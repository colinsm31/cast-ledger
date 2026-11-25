-- =============================================================================
-- 0103_drop_cost_backfill.sql — the one-time cost backfill is gone (AceStock, Phase 4A review)
--
-- 0094 filled in sale lines sold before it with the product's cost at the
-- time, marked "estimated", through fill_estimated_sale_line_costs(). Run
-- again later, it would also mark newer lines whose product had no cost when
-- they sold but has one now. The migration has run, so the function goes.
--
-- Re-runnable.
-- =============================================================================

drop function if exists fill_estimated_sale_line_costs();
