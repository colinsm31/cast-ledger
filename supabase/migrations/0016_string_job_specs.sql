-- =============================================================================
-- 0016_string_job_specs.sql — generalize string-job dimensions (AceStock)
--
-- The mains/crosses gauge & color were fixed columns, but the Strings category's
-- variant dimensions can be named anything (custom attributes). Replace the
-- fixed gauge/color columns with main_specs / cross_specs JSONB that hold the
-- picked variant-dimension values keyed by their real attribute names
-- (e.g. {"gauge":"16","color":"Black"}). brand/string/tension/variant_id stay.
--
-- Re-runnable.
-- =============================================================================

alter table string_jobs
  drop column if exists main_gauge,
  drop column if exists main_color,
  drop column if exists cross_gauge,
  drop column if exists cross_color,
  add column if not exists main_specs  jsonb not null default '{}'::jsonb,
  add column if not exists cross_specs jsonb not null default '{}'::jsonb;
