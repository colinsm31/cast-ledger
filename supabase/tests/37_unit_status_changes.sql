-- Retiring a frame or moving it to demo, and each frame's history (Phase 3B).
begin;
\ir helpers/setup.psql

select plan(16);

-- The fixture racquet (b2) is serialized; receive two frames as staff.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '["RQ-1", "RQ-2"]');
create temp table u as
  select (select id from product_units where barcode = 'RQ-1') as one,
         (select id from product_units where barcode = 'RQ-2') as two;
grant select on u to authenticated;

select results_eq(
  $$ select from_status, to_status, changed_by from unit_status_changes where product_unit_id = (select one from u) $$,
  $$ values (null::text, 'in_stock'::text, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'receiving a frame starts its history, with who received it');

-- ---------------------------------------------------------------------------
-- Moving a frame
-- ---------------------------------------------------------------------------
select is(set_unit_status((select one from u), 'demo', ' Demo fleet '), 'demo', 'staff can move a frame to demo');
select is((select status from product_units where id = (select one from u)), 'demo', 'its status changes');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b2'), 1::numeric,
          'and it no longer counts as in stock');
select results_eq(
  $$ select from_status, to_status, reason from unit_status_changes
      where product_unit_id = (select one from u) and from_status is not null $$,
  $$ values ('in_stock'::text, 'demo'::text, 'Demo fleet'::text) $$,
  'the move and its reason are recorded');

select lives_ok($$ select set_unit_status((select one from u), 'retired', 'Cracked throat') $$, 'a demo frame can be retired');
select lives_ok($$ select set_unit_status((select one from u), 'in_stock', 'Repaired by the maker') $$,
                'and a retired one put back in stock');

select throws_like($$ select set_unit_status((select two from u), 'retired', '   ') $$, 'Give a reason', 'a reason is needed');
select throws_like($$ select set_unit_status((select two from u), 'retired', repeat('x', 201)) $$,
                   'Keep the reason to 200 characters', 'of at most 200 characters');
select throws_like($$ select set_unit_status((select two from u), 'in_stock', 'Already here') $$,
                   'This frame is already in stock', 'a frame can''t move to where it is');
select throws_like($$ select set_unit_status((select two from u), 'sold', 'Sold it') $$,
                   'A frame can be put in stock, in the demo fleet or retired here (not "sold")',
                   'selling happens at the register, not here');

-- A sold frame stays sold; the sale is in its history.
select record_sale(jsonb_build_array(jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2',
                                                        'product_unit_id', (select two from u), 'qty', 1, 'unit_price', 250)),
                   '00000000-0000-0000-0000-0000000000c1',
                   '[{"method":"cash","amount":270.63}]'::jsonb, null);
select results_eq(
  $$ select from_status, to_status, sale_id is not null from unit_status_changes
      where product_unit_id = (select two from u) and to_status = 'sold' $$,
  $$ values ('in_stock'::text, 'sold'::text, true) $$,
  'a sale is recorded in the frame''s history, with the sale');
select throws_like($$ select set_unit_status((select two from u), 'retired', 'Gone') $$,
                   'This frame is sold, so it can''t be moved here', 'a sold frame can''t be retired here');

-- ---------------------------------------------------------------------------
-- Who can change what
-- ---------------------------------------------------------------------------
select throws_like($$ insert into unit_status_changes (product_unit_id, to_status) values ((select one from u), 'sold') $$,
                   '%permission denied%', 'staff can''t write history directly');
select is((select count(*)::int from unit_status_changes where product_unit_id = (select one from u)), 4,
          'staff can read a frame''s whole history');

select tests.act_as_anon();
select throws_like($$ select set_unit_status('00000000-0000-0000-0000-000000000001', 'demo', 'x') $$,
                   '%permission denied%', 'visitors can''t move frames');

select * from finish();
rollback;
