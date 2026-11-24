-- Inactive customers can't be slipped past (Phase 3D review, 0080): a racquet
-- with an open job stays with its customer, and search lists active
-- customers first. (The guard's lock is shown by race 18 in
-- scripts/test-concurrency.sh: pgTAP runs on one connection.)
begin;
\ir helpers/setup.psql

select plan(7);

insert into customers (id, first_name, last_name) values
  ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Moved'),
  ('00000000-0000-0000-0000-0000000000c3', 'Alex', 'Moved');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c2', 'Sam''s frame');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- A racquet with an open job stays with its customer
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 20);

select throws_like(
  $$ update customer_rackets set customer_id = '00000000-0000-0000-0000-0000000000c3'
      where id = '00000000-0000-0000-0000-0000000000f1' $$,
  'This racquet has a string job open: deliver or cancel it before moving it to another customer',
  'a racquet with an open job can''t be moved to another customer');
select throws_like($$ select set_customer_active('00000000-0000-0000-0000-0000000000c2', false, 'Moved away') $$,
                   'This customer has a string job open: settle it before making them inactive',
                   'so its owner still can''t be made inactive with the job open');
select lives_ok($$ update customer_rackets set notes = 'Grip worn' where id = '00000000-0000-0000-0000-0000000000f1' $$,
                'other changes to the racquet still save');

select lives_ok($$ select cancel_string_job('00000000-0000-0000-0000-000000000f01') $$, 'the job is cancelled');
select lives_ok(
  $$ update customer_rackets set customer_id = '00000000-0000-0000-0000-0000000000c3'
      where id = '00000000-0000-0000-0000-0000000000f1' $$,
  'then the racquet can move');

-- ---------------------------------------------------------------------------
-- Active customers first
-- ---------------------------------------------------------------------------
-- By name Alex comes before Sam; Alex is made inactive.
select lives_ok($$ select set_customer_active('00000000-0000-0000-0000-0000000000c3', false, 'Duplicate') $$,
                'Alex is made inactive');
select is((select array_agg(first_name) from search_customers('Moved', 8, true)), array['Sam', 'Alex'],
          'an inactive customer comes after the active ones');

select * from finish();
rollback;
