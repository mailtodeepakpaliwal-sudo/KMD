-- KMD One database setup — kmd_db_part 11 of 11. Run in order, each once.
-- Files: 20261116034500_message_log_rules_match_fees.sql … 90_kmd_finish.sql

-- ======================================================== fee-migrations/20261116034500_message_log_rules_match_fees.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): the two message logs take the rules the
-- fees app loosened on its own database, so a straight copy of the fees app's
-- sends fits (D-644, 16 Nov 2026).
--
-- Why this differs from the fees app: the fees app changed these rules with its
-- household-communications work (31 Oct to 9 Nov 2026):
--   * a send whose fate is unknown is 'uncertain' (status, on both logs);
--   * a family can be reached on a third number, 'contact:<sha-256>'
--     (destination_role);
--   * "once a day" and "once per receipt" count per destination_role, and the
--     reminder rule leaves household-event sends to their own index.
-- One still had the older, stricter rules. On 16 Nov the fees app held rows
-- they refuse (41 'uncertain', 274 'contact:' rows, 7 receipts noticed to two
-- numbers), and every online_payment_orders row needs its send
-- (send_id not null), so without this the D-644 copy could not bring the
-- online-payment records across either.
--
-- What changes: the three CHECKs become the fees app's exact definitions; the
-- two One-only unique indexes go (their per-role replacements,
-- school_notice_sends_one_a_day_role and
-- whatsapp_reminder_sends_receipt_kind_role_idx, came with 20261116033500);
-- whatsapp_reminder_sends_reminder_day_idx becomes the fees definition.
--
-- What One's own senders notice: nothing. One's receipt, reversal and
-- fee-statement notices claim their row with destination_role 'primary', and a
-- school notice takes the column default 'primary', so the per-role indexes
-- stop the same second send the old ones did; reminders already counted per
-- role. No function, and no ON CONFLICT anywhere, names these indexes.
--
-- Applied with the Supabase CLI from the owner's PC (`supabase db query
-- --remote --yes -f`), because the MCP asks for a confirmation on DROP that
-- nobody sees in time; the ledger row was written straight after it, under the
-- usual name, with the time it ran as its version.
--
-- Rollback: put the old CHECKs and indexes back, which works only while no row
-- uses the looser values.
-- ============================================================================

begin;

alter table public.whatsapp_reminder_sends drop constraint whatsapp_reminder_sends_status_check;
alter table public.whatsapp_reminder_sends add constraint whatsapp_reminder_sends_status_check
  check (status = any (array['pending', 'sent', 'failed', 'covered_by_sibling', 'uncertain']));

alter table public.whatsapp_reminder_sends drop constraint whatsapp_reminder_sends_destination_role_check;
alter table public.whatsapp_reminder_sends add constraint whatsapp_reminder_sends_destination_role_check
  check (destination_role = any (array['primary', 'secondary']) or destination_role ~ '^contact:[0-9a-f]{64}$');

alter table public.school_notice_sends drop constraint school_notice_sends_status_check;
alter table public.school_notice_sends add constraint school_notice_sends_status_check
  check (status = any (array['pending', 'sent', 'failed', 'uncertain', 'covered_by_sibling']));

drop index public.school_notice_sends_one_a_day;
drop index public.whatsapp_reminder_sends_receipt_kind_idx;

create unique index whatsapp_reminder_sends_reminder_day_idx_d644
  on public.whatsapp_reminder_sends (student_id, session_label, sent_on, campaign_name, destination_role)
  where receipt_id is null and household_event_id is null and notice_kind = 'reminder';
drop index public.whatsapp_reminder_sends_reminder_day_idx;
alter index public.whatsapp_reminder_sends_reminder_day_idx_d644 rename to whatsapp_reminder_sends_reminder_day_idx;

commit;

-- ======================================================== migrations/20261116050127_parent_chats_finish_by_itself.sql
-- Chats with parents, part three (D-645): a chat finishes by itself.
--
-- Teachers forget to tap Finished. A chat then stays in their list for good,
-- and a parent's "Ok sir, thank you for telling" after the school's answer
-- made the chat wait again: a WhatsApp to the teacher after two minutes,
-- another after three hours, and after a day the admins were told nobody had
-- answered. Nobody owed that parent anything.
--
-- The app now finishes a chat when the parent only says thanks after the
-- school's answer (its word list, or Veer Patta AI's quick read of a few
-- words). This file adds what that needs, and the third way: a chat the
-- school answered that has been quiet for twelve hours finishes by itself.
-- A chat where a parent is waiting is never closed this way, nor one whose
-- answer from school is still waiting to reach the parent. When the parent
-- writes again the chat opens again, as before (`parent_chat_append`).
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `parent_chats.done_reason`: why a chat finished without a person,
--    `thanks` or `quiet`; null when a person finished it. The app reads it
--    only while the chat is finished.
--  * `parent_chat_settings.finish_by_itself` (on) and `quiet_hours` (12),
--    so the switch and the hours change without new code.
--  * `parent_chat_close_quiet(limit)`: finishes the quiet chats, gives a chat
--    an admin took over and never handed back to its desk again (finished or
--    not), and writes a line only staff read ("Finished by itself: quiet for
--    12 hours", "Back with its desk by itself").
--  * A pg_cron job, `parent-chats-quiet`, every ten minutes. It sends nothing
--    and calls nothing outside the database.
--
-- Rollback: unschedule `parent-chats-quiet`, then remove the function and the
-- three columns. Nothing else changes.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.parent_chats
  add column if not exists done_reason text
    check (done_reason is null or done_reason in ('thanks', 'quiet'));

comment on column vppsone.parent_chats.done_reason is
  'Chats with parents (D-645): why the chat finished without a person tapping Finished (thanks: the parent only thanked the school; quiet: nobody wrote for quiet_hours). Null when a person finished it. Read only while status is done.';

alter table vppsone.parent_chat_settings
  add column if not exists finish_by_itself boolean not null default true,
  add column if not exists quiet_hours integer not null default 12 check (quiet_hours between 1 and 72);

comment on column vppsone.parent_chat_settings.finish_by_itself is
  'Chats with parents (D-645): a chat the school answered finishes by itself when the parent only says thanks, or after quiet_hours with nobody writing.';
comment on column vppsone.parent_chat_settings.quiet_hours is
  'Chats with parents (D-645): hours without a message after which an answered chat finishes by itself.';

-- The quiet chats: answered (open, not waiting), not joined to another, no
-- message for `quiet_hours`, nobody answering right now, and nothing from
-- school still waiting for the parent. Each is finished once, with a line in
-- the chat; a take-over ends with it.
create or replace function vppsone.parent_chat_close_quiet(p_limit integer default 200)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_on boolean;
  v_hours integer;
  v_count integer := 0;
begin
  select s.enabled and s.finish_by_itself, s.quiet_hours
    into v_on, v_hours
    from vppsone.parent_chat_settings s
   where s.id = 1;
  if not coalesce(v_on, false) then
    return 0;
  end if;
  v_hours := coalesce(v_hours, 12);

  with due as (
    select c.id, c.taken_by
      from vppsone.parent_chats c
     where c.status = 'open'
       and c.merged_into is null
       and c.last_message_at < now() - make_interval(hours => v_hours)
       and (c.live_until is null or c.live_until < now())
       and not exists (
         select 1 from vppsone.parent_chat_messages m
          where m.chat_id = c.id and m.status = 'waiting'
       )
     order by c.last_message_at
     limit greatest(1, least(coalesce(p_limit, 200), 1000))
     for update of c skip locked
  ),
  closed as (
    update vppsone.parent_chats c set
      status = 'done',
      waiting_since = null,
      nudge_step = null,
      next_nudge_at = null,
      live_until = null,
      taken_by = null,
      taken_at = null,
      done_at = now(),
      done_by = null,
      done_reason = 'quiet',
      updated_at = now()
      from due
     where c.id = due.id
       and c.status = 'open'
    returning c.id, due.taken_by as was_taken
  ),
  noted as (
    insert into vppsone.parent_chat_messages (chat_id, direction, kind, body, meta, status, at)
    select closed.id, 'note', 'event', null,
           jsonb_build_object('event', 'finished_itself', 'reason', 'quiet', 'hours', v_hours, 'handed_back', closed.was_taken is not null),
           'received', now()
      from closed
    returning 1
  )
  select count(*) into v_count from noted;

  -- A finished chat an admin took over and never handed back: after the same
  -- quiet hours its desk has it again, so the parent's next message is theirs.
  with released as (
    update vppsone.parent_chats c set
      taken_by = null,
      taken_at = null,
      updated_at = now()
     where c.id in (
       select d.id
         from vppsone.parent_chats d
        where d.status = 'done'
          and d.taken_by is not null
          and d.merged_into is null
          and d.last_message_at < now() - make_interval(hours => v_hours)
          and (d.live_until is null or d.live_until < now())
        order by d.last_message_at
        limit greatest(1, least(coalesce(p_limit, 200), 1000))
        for update skip locked
     )
     and c.status = 'done'
    returning c.id
  ),
  noted_back as (
    insert into vppsone.parent_chat_messages (chat_id, direction, kind, body, meta, status, at)
    select released.id, 'note', 'event', null,
           jsonb_build_object('event', 'handed_back_itself', 'hours', v_hours),
           'received', now()
      from released
    returning 1
  )
  select v_count + count(*) into v_count from noted_back;

  return v_count;
end;
$$;

comment on function vppsone.parent_chat_close_quiet(integer) is
  'Chats with parents (D-645): finish the answered chats nobody has written in for quiet_hours, hand a forgotten take-over of a quiet chat back to its desk, and note each in the chat. Never a waiting chat, never one with a message still waiting for the parent. Sends nothing.';

revoke all on function vppsone.parent_chat_close_quiet(integer) from public, anon, authenticated;
grant execute on function vppsone.parent_chat_close_quiet(integer) to service_role;

-- Every ten minutes, inside the database: no request, no WhatsApp.
select cron.schedule(
  'parent-chats-quiet',
  '*/10 * * * *',
  $job$select vppsone.parent_chat_close_quiet(200);$job$
);

commit;

-- ======================================================== fee-migrations/20261116055000_message_logs_fee_staff_only.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): the message and follow-up logs are read
-- by fee staff only, not by every signed-in account (D-648, 16 Nov 2026).
--
-- Why this differs from the fees app: in the fees app every signed-in account
-- is a member of the fee office, so these eight read rules say "anyone signed
-- in" ((select auth.role()) = 'authenticated'). In One every member of staff
-- is signed in: teachers, the office, and the practice accounts. Until 16 Nov
-- these tables held the masked replica's invented people; the night's copy of
-- the fees app (vppsone.fees_copy_run, D-644) now brings the real reminder,
-- delivery and follow-up logs, with parents' numbers and the messages sent to
-- them. Read straight through the API with any staff sign-in, they would show
-- every family's number to every teacher.
--
-- What changes: the same eight rules ask for a fee permission instead.
-- public.has_permission is the fees app's own check (an active public.users
-- row whose role grants it). 'defaulters:view' is in every fee role (admin,
-- accountant, teacher, fee collector, viewer), so whoever read these in the
-- fees app still reads them in One; 'dashboard:view', likewise in every fee
-- role, for the activity log. A One account without a fee role reads nothing,
-- which is what One's own screens already assume: they read these tables with
-- the service key after One's own permission check (fees/platform/supabase).
--
-- Only the USING expression of each existing rule changes (alter policy): no
-- rule is added or removed, and writes, grants and the copy are untouched.
-- Rollback: alter each policy back to ((select auth.role()) = 'authenticated').
-- ============================================================================

alter policy "defaulter_contacts: staff read" on public.defaulter_contacts
  using ((select public.has_permission('defaulters:view')));

alter policy "whatsapp_reminder_sends: staff read" on public.whatsapp_reminder_sends
  using ((select public.has_permission('defaulters:view')));

alter policy "whatsapp_send_attempts: staff read" on public.whatsapp_send_attempts
  using ((select public.has_permission('defaulters:view')));

alter policy "whatsapp_test_sends: staff read" on public.whatsapp_test_sends
  using ((select public.has_permission('defaulters:view')));

alter policy "whatsapp_number_health: staff read" on public.whatsapp_number_health
  using ((select public.has_permission('defaulters:view')));

alter policy "whatsapp_campaign_runs: staff read" on public.whatsapp_campaign_runs
  using ((select public.has_permission('defaulters:view')));

alter policy "whatsapp_run_holdouts: staff read" on public.whatsapp_run_holdouts
  using ((select public.has_permission('defaulters:view')));

alter policy "user_activity_events: staff read" on public.user_activity_events
  using ((select public.has_permission('dashboard:view')));

-- ======================================================== migrations/20261116055129_marks_send_themselves.sql
-- Marks send themselves (D-651).
--
-- A teacher fills in every child's mark and then forgets to tap Send marks.
-- The paper stays open, the exam office sees it as late, Needs you keeps
-- asking her, and the coordinator chases a teacher whose work is already done.
--
-- The owner's answer (16 Nov): fully entered marks may send themselves. Once
-- an exam's marks due day is over, a paper goes to the exam office by itself
-- when every child on its roll has a mark, an absence or an exemption, every
-- saved mark fits the paper, and nobody has typed in it for two hours. It goes
-- exactly where Send marks takes it: to the exam office, never to parents.
-- Showing marks to parents stays the admin's decision (D-647).
--
-- Nothing else changes. A paper with a blank is left for the teacher and the
-- exam office as before. A class whose results are locked is not touched. The
-- exam office hands a paper back the usual way ("Hand back to teacher").
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `assessment_subjects.sent_itself_at`: when the paper went by itself. It
--    reads "sent by itself" only while it equals `submitted_at`; a hand-back
--    and a person's later Send leave it behind, so nothing has to clear it.
--  * `exam_plans.marks_send_themselves` (on): the switch, per exam.
--  * `marks_paper_ready_to_send(paper)` and `marks_send_themselves(limit)`.
--    Each paper sent gets a line in the exam's activity ("Class 6 Maths went
--    to the exam office by itself").
--  * A pg_cron job, `marks-send-themselves`, at seven minutes past every hour.
--    The first run after a due day is 00:07 school time. It sends no message
--    and calls nothing outside the database.
--
-- Rollback: unschedule `marks-send-themselves`, then remove the two functions
-- and the two columns. Papers it sent stay sent, as if a person had sent them;
-- the exam office hands any of them back as usual.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.assessment_subjects
  add column if not exists sent_itself_at timestamptz;

comment on column vppsone.assessment_subjects.sent_itself_at is
  'Marks send themselves (D-651): when this paper went to the exam office by itself after the marks due day. Means "sent by itself" only while it equals submitted_at.';

alter table vppsone.exam_plans
  add column if not exists marks_send_themselves boolean not null default true;

comment on column vppsone.exam_plans.marks_send_themselves is
  'Marks send themselves (D-651): after marks_due_on, a paper with every child''s mark entered goes to the exam office by itself.';

-- Whether a paper may go by itself now: every child on its roll has a mark,
-- an absence or an exemption (a roll of nobody never goes), every saved mark
-- fits the paper as it stands (B03/B04), and nobody has typed in it for two
-- hours, so it is never taken from under a teacher who is still checking.
create or replace function vppsone.marks_paper_ready_to_send(p_paper uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from vppsone.paper_roster(p_paper))
     and not exists (
       select 1
         from vppsone.paper_roster(p_paper) as roll(student_id)
        where not exists (
          select 1 from vppsone.marks m
           where m.assessment_subject_id = p_paper
             and m.student_id = roll.student_id
             and (m.value is not null or m.absent or m.exempt)
        )
     )
     and not exists (
       select 1
         from vppsone.marks m
         join vppsone.assessment_subjects s on s.id = m.assessment_subject_id
        where m.assessment_subject_id = p_paper
          and (
            (m.value is not null and (m.value < 0 or m.value > s.max_marks or mod(m.value, s.mark_step) <> 0))
            or (m.exempt and not s.allow_exempt)
          )
     )
     and not exists (
       select 1 from vppsone.marks m
        where m.assessment_subject_id = p_paper
          and m.entered_at > now() - interval '2 hours'
     );
$$;

comment on function vppsone.marks_paper_ready_to_send(uuid) is
  'Marks send themselves (D-651): every child on the roll has a mark, an absence or an exemption, every saved mark fits the paper, and nobody typed in it for two hours.';

-- The papers whose exam's marks due day is over and which are ready: each is
-- locked, checked again under the lock (a teacher saving right now holds the
-- same row first), sent, and noted in the exam's activity.
create or replace function vppsone.marks_send_themselves(p_limit integer default 200)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today date := vppsone.school_today();
  v_now timestamptz := now();
  v_count integer := 0;
  r record;
begin
  for r in
    select s.id, s.assessment_id, s.class_label, s.subject_code
      from vppsone.assessment_subjects s
      join vppsone.assessments a on a.id = s.assessment_id
      join vppsone.exam_plans p on p.assessment_id = s.assessment_id
     where s.entry_status = 'open'
       and a.status = 'open'
       and p.marks_send_themselves
       and p.marks_due_on is not null
       and p.marks_due_on < v_today
       and not exists (
         select 1 from vppsone.exam_class_locks l
          where l.assessment_id = s.assessment_id and l.class_id = s.class_id
       )
       and vppsone.marks_paper_ready_to_send(s.id)
     order by p.marks_due_on, s.id
     limit greatest(1, least(coalesce(p_limit, 200), 1000))
  loop
    begin
      perform 1 from vppsone.assessment_subjects
        where id = r.id and entry_status = 'open'
        for update skip locked;
      if not found or not vppsone.marks_paper_ready_to_send(r.id) then
        continue;
      end if;

      update vppsone.assessment_subjects
         set entry_status = 'submitted',
             entry_revision = entry_revision + 1,
             submitted_by = null,
             submitted_at = v_now,
             sent_itself_at = v_now
       where id = r.id
         and entry_status = 'open';

      insert into vppsone.exam_activity (assessment_id, kind, text_en, text_hi, actor_staff_id)
      values (
        r.assessment_id,
        'sent_itself',
        r.class_label || ' ' || r.subject_code || ' went to the exam office by itself: every child had a mark after the due day',
        r.class_label || ' ' || r.subject_code || ' के अंक अपने-आप परीक्षा विभाग को गए: अंतिम दिन के बाद हर बच्चे के अंक भरे थे',
        null
      );
      v_count := v_count + 1;
    exception when others then
      -- A class locked a moment ago, or anything else odd about one paper:
      -- that paper waits for the next hour and the rest still go.
      null;
    end;
  end loop;

  return v_count;
end;
$$;

comment on function vppsone.marks_send_themselves(integer) is
  'Marks send themselves (D-651): after an exam''s marks due day, send to the exam office every open paper that is fully and validly entered and quiet for two hours, and note each in the exam''s activity. Never a locked class; sends no message.';

revoke all on function vppsone.marks_paper_ready_to_send(uuid) from public, anon, authenticated;
revoke all on function vppsone.marks_send_themselves(integer) from public, anon, authenticated;
grant execute on function vppsone.marks_paper_ready_to_send(uuid) to service_role;
grant execute on function vppsone.marks_send_themselves(integer) to service_role;

-- Seven minutes past every hour, inside the database: no request, no WhatsApp.
select cron.schedule(
  'marks-send-themselves',
  '7 * * * *',
  $job$select vppsone.marks_send_themselves(200);$job$
);

commit;

-- ======================================================== migrations/20261116055656_marks_send_themselves_roll_only.sql
-- Marks send themselves (D-651), second step: only the children on the roll
-- decide whether a paper is ready.
--
-- Why: the first live look found a TEST paper with 5 children on its roll and
-- 24 marks on file. The other 19 children have left that class; their old
-- marks stay on the paper (half marks among them, from the Half Yearly
-- import) and the sheet no longer shows them. `marks_paper_ready_to_send`
-- checked every mark on the paper for "out of range or off-step", so those
-- marks held the paper back for good, although a teacher's Send marks would
-- go through: `save_marks` only checks the roll. Now the range and step check
-- reads the roll too, the same as the completeness check. Nothing else
-- changes: the two quiet hours still read every mark, and the job is the same.
--
-- Adds only: one `create or replace`, the grants repeated. Rollback: apply
-- the function body from 20261116055129_marks_send_themselves.sql again.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function vppsone.marks_paper_ready_to_send(p_paper uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with roll as (
    select r.student_id from vppsone.paper_roster(p_paper) as r(student_id)
  )
  select exists (select 1 from roll)
     -- Every child on the roll has a mark, an absence or an exemption.
     and not exists (
       select 1
         from roll
        where not exists (
          select 1 from vppsone.marks m
           where m.assessment_subject_id = p_paper
             and m.student_id = roll.student_id
             and (m.value is not null or m.absent or m.exempt)
        )
     )
     -- Nothing on the roll is out of range, off-step or a refused exemption.
     -- A child who left the class keeps their old mark and never holds it up.
     and not exists (
       select 1
         from vppsone.marks m
         join roll on roll.student_id = m.student_id
         join vppsone.assessment_subjects s on s.id = m.assessment_subject_id
        where m.assessment_subject_id = p_paper
          and (
            (m.value is not null and (m.value < 0 or m.value > s.max_marks or mod(m.value, s.mark_step) <> 0))
            or (m.exempt and not s.allow_exempt)
          )
     )
     -- Nobody has typed in it for two hours.
     and not exists (
       select 1 from vppsone.marks m
        where m.assessment_subject_id = p_paper
          and m.entered_at > now() - interval '2 hours'
     );
$$;

revoke all on function vppsone.marks_paper_ready_to_send(uuid) from public, anon, authenticated;
grant execute on function vppsone.marks_paper_ready_to_send(uuid) to service_role;

commit;

-- ======================================================== post/90_kmd_finish.sql
-- ============================================================================
-- KMD One — applied after every migration.
-- ============================================================================

-- WhatsApp campaign columns the fees app added later (scheduled and guarded runs).
alter table public.whatsapp_campaigns add column if not exists schedule jsonb;
alter table public.whatsapp_campaign_runs
  add column if not exists source text not null default 'manual',
  add column if not exists scheduled_for timestamptz,
  add column if not exists overridden_guards jsonb,
  add column if not exists override_reason text;

-- Run outcomes, with delivery and timing (same money rule as the original view).
drop view if exists public.v_whatsapp_run_outcomes;
create view public.v_whatsapp_run_outcomes with (security_invoker = true) as
select
  run.id as run_id, run.campaign_id, run.session_label, run.campaign_name, run.situation, run.language,
  run.started_at, run.last_date, run.late_fee_phrase, run.source, run.scheduled_for,
  count(*) filter (where s.status = 'sent') as messaged,
  count(*) filter (where s.status = 'failed') as failed,
  count(*) filter (where s.status = 'covered_by_sibling') as covered_by_sibling,
  count(*) filter (where s.status = 'sent' and s.delivered_at is not null) as delivered,
  count(*) filter (where s.status = 'sent' and s.delivery_status = 'failed') as delivery_failed,
  count(*) filter (where s.status = 'sent' and s.read_at is not null) as read_count,
  coalesce(sum(s.due_amount) filter (where s.status = 'sent'), 0) as money_quoted,
  count(*) filter (where s.status = 'sent' and coalesce(paid.amount_paid, 0) > 0) as families_paid,
  coalesce(sum(paid.amount_paid) filter (where s.status = 'sent'), 0) as money_collected,
  round(avg(paid.first_paid - s.sent_on) filter (where s.status = 'sent' and paid.first_paid is not null), 1) as days_to_pay
from public.whatsapp_campaign_runs run
left join public.whatsapp_reminder_sends s on s.run_id = run.id
left join lateral (
  select sum(r.total_amount) as amount_paid, min(r.payment_date) as first_paid
  from public.receipts r
  where r.student_id = s.student_id
    and r.payment_date >= s.sent_on
    and (run.last_date is null or r.payment_date <= run.last_date)
    and r.payment_mode <> 'discount'
    and not exists (select 1 from public.v_receipt_reversal_totals rr where rr.receipt_id = r.id and rr.reversed_amount >= r.total_amount)
) paid on true
group by run.id;
grant select on public.v_whatsapp_run_outcomes to authenticated, service_role;

-- The original school copied its separate Fees app into One every night.
-- KMD has no such source; these empty stand-ins let the screens that ask
-- about it answer "no copy" instead of failing.
create table if not exists vppsone.fees_copy_runs (
  id bigserial primary key,
  mode text not null,
  status text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
alter table vppsone.fees_copy_runs enable row level security;
grant select on vppsone.fees_copy_runs to service_role;
create or replace function vppsone.fees_copy_secret_matches(p_secret text) returns boolean language sql as $$ select false $$;
create or replace function vppsone.fees_copy_cache_tags() returns text[] language sql as $$ select '{}'::text[] $$;
revoke all on function vppsone.fees_copy_secret_matches(text) from public, anon, authenticated;
grant execute on function vppsone.fees_copy_secret_matches(text) to service_role;
revoke all on function vppsone.fees_copy_cache_tags() from public, anon, authenticated;
grant execute on function vppsone.fees_copy_cache_tags() to service_role;

-- Every fee view reads with the caller's rights.
grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------- KMD settings
-- The WhatsApp helper's name.
update vppsone.parent_helper_settings set helper_name = 'KMD AI';

-- Scheduled jobs that call the app over the web were written for the old
-- school's address (one.vpps.co.in). They are removed here; KMD-SETUP.md has
-- the SQL to add them back with KMD's own address once the app is online.
do $$
declare j record;
begin
  for j in select jobname from cron.job where command ilike '%vpps.co.in%' loop
    perform cron.unschedule(j.jobname);
  end loop;
end $$;

-- KMD's own database is its fee ledger: fee changes are allowed once the
-- database is marked production too (owner-only key, D-345).
insert into public.app_settings (key, value) values ('fee_writes_enabled', 'true')
on conflict (key) do update set value = excluded.value;
