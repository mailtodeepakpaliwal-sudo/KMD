create or replace function vppsone.kmd_installment_amount_due() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.amount_due := coalesce(new.base_amount, 0) + coalesce(new.transport_amount, 0) - coalesce(new.discount_amount, 0);
  return new;
end $$;

drop trigger if exists installments_amount_due on public.installments;
create trigger installments_amount_due before insert or update on public.installments
  for each row execute function vppsone.kmd_installment_amount_due();

update public.installments
  set amount_due = coalesce(base_amount, 0) + coalesce(transport_amount, 0) - coalesce(discount_amount, 0);

alter table public.student_fee_overrides
  alter column custom_other_fee_head_labels type jsonb using null;

notify pgrst, 'reload schema';
