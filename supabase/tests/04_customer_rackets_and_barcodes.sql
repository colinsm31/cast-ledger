-- resolve_barcode resolution order and normalization, plus customer racket
-- retirement: history is kept and retired tags are free to reuse.
begin;
\ir helpers/setup.psql

select plan(17);

insert into product_units (id, product_id, barcode, status) values
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000b2', 'RQ-UNIT-9', 'demo');
insert into customer_rackets (id, customer_id, brand, model, barcode) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'TestBrand', 'Frame A', 'TAG-A'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'TestBrand', 'Frame B', 'TAG-B');
insert into string_jobs (id, customer_racket_id, price, status) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1', 30, 'delivered'),
  ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f1', 30, 'entered');
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-SCAN-1');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- resolve_barcode
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select kind, id, is_serialized from resolve_barcode('012345678905') $$,
  $$ values ('product'::text, '00000000-0000-0000-0000-0000000000b1'::uuid, false) $$,
  'a product UPC resolves to the product');
select is((select id from resolve_barcode('0012345678905')),
          '00000000-0000-0000-0000-0000000000b1'::uuid, 'EAN-13 with a leading zero matches the UPC-A');
select is((select id from resolve_barcode(' 0123 4567 8905 ')),
          '00000000-0000-0000-0000-0000000000b1'::uuid, 'whitespace is ignored');
select results_eq(
  $$ select kind, id, product_id, is_serialized, unit_status from resolve_barcode('RQ-UNIT-9') $$,
  $$ values ('unit'::text, '00000000-0000-0000-0000-0000000000a9'::uuid,
             '00000000-0000-0000-0000-0000000000b2'::uuid, true, 'demo'::text) $$,
  'a unit barcode resolves to the unit, its product and status');
select results_eq(
  $$ select kind, id, customer_id, open_job_id from resolve_barcode('TAG-A') $$,
  $$ values ('racket'::text, '00000000-0000-0000-0000-0000000000f1'::uuid,
             '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-000000000f02'::uuid) $$,
  'a racket tag resolves to the racket, its owner and its open job');
select results_eq(
  $$ select kind, id from resolve_barcode('GC-SCAN-1') $$,
  $$ values ('gift_card'::text, '00000000-0000-0000-0000-0000000000e1'::uuid) $$,
  'a gift card code resolves to the card');
select is((select kind from resolve_barcode('NOPE-404')), 'none', 'an unknown code resolves to none');
select is((select kind from resolve_barcode('   ')), 'none', 'a blank code resolves to none');

-- ---------------------------------------------------------------------------
-- Retiring rackets keeps history
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ delete from customer_rackets where id = '00000000-0000-0000-0000-0000000000f1' $$,
  '23503', null, 'a racket with string jobs cannot be deleted');
select is((select count(*)::int from string_jobs where customer_racket_id = '00000000-0000-0000-0000-0000000000f1'),
          2, 'its string jobs are untouched');

select lives_ok(
  $$ update customer_rackets set is_active = false where id = '00000000-0000-0000-0000-0000000000f1' $$,
  'a racket is retired by deactivating it');
select is((select kind from resolve_barcode('TAG-A')), 'none', 'a retired racket''s tag no longer resolves');
select is((select count(*)::int from string_jobs where customer_racket_id = '00000000-0000-0000-0000-0000000000f1'),
          2, 'retiring keeps the stringing history');

select lives_ok(
  $$ insert into customer_rackets (id, customer_id, model, barcode)
     values ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Frame C', 'TAG-A') $$,
  'a retired racket''s tag can be put on a new racket');
select is((select id from resolve_barcode('TAG-A')),
          '00000000-0000-0000-0000-0000000000f3'::uuid, 'the reused tag resolves to the new racket');
select throws_ok(
  $$ insert into customer_rackets (customer_id, model, barcode)
     values ('00000000-0000-0000-0000-0000000000c1', 'Frame D', 'TAG-B') $$,
  '23505', null, 'two active rackets cannot share a tag');

select lives_ok(
  $$ delete from customer_rackets where id = '00000000-0000-0000-0000-0000000000f2' $$,
  'a racket with no string jobs can still be deleted');

select * from finish();
rollback;
