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

# List volume names under /Volumes, one per line. A name can contain spaces, so
# callers must read this line by line. Word-splitting it turns one player into two
# menu entries, which is exactly what this replaced.
list_volumes() {
    local v name
    for v in /Volumes/*; do
        [ -d "$v" ] || continue
        name=$(basename "$v")
        case "$name" in
            "Macintosh HD"|"Recovery"|"com.apple.TimeMachine"*) continue ;;
        esac
        printf '%s\n' "$name"
    done
}

# A short description of a volume for the menu. "Removable" is useless here because
# macOS reports it for disk images too. What actually separates a player from a
# mounted image is the protocol, the filesystem, and whether it can be written to.
volume_hint() {
    local info fs free ro out
    info=$(diskutil info "$1" 2>/dev/null) || return 0
    case "$info" in
        *"Disk Image"*) printf 'disk image'; return 0 ;;
    esac
    fs=$(printf '%s\n' "$info" | sed -n 's/^ *File System Personality: *//p' | head -1)
    free=$(printf '%s\n' "$info" | sed -n 's/^ *Volume Free Space: *//p' | head -1 | sed 's/ (.*//')
    ro=$(printf '%s\n' "$info" | sed -n 's/^ *Volume Read-Only: *//p' | head -1)
    out="${fs:-unknown filesystem}"
    [ -n "$free" ] && out="$out, $free free"
    case "$ro" in Yes*) out="$out, read-only" ;; esac
    printf '%s' "$out"
}

# Show the mounted volumes and read a choice. The chosen name goes to stdout and
# everything else to stderr, so the caller can capture it with a command
# substitution without swallowing the menu.
choose_volume() {
    local default="${1:-}"
    local -a vols=()
    local line choice i n hint
    while IFS= read -r line; do
        [ -n "$line" ] && vols+=("$line")
    done < <(list_volumes)

    if [ "${#vols[@]}" -gt 0 ]; then
        printf 'Currently mounted volumes:\n' >&2
        for i in "${!vols[@]}"; do
            n=$((i + 1))
            hint=$(volume_hint "/Volumes/${vols[$i]}")
            if [ -n "$hint" ]; then
                printf '  %d) %s  (%s)\n' "$n" "${vols[$i]}" "$hint" >&2
            else
                printf '  %d) %s\n' "$n" "${vols[$i]}" >&2
            fi
        done
        printf '\n' >&2
    fi

    printf 'Volume name' >&2
    [ -n "$default" ] && printf ' [%s]' "$default" >&2
    printf ' (or a number from the list): ' >&2
    IFS= read -r choice || true

    case "${choice:-}" in
        '')       printf '%s' "$default" ;;
        *[!0-9]*) printf '%s' "$choice" ;;
        *)
            i=$((choice - 1))
            if [ "$i" -ge 0 ] && [ "$i" -lt "${#vols[@]}" ]; then
                printf '%s' "${vols[$i]}"
            else
                warn "there is no volume numbered $choice" >&2
            fi ;;
    esac
}
pause_if_double_clicked() {
    # A double-clicked .command closes its Terminal window on exit; hold it open.
    case "${SHOKZ_NO_PAUSE:-0}" in 1) return 0 ;; esac
    if [ -t 0 ]; then
        printf '\nPress return to close this window... '
        read -r _ || true
    fi
}
