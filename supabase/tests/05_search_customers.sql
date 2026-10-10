-- search_customers: name / full name / email / phone matching, literal
-- handling of special characters, ordering and limits.
begin;
\ir helpers/setup.psql

select plan(17);

insert into customers (id, first_name, last_name, phone_number, email) values
  ('00000000-0000-0000-0000-0000000001c1', 'Jane',  'O''Brien',     '(225)555-1234', 'jane.obrien@example.com'),
  ('00000000-0000-0000-0000-0000000001c2', 'John',  'Smith, Jr',    '(504)555-9876', null),
  ('00000000-0000-0000-0000-0000000001c3', 'Anna',  'Smith',        null,            'anna_s@example.com'),
  ('00000000-0000-0000-0000-0000000001c4', 'Percy', '100% Tennis',  null,            null);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.found_ids(p_term text, p_limit integer default 8)
returns uuid[] language sql as $$
  select coalesce(array_agg(id order by lower(last_name), lower(first_name)), '{}')
  from search_customers(p_term, p_limit)
$$;

select is(pg_temp.found_ids('jane'), array['00000000-0000-0000-0000-0000000001c1']::uuid[],
          'matches first name, case-insensitive');
select is(pg_temp.found_ids('o''brien'), array['00000000-0000-0000-0000-0000000001c1']::uuid[],
          'matches last name with an apostrophe');
select is(pg_temp.found_ids('jane o'), array['00000000-0000-0000-0000-0000000001c1']::uuid[],
          'matches "first last"');
select is(pg_temp.found_ids('smith, j'), array['00000000-0000-0000-0000-0000000001c2']::uuid[],
          'matches "last, first" (and a comma in the input is safe)');
select is(pg_temp.found_ids('Smith, Jr'), array['00000000-0000-0000-0000-0000000001c2']::uuid[],
          'a last name containing a comma is searchable');
select is(pg_temp.found_ids('smith'),
          array['00000000-0000-0000-0000-0000000001c3', '00000000-0000-0000-0000-0000000001c2']::uuid[],
          'results are ordered by last name, then first name');
select is(pg_temp.found_ids('example.com'),
          array['00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000001c3']::uuid[],
          'matches email');
select is(pg_temp.found_ids('225-555-12'), array['00000000-0000-0000-0000-0000000001c1']::uuid[],
          'matches phone by digits, ignoring punctuation');
select is(pg_temp.found_ids('225-555'),
          array['00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000000c1']::uuid[],
          'a shorter phone fragment matches every customer sharing it');
select is(pg_temp.found_ids('(504) 555 98'), array['00000000-0000-0000-0000-0000000001c2']::uuid[],
          'matches a partially typed formatted phone number');
select is(pg_temp.found_ids('100%'), array['00000000-0000-0000-0000-0000000001c4']::uuid[],
          '% in the input is matched literally (and digits inside a name are not a phone search)');
select is(pg_temp.found_ids('%'), array['00000000-0000-0000-0000-0000000001c4']::uuid[],
          'a lone % is not a wildcard');
select is(pg_temp.found_ids('a_s'), array['00000000-0000-0000-0000-0000000001c3']::uuid[],
          '_ in the input is matched literally');
select is(pg_temp.found_ids('a5s'), '{}'::uuid[],
          '_ is not a single-character wildcard');
select is(pg_temp.found_ids('  '), '{}'::uuid[], 'blank input returns nothing');
select lives_ok($$ select * from search_customers('a(b),c.d') $$,
          'parentheses and commas never break the query');
select is(cardinality(pg_temp.found_ids('a', 2)), 2, 'p_limit caps the number of results');

select * from finish();
rollback;
