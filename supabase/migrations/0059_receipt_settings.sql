-- =============================================================================
-- 0059_receipt_settings.sql — what a receipt says about the shop
-- (AceStock, Phase 2C)
--
-- Before:
--   • No receipts, and nowhere to keep the shop's name or return policy.
--
-- Now:
--   • settings gains the receipt text an admin sets in Settings: the shop's
--     name, its address (several lines, which can include a phone number),
--     the return policy and a closing footer. Each is optional, trimmed, and
--     limited in length so it fits on a receipt.
--
-- Settings are already readable by signed-in users and changeable only by an
-- admin (settings_admin_update), so no new policies. Re-runnable.
-- =============================================================================

alter table settings add column if not exists shop_name text;
alter table settings add column if not exists shop_address text;
alter table settings add column if not exists return_policy text;
alter table settings add column if not exists receipt_footer text;

alter table settings drop constraint if exists ck_settings_receipt_text;
alter table settings add constraint ck_settings_receipt_text check (
  (shop_name is null or (shop_name = trim(shop_name) and char_length(shop_name) between 1 and 100))
  and (shop_address is null or (shop_address = trim(shop_address) and char_length(shop_address) between 1 and 300))
  and (return_policy is null or (return_policy = trim(return_policy) and char_length(return_policy) between 1 and 1000))
  and (receipt_footer is null or (receipt_footer = trim(receipt_footer) and char_length(receipt_footer) between 1 and 500)));

comment on column settings.shop_name is 'The shop''s name at the top of receipts';
comment on column settings.shop_address is 'The shop''s address on receipts; may span lines and include a phone number';
comment on column settings.return_policy is 'The return policy printed on receipts';
comment on column settings.receipt_footer is 'A closing line printed at the bottom of receipts';
