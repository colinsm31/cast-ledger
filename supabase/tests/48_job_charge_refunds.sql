-- A job paid on two sales (its charge, then a dearer string change), refunded
-- (Phase 3D review, 0079): the string change's charge comes back after the
-- job's own charge, never on its own.
begin;
\ir helpers/setup.psql

select plan(7);

create function tests.refund_line(p_sale uuid, p_line uuid, p_amount numeric)
returns uuid language sql as $$
  select record_refund(p_sale, jsonb_build_array(jsonb_build_object('sale_line_id', p_line, 'qty', 1)),
                       jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', p_amount)), 'Not happy', null);
$$;
grant execute on function tests.refund_line(uuid, uuid, numeric) to authenticated;

insert into products (id, category_id, brand, name, sell_price, attributes)
select '00000000-0000-0000-0000-0000000000b8', id, 'TestBrand', 'Premium', 30, '{"color":"Red","gauge":"16"}'
  from categories where name = 'Strings';
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b8', 10);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Pat 1');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20);

-- Paid $20, then changed to the $30 string: a $10 string-change charge on a second sale.
create temp table s as select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":20}]'::jsonb, null) as job_sale;
grant select on s to authenticated;
create temp table q as select (string_change_quote('00000000-0000-0000-0000-000000000f01',
  '00000000-0000-0000-0000-0000000000b8', '00000000-0000-0000-0000-0000000000b8')->>'total')::numeric as total;
grant select on q to authenticated;
create temp table c as select change_paid_string_job('00000000-0000-0000-0000-000000000f01',
  '00000000-0000-0000-0000-0000000000b8', '00000000-0000-0000-0000-0000000000b8', 55, 53,
  jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', (select total from q)))) as result;
grant select on c to authenticated;
create temp table l as select
  (select id from sale_lines where sale_id = (select job_sale from s)) as job_line,
  (select id from sale_lines where string_job_id = '00000000-0000-0000-0000-000000000f01' and kind = 'string_change') as change_line,
  (select sale_id from sale_lines where string_job_id = '00000000-0000-0000-0000-000000000f01' and kind = 'string_change') as change_sale;
grant select on l to authenticated;

select ok((select change_line from l) is not null and (select change_sale from l) <> (select job_sale from s),
          'the string change is charged on a second sale');

-- ---------------------------------------------------------------------------
-- The string change's charge alone is refused
-- ---------------------------------------------------------------------------
select throws_like($$ select tests.refund_line((select change_sale from l), (select change_line from l), (select total from q)) $$,
                   'This is a string change on job J%: refund the job''s own charge first',
                   'a string change''s charge isn''t refunded before the job''s own');
select is((select status from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 'entered',
          'so the paid job isn''t cancelled by it');

-- ---------------------------------------------------------------------------
-- The job's charge first, then the string change's
-- ---------------------------------------------------------------------------
create temp table r1 as select tests.refund_line((select job_sale from s), (select job_line from l), 20) as id;
grant select on r1 to authenticated;
select results_eq($$ select status, refund_id from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
                  $$ select 'cancelled'::text, (select id from r1) $$,
                  'refunding the job''s charge cancels the job and marks it refunded');
create temp table r2 as select tests.refund_line((select change_sale from l), (select change_line from l), (select total from q)) as id;
grant select on r2 to authenticated;
select is((select subtotal + tax from refunds where id = (select id from r2)), (select total from q),
          'then the string change''s charge comes back in full');
select is((select refund_id from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), (select id from r1),
          'and the job keeps the refund that cancelled it');
select throws_like($$ select tests.refund_line((select change_sale from l), (select change_line from l), (select total from q)) $$,
                   'Cannot return 1 of line (only 0 remaining)', 'each charge comes back once');

select * from finish();
rollback;
