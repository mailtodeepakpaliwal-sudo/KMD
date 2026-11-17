-- KMD One database setup — kmd_db_part 7 of 11. Run in order, each once.
-- Files: 20261031111241_staff_whatsapp_review_fixes.sql … 20261104055339_builtin_ai_live.sql

-- ======================================================== migrations/20261031111241_staff_whatsapp_review_fixes.sql
-- Staff WhatsApp: the review fixes for PR #148 (go-live Phase F; D-356, D-357).
--
-- `20261031101234_staff_whatsapp_consent_and_gates` is applied and is never
-- edited; this one changes what the review found wrong in it.
--
--  1. A confined deployment claims TEST-session notices only. Preview and a
--     local `next dev` point at this one database and may run the dispatcher;
--     before this, their claim leased real-session notices too and then the
--     gate suppressed them as "not on the test list" — a real cover or money
--     notice lost for good. `claim_staff_notice` takes `p_test_only` (the
--     dispatcher passes `isConfinedDeployment()`), and a real-session row is
--     then never locked, claimed, suppressed or counted.
--  2. No child's name is stored in the outbox. `student_notice_facts` writes
--     the student's id and class label; the claim adds the name to what it
--     hands the app only while `staff_notice_student_names` is on, and strips
--     any name otherwise. And the browser cannot read `staff_notices.payload`
--     or `staff_notice_attempts.params` at all: the table-wide SELECT the
--     outbox had since P3 is replaced by column grants without them (the RLS
--     policy lets `substitutions:manage` read every row, and that permission
--     carries no fee permission). Every read of these tables in the app is
--     with the service role.
--  3. A digest folds the rest of a burst in only once the provider took it
--     (accepted, or unknown — which may have gone). Before, the fold ran
--     before the send, and a refused digest left the folded notices marked
--     "sent inside a digest" that never went.
--  4. One AiSensy request a second across every dispatcher at once, not per
--     run: `reserve_staff_send_slot` hands out the next free second from one
--     row, and a caller waits for its slot.
--  5. One count for the month's cap: `staff_whatsapp_month_sent()` is the
--     outbox's AiSensy attempts plus the teacher-task link's AiSensy claims
--     (`message_sends.task_history`), used by the claim, the Staff tab and the
--     teacher-task gate.
--
-- Nothing is sent by this migration; no fee table is touched.
--
-- Rollback: re-create claim_staff_notice(text, integer, text, uuid),
-- student_notice_facts and digest_staff_notices from 20261031101234;
-- drop function vppsone.reserve_staff_send_slot(integer), vppsone.staff_whatsapp_month_sent();
-- drop table vppsone.staff_send_pace;
-- grant select on vppsone.staff_notices, vppsone.staff_notice_attempts to authenticated;

/* ---------------------------------------------- the browser's columns */

revoke select on vppsone.staff_notices from authenticated;
grant select (
  id, notice_key, kind, duty_id, duty_revision, staff_profile_id, session_label, day, period,
  status, status_reason, not_after, command_id, created_at, updated_at, attempts, next_attempt_at,
  reconciled_by, reconciled_at, class_id, class_label, requested_by, digest_into
) on vppsone.staff_notices to authenticated;

revoke select on vppsone.staff_notice_attempts from authenticated;
grant select (
  id, notice_id, attempt_no, state, lease_owner, lease_expires_at, destination, contact_version,
  transport, template_code, language, link, policy_version, provider_message_id, provider_status,
  error, authorized_by, started_at, stamped_at, finished_at
) on vppsone.staff_notice_attempts to authenticated;

/* ------------------------------------------------- no name in the outbox */

create or replace function vppsone.student_notice_facts(p_student uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
      'student_id', s.id,
      'class_label', concat_ws(' ', c.class_name, nullif(c.section, ''))
    )
    from public.students s
    left join public.classes c on c.id = s.class_id
    where s.id = p_student
  ), '{}'::jsonb)
$$;

-- Nothing was queued with a payload before this (checked on wtgx: 0 rows),
-- but a name must never outlive the switch: drop any that is there.
update vppsone.staff_notices set payload = payload - 'student_name'
where payload ? 'student_name';

/* --------------------------------------------------- the month's count */

create or replace function vppsone.staff_whatsapp_month_sent()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  with bounds as (
    select date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata' as month_start
  )
  select (
    (select count(*) from vppsone.staff_notice_attempts a, bounds b
     where a.transport = 'aisensy' and a.state in ('sending', 'accepted', 'unknown')
       and a.started_at >= b.month_start)
    +
    (select count(*) from vppsone.message_sends m
       cross join lateral jsonb_array_elements(m.task_history) e, bounds b
     where m.task_id is not null and m.task_transport = 'aisensy'
       and e ->> 'event' = 'claim' and e ->> 'transport' = 'aisensy'
       and (e ->> 'at')::timestamptz >= b.month_start)
  )::integer
$$;

comment on function vppsone.staff_whatsapp_month_sent() is
  'AiSensy sends to staff this IST month: the outbox''s attempts that may have gone, and every AiSensy claim of the teacher-task link. The one count the month cap is held against.';

/* ------------------------------------------------------------ the pace */

create table if not exists vppsone.staff_send_pace (
  id boolean primary key default true check (id),
  next_at timestamptz not null default now()
);

comment on table vppsone.staff_send_pace is
  'One row: the next second AiSensy may be asked for a staff message, shared by every dispatcher (plan §8.3).';

alter table vppsone.staff_send_pace enable row level security;
revoke all on vppsone.staff_send_pace from public, anon, authenticated;
grant select, insert, update on vppsone.staff_send_pace to service_role;
insert into vppsone.staff_send_pace (id) values (true) on conflict (id) do nothing;

create or replace function vppsone.reserve_staff_send_slot(p_gap_ms integer default 1000)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_gap interval := make_interval(secs => greatest(coalesce(p_gap_ms, 1000), 0) / 1000.0);
  v_slot timestamptz;
begin
  -- The row lock queues concurrent callers; each gets the next free second.
  update vppsone.staff_send_pace
  set next_at = greatest(next_at, clock_timestamp()) + v_gap
  where id
  returning next_at - v_gap into v_slot;
  if v_slot is null then
    insert into vppsone.staff_send_pace (id, next_at) values (true, clock_timestamp() + v_gap)
    on conflict (id) do update set next_at = greatest(vppsone.staff_send_pace.next_at, clock_timestamp()) + v_gap
    returning next_at - v_gap into v_slot;
  end if;
  return v_slot;
end;
$$;

/* ------------------------------------------------------------ the claim */

drop function if exists vppsone.claim_staff_notice(text, integer, text, uuid);

create or replace function vppsone.claim_staff_notice(
  p_worker text,
  p_lease_seconds integer,
  p_transport text,
  p_notice_id uuid default null,
  p_test_only boolean default false
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
  v_cover constant text[] := array['cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation'];
  v_gate jsonb;
  v_names boolean := vppsone.flag_enabled('staff_notice_student_names');
  v_payload jsonb;
begin
  if not vppsone.flag_enabled('staff_notice_dispatch') then
    return jsonb_build_object('claimed', false, 'reason', 'disabled');
  end if;

  for n in
    select * from vppsone.staff_notices
    where (p_notice_id is null or id = p_notice_id)
      -- A confined deployment (Preview, local) never touches a real session.
      and (not coalesce(p_test_only, true) or vppsone.is_test_session_label(session_label))
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
          and x.session_label = n.session_label
          and x.status = 'pending' and x.not_after > now()
          and (x.next_attempt_at is null or x.next_attempt_at <= now() or x.status_reason = 'digest_hold')
      ),
      'heldForDigest', coalesce(n.status_reason = 'digest_hold', false),
      'monthSent', vppsone.staff_whatsapp_month_sent(),
      'monthCap', (
        select case when f.enabled then f.value else null end
        from vppsone.runtime_flags f where f.key = 'staff_whatsapp_month_cap'
      ),
      'allowlisted', exists (
        select 1 from vppsone.message_test_recipients t where t.phone_e164 = '+91' || right(v_destination, 10)
      )
    );

    -- The child's name is read here, only while the school allows it, and is
    -- never written back: the stored payload names the student by id.
    v_payload := case
      when n.payload is null then null
      when v_names and n.payload ? 'student_id' then
        (n.payload - 'student_name') || jsonb_build_object('student_name', (
          select st.full_name from public.students st where st.id::text = n.payload ->> 'student_id'
        ))
      else n.payload - 'student_name'
    end;

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
        'payload', v_payload
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
      'student_names', v_names
    );
  end loop;

  return jsonb_build_object('claimed', false, 'reason', 'empty');
end;
$$;

/* ----------------------------------------------------------- the digest */

/*
 * The rest of a burst of one kind for one person, folded into the digest this
 * attempt sent. Only once the provider took it (accepted, or unknown — it may
 * have gone): a refused or rate-limited digest folds nothing, so each notice
 * is still there to go on the retry. The stamp already recorded how many the
 * digest said it covered.
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
  if not found or a.state not in ('accepted', 'unknown') or a.lease_owner <> p_worker then
    return 0;
  end if;
  select * into n from vppsone.staff_notices where id = a.notice_id;

  update vppsone.staff_notices x
  set status = 'suppressed', status_reason = 'digested', digest_into = n.id
  where x.staff_profile_id = n.staff_profile_id and x.kind = n.kind and x.id <> n.id
    and x.session_label = n.session_label
    and x.status = 'pending' and x.not_after > now()
    and (x.next_attempt_at is null or x.next_attempt_at <= now() or x.status_reason = 'digest_hold');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

/* ---------------------------------------------------------------- grants */

revoke all on function vppsone.claim_staff_notice(text, integer, text, uuid, boolean) from public, anon, authenticated;
revoke all on function vppsone.student_notice_facts(uuid) from public, anon, authenticated;
revoke all on function vppsone.digest_staff_notices(uuid, text) from public, anon, authenticated;
revoke all on function vppsone.staff_whatsapp_month_sent() from public, anon, authenticated;
revoke all on function vppsone.reserve_staff_send_slot(integer) from public, anon, authenticated;
grant execute on function vppsone.claim_staff_notice(text, integer, text, uuid, boolean) to service_role;
grant execute on function vppsone.student_notice_facts(uuid) to service_role;
grant execute on function vppsone.digest_staff_notices(uuid, text) to service_role;
grant execute on function vppsone.staff_whatsapp_month_sent() to service_role;
grant execute on function vppsone.reserve_staff_send_slot(integer) to service_role;

-- ======================================================== migrations/20261031115621_ops_health_and_alerts.sql
-- Monitoring: the health pack and the staff alert it sends (go-live Phase G;
-- plan §9.1; critique1 B9).
--
--  1. `vppsone.ops_health_counts(p_hours)` — counts only, never a row, a name
--     or a phone (I-5). Read by the `health` job (`/api/jobs/health`) and by
--     `scripts/migrate/health.mjs`; `src/modules/ops-health/domain/health.ts`
--     decides what is a problem. Each count is read on its own: one that
--     cannot be read (cron missing, a table renamed) comes back as JSON null
--     and the job reports it as "could not be read", never as zero.
--     Service role only.
--  2. A new staff outbox kind, `ops_alert` (template `vx_staff_ops_alert_v1`):
--     the health job queues one for every real admin (`settings:manage`) when
--     something needs looking at. Off in `staff_notice_kinds_enabled` like
--     every new kind (plan Q15) — the owner turns it on by name
--     (docs/cutover/ADMIN-OPS-SHEET.md). Consent, the window, the daily limit
--     and the month cap apply as to every other kind.
--
-- Nothing is sent by this migration; no fee table is changed (the function
-- only reads `public`).
--
-- Rollback:
--   drop function vppsone.ops_health_counts(integer);
--   delete from vppsone.message_templates where code = 'vx_staff_ops_alert_v1';
--   update vppsone.runtime_flags set value = value - 'ops_alert' where key = 'staff_notice_kinds_enabled';
--   re-add staff_notices_kind_known without 'ops_alert' (20261031101234).

/* ------------------------------------------------------- the health pack */

create or replace function vppsone.ops_health_counts(p_hours integer default 24)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_since timestamptz := now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 24 * 14)));
  v_month date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  v_out jsonb := jsonb_build_object(
    'at', now(),
    'window_hours', greatest(1, least(coalesce(p_hours, 24), 24 * 14)),
    'month_start', date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date
  );
  v_n bigint;
  v_t timestamptz;
  v_s text;
begin
  -- Online payments: Razorpay events the reconciler keeps failing on, and
  -- captures that could not be posted (open items, any age).
  begin
    select count(*) into v_n from public.online_payment_events e
    where e.status in ('pending', 'failed') and e.attempts >= 3;
    v_out := v_out || jsonb_build_object('online_events_stuck', v_n);
  exception when others then v_out := v_out || jsonb_build_object('online_events_stuck', null);
  end;
  begin
    select count(*) into v_n from public.online_payment_captures c
    where c.application_status = 'review_required';
    v_out := v_out || jsonb_build_object('online_captures_review', v_n);
  exception when others then v_out := v_out || jsonb_build_object('online_captures_review', null);
  end;

  -- The fee receipt outbox: uncertain is open (did it go?); failed in the window.
  begin
    select count(*) into v_n from public.notification_outbox o where o.status = 'uncertain';
    v_out := v_out || jsonb_build_object('outbox_uncertain', v_n);
  exception when others then v_out := v_out || jsonb_build_object('outbox_uncertain', null);
  end;
  begin
    select count(*) into v_n from public.notification_outbox o
    where o.status = 'failed' and o.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('outbox_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('outbox_failed', null);
  end;

  -- pg_cron runs that failed in the window, and which jobs (job names are
  -- the operator's own labels, never personal data).
  begin
    select count(*) into v_n from cron.job_run_details d
    where d.status = 'failed' and d.start_time >= v_since;
    v_out := v_out || jsonb_build_object('cron_failed', v_n);
    v_out := v_out || jsonb_build_object('cron_failed_jobs', coalesce((
      select jsonb_agg(x.jobname order by x.jobname) from (
        select distinct coalesce(j.jobname, 'job ' || d.jobid::text) as jobname
        from cron.job_run_details d left join cron.job j on j.jobid = d.jobid
        where d.status = 'failed' and d.start_time >= v_since
        limit 20
      ) x
    ), '[]'::jsonb));
  exception when others then
    v_out := v_out || jsonb_build_object('cron_failed', null, 'cron_failed_jobs', null);
  end;

  -- One's own jobs: failed in the window, and "running" for more than 15
  -- minutes (a job that died without writing its end; STALE_AFTER_MS).
  begin
    select count(*) into v_n from vppsone.job_runs j
    where j.status = 'failed' and j.started_at >= v_since;
    v_out := v_out || jsonb_build_object('job_runs_failed', v_n);
    select count(*) into v_n from vppsone.job_runs j
    where j.status = 'running' and j.started_at < now() - interval '15 minutes';
    v_out := v_out || jsonb_build_object('job_runs_stale', v_n);
  exception when others then
    v_out := v_out || jsonb_build_object('job_runs_failed', null, 'job_runs_stale', null);
  end;

  -- The D-334 Drive backup: hours since its last successful run.
  begin
    select max(j.finished_at) into v_t from vppsone.job_runs j
    where j.job = 'drive-backup' and j.status = 'ok';
    v_out := v_out || jsonb_build_object(
      'drive_backup_hours',
      case when v_t is null then -1 else floor(extract(epoch from (now() - v_t)) / 3600)::bigint end
    );
  exception when others then v_out := v_out || jsonb_build_object('drive_backup_hours', null);
  end;

  -- Staff WhatsApp: failed in the window, and unknown (open: did it go?).
  begin
    select count(*) into v_n from vppsone.staff_notices s
    where s.status = 'failed' and s.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('staff_failed', v_n);
    select count(*) into v_n from vppsone.staff_notices s where s.status = 'unknown';
    v_out := v_out || jsonb_build_object('staff_unknown', v_n);
  exception when others then
    v_out := v_out || jsonb_build_object('staff_failed', null, 'staff_unknown', null);
  end;

  -- Parent WhatsApp: fee reminders and school notices that failed in the
  -- window, and One's own parent sends (message_sends) that failed.
  begin
    select count(*) into v_n from public.whatsapp_reminder_sends w
    where w.status = 'failed' and w.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('parent_reminders_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('parent_reminders_failed', null);
  end;
  begin
    select count(*) into v_n from public.school_notice_sends w
    where w.status = 'failed' and w.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('school_notices_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('school_notices_failed', null);
  end;
  begin
    select count(*) into v_n from vppsone.message_sends m
    where m.status = 'failed' and m.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('one_sends_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('one_sends_failed', null);
  end;

  -- AiSensy this month (IST) against the caps. The fee reminders' cap is the
  -- fee app's own setting (`whatsapp_month_message_cap`, 4,000 when unset —
  -- whatsapp-settings.ts); school notices have a budget in code; staff have
  -- `staff_whatsapp_month_cap`. Billed sends only (status 'sent').
  begin
    select count(*) into v_n from public.whatsapp_reminder_sends w
    where w.status = 'sent' and w.sent_on >= v_month;
    v_out := v_out || jsonb_build_object('parent_reminders_month', v_n);
  exception when others then v_out := v_out || jsonb_build_object('parent_reminders_month', null);
  end;
  begin
    select a.value into v_s from public.app_settings a where a.key = 'whatsapp_month_message_cap';
    v_out := v_out || jsonb_build_object(
      'parent_reminders_cap',
      case when v_s ~ '^\s*\d{1,9}\s*$' then trim(v_s)::bigint else null end
    );
  exception when others then v_out := v_out || jsonb_build_object('parent_reminders_cap', null);
  end;
  begin
    select count(*) into v_n from public.school_notice_sends w
    where w.status = 'sent' and w.sent_on >= v_month;
    v_out := v_out || jsonb_build_object('school_notices_month', v_n);
  exception when others then v_out := v_out || jsonb_build_object('school_notices_month', null);
  end;
  begin
    v_out := v_out || jsonb_build_object('staff_month', vppsone.staff_whatsapp_month_sent());
  exception when others then v_out := v_out || jsonb_build_object('staff_month', null);
  end;
  begin
    select case when f.enabled and jsonb_typeof(f.value) = 'number' then (f.value #>> '{}')::numeric::bigint end
      into v_n
    from vppsone.runtime_flags f where f.key = 'staff_whatsapp_month_cap';
    v_out := v_out || jsonb_build_object('staff_cap', v_n);
  exception when others then v_out := v_out || jsonb_build_object('staff_cap', null);
  end;

  return v_out;
end;
$$;

comment on function vppsone.ops_health_counts(integer) is
  'The health pack (go-live Phase G, plan §9.1): counts only. Null = could not be read. Service role only.';

revoke all on function vppsone.ops_health_counts(integer) from public, anon, authenticated;
grant execute on function vppsone.ops_health_counts(integer) to service_role;

/* ------------------------------------------------- the ops_alert kind */

alter table vppsone.staff_notices drop constraint if exists staff_notices_kind_known;
alter table vppsone.staff_notices add constraint staff_notices_kind_known check (
  kind in (
    'cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation', 'attendance_reminder',
    'marks_reminder', 'weekly_summary', 'staff_broadcast', 'online_review', 'online_payment',
    'day_collection', 'day_not_closed', 'money_request', 'money_decision', 'leave_requested', 'leave_decided',
    'ops_alert'
  )
);

-- Off until the owner names it, as every new kind (plan Q15). Only added
-- when the map does not mention it, so a later owner choice is kept.
update vppsone.runtime_flags
set value = value || '{"ops_alert": false}'::jsonb
where key = 'staff_notice_kinds_enabled' and not (value ? 'ops_alert');

insert into vppsone.message_templates (
  code, label_hi, label_en, body_hi, body_en, variables, has_url_button, audience, is_active, sort_order, wa_category
) values
  ('vx_staff_ops_alert_v1', 'सिस्टम जाँच', 'System check', '{{1}} जी, {{2}} की सिस्टम जाँच में {{3}} बातें देखनी हैं: {{4}}। देखें: {{5}}', '{{1}}, the system check for {{2}} found {{3}} things to look at: {{4}}. Details: {{5}}', array['name', 'day', 'count', 'what', 'link']::text[], false, 'staff', true, 964, 'utility')
on conflict (code) do nothing;

-- ======================================================== fee-migrations/20261031120000_online_vp1_ownership.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): One's online payments carry `vp1_`
-- references, and One never records or posts money on a fees app `vpps_` one
-- (go-live Phase E, plan §7.3, critique0 #2 and #32).
--
-- Why this differs from the fees app: Razorpay sends every event on the
-- school's one account to every registered webhook, so after cutover both apps
-- hear about every payment. The fees app mints `vpps_<intent uuid hex>` for a
-- Payment Link and `vpps_o_<uuid hex>` for a checkout order, and its own
-- check is `reference_id.startsWith('vpps_')`. One mints `vp1_…` and
-- `vp1_o_…` instead, so:
--   * the fees app reads every One payment as "not our link" and leaves it;
--   * One reads every fees payment as not its own — on the Payment Link path
--     by the same prefix check (REFERENCE_PREFIX = 'vp1_' in capture-check.ts),
--     and on the ORDER path, which matched on provider_order_id alone, by the
--     refusals below. A fees order brought in by the data load would
--     otherwise have been posted by One as well as by the fees app.
-- The app refuses `vpps_` too (processOrderPayment, reconcileOpenOrders, the
-- intents pass, applyCapture, applyOrderCapture); this is the database's half,
-- so a direct call or a future code path cannot post one either.
--
-- Lengths: `vp1_` + 32 hex = 36 characters, `vp1_o_` + 32 hex = 38, inside the
-- 40 Razorpay allows and the tables' own char_length(...) <= 40 checks.
--
-- WHAT changes:
--   public.online_payment_open_intent   mints 'vp1_'   (was 'vpps_')
--   public.online_payment_open_order    mints 'vp1_o_' (was 'vpps_o_')
--   public.online_payment_record_capture        refuses a vpps_ reference or a
--                                               link held by a vpps_ intent:
--                                               {recorded:false, reason:'not_ours'}
--   public.online_payment_record_order_capture  refuses an order whose
--                                               provider_receipt is vpps_…
--   public.online_payment_apply_capture         refuses a capture on a vpps_
--                                               intent: {applied:false, status:'not_ours'}
--   public.online_payment_apply_order_capture   refuses a capture on a vpps_o_ order
--
-- HOW: the two minting lines are swapped by vppsone.replace_in_fee_function()
-- (created here): it requires the old text exactly once, replays the
-- function's own pg_get_functiondef() with that one change, and proves that
-- swapping back gives the original body byte for byte. The four refusals are
-- first statements, put in by vppsone.inject_fee_function_preamble()
-- (20261030230000_fee_writes_guard.sql). CREATE OR REPLACE keeps the oid,
-- owner and grants. Re-running is a no-op.
--
-- Proof: scripts/migrate/verify-online-vp1-and-floor.sql (rolls back).
--
-- Rollback:
--   select vppsone.undo_replace_in_fee_function('public.online_payment_open_intent(uuid,uuid,smallint[],boolean,text,timestamp with time zone,text)',
--          '''vpps_'' || replace(v_id::text', '''vp1_'' /* [vppsone:vp1-ownership] */ || replace(v_id::text');
--   select vppsone.undo_replace_in_fee_function('public.online_payment_open_order(uuid,jsonb,text,text)',
--          '''vpps_o_'' || replace(gen_random_uuid()::text', '''vp1_o_'' /* [vppsone:vp1-ownership] */ || replace(gen_random_uuid()::text');
--   select vppsone.remove_fee_function_preamble('<each of the four>', '-- [vppsone:vp1-ownership]');
-- ============================================================================

create or replace function vppsone.replace_in_fee_function(
  p_function regprocedure,
  p_marker text,
  p_old text,
  p_new text
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_src text;
  v_def text;
  v_new text;
  v_after text;
begin
  if p_marker !~ '^\[vppsone:[a-z0-9-]+\]$' then
    raise exception 'marker must look like [vppsone:name], got %', p_marker;
  end if;
  -- [KMD] tolerate CR LF from a Windows paste
  perform vppsone.kmd_strip_cr(p_function);
  p_old := replace(p_old, chr(13), '');
  p_new := replace(p_new, chr(13), '');
  if position(p_marker in p_new) = 0 then
    raise exception 'the new text must carry the marker %', p_marker;
  end if;

  select p.prosrc into strict v_src from pg_catalog.pg_proc p where p.oid = p_function;

  if position(p_new in v_src) > 0 then
    return 'already: ' || p_function::text;
  end if;

  if (length(v_src) - length(replace(v_src, p_old, ''))) <> length(p_old) then
    raise exception '% does not contain the old text exactly once; not rewriting it', p_function;
  end if;

  v_new := replace(v_src, p_old, p_new);

  v_def := pg_catalog.pg_get_functiondef(p_function);
  if (length(v_def) - length(replace(v_def, v_src, ''))) <> length(v_src) then
    raise exception '% body does not appear exactly once in its definition; not rewriting it', p_function;
  end if;

  execute replace(v_def, v_src, v_new);

  select p.prosrc into strict v_after from pg_catalog.pg_proc p where p.oid = p_function;
  if v_after <> v_new or replace(v_after, p_new, p_old) <> v_src then
    raise exception '% was not rewritten exactly as intended', p_function;
  end if;

  return 'replaced: ' || p_function::text;
end;
$$;

comment on function vppsone.replace_in_fee_function(regprocedure, text, text, text) is
  'One-only fee-function edits (go-live Phase E): swap one exact piece of a fee function''s body, proven reversible.';

create or replace function vppsone.undo_replace_in_fee_function(
  p_function regprocedure,
  p_old text,
  p_new text
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_src text;
  v_def text;
begin
  select p.prosrc into strict v_src from pg_catalog.pg_proc p where p.oid = p_function;
  if position(p_new in v_src) = 0 then
    return 'not present: ' || p_function::text;
  end if;
  if (length(v_src) - length(replace(v_src, p_new, ''))) <> length(p_new) then
    raise exception '% contains the new text more than once; not undoing it', p_function;
  end if;
  v_def := pg_catalog.pg_get_functiondef(p_function);
  execute replace(v_def, v_src, replace(v_src, p_new, p_old));
  return 'restored: ' || p_function::text;
end;
$$;

revoke all on function vppsone.replace_in_fee_function(regprocedure, text, text, text) from public, anon, authenticated, service_role;
revoke all on function vppsone.undo_replace_in_fee_function(regprocedure, text, text) from public, anon, authenticated, service_role;

/* ------------------------------------------------------- One mints vp1_ */

select vppsone.replace_in_fee_function(
  'public.online_payment_open_intent(uuid,uuid,smallint[],boolean,text,timestamp with time zone,text)',
  '[vppsone:vp1-ownership]',
  '''vpps_'' || replace(v_id::text',
  '''vp1_'' /* [vppsone:vp1-ownership] */ || replace(v_id::text'
);

select vppsone.replace_in_fee_function(
  'public.online_payment_open_order(uuid,jsonb,text,text)',
  '[vppsone:vp1-ownership]',
  '''vpps_o_'' || replace(gen_random_uuid()::text',
  '''vp1_o_'' /* [vppsone:vp1-ownership] */ || replace(gen_random_uuid()::text'
);

/* ----------------------------------- and never records or posts vpps_ money */

select vppsone.inject_fee_function_preamble(f::regprocedure, '-- [vppsone:vp1-ownership]', g)
from (values
  ('public.online_payment_record_capture(jsonb)',
   $g$  -- The fees app's link (go-live Phase E): its money is the fees app's to record.
  if left(coalesce(v_reference_id, ''), 5) = 'vpps_'
     or (v_link_id is not null and exists (
       select 1 from public.online_payment_intents i
       where i.provider_link_id = v_link_id and left(i.provider_reference_id, 5) = 'vpps_')) then
    return jsonb_build_object('recorded', false, 'reason', 'not_ours');
  end if;$g$),
  ('public.online_payment_record_order_capture(jsonb)',
   $g$  -- The fees app's order (go-live Phase E): its money is the fees app's to record.
  if exists (
    select 1 from public.online_payment_orders o
    where o.provider_order_id = v_order_id and left(o.provider_receipt, 5) = 'vpps_') then
    return jsonb_build_object('recorded', false, 'reason', 'not_ours');
  end if;$g$),
  ('public.online_payment_apply_capture(uuid,text)',
   $g$  -- A capture on the fees app's link (go-live Phase E) is never posted here.
  if exists (
    select 1 from public.online_payment_captures c
    join public.online_payment_intents i on i.id = c.intent_id
    where c.id = p_capture_id and left(i.provider_reference_id, 5) = 'vpps_') then
    return jsonb_build_object('applied', false, 'status', 'not_ours');
  end if;$g$),
  ('public.online_payment_apply_order_capture(uuid,text)',
   $g$  -- A capture on the fees app's order (go-live Phase E) is never posted here.
  if exists (
    select 1 from public.online_payment_captures c
    join public.online_payment_orders o on o.id = c.order_id
    where c.id = p_capture_id and left(o.provider_receipt, 5) = 'vpps_') then
    return jsonb_build_object('applied', false, 'status', 'not_ours');
  end if;$g$)
) as t(f, g);

-- ======================================================== fee-migrations/20261031120100_receipt_suffix_floor.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): the receipt suffix floor, and online
-- receipts numbered with their session's own prefix (go-live Phase E, plan
-- §7.4 and §5.2b/c; critique0 #9, critique1 A5).
--
-- Why this differs from the fees app: every fees receipt is copied into One
-- with its number, and One carries on each day's sequence
-- (`<prefix><yyyymmdd>-NNNN`, the next NNNN after the day's highest). From T0
-- until written sign-off the fees app can still issue receipts — the tail of
-- Pay now links already sent, and any re-entry on rollback — and those carry
-- the same SVP prefix and the same days. So One's numbers must sit in a band
-- the fees app never reaches: `app_settings.receipt_suffix_floor = 5000`
-- makes One issue SVP<date>-5001, -5002, … while the fees app's own sequence
-- stays far below. Mandatory from T0 whatever the answer to Q8/Q11
-- (docs/cutover/RAZORPAY.md); unset (the state on this database today) the
-- numbering is exactly the fees app's.
--
-- WHAT changes, in the three functions that number receipts
-- (private.post_student_payment_core, public.post_student_payment,
-- public.post_corrected_payment): the day's starting point becomes
--     greatest(<the day's highest suffix>, vppsone.receipt_suffix_floor())
-- and the next number is that + 1, as before. The four-digit pattern
-- `-([0-9]{4})$` that reads the day's highest is unchanged and reads 5001 like
-- any other suffix; the prefix is untouched, so the receipt_prefix check
-- `^[A-Z0-9][A-Z0-9-]{1,11}$` is not involved. The floor is limited to
-- 0..9998, so the first number it gives (floor + 1) still has four digits.
-- A value that is not a whole number in that range REFUSES the posting (a
-- typo must not silently drop the band and collide with the fees app).
--
-- And the two online apply functions stop hard-coding 'SVP': they post with
-- the student's session's own fee_policy_configs.receipt_prefix (the column
-- exists; the Payment Desk already passes it), falling back to 'SVP'. Today
-- that is SVP for 2026-27 and 2027-28 and TST for TEST-2026-27, which
-- vppsone.receipt_prefix_for_student() (20261030230100) already enforced for
-- TEST — so nothing a parent sees changes, but a future session with its own
-- prefix numbers its online receipts the same as its desk receipts.
--
-- HOW: vppsone.replace_in_fee_function() (20261031120000), one exact swap per
-- function, proven reversible. CREATE OR REPLACE keeps the oid, owner and
-- grants. Re-running is a no-op.
--
-- Proof: scripts/migrate/verify-online-vp1-and-floor.sql posts to a
-- TEST-2026-27 student with the floor at 5000 inside a block that rolls back,
-- and checks the number ends -5001 (then -5002).
--
-- Rollback: vppsone.undo_replace_in_fee_function(<function>, <old>, <new>)
-- with the pairs below; then drop the two vppsone functions.
-- ============================================================================

create or replace function vppsone.receipt_suffix_floor()
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_raw text;
begin
  select nullif(trim(a.value), '') into v_raw
  from public.app_settings a
  where a.key = 'receipt_suffix_floor';

  if v_raw is null then
    return 0;
  end if;
  if v_raw !~ '^[0-9]{1,4}$' or v_raw::integer > 9998 then
    raise exception 'app_settings.receipt_suffix_floor must be a whole number from 0 to 9998, got %', v_raw
      using errcode = 'VPP02';
  end if;
  return v_raw::integer;
end;
$$;

comment on function vppsone.receipt_suffix_floor() is
  'The lowest daily receipt suffix One may issue minus one (app_settings.receipt_suffix_floor; 0 when unset). From T0 to sign-off it is 5000, so One''s receipts never share a number with the fees app''s (plan §7.4).';

revoke all on function vppsone.receipt_suffix_floor() from public, anon;
grant execute on function vppsone.receipt_suffix_floor() to authenticated, service_role;

create or replace function vppsone.online_receipt_prefix(p_student_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select nullif(trim(f.receipt_prefix), '')
     from public.students s
     join public.classes c on c.id = s.class_id
     join public.fee_policy_configs f on f.academic_session_label = c.session_label
     where s.id = p_student_id
     limit 1),
    'SVP'
  );
$$;

comment on function vppsone.online_receipt_prefix(uuid) is
  'The receipt prefix an online payment posts with: the student''s session''s fee_policy_configs.receipt_prefix, else SVP (go-live Phase E). A TEST student still ends on TST through receipt_prefix_for_student.';

revoke all on function vppsone.online_receipt_prefix(uuid) from public, anon;
grant execute on function vppsone.online_receipt_prefix(uuid) to authenticated, service_role;

/* --------------------------------------------------------- the floor */

select vppsone.replace_in_fee_function(
  'private.post_student_payment_core(uuid,date,payment_mode,integer,text,text,text,text,uuid,integer,integer)',
  '[vppsone:receipt-suffix-floor]',
  'select coalesce(max((regexp_match(receipt_row.receipt_number, ''-([0-9]{4})$''))[1]::integer), 0)
  into v_daily_sequence',
  'select greatest(coalesce(max((regexp_match(receipt_row.receipt_number, ''-([0-9]{4})$''))[1]::integer), 0), vppsone.receipt_suffix_floor()) /* [vppsone:receipt-suffix-floor] */
  into v_daily_sequence'
);

-- KMD: public.post_corrected_payment(uuid,date,payment_mode,jsonb,uuid,text,text,text,text) is KMD's own wrapper over private.post_student_payment_core, which carries the floor.

-- KMD: public.post_student_payment(uuid,date,payment_mode,integer,text,text,text,text,uuid) is KMD's own wrapper over private.post_student_payment_core, which carries the floor.

/* ------------------------------------- online receipts: the session prefix */

select vppsone.replace_in_fee_function(
  'public.online_payment_apply_capture(uuid,text)',
  '[vppsone:online-receipt-prefix]',
  '''Razorpay (online)'',
      ''SVP'',',
  '''Razorpay (online)'',
      vppsone.online_receipt_prefix(v_intent.student_id) /* [vppsone:online-receipt-prefix] */,'
);

select vppsone.replace_in_fee_function(
  'public.online_payment_apply_order_capture(uuid,text)',
  '[vppsone:online-receipt-prefix]',
  '''Razorpay (online)'',
        ''SVP'',',
  '''Razorpay (online)'',
        vppsone.online_receipt_prefix(v_line.student_id) /* [vppsone:online-receipt-prefix] */,'
);

/* --------------------------------------------- One owns the setting's value */

insert into vppsone.one_owned_fee_settings (source_table, row_key, column_name, reason) values
  ('app_settings', 'receipt_suffix_floor', 'value',
   'One''s receipt band (plan §7.4): 5000 from T0 to sign-off. The fees app has no such key; the mirror never writes it.')
on conflict do nothing;

-- ======================================================== fee-migrations/20261031120200_online_switches_default_off.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): every online-payment switch starts OFF on
-- One's database (go-live Phase E, plan §7.6; critique0 #21).
--
-- Why this differs from the fees app: on the fees app these are live settings
-- the office has been switching since 28 Oct. On One's database they are
-- One's own (scripts/migrate/lib/import-rules.mjs keeps every
-- `online_payment_*` key out of the mirror), and One takes no online money
-- until cutover step C7. The replica carried two of them 'true'
-- (online_payment_waive_late_fees, online_payment_staff_whatsapp_enabled);
-- both go 'false' here, and the five that were missing are written 'false' so
-- every one reads as a decision, not an absence. The values each takes at C7,
-- and the order they are switched on in, are in docs/cutover/RAZORPAY.md.
--
-- The seven are ONLINE_SWITCH_KEYS (src/modules/payments/domain/online/switches.ts),
-- the only keys setOnlineSwitchAction writes. The staff-alert switch is not
-- one of them (Phase 8) but is turned off too: nothing in One sends staff
-- alerts yet, and it must not start the day Phase 8 lands.
-- `online_payment_order_max_rupees` keeps its value (100000, the fees app's).
--
-- Each is registered in vppsone.one_owned_fee_settings, so a load or a
-- reconcile never treats One's value as drift from the fees app's.
--
-- Rollback: none needed; setting a switch is done on the online-payments
-- screen (/fees/payments/online) by a real admin, once fee writes are open.
-- ============================================================================

insert into public.app_settings (key, value, updated_at)
select key, 'false', now()
from (values
  ('online_payment_links_enabled'),
  ('online_payment_checkout_enabled'),
  ('online_payment_auto_posting_enabled'),
  ('online_payment_receipts_enabled'),
  ('online_payment_checkout_all_sessions'),
  ('online_payment_checkout_modal_enabled'),
  ('online_payment_waive_late_fees'),
  ('online_payment_staff_whatsapp_enabled')
) as k(key)
on conflict (key) do update set value = 'false', updated_at = now()
where public.app_settings.value is distinct from 'false';

insert into vppsone.one_owned_fee_settings (source_table, row_key, column_name, reason)
select 'app_settings', key, 'value',
       'An online-payment switch (go-live Phase E): One''s own, off until cutover step C7 (docs/cutover/RAZORPAY.md).'
from (values
  ('online_payment_links_enabled'),
  ('online_payment_checkout_enabled'),
  ('online_payment_auto_posting_enabled'),
  ('online_payment_receipts_enabled'),
  ('online_payment_checkout_all_sessions'),
  ('online_payment_checkout_modal_enabled'),
  ('online_payment_waive_late_fees'),
  ('online_payment_staff_whatsapp_enabled'),
  ('online_payment_order_max_rupees')
) as k(key)
on conflict do nothing;

-- ======================================================== migrations/20261031125856_ops_health_more_counts.sql
-- The health pack, what review of PR #149 found missing (go-live Phase G;
-- plan §9.1; critique1 B9). `vppsone.ops_health_counts` is replaced with the
-- same counts as 20261031115621 plus:
--
--  * `net_http_failed` — pg_net calls in the window answered >= 400, timed out
--    or failed (status null). Every C4 timer calls One through `net.http_get`,
--    and pg_cron records that call as succeeded whatever One answered, so a
--    wrong or rotated Vault token (401), a missing route (404) or a 500 was
--    invisible to `cron_failed`. pg_net keeps responses about six hours
--    (`pg_net.ttl`), so the 08:00 and 16:00 checks each see the hours before.
--  * `online_events_pending_old` — Razorpay events still pending after 30
--    minutes, whatever their attempts: a reconciler that never runs (a 401
--    above) never raises `attempts`, so `online_events_stuck` stayed 0.
--  * `receipt_notices_month` — fee receipt notices (`notification_outbox`,
--    provider_accepted or delivered) this IST month: AiSensy messages that
--    had no month count.
--  * `one_sends_month` — One's own parent sends by AiSensy this month.
--  * `aisensy_month_total` — every lane together (fee reminders, school
--    notices, receipt notices, One's parent sends, staff), against
--    `aisensy_plan_cap`: the owner-set `vppsone.runtime_flags`
--    `aisensy_month_plan_cap` (added off; on with a number = the plan's
--    monthly allowance). Null when any lane cannot be read.
--  * `cutover_rows` — the C3 line drawn or not; the health job's webhook
--    probe reads a 404 as "not configured yet" before it, a problem after.
--
-- Counts only, service role only (re-asserted below). Nothing is sent and
-- no fee table is changed.
--
-- Rollback: re-run the function from 20261031115621;
--   delete from vppsone.runtime_flags where key = 'aisensy_month_plan_cap';
--   re-add runtime_flags_key_known without it (20261031101234).

create or replace function vppsone.ops_health_counts(p_hours integer default 24)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_since timestamptz := now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 24 * 14)));
  v_month date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  v_out jsonb := jsonb_build_object(
    'at', now(),
    'window_hours', greatest(1, least(coalesce(p_hours, 24), 24 * 14)),
    'month_start', date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date
  );
  v_n bigint;
  v_t timestamptz;
  v_s text;
begin
  -- Online payments: Razorpay events the reconciler keeps failing on, and
  -- captures that could not be posted (open items, any age).
  begin
    select count(*) into v_n from public.online_payment_events e
    where e.status in ('pending', 'failed') and e.attempts >= 3;
    v_out := v_out || jsonb_build_object('online_events_stuck', v_n);
  exception when others then v_out := v_out || jsonb_build_object('online_events_stuck', null);
  end;
  begin
    select count(*) into v_n from public.online_payment_captures c
    where c.application_status = 'review_required';
    v_out := v_out || jsonb_build_object('online_captures_review', v_n);
  exception when others then v_out := v_out || jsonb_build_object('online_captures_review', null);
  end;

  -- The fee receipt outbox: uncertain is open (did it go?); failed in the window.
  begin
    select count(*) into v_n from public.notification_outbox o where o.status = 'uncertain';
    v_out := v_out || jsonb_build_object('outbox_uncertain', v_n);
  exception when others then v_out := v_out || jsonb_build_object('outbox_uncertain', null);
  end;
  begin
    select count(*) into v_n from public.notification_outbox o
    where o.status = 'failed' and o.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('outbox_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('outbox_failed', null);
  end;

  -- pg_cron runs that failed in the window, and which jobs (job names are
  -- the operator's own labels, never personal data).
  begin
    select count(*) into v_n from cron.job_run_details d
    where d.status = 'failed' and d.start_time >= v_since;
    v_out := v_out || jsonb_build_object('cron_failed', v_n);
    v_out := v_out || jsonb_build_object('cron_failed_jobs', coalesce((
      select jsonb_agg(x.jobname order by x.jobname) from (
        select distinct coalesce(j.jobname, 'job ' || d.jobid::text) as jobname
        from cron.job_run_details d left join cron.job j on j.jobid = d.jobid
        where d.status = 'failed' and d.start_time >= v_since
        limit 20
      ) x
    ), '[]'::jsonb));
  exception when others then
    v_out := v_out || jsonb_build_object('cron_failed', null, 'cron_failed_jobs', null);
  end;

  -- One's own jobs: failed in the window, and "running" for more than 15
  -- minutes (a job that died without writing its end; STALE_AFTER_MS).
  begin
    select count(*) into v_n from vppsone.job_runs j
    where j.status = 'failed' and j.started_at >= v_since;
    v_out := v_out || jsonb_build_object('job_runs_failed', v_n);
    select count(*) into v_n from vppsone.job_runs j
    where j.status = 'running' and j.started_at < now() - interval '15 minutes';
    v_out := v_out || jsonb_build_object('job_runs_stale', v_n);
  exception when others then
    v_out := v_out || jsonb_build_object('job_runs_failed', null, 'job_runs_stale', null);
  end;

  -- The D-334 Drive backup: hours since its last successful run.
  begin
    select max(j.finished_at) into v_t from vppsone.job_runs j
    where j.job = 'drive-backup' and j.status = 'ok';
    v_out := v_out || jsonb_build_object(
      'drive_backup_hours',
      case when v_t is null then -1 else floor(extract(epoch from (now() - v_t)) / 3600)::bigint end
    );
  exception when others then v_out := v_out || jsonb_build_object('drive_backup_hours', null);
  end;

  -- Staff WhatsApp: failed in the window, and unknown (open: did it go?).
  begin
    select count(*) into v_n from vppsone.staff_notices s
    where s.status = 'failed' and s.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('staff_failed', v_n);
    select count(*) into v_n from vppsone.staff_notices s where s.status = 'unknown';
    v_out := v_out || jsonb_build_object('staff_unknown', v_n);
  exception when others then
    v_out := v_out || jsonb_build_object('staff_failed', null, 'staff_unknown', null);
  end;

  -- Parent WhatsApp: fee reminders and school notices that failed in the
  -- window, and One's own parent sends (message_sends) that failed.
  begin
    select count(*) into v_n from public.whatsapp_reminder_sends w
    where w.status = 'failed' and w.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('parent_reminders_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('parent_reminders_failed', null);
  end;
  begin
    select count(*) into v_n from public.school_notice_sends w
    where w.status = 'failed' and w.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('school_notices_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('school_notices_failed', null);
  end;
  begin
    select count(*) into v_n from vppsone.message_sends m
    where m.status = 'failed' and m.updated_at >= v_since;
    v_out := v_out || jsonb_build_object('one_sends_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('one_sends_failed', null);
  end;

  -- AiSensy this month (IST) against the caps. The fee reminders' cap is the
  -- fee app's own setting (`whatsapp_month_message_cap`, 4,000 when unset —
  -- whatsapp-settings.ts); school notices have a budget in code; staff have
  -- `staff_whatsapp_month_cap`. Billed sends only (status 'sent').
  begin
    select count(*) into v_n from public.whatsapp_reminder_sends w
    where w.status = 'sent' and w.sent_on >= v_month;
    v_out := v_out || jsonb_build_object('parent_reminders_month', v_n);
  exception when others then v_out := v_out || jsonb_build_object('parent_reminders_month', null);
  end;
  begin
    select a.value into v_s from public.app_settings a where a.key = 'whatsapp_month_message_cap';
    v_out := v_out || jsonb_build_object(
      'parent_reminders_cap',
      case when v_s ~ '^\s*\d{1,9}\s*$' then trim(v_s)::bigint else null end
    );
  exception when others then v_out := v_out || jsonb_build_object('parent_reminders_cap', null);
  end;
  begin
    select count(*) into v_n from public.school_notice_sends w
    where w.status = 'sent' and w.sent_on >= v_month;
    v_out := v_out || jsonb_build_object('school_notices_month', v_n);
  exception when others then v_out := v_out || jsonb_build_object('school_notices_month', null);
  end;
  begin
    v_out := v_out || jsonb_build_object('staff_month', vppsone.staff_whatsapp_month_sent());
  exception when others then v_out := v_out || jsonb_build_object('staff_month', null);
  end;
  begin
    select case when f.enabled and jsonb_typeof(f.value) = 'number' then (f.value #>> '{}')::numeric::bigint end
      into v_n
    from vppsone.runtime_flags f where f.key = 'staff_whatsapp_month_cap';
    v_out := v_out || jsonb_build_object('staff_cap', v_n);
  exception when others then v_out := v_out || jsonb_build_object('staff_cap', null);
  end;

  -- pg_net calls (the C4 timers) One answered with an error, or not at all.
  begin
    select count(*) into v_n from net._http_response h
    where h.created >= v_since
      and (h.status_code is null or h.status_code >= 400 or coalesce(h.timed_out, false));
    v_out := v_out || jsonb_build_object('net_http_failed', v_n);
  exception when others then v_out := v_out || jsonb_build_object('net_http_failed', null);
  end;

  -- Razorpay events waiting longer than the reconciler's period allows.
  begin
    select count(*) into v_n from public.online_payment_events e
    where e.status = 'pending' and e.received_at < now() - interval '30 minutes';
    v_out := v_out || jsonb_build_object('online_events_pending_old', v_n);
  exception when others then v_out := v_out || jsonb_build_object('online_events_pending_old', null);
  end;

  -- The rest of AiSensy this month: receipt notices and One's parent sends.
  begin
    select count(*) into v_n from public.notification_outbox o
    where o.status in ('provider_accepted', 'delivered')
      and o.updated_at >= (v_month::timestamp at time zone 'Asia/Kolkata');
    v_out := v_out || jsonb_build_object('receipt_notices_month', v_n);
  exception when others then v_out := v_out || jsonb_build_object('receipt_notices_month', null);
  end;
  begin
    select count(*) into v_n from vppsone.message_sends m
    where m.status = 'sent' and m.sent_at >= (v_month::timestamp at time zone 'Asia/Kolkata')
      and coalesce(m.task_transport, 'aisensy') = 'aisensy';
    v_out := v_out || jsonb_build_object('one_sends_month', v_n);
  exception when others then v_out := v_out || jsonb_build_object('one_sends_month', null);
  end;

  -- Every lane together; null if any lane could not be read.
  v_out := v_out || jsonb_build_object(
    'aisensy_month_total',
    (v_out ->> 'parent_reminders_month')::bigint + (v_out ->> 'school_notices_month')::bigint
      + (v_out ->> 'receipt_notices_month')::bigint + (v_out ->> 'one_sends_month')::bigint
      + (v_out ->> 'staff_month')::bigint
  );
  begin
    select case when f.enabled and jsonb_typeof(f.value) = 'number' then (f.value #>> '{}')::numeric::bigint end
      into v_n
    from vppsone.runtime_flags f where f.key = 'aisensy_month_plan_cap';
    v_out := v_out || jsonb_build_object('aisensy_plan_cap', v_n);
  exception when others then v_out := v_out || jsonb_build_object('aisensy_plan_cap', null);
  end;

  begin
    select count(*) into v_n from vppsone.migration_runs r where r.kind = 'cutover' and r.status = 'succeeded';
    v_out := v_out || jsonb_build_object('cutover_rows', v_n);
  exception when others then v_out := v_out || jsonb_build_object('cutover_rows', null);
  end;

  return v_out;
end;
$$;

comment on function vppsone.ops_health_counts(integer) is
  'The health pack (go-live Phase G, plan §9.1): counts only. Null = could not be read. Service role only.';

revoke all on function vppsone.ops_health_counts(integer) from public, anon, authenticated;
grant execute on function vppsone.ops_health_counts(integer) to service_role;

-- The AiSensy plan's monthly allowance: off until the owner sets it (a
-- number, enabled). Off = the total is reported but not judged.
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
    'staff_notice_student_names',
    'aisensy_month_plan_cap'
  )
);
insert into vppsone.runtime_flags (key, enabled, value, note)
values (
  'aisensy_month_plan_cap', false, null,
  'AiSensy messages a month (IST) the plan allows, every lane together. Set the number and enable it; the system check warns from 80%.'
)
on conflict (key) do nothing;

-- ======================================================== migrations/20261101041404_fees_bridge_projection.sql
-- One-owned disposable read projections. No copied financial engine or send triggers.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table vppsone.fees_bridge_state (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  live_read_ready boolean not null default false,
  source_project_ref text not null default 'vgqyilgstjvgohrsiwkb'
    check (source_project_ref = 'vgqyilgstjvgohrsiwkb'),
  contract_version integer not null default 1 check (contract_version = 1),
  last_revision bigint not null default 0 check (last_revision >= 0),
  snapshot_id uuid,
  captured_at timestamptz,
  applied_at timestamptz,
  last_checked_at timestamptz,
  as_of_date date,
  active_session_label text,
  counts jsonb not null default '{}'::jsonb,
  snapshot_sha256 text,
  last_error_code text,
  last_attempt_at timestamptz
);
insert into vppsone.fees_bridge_state (id) values (true);

create table vppsone.fees_bridge_sessions (
  id uuid primary key,
  session_label text not null unique,
  status text,
  is_current boolean not null default false,
  notes text,
  created_at timestamptz,
  updated_at timestamptz,
  fields jsonb not null default '{}'::jsonb
);
create table vppsone.fees_bridge_classes (
  id uuid primary key,
  session_label text not null,
  class_name text not null,
  section text,
  stream_name text,
  sort_order integer,
  status text,
  notes text,
  created_at timestamptz,
  updated_at timestamptz,
  fields jsonb not null default '{}'::jsonb,
  constraint fees_bridge_classes_session_fkey foreign key (session_label)
    references vppsone.fees_bridge_sessions(session_label) deferrable initially deferred
);
create index fees_bridge_classes_session_idx on vppsone.fees_bridge_classes(session_label);
create table vppsone.fees_bridge_students (
  id uuid primary key,
  session_label text not null,
  class_id uuid not null,
  admission_no text,
  full_name text not null,
  father_name text,
  mother_name text,
  guardian_name text,
  guardian_relation text,
  guardian_phone text,
  primary_phone text,
  secondary_phone text,
  emergency_contact_name text,
  emergency_contact_phone text,
  roll_no text,
  status text,
  photo_path text,
  photo_url text,
  date_of_birth date,
  gender text,
  house text,
  address text,
  village_city text,
  transport_route_id uuid,
  joined_on date,
  left_on date,
  created_at timestamptz,
  updated_at timestamptz,
  fields jsonb not null default '{}'::jsonb,
  constraint fees_bridge_students_class_id_fkey foreign key (class_id)
    references vppsone.fees_bridge_classes(id) deferrable initially deferred
);
create index fees_bridge_students_session_class_idx on vppsone.fees_bridge_students(session_label,class_id);
create table vppsone.fees_bridge_households (
  id text not null check (id ~ '^(family|student):[0-9a-f-]{36}$'),
  session_label text not null,
  fields jsonb not null,
  primary key(id,session_label)
);
create table vppsone.fees_bridge_runs (
  id uuid primary key,
  revision bigint not null unique,
  captured_at timestamptz not null,
  applied_at timestamptz not null default clock_timestamp(),
  as_of_date date not null,
  counts jsonb not null,
  snapshot_sha256 text not null check (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('applied','verified'))
);
-- Retain display identity for academic history when a canonical row disappears.
-- These never appear in the current roster or authorize a financial operation.
create table vppsone.fees_bridge_retired_students (
  id uuid primary key, session_label text not null, fields jsonb not null,
  retired_at timestamptz not null default clock_timestamp()
);
create table vppsone.fees_bridge_retired_classes (
  id uuid primary key, session_label text not null, fields jsonb not null,
  retired_at timestamptz not null default clock_timestamp()
);

-- No client roles can query or alter these tables directly. All reads must pass
-- the app's staff, class and session authorization, and TEST confinement checks.
alter table vppsone.fees_bridge_state enable row level security;
alter table vppsone.fees_bridge_sessions enable row level security;
alter table vppsone.fees_bridge_classes enable row level security;
alter table vppsone.fees_bridge_students enable row level security;
alter table vppsone.fees_bridge_households enable row level security;
alter table vppsone.fees_bridge_runs enable row level security;
alter table vppsone.fees_bridge_retired_students enable row level security;
alter table vppsone.fees_bridge_retired_classes enable row level security;
revoke all on vppsone.fees_bridge_state, vppsone.fees_bridge_sessions,
  vppsone.fees_bridge_classes, vppsone.fees_bridge_students,
  vppsone.fees_bridge_households, vppsone.fees_bridge_runs,
  vppsone.fees_bridge_retired_students,vppsone.fees_bridge_retired_classes from public,anon,authenticated;
grant select,insert,update,delete on vppsone.fees_bridge_state, vppsone.fees_bridge_sessions,
  vppsone.fees_bridge_classes, vppsone.fees_bridge_students,
  vppsone.fees_bridge_households, vppsone.fees_bridge_runs,
  vppsone.fees_bridge_retired_students,vppsone.fees_bridge_retired_classes to service_role;

-- Reusable missing-only academic bootstrap, called in the same transaction as
-- an accepted bridge generation, AFTER fees_bridge_state is updated. This is
-- deliberately not the legacy rebuild: existing enrolments are One-owned
-- history and are never updated/deleted, including transfers and leavers.
-- Install via the reviewed bridge migration; do not run standalone on Fees.
create or replace function vppsone.bootstrap_fees_bridge_enrolments(p_snapshot_id uuid)
returns integer
language plpgsql security definer set search_path = '' as $$
declare inserted integer; projection_enabled boolean;
begin
  select enabled into projection_enabled from vppsone.fees_bridge_state
  where snapshot_id=p_snapshot_id and last_error_code is null;
  if p_snapshot_id is null or not found then
    raise exception 'bridge_enrolment_generation_mismatch';
  end if;
  -- Shadow bootstrap is validated before the operator enables live academics.
  if not projection_enabled then return 0; end if;
  insert into vppsone.enrolments
    (student_id,class_id,session_label,roll_no,status,enrolled_on,left_on)
  select s.id,s.class_id,s.session_label,s.roll_no,
    case when s.status='left' then 'left'::vppsone.enrolment_status
         else 'enrolled'::vppsone.enrolment_status end,
    s.joined_on,case when s.status='left' then s.left_on else null end
  from vppsone.fees_bridge_students s
  join vppsone.fees_bridge_classes c on c.id=s.class_id and c.session_label=s.session_label
  join vppsone.fees_bridge_sessions ss on ss.session_label=s.session_label
  where not vppsone.is_test_session_label(s.session_label)
    and s.status in ('active','left')
  on conflict (student_id,session_label) do nothing;
  get diagnostics inserted = row_count;
  return inserted;
end;
$$;
revoke all on function vppsone.bootstrap_fees_bridge_enrolments(uuid) from public,anon,authenticated;
grant execute on function vppsone.bootstrap_fees_bridge_enrolments(uuid) to service_role;

create function vppsone.fees_bridge_apply_snapshot(p_snapshot jsonb,p_sha256 text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_state vppsone.fees_bridge_state%rowtype;
  v_revision bigint;
  v_id uuid;
  v_counts jsonb;
  v_captured timestamptz;
  v_day date;
  v_active text;
  v_replay boolean:=false;
begin
  if current_user not in ('service_role','postgres') then
    raise exception 'bridge_service_only' using errcode='42501';
  end if;
  if p_snapshot->>'version' is distinct from '1' or p_snapshot->>'sourceProjectRef' is distinct from 'vgqyilgstjvgohrsiwkb'
    or (p_snapshot->>'complete')::boolean is distinct from true
    or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
    or jsonb_typeof(p_snapshot->'sessions') is distinct from 'array'
    or jsonb_typeof(p_snapshot->'classes') is distinct from 'array'
    or jsonb_typeof(p_snapshot->'students') is distinct from 'array'
    or jsonb_typeof(p_snapshot->'households') is distinct from 'array' then
    raise exception 'bridge_invalid_contract';
  end if;
  v_revision := (p_snapshot->>'revision')::bigint;
  v_id := (p_snapshot->>'snapshotId')::uuid;
  v_captured := (p_snapshot->>'capturedAt')::timestamptz;
  v_day := (p_snapshot->>'asOfDate')::date;
  v_active := p_snapshot->>'activeSessionLabel';
  if v_revision is null or v_revision <= 0 or v_id is null or v_captured is null
    or v_day is null or v_active is null or length(v_active)=0
    or v_captured > clock_timestamp()+interval '1 minute'
    or v_captured < clock_timestamp()-interval '10 minutes'
    or v_day <> (v_captured at time zone 'Asia/Kolkata')::date then
    raise exception 'bridge_invalid_snapshot_identity';
  end if;
  v_counts := jsonb_build_object('sessions',jsonb_array_length(p_snapshot->'sessions'),
    'classes',jsonb_array_length(p_snapshot->'classes'),
    'students',jsonb_array_length(p_snapshot->'students'),
    'households',jsonb_array_length(p_snapshot->'households'));
  if v_counts is distinct from p_snapshot->'counts'
    or (v_counts->>'sessions')::int = 0 or (v_counts->>'classes')::int = 0
    or (v_counts->>'students')::int = 0 then
    raise exception 'bridge_incomplete_snapshot';
  end if;
  select * into strict v_state from vppsone.fees_bridge_state where id for update;
  if v_revision < v_state.last_revision then
    raise exception 'bridge_stale_fence';
  elsif v_revision = v_state.last_revision then
    if v_state.snapshot_id = v_id and v_state.snapshot_sha256 = p_sha256 then
      v_replay:=true;
    else
      raise exception 'bridge_fence_payload_conflict';
    end if;
  end if;
  -- Entire current generation changes in one transaction. Academics reference
  -- stable UUIDs without a cascading FK to these disposable projections.
  if v_state.snapshot_sha256 is distinct from p_sha256 then
  insert into vppsone.fees_bridge_retired_students(id,session_label,fields)
    select b.id,b.session_label,b.fields from vppsone.fees_bridge_students b
    where not exists(select 1 from jsonb_array_elements(p_snapshot->'students') j where (j->>'id')::uuid=b.id)
    on conflict(id) do update set fields=excluded.fields,session_label=excluded.session_label,retired_at=clock_timestamp();
  insert into vppsone.fees_bridge_retired_classes(id,session_label,fields)
    select b.id,b.session_label,b.fields from vppsone.fees_bridge_classes b
    where not exists(select 1 from jsonb_array_elements(p_snapshot->'classes') j where (j->>'id')::uuid=b.id)
    on conflict(id) do update set fields=excluded.fields,session_label=excluded.session_label,retired_at=clock_timestamp();
  delete from vppsone.fees_bridge_retired_students b
    where exists(select 1 from jsonb_array_elements(p_snapshot->'students') j where (j->>'id')::uuid=b.id);
  delete from vppsone.fees_bridge_retired_classes b
    where exists(select 1 from jsonb_array_elements(p_snapshot->'classes') j where (j->>'id')::uuid=b.id);
  delete from vppsone.fees_bridge_students b where not exists
    (select 1 from jsonb_array_elements(p_snapshot->'students') j where (j->>'id')::uuid=b.id);
  delete from vppsone.fees_bridge_classes b where not exists
    (select 1 from jsonb_array_elements(p_snapshot->'classes') j where (j->>'id')::uuid=b.id);
  delete from vppsone.fees_bridge_sessions b where not exists
    (select 1 from jsonb_array_elements(p_snapshot->'sessions') j where (j->>'id')::uuid=b.id);
  delete from vppsone.fees_bridge_households b where not exists
    (select 1 from jsonb_array_elements(p_snapshot->'households') j where j->>'id'=b.id and j->>'session_label'=b.session_label);
  insert into vppsone.fees_bridge_sessions as target
    (id,session_label,status,is_current,notes,created_at,updated_at,fields)
    select (j->>'id')::uuid,j->>'session_label',j->>'status',coalesce((j->>'is_current')::boolean,false),
      j->>'notes',(j->>'created_at')::timestamptz,(j->>'updated_at')::timestamptz,j
    from jsonb_array_elements(p_snapshot->'sessions') j
    on conflict(id) do update set session_label=excluded.session_label,status=excluded.status,
      is_current=excluded.is_current,notes=excluded.notes,created_at=excluded.created_at,
      updated_at=excluded.updated_at,fields=excluded.fields
    where to_jsonb(target) is distinct from to_jsonb(excluded);
  insert into vppsone.fees_bridge_classes as target
    (id,session_label,class_name,section,stream_name,sort_order,status,notes,created_at,updated_at,fields)
    select (j->>'id')::uuid,j->>'session_label',j->>'class_name',j->>'section',j->>'stream_name',
      (j->>'sort_order')::integer,j->>'status',j->>'notes',
      (j->>'created_at')::timestamptz,(j->>'updated_at')::timestamptz,j
    from jsonb_array_elements(p_snapshot->'classes') j
    on conflict(id) do update set session_label=excluded.session_label,class_name=excluded.class_name,
      section=excluded.section,stream_name=excluded.stream_name,sort_order=excluded.sort_order,
      status=excluded.status,notes=excluded.notes,created_at=excluded.created_at,
      updated_at=excluded.updated_at,fields=excluded.fields
    where to_jsonb(target) is distinct from to_jsonb(excluded);
  insert into vppsone.fees_bridge_students as target
    (id,session_label,class_id,admission_no,full_name,father_name,mother_name,guardian_name,
     guardian_relation,guardian_phone,primary_phone,secondary_phone,emergency_contact_name,
     emergency_contact_phone,roll_no,status,photo_path,photo_url,date_of_birth,gender,house,
     address,village_city,transport_route_id,joined_on,left_on,created_at,updated_at,fields)
    select (j->>'id')::uuid,j->>'session_label',(j->>'class_id')::uuid,j->>'admission_no',
      j->>'full_name',j->>'father_name',j->>'mother_name',j->>'guardian_name',j->>'guardian_relation',
      j->>'guardian_phone',j->>'primary_phone',j->>'secondary_phone',j->>'emergency_contact_name',
      j->>'emergency_contact_phone',j->>'roll_no',j->>'status',j->>'photo_path',j->>'photo_url',
      (j->>'date_of_birth')::date,j->>'gender',j->>'house',j->>'address',j->>'village_city',
      (j->>'transport_route_id')::uuid,(j->>'joined_on')::date,(j->>'left_on')::date,
      (j->>'created_at')::timestamptz,(j->>'updated_at')::timestamptz,j
    from jsonb_array_elements(p_snapshot->'students') j
    on conflict(id) do update set session_label=excluded.session_label,class_id=excluded.class_id,
      admission_no=excluded.admission_no,full_name=excluded.full_name,father_name=excluded.father_name,
      mother_name=excluded.mother_name,guardian_name=excluded.guardian_name,
      guardian_relation=excluded.guardian_relation,guardian_phone=excluded.guardian_phone,
      primary_phone=excluded.primary_phone,secondary_phone=excluded.secondary_phone,
      emergency_contact_name=excluded.emergency_contact_name,emergency_contact_phone=excluded.emergency_contact_phone,
      roll_no=excluded.roll_no,status=excluded.status,photo_path=excluded.photo_path,photo_url=excluded.photo_url,
      date_of_birth=excluded.date_of_birth,gender=excluded.gender,house=excluded.house,address=excluded.address,
      village_city=excluded.village_city,transport_route_id=excluded.transport_route_id,
      joined_on=excluded.joined_on,left_on=excluded.left_on,created_at=excluded.created_at,
      updated_at=excluded.updated_at,fields=excluded.fields
    where to_jsonb(target) is distinct from to_jsonb(excluded);
  insert into vppsone.fees_bridge_households as target(id,session_label,fields)
    select j->>'id',j->>'session_label',j from jsonb_array_elements(p_snapshot->'households') j
    on conflict(id,session_label) do update set fields=excluded.fields
    where target.fields is distinct from excluded.fields;
  if not exists(select 1 from vppsone.fees_bridge_sessions where session_label=v_active)
    or exists(select 1 from vppsone.fees_bridge_students s
      join vppsone.fees_bridge_classes c on c.id=s.class_id where s.session_label<>c.session_label) then
    raise exception 'bridge_invalid_session_references';
  end if;
  set constraints vppsone.fees_bridge_classes_session_fkey,vppsone.fees_bridge_students_class_id_fkey immediate;
  end if;
  -- Verify projected content against this exact source snapshot, never two
  -- moving live queries. An unexpected local change fails without publishing.
  if (select count(*) from vppsone.fees_bridge_students)<>(v_counts->>'students')::int
    or (select count(*) from vppsone.fees_bridge_classes)<>(v_counts->>'classes')::int
    or (select count(*) from vppsone.fees_bridge_sessions)<>(v_counts->>'sessions')::int
    or (select count(*) from vppsone.fees_bridge_households)<>(v_counts->>'households')::int
    or exists(select 1 from jsonb_array_elements(p_snapshot->'students') j
      left join vppsone.fees_bridge_students b on b.id=(j->>'id')::uuid
      where to_jsonb(b) is distinct from to_jsonb(jsonb_populate_record(null::vppsone.fees_bridge_students,j || jsonb_build_object('fields',j))))
    or exists(select 1 from jsonb_array_elements(p_snapshot->'classes') j
      left join vppsone.fees_bridge_classes b on b.id=(j->>'id')::uuid
      where to_jsonb(b) is distinct from to_jsonb(jsonb_populate_record(null::vppsone.fees_bridge_classes,j || jsonb_build_object('fields',j))))
    or exists(select 1 from jsonb_array_elements(p_snapshot->'sessions') j
      left join vppsone.fees_bridge_sessions b on b.id=(j->>'id')::uuid
      where to_jsonb(b) is distinct from to_jsonb(jsonb_populate_record(null::vppsone.fees_bridge_sessions,
        j || jsonb_build_object('fields',j,'is_current',coalesce((j->>'is_current')::boolean,false)))))
    or exists(select 1 from jsonb_array_elements(p_snapshot->'households') j
      left join vppsone.fees_bridge_households b on b.id=j->>'id' and b.session_label=j->>'session_label'
      where b.fields is distinct from j) then
    raise exception 'bridge_projection_verification_failed';
  end if;
  if v_replay then
    perform vppsone.bootstrap_fees_bridge_enrolments(v_id);
    return jsonb_build_object('applied',false,'replayed',true,'revision',v_revision::text,'snapshotId',v_id);
  end if;
  update vppsone.fees_bridge_state set last_revision=v_revision,snapshot_id=v_id,
    captured_at=v_captured,applied_at=clock_timestamp(),as_of_date=v_day,
    active_session_label=v_active,counts=v_counts,snapshot_sha256=p_sha256,
    last_error_code=null,last_attempt_at=clock_timestamp(),last_checked_at=clock_timestamp() where id;
  perform vppsone.bootstrap_fees_bridge_enrolments(v_id);
  insert into vppsone.fees_bridge_runs(id,revision,captured_at,as_of_date,counts,snapshot_sha256,status)
    values(v_id,v_revision,v_captured,v_day,v_counts,p_sha256,'verified');
  return jsonb_build_object('applied',true,'replayed',false,'revision',v_revision::text,'snapshotId',v_id,'counts',v_counts);
end;
$$;
revoke all on function vppsone.fees_bridge_apply_snapshot(jsonb,text) from public,anon,authenticated;
grant execute on function vppsone.fees_bridge_apply_snapshot(jsonb,text) to service_role;
comment on function vppsone.fees_bridge_apply_snapshot(jsonb,text) is
  'Service-only complete roster generation replacement, fenced and atomic. Never posts money or sends messages.';

-- Publication is a separate acceptance step. Enforce its identity and freshness
-- prerequisites in the database as well as the rollout tooling.
create function vppsone.fees_bridge_guard_publication() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if new.enabled and new.live_read_ready then
    if new.last_revision<=0 or new.last_error_code is not null
      or new.last_checked_at is null or new.last_checked_at<clock_timestamp()-interval '5 minutes'
      or new.as_of_date is distinct from (clock_timestamp() at time zone 'Asia/Kolkata')::date then
      -- Once published, allow error/health updates to report an outage. This
      -- check guards only the transition into publication.
      if not (old.enabled and old.live_read_ready) then raise exception 'bridge_not_ready'; end if;
    end if;
    if exists(select 1 from vppsone.fees_bridge_classes where vppsone.is_test_session(session_label))
      or exists(select 1 from public.classes c join vppsone.fees_bridge_classes b using(id)
        where vppsone.is_test_session(c.session_label))
      or exists(select 1 from public.students s join public.classes c on c.id=s.class_id
        join vppsone.fees_bridge_students b on b.id=s.id where vppsone.is_test_session(c.session_label))
      or exists(select 1 from public.classes c join vppsone.fees_bridge_retired_classes b using(id)
        where vppsone.is_test_session(c.session_label))
      or exists(select 1 from public.students s join public.classes c on c.id=s.class_id
        join vppsone.fees_bridge_retired_students b on b.id=s.id where vppsone.is_test_session(c.session_label)) then
      raise exception 'bridge_test_identity_collision';
    end if;
    if not (old.enabled and old.live_read_ready) and exists(
      select 1 from vppsone.fees_bridge_students s
      where s.status in ('active','left') and not exists(select 1 from vppsone.enrolments e
        where e.student_id=s.id and e.session_label=s.session_label)) then
      raise exception 'bridge_academic_bootstrap_incomplete';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function vppsone.fees_bridge_guard_publication() from public,anon,authenticated;
create trigger fees_bridge_publication_guard before update on vppsone.fees_bridge_state
for each row execute function vppsone.fees_bridge_guard_publication();
notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261101042523_fees_bridge_academic_identity.sql
-- Resolve academic identities through the One-owned live projection while
-- preserving the isolated local TEST engine. Never change financial functions.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create view vppsone.fees_identity_students with (security_invoker=true) as
  select s.* from public.students s join public.classes c on c.id=s.class_id
  where not coalesce((select enabled from vppsone.fees_bridge_state where id),false)
     or vppsone.is_test_session(c.session_label)
  union all
  select (jsonb_populate_record(null::public.students,b.fields)).*
  from vppsone.fees_bridge_students b
  where coalesce((select enabled and live_read_ready and last_error_code is null
      and last_checked_at>=clock_timestamp()-interval '5 minutes' from vppsone.fees_bridge_state where id),false)
    and not vppsone.is_test_session(b.session_label)
  union all
  select (jsonb_populate_record(null::public.students,b.fields || jsonb_build_object('status','left'))).*
  from vppsone.fees_bridge_retired_students b
  where coalesce((select enabled and live_read_ready and last_error_code is null
      and last_checked_at>=clock_timestamp()-interval '5 minutes' from vppsone.fees_bridge_state where id),false)
    and not vppsone.is_test_session(b.session_label);

create view vppsone.fees_identity_classes with (security_invoker=true) as
  select c.* from public.classes c
  where not coalesce((select enabled from vppsone.fees_bridge_state where id),false)
     or vppsone.is_test_session(c.session_label)
  union all
  select (jsonb_populate_record(null::public.classes,b.fields)).*
  from vppsone.fees_bridge_classes b
  where coalesce((select enabled and live_read_ready and last_error_code is null
      and last_checked_at>=clock_timestamp()-interval '5 minutes' from vppsone.fees_bridge_state where id),false)
    and not vppsone.is_test_session(b.session_label)
  union all
  select (jsonb_populate_record(null::public.classes,b.fields)).*
  from vppsone.fees_bridge_retired_classes b
  where coalesce((select enabled and live_read_ready and last_error_code is null
      and last_checked_at>=clock_timestamp()-interval '5 minutes' from vppsone.fees_bridge_state where id),false)
    and not vppsone.is_test_session(b.session_label);
revoke all on vppsone.fees_identity_students,vppsone.fees_identity_classes from public,anon,authenticated;
grant select on vppsone.fees_identity_students,vppsone.fees_identity_classes to service_role;

-- An explicit allowlist preserves the latest deployed authorization/body of
-- each academic function, changing only the two identity relation references.
-- Financial gates, receipt functions and financial recovery stay untouched.
do $$
declare signature text; object_id oid; definition text; rewritten text;
begin
  foreach signature in array array[
    'vppsone.apply_sampark_row(uuid,integer,uuid,uuid)',
    'vppsone.claim_staff_notice(text,integer,text,uuid,boolean)',
    'vppsone.create_teacher_tasks(uuid,uuid,text)',
    'vppsone.place_student_photo(jsonb)',
    'vppsone.resolve_sampark_row(jsonb)',
    'vppsone.restart_teacher_task(uuid,uuid)',
    'vppsone.student_in_visible_session(uuid)',
    'vppsone.student_notice_facts(uuid)',
    'vppsone.teacher_task_access(uuid,uuid,text)',
    'vppsone.teacher_task_delivery_snapshot(uuid)'
  ] loop
    object_id:=to_regprocedure(signature);
    if object_id is null then raise exception 'Academic bridge dependency missing: %',signature; end if;
    definition:=pg_get_functiondef(object_id);
    rewritten:=replace(replace(definition,'public.students','vppsone.fees_identity_students'),
      'public.classes','vppsone.fees_identity_classes');
    if definition=rewritten then raise exception 'Academic bridge expected reference missing: %',signature; end if;
    execute rewritten;
  end loop;
end;
$$;
-- In coexistence, an unknown UUID must not inherit real visibility. This also
-- ensures current source-dependent academic policies fail closed on stale data.
create or replace function vppsone.student_in_visible_session(p_student_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select p_student_id is null or case
    when coalesce((select enabled from vppsone.fees_bridge_state where id),false) then
      exists(select 1 from vppsone.fees_identity_students s
        join vppsone.fees_identity_classes c on c.id=s.class_id
        where s.id=p_student_id and (vppsone.is_real_admin()
          or vppsone.is_test_session(c.session_label)=vppsone.current_is_test_account()))
    else vppsone.is_real_admin() or coalesce(
      (select vppsone.is_test_session(c.session_label)=vppsone.current_is_test_account()
        from public.students s join public.classes c on c.id=s.class_id where s.id=p_student_id),
      not vppsone.current_is_test_account()) end;
$$;
notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261101045818_fees_bridge_current_identity_guards.sql
-- Historical tombstones are display-only. Current academic commands must not
-- gain authority from a deleted/left student or an old One class membership.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create or replace view vppsone.fees_identity_students with (security_invoker=true) as
  select s.* from public.students s join public.classes c on c.id=s.class_id
  where not coalesce((select enabled from vppsone.fees_bridge_state where id),false)
     or vppsone.is_test_session(c.session_label)
  union all
  select (jsonb_populate_record(null::public.students,b.fields)).*
  from vppsone.fees_bridge_students b
  where coalesce((select enabled and live_read_ready and last_error_code is null
      and last_checked_at>=clock_timestamp()-interval '5 minutes' from vppsone.fees_bridge_state where id),false)
    and not vppsone.is_test_session(b.session_label);

create or replace view vppsone.fees_identity_classes with (security_invoker=true) as
  select c.* from public.classes c
  where not coalesce((select enabled from vppsone.fees_bridge_state where id),false)
     or vppsone.is_test_session(c.session_label)
  union all
  select (jsonb_populate_record(null::public.classes,b.fields)).*
  from vppsone.fees_bridge_classes b
  where coalesce((select enabled and live_read_ready and last_error_code is null
      and last_checked_at>=clock_timestamp()-interval '5 minutes' from vppsone.fees_bridge_state where id),false)
    and not vppsone.is_test_session(b.session_label);

-- TEST keeps its existing rules. A real current action requires a current
-- active source row and an explicitly matching academic enrolment. Source
-- transfers/leavers never rewrite historical enrolments or grant new access.
create view vppsone.fees_action_students with (security_invoker=true) as
  select s.* from vppsone.fees_identity_students s
  join vppsone.fees_identity_classes c on c.id=s.class_id
  where not coalesce((select enabled from vppsone.fees_bridge_state where id),false)
     or vppsone.is_test_session(c.session_label)
     or (s.status::text='active' and exists(
       select 1 from vppsone.enrolments e where e.student_id=s.id
         and e.session_label=c.session_label and e.class_id=s.class_id and e.status='enrolled'));
revoke all on vppsone.fees_action_students from public,anon,authenticated;
grant select on vppsone.fees_action_students to service_role;

-- Keep each deployed function's authorization and command logic. Only its
-- source identity lookup becomes current-action-only; public TEST behavior is
-- preserved by the action view above. History readers use explicit tombstones.
do $$
declare signature text; definition text; rewritten text;
begin
  foreach signature in array array[
    'vppsone.apply_sampark_row(uuid,integer,uuid,uuid)',
    'vppsone.claim_staff_notice(text,integer,text,uuid,boolean)',
    'vppsone.create_teacher_tasks(uuid,uuid,text)',
    'vppsone.place_student_photo(jsonb)',
    'vppsone.resolve_sampark_row(jsonb)',
    'vppsone.restart_teacher_task(uuid,uuid)',
    'vppsone.student_notice_facts(uuid)',
    'vppsone.teacher_task_access(uuid,uuid,text)'
  ] loop
    if to_regprocedure(signature) is null then raise exception 'Academic action dependency missing: %',signature; end if;
    definition:=pg_get_functiondef(to_regprocedure(signature));
    rewritten:=replace(definition,'vppsone.fees_identity_students','vppsone.fees_action_students');
    if definition=rewritten then raise exception 'Academic action expected reference missing: %',signature; end if;
    execute rewritten;
  end loop;
  -- Delivery snapshots only read a class label directly. Their authority is
  -- the guarded task check and canonical roster functions, so no student
  -- relation rewrite applies. Pin those dependencies instead of skipping an
  -- unexpected missing reference for every function in the allowlist.
  definition:=pg_get_functiondef('vppsone.teacher_task_delivery_snapshot(uuid)'::regprocedure);
  if position('vppsone.teacher_task_access(' in definition)=0
    or position('vppsone.paper_roster(' in definition)=0
    or position('vppsone.attendance_roster(' in definition)=0
    or position('vppsone.fees_identity_classes' in definition)=0 then
    raise exception 'Task delivery current authority dependency missing';
  end if;
end;
$$;

create function vppsone.assert_fees_bridge_roster_current(p_ids uuid[],p_class uuid,p_session text)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if not coalesce((select enabled from vppsone.fees_bridge_state where id),false)
     or vppsone.is_test_session(p_session) then return; end if;
  if not exists(select 1 from vppsone.fees_identity_classes c where c.id=p_class and c.session_label=p_session)
    or exists(select 1 from unnest(p_ids) x(id) where not exists(
      select 1 from vppsone.fees_action_students s where s.id=x.id and s.class_id=p_class)) then
    raise exception 'bridge_academic_membership_changed';
  end if;
end;
$$;
revoke all on function vppsone.assert_fees_bridge_roster_current(uuid[],uuid,text) from public,anon,authenticated;
grant execute on function vppsone.assert_fees_bridge_roster_current(uuid[],uuid,text) to service_role;

-- The same roster is used to render and save. Refuse a drifted roster rather
-- than silently dropping children from a complete-register or exam command.
create or replace function vppsone.attendance_roster(p_session text,p_class uuid,p_day date)
returns setof uuid language plpgsql stable security definer set search_path='' as $$
declare ids uuid[];
begin
  select coalesce(array_agg(e.student_id order by e.student_id),'{}'::uuid[]) into ids
  from vppsone.enrolments e
  where e.session_label=p_session and e.class_id=p_class
    and (e.enrolled_on is null or e.enrolled_on<=p_day)
    and ((e.status in ('enrolled','promoted') and e.left_on is null)
      or (e.left_on is not null and e.left_on>=p_day));
  perform vppsone.assert_fees_bridge_roster_current(ids,p_class,p_session);
  return query select unnest(ids);
end;
$$;

create or replace function vppsone.paper_roster(p_paper uuid)
returns setof uuid language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]; v_class uuid; v_session text;
begin
  select s.class_id,a.session_label into v_class,v_session
    from vppsone.assessment_subjects s join vppsone.assessments a on a.id=s.assessment_id where s.id=p_paper;
  if not found then return; end if;
  select coalesce(array_agg(e.student_id order by e.student_id),'{}'::uuid[]) into ids
  from vppsone.assessment_subjects s join vppsone.assessments a on a.id=s.assessment_id
  join vppsone.enrolments e on e.class_id=s.class_id and e.session_label=a.session_label
  where s.id=p_paper
    and (e.enrolled_on is null or e.enrolled_on<=coalesce(a.ends_on,a.starts_on,vppsone.school_today()))
    and ((e.status in ('enrolled','promoted') and e.left_on is null)
      or (e.left_on is not null and e.left_on>=coalesce(a.starts_on,a.ends_on,vppsone.school_today())));
  perform vppsone.assert_fees_bridge_roster_current(ids,v_class,v_session);
  return query select unnest(ids);
end;
$$;
notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261101170720_school_office_certificates.sql
-- School Office: independent school document authority; no financial mutations.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Called by the server only, after its session and view-as checks. Recheck
-- active actor, current matrix and TEST scope inside every consequential command.
create function vppsone.school_office_actor_allowed(p_actor uuid,p_permission text,p_session text default null,p_confined boolean default false)
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from vppsone.staff_profiles sp
   join vppsone.role_permissions rp on rp.role=sp.role and rp.permission=p_permission
   where sp.id=p_actor and sp.is_active
   and (p_permission not like 'certificates:%' and p_permission not like 'government:%' and p_permission not like 'outcomes:%'
     or sp.role in('admin','office','academic_coordinator','exam_coordinator'))
   and (p_session is null or (
     (not p_confined or vppsone.is_test_session(p_session))
     and (vppsone.is_test_session(p_session)=coalesce(sp.is_test_account,false)
       or (sp.role='admin' and not coalesce(sp.is_test_account,false)))))
   and (p_permission<>'certificates:manage' or (not coalesce(sp.is_test_account,false) and not p_confined)));
$$;
revoke all on function vppsone.school_office_actor_allowed(uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_office_actor_allowed(uuid,text,text,boolean) to service_role;

create function vppsone.school_office_session_visible(p_session text)
returns boolean language sql stable security definer set search_path='' as $$
 select vppsone.is_active_staff() and (
   vppsone.is_test_session(p_session)=vppsone.current_is_test_account() or vppsone.is_real_admin());
$$;
revoke all on function vppsone.school_office_session_visible(text) from public,anon;
grant execute on function vppsone.school_office_session_visible(text) to authenticated,service_role;

create table vppsone.school_certificate_templates (
 version integer primary key check(version>0), active boolean not null default false,
 template jsonb not null check(jsonb_typeof(template)='object'),
 approved_by uuid references vppsone.staff_profiles(id), approved_via text not null,
 created_at timestamptz not null default now(),
 check((template->>'version')::integer=version),check((template->>'signaturePolicy')='manual')
);
create unique index school_certificate_template_active on vppsone.school_certificate_templates(active) where active;
alter table vppsone.school_certificate_templates enable row level security;
create policy certificate_templates_read on vppsone.school_certificate_templates for select to authenticated
 using ((select vppsone.staff_can_any(array['certificates:view','certificates:issue','certificates:manage'])));
revoke all on vppsone.school_certificate_templates from public,anon,authenticated;
grant select on vppsone.school_certificate_templates to authenticated;
grant all on vppsone.school_certificate_templates to service_role;

insert into vppsone.school_certificate_templates(version,active,approved_via,template) values(1,true,
 'owner instruction 2026-11-01: existing letterhead, manual signature, VPPS/STUDY/<session>/0001',
 jsonb_build_object('version',1,'active',true,'titleEn','Study Certificate','titleHi','अध्ययन प्रमाण पत्र',
 'bodyEn','This is to certify that {studentName}, admission/SR number {admissionNo}, is enrolled in Class {classLabel} for academic session {sessionLabel} at {schoolName}.',
 'bodyHi','प्रमाणित किया जाता है कि {studentName}, प्रवेश/एसआर संख्या {admissionNo}, शैक्षणिक सत्र {sessionLabel} में {schoolName} की कक्षा {classLabel} में अध्ययनरत हैं।',
 'historicalBodyEn','This is to certify that {studentName}, admission/SR number {admissionNo}, was enrolled in Class {classLabel} during academic session {sessionLabel} at {schoolName}.',
 'historicalBodyHi','प्रमाणित किया जाता है कि {studentName}, प्रवेश/एसआर संख्या {admissionNo}, शैक्षणिक सत्र {sessionLabel} के दौरान {schoolName} की कक्षा {classLabel} में अध्ययनरत थे।',
 'requiredFields',jsonb_build_array('studentName','admissionNo','classLabel','sessionLabel'),
 'language','en','prefix','VPPS/STUDY','signaturePolicy','manual'));

create table vppsone.school_certificate_series (
 prefix text not null,session_label text not null,is_test boolean not null,last_number bigint not null check(last_number>0),
 primary key(prefix,session_label,is_test),check(is_test=vppsone.is_test_session(session_label))
);
alter table vppsone.school_certificate_series enable row level security;
revoke all on vppsone.school_certificate_series from public,anon,authenticated;
grant all on vppsone.school_certificate_series to service_role;

create table vppsone.school_certificate_issues (
 id uuid primary key default gen_random_uuid(),student_id uuid not null,session_label text not null,
 enrolment_id uuid not null references vppsone.enrolments(id),template_version integer not null references vppsone.school_certificate_templates(version),
 serial text not null unique,status text not null default 'prepared' check(status in('prepared','issued','superseded','cancelled')),
 artifact_state text not null default 'preparing' check(artifact_state in('preparing','ready','failed')),
 snapshot jsonb not null,issued_by uuid not null references vppsone.staff_profiles(id),issued_at timestamptz not null default now(),
 student_name text generated always as(snapshot->'facts'->>'studentName') stored,
 admission_no text generated always as(snapshot->'facts'->>'admissionNo') stored,
 storage_path text unique,artifact_sha256 text,artifact_bytes integer,
 supersedes uuid references vppsone.school_certificate_issues(id),reason text,
 check(artifact_sha256 is null or artifact_sha256 ~ '^[a-f0-9]{64}$'),
 check(artifact_state<>'ready' or (storage_path is not null and artifact_sha256 is not null and artifact_bytes>0)),
 check((snapshot->>'serial')=serial),check((snapshot->'facts'->>'studentId')::uuid=student_id),
 check(snapshot->'facts'->>'sessionLabel'=session_label)
);
create index school_certificate_student_session on vppsone.school_certificate_issues(student_id,session_label,issued_at desc);
create index school_certificate_register on vppsone.school_certificate_issues(session_label,issued_at desc);
create unique index school_certificate_supersedes_once on vppsone.school_certificate_issues(supersedes) where supersedes is not null and status<>'cancelled';
alter table vppsone.school_certificate_issues enable row level security;
create policy certificate_issues_read on vppsone.school_certificate_issues for select to authenticated
 using ((select vppsone.staff_can('certificates:view')) and (select vppsone.reads_every_class()) and vppsone.school_office_session_visible(session_label));
revoke all on vppsone.school_certificate_issues from public,anon,authenticated;
grant select on vppsone.school_certificate_issues to authenticated;
grant all on vppsone.school_certificate_issues to service_role;

create table vppsone.school_certificate_commands (
 command_id uuid primary key,actor_id uuid not null references vppsone.staff_profiles(id),request_hash text not null,
 issue_id uuid not null references vppsone.school_certificate_issues(id),created_at timestamptz not null default now()
);
alter table vppsone.school_certificate_commands enable row level security;
revoke all on vppsone.school_certificate_commands from public,anon,authenticated;
grant all on vppsone.school_certificate_commands to service_role;
create table vppsone.school_certificate_events (
 id uuid primary key default gen_random_uuid(),issue_id uuid not null references vppsone.school_certificate_issues(id),
 actor_id uuid not null references vppsone.staff_profiles(id),kind text not null check(kind in('prepared','download_requested','print_requested','handed_over','superseded','cancelled','artifact_ready','artifact_failed')),
 reason text,command_id uuid unique,created_at timestamptz not null default now()
);
create index school_certificate_events_issue on vppsone.school_certificate_events(issue_id,created_at);
alter table vppsone.school_certificate_events enable row level security;
create policy certificate_events_read on vppsone.school_certificate_events for select to authenticated
 using (exists(select 1 from vppsone.school_certificate_issues i where i.id=issue_id));
revoke all on vppsone.school_certificate_events from public,anon,authenticated;
grant select on vppsone.school_certificate_events to authenticated;
grant all on vppsone.school_certificate_events to service_role;

create function vppsone.school_certificate_immutable()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'certificate:immutable'; end if;
 if new.snapshot is distinct from old.snapshot or new.serial<>old.serial or new.student_id<>old.student_id
   or new.session_label<>old.session_label or new.enrolment_id<>old.enrolment_id or new.template_version<>old.template_version
   or new.issued_at<>old.issued_at or new.issued_by<>old.issued_by or new.supersedes is distinct from old.supersedes
   or new.reason is distinct from old.reason then raise exception 'certificate:immutable'; end if;
 if old.artifact_state='ready' and (new.artifact_state<>old.artifact_state or new.storage_path is distinct from old.storage_path
    or new.artifact_sha256 is distinct from old.artifact_sha256 or new.artifact_bytes is distinct from old.artifact_bytes) then
   raise exception 'certificate:artifact_immutable'; end if;
 if new.status<>old.status and not (old.status='prepared' and new.status in('issued','superseded','cancelled')
   or old.status='issued' and new.status in('superseded','cancelled')) then raise exception 'certificate:invalid_transition'; end if;
 return new;
end;
$$;
create trigger school_certificate_immutable before update or delete on vppsone.school_certificate_issues
 for each row execute function vppsone.school_certificate_immutable();
revoke all on function vppsone.school_certificate_immutable() from public,anon,authenticated;

-- Minimal, authorized document facts. The views enforce source freshness;
-- historical wording needs an explicit, dated historical enrolment.
create function vppsone.school_certificate_facts(p_actor uuid,p_student uuid,p_session text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare e vppsone.enrolments; s jsonb; c jsonb; t jsonb; current_record boolean; verified boolean; optional_text text;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then raise exception 'certificate:source_unavailable'; end if;
 select * into e from vppsone.enrolments where student_id=p_student and session_label=p_session order by created_at desc limit 1;
 select to_jsonb(x) into s from vppsone.fees_identity_students x where x.id=p_student limit 1;
 select to_jsonb(x) into c from vppsone.fees_identity_classes x where x.id=e.class_id and x.session_label=p_session;
 select template into t from vppsone.school_certificate_templates where active;
 current_record:=coalesce(e.status::text='enrolled' and e.left_on is null and s->>'status'='active' and (s->>'class_id')::uuid=e.class_id,false);
 verified:=e.id is not null and s is not null and c is not null and (current_record or (e.enrolled_on is not null and e.left_on is not null and e.left_on>=e.enrolled_on));
 optional_text:=coalesce((t->'requiredFields')::text,'') || ' ' ||
   case when t->>'language' in('en','both') then coalesce(t->>(case when current_record then 'bodyEn' else 'historicalBodyEn' end),'') else '' end || ' ' ||
   case when t->>'language' in('hi','both') then coalesce(t->>(case when current_record then 'bodyHi' else 'historicalBodyHi' end),'') else '' end;
 return jsonb_build_object('studentId',p_student,'enrolmentId',coalesce(e.id,'00000000-0000-0000-0000-000000000000'::uuid),
   'classId',coalesce(e.class_id,'00000000-0000-0000-0000-000000000000'::uuid),'studentName',coalesce(s->>'full_name',''),
   'admissionNo',coalesce(s->>'admission_no',''),'classLabel',concat_ws(' ',c->>'class_name',nullif(c->>'section','')),
   'sessionLabel',p_session,'status',case when current_record then 'current' else 'historical' end,
   'enrolledOn',e.enrolled_on,'leftOn',e.left_on,
   'dateOfBirth',case when position('dateOfBirth' in optional_text)>0 then s->>'date_of_birth' end,
   'fatherName',case when position('fatherName' in optional_text)>0 then s->>'father_name' end,
   'motherName',case when position('motherName' in optional_text)>0 then s->>'mother_name' end,
   'identityVerified',verified,'sourceCurrent',s is not null and c is not null,
   'sourceRevision',case when vppsone.is_test_session(p_session) then coalesce(s->>'updated_at','test') else coalesce((select last_revision::text from vppsone.fees_bridge_state where id),'unknown') end,
   'checkedAt',clock_timestamp());
end;
$$;
revoke all on function vppsone.school_certificate_facts(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_facts(uuid,uuid,text,boolean) to service_role;

-- A reprint is also a durable command. Keep it available during source outages
-- without allowing a delayed retry to become a new issuance after cancellation.
create function vppsone.school_certificate_current(p_actor uuid,p_student uuid,p_session text,p_command uuid,p_request_hash text,p_confined boolean default false,p_issue uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_certificate_commands; issue vppsone.school_certificate_issues;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'certificate:invalid_command'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-command:'||p_command::text,0));
 select * into prior from vppsone.school_certificate_commands where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'certificate:command_reused'; end if;
   select * into issue from vppsone.school_certificate_issues where id=prior.issue_id;
   if issue.student_id<>p_student or issue.session_label<>p_session then raise exception 'certificate:command_reused'; end if;
   return to_jsonb(issue);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-student:'||p_student::text||':'||p_session,0));
 select * into issue from vppsone.school_certificate_issues where student_id=p_student and session_label=p_session
   and status in('prepared','issued') and (p_issue is null or id=p_issue) order by issued_at desc limit 1;
 if not found then
   if p_issue is not null then raise exception 'certificate:stale_issue'; end if;
   return null;
 end if;
 insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
 return to_jsonb(issue);
end;
$$;
revoke all on function vppsone.school_certificate_current(uuid,uuid,text,uuid,text,boolean,uuid) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_current(uuid,uuid,text,uuid,text,boolean,uuid) to service_role;

create function vppsone.school_certificate_reserve(p_actor uuid,p_student uuid,p_session text,p_command uuid,p_request_hash text,
 p_expected_facts jsonb,p_school jsonb,p_expected_template integer,p_new boolean default false,p_supersedes uuid default null,p_reason text default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_certificate_commands; issue vppsone.school_certificate_issues; t vppsone.school_certificate_templates;
 facts jsonb; serial_number bigint; serial_text text; instant timestamptz:=clock_timestamp(); field text;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'certificate:invalid_command'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-command:'||p_command::text,0));
 select * into prior from vppsone.school_certificate_commands where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'certificate:command_reused'; end if;
   select * into issue from vppsone.school_certificate_issues where id=prior.issue_id;
   return jsonb_build_object('issue',to_jsonb(issue),'existing',true);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-student:'||p_student::text||':'||p_session,0));
 if not p_new and p_supersedes is null then
   select * into issue from vppsone.school_certificate_issues where student_id=p_student and session_label=p_session
     and status in('prepared','issued') order by issued_at desc limit 1;
   if found then
     insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
     return jsonb_build_object('issue',to_jsonb(issue),'existing',true);
   end if;
 end if;
 select * into t from vppsone.school_certificate_templates where active for share;
 if not found then raise exception 'certificate:template_inactive'; end if;
 if t.version<>p_expected_template then raise exception 'certificate:template_changed'; end if;
 facts:=vppsone.school_certificate_facts(p_actor,p_student,p_session,p_confined);
 if facts->>'identityVerified'<>'true' or facts->>'sourceCurrent'<>'true' then raise exception 'certificate:identity_unverified'; end if;
 if (facts-'checkedAt') is distinct from (p_expected_facts-'checkedAt') then raise exception 'certificate:source_changed'; end if;
 for field in select jsonb_array_elements_text(t.template->'requiredFields') loop
   if nullif(btrim(facts->>field),'') is null then raise exception 'certificate:missing_field:%',field; end if;
 end loop;
 if p_supersedes is not null then
   if not vppsone.school_office_actor_allowed(p_actor,'certificates:manage',p_session,p_confined) or length(btrim(coalesce(p_reason,'')))<3 then raise exception 'certificate:correction_forbidden'; end if;
   select * into issue from vppsone.school_certificate_issues where id=p_supersedes and student_id=p_student and session_label=p_session for update;
   if not found or issue.status not in('prepared','issued') then raise exception 'certificate:stale_issue'; end if;
 end if;
 if p_school->>'name' is null or length(p_school->>'name')<2 then raise exception 'certificate:school_missing'; end if;
 insert into vppsone.school_certificate_series(prefix,session_label,is_test,last_number)
   values(t.template->>'prefix',p_session,vppsone.is_test_session(p_session),1)
   on conflict(prefix,session_label,is_test) do update set last_number=vppsone.school_certificate_series.last_number+1
   returning last_number into serial_number;
 serial_text:=case when vppsone.is_test_session(p_session) then 'TEST/' else '' end||(t.template->>'prefix');
 serial_text:=serial_text||'/'||p_session||'/'||lpad(serial_number::text,greatest(4,length(serial_number::text)),'0');
 insert into vppsone.school_certificate_issues(student_id,session_label,enrolment_id,template_version,serial,snapshot,issued_by,issued_at,supersedes,reason)
   values(p_student,p_session,(facts->>'enrolmentId')::uuid,t.version,serial_text,
    jsonb_build_object('serial',serial_text,'issuedAt',instant,'issuedOn',(instant at time zone 'Asia/Kolkata')::date,
      'isTest',vppsone.is_test_session(p_session),'school',p_school,'facts',facts,'template',t.template),p_actor,instant,p_supersedes,p_reason)
   returning * into issue;
 insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
 insert into vppsone.school_certificate_events(issue_id,actor_id,kind) values(issue.id,p_actor,'prepared');
 -- Supersession is finalized only after the new artifact is safely stored.
 return jsonb_build_object('issue',to_jsonb(issue),'existing',false);
end;
$$;
revoke all on function vppsone.school_certificate_reserve(uuid,uuid,text,uuid,text,jsonb,jsonb,integer,boolean,uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_reserve(uuid,uuid,text,uuid,text,jsonb,jsonb,integer,boolean,uuid,text,boolean) to service_role;

create function vppsone.school_certificate_finish(p_actor uuid,p_issue uuid,p_path text,p_sha256 text,p_bytes integer,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare i vppsone.school_certificate_issues; expected_path text;
begin
 select * into i from vppsone.school_certificate_issues where id=p_issue for update;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',i.session_label,p_confined) then raise exception 'certificate:forbidden'; end if;
 expected_path:='certificates/'||i.session_label||'/'||i.student_id::text||'/'||i.id::text||'.pdf';
 if p_path<>expected_path or p_sha256 !~ '^[a-f0-9]{64}$' or p_bytes<20 or p_bytes>2097152 then raise exception 'certificate:invalid_artifact'; end if;
 if i.artifact_state='ready' then
   if i.storage_path<>p_path or i.artifact_sha256<>p_sha256 then raise exception 'certificate:artifact_immutable'; end if;
   return to_jsonb(i);
 end if;
 if i.status in('cancelled','superseded') then raise exception 'certificate:stale_issue'; end if;
 update vppsone.school_certificate_issues set artifact_state='ready',storage_path=p_path,artifact_sha256=p_sha256,artifact_bytes=p_bytes where id=i.id returning * into i;
 if i.supersedes is not null then
   update vppsone.school_certificate_issues set status='superseded' where id=i.supersedes and status in('prepared','issued');
   insert into vppsone.school_certificate_events(issue_id,actor_id,kind,reason) values(i.supersedes,p_actor,'superseded',i.reason);
 end if;
 insert into vppsone.school_certificate_events(issue_id,actor_id,kind) values(i.id,p_actor,'artifact_ready');
 return to_jsonb(i);
end;
$$;
revoke all on function vppsone.school_certificate_finish(uuid,uuid,text,text,integer,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_finish(uuid,uuid,text,text,integer,boolean) to service_role;

create function vppsone.school_certificate_event(p_actor uuid,p_issue uuid,p_kind text,p_reason text,p_command uuid,p_confined boolean default false)
returns void language plpgsql set search_path='' as $$
declare i vppsone.school_certificate_issues; prior vppsone.school_certificate_events; required_permission text;
begin
 select * into i from vppsone.school_certificate_issues where id=p_issue for update;
 required_permission:=case when p_kind='cancelled' then 'certificates:manage' when p_kind='handed_over' then 'certificates:issue' else 'certificates:view' end;
 if not found or not vppsone.school_office_actor_allowed(p_actor,required_permission,i.session_label,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in('download_requested','print_requested','handed_over','cancelled') then raise exception 'certificate:invalid_event'; end if;
 select * into prior from vppsone.school_certificate_events where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.issue_id<>p_issue or prior.kind<>p_kind or prior.reason is distinct from p_reason then raise exception 'certificate:command_reused'; end if;
   return;
 end if;
 if p_kind='cancelled' then
   if length(btrim(coalesce(p_reason,'')))<3 or i.status not in('prepared','issued') then raise exception 'certificate:reason_required'; end if;
   update vppsone.school_certificate_issues set status='cancelled' where id=i.id;
 elsif p_kind='handed_over' then
   if i.status<>'prepared' or i.artifact_state<>'ready' then raise exception 'certificate:not_ready'; end if;
   update vppsone.school_certificate_issues set status='issued' where id=i.id;
 end if;
 insert into vppsone.school_certificate_events(issue_id,actor_id,kind,reason,command_id) values(p_issue,p_actor,p_kind,p_reason,p_command);
end;
$$;
revoke all on function vppsone.school_certificate_event(uuid,uuid,text,text,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_event(uuid,uuid,text,text,uuid,boolean) to service_role;

create function vppsone.school_certificate_save_template(p_actor uuid,p_template jsonb,p_expected_version integer,p_confined boolean default false)
returns integer language plpgsql set search_path='' as $$
declare current_version integer; new_version integer;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:manage',null,p_confined) then raise exception 'certificate:forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-template',0));
 select coalesce(max(version),0) into current_version from vppsone.school_certificate_templates;
 if current_version<>p_expected_version then raise exception 'certificate:template_changed'; end if;
 if p_template->>'signaturePolicy'<>'manual' or p_template->>'prefix' !~ '^[A-Z0-9][A-Z0-9/-]{0,39}$' then raise exception 'certificate:invalid_template'; end if;
 new_version:=current_version+1;
 update vppsone.school_certificate_templates set active=false where active;
 insert into vppsone.school_certificate_templates(version,active,template,approved_by,approved_via)
 values(new_version,coalesce((p_template->>'active')::boolean,false),p_template||jsonb_build_object('version',new_version),p_actor,'authorized template configuration');
 return new_version;
end;
$$;
revoke all on function vppsone.school_certificate_save_template(uuid,jsonb,integer,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_save_template(uuid,jsonb,integer,boolean) to service_role;

-- Certificate artifacts are immutable, private, and fetched only after the
-- certificate-specific authorization above. No broad student-document policy.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('vppsone-certificates','vppsone-certificates',false,2097152,array['application/pdf']) on conflict(id) do nothing;
notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261101170731_school_office_role_permissions.sql
-- Additive capabilities for school-issued documents and official records.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'certificates:view'),
  ('admin', 'certificates:issue'),
  ('admin', 'certificates:manage'),
  ('admin', 'government:view'),
  ('admin', 'government:export'),
  ('admin', 'government:import'),
  ('admin', 'outcomes:view'),
  ('admin', 'outcomes:manage'),
  ('office', 'certificates:view'),
  ('office', 'certificates:issue'),
  ('office', 'government:view'),
  ('office', 'government:export'),
  ('office', 'government:import'),
  ('office', 'outcomes:view'),
  ('exam_coordinator', 'outcomes:view'),
  ('exam_coordinator', 'outcomes:manage')
on conflict do nothing;

-- ======================================================== migrations/20261101170841_school_office_government_records.sql
-- Versioned official-file contracts and One-owned external registration facts.
-- No source-student, financial, guardian, photo or internal-mark mutation.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table vppsone.school_return_adapters (
 id uuid primary key default gen_random_uuid(),portal text not null,module text not null,session_label text not null,school_code text not null,
 version integer not null,adapter jsonb not null,approved_by uuid not null references vppsone.staff_profiles(id),created_at timestamptz not null default now(),
 unique(portal,module,session_label,school_code,version),check(adapter->>'mode'='verified_upload'),
 check(adapter->>'specimenSha256' ~ '^[a-f0-9]{64}$'),check(length(adapter->>'sourceReference')>=10)
);
alter table vppsone.school_return_adapters enable row level security;
create policy school_return_adapters_read on vppsone.school_return_adapters for select to authenticated
 using ((select vppsone.staff_can('government:view')) and (select vppsone.reads_every_class()) and vppsone.school_office_session_visible(session_label));
revoke all on vppsone.school_return_adapters from public,anon,authenticated;
grant select on vppsone.school_return_adapters to authenticated;
grant all on vppsone.school_return_adapters to service_role;

create table vppsone.school_external_records (
 id uuid primary key default gen_random_uuid(),portal text not null,module text not null,school_code text not null,session_label text not null,
 student_id uuid not null,external_id text,registration_status text,revision integer not null default 1,
 source_batch_id uuid,updated_by uuid not null references vppsone.staff_profiles(id),updated_at timestamptz not null default now(),
 unique(portal,module,school_code,session_label,student_id),check(external_id is null or length(external_id) between 1 and 250)
);
create unique index school_external_record_identity on vppsone.school_external_records(portal,module,school_code,session_label,upper(regexp_replace(external_id,'\s','','g'))) where external_id is not null;
create index school_external_records_student on vppsone.school_external_records(student_id,session_label);
alter table vppsone.school_external_records enable row level security;
create policy school_external_records_read on vppsone.school_external_records for select to authenticated
 using ((select vppsone.staff_can_any(array['government:view','outcomes:view'])) and (select vppsone.reads_every_class()) and vppsone.school_office_session_visible(session_label));
revoke all on vppsone.school_external_records from public,anon,authenticated;
grant select on vppsone.school_external_records to authenticated;
grant all on vppsone.school_external_records to service_role;

create table vppsone.school_return_batches (
 id uuid primary key,session_label text not null,portal text not null,module text not null,direction text not null check(direction in('export','import')),
 state text not null check(state in('preparing','exported','staged','applied','submitted','accepted','partially_accepted','rejected')),
 actor_id uuid not null references vppsone.staff_profiles(id),request_hash text not null check(request_hash ~ '^[a-f0-9]{64}$'),
 adapter jsonb not null,payload jsonb not null,source_hash text,parent_batch_id uuid references vppsone.school_return_batches(id),
 file_path text,file_sha256 text,file_name text,content_type text,
 evidence_path text,evidence_sha256 text,evidence_name text,evidence_content_type text,acknowledgement text,row_outcomes jsonb not null default '[]'::jsonb,apply_command uuid unique,apply_receipt jsonb,
 revision integer not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 check(adapter->>'portal'=portal),check(adapter->>'module'=module),check(adapter->>'sessionLabel'=session_label)
);
alter table vppsone.school_external_records add constraint school_external_record_source foreign key(source_batch_id) references vppsone.school_return_batches(id);
create index school_return_batches_register on vppsone.school_return_batches(session_label,created_at desc);
alter table vppsone.school_return_batches enable row level security;
create policy school_return_batches_read on vppsone.school_return_batches for select to authenticated
 using ((select vppsone.staff_can('government:view')) and (select vppsone.reads_every_class()) and vppsone.school_office_session_visible(session_label));
revoke all on vppsone.school_return_batches from public,anon,authenticated;
grant select on vppsone.school_return_batches to authenticated;
grant all on vppsone.school_return_batches to service_role;

create table vppsone.school_return_events (
 id uuid primary key default gen_random_uuid(),batch_id uuid not null references vppsone.school_return_batches(id),actor_id uuid not null references vppsone.staff_profiles(id),
 kind text not null,detail jsonb not null default '{}'::jsonb,created_at timestamptz not null default now()
);
create index school_return_events_batch on vppsone.school_return_events(batch_id,created_at);
alter table vppsone.school_return_events enable row level security;
create policy school_return_events_read on vppsone.school_return_events for select to authenticated
 using(exists(select 1 from vppsone.school_return_batches b where b.id=batch_id));
revoke all on vppsone.school_return_events from public,anon,authenticated;
grant select on vppsone.school_return_events to authenticated;
grant all on vppsone.school_return_events to service_role;

-- Shared, minimal roster for return and official-exam capabilities. No money.
create function vppsone.school_office_roster(p_actor uuid,p_session text,p_permission text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb; source_revision text;
begin
 if p_permission not in('government:view','government:export','government:import','outcomes:view','outcomes:manage')
  or not vppsone.school_office_actor_allowed(p_actor,p_permission,p_session,p_confined)
  or not exists(select 1 from vppsone.staff_profiles where id=p_actor and role in('admin','office','academic_coordinator','exam_coordinator')) then raise exception 'office:forbidden'; end if;
 if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then raise exception 'office:source_unavailable'; end if;
 source_revision:=case when vppsone.is_test_session(p_session) then 'test' else (select last_revision::text from vppsone.fees_bridge_state where id) end;
 if vppsone.is_test_session(p_session) then
   select 'test:'||md5(coalesce(string_agg(s.id::text||coalesce(s.updated_at::text,'')||coalesce(c.updated_at::text,'')||coalesce(e.updated_at::text,''),',' order by s.id),'')) into source_revision
    from vppsone.fees_identity_students s join vppsone.fees_identity_classes c on c.id=s.class_id
    left join vppsone.enrolments e on e.student_id=s.id and e.class_id=c.id and e.session_label=p_session
    where c.session_label=p_session and s.status::text='active';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('studentId',s.id,'studentName',s.full_name,'admissionNo',coalesce(s.admission_no,''),
   'classLabel',concat_ws(' ',c.class_name,nullif(c.section,'')),'classId',c.id,'sessionLabel',p_session,'schoolCode','',
   'externalId','','registrationStatus','','sourceRevision',source_revision,'externalRevision',0,
   'identityVerified',exists(select 1 from vppsone.enrolments e where e.student_id=s.id and e.class_id=c.id and e.session_label=p_session and e.status='enrolled' and e.left_on is null)) order by c.sort_order,s.full_name),'[]'::jsonb)
 into result from vppsone.fees_identity_students s join vppsone.fees_identity_classes c on c.id=s.class_id
 where c.session_label=p_session and s.status::text='active';
 if jsonb_array_length(result)>2000 then raise exception 'office:roster_limit'; end if;
 return result;
end;
$$;
revoke all on function vppsone.school_office_roster(uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_office_roster(uuid,text,text,boolean) to service_role;

create function vppsone.school_return_reserve(p_actor uuid,p_id uuid,p_request_hash text,p_adapter jsonb,p_payload jsonb,p_direction text,p_source_hash text default null,p_parent uuid default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_return_batches; permission text; entry jsonb; source_revision text; roster jsonb;
begin
 permission:=case when p_direction='export' then 'government:export' else 'government:import' end;
 if not vppsone.school_office_actor_allowed(p_actor,permission,p_adapter->>'sessionLabel',p_confined) then raise exception 'office:forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-return:'||p_id::text,0));
 select * into prior from vppsone.school_return_batches where id=p_id;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'office:command_reused'; end if;
   return to_jsonb(prior);
 end if;
 if p_direction not in('export','import') or p_request_hash !~ '^[a-f0-9]{64}$' or p_adapter->>'portal' not in('psp','udise','class5','class8','rbse10','rbse12') then raise exception 'office:invalid'; end if;
 if p_adapter->>'mode'='verified_upload' then
   if not exists(select 1 from vppsone.school_return_adapters where adapter=p_adapter) then raise exception 'office:unverified_adapter'; end if;
 elsif p_direction='import' or p_adapter->>'mode'<>'manual_reference' then raise exception 'office:unverified_adapter'; end if;
 roster:=vppsone.school_office_roster(p_actor,p_adapter->>'sessionLabel',permission,p_confined);
 source_revision:=coalesce(roster->0->>'sourceRevision',case when vppsone.is_test_session(p_adapter->>'sessionLabel') then 'test' else (select last_revision::text from vppsone.fees_bridge_state where id) end);
 if p_payload->>'sourceRevision' is distinct from source_revision then raise exception 'office:source_changed'; end if;
 if p_direction='export' then
   if jsonb_array_length(p_payload->'rows') not between 1 and 2000 then raise exception 'office:invalid_rows'; end if;
   for entry in select * from jsonb_array_elements(p_payload->'rows') loop
     if not exists(select 1 from jsonb_array_elements(roster) r where r->>'studentId'=entry->>'studentId' and r->>'identityVerified'='true'
       and r->>'studentName'=entry->>'studentName' and r->>'admissionNo'=entry->>'admissionNo' and r->>'classLabel'=entry->>'classLabel') then raise exception 'office:roster_changed'; end if;
   end loop;
 else
   if p_source_hash !~ '^[a-f0-9]{64}$' or jsonb_array_length(p_payload->'preview') not between 1 and 2000 then raise exception 'office:invalid_import'; end if;
 end if;
 if p_parent is not null and not exists(select 1 from vppsone.school_return_batches b where b.id=p_parent and b.session_label=p_adapter->>'sessionLabel' and b.portal=p_adapter->>'portal' and b.module=p_adapter->>'module') then raise exception 'office:wrong_parent'; end if;
 insert into vppsone.school_return_batches(id,session_label,portal,module,direction,state,actor_id,request_hash,adapter,payload,source_hash,parent_batch_id)
 values(p_id,p_adapter->>'sessionLabel',p_adapter->>'portal',p_adapter->>'module',p_direction,'preparing',p_actor,p_request_hash,p_adapter,p_payload,p_source_hash,p_parent) returning * into prior;
 insert into vppsone.school_return_events(batch_id,actor_id,kind) values(p_id,p_actor,case when p_direction='export' then 'prepared' else 'import_staged' end);
 return to_jsonb(prior);
end;
$$;
revoke all on function vppsone.school_return_reserve(uuid,uuid,text,jsonb,jsonb,text,text,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_reserve(uuid,uuid,text,jsonb,jsonb,text,text,uuid,boolean) to service_role;

create function vppsone.school_return_finish(p_actor uuid,p_id uuid,p_path text,p_hash text,p_name text,p_type text,p_confined boolean default false)
returns void language plpgsql set search_path='' as $$
declare b vppsone.school_return_batches;
begin
 select * into b from vppsone.school_return_batches where id=p_id for update;
 if not found or not vppsone.school_office_actor_allowed(p_actor,case when b.direction='export' then 'government:export' else 'government:import' end,b.session_label,p_confined) then raise exception 'office:forbidden'; end if;
 if p_path not like 'batches/'||b.id::text||'/%' or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'office:invalid_file'; end if;
 if b.file_path is not null then
   if b.file_path<>p_path or b.file_sha256<>p_hash then raise exception 'office:file_immutable'; end if;
   return;
 end if;
 update vppsone.school_return_batches set file_path=p_path,file_sha256=p_hash,file_name=p_name,content_type=p_type,
   state=case when direction='export' then 'exported' else 'staged' end,revision=revision+1,updated_at=now() where id=p_id;
end;
$$;
revoke all on function vppsone.school_return_finish(uuid,uuid,text,text,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_finish(uuid,uuid,text,text,text,text,boolean) to service_role;

create function vppsone.school_return_apply(p_actor uuid,p_batch uuid,p_command uuid,p_expected_revision integer,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare b vppsone.school_return_batches; row_data jsonb; link vppsone.school_external_records; source_revision text; roster jsonb; applied integer:=0; unchanged integer:=0;
begin
 select * into b from vppsone.school_return_batches where id=p_batch for update;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'government:import',b.session_label,p_confined) then raise exception 'office:forbidden'; end if;
 if b.apply_command=p_command then return b.apply_receipt; end if;
 if b.direction<>'import' or b.state<>'staged' or b.revision<>p_expected_revision or b.file_path is null then raise exception 'office:stale_preview'; end if;
 if exists(select 1 from jsonb_array_elements(b.payload->'preview') r where r->>'state' in('conflict','unmatched')) then raise exception 'office:unresolved_conflicts'; end if;
 roster:=vppsone.school_office_roster(p_actor,b.session_label,'government:import',p_confined);
 source_revision:=roster->0->>'sourceRevision';
 if source_revision is distinct from b.payload->>'sourceRevision' then raise exception 'office:source_changed'; end if;
 -- Serialize link changes within one destination/session namespace.
 perform pg_advisory_xact_lock(hashtextextended('school-return-links:'||b.portal||':'||b.module||':'||b.session_label||':'||(b.adapter->>'schoolCode'),0));
 for row_data in select * from jsonb_array_elements(b.payload->'preview') loop
   if row_data->>'state' not in('ready','unchanged') or (row_data->>'studentId') is null then raise exception 'office:invalid_row'; end if;
   if exists(select 1 from jsonb_object_keys(row_data->'changes') k where k not in('externalId','registrationStatus')) then raise exception 'office:protected_field'; end if;
   if not exists(select 1 from jsonb_array_elements(roster) r where r->>'studentId'=row_data->>'studentId' and r->>'identityVerified'='true') then raise exception 'office:identity_changed'; end if;
   select * into link from vppsone.school_external_records where portal=b.portal and module=b.module and school_code=b.adapter->>'schoolCode' and session_label=b.session_label and student_id=(row_data->>'studentId')::uuid for update;
   if coalesce(link.revision,0)<>coalesce((row_data->>'expectedRevision')::integer,0) then raise exception 'office:stale_preview'; end if;
   if row_data->>'state'='unchanged' then unchanged:=unchanged+1; continue; end if;
   insert into vppsone.school_external_records(portal,module,school_code,session_label,student_id,external_id,registration_status,source_batch_id,updated_by)
   values(b.portal,b.module,b.adapter->>'schoolCode',b.session_label,(row_data->>'studentId')::uuid,nullif(row_data->'changes'->>'externalId',''),nullif(row_data->'changes'->>'registrationStatus',''),b.id,p_actor)
   on conflict(portal,module,school_code,session_label,student_id) do update set
     external_id=coalesce(nullif(row_data->'changes'->>'externalId',''),vppsone.school_external_records.external_id),
     registration_status=coalesce(nullif(row_data->'changes'->>'registrationStatus',''),vppsone.school_external_records.registration_status),
     revision=vppsone.school_external_records.revision+1,source_batch_id=b.id,updated_by=p_actor,updated_at=now();
   applied:=applied+1;
 end loop;
 update vppsone.school_return_batches set state='applied',apply_command=p_command,
   apply_receipt=jsonb_build_object('applied',applied,'unchanged',unchanged,'sourceHash',source_hash,'commandId',p_command),revision=revision+1,updated_at=now()
   where id=b.id returning * into b;
 insert into vppsone.school_return_events(batch_id,actor_id,kind,detail) values(b.id,p_actor,'import_applied',b.apply_receipt);
 return b.apply_receipt;
end;
$$;
revoke all on function vppsone.school_return_apply(uuid,uuid,uuid,integer,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_apply(uuid,uuid,uuid,integer,boolean) to service_role;

create function vppsone.school_return_outcome(p_actor uuid,p_batch uuid,p_expected_revision integer,p_state text,p_ack text,p_evidence text,p_evidence_hash text,p_evidence_name text,p_evidence_type text,p_rows jsonb,p_confined boolean default false)
returns void language plpgsql set search_path='' as $$
declare b vppsone.school_return_batches; accepted_count integer; row_count integer;
begin
 select * into b from vppsone.school_return_batches where id=p_batch for update;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'government:export',b.session_label,p_confined) then raise exception 'office:forbidden'; end if;
 if b.direction<>'export' or b.file_path is null or b.revision<>p_expected_revision or p_state not in('submitted','accepted','partially_accepted','rejected') then raise exception 'office:stale_batch'; end if;
 if p_state='submitted' and b.state not in('exported','rejected') then raise exception 'office:invalid_transition'; end if;
 if p_state in('accepted','partially_accepted','rejected') and b.state not in('submitted','partially_accepted') then raise exception 'office:submission_required'; end if;
 if length(btrim(coalesce(p_ack,'')))<3 then raise exception 'office:acknowledgement_required'; end if;
 if p_state in('accepted','partially_accepted','rejected') and (p_evidence not like 'evidence/'||p_batch::text||'/%' or not exists(select 1 from storage.objects where bucket_id='vppsone-school-office' and name=p_evidence)) then raise exception 'office:evidence_required'; end if;
 if p_state in('accepted','partially_accepted','rejected') and p_evidence_hash !~ '^[a-f0-9]{64}$' then raise exception 'office:evidence_required'; end if;
 if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'office:invalid_outcome'; end if;
 if p_state='submitted' then
   if jsonb_array_length(p_rows)<>0 then raise exception 'office:invalid_outcome'; end if;
 else
   row_count:=jsonb_array_length(b.payload->'rows');
   if row_count=0 or jsonb_array_length(p_rows)<>row_count
     or exists(select 1 from jsonb_array_elements(p_rows) x where x->>'state' not in('accepted','not_accepted') or x->>'state' is null
       or not exists(select 1 from jsonb_array_elements(b.payload->'rows') r where r->>'studentId'=x->>'studentId'))
     or (select count(distinct x->>'studentId') from jsonb_array_elements(p_rows) x)<>row_count then raise exception 'office:invalid_outcome'; end if;
   select count(*) into accepted_count from jsonb_array_elements(p_rows) x where x->>'state'='accepted';
   if (p_state='accepted' and accepted_count<>row_count) or (p_state='rejected' and accepted_count<>0)
     or (p_state='partially_accepted' and (accepted_count=0 or accepted_count=row_count)) then raise exception 'office:invalid_outcome'; end if;
 end if;
 update vppsone.school_return_batches set state=p_state,row_outcomes=p_rows,acknowledgement=p_ack,evidence_path=coalesce(p_evidence,evidence_path),
   evidence_sha256=coalesce(p_evidence_hash,evidence_sha256),evidence_name=coalesce(p_evidence_name,evidence_name),evidence_content_type=coalesce(p_evidence_type,evidence_content_type),revision=revision+1,updated_at=now() where id=p_batch;
 insert into vppsone.school_return_events(batch_id,actor_id,kind,detail) values(p_batch,p_actor,p_state||'_recorded',jsonb_build_object('acknowledgement',p_ack,'evidencePath',p_evidence,'evidenceSha256',p_evidence_hash,'rowOutcomes',p_rows));
end;
$$;
revoke all on function vppsone.school_return_outcome(uuid,uuid,integer,text,text,text,text,text,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_outcome(uuid,uuid,integer,text,text,text,text,text,text,jsonb,boolean) to service_role;

create function vppsone.school_return_save_adapter(p_actor uuid,p_adapter jsonb,p_expected_version integer,p_confined boolean default false)
returns uuid language plpgsql set search_path='' as $$
declare latest integer; result uuid;
begin
 if p_confined or not vppsone.school_office_actor_allowed(p_actor,'settings:manage') or not exists(select 1 from vppsone.staff_profiles where id=p_actor and not is_test_account and is_active) then raise exception 'office:forbidden'; end if;
 if p_adapter->>'mode'<>'verified_upload' or p_adapter->>'specimenSha256' !~ '^[a-f0-9]{64}$' or length(p_adapter->>'sourceReference')<10 or length(p_adapter->>'schoolCode')<1 then raise exception 'office:unverified_adapter'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-return-adapter:'||(p_adapter->>'portal')||':'||(p_adapter->>'module')||':'||(p_adapter->>'sessionLabel')||':'||(p_adapter->>'schoolCode'),0));
 select coalesce(max(version),0) into latest from vppsone.school_return_adapters where portal=p_adapter->>'portal' and module=p_adapter->>'module' and session_label=p_adapter->>'sessionLabel' and school_code=p_adapter->>'schoolCode';
 if latest<>p_expected_version then raise exception 'office:adapter_changed'; end if;
 insert into vppsone.school_return_adapters(portal,module,session_label,school_code,version,adapter,approved_by)
 values(p_adapter->>'portal',p_adapter->>'module',p_adapter->>'sessionLabel',p_adapter->>'schoolCode',latest+1,p_adapter||jsonb_build_object('version',latest+1),p_actor) returning id into result;
 return result;
end;
$$;
revoke all on function vppsone.school_return_save_adapter(uuid,jsonb,integer,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_save_adapter(uuid,jsonb,integer,boolean) to service_role;

create function vppsone.school_return_immutable()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'office:immutable'; end if;
 if new.payload is distinct from old.payload or new.adapter is distinct from old.adapter or new.actor_id<>old.actor_id or new.request_hash<>old.request_hash
  or new.direction<>old.direction or new.session_label<>old.session_label or new.portal<>old.portal or new.module<>old.module or new.source_hash is distinct from old.source_hash
  or new.parent_batch_id is distinct from old.parent_batch_id or new.created_at<>old.created_at then raise exception 'office:immutable'; end if;
 if old.file_path is not null and (new.file_path is distinct from old.file_path or new.file_sha256 is distinct from old.file_sha256 or new.file_name is distinct from old.file_name or new.content_type is distinct from old.content_type) then raise exception 'office:file_immutable'; end if;
 return new;
end;
$$;
create trigger school_return_immutable before update or delete on vppsone.school_return_batches for each row execute function vppsone.school_return_immutable();
revoke all on function vppsone.school_return_immutable() from public,anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('vppsone-school-office','vppsone-school-office',false,2097152,
 array['application/pdf','image/png','image/jpeg','text/csv','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/octet-stream']) on conflict(id) do nothing;
notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261101171208_school_office_board_records.sql
-- One-owned examination administration; no financial or internal-mark writes.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
create table vppsone.school_board_cycles (
 id uuid primary key, session_label text not null, config jsonb not null, revision integer not null default 1 check(revision>0),
 updated_by uuid not null references vppsone.staff_profiles(id),updated_at timestamptz not null default now(),
 check(config->>'sessionLabel'=session_label), check(config->>'authority' in('class5','class8','rbse10','rbse12')),
 check(config->>'attempt' in('main','supplementary','improvement','corrected'))
);
create index school_board_cycles_session on vppsone.school_board_cycles(session_label,updated_at desc);
create table vppsone.school_board_candidates (
 cycle_id uuid not null references vppsone.school_board_cycles(id),student_id uuid not null, registration text not null,roll text not null,
 subjects jsonb not null,verified boolean not null,student_snapshot jsonb,source_reference text not null,revision integer not null check(revision>0),
 verified_by uuid not null references vppsone.staff_profiles(id),verified_at timestamptz not null default now(),primary key(cycle_id,student_id),
 check(length(registration) between 1 and 100),check(length(roll) between 1 and 100),check(length(source_reference) between 10 and 1000),
 check(not verified or (student_snapshot is not null and student_snapshot->>'studentId'=student_id::text and student_snapshot->>'identityVerified'='true' and student_snapshot->>'enrolmentStatus'='enrolled'))
);
create unique index school_board_candidate_roll on vppsone.school_board_candidates(cycle_id,upper(regexp_replace(roll,'\s','','g')));
create unique index school_board_candidate_registration on vppsone.school_board_candidates(cycle_id,upper(regexp_replace(registration,'\s','','g')));
create table vppsone.school_board_readiness (
 cycle_id uuid not null references vppsone.school_board_cycles(id),student_id uuid not null,key text not null,status text not null,
 reference text not null,revision integer not null check(revision>0),cycle_revision integer not null check(cycle_revision>0),updated_by uuid not null references vppsone.staff_profiles(id),updated_at timestamptz not null default now(),
 primary key(cycle_id,student_id,key),check(status in('missing','present','checked','submitted','accepted','rejected')),
 check(status='missing' or length(reference)>=3)
);
create table vppsone.school_official_results (
 id uuid primary key default gen_random_uuid(),cycle_id uuid not null references vppsone.school_board_cycles(id), student_id uuid not null,
 subject_code text not null,revision integer not null check(revision>0),supersedes uuid references vppsone.school_official_results(id),
 status text not null check(status in('pending','available','withheld','absent','cancelled')),raw_value text,raw_status text not null,
 appearance text not null check(appearance in('appeared','not_appeared','unknown')),source_reference text not null,
 verified_by uuid not null references vppsone.staff_profiles(id),verified_at timestamptz not null default now(),
 candidate_revision integer not null,cycle_revision integer not null,evidence_path text,evidence_sha256 text,evidence_type text,
 unique(cycle_id,student_id,subject_code,revision),unique(supersedes),
 check(length(source_reference) between 10 and 1000),check(length(raw_status) between 1 and 250),
 check(raw_value is null or length(raw_value) between 1 and 250),check(status not in('pending','withheld') or raw_value is null),check(status<>'available' or raw_value is not null),
 check((evidence_path is null and evidence_sha256 is null and evidence_type is null) or (evidence_path is not null and evidence_sha256 ~ '^[a-f0-9]{64}$' and evidence_type in('application/pdf','image/png','image/jpeg')))
);
create index school_official_results_cycle on vppsone.school_official_results(cycle_id,student_id,subject_code,revision desc);
create table vppsone.school_board_commands (
 id uuid primary key,cycle_id uuid not null references vppsone.school_board_cycles(id),actor_id uuid not null references vppsone.staff_profiles(id),
 kind text not null,request_hash text not null check(request_hash ~ '^[a-f0-9]{64}$'),payload jsonb not null,receipt jsonb not null,created_at timestamptz not null default now()
);
create index school_board_commands_cycle on vppsone.school_board_commands(cycle_id,created_at desc);

alter table vppsone.school_board_cycles enable row level security;
alter table vppsone.school_board_candidates enable row level security;
alter table vppsone.school_board_readiness enable row level security;
alter table vppsone.school_official_results enable row level security;
alter table vppsone.school_board_commands enable row level security;
create policy school_board_cycles_read on vppsone.school_board_cycles for select to authenticated using((select vppsone.staff_can('outcomes:view')) and (select vppsone.reads_every_class()) and vppsone.school_office_session_visible(session_label));
create policy school_board_candidates_read on vppsone.school_board_candidates for select to authenticated using(exists(select 1 from vppsone.school_board_cycles c where c.id=cycle_id));
create policy school_board_readiness_read on vppsone.school_board_readiness for select to authenticated using(exists(select 1 from vppsone.school_board_cycles c where c.id=cycle_id));
create policy school_official_results_read on vppsone.school_official_results for select to authenticated using(exists(select 1 from vppsone.school_board_cycles c where c.id=cycle_id));
create policy school_board_commands_read on vppsone.school_board_commands for select to authenticated using(exists(select 1 from vppsone.school_board_cycles c where c.id=cycle_id));
revoke all on vppsone.school_board_cycles,vppsone.school_board_candidates,vppsone.school_board_readiness,vppsone.school_official_results,vppsone.school_board_commands from public,anon,authenticated;
grant select on vppsone.school_board_cycles,vppsone.school_board_candidates,vppsone.school_board_readiness,vppsone.school_official_results,vppsone.school_board_commands to authenticated;
grant all on vppsone.school_board_cycles,vppsone.school_board_candidates,vppsone.school_board_readiness,vppsone.school_official_results,vppsone.school_board_commands to service_role;

create function vppsone.school_board_immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'board:immutable'; end; $$;
revoke all on function vppsone.school_board_immutable() from public,anon,authenticated;
create trigger school_official_results_immutable before update or delete on vppsone.school_official_results for each row execute function vppsone.school_board_immutable();
create trigger school_board_commands_immutable before update or delete on vppsone.school_board_commands for each row execute function vppsone.school_board_immutable();

create function vppsone.school_board_candidate_snapshot_immutable() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'board:snapshot_immutable'; end if;
 if old.student_snapshot is not null and new.student_snapshot is distinct from old.student_snapshot then raise exception 'board:snapshot_immutable'; end if;
 return new;
end; $$;
revoke all on function vppsone.school_board_candidate_snapshot_immutable() from public,anon,authenticated;
create trigger school_board_candidate_snapshot_immutable before update or delete on vppsone.school_board_candidates for each row execute function vppsone.school_board_candidate_snapshot_immutable();

-- The roster is still the canonical freshness gate. An empty roster needs its
-- current revision too, so departed registrations never reuse a stale snapshot fence.
create function vppsone.school_board_source(p_actor uuid,p_session text,p_permission text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare roster jsonb; source_revision text;
begin
 if p_permission not in('outcomes:view','outcomes:manage') then raise exception 'board:forbidden'; end if;
 roster:=vppsone.school_office_roster(p_actor,p_session,p_permission,p_confined);
 source_revision:=roster->0->>'sourceRevision';
 if source_revision is null then
  source_revision:=case when vppsone.is_test_session(p_session) then 'test:'||md5('') else (select last_revision::text from vppsone.fees_bridge_state where id) end;
 end if;
 if source_revision is null or source_revision='' then raise exception 'board:source_unavailable'; end if;
 return jsonb_build_object('roster',roster,'sourceRevision',source_revision);
end; $$;
revoke all on function vppsone.school_board_source(uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_board_source(uuid,text,text,boolean) to service_role;

-- Only service calls may write, after checking the real actor and current scope.
create function vppsone.school_board_command(p_actor uuid,p_command uuid,p_cycle uuid,p_kind text,p_payload jsonb,p_hash text,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare c vppsone.school_board_cycles; prior vppsone.school_board_commands; candidate vppsone.school_board_candidates;
 result_row vppsone.school_official_results; cfg jsonb; roster jsonb; source jsonb; pupil jsonb; snapshot jsonb; item jsonb; old_revision integer; receipt jsonb; student uuid; session_label text;
begin
 if p_kind not in('cycle','candidate','readiness','result') or p_hash !~ '^[a-f0-9]{64}$' or octet_length(p_payload::text)>50000 then raise exception 'board:invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-board-command:'||p_command::text,0));
 perform pg_advisory_xact_lock(hashtextextended('school-board-cycle:'||p_cycle::text,0));
 select * into c from vppsone.school_board_cycles where id=p_cycle for update;
 session_label:=case when p_kind='cycle' then p_payload->'config'->>'sessionLabel' else c.session_label end;
 if session_label is null or not vppsone.school_office_actor_allowed(p_actor,'outcomes:manage',session_label,p_confined) then raise exception 'board:forbidden'; end if;
 select * into prior from vppsone.school_board_commands where id=p_command;
 if found then
  if prior.actor_id<>p_actor or prior.cycle_id<>p_cycle or prior.kind<>p_kind or prior.request_hash<>p_hash then raise exception 'board:command_reused'; end if;
  return prior.receipt;
 end if;
 source:=vppsone.school_board_source(p_actor,session_label,'outcomes:manage',p_confined);
 roster:=source->'roster';
 if p_kind='cycle' then
  cfg:=p_payload->'config';
  if coalesce(c.revision,0) is distinct from (p_payload->>'expectedRevision')::integer or (c.id is not null and c.session_label<>session_label) then raise exception 'board:stale'; end if;
  if cfg is null or not (cfg ?& array['authority','attempt','classIds','subjects','requirements','sourceReference','responsible','verifiedOn','label','attemptLabel'])
   or jsonb_typeof(cfg->'classIds')<>'array' or jsonb_typeof(cfg->'subjects')<>'array' or jsonb_typeof(cfg->'requirements')<>'array' then raise exception 'board:invalid'; end if;
  if cfg->>'authority' not in('class5','class8','rbse10','rbse12') or cfg->>'attempt' not in('main','supplementary','improvement','corrected')
   or jsonb_array_length(cfg->'classIds') not between 1 and 100 or jsonb_array_length(cfg->'subjects') not between 1 and 80 or jsonb_array_length(cfg->'requirements')>40
   or length(cfg->>'sourceReference') not between 10 and 1000 or length(cfg->>'responsible') not between 2 and 120 or cfg->>'verifiedOn' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'board:invalid'; end if;
  if (select count(distinct s->>'code') from jsonb_array_elements(cfg->'subjects') s)<>jsonb_array_length(cfg->'subjects')
   or exists(select 1 from jsonb_array_elements(cfg->'subjects') s where coalesce(length(s->>'code'),0) not between 1 and 40 or coalesce(length(s->>'label'),0) not between 1 and 100)
   or (select count(distinct r->>'key') from jsonb_array_elements(cfg->'requirements') r)<>jsonb_array_length(cfg->'requirements') then raise exception 'board:invalid'; end if;
  for item in select value from jsonb_array_elements(cfg->'classIds') loop
   if not exists(select 1 from jsonb_array_elements(roster) r where r->>'classId'=item#>>'{}')
    and not (c.id is not null and c.config->'classIds'=cfg->'classIds') then raise exception 'board:wrong_class'; end if;
  end loop;
  if exists(select 1 from vppsone.school_board_candidates where cycle_id=p_cycle) and
    (c.config->'classIds'<>cfg->'classIds' or c.config->'subjects'<>cfg->'subjects' or c.config->>'authority'<>cfg->>'authority' or c.config->>'attempt'<>cfg->>'attempt' or c.config->>'attemptLabel'<>cfg->>'attemptLabel') then raise exception 'board:scope_frozen'; end if;
  insert into vppsone.school_board_cycles(id,session_label,config,revision,updated_by) values(p_cycle,session_label,cfg,1,p_actor)
   on conflict(id) do update set config=excluded.config,revision=school_board_cycles.revision+1,updated_by=p_actor,updated_at=now() returning to_jsonb(school_board_cycles) into receipt;
 else
  if c.id is null or c.revision is distinct from (p_payload->>'cycleRevision')::integer then raise exception 'board:stale'; end if;
  student:=(p_payload->>'studentId')::uuid;
  if source->>'sourceRevision' is distinct from p_payload->>'expectedSource' then raise exception 'board:source_changed'; end if;
  select * into candidate from vppsone.school_board_candidates where cycle_id=p_cycle and student_id=student for update;
  select value into pupil from jsonb_array_elements(roster) where value->>'studentId'=student::text;
  if p_kind in('readiness','result') and candidate.verified and candidate.student_snapshot is not null
   and candidate.student_snapshot->>'studentId'=student::text and candidate.student_snapshot->>'sessionLabel'=session_label
   and candidate.student_snapshot->>'identityVerified'='true' and candidate.student_snapshot->>'enrolmentStatus'='enrolled'
   and c.config->'classIds' ? (candidate.student_snapshot->>'classId') then pupil:=candidate.student_snapshot; end if;
  if pupil is null or not coalesce((pupil->>'identityVerified')::boolean,false) or not (c.config->'classIds' ? (pupil->>'classId')) then raise exception 'board:identity'; end if;
  if p_kind='candidate' then
   if coalesce(candidate.revision,0) is distinct from (p_payload->>'expectedRevision')::integer then raise exception 'board:stale'; end if;
   if jsonb_typeof(p_payload->'subjects') is distinct from 'array' then raise exception 'board:invalid'; end if;
   if jsonb_array_length(p_payload->'subjects') not between 1 and 80 or length(p_payload->>'sourceReference') not between 10 and 1000
    or (select count(distinct value) from jsonb_array_elements(p_payload->'subjects'))<>jsonb_array_length(p_payload->'subjects') then raise exception 'board:invalid'; end if;
   for item in select value from jsonb_array_elements(p_payload->'subjects') loop
    if not exists(select 1 from jsonb_array_elements(c.config->'subjects') s where s->>'code'=item#>>'{}') then raise exception 'board:subject'; end if;
   end loop;
   if exists(select 1 from vppsone.school_official_results where cycle_id=p_cycle and student_id=student) and
    (candidate.subjects<>p_payload->'subjects' or candidate.registration<>p_payload->>'registration' or candidate.roll<>p_payload->>'roll' or not (p_payload->>'verified')::boolean) then raise exception 'board:registration_frozen'; end if;
   snapshot:=case when (p_payload->>'verified')::boolean then jsonb_build_object('studentId',pupil->>'studentId','studentName',pupil->>'studentName','admissionNo',pupil->>'admissionNo','classId',pupil->>'classId','classLabel',pupil->>'classLabel','sessionLabel',session_label,'identityVerified',true,'enrolmentStatus','enrolled','sourceRevision',source->>'sourceRevision') else null end;
   insert into vppsone.school_board_candidates(cycle_id,student_id,registration,roll,subjects,verified,student_snapshot,source_reference,revision,verified_by)
    values(p_cycle,student,p_payload->>'registration',p_payload->>'roll',p_payload->'subjects',(p_payload->>'verified')::boolean,snapshot,p_payload->>'sourceReference',coalesce(candidate.revision,0)+1,p_actor)
    on conflict(cycle_id,student_id) do update set registration=excluded.registration,roll=excluded.roll,subjects=excluded.subjects,verified=excluded.verified,student_snapshot=coalesce(school_board_candidates.student_snapshot,excluded.student_snapshot),source_reference=excluded.source_reference,revision=excluded.revision,verified_by=p_actor,verified_at=now()
    returning to_jsonb(school_board_candidates) into receipt;
  elsif p_kind='readiness' then
   if not exists(select 1 from jsonb_array_elements(c.config->'requirements') r where r->>'key'=p_payload->>'key') then raise exception 'board:requirement'; end if;
   select revision into old_revision from vppsone.school_board_readiness where cycle_id=p_cycle and student_id=student and key=p_payload->>'key' for update;
   if coalesce(old_revision,0) is distinct from (p_payload->>'expectedRevision')::integer then raise exception 'board:stale'; end if;
   insert into vppsone.school_board_readiness(cycle_id,student_id,key,status,reference,revision,cycle_revision,updated_by)
    values(p_cycle,student,p_payload->>'key',p_payload->>'status',p_payload->>'reference',coalesce(old_revision,0)+1,c.revision,p_actor)
    on conflict(cycle_id,student_id,key) do update set status=excluded.status,reference=excluded.reference,revision=excluded.revision,cycle_revision=excluded.cycle_revision,updated_by=p_actor,updated_at=now()
    returning to_jsonb(school_board_readiness) into receipt;
  else
   select * into candidate from vppsone.school_board_candidates where cycle_id=p_cycle and student_id=student for update;
   if candidate.student_id is null or not candidate.verified or candidate.revision is distinct from (p_payload->>'candidateRevision')::integer or not(candidate.subjects ? (p_payload->>'subjectCode')) then raise exception 'board:registration'; end if;
   select * into result_row from vppsone.school_official_results where cycle_id=p_cycle and student_id=student and subject_code=p_payload->>'subjectCode' order by revision desc limit 1;
   if coalesce(result_row.revision,0) is distinct from (p_payload->>'expectedRevision')::integer then raise exception 'board:stale'; end if;
   if p_payload->'evidence' is not null and p_payload->'evidence'<>'null'::jsonb and (p_payload->'evidence'->>'path' not like 'board/'||p_cycle::text||'/'||p_command::text||'/%') then raise exception 'board:evidence_scope'; end if;
   insert into vppsone.school_official_results(cycle_id,student_id,subject_code,revision,supersedes,status,raw_value,raw_status,appearance,source_reference,verified_by,candidate_revision,cycle_revision,evidence_path,evidence_sha256,evidence_type)
    values(p_cycle,student,p_payload->>'subjectCode',coalesce(result_row.revision,0)+1,result_row.id,p_payload->>'status',p_payload->>'rawValue',p_payload->>'rawStatus',p_payload->>'appearance',p_payload->>'sourceReference',p_actor,candidate.revision,c.revision,p_payload->'evidence'->>'path',p_payload->'evidence'->>'hash',p_payload->'evidence'->>'type')
    returning to_jsonb(school_official_results) into receipt;
  end if;
 end if;
 insert into vppsone.school_board_commands(id,cycle_id,actor_id,kind,request_hash,payload,receipt) values(p_command,p_cycle,p_actor,p_kind,p_hash,p_payload,receipt);
 return receipt;
end; $$;
revoke all on function vppsone.school_board_command(uuid,uuid,uuid,text,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_board_command(uuid,uuid,uuid,text,jsonb,text,boolean) to service_role;
commit;

-- ======================================================== migrations/20261101171212_school_office_attention.sql
-- Attention remembers a failed attempt, not a copy of student identity.
-- Reads re-evaluate current certificate facts; GET never creates/resolves rows.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table vppsone.school_certificate_attention (
 student_id uuid not null,session_label text not null,
 blocker_codes text[] not null,last_seen_at timestamptz not null default now(),
 primary key(student_id,session_label),
 check(session_label ~ '^(TEST-)?[0-9]{4}-[0-9]{2}$'),
 check(cardinality(blocker_codes) between 1 and 21 and array_position(blocker_codes,null) is null),
 check(blocker_codes <@ array[
  'studentName:missing_field','studentName:invalid_date','admissionNo:missing_field','admissionNo:invalid_date',
  'classLabel:missing_field','classLabel:invalid_date','sessionLabel:missing_field','sessionLabel:invalid_date',
  'enrolledOn:missing_field','enrolledOn:invalid_date','leftOn:missing_field','leftOn:invalid_date',
  'dateOfBirth:missing_field','dateOfBirth:invalid_date','fatherName:missing_field','fatherName:invalid_date',
  'motherName:missing_field','motherName:invalid_date','identity:identity_unverified','template:template_inactive','source:source_unavailable']::text[])
);
create index school_certificate_attention_session on vppsone.school_certificate_attention(session_label,last_seen_at desc);
alter table vppsone.school_certificate_attention enable row level security;
create policy school_certificate_attention_read on vppsone.school_certificate_attention for select to authenticated
 using ((select vppsone.staff_can('certificates:view')) and (select vppsone.reads_every_class())
   and vppsone.school_office_session_visible(session_label));
revoke all on vppsone.school_certificate_attention from public,anon,authenticated;
grant select on vppsone.school_certificate_attention to authenticated;
grant all on vppsone.school_certificate_attention to service_role;

create function vppsone.school_certificate_attention_record(p_actor uuid,p_student uuid,p_session text,p_blockers text[],p_confined boolean default false)
returns void language plpgsql set search_path='' as $$
declare normalized text[];
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined)
  or not vppsone.school_office_actor_allowed(p_actor,'certificates:view',p_session,p_confined) then raise exception 'office:forbidden'; end if;
 select array_agg(distinct x order by x) into normalized from unnest(p_blockers) x;
 insert into vppsone.school_certificate_attention(student_id,session_label,blocker_codes)
 values(p_student,p_session,normalized)
 on conflict(student_id,session_label) do update set blocker_codes=excluded.blocker_codes,last_seen_at=now();
end;
$$;
revoke all on function vppsone.school_certificate_attention_record(uuid,uuid,text,text[],boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_attention_record(uuid,uuid,text,text[],boolean) to service_role;

create function vppsone.school_certificate_attention_clear(p_actor uuid,p_student uuid,p_session text,p_confined boolean default false)
returns void language plpgsql set search_path='' as $$
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined)
  or not vppsone.school_office_actor_allowed(p_actor,'certificates:view',p_session,p_confined) then raise exception 'office:forbidden'; end if;
 delete from vppsone.school_certificate_attention where student_id=p_student and session_label=p_session;
end;
$$;
revoke all on function vppsone.school_certificate_attention_clear(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_attention_clear(uuid,uuid,text,boolean) to service_role;

create index school_return_import_attention on vppsone.school_return_batches(session_label,(coalesce(parent_batch_id,id)),created_at desc,id desc) where direction='import';

-- Service-only, actor-checked, bounded projection. Per-student facts are joined
-- in one query, rather than one source/client request for every logged child.
create function vppsone.school_office_attention(p_actor uuid,p_session text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare certificates boolean; government boolean; t jsonb; candidates jsonb:='[]'; artifacts jsonb:='[]'; batches jsonb:='[]'; unavailable boolean:=false;
begin
 certificates:=vppsone.school_office_actor_allowed(p_actor,'certificates:view',p_session,p_confined);
 government:=vppsone.school_office_actor_allowed(p_actor,'government:view',p_session,p_confined);
 if p_session is null or p_session !~ '^(TEST-)?[0-9]{4}-[0-9]{2}$' or not(certificates or government) then raise exception 'office:forbidden'; end if;
 if certificates then
  select template||jsonb_build_object('active',active) into t from vppsone.school_certificate_templates order by version desc limit 1;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into artifacts from (
   select id,student_id,student_name,session_label,artifact_state from vppsone.school_certificate_issues
   where session_label=p_session and status in('prepared','issued') and artifact_state in('preparing','failed')
   order by issued_at desc,id desc limit 4
  ) x;
  if exists(select 1 from vppsone.school_certificate_attention where session_label=p_session) then
   if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled
    and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then
    unavailable:=true;
   else
    begin
     with logged as materialized (
      select student_id,blocker_codes,last_seen_at from vppsone.school_certificate_attention where session_label=p_session
      order by last_seen_at desc,student_id limit 1000
     ), records as (
      select l.*,e.id enrolment_id,e.class_id,e.enrolled_on,e.left_on,s.id source_id,s.full_name,s.admission_no,
       s.date_of_birth,s.father_name,s.mother_name,c.id source_class_id,concat_ws(' ',c.class_name,nullif(c.section,'')) class_label,
       coalesce(e.status::text='enrolled' and e.left_on is null and s.status::text='active' and s.class_id=e.class_id,false) current_record
      from logged l
      left join lateral(select * from vppsone.enrolments e where e.student_id=l.student_id and e.session_label=p_session order by e.created_at desc,e.id desc limit 1) e on true
      left join vppsone.fees_identity_students s on s.id=l.student_id and exists(
       select 1 from vppsone.fees_identity_classes scope where scope.id=s.class_id
        and vppsone.is_test_session(scope.session_label)=vppsone.is_test_session(p_session))
      left join vppsone.fees_identity_classes c on c.id=e.class_id and c.session_label=p_session
     ), facts as (
      select r.*,
       coalesce((t->'requiredFields')::text,'')||' '||
        case when t->>'language' in('en','both') then coalesce(t->>(case when current_record then 'bodyEn' else 'historicalBodyEn' end),'') else '' end||' '||
        case when t->>'language' in('hi','both') then coalesce(t->>(case when current_record then 'bodyHi' else 'historicalBodyHi' end),'') else '' end optional_text
      from records r
     ), snapshots as (
      select student_id,blocker_codes,last_seen_at,optional_text,
       jsonb_build_object('studentId',student_id,'enrolmentId',coalesce(enrolment_id,'00000000-0000-0000-0000-000000000000'::uuid),
       'classId',coalesce(class_id,'00000000-0000-0000-0000-000000000000'::uuid),'studentName',coalesce(full_name,''),'admissionNo',coalesce(admission_no,''),
       'classLabel',class_label,'sessionLabel',p_session,'status',case when current_record then 'current' else 'historical' end,
       'enrolledOn',enrolled_on,'leftOn',left_on,'dateOfBirth',case when position('dateOfBirth' in optional_text)>0 then date_of_birth end,
       'fatherName',case when position('fatherName' in optional_text)>0 then father_name end,'motherName',case when position('motherName' in optional_text)>0 then mother_name end,
       'identityVerified',enrolment_id is not null and source_id is not null and source_class_id is not null
        and (current_record or (enrolled_on is not null and left_on is not null and left_on>=enrolled_on)),
       'sourceCurrent',source_id is not null and source_class_id is not null,'sourceRevision','attention-current','checkedAt',clock_timestamp()) facts
      from facts
     )
     select coalesce(jsonb_agg(jsonb_build_object('student_id',student_id,'blocker_codes',blocker_codes,'facts',facts)),'[]'::jsonb)
     into candidates from (
      -- Skip resolved logs before limiting the response, so old corrected
      -- records cannot crowd an unresolved student out of the card.
      select * from snapshots f where f.facts->>'sourceCurrent'='false' or exists(
       select 1 from unnest(f.blocker_codes) code where
        (code='identity:identity_unverified' and f.facts->>'identityVerified'='false')
        or (code='template:template_inactive' and t->>'active'='false')
        or (split_part(code,':',2)='missing_field'
         and ((t->'requiredFields') ? split_part(code,':',1) or position('{'||split_part(code,':',1)||'}' in f.optional_text)>0)
         and nullif(btrim(f.facts->>split_part(code,':',1)),'') is null)
      ) order by last_seen_at desc,student_id limit 8
     ) current_candidates;
    exception when others then unavailable:=true; candidates:='[]'; end;
   end if;
  end if;
 end if;
 if government then
  -- State filtering deliberately happens AFTER newest-per-parent selection.
  -- An older conflicted preview cannot survive a newer applied import.
  with latest_imports as materialized (
   select distinct on(coalesce(parent_batch_id,id)) id,parent_batch_id,direction,state,created_at,session_label,payload
   from vppsone.school_return_batches where session_label=p_session and direction='import'
   order by coalesce(parent_batch_id,id),created_at desc,id desc
  ), actionable as (
   select id,parent_batch_id,direction,state,created_at,session_label,
    exists(select 1 from jsonb_array_elements(coalesce(payload->'preview','[]'::jsonb)) r where r->>'state' in('conflict','unmatched')) has_conflicts
   from latest_imports where state in('preparing','staged')
   union all
   select id,parent_batch_id,direction,state,created_at,session_label,false from vppsone.school_return_batches
   where session_label=p_session and direction='export' and state='preparing'
  )
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into batches from (
   select * from actionable where state='preparing' or has_conflicts order by created_at desc,id desc limit 8
  ) x;
 end if;
 return jsonb_build_object('template',t,'certificate_candidates',candidates,'certificate_artifacts',artifacts,
  'return_batches',batches,'certificate_unavailable',unavailable);
end;
$$;
revoke all on function vppsone.school_office_attention(uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_office_attention(uuid,text,boolean) to service_role;

commit;

-- ======================================================== migrations/20261103031956_school_office_certificate_kinds.sql
-- School Office, second pass: several school document kinds, each with its own
-- approved template, series and reprint-first rule; a verification code frozen
-- into every new issue; and a minimal public check. No financial mutation.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Kinds the school issues itself. A TC is a document kind here; changing a
-- student's status to left stays with the existing leaving workflow.
alter table vppsone.school_certificate_templates
  add column kind text not null default 'study' check (kind in ('study','character','dob','tc'));
alter table vppsone.school_certificate_templates
  add constraint school_certificate_template_kind_matches check (coalesce(template->>'kind','study')=kind);
drop index vppsone.school_certificate_template_active;
create unique index school_certificate_template_active_kind on vppsone.school_certificate_templates(kind) where active;

alter table vppsone.school_certificate_issues
  add column kind text not null default 'study' check (kind in ('study','character','dob','tc')),
  add column verify_code text generated always as (snapshot->>'verifyCode') stored;
alter table vppsone.school_certificate_issues
  add constraint school_certificate_issue_kind_matches check (coalesce(snapshot->>'kind','study')=kind),
  add constraint school_certificate_verify_code_shape check (verify_code is null or verify_code ~ '^[a-f0-9]{16}$');
create unique index school_certificate_verify_code on vppsone.school_certificate_issues(verify_code) where verify_code is not null;
create index school_certificate_student_kind on vppsone.school_certificate_issues(student_id,session_label,kind,issued_at desc);
create index school_certificate_tray on vppsone.school_certificate_issues(session_label,issued_at desc) where status='prepared' and artifact_state='ready';

create or replace function vppsone.school_certificate_immutable()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'certificate:immutable'; end if;
 if new.snapshot is distinct from old.snapshot or new.serial<>old.serial or new.student_id<>old.student_id
   or new.session_label<>old.session_label or new.enrolment_id<>old.enrolment_id or new.template_version<>old.template_version
   or new.issued_at<>old.issued_at or new.issued_by<>old.issued_by or new.supersedes is distinct from old.supersedes
   or new.reason is distinct from old.reason or new.kind<>old.kind then raise exception 'certificate:immutable'; end if;
 if old.artifact_state='ready' and (new.artifact_state<>old.artifact_state or new.storage_path is distinct from old.storage_path
    or new.artifact_sha256 is distinct from old.artifact_sha256 or new.artifact_bytes is distinct from old.artifact_bytes) then
   raise exception 'certificate:artifact_immutable'; end if;
 if new.status<>old.status and not (old.status='prepared' and new.status in('issued','superseded','cancelled')
   or old.status='issued' and new.status in('superseded','cancelled')) then raise exception 'certificate:invalid_transition'; end if;
 return new;
end;
$$;

-- Default wording for the three new kinds, active from the start so the office
-- can use them; every later edit is a new version under the existing manage rule.
insert into vppsone.school_certificate_templates(version,kind,active,approved_via,template)
select v.version, v.kind, true, 'default wording, School Office second pass 2026-11-03', v.template||jsonb_build_object('version',v.version,'kind',v.kind)
from (values
 ((select coalesce(max(version),0)+1 from vppsone.school_certificate_templates),'character',jsonb_build_object(
   'active',true,'titleEn','Character Certificate','titleHi','चरित्र प्रमाण पत्र',
   'bodyEn','This is to certify that {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, has been a student of this school in Class {classLabel} during academic session {sessionLabel}. To the best of my knowledge {heShe} bears {conduct} moral character. I wish {himHer} every success in life.',
   'bodyHi','प्रमाणित किया जाता है कि {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, शैक्षणिक सत्र {sessionLabel} में इस विद्यालय की कक्षा {classLabel} के विद्यार्थी रहे हैं। मेरी जानकारी के अनुसार इनका चरित्र {conduct} है। इनके उज्ज्वल भविष्य के लिए शुभकामनाएँ।',
   'historicalBodyEn','This is to certify that {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, was a student of this school in Class {classLabel} during academic session {sessionLabel}. To the best of my knowledge {heShe} bears {conduct} moral character. I wish {himHer} every success in life.',
   'historicalBodyHi','प्रमाणित किया जाता है कि {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, शैक्षणिक सत्र {sessionLabel} में इस विद्यालय की कक्षा {classLabel} के विद्यार्थी रहे हैं। मेरी जानकारी के अनुसार इनका चरित्र {conduct} है। इनके उज्ज्वल भविष्य के लिए शुभकामनाएँ।',
   'requiredFields',jsonb_build_array('studentName','fatherName','admissionNo','classLabel','sessionLabel'),
   'detailRows',jsonb_build_array(),'language','en','prefix','VPPS/CC','signaturePolicy','manual')),
 ((select coalesce(max(version),0)+2 from vppsone.school_certificate_templates),'dob',jsonb_build_object(
   'active',true,'titleEn','Date of Birth Certificate','titleHi','जन्म तिथि प्रमाण पत्र',
   'bodyEn','This is to certify that, as recorded in the Scholar''s Register of this school, the date of birth of {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, is {dateOfBirth} ({dateOfBirthWords}).',
   'bodyHi','प्रमाणित किया जाता है कि इस विद्यालय की छात्र पंजिका (एसआर) के अनुसार {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, की जन्म तिथि {dateOfBirth} ({dateOfBirthWords}) है।',
   'historicalBodyEn','This is to certify that, as recorded in the Scholar''s Register of this school, the date of birth of {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, is {dateOfBirth} ({dateOfBirthWords}).',
   'historicalBodyHi','प्रमाणित किया जाता है कि इस विद्यालय की छात्र पंजिका (एसआर) के अनुसार {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, की जन्म तिथि {dateOfBirth} ({dateOfBirthWords}) है।',
   'requiredFields',jsonb_build_array('studentName','fatherName','admissionNo','dateOfBirth'),
   'detailRows',jsonb_build_array(),'language','en','prefix','VPPS/DOB','signaturePolicy','manual')),
 ((select coalesce(max(version),0)+3 from vppsone.school_certificate_templates),'tc',jsonb_build_object(
   'active',true,'titleEn','Transfer Certificate','titleHi','स्थानांतरण प्रमाण पत्र',
   'bodyEn','Certified that the particulars given below are as recorded in the Scholar''s Register of {schoolName}.',
   'bodyHi','प्रमाणित किया जाता है कि नीचे दिया गया विवरण {schoolName} की छात्र पंजिका के अनुसार है।',
   'historicalBodyEn','Certified that the particulars given below are as recorded in the Scholar''s Register of {schoolName}.',
   'historicalBodyHi','प्रमाणित किया जाता है कि नीचे दिया गया विवरण {schoolName} की छात्र पंजिका के अनुसार है।',
   'requiredFields',jsonb_build_array('studentName','fatherName','admissionNo','dateOfBirth','classLabel','leftOn'),
   'detailRows',jsonb_build_array('studentName','fatherName','motherName','dateOfBirth','dateOfBirthWords','admissionNo','admittedOn','classLabel','sessionLabel','lastResult','leftOn','reasonForLeaving','conduct','remarks'),
   'language','en','prefix','VPPS/TC','signaturePolicy','manual'))
) as v(version,kind,template);

-- Facts for one kind. Optional personal facts are returned only when that
-- kind's active template mentions them anywhere (body, detail rows or required).
create function vppsone.school_certificate_facts_v2(p_actor uuid,p_student uuid,p_session text,p_kind text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare e vppsone.enrolments; s jsonb; c jsonb; t jsonb; current_record boolean; verified boolean; mentioned text;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in ('study','character','dob','tc') then raise exception 'certificate:invalid_kind'; end if;
 if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then raise exception 'certificate:source_unavailable'; end if;
 select * into e from vppsone.enrolments where student_id=p_student and session_label=p_session order by created_at desc limit 1;
 select to_jsonb(x) into s from vppsone.fees_identity_students x where x.id=p_student limit 1;
 select to_jsonb(x) into c from vppsone.fees_identity_classes x where x.id=e.class_id and x.session_label=p_session;
 select template into t from vppsone.school_certificate_templates where active and kind=p_kind;
 current_record:=coalesce(e.status::text='enrolled' and e.left_on is null and s->>'status'='active' and (s->>'class_id')::uuid=e.class_id,false);
 verified:=e.id is not null and s is not null and c is not null and (current_record or (e.enrolled_on is not null and e.left_on is not null and e.left_on>=e.enrolled_on));
 mentioned:=coalesce(t::text,'');
 return jsonb_build_object('studentId',p_student,'enrolmentId',coalesce(e.id,'00000000-0000-0000-0000-000000000000'::uuid),
   'classId',coalesce(e.class_id,'00000000-0000-0000-0000-000000000000'::uuid),'studentName',coalesce(s->>'full_name',''),
   'admissionNo',coalesce(s->>'admission_no',''),'classLabel',concat_ws(' ',c->>'class_name',nullif(c->>'section','')),
   'sessionLabel',p_session,'status',case when current_record then 'current' else 'historical' end,
   'enrolledOn',e.enrolled_on,'leftOn',e.left_on,
   'admittedOn',case when position('admittedOn' in mentioned)>0 then s->>'joined_on' end,
   'dateOfBirth',case when position('dateOfBirth' in mentioned)>0 then s->>'date_of_birth' end,
   'fatherName',case when position('fatherName' in mentioned)>0 then s->>'father_name' end,
   'motherName',case when position('motherName' in mentioned)>0 then s->>'mother_name' end,
   'gender',case when position('{sonDaughter}' in mentioned)+position('{heShe}' in mentioned)+position('{himHer}' in mentioned)+position('{hisHer}' in mentioned)+position('{putraPutri}' in mentioned)>0 then s->>'gender' end,
   'identityVerified',verified,'sourceCurrent',s is not null and c is not null,
   'sourceRevision',case when vppsone.is_test_session(p_session) then coalesce(s->>'updated_at','test') else coalesce((select last_revision::text from vppsone.fees_bridge_state where id),'unknown') end,
   'checkedAt',clock_timestamp());
end;
$$;
revoke all on function vppsone.school_certificate_facts_v2(uuid,uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_facts_v2(uuid,uuid,text,text,boolean) to service_role;

create function vppsone.school_certificate_current_v2(p_actor uuid,p_student uuid,p_session text,p_kind text,p_command uuid,p_request_hash text,p_confined boolean default false,p_issue uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_certificate_commands; issue vppsone.school_certificate_issues;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'certificate:invalid_command'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-command:'||p_command::text,0));
 select * into prior from vppsone.school_certificate_commands where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'certificate:command_reused'; end if;
   select * into issue from vppsone.school_certificate_issues where id=prior.issue_id;
   if issue.student_id<>p_student or issue.session_label<>p_session or issue.kind<>p_kind then raise exception 'certificate:command_reused'; end if;
   return to_jsonb(issue);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-student:'||p_student::text||':'||p_session,0));
 select * into issue from vppsone.school_certificate_issues where student_id=p_student and session_label=p_session and kind=p_kind
   and status in('prepared','issued') and (p_issue is null or id=p_issue) order by issued_at desc limit 1;
 if not found then
   if p_issue is not null then raise exception 'certificate:stale_issue'; end if;
   return null;
 end if;
 insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
 return to_jsonb(issue);
end;
$$;
revoke all on function vppsone.school_certificate_current_v2(uuid,uuid,text,text,uuid,text,boolean,uuid) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_current_v2(uuid,uuid,text,text,uuid,text,boolean,uuid) to service_role;

create function vppsone.school_certificate_reserve_v2(p_actor uuid,p_student uuid,p_session text,p_kind text,p_command uuid,p_request_hash text,
 p_expected_facts jsonb,p_school jsonb,p_expected_template integer,p_purpose text default null,p_extras jsonb default '{}'::jsonb,
 p_new boolean default false,p_supersedes uuid default null,p_reason text default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_certificate_commands; issue vppsone.school_certificate_issues; t vppsone.school_certificate_templates;
 facts jsonb; serial_number bigint; serial_text text; instant timestamptz:=clock_timestamp(); field text; extra record; code text;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in ('study','character','dob','tc') then raise exception 'certificate:invalid_kind'; end if;
 if p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'certificate:invalid_command'; end if;
 if p_purpose is not null and (length(btrim(p_purpose))<2 or length(p_purpose)>80 or p_purpose ~ '[{}<>]') then raise exception 'certificate:invalid_purpose'; end if;
 if jsonb_typeof(coalesce(p_extras,'{}'::jsonb))<>'object' then raise exception 'certificate:invalid_extras'; end if;
 for extra in select key, value from jsonb_each(coalesce(p_extras,'{}'::jsonb)) loop
   if extra.key not in ('reasonForLeaving','conduct','lastResult','remarks') or jsonb_typeof(extra.value)<>'string'
     or length(extra.value#>>'{}')>200 or (extra.value#>>'{}') ~ '[{}<>]' then raise exception 'certificate:invalid_extras'; end if;
 end loop;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-command:'||p_command::text,0));
 select * into prior from vppsone.school_certificate_commands where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'certificate:command_reused'; end if;
   select * into issue from vppsone.school_certificate_issues where id=prior.issue_id;
   return jsonb_build_object('issue',to_jsonb(issue),'existing',true);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-student:'||p_student::text||':'||p_session,0));
 if not p_new and p_supersedes is null then
   select * into issue from vppsone.school_certificate_issues where student_id=p_student and session_label=p_session and kind=p_kind
     and status in('prepared','issued') order by issued_at desc limit 1;
   if found then
     insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
     return jsonb_build_object('issue',to_jsonb(issue),'existing',true);
   end if;
 end if;
 select * into t from vppsone.school_certificate_templates where active and kind=p_kind for share;
 if not found then raise exception 'certificate:template_inactive'; end if;
 if t.version<>p_expected_template then raise exception 'certificate:template_changed'; end if;
 facts:=vppsone.school_certificate_facts_v2(p_actor,p_student,p_session,p_kind,p_confined);
 if facts->>'identityVerified'<>'true' or facts->>'sourceCurrent'<>'true' then raise exception 'certificate:identity_unverified'; end if;
 if (facts-'checkedAt') is distinct from (p_expected_facts-'checkedAt') then raise exception 'certificate:source_changed'; end if;
 if p_kind='tc' and facts->>'status'<>'historical' then raise exception 'certificate:not_left'; end if;
 for field in select jsonb_array_elements_text(t.template->'requiredFields') loop
   if nullif(btrim(facts->>field),'') is null then raise exception 'certificate:missing_field:%',field; end if;
 end loop;
 if p_supersedes is not null then
   if not vppsone.school_office_actor_allowed(p_actor,'certificates:manage',p_session,p_confined) or length(btrim(coalesce(p_reason,'')))<3 then raise exception 'certificate:correction_forbidden'; end if;
   select * into issue from vppsone.school_certificate_issues where id=p_supersedes and student_id=p_student and session_label=p_session and kind=p_kind for update;
   if not found or issue.status not in('prepared','issued') then raise exception 'certificate:stale_issue'; end if;
 end if;
 if p_school->>'name' is null or length(p_school->>'name')<2 then raise exception 'certificate:school_missing'; end if;
 insert into vppsone.school_certificate_series(prefix,session_label,is_test,last_number)
   values(t.template->>'prefix',p_session,vppsone.is_test_session(p_session),1)
   on conflict(prefix,session_label,is_test) do update set last_number=vppsone.school_certificate_series.last_number+1
   returning last_number into serial_number;
 serial_text:=case when vppsone.is_test_session(p_session) then 'TEST/' else '' end||(t.template->>'prefix');
 serial_text:=serial_text||'/'||p_session||'/'||lpad(serial_number::text,greatest(4,length(serial_number::text)),'0');
 code:=substr(md5(gen_random_uuid()::text||clock_timestamp()::text),1,16);
 insert into vppsone.school_certificate_issues(student_id,session_label,enrolment_id,template_version,serial,snapshot,issued_by,issued_at,supersedes,reason,kind)
   values(p_student,p_session,(facts->>'enrolmentId')::uuid,t.version,serial_text,
    jsonb_build_object('serial',serial_text,'issuedAt',instant,'issuedOn',(instant at time zone 'Asia/Kolkata')::date,
      'isTest',vppsone.is_test_session(p_session),'school',p_school,'facts',facts,'template',t.template,
      'kind',p_kind,'purpose',nullif(btrim(coalesce(p_purpose,'')),''),'extras',coalesce(p_extras,'{}'::jsonb),'verifyCode',code),
    p_actor,instant,p_supersedes,p_reason,p_kind)
   returning * into issue;
 insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
 insert into vppsone.school_certificate_events(issue_id,actor_id,kind) values(issue.id,p_actor,'prepared');
 return jsonb_build_object('issue',to_jsonb(issue),'existing',false);
end;
$$;
revoke all on function vppsone.school_certificate_reserve_v2(uuid,uuid,text,text,uuid,text,jsonb,jsonb,integer,text,jsonb,boolean,uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_reserve_v2(uuid,uuid,text,text,uuid,text,jsonb,jsonb,integer,text,jsonb,boolean,uuid,text,boolean) to service_role;

create function vppsone.school_certificate_save_template_v2(p_actor uuid,p_kind text,p_template jsonb,p_expected_version integer,p_confined boolean default false)
returns integer language plpgsql set search_path='' as $$
declare current_version integer; new_version integer;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:manage',null,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in ('study','character','dob','tc') then raise exception 'certificate:invalid_kind'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-template',0));
 select coalesce(max(version),0) into current_version from vppsone.school_certificate_templates where kind=p_kind;
 if current_version<>p_expected_version then raise exception 'certificate:template_changed'; end if;
 if p_template->>'signaturePolicy'<>'manual' or p_template->>'prefix' !~ '^[A-Z0-9][A-Z0-9/-]{0,39}$' then raise exception 'certificate:invalid_template'; end if;
 if exists(select 1 from vppsone.school_certificate_templates where kind<>p_kind and template->>'prefix'=p_template->>'prefix') then raise exception 'certificate:prefix_in_use'; end if;
 select coalesce(max(version),0)+1 into new_version from vppsone.school_certificate_templates;
 update vppsone.school_certificate_templates set active=false where active and kind=p_kind;
 insert into vppsone.school_certificate_templates(version,kind,active,template,approved_by,approved_via)
 values(new_version,p_kind,coalesce((p_template->>'active')::boolean,false),p_template||jsonb_build_object('version',new_version,'kind',p_kind),p_actor,'authorized template configuration');
 return new_version;
end;
$$;
revoke all on function vppsone.school_certificate_save_template_v2(uuid,text,jsonb,integer,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_save_template_v2(uuid,text,jsonb,integer,boolean) to service_role;

-- The v1 entry points keep working for a deployment that has not caught up:
-- they now mean the study kind only, so they cannot read another kind's template.
create or replace function vppsone.school_certificate_facts(p_actor uuid,p_student uuid,p_session text,p_confined boolean default false)
returns jsonb language sql stable set search_path='' as $$
 select vppsone.school_certificate_facts_v2(p_actor,p_student,p_session,'study',p_confined);
$$;
create or replace function vppsone.school_certificate_current(p_actor uuid,p_student uuid,p_session text,p_command uuid,p_request_hash text,p_confined boolean default false,p_issue uuid default null)
returns jsonb language sql set search_path='' as $$
 select vppsone.school_certificate_current_v2(p_actor,p_student,p_session,'study',p_command,p_request_hash,p_confined,p_issue);
$$;
create or replace function vppsone.school_certificate_reserve(p_actor uuid,p_student uuid,p_session text,p_command uuid,p_request_hash text,
 p_expected_facts jsonb,p_school jsonb,p_expected_template integer,p_new boolean default false,p_supersedes uuid default null,p_reason text default null,p_confined boolean default false)
returns jsonb language sql set search_path='' as $$
 select vppsone.school_certificate_reserve_v2(p_actor,p_student,p_session,'study',p_command,p_request_hash,p_expected_facts,p_school,p_expected_template,null,'{}'::jsonb,p_new,p_supersedes,p_reason,p_confined);
$$;
create or replace function vppsone.school_certificate_save_template(p_actor uuid,p_template jsonb,p_expected_version integer,p_confined boolean default false)
returns integer language sql set search_path='' as $$
 select vppsone.school_certificate_save_template_v2(p_actor,'study',p_template,p_expected_version,p_confined);
$$;

revoke all on function vppsone.school_certificate_facts(uuid,uuid,text,boolean) from public,anon,authenticated;
revoke all on function vppsone.school_certificate_current(uuid,uuid,text,uuid,text,boolean,uuid) from public,anon,authenticated;
revoke all on function vppsone.school_certificate_reserve(uuid,uuid,text,uuid,text,jsonb,jsonb,integer,boolean,uuid,text,boolean) from public,anon,authenticated;
revoke all on function vppsone.school_certificate_save_template(uuid,jsonb,integer,boolean) from public,anon,authenticated;

-- Class batches: the enrolled roster an issuer may prepare documents for.
-- Names, SR numbers and classes only; the issue command rereads every fact.
create function vppsone.school_certificate_roster(p_actor uuid,p_session text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then raise exception 'certificate:source_unavailable'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('studentId',s.id,'studentName',s.full_name,'admissionNo',s.admission_no,'classId',c.id,
     'classLabel',concat_ws(' ',c.class_name,nullif(c.section,''))) order by c.class_name,c.section,s.full_name)
   from vppsone.enrolments e
   join vppsone.fees_identity_students s on s.id=e.student_id
   join vppsone.fees_identity_classes c on c.id=e.class_id and c.session_label=p_session
   where e.session_label=p_session and e.status::text='enrolled' and e.left_on is null),'[]'::jsonb);
end;
$$;
revoke all on function vppsone.school_certificate_roster(uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_roster(uuid,text,boolean) to service_role;

-- The attention card follows study certificates; it reads the study template,
-- not whichever kind was saved last.
create or replace function vppsone.school_office_attention(p_actor uuid,p_session text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare certificates boolean; government boolean; t jsonb; candidates jsonb:='[]'; artifacts jsonb:='[]'; batches jsonb:='[]'; unavailable boolean:=false;
begin
 certificates:=vppsone.school_office_actor_allowed(p_actor,'certificates:view',p_session,p_confined);
 government:=vppsone.school_office_actor_allowed(p_actor,'government:view',p_session,p_confined);
 if p_session is null or p_session !~ '^(TEST-)?[0-9]{4}-[0-9]{2}$' or not(certificates or government) then raise exception 'office:forbidden'; end if;
 if certificates then
  select template||jsonb_build_object('active',active) into t from vppsone.school_certificate_templates where kind='study' order by version desc limit 1;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into artifacts from (
   select id,student_id,student_name,session_label,artifact_state from vppsone.school_certificate_issues
   where session_label=p_session and status in('prepared','issued') and artifact_state in('preparing','failed')
   order by issued_at desc,id desc limit 4
  ) x;
  if exists(select 1 from vppsone.school_certificate_attention where session_label=p_session) then
   if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled
    and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then
    unavailable:=true;
   else
    begin
     with logged as materialized (
      select student_id,blocker_codes,last_seen_at from vppsone.school_certificate_attention where session_label=p_session
      order by last_seen_at desc,student_id limit 1000
     ), records as (
      select l.*,e.id enrolment_id,e.class_id,e.enrolled_on,e.left_on,s.id source_id,s.full_name,s.admission_no,
       s.date_of_birth,s.father_name,s.mother_name,c.id source_class_id,concat_ws(' ',c.class_name,nullif(c.section,'')) class_label,
       coalesce(e.status::text='enrolled' and e.left_on is null and s.status::text='active' and s.class_id=e.class_id,false) current_record
      from logged l
      left join lateral(select * from vppsone.enrolments e where e.student_id=l.student_id and e.session_label=p_session order by e.created_at desc,e.id desc limit 1) e on true
      left join vppsone.fees_identity_students s on s.id=l.student_id and exists(
       select 1 from vppsone.fees_identity_classes scope where scope.id=s.class_id
        and vppsone.is_test_session(scope.session_label)=vppsone.is_test_session(p_session))
      left join vppsone.fees_identity_classes c on c.id=e.class_id and c.session_label=p_session
     ), facts as (
      select r.*,
       coalesce((t->'requiredFields')::text,'')||' '||
        case when t->>'language' in('en','both') then coalesce(t->>(case when current_record then 'bodyEn' else 'historicalBodyEn' end),'') else '' end||' '||
        case when t->>'language' in('hi','both') then coalesce(t->>(case when current_record then 'bodyHi' else 'historicalBodyHi' end),'') else '' end optional_text
      from records r
     ), snapshots as (
      select student_id,blocker_codes,last_seen_at,optional_text,
       jsonb_build_object('studentId',student_id,'enrolmentId',coalesce(enrolment_id,'00000000-0000-0000-0000-000000000000'::uuid),
       'classId',coalesce(class_id,'00000000-0000-0000-0000-000000000000'::uuid),'studentName',coalesce(full_name,''),'admissionNo',coalesce(admission_no,''),
       'classLabel',class_label,'sessionLabel',p_session,'status',case when current_record then 'current' else 'historical' end,
       'enrolledOn',enrolled_on,'leftOn',left_on,'dateOfBirth',case when position('dateOfBirth' in optional_text)>0 then date_of_birth end,
       'fatherName',case when position('fatherName' in optional_text)>0 then father_name end,'motherName',case when position('motherName' in optional_text)>0 then mother_name end,
       'identityVerified',enrolment_id is not null and source_id is not null and source_class_id is not null
        and (current_record or (enrolled_on is not null and left_on is not null and left_on>=enrolled_on)),
       'sourceCurrent',source_id is not null and source_class_id is not null,'sourceRevision','attention-current','checkedAt',clock_timestamp()) facts
      from facts
     )
     select coalesce(jsonb_agg(jsonb_build_object('student_id',student_id,'blocker_codes',blocker_codes,'facts',facts)),'[]'::jsonb)
     into candidates from (
      -- Skip resolved logs before limiting the response, so old corrected
      -- records cannot crowd an unresolved student out of the card.
      select * from snapshots f where f.facts->>'sourceCurrent'='false' or exists(
       select 1 from unnest(f.blocker_codes) code where
        (code='identity:identity_unverified' and f.facts->>'identityVerified'='false')
        or (code='template:template_inactive' and t->>'active'='false')
        or (split_part(code,':',2)='missing_field'
         and ((t->'requiredFields') ? split_part(code,':',1) or position('{'||split_part(code,':',1)||'}' in f.optional_text)>0)
         and nullif(btrim(f.facts->>split_part(code,':',1)),'') is null)
      ) order by last_seen_at desc,student_id limit 8
     ) current_candidates;
    exception when others then unavailable:=true; candidates:='[]'; end;
   end if;
  end if;
 end if;
 if government then
  -- State filtering deliberately happens AFTER newest-per-parent selection.
  -- An older conflicted preview cannot survive a newer applied import.
  with latest_imports as materialized (
   select distinct on(coalesce(parent_batch_id,id)) id,parent_batch_id,direction,state,created_at,session_label,payload
   from vppsone.school_return_batches where session_label=p_session and direction='import'
   order by coalesce(parent_batch_id,id),created_at desc,id desc
  ), actionable as (
   select id,parent_batch_id,direction,state,created_at,session_label,
    exists(select 1 from jsonb_array_elements(coalesce(payload->'preview','[]'::jsonb)) r where r->>'state' in('conflict','unmatched')) has_conflicts
   from latest_imports where state in('preparing','staged')
   union all
   select id,parent_batch_id,direction,state,created_at,session_label,false from vppsone.school_return_batches
   where session_label=p_session and direction='export' and state='preparing'
  )
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into batches from (
   select * from actionable where state='preparing' or has_conflicts order by created_at desc,id desc limit 8
  ) x;
 end if;
 return jsonb_build_object('template',t,'certificate_candidates',candidates,'certificate_artifacts',artifacts,
  'return_batches',batches,'certificate_unavailable',unavailable);
end;
$$;

-- Public check behind the QR: status, number, kind, date and the name for the
-- server to mask. No class, parentage, DOB or anything else from the profile.
-- TEST issues answer as unknown so a test document cannot be vouched for.
create function vppsone.school_certificate_verify(p_code text)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when p_code !~ '^[a-f0-9]{16}$' then null else (
   select jsonb_build_object('status',i.status,'serial',i.serial,'kind',i.kind,'issuedOn',i.snapshot->>'issuedOn',
     'studentName',i.student_name,'school',i.snapshot->'school'->>'name','supersededBy',
     (select n.serial from vppsone.school_certificate_issues n where n.supersedes=i.id and n.status in('prepared','issued') limit 1))
   from vppsone.school_certificate_issues i where i.verify_code=p_code and i.artifact_state='ready' and not coalesce((i.snapshot->>'isTest')::boolean,false)) end;
$$;
revoke all on function vppsone.school_certificate_verify(text) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_verify(text) to service_role;

notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261103032018_returns_copilot_rows.sql
-- Manual entry assistant ("Portal Copilot") row marks for prepared reference sheets.
-- A mark is a person's own record that they typed a row into the official portal
-- (or found a mismatch there). It is human submission evidence only: never
-- portal acceptance, never a change to any student, fee or source record.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table vppsone.school_return_copilot_rows (
 batch_id uuid not null references vppsone.school_return_batches(id),
 row_key uuid not null,
 state text not null check(state in('entered','mismatch')),
 note text check(note is null or length(btrim(note)) between 1 and 500),
 actor_id uuid not null references vppsone.staff_profiles(id),
 updated_at timestamptz not null default now(),
 primary key(batch_id,row_key),
 check(state<>'mismatch' or note is not null)
);
alter table vppsone.school_return_copilot_rows enable row level security;
-- Visible exactly when the batch is (its own policy checks permission, scope and session).
create policy school_return_copilot_rows_read on vppsone.school_return_copilot_rows for select to authenticated
 using(exists(select 1 from vppsone.school_return_batches b where b.id=batch_id));
revoke all on vppsone.school_return_copilot_rows from public,anon,authenticated;
grant select on vppsone.school_return_copilot_rows to authenticated;
grant all on vppsone.school_return_copilot_rows to service_role;

-- Called by the server only, after its permission, view-as and session checks.
-- Rechecks the actor, the TEST fence and that the row belongs to this prepared
-- manual reference batch. Idempotent: the same mark twice is one row.
create function vppsone.school_return_copilot_mark(p_actor uuid,p_batch uuid,p_row uuid,p_state text,p_note text default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare b vppsone.school_return_batches; result vppsone.school_return_copilot_rows; clean_note text:=nullif(btrim(coalesce(p_note,'')),'');
begin
 select * into b from vppsone.school_return_batches where id=p_batch;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'government:export',b.session_label,p_confined) then raise exception 'office:forbidden'; end if;
 if b.direction<>'export' or b.adapter->>'mode'<>'manual_reference' or b.file_path is null
  or b.state not in('exported','submitted','partially_accepted','rejected') then raise exception 'office:not_manual_entry'; end if;
 if p_state not in('entered','mismatch') or (p_state='mismatch' and clean_note is null) or length(coalesce(clean_note,''))>500 then raise exception 'office:invalid_mark'; end if;
 if not exists(select 1 from jsonb_array_elements(b.payload->'rows') r where r->>'studentId'=p_row::text) then raise exception 'office:row_not_in_batch'; end if;
 insert into vppsone.school_return_copilot_rows(batch_id,row_key,state,note,actor_id)
 values(p_batch,p_row,p_state,case when p_state='mismatch' then clean_note end,p_actor)
 on conflict(batch_id,row_key) do update set state=excluded.state,note=excluded.note,actor_id=excluded.actor_id,updated_at=now()
 returning * into result;
 return to_jsonb(result);
end;
$$;
revoke all on function vppsone.school_return_copilot_mark(uuid,uuid,uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_copilot_mark(uuid,uuid,uuid,text,text,boolean) to service_role;

notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261103192446_teacher_leave_request_id.sql
-- VPPS One — a retried leave request files once (MCP feasibility §10).
--
-- `requestLeaveVx` inserted `teacher_leave` rows with no idempotency key, so
-- a send whose answer was lost — a dropped connection, a phone that slept —
-- and was tapped again filed the same leave twice, and each row queued its
-- own office notice through `teacher_leave_staff_notices`.
--
-- The leave sheet now generates one id per submission and keeps it across
-- retries of that same submission. The server stores it here and, when the
-- id is already filed for that person, returns the original rows instead of
-- inserting (src/vx/screens/teach/actions.ts).
--
-- One submission is one row per run of school days, so the key is the id
-- *and* the run's first day: the runs of one request never share a
-- `from_day`. The person is in the key too, so an id is only ever matched
-- against that person's own requests.
--
-- Additive and backfill-safe: the column is nullable and nothing is
-- backfilled. Existing rows, and rows written by the office's own leave
-- screens, keep NULL, which the partial index leaves out.
--
-- Rollback:
--   drop index if exists vppsone.teacher_leave_request_once;
--   alter table vppsone.teacher_leave drop column if exists client_request_id;

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.teacher_leave
  add column if not exists client_request_id uuid;

comment on column vppsone.teacher_leave.client_request_id is
  'The leave sheet''s id for one submission, kept across its retries. A repeat with the same id returns the rows already filed instead of filing again. NULL for rows from before it and from other screens.';

create unique index if not exists teacher_leave_request_once
  on vppsone.teacher_leave (staff_profile_id, client_request_id, from_day)
  where client_request_id is not null;

-- The app writes the column through PostgREST, which must see it at once.
notify pgrst, 'reload schema';

commit;

-- ======================================================== migrations/20261104022925_ai_connection_mcp.sql
-- The AI connection, first slice (M0/M1): One's own small OAuth 2.1
-- authorization server for the MCP endpoint, and its metadata-only call log
-- (docs/plans/2026-11-03-mcp-feasibility.md §5.2 option B, §5.3, §6.3; the
-- guarantees and their tests are in docs/plans/2026-11-03-mcp-m1-security-contract.md).
--
--  * ai_oauth_clients — public clients from dynamic registration (RFC 7591).
--    Redirect URIs were checked against an allowlist in code before insert.
--  * ai_connections   — one grant: which staff member, which auth user, which
--    client and provider, 90 days at most (owner decision D8), revoked with a
--    reason and by whom.
--  * ai_oauth_codes   — single-use authorization codes, 60 seconds, bound to
--    the client, redirect URI, PKCE challenge, resource and connection.
--  * ai_tokens        — access (15 minutes) and refresh (rotated, never past
--    the connection's expiry) tokens.
--  * ai_tool_calls    — one row per tool call: staff, connection, provider,
--    tool, outcome, row count, duration. Never arguments, names or free text
--    (the assist_log rule). Kept 180 days (D8), purged by `ai_purge`.
--
-- Codes and tokens are opaque random values; only their SHA-256 (hex) is
-- stored, so a copy of these tables opens nothing. Single use is decided here,
-- not in the app: each redemption locks its row (`select … for update`), so of
-- two concurrent redemptions exactly one finds it unused, and the other is
-- treated as reuse — the whole connection and every token from it is revoked
-- (RFC 6749 §4.1.2, OAuth 2.1 refresh rotation).
--
-- Service role only, like vppsone.assist_log: RLS on with no policy, every
-- grant to anon and authenticated revoked, functions executable by
-- service_role alone. Nothing here touches fee data.
--
-- The kill switch is a new runtime_flags key, `ai_connection`, added OFF:
-- absent or unreadable is off in the app as well.
--
-- Rollback:
--   drop function vppsone.ai_purge(integer), vppsone.ai_connection_list(uuid, integer),
--     vppsone.ai_staff_for_user(uuid), vppsone.ai_call_counts(uuid),
--     vppsone.ai_revoke_token(text, text), vppsone.ai_revoke_staff_connections(uuid, text, uuid),
--     vppsone.ai_resolve_access(text), vppsone.ai_rotate_refresh(text, text, text, text, text, integer),
--     vppsone.ai_exchange_code(text, text, text, text, text, text, text, integer),
--     vppsone.ai_create_grant(uuid, uuid, text, text, text[], text, text, text, text, integer, integer),
--     vppsone.ai_revoke_connection(uuid, text, uuid),
--     vppsone.ai_register_client(text, text, text[], text, text, integer, integer, integer);
--   drop table vppsone.ai_tool_calls, vppsone.ai_tokens, vppsone.ai_oauth_codes,
--     vppsone.ai_connections, vppsone.ai_oauth_clients;
--   delete from vppsone.runtime_flags where key = 'ai_connection';
--   re-add runtime_flags_key_known without it (20261031125856).

/* ------------------------------------------------------------ the switch */

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
    'staff_notice_student_names',
    'aisensy_month_plan_cap',
    'ai_connection'
  )
);
insert into vppsone.runtime_flags (key, enabled, value, note)
values (
  'ai_connection', false, null,
  'AI connection (Claude / ChatGPT through MCP) for eligible staff. Off = every tool call is refused; connections and the call log are kept.'
)
on conflict (key) do nothing;

/* --------------------------------------------------------------- tables */

create table vppsone.ai_oauth_clients (
  client_id text primary key check (client_id ~ '^[A-Za-z0-9_-]{22,64}$'),
  -- Display only, never trusted: the consent card names the provider from
  -- the redirect host, not from this.
  client_name text check (client_name is null or char_length(client_name) <= 80),
  redirect_uris text[] not null check (cardinality(redirect_uris) between 1 and 5),
  -- Which deployment registered it: production and every Preview share this
  -- database, so they count registrations separately.
  environment text not null check (environment in ('production', 'preview')),
  -- SHA-256 of the platform-set client IP (x-real-ip), never the address
  -- itself; nulled by the purge after a day. Only for the per-source limit.
  source_hash text check (source_hash is null or source_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

comment on table vppsone.ai_oauth_clients is
  'AI connection: public OAuth clients from dynamic registration. Every redirect URI matched an allowlist in code (src/modules/mcp/domain/redirects.ts).';

create index ai_oauth_clients_created on vppsone.ai_oauth_clients (environment, created_at);
create index ai_oauth_clients_source on vppsone.ai_oauth_clients (environment, source_hash, created_at);

create table vppsone.ai_connections (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  auth_user_id uuid not null references auth.users (id) on delete cascade,
  client_id text not null references vppsone.ai_oauth_clients (client_id) on delete restrict,
  provider text not null check (provider in ('claude', 'chatgpt', 'local')),
  scopes text[] not null check (cardinality(scopes) between 1 and 4),
  created_at timestamptz not null default now(),
  -- Null until the code is redeemed: consent alone makes a pending grant that
  -- holds no token, replaces nothing and is never shown as allowed.
  activated_at timestamptz,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by uuid references vppsone.staff_profiles (id) on delete set null,
  revoke_reason text check (revoke_reason is null or revoke_reason ~ '^[a-z_]{2,40}$'),
  constraint ai_connections_revoked_shape check ((revoked_at is null) = (revoke_reason is null)),
  -- Re-consent every 90 days (D8): no grant outlives that, whatever the app asks.
  constraint ai_connections_lifetime check (expires_at > created_at and expires_at <= created_at + interval '90 days')
);

comment on table vppsone.ai_connections is
  'AI connection grants: one staff member, one client, at most 90 days. Revoked rows are kept as evidence.';

create index ai_connections_staff on vppsone.ai_connections (staff_profile_id, created_at desc);
create index ai_connections_client on vppsone.ai_connections (client_id);

create table vppsone.ai_oauth_codes (
  code_hash text primary key check (code_hash ~ '^[0-9a-f]{64}$'),
  connection_id uuid not null references vppsone.ai_connections (id) on delete cascade,
  client_id text not null,
  redirect_uri text not null check (char_length(redirect_uri) <= 512),
  -- S256 only: base64url of a SHA-256, 43 characters.
  code_challenge text not null check (code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
  resource text not null check (char_length(resource) <= 512),
  scopes text[] not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  constraint ai_oauth_codes_short check (expires_at <= created_at + interval '5 minutes')
);

create index ai_oauth_codes_connection on vppsone.ai_oauth_codes (connection_id);
create index ai_oauth_codes_expires on vppsone.ai_oauth_codes (expires_at);

create table vppsone.ai_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  kind text not null check (kind in ('access', 'refresh')),
  connection_id uuid not null references vppsone.ai_connections (id) on delete cascade,
  resource text not null check (char_length(resource) <= 512),
  scopes text[] not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- Refresh only: set once, when the token is rotated. A second presentation
  -- of a used refresh token is replay.
  used_at timestamptz,
  replaced_by uuid references vppsone.ai_tokens (id) on delete set null,
  revoked_at timestamptz,
  constraint ai_tokens_rotation_refresh_only check (kind = 'refresh' or (used_at is null and replaced_by is null))
);

create index ai_tokens_connection on vppsone.ai_tokens (connection_id);
create index ai_tokens_expires on vppsone.ai_tokens (expires_at);

create table vppsone.ai_tool_calls (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  staff_profile_id uuid references vppsone.staff_profiles (id) on delete set null,
  connection_id uuid references vppsone.ai_connections (id) on delete set null,
  provider text not null check (provider in ('claude', 'chatgpt', 'local')),
  -- A registry name, or 'unknown' for a name the registry does not have —
  -- never the text a client sent.
  tool text not null check (tool ~ '^[a-z][a-z0-9_]{1,40}$'),
  outcome text not null check (outcome ~ '^(ok|refused:[a-z_]{2,40}|error:[a-z_]{2,40})$'),
  row_count integer check (row_count is null or row_count >= 0),
  duration_ms integer not null check (duration_ms >= 0)
);

comment on table vppsone.ai_tool_calls is
  'One row per AI connection tool call: who, which connection and provider, which tool, outcome, row count, duration. Never arguments, names or free text. 180 days.';

create index ai_tool_calls_staff_created on vppsone.ai_tool_calls (staff_profile_id, created_at desc);
create index ai_tool_calls_connection_created on vppsone.ai_tool_calls (connection_id, created_at desc);
create index ai_tool_calls_created on vppsone.ai_tool_calls (created_at);

alter table vppsone.ai_oauth_clients enable row level security;
alter table vppsone.ai_connections enable row level security;
alter table vppsone.ai_oauth_codes enable row level security;
alter table vppsone.ai_tokens enable row level security;
alter table vppsone.ai_tool_calls enable row level security;

revoke all on vppsone.ai_oauth_clients, vppsone.ai_connections, vppsone.ai_oauth_codes,
  vppsone.ai_tokens, vppsone.ai_tool_calls from public, anon, authenticated;
grant all on vppsone.ai_oauth_clients, vppsone.ai_connections, vppsone.ai_oauth_codes,
  vppsone.ai_tokens, vppsone.ai_tool_calls to service_role;

/* ------------------------------------------------------------ functions */

-- Register a public client, under one lock per environment so the counts
-- hold however many registrations arrive at once:
--  * the same source asking for the same redirect set within
--    p_reuse_seconds gets the client it already has (a provider re-registering
--    on every fresh connection does not use up the allowance);
--  * otherwise at most p_max_per_source new clients an hour per source
--    (hashed client IP), under a ceiling of p_max_per_hour per environment,
--    so one unauthenticated script cannot block everybody's onboarding and a
--    Preview cannot use up production's.
create function vppsone.ai_register_client(
  p_client_id text,
  p_client_name text,
  p_redirect_uris text[],
  p_source_hash text,
  p_environment text,
  p_max_per_source integer,
  p_max_per_hour integer,
  p_reuse_seconds integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_existing vppsone.ai_oauth_clients%rowtype;
  v_source integer;
  v_recent integer;
begin
  perform pg_advisory_xact_lock(hashtext('vppsone:ai-register:' || p_environment));

  select * into v_existing
  from vppsone.ai_oauth_clients
  where environment = p_environment
    and source_hash = p_source_hash
    and redirect_uris = p_redirect_uris
    and created_at > now() - make_interval(secs => p_reuse_seconds)
  order by created_at desc
  limit 1;
  if found then
    return jsonb_build_object(
      'ok', true, 'reused', true, 'client_id', v_existing.client_id,
      'client_name', v_existing.client_name, 'created_at', v_existing.created_at
    );
  end if;

  select count(*) filter (where source_hash = p_source_hash), count(*)
  into v_source, v_recent
  from vppsone.ai_oauth_clients
  where environment = p_environment and created_at > now() - interval '1 hour';
  if v_source >= p_max_per_source or v_recent >= p_max_per_hour then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;

  insert into vppsone.ai_oauth_clients (client_id, client_name, redirect_uris, environment, source_hash)
  values (p_client_id, nullif(btrim(p_client_name), ''), p_redirect_uris, p_environment, p_source_hash)
  returning * into v_existing;
  return jsonb_build_object(
    'ok', true, 'reused', false, 'client_id', v_existing.client_id,
    'client_name', v_existing.client_name, 'created_at', v_existing.created_at
  );
end;
$$;

-- End a connection and every token issued from it. Idempotent: the tokens
-- are revoked even when the connection already was.
create function vppsone.ai_revoke_connection(
  p_connection_id uuid,
  p_reason text,
  p_by uuid default null
)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_done boolean;
begin
  update vppsone.ai_connections
  set revoked_at = now(), revoke_reason = p_reason, revoked_by = p_by
  where id = p_connection_id and revoked_at is null;
  v_done := found;
  update vppsone.ai_tokens
  set revoked_at = now()
  where connection_id = p_connection_id and revoked_at is null;
  return v_done;
end;
$$;

-- The consent, in one transaction: a PENDING connection (no token, nothing
-- replaced, `activated_at` null) for 90 days at most, and its single-use
-- code for 60 seconds. Only redeeming the code activates it (ai_exchange_code).
-- The staff row must be active and belong to the signed-in auth user, and the
-- redirect URI must be one the client registered; eligibility (admins first,
-- D7) is checked by the app before this is called.
create function vppsone.ai_create_grant(
  p_staff_profile_id uuid,
  p_auth_user_id uuid,
  p_client_id text,
  p_provider text,
  p_scopes text[],
  p_code_hash text,
  p_redirect_uri text,
  p_code_challenge text,
  p_resource text,
  p_code_ttl_seconds integer,
  p_grant_days integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_staff vppsone.staff_profiles%rowtype;
  v_client vppsone.ai_oauth_clients%rowtype;
  v_conn uuid;
begin
  if p_code_ttl_seconds not between 1 and 300 or p_grant_days not between 1 and 90 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select * into v_staff from vppsone.staff_profiles where id = p_staff_profile_id;
  if not found or not v_staff.is_active or v_staff.user_id is distinct from p_auth_user_id then
    return jsonb_build_object('ok', false, 'reason', 'staff');
  end if;

  select * into v_client from vppsone.ai_oauth_clients where client_id = p_client_id;
  if not found or not (p_redirect_uri = any (v_client.redirect_uris)) then
    return jsonb_build_object('ok', false, 'reason', 'client');
  end if;

  insert into vppsone.ai_connections (staff_profile_id, auth_user_id, client_id, provider, scopes, expires_at)
  values (p_staff_profile_id, p_auth_user_id, p_client_id, p_provider, p_scopes, now() + make_interval(days => p_grant_days))
  returning id into v_conn;

  insert into vppsone.ai_oauth_codes (code_hash, connection_id, client_id, redirect_uri, code_challenge, resource, scopes, expires_at)
  values (p_code_hash, v_conn, p_client_id, p_redirect_uri, p_code_challenge, p_resource, p_scopes,
          now() + make_interval(secs => p_code_ttl_seconds));

  return jsonb_build_object('ok', true, 'connection_id', v_conn);
end;
$$;

-- Redeem a code for the first access and refresh tokens. The row is locked,
-- so a concurrent second redemption waits and then finds it used: that is
-- reuse, and the connection with every token from it is revoked. A code
-- presented with the wrong client, redirect URI, PKCE verifier or resource is
-- consumed and its connection revoked; an expired one is consumed and its
-- connection, which never had a token, ended.
--
-- A good code activates its connection. Under an advisory lock per staff
-- member and provider, every other unrevoked connection of theirs to that
-- provider — live or still pending — ends as 'replaced', and the connection
-- is re-read after the lock: two approvals redeemed at once leave exactly one
-- live, and a connection revoked while this waited is not activated.
create function vppsone.ai_exchange_code(
  p_code_hash text,
  p_verifier_challenge text,
  p_client_id text,
  p_redirect_uri text,
  p_resource text,
  p_access_hash text,
  p_refresh_hash text,
  p_access_ttl_seconds integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_code vppsone.ai_oauth_codes%rowtype;
  v_conn vppsone.ai_connections%rowtype;
  v_access_expires timestamptz;
begin
  select * into v_code from vppsone.ai_oauth_codes where code_hash = p_code_hash for update;
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_code.used_at is not null then
    perform vppsone.ai_revoke_connection(v_code.connection_id, 'code_reuse', null);
    return jsonb_build_object('status', 'replayed');
  end if;

  update vppsone.ai_oauth_codes set used_at = now() where code_hash = p_code_hash;

  if v_code.expires_at <= now() then
    perform vppsone.ai_revoke_connection(v_code.connection_id, 'code_expired', null);
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_code.client_id is distinct from p_client_id
     or v_code.redirect_uri is distinct from p_redirect_uri
     or v_code.code_challenge is distinct from p_verifier_challenge
     or v_code.resource is distinct from p_resource then
    perform vppsone.ai_revoke_connection(v_code.connection_id, 'code_mismatch', null);
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_conn from vppsone.ai_connections where id = v_code.connection_id;
  perform pg_advisory_xact_lock(hashtext('vppsone:ai-connection:' || v_conn.staff_profile_id::text || ':' || v_conn.provider));
  select * into v_conn from vppsone.ai_connections where id = v_code.connection_id;
  if v_conn.revoked_at is not null or v_conn.expires_at <= now() then
    return jsonb_build_object('status', 'invalid');
  end if;

  perform vppsone.ai_revoke_connection(c.id, 'replaced', v_conn.staff_profile_id)
  from vppsone.ai_connections c
  where c.staff_profile_id = v_conn.staff_profile_id
    and c.provider = v_conn.provider
    and c.id <> v_conn.id
    and c.revoked_at is null;
  update vppsone.ai_connections set activated_at = now() where id = v_conn.id;

  v_access_expires := least(now() + make_interval(secs => p_access_ttl_seconds), v_conn.expires_at);
  insert into vppsone.ai_tokens (token_hash, kind, connection_id, resource, scopes, expires_at)
  values
    (p_access_hash, 'access', v_conn.id, v_code.resource, v_code.scopes, v_access_expires),
    (p_refresh_hash, 'refresh', v_conn.id, v_code.resource, v_code.scopes, v_conn.expires_at);

  return jsonb_build_object(
    'status', 'ok',
    'connection_id', v_conn.id,
    'scopes', to_jsonb(v_code.scopes),
    'access_expires_at', v_access_expires,
    'refresh_expires_at', v_conn.expires_at
  );
end;
$$;

-- Rotate a refresh token: the presented one is marked used and a new pair
-- issued, the refresh never past the connection's expiry. A used refresh
-- token presented again is replay: the connection and every token from it is
-- revoked. The same row lock as codes makes two concurrent rotations one
-- rotation and one replay.
create function vppsone.ai_rotate_refresh(
  p_refresh_hash text,
  p_client_id text,
  p_resource text,
  p_new_access_hash text,
  p_new_refresh_hash text,
  p_access_ttl_seconds integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_old vppsone.ai_tokens%rowtype;
  v_conn vppsone.ai_connections%rowtype;
  v_new uuid;
  v_access_expires timestamptz;
begin
  select * into v_old from vppsone.ai_tokens
  where token_hash = p_refresh_hash and kind = 'refresh'
  for update;
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_conn from vppsone.ai_connections where id = v_old.connection_id;
  if v_conn.client_id is distinct from p_client_id then
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_old.used_at is not null then
    perform vppsone.ai_revoke_connection(v_old.connection_id, 'refresh_reuse', null);
    return jsonb_build_object('status', 'replayed');
  end if;

  if v_old.revoked_at is not null or v_old.expires_at <= now()
     or v_conn.revoked_at is not null or v_conn.expires_at <= now()
     or v_old.resource is distinct from p_resource then
    return jsonb_build_object('status', 'invalid');
  end if;

  v_access_expires := least(now() + make_interval(secs => p_access_ttl_seconds), v_conn.expires_at);

  insert into vppsone.ai_tokens (token_hash, kind, connection_id, resource, scopes, expires_at)
  values (p_new_refresh_hash, 'refresh', v_conn.id, v_old.resource, v_old.scopes, v_conn.expires_at)
  returning id into v_new;

  insert into vppsone.ai_tokens (token_hash, kind, connection_id, resource, scopes, expires_at)
  values (p_new_access_hash, 'access', v_conn.id, v_old.resource, v_old.scopes, v_access_expires);

  update vppsone.ai_tokens set used_at = now(), replaced_by = v_new where id = v_old.id;

  return jsonb_build_object(
    'status', 'ok',
    'connection_id', v_conn.id,
    'scopes', to_jsonb(v_old.scopes),
    'access_expires_at', v_access_expires,
    'refresh_expires_at', v_conn.expires_at
  );
end;
$$;

-- Step 1 and 2 of every call (§5.3): the token by its hash, with its
-- connection. Null when no such token. The app decides kind, expiry,
-- audience and revocation from the row, on every call.
create function vppsone.ai_resolve_access(p_token_hash text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'kind', t.kind,
    'resource', t.resource,
    'scopes', to_jsonb(t.scopes),
    'expires_at', t.expires_at,
    'revoked_at', t.revoked_at,
    'connection', jsonb_build_object(
      'id', c.id,
      'staff_profile_id', c.staff_profile_id,
      'auth_user_id', c.auth_user_id,
      'client_id', c.client_id,
      'provider', c.provider,
      'scopes', to_jsonb(c.scopes),
      'expires_at', c.expires_at,
      'revoked_at', c.revoked_at
    )
  )
  from vppsone.ai_tokens t
  join vppsone.ai_connections c on c.id = t.connection_id
  where t.token_hash = p_token_hash
$$;

-- RFC 7009. Only the client the token was issued to can revoke it; anything
-- else is answered the same way and changes nothing. A refresh token ends the
-- whole grant; an access token only itself.
create function vppsone.ai_revoke_token(p_token_hash text, p_client_id text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_token vppsone.ai_tokens%rowtype;
  v_client text;
begin
  select * into v_token from vppsone.ai_tokens where token_hash = p_token_hash;
  if not found then
    return;
  end if;
  select client_id into v_client from vppsone.ai_connections where id = v_token.connection_id;
  if v_client is distinct from p_client_id then
    return;
  end if;
  if v_token.kind = 'refresh' then
    perform vppsone.ai_revoke_connection(v_token.connection_id, 'revoked_by_client', null);
  else
    update vppsone.ai_tokens set revoked_at = coalesce(revoked_at, now()) where id = v_token.id;
  end if;
end;
$$;

-- Every live connection of one staff member: Disconnect on their card, an
-- admin disabling them, or the call pipeline finding them inactive.
create function vppsone.ai_revoke_staff_connections(
  p_staff_profile_id uuid,
  p_reason text,
  p_by uuid default null
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_n integer := 0;
begin
  for v_id in
    select id from vppsone.ai_connections
    where staff_profile_id = p_staff_profile_id and revoked_at is null
  loop
    if vppsone.ai_revoke_connection(v_id, p_reason, p_by) then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

-- Per-staff limits (§5.5), checked before anything else a call does: calls
-- in the last hour and the last 24 hours, counted from the log, refused ones
-- included. A call already refused for the limit does not count again, so a
-- client that keeps knocking is not locked out for longer; `limited_hour`
-- lets the app write at most one such refusal an hour, so a token cannot
-- flood the log either.
create function vppsone.ai_call_counts(p_staff_profile_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'hour', count(*) filter (where created_at > now() - interval '1 hour' and outcome <> 'refused:rate_limited'),
    'day', count(*) filter (where outcome <> 'refused:rate_limited'),
    'limited_hour', count(*) filter (where created_at > now() - interval '1 hour' and outcome = 'refused:rate_limited')
  )
  from vppsone.ai_tool_calls
  where staff_profile_id = p_staff_profile_id
    and created_at > now() - interval '24 hours'
$$;

-- Step 4 of every call: the staff profile for a verified auth user, and its
-- role's permissions as the matrix holds them now — the service-role twin of
-- what `readCurrentStaff` reads with the cookie (`my_permissions()` keys on
-- auth.uid(), which a token-authenticated call does not have).
create function vppsone.ai_staff_for_user(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id,
    'display_name', s.display_name,
    'short_name', s.short_name,
    'role', s.role,
    'is_teaching', s.is_teaching,
    'is_active', s.is_active,
    'preferred_language', s.preferred_language,
    'is_test_account', s.is_test_account,
    'permissions', coalesce(
      (select jsonb_agg(rp.permission order by rp.permission)
       from vppsone.role_permissions rp where rp.role = s.role),
      '[]'::jsonb
    )
  )
  from vppsone.staff_profiles s
  where s.user_id = p_user_id
$$;

-- The connections list (admin page) and one person's card: activated
-- connections only — a pending grant whose code was never redeemed holds no
-- token and is never shown as allowed. Last used and the 30-day count come
-- from the log; no argument or result is stored anywhere.
create function vppsone.ai_connection_list(p_staff_profile_id uuid default null, p_limit integer default 200)
returns table (
  id uuid,
  staff_profile_id uuid,
  staff_name text,
  provider text,
  created_at timestamptz,
  activated_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  revoke_reason text,
  last_used_at timestamptz,
  calls_30d integer
)
language sql
stable
set search_path = ''
as $$
  select
    c.id,
    c.staff_profile_id,
    s.display_name,
    c.provider,
    c.created_at,
    c.activated_at,
    c.expires_at,
    c.revoked_at,
    c.revoke_reason,
    (select max(l.created_at) from vppsone.ai_tool_calls l where l.connection_id = c.id),
    (select count(*)::integer from vppsone.ai_tool_calls l
      where l.connection_id = c.id and l.created_at > now() - interval '30 days')
  from vppsone.ai_connections c
  join vppsone.staff_profiles s on s.id = c.staff_profile_id
  where c.activated_at is not null
    and (p_staff_profile_id is null or c.staff_profile_id = p_staff_profile_id)
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 500)
$$;

-- The scheduled clean-up (job `ai-connection-purge`): call rows older than
-- the retention (180 days, D8); codes a day past expiry; tokens a day past
-- expiry or revocation (a used refresh token lives until its connection
-- expires, so replay is still recognised while the grant could be used);
-- connections ended longer ago than the retention or never activated;
-- registered clients nobody connected with within a day; and hashed source
-- addresses older than a day.
create function vppsone.ai_purge(p_keep_days integer default 180)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_calls integer;
  v_codes integer;
  v_tokens integer;
  v_connections integer;
  v_clients integer;
begin
  if p_keep_days is null or p_keep_days < 30 then
    raise exception 'ai_purge keeps at least 30 days';
  end if;

  delete from vppsone.ai_tool_calls where created_at < now() - make_interval(days => p_keep_days);
  get diagnostics v_calls = row_count;

  delete from vppsone.ai_oauth_codes where expires_at < now() - interval '1 day';
  get diagnostics v_codes = row_count;

  delete from vppsone.ai_tokens
  where expires_at < now() - interval '1 day'
     or (revoked_at is not null and revoked_at < now() - interval '1 day');
  get diagnostics v_tokens = row_count;

  -- Ended long ago, or consented to and never redeemed (pending past a day).
  delete from vppsone.ai_connections
  where coalesce(revoked_at, expires_at) < now() - make_interval(days => p_keep_days)
     or (activated_at is null and created_at < now() - interval '1 day');
  get diagnostics v_connections = row_count;

  delete from vppsone.ai_oauth_clients c
  where c.created_at < now() - interval '1 day'
    and not exists (select 1 from vppsone.ai_connections x where x.client_id = c.client_id);
  get diagnostics v_clients = row_count;

  -- The per-source limit looks back an hour; the hashed address need not
  -- outlive a day on the clients that stay.
  update vppsone.ai_oauth_clients set source_hash = null
  where source_hash is not null and created_at < now() - interval '1 day';

  return jsonb_build_object(
    'calls', v_calls,
    'codes', v_codes,
    'tokens', v_tokens,
    'connections', v_connections,
    'clients', v_clients
  );
end;
$$;

revoke all on function vppsone.ai_register_client(text, text, text[], text, text, integer, integer, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_revoke_connection(uuid, text, uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_create_grant(uuid, uuid, text, text, text[], text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_exchange_code(text, text, text, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_rotate_refresh(text, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_resolve_access(text) from public, anon, authenticated;
revoke all on function vppsone.ai_revoke_token(text, text) from public, anon, authenticated;
revoke all on function vppsone.ai_revoke_staff_connections(uuid, text, uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_call_counts(uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_staff_for_user(uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_connection_list(uuid, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_purge(integer) from public, anon, authenticated;

grant execute on function vppsone.ai_register_client(text, text, text[], text, text, integer, integer, integer) to service_role;
grant execute on function vppsone.ai_revoke_connection(uuid, text, uuid) to service_role;
grant execute on function vppsone.ai_create_grant(uuid, uuid, text, text, text[], text, text, text, text, integer, integer) to service_role;
grant execute on function vppsone.ai_exchange_code(text, text, text, text, text, text, text, integer) to service_role;
grant execute on function vppsone.ai_rotate_refresh(text, text, text, text, text, integer) to service_role;
grant execute on function vppsone.ai_resolve_access(text) to service_role;
grant execute on function vppsone.ai_revoke_token(text, text) to service_role;
grant execute on function vppsone.ai_revoke_staff_connections(uuid, text, uuid) to service_role;
grant execute on function vppsone.ai_call_counts(uuid) to service_role;
grant execute on function vppsone.ai_staff_for_user(uuid) to service_role;
grant execute on function vppsone.ai_connection_list(uuid, integer) to service_role;
grant execute on function vppsone.ai_purge(integer) to service_role;

-- ======================================================== migrations/20261104054116_built_in_ai_jobs.sql
-- Built-in Gemini pilot. Only VPPS One's server can use this ledger or bucket.
-- No browser role can list, read or change objects; the server mints individual
-- upload tokens only after authenticating and authorising the operation.
create table vppsone.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id),
  action text not null check (action ~ '^[a-z][a-z0-9-]{1,39}$'),
  session_label text not null check (session_label = 'TEST-2026-27'),
  target_id uuid not null,
  target_revision integer not null check (target_revision >= 0),
  roster_stamp text,
  input_paths text[] not null check (cardinality(input_paths) between 1 and 4),
  model text not null,
  model_version text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  thinking_tokens integer not null default 0 check (thinking_tokens >= 0),
  estimated_cost_inr numeric(12,6) not null default 0 check (estimated_cost_inr >= 0),
  attempts jsonb not null default '[]',
  raw_output jsonb,
  reviewed_data jsonb,
  final_applied_data jsonb,
  status text not null default 'draft' check (status in ('draft','applied','discarded','failed')),
  error text,
  created_at timestamptz not null default now(),
  parse_started_at timestamptz,
  parsed_at timestamptz,
  applied_at timestamptz,
  purged_at timestamptz
);
alter table vppsone.ai_jobs enable row level security;
revoke all on vppsone.ai_jobs from public, anon, authenticated;
grant select, insert, update on vppsone.ai_jobs to service_role;
create index ai_jobs_staff_created_idx on vppsone.ai_jobs (staff_profile_id, created_at);
create index ai_jobs_retention_idx on vppsone.ai_jobs (created_at) where purged_at is null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ai-inputs', 'ai-inputs', false, 2097152, array['image/jpeg','audio/webm','audio/mp4']);

-- Restrictive so an unrelated, broad permissive storage policy cannot expose
-- this bucket. The service role bypasses RLS, including for signed uploads.
create policy ai_inputs_server_only on storage.objects as restrictive
for all to anon, authenticated
using (bucket_id <> 'ai-inputs') with check (bucket_id <> 'ai-inputs');

-- Serialize reservations per person. In particular, 51 parallel requests
-- cannot all observe the same count and then get usable upload tokens.
create function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_target uuid, p_revision integer,
  p_pages integer, p_model text
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
begin
  if p_pages is null or p_pages not between 1 and 4 then
    raise exception 'invalid page count';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  if (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= 50 then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, 'TEST-2026-27', p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.jpg' from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text) to service_role;

-- ======================================================== migrations/20261104054119_ai_cover_photo.sql
-- AI photo writes are fenced to TEST. Use the existing cover command to
-- publish, record history, and queue notices. The ordinary outbox claim
-- already locks each notice and excludes pending rows before next_attempt_at.
create function vppsone.apply_ai_cover_photo(
  p_job uuid, p_actor uuid, p_day date, p_timetable_day text,
  p_version uuid, p_bells integer, p_assignments jsonb, p_review jsonb
) returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session constant text := 'TEST-2026-27';
  j vppsone.ai_jobs%rowtype;
  s vppsone.timetable_slots%rowtype;
  r record;
  v_existing jsonb;
  v_desired jsonb := '[]';
  v_previous_absences jsonb;
  v_absences jsonb;
  v_applied jsonb := '[]';
  v_keys text[] := '{}';
  v_row jsonb;
  v_written text;
  v_date_parts text[];
  v_starts timestamptz;
  v_first_start timestamptz;
  v_undo_until timestamptz;
  v_receipt jsonb;
  v_result jsonb;
begin
  if p_day is null or p_version is null or p_timetable_day is null or p_bells is null
     or length(btrim(p_timetable_day)) < 3
     or not starts_with(lower(to_char(p_day, 'FMDay')), lower(btrim(p_timetable_day)))
     or jsonb_typeof(p_assignments) is distinct from 'array'
     or jsonb_array_length(p_assignments) not between 1 and 60 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor and session_label = v_session
    and action = 'substitution-photo' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if j.status = 'applied' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  if j.status <> 'draft' or j.parsed_at is null or j.raw_output is null
     or j.roster_stamp is distinct from p_version::text || ':' || p_bells::text then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  if coalesce((select revision from vppsone.cover_days where session_label = v_session and day = p_day), 0)
       <> j.target_revision
     or not exists (select 1 from vppsone.timetable_versions
                    where id = p_version and session_label = v_session and status = 'published') then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- The ordinary absence table's unique key omits session_label. Prevent a
  -- concurrent insertion for the same staff/day from letting the upsert
  -- replace an absence belonging to another session.
  lock table vppsone.teacher_absences in share row exclusive mode;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]') into v_existing
  from vppsone.cover_duties d
  where d.session_label = v_session and d.day = p_day and d.status in ('assigned', 'needs_help');

  for r in
    select * from jsonb_to_recordset(p_assignments)
      as x(index integer, "absentId" uuid, "coveringId" uuid, "classId" uuid, period smallint, "needKey" text)
  loop
    if r."absentId" is null or r."coveringId" is null or r."absentId" = r."coveringId"
       or r."classId" is null or r.period is null or r.period not between 0 and 7
       or r.index is null or r.index not between 0 and 59 or r."needKey" is null
       or r."needKey" = any(v_keys) or v_applied @> jsonb_build_array(r.index) then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;

    v_row := j.raw_output->'rows'->r.index;
    v_written := btrim(translate(v_row->>'sourceDate', '०१२३४५६७८९０１２３４５６７８９', '01234567890123456789'));
    v_date_parts := regexp_match(v_written, '^([0-9]{1,2})[[:space:]]*([./-])[[:space:]]*([0-9]{1,2})[[:space:]]*\2[[:space:]]*([0-9]{4})$');
    if v_row->'unclear' is distinct from 'false'::jsonb or (
      v_written is distinct from p_day::text and
      (v_date_parts[4] || '-' || lpad(v_date_parts[3], 2, '0') || '-' || lpad(v_date_parts[1], 2, '0')) is distinct from p_day::text
    ) then
      return jsonb_build_object('ok', false, 'reason', 'source_date');
    end if;

    select (p_day + (period->>'starts')::time) at time zone 'Asia/Kolkata'
    into v_starts
    from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
    where b.session_label = v_session and b.is_current and b.revision = p_bells
      and (period->>'index')::smallint = r.period;
    if v_starts is null or v_starts <= clock_timestamp() + interval '2 minutes' then
      return jsonb_build_object('ok', false, 'reason', 'closed');
    end if;
    v_first_start := least(v_first_start, v_starts);

    select * into s from vppsone.timetable_slots ts
    where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
      and ts.class_id = r."classId" and ts.staff_profile_id = r."absentId"
      and not ts.parallel and not ts.shared;
    if not found or r."needKey" <>
       (s.day || '|P' || s.period || '|ordinary|' || s.subject_code || '|' || s.class_id || '|' || s.staff_profile_id || '#lesson')
       or (select count(*) from vppsone.timetable_slots ts
           where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
             and (ts.class_id = r."classId" or ts.staff_profile_id = r."absentId")) <> 1
       or (select count(*) from vppsone.staff_profiles sp
           where sp.id in (r."absentId", r."coveringId") and sp.is_active and sp.is_teaching) <> 2
       or not exists (select 1 from vppsone.timetable_slots ts
                      where ts.version_id = p_version and ts.staff_profile_id = r."coveringId")
       or exists (select 1 from vppsone.cover_policies cp
                  where cp.session_label = v_session and cp.staff_profile_id = r."coveringId"
                    and not (r.period = any(cp.allowed_periods)))
       or exists (select 1 from vppsone.teacher_leave l
                  where l.session_label = v_session and l.staff_profile_id = r."coveringId" and l.status = 'approved'
                    and p_day between l.from_day and l.to_day
                    and (l.span = 'full' or (l.span = 'first_half' and r.period <= 3)
                                         or (l.span = 'second_half' and r.period > 3)))
       or exists (select 1 from vppsone.teacher_absences a
                  where a.staff_profile_id = r."absentId" and a.day = p_day and a.session_label <> v_session)
       or exists (select 1 from vppsone.cover_duties d
                  where d.session_label = v_session and d.day = p_day and d.need_key = r."needKey"
                    and (d.status = 'assigned' or (d.covering_staff_id = r."coveringId" and d.cannot_cover_at is not null)))
    then
      return jsonb_build_object('ok', false, 'reason', 'conflict');
    end if;

    v_desired := v_desired || jsonb_build_object(
      'need_key', r."needKey", 'period', r.period, 'event_kind', 'ordinary',
      'class_ids', jsonb_build_array(s.class_id), 'class_labels', jsonb_build_array(s.class_label),
      'subject_code', s.subject_code, 'absent_staff_ids', jsonb_build_array(r."absentId"),
      'status', 'assigned', 'covering_staff_id', r."coveringId", 'source', 'manual', 'pinned', true
    );
    v_applied := v_applied || to_jsonb(r.index);
    v_keys := array_append(v_keys, r."needKey");
  end loop;

  -- Only append or fill the photographed duties. Keep every other duty,
  -- including unresolved duties and the coordinator's existing choices.
  v_desired := v_desired || coalesce(
    (select jsonb_agg(value) from jsonb_array_elements(v_existing) where not (value->>'need_key' = any(v_keys))),
    '[]'
  );
  with changes as (
    select (entry->>'absentId')::uuid as staff_id, array_agg(distinct (entry->>'period')::smallint) as periods
    from jsonb_array_elements(p_assignments) entry
    group by (entry->>'absentId')::uuid
  ), additions as (
    select c.staff_id, c.periods, a.periods as previous
    from changes c left join vppsone.teacher_absences a
      on a.staff_profile_id = c.staff_id and a.day = p_day and a.session_label = v_session
    where a.periods is null or not c.periods <@ a.periods
  )
  select coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous)), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous || periods)), '[]')
  into v_previous_absences, v_absences
  from additions;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', p_job, 'kind', 'substitution_photo', 'actor_staff_id', p_actor, 'session_label', v_session,
    'day', p_day, 'timetable_day', p_timetable_day, 'payload_hash', 'substitution-photo:' || p_job,
    'expected', jsonb_build_object('day_revision', j.target_revision, 'timetable_version_id', p_version, 'bells_revision', p_bells),
    'absences', v_absences, 'duties', v_desired
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  v_undo_until := clock_timestamp() + interval '2 minutes';
  if v_first_start <= v_undo_until
     or (select count(*) from vppsone.staff_notices where command_id = p_job and status = 'pending')
          <> jsonb_array_length(v_applied) then
    raise exception 'substitution photo was not fully applied';
  end if;
  update vppsone.staff_notices set next_attempt_at = v_undo_until
  where command_id = p_job and status = 'pending';

  v_result := jsonb_build_object('jobId', p_job, 'review', p_review, 'applied', v_applied, 'undoUntil', v_undo_until);
  update vppsone.ai_jobs set
    status = 'applied', applied_at = v_undo_until - interval '2 minutes', final_applied_data = v_result,
    reviewed_data = jsonb_build_object(
      'duties', v_existing, 'absences', v_previous_absences, 'dayRevision', v_receipt->'day_revision',
      'version', p_version, 'bells', p_bells, 'timetableDay', p_timetable_day
    )
  where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

create function vppsone.undo_ai_cover_photo(p_job uuid, p_actor uuid, p_day date)
returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session constant text := 'TEST-2026-27';
  j vppsone.ai_jobs%rowtype;
  v_undo_until timestamptz;
  v_notice_count integer;
  v_receipt jsonb;
  v_result jsonb;
begin
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor and session_label = v_session
    and action = 'substitution-photo' and status = 'applied' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if j.final_applied_data->>'undone' = 'true' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  v_undo_until := (j.final_applied_data->>'undoUntil')::timestamptz;
  if v_undo_until is null or clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  lock table vppsone.teacher_absences in share row exclusive mode;
  if exists (
    select 1 from vppsone.teacher_absences a
    join jsonb_array_elements(j.reviewed_data->'absences') prior on a.staff_profile_id = (prior->>'staff_profile_id')::uuid
    where a.day = p_day and a.session_label <> v_session
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- Teacher replies lock their duty before writing a notice. Use that same
  -- order here so any reply which already happened stays in the history and
  -- any reply to the withdrawn duty is refused after Undo commits.
  perform 1 from vppsone.cover_duties d where d.command_id = p_job order by d.id for update;

  -- Take the same notice locks the dispatcher claims, before the real-clock
  -- check. Once locked, the dispatcher skips these rows until Undo commits.
  perform 1 from vppsone.staff_notices n where n.command_id = p_job order by n.id for update;
  select count(*) into v_notice_count from vppsone.staff_notices
  where command_id = p_job and kind = 'cover_assigned';
  if clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if v_notice_count <> jsonb_array_length(j.final_applied_data->'applied') or exists (
    select 1 from vppsone.staff_notices n
    join vppsone.cover_duties d on d.id = n.duty_id
    where n.command_id = p_job
      and (n.status <> 'pending' or n.attempts <> 0 or n.next_attempt_at is distinct from v_undo_until
           or d.status <> 'assigned')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', gen_random_uuid(), 'kind', 'substitution_photo_undo', 'actor_staff_id', p_actor,
    'session_label', v_session, 'day', p_day, 'timetable_day', j.reviewed_data->'timetableDay',
    'payload_hash', 'substitution-photo-undo:' || p_job,
    'expected', jsonb_build_object(
      'day_revision', j.reviewed_data->'dayRevision',
      'timetable_version_id', j.reviewed_data->'version', 'bells_revision', j.reviewed_data->'bells'
    ),
    'absences', j.reviewed_data->'absences', 'duties', j.reviewed_data->'duties'
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  if exists (select 1 from vppsone.staff_notices where command_id = p_job and status <> 'cancelled') then
    raise exception 'substitution photo notices were not withdrawn';
  end if;
  v_result := j.final_applied_data || jsonb_build_object('undone', true);
  update vppsone.ai_jobs set final_applied_data = v_result where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

revoke all on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) from public, anon, authenticated;
revoke all on function vppsone.undo_ai_cover_photo(uuid, uuid, date) from public, anon, authenticated;
grant execute on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) to service_role;
grant execute on function vppsone.undo_ai_cover_photo(uuid, uuid, date) to service_role;

-- A teacher can respond on the web before a WhatsApp notice is due, and
-- another coordinator can change a duty. Their related escalation or
-- replacement notice must honor the original hold, too.
create function vppsone.inherit_ai_cover_photo_hold()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_hold timestamptz;
begin
  if new.session_label <> 'TEST-2026-27' or new.duty_id is null then return new; end if;
  with recursive chain as (
    select id, supersedes, command_id from vppsone.cover_duties where id = new.duty_id
    union
    select d.id, d.supersedes, d.command_id from vppsone.cover_duties d join chain c on c.supersedes = d.id
  )
  select max((j.final_applied_data->>'undoUntil')::timestamptz) into v_hold
  from chain c join vppsone.ai_jobs j on c.command_id = j.id
  where j.action = 'substitution-photo' and j.status = 'applied';

  if v_hold > clock_timestamp() then new.next_attempt_at := greatest(new.next_attempt_at, v_hold); end if;
  return new;
end;
$$;
revoke all on function vppsone.inherit_ai_cover_photo_hold() from public, anon, authenticated;
create trigger staff_notices_inherit_ai_cover_photo_hold
before insert on vppsone.staff_notices for each row execute function vppsone.inherit_ai_cover_photo_hold();

-- ======================================================== migrations/20261104054126_builtin_ai_provider_usage.sql
-- Built-in AI stays in TEST-2026-27. The new setting controls reservations
-- across photo and voice actions, and the report returns no input or transcript.
alter table vppsone.ai_jobs add column provider text;
alter table vppsone.ai_jobs add column edited boolean;

create table vppsone.builtin_ai_settings (
  id integer primary key check (id = 1),
  daily_limit integer not null default 50 check (daily_limit between 0 and 200),
  updated_at timestamptz not null default now(),
  updated_by uuid references vppsone.staff_profiles(id)
);
insert into vppsone.builtin_ai_settings (id) values (1);
alter table vppsone.builtin_ai_settings enable row level security;
revoke all on vppsone.builtin_ai_settings from public, anon, authenticated;
grant select, update on vppsone.builtin_ai_settings to service_role;

update storage.buckets
set allowed_mime_types = array['image/jpeg','audio/webm','audio/mp4','audio/wav','audio/m4a']
where id = 'ai-inputs' and public is false;

drop function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text);
create function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_target uuid, p_revision integer,
  p_pages integer, p_model text, p_audio_extension text default null
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_limit integer;
  v_extension text := coalesce(p_audio_extension, 'jpg');
begin
  if p_action not in ('marks-photo','substitution-photo','voice')
     or p_pages is null or p_pages not between 1 and 4
     or (p_action = 'voice' and (p_pages <> 1 or v_extension not in ('webm','m4a','wav')))
     or (p_action <> 'voice' and p_audio_extension is not null)
     or p_action is null then
    raise exception 'invalid AI input';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  select daily_limit into v_limit from vppsone.builtin_ai_settings where id = 1;
  if v_limit is null or (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= v_limit then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, 'TEST-2026-27', p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.' || v_extension from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text, text) to service_role;

create function vppsone.builtin_ai_usage() returns jsonb
language sql stable security invoker set search_path = '' as $$
with current_month as (
  select date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata' as start_at
), jobs as materialized (
  select * from vppsone.ai_jobs where created_at >= (select start_at from current_month)
), handled as (
  select provider, count(*) as handled from jobs
  where parsed_at is not null and provider is not null group by provider
), attempts as (
  select a->>'provider' as provider, count(*) as attempts,
    sum(case when jsonb_typeof(a->'costInr') = 'number' then (a->>'costInr')::numeric else 0 end) as cost
  from jobs cross join lateral jsonb_array_elements(
    case when jsonb_typeof(jobs.attempts) = 'array' then jobs.attempts else '[]'::jsonb end
  ) a where a->>'provider' is not null group by a->>'provider'
), providers as (
  select provider, coalesce(handled.handled,0) as handled, coalesce(attempts.attempts,0) as attempts,
         coalesce(attempts.cost,0) as cost
  from handled full join attempts using (provider)
), failures as (
  select created_at, action, provider, error from jobs where status = 'failed'
  order by created_at desc limit 12
)
select jsonb_build_object(
  'actions', (select count(*) from jobs),
  'handled', (select count(*) from jobs where parsed_at is not null),
  'applied', (select count(*) from jobs where status = 'applied'),
  'edited', (select count(*) from jobs where status = 'applied' and edited),
  'costInr', (select coalesce(sum(estimated_cost_inr),0) from jobs),
  'providers', (select coalesce(jsonb_agg(to_jsonb(p) order by provider),'[]'::jsonb) from providers p),
  'failures', (select coalesce(jsonb_agg(to_jsonb(f) order by created_at desc),'[]'::jsonb) from failures f),
  'dailyLimit', (select daily_limit from vppsone.builtin_ai_settings where id = 1)
);
$$;
revoke all on function vppsone.builtin_ai_usage() from public, anon, authenticated;
grant execute on function vppsone.builtin_ai_usage() to service_role;

-- ======================================================== migrations/20261104055339_builtin_ai_live.sql
-- Built-in AI goes live for staff (owner direction, 4 November 2026).
--
-- The pilot fenced every AI job, cover-photo apply and Undo to TEST-2026-27.
-- A job now belongs to the session the member of staff is working in, which
-- the app resolves with the ordinary session rule. The fence that stays is the
-- one every other write keeps (D-340): a test account works only in a TEST
-- session. Cover-photo apply and Undo take their session from the job row,
-- never from the caller, and still go through commit_cover_command.

alter table vppsone.ai_jobs drop constraint ai_jobs_session_label_check;
alter table vppsone.ai_jobs add constraint ai_jobs_session_label_check
  check (session_label ~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$');

drop function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text, text);
create function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_session text, p_target uuid, p_revision integer,
  p_pages integer, p_model text, p_audio_extension text default null
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_limit integer;
  v_extension text := coalesce(p_audio_extension, 'jpg');
  v_test boolean;
begin
  if p_action not in ('marks-photo','substitution-photo','voice')
     or p_pages is null or p_pages not between 1 and 4
     or (p_action = 'voice' and (p_pages <> 1 or v_extension not in ('webm','m4a','wav')))
     or (p_action <> 'voice' and p_audio_extension is not null)
     or p_action is null
     or p_session is null or p_session !~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$' then
    raise exception 'invalid AI input';
  end if;
  select is_test_account into v_test from vppsone.staff_profiles where id = p_staff and is_active;
  if not found then
    raise exception 'invalid AI input';
  end if;
  -- A test account works only in a TEST session (D-340). Which real session a
  -- member of staff may open is the app's session rule (resolveSessionLabel).
  if v_test and p_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    raise exception 'AI session not allowed';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  select daily_limit into v_limit from vppsone.builtin_ai_settings where id = 1;
  if v_limit is null or (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= v_limit then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, p_session, p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.' || v_extension from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, text, uuid, integer, integer, text, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, text, uuid, integer, integer, text, text) to service_role;

create or replace function vppsone.apply_ai_cover_photo(
  p_job uuid, p_actor uuid, p_day date, p_timetable_day text,
  p_version uuid, p_bells integer, p_assignments jsonb, p_review jsonb
) returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session text;
  j vppsone.ai_jobs%rowtype;
  s vppsone.timetable_slots%rowtype;
  r record;
  v_existing jsonb;
  v_desired jsonb := '[]';
  v_previous_absences jsonb;
  v_absences jsonb;
  v_applied jsonb := '[]';
  v_keys text[] := '{}';
  v_row jsonb;
  v_written text;
  v_date_parts text[];
  v_starts timestamptz;
  v_first_start timestamptz;
  v_undo_until timestamptz;
  v_receipt jsonb;
  v_result jsonb;
begin
  if p_day is null or p_version is null or p_timetable_day is null or p_bells is null
     or length(btrim(p_timetable_day)) < 3
     or not starts_with(lower(to_char(p_day, 'FMDay')), lower(btrim(p_timetable_day)))
     or jsonb_typeof(p_assignments) is distinct from 'array'
     or jsonb_array_length(p_assignments) not between 1 and 60 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor
    and action = 'substitution-photo' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_session := j.session_label;
  -- A test account acts only in a TEST session (D-340), whatever the caller says.
  if exists (select 1 from vppsone.staff_profiles where id = p_actor and is_test_account)
     and v_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if j.status = 'applied' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  if j.status <> 'draft' or j.parsed_at is null or j.raw_output is null
     or j.roster_stamp is distinct from p_version::text || ':' || p_bells::text then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  if coalesce((select revision from vppsone.cover_days where session_label = v_session and day = p_day), 0)
       <> j.target_revision
     or not exists (select 1 from vppsone.timetable_versions
                    where id = p_version and session_label = v_session and status = 'published') then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- The ordinary absence table's unique key omits session_label. Prevent a
  -- concurrent insertion for the same staff/day from letting the upsert
  -- replace an absence belonging to another session.
  lock table vppsone.teacher_absences in share row exclusive mode;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]') into v_existing
  from vppsone.cover_duties d
  where d.session_label = v_session and d.day = p_day and d.status in ('assigned', 'needs_help');

  for r in
    select * from jsonb_to_recordset(p_assignments)
      as x(index integer, "absentId" uuid, "coveringId" uuid, "classId" uuid, period smallint, "needKey" text)
  loop
    if r."absentId" is null or r."coveringId" is null or r."absentId" = r."coveringId"
       or r."classId" is null or r.period is null or r.period not between 0 and 7
       or r.index is null or r.index not between 0 and 59 or r."needKey" is null
       or r."needKey" = any(v_keys) or v_applied @> jsonb_build_array(r.index) then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;

    v_row := j.raw_output->'rows'->r.index;
    v_written := btrim(translate(v_row->>'sourceDate', '०१२३४५६७८९０１２３４５６７８９', '01234567890123456789'));
    v_date_parts := regexp_match(v_written, '^([0-9]{1,2})[[:space:]]*([./-])[[:space:]]*([0-9]{1,2})[[:space:]]*\2[[:space:]]*([0-9]{4})$');
    if v_row->'unclear' is distinct from 'false'::jsonb or (
      v_written is distinct from p_day::text and
      (v_date_parts[4] || '-' || lpad(v_date_parts[3], 2, '0') || '-' || lpad(v_date_parts[1], 2, '0')) is distinct from p_day::text
    ) then
      return jsonb_build_object('ok', false, 'reason', 'source_date');
    end if;

    select (p_day + (period->>'starts')::time) at time zone 'Asia/Kolkata'
    into v_starts
    from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
    where b.session_label = v_session and b.is_current and b.revision = p_bells
      and (period->>'index')::smallint = r.period;
    if v_starts is null or v_starts <= clock_timestamp() + interval '2 minutes' then
      return jsonb_build_object('ok', false, 'reason', 'closed');
    end if;
    v_first_start := least(v_first_start, v_starts);

    select * into s from vppsone.timetable_slots ts
    where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
      and ts.class_id = r."classId" and ts.staff_profile_id = r."absentId"
      and not ts.parallel and not ts.shared;
    if not found or r."needKey" <>
       (s.day || '|P' || s.period || '|ordinary|' || s.subject_code || '|' || s.class_id || '|' || s.staff_profile_id || '#lesson')
       or (select count(*) from vppsone.timetable_slots ts
           where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
             and (ts.class_id = r."classId" or ts.staff_profile_id = r."absentId")) <> 1
       or (select count(*) from vppsone.staff_profiles sp
           where sp.id in (r."absentId", r."coveringId") and sp.is_active and sp.is_teaching) <> 2
       or not exists (select 1 from vppsone.timetable_slots ts
                      where ts.version_id = p_version and ts.staff_profile_id = r."coveringId")
       or exists (select 1 from vppsone.cover_policies cp
                  where cp.session_label = v_session and cp.staff_profile_id = r."coveringId"
                    and not (r.period = any(cp.allowed_periods)))
       or exists (select 1 from vppsone.teacher_leave l
                  where l.session_label = v_session and l.staff_profile_id = r."coveringId" and l.status = 'approved'
                    and p_day between l.from_day and l.to_day
                    and (l.span = 'full' or (l.span = 'first_half' and r.period <= 3)
                                         or (l.span = 'second_half' and r.period > 3)))
       or exists (select 1 from vppsone.teacher_absences a
                  where a.staff_profile_id = r."absentId" and a.day = p_day and a.session_label <> v_session)
       or exists (select 1 from vppsone.cover_duties d
                  where d.session_label = v_session and d.day = p_day and d.need_key = r."needKey"
                    and (d.status = 'assigned' or (d.covering_staff_id = r."coveringId" and d.cannot_cover_at is not null)))
    then
      return jsonb_build_object('ok', false, 'reason', 'conflict');
    end if;

    v_desired := v_desired || jsonb_build_object(
      'need_key', r."needKey", 'period', r.period, 'event_kind', 'ordinary',
      'class_ids', jsonb_build_array(s.class_id), 'class_labels', jsonb_build_array(s.class_label),
      'subject_code', s.subject_code, 'absent_staff_ids', jsonb_build_array(r."absentId"),
      'status', 'assigned', 'covering_staff_id', r."coveringId", 'source', 'manual', 'pinned', true
    );
    v_applied := v_applied || to_jsonb(r.index);
    v_keys := array_append(v_keys, r."needKey");
  end loop;

  -- Only append or fill the photographed duties. Keep every other duty,
  -- including unresolved duties and the coordinator's existing choices.
  v_desired := v_desired || coalesce(
    (select jsonb_agg(value) from jsonb_array_elements(v_existing) where not (value->>'need_key' = any(v_keys))),
    '[]'
  );
  with changes as (
    select (entry->>'absentId')::uuid as staff_id, array_agg(distinct (entry->>'period')::smallint) as periods
    from jsonb_array_elements(p_assignments) entry
    group by (entry->>'absentId')::uuid
  ), additions as (
    select c.staff_id, c.periods, a.periods as previous
    from changes c left join vppsone.teacher_absences a
      on a.staff_profile_id = c.staff_id and a.day = p_day and a.session_label = v_session
    where a.periods is null or not c.periods <@ a.periods
  )
  select coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous)), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous || periods)), '[]')
  into v_previous_absences, v_absences
  from additions;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', p_job, 'kind', 'substitution_photo', 'actor_staff_id', p_actor, 'session_label', v_session,
    'day', p_day, 'timetable_day', p_timetable_day, 'payload_hash', 'substitution-photo:' || p_job,
    'expected', jsonb_build_object('day_revision', j.target_revision, 'timetable_version_id', p_version, 'bells_revision', p_bells),
    'absences', v_absences, 'duties', v_desired
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  v_undo_until := clock_timestamp() + interval '2 minutes';
  if v_first_start <= v_undo_until
     or (select count(*) from vppsone.staff_notices where command_id = p_job and status = 'pending')
          <> jsonb_array_length(v_applied) then
    raise exception 'substitution photo was not fully applied';
  end if;
  update vppsone.staff_notices set next_attempt_at = v_undo_until
  where command_id = p_job and status = 'pending';

  v_result := jsonb_build_object('jobId', p_job, 'review', p_review, 'applied', v_applied, 'undoUntil', v_undo_until);
  update vppsone.ai_jobs set
    status = 'applied', applied_at = v_undo_until - interval '2 minutes', final_applied_data = v_result,
    reviewed_data = jsonb_build_object(
      'duties', v_existing, 'absences', v_previous_absences, 'dayRevision', v_receipt->'day_revision',
      'version', p_version, 'bells', p_bells, 'timetableDay', p_timetable_day
    )
  where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

create or replace function vppsone.undo_ai_cover_photo(p_job uuid, p_actor uuid, p_day date)
returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session text;
  j vppsone.ai_jobs%rowtype;
  v_undo_until timestamptz;
  v_notice_count integer;
  v_receipt jsonb;
  v_result jsonb;
begin
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor
    and action = 'substitution-photo' and status = 'applied' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_session := j.session_label;
  -- A test account acts only in a TEST session (D-340), whatever the caller says.
  if exists (select 1 from vppsone.staff_profiles where id = p_actor and is_test_account)
     and v_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if j.final_applied_data->>'undone' = 'true' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  v_undo_until := (j.final_applied_data->>'undoUntil')::timestamptz;
  if v_undo_until is null or clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  lock table vppsone.teacher_absences in share row exclusive mode;
  if exists (
    select 1 from vppsone.teacher_absences a
    join jsonb_array_elements(j.reviewed_data->'absences') prior on a.staff_profile_id = (prior->>'staff_profile_id')::uuid
    where a.day = p_day and a.session_label <> v_session
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- Teacher replies lock their duty before writing a notice. Use that same
  -- order here so any reply which already happened stays in the history and
  -- any reply to the withdrawn duty is refused after Undo commits.
  perform 1 from vppsone.cover_duties d where d.command_id = p_job order by d.id for update;

  -- Take the same notice locks the dispatcher claims, before the real-clock
  -- check. Once locked, the dispatcher skips these rows until Undo commits.
  perform 1 from vppsone.staff_notices n where n.command_id = p_job order by n.id for update;
  select count(*) into v_notice_count from vppsone.staff_notices
  where command_id = p_job and kind = 'cover_assigned';
  if clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if v_notice_count <> jsonb_array_length(j.final_applied_data->'applied') or exists (
    select 1 from vppsone.staff_notices n
    join vppsone.cover_duties d on d.id = n.duty_id
    where n.command_id = p_job
      and (n.status <> 'pending' or n.attempts <> 0 or n.next_attempt_at is distinct from v_undo_until
           or d.status <> 'assigned')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', gen_random_uuid(), 'kind', 'substitution_photo_undo', 'actor_staff_id', p_actor,
    'session_label', v_session, 'day', p_day, 'timetable_day', j.reviewed_data->'timetableDay',
    'payload_hash', 'substitution-photo-undo:' || p_job,
    'expected', jsonb_build_object(
      'day_revision', j.reviewed_data->'dayRevision',
      'timetable_version_id', j.reviewed_data->'version', 'bells_revision', j.reviewed_data->'bells'
    ),
    'absences', j.reviewed_data->'absences', 'duties', j.reviewed_data->'duties'
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  if exists (select 1 from vppsone.staff_notices where command_id = p_job and status <> 'cancelled') then
    raise exception 'substitution photo notices were not withdrawn';
  end if;
  v_result := j.final_applied_data || jsonb_build_object('undone', true);
  update vppsone.ai_jobs set final_applied_data = v_result where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

-- Create or replace keeps the grants; restated for the reader.
revoke all on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) from public, anon, authenticated;
revoke all on function vppsone.undo_ai_cover_photo(uuid, uuid, date) from public, anon, authenticated;
grant execute on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) to service_role;
grant execute on function vppsone.undo_ai_cover_photo(uuid, uuid, date) to service_role;

-- A notice for any duty that descends from an applied AI cover photo honours
-- its Undo hold, in every session.
create or replace function vppsone.inherit_ai_cover_photo_hold()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_hold timestamptz;
begin
  if new.duty_id is null then return new; end if;
  with recursive chain as (
    select id, supersedes, command_id from vppsone.cover_duties where id = new.duty_id
    union
    select d.id, d.supersedes, d.command_id from vppsone.cover_duties d join chain c on c.supersedes = d.id
  )
  select max((j.final_applied_data->>'undoUntil')::timestamptz) into v_hold
  from chain c join vppsone.ai_jobs j on c.command_id = j.id
  where j.action = 'substitution-photo' and j.status = 'applied';

  if v_hold > clock_timestamp() then new.next_attempt_at := greatest(new.next_attempt_at, v_hold); end if;
  return new;
end;
$$;
revoke all on function vppsone.inherit_ai_cover_photo_hold() from public, anon, authenticated;
