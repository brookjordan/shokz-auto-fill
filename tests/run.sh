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
printf 'TEST PRO\nhttp://127.0.0.1:18801\ntestuser\ntestpass\n7\n' > "$WORK/in1"
rc=$(run_install home1 "$WORK/in1" "$WORK/out1")
check "exits 0" "$rc" "0"
check "device name with a space survives" "$(grep -m1 '^DEVICE_NAME=' "$(conf home1)")" 'DEVICE_NAME="TEST PRO"'
check "username recorded" "$(grep -m1 '^ND_USER=' "$(conf home1)")" 'ND_USER="testuser"'
check "song count recorded" "$(grep -m1 '^SONG_COUNT=' "$(conf home1)")" 'SONG_COUNT=7'
check "config is mode 600" "$(stat -f '%Sp' "$(conf home1)")" "-rw-------"
has "URL authenticated" "$(cat "$WORK/out1")" "1 of 1 authenticated"
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
    printf '%s\nhttp://127.0.0.1:18801\ntestuser\ntestpass\n5\n' "$spaced" > "$WORK/in2"
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
{ printf 'TEST PRO\nhttp://127.0.0.1:18801\nwronguser\n\033'; printf '\ntestuser\ntestpass\n5\n'; } > "$WORK/in3"
rc=$(run_install home3 "$WORK/in3" "$WORK/out3")
check "exits 0" "$rc" "0"
check "username asked twice" "$(grep -c '^Username' "$WORK/out3")" "2"
check "corrected username recorded" "$(grep -m1 '^ND_USER=' "$(conf home3)")" 'ND_USER="testuser"'

# ------------------------------- exhausted input must not loop (was shipped) --
echo "== exhausted input cancels instead of spinning =="
printf 'TEST PRO\nhttp://127.0.0.1:18801\n' > "$WORK/in4"
rc=$(run_install home4 "$WORK/in4" "$WORK/out4")
check "exits 0" "$rc" "0"
check "cancels once" "$(grep -c 'Cancelled' "$WORK/out4")" "1"
lines=$(wc -l < "$WORK/out4" | tr -d ' ')
if [ "$lines" -lt 80 ]; then ok "output stays small ($lines lines)"; else bad "output looks like a loop ($lines lines)"; fi

# ------------------------------------------------------ a rejected login ------
echo "== a rejected login is named, and can be accepted =="
printf 'TEST PRO\nhttp://127.0.0.1:18802\ntestuser\ntestpass\n5\nn\ny\n' > "$WORK/in5"
rc=$(run_install home5 "$WORK/in5" "$WORK/out5")
check "exits 0" "$rc" "0"
has "rejection reported" "$(cat "$WORK/out5")" "rejected"
has "count reported" "$(cat "$WORK/out5")" "0 of 1 authenticated"
check "config still written" "$([ -f "$(conf home5)" ] && echo yes)" "yes"

# ------------------------- connect-then-silence is told apart from a refusal --
echo "== a server that accepts and never answers is diagnosed =="
printf 'TEST PRO\nhttp://127.0.0.1:18803\ntestuser\ntestpass\n5\nn\ny\n' > "$WORK/in6"
rc=$(run_install home6 "$WORK/in6" "$WORK/out6")
check "exits 0" "$rc" "0"
has "diagnosis names the case" "$(cat "$(installed_log home6)")" "the TCP connection opened and the server never replied"

# ------------------------------------------------------------------ summary ---
echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
