-- KMD One database setup — part 6 of 11. Run the parts in order, each once.
-- Files: 20261028140100_online_payments.sql … 20261031101234_staff_whatsapp_consent_and_gates.sql

-- ======================================================== fee-migrations/20261028140100_online_payments.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261028140100_online_payments.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: the pg_cron block(s) are REMOVED.
--   The fees original unschedules and re-schedules a pg_cron job whose command
--   calls https://schoolfees-two.vercel.app/api/cron/... — the PRODUCTION fees
--   app. Applied here it would make One's database a caller of the fees app's
--   production endpoints whenever Vault holds the same secret name (plan §1.5,
--   critique0 #23). One schedules its own jobs, against its own routes, at
--   cutover (plan §11). Nothing else in the file is changed.
-- ============================================================================
-- Online fee payments through Razorpay Payment Links.
--
-- A parent taps Pay now on a WhatsApp reminder, `/pay/[code]` opens on the
-- send's own pay code, and a Razorpay Standard Payment Link takes the money.
-- This migration is everything the DATABASE must guarantee about that money:
--
--   1. One canonical quote. `private.online_payment_quote` reads the same
--      snapshot, in the same order, that the posting engine allocates over, so
--      the amount a parent is asked for clears exactly the rows it names.
--   2. A versioned intent is written BEFORE a provider link exists, and at most
--      one is open per student (a unique partial index decides the race between
--      two phones).
--   3. A verified capture is posted exactly once, through the SAME posting
--      engine the Payment Desk uses. The engine's body moves into
--      `private.post_student_payment_core`; the desk's public RPC keeps its
--      signature and its permission check and calls it. The online entry point
--      is `public.online_payment_apply_capture`, service_role only, and the core
--      admits it only while a verified, unapplied capture for that very student
--      is named in this transaction.
--   4. Money is never lost and never over-credited. A capture whose dues moved
--      (cash at the counter, a waiver, a fee edit) is RECORDED and marked
--      `review_required`, never posted against a different allocation.
--   5. A receipt posted any other way supersedes the student's open intent, so
--      a family who paid cash is not also offered the old link.
--
-- Nothing here messages anyone, creates a provider link, or posts a payment on
-- its own. The three switches seeded below are all 'false'.

begin;

-- ---------------------------------------------------------------- switches

-- Runtime switches, flippable without a deploy. The webhook intake and the
-- reconciler are deliberately NOT switched: during a rollback, money already
-- paid must still be received, verified and shown to the office.
insert into public.app_settings (key, value) values
  ('online_payment_links_enabled', 'false'),
  ('online_payment_auto_posting_enabled', 'false'),
  ('online_payment_receipts_enabled', 'false')
on conflict (key) do nothing;

create or replace function private.online_setting_on(p_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select lower(s.value) = 'true' from public.app_settings s where s.key = p_key),
    false
  );
$$;

revoke all on function private.online_setting_on(text) from public, anon, authenticated;
grant execute on function private.online_setting_on(text) to service_role;

-- ---------------------------------------------------------------- the send's scope

-- What a reminder's Pay now button actually covers, written at send time from
-- the numbers that built the message — never parsed back out of its text.
alter table public.whatsapp_reminder_sends
  add column if not exists pay_scope jsonb;

comment on column public.whatsapp_reminder_sends.pay_scope is
  'The exact scope behind this send''s Pay now link: {studentIds, installments, lastYear, '
  'situation, amount}. Written from the figures that built the message. The pay page offers '
  'an online payment only for a one-student scope, and re-quotes it from the ledger.';

-- ---------------------------------------------------------------- tables

create table public.online_payment_intents (
  id uuid primary key default gen_random_uuid(),
  -- Opaque, random, no student detail. Goes into the provider's notes and the
  -- receipt remark so the office can find an intent from either side.
  public_ref text not null unique check (public_ref ~ '^[A-Za-z0-9_-]{20,64}$'),
  provider text not null default 'razorpay' check (provider = 'razorpay'),
  provider_mode text not null check (provider_mode in ('test', 'live')),
  status text not null default 'link_pending' check (status in (
    'link_pending',     -- written, provider link not confirmed yet
    'link_created',     -- the parent can pay
    'paid',             -- a verified capture is recorded, not yet posted
    'accounted',        -- posted; receipt_id is set
    'review_required',  -- money arrived and could not be posted safely
    'superseded',       -- dues moved or another payment was posted
    'cancelled',
    'expired',
    'failed'            -- the provider refused to create the link
  )),
  student_id uuid not null references public.students (id),
  session_label text not null,
  send_id uuid references public.whatsapp_reminder_sends (id),
  scope_installment_nos smallint[] not null default '{}',
  scope_include_carry_forward boolean not null default false,
  quote jsonb not null,
  quote_version integer not null default 1,
  quote_hash text not null,
  -- The ledger is whole rupees. The provider boundary is paise, derived here
  -- and nowhere else, so it cannot be rounded on the way.
  amount_rupees integer not null check (amount_rupees >= 1),
  amount_paise bigint generated always as (amount_rupees::bigint * 100) stored,
  currency text not null default 'INR' check (currency = 'INR'),
  expires_at timestamptz not null,
  provider_reference_id text not null unique check (char_length(provider_reference_id) <= 40),
  provider_link_id text unique,
  provider_short_url text,
  link_attempts integer not null default 0,
  last_error text,
  superseded_reason text,
  -- When the provider's link was seen closed (cancelled by us, expired, or
  -- found never to exist). Null on a closed intent means the reconciler still
  -- has to make sure the link cannot take money.
  provider_cancelled_at timestamptz,
  last_reconciled_at timestamptz,
  receipt_id uuid references public.receipts (id),
  accounted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.online_payment_intents is
  'One versioned online-payment intent per quote. Written before any provider link exists. '
  'At most one open (link_pending | link_created) per student.';

-- The race between two phones, or two taps, is decided here.
create unique index online_payment_intents_one_open_per_student
  on public.online_payment_intents (student_id)
  where status in ('link_pending', 'link_created');

create index online_payment_intents_status_idx
  on public.online_payment_intents (status, updated_at);

create index online_payment_intents_send_idx
  on public.online_payment_intents (send_id)
  where send_id is not null;

-- The inbox. A verified webhook is recorded here before it is acknowledged;
-- duplicates collide on the provider's event id.
create table public.online_payment_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'razorpay',
  provider_event_id text not null unique,
  event_type text not null,
  account_id text,
  provider_payment_id text,
  provider_link_id text,
  payload_sha256 text not null,
  -- Ids, amounts and statuses only. Contact numbers, e-mail addresses and VPAs
  -- in the provider payload are never stored.
  facts jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'processed', 'ignored', 'failed')),
  attempts integer not null default 0,
  last_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

create index online_payment_events_pending_idx
  on public.online_payment_events (received_at)
  where status in ('pending', 'failed');

create index online_payment_events_payment_idx
  on public.online_payment_events (provider_payment_id)
  where provider_payment_id is not null;

-- One row per provider payment, however many events mention it.
create table public.online_payment_captures (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'razorpay',
  provider_payment_id text not null unique,
  intent_id uuid references public.online_payment_intents (id),
  provider_link_id text,
  provider_mode text not null check (provider_mode in ('test', 'live')),
  amount_paise bigint not null check (amount_paise > 0),
  currency text not null,
  provider_status text not null,
  method text,
  fee_paise bigint,
  tax_paise bigint,
  captured_at timestamptz,
  verified_at timestamptz not null default now(),
  application_status text not null default 'pending'
    check (application_status in ('pending', 'applied', 'review_required')),
  review_reason text,
  receipt_id uuid unique references public.receipts (id),
  applied_at timestamptz,
  resolved_by uuid,
  resolved_at timestamptz,
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index online_payment_captures_status_idx
  on public.online_payment_captures (application_status, created_at);

create index online_payment_captures_intent_idx
  on public.online_payment_captures (intent_id);

-- Parent messages that must survive a crash between posting and sending.
create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('receipt_notice')),
  dedupe_key text not null unique,
  receipt_id uuid references public.receipts (id),
  student_id uuid references public.students (id),
  session_label text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'queued' check (status in (
    'queued', 'processing', 'provider_accepted', 'delivered', 'failed', 'suppressed', 'uncertain'
  )),
  attempts integer not null default 0,
  max_attempts integer not null default 5,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index notification_outbox_due_idx
  on public.notification_outbox (next_attempt_at)
  where status in ('queued', 'failed', 'processing');

-- Append-only history of every decision made about online money.
create table public.online_payment_audit (
  id bigint generated always as identity primary key,
  intent_id uuid,
  capture_id uuid,
  event_id uuid,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  actor text not null default 'system',
  created_at timestamptz not null default now()
);

create index online_payment_audit_intent_idx on public.online_payment_audit (intent_id, created_at);
create index online_payment_audit_capture_idx on public.online_payment_audit (capture_id, created_at);

create or replace function private.online_payment_audit_is_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'online_payment_audit is append-only.';
end;
$$;

create trigger online_payment_audit_append_only
  before update or delete on public.online_payment_audit
  for each row execute function private.online_payment_audit_is_append_only();

-- Server-side only. Staff read these through the admin client after a
-- permission check; nothing in the browser reaches them.
alter table public.online_payment_intents enable row level security;
alter table public.online_payment_events enable row level security;
alter table public.online_payment_captures enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.online_payment_audit enable row level security;

revoke all on public.online_payment_intents from anon, authenticated;
revoke all on public.online_payment_events from anon, authenticated;
revoke all on public.online_payment_captures from anon, authenticated;
revoke all on public.notification_outbox from anon, authenticated;
revoke all on public.online_payment_audit from anon, authenticated;

-- Explicit, because this project's default privileges do not hand new tables
-- to service_role. No DELETE anywhere: money records are corrected, not removed.
grant select, insert, update on public.online_payment_intents to service_role;
grant select, insert, update on public.online_payment_events to service_role;
grant select, insert, update on public.online_payment_captures to service_role;
grant select, insert, update on public.notification_outbox to service_role;
grant select, insert on public.online_payment_audit to service_role;

-- ---------------------------------------------------------------- the quote

-- The canonical quote: what a parent is asked to pay for a scope, and the rows
-- it clears.
--
-- It walks `private.workbook_installment_snapshot` in the posting engine's own
-- order — EMI plan rows first, then due date, then installment number — over
-- `total_pending`, which is what the engine allocates against. So a quote that
-- is `eligible` is, by construction, an amount the engine will lay exactly
-- over the quoted rows and nothing else.
--
-- Not eligible, with a reason, when:
--   nothing_due                nothing owed in the scope
--   emi_plan_active            plan rows sort first; EMI policy is the desk's
--   earlier_dues_not_selected  an older owed row is outside the scope, and the
--                              engine would settle it first
--   late_fee_pending           a late fee is owed inside the scope. A late fee
--                              is not a fee: it is never folded into a fees
--                              figure, and waiving it is a staff decision
create or replace function private.online_payment_quote(
  p_student_id uuid,
  p_installment_nos smallint[],
  p_include_carry_forward boolean,
  p_as_of date
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_plan_id uuid;
  v_row record;
  v_lines jsonb := '[]'::jsonb;
  v_reasons text[] := '{}';
  v_total integer := 0;
  v_fees integer := 0;
  v_late integer := 0;
  v_seen_unselected_owed boolean := false;
  v_prefix_broken boolean := false;
  v_hash_source text := '';
begin
  select p.id into v_plan_id
  from public.student_repayment_plans as p
  where p.student_id = p_student_id
    and p.lifecycle = 'active'
  limit 1;

  for v_row in
    select
      snapshot_row.installment_id,
      snapshot_row.installment_no,
      snapshot_row.due_date,
      snapshot_row.pending_amount,
      snapshot_row.late_fee_pending,
      snapshot_row.total_pending,
      coalesce(installment.is_carry_forward, false) as is_carry_forward,
      case when plan_item.installment_id is null then 1 else 0 end as plan_priority
    from private.workbook_installment_snapshot(p_student_id, p_as_of, true) as snapshot_row
    join public.installments as installment
      on installment.id = snapshot_row.installment_id
    left join public.student_repayment_plan_items as plan_item
      on plan_item.installment_id = snapshot_row.installment_id
      and plan_item.plan_id = v_plan_id
    where snapshot_row.total_pending > 0
    order by
      case when plan_item.installment_id is null then 1 else 0 end asc,
      snapshot_row.due_date asc,
      snapshot_row.installment_no asc
  loop
    if (v_row.is_carry_forward and coalesce(p_include_carry_forward, false))
       or (not v_row.is_carry_forward
           and v_row.installment_no = any(coalesce(p_installment_nos, '{}'::smallint[]))) then
      if v_seen_unselected_owed then
        v_prefix_broken := true;
      end if;
      v_lines := v_lines || jsonb_build_object(
        'installment_id', v_row.installment_id,
        'installment_no', v_row.installment_no,
        'due_date', v_row.due_date,
        'carry_forward', v_row.is_carry_forward,
        'fees_pending', v_row.pending_amount,
        'late_fee_pending', v_row.late_fee_pending,
        'total_pending', v_row.total_pending
      );
      v_total := v_total + v_row.total_pending;
      v_fees := v_fees + v_row.pending_amount;
      v_late := v_late + v_row.late_fee_pending;
      v_hash_source := v_hash_source || v_row.installment_id::text || ':' || v_row.total_pending || ';';
    else
      v_seen_unselected_owed := true;
    end if;
  end loop;

  if v_total <= 0 then v_reasons := array_append(v_reasons, 'nothing_due'); end if;
  if v_plan_id is not null then v_reasons := array_append(v_reasons, 'emi_plan_active'); end if;
  if v_prefix_broken then v_reasons := array_append(v_reasons, 'earlier_dues_not_selected'); end if;
  if v_late > 0 then v_reasons := array_append(v_reasons, 'late_fee_pending'); end if;

  return jsonb_build_object(
    'version', 1,
    'student_id', p_student_id,
    'as_of', p_as_of,
    'installment_nos', to_jsonb(coalesce(p_installment_nos, '{}'::smallint[])),
    'include_carry_forward', coalesce(p_include_carry_forward, false),
    'lines', v_lines,
    'fees_total', v_fees,
    'late_fee_total', v_late,
    'total', v_total,
    'reasons', to_jsonb(v_reasons),
    'eligible', cardinality(v_reasons) = 0,
    -- The rows and what each owes, not the date: the same dues quoted
    -- tomorrow are the same quote.
    'hash', md5('v1|' || v_hash_source)
  );
end;
$$;

revoke all on function private.online_payment_quote(uuid, smallint[], boolean, date)
  from public, anon, authenticated;
grant execute on function private.online_payment_quote(uuid, smallint[], boolean, date)
  to service_role;

create or replace function private.ist_today()
returns date
language sql
stable
set search_path = ''
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- The quote, for the reminder sender and the pay page. Service role only.
create or replace function public.online_payment_quote_for(
  p_student_id uuid,
  p_installment_nos smallint[],
  p_include_carry_forward boolean
)
returns jsonb
language sql
set search_path = public, private
as $$
  select private.online_payment_quote(
    p_student_id, p_installment_nos, p_include_carry_forward, private.ist_today()
  );
$$;

revoke all on function public.online_payment_quote_for(uuid, smallint[], boolean)
  from public, anon, authenticated;
grant execute on function public.online_payment_quote_for(uuid, smallint[], boolean)
  to service_role;

-- ---------------------------------------------------------------- the posting core

-- Who may reach the core without a staff permission: the online entry point,
-- for exactly the student whose verified, unapplied capture it named in this
-- transaction. SECURITY INVOKER on purpose, so current_user is the caller.
create or replace function private.online_posting_in_progress(p_student_id uuid)
returns boolean
language plpgsql
stable
set search_path = public, private
as $$
declare
  v_capture_id uuid;
begin
  if current_user not in ('service_role', 'postgres') then
    return false;
  end if;
  begin
    v_capture_id := nullif(current_setting('vpps.online_capture_id', true), '')::uuid;
  exception when others then
    return false;
  end;
  if v_capture_id is null then
    return false;
  end if;
  return exists (
    select 1
    from public.online_payment_captures as capture
    join public.online_payment_intents as intent on intent.id = capture.intent_id
    where capture.id = v_capture_id
      and capture.application_status = 'pending'
      and intent.student_id = p_student_id
  );
end;
$$;

revoke all on function private.online_posting_in_progress(uuid) from public, anon;
grant execute on function private.online_posting_in_progress(uuid) to authenticated, service_role;

-- The posting engine, moved here verbatim from
-- `public.post_student_payment_with_adjustments` as it stood in production on
-- 2026-10-28 (20260811073129 + the `total_pending` line of 20260812120000).
-- The ONLY change is the first guard, which also admits
-- `private.online_posting_in_progress`.
--
-- **Edit the allocation here, not in the public RPC.** A migration that
-- string-patches the posting rule must now target this function.
create or replace function private.post_student_payment_core(
  p_student_id uuid,
  p_payment_date date,
  p_payment_mode payment_mode,
  p_total_amount integer,
  p_reference_number text default null::text,
  p_remarks text default null::text,
  p_received_by text default null::text,
  p_receipt_prefix text default 'SVP'::text,
  p_client_request_id uuid default null::uuid,
  p_quick_discount_amount integer default 0,
  p_quick_late_fee_waiver_amount integer default 0
)
returns table (receipt_id uuid, receipt_number text, allocated_total integer)
language plpgsql
set search_path to 'public'
as $function$
declare
  balance_row record;
  v_payment_allocation integer;
  v_discount_allocation integer;
  v_waiver_allocation integer;
  v_remaining_payment integer;
  v_remaining_discount integer;
  v_remaining_waiver integer;
  v_daily_sequence integer;
  v_candidate_receipt_number text;
  v_candidate_receipt_id uuid;
  v_existing_receipt_number text;
  v_existing_total_amount integer;
  v_total_pending integer;
  v_revised_pending integer;
  v_normalized_prefix text;
  v_pending_after integer;
  v_receipt_notes text;
  v_workbook_snapshot jsonb;
  v_plan_id uuid;
  v_plan_balance_before integer := 0;
  v_plan_contribution integer := 0;
begin
  if not (
    public.has_permission('payments:write')
    or private.online_posting_in_progress(p_student_id)
  ) then
    raise exception 'You do not have permission to post payments.';
  end if;

  if p_total_amount is null or p_total_amount <= 0 then
    raise exception 'Payment amount must be greater than 0.';
  end if;

  v_remaining_discount := greatest(coalesce(p_quick_discount_amount, 0), 0);
  v_remaining_waiver := greatest(coalesce(p_quick_late_fee_waiver_amount, 0), 0);
  v_remaining_payment := p_total_amount;
  v_receipt_notes := nullif(trim(coalesce(p_remarks, '')), '');

  perform pg_advisory_xact_lock(hashtextextended(p_student_id::text, 0));

  if p_client_request_id is not null then
    select r.id, r.receipt_number, r.total_amount
    into v_candidate_receipt_id, v_existing_receipt_number, v_existing_total_amount
    from public.receipts as r
    where r.student_id = p_student_id
      and r.client_request_id = p_client_request_id
    order by r.created_at desc
    limit 1;

    if v_candidate_receipt_id is not null then
      return query select v_candidate_receipt_id, v_existing_receipt_number, v_existing_total_amount;
      return;
    end if;
  end if;

  select p.id into v_plan_id
  from public.student_repayment_plans as p
  where p.student_id = p_student_id
    and p.lifecycle = 'active'
  limit 1;

  if v_plan_id is not null and (v_remaining_discount > 0 or v_remaining_waiver > 0) then
    raise exception
      'This student is on an EMI plan. Discounts and late-fee waivers cannot be applied at the counter — reschedule the plan instead.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'installment_id', snapshot_row.installment_id,
        'pending_amount', snapshot_row.total_pending,
        'due_date', snapshot_row.due_date,
        'installment_no', snapshot_row.installment_no,
        'plan_priority', case when plan_item.installment_id is null then 1 else 0 end
      )
      order by
        case when plan_item.installment_id is null then 1 else 0 end asc,
        snapshot_row.due_date asc,
        snapshot_row.installment_no asc
    ),
    '[]'::jsonb
  )
  into v_workbook_snapshot
  from private.workbook_installment_snapshot(p_student_id, p_payment_date, true) as snapshot_row
  left join public.student_repayment_plan_items as plan_item
    on plan_item.installment_id = snapshot_row.installment_id
    and plan_item.plan_id = v_plan_id;

  select coalesce(sum(snapshot.pending_amount), 0)
  into v_total_pending
  from jsonb_to_recordset(v_workbook_snapshot) as snapshot(
    installment_id uuid,
    pending_amount integer,
    due_date date,
    installment_no smallint,
    plan_priority integer
  )
  where snapshot.pending_amount > 0;

  if v_plan_id is not null then
    select coalesce(sum(snapshot.pending_amount), 0)
    into v_plan_balance_before
    from jsonb_to_recordset(v_workbook_snapshot) as snapshot(
      installment_id uuid,
      pending_amount integer,
      due_date date,
      installment_no smallint,
      plan_priority integer
    )
    where snapshot.pending_amount > 0
      and snapshot.plan_priority = 0;
  end if;

  v_revised_pending := v_total_pending - v_remaining_discount - v_remaining_waiver;

  if v_total_pending <= 0 then
    raise exception 'No pending dues are available for this student.';
  end if;

  if v_revised_pending <= 0 then
    raise exception 'No payable dues found after discount and late fee waiver.';
  end if;

  if p_total_amount > v_revised_pending then
    raise exception 'Payment amount cannot exceed revised payable amount.';
  end if;

  v_normalized_prefix := coalesce(nullif(trim(coalesce(p_receipt_prefix, '')), ''), 'SVP');

  select coalesce(max((regexp_match(receipt_row.receipt_number, '-([0-9]{4})$'))[1]::integer), 0)
  into v_daily_sequence
  from public.receipts as receipt_row
  where receipt_row.receipt_number like v_normalized_prefix || to_char(p_payment_date, 'YYYYMMDD') || '-%';

  for _attempt in 1..12 loop
    v_daily_sequence := v_daily_sequence + 1;
    v_candidate_receipt_number := v_normalized_prefix || to_char(p_payment_date, 'YYYYMMDD') || '-' || lpad(v_daily_sequence::text, 4, '0');

    begin
      insert into public.receipts (
        receipt_number, student_id, payment_date, payment_mode, total_amount,
        reference_number, notes, received_by, client_request_id
      )
      values (
        v_candidate_receipt_number, p_student_id, p_payment_date, p_payment_mode, p_total_amount,
        nullif(trim(coalesce(p_reference_number, '')), ''),
        v_receipt_notes,
        nullif(trim(coalesce(p_received_by, '')), ''),
        p_client_request_id
      )
      returning id into v_candidate_receipt_id;
      exit;
    exception when unique_violation then
      if p_client_request_id is not null then
        select r.id, r.receipt_number, r.total_amount
        into v_candidate_receipt_id, v_existing_receipt_number, v_existing_total_amount
        from public.receipts as r
        where r.student_id = p_student_id
          and r.client_request_id = p_client_request_id
        order by r.created_at desc
        limit 1;

        if v_candidate_receipt_id is not null then
          return query
          select v_candidate_receipt_id, v_existing_receipt_number, v_existing_total_amount;
          return;
        end if;
      end if;
      continue;
    end;
  end loop;

  if v_candidate_receipt_id is null then
    raise exception 'Unable to generate a unique receipt number. Please retry.';
  end if;

  for balance_row in
    select snapshot.installment_id, snapshot.pending_amount, snapshot.due_date,
           snapshot.installment_no, snapshot.plan_priority
    from jsonb_to_recordset(v_workbook_snapshot) as snapshot(
      installment_id uuid,
      pending_amount integer,
      due_date date,
      installment_no smallint,
      plan_priority integer
    )
    where snapshot.pending_amount > 0
    order by snapshot.plan_priority asc, snapshot.due_date asc, snapshot.installment_no asc
  loop
    exit when v_remaining_payment <= 0 and v_remaining_discount <= 0 and v_remaining_waiver <= 0;

    v_discount_allocation := least(v_remaining_discount, balance_row.pending_amount);
    v_waiver_allocation := least(v_remaining_waiver, balance_row.pending_amount - v_discount_allocation);
    v_payment_allocation := least(v_remaining_payment, balance_row.pending_amount - v_discount_allocation - v_waiver_allocation);

    if v_discount_allocation > 0 then
      insert into public.receipt_adjustments (
        receipt_id, student_id, installment_id, adjustment_type, amount_delta, reason, notes
      )
      values (
        v_candidate_receipt_id, p_student_id, balance_row.installment_id, 'discount',
        v_discount_allocation, 'Payment Desk quick discount', null
      );
      v_remaining_discount := v_remaining_discount - v_discount_allocation;
    end if;

    if v_waiver_allocation > 0 then
      insert into public.receipt_adjustments (
        receipt_id, student_id, installment_id, adjustment_type, amount_delta, reason, notes
      )
      values (
        v_candidate_receipt_id, p_student_id, balance_row.installment_id, 'writeoff',
        v_waiver_allocation, 'Payment Desk late fee waiver', null
      );
      v_remaining_waiver := v_remaining_waiver - v_waiver_allocation;
    end if;

    if v_payment_allocation > 0 then
      v_pending_after := balance_row.pending_amount
        - v_discount_allocation - v_waiver_allocation - v_payment_allocation;
      insert into public.payments (
        receipt_id, student_id, installment_id, amount, notes,
        discount_applied_at_posting, waiver_applied_at_posting,
        pending_before_posting, pending_after_posting
      )
      values (
        v_candidate_receipt_id, p_student_id, balance_row.installment_id, v_payment_allocation,
        null,
        v_discount_allocation, v_waiver_allocation,
        balance_row.pending_amount, v_pending_after
      );
      v_remaining_payment := v_remaining_payment - v_payment_allocation;

      if balance_row.plan_priority = 0 then
        v_plan_contribution := v_plan_contribution + v_payment_allocation;
      end if;
    end if;
  end loop;

  if v_remaining_payment <> 0 or v_remaining_discount <> 0 or v_remaining_waiver <> 0 then
    raise exception 'Unable to allocate payment and concessions cleanly. Please retry.';
  end if;

  if v_plan_id is not null then
    insert into public.student_repayment_receipt_links (
      plan_id, student_id, receipt_id,
      contribution_amount, spillover_amount,
      plan_balance_before, plan_balance_after
    )
    values (
      v_plan_id, p_student_id, v_candidate_receipt_id,
      v_plan_contribution, p_total_amount - v_plan_contribution,
      v_plan_balance_before, v_plan_balance_before - v_plan_contribution
    );
  end if;

  return query select v_candidate_receipt_id, v_candidate_receipt_number, p_total_amount;
end;
$function$;

revoke all on function private.post_student_payment_core(uuid, date, payment_mode, integer, text, text, text, text, uuid, integer, integer)
  from public, anon;
grant execute on function private.post_student_payment_core(uuid, date, payment_mode, integer, text, text, text, text, uuid, integer, integer)
  to authenticated, service_role;

-- The Payment Desk's RPC: same signature, same permission check, same result.
-- `create or replace` keeps its existing grants.
create or replace function public.post_student_payment_with_adjustments(
  p_student_id uuid,
  p_payment_date date,
  p_payment_mode payment_mode,
  p_total_amount integer,
  p_reference_number text default null::text,
  p_remarks text default null::text,
  p_received_by text default null::text,
  p_receipt_prefix text default 'SVP'::text,
  p_client_request_id uuid default null::uuid,
  p_quick_discount_amount integer default 0,
  p_quick_late_fee_waiver_amount integer default 0
)
returns table (receipt_id uuid, receipt_number text, allocated_total integer)
language plpgsql
set search_path to 'public'
as $function$
begin
  -- Staff only, exactly as before. The online entry point never comes through
  -- here: under a service-role JWT this check refuses, as it always has.
  if not public.has_permission('payments:write') then
    raise exception 'You do not have permission to post payments.';
  end if;

  return query
  select core.receipt_id, core.receipt_number, core.allocated_total
  from private.post_student_payment_core(
    p_student_id, p_payment_date, p_payment_mode, p_total_amount,
    p_reference_number, p_remarks, p_received_by, p_receipt_prefix,
    p_client_request_id, p_quick_discount_amount, p_quick_late_fee_waiver_amount
  ) as core;
end;
$function$;

-- ---------------------------------------------------------------- supersede

create or replace function private.current_online_intent_id()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
begin
  return nullif(current_setting('vpps.online_intent_id', true), '')::uuid;
exception when others then
  return null;
end;
$$;

-- Any receipt for a student supersedes their open intent — cash, cheque, bulk
-- upload, a write-off, a corrected payment — except the one the online entry
-- point is posting right now. The provider link is cancelled by the
-- reconciler; this only makes sure the pay page stops offering it.
create or replace function private.supersede_open_online_intents()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  update public.online_payment_intents
  set status = 'superseded',
      superseded_reason = 'another_payment_posted',
      updated_at = now()
  where student_id = new.student_id
    and status in ('link_pending', 'link_created')
    and id is distinct from private.current_online_intent_id();
  return null;
end;
$$;

create trigger supersede_online_intents_on_receipt
  after insert on public.receipts
  for each row execute function private.supersede_open_online_intents();

-- ---------------------------------------------------------------- intents

create or replace function private.online_audit(
  p_action text,
  p_intent_id uuid,
  p_capture_id uuid,
  p_event_id uuid,
  p_detail jsonb,
  p_actor text default 'system'
)
returns void
language sql
set search_path = public
as $$
  insert into public.online_payment_audit (action, intent_id, capture_id, event_id, detail, actor)
  values (p_action, p_intent_id, p_capture_id, p_event_id, coalesce(p_detail, '{}'::jsonb), coalesce(p_actor, 'system'));
$$;

revoke all on function private.online_audit(text, uuid, uuid, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function private.online_audit(text, uuid, uuid, uuid, jsonb, text) to service_role;

-- Open (or reuse) the student's intent for a scope, re-quoting from the ledger
-- under the student's lock. Reused when the dues have not moved; otherwise the
-- old one is superseded and a new version written. Service role only.
create or replace function public.online_payment_open_intent(
  p_student_id uuid,
  p_send_id uuid,
  p_installment_nos smallint[],
  p_include_carry_forward boolean,
  p_provider_mode text,
  p_expires_at timestamptz,
  p_public_ref text
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_session text;
  v_quote jsonb;
  v_existing public.online_payment_intents;
  v_new public.online_payment_intents;
  v_id uuid := gen_random_uuid();
begin
  if not private.online_setting_on('online_payment_links_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'links_disabled');
  end if;
  if p_provider_mode not in ('test', 'live') then
    raise exception 'Unknown provider mode.';
  end if;
  -- Razorpay refuses an expiry under 15 minutes away; six months is its ceiling.
  if p_expires_at < now() + interval '16 minutes' or p_expires_at > now() + interval '180 days' then
    raise exception 'Link expiry is outside the provider window.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_student_id::text, 0));

  select class.session_label into v_session
  from public.students as student
  join public.classes as class on class.id = student.class_id
  where student.id = p_student_id;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'student_not_found');
  end if;

  v_quote := private.online_payment_quote(
    p_student_id, p_installment_nos, p_include_carry_forward, private.ist_today()
  );

  select * into v_existing
  from public.online_payment_intents
  where student_id = p_student_id
    and status in ('link_pending', 'link_created')
  for update;

  if not coalesce((v_quote->>'eligible')::boolean, false) then
    -- Nothing payable any more: the open link must not stay on offer.
    if v_existing.id is not null and (v_quote->'reasons') ? 'nothing_due' then
      update public.online_payment_intents
      set status = 'superseded', superseded_reason = 'nothing_due', updated_at = now()
      where id = v_existing.id;
      perform private.online_audit('intent_superseded', v_existing.id, null, null,
        jsonb_build_object('reason', 'nothing_due'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'not_eligible', 'quote', v_quote);
  end if;

  if v_existing.id is not null then
    if v_existing.quote_hash = v_quote->>'hash'
       and v_existing.provider_mode = p_provider_mode
       and v_existing.scope_installment_nos = coalesce(p_installment_nos, '{}'::smallint[])
       and v_existing.scope_include_carry_forward = coalesce(p_include_carry_forward, false)
       and v_existing.expires_at > now() + interval '10 minutes' then
      return jsonb_build_object('ok', true, 'reused', true, 'intent', to_jsonb(v_existing));
    end if;
    update public.online_payment_intents
    set status = 'superseded', superseded_reason = 'quote_changed', updated_at = now()
    where id = v_existing.id;
    perform private.online_audit('intent_superseded', v_existing.id, null, null,
      jsonb_build_object('reason', 'quote_changed', 'old_hash', v_existing.quote_hash,
                         'new_hash', v_quote->>'hash'));
  end if;

  insert into public.online_payment_intents (
    id, public_ref, provider_mode, status, student_id, session_label, send_id,
    scope_installment_nos, scope_include_carry_forward,
    quote, quote_version, quote_hash, amount_rupees, expires_at, provider_reference_id
  )
  values (
    v_id, p_public_ref, p_provider_mode, 'link_pending', p_student_id, v_session, p_send_id,
    coalesce(p_installment_nos, '{}'::smallint[]), coalesce(p_include_carry_forward, false),
    v_quote, (v_quote->>'version')::integer, v_quote->>'hash', (v_quote->>'total')::integer,
    p_expires_at,
    -- 37 characters, inside Razorpay's 40, and unique per intent — which is
    -- what makes an uncertain create safe to retry: a second create with the
    -- same reference is refused, and the link is fetched by it instead.
    'vpps_' || replace(v_id::text, '-', '')
  )
  returning * into v_new;

  perform private.online_audit('intent_opened', v_new.id, null, null,
    jsonb_build_object('amount_rupees', v_new.amount_rupees, 'quote_hash', v_new.quote_hash,
                       'send_id', p_send_id, 'mode', p_provider_mode));

  return jsonb_build_object('ok', true, 'reused', false, 'intent', to_jsonb(v_new));
end;
$$;

revoke all on function public.online_payment_open_intent(uuid, uuid, smallint[], boolean, text, timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.online_payment_open_intent(uuid, uuid, smallint[], boolean, text, timestamptz, text)
  to service_role;

-- The provider confirmed a link for this intent (created, or found by its
-- reference after an uncertain create). A superseded intent keeps its status:
-- the reconciler will cancel the link it now knows about.
create or replace function public.online_payment_link_recorded(
  p_intent_id uuid,
  p_link_id text,
  p_short_url text
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_intent public.online_payment_intents;
begin
  update public.online_payment_intents
  set provider_link_id = coalesce(provider_link_id, p_link_id),
      provider_short_url = coalesce(provider_short_url, p_short_url),
      status = case when status = 'link_pending' then 'link_created' else status end,
      link_attempts = link_attempts + 1,
      last_error = null,
      updated_at = now()
  where id = p_intent_id
  returning * into v_intent;

  if v_intent.id is null then
    raise exception 'Unknown intent.';
  end if;
  if v_intent.provider_link_id is distinct from p_link_id then
    raise exception 'Intent already carries a different provider link.';
  end if;

  perform private.online_audit('link_recorded', v_intent.id, null, null,
    jsonb_build_object('link_id', p_link_id, 'status', v_intent.status));
  return to_jsonb(v_intent);
end;
$$;

revoke all on function public.online_payment_link_recorded(uuid, text, text) from public, anon, authenticated;
grant execute on function public.online_payment_link_recorded(uuid, text, text) to service_role;

-- The provider answered about a link. `p_definite` = it refused, and nothing
-- exists there: the intent fails and frees the student's slot. Otherwise the
-- outcome is uncertain and the intent stays `link_pending` for a reconcile.
create or replace function public.online_payment_link_failed(
  p_intent_id uuid,
  p_error text,
  p_definite boolean
)
returns void
language plpgsql
set search_path = public, private
as $$
begin
  update public.online_payment_intents
  set status = case when p_definite and status = 'link_pending' then 'failed' else status end,
      last_error = left(coalesce(p_error, ''), 500),
      link_attempts = link_attempts + 1,
      updated_at = now()
  where id = p_intent_id;
  perform private.online_audit(
    case when p_definite then 'link_refused' else 'link_uncertain' end,
    p_intent_id, null, null, jsonb_build_object('error', left(coalesce(p_error, ''), 300)));
end;
$$;

revoke all on function public.online_payment_link_failed(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.online_payment_link_failed(uuid, text, boolean) to service_role;

-- The provider says the link ended (expired or cancelled) or that the office
-- cancelled it. Never used to mark anything PAID.
create or replace function public.online_payment_link_closed(
  p_intent_id uuid,
  p_status text,
  p_reason text
)
returns void
language plpgsql
set search_path = public, private
as $$
begin
  if p_status not in ('expired', 'cancelled') then
    raise exception 'A link can only close as expired or cancelled.';
  end if;
  update public.online_payment_intents
  set status = case when status in ('link_pending', 'link_created') then p_status else status end,
      provider_cancelled_at = coalesce(provider_cancelled_at, now()),
      superseded_reason = coalesce(superseded_reason, p_reason),
      updated_at = now()
  where id = p_intent_id;
  perform private.online_audit('link_closed', p_intent_id, null, null,
    jsonb_build_object('status', p_status, 'reason', p_reason));
end;
$$;

revoke all on function public.online_payment_link_closed(uuid, text, text) from public, anon, authenticated;
grant execute on function public.online_payment_link_closed(uuid, text, text) to service_role;

-- ---------------------------------------------------------------- inbox

-- Record a verified webhook. Returns false for a duplicate event id.
create or replace function public.online_payment_record_event(
  p_provider_event_id text,
  p_event_type text,
  p_account_id text,
  p_provider_payment_id text,
  p_provider_link_id text,
  p_payload_sha256 text,
  p_facts jsonb
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_id uuid;
begin
  insert into public.online_payment_events (
    provider_event_id, event_type, account_id, provider_payment_id, provider_link_id,
    payload_sha256, facts
  )
  values (
    p_provider_event_id, p_event_type, p_account_id, p_provider_payment_id, p_provider_link_id,
    p_payload_sha256, coalesce(p_facts, '{}'::jsonb)
  )
  on conflict (provider_event_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.online_payment_events where provider_event_id = p_provider_event_id;
    return jsonb_build_object('id', v_id, 'duplicate', true);
  end if;
  return jsonb_build_object('id', v_id, 'duplicate', false);
end;
$$;

revoke all on function public.online_payment_record_event(text, text, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.online_payment_record_event(text, text, text, text, text, text, jsonb)
  to service_role;

-- ---------------------------------------------------------------- captures

-- Record a payment the server has FETCHED from the provider and found
-- captured. Never called with a webhook body, a browser redirect or anything
-- a parent typed. Idempotent on the provider payment id.
create or replace function public.online_payment_record_capture(p_facts jsonb)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_payment_id text := nullif(trim(p_facts->>'provider_payment_id'), '');
  v_link_id text := nullif(trim(p_facts->>'provider_link_id'), '');
  v_reference_id text := nullif(trim(p_facts->>'reference_id'), '');
  v_mode text := p_facts->>'provider_mode';
  v_amount bigint := (p_facts->>'amount_paise')::bigint;
  v_currency text := upper(coalesce(p_facts->>'currency', ''));
  v_intent public.online_payment_intents;
  v_capture public.online_payment_captures;
  v_reasons text[] := '{}';
begin
  if v_payment_id is null or v_payment_id !~ '^pay_[A-Za-z0-9]+$' then
    raise exception 'A capture needs a provider payment id.';
  end if;
  if coalesce(p_facts->>'provider_status', '') <> 'captured'
     or coalesce((p_facts->>'captured')::boolean, false) is not true then
    -- Authorised-only, failed or refunded money is not recorded as a capture.
    return jsonb_build_object('recorded', false, 'reason', 'not_captured');
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'A capture needs a positive amount.';
  end if;

  select * into v_capture from public.online_payment_captures where provider_payment_id = v_payment_id;
  if v_capture.id is not null then
    return jsonb_build_object('recorded', true, 'duplicate', true, 'capture', to_jsonb(v_capture));
  end if;

  if v_link_id is not null then
    select * into v_intent from public.online_payment_intents where provider_link_id = v_link_id;
  end if;
  if v_intent.id is null and v_reference_id is not null then
    select * into v_intent from public.online_payment_intents where provider_reference_id = v_reference_id;
  end if;

  if v_intent.id is null then
    v_reasons := array_append(v_reasons, 'unknown_link');
  else
    if v_intent.provider_mode <> v_mode then v_reasons := array_append(v_reasons, 'wrong_mode'); end if;
    if v_currency <> v_intent.currency then v_reasons := array_append(v_reasons, 'wrong_currency'); end if;
    if v_amount <> v_intent.amount_paise then v_reasons := array_append(v_reasons, 'wrong_amount'); end if;
  end if;
  -- The ledger holds whole rupees. A fractional rupee is quarantined, never rounded.
  if v_amount % 100 <> 0 then v_reasons := array_append(v_reasons, 'fractional_rupee'); end if;

  insert into public.online_payment_captures (
    provider_payment_id, intent_id, provider_link_id, provider_mode, amount_paise, currency,
    provider_status, method, fee_paise, tax_paise, captured_at,
    application_status, review_reason
  )
  values (
    v_payment_id, v_intent.id, v_link_id, v_mode, v_amount, v_currency,
    p_facts->>'provider_status', nullif(p_facts->>'method', ''),
    nullif(p_facts->>'fee_paise', '')::bigint, nullif(p_facts->>'tax_paise', '')::bigint,
    coalesce(nullif(p_facts->>'captured_at', '')::timestamptz, now()),
    case when cardinality(v_reasons) = 0 then 'pending' else 'review_required' end,
    nullif(array_to_string(v_reasons, ','), '')
  )
  on conflict (provider_payment_id) do nothing
  returning * into v_capture;

  if v_capture.id is null then
    select * into v_capture from public.online_payment_captures where provider_payment_id = v_payment_id;
    return jsonb_build_object('recorded', true, 'duplicate', true, 'capture', to_jsonb(v_capture));
  end if;

  if v_intent.id is not null and v_intent.status in ('link_pending', 'link_created') then
    update public.online_payment_intents
    set status = case when cardinality(v_reasons) = 0 then 'paid' else 'review_required' end,
        updated_at = now()
    where id = v_intent.id;
  end if;

  perform private.online_audit('capture_recorded', v_intent.id, v_capture.id, null,
    jsonb_build_object('amount_paise', v_amount, 'method', p_facts->>'method',
                       'review', v_capture.review_reason));

  return jsonb_build_object('recorded', true, 'duplicate', false, 'capture', to_jsonb(v_capture));
end;
$$;

revoke all on function public.online_payment_record_capture(jsonb) from public, anon, authenticated;
grant execute on function public.online_payment_record_capture(jsonb) to service_role;

-- Post a recorded capture through the posting engine, once.
--
-- One transaction: the student's lock, the intent, the capture, a fresh quote
-- as of the day the money was captured, the posting, the receipt, the intent
-- marked accounted and the receipt notice queued. If the fresh quote is not
-- the one the parent paid against, nothing is posted and the capture waits
-- for a person, marked `review_required`.
create or replace function public.online_payment_apply_capture(
  p_capture_id uuid,
  p_actor text default 'system'
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_capture public.online_payment_captures;
  v_intent public.online_payment_intents;
  v_student_id uuid;
  v_payment_date date;
  v_quote jsonb;
  v_reason text;
  v_receipt_id uuid;
  v_receipt_number text;
begin
  -- Lock order everywhere money moves: the student first (the same advisory
  -- key the desk takes), then the intent, then the capture.
  select intent.student_id into v_student_id
  from public.online_payment_captures as capture
  join public.online_payment_intents as intent on intent.id = capture.intent_id
  where capture.id = p_capture_id;

  if v_student_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_student_id::text, 0));
  end if;

  select * into v_capture from public.online_payment_captures where id = p_capture_id for update;
  if v_capture.id is null then
    raise exception 'Unknown capture.';
  end if;
  if v_capture.application_status = 'applied' then
    return jsonb_build_object('applied', true, 'duplicate', true, 'receipt_id', v_capture.receipt_id);
  end if;
  if v_capture.application_status <> 'pending' then
    return jsonb_build_object('applied', false, 'status', v_capture.application_status,
                              'reason', v_capture.review_reason);
  end if;

  select * into v_intent from public.online_payment_intents where id = v_capture.intent_id for update;

  v_payment_date := (coalesce(v_capture.captured_at, now()) at time zone 'Asia/Kolkata')::date;

  if v_intent.id is null then
    v_reason := 'unknown_link';
  elsif v_capture.amount_paise <> v_intent.amount_paise or v_capture.amount_paise % 100 <> 0 then
    v_reason := 'wrong_amount';
  elsif v_intent.status in ('accounted') then
    v_reason := 'intent_already_accounted';
  else
    v_quote := private.online_payment_quote(
      v_intent.student_id, v_intent.scope_installment_nos,
      v_intent.scope_include_carry_forward, v_payment_date
    );
    if not coalesce((v_quote->>'eligible')::boolean, false) then
      v_reason := 'dues_changed:' || coalesce(v_quote->>'reasons', '');
    elsif v_quote->>'hash' <> v_intent.quote_hash then
      v_reason := 'dues_changed';
    end if;
  end if;

  if v_reason is not null then
    update public.online_payment_captures
    set application_status = 'review_required', review_reason = v_reason, updated_at = now()
    where id = v_capture.id;
    if v_intent.id is not null and v_intent.status not in ('accounted') then
      update public.online_payment_intents set status = 'review_required', updated_at = now()
      where id = v_intent.id;
    end if;
    perform private.online_audit('capture_needs_review', v_intent.id, v_capture.id, null,
      jsonb_build_object('reason', v_reason), p_actor);
    return jsonb_build_object('applied', false, 'status', 'review_required', 'reason', v_reason);
  end if;

  perform set_config('vpps.online_capture_id', v_capture.id::text, true);
  perform set_config('vpps.online_intent_id', v_intent.id::text, true);

  begin
    select core.receipt_id, core.receipt_number
    into v_receipt_id, v_receipt_number
    from private.post_student_payment_core(
      v_intent.student_id,
      v_payment_date,
      'online'::payment_mode,
      v_intent.amount_rupees,
      v_capture.provider_payment_id,
      'Online payment via Razorpay · ' || v_intent.public_ref,
      'Razorpay (online)',
      'SVP',
      -- Deterministic per provider payment: the engine's own idempotency key.
      md5('razorpay:' || v_capture.provider_payment_id)::uuid,
      0,
      0
    ) as core;
  exception when others then
    perform set_config('vpps.online_capture_id', '', true);
    perform set_config('vpps.online_intent_id', '', true);
    update public.online_payment_captures
    set application_status = 'review_required',
        review_reason = left('posting_refused: ' || sqlerrm, 300),
        updated_at = now()
    where id = v_capture.id;
    update public.online_payment_intents set status = 'review_required', updated_at = now()
    where id = v_intent.id;
    perform private.online_audit('capture_needs_review', v_intent.id, v_capture.id, null,
      jsonb_build_object('reason', 'posting_refused', 'error', left(sqlerrm, 300)), p_actor);
    return jsonb_build_object('applied', false, 'status', 'review_required', 'reason', 'posting_refused');
  end;

  perform set_config('vpps.online_capture_id', '', true);
  perform set_config('vpps.online_intent_id', '', true);

  update public.online_payment_captures
  set application_status = 'applied', receipt_id = v_receipt_id, applied_at = now(),
      review_reason = null, updated_at = now()
  where id = v_capture.id;

  update public.online_payment_intents
  set status = 'accounted', receipt_id = v_receipt_id, accounted_at = now(), updated_at = now()
  where id = v_intent.id;

  insert into public.notification_outbox (kind, dedupe_key, receipt_id, student_id, session_label, payload)
  values (
    'receipt_notice', 'receipt_notice:' || v_receipt_id::text, v_receipt_id, v_intent.student_id,
    v_intent.session_label,
    jsonb_build_object('receipt_number', v_receipt_number, 'amount', v_intent.amount_rupees,
                       'payment_date', v_payment_date)
  )
  on conflict (dedupe_key) do nothing;

  perform private.online_audit('capture_applied', v_intent.id, v_capture.id, null,
    jsonb_build_object('receipt_id', v_receipt_id, 'receipt_number', v_receipt_number,
                       'amount_rupees', v_intent.amount_rupees, 'payment_date', v_payment_date),
    p_actor);

  return jsonb_build_object('applied', true, 'duplicate', false, 'receipt_id', v_receipt_id,
                            'receipt_number', v_receipt_number);
end;
$$;

revoke all on function public.online_payment_apply_capture(uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_apply_capture(uuid, text) to service_role;

-- A person decided what to do with a capture in review. Recorded, never
-- deleted: a refund or a manual posting is its own separately authorised act.
create or replace function public.online_payment_resolve_review(
  p_capture_id uuid,
  p_staff_id uuid,
  p_note text
)
returns void
language plpgsql
set search_path = public, private
as $$
begin
  if coalesce(trim(p_note), '') = '' then
    raise exception 'Say what was done with this payment.';
  end if;
  update public.online_payment_captures
  set resolved_by = p_staff_id, resolved_at = now(), resolution_note = left(p_note, 500),
      updated_at = now()
  where id = p_capture_id and application_status = 'review_required';
  perform private.online_audit('review_resolved', null, p_capture_id, null,
    jsonb_build_object('note', left(p_note, 300)), coalesce(p_staff_id::text, 'staff'));
end;
$$;

revoke all on function public.online_payment_resolve_review(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_resolve_review(uuid, uuid, text) to service_role;

-- ---------------------------------------------------------------- outbox

create or replace function public.notification_outbox_claim(p_limit integer, p_lease_seconds integer)
returns setof public.notification_outbox
language sql
set search_path = public
as $$
  update public.notification_outbox as outbox
  set status = 'processing',
      locked_until = now() + make_interval(secs => greatest(p_lease_seconds, 30)),
      attempts = outbox.attempts + 1,
      updated_at = now()
  where outbox.id in (
    select candidate.id
    from public.notification_outbox as candidate
    where (
        candidate.status in ('queued', 'failed')
        and candidate.next_attempt_at <= now()
        and candidate.attempts < candidate.max_attempts
      )
      or (candidate.status = 'processing' and candidate.locked_until < now())
    order by candidate.next_attempt_at
    limit greatest(least(p_limit, 50), 1)
    for update skip locked
  )
  returning outbox.*;
$$;

revoke all on function public.notification_outbox_claim(integer, integer) from public, anon, authenticated;
grant execute on function public.notification_outbox_claim(integer, integer) to service_role;

create or replace function public.notification_outbox_complete(
  p_id uuid,
  p_status text,
  p_provider_message_id text,
  p_error text,
  p_retry_in_seconds integer
)
returns void
language sql
set search_path = public
as $$
  update public.notification_outbox
  set status = p_status,
      provider_message_id = coalesce(p_provider_message_id, provider_message_id),
      last_error = left(p_error, 500),
      locked_until = null,
      next_attempt_at = case
        when p_status = 'failed' then now() + make_interval(secs => greatest(coalesce(p_retry_in_seconds, 600), 60))
        else next_attempt_at
      end,
      updated_at = now()
  where id = p_id;
$$;

revoke all on function public.notification_outbox_complete(uuid, text, text, text, integer) from public, anon, authenticated;
grant execute on function public.notification_outbox_complete(uuid, text, text, text, integer) to service_role;

-- ---------------------------------------------------------------- reconciliation

-- Every captured rupee is either on a receipt or in front of a person.
create or replace view public.v_online_payment_reconciliation
with (security_invoker = true)
as
select
  (capture.captured_at at time zone 'Asia/Kolkata')::date as captured_on,
  capture.provider_mode,
  count(*) as captures,
  sum(capture.amount_paise) as captured_paise,
  count(*) filter (where capture.application_status = 'applied') as applied,
  coalesce(sum(capture.amount_paise) filter (where capture.application_status = 'applied'), 0) as applied_paise,
  count(*) filter (where capture.application_status = 'review_required') as in_review,
  coalesce(sum(capture.amount_paise) filter (where capture.application_status = 'review_required'), 0) as in_review_paise,
  count(*) filter (where capture.application_status = 'pending') as awaiting_posting,
  coalesce(sum(capture.amount_paise) filter (where capture.application_status = 'pending'), 0) as awaiting_posting_paise,
  coalesce(sum(receipt.total_amount)::bigint * 100, 0) as receipted_paise,
  coalesce(sum(capture.fee_paise), 0) as provider_fee_paise,
  coalesce(sum(capture.tax_paise), 0) as provider_tax_paise
from public.online_payment_captures as capture
left join public.receipts as receipt on receipt.id = capture.receipt_id
group by 1, 2;

revoke all on public.v_online_payment_reconciliation from anon, authenticated;
grant select on public.v_online_payment_reconciliation to service_role;

-- ---------------------------------------------------------------- the timer

create or replace function public.online_payments_cron_secret_matches(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select ds.decrypted_secret = p_secret
      from vault.decrypted_secrets ds
      where ds.name = 'VPPS_ONLINE_PAYMENTS_CRON_SECRET'
      limit 1
    ),
    false
  );
$$;

revoke all on function public.online_payments_cron_secret_matches(text) from public;
revoke all on function public.online_payments_cron_secret_matches(text) from anon, authenticated;
grant execute on function public.online_payments_cron_secret_matches(text) to service_role;

-- Every ten minutes: retry the inbox, reconcile open links, cancel superseded
-- ones, drain the receipt outbox. A route with nothing to do answers in one
-- round trip. Silent until Vault holds VPPS_ONLINE_PAYMENTS_CRON_SECRET, so a
-- preview branch or the dev project never calls production.
-- [VPPS One] cron.unschedule block removed (see header).

-- [VPPS One] cron.schedule block removed (see header).

commit;

-- ======================================================== fee-migrations/20261029020128_online_payments_server_grants.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261029020128_online_payments_server_grants.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- The server role gets exactly what the online-payments design gives it.
--
-- `20261028140100` granted service_role SELECT, INSERT, UPDATE (and only
-- SELECT, INSERT on the audit) without first revoking what Supabase's default
-- privileges hand every new table in `public`: ALL, including DELETE and
-- TRUNCATE. On production the five tables therefore allowed both. TRUNCATE
-- matters most on the audit, because it skips the append-only row trigger.
-- Nothing in the app deletes from these tables; money records are kept, not
-- removed.
--
-- The schoolfees-dev project has no such default, which is why the dry run there
-- saw "permission denied" and production did not.

begin;

revoke all on public.online_payment_intents,
              public.online_payment_events,
              public.online_payment_captures,
              public.notification_outbox,
              public.online_payment_audit
  from service_role;

grant select, insert, update on public.online_payment_intents,
                                 public.online_payment_events,
                                 public.online_payment_captures,
                                 public.notification_outbox
  to service_role;

grant select, insert on public.online_payment_audit to service_role;

commit;

-- ======================================================== fee-migrations/20261029030619_guarded_staff_reads_not_callable_by_anon.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261029030619_guarded_staff_reads_not_callable_by_anon.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- Two guarded staff reads stop being callable with the browser key.
--
-- Supabase's security advisor on production (2026-10-29) reported that `anon`
-- can execute public.get_dashboard_analytics(text) and
-- public.preview_workbook_payment_allocation(uuid, date). Both are SECURITY
-- DEFINER and both carried `=X/postgres`: EXECUTE for PUBLIC, which `anon` is
-- part of.
--
-- Neither leaked anything. get_dashboard_analytics raises unless the caller is
-- service_role or has dashboard:view / finance:view, and the preview filters
-- every row on a permission list. Called over REST with the publishable key on
-- production, the first answered "You do not have permission to read dashboard
-- analytics." and the second [] for a student the engine owes five rows on.
-- This takes away the grant those guards were covering for, so a later rebuild
-- that loses a guard does not hand the browser key a family's dues.
--
-- How the grant came back: 20260523164957 ran `alter default privileges in
-- schema public revoke execute on functions from public`. A per-schema default
-- can only add to the global one, never take away from it, and the global
-- default gives PUBLIC EXECUTE on every new function. So every `create function`
-- in public comes out callable by PUBLIC: 20260812150000 created the analytics
-- read, and 20260812120000 and 20260905064847 dropped and recreated the preview,
-- each granting authenticated and service_role without revoking PUBLIC.
-- **A migration that creates or drops-and-recreates a function in public must
-- revoke EXECUTE from public, anon in the same file.**
--
-- Keeps EXECUTE: authenticated (Payment Desk preview, the system-sync health
-- probe, the dashboard when no service key is set) and service_role (the
-- dashboard's cache-safe client, the MCP worker, scripts). Loses it: anon, and
-- the roles that only had it through PUBLIC (notion_fee_sync_role,
-- dashboard_user, the Supabase platform roles). No view, function, cron job or
-- edge function calls either one as those roles.
--
-- Function bodies are untouched. Rollback:
--   grant execute on function public.get_dashboard_analytics(text) to public;
--   grant execute on function public.preview_workbook_payment_allocation(uuid, date) to public;

begin;

revoke execute on function public.get_dashboard_analytics(text) from public, anon;
revoke execute on function public.preview_workbook_payment_allocation(uuid, date) from public, anon;

grant execute on function public.get_dashboard_analytics(text) to authenticated, service_role;
grant execute on function public.preview_workbook_payment_allocation(uuid, date) to authenticated, service_role;

commit;

-- ======================================================== fee-migrations/20261029190000_online_payment_orders.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261029190000_online_payment_orders.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- One-tap online payment: Razorpay Orders + Standard Checkout on /pay/[code].
--
-- The parent sees each child's full fee breakdown, sets an amount per child
-- (₹100 minimum, at most that child's whole remaining balance for the session),
-- and pays all of it in ONE Razorpay checkout. Each child is then an ordinary
-- individual posting through `private.post_student_payment_core`, with its own
-- receipt. Nothing here posts for a family as one: every child is posted alone.
--
-- ADDITIVE. The Payment Link path (`online_payment_intents`, `open_intent`,
-- `record_capture`, `apply_capture`, the supersede trigger) is untouched, as are
-- `private.post_student_payment_core` and the desk RPC. The one replaced money
-- function is `private.online_posting_in_progress`, which gains an order branch;
-- its legacy branch is kept word for word.
--
-- THE POSTING RULE FOR ORDERS IS "STILL FITS", deliberately not "same quote".
-- A custom amount has no quote to compare. Each child's line posts when
-- 0 < line <= what that child still owes on the capture date — the same ceiling
-- the core enforces. Time only ever adds late fees, so a line stops fitting only
-- after a counter payment, a waiver or a fee edit; then the WHOLE capture goes
-- to review and no child is posted (all-or-nothing).

begin;

-- ---------------------------------------------------------------- switches

insert into public.app_settings (key, value) values
  ('online_payment_checkout_enabled', 'false'),
  ('online_payment_order_max_rupees', '100000')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- tables

-- One row per tap on "Pay": a Razorpay Order for the total of the lines.
create table public.online_payment_orders (
  id uuid primary key default gen_random_uuid(),
  public_ref text not null unique check (public_ref ~ '^[A-Za-z0-9_-]{20,64}$'),
  provider text not null default 'razorpay' check (provider = 'razorpay'),
  provider_mode text not null check (provider_mode in ('test', 'live')),
  send_id uuid not null references public.whatsapp_reminder_sends (id),
  status text not null default 'pending' check (status in (
    'pending', 'open', 'paid', 'accounted', 'review_required', 'superseded', 'abandoned', 'failed'
  )),
  amount_rupees integer not null check (amount_rupees >= 1),
  amount_paise bigint generated always as (amount_rupees::bigint * 100) stored,
  currency text not null default 'INR' check (currency = 'INR'),
  provider_receipt text not null unique check (char_length(provider_receipt) <= 40),
  provider_order_id text unique check (provider_order_id is null or provider_order_id ~ '^order_[A-Za-z0-9]+$'),
  last_error text,
  superseded_reason text,
  last_reconciled_at timestamptz,
  accounted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index online_payment_orders_send_idx on public.online_payment_orders (send_id, created_at desc);
create index online_payment_orders_watch_idx on public.online_payment_orders (status, created_at)
  where status in ('pending', 'open', 'superseded', 'paid');

comment on table public.online_payment_orders is
  'One Razorpay Order per tap on Pay on /pay/[code]. Money records: never deleted.';

-- One row per child on an order. Each carries its own receipt once posted.
create table public.online_payment_order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.online_payment_orders (id),
  line_no smallint not null check (line_no between 1 and 4),
  student_id uuid not null references public.students (id),
  session_label text not null,
  amount_rupees integer not null check (amount_rupees >= 1),
  max_rupees integer not null check (max_rupees >= amount_rupees),
  receipt_id uuid unique references public.receipts (id),
  created_at timestamptz not null default now(),
  unique (order_id, student_id),
  unique (order_id, line_no)
);

create index online_payment_order_lines_student_idx on public.online_payment_order_lines (student_id);

-- A capture belongs to an intent (Payment Link) OR to an order, never both.
-- An order capture's receipts are on its lines; its own receipt_id stays null.
alter table public.online_payment_captures
  add column order_id uuid references public.online_payment_orders (id),
  add column provider_order_id text;
alter table public.online_payment_captures
  add constraint online_payment_captures_one_target check (intent_id is null or order_id is null);
create index online_payment_captures_order_idx on public.online_payment_captures (order_id)
  where order_id is not null;

alter table public.online_payment_orders enable row level security;
alter table public.online_payment_order_lines enable row level security;

-- Production's default privileges grant service_role ALL on new tables.
-- Money records take no DELETE or TRUNCATE from anyone.
revoke all on table public.online_payment_orders from public, anon, authenticated, service_role;
revoke all on table public.online_payment_order_lines from public, anon, authenticated, service_role;
grant select, insert, update on table public.online_payment_orders to service_role;
grant select, insert, update on table public.online_payment_order_lines to service_role;

-- ---------------------------------------------------------------- what a child owes

-- Everything the child still owes this session, as the posting core counts it:
-- the sum of `total_pending` over every owed row (last year's balance, every
-- installment including future ones, late fees). The most a line may carry.
create or replace function private.online_student_owed(p_student_id uuid, p_as_of date)
returns integer
language sql
stable
set search_path = public, private
as $$
  select coalesce(sum(snapshot_row.total_pending) filter (where snapshot_row.total_pending > 0), 0)::integer
  from private.workbook_installment_snapshot(p_student_id, p_as_of, true) as snapshot_row;
$$;

revoke all on function private.online_student_owed(uuid, date) from public, anon, authenticated;
grant execute on function private.online_student_owed(uuid, date) to service_role;

-- ---------------------------------------------------------------- the pay page

-- Everything the parent's page shows, for one send. Service role only: the page
-- is public and reaches this only through the send's 160-bit pay code.
--
-- Per child it returns the FIRST NAME and class only — never the admission
-- number, a parent's name or a phone — and every installment row, paid ones
-- included, with fees and late fee kept apart.
--
-- `clear_to_date` is what clears everything due up to the horizon: the later of
-- today and the last due date among the installments the reminder named. The
-- page pre-fills it. `whole_session` is the most a line may carry.
create or replace function public.online_payment_pay_page(p_send_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public, private
as $$
declare
  v_send record;
  v_ids uuid[];
  v_scope_nos smallint[];
  v_today date := private.ist_today();
  v_children jsonb := '[]'::jsonb;
  v_index integer := 0;
  v_student_id uuid;
  v_child jsonb;
  v_horizon date;
  v_orders jsonb;
begin
  select id, session_label, pay_scope, created_at
  into v_send
  from public.whatsapp_reminder_sends
  where id = p_send_id;
  if v_send.id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_send');
  end if;

  select coalesce(array_agg(value::uuid order by ordinality), '{}')
  into v_ids
  from jsonb_array_elements_text(coalesce(v_send.pay_scope->'studentIds', '[]'::jsonb)) with ordinality;

  select coalesce(array_agg(value::smallint), '{}')
  into v_scope_nos
  from jsonb_array_elements_text(coalesce(v_send.pay_scope->'installments', '[]'::jsonb));

  if cardinality(v_ids) < 1 or cardinality(v_ids) > 4 then
    return jsonb_build_object('ok', false, 'reason', 'scope_size', 'children', cardinality(v_ids));
  end if;

  foreach v_student_id in array v_ids loop
    select greatest(v_today, coalesce(max(snapshot_row.due_date), v_today))
    into v_horizon
    from private.workbook_installment_snapshot(v_student_id, v_today, true) as snapshot_row
    join public.installments as installment on installment.id = snapshot_row.installment_id
    where not coalesce(installment.is_carry_forward, false)
      and snapshot_row.installment_no = any(v_scope_nos);

    select jsonb_build_object(
      'index', v_index,
      'first_name', split_part(trim(coalesce(student.full_name, '')), ' ', 1),
      'class_label', coalesce(max(snapshot_row.class_label), max(snapshot_row.class_name), ''),
      'session_label', v_send.session_label,
      'rows', coalesce(jsonb_agg(jsonb_build_object(
          'installment_no', snapshot_row.installment_no,
          'label', snapshot_row.installment_label,
          'due_date', snapshot_row.due_date,
          'carry_forward', coalesce(installment.is_carry_forward, false),
          'charged', snapshot_row.base_charge,
          'paid', coalesce(snapshot_row.fee_settled_amount, 0),
          'fees_pending', snapshot_row.pending_amount,
          'late_fee', coalesce(snapshot_row.final_late_fee, 0),
          'late_fee_paid', coalesce(snapshot_row.late_fee_settled_amount, 0),
          'late_fee_pending', snapshot_row.late_fee_pending,
          'total_pending', snapshot_row.total_pending,
          'status', snapshot_row.balance_status
        ) order by coalesce(installment.is_carry_forward, false) desc, snapshot_row.due_date, snapshot_row.installment_no)
        filter (where snapshot_row.installment_id is not null), '[]'::jsonb),
      'last_year_pending', coalesce(sum(snapshot_row.total_pending) filter (
          where coalesce(installment.is_carry_forward, false) and snapshot_row.total_pending > 0), 0),
      'fees_pending', coalesce(sum(snapshot_row.pending_amount) filter (
          where not coalesce(installment.is_carry_forward, false) and snapshot_row.pending_amount > 0), 0),
      'late_fee_pending', coalesce(sum(snapshot_row.late_fee_pending) filter (
          where snapshot_row.late_fee_pending > 0), 0),
      'clear_to_date', coalesce(sum(snapshot_row.total_pending) filter (
          where snapshot_row.total_pending > 0 and snapshot_row.due_date <= v_horizon), 0),
      'whole_session', coalesce(sum(snapshot_row.total_pending) filter (
          where snapshot_row.total_pending > 0), 0)
    )
    into v_child
    from public.students as student
    left join private.workbook_installment_snapshot(v_student_id, v_today, true) as snapshot_row on true
    left join public.installments as installment on installment.id = snapshot_row.installment_id
    where student.id = v_student_id
    group by student.id, student.full_name;

    v_children := v_children || jsonb_build_array(coalesce(v_child, jsonb_build_object('index', v_index)));
    v_index := v_index + 1;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
      'public_ref', o.public_ref,
      'status', o.status,
      'amount_rupees', o.amount_rupees,
      'created_at', o.created_at,
      'receipts', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'line_no', line.line_no,
            'receipt_number', receipt.receipt_number,
            'amount', receipt.total_amount
          ) order by line.line_no), '[]'::jsonb)
        from public.online_payment_order_lines as line
        join public.receipts as receipt on receipt.id = line.receipt_id
        where line.order_id = o.id
      )
    ) order by o.created_at desc), '[]'::jsonb)
  into v_orders
  from (
    select * from public.online_payment_orders
    where send_id = p_send_id
    order by created_at desc
    limit 5
  ) as o;

  return jsonb_build_object(
    'ok', true,
    'session_label', v_send.session_label,
    'sent_at', v_send.created_at,
    'today', v_today,
    'children', v_children,
    'orders', v_orders,
    'checkout_enabled', private.online_setting_on('online_payment_checkout_enabled')
      and private.online_setting_on('online_payment_links_enabled'),
    'min_line_rupees', 100,
    'order_max_rupees', coalesce((
      select nullif(value, '')::integer from public.app_settings where key = 'online_payment_order_max_rupees'
    ), 100000)
  );
end;
$$;

revoke all on function public.online_payment_pay_page(uuid) from public, anon, authenticated;
grant execute on function public.online_payment_pay_page(uuid) to service_role;

-- ---------------------------------------------------------------- opening an order

-- A tap on Pay. Lines arrive as [{index, amount_rupees}] — an index into the
-- send's own pay_scope.studentIds, never a student id from the browser.
create or replace function public.online_payment_open_order(
  p_send_id uuid,
  p_lines jsonb,
  p_provider_mode text,
  p_public_ref text
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_send record;
  v_ids uuid[];
  v_today date := private.ist_today();
  v_cap integer;
  v_line record;
  v_seen integer[] := '{}';
  v_total integer := 0;
  v_owed integer;
  v_min integer;
  v_student_id uuid;
  v_order public.online_payment_orders;
  v_line_no smallint := 0;
  v_lines jsonb := '[]'::jsonb;
  v_lock uuid;
begin
  if not (private.online_setting_on('online_payment_checkout_enabled')
          and private.online_setting_on('online_payment_links_enabled')) then
    return jsonb_build_object('ok', false, 'reason', 'switched_off');
  end if;
  if p_provider_mode not in ('test', 'live') then
    raise exception 'Unknown provider mode.';
  end if;

  select id, session_label, pay_scope into v_send
  from public.whatsapp_reminder_sends where id = p_send_id;
  if v_send.id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_send');
  end if;

  select coalesce(array_agg(value::uuid order by ordinality), '{}')
  into v_ids
  from jsonb_array_elements_text(coalesce(v_send.pay_scope->'studentIds', '[]'::jsonb)) with ordinality;
  if cardinality(v_ids) < 1 or cardinality(v_ids) > 4 then
    return jsonb_build_object('ok', false, 'reason', 'scope_size');
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 1
     or jsonb_array_length(p_lines) > cardinality(v_ids) then
    return jsonb_build_object('ok', false, 'reason', 'no_lines');
  end if;

  if (select count(*) from public.online_payment_orders
      where send_id = p_send_id and created_at > now() - interval '1 hour') >= 15 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_orders');
  end if;

  v_cap := coalesce((
    select nullif(value, '')::integer from public.app_settings where key = 'online_payment_order_max_rupees'
  ), 100000);

  -- Every child's lock, in one fixed order, before any figure is read. The desk
  -- takes the same key, so a counter payment and this cannot interleave.
  for v_lock in select distinct unnest(v_ids) order by 1 loop
    perform pg_advisory_xact_lock(hashtextextended(v_lock::text, 0));
  end loop;

  for v_line in
    select (entry->>'index')::integer as idx, (entry->>'amount_rupees')::numeric as amount
    from jsonb_array_elements(p_lines) as entry
  loop
    if v_line.idx is null or v_line.idx < 0 or v_line.idx >= cardinality(v_ids) or v_line.idx = any(v_seen) then
      return jsonb_build_object('ok', false, 'reason', 'bad_line');
    end if;
    v_seen := array_append(v_seen, v_line.idx);
    if v_line.amount is null or v_line.amount <> trunc(v_line.amount) then
      return jsonb_build_object('ok', false, 'reason', 'whole_rupees_only', 'index', v_line.idx);
    end if;
    v_student_id := v_ids[v_line.idx + 1];
    v_owed := private.online_student_owed(v_student_id, v_today);
    if v_owed <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'nothing_due', 'index', v_line.idx);
    end if;
    -- ₹100 at least, unless the child's whole balance is less: then exactly that.
    v_min := least(100, v_owed);
    if v_line.amount < v_min or v_line.amount > v_owed then
      return jsonb_build_object('ok', false, 'reason', 'amount_out_of_range', 'index', v_line.idx,
                                'min', v_min, 'max', v_owed);
    end if;
    v_total := v_total + v_line.amount::integer;
  end loop;

  if v_total < 1 or v_total > v_cap then
    return jsonb_build_object('ok', false, 'reason', 'order_over_cap', 'max', v_cap);
  end if;

  -- One live order per send: an earlier one the parent walked away from is
  -- superseded. Razorpay cannot cancel an order, so money that still lands on
  -- it is recorded and posted if it still fits (see apply_order_capture).
  update public.online_payment_orders
  set status = 'superseded', superseded_reason = 'new_order', updated_at = now()
  where send_id = p_send_id and status in ('pending', 'open');

  insert into public.online_payment_orders (public_ref, provider_mode, send_id, amount_rupees, provider_receipt)
  values (p_public_ref, p_provider_mode, p_send_id, v_total,
          'vpps_o_' || replace(gen_random_uuid()::text, '-', ''))
  returning * into v_order;

  for v_line in
    select (entry->>'index')::integer as idx, (entry->>'amount_rupees')::integer as amount
    from jsonb_array_elements(p_lines) as entry
    order by (entry->>'index')::integer
  loop
    v_line_no := v_line_no + 1;
    v_student_id := v_ids[v_line.idx + 1];
    insert into public.online_payment_order_lines (order_id, line_no, student_id, session_label, amount_rupees, max_rupees)
    values (v_order.id, v_line_no, v_student_id, v_send.session_label, v_line.amount,
            private.online_student_owed(v_student_id, v_today));
    v_lines := v_lines || jsonb_build_object('index', v_line.idx, 'amount_rupees', v_line.amount);
  end loop;

  perform private.online_audit('order_opened', null, null, null,
    jsonb_build_object('order_id', v_order.id, 'send_id', p_send_id, 'amount_rupees', v_total,
                       'lines', v_lines));

  return jsonb_build_object('ok', true, 'order', jsonb_build_object(
    'id', v_order.id,
    'public_ref', v_order.public_ref,
    'provider_receipt', v_order.provider_receipt,
    'amount_rupees', v_order.amount_rupees,
    'amount_paise', v_order.amount_paise
  ), 'lines', v_lines);
end;
$$;

revoke all on function public.online_payment_open_order(uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.online_payment_open_order(uuid, jsonb, text, text) to service_role;

create or replace function public.online_payment_order_recorded(p_order_id uuid, p_provider_order_id text)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_order public.online_payment_orders;
begin
  if p_provider_order_id is null or p_provider_order_id !~ '^order_[A-Za-z0-9]+$' then
    raise exception 'A Razorpay order id is required.';
  end if;
  update public.online_payment_orders
  set provider_order_id = p_provider_order_id,
      status = case when status = 'pending' then 'open' else status end,
      updated_at = now()
  where id = p_order_id
    and (provider_order_id is null or provider_order_id = p_provider_order_id)
  returning * into v_order;
  if v_order.id is null then
    raise exception 'Order not found, or already holds a different Razorpay order.';
  end if;
  perform private.online_audit('order_recorded', null, null, null,
    jsonb_build_object('order_id', v_order.id, 'provider_order_id', p_provider_order_id));
  return to_jsonb(v_order);
end;
$$;

revoke all on function public.online_payment_order_recorded(uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_order_recorded(uuid, text) to service_role;

-- An order that never reached Razorpay, or reached it with no id we kept: no
-- browser ever held its id, so it cannot be paid. The next tap opens a new one.
create or replace function public.online_payment_order_failed(p_order_id uuid, p_error text)
returns void
language sql
set search_path = public, private
as $$
  update public.online_payment_orders
  set status = 'failed', last_error = left(coalesce(p_error, ''), 300), updated_at = now()
  where id = p_order_id and status = 'pending';
$$;

revoke all on function public.online_payment_order_failed(uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_order_failed(uuid, text) to service_role;

-- Stop watching an order nobody paid. Still recorded and posted if money ever lands.
create or replace function public.online_payment_order_closed(p_order_id uuid, p_status text)
returns void
language plpgsql
set search_path = public, private
as $$
begin
  if p_status not in ('abandoned', 'failed') then
    raise exception 'An order closes as abandoned or failed.';
  end if;
  update public.online_payment_orders
  set status = p_status, updated_at = now()
  where id = p_order_id and status in ('pending', 'open', 'superseded');
end;
$$;

revoke all on function public.online_payment_order_closed(uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_order_closed(uuid, text) to service_role;

-- ---------------------------------------------------------------- order captures

-- Record a payment the server FETCHED from Razorpay, found captured, and whose
-- `order_id` is one of our orders. Idempotent on the payment id.
create or replace function public.online_payment_record_order_capture(p_facts jsonb)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_payment_id text := nullif(trim(p_facts->>'provider_payment_id'), '');
  v_order_id text := nullif(trim(p_facts->>'provider_order_id'), '');
  v_mode text := p_facts->>'provider_mode';
  v_amount bigint := (p_facts->>'amount_paise')::bigint;
  v_currency text := upper(coalesce(p_facts->>'currency', ''));
  v_order public.online_payment_orders;
  v_capture public.online_payment_captures;
  v_reasons text[] := '{}';
begin
  if v_payment_id is null or v_payment_id !~ '^pay_[A-Za-z0-9]+$' then
    raise exception 'A capture needs a provider payment id.';
  end if;
  if v_order_id is null or v_order_id !~ '^order_[A-Za-z0-9]+$' then
    raise exception 'An order capture needs a Razorpay order id.';
  end if;
  if coalesce(p_facts->>'provider_status', '') <> 'captured'
     or coalesce((p_facts->>'captured')::boolean, false) is not true then
    return jsonb_build_object('recorded', false, 'reason', 'not_captured');
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'A capture needs a positive amount.';
  end if;

  select * into v_capture from public.online_payment_captures where provider_payment_id = v_payment_id;
  if v_capture.id is not null then
    return jsonb_build_object('recorded', true, 'duplicate', true, 'capture', to_jsonb(v_capture));
  end if;

  select * into v_order from public.online_payment_orders where provider_order_id = v_order_id for update;
  if v_order.id is null then
    v_reasons := array_append(v_reasons, 'unknown_order');
  else
    if v_order.provider_mode <> v_mode then v_reasons := array_append(v_reasons, 'wrong_mode'); end if;
    if v_currency <> v_order.currency then v_reasons := array_append(v_reasons, 'wrong_currency'); end if;
    if v_amount <> v_order.amount_paise then v_reasons := array_append(v_reasons, 'wrong_amount'); end if;
    if v_order.status = 'accounted' then v_reasons := array_append(v_reasons, 'order_already_accounted'); end if;
  end if;
  if v_amount % 100 <> 0 then v_reasons := array_append(v_reasons, 'fractional_rupee'); end if;

  insert into public.online_payment_captures (
    provider_payment_id, intent_id, order_id, provider_order_id, provider_link_id, provider_mode,
    amount_paise, currency, provider_status, method, fee_paise, tax_paise, captured_at,
    application_status, review_reason
  )
  values (
    v_payment_id, null, v_order.id, v_order_id, null, v_mode,
    v_amount, v_currency, p_facts->>'provider_status', nullif(p_facts->>'method', ''),
    nullif(p_facts->>'fee_paise', '')::bigint, nullif(p_facts->>'tax_paise', '')::bigint,
    coalesce(nullif(p_facts->>'captured_at', '')::timestamptz, now()),
    case when cardinality(v_reasons) = 0 then 'pending' else 'review_required' end,
    nullif(array_to_string(v_reasons, ','), '')
  )
  on conflict (provider_payment_id) do nothing
  returning * into v_capture;

  if v_capture.id is null then
    select * into v_capture from public.online_payment_captures where provider_payment_id = v_payment_id;
    return jsonb_build_object('recorded', true, 'duplicate', true, 'capture', to_jsonb(v_capture));
  end if;

  if v_order.id is not null and v_order.status <> 'accounted' then
    update public.online_payment_orders
    set status = case when cardinality(v_reasons) = 0 then 'paid' else 'review_required' end,
        updated_at = now()
    where id = v_order.id;
  end if;

  perform private.online_audit('capture_recorded', null, v_capture.id, null,
    jsonb_build_object('order_id', v_order.id, 'amount_paise', v_amount, 'method', p_facts->>'method',
                       'review', v_capture.review_reason));

  return jsonb_build_object('recorded', true, 'duplicate', false, 'capture', to_jsonb(v_capture));
end;
$$;

revoke all on function public.online_payment_record_order_capture(jsonb) from public, anon, authenticated;
grant execute on function public.online_payment_record_order_capture(jsonb) to service_role;

-- Who may reach the core without a staff permission. The legacy branch below
-- is the 20261028140100 text, unchanged; the order branch admits exactly the
-- students on the order of the verified, unapplied capture named in
-- `vpps.online_capture_id` for this transaction.
create or replace function private.online_posting_in_progress(p_student_id uuid)
returns boolean
language plpgsql
stable
set search_path = public, private
as $$
declare
  v_capture_id uuid;
begin
  if current_user not in ('service_role', 'postgres') then
    return false;
  end if;
  begin
    v_capture_id := nullif(current_setting('vpps.online_capture_id', true), '')::uuid;
  exception when others then
    return false;
  end;
  if v_capture_id is null then
    return false;
  end if;
  return exists (
    select 1
    from public.online_payment_captures as capture
    join public.online_payment_intents as intent on intent.id = capture.intent_id
    where capture.id = v_capture_id
      and capture.application_status = 'pending'
      and intent.student_id = p_student_id
  ) or exists (
    select 1
    from public.online_payment_captures as capture
    join public.online_payment_order_lines as line on line.order_id = capture.order_id
    where capture.id = v_capture_id
      and capture.application_status = 'pending'
      and line.student_id = p_student_id
  );
end;
$$;

revoke all on function private.online_posting_in_progress(uuid) from public, anon;
grant execute on function private.online_posting_in_progress(uuid) to authenticated, service_role;

-- Post a recorded order capture: every child's line, or none.
--
-- One transaction: every child's lock in a fixed order, the capture, the order,
-- the "still fits" check per line as of the day the money was captured, then
-- each line through the posting core inside ONE exception block — so a refusal
-- on any child rolls back every child's receipt and the capture waits for a
-- person. One receipt notice is queued per child.
create or replace function public.online_payment_apply_order_capture(
  p_capture_id uuid,
  p_actor text default 'system'
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_capture public.online_payment_captures;
  v_order public.online_payment_orders;
  v_line record;
  v_lock uuid;
  v_payment_date date;
  v_reason text;
  v_receipt_id uuid;
  v_receipt_number text;
  v_receipts jsonb := '[]'::jsonb;
begin
  for v_lock in
    select distinct line.student_id
    from public.online_payment_captures as capture
    join public.online_payment_order_lines as line on line.order_id = capture.order_id
    where capture.id = p_capture_id
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_lock::text, 0));
  end loop;

  select * into v_capture from public.online_payment_captures where id = p_capture_id for update;
  if v_capture.id is null then
    raise exception 'Unknown capture.';
  end if;
  if v_capture.application_status = 'applied' then
    return jsonb_build_object('applied', true, 'duplicate', true);
  end if;
  if v_capture.application_status <> 'pending' then
    return jsonb_build_object('applied', false, 'status', v_capture.application_status,
                              'reason', v_capture.review_reason);
  end if;

  select * into v_order from public.online_payment_orders where id = v_capture.order_id for update;
  v_payment_date := (coalesce(v_capture.captured_at, now()) at time zone 'Asia/Kolkata')::date;

  if v_order.id is null then
    v_reason := 'unknown_order';
  elsif v_capture.amount_paise <> v_order.amount_paise or v_capture.amount_paise % 100 <> 0 then
    v_reason := 'wrong_amount';
  elsif v_order.status = 'accounted' then
    v_reason := 'order_already_accounted';
  elsif (select coalesce(sum(amount_rupees), 0) from public.online_payment_order_lines where order_id = v_order.id)
        <> v_order.amount_rupees then
    v_reason := 'lines_do_not_add_up';
  else
    for v_line in
      select line.line_no, line.student_id, line.amount_rupees
      from public.online_payment_order_lines as line
      where line.order_id = v_order.id
      order by line.line_no
    loop
      if v_line.amount_rupees > private.online_student_owed(v_line.student_id, v_payment_date) then
        v_reason := 'dues_changed:line_' || v_line.line_no;
        exit;
      end if;
    end loop;
  end if;

  if v_reason is not null then
    update public.online_payment_captures
    set application_status = 'review_required', review_reason = v_reason, updated_at = now()
    where id = v_capture.id;
    if v_order.id is not null and v_order.status <> 'accounted' then
      update public.online_payment_orders set status = 'review_required', updated_at = now()
      where id = v_order.id;
    end if;
    perform private.online_audit('capture_needs_review', null, v_capture.id, null,
      jsonb_build_object('order_id', v_order.id, 'reason', v_reason), p_actor);
    return jsonb_build_object('applied', false, 'status', 'review_required', 'reason', v_reason);
  end if;

  perform set_config('vpps.online_capture_id', v_capture.id::text, true);

  begin
    for v_line in
      select line.id, line.line_no, line.student_id, line.session_label, line.amount_rupees
      from public.online_payment_order_lines as line
      where line.order_id = v_order.id
      order by line.line_no
    loop
      select core.receipt_id, core.receipt_number
      into v_receipt_id, v_receipt_number
      from private.post_student_payment_core(
        v_line.student_id,
        v_payment_date,
        'online'::payment_mode,
        v_line.amount_rupees,
        v_capture.provider_payment_id,
        'Online payment via Razorpay · ' || v_order.public_ref,
        'Razorpay (online)',
        'SVP',
        -- Deterministic per payment AND child: the engine's own idempotency key.
        md5('razorpay:' || v_capture.provider_payment_id || ':' || v_line.student_id::text)::uuid,
        0,
        0
      ) as core;

      update public.online_payment_order_lines set receipt_id = v_receipt_id where id = v_line.id;

      insert into public.notification_outbox (kind, dedupe_key, receipt_id, student_id, session_label, payload)
      values (
        'receipt_notice', 'receipt_notice:' || v_receipt_id::text, v_receipt_id, v_line.student_id,
        v_line.session_label,
        jsonb_build_object('receipt_number', v_receipt_number, 'amount', v_line.amount_rupees,
                           'payment_date', v_payment_date)
      )
      on conflict (dedupe_key) do nothing;

      v_receipts := v_receipts || jsonb_build_object(
        'line_no', v_line.line_no, 'student_id', v_line.student_id, 'session_label', v_line.session_label,
        'receipt_id', v_receipt_id, 'receipt_number', v_receipt_number, 'amount_rupees', v_line.amount_rupees
      );
    end loop;
  exception when others then
    perform set_config('vpps.online_capture_id', '', true);
    update public.online_payment_captures
    set application_status = 'review_required',
        review_reason = left('posting_refused: ' || sqlerrm, 300),
        updated_at = now()
    where id = v_capture.id;
    update public.online_payment_orders set status = 'review_required', updated_at = now()
    where id = v_order.id;
    perform private.online_audit('capture_needs_review', null, v_capture.id, null,
      jsonb_build_object('order_id', v_order.id, 'reason', 'posting_refused', 'error', left(sqlerrm, 300)),
      p_actor);
    return jsonb_build_object('applied', false, 'status', 'review_required', 'reason', 'posting_refused');
  end;

  perform set_config('vpps.online_capture_id', '', true);

  update public.online_payment_captures
  set application_status = 'applied', applied_at = now(), review_reason = null, updated_at = now()
  where id = v_capture.id;

  update public.online_payment_orders
  set status = 'accounted', accounted_at = now(), updated_at = now()
  where id = v_order.id;

  perform private.online_audit('capture_applied', null, v_capture.id, null,
    jsonb_build_object('order_id', v_order.id, 'payment_date', v_payment_date, 'receipts', v_receipts),
    p_actor);

  return jsonb_build_object('applied', true, 'duplicate', false, 'receipts', v_receipts);
end;
$$;

revoke all on function public.online_payment_apply_order_capture(uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_apply_order_capture(uuid, text) to service_role;

-- ---------------------------------------------------------------- reconciliation

-- Same columns as before. An order capture's receipts sit on its lines, so
-- "receipted" counts those too; a Payment Link capture is counted as before.
create or replace view public.v_online_payment_reconciliation
with (security_invoker = true)
as
select
  (capture.captured_at at time zone 'Asia/Kolkata')::date as captured_on,
  capture.provider_mode,
  count(*) as captures,
  sum(capture.amount_paise) as captured_paise,
  count(*) filter (where capture.application_status = 'applied') as applied,
  coalesce(sum(capture.amount_paise) filter (where capture.application_status = 'applied'), 0) as applied_paise,
  count(*) filter (where capture.application_status = 'review_required') as in_review,
  coalesce(sum(capture.amount_paise) filter (where capture.application_status = 'review_required'), 0) as in_review_paise,
  count(*) filter (where capture.application_status = 'pending') as awaiting_posting,
  coalesce(sum(capture.amount_paise) filter (where capture.application_status = 'pending'), 0) as awaiting_posting_paise,
  coalesce(sum(coalesce(receipt.total_amount, order_receipts.total))::bigint * 100, 0) as receipted_paise,
  coalesce(sum(capture.fee_paise), 0) as provider_fee_paise,
  coalesce(sum(capture.tax_paise), 0) as provider_tax_paise
from public.online_payment_captures as capture
left join public.receipts as receipt on receipt.id = capture.receipt_id
left join lateral (
  select sum(line_receipt.total_amount) as total
  from public.online_payment_order_lines as line
  join public.receipts as line_receipt on line_receipt.id = line.receipt_id
  where line.order_id = capture.order_id
) as order_receipts on capture.order_id is not null
group by 1, 2;

revoke all on public.v_online_payment_reconciliation from anon, authenticated;
grant select on public.v_online_payment_reconciliation to service_role;

commit;

-- ======================================================== migrations/20261030112133_deployment_marker.sql
-- Which kind of database this is, said by the database itself (D-338, D-346).
--
-- wtgxcptmucjerhufzjcf is One's main database AND its only test bed: there is
-- no separate dev project, ever (owner, 30 Oct). "Is this the dev ref?" can no
-- longer tell a guard whether it may write test data, because the dev ref IS
-- production from go-live on. So the database carries one row that says so:
--
--   vppsone.deployment.environment = 'dev'         today
--                                  = 'production'  set by the orchestrator at
--                                                  go-live (Phase 1 lockdown)
--
-- Every QA, smoke-lab, day-run and seed tool reads it. While it says
-- 'production' (and whenever it cannot be read — fail closed), those tools are
-- CONFINED, not banned: they may only create or change test accounts and
-- TEST-session data. `vppsone.is_production()` is the SQL half, used by the fee
-- writes switch (supabase/fee-migrations/…_fee_writes_guard.sql).
--
-- Also here:
--  * staff_profiles.is_test_account — the flag the tools confine themselves to.
--    Phase 3 (PR-3) builds the visibility rules and converts the QA accounts;
--    this migration only adds the column (default false: nobody is a test
--    account until somebody says so) and stops a signed-in user from changing
--    it, so a test admin cannot clear its own flag (critique0 #14).
--  * is_test_session_label(text) — the one SQL definition of "a test session"
--    (TEST-, UAT-, DEMO- prefixes, the same set as isTestAcademicSessionLabel()
--    in src/platform/config/fee-rules.ts).
--  * one_owned_fee_settings — fee-schema settings One owns on this database,
--    which the mirror sync (Phase 2) must never overwrite from the fees app.
--
-- Rollback:
--   drop trigger staff_profiles_test_flag_guard on vppsone.staff_profiles;
--   drop function vppsone.staff_profiles_test_flag_guard();
--   alter table vppsone.staff_profiles drop column is_test_account;
--   drop function vppsone.is_production(); drop function vppsone.is_test_session_label(text);
--   drop table vppsone.one_owned_fee_settings;
--   drop trigger deployment_stamp on vppsone.deployment; drop function vppsone.deployment_stamp();
--   drop table vppsone.deployment_history; drop table vppsone.deployment;

create table vppsone.deployment (
  id smallint primary key default 1 check (id = 1),
  environment text not null check (environment in ('dev', 'production')),
  changed_at timestamptz not null default now(),
  changed_by text not null default current_user
);

comment on table vppsone.deployment is
  'One row: is this database production? Read by every QA/seed/smoke guard; unreadable means production (D-346).';

create table vppsone.deployment_history (
  id bigint generated always as identity primary key,
  environment text not null,
  changed_at timestamptz not null,
  changed_by text not null
);

comment on table vppsone.deployment_history is
  'Every value vppsone.deployment has held, appended by its trigger.';

-- changed_at / changed_by are stamped, not trusted, and every value is kept.
create or replace function vppsone.deployment_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'vppsone.deployment is never deleted; update its environment instead.';
  end if;
  new.changed_at := now();
  new.changed_by := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
    session_user::text
  );
  insert into vppsone.deployment_history (environment, changed_at, changed_by)
  values (new.environment, new.changed_at, new.changed_by);
  return new;
end;
$$;

create trigger deployment_stamp
  before insert or update or delete on vppsone.deployment
  for each row execute function vppsone.deployment_stamp();

insert into vppsone.deployment (id, environment) values (1, 'dev');

alter table vppsone.deployment enable row level security;
alter table vppsone.deployment_history enable row level security;
revoke all on vppsone.deployment from public, anon, authenticated;
revoke all on vppsone.deployment_history from public, anon, authenticated;
-- Read by the service role only. Changing it is an owner step done as postgres
-- (SQL editor / MCP), never from the app.
grant select on vppsone.deployment to service_role;
grant select on vppsone.deployment_history to service_role;

create or replace function vppsone.is_production()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- No row, or anything but 'dev', reads as production: fail closed.
  select coalesce((select d.environment <> 'dev' from vppsone.deployment d where d.id = 1), true);
$$;

comment on function vppsone.is_production() is
  'True unless vppsone.deployment says dev. Fail closed (D-346).';

revoke all on function vppsone.is_production() from public, anon, authenticated;
grant execute on function vppsone.is_production() to service_role;
revoke all on function vppsone.deployment_stamp() from public, anon, authenticated;

create or replace function vppsone.is_test_session_label(p_label text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_label ~* '^(test|uat|demo)-[0-9]{4}-[0-9]{2}$', false);
$$;

comment on function vppsone.is_test_session_label(text) is
  'A rehearsal session label (TEST-2026-27). Same prefixes as isTestAcademicSessionLabel() in fee-rules.ts.';

grant execute on function vppsone.is_test_session_label(text) to authenticated, service_role;

/* ------------------------------------------------------------ test accounts */

alter table vppsone.staff_profiles
  add column is_test_account boolean not null default false;

comment on column vppsone.staff_profiles.is_test_account is
  'A test account: sees and writes TEST sessions only (PR-3). QA tooling on production acts only on these (D-346). Changed by the service role only.';

-- A signed-in user never changes the flag, in either direction — not their
-- own and not anybody else's. The service role (scripts, the app's admin
-- client after its own permission check) and postgres can.
create or replace function vppsone.staff_profiles_test_flag_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_role text := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
begin
  if v_role in ('authenticated', 'anon') then
    if tg_op = 'UPDATE' and new.is_test_account is distinct from old.is_test_account then
      raise exception 'is_test_account is changed by an administrator tool, not from a signed-in session.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger staff_profiles_test_flag_guard
  before update on vppsone.staff_profiles
  for each row execute function vppsone.staff_profiles_test_flag_guard();

revoke all on function vppsone.staff_profiles_test_flag_guard() from public, anon, authenticated;

/* ------------------------------------------------- settings One owns here */

create table vppsone.one_owned_fee_settings (
  source_table text not null check (source_table ~ '^[a-z_]+$'),
  row_key text not null check (char_length(row_key) between 1 and 200),
  column_name text not null check (column_name ~ '^[a-z_]+$'),
  reason text not null check (char_length(reason) between 1 and 500),
  created_at timestamptz not null default now(),
  primary key (source_table, row_key, column_name)
);

comment on table vppsone.one_owned_fee_settings is
  'Fee-schema values One owns on this database. The mirror sync (Phase 2) never overwrites these from the fees app.';

alter table vppsone.one_owned_fee_settings enable row level security;
revoke all on vppsone.one_owned_fee_settings from public, anon, authenticated;
grant select, insert, update, delete on vppsone.one_owned_fee_settings to service_role;

insert into vppsone.one_owned_fee_settings (source_table, row_key, column_name, reason) values
  ('app_settings', 'fee_writes_enabled', 'value',
   'The fee writes switch (D-345). Set by One''s owner at T0; the fees app has no such key.');

-- ======================================================== migrations/20261030112221_migration_ledger.sql
-- The migration's own bookkeeping (plan §2.1, I-8): what ran, what it mapped,
-- and how far each source has been read.
--
-- Every importer in scripts/migrate/* (Phase 2) is idempotent, dry-run by
-- default, and writes one row here per run. Nothing in the app reads these;
-- they are for the operator and for the importers themselves:
--
--  * migration_runs        one row per run of any migrate script: which
--                          script, dry run or apply, which source project and
--                          snapshot, when it started and finished, how it
--                          ended, and its counts/sums/hashes (never personal
--                          data — I-5). A `cutover` row locks out
--                          load-snapshot for good (plan §2.3).
--  * migration_id_map      source id -> target id for every row an importer
--                          had to re-key (quarantine shells, test-session
--                          copies), so a second run finds the same target and
--                          reconcile can exclude them (plan §2.5).
--  * migration_watermarks  how far each source table has been read, as the
--                          snapshot id and the now() read inside it — never a
--                          wall-clock time recorded beforehand (critique0 #6).
--
-- Service role only: no policy, nothing granted to anon or authenticated.
--
-- Rollback:
--   drop table vppsone.migration_watermarks;
--   drop table vppsone.migration_id_map;
--   drop table vppsone.migration_runs;

create table vppsone.migration_runs (
  id uuid primary key default gen_random_uuid(),
  script text not null check (script ~ '^[a-z0-9][a-z0-9_.-]{0,80}$'),
  kind text not null default 'run' check (kind in ('run', 'dry_run', 'cutover', 'rollback')),
  source_project text not null check (source_project ~ '^[a-z]{20}$'),
  target_project text not null check (target_project ~ '^[a-z]{20}$'),
  snapshot_id text check (snapshot_id is null or char_length(snapshot_id) <= 200),
  snapshot_at timestamptz,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'succeeded', 'failed', 'refused')),
  -- Counts, sums and hashes only. Never a name, phone or row (I-5).
  summary jsonb not null default '{}'::jsonb,
  note text check (note is null or char_length(note) <= 1000),
  run_by text not null default session_user,
  check (finished_at is null or finished_at >= started_at),
  check (status = 'running' or finished_at is not null)
);

comment on table vppsone.migration_runs is
  'One row per run of a scripts/migrate/* tool (plan §2.1). A cutover row locks out load-snapshot.';

create index migration_runs_script_started on vppsone.migration_runs (script, started_at desc);

-- At most one cutover, ever.
create unique index migration_runs_one_cutover on vppsone.migration_runs ((kind)) where kind = 'cutover';

create table vppsone.migration_id_map (
  source_project text not null check (source_project ~ '^[a-z]{20}$'),
  source_table text not null check (source_table ~ '^[a-z_]+\.[a-z_]+$'),
  source_id text not null check (char_length(source_id) between 1 and 200),
  target_id text not null check (char_length(target_id) between 1 and 200),
  batch_id uuid references vppsone.migration_runs (id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (source_project, source_table, source_id)
);

comment on table vppsone.migration_id_map is
  'Source row -> target row for every row an importer re-keyed (plan §2.1). Reconcile excludes and counts these.';

create index migration_id_map_target on vppsone.migration_id_map (source_table, target_id);
create index migration_id_map_batch on vppsone.migration_id_map (batch_id);

create table vppsone.migration_watermarks (
  source_project text not null check (source_project ~ '^[a-z]{20}$'),
  source_table text not null check (source_table ~ '^[a-z_]+\.[a-z_]+$'),
  snapshot_id text not null check (char_length(snapshot_id) between 1 and 200),
  -- now() read inside the exported snapshot's own transaction.
  snapshot_at timestamptz not null,
  run_id uuid references vppsone.migration_runs (id) on delete restrict,
  row_count bigint check (row_count is null or row_count >= 0),
  content_md5 text check (content_md5 is null or content_md5 ~ '^[0-9a-f]{32}$'),
  updated_at timestamptz not null default now(),
  primary key (source_project, source_table)
);

comment on table vppsone.migration_watermarks is
  'How far each source table has been read: the snapshot itself, not a wall-clock time (critique0 #6).';

alter table vppsone.migration_runs enable row level security;
alter table vppsone.migration_id_map enable row level security;
alter table vppsone.migration_watermarks enable row level security;

revoke all on vppsone.migration_runs from public, anon, authenticated;
revoke all on vppsone.migration_id_map from public, anon, authenticated;
revoke all on vppsone.migration_watermarks from public, anon, authenticated;

grant select, insert, update on vppsone.migration_runs to service_role;
grant select, insert, update, delete on vppsone.migration_id_map to service_role;
grant select, insert, update, delete on vppsone.migration_watermarks to service_role;

-- ======================================================== fee-migrations/20261030120000_online_payment_late_fee_policy.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261030120000_online_payment_late_fee_policy.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- Late fees are not taken online this year (owner, 2026-10-30).
--
-- When a parent pays through the one-tap pay page, every late fee charged on
-- that child this session is forgiven — the ones still owed AND the ones the
-- family already paid — and the payment goes to fees. Money already paid
-- against a late fee then settles the child's fees, oldest installment first,
-- exactly as an admin's "forgive a collected late fee" does (20260826120000).
-- Next year the school takes late fees again: turn
-- `online_payment_waive_late_fees` off.
--
-- Scope, as the owner chose it: online one-tap orders only. The Payment Desk,
-- the Payment Link path (`online_payment_apply_capture`) and every WhatsApp
-- reminder are unchanged.
--
-- How:
--  1. `student_late_fee_waivers.source` gains 'online_payment', so these
--     waivers are told apart from a person's.
--  2. `private.online_student_owed` — the ceiling an order opens under and the
--     "still fits" check at posting — subtracts the child's late fees while the
--     setting is on. That is what the child owes once they are forgiven.
--  3. `private.online_waive_late_fees` forgives them, per installment,
--     idempotently per payment.
--  4. `online_payment_apply_order_capture` calls it for each child just before
--     posting that child, inside the same exception block: a posting that is
--     refused takes its waiver back with it.
--
-- `post_student_payment_core`, the desk RPC, `waive_late_fee` and the Payment
-- Link functions are untouched. Rollback: `…_rollback.sql.txt`.

begin;

-- ---------------------------------------------------------------- 1. the source

alter table public.student_late_fee_waivers drop constraint student_late_fee_waivers_source_check;
alter table public.student_late_fee_waivers add constraint student_late_fee_waivers_source_check
  check (source = any (array[
    'manual', 'payment_desk', 'migration', 'grandfather', 'repayment_plan', 'manual_collected', 'online_payment'
  ]));

-- ---------------------------------------------------------------- the switch, on

insert into public.app_settings (key, value) values ('online_payment_waive_late_fees', 'true')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 2. what a child owes

-- Everything the child still owes this session, as the posting core counts it:
-- the sum of `total_pending` over every owed row. While late fees are waived on
-- online payment, less every late fee the child is charged (`final_late_fee`,
-- already net of earlier waivers): the pending part disappears, and the part
-- already paid moves onto the child's fees. The most a line may carry.
create or replace function private.online_student_owed(p_student_id uuid, p_as_of date)
returns integer
language sql
stable
set search_path = public, private
as $$
  select greatest(
    0,
    coalesce(sum(snapshot_row.total_pending) filter (where snapshot_row.total_pending > 0), 0)
    - case
        when private.online_setting_on('online_payment_waive_late_fees')
          then coalesce(sum(greatest(snapshot_row.final_late_fee, 0)), 0)
        else 0
      end
  )::integer
  from private.workbook_installment_snapshot(p_student_id, p_as_of, true) as snapshot_row;
$$;

revoke all on function private.online_student_owed(uuid, date) from public, anon, authenticated;
grant execute on function private.online_student_owed(uuid, date) to service_role;

-- ---------------------------------------------------------------- 3. forgiving them

-- Every late fee on this child's installments, the collected ones included, one
-- waiver per installment. `final_late_fee` is net of earlier waivers, so a
-- second run finds nothing; the request id makes a replayed payment a no-op on
-- its own as well. Returns the rupees forgiven.
create or replace function private.online_waive_late_fees(p_student_id uuid, p_payment_id text, p_as_of date)
returns integer
language plpgsql
set search_path = public, private
as $$
declare
  v_row record;
  v_request uuid;
  v_total integer := 0;
begin
  for v_row in
    select
      snapshot_row.installment_id,
      snapshot_row.session_label,
      greatest(snapshot_row.final_late_fee, 0)::integer as amount,
      greatest(snapshot_row.late_fee_pending, 0)::integer as still_owed
    from private.workbook_installment_snapshot(p_student_id, p_as_of, true) as snapshot_row
    where snapshot_row.installment_id is not null
      and greatest(snapshot_row.final_late_fee, 0) > 0
    order by snapshot_row.due_date, snapshot_row.installment_no
  loop
    v_request := md5('online-late-fee:' || p_payment_id || ':' || v_row.installment_id::text)::uuid;
    if exists (
      select 1 from public.student_late_fee_waivers
      where student_id = p_student_id and client_request_id = v_request and voided_at is null
    ) then
      continue;
    end if;

    insert into public.student_late_fee_waivers (
      student_id, installment_id, session_label, amount, reason, source, client_request_id, waived_by_label
    ) values (
      p_student_id, v_row.installment_id, v_row.session_label, v_row.amount,
      format(
        'Waived on online payment %s: late fees are not taken this year (owner, 2026-10-30)%s',
        p_payment_id,
        case
          when v_row.amount > v_row.still_owed
            then format('. %s of it was already paid and now counts toward fees', v_row.amount - v_row.still_owed)
          else ''
        end
      ),
      'online_payment', v_request, 'Online payment (automatic)'
    );
    v_total := v_total + v_row.amount;
  end loop;
  return v_total;
end;
$$;

revoke all on function private.online_waive_late_fees(uuid, text, date) from public, anon, authenticated;
grant execute on function private.online_waive_late_fees(uuid, text, date) to service_role;

-- ---------------------------------------------------------------- 4. posting an order

-- As 20261029190000, plus the waiver: for each child, just before that child is
-- posted, while `online_payment_waive_late_fees` is on.
create or replace function public.online_payment_apply_order_capture(
  p_capture_id uuid,
  p_actor text default 'system'
)
returns jsonb
language plpgsql
set search_path = public, private
as $$
declare
  v_capture public.online_payment_captures;
  v_order public.online_payment_orders;
  v_line record;
  v_lock uuid;
  v_payment_date date;
  v_reason text;
  v_receipt_id uuid;
  v_receipt_number text;
  v_receipts jsonb := '[]'::jsonb;
  v_waive boolean := private.online_setting_on('online_payment_waive_late_fees');
  v_waived integer;
begin
  for v_lock in
    select distinct line.student_id
    from public.online_payment_captures as capture
    join public.online_payment_order_lines as line on line.order_id = capture.order_id
    where capture.id = p_capture_id
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_lock::text, 0));
  end loop;

  select * into v_capture from public.online_payment_captures where id = p_capture_id for update;
  if v_capture.id is null then
    raise exception 'Unknown capture.';
  end if;
  if v_capture.application_status = 'applied' then
    return jsonb_build_object('applied', true, 'duplicate', true);
  end if;
  if v_capture.application_status <> 'pending' then
    return jsonb_build_object('applied', false, 'status', v_capture.application_status,
                              'reason', v_capture.review_reason);
  end if;

  select * into v_order from public.online_payment_orders where id = v_capture.order_id for update;
  v_payment_date := (coalesce(v_capture.captured_at, now()) at time zone 'Asia/Kolkata')::date;

  if v_order.id is null then
    v_reason := 'unknown_order';
  elsif v_capture.amount_paise <> v_order.amount_paise or v_capture.amount_paise % 100 <> 0 then
    v_reason := 'wrong_amount';
  elsif v_order.status = 'accounted' then
    v_reason := 'order_already_accounted';
  elsif (select coalesce(sum(amount_rupees), 0) from public.online_payment_order_lines where order_id = v_order.id)
        <> v_order.amount_rupees then
    v_reason := 'lines_do_not_add_up';
  else
    -- What each child owes once their late fees are forgiven (online_student_owed).
    for v_line in
      select line.line_no, line.student_id, line.amount_rupees
      from public.online_payment_order_lines as line
      where line.order_id = v_order.id
      order by line.line_no
    loop
      if v_line.amount_rupees > private.online_student_owed(v_line.student_id, v_payment_date) then
        v_reason := 'dues_changed:line_' || v_line.line_no;
        exit;
      end if;
    end loop;
  end if;

  if v_reason is not null then
    update public.online_payment_captures
    set application_status = 'review_required', review_reason = v_reason, updated_at = now()
    where id = v_capture.id;
    if v_order.id is not null and v_order.status <> 'accounted' then
      update public.online_payment_orders set status = 'review_required', updated_at = now()
      where id = v_order.id;
    end if;
    perform private.online_audit('capture_needs_review', null, v_capture.id, null,
      jsonb_build_object('order_id', v_order.id, 'reason', v_reason), p_actor);
    return jsonb_build_object('applied', false, 'status', 'review_required', 'reason', v_reason);
  end if;

  perform set_config('vpps.online_capture_id', v_capture.id::text, true);

  begin
    for v_line in
      select line.id, line.line_no, line.student_id, line.session_label, line.amount_rupees
      from public.online_payment_order_lines as line
      where line.order_id = v_order.id
      order by line.line_no
    loop
      -- This year a payment online forgives that child's late fees (owner,
      -- 2026-10-30): before posting, so the money goes to fees, and inside this
      -- block, so a refused posting takes the waiver back with it.
      v_waived := 0;
      if v_waive then
        v_waived := private.online_waive_late_fees(v_line.student_id, v_capture.provider_payment_id, v_payment_date);
      end if;

      select core.receipt_id, core.receipt_number
      into v_receipt_id, v_receipt_number
      from private.post_student_payment_core(
        v_line.student_id,
        v_payment_date,
        'online'::payment_mode,
        v_line.amount_rupees,
        v_capture.provider_payment_id,
        'Online payment via Razorpay · ' || v_order.public_ref,
        'Razorpay (online)',
        'SVP',
        -- Deterministic per payment AND child: the engine's own idempotency key.
        md5('razorpay:' || v_capture.provider_payment_id || ':' || v_line.student_id::text)::uuid,
        0,
        0
      ) as core;

      update public.online_payment_order_lines set receipt_id = v_receipt_id where id = v_line.id;

      insert into public.notification_outbox (kind, dedupe_key, receipt_id, student_id, session_label, payload)
      values (
        'receipt_notice', 'receipt_notice:' || v_receipt_id::text, v_receipt_id, v_line.student_id,
        v_line.session_label,
        jsonb_build_object('receipt_number', v_receipt_number, 'amount', v_line.amount_rupees,
                           'payment_date', v_payment_date)
      )
      on conflict (dedupe_key) do nothing;

      v_receipts := v_receipts || jsonb_build_object(
        'line_no', v_line.line_no, 'student_id', v_line.student_id, 'session_label', v_line.session_label,
        'receipt_id', v_receipt_id, 'receipt_number', v_receipt_number, 'amount_rupees', v_line.amount_rupees,
        'late_fee_waived', v_waived
      );
    end loop;
  exception when others then
    perform set_config('vpps.online_capture_id', '', true);
    update public.online_payment_captures
    set application_status = 'review_required',
        review_reason = left('posting_refused: ' || sqlerrm, 300),
        updated_at = now()
    where id = v_capture.id;
    update public.online_payment_orders set status = 'review_required', updated_at = now()
    where id = v_order.id;
    perform private.online_audit('capture_needs_review', null, v_capture.id, null,
      jsonb_build_object('order_id', v_order.id, 'reason', 'posting_refused', 'error', left(sqlerrm, 300)),
      p_actor);
    return jsonb_build_object('applied', false, 'status', 'review_required', 'reason', 'posting_refused');
  end;

  perform set_config('vpps.online_capture_id', '', true);

  update public.online_payment_captures
  set application_status = 'applied', applied_at = now(), review_reason = null, updated_at = now()
  where id = v_capture.id;

  update public.online_payment_orders
  set status = 'accounted', accounted_at = now(), updated_at = now()
  where id = v_order.id;

  perform private.online_audit('capture_applied', null, v_capture.id, null,
    jsonb_build_object('order_id', v_order.id, 'payment_date', v_payment_date, 'receipts', v_receipts),
    p_actor);

  return jsonb_build_object('applied', true, 'duplicate', false, 'receipts', v_receipts);
end;
$$;

revoke all on function public.online_payment_apply_order_capture(uuid, text) from public, anon, authenticated;
grant execute on function public.online_payment_apply_order_capture(uuid, text) to service_role;

commit;

-- ======================================================== migrations/20261030132121_tail_receipts_review.sql
-- Fees receipts posted after the cutover watermark wait here for a person,
-- instead of arriving as raw rows (plan §7.8 option b, §12.1; critique0 #8).
--
-- A fees `payments` row carries an allocation (installment_id,
-- pending_before_posting, pending_after_posting) computed on the FEES ledger.
-- Copied into One after One has posted its own receipts, the same rows can
-- over-settle an installment, and per-student figures stop matching either
-- system. So scripts/migrate/tail-sync.mjs never inserts a fees receipt or
-- payment into public. It records the receipt header here, with its fees
-- receipt number and client_request_id and the allocation as evidence
-- (ids and amounts only), and a person posts it through One's own engine —
-- or marks it a duplicate of a One receipt, or rejects it.
--
-- Idempotent: one row per fees receipt id. Service role only.
--
-- Rollback:
--   drop table vppsone.tail_receipts_review;

create table vppsone.tail_receipts_review (
  id uuid primary key default gen_random_uuid(),
  source_project text not null check (source_project ~ '^[a-z]{20}$'),
  fees_receipt_id uuid not null,
  receipt_number text not null check (char_length(receipt_number) between 1 and 40),
  student_id uuid not null,
  payment_date date not null,
  payment_mode text not null check (char_length(payment_mode) between 1 and 40),
  total_amount integer not null check (total_amount > 0),
  client_request_id uuid,
  reference_number text check (reference_number is null or char_length(reference_number) <= 200),
  fees_created_at timestamptz,
  -- Allocation rows, order lines and capture ids from the fees ledger: ids and
  -- amounts only, never a name or phone (I-5).
  evidence jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'posted', 'duplicate', 'rejected')),
  posted_receipt_id uuid,
  resolved_by text,
  resolved_at timestamptz,
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 1000),
  run_id uuid references vppsone.migration_runs (id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (source_project, fees_receipt_id),
  check ((status = 'pending') = (resolved_at is null)),
  check (status <> 'posted' or posted_receipt_id is not null)
);

comment on table vppsone.tail_receipts_review is
  'Fees receipts posted after the cutover watermark, waiting to be posted through One''s engine (critique0 #8). Never copied as raw payments.';

create index tail_receipts_review_pending on vppsone.tail_receipts_review (created_at) where status = 'pending';

alter table vppsone.tail_receipts_review enable row level security;
revoke all on vppsone.tail_receipts_review from public, anon, authenticated;
grant select, insert, update on vppsone.tail_receipts_review to service_role;

-- ======================================================== migrations/20261030145719_tail_receipts_review_grants.sql
-- The review queue is never deleted from or truncated over the API: rows
-- leave it only by being resolved (status), and a person's resolution is
-- the audit of a fees receipt posted after cutover. The vppsone default
-- privileges had granted service_role every table privilege; the intended
-- set is select, insert, update (20261030132121_tail_receipts_review.sql).
-- Pinned by tests/migrate-tooling.test.ts.
--
-- Rollback:
--   grant delete, truncate, references, trigger on vppsone.tail_receipts_review to service_role;

revoke delete, truncate, references, trigger on vppsone.tail_receipts_review from service_role;

-- ======================================================== migrations/20261030155339_test_session_visibility.sql
-- Who may see a test session (Phase 3, D-340; critique0 #13, #14, #15).
--
-- wtgxcptmucjerhufzjcf is production AND the only test bed (D-346, owner T1):
-- testing happens in TEST-2026-27, by test accounts
-- (staff_profiles.is_test_account, added by 20261030112133). The rule is one
-- sentence, and this file is its SQL half:
--
--   A test account sees and writes only test sessions; everybody else sees and
--   writes only real ones; a REAL admin (role admin AND not a test account)
--   sees and writes both.
--
-- The app half is src/platform/auth/test-session-access.ts. Both use the same
-- definition of "real admin" — the ROLE, not a permission (critique0 #14: the
-- permission matrix is editable, so a `settings:manage` predicate here and a
-- role check there could drift apart).
--
-- What this file adds:
--  * vppsone.is_test_session(label)       = is_test_session_label(label)
--  * vppsone.current_is_test_account()     the viewer's flag (false with no profile)
--  * vppsone.is_real_admin()               role admin, active, not a test account
--  * vppsone.can_see_test_sessions()       is_real_admin() or current_is_test_account()
--  * vppsone.set_test_account(id, value, reason)
--        the one way a signed-in person changes the flag: a real admin, never
--        on themselves, logged to staff_authority_changes.
--  * one RESTRICTIVE policy per session-labelled table (53 of them), USING and
--    WITH CHECK both
--        (is_test_session(session_label) = current_is_test_account()) or is_real_admin()
--    and the same, through an EXISTS join to the parent's label, on the 27
--    child tables and 7 grandchild tables that carry no label of their own (87 in all).
--
-- What it does NOT do. One's own writes are service role (D-179), which
-- bypasses RLS: these policies hold the PostgREST path (a signed-in browser
-- reading vppsone directly). The app's assertSessionWritable/Visible hold the
-- rest. And `public` (the fee tables) keeps the fees app's permission-only RLS
-- while mirror mode runs — a test account reading PostgREST directly could
-- see real fee rows. That is the accepted, owner-signed limit in plan §3.4.
--
-- staff_profiles_test_flag_guard is replaced: it used to refuse every change
-- under an `authenticated` JWT, which also refused set_test_account. It now
-- keys on the database role actually running the UPDATE: a direct PostgREST
-- update runs as `authenticated` and is refused; set_test_account runs as its
-- owner and is let through (it does its own, stricter checks).
--
-- Rollback:
--   drop policy test_session_fence on vppsone.<each table>;   (87 tables)
--   drop function vppsone.set_test_account(uuid, boolean, text);
--   drop function vppsone.can_see_test_sessions(); drop function vppsone.is_real_admin();
--   drop function vppsone.current_is_test_account(); drop function vppsone.is_test_session(text);
--   and restore staff_profiles_test_flag_guard from 20261030112133.

/* ------------------------------------------------------------- definitions */

create or replace function vppsone.is_test_session(p_label text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select vppsone.is_test_session_label(p_label);
$$;

comment on function vppsone.is_test_session(text) is
  'A rehearsal session label (TEST-/UAT-/DEMO-YYYY-YY). Same as isTestAcademicSessionLabel().';

create or replace function vppsone.current_is_test_account()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select sp.is_test_account from vppsone.staff_profiles sp
     where sp.user_id = (select auth.uid()) and sp.is_active),
    false
  );
$$;

comment on function vppsone.current_is_test_account() is
  'The signed-in staff member''s is_test_account (false without an active profile).';

create or replace function vppsone.is_real_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from vppsone.staff_profiles sp
    where sp.user_id = (select auth.uid())
      and sp.is_active
      and sp.role = 'admin'
      and not sp.is_test_account
  );
$$;

comment on function vppsone.is_real_admin() is
  'Role admin, active, and NOT a test account. A test admin is fenced to TEST like every test account (critique0 #14).';

create or replace function vppsone.can_see_test_sessions()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select vppsone.is_real_admin() or vppsone.current_is_test_account();
$$;

comment on function vppsone.can_see_test_sessions() is
  'May this viewer see test sessions at all: a real admin or a test account.';

revoke all on function vppsone.is_test_session(text) from public, anon;
revoke all on function vppsone.current_is_test_account() from public, anon;
revoke all on function vppsone.is_real_admin() from public, anon;
revoke all on function vppsone.can_see_test_sessions() from public, anon;
grant execute on function vppsone.is_test_session(text) to authenticated, service_role;
grant execute on function vppsone.current_is_test_account() to authenticated, service_role;
grant execute on function vppsone.is_real_admin() to authenticated, service_role;
grant execute on function vppsone.can_see_test_sessions() to authenticated, service_role;

/* ------------------------------------------------- changing the test flag */

-- `current_user` is the role executing the UPDATE: `authenticated` / `anon`
-- for a PostgREST request, the function owner inside set_test_account, and
-- `service_role` / `postgres` for the admin client and the SQL editor.

create or replace function vppsone.staff_profiles_test_flag_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and new.is_test_account is distinct from old.is_test_account then
    raise exception 'is_test_account is changed through vppsone.set_test_account, by a real administrator.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function vppsone.staff_profiles_test_flag_guard() from public, anon, authenticated;

/*
 * Mark or unmark a test account. The signed-in person must be a REAL admin
 * (role admin, active, not a test account), may not change their own flag,
 * and must give a reason. Logged to staff_authority_changes with the role and
 * active flag unchanged and the flag change spelt out in `reason`.
 *
 * Callable by `authenticated` (the actor is auth.uid(), not a parameter), so
 * the app calls it with the signed-in person's own client, after its own check.
 */
create or replace function vppsone.set_test_account(
  p_profile_id uuid,
  p_value boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor vppsone.staff_profiles%rowtype;
  target vppsone.staff_profiles%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if p_value is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:staff-authority'));

  select * into actor from vppsone.staff_profiles
  where user_id = (select auth.uid()) and is_active;
  if not found or actor.role <> 'admin' or actor.is_test_account then
    return jsonb_build_object('ok', false, 'reason', 'not_real_admin');
  end if;

  select * into target from vppsone.staff_profiles where id = p_profile_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if target.id = actor.id then
    return jsonb_build_object('ok', false, 'reason', 'self');
  end if;
  if target.is_test_account = p_value then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  update vppsone.staff_profiles set is_test_account = p_value where id = target.id;

  insert into vppsone.staff_authority_changes (
    staff_profile_id, actor_staff_id, from_role, to_role, from_active, to_active, reason
  ) values (
    target.id, actor.id, target.role, target.role, target.is_active, target.is_active,
    format('is_test_account: %s -> %s. %s', target.is_test_account, p_value, v_reason)
  );

  return jsonb_build_object('ok', true, 'changed', true);
end;
$$;

comment on function vppsone.set_test_account(uuid, boolean, text) is
  'Mark/unmark a test account: real admin only, never self, reason required, logged (critique0 #14).';

revoke all on function vppsone.set_test_account(uuid, boolean, text) from public, anon;
grant execute on function vppsone.set_test_account(uuid, boolean, text) to authenticated;

/* -------------------------------------------------- the fence, per table */

do $$
declare
  t text;
  labelled text[] := array[
    'academic_calendar_days', 'academic_exports', 'admission_details', 'archives',
    'assessments', 'attendance_registers', 'attendance_rules', 'bell_schedules',
    'calendar_events', 'calendar_notices', 'class_aliases', 'class_seats',
    'class_teachers', 'collection_requests', 'collection_rounds', 'cover_commands',
    'cover_days', 'cover_duties', 'cover_policies', 'drive_folders', 'enquiries',
    'enrolments', 'fee_call_promises', 'fee_day_close_events', 'fee_desk_requests',
    'fee_reminder_batches', 'message_campaigns', 'message_sends', 'notes',
    'parent_message_queue', 'parent_replies', 'report_card_issues',
    'report_card_remarks', 'report_cards', 'report_schemes', 'sampark_import_batches',
    'staff_notices', 'staff_scopes', 'student_documents', 'student_followups',
    'student_photos', 'student_record_history', 'student_records',
    'substitution_plans', 'support_plans', 'teacher_absence_history',
    'teacher_absences', 'teacher_leave', 'teacher_tasks', 'teaching_assignments',
    'team_supervision_rules', 'timetable_changes', 'timetable_versions'
  ];
  -- child table, its foreign-key column, the parent that carries the label
  children text[][] := array[
    ['assessment_subjects', 'assessment_id', 'assessments'],
    ['attendance_corrections', 'register_id', 'attendance_registers'],
    ['attendance_marks', 'register_id', 'attendance_registers'],
    ['attendance_register_revisions', 'register_id', 'attendance_registers'],
    ['collection_request_fields', 'request_id', 'collection_requests'],
    ['collection_request_members', 'request_id', 'collection_requests'],
    ['collection_round_fields', 'round_id', 'collection_rounds'],
    ['collection_submissions', 'request_id', 'collection_requests'],
    ['document_upload_sessions', 'document_id', 'student_documents'],
    ['exam_activity', 'assessment_id', 'assessments'],
    ['exam_class_locks', 'assessment_id', 'assessments'],
    ['exam_duties', 'assessment_id', 'assessments'],
    ['exam_marks_links', 'assessment_id', 'assessments'],
    ['exam_plans', 'assessment_id', 'assessments'],
    ['exam_reminders', 'assessment_id', 'assessments'],
    ['exam_seats', 'assessment_id', 'assessments'],
    ['exam_slots', 'assessment_id', 'assessments'],
    ['note_replies', 'note_id', 'notes'],
    ['parent_reply_answers', 'message_send_id', 'message_sends'],
    ['photo_proposals', 'request_id', 'collection_requests'],
    ['restore_drills', 'archive_id', 'archives'],
    ['sampark_import_rows', 'batch_id', 'sampark_import_batches'],
    ['staff_notice_attempts', 'notice_id', 'staff_notices'],
    ['staff_notice_reads', 'campaign_id', 'message_campaigns'],
    ['substitution_assignments', 'plan_id', 'substitution_plans'],
    ['support_plan_steps', 'plan_id', 'support_plans'],
    ['timetable_slots', 'version_id', 'timetable_versions']
  ];
  -- grandchild, its column, the child it points at, the child's column, the labelled parent
  grandchildren text[][] := array[
    ['marks', 'assessment_subject_id', 'assessment_subjects', 'assessment_id', 'assessments'],
    ['marks_change_log', 'assessment_subject_id', 'assessment_subjects', 'assessment_id', 'assessments'],
    ['marks_commands', 'assessment_subject_id', 'assessment_subjects', 'assessment_id', 'assessments'],
    ['exam_grace', 'paper_id', 'assessment_subjects', 'assessment_id', 'assessments'],
    ['exam_moderation', 'paper_id', 'assessment_subjects', 'assessment_id', 'assessments'],
    ['exam_rechecks', 'paper_id', 'assessment_subjects', 'assessment_id', 'assessments'],
    ['exam_question_papers', 'slot_id', 'exam_slots', 'assessment_id', 'assessments']
  ];
  fence constant text :=
    '((vppsone.is_test_session(%s) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()))';
  predicate text;
  i int;
begin
  foreach t in array labelled loop
    predicate := format(fence, 'session_label');
    execute format(
      'create policy test_session_fence on vppsone.%I as restrictive for all to authenticated using %s with check %s',
      t, predicate, predicate
    );
  end loop;

  for i in 1 .. array_length(children, 1) loop
    -- A null parent id has no session: visible as a real row, like any unlabelled row.
    predicate := format(
      '(%1$I is null or exists (select 1 from vppsone.%2$I p where p.id = %3$I.%1$I and %4$s))',
      children[i][2], children[i][3], children[i][1], format(fence, 'p.session_label')
    );
    execute format(
      'create policy test_session_fence on vppsone.%I as restrictive for all to authenticated using %s with check %s',
      children[i][1], predicate, predicate
    );
  end loop;

  for i in 1 .. array_length(grandchildren, 1) loop
    predicate := format(
      '(%1$I is null or exists (select 1 from vppsone.%2$I c join vppsone.%4$I p on p.id = c.%3$I '
        'where c.id = %5$I.%1$I and %6$s))',
      grandchildren[i][2], grandchildren[i][3], grandchildren[i][4], grandchildren[i][5],
      grandchildren[i][1], format(fence, 'p.session_label')
    );
    execute format(
      'create policy test_session_fence on vppsone.%I as restrictive for all to authenticated using %s with check %s',
      grandchildren[i][1], predicate, predicate
    );
  end loop;
end;
$$;

-- ======================================================== migrations/20261030155654_set_test_account_log_text.sql
-- set_test_account (20261030155339) logged its flag change with format('%s'),
-- and a boolean's output function writes 't' / 'f': the audit row read
-- "is_test_account: f -> t". Same function, logged as 'false -> true'.
-- Found by scripts/verify-test-session-fence.sql case H.
--
-- Rollback: re-run the function from 20261030155339.

create or replace function vppsone.set_test_account(
  p_profile_id uuid,
  p_value boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor vppsone.staff_profiles%rowtype;
  target vppsone.staff_profiles%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if p_value is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:staff-authority'));

  select * into actor from vppsone.staff_profiles
  where user_id = (select auth.uid()) and is_active;
  if not found or actor.role <> 'admin' or actor.is_test_account then
    return jsonb_build_object('ok', false, 'reason', 'not_real_admin');
  end if;

  select * into target from vppsone.staff_profiles where id = p_profile_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if target.id = actor.id then
    return jsonb_build_object('ok', false, 'reason', 'self');
  end if;
  if target.is_test_account = p_value then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  update vppsone.staff_profiles set is_test_account = p_value where id = target.id;

  -- ::text, not format('%s'): a boolean's output function writes 't'/'f'.
  insert into vppsone.staff_authority_changes (
    staff_profile_id, actor_staff_id, from_role, to_role, from_active, to_active, reason
  ) values (
    target.id, actor.id, target.role, target.role, target.is_active, target.is_active,
    'is_test_account: ' || target.is_test_account::text || ' -> ' || p_value::text || '. ' || v_reason
  );

  return jsonb_build_object('ok', true, 'changed', true);
end;
$$;

revoke all on function vppsone.set_test_account(uuid, boolean, text) from public, anon;
grant execute on function vppsone.set_test_account(uuid, boolean, text) to authenticated;

-- ======================================================== fee-migrations/20261030170000_online_payment_staff_alerts.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261030170000_online_payment_staff_alerts.sql
-- (fees origin/main b96525ba), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Live (vgqyilgstjvgohrsiwkb) has it applied: load-snapshot refused the first
-- real load over the objects it creates (go-live Phase D).
-- Difference from the fees app: ONE value. The fees original seeds
--   `online_payment_staff_whatsapp_numbers` with two staff phone numbers; here
--   it is seeded '' because no real phone number goes in this repo (CLAUDE.md
--   rule 6). `online_payment_*` settings are One-owned, so the load never
--   brings live's list across (scripts/migrate/lib/import-rules.mjs); the
--   owner sets One's own, and with no number no staff WhatsApp alert can go. Everything else is the
--   fees original. The staff alert sender (push + WhatsApp to staff) is app
--   code for go-live Phase F; until then the trigger only queues rows.
-- ============================================================================
-- Staff alerts for online payments (owner, 2026-10-30).
--
-- When a Razorpay payment becomes a receipt, the office hears about it twice:
-- a notification on every staff phone that has switched alerts on, and a
-- WhatsApp message through AiSensy to the numbers in
-- `online_payment_staff_whatsapp_numbers`. The WhatsApp half has its own switch,
-- `online_payment_staff_whatsapp_enabled`. Counter payments alert nobody.
--
-- WHERE IT HOOKS IN. Two paths post online money today — Payment Links
-- (`online_payment_apply_capture`) and one-tap orders
-- (`online_payment_apply_order_capture`) — and both end in
-- `private.post_student_payment_core` writing a receipt with
-- `payment_mode = 'online'`. So the alert is queued by a trigger on that
-- receipt, not by either function: no money function is edited, and a third
-- online path would alert without anyone remembering to wire it.
--
-- THE TRIGGER CAN NEVER BLOCK A POSTING. Its body is wrapped so any error is a
-- warning and the receipt stands. An alert that failed to queue is a missed
-- message; a payment that failed to post would be money in Razorpay with no
-- receipt.
--
-- ONE ALERT PER RECEIPT, unique on `receipt_id`. The app claims due rows with a
-- lease (`staff_payment_alert_claim`), so the webhook, the pay page and the
-- ten-minute reconciler can all drain without one alert going out twice.
--
-- Web Push keys. The VAPID key pair is generated by the app on first use and
-- kept in `private.web_push_vapid` (service role only, one row). Nobody has to
-- paste a key into Vercel; deleting the row rotates it, after which every phone
-- has to switch alerts on again.
--
-- ADDITIVE. Rollback: `…_rollback.sql.txt`.

begin;

-- ---------------------------------------------------------------- switches

insert into public.app_settings (key, value) values
  ('online_payment_staff_whatsapp_enabled', 'true'),
  ('online_payment_staff_whatsapp_numbers', '')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- the alerts

create table public.staff_payment_alerts (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null unique references public.receipts (id),
  student_id uuid references public.students (id),
  receipt_number text not null,
  amount_rupees integer not null,
  payment_date date not null,
  push_status text not null default 'queued'
    check (push_status in ('queued', 'sent', 'no_devices', 'failed')),
  push_devices integer not null default 0,
  push_done_at timestamptz,
  whatsapp_status text not null default 'queued'
    check (whatsapp_status in ('queued', 'sent', 'partial', 'failed', 'off', 'not_configured')),
  -- Destinations already accepted by AiSensy. A retry sends only to the rest.
  whatsapp_sent_to text[] not null default '{}',
  whatsapp_message_ids text[] not null default '{}',
  whatsapp_attempts integer not null default 0,
  whatsapp_done_at timestamptz,
  last_error text,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index staff_payment_alerts_due_idx
  on public.staff_payment_alerts (next_attempt_at)
  where push_status = 'queued' or whatsapp_status in ('queued', 'partial', 'failed');

create index staff_payment_alerts_created_idx on public.staff_payment_alerts (created_at desc);

create or replace function private.queue_staff_payment_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    insert into public.staff_payment_alerts (receipt_id, student_id, receipt_number, amount_rupees, payment_date)
    values (new.id, new.student_id, new.receipt_number, new.total_amount, new.payment_date)
    on conflict (receipt_id) do nothing;
  exception when others then
    raise warning 'staff payment alert not queued for receipt %: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function private.queue_staff_payment_alert() from public, anon, authenticated;

create trigger queue_staff_payment_alert
  after insert on public.receipts
  for each row
  when (new.payment_mode = 'online'::public.payment_mode)
  execute function private.queue_staff_payment_alert();

-- Due alerts, leased. An alert older than two days is left alone: telling the
-- office about a payment from last week is noise, and the receipt is on screen.
create or replace function public.staff_payment_alert_claim(p_limit integer, p_lease_seconds integer)
returns setof public.staff_payment_alerts
language sql
set search_path = public
as $$
  update public.staff_payment_alerts as alert
  set locked_until = now() + make_interval(secs => greatest(p_lease_seconds, 30)),
      updated_at = now()
  where alert.id in (
    select candidate.id
    from public.staff_payment_alerts as candidate
    where (
        candidate.push_status = 'queued'
        or (candidate.whatsapp_status in ('queued', 'partial', 'failed') and candidate.whatsapp_attempts < 5)
      )
      and candidate.next_attempt_at <= now()
      and (candidate.locked_until is null or candidate.locked_until < now())
      and candidate.created_at > now() - interval '2 days'
    order by candidate.created_at
    limit greatest(least(p_limit, 50), 1)
    for update skip locked
  )
  returning alert.*;
$$;

revoke all on function public.staff_payment_alert_claim(integer, integer) from public, anon, authenticated;
grant execute on function public.staff_payment_alert_claim(integer, integer) to service_role;

-- ---------------------------------------------------------------- phones

-- One row per browser that switched alerts on. The endpoint is the push
-- service's address for that browser; p256dh and auth are its encryption keys.
create table public.staff_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text,
  failure_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index staff_push_subscriptions_user_idx on public.staff_push_subscriptions (user_id);

create table private.web_push_vapid (
  id smallint primary key default 1 check (id = 1),
  public_key text not null,
  private_key_jwk text not null,
  created_at timestamptz not null default now()
);

revoke all on private.web_push_vapid from public, anon, authenticated;

-- Returns the stored key pair, storing the one offered if there is none yet.
-- Two first callers racing both offer a pair; the first insert wins and both
-- read it back, so every phone subscribes against the same public key.
create or replace function public.web_push_vapid_keys(p_public_key text default null, p_private_key_jwk text default null)
returns table (public_key text, private_key_jwk text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_public_key is not null and p_private_key_jwk is not null then
    insert into private.web_push_vapid (id, public_key, private_key_jwk)
    values (1, p_public_key, p_private_key_jwk)
    on conflict (id) do nothing;
  end if;
  return query select v.public_key, v.private_key_jwk from private.web_push_vapid as v where v.id = 1;
end;
$$;

revoke all on function public.web_push_vapid_keys(text, text) from public, anon, authenticated;
grant execute on function public.web_push_vapid_keys(text, text) to service_role;

-- ---------------------------------------------------------------- access

alter table public.staff_payment_alerts enable row level security;
alter table public.staff_push_subscriptions enable row level security;
alter table private.web_push_vapid enable row level security;

revoke all on public.staff_payment_alerts from anon, authenticated;
revoke all on public.staff_push_subscriptions from anon, authenticated;

-- Production's default privileges grant service_role ALL on new tables. An
-- alert is a record of what was sent; it takes no DELETE. A subscription is
-- deleted when its browser turns alerts off or the push service says it is gone.
revoke all on public.staff_payment_alerts from service_role;
grant select, insert, update on public.staff_payment_alerts to service_role;
revoke all on public.staff_push_subscriptions from service_role;
grant select, insert, update, delete on public.staff_push_subscriptions to service_role;

commit;

-- ======================================================== migrations/20261030172156_test_account_staff_and_student_fences.sql
-- Test accounts manage only test accounts, and six student-keyed tables join
-- the test-session fence (Phase 3 fixes, PR #143 review; D-340).
--
-- 1. vppsone.change_staff_authority refuses a test-account actor changing the
--    role or access of a profile that is not a test account (reason
--    'test_account'). Two QA test accounts hold role admin; before this they
--    could demote, deactivate or promote real staff — the owner included —
--    stopped only by the last-admin rule. The app refuses first
--    (actorMayManage in staff-repo.ts); this is the database's half, because
--    the command runs as the service role with the actor passed in.
--
-- 2. vppsone.student_in_visible_session(student_id): the student's class
--    session against the viewer, the same sentence as every other fence:
--      a test account sees only test sessions, everybody else only real ones,
--      a real admin both. A row with no student is outside the fence (true);
--      a student or class that cannot be found is visible to real staff only.
--    SECURITY DEFINER so it reads public.students/classes whatever the
--    viewer's own fee permissions are (a teacher has no students:view).
--
-- 3. RESTRICTIVE test_session_fence policies on the six vppsone tables that
--    carry a student but no session_label, which 20261030155339 left out:
--    acc_counter_queue, acc_requests, data_quality_skips,
--    external_student_ids, parent_route_flags, promotion_marks.
--    USING and WITH CHECK both, to authenticated (service role bypasses RLS;
--    the app's assert*Visible hold that path).
--
-- Rollback:
--   drop policy test_session_fence on vppsone.<each of the six>;
--   drop function vppsone.student_in_visible_session(uuid);
--   restore change_staff_authority from 20261004031630 (without the
--   test_account branch).

create or replace function vppsone.student_in_visible_session(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_student_id is null
      or vppsone.is_real_admin()
      or coalesce(
           (select vppsone.is_test_session(c.session_label) = vppsone.current_is_test_account()
              from public.students s
              join public.classes c on c.id = s.class_id
             where s.id = p_student_id),
           not vppsone.current_is_test_account()
         );
$$;

comment on function vppsone.student_in_visible_session(uuid) is
  'Is this student''s class session one the signed-in viewer may open? Test accounts: TEST only; real staff: real only; real admin: both (D-340).';

revoke all on function vppsone.student_in_visible_session(uuid) from public, anon;
grant execute on function vppsone.student_in_visible_session(uuid) to authenticated, service_role;

do $$
declare
  t text;
begin
  foreach t in array array[
    'acc_counter_queue', 'acc_requests', 'data_quality_skips',
    'external_student_ids', 'parent_route_flags', 'promotion_marks'
  ]
  loop
    execute format('drop policy if exists test_session_fence on vppsone.%I', t);
    execute format(
      'create policy test_session_fence on vppsone.%I as restrictive for all to authenticated '
      'using (vppsone.student_in_visible_session(student_id)) '
      'with check (vppsone.student_in_visible_session(student_id))', t);
  end loop;
end;
$$;

create or replace function vppsone.change_staff_authority(
  p_actor_staff_id uuid,
  p_target_staff_id uuid,
  p_role vppsone.staff_role,
  p_is_active boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  actor vppsone.staff_profiles%rowtype;
  target vppsone.staff_profiles%rowtype;
begin
  perform pg_advisory_xact_lock(hashtext('vppsone:staff-authority'));

  select * into actor from vppsone.staff_profiles where id = p_actor_staff_id;
  if not found or not actor.is_active or actor.role <> 'admin' then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;

  select * into target from vppsone.staff_profiles where id = p_target_staff_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- Phase 3 (D-340): a test account manages only test accounts.
  if actor.is_test_account and not target.is_test_account then
    return jsonb_build_object('ok', false, 'reason', 'test_account');
  end if;

  if target.role = p_role and target.is_active = p_is_active then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  if target.id = actor.id then
    return jsonb_build_object('ok', false, 'reason', 'self');
  end if;

  begin
    update vppsone.staff_profiles set role = p_role, is_active = p_is_active where id = target.id;
  exception when check_violation then
    return jsonb_build_object('ok', false, 'reason', 'last_admin');
  end;

  insert into vppsone.staff_authority_changes (
    staff_profile_id, actor_staff_id, from_role, to_role, from_active, to_active, reason
  ) values (
    target.id, actor.id, target.role, p_role, target.is_active, p_is_active,
    nullif(btrim(coalesce(p_reason, '')), '')
  );

  return jsonb_build_object('ok', true, 'changed', true);
end;
$function$;

-- ======================================================== migrations/20261030185555_staff_profiles_is_test_account_readable.sql
-- The signed-in person reads their own `is_test_account` (current-staff.ts
-- selects it beside the profile). 20261004041954 replaced the table-wide
-- SELECT grant with a column list, and 20261030112133 added the column after
-- it, so `authenticated` could not read it: every signed-in page answered
-- "permission denied for table staff_profiles" and sent the person to
-- /login?reason=no-profile. Row visibility is still decided by RLS.
--
-- Found running tests/e2e/test-session.spec.ts against a local next dev
-- (Phase C, 31 Oct). Applied to wtgxcptmucjerhufzjcf through the Supabase MCP.
grant select (is_test_account) on vppsone.staff_profiles to authenticated;

-- ======================================================== fee-migrations/20261030190000_whatsapp_failure_desk.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261030190000_whatsapp_failure_desk.sql
-- (fees origin/main b96525ba), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Live (vgqyilgstjvgohrsiwkb) has it applied: load-snapshot refused the first
-- real load over the objects it creates (go-live Phase D).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added. (Its begin/commit were left out of the
--   MCP call only because apply_migration runs in its own transaction.)
-- ============================================================================
-- The failure desk: every reminder that did not reach a family, why, and what
-- was done about it.
--
-- Before this, three different things could go wrong with a reminder and the
-- app recorded only one of them well:
--
-- 1. AiSensy refused the request (`status = 'failed'`). Recorded, with the text.
-- 2. AiSensy accepted it and WhatsApp then could not deliver it
--    (`delivery_status = 'failed'`, from the report CSV). The status landed; the
--    reason and WhatsApp's error code were thrown away, and nothing counted it as
--    a failure.
-- 3. A retry. It updated the row in place, so the earlier attempt — which number,
--    what went wrong — was overwritten.
--
-- This migration adds:
--
-- - a CAUSE on every failed row (decided in TypeScript by
--   `domain/failure-cause.ts`, one rule for the sender, the report import and the
--   webhook), plus the delivery reason and code;
-- - a RESOLUTION, for a person saying "I called them" or "slip sent home";
-- - `whatsapp_send_attempts`, one append-only row per provider answer, delivery
--   result and resolution, written by trigger so no code path can forget it;
-- - `whatsapp_number_health`, keyed by the last ten digits of a number, so a
--   number WhatsApp has said it cannot reach is not paid for again, and the
--   audience can switch the family to the other parent's number.
--
-- Additive throughout. No existing column changes meaning, no row is rewritten
-- except by the triggers on future writes, and the backfill only inserts.

begin;

-- ------------------------------------------------------------- 0. phone key

create schema if not exists private;

-- The last ten digits, or null when there are fewer than ten. `+91 93522 05884`,
-- `919352205884` and `9352205884` are one number; the report CSV, the student
-- record and the send log each write it differently.
create or replace function private.whatsapp_phone_key(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when length(digits) >= 10 then right(digits, 10) end
  from (select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as digits) as cleaned
$$;

-- --------------------------------------------------------- 1. send columns

alter table public.whatsapp_reminder_sends
  add column if not exists failure_cause text,
  add column if not exists delivery_error_code text,
  add column if not exists delivery_error text,
  add column if not exists resolution text,
  add column if not exists resolution_note text,
  add column if not exists resolved_by uuid,
  add column if not exists resolved_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.whatsapp_reminder_sends'::regclass
      and conname = 'whatsapp_reminder_sends_failure_cause_check'
  ) then
    alter table public.whatsapp_reminder_sends
      add constraint whatsapp_reminder_sends_failure_cause_check
      check (
        failure_cause is null
        or failure_cause in (
          'invalid_number', 'not_on_whatsapp', 'opted_out', 'whatsapp_limit',
          'template', 'account', 'network', 'media', 'unknown'
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.whatsapp_reminder_sends'::regclass
      and conname = 'whatsapp_reminder_sends_resolution_check'
  ) then
    alter table public.whatsapp_reminder_sends
      add constraint whatsapp_reminder_sends_resolution_check
      check (resolution is null or resolution in ('called', 'slip_sent', 'dismissed'));
  end if;
end $$;

comment on column public.whatsapp_reminder_sends.failure_cause is
  'Why this row failed, in the office''s terms — set by domain/failure-cause.ts '
  'from the provider''s text and code, wherever the failure was learned (the send, '
  'the report CSV, the webhook). Null on a row that has not failed. Never set on '
  'a covered_by_sibling row.';

comment on column public.whatsapp_reminder_sends.delivery_error is
  'The reason AiSensy''s report or webhook gave for a delivery failure, verbatim. '
  'Kept apart from last_error, which is what the SEND was told.';

comment on column public.whatsapp_reminder_sends.resolution is
  'A person''s decision that this failure needs nothing more from WhatsApp: '
  'called = rang the family; slip_sent = paper went home; dismissed = not '
  'chasing, with resolution_note saying why. Delivered-later and paid-since are '
  'NOT stored here: both are read from the ledger and the send log, so they can '
  'never disagree with them.';

create index if not exists whatsapp_reminder_sends_open_problems_idx
  on public.whatsapp_reminder_sends (session_label, sent_on desc)
  where resolution is null
    and (status in ('failed', 'pending') or delivery_status = 'failed');

-- ------------------------------------------------------ 2. number health

create table if not exists public.whatsapp_number_health (
  phone_key text primary key check (phone_key ~ '^[0-9]{10}$'),
  last_delivered_at timestamptz,
  last_failed_at timestamptz,
  last_cause text,
  failures_in_a_row integer not null default 0,
  -- A person saying "try this number again" or "this number does not work".
  marked_by uuid,
  marked_at timestamptz,
  marked_note text,
  updated_at timestamptz not null default now()
);

comment on table public.whatsapp_number_health is
  'What WhatsApp has said about each number, by its last ten digits. A number '
  'is DEAD while failures_in_a_row > 0 and last_cause is not_on_whatsapp, '
  'invalid_number or opted_out: the audience then uses the other parent''s '
  'number, or lists the family as unreachable. One delivery resets it. Shared by '
  'siblings, because the number is.';

alter table public.whatsapp_number_health enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'whatsapp_number_health'
      and policyname = 'whatsapp_number_health: staff read'
  ) then
    create policy "whatsapp_number_health: staff read"
      on public.whatsapp_number_health for select
      using ((select auth.role()) = 'authenticated');
  end if;
end $$;

revoke all on public.whatsapp_number_health from anon;
grant select on public.whatsapp_number_health to authenticated;

create or replace function private.whatsapp_mark_number(
  p_phone_key text,
  p_delivered boolean,
  p_cause text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_phone_key is null then
    return;
  end if;

  insert into public.whatsapp_number_health as health (
    phone_key, last_delivered_at, last_failed_at, last_cause, failures_in_a_row, updated_at
  )
  values (
    p_phone_key,
    case when p_delivered then now() end,
    case when p_delivered then null else now() end,
    case when p_delivered then null else p_cause end,
    case when p_delivered then 0 else 1 end,
    now()
  )
  on conflict (phone_key) do update set
    last_delivered_at = case when p_delivered then now() else health.last_delivered_at end,
    last_failed_at = case when p_delivered then health.last_failed_at else now() end,
    last_cause = case when p_delivered then health.last_cause else p_cause end,
    failures_in_a_row = case when p_delivered then 0 else health.failures_in_a_row + 1 end,
    updated_at = now();
end;
$$;

revoke all on function private.whatsapp_mark_number(text, boolean, text) from public, anon, authenticated;

-- --------------------------------------------------------- 3. attempts log

create table if not exists public.whatsapp_send_attempts (
  id uuid primary key default gen_random_uuid(),
  send_id uuid not null references public.whatsapp_reminder_sends (id) on delete cascade,
  student_id uuid not null,
  session_label text not null,
  -- accepted / refused: what AiSensy said to the send.
  -- submitted / delivered / read / failed: what the report or webhook said later.
  -- resolved: a person closed the failure (called, slip sent, dismissed).
  result text not null check (
    result in ('accepted', 'refused', 'submitted', 'delivered', 'read', 'failed', 'resolved')
  ),
  destination text,
  destination_role text,
  provider_message_id text,
  error_code text,
  error_text text,
  cause text,
  source text not null check (source in ('send', 'report', 'resolution', 'backfill')),
  staff_id uuid,
  note text,
  created_at timestamptz not null default now()
);

comment on table public.whatsapp_send_attempts is
  'Append-only history of every reminder: each provider answer, each delivery '
  'result, each human resolution. Written by trigger on whatsapp_reminder_sends, '
  'which keeps ONE row per family per notice per day (the unique index) and '
  'updates it in place on a resend — this is where the earlier attempts survive. '
  'Rows before 2026-10-30 are a one-line backfill per send; their earlier '
  'retries were never recorded.';

create index if not exists whatsapp_send_attempts_send_idx
  on public.whatsapp_send_attempts (send_id, created_at);
create index if not exists whatsapp_send_attempts_student_idx
  on public.whatsapp_send_attempts (student_id, created_at desc);
create index if not exists whatsapp_send_attempts_session_idx
  on public.whatsapp_send_attempts (session_label, created_at desc);

alter table public.whatsapp_send_attempts enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'whatsapp_send_attempts'
      and policyname = 'whatsapp_send_attempts: staff read'
  ) then
    create policy "whatsapp_send_attempts: staff read"
      on public.whatsapp_send_attempts for select
      using ((select auth.role()) = 'authenticated');
  end if;
end $$;

revoke all on public.whatsapp_send_attempts from anon;
grant select on public.whatsapp_send_attempts to authenticated;

-- History does not change. Deletes are allowed only so the ≤30-day empty-session
-- delete can still cascade through the send log.
create or replace function private.whatsapp_send_attempts_are_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'whatsapp_send_attempts is append-only';
end;
$$;

drop trigger if exists whatsapp_send_attempts_append_only on public.whatsapp_send_attempts;
create trigger whatsapp_send_attempts_append_only
  before update on public.whatsapp_send_attempts
  for each row execute function private.whatsapp_send_attempts_are_append_only();

-- ------------------------------------------------------------- 4. triggers

-- A row taken back to `pending` is the next attempt at the same message. The
-- counter, and the clearing of the PREVIOUS message's delivery result, happen
-- here so every path that reclaims a row — the run sender, a resend from the
-- failure desk — gets them without having to remember.
create or replace function private.whatsapp_send_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'pending' and old.status in ('failed', 'sent') then
    new.attempts := coalesce(old.attempts, 1) + 1;
    new.last_attempt_at := now();
    new.delivery_status := null;
    new.delivered_at := null;
    new.read_at := null;
    new.delivery_error := null;
    new.delivery_error_code := null;
    new.failure_cause := null;
    new.resolution := null;
    new.resolution_note := null;
    new.resolved_by := null;
    new.resolved_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists whatsapp_send_before_update on public.whatsapp_reminder_sends;
create trigger whatsapp_send_before_update
  before update on public.whatsapp_reminder_sends
  for each row execute function private.whatsapp_send_before_update();

create or replace function private.whatsapp_send_after_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := private.whatsapp_phone_key(new.destination);
  v_dead text[] := array['not_on_whatsapp', 'invalid_number', 'opted_out'];
begin
  -- The provider answered the send.
  if new.status in ('sent', 'failed')
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    insert into public.whatsapp_send_attempts (
      send_id, student_id, session_label, result, destination, destination_role,
      provider_message_id, error_text, cause, source, staff_id
    ) values (
      new.id, new.student_id, new.session_label,
      case when new.status = 'sent' then 'accepted' else 'refused' end,
      new.destination, new.destination_role, new.provider_message_id,
      case when new.status = 'failed' then coalesce(new.last_error, new.error_message) end,
      case when new.status = 'failed' then new.failure_cause end,
      'send', new.sent_by
    );

    if new.status = 'failed' and new.failure_cause = any (v_dead) then
      perform private.whatsapp_mark_number(v_key, false, new.failure_cause);
    end if;
  end if;

  -- A delivery result arrived, from the report CSV or the webhook.
  if tg_op = 'UPDATE'
     and new.status = 'sent'
     and new.delivery_status is not null
     and new.delivery_status is distinct from old.delivery_status then
    insert into public.whatsapp_send_attempts (
      send_id, student_id, session_label, result, destination, destination_role,
      provider_message_id, error_code, error_text, cause, source
    ) values (
      new.id, new.student_id, new.session_label, new.delivery_status,
      new.destination, new.destination_role, new.provider_message_id,
      new.delivery_error_code, new.delivery_error,
      case when new.delivery_status = 'failed' then new.failure_cause end,
      'report'
    );

    if new.delivery_status in ('delivered', 'read') then
      perform private.whatsapp_mark_number(v_key, true, null);
    elsif new.delivery_status = 'failed' and new.failure_cause = any (v_dead) then
      perform private.whatsapp_mark_number(v_key, false, new.failure_cause);
    end if;
  end if;

  -- A person closed the failure.
  if tg_op = 'UPDATE'
     and new.resolution is not null
     and new.resolution is distinct from old.resolution then
    insert into public.whatsapp_send_attempts (
      send_id, student_id, session_label, result, destination, destination_role,
      source, staff_id, note
    ) values (
      new.id, new.student_id, new.session_label, 'resolved',
      new.destination, new.destination_role, 'resolution', new.resolved_by,
      new.resolution || coalesce(': ' || nullif(new.resolution_note, ''), '')
    );
  end if;

  return null;
end;
$$;

revoke all on function private.whatsapp_send_after_write() from public, anon, authenticated;

drop trigger if exists whatsapp_send_after_write on public.whatsapp_reminder_sends;
create trigger whatsapp_send_after_write
  after insert or update on public.whatsapp_reminder_sends
  for each row execute function private.whatsapp_send_after_write();

-- -------------------------------------------------------------- 5. backfill

-- One line per existing send, so every family's timeline starts somewhere. The
-- retries that happened before today overwrote their own history and cannot be
-- recovered; the line says what the row says now.
insert into public.whatsapp_send_attempts (
  send_id, student_id, session_label, result, destination, destination_role,
  provider_message_id, error_text, source, staff_id, created_at
)
select
  s.id, s.student_id, s.session_label,
  case when s.status = 'sent' then 'accepted' else 'refused' end,
  s.destination, s.destination_role, s.provider_message_id,
  case when s.status = 'failed' then coalesce(s.last_error, s.error_message) end,
  'backfill', s.sent_by,
  coalesce(s.last_attempt_at, s.created_at)
from public.whatsapp_reminder_sends s
where s.status in ('sent', 'failed')
  and not exists (
    select 1 from public.whatsapp_send_attempts a where a.send_id = s.id
  );

commit;

-- ======================================================== fee-migrations/20261030200000_parity_revoke_public_execute.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): take EXECUTE away from PUBLIC on the 45 fee
-- functions where the live fee database has already taken it away.
--
-- Why this differs from the fees app: it does not. It makes wtgxcptmucjerhufzjcf
-- match vgqyilgstjvgohrsiwkb. The 30 Oct schema parity check
-- (scripts/migrate/catalog-fingerprint.sql, docs/cutover/SCHEMA-PARITY.md) found
-- these 45 functions with `=X/postgres` (EXECUTE for PUBLIC, which anon is part
-- of) on wtgx and without it on live. Every other grantee row on these functions
-- (anon, authenticated, service_role, postgres) is already identical on the two,
-- so after this file the per-role EXECUTE grants for the fee schema are equal.
--
-- How wtgx got them: the masked replica (D-186) recreated functions with
-- `create function`, and Postgres's global default gives PUBLIC EXECUTE on every
-- new function (see 20261029030619's header for the same mechanism on live). The
-- fees app revoked them over several migrations that the replica never replayed.
--
-- Among them are the money RPCs (post_student_payment*, post_corrected_payment,
-- undo_recent_payment, reverse_receipt_admin, waive_late_fee, refunds) — callable
-- with the browser key on wtgx until now. Each still checks has_permission()
-- inside, so nothing was exposed, but the grant the guard was covering for goes.
-- This is plan §1.5's "sweep that revokes anon EXECUTE on dev's SECURITY DEFINER
-- functions", done against live's actual grant set instead of a guess.
--
-- Trigger functions are in the list: EXECUTE is checked when a trigger is
-- created, never when it fires, so revoking it changes nothing for the tables.
-- pg_cron runs as postgres (the owner), so the refresh jobs are unaffected.
--
-- Rollback: `grant execute on function <each> to public;` — not expected.
-- ============================================================================

begin;

revoke execute on function private.capture_audit_event() from public;
revoke execute on function private.current_staff_role() from public;
revoke execute on function private.enforce_max_active_conventional_discounts() from public;
revoke execute on function private.enforce_max_active_conventional_discounts_in_schema() from public;
revoke execute on function private.normalize_staff_role(text) from public;
revoke execute on function private.normalize_workbook_class_label(text, text) from public;
revoke execute on function private.prevent_append_only_mutation() from public;
revoke execute on function private.prevent_receipt_adjustment_mutation() from public;
revoke execute on function private.protect_receipt_money_columns() from public;
revoke execute on function private.set_actor_columns() from public;
revoke execute on function private.set_created_by_column() from public;
revoke execute on function private.set_updated_at() from public;
revoke execute on function private.sync_staff_profile_from_auth_user() from public;
revoke execute on function private.vpps_apply_chunk(text, jsonb) from public;
revoke execute on function public.active_session_label() from public;
revoke execute on function public.cancel_student_repayment_plan(uuid, text) from public;
revoke execute on function public.delete_academic_session_safe(uuid) from public;
revoke execute on function public.generate_schema_snapshot() from public;
revoke execute on function public.get_dashboard_fee_split(text) from public;
revoke execute on function public.get_dashboard_repayment_summary(text) from public;
revoke execute on function public.get_dashboard_summary(text, text) from public;
revoke execute on function public.get_student_directory_summary(text, uuid, uuid, text, text[], boolean) from public;
revoke execute on function public.get_student_segment_counts(text, uuid, uuid, text, text[], boolean) from public;
revoke execute on function public.has_any_permission(text[]) from public;
revoke execute on function public.import_student_batch_row(uuid, integer, text, uuid, text, date, text, text, text, text, text, uuid, student_status, text, integer, integer, integer, integer, jsonb, integer, integer, text, boolean) from public;
revoke execute on function public.import_student_batch_row(uuid, integer, text, uuid, text, date, text, text, text, text, text, uuid, student_status, text, integer, integer, integer, integer, jsonb, integer, integer, text, boolean, text, integer, integer) from public;
revoke execute on function public.post_corrected_payment(uuid, date, payment_mode, jsonb, uuid, text, text, text, text) from public;
revoke execute on function public.post_student_payment(uuid, date, payment_mode, integer, text, text, text, text, uuid) from public;
revoke execute on function public.post_student_payment_with_adjustments(uuid, date, payment_mode, integer, text, text, text, text, uuid, integer, integer) from public;
revoke execute on function public.preview_student_repayment_plan(uuid, text, text, integer, date) from public;
revoke execute on function public.process_refund_with_adjustment(uuid) from public;
revoke execute on function public.queue_workbook_materialized_view_refresh() from public;
revoke execute on function public.realign_recent_import_students_to_active_session(uuid) from public;
revoke execute on function public.refresh_defaulter_recovery_state(text, date) from public;
revoke execute on function public.refresh_financial_materialized_views(boolean) from public;
revoke execute on function public.refresh_workbook_materialized_views_if_requested() from public;
revoke execute on function public.reverse_receipt_admin(uuid, text) from public;
revoke execute on function public.rls_auto_enable() from public;
revoke execute on function public.set_my_preferred_locale(text) from public;
revoke execute on function public.sync_repayment_plan_late_fees(text, boolean, date) from public;
revoke execute on function public.trigger_refresh_financial_views() from public;
revoke execute on function public.undo_recent_payment(uuid, text) from public;
revoke execute on function public.void_late_fee_waiver(uuid, text) from public;
revoke execute on function public.vpps_apply_chunk_proxy(text, jsonb) from public;
revoke execute on function public.waive_late_fee(uuid, integer, text, text, uuid, uuid, boolean) from public;

commit;

-- ======================================================== fee-migrations/20261030200100_parity_office_sync_realtime.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): put public.office_sync_events back into the
-- supabase_realtime publication.
--
-- Why this differs from the fees app: it does not. The fees app's
-- 20260516100000_office_sync_events.sql adds the table to the publication; the
-- table reached wtgxcptmucjerhufzjcf through the masked replica, but publication
-- membership is not part of a table copy (critique1 B1), so on wtgx
-- OfficeSyncListener (src/ui/shell/office-sync-listener.tsx) subscribed to a
-- table that never published anything. Found by the 30 Oct schema parity check
-- (docs/cutover/SCHEMA-PARITY.md). The block is the fees original's, verbatim.
-- ============================================================================
do $$
begin
  alter publication supabase_realtime add table public.office_sync_events;
exception
  when duplicate_object then null;
end
$$;

-- ======================================================== fee-migrations/20261030230000_fee_writes_guard.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): the fee writes switch, enforced in the
-- database (D-345; plan §2.7; critique0 #24).
--
-- Why this differs from the fees app: the fees app has no such switch. On
-- One's database the real fee data arrives by a nightly mirror of the fees app
-- (Phase 2) long before One is the system of record (T0). Until then a payment,
-- waiver or reversal posted in One against a real student would be silently
-- overwritten by the next mirror load — or worse, survive it and double a
-- family's money. An app-side flag alone does not stop that: the money RPCs
-- stay callable by `authenticated` over PostgREST (critique0 #24). So the RPCs
-- themselves ask first.
--
-- THE RULE — vppsone.fee_writes_allowed(p_student_id uuid default null):
--   1. A student in a TEST session (class -> session_label matches
--      vppsone.is_test_session_label) is ALWAYS writable. Testing happens on
--      this production database, under TEST-2026-27, during mirror mode too
--      (D-346, owner override T1).
--   2. Otherwise refused when public.app_settings 'fee_writes_enabled' = 'false'.
--   3. Otherwise refused when vppsone.is_production() and the key is not 'true'
--      (unset counts as not 'true': production fails closed).
--   4. Otherwise allowed (today: marker 'dev', key unset — nothing changes).
-- vppsone.fee_writes_allowed_for_session(label) is the same rule for a write
-- that names a session rather than a student.
-- A refusal raises SQLSTATE 'VPP01' with a sentence staff can read.
--
-- GUARDED (a guard line is inserted at the top of each body — enumerated from
-- the catalog: every public/private function that inserts, updates or deletes
-- payments, receipts, receipt_adjustments, payment_adjustments,
-- student_late_fee_waivers, refund_requests, student_repayment_*, installments
-- or student_fee_overrides; no family-payment, write-off, carry-forward or
-- prev-year import function exists in SQL on this database — those writes are
-- made by the app through the fee client and are refused there):
--   private.post_student_payment_core(uuid, date, payment_mode, integer, text, text, text, text, uuid, integer, integer)   by student
--     (covers public.post_student_payment_with_adjustments and
--      public.online_payment_apply_capture / online_payment_apply_order_capture,
--      which post only through it)
--   public.post_student_payment(uuid, date, payment_mode, integer, text, text, text, text, uuid)                            by student
--   public.post_corrected_payment(uuid, date, payment_mode, jsonb, uuid, text, text, text, text)                            by student
--   public.undo_recent_payment(uuid, text)                                         by the receipt's student
--   public.reverse_receipt_admin(uuid, text)                                       by the receipt's student
--   public.waive_late_fee(uuid, integer, text, text, uuid, uuid, boolean)          by student
--   private.online_waive_late_fees(uuid, text, date)                               by student
--   public.void_late_fee_waiver(uuid, text)                                        by the waiver's student
--   public.process_refund_with_adjustment(uuid)                                    by the refund's student
--   public.create_student_repayment_plan(uuid, text, text, integer, date, text, integer, uuid, uuid, date[])  by student
--   public.reschedule_student_repayment_plan(uuid, integer, date, text, integer, uuid, date[])                 by the plan's student
--   public.cancel_student_repayment_plan(uuid, text)                               by the plan's student
--   public.sync_repayment_plan_late_fees(text, boolean, date)                      by session, skipped for a dry run
--   public.import_student_batch_row(… 23 args) and (… 26 args)                     by the class's session
--
-- HOW: the bodies are not retyped here. vppsone.inject_fee_function_preamble()
-- inserts the guard as the first statement after the body's top-level `begin`
-- (each body has exactly one column-0 `begin` line — checked), replays the
-- function's own pg_get_functiondef() with that one change, and then proves
-- that removing the inserted lines gives back the original body byte for byte.
-- CREATE OR REPLACE keeps the oid, owner and grants. Re-running is a no-op:
-- a body that already carries the marker is skipped.
--
-- Not covered here, by design: the nightly EMI late-fee cron calls
-- sync_repayment_plan_late_fees for the active session and will be refused
-- (and log an error) while writes are off on production — correct during
-- mirror mode. The mirror loader itself writes rows, not RPCs.
--
-- Direct table writes over PostgREST and the switch key itself are guarded by
-- the follow-up 20261030230200_fee_writes_table_guard.sql (which also restates
-- fee_writes_allowed_for_session through vppsone.fee_writes_open()).
--
-- Proof: scripts/migrate/verify-fee-writes-guard.sql (one DO block that ends
-- by raising, so everything it did rolls back) — run through the MCP.
--
-- Rollback: for each function above,
--   select vppsone.remove_fee_function_preamble('<regprocedure>', '-- [vppsone:fee-writes-guard]');
-- then drop the functions created here.
-- ============================================================================

create or replace function vppsone.fee_writes_allowed_for_session(p_session_label text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_setting text;
begin
  if vppsone.is_test_session_label(p_session_label) then
    return true;
  end if;

  select lower(trim(a.value)) into v_setting
  from public.app_settings a
  where a.key = 'fee_writes_enabled';

  if v_setting = 'false' then
    return false;
  end if;

  if vppsone.is_production() and v_setting is distinct from 'true' then
    return false;
  end if;

  return true;
end;
$$;

create or replace function vppsone.fee_writes_allowed(p_student_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select vppsone.fee_writes_allowed_for_session(
    (select c.session_label
       from public.students s
       join public.classes c on c.id = s.class_id
      where s.id = p_student_id)
  );
$$;

comment on function vppsone.fee_writes_allowed(uuid) is
  'May fee money be written for this student now? TEST-session students always; others per app_settings.fee_writes_enabled and vppsone.is_production() (D-345).';

create or replace function vppsone.assert_fee_writes_allowed_for_session(p_session_label text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not vppsone.fee_writes_allowed_for_session(p_session_label) then
    raise exception 'Fee changes are switched off on this database until go-live (fee_writes_enabled). Only TEST-session students can be changed.'
      using errcode = 'VPP01',
            hint = 'An owner sets app_settings.fee_writes_enabled = ''true'' at T0 (D-345).';
  end if;
end;
$$;

create or replace function vppsone.assert_fee_writes_allowed(p_student_id uuid)
returns void
language sql
stable
security definer
set search_path = ''
as $$
  select vppsone.assert_fee_writes_allowed_for_session(
    (select c.session_label
       from public.students s
       join public.classes c on c.id = s.class_id
      where s.id = p_student_id)
  );
$$;

-- The guarded functions run as their own owners or as the caller; either way
-- they must be able to call the guard. The app reads it through the service
-- role. Nobody else needs it.
revoke all on function vppsone.fee_writes_allowed_for_session(text) from public, anon;
revoke all on function vppsone.fee_writes_allowed(uuid) from public, anon;
revoke all on function vppsone.assert_fee_writes_allowed_for_session(text) from public, anon;
revoke all on function vppsone.assert_fee_writes_allowed(uuid) from public, anon;
grant execute on function vppsone.fee_writes_allowed_for_session(text) to authenticated, service_role;
grant execute on function vppsone.fee_writes_allowed(uuid) to authenticated, service_role;
grant execute on function vppsone.assert_fee_writes_allowed_for_session(text) to authenticated, service_role;
grant execute on function vppsone.assert_fee_writes_allowed(uuid) to authenticated, service_role;

/* ------------------------------------------------- the preamble injector */

create or replace function vppsone.inject_fee_function_preamble(
  p_function regprocedure,
  p_marker text,
  p_preamble text
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_src text;
  v_def text;
  v_insert text;
  v_new text;
  v_at integer;
  v_after text;
begin
  if p_marker !~ '^-- \[vppsone:[a-z0-9-]+\]$' then
    raise exception 'marker must look like -- [vppsone:name], got %', p_marker;
  end if;

  select p.prosrc into strict v_src from pg_catalog.pg_proc p where p.oid = p_function;

  if position(p_marker in v_src) > 0 then
    return 'already: ' || p_function::text;
  end if;

  if (select count(*) from regexp_matches(v_src, E'\nbegin\n', 'g')) <> 1 then
    raise exception '% does not have exactly one column-0 begin line; not rewriting it', p_function;
  end if;

  v_at := position(E'\nbegin\n' in v_src);
  v_insert := '  ' || p_marker || E'\n' || p_preamble || E'\n  -- [/vppsone]\n';
  v_new := substr(v_src, 1, v_at + 6) || v_insert || substr(v_src, v_at + 7);

  v_def := pg_catalog.pg_get_functiondef(p_function);
  if (length(v_def) - length(replace(v_def, v_src, ''))) <> length(v_src) then
    raise exception '% body does not appear exactly once in its definition; not rewriting it', p_function;
  end if;

  execute replace(v_def, v_src, v_new);

  select p.prosrc into strict v_after from pg_catalog.pg_proc p where p.oid = p_function;
  if v_after <> v_new or replace(v_after, v_insert, '') <> v_src then
    raise exception '% was not rewritten exactly as intended', p_function;
  end if;

  return 'guarded: ' || p_function::text;
end;
$$;

create or replace function vppsone.remove_fee_function_preamble(p_function regprocedure, p_marker text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_src text;
  v_def text;
  v_start integer;
  v_end integer;
  v_new text;
begin
  select p.prosrc into strict v_src from pg_catalog.pg_proc p where p.oid = p_function;
  v_start := position('  ' || p_marker || E'\n' in v_src);
  if v_start = 0 then
    return 'absent: ' || p_function::text;
  end if;
  v_end := position(E'  -- [/vppsone]\n' in substr(v_src, v_start));
  if v_end = 0 then
    raise exception '% has the marker but no end marker', p_function;
  end if;
  v_new := substr(v_src, 1, v_start - 1) || substr(v_src, v_start + v_end - 1 + length(E'  -- [/vppsone]\n'));
  v_def := pg_catalog.pg_get_functiondef(p_function);
  execute replace(v_def, v_src, v_new);
  return 'removed: ' || p_function::text;
end;
$$;

-- These rewrite fee functions. Only the database owner (postgres, through a
-- migration) may run them.
revoke all on function vppsone.inject_fee_function_preamble(regprocedure, text, text) from public, anon, authenticated, service_role;
revoke all on function vppsone.remove_fee_function_preamble(regprocedure, text) from public, anon, authenticated, service_role;

/* ------------------------------------------------------------ the guards */

select vppsone.inject_fee_function_preamble(f::regprocedure, '-- [vppsone:fee-writes-guard]', g)
from (values
  ('private.post_student_payment_core(uuid, date, payment_mode, integer, text, text, text, text, uuid, integer, integer)',
   '  perform vppsone.assert_fee_writes_allowed(p_student_id);'),
  ('public.post_student_payment(uuid, date, payment_mode, integer, text, text, text, text, uuid)',
   '  perform vppsone.assert_fee_writes_allowed(p_student_id);'),
  ('public.post_corrected_payment(uuid, date, payment_mode, jsonb, uuid, text, text, text, text)',
   '  perform vppsone.assert_fee_writes_allowed(p_student_id);'),
  ('public.undo_recent_payment(uuid, text)',
   '  perform vppsone.assert_fee_writes_allowed((select r.student_id from public.receipts r where r.id = p_receipt_id));'),
  ('public.reverse_receipt_admin(uuid, text)',
   '  perform vppsone.assert_fee_writes_allowed((select r.student_id from public.receipts r where r.id = p_receipt_id));'),
  ('public.waive_late_fee(uuid, integer, text, text, uuid, uuid, boolean)',
   '  perform vppsone.assert_fee_writes_allowed(p_student_id);'),
  ('private.online_waive_late_fees(uuid, text, date)',
   '  perform vppsone.assert_fee_writes_allowed(p_student_id);'),
  ('public.void_late_fee_waiver(uuid, text)',
   '  perform vppsone.assert_fee_writes_allowed((select w.student_id from public.student_late_fee_waivers w where w.id = p_waiver_id));'),
  ('public.process_refund_with_adjustment(uuid)',
   '  perform vppsone.assert_fee_writes_allowed((select q.student_id from public.refund_requests q where q.id = p_refund_request_id));'),
  ('public.create_student_repayment_plan(uuid, text, text, integer, date, text, integer, uuid, uuid, date[])',
   '  perform vppsone.assert_fee_writes_allowed(p_student_id);'),
  ('public.reschedule_student_repayment_plan(uuid, integer, date, text, integer, uuid, date[])',
   '  perform vppsone.assert_fee_writes_allowed((select pl.student_id from public.student_repayment_plans pl where pl.id = p_plan_id));'),
  ('public.cancel_student_repayment_plan(uuid, text)',
   '  perform vppsone.assert_fee_writes_allowed((select pl.student_id from public.student_repayment_plans pl where pl.id = p_plan_id));'),
  ('public.sync_repayment_plan_late_fees(text, boolean, date)',
   '  if not coalesce(p_dry_run, false) then perform vppsone.assert_fee_writes_allowed_for_session(p_session_label); end if;'),
  ('public.import_student_batch_row(uuid, integer, text, uuid, text, date, text, text, text, text, text, uuid, student_status, text, integer, integer, integer, integer, jsonb, integer, integer, text, boolean)',
   '  perform vppsone.assert_fee_writes_allowed_for_session((select c.session_label from public.classes c where c.id = p_class_id));'),
  ('public.import_student_batch_row(uuid, integer, text, uuid, text, date, text, text, text, text, text, uuid, student_status, text, integer, integer, integer, integer, jsonb, integer, integer, text, boolean, text, integer, integer)',
   '  perform vppsone.assert_fee_writes_allowed_for_session((select c.session_label from public.classes c where c.id = p_class_id));')
) as t(f, g);

-- The switch is a One-owned key: the mirror never copies it from the fees app
-- (registered in vppsone.one_owned_fee_settings by the deployment-marker
-- migration). It is not created here: unset means "dev: allowed; production:
-- refused", which is the state we want until the orchestrator sets it.

-- ======================================================== fee-migrations/20261030230100_test_receipt_prefix.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): TEST-session receipts are numbered TST,
-- never SVP (D-346; plan Q10; owner override T1).
--
-- Why this differs from the fees app: on the fees app TEST-2026-27 postings
-- share the real `SVP<yyyymmdd>-NNNN` sequence, so every rehearsal receipt
-- burns a real receipt number. On One's database testing happens in
-- production, every day, under TEST-2026-27 — so test postings must have a
-- sequence of their own.
--
-- How the prefix is chosen today (read from the catalog and the app):
--   * The Payment Desk passes `p_receipt_prefix` = the session's
--     fee_policy_configs.receipt_prefix (src/modules/payments/data/queries.ts),
--     falling back to the ACTIVE session's policy when no session is passed.
--   * The online path (online_payment_apply_capture) hard-codes 'SVP' when it
--     calls private.post_student_payment_core.
--   * Every posting function normalises a blank prefix to 'SVP'.
-- So the smallest change that holds for every path is in the database, at the
-- top of the three functions that number receipts:
--     p_receipt_prefix := vppsone.receipt_prefix_for_student(p_student_id, p_receipt_prefix);
-- which leaves a real student's prefix exactly as passed, and gives a
-- TEST-session student its session's own prefix — never one a real session
-- uses, falling back to 'TST'.
--
-- Data: TEST-2026-27's fee_policy_configs.receipt_prefix becomes 'TST' (it was
-- 'SVP'), so the desk shows and passes TST too. That value is One-owned and is
-- registered in vppsone.one_owned_fee_settings: the mirror sync never copies it
-- back from the fees app (where TEST-2026-27 still says SVP).
--
-- Proof: scripts/migrate/verify-fee-writes-guard.sql posts one rupee to a
-- TEST-2026-27 student inside a block that rolls back, and checks the number
-- starts with TST.
--
-- Rollback:
--   select vppsone.remove_fee_function_preamble('<each function>', '-- [vppsone:test-receipt-prefix]');
--   update public.fee_policy_configs set receipt_prefix = 'SVP' where academic_session_label = 'TEST-2026-27';
--   delete from vppsone.one_owned_fee_settings where source_table = 'fee_policy_configs';
--   drop function vppsone.receipt_prefix_for_student(uuid, text);
-- ============================================================================

create or replace function vppsone.receipt_prefix_for_student(p_student_id uuid, p_requested text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session text;
  v_prefix text;
begin
  select c.session_label into v_session
  from public.students s
  join public.classes c on c.id = s.class_id
  where s.id = p_student_id;

  if not vppsone.is_test_session_label(v_session) then
    return p_requested;
  end if;

  select nullif(trim(f.receipt_prefix), '') into v_prefix
  from public.fee_policy_configs f
  where f.academic_session_label = v_session;

  -- A test session never shares a prefix with a real one, whatever its
  -- policy row says.
  if v_prefix is null or exists (
    select 1 from public.fee_policy_configs f
    where not vppsone.is_test_session_label(f.academic_session_label)
      and upper(trim(f.receipt_prefix)) = upper(v_prefix)
  ) or upper(v_prefix) = 'SVP' then
    return 'TST';
  end if;

  return v_prefix;
end;
$$;

comment on function vppsone.receipt_prefix_for_student(uuid, text) is
  'The receipt prefix to post with: unchanged for a real student; the test session''s own prefix (TST) for a TEST-session student (D-346).';

revoke all on function vppsone.receipt_prefix_for_student(uuid, text) from public, anon;
grant execute on function vppsone.receipt_prefix_for_student(uuid, text) to authenticated, service_role;

select vppsone.inject_fee_function_preamble(f::regprocedure, '-- [vppsone:test-receipt-prefix]',
  '  p_receipt_prefix := vppsone.receipt_prefix_for_student(p_student_id, p_receipt_prefix);')
from (values
  ('private.post_student_payment_core(uuid, date, payment_mode, integer, text, text, text, text, uuid, integer, integer)'),
  ('public.post_student_payment(uuid, date, payment_mode, integer, text, text, text, text, uuid)'),
  ('public.post_corrected_payment(uuid, date, payment_mode, jsonb, uuid, text, text, text, text)')
) as t(f);

update public.fee_policy_configs
   set receipt_prefix = 'TST'
 where academic_session_label = 'TEST-2026-27'
   and receipt_prefix is distinct from 'TST';

insert into vppsone.one_owned_fee_settings (source_table, row_key, column_name, reason) values
  ('fee_policy_configs', 'TEST-2026-27', 'receipt_prefix',
   'TEST postings are numbered TST so they never consume real SVP numbers (D-346). The fees app still says SVP; the mirror must not copy it back.')
on conflict do nothing;

-- ======================================================== fee-migrations/20261030230200_fee_writes_table_guard.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): the fee writes switch also guards the
-- money TABLES, and only the database owner can turn it (D-345, D-346;
-- critique0 #24; review of PR #141).
--
-- Why this differs from the fees app: the fees app has no switch at all (see
-- 20261030230000_fee_writes_guard.sql). That file put the guard at the top of
-- the 15 money RPCs. Two doors were still open over PostgREST:
--
--  1. Direct table writes. `authenticated` holds INSERT/UPDATE/DELETE on the
--     money tables (private.post_student_payment_core is SECURITY INVOKER and
--     inserts as the caller, so the grants cannot simply be revoked), and RLS
--     lets anybody with 'payments:write' / 'fees:write' / … write them. So an
--     accountant with the anon key and their own JWT could insert a payment
--     for a real student during mirror mode. Now a BEFORE row trigger on every
--     table that carries fee money for a student asks the same question the
--     RPCs ask — vppsone.assert_fee_writes_allowed(student_id), for the OLD
--     row and for the NEW one — and a statement trigger refuses TRUNCATE.
--     Moving a student across the TEST/real boundary (students.class_id) or
--     relabelling a class across it (classes.session_label) is refused too
--     while real writes are closed: otherwise "move a real student into a TEST
--     class, post, move back" walks round the TEST exemption.
--
--  2. The switch itself. It lives in public.app_settings, which any admin can
--     write over PostgREST ('settings:write' policies; has_permission() is
--     true for every permission of an admin). Now the key `fee_writes_enabled`
--     can be inserted, changed or deleted only by a session that did not come
--     through the API — the owner in the SQL editor / MCP, as postgres — the
--     same rule as vppsone.deployment. Not anon, not authenticated, not even
--     the service role (no app screen sets it).
--
-- WHO THE TABLE TRIGGERS APPLY TO: every request that came through the API
-- (session_user 'authenticator', or a request.jwt.claims role is present):
-- anon, authenticated AND service_role. The rule is the one the app's fetch
-- guard and the RPC preambles already apply, so a write those allow, this
-- allows. Not to the database owner's own sessions (no JWT): migrations, the
-- mirror loader (scripts/migrate/lib/one-db.mjs connects as postgres) and
-- pg_cron. The cron jobs that move money call RPCs, which keep their preamble.
--
-- CHEAP WHEN OPEN: the triggers first ask vppsone.fee_writes_open() (one
-- app_settings row, one deployment row). Today (marker 'dev', key unset) that
-- is true and no per-student lookup happens.
--
-- Proof: scripts/migrate/verify-fee-writes-guard.sql (cases E–H), rolled back.
--
-- Rollback:
--   drop trigger fee_writes_row_guard on each table listed below;
--   drop trigger fee_writes_truncate_guard on each table listed below;
--   drop trigger fee_writes_class_move_guard on public.students;
--   drop trigger fee_writes_class_relabel_guard on public.classes;
--   drop trigger fee_writes_switch_owner_only on public.app_settings;
--   drop function vppsone.fee_money_row_guard(), vppsone.fee_money_truncate_guard(),
--     vppsone.fee_student_class_move_guard(), vppsone.fee_class_relabel_guard(),
--     vppsone.fee_writes_switch_owner_only(), vppsone.request_via_api(),
--     vppsone.fee_writes_open();
--   and restore fee_writes_allowed_for_session from 20261030230000.
-- ============================================================================

/* ------------------------------------------------------------ the rule */

-- Real-session fee writes are open: the key is not 'false', and on a
-- production database it is exactly 'true'.
create or replace function vppsone.fee_writes_open()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_setting text;
begin
  select lower(trim(a.value)) into v_setting
  from public.app_settings a
  where a.key = 'fee_writes_enabled';

  if v_setting = 'false' then
    return false;
  end if;
  if vppsone.is_production() and v_setting is distinct from 'true' then
    return false;
  end if;
  return true;
end;
$$;

comment on function vppsone.fee_writes_open() is
  'Are real-session fee writes open now? app_settings.fee_writes_enabled and vppsone.is_production() (D-345). TEST sessions are writable regardless.';

-- The same rule as before, now said once.
create or replace function vppsone.fee_writes_allowed_for_session(p_session_label text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select vppsone.is_test_session_label(p_session_label) or vppsone.fee_writes_open();
$$;

revoke all on function vppsone.fee_writes_open() from public, anon;
grant execute on function vppsone.fee_writes_open() to authenticated, service_role;

-- Did this statement come through the API (PostgREST / Supabase clients)?
-- session_user is 'authenticator' for every PostgREST request whatever role it
-- switches to, and SECURITY DEFINER does not change session_user. The claims
-- check also catches a postgres session that is impersonating a signed-in user
-- (the verify script does exactly that).
create or replace function vppsone.request_via_api()
returns boolean
language sql
stable
set search_path = ''
as $$
  select session_user::text = 'authenticator'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> '';
$$;

revoke all on function vppsone.request_via_api() from public, anon;
grant execute on function vppsone.request_via_api() to authenticated, service_role;

/* ------------------------------------------------- money rows, row by row */

create or replace function vppsone.fee_money_row_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if vppsone.request_via_api() and not vppsone.fee_writes_open() then
    if tg_op in ('UPDATE', 'DELETE') then
      perform vppsone.assert_fee_writes_allowed(old.student_id);
    end if;
    if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.student_id is distinct from old.student_id) then
      perform vppsone.assert_fee_writes_allowed(new.student_id);
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function vppsone.fee_money_truncate_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if vppsone.request_via_api() and not vppsone.fee_writes_open() then
    raise exception 'Fee changes are switched off on this database until go-live (fee_writes_enabled). % cannot be truncated.', tg_table_name
      using errcode = 'VPP01';
  end if;
  return null;
end;
$$;

revoke all on function vppsone.fee_money_row_guard() from public, anon, authenticated;
revoke all on function vppsone.fee_money_truncate_guard() from public, anon, authenticated;

-- Every public table that holds fee money for a student (each has student_id;
-- checked against information_schema on 30 Oct). Payment-desk, ledger,
-- waiver, refund, repayment-plan, carry-forward and discount rows.
do $$
declare
  t text;
begin
  foreach t in array array[
    'payments', 'receipts', 'receipt_adjustments', 'payment_adjustments',
    'receipt_finance_adjustments', 'installments', 'student_fee_overrides',
    'student_carry_forward_balances', 'student_late_fee_waivers', 'refund_requests',
    'student_repayment_plans', 'student_repayment_plan_items', 'student_repayment_schedule',
    'student_repayment_emi_late_fees', 'student_repayment_receipt_links',
    'student_conventional_discount_assignments'
  ]
  loop
    execute format('drop trigger if exists fee_writes_row_guard on public.%I', t);
    execute format(
      'create trigger fee_writes_row_guard before insert or update or delete on public.%I '
      'for each row execute function vppsone.fee_money_row_guard()', t);
    execute format('drop trigger if exists fee_writes_truncate_guard on public.%I', t);
    execute format(
      'create trigger fee_writes_truncate_guard before truncate on public.%I '
      'for each statement execute function vppsone.fee_money_truncate_guard()', t);
  end loop;
end;
$$;

/* --------------------------------------- the TEST / real boundary itself */

create or replace function vppsone.fee_student_class_move_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old text;
  v_new text;
begin
  if new.class_id is not distinct from old.class_id
     or not vppsone.request_via_api()
     or vppsone.fee_writes_open() then
    return new;
  end if;
  select c.session_label into v_old from public.classes c where c.id = old.class_id;
  select c.session_label into v_new from public.classes c where c.id = new.class_id;
  if vppsone.is_test_session_label(v_old) is distinct from vppsone.is_test_session_label(v_new) then
    raise exception 'A student cannot be moved between a TEST session and a real one while fee changes are switched off (fee_writes_enabled).'
      using errcode = 'VPP01';
  end if;
  return new;
end;
$$;

create or replace function vppsone.fee_class_relabel_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.session_label is not distinct from old.session_label
     or not vppsone.request_via_api()
     or vppsone.fee_writes_open() then
    return new;
  end if;
  if vppsone.is_test_session_label(old.session_label) is distinct from vppsone.is_test_session_label(new.session_label) then
    raise exception 'A class cannot be moved between a TEST session and a real one while fee changes are switched off (fee_writes_enabled).'
      using errcode = 'VPP01';
  end if;
  return new;
end;
$$;

revoke all on function vppsone.fee_student_class_move_guard() from public, anon, authenticated;
revoke all on function vppsone.fee_class_relabel_guard() from public, anon, authenticated;

drop trigger if exists fee_writes_class_move_guard on public.students;
create trigger fee_writes_class_move_guard
  before update of class_id on public.students
  for each row execute function vppsone.fee_student_class_move_guard();

drop trigger if exists fee_writes_class_relabel_guard on public.classes;
create trigger fee_writes_class_relabel_guard
  before update of session_label on public.classes
  for each row execute function vppsone.fee_class_relabel_guard();

/* ------------------------------------------- the switch is the owner's */

create or replace function vppsone.fee_writes_switch_owner_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if ((tg_op <> 'INSERT' and old.key = 'fee_writes_enabled')
      or (tg_op <> 'DELETE' and new.key = 'fee_writes_enabled'))
     and vppsone.request_via_api() then
    raise exception 'fee_writes_enabled is set by the owner in the SQL editor, not from the app or the API (D-345).'
      using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function vppsone.fee_writes_switch_owner_only() from public, anon, authenticated;

drop trigger if exists fee_writes_switch_owner_only on public.app_settings;
create trigger fee_writes_switch_owner_only
  before insert or update or delete on public.app_settings
  for each row execute function vppsone.fee_writes_switch_owner_only();

-- TRUNCATE public.app_settings would unset the key. Unset on production is
-- closed (fail closed); on dev it is already open. So it opens nothing, but
-- the API has no business truncating settings either.
drop trigger if exists fee_writes_switch_truncate_guard on public.app_settings;
create trigger fee_writes_switch_truncate_guard
  before truncate on public.app_settings
  for each statement execute function vppsone.fee_money_truncate_guard();

-- ======================================================== fee-migrations/20261031000100_fee_user_from_staff_profile.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): public.users is DERIVED from
-- vppsone.staff_profiles for every One account (D-350, default — the owner
-- may overrule; plan §1.4, Q5, D-207).
--
-- Why this differs from the fees app: in the fees app `public.users` IS the
-- staff record — its role decides `private.current_staff_role()` and so
-- `public.has_permission()` and every fee RLS policy, and an auth.users trigger
-- (`sync_staff_profile_from_auth_users`) creates a `read_only_staff` row for
-- each new sign-in. On One's database there are two staff records, and two
-- authorities would disagree: `current_staff_role()` reads `public.users`
-- FIRST, so a One admin or accountant with a stale or default fee row would
-- fail `has_permission('payments:write')` (plan §1.4). One decides: the role
-- is `vppsone.staff_profiles.role`, and the fee row follows it.
--
--  * vppsone.fee_role_map — One role -> fee role, least privilege. The fees
--    vocabulary is admin, accountant, fee_collector, teacher, view_only (live
--    renamed read_only_staff to view_only on 25 May). Only the three money
--    roles keep a money role; everybody else reads as view_only — office
--    included (D-6: posting is granted one person at a time, through
--    accountant), and teacher included (the fees `teacher` role reads every
--    fee screen; a One teacher has no fees:view at all). It agrees with
--    feeRoleFor() in src/platform/auth/fee-roles.ts except teacher, which is
--    narrower here: a database role is the last line, the app's is a screen.
--  * vppsone.sync_fee_user_from_staff_profile(profile_id) upserts the
--    profile's public.users row (id = auth user, role from the map, active
--    as the profile). A profile without a login has no row.
--  * a trigger on vppsone.staff_profiles runs it whenever role, is_active,
--    user_id or display_name changes; a login moved to another profile
--    leaves the old user's fee row inactive.
--  * every existing profile with a login is derived once, here.
--
-- `sync_staff_profile_from_auth_users` is NOT recreated: One's /staff makes
-- the profile, and this trigger makes the fee row from it, so a second
-- automatic writer keyed on auth.users would only ever be able to contradict
-- the profile. It stays absent on this database (PR-1 did not replay it).
--
-- The mirror load (scripts/migrate/load-snapshot.mjs) never writes the
-- public.users row of a user who has a staff profile, remaps a fees user whose
-- email is a One account onto that account, and re-derives afterwards.
--
-- Rollback:
--   drop trigger staff_profiles_sync_fee_user on vppsone.staff_profiles;
--   drop function vppsone.staff_profiles_sync_fee_user();
--   drop function vppsone.sync_fee_user_from_staff_profile(uuid);
--   drop table vppsone.fee_role_map;
--   (the derived public.users rows stay; delete them by id if wanted)
-- ============================================================================

create table vppsone.fee_role_map (
  one_role vppsone.staff_role primary key,
  fee_role public.staff_role not null,
  why text not null check (char_length(why) between 1 and 300)
);

comment on table vppsone.fee_role_map is
  'One role -> the fee role public.users gets (D-350). Least privilege; staff_profiles is the authority.';

insert into vppsone.fee_role_map (one_role, fee_role, why) values
  ('admin', 'admin', 'Runs the school, including its money.'),
  ('accountant', 'accountant', 'Posts payments and keeps the books (D-6: posting is granted through this role).'),
  ('fee_collector', 'fee_collector', 'Collects fees at the desk.'),
  ('office', 'view_only', 'Reads fees; posting is not the office''s by default (D-6).'),
  ('academic_coordinator', 'view_only', 'No fee duty: the least fee role.'),
  ('exam_coordinator', 'view_only', 'No fee duty: the least fee role.'),
  ('teacher', 'view_only', 'No fees:view in One; the fees teacher role would read every fee screen.'),
  ('view_only', 'view_only', 'Reads only.');

alter table vppsone.fee_role_map enable row level security;
revoke all on vppsone.fee_role_map from public, anon, authenticated;
grant select on vppsone.fee_role_map to service_role;

create or replace function vppsone.sync_fee_user_from_staff_profile(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile vppsone.staff_profiles%rowtype;
  v_role public.staff_role;
begin
  select * into v_profile from vppsone.staff_profiles where id = p_profile_id;
  if not found or v_profile.user_id is null then
    return;
  end if;
  select m.fee_role into v_role from vppsone.fee_role_map m where m.one_role = v_profile.role;
  -- A One role with no row in the map is the least fee role, never a guess upward.
  v_role := coalesce(v_role, 'view_only'::public.staff_role);

  insert into public.users (id, full_name, role, is_active)
  values (v_profile.user_id, v_profile.display_name, v_role, v_profile.is_active)
  on conflict (id) do update
    set role = excluded.role,
        is_active = excluded.is_active,
        full_name = excluded.full_name
    where (public.users.role, public.users.is_active, public.users.full_name)
      is distinct from (excluded.role, excluded.is_active, excluded.full_name);
end;
$$;

comment on function vppsone.sync_fee_user_from_staff_profile(uuid) is
  'Derive public.users (the fee role row) from a staff profile through vppsone.fee_role_map (D-350).';

revoke all on function vppsone.sync_fee_user_from_staff_profile(uuid) from public, anon, authenticated;
grant execute on function vppsone.sync_fee_user_from_staff_profile(uuid) to service_role;

create or replace function vppsone.staff_profiles_sync_fee_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.user_id is not null and old.user_id is distinct from new.user_id then
    update public.users set is_active = false where id = old.user_id and is_active;
  end if;
  perform vppsone.sync_fee_user_from_staff_profile(new.id);
  return null;
end;
$$;

revoke all on function vppsone.staff_profiles_sync_fee_user() from public, anon, authenticated;

create trigger staff_profiles_sync_fee_user
  after insert or update of role, is_active, user_id, display_name on vppsone.staff_profiles
  for each row execute function vppsone.staff_profiles_sync_fee_user();

-- Every existing profile with a login, once.
select vppsone.sync_fee_user_from_staff_profile(sp.id)
from vppsone.staff_profiles sp
where sp.user_id is not null;

-- ======================================================== fee-migrations/20261031000200_test_account_fee_write_fence.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): a TEST ACCOUNT writes fee rows only for
-- TEST-session students, over every API path (Phase 3, D-340, owner T1;
-- PR #143 review).
--
-- Why this differs from the fees app: the fees app has no test accounts. On
-- One's database test accounts are real logins (the 39 QA / Smoke Lab /
-- day-run profiles), and D-350 derives their public.users role from their One
-- role — so a test admin is fee role admin, a test accountant is accountant,
-- a test fee collector is fee_collector. Fee RLS is permission-only (no
-- session condition), so their JWT could INSERT / UPDATE / DELETE real fee
-- rows over PostgREST directly, past the app's fence, and the D-347 triggers
-- only ask whether real writes are open (fee_writes_enabled), which they will
-- be from go-live.
--
-- Why not give test accounts view_only instead (the review's option b): the
-- app's fee screens write through the signed-in person's own client, so a
-- view_only test accountant could not post a TEST payment — and testing in
-- TEST-2026-27 is what test accounts are for (T1). The role stays; the
-- session is fenced, row by row:
--
--  * vppsone.fee_money_row_guard() (every money table, D-347) now also
--    refuses, whenever a test account is signed in, an OLD or NEW row whose
--    student is not in a TEST session — fee_writes_enabled or not.
--  * public.students: a test account may insert, change or delete a student
--    only in a TEST class (old and new class).
--  * public.classes, public.academic_sessions: only TEST-labelled rows. This
--    also stops a test admin making TEST-2026-27 the current session (the
--    single-current trigger updates the real rows, and is refused).
--  * public.app_settings: a test account writes only keys that name a TEST
--    session (the reminder screen's per-session "last used" key); never
--    active_session_label or the school's WhatsApp switches.
--
-- WHO: requests that came through the API (vppsone.request_via_api()) AND
-- carry a signed-in test account (vppsone.current_is_test_account(): the
-- JWT's auth.uid() → an active staff profile with is_test_account). The
-- service role has no auth.uid() and is fenced by the app; the owner's own
-- sessions (migrations, the mirror loader, pg_cron) are not touched. A real
-- account pays one indexed lookup (staff_profiles.user_id is unique).
--
-- Proof: scripts/verify-test-session-fence.sql, cases J–N, rolled back.
--
-- Rollback:
--   drop trigger test_account_student_guard on public.students;
--   drop trigger test_account_session_row_guard on public.classes;
--   drop trigger test_account_session_row_guard on public.academic_sessions;
--   drop trigger test_account_settings_guard on public.app_settings;
--   drop function vppsone.test_account_student_guard(),
--     vppsone.test_account_session_row_guard(),
--     vppsone.test_account_settings_guard(),
--     vppsone.assert_test_account_may_write_student(uuid),
--     vppsone.assert_test_account_may_write_session(text);
--   and restore vppsone.fee_money_row_guard() from 20261030230200.
-- ============================================================================

create or replace function vppsone.assert_test_account_may_write_session(p_session_label text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not vppsone.is_test_session(p_session_label) then
    raise exception 'A test account changes only TEST-session data.'
      using errcode = '42501',
            hint = 'Sign in with a real account to change a real session (D-340).';
  end if;
end;
$$;

-- No student, no class or no session: refused (fail closed for a test account).
create or replace function vppsone.assert_test_account_may_write_student(p_student_id uuid)
returns void
language sql
stable
security definer
set search_path = ''
as $$
  select vppsone.assert_test_account_may_write_session(
    (select c.session_label
       from public.students s
       join public.classes c on c.id = s.class_id
      where s.id = p_student_id)
  );
$$;

revoke all on function vppsone.assert_test_account_may_write_session(text) from public, anon;
revoke all on function vppsone.assert_test_account_may_write_student(uuid) from public, anon;
grant execute on function vppsone.assert_test_account_may_write_session(text) to authenticated, service_role;
grant execute on function vppsone.assert_test_account_may_write_student(uuid) to authenticated, service_role;

/* ------------------------------------------- money rows: the D-347 guard + */

create or replace function vppsone.fee_money_row_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if vppsone.request_via_api() then
    -- A test account: TEST-session students only, old row and new.
    if vppsone.current_is_test_account() then
      if tg_op in ('UPDATE', 'DELETE') then
        perform vppsone.assert_test_account_may_write_student(old.student_id);
      end if;
      if tg_op in ('INSERT', 'UPDATE') then
        perform vppsone.assert_test_account_may_write_student(new.student_id);
      end if;
    end if;
    -- Everybody: real-session writes only while they are open (D-345).
    if not vppsone.fee_writes_open() then
      if tg_op in ('UPDATE', 'DELETE') then
        perform vppsone.assert_fee_writes_allowed(old.student_id);
      end if;
      if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.student_id is distinct from old.student_id) then
        perform vppsone.assert_fee_writes_allowed(new.student_id);
      end if;
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

/* ------------------------------------------------------------- students */

create or replace function vppsone.test_account_student_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_label text;
begin
  if vppsone.request_via_api() and vppsone.current_is_test_account() then
    if tg_op in ('UPDATE', 'DELETE') then
      select c.session_label into v_label from public.classes c where c.id = old.class_id;
      perform vppsone.assert_test_account_may_write_session(v_label);
    end if;
    if tg_op in ('INSERT', 'UPDATE') then
      select c.session_label into v_label from public.classes c where c.id = new.class_id;
      perform vppsone.assert_test_account_may_write_session(v_label);
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function vppsone.test_account_student_guard() from public, anon, authenticated;

drop trigger if exists test_account_student_guard on public.students;
create trigger test_account_student_guard
  before insert or update or delete on public.students
  for each row execute function vppsone.test_account_student_guard();

/* ------------------------------------- classes and academic sessions */

create or replace function vppsone.test_account_session_row_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if vppsone.request_via_api() and vppsone.current_is_test_account() then
    if tg_op in ('UPDATE', 'DELETE') then
      perform vppsone.assert_test_account_may_write_session(old.session_label);
    end if;
    if tg_op in ('INSERT', 'UPDATE') then
      perform vppsone.assert_test_account_may_write_session(new.session_label);
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function vppsone.test_account_session_row_guard() from public, anon, authenticated;

drop trigger if exists test_account_session_row_guard on public.classes;
create trigger test_account_session_row_guard
  before insert or update or delete on public.classes
  for each row execute function vppsone.test_account_session_row_guard();

drop trigger if exists test_account_session_row_guard on public.academic_sessions;
create trigger test_account_session_row_guard
  before insert or update or delete on public.academic_sessions
  for each row execute function vppsone.test_account_session_row_guard();

/* ------------------------------------------------------------ settings */

create or replace function vppsone.test_account_settings_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if vppsone.request_via_api() and vppsone.current_is_test_account() then
    if (tg_op <> 'INSERT' and old.key !~* '(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}')
       or (tg_op <> 'DELETE' and new.key !~* '(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}') then
      raise exception 'A test account changes only settings that belong to a TEST session.'
        using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function vppsone.test_account_settings_guard() from public, anon, authenticated;

drop trigger if exists test_account_settings_guard on public.app_settings;
create trigger test_account_settings_guard
  before insert or update or delete on public.app_settings
  for each row execute function vppsone.test_account_settings_guard();

-- ======================================================== migrations/20261031040453_parent_send_gate.sql
-- One gate for every WhatsApp message to a parent (go-live Phase D; plan §6.3,
-- critique0 #10, #30; D-353).
--
-- `src/modules/whatsapp/data/aisensy.ts` refuses a parent send unless, in
-- order: the deployment is VPPSONE_ENV=live, `runtime_flags.parent_dispatch`
-- is on, `runtime_flags.parent_dispatch_categories` lists the notice's kind,
-- and — when the session is a test session, the actor is a test account, or
-- the deployment is not Vercel production — the destination is in
-- `message_test_recipients`. Every read that fails refuses.
--
-- What this migration adds:
--
--  * `runtime_flags.value` (jsonb), for the two switches that are not a plain
--    on/off: `parent_dispatch_categories` (a JSON array of notice kinds) and
--    `absent_notice_owner` ("fees_notice" or "native": which path may tell a
--    parent their child is absent, so a family never gets both).
--  * `parent_dispatch_categories` seeded to `[]`: no category may send until
--    the owner names it.
--  * `absent_notice_owner` seeded to "fees_notice": the fees app's school
--    notice is how parents are told today, and One's native register message
--    (D-320) stays behind the approval rules of D-10 either way.
--  * `message_test_recipients`: the only numbers a test session, a test
--    account or a non-production deployment may message. Empty: numbers are
--    added by the operator in SQL, never by a migration (rule 6).
--
-- Additive. Service role reads all of it; `authenticated` keeps its existing
-- SELECT on runtime_flags (table-level, so the new column is covered) and gets
-- nothing on the allowlist.
--
-- Rollback:
--   drop table vppsone.message_test_recipients;
--   delete from vppsone.runtime_flags where key in ('parent_dispatch_categories', 'absent_notice_owner');
--   alter table vppsone.runtime_flags drop constraint runtime_flags_key_known;
--   alter table vppsone.runtime_flags add constraint runtime_flags_key_known check (
--     key in ('cover_command', 'staff_notice_dispatch', 'fault_injection', 'parent_dispatch'));
--   alter table vppsone.runtime_flags drop column value;

alter table vppsone.runtime_flags add column if not exists value jsonb;

alter table vppsone.runtime_flags drop constraint if exists runtime_flags_key_known;
alter table vppsone.runtime_flags add constraint runtime_flags_key_known check (
  key in (
    'cover_command',
    'staff_notice_dispatch',
    'fault_injection',
    'parent_dispatch',
    'parent_dispatch_categories',
    'absent_notice_owner'
  )
);

alter table vppsone.runtime_flags drop constraint if exists runtime_flags_value_shape;
alter table vppsone.runtime_flags add constraint runtime_flags_value_shape check (
  case key
    when 'parent_dispatch_categories' then value is not null and jsonb_typeof(value) = 'array'
    when 'absent_notice_owner' then value is null or value in ('"fees_notice"'::jsonb, '"native"'::jsonb)
    else true
  end
);

insert into vppsone.runtime_flags (key, enabled, value, note) values
  ('parent_dispatch_categories', true, '[]'::jsonb,
   'Notice kinds that may reach a parent once parent_dispatch is on: fee_reminder, receipt, reversal, fee_statement, school_notice, absent_notice, collection_request, report_delivery, general. Empty until the owner names them.'),
  ('absent_notice_owner', true, '"fees_notice"'::jsonb,
   'Which path tells a parent their child is absent: fees_notice (the ported school notice) or native (the register message, D-320). Never both.')
on conflict (key) do nothing;

comment on column vppsone.runtime_flags.value is
  'Structured value for switches that are not plain on/off (parent_dispatch_categories, absent_notice_owner).';

create table if not exists vppsone.message_test_recipients (
  phone_e164 text primary key check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  label text not null check (char_length(label) between 1 and 120),
  added_by uuid references vppsone.staff_profiles (id) on delete set null,
  added_at timestamptz not null default now()
);

comment on table vppsone.message_test_recipients is
  'The only numbers a test session, a test account or a non-production deployment may WhatsApp (plan §6.3). Added by the operator in SQL; never seeded by a migration.';

alter table vppsone.message_test_recipients enable row level security;
revoke all on vppsone.message_test_recipients from public, anon, authenticated;
grant select, insert, update, delete on vppsone.message_test_recipients to service_role;

-- ======================================================== fee-migrations/20261031042100_failure_desk_service_grants.sql
-- ============================================================================
-- VPPS One fee-migration, One-only (go-live Phase D). Applied to
-- wtgxcptmucjerhufzjcf through the Supabase MCP; never to the fees database.
--
-- Why it differs from the fees app: the fees app's
-- 20261030190000_whatsapp_failure_desk.sql grants nothing to service_role on
-- its two new tables, because live's ALTER DEFAULT PRIVILEGES in `public` hand
-- service_role ALL on every new table. One's database has no default
-- privileges there (SCHEMA-PARITY.md: "One stricter"), so after the catch-up
-- the service role could not read the attempts log or the number-health table
-- at all. These are the grants the failure desk's server code needs, and
-- nothing for anon or authenticated beyond the fees file's own SELECT.
-- (The fees file's own staff_payment_alerts grants are explicit and need no
-- help.) Pinned by tests/fee-catch-up-phase-d.test.ts.
-- ============================================================================

grant select, insert, update, delete on public.whatsapp_send_attempts to service_role;
grant select, insert, update, delete on public.whatsapp_number_health to service_role;

-- ======================================================== migrations/20261031084012_parent_dispatch_test_only.sql
-- Test-only parent sending (owner, 31 Oct): AiSensy can be verified on the
-- owner's approved numbers while parent sending stays closed.
--
-- Before this, `src/platform/messaging/parent-send-gate.ts` refused every send
-- at `parent_dispatch = off`, before it ever looked at the allowlist, so the
-- only way to test a real send was to open sends to real parents.
--
-- `runtime_flags.parent_dispatch_test_only` (seeded OFF):
--   parent_dispatch OFF, test_only OFF -> every parent send refused (as before);
--   parent_dispatch OFF, test_only ON  -> a send passes ONLY when its number is
--     in `vppsone.message_test_recipients`, whatever the session or the sender;
--     `_v6` is still refused, VPPSONE_ENV must still be `live`, the category
--     list is not consulted;
--   parent_dispatch ON                 -> the gate as before (test_only unused).
-- A read that fails refuses. The switch is the operator's, set in SQL
-- (docs/cutover/AISENSY-TEMPLATES.md, "Test-only sending"); no app screen
-- writes it.
--
-- Grants: none new. `runtime_flags` keeps its table-level grants — the service
-- role reads and updates every row (the gate reads with it), `authenticated`
-- may only SELECT, `anon` nothing. Checked after applying with
-- has_table_privilege; pinned in tests/parent-send-gate.test.ts.
--
-- Rollback:
--   delete from vppsone.runtime_flags where key = 'parent_dispatch_test_only';
--   alter table vppsone.runtime_flags drop constraint runtime_flags_key_known;
--   alter table vppsone.runtime_flags add constraint runtime_flags_key_known check (
--     key in ('cover_command', 'staff_notice_dispatch', 'fault_injection', 'parent_dispatch',
--             'parent_dispatch_categories', 'absent_notice_owner'));

alter table vppsone.runtime_flags drop constraint if exists runtime_flags_key_known;
alter table vppsone.runtime_flags add constraint runtime_flags_key_known check (
  key in (
    'cover_command',
    'staff_notice_dispatch',
    'fault_injection',
    'parent_dispatch',
    'parent_dispatch_categories',
    'absent_notice_owner',
    'parent_dispatch_test_only'
  )
);

insert into vppsone.runtime_flags (key, enabled, value, note) values
  ('parent_dispatch_test_only', false, null,
   'While parent_dispatch is off: on = a parent WhatsApp may go ONLY to a number in vppsone.message_test_recipients (testing AiSensy on approved numbers). Off = nothing goes. Ignored once parent_dispatch is on.')
on conflict (key) do nothing;

-- ======================================================== fee-migrations/20261031090000_school_notice_sends_service_grants.sql
-- ============================================================================
-- VPPS One fee-migration, One-only (owner decisions phase, 31 Oct). Applied to
-- wtgxcptmucjerhufzjcf through the Supabase MCP; never to the fees database.
--
-- Why it differs from the fees app: the fees app's
-- 20261026120040_school_notice_sends.sql grants nothing on its new table,
-- because live's ALTER DEFAULT PRIVILEGES in `public` hand anon, authenticated
-- and service_role ALL on every new table. One's database has no default
-- privileges there (SCHEMA-PARITY.md: "One stricter"), so after the catch-up
-- `public.school_notice_sends` had NO grant at all: only its owner could use
-- it, and the ported school-notice sender — which reads and writes it with the
-- SERVICE-ROLE client (`createAdminClient()` in
-- src/app/(app)/fees/reminders/notices/{page,actions}.ts →
-- src/modules/whatsapp/data/school-notice-sender.ts: select, insert, update;
-- never delete) — would fail on its first read. Found by the 31 Oct
-- live-vs-One catalog diff.
--
-- These are exactly the privileges that code uses. Nothing for anon, and
-- nothing for authenticated: no app path reads this table through the user's
-- client (the fees file's "staff read" policy stays, unused). Pinned by
-- tests/fee-migrations-owner-decisions.test.ts.
--
-- Rollback: revoke select, insert, update on public.school_notice_sends from service_role;
-- ============================================================================

grant select, insert, update on public.school_notice_sends to service_role;

-- ======================================================== migrations/20261031101234_staff_whatsapp_consent_and_gates.sql
-- WhatsApp to staff: consent, per-kind switches, caps, new events (go-live
-- Phase F; plan §8; D-344, D-356; critique1 A10, B13, C1).
--
-- The staff outbox (`staff_notices`, P3/P4, D-214) learns four things here:
--
--  1. Consent. `staff_profiles.whatsapp_opt_in_at` / `_source` ('form' — the
--     paper form at training, 'self' — /preferences, 'admin_recorded' — an
--     admin in /staff) / `_opt_out_at`. No consent, no send. And
--     `staff_notice_prefs(staff_profile_id, kind, enabled)`: a person may turn
--     a kind off for themselves (no row = not chosen = on, consent covers it).
--  2. Switches and limits, in `runtime_flags`:
--       staff_notice_kinds_enabled  {kind: true|false} — a kind not named true
--                                   does not go. Existing kinds on, new kinds
--                                   off until the owner names them (Q15).
--       staff_whatsapp_month_cap    a number, AiSensy sends a month (1000).
--       staff_notice_student_names  off: a staff message says "a student of
--                                   5-A", never a child's name.
--     `staff_notice_dispatch` stays the instant kill switch.
--  3. New kinds with a payload instead of a duty or a register (online
--     payment review/received, the day's collection, day not closed, money
--     requests and decisions, leave, and the three that used to be "send by
--     hand" through message_sends: marks reminder, weekly summary, staff
--     notice). Triggers on `fee_desk_requests` and `teacher_leave` queue the
--     money and leave notices in the same transaction as the request.
--  4. The claim now reads every fact the gate needs (consent, prefs, the kinds
--     map, today's and this month's sends, a burst of the same kind, whether
--     the number is on the test allowlist) in the transaction that leases the
--     notice. The app decides (src/modules/staff-notices/domain/gates.ts) and
--     either sends, or hands the claim back: `release_staff_notice` suppresses
--     it or holds it until a time (the 07:00 window, a digest hold), and
--     `digest_staff_notices` folds the rest of a burst into the one sent.
--
-- Also: the template name is settled — the outbox sends
-- `vppsone_staff_attendance_reminder` (four slots); the older one-slot
-- `vppsone_attendance_reminder` row is switched off (is_active false), not
-- deleted. Every staff template is registered in `message_templates`.
--
-- No fee table is altered; the triggers' payload READS `public.students` and
-- `public.classes` for a class label. Nothing is sent by this migration.
--
-- Grants: the service role does everything (the app's server writes); the
-- browser gets SELECT on its own prefs only. `authenticated` keeps its column
-- grants on staff_profiles unchanged (the consent columns are read with the
-- service role).
--
-- Rollback:
--   drop trigger fee_desk_requests_staff_notices on vppsone.fee_desk_requests;
--   drop trigger teacher_leave_staff_notices on vppsone.teacher_leave;
--   drop function vppsone.fee_desk_request_staff_notices(), vppsone.teacher_leave_staff_notices(),
--     vppsone.queue_staff_notice(text, text, uuid, text, jsonb, timestamptz, uuid),
--     vppsone.queue_staff_notice_to_permission(text, text, text, text, jsonb, timestamptz, uuid, uuid),
--     vppsone.release_staff_notice(uuid, text, text, text, timestamptz),
--     vppsone.digest_staff_notices(uuid, text), vppsone.student_notice_facts(uuid);
--   re-create claim_staff_notice from 20261004051407;
--   drop table vppsone.staff_notice_prefs;
--   alter table vppsone.staff_notices drop column payload, drop column requested_by, drop column digest_into;
--   restore staff_notices_kind_known / staff_notices_names_its_subject from 20261004051407;
--   delete from vppsone.runtime_flags where key in ('staff_notice_kinds_enabled','staff_whatsapp_month_cap','staff_notice_student_names');
--   alter table vppsone.staff_profiles drop column whatsapp_opt_in_at, drop column whatsapp_opt_in_source,
--     drop column whatsapp_opt_in_recorded_by, drop column whatsapp_opt_out_at;

/* ------------------------------------------------------------- consent */

alter table vppsone.staff_profiles
  add column if not exists whatsapp_opt_in_at timestamptz,
  add column if not exists whatsapp_opt_in_source text,
  add column if not exists whatsapp_opt_in_recorded_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column if not exists whatsapp_opt_out_at timestamptz;

alter table vppsone.staff_profiles drop constraint if exists staff_profiles_whatsapp_opt_in_source_known;
alter table vppsone.staff_profiles add constraint staff_profiles_whatsapp_opt_in_source_known check (
  whatsapp_opt_in_source is null or whatsapp_opt_in_source in ('form', 'self', 'admin_recorded')
);
alter table vppsone.staff_profiles drop constraint if exists staff_profiles_whatsapp_opt_in_together;
alter table vppsone.staff_profiles add constraint staff_profiles_whatsapp_opt_in_together check (
  (whatsapp_opt_in_at is null) = (whatsapp_opt_in_source is null)
);

comment on column vppsone.staff_profiles.whatsapp_opt_in_at is
  'When this person agreed to WhatsApp messages from the school app. Null: never asked — nothing is sent (plan §8.3).';
comment on column vppsone.staff_profiles.whatsapp_opt_in_source is
  'How the consent was given: form (paper, at training), self (/preferences) or admin_recorded (/staff, the admin records consent collected in person).';
comment on column vppsone.staff_profiles.whatsapp_opt_out_at is
  'When they opted out. An opt-out at or after the opt-in wins.';

create table if not exists vppsone.staff_notice_prefs (
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  kind text not null check (kind ~ '^[a-z_]{3,40}$'),
  enabled boolean not null,
  updated_at timestamptz not null default now(),
  primary key (staff_profile_id, kind)
);

comment on table vppsone.staff_notice_prefs is
  'A person''s own on/off for one kind of staff WhatsApp. No row = not chosen = on (consent covers it).';

alter table vppsone.staff_notice_prefs enable row level security;
drop policy if exists staff_notice_prefs_select_own on vppsone.staff_notice_prefs;
create policy staff_notice_prefs_select_own on vppsone.staff_notice_prefs for select to authenticated
  using (staff_profile_id = (select vppsone.current_staff_profile_id()));
revoke all on vppsone.staff_notice_prefs from public, anon, authenticated;
grant select on vppsone.staff_notice_prefs to authenticated;
grant select, insert, update, delete on vppsone.staff_notice_prefs to service_role;

/* ------------------------------------------------------------ switches */

alter table vppsone.runtime_flags drop constraint if exists runtime_flags_key_known;
alter table vppsone.runtime_flags add constraint runtime_flags_key_known check (
  key in (
    'cover_command',
    'staff_notice_dispatch',
    'fault_injection',
    'parent_dispatch',
    'parent_dispatch_categories',
    'absent_notice_owner',
    'parent_dispatch_test_only',
    'staff_notice_kinds_enabled',
    'staff_whatsapp_month_cap',
    'staff_notice_student_names'
  )
);

alter table vppsone.runtime_flags drop constraint if exists runtime_flags_value_shape;
alter table vppsone.runtime_flags add constraint runtime_flags_value_shape check (
  case key
    when 'parent_dispatch_categories' then value is not null and jsonb_typeof(value) = 'array'
    when 'absent_notice_owner' then value is null or value in ('"fees_notice"'::jsonb, '"native"'::jsonb)
    when 'staff_notice_kinds_enabled' then value is not null and jsonb_typeof(value) = 'object'
    when 'staff_whatsapp_month_cap' then value is not null and jsonb_typeof(value) = 'number'
      and (value #>> '{}')::numeric > 0
    else true
  end
);

insert into vppsone.runtime_flags (key, enabled, value, note) values
  ('staff_notice_kinds_enabled', true,
   '{"cover_assigned": true, "cover_changed": true, "cover_cancelled": true, "cover_escalation": true, "attendance_reminder": true, "marks_reminder": false, "weekly_summary": false, "staff_broadcast": false, "online_review": false, "online_payment": false, "day_collection": false, "day_not_closed": false, "money_request": false, "money_decision": false, "leave_requested": false, "leave_decided": false, "teacher_task": true}'::jsonb,
   'Which kinds of staff WhatsApp may go, by name: a kind not set to true does not go. Existing kinds on; new kinds off until the owner names them (plan Q15). Consent is still asked of every person.'),
  ('staff_whatsapp_month_cap', true, '1000'::jsonb,
   'AiSensy sends to staff a month (IST), all kinds together. Reached: nothing more goes until the 1st. Off or missing: nothing goes.'),
  ('staff_notice_student_names', false, null,
   'On: a staff WhatsApp may name the child (money requests, online payments). Off: it says "a student of 5-A".')
on conflict (key) do nothing;

/* ------------------------------------------------------- the outbox rows */

alter table vppsone.staff_notices
  add column if not exists payload jsonb,
  add column if not exists requested_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column if not exists digest_into uuid references vppsone.staff_notices (id) on delete set null;

comment on column vppsone.staff_notices.payload is
  'For a kind that is not about a duty or a register: what the message needs, written when it was queued. Never a phone number.';
comment on column vppsone.staff_notices.requested_by is
  'Who queued it by hand (a reminder, a staff notice), so they can take it back before it goes.';
comment on column vppsone.staff_notices.digest_into is
  'Folded into this notice''s digest message instead of going on its own.';

alter table vppsone.staff_notices drop constraint if exists staff_notices_kind_known;
alter table vppsone.staff_notices add constraint staff_notices_kind_known check (
  kind in (
    'cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation', 'attendance_reminder',
    'marks_reminder', 'weekly_summary', 'staff_broadcast', 'online_review', 'online_payment',
    'day_collection', 'day_not_closed', 'money_request', 'money_decision', 'leave_requested', 'leave_decided'
  )
);

alter table vppsone.staff_notices drop constraint if exists staff_notices_names_its_subject;
alter table vppsone.staff_notices add constraint staff_notices_names_its_subject check (
  (kind in ('cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation')
    and duty_id is not null and duty_revision is not null and period is not null)
  or (kind = 'attendance_reminder' and duty_id is null and class_id is not null)
  or (kind not in ('cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation', 'attendance_reminder')
    and duty_id is null and payload is not null and jsonb_typeof(payload) = 'object')
);

create index if not exists staff_notices_by_staff_kind_idx
  on vppsone.staff_notices (staff_profile_id, kind, status);
create index if not exists staff_notice_attempts_started_idx
  on vppsone.staff_notice_attempts (started_at);
create index if not exists staff_notice_attempts_notice_idx
  on vppsone.staff_notice_attempts (notice_id);

/* ----------------------------------------------------------- queueing */

/*
 * Queue one notice for one person. A test account is never told about a real
 * session (its number is a test number or nothing, and real data is not its
 * to see); an inactive profile is skipped. Idempotent on the key.
 */
create or replace function vppsone.queue_staff_notice(
  p_key text,
  p_kind text,
  p_staff uuid,
  p_session text,
  p_payload jsonb,
  p_not_after timestamptz default null,
  p_requested_by uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_test boolean;
  v_id uuid;
begin
  if p_staff is null or coalesce(p_session, '') = '' then
    return null;
  end if;
  select is_test_account into v_test
  from vppsone.staff_profiles where id = p_staff and is_active;
  if not found then
    return null;
  end if;
  if v_test and not vppsone.is_test_session_label(p_session) then
    return null;
  end if;

  insert into vppsone.staff_notices (
    notice_key, kind, staff_profile_id, session_label, day, not_after, command_id, payload, requested_by
  ) values (
    p_key, p_kind, p_staff, p_session, (now() at time zone 'Asia/Kolkata')::date,
    coalesce(p_not_after, now() + interval '3 days'), gen_random_uuid(), coalesce(p_payload, '{}'::jsonb), p_requested_by
  )
  on conflict (notice_key) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

/* Queue one each for every active holder of a permission, but the one excluded. */
create or replace function vppsone.queue_staff_notice_to_permission(
  p_key_prefix text,
  p_kind text,
  p_permission text,
  p_session text,
  p_payload jsonb,
  p_not_after timestamptz default null,
  p_exclude uuid default null,
  p_exclude_too uuid default null
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_count integer := 0;
begin
  for v_staff in
    select sp.id from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where rp.permission = p_permission and sp.is_active
      and sp.id is distinct from p_exclude and sp.id is distinct from p_exclude_too
    order by sp.id
  loop
    if vppsone.queue_staff_notice(p_key_prefix || ':' || v_staff::text, p_kind, v_staff, p_session, p_payload, p_not_after) is not null then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

/* A student's name and class label for a payload. The name is used only when the school allows it. */
create or replace function vppsone.student_notice_facts(p_student uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
      'student_name', s.full_name,
      'class_label', concat_ws(' ', c.class_name, nullif(c.section, ''))
    )
    from public.students s
    left join public.classes c on c.id = s.class_id
    where s.id = p_student
  ), '{}'::jsonb)
$$;

/* A reversal or write-off asked for → every admin; decided → whoever asked. */
create or replace function vppsone.fee_desk_request_staff_notices()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  begin
    v_payload := jsonb_build_object(
      'request_id', new.id,
      'request_kind', new.kind,
      'amount', new.amount,
      'receipt_number', new.receipt_number,
      'requested_by_name', new.requested_by_name
    ) || vppsone.student_notice_facts(new.student_id);

    if tg_op = 'INSERT' and new.status = 'pending' then
      perform vppsone.queue_staff_notice_to_permission(
        'money_request:' || new.id::text, 'money_request', 'fees:manage', new.session_label,
        v_payload, now() + interval '3 days', new.requested_by
      );
    elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'declined')
      and new.requested_by is not null and new.decided_by is distinct from new.requested_by then
      perform vppsone.queue_staff_notice(
        'money_decision:' || new.id::text, 'money_decision', new.requested_by, new.session_label,
        v_payload || jsonb_build_object('decision', new.status), now() + interval '3 days'
      );
    end if;
  exception when others then
    -- A notice never stops the request it is about.
    raise warning 'staff notice for fee_desk_request % not queued: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists fee_desk_requests_staff_notices on vppsone.fee_desk_requests;
create trigger fee_desk_requests_staff_notices
  after insert or update of status on vppsone.fee_desk_requests
  for each row execute function vppsone.fee_desk_request_staff_notices();

/* Leave asked for → whoever arranges cover; decided → the teacher. The note is never put in a notice. */
create or replace function vppsone.teacher_leave_staff_notices()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  begin
    v_payload := jsonb_build_object(
      'leave_id', new.id,
      'teacher_name', (select display_name from vppsone.staff_profiles where id = new.staff_profile_id),
      'from_day', new.from_day,
      'to_day', new.to_day,
      'span', new.span
    );
    if tg_op = 'INSERT' and new.status = 'asked' then
      perform vppsone.queue_staff_notice_to_permission(
        'leave_requested:' || new.id::text, 'leave_requested', 'substitutions:manage', new.session_label,
        v_payload, now() + interval '3 days', new.requested_by, new.staff_profile_id
      );
    elsif tg_op = 'UPDATE' and old.status = 'asked' and new.status in ('approved', 'declined')
      and new.decided_by is distinct from new.staff_profile_id then
      perform vppsone.queue_staff_notice(
        'leave_decided:' || new.id::text, 'leave_decided', new.staff_profile_id, new.session_label,
        v_payload || jsonb_build_object('decision', new.status), now() + interval '3 days'
      );
    end if;
  exception when others then
    raise warning 'staff notice for teacher_leave % not queued: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists teacher_leave_staff_notices on vppsone.teacher_leave;
create trigger teacher_leave_staff_notices
  after insert or update of status on vppsone.teacher_leave
  for each row execute function vppsone.teacher_leave_staff_notices();

/* ------------------------------------------------------------ the claim */

create or replace function vppsone.claim_staff_notice(
  p_worker text,
  p_lease_seconds integer,
  p_transport text,
  p_notice_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  n vppsone.staff_notices%rowtype;
  d vppsone.cover_duties%rowtype;
  s vppsone.staff_profiles%rowtype;
  v_destination text;
  v_attempt uuid;
  v_attempt_no integer;
  v_why text;
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_month_start timestamptz := date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_cover constant text[] := array['cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation'];
  v_gate jsonb;
begin
  if not vppsone.flag_enabled('staff_notice_dispatch') then
    return jsonb_build_object('claimed', false, 'reason', 'disabled');
  end if;

  for n in
    select * from vppsone.staff_notices
    where (p_notice_id is null or id = p_notice_id)
      and (
        (status = 'pending' and (next_attempt_at is null or next_attempt_at <= now()))
        or (status = 'failed' and next_attempt_at is not null and next_attempt_at <= now())
      )
    order by not_after, created_at
    limit 20
    for update skip locked
  loop
    d := null;
    if n.duty_id is not null then
      select * into d from vppsone.cover_duties where id = n.duty_id;
    end if;
    select * into s from vppsone.staff_profiles where id = n.staff_profile_id;
    v_destination := vppsone.staff_destination(n.staff_profile_id);
    v_why := null;

    if now() >= n.not_after then
      v_why := 'too_late';
    elsif not s.is_active then
      v_why := 'inactive';
    elsif s.is_test_account and not vppsone.is_test_session_label(n.session_label) then
      -- A test account is never told about a real session.
      v_why := 'test_account_real_session';
    elsif n.kind in ('cover_assigned', 'cover_changed')
      and (d.status <> 'assigned' or d.covering_staff_id is distinct from n.staff_profile_id) then
      v_why := 'duty_changed';
    elsif n.kind = 'cover_cancelled' and d.status in ('assigned', 'needs_help')
      and d.covering_staff_id = n.staff_profile_id then
      v_why := 'duty_restored';
    elsif n.kind = 'cover_escalation' and (d.status <> 'assigned' or d.cannot_cover_at is null) then
      v_why := 'resolved';
    elsif n.kind = 'attendance_reminder' and exists (
      select 1 from vppsone.attendance_registers r
      where r.session_label = n.session_label and r.class_id = n.class_id
        and r.day = n.day and r.period is null and r.revision >= 1
    ) then
      v_why := 'already_saved';
    elsif n.kind = 'attendance_reminder' and not exists (
      select 1 from vppsone.class_teachers ct
      where ct.staff_profile_id = n.staff_profile_id and ct.class_id = n.class_id
        and ct.session_label = n.session_label
        and (ct.effective_from is null or ct.effective_from <= n.day)
        and (ct.effective_to is null or ct.effective_to >= n.day)
    ) then
      v_why := 'not_responsible';
    elsif n.kind = 'money_request' and exists (
      select 1 from vppsone.fee_desk_requests r
      where r.id::text = n.payload ->> 'request_id' and r.status <> 'pending'
    ) then
      -- Decided (or withdrawn) before anybody needed telling.
      v_why := 'resolved';
    elsif n.kind = 'leave_requested' and exists (
      select 1 from vppsone.teacher_leave l
      where l.id::text = n.payload ->> 'leave_id' and l.status <> 'asked'
    ) then
      v_why := 'resolved';
    elsif n.kind = 'online_review' and exists (
      select 1 from public.online_payment_captures c
      where c.id::text = n.payload ->> 'capture_id' and c.application_status <> 'review_required'
    ) then
      v_why := 'resolved';
    elsif v_destination is null or length(v_destination) < 10 then
      v_why := 'no_phone';
    end if;

    if v_why is not null then
      update vppsone.staff_notices set status = 'suppressed', status_reason = v_why where id = n.id;
      continue;
    end if;

    -- Everything the gate asks, read now, in this transaction (gates.ts).
    v_gate := jsonb_build_object(
      'optInAt', s.whatsapp_opt_in_at,
      'optOutAt', s.whatsapp_opt_out_at,
      'isTestAccount', coalesce(s.is_test_account, false),
      'isTestSession', vppsone.is_test_session_label(n.session_label),
      'prefEnabled', (
        select p.enabled from vppsone.staff_notice_prefs p
        where p.staff_profile_id = s.id and p.kind = n.kind
      ),
      'kindsEnabled', (
        select case when f.enabled then f.value else null end
        from vppsone.runtime_flags f where f.key = 'staff_notice_kinds_enabled'
      ),
      'sentToday', (
        select count(*) from vppsone.staff_notice_attempts a
        join vppsone.staff_notices x on x.id = a.notice_id
        where x.staff_profile_id = s.id and not (x.kind = any (v_cover))
          and a.state in ('sending', 'accepted', 'unknown') and a.started_at >= v_day_start
      ),
      'recentSameKind', (
        select count(*) from vppsone.staff_notice_attempts a
        join vppsone.staff_notices x on x.id = a.notice_id
        where x.staff_profile_id = s.id and x.kind = n.kind
          and a.state in ('sending', 'accepted', 'unknown') and a.started_at >= now() - interval '30 minutes'
      ),
      'pendingSameKind', (
        select count(*) from vppsone.staff_notices x
        where x.staff_profile_id = s.id and x.kind = n.kind and x.id <> n.id
          and x.status = 'pending' and x.not_after > now()
          and (x.next_attempt_at is null or x.next_attempt_at <= now() or x.status_reason = 'digest_hold')
      ),
      'heldForDigest', coalesce(n.status_reason = 'digest_hold', false),
      'monthSent', (
        select count(*) from vppsone.staff_notice_attempts a
        where a.transport = 'aisensy' and a.state in ('sending', 'accepted', 'unknown')
          and a.started_at >= v_month_start
      ),
      'monthCap', (
        select case when f.enabled then f.value else null end
        from vppsone.runtime_flags f where f.key = 'staff_whatsapp_month_cap'
      ),
      'allowlisted', exists (
        select 1 from vppsone.message_test_recipients t where t.phone_e164 = '+91' || right(v_destination, 10)
      )
    );

    -- Numbered past every earlier attempt, a gate's hand-back included.
    select coalesce(max(attempt_no), 0) + 1 into v_attempt_no
    from vppsone.staff_notice_attempts where notice_id = n.id;

    insert into vppsone.staff_notice_attempts (
      notice_id, attempt_no, lease_owner, lease_expires_at, destination, contact_version, transport
    ) values (
      n.id, v_attempt_no, p_worker, now() + make_interval(secs => p_lease_seconds),
      right(v_destination, 10),
      md5(coalesce(s.whatsapp_phone, '') || '|' || coalesce(s.phone, '') || '|' || s.updated_at::text),
      p_transport
    )
    returning id into v_attempt;

    update vppsone.staff_notices
    set status = 'dispatching', attempts = attempts + 1, next_attempt_at = null
    where id = n.id;

    return jsonb_build_object(
      'claimed', true,
      'attempt_id', v_attempt,
      'notice', jsonb_build_object(
        'id', n.id, 'kind', n.kind, 'day', n.day, 'period', n.period,
        'attempt_no', v_attempt_no, 'not_after', n.not_after, 'session_label', n.session_label,
        'payload', n.payload
      ),
      'duty', case when n.duty_id is null then null else jsonb_build_object(
        'id', d.id, 'class_labels', d.class_labels, 'subject_code', d.subject_code,
        'period', d.period, 'day', d.day, 'revision', d.revision, 'status', d.status
      ) end,
      'register', case when n.kind = 'attendance_reminder' then jsonb_build_object(
        'class_id', n.class_id, 'class_label', n.class_label, 'day', n.day
      ) else null end,
      'staff', jsonb_build_object(
        'id', s.id, 'display_name', s.display_name, 'language', s.preferred_language
      ),
      'destination', right(v_destination, 10),
      'gate', v_gate,
      'student_names', vppsone.flag_enabled('staff_notice_student_names')
    );
  end loop;

  return jsonb_build_object('claimed', false, 'reason', 'empty');
end;
$$;

/*
 * The gate said no, or not yet: hand the claim back before anything was sent.
 * 'suppress' ends the notice with the reason; 'defer' puts it back in the
 * queue from `p_until` (a hold that would outlive the notice ends it as
 * too_late). The attempt is closed as abandoned with the reason, and the
 * notice's provider-attempt count is given back, so a hold never uses up a retry.
 */
create or replace function vppsone.release_staff_notice(
  p_attempt uuid,
  p_worker text,
  p_action text,
  p_reason text,
  p_until timestamptz default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  a vppsone.staff_notice_attempts%rowtype;
  n vppsone.staff_notices%rowtype;
  v_reason text := left(coalesce(nullif(p_reason, ''), 'gate'), 60);
begin
  select * into a from vppsone.staff_notice_attempts where id = p_attempt for update;
  if not found or a.state <> 'claimed' or a.lease_owner <> p_worker then
    return jsonb_build_object('recorded', false);
  end if;
  select * into n from vppsone.staff_notices where id = a.notice_id for update;

  update vppsone.staff_notice_attempts
  set state = 'abandoned', error = 'gate: ' || v_reason, finished_at = now()
  where id = a.id;

  if p_action = 'defer' and p_until is not null and p_until < n.not_after then
    update vppsone.staff_notices
    set status = 'pending', next_attempt_at = p_until, status_reason = v_reason,
        attempts = greatest(attempts - 1, 0)
    where id = n.id;
    return jsonb_build_object('recorded', true, 'notice_status', 'pending', 'until', p_until);
  end if;

  update vppsone.staff_notices
  set status = 'suppressed',
      status_reason = case when p_action = 'defer' then 'too_late' else v_reason end,
      attempts = greatest(attempts - 1, 0)
  where id = n.id;
  return jsonb_build_object('recorded', true, 'notice_status', 'suppressed');
end;
$$;

/*
 * The rest of a burst of one kind for one person, folded into the digest this
 * attempt is about to send. Only after the stamp: what the digest says it
 * covers is on record before the provider is called.
 */
create or replace function vppsone.digest_staff_notices(p_attempt uuid, p_worker text)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  a vppsone.staff_notice_attempts%rowtype;
  n vppsone.staff_notices%rowtype;
  v_count integer;
begin
  select * into a from vppsone.staff_notice_attempts where id = p_attempt;
  if not found or a.state <> 'sending' or a.lease_owner <> p_worker then
    return 0;
  end if;
  select * into n from vppsone.staff_notices where id = a.notice_id;

  update vppsone.staff_notices x
  set status = 'suppressed', status_reason = 'digested', digest_into = n.id
  where x.staff_profile_id = n.staff_profile_id and x.kind = n.kind and x.id <> n.id
    and x.status = 'pending' and x.not_after > now()
    and (x.next_attempt_at is null or x.next_attempt_at <= now() or x.status_reason = 'digest_hold');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

/* ------------------------------------------------------------- templates */

-- One name for the register reminder: the outbox's four-slot one.
update vppsone.message_templates set is_active = false, updated_at = now()
where code = 'vppsone_attendance_reminder' and is_active;

insert into vppsone.message_templates (
  code, label_hi, label_en, body_hi, body_en, variables, has_url_button, audience, is_active, sort_order, wa_category
) values
  ('vppsone_cover_assigned', 'व्यवस्था मिली', 'Cover assigned', '{{1}} जी, {{2}} को {{3}} में {{4}} ({{5}}) की व्यवस्था आपकी है। देखें और पुष्टि करें: {{6}}', '{{1}}, you are covering {{4}} ({{5}}) in {{3}} on {{2}}. Open and acknowledge: {{6}}', array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], false, 'staff', true, 950, 'utility'),
  ('vppsone_cover_changed', 'व्यवस्था बदली', 'Cover changed', '{{1}} जी, {{2}} {{3}} की आपकी व्यवस्था बदली है: अब {{4}} ({{5}})। नया विवरण: {{6}}', '{{1}}, your cover in {{3}} on {{2}} has changed: now {{4}} ({{5}}). Current details: {{6}}', array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], false, 'staff', true, 951, 'utility'),
  ('vppsone_cover_cancelled', 'व्यवस्था रद्द', 'Cover cancelled', '{{1}} जी, {{2}} {{3}} में {{4}} ({{5}}) की व्यवस्था अब आपकी नहीं है। विवरण: {{6}}', '{{1}}, you no longer need to cover {{4}} ({{5}}) in {{3}} on {{2}}. Details: {{6}}', array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], false, 'staff', true, 952, 'utility'),
  ('vppsone_cover_escalation', 'व्यवस्था नहीं हो सकी', 'Cover refused', '{{1}} जी, {{2}} {{3}} में {{4}} ({{5}}) के लिए कोई नहीं है — किसी अध्यापक ने कहा वे नहीं ले सकते। देखें: {{6}}', '{{1}}, {{4}} ({{5}}) in {{3}} on {{2}} needs someone — the assigned teacher cannot cover it. Review: {{6}}', array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], false, 'staff', true, 953, 'utility'),
  ('vppsone_staff_attendance_reminder', 'हाज़िरी की याद', 'Register not saved', '{{1}} जी, {{2}} की {{3}} की हाज़िरी अभी दर्ज नहीं हुई है। यहाँ लें: {{4}}', '{{1}}, {{3}}''s register for {{2}} has not been saved yet. Take it here: {{4}}', array['name', 'day', 'class', 'link']::text[], false, 'staff', true, 954, 'utility'),
  ('vx_staff_online_review_v1', 'ऑनलाइन भुगतान जाँचें', 'Online payment needs review', '{{1}} जी, {{3}} का {{2}} का ऑनलाइन भुगतान अपने-आप दर्ज नहीं हो सका। जाँच कर दर्ज करें: {{4}}', '{{1}}, an online payment of {{2}} for {{3}} could not be posted automatically. Review it here: {{4}}', array['name', 'amount', 'student or class', 'link']::text[], false, 'staff', true, 955, 'utility'),
  ('vx_staff_online_payment_v1', 'ऑनलाइन भुगतान आया', 'Online payment received', '{{1}} जी, {{3}} की फ़ीस {{2}} ऑनलाइन मिली, रसीद {{4}} बन गई है। {{5}}', '{{1}}, {{2}} was received online for {{3}}; receipt {{4}} has been posted. {{5}}', array['name', 'amount', 'student or class', 'receipt', 'link']::text[], false, 'staff', true, 956, 'utility'),
  ('vx_staff_day_collection_v1', 'दिन का संग्रह', 'Day''s collection', '{{1}} जी, {{2}} का संग्रह: {{3}}, {{4}} रसीदें ({{5}})। {{6}}', '{{1}}, collection for {{2}}: {{3}} in {{4}} receipts ({{5}}). {{6}}', array['name', 'day', 'total', 'receipts', 'by mode', 'link']::text[], false, 'staff', true, 957, 'utility'),
  ('vx_staff_day_not_closed_v1', 'दिन बंद नहीं हुआ', 'Day not closed', '{{1}} जी, {{2}} का दिन अभी बंद नहीं हुआ है ({{3}} रसीदें, {{4}})। नकद गिनकर दिन बंद करें: {{5}}', '{{1}}, {{2}} has not been closed yet ({{3}} receipts, {{4}}). Count the cash and close the day: {{5}}', array['name', 'day', 'receipts', 'total', 'link']::text[], false, 'staff', true, 958, 'utility'),
  ('vx_staff_money_request_v1', 'रसीद रद्द / माफ़ी का अनुरोध', 'Reversal or write-off requested', '{{1}} जी, {{5}} ने {{4}} के लिए {{3}} का {{2}} माँगा है। निर्णय करें: {{6}}', '{{1}}, {{5}} asked for a {{2}} of {{3}} for {{4}}. Decide here: {{6}}', array['name', 'what', 'amount', 'student or class', 'asked by', 'link']::text[], false, 'staff', true, 959, 'utility'),
  ('vx_staff_money_decision_v1', 'रसीद रद्द / माफ़ी का निर्णय', 'Reversal or write-off decided', '{{1}} जी, {{5}} के {{4}} के {{2}} का आपका अनुरोध {{3}} हुआ। {{6}}', '{{1}}, your {{2}} request of {{4}} for {{5}} was {{3}}. {{6}}', array['name', 'what', 'decision', 'amount', 'student or class', 'link']::text[], false, 'staff', true, 960, 'utility'),
  ('vx_staff_leave_requested_v1', 'छुट्टी का अनुरोध', 'Leave requested', '{{1}} जी, {{2}} ने {{3}} की छुट्टी माँगी है। देखें: {{4}}', '{{1}}, {{2}} has asked for leave on {{3}}. Review: {{4}}', array['name', 'teacher', 'dates', 'link']::text[], false, 'staff', true, 961, 'utility'),
  ('vx_staff_leave_decided_v1', 'छुट्टी का निर्णय', 'Leave decided', '{{1}} जी, {{2}} की आपकी छुट्टी {{3}} हुई। {{4}}', '{{1}}, your leave for {{2}} was {{3}}. {{4}}', array['name', 'dates', 'decision', 'link']::text[], false, 'staff', true, 962, 'utility'),
  ('vx_staff_digest_v1', 'कई संदेश एक साथ', 'Several messages at once', '{{1}} जी, आपके लिए {{2}} नए संदेश: {{3}}। सब यहाँ देखें: {{4}}', '{{1}}, you have {{2}} new messages: {{3}}. See them all here: {{4}}', array['name', 'count', 'what', 'link']::text[], false, 'staff', true, 963, 'utility')
on conflict (code) do nothing;

/* ---------------------------------------------------------------- grants */

revoke all on function vppsone.queue_staff_notice(text, text, uuid, text, jsonb, timestamptz, uuid) from public, anon, authenticated;
revoke all on function vppsone.queue_staff_notice_to_permission(text, text, text, text, jsonb, timestamptz, uuid, uuid) from public, anon, authenticated;
revoke all on function vppsone.student_notice_facts(uuid) from public, anon, authenticated;
revoke all on function vppsone.fee_desk_request_staff_notices() from public, anon, authenticated;
revoke all on function vppsone.teacher_leave_staff_notices() from public, anon, authenticated;
revoke all on function vppsone.claim_staff_notice(text, integer, text, uuid) from public, anon, authenticated;
revoke all on function vppsone.release_staff_notice(uuid, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function vppsone.digest_staff_notices(uuid, text) from public, anon, authenticated;
grant execute on function vppsone.queue_staff_notice(text, text, uuid, text, jsonb, timestamptz, uuid) to service_role;
grant execute on function vppsone.queue_staff_notice_to_permission(text, text, text, text, jsonb, timestamptz, uuid, uuid) to service_role;
grant execute on function vppsone.student_notice_facts(uuid) to service_role;
grant execute on function vppsone.claim_staff_notice(text, integer, text, uuid) to service_role;
grant execute on function vppsone.release_staff_notice(uuid, text, text, text, timestamptz) to service_role;
grant execute on function vppsone.digest_staff_notices(uuid, text) to service_role;
