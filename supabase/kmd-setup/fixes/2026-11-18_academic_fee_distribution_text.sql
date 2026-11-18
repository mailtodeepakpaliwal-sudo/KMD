-- KMD fix, 18 Nov 2026: Fee setup "Review and publish" failed with
--   invalid input syntax for type integer: "first_only"
-- The KMD rebuild typed fee_policy_configs.academic_fee_distribution as
-- integer; the app stores 'first_only' or 'equal'. The column was empty in
-- every row and no view or function reads it, so nothing is lost.
-- (base/01_fee_tables.sql and parts/kmd_db_part02.sql are already corrected
-- for a fresh database; run this once on uvvusynovvhtacauvrzc.)

alter table public.fee_policy_configs
  alter column academic_fee_distribution type text using null;

alter table public.fee_policy_configs
  add constraint fee_policy_configs_academic_fee_distribution_check
  check (academic_fee_distribution is null or academic_fee_distribution in ('first_only', 'equal'));

notify pgrst, 'reload schema';
