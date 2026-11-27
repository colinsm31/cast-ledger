-- Stringing volume and revenue (0099), with the strings/labour split fixed (0102).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(9);

-- The shop's labour charge is $18. Job ...e1 (from the fixture) was entered
-- in October and is still waiting; its strings price is the real one ($18
-- labour + the $20 string = $38). Its $30 charge on 11 Nov is $20 strings and
-- $10 labour; it was refunded on 20 Nov. Also in November:
--   e5  the customer's own mains and crosses (labour only), $18 charged 15 Nov
--   a $5 string change on e1 on 16 Nov, refunded 17 Nov
--   j2  entered 3 Nov 10:00, rush, promised 4 Nov 12:00, completed by Sam 4 Nov 10:00 (on time)
--   j3  entered 5 Nov 10:00, customer's own mains, promised 6 Nov, completed by Sam 8 Nov 10:00 (late)
--   j4  entered 6 Nov, cancelled 6 Nov
update settings set stringing_labor = 18 where id;
update string_jobs set entered_at = '2026-10-20 10:00Z',
                       strings_price = string_job_strings_price(main_product_id, cross_product_id)
 where id = '00000000-0000-0000-0000-0000000000e1';
-- The fixture rang e1's charge before its price was set; save the split the
-- register would have saved then ($38 strings price, $18 labour), since the
-- split is kept on the line (0117).
update sale_lines set strings_amount = 20, labor_amount = 10
 where id = '00000000-0000-0000-0000-0000000007c3';
-- One open job per racquet: each job gets its own.
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000fa', '00000000-0000-0000-0000-0000000000c1', 'Frame 2'),
  ('00000000-0000-0000-0000-0000000000fb', '00000000-0000-0000-0000-0000000000c1', 'Frame 3'),
  ('00000000-0000-0000-0000-0000000000fc', '00000000-0000-0000-0000-0000000000c1', 'Frame 4');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension,
                         price, is_rush, promised_at, entered_at)
values
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000fa',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30, true,
   '2026-11-04 12:00Z', '2026-11-03 10:00Z'),
  ('00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-0000000000fc',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30, false,
   '2026-11-07 12:00Z', '2026-11-06 10:00Z');
insert into string_jobs (id, customer_racket_id, main_customer_supplied, main_brand, main_string,
                         cross_product_id, main_tension, cross_tension, price, promised_at, entered_at)
values
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000fb', true, 'Own', 'Poly',
   '00000000-0000-0000-0000-0000000000b1', 52, 52, 20, '2026-11-06 12:00Z', '2026-11-05 10:00Z');
update string_jobs set status = 'complete', completed_at = '2026-11-04 10:00Z', strung_by = 'Sam'
 where id = '00000000-0000-0000-0000-0000000000e2';
update string_jobs set status = 'complete', completed_at = '2026-11-08 10:00Z', strung_by = ' Sam '
 where id = '00000000-0000-0000-0000-0000000000e3';
update string_jobs set status = 'cancelled', cancelled_at = '2026-11-06 11:00Z'
 where id = '00000000-0000-0000-0000-0000000000e4';

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000fd', '00000000-0000-0000-0000-0000000000c1', 'Frame 5');
insert into string_jobs (id, customer_racket_id, main_customer_supplied, cross_customer_supplied, main_brand, main_string,
                         cross_brand, cross_string, main_tension, cross_tension, price, strings_price,
                         status, entered_at, completed_at, delivered_at)
values ('00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-0000000000fd', true, true, 'Own', 'Poly',
        'Own', 'Gut', 52, 52, 18, string_job_strings_price(null, null),
        'delivered', '2026-10-05 10:00Z', '2026-10-05 12:00Z', '2026-10-06 10:00Z');
insert into sales (id, sold_at, subtotal, tax, tax_rate) values
  ('00000000-0000-0000-0000-0000000005c5', '2026-11-15 10:00Z', 18, 0, 0),
  ('00000000-0000-0000-0000-0000000005c6', '2026-11-16 10:00Z', 5, 0, 0);
insert into sale_lines (id, sale_id, string_job_id, qty, unit_price, kind) values
  ('00000000-0000-0000-0000-0000000007c8', '00000000-0000-0000-0000-0000000005c5', '00000000-0000-0000-0000-0000000000e5', 1, 18, 'charge'),
  ('00000000-0000-0000-0000-0000000007c9', '00000000-0000-0000-0000-0000000005c6', '00000000-0000-0000-0000-0000000000e1', 1, 5, 'string_change');
insert into refunds (id, sale_id, subtotal, tax, refunded_at) values
  ('00000000-0000-0000-0000-0000000008c3', '00000000-0000-0000-0000-0000000005c6', 5, 0, '2026-11-17 10:00Z');
insert into refund_lines (refund_id, sale_line_id, qty, unit_price) values
  ('00000000-0000-0000-0000-0000000008c3', '00000000-0000-0000-0000-0000000007c9', 1, 5);

insert into refunds (id, sale_id, subtotal, tax, refunded_at, user_id) values
  ('00000000-0000-0000-0000-0000000008c2', '00000000-0000-0000-0000-0000000005c2', 30, 0,
   '2026-11-20 10:00Z', '00000000-0000-0000-0000-0000000000a2');
insert into refund_lines (refund_id, sale_line_id, qty, unit_price) values
  ('00000000-0000-0000-0000-0000000008c2', '00000000-0000-0000-0000-0000000007c3', 1, 30);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select * from report_stringing_summary('2026-11-01Z', '2026-12-01Z') $$, '42501',
                 'Only an admin can see reports', 'staff can''t see the stringing summary');
select throws_ok($$ select * from report_stringing('2026-11-01Z', '2026-12-01Z') $$, '42501',
                 'Only an admin can see reports', 'or the stringing by stringer');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select jobs_entered, rush_entered, jobs_completed, jobs_delivered, jobs_cancelled, jobs_waiting,
            revenue, strings_revenue, labor_revenue, refunds, net_revenue
       from report_stringing_summary('2026-11-01Z', '2026-12-01Z') $$,
  $$ values (3, 1, 2, 0, 1, 1, 53.00::numeric, 0.00::numeric, 18.00::numeric, 35.00::numeric, 18.00::numeric) $$,
  'November: $53 charged, $35 refunded; what''s left is the customer''s-own-string job''s labour');

select results_eq(
  $$ select revenue, strings_revenue, labor_revenue from report_stringing_summary('2026-11-11Z', '2026-11-12Z') $$,
  $$ values (30.00::numeric, 20.00::numeric, 10.00::numeric) $$,
  'a charge''s strings are its strings price less labour; the rest of the charge is labour');

select results_eq(
  $$ select revenue, strings_revenue, labor_revenue from report_stringing_summary('2026-11-15Z', '2026-11-17Z') $$,
  $$ values (23.00::numeric, 5.00::numeric, 18.00::numeric) $$,
  'the customer''s own string is labour only; a string change is strings');

select results_eq(
  $$ select qty_sold, qty_returned, returns from report_sales_by('2026-11-01Z', '2026-12-01Z', 'category')
      where group_key = 'stringing' $$,
  $$ values (2, 1, 35.00::numeric) $$,
  'a refunded string change is money back, not another returned job');

select results_eq(
  $$ select stringer, jobs_completed, rush, customer_supplied, on_time, late, avg_hours
       from report_stringing('2026-11-01Z', '2026-12-01Z') $$,
  $$ values ('Sam'::text, 2, 1, 1, 1, 1, 48.0::numeric) $$,
  'by stringer: rush, customer''s own string, on time or late, average hours');

select throws_ok($$ select * from report_stringing('2026-12-01Z', '2026-11-01Z') $$, '22023',
                 'A report needs a start before its end', 'a period must start before it ends');

select results_eq(
  $$ select jobs_entered, jobs_completed, revenue, net_revenue from report_stringing_summary('2026-10-01Z', '2026-11-01Z') $$,
  $$ values (2, 1, 0::numeric, 0::numeric) $$,
  'October: two jobs entered, the customer''s-own-string one completed, nothing charged');

select * from finish();
rollback;
