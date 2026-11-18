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
  academic_fee_distribution text check (academic_fee_distribution is null or academic_fee_distribution in ('first_only', 'equal')),
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
  custom_other_fee_head_labels jsonb,
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

-- Student-info columns the ported fee code writes on every admission
-- (src/modules/students-fees/domain/info-fields.ts). Missing from the first
-- rebuild, which made every "Add student" fail with a 400; applied to
-- uvvusynovvhtacauvrzc on 18 Nov 2026 as migration kmd_students_info_columns.
alter table public.students
  add column if not exists blood_group text,
  add column if not exists religion text,
  add column if not exists caste text,
  add column if not exists nationality text,
  add column if not exists mother_tongue text,
  add column if not exists aadhaar_no text,
  add column if not exists jan_aadhaar_no text,
  add column if not exists apaar_id text,
  add column if not exists previous_school text,
  add column if not exists board_registration_no text,
  add column if not exists tehsil text,
  add column if not exists district text,
  add column if not exists state text,
  add column if not exists pincode text,
  add column if not exists guardian_relation text,
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_phone text;

create unique index if not exists idx_students_aadhaar_no_unique
  on public.students (aadhaar_no) where aadhaar_no is not null;

-- Unique keys the app's upserts name in ON CONFLICT (18 Nov 2026: Fee setup
-- failed with "no unique or exclusion constraint matching the ON CONFLICT").
alter table public.conventional_discount_policies
  add constraint conventional_discount_policies_session_code_key unique (academic_session_label, code);
alter table public.student_family_members
  add constraint student_family_members_session_group_student_key unique (academic_session_label, family_group_id, student_id);
alter table public.collection_closures
  add constraint collection_closures_payment_date_key unique (payment_date);
alter table public.student_collection_flags
  add constraint student_collection_flags_session_student_key unique (session_label, student_id);

-- Foreign keys the app's linked reads (PostgREST embeds) need, and the office
-- sync event shape the app writes (18 Nov 2026: dues preparation read 400).
alter table public.student_conventional_discount_assignments
  add constraint scda_policy_id_fkey foreign key (policy_id) references public.conventional_discount_policies(id),
  add constraint scda_family_group_id_fkey foreign key (family_group_id) references public.student_family_groups(id),
  add constraint scda_student_id_fkey foreign key (student_id) references public.students(id) on delete cascade;
alter table public.refund_requests
  add constraint refund_requests_receipt_id_fkey foreign key (receipt_id) references public.receipts(id),
  add constraint refund_requests_student_id_fkey foreign key (student_id) references public.students(id);
alter table public.student_late_fee_waivers
  add constraint student_late_fee_waivers_installment_id_fkey foreign key (installment_id) references public.installments(id) on delete cascade;
alter table public.student_repayment_receipt_links
  add constraint student_repayment_receipt_links_receipt_id_fkey foreign key (receipt_id) references public.receipts(id);
alter table public.office_sync_events
  add column if not exists action text,
  alter column entity_id type text using entity_id::text,
  alter column affected_student_ids type text[] using null;

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

-- Needed by the reminder delivery read (embed students); 18 Nov 2026.
alter table public.whatsapp_reminder_sends
  add constraint whatsapp_reminder_sends_student_id_fkey foreign key (student_id) references public.students(id);
