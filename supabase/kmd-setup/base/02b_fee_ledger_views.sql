-- ============================================================================
-- KMD One — the fee ledger: one per-installment calculation and the views the
-- app reads. Rules follow src/modules/fees/domain/workbook.ts:
--   * an installment's charge is installments.amount_due (base + transport −
--     discount, laid out by the app's ledger generator);
--   * money settles the base charge first, then the late fee;
--   * a flat late fee (installments.late_fee_flat_amount) applies once the due
--     date has passed with the base charge not settled by that date;
--   * waivers (manual, or a desk 'writeoff') reduce the late fee only;
--   * a desk 'discount' closes part of the base charge without money;
--   * reversals are negative payment_adjustments and undo money.
-- ============================================================================

-- ------------------------------------------------------------ table tweaks
alter table public.receipts alter column client_request_id type uuid using nullif(client_request_id, '')::uuid;
alter table public.student_late_fee_waivers alter column client_request_id type uuid using nullif(client_request_id, '')::uuid;

create table if not exists public.student_repayment_plans (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  session_label text not null,
  scope text not null default 'old_and_current'
    check (scope in ('old_balance_only', 'current_year_only', 'old_and_current')),
  lifecycle text not null default 'active'
    check (lifecycle in ('active', 'cancelled', 'superseded')),
  opening_balance integer not null default 0,
  monthly_amount integer not null default 0,
  term_months integer not null default 1,
  first_due_date date not null,
  end_date date,
  final_installment_amount integer not null default 0,
  reason text,
  waived_late_fee_total integer not null default 0,
  activated_at timestamptz not null default now(),
  activated_by uuid,
  activated_by_label text,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancellation_reason text,
  supersedes_plan_id uuid references public.student_repayment_plans(id),
  superseded_by_plan_id uuid references public.student_repayment_plans(id),
  plan_review_needed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index student_repayment_plans_one_active on public.student_repayment_plans (student_id) where lifecycle = 'active';
alter table public.student_repayment_plans enable row level security;
create policy "student_repayment_plans: staff read" on public.student_repayment_plans for select to authenticated using (public.is_staff());
create trigger student_repayment_plans_touch_updated_at before update on public.student_repayment_plans for each row execute function private.touch_updated_at();

alter table public.student_repayment_plan_items add constraint student_repayment_plan_items_plan_id_fkey foreign key (plan_id) references public.student_repayment_plans(id) on delete cascade;
alter table public.student_repayment_schedule add constraint student_repayment_schedule_plan_id_fkey foreign key (plan_id) references public.student_repayment_plans(id) on delete cascade;
alter table public.student_repayment_receipt_links add constraint student_repayment_receipt_links_plan_id_fkey foreign key (plan_id) references public.student_repayment_plans(id) on delete cascade;
alter table public.student_repayment_emi_late_fees add constraint student_repayment_emi_late_fees_plan_id_fkey foreign key (plan_id) references public.student_repayment_plans(id) on delete cascade;
alter table public.student_repayment_schedule add column if not exists paid_amount integer not null default 0;

alter table public.student_carry_forward_balances
  add column if not exists source_session_label text,
  add column if not exists target_session_label text,
  add column if not exists fee_head text not null default 'Previous session balance',
  add column if not exists original_amount integer not null default 0,
  add column if not exists installment_id uuid references public.installments(id) on delete set null,
  add column if not exists status text not null default 'open',
  add column if not exists notes text,
  add column if not exists created_by uuid;

-- ------------------------------------------------------------ the calculation
create or replace function private.installment_ledger(p_student_id uuid default null, p_as_of date default null)
returns table (
  installment_id uuid, student_id uuid, class_id uuid, session_label text, source_session_label text,
  installment_no integer, installment_label text, due_date date, is_carry_forward boolean, is_emi_late_fee boolean,
  base_charge integer, discount_closeout_amount integer, adjustment_amount integer, paid_amount integer,
  applied_amount integer, raw_late_fee integer, waiver_applied integer, final_late_fee integer,
  fee_settled_amount integer, late_fee_settled_amount integer, settled_amount integer,
  pending_amount integer, late_fee_pending integer, total_charge integer, total_pending integer,
  balance_status text, late_fee_status text, last_payment_date date
)
language sql stable security definer
set search_path to 'public', 'private'
as $$
  with params as (select coalesce(p_as_of, private.ist_today()) as as_of),
  inst as (
    select i.*, c.session_label as class_session_label
    from public.installments i
    join public.classes c on c.id = i.class_id
    where (p_student_id is null or i.student_id = p_student_id)
      and coalesce(i.status, 'scheduled') = 'scheduled'
  ),
  pay as (
    select p.installment_id,
           sum(p.amount)::integer as cash,
           sum(p.amount) filter (where r.payment_date <= i.due_date)::integer as cash_by_due,
           max(r.payment_date) as last_date
    from public.payments p
    join public.receipts r on r.id = p.receipt_id
    join inst i on i.id = p.installment_id, params
    where r.payment_date <= params.as_of
    group by p.installment_id
  ),
  padj as (
    select coalesce(pa.installment_id, p.installment_id) as installment_id, sum(pa.amount_delta)::integer as delta
    from public.payment_adjustments pa
    left join public.payments p on p.id = pa.payment_id
    where coalesce(pa.installment_id, p.installment_id) in (select id from inst)
    group by 1
  ),
  radj as (
    select ra.installment_id,
           sum(ra.amount_delta) filter (where ra.adjustment_type = 'discount')::integer as discount,
           sum(ra.amount_delta) filter (where ra.adjustment_type = 'writeoff')::integer as writeoff,
           sum(ra.amount_delta) filter (where ra.adjustment_type = 'discount' and r.payment_date <= i.due_date)::integer as discount_by_due
    from public.receipt_adjustments ra
    join public.receipts r on r.id = ra.receipt_id
    join inst i on i.id = ra.installment_id, params
    where r.payment_date <= params.as_of
    group by ra.installment_id
  ),
  waiv as (
    select w.installment_id, sum(w.amount)::integer as amount
    from public.student_late_fee_waivers w
    where w.voided_at is null and w.installment_id in (select id from inst)
    group by w.installment_id
  ),
  base as (
    select i.id as installment_id, i.student_id, i.class_id, i.class_session_label as session_label,
           coalesce(i.source_session_label, i.class_session_label) as source_session_label,
           i.installment_no, i.installment_label, i.due_date,
           coalesce(i.is_carry_forward, false) as is_carry_forward,
           coalesce(i.is_emi_late_fee, false) as is_emi_late_fee,
           greatest(coalesce(i.amount_due, 0), 0) as base_charge,
           coalesce(radj.discount, 0) as discount_closeout_amount,
           coalesce(padj.delta, 0) as adjustment_amount,
           greatest(coalesce(pay.cash, 0) + coalesce(padj.delta, 0), 0) as paid_amount,
           coalesce(pay.cash_by_due, 0) + coalesce(radj.discount_by_due, 0) as settled_by_due,
           case
             when coalesce(i.is_carry_forward, false) or coalesce(i.is_emi_late_fee, false) then 0
             when params.as_of > i.due_date
              and coalesce(pay.cash_by_due, 0) + coalesce(radj.discount_by_due, 0) < greatest(coalesce(i.amount_due, 0), 0)
               then greatest(coalesce(i.late_fee_flat_amount, 0), 0)
             else 0
           end as raw_late_fee,
           coalesce(waiv.amount, 0) + coalesce(radj.writeoff, 0) as waived,
           pay.last_date as last_payment_date,
           params.as_of
    from inst i
    cross join params
    left join pay on pay.installment_id = i.id
    left join padj on padj.installment_id = i.id
    left join radj on radj.installment_id = i.id
    left join waiv on waiv.installment_id = i.id
  ),
  calc as (
    select b.*,
           least(b.waived, b.raw_late_fee) as waiver_applied,
           greatest(b.raw_late_fee - b.waived, 0) as final_late_fee,
           b.paid_amount + b.discount_closeout_amount as applied_amount
    from base b
  ),
  settle as (
    select c.*,
           least(c.applied_amount, c.base_charge) as fee_settled_amount,
           least(greatest(c.applied_amount - c.base_charge, 0), c.final_late_fee) as late_fee_settled_amount
    from calc c
  )
  select s.installment_id, s.student_id, s.class_id, s.session_label, s.source_session_label,
         s.installment_no, s.installment_label, s.due_date, s.is_carry_forward, s.is_emi_late_fee,
         s.base_charge, s.discount_closeout_amount, s.adjustment_amount, s.paid_amount,
         s.applied_amount, s.raw_late_fee, s.waiver_applied, s.final_late_fee,
         s.fee_settled_amount, s.late_fee_settled_amount,
         s.fee_settled_amount + s.late_fee_settled_amount as settled_amount,
         s.base_charge - s.fee_settled_amount as pending_amount,
         s.final_late_fee - s.late_fee_settled_amount as late_fee_pending,
         s.base_charge + s.final_late_fee as total_charge,
         (s.base_charge - s.fee_settled_amount) + (s.final_late_fee - s.late_fee_settled_amount) as total_pending,
         case
           when s.base_charge + s.final_late_fee = 0 and (s.waiver_applied > 0 or s.discount_closeout_amount > 0) then 'waived'
           when (s.base_charge - s.fee_settled_amount) + (s.final_late_fee - s.late_fee_settled_amount) <= 0 then 'paid'
           when s.as_of > s.due_date then 'overdue'
           when s.applied_amount > 0 then 'partial'
           else 'pending'
         end as balance_status,
         case
           when s.raw_late_fee = 0 then 'none'
           when s.final_late_fee = 0 then 'waived'
           when s.final_late_fee - s.late_fee_settled_amount <= 0 then 'paid'
           else 'pending'
         end as late_fee_status,
         s.last_payment_date
  from settle s
$$;

-- What the posting engine allocates against (fee-migration 20261028140100).
create or replace function private.workbook_installment_snapshot(p_student_id uuid, p_as_of date, p_include_carry_forward boolean default true)
returns table (
  installment_id uuid, installment_no integer, installment_label text, due_date date,
  session_label text, class_label text, class_name text, base_charge integer,
  final_late_fee integer, fee_settled_amount integer, late_fee_settled_amount integer,
  pending_amount integer, late_fee_pending integer, total_pending integer, balance_status text,
  is_carry_forward boolean
)
language sql stable security definer
set search_path to 'public', 'private'
as $$
  select l.installment_id, l.installment_no, l.installment_label, l.due_date,
         l.session_label,
         concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) as class_label,
         c.class_name, l.base_charge, l.final_late_fee, l.fee_settled_amount, l.late_fee_settled_amount,
         l.pending_amount, l.late_fee_pending, l.total_pending, l.balance_status, l.is_carry_forward
  from private.installment_ledger(p_student_id, p_as_of) l
  join public.classes c on c.id = l.class_id
  where coalesce(p_include_carry_forward, true) or not l.is_carry_forward
$$;

-- ------------------------------------------------------------ views
create or replace view public.v_receipt_reversal_totals with (security_invoker = true) as
  select p.receipt_id, (-sum(pa.amount_delta))::integer as reversed_amount
  from public.payment_adjustments pa
  join public.payments p on p.id = pa.payment_id
  where pa.adjustment_type = 'reversal'
  group by p.receipt_id;

create or replace view public.v_workbook_installment_balances with (security_invoker = true) as
  select l.installment_id, l.student_id, l.class_id, l.session_label, l.source_session_label,
         l.installment_no, l.installment_label, l.due_date, l.is_carry_forward,
         s.full_name as student_name, s.admission_no, s.father_name,
         coalesce(s.father_phone, s.primary_phone) as father_phone,
         concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) as class_label,
         c.class_name, c.section, c.stream_name,
         s.transport_route_id, tr.route_code as transport_route_code, tr.route_name as transport_route_name,
         l.base_charge, l.discount_closeout_amount, l.adjustment_amount, l.paid_amount, l.applied_amount,
         l.waiver_applied, l.final_late_fee, l.fee_settled_amount, l.late_fee_settled_amount, l.settled_amount,
         l.pending_amount, l.late_fee_pending, l.total_charge, l.total_pending,
         l.balance_status, l.late_fee_status, l.last_payment_date
  from private.installment_ledger(null, null) l
  join public.students s on s.id = l.student_id
  join public.classes c on c.id = l.class_id
  left join public.transport_routes tr on tr.id = s.transport_route_id;

create or replace view public.v_installment_balances with (security_invoker = true) as
  select installment_id, student_id, class_id, session_label, installment_no, installment_label, due_date,
         total_charge as amount_due, settled_amount as paid_amount, total_pending as outstanding_amount, balance_status
  from public.v_workbook_installment_balances;

create or replace view public.v_student_manual_late_fee_waivers with (security_invoker = true) as
  select w.student_id, w.session_label, count(*)::integer as waiver_count, sum(w.amount)::integer as waived_amount,
         max(w.waived_at) as last_waived_at
  from public.student_late_fee_waivers w
  where w.voided_at is null
  group by w.student_id, w.session_label;

create or replace view public.v_workbook_student_financials with (security_invoker = true) as
  with l as (
    select * from public.v_workbook_installment_balances
  ),
  per_student as (
    select l.student_id,
           sum(l.base_charge)::integer as base_charge_total,
           sum(l.final_late_fee)::integer as late_fee_total,
           sum(l.waiver_applied)::integer as late_fee_waiver_amount,
           sum(l.paid_amount)::integer as total_paid,
           sum(l.discount_closeout_amount)::integer as total_discount_closeouts,
           sum(l.pending_amount)::integer as base_outstanding_amount,
           sum(l.late_fee_pending)::integer as late_fee_outstanding_amount,
           sum(l.total_pending)::integer as outstanding_amount,
           count(*) filter (where l.balance_status = 'overdue')::integer as overdue_installment_count,
           max(l.last_payment_date) as last_payment_date,
           (array_agg(l.installment_label order by l.due_date, l.installment_no) filter (where l.total_pending > 0))[1] as next_due_label,
           (array_agg(l.due_date order by l.due_date, l.installment_no) filter (where l.total_pending > 0))[1] as next_due_date,
           (array_agg(l.total_pending order by l.due_date, l.installment_no) filter (where l.total_pending > 0))[1] as next_due_amount,
           sum(l.base_charge) filter (where l.installment_no = 1 and not l.is_carry_forward)::integer as installment1_base,
           sum(l.base_charge) filter (where l.installment_no = 2 and not l.is_carry_forward)::integer as installment2_base,
           sum(l.base_charge) filter (where l.installment_no = 3 and not l.is_carry_forward)::integer as installment3_base,
           sum(l.base_charge) filter (where l.installment_no = 4 and not l.is_carry_forward)::integer as installment4_base,
           sum(l.total_pending) filter (where l.installment_no = 1 and not l.is_carry_forward)::integer as inst1_pending,
           sum(l.total_pending) filter (where l.installment_no = 2 and not l.is_carry_forward)::integer as inst2_pending,
           sum(l.total_pending) filter (where l.installment_no = 3 and not l.is_carry_forward)::integer as inst3_pending,
           sum(l.total_pending) filter (where l.installment_no = 4 and not l.is_carry_forward)::integer as inst4_pending,
           sum(l.waiver_applied) filter (where l.installment_no = 1)::integer as waiver_applied1,
           sum(l.waiver_applied) filter (where l.installment_no = 2)::integer as waiver_applied2,
           sum(l.waiver_applied) filter (where l.installment_no = 3)::integer as waiver_applied3,
           sum(l.waiver_applied) filter (where l.installment_no = 4)::integer as waiver_applied4
    from l group by l.student_id
  ),
  last_receipt as (
    select distinct on (r.student_id) r.student_id, r.total_amount
    from public.receipts r
    where r.payment_mode <> 'discount'
    order by r.student_id, r.payment_date desc, r.created_at desc
  ),
  dup as (
    select s.admission_no, c.session_label
    from public.students s join public.classes c on c.id = s.class_id
    where coalesce(s.admission_no, '') <> ''
    group by s.admission_no, c.session_label having count(*) > 1
  )
  select s.id as student_id, s.full_name as student_name, s.admission_no, s.father_name,
         coalesce(s.father_phone, s.primary_phone) as father_phone, s.mother_phone,
         s.class_id, c.session_label, c.sort_order,
         concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) as class_label,
         s.transport_route_id, tr.route_code as transport_route_code, tr.route_name as transport_route_name,
         s.status as record_status, initcap(coalesce(s.status, '')) as student_status_label,
         coalesce(o.custom_tuition_fee_amount, fs.tuition_fee_amount, 0) as tuition_fee,
         case when s.transport_route_id is null then 0
              else coalesce(o.custom_transport_fee_amount, tr.annual_fee_amount, 0) end as transport_fee,
         coalesce(case when coalesce(o.student_type_override, s.student_type, 'existing') = 'new'
                       then pc.new_student_academic_fee_amount else pc.old_student_academic_fee_amount end, 0) as academic_fee,
         o.other_adjustment_head, coalesce(o.other_adjustment_amount, 0) as other_adjustment_amount,
         coalesce(o.discount_amount, 0) as discount_amount,
         coalesce(ps.base_charge_total, 0) + coalesce(o.discount_amount, 0) as gross_base_before_discount,
         coalesce(ps.base_charge_total, 0) as base_charge_total,
         coalesce(ps.base_charge_total, 0) as base_total_due,
         coalesce(ps.late_fee_total, 0) as late_fee_total,
         coalesce(ps.late_fee_waiver_amount, 0) as late_fee_waiver_amount,
         coalesce(ps.base_charge_total, 0) + coalesce(ps.late_fee_total, 0) as total_due,
         coalesce(ps.total_paid, 0) as total_paid,
         coalesce(ps.total_discount_closeouts, 0) as total_discount_closeouts,
         coalesce(ps.outstanding_amount, 0) as outstanding_amount,
         coalesce(ps.base_outstanding_amount, 0) as base_outstanding_amount,
         coalesce(ps.late_fee_outstanding_amount, 0) as late_fee_outstanding_amount,
         coalesce(ps.overdue_installment_count, 0) as overdue_installment_count,
         coalesce(ps.installment1_base, 0) as installment1_base, coalesce(ps.installment2_base, 0) as installment2_base,
         coalesce(ps.installment3_base, 0) as installment3_base, coalesce(ps.installment4_base, 0) as installment4_base,
         coalesce(ps.inst1_pending, 0) as inst1_pending, coalesce(ps.inst2_pending, 0) as inst2_pending,
         coalesce(ps.inst3_pending, 0) as inst3_pending, coalesce(ps.inst4_pending, 0) as inst4_pending,
         coalesce(ps.waiver_applied1, 0) as waiver_applied1, coalesce(ps.waiver_applied2, 0) as waiver_applied2,
         coalesce(ps.waiver_applied3, 0) as waiver_applied3, coalesce(ps.waiver_applied4, 0) as waiver_applied4,
         ps.next_due_label, ps.next_due_date, coalesce(ps.next_due_amount, 0) as next_due_amount,
         ps.last_payment_date, coalesce(lr.total_amount, 0) as last_payment_amount,
         case
           when coalesce(ps.base_charge_total, 0) + coalesce(ps.late_fee_total, 0) <= 0 then ''
           when coalesce(ps.outstanding_amount, 0) <= 0 then 'PAID'
           when coalesce(ps.total_paid, 0) <= 0 then 'NOT STARTED'
           when ps.next_due_date is not null and private.ist_today() > ps.next_due_date then 'OVERDUE'
           else 'PARTLY PAID'
         end as status_label,
         case when coalesce(s.admission_no, '') <> ''
              then concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) || '|' || s.admission_no
              else concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) || '|' || s.full_name end as workbook_student_key,
         (dup.admission_no is not null) as duplicate_sr_flag,
         (s.class_id is null) as missing_class_flag,
         (s.date_of_birth is null) as missing_dob_flag,
         (coalesce(s.status, '') = '') as missing_status_flag
  from public.students s
  join public.classes c on c.id = s.class_id
  left join public.transport_routes tr on tr.id = s.transport_route_id
  left join public.fee_settings fs on fs.class_id = s.class_id and fs.is_active
  left join public.student_fee_overrides o on o.student_id = s.id and o.is_active
  left join public.fee_policy_configs pc on pc.academic_session_label = c.session_label
  left join per_student ps on ps.student_id = s.id
  left join last_receipt lr on lr.student_id = s.id
  left join dup on dup.admission_no = s.admission_no and dup.session_label = c.session_label;

create or replace view public.v_student_financial_state with (security_invoker = true) as
  select f.student_id, f.session_label, f.total_due, f.total_paid + f.total_discount_closeouts as total_paid,
         f.outstanding_amount as pending_amount, f.outstanding_amount as installment_pending_amount,
         greatest(f.total_paid + f.total_discount_closeouts - f.total_due, 0) as overpaid_amount,
         greatest(f.total_paid + f.total_discount_closeouts - f.total_due, 0) as credit_balance,
         greatest(f.total_paid + f.total_discount_closeouts - f.total_due, 0) as refundable_amount,
         0::integer as rows_kept_for_review
  from public.v_workbook_student_financials f;

create or replace view public.v_student_repayment_plan_status with (security_invoker = true) as
  with sched as (
    select sc.plan_id,
           count(*)::integer as item_count,
           sum(sc.amount) filter (where sc.due_date <= private.ist_today())::integer as expected_to_date,
           min(sc.due_date) as first_due
    from public.student_repayment_schedule sc group by sc.plan_id
  ),
  paid as (
    select rl.plan_id, sum(rl.contribution_amount)::integer as paid_to_date
    from public.student_repayment_receipt_links rl group by rl.plan_id
  ),
  walk as (
    select sc.plan_id, sc.sequence_no, sc.due_date, sc.amount,
           sum(sc.amount) over (partition by sc.plan_id order by sc.sequence_no) as cumulative
    from public.student_repayment_schedule sc
  ),
  progress as (
    select w.plan_id,
           count(*) filter (where w.cumulative <= coalesce(pd.paid_to_date, 0))::integer as paid_installment_count,
           count(*) filter (where w.cumulative > coalesce(pd.paid_to_date, 0) and w.due_date < private.ist_today())::integer as missed_installment_count,
           (array_agg(w.sequence_no order by w.sequence_no) filter (where w.cumulative > coalesce(pd.paid_to_date, 0)))[1] as next_due_sequence_no,
           (array_agg(w.due_date order by w.sequence_no) filter (where w.cumulative > coalesce(pd.paid_to_date, 0)))[1] as next_due_date,
           (array_agg(least(w.amount, w.cumulative - coalesce(pd.paid_to_date, 0)) order by w.sequence_no)
              filter (where w.cumulative > coalesce(pd.paid_to_date, 0)))[1] as next_due_amount
    from walk w left join paid pd on pd.plan_id = w.plan_id
    group by w.plan_id
  )
  select p.id as plan_id, p.student_id, p.session_label, p.scope, p.lifecycle, p.reason,
         p.opening_balance, p.monthly_amount, p.term_months, coalesce(p.first_due_date, sc.first_due) as first_due_date,
         p.end_date, p.final_installment_amount, p.waived_late_fee_total,
         p.activated_at, p.activated_by, p.activated_by_label, p.cancelled_at, p.cancellation_reason,
         p.supersedes_plan_id, p.superseded_by_plan_id, p.plan_review_needed,
         coalesce(sc.item_count, 0) as item_count,
         coalesce(pd.paid_to_date, 0) as paid_to_date,
         greatest(p.opening_balance - coalesce(pd.paid_to_date, 0), 0) as remaining_balance,
         coalesce(sc.expected_to_date, 0) as expected_to_date,
         greatest(coalesce(sc.expected_to_date, 0) - coalesce(pd.paid_to_date, 0), 0) as expected_overdue,
         greatest(coalesce(sc.expected_to_date, 0) - coalesce(pd.paid_to_date, 0), 0) as catch_up_amount,
         coalesce(pr.paid_installment_count, 0) as paid_installment_count,
         coalesce(pr.missed_installment_count, 0) as missed_installment_count,
         pr.next_due_sequence_no, pr.next_due_date, coalesce(pr.next_due_amount, 0) as next_due_amount,
         case
           when p.opening_balance - coalesce(pd.paid_to_date, 0) <= 0 then 'completed'
           when coalesce(pr.missed_installment_count, 0) > 0 then 'behind'
           when pr.next_due_date is not null and pr.next_due_date <= private.ist_today() then 'due'
           when coalesce(p.first_due_date, sc.first_due) > private.ist_today() then 'upcoming'
           else 'on_track'
         end as payment_status
  from public.student_repayment_plans p
  left join sched sc on sc.plan_id = p.id
  left join paid pd on pd.plan_id = p.id
  left join progress pr on pr.plan_id = p.id;

create or replace view public.v_student_carry_forward_balances with (security_invoker = true) as
  select cf.id, cf.student_id, s.full_name as student_name, s.admission_no,
         concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) as class_label,
         coalesce(s.father_phone, s.primary_phone) as father_phone,
         cf.fee_head, cf.source_session_label, cf.target_session_label, cf.status,
         cf.original_amount,
         coalesce(l.settled_amount, 0) as collected_amount,
         case when l.installment_id is null then cf.original_amount else l.total_pending end as remaining_amount,
         coalesce(l.balance_status, case when cf.original_amount > 0 then 'pending' else 'paid' end) as balance_status
  from public.student_carry_forward_balances cf
  join public.students s on s.id = cf.student_id
  left join public.classes c on c.id = s.class_id
  left join public.v_workbook_installment_balances l on l.installment_id = cf.installment_id;

create or replace view public.v_student_directory with (security_invoker = true) as
  with emi as (
    select ps.student_id, ps.payment_status, ps.next_due_date
    from public.v_student_repayment_plan_status ps where ps.lifecycle = 'active'
  ),
  disc as (
    select a.student_id, array_agg(lower(p.code)) as codes
    from public.student_conventional_discount_assignments a
    join public.conventional_discount_policies p on p.id = a.policy_id
    where coalesce(a.is_active, true)
    group by a.student_id
  ),
  cf as (
    select student_id, sum(remaining_amount)::integer as remaining
    from public.v_student_carry_forward_balances group by student_id
  ),
  waivers as (
    select distinct student_id from public.student_late_fee_waivers where voided_at is null
  ),
  sessions as (
    select session_label, min(created_at) as opened_at from public.classes group by session_label
  )
  select s.id as student_id, c.session_label, s.class_id, c.status as class_status, s.transport_route_id,
         s.status as record_status, s.full_name, s.admission_no,
         lower(concat_ws(' ', s.full_name, s.admission_no, s.father_name, s.mother_name, s.primary_phone,
                         s.secondary_phone, s.father_phone, s.mother_phone, s.village_city)) as search_text,
         coalesce(f.total_paid, 0) as total_paid, f.last_payment_date,
         coalesce(f.base_outstanding_amount, 0) as base_outstanding_amount,
         coalesce(f.late_fee_outstanding_amount, 0) as late_fee_outstanding_amount,
         coalesce(f.outstanding_amount, 0) as outstanding_amount,
         coalesce(f.total_due, 0) as total_due,
         (s.status = 'active') as seg_active,
         (s.status = 'left') as seg_left,
         (s.status = 'left' and coalesce(f.outstanding_amount, 0) > 0) as seg_left_owing,
         (s.status = 'graduated') as seg_graduated,
         (s.joined_on is not null and s.joined_on >= coalesce((select opened_at::date from sessions se where se.session_label = c.session_label), s.joined_on)
          or coalesce(s.student_type, '') = 'new') as seg_new_this_year,
         (coalesce(cf.remaining, 0) > 0) as seg_old_balance_due,
         (coalesce(f.overdue_installment_count, 0) > 0) as seg_overdue,
         (coalesce(f.late_fee_outstanding_amount, 0) > 0) as seg_late_fee_pending,
         (coalesce(f.total_paid, 0) > 0 and coalesce(f.outstanding_amount, 0) > 0) as seg_partly_paid,
         (coalesce(f.total_due, 0) > 0 and coalesce(f.outstanding_amount, 0) <= 0) as seg_year_clear,
         (coalesce(f.total_paid, 0) = 0 and coalesce(f.outstanding_amount, 0) > 0) as seg_never_paid,
         (coalesce(f.outstanding_amount, 0) > 0) as seg_has_dues,
         (coalesce(nullif(btrim(coalesce(s.primary_phone, s.father_phone, s.guardian_phone, '')), ''), '') = '') as seg_missing_phone,
         (coalesce(f.total_due, 0) = 0 and s.status = 'active') as seg_dues_not_prepared,
         (s.date_of_birth is null) as seg_missing_dob,
         coalesce(f.duplicate_sr_flag, false) as seg_duplicate_sr,
         (coalesce(btrim(s.admission_no), '') = '') as seg_pending_sr,
         (s.transport_route_id is not null) as seg_on_transport,
         (coalesce(f.discount_amount, 0) > 0 or d.codes is not null) as seg_has_discount,
         coalesce('rte' = any (d.codes), false) as seg_discount_rte,
         coalesce('staff_child' = any (d.codes), false) as seg_discount_staff_child,
         coalesce('third_child' = any (d.codes), false) as seg_discount_third_child,
         exists (select 1 from public.student_fee_overrides o where o.student_id = s.id and o.is_active) as seg_fee_exception,
         (w.student_id is not null) as seg_late_fee_waived,
         (emi.student_id is not null) as seg_on_emi,
         (emi.student_id is not null and emi.next_due_date is not null and emi.next_due_date <= private.ist_today() + 7) as seg_emi_due,
         coalesce(emi.payment_status = 'behind', false) as seg_emi_missed
  from public.students s
  join public.classes c on c.id = s.class_id
  left join public.v_workbook_student_financials f on f.student_id = s.id
  left join emi on emi.student_id = s.id
  left join disc d on d.student_id = s.id
  left join cf on cf.student_id = s.id
  left join waivers w on w.student_id = s.id;

create or replace view public.v_ledger_policy_drift with (security_invoker = true) as
  with sess as (select distinct session_label from public.classes)
  select se.session_label,
         exists (select 1 from public.installments i join public.classes c on c.id = i.class_id where c.session_label = se.session_label) as has_ledger,
         (select count(*)::integer from public.installments i join public.students s on s.id = i.student_id
           join public.classes c on c.id = i.class_id
           where c.session_label = se.session_label and i.class_id <> s.class_id and i.status = 'scheduled') as stale_class_rows,
         (select count(*)::integer from public.installments i join public.students s on s.id = i.student_id
           join public.classes c on c.id = i.class_id
           where c.session_label = se.session_label and i.class_id <> s.class_id and i.status = 'scheduled'
             and exists (select 1 from public.payments p where p.installment_id = i.id)) as stale_class_locked_rows,
         exists (select 1 from public.installments i join public.students s on s.id = i.student_id
           join public.classes c on c.id = i.class_id
           where c.session_label = se.session_label and i.class_id <> s.class_id and i.status = 'scheduled') as drift
  from sess se;

-- Materialized-view refresh hooks the app calls; the views above are live, so
-- there is nothing to refresh.
create or replace function public.refresh_workbook_materialized_views_if_requested()
returns boolean language sql security definer set search_path to 'public' as $$ select false $$;
create or replace function public.queue_workbook_materialized_view_refresh()
returns void language sql security definer set search_path to 'public' as $$ select $$;

grant select on all tables in schema public to authenticated, service_role;
revoke all on function private.installment_ledger(uuid, date) from public, anon;
grant execute on function private.installment_ledger(uuid, date) to authenticated, service_role;
grant execute on function private.workbook_installment_snapshot(uuid, date, boolean) to authenticated, service_role;
