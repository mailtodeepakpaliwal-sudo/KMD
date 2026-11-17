-- LOCAL TEST BED ONLY. Imitates the parts of a Supabase project the
-- migrations touch. Never applied to the real project.
do $$ begin if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator login noinherit; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then create role supabase_admin superuser; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'supabase_storage_admin') then create role supabase_storage_admin; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'dashboard_user') then create role dashboard_user; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'pgbouncer') then create role pgbouncer; end if; end $$;
grant anon, authenticated, service_role to authenticator;

create schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists citext with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists unaccent with schema extensions;
alter database postgres set search_path = "$user", public, extensions;
set search_path = "$user", public, extensions;
grant usage on schema extensions to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- auth
create schema auth;
create table auth.users (
  instance_id uuid, id uuid primary key default gen_random_uuid(), aud varchar(255), role varchar(255),
  email varchar(255), encrypted_password varchar(255), email_confirmed_at timestamptz, invited_at timestamptz,
  confirmation_token varchar(255), confirmation_sent_at timestamptz, recovery_token varchar(255), recovery_sent_at timestamptz,
  email_change_token_new varchar(255), email_change varchar(255), email_change_sent_at timestamptz,
  last_sign_in_at timestamptz, raw_app_meta_data jsonb, raw_user_meta_data jsonb, is_super_admin boolean,
  created_at timestamptz default now(), updated_at timestamptz default now(), phone text unique, phone_confirmed_at timestamptz,
  phone_change text, phone_change_token varchar(255), phone_change_sent_at timestamptz, confirmed_at timestamptz,
  email_change_token_current varchar(255), email_change_confirm_status smallint, banned_until timestamptz,
  reauthentication_token varchar(255), reauthentication_sent_at timestamptz, is_sso_user boolean default false,
  deleted_at timestamptz, is_anonymous boolean default false
);
create table auth.sessions (id uuid primary key, user_id uuid references auth.users on delete cascade, created_at timestamptz, updated_at timestamptz, factor_id uuid, aal text, not_after timestamptz, refreshed_at timestamp, user_agent text, ip inet, tag text);
create table auth.identities (id uuid primary key default gen_random_uuid(), provider_id text, user_id uuid references auth.users on delete cascade, identity_data jsonb, provider text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz, email text);
create table auth.refresh_tokens (id bigserial primary key, token varchar(255), user_id varchar(255), revoked boolean, created_at timestamptz, updated_at timestamptz, parent varchar(255), session_id uuid);
create table auth.mfa_factors (id uuid primary key, user_id uuid, friendly_name text, factor_type text, status text, created_at timestamptz, updated_at timestamptz);
create table auth.audit_log_entries (instance_id uuid, id uuid primary key, payload json, created_at timestamptz, ip_address varchar(64));
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true), (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')), '')::uuid $$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(current_setting('request.jwt.claim.role', true), (current_setting('request.jwt.claims', true)::jsonb ->> 'role')) $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''), nullif(current_setting('request.jwt.claims', true), ''))::jsonb $$;
create or replace function auth.email() returns text language sql stable as $$ select auth.jwt() ->> 'email' $$;
grant usage on schema auth to anon, authenticated, service_role;
grant all on all tables in schema auth to service_role;

-- storage
create schema storage;
create table storage.buckets (id text primary key, name text not null unique, owner uuid, created_at timestamptz default now(), updated_at timestamptz default now(), public boolean default false, avif_autodetection boolean default false, file_size_limit bigint, allowed_mime_types text[], owner_id text, type text);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid, created_at timestamptz default now(), updated_at timestamptz default now(), last_accessed_at timestamptz default now(), metadata jsonb, path_tokens text[] generated always as (string_to_array(name, '/')) stored, version text, owner_id text, user_metadata jsonb, level int);
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
create or replace function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare _parts text[]; begin select string_to_array(name, '/') into _parts; return _parts[1:array_length(_parts,1)-1]; end $$;
create or replace function storage.filename(name text) returns text language plpgsql immutable as $$
declare _parts text[]; begin select string_to_array(name, '/') into _parts; return _parts[array_length(_parts,1)]; end $$;
create or replace function storage.extension(name text) returns text language plpgsql immutable as $$
declare _parts text[]; _filename text; begin select string_to_array(name, '/') into _parts; select _parts[array_length(_parts,1)] into _filename; return reverse(split_part(reverse(_filename), '.', 1)); end $$;
grant usage on schema storage to anon, authenticated, service_role;
grant all on all tables in schema storage to anon, authenticated, service_role;

-- pg_cron (stub)
create schema cron;
create table cron.job (jobid bigserial primary key, schedule text, command text, nodename text default 'localhost', nodeport int default 5432, database text default 'postgres', username text default 'postgres', active boolean default true, jobname text unique);
create table cron.job_run_details (jobid bigint, runid bigserial primary key, job_pid int, database text, username text, command text, status text, return_message text, start_time timestamptz, end_time timestamptz);
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language plpgsql as $$
declare v bigint; begin
  insert into cron.job(jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid into v; return v; end $$;
create or replace function cron.schedule(schedule text, command text) returns bigint language sql as $$ insert into cron.job(schedule, command) values (schedule, command) returning jobid $$;
create or replace function cron.unschedule(job_name text) returns boolean language plpgsql as $$ begin delete from cron.job where jobname = job_name; return found; end $$;
create or replace function cron.unschedule(job_id bigint) returns boolean language plpgsql as $$ begin delete from cron.job where jobid = job_id; return found; end $$;
create or replace function cron.alter_job(job_id bigint, schedule text default null, command text default null, database text default null, username text default null, active boolean default null) returns void language sql as $$
  update cron.job set schedule = coalesce(alter_job.schedule, job.schedule), command = coalesce(alter_job.command, job.command), active = coalesce(alter_job.active, job.active) where jobid = job_id $$;

-- pg_net (stub)
create schema net;
create table net._http_response (id bigint, status_code int, content_type text, headers jsonb, content text, timed_out boolean, error_msg text, created timestamptz default now());
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $$ select 1::bigint $$;
create or replace function net.http_get(url text, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $$ select 1::bigint $$;

-- vault (stub)
create schema vault;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, description text default '', secret text, key_id uuid, nonce bytea, created_at timestamptz default now(), updated_at timestamptz default now());
create view vault.decrypted_secrets as select *, secret as decrypted_secret from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '', new_key_id uuid default null) returns uuid language sql as $$
  insert into vault.secrets(secret, name, description) values (new_secret, new_name, new_description) returning id $$;
create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null, new_description text default null, new_key_id uuid default null) returns void language sql as $$
  update vault.secrets set secret = coalesce(new_secret, secret), name = coalesce(new_name, name) where id = secret_id $$;

-- realtime
create publication supabase_realtime;
create schema realtime;
create table realtime.messages (id bigserial primary key, topic text, extension text, payload jsonb, event text, private boolean, inserted_at timestamp default now(), updated_at timestamp default now());
create or replace function realtime.topic() returns text language sql stable as $$ select current_setting('realtime.topic', true) $$;
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void language sql as $$ select $$;
grant usage on schema realtime to authenticated, service_role;

create schema graphql_public;

create schema supabase_migrations;
create table supabase_migrations.schema_migrations (version text primary key, statements text[], name text, created_by text, idempotency_key text);
