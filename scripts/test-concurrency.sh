#!/usr/bin/env bash
# Concurrency checks for the money paths (Phase 1B).
#
# pgTAP runs on a single connection, so it can't show what happens when two
# registers hit the same balance at the same moment. This script does: for each
# scenario, session A runs the operation and holds its transaction open for a
# moment, while session B tries the same thing. With row locks in place, B waits
# for A, then sees A's result and is refused. Without them, both succeed.
#
# Scenarios: gift card double spend, store credit double spend, the same sale
# line refunded twice, the same string job charged twice, the last unit of
# stock sold twice with "block overselling" on, the same string job marked
# complete twice (which would use up its string twice), two string jobs
# entered for the last unit of a string with "block overselling" on, the same
# paid job's strings changed twice at once (charging the difference twice),
# a string change racing "Mark complete", a stock adjustment racing a sale of
# the last unit (block overselling on), and two registers receiving units with
# the same barcode at once, the same sold frame returned twice, the same
# demo frame lent twice, the same item exchanged twice, and a job's charge
# refunded while its strings are changed (which must queue, not deadlock),
# a demo lent while its customer is being made inactive, a racquet moved
# to another customer while a job is entered for it, two senders claiming
# the same queued customer message (it must be sent once), and a racquet being
# moved to an inactive customer when a job is entered for it, and a cash sale
# rung while its drawer is being closed (it's counted, or refused, never lost).
#
# Usage:  ./scripts/test-concurrency.sh            (local stack from `supabase start`)
#         DB_URL=postgresql://... ./scripts/test-concurrency.sh
# It creates and then deletes test rows, so only the local database is accepted.
set -euo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
source "$(dirname "$0")/lib/require-local-db.sh"
require_local_db "$DB_URL"
HOLD_SECONDS=2
psql_run() { psql "$DB_URL" -v ON_ERROR_STOP=1 -qAt "$@"; }

new_id() { psql_run -c "select gen_random_uuid()"; }
CATEGORY=$(new_id); PRODUCT=$(new_id); LAST_UNIT_PRODUCT=$(new_id); CUSTOMER=$(new_id)
GIFT_CARD=$(new_id); RACKET=$(new_id); JOB=$(new_id); RACKET_2=$(new_id); JOB_2=$(new_id)
RACKET_3=$(new_id); RACKET_4=$(new_id); LAST_STRING=$(new_id); STAFF=$(new_id)
RACKET_5=$(new_id); RACKET_6=$(new_id); JOB_5=$(new_id); JOB_6=$(new_id); STRING_A=$(new_id); STRING_B=$(new_id)
RACKET_7=$(new_id); JOB_7=$(new_id); CUSTOMER_2=$(new_id); CUSTOMER_3=$(new_id); RACKET_8=$(new_id)
CUSTOMER_4=$(new_id); RACKET_9=$(new_id)
ADJUST_PRODUCT=$(new_id); UNIT_PRODUCT=$(new_id); RACQUET_CATEGORY=$(new_id); APPROVAL=$(new_id); HELD=$(new_id)
DRAWER=$(new_id)
RUN_TAG="concurrency-$(date +%s)"
# "false" if the setting is somehow missing, so cleanup can always restore it.
ORIGINAL_BLOCK_OVERSELL=$(psql_run -c "select coalesce((select block_oversell from settings where id), false)::text")
ORIGINAL_DISCOUNT_CAP=$(psql_run -c "select coalesce((select staff_discount_cap from settings where id), 20)")
ORIGINAL_CASH_NEEDS_DRAWER=$(psql_run -c "select coalesce((select cash_needs_drawer from settings where id), true)::text")
ORIGINAL_TIME_ZONE=$(psql_run -c "select coalesce(quote_literal(time_zone), 'null') from settings where id")
RACE_DIR=$(mktemp -d)

cleanup() {
  psql_run <<SQL >/dev/null
    update settings set block_oversell = ${ORIGINAL_BLOCK_OVERSELL}, staff_discount_cap = ${ORIGINAL_DISCOUNT_CAP},
                        cash_needs_drawer = ${ORIGINAL_CASH_NEEDS_DRAWER}, time_zone = ${ORIGINAL_TIME_ZONE} where id;
    set client_min_messages = warning;
    drop trigger if exists trg_concurrency_pause on refunds;
    drop function if exists concurrency_test_pause();
    create temp table run_sales as
      select id from sales where customer_id = '${CUSTOMER}' or note = '${RUN_TAG}';
    delete from notifications   where customer_id in ('${CUSTOMER}', '${CUSTOMER_2}', '${CUSTOMER_3}', '${CUSTOMER_4}');
    delete from customer_opt_in_changes where customer_id in ('${CUSTOMER}', '${CUSTOMER_2}', '${CUSTOMER_3}', '${CUSTOMER_4}');
    delete from demo_loans      where customer_id in ('${CUSTOMER}', '${CUSTOMER_2}');
    delete from exchanges       where sale_id in (select id from run_sales);
    delete from unit_status_changes where product_unit_id in (select id from product_units where product_id = '${UNIT_PRODUCT}');
    delete from refund_payments where refund_id in (select id from refunds where sale_id in (select id from run_sales));
    delete from refund_lines    where refund_id in (select id from refunds where sale_id in (select id from run_sales));
    update string_jobs set refund_id = null where refund_id in (select id from refunds where sale_id in (select id from run_sales));
    delete from refunds         where sale_id in (select id from run_sales);
    delete from gift_card_txns  where gift_card_id = '${GIFT_CARD}' or sale_id in (select id from run_sales);
    delete from store_credit_txns where customer_id = '${CUSTOMER}';
    delete from inventory_txns  where product_id in ('${PRODUCT}', '${LAST_UNIT_PRODUCT}', '${LAST_STRING}',
                                                     '${STRING_A}', '${STRING_B}', '${ADJUST_PRODUCT}');
    delete from discount_approvals where id = '${APPROVAL}';
    delete from held_tickets    where id = '${HELD}';
    delete from sale_payments   where sale_id in (select id from run_sales);
    delete from sale_lines      where sale_id in (select id from run_sales);
    delete from product_units   where product_id = '${UNIT_PRODUCT}';
    delete from string_jobs     where id in ('${JOB}', '${JOB_2}')
                                   or customer_racket_id in ('${RACKET_3}', '${RACKET_4}', '${RACKET_5}', '${RACKET_6}',
                                                             '${RACKET_7}', '${RACKET_8}', '${RACKET_9}');
    delete from sales           where id in (select id from run_sales);
    delete from drawer_sessions where drawer_id = '${DRAWER}';
    delete from drawers         where id = '${DRAWER}';
    delete from customer_rackets where id in ('${RACKET}', '${RACKET_2}', '${RACKET_3}', '${RACKET_4}',
                                             '${RACKET_5}', '${RACKET_6}', '${RACKET_7}', '${RACKET_8}', '${RACKET_9}');
    delete from gift_cards      where id = '${GIFT_CARD}';
    delete from customers       where id in ('${CUSTOMER}', '${CUSTOMER_2}', '${CUSTOMER_3}', '${CUSTOMER_4}');
    delete from products        where id in ('${PRODUCT}', '${LAST_UNIT_PRODUCT}', '${LAST_STRING}',
                                             '${STRING_A}', '${STRING_B}', '${ADJUST_PRODUCT}', '${UNIT_PRODUCT}');
    delete from categories      where id in ('${CATEGORY}', '${RACQUET_CATEGORY}');
    delete from profiles        where id = '${STAFF}';
    delete from auth.users      where id = '${STAFF}';
SQL
  rm -rf "$RACE_DIR"
}
trap cleanup EXIT

# Every race below spends one $20 item plus tax.
TAX_RATE=$(psql_run -c "select tax_rate from settings where id")
SPEND_TOTAL=$(psql_run -c "select round(20 * (1 + ${TAX_RATE} / 100.0), 2)")

# Fixtures: a gift card and store credit each holding exactly one item's total,
# a $20 product with plenty of stock, a product with exactly one unit, an
# unpaid $30 string job, a second job strung with the $20 product, a string
# with exactly one unit, and a temporary staff account (string jobs entered by
# a signed-in user are checked for availability).
# The races take cash without a drawer; the drawer race turns the check back on.
psql_run -c "update settings set cash_needs_drawer = false where id" >/dev/null
psql_run <<SQL >/dev/null
  insert into categories (id, name) values ('${CATEGORY}', '${RUN_TAG}');
  insert into products (id, category_id, name, sell_price) values
    ('${PRODUCT}', '${CATEGORY}', 'Concurrency item', 20),
    ('${LAST_UNIT_PRODUCT}', '${CATEGORY}', 'Last unit', 20);
  insert into inventory_txns (txn_type, product_id, qty) values
    ('receive', '${PRODUCT}', 100), ('receive', '${LAST_UNIT_PRODUCT}', 1);
  insert into customers (id, first_name, last_name) values ('${CUSTOMER}', 'Concurrency', 'Test');
  insert into gift_cards (id, code) values ('${GIFT_CARD}', '${RUN_TAG}');
  insert into gift_card_txns (gift_card_id, amount, reason) values ('${GIFT_CARD}', ${SPEND_TOTAL}, 'load');
  insert into store_credit_txns (customer_id, amount, reason) values ('${CUSTOMER}', ${SPEND_TOTAL}, 'fixture');
  insert into customer_rackets (id, customer_id, model) values ('${RACKET}', '${CUSTOMER}', 'Frame');
  insert into string_jobs (id, customer_racket_id, price) values ('${JOB}', '${RACKET}', 30);
  insert into customer_rackets (id, customer_id, model) values ('${RACKET_2}', '${CUSTOMER}', 'Second frame');
  -- Jobs that get marked complete need a stringer (0051).
  insert into string_jobs (id, customer_racket_id, main_product_id, price, strung_by)
  values ('${JOB_2}', '${RACKET_2}', '${PRODUCT}', 30, 'Concurrency');
  insert into customer_rackets (id, customer_id, model) values
    ('${RACKET_3}', '${CUSTOMER}', 'Third frame'), ('${RACKET_4}', '${CUSTOMER}', 'Fourth frame');
  insert into products (id, category_id, brand, name, sell_price, attributes)
  select '${LAST_STRING}', id, 'Concurrency', '${RUN_TAG}', 20, '{"color":"Black","gauge":"17"}'
    from categories where name = 'Strings';
  insert into inventory_txns (txn_type, product_id, qty) values ('receive', '${LAST_STRING}', 1);
  insert into auth.users (id, email, aud, role)
  values ('${STAFF}', '${RUN_TAG}@concurrency.test', 'authenticated', 'authenticated');
  update profiles set role = 'staff' where id = '${STAFF}';
  -- Two paid jobs on 20-dollar strings, for the string-change races.
  insert into products (id, category_id, brand, name, sell_price, attributes)
  select v.id, c.id, 'Concurrency', v.name, v.price, '{"color":"Black","gauge":"17"}'
    from categories c,
         (values ('${STRING_A}'::uuid, '${RUN_TAG} A', 20), ('${STRING_B}'::uuid, '${RUN_TAG} B', 30)) v(id, name, price)
   where c.name = 'Strings';
  insert into inventory_txns (txn_type, product_id, qty) values ('receive', '${STRING_A}', 10), ('receive', '${STRING_B}', 10);
  insert into customer_rackets (id, customer_id, model) values
    ('${RACKET_5}', '${CUSTOMER}', 'Fifth frame'), ('${RACKET_6}', '${CUSTOMER}', 'Sixth frame');
  insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price, strung_by) values
    ('${JOB_5}', '${RACKET_5}', '${STRING_A}', '${STRING_A}', 52, 52, 20, null),
    ('${JOB_6}', '${RACKET_6}', '${STRING_A}', '${STRING_A}', 52, 52, 20, 'Concurrency');
  -- One unit of a counted product (adjust vs sale), and a unit-tracked product.
  insert into products (id, category_id, name, sell_price) values ('${ADJUST_PRODUCT}', '${CATEGORY}', 'Adjust race', 20);
  insert into inventory_txns (txn_type, product_id, qty) values ('receive', '${ADJUST_PRODUCT}', 1);
  insert into categories (id, name, serialized_default) values ('${RACQUET_CATEGORY}', '${RUN_TAG} units', true);
  insert into products (id, category_id, name, sell_price) values ('${UNIT_PRODUCT}', '${RACQUET_CATEGORY}', 'Unit race', 200);
SQL

# Wait until session A (started with PGAPPNAME=$1, process $2) has run its
# statement and is holding its transaction open in pg_sleep, so B really
# starts second. Gives up (returns 1) if A ends first or after 10 seconds,
# rather than racing on a guess.
wait_until_holding() {
  for _ in $(seq 1 100); do
    [[ "$(psql_run -c "select exists (select 1 from pg_stat_activity
                                      where application_name = '$1' and wait_event = 'PgSleep')")" == "t" ]] && return 0
    kill -0 "$2" 2>/dev/null || break
    sleep 0.1
  done
  echo "Session A ($1) never reached its hold; this race wasn't run." >&2
  return 1
}

# Run a statement in two sessions (or a second statement in session B): A holds
# its transaction open while B starts. Prints how many of the two succeeded.
race() {
  local statement="$1" statement_b="${2:-$1}" successes=0 session_a="race-a-$$-$RANDOM"
  ( PGAPPNAME="$session_a" psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 \
      -c "begin; ${statement}; select pg_sleep(${HOLD_SECONDS}); commit;" >/dev/null 2>&1 \
      && echo ok > "$RACE_DIR/a" ) &
  if ! wait_until_holding "$session_a" $!; then
    wait
    rm -f "$RACE_DIR/a"
    echo "not run"
    return
  fi
  psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 -c "begin; ${statement_b}; commit;" >/dev/null 2>&1 && echo ok > "$RACE_DIR/b"
  wait
  [[ -f "$RACE_DIR/a" ]] && successes=$((successes + 1))
  [[ -f "$RACE_DIR/b" ]] && successes=$((successes + 1))
  rm -f "$RACE_DIR/a" "$RACE_DIR/b"
  echo "$successes"
}

failures=0
check() {
  local name="$1" successes="$2" detail="$3"
  if [[ "$successes" == "1" ]]; then
    echo "ok     - ${name} (${detail})"
  else
    echo "FAILED - ${name}: ${successes} of 2 concurrent attempts succeeded (${detail})"
    failures=$((failures + 1))
  fi
}

# 1. Gift card: two sales each try to spend the card's whole balance.
n=$(race "select record_sale('[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb, null,
  '[{\"method\":\"gift_card\",\"amount\":${SPEND_TOTAL},\"gift_card_id\":\"${GIFT_CARD}\"}]'::jsonb, '${RUN_TAG}')")
check "gift card spent by two registers at once" "$n" \
  "balance now $(psql_run -c "select balance from gift_card_balance where gift_card_id = '${GIFT_CARD}'")"

# 2. Store credit: two sales each try to spend the customer's whole credit.
n=$(race "select record_sale('[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb, '${CUSTOMER}',
  '[{\"method\":\"store_credit\",\"amount\":${SPEND_TOTAL}}]'::jsonb, null)")
check "store credit spent by two registers at once" "$n" \
  "balance now $(psql_run -c "select balance from customer_store_credit where customer_id = '${CUSTOMER}'")"

# 3. Refund: two refunds of the only unit on a sale line.
SALE=$(psql_run -c "select record_sale('[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb, null,
  '[{\"method\":\"cash\",\"amount\":${SPEND_TOTAL}}]'::jsonb, '${RUN_TAG}')")
LINE=$(psql_run -c "select id from sale_lines where sale_id = '${SALE}'")
n=$(race "select record_refund('${SALE}', '[{\"sale_line_id\":\"${LINE}\",\"qty\":1}]'::jsonb,
  '[{\"method\":\"cash\",\"amount\":${SPEND_TOTAL}}]'::jsonb, null, null)")
check "one sold item refunded by two registers at once" "$n" \
  "$(psql_run -c "select coalesce(sum(qty), 0) from refund_lines where sale_line_id = '${LINE}'") of 1 returned"

# 4. String job: two tickets charge the same job (stringing tax may apply).
JOB_TOTAL=$(psql_run -c "select 30 + case when tax_stringing then round(30 * tax_rate / 100.0, 2) else 0 end from settings where id")
n=$(race "select record_sale('[{\"string_job_id\":\"${JOB}\",\"qty\":1,\"unit_price\":30}]'::jsonb, null,
  '[{\"method\":\"cash\",\"amount\":${JOB_TOTAL}}]'::jsonb, '${RUN_TAG}')")
check "one string job charged by two registers at once" "$n" \
  "$(psql_run -c "select count(*) from sale_lines where string_job_id = '${JOB}'") charge(s) recorded"

# 5. Last unit with overselling blocked: two sales of the only unit.
psql_run -c "update settings set block_oversell = true where id" >/dev/null
n=$(race "select record_sale('[{\"product_id\":\"${LAST_UNIT_PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb, null,
  '[{\"method\":\"cash\",\"amount\":${SPEND_TOTAL}}]'::jsonb, '${RUN_TAG}')")
check "last unit sold by two registers at once (block overselling on)" "$n" \
  "on hand now $(psql_run -c "select on_hand from product_stock where product_id = '${LAST_UNIT_PRODUCT}'")"

# 6. String job: two clicks of "Mark complete" on the same job.
n=$(race "select advance_string_job('${JOB_2}', 'complete')")
check "one string job completed twice at once" "$n" \
  "$(psql_run -c "select count(*) from inventory_txns where product_id = '${PRODUCT}' and txn_type = 'consume'") string use(s) recorded"

# 7. Last unit of a string: two registers enter jobs (different racquets) for it
#    as a signed-in staff member, with overselling blocked.
psql_run -c "update settings set block_oversell = true where id" >/dev/null
AS_STAFF="select set_config('request.jwt.claim.sub', '${STAFF}', true),
  set_config('request.jwt.claims', '{\"sub\":\"${STAFF}\",\"role\":\"authenticated\"}', true);
  set local role authenticated"
enter_job() {
  echo "${AS_STAFF}; insert into string_jobs (customer_racket_id, main_product_id, cross_product_id,
    main_tension, cross_tension, price) values ('$1', '${LAST_STRING}', '${LAST_STRING}', 52, 52, 30)"
}
n=$(race "$(enter_job "${RACKET_3}")" "$(enter_job "${RACKET_4}")")
check "last unit of a string set aside by two registers at once (block overselling on)" "$n" \
  "$(psql_run -c "select count(*) from string_jobs where main_product_id = '${LAST_STRING}'") job(s) entered"

# 8. The same paid job's strings changed to dearer ones by two registers at once:
#    the difference is charged once; the second sees the new strings and is refused.
for job in "${JOB_5}" "${JOB_6}"; do
  total=$(psql_run -c "select 20 + case when tax_stringing then round(20 * tax_rate / 100.0, 2) else 0 end from settings where id")
  psql_run -c "select record_sale('[{\"string_job_id\":\"${job}\",\"qty\":1,\"unit_price\":20}]'::jsonb,
    '${CUSTOMER}', '[{\"method\":\"cash\",\"amount\":${total}}]'::jsonb, '${RUN_TAG}')" >/dev/null
done
change_strings() {
  local total
  total=$(psql_run -c "select string_change_quote('$1', '${STRING_B}', '${STRING_B}')->>'total'")
  echo "${AS_STAFF}; select change_paid_string_job('$1', '${STRING_B}', '${STRING_B}', 52, 52,
    '[{\"method\":\"cash\",\"amount\":${total}}]'::jsonb)"
}
n=$(race "$(change_strings "${JOB_5}")")
check "one paid job's strings changed by two registers at once" "$n" \
  "$(psql_run -c "select count(*) from sale_lines where string_job_id = '${JOB_5}' and kind = 'string_change'") difference charge(s) recorded"

# 9. A string change racing "Mark complete" on the same job: whichever goes
#    first, the string used up must be the job's final string.
( PGAPPNAME="race-change-$$" psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 \
    -c "begin; $(change_strings "${JOB_6}"); select pg_sleep(${HOLD_SECONDS}); commit;" >/dev/null 2>&1 ) &
wait_until_holding "race-change-$$" $! || failures=$((failures + 1))
psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 \
  -c "begin; ${AS_STAFF}; select advance_string_job('${JOB_6}', 'complete'); commit;" >/dev/null 2>&1 || true
wait
consistent=$(psql_run -c "select (select status from string_jobs where id = '${JOB_6}') = 'complete'
  and (select array_agg(distinct product_id) from inventory_txns
        where txn_type = 'consume' and product_id in ('${STRING_A}', '${STRING_B}')
          and created_at > now() - interval '1 minute')
      = array[(select main_product_id from string_jobs where id = '${JOB_6}')]")
check "a string change racing \"Mark complete\"" "$([[ "$consistent" == "t" ]] && echo 1 || echo 0)" \
  "job strung with $(psql_run -c "select p.name from string_jobs j join products p on p.id = j.main_product_id where j.id = '${JOB_6}'")"

# 10. With overselling blocked, a sale of the only unit is in progress when a
#     "−1" stock adjustment runs: one goes through, and stock never goes below
#     zero. (Adjustment first is serialized by the product's foreign key anyway;
#     this order needs adjust_stock's own lock.)
psql_run -c "update settings set block_oversell = true where id" >/dev/null
SALE_TOTAL=$(psql_run -c "select round(20 * (1 + tax_rate / 100.0), 2) from settings where id")
n=$(race "${AS_STAFF}; select record_sale('[{\"product_id\":\"${ADJUST_PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb,
            null, '[{\"method\":\"cash\",\"amount\":${SALE_TOTAL}}]'::jsonb, '${RUN_TAG}')" \
         "${AS_STAFF}; select adjust_stock('${ADJUST_PRODUCT}', -1, 'count')")
check "a stock adjustment racing a sale of the last unit (block overselling on)" "$n" \
  "on hand now $(psql_run -c "select on_hand from product_stock where product_id = '${ADJUST_PRODUCT}'")"

# 11. Two registers receive a unit with the same new barcode at once, one as
#     UPC-A (12 digits) and one as EAN-13 (a leading 0). The unique index alone
#     can't see these are the same code; the barcode lock must.
UPC=$(printf '9%011d' "$(( $(date +%s) % 100000000000 ))")
n=$(race "select receive_units('${UNIT_PRODUCT}', '[\"${UPC}\"]'::jsonb)" \
         "select receive_units('${UNIT_PRODUCT}', '[\"0${UPC}\"]'::jsonb)")
check "one unit barcode (UPC-A vs EAN-13) received by two registers at once" "$n" \
  "$(psql_run -c "select count(*) from product_units where barcode in ('${UPC}', '0${UPC}')") unit(s) with that code"

# 12. One admin approval for a discount over the staff limit, used by two
#     registers at once: one sale goes through, and the approval names it.
psql_run -c "update settings set staff_discount_cap = 20, block_oversell = false where id" >/dev/null
psql_run -c "insert into discount_approvals (id, approved_by, max_percent) values ('${APPROVAL}', '${STAFF}', 60)" >/dev/null
HALF_TOTAL=$(psql_run -c "select round(10 * (1 + ${TAX_RATE} / 100.0), 2)")
n=$(race "${AS_STAFF}; select record_sale('[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20,
            \"discount\":0.5,\"discount_reason\":\"Damaged\"}]'::jsonb,
            null, '[{\"method\":\"cash\",\"amount\":${HALF_TOTAL}}]'::jsonb, '${RUN_TAG}', null, '${APPROVAL}')")
check "one discount approval used by two registers at once" "$n" \
  "$(psql_run -c "select count(*) from sales where discount_approved_by = '${STAFF}' and note = '${RUN_TAG}'") sale(s) approved"

# 13. One held ticket recalled at two registers at once: one gets it.
psql_run -c "insert into held_tickets (id, name, ticket, held_by, expires_at)
  values ('${HELD}', '${RUN_TAG}', '{\"lines\":[{\"key\":\"k\",\"qty\":1}]}', '${STAFF}', now() + interval '1 hour')" >/dev/null
n=$(race "${AS_STAFF}; select recall_held_ticket('${HELD}')")
check "one held ticket recalled at two registers at once" "$n" \
  "$(psql_run -c "select count(*) from held_tickets where id = '${HELD}'") left on hold"

# 14. One sold racquet frame returned at two registers at once: one return
#     goes through and the frame is back in stock once (0070).
FRAME_CODE="${RUN_TAG}-frame"
psql_run -c "select receive_units('${UNIT_PRODUCT}', '[\"${FRAME_CODE}\"]'::jsonb)" >/dev/null
FRAME=$(psql_run -c "select id from product_units where barcode = '${FRAME_CODE}'")
FRAME_TOTAL=$(psql_run -c "select round(200 * (1 + ${TAX_RATE} / 100.0), 2)")
FRAME_SALE=$(psql_run -c "select record_sale('[{\"product_id\":\"${UNIT_PRODUCT}\",\"product_unit_id\":\"${FRAME}\",
  \"qty\":1,\"unit_price\":200}]'::jsonb, null, '[{\"method\":\"cash\",\"amount\":${FRAME_TOTAL}}]'::jsonb, '${RUN_TAG}')")
FRAME_LINE=$(psql_run -c "select id from sale_lines where sale_id = '${FRAME_SALE}'")
n=$(race "select record_refund('${FRAME_SALE}', '[{\"sale_line_id\":\"${FRAME_LINE}\",\"qty\":1}]'::jsonb,
  '[{\"method\":\"cash\",\"amount\":${FRAME_TOTAL}}]'::jsonb, null, null)")
check "one racquet frame returned by two registers at once" "$n" \
  "$(psql_run -c "select status || ', ' || (select count(*) from unit_status_changes where product_unit_id = '${FRAME}' and from_status = 'sold') || ' return(s) in its history' from product_units where id = '${FRAME}'")"

# 15. One demo frame lent at two registers at once: one loan goes out, the
#     other register is told it's already out (0071).
DEMO_CODE="${RUN_TAG}-demo"
psql_run -c "select receive_units('${UNIT_PRODUCT}', '[\"${DEMO_CODE}\"]'::jsonb)" >/dev/null
DEMO=$(psql_run -c "select id from product_units where barcode = '${DEMO_CODE}'")
psql_run -c "select set_unit_status('${DEMO}', 'demo', 'Demo fleet')" >/dev/null
n=$(race "select check_out_demo('${DEMO}', '${CUSTOMER}')")
check "one demo frame lent by two registers at once" "$n" \
  "$(psql_run -c "select count(*) || ' loan(s), frame ' || (select status from product_units where id = '${DEMO}') from demo_loans where product_unit_id = '${DEMO}'")"

# 16. One sold item exchanged at two registers at once: one exchange goes
#     through, the other is told the item is already returned (0077).
SWAP_TOTAL=$(psql_run -c "select round(20 * (1 + ${TAX_RATE} / 100.0), 2)")
SWAP_SALE=$(psql_run -c "select record_sale('[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb,
  '${CUSTOMER}', '[{\"method\":\"cash\",\"amount\":${SWAP_TOTAL}}]'::jsonb, '${RUN_TAG}')")
SWAP_LINE=$(psql_run -c "select id from sale_lines where sale_id = '${SWAP_SALE}'")
n=$(race "select record_exchange('${SWAP_SALE}', '[{\"sale_line_id\":\"${SWAP_LINE}\",\"qty\":1}]'::jsonb,
  '[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb, '${CUSTOMER}', '[]'::jsonb, '[]'::jsonb, null)")
check "one sold item exchanged by two registers at once" "$n" \
  "$(psql_run -c "select count(*) from exchanges e join refunds r on r.id = e.refund_id where r.sale_id = '${SWAP_SALE}'") exchange(s)"

# 17. A paid job's charge refunded at one register while its strings are
#     changed to cheaper ones at another (0079). The string change locks the
#     job, then its sales; the refund must take them in the same order, or the
#     two stop with "deadlock detected". A test-only pause after the refund's
#     row is written holds the refund open just after its first locks.
psql_run <<SQL >/dev/null
  insert into customer_rackets (id, customer_id, model) values ('${RACKET_7}', '${CUSTOMER}', 'Seventh frame');
  insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
  values ('${JOB_7}', '${RACKET_7}', '${STRING_B}', '${STRING_B}', 52, 52, 30);
  create function concurrency_test_pause() returns trigger language plpgsql as \$\$
  begin
    if current_setting('acestock.concurrency_pause', true) = 'on' then perform pg_sleep(${HOLD_SECONDS}); end if;
    return new;
  end;
  \$\$;
  create trigger trg_concurrency_pause after insert on refunds for each row execute function concurrency_test_pause();
SQL
JOB_7_TOTAL=$(psql_run -c "select 30 + case when tax_stringing then round(30 * tax_rate / 100.0, 2) else 0 end from settings where id")
JOB_7_SALE=$(psql_run -c "select record_sale('[{\"string_job_id\":\"${JOB_7}\",\"qty\":1,\"unit_price\":30}]'::jsonb,
  '${CUSTOMER}', '[{\"method\":\"cash\",\"amount\":${JOB_7_TOTAL}}]'::jsonb, '${RUN_TAG}')")
JOB_7_LINE=$(psql_run -c "select id from sale_lines where sale_id = '${JOB_7_SALE}'")
GIVE_BACK=$(psql_run -c "select abs((string_change_quote('${JOB_7}', '${STRING_A}', '${STRING_A}')->>'total')::numeric)")
( PGAPPNAME="race-refund-$$" psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 -c "begin;
    select set_config('acestock.concurrency_pause', 'on', true);
    select record_refund('${JOB_7_SALE}', '[{\"sale_line_id\":\"${JOB_7_LINE}\",\"qty\":1}]'::jsonb,
      '[{\"method\":\"cash\",\"amount\":${JOB_7_TOTAL}}]'::jsonb, null, null);
    commit;" > "$RACE_DIR/refund" 2>&1 ) &
wait_until_holding "race-refund-$$" $! || failures=$((failures + 1))
psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 -c "begin; ${AS_STAFF};
  select change_paid_string_job('${JOB_7}', '${STRING_A}', '${STRING_A}', 52, 52,
    '[{\"method\":\"cash\",\"amount\":${GIVE_BACK}}]'::jsonb); commit;" > "$RACE_DIR/change" 2>&1 || true
wait
JOB_7_REFUNDS=$(psql_run -c "select count(*) from refunds where sale_id = '${JOB_7_SALE}'")
if grep -qi "deadlock" "$RACE_DIR/refund" "$RACE_DIR/change"; then
  check "a job's charge refunded while its strings change" 0 "deadlock detected"
elif [[ "$JOB_7_REFUNDS" -lt 1 ]] || grep -qi "error" "$RACE_DIR/refund"; then
  check "a job's charge refunded while its strings change" 0 "the refund failed: $(head -c 200 "$RACE_DIR/refund")"
else
  check "a job's charge refunded while its strings change" 1 \
    "no deadlock; refund recorded, job $(psql_run -c "select status from string_jobs where id = '${JOB_7}'")"
fi

# 18. A customer made inactive at one register while a demo is lent to them
#     at another (0080): the demo waits for the deactivation and is refused,
#     so no inactive customer has a demo out.
psql_run -c "insert into customers (id, first_name, last_name) values ('${CUSTOMER_2}', 'Concurrency', 'Leaving')" >/dev/null
DEMO_2_CODE="${RUN_TAG}-demo-2"
psql_run -c "select receive_units('${UNIT_PRODUCT}', '[\"${DEMO_2_CODE}\"]'::jsonb)" >/dev/null
DEMO_2=$(psql_run -c "select id from product_units where barcode = '${DEMO_2_CODE}'")
psql_run -c "select set_unit_status('${DEMO_2}', 'demo', 'Demo fleet')" >/dev/null
n=$(race "${AS_STAFF}; select set_customer_active('${CUSTOMER_2}', false, 'Moved away')" \
         "select check_out_demo('${DEMO_2}', '${CUSTOMER_2}')")
check "a demo lent while its customer is made inactive" "$n" \
  "$(psql_run -c "select case when is_active then 'active' else 'inactive' end || ' with ' ||
    (select count(*) from demo_loans where customer_id = '${CUSTOMER_2}' and back_at is null) || ' demo(s) out'
    from customers where id = '${CUSTOMER_2}'")"

# 19. A job entered for a racquet at one register while the racquet is moved
#     to another customer at the other: the move waits for the job (the new
#     job locks its racquet, guard_string_job_racket 0042) and is refused
#     (guard_racket_owner 0080), so no racquet has a job open under someone else.
psql_run <<SQL >/dev/null
  insert into customers (id, first_name, last_name) values ('${CUSTOMER_3}', 'Concurrency', 'Taker');
  insert into customer_rackets (id, customer_id, model) values ('${RACKET_8}', '${CUSTOMER}', 'Eighth frame');
SQL
n=$(race "${AS_STAFF}; insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension,
           cross_tension, price) values ('${RACKET_8}', '${STRING_A}', '${STRING_A}', 52, 52, 20)" \
         "update customer_rackets set customer_id = '${CUSTOMER_3}' where id = '${RACKET_8}'")
check "a racquet moved while a job is entered for it" "$n" \
  "$(psql_run -c "select 'racquet with ' || case when customer_id = '${CUSTOMER}' then 'its owner' else 'the other customer' end ||
    ', ' || (select count(*) from string_jobs where customer_racket_id = '${RACKET_8}' and status = 'entered') || ' job(s) open'
    from customer_rackets where id = '${RACKET_8}'")"

# 20. Two senders claim the same queued message (0086, 0088): it's claimed, so
#     sent, only once (claim_notifications takes rows FOR UPDATE SKIP LOCKED).
#     A receipt email, so the ready-message checks (0088) don't come into it.
NOTE_ID=$(psql_run -c "insert into notifications (kind, channel, customer_id, to_address, subject, body)
  values ('receipt', 'email', '${CUSTOMER}', 'race@example.com', 'Receipt', '${RUN_TAG}') returning id")
claim_one="do \$\$ begin
  if not exists (select 1 from claim_notifications(p_id => '${NOTE_ID}')) then
    raise exception 'not claimed';
  end if; end \$\$"
n=$(race "${claim_one}")
check "one customer message claimed by two senders at once" "$n" \
  "$(psql_run -c "select status || ', ' || attempts || ' attempt(s)' from notifications where id = '${NOTE_ID}'")"

# 21. The other order from 19 (0091): the racquet is being moved to an
#     inactive customer when a job is entered for it. The job waits for the
#     move (guard_active_customer locks the racquet before reading its owner)
#     and is refused, so no job is open under an inactive customer.
psql_run <<SQL >/dev/null
  insert into customers (id, first_name, last_name) values ('${CUSTOMER_4}', 'Concurrency', 'Gone');
  insert into customer_rackets (id, customer_id, model) values ('${RACKET_9}', '${CUSTOMER}', 'Ninth frame');
SQL
psql_run -c "${AS_STAFF}; select set_customer_active('${CUSTOMER_4}', false, 'Moved away')" >/dev/null
n=$(race "update customer_rackets set customer_id = '${CUSTOMER_4}' where id = '${RACKET_9}'" \
         "${AS_STAFF}; insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension,
           cross_tension, price) values ('${RACKET_9}', '${STRING_A}', '${STRING_A}', 52, 52, 20)")
check "a job entered while its racquet moves to an inactive customer" "$n" \
  "$(psql_run -c "select 'racquet with ' || case when r.customer_id = '${CUSTOMER_4}' then 'the inactive customer' else 'its owner' end ||
    ', ' || (select count(*) from string_jobs where customer_racket_id = '${RACKET_9}' and status = 'entered') || ' job(s) open'
    from customer_rackets r where r.id = '${RACKET_9}'")"

# 22. A cash sale rung while its drawer is being closed (0109): the sale waits
#     for the close and is refused (the drawer is no longer open), so the
#     closing count's expected cash never misses a sale.
psql_run <<SQL >/dev/null
  update settings set cash_needs_drawer = true, time_zone = coalesce(time_zone, 'UTC') where id;
  insert into drawers (id, name) values ('${DRAWER}', '${RUN_TAG}');
  select open_drawer('${DRAWER}', '{"20": 5}');
SQL
DRAWER_HEADER="select set_config('request.headers', '{\"x-acestock-drawer\":\"${DRAWER}\"}', true)"
n=$(race "select close_drawer((select id from drawer_sessions where drawer_id = '${DRAWER}'), '{\"20\": 5}')" \
         "${DRAWER_HEADER}; select record_sale('[{\"product_id\":\"${PRODUCT}\",\"qty\":1,\"unit_price\":20}]'::jsonb, null,
           '[{\"method\":\"cash\",\"amount\":${SPEND_TOTAL}}]'::jsonb, '${RUN_TAG}')")
check "a cash sale rung while its drawer is closed" "$n" \
  "$(psql_run -c "select 'expected ' || expected_cash || ', ' || (select count(*) from sales where drawer_session_id = ds.id) ||
    ' sale(s) in the drawer' from drawer_sessions ds where drawer_id = '${DRAWER}'")"

rm -rf "$RACE_DIR"
if (( failures > 0 )); then
  echo "${failures} concurrency check(s) failed"
  exit 1
fi
echo "All concurrency checks passed"
