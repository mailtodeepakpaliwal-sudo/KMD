-- ============================================================================
-- KMD One — fee base: keys, links, defaults and the permission helpers.
-- ============================================================================

-- ---------------------------------------------------------------- settings
alter table public.app_settings drop column id;
alter table public.app_settings alter column key set not null;
alter table public.app_settings add primary key (key);
alter table public.app_settings add column if not exists description text;
alter table public.app_settings add column if not exists updated_at timestamptz not null default now();
alter table public.app_settings add column if not exists updated_by uuid;

-- ---------------------------------------------------------------- people
alter table public.users add constraint users_id_fkey foreign key (id) references auth.users(id) on delete cascade;
alter table public.users alter column id drop default;
alter table public.users alter column is_active set default true;
alter table public.users alter column role set default 'view_only';
alter table public.users add column if not exists email text;

-- ---------------------------------------------------------------- sessions and classes
alter table public.academic_sessions alter column session_label set not null;
create unique index academic_sessions_session_label_key on public.academic_sessions (session_label);
alter table public.academic_sessions alter column is_current set default false;
alter table public.academic_sessions alter column status set default 'active';

alter table public.classes alter column status set default 'active';
alter table public.classes alter column sort_order set default 0;
alter table public.classes alter column session_label set not null;
alter table public.classes alter column class_name set not null;
create unique index classes_session_name_section_stream_key
  on public.classes (session_label, class_name, coalesce(section, ''), coalesce(stream_name, ''));

alter table public.transport_routes alter column is_active set default true;
alter table public.transport_routes alter column default_installment_amount set default 0;

-- ---------------------------------------------------------------- students
alter table public.students alter column status set default 'active';
alter table public.students alter column full_name set not null;
alter table public.students add constraint students_class_id_fkey foreign key (class_id) references public.classes(id);
alter table public.students add constraint students_transport_route_id_fkey foreign key (transport_route_id) references public.transport_routes(id);
create index students_class_id_idx on public.students (class_id);
create index students_admission_no_idx on public.students (admission_no);
alter table public.students add column if not exists created_by uuid;
alter table public.students add column if not exists updated_by uuid;
alter table public.students add column if not exists father_phone text;
alter table public.students add column if not exists mother_phone text;
alter table public.students add column if not exists student_type text default 'existing';
alter table public.students add column if not exists category text;
alter table public.students add column if not exists record_status text not null default 'active';

-- ---------------------------------------------------------------- fee setup
alter table public.fee_settings add constraint fee_settings_class_id_fkey foreign key (class_id) references public.classes(id) on delete cascade;
alter table public.fee_settings alter column is_active set default true;
alter table public.fee_settings alter column installment_count set default 4;
alter table public.fee_settings alter column late_fee_flat_amount set default 0;
alter table public.fee_settings alter column other_fee_heads set default '{}'::jsonb;
alter table public.fee_settings alter column tuition_fee_amount set default 0;
alter table public.fee_settings alter column transport_fee_amount set default 0;
alter table public.fee_settings alter column books_fee_amount set default 0;
alter table public.fee_settings alter column admission_activity_misc_fee_amount set default 0;
alter table public.fee_settings alter column annual_base_amount set default 0;

alter table public.fee_policy_configs alter column receipt_prefix set default 'KMD';
alter table public.fee_policy_configs alter column calculation_model set default 'workbook_v1';
alter table public.fee_policy_configs alter column is_active set default true;
alter table public.fee_policy_configs alter column late_fee_flat_amount set default 0;
alter table public.fee_policy_configs alter column installment_schedule set default '[]'::jsonb;
alter table public.fee_policy_configs alter column custom_fee_heads set default '[]'::jsonb;
alter table public.fee_policy_configs alter column accepted_payment_modes set default '["cash","upi","bank_transfer","cheque"]'::jsonb;
create unique index fee_policy_configs_session_key on public.fee_policy_configs (academic_session_label);
alter table public.fee_policy_configs add constraint fee_policy_configs_receipt_prefix_check
  check (receipt_prefix ~ '^[A-Z0-9][A-Z0-9-]{1,11}$');

alter table public.student_fee_overrides add constraint student_fee_overrides_student_id_fkey foreign key (student_id) references public.students(id) on delete cascade;
alter table public.student_fee_overrides alter column is_active set default true;
alter table public.student_fee_overrides alter column discount_amount set default 0;
alter table public.student_fee_overrides alter column late_fee_waiver_amount set default 0;

-- ---------------------------------------------------------------- ledger
alter table public.installments add constraint installments_student_id_fkey foreign key (student_id) references public.students(id) on delete cascade;
alter table public.installments add constraint installments_class_id_fkey foreign key (class_id) references public.classes(id);
alter table public.installments alter column status set default 'scheduled';
alter table public.installments alter column discount_amount set default 0;
alter table public.installments alter column transport_amount set default 0;
alter table public.installments alter column base_amount set default 0;
alter table public.installments alter column amount_due set default 0;
alter table public.installments alter column late_fee_flat_amount set default 0;
alter table public.installments alter column is_carry_forward set default false;
alter table public.installments alter column is_emi_late_fee set default false;
create index installments_student_id_idx on public.installments (student_id);

alter table public.receipts add constraint receipts_student_id_fkey foreign key (student_id) references public.students(id);
alter table public.receipts alter column receipt_number set not null;
create unique index receipts_receipt_number_key on public.receipts (receipt_number);
create unique index receipts_student_client_request_id_unique on public.receipts (student_id, client_request_id) where client_request_id is not null;
create index receipts_student_id_idx on public.receipts (student_id);
create index receipts_payment_date_idx on public.receipts (payment_date);
alter table public.receipts add column if not exists session_label text;

alter table public.payments add constraint payments_receipt_id_fkey foreign key (receipt_id) references public.receipts(id);
alter table public.payments add constraint payments_installment_id_fkey foreign key (installment_id) references public.installments(id);
alter table public.payments add constraint payments_student_id_fkey foreign key (student_id) references public.students(id);
create index payments_receipt_id_idx on public.payments (receipt_id);
create index payments_installment_id_idx on public.payments (installment_id);
alter table public.payments alter column discount_applied_at_posting set default 0;
alter table public.payments alter column waiver_applied_at_posting set default 0;

alter table public.payment_adjustments add constraint payment_adjustments_payment_id_fkey foreign key (payment_id) references public.payments(id);
create index payment_adjustments_payment_id_idx on public.payment_adjustments (payment_id);

alter table public.student_late_fee_waivers add constraint student_late_fee_waivers_student_id_fkey foreign key (student_id) references public.students(id) on delete cascade;
alter table public.student_late_fee_waivers add column if not exists installment_id uuid references public.installments(id) on delete cascade;
alter table public.student_late_fee_waivers add column if not exists amount integer not null default 0;
alter table public.student_late_fee_waivers add column if not exists voided_at timestamptz;
alter table public.student_late_fee_waivers add column if not exists voided_by uuid;

-- receipts and payments are append-only: corrections go through adjustments
create or replace function private.refuse_delete() returns trigger language plpgsql as $$
begin
  raise exception '% rows cannot be deleted; post a reversal or adjustment instead', tg_table_name using errcode = 'P0001';
end $$;
create trigger receipts_no_delete before delete on public.receipts for each row execute function private.refuse_delete();
create trigger payments_no_delete before delete on public.payments for each row execute function private.refuse_delete();

-- ---------------------------------------------------------------- family / contacts
alter table public.student_family_members add constraint student_family_members_student_id_fkey foreign key (student_id) references public.students(id) on delete cascade;
alter table public.student_family_members add constraint student_family_members_group_id_fkey foreign key (family_group_id) references public.student_family_groups(id) on delete cascade;

-- ---------------------------------------------------------------- touch updated_at
create or replace function private.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  for t in
    select c.table_name from information_schema.columns c
    join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.column_name = 'updated_at'
  loop
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_updated_at()', t || '_touch_updated_at', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- permissions
-- The signed-in person's fee role. A later migration
-- (20260922100000_current_staff_role_reads_vppsone) extends this to read
-- vppsone.staff_profiles as well.
create or replace function private.current_staff_role()
returns public.staff_role language sql stable security definer
set search_path to 'public', 'auth', 'private' as $$
  select u.role from public.users u where u.id = auth.uid() and u.is_active = true limit 1
$$;

create or replace function public.current_staff_role()
returns public.staff_role language sql stable security definer
set search_path to 'public', 'auth', 'private' as $$ select private.current_staff_role() $$;

-- What each role may do. Mirrors src/modules/fees/platform/roles.ts; the three
-- school-office roles read like a teacher and never handle money.
create or replace function public.role_permissions(p_role public.staff_role)
returns text[] language sql immutable as $$
  select case p_role
    when 'admin' then array[
      'dashboard:view','students:view','students:write','students:edit_basic','students:edit_sr_no',
      'fees:view','fees:write','fees:repayment_plan','payments:view','payments:write','payments:adjust',
      'payments:reverse_any','payments:bulk','payments:waive_late_fee','finance:view','finance:write',
      'finance:approve','ledger:view','receipts:view','receipts:print','defaulters:view','contacts:write',
      'imports:view','reports:view','settings:view','settings:write','staff:manage']
    when 'accountant' then array[
      'dashboard:view','students:view','fees:view','payments:view','payments:write','payments:waive_late_fee',
      'finance:view','ledger:view','receipts:view','receipts:print','defaulters:view','imports:view',
      'reports:view','settings:view']
    when 'fee_collector' then array[
      'dashboard:view','students:view','fees:view','payments:view','payments:write','finance:view',
      'ledger:view','receipts:view','receipts:print','defaulters:view','contacts:write','imports:view',
      'reports:view','settings:view']
    when 'view_only' then array['dashboard:view','students:view','defaulters:view','receipts:view']
    else array[
      'dashboard:view','students:view','students:edit_basic','fees:view','payments:view','finance:view',
      'ledger:view','receipts:view','defaulters:view','imports:view','reports:view','settings:view']
  end
$$;

create or replace function public.has_permission(p_permission text)
returns boolean language sql stable security definer
set search_path to 'public', 'auth', 'private' as $$
  select auth.uid() is not null
     and coalesce(p_permission = any (public.role_permissions(private.current_staff_role())), false)
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer
set search_path to 'public', 'auth', 'private' as $$ select private.current_staff_role() = 'admin' $$;

create or replace function public.is_staff()
returns boolean language sql stable security definer
set search_path to 'public', 'auth', 'private' as $$ select private.current_staff_role() is not null $$;

create or replace function private.ist_today()
returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------------------------------------------------------------- audit log
alter table public.audit_logs alter column created_at set default now();
create or replace function private.write_audit_log() returns trigger language plpgsql security definer
set search_path to 'public', 'private' as $$
begin
  insert into public.audit_logs (table_name, record_id, action, before_data, after_data, changed_by)
  values (tg_table_name,
          coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'id', ''),
          lower(tg_op),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
          auth.uid());
  return coalesce(new, old);
end $$;
do $$
declare t text;
begin
  foreach t in array array['students','classes','fee_settings','fee_policy_configs','student_fee_overrides',
                           'installments','receipts','payments','payment_adjustments','transport_routes','users']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.write_audit_log()', t || '_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- row level security
-- Every fee table is closed to the browser by default. Signed-in staff read
-- through their permission; writes go through security-definer functions or
-- the server's service role.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_staff())', t || ': staff read', t);
  end loop;
end $$;
revoke all on all tables in schema public from anon;

-- ---------------------------------------------------------------- columns the SQL migrations read
alter table public.defaulter_recovery_state
  add column if not exists last_resolved_contact_id uuid,
  add column if not exists promise_resolved_at timestamptz,
  add column if not exists promise_resolved_outcome text,
  add column if not exists recovery_stage text;
alter table public.receipt_adjustments
  add column if not exists installment_id uuid,
  add column if not exists notes text,
  add column if not exists reason text;
alter table public.student_repayment_receipt_links
  add column if not exists plan_balance_before integer,
  add column if not exists student_id uuid;
alter table public.whatsapp_reminder_sends
  add column if not exists last_attempt_at timestamptz;
alter table public.student_late_fee_waivers alter column source set default 'manual';
alter table public.student_late_fee_waivers add constraint student_late_fee_waivers_source_check
  check (source = any (array['manual', 'payment_desk', 'migration', 'grandfather', 'repayment_plan', 'manual_collected']));

-- Finance-side corrections recorded against a receipt (bank charges, rounding).
create table if not exists public.receipt_finance_adjustments (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid references public.receipts(id),
  student_id uuid references public.students(id),
  adjustment_type text,
  amount integer not null default 0,
  reason text,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.receipt_finance_adjustments enable row level security;
create policy "receipt_finance_adjustments: staff read" on public.receipt_finance_adjustments for select to authenticated using (public.is_staff());
alter table public.receipts add constraint receipts_id_student_id_key unique (id, student_id);

-- The WhatsApp send log's own rules (fees app 20260820140000, not in the code).
alter table public.whatsapp_reminder_sends alter column status set default 'pending';
alter table public.whatsapp_reminder_sends alter column sent_on set default ((now() at time zone 'Asia/Kolkata')::date);
alter table public.whatsapp_reminder_sends alter column notice_kind set default 'reminder';
alter table public.whatsapp_reminder_sends alter column destination_role set default 'primary';
alter table public.whatsapp_reminder_sends add constraint whatsapp_reminder_sends_status_check
  check (status = any (array['pending', 'sent', 'failed', 'covered_by_sibling']));
alter table public.whatsapp_reminder_sends add constraint whatsapp_reminder_sends_destination_role_check
  check (destination_role = any (array['primary', 'secondary']));
create unique index whatsapp_reminder_sends_reminder_day_idx
  on public.whatsapp_reminder_sends (student_id, session_label, sent_on, campaign_name, destination_role)
  where receipt_id is null and notice_kind = 'reminder';
