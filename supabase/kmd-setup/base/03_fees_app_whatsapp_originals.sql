-- The fees app's own WhatsApp campaign migrations, copied unchanged from
-- tests/fees/fixtures/fee-migrations (schoolfees @ 8a0cd47c).

-- Per-family WhatsApp reminder cadence, so the office stops re-unticking the
-- same children every single run.
--
-- The reminders list is rebuilt from the ledger on every load, which is what
-- makes "families who paid drop off" free. What was NOT persisted was the
-- office's own judgement: "this family pays eventually, don't chase them every
-- few days". So the same twenty rows got unticked by hand, daily.
--
-- Deliberately WhatsApp-scoped, and deliberately NOT `no_call`. `no_call` means
-- "don't chase this family at all" and removes them from the Defaulters call
-- queue too; the office wants to keep CALLING some of these families while
-- messaging them less often. Two different decisions, two different columns,
-- on the one table that already owns per-session collection preferences.
--
-- There is no "last reminded" column here on purpose: `whatsapp_reminder_sends`
-- already records `sent_on` for every attempt, so the gap is derived from the
-- send log and cannot drift away from what was actually sent.

alter table public.student_collection_flags
  add column if not exists whatsapp_cadence text not null default 'every_run',
  add column if not exists whatsapp_snoozed_until date;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'student_collection_flags_whatsapp_cadence_check'
  ) then
    alter table public.student_collection_flags
      add constraint student_collection_flags_whatsapp_cadence_check
      check (whatsapp_cadence in ('every_run', 'weekly', 'fortnightly', 'monthly', 'never'));
  end if;
end $$;

comment on column public.student_collection_flags.whatsapp_cadence is
  'How often this family may receive a WhatsApp fee reminder: every_run (default), '
  'weekly, fortnightly, monthly, or never. Enforced against whatsapp_reminder_sends.sent_on, '
  'so the minimum gap is measured from what was actually sent. WhatsApp only — it does '
  'NOT affect the Defaulters call queue, which reads no_call.';

comment on column public.student_collection_flags.whatsapp_snoozed_until is
  'Temporary WhatsApp skip. The family is absent from the reminder list until this date '
  'and then returns on its own, with no un-snoozing to remember. Independent of cadence.';

-- The reminder screen filters on these two, per session, for every load.
create index if not exists student_collection_flags_whatsapp_idx
  on public.student_collection_flags (session_label)
  where whatsapp_cadence <> 'every_run' or whatsapp_snoozed_until is not null;

-- IMPORTANT for anything writing this table from now on: `no_call` defaults to
-- TRUE. A row inserted just to record a WhatsApp cadence must pass
-- `no_call => false` explicitly, or setting "remind monthly" would silently
-- also stop the fee collectors calling that family. The reminder actions
-- update-then-insert for exactly this reason.
-- Saved reminder campaigns, the runs they produce, and what those runs collected.
--
-- The send log already IS the cohort record: `whatsapp_reminder_sends` holds one
-- row per family per notice per day, with the amount quoted and the params as
-- sent. 142 rows for the single run that has happened. What was missing is only
-- a grouping key and a record of what the run WAS — so this is two small tables
-- and one nullable column, not a new subsystem.
--
-- Shape follows `promotion_runs` (20260525135507): a run table with denormalised
-- counts. RLS follows `whatsapp_reminder_sends` (20260820140000): staff read,
-- service-role writes, no insert policy at all.

-- ---------------------------------------------------------------- the definition
-- Editable in place, because it is intent rather than a financial record. What
-- actually went out is snapshotted on the run.
create table if not exists public.whatsapp_campaigns (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  name text not null,
  situation text not null check (situation in ('fee_due', 'balance', 'prevyear')),
  language text not null check (language in ('hi', 'en')),
  -- The ReminderFilters snapshot, so re-running rebuilds the same audience rule
  -- against today's ledger rather than yesterday's list.
  filters jsonb not null default '{}'::jsonb,
  last_date date,
  late_fee_amount integer not null default 0 check (late_fee_amount >= 0),
  late_fee_basis text not null default 'per_installment'
    check (late_fee_basis in ('per_installment', 'per_day', 'flat', 'none')),
  archived_at timestamptz,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_label, name)
);

comment on table public.whatsapp_campaigns is
  'A saved, re-runnable reminder definition: which notice, in which language, to '
  'whom, by when, with what late fee. The audience is NEVER stored — only the '
  'filter rule — so a family who pays drops out of the next run for free.';

comment on column public.whatsapp_campaigns.late_fee_amount is
  'What the MESSAGE says a late payment costs. Deliberately not the ledger''s late '
  'fee: this is a lever for getting fees in on time, and the app does not charge '
  'it. The screen warns when the two disagree rather than refusing to send.';

comment on column public.whatsapp_campaigns.created_by is
  'Not a foreign key to auth.users, matching whatsapp_reminder_sends.sent_by — '
  'removing a staff account must not delete the record of what was sent.';

create index if not exists whatsapp_campaigns_session_idx
  on public.whatsapp_campaigns (session_label, archived_at nulls first, name);

-- --------------------------------------------------------------------- one press
-- Immutable once finished. `filters` and `late_fee_phrase` are snapshotted here
-- rather than read back through the campaign, because the campaign is editable
-- and what went out is not.
create table if not exists public.whatsapp_campaign_runs (
  id uuid primary key default gen_random_uuid(),
  -- set null, never cascade: deleting a saved campaign must not destroy the
  -- evidence that parents were messaged.
  campaign_id uuid references public.whatsapp_campaigns(id) on delete set null,
  session_label text not null,
  campaign_name text not null,
  situation text not null,
  language text not null,
  filters jsonb not null default '{}'::jsonb,
  last_date date,
  late_fee_phrase text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  started_by uuid,
  selected_count integer not null default 0,
  sent_count integer not null default 0,
  failed_count integer not null default 0,
  already_count integer not null default 0,
  money_quoted bigint not null default 0,
  created_at timestamptz not null default now()
);

comment on table public.whatsapp_campaign_runs is
  'One press of Send. The counts are denormalised because sendRemindersAction '
  'already computes them and used to throw them away.';

comment on column public.whatsapp_campaign_runs.late_fee_phrase is
  'Exactly what slot 7 carried, as text. The composed phrase, not the amount and '
  'basis it came from — a later change to the campaign must not rewrite history.';

create index if not exists whatsapp_campaign_runs_session_idx
  on public.whatsapp_campaign_runs (session_label, started_at desc);
create index if not exists whatsapp_campaign_runs_campaign_idx
  on public.whatsapp_campaign_runs (campaign_id, started_at desc);

-- ------------------------------------------------------------- the grouping key
-- Nullable on purpose. The 142 rows already logged belong to no run and are NOT
-- backfilled: inventing a run nobody pressed would be a lie in the record.
alter table public.whatsapp_reminder_sends
  add column if not exists run_id uuid
    references public.whatsapp_campaign_runs(id) on delete set null;

comment on column public.whatsapp_reminder_sends.run_id is
  'Which press of Send produced this row. Null for anything sent before runs were '
  'recorded. DELIBERATELY NOT part of the unique index: '
  '(student_id, session_label, sent_on, campaign_name) is what stops a family '
  'being sent the same notice twice in one day, and adding run_id would let a '
  'second run that same day message everyone again.';

create index if not exists whatsapp_reminder_sends_run_idx
  on public.whatsapp_reminder_sends (run_id);

-- ------------------------------------------------------------------ did it work
-- A view, not a materialized one: a handful of runs a month over hundreds of
-- rows. A matview would add a refresh path to forget, and this schema already
-- works around one two-minute staleness window.
--
-- "Paid after the reminder", never "because of it". Payments here are spiky —
-- 17 Aug posted 107 families in one batch against 2-9 on a normal day, which is
-- counter cash entered in bulk. This view cannot tell that apart from a response
-- and does not pretend to.
-- One lateral per send row. A run is one campaign on one day, and the unique
-- index guarantees at most one send per student in it, so there is nothing to
-- de-duplicate and no way to double-count.
create or replace view public.v_whatsapp_run_outcomes as
select
  run.id as run_id,
  run.campaign_id,
  run.session_label,
  run.campaign_name,
  run.situation,
  run.language,
  run.started_at,
  run.last_date,
  run.late_fee_phrase,
  count(*) filter (where s.status = 'sent') as messaged,
  count(*) filter (where s.status = 'failed') as failed,
  coalesce(sum(s.due_amount) filter (where s.status = 'sent'), 0) as money_quoted,
  count(*) filter (where s.status = 'sent' and coalesce(paid.amount_paid, 0) > 0)
    as families_paid,
  coalesce(sum(paid.amount_paid) filter (where s.status = 'sent'), 0)
    as money_collected
from public.whatsapp_campaign_runs run
left join public.whatsapp_reminder_sends s on s.run_id = run.id
left join lateral (
  select sum(r.total_amount) as amount_paid
  from public.receipts r
  where r.student_id = s.student_id
    and r.payment_date >= s.sent_on
    and (run.last_date is null or r.payment_date <= run.last_date)
    -- A discount close-out is not collection.
    and r.payment_mode <> 'discount'
    -- A fully reversed receipt never happened, as far as money is concerned.
    and not exists (
      select 1
      from public.v_receipt_reversal_totals rr
      where rr.receipt_id = r.id
        and rr.reversed_amount >= r.total_amount
    )
) paid on true
group by run.id;

comment on view public.v_whatsapp_run_outcomes is
  'Per run: who was messaged, and who paid between the send and the date the '
  'message asked for. Excludes discount close-outs and fully reversed receipts, '
  'matching the dashboard collection rule. This is correlation, not attribution.';

-- -------------------------------------------------------------------------- RLS
-- Staff read from the screen. Writes go through the service role in a server
-- action, which bypasses RLS — there is deliberately no insert or update policy,
-- so nothing running in a browser can fabricate a record of a campaign run.
--
-- `(select auth.role())` rather than the bare call: the bare one is re-evaluated
-- per row, the auth_rls_initplan pattern 20260527090443 swept out everywhere.
alter table public.whatsapp_campaigns enable row level security;
alter table public.whatsapp_campaign_runs enable row level security;

drop policy if exists "whatsapp_campaigns: staff read" on public.whatsapp_campaigns;
create policy "whatsapp_campaigns: staff read"
  on public.whatsapp_campaigns for select
  using ((select auth.role()) = 'authenticated');

drop policy if exists "whatsapp_campaign_runs: staff read" on public.whatsapp_campaign_runs;
create policy "whatsapp_campaign_runs: staff read"
  on public.whatsapp_campaign_runs for select
  using ((select auth.role()) = 'authenticated');

grant select on public.whatsapp_campaigns to authenticated;
grant select on public.whatsapp_campaign_runs to authenticated;
grant select on public.v_whatsapp_run_outcomes to authenticated;
-- Tell a parent their payment landed.
--
-- The office's most common WhatsApp message is not a reminder, it is a parent
-- asking whether the money arrived. A receipt notice answers that before it is
-- asked, and it is the only message in this system a family is pleased to get.
--
-- Sent strictly AFTER `post_student_payment_with_adjustments` has returned
-- success, outside any transaction, inside a try/catch that swallows
-- everything. A messaging failure must never fail a posting: the money is in
-- the drawer and the receipt is printed either way.

alter table public.whatsapp_reminder_sends
  add column if not exists receipt_id uuid
    references public.receipts(id) on delete set null;

comment on column public.whatsapp_reminder_sends.receipt_id is
  'The receipt this notice confirms, for a receipt notice only. Null for every '
  'reminder. `on delete set null` rather than cascade, matching campaign_id: a '
  'send row is evidence a parent was messaged, and it must outlive whatever it '
  'referred to.';

-- ONE notice per receipt, ever.
--
-- Deliberately NOT part of the day/campaign index, which is scoped to a session
-- and a day. A receipt notice is keyed to a receipt and nothing else: a second
-- posting for the same family on the same day is a second receipt and deserves
-- its own message, while a retry of the SAME receipt must never send twice.
create unique index if not exists whatsapp_reminder_sends_receipt_idx
  on public.whatsapp_reminder_sends (receipt_id)
  where receipt_id is not null;

comment on index public.whatsapp_reminder_sends_receipt_idx is
  'One receipt notice per receipt. Partial, so the millions of reminder rows '
  'carrying a null receipt_id are not in it. Claimed before the provider call '
  'like every other send, so this is what decides a race between two postings.';

-- ---------------------------------------------------------------- the switch

-- `app_settings` is the existing key/value store the active session already
-- lives in. A dedicated column on a settings table would need a settings table;
-- this needs two rows.
insert into public.app_settings (key, value)
values
  -- OFF until the template is approved AND somebody decides the school wants
  -- this. A feature that starts messaging parents the moment it deploys is not
  -- a feature, it is an incident.
  ('whatsapp_receipt_notice_enabled', 'false'),
  -- Which `_v3` campaigns an admin has confirmed are Live in AiSensy, as a JSON
  -- array of campaign names. The registry's `approved: false` is the floor: this
  -- can only turn a campaign ON, and never one the code has not written a body
  -- for, because a name with no descriptor has nothing to enable.
  ('whatsapp_campaign_approvals', '[]')
-- Explicit target: `key` is the primary key, and a bare `do nothing` would
-- silently swallow a conflict on some other constraint added later.
on conflict (key) do nothing;
-- A second receipt for the same student on the same day is a second receipt.
--
-- `data/receipt-notice.ts` inserts its claim row WITHOUT `sent_on`, so the
-- column defaults to the IST date. The day index is
--
--   unique (student_id, session_label, sent_on, campaign_name, destination_role)
--
-- and it is NOT partial, so a family paying twice in one day collides on it and
-- the code reports the 23505 as *"A notice for this receipt has already been
-- sent."* — which is untrue, and suppresses a notice for a receipt that has
-- never been announced. `20260903172053_whatsapp_receipt_notices.sql:24-27`
-- says the opposite is intended:
--
--   "a second posting for the same family on the same day is a second receipt
--    and deserves its own message"
--
-- Invisible in production only because `whatsapp_receipt_notice_enabled` is
-- still 'false'.
--
-- Two changes, and they must ship together, because the second one is what
-- makes a THIRD notice kind possible at all:
--
--   1. The day index becomes partial on reminder rows (`receipt_id is null`).
--      Reminders and `covered_by_sibling` rows are guarded exactly as before;
--      receipt-shaped notices are guarded by the receipt index alone.
--
--   2. The receipt index is re-keyed from (receipt_id) to
--      (receipt_id, notice_kind). Without this, a payment-REVERSED notice would
--      collide with the receipt notice for the same receipt and be reported as
--      a duplicate — one receipt can legitimately produce one "payment
--      received" and, later, one "payment reversed".
--
-- A pleasant consequence of (1): a fee-statement notice carries
-- `receipt_id is null`, so it inherits the day index for free. One statement per
-- family per day, no new column and no new index — which is exactly the rule a
-- staff-tapped button wants, against double-taps and two staff in two tabs.


-- `not null default` is load-bearing. A nullable notice_kind would let
-- Postgres's default NULLS DISTINCT treat two rows with the same receipt_id and
-- a null kind as different, silently deleting the "one notice per receipt, ever"
-- guarantee this index exists to provide.
alter table public.whatsapp_reminder_sends
  add column if not exists notice_kind text not null default 'reminder';

alter table public.whatsapp_reminder_sends
  drop constraint if exists whatsapp_reminder_sends_notice_kind_check;

alter table public.whatsapp_reminder_sends
  add constraint whatsapp_reminder_sends_notice_kind_check
  check (notice_kind in ('reminder', 'receipt', 'reversal', 'fee_statement'));

-- Backfill BEFORE the new index is built: every existing row carrying a
-- receipt_id is, by construction, a receipt notice.
update public.whatsapp_reminder_sends
   set notice_kind = 'receipt'
 where receipt_id is not null
   and notice_kind = 'reminder';

-- Create then drop, never the reverse: dropping first would leave a window in
-- which nothing stops a duplicate.
create unique index if not exists whatsapp_reminder_sends_receipt_kind_idx
  on public.whatsapp_reminder_sends (receipt_id, notice_kind)
  where receipt_id is not null;

drop index if exists public.whatsapp_reminder_sends_receipt_idx;

create unique index if not exists whatsapp_reminder_sends_reminder_day_idx
  on public.whatsapp_reminder_sends
  (student_id, session_label, sent_on, campaign_name, destination_role)
  where receipt_id is null;

drop index if exists public.whatsapp_reminder_sends_student_day_campaign_role_idx;

comment on column public.whatsapp_reminder_sends.notice_kind is
  'What this row announced: reminder (the campaign runner), receipt, reversal, or fee_statement. Part of the receipt uniqueness key, so one receipt may produce one receipt notice and later one reversal notice without either being reported as a duplicate.';

