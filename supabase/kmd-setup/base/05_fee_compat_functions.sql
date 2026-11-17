-- ============================================================================
-- KMD One — the rest of the original fee database's functions, so every
-- migration that names them (grants, guards) finds them with the exact same
-- signature. The list comes from fee-migration 20261030200000.
-- ============================================================================

create type public.student_status as enum ('active', 'inactive', 'left', 'graduated');
alter table public.users add column if not exists preferred_locale text;

-- ---------------------------------------------------------------- trigger helpers
-- Kept for the grant list; KMD's tables use private.write_audit_log.
create or replace function private.capture_audit_event() returns trigger language plpgsql as $$
begin
  return coalesce(new, old);
end $$;

create or replace function private.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create or replace function private.set_created_by_column() returns trigger language plpgsql as $$
begin new.created_by := coalesce(new.created_by, auth.uid()); return new; end $$;
create or replace function private.set_actor_columns() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, auth.uid()); end if;
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end $$;

-- Append-only money records.
create or replace function private.prevent_append_only_mutation() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only; post a correcting entry instead', tg_table_name using errcode = 'P0001';
end $$;
create or replace function private.prevent_receipt_adjustment_mutation() returns trigger language plpgsql as $$
begin
  raise exception 'Receipt adjustments are append-only; post a correcting entry instead' using errcode = 'P0001';
end $$;
create or replace function private.protect_receipt_money_columns() returns trigger language plpgsql as $$
begin
  if new.receipt_number is distinct from old.receipt_number or new.student_id is distinct from old.student_id
     or new.payment_date is distinct from old.payment_date or new.payment_mode is distinct from old.payment_mode
     or new.total_amount is distinct from old.total_amount then
    raise exception 'A receipt''s number, student, date, mode and amount cannot be changed; reverse it instead' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger receipts_protect_money before update on public.receipts for each row execute function private.protect_receipt_money_columns();
create trigger payments_append_only before update on public.payments for each row execute function private.prevent_append_only_mutation();
create trigger payment_adjustments_append_only before update or delete on public.payment_adjustments for each row execute function private.prevent_append_only_mutation();
create trigger receipt_adjustments_append_only before update or delete on public.receipt_adjustments for each row execute function private.prevent_receipt_adjustment_mutation();

-- At most two active conventional discounts per student and session.
create or replace function private.enforce_max_active_conventional_discounts() returns trigger language plpgsql as $$
begin
  if coalesce(new.is_active, true) and (
    select count(*) from public.student_conventional_discount_assignments a
    where a.student_id = new.student_id and a.academic_session_label = new.academic_session_label
      and coalesce(a.is_active, true) and a.id <> new.id) >= 2 then
    raise exception 'A student can have at most two active discount policies in a session.';
  end if;
  return new;
end $$;
create or replace function private.enforce_max_active_conventional_discounts_in_schema() returns trigger language plpgsql as $$
begin return new; end $$;
create trigger student_conventional_discount_assignments_max before insert or update on public.student_conventional_discount_assignments
  for each row execute function private.enforce_max_active_conventional_discounts();

create or replace function private.normalize_staff_role(p_role text) returns public.staff_role language sql immutable as $$
  select case lower(btrim(coalesce(p_role, '')))
    when 'read_only_staff' then 'view_only'::public.staff_role
    when 'defaulter_followup' then 'fee_collector'::public.staff_role
    when '' then 'view_only'::public.staff_role
    else lower(btrim(p_role))::public.staff_role end
$$;

create or replace function private.normalize_workbook_class_label(p_class_name text, p_section text) returns text language sql immutable as $$
  select upper(regexp_replace(btrim(concat_ws(' ', p_class_name, nullif(btrim(coalesce(p_section, '')), ''))), '\s+', ' ', 'g'))
$$;

-- The fee app made a staff profile for every new auth user; One deliberately
-- does not (D-355). Kept as a no-op for the grant list; never attached.
create or replace function private.sync_staff_profile_from_auth_user() returns trigger language plpgsql as $$
begin return new; end $$;

-- The old school's data-migration chunk loader. Not used by KMD.
create or replace function private.vpps_apply_chunk(p_table text, p_rows jsonb) returns integer language plpgsql as $$
begin raise exception 'Not available in KMD One.'; end $$;
create or replace function public.vpps_apply_chunk_proxy(p_table text, p_rows jsonb) returns integer language plpgsql as $$
begin raise exception 'Not available in KMD One.'; end $$;

-- ---------------------------------------------------------------- small public helpers
create or replace function public.active_session_label() returns text language sql stable security definer
set search_path to 'public' as $$
  select coalesce(
    (select nullif(btrim(value), '') from public.app_settings where key = 'active_session_label'),
    (select session_label from public.academic_sessions where is_current order by created_at desc limit 1))
$$;

create or replace function public.has_any_permission(p_permissions text[]) returns boolean language sql stable security definer
set search_path to 'public', 'private' as $$
  select coalesce(bool_or(public.has_permission(p)), false) from unnest(p_permissions) p
$$;

create or replace function public.set_my_preferred_locale(p_locale text) returns void language plpgsql security definer
set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  update public.users set preferred_locale = p_locale where id = auth.uid();
end $$;

create or replace function public.generate_schema_snapshot() returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select jsonb_build_object('generatedAt', now(), 'tables', coalesce(jsonb_object_agg(t.table_name, t.cols), '{}'::jsonb))
  from (select table_name, jsonb_agg(column_name order by ordinal_position) as cols
        from information_schema.columns where table_schema = 'public' group by table_name) t
$$;

create or replace function public.rls_auto_enable() returns void language sql as $$ select $$;
create or replace function public.refresh_financial_materialized_views(p_concurrently boolean default true) returns void language sql as $$ select $$;
create or replace function public.trigger_refresh_financial_views() returns trigger language plpgsql as $$ begin return null; end $$;

create or replace function public.refresh_defaulter_recovery_state(p_session_label text, p_today date default current_date)
returns void language plpgsql security definer set search_path to 'public', 'vppsone' as $$
begin
  perform vppsone.refresh_defaulter_recovery_state(p_session_label, p_today);
end $$;

-- ---------------------------------------------------------------- late fee helpers
create or replace function public.void_late_fee_waiver(p_waiver_id uuid, p_reason text)
returns void language plpgsql security definer set search_path to 'public', 'private' as $$
begin
  perform private.require_permission('payments:waive_late_fee', 'You do not have permission to change late-fee waivers.');
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required.'; end if;
  update public.student_late_fee_waivers set voided_at = now(), void_reason = p_reason
   where id = p_waiver_id and voided_at is null;
  if not found then raise exception 'Waiver not found or already voided.'; end if;
end $$;

-- Late fees on installments covered by an active EMI plan are forgiven.
create or replace function public.sync_repayment_plan_late_fees(p_session_label text, p_dry_run boolean default true, p_as_of date default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'private' as $$
declare v_count integer := 0; v_amount integer := 0; r record;
begin
  perform private.require_permission('fees:repayment_plan', 'Only an admin can do this.');
  for r in
    select l.student_id, l.installment_id, l.session_label, l.late_fee_pending
    from public.student_repayment_plans p
    join public.student_repayment_plan_items i on i.plan_id = p.id
    cross join lateral private.installment_ledger(p.student_id, p_as_of) l
    where p.lifecycle = 'active' and p.session_label = p_session_label
      and l.installment_id = i.installment_id and l.late_fee_pending > 0
  loop
    v_count := v_count + 1; v_amount := v_amount + r.late_fee_pending;
    if not coalesce(p_dry_run, true) then
      insert into public.student_late_fee_waivers (student_id, installment_id, session_label, amount, reason, source, waived_at)
      values (r.student_id, r.installment_id, r.session_label, r.late_fee_pending, 'Covered by the EMI plan', 'repayment_plan', now());
    end if;
  end loop;
  return jsonb_build_object('rows', v_count, 'amount', v_amount, 'dryRun', coalesce(p_dry_run, true));
end $$;

-- ---------------------------------------------------------------- not used by KMD One
-- The fee app's row-by-row import and its corrected-payment RPC. The app's own
-- import screens and Payment Desk do this work; these refuse so nothing
-- reaches them by accident.
create or replace function public.import_student_batch_row(
  p_batch_id uuid, p_row_index integer, p_full_name text, p_class_id uuid, p_admission_no text, p_date_of_birth date,
  p_father_name text, p_mother_name text, p_father_phone text, p_mother_phone text, p_address text,
  p_transport_route_id uuid, p_status public.student_status, p_student_type text,
  p_tuition_fee integer, p_transport_fee integer, p_books_fee integer, p_misc_fee integer, p_other_fee_heads jsonb,
  p_discount_amount integer, p_late_fee_waiver integer, p_notes text, p_dry_run boolean
) returns uuid language plpgsql as $$
begin
  raise exception 'Use the Students import screen.';
end $$;
create or replace function public.import_student_batch_row(
  p_batch_id uuid, p_row_index integer, p_full_name text, p_class_id uuid, p_admission_no text, p_date_of_birth date,
  p_father_name text, p_mother_name text, p_father_phone text, p_mother_phone text, p_address text,
  p_transport_route_id uuid, p_status public.student_status, p_student_type text,
  p_tuition_fee integer, p_transport_fee integer, p_books_fee integer, p_misc_fee integer, p_other_fee_heads jsonb,
  p_discount_amount integer, p_late_fee_waiver integer, p_notes text, p_dry_run boolean,
  p_other_adjustment_head text, p_other_adjustment_amount integer, p_custom_late_fee integer
) returns uuid language plpgsql as $$
begin
  raise exception 'Use the Students import screen.';
end $$;

create or replace function public.post_corrected_payment(
  p_student_id uuid, p_payment_date date, p_payment_mode payment_mode, p_allocations jsonb, p_client_request_id uuid,
  p_reference_number text, p_remarks text, p_received_by text, p_receipt_prefix text
) returns table (receipt_id uuid, receipt_number text, allocated_total integer) language plpgsql as $$
begin
  raise exception 'Use the Payment Desk to post a payment.';
end $$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prokind = 'f'
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
