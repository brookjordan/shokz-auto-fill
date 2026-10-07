#!/opt/homebrew/bin/bash
#
# Shokz auto-fill: when the player mounts, download a fresh random set of songs
# from Navidrome, write it as a numbered folder in <device>/auto-list, keep the
# two newest lists, and eject the device.
#
# WHY THIS RUNS UNDER A NON-PLATFORM SHELL
#   macOS gates removable volumes behind TCC service
#   kTCCServiceSystemPolicyRemovableVolumes. If a LaunchAgent runs /bin/bash, then
#   bash is the responsible process - and /bin/bash is an Apple *platform binary*
#   (codesign reports "Platform identifier=26"). macOS never grants TCC access to
#   platform binaries and cannot even prompt for it:
#       "Platform binary prompting is 'Deny' because: is Platform Binary"
#   so every mkdir on the device fails with EPERM and no explanation. Running
#   under a Homebrew bash (not a platform binary) lets macOS prompt once and then
#   grant it. Do not "simplify" the shebang back to /bin/bash.
#
# CONFIGURATION
#   Read from $SHOKZ_CONFIG, else ~/.config/shokz-auto-fill/config.
#   Contains the device name, Navidrome URL(s) and credentials. Never committed.

set -u

CONFIG="${SHOKZ_CONFIG:-$HOME/.config/shokz-auto-fill/config}"
if [ ! -r "$CONFIG" ]; then
    echo "ERROR: config not found or unreadable: $CONFIG" >&2
    echo "       Run install.command to create it." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"

: "${DEVICE_NAME:?DEVICE_NAME must be set in $CONFIG}"
: "${ND_URLS:?ND_URLS must be set in $CONFIG}"
: "${ND_USER:?ND_USER must be set in $CONFIG}"
: "${ND_PASS:?ND_PASS must be set in $CONFIG}"
SONG_COUNT="${SONG_COUNT:-50}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"

TARGET="/Volumes/$DEVICE_NAME"
STATE_FILE="/tmp/shokz-auto-fill.state"
AUTO_DIR="$TARGET/auto-list"
LOG_FILE="/tmp/shokz-auto-fill.log"

# Touch log if it doesn't exist, then trim it to the last 1000 lines
touch "$LOG_FILE"
echo "$(tail -n 1000 "$LOG_FILE")" > "$LOG_FILE"

# APPEND all output to the log instead of overwriting it
exec >> >(tee -i -a "$LOG_FILE")
exec 2>&1

echo "--- Script started at $(date) ---"

abort() {
    echo "ABORT: $1"
    echo "Short-circuiting: no new auto-list folder, no cleanup, no eject."
    rm -f "$STATE_FILE"
    echo "--- Script aborted at $(date) ---"
    exit 1
}

# Give macOS 2 seconds to properly finish mounting before we touch anything
sleep 2

if [ ! -d "$TARGET" ]; then
    [ ! -f "$STATE_FILE" ] && rm -f "$STATE_FILE"
    echo "$DEVICE_NAME not mounted; nothing to do."
    exit 0
fi

if [ -f "$STATE_FILE" ]; then
    echo "State file exists (another run in progress or a prior run crashed). Skipping."
    echo "If this persists with no download underway, delete ${STATE_FILE} and replug."
    exit 0
fi

touch "$STATE_FILE"
# Always drop the lock when this run exits (success, abort, or crash) so WatchPaths
# firings don't silently no-op forever after an interrupted fill.
trap 'rm -f "$STATE_FILE"' EXIT

make_auth() {
    SALT=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
    TOKEN=$(echo -n "${ND_PASS}${SALT}" | md5)
}

# Returns 0 if base URL answers Subsonic ping with auth OK or wrong-password
# (proves the server is reachable). Network failures return non-zero.
probe_navidrome() {
    local base_url="$1"
    local label="$2"
    make_auth
    echo "Probing ${label} at ${base_url}..."
    local body http_code
    body=$(curl -sS --connect-timeout "$CONNECT_TIMEOUT" -m "$CONNECT_TIMEOUT" \
        -w '\n%{http_code}' \
        "${base_url}/rest/ping.view?u=${ND_USER}&t=${TOKEN}&s=${SALT}&v=1.12.0&c=bash&f=json")
    local curl_rc=$?
    if [ $curl_rc -ne 0 ]; then
        echo "FAILED ${label}: curl error ${curl_rc} (unreachable / timed out)."
        return 1
    fi
    http_code=$(echo "$body" | tail -n 1)
    body=$(echo "$body" | sed '$d')
    local status
    status=$(echo "$body" | jq -r '.["subsonic-response"].status // empty' 2>/dev/null)
    if [ "$http_code" != "200" ] || [ -z "$status" ]; then
        echo "FAILED ${label}: HTTP ${http_code}, not a Subsonic response."
        echo "Body: ${body:0:200}"
        return 1
    fi
    if [ "$status" = "ok" ]; then
        echo "OK ${label}: reachable and authenticated."
        return 0
    fi
    local err
    err=$(echo "$body" | jq -r '.["subsonic-response"].error.message // "unknown error"')
    # Auth failure still means the host is the right service - usable for API calls
    # once credentials are fixed; treat as reachable so we don't skip to the next hop.
    echo "OK ${label}: reachable (Subsonic status=${status}: ${err})."
    return 0
}

# Try each configured URL in order; first reachable one wins.
ND_URL=""
ND_LABEL=""
for _url in $ND_URLS; do
    _url="${_url%/}"
    [ -n "$_url" ] || continue
    if probe_navidrome "$_url" "$_url"; then
        ND_URL="$_url"
        ND_LABEL="$_url"
        break
    fi
done
[ -n "$ND_URL" ] || abort "None of the configured Navidrome URLs answered: ${ND_URLS}. Leaving existing music on ${DEVICE_NAME} untouched."

echo "Using Navidrome via ${ND_LABEL}"

make_auth
echo "Fetching ${SONG_COUNT} random songs from Navidrome..."
JSON_RESPONSE=$(curl -sS --connect-timeout "$CONNECT_TIMEOUT" -m 60 \
    "${ND_URL}/rest/getRandomSongs.view?u=${ND_USER}&t=${TOKEN}&s=${SALT}&v=1.12.0&c=bash&f=json&size=${SONG_COUNT}")
curl_rc=$?
if [ $curl_rc -ne 0 ]; then
    abort "getRandomSongs curl failed (rc=${curl_rc}) against ${ND_LABEL}."
fi

API_STATUS=$(echo "$JSON_RESPONSE" | jq -r '.["subsonic-response"].status // empty')
if [ "$API_STATUS" != "ok" ]; then
    API_ERR=$(echo "$JSON_RESPONSE" | jq -r '.["subsonic-response"].error.message // "unknown"')
    abort "getRandomSongs failed on ${ND_LABEL}: status=${API_STATUS:-missing} (${API_ERR})."
fi

SONG_IDS=$(echo "$JSON_RESPONSE" | jq -r '.["subsonic-response"].randomSongs.song[]?.id // empty')
SONG_ID_COUNT=$(echo "$SONG_IDS" | grep -c . || true)
if [ "$SONG_ID_COUNT" -eq 0 ]; then
    abort "getRandomSongs returned zero songs from ${ND_LABEL}. Refusing to create an empty auto-list folder."
fi

echo "Got ${SONG_ID_COUNT} song id(s)."

mkdir -p "$AUTO_DIR"

# Numeric folder names only. A glob avoids `ls | grep`, which mangles names
# containing spaces.
LAST_NUM=0
for _d in "$AUTO_DIR"/*; do
    [ -d "$_d" ] || continue
    _n=${_d##*/}
    case "$_n" in
        ''|*[!0-9]*) continue ;;
    esac
    [ "$_n" -gt "$LAST_NUM" ] && LAST_NUM="$_n"
done
NEXT_NUM=$((LAST_NUM + 1))

NEW_DIR="$AUTO_DIR/$NEXT_NUM"
mkdir -p "$NEW_DIR"
echo "Downloading to $NEW_DIR..."

DOWNLOADED=0
echo "$SONG_IDS" | while IFS= read -r id; do
    if [ -n "$id" ]; then
        PREFIX=$(printf "%04d" $((DOWNLOADED + 1)))

        mkdir -p "$NEW_DIR/temp_dl"
        cd "$NEW_DIR/temp_dl" || exit 1

        DOWNLOAD_URL="${ND_URL}/rest/download.view?id=${id}&u=${ND_USER}&t=${TOKEN}&s=${SALT}&v=1.12.0&c=bash"
        if ! curl -sS --connect-timeout "$CONNECT_TIMEOUT" -m 120 -L -J -O "$DOWNLOAD_URL"; then
            echo "WARN: download failed for id=${id}"
            cd "$NEW_DIR" || exit 1
            rm -rf temp_dl
            continue
        fi

        DOWNLOADED_FILE=$(ls | head -n 1)

        if [ -n "$DOWNLOADED_FILE" ]; then
            mv "$DOWNLOADED_FILE" "../${PREFIX} - ${DOWNLOADED_FILE}"
            DOWNLOADED=$((DOWNLOADED + 1))
        else
            echo "WARN: no file saved for id=${id}"
        fi

        cd "$NEW_DIR" || exit 1
        rm -rf temp_dl
    fi
done

# Subshell above - count files actually present
FILE_COUNT=$(find "$NEW_DIR" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')
echo "Downloaded file count in ${NEW_DIR}: ${FILE_COUNT}"
if [ "$FILE_COUNT" -eq 0 ]; then
    echo "Removing empty folder ${NEW_DIR}"
    rm -rf "$NEW_DIR"
    abort "All downloads failed against ${ND_LABEL}. Existing auto-list folders left intact."
fi

echo "Cleaning up old lists (keeping 2 newest)..."
cd "$AUTO_DIR" || abort "Could not cd to ${AUTO_DIR}"
# Numeric names only, newest two kept. Every entry is validated as digits, so the
# word-split below cannot break on a name containing spaces.
_old=""
for _d in *; do
    [ -d "$_d" ] || continue
    case "$_d" in
        ''|*[!0-9]*) continue ;;
    esac
    _old="$_old $_d"
done
# shellcheck disable=SC2086  # digits-only entries, split on purpose
printf '%s\n' $_old | sort -nr | tail -n +3 | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    echo "Removing $dir"
    rm -rf -- "$dir"
done
cd "$HOME" || true

echo "Syncing and ejecting..."
sync
sleep 2
diskutil eject "$TARGET"
