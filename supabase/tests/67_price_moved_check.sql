-- A catalog price that moves while the ticket is open is caught at payment (0105).
begin;
\ir helpers/setup.psql

select plan(5);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- The register showed the string at $20 (its list price then).
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20,"list_price":20}]'::jsonb,
                        null, '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'a sale at the price the register showed goes through');

-- The catalog price goes up to $22 while the cashier is taking payment.
select tests.clear_authentication();
update products set sell_price = 22 where id = '00000000-0000-0000-0000-0000000000b1';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20,"list_price":20}]'::jsonb,
                        null, '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'P0001', 'A price changed in the catalog while this ticket was open: check the ticket and take payment again',
  'the moved price is caught instead of saved as a price change nobody made');
select is((select count(*)::int from sale_lines where list_price = 22 and unit_price = 20), 0,
          'nothing was saved');

-- Back on the ticket the register shows $22; a price change typed there is the cashier's own.
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20,"list_price":22}]'::jsonb,
                        null, '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'with the new list price shown, a lower price is a price change the cashier made');

-- A line without list_price (older screens, exchanges) works as before.
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":22}]'::jsonb,
                        null, '[{"method":"cash","amount":23.82}]'::jsonb, null) $$,
  'a line without the list price shown is not checked');

select * from finish();
rollback;
