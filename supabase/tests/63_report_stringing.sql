-- Stringing volume and revenue (0099).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(6);

-- Job ...e1 (from the fixture) was entered in October and is still waiting;
-- its $30 charge on 11 Nov included $20 of the shop's strings, and was
-- refunded on 20 Nov. November also has:
--   j2  entered 3 Nov 10:00, rush, promised 4 Nov 12:00, completed by Sam 4 Nov 10:00 (on time)
--   j3  entered 5 Nov 10:00, customer's own mains, promised 6 Nov, completed by Sam 8 Nov 10:00 (late)
--   j4  entered 6 Nov, cancelled 6 Nov
update string_jobs set entered_at = '2026-10-20 10:00Z', strings_price = 20
 where id = '00000000-0000-0000-0000-0000000000e1';
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
  $$ values (3, 1, 2, 0, 1, 1, 30.00::numeric, 20.00::numeric, 10.00::numeric, 30.00::numeric, 0.00::numeric) $$,
  'November: jobs in and out, and the stringing charge split into strings and labor, less its refund');

select results_eq(
  $$ select stringer, jobs_completed, rush, customer_supplied, on_time, late, avg_hours
       from report_stringing('2026-11-01Z', '2026-12-01Z') $$,
  $$ values ('Sam'::text, 2, 1, 1, 1, 1, 48.0::numeric) $$,
  'by stringer: rush, customer''s own string, on time or late, average hours');

select throws_ok($$ select * from report_stringing('2026-12-01Z', '2026-11-01Z') $$, '22023',
                 'A report needs a start before its end', 'a period must start before it ends');

select results_eq(
  $$ select jobs_entered, jobs_completed, revenue, net_revenue from report_stringing_summary('2026-10-01Z', '2026-11-01Z') $$,
  $$ values (1, 0, 0::numeric, 0::numeric) $$,
  'October: one job entered, nothing charged');

select * from finish();
rollback;
