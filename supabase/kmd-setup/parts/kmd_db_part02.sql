-- KMD One database setup — kmd_db_part 2 of 11. Run in order, each once.
-- Files: 01_fee_tables.sql … 20260918043934_add_fee_roles_to_staff_role.sql

-- ======================================================== base/01_fee_tables.sql
-- ============================================================================
-- KMD One — fee base schema (public + private), written fresh for
-- KMD Public School, Jaipur. The original app ran next to a separate
-- "School Fees" database whose base schema was not part of the code; this
-- file recreates the tables, types and helpers the app and its migrations
-- expect, so a brand-new Supabase project can be set up from scratch.
-- ============================================================================
create schema if not exists private;
grant usage on schema private to authenticated, service_role;
create extension if not exists pgcrypto with schema extensions;

create type public.payment_mode as enum ('cash', 'upi', 'bank_transfer', 'cheque', 'discount');
create type public.staff_role as enum (
  'admin', 'accountant', 'teacher', 'fee_collector', 'view_only',
  'office', 'academic_coordinator', 'exam_coordinator'
);

create table public.academic_sessions (
  id uuid primary key default gen_random_uuid(),
  is_current boolean,
  notes text,
  session_label text,
  status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.app_settings (
  id uuid primary key default gen_random_uuid(),
  key text,
  value text
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  table_name text,
  record_id text,
  action text,
  before_data jsonb,
  after_data jsonb,
  changed_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.classes (
  id uuid primary key default gen_random_uuid(),
  session_label text,
  class_name text,
  section text,
  stream_name text,
  sort_order integer,
  status text,
  notes text,
  created_by uuid,
  updated_by uuid,
  is_active boolean,
  label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.collection_closures (
  approved_at timestamptz,
  approved_by uuid,
  bank_deposit_reference text,
  cash_deposit_status text,
  close_note text,
  closed_at timestamptz,
  closed_by uuid,
  created_by uuid,
  id uuid primary key default gen_random_uuid(),
  payment_date date,
  reconciliation_status text,
  status text,
  summary_snapshot jsonb,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.config_change_batches (
  id uuid primary key default gen_random_uuid(),
  target_ref text,
  target_label text,
  status text,
  before_payload jsonb,
  proposed_payload jsonb,
  changed_fields jsonb,
  preview_summary jsonb,
  apply_summary jsonb,
  apply_notes text,
  previewed_at timestamptz,
  applied_at timestamptz,
  created_by uuid,
  updated_by uuid,
  change_scope text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.config_change_blocked_installments (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid,
  student_id uuid,
  installment_id uuid,
  installment_label text,
  due_date date,
  amount_due integer,
  paid_amount integer,
  adjustment_amount integer,
  outstanding_amount integer,
  reason_code text,
  reason_label text,
  action_needed text,
  review_status text,
  review_notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.conventional_discount_policies (
  academic_session_label text,
  calculation_type text,
  code text,
  display_name text,
  fixed_tuition_amount integer,
  id uuid primary key default gen_random_uuid(),
  is_active boolean,
  is_builtin boolean,
  percentage text,
  sort_order integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.defaulter_contacts (
  bulk text,
  channel text,
  contacted_at timestamptz,
  contacted_phone text,
  family_group_id uuid,
  id uuid primary key default gen_random_uuid(),
  no_call text,
  note text,
  outcome text,
  phone_label text,
  promise_broken_count integer,
  promise_kept_count integer,
  reason text,
  session_label text,
  snooze_until text,
  student_id uuid,
  voice_note_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.defaulter_recovery_state (
  id uuid primary key default gen_random_uuid(),
  family_group_id uuid,
  promise_broken_count integer,
  promise_kept_count integer,
  session_label text,
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.fee_policy_configs (
  id uuid primary key default gen_random_uuid(),
  academic_session_label text,
  calculation_model text,
  installment_schedule jsonb,
  late_fee_flat_amount integer,
  new_student_academic_fee_amount integer,
  old_student_academic_fee_amount integer,
  custom_fee_heads jsonb,
  accepted_payment_modes jsonb,
  receipt_prefix text,
  notes text,
  is_active boolean,
  created_by uuid,
  updated_by uuid,
  academic_fee_distribution integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.fee_settings (
  id uuid primary key default gen_random_uuid(),
  class_id uuid,
  annual_base_amount integer,
  tuition_fee_amount integer,
  transport_fee_amount integer,
  books_fee_amount integer,
  admission_activity_misc_fee_amount integer,
  other_fee_heads jsonb,
  late_fee_flat_amount integer,
  installment_count integer,
  student_type_default text,
  transport_applies_default boolean,
  is_active boolean,
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  filename text,
  source_format text,
  worksheet_name text,
  file_size_bytes integer,
  status text,
  detected_headers jsonb,
  column_mapping jsonb,
  total_rows integer,
  valid_rows integer,
  invalid_rows integer,
  duplicate_rows integer,
  imported_rows integer,
  skipped_rows integer,
  failed_rows integer,
  summary jsonb,
  validation_completed_at timestamptz,
  import_completed_at timestamptz,
  error_message text,
  created_by uuid,
  updated_by uuid,
  import_mode text,
  target_session_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid,
  row_index integer,
  raw_payload jsonb,
  normalized_payload jsonb,
  status text,
  errors jsonb,
  warnings jsonb,
  duplicate_student_id uuid,
  imported_student_id uuid,
  imported_override_id uuid,
  created_by uuid,
  updated_by uuid,
  anomaly_categories text,
  changed_fields text,
  duplicate_audit_decision text,
  duplicate_audit_target_student_id uuid,
  import_operation text,
  review_note text,
  review_status text,
  reviewed_at timestamptz,
  target_student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.installments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid,
  class_id uuid,
  fee_setting_id uuid,
  student_fee_override_id uuid,
  installment_no integer,
  installment_label text,
  due_date date,
  base_amount integer,
  transport_amount integer,
  discount_amount integer,
  amount_due integer,
  late_fee_flat_amount integer,
  status text,
  notes text,
  created_by uuid,
  updated_by uuid,
  carry_forward_balance_id uuid,
  is_carry_forward boolean,
  is_emi_late_fee boolean,
  source_session_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ledger_regeneration_batches (
  applied_at timestamptz,
  apply_notes text,
  apply_summary jsonb,
  id uuid primary key default gen_random_uuid(),
  message text,
  policy_revision_id uuid,
  policy_revision_label text,
  preview_summary jsonb,
  reason text,
  source_snapshot jsonb,
  status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ledger_regeneration_rows (
  id uuid primary key default gen_random_uuid(),
  action_needed text,
  adjustment_amount integer,
  amount_due integer,
  balance_status integer,
  base_amount integer,
  batch_id uuid,
  class_id uuid,
  class_label text,
  discount_amount integer,
  due_date date,
  fee_setting_id uuid,
  installment_id uuid,
  installment_label text,
  installment_no integer,
  late_fee_flat_amount integer,
  outstanding_amount integer,
  paid_amount integer,
  reason_code text,
  reason_label text,
  student_fee_override_id uuid,
  student_id uuid,
  student_label text,
  transport_amount integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.office_sync_events (
  id uuid primary key default gen_random_uuid(),
  affected_student_ids text,
  entity_id uuid,
  entity_type text,
  metadata jsonb,
  session_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payment_adjustment_reviews (
  id uuid primary key default gen_random_uuid(),
  created_by uuid,
  payment_adjustment_id uuid,
  review_note text,
  review_status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payment_adjustments (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid,
  student_id uuid,
  installment_id uuid,
  adjustment_type text,
  amount_delta integer,
  reason text,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payment_import_batches (
  error_rows integer,
  file_name text,
  id uuid primary key default gen_random_uuid(),
  posted_rows integer,
  session_label text,
  source_format text,
  status text,
  total_rows integer,
  valid_rows integer,
  warning_rows integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payment_import_rows (
  admission_no text,
  amount integer,
  batch_id uuid,
  client_request_id text,
  duplicate_acknowledged text,
  existing_receipt_duplicate text,
  id uuid primary key default gen_random_uuid(),
  intra_file_duplicate text,
  payment_date date,
  payment_mode text,
  post_error text,
  posted_at timestamptz,
  receipt_id uuid,
  receipt_number text,
  remarks text,
  row_number text,
  student_id uuid,
  student_name text,
  validation_messages text,
  validation_status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid,
  student_id uuid,
  installment_id uuid,
  amount integer,
  notes text,
  created_by uuid,
  discount_applied_at_posting text,
  pending_after_posting integer,
  pending_before_posting integer,
  waiver_applied_at_posting text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.prev_year_import_batches (
  applied_at timestamptz,
  applied_row_count integer,
  applied_subtotal integer,
  apply_notes text,
  candidate_row_count integer,
  confirmed_row_count integer,
  confirmed_subtotal integer,
  file_name text,
  file_sha256 text,
  id uuid primary key default gen_random_uuid(),
  session_label text,
  source_sheet text,
  status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.prev_year_import_rows (
  applied_amount integer,
  applied_installment_id uuid,
  batch_id uuid,
  id uuid primary key default gen_random_uuid(),
  match_method text,
  matched_admission_no integer,
  matched_student_id uuid,
  owner_decision text,
  prev_year_due integer,
  row_index integer,
  skip_reason text,
  source_admission_no integer,
  source_name text,
  status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.promotion_run_entries (
  applied text,
  credit_balance integer,
  decision text,
  id uuid primary key default gen_random_uuid(),
  new_class_id uuid,
  new_status text,
  opening_credit_amount integer,
  previous_class_id uuid,
  previous_status text,
  reason text,
  run_id uuid,
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.promotion_runs (
  applied_at timestamptz,
  applied_count integer,
  credit_carry_forward_count integer,
  credit_carry_forward_total integer,
  graduated_count integer,
  id uuid primary key default gen_random_uuid(),
  notes text,
  preview_count integer,
  rolled_back_at timestamptz,
  source_session_label text,
  status text,
  target_session_label text,
  triggered_at timestamptz,
  triggered_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.receipt_adjustments (
  id uuid primary key default gen_random_uuid(),
  adjustment_type text,
  amount_delta integer,
  receipt_id uuid,
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_number text,
  student_id uuid,
  payment_date date,
  payment_mode public.payment_mode,
  total_amount integer,
  reference_number text,
  notes text,
  received_by text,
  created_by uuid,
  client_request_id text,
  write_off_note text,
  write_off_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.refund_requests (
  approval_note text,
  approved_at timestamptz,
  approved_by uuid,
  created_by uuid,
  id uuid primary key default gen_random_uuid(),
  notes text,
  processed_at timestamptz,
  processed_by uuid,
  processing_note text,
  reason text,
  receipt_id uuid,
  refund_date date,
  refund_method text,
  refund_reference text,
  requested_amount integer,
  status text,
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.school_fee_defaults (
  id uuid primary key default gen_random_uuid(),
  tuition_fee_amount integer,
  transport_fee_amount integer,
  books_fee_amount integer,
  admission_activity_misc_fee_amount integer,
  other_fee_heads jsonb,
  late_fee_flat_amount integer,
  installment_count integer,
  installment_due_dates jsonb,
  student_type_default text,
  transport_applies_default boolean,
  is_active boolean,
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.school_holidays (
  id uuid primary key default gen_random_uuid(),
  counter_open text,
  holiday_date date,
  label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.session_reconcile_log (
  attention_count integer,
  error_message text,
  finished_at timestamptz,
  id uuid primary key default gen_random_uuid(),
  locked_count integer,
  prepared_count integer,
  run_by uuid,
  session_label text,
  updated_count integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.setup_progress (
  id uuid primary key default gen_random_uuid(),
  setup_completed_at timestamptz,
  completion_notes text,
  is_active boolean,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_carry_forward_balances (
  id uuid primary key default gen_random_uuid(),
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_collection_flags (
  id uuid primary key default gen_random_uuid(),
  no_call text,
  reason text,
  session_label text,
  student_id uuid,
  whatsapp_cadence text,
  whatsapp_language text,
  whatsapp_profile text,
  whatsapp_profile_set_at timestamptz,
  whatsapp_profile_set_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_conventional_discount_assignments (
  academic_session_label text,
  applied_at timestamptz,
  applied_by uuid,
  before_tuition_amount integer,
  calculation_snapshot jsonb,
  family_group_id uuid,
  id uuid primary key default gen_random_uuid(),
  is_active boolean,
  is_manual_override boolean,
  manual_override_reason text,
  notes text,
  policy_id uuid,
  reason text,
  resulting_tuition_amount integer,
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_family_groups (
  academic_session_label text,
  family_label text,
  guardian_name text,
  guardian_phone text,
  id uuid primary key default gen_random_uuid(),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_family_members (
  academic_session_label text,
  family_group_id uuid,
  id uuid primary key default gen_random_uuid(),
  is_policy_candidate boolean,
  manual_order_override text,
  notes text,
  sibling_order text,
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_fee_overrides (
  id uuid primary key default gen_random_uuid(),
  student_id uuid,
  fee_setting_id uuid,
  custom_annual_base_amount integer,
  custom_transport_installment_amount integer,
  custom_tuition_fee_amount integer,
  custom_transport_fee_amount integer,
  custom_books_fee_amount integer,
  custom_admission_activity_misc_fee_amount integer,
  custom_other_fee_heads jsonb,
  custom_late_fee_flat_amount integer,
  other_adjustment_head text,
  other_adjustment_amount integer,
  late_fee_waiver_amount integer,
  student_type_override text,
  transport_applies_override boolean,
  discount_amount integer,
  reason text,
  is_active boolean,
  created_by uuid,
  updated_by uuid,
  custom_other_fee_head_labels integer,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_late_fee_waivers (
  id uuid primary key default gen_random_uuid(),
  amount integer,
  client_request_id text,
  installment_id uuid,
  reason text,
  session_label text,
  source text,
  student_id uuid,
  void_reason text,
  voided_at timestamptz,
  waived_at timestamptz,
  waived_by_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_repayment_emi_late_fees (
  id uuid primary key default gen_random_uuid(),
  amount integer,
  backing_installment_id uuid,
  plan_id uuid,
  sequence_no integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_repayment_plan_items (
  id uuid primary key default gen_random_uuid(),
  due_date date,
  included_base_balance integer,
  installment_id uuid,
  installment_label text,
  installment_no integer,
  is_carry_forward boolean,
  plan_id uuid,
  snapshot_base_charge integer,
  student_id uuid,
  waived_late_fee integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_repayment_receipt_links (
  id uuid primary key default gen_random_uuid(),
  contribution_amount integer,
  plan_balance_after integer,
  plan_id uuid,
  receipt_id uuid,
  spillover_amount integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_repayment_schedule (
  id uuid primary key default gen_random_uuid(),
  amount integer,
  due_date date,
  plan_id uuid,
  sequence_no integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.student_session_reanchor_log (
  id uuid primary key default gen_random_uuid(),
  student_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.students (
  address text,
  admission_no text,
  class_id uuid,
  date_of_birth date,
  email text,
  father_name text,
  full_name text,
  gender text,
  guardian_name text,
  guardian_phone text,
  house text,
  id uuid primary key default gen_random_uuid(),
  joined_on date,
  left_on date,
  mother_name text,
  notes text,
  photo_path text,
  primary_phone text,
  roll_no text,
  secondary_phone text,
  status text,
  tc_number text,
  transport_route_id uuid,
  village_city text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.transport_routes (
  id uuid primary key default gen_random_uuid(),
  route_code text,
  route_name text,
  default_installment_amount integer,
  annual_fee_amount integer,
  is_active boolean,
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_activity_events (
  id uuid primary key default gen_random_uuid(),
  kind text,
  payload jsonb,
  ref_id uuid,
  user_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.users (
  id uuid primary key default gen_random_uuid(),
  full_name text,
  role public.staff_role,
  phone text,
  is_active boolean,
  last_login_at timestamptz,
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);



create table public.whatsapp_reminder_sends (
  campaign_name text,
  delivered_at timestamptz,
  delivery_status text,
  destination text,
  destination_role text,
  document_path text,
  due_amount integer,
  error_message text,
  failure_cause text,
  id uuid primary key default gen_random_uuid(),
  last_error text,
  notice_kind text,
  pay_code text,
  pay_code_expires_on date,
  pay_scope text,
  provider_message_id text,
  read_at timestamptz,
  reason text,
  receipt_id uuid,
  resolution text,
  resolution_note text,
  resolved_at timestamptz,
  resolved_by uuid,
  run_id uuid,
  sent_by uuid,
  sent_on date,
  session_label text,
  status text,
  student_id uuid,
  template_params jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.whatsapp_test_sends (
  campaign_name text,
  error_message text,
  id uuid primary key default gen_random_uuid(),
  provider_message_id text,
  sent_by uuid,
  succeeded text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ======================================================== base/02_fee_keys_helpers.sql
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

-- ======================================================== base/02b_fee_ledger_views.sql
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

-- ======================================================== base/03_fees_app_whatsapp_originals.sql
-- The fees app's own WhatsApp campaign migrations, copied unchanged from
-- tests/fees/fixtures/fee-migrations (schoolfees @ 8a0cd47c).

-- Per-family WhatsApp reminder cadence, so the office stops re-unticking the
-- same children every single run.
--
-- The reminders list is rebuilt from the ledger on every load, which is what
-- makes "families who paid drop off" free. What was NOT persisted was the
-- office's own judgement: "this family pays eventually, don't chase them every
-- few days". So the same twenty rows got unticked by hand, daily.
--
-- Deliberately WhatsApp-scoped, and deliberately NOT `no_call`. `no_call` means
-- "don't chase this family at all" and removes them from the Defaulters call
-- queue too; the office wants to keep CALLING some of these families while
-- messaging them less often. Two different decisions, two different columns,
-- on the one table that already owns per-session collection preferences.
--
-- There is no "last reminded" column here on purpose: `whatsapp_reminder_sends`
-- already records `sent_on` for every attempt, so the gap is derived from the
-- send log and cannot drift away from what was actually sent.

alter table public.student_collection_flags
  add column if not exists whatsapp_cadence text not null default 'every_run',
  add column if not exists whatsapp_snoozed_until date;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'student_collection_flags_whatsapp_cadence_check'
  ) then
    alter table public.student_collection_flags
      add constraint student_collection_flags_whatsapp_cadence_check
      check (whatsapp_cadence in ('every_run', 'weekly', 'fortnightly', 'monthly', 'never'));
  end if;
end $$;

comment on column public.student_collection_flags.whatsapp_cadence is
  'How often this family may receive a WhatsApp fee reminder: every_run (default), '
  'weekly, fortnightly, monthly, or never. Enforced against whatsapp_reminder_sends.sent_on, '
  'so the minimum gap is measured from what was actually sent. WhatsApp only — it does '
  'NOT affect the Defaulters call queue, which reads no_call.';

comment on column public.student_collection_flags.whatsapp_snoozed_until is
  'Temporary WhatsApp skip. The family is absent from the reminder list until this date '
  'and then returns on its own, with no un-snoozing to remember. Independent of cadence.';

-- The reminder screen filters on these two, per session, for every load.
create index if not exists student_collection_flags_whatsapp_idx
  on public.student_collection_flags (session_label)
  where whatsapp_cadence <> 'every_run' or whatsapp_snoozed_until is not null;

-- IMPORTANT for anything writing this table from now on: `no_call` defaults to
-- TRUE. A row inserted just to record a WhatsApp cadence must pass
-- `no_call => false` explicitly, or setting "remind monthly" would silently
-- also stop the fee collectors calling that family. The reminder actions
-- update-then-insert for exactly this reason.
-- Saved reminder campaigns, the runs they produce, and what those runs collected.
--
-- The send log already IS the cohort record: `whatsapp_reminder_sends` holds one
-- row per family per notice per day, with the amount quoted and the params as
-- sent. 142 rows for the single run that has happened. What was missing is only
-- a grouping key and a record of what the run WAS — so this is two small tables
-- and one nullable column, not a new subsystem.
--
-- Shape follows `promotion_runs` (20260525135507): a run table with denormalised
-- counts. RLS follows `whatsapp_reminder_sends` (20260820140000): staff read,
-- service-role writes, no insert policy at all.

-- ---------------------------------------------------------------- the definition
-- Editable in place, because it is intent rather than a financial record. What
-- actually went out is snapshotted on the run.
create table if not exists public.whatsapp_campaigns (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  name text not null,
  situation text not null check (situation in ('fee_due', 'balance', 'prevyear')),
  language text not null check (language in ('hi', 'en')),
  -- The ReminderFilters snapshot, so re-running rebuilds the same audience rule
  -- against today's ledger rather than yesterday's list.
  filters jsonb not null default '{}'::jsonb,
  last_date date,
  late_fee_amount integer not null default 0 check (late_fee_amount >= 0),
  late_fee_basis text not null default 'per_installment'
    check (late_fee_basis in ('per_installment', 'per_day', 'flat', 'none')),
  archived_at timestamptz,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_label, name)
);

comment on table public.whatsapp_campaigns is
  'A saved, re-runnable reminder definition: which notice, in which language, to '
  'whom, by when, with what late fee. The audience is NEVER stored — only the '
  'filter rule — so a family who pays drops out of the next run for free.';

comment on column public.whatsapp_campaigns.late_fee_amount is
  'What the MESSAGE says a late payment costs. Deliberately not the ledger''s late '
  'fee: this is a lever for getting fees in on time, and the app does not charge '
  'it. The screen warns when the two disagree rather than refusing to send.';

comment on column public.whatsapp_campaigns.created_by is
  'Not a foreign key to auth.users, matching whatsapp_reminder_sends.sent_by — '
  'removing a staff account must not delete the record of what was sent.';

create index if not exists whatsapp_campaigns_session_idx
  on public.whatsapp_campaigns (session_label, archived_at nulls first, name);

-- --------------------------------------------------------------------- one press
-- Immutable once finished. `filters` and `late_fee_phrase` are snapshotted here
-- rather than read back through the campaign, because the campaign is editable
-- and what went out is not.
create table if not exists public.whatsapp_campaign_runs (
  id uuid primary key default gen_random_uuid(),
  -- set null, never cascade: deleting a saved campaign must not destroy the
  -- evidence that parents were messaged.
  campaign_id uuid references public.whatsapp_campaigns(id) on delete set null,
  session_label text not null,
  campaign_name text not null,
  situation text not null,
  language text not null,
  filters jsonb not null default '{}'::jsonb,
  last_date date,
  late_fee_phrase text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  started_by uuid,
  selected_count integer not null default 0,
  sent_count integer not null default 0,
  failed_count integer not null default 0,
  already_count integer not null default 0,
  money_quoted bigint not null default 0,
  created_at timestamptz not null default now()
);

comment on table public.whatsapp_campaign_runs is
  'One press of Send. The counts are denormalised because sendRemindersAction '
  'already computes them and used to throw them away.';

comment on column public.whatsapp_campaign_runs.late_fee_phrase is
  'Exactly what slot 7 carried, as text. The composed phrase, not the amount and '
  'basis it came from — a later change to the campaign must not rewrite history.';

create index if not exists whatsapp_campaign_runs_session_idx
  on public.whatsapp_campaign_runs (session_label, started_at desc);
create index if not exists whatsapp_campaign_runs_campaign_idx
  on public.whatsapp_campaign_runs (campaign_id, started_at desc);

-- ------------------------------------------------------------- the grouping key
-- Nullable on purpose. The 142 rows already logged belong to no run and are NOT
-- backfilled: inventing a run nobody pressed would be a lie in the record.
alter table public.whatsapp_reminder_sends
  add column if not exists run_id uuid
    references public.whatsapp_campaign_runs(id) on delete set null;

comment on column public.whatsapp_reminder_sends.run_id is
  'Which press of Send produced this row. Null for anything sent before runs were '
  'recorded. DELIBERATELY NOT part of the unique index: '
  '(student_id, session_label, sent_on, campaign_name) is what stops a family '
  'being sent the same notice twice in one day, and adding run_id would let a '
  'second run that same day message everyone again.';

create index if not exists whatsapp_reminder_sends_run_idx
  on public.whatsapp_reminder_sends (run_id);

-- ------------------------------------------------------------------ did it work
-- A view, not a materialized one: a handful of runs a month over hundreds of
-- rows. A matview would add a refresh path to forget, and this schema already
-- works around one two-minute staleness window.
--
-- "Paid after the reminder", never "because of it". Payments here are spiky —
-- 17 Aug posted 107 families in one batch against 2-9 on a normal day, which is
-- counter cash entered in bulk. This view cannot tell that apart from a response
-- and does not pretend to.
-- One lateral per send row. A run is one campaign on one day, and the unique
-- index guarantees at most one send per student in it, so there is nothing to
-- de-duplicate and no way to double-count.
create or replace view public.v_whatsapp_run_outcomes as
select
  run.id as run_id,
  run.campaign_id,
  run.session_label,
  run.campaign_name,
  run.situation,
  run.language,
  run.started_at,
  run.last_date,
  run.late_fee_phrase,
  count(*) filter (where s.status = 'sent') as messaged,
  count(*) filter (where s.status = 'failed') as failed,
  coalesce(sum(s.due_amount) filter (where s.status = 'sent'), 0) as money_quoted,
  count(*) filter (where s.status = 'sent' and coalesce(paid.amount_paid, 0) > 0)
    as families_paid,
  coalesce(sum(paid.amount_paid) filter (where s.status = 'sent'), 0)
    as money_collected
from public.whatsapp_campaign_runs run
left join public.whatsapp_reminder_sends s on s.run_id = run.id
left join lateral (
  select sum(r.total_amount) as amount_paid
  from public.receipts r
  where r.student_id = s.student_id
    and r.payment_date >= s.sent_on
    and (run.last_date is null or r.payment_date <= run.last_date)
    -- A discount close-out is not collection.
    and r.payment_mode <> 'discount'
    -- A fully reversed receipt never happened, as far as money is concerned.
    and not exists (
      select 1
      from public.v_receipt_reversal_totals rr
      where rr.receipt_id = r.id
        and rr.reversed_amount >= r.total_amount
    )
) paid on true
group by run.id;

comment on view public.v_whatsapp_run_outcomes is
  'Per run: who was messaged, and who paid between the send and the date the '
  'message asked for. Excludes discount close-outs and fully reversed receipts, '
  'matching the dashboard collection rule. This is correlation, not attribution.';

-- -------------------------------------------------------------------------- RLS
-- Staff read from the screen. Writes go through the service role in a server
-- action, which bypasses RLS — there is deliberately no insert or update policy,
-- so nothing running in a browser can fabricate a record of a campaign run.
--
-- `(select auth.role())` rather than the bare call: the bare one is re-evaluated
-- per row, the auth_rls_initplan pattern 20260527090443 swept out everywhere.
alter table public.whatsapp_campaigns enable row level security;
alter table public.whatsapp_campaign_runs enable row level security;

drop policy if exists "whatsapp_campaigns: staff read" on public.whatsapp_campaigns;
create policy "whatsapp_campaigns: staff read"
  on public.whatsapp_campaigns for select
  using ((select auth.role()) = 'authenticated');

drop policy if exists "whatsapp_campaign_runs: staff read" on public.whatsapp_campaign_runs;
create policy "whatsapp_campaign_runs: staff read"
  on public.whatsapp_campaign_runs for select
  using ((select auth.role()) = 'authenticated');

grant select on public.whatsapp_campaigns to authenticated;
grant select on public.whatsapp_campaign_runs to authenticated;
grant select on public.v_whatsapp_run_outcomes to authenticated;
-- Tell a parent their payment landed.
--
-- The office's most common WhatsApp message is not a reminder, it is a parent
-- asking whether the money arrived. A receipt notice answers that before it is
-- asked, and it is the only message in this system a family is pleased to get.
--
-- Sent strictly AFTER `post_student_payment_with_adjustments` has returned
-- success, outside any transaction, inside a try/catch that swallows
-- everything. A messaging failure must never fail a posting: the money is in
-- the drawer and the receipt is printed either way.

alter table public.whatsapp_reminder_sends
  add column if not exists receipt_id uuid
    references public.receipts(id) on delete set null;

comment on column public.whatsapp_reminder_sends.receipt_id is
  'The receipt this notice confirms, for a receipt notice only. Null for every '
  'reminder. `on delete set null` rather than cascade, matching campaign_id: a '
  'send row is evidence a parent was messaged, and it must outlive whatever it '
  'referred to.';

-- ONE notice per receipt, ever.
--
-- Deliberately NOT part of the day/campaign index, which is scoped to a session
-- and a day. A receipt notice is keyed to a receipt and nothing else: a second
-- posting for the same family on the same day is a second receipt and deserves
-- its own message, while a retry of the SAME receipt must never send twice.
create unique index if not exists whatsapp_reminder_sends_receipt_idx
  on public.whatsapp_reminder_sends (receipt_id)
  where receipt_id is not null;

comment on index public.whatsapp_reminder_sends_receipt_idx is
  'One receipt notice per receipt. Partial, so the millions of reminder rows '
  'carrying a null receipt_id are not in it. Claimed before the provider call '
  'like every other send, so this is what decides a race between two postings.';

-- ---------------------------------------------------------------- the switch

-- `app_settings` is the existing key/value store the active session already
-- lives in. A dedicated column on a settings table would need a settings table;
-- this needs two rows.
insert into public.app_settings (key, value)
values
  -- OFF until the template is approved AND somebody decides the school wants
  -- this. A feature that starts messaging parents the moment it deploys is not
  -- a feature, it is an incident.
  ('whatsapp_receipt_notice_enabled', 'false'),
  -- Which `_v3` campaigns an admin has confirmed are Live in AiSensy, as a JSON
  -- array of campaign names. The registry's `approved: false` is the floor: this
  -- can only turn a campaign ON, and never one the code has not written a body
  -- for, because a name with no descriptor has nothing to enable.
  ('whatsapp_campaign_approvals', '[]')
-- Explicit target: `key` is the primary key, and a bare `do nothing` would
-- silently swallow a conflict on some other constraint added later.
on conflict (key) do nothing;
-- A second receipt for the same student on the same day is a second receipt.
--
-- `data/receipt-notice.ts` inserts its claim row WITHOUT `sent_on`, so the
-- column defaults to the IST date. The day index is
--
--   unique (student_id, session_label, sent_on, campaign_name, destination_role)
--
-- and it is NOT partial, so a family paying twice in one day collides on it and
-- the code reports the 23505 as *"A notice for this receipt has already been
-- sent."* — which is untrue, and suppresses a notice for a receipt that has
-- never been announced. `20260903172053_whatsapp_receipt_notices.sql:24-27`
-- says the opposite is intended:
--
--   "a second posting for the same family on the same day is a second receipt
--    and deserves its own message"
--
-- Invisible in production only because `whatsapp_receipt_notice_enabled` is
-- still 'false'.
--
-- Two changes, and they must ship together, because the second one is what
-- makes a THIRD notice kind possible at all:
--
--   1. The day index becomes partial on reminder rows (`receipt_id is null`).
--      Reminders and `covered_by_sibling` rows are guarded exactly as before;
--      receipt-shaped notices are guarded by the receipt index alone.
--
--   2. The receipt index is re-keyed from (receipt_id) to
--      (receipt_id, notice_kind). Without this, a payment-REVERSED notice would
--      collide with the receipt notice for the same receipt and be reported as
--      a duplicate — one receipt can legitimately produce one "payment
--      received" and, later, one "payment reversed".
--
-- A pleasant consequence of (1): a fee-statement notice carries
-- `receipt_id is null`, so it inherits the day index for free. One statement per
-- family per day, no new column and no new index — which is exactly the rule a
-- staff-tapped button wants, against double-taps and two staff in two tabs.


-- `not null default` is load-bearing. A nullable notice_kind would let
-- Postgres's default NULLS DISTINCT treat two rows with the same receipt_id and
-- a null kind as different, silently deleting the "one notice per receipt, ever"
-- guarantee this index exists to provide.
alter table public.whatsapp_reminder_sends
  add column if not exists notice_kind text not null default 'reminder';

alter table public.whatsapp_reminder_sends
  drop constraint if exists whatsapp_reminder_sends_notice_kind_check;

alter table public.whatsapp_reminder_sends
  add constraint whatsapp_reminder_sends_notice_kind_check
  check (notice_kind in ('reminder', 'receipt', 'reversal', 'fee_statement'));

-- Backfill BEFORE the new index is built: every existing row carrying a
-- receipt_id is, by construction, a receipt notice.
update public.whatsapp_reminder_sends
   set notice_kind = 'receipt'
 where receipt_id is not null
   and notice_kind = 'reminder';

-- Create then drop, never the reverse: dropping first would leave a window in
-- which nothing stops a duplicate.
create unique index if not exists whatsapp_reminder_sends_receipt_kind_idx
  on public.whatsapp_reminder_sends (receipt_id, notice_kind)
  where receipt_id is not null;

drop index if exists public.whatsapp_reminder_sends_receipt_idx;

create unique index if not exists whatsapp_reminder_sends_reminder_day_idx
  on public.whatsapp_reminder_sends
  (student_id, session_label, sent_on, campaign_name, destination_role)
  where receipt_id is null;

drop index if exists public.whatsapp_reminder_sends_student_day_campaign_role_idx;

comment on column public.whatsapp_reminder_sends.notice_kind is
  'What this row announced: reminder (the campaign runner), receipt, reversal, or fee_statement. Part of the receipt uniqueness key, so one receipt may produce one receipt notice and later one reversal notice without either being reported as a duplicate.';

-- ======================================================== base/03b_whatsapp_extras.sql
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

-- ======================================================== base/04_fee_functions.sql
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

-- ======================================================== base/05_fee_compat_functions.sql
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

-- ======================================================== base/06_fee_write_policies.sql
-- ============================================================================
-- KMD One — who may write each fee table when signed in (the browser and the
-- app's signed-in server calls). Reads are open to staff (02_fee_keys_helpers);
-- writes need the permission that owns the table. The server's service role
-- is not affected by row-level security.
-- ============================================================================
do $$
declare
  rule record;
begin
  for rule in
    select * from (values
      ('students', 'students:edit_basic'), ('classes', 'students:write'), ('transport_routes', 'fees:write'),
      ('academic_sessions', 'settings:write'), ('student_family_groups', 'students:write'),
      ('student_family_members', 'students:write'), ('school_holidays', 'settings:write'),
      ('fee_settings', 'fees:write'), ('fee_policy_configs', 'fees:write'), ('school_fee_defaults', 'fees:write'),
      ('student_fee_overrides', 'fees:write'), ('installments', 'fees:write'),
      ('conventional_discount_policies', 'fees:write'), ('student_conventional_discount_assignments', 'fees:write'),
      ('student_carry_forward_balances', 'fees:write'), ('config_change_batches', 'fees:write'),
      ('config_change_blocked_installments', 'fees:write'), ('ledger_regeneration_batches', 'fees:write'),
      ('ledger_regeneration_rows', 'fees:write'), ('setup_progress', 'settings:write'),
      ('promotion_runs', 'students:write'), ('promotion_run_entries', 'students:write'),
      ('session_reconcile_log', 'fees:write'), ('student_session_reanchor_log', 'fees:write'),
      ('receipts', 'payments:write'), ('payments', 'payments:write'), ('receipt_adjustments', 'payments:write'),
      ('payment_adjustments', 'payments:adjust'), ('student_late_fee_waivers', 'payments:waive_late_fee'),
      ('student_repayment_plans', 'fees:repayment_plan'), ('student_repayment_plan_items', 'fees:repayment_plan'),
      ('student_repayment_schedule', 'fees:repayment_plan'), ('student_repayment_emi_late_fees', 'fees:repayment_plan'),
      ('student_repayment_receipt_links', 'payments:write'),
      ('refund_requests', 'finance:write'), ('collection_closures', 'finance:write'),
      ('payment_adjustment_reviews', 'finance:write'), ('receipt_finance_adjustments', 'finance:write'),
      ('defaulter_contacts', 'contacts:write'), ('defaulter_recovery_state', 'contacts:write'),
      ('student_collection_flags', 'contacts:write'),
      ('import_batches', 'students:write'), ('import_rows', 'students:write'),
      ('payment_import_batches', 'payments:bulk'), ('payment_import_rows', 'payments:bulk'),
      ('prev_year_import_batches', 'fees:write'), ('prev_year_import_rows', 'fees:write'),
      ('app_settings', 'settings:write'), ('users', 'staff:manage'),
      ('whatsapp_campaigns', 'contacts:write'), ('whatsapp_campaign_runs', 'contacts:write'),
      ('whatsapp_reminder_sends', 'contacts:write'), ('whatsapp_test_sends', 'contacts:write'),
      ('whatsapp_run_holdouts', 'contacts:write')
    ) as t(tbl, perm)
  loop
    if to_regclass('public.' || rule.tbl) is null then continue; end if;
    execute format('create policy %I on public.%I for insert to authenticated with check (public.has_permission(%L))',
                   rule.tbl || ': staff insert', rule.tbl, rule.perm);
    execute format('create policy %I on public.%I for update to authenticated using (public.has_permission(%L)) with check (public.has_permission(%L))',
                   rule.tbl || ': staff update', rule.tbl, rule.perm, rule.perm);
    execute format('create policy %I on public.%I for delete to authenticated using (public.has_permission(%L))',
                   rule.tbl || ': staff delete', rule.tbl, rule.perm);
  end loop;
end $$;

-- Anyone on the staff may add to the activity and audit trails.
create policy "audit_logs: staff insert" on public.audit_logs for insert to authenticated with check (public.is_staff());
create policy "user_activity_events: staff insert" on public.user_activity_events for insert to authenticated with check (public.is_staff());
create policy "office_sync_events: staff insert" on public.office_sync_events for insert to authenticated with check (public.is_staff());

grant insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

-- ======================================================== fee-migrations/20260525142048_nightly_backup_bucket.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20260525142048_nightly_backup_bucket.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added. Found missing on wtgx by the 30 Oct
--   schema parity check (docs/cutover/SCHEMA-PARITY.md): the bucket was there but
--   its storage.objects policy was not, because the masked replica copied tables
--   and functions and never storage policies (critique1 B1). Both statements are
--   idempotent, so re-running the bucket upsert is harmless.
-- ============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'nightly-backups',
  'nightly-backups',
  false,
  104857600, -- 100 MB ceiling per file
  array['text/csv', 'application/zip', 'application/json']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'nightly_backups: admin read'
  ) then
    create policy "nightly_backups: admin read"
      on storage.objects for select
      using (
        bucket_id = 'nightly-backups' and public.has_permission('settings:write')
      );
  end if;
end
$$;

-- ======================================================== fee-migrations/20260813170000_student_photo_storage_rls.sql
-- ============================================================================
-- VPPS One fee-migration: copy of the fees app's supabase/migrations/20260813170000_student_photo_storage_rls.sql
-- (fees main 8a0cd47c), applied to One's main database wtgxcptmucjerhufzjcf
-- through the Supabase MCP (D-338; see supabase/fee-migrations/README.md).
-- Difference from the fees app: none. The body below is byte-for-byte the fees
--   original; only this header is added. Found missing on wtgx by the 30 Oct
--   schema parity check (docs/cutover/SCHEMA-PARITY.md): wtgx still had the
--   20260525133208 "any signed-in user" policies, because the masked replica
--   copied tables and functions and never storage policies (critique1 B1).
--   On One, public.has_permission() reads private.current_staff_role(), which
--   falls back to vppsone.staff_profiles (D-191), so One's roles are judged by
--   the same permission arms as the fee app's.
-- ============================================================================
-- Scope the student-photos bucket to staff permissions.
--
-- The four policies written in 20260525133208 all read
--
--     bucket_id = 'student-photos' and auth.role() = 'authenticated'
--
-- which is not a permission check — it only asks "is this anyone at all?". Any
-- signed-in staff member could read, overwrite and DELETE every student photo
-- in the school by talking to the storage API directly. The students:view gate
-- lives in app/protected/students/photo/route.ts, and a session token goes
-- straight past it.
--
-- That mattered little while the only way to reach the uploader was the desktop
-- edit form. A phone flow makes the bucket something staff touch daily, so it
-- gets the same permission model as the records it belongs to:
--
--   read   -> students:view                      (everyone who sees the list)
--   write  -> students:write or students:edit_basic  (whoever may edit a student)
--
-- Deliberately matches who can already edit a student in the app: admin and
-- teacher can change a photo, accountant and fee_collector cannot, view_only
-- can look but not touch. public.has_permission is STABLE SECURITY DEFINER and
-- reads private.current_staff_role(), so it evaluates correctly under the
-- browser client's JWT — which is what performs the upload.

begin;

drop policy if exists "student_photos: staff read" on storage.objects;
drop policy if exists "student_photos: staff upload" on storage.objects;
drop policy if exists "student_photos: staff update" on storage.objects;
drop policy if exists "student_photos: staff delete" on storage.objects;

create policy "student_photos: staff read"
  on storage.objects for select
  using (
    bucket_id = 'student-photos'
    and public.has_permission('students:view')
  );

create policy "student_photos: staff upload"
  on storage.objects for insert
  with check (
    bucket_id = 'student-photos'
    and (
      public.has_permission('students:write')
      or public.has_permission('students:edit_basic')
    )
  );

create policy "student_photos: staff update"
  on storage.objects for update
  using (
    bucket_id = 'student-photos'
    and (
      public.has_permission('students:write')
      or public.has_permission('students:edit_basic')
    )
  )
  with check (
    bucket_id = 'student-photos'
    and (
      public.has_permission('students:write')
      or public.has_permission('students:edit_basic')
    )
  );

-- Replacing a photo deletes the object it replaced, so delete follows write
-- rather than being admin-only.
create policy "student_photos: staff delete"
  on storage.objects for delete
  using (
    bucket_id = 'student-photos'
    and (
      public.has_permission('students:write')
      or public.has_permission('students:edit_basic')
    )
  );

commit;

-- ======================================================== migrations/20260916191746_create_vppsone_schema.sql
-- VPPS One — the schema everything this app owns lives in.
--
-- Rule 1 of CLAUDE.md: nothing VPPS One creates may land in `public`, which
-- belongs to the fee app. Creating one new schema is what makes the cutover
-- additive by construction — it adds nothing to `public`, touches no fee
-- table, and could be dropped whole if it ever had to be (PLAN §2, D-4).
--
-- Applied to schoolfees-dev (wtgxcptmucjerhufzjcf) through the Supabase MCP.
-- `supabase db push` is not usable on this database; see docs/SETUP.md.

create schema if not exists vppsone;

comment on schema vppsone is
  'VPPS One. Everything this app owns. `public` belongs to the fee app and is SELECT-only from here.';

-- `anon` is deliberately absent: nothing in VPPS One is readable signed out.
-- Phase 5 adds parent-facing token links, and those will be served by route
-- handlers using the service-role client, not by an anonymous PostgREST read.
grant usage on schema vppsone to authenticated, service_role;

-- Reads for signed-in staff are still filtered by each table's RLS policies;
-- this grant only makes the tables visible to the role at all. Writes go
-- through server actions on the service-role client, which bypasses RLS after
-- the action has checked the permission itself.
alter default privileges in schema vppsone
  grant select on tables to authenticated;

alter default privileges in schema vppsone
  grant all on tables to service_role;

alter default privileges in schema vppsone
  grant all on sequences to service_role;

alter default privileges in schema vppsone
  grant usage, select on sequences to authenticated;

-- Every table in this schema carries `updated_at`; this keeps it honest
-- without each write remembering to.
create or replace function vppsone.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function vppsone.set_updated_at() is
  'BEFORE UPDATE trigger: stamps updated_at = now(). Attach to every vppsone table that has the column.';

-- ======================================================== migrations/20260916191757_create_staff_profiles.sql
-- VPPS One — staff roles and staff profiles.
--
-- A staff profile is not an account. `user_id` is nullable because not every
-- staff member signs in: the timetable needs a row for every teacher on it,
-- including the ones who will never open the app. Accounts are created by an
-- admin in Supabase Auth; this table only says who a signed-in account is and
-- what they may do (D-6 — the role comes from here, never public.users.role).

create type vppsone.staff_role as enum (
  'admin',
  'office',
  'academic_coordinator',
  'exam_coordinator',
  'teacher',
  'view_only'
);

comment on type vppsone.staff_role is
  'VPPS One roles (PLAN §3). Unrelated to the fee app''s public.users.role — a person can be an accountant there and a class teacher here.';

create table vppsone.staff_profiles (
  id uuid primary key default gen_random_uuid(),

  -- ON DELETE SET NULL, not CASCADE: deleting an auth user must not take the
  -- timetable's join key with it. The profile survives, unlinked.
  user_id uuid unique references auth.users (id) on delete set null,

  display_name text not null,

  -- The timetable's join key. Immutable once set — enforced by the trigger
  -- below, because a rename here silently orphans every slot that named it.
  short_name text not null,

  role vppsone.staff_role not null default 'view_only',

  phone text,
  whatsapp_phone text,

  is_teaching boolean not null default false,
  is_active boolean not null default true,

  -- The app is Hindi-first; 'en' is the opt-out.
  preferred_language text not null default 'hi',

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint staff_profiles_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint staff_profiles_short_name_trimmed
    check (short_name = btrim(short_name) and short_name <> ''),
  constraint staff_profiles_preferred_language_known
    check (preferred_language in ('hi', 'en'))
);

comment on table vppsone.staff_profiles is
  'Who a staff member is and what they may do. Not an account — user_id is nullable so non-users (teachers on the timetable) still have a row.';
comment on column vppsone.staff_profiles.short_name is
  'The timetable''s join key (e.g. the initials a slot names). Unique case-insensitively, and immutable once the row exists.';
comment on column vppsone.staff_profiles.user_id is
  'The auth.users row that signs in as this person, or NULL if they never sign in.';

-- Case-insensitive, because "RKS" and "rks" are the same teacher to everyone
-- except a unique constraint. This is the timetable's join key, so a
-- case-variant duplicate is a silently wrong import, not a cosmetic problem.
create unique index staff_profiles_short_name_unique_ci
  on vppsone.staff_profiles (lower(short_name));

-- The two reads the app actually makes: "who is this signed-in user" (covered
-- by the unique constraint on user_id) and "list the active teaching staff".
create index staff_profiles_active_teaching_idx
  on vppsone.staff_profiles (is_active, is_teaching)
  where is_active;

create trigger staff_profiles_set_updated_at
  before update on vppsone.staff_profiles
  for each row
  execute function vppsone.set_updated_at();

-- short_name immutability, in the database rather than only in the form that
-- happens to be the current way in. A server action can be rewritten; this
-- cannot be forgotten.
create or replace function vppsone.staff_profiles_short_name_is_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.short_name is distinct from old.short_name then
    raise exception
      'short_name is immutable (% -> %). It is the timetable''s join key; create a new profile instead.',
      old.short_name, new.short_name
      using errcode = 'restrict_violation';
  end if;
  return new;
end;
$$;

create trigger staff_profiles_short_name_immutable
  before update on vppsone.staff_profiles
  for each row
  execute function vppsone.staff_profiles_short_name_is_immutable();

alter table vppsone.staff_profiles enable row level security;

-- SELECT only, and no INSERT/UPDATE/DELETE policy at all. Writes go through
-- server actions that have already checked the permission and then use the
-- service-role client, which bypasses RLS. That keeps "who may write" in one
-- readable TypeScript file (src/platform/auth/permissions.ts) instead of
-- spread across policies that a role change would have to be kept in step with.
create policy staff_profiles_select_authenticated
  on vppsone.staff_profiles
  for select
  to authenticated
  using (true);

-- Explicit, because ALTER DEFAULT PRIVILEGES only covers objects created after
-- it by the same role — worth not depending on when this file is replayed
-- against the live project at cutover.
grant select on vppsone.staff_profiles to authenticated;
grant all on vppsone.staff_profiles to service_role;

-- ======================================================== migrations/20260916191935_expose_vppsone_to_postgrest.sql
-- Make the `vppsone` schema reachable from supabase-js.
--
-- PostgREST serves only the schemas it is told to. On this project that was
-- `public, graphql_public`, so every read of a vppsone table came back
--   PGRST106  Invalid schema: vppsone
-- no matter what the grants said. Creating the schema is not enough; it has to
-- be exposed as well.
--
-- This is a PostgREST setting rather than a schema object, which is why it
-- reads oddly for a migration file — but it has to be replayed at cutover
-- exactly like the CREATE SCHEMA above it, or the live app answers PGRST106 on
-- its first request. See docs/SETUP.md and PLAN §7 step 2.
--
-- It is written to be **additive**: it appends `vppsone` to whatever the role
-- already carries and never removes an entry. The fee app keeps `public`.
--
-- Safety: exposing a schema is not the same as granting access to it. `anon`
-- has no USAGE on `vppsone` (see 20260916191746), so a signed-out request gets
-- `42501 permission denied for schema vppsone`; `authenticated` gets through
-- the grant and is then filtered by each table's RLS policy.
--
-- If the project's exposed schemas were ever set from the dashboard
-- (Settings -> API -> Exposed schemas), set them there too — this role setting
-- takes precedence, so a dashboard value that disagrees is silently ignored
-- and the next person to read it will be misled.

do $$
declare
  current_schemas text;
  schema_list text[];
begin
  select option_value
    into current_schemas
    from pg_options_to_table((select rolconfig from pg_roles where rolname = 'authenticator'))
   where option_name = 'pgrst.db_schemas';

  -- Unset means PostgREST is running on the project default.
  current_schemas := coalesce(current_schemas, 'public, graphql_public');

  select array_agg(btrim(entry))
    into schema_list
    from unnest(string_to_array(current_schemas, ',')) as entry
   where btrim(entry) <> '';

  if 'vppsone' = any (schema_list) then
    raise notice 'pgrst.db_schemas already exposes vppsone (%)', current_schemas;
    return;
  end if;

  schema_list := schema_list || 'vppsone'::text;

  execute format(
    'alter role authenticator set pgrst.db_schemas = %L',
    array_to_string(schema_list, ', ')
  );

  raise notice 'pgrst.db_schemas is now %', array_to_string(schema_list, ', ');
end $$;

-- Pick up both the new config and the new tables without waiting for
-- PostgREST's own poll.
notify pgrst, 'reload config';
notify pgrst, 'reload schema';

-- ======================================================== migrations/20260916201212_create_subjects_and_class_aliases.sql
-- VPPS One — subjects, and the map from the fee app's classes to the labels
-- the timetable uses.
--
-- Both tables exist because the timetable (Phase 2) names things in the
-- school's own shorthand and the fee app names them in full. `class_aliases`
-- is the translation layer, and it is master data rather than a lookup table
-- in code because only the school knows that "11 Science" is the row a
-- timetable cell calls "11-S".

create table vppsone.subjects (
  id uuid primary key default gen_random_uuid(),

  -- What a timetable cell says: "MATHS", "SST", "HIN". Unique
  -- case-insensitively (see the index below) for the same reason a staff
  -- short name is: it is a join key, and a case-variant duplicate is a
  -- silently wrong import.
  code text not null,

  -- What a human reads. Hindi first, because the app is.
  name_hi text not null,
  name_en text not null,

  is_active boolean not null default true,
  sort_order integer not null default 0,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint subjects_code_trimmed
    check (code = btrim(code) and code <> ''),
  constraint subjects_name_hi_not_blank check (btrim(name_hi) <> ''),
  constraint subjects_name_en_not_blank check (btrim(name_en) <> '')
);

comment on table vppsone.subjects is
  'Subjects as the timetable names them. `code` is the join key a timetable cell carries.';
comment on column vppsone.subjects.code is
  'The token a timetable cell uses. Unique case-insensitively; immutable once written.';

create unique index subjects_code_unique_ci on vppsone.subjects (lower(code));
create index subjects_active_sort_idx on vppsone.subjects (sort_order, name_en) where is_active;

create trigger subjects_set_updated_at
  before update on vppsone.subjects
  for each row execute function vppsone.set_updated_at();

-- Same reasoning as staff_profiles.short_name: a code is referenced by rows
-- that already exist, so it is replaced, never renamed.
create or replace function vppsone.subjects_code_is_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.code is distinct from old.code then
    raise exception
      'subject code is immutable (% -> %). It is the timetable''s join key; create a new subject instead.',
      old.code, new.code
      using errcode = 'restrict_violation';
  end if;
  return new;
end;
$$;

create trigger subjects_code_immutable
  before update on vppsone.subjects
  for each row execute function vppsone.subjects_code_is_immutable();

alter table vppsone.subjects enable row level security;

create policy subjects_select_authenticated
  on vppsone.subjects for select to authenticated using (true);

grant select on vppsone.subjects to authenticated;
grant all on vppsone.subjects to service_role;


-- ---------------------------------------------------------------------------
-- class_aliases
-- ---------------------------------------------------------------------------

create table vppsone.class_aliases (
  id uuid primary key default gen_random_uuid(),

  -- `public.classes.id`. A plain uuid column with NO foreign key: a constraint
  -- pointing into the fee app's schema would be a write into it (rule 2, D-5).
  -- The consistency check in task 1.6 is what notices a class that has gone.
  class_id uuid not null,

  -- Denormalised from `public.classes.session_label` on purpose. The fee app's
  -- classes are per session, so an alias is too — and carrying the label here
  -- means "this year's aliases" is one index, not a join into another schema.
  session_label text not null,

  -- What a timetable cell calls this class: "11-S", "5", "NUR".
  timetable_label text not null,

  -- What the class is called in VPPS One's own screens, when the fee app's
  -- name is not the one staff say out loud. NULL means "use the fee app's".
  display_name text,

  sort_order integer not null default 0,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint class_aliases_timetable_label_trimmed
    check (timetable_label = btrim(timetable_label) and timetable_label <> ''),
  constraint class_aliases_session_label_trimmed
    check (session_label = btrim(session_label) and session_label <> '')
);

comment on table vppsone.class_aliases is
  'Maps a fee-app class row to the label the timetable uses for it. class_id has no FK into public by design (rule 2).';

-- One alias per class per session, and one class per label per session. Both
-- directions matter: two labels for one class makes the timetable ambiguous,
-- and two classes for one label makes it wrong.
create unique index class_aliases_class_per_session_unique
  on vppsone.class_aliases (class_id, session_label);

create unique index class_aliases_label_per_session_unique_ci
  on vppsone.class_aliases (session_label, lower(timetable_label));

create index class_aliases_session_sort_idx
  on vppsone.class_aliases (session_label, sort_order);

create trigger class_aliases_set_updated_at
  before update on vppsone.class_aliases
  for each row execute function vppsone.set_updated_at();

alter table vppsone.class_aliases enable row level security;

create policy class_aliases_select_authenticated
  on vppsone.class_aliases for select to authenticated using (true);

grant select on vppsone.class_aliases to authenticated;
grant all on vppsone.class_aliases to service_role;

-- ======================================================== migrations/20260916202429_staff_language_allows_bilingual.sql
-- Language is a choice each staff member makes, not a decision the app makes
-- for everyone.
--
-- The column started as `hi | en`, but every screen was written with both
-- languages side by side regardless of it — so the column was stored and never
-- read. This adds the third option and makes the column mean something:
--
--   hi    Hindi only
--   en    English only
--   both  Hindi with English beneath it — what the app used to do for everybody
--
-- The default stays `hi`: most of the teaching staff read Hindi, and an admin
-- sets anything else when they create the profile (D-35).

alter table vppsone.staff_profiles
  drop constraint staff_profiles_preferred_language_known;

alter table vppsone.staff_profiles
  add constraint staff_profiles_preferred_language_known
  check (preferred_language in ('hi', 'en', 'both'));

comment on column vppsone.staff_profiles.preferred_language is
  'Which language this staff member reads the app in: hi, en, or both (Hindi with English beneath). Per account, not per app.';

-- ======================================================== migrations/20260916204801_create_class_teachers_and_calendar.sql
-- VPPS One — class teachers (with history) and the academic calendar.

-- ---------------------------------------------------------------------------
-- class_teachers
-- ---------------------------------------------------------------------------
--
-- "With history: replaced, never edited" (PLAN §4). A class teacher changing
-- mid-year is a fact about a date, not a correction: attendance already taken,
-- notes already written and report cards already signed all belong to whoever
-- held the class then. So a change closes the current row and opens a new one.

create type vppsone.class_teacher_role as enum ('class_teacher', 'assistant');

create table vppsone.class_teachers (
  id uuid primary key default gen_random_uuid(),

  -- `public.classes.id`, with no FK: a constraint into the fee app's schema
  -- would be a write into it (rule 2, D-5).
  class_id uuid not null,
  session_label text not null,

  -- ON DELETE RESTRICT, unlike everywhere else. A staff profile that has ever
  -- been a class teacher cannot be deleted out from under this history —
  -- and it never is, because staff are deactivated rather than deleted (D-31).
  staff_profile_id uuid not null
    references vppsone.staff_profiles (id) on delete restrict,

  role vppsone.class_teacher_role not null default 'class_teacher',

  effective_from date not null default current_date,
  -- NULL means current.
  effective_to date,
  replaced_reason text,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint class_teachers_period_ordered
    check (effective_to is null or effective_to >= effective_from)
);

comment on table vppsone.class_teachers is
  'Who is class teacher of which class, with history. A change closes the old row and opens a new one; rows are never edited (PLAN §4).';
comment on column vppsone.class_teachers.effective_to is
  'NULL means current. A replacement sets this to the day before the new row starts.';

-- One *current* holder per class per role. The partial index is the whole
-- point: any number of closed rows may exist, but two open ones would mean
-- the class has two class teachers today, which is the bug this prevents.
create unique index class_teachers_one_current_per_class
  on vppsone.class_teachers (class_id, session_label, role)
  where effective_to is null;

-- "Which classes am I responsible for" — the Phase 3 teacher workspace's
-- first question.
create index class_teachers_by_staff_idx
  on vppsone.class_teachers (staff_profile_id, session_label);

create index class_teachers_session_idx
  on vppsone.class_teachers (session_label, class_id);

create trigger class_teachers_set_updated_at
  before update on vppsone.class_teachers
  for each row execute function vppsone.set_updated_at();

alter table vppsone.class_teachers enable row level security;

create policy class_teachers_select_authenticated
  on vppsone.class_teachers for select to authenticated using (true);

grant select on vppsone.class_teachers to authenticated;
grant all on vppsone.class_teachers to service_role;


-- ---------------------------------------------------------------------------
-- academic_calendar_days
-- ---------------------------------------------------------------------------
--
-- Only the days that are *not* an ordinary teaching day, plus the ones that
-- are instructional against the weekly pattern — a working Sunday before an
-- exam, say. Absence of a row means "whatever the weekly pattern says", so a
-- year needs a few dozen rows rather than 365.

create type vppsone.calendar_day_kind as enum (
  'instructional',
  'holiday',
  'exam',
  'event',
  'vacation'
);

create table vppsone.academic_calendar_days (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  day date not null,
  kind vppsone.calendar_day_kind not null,

  -- Both halves, because language is per reader (PLAN §3a). Nullable: a
  -- holiday does not always have a name worth typing.
  label_hi text,
  label_en text,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.academic_calendar_days is
  'Days that are not an ordinary teaching day, plus explicit instructional days. Absence of a row means an ordinary day decided by the weekly pattern.';

-- A day is one thing. Two rows for 15 August would make "is school open"
-- depend on which row was read first.
create unique index calendar_one_row_per_day
  on vppsone.academic_calendar_days (session_label, day);

create index calendar_session_day_idx
  on vppsone.academic_calendar_days (session_label, day);

create trigger calendar_set_updated_at
  before update on vppsone.academic_calendar_days
  for each row execute function vppsone.set_updated_at();

alter table vppsone.academic_calendar_days enable row level security;

create policy calendar_select_authenticated
  on vppsone.academic_calendar_days for select to authenticated using (true);

grant select on vppsone.academic_calendar_days to authenticated;
grant all on vppsone.academic_calendar_days to service_role;

-- ======================================================== migrations/20260916205631_create_enrolments.sql
-- VPPS One — enrolments: the academic record.
--
-- `public.students` holds where a child is **today**: one `class_id`, one
-- `status`, overwritten when they move up a year. That is what a fee app
-- needs. It is not what an academic record needs — "which class was this
-- child in when they sat that exam" has no answer in it, and by the time the
-- question is asked the row has already changed.
--
-- So VPPS One keeps its own row per child per session, built from
-- `public.students` once and then owned here. Rule 2 is why it has to be a
-- copy: the fee app's table cannot gain a column or a history table.

create type vppsone.enrolment_status as enum ('enrolled', 'left', 'promoted');

create table vppsone.enrolments (
  id uuid primary key default gen_random_uuid(),

  -- `public.students.id` and `public.classes.id`, both without a foreign key:
  -- a constraint into the fee app's schema would be a write into it
  -- (rule 2, D-5). The consistency check on /enrolments is what notices a
  -- student who has since gone.
  student_id uuid not null,
  class_id uuid not null,

  session_label text not null,

  -- Copied from the fee app at build time, editable here afterwards: a roll
  -- number is an academic fact about a year, and the fee app overwrites it.
  roll_no text,

  status vppsone.enrolment_status not null default 'enrolled',
  enrolled_on date,
  left_on date,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- A leaving date on a row that still says "enrolled" is a contradiction
  -- somebody would eventually have to resolve by guessing.
  constraint enrolments_left_on_needs_status
    check (left_on is null or status <> 'enrolled')
);

comment on table vppsone.enrolments is
  'Which child was in which class in which session. Built from public.students, which holds only today; this is the academic record that keeps history.';
comment on column vppsone.enrolments.roll_no is
  'The roll number as of this session. Copied from the fee app at build time and editable here afterwards.';

-- One row per child per session. A child cannot be in two classes in the same
-- year, and a rebuild must update rather than duplicate.
create unique index enrolments_one_per_student_per_session
  on vppsone.enrolments (student_id, session_label);

-- "Who is in this class" — the register's first query, every period of every
-- day. Partial, because a left student is not on the register.
create index enrolments_by_class_idx
  on vppsone.enrolments (session_label, class_id)
  where status = 'enrolled';

-- "Where has this child been" — the student card in task 3.5.
create index enrolments_by_student_idx
  on vppsone.enrolments (student_id);

create trigger enrolments_set_updated_at
  before update on vppsone.enrolments
  for each row execute function vppsone.set_updated_at();

alter table vppsone.enrolments enable row level security;

create policy enrolments_select_authenticated
  on vppsone.enrolments for select to authenticated using (true);

grant select on vppsone.enrolments to authenticated;
grant all on vppsone.enrolments to service_role;

-- ======================================================== migrations/20260916210606_create_timetable_versions_and_slots.sql
-- VPPS One — timetable versions, their slots, and the teaching assignments
-- regenerated from whichever version is published.

create type vppsone.timetable_status as enum ('draft', 'published', 'archived');

create table vppsone.timetable_versions (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  -- What the school calls this upload: "v11", "after Diwali", "corrected".
  label text not null,
  status vppsone.timetable_status not null default 'draft',

  -- The sheet exactly as it was pasted in. Kept so a version can be
  -- re-parsed after a parser fix without asking the office to find the file
  -- again, and so "what did we actually upload" has an answer.
  source_text text,
  notes text,

  cell_count integer not null default 0,
  slot_count integer not null default 0,

  published_at timestamptz,
  published_by uuid references auth.users (id) on delete set null,
  archived_at timestamptz,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint timetable_versions_label_not_blank check (btrim(label) <> '')
);

comment on table vppsone.timetable_versions is
  'An uploaded timetable. draft -> published -> archived. Publishing archives whatever was published before, so exactly one version is live per session.';

-- Exactly one published version per session. Any number of drafts and
-- archives may sit beside it; two published ones would make "what is the
-- timetable today" ambiguous, which is the question the whole app asks.
create unique index timetable_versions_one_published_per_session
  on vppsone.timetable_versions (session_label)
  where status = 'published';

create index timetable_versions_session_idx
  on vppsone.timetable_versions (session_label, created_at desc);

create trigger timetable_versions_set_updated_at
  before update on vppsone.timetable_versions
  for each row execute function vppsone.set_updated_at();

alter table vppsone.timetable_versions enable row level security;

create policy timetable_versions_select_authenticated
  on vppsone.timetable_versions for select to authenticated using (true);

grant select on vppsone.timetable_versions to authenticated;
grant all on vppsone.timetable_versions to service_role;


-- ---------------------------------------------------------------------------
-- timetable_slots
-- ---------------------------------------------------------------------------

create table vppsone.timetable_slots (
  id uuid primary key default gen_random_uuid(),

  -- ON DELETE CASCADE: a draft that is thrown away takes its slots with it.
  -- They are derived from `source_text` and mean nothing without the version.
  version_id uuid not null
    references vppsone.timetable_versions (id) on delete cascade,

  day text not null,
  /** 0-based, as the parser produces. */
  period smallint not null,

  -- `public.classes.id` with no FK (rule 2, D-5). `class_label` beside it is
  -- what the sheet said, kept so a slot still reads correctly if an alias is
  -- later changed.
  class_id uuid not null,
  class_label text not null,

  -- RESTRICT on both: a subject or a staff profile referenced by a published
  -- timetable cannot be deleted out from under it. Neither ever is —
  -- both are deactivated instead (D-31) — so this only catches a mistake.
  subject_id uuid not null references vppsone.subjects (id) on delete restrict,
  subject_code text not null,
  staff_profile_id uuid not null
    references vppsone.staff_profiles (id) on delete restrict,
  teacher_short_name text not null,

  -- Carried from the parser rather than re-derived: `parallel` is what
  -- decides whether an absence needs a substitute, and re-deriving it here
  -- would mean the rule living in two places.
  parallel boolean not null default false,
  shared boolean not null default false,

  created_at timestamptz not null default now(),

  constraint timetable_slots_period_in_range check (period between 0 and 15)
);

comment on table vppsone.timetable_slots is
  'One row per teacher per period per class in a version. A parallel cell produces one row per teacher; a shared cell produces one per teacher too, flagged shared.';

create index timetable_slots_by_version_idx on vppsone.timetable_slots (version_id);
-- The two views task 2.4 builds: by class, and by teacher.
create index timetable_slots_by_class_idx
  on vppsone.timetable_slots (version_id, class_id, day, period);
create index timetable_slots_by_teacher_idx
  on vppsone.timetable_slots (version_id, staff_profile_id, day, period);

alter table vppsone.timetable_slots enable row level security;

create policy timetable_slots_select_authenticated
  on vppsone.timetable_slots for select to authenticated using (true);

grant select on vppsone.timetable_slots to authenticated;
grant all on vppsone.timetable_slots to service_role;


-- ---------------------------------------------------------------------------
-- teaching_assignments
-- ---------------------------------------------------------------------------
--
-- "regenerated on every publish" (PLAN §4). Never edited by hand: it is a
-- rollup of the published version, and an edit would be a fact the timetable
-- disagrees with.

create table vppsone.teaching_assignments (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  staff_profile_id uuid not null
    references vppsone.staff_profiles (id) on delete restrict,
  class_id uuid not null,
  subject_id uuid not null references vppsone.subjects (id) on delete restrict,
  periods_per_week integer not null default 0,
  version_id uuid not null
    references vppsone.timetable_versions (id) on delete cascade,
  created_at timestamptz not null default now()
);

comment on table vppsone.teaching_assignments is
  'Who teaches what to whom, regenerated on every publish from the published version. Never edited by hand — PLAN §4 says regenerated.';

create unique index teaching_assignments_unique
  on vppsone.teaching_assignments (session_label, staff_profile_id, class_id, subject_id);

-- "Which classes do I teach" — the Phase 3 teacher workspace, and the scope
-- that makes `attendance:mark` mean *own* classes.
create index teaching_assignments_by_staff_idx
  on vppsone.teaching_assignments (staff_profile_id, session_label);

alter table vppsone.teaching_assignments enable row level security;

create policy teaching_assignments_select_authenticated
  on vppsone.teaching_assignments for select to authenticated using (true);

grant select on vppsone.teaching_assignments to authenticated;
grant all on vppsone.teaching_assignments to service_role;

-- ======================================================== migrations/20260917021218_create_attendance_and_notes.sql
-- VPPS One — attendance, corrections and notes: the teacher's day (Phase 3).

create type vppsone.attendance_status as enum ('present', 'absent', 'late', 'leave');
create type vppsone.register_status as enum ('open', 'submitted');

-- ---------------------------------------------------------------------------
-- attendance_registers
-- ---------------------------------------------------------------------------

create table vppsone.attendance_registers (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  -- `public.classes.id` with no FK (rule 2, D-5).
  class_id uuid not null,
  day date not null,

  -- NULL means the daily register the class teacher takes. A number means a
  -- subject period. The school takes one register a day today; the column is
  -- here because the timetable already knows about periods and adding it
  -- later would mean rewriting the unique index under live rows.
  period smallint,

  status vppsone.register_status not null default 'open',

  -- Who actually marked it.
  taken_by uuid references vppsone.staff_profiles (id) on delete restrict,
  submitted_at timestamptz,

  -- Set when the office marks for a teacher who could not (task 3.3). Kept
  -- separate from `taken_by` because "the office recorded this" and "the
  -- teacher recorded this" are different facts, and a register that hides
  -- which one it was cannot be audited.
  on_behalf_of uuid references vppsone.staff_profiles (id) on delete restrict,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.attendance_registers is
  'One register per class per day (period NULL = the daily register). Opened when a teacher starts marking; submitted when they finish.';

-- Two partial indexes rather than one over a nullable column: in Postgres,
-- NULLs are distinct in a unique index, so a single index on
-- (session, class, day, period) would happily allow two daily registers for
-- the same class on the same day — which is the exact duplicate this must
-- prevent.
create unique index attendance_registers_unique_daily
  on vppsone.attendance_registers (session_label, class_id, day)
  where period is null;

create unique index attendance_registers_unique_period
  on vppsone.attendance_registers (session_label, class_id, day, period)
  where period is not null;

create index attendance_registers_by_day_idx
  on vppsone.attendance_registers (session_label, day);

create index attendance_registers_by_class_idx
  on vppsone.attendance_registers (class_id, day desc);

create trigger attendance_registers_set_updated_at
  before update on vppsone.attendance_registers
  for each row execute function vppsone.set_updated_at();

alter table vppsone.attendance_registers enable row level security;
create policy attendance_registers_select_authenticated
  on vppsone.attendance_registers for select to authenticated using (true);
grant select on vppsone.attendance_registers to authenticated;
grant all on vppsone.attendance_registers to service_role;


-- ---------------------------------------------------------------------------
-- attendance_marks
-- ---------------------------------------------------------------------------

create table vppsone.attendance_marks (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null
    references vppsone.attendance_registers (id) on delete cascade,
  student_id uuid not null,
  status vppsone.attendance_status not null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.attendance_marks is
  'One mark per student per register. Upserted on (register_id, student_id), which is what makes a retried submit idempotent.';

-- The whole offline story rests on this index. A teacher on a bad connection
-- submits, sees nothing happen, and submits again; the upsert turns the second
-- attempt into the same row rather than a duplicate mark.
create unique index attendance_marks_unique
  on vppsone.attendance_marks (register_id, student_id);

create index attendance_marks_by_student_idx
  on vppsone.attendance_marks (student_id);

create trigger attendance_marks_set_updated_at
  before update on vppsone.attendance_marks
  for each row execute function vppsone.set_updated_at();

alter table vppsone.attendance_marks enable row level security;
create policy attendance_marks_select_authenticated
  on vppsone.attendance_marks for select to authenticated using (true);
grant select on vppsone.attendance_marks to authenticated;
grant all on vppsone.attendance_marks to service_role;


-- ---------------------------------------------------------------------------
-- attendance_corrections
-- ---------------------------------------------------------------------------
--
-- A submitted register is a record, not a draft. Changing a mark after the
-- fact is a request somebody approves, so the original stands until then and
-- the change carries a reason and a name.

create type vppsone.correction_status as enum ('pending', 'approved', 'rejected');

create table vppsone.attendance_corrections (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null
    references vppsone.attendance_registers (id) on delete cascade,
  student_id uuid not null,

  -- What it was, so the history reads without joining back to a mark that has
  -- since been rewritten.
  from_status vppsone.attendance_status,
  to_status vppsone.attendance_status not null,
  reason text not null,

  requested_by uuid not null
    references vppsone.staff_profiles (id) on delete restrict,
  requested_at timestamptz not null default now(),

  status vppsone.correction_status not null default 'pending',
  decided_by uuid references vppsone.staff_profiles (id) on delete restrict,
  decided_at timestamptz,
  decision_note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint corrections_reason_not_blank check (btrim(reason) <> ''),
  -- A decided request with no decision time, or a pending one that has been
  -- decided, is a row nobody can interpret later.
  constraint corrections_decided_together
    check (
      (status = 'pending' and decided_at is null)
      or (status <> 'pending' and decided_at is not null)
    )
);

comment on table vppsone.attendance_corrections is
  'A request to change a submitted mark. The mark is only rewritten when the request is approved, so the original stands until somebody decides.';

-- One open request per mark: two pending corrections for the same child would
-- make the approval queue a race.
create unique index corrections_one_pending_per_mark
  on vppsone.attendance_corrections (register_id, student_id)
  where status = 'pending';

create index corrections_pending_idx
  on vppsone.attendance_corrections (status, requested_at desc);

create trigger corrections_set_updated_at
  before update on vppsone.attendance_corrections
  for each row execute function vppsone.set_updated_at();

alter table vppsone.attendance_corrections enable row level security;
create policy corrections_select_authenticated
  on vppsone.attendance_corrections for select to authenticated using (true);
grant select on vppsone.attendance_corrections to authenticated;
grant all on vppsone.attendance_corrections to service_role;


-- ---------------------------------------------------------------------------
-- notes
-- ---------------------------------------------------------------------------

create table vppsone.note_kinds (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  label_hi text not null,
  label_en text not null,
  -- Decides the colour a screen gives it. Not a judgement about the child:
  -- "concern" means the note wants following up, not that the child is a
  -- problem.
  tone text not null default 'neutral',
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint note_kinds_code_trimmed check (code = btrim(code) and code <> ''),
  constraint note_kinds_tone_known check (tone in ('neutral', 'good', 'concern'))
);

create unique index note_kinds_code_unique_ci on vppsone.note_kinds (lower(code));

create trigger note_kinds_set_updated_at
  before update on vppsone.note_kinds
  for each row execute function vppsone.set_updated_at();

alter table vppsone.note_kinds enable row level security;
create policy note_kinds_select_authenticated
  on vppsone.note_kinds for select to authenticated using (true);
grant select on vppsone.note_kinds to authenticated;
grant all on vppsone.note_kinds to service_role;

create table vppsone.notes (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  -- One or the other, or both: a note can be about a child, about a whole
  -- class, or about a child in the context of a class.
  student_id uuid,
  class_id uuid,

  kind_id uuid not null references vppsone.note_kinds (id) on delete restrict,
  body text not null,
  written_by uuid not null
    references vppsone.staff_profiles (id) on delete restrict,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint notes_body_not_blank check (btrim(body) <> ''),
  -- A note about nobody is a note nobody will ever find again.
  constraint notes_about_somebody
    check (student_id is not null or class_id is not null)
);

comment on table vppsone.notes is
  'A note about one student or a whole class. Typed by note_kinds so a screen can filter without reading every body.';

create index notes_by_student_idx on vppsone.notes (student_id, created_at desc);
create index notes_by_class_idx on vppsone.notes (class_id, created_at desc);
create index notes_by_session_idx on vppsone.notes (session_label, created_at desc);

create trigger notes_set_updated_at
  before update on vppsone.notes
  for each row execute function vppsone.set_updated_at();

alter table vppsone.notes enable row level security;
create policy notes_select_authenticated
  on vppsone.notes for select to authenticated using (true);
grant select on vppsone.notes to authenticated;
grant all on vppsone.notes to service_role;

-- The kinds the school already uses on paper. Seeded rather than left empty,
-- because a notes screen with no kinds is a screen nobody can use, and these
-- six are not a guess — they are what the register margins say.
insert into vppsone.note_kinds (code, label_hi, label_en, tone, sort_order) values
  ('behaviour', 'व्यवहार', 'Behaviour', 'concern', 1),
  ('praise', 'शाबाशी', 'Praise', 'good', 2),
  ('homework', 'गृहकार्य', 'Homework', 'concern', 3),
  ('health', 'स्वास्थ्य', 'Health', 'neutral', 4),
  ('parent', 'अभिभावक से बात', 'Parent contact', 'neutral', 5),
  ('other', 'अन्य', 'Other', 'neutral', 9)
on conflict do nothing;

-- ======================================================== migrations/20260917025818_create_substitutions.sql
-- VPPS One — substitutions: absences, cover policies, plans (Phase 4).

create type vppsone.substitution_plan_status as enum ('draft', 'published');
create type vppsone.substitution_kind as enum ('cover', 'self_study', 'merged');
create type vppsone.substitution_source as enum ('auto', 'suggestion', 'manual');

-- Who may be asked to cover, and when they are in the building.
create type vppsone.cover_role as enum ('normal', 'duty', 'reserve');

-- ---------------------------------------------------------------------------
-- cover_policies
-- ---------------------------------------------------------------------------
--
-- Two standing facts about a member of staff that the planner cannot read off
-- a timetable.
--
-- **The shift window.** A part-time teacher who arrives at the fifth period
-- has four empty periods in their timetable that are not free time — they are
-- periods they are not in the building for. Without this the planner hands
-- them cover duty before they arrive, which is the bug the ported engine was
-- written to fix.
--
-- **The cover role.** `duty` is a coordinator or exam in-charge: still
-- teaching staff, still suggested, but only after everybody else and never
-- automatically. `reserve` is admin staff who may be asked and are never
-- volunteered — they have no timetable at all, so they read as free in every
-- period, which is exactly how they would otherwise end up covering the
-- hardest lesson of the day.
--
-- The engine this was ported from shipped both as constants with real
-- teachers' names in the source. Rule 6 forbids that here, and a school that
-- cannot change its own part-time hours without a deploy is worse off anyway,
-- so they are rows a coordinator edits (task 4.4).

create table vppsone.cover_policies (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  staff_profile_id uuid not null
    references vppsone.staff_profiles (id) on delete cascade,

  -- The period indexes this person is on site for, 0-based. The full day is
  -- stored explicitly rather than as NULL: "every period" and "nobody has said"
  -- are the same answer here, and one representation is easier to read.
  allowed_periods smallint[] not null default '{0,1,2,3,4,5,6,7}',

  cover_role vppsone.cover_role not null default 'normal',

  -- How many covers the planner may hand this person without a coordinator
  -- confirming. Two is the ported engine's default.
  max_auto_covers smallint not null default 2,

  note text,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint cover_policies_max_auto_sane check (max_auto_covers between 0 and 8)
);

comment on table vppsone.cover_policies is
  'Standing cover facts per staff member: the periods they are on site for, whether they are duty or reserve, and their automatic cover cap.';

create unique index cover_policies_unique
  on vppsone.cover_policies (session_label, staff_profile_id);

create trigger cover_policies_set_updated_at
  before update on vppsone.cover_policies
  for each row execute function vppsone.set_updated_at();

alter table vppsone.cover_policies enable row level security;
create policy cover_policies_select_authenticated
  on vppsone.cover_policies for select to authenticated using (true);
grant select on vppsone.cover_policies to authenticated;
grant all on vppsone.cover_policies to service_role;


-- ---------------------------------------------------------------------------
-- teacher_absences
-- ---------------------------------------------------------------------------
--
-- An absence is one day — but not always the whole of one. Teachers leave
-- after the fourth period for a hospital appointment, or arrive at the fifth
-- from one. Modelled as a whole day, those hours read as absent while the
-- teacher is standing in the staff room: the planner invents vacancies nobody
-- needs and refuses the cover this teacher could actually give.
--
-- So the periods are stored, and a whole day is simply every period. This is
-- not a shift: a shift holds every day and lives in `cover_policies`; an
-- absence belongs to one date.

create table vppsone.teacher_absences (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  staff_profile_id uuid not null
    references vppsone.staff_profiles (id) on delete cascade,
  day date not null,
  periods smallint[] not null,
  reason text,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- An entry with no periods is not an absence. Refused here so no screen has
  -- to decide what an empty one would have meant.
  constraint teacher_absences_has_periods check (cardinality(periods) > 0)
);

comment on table vppsone.teacher_absences is
  'One row per staff member per day away, carrying the periods it applies to. A whole day is every period.';

create unique index teacher_absences_unique
  on vppsone.teacher_absences (staff_profile_id, day);

create index teacher_absences_by_day_idx
  on vppsone.teacher_absences (session_label, day);

create trigger teacher_absences_set_updated_at
  before update on vppsone.teacher_absences
  for each row execute function vppsone.set_updated_at();

alter table vppsone.teacher_absences enable row level security;
create policy teacher_absences_select_authenticated
  on vppsone.teacher_absences for select to authenticated using (true);
grant select on vppsone.teacher_absences to authenticated;
grant all on vppsone.teacher_absences to service_role;


-- ---------------------------------------------------------------------------
-- substitution_plans
-- ---------------------------------------------------------------------------
--
-- One plan per day. `version_id` records the timetable it was planned
-- against, because a plan built on a timetable that has since been republished
-- is describing periods that may no longer exist — the ported engine threw
-- saved plans away on a schedule version change, and this is where that rule
-- lives now.

create table vppsone.substitution_plans (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  day date not null,
  version_id uuid not null
    references vppsone.timetable_versions (id) on delete restrict,

  status vppsone.substitution_plan_status not null default 'draft',

  generated_at timestamptz,
  published_at timestamptz,
  published_by uuid references vppsone.staff_profiles (id) on delete restrict,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint substitution_plans_published_together
    check (
      (status = 'draft' and published_at is null)
      or (status = 'published' and published_at is not null)
    )
);

comment on table vppsone.substitution_plans is
  'One cover plan per day, planned against a specific published timetable version.';

create unique index substitution_plans_unique_day
  on vppsone.substitution_plans (session_label, day);

create trigger substitution_plans_set_updated_at
  before update on vppsone.substitution_plans
  for each row execute function vppsone.set_updated_at();

alter table vppsone.substitution_plans enable row level security;
create policy substitution_plans_select_authenticated
  on vppsone.substitution_plans for select to authenticated using (true);
grant select on vppsone.substitution_plans to authenticated;
grant all on vppsone.substitution_plans to service_role;


-- ---------------------------------------------------------------------------
-- substitution_assignments
-- ---------------------------------------------------------------------------

create table vppsone.substitution_assignments (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null
    references vppsone.substitution_plans (id) on delete cascade,

  period smallint not null,
  class_id uuid not null,
  -- Denormalised, like `timetable_slots.class_label`: a printed cover sheet
  -- has to read correctly a year later, when an alias may have been renamed.
  class_label text not null,
  subject_code text,

  original_staff_id uuid
    references vppsone.staff_profiles (id) on delete restrict,

  -- NULL for self study and for a merged class: nobody is covering, which is
  -- a decision in its own right and not a gap in the data.
  covering_staff_id uuid
    references vppsone.staff_profiles (id) on delete restrict,

  kind vppsone.substitution_kind not null default 'cover',
  merge_host_class_id uuid,
  merge_host_class_label text,

  -- Why the engine chose this person, kept so the sheet can say so and so a
  -- coordinator can see what a regenerate would change.
  match_tier text,
  source vppsone.substitution_source not null default 'manual',
  warnings text[] not null default '{}',

  -- A pin survives a regenerate. It is a decision somebody made on purpose.
  pinned boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint substitution_assignments_cover_has_teacher
    check (kind <> 'cover' or covering_staff_id is not null),
  constraint substitution_assignments_merge_has_host
    check (kind <> 'merged' or merge_host_class_id is not null)
);

comment on table vppsone.substitution_assignments is
  'One row per vacancy in a plan: who covers it, or that it is self study or merged into another class.';

-- One decision per class per period.
create unique index substitution_assignments_unique_slot
  on vppsone.substitution_assignments (plan_id, class_id, period);

-- Nobody covers two classes at once. The engine refuses it too; this is the
-- half that still holds when a coordinator overrides by hand.
create unique index substitution_assignments_no_double_booking
  on vppsone.substitution_assignments (plan_id, covering_staff_id, period)
  where covering_staff_id is not null;

create index substitution_assignments_by_teacher_idx
  on vppsone.substitution_assignments (covering_staff_id);

create trigger substitution_assignments_set_updated_at
  before update on vppsone.substitution_assignments
  for each row execute function vppsone.set_updated_at();

alter table vppsone.substitution_assignments enable row level security;
create policy substitution_assignments_select_authenticated
  on vppsone.substitution_assignments for select to authenticated using (true);
grant select on vppsone.substitution_assignments to authenticated;
grant all on vppsone.substitution_assignments to service_role;

-- ======================================================== migrations/20260917033652_create_collection.sql
-- VPPS One — collection: the Sampark merge (Phase 5).
--
-- Asking the school a question and getting an answer back, without anybody
-- signing in. The office builds a request, sends one link per teacher, and the
-- answers arrive here for a person to accept.

create type vppsone.field_input as enum
  ('text', 'tel', 'number', 'date', 'boolean', 'select');

-- `confirm` shows what is on record and asks whether it is right; `collect`
-- shows an empty input. The difference matters on a phone: confirming forty
-- numbers is forty taps, typing them is forty minutes.
create type vppsone.field_mode as enum ('confirm', 'collect');

create type vppsone.request_status as enum ('draft', 'open', 'closed');
create type vppsone.submission_status as enum ('pending', 'accepted', 'rejected');
create type vppsone.record_source as enum ('teacher', 'office', 'import');
create type vppsone.send_status as enum ('draft', 'queued', 'sent', 'failed', 'cancelled');

-- ---------------------------------------------------------------------------
-- collection_fields — the registry
-- ---------------------------------------------------------------------------
--
-- One row per question the school can ask. The key is a database identifier:
-- submissions and student records point at it, and it is never renamed once
-- anything does.

create table vppsone.collection_fields (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  label_hi text not null,
  label_en text not null,

  input_type vppsone.field_input not null default 'text',
  mode vppsone.field_mode not null default 'confirm',

  -- Validation, carried on the row so the same rules run in the browser and on
  -- the server. A nine-digit phone number must be impossible to *submit*, not
  -- something the office cleans up later.
  exact_len smallint,
  pattern text,
  max_value numeric,
  options text[],

  -- Which fee-app column answers the same question, when one does.
  --
  -- Sampark wrote these straight back to its own `students` table. Rule 2
  -- forbids that here: `public` is the fee app's and VPPS One never writes it.
  -- So this is not a destination, it is a **comparison**: it lets a request
  -- show the teacher what the fee app currently holds, and lets the review
  -- queue say "the fee app says one thing, the teacher says another" — which a
  -- person then fixes in the fee app, deliberately.
  fee_column text,

  help_hi text,
  help_en text,

  is_active boolean not null default true,
  sort_order integer not null default 0,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- The rule the key editor enforces, held by the database as well, because a
  -- key is a foreign key in everything but name.
  constraint collection_fields_key_shape check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  constraint collection_fields_exact_len_sane check (exact_len is null or exact_len between 1 and 200)
);

comment on table vppsone.collection_fields is
  'Every question the school can ask. The key is referenced by submissions and student records and is never renamed.';

create unique index collection_fields_key_unique on vppsone.collection_fields (key);
create index collection_fields_active_idx on vppsone.collection_fields (is_active, sort_order);

create trigger collection_fields_set_updated_at
  before update on vppsone.collection_fields
  for each row execute function vppsone.set_updated_at();

alter table vppsone.collection_fields enable row level security;
create policy collection_fields_select_authenticated
  on vppsone.collection_fields for select to authenticated using (true);
grant select on vppsone.collection_fields to authenticated;
grant all on vppsone.collection_fields to service_role;


-- ---------------------------------------------------------------------------
-- collection_requests — one ask, one audience, one link
-- ---------------------------------------------------------------------------

create table vppsone.collection_requests (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  title_hi text not null,
  title_en text not null,

  -- The class whose roll is being asked about. No FK (rule 2, D-5).
  class_id uuid not null,
  class_label text not null,

  -- Who the link was made for. Null when the office keeps it themselves.
  assigned_staff_id uuid references vppsone.staff_profiles (id) on delete set null,

  -- ~96 bits of entropy. Enumeration is infeasible on its own, and the rate
  -- limit below makes guessing cost something as well.
  token text not null,

  due_date date,
  status vppsone.request_status not null default 'draft',

  -- The office's own sentence about why this link shows nine children rather
  -- than a whole class. Without it a subset reads as a broken list.
  reason_hi text,
  reason_en text,

  opened_at timestamptz,
  closed_at timestamptz,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint collection_requests_token_shape check (char_length(token) between 12 and 64)
);

comment on table vppsone.collection_requests is
  'One request: a class, a set of fields, a due date and a token. The token is the whole authorization — see resolveToken().';

create unique index collection_requests_token_unique on vppsone.collection_requests (token);
create index collection_requests_open_idx
  on vppsone.collection_requests (session_label, status, due_date);
create index collection_requests_staff_idx
  on vppsone.collection_requests (assigned_staff_id, status);

create trigger collection_requests_set_updated_at
  before update on vppsone.collection_requests
  for each row execute function vppsone.set_updated_at();

alter table vppsone.collection_requests enable row level security;
create policy collection_requests_select_authenticated
  on vppsone.collection_requests for select to authenticated using (true);
grant select on vppsone.collection_requests to authenticated;
grant all on vppsone.collection_requests to service_role;


-- ---------------------------------------------------------------------------
-- collection_request_fields — what this request asks for
-- ---------------------------------------------------------------------------

create table vppsone.collection_request_fields (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null
    references vppsone.collection_requests (id) on delete cascade,
  field_id uuid not null
    references vppsone.collection_fields (id) on delete restrict,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create unique index collection_request_fields_unique
  on vppsone.collection_request_fields (request_id, field_id);

alter table vppsone.collection_request_fields enable row level security;
create policy collection_request_fields_select_authenticated
  on vppsone.collection_request_fields for select to authenticated using (true);
grant select on vppsone.collection_request_fields to authenticated;
grant all on vppsone.collection_request_fields to service_role;


-- ---------------------------------------------------------------------------
-- collection_submissions — what came back
-- ---------------------------------------------------------------------------
--
-- One row per (request, student, field). Re-answering replaces rather than
-- appends: a teacher who corrects a typo is fixing her answer, not filing a
-- second one, and an office reading a queue of both would have to work out
-- which is current.

create table vppsone.collection_submissions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null
    references vppsone.collection_requests (id) on delete cascade,

  -- `public.students.id`, with no FK (rule 2, D-5).
  student_id uuid not null,
  field_id uuid not null
    references vppsone.collection_fields (id) on delete restrict,

  -- Already normalised by the time it lands: ten digits for a phone, yes/no
  -- for a boolean, an ISO date for a date.
  value text,

  -- What the school held when the link was sent, frozen. The review queue
  -- shows the two side by side, and "no change" is a real answer.
  previous_value text,

  status vppsone.submission_status not null default 'pending',

  submitted_at timestamptz not null default now(),
  decided_by uuid references vppsone.staff_profiles (id) on delete restrict,
  decided_at timestamptz,
  decision_note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint collection_submissions_decided_together
    check (
      (status = 'pending' and decided_at is null)
      or (status <> 'pending' and decided_at is not null)
    )
);

comment on table vppsone.collection_submissions is
  'One answer per (request, student, field). Re-answering replaces: a correction is not a second submission.';

create unique index collection_submissions_unique
  on vppsone.collection_submissions (request_id, student_id, field_id);

create index collection_submissions_pending_idx
  on vppsone.collection_submissions (status, submitted_at desc);

create index collection_submissions_student_idx
  on vppsone.collection_submissions (student_id);

create trigger collection_submissions_set_updated_at
  before update on vppsone.collection_submissions
  for each row execute function vppsone.set_updated_at();

alter table vppsone.collection_submissions enable row level security;
create policy collection_submissions_select_authenticated
  on vppsone.collection_submissions for select to authenticated using (true);
grant select on vppsone.collection_submissions to authenticated;
grant all on vppsone.collection_submissions to service_role;


-- ---------------------------------------------------------------------------
-- student_records — what the school now holds
-- ---------------------------------------------------------------------------
--
-- The accepted answer, one per (student, field). This is VPPS One's own record
-- and it never overwrites the fee app: where a field names a `fee_column`, the
-- two are shown side by side and a person decides.
--
-- **An accepted teacher answer outranks every import, forever.** That is
-- written in code rather than as an editable row on purpose — a row can be
-- changed, and no administrative convenience is worth the day a teacher finds
-- her approved correction was quietly undone by somebody re-importing last
-- term's export.

create table vppsone.student_records (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  student_id uuid not null,
  field_id uuid not null
    references vppsone.collection_fields (id) on delete restrict,

  value text,
  source vppsone.record_source not null default 'teacher',

  source_submission_id uuid
    references vppsone.collection_submissions (id) on delete set null,

  recorded_by uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.student_records is
  'The accepted value per (student, field). VPPS One''s own record; it never writes the fee app.';

create unique index student_records_unique
  on vppsone.student_records (student_id, field_id);

create index student_records_field_idx on vppsone.student_records (field_id);

create trigger student_records_set_updated_at
  before update on vppsone.student_records
  for each row execute function vppsone.set_updated_at();

alter table vppsone.student_records enable row level security;
create policy student_records_select_authenticated
  on vppsone.student_records for select to authenticated using (true);
grant select on vppsone.student_records to authenticated;
grant all on vppsone.student_records to service_role;


-- ---------------------------------------------------------------------------
-- student_documents
-- ---------------------------------------------------------------------------
--
-- The file itself lives in Supabase Storage; this is the row that says whose
-- it is and what it is. The bucket is private, and a document is served
-- through a signed URL minted after a permission check — never by a public
-- path, because a birth certificate with a guessable URL is a birth
-- certificate anybody has.

create table vppsone.student_documents (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  student_id uuid not null,

  kind text not null default 'other',
  storage_path text not null,
  file_name text not null,
  content_type text not null,
  byte_size integer not null,

  note text,

  uploaded_by uuid references vppsone.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint student_documents_size_sane check (byte_size between 1 and 20000000)
);

comment on table vppsone.student_documents is
  'A file about one child, held in a private Storage bucket and served through a signed URL after a permission check.';

create unique index student_documents_path_unique
  on vppsone.student_documents (storage_path);

create index student_documents_student_idx
  on vppsone.student_documents (student_id, created_at desc);

create trigger student_documents_set_updated_at
  before update on vppsone.student_documents
  for each row execute function vppsone.set_updated_at();

alter table vppsone.student_documents enable row level security;
create policy student_documents_select_authenticated
  on vppsone.student_documents for select to authenticated using (true);
grant select on vppsone.student_documents to authenticated;
grant all on vppsone.student_documents to service_role;


-- ---------------------------------------------------------------------------
-- message_templates and message_sends
-- ---------------------------------------------------------------------------
--
-- A WhatsApp template is approved by Meta with its wording fixed; the app may
-- only fill the numbered placeholders. So the wording lives here, beside the
-- name AiSensy knows it by, and a send records which template and which
-- values — enough to explain, a year later, exactly what a parent received.

create table vppsone.message_templates (
  id uuid primary key default gen_random_uuid(),

  -- The AiSensy campaign name. This is the contract with the provider.
  code text not null,

  label_hi text not null,
  label_en text not null,

  -- The approved wording, with {{1}}, {{2}} … where values go.
  body_hi text not null,
  body_en text not null,

  -- What each placeholder means, in order, so a send screen can label the
  -- boxes instead of asking somebody to remember.
  variables text[] not null default '{}',

  -- Whether the template carries a URL button, which is how a token link
  -- reaches a teacher's phone.
  has_url_button boolean not null default false,

  audience text not null default 'staff',

  is_active boolean not null default true,
  sort_order integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint message_templates_audience_known check (audience in ('staff', 'parent'))
);

comment on table vppsone.message_templates is
  'The approved wording of each WhatsApp template, beside the name AiSensy knows it by.';

create unique index message_templates_code_unique on vppsone.message_templates (code);

create trigger message_templates_set_updated_at
  before update on vppsone.message_templates
  for each row execute function vppsone.set_updated_at();

alter table vppsone.message_templates enable row level security;
create policy message_templates_select_authenticated
  on vppsone.message_templates for select to authenticated using (true);
grant select on vppsone.message_templates to authenticated;
grant all on vppsone.message_templates to service_role;


create table vppsone.message_sends (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  template_id uuid not null
    references vppsone.message_templates (id) on delete restrict,

  to_phone text not null,
  to_name text,

  -- Who or what it is about, when it is about somebody.
  student_id uuid,
  request_id uuid references vppsone.collection_requests (id) on delete set null,
  staff_profile_id uuid references vppsone.staff_profiles (id) on delete set null,

  variables text[] not null default '{}',

  -- The exact text as it will read, resolved at queue time. Kept because a
  -- template can be edited afterwards and "what did we actually send" must
  -- still have an answer.
  rendered_hi text not null,
  rendered_en text not null,

  status vppsone.send_status not null default 'draft',

  provider_message_id text,
  error text,

  requested_by uuid references vppsone.staff_profiles (id) on delete restrict,
  requested_at timestamptz not null default now(),
  sent_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint message_sends_sent_together
    check ((status = 'sent') = (sent_at is not null))
);

comment on table vppsone.message_sends is
  'One row per message the school means to send, with the text as it will read. A parent-facing send is pressed by a person (D-10).';

create index message_sends_queue_idx
  on vppsone.message_sends (session_label, status, requested_at desc);

create index message_sends_student_idx on vppsone.message_sends (student_id);

create trigger message_sends_set_updated_at
  before update on vppsone.message_sends
  for each row execute function vppsone.set_updated_at();

alter table vppsone.message_sends enable row level security;
create policy message_sends_select_authenticated
  on vppsone.message_sends for select to authenticated using (true);
grant select on vppsone.message_sends to authenticated;
grant all on vppsone.message_sends to service_role;


-- ---------------------------------------------------------------------------
-- rate_limits
-- ---------------------------------------------------------------------------
--
-- Counted in Postgres, not in memory. Vercel runs many instances and each
-- would keep its own tally, so an in-memory limit of 30 across ten instances
-- is really a limit of 300 — which is not a limit.
--
-- The whole check is one upsert: the CASE resets the window in the same
-- statement that increments it, so two concurrent requests cannot both decide
-- the window has expired and both reset the count to 1.

create table vppsone.rate_limits (
  bucket text primary key,
  hits integer not null default 0,
  window_started_at timestamptz not null default now()
);

comment on table vppsone.rate_limits is
  'Token buckets for the public token links. Counted in Postgres because the app runs on many instances.';

alter table vppsone.rate_limits enable row level security;
grant all on vppsone.rate_limits to service_role;

create or replace function vppsone.bump_rate_limit(
  p_bucket text,
  p_limit integer,
  p_window_ms integer
) returns table (allowed boolean, hits integer, retry_after_ms integer)
language plpgsql
security definer
set search_path = vppsone, pg_catalog
as $$
declare
  v_row vppsone.rate_limits%rowtype;
begin
  insert into vppsone.rate_limits as rl (bucket, hits, window_started_at)
  values (p_bucket, 1, now())
  on conflict (bucket) do update
    set
      -- Reset and increment in one statement, so the window cannot be reset
      -- twice by two requests that both read it as expired.
      hits = case
        when rl.window_started_at < now() - make_interval(secs => p_window_ms / 1000.0)
        then 1
        else rl.hits + 1
      end,
      window_started_at = case
        when rl.window_started_at < now() - make_interval(secs => p_window_ms / 1000.0)
        then now()
        else rl.window_started_at
      end
  returning * into v_row;

  return query
  select
    v_row.hits <= p_limit,
    v_row.hits,
    greatest(
      0,
      (extract(epoch from (v_row.window_started_at + make_interval(secs => p_window_ms / 1000.0) - now())) * 1000)::integer
    );
end;
$$;

revoke all on function vppsone.bump_rate_limit(text, integer, integer) from public;
grant execute on function vppsone.bump_rate_limit(text, integer, integer) to service_role;


-- ---------------------------------------------------------------------------
-- The fields the school already asks for
-- ---------------------------------------------------------------------------
--
-- Seeded rather than left empty, because a registry with nothing in it is a
-- screen nobody can use. Every one of these is a question the school already
-- asks on paper at admission.

insert into vppsone.collection_fields
  (key, label_hi, label_en, input_type, mode, exact_len, fee_column, sort_order, help_hi, help_en)
values
  ('guardian_phone', 'अभिभावक का फ़ोन', 'Guardian phone', 'tel', 'confirm', 10,
   'guardian_phone', 1,
   'भाई-बहन का एक ही नंबर होना सामान्य है।',
   'Siblings sharing one number is normal, not a mistake.'),
  ('mother_phone', 'माता का फ़ोन', 'Mother phone', 'tel', 'collect', 10, null, 2, null, null),
  ('date_of_birth', 'जन्म तिथि', 'Date of birth', 'date', 'confirm', null, 'date_of_birth', 3,
   null, 'Checked against an age of 2 to 22 years.'),
  ('aadhaar_last4', 'आधार के अंतिम 4 अंक', 'Aadhaar last 4 digits', 'text', 'collect', 4, null, 4,
   'पूरा आधार नंबर कभी न भरें।', 'Never the full number — the last four only.'),
  ('blood_group', 'रक्त समूह', 'Blood group', 'select', 'collect', null, null, 5, null, null),
  ('address', 'पता', 'Address', 'text', 'confirm', null, 'address', 6, null, null),
  ('transport', 'वाहन', 'Transport', 'select', 'collect', null, null, 7,
   'जो पैदल आते हैं उनके लिए "कोई नहीं" चुनें।',
   'Choose "None" for a child who walks — that is an answer, not a blank.')
on conflict do nothing;

update vppsone.collection_fields
set options = array['A+','A-','B+','B-','AB+','AB-','O+','O-']
where key = 'blood_group';

update vppsone.collection_fields
set options = array['School bus','Own vehicle','Walks','None']
where key = 'transport';

-- ======================================================== migrations/20260917033722_create_vppsone_documents_bucket.sql
-- The private bucket student documents live in.
--
-- A migration rather than a dashboard click, because it has to exist on the
-- live project at cutover too and a setting nobody wrote down is a setting
-- somebody has to rediscover.
--
-- Named `vppsone-` so it cannot collide with the fee app's four buckets on the
-- same project. Private: a document is served through a signed URL minted
-- after a permission check, never by a public path.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'vppsone-documents',
  'vppsone-documents',
  false,
  10485760,
  array[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'image/webp'
  ]
)
on conflict (id) do update
  set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- ======================================================== migrations/20260917041039_create_assessments.sql
-- VPPS One — assessments, marks and report cards (Phase 6).

create type vppsone.assessment_kind as enum ('formative', 'summative', 'practical', 'other');
create type vppsone.assessment_status as enum ('draft', 'open', 'locked');
create type vppsone.export_kind as enum ('marks', 'attendance', 'report_cards');

-- ---------------------------------------------------------------------------
-- assessments — one exam, in one term
-- ---------------------------------------------------------------------------

create table vppsone.assessments (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  term text not null,
  code text not null,
  label_hi text not null,
  label_en text not null,

  kind vppsone.assessment_kind not null default 'summative',

  starts_on date,
  ends_on date,

  -- How much this exam contributes to the term's report card, as a share.
  -- Kept on the exam rather than in a separate weighting table: a school that
  -- changes the weighting changes it for the exam, and one number on one row
  -- is a number somebody can check.
  weight numeric not null default 1,

  status vppsone.assessment_status not null default 'draft',
  locked_at timestamptz,
  locked_by uuid references vppsone.staff_profiles (id) on delete restrict,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint assessments_weight_sane check (weight >= 0 and weight <= 10),
  constraint assessments_dates_ordered check (ends_on is null or starts_on is null or ends_on >= starts_on),
  constraint assessments_locked_together
    check ((status = 'locked') = (locked_at is not null))
);

comment on table vppsone.assessments is
  'One exam in one term. Marks are entered against its subjects; locking it stops further entry.';

create unique index assessments_code_unique
  on vppsone.assessments (session_label, term, code);

create index assessments_open_idx
  on vppsone.assessments (session_label, status);

create trigger assessments_set_updated_at
  before update on vppsone.assessments
  for each row execute function vppsone.set_updated_at();

alter table vppsone.assessments enable row level security;
create policy assessments_select_authenticated
  on vppsone.assessments for select to authenticated using (true);
grant select on vppsone.assessments to authenticated;
grant all on vppsone.assessments to service_role;

-- ---------------------------------------------------------------------------
-- assessment_subjects — what is examined, for whom, out of how much
-- ---------------------------------------------------------------------------
--
-- Not named in PLAN §5, and necessary: an exam is not one max mark. A Class 5
-- English paper and a Class 10 English paper are different papers out of
-- different totals, and a single `max_marks` on the exam would make every class
-- in the school sit the same one.

create table vppsone.assessment_subjects (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null
    references vppsone.assessments (id) on delete cascade,

  -- `public.classes.id`, with no FK (rule 2, D-5).
  class_id uuid not null,
  class_label text not null,

  subject_id uuid not null
    references vppsone.subjects (id) on delete restrict,
  subject_code text not null,

  max_marks numeric not null,
  pass_marks numeric,

  sort_order integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint assessment_subjects_max_sane check (max_marks > 0 and max_marks <= 1000),
  constraint assessment_subjects_pass_sane
    check (pass_marks is null or (pass_marks >= 0 and pass_marks <= max_marks))
);

comment on table vppsone.assessment_subjects is
  'One paper: an exam, a class and a subject, out of a max. A Class 5 paper and a Class 10 paper are different papers.';

create unique index assessment_subjects_unique
  on vppsone.assessment_subjects (assessment_id, class_id, subject_id);

create index assessment_subjects_class_idx
  on vppsone.assessment_subjects (class_id);

create trigger assessment_subjects_set_updated_at
  before update on vppsone.assessment_subjects
  for each row execute function vppsone.set_updated_at();

alter table vppsone.assessment_subjects enable row level security;
create policy assessment_subjects_select_authenticated
  on vppsone.assessment_subjects for select to authenticated using (true);
grant select on vppsone.assessment_subjects to authenticated;
grant all on vppsone.assessment_subjects to service_role;

-- ---------------------------------------------------------------------------
-- marks
-- ---------------------------------------------------------------------------
--
-- One mark per child per paper. `value` NULL and `absent` false is "nobody has
-- entered this yet", which is a different fact from a zero and from a child who
-- did not sit the paper — and a grid that could not tell the three apart would
-- make "who has not entered yet" unanswerable, which is the question the whole
-- board exists for.

create table vppsone.marks (
  id uuid primary key default gen_random_uuid(),
  assessment_subject_id uuid not null
    references vppsone.assessment_subjects (id) on delete cascade,

  student_id uuid not null,

  value numeric,
  absent boolean not null default false,

  entered_by uuid references vppsone.staff_profiles (id) on delete restrict,
  entered_at timestamptz not null default now(),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- A child who was absent has no mark. Storing both would leave two answers
  -- to "what did they get", and the report card would have to guess.
  constraint marks_absent_has_no_value check (not absent or value is null),
  constraint marks_not_negative check (value is null or value >= 0)
);

comment on table vppsone.marks is
  'One mark per child per paper. NULL value with absent false means nobody has entered it yet — which is not a zero.';

create unique index marks_unique
  on vppsone.marks (assessment_subject_id, student_id);

create index marks_student_idx on vppsone.marks (student_id);

create trigger marks_set_updated_at
  before update on vppsone.marks
  for each row execute function vppsone.set_updated_at();

alter table vppsone.marks enable row level security;
create policy marks_select_authenticated
  on vppsone.marks for select to authenticated using (true);
grant select on vppsone.marks to authenticated;
grant all on vppsone.marks to service_role;

-- ---------------------------------------------------------------------------
-- marks_change_log — append-only
-- ---------------------------------------------------------------------------
--
-- A mark that changes after a parent has seen it is the single most sensitive
-- write in this app. The log is append-only and carries both sides of every
-- change, so "it was 68 last week" has an answer that does not depend on
-- anybody remembering.

create table vppsone.marks_change_log (
  id uuid primary key default gen_random_uuid(),

  assessment_subject_id uuid not null
    references vppsone.assessment_subjects (id) on delete cascade,
  student_id uuid not null,

  from_value numeric,
  to_value numeric,
  from_absent boolean,
  to_absent boolean,

  reason text,

  changed_by uuid references vppsone.staff_profiles (id) on delete restrict,
  changed_at timestamptz not null default now()
);

comment on table vppsone.marks_change_log is
  'Append-only. Every change to a mark, both sides of it, and who made it.';

create index marks_change_log_paper_idx
  on vppsone.marks_change_log (assessment_subject_id, changed_at desc);

create index marks_change_log_student_idx
  on vppsone.marks_change_log (student_id, changed_at desc);

alter table vppsone.marks_change_log enable row level security;
create policy marks_change_log_select_authenticated
  on vppsone.marks_change_log for select to authenticated using (true);
grant select on vppsone.marks_change_log to authenticated;
grant all on vppsone.marks_change_log to service_role;

-- ---------------------------------------------------------------------------
-- report_cards
-- ---------------------------------------------------------------------------
--
-- A snapshot, not a view. A report card is what the school handed a family on
-- a day, and marks change afterwards — a correction, a re-mark, a paper found.
-- Recomputing the card from today's marks would silently rewrite what the
-- parent is holding, so the card keeps its own copy of what it said.

create table vppsone.report_cards (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  student_id uuid not null,
  term text not null,

  payload jsonb not null,

  generated_by uuid references vppsone.staff_profiles (id) on delete restrict,
  generated_at timestamptz not null default now(),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table vppsone.report_cards is
  'What the school handed a family, kept as it was. Marks change afterwards; a card does not.';

create unique index report_cards_unique
  on vppsone.report_cards (session_label, student_id, term);

create index report_cards_term_idx
  on vppsone.report_cards (session_label, term);

create trigger report_cards_set_updated_at
  before update on vppsone.report_cards
  for each row execute function vppsone.set_updated_at();

alter table vppsone.report_cards enable row level security;
create policy report_cards_select_authenticated
  on vppsone.report_cards for select to authenticated using (true);
grant select on vppsone.report_cards to authenticated;
grant all on vppsone.report_cards to service_role;

-- ---------------------------------------------------------------------------
-- academic_exports — the log PLAN 6.5 asks for
-- ---------------------------------------------------------------------------
--
-- An export is a copy of the school's records leaving the building. Who took
-- what, and when, is the whole reason the task says "logged".

create table vppsone.academic_exports (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  kind vppsone.export_kind not null,
  scope text not null,
  row_count integer not null default 0,

  exported_by uuid references vppsone.staff_profiles (id) on delete restrict,
  exported_at timestamptz not null default now()
);

comment on table vppsone.academic_exports is
  'One row per export taken. Who took what, and when.';

create index academic_exports_recent_idx
  on vppsone.academic_exports (session_label, exported_at desc);

alter table vppsone.academic_exports enable row level security;
create policy academic_exports_select_authenticated
  on vppsone.academic_exports for select to authenticated using (true);
grant select on vppsone.academic_exports to authenticated;
grant all on vppsone.academic_exports to service_role;

-- ======================================================== migrations/20260917051014_create_jobs.sql
-- VPPS One — the job platform (Phase 7.1).

create type vppsone.job_status as enum ('running', 'ok', 'failed', 'skipped');
create type vppsone.job_trigger as enum ('schedule', 'manual');

-- ---------------------------------------------------------------------------
-- job_runs — one row per attempt, including the ones that failed
-- ---------------------------------------------------------------------------
--
-- A scheduled job nobody can see is a job nobody trusts. The first question
-- after "did the registers open this morning?" is "when did that last work",
-- and that question needs a row per *attempt* — a table that only recorded
-- successes would be silent on precisely the morning somebody is asking.

create table vppsone.job_runs (
  id uuid primary key default gen_random_uuid(),

  -- Not an enum: the job list lives in `src/modules/jobs/domain/jobs.ts`, and
  -- adding a job should not need a migration. An unknown name here is a row
  -- describing a job that has been removed, which is history, not corruption.
  job text not null,

  status vppsone.job_status not null default 'running',
  trigger vppsone.job_trigger not null,

  -- Null for a scheduled run: nobody triggered it, which is the point.
  triggered_by uuid references vppsone.staff_profiles (id) on delete set null,

  -- The school day this run was *for*, which is not always the day it ran on.
  -- A register-opening job retried at 00:05 the next morning is still about
  -- yesterday, and the retry has to be able to say so.
  for_day date,

  -- What it did, in numbers. Kept as jsonb rather than columns because every
  -- job counts something different, and a table with a column per job's
  -- favourite number is a table that gets a migration every time one changes.
  summary jsonb not null default '{}'::jsonb,

  error text,

  started_at timestamptz not null default now(),
  finished_at timestamptz,

  constraint job_runs_finished_when_done
    check ((status = 'running') = (finished_at is null))
);

comment on table vppsone.job_runs is
  'One row per attempt at a scheduled job, successes and failures alike. What the jobs console reads.';

-- **One run of a job at a time, enforced here rather than in code.** Two
-- overlapping register-opening runs would each find no register and each
-- create one. A lock held in the application is a lock that does not exist
-- when the application is two instances, which on Vercel it always is.
create unique index job_runs_one_at_a_time
  on vppsone.job_runs (job)
  where status = 'running';

create index job_runs_recent_idx on vppsone.job_runs (job, started_at desc);
create index job_runs_day_idx on vppsone.job_runs (job, for_day, status);

alter table vppsone.job_runs enable row level security;
create policy job_runs_select_authenticated
  on vppsone.job_runs for select to authenticated using (true);
grant select on vppsone.job_runs to authenticated;
grant all on vppsone.job_runs to service_role;

-- ======================================================== migrations/20260917051208_create_job_message_templates.sql
-- The two staff templates the reminder jobs prepare messages against (7.2).
--
-- Rows rather than code because a template is wording the school owns and
-- AiSensy has approved, and because a job that had to invent its own text
-- would put a sentence in front of a teacher that nobody signed off. Both are
-- `audience = 'staff'`: a parent-facing reminder is refused by `mayDispatch()`
-- whatever a screen believes (D-10, D-76), and a scheduled job is the last
-- place that rule should be tested.
--
-- `on conflict do nothing` so this is safe on a database where somebody has
-- already edited the wording.

insert into vppsone.message_templates
  (code, label_hi, label_en, body_hi, body_en, variables, has_url_button, audience, sort_order)
values
  (
    'vppsone_attendance_reminder',
    'हाज़िरी की याद',
    'Attendance reminder',
    'नमस्ते {{1}}, आज की हाज़िरी अभी जमा नहीं हुई है। कृपया भर दीजिए।',
    'Hello {{1}}, today''s register has not been submitted yet. Please fill it in.',
    array['Teacher name'],
    false,
    'staff',
    3
  ),
  (
    'vppsone_marks_reminder',
    'बाकी अंकों की याद',
    'Marks reminder',
    'नमस्ते {{1}}, इन पेपरों के अंक अभी बाकी हैं: {{2}}',
    'Hello {{1}}, these papers still have marks outstanding: {{2}}',
    array['Teacher name', 'Which papers'],
    false,
    'staff',
    4
  )
on conflict (code) do nothing;

-- ======================================================== migrations/20260917093746_create_qa_fixture_runs.sql
-- VPPS One — QA fixture bookkeeping (task R0.2).
--
-- PLAN §5 R0 asks for fixtures that are "removable by run ID", and QA.md for a
-- run that can prove its own cleanup. Both need the seeder to remember what it
-- did, and remembering it in a file on one laptop is not remembering it.
--
-- So a fixture run writes an **undo log** as it goes: one row per write, with
-- enough to reverse it. An insert is reversed by deleting the key; an update is
-- reversed by writing `previous` back. That is what makes it safe for the
-- seeder to touch rows it did not create — binding a QA login to a staff
-- profile that already exists, for instance — because the old value is kept
-- rather than assumed to be null.
--
-- These two tables are bookkeeping, not product data. Nothing in `src/` reads
-- them; `scripts/qa-fixture.mjs` owns them, and that script refuses to run
-- against anything but the dev project (rule 3). They live in `vppsone`
-- because rule 1 says everything this app creates does.

-- ---------------------------------------------------------------------------
-- qa_runs — one row per `npm run qa:seed`
-- ---------------------------------------------------------------------------

create table vppsone.qa_runs (
  -- Human-chosen and human-typed: `qa:reset --run <id>`. A uuid would be
  -- correct and unusable at a terminal, so this is a short readable id the
  -- seeder derives from the clock, e.g. `r20260917-0942`.
  run_id text primary key,

  -- What made this run deterministic. Two runs with the same seed pick the
  -- same teachers, the same class and the same children; a run that cannot say
  -- what its seed was cannot be repeated, and an unrepeatable fixture makes an
  -- intermittent failure unarguable.
  seed text not null,

  -- Null until the run finishes. A row that never got one is a seed that died
  -- halfway, which is exactly the state `qa:reset` has to be able to clear.
  finished_at timestamptz,

  -- `seed` | `reset`. Plain text for the same reason `job_runs.job` is: adding
  -- a fixture mode should not need a migration.
  kind text not null default 'seed',

  note text,
  started_at timestamptz not null default now()
);

comment on table vppsone.qa_runs is
  'One row per QA fixture run. Dev-only bookkeeping written by scripts/qa-fixture.mjs; no application code reads it.';

create index qa_runs_recent_idx on vppsone.qa_runs (started_at desc);

-- ---------------------------------------------------------------------------
-- qa_undo — how to put it back
-- ---------------------------------------------------------------------------

create table vppsone.qa_undo (
  id bigint generated always as identity primary key,

  run_id text not null references vppsone.qa_runs (run_id) on delete cascade,

  -- Reversal order. Rows are undone by descending `seq`, because a fixture
  -- writes a staff profile before the class-teacher row that points at it and
  -- deleting them in insertion order would hit the foreign key.
  seq integer not null,

  -- Schema-qualified, e.g. `vppsone.class_teachers`. The reset resolves it at
  -- run time rather than trusting a bare name to mean the right schema.
  table_name text not null,

  -- `insert` — reverse by deleting `key`.
  -- `update` — reverse by writing `previous` back over `key`.
  -- `delete` — reverse by inserting `previous`.
  action text not null,

  -- The primary key, as an object: `{"id": "…"}`, or a composite.
  key jsonb not null,

  -- The whole row as it was **before** this write, or null for an insert.
  -- Whole, not the changed columns: a partial snapshot restores a row that
  -- looks right and is not, and this is the only copy.
  previous jsonb,

  created_at timestamptz not null default now(),

  constraint qa_undo_action_is_known
    check (action in ('insert', 'update', 'delete')),

  -- An update or delete with nothing to put back is not reversible, and
  -- finding that out during a reset is finding it out too late.
  constraint qa_undo_reversal_has_a_previous
    check (action = 'insert' or previous is not null)
);

comment on table vppsone.qa_undo is
  'What a QA fixture run changed, and how to reverse it. Undone in descending seq order.';

create index qa_undo_by_run_idx on vppsone.qa_undo (run_id, seq desc);

-- No authenticated grants and no select policy on either table: this is test
-- scaffolding, the service-role client is the only thing that touches it, and
-- a signed-in member of staff has no reason to read it.
alter table vppsone.qa_runs enable row level security;
alter table vppsone.qa_undo enable row level security;
grant all on vppsone.qa_runs to service_role;
grant all on vppsone.qa_undo to service_role;

-- ======================================================== migrations/20260917110132_collection_request_title_is_authored.sql
-- A request's title is text somebody typed, not a string this app ships.
--
-- Both halves were NOT NULL, so the office had to type the same sentence twice
-- before it could ask a teacher for a phone number — the most common task in
-- the app, doubled, to buy a translation nobody asked for (B-05). PLAN §3a:
-- "routine requests must not require two typed titles".
--
-- So one half is enough, and which one is a fact worth keeping: a Hindi reader
-- shown an English title is not broken, but the screen should be able to say
-- it fell back rather than pretend the author wrote it that way (B-14).
-- Storing the typed text in both columns would lose exactly that.

alter table vppsone.collection_requests
  alter column title_hi drop not null,
  alter column title_en drop not null;

-- An empty string is not an answer. Normalising it to null at the boundary
-- means "nothing was typed" has one representation rather than two, and the
-- check below can be about presence instead of about whitespace.
update vppsone.collection_requests set title_hi = null where btrim(title_hi) = '';
update vppsone.collection_requests set title_en = null where btrim(title_en) = '';

-- A request with no title at all is a teacher opening a link that does not say
-- what is being asked. One half is a choice; none is a bug.
alter table vppsone.collection_requests
  add constraint collection_requests_has_a_title
  check (
    coalesce(nullif(btrim(title_hi), ''), nullif(btrim(title_en), '')) is not null
  );

comment on column vppsone.collection_requests.title_hi is
  'Authored text, not a shipped string. Null when the author wrote only English; the reader falls back and the screen says so.';
comment on column vppsone.collection_requests.title_en is
  'Authored text, not a shipped string. Null when the author wrote only Hindi.';

-- ======================================================== migrations/20260917122238_create_collection_rounds_and_frozen_members.sql
-- VPPS One — collection rounds, and the roster frozen at the moment of asking.
--
-- **The bug this exists to fix (B-07, S-02).** A request's roll and its
-- prefilled values were re-read from `enrolments` and `student_records` every
-- time the link was opened. So moving a child between classes after a link went
-- out changed who the teacher was being asked about, and an office correction
-- changed what "old value" meant on the review screen — the teacher is shown
-- one thing, answers it, and the queue compares her answer against something
-- she never saw.
--
-- A request is a question that was asked at a moment. This freezes the moment.

/* ------------------------------------------------------------- the round */

create table vppsone.collection_rounds (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  -- Authored text: one half is enough (R1.3, D-129).
  title_hi text,
  title_en text,

  -- What was asked for, as chosen. Kept as the *description* of the audience
  -- rather than as its result: the result is `collection_request_members`, and
  -- keeping both means the board can say "Class 6, children with no phone
  -- number" long after the children in question have changed.
  --
  -- { kind, classIds[], houses[], routes[], studentIds[], gaps[] }
  audience jsonb not null default '{}'::jsonb,

  due_date date,

  -- Why these children and not a whole class. Without it a subset reads to a
  -- teacher as a broken list, which is worse than not sending it.
  reason_hi text,
  reason_en text,

  -- `class_teacher` | `incharge`. Plain text rather than an enum, following
  -- the rule below: a third way of choosing recipients should cost nothing.
  recipient_mode text not null default 'class_teacher',

  status text not null default 'draft',

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- A round nobody can read the title of is a link that does not say what is
  -- being asked.
  constraint collection_rounds_has_a_title
    check (coalesce(nullif(btrim(title_hi), ''), nullif(btrim(title_en), '')) is not null)
);

comment on table vppsone.collection_rounds is
  'One round of asking: an audience, some fields, a due date. Its links are collection_requests rows carrying round_id.';
comment on column vppsone.collection_rounds.audience is
  'What was asked for, as chosen. The result is collection_request_members, frozen at issue.';

create index collection_rounds_session_idx
  on vppsone.collection_rounds (session_label, created_at desc);

create trigger collection_rounds_set_updated_at
  before update on vppsone.collection_rounds
  for each row execute function vppsone.set_updated_at();

alter table vppsone.collection_rounds enable row level security;
create policy collection_rounds_select_authenticated
  on vppsone.collection_rounds for select to authenticated using (true);
grant select on vppsone.collection_rounds to authenticated;
grant all on vppsone.collection_rounds to service_role;

/* --------------------------------------------- a request inside a round */

alter table vppsone.collection_requests
  -- ON DELETE SET NULL, not CASCADE: a link outlives the round it came from.
  -- Deleting a round must not delete the answers a teacher already sent.
  add column round_id uuid references vppsone.collection_rounds (id) on delete set null,

  -- class | house | route | master | list.
  --
  -- **Plain text, no enum and no check.** A fifth kind should cost nothing:
  -- an enum would need a migration, and the resolver, the board, the token
  -- routes and the review queue all carry this value through unchanged. An
  -- unrecognised kind is a row from a later version, not corruption.
  add column audience_kind text not null default 'class',

  -- How the group reads on screen and in the message: "Class 6", "Rana
  -- Pratap", "Amet City", "All classes".
  add column audience_label text,

  -- The number this link was actually sent to, when it is not the teacher's
  -- saved one. Null means "use the profile's". The office often knows a better
  -- number for one round, and typing it here must not change every future one.
  add column contact_phone text,

  -- Handing a link over happens once, so this is both "when" and "whether".
  add column sent_at timestamptz,
  add column sent_by uuid references vppsone.staff_profiles (id) on delete set null,

  -- A chase happens again every week the answers do not arrive, so the useful
  -- facts are the most recent one and how many there have been. Deliberately a
  -- different shape from sent_at.
  add column reminded_at timestamptz,
  add column reminded_by uuid references vppsone.staff_profiles (id) on delete set null,
  add column reminder_count integer not null default 0,

  -- Hidden from the boards, kept in the database. A request that collected
  -- answers cannot be deleted — submissions reference it — so archiving is the
  -- honest version of the same intent: the clutter goes, the evidence does not.
  add column archived_at timestamptz,

  -- When this link's token was last replaced. Never read by the resolver:
  -- rotation overwrites `token`, so the old URL is dead the instant the new one
  -- is born. This exists only so a screen can say "rotated 3 Sep".
  add column token_rotated_at timestamptz;

-- A house or a bus route spans classes, so neither has one.
alter table vppsone.collection_requests alter column class_id drop not null;
alter table vppsone.collection_requests alter column class_label drop not null;

-- Every existing request is a class request, and its label is its class.
update vppsone.collection_requests
set audience_label = coalesce(audience_label, class_label)
where audience_label is null;

alter table vppsone.collection_requests alter column audience_label set not null;

-- A class request still needs its class: dropping NOT NULL above must not let
-- one be created without one.
alter table vppsone.collection_requests
  add constraint collection_requests_class_kind_has_a_class
  check (audience_kind <> 'class' or class_id is not null);

-- **One link per group per round.** This is what makes Resume safe: a fan-out
-- that failed halfway is finished by creating the scopes that are missing, and
-- a double-tapped Resume racing itself hits this index instead of minting a
-- second token for a group that already has one.
create unique index collection_requests_round_scope_idx
  on vppsone.collection_requests (round_id, audience_kind, audience_label)
  where round_id is not null;

create index collection_requests_round_idx
  on vppsone.collection_requests (round_id);

/* ----------------------------------------- who was asked, and what we held */

create table vppsone.collection_request_members (
  request_id uuid not null
    references vppsone.collection_requests (id) on delete cascade,

  -- `public.students.id`, with no FK (rule 2, D-5).
  student_id uuid not null,

  -- The roll number as it was when the link went out. A child's roll number
  -- changes; the sheet the teacher is looking at does not.
  roll_no text,

  -- **The prefilled values exactly as sent.** This is the diff base: every
  -- answer is compared against it to decide what changed, so "old value → new
  -- value" on the review screen still refers to what the teacher actually saw,
  -- however many times the record has been corrected since.
  snapshot jsonb not null default '{}'::jsonb,

  -- One line about this child on this link — "number belongs to an uncle",
  -- "photo is blurred". A column rather than a key in `snapshot`, which is the
  -- obvious home and the wrong one: `snapshot` is the diff base, and a key in
  -- there that is not a field is a key something will eventually read as one.
  ask_note text,

  created_at timestamptz not null default now(),

  primary key (request_id, student_id)
);

comment on table vppsone.collection_request_members is
  'Who was in scope and what we held, frozen at the moment the link was issued. Moving a child afterwards cannot change what was asked (S-02).';
comment on column vppsone.collection_request_members.snapshot is
  'Prefilled values exactly as sent. The diff base for review — never re-derived.';

create index collection_request_members_student_idx
  on vppsone.collection_request_members (student_id);

alter table vppsone.collection_request_members enable row level security;
create policy collection_request_members_select_authenticated
  on vppsone.collection_request_members for select to authenticated using (true);
grant select on vppsone.collection_request_members to authenticated;
grant all on vppsone.collection_request_members to service_role;

-- ======================================================== migrations/20260917124338_create_external_student_ids.sql
-- VPPS One — which child in another app is this child.
--
-- **S-10 / B-15.** SamPark keys its students on its own text id ('S1001'),
-- not on `public.students.id`, so there is no arithmetic that turns one into
-- the other. `apps.ts` has therefore never emitted a SamPark deep link: it
-- sends the reader to SamPark's search box, because guessing by name is the
-- one thing PARITY.md says never to do.
--
-- This is the table that ends the guessing. Nothing populates it yet — the
-- matcher belongs with the student source tooling in R4.1 — and until a row
-- exists the link keeps degrading to search, which is the same honest
-- behaviour it has today.

create table vppsone.external_student_ids (
  -- `AppId` from `src/platform/config/app-origins.ts`. Text, not an enum: a
  -- fourth app should cost a row, not a migration.
  app_id text not null,

  -- The other app's own id, exactly as it holds it.
  external_id text not null,

  -- `public.students.id`, with no foreign key (rule 2, D-5).
  student_id uuid not null,

  -- **Which dataset that uuid belongs to.**
  --
  -- Load-bearing. VPPS One reads schoolfees-dev and both siblings read live,
  -- so a uuid here is only meaningful against the dataset it was matched in.
  -- A deep link built from a dev-matched row while pointed at live data would
  -- not 404 — it would open a different child, which is worse than not
  -- linking at all. The resolver refuses a row whose environment is not the
  -- one being read.
  source_environment text not null,

  -- How the pair was established: 'admission_no', 'sr_no', 'hand'. Kept
  -- because a wrong mapping is found by asking how it was made, and a matcher
  -- that silently changes rule leaves no trace otherwise.
  matched_on text,

  note text,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),

  primary key (app_id, external_id)
);

comment on table vppsone.external_student_ids is
  'Which child in another app is this child. Only usable against the dataset in source_environment (S-10).';
comment on column vppsone.external_student_ids.source_environment is
  'The dataset student_id belongs to. A mapping matched on dev says nothing about a child on live.';

-- One child, one id per app, in each direction. Without this a re-run of a
-- matcher quietly builds a second mapping and the link starts depending on
-- row order.
create unique index external_student_ids_one_per_student
  on vppsone.external_student_ids (app_id, source_environment, student_id);

create index external_student_ids_student_idx
  on vppsone.external_student_ids (student_id);

alter table vppsone.external_student_ids enable row level security;
create policy external_student_ids_select_authenticated
  on vppsone.external_student_ids for select to authenticated using (true);
grant select on vppsone.external_student_ids to authenticated;
grant all on vppsone.external_student_ids to service_role;

-- ======================================================== migrations/20260917132427_create_collection_round_fields.sql
-- VPPS One — what a round asks for, before it has any links.
--
-- R3.1 gave a round an audience, a title and a due date but no fields: the
-- fields lived only on `collection_request_fields`, which needs a request, and
-- a request is a link. So a round could be written down on Tuesday and could
-- not say what it was going to ask until the fan-out ran on Wednesday — the
-- preview had nothing to preview.
--
-- This is the other half. The fan-out copies these onto each link it mints, so
-- `collection_request_fields` stays exactly what it is: what *this link* asks,
-- frozen with the rest of it.

create table vppsone.collection_round_fields (
  round_id uuid not null
    references vppsone.collection_rounds (id) on delete cascade,

  -- RESTRICT, matching `collection_request_fields`: a field somebody is still
  -- being asked for is not a field to delete out from under them.
  field_id uuid not null
    references vppsone.collection_fields (id) on delete restrict,

  -- The order the office chose, which is the order the teacher sees. Not the
  -- registry's own `sort_order`: a round asking for two things puts the one it
  -- cares about first, and re-sorting it into registry order would silently
  -- reverse that.
  sort_order integer not null default 0,

  created_at timestamptz not null default now(),

  primary key (round_id, field_id)
);

comment on table vppsone.collection_round_fields is
  'What a round asks for. Copied onto each link at fan-out; collection_request_fields stays what THAT link asks.';

create index collection_round_fields_field_idx
  on vppsone.collection_round_fields (field_id);

alter table vppsone.collection_round_fields enable row level security;
create policy collection_round_fields_select_authenticated
  on vppsone.collection_round_fields for select to authenticated using (true);
grant select on vppsone.collection_round_fields to authenticated;
grant all on vppsone.collection_round_fields to service_role;

-- ======================================================== migrations/20260917142719_create_staff_scopes.sql
-- VPPS One — who is in charge of a house or a bus route.
--
-- **B-32.** A round can be addressed to a house or a route, and until now
-- nothing in this schema could say who such a link would go *to*.
-- `vppsone.class_teachers` covers classes and `staff_profiles` has no
-- equivalent columns, so a house round resolved to children and then had
-- nowhere to send them. SamPark carries `teacher.houses` and `teacher.routes`;
-- this is the same fact, normalised.
--
-- **Classes deliberately stay in `class_teachers`.** Merging them would mean
-- either dropping that table's `role`, `effective_from`/`effective_to` and
-- `replaced_reason` — which exist because a class teacher is replaced
-- mid-year and the register has to know when — or bolting four columns that
-- mean nothing for a bus route onto every row here. One source of truth per
-- kind, and `ownersFor()` reads both.

create table vppsone.staff_scopes (
  id uuid primary key default gen_random_uuid(),

  staff_profile_id uuid not null
    references vppsone.staff_profiles (id) on delete cascade,

  -- `house` | `route`. Plain text with no enum, following `audience_kind`
  -- (D-144): a fourth thing somebody can be in charge of should cost a row.
  kind text not null,

  -- The house name as `public.students.house` spells it, or the route id as
  -- `public.students.transport_route_id` holds it. **Matched exactly**, never
  -- by prefix: several bus routes differ only by a parenthesised suffix
  -- ("Amet Railway Station (Inside)" against "(On Road)"), and a loose match
  -- would hand one route's children to another route's in-charge.
  value text not null,

  -- In-charge of a house *this year*. It changes, and a round sent last term
  -- was sent to whoever held it then.
  session_label text not null,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),

  constraint staff_scopes_kind_is_known check (kind in ('house', 'route')),
  constraint staff_scopes_value_not_blank check (btrim(value) <> '')
);

comment on table vppsone.staff_scopes is
  'Who is in charge of a house or a bus route this session. Classes live in class_teachers, which carries handover dates this does not need (B-32).';

-- One row per person per thing. A second identical row would make "two people
-- are assigned to Chetak" true when one person was recorded twice, and that
-- reads to the office as a choice to make rather than a duplicate to delete.
create unique index staff_scopes_one_per_person
  on vppsone.staff_scopes (session_label, kind, value, staff_profile_id);

-- "Who owns this house" — the fan-out's own query, once per group.
create index staff_scopes_by_value
  on vppsone.staff_scopes (session_label, kind, value);

create index staff_scopes_by_person
  on vppsone.staff_scopes (staff_profile_id);

alter table vppsone.staff_scopes enable row level security;
create policy staff_scopes_select_authenticated
  on vppsone.staff_scopes for select to authenticated using (true);
grant select on vppsone.staff_scopes to authenticated;
grant all on vppsone.staff_scopes to service_role;

-- ======================================================== migrations/20260917155559_create_staff_start_preference.sql
-- Where a member of staff starts when they sign in.
--
-- The product requirement behind this column is "accounts staff should open
-- the School Fees workspace by default". The thing it must **not** become is a
-- seventh role: `accountant` is the fee app's identity model, and nothing in
-- this repo can grant it (CLAUDE.md rule 2, PLAN §3, D-6). Deriving one from
-- an email address or a menu label would be inventing access by inference.
--
-- So this is an explicit per-account preference, chosen by the person
-- themselves, and it can only ever name a destination their role already
-- reaches:
--
--   NULL              the role's own Home — the default, and what every
--                     existing row means today
--   '/students'       a VPPS One route the role holds the permission for
--   'app:schoolfees'  one of the sibling apps, and only for a role the
--                     registry already offers it to (`apps:view`)
--
-- The format is constrained here; **which** value a given role may actually
-- use is decided in `src/platform/config/start.ts`, next to the permission map
-- it has to agree with. A stored value the role no longer qualifies for is
-- ignored at read time rather than honoured — a demotion must not leave
-- somebody with a landing page they can no longer open.

alter table vppsone.staff_profiles
  add column preferred_start text;

alter table vppsone.staff_profiles
  add constraint staff_profiles_preferred_start_shape
  check (
    preferred_start is null
    or preferred_start ~ '^(/[a-z0-9/-]*|app:[a-z][a-z0-9-]*)$'
  );

comment on column vppsone.staff_profiles.preferred_start is
  'Explicit start screen for this account: NULL for the role Home, a VPPS One path, or app:<registry id>. Never grants access — resolved against the role permission map at read time.';

-- ======================================================== migrations/20260918043934_add_fee_roles_to_staff_role.sql
-- The fee app is being folded into VPPS One and retired, so its two
-- fee-desk roles become this app's own.
--
-- `accountant` is the role that sees the ported School Fees screens.
-- `fee_collector` works the follow-up list and takes no money.
--
-- Both are additive. Nothing is assigned here: Postgres refuses to USE an
-- enum value added in the same transaction that added it, so any row that
-- becomes an accountant does so in a later migration or at runtime.

alter type vppsone.staff_role add value if not exists 'accountant';
alter type vppsone.staff_role add value if not exists 'fee_collector';
