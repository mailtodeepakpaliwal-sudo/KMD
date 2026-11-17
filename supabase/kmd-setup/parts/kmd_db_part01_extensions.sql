-- KMD One database setup — part 1 of 11: switch on the extensions it uses.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
