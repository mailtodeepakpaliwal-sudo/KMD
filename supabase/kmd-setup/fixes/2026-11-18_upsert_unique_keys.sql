alter table public.conventional_discount_policies
  add constraint conventional_discount_policies_session_code_key unique (academic_session_label, code);

alter table public.student_family_members
  add constraint student_family_members_session_group_student_key unique (academic_session_label, family_group_id, student_id);

alter table public.collection_closures
  add constraint collection_closures_payment_date_key unique (payment_date);

alter table public.student_collection_flags
  add constraint student_collection_flags_session_student_key unique (session_label, student_id);

notify pgrst, 'reload schema';
