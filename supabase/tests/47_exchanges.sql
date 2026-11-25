-- Exchanges (Phase 3D): return and sell on one ticket, the difference
-- collected or given back.
begin;
\ir helpers/setup.psql

select plan(22);

-- An overgrip at $30 (the $20 string is in the fixtures); both taxed at 8.25%.
insert into products (id, category_id, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 30);
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b7', 10);
select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');

create function tests.line(p_product uuid, p_qty integer, p_price numeric)
returns jsonb language sql as $$ select jsonb_build_object('product_id', p_product, 'qty', p_qty, 'unit_price', p_price) $$;
create function tests.return_of(p_sale uuid, p_product uuid, p_qty integer)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'sale_line_id', (select id from sale_lines where sale_id = p_sale and product_id = p_product), 'qty', p_qty));
$$;
grant execute on function tests.line(uuid, integer, numeric), tests.return_of(uuid, uuid, integer) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Two overgrips on a card ($60 + $4.95), three strings on a card ($60 + $4.95).
create temp table s as select
  record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 2, 30)),
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":64.95}]'::jsonb, null) as grips,
  record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 3, 20)),
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":64.95}]'::jsonb, null) as strings;
grant select on s to authenticated;

-- ---------------------------------------------------------------------------
-- An even swap: one overgrip for another
-- ---------------------------------------------------------------------------
create temp table e1 as select record_exchange(
  (select grips from s), tests.return_of((select grips from s), '00000000-0000-0000-0000-0000000000b7', 1),
  jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 1, 30)),
  '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, 'Wrong size') as x;
grant select on e1 to authenticated;
select is(((select x from e1)->>'credit')::numeric, 32.48, 'the return is worth $32.48 with its tax');
select results_eq(
  $$ select method, amount from refund_payments where refund_id = ((select x from e1)->>'refund_id')::uuid $$,
  $$ values ('exchange'::text, 32.48::numeric) $$, 'all of it moves to the new sale');
select results_eq(
  $$ select payment_method, subtotal + tax, note from sales where id = ((select x from e1)->>'sale_id')::uuid $$,
  $$ values ('exchange'::text, 32.48::numeric, 'Exchange'::text) $$, 'which it pays in full');
select results_eq(
  $$ select refund_id, sale_id, credit from exchanges where id = ((select x from e1)->>'exchange_id')::uuid $$,
  $$ values (((select x from e1)->>'refund_id')::uuid, ((select x from e1)->>'sale_id')::uuid, 32.48::numeric) $$,
  'the exchange ties the two together');
select is((select reason from refunds where id = ((select x from e1)->>'refund_id')::uuid), 'Wrong size',
          'the return keeps its reason');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b7'), 8::numeric,
          'one back in stock, one out again');

-- ---------------------------------------------------------------------------
-- The customer pays the difference
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_exchange(
       (select grips from s), tests.return_of((select grips from s), '00000000-0000-0000-0000-0000000000b7', 1),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 2, 20)),
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) $$,
  'Payments ($32.47) must equal the sale total ($43.30)%', 'the difference must be paid');
create temp table e2 as select record_exchange(
  (select grips from s), tests.return_of((select grips from s), '00000000-0000-0000-0000-0000000000b7', 1),
  jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 2, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":10.83}]'::jsonb, '[]'::jsonb, null) as x;
grant select on e2 to authenticated;
select results_eq(
  $$ select method, amount from sale_payments where sale_id = ((select x from e2)->>'sale_id')::uuid order by method $$,
  $$ values ('cash'::text, 10.83::numeric), ('exchange'::text, 32.47::numeric) $$,
  'the second overgrip ($32.47, the rest of the sale''s tax) pays most of two strings; cash covers $10.83');
select is((select payment_method from sales where id = ((select x from e2)->>'sale_id')::uuid), 'split',
          'a split payment');

-- ---------------------------------------------------------------------------
-- The shop gives the difference back
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_exchange(
       (select strings from s), tests.return_of((select strings from s), '00000000-0000-0000-0000-0000000000b1', 3),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) $$,
  'The return ($64.95) is more than the new items ($21.65): give the difference back on the return',
  'the difference must be given back');
select throws_like(
  $$ select record_exchange(
       (select strings from s), tests.return_of((select strings from s), '00000000-0000-0000-0000-0000000000b1', 3),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[{"method":"credit","amount":70}]'::jsonb, null) $$,
  'The money back ($70.00) is more than the return ($64.95)', 'never more than the return');
savepoint no_reason;
select lives_ok(
  $$ select record_exchange(
       (select strings from s), tests.return_of((select strings from s), '00000000-0000-0000-0000-0000000000b1', 3),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[{"method":"cash","amount":43.30}]'::jsonb, null) $$,
  'cash back on a card sale needs no reason (0093)');
rollback to savepoint no_reason;
create temp table e3 as select record_exchange(
  (select strings from s), tests.return_of((select strings from s), '00000000-0000-0000-0000-0000000000b1', 3),
  jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[{"method":"credit","amount":43.30}]'::jsonb, null) as x;
grant select on e3 to authenticated;
select results_eq(
  $$ select method, amount from refund_payments where refund_id = ((select x from e3)->>'refund_id')::uuid order by method $$,
  $$ values ('credit'::text, 43.30::numeric), ('exchange'::text, 21.65::numeric) $$,
  '$43.30 goes back to the card, $21.65 pays for the new string');
select is((select payment_method from sales where id = ((select x from e3)->>'sale_id')::uuid), 'exchange',
          'the new sale is paid by the exchange alone');

-- ---------------------------------------------------------------------------
-- All or nothing
-- ---------------------------------------------------------------------------
create temp table before as select count(*)::int as refunds from refunds;
grant select on before to authenticated;
select throws_like(
  $$ select record_exchange(
       (select grips from s), tests.return_of((select grips from s), '00000000-0000-0000-0000-0000000000b7', 1),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 1, 30)),
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) $$,
  '%Cannot return 1 of line (only 0 remaining)%', 'nothing left to return on the first sale');
select throws_like(
  $$ select record_exchange(
       ((select x from e3)->>'sale_id')::uuid,
       tests.return_of(((select x from e3)->>'sale_id')::uuid, '00000000-0000-0000-0000-0000000000b1', 1),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-00000000dead', 1, 30)),
       '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":10.83}]'::jsonb, '[]'::jsonb, null) $$,
  'Unknown product_id % in sale line', 'a new sale that fails...');
select is((select count(*)::int from refunds), (select refunds from before), '...leaves no refund behind');

-- An exchange's sale can be exchanged again.
select lives_ok(
  $$ select record_exchange(
       ((select x from e3)->>'sale_id')::uuid,
       tests.return_of(((select x from e3)->>'sale_id')::uuid, '00000000-0000-0000-0000-0000000000b1', 1),
       jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 1, 30)),
       '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":10.83}]'::jsonb, '[]'::jsonb, null) $$,
  'the new string is swapped again, for an overgrip');

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)), null,
                        '[{"method":"exchange","amount":21.65}]'::jsonb, null) $$,
  'Invalid payment method "exchange"', 'only an exchange pays by exchange');
create temp table g as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 1, 30)),
  null, '[{"method":"cash","amount":32.48}]'::jsonb, null) as id;
grant select on g to authenticated;
select throws_like(
  $$ select record_refund((select id from g), tests.return_of((select id from g), '00000000-0000-0000-0000-0000000000b7', 1),
                          '[{"method":"exchange","amount":32.48}]'::jsonb, null, null) $$,
  'Invalid refund method "exchange"', 'a refund can''t be paid out as exchange credit');
select throws_ok($$ insert into exchanges (refund_id, sale_id, credit)
                    select id, sale_id, 0 from refunds limit 1 $$, '42501', null, 'staff can''t write exchanges directly');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(
  $$ select record_exchange((select grips from s), '[]'::jsonb, '[]'::jsonb, null, '[]'::jsonb, '[]'::jsonb, null) $$,
  '42501', null, 'an account waiting for approval can''t exchange');

select * from finish();
rollback;
