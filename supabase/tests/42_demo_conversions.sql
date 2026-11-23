-- Demos that led to a sale (Phase 3C).
begin;
\ir helpers/setup.psql

select plan(10);

-- A second racquet model, and a second customer.
insert into products (id, category_id, brand, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000d2', 'TestBrand', 'Other Racquet 98', 250.00);
insert into customers (id, first_name, last_name) values ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Other');

create function tests.sell_frame(p_unit uuid, p_product uuid, p_customer uuid)
returns uuid language sql as $$
  select record_sale(jsonb_build_array(jsonb_build_object('product_id', p_product, 'product_unit_id', p_unit,
                                                          'qty', 1, 'unit_price', 250)),
                     p_customer, '[{"method":"cash","amount":270.63}]'::jsonb, null);
$$;
grant execute on function tests.sell_frame(uuid, uuid, uuid) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '["CV-DEMO", "CV-NEW-1", "CV-NEW-2", "CV-NEW-3"]');
select receive_units('00000000-0000-0000-0000-0000000000b3', '["CV-OTHER"]');
create temp table u as select
  (select id from product_units where barcode = 'CV-DEMO')  as demo,
  (select id from product_units where barcode = 'CV-NEW-1') as new1,
  (select id from product_units where barcode = 'CV-NEW-2') as new2,
  (select id from product_units where barcode = 'CV-NEW-3') as new3,
  (select id from product_units where barcode = 'CV-OTHER') as other;
grant select on u to authenticated;

-- Pat borrows the demo and brings it back.
select set_unit_status((select demo from u), 'demo', 'Demo fleet');
create temp table l as
  select check_out_demo((select demo from u), '00000000-0000-0000-0000-0000000000c1') as loan;
grant select on l to authenticated;
select check_in_demo((select loan from l));

-- ---------------------------------------------------------------------------
-- What doesn't count
-- ---------------------------------------------------------------------------
select tests.sell_frame((select other from u), '00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000c1');
select is((select sale_id from demo_loans where id = (select loan from l)), null::uuid,
          'buying a different racquet doesn''t count');
select tests.sell_frame((select new1 from u), '00000000-0000-0000-0000-0000000000b2', null);
select tests.sell_frame((select new2 from u), '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000c2');
select is((select sale_id from demo_loans where id = (select loan from l)), null::uuid,
          'nor does a walk-in or another customer buying the same racquet');

-- ---------------------------------------------------------------------------
-- Pat buys one
-- ---------------------------------------------------------------------------
create temp table s as select tests.sell_frame((select new3 from u), '00000000-0000-0000-0000-0000000000b2',
                                               '00000000-0000-0000-0000-0000000000c1') as sale;
grant select on s to authenticated;
select is((select sale_id from demo_loans where id = (select loan from l)), (select sale from s),
          'buying a new frame of the racquet they demoed links the demo to the sale');

-- Pat demos it again and buys the demo frame itself (moved back in stock first).
select check_out_demo((select demo from u), '00000000-0000-0000-0000-0000000000c1');
select check_in_demo((select id from demo_loans where back_at is null));
select set_unit_status((select demo from u), 'in_stock', 'Selling the demo');
create temp table s2 as select tests.sell_frame((select demo from u), '00000000-0000-0000-0000-0000000000b2',
                                                '00000000-0000-0000-0000-0000000000c1') as sale;
grant select on s2 to authenticated;
select is((select sale_id from demo_loans where id <> (select loan from l)), (select sale from s2),
          'buying the demo frame itself links the latest demo');
select is((select sale_id from demo_loans where id = (select loan from l)), (select sale from s),
          'and leaves the earlier link alone');

-- ---------------------------------------------------------------------------
-- A refund leaves the link
-- ---------------------------------------------------------------------------
select record_refund((select sale from s), jsonb_build_array(jsonb_build_object(
         'sale_line_id', (select id from sale_lines where sale_id = (select sale from s)), 'qty', 1)),
       '[{"method":"cash","amount":270.63}]'::jsonb, 'Changed mind', null);
select is((select sale_id from demo_loans where id = (select loan from l)), (select sale from s),
          'returning the frame bought keeps the demo''s link to the sale');

-- ---------------------------------------------------------------------------
-- When a demo counts: still out, or back in the 30 days before the sale
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
create function tests.resell_demo_frame() returns void language plpgsql as $$
begin
  perform tests.clear_authentication();
  update demo_loans set sale_id = null where id <> (select loan from l);
  update product_units set status = 'in_stock', sale_id = null, customer_id = null where id = (select demo from u);
  perform tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
  perform tests.sell_frame((select demo from u), '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000c1');
end $$;
grant execute on function tests.resell_demo_frame() to authenticated;

select tests.clear_authentication();
update demo_loans set out_at = now() - interval '40 days', back_at = now() - interval '31 days' where id <> (select loan from l);
select tests.resell_demo_frame();
select is((select sale_id from demo_loans where id <> (select loan from l)), null::uuid,
          'a demo back more than 30 days before doesn''t count');

select tests.clear_authentication();
update demo_loans set back_at = now() - interval '5 days' where id <> (select loan from l);
select tests.resell_demo_frame();
select isnt((select sale_id from demo_loans where id <> (select loan from l)), null::uuid,
            'a long loan bought soon after it came back counts');

-- ---------------------------------------------------------------------------
-- One demo per racquet per sale
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b3', '["OD-1", "OD-2", "OB-1", "OB-2"]');
select set_unit_status(id, 'demo', 'Demo fleet') from product_units where barcode in ('OD-1', 'OD-2');
select check_in_demo(check_out_demo(id, '00000000-0000-0000-0000-0000000000c1'))
  from product_units where barcode in ('OD-1', 'OD-2');
create temp table pair as select record_sale(
  (select jsonb_agg(jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b3', 'product_unit_id', id,
                                       'qty', 1, 'unit_price', 250))
     from product_units where barcode in ('OB-1', 'OB-2')),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":541.25}]'::jsonb, null) as sale;
grant select on pair to authenticated;
select is((select count(*)::int from demo_loans where sale_id = (select sale from pair)), 1,
          'two frames bought on one sale credit one demo, not both');

select throws_like($$ update demo_loans set sale_id = null $$, '%permission denied%',
                   'staff can''t change a demo''s sale directly');

select * from finish();
rollback;
