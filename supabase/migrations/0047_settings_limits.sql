-- =============================================================================
-- 0047_settings_limits.sql — limits on shop settings
--                            (AceStock, foundation code review #11)
--
-- Before:
--   • Any number could be saved as a setting: a negative or 150% tax rate, a
--     negative stringing labor charge or reorder point. The web app's checks
--     were the only guard, and "8.25%" was saved as 0% tax.
--
-- Now:
--   1. The tax rate is between 0 and 100, the stringing labor charge is 0 or
--      more, and the default reorder point is empty or 0 or more. Anything
--      else is refused with a message naming the setting.
--
-- Re-runnable.
-- =============================================================================

create or replace function guard_settings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.tax_rate < 0 or new.tax_rate > 100 then
    raise exception 'Tax rate must be between 0 and 100 (got %)', new.tax_rate;
  end if;
  if new.stringing_labor < 0 then
    raise exception 'Stringing labor can''t be negative (got %)', new.stringing_labor;
  end if;
  if new.default_reorder_point < 0 then
    raise exception 'Default reorder point can''t be negative (got %)', new.default_reorder_point;
  end if;
  return new;
end;
$$;

revoke all on function guard_settings() from public, anon, authenticated;

drop trigger if exists trg_guard_settings on settings;
create trigger trg_guard_settings
  before insert or update on settings
  for each row execute function guard_settings();
