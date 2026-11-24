-- An exchange's credit keeps the payment types it came from (Phase 3D review,
-- 0081 → 0082): it uses up the original sale's room that way and gives the
-- new sale exactly that room, so one credit can't go back twice. And an
-- exchange can't load a gift card.
begin;
\ir helpers/setup.psql

select plan(15);

-- An overgrip at $30 ($32.48 with tax; the $20 string is in the fixtures).
insert into products (id, category_id, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 30);
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b7', 20);
insert into gift_cards (id, code) values
  ('00000000-0000-0000-0000-0000000000e1', 'GC-50'),
  ('00000000-0000-0000-0000-0000000000e2', 'GC-50B'),
  ('00000000-0000-0000-0000-0000000000e3', 'GC-50C');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e2', 50, 'load');

create function tests.line(p_product uuid, p_qty integer, p_price numeric)
returns jsonb language sql as $$ select jsonb_build_object('product_id', p_product, 'qty', p_qty, 'unit_price', p_price) $$;
create function tests.return_of(p_sale uuid, p_product uuid, p_qty integer)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'sale_line_id', (select id from sale_lines where sale_id = p_sale and product_id = p_product), 'qty', p_qty));
$$;
create function tests.refund_of(p_sale uuid, p_product uuid, p_qty integer, p_payments jsonb)
returns uuid language sql as $$ select record_refund(p_sale, tests.return_of(p_sale, p_product, p_qty), p_payments, null, null) $$;
create function tests.swap(p_sale uuid, p_back uuid, p_new uuid, p_new_price numeric, p_payments jsonb default '[]')
returns uuid language sql as $$
  select (record_exchange(p_sale, tests.return_of(p_sale, p_back, 1), jsonb_build_array(tests.line(p_new, 1, p_new_price)),
                          '00000000-0000-0000-0000-0000000000c1', p_payments, '[]'::jsonb, null)->>'sale_id')::uuid;
$$;
grant execute on function tests.line(uuid, integer, numeric), tests.return_of(uuid, uuid, integer),
  tests.refund_of(uuid, uuid, integer, jsonb), tests.swap(uuid, uuid, uuid, numeric, jsonb) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- Four strings ($86.60): $30 on a card, $56.60 cash. One ($21.65) is swapped
-- for an overgrip ($32.48), the customer paying $10.83 cash.
-- ---------------------------------------------------------------------------
create temp table a as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 4, 20)),
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"credit","amount":30},{"method":"cash","amount":56.60}]'::jsonb, null) as id;
grant select on a to authenticated;
create temp table b as select tests.swap((select id from a), '00000000-0000-0000-0000-0000000000b1',
  '00000000-0000-0000-0000-0000000000b7', 30, '[{"method":"cash","amount":10.83}]') as id;
grant select on b to authenticated;

select results_eq(
  $$ select rp.method, rp.amount, rp.source_method from refund_payments rp join refunds r on r.id = rp.refund_id
      where r.sale_id = (select id from a) $$,
  $$ values ('exchange'::text, 21.65::numeric, 'cash'::text) $$,
  'the credit comes out of the original''s cash first');
select results_eq(
  $$ select method, amount, source_method from sale_payments where sale_id = (select id from b) order by method $$,
  $$ values ('cash'::text, 10.83::numeric, null::text), ('exchange'::text, 21.65::numeric, 'cash'::text) $$,
  'and the new sale''s exchange payment says so');

-- Two more strings back on the original ($43.30): $20 to the card, $23.30 cash.
-- It has $10 left on the card and $11.65 in cash ($56.60 − $21.65 − $23.30).
select lives_ok(
  $$ select tests.refund_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 2,
       '[{"method":"credit","amount":20},{"method":"cash","amount":23.30}]') $$,
  'two strings come back on the original sale');

-- ---------------------------------------------------------------------------
-- The new sale ($32.48: $21.65 credit from cash + $10.83 cash)
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select tests.refund_of((select id from b), '00000000-0000-0000-0000-0000000000b7', 1,
       '[{"method":"credit","amount":10},{"method":"cash","amount":22.48}]') $$,
  'Refunding more to credit than the sale took that way is a payment-type change; give a reason',
  'the new sale can''t send its credit to the card: it came out of cash');
create temp table rb as select tests.refund_of((select id from b), '00000000-0000-0000-0000-0000000000b7', 1,
  '[{"method":"cash","amount":32.48}]') as id;
grant select on rb to authenticated;
select is((select method_change_reason from refunds where id = (select id from rb)), null,
          'all $32.48 goes back as cash with no reason');

-- ---------------------------------------------------------------------------
-- The original's last string ($21.65): the credit was counted there too
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select tests.refund_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 1,
       '[{"method":"credit","amount":10.01},{"method":"cash","amount":11.64}]') $$,
  'Refunding more to credit than the sale took that way is a payment-type change; give a reason',
  'no more than the $10 left goes back to the card');
select throws_like(
  $$ select tests.refund_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 1,
       '[{"method":"cash","amount":21.65}]') $$,
  'Refunding more to cash than the sale took that way is a payment-type change; give a reason',
  'nor more than the $11.65 cash left (the exchange used the rest)');
select lives_ok(
  $$ select tests.refund_of((select id from a), '00000000-0000-0000-0000-0000000000b1', 1,
       '[{"method":"credit","amount":10},{"method":"cash","amount":11.65}]') $$,
  '$10 to the card and $11.65 cash goes back with no reason');
select results_eq(
  $$ select coalesce(rp.source_method, rp.method), sum(rp.amount)
       from refund_payments rp join refunds r on r.id = rp.refund_id
      where r.sale_id in ((select id from a), (select id from b)) and rp.method <> 'exchange'
      group by 1 order by 1 $$,
  $$ values ('cash'::text, 67.43::numeric), ('credit'::text, 30.00::numeric) $$,
  'in all, the card gets back its $30 and cash its $56.60 + $10.83, never more');

-- ---------------------------------------------------------------------------
-- A gift-card-paid original, exchanged twice
-- ---------------------------------------------------------------------------
create temp table g as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b7', 1, 30)),
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"gift_card","amount":32.48,"gift_card_id":"00000000-0000-0000-0000-0000000000e2"}]'::jsonb, null) as id;
grant select on g to authenticated;
create temp table g1 as select tests.swap((select id from g), '00000000-0000-0000-0000-0000000000b7',
  '00000000-0000-0000-0000-0000000000b7', 30) as id;
grant select on g1 to authenticated;
create temp table g2 as select tests.swap((select id from g1), '00000000-0000-0000-0000-0000000000b7',
  '00000000-0000-0000-0000-0000000000b7', 30) as id;
grant select on g2 to authenticated;
select results_eq(
  $$ select source_method, source_gift_card_id, amount from sale_payments where sale_id = (select id from g2) $$,
  $$ values ('gift_card'::text, '00000000-0000-0000-0000-0000000000e2'::uuid, 32.48::numeric) $$,
  'after two exchanges the credit still says it came off card GC-50B');
select throws_like(
  $$ select tests.refund_of((select id from g2), '00000000-0000-0000-0000-0000000000b7', 1,
       '[{"method":"gift_card","amount":32.48,"gift_card_id":"00000000-0000-0000-0000-0000000000e3"}]') $$,
  'Refunding more to gift card GC-50C than the sale took that way is a payment-type change; give a reason',
  'it can''t go onto another card without a reason');
create temp table rg as select tests.refund_of((select id from g2), '00000000-0000-0000-0000-0000000000b7', 1,
  '[{"method":"gift_card","amount":32.48,"gift_card_id":"00000000-0000-0000-0000-0000000000e2"}]') as id;
grant select on rg to authenticated;
select is((select method_change_reason from refunds where id = (select id from rg)), null,
          'back onto GC-50B it needs no reason');
select is((select sum(amount) from gift_card_txns where gift_card_id = '00000000-0000-0000-0000-0000000000e2'), 50.00::numeric,
          'and the card holds its $50 again');

-- ---------------------------------------------------------------------------
-- An exchange can't load a gift card
-- ---------------------------------------------------------------------------
create temp table s2 as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":21.65}]'::jsonb, null) as id;
grant select on s2 to authenticated;
select throws_like(
  $$ select record_exchange(
       (select id from s2), tests.return_of((select id from s2), '00000000-0000-0000-0000-0000000000b1', 1),
       '[{"gift_card_id":"00000000-0000-0000-0000-0000000000e1","qty":1,"unit_price":21.65}]'::jsonb,
       '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) $$,
  'An exchange can''t load a gift card: refund the items onto the card instead',
  'the return''s credit can''t become gift card money');
select is((select count(*)::int from gift_card_txns where gift_card_id = '00000000-0000-0000-0000-0000000000e1'), 0,
          'nothing reaches the card');

select * from finish();
rollback;
