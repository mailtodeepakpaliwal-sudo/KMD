-- KMD One database setup — part 8 of 11. Run the parts in order, each once.
-- Files: 20261104083132_builtin_ai_key_status.sql … 20261107045020_ai_report_export_kind.sql

-- ======================================================== migrations/20261104083132_builtin_ai_key_status.sql
-- Built-in AI: which key answered, and what each key last did (4 November 2026).
--
-- ai_jobs.key_type records how the answering key is paid for: the free AI
-- Studio tier, Google billing, or prepaid API credits (lib/ai/router.ts).
-- builtin_ai_provider_status keeps one row per key: working, out of quota
-- (with the time a free-tier daily quota resets, midnight Pacific), or
-- failing, with a fixed failure category and HTTP status only. Every server
-- instance reads it, so one exhausted free key is skipped everywhere.
-- builtin_ai_settings.last_smoke holds the admin key check's results.
-- Server only: RLS on, no browser grants.

alter table vppsone.ai_jobs add column key_type text check (key_type in ('free', 'paid', 'credits'));

create table vppsone.builtin_ai_provider_status (
  provider text primary key check (provider in ('gemini-free', 'gemini-paid', 'anthropic', 'openai')),
  state text not null check (state in ('ok', 'quota', 'failing')),
  problem text check (problem ~ '^[a-z_]{1,32}$'),
  http_status integer check (http_status between 100 and 599),
  model text check (char_length(model) <= 80),
  blocked_until timestamptz,
  checked_at timestamptz not null default now()
);
alter table vppsone.builtin_ai_provider_status enable row level security;
revoke all on vppsone.builtin_ai_provider_status from public, anon, authenticated;
grant select, insert, update on vppsone.builtin_ai_provider_status to service_role;

alter table vppsone.builtin_ai_settings add column last_smoke jsonb;
alter table vppsone.builtin_ai_settings add column last_smoke_at timestamptz;

-- ======================================================== migrations/20261105063256_assist_drafts_cover_reports.sql
-- AI that shows up without being asked (D-418) and the cover period's report
-- back to the absent teacher (D-419).
--
-- assist_drafts: drafts the app prepares for one member of staff before they
-- ask: the plan for a cover duty, a class's week of notes. A draft is a
-- suggestion only; it never becomes school data until the person uses it on
-- the ordinary screen. One row per (person, kind, thing it is about), so a
-- rerun replaces rather than piles up. Expired rows are purged with the log.
--
-- cover_reports: one line from the teacher who covered a period ("settled",
-- "work done", "a problem") with an optional sentence, for the teacher who was
-- away. One report per duty; the covering teacher may change it.
--
-- Both private, like assist_log: RLS on with no policies and nothing granted to
-- anon or authenticated. The app reaches them only through the service role,
-- after its own permission and ownership checks.

create table vppsone.assist_drafts (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  kind text not null check (kind in ('cover_plan', 'class_digest')),
  ref text not null check (char_length(ref) between 1 and 120),
  session_label text not null check (session_label ~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$'),
  title_en text not null check (char_length(title_en) between 1 and 160),
  title_hi text not null check (char_length(title_hi) between 1 and 160),
  href text check (href is null or (href ~ '^/[A-Za-z0-9/_?=&.%-]*$' and char_length(href) <= 300)),
  payload jsonb not null,
  log_id uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  decision text check (decision in ('kept', 'edited', 'discarded')),
  decided_at timestamptz,
  constraint assist_drafts_decided check ((decision is null) = (decided_at is null)),
  constraint assist_drafts_one unique (staff_profile_id, kind, ref)
);

create index assist_drafts_waiting on vppsone.assist_drafts (staff_profile_id, expires_at) where decision is null;

create table vppsone.cover_reports (
  duty_id uuid primary key references vppsone.cover_duties (id) on delete cascade,
  session_label text not null check (session_label ~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$'),
  written_by uuid not null references vppsone.staff_profiles (id) on delete cascade,
  outcome text not null check (outcome in ('settled', 'work_done', 'problem')),
  body text check (body is null or char_length(body) between 1 and 600),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  seen_by uuid[] not null default '{}'
);

create index cover_reports_recent on vppsone.cover_reports (session_label, created_at desc);

alter table vppsone.assist_drafts enable row level security;
alter table vppsone.cover_reports enable row level security;

revoke all on vppsone.assist_drafts, vppsone.cover_reports from anon, authenticated;
grant all on vppsone.assist_drafts, vppsone.cover_reports to service_role;

-- ======================================================== migrations/20261106122604_notes_client_request_id.sql
-- VPPS One — a note saved twice files once (20-teacher school day, 6 Nov 2026).
--
-- `createNoteAction` inserted `notes` rows with no idempotency key. On a slow
-- day a save took 30-90 s; a teacher who left the screen while it said "Still
-- saving" came back to her draft ("not saved yet"), saved it again, and the
-- child got two identical notes, each with its own follow-up to the class
-- teacher. Six of ten teacher seats hit it in the smoke run.
--
-- The composer now gives every draft one id, keeps it in the stored draft and
-- sends it with every save of that draft. The server stores it here and, when
-- the id is already filed for that writer, returns the original note instead
-- of inserting (src/vx/screens/notes/actions.ts). Same shape as
-- `teacher_leave_request_once` (20261103192446).
--
-- Additive: the column is nullable and nothing is backfilled; the partial
-- index leaves out every existing row and every note written elsewhere.
--
-- Rollback:
--   drop index if exists vppsone.notes_request_once;
--   alter table vppsone.notes drop column if exists client_request_id;

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.notes
  add column if not exists client_request_id uuid;

comment on column vppsone.notes.client_request_id is
  'The composer''s id for one draft, kept across its retries. A repeat save with the same id returns the note already filed instead of a second one. NULL for notes from before it and from other screens.';

create unique index if not exists notes_request_once
  on vppsone.notes (written_by, client_request_id)
  where client_request_id is not null;

notify pgrst, 'reload schema';

commit;

-- ======================================================== migrations/20261106143831_parent_message_switches.sql
-- Admin on/off switches for every message VPPS One queues for parents (owner,
-- 6 Nov 2026: "let admin make the switch on off of all the decisions that
-- needs to send to parent").
--
-- One row per kind of vppsone.parent_message_queue. `enabled` decides whether
-- the app queues that kind at all; `starts_on` is the register's parent switch
-- default for the first save of the day (D-320), read only for absent_alert.
-- Nothing here sends: the queue is still sent by a person from Messages → To
-- send. Seeded to today's behaviour, so applying this changes nothing until an
-- admin flips a switch.
--
-- Rollback: drop table vppsone.parent_message_switches;

create table if not exists vppsone.parent_message_switches (
  kind text primary key,
  enabled boolean not null default true,
  starts_on boolean not null default true,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint parent_message_switches_kind_known check (kind in ('absent_alert', 'birthday', 'note', 'support_plan'))
);
comment on table vppsone.parent_message_switches is
  'Admin switches: which kinds of parent_message_queue the app may queue, and whether the register''s parent switch starts on. Written by Settings → Messages to parents.';

insert into vppsone.parent_message_switches (kind, enabled, starts_on) values
  ('absent_alert', true, true),
  ('birthday', true, true),
  ('note', true, true),
  ('support_plan', true, true)
on conflict (kind) do nothing;

alter table vppsone.parent_message_switches enable row level security;
-- Read and written on the service role, after the caller's permission check.
grant select, insert, update on vppsone.parent_message_switches to service_role;

-- ======================================================== migrations/20261106162701_fees_bridge_nightly_only.sql
-- The Fees roster is copied into One once a night, not every minute
-- (owner's decision, 6 Nov 2026, D-457: "a night sync is enough").
--
-- 1. Remove the every-minute `fees-bridge-sync` pg_cron job. It was paused by
--    hand during the 6 Nov outage (it ran each minute for up to 120 s and
--    overlapped itself). Unscheduling it, rather than leaving it inactive,
--    means no later script or person can switch it back on by mistake.
--    `fees-bridge-nightly-verify` (20:30 UTC = 02:00 IST, `?verify=1`) stays:
--    it forces a full snapshot, applies it and acknowledges the events, so it
--    is a complete sync on its own. `fees-bridge-cron-history` stays.
-- 2. A roster checked last night is current until the next night. Four
--    readers refused anything older than five minutes; they now allow 26 hours
--    (a day plus slack), the same figure as BRIDGE_FRESH_FOR_MS in
--    src/platform/fees-bridge/state.ts. The functions are patched in place by
--    exact text, and the migration fails unless each holds the old check
--    exactly once, so a function that has changed shape is never half-edited.
--    Money figures are not affected: canonical financial lookup is still a
--    direct request to Fees.
begin;

do $$
declare j bigint;
begin
  for j in select jobid from cron.job where jobname = 'fees-bridge-sync' loop
    perform cron.unschedule(j);
  end loop;
end;
$$;

do $$
declare
  f text;
  d text;
  old_check constant text := 'last_checked_at>=clock_timestamp()-interval ''5 minutes''';
  new_check constant text := 'last_checked_at>=clock_timestamp()-interval ''26 hours''';
begin
  foreach f in array array[
    'vppsone.school_certificate_facts_v2(uuid,uuid,text,text,boolean)',
    'vppsone.school_certificate_roster(uuid,text,boolean)',
    'vppsone.school_office_attention(uuid,text,boolean)',
    'vppsone.school_office_roster(uuid,text,text,boolean)'
  ] loop
    d := pg_get_functiondef(f::regprocedure);
    if (length(d) - length(replace(d, old_check, ''))) / length(old_check) <> 1 then
      raise exception 'fees_bridge_nightly_only: % does not hold the five-minute check exactly once', f;
    end if;
    execute replace(d, old_check, new_check);
  end loop;
end;
$$;

commit;

-- ======================================================== migrations/20261106192629_bolo_typed_requests.sql
-- Bolo can be typed as well as spoken (teacher day, 6 Nov 2026: "You can't
-- type to Bolo"). A typed request is one UTF-8 text file in the same private
-- bucket, on the same voice job, quota, review and 90-day purge as a recording.
-- The server writes it; no browser uploads text.
begin;

update storage.buckets
set allowed_mime_types = array['image/jpeg','audio/webm','audio/mp4','audio/wav','audio/m4a','text/plain']
where id = 'ai-inputs' and public is false;

create or replace function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_session text, p_target uuid, p_revision integer,
  p_pages integer, p_model text, p_audio_extension text default null
) returns uuid language plpgsql set search_path = '' as $$
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
     or (p_action = 'voice' and (p_pages <> 1 or v_extension not in ('webm','m4a','wav','txt')))
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

commit;

-- ======================================================== migrations/20261107042312_fees_reports_role_permissions.sql
-- D-476: Reports gets its own switch, fees:reports ("See fee reports" on
-- Staff -> Roles), so the admin decides who opens the fee reports apart from
-- who reads the other fee screens. On for the roles that had Reports before
-- and whose Fees role carries reports:view; off for the office (owner,
-- 7 Nov 2026: the two Viewers do not get reports). Rows only; additive.
-- The admin row comes first because set_role_permissions only offers a
-- permission the admin role already holds.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'fees:reports'),
  ('accountant', 'fees:reports'),
  ('fee_collector', 'fees:reports')
on conflict do nothing;

-- ======================================================== migrations/20261107045006_ai_report_role_permissions.sql
-- D-484, D-485: the AI report (reports:ai, "Download the AI report" on Staff -> Roles):
-- one file of everything One and Fees hold for a session, student photographs
-- included, for staff to give to an AI assistant. The admin's alone by default
-- (owner, 7 Nov 2026); the admin can grant it to another role in the matrix,
-- and what the file carries is still narrowed to what that reader may see.
-- Rows only; additive. The admin row is the only one: set_role_permissions
-- offers a permission to other roles only once the admin role holds it.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'reports:ai')
on conflict do nothing;

-- ======================================================== migrations/20261107045020_ai_report_export_kind.sql
-- D-485: every AI report download is logged in academic_exports like the
-- other bulk exports (who took which session, when, how many rows), so the
-- admin can see who took a file that holds the whole school's records.
alter type vppsone.export_kind add value if not exists 'ai_report';
