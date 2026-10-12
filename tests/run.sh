#!/usr/bin/env bash
#
# Tests for install.command.
#
#     bash tests/run.sh
#
# macOS only: the installer shells out to diskutil, plutil and codesign.
#
# Nothing here touches the real launchd domain. A stub `launchctl` is placed first
# on PATH, HOME is a throwaway directory, and every run is bounded by a hard
# timeout, so a prompt loop fails the test instead of hanging it.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$(cd "$(dirname "$0")" && pwd)"
BOUND="${BOUND:-60}"
WORK=""
SRV_PIDS=""
PASS=0
FAIL=0

cleanup() {
    # shellcheck disable=SC2086
    [ -n "$SRV_PIDS" ] && kill $SRV_PIDS 2>/dev/null
    [ -n "$WORK" ] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT INT TERM

ok()    { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip()  { printf '  skip  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2], wanted [$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$3] not found" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$3] should be absent" ;; *) ok "$1" ;; esac; }

if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS only (diskutil, plutil, codesign); skipping"
    exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "perl is required for run timeouts"; exit 1; }

# The installer needs a non-platform bash and will try to brew-install one. That takes
# longer than a run timeout, which turns into confusing failures, so check up front.
if [ ! -x /opt/homebrew/bin/bash ]; then
    echo "Homebrew bash is required at /opt/homebrew/bin/bash; without it the installer"
    echo "tries to install bash mid-run and every scenario dies on the timeout."
    echo "Fix: brew install bash"
    exit 1
fi

WORK="$(mktemp -d)"
STUB_LOG="$WORK/stub-calls.log"
export STUB_LOG
: > "$STUB_LOG"

# ---------------------------------------------------------------- the harness --

mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<'STUB'
#!/bin/bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
# Satisfy the permission probe without ever invoking the real launchctl: write the
# answer the installer is waiting for into the probe's own StandardOutPath.
if [ "${1:-}" = "bootstrap" ]; then
    out=$(plutil -extract StandardOutPath raw "$3" 2>/dev/null)
    [ -n "$out" ] && echo OK > "$out"
fi
exit 0
STUB
chmod +x "$WORK/bin/launchctl"

start_server() {  # start_server <mode> <port>
    python3 "$TESTS/fake-subsonic.py" "$1" "$2" >/dev/null 2>&1 &
    SRV_PIDS="$SRV_PIDS $!"
    local i=0
    while [ "$i" -lt 50 ]; do
        if nc -z 127.0.0.1 "$2" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# Run the installer against a throwaway HOME, bounded. Prints the exit status.
run_install() {  # run_install <home-name> <input-file> <log-file>
    local home="$WORK/$1" input="$2" log="$3" rc
    rm -rf "$home"
    mkdir -p "$home/Library/LaunchAgents"
    ( cd "$REPO" && HOME="$home" PATH="$WORK/bin:$PATH" SHOKZ_NO_PAUSE=1 \
        perl -e 'alarm shift; exec @ARGV' "$BOUND" bash ./install.command ) \
        < "$input" > "$log" 2>&1
    rc=$?
    printf '%s' "$rc"
}

conf() { printf '%s' "$WORK/$1/.config/shokz-auto-fill/config"; }
installed_log() { printf '%s/Library/Application Support/ShokzAutoFill/logs/latest.log' "$WORK/$1"; }

start_server ok 18801 || { echo "could not start the fake server"; exit 1; }
start_server failed 18802
start_server hang 18803

# ------------------------------------------------------- the straight run -----
echo "== a normal install =="
printf 'http://127.0.0.1:18801\ntestuser\ntestpass\nTEST PRO\n7\n' > "$WORK/in1"
rc=$(run_install home1 "$WORK/in1" "$WORK/out1")
check "exits 0" "$rc" "0"
check "device name with a space survives" "$(grep -m1 '^DEVICE_NAME=' "$(conf home1)")" 'DEVICE_NAME="TEST PRO"'
check "username recorded" "$(grep -m1 '^ND_USER=' "$(conf home1)")" 'ND_USER="testuser"'
check "song count recorded" "$(grep -m1 '^SONG_COUNT=' "$(conf home1)")" 'SONG_COUNT=7'
check "config is mode 600" "$(stat -f '%Sp' "$(conf home1)")" "-rw-------"
has "URL authenticated" "$(cat "$WORK/out1")" "1 of 1 authenticated"
# The credentials are asked for first so the check can run while the rest is
# answered, so the device question must come after the login.
if awk '/^URL\(s\):/{u=NR} /^Volume name/{d=NR} END{exit !(u && d && u < d)}' "$WORK/out1"; then
    ok "the server is asked before the device"
else
    bad "the server should be asked before the device"
fi
has "stub launchctl was used" "$(cat "$STUB_LOG")" "bootstrap"
hasnt "password never reaches the install log" "$(cat "$(installed_log home1)")" "testpass"
has "deep diagnostics recorded a conclusion" "$(cat "$(installed_log home1)")" "conclusion"
shebang=$(head -1 "$WORK/home1/Library/Application Support/ShokzAutoFill/bin/auto_fill_shokz.sh" 2>/dev/null)
has "installed shebang is a bash path" "$shebang" "bash"
check "plist written" "$([ -f "$WORK/home1/Library/LaunchAgents/local.shokz-auto-fill.plist" ] && echo yes)" "yes"

# ------------------------------------------- naming regression (was shipped) --
echo "== a mounted name containing a space is one menu entry =="
spaced=""
for v in /Volumes/*; do
    [ -d "$v" ] || continue
    n=$(basename "$v")
    case "$n" in
        "Macintosh HD"|Recovery*|com.apple.TimeMachine*) continue ;;
        *" "*) spaced="$n" ;;
    esac
done
if [ -n "$spaced" ]; then
    printf 'http://127.0.0.1:18801\ntestuser\ntestpass\n%s\n5\n' "$spaced" > "$WORK/in2"
    rc=$(run_install home2 "$WORK/in2" "$WORK/out2")
    check "exits 0 with a spaced volume" "$rc" "0"
    check "volume listed once, whole" "$(grep -cE "^  [0-9]+\) ${spaced}(  \(.*\))?$" "$WORK/out2")" "1"
    check "volume not split into a bare first word" "$(grep -cE "^  [0-9]+\) ${spaced%% *}$" "$WORK/out2")" "0"
    check "spaced device recorded whole" "$(grep -m1 '^DEVICE_NAME=' "$(conf home2)")" "DEVICE_NAME=\"$spaced\""
else
    skip "no mounted volume contains a space"
fi

# ------------------------------------------------- back navigation (Escape) ---
echo "== Escape at the password prompt returns to the username =="
{ printf 'http://127.0.0.1:18801\nwronguser\n\033'; printf '\ntestuser\ntestpass\nTEST PRO\n5\n'; } > "$WORK/in3"
rc=$(run_install home3 "$WORK/in3" "$WORK/out3")
check "exits 0" "$rc" "0"
check "username asked twice" "$(grep -c '^Username' "$WORK/out3")" "2"
check "corrected username recorded" "$(grep -m1 '^ND_USER=' "$(conf home3)")" 'ND_USER="testuser"'

# ------------------------------- exhausted input must not loop (was shipped) --
echo "== exhausted input cancels instead of spinning =="
printf 'http://127.0.0.1:18801\ntestuser\n' > "$WORK/in4"
rc=$(run_install home4 "$WORK/in4" "$WORK/out4")
check "exits 0" "$rc" "0"
check "cancels once" "$(grep -c 'Cancelled' "$WORK/out4")" "1"
lines=$(wc -l < "$WORK/out4" | tr -d ' ')
if [ "$lines" -lt 80 ]; then ok "output stays small ($lines lines)"; else bad "output looks like a loop ($lines lines)"; fi

# ------------------------------------------- pasted and edited answers --------
# A pasted URL arrives from the terminal wrapped in bracketed-paste markers. The
# old raw-mode prompt ate the wrapper and read the rest as end of input, which
# cancelled the whole run.
echo "== a pasted URL is accepted =="
printf '\033[200~http://127.0.0.1:18801\033[201~\ntestuser\ntestpass\nTEST PRO\n5\n' > "$WORK/in7"
rc=$(run_install home7 "$WORK/in7" "$WORK/out7")
check "exits 0" "$rc" "0"
check "pasted URL recorded, markers gone" "$(grep -m1 '^ND_URLS=' "$(conf home7)")" 'ND_URLS="http://127.0.0.1:18801"'
has "pasted URL authenticated" "$(cat "$WORK/out7")" "1 of 1 authenticated"

# An arrow key that reaches the prompt as bytes must never land in the value.
echo "== stray escape sequences never reach the value =="
printf 'http://127.0.0.1:18801\033[D\033[D\ntestuser\ntestpass\nTEST PRO\n5\n' > "$WORK/in8"
rc=$(run_install home8 "$WORK/in8" "$WORK/out8")
check "exits 0" "$rc" "0"
check "URL stored without arrow bytes" "$(grep -m1 '^ND_URLS=' "$(conf home8)")" 'ND_URLS="http://127.0.0.1:18801"'
has "clean URL authenticated" "$(cat "$WORK/out8")" "1 of 1 authenticated"

# `back` is what replaces Up/Escape at a terminal now that the line editor owns
# the arrow keys.
echo "== typing back returns to the previous question =="
printf 'http://127.0.0.1:18801\nback\nhttp://127.0.0.1:18801\ntestuser\ntestpass\nTEST PRO\n5\n' > "$WORK/in9"
rc=$(run_install home9 "$WORK/in9" "$WORK/out9")
check "exits 0" "$rc" "0"
check "URL list asked twice" "$(grep -c '^URL(s)' "$WORK/out9")" "2"
check "username recorded after going back" "$(grep -m1 '^ND_USER=' "$(conf home9)")" 'ND_USER="testuser"'

# A bare Escape is a keypress in its own right, and the case that matters is the
# one where nothing follows it: readline would swallow it as a meta prefix.
echo "== a bare Escape goes back, and up and down navigate =="
printf 'http://127.0.0.1:18801\nfirstuser\n\033' > "$WORK/in10"
rc=$(run_install home10 "$WORK/in10" "$WORK/out10")
check "exits 0" "$rc" "0"
check "username asked twice after Escape" "$(grep -c '^Username' "$WORK/out10")" "2"
has "input running out still cancels" "$(cat "$WORK/out10")" "Cancelled"

printf 'http://127.0.0.1:18801\n\033[A\033[B\ntestuser\ntestpass\nTEST PRO\n5\n' > "$WORK/in11"
rc=$(run_install home11 "$WORK/in11" "$WORK/out11")
check "exits 0" "$rc" "0"
check "Up goes back to the URL list" "$(grep -c '^URL(s)' "$WORK/out11")" "2"
check "Down comes forward again" "$(grep -m1 '^ND_USER=' "$(conf home11)")" 'ND_USER="testuser"'

echo "== backspace corrects a value =="
printf 'http://127.0.0.1:18801X\177\ntestuser\ntestpass\nTEST PRO\n5\n' > "$WORK/in12"
rc=$(run_install home12 "$WORK/in12" "$WORK/out12")
check "exits 0" "$rc" "0"
check "the deleted character is gone" "$(grep -m1 '^ND_URLS=' "$(conf home12)")" 'ND_URLS="http://127.0.0.1:18801"'
has "the corrected URL authenticates" "$(cat "$WORK/out12")" "1 of 1 authenticated"

# Going back to fix one answer must not drag the user through the rest of them.
echo "== fixing a URL re-asks only the URL =="
# 18804 has nothing listening, so the check reports no answer and offers the fix.
printf 'http://127.0.0.1:18804\ntestuser\ntestpass\nTEST PRO\n5\ny\nhttp://127.0.0.1:18801\n' > "$WORK/in13"
rc=$(run_install home13 "$WORK/in13" "$WORK/out13")
check "exits 0" "$rc" "0"
check "the URL list was asked twice" "$(grep -c '^URL(s)' "$WORK/out13")" "2"
check "the login was asked once" "$(grep -c '^Username' "$WORK/out13")" "1"
check "the device was asked once" "$(grep -c '^Volume name' "$WORK/out13")" "1"
has "the corrected URL authenticates" "$(cat "$WORK/out13")" "1 of 1 authenticated"

echo "== fixing a login re-asks the login, not the device =="
# 18802 answers but rejects every login, which offers the login fix. The password
# step asks twice - keep the stored one, then the new one - hence the n before it.
printf 'http://127.0.0.1:18802\ntestuser\ntestpass\nTEST PRO\n5\ny\nnewuser\nn\nnewpass\nn\ny\n' > "$WORK/in14"
rc=$(run_install home14 "$WORK/in14" "$WORK/out14")
check "exits 0" "$rc" "0"
check "the login was asked twice" "$(grep -c '^Username' "$WORK/out14")" "2"
check "the device was asked once" "$(grep -c '^Volume name' "$WORK/out14")" "1"
check "the corrected username is recorded" "$(grep -m1 '^ND_USER=' "$(conf home14)")" 'ND_USER="newuser"'

# ------------------------------------------------------ a rejected login ------
echo "== a rejected login is named, and can be accepted =="
printf 'http://127.0.0.1:18802\ntestuser\ntestpass\nTEST PRO\n5\nn\ny\n' > "$WORK/in5"
rc=$(run_install home5 "$WORK/in5" "$WORK/out5")
check "exits 0" "$rc" "0"
has "rejection reported" "$(cat "$WORK/out5")" "rejected"
has "count reported" "$(cat "$WORK/out5")" "0 of 1 authenticated"
check "config still written" "$([ -f "$(conf home5)" ] && echo yes)" "yes"

# ------------------------- connect-then-silence is told apart from a refusal --
echo "== a server that accepts and never answers is diagnosed =="
printf 'http://127.0.0.1:18803\ntestuser\ntestpass\nTEST PRO\n5\nn\ny\n' > "$WORK/in6"
rc=$(run_install home6 "$WORK/in6" "$WORK/out6")
check "exits 0" "$rc" "0"
has "diagnosis names the case" "$(cat "$(installed_log home6)")" "the TCP connection opened and the server never replied"
# A check still in flight when the questions run out has to say so rather than
# looking like a hang.
has "an unfinished background check is announced" "$(cat "$WORK/out6")" "the background check has not finished"

# ------------------------------------------------ the fill script's lock -------
# Covered here rather than in run.sh's own scenarios because it needs no mounted
# volume: tests/lock.sh pulls the lock block out of the installed script.
echo "== the fill script takes only one run at a time =="
if bash "$TESTS/lock.sh" > "$WORK/lock-out" 2>&1; then
    ok "one fill at a time (tests/lock.sh)"
else
    bad "one fill at a time - tests/lock.sh reported:"
    sed 's/^/        /' "$WORK/lock-out"
fi

# ------------------------------------------------------------------ summary ---
echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
