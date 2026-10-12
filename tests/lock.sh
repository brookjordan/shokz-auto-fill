#!/usr/bin/env bash
#
# Tests for the fill script's lock.
#
#     bash tests/lock.sh
#
# The lock block is extracted from bin/auto_fill_shokz.sh rather than restated, so
# this cannot drift from what actually ships. It needs no mounted volume, which is
# why the fill script can be covered here and not in tests/run.sh.
#
# The defect it exists for: the lock was tested with `[ -f ]` and then created with
# `touch`, so two /Volumes events arriving together both got through, and each run
# cleared the lock file on exit whether or not it owned it. Two fills then numbered
# folders on the same device and deleted each other's work.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/bin/auto_fill_shokz.sh"
W="$(mktemp -d)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
cleanup() { rm -rf "$W"; return 0; }
trap cleanup EXIT INT TERM

sed -n "/^release_lock()/,/^trap 'release_lock' EXIT$/p" "$SRC" > "$W/lock.sh"
if [ ! -s "$W/lock.sh" ]; then
    echo "could not extract the lock block from $SRC"
    echo "look for the markers 'release_lock()' and \"trap 'release_lock' EXIT\""
    exit 1
fi

cat > "$W/runner" <<EOF
#!/usr/bin/env bash
STATE_FILE="$W/state"
LOG_FILE="$W/log"
. "$W/lock.sh"
echo ACQUIRED
sleep "\${HOLD:-0}"
EOF
chmod +x "$W/runner"
run() { STATE_FILE="$W/state" LOG_FILE="$W/log" "$W/runner"; }

echo "== nobody holds it =="
rm -f "$W/state"
HOLD=2 run > "$W/out1" &
runner_pid=$!
i=0
while [ "$i" -lt 60 ] && [ ! -s "$W/state" ]; do sleep 0.1; i=$((i + 1)); done
case "$(cat "$W/state" 2>/dev/null)" in
    ''|*[!0-9]*) bad "lock should record the holder's pid, got [$(cat "$W/state" 2>/dev/null)]" ;;
    *)           ok "lock records its owner pid" ;;
esac
wait "$runner_pid"
case "$(cat "$W/out1")" in
    *ACQUIRED*) ok "acquires a free lock" ;;
    *)          bad "should acquire a free lock" ;;
esac

echo "== the holder finishes =="
if [ -f "$W/state" ]; then
    bad "lock should be gone once the holder exits"
else
    ok "lock is released on exit"
fi

echo "== a live owner holds it =="
sleep 30 &
holder=$!
printf '%s\n' "$holder" > "$W/state"
out="$(run)"
case "$out" in
    *ACQUIRED*) bad "must not acquire a held lock" ;;
    *)          ok "skips while a live owner holds it" ;;
esac
if grep -q "pid $holder" "$W/log"; then
    ok "the log names the pid holding it"
else
    bad "the log should name the holding pid"
fi
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

echo "== the owner was killed =="
printf '%s\n' 999999 > "$W/state"
out="$(run)"
case "$out" in
    *ACQUIRED*) bad "a stale lock must not be taken silently" ;;
    *)          ok "does not take a stale lock" ;;
esac
if grep -q "delete $W/state" "$W/log"; then
    ok "says how to clear a stale lock"
else
    bad "should say how to clear a stale lock"
fi

echo "== releasing is not a free-for-all =="
printf 'someone-else\n' > "$W/state"
# shellcheck disable=SC2034  # both are read by the sourced lock block
( STATE_FILE="$W/state" LOG_FILE="$W/log"; . "$W/lock.sh"; release_lock ) >/dev/null 2>&1
if [ -f "$W/state" ]; then
    ok "a non-owner cannot release the lock"
else
    bad "lock was released by a non-owner"
fi

echo "== twenty runs start at once =="
rm -f "$W/state" "$W/wins"
for _ in $(seq 20); do
    ( STATE_FILE="$W/state" LOG_FILE="$W/log" HOLD=1 "$W/runner" >> "$W/wins" 2>/dev/null ) &
done
wait
wins="$(grep -c ACQUIRED "$W/wins" 2>/dev/null)"
if [ "$wins" = "1" ]; then
    ok "exactly one of twenty acquires the lock"
else
    bad "expected 1 winner, got $wins"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
