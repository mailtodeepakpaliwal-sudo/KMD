-- KMD One database setup — kmd_db_resume_ 3 of 5. Run in order, each once.
-- Files: 20261107070915_needs_attention_for_session.sql … 20261113205845_staff_helper_roles.sql

-- ======================================================== migrations/20261107070915_needs_attention_for_session.sql
-- The needs-attention read for ONE session (D-495).
--
-- `v_needs_attention` aggregates every attendance mark and every exam mark of
-- every session, and only then keeps the session asked for: the filter cannot
-- reach inside its CTEs. That cost ~0.5 s on a quiet database, and on a busy
-- one it ran past the 8 s statement timeout ("Could not read the attention
-- list", Academics and Student progress, 6-7 Nov 2026). Its marks rules are
-- also unused: the app works them out itself from dated exams (`marksFlags`).
--
-- This function narrows to the session first and returns only what the app
-- reads: attendance and open notes, for every enrolled child who has either.
-- Same rules as the view (75 % over at least 5 days; 2+ open non-praise
-- notes). The view stays for anything else that reads it.
create or replace function vppsone.needs_attention_for_session(p_session text)
returns table (
  student_id uuid,
  class_id uuid,
  attendance_pct numeric,
  days_counted bigint,
  open_notes integer,
  reasons text[]
)
language sql stable security invoker set search_path = ''
as $$
  with att as (
    select m.student_id,
           count(c.credit) as days_counted,
           round(100.0 * sum(c.credit) / nullif(count(c.credit), 0), 1) as attendance_pct
    from vppsone.attendance_registers r
    join vppsone.attendance_marks m on m.register_id = r.id
    left join vppsone.attendance_rules ar on ar.session_label = r.session_label
    cross join lateral (
      select case m.status
               when 'present' then 1.0
               when 'late' then 1.0
               when 'half_day' then coalesce(ar.half_day_credit, 0.5)
               when 'absent' then 0.0
               else null
             end as credit
    ) c
    where r.session_label = p_session and r.status = 'submitted' and r.period is null
    group by m.student_id
  ),
  notes_open as (
    select n.student_id, count(*)::integer as open_notes
    from vppsone.notes n
    join vppsone.note_kinds k on k.id = n.kind_id
    where n.session_label = p_session
      and n.student_id is not null
      and n.status in ('open', 'working')
      and k.tone <> 'good'
    group by n.student_id
  )
  select e.student_id,
         e.class_id,
         att.attendance_pct,
         coalesce(att.days_counted, 0) as days_counted,
         coalesce(o.open_notes, 0) as open_notes,
         array_remove(array[
           case when att.attendance_pct < 75 and att.days_counted >= 5 then 'attendance' end,
           case when coalesce(o.open_notes, 0) >= 2 then 'notes' end
         ], null) as reasons
  from vppsone.enrolments e
  left join att on att.student_id = e.student_id
  left join notes_open o on o.student_id = e.student_id
  where e.session_label = p_session
    and e.status = 'enrolled'
    and (att.student_id is not null or o.student_id is not null)
$$;

revoke all on function vppsone.needs_attention_for_session(text) from public, anon, authenticated;
grant execute on function vppsone.needs_attention_for_session(text) to service_role;

-- ======================================================== migrations/20261107075126_assist_log_provider.sql
-- Which provider wrote each AI helper draft (D-496).
--
-- The free models (NVIDIA, OpenRouter, Gemini Free) now write the open tasks
-- for everyone, and every text task for a test account. `model` alone cannot
-- tell Gemini Free from Gemini Paid (both can run the same model), so each
-- row now names its provider, and Settings -> AI helper can show how many
-- drafts were free and roughly what they would have cost on the paid models.
--
-- Rows written before this migration have no provider; the page counts them
-- as paid. Still no prompt and no answer: the log stays metadata (D-324).
--
-- Rollback: drop function vppsone.assist_usage_by_provider(timestamptz);
--           alter table vppsone.assist_log drop column provider;

alter table vppsone.assist_log
  add column if not exists provider text
  constraint assist_log_provider_known
  check (provider in ('nvidia-free', 'openrouter-free', 'gemini-free', 'anthropic', 'openai', 'gemini-paid'));

comment on column vppsone.assist_log.provider is
  'The stage that wrote the draft, or the last one tried when none did (D-496). Null on rows written before 7 Nov 2026.';

-- Settings -> AI helper: drafts and tokens per provider and task since a moment.
create or replace function vppsone.assist_usage_by_provider(p_since timestamptz)
returns table (
  provider text,
  task text,
  drafts integer,
  input_tokens bigint,
  output_tokens bigint,
  cost_usd numeric
)
language sql
stable
set search_path = ''
as $$
  select
    l.provider,
    l.task,
    count(*)::integer,
    coalesce(sum(l.input_tokens), 0)::bigint,
    coalesce(sum(l.output_tokens), 0)::bigint,
    coalesce(sum(l.cost_usd), 0)
  from vppsone.assist_log l
  where l.created_at >= p_since and l.outcome = 'drafted'
  group by l.provider, l.task;
$$;

revoke all on function vppsone.assist_usage_by_provider(timestamptz) from public, anon, authenticated;
grant execute on function vppsone.assist_usage_by_provider(timestamptz) to service_role;

-- ======================================================== migrations/20261107100619_ai_overview.sql
-- Settings -> AI helper: one page for every AI job in One (D-501).
--
-- The written drafts (`assist_log`) and the photo and voice jobs (`ai_jobs`)
-- were counted on two different settings pages. This function returns both,
-- grouped small, so one page can show which model did which job, the route
-- each job took and what it cost:
--
--   helper   drafts per task, model, provider, outcome and decision
--   builtin  photo and voice jobs per action, model, provider and status
--   tries    every attempt a photo or voice job made, per provider (the fallbacks)
--   days     jobs per school day (IST)
--   recent   the last 14 jobs of either kind, newest first, with who asked
--
-- Metadata only, as before: no prompt, answer, transcript or photo. Test
-- accounts and TEST sessions are flagged so the page can say which jobs were
-- practice. Service role only, like the other usage functions.
--
-- Rollback: drop function vppsone.ai_overview(timestamptz);

create or replace function vppsone.ai_overview(p_since timestamptz)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
with helper as materialized (
  select
    l.created_at, l.task, l.model, l.provider, l.outcome, l.decision,
    coalesce(l.cost_usd, 0) as cost_usd,
    coalesce(l.input_tokens, 0) as input_tokens,
    coalesce(l.output_tokens, 0) as output_tokens,
    coalesce(sp.is_test_account, false) as test
  from vppsone.assist_log l
  left join vppsone.staff_profiles sp on sp.id = l.staff_profile_id
  where l.created_at >= p_since
), builtin as materialized (
  select
    j.created_at, j.action, j.model, j.provider, j.status, coalesce(j.edited, false) as edited,
    coalesce(j.estimated_cost_inr, 0) as cost_inr, j.attempts,
    (coalesce(j.session_label, '') ~ '^(TEST|UAT|DEMO)-' or coalesce(sp.is_test_account, false)) as test
  from vppsone.ai_jobs j
  left join vppsone.staff_profiles sp on sp.id = j.staff_profile_id
  where j.created_at >= p_since
), recent as (
  (
    select
      l.created_at as at, 'helper' as kind, l.task, l.model, l.provider, l.outcome,
      l.decision, null::text as status, coalesce(l.cost_usd, 0) as cost_usd, 0::numeric as cost_inr,
      '[]'::jsonb as attempts, coalesce(sp.is_test_account, false) as test, sp.display_name as who
    from vppsone.assist_log l
    left join vppsone.staff_profiles sp on sp.id = l.staff_profile_id
    order by l.created_at desc
    limit 14
  )
  union all
  (
    select
      j.created_at, 'builtin', j.action, j.model, j.provider, null, null, j.status, 0,
      coalesce(j.estimated_cost_inr, 0),
      case when jsonb_typeof(j.attempts) = 'array' then j.attempts else '[]'::jsonb end,
      (coalesce(j.session_label, '') ~ '^(TEST|UAT|DEMO)-' or coalesce(sp.is_test_account, false)),
      sp.display_name
    from vppsone.ai_jobs j
    left join vppsone.staff_profiles sp on sp.id = j.staff_profile_id
    order by j.created_at desc
    limit 14
  )
)
select jsonb_build_object(
  'helper', coalesce((
    select jsonb_agg(to_jsonb(g)) from (
      select task, model, provider, outcome, decision, test,
        count(*)::integer as n,
        sum(cost_usd) as cost_usd,
        sum(input_tokens)::bigint as input_tokens,
        sum(output_tokens)::bigint as output_tokens
      from helper
      group by task, model, provider, outcome, decision, test
    ) g
  ), '[]'::jsonb),
  'builtin', coalesce((
    select jsonb_agg(to_jsonb(g)) from (
      select action as task, model, provider, status, edited, test,
        count(*)::integer as n,
        sum(cost_inr) as cost_inr
      from builtin
      group by action, model, provider, status, edited, test
    ) g
  ), '[]'::jsonb),
  'tries', coalesce((
    select jsonb_agg(to_jsonb(g)) from (
      select b.action as task, a->>'provider' as provider, a->>'model' as model, a->>'outcome' as outcome,
        count(*)::integer as n,
        sum(case when jsonb_typeof(a->'costInr') = 'number' then (a->>'costInr')::numeric else 0 end) as cost_inr
      from builtin b
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(b.attempts) = 'array' then b.attempts else '[]'::jsonb end
      ) a
      where a->>'provider' is not null
      group by b.action, a->>'provider', a->>'model', a->>'outcome'
    ) g
  ), '[]'::jsonb),
  'days', coalesce((
    select jsonb_agg(to_jsonb(g) order by g.day) from (
      select to_char(created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD') as day,
        kind, provider, model, zero_cost, count(*)::integer as n
      from (
        select created_at, 'helper' as kind, provider, model, cost_usd = 0 as zero_cost from helper
        union all
        select created_at, 'builtin', provider, model, cost_inr = 0 from builtin
      ) x
      group by 1, kind, provider, model, zero_cost
    ) g
  ), '[]'::jsonb),
  'recent', coalesce((
    select jsonb_agg(to_jsonb(r) order by r.at desc) from (
      select * from recent order by at desc limit 14
    ) r
  ), '[]'::jsonb)
);
$$;

revoke all on function vppsone.ai_overview(timestamptz) from public, anon, authenticated;
grant execute on function vppsone.ai_overview(timestamptz) to service_role;

-- ======================================================== migrations/20261107142035_fees_photo_copies_and_nightly_identity.sql
-- Two changes for the real year (owner, 7 Nov 2026).
--
-- 1. Teachers see their children's photos (D-511). The photos are kept in
--    Fees, and Fees shares them through One only with office staff. Janmejay
--    chose that One keeps its own copy, made when an admin taps "Refresh
--    roster now": `student_photos.source` gains 'fees' for those copies
--    (`source_ref` holds the Fees photo path the copy was made from, so a
--    changed photo is copied again). A photo a person placed in One is never
--    replaced from Fees. Nothing is written to Fees.
--
-- 2. The roster identity follows the nightly copy (D-512). D-457 (6 Nov) made
--    the Fees roster copy nightly and 20261106162701 let four readers trust a
--    roster checked within 26 hours, but `fees_identity_students` and
--    `fees_identity_classes` kept a five-minute window. Every real-year
--    command that checks the current roster through them (saving attendance,
--    saving marks, teacher tasks, Sampark rows, notices, placing a photo, and
--    the test-session fence on six tables) refused real children whenever the
--    last check was more than five minutes old, which since 6 Nov is nearly
--    always. The same 26 hours as BRIDGE_FRESH_FOR_MS. The views are patched by
--    exact text and the migration fails unless each holds the old check once.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

alter table vppsone.student_photos drop constraint student_photos_source;
alter table vppsone.student_photos add constraint student_photos_source
  check (source in ('camera', 'file', 'folder', 'fees'));
comment on column vppsone.student_photos.source is
  'camera, file or folder: placed in One by a person. fees: copied from the Fees app''s photo on an admin''s "Refresh roster now" (source_ref is the Fees photo path).';

do $$
declare
  v text;
  d text;
  old_check constant text := '''00:05:00''::interval';
  new_check constant text := '''26:00:00''::interval';
begin
  perform set_config('search_path', 'public', true);
  foreach v in array array['vppsone.fees_identity_classes', 'vppsone.fees_identity_students'] loop
    d := pg_get_viewdef(v::regclass, true);
    if (length(d) - length(replace(d, old_check, ''))) / length(old_check) <> 1 then
      raise exception 'nightly identity: % does not hold the five-minute check exactly once', v;
    end if;
    d := regexp_replace(replace(d, old_check, new_check), ';\s*$', '');
    execute format('create or replace view %s with (security_invoker = true) as %s', v, d);
    if (select reloptions from pg_class where oid = v::regclass) is distinct from array['security_invoker=true'] then
      raise exception 'nightly identity: % lost security_invoker', v;
    end if;
  end loop;
end;
$$;

commit;

-- ======================================================== migrations/20261107164847_view_as_person.sql
-- See One as a chosen member of staff (D-520, owner request 7 Nov 2026: "as an
-- admin ... I should also have an access to see and select which teacher or
-- which academic coordinator ... and their real data can be shown to me, only
-- the admin").
--
-- The app draws every screen from the chosen person's own profile, role and
-- classes (src/platform/auth/view-as-subject.ts). Most screens read with the
-- service role and filter by that person's id, so they are already right.
-- What this migration adds is the rest: the reads that go through the
-- signed-in administrator's own session, where row level security decides
-- what comes back. Without it a teacher's Students list, seen by an
-- administrator, would show every child in the school instead of hers.
--
-- 1. vppsone.view_as_log: who looked as whom, when, and how it ended. A row
--    is also the grant: the database honours a "see as" request only while
--    the administrator holds an open, unexpired row for that person (two
--    hours, the same as the app's cookie).
--
-- 2. vppsone.view_as_subject_id(): the chosen person, or null. Non-null only
--    when ALL of these hold:
--      - the request carries the `x-vx-view-as` header (the app sets it from
--        its view-as cookie on the signed-in person's own client);
--      - the transaction is READ ONLY. PostgREST opens one for every GET and
--        for every stable function, and a read-only transaction cannot write
--        anything at all, so nothing can ever be saved under somebody else's
--        name. Every write runs read-write and is the administrator's own;
--        the app refuses those too while it is showing another person;
--      - auth.uid() is an active administrator holding an open, unexpired log
--        row for that person, who is active and not an administrator. A test
--        administrator may only look as a test account (a QA key never opens
--        a real person's screens); a real administrator may look as real
--        staff or as a practice account, whose screens show TEST data only.
--
-- 3. The row-security helpers follow it. current_staff_profile_id(),
--    reads_every_class(), staff_can(), staff_can_any() and
--    current_is_test_account() answer for the chosen person (my_class_keys(),
--    my_held_class_keys() and is_active_staff() already go through
--    current_staff_profile_id()). is_admin_staff() and is_real_admin() answer
--    false while showing another person, because that person is never an
--    administrator; so the test-session fence reads as it does for them. With
--    no header, every one of them gives exactly the answer it gave before.
--    my_permissions() is deliberately left alone: it is how the app reads the
--    signed-in administrator's own permissions. The fee schema's helpers are
--    not touched.
--
-- Rollback: re-run the seven helper bodies as they were (current_staff_profile_id,
-- reads_every_class, staff_can, staff_can_any from
-- 20261004031630_staff_authority_and_scoped_reads.sql; is_admin_staff from
-- 20261011090858_vx_sensitive_notes_scope.sql; is_real_admin and
-- current_is_test_account from 20261030155339_test_session_visibility.sql),
-- then drop function
-- vppsone.view_as_end(text), vppsone.view_as_begin(uuid),
-- vppsone.view_as_subject_id(); drop table vppsone.view_as_log.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

create table if not exists vppsone.view_as_log (
  id uuid primary key default gen_random_uuid(),
  actor_staff_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  actor_user_id uuid not null,
  subject_staff_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  is_test boolean not null default false,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 hours'),
  ended_at timestamptz,
  end_reason text,
  constraint view_as_log_not_self check (actor_staff_id <> subject_staff_id),
  constraint view_as_log_end_reason check (end_reason is null or end_reason in ('back', 'switched', 'signed_out', 'expired')),
  constraint view_as_log_end_pair check ((ended_at is null) = (end_reason is null))
);
comment on table vppsone.view_as_log is
  'D-520: an administrator seeing One as another member of staff. An open, unexpired row is also the grant vppsone.view_as_subject_id() checks. Written only by view_as_begin() / view_as_end().';

create index if not exists view_as_log_open_idx
  on vppsone.view_as_log (actor_user_id, subject_staff_id)
  where ended_at is null;
create index if not exists view_as_log_started_idx
  on vppsone.view_as_log (started_at desc);

alter table vppsone.view_as_log enable row level security;
-- Read on the service role, after the app has checked the reader is an
-- administrator. Written only by the two functions below.
grant select on vppsone.view_as_log to service_role;

create or replace function vppsone.view_as_subject_id()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_headers text := current_setting('request.headers', true);
  v_raw text;
  v_subject uuid;
begin
  -- The common path: no header, no work.
  if v_headers is null or position('x-vx-view-as' in v_headers) = 0 then
    return null;
  end if;
  -- Only a read-only transaction may ever be drawn as somebody else.
  if current_setting('transaction_read_only', true) is distinct from 'on' then
    return null;
  end if;
  v_raw := v_headers::json ->> 'x-vx-view-as';
  if v_raw is null or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return null;
  end if;
  select l.subject_staff_id into v_subject
  from vppsone.view_as_log l
  join vppsone.staff_profiles a on a.id = l.actor_staff_id
  join vppsone.staff_profiles s on s.id = l.subject_staff_id
  where l.actor_user_id = (select auth.uid())
    and l.subject_staff_id = v_raw::uuid
    and l.ended_at is null
    and l.expires_at > now()
    and a.user_id = l.actor_user_id
    and a.is_active
    and a.role = 'admin'
    and s.is_active
    and s.role <> 'admin'
    and (s.is_test_account or not a.is_test_account)
  order by l.started_at desc
  limit 1;
  return v_subject;
end;
$function$;
comment on function vppsone.view_as_subject_id() is
  'D-520: the member of staff an administrator is seeing One as, in a READ ONLY transaction carrying x-vx-view-as and backed by an open view_as_log row; else null.';
revoke all on function vppsone.view_as_subject_id() from public, anon, authenticated;
grant execute on function vppsone.view_as_subject_id() to service_role;

create or replace function vppsone.view_as_begin(p_subject uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor vppsone.staff_profiles%rowtype;
  v_subject vppsone.staff_profiles%rowtype;
  v_id uuid;
begin
  select * into v_actor from vppsone.staff_profiles sp
  where sp.user_id = (select auth.uid()) and sp.is_active;
  if v_actor.id is null or v_actor.role <> 'admin' then
    raise exception 'Only an administrator can see One as another person.' using errcode = '42501';
  end if;
  select * into v_subject from vppsone.staff_profiles sp where sp.id = p_subject;
  if v_subject.id is null or not v_subject.is_active then
    raise exception 'That person is not an active member of staff.' using errcode = '22023';
  end if;
  if v_subject.id = v_actor.id or v_subject.role = 'admin' then
    raise exception 'Choose a member of staff who is not an administrator.' using errcode = '22023';
  end if;
  if v_actor.is_test_account and not v_subject.is_test_account then
    raise exception 'A test account can only see One as another test account.' using errcode = '42501';
  end if;

  update vppsone.view_as_log
     set ended_at = least(now(), expires_at),
         end_reason = case when expires_at <= now() then 'expired' else 'switched' end
   where actor_user_id = v_actor.user_id and ended_at is null;

  insert into vppsone.view_as_log (actor_staff_id, actor_user_id, subject_staff_id, is_test)
  values (v_actor.id, v_actor.user_id, v_subject.id, v_subject.is_test_account)
  returning id into v_id;
  return v_id;
end;
$function$;
comment on function vppsone.view_as_begin(uuid) is
  'D-520: the signed-in administrator starts seeing One as p_subject (active, not an administrator; a test administrator only as a test account). Ends any view they had open. Two hours.';
revoke all on function vppsone.view_as_begin(uuid) from public, anon;
grant execute on function vppsone.view_as_begin(uuid) to authenticated, service_role;

create or replace function vppsone.view_as_end(p_reason text default 'back')
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  if p_reason is null or p_reason not in ('back', 'switched', 'signed_out') then
    raise exception 'Unknown reason for ending the view.' using errcode = '22023';
  end if;
  update vppsone.view_as_log
     set ended_at = least(now(), expires_at),
         end_reason = case when expires_at <= now() then 'expired' else p_reason end
   where actor_user_id = (select auth.uid()) and ended_at is null;
end;
$function$;
comment on function vppsone.view_as_end(text) is
  'D-520: the signed-in person stops seeing One as anybody else (back, switched or signed_out).';
revoke all on function vppsone.view_as_end(text) from public, anon;
grant execute on function vppsone.view_as_end(text) to authenticated, service_role;

-- The helpers. Each keeps its old answer when view_as_subject_id() is null.

create or replace function vppsone.current_staff_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    vppsone.view_as_subject_id(),
    (select sp.id from vppsone.staff_profiles sp
      where sp.user_id = (select auth.uid()) and sp.is_active)
  )
$function$;

create or replace function vppsone.reads_every_class()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from vppsone.staff_profiles sp
    where sp.id = vppsone.current_staff_profile_id() and sp.is_active
      and sp.role in ('admin', 'office', 'academic_coordinator', 'exam_coordinator')
  )
$function$;

create or replace function vppsone.staff_can(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = vppsone.current_staff_profile_id() and sp.is_active and rp.permission = p_permission
  )
$function$;

create or replace function vppsone.staff_can_any(p_permissions text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = vppsone.current_staff_profile_id() and sp.is_active and rp.permission = any (p_permissions)
  )
$function$;

create or replace function vppsone.current_is_test_account()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    (select sp.is_test_account from vppsone.staff_profiles sp
      where sp.id = vppsone.current_staff_profile_id() and sp.is_active),
    false
  )
$function$;

create or replace function vppsone.is_admin_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select vppsone.view_as_subject_id() is null and exists (
    select 1 from vppsone.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'admin'
  )
$function$;

create or replace function vppsone.is_real_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select vppsone.view_as_subject_id() is null and exists (
    select 1 from vppsone.staff_profiles sp
    where sp.user_id = (select auth.uid())
      and sp.is_active
      and sp.role = 'admin'
      and not sp.is_test_account
  )
$function$;

commit;

-- ======================================================== migrations/20261107165000_transport.sql
-- Transport: routes, drivers and bus trips (owner, 7 Nov 2026, D-521).
--
-- Janmejay: "I can only see On bus ... there are so many transport routes ...
-- see the students on different times of routes, and assign drivers on the
-- routes, so I can know which driver is going on which route."
--
-- Fees stays the authority for which route a child is on (students.
-- transport_route_id, copied nightly into fees_bridge_students). What One adds
-- is everything Fees never held:
--
--  * fees_bridge_routes: the route NAMES, copied from Fees' machine-only
--    GET /api/one/v1/sync/routes (Fees PR 151). Names, codes and flags only,
--    never a fee. Replaced whole by fees_bridge_replace_routes(), never edited
--    here. TEST sessions keep reading their own local route list.
--  * transport_drivers: who drives (name, phone), per session.
--  * transport_trips: one bus run at one time of day (morning pickup,
--    afternoon drop, or another run), with its driver, helper and bus.
--  * transport_trip_stops: the routes (villages) that run reaches, in order,
--    each with an optional time. A route's children ride every trip that
--    stops there.
--
-- Session-labelled like everything else in One, so TEST-2026-27 has its own
-- drivers and trips and a test account can never touch the real ones. One's
-- writes are service role (D-179), so the app's assertSessionWritable is the
-- fence that counts; the restrictive test_session_fence policies below hold
-- the PostgREST path as on the 87 other tables (20261030155339). Nothing here
-- reads or writes the fee tables.
--
-- Rollback:
--   drop function vppsone.transport_save_trip(uuid, text, jsonb, timestamptz);
--   drop function vppsone.fees_bridge_replace_routes(jsonb);
--   drop table vppsone.transport_trip_stops, vppsone.transport_trips,
--              vppsone.transport_drivers, vppsone.fees_bridge_route_sync,
--              vppsone.fees_bridge_routes;
--   (and the rows of 20261107165001_transport_role_permissions.sql)
begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

/* ----------------------------------------------------------- route names */

create table vppsone.fees_bridge_routes (
  id uuid primary key,
  name text not null check (length(btrim(name)) between 1 and 200),
  code text check (code is null or length(code) <= 50),
  is_active boolean not null default true,
  -- Fees' "No Transport" row: a placeholder, not a bus (isSentinelNoTransportRoute).
  placeholder boolean not null default false,
  refreshed_at timestamptz not null default now()
);
comment on table vppsone.fees_bridge_routes is
  'Transport route names copied from Fees (GET /api/one/v1/sync/routes). Replaced whole by fees_bridge_replace_routes(); never edited in One. No fee column.';

create table vppsone.fees_bridge_route_sync (
  id boolean primary key default true check (id),
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code ~ '^[a-z0-9_]{1,64}$')
);
comment on table vppsone.fees_bridge_route_sync is
  'When One last asked Fees for route names, so a page that finds a name missing asks at most once in ten minutes.';
insert into vppsone.fees_bridge_route_sync (id) values (true);

-- The list Fees answered replaces the copy, all of it or none of it. An empty
-- list is refused rather than taken to mean "the school has no routes".
create function vppsone.fees_bridge_replace_routes(p_routes jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  if jsonb_typeof(p_routes) is distinct from 'array'
     or jsonb_array_length(p_routes) = 0
     or jsonb_array_length(p_routes) > 500 then
    raise exception 'transport:bad_routes';
  end if;
  if exists (
       select 1 from jsonb_array_elements(p_routes) as r
        where nullif(r->>'id', '') is null or nullif(btrim(coalesce(r->>'name', '')), '') is null
     )
     or (select count(distinct r->>'id') from jsonb_array_elements(p_routes) as r) <> jsonb_array_length(p_routes) then
    raise exception 'transport:bad_routes';
  end if;

  insert into vppsone.fees_bridge_routes as t (id, name, code, is_active, placeholder, refreshed_at)
  select (r->>'id')::uuid,
         btrim(r->>'name'),
         nullif(btrim(coalesce(r->>'code', '')), ''),
         coalesce((r->>'isActive')::boolean, true),
         coalesce((r->>'placeholder')::boolean, false),
         now()
    from jsonb_array_elements(p_routes) as r
  on conflict (id) do update
    set name = excluded.name, code = excluded.code, is_active = excluded.is_active,
        placeholder = excluded.placeholder, refreshed_at = excluded.refreshed_at;
  get diagnostics v_count = row_count;

  delete from vppsone.fees_bridge_routes as t
   where not exists (select 1 from jsonb_array_elements(p_routes) as r where (r->>'id')::uuid = t.id);

  update vppsone.fees_bridge_route_sync
     set last_success_at = now(), last_error_code = null
   where id;

  return v_count;
end;
$$;
revoke all on function vppsone.fees_bridge_replace_routes(jsonb) from public, anon, authenticated;
grant execute on function vppsone.fees_bridge_replace_routes(jsonb) to service_role;

/* ---------------------------------------------------------------- drivers */

create table vppsone.transport_drivers (
  id uuid primary key default gen_random_uuid(),
  session_label text not null check (session_label ~ '^(TEST-|UAT-|DEMO-)?[0-9]{4}-[0-9]{2}$'),
  full_name text not null check (length(btrim(full_name)) between 1 and 80),
  phone text check (phone is null or phone ~ '^[0-9]{10}$'),
  notes text check (notes is null or length(notes) <= 300),
  created_by uuid references vppsone.staff_profiles(id) on delete set null,
  updated_by uuid references vppsone.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- The pair the trips' composite key points at, so a trip can only name a
  -- driver of its own session.
  unique (id, session_label)
);
create index transport_drivers_session on vppsone.transport_drivers (session_label);
comment on table vppsone.transport_drivers is
  'Who drives the school''s buses, per session. Written by One''s Transport screen (transport:manage).';

/* ------------------------------------------------------------------ trips */

create table vppsone.transport_trips (
  id uuid primary key default gen_random_uuid(),
  session_label text not null check (session_label ~ '^(TEST-|UAT-|DEMO-)?[0-9]{4}-[0-9]{2}$'),
  shift text not null check (shift in ('morning', 'afternoon', 'other')),
  starts_at time not null,
  bus_name text not null check (length(btrim(bus_name)) between 1 and 40),
  vehicle_no text check (vehicle_no is null or length(btrim(vehicle_no)) between 1 and 20),
  driver_id uuid,
  helper_name text check (helper_name is null or length(btrim(helper_name)) between 1 and 80),
  helper_phone text check (helper_phone is null or helper_phone ~ '^[0-9]{10}$'),
  notes text check (notes is null or length(notes) <= 300),
  created_by uuid references vppsone.staff_profiles(id) on delete set null,
  updated_by uuid references vppsone.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Removing a driver leaves the bus without one; the trip and its session stay.
  foreign key (driver_id, session_label)
    references vppsone.transport_drivers (id, session_label) on delete set null (driver_id)
);
create index transport_trips_session on vppsone.transport_trips (session_label, shift, starts_at);
create index transport_trips_driver on vppsone.transport_trips (driver_id) where driver_id is not null;
comment on table vppsone.transport_trips is
  'One bus run at one time of day: morning pickup, afternoon drop or another run. Its villages are transport_trip_stops.';

create table vppsone.transport_trip_stops (
  trip_id uuid not null references vppsone.transport_trips(id) on delete cascade,
  -- A Fees transport route id (fees_bridge_routes, or the local list in a TEST
  -- session). Not a foreign key: the names are a copy that is replaced whole.
  route_id uuid not null,
  position smallint not null check (position between 1 and 60),
  stop_time time,
  primary key (trip_id, route_id),
  unique (trip_id, position)
);
create index transport_trip_stops_route on vppsone.transport_trip_stops (route_id);
comment on table vppsone.transport_trip_stops is
  'The routes (villages) a trip reaches, in order, each with an optional time.';

/* --------------------------------------------------------- the one writer */

-- Saves a trip and its stops together, so a bus is never left half-saved.
-- p_trip: { id?, shift, startsAt "HH:MM", busName, vehicleNo?, driverId?,
--           helperName?, helperPhone?, notes?, stops: [{ routeId, stopTime? }] }
-- in the order the bus reaches them. With an id, the trip must already be in
-- p_session; with p_expected (the updated_at the editor opened), a trip
-- somebody else changed meanwhile is refused instead of overwritten.
create function vppsone.transport_save_trip(
  p_actor uuid,
  p_session text,
  p_trip jsonb,
  p_expected timestamptz default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_trip->>'id', '')::uuid;
  v_driver uuid := nullif(p_trip->>'driverId', '')::uuid;
  v_stops jsonb := coalesce(p_trip->'stops', '[]'::jsonb);
  v_current timestamptz;
  v_saved timestamptz;
begin
  if p_session is null or p_session !~ '^(TEST-|UAT-|DEMO-)?[0-9]{4}-[0-9]{2}$' then
    raise exception 'transport:bad_request';
  end if;
  if jsonb_typeof(v_stops) <> 'array' or jsonb_array_length(v_stops) > 40 then
    raise exception 'transport:bad_request';
  end if;
  if (select count(distinct s->>'routeId') from jsonb_array_elements(v_stops) s) <> jsonb_array_length(v_stops) then
    raise exception 'transport:duplicate_stop';
  end if;
  if v_driver is not null and not exists (
    select 1 from vppsone.transport_drivers d where d.id = v_driver and d.session_label = p_session
  ) then
    raise exception 'transport:driver_missing';
  end if;

  if v_id is null then
    insert into vppsone.transport_trips (session_label, shift, starts_at, bus_name, vehicle_no, driver_id,
                                         helper_name, helper_phone, notes, created_by, updated_by)
    values (p_session, p_trip->>'shift', (p_trip->>'startsAt')::time, btrim(p_trip->>'busName'),
            nullif(btrim(coalesce(p_trip->>'vehicleNo', '')), ''), v_driver,
            nullif(btrim(coalesce(p_trip->>'helperName', '')), ''), nullif(p_trip->>'helperPhone', ''),
            nullif(btrim(coalesce(p_trip->>'notes', '')), ''), p_actor, p_actor)
    returning id, updated_at into v_id, v_saved;
  else
    select updated_at into v_current from vppsone.transport_trips
     where id = v_id and session_label = p_session
     for update;
    if not found then raise exception 'transport:not_found'; end if;
    if p_expected is not null and v_current <> p_expected then raise exception 'transport:changed'; end if;
    update vppsone.transport_trips
       set shift = p_trip->>'shift', starts_at = (p_trip->>'startsAt')::time,
           bus_name = btrim(p_trip->>'busName'),
           vehicle_no = nullif(btrim(coalesce(p_trip->>'vehicleNo', '')), ''), driver_id = v_driver,
           helper_name = nullif(btrim(coalesce(p_trip->>'helperName', '')), ''),
           helper_phone = nullif(p_trip->>'helperPhone', ''),
           notes = nullif(btrim(coalesce(p_trip->>'notes', '')), ''),
           updated_by = p_actor, updated_at = greatest(clock_timestamp(), v_current + interval '1 millisecond')
     where id = v_id
    returning updated_at into v_saved;
    delete from vppsone.transport_trip_stops where trip_id = v_id;
  end if;

  insert into vppsone.transport_trip_stops (trip_id, route_id, position, stop_time)
  select v_id, (s.value->>'routeId')::uuid, s.ordinality::smallint, nullif(s.value->>'stopTime', '')::time
    from jsonb_array_elements(v_stops) with ordinality as s;

  return jsonb_build_object('id', v_id, 'updatedAt', v_saved);
end;
$$;
revoke all on function vppsone.transport_save_trip(uuid, text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function vppsone.transport_save_trip(uuid, text, jsonb, timestamptz) to service_role;

/* ---------------------------------------------------- access and the fence */

alter table vppsone.fees_bridge_routes enable row level security;
alter table vppsone.fees_bridge_route_sync enable row level security;
alter table vppsone.transport_drivers enable row level security;
alter table vppsone.transport_trips enable row level security;
alter table vppsone.transport_trip_stops enable row level security;

revoke all on vppsone.fees_bridge_routes, vppsone.fees_bridge_route_sync, vppsone.transport_drivers,
  vppsone.transport_trips, vppsone.transport_trip_stops from anon, authenticated;
grant all on vppsone.fees_bridge_routes, vppsone.fees_bridge_route_sync, vppsone.transport_drivers,
  vppsone.transport_trips, vppsone.transport_trip_stops to service_role;

create policy test_session_fence on vppsone.transport_drivers as restrictive for all to authenticated
  using ((vppsone.is_test_session(session_label) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()))
  with check ((vppsone.is_test_session(session_label) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()));
create policy test_session_fence on vppsone.transport_trips as restrictive for all to authenticated
  using ((vppsone.is_test_session(session_label) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()))
  with check ((vppsone.is_test_session(session_label) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()));
create policy test_session_fence on vppsone.transport_trip_stops as restrictive for all to authenticated
  using (exists (select 1 from vppsone.transport_trips p where p.id = transport_trip_stops.trip_id
    and ((vppsone.is_test_session(p.session_label) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()))))
  with check (exists (select 1 from vppsone.transport_trips p where p.id = transport_trip_stops.trip_id
    and ((vppsone.is_test_session(p.session_label) = (select vppsone.current_is_test_account())) or (select vppsone.is_real_admin()))));

commit;

-- ======================================================== migrations/20261107165001_transport_role_permissions.sql
-- Transport's two switches on Staff -> Roles (owner, 7 Nov 2026, D-521).
--
-- transport:view   open Transport: routes, bus times, drivers and the
--                  children on each bus.
-- transport:manage add and change drivers and bus trips.
--
-- On for the admin (every permission is, and set_role_permissions only knows
-- a permission the Admin column holds) and for the office, whose Transport
-- tile this replaces. Any other role is one switch away on Staff -> Roles.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'transport:view'),
  ('admin', 'transport:manage'),
  ('office', 'transport:view'),
  ('office', 'transport:manage')
on conflict do nothing;

-- ======================================================== migrations/20261107172553_certificate_requests.sql
-- Certificates a teacher asks for, and an approver's answer (D-542).
--
-- A teacher prepares nothing. The request names a child in one of the
-- teacher's own classes, a document (study, character or date of birth; a TC
-- stays with the office, which owns the leaving workflow) and an optional
-- purpose. An approver's "Approve and sign" issues the document through the
-- existing issue path under the approver's own name, so it carries the
-- principal's printed signature and the school seal (D-541), and the request
-- then points at that stored original. The person who asked can download it
-- and hand it to the family; every download is written into the
-- certificate's own history. No financial data, nothing in public.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Who may ask and approve is in ..._certificate_requests_role_permissions.sql.

create table vppsone.school_certificate_requests (
 id uuid primary key default gen_random_uuid(),
 student_id uuid not null,
 session_label text not null check (session_label ~ '^(TEST-)?[0-9]{4}-[0-9]{2}$'),
 class_id uuid not null,
 kind text not null check (kind in ('study','character','dob')),
 purpose text check (purpose is null or (length(btrim(purpose)) between 2 and 80 and purpose !~ '[{}<>]')),
 extras jsonb not null default '{}'::jsonb check (jsonb_typeof(extras)='object'),
 note text check (note is null or (length(btrim(note)) between 1 and 300 and note !~ '[{}<>]')),
 requested_by uuid not null references vppsone.staff_profiles(id),
 requested_at timestamptz not null default now(),
 command_id uuid not null unique,
 state text not null default 'waiting' check (state in ('waiting','approved','declined','withdrawn')),
 decided_by uuid references vppsone.staff_profiles(id),
 decided_at timestamptz,
 decline_reason text check (decline_reason is null or (length(btrim(decline_reason)) between 3 and 300 and decline_reason !~ '[{}<>]')),
 issue_id uuid references vppsone.school_certificate_issues(id),
 constraint school_certificate_request_decided check (((state='waiting')=(decided_at is null)) and ((state='waiting')=(decided_by is null))),
 constraint school_certificate_request_issue check ((state='approved')=(issue_id is not null)),
 constraint school_certificate_request_declined check ((state='declined')=(decline_reason is not null))
);
-- One open request per child, session and document; a second ask finds the first.
create unique index school_certificate_request_waiting on vppsone.school_certificate_requests(student_id,session_label,kind) where state='waiting';
create index school_certificate_request_queue on vppsone.school_certificate_requests(session_label,state,requested_at desc);
create index school_certificate_request_mine on vppsone.school_certificate_requests(requested_by,requested_at desc);
create index school_certificate_request_student on vppsone.school_certificate_requests(student_id,session_label,requested_at desc);
create index school_certificate_request_issue_ref on vppsone.school_certificate_requests(issue_id) where issue_id is not null;
alter table vppsone.school_certificate_requests enable row level security;
revoke all on vppsone.school_certificate_requests from public,anon,authenticated;
grant all on vppsone.school_certificate_requests to service_role;

-- What was asked never changes, and an answer is final.
create function vppsone.school_certificate_request_guard()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'certificate_request:immutable'; end if;
 if new.id<>old.id or new.student_id<>old.student_id or new.session_label<>old.session_label or new.class_id<>old.class_id
   or new.kind<>old.kind or new.purpose is distinct from old.purpose or new.extras<>old.extras or new.note is distinct from old.note
   or new.requested_by<>old.requested_by or new.requested_at<>old.requested_at or new.command_id<>old.command_id then
   raise exception 'certificate_request:immutable';
 end if;
 if old.state<>'waiting' and row(new.state,new.decided_by,new.decided_at,new.decline_reason,new.issue_id)
   is distinct from row(old.state,old.decided_by,old.decided_at,old.decline_reason,old.issue_id) then
   raise exception 'certificate_request:decided';
 end if;
 return new;
end;
$$;
create trigger school_certificate_request_guard before update or delete on vppsone.school_certificate_requests
 for each row execute function vppsone.school_certificate_request_guard();
revoke all on function vppsone.school_certificate_request_guard() from public,anon,authenticated;

-- Who may ask: active staff whose role holds certificates:request, in a
-- session their account may touch (TEST with TEST), for a class they hold
-- today or teach -- the classes vppsone.my_class_keys() gives a teacher --
-- or any class for the school-wide roles.
create function vppsone.school_certificate_requester_allowed(p_actor uuid,p_session text,p_class uuid,p_confined boolean default false)
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from vppsone.staff_profiles sp
   join vppsone.role_permissions rp on rp.role=sp.role and rp.permission='certificates:request'
   where sp.id=p_actor and sp.is_active
     and p_session ~ '^(TEST-)?[0-9]{4}-[0-9]{2}$'
     and (not p_confined or vppsone.is_test_session(p_session))
     and (vppsone.is_test_session(p_session)=coalesce(sp.is_test_account,false)
       or (sp.role='admin' and not coalesce(sp.is_test_account,false)))
     and (sp.role in ('admin','office','academic_coordinator','exam_coordinator')
       or exists(select 1 from vppsone.class_teachers ct
         where ct.staff_profile_id=p_actor and ct.class_id=p_class and ct.session_label=p_session
           and (ct.effective_from is null or ct.effective_from<=vppsone.school_today())
           and (ct.effective_to is null or ct.effective_to>=vppsone.school_today()))
       or exists(select 1 from vppsone.teaching_assignments ta
         where ta.staff_profile_id=p_actor and ta.class_id=p_class and ta.session_label=p_session)));
$$;
revoke all on function vppsone.school_certificate_requester_allowed(uuid,text,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_requester_allowed(uuid,text,uuid,boolean) to service_role;

-- The person who asked, still active and still allowed to ask at all.
create function vppsone.school_certificate_request_owner(p_actor uuid,p_request vppsone.school_certificate_requests,p_confined boolean default false)
returns boolean language sql stable set search_path='' as $$
 select p_request.requested_by=p_actor and (not p_confined or vppsone.is_test_session(p_request.session_label))
   and exists(select 1 from vppsone.staff_profiles sp
     join vppsone.role_permissions rp on rp.role=sp.role and rp.permission='certificates:request'
     where sp.id=p_actor and sp.is_active);
$$;
revoke all on function vppsone.school_certificate_request_owner(uuid,vppsone.school_certificate_requests,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_request_owner(uuid,vppsone.school_certificate_requests,boolean) to service_role;

create function vppsone.school_certificate_request_create(p_actor uuid,p_student uuid,p_session text,p_kind text,p_command uuid,
 p_purpose text default null,p_extras jsonb default '{}'::jsonb,p_note text default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare e vppsone.enrolments; r vppsone.school_certificate_requests; extra record;
 v_purpose text:=nullif(btrim(coalesce(p_purpose,'')),''); v_note text:=nullif(btrim(coalesce(p_note,'')),''); v_extras jsonb:=coalesce(p_extras,'{}'::jsonb);
begin
 if p_kind not in ('study','character','dob') then raise exception 'certificate_request:invalid_kind'; end if;
 if v_purpose is not null and (length(v_purpose)<2 or length(v_purpose)>80 or v_purpose ~ '[{}<>]') then raise exception 'certificate_request:invalid_purpose'; end if;
 if v_note is not null and (length(v_note)>300 or v_note ~ '[{}<>]') then raise exception 'certificate_request:invalid_note'; end if;
 if jsonb_typeof(v_extras)<>'object' then raise exception 'certificate_request:invalid_extras'; end if;
 for extra in select key,value from jsonb_each(v_extras) loop
   if extra.key<>'conduct' or jsonb_typeof(extra.value)<>'string'
     or (extra.value#>>'{}') not in ('excellent','very_good','good','satisfactory') then raise exception 'certificate_request:invalid_extras'; end if;
 end loop;
 if p_kind='character' and not (v_extras ? 'conduct') then raise exception 'certificate_request:conduct_required'; end if;
 if p_kind<>'character' and v_extras<>'{}'::jsonb then raise exception 'certificate_request:invalid_extras'; end if;
 if p_session is null or p_session !~ '^(TEST-)?[0-9]{4}-[0-9]{2}$' or (p_confined and not vppsone.is_test_session(p_session)) then
   raise exception 'certificate_request:forbidden';
 end if;
 select * into e from vppsone.enrolments where student_id=p_student and session_label=p_session
   and status::text='enrolled' and left_on is null order by created_at desc limit 1;
 if not found then raise exception 'certificate_request:not_enrolled'; end if;
 if not vppsone.school_certificate_requester_allowed(p_actor,p_session,e.class_id,p_confined) then raise exception 'certificate_request:forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-request-command:'||p_command::text,0));
 select * into r from vppsone.school_certificate_requests where command_id=p_command;
 if found then
   if r.requested_by<>p_actor or r.student_id<>p_student or r.session_label<>p_session or r.kind<>p_kind
     or r.purpose is distinct from v_purpose or r.extras<>v_extras or r.note is distinct from v_note then raise exception 'certificate_request:command_reused'; end if;
   return jsonb_build_object('request',to_jsonb(r),'existing',true);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-request:'||p_student::text||':'||p_session||':'||p_kind,0));
 select * into r from vppsone.school_certificate_requests where student_id=p_student and session_label=p_session and kind=p_kind and state='waiting';
 if found then return jsonb_build_object('request',to_jsonb(r),'existing',true); end if;
 insert into vppsone.school_certificate_requests(student_id,session_label,class_id,kind,purpose,extras,note,requested_by,command_id)
   values(p_student,p_session,e.class_id,p_kind,v_purpose,v_extras,v_note,p_actor,p_command) returning * into r;
 return jsonb_build_object('request',to_jsonb(r),'existing',false);
end;
$$;
revoke all on function vppsone.school_certificate_request_create(uuid,uuid,text,text,uuid,text,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_request_create(uuid,uuid,text,text,uuid,text,jsonb,text,boolean) to service_role;

create function vppsone.school_certificate_request_withdraw(p_actor uuid,p_request uuid,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare r vppsone.school_certificate_requests;
begin
 select * into r from vppsone.school_certificate_requests where id=p_request for update;
 if not found or not vppsone.school_certificate_request_owner(p_actor,r,p_confined) then raise exception 'certificate_request:forbidden'; end if;
 if r.state='withdrawn' then return to_jsonb(r); end if;
 if r.state<>'waiting' then raise exception 'certificate_request:decided'; end if;
 update vppsone.school_certificate_requests set state='withdrawn',decided_by=p_actor,decided_at=clock_timestamp() where id=r.id returning * into r;
 return to_jsonb(r);
end;
$$;
revoke all on function vppsone.school_certificate_request_withdraw(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_request_withdraw(uuid,uuid,boolean) to service_role;

create function vppsone.school_certificate_request_decline(p_actor uuid,p_request uuid,p_reason text,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare r vppsone.school_certificate_requests; v_reason text:=btrim(coalesce(p_reason,''));
begin
 select * into r from vppsone.school_certificate_requests where id=p_request for update;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'certificates:approve',r.session_label,p_confined) then raise exception 'certificate_request:forbidden'; end if;
 if r.state='declined' and r.decided_by=p_actor and r.decline_reason=v_reason then return to_jsonb(r); end if;
 if r.state<>'waiting' then raise exception 'certificate_request:decided'; end if;
 if length(v_reason)<3 or length(v_reason)>300 or v_reason ~ '[{}<>]' then raise exception 'certificate_request:reason_required'; end if;
 update vppsone.school_certificate_requests set state='declined',decided_by=p_actor,decided_at=clock_timestamp(),decline_reason=v_reason
   where id=r.id returning * into r;
 return to_jsonb(r);
end;
$$;
revoke all on function vppsone.school_certificate_request_decline(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_request_decline(uuid,uuid,text,boolean) to service_role;

-- Approval links the request to the document the approver has just issued:
-- same child, session, document, purpose and conduct, issued by this approver,
-- current and stored. Issuing itself stays in school_certificate_reserve_v2.
create function vppsone.school_certificate_request_approve(p_actor uuid,p_request uuid,p_issue uuid,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare r vppsone.school_certificate_requests; i vppsone.school_certificate_issues;
begin
 select * into r from vppsone.school_certificate_requests where id=p_request for update;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'certificates:approve',r.session_label,p_confined)
   or not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',r.session_label,p_confined) then raise exception 'certificate_request:forbidden'; end if;
 if r.state='approved' and r.issue_id=p_issue then return to_jsonb(r); end if;
 if r.state<>'waiting' then raise exception 'certificate_request:decided'; end if;
 select * into i from vppsone.school_certificate_issues where id=p_issue;
 if not found or i.student_id<>r.student_id or i.session_label<>r.session_label or i.kind<>r.kind or i.issued_by<>p_actor
   or i.status not in ('prepared','issued') or i.artifact_state<>'ready'
   or (i.snapshot->>'purpose') is distinct from r.purpose or coalesce(i.snapshot->'extras','{}'::jsonb)<>r.extras then
   raise exception 'certificate_request:issue_mismatch';
 end if;
 update vppsone.school_certificate_requests set state='approved',decided_by=p_actor,decided_at=clock_timestamp(),issue_id=p_issue
   where id=r.id returning * into r;
 return to_jsonb(r);
end;
$$;
revoke all on function vppsone.school_certificate_request_approve(uuid,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_request_approve(uuid,uuid,uuid,boolean) to service_role;

-- The stored original behind an approved request, for the person who asked or
-- an approver. A corrected copy stands in for one the office superseded; a
-- cancelled one is gone. With a command it records the download in the
-- certificate's history first (idempotent); without one it only reads.
create function vppsone.school_certificate_request_document(p_actor uuid,p_request uuid,p_command uuid default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare r vppsone.school_certificate_requests; i vppsone.school_certificate_issues; replacement vppsone.school_certificate_issues; prior vppsone.school_certificate_events;
begin
 select * into r from vppsone.school_certificate_requests where id=p_request;
 if not found or not (vppsone.school_certificate_request_owner(p_actor,r,p_confined)
   or vppsone.school_office_actor_allowed(p_actor,'certificates:approve',r.session_label,p_confined)) then raise exception 'certificate_request:forbidden'; end if;
 if r.state<>'approved' then raise exception 'certificate_request:not_ready'; end if;
 select * into i from vppsone.school_certificate_issues where id=r.issue_id;
 if i.status='superseded' then
   select * into replacement from vppsone.school_certificate_issues where supersedes=i.id and status in ('prepared','issued') and artifact_state='ready' limit 1;
   if found then i:=replacement; end if;
 end if;
 if i.status not in ('prepared','issued') or i.artifact_state<>'ready' or i.storage_path is null then raise exception 'certificate_request:not_ready'; end if;
 if p_command is not null then
   select * into prior from vppsone.school_certificate_events where command_id=p_command;
   if found then
     if prior.actor_id<>p_actor or prior.issue_id<>i.id or prior.kind<>'download_requested' then raise exception 'certificate_request:command_reused'; end if;
   else
     insert into vppsone.school_certificate_events(issue_id,actor_id,kind,reason,command_id) values(i.id,p_actor,'download_requested','Through a teacher request',p_command);
   end if;
 end if;
 return jsonb_build_object('issueId',i.id,'serial',i.serial,'storagePath',i.storage_path,'sha256',i.artifact_sha256);
end;
$$;
revoke all on function vppsone.school_certificate_request_document(uuid,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_request_document(uuid,uuid,uuid,boolean) to service_role;

-- Requests as each screen needs them: 'mine' for the person who asked,
-- 'student' for anyone who may ask for that child, 'approver' for the queue.
-- Father's name and date of birth go only to an approver, who checks them
-- before signing.
create function vppsone.school_certificate_requests_list(p_actor uuid,p_session text,p_scope text,p_student uuid default null,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare approver boolean; e vppsone.enrolments;
begin
 if p_scope not in ('mine','student','approver') or p_session is null or p_session !~ '^(TEST-)?[0-9]{4}-[0-9]{2}$' then raise exception 'certificate_request:invalid_scope'; end if;
 if p_confined and not vppsone.is_test_session(p_session) then raise exception 'certificate_request:forbidden'; end if;
 approver:=vppsone.school_office_actor_allowed(p_actor,'certificates:approve',p_session,p_confined);
 if p_scope='approver' and not approver then raise exception 'certificate_request:forbidden'; end if;
 if p_scope='student' then
   if p_student is null then raise exception 'certificate_request:invalid_scope'; end if;
   select * into e from vppsone.enrolments where student_id=p_student and session_label=p_session order by created_at desc limit 1;
   if not approver and (e.id is null or not vppsone.school_certificate_requester_allowed(p_actor,p_session,e.class_id,p_confined)) then
     raise exception 'certificate_request:forbidden';
   end if;
 end if;
 if p_scope='mine' and not exists(select 1 from vppsone.staff_profiles sp where sp.id=p_actor and sp.is_active) then raise exception 'certificate_request:forbidden'; end if;
 return coalesce((select jsonb_agg(x.item order by x.waiting desc, x.at desc) from (
   select r.state='waiting' as waiting, coalesce(r.decided_at,r.requested_at) as at, jsonb_build_object(
     'id',r.id,'studentId',r.student_id,'sessionLabel',r.session_label,'classId',r.class_id,'kind',r.kind,'purpose',r.purpose,'extras',r.extras,'note',r.note,
     'requestedBy',r.requested_by,'requestedByName',coalesce(nullif(rq.short_name,''),rq.display_name),'requestedAt',r.requested_at,
     'state',r.state,'decidedByName',coalesce(nullif(dc.short_name,''),dc.display_name),'decidedAt',r.decided_at,'declineReason',r.decline_reason,
     'issueId',d.id,'serial',d.serial,'issueStatus',d.status,
     'issueReady',coalesce(d.artifact_state='ready' and d.status in ('prepared','issued'),false),
     'signed',coalesce(d.snapshot->'school'->>'signaturePolicy'='facsimile'
       and (d.snapshot->'school' ? 'signatureAsset' or nullif(d.snapshot->'school'->>'signature','') is not null),false),
     'studentName',coalesce(s.full_name,''),'admissionNo',coalesce(s.admission_no,''),'classLabel',concat_ws(' ',c.class_name,nullif(c.section,'')),
     'mine',r.requested_by=p_actor,
     'fatherName',case when approver then s.father_name end,'dateOfBirth',case when approver then s.date_of_birth end) as item
   from vppsone.school_certificate_requests r
   join vppsone.staff_profiles rq on rq.id=r.requested_by
   left join vppsone.staff_profiles dc on dc.id=r.decided_by
   left join vppsone.school_certificate_issues i on i.id=r.issue_id
   left join lateral (select x.* from vppsone.school_certificate_issues x where x.id=coalesce(
       (select n.id from vppsone.school_certificate_issues n where i.status='superseded' and n.supersedes=i.id and n.status in ('prepared','issued') limit 1), i.id)) d on true
   left join lateral (select * from vppsone.fees_identity_students fs where fs.id=r.student_id limit 1) s on true
   left join lateral (select * from vppsone.fees_identity_classes fc where fc.id=r.class_id and fc.session_label=r.session_label limit 1) c on true
   where r.session_label=p_session and case p_scope
     when 'mine' then r.requested_by=p_actor and r.state<>'withdrawn' and (r.state='waiting' or coalesce(r.decided_at,r.requested_at)>=clock_timestamp()-interval '30 days')
     when 'student' then r.student_id=p_student and r.state<>'withdrawn'
     else r.state='waiting' or (r.state in ('approved','declined') and r.decided_at>=clock_timestamp()-interval '2 days') end
   order by r.state='waiting' desc, coalesce(r.decided_at,r.requested_at) desc
   limit case when p_scope='approver' then 100 else 20 end
 ) x),'[]'::jsonb);
end;
$$;
revoke all on function vppsone.school_certificate_requests_list(uuid,text,text,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_requests_list(uuid,text,text,uuid,boolean) to service_role;

notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261107172557_certificate_requests_role_permissions.sql
-- D-542: certificate requests. A teacher asks for a study, character or
-- date-of-birth certificate for a child in her own classes
-- (certificates:request, "Ask for a certificate"); an approver signs and seals
-- it (certificates:approve, "Approve teachers' requests" on Staff -> Roles).
-- The admin holds both and teachers ask by default (owner, 7 Nov 2026).
-- Approving also needs certificates:issue, so another role gets it only when
-- the admin grants it in the matrix. Rows only; additive. The admin rows are
-- what lets set_role_permissions offer these to other roles at all.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'certificates:request'),
  ('admin', 'certificates:approve'),
  ('teacher', 'certificates:request')
on conflict do nothing;

-- ======================================================== migrations/20261107174655_task_delivery_queue_fix.sql
-- Noting a WhatsApp send for a teacher's task failed on live (found on a real
-- phone, 7 Nov 2026): queue_teacher_task_delivery stopped with
--   column reference "snapshot" is ambiguous
-- message_sends gained its own `snapshot` column in 20261004084641
-- (parent message policy), before task delivery was written, and PL/pgSQL
-- refuses a bare name that is both a variable and a column. So no task
-- delivery could ever be queued: the board kept saying "Link not sent".
--
-- The same function, unchanged in what it decides. Its variables are now
-- named through the block label wherever a statement reads a table, so a
-- column added later cannot take their place again. Grants are restated.
create or replace function vppsone.queue_teacher_task_delivery(p_actor uuid,p_preview uuid,p_digest text) returns jsonb language plpgsql security definer set search_path='' as $$
<<q>>
declare preview vppsone.teacher_task_previews%rowtype; snapshot jsonb; task uuid; msg uuid; template vppsone.message_templates%rowtype; params text[]; round text;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into preview from vppsone.teacher_task_previews where id=p_preview and actor_id=p_actor and digest=p_digest;
  if not found or preview.expires_at<now() or preview.payload->'delivery' is null then return jsonb_build_object('ok',false,'reason','changed'); end if;
  task:=(preview.payload->'delivery'->>'taskId')::uuid;
  -- Every enqueue/claim takes task before message row. Management also locks task.
  perform 1 from vppsone.teacher_tasks where id=q.task for update;
  perform 1 from vppsone.staff_profiles where id in(p_actor,(select assigned_staff_id from vppsone.teacher_tasks where id=q.task)) order by id for share;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  snapshot:=vppsone.teacher_task_delivery_snapshot(task);
  if snapshot is null or snapshot->>'version' is distinct from preview.payload->'delivery'->>'authorityVersion' then return jsonb_build_object('ok',false,'reason','changed'); end if;
  if not (snapshot->>'pending')::boolean then return jsonb_build_object('ok',false,'reason','complete'); end if;
  if vppsone.teacher_task_has_unknown_delivery(task) then return jsonb_build_object('ok',false,'reason','reconcile'); end if;
  select * into template from vppsone.message_templates where code='vppsone_teacher_task'||case when preview.payload->>'kind'='reminder' then '_reminder' else '' end||'_'||(q.snapshot->>'language')||'_v1' and is_active and audience='staff';
  if not found or md5(to_jsonb(template)::text) is distinct from preview.payload->'delivery'->>'templateVersion' then return jsonb_build_object('ok',false,'reason','changed'); end if;
  snapshot:=preview.payload->'delivery';
  round:=preview.payload->>'round';
  if preview.payload->>'kind'='reminder' and round is distinct from 'reminder:'||vppsone.school_today()::text then return jsonb_build_object('ok',false,'reason','changed'); end if;
  -- message_sends has its own `snapshot` column (20261004084641), so every
  -- variable read next to a table is named through the block label.
  select m.id into msg from vppsone.message_sends m where m.task_id=q.task and m.task_snapshot->>'version'=q.snapshot->>'version' and m.task_round=q.round;
  if found then
    -- The caller reviewed this exact immutable row again; another office actor
    -- may continue it only through a fresh actor-bound preview.
    perform set_config('vppsone.task_delivery',msg::text,true);
    update vppsone.message_sends set requested_by=p_actor where id=q.msg and task_delivery_state in ('ready','rejected');
    return jsonb_build_object('ok',true,'id',msg);
  end if;
  params:=array[snapshot->>'name',snapshot->>'title',coalesce(snapshot->>'due','—')];
  msg:=gen_random_uuid();perform set_config('vppsone.task_delivery',msg::text,true);
  insert into vppsone.message_sends(id,session_label,template_id,to_phone,to_name,staff_profile_id,variables,rendered_hi,rendered_en,status,requested_by,task_id,task_snapshot,task_round,task_delivery_state)
    select q.msg,t.session_label,q.template.id,q.snapshot->>'phone',q.snapshot->>'name',t.assigned_staff_id,q.params,
      replace(replace(replace(q.template.body_hi,'{{1}}',q.params[1]),'{{2}}',q.params[2]),'{{3}}',q.params[3]),
      replace(replace(replace(q.template.body_en,'{{1}}',q.params[1]),'{{2}}',q.params[2]),'{{3}}',q.params[3]),
      'queued',p_actor,q.task,q.snapshot,q.round,'ready' from vppsone.teacher_tasks t where t.id=q.task;
  return jsonb_build_object('ok',true,'id',msg);
end; $$;

revoke all on function vppsone.queue_teacher_task_delivery(uuid,uuid,text) from public,anon,authenticated;
grant execute on function vppsone.queue_teacher_task_delivery(uuid,uuid,text) to service_role;

-- ======================================================== migrations/20261108170533_staff_session_match.sql
/*
 * Each session has its own kind of staff (owner, 8 Nov 2026: "the test
 * accounts and QA accounts should be in the test session only ... the real
 * live data will only have the genuine accounts").
 *
 * A test account (`staff_profiles.is_test_account`) works only in a test
 * session (TEST-/UAT-/DEMO-); real staff work only in a real one. The app's
 * half is `staffBelongsToSession()` in src/platform/auth/test-session-policy.ts,
 * which every staff list, picker and count now asks. This is the database's
 * half, for the writes a picker cannot reach:
 *
 *   1. `vppsone.staff_matches_session(staff, session)`: the same predicate.
 *   2. `queue_staff_notice` skips a notice whose person and session differ,
 *      both ways. It already skipped a test account in a real session; it now
 *      also skips a real person in a test session (a TEST leave request was
 *      queuing a WhatsApp notice to the real admin). Skipping, not raising:
 *      a notice is a side effect, and the cover/leave write that queued it
 *      must still succeed.
 *   3. `staff_session_match` triggers refuse putting somebody on another
 *      session's work: class teachers, teaching assignments, timetable slots,
 *      staff scopes, cover policies, teacher tasks, collection requests, exam
 *      duties and exam marks links. Each is a deliberate assignment chosen
 *      from a staff picker. Columns that can default to the person writing
 *      (a note's "follow up: me", a plan step's owner) are left alone: that is
 *      authorship, and a real admin may still look at the test session.
 *      An update is checked only when the person or the session changes, so
 *      existing rows and same-value upserts are untouched.
 *   4. No rows are changed here. The handful of test-only leftovers (never-
 *      sent notices across the line, practice-day leave for real teachers in
 *      the TEST session, one real-year cover policy for a test account) were
 *      removed as a one-off data fix the same day; see D-560 in
 *      docs/DECISIONS.md. Existing rows are never re-checked.
 *
 * Nothing here is in `public` and no fee row is read or written.
 */

begin;

/* ------------------------------------------------------------ predicate */

create or replace function vppsone.staff_matches_session(p_staff uuid, p_session text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- No person, or a person the foreign key will refuse anyway: nothing to say.
  select coalesce((
    select sp.is_test_account = vppsone.is_test_session_label(p_session)
    from vppsone.staff_profiles sp
    where sp.id = p_staff
  ), true);
$$;

revoke all on function vppsone.staff_matches_session(uuid, text) from public, anon;
grant execute on function vppsone.staff_matches_session(uuid, text) to authenticated, service_role;

/* ---------------------------------------------------- notices, both ways */

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
  -- A test account hears only about test sessions, and real staff only about
  -- real ones (8 Nov 2026; before, only the first half was checked).
  if v_test is distinct from vppsone.is_test_session_label(p_session) then
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

/* ------------------------------------------------------- the row guard */

/*
 * TG_ARGV[0]: the column holding the session label, or (with TG_ARGV[1]) the
 *             column holding the parent row's id.
 * TG_ARGV[1]: '' when the row carries its own session_label; otherwise the
 *             vppsone table whose `session_label` the row belongs to.
 * TG_ARGV[2..]: the staff columns to check.
 */
create or replace function vppsone.guard_staff_session_match()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb;
  v_key text := tg_argv[0];
  v_parent text := nullif(tg_argv[1], '');
  v_session text;
  v_staff uuid;
  v_changed boolean;
  i integer;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_changed := (v_new -> v_key) is distinct from (v_old -> v_key);
    for i in 2 .. tg_nargs - 1 loop
      v_changed := v_changed or (v_new -> tg_argv[i]) is distinct from (v_old -> tg_argv[i]);
    end loop;
    if not v_changed then
      return new;
    end if;
  end if;

  if v_parent is null then
    v_session := v_new ->> v_key;
  else
    if (v_new ->> v_key) is null then
      return new;
    end if;
    execute format('select session_label from vppsone.%I where id = $1', v_parent)
      into v_session
      using (v_new ->> v_key)::uuid;
    if v_session is null then
      return new; -- no parent: the foreign key decides
    end if;
  end if;

  for i in 2 .. tg_nargs - 1 loop
    v_staff := (v_new ->> tg_argv[i])::uuid;
    if v_staff is not null and not vppsone.staff_matches_session(v_staff, v_session) then
      raise exception using
        errcode = 'check_violation',
        message = 'Test accounts work only in a test session, and real staff only in the real year.',
        detail = format('%s.%s, session %s', tg_table_name, tg_argv[i], coalesce(v_session, '(none)'));
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function vppsone.guard_staff_session_match() from public, anon, authenticated;

create or replace trigger staff_session_match
  before insert or update of session_label, staff_profile_id on vppsone.class_teachers
  for each row execute function vppsone.guard_staff_session_match('session_label', '', 'staff_profile_id');

create or replace trigger staff_session_match
  before insert or update of session_label, staff_profile_id on vppsone.teaching_assignments
  for each row execute function vppsone.guard_staff_session_match('session_label', '', 'staff_profile_id');

create or replace trigger staff_session_match
  before insert or update of session_label, staff_profile_id on vppsone.staff_scopes
  for each row execute function vppsone.guard_staff_session_match('session_label', '', 'staff_profile_id');

create or replace trigger staff_session_match
  before insert or update of session_label, staff_profile_id on vppsone.cover_policies
  for each row execute function vppsone.guard_staff_session_match('session_label', '', 'staff_profile_id');

create or replace trigger staff_session_match
  before insert or update of session_label, assigned_staff_id on vppsone.teacher_tasks
  for each row execute function vppsone.guard_staff_session_match('session_label', '', 'assigned_staff_id');

create or replace trigger staff_session_match
  before insert or update of session_label, assigned_staff_id on vppsone.collection_requests
  for each row execute function vppsone.guard_staff_session_match('session_label', '', 'assigned_staff_id');

create or replace trigger staff_session_match
  before insert or update of version_id, staff_profile_id on vppsone.timetable_slots
  for each row execute function vppsone.guard_staff_session_match('version_id', 'timetable_versions', 'staff_profile_id');

create or replace trigger staff_session_match
  before insert or update of assessment_id, staff_profile_id on vppsone.exam_duties
  for each row execute function vppsone.guard_staff_session_match('assessment_id', 'assessments', 'staff_profile_id');

create or replace trigger staff_session_match
  before insert or update of assessment_id, staff_profile_id on vppsone.exam_marks_links
  for each row execute function vppsone.guard_staff_session_match('assessment_id', 'assessments', 'staff_profile_id');

commit;

-- ======================================================== migrations/20261109062459_school_whatsapp.sql
-- The school's own WhatsApp number replaces AiSensy in VPPS One (D-562).
--
-- One sends from +91 83022 07823 ("Veer Patta School") through the school's
-- own WhatsApp server, or straight to Meta's Cloud API, behind one service
-- (src/platform/whatsapp). The fees app keeps its own AiSensy number
-- (+91 80 4713 6289) and nothing here touches it; One refuses that number as
-- a sender and as a recipient.
--
-- What this adds, all in `vppsone`:
--
--  * `whatsapp_templates`: the template registry. Which templates exist on the
--    school's account, under which name and language, how many `{{n}}` each
--    takes, and whether Meta has APPROVED it. Nothing goes out under a
--    template whose row is not `approved`. Every row starts `not_submitted`:
--    templates are approved per WhatsApp Business Account, so nothing approved
--    on AiSensy's account carries over. Seeded from the app's descriptors
--    (scripts/whatsapp-template-catalog.mjs) and from One's own
--    `message_templates`.
--  * `whatsapp_messages`: one row per message, ever. It is the log AND the
--    queue: `queued` / `retry_wait` rows are sent by the queue job, the rest
--    are history. Written only by the service role.
--  * `whatsapp_message_events`: append-only. Every send attempt, status
--    report (sent, delivered, read, failed with Meta's code), retry and
--    "paid" mark.
--  * `whatsapp_inbound`: parents' replies.
--  * Six switches in `runtime_flags`, every one of them CLOSED:
--      whatsapp_dry_run           ON  -> written to the log, never sent
--      whatsapp_features          every feature false
--      whatsapp_real_recipients   OFF -> only the owner's test number
--      whatsapp_owner_test_number empty -> with real recipients off, nobody
--      whatsapp_daily_limit       250 a day (a new number's Meta tier)
--      whatsapp_month_plan_cap    replaces aisensy_month_plan_cap (same value)
--  * `whatsapp_claim_send`, `whatsapp_take_due`, `whatsapp_record_status`:
--    the three writes that must be atomic (daily limit, queue lease,
--    never-backwards status).
--  * The queue's timer: pg_cron every five minutes, which calls One ONLY when
--    a row is due, with a Vault secret checked in Postgres
--    (`whatsapp_queue_secret_matches`), so no copy lives in Vercel.
--  * Staff notices may record the transport `whatsapp`; the month's staff
--    count and ops health read both the old `aisensy` rows and the new ones.
--
-- Rollback (nothing else depends on these):
--   select cron.unschedule('whatsapp-queue');
--   delete from vault.secrets where name = 'WHATSAPP_QUEUE_CRON_SECRET';
--   drop function vppsone.whatsapp_queue_secret_matches(text), vppsone.whatsapp_record_status(text,text,timestamptz,text,text,jsonb),
--     vppsone.whatsapp_take_due(integer), vppsone.whatsapp_claim_send(jsonb,text,integer);
--   drop table vppsone.whatsapp_inbound, vppsone.whatsapp_message_events, vppsone.whatsapp_messages, vppsone.whatsapp_templates;
--   delete from vppsone.runtime_flags where key like 'whatsapp_%';
--   (and restore runtime_flags_key_known, staff_notice_attempts_transport_known,
--    staff_whatsapp_month_sent and ops_health_counts from 20261031125856.)

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

-- --------------------------------------------------------------- registry

create table vppsone.whatsapp_templates (
  key text primary key,
  provider_name text not null,
  language_code text not null,
  feature text not null,
  category text not null default 'utility',
  body_params integer not null default 0,
  param_names text[] not null default '{}',
  header text not null default 'none',
  url_button boolean not null default false,
  status text not null default 'not_submitted',
  status_reason text,
  status_checked_at timestamptz,
  label_en text,
  label_hi text,
  updated_at timestamptz not null default now(),
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  constraint whatsapp_templates_status_known check (status in ('not_submitted', 'pending', 'approved', 'rejected', 'paused', 'disabled')),
  constraint whatsapp_templates_header_known check (header in ('none', 'document', 'image', 'text')),
  constraint whatsapp_templates_category_known check (category in ('utility', 'marketing', 'authentication')),
  constraint whatsapp_templates_params_range check (body_params between 0 and 20),
  constraint whatsapp_templates_language_shape check (language_code ~ '^[a-z]{2}(_[A-Z]{2})?$'),
  constraint whatsapp_templates_name_shape check (provider_name ~ '^[a-z0-9_]+$' and length(provider_name) <= 512),
  -- `_v6` Pay now buttons point at the fees app's host (parent-send-gate.ts).
  constraint whatsapp_templates_never_v6 check (key !~* '_v6$' and provider_name !~* '_v6$')
);

comment on table vppsone.whatsapp_templates is
  'D-562: templates on the school''s own WhatsApp account (+91 83022 07823). A message goes out only under a row whose status is approved. Status is read from the WhatsApp server / Meta (Settings -> WhatsApp -> Check templates) or set by an admin.';

alter table vppsone.whatsapp_templates enable row level security;
revoke all on vppsone.whatsapp_templates from anon, authenticated;
grant all on vppsone.whatsapp_templates to service_role;

-- ---------------------------------------------------------------- the log

create table vppsone.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  feature text not null,
  kind text not null,
  template_key text,
  provider_template_name text,
  language_code text,
  to_e164 text not null,
  to_name text,
  body_params jsonb not null default '[]'::jsonb,
  header jsonb,
  button_params jsonb not null default '[]'::jsonb,
  text_body text,
  session_label text,
  source_table text,
  source_id text,
  requested_by uuid,
  status text not null,
  dry_run boolean not null default false,
  provider text,
  provider_message_id text,
  attempts integer not null default 0,
  max_attempts integer not null default 1,
  next_attempt_at timestamptz,
  last_attempt_at timestamptz,
  error_code text,
  error_title text,
  error_detail text,
  http_status integer,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz,
  pay_code text,
  paid_at timestamptz,
  paid_receipt_id uuid,
  idempotency_key text,
  retry_of uuid references vppsone.whatsapp_messages (id) on delete set null,
  retried_at timestamptz,
  retried_by uuid,
  constraint whatsapp_messages_kind_known check (kind in ('template', 'text')),
  constraint whatsapp_messages_status_known check (status in (
    'dry_run', 'held', 'queued', 'sending', 'retry_wait',
    'accepted', 'sent', 'delivered', 'read', 'failed', 'unknown', 'cancelled'
  )),
  constraint whatsapp_messages_template_has_key check ((kind = 'template') = (template_key is not null)),
  constraint whatsapp_messages_text_has_body check ((kind = 'text') = (text_body is not null)),
  constraint whatsapp_messages_e164 check (to_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  -- The fees app's AiSensy number is never a recipient of One's.
  constraint whatsapp_messages_never_fees_number check (to_e164 <> '+918047136289'),
  constraint whatsapp_messages_attempts_range check (attempts >= 0 and max_attempts between 1 and 5),
  constraint whatsapp_messages_queue_has_time check (status not in ('queued', 'retry_wait') or next_attempt_at is not null)
);

comment on table vppsone.whatsapp_messages is
  'D-562: every WhatsApp message One sends or would have sent (dry run), one row each. The log and the queue: queued/retry_wait rows are sent by /api/jobs/whatsapp-queue. Service role only.';

create unique index whatsapp_messages_provider_id_key
  on vppsone.whatsapp_messages (provider_message_id) where provider_message_id is not null;
create unique index whatsapp_messages_idempotency_key
  on vppsone.whatsapp_messages (idempotency_key) where idempotency_key is not null;
create index whatsapp_messages_due_idx
  on vppsone.whatsapp_messages (next_attempt_at) where status in ('queued', 'retry_wait');
create index whatsapp_messages_created_idx on vppsone.whatsapp_messages (created_at desc);
create index whatsapp_messages_problem_idx
  on vppsone.whatsapp_messages (created_at desc) where status in ('failed', 'unknown', 'held');
create index whatsapp_messages_source_idx on vppsone.whatsapp_messages (source_table, source_id);
create index whatsapp_messages_pay_code_idx on vppsone.whatsapp_messages (pay_code) where pay_code is not null;

alter table vppsone.whatsapp_messages enable row level security;
revoke all on vppsone.whatsapp_messages from anon, authenticated;
grant all on vppsone.whatsapp_messages to service_role;

create table vppsone.whatsapp_message_events (
  id bigint generated always as identity primary key,
  received_at timestamptz not null default now(),
  message_id uuid references vppsone.whatsapp_messages (id) on delete set null,
  provider_message_id text,
  event text not null,
  status text,
  error_code text,
  error_title text,
  occurred_at timestamptz,
  detail jsonb,
  constraint whatsapp_message_events_event_known check (event in ('send', 'status', 'retry', 'paid', 'note'))
);

comment on table vppsone.whatsapp_message_events is
  'D-562: append-only history of every WhatsApp send attempt, status report, retry and paid mark. Service role only.';

create index whatsapp_message_events_message_idx on vppsone.whatsapp_message_events (message_id, id);
create index whatsapp_message_events_provider_idx on vppsone.whatsapp_message_events (provider_message_id);

alter table vppsone.whatsapp_message_events enable row level security;
revoke all on vppsone.whatsapp_message_events from anon, authenticated;
grant all on vppsone.whatsapp_message_events to service_role;

create table vppsone.whatsapp_inbound (
  id uuid primary key default gen_random_uuid(),
  provider_message_id text not null unique,
  from_e164 text not null,
  from_name text,
  message_type text not null,
  text_body text,
  reply_to_provider_id text,
  reply_to_message_id uuid references vppsone.whatsapp_messages (id) on delete set null,
  received_at timestamptz not null,
  stored_at timestamptz not null default now(),
  payload jsonb,
  seen_by uuid references vppsone.staff_profiles (id) on delete set null,
  seen_at timestamptz
);

comment on table vppsone.whatsapp_inbound is
  'D-562: replies parents send to the school''s WhatsApp number, from the status webhook. Service role only.';

create index whatsapp_inbound_received_idx on vppsone.whatsapp_inbound (received_at desc);

alter table vppsone.whatsapp_inbound enable row level security;
revoke all on vppsone.whatsapp_inbound from anon, authenticated;
grant all on vppsone.whatsapp_inbound to service_role;

-- ------------------------------------------------------------- switches

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
    'ai_connection',
    'whatsapp_dry_run',
    'whatsapp_features',
    'whatsapp_real_recipients',
    'whatsapp_owner_test_number',
    'whatsapp_daily_limit',
    'whatsapp_month_plan_cap'
  )
);

insert into vppsone.runtime_flags (key, enabled, value, note) values
  ('whatsapp_dry_run', true, null,
   'On = every WhatsApp One would send is written to the message log and nothing is sent. Turned off by an admin in Settings -> WhatsApp.'),
  ('whatsapp_features', true,
   '{"fee_reminder": false, "receipt": false, "reversal": false, "fee_statement": false, "school_notice": false, "absent_notice": false, "collection_request": false, "report_delivery": false, "general": false, "staff_notice": false, "teacher_task": false}'::jsonb,
   'Which features may send through the school''s own WhatsApp. Every one false until an admin switches it on.'),
  ('whatsapp_real_recipients', false, null,
   'Off = One may message ONLY the owner''s test number (whatsapp_owner_test_number), whoever it is meant for. On only with the owner''s written approval; no screen turns it on.'),
  ('whatsapp_owner_test_number', false, null,
   'The owner''s own WhatsApp number, E.164 in value. The only recipient while whatsapp_real_recipients is off.'),
  ('whatsapp_daily_limit', true, '250'::jsonb,
   'Most WhatsApp messages One may send in one school day (IST). 250 is Meta''s first tier for a new number.')
on conflict (key) do nothing;

insert into vppsone.runtime_flags (key, enabled, value, note)
select 'whatsapp_month_plan_cap', f.enabled, f.value,
       'The month''s allowance on the school''s WhatsApp plan, for ops health (was aisensy_month_plan_cap).'
from vppsone.runtime_flags f where f.key = 'aisensy_month_plan_cap'
on conflict (key) do nothing;
insert into vppsone.runtime_flags (key, enabled, value, note) values
  ('whatsapp_month_plan_cap', false, null,
   'The month''s allowance on the school''s WhatsApp plan, for ops health (was aisensy_month_plan_cap).')
on conflict (key) do nothing;

-- ------------------------------------------------------- atomic writes

/*
 * Write one message's row, under the school day's limit.
 *
 * `p_status` is what the row starts as: `sending` (sent now), `queued` (the
 * queue job sends it), or `dry_run` / `held` (never sent; logged so the office
 * can see what WOULD have gone). Only `sending` and `queued` count against
 * the limit and take its lock, so two senders at once cannot both take the
 * last slot. A repeat of an idempotency key answers the first row.
 */
create function vppsone.whatsapp_claim_send(p_message jsonb, p_status text, p_daily_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := nullif(p_message ->> 'idempotency_key', '');
  v_found_id uuid;
  v_found_status text;
  v_found_provider_id text;
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_used integer := 0;
  v_status text := p_status;
  v_error_code text := nullif(p_message ->> 'error_code', '');
  v_new_id uuid;
begin
  if p_status not in ('sending', 'queued', 'dry_run', 'held') then
    raise exception 'whatsapp_claim:status';
  end if;

  if v_key is not null then
    select m.id, m.status, m.provider_message_id
      into v_found_id, v_found_status, v_found_provider_id
      from vppsone.whatsapp_messages m
     where m.idempotency_key = v_key;
    if v_found_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'duplicate', 'id', v_found_id,
        'status', v_found_status, 'provider_message_id', v_found_provider_id);
    end if;
  end if;

  if p_status in ('sending', 'queued') then
    perform pg_advisory_xact_lock(hashtext('vppsone.whatsapp_daily_limit'));
    select count(*)::integer into v_used
      from vppsone.whatsapp_messages m
     where m.created_at >= v_day_start
       and m.status in ('sending', 'queued', 'retry_wait', 'accepted', 'sent', 'delivered', 'read', 'unknown');
    if p_daily_limit is null or p_daily_limit < 0 or v_used >= p_daily_limit then
      v_status := 'held';
      v_error_code := 'daily_limit';
    end if;
  end if;

  insert into vppsone.whatsapp_messages (
    feature, kind, template_key, provider_template_name, language_code, to_e164, to_name,
    body_params, header, button_params, text_body, session_label, source_table, source_id,
    requested_by, status, dry_run, provider, max_attempts, next_attempt_at, error_code,
    error_title, pay_code, idempotency_key, retry_of
  ) values (
    p_message ->> 'feature',
    p_message ->> 'kind',
    nullif(p_message ->> 'template_key', ''),
    nullif(p_message ->> 'provider_template_name', ''),
    nullif(p_message ->> 'language_code', ''),
    p_message ->> 'to_e164',
    nullif(p_message ->> 'to_name', ''),
    coalesce(p_message -> 'body_params', '[]'::jsonb),
    p_message -> 'header',
    coalesce(p_message -> 'button_params', '[]'::jsonb),
    p_message ->> 'text_body',
    nullif(p_message ->> 'session_label', ''),
    nullif(p_message ->> 'source_table', ''),
    nullif(p_message ->> 'source_id', ''),
    nullif(p_message ->> 'requested_by', '')::uuid,
    v_status,
    v_status = 'dry_run',
    nullif(p_message ->> 'provider', ''),
    coalesce(nullif(p_message ->> 'max_attempts', '')::integer, 1),
    case when v_status = 'queued' then coalesce(nullif(p_message ->> 'next_attempt_at', '')::timestamptz, now()) end,
    v_error_code,
    nullif(p_message ->> 'error_title', ''),
    nullif(p_message ->> 'pay_code', ''),
    -- A row that never reached the provider does not hold its key: the next
    -- try (tomorrow, after a switch) must be able to claim it.
    case when v_status in ('sending', 'queued') then v_key end,
    nullif(p_message ->> 'retry_of', '')::uuid
  )
  returning id into v_new_id;

  insert into vppsone.whatsapp_message_events (message_id, event, status, error_code, detail)
  values (v_new_id, 'send', v_status, v_error_code,
          jsonb_build_object('feature', p_message ->> 'feature', 'used_today', v_used, 'limit', p_daily_limit));

  if v_status = 'held' and p_status in ('sending', 'queued') then
    return jsonb_build_object('ok', false, 'reason', 'daily_limit', 'id', v_new_id, 'used', v_used, 'limit', p_daily_limit);
  end if;
  return jsonb_build_object('ok', true, 'id', v_new_id, 'status', v_status, 'used', v_used);
end;
$$;

revoke all on function vppsone.whatsapp_claim_send(jsonb, text, integer) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_claim_send(jsonb, text, integer) to service_role;

/*
 * The queue job's lease: up to `p_limit` due rows, moved to `sending` in the
 * same statement, so two runs at once never take the same row.
 */
create function vppsone.whatsapp_take_due(p_limit integer)
returns setof vppsone.whatsapp_messages
language sql
security definer
set search_path = ''
as $$
  update vppsone.whatsapp_messages m
     set status = 'sending', updated_at = now()
   where m.id in (
     select d.id from vppsone.whatsapp_messages d
      where d.status in ('queued', 'retry_wait') and d.next_attempt_at <= now()
      order by d.next_attempt_at, d.id
      limit greatest(1, least(coalesce(p_limit, 10), 50))
      for update skip locked
   )
  returning m.*;
$$;

revoke all on function vppsone.whatsapp_take_due(integer) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_take_due(integer) to service_role;

/*
 * A status report from the WhatsApp server or Meta. Never backwards:
 * accepted < sent < delivered < read, and a report that arrives late (a
 * "sent" after a "read") changes nothing. `failed` overrides accepted and
 * sent, never delivered or read. Every report is kept as an event, matched or
 * not.
 */
create function vppsone.whatsapp_record_status(
  p_provider_message_id text,
  p_status text,
  p_at timestamptz,
  p_error_code text,
  p_error_title text,
  p_detail jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_current text;
  v_source_table text;
  v_source_id text;
  v_at timestamptz := coalesce(p_at, now());
  v_changed boolean := false;
  v_rank_new integer;
  v_rank_current integer;
begin
  if p_status not in ('sent', 'delivered', 'read', 'failed') then
    raise exception 'whatsapp_status:unknown';
  end if;

  select m.id, m.status, m.source_table, m.source_id
    into v_id, v_current, v_source_table, v_source_id
    from vppsone.whatsapp_messages m
   where m.provider_message_id = p_provider_message_id
   for update;

  if v_id is not null then
    v_rank_new := case p_status when 'sent' then 2 when 'delivered' then 3 when 'read' then 4 else 0 end;
    v_rank_current := case v_current when 'accepted' then 1 when 'sent' then 2 when 'delivered' then 3 when 'read' then 4 else 0 end;

    if p_status = 'failed' then
      if v_current in ('accepted', 'sent', 'unknown', 'sending') then
        update vppsone.whatsapp_messages m
           set status = 'failed', failed_at = v_at, error_code = p_error_code,
               error_title = p_error_title, updated_at = now()
         where m.id = v_id;
        v_changed := true;
      end if;
    elsif v_current <> 'failed' and v_rank_new > v_rank_current then
      update vppsone.whatsapp_messages m
         set status = p_status,
             sent_at = coalesce(m.sent_at, v_at),
             delivered_at = case when p_status in ('delivered', 'read') then coalesce(m.delivered_at, v_at) else m.delivered_at end,
             read_at = case when p_status = 'read' then coalesce(m.read_at, v_at) else m.read_at end,
             updated_at = now()
       where m.id = v_id;
      v_changed := true;
    end if;
  end if;

  insert into vppsone.whatsapp_message_events (message_id, provider_message_id, event, status, error_code, error_title, occurred_at, detail)
  values (v_id, p_provider_message_id, 'status', p_status, p_error_code, p_error_title, v_at, p_detail);

  return jsonb_build_object('matched', v_id is not null, 'changed', v_changed, 'id', v_id,
    'previous', v_current, 'source_table', v_source_table, 'source_id', v_source_id);
end;
$$;

revoke all on function vppsone.whatsapp_record_status(text, text, timestamptz, text, text, jsonb) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_record_status(text, text, timestamptz, text, text, jsonb) to service_role;

-- ------------------------------------------------------------ the timer

select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'WHATSAPP_QUEUE_CRON_SECRET',
  'D-562: pg_cron -> /api/jobs/whatsapp-queue. Checked by vppsone.whatsapp_queue_secret_matches; never copied to Vercel.')
where not exists (select 1 from vault.secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET');

create function vppsone.whatsapp_queue_secret_matches(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select s.decrypted_secret = p_secret and length(p_secret) = 64
       from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET'),
    false)
$$;

revoke all on function vppsone.whatsapp_queue_secret_matches(text) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_queue_secret_matches(text) to service_role;

-- Every five minutes, and only when something is due: an empty queue costs
-- one indexed read and no request to One.
select cron.schedule(
  'whatsapp-queue',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/whatsapp-queue',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (
    select 1 from vppsone.whatsapp_messages m
     where m.status in ('queued', 'retry_wait') and m.next_attempt_at <= now()
  );
  $job$
);

-- ------------------------------------------------- staff notices + health

alter table vppsone.staff_notice_attempts drop constraint if exists staff_notice_attempts_transport_known;
alter table vppsone.staff_notice_attempts add constraint staff_notice_attempts_transport_known
  check (transport in ('mock', 'aisensy', 'whatsapp', 'disabled'));

-- The month's staff sends: AiSensy's (history) and the school number's.
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
     where a.transport in ('aisensy', 'whatsapp') and a.state in ('sending', 'accepted', 'unknown')
       and a.started_at >= b.month_start)
    +
    (select count(*) from vppsone.message_sends m
       cross join lateral jsonb_array_elements(m.task_history) e, bounds b
     where m.task_id is not null and m.task_transport in ('aisensy', 'whatsapp')
       and e ->> 'event' = 'claim' and e ->> 'transport' in ('aisensy', 'whatsapp')
       and (e ->> 'at')::timestamptz >= b.month_start)
  )::integer
$$;

-- Ops health: the month's total is the school WhatsApp's now. Patched in
-- place, so the rest of the function stays byte-for-byte what was reviewed.
do $patch$
declare
  v_def text := pg_get_functiondef('vppsone.ops_health_counts(integer)'::regprocedure);
begin
  v_def := replace(v_def, $q$coalesce(m.task_transport, 'aisensy') = 'aisensy'$q$, $q$coalesce(m.task_transport, 'aisensy') in ('aisensy', 'whatsapp')$q$);
  v_def := replace(v_def, $q$'aisensy_month_total'$q$, $q$'whatsapp_month_total'$q$);
  v_def := replace(v_def, $q$'aisensy_month_plan_cap'$q$, $q$'whatsapp_month_plan_cap'$q$);
  v_def := replace(v_def, $q$'aisensy_plan_cap'$q$, $q$'whatsapp_plan_cap'$q$);
  if v_def ~ 'aisensy_' or v_def !~ 'whatsapp_month_total' then
    raise exception 'ops_health_counts was not patched as expected';
  end if;
  execute v_def;
end;
$patch$;

-- ---------------------------------------------------------------- seed

-- One's own staff and collection templates, as they are defined today.
insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, category, body_params, param_names, header, url_button, label_en, label_hi)
select
  mt.code,
  mt.code,
  case when mt.code ~ '_hi(_|$)' then 'hi' else 'en' end,
  case
    when mt.code like 'vppsone_teacher_task_%' then 'teacher_task'
    when mt.audience = 'parent' then 'general'
    when mt.code = 'vppsone_collection_link' then 'collection_request'
    else 'staff_notice'
  end,
  case when mt.wa_category in ('utility', 'marketing', 'authentication') then mt.wa_category else 'utility' end,
  coalesce(array_length(mt.variables, 1), 0),
  mt.variables,
  'none',
  mt.has_url_button,
  mt.label_en,
  mt.label_hi
from vppsone.message_templates mt
where mt.code !~* '_v6$'
on conflict (key) do nothing;

-- The fee-side templates, from scripts/whatsapp-template-catalog.mjs.
insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en) values
  ('vpps_app_fee_due_hi_v2', 'vpps_app_fee_due_hi_v2', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: fee due (hi)'),
  ('vpps_app_fee_due_en_v2', 'vpps_app_fee_due_en_v2', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: fee due (en)'),
  ('vpps_app_balance_hi_v2', 'vpps_app_balance_hi_v2', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: balance (hi)'),
  ('vpps_app_balance_en_v2', 'vpps_app_balance_en_v2', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: balance (en)'),
  ('vpps_app_prevyear_hi_v2', 'vpps_app_prevyear_hi_v2', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: prevyear (hi)'),
  ('vpps_app_prevyear_en_v2', 'vpps_app_prevyear_en_v2', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: prevyear (en)'),
  ('vpps_app_upcoming_hi_v3', 'vpps_app_upcoming_hi_v3', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: upcoming (hi)'),
  ('vpps_app_upcoming_en_v3', 'vpps_app_upcoming_en_v3', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: upcoming (en)'),
  ('vpps_app_upcoming_final_hi_v3', 'vpps_app_upcoming_final_hi_v3', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: upcoming final (hi)'),
  ('vpps_app_upcoming_final_en_v3', 'vpps_app_upcoming_final_en_v3', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: upcoming final (en)'),
  ('vpps_app_late_fee_applied_hi_v3', 'vpps_app_late_fee_applied_hi_v3', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'feesPending', 'lateFeeApplied', 'totalToPay']::text[], 'none', false, 'Fee reminder: late fee applied (hi)'),
  ('vpps_app_late_fee_applied_en_v3', 'vpps_app_late_fee_applied_en_v3', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'feesPending', 'lateFeeApplied', 'totalToPay']::text[], 'none', false, 'Fee reminder: late fee applied (en)'),
  ('vpps_app_promise_lapsed_hi_v3', 'vpps_app_promise_lapsed_hi_v3', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: promise lapsed (hi)'),
  ('vpps_app_promise_lapsed_en_v3', 'vpps_app_promise_lapsed_en_v3', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: promise lapsed (en)'),
  ('vpps_app_late_fee_waiver_hi_v4', 'vpps_app_late_fee_waiver_hi_v4', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'feesPending', 'lateFeeApplied', 'date']::text[], 'none', false, 'Fee reminder: late fee waiver (hi)'),
  ('vpps_app_late_fee_waiver_en_v4', 'vpps_app_late_fee_waiver_en_v4', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'feesPending', 'lateFeeApplied', 'date']::text[], 'none', false, 'Fee reminder: late fee waiver (en)'),
  ('vpps_app_waiver_last_call_hi_v4', 'vpps_app_waiver_last_call_hi_v4', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'feesPending', 'lateFeeApplied', 'date']::text[], 'none', false, 'Fee reminder: waiver last call (hi)'),
  ('vpps_app_waiver_last_call_en_v4', 'vpps_app_waiver_last_call_en_v4', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'feesPending', 'lateFeeApplied', 'date']::text[], 'none', false, 'Fee reminder: waiver last call (en)'),
  ('vpps_app_overdue_final_hi_v4', 'vpps_app_overdue_final_hi_v4', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: overdue final (hi)'),
  ('vpps_app_overdue_final_en_v4', 'vpps_app_overdue_final_en_v4', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: overdue final (en)'),
  ('vpps_app_promise_due_hi_v4', 'vpps_app_promise_due_hi_v4', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: promise due (hi)'),
  ('vpps_app_promise_due_en_v4', 'vpps_app_promise_due_en_v4', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: promise due (en)'),
  ('vpps_app_exam_clearance_hi_v4', 'vpps_app_exam_clearance_hi_v4', 'hi', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: exam clearance (hi)'),
  ('vpps_app_exam_clearance_en_v4', 'vpps_app_exam_clearance_en_v4', 'en', 'fee_reminder', 7, array['parentName', 'studentName', 'studentClass', 'contextLine', 'amount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder: exam clearance (en)'),
  ('vpps_app_family_fee_due_hi_v3', 'vpps_app_family_fee_due_hi_v3', 'hi', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: fee due (hi)'),
  ('vpps_app_family_fee_due_en_v3', 'vpps_app_family_fee_due_en_v3', 'en', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: fee due (en)'),
  ('vpps_app_family_balance_hi_v3', 'vpps_app_family_balance_hi_v3', 'hi', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: balance (hi)'),
  ('vpps_app_family_balance_en_v3', 'vpps_app_family_balance_en_v3', 'en', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: balance (en)'),
  ('vpps_app_family_upcoming_hi_v3', 'vpps_app_family_upcoming_hi_v3', 'hi', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: upcoming (hi)'),
  ('vpps_app_family_upcoming_en_v3', 'vpps_app_family_upcoming_en_v3', 'en', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: upcoming (en)'),
  ('vpps_app_family_late_fee_applied_hi_v3', 'vpps_app_family_late_fee_applied_hi_v3', 'hi', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: late fee applied (hi)'),
  ('vpps_app_family_late_fee_applied_en_v3', 'vpps_app_family_late_fee_applied_en_v3', 'en', 'fee_reminder', 5, array['parentName', 'childrenLine', 'totalAmount', 'date', 'lateFeePhrase']::text[], 'none', false, 'Fee reminder for a family: late fee applied (en)'),
  ('vpps_app_upcoming_hi_v7', 'vpps_app_upcoming_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: upcoming (hi)'),
  ('vpps_app_upcoming_en_v7', 'vpps_app_upcoming_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: upcoming (en)'),
  ('vpps_app_upcoming_final_hi_v7', 'vpps_app_upcoming_final_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: upcoming final (hi)'),
  ('vpps_app_upcoming_final_en_v7', 'vpps_app_upcoming_final_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: upcoming final (en)'),
  ('vpps_app_fee_due_hi_v7', 'vpps_app_fee_due_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: fee due (hi)'),
  ('vpps_app_fee_due_en_v7', 'vpps_app_fee_due_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: fee due (en)'),
  ('vpps_app_balance_hi_v7', 'vpps_app_balance_hi_v7', 'hi', 'fee_reminder', 5, array['balance', 'students', 'receivedSoFar', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: balance (hi)'),
  ('vpps_app_balance_en_v7', 'vpps_app_balance_en_v7', 'en', 'fee_reminder', 5, array['balance', 'students', 'receivedSoFar', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: balance (en)'),
  ('vpps_app_overdue_final_hi_v7', 'vpps_app_overdue_final_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: overdue final (hi)'),
  ('vpps_app_overdue_final_en_v7', 'vpps_app_overdue_final_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: overdue final (en)'),
  ('vpps_app_late_fee_waiver_hi_v7', 'vpps_app_late_fee_waiver_hi_v7', 'hi', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now: late fee waiver (hi)'),
  ('vpps_app_late_fee_waiver_en_v7', 'vpps_app_late_fee_waiver_en_v7', 'en', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now: late fee waiver (en)'),
  ('vpps_app_waiver_last_call_hi_v7', 'vpps_app_waiver_last_call_hi_v7', 'hi', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now: waiver last call (hi)'),
  ('vpps_app_waiver_last_call_en_v7', 'vpps_app_waiver_last_call_en_v7', 'en', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now: waiver last call (en)'),
  ('vpps_app_promise_due_hi_v7', 'vpps_app_promise_due_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'spokenOn', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: promise due (hi)'),
  ('vpps_app_promise_due_en_v7', 'vpps_app_promise_due_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'spokenOn', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: promise due (en)'),
  ('vpps_app_promise_lapsed_hi_v7', 'vpps_app_promise_lapsed_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'promisedDate', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: promise lapsed (hi)'),
  ('vpps_app_promise_lapsed_en_v7', 'vpps_app_promise_lapsed_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'promisedDate', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: promise lapsed (en)'),
  ('vpps_app_exam_clearance_hi_v7', 'vpps_app_exam_clearance_hi_v7', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: exam clearance (hi)'),
  ('vpps_app_exam_clearance_en_v7', 'vpps_app_exam_clearance_en_v7', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: exam clearance (en)'),
  ('vpps_app_prevyear_hi_v7', 'vpps_app_prevyear_hi_v7', 'hi', 'fee_reminder', 5, array['balance', 'students', 'session', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: prevyear (hi)'),
  ('vpps_app_prevyear_en_v7', 'vpps_app_prevyear_en_v7', 'en', 'fee_reminder', 5, array['balance', 'students', 'session', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now: prevyear (en)'),
  ('vpps_app_receipt_hi_v5', 'vpps_app_receipt_hi_v5', 'hi', 'receipt', 7, array['parentName', 'studentName', 'studentClass', 'receiptNumber', 'amountPaid', 'paymentDate', 'remainingBalance']::text[], 'document', false, 'Receipt with the PDF attached (hi)'),
  ('vpps_app_receipt_en_v5', 'vpps_app_receipt_en_v5', 'en', 'receipt', 7, array['parentName', 'studentName', 'studentClass', 'receiptNumber', 'amountPaid', 'paymentDate', 'remainingBalance']::text[], 'document', false, 'Receipt with the PDF attached (en)'),
  ('vpps_app_receipt_hi_v3', 'vpps_app_receipt_hi_v3', 'hi', 'receipt', 7, array['parentName', 'studentName', 'studentClass', 'receiptNumber', 'amountPaid', 'paymentDate', 'remainingBalance']::text[], 'none', false, 'Receipt, text only (hi)'),
  ('vpps_app_receipt_en_v3', 'vpps_app_receipt_en_v3', 'en', 'receipt', 7, array['parentName', 'studentName', 'studentClass', 'receiptNumber', 'amountPaid', 'paymentDate', 'remainingBalance']::text[], 'none', false, 'Receipt, text only (en)'),
  ('vpps_app_reversal_hi_v1', 'vpps_app_reversal_hi_v1', 'hi', 'reversal', 6, array['parentName', 'studentName', 'receiptNumber', 'amountReversed', 'reversedOn', 'remainingBalance']::text[], 'none', false, 'Receipt cancelled (hi)'),
  ('vpps_app_reversal_en_v1', 'vpps_app_reversal_en_v1', 'en', 'reversal', 6, array['parentName', 'studentName', 'receiptNumber', 'amountReversed', 'reversedOn', 'remainingBalance']::text[], 'none', false, 'Receipt cancelled (en)'),
  ('vpps_app_fee_statement_hi_v1', 'vpps_app_fee_statement_hi_v1', 'hi', 'fee_statement', 5, array['parentName', 'studentName', 'studentClass', 'sessionLabel', 'pendingAmount']::text[], 'document', false, 'Fee statement with the PDF attached (hi)'),
  ('vpps_app_fee_statement_en_v1', 'vpps_app_fee_statement_en_v1', 'en', 'fee_statement', 5, array['parentName', 'studentName', 'studentClass', 'sessionLabel', 'pendingAmount']::text[], 'document', false, 'Fee statement with the PDF attached (en)'),
  ('vpps_school_absent_hi_v1', 'vpps_school_absent_hi_v1', 'hi', 'absent_notice', 3, array['विद्यार्थी', 'कक्षा', 'तिथि']::text[], 'none', false, 'School notice: absent today (hi)'),
  ('vpps_school_absent_en_v1', 'vpps_school_absent_en_v1', 'en', 'absent_notice', 3, array['Student', 'Class', 'Date']::text[], 'none', false, 'School notice: absent today (en)'),
  ('vpps_school_exam_schedule_hi_v1', 'vpps_school_exam_schedule_hi_v1', 'hi', 'school_notice', 5, array['विद्यार्थी', 'कक्षा', 'परीक्षा', 'प्रारंभ तिथि', 'उपस्थिति का समय']::text[], 'none', false, 'School notice: exam schedule (hi)'),
  ('vpps_school_exam_schedule_en_v1', 'vpps_school_exam_schedule_en_v1', 'en', 'school_notice', 5, array['Student', 'Class', 'Examination', 'Starts on', 'Reporting time']::text[], 'none', false, 'School notice: exam schedule (en)'),
  ('vpps_school_ptm_hi_v1', 'vpps_school_ptm_hi_v1', 'hi', 'school_notice', 4, array['विद्यार्थी', 'कक्षा', 'तिथि', 'समय']::text[], 'none', false, 'School notice: ptm (hi)'),
  ('vpps_school_ptm_en_v1', 'vpps_school_ptm_en_v1', 'en', 'school_notice', 4, array['Student', 'Class', 'Date', 'Time']::text[], 'none', false, 'School notice: ptm (en)'),
  ('vpps_school_closed_hi_v1', 'vpps_school_closed_hi_v1', 'hi', 'school_notice', 4, array['विद्यार्थी', 'अवकाश तिथि', 'कारण', 'विद्यालय पुनः खुलने की तिथि']::text[], 'none', false, 'School notice: school closed (hi)'),
  ('vpps_school_closed_en_v1', 'vpps_school_closed_en_v1', 'en', 'school_notice', 4, array['For', 'Closed on', 'Reason', 'School reopens on']::text[], 'none', false, 'School notice: school closed (en)')
on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261109062527_task_delivery_whatsapp_transport.sql
-- Teacher task messages go out through the school's own WhatsApp (D-562).
--
-- `claim_teacher_task_delivery` took exactly one machine transport, 'aisensy'.
-- One no longer talks to AiSensy, so the claim takes 'whatsapp' instead (the
-- school's number, through src/platform/whatsapp). 'manual' (the office opens
-- WhatsApp itself) is unchanged. Rows already written with 'aisensy' stay
-- valid history, so the column still allows it.
--
-- The function is patched in place from its live definition: one condition
-- changes and the rest stays byte-for-byte what was reviewed in
-- 20261016090000 and 20261107174655.
--
-- Rollback: the same replace in reverse, and the constraint without
-- 'whatsapp' once no row carries it.

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

alter table vppsone.message_sends drop constraint if exists message_sends_task_transport_check;
alter table vppsone.message_sends add constraint message_sends_task_transport_check
  check (task_transport in ('aisensy', 'whatsapp', 'manual'));

do $patch$
declare
  v_def text := pg_get_functiondef('vppsone.claim_teacher_task_delivery(uuid,uuid,text,text,boolean)'::regprocedure);
begin
  v_def := replace(v_def, $q$p_transport<>'aisensy'$q$, $q$p_transport<>'whatsapp'$q$);
  if v_def ~ 'aisensy' or v_def !~ $q$p_transport<>'whatsapp'$q$ then
    raise exception 'claim_teacher_task_delivery was not patched as expected';
  end if;
  execute v_def;
end;
$patch$;

commit;

-- ======================================================== migrations/20261109082705_whatsapp_hub.sql
-- One talks to the school's WhatsApp hub (D-566, after D-562).
--
-- The hub (https://vpps-whatsapp-hub.raj-39e.workers.dev, repo
-- veerpatta/vpps-whatsapp-hub) owns +91 83022 07823 on Meta's Cloud API. One
-- sends through it with Meta's own JSON and its own key (WHATSAPP_HUB_KEY,
-- server-only). The fees app keeps its AiSensy number (+91 80 4713 6289) and
-- nothing here touches it.
--
-- What this adds, all in `vppsone`:
--
--  * `whatsapp_templates.quality` and `.submitted_at`: the hub's quality
--    rating for an approved template, and when One handed a template to Meta
--    for review (Settings -> WhatsApp -> Send for approval). A row sent from
--    here and not yet in the hub's list reads `pending`, not `not_submitted`.
--  * `whatsapp_messages.status_polls` and `.status_polled_at`: the hub's
--    webhook is best-effort, so the queue job also asks the hub
--    (`GET /v1/status/{wamid}`) about messages it has not heard back on. Each
--    message is asked at most four times, ten minutes, an hour, four hours and
--    sixteen hours after it went, and never after two days.
--  * `whatsapp_poll_is_due` (the rule) and `whatsapp_take_pollable` (the
--    lease, like `whatsapp_take_due`).
--  * The queue's timer now also wakes One when a message is due a poll.
--  * 22 `_v8` registry rows: the `_v7` fee reminders with Pay now, word for
--    word, under new names for the hub's account. `_v7` was submitted on
--    AiSensy's account for the fees number, which One never uses. Every row
--    starts `not_submitted`; only the hub's list can make one `approved`.
--
-- Rollback (nothing else depends on these):
--   select cron.schedule('whatsapp-queue', '*/5 * * * *', <the command from 20261109062459>);
--   drop function vppsone.whatsapp_take_pollable(integer), vppsone.whatsapp_poll_is_due(vppsone.whatsapp_messages);
--   drop index vppsone.whatsapp_messages_pollable_idx;
--   alter table vppsone.whatsapp_messages drop column status_polls, drop column status_polled_at;
--   alter table vppsone.whatsapp_templates drop column quality, drop column submitted_at;
--   delete from vppsone.whatsapp_templates where key like '%\_v8' and status = 'not_submitted';

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

-- --------------------------------------------------------------- registry

alter table vppsone.whatsapp_templates
  add column quality text,
  add column submitted_at timestamptz;

comment on column vppsone.whatsapp_templates.quality is
  'D-566: the hub''s quality rating for this template (GREEN / YELLOW / RED / UNKNOWN), from GET /v1/templates.';
comment on column vppsone.whatsapp_templates.submitted_at is
  'D-566: when One sent this template to Meta for review through the hub (POST /v1/templates). Null when it was never sent from One.';

comment on table vppsone.whatsapp_templates is
  'D-562/D-566: templates on the school''s own WhatsApp account (+91 83022 07823). A message goes out only under a row whose status is approved, and only the hub''s template list (Settings -> WhatsApp -> Check templates) makes a row approved. Nobody marks one by hand.';

-- ------------------------------------------------------------- status poll

alter table vppsone.whatsapp_messages
  add column status_polls integer not null default 0,
  add column status_polled_at timestamptz,
  add constraint whatsapp_messages_status_polls_range check (status_polls between 0 and 10);

create index whatsapp_messages_pollable_idx
  on vppsone.whatsapp_messages (created_at)
  where provider = 'hub' and status in ('accepted', 'sent') and provider_message_id is not null;

/*
 * Is this message due a question to the hub? Only the hub's own messages
 * that have gone and not been delivered, read or failed; at most four times,
 * ten minutes, an hour, four hours and sixteen hours after the send; never
 * after two days (a phone that has been off that long is not news).
 */
create function vppsone.whatsapp_poll_is_due(m vppsone.whatsapp_messages)
returns boolean
language sql
stable
set search_path = ''
as $$
  select m.provider = 'hub'
     and m.status in ('accepted', 'sent')
     and m.provider_message_id is not null
     and m.status_polls < 4
     and coalesce(m.last_attempt_at, m.created_at) > now() - interval '48 hours'
     and coalesce(m.last_attempt_at, m.created_at)
         + case m.status_polls
             when 0 then interval '10 minutes'
             when 1 then interval '1 hour'
             when 2 then interval '4 hours'
             else interval '16 hours'
           end <= now();
$$;

revoke all on function vppsone.whatsapp_poll_is_due(vppsone.whatsapp_messages) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_poll_is_due(vppsone.whatsapp_messages) to service_role;

/*
 * The queue job's poll lease: up to `p_limit` messages due a question, each
 * counted as asked in the same statement, so two runs at once never ask
 * about the same message and a hub that never answers costs four questions.
 */
create function vppsone.whatsapp_take_pollable(p_limit integer)
returns setof vppsone.whatsapp_messages
language sql
security definer
set search_path = ''
as $$
  update vppsone.whatsapp_messages m
     set status_polls = m.status_polls + 1, status_polled_at = now()
   where m.id in (
     select d.id from vppsone.whatsapp_messages d
      where d.provider = 'hub' and d.status in ('accepted', 'sent') and d.provider_message_id is not null
        and vppsone.whatsapp_poll_is_due(d)
      order by d.created_at, d.id
      limit greatest(1, least(coalesce(p_limit, 20), 50))
      for update skip locked
   )
  returning m.*;
$$;

revoke all on function vppsone.whatsapp_take_pollable(integer) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_take_pollable(integer) to service_role;

-- ------------------------------------------------------------- the timer

-- Same job, same five minutes; it now also wakes One when a message is due
-- a poll. An empty queue still costs two indexed reads and no request.
select cron.schedule(
  'whatsapp-queue',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/whatsapp-queue',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (
    select 1 from vppsone.whatsapp_messages m
     where m.status in ('queued', 'retry_wait') and m.next_attempt_at <= now()
  )
  or exists (
    select 1 from vppsone.whatsapp_messages m
     where m.provider = 'hub' and m.status in ('accepted', 'sent') and m.provider_message_id is not null
       and vppsone.whatsapp_poll_is_due(m)
  );
  $job$
);

-- ------------------------------------------------------ the _v8 templates

-- Printed by scripts/whatsapp-template-catalog.mjs; held to the app's own
-- descriptors by tests/whatsapp-template-catalog.test.ts.
insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en) values
  ('vpps_app_upcoming_hi_v8', 'vpps_app_upcoming_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: upcoming (hi)'),
  ('vpps_app_upcoming_en_v8', 'vpps_app_upcoming_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: upcoming (en)'),
  ('vpps_app_upcoming_final_hi_v8', 'vpps_app_upcoming_final_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: upcoming final (hi)'),
  ('vpps_app_upcoming_final_en_v8', 'vpps_app_upcoming_final_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: upcoming final (en)'),
  ('vpps_app_fee_due_hi_v8', 'vpps_app_fee_due_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: fee due (hi)'),
  ('vpps_app_fee_due_en_v8', 'vpps_app_fee_due_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: fee due (en)'),
  ('vpps_app_balance_hi_v8', 'vpps_app_balance_hi_v8', 'hi', 'fee_reminder', 5, array['balance', 'students', 'receivedSoFar', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: balance (hi)'),
  ('vpps_app_balance_en_v8', 'vpps_app_balance_en_v8', 'en', 'fee_reminder', 5, array['balance', 'students', 'receivedSoFar', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: balance (en)'),
  ('vpps_app_overdue_final_hi_v8', 'vpps_app_overdue_final_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: overdue final (hi)'),
  ('vpps_app_overdue_final_en_v8', 'vpps_app_overdue_final_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: overdue final (en)'),
  ('vpps_app_late_fee_waiver_hi_v8', 'vpps_app_late_fee_waiver_hi_v8', 'hi', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: late fee waiver (hi)'),
  ('vpps_app_late_fee_waiver_en_v8', 'vpps_app_late_fee_waiver_en_v8', 'en', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: late fee waiver (en)'),
  ('vpps_app_waiver_last_call_hi_v8', 'vpps_app_waiver_last_call_hi_v8', 'hi', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: waiver last call (hi)'),
  ('vpps_app_waiver_last_call_en_v8', 'vpps_app_waiver_last_call_en_v8', 'en', 'fee_reminder', 5, array['feesPending', 'students', 'context', 'lateFeeApplied', 'date']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: waiver last call (en)'),
  ('vpps_app_promise_due_hi_v8', 'vpps_app_promise_due_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'spokenOn', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: promise due (hi)'),
  ('vpps_app_promise_due_en_v8', 'vpps_app_promise_due_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'spokenOn', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: promise due (en)'),
  ('vpps_app_promise_lapsed_hi_v8', 'vpps_app_promise_lapsed_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'promisedDate', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: promise lapsed (hi)'),
  ('vpps_app_promise_lapsed_en_v8', 'vpps_app_promise_lapsed_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'promisedDate', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: promise lapsed (en)'),
  ('vpps_app_exam_clearance_hi_v8', 'vpps_app_exam_clearance_hi_v8', 'hi', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: exam clearance (hi)'),
  ('vpps_app_exam_clearance_en_v8', 'vpps_app_exam_clearance_en_v8', 'en', 'fee_reminder', 5, array['amount', 'students', 'context', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: exam clearance (en)'),
  ('vpps_app_prevyear_hi_v8', 'vpps_app_prevyear_hi_v8', 'hi', 'fee_reminder', 5, array['balance', 'students', 'session', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: prevyear (hi)'),
  ('vpps_app_prevyear_en_v8', 'vpps_app_prevyear_en_v8', 'en', 'fee_reminder', 5, array['balance', 'students', 'session', 'date', 'lateFeePhrase']::text[], 'none', true, 'Fee reminder with Pay now, on the hub: prevyear (en)')
on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261110071216_apinex_free.sql
-- APInex's free models in the AI helper (D-567).
--
-- One more free provider, `apinex-free`: an OpenAI-shaped gateway whose
-- `free/...` models cost nothing. Like the other free providers it only ever
-- sees the open tasks, or a test account's text; never a photo.
--
--  * assist_log.provider may now say `apinex-free`. The model column already
--    names which of APInex's models wrote the draft (`free/glm-5.3`).
--  * assist_settings.free_check keeps the last "Check free models" run from
--    Settings -> AI in One -> Cost: which free models APInex listed, and for
--    each one whether it wrote a usable notice and cover plan, and how fast.
--    Only model names, times, a fixed problem word and an HTTP status; never
--    an answer, a prompt or a key. The helper uses it to skip models that did
--    not answer. Null until the first check.
--
-- Rollback: alter table vppsone.assist_settings drop column free_check;
--           alter table vppsone.assist_log drop constraint assist_log_provider_known;
--           alter table vppsone.assist_log add constraint assist_log_provider_known
--             check (provider in ('nvidia-free', 'openrouter-free', 'gemini-free', 'anthropic', 'openai', 'gemini-paid'));
--           (after deleting or nulling any rows whose provider is 'apinex-free')
--
-- Applied to One (wtgxcptmucjerhufzjcf) on 10 Nov 2026; the file carries the version the database recorded.

alter table vppsone.assist_log drop constraint if exists assist_log_provider_known;
alter table vppsone.assist_log
  add constraint assist_log_provider_known
  check (provider in ('nvidia-free', 'openrouter-free', 'gemini-free', 'apinex-free', 'anthropic', 'openai', 'gemini-paid'));

alter table vppsone.assist_settings
  add column if not exists free_check jsonb
  constraint assist_settings_free_check_shape
  check (free_check is null or (jsonb_typeof(free_check) = 'object' and pg_column_size(free_check) < 65536));

comment on column vppsone.assist_settings.free_check is
  'The last check of APInex''s free models (D-567): {at, blocked, models[], results[{model, probe, ok, ms, problem?, httpStatus?}]}. No answer, prompt or key.';

-- ======================================================== migrations/20261111060151_whatsapp_statuses_and_template_check.sql
-- One keeps only statuses for its own messages, and checks the hub's templates
-- hourly (owner, 11 Nov 2026: "yes, fix them" for the gaps found in the review
-- of the school's WhatsApp hub). D-571, D-572.
--
--  * `whatsapp_record_status` no longer writes an event for a message One did
--    not send (the hub forwards every status on the school's number; the
--    hub's own dashboard, bot and broadcasts are not One's business).
--  * `whatsapp-templates`: pg_cron reads the hub's template list through One
--    once an hour (minute 17), so an approval whose webhook was lost still
--    reaches One. Same Vault secret as the queue.
--
-- Rollback:
--   select cron.unschedule('whatsapp-templates');
--   (restore whatsapp_record_status from 20261109062459.)

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

create or replace function vppsone.whatsapp_record_status(
  p_provider_message_id text,
  p_status text,
  p_at timestamptz,
  p_error_code text,
  p_error_title text,
  p_detail jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_current text;
  v_source_table text;
  v_source_id text;
  v_at timestamptz := coalesce(p_at, now());
  v_changed boolean := false;
  v_rank_new integer;
  v_rank_current integer;
begin
  if p_status not in ('sent', 'delivered', 'read', 'failed') then
    raise exception 'whatsapp_status:unknown';
  end if;

  select m.id, m.status, m.source_table, m.source_id
    into v_id, v_current, v_source_table, v_source_id
    from vppsone.whatsapp_messages m
   where m.provider_message_id = p_provider_message_id
   for update;

  -- Not a message One sent: nothing to write, and no trace kept.
  if v_id is null then
    return jsonb_build_object('matched', false, 'changed', false, 'id', null,
      'previous', null, 'source_table', null, 'source_id', null);
  end if;

  v_rank_new := case p_status when 'sent' then 2 when 'delivered' then 3 when 'read' then 4 else 0 end;
  v_rank_current := case v_current when 'accepted' then 1 when 'sent' then 2 when 'delivered' then 3 when 'read' then 4 else 0 end;

  if p_status = 'failed' then
    if v_current in ('accepted', 'sent', 'unknown', 'sending') then
      update vppsone.whatsapp_messages m
         set status = 'failed', failed_at = v_at, error_code = p_error_code,
             error_title = p_error_title, updated_at = now()
       where m.id = v_id;
      v_changed := true;
    end if;
  elsif v_current <> 'failed' and v_rank_new > v_rank_current then
    update vppsone.whatsapp_messages m
       set status = p_status,
           sent_at = coalesce(m.sent_at, v_at),
           delivered_at = case when p_status in ('delivered', 'read') then coalesce(m.delivered_at, v_at) else m.delivered_at end,
           read_at = case when p_status = 'read' then coalesce(m.read_at, v_at) else m.read_at end,
           updated_at = now()
     where m.id = v_id;
    v_changed := true;
  end if;

  insert into vppsone.whatsapp_message_events (message_id, provider_message_id, event, status, error_code, error_title, occurred_at, detail)
  values (v_id, p_provider_message_id, 'status', p_status, p_error_code, p_error_title, v_at, p_detail);

  return jsonb_build_object('matched', true, 'changed', v_changed, 'id', v_id,
    'previous', v_current, 'source_table', v_source_table, 'source_id', v_source_id);
end;
$$;

revoke all on function vppsone.whatsapp_record_status(text, text, timestamptz, text, text, jsonb) from public, anon, authenticated;
grant execute on function vppsone.whatsapp_record_status(text, text, timestamptz, text, text, jsonb) to service_role;

select cron.schedule(
  'whatsapp-templates',
  '17 * * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/whatsapp-templates',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $job$
);

commit;

-- ======================================================== migrations/20261111060200_whatsapp_fee_sender_and_cleanup.sql
-- One and the Fees app kept apart on WhatsApp, and One keeps only what is its
-- own (owner, 11 Nov 2026: "keep both the apps separate", and "yes, fix them"
-- for the gaps found in the review of the school's WhatsApp hub). D-570, D-571.
--
--  * `whatsapp_fee_sender` in `runtime_flags`: who sends fee reminders,
--    receipts, reversal notices and fee statements to parents. `fees` = the
--    Fees app, from its own AiSensy number, and One refuses them
--    (platform/whatsapp/policy.ts FEES_APP_FEATURES). Only `one`, written on
--    the owner's word once the Fees app has stopped sending them, lets One.
--    Until this row exists One reads a missing row as `fees`, so applying it
--    changes nothing about what One sends.
--  * The copies One had made of messages that were not replies to One, and of
--    statuses for messages One never sent, are removed: the hub keeps the
--    originals in its own inbox.
--
-- The rest of the 11 Nov change (statuses, hourly template check) is
-- 20261111060151. This half deletes rows, so the Supabase connector asks the
-- owner to confirm it; apply it with `npx supabase db push --linked` or with
-- the owner present, then `git mv` this file to the recorded version.
--
-- Rollback:
--   delete from vppsone.runtime_flags where key = 'whatsapp_fee_sender';
--   (restore runtime_flags_key_known from 20261109062459.)

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

-- ---------------------------------------------------------- who sends what

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
    'ai_connection',
    'whatsapp_dry_run',
    'whatsapp_features',
    'whatsapp_real_recipients',
    'whatsapp_owner_test_number',
    'whatsapp_daily_limit',
    'whatsapp_month_plan_cap',
    'whatsapp_fee_sender'
  )
);

insert into vppsone.runtime_flags (key, enabled, value, note) values
  ('whatsapp_fee_sender', true, '"fees"'::jsonb,
   'Who sends fee reminders, receipts, reversal notices and fee statements to parents. "fees" = the Fees app from its own number, and One refuses them. "one" only on the owner''s word, once the Fees app has stopped sending them.')
on conflict (key) do nothing;

-- --------------------------------------------- only what is One's, kept

delete from vppsone.whatsapp_message_events e
 where e.message_id is null and e.event = 'status';

-- A reply to One quotes a message One sent, or comes within 7 days after One
-- messaged that number (platform/whatsapp/store.ts isReplyToOne).
delete from vppsone.whatsapp_inbound i
 where i.reply_to_message_id is null
   and not exists (
     select 1 from vppsone.whatsapp_messages m
      where m.to_e164 = i.from_e164
        and m.provider_message_id is not null
        and m.created_at <= i.received_at
        and m.created_at >= i.received_at - interval '7 days'
   );

commit;

-- ======================================================== migrations/20261112024037_whatsapp_staff_hub_templates.sql
-- One's staff notices and teacher tasks on the school's WhatsApp hub (owner,
-- 12 Nov 2026: "Yes submit them"). D-573.
--
-- The staff templates were written for AiSensy: one name per message, one
-- English body, most starting with the person's name ("{{1}}, ...") and
-- ending with a link ("... {{6}}"). Meta refuses a body that starts or ends
-- with a blank, and a Hindi reader would get English words around Hindi
-- values. So the hub gets its own copy of each, one name per message and
-- language (vpps_staff_<slug>_<hi|en>_v1), with a title, the school's name,
-- one labelled line per value and a closing line. The blanks keep the old
-- order, so the renderers are unchanged; One sends under these names at the
-- last step (src/modules/whatsapp/domain/staff-hub-templates.ts, staffHubKey).
--
-- Rows only, all `not_submitted`: nothing is sent to anyone. The hourly
-- template check (pg_cron job 'whatsapp-templates') sends a never-sent row to
-- Meta for approval by itself, up to 15 an hour; Settings -> WhatsApp ->
-- Send for approval sends the rest. The parents' school notices (absent
-- today, school closed, exam schedule, PTM) already have rows
-- (20261109062459) and go as they are. The old AiSensy-era staff rows stay as
-- history; Settings counts a feature against its hub names once it has them.
--
-- Rollback, only while none is approved and in use: remove the 40 rows whose
-- key starts with vpps_staff_ (their names are listed below).

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_staff_cover_assigned_hi_v1', 'vpps_staff_cover_assigned_hi_v1', 'hi', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover assigned, on the hub (hi)', 'आपके लिए व्यवस्था'),
  ('vpps_staff_cover_assigned_en_v1', 'vpps_staff_cover_assigned_en_v1', 'en', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover assigned, on the hub (en)', 'आपके लिए व्यवस्था'),
  ('vpps_staff_cover_changed_hi_v1', 'vpps_staff_cover_changed_hi_v1', 'hi', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover changed, on the hub (hi)', 'व्यवस्था में बदलाव'),
  ('vpps_staff_cover_changed_en_v1', 'vpps_staff_cover_changed_en_v1', 'en', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover changed, on the hub (en)', 'व्यवस्था में बदलाव'),
  ('vpps_staff_cover_cancelled_hi_v1', 'vpps_staff_cover_cancelled_hi_v1', 'hi', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover cancelled, on the hub (hi)', 'व्यवस्था रद्द'),
  ('vpps_staff_cover_cancelled_en_v1', 'vpps_staff_cover_cancelled_en_v1', 'en', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover cancelled, on the hub (en)', 'व्यवस्था रद्द'),
  ('vpps_staff_cover_needed_hi_v1', 'vpps_staff_cover_needed_hi_v1', 'hi', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover refused, on the hub (hi)', 'व्यवस्था चाहिए'),
  ('vpps_staff_cover_needed_en_v1', 'vpps_staff_cover_needed_en_v1', 'en', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover refused, on the hub (en)', 'व्यवस्था चाहिए'),
  ('vpps_staff_register_not_saved_hi_v1', 'vpps_staff_register_not_saved_hi_v1', 'hi', 'staff_notice', 4, array['name', 'day', 'class', 'link']::text[], 'none', false, 'Register not saved, on the hub (hi)', 'हाज़िरी दर्ज नहीं हुई'),
  ('vpps_staff_register_not_saved_en_v1', 'vpps_staff_register_not_saved_en_v1', 'en', 'staff_notice', 4, array['name', 'day', 'class', 'link']::text[], 'none', false, 'Register not saved, on the hub (en)', 'हाज़िरी दर्ज नहीं हुई'),
  ('vpps_staff_marks_pending_hi_v1', 'vpps_staff_marks_pending_hi_v1', 'hi', 'staff_notice', 2, array['Teacher name', 'Which papers']::text[], 'none', false, 'Marks reminder, on the hub (hi)', 'अंक बाकी'),
  ('vpps_staff_marks_pending_en_v1', 'vpps_staff_marks_pending_en_v1', 'en', 'staff_notice', 2, array['Teacher name', 'Which papers']::text[], 'none', false, 'Marks reminder, on the hub (en)', 'अंक बाकी'),
  ('vpps_staff_weekly_summary_hi_v1', 'vpps_staff_weekly_summary_hi_v1', 'hi', 'staff_notice', 3, array['name', 'summary', 'from']::text[], 'none', false, 'Weekly academic summary, on the hub (hi)', 'साप्ताहिक शैक्षणिक सारांश'),
  ('vpps_staff_weekly_summary_en_v1', 'vpps_staff_weekly_summary_en_v1', 'en', 'staff_notice', 3, array['name', 'summary', 'from']::text[], 'none', false, 'Weekly academic summary, on the hub (en)', 'साप्ताहिक शैक्षणिक सारांश'),
  ('vpps_staff_notice_hi_v1', 'vpps_staff_notice_hi_v1', 'hi', 'staff_notice', 1, array['text']::text[], 'none', false, 'Staff notice, on the hub (hi)', 'स्टाफ़ सूचना'),
  ('vpps_staff_notice_en_v1', 'vpps_staff_notice_en_v1', 'en', 'staff_notice', 1, array['text']::text[], 'none', false, 'Staff notice, on the hub (en)', 'स्टाफ़ सूचना'),
  ('vpps_staff_online_payment_check_hi_v1', 'vpps_staff_online_payment_check_hi_v1', 'hi', 'staff_notice', 4, array['name', 'amount', 'student or class', 'link']::text[], 'none', false, 'Online payment needs review, on the hub (hi)', 'ऑनलाइन भुगतान जाँचें'),
  ('vpps_staff_online_payment_check_en_v1', 'vpps_staff_online_payment_check_en_v1', 'en', 'staff_notice', 4, array['name', 'amount', 'student or class', 'link']::text[], 'none', false, 'Online payment needs review, on the hub (en)', 'ऑनलाइन भुगतान जाँचें'),
  ('vpps_staff_online_payment_hi_v1', 'vpps_staff_online_payment_hi_v1', 'hi', 'staff_notice', 5, array['name', 'amount', 'student or class', 'receipt', 'link']::text[], 'none', false, 'Online payment received, on the hub (hi)', 'ऑनलाइन भुगतान मिला'),
  ('vpps_staff_online_payment_en_v1', 'vpps_staff_online_payment_en_v1', 'en', 'staff_notice', 5, array['name', 'amount', 'student or class', 'receipt', 'link']::text[], 'none', false, 'Online payment received, on the hub (en)', 'ऑनलाइन भुगतान मिला'),
  ('vpps_staff_day_collection_hi_v1', 'vpps_staff_day_collection_hi_v1', 'hi', 'staff_notice', 6, array['name', 'day', 'total', 'receipts', 'by mode', 'link']::text[], 'none', false, 'Day''s collection, on the hub (hi)', 'दिन का फ़ीस संग्रह'),
  ('vpps_staff_day_collection_en_v1', 'vpps_staff_day_collection_en_v1', 'en', 'staff_notice', 6, array['name', 'day', 'total', 'receipts', 'by mode', 'link']::text[], 'none', false, 'Day''s collection, on the hub (en)', 'दिन का फ़ीस संग्रह'),
  ('vpps_staff_day_not_closed_hi_v1', 'vpps_staff_day_not_closed_hi_v1', 'hi', 'staff_notice', 5, array['name', 'day', 'receipts', 'total', 'link']::text[], 'none', false, 'Day not closed, on the hub (hi)', 'दिन बंद नहीं हुआ'),
  ('vpps_staff_day_not_closed_en_v1', 'vpps_staff_day_not_closed_en_v1', 'en', 'staff_notice', 5, array['name', 'day', 'receipts', 'total', 'link']::text[], 'none', false, 'Day not closed, on the hub (en)', 'दिन बंद नहीं हुआ'),
  ('vpps_staff_money_request_hi_v1', 'vpps_staff_money_request_hi_v1', 'hi', 'staff_notice', 6, array['name', 'what', 'amount', 'student or class', 'asked by', 'link']::text[], 'none', false, 'Reversal or write-off requested, on the hub (hi)', 'निर्णय चाहिए'),
  ('vpps_staff_money_request_en_v1', 'vpps_staff_money_request_en_v1', 'en', 'staff_notice', 6, array['name', 'what', 'amount', 'student or class', 'asked by', 'link']::text[], 'none', false, 'Reversal or write-off requested, on the hub (en)', 'निर्णय चाहिए'),
  ('vpps_staff_money_decision_hi_v1', 'vpps_staff_money_decision_hi_v1', 'hi', 'staff_notice', 6, array['name', 'what', 'decision', 'amount', 'student or class', 'link']::text[], 'none', false, 'Reversal or write-off decided, on the hub (hi)', 'अनुरोध पर निर्णय'),
  ('vpps_staff_money_decision_en_v1', 'vpps_staff_money_decision_en_v1', 'en', 'staff_notice', 6, array['name', 'what', 'decision', 'amount', 'student or class', 'link']::text[], 'none', false, 'Reversal or write-off decided, on the hub (en)', 'अनुरोध पर निर्णय'),
  ('vpps_staff_leave_request_hi_v1', 'vpps_staff_leave_request_hi_v1', 'hi', 'staff_notice', 4, array['name', 'teacher', 'dates', 'link']::text[], 'none', false, 'Leave requested, on the hub (hi)', 'छुट्टी का अनुरोध'),
  ('vpps_staff_leave_request_en_v1', 'vpps_staff_leave_request_en_v1', 'en', 'staff_notice', 4, array['name', 'teacher', 'dates', 'link']::text[], 'none', false, 'Leave requested, on the hub (en)', 'छुट्टी का अनुरोध'),
  ('vpps_staff_leave_decided_hi_v1', 'vpps_staff_leave_decided_hi_v1', 'hi', 'staff_notice', 4, array['name', 'dates', 'decision', 'link']::text[], 'none', false, 'Leave decided, on the hub (hi)', 'छुट्टी पर निर्णय'),
  ('vpps_staff_leave_decided_en_v1', 'vpps_staff_leave_decided_en_v1', 'en', 'staff_notice', 4, array['name', 'dates', 'decision', 'link']::text[], 'none', false, 'Leave decided, on the hub (en)', 'छुट्टी पर निर्णय'),
  ('vpps_staff_system_check_hi_v1', 'vpps_staff_system_check_hi_v1', 'hi', 'staff_notice', 5, array['name', 'day', 'count', 'what', 'link']::text[], 'none', false, 'System check, on the hub (hi)', 'सिस्टम जाँच'),
  ('vpps_staff_system_check_en_v1', 'vpps_staff_system_check_en_v1', 'en', 'staff_notice', 5, array['name', 'day', 'count', 'what', 'link']::text[], 'none', false, 'System check, on the hub (en)', 'सिस्टम जाँच'),
  ('vpps_staff_digest_hi_v1', 'vpps_staff_digest_hi_v1', 'hi', 'staff_notice', 4, array['name', 'count', 'what', 'link']::text[], 'none', false, 'Several messages at once, on the hub (hi)', 'आपके लिए नए संदेश'),
  ('vpps_staff_digest_en_v1', 'vpps_staff_digest_en_v1', 'en', 'staff_notice', 4, array['name', 'count', 'what', 'link']::text[], 'none', false, 'Several messages at once, on the hub (en)', 'आपके लिए नए संदेश'),
  ('vpps_staff_task_hi_v1', 'vpps_staff_task_hi_v1', 'hi', 'teacher_task', 3, array['teacher', 'task', 'due']::text[], 'none', true, 'Teacher task, on the hub (hi)', 'नया कार्य'),
  ('vpps_staff_task_en_v1', 'vpps_staff_task_en_v1', 'en', 'teacher_task', 3, array['teacher', 'task', 'due']::text[], 'none', true, 'Teacher task, on the hub (en)', 'नया कार्य'),
  ('vpps_staff_task_reminder_hi_v1', 'vpps_staff_task_reminder_hi_v1', 'hi', 'teacher_task', 3, array['teacher', 'task', 'due']::text[], 'none', true, 'Task reminder, on the hub (hi)', 'कार्य की याद'),
  ('vpps_staff_task_reminder_en_v1', 'vpps_staff_task_reminder_en_v1', 'en', 'teacher_task', 3, array['teacher', 'task', 'due']::text[], 'none', true, 'Task reminder, on the hub (en)', 'कार्य की याद')

on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261112041158_parent_helper.sql
-- Veer Patta AI, the school's WhatsApp helper for parents, step 1 (D-574).
--
-- A parent writes to the school's number (+91 83022 07823). The school's hub
-- forwards the message to One, One asks the hub whether it may answer
-- (`POST /v1/typing`, the hub's claim), and answers from the family's own
-- records: fees, receipts, attendance, results, the class teacher, or a
-- hand-off into One's Messages inbox. Step 1 answers ONLY the owner's test
-- number, for the practice children named below; every other number is left
-- to the hub's own bot and the office.
--
-- What this adds, all in `vppsone`, nothing in `public`:
--
--  * `parent_helper_settings`: one row. The helper's name, kept in one place
--    ("Veer Patta AI", the owner's choice, 12 Nov 2026), and the practice
--    children the owner's number stands for. Seeded with two TEST-2026-27
--    children; `parent_helper_child()` answers for test-year children only,
--    whatever this list says.
--  * `parent_helper_turns`: one row per parent message the helper looked at.
--    Metadata only: what kind of message, what it was taken to ask, how it
--    was answered, by which model, at what cost, and the hand-off it made.
--    The unique message id is what stops a repeated forward from being
--    answered twice. No message text is kept here: the conversation itself
--    stays in the hub, which is the school's WhatsApp inbox.
--  * `parent_helper_chats`: per number, the little the helper must remember
--    between messages: the language the parent writes in, whether it is
--    waiting for a message to pass on ("type your message for the teacher"),
--    and when it last greeted them.
--  * `parent_helper_child(student)`: one child's facts in one read, for a
--    caller with no signed-in person (the webhook). Answers null for any
--    child who is not in a TEST/UAT/DEMO session: a real family's fees come
--    from the Fees app, never from this database's replica. Results only
--    for an exam whose results are released and whose class is locked.
--    Fees never include the late fee, which has its own line; a write-off
--    (`payment_mode = 'discount'`) is never shown as a receipt.
--  * `parent_helper_budget(number, month, day)`: the school's AI spend this
--    month (One's AI helper and Veer Patta AI together, against the one
--    budget in Settings -> AI in One) and this number's answered turns today.
--
-- Rollback:
--   drop function if exists vppsone.parent_helper_budget(text, timestamptz, timestamptz);
--   drop function if exists vppsone.parent_helper_child(uuid);
--   drop table if exists vppsone.parent_helper_turns;
--   drop table if exists vppsone.parent_helper_chats;
--   drop table if exists vppsone.parent_helper_settings;

begin;

set local lock_timeout = '5s';

create table vppsone.parent_helper_settings (
  id smallint primary key default 1 check (id = 1),
  helper_name text not null default 'Veer Patta AI' check (char_length(btrim(helper_name)) between 2 and 40),
  practice_student_ids uuid[] not null default '{}',
  updated_by uuid references vppsone.staff_profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table vppsone.parent_helper_settings is
  'Veer Patta AI (D-574): its name, and the practice children the owner''s test number stands for. One row.';

insert into vppsone.parent_helper_settings (id, helper_name, practice_student_ids)
select 1, 'Veer Patta AI', coalesce(array_agg(s.id order by s.admission_no), '{}')
from public.students s
join public.classes c on c.id = s.class_id
where s.admission_no in ('TEST-D-0003', 'TEST-CL2-196')
  and c.session_label ~* '^(TEST|UAT|DEMO)-'
on conflict (id) do nothing;

create table vppsone.parent_helper_chats (
  from_e164 text primary key check (from_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  language text check (language in ('hi', 'hx', 'en')),
  awaiting text check (awaiting is null or awaiting ~ '^(teacher:[a-z0-9]{4,16}|office)$'),
  awaiting_until timestamptz,
  greeted_at timestamptz,
  last_turn_at timestamptz,
  updated_at timestamptz not null default now()
);

comment on table vppsone.parent_helper_chats is
  'Veer Patta AI (D-574): per number, the language and what the helper is waiting for. Never the messages themselves.';

create table vppsone.parent_helper_turns (
  id uuid primary key default gen_random_uuid(),
  provider_message_id text not null unique,
  from_e164 text not null,
  received_at timestamptz not null,
  kind text not null check (kind in ('text', 'tap', 'voice', 'media')),
  status text not null default 'started' check (status in ('started', 'not_claimed', 'answered', 'failed')),
  reason text check (reason is null or char_length(reason) <= 120),
  intent text check (intent is null or intent ~ '^[a-z_]{2,30}$'),
  route text check (route is null or route in ('rule', 'tap', 'ai', 'ai_careful', 'fallback')),
  model text,
  cost_usd numeric(10, 6) not null default 0 check (cost_usd >= 0),
  handoff text check (handoff is null or handoff in ('class_teacher', 'accounts', 'office', 'principal')),
  parent_reply_id uuid references vppsone.parent_replies(id) on delete set null,
  reply_message_id text,
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.parent_helper_turns is
  'Veer Patta AI (D-574): one row per parent message looked at. Metadata only, never the text. The unique message id stops a repeated forward being answered twice.';

create index parent_helper_turns_from_created on vppsone.parent_helper_turns (from_e164, created_at desc);
create index parent_helper_turns_created on vppsone.parent_helper_turns (created_at);

alter table vppsone.parent_helper_settings enable row level security;
alter table vppsone.parent_helper_chats enable row level security;
alter table vppsone.parent_helper_turns enable row level security;

revoke all on vppsone.parent_helper_settings, vppsone.parent_helper_chats, vppsone.parent_helper_turns from anon, authenticated;
grant all on vppsone.parent_helper_settings, vppsone.parent_helper_chats, vppsone.parent_helper_turns to service_role;

create function vppsone.parent_helper_child(p_student_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with today as (
    select (now() at time zone 'Asia/Kolkata')::date as d
  ),
  kid as (
    select s.id, s.full_name, s.class_id, s.status::text as status,
           c.session_label, c.class_name, c.section, c.stream_name
    from public.students s
    join public.classes c on c.id = s.class_id
    where s.id = p_student_id
      -- Step 1: test-year children only. A real family's fees come from the
      -- Fees app through its own connection, never from this replica.
      and c.session_label ~* '^(TEST|UAT|DEMO)-'
  )
  select case when not exists (select 1 from kid) then null else jsonb_build_object(
    'today', (select d from today),
    'student', (
      select jsonb_build_object(
        'id', k.id, 'full_name', k.full_name, 'class_id', k.class_id, 'status', k.status,
        'session_label', k.session_label, 'class_name', k.class_name, 'section', k.section, 'stream_name', k.stream_name)
      from kid k
    ),
    -- Fees only in `pending`; the late fee is its own column, never added in.
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
          'installment_no', b.installment_no, 'due_date', b.due_date, 'pending', b.pending_amount,
          'late_pending', b.late_fee_pending, 'applied', b.applied_amount, 'carry_forward', b.is_carry_forward)
        order by b.due_date, b.installment_no)
      from public.v_workbook_installment_balances b
      join kid k on k.id = b.student_id and b.session_label = k.session_label
    ), '[]'::jsonb),
    -- The five latest receipts. A write-off is not a payment and is left out;
    -- a reversed receipt stays, marked.
    'receipts', coalesce((
      select jsonb_agg(q.r order by q.d desc, q.n desc)
      from (
        select jsonb_build_object(
            'number', r.receipt_number, 'date', r.payment_date, 'amount', r.total_amount,
            'mode', r.payment_mode::text,
            'reversed', r.total_amount > 0 and coalesce(t.reversed_amount, 0) >= r.total_amount) as r,
          r.payment_date as d, r.receipt_number as n
        from public.receipts r
        join kid k on k.id = r.student_id
        left join public.v_receipt_reversal_totals t on t.receipt_id = r.id
        where r.payment_mode::text <> 'discount'
        order by r.payment_date desc, r.receipt_number desc
        limit 5
      ) q
    ), '[]'::jsonb),
    'attendance', (
      select jsonb_build_object(
        'attendance_pct', a.attendance_pct, 'days_counted', a.days_counted,
        'absent_days', a.absent_days, 'late_days', a.late_days)
      from vppsone.v_student_attendance a
      join kid k on k.id = a.student_id and a.session_label = k.session_label
    ),
    -- The daily register's last 30 days, submitted registers only.
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('day', g.day, 'status', m.status::text) order by g.day desc)
      from vppsone.attendance_marks m
      join vppsone.attendance_registers g on g.id = m.register_id
      join kid k on k.id = m.student_id and g.session_label = k.session_label
      where g.status = 'submitted' and g.period is null and g.day >= (select d from today) - 30
    ), '[]'::jsonb),
    -- What the school has finished: results released, the child's class locked.
    'results', coalesce((
      select jsonb_agg(q.e order by q.s desc nulls last)
      from (
        select jsonb_build_object(
            'label', a.label_en, 'label_hi', a.label_hi, 'term', a.term,
            'subjects', coalesce((
              select jsonb_agg(jsonb_build_object(
                  'name', coalesce(sub.name_en, s2.subject_code), 'name_hi', sub.name_hi, 'max', s2.max_marks,
                  'value', mk.value, 'absent', coalesce(mk.absent, false), 'exempt', coalesce(mk.exempt, false))
                order by s2.sort_order, sub.sort_order)
              from vppsone.assessment_subjects s2
              left join vppsone.subjects sub on sub.id = s2.subject_id
              left join vppsone.marks mk on mk.assessment_subject_id = s2.id and mk.student_id = k.id
              where s2.assessment_id = a.id and s2.class_id = k.class_id
            ), '[]'::jsonb)) as e,
          a.starts_on as s
        from vppsone.assessments a
        join kid k on k.session_label = a.session_label
        join vppsone.exam_class_locks l on l.assessment_id = a.id and l.class_id = k.class_id
        join vppsone.exam_plans p on p.assessment_id = a.id
        where p.results_published_at is not null
           or (p.results_publish_at is not null and p.results_publish_at <= now())
        order by a.starts_on desc nulls last
        limit 3
      ) q
    ), '[]'::jsonb),
    'class_teacher', (
      select jsonb_build_object('staff_id', sp.id, 'name', sp.display_name, 'is_test', coalesce(sp.is_test_account, false))
      from vppsone.class_teachers ct
      join vppsone.staff_profiles sp on sp.id = ct.staff_profile_id
      join kid k on ct.class_id = k.class_id and ct.session_label = k.session_label
      where ct.role = 'class_teacher' and sp.is_active
        and (ct.effective_from is null or ct.effective_from <= (select d from today))
        and (ct.effective_to is null or ct.effective_to >= (select d from today))
      order by ct.effective_from desc nulls last
      limit 1
    ),
    -- The next 30 days of the child's own session calendar.
    'calendar', coalesce((
      select jsonb_agg(jsonb_build_object(
          'date', e.starts_on, 'until', e.ends_on, 'title', e.title, 'title_hi', e.title_hi, 'kind', e.kind)
        order by e.starts_on)
      from vppsone.calendar_events e
      join kid k on e.session_label = k.session_label
      where e.cancelled_at is null
        and coalesce(e.ends_on, e.starts_on) >= (select d from today)
        and e.starts_on <= (select d from today) + 30
        and (e.class_ids is null or cardinality(e.class_ids) = 0 or k.class_id = any(e.class_ids))
    ), '[]'::jsonb)
  ) end;
$$;

create function vppsone.parent_helper_budget(p_from text, p_month_start timestamptz, p_day_start timestamptz)
returns table (spent_usd numeric, helper_usd numeric, turns_today integer)
language sql
stable
set search_path = ''
as $$
  with helper as (
    select coalesce(sum(t.cost_usd), 0) as usd
    from vppsone.parent_helper_turns t
    where t.created_at >= p_month_start
  )
  select
    coalesce((select sum(l.cost_usd) from vppsone.assist_log l where l.created_at >= p_month_start), 0) + (select usd from helper),
    (select usd from helper),
    (select count(*)::integer from vppsone.parent_helper_turns t
       where t.from_e164 = p_from and t.created_at >= p_day_start and t.status = 'answered');
$$;

revoke all on function vppsone.parent_helper_child(uuid) from public, anon, authenticated;
revoke all on function vppsone.parent_helper_budget(text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function vppsone.parent_helper_child(uuid) to service_role;
grant execute on function vppsone.parent_helper_budget(text, timestamptz, timestamptz) to service_role;

commit;

-- ======================================================== migrations/20261112052103_parent_helper_handoffs.sql
-- Veer Patta AI, step 2: a hand-off reaches a person, and their answer
-- reaches the parent (D-578).
--
-- Step 1 (20261112041158) put a parent's message in One's Messages inbox
-- (`parent_replies`). Now the person it is for is told on WhatsApp, between
-- 6 am and 9 pm in India only: the child's class teacher, the accountant
-- with an admin for fees, an admin for the principal, the office for the
-- office. They answer by swiping right on that message and typing, and the
-- answer goes to the parent from the school's number. Unanswered after
-- 3 hours: one reminder. A complaint still unanswered a day later goes up to
-- an admin (the owner, 12 Nov 2026).
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `parent_helper_handoffs`: one row per hand-off the helper made (one per
--    `parent_replies` row): who it is for, how far it has gone, and what is
--    due next (`next_action`, `next_action_at`), which the job below reads.
--  * `parent_helper_alerts`: each WhatsApp message that told a person, with
--    its message id. A swiped reply quotes that id, which is how One knows a
--    reply is an answer, and to which parent it goes.
--  * `parent_helper_deliveries`: each answer's way to the parent. Inside the
--    parent's 24 hours it goes as it is; outside them a short approved note
--    says it is ready and the answer waits (`waiting`) until the parent
--    replies. The answer's words stay in `parent_reply_answers`, where every
--    answer from One's Messages already goes.
--  * `parent_helper_take_due(limit)`: the hand-offs whose next step is due,
--    each held for ten minutes so two runs never act on one twice.
--  * Four registry rows, `not_submitted`: the staff alert and the parent's
--    "your answer is ready" note, Hindi and English. The hourly template
--    check sends each to Meta once by itself; nothing is sent to anyone.
--  * pg_cron job `parent-helper`, every five minutes, and only when a step is
--    due, calling /api/jobs/parent-helper with the WhatsApp queue's secret.
--
-- Nothing here sends to a real person while practice mode is on or real
-- recipients are off: every message still passes `checkWhatsAppSend`.
--
-- Rollback:
--   select cron.unschedule('parent-helper');
--   delete from vppsone.whatsapp_templates where key in ('vpps_staff_parent_question_hi_v1',
--     'vpps_staff_parent_question_en_v1', 'vpps_parent_answer_ready_hi_v1', 'vpps_parent_answer_ready_en_v1')
--     and status = 'not_submitted';
--   drop function if exists vppsone.parent_helper_take_due(integer);
--   drop table if exists vppsone.parent_helper_deliveries;
--   drop table if exists vppsone.parent_helper_alerts;
--   drop table if exists vppsone.parent_helper_handoffs;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table vppsone.parent_helper_handoffs (
  id uuid primary key default gen_random_uuid(),
  parent_reply_id uuid not null unique references vppsone.parent_replies(id) on delete cascade,
  parent_e164 text not null check (parent_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  language text not null check (language in ('hi', 'hx', 'en')),
  target text not null check (target in ('class_teacher', 'accounts', 'office', 'principal')),
  topic text not null check (topic ~ '^[a-z_]{2,30}$'),
  complaint boolean not null default false,
  practice boolean not null default false,
  class_teacher_id uuid references vppsone.staff_profiles(id) on delete set null,
  -- The child's first name, or the parent's own name when no child was named.
  about_name text not null check (char_length(about_name) between 1 and 80),
  level smallint not null default 0 check (level between 0 and 1),
  reminders smallint not null default 0 check (reminders between 0 and 5),
  level_alerted_at timestamptz,
  next_action text check (next_action is null or next_action in ('alert', 'remind', 'pass_up')),
  next_action_at timestamptz,
  answered_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint parent_helper_handoffs_next_together check ((next_action is null) = (next_action_at is null))
);

comment on table vppsone.parent_helper_handoffs is
  'Veer Patta AI (D-578): one row per hand-off. Who it is for, how far it has gone, and the next step (alert, reminder, passing up to an admin) with when it is due.';

create index parent_helper_handoffs_due on vppsone.parent_helper_handoffs (next_action_at)
  where next_action_at is not null and answered_at is null and closed_at is null;
create index parent_helper_handoffs_parent on vppsone.parent_helper_handoffs (parent_e164, created_at desc);

create table vppsone.parent_helper_alerts (
  id uuid primary key default gen_random_uuid(),
  handoff_id uuid not null references vppsone.parent_helper_handoffs(id) on delete cascade,
  staff_id uuid references vppsone.staff_profiles(id) on delete set null,
  to_e164 text check (to_e164 is null or to_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  kind text not null check (kind in ('alert', 'reminder', 'passed_up')),
  via text check (via is null or via in ('text', 'template')),
  status text not null check (status in ('sent', 'failed', 'skipped')),
  reason text check (reason is null or char_length(reason) <= 120),
  message_id text unique,
  created_at timestamptz not null default now()
);

comment on table vppsone.parent_helper_alerts is
  'Veer Patta AI (D-578): each WhatsApp message that told a person about a hand-off. A swiped reply quotes message_id, which ties the answer to the parent.';

create index parent_helper_alerts_handoff on vppsone.parent_helper_alerts (handoff_id, created_at);

create table vppsone.parent_helper_deliveries (
  answer_id uuid primary key references vppsone.parent_reply_answers(id) on delete restrict,
  handoff_id uuid not null references vppsone.parent_helper_handoffs(id) on delete cascade,
  status text not null check (status in ('sent', 'waiting', 'failed')),
  via text check (via is null or via in ('text', 'template')),
  -- Who answered, as the parent reads it: the class teacher by name, else the office they speak for.
  answerer_kind text not null check (answerer_kind in ('class_teacher', 'accounts', 'principal', 'office')),
  answerer_name text check (answerer_name is null or char_length(answerer_name) <= 80),
  note_message_id text,
  message_id text,
  reason text check (reason is null or char_length(reason) <= 120),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now()
);

comment on table vppsone.parent_helper_deliveries is
  'Veer Patta AI (D-578): each answer''s way to the parent. sent, or waiting for the parent to reply to the approved "your answer is ready" note, or failed. The words stay in parent_reply_answers.';

create index parent_helper_deliveries_waiting on vppsone.parent_helper_deliveries (handoff_id) where status = 'waiting';

alter table vppsone.parent_helper_handoffs enable row level security;
alter table vppsone.parent_helper_alerts enable row level security;
alter table vppsone.parent_helper_deliveries enable row level security;

revoke all on vppsone.parent_helper_handoffs, vppsone.parent_helper_alerts, vppsone.parent_helper_deliveries from anon, authenticated;
grant all on vppsone.parent_helper_handoffs, vppsone.parent_helper_alerts, vppsone.parent_helper_deliveries to service_role;

create function vppsone.parent_helper_take_due(p_limit integer)
returns setof uuid
language sql
volatile
set search_path = ''
as $$
  update vppsone.parent_helper_handoffs h
     set next_action_at = now() + interval '10 minutes',
         updated_at = now()
   where h.id in (
     select d.id
       from vppsone.parent_helper_handoffs d
      where d.next_action_at is not null
        and d.next_action_at <= now()
        and d.answered_at is null
        and d.closed_at is null
      order by d.next_action_at
      limit greatest(1, least(coalesce(p_limit, 20), 50))
      for update skip locked
   )
  returning h.id;
$$;

comment on function vppsone.parent_helper_take_due(integer) is
  'Veer Patta AI (D-578): the hand-offs whose next step is due, each pushed ten minutes on so another run leaves it alone. The job sets the real next time once the step is done.';

revoke all on function vppsone.parent_helper_take_due(integer) from public, anon, authenticated;
grant execute on function vppsone.parent_helper_take_due(integer) to service_role;

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_staff_parent_question_hi_v1', 'vpps_staff_parent_question_hi_v1', 'hi', 'parent_helper', 4, array['name', 'student', 'about', 'message']::text[], 'none', false, 'A parent''s message for a teacher, on the hub (hi)', 'अभिभावक का संदेश'),
  ('vpps_staff_parent_question_en_v1', 'vpps_staff_parent_question_en_v1', 'en', 'parent_helper', 4, array['name', 'student', 'about', 'message']::text[], 'none', false, 'A parent''s message for a teacher, on the hub (en)', 'अभिभावक का संदेश'),
  ('vpps_parent_answer_ready_hi_v1', 'vpps_parent_answer_ready_hi_v1', 'hi', 'parent_helper', 2, array['who', 'child']::text[], 'none', false, 'Your answer is ready, on the hub (hi)', 'आपका जवाब तैयार है'),
  ('vpps_parent_answer_ready_en_v1', 'vpps_parent_answer_ready_en_v1', 'en', 'parent_helper', 2, array['who', 'child']::text[], 'none', false, 'Your answer is ready, on the hub (en)', 'आपका जवाब तैयार है')
on conflict (key) do nothing;

select cron.schedule(
  'parent-helper',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/parent-helper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (
    select 1 from vppsone.parent_helper_handoffs h
     where h.next_action_at is not null and h.next_action_at <= now()
       and h.answered_at is null and h.closed_at is null
  );
  $job$
);

commit;

-- ======================================================== migrations/20261112064013_whatsapp_staff_hub_reworded.sql
-- Thirteen staff copies reworded for Meta's review (D-581, 12 Nov 2026).
--
-- Of the 40 staff and teacher-task copies sent to Meta for approval on
-- 12 Nov (D-573), Meta re-filed 12 as marketing after approving them as
-- utility (about 7 times the price, and Meta holds some back from people
-- who get many) and turned one down as the wrong category (the Hindi
-- "online payment to check"). Meta never takes a name twice, so each is
-- reworded under the next name, _v2: no "open the app" lines, and each one
-- says whose work it is. The wording is in
-- src/modules/whatsapp/domain/staff-hub-templates.ts (`version`).
--
-- Rows only, all `not_submitted`: nothing is sent to anyone. The hourly
-- template check sends them to Meta by itself. The _v1 rows stay as history:
-- One no longer sends under those names, and the send policy refuses any
-- template Meta has filed as marketing (platform/whatsapp/policy.ts).
--
-- Rollback, only while none is approved and in use: remove the 13 rows whose
-- key ends in _v2 below.

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_staff_cover_cancelled_hi_v2', 'vpps_staff_cover_cancelled_hi_v2', 'hi', 'staff_notice', 6, array['name', 'day', 'period', 'classes', 'subject', 'link']::text[], 'none', false, 'Cover cancelled, on the hub (hi, reworded)', 'कवर ड्यूटी रद्द'),
  ('vpps_staff_weekly_summary_hi_v2', 'vpps_staff_weekly_summary_hi_v2', 'hi', 'staff_notice', 3, array['name', 'summary', 'from']::text[], 'none', false, 'Weekly academic summary, on the hub (hi, reworded)', 'साप्ताहिक शैक्षणिक रिपोर्ट'),
  ('vpps_staff_notice_hi_v2', 'vpps_staff_notice_hi_v2', 'hi', 'staff_notice', 1, array['text']::text[], 'none', false, 'Staff notice, on the hub (hi, reworded)', 'विद्यालय स्टाफ़ के लिए सूचना'),
  ('vpps_staff_notice_en_v2', 'vpps_staff_notice_en_v2', 'en', 'staff_notice', 1, array['text']::text[], 'none', false, 'Staff notice, on the hub (en, reworded)', 'विद्यालय स्टाफ़ के लिए सूचना'),
  ('vpps_staff_online_payment_check_hi_v2', 'vpps_staff_online_payment_check_hi_v2', 'hi', 'staff_notice', 4, array['name', 'amount', 'student or class', 'link']::text[], 'none', false, 'Online payment needs review, on the hub (hi, reworded)', 'ऑनलाइन भुगतान दर्ज करना है'),
  ('vpps_staff_money_request_hi_v2', 'vpps_staff_money_request_hi_v2', 'hi', 'staff_notice', 6, array['name', 'what', 'amount', 'student or class', 'asked by', 'link']::text[], 'none', false, 'Reversal or write-off requested, on the hub (hi, reworded)', 'फ़ीस रिकॉर्ड की मंज़ूरी'),
  ('vpps_staff_money_request_en_v2', 'vpps_staff_money_request_en_v2', 'en', 'staff_notice', 6, array['name', 'what', 'amount', 'student or class', 'asked by', 'link']::text[], 'none', false, 'Reversal or write-off requested, on the hub (en, reworded)', 'फ़ीस रिकॉर्ड की मंज़ूरी'),
  ('vpps_staff_money_decision_hi_v2', 'vpps_staff_money_decision_hi_v2', 'hi', 'staff_notice', 6, array['name', 'what', 'decision', 'amount', 'student or class', 'link']::text[], 'none', false, 'Reversal or write-off decided, on the hub (hi, reworded)', 'फ़ीस रिकॉर्ड पर निर्णय'),
  ('vpps_staff_system_check_hi_v2', 'vpps_staff_system_check_hi_v2', 'hi', 'staff_notice', 5, array['name', 'day', 'count', 'what', 'link']::text[], 'none', false, 'System check, on the hub (hi, reworded)', 'सिस्टम जाँच की चेतावनी'),
  ('vpps_staff_system_check_en_v2', 'vpps_staff_system_check_en_v2', 'en', 'staff_notice', 5, array['name', 'day', 'count', 'what', 'link']::text[], 'none', false, 'System check, on the hub (en, reworded)', 'सिस्टम जाँच की चेतावनी'),
  ('vpps_staff_digest_hi_v2', 'vpps_staff_digest_hi_v2', 'hi', 'staff_notice', 4, array['name', 'count', 'what', 'link']::text[], 'none', false, 'Several messages at once, on the hub (hi, reworded)', 'आपकी स्टाफ़ सूचनाएँ'),
  ('vpps_staff_digest_en_v2', 'vpps_staff_digest_en_v2', 'en', 'staff_notice', 4, array['name', 'count', 'what', 'link']::text[], 'none', false, 'Several messages at once, on the hub (en, reworded)', 'आपकी स्टाफ़ सूचनाएँ'),
  ('vpps_staff_task_hi_v2', 'vpps_staff_task_hi_v2', 'hi', 'teacher_task', 3, array['teacher', 'task', 'due']::text[], 'none', true, 'Teacher task, on the hub (hi, reworded)', 'नया कार्य सौंपा गया')

on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261112101311_staff_whatsapp_link.sql
-- Veer Patta AI: a member of staff links their own WhatsApp (D-582).
--
-- A hand-off (D-578) tells the child's class teacher, or the accountant, on
-- WhatsApp. That needs their WhatsApp number, and until now One had nobody's:
-- the office would have had to type every number into the staff record. Now
-- each person links their own, from My profile (teachers) or Preferences:
--
--  1. They tap "Link my WhatsApp". One makes a one-time code for them alone:
--     eight letters and digits, good for 30 minutes.
--  2. WhatsApp opens on their phone with a short message holding the code,
--     addressed to the school's number. They press Send.
--  3. The hub forwards the message to One, which finds the code and writes
--     down the number it came from as their WhatsApp number, with their
--     consent: sending the code from that phone is the yes.
--
-- The number is never typed, so it cannot be mistyped, and it is theirs:
-- only the person holding that phone could have sent the code from it. A test
-- account takes only a number on the test list (`message_test_recipients`),
-- the rule every staff message already keeps: a test account's number is a
-- test number or nothing.
--
-- The yes is the person's own, so it is recorded as `whatsapp_opt_in_source`
-- 'self', as on Preferences. How it was given stays here: the used code keeps
-- the number it came from, and One's screens read "linked from your phone"
-- when the number on file is that number. No existing table or rule changes.
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `staff_whatsapp_links`: the codes. Each is used once; an unused one runs
--    out after 30 minutes. One clears a person's other open codes when they
--    make a new one, and again once one is used.
--  * `link_staff_whatsapp(code, from)`: the one place a code becomes a link,
--    in one transaction.
--
-- Nothing here sends anything. Whether One answers the message on WhatsApp is
-- the helper's own switch and practice mode, as for every other message.
--
-- Rollback:
--   drop function if exists vppsone.link_staff_whatsapp(text, text);
--   drop table if exists vppsone.staff_whatsapp_links;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

comment on column vppsone.staff_profiles.whatsapp_opt_in_source is
  'How the consent was given: form (paper, at training), self (the person themselves: on /preferences, or by sending their Link my WhatsApp code from that phone, D-582, kept in staff_whatsapp_links) or admin_recorded (/staff, the admin records consent collected in person).';

create table vppsone.staff_whatsapp_links (
  code text primary key check (code ~ '^[A-HJKMNP-Z2-9]{8}$'),
  staff_profile_id uuid not null references vppsone.staff_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes',
  used_at timestamptz,
  used_from text check (used_from is null or used_from ~ '^\+91[6-9][0-9]{9}$'),
  check ((used_at is null) = (used_from is null)),
  check (expires_at > created_at)
);

comment on table vppsone.staff_whatsapp_links is
  'Link my WhatsApp (D-582): one-time codes a member of staff sends from their phone to the school''s number, so One learns their WhatsApp number from WhatsApp itself. A used row keeps which number it linked and when.';

create index staff_whatsapp_links_staff on vppsone.staff_whatsapp_links (staff_profile_id, created_at desc);

alter table vppsone.staff_whatsapp_links enable row level security;

revoke all on vppsone.staff_whatsapp_links from public, anon, authenticated;
grant select, insert, update, delete on vppsone.staff_whatsapp_links to service_role;

create function vppsone.link_staff_whatsapp(p_code text, p_from text)
returns table (outcome text, staff_profile_id uuid, display_name text, preferred_language text, is_test_account boolean)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_link vppsone.staff_whatsapp_links%rowtype;
  v_staff record;
begin
  if p_from is null or p_from !~ '^\+91[6-9][0-9]{9}$' then
    return query select 'bad_number'::text, null::uuid, null::text, null::text, null::boolean;
    return;
  end if;
  if v_code !~ '^[A-HJKMNP-Z2-9]{8}$' then
    return query select 'no_code'::text, null::uuid, null::text, null::text, null::boolean;
    return;
  end if;

  select l.* into v_link from vppsone.staff_whatsapp_links l where l.code = v_code for update;
  if not found then
    return query select 'no_code'::text, null::uuid, null::text, null::text, null::boolean;
    return;
  end if;

  select s.id, s.display_name, s.preferred_language, coalesce(s.is_test_account, false) as is_test_account, s.is_active
    into v_staff
    from vppsone.staff_profiles s
   where s.id = v_link.staff_profile_id
     for update;

  if v_link.used_at is not null then
    -- The same message forwarded twice, or sent twice: it is linked already.
    if v_link.used_from = p_from then
      return query select 'already_linked'::text, v_staff.id, v_staff.display_name, v_staff.preferred_language, v_staff.is_test_account;
    else
      return query select 'used'::text, null::uuid, null::text, null::text, null::boolean;
    end if;
    return;
  end if;

  if v_link.expires_at <= now() then
    return query select 'expired'::text, v_staff.id, null::text, v_staff.preferred_language, null::boolean;
    return;
  end if;

  if not coalesce(v_staff.is_active, false) then
    return query select 'inactive'::text, null::uuid, null::text, null::text, null::boolean;
    return;
  end if;

  if v_staff.is_test_account
     and not exists (select 1 from vppsone.message_test_recipients r where r.phone_e164 = p_from) then
    return query select 'not_test_number'::text, v_staff.id, null::text, v_staff.preferred_language, true;
    return;
  end if;

  -- Their own yes, given from that phone: 'self', as on Preferences.
  update vppsone.staff_profiles s
     set whatsapp_phone = right(p_from, 10),
         whatsapp_opt_in_at = now(),
         whatsapp_opt_in_source = 'self',
         whatsapp_opt_in_recorded_by = v_staff.id,
         whatsapp_opt_out_at = null
   where s.id = v_staff.id;

  update vppsone.staff_whatsapp_links l
     set used_at = now(), used_from = p_from
   where l.code = v_code;

  return query select 'linked'::text, v_staff.id, v_staff.display_name, v_staff.preferred_language, v_staff.is_test_account;
end;
$$;

comment on function vppsone.link_staff_whatsapp(text, text) is
  'Link my WhatsApp (D-582): the code a member of staff sent from their phone, and the number it came from. linked: the number is now their WhatsApp number, with their own yes (source self). Otherwise one of bad_number, no_code, used, already_linked, expired, inactive, not_test_number, and nothing changed.';

revoke all on function vppsone.link_staff_whatsapp(text, text) from public, anon, authenticated;
grant execute on function vppsone.link_staff_whatsapp(text, text) to service_role;

commit;

-- ======================================================== migrations/20261112110044_parent_helper_ratings.sql
-- Veer Patta AI, step 2b: "Did this answer help?" (D-584).
--
-- After a teacher's or the office's answer reaches a parent (D-578), the
-- helper asks once, on two buttons: "Yes, it helped" and "No". A "no" goes
-- to the school office with what the parent asked and the answer that did
-- not help, as a new message in One's Messages and a new hand-off for the
-- office. It is handled as a complaint: a reminder after 3 hours, and an
-- admin is told when it is still unanswered a day later. The office's answer
-- to it is never rated again, so a "no" cannot go round in circles.
--
-- What this adds, to `vppsone.parent_helper_handoffs` only (service role
-- only, as the table already is). Every column is new and empty, so the
-- code that runs today does not notice it:
--
--  * `rating_asked_at`: when the parent was asked. Set by the one run that
--    sends the question, so it is asked once per hand-off.
--  * `rating`, `rated_at`: the parent's tap, `helped` or `not_helped`. A "no"
--    may replace a "yes" (a wrong tap put right); a "yes" never replaces a
--    "no", because the office already has it.
--  * `follow_up_of`: on the office's hand-off for a "no", the hand-off whose
--    answer did not help. At most one each (a unique index), so a second
--    tap never tells the office twice.
--
-- Nothing is stored that is not already in One: the parent's words stay in
-- `parent_replies` and the answers in `parent_reply_answers`, as before.
--
-- Rollback (by hand, never needed by the code that runs today):
--   alter table vppsone.parent_helper_handoffs
--     drop constraint if exists parent_helper_handoffs_rating_known,
--     drop constraint if exists parent_helper_handoffs_rating_together,
--     drop constraint if exists parent_helper_handoffs_follow_up_not_self,
--     drop constraint if exists parent_helper_handoffs_follow_up_not_rated,
--     drop column if exists follow_up_of,
--     drop column if exists rated_at,
--     drop column if exists rating,
--     drop column if exists rating_asked_at;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.parent_helper_handoffs
  add column rating_asked_at timestamptz,
  add column rating text,
  add column rated_at timestamptz,
  add column follow_up_of uuid references vppsone.parent_helper_handoffs(id) on delete set null,
  add constraint parent_helper_handoffs_rating_known check (rating is null or rating in ('helped', 'not_helped')),
  add constraint parent_helper_handoffs_rating_together check ((rating is null) = (rated_at is null)),
  add constraint parent_helper_handoffs_follow_up_not_self check (follow_up_of is null or follow_up_of <> id),
  add constraint parent_helper_handoffs_follow_up_not_rated check (follow_up_of is null or (rating is null and rating_asked_at is null));

comment on column vppsone.parent_helper_handoffs.rating_asked_at is
  'Veer Patta AI (D-584): when the parent was asked "Did this answer help?". Asked once per hand-off, never on the office''s hand-off for a "no".';
comment on column vppsone.parent_helper_handoffs.rating is
  'Veer Patta AI (D-584): the parent''s tap on "Did this answer help?": helped or not_helped. A "no" may replace a "yes"; a "yes" never replaces a "no".';
comment on column vppsone.parent_helper_handoffs.rated_at is
  'Veer Patta AI (D-584): when the rating was kept.';
comment on column vppsone.parent_helper_handoffs.follow_up_of is
  'Veer Patta AI (D-584): on the school office''s hand-off for a "no", the hand-off whose answer did not help. At most one each.';

create unique index parent_helper_handoffs_one_follow_up on vppsone.parent_helper_handoffs (follow_up_of)
  where follow_up_of is not null;

commit;

-- ======================================================== migrations/20261112111705_staff_sign_in_codes.sql
-- Sign in with a WhatsApp code (D-584).
--
-- The sign-in page asks for a mobile number. If that number is on exactly one
-- active member of staff's record (their WhatsApp number, or their phone when
-- no WhatsApp number is on file), One sends a six-digit code to it on
-- WhatsApp from the school's number, through the school's hub, and the
-- person types it back. Email and password stay as the other way in.
--
-- What makes it safe:
--
--  * The page answers the same whichever number is typed: "if this number is
--    on a staff record, a code is on its way". Nobody learns from it whose
--    number is on file. A number on no record, a number on two records, and a
--    number the current setting does not allow all get a row here with no
--    code, so even the limits below count them the same.
--  * A code is good for 10 minutes, once, and five wrong tries end it. Only
--    the newest code for a number works.
--  * At most 3 codes per number in 15 minutes and 10 a day, 30 seconds apart;
--    at most 8 asks from one browser address in 15 minutes and 30 a day; and
--    120 codes an hour for the whole school, so a fault cannot run up Meta's
--    bill (about 14 paise a code).
--  * The code itself is never stored: the app keeps a SHA-256 of the row's
--    id and the code, and compares that. The hub keeps "[Sign-in code sent.
--    The code is hidden.]" in its chats (hub PR 4).
--  * Test accounts are not reachable this way. They keep the QA sign-in page.
--  * `staff_sign_in_settings.mode` decides who can get a code: off, the
--    owner's test number only (`whatsapp_owner_test_number`, the starting
--    point), or every member of staff. An admin changes it in Settings ->
--    WhatsApp. The hub's own AUTH_SEND_MODE is a second, separate gate.
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `staff_sign_in_settings`: one row, the mode.
--  * `staff_sign_in_codes`: every ask, whether a code went or not. Kept 30
--    days (the app clears older rows after each ask), so an admin can see
--    who signed in this way.
--  * `request_staff_sign_in_code(...)`: the one place an ask is decided, in
--    one transaction, under a lock on the number.
--  * `verify_staff_sign_in_code(...)`: the one place a code is checked. It
--    checks the person again (still active, still that number) before it
--    says yes.
--
-- Nothing here sends anything and no existing table or rule changes. It is
-- additive only: undoing it means removing the two functions, then the two
-- tables, that it creates.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table vppsone.staff_sign_in_settings (
  id boolean primary key default true check (id),
  mode text not null default 'owner_only' check (mode in ('off', 'owner_only', 'all_staff')),
  updated_at timestamptz not null default now(),
  updated_by uuid references vppsone.staff_profiles(id) on delete set null
);

comment on table vppsone.staff_sign_in_settings is
  'Sign in with a WhatsApp code (D-584): who can get a code. off; owner_only (the WhatsApp owner test number only); all_staff (any active, non-test member of staff whose number is on exactly one record).';

insert into vppsone.staff_sign_in_settings (id, mode) values (true, 'owner_only') on conflict (id) do nothing;

alter table vppsone.staff_sign_in_settings enable row level security;
revoke all on vppsone.staff_sign_in_settings from public, anon, authenticated;
grant select, update on vppsone.staff_sign_in_settings to service_role;

create table vppsone.staff_sign_in_codes (
  id uuid primary key,
  phone_key text not null check (phone_key ~ '^[6-9][0-9]{9}$'),
  client_key text not null check (client_key ~ '^[0-9a-f]{16,64}$'),
  outcome text not null check (outcome in ('send', 'no_match', 'shared_number', 'not_allowed')),
  staff_profile_id uuid references vppsone.staff_profiles(id) on delete cascade,
  code_hash text check (code_hash is null or code_hash ~ '^[0-9a-f]{64}$'),
  language text not null default 'hi' check (language in ('hi', 'en')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  attempts smallint not null default 0 check (attempts between 0 and 5),
  used_at timestamptz,
  send_status text not null default 'none' check (send_status in ('none', 'pending', 'accepted', 'refused', 'unknown')),
  send_error text check (send_error is null or char_length(send_error) <= 300),
  provider_message_id text check (provider_message_id is null or char_length(provider_message_id) <= 200),
  check ((outcome = 'send') = (code_hash is not null)),
  check (outcome <> 'send' or staff_profile_id is not null),
  check (used_at is null or outcome = 'send'),
  check (expires_at > created_at)
);

comment on table vppsone.staff_sign_in_codes is
  'Sign in with a WhatsApp code (D-584): every ask. A row with outcome send carries a SHA-256 of its id and the code, never the code. The app clears rows older than 30 days.';

create index staff_sign_in_codes_phone on vppsone.staff_sign_in_codes (phone_key, created_at desc);
create index staff_sign_in_codes_client on vppsone.staff_sign_in_codes (client_key, created_at desc);
create index staff_sign_in_codes_created on vppsone.staff_sign_in_codes (created_at);

alter table vppsone.staff_sign_in_codes enable row level security;
revoke all on vppsone.staff_sign_in_codes from public, anon, authenticated;
grant select, insert, update, delete on vppsone.staff_sign_in_codes to service_role;

create function vppsone.request_staff_sign_in_code(
  p_id uuid,
  p_phone text,
  p_client_key text,
  p_code_hash text,
  p_language text
)
returns table (outcome text, staff_profile_id uuid, phone_key text, retry_after_seconds integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_key text;
  v_client text := lower(coalesce(p_client_key, ''));
  v_language text := case when p_language = 'en' then 'en' else 'hi' end;
  v_now timestamptz := clock_timestamp();
  v_mode text;
  v_owner text;
  v_matches uuid[];
  v_outcome text;
  v_staff uuid;
  v_count integer;
  v_oldest timestamptz;
  v_latest timestamptz;
begin
  -- An Indian mobile, typed as 10 digits, with a 0, or with 91 in front. Nothing else.
  if v_digits ~ '^(0|91)?[6-9][0-9]{9}$' then
    v_key := right(v_digits, 10);
  end if;
  if p_id is null or v_key is null then
    return query select 'bad_number'::text, null::uuid, null::text, null::integer;
    return;
  end if;
  if v_client !~ '^[0-9a-f]{16,64}$' or coalesce(p_code_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'request_staff_sign_in_code: malformed client key or code hash' using errcode = '22023';
  end if;

  select s.mode into v_mode from vppsone.staff_sign_in_settings s where s.id;
  if coalesce(v_mode, 'off') = 'off' then
    return query select 'off'::text, null::uuid, null::text, null::integer;
    return;
  end if;

  -- One ask at a time per number, so two taps cannot both slip under a limit.
  perform pg_advisory_xact_lock(hashtextextended('staff_sign_in:' || v_key, 0));

  -- 30 seconds between codes to one number.
  select max(c.created_at) into v_latest from vppsone.staff_sign_in_codes c where c.phone_key = v_key;
  if v_latest is not null and v_latest > v_now - interval '30 seconds' then
    return query select 'limited'::text, null::uuid, null::text,
      greatest(1, ceil(extract(epoch from (v_latest + interval '30 seconds' - v_now)))::integer);
    return;
  end if;

  -- 3 per number in 15 minutes, 10 a day.
  select count(*), min(c.created_at) into v_count, v_oldest
    from vppsone.staff_sign_in_codes c where c.phone_key = v_key and c.created_at > v_now - interval '15 minutes';
  if v_count >= 3 then
    return query select 'limited'::text, null::uuid, null::text,
      greatest(1, ceil(extract(epoch from (v_oldest + interval '15 minutes' - v_now)))::integer);
    return;
  end if;
  select count(*), min(c.created_at) into v_count, v_oldest
    from vppsone.staff_sign_in_codes c where c.phone_key = v_key and c.created_at > v_now - interval '24 hours';
  if v_count >= 10 then
    return query select 'limited'::text, null::uuid, null::text,
      greatest(1, ceil(extract(epoch from (v_oldest + interval '24 hours' - v_now)))::integer);
    return;
  end if;

  -- 8 asks from one address in 15 minutes, 30 a day, whatever numbers they were.
  select count(*), min(c.created_at) into v_count, v_oldest
    from vppsone.staff_sign_in_codes c where c.client_key = v_client and c.created_at > v_now - interval '15 minutes';
  if v_count >= 8 then
    return query select 'limited'::text, null::uuid, null::text,
      greatest(1, ceil(extract(epoch from (v_oldest + interval '15 minutes' - v_now)))::integer);
    return;
  end if;
  select count(*), min(c.created_at) into v_count, v_oldest
    from vppsone.staff_sign_in_codes c where c.client_key = v_client and c.created_at > v_now - interval '24 hours';
  if v_count >= 30 then
    return query select 'limited'::text, null::uuid, null::text,
      greatest(1, ceil(extract(epoch from (v_oldest + interval '24 hours' - v_now)))::integer);
    return;
  end if;

  -- 120 codes an hour for the whole school.
  select count(*) into v_count
    from vppsone.staff_sign_in_codes c where c.outcome = 'send' and c.created_at > v_now - interval '1 hour';
  if v_count >= 120 then
    return query select 'busy'::text, null::uuid, null::text, 600;
    return;
  end if;

  select array_agg(sp.id order by sp.id) into v_matches
    from vppsone.staff_profiles sp
   where sp.is_active
     and not sp.is_test_account
     and sp.user_id is not null
     and private.whatsapp_phone_key(coalesce(sp.whatsapp_phone, sp.phone)) = v_key;

  if coalesce(cardinality(v_matches), 0) = 0 then
    v_outcome := 'no_match';
  elsif cardinality(v_matches) > 1 then
    v_outcome := 'shared_number';
  else
    v_staff := v_matches[1];
    if v_mode = 'owner_only' then
      select private.whatsapp_phone_key(f.value #>> '{}') into v_owner
        from vppsone.runtime_flags f where f.key = 'whatsapp_owner_test_number' and f.enabled;
      v_outcome := case when v_owner is not null and v_owner = v_key then 'send' else 'not_allowed' end;
    else
      v_outcome := 'send';
    end if;
  end if;

  if v_outcome = 'send' then
    -- Only the newest code for a number works.
    update vppsone.staff_sign_in_codes c
       set attempts = 5
     where c.phone_key = v_key and c.outcome = 'send' and c.used_at is null and c.expires_at > v_now;
  end if;

  insert into vppsone.staff_sign_in_codes (id, phone_key, client_key, outcome, staff_profile_id, code_hash, language, created_at, expires_at, send_status)
  values (
    p_id, v_key, v_client, v_outcome,
    case when v_outcome in ('send', 'not_allowed') then v_staff end,
    case when v_outcome = 'send' then lower(p_code_hash) end,
    v_language, v_now, v_now + interval '10 minutes',
    case when v_outcome = 'send' then 'pending' else 'none' end
  );


  return query select v_outcome,
    case when v_outcome = 'send' then v_staff end,
    case when v_outcome = 'send' then v_key end,
    null::integer;
end;
$$;

comment on function vppsone.request_staff_sign_in_code(uuid, text, text, text, text) is
  'Sign in with a WhatsApp code (D-584): decide one ask. Outcomes: bad_number, off, limited, busy (nothing written); no_match, shared_number, not_allowed (a row, no code); send (a row with the code''s hash; the caller sends the code). The caller shows every row-writing outcome the same way.';

create function vppsone.verify_staff_sign_in_code(p_id uuid, p_code_hash text)
returns table (outcome text, staff_profile_id uuid, user_id uuid, tries_left integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_row vppsone.staff_sign_in_codes%rowtype;
  v_now timestamptz := clock_timestamp();
  v_attempts integer;
  v_user uuid;
  v_mode text;
  v_owner text;
begin
  if p_id is null then
    return query select 'no_code'::text, null::uuid, null::uuid, 0;
    return;
  end if;

  select * into v_row from vppsone.staff_sign_in_codes c where c.id = p_id for update;
  if not found then
    return query select 'no_code'::text, null::uuid, null::uuid, 0;
    return;
  end if;
  if v_row.used_at is not null then
    return query select 'used'::text, null::uuid, null::uuid, 0;
    return;
  end if;
  if v_row.attempts >= 5 then
    return query select 'locked'::text, null::uuid, null::uuid, 0;
    return;
  end if;
  if v_row.expires_at <= v_now then
    return query select 'expired'::text, null::uuid, null::uuid, 0;
    return;
  end if;

  update vppsone.staff_sign_in_codes c set attempts = c.attempts + 1 where c.id = p_id returning c.attempts into v_attempts;

  -- A row that never had a code answers exactly like a wrong code.
  if v_row.outcome <> 'send' or v_row.code_hash is distinct from lower(coalesce(p_code_hash, '')) then
    return query select case when v_attempts >= 5 then 'locked' else 'wrong' end::text, null::uuid, null::uuid, 5 - v_attempts;
    return;
  end if;

  -- The person again, as they are now: still active, still staff, still that number.
  select sp.user_id into v_user
    from vppsone.staff_profiles sp
   where sp.id = v_row.staff_profile_id
     and sp.is_active
     and not sp.is_test_account
     and sp.user_id is not null
     and private.whatsapp_phone_key(coalesce(sp.whatsapp_phone, sp.phone)) = v_row.phone_key;

  select s.mode into v_mode from vppsone.staff_sign_in_settings s where s.id;
  if v_mode = 'owner_only' then
    select private.whatsapp_phone_key(f.value #>> '{}') into v_owner
      from vppsone.runtime_flags f where f.key = 'whatsapp_owner_test_number' and f.enabled;
  end if;

  update vppsone.staff_sign_in_codes c set used_at = v_now where c.id = p_id;

  if v_user is null then
    return query select 'not_staff'::text, null::uuid, null::uuid, 0;
    return;
  end if;
  if coalesce(v_mode, 'off') = 'off' or (v_mode = 'owner_only' and v_owner is distinct from v_row.phone_key) then
    return query select 'off'::text, null::uuid, null::uuid, 0;
    return;
  end if;

  return query select 'ok'::text, v_row.staff_profile_id, v_user, null::integer;
end;
$$;

comment on function vppsone.verify_staff_sign_in_code(uuid, text) is
  'Sign in with a WhatsApp code (D-584): check one code, once. Outcomes: ok (with the staff profile and auth user), wrong (tries_left), locked, expired, used, no_code, not_staff, off.';

revoke all on function vppsone.request_staff_sign_in_code(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function vppsone.verify_staff_sign_in_code(uuid, text) from public, anon, authenticated;
grant execute on function vppsone.request_staff_sign_in_code(uuid, text, text, text, text) to service_role;
grant execute on function vppsone.verify_staff_sign_in_code(uuid, text) to service_role;

commit;

-- ======================================================== migrations/20261112112417_whatsapp_sign_in_templates.sql
-- The two sign-in code templates on the school's hub (D-587, 12 Nov 2026).
--
-- Meta's AUTHENTICATION kind: Meta writes the words (the code, "for your
-- security, do not share this code", "this code expires in 10 minutes") and
-- the Copy code button. One fills one blank, the code, in the body and the
-- button (src/modules/whatsapp/data/sign-in-codes.ts). The submission is
-- SIGN_IN_HUB_SUBMISSIONS in src/modules/whatsapp/domain/hub-templates.ts.
--
-- Added only now because the hub that understands an AUTHENTICATION
-- submission is deployed (build 2026-11-12.sign-in-codes-2): a row in place
-- earlier would have been sent to the old hub by the hourly job, refused, and
-- left for an admin to send again.
--
-- Rows only, `not_submitted`: nothing is sent to anyone. The hourly template
-- check sends them to Meta by itself. `url_button` is false: Meta lists the
-- Copy code button as a URL button, but One never adds a link to it.
--
-- Rollback, only while neither is approved and in use: remove the two rows.

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, category, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_sign_in_code_hi_v1', 'vpps_sign_in_code_hi_v1', 'hi', 'staff_login', 'authentication', 1, array['code']::text[], 'none', false, 'Sign-in code for staff, on the hub (hi)', 'साइन-इन कोड'),
  ('vpps_sign_in_code_en_v1', 'vpps_sign_in_code_en_v1', 'en', 'staff_login', 'authentication', 1, array['code']::text[], 'none', false, 'Sign-in code for staff, on the hub (en)', 'साइन-इन कोड')
on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261112113517_parent_absence_notes.sql
-- Veer Patta AI, step 2b: a parent's sick-day note shows on the register
-- (D-588).
--
-- A parent writes to the school's number that a child will not come ("Riya
-- bimar hai, aaj nahi aayegi"). The helper already hands that message to the
-- class teacher (step 2, D-578). Now it also keeps one row per day the parent
-- named, so the class's register for that day says "Parent informed" beside
-- the child, the child starts as Absent there (the teacher can still change
-- it), and no "your child is absent" WhatsApp is queued for that parent.
--
-- What this adds, in `vppsone`, service role only:
--
--  * `parent_absence_notes`: one row per child per day. The reason is a word
--    (`sick` or `other`), never the parent's own words: those stay in the
--    hand-off (`parent_replies`), as every hand-off's do. The first note for a
--    day stands; a second message about the same day adds nothing.
--
-- The register and the absent-alert queue read it with the service role, for
-- the classes the reader may already open; nobody signed in reads it directly.
--
-- Rollback:
--   drop table if exists vppsone.parent_absence_notes;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table vppsone.parent_absence_notes (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null,
  session_label text not null check (char_length(session_label) between 4 and 40),
  day date not null,
  reason text not null,
  -- The hand-off the note came with, in One's Messages inbox.
  parent_reply_id uuid references vppsone.parent_replies(id) on delete set null,
  -- Written for the owner's test number standing in for a family.
  practice boolean not null default false,
  created_at timestamptz not null default now(),
  constraint parent_absence_notes_reason_known check (reason in ('sick', 'other')),
  constraint parent_absence_notes_one_per_day unique (student_id, day)
);

comment on table vppsone.parent_absence_notes is
  'Veer Patta AI (D-588): a parent told the school on WhatsApp that a child will be away. One row per child per day, for the register to show "Parent informed" and for no absent alert to be queued. The parent''s words stay in the hand-off (parent_replies).';
comment on column vppsone.parent_absence_notes.reason is
  'sick, or other (a family matter, travel): a word, never the parent''s message.';
comment on column vppsone.parent_absence_notes.parent_reply_id is
  'The hand-off this note came with, in One''s Messages inbox; null once that message is removed.';

create index parent_absence_notes_day on vppsone.parent_absence_notes (day, session_label);

alter table vppsone.parent_absence_notes enable row level security;
revoke all on vppsone.parent_absence_notes from anon, authenticated;
grant all on vppsone.parent_absence_notes to service_role;

commit;

-- ======================================================== migrations/20261112125144_parent_helper_lessons.sql
-- Veer Patta AI, step 3: "teach it once" and the weekly report (D-589, D-590).
--
-- When the helper cannot answer a general question about the school (winter
-- timings, the Saturday uniform, a bus route), it passes the parent to the
-- office as before, and now also puts the question on a list in One, written
-- by Claude as one short general line with no names and nothing about the
-- family. An admin writes the school's answer once; from the next message on,
-- the helper answers that question itself, in the parent's language. Or the
-- admin says a person always answers it, and it stops coming back to the list.
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `parent_helper_lessons`: one row per question. `practice` keeps the
--    practice family's questions (the owner's number standing for the TEST
--    children) apart from real families': an answer taught for one is used
--    for that kind of chat only. `fingerprint` is the question folded to
--    lower case and plain words by the app, so the same question asked again
--    finds the row it is already on instead of making a new one.
--  * `parent_helper_note_lesson(...)`: the helper's one write per answer.
--    'used' counts an answer the helper gave from a school answer; 'asked'
--    counts a question again (by the row the helper named, else by its
--    fingerprint) or lists it for the first time. Atomic, one round trip.
--  * Three columns on `parent_helper_turns`, for the weekly report:
--    `practice` (every turn so far is the practice family's, so existing rows
--    read true), and `lesson_id` / `lesson_role`, the lesson a turn used or
--    added to.
--
-- Nothing here stores a parent's words: a lesson's question is Claude's
-- general wording, which the app refuses when it names any child, parent or
-- teacher of the family that wrote, or carries a long number, an address or
-- a link. Nothing here sends a message.
--
-- Rollback (by hand; the code that runs today does not read any of it):
--   drop function if exists vppsone.parent_helper_note_lesson(boolean, text, uuid, text, text, text);
--   alter table vppsone.parent_helper_turns
--     drop constraint if exists parent_helper_turns_lesson_role_known,
--     drop column if exists lesson_role,
--     drop column if exists lesson_id,
--     drop column if exists practice;
--   drop table if exists vppsone.parent_helper_lessons;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table vppsone.parent_helper_lessons (
  id uuid primary key default gen_random_uuid(),
  practice boolean not null,
  question text not null
    constraint parent_helper_lessons_question_size check (char_length(btrim(question)) between 6 and 160),
  fingerprint text not null
    constraint parent_helper_lessons_fingerprint_size check (char_length(fingerprint) between 3 and 160),
  answer text
    constraint parent_helper_lessons_answer_size check (answer is null or char_length(btrim(answer)) between 2 and 600),
  status text not null default 'waiting'
    constraint parent_helper_lessons_status_known check (status in ('waiting', 'answered', 'by_people')),
  topic text
    constraint parent_helper_lessons_topic_shape check (topic is null or topic ~ '^[a-z_]{2,30}$'),
  asked_count integer not null default 1
    constraint parent_helper_lessons_asked_count_range check (asked_count between 0 and 1000000),
  first_asked_at timestamptz not null default now(),
  last_asked_at timestamptz not null default now(),
  used_count integer not null default 0
    constraint parent_helper_lessons_used_count_range check (used_count between 0 and 1000000),
  last_used_at timestamptz,
  answered_by uuid constraint parent_helper_lessons_answered_by_fkey references vppsone.staff_profiles(id) on delete set null,
  answered_at timestamptz,
  closed_by uuid constraint parent_helper_lessons_closed_by_fkey references vppsone.staff_profiles(id) on delete set null,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint parent_helper_lessons_answered_has_answer check (status <> 'answered' or answer is not null)
);

comment on table vppsone.parent_helper_lessons is
  'Veer Patta AI (D-589): questions the helper could not answer, in Claude''s general wording with no names, and the school''s answer once an admin writes it. practice keeps the practice family''s apart from real families''.';
comment on column vppsone.parent_helper_lessons.fingerprint is
  'The question folded to lower case and plain words by the app: the same question asked again finds this row.';
comment on column vppsone.parent_helper_lessons.status is
  'waiting: on the list for an admin. answered: the helper answers it from answer. by_people: a person always answers it; the helper hands it off and does not list it again.';

-- One open row per question and kind. An answered question may be asked
-- again in a way its answer does not cover, which lists it afresh.
create unique index parent_helper_lessons_open_question
  on vppsone.parent_helper_lessons (practice, fingerprint)
  where status in ('waiting', 'by_people');
create index parent_helper_lessons_kind
  on vppsone.parent_helper_lessons (practice, status, last_asked_at desc);

alter table vppsone.parent_helper_lessons enable row level security;
revoke all on vppsone.parent_helper_lessons from anon, authenticated;
grant all on vppsone.parent_helper_lessons to service_role;

alter table vppsone.parent_helper_turns
  add column practice boolean not null default true,
  add column lesson_id uuid references vppsone.parent_helper_lessons(id) on delete set null,
  add column lesson_role text,
  add constraint parent_helper_turns_lesson_role_known check (lesson_role is null or lesson_role in ('used', 'asked'));

comment on column vppsone.parent_helper_turns.practice is
  'Veer Patta AI (D-590): a parent of the practice family (the owner''s number standing for TEST children) or of a real one. Every turn before this column was practice; a member of staff''s own turns (an answer, a link code) keep the default.';
comment on column vppsone.parent_helper_turns.lesson_id is
  'Veer Patta AI (D-589): the lesson this answer used (lesson_role used) or added the question to (asked).';

create index parent_helper_turns_week on vppsone.parent_helper_turns (practice, received_at);

create function vppsone.parent_helper_note_lesson(
  p_practice boolean,
  p_role text,
  p_lesson_id uuid,
  p_question text,
  p_fingerprint text,
  p_topic text
)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_practice is null then
    return null;
  end if;

  -- An answer the helper gave from what the school taught it.
  if p_role = 'used' then
    update vppsone.parent_helper_lessons l
       set used_count = l.used_count + 1, last_used_at = now(), updated_at = now()
     where l.id = p_lesson_id and l.practice = p_practice and l.status = 'answered'
    returning l.id into v_id;
    return v_id;
  end if;

  if p_role is distinct from 'asked' then
    return null;
  end if;

  -- The question again: the row the helper named, if it is still open.
  if p_lesson_id is not null then
    update vppsone.parent_helper_lessons l
       set asked_count = l.asked_count + 1, last_asked_at = now(), updated_at = now()
     where l.id = p_lesson_id and l.practice = p_practice and l.status in ('waiting', 'by_people')
    returning l.id into v_id;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  if p_question is null or p_fingerprint is null
     or char_length(btrim(p_question)) not between 6 and 160
     or char_length(p_fingerprint) not between 3 and 160 then
    return null;
  end if;

  -- New, or the same words as an open row.
  insert into vppsone.parent_helper_lessons as l (practice, question, fingerprint, topic)
  values (p_practice, btrim(p_question), p_fingerprint, case when p_topic ~ '^[a-z_]{2,30}$' then p_topic end)
  on conflict (practice, fingerprint) where status in ('waiting', 'by_people')
  do update set asked_count = l.asked_count + 1, last_asked_at = now(), updated_at = now()
  returning l.id into v_id;
  return v_id;
end;
$$;

comment on function vppsone.parent_helper_note_lesson(boolean, text, uuid, text, text, text) is
  'Veer Patta AI (D-589): used counts an answer given from a school answer; asked counts an open question again (by id, else by fingerprint) or lists it. Returns the lesson id, or null when nothing matched.';

revoke all on function vppsone.parent_helper_note_lesson(boolean, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function vppsone.parent_helper_note_lesson(boolean, text, uuid, text, text, text) to service_role;

commit;

-- ======================================================== migrations/20261112143810_parent_helper_visits.sql
-- Veer Patta AI, step 3c: a school visit booked on WhatsApp (D-592, D-593).
--
-- A family that wants a child admitted writes "admission" to the school's
-- number, picks a day and morning or afternoon, and types the child's name
-- and class. The office is told the way every hand-off tells it (Messages,
-- and WhatsApp between 6 am and 9 pm), and the visit shows on the Admissions
-- board as an enquiry with its day.
--
-- What this changes, in `vppsone`:
--
--  * `enquiries` gains the visit: `visit_on` and `visit_part` (morning or
--    afternoon, always together), `source` (`office`, which every row so far
--    reads, or `whatsapp`), and `parent_reply_id`, the hand-off a WhatsApp
--    enquiry came with: one enquiry per hand-off. The parent's own words stay
--    in the hand-off (`parent_replies`), as every hand-off's do.
--  * `parent_helper_chats.awaiting` may also read `visit:<yyyymmdd><am|pm>`:
--    after the parent picks a slot, the chat waits 30 minutes for the
--    child's name and class.
--
-- Additive for the data: no row changes, and existing enquiries read
-- source = 'office' with no visit.
--
-- Rollback:
--   update vppsone.parent_helper_chats set awaiting = null, awaiting_until = null where awaiting like 'visit:%';
--   alter table vppsone.parent_helper_chats drop constraint parent_helper_chats_awaiting_check;
--   alter table vppsone.parent_helper_chats add constraint parent_helper_chats_awaiting_check
--     check (awaiting is null or awaiting ~ '^(teacher:[a-z0-9]{4,16}|office)$');
--   alter table vppsone.enquiries drop column parent_reply_id, drop column source, drop column visit_part, drop column visit_on;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.enquiries
  add column visit_on date,
  add column visit_part text,
  add column source text not null default 'office',
  add column parent_reply_id uuid references vppsone.parent_replies(id) on delete set null,
  add constraint enquiries_visit_part_known check (visit_part is null or visit_part in ('morning', 'afternoon')),
  add constraint enquiries_visit_whole check ((visit_on is null) = (visit_part is null)),
  add constraint enquiries_source_known check (source in ('office', 'whatsapp')),
  add constraint enquiries_one_per_handoff unique (parent_reply_id);

comment on column vppsone.enquiries.visit_on is
  'The day the family asked to come and see the school (D-592), with visit_part; null when no visit was asked for.';
comment on column vppsone.enquiries.visit_part is
  'morning or afternoon: the office calls the family to fix the time.';
comment on column vppsone.enquiries.source is
  'office: typed in on the Admissions board. whatsapp: booked by the family with Veer Patta AI.';
comment on column vppsone.enquiries.parent_reply_id is
  'The hand-off the office was given for a WhatsApp booking, in One''s Messages inbox; it carries the parent''s own words.';

alter table vppsone.parent_helper_chats drop constraint parent_helper_chats_awaiting_check;
alter table vppsone.parent_helper_chats add constraint parent_helper_chats_awaiting_check
  check (awaiting is null or awaiting ~ '^(teacher:[a-z0-9]{4,16}|office|visit:[0-9]{8}(am|pm))$');

commit;

-- ======================================================== migrations/20261112161710_parent_files_to_drive.sql
-- Veer Patta AI, step 3d (D-594, D-595): parents' files and old chats in the
-- school's Shared Drive.
--
-- Two pg_cron jobs. Both call One's /api/jobs/parent-files with the WhatsApp
-- queue's Bearer secret (Vault: WHATSAPP_QUEUE_CRON_SECRET), the same door as
-- the parent-helper job, and the route checks it in Postgres
-- (whatsapp_queue_secret_matches):
--
--   parent-files            every hour at :17, and only while Veer Patta AI
--                           is switched on (whatsapp_features.parent_helper).
--                           The sweep: parents' photos, voice notes, videos
--                           and documents that the copy started by each
--                           message missed. In practice, only the owner's own
--                           number; the hub's own test mode also holds back
--                           everybody else's files.
--   whatsapp-chat-archive   every day at 21:40 UTC (03:10 in India). Asks the
--                           hub whether a month of chats is due to leave it
--                           (older than six months, or sooner when its free
--                           database passes 40%), writes that month to Drive
--                           as one spreadsheet, and only then lets the hub
--                           remove it. Most days the hub says nothing is due.
--
-- No table, column, grant or policy changes. The files and the chats are
-- never written to One's database (D-576); their Drive folders are rows in
-- vppsone.drive_folders under the keys 'wa-files…' and 'wa-chats', the way
-- the nightly backup keeps '_backups'.
--
-- Rollback:
--   select cron.unschedule('parent-files');
--   select cron.unschedule('whatsapp-chat-archive');

begin;

select cron.schedule(
  'parent-files',
  '17 * * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/parent-files',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{"part": "files"}'::jsonb,
    timeout_milliseconds := 290000
  )
  where exists (
    select 1 from vppsone.runtime_flags f
     where f.key = 'whatsapp_features'
       and f.enabled is true
       and f.value -> 'parent_helper' = 'true'::jsonb
  );
  $job$
);

select cron.schedule(
  'whatsapp-chat-archive',
  '40 21 * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/parent-files',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{"part": "archive"}'::jsonb,
    timeout_milliseconds := 290000
  );
  $job$
);

commit;

-- ======================================================== migrations/20261113021008_parent_suggestions.sql
-- Veer Patta AI: a parent's message never changes a child's record or the
-- school's on its own (D-598).
--
-- The owner, 12 Nov 2026: "Don't let parents responses affect the data of
-- the student or school". When the helper reads something in a parent's
-- WhatsApp that belongs in a child's record, it becomes a suggestion, and a
-- person at school applies it or lets it go.
--
-- Before this, two things were written on a parent's word alone: a sick-day
-- note on the register, which also stopped the queued "your child is absent"
-- WhatsApp for those days (D-588), and a school visit as an enquiry on the
-- Admissions board (D-592). Each is now a suggestion. A third kind is new: a
-- detail the parent asks the school to change (a phone number, an address).
--
-- What this adds, in `vppsone`, service role only:
--
--  * `parent_suggestions`: one row per thing the helper read. Whom it waits
--    for (the class teacher for a child's absence, the office for the rest;
--    an admin may decide any), whether it waits, was applied or was let go,
--    who decided it and how, and when it stops waiting: an absence at the end
--    of its last day, a visit at the end of its day, a change to a record
--    after seven days (the office may need to call the family first). The
--    payload holds what was read, in the school's words (days, a reason, a
--    field and its new value), never the parent's message: that stays in the
--    hand-off (`parent_replies`), as every hand-off's does.
--  * `parent_absence_notes` gains `suggestion_id`, the suggestion a note was
--    applied from, and `mark`, how the register starts the child: Leave or
--    Absent, as the person who applied it chose.
--  * `add_parent_suggestion(p)`: the helper's only write about a child.
--  * `decide_parent_suggestions(p)`: apply or let go, one or many at once, as
--    the member of staff deciding. The writes happen here and nowhere else:
--    the register's note, stopping the absent alert, the Admissions enquiry,
--    and a record value through `write_student_value`, which keeps history.
--  * Undo (`undo_parent_suggestion`) is the next file,
--    *_parent_suggestion_undo.sql. It removes rows when a person presses
--    Undo (the notes, the enquiry, the value an applied suggestion wrote), so
--    the Supabase connector asks the owner to confirm it; it goes in with
--    the owner present. Nothing in this file removes a row.
--
-- Additive: no existing row changes. Existing notes read mark = 'absent', as
-- the register has always started them.
--
-- Rollback:
--   (first *_parent_suggestion_undo.sql's rollback)
--   drop function if exists vppsone.decide_parent_suggestions(jsonb);
--   drop function if exists vppsone.add_parent_suggestion(jsonb);
--   drop function if exists vppsone.parent_suggestion_may_decide(uuid, text, text, uuid);
--   alter table vppsone.parent_absence_notes drop column suggestion_id, drop column mark;
--   drop table if exists vppsone.parent_suggestions;
--   drop function if exists vppsone.parent_suggestion_payload_ok(text, jsonb);

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

/* ------------------------------------------------------------- the shape */

-- What a suggestion of each kind holds. Written in the database as well as
-- in the app, because the payload is what a person applies.
create or replace function vppsone.parent_suggestion_payload_ok(p_kind text, p jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_day jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return false;
  end if;
  -- Only the keys of its kind: nothing else (the parent's words above all) can ride along.
  if not (
    (select coalesce(array_agg(k), array[]::text[]) from jsonb_object_keys(p) k) <@ case p_kind
      when 'absence' then array['days', 'reason']
      when 'visit' then array['day', 'part', 'child_name', 'class_label']
      when 'record' then array['field', 'value', 'was']
      else array[]::text[]
    end
  ) then
    return false;
  end if;
  if p_kind = 'absence' then
    if coalesce(jsonb_typeof(p->'days'), '') <> 'array' or jsonb_array_length(p->'days') not between 1 and 7 then
      return false;
    end if;
    for v_day in select value from jsonb_array_elements(p->'days') loop
      if coalesce(jsonb_typeof(v_day), '') <> 'string' or (v_day #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        return false;
      end if;
    end loop;
    return coalesce(p->>'reason', '') in ('sick', 'other');
  elsif p_kind = 'visit' then
    return coalesce(p->>'day', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      and coalesce(p->>'part', '') in ('morning', 'afternoon')
      and char_length(btrim(coalesce(p->>'child_name', ''))) between 1 and 120
      and (coalesce(jsonb_typeof(p->'class_label'), 'null') = 'null' or char_length(p->>'class_label') between 1 and 60);
  elsif p_kind = 'record' then
    return coalesce(p->>'field', '') in ('guardian_phone', 'mother_phone', 'date_of_birth', 'blood_group', 'address')
      and char_length(btrim(coalesce(p->>'value', ''))) between 1 and 200
      and (coalesce(jsonb_typeof(p->'was'), 'null') = 'null' or char_length(p->>'was') <= 200);
  end if;
  return false;
end;
$$;

comment on function vppsone.parent_suggestion_payload_ok(text, jsonb) is
  'D-598: what a parent suggestion of each kind holds. absence {days[1-7], reason sick|other}; visit {day, part, child_name, class_label}; record {field, value, was}.';

create table vppsone.parent_suggestions (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  session_label text not null check (char_length(session_label) between 4 and 40),
  -- The child it is about; none for a visit, which is about a child not yet at the school.
  student_id uuid,
  -- The child's class this session, when enrolled: whose class teacher decides an absence.
  class_id uuid,
  -- The hand-off it came with, in One's Messages inbox: the parent's own words.
  parent_reply_id uuid references vppsone.parent_replies(id) on delete set null,
  route text not null,
  -- The class teacher it waits for; null when it waits for the office.
  assigned_staff_id uuid references vppsone.staff_profiles(id) on delete set null,
  payload jsonb not null,
  status text not null default 'pending',
  expires_at timestamptz not null,
  decided_by uuid references vppsone.staff_profiles(id) on delete set null,
  decided_at timestamptz,
  decided_via text,
  -- What applying did, so it can be put back: the register's mark, the enquiry made, the value before.
  decision jsonb,
  -- The last time a decision on it was taken back; it may have been decided again since.
  undone_by uuid references vppsone.staff_profiles(id) on delete set null,
  undone_at timestamptz,
  -- Read for the owner's test number standing in for a family.
  practice boolean not null default false,
  created_at timestamptz not null default now(),
  constraint parent_suggestions_kind_known check (kind in ('absence', 'visit', 'record')),
  constraint parent_suggestions_route_known check (route in ('class_teacher', 'office')),
  constraint parent_suggestions_status_known check (status in ('pending', 'applied', 'dismissed', 'undone')),
  constraint parent_suggestions_via_known check (decided_via is null or decided_via in ('needs_you', 'teacher_home', 'register', 'whatsapp')),
  constraint parent_suggestions_child_known check ((kind = 'visit') = (student_id is null)),
  constraint parent_suggestions_decided_whole check ((status in ('pending', 'undone')) = (decided_at is null)),
  constraint parent_suggestions_undone_says_when check (status <> 'undone' or undone_at is not null),
  constraint parent_suggestions_payload_ok check (vppsone.parent_suggestion_payload_ok(kind, payload))
);

comment on table vppsone.parent_suggestions is
  'Veer Patta AI (D-598): something a parent said on WhatsApp that may belong in a child''s or the school''s record. Nothing is written until a member of staff applies it (decide_parent_suggestions). The parent''s words stay in the hand-off (parent_replies).';
comment on column vppsone.parent_suggestions.route is
  'class_teacher: an absence, for the class teacher of the child''s class (and an admin, and whoever corrects attendance). office: everything else, and an absence in a class with no class teacher.';
comment on column vppsone.parent_suggestions.status is
  'pending: waiting (until expires_at). applied, dismissed: decided by decided_by. undone: a decision taken back after it had expired, so it waits no longer.';
comment on column vppsone.parent_suggestions.expires_at is
  'When it stops waiting: an absence at the end of its last day (India), a visit at the end of its day, a record change seven days after it came.';

create index parent_suggestions_waiting on vppsone.parent_suggestions (session_label, status, expires_at);
create index parent_suggestions_by_class on vppsone.parent_suggestions (class_id, status) where class_id is not null;
create index parent_suggestions_decided on vppsone.parent_suggestions (session_label, decided_at) where decided_at is not null;
create unique index parent_suggestions_one_per_handoff on vppsone.parent_suggestions (parent_reply_id, kind) where parent_reply_id is not null;

alter table vppsone.parent_suggestions enable row level security;
revoke all on vppsone.parent_suggestions from anon, authenticated;
grant all on vppsone.parent_suggestions to service_role;

/* ------------------------------------------------ the register's note */

alter table vppsone.parent_absence_notes
  add column suggestion_id uuid references vppsone.parent_suggestions(id) on delete set null,
  add column mark text not null default 'absent',
  add constraint parent_absence_notes_mark_known check (mark in ('absent', 'leave'));

comment on column vppsone.parent_absence_notes.suggestion_id is
  'The suggestion this note was applied from (D-598); null for a note written before notes needed a person.';
comment on column vppsone.parent_absence_notes.mark is
  'How the register starts the child: leave or absent, as the person who applied the note chose. The teacher can still change it.';

create index parent_absence_notes_suggestion on vppsone.parent_absence_notes (suggestion_id) where suggestion_id is not null;

/* ------------------------------------------------------- who decides */

-- An absence: whoever corrects attendance, or the class teacher (or
-- assistant) of the child's class today. A visit: the office (collection) or
-- the fee desk. A record change: the office. An admin holds every
-- permission. Always someone of the session's own kind: a test account only
-- in a test session, real staff only in the real year.
create or replace function vppsone.parent_suggestion_may_decide(p_actor uuid, p_kind text, p_session text, p_class uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from vppsone.staff_profiles sp
    where sp.id = p_actor
      and sp.is_active
      and vppsone.staff_matches_session(sp.id, p_session)
      and (
        exists (
          select 1 from vppsone.role_permissions rp
          where rp.role = sp.role
            and rp.permission = any (
              case p_kind
                when 'absence' then array['attendance:correct']
                when 'visit' then array['collection:manage', 'fees:manage']
                when 'record' then array['collection:manage']
                else array[]::text[]
              end
            )
        )
        or (
          p_kind = 'absence'
          and p_class is not null
          and exists (
            select 1
            from vppsone.class_teachers ct
            join vppsone.role_permissions rp on rp.role = sp.role and rp.permission = 'attendance:mark'
            where ct.staff_profile_id = sp.id
              and ct.class_id = p_class
              and ct.session_label = p_session
              and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
              and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
          )
        )
      )
  );
$$;

comment on function vppsone.parent_suggestion_may_decide(uuid, text, text, uuid) is
  'D-598: whether this member of staff may apply or let go a parent suggestion of this kind, in this session and class.';

/* ------------------------------------------------------- the helper's write */

create or replace function vppsone.add_parent_suggestion(p jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_kind text := p->>'kind';
  v_session text := btrim(coalesce(p->>'session_label', ''));
  v_in jsonb := coalesce(p->'payload', '{}'::jsonb);
  v_practice boolean := coalesce((p->>'practice')::boolean, false);
  v_student uuid;
  v_reply uuid;
  v_payload jsonb;
  v_class uuid;
  v_route text := 'office';
  v_assigned uuid;
  v_expires timestamptz;
  v_days date[];
  v_field_id uuid;
  v_fee_column text;
  v_was text;
  v_value text;
  v_id uuid;
begin
  if v_kind is null or v_kind not in ('absence', 'visit', 'record') or char_length(v_session) not between 4 and 40 then
    raise exception 'parent_suggestion:bad_request' using errcode = '22023';
  end if;
  v_reply := nullif(p->>'parent_reply_id', '')::uuid;
  if v_kind <> 'visit' then
    v_student := (p->>'student_id')::uuid;
    if v_student is null then
      raise exception 'parent_suggestion:bad_request' using errcode = '22023';
    end if;
    select e.class_id into v_class
    from vppsone.enrolments e
    where e.student_id = v_student and e.session_label = v_session and e.status = 'enrolled'
    limit 1;
  end if;

  -- One suggestion of a kind per hand-off: a repeated turn adds nothing.
  if v_reply is not null then
    select s.id into v_id from vppsone.parent_suggestions s where s.parent_reply_id = v_reply and s.kind = v_kind;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  if v_kind = 'absence' then
    if not vppsone.parent_suggestion_payload_ok('absence', v_in) then
      raise exception 'parent_suggestion:bad_payload' using errcode = '22023';
    end if;
    select array_agg(distinct d::date order by d::date) into v_days from jsonb_array_elements_text(v_in->'days') d;
    v_payload := jsonb_build_object(
      'days', (select jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d) from unnest(v_days) d),
      'reason', v_in->>'reason'
    );
    v_expires := ((v_days[array_upper(v_days, 1)] + 1)::timestamp at time zone 'Asia/Kolkata');
    -- The class teacher of the child's class today, of the session's own kind; otherwise the office.
    if v_class is not null then
      select ct.staff_profile_id into v_assigned
      from vppsone.class_teachers ct
      join vppsone.staff_profiles sp on sp.id = ct.staff_profile_id and sp.is_active
      where ct.class_id = v_class
        and ct.session_label = v_session
        and ct.role = 'class_teacher'
        and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
        and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
        and vppsone.staff_matches_session(sp.id, v_session)
      order by ct.effective_from desc nulls last
      limit 1;
    end if;
    if v_assigned is not null then
      v_route := 'class_teacher';
    end if;
    -- The same days already waiting, or already applied, for this child: nothing new to ask.
    select s.id into v_id
    from vppsone.parent_suggestions s
    where s.kind = 'absence'
      and s.student_id = v_student
      and s.session_label = v_session
      and s.status in ('pending', 'applied')
      and s.expires_at > now()
      and (select array_agg(x::date) from jsonb_array_elements_text(s.payload->'days') x) @> v_days
    order by s.created_at
    limit 1;
    if v_id is not null then
      return v_id;
    end if;

  elsif v_kind = 'visit' then
    v_payload := jsonb_build_object(
      'day', v_in->>'day',
      'part', v_in->>'part',
      'child_name', btrim(coalesce(v_in->>'child_name', '')),
      'class_label', nullif(btrim(coalesce(v_in->>'class_label', '')), '')
    );
    if not vppsone.parent_suggestion_payload_ok('visit', v_payload) then
      raise exception 'parent_suggestion:bad_payload' using errcode = '22023';
    end if;
    v_expires := (((v_payload->>'day')::date + 1)::timestamp at time zone 'Asia/Kolkata');

  else
    v_value := btrim(coalesce(v_in->>'value', ''));
    if not vppsone.parent_suggestion_payload_ok('record', jsonb_build_object('field', v_in->>'field', 'value', v_value)) then
      raise exception 'parent_suggestion:bad_payload' using errcode = '22023';
    end if;
    select cf.id, cf.fee_column into v_field_id, v_fee_column
    from vppsone.collection_fields cf
    where cf.key = v_in->>'field' and cf.is_active;
    if v_field_id is null then
      -- Not a detail the school keeps here: the hand-off alone carries it.
      return null;
    end if;
    select sr.value into v_was from vppsone.student_records sr where sr.student_id = v_student and sr.field_id = v_field_id;
    if v_was is null and v_fee_column is not null then
      select to_jsonb(s) ->> v_fee_column into v_was from public.students s where s.id = v_student;
    end if;
    -- The school already holds this value: nothing to change.
    if v_was is not distinct from v_value then
      return null;
    end if;
    v_payload := jsonb_build_object('field', v_in->>'field', 'value', v_value, 'was', left(v_was, 200));
    if not vppsone.parent_suggestion_payload_ok('record', v_payload) then
      raise exception 'parent_suggestion:bad_payload' using errcode = '22023';
    end if;
    v_expires := now() + interval '7 days';
    select s.id into v_id
    from vppsone.parent_suggestions s
    where s.kind = 'record'
      and s.student_id = v_student
      and s.session_label = v_session
      and s.status = 'pending'
      and s.expires_at > now()
      and s.payload->>'field' = v_payload->>'field'
      and s.payload->>'value' = v_value
    limit 1;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  -- Too late to wait for anyone (an absence for today written at midnight).
  if v_expires <= now() then
    return null;
  end if;

  insert into vppsone.parent_suggestions (
    kind, session_label, student_id, class_id, parent_reply_id, route, assigned_staff_id, payload, expires_at, practice
  ) values (
    v_kind, v_session, v_student, v_class, v_reply, v_route, v_assigned, v_payload, v_expires, v_practice
  )
  on conflict (parent_reply_id, kind) where parent_reply_id is not null do nothing
  returning id into v_id;
  if v_id is null then
    select s.id into v_id from vppsone.parent_suggestions s where s.parent_reply_id = v_reply and s.kind = v_kind;
  end if;
  return v_id;
end;
$$;

comment on function vppsone.add_parent_suggestion(jsonb) is
  'D-598: the helper''s only write about a child. {kind, session_label, student_id, parent_reply_id, practice, payload}. Returns the suggestion (a new one, or the one already waiting with the same content), or null when there is nothing to ask.';

/* ------------------------------------------------------- deciding */

create or replace function vppsone.decide_parent_suggestions(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_ids uuid[];
  v_decision text := coalesce(p->>'decision', '');
  v_mark text := coalesce(nullif(p->>'mark', ''), 'leave');
  v_via text := coalesce(nullif(p->>'via', ''), 'needs_you');
  v_row vppsone.parent_suggestions%rowtype;
  v_seen uuid[] := array[]::uuid[];
  v_results jsonb := '[]'::jsonb;
  v_outcome jsonb;
  v_detail jsonb;
  v_days date[];
  v_noted integer;
  v_stopped integer;
  v_from_name text;
  v_from_phone text;
  v_phone text;
  v_enquiry uuid;
  v_field_id uuid;
  v_fee_column text;
  v_prev text;
  v_had boolean;
  v_write text;
  v_applied integer := 0;
  v_dismissed integer := 0;
  v_id uuid;
begin
  begin
    v_actor := (p->>'actor_staff_id')::uuid;
    select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_actor is null or v_ids is null or cardinality(v_ids) > 200
     or v_decision not in ('apply', 'dismiss')
     or v_mark not in ('leave', 'absent')
     or v_via not in ('needs_you', 'teacher_home', 'register', 'whatsapp') then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (select 1 from vppsone.staff_profiles where id = v_actor and is_active) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  for v_row in
    select * from vppsone.parent_suggestions where id = any (v_ids) order by created_at, id for update
  loop
    v_seen := v_seen || v_row.id;
    if v_row.status <> 'pending' then
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'already', 'status', v_row.status, 'decided_by', v_row.decided_by);
    elsif v_row.expires_at <= now() then
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'expired');
    elsif not vppsone.parent_suggestion_may_decide(v_actor, v_row.kind, v_row.session_label, v_row.class_id) then
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'not_permitted');
    elsif v_decision = 'dismiss' then
      update vppsone.parent_suggestions
      set status = 'dismissed', decided_by = v_actor, decided_at = now(), decided_via = v_via, decision = '{}'::jsonb
      where id = v_row.id;
      v_dismissed := v_dismissed + 1;
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'dismissed');
    else
      begin
        if v_row.kind = 'absence' then
          -- The register's note, one per day, with the mark the person chose;
          -- a day some note already covers keeps that note.
          select array_agg(x::date) into v_days from jsonb_array_elements_text(v_row.payload->'days') x;
          insert into vppsone.parent_absence_notes (student_id, session_label, day, reason, parent_reply_id, practice, suggestion_id, mark)
          select v_row.student_id, v_row.session_label, d, v_row.payload->>'reason', v_row.parent_reply_id, v_row.practice, v_row.id, v_mark
          from unnest(v_days) d
          on conflict (student_id, day) do nothing;
          get diagnostics v_noted = row_count;
          -- The parent told the school: no "your child is absent" WhatsApp for those days.
          update vppsone.parent_message_queue
          set status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor
          where session_label = v_row.session_label
            and kind = 'absent_alert'
            and status = 'queued'
            and student_id = v_row.student_id
            and day = any (v_days);
          get diagnostics v_stopped = row_count;
          v_detail := jsonb_build_object('mark', v_mark, 'noted', v_noted, 'alerts_stopped', v_stopped);

        elsif v_row.kind = 'visit' then
          select pr.from_name, pr.from_phone into v_from_name, v_from_phone
          from vppsone.parent_replies pr where pr.id = v_row.parent_reply_id;
          if v_from_phone is null then
            raise exception 'handoff_gone';
          end if;
          -- "+919000000001" -> "9000000001", the way the Admissions board keeps a phone.
          v_phone := regexp_replace(v_from_phone, '[^0-9]', '', 'g');
          if char_length(v_phone) = 12 and left(v_phone, 2) = '91' then
            v_phone := substr(v_phone, 3);
          end if;
          v_enquiry := null;
          insert into vppsone.enquiries (
            session_label, stage, child_name, class_label, parent_name, phone, source, visit_on, visit_part, parent_reply_id, created_by
          ) values (
            v_row.session_label, 'enquiry', v_row.payload->>'child_name', v_row.payload->>'class_label',
            nullif(nullif(left(regexp_replace(btrim(coalesce(v_from_name, '')), '\s+', ' ', 'g'), 80), ''), 'Parent'),
            nullif(v_phone, ''), 'whatsapp', (v_row.payload->>'day')::date, v_row.payload->>'part', v_row.parent_reply_id, v_actor
          )
          on conflict (parent_reply_id) do nothing
          returning id into v_enquiry;
          if v_enquiry is null then
            select e.id into v_enquiry from vppsone.enquiries e where e.parent_reply_id = v_row.parent_reply_id;
            v_detail := jsonb_build_object('enquiry_id', v_enquiry, 'created', false);
          else
            v_detail := jsonb_build_object('enquiry_id', v_enquiry, 'created', true);
          end if;

        else
          select cf.id, cf.fee_column into v_field_id, v_fee_column
          from vppsone.collection_fields cf where cf.key = v_row.payload->>'field';
          if v_field_id is null then
            raise exception 'field_gone';
          end if;
          v_prev := null;
          select sr.value into v_prev from vppsone.student_records sr where sr.student_id = v_row.student_id and sr.field_id = v_field_id;
          v_had := found;
          if not v_had and v_fee_column is not null then
            select to_jsonb(s) ->> v_fee_column into v_prev from public.students s where s.id = v_row.student_id;
          end if;
          -- The one writer of a child's record, as the person deciding: kept in its history.
          v_write := vppsone.write_student_value(
            v_row.student_id, v_field_id, v_row.session_label, v_row.payload->>'value',
            'office', 'whatsapp_parent', 'parent_suggestion:' || v_row.id::text, null, gen_random_uuid(), v_actor
          );
          v_detail := jsonb_build_object('field_id', v_field_id, 'previous', v_prev, 'had_record', v_had, 'write', v_write);
        end if;

        update vppsone.parent_suggestions
        set status = 'applied', decided_by = v_actor, decided_at = now(), decided_via = v_via, decision = v_detail
        where id = v_row.id;
        v_applied := v_applied + 1;
        v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'applied', 'kind', v_row.kind) || v_detail;
      exception when others then
        v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'failed', 'reason', left(sqlerrm, 120));
      end;
    end if;
    v_results := v_results || jsonb_build_array(v_outcome);
  end loop;

  foreach v_id in array v_ids loop
    if not (v_id = any (v_seen)) then
      v_results := v_results || jsonb_build_array(jsonb_build_object('id', v_id, 'outcome', 'not_found'));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'applied', v_applied, 'dismissed', v_dismissed, 'results', v_results);
end;
$$;

comment on function vppsone.decide_parent_suggestions(jsonb) is
  'D-598: apply or let go parent suggestions, as {actor_staff_id, ids[<=200], decision apply|dismiss, mark leave|absent, via}. Each is re-checked (still waiting, not expired, this person may decide it) and answered on its own: applied, dismissed, already, expired, not_permitted, failed or not_found.';

revoke all on function vppsone.parent_suggestion_payload_ok(text, jsonb) from public, anon, authenticated;
revoke all on function vppsone.parent_suggestion_may_decide(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function vppsone.add_parent_suggestion(jsonb) from public, anon, authenticated;
revoke all on function vppsone.decide_parent_suggestions(jsonb) from public, anon, authenticated;
grant execute on function vppsone.parent_suggestion_payload_ok(text, jsonb) to service_role;
grant execute on function vppsone.parent_suggestion_may_decide(uuid, text, text, uuid) to service_role;
grant execute on function vppsone.add_parent_suggestion(jsonb) to service_role;
grant execute on function vppsone.decide_parent_suggestions(jsonb) to service_role;

commit;

-- ======================================================== migrations/20261113022255_parent_suggestion_undo.sql
-- Veer Patta AI (D-598, D-599): Undo, for a parent's suggestion a member of
-- staff applied or let go. Undo keeps every row.
--
-- The rest of D-598 is *_parent_suggestions.sql, just before this. Taking a
-- decision back changes rows and keeps them, so nothing is lost and each
-- step stays on record:
--
--  * the register's notes an applied absence added are withdrawn
--    (`parent_absence_notes.withdrawn_at`, `withdrawn_by`), and the register
--    no longer reads them. Applying the suggestion again brings those days
--    back, with the mark chosen then;
--  * the Admissions enquiry an applied visit made is closed, while the office
--    has not started on it. Applying the visit again opens it again;
--  * the value an applied change wrote to a child's record is put back
--    through the record writer, with history: the value before, or no value
--    of One's own when One held none, so the fee app's value shows again
--    (readers take One's value, else the fee app's). Never over a value
--    somebody wrote since.
--
-- So `decide_parent_suggestions` is written again here, the same but for
-- that: a withdrawn note and an enquiry Undo closed come back when the
-- suggestion is applied again.
--
-- An earlier draft of this file removed those rows on Undo. The Supabase
-- connector asks the owner to confirm any migration that can remove rows,
-- and that question cannot be answered from a thread; the owner asked on
-- 13 Nov for migrations to go in without asking him. Keeping the rows is the
-- better record anyway.
--
-- Rollback:
--   drop function if exists vppsone.undo_parent_suggestion(jsonb);
--   (then decide_parent_suggestions as *_parent_suggestions.sql wrote it)
--   alter table vppsone.parent_absence_notes drop column withdrawn_by, drop column withdrawn_at;

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

/* ------------------------------------------------ a note taken back */

alter table vppsone.parent_absence_notes
  add column withdrawn_at timestamptz,
  add column withdrawn_by uuid references vppsone.staff_profiles(id) on delete set null,
  add constraint parent_absence_notes_withdrawn_says_when check (withdrawn_by is null or withdrawn_at is not null);

comment on column vppsone.parent_absence_notes.withdrawn_at is
  'D-599: when a person took the note back (Undo on the suggestion it was applied from). The note is kept and the register no longer reads it; applying the suggestion again brings it back.';
comment on column vppsone.parent_absence_notes.withdrawn_by is
  'D-599: who took the note back.';

/* ------------------------------------------------------- deciding */

create or replace function vppsone.decide_parent_suggestions(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_ids uuid[];
  v_decision text := coalesce(p->>'decision', '');
  v_mark text := coalesce(nullif(p->>'mark', ''), 'leave');
  v_via text := coalesce(nullif(p->>'via', ''), 'needs_you');
  v_row vppsone.parent_suggestions%rowtype;
  v_seen uuid[] := array[]::uuid[];
  v_results jsonb := '[]'::jsonb;
  v_outcome jsonb;
  v_detail jsonb;
  v_days date[];
  v_noted integer;
  v_stopped integer;
  v_from_name text;
  v_from_phone text;
  v_phone text;
  v_enquiry uuid;
  v_field_id uuid;
  v_fee_column text;
  v_prev text;
  v_had boolean;
  v_write text;
  v_applied integer := 0;
  v_dismissed integer := 0;
  v_id uuid;
begin
  begin
    v_actor := (p->>'actor_staff_id')::uuid;
    select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_actor is null or v_ids is null or cardinality(v_ids) > 200
     or v_decision not in ('apply', 'dismiss')
     or v_mark not in ('leave', 'absent')
     or v_via not in ('needs_you', 'teacher_home', 'register', 'whatsapp') then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (select 1 from vppsone.staff_profiles where id = v_actor and is_active) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  for v_row in
    select * from vppsone.parent_suggestions where id = any (v_ids) order by created_at, id for update
  loop
    v_seen := v_seen || v_row.id;
    if v_row.status <> 'pending' then
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'already', 'status', v_row.status, 'decided_by', v_row.decided_by);
    elsif v_row.expires_at <= now() then
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'expired');
    elsif not vppsone.parent_suggestion_may_decide(v_actor, v_row.kind, v_row.session_label, v_row.class_id) then
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'not_permitted');
    elsif v_decision = 'dismiss' then
      update vppsone.parent_suggestions
      set status = 'dismissed', decided_by = v_actor, decided_at = now(), decided_via = v_via, decision = '{}'::jsonb
      where id = v_row.id;
      v_dismissed := v_dismissed + 1;
      v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'dismissed');
    else
      begin
        if v_row.kind = 'absence' then
          -- The register's note, one per day, with the mark the person chose;
          -- a day some note already covers keeps that note, and a day whose
          -- note was taken back (Undo) has it back, as decided now.
          select array_agg(x::date) into v_days from jsonb_array_elements_text(v_row.payload->'days') x;
          insert into vppsone.parent_absence_notes as n (student_id, session_label, day, reason, parent_reply_id, practice, suggestion_id, mark)
          select v_row.student_id, v_row.session_label, d, v_row.payload->>'reason', v_row.parent_reply_id, v_row.practice, v_row.id, v_mark
          from unnest(v_days) d
          on conflict (student_id, day) do update
            set session_label = excluded.session_label, reason = excluded.reason, parent_reply_id = excluded.parent_reply_id,
                practice = excluded.practice, suggestion_id = excluded.suggestion_id, mark = excluded.mark,
                withdrawn_at = null, withdrawn_by = null
            where n.withdrawn_at is not null;
          get diagnostics v_noted = row_count;
          -- The parent told the school: no "your child is absent" WhatsApp for those days.
          update vppsone.parent_message_queue
          set status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor
          where session_label = v_row.session_label
            and kind = 'absent_alert'
            and status = 'queued'
            and student_id = v_row.student_id
            and day = any (v_days);
          get diagnostics v_stopped = row_count;
          v_detail := jsonb_build_object('mark', v_mark, 'noted', v_noted, 'alerts_stopped', v_stopped);

        elsif v_row.kind = 'visit' then
          select pr.from_name, pr.from_phone into v_from_name, v_from_phone
          from vppsone.parent_replies pr where pr.id = v_row.parent_reply_id;
          if v_from_phone is null then
            raise exception 'handoff_gone';
          end if;
          -- "+919000000001" -> "9000000001", the way the Admissions board keeps a phone.
          v_phone := regexp_replace(v_from_phone, '[^0-9]', '', 'g');
          if char_length(v_phone) = 12 and left(v_phone, 2) = '91' then
            v_phone := substr(v_phone, 3);
          end if;
          v_enquiry := null;
          -- On the board as this person's; an enquiry Undo closed opens again.
          insert into vppsone.enquiries as e (
            session_label, stage, child_name, class_label, parent_name, phone, source, visit_on, visit_part, parent_reply_id, created_by
          ) values (
            v_row.session_label, 'enquiry', v_row.payload->>'child_name', v_row.payload->>'class_label',
            nullif(nullif(left(regexp_replace(btrim(coalesce(v_from_name, '')), '\s+', ' ', 'g'), 80), ''), 'Parent'),
            nullif(v_phone, ''), 'whatsapp', (v_row.payload->>'day')::date, v_row.payload->>'part', v_row.parent_reply_id, v_actor
          )
          on conflict (parent_reply_id) do update
            set stage = 'enquiry', stage_changed_at = now(), updated_at = now(),
                visit_on = excluded.visit_on, visit_part = excluded.visit_part
            where e.stage = 'closed' and e.student_id is null
          returning e.id into v_enquiry;
          if v_enquiry is null then
            select x.id into v_enquiry from vppsone.enquiries x where x.parent_reply_id = v_row.parent_reply_id;
            v_detail := jsonb_build_object('enquiry_id', v_enquiry, 'created', false);
          else
            v_detail := jsonb_build_object('enquiry_id', v_enquiry, 'created', true);
          end if;

        else
          select cf.id, cf.fee_column into v_field_id, v_fee_column
          from vppsone.collection_fields cf where cf.key = v_row.payload->>'field';
          if v_field_id is null then
            raise exception 'field_gone';
          end if;
          v_prev := null;
          select sr.value into v_prev from vppsone.student_records sr where sr.student_id = v_row.student_id and sr.field_id = v_field_id;
          v_had := found;
          if not v_had and v_fee_column is not null then
            select to_jsonb(s) ->> v_fee_column into v_prev from public.students s where s.id = v_row.student_id;
          end if;
          -- The one writer of a child's record, as the person deciding: kept in its history.
          v_write := vppsone.write_student_value(
            v_row.student_id, v_field_id, v_row.session_label, v_row.payload->>'value',
            'office', 'whatsapp_parent', 'parent_suggestion:' || v_row.id::text, null, gen_random_uuid(), v_actor
          );
          v_detail := jsonb_build_object('field_id', v_field_id, 'previous', v_prev, 'had_record', v_had, 'write', v_write);
        end if;

        update vppsone.parent_suggestions
        set status = 'applied', decided_by = v_actor, decided_at = now(), decided_via = v_via, decision = v_detail
        where id = v_row.id;
        v_applied := v_applied + 1;
        v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'applied', 'kind', v_row.kind) || v_detail;
      exception when others then
        v_outcome := jsonb_build_object('id', v_row.id, 'outcome', 'failed', 'reason', left(sqlerrm, 120));
      end;
    end if;
    v_results := v_results || jsonb_build_array(v_outcome);
  end loop;

  foreach v_id in array v_ids loop
    if not (v_id = any (v_seen)) then
      v_results := v_results || jsonb_build_array(jsonb_build_object('id', v_id, 'outcome', 'not_found'));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'applied', v_applied, 'dismissed', v_dismissed, 'results', v_results);
end;
$$;

comment on function vppsone.decide_parent_suggestions(jsonb) is
  'D-598: apply or let go parent suggestions, as {actor_staff_id, ids[<=200], decision apply|dismiss, mark leave|absent, via}. Each is re-checked (still waiting, not expired, this person may decide it) and answered on its own: applied, dismissed, already, expired, not_permitted, failed or not_found. Applying again after an Undo brings back the notes it withdrew and the enquiry it closed (D-599).';

/* ------------------------------------------------------- taking it back */

create or replace function vppsone.undo_parent_suggestion(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_id uuid;
  v_row vppsone.parent_suggestions%rowtype;
  v_enquiry vppsone.enquiries%rowtype;
  v_record vppsone.student_records%rowtype;
  v_taken_back integer := 0;
  v_status text;
begin
  begin
    v_actor := (p->>'actor_staff_id')::uuid;
    v_id := (p->>'id')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_actor is null or v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select * into v_row from vppsone.parent_suggestions where id = v_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_row.status not in ('applied', 'dismissed') then
    return jsonb_build_object('ok', false, 'reason', 'not_decided', 'status', v_row.status);
  end if;
  if not vppsone.parent_suggestion_may_decide(v_actor, v_row.kind, v_row.session_label, v_row.class_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  if v_row.status = 'applied' then
    if v_row.kind = 'absence' then
      -- Only the days this suggestion noted, withdrawn and kept; a stopped absent alert is not queued again.
      update vppsone.parent_absence_notes
      set withdrawn_at = now(), withdrawn_by = v_actor
      where suggestion_id = v_row.id and withdrawn_at is null;
      get diagnostics v_taken_back = row_count;

    elsif v_row.kind = 'visit' then
      if coalesce((v_row.decision->>'created')::boolean, false) then
        select * into v_enquiry from vppsone.enquiries where id = (v_row.decision->>'enquiry_id')::uuid for update;
        if found then
          -- The office has started on it: it stays, and is changed on the board.
          if v_enquiry.stage <> 'enquiry' or v_enquiry.student_id is not null then
            return jsonb_build_object('ok', false, 'reason', 'enquiry_moved');
          end if;
          -- Closed, as a family that is not coming, and kept.
          update vppsone.enquiries
          set stage = 'closed', stage_changed_at = now(), updated_at = now()
          where id = v_enquiry.id;
          get diagnostics v_taken_back = row_count;
        end if;
      end if;

    elsif coalesce(v_row.decision->>'write', '') = 'written' then
      select * into v_record
      from vppsone.student_records
      where student_id = v_row.student_id and field_id = (v_row.decision->>'field_id')::uuid
      for update;
      -- Somebody has written the value since: it is theirs now, and stays.
      if not found or v_record.source_ref is distinct from 'parent_suggestion:' || v_row.id::text then
        return jsonb_build_object('ok', false, 'reason', 'record_moved');
      end if;
      -- The value before, through the one writer, with history. When One held
      -- none of its own, none again, and the fee app's value shows.
      perform vppsone.write_student_value(
        v_row.student_id, v_record.field_id, v_record.session_label,
        case when coalesce((v_row.decision->>'had_record')::boolean, false) then v_row.decision->>'previous' end,
        'office', 'whatsapp_parent_undo', 'parent_suggestion:' || v_row.id::text || ':undo', null, gen_random_uuid(), v_actor
      );
      v_taken_back := 1;
    end if;
  end if;

  -- It waits again, to be decided afresh, unless its time has passed.
  v_status := case when v_row.expires_at > now() then 'pending' else 'undone' end;
  update vppsone.parent_suggestions
  set status = v_status, decided_by = null, decided_at = null, decided_via = null, decision = null,
      undone_by = v_actor, undone_at = now()
  where id = v_row.id;

  return jsonb_build_object('ok', true, 'status', v_status, 'was', v_row.status, 'taken_back', v_taken_back);
end;
$$;

comment on function vppsone.undo_parent_suggestion(jsonb) is
  'D-599: {actor_staff_id, id}. Takes back an applied suggestion, keeping every row: its register notes are withdrawn, the enquiry it made is closed while the office has not started on it, the record value is put back while nobody has written since. Or takes back a "Not now". It waits again until it expires.';

revoke all on function vppsone.undo_parent_suggestion(jsonb) from public, anon, authenticated;
grant execute on function vppsone.undo_parent_suggestion(jsonb) to service_role;

commit;

-- ======================================================== migrations/20261113044301_parent_helper_away_note.sql
-- Veer Patta AI: a class teacher decides a parent's "my child will be away"
-- note from WhatsApp (D-602; the owner's idea 4, 12 Nov 2026).
--
-- When the helper tells a class teacher that a parent says their child will
-- be away, the alert carries three buttons: Mark Leave, Mark Absent and
-- Not now. While the teacher's chat with the school is open the alert is
-- typed, with reply buttons. Otherwise it is this approved message, whose
-- quick replies carry the note's own id back when tapped. A tap decides the
-- note as that teacher, exactly as the same button in One does
-- (`decide_parent_suggestions` with via 'whatsapp', 20261113021008): the
-- database checks again that they may, and that it still waits. Alerts go
-- only from 6 am to 9 pm, as every hand-off's do (D-578).
--
-- What this adds: two registry rows, `not_submitted`, Hindi and English. The
-- hourly template check sends each to Meta once by itself (the hub's
-- `POST /v1/templates`, quick replies included); nothing is sent to anyone.
-- Until Meta approves them, a teacher whose chat is closed gets the ordinary
-- staff alert, and the note waits for them in One.
--
-- Nothing here sends to a real person while practice mode is on or real
-- recipients are off: every message still passes `checkWhatsAppSend`.
--
-- Rollback: take out the two rows by key ('vpps_staff_away_note_hi_v1',
-- 'vpps_staff_away_note_en_v1') while they still read `not_submitted`. Once
-- Meta has them, leave them: a row Meta knows is how One reads its status.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_staff_away_note_hi_v1', 'vpps_staff_away_note_hi_v1', 'hi', 'parent_helper', 4, array['name', 'student', 'away', 'message']::text[], 'none', false, 'A parent says a child will be away, with Mark Leave, Mark Absent and Not now (hi)', 'अभिभावक का छुट्टी का संदेश'),
  ('vpps_staff_away_note_en_v1', 'vpps_staff_away_note_en_v1', 'en', 'parent_helper', 4, array['name', 'student', 'away', 'message']::text[], 'none', false, 'A parent says a child will be away, with Mark Leave, Mark Absent and Not now (en)', 'अभिभावक का छुट्टी का संदेश')
on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261113084707_parent_helper_turn_stages.sql
-- Veer Patta AI: where each answer's time went (D-605).
--
-- The owner, testing on 13 Nov 2026, found the helper slow and the typing
-- dots missing. The ledger kept one number per answer (`latency_ms`, from
-- the parent's message to the reply going out), which says that an answer
-- was slow but not which part. This adds the parts: the hand-off from Meta
-- through the hub, One's own checks, the hub's claim (when the parent sees
-- the blue ticks and the dots), the family's records, working out the
-- answer, Claude's share of it, a receipt PDF, and the send.
--
-- One nullable column, written by `finishTurn` as an object of whole
-- milliseconds. Metadata only, like the rest of the row: never what the
-- parent wrote.
--
-- Rollback: the column can stay; nothing reads it but people looking into a
-- slow answer.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.parent_helper_turns
  add column if not exists stages_ms jsonb
    check (stages_ms is null or jsonb_typeof(stages_ms) = 'object');

comment on column vppsone.parent_helper_turns.stages_ms is
  'Veer Patta AI (D-605): where this answer''s time went, in whole milliseconds: before (the parent''s message to One starting), checks, claim, dots (the parent''s message to the typing dots), family, compose, ai, receipt, waiting, send. Only the parts the turn reached.';

commit;

-- ======================================================== migrations/20261113205845_staff_helper_roles.sql
-- Veer Patta AI answers a member of staff as their role (D-607).
--
-- The owner, 13 Nov 2026: a number that belongs to the admin, a teacher or
-- the accountant must be answered as that person, with that role's menu,
-- not as a parent. Two additions make that possible:
--
--  1. `parent_helper_chats.hat`: which way this chat is answered now. For a
--     member of staff it is null (their own role) or 'parent' (they chose to
--     write to the school as a parent). For the owner's test number it is the
--     role he is trying (admin, office, accountant, fee_collector, teacher,
--     academic_coordinator, exam_coordinator, view_only) or 'parent'. Never
--     what anybody wrote.
--
--  2. `vppsone.staff_helper_fees`: the fee figures an accountant, the office
--     or an admin asks for on WhatsApp, for a TEST session only (the practice
--     records, which are One's own). A real year's figures come from the Fees
--     app, which a webhook cannot read on anybody's behalf, so a real year
--     returns null and the reply points to One. The money rules are the
--     Fees app's: fees and late fees are separate and never added; a
--     write-off (payment_mode 'discount') is not collection; a reversed
--     receipt counts only what was not reversed; money counts students on
--     the roll or who have paid something.
--
-- Read-only, service role only. Additive: a nullable column, a check, and a
-- function. Rollback: the column can stay (nothing else reads it); the
-- function can be left unused.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.parent_helper_chats
  add column if not exists hat text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'parent_helper_chats_hat_shape'
      and conrelid = 'vppsone.parent_helper_chats'::regclass
  ) then
    alter table vppsone.parent_helper_chats
      add constraint parent_helper_chats_hat_shape check (hat is null or hat ~ '^[a-z_]{3,32}$');
  end if;
end;
$$;

comment on column vppsone.parent_helper_chats.hat is
  'Veer Patta AI (D-607): how this chat is answered now. Null: as the person the number belongs to (a parent, or a member of staff as their role). ''parent'': a member of staff writing as a parent. On the owner''s test number, the role being tried (admin, office, accountant, fee_collector, teacher, academic_coordinator, exam_coordinator, view_only) or ''parent''.';

create or replace function vppsone.staff_helper_fees(p_session_label text, p_day date, p_query text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with guard as (
    -- The practice records only. A real year's money is the Fees app's.
    select p_session_label as label
    where p_session_label ~* '^(TEST|UAT|DEMO)-' and p_day is not null
  ),
  paid as (
    -- Money in, net of reversals. A write-off is not collection.
    select r.payment_date as day, r.payment_mode::text as mode,
           greatest(r.total_amount - coalesce(t.reversed_amount, 0), 0) as net
    from public.receipts r
    join public.students s on s.id = r.student_id
    join public.classes c on c.id = s.class_id
    join guard g on c.session_label = g.label
    left join public.v_receipt_reversal_totals t on t.receipt_id = r.id
    where r.payment_mode::text <> 'discount'
  ),
  money as (
    -- Students on the roll, or who have paid something (a child who left owing still owes).
    select f.*
    from public.v_workbook_student_financials f
    join guard g on f.session_label = g.label
    where f.record_status::text = 'active' or coalesce(f.total_paid, 0) > 0
  ),
  q as (
    select nullif(btrim(coalesce(p_query, '')), '') as text
  ),
  found as (
    select f.student_id, f.admission_no, f.student_name, f.class_label, f.record_status::text as status,
           coalesce(f.base_outstanding_amount, 0) as fees_pending,
           coalesce(f.late_fee_outstanding_amount, 0) as late_pending,
           coalesce(f.total_paid, 0) as total_paid,
           f.last_payment_date, f.last_payment_amount,
           coalesce(f.overdue_installment_count, 0) as overdue_installments,
           f.next_due_date, f.next_due_amount,
           lower(coalesce(f.admission_no, '')) = lower(q.text) as exact
    from public.v_workbook_student_financials f
    join guard g on f.session_label = g.label
    cross join q
    where q.text is not null and length(q.text) between 2 and 60
      and (
        lower(coalesce(f.admission_no, '')) = lower(q.text)
        or f.student_name ilike '%' || replace(replace(replace(q.text, '\', '\\'), '%', '\%'), '_', '\_') || '%'
      )
  )
  select case when not exists (select 1 from guard) then null else jsonb_build_object(
    'day', p_day,
    'today', (
      select jsonb_build_object(
        'total', coalesce(sum(p.net), 0),
        'count', count(*) filter (where p.net > 0),
        'by_mode', coalesce((
          select jsonb_agg(jsonb_build_object('mode', m.mode, 'total', m.total, 'count', m.n) order by m.total desc)
          from (
            select p2.mode, sum(p2.net) as total, count(*) filter (where p2.net > 0) as n
            from paid p2
            where p2.day = p_day
            group by p2.mode
            having sum(p2.net) > 0
          ) m
        ), '[]'::jsonb))
      from paid p
      where p.day = p_day
    ),
    'last_day', (
      select jsonb_build_object('day', d.day, 'total', sum(p.net), 'count', count(*) filter (where p.net > 0))
      from (select max(p0.day) as day from paid p0 where p0.day < p_day and p0.net > 0) d
      join paid p on p.day = d.day
      group by d.day
    ),
    'month', (
      select jsonb_build_object('total', coalesce(sum(p.net), 0), 'count', count(*) filter (where p.net > 0))
      from paid p
      where p.day >= date_trunc('month', p_day)::date and p.day <= p_day
    ),
    'session', (
      select jsonb_build_object(
        'collected', (select coalesce(sum(p.net), 0) from paid p),
        'fees_pending', coalesce(sum(m.base_outstanding_amount) filter (where m.base_outstanding_amount > 0), 0),
        'late_pending', coalesce(sum(m.late_fee_outstanding_amount) filter (where m.late_fee_outstanding_amount > 0), 0),
        'with_dues', count(*) filter (where m.base_outstanding_amount > 0),
        'overdue', count(*) filter (where m.base_outstanding_amount > 0 and coalesce(m.overdue_installment_count, 0) > 0),
        'late_only', count(*) filter (where coalesce(m.base_outstanding_amount, 0) <= 0 and m.late_fee_outstanding_amount > 0),
        'students', count(*))
      from money m
    ),
    'query', (select q.text from q),
    'match_count', (select count(*) from found),
    'matches', coalesce((
      select jsonb_agg(jsonb_build_object(
          'student_id', x.student_id, 'admission_no', x.admission_no, 'name', x.student_name,
          'class_label', x.class_label, 'status', x.status,
          'fees_pending', x.fees_pending, 'late_pending', x.late_pending, 'total_paid', x.total_paid,
          'last_payment_date', x.last_payment_date, 'last_payment_amount', x.last_payment_amount,
          'overdue_installments', x.overdue_installments,
          'next_due_date', x.next_due_date, 'next_due_amount', x.next_due_amount)
        order by x.exact desc, x.student_name)
      from (select * from found order by exact desc, student_name limit 6) x
    ), '[]'::jsonb)
  ) end;
$$;

comment on function vppsone.staff_helper_fees(text, date, text) is
  'Veer Patta AI (D-607): fee figures for a member of staff on WhatsApp, TEST sessions only (null otherwise). Today''s, the last day''s, the month''s and the session''s collection net of reversals and without write-offs; fees pending and late fees pending kept apart; up to six students matching an admission number or a name. Service role only.';

revoke all on function vppsone.staff_helper_fees(text, date, text) from public, anon, authenticated;
grant execute on function vppsone.staff_helper_fees(text, date, text) to service_role;

commit;
