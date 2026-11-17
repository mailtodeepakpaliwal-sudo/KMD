#!/usr/bin/env bash
# Replay the base schema then every migration (vppsone + fee) in timestamp
# order into a fresh local database. Stops at the first failure.
#   replay.sh [start_from_version]
set -u
PG="psql -h /tmp/pg -p 55432 -U postgres -X -q"
REPO=/home/claude/src/kmd-one/supabase
KDB=/home/claude/kmddb
SKIP_FILE=$KDB/skip.txt
DB=replay
START=${1:-}

if [ -z "$START" ]; then
  $PG -c "drop database if exists $DB" -c "create database $DB template tpl_stub" >/dev/null
  for f in $KDB/base/*.sql; do
    if ! $PG -d $DB -v ON_ERROR_STOP=1 -1 -f "$f" > /tmp/replay.out 2>&1; then
      echo "BASE FAIL: $f"; grep -v "^NOTICE\|^psql.*NOTICE\|^HINT\|^DETAIL:  drop" /tmp/replay.out | head -15; exit 1
    fi
  done
fi

ls $REPO/migrations/*.sql $REPO/fee-migrations/*.sql | awk -F/ '{print $NF" "$0}' | sort | cut -d' ' -f2 > /tmp/order.txt
n=0
while read -r f; do
  v=$(basename "$f" | cut -c1-14)
  if [ -n "$START" ] && [ "$v" \< "$START" ]; then continue; fi
  b=$(basename "$f")
  if grep -qx "$b" $SKIP_FILE 2>/dev/null; then continue; fi
  # an override replaces the original file
  if [ -f "$KDB/override/$b" ]; then f="$KDB/override/$b"; fi
  if ! $PG -d $DB -v ON_ERROR_STOP=1 -1 -f "$f" > /tmp/replay.out 2>&1; then
    echo "FAIL after $n ok: $b"
    grep -iE "error|line [0-9]+:|context|detail|hint" /tmp/replay.out | grep -v "^psql:.*NOTICE" | head -12
    echo "$v" > /tmp/replay.last
    exit 1
  fi
  n=$((n+1))
done < /tmp/order.txt
for f in $KDB/post/*.sql; do
  if ! $PG -d $DB -v ON_ERROR_STOP=1 -1 -f "$f" > /tmp/replay.out 2>&1; then
    echo "POST FAIL: $f"; grep -iE "error|line" /tmp/replay.out | head -10; exit 1
  fi
done
echo "ALL OK ($n files + post)"
