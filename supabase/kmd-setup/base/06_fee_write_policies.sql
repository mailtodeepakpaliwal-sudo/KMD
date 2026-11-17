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
