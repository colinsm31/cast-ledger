-- Returning a sold racquet frame (Phase 3B).
begin;
\ir helpers/setup.psql

select plan(16);

create function tests.refund_frame(p_sale uuid, p_line uuid, p_amount numeric, p_extra jsonb default '{}')
returns uuid language sql as $$
  select record_refund(p_sale, jsonb_build_array(jsonb_build_object('sale_line_id', p_line, 'qty', 1) || p_extra),
                       jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', p_amount)), 'Changed mind', null);
$$;
grant execute on function tests.refund_frame(uuid, uuid, numeric, jsonb) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '["RQ-1", "RQ-2", "RQ-3"]');
create temp table u as
  select (select id from product_units where barcode = 'RQ-1') as one,
         (select id from product_units where barcode = 'RQ-2') as two,
         (select id from product_units where barcode = 'RQ-3') as three;
grant select on u to authenticated;

-- Two frames on one sale ($500 + 8.25% = $541.25), the third on another.
create temp table s as select
  record_sale(jsonb_build_array(
                jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2', 'product_unit_id', (select one from u),
                                   'qty', 1, 'unit_price', 250),
                jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2', 'product_unit_id', (select two from u),
                                   'qty', 1, 'unit_price', 250)),
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":541.25}]'::jsonb, null) as pair,
  record_sale(jsonb_build_array(
                jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2', 'product_unit_id', (select three from u),
                                   'qty', 1, 'unit_price', 250)),
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":270.63}]'::jsonb, null) as single;
grant select on s to authenticated;
create temp table l as select
  (select id from sale_lines where product_unit_id = (select one from u)) as one,
  (select id from sale_lines where product_unit_id = (select two from u)) as two,
  (select id from sale_lines where product_unit_id = (select three from u)) as three;
grant select on l to authenticated;

-- ---------------------------------------------------------------------------
-- Back in stock
-- ---------------------------------------------------------------------------
create temp table r as select tests.refund_frame((select pair from s), (select one from l), 270.63) as first_refund;
grant select on r to authenticated;
select results_eq($$ select subtotal, tax from refunds where id = (select first_refund from r) $$,
                  $$ values (250.00::numeric, 20.63::numeric) $$, 'the frame is refunded at its price and the sale''s tax');
select results_eq($$ select status, sale_id, customer_id from product_units where id = (select one from u) $$,
                  $$ values ('in_stock'::text, null::uuid, null::uuid) $$, 'the frame is back in stock, nobody''s');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b2'), 1::numeric,
          'and counts as on hand again');
select results_eq(
  $$ select from_status, to_status, reason, refund_id from unit_status_changes
      where product_unit_id = (select one from u) and from_status = 'sold' $$,
  $$ values ('sold'::text, 'in_stock'::text, 'Returned'::text, (select first_refund from r)) $$,
  'its history records the return with the refund');
select is((select is_active from customer_rackets where product_unit_id = (select one from u)), false,
          'it''s no longer the customer''s racquet');
select is((select count(*)::int from inventory_txns where product_id = '00000000-0000-0000-0000-0000000000b2'), 0,
          'no stock-ledger row is written for a frame');
select results_eq($$ select kind from resolve_barcode('RQ-1') $$, $$ values ('unit'::text) $$,
                  'scanning it finds the frame again, not the old racquet');

select throws_like($$ select tests.refund_frame((select pair from s), (select one from l), 270.63) $$,
                   '%Cannot return 1 of line (only 0 remaining)%', 'a frame can''t be returned twice');

-- ---------------------------------------------------------------------------
-- Damaged: retired
-- ---------------------------------------------------------------------------
savepoint no_reason;
select lives_ok(
  $$ select tests.refund_frame((select pair from s), (select two from l), 270.62, '{"unit_status":"retired"}') $$,
  'a damaged frame can be retired with no reason (0093)');
rollback to savepoint no_reason;
select throws_like($$ select tests.refund_frame((select pair from s), (select two from l), 270.62, '{"unit_status":"demo"}') $$,
                   'A returned frame goes back in stock or is retired (not "demo")', 'it goes back in stock or is retired');
select lives_ok(
  $$ select tests.refund_frame((select pair from s), (select two from l), 270.62,
                               '{"unit_status":"retired","unit_reason":" Cracked at the throat "}') $$,
  'a damaged frame is returned and retired');
select results_eq(
  $$ select u.status, c.reason from product_units u
       join unit_status_changes c on c.product_unit_id = u.id and c.refund_id is not null
      where u.id = (select two from u) $$,
  $$ values ('retired'::text, 'Cracked at the throat'::text) $$, 'with the reason in its history');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b2'), 1::numeric,
          'a retired frame doesn''t count as on hand');

-- ---------------------------------------------------------------------------
-- A racquet with a string job open
-- ---------------------------------------------------------------------------
insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ((select id from customer_rackets where product_unit_id = (select three from u)),
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50, 38);
select throws_like($$ select tests.refund_frame((select single from s), (select three from l), 270.63) $$,
                   'This racquet has a string job open: deliver or cancel it before returning the frame',
                   'a racquet being strung can''t be returned');
select cancel_string_job((select id from string_jobs where customer_racket_id =
                           (select id from customer_rackets where product_unit_id = (select three from u))));
select lives_ok($$ select tests.refund_frame((select single from s), (select three from l), 270.63) $$,
                'once the job is cancelled it can');

select is((select count(*)::int from refund_lines rl join refunds rf on rf.id = rl.refund_id where rf.sale_id = (select pair from s)), 2,
          'each return is recorded as a refund line');

select * from finish();
rollback;
