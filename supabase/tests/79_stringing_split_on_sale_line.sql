-- A stringing charge's strings and labour, saved when it's rung (0117).
begin;
\ir helpers/setup.psql

select plan(7);

-- $18 labour; strings at $20 (b1, in the fixtures) and $30.
update settings set stringing_labor = 18, tax_stringing = false where id;
insert into products (id, category_id, brand, name, sell_price, attributes)
select '00000000-0000-0000-0000-0000000000b5', id, 'TestBrand', 'Thirty', 30, '{"color":"Red","gauge":"16"}'
  from categories where name = 'Strings';
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b5', 10);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Up'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Down');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
-- Up: a $20 string ($38 with labour), changed to a $30 string (+$10).
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 38);
-- Down: a $30 string ($48), changed to a $20 string (-$10).
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000b5', 55, 53, 48);
select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":38}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":38}]', null);
select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":48}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":48}]', null);

select results_eq(
  $$ select strings_amount, labor_amount, split_estimated from sale_lines
      where string_job_id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values (20.00::numeric, 18.00::numeric, false) $$,
  'a charge saves its strings and labour when it''s rung');

select change_paid_string_job('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000b5',
       '00000000-0000-0000-0000-0000000000b5', 55, 53, '[{"method":"credit","amount":10}]');
select change_paid_string_job('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000b1',
       '00000000-0000-0000-0000-0000000000b1', 55, 53, '[{"method":"credit","amount":10}]');

select results_eq(
  $$ select strings_amount, labor_amount from sale_lines
      where string_job_id = '00000000-0000-0000-0000-000000000f01' and kind = 'charge' $$,
  $$ values (20.00::numeric, 18.00::numeric) $$,
  'a later string change leaves the first charge''s split as it was');
select results_eq(
  $$ select strings_amount, labor_amount from sale_lines
      where string_job_id = '00000000-0000-0000-0000-000000000f01' and kind = 'string_change' $$,
  $$ values (10.00::numeric, 0.00::numeric) $$,
  'the string change''s charge is all strings');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select revenue, strings_revenue, labor_revenue, refunds
       from report_stringing_summary(now() - interval '1 hour', now() + interval '1 hour') $$,
  $$ values (96.00::numeric, 50.00::numeric, 36.00::numeric, 10.00::numeric) $$,
  'up: $30 strings + $18 labour; down: $20 strings + $18 labour, the give-back all strings');

-- Older lines are filled in from the job's price before its string changes.
select tests.clear_authentication();
update sale_lines set strings_amount = null, labor_amount = null, split_estimated = false
 where string_job_id in ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-000000000f02');
select fill_sale_line_strings_split();
select results_eq(
  $$ select strings_amount, labor_amount, split_estimated from sale_lines
      where string_job_id = '00000000-0000-0000-0000-000000000f01' and kind = 'charge' $$,
  $$ values (20.00::numeric, 18.00::numeric, true) $$,
  'an older charge is filled in from before its string change (up), marked estimated');
select results_eq(
  $$ select strings_amount, labor_amount from sale_lines
      where string_job_id = '00000000-0000-0000-0000-000000000f02' and kind = 'charge' $$,
  $$ values (30.00::numeric, 18.00::numeric) $$,
  'and from before a give-back (down)');
select results_eq(
  $$ select strings_amount, labor_amount, split_estimated from sale_lines
      where string_job_id = '00000000-0000-0000-0000-000000000f01' and kind = 'string_change' $$,
  $$ values (10.00::numeric, 0.00::numeric, false) $$,
  'an older string change is all strings');

select * from finish();
rollback;
