-- ============================================================================
-- KMD One — fee functions the app calls (supabase.rpc). Written for a fresh
-- KMD Public School database. Money rules match private.installment_ledger
-- and the posting engine (private.post_student_payment_core, created by
-- fee-migration 20261028140100_online_payments).
-- ============================================================================

-- ------------------------------------------------------------- helpers
create or replace function private.require_permission(p_permission text, p_message text default null)
returns void language plpgsql stable security definer set search_path to 'public', 'private' as $$
begin
  if coalesce(auth.role(), '') = 'service_role' or session_user in ('postgres', 'supabase_admin') and auth.uid() is null then
    return;
  end if;
  if not public.has_permission(p_permission) then
    raise exception '%', coalesce(p_message, 'You do not have permission to do this.') using errcode = '42501';
  end if;
end $$;

create or replace function private.class_label(p_class_id uuid)
returns text language sql stable set search_path to 'public' as $$
  select concat_ws(' ', c.class_name, nullif(c.section, ''), nullif(c.stream_name, '')) from public.classes c where c.id = p_class_id
$$;

-- ------------------------------------------------------------- posting
-- The desk's plain posting RPC: the core with no counter concessions.
create or replace function public.post_student_payment(
  p_student_id uuid,
  p_payment_date date,
  p_payment_mode payment_mode,
  p_total_amount integer,
  p_reference_number text default null,
  p_remarks text default null,
  p_received_by text default null,
  p_receipt_prefix text default 'KMD',
  p_client_request_id uuid default null
)
returns table (receipt_id uuid, receipt_number text, allocated_total integer)
language plpgsql security definer set search_path to 'public', 'private' as $$
begin
  return query select * from private.post_student_payment_core(
    p_student_id, p_payment_date, p_payment_mode, p_total_amount, p_reference_number,
    p_remarks, p_received_by, coalesce(nullif(btrim(p_receipt_prefix), ''), 'KMD'), p_client_request_id, 0, 0);
end $$;

-- What a payment on p_payment_date would settle, row by row, in the engine's order.
create or replace function public.preview_workbook_payment_allocation(p_student_id uuid, p_payment_date date)
returns table (
  installment_id uuid, installment_no integer, installment_label text, is_carry_forward boolean,
  source_session_label text, target_session_label text, carry_forward_fee_head text, due_date date,
  total_charge integer, paid_amount integer, adjustment_amount integer, raw_late_fee integer,
  waiver_applied integer, final_late_fee integer, pending_amount integer, late_fee_pending integer,
  total_pending integer, balance_status text, settled_amount integer, plan_priority integer
)
language plpgsql stable security definer set search_path to 'public', 'private' as $$
declare v_plan_id uuid;
begin
  perform private.require_permission('payments:view', 'You do not have permission to view payments.');
  select p.id into v_plan_id from public.student_repayment_plans p
   where p.student_id = p_student_id and p.lifecycle = 'active' limit 1;
  return query
  select l.installment_id, l.installment_no, l.installment_label, l.is_carry_forward,
         l.source_session_label, case when l.is_carry_forward then l.session_label end,
         cf.fee_head, l.due_date, l.total_charge, l.paid_amount, l.adjustment_amount, l.raw_late_fee,
         l.waiver_applied, l.final_late_fee, l.pending_amount, l.late_fee_pending, l.total_pending,
         l.balance_status, l.settled_amount,
         case when pi.installment_id is null then 1 else 0 end
  from private.installment_ledger(p_student_id, p_payment_date) l
  left join public.student_repayment_plan_items pi on pi.installment_id = l.installment_id and pi.plan_id = v_plan_id
  left join public.student_carry_forward_balances cf on cf.installment_id = l.installment_id
  order by case when pi.installment_id is null then 1 else 0 end, l.due_date, l.installment_no;
end $$;

-- ------------------------------------------------------------- reversal
-- Undo the money on one receipt: a 'reversal' adjustment per payment for what
-- is not yet reversed, and the receipt's counter concessions taken back.
create or replace function private.reverse_receipt(p_receipt_id uuid, p_reason text)
returns table (receipt_id uuid, receipt_number text, reversed_amount integer, already_reversed_amount integer, concession_amount integer)
language plpgsql security definer set search_path to 'public', 'private' as $$
declare
  v_receipt public.receipts%rowtype;
  v_reversed integer := 0;
  v_already integer := 0;
  v_concession integer := 0;
  r record;
begin
  select * into v_receipt from public.receipts where id = p_receipt_id;
  if not found then raise exception 'Receipt not found.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required to reverse a receipt.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_receipt.student_id::text, 0));

  for r in
    select p.id, p.installment_id, p.amount,
           coalesce((select -sum(pa.amount_delta) from public.payment_adjustments pa
                      where pa.payment_id = p.id and pa.adjustment_type = 'reversal'), 0)::integer as done
    from public.payments p where p.receipt_id = p_receipt_id
  loop
    v_already := v_already + r.done;
    if r.amount - r.done > 0 then
      insert into public.payment_adjustments (payment_id, student_id, installment_id, adjustment_type, amount_delta, reason, created_by)
      values (r.id, v_receipt.student_id, r.installment_id, 'reversal', -(r.amount - r.done), p_reason, auth.uid());
      v_reversed := v_reversed + (r.amount - r.done);
    end if;
  end loop;

  for r in
    select ra.installment_id, ra.adjustment_type, sum(ra.amount_delta)::integer as net
    from public.receipt_adjustments ra
    where ra.receipt_id = p_receipt_id and ra.adjustment_type in ('discount', 'writeoff')
    group by ra.installment_id, ra.adjustment_type having sum(ra.amount_delta) > 0
  loop
    insert into public.receipt_adjustments (receipt_id, student_id, installment_id, adjustment_type, amount_delta, reason, notes)
    values (p_receipt_id, v_receipt.student_id, r.installment_id, r.adjustment_type, -r.net, 'Reversed with receipt', p_reason);
    v_concession := v_concession + r.net;
  end loop;

  if v_reversed = 0 and v_concession = 0 then
    raise exception 'This receipt has already been reversed.';
  end if;
  return query select v_receipt.id, v_receipt.receipt_number, v_reversed, v_already, v_concession;
end $$;

create or replace function public.reverse_receipt_admin(p_receipt_id uuid, p_reason text)
returns table (receipt_id uuid, receipt_number text, reversed_amount integer, already_reversed_amount integer, concession_amount integer)
language plpgsql security definer set search_path to 'public', 'private' as $$
begin
  perform private.require_permission('payments:reverse_any', 'Only an admin can reverse a receipt.');
  return query select * from private.reverse_receipt(p_receipt_id, p_reason);
end $$;

-- The 10-minute undo for the person who took the payment.
create or replace function public.undo_recent_payment(p_receipt_id uuid, p_reason text default null)
returns table (receipt_id uuid, receipt_number text, reversed_amount integer)
language plpgsql security definer set search_path to 'public', 'private' as $$
declare v_receipt public.receipts%rowtype;
begin
  perform private.require_permission('payments:write', 'You do not have permission to undo payments.');
  select * into v_receipt from public.receipts r where r.id = p_receipt_id;
  if not found then raise exception 'Receipt not found.'; end if;
  if v_receipt.created_at < now() - interval '10 minutes' then
    raise exception 'The 10-minute undo window has passed. Ask an admin to reverse this receipt.';
  end if;
  if v_receipt.created_by is not null and v_receipt.created_by <> auth.uid() and not public.has_permission('payments:reverse_any') then
    raise exception 'Only the person who took this payment can undo it.';
  end if;
  return query select x.receipt_id, x.receipt_number, x.reversed_amount
    from private.reverse_receipt(p_receipt_id, coalesce(nullif(btrim(p_reason), ''), 'Undone at the Payment Desk')) x;
end $$;

-- Who took the payment.
create or replace function private.receipts_set_created_by() returns trigger language plpgsql as $$
begin
  new.created_by := coalesce(new.created_by, auth.uid());
  new.session_label := coalesce(new.session_label,
    (select c.session_label from public.students s join public.classes c on c.id = s.class_id where s.id = new.student_id));
  return new;
end $$;
create trigger receipts_set_created_by before insert on public.receipts for each row execute function private.receipts_set_created_by();

-- ------------------------------------------------------------- late fee waiver
create or replace function public.waive_late_fee(
  p_student_id uuid,
  p_amount integer,
  p_remarks text default null,
  p_session_label text default null,
  p_client_request_id uuid default null,
  p_installment_id uuid default null,
  p_include_collected boolean default false
)
returns table (ok boolean, message text, waived_amount integer)
language plpgsql security definer set search_path to 'public', 'private' as $$
declare
  v_left integer := greatest(coalesce(p_amount, 0), 0);
  v_done integer := 0;
  v_take integer;
  v_label text;
  r record;
begin
  perform private.require_permission('payments:waive_late_fee', 'You do not have permission to waive late fees.');
  if v_left <= 0 then
    return query select false, 'Enter an amount to waive.', 0; return;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_student_id::text, 0));

  if p_client_request_id is not null and exists (
    select 1 from public.student_late_fee_waivers w where w.student_id = p_student_id and w.client_request_id = p_client_request_id and w.voided_at is null
  ) then
    return query select true, 'Already waived.', (select sum(w.amount)::integer from public.student_late_fee_waivers w
      where w.student_id = p_student_id and w.client_request_id = p_client_request_id and w.voided_at is null);
    return;
  end if;

  select coalesce(u.full_name, sp.display_name) into v_label
  from (select auth.uid() as id) me
  left join public.users u on u.id = me.id
  left join vppsone.staff_profiles sp on sp.user_id = me.id;

  for r in
    select l.installment_id, l.session_label, l.final_late_fee, l.late_fee_pending
    from private.installment_ledger(p_student_id, null) l
    where l.final_late_fee > 0
      and (l.late_fee_pending > 0 or coalesce(p_include_collected, false))
      and (p_installment_id is null or l.installment_id = p_installment_id)
      and (p_session_label is null or l.session_label = p_session_label or l.source_session_label = p_session_label)
    order by (l.late_fee_pending > 0) desc, l.due_date, l.installment_no
  loop
    exit when v_left <= 0;
    v_take := least(v_left, case when r.late_fee_pending > 0 then r.late_fee_pending else r.final_late_fee end);
    if v_take > 0 then
      insert into public.student_late_fee_waivers (student_id, installment_id, session_label, amount, reason, source,
                                                   client_request_id, waived_at, waived_by_label)
      values (p_student_id, r.installment_id, r.session_label, v_take, coalesce(p_remarks, 'Late fee waived'),
              case when r.late_fee_pending > 0 then 'manual' else 'manual_collected' end,
              p_client_request_id, now(), v_label);
      v_left := v_left - v_take;
      v_done := v_done + v_take;
    end if;
  end loop;

  if v_done = 0 then
    return query select false, 'No pending late fee to waive.', 0; return;
  end if;
  return query select true, null::text, v_done;
end $$;

-- ------------------------------------------------------------- refunds
create or replace function public.process_refund_with_adjustment(p_refund_request_id uuid)
returns void language plpgsql security definer set search_path to 'public', 'private' as $$
declare
  v_req public.refund_requests%rowtype;
  v_left integer;
  v_take integer;
  r record;
begin
  perform private.require_permission('finance:approve', 'Only an admin can process a refund.');
  select * into v_req from public.refund_requests where id = p_refund_request_id for update;
  if not found then raise exception 'Refund request not found.'; end if;
  if v_req.status = 'processed' then raise exception 'This refund has already been processed.'; end if;
  if v_req.status <> 'approved' then raise exception 'Approve the refund before processing it.'; end if;
  v_left := greatest(coalesce(v_req.requested_amount, 0), 0);
  if v_left <= 0 then raise exception 'The refund amount must be greater than 0.'; end if;

  for r in
    select p.id, p.installment_id, p.student_id,
           p.amount + coalesce((select sum(pa.amount_delta) from public.payment_adjustments pa where pa.payment_id = p.id), 0) as net
    from public.payments p
    where p.receipt_id = v_req.receipt_id
    order by p.created_at desc
  loop
    exit when v_left <= 0;
    v_take := least(v_left, greatest(r.net, 0));
    if v_take > 0 then
      insert into public.payment_adjustments (payment_id, student_id, installment_id, adjustment_type, amount_delta, reason, notes, created_by)
      values (r.id, r.student_id, r.installment_id, 'reversal', -v_take, 'Refund', v_req.reason, auth.uid());
      v_left := v_left - v_take;
    end if;
  end loop;
  if v_left > 0 then raise exception 'The refund is larger than what is left on this receipt.'; end if;

  update public.refund_requests
     set status = 'processed', processed_at = now(), processed_by = auth.uid(),
         refund_date = coalesce(refund_date, private.ist_today())
   where id = p_refund_request_id;
end $$;

-- ------------------------------------------------------------- dashboards
-- Students whose money counts: on the roll, or who have paid something.
create or replace function private.money_students(p_session_label text)
returns setof public.v_workbook_student_financials language sql stable security definer set search_path to 'public', 'private' as $$
  select f.* from public.v_workbook_student_financials f
  where f.session_label = p_session_label and (f.record_status = 'active' or f.total_paid > 0)
$$;

create or replace function public.get_dashboard_fee_split(p_session_label text)
returns table (current_year_expected integer, current_year_collected integer, current_year_pending integer,
               previous_year_original integer, previous_year_collected integer, previous_year_pending integer,
               late_fee_pending integer)
language sql stable security definer set search_path to 'public', 'private' as $$
  with l as (
    select b.* from public.v_workbook_installment_balances b
    join public.students s on s.id = b.student_id
    where b.session_label = p_session_label
      and (s.status = 'active' or exists (select 1 from public.payments p where p.student_id = s.id))
  )
  select coalesce(sum(base_charge) filter (where not is_carry_forward), 0)::integer,
         coalesce(sum(fee_settled_amount) filter (where not is_carry_forward), 0)::integer,
         coalesce(sum(pending_amount) filter (where not is_carry_forward), 0)::integer,
         coalesce(sum(base_charge) filter (where is_carry_forward), 0)::integer,
         coalesce(sum(fee_settled_amount) filter (where is_carry_forward), 0)::integer,
         coalesce(sum(pending_amount) filter (where is_carry_forward), 0)::integer,
         coalesce(sum(late_fee_pending), 0)::integer
  from l
$$;

create or replace function public.get_dashboard_summary(p_session_label text, p_today text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public', 'private' as $$
declare
  v_today date := coalesce(nullif(p_today, '')::date, private.ist_today());
  v_result jsonb;
begin
  perform private.require_permission('dashboard:view', 'You do not have permission to view the dashboard.');
  with fin as (select * from private.money_students(p_session_label)),
  inst as (
    select b.* from public.v_workbook_installment_balances b
    join fin on fin.student_id = b.student_id
  ),
  rcpt as (
    select r.id, r.receipt_number, r.payment_date, r.payment_mode::text as payment_mode, r.student_id,
           r.total_amount - coalesce(t.reversed_amount, 0) as amount
    from public.receipts r
    join public.students s on s.id = r.student_id
    join public.classes c on c.id = s.class_id and c.session_label = p_session_label
    left join public.v_receipt_reversal_totals t on t.receipt_id = r.id
    where r.payment_mode <> 'discount'
  ),
  split as (select * from public.get_dashboard_fee_split(p_session_label))
  select jsonb_build_object(
    'kpis', jsonb_build_object(
      'totalStudents', (select count(*) from fin where record_status = 'active'),
      'totalExpectedFees', coalesce((select sum(total_due) from fin), 0),
      'totalCollected', coalesce((select sum(total_paid) from fin), 0),
      'totalPending', coalesce((select sum(outstanding_amount) from fin), 0),
      'currentYearExpected', (select current_year_expected from split),
      'currentYearCollected', (select current_year_collected from split),
      'currentYearPending', (select current_year_pending from split),
      'previousYearOriginal', (select previous_year_original from split),
      'previousYearCollected', (select previous_year_collected from split),
      'previousYearPending', (select previous_year_pending from split),
      'lateFeePending', (select late_fee_pending from split),
      'overdueAmount', coalesce((select sum(total_pending) from inst where balance_status = 'overdue'), 0),
      'todaysCollection', coalesce((select sum(amount) from rcpt where payment_date = v_today), 0),
      'thisMonthCollection', coalesce((select sum(amount) from rcpt where date_trunc('month', payment_date) = date_trunc('month', v_today::timestamp)), 0),
      'receiptsToday', (select count(*) from rcpt where payment_date = v_today),
      'collectionRate', coalesce((select round(100.0 * sum(total_paid) / nullif(sum(total_due), 0)) from fin), 0)
    ),
    'todayPaymentModeBreakdown', coalesce((
      select jsonb_agg(jsonb_build_object('paymentMode', payment_mode, 'amount', amt, 'receiptCount', n) order by amt desc)
      from (select payment_mode, sum(amount) as amt, count(*) as n from rcpt where payment_date = v_today group by payment_mode) x
    ), '[]'::jsonb),
    'recentPayments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'receiptId', x.id, 'receiptNumber', x.receipt_number, 'paymentDate', x.payment_date,
        'studentId', x.student_id, 'studentName', s.full_name, 'admissionNo', coalesce(s.admission_no, ''),
        'classLabel', private.class_label(s.class_id), 'paymentMode', x.payment_mode, 'amount', x.amount) order by x.payment_date desc, x.receipt_number desc)
      from (select * from rcpt order by payment_date desc, receipt_number desc limit 10) x
      join public.students s on s.id = x.student_id
    ), '[]'::jsonb),
    'followUpQueue', coalesce((
      select jsonb_agg(jsonb_build_object(
        'studentId', f.student_id, 'studentName', f.student_name, 'admissionNo', coalesce(f.admission_no, ''),
        'classId', f.class_id, 'classLabel', f.class_label, 'fatherPhone', f.father_phone,
        'outstandingAmount', f.outstanding_amount, 'nextDueDate', f.next_due_date, 'nextDueLabel', f.next_due_label,
        'nextDueAmount', f.next_due_amount, 'statusLabel', f.status_label,
        'reminderText', format('Dear parent, Rs %s is pending for %s (%s). Kindly pay at the earliest. — KMD Public School, Jaipur',
                               f.outstanding_amount, f.student_name, f.class_label)) order by f.outstanding_amount desc)
      from (select * from fin where outstanding_amount > 0 and overdue_installment_count > 0 order by outstanding_amount desc limit 20) f
    ), '[]'::jsonb),
    'emptyState', jsonb_build_object(
      'hasStudents', exists (select 1 from public.students s join public.classes c on c.id = s.class_id where c.session_label = p_session_label),
      'hasReceipts', exists (select 1 from rcpt),
      'hasFinancialData', exists (select 1 from inst)),
    'studentsWithPending', (select count(*) from fin where outstanding_amount > 0),
    'totalRefundDue', coalesce((select sum(requested_amount) from public.refund_requests where status in ('pending_approval', 'approved')), 0),
    'collectionTrend', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'amount', coalesce(amt, 0), 'receiptCount', coalesce(n, 0)) order by d)
      from generate_series(v_today - 29, v_today, interval '1 day') g(d)
      left join (select payment_date, sum(amount) as amt, count(*) as n from rcpt group by payment_date) x on x.payment_date = g.d::date
    ), '[]'::jsonb),
    'collectionHeatmap', coalesce((
      select jsonb_agg(jsonb_build_object('date', payment_date, 'amount', amt) order by payment_date)
      from (select payment_date, sum(amount) as amt from rcpt where payment_date > v_today - 365 group by payment_date) x
    ), '[]'::jsonb),
    'classSummary', coalesce((
      select jsonb_agg(jsonb_build_object(
        'classId', x.id, 'sessionLabel', x.session_label, 'classLabel', private.class_label(x.id),
        'totalStudents', x.total_students, 'studentsWithGeneratedDues', x.with_dues, 'missingDuesStudents', x.missing_dues,
        'expectedAmount', x.expected, 'collectedAmount', x.collected, 'pendingAmount', x.pending,
        'overdueAmount', x.overdue_amount, 'overdueStudents', x.overdue_students, 'studentsWithPending', x.with_pending,
        'collectionRate', x.rate) order by x.sort_order, x.class_name)
      from (
        select c.id, c.session_label, c.sort_order, c.class_name,
               count(f.student_id) filter (where f.record_status = 'active') as total_students,
               count(f.student_id) filter (where f.total_due > 0) as with_dues,
               count(f.student_id) filter (where f.total_due = 0 and f.record_status = 'active') as missing_dues,
               coalesce(sum(f.total_due), 0) as expected, coalesce(sum(f.total_paid), 0) as collected,
               coalesce(sum(f.outstanding_amount), 0) as pending,
               coalesce(sum(f.outstanding_amount) filter (where f.overdue_installment_count > 0), 0) as overdue_amount,
               count(f.student_id) filter (where f.overdue_installment_count > 0) as overdue_students,
               count(f.student_id) filter (where f.outstanding_amount > 0) as with_pending,
               coalesce(round(100.0 * sum(f.total_paid) / nullif(sum(f.total_due), 0)), 0) as rate
        from public.classes c left join fin f on f.class_id = c.id
        where c.session_label = p_session_label and c.status = 'active'
        group by c.id
      ) x
    ), '[]'::jsonb),
    'installmentSummary', coalesce((
      select jsonb_agg(row_to_json(x)::jsonb order by x."installmentNo")
      from (select installment_no as "installmentNo", min(installment_label) as "installmentLabel",
                   bool_or(is_carry_forward) as "isCarryForward", min(source_session_label) as "sourceSessionLabel",
                   min(due_date) as "dueDate", count(distinct student_id) as "studentCount",
                   sum(total_charge) as "expectedAmount", sum(settled_amount) as "collectedAmount",
                   sum(total_pending) as "pendingAmount",
                   coalesce(sum(total_pending) filter (where balance_status = 'overdue'), 0) as "overdueAmount",
                   coalesce(round(100.0 * sum(settled_amount) / nullif(sum(total_charge), 0)), 0) as "collectionRate"
            from inst group by installment_no) x
    ), '[]'::jsonb),
    'classInstallmentMatrix', coalesce((
      select jsonb_agg(jsonb_build_object('classId', class_id, 'classLabel', class_label, 'installments', items, 'totalPendingAmount', total) order by class_label)
      from (select class_id, min(class_label) as class_label, sum(p) as total,
                   jsonb_agg(jsonb_build_object('installmentNo', installment_no, 'installmentLabel', lbl, 'isCarryForward', cf,
                                                'sourceSessionLabel', src, 'pendingAmount', p) order by installment_no) as items
            from (select class_id, class_label, installment_no, min(installment_label) as lbl, bool_or(is_carry_forward) as cf,
                         min(source_session_label) as src, sum(total_pending) as p
                  from inst group by class_id, class_label, installment_no) y
            group by class_id) x
    ), '[]'::jsonb),
    'overdueInstallmentCount', (select count(*) from inst where balance_status = 'overdue'),
    'paidStudents', (select count(*) from fin where status_label = 'PAID'),
    'partlyPaidStudents', (select count(*) from fin where status_label = 'PARTLY PAID'),
    'overdueStudents', (select count(*) from fin where status_label = 'OVERDUE'),
    'notStartedStudents', (select count(*) from fin where status_label = 'NOT STARTED'),
    'systemSyncHealth', null
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_dashboard_analytics(p_session_label text)
returns jsonb language plpgsql stable security definer set search_path to 'public', 'private' as $$
declare v_today date := private.ist_today(); v_result jsonb;
begin
  perform private.require_permission('dashboard:view', 'You do not have permission to view the dashboard.');
  with fin as (select * from private.money_students(p_session_label)),
  inst as (select b.* from public.v_workbook_installment_balances b join fin on fin.student_id = b.student_id),
  rcpt as (
    select r.id, r.payment_date, r.payment_mode::text as payment_mode, r.student_id,
           r.total_amount - coalesce(t.reversed_amount, 0) as amount
    from public.receipts r
    join public.students s on s.id = r.student_id
    join public.classes c on c.id = s.class_id and c.session_label = p_session_label
    left join public.v_receipt_reversal_totals t on t.receipt_id = r.id
    where r.payment_mode <> 'discount'
  ),
  ranked as (select outstanding_amount, row_number() over (order by outstanding_amount desc) as rn from fin where outstanding_amount > 0)
  select jsonb_build_object(
    'sessionLabel', p_session_label,
    'debtAge', coalesce((
      select jsonb_agg(jsonb_build_object('bucket', bucket, 'feesPending', amt, 'rows', n, 'students', st) order by ord)
      from (select case when v_today - due_date <= 30 then '0-30' when v_today - due_date <= 60 then '31-60'
                        when v_today - due_date <= 90 then '61-90' else '90+' end as bucket,
                   min(case when v_today - due_date <= 30 then 1 when v_today - due_date <= 60 then 2 when v_today - due_date <= 90 then 3 else 4 end) as ord,
                   sum(pending_amount) as amt, count(*) as n, count(distinct student_id) as st
            from inst where pending_amount > 0 and due_date < v_today group by 1) x
    ), '[]'::jsonb),
    'lateFee', jsonb_build_object(
      'charged', coalesce((select sum(final_late_fee + waiver_applied) from inst), 0),
      'waived', coalesce((select sum(waiver_applied) from inst), 0),
      'pending', coalesce((select sum(late_fee_pending) from inst), 0),
      'studentsWithPending', (select count(distinct student_id) from inst where late_fee_pending > 0),
      'byWaiverSource', coalesce((
        select jsonb_agg(jsonb_build_object('source', coalesce(w.source, 'manual'), 'amount', sum_amt, 'count', n))
        from (select w.source, sum(w.amount) as sum_amt, count(*) as n from public.student_late_fee_waivers w
              where w.voided_at is null and w.session_label = p_session_label group by w.source) w
      ), '[]'::jsonb),
      'nextAccrual', (
        with nxt as (select min(b.due_date) as d from inst b where b.due_date >= v_today and b.pending_amount > 0)
        select jsonb_build_object('dueDate', nxt.d,
                 'amount', coalesce((select sum(i.late_fee_flat_amount) from inst b join public.installments i on i.id = b.installment_id
                                     where b.due_date = nxt.d and b.pending_amount > 0), 0),
                 'installments', (select count(*) from inst b where b.due_date = nxt.d and b.pending_amount > 0))
        from nxt)
    ),
    'monthlyCollection', coalesce((
      select jsonb_agg(jsonb_build_object('month', m.month, 'amount', m.amt, 'receipts', m.n, 'students', m.st,
                                          'byMode', coalesce(md.modes, '{}'::jsonb)) order by m.month)
      from (select to_char(r.payment_date, 'YYYY-MM') as month, sum(r.amount) as amt, count(*) as n, count(distinct r.student_id) as st
            from rcpt r group by 1) m
      left join (select y.month, jsonb_object_agg(y.payment_mode, y.amt) as modes
                 from (select to_char(r.payment_date, 'YYYY-MM') as month, r.payment_mode, sum(r.amount) as amt
                       from rcpt r group by 1, 2) y group by y.month) md on md.month = m.month
    ), '[]'::jsonb),
    'classRecovery', coalesce((
      select jsonb_agg(jsonb_build_object('classId', class_id, 'classLabel', class_label, 'expected', exp, 'collected', col,
                                          'feesPending', fp, 'lateFeePending', lp, 'studentsAtRisk', risk, 'students', n,
                                          'recoveryRate', coalesce(round(100.0 * col / nullif(exp, 0)), 0)) order by class_label)
      from (select class_id, min(class_label) as class_label, sum(total_due) as exp, sum(total_paid) as col,
                   sum(base_outstanding_amount) as fp, sum(late_fee_outstanding_amount) as lp,
                   count(*) filter (where overdue_installment_count > 0) as risk, count(*) as n
            from fin group by class_id) x
    ), '[]'::jsonb),
    'routeRecovery', coalesce((
      select jsonb_agg(jsonb_build_object('routeId', transport_route_id, 'routeLabel', coalesce(lbl, 'No transport'), 'studentCount', n,
                                          'expectedAmount', exp, 'collectedAmount', col, 'pendingAmount', pend,
                                          'collectionRate', coalesce(round(100.0 * col / nullif(exp, 0)), 0)) order by pend desc)
      from (select transport_route_id, min(transport_route_name) as lbl, count(*) as n, sum(base_charge_total) as exp,
                   sum(total_paid) as col, sum(outstanding_amount) as pend
            from fin where transport_route_id is not null group by transport_route_id) x
    ), '[]'::jsonb),
    'concentration', jsonb_build_object(
      'studentsWithDues', (select count(*) from ranked),
      'totalPending', coalesce((select sum(outstanding_amount) from ranked), 0),
      'top10Amount', coalesce((select sum(outstanding_amount) from ranked where rn <= 10), 0),
      'top10Pct', coalesce((select round(100.0 * sum(outstanding_amount) filter (where rn <= 10) / nullif(sum(outstanding_amount), 0)) from ranked), 0),
      'top50Amount', coalesce((select sum(outstanding_amount) from ranked where rn <= 50), 0),
      'top50Pct', coalesce((select round(100.0 * sum(outstanding_amount) filter (where rn <= 50) / nullif(sum(outstanding_amount), 0)) from ranked), 0)),
    'discounts', jsonb_build_object(
      'totalDiscount', coalesce((select sum(discount_amount) from fin), 0),
      'conventionalDiscount', coalesce((select sum(greatest(coalesce(a.before_tuition_amount, 0) - coalesce(a.resulting_tuition_amount, 0), 0))
                                        from public.student_conventional_discount_assignments a
                                        where a.academic_session_label = p_session_label and coalesce(a.is_active, true)), 0),
      'manualDiscount', coalesce((select sum(discount_amount) from fin), 0),
      'studentsWithDiscount', (select count(*) from fin where discount_amount > 0),
      'byPolicy', coalesce((
        select jsonb_agg(jsonb_build_object('label', x.label, 'students', x.students, 'amount', x.amount))
        from (select p.display_name as label, count(*) as students,
                     sum(greatest(coalesce(a.before_tuition_amount, 0) - coalesce(a.resulting_tuition_amount, 0), 0)) as amount
              from public.student_conventional_discount_assignments a
              join public.conventional_discount_policies p on p.id = a.policy_id
              where a.academic_session_label = p_session_label and coalesce(a.is_active, true)
              group by p.display_name) x
      ), '[]'::jsonb),
      'closeouts', jsonb_build_object('amount', coalesce((select sum(total_discount_closeouts) from fin), 0),
                                      'students', (select count(*) from fin where total_discount_closeouts > 0)))
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_dashboard_repayment_summary(p_session_label text)
returns jsonb language plpgsql stable security definer set search_path to 'public', 'private' as $$
declare v_today date := private.ist_today(); v_result jsonb;
begin
  perform private.require_permission('dashboard:view', 'You do not have permission to view the dashboard.');
  with p as (select * from public.v_student_repayment_plan_status where session_label = p_session_label)
  select jsonb_build_object(
    'sessionLabel', p_session_label,
    'activePlans', (select count(*) from p where lifecycle = 'active'),
    'onTrack', (select count(*) from p where lifecycle = 'active' and payment_status in ('on_track', 'upcoming')),
    'dueNow', (select count(*) from p where lifecycle = 'active' and payment_status = 'due'),
    'missed', (select count(*) from p where lifecycle = 'active' and payment_status = 'behind'),
    'completed', (select count(*) from p where payment_status = 'completed'),
    'planReviewNeeded', (select count(*) from p where lifecycle = 'active' and plan_review_needed),
    'openingBalanceTotal', coalesce((select sum(opening_balance) from p where lifecycle = 'active'), 0),
    'remainingTotal', coalesce((select sum(remaining_balance) from p where lifecycle = 'active'), 0),
    'catchUpTotal', coalesce((select sum(catch_up_amount) from p where lifecycle = 'active'), 0),
    'expectedThisMonth', coalesce((select sum(sc.amount) from public.student_repayment_schedule sc join p on p.plan_id = sc.plan_id
                                   where p.lifecycle = 'active' and date_trunc('month', sc.due_date) = date_trunc('month', v_today::timestamp)), 0),
    'collectedThisMonth', coalesce((select sum(rl.contribution_amount) from public.student_repayment_receipt_links rl
                                    join p on p.plan_id = rl.plan_id join public.receipts r on r.id = rl.receipt_id
                                    where date_trunc('month', r.payment_date) = date_trunc('month', v_today::timestamp)), 0),
    'topPriorityStudents', coalesce((
      select jsonb_agg(jsonb_build_object('studentId', p.student_id, 'planId', p.plan_id, 'studentName', s.full_name,
                 'admissionNo', coalesce(s.admission_no, ''), 'paymentStatus', p.payment_status,
                 'missedInstallmentCount', p.missed_installment_count, 'catchUpAmount', p.catch_up_amount,
                 'remainingBalance', p.remaining_balance, 'nextDueDate', p.next_due_date)
               order by p.missed_installment_count desc, p.catch_up_amount desc)
      from (select * from p where lifecycle = 'active' and payment_status in ('behind', 'due')
            order by missed_installment_count desc, catch_up_amount desc limit 10) p
      join public.students s on s.id = p.student_id
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_student_directory_summary(
  p_session_label text,
  p_class_id uuid default null,
  p_route_id uuid default null,
  p_query text default null,
  p_statuses text[] default null,
  p_active_classes_only boolean default true
)
returns jsonb language sql stable security definer set search_path to 'public', 'private' as $$
  select jsonb_build_object(
    'studentCount', count(*),
    'expectedFees', coalesce(sum(d.total_due), 0),
    'totalPaid', coalesce(sum(d.total_paid), 0),
    'totalOutstanding', coalesce(sum(d.outstanding_amount), 0),
    'oldBalanceOutstanding', coalesce(sum(cf.remaining), 0),
    'lateFeeOutstanding', coalesce(sum(d.late_fee_outstanding_amount), 0),
    'totalDiscount', coalesce(sum(f.discount_amount), 0),
    'transportStudentCount', count(*) filter (where d.transport_route_id is not null))
  from public.v_student_directory d
  left join public.v_workbook_student_financials f on f.student_id = d.student_id
  left join (select student_id, sum(remaining_amount) as remaining from public.v_student_carry_forward_balances group by student_id) cf
    on cf.student_id = d.student_id
  where d.session_label = p_session_label
    and (not coalesce(p_active_classes_only, true) or d.class_status = 'active')
    and (p_class_id is null or d.class_id = p_class_id)
    and (p_route_id is null or d.transport_route_id = p_route_id)
    and (p_statuses is null or d.record_status = any (p_statuses))
    and (p_query is null or btrim(p_query) = '' or d.search_text like '%' || lower(btrim(p_query)) || '%')
$$;

-- ------------------------------------------------------------- EMI plans
-- The dues a plan would cover, and its monthly schedule.
create or replace function private.repayment_plan_build(
  p_student_id uuid, p_session_label text, p_scope text, p_monthly_amount integer,
  p_first_due_date date, p_due_dates date[] default null
)
returns jsonb language plpgsql stable security definer set search_path to 'public', 'private' as $$
declare
  v_items jsonb;
  v_opening integer;
  v_old integer;
  v_current integer;
  v_late integer;
  v_schedule jsonb := '[]'::jsonb;
  v_errors text[] := '{}';
  v_left integer;
  v_seq integer := 0;
  v_amount integer;
  v_due date;
  v_active boolean;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'installmentId', l.installment_id, 'installmentNo', l.installment_no, 'installmentLabel', l.installment_label,
           'dueDate', l.due_date, 'isCarryForward', l.is_carry_forward, 'baseCharge', l.base_charge,
           'includedBaseBalance', l.pending_amount, 'chargedLateFee', l.late_fee_pending) order by l.due_date, l.installment_no), '[]'::jsonb),
         coalesce(sum(l.pending_amount), 0)::integer,
         coalesce(sum(l.pending_amount) filter (where l.is_carry_forward), 0)::integer,
         coalesce(sum(l.pending_amount) filter (where not l.is_carry_forward), 0)::integer,
         coalesce(sum(l.late_fee_pending), 0)::integer
    into v_items, v_opening, v_old, v_current, v_late
  from private.installment_ledger(p_student_id, null) l
  where l.pending_amount > 0
    and (l.session_label = p_session_label or l.is_carry_forward)
    and (p_scope = 'old_and_current'
         or (p_scope = 'old_balance_only' and l.is_carry_forward)
         or (p_scope = 'current_year_only' and not l.is_carry_forward));

  v_active := exists (select 1 from public.student_repayment_plans where student_id = p_student_id and lifecycle = 'active');
  if v_opening <= 0 then v_errors := v_errors || 'There is nothing pending to put on a plan.'; end if;
  if coalesce(p_monthly_amount, 0) <= 0 then v_errors := v_errors || 'Enter a monthly amount greater than 0.'; end if;
  if p_first_due_date is null and (p_due_dates is null or cardinality(p_due_dates) = 0) then
    v_errors := v_errors || 'Choose the first due date.';
  end if;

  if cardinality(v_errors) = 0 then
    v_left := v_opening;
    while v_left > 0 and v_seq < 120 loop
      v_seq := v_seq + 1;
      v_amount := least(p_monthly_amount, v_left);
      v_due := coalesce(p_due_dates[v_seq], (p_first_due_date + make_interval(months => v_seq - 1))::date);
      v_schedule := v_schedule || jsonb_build_object('sequenceNo', v_seq, 'dueDate', v_due, 'amount', v_amount);
      v_left := v_left - v_amount;
    end loop;
  end if;

  return jsonb_build_object(
    'studentId', p_student_id, 'sessionLabel', p_session_label, 'scope', p_scope,
    'openingBalance', v_opening, 'oldBalanceIncluded', v_old, 'currentYearIncluded', v_current,
    'lateFeeWaived', v_late, 'installmentCount', jsonb_array_length(v_items),
    'monthlyAmount', p_monthly_amount, 'firstDueDate', coalesce(p_due_dates[1], p_first_due_date),
    'termMonths', nullif(v_seq, 0),
    'finalInstallmentAmount', (v_schedule -> -1 ->> 'amount')::integer,
    'endDate', v_schedule -> -1 ->> 'dueDate',
    'items', v_items, 'schedule', v_schedule, 'hasActivePlan', v_active,
    'errors', to_jsonb(v_errors), 'canActivate', cardinality(v_errors) = 0 and not v_active);
end $$;

create or replace function public.preview_student_repayment_plan(
  p_student_id uuid, p_session_label text, p_scope text, p_monthly_amount integer, p_first_due_date date
)
returns jsonb language plpgsql stable security definer set search_path to 'public', 'private' as $$
begin
  perform private.require_permission('fees:view', 'You do not have permission to view fees.');
  return private.repayment_plan_build(p_student_id, p_session_label, p_scope, p_monthly_amount, p_first_due_date, null);
end $$;

create or replace function private.repayment_plan_activate(
  p_student_id uuid, p_session_label text, p_scope text, p_monthly_amount integer, p_first_due_date date,
  p_reason text, p_due_dates date[], p_supersedes uuid
)
returns uuid language plpgsql security definer set search_path to 'public', 'private' as $$
declare
  v_preview jsonb;
  v_plan uuid;
  v_label text;
  r jsonb;
begin
  v_preview := private.repayment_plan_build(p_student_id, p_session_label, p_scope, p_monthly_amount, p_first_due_date, p_due_dates);
  if jsonb_array_length(v_preview -> 'errors') > 0 then
    raise exception '%', v_preview -> 'errors' ->> 0;
  end if;
  select coalesce(u.full_name, sp.display_name) into v_label
  from (select auth.uid() as id) me
  left join public.users u on u.id = me.id
  left join vppsone.staff_profiles sp on sp.user_id = me.id;

  insert into public.student_repayment_plans (student_id, session_label, scope, lifecycle, opening_balance, monthly_amount,
           term_months, first_due_date, end_date, final_installment_amount, reason, waived_late_fee_total,
           activated_by, activated_by_label, supersedes_plan_id)
  values (p_student_id, p_session_label, p_scope, 'active', (v_preview ->> 'openingBalance')::integer, p_monthly_amount,
          coalesce((v_preview ->> 'termMonths')::integer, 1), (v_preview ->> 'firstDueDate')::date, (v_preview ->> 'endDate')::date,
          coalesce((v_preview ->> 'finalInstallmentAmount')::integer, 0), p_reason, (v_preview ->> 'lateFeeWaived')::integer,
          auth.uid(), v_label, p_supersedes)
  returning id into v_plan;

  for r in select * from jsonb_array_elements(v_preview -> 'items') loop
    insert into public.student_repayment_plan_items (plan_id, student_id, installment_id, installment_no, installment_label,
             due_date, is_carry_forward, snapshot_base_charge, included_base_balance, waived_late_fee)
    values (v_plan, p_student_id, (r ->> 'installmentId')::uuid, (r ->> 'installmentNo')::integer, r ->> 'installmentLabel',
            (r ->> 'dueDate')::date, (r ->> 'isCarryForward')::boolean, (r ->> 'baseCharge')::integer,
            (r ->> 'includedBaseBalance')::integer, (r ->> 'chargedLateFee')::integer);
    if (r ->> 'chargedLateFee')::integer > 0 then
      insert into public.student_late_fee_waivers (student_id, installment_id, session_label, amount, reason, source, waived_at, waived_by_label)
      values (p_student_id, (r ->> 'installmentId')::uuid, p_session_label, (r ->> 'chargedLateFee')::integer,
              'Waived when the EMI plan started', 'repayment_plan', now(), v_label);
    end if;
  end loop;
  for r in select * from jsonb_array_elements(v_preview -> 'schedule') loop
    insert into public.student_repayment_schedule (plan_id, sequence_no, due_date, amount)
    values (v_plan, (r ->> 'sequenceNo')::integer, (r ->> 'dueDate')::date, (r ->> 'amount')::integer);
  end loop;
  return v_plan;
end $$;

create or replace function public.create_student_repayment_plan(
  p_student_id uuid, p_session_label text, p_scope text, p_monthly_amount integer, p_first_due_date date,
  p_reason text, p_expected_opening_balance integer default null, p_client_request_id uuid default null,
  p_supersedes_plan_id uuid default null, p_due_dates date[] default null
)
returns uuid language plpgsql security definer set search_path to 'public', 'private' as $$
declare v_preview jsonb;
begin
  perform private.require_permission('fees:repayment_plan', 'Only an admin can start an EMI plan.');
  perform pg_advisory_xact_lock(hashtextextended(p_student_id::text, 0));
  if exists (select 1 from public.student_repayment_plans where student_id = p_student_id and lifecycle = 'active') then
    raise exception 'This student already has an active EMI plan.';
  end if;
  v_preview := private.repayment_plan_build(p_student_id, p_session_label, p_scope, p_monthly_amount, p_first_due_date, p_due_dates);
  if p_expected_opening_balance is not null and (v_preview ->> 'openingBalance')::integer <> p_expected_opening_balance then
    raise exception 'The balance changed since the preview (now Rs %). Preview the plan again.', v_preview ->> 'openingBalance';
  end if;
  return private.repayment_plan_activate(p_student_id, p_session_label, p_scope, p_monthly_amount, p_first_due_date,
                                         p_reason, p_due_dates, p_supersedes_plan_id);
end $$;

create or replace function public.reschedule_student_repayment_plan(
  p_plan_id uuid, p_monthly_amount integer, p_first_due_date date, p_reason text,
  p_expected_remaining_balance integer default null, p_client_request_id uuid default null, p_due_dates date[] default null
)
returns uuid language plpgsql security definer set search_path to 'public', 'private' as $$
declare v_plan public.student_repayment_plans%rowtype; v_new uuid; v_remaining integer;
begin
  perform private.require_permission('fees:repayment_plan', 'Only an admin can reschedule an EMI plan.');
  select * into v_plan from public.student_repayment_plans where id = p_plan_id for update;
  if not found or v_plan.lifecycle <> 'active' then raise exception 'This EMI plan is not active.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_plan.student_id::text, 0));
  select remaining_balance into v_remaining from public.v_student_repayment_plan_status where plan_id = p_plan_id;
  if p_expected_remaining_balance is not null and v_remaining <> p_expected_remaining_balance then
    raise exception 'The balance changed since the preview (now Rs %). Preview the plan again.', v_remaining;
  end if;
  update public.student_repayment_plans set lifecycle = 'superseded' where id = p_plan_id;
  v_new := private.repayment_plan_activate(v_plan.student_id, v_plan.session_label, v_plan.scope, p_monthly_amount,
                                           p_first_due_date, p_reason, p_due_dates, p_plan_id);
  update public.student_repayment_plans set superseded_by_plan_id = v_new where id = p_plan_id;
  return v_new;
end $$;

create or replace function public.cancel_student_repayment_plan(p_plan_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public', 'private' as $$
declare v_plan public.student_repayment_plans%rowtype; v_remaining integer; v_waivers integer;
begin
  perform private.require_permission('fees:repayment_plan', 'Only an admin can cancel an EMI plan.');
  select * into v_plan from public.student_repayment_plans where id = p_plan_id for update;
  if not found or v_plan.lifecycle <> 'active' then raise exception 'This EMI plan is not active.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required to cancel an EMI plan.'; end if;
  select remaining_balance into v_remaining from public.v_student_repayment_plan_status where plan_id = p_plan_id;
  select count(*) into v_waivers from public.student_late_fee_waivers
   where student_id = v_plan.student_id and source = 'repayment_plan' and voided_at is null;
  update public.student_repayment_plans
     set lifecycle = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
   where id = p_plan_id;
  return jsonb_build_object('remainingBalance', coalesce(v_remaining, 0), 'lateFeeWaiversKept', coalesce(v_waivers, 0));
end $$;

-- ------------------------------------------------------------- sessions
create or replace function public.delete_academic_session_safe(p_session_id uuid)
returns void language plpgsql security definer set search_path to 'public', 'private' as $$
declare v_session public.academic_sessions%rowtype;
begin
  perform private.require_permission('settings:write', 'Only an admin can delete a session.');
  select * into v_session from public.academic_sessions where id = p_session_id for update;
  if not found then raise exception 'Session not found.'; end if;
  if v_session.created_at < now() - interval '30 days' then
    raise exception 'Only a session created in the last 30 days can be deleted.';
  end if;
  if exists (select 1 from public.receipts r join public.students s on s.id = r.student_id
             join public.classes c on c.id = s.class_id where c.session_label = v_session.session_label) then
    raise exception 'This session has receipts, so it cannot be deleted.';
  end if;
  delete from public.installments i using public.classes c where c.id = i.class_id and c.session_label = v_session.session_label;
  delete from public.students s using public.classes c where c.id = s.class_id and c.session_label = v_session.session_label
    and not exists (select 1 from public.receipts r where r.student_id = s.id);
  delete from public.classes where session_label = v_session.session_label
    and not exists (select 1 from public.students s where s.class_id = classes.id);
  delete from public.fee_policy_configs where academic_session_label = v_session.session_label;
  delete from public.academic_sessions where id = p_session_id;
end $$;

-- Students imported in the last day into a class of another session move to
-- the same class in the active session.
create or replace function public.realign_recent_import_students_to_active_session(p_run_by uuid default null)
returns table (moved_count integer, attention_count integer, moved_student_ids uuid[])
language plpgsql security definer set search_path to 'public', 'private' as $$
declare
  v_active text;
  v_moved uuid[] := '{}';
  v_attention integer := 0;
  r record;
  v_target uuid;
begin
  perform private.require_permission('students:write', 'You do not have permission to move students.');
  select coalesce(
    (select nullif(btrim(value), '') from public.app_settings where key = 'active_session_label'),
    (select session_label from public.academic_sessions where is_current order by created_at desc limit 1)
  ) into v_active;
  if v_active is null then raise exception 'No active session is set.'; end if;
  for r in
    select s.id, c.class_name, c.section, c.stream_name
    from public.students s join public.classes c on c.id = s.class_id
    where c.session_label <> v_active and s.created_at > now() - interval '1 day'
  loop
    select c2.id into v_target from public.classes c2
     where c2.session_label = v_active and c2.class_name = r.class_name
       and coalesce(c2.section, '') = coalesce(r.section, '') and coalesce(c2.stream_name, '') = coalesce(r.stream_name, '')
     limit 1;
    if v_target is null or exists (select 1 from public.receipts where student_id = r.id) then
      v_attention := v_attention + 1;
    else
      update public.students set class_id = v_target where id = r.id;
      v_moved := v_moved || r.id;
    end if;
  end loop;
  return query select cardinality(v_moved), v_attention, v_moved;
end $$;

-- ------------------------------------------------------------- grants
do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
