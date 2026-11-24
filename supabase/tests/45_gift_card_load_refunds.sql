-- Refunding an unused gift card load with an admin's approval (Phase 3D).
begin;
\ir helpers/setup.psql

select plan(24);

create function tests.refund_load(p_sale uuid, p_amount numeric, p_approval uuid default null,
                                  p_method text default 'cash', p_card uuid default null, p_qty integer default 1)
returns uuid language sql as $$
  select record_refund(
    p_sale,
    jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = p_sale), 'qty', p_qty)),
    jsonb_build_array(jsonb_build_object('method', p_method, 'amount', p_amount, 'gift_card_id', p_card)),
    'Loaded the wrong card', null, null, p_approval);
$$;
grant execute on function tests.refund_load(uuid, numeric, uuid, text, uuid, integer) to authenticated;
-- A sale's gift card load lines, as an admin approves them (0083).
create function tests.loads(p_sale uuid) returns uuid[] language sql as $$
  select array_agg(id order by unit_price, id) from sale_lines where sale_id = p_sale and gift_card_id is not null;
$$;
grant execute on function tests.loads(uuid) to authenticated;

insert into gift_cards (id, code) values
  ('00000000-0000-0000-0000-0000000000e1', 'GC-45A'),
  ('00000000-0000-0000-0000-0000000000e2', 'GC-45B'),
  ('00000000-0000-0000-0000-0000000000e3', 'GC-45C'),
  ('00000000-0000-0000-0000-0000000000e4', 'GC-45D'),
  ('00000000-0000-0000-0000-0000000000e5', 'GC-45E');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Three loads, each on its own sale to Pat: $50 on A, $30 on B (then $5 spent), $20 on C.
create temp table s as select
  record_sale('[{"gift_card_id":"00000000-0000-0000-0000-0000000000e1","qty":1,"unit_price":50}]'::jsonb,
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":50}]'::jsonb, null) as a,
  record_sale('[{"gift_card_id":"00000000-0000-0000-0000-0000000000e2","qty":1,"unit_price":30}]'::jsonb,
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":30}]'::jsonb, null) as b,
  record_sale('[{"gift_card_id":"00000000-0000-0000-0000-0000000000e3","qty":1,"unit_price":20}]'::jsonb,
              '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":20}]'::jsonb, null) as c;
grant select on s to authenticated;
-- Two $50 loads on one sale, D and E (0083).
create temp table two as select record_sale(
  '[{"gift_card_id":"00000000-0000-0000-0000-0000000000e4","qty":1,"unit_price":50},
    {"gift_card_id":"00000000-0000-0000-0000-0000000000e5","qty":1,"unit_price":50}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":100}]'::jsonb, null) as id;
grant select on two to authenticated;
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
       null, '[{"method":"gift_card","amount":5,"gift_card_id":"00000000-0000-0000-0000-0000000000e2"},
              {"method":"cash","amount":16.65}]'::jsonb, null) $$,
  '$5 of card B is spent');

-- ---------------------------------------------------------------------------
-- Staff need an admin
-- ---------------------------------------------------------------------------
select throws_like($$ select tests.refund_load((select a from s), 50) $$,
                   'Refunding a gift card load needs an admin''s approval', 'staff can''t refund a load alone');
select throws_ok($$ select approve_refund((select a from s), 50, tests.loads((select a from s))) $$, '42501', 'Only an admin can approve refunding a gift card load',
                 'staff can''t approve it themselves');
select throws_ok($$ insert into refund_approvals default values $$, '42501', null,
                 'or write an approval directly');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
create temp table ap as select approve_refund((select a from s), 50, tests.loads((select a from s))) as first,
                               approve_refund((select c from s), 20, tests.loads((select c from s))) as second,
                               approve_refund((select c from s), 20, tests.loads((select c from s))) as other_sale,
                               approve_refund((select id from two), 50, array[(select id from sale_lines
                                 where gift_card_id = '00000000-0000-0000-0000-0000000000e4')]) as card_d;
-- An admin writing an approval directly: $20 for A's $50 load.
insert into refund_approvals (id, sale_id, amount, sale_line_ids)
values ('00000000-0000-0000-0000-0000000000aa', (select a from s), 20, tests.loads((select a from s)));
alter table ap add column wrong_amount uuid default '00000000-0000-0000-0000-0000000000aa';
select throws_like($$ select approve_refund((select a from s), 0, tests.loads((select a from s))) $$,
                   'The approved amount must be a positive amount in cents', 'an approval names a real amount');
select throws_like($$ select approve_refund((select a from s), 20, tests.loads((select a from s))) $$,
                   'Those loads come to $50.00, not $20.00', 'and the loads it names add up to it');
select throws_like($$ select approve_refund((select a from s), 50, tests.loads((select c from s))) $$,
                   'Approve gift card loads on this sale', 'and they''re loads on that sale');
select throws_ok($$ insert into refund_approvals (sale_id) values ((select a from s)) $$, '42501', null,
                 'and can''t be written without one');
select throws_ok($$ insert into refund_approvals (sale_id, amount, sale_line_ids, expires_at)
                    values ((select a from s), 50, tests.loads((select a from s)), now() + interval '1 day') $$,
                 '42501', null, 'nor written to last longer than 15 minutes');
grant select on ap to authenticated;
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_like($$ select tests.refund_load((select a from s), 100, (select first from ap), p_qty => 2) $$,
                   'A gift card load is refunded whole', 'a load is refunded whole');
select throws_like($$ select tests.refund_load((select a from s), 50, (select first from ap), 'gift_card',
                                               '00000000-0000-0000-0000-0000000000e1') $$,
                   'A refunded load can''t go back onto the same gift card', 'the money doesn''t go back onto the card');
select throws_like($$ select tests.refund_load((select a from s), 50, (select wrong_amount from ap)) $$,
                   'The admin approved refunding $20.00 of gift card loads, not $50.00: ask again',
                   'an approval for $20 doesn''t refund a $50 load');
select throws_like($$ select tests.refund_load((select a from s), 50, (select other_sale from ap)) $$,
                   'The admin approved a refund on another sale: ask again',
                   'an approval for one sale doesn''t refund another');
select throws_like(
  $$ select record_refund((select id from two),
       jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines
         where gift_card_id = '00000000-0000-0000-0000-0000000000e5'), 'qty', 1)),
       '[{"method":"cash","amount":50}]'::jsonb, null, null, null, (select card_d from ap)) $$,
  'The admin approved refunding other gift card loads on this sale: ask again',
  'an approval for card D''s $50 doesn''t refund card E''s $50');
select throws_like($$ select tests.refund_load((select a from s), 50, gen_random_uuid()) $$,
                   'The admin approval has expired or been used: ask again', 'an unknown approval is refused');
select throws_like($$ select tests.refund_load((select b from s), 30, (select first from ap)) $$,
                   'Gift card GC-45B has $25.00 left of this $30.00 load: only an unused load can be refunded',
                   'a load that''s been partly spent isn''t refunded');

-- ---------------------------------------------------------------------------
-- With the approval
-- ---------------------------------------------------------------------------
create temp table r as select tests.refund_load((select a from s), 50, (select first from ap)) as refund;
grant select on r to authenticated;
select results_eq($$ select subtotal, tax, approved_by from refunds where id = (select refund from r) $$,
                  $$ values (50.00::numeric, 0.00::numeric, '00000000-0000-0000-0000-0000000000a2'::uuid) $$,
                  'the load is refunded, recording the approving admin');
select results_eq(
  $$ select balance, customer_id from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e1' $$,
  $$ values (0::numeric, null::uuid) $$, 'the card is empty and no longer Pat''s');
select is((select reason from gift_card_txns where gift_card_id = '00000000-0000-0000-0000-0000000000e1' and amount < 0),
          'load refund', 'its history shows the load refunded');
select tests.clear_authentication();
select is((select refund_id from refund_approvals where id = (select first from ap)), (select refund from r),
          'the approval is used up by the refund');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select tests.refund_load((select c from s), 20, (select first from ap), 'credit') $$,
                   'The admin approval has expired or been used: ask again', 'an approval is used once');

select tests.clear_authentication();
update refund_approvals set expires_at = now() - interval '1 minute' where id = (select second from ap);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select tests.refund_load((select c from s), 20, (select second from ap), 'credit') $$,
                   'The admin approval has expired or been used: ask again', 'and only for 15 minutes');
select throws_ok($$ update refund_approvals set refund_id = null $$, '42501', null,
                 'staff can''t reset an approval');

-- ---------------------------------------------------------------------------
-- An admin at the register needs no approval
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
create temp table r2 as select tests.refund_load((select c from s), 20, null, 'credit') as refund;
select is((select approved_by from refunds where id = (select refund from r2)),
          '00000000-0000-0000-0000-0000000000a2'::uuid, 'an admin refunds a load themselves, recorded as approving it');

select * from finish();
rollback;
