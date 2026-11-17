-- KMD One database setup — kmd_db_part 3 of 11. Run in order, each once.
-- Files: 20260922091500_create_data_replica_log.sql … 20261004051001_attendance_half_day_status.sql

-- ======================================================== migrations/20260922091500_create_data_replica_log.sql
-- The record of where this database's fee data came from.
--
-- `schoolfees-dev` now carries a de-identified replica of the live fee
-- database: the same 614 students, the same 2,536 instalments and the same
-- totals to the rupee, with every name, phone number, address and government
-- identifier replaced or dropped (scripts/replicate-live.mjs).
--
-- **This table exists so that "is this live data?" is a question with an
-- answer in the database rather than a matter of recognising twelve
-- surnames.** Anything reading this database — a person, a test, an agent —
-- can select one row and know. A database with no row here has not been
-- through the replica pipeline, which is itself the answer.
--
-- It lives in `vppsone` because rule 1 says so: `public` belongs to the fee
-- app, and a table this app invented does not go there.
create table if not exists vppsone.data_replica (
  id uuid primary key default gen_random_uuid(),

  -- Where the rows came from, by project ref, so the answer survives the
  -- environment variables being rewritten.
  source_project text not null,
  target_project text not null,

  -- What was actually moved, and what was deliberately left behind.
  tables_copied integer not null,
  rows_copied integer not null,
  tables_skipped jsonb not null default '{}'::jsonb,

  -- Which columns were masked and how. The honest record of what a reader of
  -- this database is looking at.
  masked_columns jsonb not null default '{}'::jsonb,

  -- Rows the source holds that the source's own rules would now reject, kept
  -- rather than dropped so the money still adds up, and flagged so they can
  -- be found again.
  carried_exceptions jsonb not null default '{}'::jsonb,

  note text,
  created_at timestamptz not null default now()
);

comment on table vppsone.data_replica is
  'One row per replica load. Its presence means the fee data in this database is masked test data copied from another project, never the live original.';

alter table vppsone.data_replica enable row level security;

-- Readable by any signed-in member of staff: knowing whether you are looking
-- at real money is not a privilege, it is the first thing anyone should be
-- able to check. Writing is left to the service role that runs the loader.
drop policy if exists data_replica_readable_by_staff on vppsone.data_replica;
create policy data_replica_readable_by_staff
  on vppsone.data_replica
  for select
  to authenticated
  using (true);

-- ======================================================== migrations/20260922100000_current_staff_role_reads_vppsone.sql
-- ⚠ THIS MIGRATION CHANGES A FUNCTION THE FEE APP OWNS. ⚠
--
-- Everything else in this directory creates or alters objects in the `vppsone`
-- schema, which is rule 1. This one redefines `private.current_staff_role()`,
-- which belongs to School Fees — so read the whole header before changing it,
-- and **it must be applied to the live fee database at cutover** or VPPS One
-- will not be able to take a rupee there.
--
-- ## What was broken
--
-- An accountant in VPPS One could not post a payment. Not a configuration
-- problem and not a client problem: `post_student_payment_with_adjustments`
-- opens with `if not public.has_permission('payments:write')`, and
-- `has_permission` is
--
--     select auth.uid() is not null and case private.current_staff_role() … end
--
-- while `current_staff_role()` read **only** `public.users`. A VPPS One account
-- fails that both ways — through the cookie client because it has no
-- `public.users` row (D-6 deliberately keeps each person's role in
-- `vppsone.staff_profiles` so it is not recorded in two places that can
-- disagree), and through the service-role client because `auth.uid()` is null
-- there. Sixteen of the eighteen fee RPCs are gated this way; ten of them,
-- including posting, refunds and every repayment-plan action, have no
-- service-role arm to fall back on.
--
-- Tried, not inferred: a ₹100 post as `qa.fees` with a real session token and
-- again as service role both answered "You do not have permission to post
-- payments", and wrote no receipt.
--
-- ## Why this is the fix, and why it is small
--
-- **The fee database was already prepared for it.** `public.staff_role`
-- already contains all eight VPPS One roles — `office`,
-- `academic_coordinator` and `exam_coordinator` alongside the fee app's five —
-- in dev *and* in live, and `public.has_permission()` already has a case arm
-- for each of them. The only piece left undone was this function, which never
-- looked anywhere but `public.users`.
--
-- **It is purely additive.** The fee app's own users all have a `public.users`
-- row, so the first branch answers for every one of them exactly as before.
-- The second branch can only fire for an account that has no row there — which
-- is to say, only for VPPS One. No existing behaviour changes.
--
-- **It keeps the person.** The alternative considered was signing VPPS One's
-- fee RPC calls as one shared service identity in `public.users`. That works,
-- but then `auth.uid()` inside the function is the machine, so `created_by` on
-- every receipt records the machine rather than the accountant who took the
-- money. On a receipts table that is deliberately append-only, losing who did
-- it is too high a price. Here `auth.uid()` is still the real person and the
-- audit trail stays true.
--
-- **It does not widen what anybody may do.** The role still comes from
-- `vppsone.staff_profiles`, which is the only place this app records one, and
-- `has_permission` decides what it means. An `office` account resolves to the
-- `office` arm, which grants no `payments:*` at all — so "office reads fees,
-- cannot post" (D-180) still holds at the database, not just in the app.
--
-- The two enums carry the same eight labels, so the cast through `text` is
-- total; a label present in one and not the other would raise rather than
-- silently resolve to anything.
create or replace function private.current_staff_role()
returns public.staff_role
language sql
stable
security definer
set search_path to 'public', 'auth', 'private'
as $function$
  select coalesce(
    -- The fee app's own answer, unchanged and still first.
    (
      select u.role
      from public.users as u
      where u.id = auth.uid()
        and u.is_active = true
      limit 1
    ),
    -- VPPS One's answer, consulted only when the fee app has never heard of
    -- this person. `vppsone.staff_profiles` is where this app records a role
    -- and the only place it does.
    (
      select sp.role::text::public.staff_role
      from vppsone.staff_profiles as sp
      where sp.user_id = auth.uid()
        and sp.is_active = true
      limit 1
    )
  );
$function$;

comment on function private.current_staff_role() is
  'The signed-in person''s fee role. public.users first, then vppsone.staff_profiles for accounts the fee app has no row for. See the migration header: this function is owned by School Fees and must be applied to the live fee database at cutover.';

-- ======================================================== migrations/20261004031630_staff_authority_and_scoped_reads.sql
-- P1 (Gate C): one staff authority, and reads scoped to it.
--
-- Until now every `vppsone` table carried one policy, `for select to
-- authenticated using (true)`. The app checked permissions on every screen,
-- but PostgREST is reachable directly with any signed-in JWT on this project —
-- and the fee app's accounts, a profile-less login and a staff member
-- deactivated an hour ago all hold one. Each could read every register, note,
-- mark, guardian snapshot and every collection link's bearer token.
--
-- This migration makes the database agree with `src/platform/auth/permissions.ts`:
--
--  1. `vppsone.role_permissions` is the permission map, as rows. Seeded here
--     from the TypeScript map; `tests/scoped-reads.test.ts` fails if the two
--     disagree, so a change to one without the other cannot ship.
--  2. Helper functions answer "is this an active staff member", "may they do
--     X" and "which classes are theirs", from `staff_profiles` and nothing else
--     (D-6: never a JWT claim, never `public.users`).
--  3. Every policy is replaced. Reference data needs an active profile; pupil
--     data needs the permission its screen needs *and* the class scope — a
--     teacher reads her own classes, the office and coordinators read all.
--  4. (The three columns that stop being readable directly — staff phones, a
--     teacher's absence reason and a collection link's token — are the next
--     migration, applied once the code that reads them differently is live.)
--  5. Role, activation and the last administrator are one command,
--     `change_staff_authority`, admin-only, audited, and serialised so two
--     simultaneous demotions cannot remove the last admin.
--
-- Additive except for the dropped `using (true)` policies, which are what is
-- being fixed. Writes still go through the service role after the app checks.

-- ------------------------------------------------------------------ school date

create or replace function vppsone.school_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Kolkata')::date
$$;

comment on function vppsone.school_today() is
  'Today in Amet. Postgres runs in UTC, and 00:00-05:30 UTC is still yesterday at school.';

-- ----------------------------------------------------------- the permission map

create table vppsone.role_permissions (
  role vppsone.staff_role not null,
  permission text not null,
  primary key (role, permission),
  constraint role_permissions_shape check (permission ~ '^[a-z_]+:[a-z_]+$')
);

comment on table vppsone.role_permissions is
  'src/platform/auth/permissions.ts as rows, so a policy can ask the same question the app does. tests/scoped-reads.test.ts keeps them equal.';

insert into vppsone.role_permissions (role, permission) values
  ('admin', 'dashboard:view'),
  ('admin', 'staff:view'),
  ('admin', 'staff:manage'),
  ('admin', 'academics:view'),
  ('admin', 'academics:manage'),
  ('admin', 'timetable:view'),
  ('admin', 'timetable:manage'),
  ('admin', 'substitutions:view'),
  ('admin', 'substitutions:manage'),
  ('admin', 'attendance:view'),
  ('admin', 'attendance:mark'),
  ('admin', 'attendance:mark_on_behalf'),
  ('admin', 'attendance:correct'),
  ('admin', 'notes:view'),
  ('admin', 'notes:write'),
  ('admin', 'collection:view'),
  ('admin', 'collection:manage'),
  ('admin', 'documents:view'),
  ('admin', 'documents:manage'),
  ('admin', 'assessments:view'),
  ('admin', 'assessments:manage'),
  ('admin', 'marks:view'),
  ('admin', 'marks:write'),
  ('admin', 'reports:view'),
  ('admin', 'students:view'),
  ('admin', 'apps:view'),
  ('admin', 'fees:view'),
  ('admin', 'fees:collect'),
  ('admin', 'fees:manage'),
  ('admin', 'jobs:view'),
  ('admin', 'jobs:run'),
  ('admin', 'audit:view'),
  ('office', 'dashboard:view'),
  ('office', 'staff:view'),
  ('office', 'staff:manage'),
  ('office', 'academics:view'),
  ('office', 'academics:manage'),
  ('office', 'timetable:view'),
  ('office', 'substitutions:view'),
  ('office', 'attendance:view'),
  ('office', 'attendance:mark_on_behalf'),
  ('office', 'attendance:correct'),
  ('office', 'notes:view'),
  ('office', 'collection:view'),
  ('office', 'collection:manage'),
  ('office', 'documents:view'),
  ('office', 'documents:manage'),
  ('office', 'assessments:view'),
  ('office', 'marks:view'),
  ('office', 'reports:view'),
  ('office', 'apps:view'),
  ('office', 'students:view'),
  ('office', 'fees:view'),
  ('accountant', 'dashboard:view'),
  ('accountant', 'fees:view'),
  ('accountant', 'fees:collect'),
  ('fee_collector', 'dashboard:view'),
  ('fee_collector', 'fees:view'),
  ('academic_coordinator', 'dashboard:view'),
  ('academic_coordinator', 'staff:view'),
  ('academic_coordinator', 'academics:view'),
  ('academic_coordinator', 'academics:manage'),
  ('academic_coordinator', 'timetable:view'),
  ('academic_coordinator', 'timetable:manage'),
  ('academic_coordinator', 'substitutions:view'),
  ('academic_coordinator', 'substitutions:manage'),
  ('academic_coordinator', 'attendance:view'),
  ('academic_coordinator', 'notes:view'),
  ('academic_coordinator', 'assessments:view'),
  ('academic_coordinator', 'marks:view'),
  ('academic_coordinator', 'reports:view'),
  ('exam_coordinator', 'dashboard:view'),
  ('exam_coordinator', 'staff:view'),
  ('exam_coordinator', 'academics:view'),
  ('exam_coordinator', 'timetable:view'),
  ('exam_coordinator', 'attendance:view'),
  ('exam_coordinator', 'assessments:view'),
  ('exam_coordinator', 'assessments:manage'),
  ('exam_coordinator', 'marks:view'),
  ('exam_coordinator', 'marks:write'),
  ('exam_coordinator', 'reports:view'),
  ('teacher', 'dashboard:view'),
  ('teacher', 'timetable:view'),
  ('teacher', 'substitutions:view'),
  ('teacher', 'attendance:view'),
  ('teacher', 'attendance:mark'),
  ('teacher', 'notes:view'),
  ('teacher', 'notes:write'),
  ('teacher', 'assessments:view'),
  ('teacher', 'marks:view'),
  ('teacher', 'marks:write'),
  ('view_only', 'dashboard:view'),
  ('view_only', 'timetable:view');

alter table vppsone.role_permissions enable row level security;
-- Read only through the functions below; nothing needs the raw table.
revoke all on vppsone.role_permissions from authenticated;
grant all on vppsone.role_permissions to service_role;

-- ------------------------------------------------------------- who is asking

create or replace function vppsone.current_staff_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select sp.id
  from vppsone.staff_profiles sp
  where sp.user_id = (select auth.uid()) and sp.is_active
$$;

create or replace function vppsone.is_active_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select vppsone.current_staff_profile_id() is not null
$$;

create or replace function vppsone.staff_can(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.user_id = (select auth.uid())
      and sp.is_active
      and rp.permission = p_permission
  )
$$;

create or replace function vppsone.staff_can_any(p_permissions text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.user_id = (select auth.uid())
      and sp.is_active
      and rp.permission = any (p_permissions)
  )
$$;

/*
 * Whose job is every class. Mirrors `readsEveryClass()` in permissions.ts:
 * the office and the administrator run the school, the two coordinators
 * oversee it. A teacher is not on this list — her classes are her own.
 */
create or replace function vppsone.reads_every_class()
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
      and sp.role in ('admin', 'office', 'academic_coordinator', 'exam_coordinator')
  )
$$;

/*
 * The classes that are this person's, as `class_id|session_label` keys.
 *
 * Class teacher over the whole effective interval, not only `effective_to is
 * null`: a teacher handed a class from next Monday is not its teacher today,
 * and one replaced today still is until tonight. Plus every class the
 * published timetable has them teaching. A cover duty is deliberately not a
 * source: covering a period gives no right to the class's records (PLAN P1).
 */
create or replace function vppsone.my_class_keys()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select vppsone.current_staff_profile_id() as id)
  select coalesce(array_agg(distinct k), '{}'::text[])
  from (
    select ct.class_id::text || '|' || ct.session_label as k
    from vppsone.class_teachers ct, me
    where ct.staff_profile_id = me.id
      and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
      and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
    union
    select ta.class_id::text || '|' || ta.session_label
    from vppsone.teaching_assignments ta, me
    where ta.staff_profile_id = me.id
  ) keys
$$;

revoke all on function vppsone.current_staff_profile_id() from public;
revoke all on function vppsone.is_active_staff() from public;
revoke all on function vppsone.staff_can(text) from public;
revoke all on function vppsone.staff_can_any(text[]) from public;
revoke all on function vppsone.reads_every_class() from public;
revoke all on function vppsone.my_class_keys() from public;
grant execute on function vppsone.current_staff_profile_id() to authenticated, service_role;
grant execute on function vppsone.is_active_staff() to authenticated, service_role;
grant execute on function vppsone.staff_can(text) to authenticated, service_role;
grant execute on function vppsone.staff_can_any(text[]) to authenticated, service_role;
grant execute on function vppsone.reads_every_class() to authenticated, service_role;
grant execute on function vppsone.my_class_keys() to authenticated, service_role;
grant execute on function vppsone.school_today() to authenticated, service_role;

-- --------------------------------------------------- drop every using (true)

do $$
declare
  p record;
begin
  for p in
    select tablename, policyname
    from pg_policies
    where schemaname = 'vppsone' and cmd = 'SELECT' and qual = 'true'
  loop
    execute format('drop policy %I on vppsone.%I', p.policyname, p.tablename);
  end loop;
end
$$;

-- ------------------------------------------- reference data: any active staff
--
-- Timetables, subjects, the calendar, who teaches what, cover policies and
-- plans. No child is named in any of these.

do $$
declare
  t text;
begin
  foreach t in array array[
    'subjects', 'class_aliases', 'class_teachers', 'academic_calendar_days',
    'timetable_versions', 'timetable_slots', 'teaching_assignments',
    'note_kinds', 'cover_policies', 'teacher_absences', 'substitution_plans',
    'substitution_assignments', 'collection_fields', 'message_templates',
    'assessments', 'assessment_subjects', 'staff_scopes', 'data_replica'
  ]
  loop
    execute format(
      'create policy %I on vppsone.%I for select to authenticated using ((select vppsone.is_active_staff()))',
      t || '_select_active_staff', t
    );
  end loop;
end
$$;

-- A profile row is readable by its own login even when inactive, so the sign-in
-- screen can say "your account is switched off" rather than "no account".
create policy staff_profiles_select_active_staff
  on vppsone.staff_profiles for select to authenticated
  using (user_id = (select auth.uid()) or (select vppsone.is_active_staff()));

-- --------------------------------------------- pupil data: permission + class

create policy enrolments_select_scoped
  on vppsone.enrolments for select to authenticated
  using (
    (select vppsone.staff_can_any(array[
      'attendance:view', 'students:view', 'reports:view', 'collection:view',
      'marks:view', 'documents:view'
    ]))
    and (
      (select vppsone.reads_every_class())
      or (class_id::text || '|' || session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
    )
  );

create policy attendance_registers_select_scoped
  on vppsone.attendance_registers for select to authenticated
  using (
    (select vppsone.staff_can('attendance:view'))
    and (
      (select vppsone.reads_every_class())
      or (class_id::text || '|' || session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
    )
  );

-- A mark is visible when its register is: the subquery is itself under the
-- register policy above.
create policy attendance_marks_select_scoped
  on vppsone.attendance_marks for select to authenticated
  using (
    exists (select 1 from vppsone.attendance_registers r where r.id = register_id)
  );

create policy attendance_corrections_select_scoped
  on vppsone.attendance_corrections for select to authenticated
  using (
    requested_by = (select vppsone.current_staff_profile_id())
    or exists (select 1 from vppsone.attendance_registers r where r.id = register_id)
  );

-- Mirrors canReadNote(): the office and admin follow up on every concern;
-- anybody else reads what they wrote and what is about their own classes.
create policy notes_select_scoped
  on vppsone.notes for select to authenticated
  using (
    (select vppsone.staff_can('notes:view'))
    and (
      (select vppsone.staff_can('attendance:correct'))
      or written_by = (select vppsone.current_staff_profile_id())
      or (
        class_id is not null
        and (class_id::text || '|' || session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
      )
    )
  );

create policy marks_select_scoped
  on vppsone.marks for select to authenticated
  using (
    (select vppsone.staff_can('marks:view'))
    and exists (
      select 1
      from vppsone.assessment_subjects s
      join vppsone.assessments a on a.id = s.assessment_id
      where s.id = assessment_subject_id
        and (
          (select vppsone.reads_every_class())
          or (s.class_id::text || '|' || a.session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
        )
    )
  );

create policy marks_change_log_select_scoped
  on vppsone.marks_change_log for select to authenticated
  using (
    (select vppsone.staff_can('marks:view'))
    and exists (
      select 1
      from vppsone.assessment_subjects s
      join vppsone.assessments a on a.id = s.assessment_id
      where s.id = assessment_subject_id
        and (
          (select vppsone.reads_every_class())
          or (s.class_id::text || '|' || a.session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
        )
    )
  );

-- A child is in scope when one of their enrolments is visible — which the
-- enrolments policy has already decided.
create policy report_cards_select_scoped
  on vppsone.report_cards for select to authenticated
  using (
    (select vppsone.staff_can('reports:view'))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e
        where e.student_id = report_cards.student_id
          and e.session_label = report_cards.session_label
      )
    )
  );

create policy academic_exports_select_scoped
  on vppsone.academic_exports for select to authenticated
  using ((select vppsone.staff_can('reports:view')));

create policy student_records_select_scoped
  on vppsone.student_records for select to authenticated
  using (
    (select vppsone.staff_can_any(array[
      'collection:view', 'documents:view', 'students:view', 'attendance:view'
    ]))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e
        where e.student_id = student_records.student_id
          and e.session_label = student_records.session_label
      )
    )
  );

create policy student_documents_select_scoped
  on vppsone.student_documents for select to authenticated
  using (
    (select vppsone.staff_can('documents:view'))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e
        where e.student_id = student_documents.student_id
          and e.session_label = student_documents.session_label
      )
    )
  );

create policy external_student_ids_select_scoped
  on vppsone.external_student_ids for select to authenticated
  using (
    (select vppsone.staff_can_any(array['students:view', 'collection:view', 'attendance:view']))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e where e.student_id = external_student_ids.student_id
      )
    )
  );

-- ------------------------------------------------- collection: office + owner

create policy collection_rounds_select_scoped
  on vppsone.collection_rounds for select to authenticated
  using ((select vppsone.staff_can('collection:view')));

create policy collection_round_fields_select_scoped
  on vppsone.collection_round_fields for select to authenticated
  using ((select vppsone.staff_can('collection:view')));

create policy collection_requests_select_scoped
  on vppsone.collection_requests for select to authenticated
  using (
    (select vppsone.staff_can('collection:view'))
    or assigned_staff_id = (select vppsone.current_staff_profile_id())
  );

create policy collection_request_fields_select_scoped
  on vppsone.collection_request_fields for select to authenticated
  using (exists (select 1 from vppsone.collection_requests r where r.id = request_id));

create policy collection_request_members_select_scoped
  on vppsone.collection_request_members for select to authenticated
  using (exists (select 1 from vppsone.collection_requests r where r.id = request_id));

create policy collection_submissions_select_scoped
  on vppsone.collection_submissions for select to authenticated
  using (exists (select 1 from vppsone.collection_requests r where r.id = request_id));

create policy message_sends_select_scoped
  on vppsone.message_sends for select to authenticated
  using ((select vppsone.staff_can('collection:view')));

create policy job_runs_select_scoped
  on vppsone.job_runs for select to authenticated
  using ((select vppsone.staff_can('jobs:view')));

-- ------------------------------------------- one authority for role and access

create table vppsone.staff_authority_changes (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  actor_staff_id uuid references vppsone.staff_profiles (id) on delete set null,
  from_role vppsone.staff_role not null,
  to_role vppsone.staff_role not null,
  from_active boolean not null,
  to_active boolean not null,
  reason text,
  changed_at timestamptz not null default now()
);

comment on table vppsone.staff_authority_changes is
  'Every change of role or activation, who made it and why. Appended by change_staff_authority(); never edited.';

create index staff_authority_changes_by_staff_idx
  on vppsone.staff_authority_changes (staff_profile_id, changed_at desc);

alter table vppsone.staff_authority_changes enable row level security;
create policy staff_authority_changes_select_scoped
  on vppsone.staff_authority_changes for select to authenticated
  using ((select vppsone.staff_can('staff:manage')));
grant select on vppsone.staff_authority_changes to authenticated;
grant all on vppsone.staff_authority_changes to service_role;

/*
 * The last active administrator cannot stop being one.
 *
 * A trigger, not only a check in the command, because the command is not the
 * only writer a future change might add — and serialised on one advisory lock,
 * because two demotions of two different admins each see the other admin as
 * still there unless one waits for the other to commit. The count runs after
 * the lock is held, so it sees the first one's result.
 */
create or replace function vppsone.staff_profiles_keep_an_admin()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  remaining integer;
begin
  if tg_op = 'DELETE' then
    if not (old.role = 'admin' and old.is_active) then
      return old;
    end if;
  elsif not (old.role = 'admin' and old.is_active)
     or (new.role = 'admin' and new.is_active) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:staff-authority'));

  select count(*) into remaining
  from vppsone.staff_profiles sp
  where sp.role = 'admin' and sp.is_active and sp.id <> old.id;

  if remaining = 0 then
    raise exception 'The school must keep at least one active administrator.'
      using errcode = 'check_violation', hint = 'last_admin';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger staff_profiles_keep_an_admin
  before update of role, is_active or delete on vppsone.staff_profiles
  for each row execute function vppsone.staff_profiles_keep_an_admin();

/*
 * Change who somebody is allowed to be. Admin only, audited, atomic.
 *
 * The app checks the actor too; this checks again, against the row as it is
 * now rather than as the page saw it, because the page may be an hour old and
 * the actor may have been demoted since. Called by the service role only.
 */
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
as $$
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

  if target.role = p_role and target.is_active = p_is_active then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;

  if target.id = actor.id then
    return jsonb_build_object('ok', false, 'reason', 'self');
  end if;

  begin
    update vppsone.staff_profiles
    set role = p_role, is_active = p_is_active
    where id = target.id;
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
$$;

revoke all on function vppsone.change_staff_authority(uuid, uuid, vppsone.staff_role, boolean, text) from public;
grant execute on function vppsone.change_staff_authority(uuid, uuid, vppsone.staff_role, boolean, text) to service_role;

-- ======================================================== migrations/20261004035559_bells_and_team_rules.sql
-- P2 (Gates B and D): when periods happen, and what a team block needs.
--
-- Two facts the timetable never held, both school policy rather than data the
-- sheet can be parsed for, both edited by whoever arranges cover:
--
--  1. `bell_schedules` — the time of each period. One current row per session,
--     versioned by `revision`, seeded with the regular profile Raj chose as the
--     editable default on 4 October (eight 40-minute periods from 08:30, a
--     break 11:10-11:30, the day ending 14:10, Asia/Kolkata). The cover command
--     refuses to arrange a period that has started, and says which bells it
--     judged that by.
--  2. `team_supervision_rules` — how many of a team block's teachers must be
--     present for it to run without help (ELGA: some number of five). With no
--     rule, any absence from a team is shown to a person and never arranged
--     automatically (src/modules/substitutions/domain/events.ts).
--
-- Additive. Nothing here touches fee data.

create table vppsone.bell_schedules (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  label text not null default 'Regular',
  /** [{"index":0,"starts":"08:30","ends":"09:10"}, ...], school wall-clock. */
  periods jsonb not null,
  revision integer not null default 1,
  is_current boolean not null default true,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bell_schedules_periods_array check (jsonb_typeof(periods) = 'array'),
  constraint bell_schedules_revision_positive check (revision > 0)
);

comment on table vppsone.bell_schedules is
  'When each period happens, per session. One current row; revision bumps on every edit so a cover plan can name the bells it was judged by.';

create unique index bell_schedules_one_current
  on vppsone.bell_schedules (session_label) where is_current;

create trigger bell_schedules_set_updated_at
  before update on vppsone.bell_schedules
  for each row execute function vppsone.set_updated_at();

alter table vppsone.bell_schedules enable row level security;
create policy bell_schedules_select_active_staff
  on vppsone.bell_schedules for select to authenticated
  using ((select vppsone.is_active_staff()));
grant select on vppsone.bell_schedules to authenticated;
grant all on vppsone.bell_schedules to service_role;

-- The regular profile for every session the school has enrolments in.
insert into vppsone.bell_schedules (session_label, label, periods)
select distinct e.session_label, 'Regular', '[
  {"index":0,"starts":"08:30","ends":"09:10"},
  {"index":1,"starts":"09:10","ends":"09:50"},
  {"index":2,"starts":"09:50","ends":"10:30"},
  {"index":3,"starts":"10:30","ends":"11:10"},
  {"index":4,"starts":"11:30","ends":"12:10"},
  {"index":5,"starts":"12:10","ends":"12:50"},
  {"index":6,"starts":"12:50","ends":"13:30"},
  {"index":7,"starts":"13:30","ends":"14:10"}
]'::jsonb
from vppsone.enrolments e
on conflict do nothing;

create table vppsone.team_supervision_rules (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  subject_code text not null,
  minimum_present smallint not null,
  note text,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint team_supervision_rules_minimum_sane check (minimum_present between 1 and 15)
);

comment on table vppsone.team_supervision_rules is
  'A school rule for a team block (ELGA): how many of its teachers must be present for it to run without help. No row means the block is unmapped and every absence from it is shown to a person.';

create unique index team_supervision_rules_unique
  on vppsone.team_supervision_rules (session_label, subject_code);

create trigger team_supervision_rules_set_updated_at
  before update on vppsone.team_supervision_rules
  for each row execute function vppsone.set_updated_at();

alter table vppsone.team_supervision_rules enable row level security;
create policy team_supervision_rules_select_active_staff
  on vppsone.team_supervision_rules for select to authenticated
  using ((select vppsone.is_active_staff()));
grant select on vppsone.team_supervision_rules to authenticated;
grant all on vppsone.team_supervision_rules to service_role;

-- ======================================================== migrations/20261004040755_atomic_cover_command.sql
-- P3 (Gate E): one atomic, versioned, idempotent absence-and-cover command.
--
-- Before this, arranging cover was five separate requests — save the absence,
-- generate (delete, insert, stamp), edit, publish — with no transaction around
-- any of them. A failure halfway left a published plan with rows missing; two
-- coordinators could interleave; publishing never checked the plan against
-- the absence that had changed since; and nobody was ever told.
--
-- Now there is one database command, `vppsone.commit_cover_command`, and it is
-- the only writer of absences, duties and notice intents. Given a logical
-- submission id, the actor and the *whole desired state* of the day's future
-- duties (which the server worked out — never the browser), it:
--
--   1. refuses an actor who may not manage cover, or a disabled command;
--   2. serialises on the day (an advisory lock), so two operators queue;
--   3. returns the stored receipt for a repeated id with the same payload,
--      and refuses the same id with a different payload;
--   4. refuses a stale plan — the day, the published timetable or the bells
--      moved since the operator looked — rather than last-write-wins;
--   5. writes the absence change with an appended revision;
--   6. re-validates every assignment against the facts as they now are
--      (active, present, not teaching, not double booked, period not begun)
--      and raises — rolling everything back — if one fails;
--   7. diffs desired against live duties: unchanged rows keep their identity
--      and are not re-announced; changed ones are superseded by a new
--      revision; vanished ones are cancelled; started periods are history and
--      are never touched;
--   8. writes the notice intents those changes need — and cancels an unsent
--      notice instead of sending a correction for it;
--   9. bumps the day's revision and stores the receipt.
--
-- All of it in the one transaction the function is. Provider calls happen
-- later, outside it (P4), and cannot undo a valid plan.
--
-- The old `substitution_plans`/`substitution_assignments` stay, read-only, as
-- history. Additive otherwise; nothing touches fee data.

-- ------------------------------------------------------------- switches

create table vppsone.runtime_flags (
  key text primary key,
  enabled boolean not null,
  note text,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint runtime_flags_key_known check (
    key in ('cover_command', 'staff_notice_dispatch', 'fault_injection', 'parent_dispatch')
  )
);

comment on table vppsone.runtime_flags is
  'Operator switches. cover_command and staff_notice_dispatch can be turned off independently (rollback without deleting evidence). fault_injection exists for the atomicity tests and is never on in production. parent_dispatch stays off: parents are approval-by-default (PLAN §14).';

insert into vppsone.runtime_flags (key, enabled, note) values
  ('cover_command', true, 'Save absence & arrange cover'),
  ('staff_notice_dispatch', false, 'Off until P4 ships its dispatcher; turned on per deployment'),
  ('fault_injection', false, 'Test-only. Turned on by hand on schoolfees-dev, never by a migration'),
  ('parent_dispatch', false, 'Parent messages are approval-only')
on conflict (key) do nothing;

alter table vppsone.runtime_flags enable row level security;
create policy runtime_flags_select_active_staff
  on vppsone.runtime_flags for select to authenticated
  using ((select vppsone.is_active_staff()));
grant select on vppsone.runtime_flags to authenticated;
grant all on vppsone.runtime_flags to service_role;

create or replace function vppsone.flag_enabled(p_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select enabled from vppsone.runtime_flags where key = p_key), false)
$$;

revoke all on function vppsone.flag_enabled(text) from public;
grant execute on function vppsone.flag_enabled(text) to authenticated, service_role;

-- ------------------------------------------------------------- the clock

/*
 * Whether cover for a period can still be arranged: it has not begun.
 *
 * By the session's current bells, in school time. A day before today never;
 * a day after today always; today by the bell. No bells at all for today means
 * nobody can say, so the answer is no — a person decides.
 * Mirrors `isArrangeable()` in src/modules/timetable/domain/bells.ts.
 */
create or replace function vppsone.cover_period_open(
  p_session_label text,
  p_day date,
  p_period integer
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_minutes integer := extract(hour from (now() at time zone 'Asia/Kolkata'))::integer * 60
                     + extract(minute from (now() at time zone 'Asia/Kolkata'))::integer;
  v_starts text;
begin
  if p_day < v_today then return false; end if;
  if p_day > v_today then return true; end if;

  select period->>'starts' into v_starts
  from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
  where b.session_label = p_session_label and b.is_current
    and (period->>'index')::integer = p_period;

  if v_starts is null then return false; end if;
  return v_minutes < split_part(v_starts, ':', 1)::integer * 60 + split_part(v_starts, ':', 2)::integer;
end;
$$;

/* When a period ends, as an instant — after it a cover notice is pointless. */
create or replace function vppsone.cover_period_ends_at(
  p_session_label text,
  p_day date,
  p_period integer
)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select ((p_day::text || ' ' || coalesce(
    (select period->>'ends'
     from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
     where b.session_label = p_session_label and b.is_current
       and (period->>'index')::integer = p_period),
    '23:59'
  ))::timestamp at time zone 'Asia/Kolkata')
$$;

revoke all on function vppsone.cover_period_open(text, date, integer) from public;
revoke all on function vppsone.cover_period_ends_at(text, date, integer) from public;
grant execute on function vppsone.cover_period_open(text, date, integer) to authenticated, service_role;
grant execute on function vppsone.cover_period_ends_at(text, date, integer) to authenticated, service_role;

-- ------------------------------------------------------------- absences

alter table vppsone.teacher_absences
  add column revision integer not null default 1,
  add column updated_by uuid references vppsone.staff_profiles (id) on delete set null;

create table vppsone.teacher_absence_history (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  day date not null,
  /** Null records the absence being cleared — they came in after all. */
  periods smallint[],
  revision integer not null,
  command_id uuid not null,
  actor_staff_id uuid references vppsone.staff_profiles (id) on delete set null,
  recorded_at timestamptz not null default now()
);

comment on table vppsone.teacher_absence_history is
  'Every change to an absence, appended by commit_cover_command. No reasons are stored: the command does not ask for one.';

create index teacher_absence_history_by_day_idx
  on vppsone.teacher_absence_history (session_label, day, staff_profile_id, revision);

alter table vppsone.teacher_absence_history enable row level security;
create policy teacher_absence_history_select_scoped
  on vppsone.teacher_absence_history for select to authenticated
  using ((select vppsone.staff_can('substitutions:manage')));
grant select on vppsone.teacher_absence_history to authenticated;
grant all on vppsone.teacher_absence_history to service_role;

-- ------------------------------------------------------------- the day

create table vppsone.cover_days (
  session_label text not null,
  day date not null,
  revision integer not null default 0,
  timetable_version_id uuid references vppsone.timetable_versions (id) on delete set null,
  bells_revision integer,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (session_label, day)
);

comment on table vppsone.cover_days is
  'One row per day cover was arranged for. revision bumps on every committed command; a command that names an older revision is stale.';

alter table vppsone.cover_days enable row level security;
create policy cover_days_select_active_staff
  on vppsone.cover_days for select to authenticated
  using ((select vppsone.is_active_staff()));
grant select on vppsone.cover_days to authenticated;
grant all on vppsone.cover_days to service_role;

-- ------------------------------------------------------------- duties

create type vppsone.cover_duty_status as enum ('assigned', 'needs_help', 'cancelled', 'superseded');

create table vppsone.cover_duties (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  day date not null,
  /** The physical lesson and what it needs (events.ts); stable across revisions. */
  need_key text not null,
  period smallint not null,
  event_kind text not null,
  class_ids uuid[] not null,
  class_labels text[] not null,
  subject_code text not null,
  absent_staff_ids uuid[] not null,
  status vppsone.cover_duty_status not null,
  covering_staff_id uuid references vppsone.staff_profiles (id) on delete restrict,
  /** Who the engine would ask, for a duty it may not assign by itself. */
  suggested_staff_id uuid references vppsone.staff_profiles (id) on delete set null,
  /** Why a person has to look: no_candidate, team_unmapped, pin_invalid, cannot_cover, … */
  reason text,
  source text not null,
  pinned boolean not null default false,
  match_tier text,
  warnings text[] not null default '{}',
  revision integer not null default 1,
  supersedes uuid references vppsone.cover_duties (id) on delete set null,
  day_revision integer not null,
  command_id uuid not null,
  created_by uuid references vppsone.staff_profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  acknowledged_at timestamptz,
  cannot_cover_at timestamptz,
  cannot_cover_note text,
  constraint cover_duties_period_in_range check (period between 0 and 15),
  constraint cover_duties_kind_known check (
    event_kind in ('ordinary', 'joint', 'parallel_cohort', 'team_block')
  ),
  constraint cover_duties_source_known check (source in ('auto', 'manual')),
  constraint cover_duties_assigned_has_teacher check (
    status <> 'assigned' or covering_staff_id is not null
  ),
  constraint cover_duties_classes_aligned check (
    cardinality(class_ids) > 0 and cardinality(class_ids) = cardinality(class_labels)
  ),
  constraint cover_duties_ended_when_done check (
    (status in ('cancelled', 'superseded')) = (ended_at is not null)
  )
);

comment on table vppsone.cover_duties is
  'One row per revision of one cover need. Live rows are assigned or needs_help; a change supersedes a row with a new revision rather than editing it, so what a teacher was told stays on record.';

-- One live row per need, and nobody in two rooms at once — across the whole
-- day, not only within one plan.
create unique index cover_duties_one_live_per_need
  on vppsone.cover_duties (session_label, day, need_key)
  where status in ('assigned', 'needs_help');
create unique index cover_duties_no_double_booking
  on vppsone.cover_duties (session_label, day, period, covering_staff_id)
  where status = 'assigned';
create index cover_duties_by_day_idx on vppsone.cover_duties (session_label, day, period);
create index cover_duties_by_teacher_idx
  on vppsone.cover_duties (covering_staff_id, day) where status = 'assigned';
create index cover_duties_by_need_idx on vppsone.cover_duties (session_label, day, need_key, revision);

alter table vppsone.cover_duties enable row level security;
create policy cover_duties_select_scoped
  on vppsone.cover_duties for select to authenticated
  using (
    (select vppsone.staff_can('substitutions:view'))
    or covering_staff_id = (select vppsone.current_staff_profile_id())
  );
grant select on vppsone.cover_duties to authenticated;
grant all on vppsone.cover_duties to service_role;

-- ------------------------------------------------------------- commands

create table vppsone.cover_commands (
  /** The logical submission id the browser minted once per form. */
  id uuid primary key,
  kind text not null,
  session_label text not null,
  day date not null,
  actor_staff_id uuid not null references vppsone.staff_profiles (id) on delete restrict,
  payload_hash text not null,
  receipt jsonb not null,
  created_at timestamptz not null default now()
);

comment on table vppsone.cover_commands is
  'Every committed cover command and the receipt it returned. A repeated id with the same payload gets this receipt back; with a different payload it is refused.';

create index cover_commands_by_day_idx on vppsone.cover_commands (session_label, day, created_at desc);

alter table vppsone.cover_commands enable row level security;
create policy cover_commands_select_scoped
  on vppsone.cover_commands for select to authenticated
  using (
    actor_staff_id = (select vppsone.current_staff_profile_id())
    or (select vppsone.staff_can('substitutions:manage'))
  );
grant select on vppsone.cover_commands to authenticated;
grant all on vppsone.cover_commands to service_role;

-- ------------------------------------------------------------- notice intents

create type vppsone.staff_notice_status as enum (
  'pending', 'cancelled', 'suppressed', 'dispatching', 'accepted', 'failed', 'unknown',
  'delivered', 'read'
);

create table vppsone.staff_notices (
  id uuid primary key default gen_random_uuid(),
  /** duty id : kind : staff — one notice per business event per person. */
  notice_key text not null,
  kind text not null,
  duty_id uuid not null references vppsone.cover_duties (id) on delete restrict,
  duty_revision integer not null,
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete restrict,
  session_label text not null,
  day date not null,
  period smallint not null,
  status vppsone.staff_notice_status not null default 'pending',
  status_reason text,
  /** After this a cover notice says nothing useful and is not sent. */
  not_after timestamptz not null,
  command_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_notices_kind_known check (
    kind in ('cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation')
  )
);

comment on table vppsone.staff_notices is
  'What a member of staff should be told about a cover duty — the intent, written in the same transaction as the duty. Attempts to send it are a separate ledger (P4).';

create unique index staff_notices_key_unique on vppsone.staff_notices (notice_key);
create index staff_notices_queue_idx on vppsone.staff_notices (status, not_after);
create index staff_notices_by_duty_idx on vppsone.staff_notices (duty_id);
create index staff_notices_by_staff_idx on vppsone.staff_notices (staff_profile_id, day);

create trigger staff_notices_set_updated_at
  before update on vppsone.staff_notices
  for each row execute function vppsone.set_updated_at();

alter table vppsone.staff_notices enable row level security;
create policy staff_notices_select_scoped
  on vppsone.staff_notices for select to authenticated
  using (
    staff_profile_id = (select vppsone.current_staff_profile_id())
    or (select vppsone.staff_can('substitutions:manage'))
  );
grant select on vppsone.staff_notices to authenticated;
grant all on vppsone.staff_notices to service_role;

-- ------------------------------------------------------------- the command

create or replace function vppsone.commit_cover_command(p_command jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_kind text := coalesce(p_command->>'kind', 'arrange');
  v_actor uuid;
  v_session text := p_command->>'session_label';
  v_day date;
  v_hash text := p_command->>'payload_hash';
  v_tt_day text := p_command->>'timetable_day';
  v_expected jsonb := coalesce(p_command->'expected', '{}'::jsonb);
  v_fault text := p_command->>'fault';
  v_desired jsonb := coalesce(p_command->'duties', '[]'::jsonb);
  v_previous vppsone.cover_commands%rowtype;
  v_day_row vppsone.cover_days%rowtype;
  v_version uuid;
  v_bells_revision integer;
  v_actor_user uuid;
  a jsonb;
  d jsonb;
  e vppsone.cover_duties%rowtype;
  v_staff uuid;
  v_periods smallint[];
  v_revision integer;
  v_problems jsonb := '[]'::jsonb;
  v_handled text[] := '{}';
  v_new_id uuid;
  v_new_revision integer;
  v_covering uuid;
  v_count_new integer := 0;
  v_count_changed integer := 0;
  v_count_cancelled integer := 0;
  v_count_unchanged integer := 0;
  v_count_skipped integer := 0;
  v_receipt jsonb;
  v_live jsonb;
  v_pairs jsonb := '[]'::jsonb;
  p jsonb;
  v_old vppsone.cover_duties%rowtype;
  v_old_status text;
begin
  begin
    v_id := (p_command->>'command_id')::uuid;
    v_actor := (p_command->>'actor_staff_id')::uuid;
    v_day := (p_command->>'day')::date;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;

  if v_id is null or v_actor is null or v_session is null or v_day is null or v_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 1. Who is asking, now — not when the page was drawn.
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  select user_id into v_actor_user from vppsone.staff_profiles where id = v_actor;

  -- 2. One command per day at a time. Different days never conflict: a
  -- teacher can only be double booked within one day.
  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || v_day::text));

  -- 3. The same submission again gets the same answer.
  select * into v_previous from vppsone.cover_commands where id = v_id;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  if not vppsone.flag_enabled('cover_command') then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- 4. Nothing has moved since the operator looked.
  insert into vppsone.cover_days (session_label, day) values (v_session, v_day)
  on conflict (session_label, day) do nothing;
  select * into v_day_row from vppsone.cover_days
  where session_label = v_session and day = v_day for update;
  select id into v_version from vppsone.timetable_versions
  where session_label = v_session and status = 'published';
  select revision into v_bells_revision from vppsone.bell_schedules
  where session_label = v_session and is_current;

  if v_day_row.revision is distinct from (v_expected->>'day_revision')::integer
     or v_version is distinct from (v_expected->>'timetable_version_id')::uuid
     or coalesce(v_bells_revision, 0) is distinct from coalesce((v_expected->>'bells_revision')::integer, 0)
  then
    return jsonb_build_object(
      'ok', false,
      'reason', 'stale',
      'current', jsonb_build_object(
        'day_revision', v_day_row.revision,
        'timetable_version_id', v_version,
        'bells_revision', coalesce(v_bells_revision, 0)
      )
    );
  end if;

  if v_version is null then
    return jsonb_build_object('ok', false, 'reason', 'no_timetable');
  end if;

  -- 5. The absence, with its history appended.
  for a in select value from jsonb_array_elements(coalesce(p_command->'absences', '[]'::jsonb))
  loop
    v_staff := (a->>'staff_profile_id')::uuid;
    if jsonb_typeof(a->'periods') = 'array' and jsonb_array_length(a->'periods') > 0 then
      select array_agg(distinct value::smallint order by value::smallint)
      into v_periods
      from jsonb_array_elements_text(a->'periods');

      insert into vppsone.teacher_absences (
        session_label, staff_profile_id, day, periods, created_by, updated_by
      ) values (v_session, v_staff, v_day, v_periods, v_actor_user, v_actor)
      on conflict (staff_profile_id, day) do update
        set periods = excluded.periods,
            session_label = excluded.session_label,
            updated_by = excluded.updated_by,
            revision = vppsone.teacher_absences.revision + 1
      returning revision into v_revision;
    else
      v_periods := null;
      v_revision := null;
      delete from vppsone.teacher_absences
      where staff_profile_id = v_staff and day = v_day
      returning revision + 1 into v_revision;
      if v_revision is null then
        continue;
      end if;
    end if;

    insert into vppsone.teacher_absence_history (
      session_label, staff_profile_id, day, periods, revision, command_id, actor_staff_id
    ) values (v_session, v_staff, v_day, v_periods, v_revision, v_id, v_actor);
  end loop;

  if v_fault = 'after_absences' and vppsone.flag_enabled('fault_injection') then
    raise exception 'cover_command:injected_fault:after_absences';
  end if;

  -- 6. Every assignment, against the facts as they now are.
  for d in select value from jsonb_array_elements(v_desired)
  loop
    if d->>'status' <> 'assigned' then continue; end if;
    v_covering := (d->>'covering_staff_id')::uuid;

    if not vppsone.cover_period_open(v_session, v_day, (d->>'period')::integer) then
      continue; -- a begun period is history; step 7 leaves it alone
    end if;

    if not exists (
      select 1 from vppsone.staff_profiles where id = v_covering and is_active
    ) then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'inactive');
    end if;

    if exists (
      select 1 from vppsone.teacher_absences ta
      where ta.staff_profile_id = v_covering and ta.day = v_day
        and (d->>'period')::smallint = any (ta.periods)
    ) then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'absent');
    end if;

    if exists (
      select 1 from vppsone.timetable_slots s
      where s.version_id = v_version and s.day = v_tt_day
        and s.period = (d->>'period')::smallint and s.staff_profile_id = v_covering
    ) then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'teaching');
    end if;

    if (
      select count(*) from jsonb_array_elements(v_desired) other
      where other->>'status' = 'assigned'
        and other->>'covering_staff_id' = d->>'covering_staff_id'
        and other->>'period' = d->>'period'
    ) > 1 then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'double_booked');
    end if;
  end loop;

  if jsonb_array_length(v_problems) > 0 then
    -- Raise, so the absence written above is rolled back with everything else.
    raise exception 'cover_command:invalid:%', v_problems::text;
  end if;

  -- 7. Desired against live, in two phases so a teacher moved from one
  -- lesson to another in the same period never collides with herself: first
  -- every row that changes is ended, then the new rows are written.
  -- Begun periods are history and are skipped.
  for e in
    select * from vppsone.cover_duties
    where session_label = v_session and day = v_day and status in ('assigned', 'needs_help')
    order by period, need_key
    for update
  loop
    v_handled := v_handled || e.need_key;
    d := null;
    select value into d from jsonb_array_elements(v_desired) where value->>'need_key' = e.need_key limit 1;

    if not vppsone.cover_period_open(v_session, v_day, e.period) then
      if d is not null then v_count_skipped := v_count_skipped + 1; end if;
      continue;
    end if;

    if d is null then
      update vppsone.cover_duties set status = 'cancelled', ended_at = now() where id = e.id;
      v_count_cancelled := v_count_cancelled + 1;
      if e.status = 'assigned' then
        perform vppsone.cover_notice_withdrawn(e, v_id);
      end if;
      continue;
    end if;

    if d->>'status' = e.status::text
       and (d->>'covering_staff_id')::uuid is not distinct from e.covering_staff_id
       and coalesce(d->>'reason', '') = coalesce(e.reason, '')
       and (select array_agg(value::uuid order by value::uuid) from jsonb_array_elements_text(d->'class_ids'))
           = (select array_agg(c order by c) from unnest(e.class_ids) c)
       and (select coalesce(array_agg(value::uuid order by value::uuid), '{}') from jsonb_array_elements_text(coalesce(d->'absent_staff_ids', '[]'::jsonb)))
           = (select coalesce(array_agg(c order by c), '{}') from unnest(e.absent_staff_ids) c)
    then
      -- Unchanged in every way anybody was told. Suggestions and warnings
      -- are working notes, refreshed in place without a new revision.
      update vppsone.cover_duties
      set suggested_staff_id = (d->>'suggested_staff_id')::uuid,
          match_tier = d->>'match_tier',
          warnings = coalesce(array(select jsonb_array_elements_text(coalesce(d->'warnings', '[]'::jsonb))), '{}')
      where id = e.id;
      v_count_unchanged := v_count_unchanged + 1;
      continue;
    end if;

    update vppsone.cover_duties set status = 'superseded', ended_at = now() where id = e.id;
    v_pairs := v_pairs || jsonb_build_object('old_id', e.id, 'old_status', e.status::text, 'desired', d);
  end loop;

  for p in select value from jsonb_array_elements(v_pairs)
  loop
    select * into v_old from vppsone.cover_duties where id = (p->>'old_id')::uuid;
    v_old_status := p->>'old_status';
    d := p->'desired';

    v_new_id := vppsone.cover_duty_insert(d, v_session, v_day, v_old.revision + 1, v_old.id, v_day_row.revision + 1, v_id, v_actor);
    v_count_changed := v_count_changed + 1;

    if v_old_status = 'assigned' and (
      d->>'status' <> 'assigned' or (d->>'covering_staff_id')::uuid <> v_old.covering_staff_id
    ) then
      perform vppsone.cover_notice_withdrawn(v_old, v_id);
    end if;

    if d->>'status' = 'assigned' then
      if v_old_status = 'assigned' and (d->>'covering_staff_id')::uuid = v_old.covering_staff_id then
        perform vppsone.cover_notice_changed(v_old, v_new_id, v_id);
      else
        perform vppsone.cover_notice_queue(v_new_id, 'cover_assigned', v_id);
      end if;
    end if;
  end loop;

  for d in select value from jsonb_array_elements(v_desired)
  loop
    if (d->>'need_key') = any (v_handled) then continue; end if;
    if not vppsone.cover_period_open(v_session, v_day, (d->>'period')::integer) then
      v_count_skipped := v_count_skipped + 1;
      continue;
    end if;

    select coalesce(max(revision), 0) + 1 into v_new_revision
    from vppsone.cover_duties
    where session_label = v_session and day = v_day and need_key = d->>'need_key';

    v_new_id := vppsone.cover_duty_insert(d, v_session, v_day, v_new_revision, null, v_day_row.revision + 1, v_id, v_actor);
    v_count_new := v_count_new + 1;
    if d->>'status' = 'assigned' then
      perform vppsone.cover_notice_queue(v_new_id, 'cover_assigned', v_id);
    end if;
  end loop;

  if v_fault = 'after_duties' and vppsone.flag_enabled('fault_injection') then
    raise exception 'cover_command:injected_fault:after_duties';
  end if;

  -- 9. The day moves on, and the receipt is kept.
  update vppsone.cover_days
  set revision = revision + 1,
      timetable_version_id = v_version,
      bells_revision = v_bells_revision,
      updated_by = v_actor,
      updated_at = now()
  where session_label = v_session and day = v_day;

  select jsonb_build_object(
    'assigned', count(*) filter (where status = 'assigned'),
    'needs_help', count(*) filter (where status = 'needs_help')
  ) into v_live
  from vppsone.cover_duties
  where session_label = v_session and day = v_day and status in ('assigned', 'needs_help');

  v_receipt := jsonb_build_object(
    'ok', true,
    'command_id', v_id,
    'kind', v_kind,
    'day', v_day,
    'day_revision', v_day_row.revision + 1,
    'assigned', (v_live->>'assigned')::integer,
    'needs_help', (v_live->>'needs_help')::integer,
    'new', v_count_new,
    'changed', v_count_changed,
    'cancelled', v_count_cancelled,
    'unchanged', v_count_unchanged,
    'skipped_started', v_count_skipped,
    'notices_queued', (
      select count(*) from vppsone.staff_notices where command_id = v_id and status = 'pending'
    ),
    'notices_withdrawn', (
      select count(*) from vppsone.staff_notices
      where status = 'cancelled' and status_reason = 'withdrawn:' || v_id::text
    ),
    'notice_recipients', (
      select count(distinct staff_profile_id) from vppsone.staff_notices
      where command_id = v_id and status = 'pending'
    ),
    'recipients_without_phone', (
      select count(distinct n.staff_profile_id)
      from vppsone.staff_notices n
      join vppsone.staff_profiles sp on sp.id = n.staff_profile_id
      where n.command_id = v_id and n.status = 'pending'
        and coalesce(nullif(sp.whatsapp_phone, ''), nullif(sp.phone, '')) is null
    ),
    'replayed', false
  );

  if v_fault = 'before_receipt' and vppsone.flag_enabled('fault_injection') then
    raise exception 'cover_command:injected_fault:before_receipt';
  end if;

  insert into vppsone.cover_commands (id, kind, session_label, day, actor_staff_id, payload_hash, receipt)
  values (v_id, v_kind, v_session, v_day, v_actor, v_hash, v_receipt);

  return v_receipt;
end;
$$;

-- --------------------------------------------- the command's three helpers

create or replace function vppsone.cover_duty_insert(
  d jsonb,
  p_session text,
  p_day date,
  p_revision integer,
  p_supersedes uuid,
  p_day_revision integer,
  p_command uuid,
  p_actor uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into vppsone.cover_duties (
    session_label, day, need_key, period, event_kind, class_ids, class_labels, subject_code,
    absent_staff_ids, status, covering_staff_id, suggested_staff_id, reason, source, pinned,
    match_tier, warnings, revision, supersedes, day_revision, command_id, created_by
  ) values (
    p_session, p_day, d->>'need_key', (d->>'period')::smallint, d->>'event_kind',
    array(select value::uuid from jsonb_array_elements_text(d->'class_ids')),
    array(select value from jsonb_array_elements_text(d->'class_labels')),
    d->>'subject_code',
    array(select value::uuid from jsonb_array_elements_text(coalesce(d->'absent_staff_ids', '[]'::jsonb))),
    (d->>'status')::vppsone.cover_duty_status,
    (d->>'covering_staff_id')::uuid,
    (d->>'suggested_staff_id')::uuid,
    d->>'reason',
    coalesce(d->>'source', 'auto'),
    coalesce((d->>'pinned')::boolean, false),
    d->>'match_tier',
    coalesce(array(select jsonb_array_elements_text(coalesce(d->'warnings', '[]'::jsonb))), '{}'),
    p_revision, p_supersedes, p_day_revision, p_command, p_actor
  )
  returning id into v_id;
  return v_id;
end;
$$;

/* Tell somebody a duty is theirs. One notice per duty row, kind and person. */
create or replace function vppsone.cover_notice_queue(p_duty uuid, p_kind text, p_command uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r vppsone.cover_duties%rowtype;
begin
  select * into r from vppsone.cover_duties where id = p_duty;
  if r.covering_staff_id is null then return; end if;
  insert into vppsone.staff_notices (
    notice_key, kind, duty_id, duty_revision, staff_profile_id, session_label, day, period,
    not_after, command_id
  ) values (
    r.id::text || ':' || p_kind || ':' || r.covering_staff_id::text,
    p_kind, r.id, r.revision, r.covering_staff_id, r.session_label, r.day, r.period,
    vppsone.cover_period_ends_at(r.session_label, r.day, r.period), p_command
  )
  on conflict (notice_key) do nothing;
end;
$$;

/*
 * A duty somebody held is no longer theirs.
 *
 * If what they were told has not been sent yet, it is simply withdrawn —
 * there is nothing to correct. If it went out, or might have (dispatching,
 * accepted, unknown), they are owed an explicit cancellation. If they were
 * never told anything, there is nothing to say.
 */
create or replace function vppsone.cover_notice_withdrawn(p_old vppsone.cover_duties, p_command uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sent boolean;
begin
  update vppsone.staff_notices
  set status = 'cancelled', status_reason = 'withdrawn:' || p_command::text
  where duty_id = p_old.id and status = 'pending';

  select exists (
    select 1 from vppsone.staff_notices
    where duty_id = p_old.id
      and kind in ('cover_assigned', 'cover_changed')
      and status in ('dispatching', 'accepted', 'unknown', 'delivered', 'read')
  ) into v_sent;

  if v_sent then
    insert into vppsone.staff_notices (
      notice_key, kind, duty_id, duty_revision, staff_profile_id, session_label, day, period,
      not_after, command_id
    ) values (
      p_old.id::text || ':cover_cancelled:' || p_old.covering_staff_id::text,
      'cover_cancelled', p_old.id, p_old.revision, p_old.covering_staff_id,
      p_old.session_label, p_old.day, p_old.period,
      vppsone.cover_period_ends_at(p_old.session_label, p_old.day, p_old.period), p_command
    )
    on conflict (notice_key) do nothing;
  end if;
end;
$$;

/* Same teacher, changed facts: a correction if they were told, else a fresh notice. */
create or replace function vppsone.cover_notice_changed(p_old vppsone.cover_duties, p_new uuid, p_command uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sent boolean;
begin
  update vppsone.staff_notices
  set status = 'cancelled', status_reason = 'withdrawn:' || p_command::text
  where duty_id = p_old.id and status = 'pending';

  select exists (
    select 1 from vppsone.staff_notices
    where duty_id = p_old.id and status in ('dispatching', 'accepted', 'unknown', 'delivered', 'read')
  ) into v_sent;

  perform vppsone.cover_notice_queue(p_new, case when v_sent then 'cover_changed' else 'cover_assigned' end, p_command);
end;
$$;

revoke all on function vppsone.commit_cover_command(jsonb) from public;
revoke all on function vppsone.cover_duty_insert(jsonb, text, date, integer, uuid, integer, uuid, uuid) from public;
revoke all on function vppsone.cover_notice_queue(uuid, text, uuid) from public;
revoke all on function vppsone.cover_notice_withdrawn(vppsone.cover_duties, uuid) from public;
revoke all on function vppsone.cover_notice_changed(vppsone.cover_duties, uuid, uuid) from public;
grant execute on function vppsone.commit_cover_command(jsonb) to service_role;
grant execute on function vppsone.cover_duty_insert(jsonb, text, date, integer, uuid, integer, uuid, uuid) to service_role;
grant execute on function vppsone.cover_notice_queue(uuid, text, uuid) to service_role;
grant execute on function vppsone.cover_notice_withdrawn(vppsone.cover_duties, uuid) to service_role;
grant execute on function vppsone.cover_notice_changed(vppsone.cover_duties, uuid, uuid) to service_role;

-- ======================================================== migrations/20261004041934_staff_notice_outbox.sql
-- P4 (Gate F): sending a staff notice, honestly.
--
-- `staff_notices` (P3) is what somebody should be told. This is the ledger of
-- trying to tell them, and the three database steps a dispatcher takes:
--
--   claim_staff_notice  — atomically take one due notice under a lease, after
--                         re-checking it against the facts *now*: the duty is
--                         still theirs, the period has not ended, they are
--                         active, they have a number. Anything that fails is
--                         suppressed with the reason, never sent stale.
--   stamp_staff_notice  — record exactly what will be sent (destination,
--                         template, language, parameters) before the provider
--                         is called, so a crash after the call still leaves
--                         evidence of what may have gone out.
--   finish_staff_notice — record the outcome. Accepted needs a provider id.
--                         A definite refusal or a rate limit may be retried,
--                         boundedly, by a new attempt that re-checks
--                         everything. A timeout, or a 2xx without an id, is
--                         Unknown: it may have been accepted, and it is never
--                         retried by the machine.
--
-- `sweep_staff_notices` ends leases nobody finished: an attempt that never
-- reached the provider goes back to the queue; one that might have is Unknown.
-- Re-sending after Unknown is a person's decision, recorded as theirs.
--
-- There is no exactly-once promise here, because WhatsApp cannot make one.

alter table vppsone.staff_notices
  add column attempts integer not null default 0,
  add column next_attempt_at timestamptz,
  add column reconciled_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column reconciled_at timestamptz;

create type vppsone.notice_attempt_state as enum (
  'claimed', 'sending', 'accepted', 'rejected', 'rate_limited', 'unknown', 'abandoned'
);

create table vppsone.staff_notice_attempts (
  id uuid primary key default gen_random_uuid(),
  notice_id uuid not null references vppsone.staff_notices (id) on delete restrict,
  attempt_no integer not null,
  state vppsone.notice_attempt_state not null default 'claimed',
  lease_owner text not null,
  lease_expires_at timestamptz not null,
  /** The number it was going to, as it was then — a later change does not rewrite history. */
  destination text not null,
  contact_version text not null,
  transport text not null,
  template_code text,
  language text,
  params jsonb,
  link text,
  policy_version text not null default 'staff-cover-v1',
  provider_message_id text,
  provider_status integer,
  error text,
  /** Set when a person authorised a re-send after Unknown. */
  authorized_by uuid references vppsone.staff_profiles (id) on delete set null,
  started_at timestamptz not null default now(),
  stamped_at timestamptz,
  finished_at timestamptz,
  constraint staff_notice_attempts_transport_known check (transport in ('mock', 'aisensy', 'disabled')),
  constraint staff_notice_attempts_no_unique unique (notice_id, attempt_no)
);

comment on table vppsone.staff_notice_attempts is
  'Every attempt to send a staff notice, with what was sent and to which number. Never edited after it finishes.';

create index staff_notice_attempts_open_idx
  on vppsone.staff_notice_attempts (lease_expires_at) where state in ('claimed', 'sending');

alter table vppsone.staff_notice_attempts enable row level security;
create policy staff_notice_attempts_select_scoped
  on vppsone.staff_notice_attempts for select to authenticated
  using ((select vppsone.staff_can('substitutions:manage')));
grant select on vppsone.staff_notice_attempts to authenticated;
grant all on vppsone.staff_notice_attempts to service_role;

/* The ten digits a staff phone is stored as, or null. */
create or replace function vppsone.staff_destination(p_staff uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select nullif(regexp_replace(coalesce(nullif(whatsapp_phone, ''), nullif(phone, ''), ''), '\D', '', 'g'), '')
  from vppsone.staff_profiles where id = p_staff
$$;

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
  v_why text;
begin
  if not vppsone.flag_enabled('staff_notice_dispatch') then
    return jsonb_build_object('claimed', false, 'reason', 'disabled');
  end if;

  for n in
    select * from vppsone.staff_notices
    where (p_notice_id is null or id = p_notice_id)
      and (
        status = 'pending'
        or (status = 'failed' and next_attempt_at is not null and next_attempt_at <= now())
      )
    order by not_after, created_at
    limit 20
    for update skip locked
  loop
    select * into d from vppsone.cover_duties where id = n.duty_id;
    select * into s from vppsone.staff_profiles where id = n.staff_profile_id;
    v_destination := vppsone.staff_destination(n.staff_profile_id);
    v_why := null;

    if now() >= n.not_after then
      v_why := 'too_late';
    elsif not s.is_active then
      v_why := 'inactive';
    elsif n.kind in ('cover_assigned', 'cover_changed')
      and (d.status <> 'assigned' or d.covering_staff_id is distinct from n.staff_profile_id) then
      v_why := 'duty_changed';
    elsif n.kind = 'cover_cancelled' and d.status in ('assigned', 'needs_help')
      and d.covering_staff_id = n.staff_profile_id then
      v_why := 'duty_restored';
    elsif n.kind = 'cover_escalation' and (d.status <> 'assigned' or d.cannot_cover_at is null) then
      -- Somebody already reassigned it, or the refusal was withdrawn.
      v_why := 'resolved';
    elsif v_destination is null or length(v_destination) < 10 then
      v_why := 'no_phone';
    end if;

    if v_why is not null then
      update vppsone.staff_notices set status = 'suppressed', status_reason = v_why where id = n.id;
      continue;
    end if;

    insert into vppsone.staff_notice_attempts (
      notice_id, attempt_no, lease_owner, lease_expires_at, destination, contact_version, transport
    ) values (
      n.id, n.attempts + 1, p_worker, now() + make_interval(secs => p_lease_seconds),
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
        'attempt_no', n.attempts + 1, 'not_after', n.not_after
      ),
      'duty', jsonb_build_object(
        'id', d.id, 'class_labels', d.class_labels, 'subject_code', d.subject_code,
        'period', d.period, 'day', d.day, 'revision', d.revision, 'status', d.status
      ),
      'staff', jsonb_build_object(
        'id', s.id, 'display_name', s.display_name, 'language', s.preferred_language
      ),
      'destination', right(v_destination, 10)
    );
  end loop;

  return jsonb_build_object('claimed', false, 'reason', 'empty');
end;
$$;

create or replace function vppsone.stamp_staff_notice(
  p_attempt uuid,
  p_worker text,
  p_template text,
  p_language text,
  p_params jsonb,
  p_link text
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update vppsone.staff_notice_attempts
  set state = 'sending', template_code = p_template, language = p_language,
      params = p_params, link = p_link, stamped_at = now()
  where id = p_attempt and state = 'claimed' and lease_owner = p_worker and lease_expires_at > now();
  return found;
end;
$$;

create or replace function vppsone.finish_staff_notice(
  p_attempt uuid,
  p_worker text,
  p_outcome text,
  p_provider_message_id text,
  p_provider_status integer,
  p_error text
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
  v_state vppsone.notice_attempt_state;
  v_notice vppsone.staff_notice_status;
  v_next timestamptz;
begin
  select * into a from vppsone.staff_notice_attempts where id = p_attempt for update;
  if not found or a.state <> 'sending' or a.lease_owner <> p_worker then
    -- Already settled by the sweeper or another worker: the first word stands.
    return jsonb_build_object('recorded', false);
  end if;
  select * into n from vppsone.staff_notices where id = a.notice_id for update;

  v_state := case p_outcome
    when 'accepted' then 'accepted'
    when 'rejected' then 'rejected'
    when 'rate_limited' then 'rate_limited'
    else 'unknown'
  end::vppsone.notice_attempt_state;

  -- Accepted only with the provider's receipt id; a 2xx without one is Unknown.
  if v_state = 'accepted' and coalesce(p_provider_message_id, '') = '' then
    v_state := 'unknown';
  end if;

  if v_state = 'accepted' then
    v_notice := 'accepted';
  elsif v_state = 'unknown' then
    v_notice := 'unknown';
  else
    v_notice := 'failed';
    -- Bounded retry, only while the notice still means something.
    if (v_state = 'rate_limited' or coalesce(p_provider_status, 0) >= 500) and n.attempts < 3 then
      v_next := now() + make_interval(mins => case n.attempts when 1 then 1 when 2 then 5 else 15 end);
      if v_next >= n.not_after then v_next := null; end if;
    end if;
  end if;

  update vppsone.staff_notice_attempts
  set state = v_state, provider_message_id = nullif(p_provider_message_id, ''),
      provider_status = p_provider_status, error = left(p_error, 500), finished_at = now()
  where id = a.id;

  update vppsone.staff_notices
  set status = v_notice, next_attempt_at = v_next,
      status_reason = case when v_notice = 'failed' then left(p_error, 200) else null end
  where id = n.id;

  return jsonb_build_object('recorded', true, 'notice_status', v_notice, 'retry_at', v_next);
end;
$$;

create or replace function vppsone.sweep_staff_notices()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_released integer;
  v_unknown integer;
begin
  -- Never reached the provider: safe to put back.
  with gone as (
    update vppsone.staff_notice_attempts set state = 'abandoned', finished_at = now()
    where state = 'claimed' and lease_expires_at <= now()
    returning notice_id
  )
  update vppsone.staff_notices n set status = 'pending'
  from gone where n.id = gone.notice_id and n.status = 'dispatching';
  get diagnostics v_released = row_count;

  -- Might have reached it: Unknown, and left for a person.
  with lost as (
    update vppsone.staff_notice_attempts
    set state = 'unknown', finished_at = now(), error = 'lease expired after the provider was called'
    where state = 'sending' and lease_expires_at <= now()
    returning notice_id
  )
  update vppsone.staff_notices n set status = 'unknown'
  from lost where n.id = lost.notice_id and n.status = 'dispatching';
  get diagnostics v_unknown = row_count;

  -- Pending past the point of usefulness.
  update vppsone.staff_notices set status = 'suppressed', status_reason = 'too_late'
  where status in ('pending', 'failed') and not_after <= now();

  return jsonb_build_object('released', v_released, 'unknown', v_unknown);
end;
$$;

/*
 * A person settles an Unknown or failed notice: they confirmed it arrived, or
 * they authorise one more attempt knowing it may be a duplicate.
 */
create or replace function vppsone.reconcile_staff_notice(
  p_notice uuid,
  p_actor uuid,
  p_resolution text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  n vppsone.staff_notices%rowtype;
begin
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into n from vppsone.staff_notices where id = p_notice for update;
  if not found or n.status not in ('unknown', 'failed', 'suppressed') then
    return jsonb_build_object('ok', false, 'reason', 'not_open');
  end if;

  if p_resolution = 'confirmed_received' then
    update vppsone.staff_notices
    set status = 'delivered', status_reason = 'confirmed by a person',
        reconciled_by = p_actor, reconciled_at = now()
    where id = n.id;
  elsif p_resolution = 'resend' then
    if now() >= n.not_after then
      return jsonb_build_object('ok', false, 'reason', 'too_late');
    end if;
    update vppsone.staff_notices
    set status = 'pending', next_attempt_at = null, status_reason = 'resend authorised',
        reconciled_by = p_actor, reconciled_at = now()
    where id = n.id;
  else
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function vppsone.staff_destination(uuid) from public;
revoke all on function vppsone.claim_staff_notice(text, integer, text, uuid) from public;
revoke all on function vppsone.stamp_staff_notice(uuid, text, text, text, jsonb, text) from public;
revoke all on function vppsone.finish_staff_notice(uuid, text, text, text, integer, text) from public;
revoke all on function vppsone.sweep_staff_notices() from public;
revoke all on function vppsone.reconcile_staff_notice(uuid, uuid, text) from public;
grant execute on function vppsone.staff_destination(uuid) to service_role;
grant execute on function vppsone.claim_staff_notice(text, integer, text, uuid) to service_role;
grant execute on function vppsone.stamp_staff_notice(uuid, text, text, text, jsonb, text) to service_role;
grant execute on function vppsone.finish_staff_notice(uuid, text, text, text, integer, text) to service_role;
grant execute on function vppsone.sweep_staff_notices() to service_role;
grant execute on function vppsone.reconcile_staff_notice(uuid, uuid, text) to service_role;

-- ======================================================== migrations/20261004041954_hide_phone_reason_and_token_columns.sql
-- P1, second half: three columns stop being readable straight from PostgREST.
--
--  - `staff_profiles.phone` and `whatsapp_phone`: a colleague's number is for
--    the people who keep the staff list, not for every account that can sign in.
--  - `teacher_absences.reason`: why a teacher is away is between them and the
--    person arranging cover. The new absence command does not ask for one.
--  - `collection_requests.token` and `contact_phone`: a token is the whole
--    authorization for its link (see the table comment), and any signed-in JWT
--    could list every one.
--
-- Separate from the row policies because the app read these through the cookie
-- client until the same pull request moved those reads behind a permission and
-- onto the service role. Applying this before that code is deployed breaks the
-- staff list, the cover planner and the collection list; applying it after
-- breaks nothing. Every embed in the app names only display_name, short_name and
-- preferred_language from staff_profiles, which stay readable.

-- Column privileges replace the table-wide SELECT. Every column not named here
-- is still readable under the row policy; these are read by the app through
-- the service role, after the permission that shows them.

revoke select on vppsone.staff_profiles from authenticated;
grant select (
  id, user_id, display_name, short_name, role, is_teaching, is_active,
  preferred_language, preferred_start, created_by, created_at, updated_at
) on vppsone.staff_profiles to authenticated;

revoke select on vppsone.teacher_absences from authenticated;
grant select (
  id, session_label, staff_profile_id, day, periods, created_by, created_at, updated_at,
  revision, updated_by
) on vppsone.teacher_absences to authenticated;

revoke select on vppsone.collection_requests from authenticated;
grant select (
  id, session_label, title_hi, title_en, class_id, class_label, assigned_staff_id,
  due_date, status, reason_hi, reason_en, opened_at, closed_at, created_by,
  created_at, updated_at, round_id, audience_kind, audience_label, sent_at, sent_by,
  reminded_at, reminded_by, reminder_count, archived_at, token_rotated_at
) on vppsone.collection_requests to authenticated;

-- ======================================================== migrations/20261004042207_absence_updated_by_is_not_an_embed.sql
-- teacher_absences.updated_by (added by atomic_cover_command) was a second
-- foreign key to staff_profiles. Every existing `staff_profiles!inner(...)`
-- embed on this table became ambiguous and PostgREST refused the whole select,
-- which took the cover planner down on the dev deployment for about twenty
-- minutes on 4 October. The column stays; the constraint goes — who changed an
-- absence is recorded with full integrity in teacher_absence_history.
-- The app's own embed now names its constraint as well (absences-repo.ts), so
-- neither fix depends on the other.
alter table vppsone.teacher_absences drop constraint teacher_absences_updated_by_fkey;

-- ======================================================== migrations/20261004042423_teacher_responds_to_cover.sql
-- P5 (Gate G): the teacher's side of a cover duty.
--
-- Two answers, both explicit, both idempotent, and neither one a fact about
-- the classroom:
--
--  - "Acknowledge" records that she has seen it. Not that she is in the room;
--    not that WhatsApp delivered it (PLAN §5: a blue tick is not
--    acknowledgement, and acknowledgement is not coverage).
--  - "I cannot cover" records the refusal and tells whoever arranges cover. It
--    does not free her or hand the duty to anybody: the duty stays hers until
--    a cover command reassigns it, and that command will never choose her for
--    it again (P3's exclusions).
--
-- Only the duty's current holder may answer, only while it is live and its
-- period has not ended, and only through this function — the service role
-- calls it after the page has authenticated her.

create or replace function vppsone.respond_to_cover_duty(
  p_duty uuid,
  p_staff uuid,
  p_response text,
  p_note text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  d vppsone.cover_duties%rowtype;
  v_ends timestamptz;
  v_manager record;
  v_queued integer := 0;
begin
  select * into d from vppsone.cover_duties where id = p_duty for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if d.status <> 'assigned' or d.covering_staff_id is distinct from p_staff then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'status', d.status);
  end if;

  v_ends := vppsone.cover_period_ends_at(d.session_label, d.day, d.period);
  if now() >= v_ends then
    return jsonb_build_object('ok', false, 'reason', 'over');
  end if;

  if p_response = 'acknowledge' then
    if d.acknowledged_at is null then
      update vppsone.cover_duties set acknowledged_at = now() where id = d.id;
    end if;
    return jsonb_build_object('ok', true, 'acknowledged', true);
  end if;

  if p_response = 'cannot_cover' then
    if d.cannot_cover_at is not null then
      return jsonb_build_object('ok', true, 'cannot_cover', true, 'already', true);
    end if;

    update vppsone.cover_duties
    set cannot_cover_at = now(),
        cannot_cover_note = nullif(left(btrim(coalesce(p_note, '')), 200), '')
    where id = d.id;

    -- Tell whoever arranges cover: the academic coordinators, or the
    -- administrators when there is none. One notice per person per duty.
    for v_manager in
      select sp.id
      from vppsone.staff_profiles sp
      where sp.is_active and sp.role = 'academic_coordinator'
      union
      select sp.id
      from vppsone.staff_profiles sp
      where sp.is_active and sp.role = 'admin'
        and not exists (
          select 1 from vppsone.staff_profiles c
          where c.is_active and c.role = 'academic_coordinator'
        )
    loop
      insert into vppsone.staff_notices (
        notice_key, kind, duty_id, duty_revision, staff_profile_id, session_label, day, period,
        not_after, command_id
      ) values (
        d.id::text || ':cover_escalation:' || v_manager.id::text,
        'cover_escalation', d.id, d.revision, v_manager.id, d.session_label, d.day, d.period,
        v_ends, d.command_id
      )
      on conflict (notice_key) do nothing;
      v_queued := v_queued + 1;
    end loop;

    return jsonb_build_object('ok', true, 'cannot_cover', true, 'escalated_to', v_queued);
  end if;

  return jsonb_build_object('ok', false, 'reason', 'bad_request');
end;
$$;

revoke all on function vppsone.respond_to_cover_duty(uuid, uuid, text, text) from public;
grant execute on function vppsone.respond_to_cover_duty(uuid, uuid, text, text) to service_role;

-- ======================================================== migrations/20261004044226_assign_same_teacher_pins.sql
-- P3 follow-up: a hand-picked cover for the teacher who already holds it is a pin.
--
-- The coordinator presses "Assign" on the teacher the planner already chose.
-- The diff compared only what the teacher was told — status, holder, reason,
-- classes, who is away — found it unchanged, and kept `source = 'auto',
-- pinned = false`. The screen said "Saved"; the next re-arrangement was then
-- free to move that teacher, which is exactly what pressing Assign was meant
-- to prevent.
--
-- Now the unchanged branch also carries the planner's `source` and `pinned`
-- forward, in place and without a revision (nobody is told anything new), and
-- the receipt counts it as `pinned` so the screen can say so.
--
-- Only `commit_cover_command` changes. Its grants are those of the original
-- (service_role only); `create or replace` keeps them.

create or replace function vppsone.commit_cover_command(p_command jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_kind text := coalesce(p_command->>'kind', 'arrange');
  v_actor uuid;
  v_session text := p_command->>'session_label';
  v_day date;
  v_hash text := p_command->>'payload_hash';
  v_tt_day text := p_command->>'timetable_day';
  v_expected jsonb := coalesce(p_command->'expected', '{}'::jsonb);
  v_fault text := p_command->>'fault';
  v_desired jsonb := coalesce(p_command->'duties', '[]'::jsonb);
  v_previous vppsone.cover_commands%rowtype;
  v_day_row vppsone.cover_days%rowtype;
  v_version uuid;
  v_bells_revision integer;
  v_actor_user uuid;
  a jsonb;
  d jsonb;
  e vppsone.cover_duties%rowtype;
  v_staff uuid;
  v_periods smallint[];
  v_revision integer;
  v_problems jsonb := '[]'::jsonb;
  v_handled text[] := '{}';
  v_new_id uuid;
  v_new_revision integer;
  v_covering uuid;
  v_count_new integer := 0;
  v_count_changed integer := 0;
  v_count_cancelled integer := 0;
  v_count_unchanged integer := 0;
  v_count_skipped integer := 0;
  v_count_pinned integer := 0;
  v_receipt jsonb;
  v_live jsonb;
  v_pairs jsonb := '[]'::jsonb;
  p jsonb;
  v_old vppsone.cover_duties%rowtype;
  v_old_status text;
begin
  begin
    v_id := (p_command->>'command_id')::uuid;
    v_actor := (p_command->>'actor_staff_id')::uuid;
    v_day := (p_command->>'day')::date;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;

  if v_id is null or v_actor is null or v_session is null or v_day is null or v_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 1. Who is asking, now — not when the page was drawn.
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  select user_id into v_actor_user from vppsone.staff_profiles where id = v_actor;

  -- 2. One command per day at a time. Different days never conflict: a
  -- teacher can only be double booked within one day.
  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || v_day::text));

  -- 3. The same submission again gets the same answer.
  select * into v_previous from vppsone.cover_commands where id = v_id;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  if not vppsone.flag_enabled('cover_command') then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- 4. Nothing has moved since the operator looked.
  insert into vppsone.cover_days (session_label, day) values (v_session, v_day)
  on conflict (session_label, day) do nothing;
  select * into v_day_row from vppsone.cover_days
  where session_label = v_session and day = v_day for update;
  select id into v_version from vppsone.timetable_versions
  where session_label = v_session and status = 'published';
  select revision into v_bells_revision from vppsone.bell_schedules
  where session_label = v_session and is_current;

  if v_day_row.revision is distinct from (v_expected->>'day_revision')::integer
     or v_version is distinct from (v_expected->>'timetable_version_id')::uuid
     or coalesce(v_bells_revision, 0) is distinct from coalesce((v_expected->>'bells_revision')::integer, 0)
  then
    return jsonb_build_object(
      'ok', false,
      'reason', 'stale',
      'current', jsonb_build_object(
        'day_revision', v_day_row.revision,
        'timetable_version_id', v_version,
        'bells_revision', coalesce(v_bells_revision, 0)
      )
    );
  end if;

  if v_version is null then
    return jsonb_build_object('ok', false, 'reason', 'no_timetable');
  end if;

  -- 5. The absence, with its history appended.
  for a in select value from jsonb_array_elements(coalesce(p_command->'absences', '[]'::jsonb))
  loop
    v_staff := (a->>'staff_profile_id')::uuid;
    if jsonb_typeof(a->'periods') = 'array' and jsonb_array_length(a->'periods') > 0 then
      select array_agg(distinct value::smallint order by value::smallint)
      into v_periods
      from jsonb_array_elements_text(a->'periods');

      insert into vppsone.teacher_absences (
        session_label, staff_profile_id, day, periods, created_by, updated_by
      ) values (v_session, v_staff, v_day, v_periods, v_actor_user, v_actor)
      on conflict (staff_profile_id, day) do update
        set periods = excluded.periods,
            session_label = excluded.session_label,
            updated_by = excluded.updated_by,
            revision = vppsone.teacher_absences.revision + 1
      returning revision into v_revision;
    else
      v_periods := null;
      v_revision := null;
      delete from vppsone.teacher_absences
      where staff_profile_id = v_staff and day = v_day
      returning revision + 1 into v_revision;
      if v_revision is null then
        continue;
      end if;
    end if;

    insert into vppsone.teacher_absence_history (
      session_label, staff_profile_id, day, periods, revision, command_id, actor_staff_id
    ) values (v_session, v_staff, v_day, v_periods, v_revision, v_id, v_actor);
  end loop;

  if v_fault = 'after_absences' and vppsone.flag_enabled('fault_injection') then
    raise exception 'cover_command:injected_fault:after_absences';
  end if;

  -- 6. Every assignment, against the facts as they now are.
  for d in select value from jsonb_array_elements(v_desired)
  loop
    if d->>'status' <> 'assigned' then continue; end if;
    v_covering := (d->>'covering_staff_id')::uuid;

    if not vppsone.cover_period_open(v_session, v_day, (d->>'period')::integer) then
      continue; -- a begun period is history; step 7 leaves it alone
    end if;

    if not exists (
      select 1 from vppsone.staff_profiles where id = v_covering and is_active
    ) then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'inactive');
    end if;

    if exists (
      select 1 from vppsone.teacher_absences ta
      where ta.staff_profile_id = v_covering and ta.day = v_day
        and (d->>'period')::smallint = any (ta.periods)
    ) then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'absent');
    end if;

    if exists (
      select 1 from vppsone.timetable_slots s
      where s.version_id = v_version and s.day = v_tt_day
        and s.period = (d->>'period')::smallint and s.staff_profile_id = v_covering
    ) then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'teaching');
    end if;

    if (
      select count(*) from jsonb_array_elements(v_desired) other
      where other->>'status' = 'assigned'
        and other->>'covering_staff_id' = d->>'covering_staff_id'
        and other->>'period' = d->>'period'
    ) > 1 then
      v_problems := v_problems || jsonb_build_object('need_key', d->>'need_key', 'problem', 'double_booked');
    end if;
  end loop;

  if jsonb_array_length(v_problems) > 0 then
    -- Raise, so the absence written above is rolled back with everything else.
    raise exception 'cover_command:invalid:%', v_problems::text;
  end if;

  -- 7. Desired against live, in two phases so a teacher moved from one
  -- lesson to another in the same period never collides with herself: first
  -- every row that changes is ended, then the new rows are written.
  -- Begun periods are history and are skipped.
  for e in
    select * from vppsone.cover_duties
    where session_label = v_session and day = v_day and status in ('assigned', 'needs_help')
    order by period, need_key
    for update
  loop
    v_handled := v_handled || e.need_key;
    d := null;
    select value into d from jsonb_array_elements(v_desired) where value->>'need_key' = e.need_key limit 1;

    if not vppsone.cover_period_open(v_session, v_day, e.period) then
      if d is not null then v_count_skipped := v_count_skipped + 1; end if;
      continue;
    end if;

    if d is null then
      update vppsone.cover_duties set status = 'cancelled', ended_at = now() where id = e.id;
      v_count_cancelled := v_count_cancelled + 1;
      if e.status = 'assigned' then
        perform vppsone.cover_notice_withdrawn(e, v_id);
      end if;
      continue;
    end if;

    if d->>'status' = e.status::text
       and (d->>'covering_staff_id')::uuid is not distinct from e.covering_staff_id
       and coalesce(d->>'reason', '') = coalesce(e.reason, '')
       and (select array_agg(value::uuid order by value::uuid) from jsonb_array_elements_text(d->'class_ids'))
           = (select array_agg(c order by c) from unnest(e.class_ids) c)
       and (select coalesce(array_agg(value::uuid order by value::uuid), '{}') from jsonb_array_elements_text(coalesce(d->'absent_staff_ids', '[]'::jsonb)))
           = (select coalesce(array_agg(c order by c), '{}') from unnest(e.absent_staff_ids) c)
    then
      -- Unchanged in every way anybody was told. Suggestions and warnings
      -- are working notes, refreshed in place without a new revision.
      --
      -- So is a pin: a coordinator choosing, by hand, the teacher who already
      -- has the duty changes nothing that teacher was told, but it does change
      -- what the next re-arrangement may do with it. Recorded here, in place,
      -- because a new revision would send her a notice about nothing.
      if coalesce(d->>'source', 'auto') is distinct from e.source
         or coalesce((d->>'pinned')::boolean, false) is distinct from e.pinned then
        v_count_pinned := v_count_pinned + 1;
      end if;
      update vppsone.cover_duties
      set suggested_staff_id = (d->>'suggested_staff_id')::uuid,
          match_tier = d->>'match_tier',
          warnings = coalesce(array(select jsonb_array_elements_text(coalesce(d->'warnings', '[]'::jsonb))), '{}'),
          source = coalesce(d->>'source', 'auto'),
          pinned = coalesce((d->>'pinned')::boolean, false)
      where id = e.id;
      v_count_unchanged := v_count_unchanged + 1;
      continue;
    end if;

    update vppsone.cover_duties set status = 'superseded', ended_at = now() where id = e.id;
    v_pairs := v_pairs || jsonb_build_object('old_id', e.id, 'old_status', e.status::text, 'desired', d);
  end loop;

  for p in select value from jsonb_array_elements(v_pairs)
  loop
    select * into v_old from vppsone.cover_duties where id = (p->>'old_id')::uuid;
    v_old_status := p->>'old_status';
    d := p->'desired';

    v_new_id := vppsone.cover_duty_insert(d, v_session, v_day, v_old.revision + 1, v_old.id, v_day_row.revision + 1, v_id, v_actor);
    v_count_changed := v_count_changed + 1;

    if v_old_status = 'assigned' and (
      d->>'status' <> 'assigned' or (d->>'covering_staff_id')::uuid <> v_old.covering_staff_id
    ) then
      perform vppsone.cover_notice_withdrawn(v_old, v_id);
    end if;

    if d->>'status' = 'assigned' then
      if v_old_status = 'assigned' and (d->>'covering_staff_id')::uuid = v_old.covering_staff_id then
        perform vppsone.cover_notice_changed(v_old, v_new_id, v_id);
      else
        perform vppsone.cover_notice_queue(v_new_id, 'cover_assigned', v_id);
      end if;
    end if;
  end loop;

  for d in select value from jsonb_array_elements(v_desired)
  loop
    if (d->>'need_key') = any (v_handled) then continue; end if;
    if not vppsone.cover_period_open(v_session, v_day, (d->>'period')::integer) then
      v_count_skipped := v_count_skipped + 1;
      continue;
    end if;

    select coalesce(max(revision), 0) + 1 into v_new_revision
    from vppsone.cover_duties
    where session_label = v_session and day = v_day and need_key = d->>'need_key';

    v_new_id := vppsone.cover_duty_insert(d, v_session, v_day, v_new_revision, null, v_day_row.revision + 1, v_id, v_actor);
    v_count_new := v_count_new + 1;
    if d->>'status' = 'assigned' then
      perform vppsone.cover_notice_queue(v_new_id, 'cover_assigned', v_id);
    end if;
  end loop;

  if v_fault = 'after_duties' and vppsone.flag_enabled('fault_injection') then
    raise exception 'cover_command:injected_fault:after_duties';
  end if;

  -- 9. The day moves on, and the receipt is kept.
  update vppsone.cover_days
  set revision = revision + 1,
      timetable_version_id = v_version,
      bells_revision = v_bells_revision,
      updated_by = v_actor,
      updated_at = now()
  where session_label = v_session and day = v_day;

  select jsonb_build_object(
    'assigned', count(*) filter (where status = 'assigned'),
    'needs_help', count(*) filter (where status = 'needs_help')
  ) into v_live
  from vppsone.cover_duties
  where session_label = v_session and day = v_day and status in ('assigned', 'needs_help');

  v_receipt := jsonb_build_object(
    'ok', true,
    'command_id', v_id,
    'kind', v_kind,
    'day', v_day,
    'day_revision', v_day_row.revision + 1,
    'assigned', (v_live->>'assigned')::integer,
    'needs_help', (v_live->>'needs_help')::integer,
    'new', v_count_new,
    'changed', v_count_changed,
    'cancelled', v_count_cancelled,
    'unchanged', v_count_unchanged,
    'pinned', v_count_pinned,
    'skipped_started', v_count_skipped,
    'notices_queued', (
      select count(*) from vppsone.staff_notices where command_id = v_id and status = 'pending'
    ),
    'notices_withdrawn', (
      select count(*) from vppsone.staff_notices
      where status = 'cancelled' and status_reason = 'withdrawn:' || v_id::text
    ),
    'notice_recipients', (
      select count(distinct staff_profile_id) from vppsone.staff_notices
      where command_id = v_id and status = 'pending'
    ),
    'recipients_without_phone', (
      select count(distinct n.staff_profile_id)
      from vppsone.staff_notices n
      join vppsone.staff_profiles sp on sp.id = n.staff_profile_id
      where n.command_id = v_id and n.status = 'pending'
        and coalesce(nullif(sp.whatsapp_phone, ''), nullif(sp.phone, '')) is null
    ),
    'replayed', false
  );

  if v_fault = 'before_receipt' and vppsone.flag_enabled('fault_injection') then
    raise exception 'cover_command:injected_fault:before_receipt';
  end if;

  insert into vppsone.cover_commands (id, kind, session_label, day, actor_staff_id, payload_hash, receipt)
  values (v_id, v_kind, v_session, v_day, v_actor, v_hash, v_receipt);

  return v_receipt;
end;
$$;

-- ======================================================== migrations/20261004051001_attendance_half_day_status.sql
-- P6: a child who was in school for part of the day.
--
-- Its own migration because Postgres will not let a new enum value be used in
-- the transaction that adds it, and the next migration uses it.
alter type vppsone.attendance_status add value if not exists 'half_day';
