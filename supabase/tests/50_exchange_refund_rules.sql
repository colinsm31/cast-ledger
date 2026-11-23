-- An exchange's credit is refunded the way the original sale was paid
-- (Phase 3D review, 0081), and an exchange can't load a gift card.
begin;
\ir helpers/setup.psql

select plan(7);

-- An overgrip at $30 (the $20 string is in the fixtures); both taxed at 8.25%.
insert into products (id, category_id, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 30);
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b7', 10);
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-50');

create function tests.line(p_product uuid, p_qty integer, p_price numeric)
returns jsonb language sql as $$ select jsonb_build_object('product_id', p_product, 'qty', p_qty, 'unit_price', p_price) $$;
create function tests.return_of(p_sale uuid, p_product uuid, p_qty integer)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'sale_line_id', (select id from sale_lines where sale_id = p_sale and product_id = p_product), 'qty', p_qty));
$$;
grant execute on function tests.line(uuid, integer, numeric), tests.return_of(uuid, uuid, integer) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Four strings ($80 + $6.60): $30 on a card, $56.60 cash.
create temp table a as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 4, 20)),
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"credit","amount":30},{"method":"cash","amount":56.60}]'::jsonb, null) as id;
grant select on a to authenticated;

-- One string ($21.65) swapped for an overgrip ($32.48): the customer pays $10.83 cash.
create temp table x as select record_exchange(
  (select id from a), tests.return_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 1),
  jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 1, 30)),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":10.83}]'::jsonb, '[]'::jsonb, null) as r;
grant select on x to authenticated;
create temp table b as select ((select r from x)->>'sale_id')::uuid as id;
grant select on b to authenticated;

-- Two more strings come back on the original ($43.30): $20 to the card, $23.30 cash.
-- The original now has $10 left on the card and $33.30 in cash.
select lives_ok(
  $$ select record_refund((select id from a), tests.return_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 2),
       '[{"method":"credit","amount":20},{"method":"cash","amount":23.30}]'::jsonb, null, null) $$,
  'two strings come back on the original sale');

-- ---------------------------------------------------------------------------
-- Refunding the exchange's new sale ($32.48: $21.65 credit + $10.83 cash)
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_refund((select id from b), tests.return_of((select id from b), '00000000-0000-0000-0000-0000000000b7', 1),
       '[{"method":"credit","amount":10.01},{"method":"cash","amount":22.47}]'::jsonb, null, null) $$,
  'Refunding more to credit than the sale took that way is a payment-type change; give a reason',
  'the credit can go back to the card only as far as the original has left on it ($10)');
select throws_like(
  $$ select record_refund((select id from b), tests.return_of((select id from b), '00000000-0000-0000-0000-0000000000b7', 1),
       '[{"method":"store_credit","amount":32.48}]'::jsonb, null, null) $$,
  '%store_credit than the sale took that way is a payment-type change%',
  'and not to a payment type the original wasn''t paid with');
create temp table rb as select record_refund((select id from b),
  tests.return_of((select id from b), '00000000-0000-0000-0000-0000000000b7', 1),
  '[{"method":"credit","amount":10},{"method":"cash","amount":22.48}]'::jsonb, null, null) as id;
grant select on rb to authenticated;
select is((select method_change_reason from refunds where id = (select id from rb)), null,
          'the way the original was paid, it goes back with no reason');
select results_eq(
  $$ select method, amount from refund_payments where refund_id = (select id from rb) order by method $$,
  $$ values ('cash'::text, 22.48::numeric), ('credit'::text, 10.00::numeric) $$,
  '$10 to the card and $22.48 cash');

-- ---------------------------------------------------------------------------
-- An exchange can't load a gift card
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_exchange(
       (select id from a), tests.return_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 1),
       '[{"gift_card_id":"00000000-0000-0000-0000-0000000000e1","qty":1,"unit_price":21.65}]'::jsonb,
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) $$,
  'An exchange can''t load a gift card: refund the items onto the card instead',
  'the return''s credit can''t become gift card money');
select is((select count(*)::int from gift_card_txns where gift_card_id = '00000000-0000-0000-0000-0000000000e1'), 0,
          'nothing reaches the card');

select * from finish();
rollback;
