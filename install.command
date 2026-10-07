#!/bin/bash
#
# Shokz Auto-Fill installer.
#
# Double-click this file, or run it from a terminal. It asks for the device, the
# Navidrome URL(s) and the login, verifies them against the server, then installs:
#   * the fill script under ~/Library/Application Support/ShokzAutoFill
#   * the config (with the password) under ~/.config/shokz-auto-fill, mode 600
#   * a LaunchAgent that runs the script whenever /Volumes changes
#
# It is safe to re-run: existing answers are offered as defaults, and the
# permission probe is repeated (needed after a Homebrew bash upgrade, because the
# TCC grant is keyed to the interpreter's path).
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

# ------------------------------------------------------- existing config as defaults
DEF_DEVICE=""
DEF_URLS=""
DEF_USER="$(id -un)"
DEF_SONGS="50"
if [ -r "$CONFIG" ]; then
    say "Existing config found at $CONFIG - its values are offered as defaults."
    # shellcheck source=/dev/null
    . "$CONFIG"
    DEF_DEVICE="${DEVICE_NAME:-}"
    DEF_URLS="${ND_URLS:-}"
    DEF_USER="${ND_USER:-$(id -un)}"
    DEF_SONGS="${SONG_COUNT:-50}"
    say ""
fi

# ------------------------------------------------------------------- 1. the device
say "--- 1. Which device should be filled? ---"
say "This is the name the player mounts as, i.e. the folder under /Volumes."
vols="$(list_volumes || true)"
if [ -n "$vols" ]; then
    say "Currently mounted volumes:"
    n=0
    for v in $vols; do
        n=$((n + 1))
        printf '  %d) %s\n' "$n" "$v"
        eval "VOL_$n=\$v"
    done
    say ""
fi
prompt="Volume name"
[ -n "$DEF_DEVICE" ] && prompt="$prompt [$DEF_DEVICE]"
printf '%s (or a number from the list): ' "$prompt"
read -r DEVICE_NAME || true
if [ -n "${DEVICE_NAME:-}" ] && [ "$DEVICE_NAME" -eq "$DEVICE_NAME" ] 2>/dev/null; then
    eval "DEVICE_NAME=\${VOL_$DEVICE_NAME:-}"
fi
[ -n "${DEVICE_NAME:-}" ] || DEVICE_NAME="$DEF_DEVICE"
[ -n "${DEVICE_NAME:-}" ] || die "A device name is required."
say "  -> device: /Volumes/$DEVICE_NAME"
say ""

# --------------------------------------------------------- 2. Navidrome URL(s)
say "--- 2. Navidrome URL(s) ---"
say "Space-separated, tried in order until one answers. Put the fastest first"
say "(e.g. a LAN address), then anything that works remotely."
prompt="URL(s)"
[ -n "$DEF_URLS" ] && prompt="$prompt [$DEF_URLS]"
printf '%s: ' "$prompt"
read -r ND_URLS || true
[ -n "${ND_URLS:-}" ] || ND_URLS="$DEF_URLS"
[ -n "${ND_URLS:-}" ] || die "At least one Navidrome URL is required."
ND_URLS="$(printf '%s' "$ND_URLS" | tr ',' ' ')"
say "  -> will try: $ND_URLS"
say ""

# ------------------------------------------------------------------ 3. the login
say "--- 3. Navidrome login ---"
printf 'Username [%s]: ' "$DEF_USER"
read -r ND_USER || true
[ -n "${ND_USER:-}" ] || ND_USER="$DEF_USER"

# Offer to migrate a credential from an older install rather than retyping it.
LEGACY_SCRIPT="$HOME/.bin/scripts/auto_fill_shokz.sh"
ND_PASS=""
if [ -r "$LEGACY_SCRIPT" ]; then
    # Handles both single- and double-quoted assignments; the original used single
    # quotes, which a naive sed for ND_PASS="..." silently fails to match.
    OLD_PASS="$(awk 'NR<=40 { eq=index($0,"="); if (eq>0 && substr($0,1,eq-1)=="ND_PASS") { print substr($0,eq+1); exit } }' "$LEGACY_SCRIPT" | tr -d "\"'")"
    if [ -n "${OLD_PASS:-}" ]; then
        printf 'Found an existing Navidrome password in %s. Use it? [Y/n]: ' "$LEGACY_SCRIPT"
        read -r ans || true
        case "${ans:-Y}" in
            [Nn]*) : ;;
            *) ND_PASS="$OLD_PASS"; say "  -> using the existing password (not displayed)" ;;
        esac
    fi
    unset OLD_PASS
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

# ------------------------------------------------------------- 4. songs per fill
printf -- '--- 4. Songs per fill [%s]: ' "$DEF_SONGS"
read -r SONG_COUNT || true
[ -n "${SONG_COUNT:-}" ] || SONG_COUNT="$DEF_SONGS"
say ""

# ------------------------------------------------- 5. verify against the server
say "--- 5. Checking the URL(s) and login ---"
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
    warn "No configured URL answered."
    printf 'Install anyway so you can fix the URL later? [y/N]: '
    read -r ans || true
    case "${ans:-N}" in [Yy]*) : ;; *) die "Aborted at your request." ;; esac
fi
say ""

# ------------------------------------------------------- 6. non-platform shell
say "--- 6. Shell for the background job ---"
ensure_non_platform_shell
INTERP="$BREW_BASH"
say "  using $INTERP (not a platform binary, so macOS can grant it access)"
say ""

# ------------------------------------------------------------- 7. write config
mkdir -p "$CONFIG_DIR"
umask 077
cat > "$CONFIG" <<EOF
# $APP_NAME configuration.  Created $(date '+%Y-%m-%d %H:%M').
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
say "  wrote $CONFIG (mode 600, never committed)"

# ----------------------------------------------------------- 8. install files
mkdir -p "$SUPPORT/bin"
cp ./bin/auto_fill_shokz.sh "$SCRIPT_DEST"
# Point the installed copy's shebang at the interpreter actually resolved on this
# machine, so it stays correct on Intel Macs where Homebrew lives in /usr/local.
sed -i '' "1s|.*|#!$INTERP|" "$SCRIPT_DEST"
chmod 755 "$SCRIPT_DEST"
say "  installed script: $SCRIPT_DEST"

# ----------------------------------------------------------- 9. the LaunchAgent
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

# ------------------------------------------------- 10. retire the legacy agent
if launchctl list "$LEGACY_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
    say "  unloaded legacy agent $LEGACY_LABEL"
fi
if [ -f "$LEGACY_PLIST" ]; then
    mv "$LEGACY_PLIST" "$LEGACY_PLIST.disabled" 2>/dev/null \
        && say "  parked legacy plist -> $LEGACY_PLIST.disabled"
fi

# ------------------------------------------------------------- 11. load it
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null \
    || launchctl load "$PLIST_DEST" 2>/dev/null || true
sleep 2
if launchctl list "$LABEL" >/dev/null 2>&1; then
    say "  agent loaded: $LABEL"
else
    warn "agent does not appear in launchctl; check: launchctl list | grep shokz"
fi

# ------------------------------------------------- 12. removable-volume permission
say ""
say "--- 7. Removable-volume permission ---"
say "macOS will ask once to allow access to removable volumes. If a dialog"
say "appears, click Allow. (This is the whole reason for the non-platform shell.)"
PROBE_LABEL="com.brookjordan.shokz-auto-fill.probe"
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
    say "  device not mounted right now, so permission cannot be probed."
    say "  It will be requested the first time the device is plugged in (Allow it)."
    rm -f "$PROBE_PLIST" 2>/dev/null || true
fi

say ""
say "=== Done ==="
say "Config   : $CONFIG"
say "Script   : $SCRIPT_DEST"
say "Agent    : $LABEL"
say "Log      : /tmp/shokz-auto-fill.log"
say ""
say "Plug the device in (or replug it) to trigger a fill. To test now:"
say "  launchctl kickstart -k gui/$(id -u)/$LABEL"
pause_if_double_clicked
