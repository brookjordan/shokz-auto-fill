#!/bin/bash
# Shared constants and helpers for the Shokz auto-fill installer.
# Sourced by install.command and uninstall.command. Not executable on its own.

APP_NAME="Shokz Auto-Fill"

# launchd identity. The installer replaces any earlier version of this agent, so
# there is only ever one job watching /Volumes.
LABEL="local.shokz-auto-fill"

SUPPORT="$HOME/Library/Application Support/ShokzAutoFill"
SCRIPT_DEST="$SUPPORT/bin/auto_fill_shokz.sh"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/shokz-auto-fill"
CONFIG="$CONFIG_DIR/config"

# A NON-PLATFORM shell is mandatory. When a LaunchAgent runs /bin/bash, bash
# becomes the "responsible process", and /bin/bash is an Apple platform binary
# (codesign: "Platform identifier=26"). macOS refuses to grant TCC permissions to
# platform binaries and cannot even prompt:
#     "Platform binary prompting is 'Deny' because: is Platform Binary"
# so writes to the removable volume fail with EPERM forever, silently.
# A Homebrew bash is not a platform binary, so macOS can prompt and grant.
BREW_BASH="/opt/homebrew/bin/bash"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_platform_binary() { codesign -dvvv "$1" 2>&1 | grep -qi "Platform identifier"; }

ensure_non_platform_shell() {
    if [ -x "$BREW_BASH" ] && ! is_platform_binary "$BREW_BASH"; then
        return 0
    fi
    command -v brew >/dev/null 2>&1 \
        || die "Homebrew is required to provide a non-platform bash (https://brew.sh)."
    say "Installing bash via Homebrew - required because /bin/bash is an Apple"
    say "platform binary that macOS can never grant removable-volume access to."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install bash >/dev/null 2>&1 \
        || die "brew install bash failed."
    [ -x "$BREW_BASH" ] || die "bash is still missing at $BREW_BASH."
    is_platform_binary "$BREW_BASH" && die "$BREW_BASH is unexpectedly a platform binary."
    return 0
}

# Subsonic/Navidrome ping. Prints the subsonic status ("ok" / "failed") on
# success, nothing on network failure. Credentials are never echoed.
subsonic_ping() {
    local url="$1" user="$2" pass="$3" t="${4:-8}"
    local salt token body http
    salt=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
    token=$(printf '%s' "${pass}${salt}" | md5)
    body=$(curl -sS --connect-timeout "$t" -m "$t" -w '\n%{http_code}' \
        "${url%/}/rest/ping.view?u=${user}&t=${token}&s=${salt}&v=1.12.0&c=bash&f=json" 2>/dev/null) || return 1
    http=$(printf '%s' "$body" | tail -n 1)
    body=$(printf '%s' "$body" | sed '$d')
    [ "$http" = "200" ] || return 1
    printf '%s' "$body" | jq -r '.["subsonic-response"].status // empty' 2>/dev/null
}

# List mountable volumes, excluding the boot volume. Used for the device menu.
list_volumes() {
    local v
    for v in /Volumes/*; do
        [ -d "$v" ] || continue
        case "$(basename "$v")" in
            "Macintosh HD"|"Recovery"|"com.apple.TimeMachine"*) continue ;;
        esac
        basename "$v"
    done
}

pause_if_double_clicked() {
    # A double-clicked .command closes its Terminal window on exit; hold it open.
    case "${SHOKZ_NO_PAUSE:-0}" in 1) return 0 ;; esac
    if [ -t 0 ]; then
        printf '\nPress return to close this window... '
        read -r _ || true
    fi
}
