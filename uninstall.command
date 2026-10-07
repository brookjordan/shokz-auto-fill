#!/bin/bash
#
# Shokz Auto-Fill uninstaller.
#
# Removes the LaunchAgent, the installed script and (optionally) the config.
# It never touches the contents of the device itself.
#
# Double-click or run from a terminal.
set -u

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/common.sh
. ./lib/common.sh

say "=== $APP_NAME uninstaller ==="
say ""

# ------------------------------------------------------------- stop the agent
if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    say "unloaded agent: $LABEL"
else
    say "agent not loaded: $LABEL"
fi
if [ -f "$PLIST_DEST" ]; then
    rm -f "$PLIST_DEST" && say "removed $PLIST_DEST"
fi

# A fill may be mid-run; warn rather than kill it, so a partial folder is not left.
if pgrep -f "auto_fill_shokz.sh" >/dev/null 2>&1; then
    warn "a fill appears to be running. Let it finish, or it may leave a partial folder."
fi

# ------------------------------------------------------- remove installed files
if [ -d "$SUPPORT" ]; then
    printf 'Remove the installed script and logs (%s)? [Y/n]: ' "$SUPPORT"
    read -r ans || true
    case "${ans:-Y}" in
        [Nn]*) say "kept $SUPPORT" ;;
        *)     rm -rf "$SUPPORT" && say "removed $SUPPORT" ;;
    esac
fi

# The config holds the Navidrome password.
if [ -f "$CONFIG" ]; then
    printf 'Remove the config, which contains your Navidrome password (%s)? [y/N]: ' "$CONFIG"
    read -r ans || true
    case "${ans:-N}" in
        [Yy]*) rm -f "$CONFIG"; rmdir "$CONFIG_DIR" 2>/dev/null || true; say "removed $CONFIG" ;;
        *)     say "kept $CONFIG (it contains a credential - delete it manually if you want it gone)" ;;
    esac
fi


say ""
say "=== Done ==="
say ""
say "The removable-volume permission that macOS granted to the interpreter is"
say "NOT removed automatically. Resetting it also clears the grant for every"
say "other app that uses removable volumes, so it is left alone. If you really"
say "want it gone:"
say "    tccutil reset SystemPolicyRemovableVolumes"
say ""
say "Any music already on the device was left untouched."
pause_if_double_clicked
