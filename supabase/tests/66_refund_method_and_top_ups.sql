-- A refund paid back a different way is on record; adding value is an admin's (0104).
begin;
\ir helpers/setup.psql

select plan(10);

insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000006e1', 'GC-TOPUP');

create function tests.line(p_product uuid, p_qty integer, p_price numeric)
returns jsonb language sql immutable as $$ select jsonb_build_object('product_id', p_product, 'qty', p_qty, 'unit_price', p_price) $$;
grant execute on function tests.line(uuid, integer, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Adding value
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select adjust_gift_card('00000000-0000-0000-0000-0000000006e1', 25, null) $$,
                 '42501', 'Only an admin can add value to a gift card', 'staff can''t add value to a gift card');
select throws_ok($$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 25, null) $$,
                 '42501', 'Only an admin can add store credit', 'or add store credit');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select is(adjust_gift_card('00000000-0000-0000-0000-0000000006e1', 25, null), 25::numeric,
          'an admin adds value, no reason needed');
select is(add_store_credit('00000000-0000-0000-0000-0000000000c1', 10, null), 10::numeric,
          'and store credit');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is(adjust_gift_card('00000000-0000-0000-0000-0000000006e1', -5, null), 20::numeric,
          'staff can still take value off a gift card');

-- ---------------------------------------------------------------------------
-- Refunds paid back a different way
-- ---------------------------------------------------------------------------
-- A string paid by card ($21.65), refunded half to cash and half to card;
-- another paid in cash, refunded to cash.
create temp table card_sale as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  null, '[{"method":"credit","amount":21.65}]'::jsonb, null) as id;
create temp table cash_sale as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  null, '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
grant select on card_sale, cash_sale to authenticated;

create temp table changed as select record_refund((select id from card_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = (select id from card_sale)), 'qty', 1)),
  '[{"method":"cash","amount":10.65},{"method":"credit","amount":11}]'::jsonb, null, null) as id;
create temp table same as select record_refund((select id from cash_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = (select id from cash_sale)), 'qty', 1)),
  '[{"method":"cash","amount":21.65}]'::jsonb, null, null) as id;
grant select on changed, same to authenticated;

select is((select method_changed_to from refunds where id = (select id from changed)), array['cash'],
          'a card sale refunded partly in cash is marked, with no reason typed');
select is((select method_change_reason from refunds where id = (select id from changed)), null::text,
          'and no reason is made up');
select is((select method_changed_to from refunds where id = (select id from same)), null::text[],
          'a refund paid back the way the sale was paid isn''t marked');
select tests.clear_authentication();

-- The discounts report lists it, with who and "(none)".
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select kind, made_by, item, amount, reason
       from report_price_changes(now() - interval '1 hour', now() + interval '1 hour')
      where kind = 'payment_type_change' $$,
  $$ values ('payment_type_change'::text, 'staff@test.local'::text, 'Refund paid by cash'::text, null::numeric, '(none)'::text) $$,
  'the discounts report lists the refund paid back a different way');
select is((select count(*)::int from report_price_changes(now() - interval '1 hour', now() + interval '1 hour')
            where kind <> 'payment_type_change'), 0, 'and nothing else from these sales');

select * from finish();
rollback;
