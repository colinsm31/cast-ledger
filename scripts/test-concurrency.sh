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
# complete twice (which would use up its string twice), and two string jobs
# entered for the last unit of a string with "block overselling" on.
#
# Usage:  ./scripts/test-concurrency.sh            (local stack from `supabase start`)
#         DB_URL=postgresql://... ./scripts/test-concurrency.sh
# Never point this at production: it creates and then deletes test rows.
set -euo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
HOLD_SECONDS=2
psql_run() { psql "$DB_URL" -v ON_ERROR_STOP=1 -qAt "$@"; }

new_id() { psql_run -c "select gen_random_uuid()"; }
CATEGORY=$(new_id); PRODUCT=$(new_id); LAST_UNIT_PRODUCT=$(new_id); CUSTOMER=$(new_id)
GIFT_CARD=$(new_id); RACKET=$(new_id); JOB=$(new_id); RACKET_2=$(new_id); JOB_2=$(new_id)
RACKET_3=$(new_id); RACKET_4=$(new_id); LAST_STRING=$(new_id); STAFF=$(new_id)
RUN_TAG="concurrency-$(date +%s)"
ORIGINAL_BLOCK_OVERSELL=$(psql_run -c "select block_oversell::text from settings where id")

cleanup() {
  psql_run <<SQL >/dev/null
    update settings set block_oversell = ${ORIGINAL_BLOCK_OVERSELL} where id;
    create temp table run_sales as
      select id from sales where customer_id = '${CUSTOMER}' or note = '${RUN_TAG}';
    delete from refund_payments where refund_id in (select id from refunds where sale_id in (select id from run_sales));
    delete from refund_lines    where refund_id in (select id from refunds where sale_id in (select id from run_sales));
    delete from refunds         where sale_id in (select id from run_sales);
    delete from gift_card_txns  where gift_card_id = '${GIFT_CARD}' or sale_id in (select id from run_sales);
    delete from store_credit_txns where customer_id = '${CUSTOMER}';
    delete from inventory_txns  where product_id in ('${PRODUCT}', '${LAST_UNIT_PRODUCT}', '${LAST_STRING}');
    delete from sale_payments   where sale_id in (select id from run_sales);
    delete from sale_lines      where sale_id in (select id from run_sales);
    delete from string_jobs     where id in ('${JOB}', '${JOB_2}')
                                   or customer_racket_id in ('${RACKET_3}', '${RACKET_4}');
    delete from sales           where id in (select id from run_sales);
    delete from customer_rackets where id in ('${RACKET}', '${RACKET_2}', '${RACKET_3}', '${RACKET_4}');
    delete from gift_cards      where id = '${GIFT_CARD}';
    delete from customers       where id = '${CUSTOMER}';
    delete from products        where id in ('${PRODUCT}', '${LAST_UNIT_PRODUCT}', '${LAST_STRING}');
    delete from categories      where id = '${CATEGORY}';
    delete from profiles        where id = '${STAFF}';
    delete from auth.users      where id = '${STAFF}';
SQL
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
  insert into string_jobs (id, customer_racket_id, main_product_id, price)
  values ('${JOB_2}', '${RACKET_2}', '${PRODUCT}', 30);
  insert into customer_rackets (id, customer_id, model) values
    ('${RACKET_3}', '${CUSTOMER}', 'Third frame'), ('${RACKET_4}', '${CUSTOMER}', 'Fourth frame');
  insert into products (id, category_id, brand, name, sell_price, attributes)
  select '${LAST_STRING}', id, 'Concurrency', '${RUN_TAG}', 20, '{"color":"Black","gauge":"17"}'
    from categories where name = 'Strings';
  insert into inventory_txns (txn_type, product_id, qty) values ('receive', '${LAST_STRING}', 1);
  insert into auth.users (id, email, aud, role)
  values ('${STAFF}', '${RUN_TAG}@concurrency.test', 'authenticated', 'authenticated');
  update profiles set role = 'staff' where id = '${STAFF}';
SQL

# Run a statement in two sessions (or a second statement in session B): A holds
# its transaction open while B starts. Prints how many of the two succeeded.
race() {
  local statement="$1" statement_b="${2:-$1}" successes=0
  ( psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 \
      -c "begin; ${statement}; select pg_sleep(${HOLD_SECONDS}); commit;" >/dev/null 2>&1 \
      && echo ok > "$RACE_DIR/a" ) &
  sleep 0.5
  psql "$DB_URL" -qAt -v ON_ERROR_STOP=1 -c "begin; ${statement_b}; commit;" >/dev/null 2>&1 && echo ok > "$RACE_DIR/b"
  wait
  [[ -f "$RACE_DIR/a" ]] && successes=$((successes + 1))
  [[ -f "$RACE_DIR/b" ]] && successes=$((successes + 1))
  rm -f "$RACE_DIR/a" "$RACE_DIR/b"
  echo "$successes"
}
RACE_DIR=$(mktemp -d)

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

rm -rf "$RACE_DIR"
if (( failures > 0 )); then
  echo "${failures} concurrency check(s) failed"
  exit 1
fi
echo "All concurrency checks passed"
