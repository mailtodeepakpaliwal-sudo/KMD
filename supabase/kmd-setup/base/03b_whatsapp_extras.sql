-- Families deliberately not messaged in a run, to compare who paid anyway.
create table if not exists public.whatsapp_run_holdouts (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.whatsapp_campaign_runs(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (run_id, student_id)
);
alter table public.whatsapp_run_holdouts enable row level security;
create policy "whatsapp_run_holdouts: staff read" on public.whatsapp_run_holdouts for select to authenticated using (public.is_staff());

create or replace view public.v_whatsapp_run_holdout_outcomes with (security_invoker = true) as
  select h.run_id,
         count(*)::integer as held_out,
         count(*) filter (where exists (
           select 1 from public.receipts r where r.student_id = h.student_id and r.payment_mode <> 'discount'
             and r.created_at >= run.started_at))::integer as held_out_paid,
         coalesce(sum((select sum(r.total_amount) from public.receipts r where r.student_id = h.student_id
             and r.payment_mode <> 'discount' and r.created_at >= run.started_at)), 0)::integer as held_out_collected
  from public.whatsapp_run_holdouts h
  join public.whatsapp_campaign_runs run on run.id = h.run_id
  group by h.run_id;
