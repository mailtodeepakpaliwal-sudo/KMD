-- Local smoke test of the fee ledger. Run inside one transaction, rolled back.
\set ON_ERROR_STOP 1
begin;
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'admin@kmd.test');
insert into public.users (id, full_name, role, is_active) values ('11111111-1111-1111-1111-111111111111', 'KMD Admin', 'admin', true);
insert into public.app_settings (key, value) values ('active_session_label', '2026-27'), ('fee_writes_enabled', 'true')
  on conflict (key) do update set value = excluded.value;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
insert into public.academic_sessions (session_label, is_current, status) values ('2026-27', true, 'active');
insert into public.fee_policy_configs (academic_session_label, receipt_prefix, late_fee_flat_amount) values ('2026-27', 'KMD', 100);
insert into public.classes (id, session_label, class_name, sort_order) values ('22222222-2222-2222-2222-222222222222', '2026-27', 'Class 5', 8);
insert into public.fee_settings (class_id, tuition_fee_amount, late_fee_flat_amount) values ('22222222-2222-2222-2222-222222222222', 20000, 100);
insert into public.students (id, full_name, admission_no, class_id, status, father_phone)
  values ('33333333-3333-3333-3333-333333333333', 'Aarav Sharma', 'KMD-101', '22222222-2222-2222-2222-222222222222', 'active', '9999999999');
insert into public.installments (student_id, class_id, installment_no, installment_label, due_date, base_amount, amount_due, late_fee_flat_amount)
select '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', n, 'Installment ' || n,
       (date '2026-04-20' + (n - 1) * interval '3 months')::date, 5000, 5000, 100
from generate_series(1, 4) n;

\echo '--- ledger before any payment (as of 17 Nov 2026: inst 1-3 overdue, late fee 100 each)'
select installment_no, due_date, base_charge, final_late_fee, total_pending, balance_status, late_fee_status
from private.installment_ledger('33333333-3333-3333-3333-333333333333', '2026-11-17') order by installment_no;

\echo '--- post Rs 7000 on 17 Nov'
select * from public.post_student_payment_with_adjustments('33333333-3333-3333-3333-333333333333', '2026-11-17', 'cash', 7000,
  null, 'smoke', 'Office', 'KMD', 'aaaaaaaa-0000-0000-0000-000000000001', 0, 0);
\echo '--- the same request again returns the same receipt (idempotent)'
select * from public.post_student_payment_with_adjustments('33333333-3333-3333-3333-333333333333', '2026-11-17', 'cash', 7000,
  null, 'smoke', 'Office', 'KMD', 'aaaaaaaa-0000-0000-0000-000000000001', 0, 0);
select count(*) as receipts from public.receipts;

\echo '--- ledger after payment'
select installment_no, base_charge, final_late_fee, applied_amount, pending_amount, late_fee_pending, total_pending, balance_status
from private.installment_ledger('33333333-3333-3333-3333-333333333333', '2026-11-17') order by installment_no;

\echo '--- waive Rs 150 of late fee'
select * from public.waive_late_fee('33333333-3333-3333-3333-333333333333', 150, 'smoke waiver', '2026-27', null, null, false);

\echo '--- student financials'
select student_name, total_due, total_paid, outstanding_amount, late_fee_total, late_fee_waiver_amount, status_label, next_due_label, next_due_amount
from public.v_workbook_student_financials;

\echo '--- directory segments'
select * from public.get_student_segment_counts('2026-27');
select public.get_student_directory_summary('2026-27');

\echo '--- dashboards'
select jsonb_pretty(public.get_dashboard_summary('2026-27', '2026-11-17') -> 'kpis');
select jsonb_array_length(public.get_dashboard_analytics('2026-27') -> 'classRecovery') as class_rows;
select * from public.get_dashboard_fee_split('2026-27');

\echo '--- preview a payment'
select installment_no, total_pending, balance_status, plan_priority from public.preview_workbook_payment_allocation('33333333-3333-3333-3333-333333333333', '2026-11-17');

\echo '--- EMI plan preview, create'
select p ->> 'openingBalance' as opening, p ->> 'termMonths' as months, p -> 'errors' as errors
from (select public.preview_student_repayment_plan('33333333-3333-3333-3333-333333333333', '2026-27', 'old_and_current', 3000, '2026-12-10') p) x;
select public.create_student_repayment_plan('33333333-3333-3333-3333-333333333333', '2026-27', 'old_and_current', 3000, '2026-12-10', 'smoke plan') is not null as plan_created;
select lifecycle, opening_balance, item_count, remaining_balance, payment_status from public.v_student_repayment_plan_status;
select jsonb_pretty(public.get_dashboard_repayment_summary('2026-27') - 'topPriorityStudents');

\echo '--- reverse the receipt'
select * from public.reverse_receipt_admin((select id from public.receipts limit 1), 'smoke reversal');
select * from public.v_receipt_reversal_totals;
select total_paid, outstanding_amount from public.v_workbook_student_financials;

\echo '--- delete of a receipt is refused'
do $$ begin
  delete from public.receipts;
  raise exception 'delete was allowed';
exception when others then
  if sqlerrm like '%cannot be deleted%' then raise notice 'refused as expected'; else raise; end if;
end $$;
rollback;
