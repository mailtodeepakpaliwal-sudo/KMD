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

-- installments.amount_due is a generated column in the fees app
-- ((base_amount + transport_amount) - discount_amount); the app never writes
-- it. The rebuilt base made it a plain column defaulting to 0, so every
-- installment read as Rs 0 due (18 Nov 2026). A trigger keeps the views that
-- read it untouched.
create or replace function vppsone.kmd_installment_amount_due() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.amount_due := coalesce(new.base_amount, 0) + coalesce(new.transport_amount, 0) - coalesce(new.discount_amount, 0);
  return new;
end $$;
drop trigger if exists installments_amount_due on public.installments;
create trigger installments_amount_due before insert or update on public.installments
  for each row execute function vppsone.kmd_installment_amount_due();

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
