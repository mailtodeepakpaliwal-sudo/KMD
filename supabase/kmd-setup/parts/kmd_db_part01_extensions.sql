-- KMD One database setup — part 1: switch on the extensions it uses.
-- ALREADY APPLIED to project uvvusynovvhtacauvrzc on 17 Nov 2026. Do not run again.
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_trgm with schema extensions;
