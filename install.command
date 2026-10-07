#!/bin/bash
#
# Shokz Auto-Fill installer.
#
# Double-click this file, or run it from a terminal.
#
# FIRST RUN installs everything:
#   * the fill script under ~/Library/Application Support/ShokzAutoFill
#   * the config (with the password) under ~/.config/shokz-auto-fill, mode 600
#   * a LaunchAgent that runs the script whenever /Volumes changes
#
# LATER RUNS detect the existing installation and let you update individual
# settings - song count, Navidrome URL(s), device, login - or reinstall the
# script and agent. Only what you pick is changed.
#
# The script and agent read the config at run time, so changing a *setting* needs
# no reload. Reinstalling the agent is still useful to re-request the
# removable-volume permission (which macOS ties to the interpreter's path and can
# lose after a Homebrew bash upgrade).
set -u

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/common.sh
. ./lib/common.sh

say "=== $APP_NAME installer ==="
say ""

# ---------------------------------------------------------------- prerequisites
command -v curl >/dev/null 2>&1 || die "curl is required."
if ! command -v jq >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "jq is required (brew install jq)."
    say "Installing jq ..."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install jq >/dev/null 2>&1 || die "brew install jq failed."
fi

# ------------------------------------------------------------------- logging
# From here on, everything on screen is mirrored into a timestamped log, and the URL
# checks add depth of their own. The log records the reasoning, not only results.
log_init
if [ -n "$SHOKZ_LOG" ]; then
    log_env
    exec 3>&1 4>&2
    exec > >(tee -a "$SHOKZ_LOG") 2>&1
    trap '_restore_output' EXIT
else
    say "could not create a log file; continuing without one"
fi

# ------------------------------------------------------------- what is installed
CUR_DEVICE=""
CUR_URLS=""
CUR_USER=""
CUR_PASS=""
CUR_SONGS="50"
HAVE_CONFIG=0
if [ -r "$CONFIG" ]; then
    HAVE_CONFIG=1
    # shellcheck source=/dev/null
    . "$CONFIG"
    CUR_DEVICE="${DEVICE_NAME:-}"
    CUR_URLS="${ND_URLS:-}"
    CUR_USER="${ND_USER:-}"
    CUR_PASS="${ND_PASS:-}"
    CUR_SONGS="${SONG_COUNT:-50}"
fi
HAVE_SCRIPT=0; [ -x "$SCRIPT_DEST" ] && HAVE_SCRIPT=1
HAVE_PLIST=0;  [ -f "$PLIST_DEST" ]  && HAVE_PLIST=1
AGENT_LOADED=0
launchctl list "$LABEL" >/dev/null 2>&1 && AGENT_LOADED=1

INSTALLED=0
{ [ "$HAVE_CONFIG" = 1 ] || [ "$HAVE_PLIST" = 1 ] || [ "$HAVE_SCRIPT" = 1 ]; } && INSTALLED=1

log ""
log "--- existing installation ---"
log "config          : $([ "$HAVE_CONFIG" = 1 ] && echo present || echo missing)  $CONFIG"
log "script          : $([ "$HAVE_SCRIPT" = 1 ] && echo present || echo missing)  $SCRIPT_DEST"
log "plist           : $([ "$HAVE_PLIST" = 1 ] && echo present || echo missing)  $PLIST_DEST"
log "agent loaded    : $AGENT_LOADED  ($LABEL)"
log "=> treated as   : $([ "$INSTALLED" = 1 ] && echo 'existing install (update)' || echo 'fresh install')"

# ---------------------------------------------------- choose what to update
DO_DEVICE=1; DO_URLS=1; DO_LOGIN=1; DO_SONGS=1; DO_REFRESH=1

if [ "$INSTALLED" = 1 ]; then
    say "An existing installation was found."
    say "  config : $([ "$HAVE_CONFIG" = 1 ] && echo "$CONFIG" || echo 'missing')"
    say "  script : $([ "$HAVE_SCRIPT" = 1 ] && echo 'present' || echo 'missing')  ($SCRIPT_DEST)"
    if [ "$AGENT_LOADED" = 1 ]; then
        say "  agent  : loaded  ($LABEL)"
    elif [ "$HAVE_PLIST" = 1 ]; then
        say "  agent  : installed but not loaded  ($LABEL)"
    else
        say "  agent  : missing  ($LABEL)"
    fi
    say ""
    say "Current settings:"
    say "  device     : ${CUR_DEVICE:-<unset>}"
    say "  url(s)     : ${CUR_URLS:-<unset>}"
    say "  login      : ${CUR_USER:-<unset>}   password: $([ -n "$CUR_PASS" ] && echo 'stored' || echo 'MISSING')"
    say "  songs/fill : ${CUR_SONGS:-50}"
    say ""
    say "What would you like to update?  (one number, several separated by spaces, or 'a')"
    say "  1) song count          (now ${CUR_SONGS:-50})"
    say "  2) Navidrome URL(s)"
    say "  3) device              (now ${CUR_DEVICE:-<unset>})"
    say "  4) login               (now ${CUR_USER:-<unset>})"
    say "  5) reinstall script + LaunchAgent, and re-request volume permission"
    say "  a) all of the above"
    say "  q) quit without changing anything"
    printf 'Choice [a]: '
    read -r sel || true
    sel="${sel:-a}"
    case "$sel" in
        q|Q|quit|QUIT) say "Nothing changed."; pause_if_double_clicked; exit 0 ;;
    esac
    DO_DEVICE=0; DO_URLS=0; DO_LOGIN=0; DO_SONGS=0; DO_REFRESH=0
    case "$sel" in
        a|A|all|ALL|\*)
            DO_DEVICE=1; DO_URLS=1; DO_LOGIN=1; DO_SONGS=1; DO_REFRESH=1 ;;
        *)
            for t in $(printf '%s' "$sel" | tr ',' ' '); do
                case "$t" in
                    1) DO_SONGS=1 ;;
                    2) DO_URLS=1 ;;
                    3) DO_DEVICE=1 ;;
                    4) DO_LOGIN=1 ;;
                    5) DO_REFRESH=1 ;;
                    *) warn "ignoring unrecognised choice: '$t'" ;;
                esac
            done ;;
    esac
    if [ $((DO_DEVICE + DO_URLS + DO_LOGIN + DO_SONGS + DO_REFRESH)) -eq 0 ]; then
        say "Nothing selected - no changes made."
        pause_if_double_clicked
        exit 0
    fi
    # Never leave the config without a password.
    if [ -z "$CUR_PASS" ]; then
        warn "no stored password found, so the login will be asked for as well"
    log ""
    log "--- what the user chose to update ---"
    log "selection       : $sel"
    log "device=$DO_DEVICE urls=$DO_URLS login=$DO_LOGIN songs=$DO_SONGS refresh=$DO_REFRESH"
        DO_LOGIN=1
    fi
    say ""
fi

# ------------------------------------------------------- ask for the settings
# Every question is a step. Escape goes back one, Ctrl-C cancels, and each answer
# lives in its own variable, so stepping back never costs a later answer.

say "Up or Escape goes back a question, Down moves forward to one you have already"
say "answered, and Ctrl-C cancels."
say ""

DEVICE_NAME="$CUR_DEVICE"
ND_URLS="$CUR_URLS"
ND_USER="$CUR_USER"
ND_PASS="$CUR_PASS"
SONG_COUNT="${CUR_SONGS:-50}"

STEPS=()
[ "$DO_DEVICE" = 1 ] && STEPS+=("device")
[ "$DO_URLS" = 1 ] && STEPS+=("urls")
[ "$DO_LOGIN" = 1 ] && STEPS+=("username")
[ "$DO_LOGIN" = 1 ] && STEPS+=("password")
[ "$DO_SONGS" = 1 ] && STEPS+=("songs")

STEP_INDEX=0
MAX_REACHED=-1

# Down should only walk forward over questions already answered.
step_has_value() {
    case "$1" in
        device)   [ -n "$DEVICE_NAME" ] ;;
        urls)     [ -n "$ND_URLS" ] ;;
        username) [ -n "$ND_USER" ] ;;
        password) [ -n "$ND_PASS" ] ;;
        songs)    [ -n "$SONG_COUNT" ] ;;
        *)        return 0 ;;
    esac
}

step_index_of() {
    local want="$1" k=0 s
    for s in "${STEPS[@]}"; do
        if [ "$s" = "$want" ]; then STEP_INDEX="$k"; return 0; fi
        k=$((k + 1))
    done
    STEPS+=("$want")
    STEP_INDEX=$((${#STEPS[@]} - 1))
    return 0
}

ask_device() {
    say ""
    say "--- Which device should be filled? ---"
    say "The name the player mounts as, the folder under /Volumes."
    local v rc
    while :; do
        v="$(choose_volume "$DEVICE_NAME")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        if [ -n "$v" ]; then DEVICE_NAME="$v"; break; fi
        warn "a device name is required."
    done
    say "  -> /Volumes/$DEVICE_NAME"
    return 0
}

ask_urls() {
    say ""
    say "--- Navidrome URL(s) ---"
    say "Space-separated, tried in order. Put the fastest first, then a remote one."
    local rc
    while :; do
        read_step_raw "URL(s)${ND_URLS:+ [$ND_URLS]}" "$ND_URLS"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        ND_URLS="$(printf '%s' "$STEP_VALUE" | tr ',' ' ')"
        if [ -n "$ND_URLS" ]; then break; fi
        warn "at least one URL is required."
    done
    say "  -> will try: $ND_URLS"
    return 0
}

# The username and the password are separate steps so that noticing a typo in the
# username at the password prompt is one Escape away from fixing it.
ask_username() {
    say ""
    say "--- Navidrome username ---"
    say "Your Navidrome account, which need not match your macOS account."
    local rc
    while :; do
        read_step_raw "Username${ND_USER:+ [$ND_USER]}" "$ND_USER"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        if [ -n "$STEP_VALUE" ]; then ND_USER="$STEP_VALUE"; break; fi
        warn "a Navidrome username is required."
    done
    return 0
}

ask_password() {
    say ""
    say "--- Navidrome password ---"
    local rc
    if [ -n "$ND_PASS" ]; then
        read_step_raw "Keep the password already set? [Y/n]" "Y"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        case "$STEP_VALUE" in [Nn]*) ND_PASS="" ;; *) return 0 ;; esac
    fi
    while :; do
        read_secret "Password for $ND_USER (not echoed, will be checked)"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        if [ -n "$SECRET_VALUE" ]; then ND_PASS="$SECRET_VALUE"; fi
        [ -n "$ND_PASS" ] || warn "a password is required."
        [ -n "$ND_PASS" ] && break
    done
    return 0
}

ask_songs() {
    say ""
    say "--- Songs per fill ---"
    local rc
    while :; do
        read_step_raw "How many songs per fill${SONG_COUNT:+ [$SONG_COUNT]}" "$SONG_COUNT"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        case "$STEP_VALUE" in
            ''|*[!0-9]*) warn "enter a whole number." ;;
            0)           warn "enter a number greater than zero." ;;
            *)           SONG_COUNT="$STEP_VALUE"; break ;;
        esac
    done
    say "  -> $SONG_COUNT songs per fill"
    return 0
}

# For the "go back and fix it?" questions, Up means go back and Down means carry on,
# which matches what those keys do everywhere else. 0 = go back, 1 = carry on.
ask_fix_it() {
    local prompt="$1" rc
    read_step_raw "$prompt [Y/n]" "Y"; rc=$?
    case "$rc" in
        1) return 0 ;;
        3) return 1 ;;
        2) return 2 ;;
    esac
    case "$STEP_VALUE" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Test every URL. Returns 0 to carry on, 3 to go back to the login, 4 to go back to
# the URL list, 5 to abandon.
CHECK_ATTEMPT=0
run_checks() {
    local n_total=0 n_ok=0 n_reach=0 dead="" u st rc
    CHECK_ATTEMPT=$((CHECK_ATTEMPT + 1))
    if [ "$CHECK_ATTEMPT" -gt 20 ]; then
        warn "20 rounds without a working URL. Stopping so this cannot loop forever."
        return 5
    fi
    log ""
    log "--- settings gathered, check attempt $CHECK_ATTEMPT ---"
    log "device          : $DEVICE_NAME"
    log "urls            : $ND_URLS"
    log "username        : $ND_USER"
    log "password        : $([ -n "${ND_PASS:-}" ] && echo 'set, never logged' || echo MISSING)"
    log "songs per fill  : $SONG_COUNT"

    if [ "$DO_URLS" != 1 ] && [ "$DO_LOGIN" != 1 ] && [ "$INSTALLED" = 1 ]; then
        say ""
        say "Settings changed only - no server check needed (credentials unchanged)."
        say ""
        return 0
    fi

    say ""
    say "--- Checking every configured URL ---"
    for u in $ND_URLS; do
        u="${u%/}"
        n_total=$((n_total + 1))
        st="$(diag_url "$u" "$ND_USER" "$ND_PASS" 8)"
        log "    verdict      : ${st:-no answer}"
        if [ -z "$st" ]; then
            say "  no answer : $u"
            dead="$dead $u"
        elif [ "$st" = "ok" ]; then
            say "  ok        : $u (authenticated)"
            n_ok=$((n_ok + 1)); n_reach=$((n_reach + 1))
        else
            say "  rejected  : $u (Subsonic status='$st')"
            n_reach=$((n_reach + 1))
        fi
    done
    say "  ${n_ok} of ${n_total} authenticated."

    if [ "$n_ok" -gt 0 ] && [ -z "$dead" ]; then return 0; fi

    if [ "$n_ok" -gt 0 ]; then
        # Something works but part of the list does not, and a broken fallback is
        # only discovered on the day the working URL goes away.
        warn "these URLs did not answer:${dead}"
        ask_fix_it "Go back and edit the URL list?"; rc=$?
        [ "$rc" -eq 2 ] && return 2
        [ "$rc" -eq 0 ] && return 4
        return 0
    fi

    if [ "$n_reach" -gt 0 ]; then
        warn "a server answered, so the addresses are right, but it rejected that login."
        ask_fix_it "Go back and fix the login?"; rc=$?
        [ "$rc" -eq 2 ] && return 2
        [ "$rc" -eq 0 ] && return 3
    else
        warn "no configured URL answered:${ND_URLS}"
        ask_fix_it "Go back and edit the URL list?"; rc=$?
        [ "$rc" -eq 2 ] && return 2
        [ "$rc" -eq 0 ] && return 4
    fi

    read_step_raw "Install anyway, to fix it later? [y/N]" "N"; rc=$?
    case "$rc" in 1|3) rc=0 ;; esac
    [ "$rc" -eq 0 ] || return 2
    case "$STEP_VALUE" in [Yy]*) return 0 ;; *) return 5 ;; esac
}

i=0
rc=0
while :; do
    while [ "$i" -lt "${#STEPS[@]}" ]; do
        case "${STEPS[$i]}" in
            device) ask_device; rc=$? ;;
            urls)   ask_urls;   rc=$? ;;
            username) ask_username; rc=$? ;;
            password) ask_password; rc=$? ;;
            songs)  ask_songs;  rc=$? ;;
            *)      rc=0 ;;
        esac
        if [ "$rc" -eq 0 ]; then
            [ "$i" -gt "$MAX_REACHED" ] && MAX_REACHED="$i"
            i=$((i + 1))
        elif [ "$rc" -eq 1 ]; then
            if [ "$i" -gt 0 ]; then
                i=$((i - 1))
            else
                say "  this is the first question, so there is nothing to go back to"
            fi
        elif [ "$rc" -eq 3 ]; then
            if [ "$i" -lt "$MAX_REACHED" ] || step_has_value "${STEPS[$i]}"; then
                i=$((i + 1))
            else
                say "  no later question has been answered yet"
            fi
        else
            say ""
            say "Cancelled. Nothing was changed."
            pause_if_double_clicked
            exit 0
        fi
    done

    run_checks; rc=$?
    case "$rc" in
        0) break ;;
        3) step_index_of username; i="$STEP_INDEX" ;;
        4) step_index_of urls;  i="$STEP_INDEX" ;;
        5) say ""
           say "Aborted at your request. Nothing was changed."
           pause_if_double_clicked
           exit 0 ;;
        *) break ;;
    esac
done
say ""

# ------------------------------------------------------------- write config
mkdir -p "$CONFIG_DIR"
umask 077
cat > "$CONFIG" <<EOF
# $APP_NAME configuration.  Updated $(date '+%Y-%m-%d %H:%M').
# Contains a credential - keep it mode 600 and do NOT commit it to git.

# The player's volume name, i.e. the folder under /Volumes
DEVICE_NAME="$DEVICE_NAME"

# Navidrome base URL(s), tried in order until one answers
ND_URLS="$ND_URLS"

ND_USER="$ND_USER"
ND_PASS="$ND_PASS"

SONG_COUNT=$SONG_COUNT
CONNECT_TIMEOUT=8
EOF
chmod 600 "$CONFIG"
say "config written: $CONFIG (mode 600)"

log ""
log "--- config written, password redacted ---"
while IFS= read -r _ln; do log "  $_ln"; done < "$CONFIG"
log "permissions     : $(stat -f '%Sp' "$CONFIG" 2>/dev/null)"

# ---------------------------------------- install / refresh the script + agent
if [ "$DO_REFRESH" = 1 ] || [ "$INSTALLED" = 0 ]; then
    say ""
    say "--- Shell for the background job ---"
    ensure_non_platform_shell
    INTERP="$BREW_BASH"
    say "  using $INTERP (not a platform binary, so macOS can grant it access)"
    log "interpreter     : $INTERP"
    log "  codesign      : $(codesign -dvvv "$INTERP" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
    if codesign -dvvv "$INTERP" 2>&1 | grep -qi 'Platform identifier'; then
        log "  PLATFORM BINARY: yes, which TCC can never grant. This is a bug"
    else
        log "  platform binary: no, so macOS can prompt for it"
    fi

    mkdir -p "$SUPPORT/bin"
    cp ./bin/auto_fill_shokz.sh "$SCRIPT_DEST"
    # Point the installed copy's shebang at the interpreter actually resolved on
    # this machine, so it stays correct on Intel Macs where brew lives in /usr/local.
    sed -i '' "1s|.*|#!$INTERP|" "$SCRIPT_DEST"
    chmod 755 "$SCRIPT_DEST"
    say "  installed script: $SCRIPT_DEST"

    # ~/Library/LaunchAgents may not exist in a fresh user account.
    mkdir -p "$(dirname "$PLIST_DEST")"
    cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INTERP</string>
		<string>$SCRIPT_DEST</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>/Volumes</string>
	</array>
	<key>StandardOutPath</key>
	<string>$SUPPORT/launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>$SUPPORT/launchd.err.log</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST_DEST" >/dev/null || die "generated plist is malformed"
    chmod 644 "$PLIST_DEST"
    say "  wrote $PLIST_DEST"

    log ""
    log "--- LaunchAgent written ---"
    log "path            : $PLIST_DEST"
    while IFS= read -r _ln; do log "  $_ln"; done < "$PLIST_DEST"
    log "lint            : $(plutil -lint "$PLIST_DEST" 2>&1)"
    log "permissions     : $(stat -f '%Sp' "$PLIST_DEST" 2>/dev/null)"
    log "script sha256   : $(shasum -a 256 "$SCRIPT_DEST" 2>/dev/null | awk '{print $1}')"
    log "script shebang  : $(head -1 "$SCRIPT_DEST" 2>/dev/null)"


    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null \
        || launchctl load "$PLIST_DEST" 2>/dev/null || true
    sleep 2
    log ""
    log "--- loading the agent ---"
    log "bootout then bootstrap gui/$(id -u) $PLIST_DEST"

    if launchctl list "$LABEL" >/dev/null 2>&1; then
        say "  agent loaded: $LABEL"
    log "  loaded        : yes"
    log "  launchctl list: $(launchctl list "$LABEL" 2>&1 | tr '\n' ' ')"
    else
        warn "agent does not appear in launchctl; check: launchctl list | grep shokz"
    log "  loaded        : NO, not present in launchctl"
    log "  launchctl list: $(launchctl list "$LABEL" 2>&1 | tr '\n' ' ')"
    fi

    # ------------------------------------------------- permission probe
    say ""
    say "--- Removable-volume permission ---"
    say "macOS may ask once to allow access to removable volumes; click Allow."
    PROBE_LABEL="$LABEL.probe"
    PROBE_PLIST="$HOME/Library/LaunchAgents/$PROBE_LABEL.plist"
    PROBE_LOG="/tmp/shokz-auto-fill-probe.log"
    cat > "$PROBE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$PROBE_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INTERP</string>
		<string>-c</string>
		<string>if mkdir -p "/Volumes/$DEVICE_NAME/.shokz_probe" 2>/dev/null; then echo OK; rmdir "/Volumes/$DEVICE_NAME/.shokz_probe"; else echo DENIED; fi</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>$PROBE_LOG</string>
	<key>StandardErrorPath</key><string>$PROBE_LOG</string>
</dict>
</plist>
EOF
    if [ -d "/Volumes/$DEVICE_NAME" ]; then
        rm -f "$PROBE_LOG"
        launchctl bootout "gui/$(id -u)/$PROBE_LABEL" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$PROBE_PLIST" 2>/dev/null || true
        i=0
        while [ $i -lt 20 ]; do
            sleep 3
            grep -qE 'OK|DENIED' "$PROBE_LOG" 2>/dev/null && break
            i=$((i + 1))
        done
        RESULT="$(grep -oE 'OK|DENIED' "$PROBE_LOG" 2>/dev/null | head -1)"
        log ""
        log "--- permission probe ---"
        log "probe label     : $PROBE_LABEL"
        log "probe plist     : $PROBE_PLIST"
        log "probe log       : $PROBE_LOG"
        log "probe output    : $(cat "$PROBE_LOG" 2>/dev/null | tr '\n' ' ')"
        log "probe result    : ${RESULT:-<no answer within 60s>}"
        launchctl bootout "gui/$(id -u)/$PROBE_LABEL" 2>/dev/null || true
        rm -f "$PROBE_PLIST"
        case "${RESULT:-}" in
            OK)     say "  permission OK - the job can write to the device" ;;
            DENIED) warn "permission DENIED. Allow the dialog, or add to System Settings >"
                    warn "Privacy & Security > Full Disk Access:  $INTERP"
                    warn "then re-run this installer." ;;
            *)      warn "no answer within 60s - a permission dialog is probably waiting."
                    warn "Allow it, or add to Full Disk Access:  $INTERP" ;;
        esac
    else
        say "  device not mounted, so permission cannot be probed now."
        say "  It will be requested the first time the device is plugged in - allow it."
        rm -f "$PROBE_PLIST" 2>/dev/null || true
    fi
else
    say ""
    say "script and agent left as-is (settings are read from the config at run time)"
fi

say ""
say "=== Done ==="
say "Config   : $CONFIG"
say "  device     : $DEVICE_NAME"
say "  url(s)     : $ND_URLS"
say "  login      : $ND_USER"
say "  songs/fill : $SONG_COUNT"
say "Agent    : $LABEL"
say "Log      : ${SHOKZ_LOG:-<none>}"
say "Job log  : /tmp/shokz-auto-fill.log"
say ""
say "To test now:  launchctl kickstart -k gui/$(id -u)/$LABEL"
pause_if_double_clicked
