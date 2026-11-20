-- A racquet sold to a customer becomes one of their racquets (Phase 3B).
begin;
\ir helpers/setup.psql

select plan(13);

update products set attributes = '{"grip_size":"4 3/8"}' where id = '00000000-0000-0000-0000-0000000000b2';
insert into customers (id, first_name, last_name) values ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Lob');
-- Sam's own racquet, which will wear the tag "RQ-3".
insert into customer_rackets (customer_id, model, barcode) values ('00000000-0000-0000-0000-0000000000c2', 'Old Frame', 'RQ-3x');

create function tests.sell(p_unit uuid, p_customer uuid) returns uuid language sql as $$
  select record_sale(jsonb_build_array(jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2',
                                                          'product_unit_id', p_unit, 'qty', 1, 'unit_price', 250)),
                     p_customer, '[{"method":"cash","amount":270.63}]'::jsonb, null);
$$;
grant execute on function tests.sell(uuid, uuid) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '["RQ-1", "RQ-2", "RQ-3", null]');
create temp table u as
  select (select id from product_units where barcode = 'RQ-1') as one,
         (select id from product_units where barcode = 'RQ-2') as two,
         (select id from product_units where barcode = 'RQ-3') as three,
         (select id from product_units where barcode is null) as blank;
grant select on u to authenticated;


-- ---------------------------------------------------------------------------
-- Selling to a customer
-- ---------------------------------------------------------------------------
select tests.sell((select one from u), '00000000-0000-0000-0000-0000000000c1');
select results_eq(
  $$ select customer_id, product_id, brand, model, grip_size, barcode, is_active
       from customer_rackets where product_unit_id = (select one from u) $$,
  $$ values ('00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000b2'::uuid,
             'TestBrand'::text, 'Test Racquet 100'::text, '4 3/8'::text, 'RQ-1'::text, true) $$,
  'the frame joins the customer''s racquets, its barcode as the tag');
select is((select barcode from product_units where id = (select one from u)), 'RQ-1', 'and the frame keeps its barcode');

select results_eq(
  $$ select kind, id, customer_id from resolve_barcode('RQ-1') $$,
  $$ values ('racket'::text, (select id from customer_rackets where product_unit_id = (select one from u)),
             '00000000-0000-0000-0000-0000000000c1'::uuid) $$,
  'scanning the sold frame finds the customer''s racquet');
select results_eq($$ select kind from resolve_barcode('RQ-2') $$, $$ values ('unit'::text) $$,
                  'a frame still in stock scans as a frame');

-- It can be strung straight away.
select lives_ok(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ((select id from customer_rackets where product_unit_id = (select one from u)),
             '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50, 38) $$,
  'the new racquet can be strung in the same visit');
select is((select open_job_id is not null from resolve_barcode('RQ-1')), true, 'and scanning it then opens that job');

-- ---------------------------------------------------------------------------
-- Other cases
-- ---------------------------------------------------------------------------
select tests.sell((select two from u), null);
select is((select count(*)::int from customer_rackets where product_unit_id = (select two from u)), 0,
          'a sale to nobody adds no racquet');

select tests.sell((select blank from u), '00000000-0000-0000-0000-0000000000c2');
select results_eq($$ select barcode, is_active from customer_rackets where product_unit_id = (select blank from u) $$,
                  $$ values (null::text, true) $$, 'a frame with no barcode becomes a racquet with no tag');

-- A frame whose barcode another customer's racquet already wears is added untagged.
select tests.clear_authentication();
-- (Only possible with the guard off, e.g. a code recorded before 0045.)
alter table customer_rackets disable trigger trg_guard_unique_barcode;
update customer_rackets set barcode = 'RQ-3' where barcode = 'RQ-3x';
alter table customer_rackets enable trigger trg_guard_unique_barcode;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select tests.sell((select three from u), '00000000-0000-0000-0000-0000000000c1') $$,
                'a taken code doesn''t stop the sale');
select is((select barcode from customer_rackets where product_unit_id = (select three from u)), null,
          'the racquet is added without a tag');

-- ---------------------------------------------------------------------------
-- Barcodes stay one code, one thing
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into customer_rackets (customer_id, model, barcode) values ('00000000-0000-0000-0000-0000000000c2', 'Copy', 'RQ-1') $$,
  'Barcode RQ-1 is already the barcode of a TestBrand Test Racquet 100 unit',
  'another racquet can''t take a frame''s barcode');
select throws_like(
  $$ insert into customer_rackets (customer_id, model, barcode, product_unit_id)
     values ('00000000-0000-0000-0000-0000000000c2', 'Copy', null, (select one from u)) $$,
  '%uq_customer_rackets_unit%', 'and a frame is one customer''s racquet at a time');
select throws_like(
  $$ insert into customer_rackets (customer_id, model, barcode, product_unit_id)
     values ('00000000-0000-0000-0000-0000000000c2', 'Copy', 'RQ-2', (select one from u)) $$,
  'Barcode RQ-2 is already the barcode of a TestBrand Test Racquet 100 unit',
  'a racquet only shares the barcode of its own frame');

select * from finish();
rollback;
