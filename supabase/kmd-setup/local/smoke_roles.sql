\set ON_ERROR_STOP 1
begin;
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'admin@kmd.test'), ('44444444-4444-4444-4444-444444444444', 'viewer@kmd.test');
insert into public.users (id, full_name, role, is_active) values ('11111111-1111-1111-1111-111111111111', 'KMD Admin', 'admin', true),
  ('44444444-4444-4444-4444-444444444444', 'Viewer', 'view_only', true);
insert into public.app_settings (key, value) values ('active_session_label', '2026-27'), ('fee_writes_enabled', 'true') on conflict (key) do update set value = excluded.value;
insert into public.academic_sessions (session_label, is_current, status) values ('2026-27', true, 'active');
insert into public.fee_policy_configs (academic_session_label, receipt_prefix) values ('2026-27', 'KMD');
insert into public.classes (id, session_label, class_name) values ('22222222-2222-2222-2222-222222222222', '2026-27', 'Class 5');
insert into public.students (id, full_name, class_id) values ('33333333-3333-3333-3333-333333333333', 'Aarav', '22222222-2222-2222-2222-222222222222');
insert into public.installments (student_id, class_id, installment_no, installment_label, due_date, amount_due)
  values ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', 1, 'Installment 1', '2027-01-10', 5000);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
\echo '--- admin (authenticated role) reads views and posts'
select count(*) as fin_rows from public.v_workbook_student_financials;
select receipt_number from public.post_student_payment_with_adjustments('33333333-3333-3333-3333-333333333333', current_date, 'upi', 1000, 'UTR1', null, 'Desk', 'KMD', gen_random_uuid(), 0, 0);
select (public.get_dashboard_summary('2026-27', null) -> 'kpis' ->> 'totalCollected') as collected;

select set_config('request.jwt.claims', '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
\echo '--- viewer cannot post'
do $$ begin
  perform public.post_student_payment_with_adjustments('33333333-3333-3333-3333-333333333333', current_date, 'cash', 100, null, null, 'x', 'KMD', gen_random_uuid(), 0, 0);
  raise exception 'viewer posted!';
exception when others then raise notice 'viewer refused: %', sqlerrm; end $$;
\echo '--- viewer cannot write a table directly'
do $$ begin
  update public.students set full_name = 'Hacked';
  if found then raise exception 'viewer updated students!'; end if;
  raise notice 'viewer update touched no rows (no policy)';
exception when insufficient_privilege then raise notice 'viewer update refused'; end $$;

reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
\echo '--- anonymous visitor sees nothing'
do $$ begin
  perform 1 from public.students;
  raise exception 'anon read students!';
exception when insufficient_privilege then raise notice 'anon refused'; end $$;
rollback;
