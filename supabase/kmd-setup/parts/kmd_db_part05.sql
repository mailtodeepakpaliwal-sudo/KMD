-- KMD One database setup — kmd_db_part 5 of 11. Run in order, each once.
-- Files: 20261004124254_archive_catalogue.sql … 20261028140000_online_payment_mode.sql

-- ======================================================== migrations/20261004124254_archive_catalogue.sql
-- P11: an archive the school can find, open and prove it can restore.
--
-- Plan §16 "Archiving is accessible preservation": archives inside the app,
-- access checked before serving bytes; a manifest of counts, schema version
-- and checksums; and "test a synthetic restoration of both records and
-- documents before treating a backup as usable" — because a Supabase database
-- backup does not include Storage objects.
--
-- An archive here is a copy of every `vppsone` table (as canonical JSON, one
-- file per table) and of every object in the documents and photographs
-- buckets, written to the private `vppsone-archives` bucket with a manifest.
-- Nothing is deleted to make room: an archive is a copy. The fee app's tables
-- (`public`) are the fee app's to keep and are not in it.
--
-- A restore drill reloads each archived table into a scratch table of the
-- same shape inside one transaction and compares the reloaded rows' digest
-- with the digest the archive recorded; it re-hashes every archived object
-- and round-trips one through a scratch prefix. The drill writes nothing that
-- outlives it.

insert into storage.buckets (id, name, public, file_size_limit)
values ('vppsone-archives', 'vppsone-archives', false, 52428800)
on conflict (id) do nothing;

create table vppsone.archives (
  id uuid primary key default gen_random_uuid(),
  -- What the school calls it: "2026-27 year end", "before cutover".
  label text not null,
  session_label text not null,
  status text not null default 'building',
  manifest jsonb,
  table_count integer,
  row_count integer,
  object_count integer,
  total_bytes bigint,
  error text,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint archives_status check (status in ('building', 'ready', 'failed')),
  constraint archives_label_says check (btrim(label) <> '')
);

comment on table vppsone.archives is
  'The archive catalogue: one row per archive, its manifest of tables, rows, objects and checksums. The bytes are in the private vppsone-archives bucket.';

create table vppsone.restore_drills (
  id uuid primary key default gen_random_uuid(),
  archive_id uuid not null references vppsone.archives (id) on delete restrict,
  ok boolean not null,
  report jsonb not null,
  ran_by uuid references vppsone.staff_profiles (id) on delete restrict,
  ran_at timestamptz not null default now()
);

comment on table vppsone.restore_drills is
  'Every restore drill run against an archive and what it found. Kept: an archive is only as good as its last drill.';

alter table vppsone.archives enable row level security;
alter table vppsone.restore_drills enable row level security;
create policy archives_select_admin on vppsone.archives for select to authenticated
  using ((select vppsone.staff_can('jobs:run')));
create policy restore_drills_select_admin on vppsone.restore_drills for select to authenticated
  using ((select vppsone.staff_can('jobs:run')));
grant select on vppsone.archives, vppsone.restore_drills to authenticated;
grant all on vppsone.archives, vppsone.restore_drills to service_role;

-- ---------------------------------------------------------------------------
-- Reading a table canonically
-- ---------------------------------------------------------------------------

-- Every base table in the schema except the ones that are working state, not
-- record: rate-limit counters.
create or replace function vppsone.archive_tables()
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select t.table_name::text
  from information_schema.tables t
  where t.table_schema = 'vppsone' and t.table_type = 'BASE TABLE'
    and t.table_name not in ('rate_limits')
  order by 1;
$$;

-- One table's rows as a JSON array — each row as `to_jsonb`, ordered by its
-- own text so the same rows always make the same bytes — with their count and
-- digest, all from one statement and so one snapshot: a write landing between
-- the export and the digest cannot make a sound archive look broken.
create or replace function vppsone.archive_table_export(p_table text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
  v_count bigint;
  v_md5 text;
begin
  if p_table not in (select vppsone.archive_tables()) then
    raise exception 'not an archived table: %', p_table;
  end if;
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text), ''[]''::jsonb), count(*), '
    || 'md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')) from vppsone.%I t',
    p_table
  ) into v_rows, v_count, v_md5;
  return jsonb_build_object('rows', v_rows, 'count', v_count, 'md5', v_md5);
end;
$$;

-- The same table's count and digest, computed the way the drill computes it.
create or replace function vppsone.archive_table_digest(p_table text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count bigint;
  v_md5 text;
begin
  if p_table not in (select vppsone.archive_tables()) then
    raise exception 'not an archived table: %', p_table;
  end if;
  execute format(
    'select count(*), md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')) from vppsone.%I t',
    p_table
  ) into v_count, v_md5;
  return jsonb_build_object('rows', v_count, 'md5', v_md5);
end;
$$;

-- ---------------------------------------------------------------------------
-- The drill: reload archived rows into a scratch table and digest them
-- ---------------------------------------------------------------------------

create or replace function vppsone.restore_drill_table(p_table text, p_rows jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count bigint;
  v_md5 text;
begin
  if p_table not in (select vppsone.archive_tables()) then
    raise exception 'not an archived table: %', p_table;
  end if;
  -- Same columns and types as the table, none of its constraints, triggers or
  -- defaults; gone at the end of this transaction.
  execute 'drop table if exists pg_temp.restore_drill';
  execute format('create temp table restore_drill (like vppsone.%I) on commit drop', p_table);
  execute format(
    'insert into pg_temp.restore_drill select * from jsonb_populate_recordset(null::vppsone.%I, $1)',
    p_table
  ) using p_rows;
  execute
    'select count(*), md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')) from pg_temp.restore_drill t'
    into v_count, v_md5;
  execute 'drop table pg_temp.restore_drill';
  return jsonb_build_object('rows', v_count, 'md5', v_md5);
end;
$$;

-- The objects an archive copies: every document and photograph.
create or replace function vppsone.archive_object_listing()
returns table (bucket text, name text, size bigint, mimetype text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.bucket_id::text, o.name::text, coalesce((o.metadata->>'size')::bigint, 0), o.metadata->>'mimetype'
  from storage.objects o
  where o.bucket_id in ('vppsone-documents', 'vppsone-photos')
  order by o.bucket_id, o.name;
$$;

-- The schema's version: the latest migration applied.
create or replace function vppsone.archive_schema_version()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select max(version)::text from supabase_migrations.schema_migrations;
$$;

revoke all on function vppsone.archive_tables() from public, anon, authenticated;
revoke all on function vppsone.archive_table_export(text) from public, anon, authenticated;
revoke all on function vppsone.archive_table_digest(text) from public, anon, authenticated;
revoke all on function vppsone.restore_drill_table(text, jsonb) from public, anon, authenticated;
revoke all on function vppsone.archive_object_listing() from public, anon, authenticated;
revoke all on function vppsone.archive_schema_version() from public, anon, authenticated;
grant execute on function vppsone.archive_tables() to service_role;
grant execute on function vppsone.archive_table_export(text) to service_role;
grant execute on function vppsone.archive_table_digest(text) to service_role;
grant execute on function vppsone.restore_drill_table(text, jsonb) to service_role;
grant execute on function vppsone.archive_object_listing() to service_role;
grant execute on function vppsone.archive_schema_version() to service_role;

-- ======================================================== migrations/20261004124357_archive_rows_as_text.sql
-- P11 follow-up: archived rows travel as text, never as parsed numbers.
--
-- A JSON parser in the app turns the numeric 0.50 into 0.5, and a reloaded
-- table then digests differently from the one archived — a restore drill
-- failing on a sound archive. So the export hands its rows over as the text
-- Postgres wrote, the file is that text byte for byte, and the drill takes
-- text and parses it in Postgres.

create or replace function vppsone.archive_table_export(p_table text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
  v_count bigint;
  v_md5 text;
begin
  if p_table not in (select vppsone.archive_tables()) then
    raise exception 'not an archived table: %', p_table;
  end if;
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text), ''[]''::jsonb), count(*), '
    || 'md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')) from vppsone.%I t',
    p_table
  ) into v_rows, v_count, v_md5;
  -- `rows` is a string: the caller writes it to the file without parsing it.
  return jsonb_build_object('rows', v_rows::text, 'count', v_count, 'md5', v_md5);
end;
$$;

drop function vppsone.restore_drill_table(text, jsonb);

create or replace function vppsone.restore_drill_table(p_table text, p_rows text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count bigint;
  v_md5 text;
begin
  if p_table not in (select vppsone.archive_tables()) then
    raise exception 'not an archived table: %', p_table;
  end if;
  -- Same columns and types as the table, none of its constraints, triggers or
  -- defaults; gone at the end of this transaction.
  execute 'drop table if exists pg_temp.restore_drill';
  execute format('create temp table restore_drill (like vppsone.%I) on commit drop', p_table);
  execute format(
    'insert into pg_temp.restore_drill select * from jsonb_populate_recordset(null::vppsone.%I, $1::jsonb)',
    p_table
  ) using p_rows;
  execute
    'select count(*), md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')) from pg_temp.restore_drill t'
    into v_count, v_md5;
  execute 'drop table pg_temp.restore_drill';
  return jsonb_build_object('rows', v_count, 'md5', v_md5);
end;
$$;

revoke all on function vppsone.restore_drill_table(text, text) from public, anon, authenticated;
grant execute on function vppsone.restore_drill_table(text, text) to service_role;

-- ======================================================== migrations/20261004125936_fee_contract_fingerprints.sql
-- P12: prove, from the catalogue, that this app's work left the fee app's
-- contracts exactly as they were.
--
-- Prompt 8: "protect fee parity with source-boundary assertions … academic
-- changes cannot alter receipt/ledger paths, actor attribution, request-key
-- behaviour, reversals or fee automation. Do not call live fees to prove
-- noninterference. No migration modifies shared fee schemas/functions."
--
-- Read-only. Returns every function, trigger and index in `public` and
-- `private` with an md5 of its definition, so `verify:fee-parity` can compare
-- them with a committed baseline and name anything that moved. Reading a
-- definition is not reading fee data, and nothing here writes.

create or replace function vppsone.fee_contract_fingerprints()
returns table (kind text, name text, md5 text, definition text)
language sql
stable
security definer
set search_path = ''
as $$
  select 'function', n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         md5(pg_get_functiondef(p.oid)), pg_get_functiondef(p.oid)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and p.prokind = 'f'
  union all
  select 'trigger', n.nspname || '.' || c.relname || ':' || t.tgname,
         md5(pg_get_triggerdef(t.oid)), pg_get_triggerdef(t.oid)
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not t.tgisinternal
  union all
  select 'index', i.schemaname || '.' || i.indexname, md5(i.indexdef), i.indexdef
  from pg_indexes i
  where i.schemaname = 'public'
  order by 1, 2;
$$;

comment on function vppsone.fee_contract_fingerprints is
  'Read-only catalogue fingerprints of the fee app''s functions, triggers and indexes, for verify:fee-parity. Writes nothing.';

revoke all on function vppsone.fee_contract_fingerprints() from public, anon, authenticated;
grant execute on function vppsone.fee_contract_fingerprints() to service_role;

-- ======================================================== migrations/20261006043431_native_defaulter_recovery_refresh.sql
-- Native fee readers are authorized by active vppsone staff profiles.
-- Keep the legacy fee schema and role catalogue unchanged. The definer is
-- needed for the derived-state upsert; the native guard runs before any read
-- or write, and only authenticated callers may execute this entry point.
CREATE OR REPLACE FUNCTION vppsone.refresh_defaulter_recovery_state(p_session_label text, p_today date DEFAULT CURRENT_DATE)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rows integer := 0;
begin
  if auth.uid() is null or not vppsone.staff_can('fees:view') then
    raise exception 'Unauthorized recovery state refresh.' using errcode = '28000';
  end if;

  with latest_promises as (
    select distinct on (dc.student_id)
      dc.id as contact_id,
      dc.student_id,
      dc.session_label,
      dc.contacted_at,
      dc.snooze_until,
      (
        select sfm.family_group_id
        from public.student_family_members sfm
        where sfm.student_id = dc.student_id
          and sfm.academic_session_label = dc.session_label
        order by sfm.created_at desc
        limit 1
      ) as family_group_id,
      exists (
        select 1
        from public.receipts r
        join public.payments p
          on p.receipt_id = r.id
          and p.student_id = r.student_id
        join public.installments i
          on i.id = p.installment_id
          and i.student_id = p.student_id
        join public.classes
          on classes.id = i.class_id
          and classes.session_label = dc.session_label
        where r.student_id = dc.student_id
          and r.payment_date >= dc.contacted_at::date
      ) as paid_since_promise
    from public.defaulter_contacts dc
    where dc.session_label = p_session_label
      and dc.outcome = 'promised_pay'
      and dc.snooze_until is not null
      and (
        dc.snooze_until <= p_today
        or exists (
          select 1
          from public.receipts r
          join public.payments p
            on p.receipt_id = r.id
            and p.student_id = r.student_id
          join public.installments i
            on i.id = p.installment_id
            and i.student_id = p.student_id
          join public.classes
            on classes.id = i.class_id
            and classes.session_label = dc.session_label
          where r.student_id = dc.student_id
            and r.payment_date >= dc.contacted_at::date
        )
      )
    order by dc.student_id, dc.contacted_at desc, dc.id desc
  ),
  resolved as (
    select
      contact_id,
      student_id,
      session_label,
      family_group_id,
      case
        when paid_since_promise then 'kept'
        when snooze_until < p_today then 'broken'
        else null
      end as outcome
    from latest_promises
  ),
  upserted as (
    insert into public.defaulter_recovery_state (
      student_id,
      session_label,
      family_group_id,
      recovery_stage,
      promise_resolved_outcome,
      promise_resolved_at,
      last_resolved_contact_id,
      promise_kept_count,
      promise_broken_count
    )
    select
      resolved.student_id,
      resolved.session_label,
      resolved.family_group_id,
      case when resolved.outcome = 'broken' then 'promise_due' else 'standard' end,
      resolved.outcome,
      now(),
      resolved.contact_id,
      case when resolved.outcome = 'kept' then 1 else 0 end,
      case when resolved.outcome = 'broken' then 1 else 0 end
    from resolved
    where resolved.outcome is not null
    on conflict (student_id, session_label) do update
    set
      family_group_id = coalesce(excluded.family_group_id, defaulter_recovery_state.family_group_id),
      recovery_stage = excluded.recovery_stage,
      promise_resolved_outcome = excluded.promise_resolved_outcome,
      promise_resolved_at = case
        when defaulter_recovery_state.last_resolved_contact_id is distinct from excluded.last_resolved_contact_id
          then excluded.promise_resolved_at
        else defaulter_recovery_state.promise_resolved_at
      end,
      last_resolved_contact_id = excluded.last_resolved_contact_id,
      promise_kept_count = defaulter_recovery_state.promise_kept_count + case
        when defaulter_recovery_state.last_resolved_contact_id is distinct from excluded.last_resolved_contact_id
          and excluded.promise_resolved_outcome = 'kept'
          then 1
        else 0
      end,
      promise_broken_count = defaulter_recovery_state.promise_broken_count + case
        when defaulter_recovery_state.last_resolved_contact_id is distinct from excluded.last_resolved_contact_id
          and excluded.promise_resolved_outcome = 'broken'
          then 1
        else 0
      end
    returning 1
  )
  select count(*) into v_rows from upserted;

  return v_rows;
end;
$function$;

revoke all on function vppsone.refresh_defaulter_recovery_state(text, date) from public, anon;
grant execute on function vppsone.refresh_defaulter_recovery_state(text, date) to authenticated;

-- ======================================================== migrations/20261010100247_vx_role_permissions.sql
-- The redesigned app (docs/design-handoff) adds two screens that need their own
-- permission: Messages (send a notice to staff or families) and Settings
-- (school-wide settings and the role matrix). Rows only; additive.
-- tests/scoped-reads.test.ts reads this file alongside the authority seed.

insert into vppsone.role_permissions (role, permission) values
  ('admin', 'messages:send'),
  ('admin', 'settings:manage'),
  ('office', 'messages:send'),
  ('academic_coordinator', 'messages:send'),
  ('exam_coordinator', 'messages:send')
on conflict do nothing;

-- ======================================================== migrations/20261010102233_vx_academic_role_permissions.sql
-- The academic coordinator's attendance screen (docs/design-handoff SCREENS
-- "AcadAttendance") marks a class for a teacher on leave and approves change
-- requests from teachers (RULES C, F: "attendance oversight"). Those are the
-- two acts the office already has; the coordinator gets the same two rows.
-- Rows only; additive. tests/scoped-reads.test.ts reads this file.

insert into vppsone.role_permissions (role, permission) values
  ('academic_coordinator', 'attendance:mark_on_behalf'),
  ('academic_coordinator', 'attendance:correct')
on conflict do nothing;

-- ======================================================== migrations/20261010102401_vx_ops_modules.sql
-- P10 part 1 of the redesign (docs/design-handoff): Timetable, Messages,
-- Staff & roles, Settings. Additive only; every object in `vppsone`.
--
--  1. The role matrix becomes editable. `vppsone.role_permissions` stays the
--     one map the policies read (`staff_can`), and now the app reads it too
--     (`my_permissions`). Edits go through `set_role_permissions`, which
--     re-reads the actor, refuses anyone but an active administrator, keeps
--     the Admin column locked, never gives a teacher money, and appends every
--     change to `role_permission_changes`.
--  2. School-wide settings (profile, receipt footer) and each person's own
--     alert preferences, with an insert-only history of every settings change.
--  3. Timetable: edits waiting to be published, and teacher leave requests.
--  4. Messages: a notice sent to many people is a campaign; each recipient is
--     still one `message_sends` row (now carrying `campaign_id`). Parent
--     replies are their own inbox. Templates gain their WhatsApp category.

-- ------------------------------------------------------------- 1. role matrix

create table vppsone.role_permission_changes (
  id uuid primary key default gen_random_uuid(),
  actor_staff_id uuid not null references vppsone.staff_profiles(id) on delete restrict,
  role vppsone.staff_role not null,
  permission text not null,
  granted boolean not null,
  reason text,
  changed_at timestamptz not null default now()
);

comment on table vppsone.role_permission_changes is
  'Every change to the role matrix: who, which role, which permission, on or off. Appended by set_role_permissions(); never edited.';

alter table vppsone.role_permission_changes enable row level security;
revoke all on vppsone.role_permission_changes from anon, authenticated;
grant select, insert on vppsone.role_permission_changes to service_role;

create or replace function vppsone.my_permissions()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(rp.permission order by rp.permission), '{}'::text[])
  from vppsone.staff_profiles sp
  join vppsone.role_permissions rp on rp.role = sp.role
  where sp.user_id = (select auth.uid()) and sp.is_active
$$;

comment on function vppsone.my_permissions() is
  'The signed-in staff member''s permissions as the matrix holds them now, so can() honours an admin''s edit on the next request.';

revoke all on function vppsone.my_permissions() from public, anon;
grant execute on function vppsone.my_permissions() to authenticated, service_role;

create or replace function vppsone.set_role_permissions(
  p_actor_staff_id uuid,
  p_changes jsonb,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor vppsone.staff_profiles%rowtype;
  change jsonb;
  v_role vppsone.staff_role;
  v_permission text;
  v_granted boolean;
  v_rows integer;
  v_applied integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('vppsone:role-matrix'));

  select * into actor from vppsone.staff_profiles where id = p_actor_staff_id;
  if not found or not actor.is_active or actor.role <> 'admin' then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;

  if jsonb_typeof(p_changes) is distinct from 'array' or jsonb_array_length(p_changes) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty');
  end if;

  -- Every change is checked before any is applied: all or nothing.
  for change in select value from jsonb_array_elements(p_changes) loop
    if not (change->>'role') = any (enum_range(null::vppsone.staff_role)::text[]) then
      return jsonb_build_object('ok', false, 'reason', 'bad_role');
    end if;
    v_role := (change->>'role')::vppsone.staff_role;
    v_permission := change->>'permission';
    v_granted := (change->>'granted')::boolean;
    if v_granted is null then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    if v_role = 'admin' then
      return jsonb_build_object('ok', false, 'reason', 'admin_locked');
    end if;
    -- Only a permission the app knows: the Admin column holds every one.
    if not exists (
      select 1 from vppsone.role_permissions
      where role = 'admin' and permission = v_permission
    ) then
      return jsonb_build_object('ok', false, 'reason', 'unknown_permission');
    end if;
    if v_role = 'teacher' and v_granted and v_permission like 'fees:%' then
      return jsonb_build_object('ok', false, 'reason', 'teacher_money');
    end if;
  end loop;

  for change in select value from jsonb_array_elements(p_changes) loop
    v_role := (change->>'role')::vppsone.staff_role;
    v_permission := change->>'permission';
    v_granted := (change->>'granted')::boolean;

    if v_granted then
      insert into vppsone.role_permissions (role, permission)
      values (v_role, v_permission)
      on conflict do nothing;
    else
      delete from vppsone.role_permissions
      where role = v_role and permission = v_permission;
    end if;
    get diagnostics v_rows = row_count;

    if v_rows > 0 then
      insert into vppsone.role_permission_changes (actor_staff_id, role, permission, granted, reason)
      values (actor.id, v_role, v_permission, v_granted, nullif(btrim(coalesce(p_reason, '')), ''));
      v_applied := v_applied + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'applied', v_applied);
end;
$$;

comment on function vppsone.set_role_permissions(uuid, jsonb, text) is
  'The only writer of role_permissions after the seed. Admin only (re-read now), Admin column locked, no money for teachers, every change logged.';

revoke all on function vppsone.set_role_permissions(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function vppsone.set_role_permissions(uuid, jsonb, text) to service_role;

-- ---------------------------------------------------------------- 2. settings

create table vppsone.school_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references vppsone.staff_profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint school_settings_key_shape check (key ~ '^[a-z_]+$')
);

comment on table vppsone.school_settings is
  'School-wide settings the admin edits on Settings (profile, receipt footer). One row per key; every change is in school_settings_history.';

create table vppsone.school_settings_history (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  before jsonb,
  after jsonb not null,
  changed_by uuid references vppsone.staff_profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);

comment on table vppsone.school_settings_history is 'Every settings change, before and after. Insert-only.';

create table vppsone.staff_ui_preferences (
  staff_profile_id uuid primary key references vppsone.staff_profiles(id) on delete cascade,
  large_text boolean not null default false,
  alerts jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

comment on table vppsone.staff_ui_preferences is
  'One person''s own preferences beyond language: large text, and which WhatsApp alerts reach their phone.';

alter table vppsone.school_settings enable row level security;
alter table vppsone.school_settings_history enable row level security;
alter table vppsone.staff_ui_preferences enable row level security;
revoke all on vppsone.school_settings, vppsone.school_settings_history, vppsone.staff_ui_preferences from anon, authenticated;
grant all on vppsone.school_settings, vppsone.staff_ui_preferences to service_role;
grant select, insert on vppsone.school_settings_history to service_role;

-- --------------------------------------------------------------- 3. timetable

create table vppsone.timetable_changes (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  base_version_id uuid not null references vppsone.timetable_versions(id) on delete restrict,
  day text not null,
  period smallint not null check (period between 0 and 15),
  class_id uuid not null,
  class_label text not null,
  from_subject_code text,
  from_teacher_short_name text,
  subject_id uuid not null references vppsone.subjects(id) on delete restrict,
  subject_code text not null,
  staff_profile_id uuid not null references vppsone.staff_profiles(id) on delete restrict,
  teacher_short_name text not null,
  status text not null default 'pending' check (status in ('pending', 'published', 'discarded')),
  published_version_id uuid references vppsone.timetable_versions(id) on delete set null,
  created_by uuid not null references vppsone.staff_profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  decided_by uuid references vppsone.staff_profiles(id) on delete set null,
  decided_at timestamptz
);

comment on table vppsone.timetable_changes is
  'A period changed on the timetable screen and not yet published. Publishing copies the live version, applies every pending change and publishes the copy; teachers see nothing until then.';

create unique index timetable_changes_one_pending_per_cell
  on vppsone.timetable_changes (session_label, day, period, class_id)
  where status = 'pending';

create table vppsone.teacher_leave (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  staff_profile_id uuid not null references vppsone.staff_profiles(id) on delete restrict,
  from_day date not null,
  to_day date not null,
  span text not null default 'full' check (span in ('full', 'first_half', 'second_half')),
  note text,
  status text not null default 'asked' check (status in ('asked', 'approved', 'declined', 'cancelled')),
  requested_by uuid not null references vppsone.staff_profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  decided_by uuid references vppsone.staff_profiles(id) on delete set null,
  decided_at timestamptz,
  constraint teacher_leave_order check (to_day >= from_day),
  constraint teacher_leave_short check (to_day - from_day <= 60)
);

comment on table vppsone.teacher_leave is
  'Leave asked for or recorded. Approving turns each school day into a teacher absence through the cover command, so cover is arranged and notices are queued the usual way. The note is never put in a notice.';

alter table vppsone.timetable_changes enable row level security;
alter table vppsone.teacher_leave enable row level security;
revoke all on vppsone.timetable_changes, vppsone.teacher_leave from anon, authenticated;
grant all on vppsone.timetable_changes, vppsone.teacher_leave to service_role;

-- ---------------------------------------------------------------- 4. messages

create table vppsone.message_campaigns (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  kind text not null check (kind in ('notice', 'holiday', 'ptm', 'fee', 'result', 'staff')),
  title text not null check (length(btrim(title)) between 1 and 120),
  body_hi text,
  body_en text,
  language text not null default 'both' check (language in ('both', 'hi', 'en')),
  audience text not null check (audience in ('school', 'classes', 'staff')),
  class_ids uuid[] not null default '{}',
  audience_label text not null,
  recipient_count integer not null check (recipient_count >= 0),
  cost_paise integer not null check (cost_paise >= 0),
  status text not null default 'queued' check (status in ('queued', 'cancelled')),
  client_request_id uuid not null unique,
  created_by uuid not null references vppsone.staff_profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  cancelled_by uuid references vppsone.staff_profiles(id) on delete set null,
  cancelled_at timestamptz,
  constraint message_campaigns_has_text check (coalesce(body_hi, '') <> '' or coalesce(body_en, '') <> '')
);

comment on table vppsone.message_campaigns is
  'One notice to many people. Each recipient is a message_sends row with this campaign_id. Parent rows stop at queued: a person sends them (D-10).';

alter table vppsone.message_sends
  add column if not exists campaign_id uuid references vppsone.message_campaigns(id) on delete restrict;

create index if not exists message_sends_campaign_idx on vppsone.message_sends (campaign_id) where campaign_id is not null;

alter table vppsone.message_templates
  add column if not exists wa_category text check (wa_category in ('utility', 'marketing'));

create table vppsone.parent_replies (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  from_name text not null,
  from_phone text not null,
  student_id uuid,
  student_label text,
  campaign_id uuid references vppsone.message_campaigns(id) on delete set null,
  regarding text,
  body text not null,
  received_at timestamptz not null default now(),
  assigned_staff_id uuid references vppsone.staff_profiles(id) on delete set null,
  status text not null default 'open' check (status in ('open', 'done')),
  done_by uuid references vppsone.staff_profiles(id) on delete set null,
  done_at timestamptz
);

comment on table vppsone.parent_replies is
  'A parent''s WhatsApp reply to a notice. An answer is queued as a message_sends row for a person to send; nothing here sends.';

create table vppsone.parent_reply_answers (
  id uuid primary key default gen_random_uuid(),
  reply_id uuid not null references vppsone.parent_replies(id) on delete restrict,
  body text not null,
  message_send_id uuid references vppsone.message_sends(id) on delete set null,
  answered_by uuid not null references vppsone.staff_profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

comment on table vppsone.parent_reply_answers is 'What the school answered to a parent reply. Insert-only.';

alter table vppsone.message_campaigns enable row level security;
alter table vppsone.parent_replies enable row level security;
alter table vppsone.parent_reply_answers enable row level security;
revoke all on vppsone.message_campaigns, vppsone.parent_replies, vppsone.parent_reply_answers from anon, authenticated;
grant all on vppsone.message_campaigns, vppsone.parent_replies to service_role;
grant select, insert on vppsone.parent_reply_answers to service_role;

-- The two templates a notice is queued under: one for families, one for staff.
insert into vppsone.message_templates (code, label_hi, label_en, body_hi, body_en, variables, has_url_button, audience, is_active, sort_order, wa_category)
values
  ('vx_school_notice', 'स्कूल सूचना', 'School notice', '{{1}}', '{{1}}', array['text'], false, 'parent', true, 900, 'utility'),
  ('vx_staff_notice', 'स्टाफ़ सूचना', 'Staff notice', '{{1}}', '{{1}}', array['text'], false, 'staff', true, 901, 'utility')
on conflict (code) do nothing;

-- ======================================================== migrations/20261010102516_vx_accounts_books.sql
-- UI redesign: the accountant's books (AccHome, AccBooks, Reports, FeeSetup).
--
-- Everything here is VPPS One's own bookkeeping *about* fee rows, never a fee
-- row itself. Receipts, refunds and waivers stay in `public` and are written
-- only by the ported fee module. These tables hold what the fee app never
-- recorded: the cheque's number and where it physically is, the deposit slip
-- it went to the bank on, the bank's UPI statement and which receipt each
-- line matched, the accountant's requests to the admin, the counter queue and
-- report schedules.
--
-- Fee ids (`receipt_id`, `student_id`) are stored with no foreign key (rule 2).
-- Event tables are append-only: the latest event is the state, and a mistake
-- is corrected by a later event, never an update.

create table vppsone.acc_deposit_slips (
  id uuid primary key default gen_random_uuid(),
  slip_no text not null unique,
  bank_label text not null,
  deposited_on date not null,
  total_amount integer not null check (total_amount >= 0),
  cheque_count integer not null check (cheque_count > 0),
  note text,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

create table vppsone.acc_cheques (
  id uuid primary key default gen_random_uuid(),
  -- `public.receipts.id` of a cheque receipt. One set of details per receipt.
  receipt_id uuid not null unique,
  cheque_no text not null check (length(trim(cheque_no)) between 3 and 12),
  bank_name text not null check (length(trim(bank_name)) between 2 and 80),
  cheque_date date,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

create table vppsone.acc_cheque_events (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null,
  status text not null check (status in ('in_bag', 'deposited', 'cleared', 'bounced')),
  deposit_slip_id uuid references vppsone.acc_deposit_slips (id) on delete restrict,
  reason text,
  note text,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint acc_cheque_events_deposit_has_slip check (status <> 'deposited' or deposit_slip_id is not null),
  constraint acc_cheque_events_bounce_has_reason check (status <> 'bounced' or reason is not null)
);
create index acc_cheque_events_receipt on vppsone.acc_cheque_events (receipt_id, created_at desc);

create table vppsone.acc_upi_lines (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  txn_at timestamptz not null,
  amount integer not null check (amount > 0),
  payer text not null,
  utr text not null check (length(trim(utr)) between 6 and 30),
  bank_label text not null default 'School account',
  uploaded_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  constraint acc_upi_lines_once unique (utr, amount)
);
create index acc_upi_lines_txn on vppsone.acc_upi_lines (txn_at desc);

create table vppsone.acc_upi_events (
  id uuid primary key default gen_random_uuid(),
  line_id uuid not null references vppsone.acc_upi_lines (id) on delete restrict,
  action text not null check (action in ('match', 'unmatch', 'not_fee')),
  receipt_id uuid,
  note text,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint acc_upi_events_match_has_receipt check (action <> 'match' or receipt_id is not null)
);
create index acc_upi_events_line on vppsone.acc_upi_events (line_id, created_at desc);

create table vppsone.acc_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('late_fee_waiver', 'reversal', 'refund', 'fee_change', 'other')),
  student_id uuid,
  receipt_id uuid,
  amount integer check (amount is null or amount >= 0),
  title text not null check (length(trim(title)) between 3 and 200),
  reason text not null check (length(trim(reason)) between 3 and 1000),
  payload jsonb not null default '{}'::jsonb,
  requested_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  requested_at timestamptz not null default now(),
  reminded_at timestamptz,
  withdrawn_at timestamptz,
  decision text check (decision in ('approved', 'declined')),
  decision_note text,
  decided_by uuid references vppsone.staff_profiles (id) on delete restrict,
  decided_at timestamptz,
  constraint acc_requests_decided_together check ((decision is null) = (decided_at is null)),
  constraint acc_requests_not_both check (decision is null or withdrawn_at is null)
);
create index acc_requests_open on vppsone.acc_requests (requested_at desc) where decision is null and withdrawn_at is null;

create table vppsone.acc_counter_queue (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null,
  family_label text not null,
  note text,
  arrived_at timestamptz not null default now(),
  served_at timestamptz,
  left_at timestamptz,
  added_by uuid not null references vppsone.staff_profiles (id) on delete restrict
);
create index acc_counter_queue_waiting on vppsone.acc_counter_queue (arrived_at) where served_at is null and left_at is null;

create table vppsone.acc_reminder_pauses (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  paused boolean not null,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);
create index acc_reminder_pauses_day on vppsone.acc_reminder_pauses (day, created_at desc);

create table vppsone.acc_report_schedules (
  id uuid primary key default gen_random_uuid(),
  report_key text not null check (report_key in ('collection', 'defaulters', 'classwise', 'daybook')),
  title text not null,
  recipients text[] not null check (cardinality(recipients) > 0),
  frequency text not null check (frequency in ('daily', 'weekly', 'monthly')),
  weekday smallint check (weekday between 0 and 6),
  send_time time not null default '18:00',
  format text not null default 'pdf' check (format in ('pdf', 'excel')),
  active boolean not null default true,
  last_sent_at timestamptz,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.acc_cheques is 'Cheque number and bank for a cheque receipt in public.receipts. Not a fee row.';
comment on table vppsone.acc_cheque_events is 'Append-only: where a cheque is (in the bag, deposited, cleared, bounced). Latest event is its state.';
comment on table vppsone.acc_upi_events is 'Append-only: a bank statement UPI line matched to a receipt, unmatched, or marked not a fee.';
comment on table vppsone.acc_requests is 'An accountant asks the admin: waive a late fee, reverse a receipt, refund, change a fee. The decision is recorded here; the fee write happens in the fee module.';

do $$
declare t text;
begin
  foreach t in array array['acc_deposit_slips', 'acc_cheques', 'acc_cheque_events', 'acc_upi_lines', 'acc_upi_events',
                           'acc_requests', 'acc_counter_queue', 'acc_reminder_pauses', 'acc_report_schedules']
  loop
    execute format('alter table vppsone.%I enable row level security', t);
    execute format('create policy %I on vppsone.%I for select to authenticated using ((select vppsone.staff_can_any(array[''fees:view''])))', t || '_select_fees', t);
    execute format('grant select on vppsone.%I to authenticated', t);
    execute format('grant all on vppsone.%I to service_role', t);
  end loop;
end $$;

-- ======================================================== migrations/20261010102657_vx_people_admissions_tools.sql
-- UI P10 part 2 (People): admissions pipeline, admission details, seats,
-- promotion marks, data-quality skips and the bulk-change log.
--
-- All of it is VPPS One's own record in the `vppsone` schema. Fee tables are
-- not altered: a child's fee record is still created through the ported
-- School Fees student actions, and these tables only hold what the fee app
-- never had (an enquiry before there is a child, the Hindi spelling of a
-- name, which papers the office has seen). `student_id` columns name
-- `public.students.id` without a foreign key (rule 2, D-5).

create table vppsone.enquiries (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  -- enquiry -> visited -> form -> admitted; closed is a family that did not come.
  stage text not null default 'enquiry',
  child_name text not null,
  class_label text,
  parent_name text,
  phone text,
  notes text,
  student_id uuid,
  created_by uuid references vppsone.staff_profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  stage_changed_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint enquiries_stage check (stage in ('enquiry', 'visited', 'form', 'admitted', 'closed')),
  constraint enquiries_name check (length(btrim(child_name)) between 1 and 120),
  constraint enquiries_admitted_has_student check (stage <> 'admitted' or student_id is not null)
);
comment on table vppsone.enquiries is
  'Families asking about a seat, before there is a student record. Admitted rows point at public.students.id.';
create index enquiries_session_stage on vppsone.enquiries (session_label, stage);

create table vppsone.admission_details (
  student_id uuid primary key,
  session_label text not null,
  name_hi text,
  -- Papers the office has seen: { birth, tc, photo, aadhaar, address } -> boolean.
  docs jsonb not null default '{}'::jsonb,
  enquiry_id uuid references vppsone.enquiries (id) on delete set null,
  admitted_by uuid references vppsone.staff_profiles (id) on delete set null,
  admitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admission_details_docs_object check (jsonb_typeof(docs) = 'object')
);
comment on table vppsone.admission_details is
  'What the admissions desk records beside the fee student row: Hindi name and documents received.';

create table vppsone.class_seats (
  session_label text not null,
  class_id uuid not null,
  seats integer not null,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (session_label, class_id),
  constraint class_seats_range check (seats between 0 and 500)
);
comment on table vppsone.class_seats is
  'How many children a class can take this session. A class with no row has no limit shown.';

create table vppsone.promotion_marks (
  run_id uuid not null,
  entry_id uuid not null,
  student_id uuid not null,
  -- held: stays in the same class. leaving: leaves the roll at year end.
  kind text not null,
  note text,
  marked_by uuid references vppsone.staff_profiles (id) on delete set null,
  marked_at timestamptz not null default now(),
  primary key (run_id, entry_id),
  constraint promotion_marks_kind check (kind in ('held', 'leaving'))
);
comment on table vppsone.promotion_marks is
  'Why a promotion entry was set to skip: held back or leaving. The fee run only knows skip.';

create table vppsone.data_quality_skips (
  student_id uuid not null,
  issue text not null,
  skipped_until date not null,
  skipped_by uuid references vppsone.staff_profiles (id) on delete set null,
  skipped_at timestamptz not null default now(),
  primary key (student_id, issue),
  constraint data_quality_skips_issue check (issue in ('father_phone', 'dob', 'mother_name', 'duplicate', 'age', 'address'))
);
comment on table vppsone.data_quality_skips is
  'A data-quality item the office chose to look at later. It comes back after skipped_until.';

create table vppsone.bulk_changes (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  title text not null,
  detail jsonb not null default '{}'::jsonb,
  done_by uuid references vppsone.staff_profiles (id) on delete set null,
  done_at timestamptz not null default now(),
  constraint bulk_changes_kind check (kind in ('promote', 'promote_undo', 'import', 'merge', 'split', 'quality'))
);
comment on table vppsone.bulk_changes is
  'Append-only log of school-wide student changes, for the Student tools hub.';
create index bulk_changes_done_at on vppsone.bulk_changes (done_at desc);

-- Reads for the people who run admissions; writes go through server actions
-- that check fees:manage and use the service role.
alter table vppsone.enquiries enable row level security;
alter table vppsone.admission_details enable row level security;
alter table vppsone.class_seats enable row level security;
alter table vppsone.promotion_marks enable row level security;
alter table vppsone.data_quality_skips enable row level security;
alter table vppsone.bulk_changes enable row level security;

create policy enquiries_select_staff on vppsone.enquiries for select to authenticated
  using ((select vppsone.staff_can_any(array['fees:manage', 'students:view'])));
create policy admission_details_select_staff on vppsone.admission_details for select to authenticated
  using ((select vppsone.staff_can_any(array['fees:manage', 'students:view'])));
create policy class_seats_select_staff on vppsone.class_seats for select to authenticated
  using ((select vppsone.staff_can_any(array['fees:manage', 'students:view'])));
create policy promotion_marks_select_staff on vppsone.promotion_marks for select to authenticated
  using ((select vppsone.staff_can_any(array['fees:manage'])));
create policy data_quality_skips_select_staff on vppsone.data_quality_skips for select to authenticated
  using ((select vppsone.staff_can_any(array['fees:manage'])));
create policy bulk_changes_select_staff on vppsone.bulk_changes for select to authenticated
  using ((select vppsone.staff_can_any(array['fees:manage'])));

grant select on vppsone.enquiries, vppsone.admission_details, vppsone.class_seats,
  vppsone.promotion_marks, vppsone.data_quality_skips, vppsone.bulk_changes to authenticated;
grant all on vppsone.enquiries, vppsone.admission_details, vppsone.class_seats,
  vppsone.promotion_marks, vppsone.data_quality_skips, vppsone.bulk_changes to service_role;

-- ======================================================== migrations/20261010102709_vx_exam_office.sql
-- UI P9: the exam office — date sheet, rooms, seating, duties, question
-- papers, marks links, the results pipeline (moderation, grace, per-class
-- lock, rechecks, publishing) and class-teacher remarks.
--
-- Everything here is VPPS One's own and lives in `vppsone`. Marks are still
-- written only by `save_marks`; this adds one rule to it from the outside: a
-- class whose results are locked takes no more marks, from either app, until
-- the exam office unlocks it. That rule is a trigger, so it holds whoever
-- writes.

-- ---------------------------------------------------------------------------
-- One row of settings per exam
-- ---------------------------------------------------------------------------

create table vppsone.exam_plans (
  assessment_id uuid primary key references vppsone.assessments (id) on delete cascade,
  marks_due_on date,
  results_on date,
  ptm_at time,
  reporting_time time not null default '08:15',
  copied_from uuid references vppsone.assessments (id) on delete set null,
  datesheet_checked_at timestamptz,
  datesheet_published_at timestamptz,
  datesheet_published_by uuid references vppsone.staff_profiles (id) on delete restrict,
  grace_max numeric(4, 1) not null default 3,
  grace_subjects smallint not null default 2,
  results_publish_at timestamptz,
  results_published_at timestamptz,
  results_published_by uuid references vppsone.staff_profiles (id) on delete restrict,
  results_channels jsonb not null default '{"whatsapp": true, "ptm": true}'::jsonb,
  -- {step_key: {"at": timestamptz, "by": staff id}} for the coordinator's checklist.
  checklist jsonb not null default '{}'::jsonb,
  updated_by uuid references vppsone.staff_profiles (id) on delete restrict,
  updated_at timestamptz not null default now(),
  constraint exam_plans_grace_sane check (grace_max between 0 and 10 and grace_subjects between 0 and 5)
);
comment on table vppsone.exam_plans is
  'The exam office''s settings for one exam: marks due, results day, grace rule, publishing, and the checklist.';

-- ---------------------------------------------------------------------------
-- The date sheet: one sitting of one paper for one group of classes
-- ---------------------------------------------------------------------------

create table vppsone.exam_slots (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references vppsone.assessments (id) on delete cascade,
  -- 'pre', 'c1_5', 'c6_8', 'c9_10', 'c11_12' — the bands the date sheet is drawn in.
  group_key text not null,
  subject_label text not null,
  sits_on date not null,
  starts_at time not null,
  minutes integer not null,
  sort_order integer not null default 0,
  created_by uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint exam_slots_group_known check (group_key in ('pre', 'c1_5', 'c6_8', 'c9_10', 'c11_12')),
  constraint exam_slots_length_sane check (minutes between 15 and 240),
  constraint exam_slots_subject_present check (length(btrim(subject_label)) between 1 and 80)
);
create index exam_slots_by_exam on vppsone.exam_slots (assessment_id, sits_on, starts_at);
comment on table vppsone.exam_slots is 'The date sheet: which paper each group of classes sits, when and for how long.';

-- ---------------------------------------------------------------------------
-- Rooms, seats, invigilation duties
-- ---------------------------------------------------------------------------

create table vppsone.exam_rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  seats integer not null,
  cols smallint not null default 4,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint exam_rooms_seats_sane check (seats between 1 and 400 and cols between 1 and 12)
);
comment on table vppsone.exam_rooms is 'Rooms the school seats exams in, and how many each holds.';

create table vppsone.exam_seats (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references vppsone.assessments (id) on delete cascade,
  room_id uuid not null references vppsone.exam_rooms (id) on delete restrict,
  seat_no integer not null,
  class_id uuid not null,
  -- `public.students.id`, with no foreign key (rule 2).
  student_id uuid not null,
  created_by uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint exam_seats_one_per_child unique (assessment_id, student_id),
  constraint exam_seats_one_per_seat unique (assessment_id, room_id, seat_no)
);
comment on table vppsone.exam_seats is 'Who sits where for one exam. Rebuilt whole by the seating command.';

create table vppsone.exam_duties (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references vppsone.assessments (id) on delete cascade,
  sits_on date not null,
  room_id uuid not null references vppsone.exam_rooms (id) on delete restrict,
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_by uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint exam_duties_once unique (assessment_id, sits_on, staff_profile_id)
);
create index exam_duties_by_room on vppsone.exam_duties (assessment_id, sits_on, room_id);
comment on table vppsone.exam_duties is 'Invigilation: one teacher in one room on one exam day.';

create table vppsone.exam_question_papers (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null unique references vppsone.exam_slots (id) on delete cascade,
  setter_staff_id uuid references vppsone.staff_profiles (id) on delete restrict,
  status text not null default 'waiting',
  updated_by uuid references vppsone.staff_profiles (id) on delete restrict,
  updated_at timestamptz not null default now(),
  constraint exam_question_papers_status_known check (status in ('waiting', 'received', 'checked', 'printed'))
);
comment on table vppsone.exam_question_papers is 'Each sitting''s question paper: who sets it and how far it has got.';

-- ---------------------------------------------------------------------------
-- Marks links: one token per teacher per exam, no account needed
-- ---------------------------------------------------------------------------

create table vppsone.exam_marks_links (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references vppsone.assessments (id) on delete cascade,
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete restrict,
  token text not null unique,
  created_by uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  last_opened_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references vppsone.staff_profiles (id) on delete restrict,
  constraint exam_marks_links_token_shape check (token ~ '^[A-Za-z0-9_-]{16,64}$')
);
create unique index exam_marks_links_one_live
  on vppsone.exam_marks_links (assessment_id, staff_profile_id) where revoked_at is null;
comment on table vppsone.exam_marks_links is
  'A teacher''s marks link for one exam. It reaches only the papers the timetable gives her; save_marks checks that again.';

-- ---------------------------------------------------------------------------
-- The results pipeline
-- ---------------------------------------------------------------------------

create table vppsone.exam_class_locks (
  assessment_id uuid not null references vppsone.assessments (id) on delete cascade,
  class_id uuid not null,
  locked_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  locked_at timestamptz not null default now(),
  primary key (assessment_id, class_id)
);
comment on table vppsone.exam_class_locks is
  'A class whose results are locked for one exam. While a row is here no mark on its papers changes, from either app.';

create table vppsone.exam_moderation (
  paper_id uuid primary key references vppsone.assessment_subjects (id) on delete cascade,
  decision text not null,
  note text,
  decided_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  decided_at timestamptz not null default now(),
  constraint exam_moderation_decision_known check (decision in ('fine', 'recheck'))
);
comment on table vppsone.exam_moderation is 'The exam office''s look at a paper whose average moved a lot: fine, or sent back to recheck.';

create table vppsone.exam_grace (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references vppsone.assessment_subjects (id) on delete cascade,
  student_id uuid not null,
  grace numeric(4, 1) not null,
  applied_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  applied_at timestamptz not null default now(),
  constraint exam_grace_once unique (paper_id, student_id),
  constraint exam_grace_sane check (grace > 0 and grace <= 10)
);
comment on table vppsone.exam_grace is
  'Grace marks given to one child on one paper. Kept beside the mark, never added into it, so the card can say which is which.';

create table vppsone.exam_rechecks (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references vppsone.assessment_subjects (id) on delete cascade,
  student_id uuid not null,
  asked_by text not null,
  note text,
  status text not null default 'new',
  old_value numeric,
  new_value numeric,
  created_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  resolved_by uuid references vppsone.staff_profiles (id) on delete restrict,
  resolved_at timestamptz,
  constraint exam_rechecks_status_known check (status in ('new', 'with_teacher', 'changed', 'no_change')),
  constraint exam_rechecks_resolved_together check ((status in ('changed', 'no_change')) = (resolved_at is not null))
);
create index exam_rechecks_open on vppsone.exam_rechecks (paper_id) where resolved_at is null;
comment on table vppsone.exam_rechecks is 'A family or teacher asking for a paper to be looked at again, and what came of it.';

create table vppsone.report_card_remarks (
  session_label text not null,
  term text not null,
  student_id uuid not null,
  remark text not null,
  written_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  updated_at timestamptz not null default now(),
  primary key (session_label, term, student_id),
  constraint report_card_remarks_length check (length(btrim(remark)) between 1 and 400)
);
comment on table vppsone.report_card_remarks is 'The class teacher''s one line on each child''s card for a term.';

create table vppsone.exam_reminders (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references vppsone.assessments (id) on delete cascade,
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete restrict,
  channel text not null,
  sent_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  sent_at timestamptz not null default now(),
  constraint exam_reminders_channel_known check (channel in ('whatsapp', 'copy', 'notice'))
);
comment on table vppsone.exam_reminders is
  'Reminders to late teachers. The coordinator sends them from her own phone; this records that she did.';

-- Append-only: what happened in an exam, newest first on the coordinator's home.
create table vppsone.exam_activity (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid references vppsone.assessments (id) on delete cascade,
  kind text not null,
  text_en text not null,
  text_hi text,
  actor_staff_id uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);
create index exam_activity_recent on vppsone.exam_activity (assessment_id, created_at desc);
comment on table vppsone.exam_activity is 'What happened in an exam, in order. Never edited.';

create or replace function vppsone.exam_activity_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A cascade from a deleted exam is the one way a row leaves.
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'exam_activity is append-only';
end;
$$;

create trigger exam_activity_no_update before update or delete on vppsone.exam_activity
  for each row execute function vppsone.exam_activity_append_only();

-- ---------------------------------------------------------------------------
-- A locked class takes no marks
-- ---------------------------------------------------------------------------

create or replace function vppsone.marks_respect_class_lock()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_paper uuid := coalesce(new.assessment_subject_id, old.assessment_subject_id);
begin
  if exists (
    select 1 from vppsone.assessment_subjects s
    join vppsone.exam_class_locks l on l.assessment_id = s.assessment_id and l.class_id = s.class_id
    where s.id = v_paper
  ) then
    raise exception 'marks:paper_locked';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger marks_class_lock before insert or update or delete on vppsone.marks
  for each row execute function vppsone.marks_respect_class_lock();

create or replace function vppsone.papers_respect_class_lock()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.entry_revision is distinct from old.entry_revision and exists (
    select 1 from vppsone.exam_class_locks l
    where l.assessment_id = new.assessment_id and l.class_id = new.class_id
  ) then
    raise exception 'marks:paper_locked';
  end if;
  return new;
end;
$$;

create trigger assessment_subjects_class_lock before update on vppsone.assessment_subjects
  for each row execute function vppsone.papers_respect_class_lock();

-- ---------------------------------------------------------------------------
-- A teacher takes back her own submission, within ten minutes
-- ---------------------------------------------------------------------------

create or replace function vppsone.withdraw_marks_submission(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_paper uuid;
  v_expected integer;
  s vppsone.assessment_subjects%rowtype;
  a vppsone.assessments%rowtype;
begin
  begin
    v_actor := (p->>'actor_staff_id')::uuid;
    v_paper := (p->>'paper_id')::uuid;
    v_expected := (p->>'expected_revision')::integer;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_actor is null or v_paper is null or v_expected is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select * into s from vppsone.assessment_subjects where id = v_paper for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  select * into a from vppsone.assessments where id = s.assessment_id;
  if a.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'exam_not_open');
  end if;
  if s.entry_status <> 'submitted' then
    return jsonb_build_object('ok', false, 'reason', 'not_submitted');
  end if;
  if s.entry_revision <> v_expected then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;
  -- Only her own submission, and only while it is fresh. After that it is the
  -- exam office's to hand back (save_marks 'reopen').
  if s.submitted_by is distinct from v_actor then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if s.submitted_at < now() - interval '10 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_late');
  end if;

  update vppsone.assessment_subjects
  set entry_status = 'open', entry_revision = entry_revision + 1, submitted_by = null, submitted_at = null
  where id = v_paper;

  insert into vppsone.exam_activity (assessment_id, kind, text_en, text_hi, actor_staff_id)
  select s.assessment_id, 'withdrawn',
         sp.display_name || ' took back ' || s.class_label || ' ' || s.subject_code || ' to change it',
         sp.display_name || ' ने ' || s.class_label || ' ' || s.subject_code || ' बदलने के लिए वापस लिया',
         v_actor
  from vppsone.staff_profiles sp where sp.id = v_actor;

  return jsonb_build_object('ok', true, 'revision', s.entry_revision + 1);
end;
$$;

revoke all on function vppsone.withdraw_marks_submission(jsonb) from public;
grant execute on function vppsone.withdraw_marks_submission(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Reads: staff who can see exams see the plan; writes are the service role's,
-- after the app has checked the permission.
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'exam_plans', 'exam_slots', 'exam_rooms', 'exam_seats', 'exam_duties', 'exam_question_papers',
    'exam_class_locks', 'exam_moderation', 'exam_grace', 'exam_rechecks', 'report_card_remarks',
    'exam_reminders', 'exam_activity'
  ]
  loop
    execute format('alter table vppsone.%I enable row level security', t);
    execute format(
      'create policy %I on vppsone.%I for select to authenticated using ((select vppsone.staff_can_any(array[''assessments:view'', ''marks:view''])))',
      t || '_select_staff', t
    );
    execute format('grant select on vppsone.%I to authenticated', t);
    execute format('grant all on vppsone.%I to service_role', t);
  end loop;
end;
$$;

-- Tokens are never readable from a browser session.
alter table vppsone.exam_marks_links enable row level security;
grant all on vppsone.exam_marks_links to service_role;

-- ======================================================== migrations/20261010102940_vx_fee_desk.sql
-- VPPS One — fee desk redesign (receipts & day close, dues & calls, fee
-- reminders). Additive, vppsone only; nothing here touches `public`, and no
-- fee money is written here: receipts, payments and reversals stay in the fee
-- RPCs. Applied as six small migrations (the connector timed out on one large
-- one); this first one creates fee_call_promises, completed in
-- 20261010102952_vx_fee_call_promises_rules.sql.

create table if not exists vppsone.fee_call_promises (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  student_id uuid not null,
  kind text not null default 'pay',
  promised_on date not null,
  amount numeric(12, 2) not null default 0,
  note text,
  created_by uuid,
  created_by_name text,
  created_at timestamptz not null default now()
);

-- ======================================================== migrations/20261010102943_vx_academics_calendar.sql
-- The academic coordinator's app and the school calendar (docs/design-handoff
-- SCREENS: AcadHome, AcadProgress, AcadAttendance, Calendar). Additive, and
-- in `vppsone` only. Every table has RLS with a read policy for active staff;
-- writes go through server actions that check a permission first and use the
-- service role, like the rest of this schema.

-- ------------------------------------------------------------------ calendar

-- Events that are not a change to whether school is open. Holidays stay in
-- `academic_calendar_days`, which attendance and the timetable already read,
-- so a holiday added here closes the register too.
create table if not exists vppsone.calendar_events (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  kind text not null,
  title text not null,
  title_hi text,
  starts_on date not null,
  ends_on date not null,
  all_day boolean not null default true,
  starts_at time,
  ends_at time,
  place text,
  -- `public.classes.id`, no FK (rule 2). Empty means the whole school.
  class_ids uuid[] not null default '{}',
  details text,
  created_by uuid references vppsone.staff_profiles (id),
  created_at timestamptz not null default now(),
  updated_by uuid references vppsone.staff_profiles (id),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references vppsone.staff_profiles (id),
  constraint calendar_events_kind_known check (kind in ('exam', 'event', 'ptm', 'meeting', 'fee_due')),
  constraint calendar_events_dates_ordered check (ends_on >= starts_on),
  constraint calendar_events_title_present check (length(btrim(title)) between 1 and 120),
  constraint calendar_events_time_when_timed check (all_day or starts_at is not null)
);

comment on table vppsone.calendar_events is
  'School calendar events (exam, event, PTM, meeting, fee due). Holidays are academic_calendar_days rows. Cancelled, never deleted.';

create index if not exists calendar_events_session_dates
  on vppsone.calendar_events (session_label, starts_on, ends_on);

create trigger calendar_events_set_updated_at
  before update on vppsone.calendar_events
  for each row execute function vppsone.set_updated_at();

alter table vppsone.calendar_events enable row level security;
create policy calendar_events_select_active_staff on vppsone.calendar_events
  for select to authenticated using ((select vppsone.is_active_staff()));
grant select on vppsone.calendar_events to authenticated;

-- A notice about an event or a holiday that somebody asked to send. Parent
-- messages are approval-by-default (PLAN §14, parent_message_policies), so a
-- notice is recorded with its text, audience, count and cost, and waits for
-- approval in Messages; nothing here sends.
create table if not exists vppsone.calendar_notices (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  event_id uuid references vppsone.calendar_events (id),
  holiday_day date,
  audience text not null,
  recipients integer not null default 0,
  cost_paise integer not null default 0,
  send_at timestamptz,
  rendered_hi text not null,
  rendered_en text not null,
  status text not null default 'awaiting_approval',
  requested_by uuid not null references vppsone.staff_profiles (id),
  requested_at timestamptz not null default now(),
  constraint calendar_notices_audience_known check (audience in ('parents', 'staff', 'both')),
  constraint calendar_notices_status_known check (status in ('awaiting_approval', 'approved', 'sent', 'cancelled')),
  constraint calendar_notices_names_its_subject check (event_id is not null or holiday_day is not null)
);

comment on table vppsone.calendar_notices is
  'A parent or staff notice about a calendar event or holiday: what it says, to whom, the count and cost. Waits for approval; never sent from here.';

create index if not exists calendar_notices_event on vppsone.calendar_notices (event_id);
create index if not exists calendar_notices_holiday on vppsone.calendar_notices (session_label, holiday_day);

alter table vppsone.calendar_notices enable row level security;
create policy calendar_notices_select_active_staff on vppsone.calendar_notices
  for select to authenticated using ((select vppsone.is_active_staff()));
grant select on vppsone.calendar_notices to authenticated;

-- ------------------------------------------------------------ support plans

create table if not exists vppsone.support_plans (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  -- `public.students.id`, no FK (rule 2).
  student_id uuid not null,
  goal text,
  status text not null default 'draft',
  created_by uuid not null references vppsone.staff_profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  closed_at timestamptz,
  constraint support_plans_status_known check (status in ('draft', 'active', 'done', 'closed'))
);

comment on table vppsone.support_plans is
  'A plan to help one child: a goal and steps with an owner and a date. Draft until started.';

create index if not exists support_plans_student on vppsone.support_plans (session_label, student_id);

create trigger support_plans_set_updated_at
  before update on vppsone.support_plans
  for each row execute function vppsone.set_updated_at();

create table if not exists vppsone.support_plan_steps (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references vppsone.support_plans (id) on delete cascade,
  text text not null,
  owner_staff_id uuid references vppsone.staff_profiles (id),
  due_label text,
  sort_order integer not null default 0,
  done_at timestamptz,
  done_by uuid references vppsone.staff_profiles (id),
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint support_plan_steps_text_present check (length(btrim(text)) between 1 and 160)
);

create index if not exists support_plan_steps_plan on vppsone.support_plan_steps (plan_id, sort_order);

alter table vppsone.support_plans enable row level security;
alter table vppsone.support_plan_steps enable row level security;
create policy support_plans_select_scoped on vppsone.support_plans
  for select to authenticated using (
    (select vppsone.staff_can('notes:view'))
    and ((select vppsone.reads_every_class()) or created_by = (select vppsone.current_staff_profile_id()))
  );
create policy support_plan_steps_select_scoped on vppsone.support_plan_steps
  for select to authenticated using (
    exists (select 1 from vppsone.support_plans p where p.id = support_plan_steps.plan_id)
  );
grant select on vppsone.support_plans, vppsone.support_plan_steps to authenticated;

-- ----------------------------------------------- follow-up on children

-- What a coordinator did about a child on the needs-attention or below-75%
-- lists: a call and its outcome, "improving", or a follow-up handed to
-- somebody. Appended; the latest row of a kind is what the list shows.
create table if not exists vppsone.student_followups (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  student_id uuid not null,
  kind text not null,
  outcome text,
  note text,
  owner_staff_id uuid references vppsone.staff_profiles (id),
  created_by uuid not null references vppsone.staff_profiles (id),
  created_at timestamptz not null default now(),
  constraint student_followups_kind_known check (kind in ('call', 'improving', 'follow_up')),
  constraint student_followups_outcome_known check (
    outcome is null or outcome in ('reached', 'no_answer', 'wrong_number', 'will_come', 'visit_school')
  ),
  constraint student_followups_note_length check (note is null or length(note) <= 400)
);

comment on table vppsone.student_followups is
  'Calls to parents, "improving" marks and follow-ups handed to staff, for children on the attention lists. Append-only.';

create index if not exists student_followups_student
  on vppsone.student_followups (session_label, student_id, created_at desc);

alter table vppsone.student_followups enable row level security;
create policy student_followups_select_scoped on vppsone.student_followups
  for select to authenticated using (
    (select vppsone.staff_can('attendance:view')) and (select vppsone.reads_every_class())
  );
grant select on vppsone.student_followups to authenticated;

-- ------------------------------------------------------- needs attention

-- The coordinator's list, built by the database from the same facts every
-- screen reads (docs/design-handoff DATA-MODEL "v_needs_attention"):
--
--   attendance below 75%      submitted daily registers this session; late is
--                             a whole day, half day is the session's credit,
--                             leave is out of both halves (domain/attendance)
--   below 33% in a subject    the child's latest paper in that subject
--   marks dropped 15%+        latest paper vs the one before, same subject,
--                             in percentage points
--   2 or more open notes      notes of a concern kind in the last 30 days
--
-- One row per child with at least one reason. security_invoker, so a reader
-- sees only the rows the underlying tables' RLS lets them see.
create or replace view vppsone.v_needs_attention
with (security_invoker = true) as
with credit as (
  select r.session_label,
         m.student_id,
         r.class_id,
         case m.status
           when 'present' then 1.0
           when 'late' then 1.0
           when 'half_day' then coalesce(ar.half_day_credit, 0.5)
           when 'absent' then 0.0
           else null
         end as credit
  from vppsone.attendance_marks m
  join vppsone.attendance_registers r on r.id = m.register_id
  left join vppsone.attendance_rules ar on ar.session_label = r.session_label
  where r.status = 'submitted' and r.period is null
),
att as (
  select session_label, student_id,
         count(credit) as days_counted,
         round(100.0 * sum(credit) / nullif(count(credit), 0), 1) as attendance_pct
  from credit
  group by session_label, student_id
),
papers as (
  select a.session_label,
         mk.student_id,
         s.class_id,
         s.subject_id,
         s.subject_code,
         round(100.0 * mk.value / nullif(s.max_marks, 0), 1) as pct,
         row_number() over (
           partition by a.session_label, mk.student_id, s.subject_id
           order by coalesce(a.starts_on, a.ends_on, a.created_at::date) desc, a.created_at desc
         ) as recency
  from vppsone.marks mk
  join vppsone.assessment_subjects s on s.id = mk.assessment_subject_id
  join vppsone.assessments a on a.id = s.assessment_id
  where mk.value is not null and not mk.absent and not mk.exempt
),
latest as (
  select l.session_label, l.student_id, l.subject_code, l.pct, p.pct as previous_pct
  from papers l
  left join papers p
    on p.session_label = l.session_label and p.student_id = l.student_id
   and p.subject_id = l.subject_id and p.recency = 2
  where l.recency = 1
),
marks_flags as (
  select session_label, student_id,
         array_agg(subject_code order by pct) filter (where pct < 33) as below_33_subjects,
         max(previous_pct - pct) filter (where previous_pct - pct >= 15) as drop_points,
         (array_agg(subject_code order by previous_pct - pct desc nulls last)
            filter (where previous_pct - pct >= 15))[1] as drop_subject
  from latest
  group by session_label, student_id
),
open_notes as (
  select n.session_label, n.student_id, count(*)::int as open_notes
  from vppsone.notes n
  join vppsone.note_kinds k on k.id = n.kind_id
  where n.student_id is not null
    and k.tone = 'concern'
    and n.created_at >= now() - interval '30 days'
  group by n.session_label, n.student_id
),
children as (
  select session_label, student_id from att
  union select session_label, student_id from marks_flags
  union select session_label, student_id from open_notes
)
select c.session_label,
       c.student_id,
       e.class_id,
       att.attendance_pct,
       coalesce(att.days_counted, 0) as days_counted,
       coalesce(mf.below_33_subjects, '{}') as below_33_subjects,
       mf.drop_points,
       mf.drop_subject,
       coalesce(o.open_notes, 0) as open_notes,
       array_remove(array[
         case when att.attendance_pct < 75 and att.days_counted >= 5 then 'attendance' end,
         case when coalesce(cardinality(mf.below_33_subjects), 0) > 0 then 'below_33' end,
         case when mf.drop_points is not null then 'dropped' end,
         case when coalesce(o.open_notes, 0) >= 2 then 'notes' end
       ], null) as reasons
from children c
join vppsone.enrolments e
  on e.student_id = c.student_id and e.session_label = c.session_label and e.status = 'enrolled'
left join att on att.session_label = c.session_label and att.student_id = c.student_id
left join marks_flags mf on mf.session_label = c.session_label and mf.student_id = c.student_id
left join open_notes o on o.session_label = c.session_label and o.student_id = c.student_id
where (att.attendance_pct < 75 and att.days_counted >= 5)
   or coalesce(cardinality(mf.below_33_subjects), 0) > 0
   or mf.drop_points is not null
   or coalesce(o.open_notes, 0) >= 2;

comment on view vppsone.v_needs_attention is
  'Children needing attention: attendance < 75% (5+ days counted), any subject < 33% in the latest paper, a drop of 15+ points since the previous paper, or 2+ concern notes in 30 days.';

grant select on vppsone.v_needs_attention to authenticated;

-- ---------------------------------------------------- weekly summary

insert into vppsone.message_templates (code, label_hi, label_en, body_hi, body_en, variables, audience, sort_order)
values (
  'vppsone_weekly_summary',
  'साप्ताहिक शैक्षणिक सारांश',
  'Weekly academic summary',
  'नमस्ते {{1}}, इस सप्ताह का शैक्षणिक सारांश: {{2}} — {{3}}',
  'Hello {{1}}, this week''s academic summary: {{2}} — {{3}}',
  array['name', 'summary', 'from'],
  'staff',
  40
)
on conflict (code) do nothing;

-- ======================================================== migrations/20261010102952_vx_fee_call_promises_rules.sql
-- A parent's promise on a call: amount and date. Insert-only. Kept or broken
-- is computed from receipts (src/modules/defaulters/vx), never stored.

alter table vppsone.fee_call_promises
  add constraint fee_call_promises_created_by_fkey foreign key (created_by) references vppsone.staff_profiles (id) on delete set null,
  add constraint fee_call_promises_kind_known check (kind in ('pay', 'visit')),
  add constraint fee_call_promises_amount_non_negative check (amount >= 0),
  add constraint fee_call_promises_note_short check (note is null or length(note) <= 500);
comment on table vppsone.fee_call_promises is
  'A parent''s promise on a call: amount and date. Insert-only. Kept or broken is computed from receipts, never stored.';
create index if not exists fee_call_promises_by_day_idx on vppsone.fee_call_promises (promised_on);
create index if not exists fee_call_promises_by_student_idx on vppsone.fee_call_promises (student_id, created_at desc);
alter table vppsone.fee_call_promises enable row level security;
create policy fee_call_promises_select on vppsone.fee_call_promises for select to authenticated
  using ((select vppsone.staff_can('fees:view')));
grant select on vppsone.fee_call_promises to authenticated;
grant select, insert on vppsone.fee_call_promises to service_role;

-- ======================================================== migrations/20261010103004_vx_fee_day_close_events.sql
-- The counted close of a fee desk day. Insert-only: reopening is a new row.
-- It does not lock receipts (that would mean changing the fee RPCs); receipts
-- posted after a close are flagged on /receipts instead. The fee app's own
-- auto-day-close cron (public.collection_closures) is left as it is.

create table if not exists vppsone.fee_day_close_events (
  id uuid primary key default gen_random_uuid(),
  payment_date date not null,
  action text not null,
  session_label text not null,
  expected jsonb not null default '{}'::jsonb,
  denominations jsonb not null default '{}'::jsonb,
  cash_expected numeric(12, 2) not null default 0,
  cash_counted numeric(12, 2) not null default 0,
  upi_checked boolean not null default false,
  receipt_count integer not null default 0,
  reversed_count integer not null default 0,
  note text,
  actor_id uuid references vppsone.staff_profiles (id) on delete set null,
  actor_name text,
  created_at timestamptz not null default now(),
  constraint fee_day_close_events_action_known check (action in ('close', 'reopen')),
  constraint fee_day_close_events_counted_or_explained check (
    action <> 'close' or cash_counted = cash_expected or length(btrim(coalesce(note, ''))) >= 5),
  constraint fee_day_close_events_note_short check (note is null or length(note) <= 500)
);
comment on table vppsone.fee_day_close_events is
  'Counted close of a fee desk day. Insert-only: reopening is a new row. Does not lock receipts; receipts posted after a close are flagged on screen.';
create index if not exists fee_day_close_events_by_day_idx on vppsone.fee_day_close_events (payment_date, created_at desc);
alter table vppsone.fee_day_close_events enable row level security;
create policy fee_day_close_events_select on vppsone.fee_day_close_events for select to authenticated
  using ((select vppsone.staff_can('fees:view')));
grant select on vppsone.fee_day_close_events to authenticated;
grant select, insert on vppsone.fee_day_close_events to service_role;

-- ======================================================== migrations/20261010103016_vx_fee_desk_requests.sql
-- A receipt reversal or a write-off asked for by staff who cannot do it
-- themselves, for an admin to decide under "Needs you". The money moves only
-- through the fee RPCs, and only when an admin acts.

create table if not exists vppsone.fee_desk_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  status text not null default 'pending',
  session_label text not null,
  student_id uuid not null,
  receipt_id uuid,
  receipt_number text,
  amount numeric(12, 2) not null,
  reason_code text not null,
  note text,
  requested_by uuid references vppsone.staff_profiles (id) on delete set null,
  requested_by_name text,
  decided_by uuid references vppsone.staff_profiles (id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now(),
  constraint fee_desk_requests_kind_known check (kind in ('reversal', 'write_off')),
  constraint fee_desk_requests_status_known check (status in ('pending', 'approved', 'declined', 'withdrawn')),
  constraint fee_desk_requests_amount_positive check (amount > 0),
  constraint fee_desk_requests_reversal_has_receipt check (kind <> 'reversal' or receipt_id is not null),
  constraint fee_desk_requests_note_short check (note is null or length(note) <= 500)
);
comment on table vppsone.fee_desk_requests is
  'A receipt reversal or a write-off asked for by staff who cannot do it themselves. An admin decides; the money moves only through the fee RPCs.';
create unique index if not exists fee_desk_requests_one_pending_reversal
  on vppsone.fee_desk_requests (receipt_id) where kind = 'reversal' and status = 'pending';
create unique index if not exists fee_desk_requests_one_pending_write_off
  on vppsone.fee_desk_requests (student_id, session_label) where kind = 'write_off' and status = 'pending';
create index if not exists fee_desk_requests_pending_idx on vppsone.fee_desk_requests (created_at desc) where status = 'pending';
alter table vppsone.fee_desk_requests enable row level security;
create policy fee_desk_requests_select on vppsone.fee_desk_requests for select to authenticated
  using ((select vppsone.staff_can('fees:view')));
grant select on vppsone.fee_desk_requests to authenticated;
grant select, insert, update on vppsone.fee_desk_requests to service_role;

-- ======================================================== migrations/20261010103021_vx_fee_reminder_rules.sql
-- Settings of the automatic fee reminder rules shown on /reminders. Sending
-- stays with the fee app's scheduled sender; nothing here sends.

create table if not exists vppsone.fee_reminder_rules (
  id uuid primary key default gen_random_uuid(),
  rule_key text not null unique,
  title_en text not null,
  title_hi text,
  icon text not null default 'bell',
  timing_options text[] not null default '{}',
  timing_choice text not null,
  send_time text not null default '10',
  audience text not null default 'all',
  template text not null default 'gentle',
  quiet_hours boolean not null default true,
  enabled boolean not null default false,
  sort_order integer not null default 0,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint fee_reminder_rules_send_time_known check (send_time in ('10', '12', '17', '19')),
  constraint fee_reminder_rules_audience_known check (audience in ('all', 'skip_promised')),
  constraint fee_reminder_rules_template_known check (template in ('gentle', 'final', 'upcoming'))
);
comment on table vppsone.fee_reminder_rules is
  'Settings of the automatic fee reminder rules shown on /reminders. Sending stays with the fee app''s scheduled sender.';
alter table vppsone.fee_reminder_rules enable row level security;
create policy fee_reminder_rules_select on vppsone.fee_reminder_rules for select to authenticated
  using ((select vppsone.staff_can('fees:view')));
grant select on vppsone.fee_reminder_rules to authenticated;
grant select, insert, update on vppsone.fee_reminder_rules to service_role;

-- ======================================================== migrations/20261010103026_vx_fee_reminder_batches.sql
-- A fee reminder batch prepared on /reminders. QUEUED ONLY: nothing in VPPS
-- One sends these (CLAUDE.md rule 8). A person sends from the classic
-- WhatsApp screen after its own preview.

create table if not exists vppsone.fee_reminder_batches (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  name text not null,
  template text not null,
  language text not null default 'both',
  audience jsonb not null default '{}'::jsonb,
  audience_line text,
  student_ids uuid[] not null default '{}',
  family_count integer not null default 0,
  money_quoted numeric(14, 2) not null default 0,
  cost_estimate numeric(10, 2) not null default 0,
  status text not null default 'queued',
  scheduled_for timestamptz,
  created_by uuid references vppsone.staff_profiles (id) on delete set null,
  created_by_name text,
  created_at timestamptz not null default now(),
  constraint fee_reminder_batches_template_known check (template in ('gentle', 'final', 'upcoming')),
  constraint fee_reminder_batches_language_known check (language in ('both', 'hi', 'en')),
  constraint fee_reminder_batches_status_known check (status in ('queued', 'scheduled', 'cancelled')),
  constraint fee_reminder_batches_name_not_blank check (btrim(name) <> '')
);
comment on table vppsone.fee_reminder_batches is
  'A fee reminder batch prepared on /reminders. QUEUED ONLY: nothing in VPPS One sends these (CLAUDE.md rule 8).';
create index if not exists fee_reminder_batches_recent_idx on vppsone.fee_reminder_batches (created_at desc);
alter table vppsone.fee_reminder_batches enable row level security;
create policy fee_reminder_batches_select on vppsone.fee_reminder_batches for select to authenticated
  using ((select vppsone.staff_can('fees:view')));
grant select on vppsone.fee_reminder_batches to authenticated;
grant select, insert, update on vppsone.fee_reminder_batches to service_role;

-- ======================================================== migrations/20261010103114_vx_teacher_notes_columns.sql
-- VPPS One — notes on children get the design's shape (UI P7): tags,
-- voice/typed, a follow-up with a date and an owner, a status
-- (open → working → done), visibility (team / only me) and "tell parents".
-- Additive, vppsone only.
set local lock_timeout = '15s';
alter table vppsone.notes
  add column if not exists source text not null default 'typed',
  add column if not exists tags text[] not null default '{}',
  add column if not exists needs_follow_up boolean not null default false,
  add column if not exists follow_up_on date,
  add column if not exists follow_up_owner text,
  add column if not exists follow_up_staff_id uuid references vppsone.staff_profiles (id) on delete set null,
  add column if not exists status text not null default 'open',
  add column if not exists visibility text not null default 'team',
  add column if not exists tell_parents boolean not null default false,
  add column if not exists author_relation text,
  add column if not exists subject_code text,
  add column if not exists status_changed_at timestamptz,
  add column if not exists status_changed_by uuid references vppsone.staff_profiles (id) on delete set null;

-- ======================================================== migrations/20261010103349_vx_teacher_notes_scope.sql
-- "Only me" is only the author. Team notes are read by the office and admin
-- (who correct attendance), the coordinators (who read every class), the
-- person asked to follow up, and the teachers of that class — so a subject
-- teacher's note reaches the class teacher by itself.
set local lock_timeout = '15s';
alter policy notes_select_scoped
  on vppsone.notes
  using (
    (select vppsone.staff_can('notes:view'))
    and (
      written_by = (select vppsone.current_staff_profile_id())
      or (
        visibility = 'team'
        and (
          (select vppsone.staff_can('attendance:correct'))
          or (select vppsone.reads_every_class())
          or follow_up_staff_id = (select vppsone.current_staff_profile_id())
          or (
            class_id is not null
            and (class_id::text || '|' || session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
          )
        )
      )
    )
  );

-- ======================================================== migrations/20261010103358_vx_teacher_notes_rules.sql
-- The values the new note columns may hold.
set local lock_timeout = '15s';
alter table vppsone.notes
  add constraint notes_source_known check (source in ('typed', 'voice')),
  add constraint notes_tags_known check (tags <@ array['studies', 'behaviour', 'health', 'family', 'talent', 'attendance']::text[]),
  add constraint notes_status_known check (status in ('open', 'working', 'done')),
  add constraint notes_visibility_known check (visibility in ('team', 'private')),
  add constraint notes_follow_up_owner_known check (follow_up_owner is null or follow_up_owner in ('me', 'class_teacher', 'coordinator', 'admin')),
  add constraint notes_follow_up_has_date check (not needs_follow_up or follow_up_on is not null);
create index if not exists notes_follow_up_idx on vppsone.notes (follow_up_on) where needs_follow_up and status <> 'done';

-- ======================================================== migrations/20261010103433_vx_message_campaign_queue.sql
-- Messages (design `Messages`): queue a notice and every recipient row in one
-- transaction, idempotent on the campaign's client_request_id. Rows are only
-- ever queued here; nothing in this function sends, and parent rows still stop
-- at the queue behind vppsone.runtime_flags.parent_dispatch (D-10).

create or replace function vppsone.queue_message_campaign(
  p_campaign jsonb,
  p_rows jsonb
) returns jsonb
language plpgsql
security definer
set search_path = vppsone, pg_temp
as $$
declare
  v_id uuid;
  v_request uuid := (p_campaign->>'client_request_id')::uuid;
  v_count integer;
begin
  if v_request is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty');
  end if;

  select id into v_id from vppsone.message_campaigns where client_request_id = v_request;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'campaign_id', v_id, 'duplicate', true);
  end if;

  v_count := jsonb_array_length(p_rows);

  insert into vppsone.message_campaigns (
    session_label, kind, title, body_hi, body_en, language, audience, class_ids,
    audience_label, recipient_count, cost_paise, status, client_request_id, created_by
  ) values (
    p_campaign->>'session_label',
    p_campaign->>'kind',
    p_campaign->>'title',
    p_campaign->>'body_hi',
    p_campaign->>'body_en',
    coalesce(p_campaign->>'language', 'both'),
    p_campaign->>'audience',
    coalesce(array(select jsonb_array_elements_text(p_campaign->'class_ids'))::uuid[], '{}'::uuid[]),
    p_campaign->>'audience_label',
    v_count,
    v_count * 88,
    'queued',
    v_request,
    (p_campaign->>'created_by')::uuid
  )
  on conflict (client_request_id) do nothing
  returning id into v_id;

  if v_id is null then
    -- A concurrent post with the same request id won the race.
    select id into v_id from vppsone.message_campaigns where client_request_id = v_request;
    return jsonb_build_object('ok', true, 'campaign_id', v_id, 'duplicate', true);
  end if;

  insert into vppsone.message_sends (
    session_label, template_id, to_phone, to_name, student_id, staff_profile_id,
    variables, rendered_hi, rendered_en, status, requested_by, category, snapshot, campaign_id
  )
  select
    p_campaign->>'session_label',
    (r->>'template_id')::uuid,
    r->>'to_phone',
    r->>'to_name',
    nullif(r->>'student_id', '')::uuid,
    nullif(r->>'staff_profile_id', '')::uuid,
    coalesce(array(select jsonb_array_elements_text(r->'variables')), '{}'::text[]),
    coalesce(r->>'rendered_hi', ''),
    coalesce(r->>'rendered_en', ''),
    'queued',
    (p_campaign->>'created_by')::uuid,
    coalesce(r->>'category', 'general'),
    r->'snapshot',
    v_id
  from jsonb_array_elements(p_rows) as r;

  return jsonb_build_object('ok', true, 'campaign_id', v_id, 'duplicate', false, 'count', v_count);
end;
$$;

revoke all on function vppsone.queue_message_campaign(jsonb, jsonb) from public, anon, authenticated;
grant execute on function vppsone.queue_message_campaign(jsonb, jsonb) to service_role;

-- ======================================================== migrations/20261010103503_vx_teacher_notes_tables.sql
-- Replies on notes, "Got it" on staff notices, and the queue of messages to
-- parents (absent alerts, birthday wishes, notes, support plans).
--
-- support_plans / support_plan_steps belong to vx_academics_calendar; the
-- notes screens add only what they need on top. Leave requests reuse
-- vppsone.teacher_leave and "large text" reuses vppsone.staff_ui_preferences.
--
-- parent_message_queue is QUEUED ONLY: nothing in VPPS One sends it.
set local lock_timeout = '15s';

alter table vppsone.support_plans
  add column if not exists class_id uuid,
  add column if not exists note_id uuid references vppsone.notes (id) on delete set null,
  add column if not exists tell_parents boolean not null default false;
create index if not exists support_plans_by_note_idx on vppsone.support_plans (note_id);

alter table vppsone.support_plan_steps
  add column if not exists owner_role text,
  add column if not exists created_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column if not exists removed_by uuid references vppsone.staff_profiles (id) on delete set null;
alter table vppsone.support_plan_steps
  add constraint support_plan_steps_owner_role_known
  check (owner_role is null or owner_role in ('me', 'class_teacher', 'subject_teacher', 'coordinator', 'admin', 'parents'));

create table vppsone.note_replies (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references vppsone.notes (id) on delete cascade,
  body text not null,
  source text not null default 'typed',
  written_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint note_replies_body_not_blank check (btrim(body) <> '' and length(body) <= 1000),
  constraint note_replies_source_known check (source in ('typed', 'voice', 'system'))
);
comment on table vppsone.note_replies is
  'Replies on a note about a child. Insert-only: a reply is never edited, so the thread is a record.';
create index note_replies_by_note_idx on vppsone.note_replies (note_id, created_at);
alter table vppsone.note_replies enable row level security;
create policy note_replies_select_with_note
  on vppsone.note_replies for select to authenticated
  using (exists (select 1 from vppsone.notes n where n.id = note_id));
grant select on vppsone.note_replies to authenticated;
grant select, insert on vppsone.note_replies to service_role;

create table vppsone.staff_notice_reads (
  campaign_id uuid not null references vppsone.message_campaigns (id) on delete cascade,
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (campaign_id, staff_profile_id)
);
comment on table vppsone.staff_notice_reads is
  'A member of staff tapped "Got it" on a notice the office sent to staff. The office sees who has read it.';
alter table vppsone.staff_notice_reads enable row level security;
create policy staff_notice_reads_select
  on vppsone.staff_notice_reads for select to authenticated
  using (
    staff_profile_id = (select vppsone.current_staff_profile_id())
    or (select vppsone.staff_can('messages:send'))
  );
grant select on vppsone.staff_notice_reads to authenticated;
grant all on vppsone.staff_notice_reads to service_role;

create table vppsone.parent_message_queue (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  kind text not null,
  student_id uuid not null,
  class_id uuid,
  register_id uuid references vppsone.attendance_registers (id) on delete set null,
  note_id uuid references vppsone.notes (id) on delete set null,
  plan_id uuid references vppsone.support_plans (id) on delete set null,
  day date,
  body_hi text not null,
  body_en text,
  status text not null default 'queued',
  queued_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references vppsone.staff_profiles (id) on delete set null,
  constraint parent_message_queue_kind_known check (kind in ('absent_alert', 'birthday', 'note', 'support_plan')),
  constraint parent_message_queue_status_known check (status in ('queued', 'cancelled'))
);
comment on table vppsone.parent_message_queue is
  'Messages to parents a teacher asked for. QUEUED ONLY: nothing in VPPS One sends these. A person previews and sends from Messages (RULES H; CLAUDE.md rule 8).';
create unique index parent_message_queue_one_absent_alert
  on vppsone.parent_message_queue (register_id, student_id)
  where kind = 'absent_alert' and status = 'queued';
create index parent_message_queue_recent_idx on vppsone.parent_message_queue (created_at desc);
alter table vppsone.parent_message_queue enable row level security;
create policy parent_message_queue_select
  on vppsone.parent_message_queue for select to authenticated
  using (
    queued_by = (select vppsone.current_staff_profile_id())
    or (select vppsone.staff_can('messages:send'))
  );
grant select on vppsone.parent_message_queue to authenticated;
grant all on vppsone.parent_message_queue to service_role;

-- ======================================================== migrations/20261010103638_vx_needs_attention_open_notes.sql
-- "2 or more open notes" now reads the notes' own status (open, working,
-- done), which the Notes redesign added, instead of standing in with "concern
-- notes in the last 30 days". Praise is never a reason for attention.
-- Same columns, so create or replace keeps every grant and reader.
create or replace view vppsone.v_needs_attention
with (security_invoker = true) as
with credit as (
  select r.session_label,
         m.student_id,
         r.class_id,
         case m.status
           when 'present' then 1.0
           when 'late' then 1.0
           when 'half_day' then coalesce(ar.half_day_credit, 0.5)
           when 'absent' then 0.0
           else null
         end as credit
  from vppsone.attendance_marks m
  join vppsone.attendance_registers r on r.id = m.register_id
  left join vppsone.attendance_rules ar on ar.session_label = r.session_label
  where r.status = 'submitted' and r.period is null
),
att as (
  select session_label, student_id,
         count(credit) as days_counted,
         round(100.0 * sum(credit) / nullif(count(credit), 0), 1) as attendance_pct
  from credit
  group by session_label, student_id
),
papers as (
  select a.session_label,
         mk.student_id,
         s.class_id,
         s.subject_id,
         s.subject_code,
         round(100.0 * mk.value / nullif(s.max_marks, 0), 1) as pct,
         row_number() over (
           partition by a.session_label, mk.student_id, s.subject_id
           order by coalesce(a.starts_on, a.ends_on, a.created_at::date) desc, a.created_at desc
         ) as recency
  from vppsone.marks mk
  join vppsone.assessment_subjects s on s.id = mk.assessment_subject_id
  join vppsone.assessments a on a.id = s.assessment_id
  where mk.value is not null and not mk.absent and not mk.exempt
),
latest as (
  select l.session_label, l.student_id, l.subject_code, l.pct, p.pct as previous_pct
  from papers l
  left join papers p
    on p.session_label = l.session_label and p.student_id = l.student_id
   and p.subject_id = l.subject_id and p.recency = 2
  where l.recency = 1
),
marks_flags as (
  select session_label, student_id,
         array_agg(subject_code order by pct) filter (where pct < 33) as below_33_subjects,
         max(previous_pct - pct) filter (where previous_pct - pct >= 15) as drop_points,
         (array_agg(subject_code order by previous_pct - pct desc nulls last)
            filter (where previous_pct - pct >= 15))[1] as drop_subject
  from latest
  group by session_label, student_id
),
open_notes as (
  select n.session_label, n.student_id, count(*)::int as open_notes
  from vppsone.notes n
  join vppsone.note_kinds k on k.id = n.kind_id
  where n.student_id is not null
    and n.status in ('open', 'working')
    and k.tone <> 'good'
  group by n.session_label, n.student_id
),
children as (
  select session_label, student_id from att
  union select session_label, student_id from marks_flags
  union select session_label, student_id from open_notes
)
select c.session_label,
       c.student_id,
       e.class_id,
       att.attendance_pct,
       coalesce(att.days_counted, 0) as days_counted,
       coalesce(mf.below_33_subjects, '{}') as below_33_subjects,
       mf.drop_points,
       mf.drop_subject,
       coalesce(o.open_notes, 0) as open_notes,
       array_remove(array[
         case when att.attendance_pct < 75 and att.days_counted >= 5 then 'attendance' end,
         case when coalesce(cardinality(mf.below_33_subjects), 0) > 0 then 'below_33' end,
         case when mf.drop_points is not null then 'dropped' end,
         case when coalesce(o.open_notes, 0) >= 2 then 'notes' end
       ], null) as reasons
from children c
join vppsone.enrolments e
  on e.student_id = c.student_id and e.session_label = c.session_label and e.status = 'enrolled'
left join att on att.session_label = c.session_label and att.student_id = c.student_id
left join marks_flags mf on mf.session_label = c.session_label and mf.student_id = c.student_id
left join open_notes o on o.session_label = c.session_label and o.student_id = c.student_id
where (att.attendance_pct < 75 and att.days_counted >= 5)
   or coalesce(cardinality(mf.below_33_subjects), 0) > 0
   or mf.drop_points is not null
   or coalesce(o.open_notes, 0) >= 2;

comment on view vppsone.v_needs_attention is
  'Children needing attention: attendance < 75% (5+ days counted), any subject < 33% in the latest paper, a drop of 15+ points since the previous paper, or 2+ notes still open (status open or working, not praise).';

grant select on vppsone.v_needs_attention to authenticated;

-- ======================================================== migrations/20261010104156_vx_academic_rollups.sql
-- Roll-ups the coordinator's screens read (AcadHome, AcadProgress,
-- AcadAttendance, Calendar), so a month of attendance is ~700 register rows
-- rather than ~16,000 marks, and an exam's class-by-subject heat map is one
-- row per paper. Views only, in vppsone, security_invoker: a reader sees what
-- the underlying tables' RLS lets them see.

-- One daily register with its counts. Late counts present (a whole day),
-- leave is not counted, half day is the session's credit — the same rules as
-- modules/attendance/domain/attendance.ts and v_needs_attention.
create or replace view vppsone.v_register_tally
with (security_invoker = true) as
select r.id as register_id,
       r.session_label,
       r.class_id,
       r.day,
       r.status,
       r.submitted_at,
       r.taken_by,
       r.on_behalf_of,
       count(m.student_id)::int as marked,
       count(m.student_id) filter (where m.status = 'present')::int as present,
       count(m.student_id) filter (where m.status = 'absent')::int as absent,
       count(m.student_id) filter (where m.status = 'late')::int as late,
       count(m.student_id) filter (where m.status = 'leave')::int as on_leave,
       count(m.student_id) filter (where m.status = 'half_day')::int as half_day
from vppsone.attendance_registers r
left join vppsone.attendance_marks m on m.register_id = r.id
where r.period is null
group by r.id;

comment on view vppsone.v_register_tally is
  'Each daily register with its present/absent/late/leave/half-day counts.';

-- A child's attendance this session, from submitted daily registers.
create or replace view vppsone.v_student_attendance
with (security_invoker = true) as
select r.session_label,
       m.student_id,
       count(*) filter (where m.status <> 'leave')::int as days_counted,
       sum(case m.status
             when 'present' then 1.0
             when 'late' then 1.0
             when 'half_day' then coalesce(ar.half_day_credit, 0.5)
             when 'absent' then 0.0
             else 0.0
           end) as credit,
       count(*) filter (where m.status = 'absent')::int as absent_days,
       count(*) filter (where m.status = 'late')::int as late_days,
       count(*) filter (where m.status = 'absent' and r.day >= vppsone.school_today() - 7)::int as absent_last_week,
       round(100.0 * sum(case m.status
                           when 'present' then 1.0
                           when 'late' then 1.0
                           when 'half_day' then coalesce(ar.half_day_credit, 0.5)
                           when 'absent' then 0.0
                           else 0.0
                         end) / nullif(count(*) filter (where m.status <> 'leave'), 0), 1) as attendance_pct
from vppsone.attendance_marks m
join vppsone.attendance_registers r on r.id = m.register_id
left join vppsone.attendance_rules ar on ar.session_label = r.session_label
where r.status = 'submitted' and r.period is null
group by r.session_label, m.student_id;

comment on view vppsone.v_student_attendance is
  'Each child''s attendance this session from submitted daily registers (late = present, leave not counted).';

-- One exam paper (class × subject) with how far entry has got and how it went.
create or replace view vppsone.v_paper_stats
with (security_invoker = true) as
select s.id as paper_id,
       s.assessment_id,
       a.session_label,
       a.code as exam_code,
       s.class_id,
       s.class_label,
       s.subject_id,
       s.subject_code,
       s.max_marks,
       s.pass_marks,
       s.entry_status,
       s.submitted_at,
       s.sort_order,
       count(mk.id) filter (where mk.value is not null or mk.absent or mk.exempt)::int as entered,
       count(mk.value)::int as scored,
       round(avg(100.0 * mk.value / nullif(s.max_marks, 0)), 1) as avg_pct,
       count(mk.id) filter (where mk.value >= s.pass_marks)::int as passed
from vppsone.assessment_subjects s
join vppsone.assessments a on a.id = s.assessment_id
left join vppsone.marks mk on mk.assessment_subject_id = s.id
group by s.id, a.id;

comment on view vppsone.v_paper_stats is
  'Each exam paper with marks entered, average percent and passes.';

-- A child's result in one exam across their papers.
create or replace view vppsone.v_student_exam
with (security_invoker = true) as
select a.session_label,
       s.assessment_id,
       mk.student_id,
       s.class_id,
       round(avg(100.0 * mk.value / nullif(s.max_marks, 0)), 1) as avg_pct,
       count(mk.value)::int as papers,
       count(mk.value) filter (where mk.value < s.pass_marks)::int as failed
from vppsone.marks mk
join vppsone.assessment_subjects s on s.id = mk.assessment_subject_id
join vppsone.assessments a on a.id = s.assessment_id
where mk.value is not null and not mk.absent and not mk.exempt
group by a.session_label, s.assessment_id, mk.student_id, s.class_id;

comment on view vppsone.v_student_exam is
  'Each child''s average percent and failed papers in one exam.';

grant select on vppsone.v_register_tally, vppsone.v_student_attendance,
  vppsone.v_paper_stats, vppsone.v_student_exam to authenticated;

-- ======================================================== migrations/20261011030048_vx_send_by_hand.sql
-- Sending by hand from Messages → To send.
--
-- Nothing here sends. A person opens their own WhatsApp from the queue with
-- the text filled in (wa.me), presses send there, and the row is marked sent
-- by them (D-10, RULES H). These columns are what that needs:
--
-- * parent_message_queue rows (teacher notes, absent alerts) can now be
--   `sent`, with who and when;
-- * a fee reminder batch and a calendar notice are turned into one message
--   per family when a person prepares them, and remember which campaign that
--   made, so it is never prepared twice.

alter table vppsone.parent_message_queue
  drop constraint if exists parent_message_queue_status_known;
alter table vppsone.parent_message_queue
  add constraint parent_message_queue_status_known check (status in ('queued', 'sent', 'cancelled'));
alter table vppsone.parent_message_queue
  add column if not exists sent_at timestamptz,
  add column if not exists sent_by uuid references vppsone.staff_profiles (id) on delete set null;
alter table vppsone.parent_message_queue
  add constraint parent_message_queue_sent_together check ((status = 'sent') = (sent_at is not null));

comment on table vppsone.parent_message_queue is
  'Messages to parents a teacher asked for. Nothing in VPPS One sends these: a person opens WhatsApp from Messages → To send, sends it, and it is marked sent by them (RULES H; CLAUDE.md rule 8).';

alter table vppsone.fee_reminder_batches
  drop constraint if exists fee_reminder_batches_status_known;
alter table vppsone.fee_reminder_batches
  add constraint fee_reminder_batches_status_known check (status in ('queued', 'scheduled', 'prepared', 'cancelled'));
alter table vppsone.fee_reminder_batches
  add column if not exists campaign_id uuid references vppsone.message_campaigns (id) on delete set null,
  add column if not exists prepared_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column if not exists prepared_at timestamptz;

comment on table vppsone.fee_reminder_batches is
  'A fee reminder batch prepared on /reminders. Nothing sends it: preparing it makes one message per family in Messages → To send, which a person sends by hand (CLAUDE.md rule 8).';

alter table vppsone.calendar_notices
  add column if not exists campaign_id uuid references vppsone.message_campaigns (id) on delete set null,
  add column if not exists decided_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column if not exists decided_at timestamptz;

comment on table vppsone.calendar_notices is
  'A parent or staff notice about a calendar event or holiday. Approving it in Messages → To send makes one message per family or colleague, which a person sends by hand; nothing is sent from here.';

-- ======================================================== migrations/20261011090858_vx_sensitive_notes_scope.sql
-- Health and family notes are read by fewer people (D-264).
--
-- The 11 October improvement notes asked who sees each kind of note (§10.5).
-- The default chosen until the school answers: a support note (studies,
-- behaviour, talent, attendance) is read as before — the child's teachers,
-- the person asked to follow it up and the school-wide roles. A health or
-- family note is read by its author, the person asked to follow it up, the
-- administrator and the child's class teacher only.
--
-- `canSeeNote()` in src/vx/screens/notes/domain/notes.ts is the same rule for
-- reads made with the service role; tests/vx-notes.test.ts pins it. A note
-- written before tags existed is sensitive by its old kind (health, parent),
-- as `tagsFromKind()` reads it. Additive: one helper each, one policy body.
set local lock_timeout = '15s';

-- The classes the signed-in person is class teacher of today, as
-- "class_id|session_label" keys, the shape `my_class_keys()` returns.
create or replace function vppsone.my_held_class_keys()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct ct.class_id::text || '|' || ct.session_label), '{}'::text[])
  from vppsone.class_teachers ct
  where ct.staff_profile_id = vppsone.current_staff_profile_id()
    and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
    and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
$$;
revoke all on function vppsone.my_held_class_keys() from public, anon;
grant execute on function vppsone.my_held_class_keys() to authenticated, service_role;

create or replace function vppsone.is_admin_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from vppsone.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'admin'
  )
$$;
revoke all on function vppsone.is_admin_staff() from public, anon;
grant execute on function vppsone.is_admin_staff() to authenticated, service_role;

-- A note about health or family, by its tags or, with none, its old kind.
create or replace function vppsone.note_is_sensitive(p_tags text[], p_kind_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when coalesce(cardinality(p_tags), 0) > 0 then p_tags && array['health', 'family']::text[]
    else exists (select 1 from vppsone.note_kinds k where k.id = p_kind_id and k.code in ('health', 'parent'))
  end
$$;
revoke all on function vppsone.note_is_sensitive(text[], uuid) from public, anon;
grant execute on function vppsone.note_is_sensitive(text[], uuid) to authenticated, service_role;

alter policy notes_select_scoped
  on vppsone.notes
  using (
    (select vppsone.staff_can('notes:view'))
    and (
      written_by = (select vppsone.current_staff_profile_id())
      or (
        visibility = 'team'
        and (
          follow_up_staff_id = (select vppsone.current_staff_profile_id())
          or (
            vppsone.note_is_sensitive(tags, kind_id)
            and (
              (select vppsone.is_admin_staff())
              or (
                class_id is not null
                and (class_id::text || '|' || session_label) = any (coalesce((select vppsone.my_held_class_keys()), '{}'::text[]))
              )
            )
          )
          or (
            not vppsone.note_is_sensitive(tags, kind_id)
            and (
              (select vppsone.staff_can('attendance:correct'))
              or (select vppsone.reads_every_class())
              or (
                class_id is not null
                and (class_id::text || '|' || session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
              )
            )
          )
        )
      )
    )
  );

-- ======================================================== migrations/20261011091243_vx_family_contact.sql
-- Family contact outcomes (D-265).
--
-- The 11 October notes (§6): "Family contact should record what actually
-- happened: attempted, spoke, or follow-up agreed. Drafting a message does not
-- mean it was sent." A contact is a new kind on the existing follow-up record
-- rather than a second table, so the coordinator's attention lists, the
-- student's academic page and Student 360 all read one history.
--
-- Additive only: existing 'call' rows and their outcomes are untouched. A
-- contact can name the note it was about, and a "follow-up agreed" carries
-- the date that was agreed. Nothing here sends anything to a family.

alter table vppsone.student_followups
  add column if not exists agreed_on date,
  add column if not exists note_id uuid references vppsone.notes (id) on delete set null;

alter table vppsone.student_followups drop constraint if exists student_followups_kind_known;
alter table vppsone.student_followups
  add constraint student_followups_kind_known check (kind in ('call', 'improving', 'follow_up', 'contact'));

alter table vppsone.student_followups drop constraint if exists student_followups_outcome_known;
alter table vppsone.student_followups
  add constraint student_followups_outcome_known check (
    outcome is null
    or outcome in ('reached', 'no_answer', 'wrong_number', 'will_come', 'visit_school', 'attempted', 'spoke', 'follow_up_agreed')
  );

-- A contact always says how it went, with one of its own three outcomes; an
-- agreed date belongs only to "follow-up agreed", and is required there.
alter table vppsone.student_followups
  add constraint student_followups_contact_shape check (
    (kind <> 'contact' and agreed_on is null)
    or (kind = 'contact' and outcome in ('attempted', 'spoke') and agreed_on is null)
    or (kind = 'contact' and outcome = 'follow_up_agreed' and agreed_on is not null)
  );

comment on column vppsone.student_followups.agreed_on is
  'For a family contact whose outcome is follow_up_agreed: the date agreed with the family.';
comment on column vppsone.student_followups.note_id is
  'The note (support action) a family contact was about, when there was one.';

-- ======================================================== migrations/20261011092957_vx_fee_collector_role_permissions.sql
-- D-261: fee collectors take money at the Payment Desk (fees:collect); the back
-- office (closing the day, reversals, bank books, refunds, bulk entry,
-- pausing reminders) moves to a new fees:accounts held by the accountant and
-- the admin. Rows only; additive.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'fees:accounts'),
  ('accountant', 'fees:accounts'),
  ('fee_collector', 'fees:collect')
on conflict do nothing;

-- ======================================================== migrations/20261016070000_teacher_tasks.sql
-- Shared teacher work. All application objects stay in vppsone. Unapplied.
-- Canonical collection/marks/register rows own completion; tasks own delegation.
create table vppsone.teacher_tasks (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  kind text not null check (kind in ('collection','marks','attendance')),
  source_key text not null,
  request_id uuid unique references vppsone.collection_requests(id),
  paper_id uuid references vppsone.assessment_subjects(id),
  class_id uuid,
  day date,
  scope jsonb not null,
  assigned_staff_id uuid not null references vppsone.staff_profiles(id),
  title text not null,
  due_date date,
  -- Like collection_requests.token: capability visible only to service_role.
  token text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text,'-',''),
  revoked_at timestamptz,
  opened_at timestamptz,
  created_by uuid not null references vppsone.staff_profiles(id),
  created_at timestamptz not null default now(),
  check ((kind='collection' and request_id is not null and paper_id is null and day is null)
    or (kind='marks' and paper_id is not null and request_id is null and day is null)
    or (kind='attendance' and class_id is not null and day is not null and request_id is null and paper_id is null))
);
create index teacher_tasks_assignee on vppsone.teacher_tasks(session_label, assigned_staff_id);
create unique index teacher_tasks_current_source on vppsone.teacher_tasks(source_key) where revoked_at is null;
create table vppsone.teacher_task_previews (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references vppsone.staff_profiles(id),
  payload jsonb not null,
  digest text generated always as (md5(payload::text)) stored,
  expires_at timestamptz not null default now() + interval '30 minutes',
  result jsonb,
  created_at timestamptz not null default now()
);
alter table vppsone.teacher_tasks enable row level security;
alter table vppsone.teacher_task_previews enable row level security;
revoke all on vppsone.teacher_tasks, vppsone.teacher_task_previews from anon, authenticated;
grant all on vppsone.teacher_tasks, vppsone.teacher_task_previews to service_role;

create function vppsone.teacher_task_owner(p_staff uuid, p_session text, p_scope jsonb, p_kind text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from vppsone.staff_profiles sp where sp.id=p_staff and sp.is_active and (sp.is_teaching or sp.role='teacher')
      and (p_kind='collection' or exists (select 1 from vppsone.role_permissions rp where rp.role=sp.role
        and rp.permission=case when p_kind='marks' then 'marks:write' else 'attendance:mark' end))
      and case p_scope->>'kind'
        when 'common' then p_kind='collection'
        when 'class' then p_kind<>'marks' and exists (select 1 from vppsone.class_teachers ct
          where ct.staff_profile_id=p_staff and ct.session_label=p_session and ct.class_id::text=p_scope->>'value'
          and ct.role='class_teacher' and ct.effective_from<=vppsone.school_today()
          and (ct.effective_to is null or ct.effective_to>=vppsone.school_today()))
        when 'house' then p_kind='collection' and exists (select 1 from vppsone.staff_scopes ss
          where ss.staff_profile_id=p_staff and ss.session_label=p_session and ss.kind='house' and ss.value=p_scope->>'value')
        when 'route' then p_kind='collection' and exists (select 1 from vppsone.staff_scopes ss
          where ss.staff_profile_id=p_staff and ss.session_label=p_session and ss.kind='route' and ss.value=p_scope->>'value')
        when 'subject' then p_kind<>'attendance' and exists (select 1 from vppsone.teaching_assignments ta
          where ta.staff_profile_id=p_staff and ta.session_label=p_session and ta.class_id::text=p_scope->>'value'
          and ta.subject_id::text=p_scope->>'subjectId')
        else false end
  );
$$;

create function vppsone.teacher_task_access(p_id uuid, p_staff uuid default null, p_token text default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from vppsone.teacher_tasks t where t.id=p_id and t.revoked_at is null
    and ((p_staff is not null and t.assigned_staff_id=p_staff) or (p_token is not null and t.token=p_token))
    and vppsone.teacher_task_owner(t.assigned_staff_id,t.session_label,t.scope,t.kind)
    and (t.kind<>'collection' or exists (select 1 from vppsone.collection_requests r
      where r.id=t.request_id and r.status='open' and r.archived_at is null and r.assigned_staff_id=t.assigned_staff_id))
    and (t.kind<>'collection' or not exists (
      select 1 from vppsone.collection_request_members cm where cm.request_id=t.request_id and not exists (
        select 1 from vppsone.enrolments e join public.students s on s.id=e.student_id
        where e.student_id=cm.student_id and e.session_label=t.session_label and e.status='enrolled'
          and case t.scope->>'kind'
            when 'common' then true
            when 'class' then e.class_id::text=t.scope->>'value'
            when 'subject' then e.class_id::text=t.scope->>'value'
            when 'house' then to_jsonb(s)->>'house'=t.scope->>'value'
            when 'route' then to_jsonb(s)->>'transport_route_id'=t.scope->>'value'
            else false end))));
$$;

-- Authoritative server preview is saved once. Creation accepts its id and digest,
-- never a browser-supplied replacement roster. No token is minted by a preview.
create function vppsone.prepare_teacher_tasks(p_actor uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v vppsone.teacher_task_previews%rowtype;
begin
  if not exists (select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  if jsonb_typeof(p->'groups') is distinct from 'array' or jsonb_array_length(p->'groups') not between 1 and 60 then raise exception 'tasks:bad_request'; end if;
  insert into vppsone.teacher_task_previews(actor_id,payload) values(p_actor,p) returning * into v;
  return jsonb_build_object('id',v.id,'digest',v.digest);
end; $$;

create function vppsone.create_teacher_tasks(p_actor uuid, p_preview uuid, p_digest text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v vppsone.teacher_task_previews%rowtype; g jsonb; member jsonb; f uuid; r uuid; t vppsone.teacher_tasks%rowtype;
  v_key text; v_kind text; v_session text; v_ids uuid[]; v_fields uuid[]; v_result jsonb:='[]'; v_snapshot jsonb;
  v_paper vppsone.assessment_subjects%rowtype; v_user uuid; v_existing uuid;
begin
  select s.user_id into v_user from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage';
  if not found then raise exception 'tasks:not_permitted'; end if;
  -- The first read only discovers the lock key. Take the session advisory lock
  -- before shared preview/task row locks, including receipt replay.
  select * into v from vppsone.teacher_task_previews where id=p_preview and actor_id=p_actor;
  if not found or v.digest is distinct from p_digest then raise exception 'tasks:preview_changed'; end if;
  v_session:=v.payload->>'session';
  if v_session is null then raise exception 'tasks:bad_request'; end if;
  perform pg_advisory_xact_lock(hashtext('vppsone:teacher-task-create:'||v_session));
  select * into v from vppsone.teacher_task_previews where id=p_preview and actor_id=p_actor for update;
  if not found or v.digest is distinct from p_digest or v.payload->>'session' is distinct from v_session
    then raise exception 'tasks:preview_changed'; end if;
  select s.user_id into v_user from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage';
  if not found then raise exception 'tasks:not_permitted'; end if;
  if v.result is not null then
    -- A retry receipt is not authorization to a task whose owner/scope changed.
    for g in select jsonb_build_object('task', r.value, 'group', v.payload->'groups'->(r.ordinality::int-1))
      from jsonb_array_elements(v.result) with ordinality r loop
      select * into t from vppsone.teacher_tasks where id=(g->'task'->>'id')::uuid for update;
      if not found or t.assigned_staff_id is distinct from (g->'group'->>'teacherId')::uuid
        then raise exception 'tasks:recipient_changed'; end if;
      if t.scope is distinct from g->'group'->'scope' or not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null)
        then raise exception 'tasks:scope_changed' using detail=t.id::text; end if;
      select array_agg(distinct value::uuid order by value::uuid) into v_ids from jsonb_array_elements_text(g->'group'->'studentIds');
      if t.kind='collection' then
        select array_agg(distinct value::uuid order by value::uuid) into v_fields from jsonb_array_elements_text(v.payload->'fieldIds');
        if v_ids is distinct from (select array_agg(student_id order by student_id) from vppsone.collection_request_members where request_id=t.request_id)
          or v_fields is distinct from (select array_agg(field_id order by field_id) from vppsone.collection_request_fields where request_id=t.request_id)
          then raise exception 'tasks:selection_changed'; end if;
      elsif t.kind='marks' then
        if v_ids is distinct from (select array_agg(id order by id) from vppsone.paper_roster(t.paper_id) id) then raise exception 'tasks:selection_changed'; end if;
      else
        if v_ids is distinct from (select array_agg(id order by id) from vppsone.attendance_roster(t.session_label,t.class_id,t.day) id) then raise exception 'tasks:selection_changed'; end if;
      end if;
    end loop;
    return v.result;
  end if;
  if v.expires_at<now() then raise exception 'tasks:preview_expired'; end if;
  v_session:=v.payload->>'session'; v_kind:=v.payload->>'kind';
  if v_kind not in ('collection','marks','attendance') or v_session is null then raise exception 'tasks:bad_request'; end if;
  for g in select value from jsonb_array_elements(v.payload->'groups') loop
    if not vppsone.teacher_task_owner((g->>'teacherId')::uuid,v_session,g->'scope',v_kind) then raise exception 'tasks:assignment_changed'; end if;
    select array_agg(distinct value::uuid order by value::uuid) into v_ids from jsonb_array_elements_text(g->'studentIds');
    if coalesce(cardinality(v_ids),0) not between 1 and 2000 then raise exception 'tasks:empty_scope'; end if;
    -- Every previewed child must still have precisely the previewed enrolment.
    if v_kind='collection' then
    if v_ids is distinct from (select array_agg((m->>'id')::uuid order by (m->>'id')::uuid) from jsonb_array_elements(g->'members') m) then raise exception 'tasks:selection_changed'; end if;
    for member in select value from jsonb_array_elements(g->'members') loop
      if not exists (select 1 from vppsone.enrolments e join public.students s on s.id=e.student_id
        where e.session_label=v_session and e.status='enrolled' and e.student_id=(member->>'id')::uuid
          and e.class_id::text=member->>'classId'
          and coalesce(to_jsonb(s)->>'house','')=coalesce(member->>'house','')
          and coalesce(to_jsonb(s)->>'transport_route_id','')=coalesce(member->>'routeId','')
          and case g->'scope'->>'kind'
            when 'common' then true
            when 'class' then e.class_id::text=g->'scope'->>'value'
            when 'subject' then e.class_id::text=g->'scope'->>'value'
            when 'house' then to_jsonb(s)->>'house'=g->'scope'->>'value'
            when 'route' then to_jsonb(s)->>'transport_route_id'=g->'scope'->>'value'
            else false end) then raise exception 'tasks:selection_changed'; end if;
    end loop;
    end if;
    if v_kind='collection' then
      select array_agg(distinct value::uuid order by value::uuid) into v_fields from jsonb_array_elements_text(v.payload->'fieldIds');
      if coalesce(cardinality(v_fields),0)=0 or exists (select 1 from unnest(v_fields) id
        where not exists (select 1 from vppsone.collection_fields cf where cf.id=id and cf.is_active)) then raise exception 'tasks:fields_changed'; end if;
      v_key:='collection:'||v_session||':'||md5(array_to_string(v_ids,',')||':'||array_to_string(v_fields,','));
    elsif v_kind='marks' then
      select * into v_paper from vppsone.assessment_subjects where id=(v.payload->>'paperId')::uuid;
      if not found or g->'scope'->>'kind'<>'subject' or v_paper.class_id::text<>g->'scope'->>'value'
        or v_paper.subject_id::text<>g->'scope'->>'subjectId'
        or not exists(select 1 from vppsone.assessments a where a.id=v_paper.assessment_id and a.session_label=v_session and a.status='open')
        then raise exception 'tasks:paper_changed'; end if;
      v_key:='marks:'||v_session||':'||v_paper.id::text;
      if v_ids is distinct from (select array_agg(id order by id) from vppsone.paper_roster(v_paper.id) id) then raise exception 'tasks:selection_changed'; end if;
    else
      if g->'scope'->>'kind'<>'class' or (v.payload->>'day')::date>vppsone.school_today() then raise exception 'tasks:bad_request'; end if;
      v_key:='attendance:'||v_session||':'||(g->'scope'->>'value')||':'||(v.payload->>'day');
      if v_ids is distinct from (select array_agg(id order by id) from vppsone.attendance_roster(v_session,(g->'scope'->>'value')::uuid,(v.payload->>'day')::date) id) then raise exception 'tasks:selection_changed'; end if;
    end if;
    select * into t from vppsone.teacher_tasks where source_key=v_key and revoked_at is null for update;
    if found then
      if t.assigned_staff_id is distinct from (g->>'teacherId')::uuid then raise exception 'tasks:recipient_changed'; end if;
      if t.scope is distinct from g->'scope' or not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null)
        then raise exception 'tasks:scope_changed' using detail=t.id::text; end if;
      -- The bounded identity is only a lookup. Exact canonical membership and
      -- fields, not a digest alone, authorize reusing this request.
      if v_kind='collection' and (v_ids is distinct from (select array_agg(student_id order by student_id) from vppsone.collection_request_members where request_id=t.request_id)
        or v_fields is distinct from (select array_agg(field_id order by field_id) from vppsone.collection_request_fields where request_id=t.request_id))
        then raise exception 'tasks:selection_changed'; end if;
      -- An existing task is reused, never silently reassigned by another entry point.
      v_result:=v_result||jsonb_build_array(jsonb_build_object('id',t.id,'reused',true,'teacherId',t.assigned_staff_id)); continue;
    end if;
    r:=null;
    if v_kind='collection' then
      -- Adopt an exact existing collection list rather than create duplicate proposals.
      select cr.id into v_existing from vppsone.collection_requests cr
        where coalesce(v.payload->>'freshRound','false')<>'true' and cr.session_label=v_session and cr.status='open' and cr.archived_at is null
          and cr.assigned_staff_id=(g->>'teacherId')::uuid
          and (select array_agg(cm.student_id order by cm.student_id) from vppsone.collection_request_members cm where cm.request_id=cr.id)=v_ids
          and (select array_agg(cf.field_id order by cf.field_id) from vppsone.collection_request_fields cf where cf.request_id=cr.id)=v_fields
          and not exists(select 1 from vppsone.teacher_tasks tt where tt.request_id=cr.id)
        order by cr.created_at limit 1;
      r:=v_existing;
      if r is null then
        insert into vppsone.collection_requests(session_label,title_hi,title_en,class_label,assigned_staff_id,token,due_date,status,audience_kind,audience_label,created_by)
          values(v_session,v.payload->>'title',v.payload->>'title',g->>'label',(g->>'teacherId')::uuid,
            replace(gen_random_uuid()::text,'-',''),(v.payload->>'dueDate')::date,'open','list',g->>'label',v_user) returning id into r;
        foreach f in array v_fields loop insert into vppsone.collection_request_fields(request_id,field_id) values(r,f); end loop;
        -- SQL joins avoid URL/filter limits. Only approved student_records override fee values.
        insert into vppsone.collection_request_members(request_id,student_id,roll_no,snapshot)
          select r,e.student_id,e.roll_no,coalesce((select jsonb_object_agg(cf.key,coalesce(sr.value,to_jsonb(s)->>cf.fee_column))
            from vppsone.collection_fields cf left join vppsone.student_records sr on sr.student_id=e.student_id and sr.field_id=cf.id
            where cf.id=any(v_fields)),'{}'::jsonb)
          from vppsone.enrolments e join public.students s on s.id=e.student_id
          where e.session_label=v_session and e.status='enrolled' and e.student_id=any(v_ids);
      end if;
    end if;
    -- A concurrent roster change must not silently shrink the committed list.
    if v_kind='collection' and v_ids is distinct from (select array_agg(cm.student_id order by cm.student_id)
      from vppsone.collection_request_members cm where cm.request_id=r) then raise exception 'tasks:selection_changed'; end if;
    insert into vppsone.teacher_tasks(session_label,kind,source_key,request_id,paper_id,class_id,day,scope,assigned_staff_id,title,due_date,created_by)
      values(v_session,v_kind,v_key,r,case when v_kind='marks' then v_paper.id end,
        case when v_kind='attendance' then (g->'scope'->>'value')::uuid end,
        case when v_kind='attendance' then (v.payload->>'day')::date end,g->'scope',(g->>'teacherId')::uuid,
        v.payload->>'title',(v.payload->>'dueDate')::date,p_actor) returning * into t;
    v_result:=v_result||jsonb_build_array(jsonb_build_object('id',t.id,'reused',false,'teacherId',t.assigned_staff_id));
  end loop;
  update vppsone.teacher_task_previews set result=v_result where id=v.id;
  return v_result;
end; $$;

-- Collection answers are teacher proposals, including legacy /r requests
-- without a teacher_tasks row. Only an active administrator may decide them.
-- A refusal rolls back the entire accept_submissions transaction/official write.
create function vppsone.guard_teacher_task_review()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op='UPDATE' and old.status<>'pending' and new.status='pending' then return old; end if;
  if new.status='pending' and exists(select 1 from vppsone.teacher_tasks t where t.request_id=new.request_id
    and not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null)) then raise exception 'tasks:not_permitted'; end if;
  if new.status<>'pending'
    and not exists(select 1 from vppsone.staff_profiles s where s.id=new.decided_by and s.is_active and s.role='admin')
    then raise exception 'tasks:admin_review_required'; end if;
  return new;
end; $$;
create trigger teacher_task_review_admin before insert or update on vppsone.collection_submissions
  for each row execute function vppsone.guard_teacher_task_review();
revoke all on function vppsone.guard_teacher_task_review() from public,anon,authenticated;

-- A task link can only call the same canonical audited writers as login.
create function vppsone.save_teacher_task(p_id uuid, p_staff uuid, p_token text, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t vppsone.teacher_tasks%rowtype;
begin
  select * into t from vppsone.teacher_tasks where id=p_id for update;
  if not found or not vppsone.teacher_task_access(p_id,p_staff,p_token) then return jsonb_build_object('ok',false,'reason','not_permitted'); end if;
  if t.kind='collection' then
    if p->>'kind' is distinct from 'collection' or p->>'request_id' is distinct from t.request_id::text then
      return jsonb_build_object('ok',false,'reason','not_permitted'); end if;
    -- Task then request: retain the original public capability across every
    -- wait, and never substitute a replacement assignee's request token.
    perform 1 from vppsone.collection_requests where id=t.request_id for update;
    if not found or not vppsone.teacher_task_access(p_id,p_staff,p_token) then
      return jsonb_build_object('ok',false,'reason','not_permitted'); end if;
    return jsonb_build_object('ok',true,'written',vppsone.record_collection_answers(t.request_id,p->>'request_token',p->'answers'));
  elsif t.kind='marks' then
    if p->>'paper_id' is distinct from t.paper_id::text or p->>'kind' not in ('draft','submit','correction') then return jsonb_build_object('ok',false,'reason','not_permitted'); end if;
    return vppsone.save_marks(p||jsonb_build_object('actor_staff_id',t.assigned_staff_id));
  elsif t.kind='attendance' then
    if p->>'class_id' is distinct from t.class_id::text or p->>'day' is distinct from t.day::text
      or p->>'session_label' is distinct from t.session_label then return jsonb_build_object('ok',false,'reason','not_permitted'); end if;
    return vppsone.save_attendance_register((p-'correction_request_id'-'decision_note')||jsonb_build_object('actor_staff_id',t.assigned_staff_id));
  end if;
  return jsonb_build_object('ok',false,'reason','bad_request');
end; $$;

-- Shared submission handler, including /r links. Upsert preserves decided rows
-- in the transaction, so an offline retry cannot reopen an approved answer.
create function vppsone.record_collection_answers(p_request uuid, p_token text, p_answers jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare r vppsone.collection_requests%rowtype; t vppsone.teacher_tasks%rowtype; n integer;
begin
  select * into t from vppsone.teacher_tasks where request_id=p_request for update;
  if found and not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null) then raise exception 'tasks:not_permitted'; end if;
  select * into r from vppsone.collection_requests where id=p_request for update;
  if not found or r.status<>'open' or r.archived_at is not null or r.token is distinct from p_token then raise exception 'tasks:not_permitted'; end if;
  if t.id is not null and not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null) then raise exception 'tasks:not_permitted'; end if;
  if r.assigned_staff_id is not null and not exists(select 1 from vppsone.staff_profiles s where s.id=r.assigned_staff_id and s.is_active) then raise exception 'tasks:not_permitted'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' or jsonb_array_length(p_answers)>40000 then raise exception 'tasks:bad_request'; end if;
  if exists(select 1 from jsonb_array_elements(p_answers) a where
    not exists(select 1 from vppsone.collection_request_fields f where f.request_id=r.id and f.field_id=(a->>'fieldId')::uuid)
    or not (exists(select 1 from vppsone.collection_request_members m where m.request_id=r.id and m.student_id=(a->>'studentId')::uuid)
      or (not exists(select 1 from vppsone.collection_request_members m where m.request_id=r.id)
        and exists(select 1 from vppsone.enrolments e where e.session_label=r.session_label and e.class_id=r.class_id and e.status='enrolled' and e.student_id=(a->>'studentId')::uuid)))) then raise exception 'tasks:out_of_scope'; end if;
  insert into vppsone.collection_submissions(request_id,student_id,field_id,value,previous_value,status,submitted_at)
    select r.id,(a->>'studentId')::uuid,(a->>'fieldId')::uuid,a->>'value',a->>'previousValue','pending',now()
    from jsonb_array_elements(p_answers) a
    on conflict(request_id,student_id,field_id) do update set value=excluded.value,submitted_at=excluded.submitted_at
    where vppsone.collection_submissions.status='pending';
  get diagnostics n=row_count; return n;
end; $$;

create function vppsone.manage_teacher_task(p_actor uuid, p_id uuid, p_teacher uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare t vppsone.teacher_tasks%rowtype;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into t from vppsone.teacher_tasks where id=p_id for update;
  if not found then raise exception 'tasks:not_found'; end if;
  -- Acquire every mutation lock in task/request order before the authoritative
  -- actor and recipient checks. Either row may have blocked this transaction.
  if t.request_id is not null then
    perform 1 from vppsone.collection_requests where id=t.request_id for update;
    if not found then raise exception 'tasks:not_found'; end if;
  end if;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  if p_teacher is not null and not vppsone.teacher_task_owner(p_teacher,t.session_label,t.scope,t.kind) then raise exception 'tasks:not_owner'; end if;
  update vppsone.teacher_tasks set assigned_staff_id=coalesce(p_teacher,assigned_staff_id),
    revoked_at=case when p_teacher is null then now() end, opened_at=null,
    token=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','') where id=p_id;
  if t.request_id is not null then
    update vppsone.collection_requests set assigned_staff_id=coalesce(p_teacher,assigned_staff_id),
      status=case when p_teacher is null then 'closed'::vppsone.request_status else 'open'::vppsone.request_status end,
      token=replace(gen_random_uuid()::text,'-',''),token_rotated_at=now() where id=t.request_id;
  end if;
end; $$;

-- Explicit recovery of an existing collection list after automatic ownership
-- changes. The same canonical request is retained; both capabilities rotate.
create function vppsone.delegate_teacher_task_list(p_actor uuid, p_id uuid, p_teacher uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare t vppsone.teacher_tasks%rowtype;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into t from vppsone.teacher_tasks where id=p_id for update;
  if not found or t.kind<>'collection' or t.revoked_at is not null then raise exception 'tasks:bad_request'; end if;
  update vppsone.teacher_tasks set scope='{"kind":"common","value":"selected"}'::jsonb where id=p_id;
  perform vppsone.manage_teacher_task(p_actor,p_id,p_teacher);
  if not vppsone.teacher_task_access(p_id,p_teacher,null) then raise exception 'tasks:selection_changed'; end if;
end; $$;
revoke all on function vppsone.delegate_teacher_task_list(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function vppsone.delegate_teacher_task_list(uuid,uuid,uuid) to service_role;

-- An explicit new round keeps decided proposals immutable. Revoke and create
-- happen in one transaction; failure preserves the previous usable request.
create function vppsone.restart_teacher_task(p_actor uuid, p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t vppsone.teacher_tasks%rowtype; v_session text; v_ids jsonb; v_fields jsonb; v_members jsonb; preview jsonb; result jsonb;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role
    where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  -- Discover the key without owning a row lock. Nested create takes this same
  -- transaction lock reentrantly; it must never wait for it while owning a row.
  select session_label into v_session from vppsone.teacher_tasks where id=p_id;
  if not found then raise exception 'tasks:bad_request'; end if;
  perform pg_advisory_xact_lock(hashtext('vppsone:teacher-task-create:'||v_session));
  select * into t from vppsone.teacher_tasks where id=p_id for update;
  if not found or t.kind<>'collection' or t.session_label is distinct from v_session then raise exception 'tasks:bad_request'; end if;
  if not vppsone.teacher_task_owner(t.assigned_staff_id,t.session_label,t.scope,t.kind) then raise exception 'tasks:assignment_changed'; end if;
  select jsonb_agg(student_id order by student_id) into v_ids from vppsone.collection_request_members where request_id=t.request_id;
  select jsonb_agg(field_id order by field_id) into v_fields from vppsone.collection_request_fields where request_id=t.request_id;
  select jsonb_agg(jsonb_build_object('id',e.student_id,'classId',e.class_id,'house',to_jsonb(s)->>'house','routeId',to_jsonb(s)->>'transport_route_id') order by e.student_id)
    into v_members from vppsone.collection_request_members cm join vppsone.enrolments e on e.student_id=cm.student_id
      and e.session_label=t.session_label and e.status='enrolled' join public.students s on s.id=e.student_id where cm.request_id=t.request_id;
  preview:=vppsone.prepare_teacher_tasks(p_actor,jsonb_build_object('session',t.session_label,'kind','collection','freshRound',true,'title',t.title,'dueDate',null,
    'fieldIds',v_fields,'groups',jsonb_build_array(jsonb_build_object('teacherId',t.assigned_staff_id,'label',t.title,'scope',t.scope,'studentIds',v_ids,'members',v_members))));
  perform vppsone.manage_teacher_task(p_actor,p_id,null);
  result:=vppsone.create_teacher_tasks(p_actor,(preview->>'id')::uuid,preview->>'digest');
  return result->0;
end; $$;
revoke all on function vppsone.restart_teacher_task(uuid,uuid) from public,anon,authenticated;
grant execute on function vppsone.restart_teacher_task(uuid,uuid) to service_role;

revoke all on function vppsone.teacher_task_owner(uuid,text,jsonb,text),vppsone.teacher_task_access(uuid,uuid,text),
  vppsone.prepare_teacher_tasks(uuid,jsonb),vppsone.create_teacher_tasks(uuid,uuid,text),vppsone.save_teacher_task(uuid,uuid,text,jsonb),
  vppsone.record_collection_answers(uuid,text,jsonb),vppsone.manage_teacher_task(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function vppsone.teacher_task_owner(uuid,text,jsonb,text),vppsone.teacher_task_access(uuid,uuid,text),
  vppsone.prepare_teacher_tasks(uuid,jsonb),vppsone.create_teacher_tasks(uuid,uuid,text),vppsone.save_teacher_task(uuid,uuid,text,jsonb),
  vppsone.record_collection_answers(uuid,text,jsonb),vppsone.manage_teacher_task(uuid,uuid,uuid) to service_role;

-- ======================================================== migrations/20261016080000_profile_photos.sql
-- Authored locally; unapplied. Reuses the existing PRIVATE vppsone-photos bucket.
-- The collection answer is the only task progress authority. A proposal is its
-- immutable uploaded-byte attachment, never a second task or official portrait.
insert into vppsone.collection_fields(key,label_hi,label_en,input_type,mode,is_active,sort_order)
values('student_photo','विद्यार्थी का फोटो','Student photograph','text','collect',true,90)
on conflict(key) do nothing;

create table vppsone.photo_proposals (
  command_id uuid primary key,
  request_id uuid not null references vppsone.collection_requests(id),
  student_id uuid not null,
  field_id uuid not null references vppsone.collection_fields(id),
  actor_staff_id uuid not null references vppsone.staff_profiles(id),
  capability_hash text not null,
  payload jsonb not null,
  expected_current uuid,
  decision text not null default 'pending' check(decision in('pending','accepted','rejected')),
  decided_by uuid references vppsone.staff_profiles(id),
  created_at timestamptz not null default now()
);
create index photo_proposals_request on vppsone.photo_proposals(request_id,student_id);
alter table vppsone.photo_proposals enable row level security;
revoke all on vppsone.photo_proposals from anon,authenticated;
grant all on vppsone.photo_proposals to service_role;

create function vppsone.guard_photo_answer() returns trigger
language plpgsql security definer set search_path='' as $$
declare p vppsone.photo_proposals%rowtype;
begin
  if not exists(select 1 from vppsone.collection_fields f where f.id=new.field_id and f.key='student_photo') then return new; end if;
  select * into p from vppsone.photo_proposals where command_id::text=new.value
    and request_id=new.request_id and student_id=new.student_id and field_id=new.field_id;
  if not found then raise exception 'photos:unbound'; end if;
  if tg_op='UPDATE' and old.status<>'pending' and (new.value is distinct from old.value or new.status is distinct from old.status) then raise exception 'photos:decided'; end if;
  if new.status::text is distinct from p.decision then raise exception 'photos:use_photo_review'; end if;
  if new.status<>'pending' and (new.decided_by is distinct from p.decided_by or not exists(
    select 1 from vppsone.staff_profiles s where s.id=new.decided_by and s.is_active and s.role='admin')) then raise exception 'photos:admin_required'; end if;
  if new.status='accepted' and not exists(select 1 from vppsone.student_photos s where s.command_id=p.command_id and s.student_id=p.student_id) then raise exception 'photos:unplaced'; end if;
  return new;
end; $$;
create trigger photo_answer_bound before insert or update on vppsone.collection_submissions
for each row execute function vppsone.guard_photo_answer();

create function vppsone.submit_student_photo(p_request uuid,p_token text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r vppsone.collection_requests%rowtype; t vppsone.teacher_tasks%rowtype;
  prior vppsone.photo_proposals%rowtype; answer vppsone.collection_submissions%rowtype;
  cmd uuid := (p->>'command_id')::uuid; student uuid := (p->>'student_id')::uuid; field uuid;
begin
  -- Same task -> request lock order as record_collection_answers/reassignment.
  select * into t from vppsone.teacher_tasks where request_id=p_request for update;
  if found and not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null) then raise exception 'photos:not_permitted'; end if;
  select * into r from vppsone.collection_requests where id=p_request for update;
  if not found or r.status<>'open' or r.archived_at is not null or r.token is distinct from p_token
    or not exists(select 1 from vppsone.staff_profiles where id=r.assigned_staff_id and is_active)
    or not exists(select 1 from vppsone.collection_request_members where request_id=r.id and student_id=student)
    then raise exception 'photos:not_permitted'; end if;
  select f.id into field from vppsone.collection_fields f join vppsone.collection_request_fields rf on rf.field_id=f.id
    where rf.request_id=r.id and f.key='student_photo';
  if field is null then raise exception 'photos:not_permitted'; end if;
  if cmd is null or p->>'content_type' is distinct from 'image/jpeg' or coalesce((p->>'byte_size')::int,0) not between 1 and 204800
    or coalesce((p->>'width')::int,0) not between 1 and 600 or coalesce((p->>'height')::int,0) not between 1 and 600
    or coalesce(p->>'sha256','') !~ '^[0-9a-f]{64}$'
    or p->>'session_label' is distinct from r.session_label or coalesce(p->>'source','') not in('camera','file','folder')
    or p->>'storage_path' is distinct from 'proposals/'||r.id::text||'/'||student::text||'/'||cmd::text||'.jpg'
    then raise exception 'photos:bad_request'; end if;
  perform pg_advisory_xact_lock(hashtext('vppsone:photo-proposal:'||cmd::text));
  select * into prior from vppsone.photo_proposals where command_id=cmd;
  if found then
    if prior.request_id=r.id and prior.actor_staff_id=r.assigned_staff_id and prior.capability_hash=md5(r.token)
      and prior.payload=p then return jsonb_build_object('ok',true,'proposalId',cmd,'replayed',true); end if;
    raise exception 'photos:id_reused';
  end if;
  select * into answer from vppsone.collection_submissions where request_id=r.id and student_id=student and field_id=field for update;
  if answer.status is not null and answer.status<>'pending' then raise exception 'photos:decided'; end if;
  if answer.value is distinct from nullif(p->>'expected_proposal','') then raise exception 'photos:stale'; end if;
  insert into vppsone.photo_proposals(command_id,request_id,student_id,field_id,actor_staff_id,capability_hash,payload,expected_current)
    values(cmd,r.id,student,field,r.assigned_staff_id,md5(r.token),p,nullif(p->>'expected_current','')::uuid);
  perform vppsone.record_collection_answers(r.id,r.token,jsonb_build_array(jsonb_build_object(
    'studentId',student,'fieldId',field,'value',cmd::text,'previousValue',p->>'expected_current')));
  return jsonb_build_object('ok',true,'proposalId',cmd,'replayed',false);
end; $$;

create function vppsone.review_student_photo(p_actor uuid,p_proposal uuid,p_accept boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare proposal vppsone.photo_proposals%rowtype; t vppsone.teacher_tasks%rowtype;
  answer vppsone.collection_submissions%rowtype; result jsonb; request uuid;
begin
  if not exists(select 1 from vppsone.staff_profiles where id=p_actor and is_active and role='admin') then raise exception 'photos:admin_required'; end if;
  select request_id into request from vppsone.photo_proposals where command_id=p_proposal;
  select * into t from vppsone.teacher_tasks where request_id=request for update;
  if found and not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null) then raise exception 'photos:not_permitted'; end if;
  perform 1 from vppsone.collection_requests where id=request and status='open' and archived_at is null for update;
  if not found then raise exception 'photos:not_permitted'; end if;
  select * into proposal from vppsone.photo_proposals where command_id=p_proposal for update;
  if not found then raise exception 'photos:not_found'; end if;
  select * into answer from vppsone.collection_submissions where request_id=request and student_id=proposal.student_id and field_id=proposal.field_id for update;
  if answer.value is distinct from p_proposal::text then raise exception 'photos:stale'; end if;
  if proposal.decision<>'pending' then
    if (proposal.decision='accepted')=p_accept then return jsonb_build_object('ok',true,'replayed',true); end if;
    raise exception 'photos:decided';
  end if;
  if p_accept then
    result := vppsone.place_student_photo(proposal.payload||jsonb_build_object('actor_staff_id',p_actor,
      'payload_hash',md5(proposal.payload::text),'expected_current',proposal.expected_current));
    if result->>'ok' is distinct from 'true' then return result; end if;
  end if;
  update vppsone.photo_proposals set decision=case when p_accept then 'accepted' else 'rejected' end,decided_by=p_actor where command_id=p_proposal;
  update vppsone.collection_submissions set status=(case when p_accept then 'accepted' else 'rejected' end)::vppsone.submission_status,
    decided_by=p_actor,decided_at=now() where id=answer.id;
  return jsonb_build_object('ok',true,'replayed',false);
end; $$;

revoke all on function vppsone.guard_photo_answer() from public,anon,authenticated;
revoke all on function vppsone.submit_student_photo(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function vppsone.review_student_photo(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.submit_student_photo(uuid,text,jsonb) to service_role;
grant execute on function vppsone.review_student_photo(uuid,uuid,boolean) to service_role;

-- Self photo follows existing self-preference policy. Editing another person
-- requires the current staff:manage matrix grant; no role/activation write.
create table vppsone.staff_photos (
  command_id uuid primary key,
  staff_id uuid not null references vppsone.staff_profiles(id),
  actor_staff_id uuid not null references vppsone.staff_profiles(id),
  payload jsonb not null,
  replaced_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index staff_photos_current on vppsone.staff_photos(staff_id) where replaced_at is null;
alter table vppsone.staff_photos enable row level security;
revoke all on vppsone.staff_photos from anon,authenticated;
grant all on vppsone.staff_photos to service_role;
create function vppsone.save_staff_photo(p_actor uuid,p_staff uuid,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior vppsone.staff_photos%rowtype; current_id uuid; cmd uuid := (p->>'command_id')::uuid;
begin
  if not exists(select 1 from vppsone.staff_profiles s where s.id=p_actor and s.is_active and
    (s.id=p_staff or exists(select 1 from vppsone.role_permissions rp where rp.role=s.role and rp.permission='staff:manage')))
    or not exists(select 1 from vppsone.staff_profiles where id=p_staff)
    then raise exception 'photos:not_permitted'; end if;
  if cmd is null or p->>'content_type' is distinct from 'image/jpeg' or coalesce((p->>'byte_size')::int,0) not between 1 and 204800
    or coalesce((p->>'width')::int,0) not between 1 and 600 or coalesce((p->>'height')::int,0) not between 1 and 600
    or coalesce(p->>'sha256','') !~ '^[0-9a-f]{64}$'
    or p->>'storage_path' is distinct from 'staff/'||p_staff::text||'/'||cmd::text||'.jpg'
    then raise exception 'photos:bad_request'; end if;
  perform pg_advisory_xact_lock(hashtext('vppsone:staff-photo-command:'||cmd::text));
  perform pg_advisory_xact_lock(hashtext('vppsone:staff-photo:'||p_staff::text));
  -- An advisory wait can outlive activation or permission changes. Re-read
  -- current authority before both receipt replay and any photo/history write.
  if not exists(select 1 from vppsone.staff_profiles s where s.id=p_actor and s.is_active and
    (s.id=p_staff or exists(select 1 from vppsone.role_permissions rp where rp.role=s.role and rp.permission='staff:manage')))
    or not exists(select 1 from vppsone.staff_profiles where id=p_staff)
    then raise exception 'photos:not_permitted'; end if;
  select * into prior from vppsone.staff_photos where command_id=cmd;
  if found then
    if prior.staff_id=p_staff and prior.actor_staff_id=p_actor and prior.payload=p then return jsonb_build_object('ok',true,'replayed',true); end if;
    raise exception 'photos:id_reused';
  end if;
  select command_id into current_id from vppsone.staff_photos where staff_id=p_staff and replaced_at is null;
  if current_id is distinct from nullif(p->>'expected_current','')::uuid then raise exception 'photos:stale'; end if;
  update vppsone.staff_photos set replaced_at=now() where staff_id=p_staff and replaced_at is null;
  insert into vppsone.staff_photos(command_id,staff_id,actor_staff_id,payload) values(cmd,p_staff,p_actor,p);
  return jsonb_build_object('ok',true,'replayed',false);
end; $$;
revoke all on function vppsone.save_staff_photo(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function vppsone.save_staff_photo(uuid,uuid,jsonb) to service_role;

-- A direct class-teacher avatar edit joins existing assigned photo work first.
-- It can otherwise ask only this teacher, about this one currently owned child.
create function vppsone.ensure_student_photo_task(p_actor uuid,p_student uuid,p_session text) returns uuid
language plpgsql security definer set search_path='' as $$
declare t vppsone.teacher_tasks%rowtype; class uuid; field uuid; request uuid; task uuid; source text; actor_user uuid;
begin
  perform pg_advisory_xact_lock(hashtext('vppsone:teacher-task-create:'||p_session));
  select e.class_id into class from vppsone.enrolments e join vppsone.class_teachers ct on ct.class_id=e.class_id and ct.session_label=e.session_label
    join vppsone.staff_profiles s on s.id=ct.staff_profile_id
    where e.student_id=p_student and e.session_label=p_session and e.status='enrolled' and ct.staff_profile_id=p_actor
      and ct.role='class_teacher' and ct.effective_from<=vppsone.school_today() and (ct.effective_to is null or ct.effective_to>=vppsone.school_today())
      and s.is_active and (s.is_teaching or s.role='teacher') limit 1;
  if class is null then raise exception 'photos:not_permitted'; end if;
  select id into field from vppsone.collection_fields where key='student_photo' and is_active;
  if field is null then raise exception 'photos:unavailable'; end if;
  for t in select tt.* from vppsone.teacher_tasks tt
    join vppsone.collection_request_members rm on rm.request_id=tt.request_id and rm.student_id=p_student
    join vppsone.collection_request_fields rf on rf.request_id=tt.request_id and rf.field_id=field
    where tt.assigned_staff_id=p_actor and tt.session_label=p_session and tt.revoked_at is null order by tt.created_at for update of tt
  loop
    if vppsone.teacher_task_access(t.id,p_actor,null) then return t.id; end if;
  end loop;
  source := 'collection:'||p_session||':'||md5(p_student::text||':'||field::text);
  if exists(select 1 from vppsone.teacher_tasks where source_key=source and revoked_at is null) then raise exception 'photos:assignment_changed'; end if;
  select user_id into actor_user from vppsone.staff_profiles where id=p_actor;
  insert into vppsone.collection_requests(session_label,title_hi,title_en,class_id,class_label,assigned_staff_id,token,status,audience_kind,audience_label,created_by)
    values(p_session,'विद्यार्थी का फोटो','Student photograph',class,'',p_actor,replace(gen_random_uuid()::text,'-',''),'open','class','',actor_user) returning id into request;
  insert into vppsone.collection_request_fields(request_id,field_id) values(request,field);
  insert into vppsone.collection_request_members(request_id,student_id,roll_no,snapshot)
    select request,p_student,e.roll_no,jsonb_build_object('student_photo',(select id::text from vppsone.student_photos where student_id=p_student and replaced_at is null))
    from vppsone.enrolments e where e.student_id=p_student and e.session_label=p_session and e.class_id=class and e.status='enrolled';
  insert into vppsone.teacher_tasks(session_label,kind,source_key,request_id,scope,assigned_staff_id,title,created_by)
    values(p_session,'collection',source,request,jsonb_build_object('kind','class','value',class),p_actor,'Student photograph',p_actor) returning id into task;
  if not vppsone.teacher_task_access(task,p_actor,null) then raise exception 'photos:not_permitted'; end if;
  return task;
end; $$;
revoke all on function vppsone.ensure_student_photo_task(uuid,uuid,text) from public,anon,authenticated;
grant execute on function vppsone.ensure_student_photo_task(uuid,uuid,text) to service_role;

-- ======================================================== migrations/20261016090000_teacher_task_delivery.sql
-- Task delivery extends the existing collection outbox. No new sending queue.
-- Depends on teacher_tasks and the existing collection message tables. Unapplied.
alter table vppsone.message_sends
  add column task_id uuid references vppsone.teacher_tasks(id),
  add column task_snapshot jsonb,
  add column task_round text,
  add column task_delivery_state text check (task_delivery_state in ('ready','unknown','rejected','accepted','manual_opened','human_confirmed')),
  add column task_transport text check (task_transport in ('aisensy','manual')),
  add column task_history jsonb not null default '[]';
create unique index message_sends_task_round on vppsone.message_sends(task_id,(task_snapshot->>'version'),task_round) where task_id is not null;
-- Existing screens/RLS must not expose a task's private review or bypass its gates.
create policy message_sends_task_private on vppsone.message_sends as restrictive for select to authenticated using(task_id is null);

-- Each campaign is one exact recipient-language body, independent of the office
-- reader's language. Both render columns deliberately carry that same body.
insert into vppsone.message_templates(code,label_hi,label_en,body_hi,body_en,variables,has_url_button,audience,is_active,sort_order)
select code,label_hi,label_en,body,body,array['teacher','task','due'],true,'staff',true,sort_order from (values
('vppsone_teacher_task_en_v1','शिक्षक कार्य · अंग्रेज़ी','Teacher task · English','{{1}}, task: {{2}}. Due: {{3}}. Use the button to open your work.',80),
('vppsone_teacher_task_hi_v1','शिक्षक कार्य · हिंदी','Teacher task · Hindi','{{1}}, कार्य: {{2}}। अंतिम तिथि: {{3}}। काम खोलने के लिए बटन दबाएँ।',81),
('vppsone_teacher_task_both_v1','शिक्षक कार्य · दोनों','Teacher task · Both','{{1}}, कार्य / Task: {{2}}। अंतिम तिथि / Due: {{3}}। काम खोलने के लिए बटन दबाएँ / Use the button to open your work.',82),
('vppsone_teacher_task_reminder_en_v1','कार्य याद · अंग्रेज़ी','Task reminder · English','{{1}}, work is still pending: {{2}}. Due: {{3}}. Use the button to open your work.',83),
('vppsone_teacher_task_reminder_hi_v1','कार्य याद · हिंदी','Task reminder · Hindi','{{1}}, कार्य अभी बाकी है: {{2}}। अंतिम तिथि: {{3}}। काम खोलने के लिए बटन दबाएँ।',84),
('vppsone_teacher_task_reminder_both_v1','कार्य याद · दोनों','Task reminder · Both','{{1}}, कार्य अभी बाकी है / Work is still pending: {{2}}। अंतिम तिथि / Due: {{3}}। काम खोलने के लिए बटन दबाएँ / Use the button to open your work.',85)
) as contracts(code,label_hi,label_en,body,sort_order);

create function vppsone.guard_teacher_task_delivery() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.task_id is null and exists(select 1 from vppsone.message_templates where id=new.template_id and code ~ '^[A-Za-z0-9_-]+_teacher_task(_|$)') then
    raise exception 'task_delivery:review_required';
  end if;
  if new.task_id is null and new.request_id is not null
    and current_setting('vppsone.task_delivery',true) is distinct from new.id::text
    and exists(select 1 from vppsone.teacher_tasks where request_id=new.request_id)
    and (new.status='sent' or (new.provider_message_id is not null and (tg_op='INSERT' or new.provider_message_id is distinct from old.provider_message_id))) then
    raise exception 'task_delivery:review_required';
  end if;
  if (new.task_id is not null or (tg_op='UPDATE' and old.task_id is not null))
    and current_setting('vppsone.task_delivery',true) is distinct from new.id::text then
    raise exception 'task_delivery:rpc_required';
  end if;
  return new;
end; $$;
create trigger teacher_task_delivery_guard before insert or update on vppsone.message_sends for each row execute function vppsone.guard_teacher_task_delivery();

-- Legacy requests can be adopted after a send became uncertain. Keep that gate.
create function vppsone.teacher_task_has_unknown_delivery(p_task uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from vppsone.message_sends m join vppsone.teacher_tasks t on (m.task_id=t.id or m.request_id=t.request_id) where t.id=p_task and
    (m.task_delivery_state='unknown' or (m.task_delivery_state is null and m.status='failed' and
      (m.provider_message_id is not null or not (coalesce(m.error,'') like 'Provider rejected this request: %'
        or coalesce(m.error,'') ~ '^The provider refused it \((400|401|403|404|422|429)\)\.$')))));
$$;

create function vppsone.teacher_task_delivery_snapshot(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t vppsone.teacher_tasks%rowtype; s vppsone.staff_profiles%rowtype; phone text; expected int:=0; answered int:=0; approved int:=0; rejected int:=0; pending boolean; opened timestamptz; request_token text; scope_version text;
  student_count int:=0; fields jsonb:='[]'; review_scope jsonb; class_id uuid; subject_id uuid; class_label text; subject jsonb;
begin
  select * into t from vppsone.teacher_tasks where id=p_id;
  if not found or not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null) then return null; end if;
  select * into s from vppsone.staff_profiles where id=t.assigned_staff_id;
  phone:=regexp_replace(coalesce(nullif(trim(s.whatsapp_phone),''),s.phone,''),'[^0-9]','','g');
  if length(phone)=12 and left(phone,2)='91' then phone:=substr(phone,3); end if;
  if length(phone)=11 and left(phone,1)='0' then phone:=substr(phone,2); end if;
  opened:=t.opened_at;
  if t.kind='collection' then
    select count(*)::int into student_count from vppsone.collection_request_members where request_id=t.request_id;
    select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'hi',f.label_hi,'en',f.label_en) order by f.id),'[]') into fields
      from vppsone.collection_request_fields rf join vppsone.collection_fields f on f.id=rf.field_id where rf.request_id=t.request_id;
    select r.class_label into class_label from vppsone.collection_requests r where r.id=t.request_id;
    select count(*)::int into expected from vppsone.collection_request_members m cross join vppsone.collection_request_fields f where m.request_id=t.request_id and f.request_id=t.request_id;
    select count(*)::int,count(*) filter(where a.status='accepted')::int,count(*) filter(where a.status='rejected')::int into answered,approved,rejected
      from vppsone.collection_submissions a join vppsone.collection_request_members m on m.request_id=a.request_id and m.student_id=a.student_id
      join vppsone.collection_request_fields f on f.request_id=a.request_id and f.field_id=a.field_id where a.request_id=t.request_id;
    -- collection_requests.opened_at is the office's open-for-work timestamp.
    -- Only teacher_tasks.opened_at records authorized teacher access.
    select r.token into request_token from vppsone.collection_requests r where r.id=t.request_id;
    pending:=answered<expected;
    select md5(coalesce((select string_agg(m.student_id::text,',' order by m.student_id) from vppsone.collection_request_members m where m.request_id=t.request_id),'')||':'||coalesce((select string_agg(f.field_id::text,',' order by f.field_id) from vppsone.collection_request_fields f where f.request_id=t.request_id),'')) into scope_version;
  elsif t.kind='marks' then
    select a.entry_status is distinct from 'submitted',a.class_id,a.subject_id into pending,class_id,subject_id from vppsone.assessment_subjects a where a.id=t.paper_id;
    select count(*)::int,md5(string_agg(r::text,',' order by r)) into student_count,scope_version from vppsone.paper_roster(t.paper_id) r;
    select jsonb_build_object('hi',su.name_hi,'en',su.name_en) into subject from vppsone.subjects su where su.id=subject_id;
  else
    pending:=not exists(select 1 from vppsone.attendance_registers a where a.session_label=t.session_label and a.class_id=t.class_id and a.day=t.day and a.period is null and a.revision>0);
    class_id:=t.class_id;
    select count(*)::int,md5(string_agg(r::text,',' order by r)) into student_count,scope_version from vppsone.attendance_roster(t.session_label,t.class_id,t.day) r;
  end if;
  if class_id is not null then
    -- Display metadata only; no public/fee write or schema change.
    select concat_ws(' ',c.class_name,nullif(c.section,''),nullif(c.stream_name,'')) into class_label from public.classes c where c.id=class_id;
  end if;
  review_scope:=jsonb_build_object('session',t.session_label,'classLabel',class_label,'subject',subject,'day',t.day);
  return jsonb_build_object('taskId',t.id,'teacherId',t.assigned_staff_id,'phone',phone,'name',s.display_name,'title',t.title,'due',t.due_date,'language',coalesce(s.preferred_language::text,'both'),
    'studentCount',student_count,'fields',fields,'scope',review_scope,
    'pending',coalesce(pending,false),'expected',expected,'answered',answered,'approved',approved,'rejected',rejected,'openedAt',opened,
    'version',md5(jsonb_build_array(t.token,request_token,t.assigned_staff_id,t.scope,scope_version,t.title,t.due_date,phone,s.updated_at,s.display_name,s.preferred_language,student_count,fields,review_scope,t.kind,t.paper_id,class_id,subject_id)::text));
end; $$;

create function vppsone.mark_teacher_task_opened(p_id uuid,p_staff uuid default null,p_token text default null,p_request_token text default null) returns boolean language plpgsql security definer set search_path='' as $$
declare task vppsone.teacher_tasks%rowtype;
begin
  select * into task from vppsone.teacher_tasks where id=p_id or request_id=p_id for update;
  if not found then return false; end if;
  perform 1 from vppsone.staff_profiles where id=task.assigned_staff_id for share;
  if p_request_token is not null then
    if not exists(select 1 from vppsone.collection_requests r where r.id=task.request_id and r.token=p_request_token) then return false; end if;
    if not vppsone.teacher_task_access(task.id,task.assigned_staff_id,null) then return false; end if;
  elsif not vppsone.teacher_task_access(task.id,p_staff,p_token) then return false;
  end if;
  update vppsone.teacher_tasks set opened_at=coalesce(opened_at,now()) where id=task.id;
  return true;
end; $$;

create function vppsone.teacher_task_share_link(p_actor uuid,p_task uuid) returns text language plpgsql security definer set search_path='' as $$
declare task vppsone.teacher_tasks%rowtype;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into task from vppsone.teacher_tasks where id=p_task for update;
  perform 1 from vppsone.staff_profiles where id in(p_actor,task.assigned_staff_id) order by id for share;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  if not found or not vppsone.teacher_task_access(task.id,task.assigned_staff_id,null) then return null; end if;
  if vppsone.teacher_task_has_unknown_delivery(p_task) then return null; end if;
  return '/t/tasks/'||task.token;
end; $$;

create function vppsone.prepare_teacher_task_delivery(p_actor uuid,p_task uuid,p_kind text) returns jsonb language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; preview vppsone.teacher_task_previews%rowtype; template vppsone.message_templates%rowtype; params text[];
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  if p_kind not in ('initial','reminder') or p_kind is null then raise exception 'task_delivery:kind'; end if;
  perform 1 from vppsone.teacher_tasks where id=p_task for update;
  perform 1 from vppsone.staff_profiles where id in(p_actor,(select assigned_staff_id from vppsone.teacher_tasks where id=p_task)) order by id for share;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  snapshot:=vppsone.teacher_task_delivery_snapshot(p_task);
  if snapshot is null then return jsonb_build_object('ok',false,'reason','changed'); end if;
  if not (snapshot->>'pending')::boolean then return jsonb_build_object('ok',false,'reason','complete'); end if;
  if snapshot->>'phone' !~ '^[6-9][0-9]{9}$' then return jsonb_build_object('ok',false,'reason','phone'); end if;
  select * into template from vppsone.message_templates where code='vppsone_teacher_task'||case when p_kind='reminder' then '_reminder' else '' end||'_'||(snapshot->>'language')||'_v1' and is_active and audience='staff';
  if not found then return jsonb_build_object('ok',false,'reason','unavailable'); end if;
  snapshot:=snapshot||jsonb_build_object('authorityVersion',snapshot->>'version','templateVersion',md5(to_jsonb(template)::text),'version',md5((snapshot->>'version')||md5(to_jsonb(template)::text)));
  params:=array[snapshot->>'name',snapshot->>'title',coalesce(snapshot->>'due','—')];
  insert into vppsone.teacher_task_previews(actor_id,payload) values(p_actor,jsonb_build_object('delivery',snapshot,'kind',p_kind,'round',case when p_kind='initial' then 'initial' else 'reminder:'||vppsone.school_today()::text end)) returning * into preview;
  return snapshot - 'version' - 'authorityVersion' - 'templateVersion' || jsonb_build_object('ok',true,'id',preview.id,'digest',preview.digest,'kind',p_kind,
    'textHi',replace(replace(replace(template.body_hi,'{{1}}',params[1]),'{{2}}',params[2]),'{{3}}',params[3]),
    'textEn',replace(replace(replace(template.body_en,'{{1}}',params[1]),'{{2}}',params[2]),'{{3}}',params[3]));
end; $$;

create function vppsone.queue_teacher_task_delivery(p_actor uuid,p_preview uuid,p_digest text) returns jsonb language plpgsql security definer set search_path='' as $$
declare preview vppsone.teacher_task_previews%rowtype; snapshot jsonb; task uuid; msg uuid; template vppsone.message_templates%rowtype; params text[]; round text;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into preview from vppsone.teacher_task_previews where id=p_preview and actor_id=p_actor and digest=p_digest;
  if not found or preview.expires_at<now() or preview.payload->'delivery' is null then return jsonb_build_object('ok',false,'reason','changed'); end if;
  task:=(preview.payload->'delivery'->>'taskId')::uuid;
  -- Every enqueue/claim takes task before message row. Management also locks task.
  perform 1 from vppsone.teacher_tasks where id=task for update;
  perform 1 from vppsone.staff_profiles where id in(p_actor,(select assigned_staff_id from vppsone.teacher_tasks where id=task)) order by id for share;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  snapshot:=vppsone.teacher_task_delivery_snapshot(task);
  if snapshot is null or snapshot->>'version' is distinct from preview.payload->'delivery'->>'authorityVersion' then return jsonb_build_object('ok',false,'reason','changed'); end if;
  if not (snapshot->>'pending')::boolean then return jsonb_build_object('ok',false,'reason','complete'); end if;
  if vppsone.teacher_task_has_unknown_delivery(task) then return jsonb_build_object('ok',false,'reason','reconcile'); end if;
  select * into template from vppsone.message_templates where code='vppsone_teacher_task'||case when preview.payload->>'kind'='reminder' then '_reminder' else '' end||'_'||(snapshot->>'language')||'_v1' and is_active and audience='staff';
  if not found or md5(to_jsonb(template)::text) is distinct from preview.payload->'delivery'->>'templateVersion' then return jsonb_build_object('ok',false,'reason','changed'); end if;
  snapshot:=preview.payload->'delivery';
  round:=preview.payload->>'round';
  if preview.payload->>'kind'='reminder' and round is distinct from 'reminder:'||vppsone.school_today()::text then return jsonb_build_object('ok',false,'reason','changed'); end if;
  select id into msg from vppsone.message_sends where task_id=task and task_snapshot->>'version'=snapshot->>'version' and task_round=round;
  if found then
    -- The caller reviewed this exact immutable row again; another office actor
    -- may continue it only through a fresh actor-bound preview.
    perform set_config('vppsone.task_delivery',msg::text,true);
    update vppsone.message_sends set requested_by=p_actor where id=msg and task_delivery_state in ('ready','rejected');
    return jsonb_build_object('ok',true,'id',msg);
  end if;
  params:=array[snapshot->>'name',snapshot->>'title',coalesce(snapshot->>'due','—')];
  msg:=gen_random_uuid();perform set_config('vppsone.task_delivery',msg::text,true);
  insert into vppsone.message_sends(id,session_label,template_id,to_phone,to_name,staff_profile_id,variables,rendered_hi,rendered_en,status,requested_by,task_id,task_snapshot,task_round,task_delivery_state)
    select msg,t.session_label,template.id,snapshot->>'phone',snapshot->>'name',t.assigned_staff_id,params,
      replace(replace(replace(template.body_hi,'{{1}}',params[1]),'{{2}}',params[2]),'{{3}}',params[3]),
      replace(replace(replace(template.body_en,'{{1}}',params[1]),'{{2}}',params[2]),'{{3}}',params[3]),
      'queued',p_actor,task,snapshot,round,'ready' from vppsone.teacher_tasks t where id=task;
  return jsonb_build_object('ok',true,'id',msg);
end; $$;

create function vppsone.claim_teacher_task_delivery(p_actor uuid,p_id uuid,p_attempt text,p_transport text,p_manual boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare msg vppsone.message_sends%rowtype; task uuid; snapshot jsonb; token text; campaign text; template_version text;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  if (p_manual and p_transport<>'manual') or (not p_manual and (p_transport<>'aisensy' or p_attempt not like 'attempt:%')) then raise exception 'task_delivery:transport'; end if;
  select task_id into task from vppsone.message_sends where id=p_id;
  if task is null then return jsonb_build_object('ok',false,'reason','changed'); end if;
  perform 1 from vppsone.teacher_tasks where id=task for update;
  perform 1 from vppsone.staff_profiles where id in(p_actor,(select assigned_staff_id from vppsone.teacher_tasks where id=task)) order by id for share;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into msg from vppsone.message_sends where id=p_id for update;
  if vppsone.teacher_task_has_unknown_delivery(task) then return jsonb_build_object('ok',false,'reason','reconcile'); end if;
  if msg.task_delivery_state not in ('ready','rejected') then return jsonb_build_object('ok',false,'reason','already_handled'); end if;
  snapshot:=vppsone.teacher_task_delivery_snapshot(task);
  if msg.requested_by is distinct from p_actor or snapshot is null or snapshot->>'version' is distinct from msg.task_snapshot->>'authorityVersion' then return jsonb_build_object('ok',false,'reason','changed'); end if;
  if not (snapshot->>'pending')::boolean then return jsonb_build_object('ok',false,'reason','complete'); end if;
  if msg.task_round like 'reminder:%' and msg.task_round is distinct from 'reminder:'||vppsone.school_today()::text then return jsonb_build_object('ok',false,'reason','changed'); end if;
  select mt.code,md5(to_jsonb(mt)::text) into campaign,template_version from vppsone.message_templates mt where mt.id=msg.template_id and mt.is_active and mt.audience='staff';
  if campaign not in ('vppsone_teacher_task_en_v1','vppsone_teacher_task_hi_v1','vppsone_teacher_task_both_v1','vppsone_teacher_task_reminder_en_v1','vppsone_teacher_task_reminder_hi_v1','vppsone_teacher_task_reminder_both_v1') or campaign is null then return jsonb_build_object('ok',false,'reason','unavailable'); end if;
  if template_version is distinct from msg.task_snapshot->>'templateVersion' then return jsonb_build_object('ok',false,'reason','changed'); end if;
  select t.token into token from vppsone.teacher_tasks t where id=task;
  perform set_config('vppsone.task_delivery',p_id::text,true);
  update vppsone.message_sends set status=case when p_manual then 'sent'::vppsone.send_status else 'failed'::vppsone.send_status end,
    sent_at=case when p_manual then now() else null end,provider_message_id=case when p_manual then null else p_attempt end,
    error=case when p_manual then null else 'Provider result unknown; reconcile before another send.' end,
    task_transport=p_transport,task_delivery_state=case when p_manual then 'manual_opened' else 'unknown' end,
    task_history=task_history||jsonb_build_array(jsonb_build_object('event',case when p_manual then 'manual_opened' else 'claim' end,'attempt',p_attempt,'actor',p_actor,'at',now(),'transport',p_transport)) where id=p_id;
  return jsonb_build_object('ok',true,'taskId',task,'path','/t/tasks/'||token,'buttonSuffix',token,'phone',msg.to_phone,'name',msg.to_name,'campaign',campaign,'params',msg.variables,'text',msg.rendered_en);
end; $$;

create function vppsone.finish_teacher_task_delivery(p_actor uuid,p_id uuid,p_attempt text,p_outcome text,p_receipt text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare msg vppsone.message_sends%rowtype;
begin
  select * into msg from vppsone.message_sends where id=p_id for update;
  if not found or msg.task_id is null or msg.requested_by is distinct from p_actor or msg.provider_message_id is distinct from p_attempt or msg.task_delivery_state<>'unknown' then return jsonb_build_object('ok',false,'reason','reconcile'); end if;
  if p_outcome is null or p_outcome not in ('accepted','rejected','unknown') or (p_outcome='accepted' and (nullif(trim(p_receipt),'') is null or p_receipt like 'mock:%')) then raise exception 'task_delivery:outcome'; end if;
  perform set_config('vppsone.task_delivery',p_id::text,true);
  update vppsone.message_sends set status=case when p_outcome='accepted' then 'sent'::vppsone.send_status else 'failed'::vppsone.send_status end,
    sent_at=case when p_outcome='accepted' then now() else null end,task_delivery_state=p_outcome,
    provider_message_id=case when p_outcome='accepted' then p_receipt when p_outcome='rejected' then null else p_attempt end,
    error=case when p_outcome='accepted' then null when p_outcome='rejected' then 'Provider rejected this request: confirmed refusal' else 'Provider result unknown; reconcile before another send.' end,
    task_history=task_history||jsonb_build_array(jsonb_build_object('event',p_outcome,'attempt',p_attempt,'actor',p_actor,'at',now(),'receipt',p_receipt)) where id=p_id;
  return jsonb_build_object('ok',true);
end; $$;

create function vppsone.reconcile_teacher_task_delivery(p_actor uuid,p_id uuid,p_attempt text,p_resolution text,p_note text) returns boolean language plpgsql security definer set search_path='' as $$
declare msg vppsone.message_sends%rowtype; task uuid;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  if p_resolution is null or p_resolution not in ('accepted','not_sent') or p_note is null or length(trim(p_note)) not between 5 and 500 then raise exception 'task_delivery:evidence'; end if;
  select t.id into task from vppsone.message_sends m join vppsone.teacher_tasks t on(m.task_id=t.id or m.request_id=t.request_id) where m.id=p_id;
  if not found then return false; end if;
  perform 1 from vppsone.teacher_tasks where id=task for update;
  perform 1 from vppsone.staff_profiles where id=p_actor for share;
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  select * into msg from vppsone.message_sends where id=p_id for update;
  if not found or (msg.task_id is null and not exists(select 1 from vppsone.teacher_tasks where request_id=msg.request_id))
    or msg.provider_message_id is distinct from p_attempt or not coalesce((msg.task_delivery_state='unknown' or
      (msg.task_delivery_state is null and msg.status='failed' and (msg.provider_message_id is not null or not
        (coalesce(msg.error,'') like 'Provider rejected this request: %' or coalesce(msg.error,'') ~ '^The provider refused it \((400|401|403|404|422|429)\)\.$')))),false) then return false; end if;
  perform set_config('vppsone.task_delivery',p_id::text,true);
  update vppsone.message_sends set status=case when p_resolution='accepted' then 'sent'::vppsone.send_status else 'failed'::vppsone.send_status end,
    sent_at=case when p_resolution='accepted' then now() else null end,task_delivery_state=case when p_resolution='accepted' then 'human_confirmed' else 'rejected' end,
    provider_message_id=case when p_resolution='accepted' then 'confirmed:'||coalesce(p_attempt,'legacy:'||p_id::text) else null end,
    error=case when p_resolution='accepted' then null else 'Provider rejected this request: human checked not sent' end,
    task_history=task_history||jsonb_build_array(jsonb_build_object('event','reconcile','resolution',p_resolution,'attempt',p_attempt,'actor',p_actor,'at',now(),'note',trim(p_note))) where id=p_id;
  return true;
end; $$;

create function vppsone.teacher_task_delivery_summary(p_actor uuid,p_task uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare snapshot jsonb; deliveries jsonb;
begin
  if not exists(select 1 from vppsone.staff_profiles s join vppsone.role_permissions rp on rp.role=s.role where s.id=p_actor and s.is_active and rp.permission='collection:manage') then raise exception 'tasks:not_permitted'; end if;
  snapshot:=vppsone.teacher_task_delivery_snapshot(p_task);
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'state',coalesce(m.task_delivery_state,
    case when m.status='failed' and (m.provider_message_id is not null or not (coalesce(m.error,'') like 'Provider rejected this request: %' or coalesce(m.error,'') ~ '^The provider refused it \((400|401|403|404|422|429)\)\.$')) then 'unknown' else 'legacy_recorded' end),
    'transport',m.task_transport,'phone',m.to_phone,'at',m.requested_at,'round',coalesce(m.task_round,'legacy'),'attempt',m.provider_message_id,'history',m.task_history) order by m.requested_at desc,m.id),'[]') into deliveries from vppsone.message_sends m join vppsone.teacher_tasks t on(m.task_id=t.id or m.request_id=t.request_id) where t.id=p_task;
  return coalesce(snapshot-'version','{}')||jsonb_build_object('deliveries',deliveries);
end; $$;

revoke all on function vppsone.guard_teacher_task_delivery(),vppsone.teacher_task_delivery_snapshot(uuid),vppsone.prepare_teacher_task_delivery(uuid,uuid,text),vppsone.queue_teacher_task_delivery(uuid,uuid,text),vppsone.claim_teacher_task_delivery(uuid,uuid,text,text,boolean),vppsone.finish_teacher_task_delivery(uuid,uuid,text,text,text),vppsone.reconcile_teacher_task_delivery(uuid,uuid,text,text,text),vppsone.teacher_task_delivery_summary(uuid,uuid) from public,anon,authenticated;
grant execute on function vppsone.prepare_teacher_task_delivery(uuid,uuid,text),vppsone.queue_teacher_task_delivery(uuid,uuid,text),vppsone.claim_teacher_task_delivery(uuid,uuid,text,text,boolean),vppsone.finish_teacher_task_delivery(uuid,uuid,text,text,text),vppsone.reconcile_teacher_task_delivery(uuid,uuid,text,text,text),vppsone.teacher_task_delivery_summary(uuid,uuid) to service_role;
revoke all on function vppsone.mark_teacher_task_opened(uuid,uuid,text,text),vppsone.teacher_task_share_link(uuid,uuid) from public,anon,authenticated;
grant execute on function vppsone.mark_teacher_task_opened(uuid,uuid,text,text),vppsone.teacher_task_share_link(uuid,uuid) to service_role;
revoke all on function vppsone.teacher_task_has_unknown_delivery(uuid) from public,anon,authenticated;

-- ======================================================== migrations/20261018191000_overnight_qa_app_sessions.sql
-- REDUCED APP-ONLY REVIEW ARTIFACT. Apply only to wtgxcptmucjerhufzjcf after review.
-- Never apply to the protected/live project. Run target guard before applying.
-- No Auth writes, no token storage, no public data writes or public policy changes.
-- Existing six QA accounts only. No Storage/public policy changes or new Auth users.
-- Expiry/revocation is enforced ONLY by VPPS One application guards.
-- NO existing policies or helper functions change. Direct Supabase/Storage access remains inherited.
set local lock_timeout = '5s';
set local statement_timeout = '60s';
-- KMD: the original owner/project identity preflight is removed; these QA tables stay empty and switched off.

create table vppsone.qa_dayrun_runs (
  id text primary key check(id='overnight-20261019'),
  project_ref text not null check(project_ref='wtgxcptmucjerhufzjcf'),
  owner_user_id uuid not null check(owner_user_id='94751583-3fbd-422b-b748-9104e85c1644'),
  owner_staff_profile_id uuid not null check(owner_staff_profile_id='30c6b4d7-df2d-4ae2-873f-221e3d2ee55d'),
  expires_at timestamptz not null check(expires_at='2026-10-19T07:00:00Z'::timestamptz),
  enabled boolean not null default false,
  revoked_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);
create table vppsone.qa_dayrun_accounts (
  run_id text not null references vppsone.qa_dayrun_runs(id) on delete restrict,
  alias text primary key check(alias in('admin','accountant','academic','exam','teacher','teacher2')),
  user_id uuid unique, -- deliberately no auth.users FK: tombstones survive user deletion
  staff_profile_id uuid not null unique,
  email text not null unique,
  role vppsone.staff_role not null,
  is_new boolean not null,
  revoked_at timestamptz,
  registered_at timestamptz,
  check(not is_new)
);
create table vppsone.qa_dayrun_pairs (
  id uuid primary key default gen_random_uuid(),
  run_id text not null references vppsone.qa_dayrun_runs(id) on delete restrict,
  target_origin text not null check(target_origin='https://vppsone-veerpattas-projects.vercel.app'),
  secret_hash text not null check(secret_hash ~ '^[a-f0-9]{64}$'),
  request_key_hash text not null check(request_key_hash ~ '^[a-f0-9]{64}$'),
  status text not null default 'pending' check(status in('pending','authorized','consuming','used','failed','revoked')),
  alias text references vppsone.qa_dayrun_accounts(alias) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  approved_at timestamptz,
  approved_by uuid,
  consuming_at timestamptz,
  used_at timestamptz,
  failed_at timestamptz,
  check(expires_at<=created_at+interval '5 minutes'),
  check(expires_at<='2026-10-19T07:00:00Z'::timestamptz)
);
create index qa_dayrun_pairs_rate on vppsone.qa_dayrun_pairs(created_at,request_key_hash);
create table vppsone.qa_dayrun_sessions (
  session_id uuid primary key, -- deliberately no auth.sessions FK; never delete a lease
  run_id text not null references vppsone.qa_dayrun_runs(id) on delete restrict,
  pair_id uuid not null unique references vppsone.qa_dayrun_pairs(id) on delete restrict,
  alias text not null references vppsone.qa_dayrun_accounts(alias) on delete restrict,
  user_id uuid not null,
  staff_profile_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null check(expires_at='2026-10-19T07:00:00Z'::timestamptz),
  revoked_at timestamptz
);
create index qa_dayrun_sessions_user on vppsone.qa_dayrun_sessions(user_id);
-- KMD: the original school's overnight QA run and its six pinned accounts are not created.

-- Freeze identity pins and permanent revocation/session tombstones.
create function vppsone.qa_dayrun_preserve_tombstone() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op in('DELETE','TRUNCATE') then raise exception 'DAYRUN: tombstones must never be deleted'; end if;
  if tg_table_name='qa_dayrun_runs' then
    if (to_jsonb(new)-'enabled'-'revoked_at') is distinct from (to_jsonb(old)-'enabled'-'revoked_at')
       or(old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at) then
      raise exception 'DAYRUN: immutable run'; end if;
  elsif tg_table_name='qa_dayrun_accounts' then
    if (to_jsonb(new)-'user_id'-'registered_at'-'revoked_at') is distinct from (to_jsonb(old)-'user_id'-'registered_at'-'revoked_at')
       or(old.user_id is not null and new.user_id is distinct from old.user_id)
       or(old.registered_at is not null and new.registered_at is distinct from old.registered_at)
       or(old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at) then
      raise exception 'DAYRUN: immutable identity pin'; end if;
  elsif tg_table_name='qa_dayrun_pairs' then
    if new.id is distinct from old.id or new.run_id is distinct from old.run_id
       or new.target_origin is distinct from old.target_origin or new.secret_hash is distinct from old.secret_hash
       or new.request_key_hash is distinct from old.request_key_hash or new.created_at is distinct from old.created_at
       or new.expires_at is distinct from old.expires_at
       or(old.alias is not null and new.alias is distinct from old.alias) then
      raise exception 'DAYRUN: immutable pair binding'; end if;
  elsif tg_table_name='qa_dayrun_sessions' then
    if (to_jsonb(new)-'revoked_at') is distinct from (to_jsonb(old)-'revoked_at')
       or(old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at) then
      raise exception 'DAYRUN: immutable session lease'; end if;
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['qa_dayrun_runs','qa_dayrun_accounts','qa_dayrun_pairs','qa_dayrun_sessions'] loop
    execute format('alter table vppsone.%I enable row level security',t);
    execute format('revoke all on vppsone.%I from public, anon, authenticated, service_role',t);
    execute format('grant select on vppsone.%I to service_role',t);
    execute format('create trigger preserve_dayrun_tombstone before delete or update on vppsone.%I for each row execute function vppsone.qa_dayrun_preserve_tombstone()',t);
    execute format('create trigger preserve_dayrun_truncate before truncate on vppsone.%I for each statement execute function vppsone.qa_dayrun_preserve_tombstone()',t);
  end loop;
end $$;

create function vppsone.qa_dayrun_access_allowed() returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare
  u uuid := auth.uid();
  sid uuid;
  s vppsone.qa_dayrun_sessions%rowtype;
  r vppsone.qa_dayrun_runs%rowtype;
begin
  -- Restriction is ONLY for a launcher-issued session_id. Existing unrelated
  -- sessions and all other users retain their original access decisions.
  begin sid := (auth.jwt()->>'session_id')::uuid;
    exception when invalid_text_representation then return true; end;
  select * into s from vppsone.qa_dayrun_sessions where session_id=sid;
  if not found then return true; end if;
  select * into r from vppsone.qa_dayrun_runs where id=s.run_id;
  return found and s.user_id=u and s.revoked_at is null and r.enabled and r.revoked_at is null
    and clock_timestamp()<s.expires_at and clock_timestamp()<r.expires_at
    and exists(select 1 from vppsone.qa_dayrun_accounts a join vppsone.staff_profiles p on p.id=a.staff_profile_id
      where a.alias=s.alias and a.user_id=u and a.staff_profile_id=s.staff_profile_id and a.revoked_at is null
        and p.user_id=u and p.role=a.role and p.is_active);
end $$;
create function vppsone.qa_dayrun_create_pair(p_secret_hash text,p_request_key_hash text,p_target_origin text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r vppsone.qa_dayrun_runs%rowtype; v_id uuid; v_now timestamptz:=clock_timestamp(); v_exp timestamptz;
begin
  if p_target_origin is distinct from 'https://vppsone-veerpattas-projects.vercel.app' then return null; end if;
  if p_secret_hash is null or p_request_key_hash is null or p_secret_hash !~ '^[a-f0-9]{64}$' or p_request_key_hash !~ '^[a-f0-9]{64}$' then return null; end if;
  -- Serializes all create/approve/consume/complete/revoke races and cap checks.
  select * into r from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  if not r.enabled or r.revoked_at is not null or v_now>=r.expires_at then return null; end if;
  if (select count(*) from vppsone.qa_dayrun_pairs)>=300
    or(select count(*) from vppsone.qa_dayrun_pairs where created_at>v_now-interval '1 minute')>=30
    or(select count(*) from vppsone.qa_dayrun_pairs where request_key_hash=p_request_key_hash and created_at>v_now-interval '1 minute')>=5
    or(select count(*) from vppsone.qa_dayrun_pairs where status in('pending','authorized','consuming') and expires_at>v_now)>=25 then return null; end if;
  v_exp:=least(v_now+interval '5 minutes',r.expires_at);
  insert into vppsone.qa_dayrun_pairs(run_id,target_origin,secret_hash,request_key_hash,created_at,expires_at)
  values(r.id,p_target_origin,p_secret_hash,p_request_key_hash,v_now,v_exp) returning id into v_id;
  return jsonb_build_object('id',v_id,'expires_at',v_exp,'target_origin',p_target_origin);
end $$;
create function vppsone.qa_dayrun_approve_pair(p_pair_id uuid,p_alias text,p_owner_user_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare r vppsone.qa_dayrun_runs%rowtype;
begin
  select * into r from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  if p_owner_user_id is distinct from r.owner_user_id or not r.enabled or r.revoked_at is not null or clock_timestamp()>=r.expires_at then return false; end if;
  if not exists(select 1 from vppsone.staff_profiles where id=r.owner_staff_profile_id and user_id=r.owner_user_id and role='admin' and is_active) then return false; end if;
  if not exists(select 1 from vppsone.qa_dayrun_accounts a join vppsone.staff_profiles sp on sp.id=a.staff_profile_id join auth.users u on u.id=a.user_id
    where a.alias=p_alias and a.user_id=sp.user_id and sp.is_active and sp.role=a.role and lower(u.email)=a.email and a.revoked_at is null and a.registered_at is not null) then return false; end if;
  update vppsone.qa_dayrun_pairs set status='authorized',alias=p_alias,approved_by=p_owner_user_id,approved_at=clock_timestamp()
    where id=p_pair_id and run_id=r.id and status='pending' and expires_at>clock_timestamp();
  return found;
end $$;
create function vppsone.qa_dayrun_consume_pair(p_pair_id uuid,p_secret_hash text,p_target_origin text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r vppsone.qa_dayrun_runs%rowtype; p vppsone.qa_dayrun_pairs%rowtype; a vppsone.qa_dayrun_accounts%rowtype;
begin
  select * into r from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  if not r.enabled or r.revoked_at is not null or clock_timestamp()>=r.expires_at then return null; end if;
  update vppsone.qa_dayrun_pairs set status='consuming',consuming_at=clock_timestamp()
    where id=p_pair_id and run_id=r.id and status='authorized' and secret_hash=p_secret_hash and target_origin=p_target_origin and expires_at>clock_timestamp()
    returning * into p;
  if not found then return null; end if;
  select * into a from vppsone.qa_dayrun_accounts where alias=p.alias and user_id is not null and revoked_at is null;
  if not found or not exists(select 1 from vppsone.staff_profiles sp join auth.users u on u.id=sp.user_id
    where sp.id=a.staff_profile_id and sp.user_id=a.user_id and sp.role=a.role and sp.is_active and lower(u.email)=a.email) then
    update vppsone.qa_dayrun_pairs set status='failed',failed_at=clock_timestamp() where id=p.id; return null;
  end if;
  return jsonb_build_object('id',p.id,'target_origin',p.target_origin,'alias',a.alias,'user_id',a.user_id,'staff_profile_id',a.staff_profile_id,'email',a.email,'role',a.role,'is_new',a.is_new,'expires_at',r.expires_at);
end $$;
create function vppsone.qa_dayrun_complete_pair(p_pair_id uuid,p_session_id uuid,p_user_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare r vppsone.qa_dayrun_runs%rowtype; p vppsone.qa_dayrun_pairs%rowtype; a vppsone.qa_dayrun_accounts%rowtype;
begin
  select * into r from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  select * into p from vppsone.qa_dayrun_pairs where id=p_pair_id and status='consuming' for update;
  if not found then return false; end if;
  select * into a from vppsone.qa_dayrun_accounts where alias=p.alias;
  if not r.enabled or r.revoked_at is not null or clock_timestamp()>=r.expires_at or clock_timestamp()>=p.expires_at
    or a.user_id is distinct from p_user_id or a.revoked_at is not null
    or not exists(select 1 from auth.sessions s where s.id=p_session_id and s.user_id=p_user_id)
    or not exists(select 1 from vppsone.staff_profiles sp where sp.id=a.staff_profile_id and sp.user_id=p_user_id and sp.is_active and sp.role=a.role)
    or exists(select 1 from vppsone.qa_dayrun_sessions where session_id=p_session_id) then
    update vppsone.qa_dayrun_pairs set status='failed',failed_at=clock_timestamp() where id=p.id; return false;
  end if;
  insert into vppsone.qa_dayrun_sessions(session_id,run_id,pair_id,alias,user_id,staff_profile_id,expires_at)
    values(p_session_id,r.id,p.id,a.alias,p_user_id,a.staff_profile_id,r.expires_at);
  update vppsone.qa_dayrun_pairs set status='used',used_at=clock_timestamp() where id=p.id;
  return true;
end $$;
create function vppsone.qa_dayrun_fail_pair(p_pair_id uuid,p_secret_hash text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
  perform 1 from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  -- Public pair ID alone is not enough to cancel a pairing or session.
  perform 1 from vppsone.qa_dayrun_pairs where id=p_pair_id and secret_hash=p_secret_hash
    and status in('consuming','used') for update;
  if not found then return false; end if;
  update vppsone.qa_dayrun_sessions set revoked_at=clock_timestamp() where pair_id=p_pair_id and revoked_at is null;
  update vppsone.qa_dayrun_pairs set status='failed',failed_at=clock_timestamp()
    where id=p_pair_id and status in('consuming','used');
  return found;
end $$;
create function vppsone.qa_dayrun_owner_session_valid(p_session_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.sessions s join vppsone.staff_profiles sp on sp.user_id=s.user_id
    where s.id=p_session_id and s.user_id='94751583-3fbd-422b-b748-9104e85c1644'
      and sp.id='30c6b4d7-df2d-4ae2-873f-221e3d2ee55d' and sp.role='admin' and sp.is_active
      and (s.not_after is null or s.not_after>clock_timestamp()))
$$;
create function vppsone.qa_dayrun_revoke_session(p_session_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
  perform 1 from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  update vppsone.qa_dayrun_sessions set revoked_at=coalesce(revoked_at,clock_timestamp())
    where session_id=p_session_id and run_id='overnight-20261019';
  return found;
end $$;
create function vppsone.qa_dayrun_activate(p_owner_user_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare r vppsone.qa_dayrun_runs%rowtype;
begin
  select * into r from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  if p_owner_user_id is distinct from r.owner_user_id or r.revoked_at is not null or clock_timestamp()>=r.expires_at then return false; end if;
  if not exists(select 1 from vppsone.staff_profiles where id=r.owner_staff_profile_id and user_id=r.owner_user_id and role='admin' and is_active) then return false; end if;
  if (select count(*) from vppsone.qa_dayrun_accounts a join vppsone.staff_profiles sp on sp.id=a.staff_profile_id join auth.users u on u.id=a.user_id
    where a.user_id=sp.user_id and sp.is_active and sp.role=a.role and lower(u.email)=a.email and a.revoked_at is null and a.registered_at is not null)<>6 then return false; end if;
  update vppsone.qa_dayrun_runs set enabled=true where id=r.id;
  return true;
end $$;
create function vppsone.qa_dayrun_revoke() returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_now timestamptz:=clock_timestamp(); v_profiles integer;
begin
  perform 1 from vppsone.qa_dayrun_runs where id='overnight-20261019' for update;
  -- Denial first. Tombstones remain after revoke and expiry, permanently.
  update vppsone.qa_dayrun_runs set enabled=false,revoked_at=coalesce(revoked_at,v_now) where id='overnight-20261019';
  update vppsone.qa_dayrun_sessions set revoked_at=v_now where revoked_at is null;
  update vppsone.qa_dayrun_pairs set status='revoked' where status in('pending','authorized','consuming');
  v_profiles:=0; -- Existing profiles are never deactivated.
  return jsonb_build_object('revoked',true,'new_profiles_deactivated',v_profiles,'expires_at','2026-10-19T07:00:00Z');
end $$;
-- ACLs target only the exact eleven signatures created above.
do $$ declare signature text; begin
  foreach signature in array array[
    'vppsone.qa_dayrun_preserve_tombstone()',
    'vppsone.qa_dayrun_access_allowed()',
    'vppsone.qa_dayrun_create_pair(text,text,text)',
    'vppsone.qa_dayrun_approve_pair(uuid,text,uuid)',
    'vppsone.qa_dayrun_consume_pair(uuid,text,text)',
    'vppsone.qa_dayrun_complete_pair(uuid,uuid,uuid)',
    'vppsone.qa_dayrun_fail_pair(uuid,text)',
    'vppsone.qa_dayrun_owner_session_valid(uuid)',
    'vppsone.qa_dayrun_revoke_session(uuid)',
    'vppsone.qa_dayrun_activate(uuid)',
    'vppsone.qa_dayrun_revoke()'
  ] loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',signature::regprocedure);
    if signature='vppsone.qa_dayrun_access_allowed()' then
      execute format('grant execute on function %s to authenticated,service_role',signature::regprocedure);
    elsif signature<>'vppsone.qa_dayrun_preserve_tombstone()' then
      execute format('grant execute on function %s to service_role',signature::regprocedure);
    end if;
  end loop;
end $$;
-- KMD: no pinned QA accounts to assert.

-- ======================================================== migrations/20261020020824_photo_review_reason.sql
-- U03 (19 Oct assessment brief): a rejected photograph carries the reason the
-- teacher sees ("Changes requested: ..."). Additive: one nullable column, a
-- four-argument review that records it, and the three-argument review kept
-- as a wrapper so nothing calling it changes. Same locks, checks and grants as
-- 20261016080000_profile_photos.sql; the official photograph still changes
-- only on approval. Rollback: drop the 4-arg function, restore the 3-arg body
-- from 20261016080000, drop the column.

alter table vppsone.photo_proposals
  add column if not exists decision_note text
  check (decision_note is null or char_length(decision_note) between 1 and 300);

create or replace function vppsone.review_student_photo(p_actor uuid,p_proposal uuid,p_accept boolean,p_note text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare proposal vppsone.photo_proposals%rowtype; t vppsone.teacher_tasks%rowtype;
  answer vppsone.collection_submissions%rowtype; result jsonb; request uuid;
  note text := nullif(btrim(coalesce(p_note,'')),'');
begin
  if not exists(select 1 from vppsone.staff_profiles where id=p_actor and is_active and role='admin') then raise exception 'photos:admin_required'; end if;
  if note is not null and char_length(note)>300 then raise exception 'photos:bad_request'; end if;
  select request_id into request from vppsone.photo_proposals where command_id=p_proposal;
  select * into t from vppsone.teacher_tasks where request_id=request for update;
  if found and not vppsone.teacher_task_access(t.id,t.assigned_staff_id,null) then raise exception 'photos:not_permitted'; end if;
  perform 1 from vppsone.collection_requests where id=request and status='open' and archived_at is null for update;
  if not found then raise exception 'photos:not_permitted'; end if;
  select * into proposal from vppsone.photo_proposals where command_id=p_proposal for update;
  if not found then raise exception 'photos:not_found'; end if;
  select * into answer from vppsone.collection_submissions where request_id=request and student_id=proposal.student_id and field_id=proposal.field_id for update;
  if answer.value is distinct from p_proposal::text then raise exception 'photos:stale'; end if;
  if proposal.decision<>'pending' then
    if (proposal.decision='accepted')=p_accept then return jsonb_build_object('ok',true,'replayed',true); end if;
    raise exception 'photos:decided';
  end if;
  if p_accept then
    result := vppsone.place_student_photo(proposal.payload||jsonb_build_object('actor_staff_id',p_actor,
      'payload_hash',md5(proposal.payload::text),'expected_current',proposal.expected_current));
    if result->>'ok' is distinct from 'true' then return result; end if;
  end if;
  update vppsone.photo_proposals set decision=case when p_accept then 'accepted' else 'rejected' end,decided_by=p_actor,
    decision_note=case when p_accept then null else note end
    where command_id=p_proposal;
  update vppsone.collection_submissions set status=(case when p_accept then 'accepted' else 'rejected' end)::vppsone.submission_status,
    decided_by=p_actor,decided_at=now() where id=answer.id;
  return jsonb_build_object('ok',true,'replayed',false);
end; $$;

create or replace function vppsone.review_student_photo(p_actor uuid,p_proposal uuid,p_accept boolean) returns jsonb
language sql security definer set search_path='' as $$
  select vppsone.review_student_photo(p_actor,p_proposal,p_accept,null::text);
$$;

revoke all on function vppsone.review_student_photo(uuid,uuid,boolean,text) from public,anon,authenticated;
revoke all on function vppsone.review_student_photo(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function vppsone.review_student_photo(uuid,uuid,boolean,text) to service_role;
grant execute on function vppsone.review_student_photo(uuid,uuid,boolean) to service_role;

-- ======================================================== migrations/20261020020829_support_plans_follow_source_note.sql
-- R01 (19 Oct assessment brief), defence in depth. The app reads support
-- plans with the service role and checks the source note itself (D-302);
-- this policy holds a direct REST read to the same line: a school-wide reader
-- sees a plan only when it has no source note or she can read that note
-- (the subquery runs under notes_select_scoped, so an Only me note, or a
-- health or family note she may not read, keeps its plan from her). The
-- maker always reads her plan; steps follow their plan's visibility.
-- Rollback: alter the policy back to the using clause in
-- 20261010102943_vx_academics_calendar.sql.

alter policy support_plans_select_scoped on vppsone.support_plans
  using (
    (select vppsone.staff_can('notes:view'))
    and (
      created_by = (select vppsone.current_staff_profile_id())
      or (
        (select vppsone.reads_every_class())
        and (note_id is null or exists (select 1 from vppsone.notes n where n.id = support_plans.note_id))
      )
    )
  );

-- ======================================================== migrations/20261020103153_smoke_lab.sql
-- Smoke Lab (owner's request, 20 Oct 2026): passwordless role accounts that
-- AI agents use to run a whole school day on the TEST database and file the
-- bugs and improvements they find.
--
-- DEV ONLY. Never apply to the live School Fees project: it is a D-skip file
-- in docs/cutover/LIVE-MIGRATION-PLAN.md, and the app switches the lab off on
-- live in code as well (src/platform/auth/smoke-lab.ts).
--
-- Shape of the safety:
--  * Only `smoke.*@qa.vpps.local` accounts are in the pool, and only those
--    can be signed in through a pass.
--  * A pass is a 256-bit secret shown once; only its sha256 is stored here.
--  * A smoke account's session is honoured only while one of its passes and
--    its run are live: `smoke_access_allowed()` is checked by the middleware
--    on every request (any other account is unaffected and always `true`).
--  * Nothing here is readable by a browser: RLS on, no policies, and the
--    schema's default `select` for `authenticated` revoked. The app reads it
--    with the service role after an admin check.
--
-- Rollback: drop function vppsone.smoke_access_allowed(); drop the four
-- tables (findings, passes, runs, pool), then unlink the pool's teacher
-- profiles (scripts/smoke-pool.mjs --release).

create table vppsone.smoke_pool (
  email text primary key
    check (email ~ '^smoke\.[a-z0-9._-]+@qa\.vpps\.local$'),
  auth_user_id uuid not null unique references auth.users (id) on delete cascade,
  staff_profile_id uuid not null unique references vppsone.staff_profiles (id),
  role vppsone.staff_role not null,
  label text not null check (char_length(label) between 3 and 80),
  linked_existing boolean not null default false,
  created_at timestamptz not null default now()
);

comment on table vppsone.smoke_pool is
  'Smoke Lab test accounts (DEV only). linked_existing: the account was attached to an existing teacher profile rather than given a new one.';

create table vppsone.smoke_runs (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 3 and 120),
  scenario text not null default 'school_day' check (scenario in ('school_day', 'free_explore')),
  school_day date,
  clock_start text check (clock_start is null or clock_start ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  status text not null default 'open' check (status in ('open', 'closed', 'revoked')),
  expires_at timestamptz not null,
  created_by uuid not null references vppsone.staff_profiles (id),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid references vppsone.staff_profiles (id),
  constraint smoke_runs_window check (expires_at > created_at and expires_at <= created_at + interval '24 hours'),
  constraint smoke_runs_closed check ((status = 'open') = (closed_at is null))
);

create table vppsone.smoke_passes (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references vppsone.smoke_runs (id) on delete cascade,
  pool_email text not null references vppsone.smoke_pool (email) on delete cascade,
  persona text check (persona is null or char_length(persona) <= 120),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  first_used_at timestamptz,
  last_used_at timestamptz,
  uses integer not null default 0 check (uses >= 0),
  created_at timestamptz not null default now(),
  unique (run_id, pool_email)
);

create index smoke_passes_pool_live on vppsone.smoke_passes (pool_email, expires_at) where revoked_at is null;

create table vppsone.smoke_findings (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references vppsone.smoke_runs (id) on delete cascade,
  pass_id uuid references vppsone.smoke_passes (id) on delete set null,
  role vppsone.staff_role,
  reporter text check (reporter is null or char_length(reporter) <= 120),
  kind text not null check (kind in ('bug', 'improvement', 'question')),
  severity text not null check (severity in ('P1', 'P2', 'P3')),
  title text not null check (char_length(btrim(title)) between 3 and 160),
  screen text check (screen is null or char_length(screen) <= 300),
  steps text check (steps is null or char_length(steps) <= 4000),
  expected text check (expected is null or char_length(expected) <= 2000),
  actual text check (actual is null or char_length(actual) <= 2000),
  evidence text check (evidence is null or char_length(evidence) <= 4000),
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{32}$'),
  repeats integer not null default 1 check (repeats >= 1),
  status text not null default 'new'
    check (status in ('new', 'confirmed', 'duplicate', 'not_a_bug', 'fixed', 'verified', 'regressed')),
  triage_note text check (triage_note is null or char_length(triage_note) <= 1000),
  triaged_by uuid references vppsone.staff_profiles (id),
  triaged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (run_id, fingerprint)
);

create index smoke_findings_status on vppsone.smoke_findings (status, severity, created_at desc);

create trigger smoke_findings_set_updated_at
  before update on vppsone.smoke_findings
  for each row execute function vppsone.set_updated_at();

alter table vppsone.smoke_pool enable row level security;
alter table vppsone.smoke_runs enable row level security;
alter table vppsone.smoke_passes enable row level security;
alter table vppsone.smoke_findings enable row level security;

revoke all on vppsone.smoke_pool, vppsone.smoke_runs, vppsone.smoke_passes, vppsone.smoke_findings from anon, authenticated;
grant all on vppsone.smoke_pool, vppsone.smoke_runs, vppsone.smoke_passes, vppsone.smoke_findings to service_role;

-- True for every account that is not in the pool (nothing changes for real
-- or ordinary QA staff). For a pool account: true only while it holds a pass
-- that is unrevoked and unexpired, in a run that is open and unexpired.
create function vppsone.smoke_access_allowed() returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from vppsone.smoke_pool p where p.auth_user_id = auth.uid())
    or exists (
      select 1
      from vppsone.smoke_passes s
      join vppsone.smoke_runs r on r.id = s.run_id
      join vppsone.smoke_pool p on p.email = s.pool_email
      where p.auth_user_id = auth.uid()
        and s.revoked_at is null
        and s.expires_at > now()
        and r.status = 'open'
        and r.expires_at > now()
    );
$$;

revoke all on function vppsone.smoke_access_allowed() from public, anon;
grant execute on function vppsone.smoke_access_allowed() to authenticated, service_role;

-- ======================================================== migrations/20261020105658_smoke_lab_enforcement.sql
-- Smoke Lab, second pass after an independent security review (20 Oct 2026).
-- DEV ONLY, like 20261020103153_smoke_lab.sql (a D-skip for the live cutover).
--
-- 1. Runs are enforced by the database, not only the app. A smoke account
--    with no live pass is banned and its sessions deleted, so the tokens an
--    agent holds stop refreshing even if it never touches the app again;
--    one with a live pass is unbanned. `smoke_enforce()` runs on every
--    open/close/revoke (the app calls it) and every two minutes (pg_cron),
--    which is how expiry is enforced.
-- 2. `smoke_access_allowed()` answers only for the pool: anybody outside it
--    gets false (the app asks it only about smoke accounts).
-- 3. Counters and repeats are single statements (no read-then-write).
-- 4. Per-run finding counts are aggregated here, not read row by row.
-- 5. The pool remembers a borrowed teacher profile's language, so release
--    can put it back.
--
-- Rollback: select cron.unschedule('smoke-enforce'); drop the five functions
-- added here; restore smoke_access_allowed from 20261020103153; update
-- auth.users set banned_until = null where id in (select auth_user_id from
-- vppsone.smoke_pool); alter table vppsone.smoke_pool drop column original_language.

alter table vppsone.smoke_pool add column original_language text;

create or replace function vppsone.smoke_access_allowed() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from vppsone.smoke_passes s
    join vppsone.smoke_runs r on r.id = s.run_id
    join vppsone.smoke_pool p on p.email = s.pool_email
    where p.auth_user_id = auth.uid()
      and s.revoked_at is null
      and s.expires_at > now()
      and r.status = 'open'
      and r.expires_at > now()
  );
$$;

create function vppsone.smoke_enforce() returns integer
language plpgsql security definer set search_path = '' as $$
declare changed integer := 0; n integer;
begin
  with live as (
    select distinct p.auth_user_id
    from vppsone.smoke_pool p
    join vppsone.smoke_passes s on s.pool_email = p.email
    join vppsone.smoke_runs r on r.id = s.run_id
    where s.revoked_at is null and s.expires_at > now() and r.status = 'open' and r.expires_at > now()
  )
  update auth.users u
     set banned_until = case when u.id in (select auth_user_id from live) then null else 'infinity'::timestamptz end
   where u.id in (select auth_user_id from vppsone.smoke_pool)
     and u.banned_until is distinct from (case when u.id in (select auth_user_id from live) then null else 'infinity'::timestamptz end);
  get diagnostics n = row_count;
  changed := changed + n;

  delete from auth.sessions s
   where s.user_id in (select auth_user_id from vppsone.smoke_pool)
     and s.user_id in (select id from auth.users where banned_until is not null and banned_until > now());
  get diagnostics n = row_count;
  return changed + n;
end; $$;

create function vppsone.smoke_touch_pass(p_pass uuid) returns void
language sql security definer set search_path = '' as $$
  update vppsone.smoke_passes
     set uses = uses + 1, last_used_at = now(), first_used_at = coalesce(first_used_at, now())
   where id = p_pass;
$$;

create function vppsone.smoke_record_finding(
  p_run uuid, p_pass uuid, p_role vppsone.staff_role, p_reporter text, p_kind text, p_severity text,
  p_title text, p_screen text, p_steps text, p_expected text, p_actual text, p_evidence text, p_fingerprint text
) returns table (id uuid, repeat boolean)
language sql security definer set search_path = '' as $$
  insert into vppsone.smoke_findings (run_id, pass_id, role, reporter, kind, severity, title, screen, steps, expected, actual, evidence, fingerprint)
  values (p_run, p_pass, p_role, p_reporter, p_kind, p_severity, p_title, p_screen, p_steps, p_expected, p_actual, p_evidence, p_fingerprint)
  on conflict (run_id, fingerprint) do update set repeats = vppsone.smoke_findings.repeats + 1
  returning vppsone.smoke_findings.id, (xmax <> 0) as repeat;
$$;

create function vppsone.smoke_run_counts(p_runs uuid[]) returns table (run_id uuid, total integer, open integer, p1 integer)
language sql stable security definer set search_path = '' as $$
  select f.run_id,
         count(*)::integer,
         count(*) filter (where f.status in ('new', 'confirmed', 'regressed'))::integer,
         count(*) filter (where f.status in ('new', 'confirmed', 'regressed') and f.severity = 'P1')::integer
    from vppsone.smoke_findings f
   where f.run_id = any (p_runs)
   group by f.run_id;
$$;

revoke all on function vppsone.smoke_enforce() from public, anon, authenticated;
revoke all on function vppsone.smoke_touch_pass(uuid) from public, anon, authenticated;
revoke all on function vppsone.smoke_record_finding(uuid, uuid, vppsone.staff_role, text, text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function vppsone.smoke_run_counts(uuid[]) from public, anon, authenticated;
grant execute on function vppsone.smoke_enforce() to service_role;
grant execute on function vppsone.smoke_touch_pass(uuid) to service_role;
grant execute on function vppsone.smoke_record_finding(uuid, uuid, vppsone.staff_role, text, text, text, text, text, text, text, text, text, text) to service_role;
grant execute on function vppsone.smoke_run_counts(uuid[]) to service_role;

select cron.schedule('smoke-enforce', '*/2 * * * *', $cron$select vppsone.smoke_enforce()$cron$);

-- Every pool account is banned until a run gives it a pass.
select vppsone.smoke_enforce();

-- ======================================================== migrations/20261020110015_smoke_lab_ban_date.sql
-- Smoke Lab: ban with a far-future date, not 'infinity' (DEV ONLY, D-skip).
--
-- 20261020105658 banned pool accounts with banned_until = 'infinity'. Postgres
-- accepts it; Supabase Auth cannot scan it into a Go time, so loading any of
-- those users failed ("Database error loading user") and so did listing the
-- project's users at all — every admin user screen and script on the test
-- database. Auth's own "ban forever" is a duration of about a hundred years,
-- so this uses a fixed date that far out, which also keeps the comparison in
-- smoke_enforce() stable (no rewrite every two minutes).
--
-- Rollback: re-apply smoke_enforce() from 20261020105658 (not advised).

create or replace function vppsone.smoke_enforce() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  changed integer := 0;
  n integer;
  banned constant timestamptz := '2999-12-31 00:00:00+00';
begin
  with live as (
    select distinct p.auth_user_id
    from vppsone.smoke_pool p
    join vppsone.smoke_passes s on s.pool_email = p.email
    join vppsone.smoke_runs r on r.id = s.run_id
    where s.revoked_at is null and s.expires_at > now() and r.status = 'open' and r.expires_at > now()
  )
  update auth.users u
     set banned_until = case when u.id in (select auth_user_id from live) then null else banned end
   where u.id in (select auth_user_id from vppsone.smoke_pool)
     and u.banned_until is distinct from (case when u.id in (select auth_user_id from live) then null else banned end);
  get diagnostics n = row_count;
  changed := changed + n;

  delete from auth.sessions s
   where s.user_id in (select auth_user_id from vppsone.smoke_pool)
     and s.user_id in (select id from auth.users where banned_until is not null and banned_until > now());
  get diagnostics n = row_count;
  return changed + n;
end; $$;

revoke all on function vppsone.smoke_enforce() from public, anon, authenticated;
grant execute on function vppsone.smoke_enforce() to service_role;

select vppsone.smoke_enforce();

-- ======================================================== migrations/20261021033411_late_cover_assign.sql
-- Smoke school day, 20 Oct findings (dev group 5). Applied to DEV as 20261021033411.
-- Goes to live with the app at cutover (not a D-skip).
--
-- A person may put a teacher into a lesson that is running now with nobody in
-- it. The cover command treats a begun period as history (cover_period_open);
-- this is the one narrow door: today only, a period that has started and not
-- ended, a lesson with no live duty, a teacher who is active, in school, not
-- teaching and not already covering then. It writes one manual, pinned duty
-- and queues its notice, in the same shape and under the same per-day lock as
-- commit_cover_command, so the next command leaves it alone (its step 7 skips
-- begun periods) and every screen reads the lesson as covered.

create or replace function vppsone.assign_late_cover(p_command jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_actor uuid;
  v_session text := p_command->>'session_label';
  v_day date;
  v_hash text := p_command->>'payload_hash';
  v_tt_day text := p_command->>'timetable_day';
  v_need jsonb := p_command->'need';
  v_covering uuid;
  v_period integer;
  v_previous vppsone.cover_commands%rowtype;
  v_day_row vppsone.cover_days%rowtype;
  v_version uuid;
  v_bells_revision integer;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_minutes integer := extract(hour from (now() at time zone 'Asia/Kolkata'))::integer * 60
                     + extract(minute from (now() at time zone 'Asia/Kolkata'))::integer;
  v_starts text;
  v_ends text;
  v_revision integer;
  v_new_id uuid;
  v_live jsonb;
  v_receipt jsonb;
begin
  begin
    v_id := (p_command->>'command_id')::uuid;
    v_actor := (p_command->>'actor_staff_id')::uuid;
    v_day := (p_command->>'day')::date;
    v_covering := (p_command->>'covering_staff_id')::uuid;
    v_period := (v_need->>'period')::integer;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;

  if v_id is null or v_actor is null or v_session is null or v_day is null or v_hash is null
     or v_covering is null or v_period is null or v_need->>'need_key' is null or v_tt_day is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- Who is asking, now.
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || v_day::text));

  -- The same submission again gets the same answer.
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

  -- Today, and a period that is running now.
  select period->>'starts', period->>'ends' into v_starts, v_ends
  from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
  where b.session_label = v_session and b.is_current
    and (period->>'index')::integer = v_period;
  if v_day <> v_today or v_starts is null or v_ends is null
     or v_minutes < split_part(v_starts, ':', 1)::integer * 60 + split_part(v_starts, ':', 2)::integer
     or v_minutes >= split_part(v_ends, ':', 1)::integer * 60 + split_part(v_ends, ':', 2)::integer then
    return jsonb_build_object('ok', false, 'reason', 'not_running');
  end if;

  select id into v_version from vppsone.timetable_versions
  where session_label = v_session and status = 'published';
  select revision into v_bells_revision from vppsone.bell_schedules
  where session_label = v_session and is_current;
  if v_version is null or v_version is distinct from (p_command->>'timetable_version_id')::uuid then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- Nobody has been put in that lesson meanwhile.
  if exists (
    select 1 from vppsone.cover_duties
    where session_label = v_session and day = v_day and need_key = v_need->>'need_key'
      and status in ('assigned', 'needs_help')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- The teacher can be there.
  if not exists (select 1 from vppsone.staff_profiles where id = v_covering and is_active)
     or exists (
       select 1 from vppsone.teacher_absences ta
       where ta.staff_profile_id = v_covering and ta.day = v_day
         and (cardinality(ta.periods) = 0 or v_period::smallint = any (ta.periods))
     )
     or exists (
       select 1 from vppsone.timetable_slots s
       where s.version_id = v_version and s.day = v_tt_day
         and s.period = v_period::smallint and s.staff_profile_id = v_covering
     )
     or exists (
       select 1 from vppsone.cover_duties d
       where d.session_label = v_session and d.day = v_day and d.period = v_period::smallint
         and d.covering_staff_id = v_covering and d.status = 'assigned'
     ) then
    return jsonb_build_object('ok', false, 'reason', 'refused_override');
  end if;

  insert into vppsone.cover_days (session_label, day) values (v_session, v_day)
  on conflict (session_label, day) do nothing;
  select * into v_day_row from vppsone.cover_days
  where session_label = v_session and day = v_day for update;

  select coalesce(max(revision), 0) + 1 into v_revision
  from vppsone.cover_duties
  where session_label = v_session and day = v_day and need_key = v_need->>'need_key';

  v_new_id := vppsone.cover_duty_insert(
    v_need || jsonb_build_object(
      'status', 'assigned',
      'covering_staff_id', v_covering,
      'suggested_staff_id', null,
      'reason', null,
      'source', 'manual',
      'pinned', true,
      'match_tier', null,
      'warnings', '[]'::jsonb
    ),
    v_session, v_day, v_revision, null, v_day_row.revision + 1, v_id, v_actor
  );
  perform vppsone.cover_notice_queue(v_new_id, 'cover_assigned', v_id);

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
    'kind', 'late_assign',
    'day', v_day,
    'day_revision', v_day_row.revision + 1,
    'assigned', (v_live->>'assigned')::integer,
    'needs_help', (v_live->>'needs_help')::integer,
    'new', 1,
    'changed', 0,
    'cancelled', 0,
    'unchanged', 0,
    'pinned', 0,
    'skipped_started', 0,
    'notices_queued', (select count(*) from vppsone.staff_notices where command_id = v_id and status = 'pending'),
    'notices_withdrawn', 0,
    'notice_recipients', (select count(distinct staff_profile_id) from vppsone.staff_notices where command_id = v_id and status = 'pending'),
    'recipients_without_phone', (
      select count(distinct n.staff_profile_id)
      from vppsone.staff_notices n
      join vppsone.staff_profiles sp on sp.id = n.staff_profile_id
      where n.command_id = v_id and n.status = 'pending'
        and coalesce(nullif(sp.whatsapp_phone, ''), nullif(sp.phone, '')) is null
    ),
    'replayed', false
  );

  insert into vppsone.cover_commands (id, kind, session_label, day, actor_staff_id, payload_hash, receipt)
  values (v_id, 'late_assign', v_session, v_day, v_actor, v_hash, v_receipt);

  return v_receipt;
end;
$$;

comment on function vppsone.assign_late_cover(jsonb) is
  'Put a teacher into a lesson running now with nobody in it (today, a begun and unfinished period, no live duty). One manual pinned duty and its notice, under the cover day lock. The cover command leaves begun periods alone, so it stays.';

revoke all on function vppsone.assign_late_cover(jsonb) from public, anon, authenticated;
grant execute on function vppsone.assign_late_cover(jsonb) to service_role;

-- ======================================================== fee-migrations/20261026080221_two_reads_every_screen_waited_on.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261026080221_two_reads_every_screen_waited_on.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- Two reads that staff waited on, made cheap. No money rule changes.
--
-- 1. Opening a student's profile counted `audit_logs` by `record_id` alone.
--
--    `getStudentDeletionSafety()` runs on every load of
--    `/protected/students/[studentId]` to decide whether the delete button is
--    offered, and one of its fifteen counts is
--    `audit_logs where record_id = $1`. The only index carrying `record_id` is
--    `idx_audit_logs_record (table_name, record_id, created_at desc)`, which
--    leads on `table_name`, so Postgres walked the whole index: 290 ms on
--    production (42k rows, 63 MB), with pg_stat_statements recording a 6.8 s
--    worst case. The profile streams, but it does not finish until that count
--    returns. With this index the same count is 0.7 ms.
--
--    Built in about six seconds on the current compute, inside the
--    transaction. `audit_logs` writes wait for it; reads do not.
--
-- 2. `get_student_segment_counts` materialised the directory twice over.
--
--    The 24 filter chips on the Students page come from this function. It
--    built a `population` CTE of `v_student_directory d.*` and referenced it
--    four times, so Postgres 17 materialised it -- every column of the view,
--    including the ones no chip reads -- and then scanned the copy once per
--    sub-select. 140 ms per call on production, warm, for 614 students; the
--    same view read directly is about 45 ms.
--
--    The rewrite is one scan with FILTER aggregates. `scoped` was `population`
--    narrowed by `p_statuses`, so it becomes a boolean, `in_scope`, and every
--    count that read `scoped` now reads `population ... filter (where
--    in_scope and ...)`. The enrolment block and populationTotal still count
--    the whole population, exactly as before.
--
--    Dry-run against production before shipping: the JSON returned by the old
--    and new bodies compared EQUAL for p_statuses null, ['active'],
--    ['left','graduated'], and for a text query across all classes. 140 ms ->
--    70 ms.
--
--    CREATE OR REPLACE keeps the existing grants (postgres, service_role,
--    authenticated).

begin;

create index if not exists idx_audit_logs_record_id
  on public.audit_logs using btree (record_id);

create or replace function public.get_student_segment_counts(
  p_session_label text,
  p_class_id uuid default null::uuid,
  p_route_id uuid default null::uuid,
  p_query text default null::text,
  p_statuses text[] default null::text[],
  p_active_classes_only boolean default true
)
returns jsonb
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object(
    'scopeTotal',      count(*) filter (where in_scope),
    'populationTotal', count(*),
    'enrolment', jsonb_build_object(
      'active',      count(*) filter (where seg_active),
      'left',        count(*) filter (where seg_left),
      'leftOwing',   count(*) filter (where seg_left_owing),
      'graduated',   count(*) filter (where seg_graduated),
      'newThisYear', count(*) filter (where seg_new_this_year)
    ),
    'counts', jsonb_build_object(
      'oldBalanceDue',       count(*) filter (where in_scope and seg_old_balance_due),
      'overdue',             count(*) filter (where in_scope and seg_overdue),
      'lateFeePending',      count(*) filter (where in_scope and seg_late_fee_pending),
      'partlyPaid',          count(*) filter (where in_scope and seg_partly_paid),
      'yearClear',           count(*) filter (where in_scope and seg_year_clear),
      'neverPaid',           count(*) filter (where in_scope and seg_never_paid),
      'hasDues',             count(*) filter (where in_scope and seg_has_dues),
      'missingPhone',        count(*) filter (where in_scope and seg_missing_phone),
      'duesNotPrepared',     count(*) filter (where in_scope and seg_dues_not_prepared),
      'missingDob',          count(*) filter (where in_scope and seg_missing_dob),
      'duplicateSr',         count(*) filter (where in_scope and seg_duplicate_sr),
      'pendingSr',           count(*) filter (where in_scope and seg_pending_sr),
      'onTransport',         count(*) filter (where in_scope and seg_on_transport),
      'hasDiscount',         count(*) filter (where in_scope and seg_has_discount),
      'discountRte',         count(*) filter (where in_scope and seg_discount_rte),
      'discountStaffChild',  count(*) filter (where in_scope and seg_discount_staff_child),
      'discountThirdChild',  count(*) filter (where in_scope and seg_discount_third_child),
      'feeException',        count(*) filter (where in_scope and seg_fee_exception),
      'lateFeeWaived',       count(*) filter (where in_scope and seg_late_fee_waived),
      'onEmi',               count(*) filter (where in_scope and seg_on_emi),
      'emiDue',              count(*) filter (where in_scope and seg_emi_due),
      'emiMissed',           count(*) filter (where in_scope and seg_emi_missed)
    )
  )
  from (
    select
      d.*,
      (p_statuses is null or d.record_status::text = any(p_statuses)) as in_scope
    from public.v_student_directory as d
    where d.session_label = p_session_label
      and (not p_active_classes_only or d.class_status = 'active')
      and (p_class_id is null or d.class_id = p_class_id)
      and (p_route_id is null or d.transport_route_id = p_route_id)
      and (
        p_query is null or btrim(p_query) = ''
        or d.search_text like '%' || lower(btrim(p_query)) || '%'
      )
  ) as population;
$function$;

commit;

-- ======================================================== fee-migrations/20261026120000_whatsapp_reminder_profile.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261026120000_whatsapp_reminder_profile.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- How hard the school chases one family: on_time / standard / chronic /
-- hardship / quiet.
--
-- Cadence ("how often") was the only per-family judgement the reminder screen
-- could record. It could not say "this family pays on time, one polite note is
-- plenty" or "this family needs every step", so the office went on unticking
-- the same rows by hand. A profile is that judgement, stored once.
--
-- NULL is the normal state and is NOT "standard". It means "use the
-- suggestion", which the app works out from the ledger on every load (late fees
-- charged on passed installments, fees still owed on them, an active repayment
-- plan). A family who starts paying late moves on their own; a value here is the
-- office fixing a family in place.
--
-- WhatsApp only, like cadence. It never touches `no_call`, which is what the
-- Defaulters call queue reads.

alter table public.student_collection_flags
  add column if not exists whatsapp_profile text,
  add column if not exists whatsapp_profile_set_at timestamptz,
  add column if not exists whatsapp_profile_set_by uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'student_collection_flags_whatsapp_profile_check'
  ) then
    alter table public.student_collection_flags
      add constraint student_collection_flags_whatsapp_profile_check
      check (
        whatsapp_profile is null
        or whatsapp_profile in ('on_time', 'standard', 'chronic', 'hardship', 'quiet')
      );
  end if;
end $$;

comment on column public.student_collection_flags.whatsapp_profile is
  'How hard WhatsApp reminders chase this family: on_time, standard, chronic, hardship or '
  'quiet. NULL means "use the ledger''s suggestion", which the app recomputes on every load. '
  'An audience filter only — the reminder screen picks which profiles a run reaches. '
  'WhatsApp only; it does NOT affect the Defaulters call queue, which reads no_call.';

comment on column public.student_collection_flags.whatsapp_profile_set_at is
  'When the office last set whatsapp_profile by hand.';

comment on column public.student_collection_flags.whatsapp_profile_set_by is
  'auth.users id of whoever last set whatsapp_profile by hand.';

-- IMPORTANT, as on every column this table gains: `no_call` defaults to TRUE.
-- A row inserted only to record a profile must pass `no_call => false`
-- explicitly, or filing a family as "on time" would silently stop the fee
-- collectors calling them. The app updates first and inserts only when there is
-- no row, for exactly this reason.

-- ======================================================== fee-migrations/20261026120020_whatsapp_scheduled_runs_timer.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261026120020_whatsapp_scheduled_runs_timer.sql
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
-- The morning timer for scheduled WhatsApp campaigns — 09:30 IST every day.
--
-- `/api/cron/whatsapp-scheduled-runs` has existed since September, but nothing
-- called it: Vercel's Hobby plan allows two crons and both are spent (the
-- nightly backup and the automatic day close), and a third `vercel.json` entry
-- fails the whole deployment rather than just the cron. pg_cron + pg_net are
-- already how this database calls out on a schedule (the Notion sync), so the
-- timer lives here instead.
--
-- What it sends is decided entirely by the route, under the same guards as a
-- pressed Send: only saved campaigns whose slot has arrived AND whose owner
-- ticked "sends itself". Production held ZERO saved campaigns when this was
-- written, so on its first morning it sends nothing at all.
--
-- The secret lives in Vault as `VPPS_WHATSAPP_CRON_SECRET` and matches the
-- `WHATSAPP_CRON_SECRET` env var on the Vercel production deployment. Until
-- that secret exists the job does not call out at all — so a preview branch or
-- the dev project, which run this same migration, never ping production.
--
-- 04:00 UTC is 09:30 IST: office hours, and inside the 08:00-20:00 quiet-hours
-- guard, so a scheduled run is never the thing that wakes a parent.

-- [VPPS One] cron.unschedule block removed (see header).

-- [VPPS One] cron.schedule block removed (see header).

-- [VPPS One] With both cron blocks removed this file does nothing. The no-op
-- below lets it be applied anyway, so the ledger records every fee version.
select 1;

-- ======================================================== fee-migrations/20261026120040_school_notice_sends.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261026120040_school_notice_sends.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- School notices on WhatsApp: absence alerts, exam schedules, parent-teacher
-- meetings, closures. The everyday messages a school sends that are NOT about
-- money.
--
-- Their own send log, deliberately NOT `whatsapp_reminder_sends`:
--
--   * That table's rows are the fee-reminder cadence's evidence. An absence
--     alert counted there would push a family's next FEE reminder out by a
--     week for the crime of their child being ill.
--   * Its unique index claims a student's day per fee campaign; an absence
--     alert and a fee notice on the same morning are both legitimate.
--   * Its money columns (due_amount, pay_code) mean nothing here.
--
-- One row per child per notice per day. A phone with siblings on a closure
-- notice gets ONE message naming every child; the siblings get
-- `covered_by_sibling` rows carrying the same provider id, exactly as the fee
-- reminders record them, so "already sent today" still holds per child.

create table if not exists public.school_notice_sends (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  student_id uuid not null references public.students (id) on delete cascade,
  notice_kind text not null,
  campaign_name text not null,
  sent_on date not null,
  destination text,
  language text,
  template_params jsonb not null default '[]'::jsonb,
  status text not null default 'pending',
  provider_message_id text,
  error_message text,
  -- One press of Send, so the screen can show a batch as one line of history.
  batch_id uuid not null,
  sent_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint school_notice_sends_kind_check
    check (notice_kind in ('absent_today', 'exam_schedule', 'ptm', 'school_closed')),
  constraint school_notice_sends_status_check
    check (status in ('pending', 'sent', 'failed', 'covered_by_sibling'))
);

comment on table public.school_notice_sends is
  'One row per child per school notice (absence, exam schedule, PTM, closure) per day. '
  'Separate from whatsapp_reminder_sends so a non-fee message never moves a family''s '
  'fee-reminder cadence. Siblings named in one message carry covered_by_sibling rows.';

-- Claimed BEFORE the provider call, like the fee reminders: two staff sending
-- the same absence list collide here and only one message goes.
create unique index if not exists school_notice_sends_one_a_day
  on public.school_notice_sends (session_label, student_id, notice_kind, sent_on);

create index if not exists school_notice_sends_batch_idx
  on public.school_notice_sends (batch_id);

create index if not exists school_notice_sends_month_idx
  on public.school_notice_sends (sent_on);

alter table public.school_notice_sends enable row level security;

-- Staff may read the history; every write goes through the server with the
-- service role, behind the screen's own permission check.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'school_notice_sends'
      and policyname = 'school_notice_sends: staff read'
  ) then
    create policy "school_notice_sends: staff read"
      on public.school_notice_sends for select
      using ((select auth.role()) = 'authenticated');
  end if;
end $$;

-- ======================================================== migrations/20261027080847_assist.sql
-- The AI helper (D-324): Claude drafts, a person decides.
--
-- Two tables, both private to the server:
--  * assist_settings — one row the admin edits on Settings → AI helper: a
--    master switch, a monthly budget in US dollars, a per-person daily cap
--    and the features that are switched off.
--  * assist_log — one row per draft: who asked, which feature, which model,
--    the tokens and the estimated cost, and what the person did with it
--    (kept, edited, discarded). No prompt and no answer is stored: the log is
--    for the budget and for knowing which features are worth their cost,
--    never a second copy of what staff wrote about children.
--
-- RLS on with no policies, and nothing granted to anon or authenticated: the
-- app reads and writes these with the service role after its own permission
-- check, as it does the smoke lab tables.
--
-- Rollback: drop function vppsone.assist_usage_by_staff(timestamptz);
-- drop function vppsone.assist_usage_summary(timestamptz);
-- drop function vppsone.assist_budget_state(uuid, timestamptz, timestamptz);
-- drop table vppsone.assist_log; drop table vppsone.assist_settings;

create table vppsone.assist_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default true,
  monthly_budget_usd numeric(8, 2) not null default 25
    check (monthly_budget_usd >= 0 and monthly_budget_usd <= 1000),
  daily_cap_per_staff integer not null default 60
    check (daily_cap_per_staff between 0 and 1000),
  disabled_features text[] not null default '{}',
  updated_by uuid references vppsone.staff_profiles (id),
  updated_at timestamptz not null default now()
);

comment on table vppsone.assist_settings is
  'AI helper settings (D-324). One row. monthly_budget_usd stops new drafts once the estimated spend this month (IST) reaches it; daily_cap_per_staff limits drafts per person per IST day.';

insert into vppsone.assist_settings (id) values (1) on conflict do nothing;

create table vppsone.assist_log (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id),
  feature text not null check (feature ~ '^[a-z]{2,20}$'),
  task text not null check (task ~ '^[a-z]{2,20}\.[a-z]{2,20}$'),
  model text not null check (char_length(model) between 3 and 60),
  outcome text not null check (outcome in ('drafted', 'refused', 'failed')),
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  cache_read_tokens integer not null default 0 check (cache_read_tokens >= 0),
  cost_usd numeric(12, 6) not null default 0 check (cost_usd >= 0),
  decision text check (decision in ('kept', 'edited', 'discarded')),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  constraint assist_log_decided check ((decision is null) = (decided_at is null))
);

comment on table vppsone.assist_log is
  'One row per AI helper request (D-324): tokens, estimated cost and what the person did with the draft. Never the prompt or the answer.';

create index assist_log_created on vppsone.assist_log (created_at);
create index assist_log_staff_created on vppsone.assist_log (staff_profile_id, created_at);

alter table vppsone.assist_settings enable row level security;
alter table vppsone.assist_log enable row level security;

revoke all on vppsone.assist_settings, vppsone.assist_log from anon, authenticated;
grant all on vppsone.assist_settings, vppsone.assist_log to service_role;

-- The two numbers every request is checked against, in one round trip.
create function vppsone.assist_budget_state(
  p_staff uuid,
  p_month_start timestamptz,
  p_day_start timestamptz
)
returns table (spent_usd numeric, staff_today integer)
language sql
stable
set search_path = ''
as $$
  select
    coalesce((select sum(l.cost_usd) from vppsone.assist_log l where l.created_at >= p_month_start), 0),
    (select count(*)::integer from vppsone.assist_log l
       where l.staff_profile_id = p_staff and l.created_at >= p_day_start);
$$;

-- Settings → AI helper: one line per feature since a moment.
create function vppsone.assist_usage_summary(p_since timestamptz)
returns table (
  feature text,
  uses integer,
  cost_usd numeric,
  kept integer,
  edited integer,
  discarded integer,
  refused integer,
  failed integer
)
language sql
stable
set search_path = ''
as $$
  select
    l.feature,
    count(*)::integer,
    coalesce(sum(l.cost_usd), 0),
    count(*) filter (where l.decision = 'kept')::integer,
    count(*) filter (where l.decision = 'edited')::integer,
    count(*) filter (where l.decision = 'discarded')::integer,
    count(*) filter (where l.outcome = 'refused')::integer,
    count(*) filter (where l.outcome = 'failed')::integer
  from vppsone.assist_log l
  where l.created_at >= p_since
  group by l.feature
  order by count(*) desc;
$$;

-- Settings → AI helper: who uses it most, since a moment.
create function vppsone.assist_usage_by_staff(p_since timestamptz)
returns table (staff_profile_id uuid, uses integer, cost_usd numeric)
language sql
stable
set search_path = ''
as $$
  select l.staff_profile_id, count(*)::integer, coalesce(sum(l.cost_usd), 0)
  from vppsone.assist_log l
  where l.created_at >= p_since
  group by l.staff_profile_id
  order by count(*) desc
  limit 20;
$$;

revoke all on function vppsone.assist_budget_state(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function vppsone.assist_usage_summary(timestamptz) from public, anon, authenticated;
revoke all on function vppsone.assist_usage_by_staff(timestamptz) from public, anon, authenticated;
grant execute on function vppsone.assist_budget_state(uuid, timestamptz, timestamptz) to service_role;
grant execute on function vppsone.assist_usage_summary(timestamptz) to service_role;
grant execute on function vppsone.assist_usage_by_staff(timestamptz) to service_role;

-- ======================================================== fee-migrations/20261027090000_whatsapp_cron_secret_check.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261027090000_whatsapp_cron_secret_check.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- The morning timer's secret, checked where it lives.
--
-- `20261026120020` schedules pg_cron to call /api/cron/whatsapp-scheduled-runs
-- at 09:30 IST with Vault's `VPPS_WHATSAPP_CRON_SECRET`. The route used to
-- accept only Vercel env vars, so the same value had to be copied into a
-- `WHATSAPP_CRON_SECRET` on the production deployment — two copies of one
-- secret, and a copy nobody with database access could make. This lets the
-- route ask Postgres instead: is this the timer's secret, yes or no.
--
-- Never returns the secret. SECURITY DEFINER so it can read Vault; EXECUTE is
-- revoked from everyone but the service role, which is what the route calls
-- with. A NULL or wrong value is simply false.

create or replace function public.whatsapp_cron_secret_matches(p_secret text)
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
      where ds.name = 'VPPS_WHATSAPP_CRON_SECRET'
      limit 1
    ),
    false
  );
$$;

revoke all on function public.whatsapp_cron_secret_matches(text) from public;
revoke all on function public.whatsapp_cron_secret_matches(text) from anon, authenticated;
grant execute on function public.whatsapp_cron_secret_matches(text) to service_role;

comment on function public.whatsapp_cron_secret_matches(text) is
  'True when p_secret equals Vault''s VPPS_WHATSAPP_CRON_SECRET. Lets '
  '/api/cron/whatsapp-scheduled-runs accept the pg_cron timer without a second copy of the '
  'secret in Vercel. Never returns the secret; service_role only.';

-- ======================================================== migrations/20261027114837_document_storage_providers.sql
-- Student documents in a school Google Shared Drive (D-333).
--
-- The bytes may move; the index does not. Every document is still one row in
-- vppsone.student_documents, read through the same scoped policy, and opened
-- only through /documents/<id> after a permission check. What this adds:
--
--  * where the bytes are (`storage_provider`), and for Drive the file id, the
--    sha256 Drive itself reported, a content version, the upload's state and
--    the browser's idempotency key, so a double-tapped Save is one document;
--  * `removed_at` / `removed_by`: removing a Drive document hides the row and
--    keeps the file. Nothing in Drive is deleted or overwritten by the app;
--  * document_upload_sessions: the Drive resumable-upload address for a file
--    in flight. That address is a capability to write one file, so the table
--    is server-only — RLS on, no policies, nothing granted to anon or
--    authenticated;
--  * drive_folders: one Drive folder per academic session, created once. The
--    primary key is what stops two first uploads creating two folders;
--  * file_storage_settings: one row, server-only. Where new documents go
--    (`supabase` until somebody changes it), an optional pilot list of staff
--    whose uploads go to Drive first, and the non-secret identifiers of the
--    Google project, Workload Identity pool, service account and Shared Drive.
--    No key, token or password is stored here or anywhere: the app proves who
--    it is with its Vercel OIDC token (Workload Identity Federation).
--
-- Existing rows keep their meaning: every one is `supabase`, `stored`. The
-- migration is safe to apply before the code that uses it: every new column
-- has a default or is nullable, and no existing query or embed changes.
--
-- Rollback (only while no row is 'gdrive'):
--   restore vppsone.archive_object_listing() from 20261004124254 (two buckets);
--   alter table vppsone.student_documents
--     drop constraint student_documents_backup_complete,
--     drop column backed_up_at, drop column backup_key_fingerprint,
--     drop column backup_sha256, drop column backup_path;
--   (the empty bucket vppsone-drive-backups may stay)
--   drop table vppsone.file_storage_settings;
--   drop table vppsone.drive_folders;
--   drop table vppsone.document_upload_sessions;
--   alter table vppsone.student_documents
--     drop constraint student_documents_drive_complete,
--     drop column removed_by, drop column removed_at,
--     drop column drive_verified_at,
--     drop column client_request_id, drop column upload_state,
--     drop column content_version, drop column content_sha256,
--     drop column drive_file_id, drop column storage_provider;

alter table vppsone.student_documents
  add column storage_provider text not null default 'supabase'
    check (storage_provider in ('supabase', 'gdrive')),
  add column drive_file_id text
    check (drive_file_id is null or drive_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  add column content_sha256 text
    check (content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$'),
  add column content_version integer not null default 1
    check (content_version >= 1),
  add column upload_state text not null default 'stored'
    check (upload_state in ('uploading', 'stored', 'failed')),
  add column client_request_id uuid,
  add column removed_at timestamptz,
  -- Deliberately no foreign key: a second key to staff_profiles would make
  -- the existing unnamed `staff_profiles(display_name)` embed ambiguous
  -- (PGRST201) for any build that predates this migration, so applying it
  -- before the code ships would break every student page.
  add column removed_by uuid,
  -- When the nightly job last confirmed Drive still holds the same bytes.
  add column drive_verified_at timestamptz,
  add constraint student_documents_drive_complete check (
    storage_provider <> 'gdrive'
    or upload_state <> 'stored'
    or (drive_file_id is not null and content_sha256 is not null)
  );

comment on column vppsone.student_documents.storage_provider is
  'Where the bytes are: supabase (bucket vppsone-documents, storage_path) or gdrive (drive_file_id in the school Shared Drive).';
comment on column vppsone.student_documents.content_sha256 is
  'sha256 of the stored bytes. For gdrive, the value Drive reported after upload, compared with the one the browser declared.';
comment on column vppsone.student_documents.removed_at is
  'Hidden from staff. For gdrive the file is kept in the Shared Drive; nothing is deleted by the app.';

create unique index student_documents_drive_file_unique
  on vppsone.student_documents (drive_file_id)
  where drive_file_id is not null;

create unique index student_documents_client_request_unique
  on vppsone.student_documents (client_request_id)
  where client_request_id is not null;

create table vppsone.document_upload_sessions (
  document_id uuid primary key
    references vppsone.student_documents (id) on delete cascade,
  drive_session_url text not null
    check (drive_session_url like 'https://www.googleapis.com/upload/drive/v3/%'),
  declared_bytes bigint not null check (declared_bytes between 1 and 10485760),
  declared_sha256 text not null check (declared_sha256 ~ '^[0-9a-f]{64}$'),
  received_bytes bigint not null default 0 check (received_bytes >= 0),
  created_by uuid not null references vppsone.staff_profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint document_upload_sessions_progress check (received_bytes <= declared_bytes)
);

comment on table vppsone.document_upload_sessions is
  'A Drive document upload in flight (D-333). The session URL can write one file, so this table is server-only.';

create table vppsone.drive_folders (
  session_label text primary key check (char_length(session_label) between 1 and 40),
  folder_id text not null unique check (folder_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  created_at timestamptz not null default now()
);

comment on table vppsone.drive_folders is
  'The Shared Drive folder that holds one academic session''s documents (D-333).';

create table vppsone.file_storage_settings (
  id smallint primary key default 1 check (id = 1),
  documents_provider text not null default 'supabase'
    check (documents_provider in ('supabase', 'gdrive')),
  drive_pilot_staff_ids uuid[] not null default '{}',
  shared_drive_id text check (shared_drive_id is null or shared_drive_id ~ '^[A-Za-z0-9_-]{10,100}$'),
  root_folder_id text check (root_folder_id is null or root_folder_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  google_project_number text check (google_project_number is null or google_project_number ~ '^[0-9]{6,20}$'),
  workload_pool_id text check (workload_pool_id is null or workload_pool_id ~ '^[a-z0-9-]{4,32}$'),
  workload_provider_id text check (workload_provider_id is null or workload_provider_id ~ '^[a-z0-9-]{4,32}$'),
  service_account_email text check (
    service_account_email is null
    or service_account_email ~ '^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$'
  ),
  recovery_public_key text check (
    recovery_public_key is null or recovery_public_key like '-----BEGIN PUBLIC KEY-----%'
  ),
  recovery_key_fingerprint text check (
    recovery_key_fingerprint is null or recovery_key_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  last_check_at timestamptz,
  last_check_ok boolean,
  last_check_detail text check (last_check_detail is null or char_length(last_check_detail) <= 300),
  updated_by uuid references vppsone.staff_profiles (id),
  updated_at timestamptz not null default now(),
  constraint file_storage_settings_drive_needs_config check (
    documents_provider <> 'gdrive'
    or (
      shared_drive_id is not null and root_folder_id is not null
      and google_project_number is not null and workload_pool_id is not null
      and workload_provider_id is not null and service_account_email is not null
    )
  ),
  constraint file_storage_settings_recovery_pair check (
    (recovery_public_key is null) = (recovery_key_fingerprint is null)
  )
);

comment on table vppsone.file_storage_settings is
  'Where new student documents are stored (D-333). One row, server-only. Identifiers only: no key, token or secret.';

insert into vppsone.file_storage_settings (id) values (1) on conflict do nothing;

-- The independent copy (D-333). A Drive document is copied, sealed for the
-- school's recovery key, into a private bucket on this project — a different
-- provider from Google, so losing either one leaves the other. The app holds
-- only the public half of the key and cannot read these copies back.
alter table vppsone.student_documents
  add column backup_path text,
  add column backup_sha256 text check (backup_sha256 is null or backup_sha256 ~ '^[0-9a-f]{64}$'),
  add column backup_key_fingerprint text
    check (backup_key_fingerprint is null or backup_key_fingerprint ~ '^[0-9a-f]{64}$'),
  add column backed_up_at timestamptz,
  add constraint student_documents_backup_complete check (
    (backed_up_at is null) = (backup_path is null)
    and (backup_path is null) = (backup_sha256 is null)
    and (backup_path is null) = (backup_key_fingerprint is null)
  );

create index student_documents_backup_pending
  on vppsone.student_documents (created_at)
  where storage_provider = 'gdrive' and upload_state = 'stored' and backed_up_at is null;

insert into storage.buckets (id, name, public, file_size_limit)
values ('vppsone-drive-backups', 'vppsone-drive-backups', false, 16777216)
on conflict (id) do nothing;

-- Year-end archives carry the sealed copies too, byte for byte.
create or replace function vppsone.archive_object_listing()
returns table (bucket text, name text, size bigint, mimetype text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.bucket_id::text, o.name::text, coalesce((o.metadata->>'size')::bigint, 0), o.metadata->>'mimetype'
  from storage.objects o
  where o.bucket_id in ('vppsone-documents', 'vppsone-photos', 'vppsone-drive-backups')
  order by o.bucket_id, o.name;
$$;

alter table vppsone.document_upload_sessions enable row level security;
alter table vppsone.drive_folders enable row level security;
alter table vppsone.file_storage_settings enable row level security;

revoke all on vppsone.document_upload_sessions from anon, authenticated;
revoke all on vppsone.drive_folders from anon, authenticated;
revoke all on vppsone.file_storage_settings from anon, authenticated;

grant all on vppsone.document_upload_sessions to service_role;
grant all on vppsone.drive_folders to service_role;
grant all on vppsone.file_storage_settings to service_role;

-- ======================================================== migrations/20261028035840_drive_central_backup.sql
-- One central store, and nightly backups into it (D-334).
--
-- The owner (27-28 Oct) chose one administrator-controlled destination: the
-- folder "VPPS One documents" in the school's Shared Drive "Share", where
-- raj@vpps.co.in is the only manager. Every role's uploads go there through
-- the backend's service account; nobody connects their own Google account.
-- The operational database stays the system of record; Drive holds the
-- document bytes and, from this migration on, a nightly encrypted copy of
-- everything else:
--
--  * drive_snapshots: one row per nightly snapshot — every `vppsone` table and
--    every fee (`public`) table as canonical JSON, with counts and Postgres
--    digests, gzipped and sealed for the school's recovery key, plus a
--    plaintext manifest beside it (names, counts, checksums; no rows);
--  * drive_object_copies: a sealed copy in Drive of every object in the
--    buckets that hold people's files (documents, photographs, voice notes,
--    the fee app's photographs), so the bytes are recoverable from Drive too;
--  * backup_public_tables() / backup_public_table_export(): read the fee
--    tables for the snapshot. Read only: nothing here alters, adds to or
--    grants on a fee table;
--  * backup_object_listing(): the objects the copy step looks at;
--  * student_documents.migrated_at: a bucket document copied into Drive. Its
--    `storage_path` still names the bucket original, which is kept;
--  * file_storage_settings.bucket_migration_approved_at: the copy-only
--    migration of bucket documents runs only while this is set;
--  * file_storage_settings_history and a guard: every change to the settings
--    row is recorded, and changing the destination (drive, folder, project,
--    pool, provider or service account) once documents live in Drive is
--    refused unless the same transaction says
--    `set local vppsone.confirm_storage_move = 'yes'`.
--
-- No retention is decided here: the owner chose to keep every backup for
-- now, and the service account cannot delete anything in Drive anyway.
--
-- Rollback (nothing depends on these but the backup job):
--   drop trigger file_storage_settings_guard on vppsone.file_storage_settings;
--   drop trigger file_storage_settings_no_truncate on vppsone.file_storage_settings;
--   drop function vppsone.file_storage_settings_guard();
--   drop function vppsone.backup_schema_export(text);
--   drop table vppsone.file_storage_settings_history;
--   drop function vppsone.backup_object_listing();
--   drop function vppsone.backup_public_table_export(text);
--   drop function vppsone.backup_public_tables();
--   drop table vppsone.drive_object_copies; drop table vppsone.drive_snapshots;
--   alter table vppsone.file_storage_settings drop column bucket_migration_approved_at;
--   alter table vppsone.student_documents drop constraint student_documents_migrated_kept,
--     drop column migration_note, drop column migration_failed_at;
--   (student_documents.migrated_at: first put migrated rows back with
--    update vppsone.student_documents set storage_provider = 'supabase',
--      drive_file_id = null, migrated_at = null where migrated_at is not null;)

alter table vppsone.student_documents
  add column migrated_at timestamptz,
  -- A move that did not match or failed is parked, with why, and not tried
  -- again until somebody clears it: a stuck row must not be re-read and
  -- re-uploaded every night.
  add column migration_failed_at timestamptz,
  add column migration_note text check (migration_note is null or char_length(migration_note) <= 300),
  add constraint student_documents_migrated_kept check (
    migrated_at is null or (storage_provider = 'gdrive' and storage_path not like 'gdrive/%')
  );

comment on column vppsone.student_documents.migrated_at is
  'Copied from the bucket into Drive (D-334). storage_path still names the bucket original, which is kept for rollback.';

alter table vppsone.file_storage_settings
  add column bucket_migration_approved_at timestamptz;

comment on column vppsone.file_storage_settings.bucket_migration_approved_at is
  'When set, the nightly job copies bucket documents into Drive, copy-only (D-334).';

create table vppsone.drive_snapshots (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  bundle_drive_file_id text not null unique check (bundle_drive_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  manifest_drive_file_id text not null unique check (manifest_drive_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  key_fingerprint text not null check (key_fingerprint ~ '^[0-9a-f]{64}$'),
  sealed_sha256 text not null check (sealed_sha256 ~ '^[0-9a-f]{64}$'),
  plain_sha256 text not null check (plain_sha256 ~ '^[0-9a-f]{64}$'),
  sealed_bytes bigint not null check (sealed_bytes > 0),
  schema_version text,
  app_commit text,
  table_count integer not null check (table_count >= 0),
  row_count bigint not null check (row_count >= 0),
  object_count integer not null check (object_count >= 0)
);

comment on table vppsone.drive_snapshots is
  'Nightly encrypted snapshots of every vppsone and fee table in the school Drive (D-334). The bytes are in Drive; this is the catalogue.';

create table vppsone.drive_object_copies (
  bucket text not null check (bucket in ('vppsone-documents', 'vppsone-photos', 'defaulter-voice-notes', 'student-photos')),
  object_name text not null check (char_length(object_name) between 1 and 1024),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes bigint not null check (bytes >= 0),
  drive_file_id text not null unique check (drive_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  sealed_sha256 text not null check (sealed_sha256 ~ '^[0-9a-f]{64}$'),
  key_fingerprint text not null check (key_fingerprint ~ '^[0-9a-f]{64}$'),
  copied_at timestamptz not null default now(),
  -- Per key: a new recovery key re-seals every file, and the old copies stay.
  primary key (bucket, object_name, sha256, key_fingerprint)
);

comment on table vppsone.drive_object_copies is
  'A sealed copy in the school Drive of one version of one stored object (D-334).';

create table vppsone.file_storage_settings_history (
  id bigserial primary key,
  changed_at timestamptz not null default now(),
  changed_by text not null default current_user,
  old_row jsonb not null,
  new_row jsonb not null
);

comment on table vppsone.file_storage_settings_history is
  'Every change to file_storage_settings, before and after (D-334). The recovery public key is left out; its fingerprint is kept.';

create or replace function vppsone.backup_public_tables()
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select t.table_name::text
  from information_schema.tables t
  where t.table_schema = 'public' and t.table_type = 'BASE TABLE'
  order by 1;
$$;

-- The same shape as archive_table_export, for a fee table: rows as canonical
-- JSON text, their count and their digest, all from one statement.
create or replace function vppsone.backup_public_table_export(p_table text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
  v_count bigint;
  v_md5 text;
begin
  if p_table not in (select vppsone.backup_public_tables()) then
    raise exception 'not a fee table: %', p_table;
  end if;
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text), ''[]''::jsonb), count(*), '
    || 'md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')) from public.%I t',
    p_table
  ) into v_rows, v_count, v_md5;
  return jsonb_build_object('rows', v_rows::text, 'count', v_count, 'md5', v_md5);
end;
$$;

-- Every table of one schema in ONE statement, so all of them come from the
-- same moment: a STABLE function's queries share the calling query's
-- snapshot. Ordinary tables only (relkind 'r'), so a partitioned table is
-- exported once, through its partitions. The per-table export above stays as
-- the fallback if this one call is ever too big or too slow.
create or replace function vppsone.backup_schema_export(p_schema text)
returns table (table_name text, row_count bigint, md5 text, rows text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_table text;
begin
  if p_schema not in ('vppsone', 'public') then
    raise exception 'not a backed-up schema: %', p_schema;
  end if;
  for v_table in
    select c.relname::text
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = p_schema and c.relkind = 'r'
      and not (p_schema = 'vppsone' and c.relname = 'rate_limits')
    order by 1
  loop
    return query execute format(
      'select %L::text, count(*), '
      || 'md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' order by to_jsonb(t)::text), '''')), '
      || 'coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text), ''[]''::jsonb)::text '
      || 'from %I.%I t',
      v_table, p_schema, v_table
    );
  end loop;
end;
$$;

create or replace function vppsone.backup_object_listing()
returns table (bucket text, name text, size bigint, mimetype text, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select o.bucket_id::text, o.name::text, coalesce((o.metadata->>'size')::bigint, 0), o.metadata->>'mimetype',
         coalesce(o.updated_at, o.created_at)
  from storage.objects o
  where o.bucket_id in ('vppsone-documents', 'vppsone-photos', 'defaulter-voice-notes', 'student-photos')
  order by o.bucket_id, o.name;
$$;

-- Not SECURITY DEFINER: it must record who ran the change, and every writer
-- of this table already holds the grants it uses.
create or replace function vppsone.file_storage_settings_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'The document storage settings row is never deleted (D-334); change its values instead.';
  end if;

  if (
    (old.shared_drive_id is not null and new.shared_drive_id is distinct from old.shared_drive_id)
    or (old.root_folder_id is not null and new.root_folder_id is distinct from old.root_folder_id)
    or (old.google_project_number is not null and new.google_project_number is distinct from old.google_project_number)
    or (old.workload_pool_id is not null and new.workload_pool_id is distinct from old.workload_pool_id)
    or (old.workload_provider_id is not null and new.workload_provider_id is distinct from old.workload_provider_id)
    or (old.service_account_email is not null and new.service_account_email is distinct from old.service_account_email)
  )
  and exists (select 1 from vppsone.student_documents where storage_provider = 'gdrive')
  and coalesce(current_setting('vppsone.confirm_storage_move', true), '') <> 'yes'
  then
    raise exception 'Changing the document storage destination needs explicit confirmation (D-334): copy every Drive document first, then, in one transaction, set local vppsone.confirm_storage_move = ''yes'', change the row and delete from vppsone.drive_folders (its folders belong to the old destination).';
  end if;

  new.updated_at := now();
  insert into vppsone.file_storage_settings_history (changed_by, old_row, new_row)
  values (
    -- Bracketed: `||` and `->>` share a precedence, and unbracketed this
    -- read ' as ' as JSON and refused every update (found by the dry run).
    session_user || coalesce(' as ' || ((nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'role'), ''),
    to_jsonb(old) - 'recovery_public_key',
    to_jsonb(new) - 'recovery_public_key'
  );
  return new;
end;
$$;

create trigger file_storage_settings_guard
  before update or delete on vppsone.file_storage_settings
  for each row execute function vppsone.file_storage_settings_guard();

create trigger file_storage_settings_no_truncate
  before truncate on vppsone.file_storage_settings
  for each statement execute function vppsone.file_storage_settings_guard();

alter table vppsone.drive_snapshots enable row level security;
alter table vppsone.drive_object_copies enable row level security;
alter table vppsone.file_storage_settings_history enable row level security;

revoke all on vppsone.drive_snapshots from anon, authenticated;
revoke all on vppsone.drive_object_copies from anon, authenticated;
revoke all on vppsone.file_storage_settings_history from anon, authenticated;
revoke all on sequence vppsone.file_storage_settings_history_id_seq from anon, authenticated;

grant all on vppsone.drive_snapshots to service_role;
grant all on vppsone.drive_object_copies to service_role;
grant all on vppsone.file_storage_settings_history to service_role;
grant usage on sequence vppsone.file_storage_settings_history_id_seq to service_role;

revoke all on function vppsone.backup_public_tables() from public, anon, authenticated;
revoke all on function vppsone.backup_public_table_export(text) from public, anon, authenticated;
revoke all on function vppsone.backup_object_listing() from public, anon, authenticated;
revoke all on function vppsone.backup_schema_export(text) from public, anon, authenticated;
grant execute on function vppsone.backup_schema_export(text) to service_role;
revoke all on function vppsone.file_storage_settings_guard() from public, anon, authenticated;
grant execute on function vppsone.backup_public_tables() to service_role;
grant execute on function vppsone.backup_public_table_export(text) to service_role;
grant execute on function vppsone.backup_object_listing() to service_role;

-- ======================================================== fee-migrations/20261028140000_online_payment_mode.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20261028140000_online_payment_mode.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added.
-- ============================================================================
-- A receipt paid through the online gateway says so.
--
-- Razorpay takes UPI, cards and netbanking, so none of the counter's four modes
-- describes it truthfully: calling a card payment "UPI" would put it in the
-- wrong column of every day-close and export. `online` is its own mode.
--
-- Its own migration because Postgres refuses to USE a new enum value in the
-- transaction that adds it ("unsafe use of new value"), and
-- `20261028140100_online_payments.sql` posts with it.
--
-- The Payment Desk never offers it: `PAYMENT_MODES` in
-- `src/platform/config/fee-rules.ts` is the desk's list and does not carry it.
-- Only `public.online_payment_apply_capture` posts an `online` receipt.

alter type public.payment_mode add value if not exists 'online';
