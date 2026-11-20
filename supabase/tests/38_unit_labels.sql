-- Barcodes for frames received without one (Phase 3B).
begin;
\ir helpers/setup.psql

select plan(13);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '[null, null, null, "RQ-1"]');
create temp table u as
  select (array_agg(id order by id) filter (where barcode is null)) as blank,
         (select id from product_units where barcode = 'RQ-1') as labelled
    from product_units;
grant select on u to authenticated;

-- ---------------------------------------------------------------------------
-- The shop's label codes
-- ---------------------------------------------------------------------------
create temp table first_code as select assign_unit_label((select blank[1] from u)) as code;
grant select on first_code to authenticated;
select ok((select code ~ '^U[0-9]{5,}$' from first_code), 'a frame with no barcode gets a U code');
select is((select barcode from product_units where id = (select blank[1] from u)), (select code from first_code),
          'which becomes its barcode');
select is(assign_unit_label((select blank[1] from u)), (select code from first_code),
          'asking again prints the same code');
select is(assign_unit_label((select labelled from u)), 'RQ-1', 'a frame with a barcode keeps it');
select results_eq($$ select kind, id from resolve_barcode((select code from first_code)) $$,
                  $$ values ('unit'::text, (select blank[1] from u)) $$, 'scanning the label finds the frame');

-- A code already used elsewhere is skipped.
select tests.clear_authentication();
insert into customer_rackets (customer_id, model, barcode)
values ('00000000-0000-0000-0000-0000000000c1', 'Old Frame',
        'U' || (substr((select code from first_code), 2)::bigint + 1));
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is(assign_unit_label((select blank[2] from u)), 'U' || (substr((select code from first_code), 2)::bigint + 2),
          'a code something else already uses is skipped');

-- ---------------------------------------------------------------------------
-- A barcode added later
-- ---------------------------------------------------------------------------
select is(set_unit_barcode((select blank[3] from u), ' 400123 '), '400123', 'a barcode can be added later, tidied');
select throws_like($$ select set_unit_barcode((select blank[3] from u), '400124') $$,
                   'This frame already has barcode 400123', 'but not changed once set');
select throws_like($$ select set_unit_barcode((select blank[1] from u), '') $$, 'Scan or type the barcode', 'a barcode is needed');
select throws_like($$ select set_unit_barcode((select blank[1] from u), 'two words') $$,
                   'A barcode is at most 64 characters, with no spaces', 'with no spaces');
select throws_like($$ select set_unit_barcode((select blank[1] from u), '012345678905') $$,
                   'This frame already has barcode U%', 'a labelled frame can''t take another');

-- The 0045 rules still hold: one code, one thing.
select tests.clear_authentication();
update product_units set barcode = null where id = (select blank[1] from u);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select set_unit_barcode((select blank[1] from u), '012345678905') $$,
                   'Barcode 012345678905 is already the UPC of TestBrand Test String 16', 'a code in use is refused');

select tests.act_as_anon();
select throws_like($$ select assign_unit_label('00000000-0000-0000-0000-000000000001') $$,
                   '%permission denied%', 'visitors can''t label frames');

select * from finish();
rollback;
