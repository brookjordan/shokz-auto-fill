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

# ------------------------------------------------------------- what is installed
CUR_DEVICE=""
CUR_URLS=""
CUR_USER="$(id -un)"
CUR_PASS=""
CUR_SONGS="50"
HAVE_CONFIG=0
if [ -r "$CONFIG" ]; then
    HAVE_CONFIG=1
    # shellcheck source=/dev/null
    . "$CONFIG"
    CUR_DEVICE="${DEVICE_NAME:-}"
    CUR_URLS="${ND_URLS:-}"
    CUR_USER="${ND_USER:-$(id -un)}"
    CUR_PASS="${ND_PASS:-}"
    CUR_SONGS="${SONG_COUNT:-50}"
fi
HAVE_SCRIPT=0; [ -x "$SCRIPT_DEST" ] && HAVE_SCRIPT=1
HAVE_PLIST=0;  [ -f "$PLIST_DEST" ]  && HAVE_PLIST=1
AGENT_LOADED=0
launchctl list "$LABEL" >/dev/null 2>&1 && AGENT_LOADED=1

INSTALLED=0
{ [ "$HAVE_CONFIG" = 1 ] || [ "$HAVE_PLIST" = 1 ] || [ "$HAVE_SCRIPT" = 1 ]; } && INSTALLED=1

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
        DO_LOGIN=1
    fi
    say ""
fi

# ------------------------------------------------------------------- the device
if [ "$DO_DEVICE" = 1 ]; then
    say "--- Which device should be filled? ---"
    say "This is the name the player mounts as, i.e. the folder under /Volumes."
    DEVICE_NAME="$(choose_volume "$CUR_DEVICE")"
    [ -n "${DEVICE_NAME:-}" ] || DEVICE_NAME="$CUR_DEVICE"
    [ -n "${DEVICE_NAME:-}" ] || die "A device name is required."
    say "  -> /Volumes/$DEVICE_NAME"
    say ""
else
    DEVICE_NAME="$CUR_DEVICE"
fi

# --------------------------------------------------------- Navidrome URL(s)
if [ "$DO_URLS" = 1 ]; then
    say "--- Navidrome URL(s) ---"
    say "Space-separated, tried in order until one answers. Put the fastest first"
    say "(e.g. a LAN address), then anything that works remotely."
    prompt="URL(s)"
    [ -n "$CUR_URLS" ] && prompt="$prompt [$CUR_URLS]"
    printf '%s: ' "$prompt"
    read -r ND_URLS || true
    [ -n "${ND_URLS:-}" ] || ND_URLS="$CUR_URLS"
    [ -n "${ND_URLS:-}" ] || die "At least one Navidrome URL is required."
    ND_URLS="$(printf '%s' "$ND_URLS" | tr ',' ' ')"
    say "  -> will try: $ND_URLS"
    say ""
else
    ND_URLS="$CUR_URLS"
fi

# ------------------------------------------------------------------ the login
if [ "$DO_LOGIN" = 1 ]; then
    say "--- Navidrome login ---"
    printf 'Username [%s]: ' "$CUR_USER"
    read -r ND_USER || true
    [ -n "${ND_USER:-}" ] || ND_USER="$CUR_USER"

    ND_PASS=""
    if [ -n "$CUR_PASS" ]; then
        printf 'Keep the stored password? [Y/n]: '
        read -r ans || true
        case "${ans:-Y}" in
            [Nn]*) : ;;
            *) ND_PASS="$CUR_PASS"; say "  -> keeping the stored password" ;;
        esac
    fi
    if [ -z "$ND_PASS" ]; then
        printf 'Password for %s (not echoed): ' "$ND_USER"
        read -r -s ND_PASS || true
        printf '\n'
        printf 'Confirm password: '
        read -r -s ND_PASS2 || true
        printf '\n'
        [ "$ND_PASS" = "$ND_PASS2" ] || die "Passwords did not match."
        unset ND_PASS2
    fi
    [ -n "${ND_PASS:-}" ] || die "A password is required."
    say ""
else
    ND_USER="$CUR_USER"
    ND_PASS="$CUR_PASS"
fi

# ------------------------------------------------------------- songs per fill
if [ "$DO_SONGS" = 1 ]; then
    printf -- '--- Songs per fill [%s]: ' "$CUR_SONGS"
    read -r SONG_COUNT || true
    [ -n "${SONG_COUNT:-}" ] || SONG_COUNT="$CUR_SONGS"
else
    SONG_COUNT="$CUR_SONGS"
fi
case "${SONG_COUNT:-}" in
    ''|*[!0-9]*) die "Songs per fill must be a whole number (got '${SONG_COUNT:-}')." ;;
esac
[ "$SONG_COUNT" -gt 0 ] || die "Songs per fill must be greater than zero."
[ "$DO_SONGS" = 1 ] && { say "  -> $SONG_COUNT songs per fill"; say ""; }

# ------------------------------------------- verify (only when it can matter)
if [ "$DO_URLS" = 1 ] || [ "$DO_LOGIN" = 1 ] || [ "$INSTALLED" = 0 ]; then
    say "--- Checking the URL(s) and login ---"
    WORKING_URL=""
    for u in $ND_URLS; do
        u="${u%/}"
        st="$(subsonic_ping "$u" "$ND_USER" "$ND_PASS" 8 || true)"
        if [ -z "$st" ]; then
            say "  unreachable : $u"
        elif [ "$st" = "ok" ]; then
            say "  OK          : $u (authenticated)"
            [ -n "$WORKING_URL" ] || WORKING_URL="$u"
        else
            say "  reachable   : $u (Subsonic status='$st' - check the login)"
            [ -n "$WORKING_URL" ] || WORKING_URL="$u"
        fi
    done
    if [ -z "$WORKING_URL" ]; then
        warn "no configured URL answered."
        printf 'Continue anyway so you can fix it later? [y/N]: '
        read -r ans || true
        case "${ans:-N}" in [Yy]*) : ;; *) die "Aborted at your request." ;; esac
    fi
    say ""
else
    say "Settings changed only - no server check needed (credentials unchanged)."
    say ""
fi

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

# ---------------------------------------- install / refresh the script + agent
if [ "$DO_REFRESH" = 1 ] || [ "$INSTALLED" = 0 ]; then
    say ""
    say "--- Shell for the background job ---"
    ensure_non_platform_shell
    INTERP="$BREW_BASH"
    say "  using $INTERP (not a platform binary, so macOS can grant it access)"

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


    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null \
        || launchctl load "$PLIST_DEST" 2>/dev/null || true
    sleep 2
    if launchctl list "$LABEL" >/dev/null 2>&1; then
        say "  agent loaded: $LABEL"
    else
        warn "agent does not appear in launchctl; check: launchctl list | grep shokz"
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
say "Log      : /tmp/shokz-auto-fill.log"
say ""
say "To test now:  launchctl kickstart -k gui/$(id -u)/$LABEL"
pause_if_double_clicked
