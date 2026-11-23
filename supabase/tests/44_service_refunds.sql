-- Refunding a stringing charge (Phase 3D): the job stays on record, marked
-- refunded; tax counts only taxed lines; string-change give-backs come off.
begin;
\ir helpers/setup.psql

select plan(20);

create function tests.refund_line(p_sale uuid, p_line uuid, p_amount numeric, p_qty integer default 1)
returns uuid language sql as $$
  select record_refund(p_sale, jsonb_build_array(jsonb_build_object('sale_line_id', p_line, 'qty', p_qty)),
                       jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', p_amount)), 'Not happy', null);
$$;
grant execute on function tests.refund_line(uuid, uuid, numeric, integer) to authenticated;

insert into products (id, category_id, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 20);
insert into products (id, category_id, brand, name, sell_price, attributes)
select '00000000-0000-0000-0000-0000000000b6', id, 'TestBrand', 'Budget', 10, '{"color":"White","gauge":"17"}'
  from categories where name = 'Strings';
insert into inventory_txns (txn_type, product_id, qty) values
  ('receive', '00000000-0000-0000-0000-0000000000b7', 10),
  ('receive', '00000000-0000-0000-0000-0000000000b6', 10);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Pat 1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Pat 2'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Pat 3');
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-44');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20),
       ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20);

-- One ticket: job 1 ($20, untaxed), an overgrip ($20 + $1.65 tax) and a $25 gift card load.
create temp table s as select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":20},
    {"product_id":"00000000-0000-0000-0000-0000000000b7","qty":1,"unit_price":20},
    {"gift_card_id":"00000000-0000-0000-0000-0000000000e1","qty":1,"unit_price":25}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":66.65}]'::jsonb, null) as id;
grant select on s to authenticated;
create temp table l as select
  (select id from sale_lines where string_job_id = '00000000-0000-0000-0000-000000000f01') as job,
  (select id from sale_lines where product_id = '00000000-0000-0000-0000-0000000000b7') as grip,
  (select id from sale_lines where gift_card_id = '00000000-0000-0000-0000-0000000000e1') as card;
grant select on l to authenticated;

-- ---------------------------------------------------------------------------
-- A job not started yet: the refund cancels it
-- ---------------------------------------------------------------------------
select throws_like($$ select cancel_string_job('00000000-0000-0000-0000-000000000f01') $$,
                   'This string job has been paid: refund its charge from the sale to cancel it',
                   'cancelling a paid job points to the refund');
select throws_like($$ select tests.refund_line((select id from s), (select job from l), 40, 2) $$,
                   'A stringing charge is refunded whole (qty 1)', 'a stringing charge is refunded whole');
select throws_like($$ select tests.refund_line((select id from s), (select job from l), 21.65) $$,
                   '%must equal the refund total (20.00)%', 'untaxed stringing gives back no tax');

create temp table r as select tests.refund_line((select id from s), (select job from l), 20) as job_refund;
grant select on r to authenticated;
select results_eq($$ select subtotal, tax from refunds where id = (select job_refund from r) $$,
                  $$ values (20.00::numeric, 0.00::numeric) $$, 'the job''s charge is refunded without tax');
select results_eq(
  $$ select status, refund_id, refunded_at is not null, cancelled_by from string_jobs
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values ('cancelled'::text, (select job_refund from r), true, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'the job stays on record, cancelled and marked refunded');
select is((select committed from product_available where product_id = '00000000-0000-0000-0000-0000000000b1'), 1,
          'its strings are no longer reserved');
select throws_like($$ select tests.refund_line((select id from s), (select job from l), 20) $$,
                   '%Cannot return 1 of line (only 0 remaining)%', 'a stringing charge is refunded once');

create temp table r2 as select tests.refund_line((select id from s), (select grip from l), 21.65) as grip_refund;
grant select on r2 to authenticated;
select is((select tax from refunds where id = (select grip_refund from r2)),
          1.65::numeric, 'the overgrip, refunded later, gives back all the tax the sale charged');

select throws_like($$ select tests.refund_line((select id from s), (select card from l), 25) $$,
                   'Only product and stringing lines can be returned', 'a gift card load isn''t refunded this way');

-- ---------------------------------------------------------------------------
-- Strung and waiting, then delivered
-- ---------------------------------------------------------------------------
create temp table s2 as select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":20}]'::jsonb, null) as id;
grant select on s2 to authenticated;
update string_jobs set strung_by = 'Test Stringer' where id = '00000000-0000-0000-0000-000000000f02';
select is(advance_string_job('00000000-0000-0000-0000-000000000f02', 'complete'), 'complete', 'job 2 is strung');

select throws_like(
  $$ select record_refund((select id from s2), jsonb_build_array(jsonb_build_object(
       'sale_line_id', (select id from sale_lines where sale_id = (select id from s2)), 'qty', 1)),
       '[{"method":"credit","amount":20}]'::jsonb, null, null) $$,
  'String job J% is strung and waiting: deliver it before refunding its charge', 'a job waiting for pickup is delivered first');
select is(advance_string_job('00000000-0000-0000-0000-000000000f02', 'delivered'), 'delivered', 'and picked up');
select lives_ok(
  $$ select record_refund((select id from s2), jsonb_build_array(jsonb_build_object(
       'sale_line_id', (select id from sale_lines where sale_id = (select id from s2)), 'qty', 1)),
       '[{"method":"credit","amount":20}]'::jsonb, 'Strings broke on day one', null) $$,
  'a delivered job''s charge is refunded');
select results_eq(
  $$ select status, refund_id is not null from string_jobs where id = '00000000-0000-0000-0000-000000000f02' $$,
  $$ values ('delivered'::text, true) $$, 'it stays delivered, marked refunded');

-- ---------------------------------------------------------------------------
-- Taxed stringing with a string-change give-back
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update settings set tax_stringing = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000f3',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 50, 50, 20);
create temp table s3 as select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f03","qty":1,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
grant select on s3 to authenticated;
-- $10 cheaper strings: $10.83 back.
select lives_ok(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000b6',
                                   '00000000-0000-0000-0000-0000000000b6', 50, 50, '[{"method":"cash","amount":10.83}]'::jsonb) $$,
  'cheaper strings give $10.83 back first');

select throws_like(
  $$ select tests.refund_line((select id from s3), (select id from sale_lines where sale_id = (select id from s3)), 21.65) $$,
  '%must equal the refund total (10.82)%', 'what''s left is the price less the give-back, with the tax left');
select lives_ok(
  $$ select tests.refund_line((select id from s3), (select id from sale_lines where sale_id = (select id from s3)), 10.82) $$,
  'the rest of the charge is refunded');
select results_eq(
  $$ select r.subtotal, r.tax, rl.unit_price from refunds r join refund_lines rl on rl.refund_id = r.id
      where r.sale_id = (select id from s3) and rl.kind = 'return' $$,
  $$ values (10.00::numeric, 0.82::numeric, 10.00::numeric) $$,
  'the sale''s $1.65 of tax is given back in full, never more');

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, refunded_at)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b1', 50, 50, now()) $$,
  'A new string job starts as entered and unpaid', 'a new job can''t start refunded');
select throws_ok(
  $$ update string_jobs set refunded_at = null where id = '00000000-0000-0000-0000-000000000f01' $$,
  '42501', null, 'staff can''t clear the refunded mark directly');

select * from finish();
rollback;
