-- Promised time and rush on string jobs (Phase 3A).
begin;
\ir helpers/setup.psql

select plan(15);

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame 2'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Frame 3'),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000c1', 'Frame 4');

create function tests.new_job(p_racket uuid, p_promised timestamptz default null, p_rush boolean default false)
returns uuid language sql as $$
  insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension,
                           price, promised_at, is_rush)
  values (p_racket, '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50,
          30, p_promised, p_rush)
  returning id;
$$;
grant execute on function tests.new_job(uuid, timestamptz, boolean) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- The default promise
-- ---------------------------------------------------------------------------
create temp table j as select tests.new_job('00000000-0000-0000-0000-0000000000f1') as first_id;
grant select on j to authenticated;
select results_eq(
  $$ select promised_at = entered_at + interval '24 hours', is_rush from string_jobs where id = (select first_id from j) $$,
  $$ values (true, false) $$,
  'a new job is promised 24 hours after drop-off, not rushed');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
update settings set stringing_turnaround_hours = 4 where id;
select throws_like($$ update settings set stringing_turnaround_hours = 0 where id $$,
                   '%ck_settings_stringing_turnaround_hours%', 'the turnaround is at least an hour');
select throws_like($$ update settings set stringing_turnaround_hours = 721 where id $$,
                   '%ck_settings_stringing_turnaround_hours%', 'and at most 30 days');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select tests.new_job('00000000-0000-0000-0000-0000000000f2');
select is((select promised_at - entered_at from string_jobs where customer_racket_id = '00000000-0000-0000-0000-0000000000f2'),
          interval '4 hours', 'the shop''s turnaround sets the default promise');

-- ---------------------------------------------------------------------------
-- A promise chosen at drop-off
-- ---------------------------------------------------------------------------
select lives_ok($$ select tests.new_job('00000000-0000-0000-0000-0000000000f3',
                                        date_trunc('minute', now()) + interval '2 hours', true) $$,
                'a promised time and rush can be set at drop-off');
select results_eq(
  $$ select promised_at = date_trunc('minute', now()) + interval '2 hours', is_rush
       from string_jobs where customer_racket_id = '00000000-0000-0000-0000-0000000000f3' $$,
  $$ values (true, true) $$, 'and are kept');
select throws_like($$ select tests.new_job('00000000-0000-0000-0000-0000000000f4', now() - interval '1 hour') $$,
                   'The promised time (%) has already passed', 'a promise in the past is refused');
select throws_like($$ select tests.new_job('00000000-0000-0000-0000-0000000000f4', now() + interval '91 days') $$,
                   'Promise the job within 90 days of drop-off', 'and one too far ahead');

-- ---------------------------------------------------------------------------
-- Changing it while the job waits
-- ---------------------------------------------------------------------------
select lives_ok($$ update string_jobs set promised_at = now() + interval '3 days', is_rush = true
                    where id = (select first_id from j) $$, 'a waiting job''s promise and rush can change');
select results_eq($$ select promised_at > now() + interval '71 hours', is_rush from string_jobs where id = (select first_id from j) $$,
                  $$ values (true, true) $$, 'and the change is saved');
select throws_like($$ update string_jobs set promised_at = null where id = (select first_id from j) $$,
                   'A string job needs a promised time', 'the promise can''t be cleared');
select throws_like($$ update string_jobs set promised_at = now() - interval '1 day' where id = (select first_id from j) $$,
                   'The promised time (%) has already passed', 'or moved into the past');
select lives_ok($$ update string_jobs set is_rush = false where id = (select first_id from j) $$,
                'rush alone can be turned off');

-- Once it's strung, neither changes.
update string_jobs set strung_by = 'Alex' where id = (select first_id from j);
select advance_string_job((select first_id from j), 'complete');
select throws_like($$ update string_jobs set is_rush = true where id = (select first_id from j) $$,
                   'The racquet has been strung, so its promised time and rush can''t change',
                   'a strung job''s rush is fixed');
select throws_like($$ update string_jobs set promised_at = now() + interval '5 days' where id = (select first_id from j) $$,
                   'The racquet has been strung, so its promised time and rush can''t change',
                   'and so is its promise');

select * from finish();
rollback;
