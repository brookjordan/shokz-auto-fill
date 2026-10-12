#!/bin/bash
# Shared constants and helpers for the Shokz auto-fill installer.
# Sourced by install.command and uninstall.command. Not executable on its own.

APP_NAME="Shokz Auto-Fill"

# launchd identity. The installer replaces any earlier version of this agent, so
# there is only ever one job watching /Volumes.
LABEL="local.shokz-auto-fill"

SUPPORT="$HOME/Library/Application Support/ShokzAutoFill"
# shellcheck disable=SC2034  # part of this library's interface; used by callers
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
# Also puts the terminal back into canonical mode with echo on, so a run that
# inherited a terminal left raw by an older version cannot leave it that way.
_RESTORED=0
_restore_output() {
    if [ "${_RESTORED:-0}" = 1 ]; then return 0; fi
    _RESTORED=1
    # Let the caller stop any background work it started, so leaving does not sit
    # waiting for a network check to time out.
    if command -v stop_checks >/dev/null 2>&1; then stop_checks; fi
    stty icanon echo isig 2>/dev/null || true
    exec 1>&3 2>&4 2>/dev/null || true
    exec 3>&- 4>&- 2>/dev/null || true
    wait 2>/dev/null || true
    return 0
}

# Ctrl-C during a prompt. The EXIT trap does the terminal and tee cleanup.
_interrupted() {
    printf '\nCancelled. Nothing was changed.\n' >&2
    exit 130
}

# ---------------------------------------------------------------- prompting --
# One reader for every question, used whether stdin is a terminal or a pipe - so
# the tests drive the same code the terminal does.
#
# The terminal is put into non-canonical, no-echo mode and this reader echoes what
# it accepts. That is deliberate: bash's line editor (readline) treats a bare
# Escape as the start of a meta sequence and swallows it, which is how "Escape goes
# back a step" was lost. Reading the keys here also keeps an arrow key from landing
# in the value as literal characters, and lets a bracketed paste be stepped over so
# the pasted text is inserted normally.
#
#   Escape / Up / back / <   go back one question
#   Down / next / >          move forward to a question already answered
#   Backspace                delete one character
#   Ctrl-U                   clear the line
#   Left / Right             ignored: answers are typed at the end
#   Ctrl-C / Ctrl-D          cancel
#
# At the password prompt only Escape, < and > navigate, because a password can be
# any string.
#
# Values live in globals, so revisiting a step never costs an answer given at
# another one.

STEP_VALUE=""
SECRET_VALUE=""

# Drop terminal escape sequences and their leftovers, so a sequence that arrived in
# pieces cannot become invisible characters inside a URL or a volume name. A CSI
# sequence is ESC [ parameters final-byte, the final byte being anything from @ to
# ~, which covers both an arrow key (ESC [ A) and a paste marker (ESC [ 200 ~).
sanitize_answer() {
    local esc=$'\e'
    printf '%s' "$1" | sed -e "s/${esc}\[[0-9;?]*[@-~]//g" -e "s/${esc}//g" | tr -d '[:cntrl:]'
}

# Put the terminal back the way it was found.
_end_read() {
    if [ -t 0 ]; then stty icanon echo isig 2>/dev/null || true; fi
    return 0
}

# The terminal while an ordinary key is awaited: block until one arrives.
_tty_wait_key() {
    if [ -t 0 ]; then stty -icanon -echo min 1 time 0 2>/dev/null || true; fi
    return 0
}

# The terminal while the byte after an Escape is awaited. `min 0 time 1` is the
# driver's own tenth-of-a-second window, and it is what tells a lone Escape from
# the start of an arrow key. It is used in place of `read -t 0.1` because
# /bin/bash on macOS is 3.2, which rejects a fractional timeout outright
# ("read: 0.1: invalid timeout specification") and would report every arrow key as
# a bare Escape.
_tty_wait_byte() {
    if [ -t 0 ]; then stty -icanon -echo min 0 time 1 2>/dev/null || true; fi
    return 0
}

# Read one line into REPLY_LINE. Returns 0 for a line, 1 for back, 3 for forward,
# 2 for cancel or no more input.
#   $1 prompt, $2 = 1 to keep the answer off the screen
#
# `seq` carries the escape-sequence state between keystrokes:
#   0  ordinary
#   1  an Escape has been read and may be a keypress of its own
#   2  inside a sequence (Escape [ ... or Escape O ...)
# Every Escape restarts that state, so two arrow keys pressed together cannot leave
# a stray byte behind, and a bracketed paste is stepped over marker by marker while
# the text between the markers is read as ordinary characters.
_read_line_bytes() {
    local prompt="$1" quiet="${2:-0}" buf="" ch seq=0

    printf '%s: ' "$prompt" >&2
    _tty_wait_key

    while :; do
        if IFS= read -rsn1 ch; then
            # bash's -n stops at the delimiter and does not hand it back, so an
            # empty value with success is the newline that ends the line.
            if [ -z "$ch" ]; then
                case "$seq" in
                    1) _end_read; printf '\n' >&2; return 1 ;;
                    2) seq=0; _tty_wait_key; continue ;;
                    *) break ;;
                esac
            fi
        else
            # No byte at all: either the input ended, or the window above ran out.
            case "$seq" in
                1) _end_read; printf '\n' >&2; return 1 ;;
                2) seq=0; _tty_wait_key; continue ;;
                *)
                    if [ -n "$buf" ]; then break; fi
                    _end_read
                    printf '\n' >&2
                    return 2 ;;
            esac
        fi

        if [ "$ch" = $'\e' ]; then
            if [ "$seq" = 1 ]; then
                _end_read
                printf '\n' >&2
                return 1
            fi
            seq=1
            _tty_wait_byte
            continue
        fi

        if [ "$seq" = 1 ]; then
            case "$ch" in
                '['|'O') seq=2; _tty_wait_byte; continue ;;
                *)       _end_read; printf '\n' >&2; return 1 ;;
            esac
        fi
        if [ "$seq" = 2 ]; then
            case "$ch" in
                A)      _end_read; printf '\n' >&2; return 1 ;;
                B)      _end_read; printf '\n' >&2; return 3 ;;
                [@-~])  seq=0; _tty_wait_key; continue ;;
                *)      continue ;;
            esac
        fi

        case "$ch" in
            $'\r') break ;;
            $'\177'|$'\010')
                if [ -n "$buf" ]; then
                    buf="${buf%?}"
                    [ "$quiet" = 1 ] || printf '\b \b' >&2
                fi ;;
            $'\025')
                buf=""
                [ "$quiet" = 1 ] || printf '\r\033[K%s: ' "$prompt" >&2 ;;
            $'\003'|$'\004')
                _end_read
                printf '\n' >&2
                return 2 ;;
            *)
                buf="${buf}${ch}"
                [ "$quiet" = 1 ] || printf '%s' "$ch" >&2 ;;
        esac
    done

    _end_read
    if [ "$quiet" = 1 ]; then printf '\n' >&2; fi
    REPLY_LINE="$buf"
    return 0
}

# Prompt with the brackets supplied by the caller, e.g. "URL(s) [old]".
# Returns 0 for a value, 1 for back, 2 for cancel, 3 for forward.
read_step_raw() {
    local prompt="$1" default="${2:-}" rc line
    STEP_VALUE=""
    _read_line_bytes "$prompt" 0; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    line="$REPLY_LINE"
    case "$line" in
        back|BACK|Back|'<') return 1 ;;
        next|NEXT|Next|'>') return 3 ;;
    esac
    STEP_VALUE="$(sanitize_answer "$line")"
    [ -n "$STEP_VALUE" ] || STEP_VALUE="$default"
    return 0
}

# Read without echoing, for the password. Only the symbols navigate here: a
# password is free-form, so no word can be reserved at this prompt.
read_secret() {
    local prompt="$1" rc line
    SECRET_VALUE=""
    _read_line_bytes "$prompt" 1; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    line="$REPLY_LINE"
    case "$line" in
        '<') return 1 ;;
        '>') return 3 ;;
    esac
    # shellcheck disable=SC2034  # the caller reads this after read_secret
    SECRET_VALUE="$line"
    return 0
}
