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

alter table public.whatsapp_reminder_sends
  add constraint whatsapp_reminder_sends_student_id_fkey foreign key (student_id) references public.students(id);

alter table public.office_sync_events
  add column if not exists action text,
  alter column entity_id type text using entity_id::text,
  alter column affected_student_ids type text[] using null;

notify pgrst, 'reload schema';
