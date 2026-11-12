-- Discounts: one number per line or ticket (1 = 100%, below 1 = fraction,
-- above 1 = dollars each), each with a reason; a staff limit counting price
-- changes and discounts; one-time admin approvals; refunds and the report
-- (Phase 2B).
begin;
\ir helpers/setup.psql

select plan(47);

-- Settings are admin-only; the tests set the staff limit through this.
create function tests.set_discount_cap(p_percent numeric) returns void
language sql security definer set search_path = public, pg_temp
as $$ update settings set staff_discount_cap = p_percent where id; $$;
grant execute on function tests.set_discount_cap(numeric) to authenticated;
select tests.set_discount_cap(20);

insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e3', 'GC-DISCOUNT');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1');
insert into string_jobs (id, customer_racket_id, price) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1', 30);

-- b1 is a $20 string; tax is 8.25%.
create function tests.line(p_qty integer, p_price numeric, p_discount numeric default null, p_reason text default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'product_id', '00000000-0000-0000-0000-0000000000b1', 'qty', p_qty, 'unit_price', p_price,
    'discount', p_discount, 'discount_reason', p_reason));
$$;
grant execute on function tests.line(integer, numeric, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- The input rule
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select discount_each(20, 1), discount_each(20, 0.25), discount_each(20, 3), discount_each(9.99, 0.25), discount_each(20, 0) $$,
  $$ values (20::numeric, 5.00::numeric, 3::numeric, 2.50::numeric, 0::numeric) $$,
  '1 is 100% off, 0.25 is 25% off, 3 is $3 off, rounded to the cent; 0 is none');
select throws_like($$ select discount_each(20, -0.1) $$, 'A discount can''t be negative', 'a negative discount is refused');
select throws_like($$ select discount_each(20, 25) $$, 'A $25.00 discount is more than the $20.00 price',
                   'more dollars off than the price is refused');
select throws_like($$ select discount_each(20, 3.333) $$, 'A dollar discount must be in whole cents',
                   'dollars off must be whole cents');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- Line discounts
-- ---------------------------------------------------------------------------
select is(
  (quote_sale(jsonb_build_array(tests.line(1, 20, 0.1)), null))->'problems',
  '[{"line": 0, "message": "Discount: give a reason"}]'::jsonb,
  'a discount without a reason is a problem');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20, 0.1)), null, '[{"method":"cash","amount":19.49}]'::jsonb, null) $$,
  'The discount on line 1 needs a reason', 'and recording it is refused');

create temp table q1 as select quote_sale(jsonb_build_array(tests.line(1, 20, 0.1, '  Promotion ')), null) as q;
select results_eq(
  $$ select q->'problems', (q->'lines'->0->>'unit_price')::numeric, (q->'lines'->0->>'line_discount_each')::numeric,
            q->'lines'->0->>'discount_reason', (q->>'total')::numeric, (q->>'discount_total')::numeric from q1 $$,
  $$ values ('[]'::jsonb, 18::numeric, 2.00::numeric, 'Promotion'::text, 19.49::numeric, 2::numeric) $$,
  '10% off $20 with a reason: $18 each, taxed on $18');

create temp table s1 as
select record_sale(jsonb_build_array(tests.line(1, 20, 0.1, 'Promotion')), null, '[{"method":"cash","amount":19.49}]'::jsonb, null) as id;
select results_eq(
  $$ select unit_price, price_before_discount, line_discount, line_discount_each, ticket_discount_each, discount_reason, list_price, price_reason
       from sale_lines where sale_id = (select id from s1) $$,
  $$ values (18.00::numeric(12,2), 20.00::numeric(12,2), 0.1::numeric(12,4), 2.00::numeric(12,2), null::numeric(12,2),
             'Promotion'::text, 20.00::numeric(12,2), null::text) $$,
  'the line keeps the price before the discount, the discount entered and what it took off');
select is((select discount_approved_by from sales where id = (select id from s1)), null::uuid,
          'a discount within the limit needs no approval');

select results_eq(
  $$ select (q->'lines'->0->>'unit_price')::numeric, (q->>'subtotal')::numeric
       from (select quote_sale(jsonb_build_array(tests.line(2, 20, 3, 'Promotion')), null) as q) x $$,
  $$ values (17::numeric, 34::numeric) $$,
  '$3 off is $3 off each item');
select throws_like(
  $$ select quote_sale(jsonb_build_array(tests.line(1, 20, 21, 'Promotion')), null) $$,
  'A $21.00 discount is more than the $20.00 price', 'the quote refuses more dollars off than the price');
select throws_like(
  $$ select quote_sale('[{"gift_card_id":"00000000-0000-0000-0000-0000000000e3","qty":1,"unit_price":25,"discount":0.1,"discount_reason":"Promotion"}]'::jsonb, null) $$,
  'A gift card sale can''t be discounted', 'a gift card can''t be discounted');

-- ---------------------------------------------------------------------------
-- Ticket discounts
-- ---------------------------------------------------------------------------
create temp table q2 as
select quote_sale(jsonb_build_array(tests.line(1, 20), tests.line(2, 20, 3, 'Promotion')), null,
                  '{"discount":0.1,"discount_reason":"Loyalty"}') as q;
select results_eq(
  $$ select (q->'lines'->0->>'ticket_discount_each')::numeric, (q->'lines'->0->>'unit_price')::numeric,
            (q->'lines'->1->>'ticket_discount_each')::numeric, (q->'lines'->1->>'unit_price')::numeric,
            (q->>'subtotal')::numeric, (q->>'discount_total')::numeric from q2 $$,
  $$ values (2.00::numeric, 18.00::numeric, 1.70::numeric, 15.30::numeric, 48.60::numeric, 11.40::numeric) $$,
  '10% off the ticket comes off each item after its line discount');
select is((select (q->>'max_discount_percent')::numeric from q2), 23.50, 'the furthest item is 23.5% below its price');
select is((select q->'problems' from q2),
          '[{"line": null, "message": "23.5% off is over the staff limit of 20%: an admin must approve it"}]'::jsonb,
          'which is over the staff limit');

select is(
  (select (q->>'discount_total')::numeric
     from (select quote_sale(jsonb_build_array(tests.line(2, 20)), null, '{"discount":5,"discount_reason":"Loyalty"}') as q) x),
  5.00, '$5 off two $20 items is $2.50 off each');
select is(
  (select (q->>'discount_total')::numeric
     from (select quote_sale(jsonb_build_array(tests.line(3, 20)), null, '{"discount":5,"discount_reason":"Loyalty"}') as q) x),
  5.01, '$5 off three is $1.67 each: a cent over, shown exactly');
select throws_like(
  $$ select quote_sale(jsonb_build_array(tests.line(1, 20)), null, '{"discount":25,"discount_reason":"Loyalty"}') $$,
  'A $25.00 ticket discount is more than the $20.00 of items it applies to', 'a ticket discount over the items is refused');
select results_eq(
  $$ select (q->'lines'->0->>'unit_price')::numeric, (q->'lines'->1->>'unit_price')::numeric
       from (select quote_sale('[{"gift_card_id":"00000000-0000-0000-0000-0000000000e3","qty":1,"unit_price":25}]'::jsonb
                               || jsonb_build_array(tests.line(1, 20)), null, '{"discount":0.1,"discount_reason":"Loyalty"}') as q) x $$,
  $$ values (25::numeric, 18.00::numeric) $$,
  'the ticket discount doesn''t touch a gift card');
select is(
  (quote_sale(jsonb_build_array(tests.line(1, 20)), null, '{"discount":0.1}'))->'problems',
  '[{"line": null, "message": "Ticket discount: give a reason"}]'::jsonb,
  'a ticket discount needs a reason');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20)), null, '[{"method":"cash","amount":19.49}]'::jsonb, null, '{"discount":0.1}') $$,
  'The ticket discount needs a reason', 'and recording it without one is refused');

create temp table s2 as
select record_sale(jsonb_build_array(tests.line(1, 20)), null, '[{"method":"cash","amount":19.49}]'::jsonb, null,
                   '{"discount":0.1,"discount_reason":" Loyalty "}') as id;
select results_eq(
  $$ select s.ticket_discount, s.ticket_discount_reason, l.unit_price, l.price_before_discount, l.ticket_discount_each
       from sales s join sale_lines l on l.sale_id = s.id where s.id = (select id from s2) $$,
  $$ values (0.1::numeric(12,4), 'Loyalty'::text, 18.00::numeric(12,2), 20.00::numeric(12,2), 2.00::numeric(12,2)) $$,
  'the sale keeps its ticket discount and reason; the line what it took off');

-- ---------------------------------------------------------------------------
-- The staff limit
-- ---------------------------------------------------------------------------
select is((quote_sale(jsonb_build_array(tests.line(1, 20, 0.2, 'Promotion')), null))->'problems', '[]'::jsonb,
          'exactly the limit is fine');
select is(
  (quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15,"price_reason":"Price match"}]'::jsonb, null))->'problems',
  '[{"line": null, "message": "25% off is over the staff limit of 20%: an admin must approve it"}]'::jsonb,
  'a price changed below the catalog price counts toward the limit');
select is(
  (quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":18,"price_reason":"Price match"}]'::jsonb
              || '[]'::jsonb, null, '{"discount":0.1,"discount_reason":"Loyalty"}'))->'problems',
  '[]'::jsonb, 'and together with a discount: $18 less 10% is 19% off');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20, 0.25, 'Promotion')), null, '[{"method":"cash","amount":16.24}]'::jsonb, null) $$,
  '25% off is over the staff limit of 20%: an admin must approve it', 'staff can''t record a discount over the limit');

-- ---------------------------------------------------------------------------
-- Approvals
-- ---------------------------------------------------------------------------
select throws_ok($$ select approve_discount(30) $$, '42501', 'Only an admin can approve a discount', 'staff can''t approve');
select throws_ok($$ insert into discount_approvals (max_percent) values (30) $$, '42501', null,
                 'or write an approval directly');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_like($$ select approve_discount(0) $$, 'Approve a discount between 0% and 100%', 'an approval needs a percent');
create temp table approvals as
select approve_discount(30) as a30, approve_discount(30) as a30b, approve_discount(30) as a30c, approve_discount(10) as a10;
grant select on approvals, s1 to authenticated;
select results_eq(
  $$ select approved_by, max_percent, expires_at - created_at, sale_id from discount_approvals where id = (select a30 from approvals) $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid, 30.00::numeric(5,2), interval '15 minutes', null::uuid) $$,
  'an approval records the admin, the percent, and lasts 15 minutes');

create temp table s3 as
select record_sale(jsonb_build_array(tests.line(1, 20, 0.5, 'Damaged')), null, '[{"method":"cash","amount":10.83}]'::jsonb, null) as id;
grant select on s3 to authenticated;
select is((select discount_approved_by from sales where id = (select id from s3)),
          '00000000-0000-0000-0000-0000000000a2'::uuid, 'an admin can go over the limit; the sale says so');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from discount_approvals), 0, 'staff can''t read approvals');
select is(
  (quote_sale(jsonb_build_array(tests.line(1, 20, 0.25, 'Promotion')), null, null, (select a30 from approvals)))->'problems',
  '[]'::jsonb, 'an approval clears the problem in the quote');
create temp table s4 as
select record_sale(jsonb_build_array(tests.line(1, 20, 0.25, 'Promotion')), null, '[{"method":"cash","amount":16.24}]'::jsonb,
                   null, null, (select a30 from approvals)) as id;
grant select on s4 to authenticated;
select is((select discount_approved_by from sales where id = (select id from s4)),
          '00000000-0000-0000-0000-0000000000a2'::uuid, 'with an approval, staff record it, naming the admin');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20, 0.25, 'Promotion')), null, '[{"method":"cash","amount":16.24}]'::jsonb,
                        null, null, (select a30 from approvals)) $$,
  'The admin approval doesn''t cover 25% off (it may have expired or been used): ask again',
  'an approval works once');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20, 0.25, 'Promotion')), null, '[{"method":"cash","amount":16.24}]'::jsonb,
                        null, null, (select a10 from approvals)) $$,
  'The admin approval doesn''t cover 25% off%', 'and only up to its percent');
create temp table s5 as
select record_sale(jsonb_build_array(tests.line(1, 20, 0.1, 'Promotion')), null, '[{"method":"cash","amount":19.49}]'::jsonb,
                   null, null, (select a30b from approvals)) as id;
select tests.clear_authentication();
select is((select sale_id from discount_approvals where id = (select a30b from approvals)), null::uuid,
          'a sale within the limit doesn''t use up an approval');
select is((select sale_id from discount_approvals where id = (select a30 from approvals)), (select id from s4),
          'a used approval names its sale');
update discount_approvals set expires_at = now() - interval '1 minute' where id = (select a30c from approvals);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20, 0.25, 'Promotion')), null, '[{"method":"cash","amount":16.24}]'::jsonb,
                        null, null, (select a30c from approvals)) $$,
  'The admin approval doesn''t cover%', 'an expired approval doesn''t work');

-- ---------------------------------------------------------------------------
-- String jobs, refunds and the report
-- ---------------------------------------------------------------------------
create temp table s6 as
select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30,"discount":5,"discount_reason":"Loyalty"}]'::jsonb,
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":25}]'::jsonb, null) as id;
select is((select price from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 25.00::numeric(12,2),
          'a discounted string job''s price becomes what was charged');

create temp table r1 as
select record_refund((select id from s4),
         (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines where sale_id = (select id from s4)),
         '[{"method":"cash","amount":16.24}]'::jsonb, null, null, null) as id;
select results_eq(
  $$ select subtotal, tax from refunds where id = (select id from r1) $$,
  $$ values (15.00::numeric(12,2), 1.24::numeric(12,2)) $$,
  'returning a discounted item refunds what it cost, with its tax');

-- The report, before and after one sale with a price change and a discount.
create temp table before as select * from sales_summary(now() - interval '1 hour', now() + interval '1 hour');
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":19,"price_reason":"Price match",
                      "discount":0.1,"discount_reason":"Loyalty"}]'::jsonb, null, '[{"method":"cash","amount":37.02}]'::jsonb, null);
create temp table after as select * from sales_summary(now() - interval '1 hour', now() + interval '1 hour');
select results_eq(
  $$ select a.discounts - b.discounts, a.discount_total - b.discount_total,
            a.price_changes - b.price_changes, a.price_change_total - b.price_change_total, a.gross - b.gross
       from before b, after a $$,
  $$ values (1, 3.80::numeric, 1, -2.00::numeric, 34.20::numeric) $$,
  'the report counts the discount once, and the price change before it');

select ok(not has_function_privilege('authenticated', 'discount_each(numeric, numeric)', 'execute')
          and not has_function_privilege('authenticated', 'discount_approval_problem(jsonb, uuid)', 'execute')
          and not has_function_privilege('authenticated', 'sale_totals(jsonb, jsonb)', 'execute'),
          'the discount helpers are internal');
select ok(not has_function_privilege('anon', 'approve_discount(numeric)', 'execute')
          and not has_function_privilege('anon', 'record_sale(jsonb, uuid, jsonb, text, jsonb, uuid)', 'execute')
          and not has_function_privilege('anon', 'quote_sale(jsonb, uuid, jsonb, uuid)', 'execute'),
          'signed-out visitors can''t approve, quote or sell');

-- Admins: no limit.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select is((quote_sale(jsonb_build_array(tests.line(1, 20, 1, 'Damaged')), null))->'problems', '[]'::jsonb,
          'an admin''s quote has no limit');
select tests.set_discount_cap(100);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((quote_sale(jsonb_build_array(tests.line(1, 20, 1, 'Damaged')), null))->'problems', '[]'::jsonb,
          'a 100% limit lets staff give anything away');
select is((quote_sale(jsonb_build_array(tests.line(1, 20)), null))->>'staff_discount_cap', '100.00',
          'the quote says what the limit is');

select * from finish();
rollback;
