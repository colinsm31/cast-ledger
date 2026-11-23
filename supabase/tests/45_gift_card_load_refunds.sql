-- Refunding an unused gift card load with an admin's approval (Phase 3D).
begin;
\ir helpers/setup.psql

select plan(15);

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

insert into gift_cards (id, code) values
  ('00000000-0000-0000-0000-0000000000e1', 'GC-45A'),
  ('00000000-0000-0000-0000-0000000000e2', 'GC-45B'),
  ('00000000-0000-0000-0000-0000000000e3', 'GC-45C');

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
select throws_ok($$ select approve_refund() $$, '42501', 'Only an admin can approve refunding a gift card load',
                 'staff can''t approve it themselves');
select throws_ok($$ insert into refund_approvals default values $$, '42501', null,
                 'or write an approval directly');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
create temp table ap as select approve_refund() as first, approve_refund() as second;
grant select on ap to authenticated;
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_like($$ select tests.refund_load((select a from s), 100, (select first from ap), p_qty => 2) $$,
                   'A gift card load is refunded whole', 'a load is refunded whole');
select throws_like($$ select tests.refund_load((select a from s), 50, (select first from ap), 'gift_card',
                                               '00000000-0000-0000-0000-0000000000e1') $$,
                   'A refunded load can''t go back onto the same gift card', 'the money doesn''t go back onto the card');
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
