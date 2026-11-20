-- Assigning string jobs to a stringer (Phase 3A).
begin;
\ir helpers/setup.psql

select plan(10);

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame 2');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price,
                         assigned_to)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50, 30, ' Alex '),
       ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50, 30, null);

select is((select assigned_to from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 'Alex',
          'a job can be assigned at drop-off, the name tidied');
select is((select assigned_to from string_jobs where id = '00000000-0000-0000-0000-000000000f02'), null,
          'or left unassigned');

select lives_ok($$ update string_jobs set assigned_to = 'Jo' where id = '00000000-0000-0000-0000-000000000f02' $$,
                'a waiting job can be assigned later');
select lives_ok($$ update string_jobs set assigned_to = '  ' where id = '00000000-0000-0000-0000-000000000f02' $$,
                'and unassigned again with a blank name');
select is((select assigned_to from string_jobs where id = '00000000-0000-0000-0000-000000000f02'), null,
          'a blank name means unassigned');
select throws_like($$ update string_jobs set assigned_to = repeat('x', 61) where id = '00000000-0000-0000-0000-000000000f02' $$,
                   '%ck_string_jobs_assigned_to%', 'a name is at most 60 characters');

-- Completing records the assigned stringer when nobody else was recorded.
select is(advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete'), 'complete',
          'an assigned job can be completed without picking a stringer');
select is((select strung_by from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 'Alex',
          'and records the assigned stringer as who strung it');
select throws_like($$ update string_jobs set assigned_to = 'Jo' where id = '00000000-0000-0000-0000-000000000f01' $$,
                   'The racquet has been strung, so who it''s assigned to can''t change',
                   'a strung job''s assignment is fixed');

-- A recorded stringer wins over the assignment; nobody at all is still refused.
update string_jobs set assigned_to = 'Jo', strung_by = 'Sam' where id = '00000000-0000-0000-0000-000000000f02';
select advance_string_job('00000000-0000-0000-0000-000000000f02', 'complete');
select is((select strung_by from string_jobs where id = '00000000-0000-0000-0000-000000000f02'), 'Sam',
          'the stringer recorded on the job is kept');

select * from finish();
rollback;
