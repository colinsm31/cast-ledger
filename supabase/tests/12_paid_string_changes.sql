-- Changing the strings on a paid, not-yet-strung job and settling the
-- difference (commit 2b): charge more, give back less, payment-type limits,
-- tax, discounts carrying over, and the guards around it.
begin;
\ir helpers/setup.psql

select plan(36);

-- Strings (real Strings category, 10 of each on hand). b1 ($20) is in the fixtures.
insert into products (id, category_id, brand, name, sell_price, attributes)
select v.id, c.id, 'TestBrand', v.name, v.price, v.attrs::jsonb
  from categories c,
       (values
         ('00000000-0000-0000-0000-0000000000b4'::uuid, 'Same Price', 20, '{"color":"Black","gauge":"16"}'),
         ('00000000-0000-0000-0000-0000000000b5'::uuid, 'Premium',    43, '{"color":"Red","gauge":"16"}'),
         ('00000000-0000-0000-0000-0000000000b6'::uuid, 'Budget',     10, '{"color":"White","gauge":"17"}')
       ) as v(id, name, price, attrs)
 where c.name = 'Strings';
insert into products (id, category_id, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 20);
insert into inventory_txns (txn_type, product_id, qty)
select 'receive', id, 10 from products
 where id in ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000b5',
              '00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000b7');

insert into customers (id, first_name, last_name) values ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Tester');
insert into store_credit_txns (customer_id, amount, reason) values ('00000000-0000-0000-0000-0000000000c1', 25, 'fixture');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Pat 1'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Pat 3'),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000c1', 'Pat 4'),
  ('00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-0000000000c1', 'Pat 5'),
  ('00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-0000000000c1', 'Pat 6');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Job 1: b1 / b1 ($20 of strings), paid at a $15 register discount.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20);
select is((select strings_price from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 20.00::numeric,
          'entering a job records its strings'' catalog price');

create temp table sale_a as
select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":15}]'::jsonb,
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":15}]'::jsonb, null) as id;
select results_eq(
  $$ select j.price, sl.taxable from string_jobs j join sale_lines sl on sl.string_job_id = j.id
      where j.id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values (15.00::numeric, false) $$,
  'paying a job saves what was charged as its price, and the line as untaxed (stringing tax off)');

-- ---------------------------------------------------------------------------
-- Direct edits on a paid job
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ update string_jobs set main_product_id = '00000000-0000-0000-0000-0000000000b4',
                            cross_product_id = '00000000-0000-0000-0000-0000000000b4'
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'a paid job can change to strings of the same price directly');
select throws_like(
  $$ update string_jobs set main_product_id = '00000000-0000-0000-0000-0000000000b5',
                            cross_product_id = '00000000-0000-0000-0000-0000000000b5'
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%paid for strings costing $20.00; the new strings cost $43.00%',
  'a paid job can''t change to strings of a different price directly');
select lives_ok(
  $$ update string_jobs set main_tension = 56 where id = '00000000-0000-0000-0000-000000000f01' $$,
  'a paid job''s tension can still be edited');
select throws_like(
  $$ update string_jobs set price = 0 where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%price of a paid string job%', 'a paid job''s price still can''t be edited directly');

-- ---------------------------------------------------------------------------
-- More expensive strings: charge the difference
-- ---------------------------------------------------------------------------
select is(
  string_change_quote('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
                      '00000000-0000-0000-0000-0000000000b5') - 'old_price' - 'new_price',
  '{"direction":"charge","amount":23.00,"tax":0,"total":23.00,"customer_id":"00000000-0000-0000-0000-0000000000c1"}'::jsonb,
  'changing $20 strings to $43 strings owes $23 (no stringing tax)');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
       '00000000-0000-0000-0000-0000000000b5', 55, 53, '[{"method":"cash","amount":20}]'::jsonb) $$,
  '%must equal the string change total%', 'the wrong amount is refused');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
       '00000000-0000-0000-0000-0000000000b5', 55, 53, '[{"method":"gift_card","amount":23}]'::jsonb) $$,
  '%cash, credit or store credit%', 'a gift card can''t pay for a string change');
select is((select main_product_id from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
          '00000000-0000-0000-0000-0000000000b4'::uuid, 'a refused change leaves the strings as they were');

create temp table charge_result as
select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
       '00000000-0000-0000-0000-0000000000b5', 55, 53,
       '[{"method":"cash","amount":13},{"method":"store_credit","amount":10}]'::jsonb) as r;
select is((select r->>'direction' from charge_result), 'charge', 'the difference is charged (cash + store credit)');
select results_eq(
  $$ select main_product_id, cross_product_id, price, strings_price, status, main_specs
       from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values ('00000000-0000-0000-0000-0000000000b5'::uuid, '00000000-0000-0000-0000-0000000000b5'::uuid,
             38.00::numeric, 43.00::numeric, 'entered'::text, '{"color":"Red","gauge":"16"}'::jsonb) $$,
  'the strings change; the price moves by the difference, so the $5 discount carries over');
select results_eq(
  $$ select s.customer_id, s.subtotal, s.tax, s.payment_method, sl.kind, sl.qty, sl.unit_price
       from sales s join sale_lines sl on sl.sale_id = s.id
      where s.id = (select (r->>'sale_id')::uuid from charge_result) $$,
  $$ values ('00000000-0000-0000-0000-0000000000c1'::uuid, 23.00::numeric, 0.00::numeric, 'split'::text,
             'string_change'::text, 1, 23.00::numeric) $$,
  'a sale with a "string change" line records the charge for the customer who paid');
select is((select balance from customer_store_credit where customer_id = '00000000-0000-0000-0000-0000000000c1'),
          15.00::numeric, 'the store credit used comes off Pat''s balance');
select results_eq(
  $$ select product_id, committed from product_available
      where product_id in ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000b5')
      order by product_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000b4'::uuid, 0), ('00000000-0000-0000-0000-0000000000b5'::uuid, 1) $$,
  'the old string is released and the new one set aside');

-- ---------------------------------------------------------------------------
-- Cheaper strings: give back the difference, newest sale first
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update sales set sold_at = sold_at - interval '1 hour' where id = (select id from sale_a);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select is(
  (string_change_quote('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b6',
                       '00000000-0000-0000-0000-0000000000b6')
     -> 'allocations') @> '[{"amount":23.00},{"amount":10.00}]'::jsonb
  and jsonb_array_length(string_change_quote('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b6',
                       '00000000-0000-0000-0000-0000000000b6') -> 'allocations') = 2,
  true, '$43 → $10 gives back $33: $23 from the string-change sale, then $10 from the original');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6', 55, 53, '[{"method":"cash","amount":33}]'::jsonb) $$,
  '%Giving back more as cash than the sale took%',
  'giving back more cash than a sale took that way needs a reason');
select lives_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6', 55, 53,
       '[{"method":"store_credit","amount":10},{"method":"cash","amount":23}]'::jsonb) $$,
  'within each payment type''s limit, no reason is needed');
select results_eq(
  $$ select r.subtotal, r.tax, rl.kind, rl.unit_price
       from refunds r join refund_lines rl on rl.refund_id = r.id
      where r.reason = 'String change' order by r.subtotal desc $$,
  $$ values (23.00::numeric, 0.00::numeric, 'string_change'::text, 23.00::numeric),
            (10.00::numeric, 0.00::numeric, 'string_change'::text, 10.00::numeric) $$,
  'one "string change" refund per paying sale');
select is((select balance from customer_store_credit where customer_id = '00000000-0000-0000-0000-0000000000c1'),
          25.00::numeric, 'store credit given back goes to the paying customer');
select results_eq(
  $$ select price, strings_price from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values (5.00::numeric, 10.00::numeric) $$,
  'the job is now $10 strings at $5 (the discount still applies)');

-- ---------------------------------------------------------------------------
-- Stringing tax, and a payment-type change with a reason
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update settings set tax_stringing = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000f3',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 50, 50, 20);
select lives_ok(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f03","qty":1,"unit_price":20}]'::jsonb,
                        '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'a taxed stringing sale');
select is(
  (string_change_quote('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000b5',
                       '00000000-0000-0000-0000-0000000000b5') ->> 'total')::numeric,
  24.90::numeric, 'with stringing taxed, $23 more is $24.90 with tax');
select is(
  (string_change_quote('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000b6',
                       '00000000-0000-0000-0000-0000000000b6') ->> 'total')::numeric,
  10.83::numeric, '$10 less gives back $10.83 with its tax');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6', 50, 50, '[{"method":"credit","amount":10.83}]'::jsonb) $$,
  '%more as credit than the sale took%', 'giving back to a card on a cash sale needs a reason');
select lives_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6', 50, 50, '[{"method":"credit","amount":10.83}]'::jsonb,
       'Customer asked for it on their card') $$,
  'with a reason it goes through');
select is((select method_change_reason from refunds r join refund_lines rl on rl.refund_id = r.id
            join sale_lines sl on sl.id = rl.sale_line_id where sl.string_job_id = '00000000-0000-0000-0000-000000000f03'),
          'Customer asked for it on their card', 'and the reason is stored on the refund');

-- ---------------------------------------------------------------------------
-- Store credit when the paying sale had no customer
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update settings set tax_stringing = false where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f04', '00000000-0000-0000-0000-0000000000f4',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 50, 50, 20);
select lives_ok(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f04","qty":1,"unit_price":20}]'::jsonb,
                        null, '[{"method":"cash","amount":20}]'::jsonb, null) $$,
  'a job paid on an unidentified ticket');
select lives_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f04', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6', 50, 50, '[{"method":"store_credit","amount":10}]'::jsonb,
       'Store credit instead of cash') $$,
  'store credit can still be given back');
select is((select balance from customer_store_credit where customer_id = '00000000-0000-0000-0000-0000000000c1'),
          35.00::numeric, '... to the racquet''s owner');

-- ---------------------------------------------------------------------------
-- Product refunds: tax counts only taxable refunded amounts
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f05', '00000000-0000-0000-0000-0000000000f5',
        '00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000b5', 50, 50, 43);
create temp table mixed_sale as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b7","qty":2,"unit_price":20},
                     {"string_job_id":"00000000-0000-0000-0000-000000000f05","qty":1,"unit_price":43}]'::jsonb,
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":86.30}]'::jsonb, null) as id;
select lives_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f05', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6', 50, 50, '[{"method":"cash","amount":33}]'::jsonb) $$,
  'an untaxed $33 give-back on a sale that also had taxed products');
create temp table product_refund as
select record_refund(
  (select id from mixed_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id',
    (select id from sale_lines where sale_id = (select id from mixed_sale) and product_id is not null), 'qty', 1)),
  '[{"method":"cash","amount":21.65}]'::jsonb, 'return', null) as id;
select is((select tax from refunds where id = (select id from product_refund)), 1.65::numeric,
          'returning one $20 overgrip afterwards refunds $1.65 tax, not tax on the untaxed give-back too');

-- ---------------------------------------------------------------------------
-- Who and what can use it
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f06', '00000000-0000-0000-0000-0000000000f6',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 50, 50, 20);
select throws_like(
  $$ select string_change_quote('00000000-0000-0000-0000-000000000f06', '00000000-0000-0000-0000-0000000000b6',
       '00000000-0000-0000-0000-0000000000b6') $$,
  '%Only a paid job that hasn''t been strung%', 'an unpaid job changes strings directly, not through String change');
-- A job needs a stringer before it's complete (0051).
update string_jobs set strung_by = 'Test Stringer' where id = '00000000-0000-0000-0000-000000000f03';
select lives_ok($$ select advance_string_job('00000000-0000-0000-0000-000000000f03', 'complete') $$, 'job 3 is strung');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000b1',
       '00000000-0000-0000-0000-0000000000b1', 50, 50, '[]'::jsonb) $$,
  '%Only a paid job that hasn''t been strung%', 'a strung job can''t change strings');

select tests.clear_authentication();
select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b1',
       '00000000-0000-0000-0000-0000000000b1', 50, 50, '[]'::jsonb) $$,
  '42501', null, 'an account without staff access can''t change strings');
select tests.clear_authentication();

select * from finish();
rollback;
