-- Inventory and barcodes (code review #4, #16, #19, #31): unit tracking comes
-- from the category, one code means one thing, stock adjustments respect
-- "block overselling", and counted-stock functions refuse unit-tracked products.
begin;
\ir helpers/setup.psql

select plan(30);

-- Fixtures: d1 = counted category, d2 = unit-tracked (racquets).
--   b1  Test String 16, UPC 012345678905, 10 on hand        (setup.psql)
--   b2  Test Racquet 100, UPC 098765432109, unit-tracked    (setup.psql)
--   b3  Overgrip (counted, 2 on hand)
--   b4  Spare Racquet (unit-tracked, no history)
insert into products (id, category_id, name, sell_price, barcode) values
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 5, '111111111116'),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000d2', 'Spare Racquet', 199, null);
insert into categories (id, name, sort_order, serialized_default) values
  ('00000000-0000-0000-0000-0000000000d3', 'pgTAP Empty Category', 902, false);
insert into customer_rackets (id, customer_id, model, barcode, is_active) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Active Frame', 'TAG-ACTIVE', true),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Retired Frame', 'TAG-RETIRED', false);
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-INV-1');
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b3', 2);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- #4 Unit tracking comes from the category
-- ---------------------------------------------------------------------------
update products set is_serialized = false where id = '00000000-0000-0000-0000-0000000000b2';
select is((select is_serialized from products where id = '00000000-0000-0000-0000-0000000000b2'), true,
          'staff can''t switch a racquet''s unit tracking off');
update products set is_serialized = true where id = '00000000-0000-0000-0000-0000000000b3';
select is((select is_serialized from products where id = '00000000-0000-0000-0000-0000000000b3'), false,
          'nor switch it on for a counted product');
insert into products (id, category_id, name, sell_price, is_serialized)
values ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000d2', 'New Racquet', 150, false);
select is((select is_serialized from products where id = '00000000-0000-0000-0000-0000000000b5'), true,
          'a new product takes its category''s setting, whatever the screen sent');
select lives_ok(
  $$ update products set category_id = '00000000-0000-0000-0000-0000000000d1'
      where id = '00000000-0000-0000-0000-0000000000b4' $$,
  'a product with no stock history can move between categories');
select is((select is_serialized from products where id = '00000000-0000-0000-0000-0000000000b4'), false,
          '... and takes the new category''s setting');
select throws_like(
  $$ update products set category_id = '00000000-0000-0000-0000-0000000000d2'
      where id = '00000000-0000-0000-0000-0000000000b1' $$,
  '%Test String 16 has stock history, so it can''t switch to unit tracking%',
  'a product with stock history can''t move to a category with the other setting');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_like(
  $$ update categories set serialized_default = true where id = '00000000-0000-0000-0000-0000000000d1' $$,
  '%have stock history%', 'a category''s unit tracking can''t change while its products have history');
select lives_ok(
  $$ update categories set serialized_default = true where id = '00000000-0000-0000-0000-0000000000d3' $$,
  'a category with no product history can change');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- Products: staff create and edit, admins delete
-- ---------------------------------------------------------------------------
select lives_ok($$ update products set sell_price = 6 where id = '00000000-0000-0000-0000-0000000000b3' $$,
                'staff can edit a product');
delete from products where id = '00000000-0000-0000-0000-0000000000b5';
select is((select count(*)::int from products where id = '00000000-0000-0000-0000-0000000000b5'), 1,
          'staff can''t delete a product');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
delete from products where id = '00000000-0000-0000-0000-0000000000b5';
select is((select count(*)::int from products where id = '00000000-0000-0000-0000-0000000000b5'), 0,
          'an admin can delete a product with no history');
select tests.clear_authentication();
select is(
  (select count(*)::int from information_schema.table_privileges
    where table_schema = 'public' and grantee in ('authenticated', 'anon') and privilege_type = 'TRUNCATE'),
  0, 'no signed-in or signed-out user can empty a table');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- #16 One code, one thing
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select receive_units('00000000-0000-0000-0000-0000000000b2', '["012345678905"]'::jsonb) $$,
  '%Barcode 012345678905 is already the UPC of TestBrand Test String 16%',
  'a unit can''t use a product''s UPC');
select throws_like(
  $$ select receive_units('00000000-0000-0000-0000-0000000000b2', '["0012345678905"]'::jsonb) $$,
  '%already the UPC of TestBrand Test String 16%',
  '... nor its EAN-13 form');
select throws_like(
  $$ select receive_units('00000000-0000-0000-0000-0000000000b2', '["TAG-ACTIVE"]'::jsonb) $$,
  '%already the tag on Pat Tester''s Active Frame%',
  'a unit can''t use an active racquet''s tag');
select throws_like(
  $$ select receive_units('00000000-0000-0000-0000-0000000000b2', '["GC-INV-1"]'::jsonb) $$,
  '%already a gift card''s code%',
  'a unit can''t use a gift card code');
select lives_ok(
  $$ select receive_units('00000000-0000-0000-0000-0000000000b2', '["TAG-RETIRED", "RQ-UNIT-1"]'::jsonb) $$,
  'a retired racquet''s tag is free, and a new code is fine');
select throws_like(
  $$ insert into products (category_id, name, sell_price, barcode)
     values ('00000000-0000-0000-0000-0000000000d1', 'Copycat', 1, '0012345678905') $$,
  '%already the UPC of TestBrand Test String 16%',
  'a product can''t take another product''s UPC in the other form');
select throws_like(
  $$ update products set barcode = 'RQ-UNIT-1' where id = '00000000-0000-0000-0000-0000000000b3' $$,
  '%already the barcode of a TestBrand Test Racquet 100 unit%',
  'a product can''t take a unit''s barcode');
select lives_ok(
  $$ update products set sell_price = 7, barcode = '111111111116' where id = '00000000-0000-0000-0000-0000000000b3' $$,
  'saving a product with its own UPC unchanged is fine');
select throws_like(
  $$ insert into customer_rackets (customer_id, model, barcode)
     values ('00000000-0000-0000-0000-0000000000c1', 'Clash', '111111111116') $$,
  '%already the UPC of Overgrip%', 'a racquet tag can''t be a product UPC');
select throws_like(
  $$ update customer_rackets set is_active = true where id = '00000000-0000-0000-0000-0000000000f2' $$,
  '%already the barcode of a TestBrand Test Racquet 100 unit%',
  'reactivating a racquet whose tag was reused is refused');
select throws_like(
  $$ select ensure_gift_card('098765432109', null) $$,
  '%already the UPC of TestBrand Test Racquet 100%', 'a gift card can''t use a product UPC');
select lives_ok($$ select ensure_gift_card('GC-INV-1', null) $$, 'an existing gift card can still be looked up by its code');

-- Lookup prefers the exact form when both exist (data from before 0045).
select tests.clear_authentication();
alter table products disable trigger trg_guard_unique_barcode;
insert into products (id, category_id, name, sell_price, barcode)
values ('00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000d1', 'Old EAN Entry', 1, '0012345678905');
alter table products enable trigger trg_guard_unique_barcode;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select results_eq(
  $$ select r.name from resolve_barcode('0012345678905') r
     union all select r.name from resolve_barcode('012345678905') r $$,
  $$ values ('Old EAN Entry'::text), ('Test String 16'::text) $$,
  'when both forms are stored, a scan finds the exact one');

-- ---------------------------------------------------------------------------
-- #19 Adjustments and #31 counted stock vs units
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update settings set block_oversell = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like(
  $$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -11, 'count') $$,
  '%Only 10 of TestBrand Test String 16 on hand; this would take it to -1%',
  'with blocking on, an adjustment can''t take stock below zero');
select lives_ok($$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -10, null) $$,
                'adjusting to exactly zero is fine, with or without a note');
select tests.clear_authentication();
update settings set block_oversell = false where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -3, null) $$,
                'with blocking off, stock can go below zero, as before');
select throws_like(
  $$ select receive_stock('00000000-0000-0000-0000-0000000000b2', 5, 100, null, null) $$,
  '%tracked by unit%', 'counted stock can''t be received for a unit-tracked product');
select throws_like(
  $$ select adjust_stock('00000000-0000-0000-0000-0000000000b2', -1, 'damaged') $$,
  '%tracked by unit%', 'nor adjusted');

select tests.clear_authentication();
select * from finish();
rollback;
