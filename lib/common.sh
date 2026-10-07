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
    local line choice i n hint rc
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

    read_step_raw "Volume name${default:+ [$default]} (or a number from the list)" "$default"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    choice="$STEP_VALUE"

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

# ---------------------------------------------------------------- logging ----
# The installer writes a full log of what it did and why. It captures every layer
# of each URL check: name resolution, TCP, TLS, HTTP status, timings, response
# headers and a body excerpt. Anything that could be replayed is redacted first,
# because a Subsonic token plus its salt is a working credential.

SHOKZ_LOG=""

# Strip credentials from a string before it reaches the log: the token and salt
# query parameters, and the password itself if it ever appears.
redact() {
    local s="$1"
    if [ -n "${ND_PASS:-}" ]; then
        s="${s//"$ND_PASS"/<redacted-password>}"
    fi
    printf '%s' "$s" | sed -E 's/([?&](t|s|p|token|salt|password|u)=)[^&[:space:]]*/\1<redacted>/g'
}

# Append one line to the log file. Writes only to the file, so the deep detail does
# not clutter the terminal. A no-op until log_init has run.
log() {
    [ -n "${SHOKZ_LOG:-}" ] || return 0
    if [ -z "${1:-}" ]; then
        printf '\n' >> "$SHOKZ_LOG" 2>/dev/null || true
        return 0
    fi
    printf '%s\n' "$(redact "$*")" >> "$SHOKZ_LOG" 2>/dev/null || true
}

log_init() {
    local dir="$SUPPORT/logs"
    mkdir -p "$dir" 2>/dev/null || return 0
    chmod 700 "$dir" 2>/dev/null || true
    SHOKZ_LOG="$dir/install-$(date +%Y%m%dT%H%M%S).log"
    : > "$SHOKZ_LOG" 2>/dev/null || { SHOKZ_LOG=""; return 0; }
    chmod 600 "$SHOKZ_LOG" 2>/dev/null || true
    ln -sf "$(basename "$SHOKZ_LOG")" "$dir/latest.log" 2>/dev/null || true
    log "=== $APP_NAME installer ==="
    log "started : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "log     : $SHOKZ_LOG"
    log "note    : mode 600. Tokens, salts and the password are redacted."
}

# What each curl exit code means, so the log explains the failure rather than
# printing a number.
curl_meaning() {
    case "${1:-}" in
        0)    echo "ok" ;;
        5)    echo "could not resolve proxy" ;;
        6)    echo "could not resolve host (DNS)" ;;
        7)    echo "connection refused (nothing listening)" ;;
        28)   echo "timed out: no reply before the deadline. Filtered port, or an upstream that accepts and never answers" ;;
        35)   echo "TLS handshake failed" ;;
        51|60) echo "certificate not trusted, or does not match this host" ;;
        52)   echo "server closed the connection without replying" ;;
        56)   echo "failure receiving data" ;;
        *)    echo "unclassified curl failure" ;;
    esac
}

# Everything about one URL, at every layer, into the log.
diag_url() {
    local url="$1" user="$2" pass="$3" timeout="${4:-8}"
    local scheme host port salt token hdr body err meta rc st tls_time tls_ok conn_time connected concl
    local W=16

    scheme="${url%%://*}"
    host="${url#*://}"; host="${host%%/*}"
    port=443; [ "$scheme" = "http" ] && port=80
    case "$host" in *:*) port="${host##*:}"; host="${host%%:*}";; esac

    log ""
    log "  ------------------------------------------------------------------"
    log "  $(printf "%-${W}s : %s" "url" "$url")"
    log "  $(printf "%-${W}s : %s" "scheme/host/port" "$scheme $host $port")"

    # An address literal needs no lookup, and saying "no record" for one is wrong.
    if printf '%s' "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || printf '%s' "$host" | grep -q ':'; then
        log "  $(printf "%-${W}s : %s" "DNS" "address literal, no lookup needed")"
    elif [ -n "$(dig +short A "$host" 2>/dev/null)$(dig +short AAAA "$host" 2>/dev/null)" ]; then
        log "  $(printf "%-${W}s : %s" "DNS A" "$(dig +short A "$host" 2>/dev/null | tr '\n' ' ')")"
        log "  $(printf "%-${W}s : %s" "DNS AAAA" "$(dig +short AAAA "$host" 2>/dev/null | tr '\n' ' ')")"
        log "  $(printf "%-${W}s : %s" "DNS server" "$(dig "$host" A 2>/dev/null | awk '/^;; SERVER/{print $3; exit}')")"
    else
        log "  $(printf "%-${W}s : %s" "DNS" "no A or AAAA record for $host")"
    fi

    if command -v nc >/dev/null 2>&1; then
        if nc -z -G "$timeout" "$host" "$port" >/dev/null 2>&1; then
            log "  $(printf "%-${W}s : %s" "TCP $port" "open")"
        else
            log "  $(printf "%-${W}s : %s" "TCP $port" "closed or filtered")"
        fi
    fi

    salt=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
    token=$(printf '%s' "${pass}${salt}" | md5)
    hdr=$(mktemp 2>/dev/null) || hdr=""
    body=$(mktemp 2>/dev/null) || body=""
    err=$(mktemp 2>/dev/null) || err=""

    # -s keeps curl's own error text out of the machine-readable -w fields, so the
    # two can be logged as separate lines instead of one mangled one.
    meta=$(curl -s -D "${hdr:-/dev/null}" -o "${body:-/dev/null}" -w \
        'code=%{http_code} ip=%{remote_ip} httpver=%{http_version} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s firstbyte=%{time_starttransfer}s total=%{time_total}s bytes=%{size_download} redirects=%{num_redirects}' \
        --connect-timeout "$timeout" --max-time "$((timeout * 2))" \
        "${url%/}/rest/ping.view?u=${user}&t=${token}&s=${salt}&v=1.12.0&c=installer&f=json" \
        2>"${err:-/dev/null}")
    rc=$?

    log "  $(printf "%-${W}s : %s" "curl exit" "$rc, $(curl_meaning "$rc")")"
    log "  $(printf "%-${W}s : %s" "timings" "$meta")"
    if [ -s "${err:-/dev/null}" ]; then
        while IFS= read -r ln; do
            log "  $(printf "%-${W}s : %s" "curl says" "$ln")"
        done < "$err"
    fi

    if [ -s "${hdr:-/dev/null}" ]; then
        log "  $(printf "%-${W}s :" "response head")"
        while IFS= read -r ln; do log "    $ln"; done < "$hdr"
    else
        log "  $(printf "%-${W}s : %s" "response head" "none received")"
    fi

    st=""
    if [ -s "${body:-/dev/null}" ]; then
        log "  $(printf "%-${W}s :" "body excerpt")"
        head -c 400 "$body" | tr -d '\r' | while IFS= read -r ln; do log "    $ln"; done
        st=$(jq -r '.["subsonic-response"].status // empty' < "$body" 2>/dev/null)
    elif [ -s "${hdr:-/dev/null}" ]; then
        log "  $(printf "%-${W}s : %s" "body" "empty, the server replied with headers only")"
    else
        log "  $(printf "%-${W}s : %s" "body" "none, no response was received")"
    fi
    log "  $(printf "%-${W}s : %s" "subsonic status" "${st:-<none>}")"

    tls_time=$(printf '%s' "$meta" | sed -n 's/.*tls=\([0-9.]*\)s.*/\1/p')
    case "$tls_time" in ""|0|0.000000) tls_ok=0 ;; *) tls_ok=1 ;; esac
    conn_time=$(printf '%s' "$meta" | sed -n 's/.*connect=\([0-9.]*\)s.*/\1/p')
    case "$conn_time" in ""|0|0.000000) connected=0 ;; *) connected=1 ;; esac

    if [ "$rc" -eq 0 ] && [ "$st" = "ok" ]; then
        concl="authenticated"
    elif [ "$rc" -eq 0 ] && [ -n "$st" ]; then
        concl="reachable, and it rejected the credentials"
    elif [ "$rc" -eq 28 ] && [ -s "${hdr:-/dev/null}" ]; then
        concl="headers arrived but the body never finished, so the upstream stalled mid-response"
    elif [ "$rc" -eq 28 ] && [ "$tls_ok" = 1 ]; then
        concl="TLS completed and then nothing came back. A proxy is waiting on an upstream that never answers"
    elif [ "$rc" -eq 28 ] && [ "$connected" = 1 ]; then
        concl="the TCP connection opened and the server never replied"
    elif [ "$rc" -eq 28 ]; then
        concl="no reply before the deadline. The port is filtered, or the host is down"
    elif [ "$rc" -eq 7 ]; then
        concl="nothing is listening on that port"
    elif [ "$rc" -eq 6 ]; then
        concl="the hostname did not resolve"
    elif [ "$rc" -eq 35 ] || [ "$rc" -eq 51 ] || [ "$rc" -eq 60 ]; then
        concl="the TLS handshake or the certificate failed"
    else
        concl="see the curl exit code above"
    fi
    log "  $(printf "%-${W}s : %s" "conclusion" "$concl")"

    [ -n "$hdr" ] && rm -f "$hdr"
    [ -n "$body" ] && rm -f "$body"
    [ -n "$err" ] && rm -f "$err"
    # The status is the return value, so this one instrumented request also decides
    # the outcome rather than probing the same URL twice.
    printf '%s' "$st"
}

log_env() {
    log ""
    log "--- environment ---"
    log "host            : $(hostname 2>/dev/null)"
    log "model           : $(sysctl -n hw.model 2>/dev/null)"
    log "macOS           : $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
    log "arch            : $(uname -m)"
    log "run by          : $(id -un) uid=$(id -u)"
    log "shell           : ${SHELL:-unknown}"
    log "bash            : $BASH_VERSION"
    log "brew            : $(brew --version 2>/dev/null | head -1)"
    log "jq              : $(jq --version 2>/dev/null)"
    log "curl            : $(curl --version 2>/dev/null | head -1)"
    log "agent label     : $LABEL"
    log "app support     : $SUPPORT"
    log "config path     : $CONFIG"
    log "plist path      : $PLIST_DEST"
    log "interpreter     : $BREW_BASH"
    if [ -x "$BREW_BASH" ]; then
        log "interp identity : $(codesign -dvvv "$BREW_BASH" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
        if codesign -dvvv "$BREW_BASH" 2>&1 | grep -qi 'Platform identifier'; then
            log "interp platform : YES. TCC can never grant a platform binary; this is a bug"
        else
            log "interp platform : no (grantable)"
        fi
    fi
    log "volumes seen    : $(list_volumes 2>/dev/null | tr '\n' '|')"
}


# Undo the installer's tee and let it drain, so the last log lines are not lost.
_restore_output() {
    stty icanon echo 2>/dev/null || true
    exec 1>&3 2>&4 2>/dev/null || true
    exec 3>&- 4>&- 2>/dev/null || true
    wait 2>/dev/null || true
}

# ---------------------------------------------------------------- prompting --
# Interactive reads that support stepping back. A bare Escape is caught by reading
# one keystroke in raw mode; the rest of the line is read normally, so editing and
# pasting still work. Values live in globals, so revisiting a step never costs an
# answer given at another one.

STEP_VALUE=""
SECRET_VALUE=""

# Read one line. Returns 0 for a line, 1 for Escape, 2 for cancel.
_read_core() {
    local silent="$1" first rest nxt rc
    STEP_VALUE=""
    while :; do
        if [ "$silent" = 1 ]; then
            IFS= read -rsn1 first; rc=$?
        else
            IFS= read -rn1 first; rc=$?
        fi
        # End of input is not the same as pressing Enter. Without this, exhausted
        # stdin takes the default forever and the step machine spins.
        if [ "$rc" -ne 0 ] && [ -z "$first" ]; then return 2; fi
        case "$first" in
            $'\e')
                # Every arrow key starts with ESC. In a plain read the shell is not
                # using them, so up can mean back and down can mean forward. Any
                # other escape sequence is drained and ignored.
                stty -icanon min 0 time 0 2>/dev/null || true
                IFS= read -rn1 nxt 2>/dev/null || true
                case "$nxt" in
                    '['|'O')
                        IFS= read -rn1 nxt 2>/dev/null || true
                        case "$nxt" in
                            A) stty icanon 2>/dev/null || true; return 1 ;;
                            B) stty icanon 2>/dev/null || true; return 3 ;;
                            *)
                                stty -icanon min 0 time 1 2>/dev/null || true
                                while IFS= read -rn1 nxt 2>/dev/null; do :; done
                                stty icanon 2>/dev/null || true
                                continue ;;
                        esac ;;
                    *) stty icanon 2>/dev/null || true; return 1 ;;
                esac ;;
            $'\x03'|$'\x04') return 2 ;;
        esac
        break
    done
    [ -n "$first" ] || return 0
    if [ "$silent" = 1 ]; then
        IFS= read -rs rest || true
    else
        IFS= read -r rest || true
    fi
    STEP_VALUE="${first}${rest}"
    return 0
}

# Prompt with the brackets supplied by the caller, e.g. "URL(s) [old]".
read_step_raw() {
    local prompt="$1" default="${2:-}" rc
    printf '%s: ' "$prompt" >&2
    stty -icanon min 1 time 0 2>/dev/null || true
    _read_core 0; rc=$?
    stty icanon 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then printf '\n' >&2; return "$rc"; fi
    [ -n "$STEP_VALUE" ] || STEP_VALUE="$default"
    return 0
}

# Read without echoing, for the password.
read_secret() {
    local prompt="$1" rc
    printf '%s: ' "$prompt" >&2
    stty -icanon min 1 time 0 2>/dev/null || true
    _read_core 1; rc=$?
    stty icanon 2>/dev/null || true
    printf '\n' >&2
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    SECRET_VALUE="$STEP_VALUE"
    return 0
}