-- Stock quantities (code review #29): received and adjusted quantities are a
-- whole number or a half, the unit the imported string stock already uses.
begin;
\ir helpers/setup.psql

select plan(8);

-- b1 = Test String 16, 10 on hand (setup.psql).
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_like(
  $$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 0.0001, null, null, null) $$,
  '%Quantity 0.0001 must be a whole number or a half, like 2 or 2.5%', 'a tiny received quantity is refused');
select throws_like(
  $$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 1.37, null, null, null) $$,
  '%Quantity 1.37 must be a whole number or a half%', 'a typo like 1.37 is refused');
select throws_like(
  $$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -2.25, null) $$,
  '%Quantity -2.25 must be a whole number or a half%', 'adjustments too');
select lives_ok($$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 0.5, null, null, null) $$,
                'half a unit can be received');
select lives_ok($$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -1.5, null) $$,
                'and adjusted');
select lives_ok($$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 3.000, null, null, null) $$,
                'trailing zeros are fine');
select is((select sum(qty) from inventory_txns where product_id = '00000000-0000-0000-0000-0000000000b1'),
          12.000::numeric, 'on hand is 10 + 0.5 - 1.5 + 3');

select tests.clear_authentication();
select ok(not has_function_privilege('authenticated', 'require_half_units(numeric, text)', 'execute'),
          'the quantity check is internal');

select * from finish();
rollback;
