#!/bin/bash

# --- PATHS ---
INSTALL_ROOT="$HOME/.one-thing-sync"
WORKER_SCRIPT="$INSTALL_ROOT/worker.sh"
APP_NAME="OneThingSync.app"
APP_PATH="$INSTALL_ROOT/$APP_NAME"
CONFIG_FILE="$INSTALL_ROOT/config.txt"
STATE_FILE="$INSTALL_ROOT/state.txt"
PLIST_PATH="$HOME/Library/LaunchAgents/com.onething.sync.plist"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== One Thing Sync Installer (Signed Applet) ===${NC}"

# 1. SETUP DIRS
mkdir -p "$INSTALL_ROOT"

# 2. CONFIGURATION
if [ -f "$CONFIG_FILE" ]; then
    echo -e "\n${GREEN}Existing configuration found - keeping it.${NC}"
else
    echo -e "\n${GREEN}Configuration${NC}"
    read -p "Bin ID: " -r BIN_ID < /dev/tty
    read -p "Master Key: " -r API_KEY < /dev/tty

    BIN_ID=$(echo "$BIN_ID" | xargs)
    API_KEY=$(echo "$API_KEY" | xargs)

    if [ -z "$BIN_ID" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}Error: Missing credentials.${NC}"
        exit 1
    fi

    echo "$BIN_ID" > "$CONFIG_FILE"
    echo "$API_KEY" >> "$CONFIG_FILE"
fi

# 3. CREATE WORKER SCRIPT
cat << 'EOF' > "$WORKER_SCRIPT"
#!/bin/bash
INSTALL_ROOT="$HOME/.one-thing-sync"
CONFIG_FILE="$INSTALL_ROOT/config.txt"
STATE_FILE="$INSTALL_ROOT/state.txt"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -f "$CONFIG_FILE" ]; then echo "Missing config"; exit 1; fi
BIN_ID=$(sed '1q;d' "$CONFIG_FILE")
API_KEY=$(sed '2q;d' "$CONFIG_FILE")
SYNC_URL="https://api.jsonbin.io/v3/b/$BIN_ID"
if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; fi

get_local_text() {
    # Direct read via plutil (Allowed because parent app has FDA)
    PLIST="$HOME/Library/Containers/com.sindresorhus.One-Thing/Data/Library/Preferences/com.sindresorhus.One-Thing.plist"
    TEXT=$(plutil -extract text raw -o - "$PLIST" 2>/dev/null)
    if [ -z "$TEXT" ]; then
        TEXT=$(defaults read com.sindresorhus.One-Thing text 2>/dev/null)
    fi
    printf "%s" "$TEXT"
}

url_encode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

get_remote_text() {
    curl -s -H "X-Master-Key: $API_KEY" "$SYNC_URL" \
    | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('record', {}).get('text', ''))"
}

create_json_payload() {
    python3 -c "import sys, json; print(json.dumps({'text': sys.argv[1]}))" "$1"
}

echo "[$(date '+%H:%M:%S')] Checking..."
LOCAL_TEXT=$(get_local_text)
REMOTE_TEXT=$(get_remote_text)
LAST_KNOWN=$(cat "$STATE_FILE")

if [ "$REMOTE_TEXT" == "None" ]; then REMOTE_TEXT=""; fi

echo "  L: '$LOCAL_TEXT' | R: '$REMOTE_TEXT'"

if [ "$LOCAL_TEXT" != "$LAST_KNOWN" ] && [ ! -z "$LOCAL_TEXT" ]; then
    if [ "$LOCAL_TEXT" != "$REMOTE_TEXT" ]; then
        echo "  -> Pushing..."
        PAYLOAD=$(create_json_payload "$LOCAL_TEXT")
        curl -s -X PUT -H "Content-Type: application/json" -H "X-Master-Key: $API_KEY" -d "$PAYLOAD" "$SYNC_URL" >/dev/null
    fi
    echo "$LOCAL_TEXT" > "$STATE_FILE"
elif [ "$REMOTE_TEXT" != "$LAST_KNOWN" ]; then
    echo "  -> Pulling..."
    ENCODED=$(url_encode "$REMOTE_TEXT")
    open --background "one-thing:?text=$ENCODED"
    echo "$REMOTE_TEXT" > "$STATE_FILE"
else
    echo "  -> No changes."
fi
EOF
chmod +x "$WORKER_SCRIPT"

# 4. COMPILE APP
echo -e "\n${BLUE}Compiling Applet...${NC}"
# Create a temporary AppleScript file
TEMP_SCRIPT="/tmp/onething_compile.applescript"
cat > "$TEMP_SCRIPT" << 'APPLESCRIPT'
on run
    do shell script "~/.one-thing-sync/worker.sh"
end run
APPLESCRIPT

osacompile -o "$APP_PATH" "$TEMP_SCRIPT"
rm "$TEMP_SCRIPT"

# 5. MODIFY PLIST (Hide from Dock + Set Name)
# This prevents the 'applet' name and dock icon bouncing
INFO_PLIST="$APP_PATH/Contents/Info.plist"
plutil -replace LSUIElement -bool true "$INFO_PLIST"
plutil -replace CFBundleName -string "OneThingSync" "$INFO_PLIST"
plutil -replace CFBundleIdentifier -string "com.jpjagt.onethingsync" "$INFO_PLIST"
plutil -replace LSBackgroundOnly -bool true "$INFO_PLIST"
plutil -replace NSAppleEventsUsageDescription -string "OneThingSync needs to run automation scripts" "$INFO_PLIST"
# Prevent the "Run or Quit" startup screen
plutil -replace NSAppleScriptEnabled -bool false "$INFO_PLIST" 2>/dev/null || plutil -insert NSAppleScriptEnabled -bool false "$INFO_PLIST"
plutil -replace LSEnvironment -json '{"__OSASCRIPT_ENV":"1"}' "$INFO_PLIST" 2>/dev/null || plutil -insert LSEnvironment -json '{"__OSASCRIPT_ENV":"1"}' "$INFO_PLIST"

# 6. FIX APPLET.RSRC PERMISSIONS (Prevents "Run or Quit" dialog)
echo -e "${BLUE}Fixing applet.rsrc permissions...${NC}"
RSRC_FILE="$APP_PATH/Contents/Resources/applet.rsrc"
chmod +x "$RSRC_FILE"

# Set the "spsh" resource bit to 00 (disable startup screen)
# The second byte controls the startup dialog: 01=show, 00=hide
# Find the spsh resource and change byte at offset 1 from 01 to 00
if [ -f "$RSRC_FILE" ]; then
    # Create a hex dump, find spsh, modify the byte, and write back
    xxd -p "$RSRC_FILE" | tr -d '\n' > /tmp/rsrc.hex
    # Replace the startup screen flag pattern (this is a bit hacky but works)
    # Look for the spsh resource signature and change the control byte
    sed -i '' 's/73707368000000010100/73707368000000010000/g' /tmp/rsrc.hex
    xxd -r -p /tmp/rsrc.hex > "$RSRC_FILE"
    rm /tmp/rsrc.hex
fi

# 6.5. CODE SIGNING (The Fix for the 10s Prompt Loop)
echo -e "${BLUE}Signing App...${NC}"
codesign --force --deep --sign - "$APP_PATH"

# 7. PERMISSION REQUEST
echo -e "\n${YELLOW}=== ACTION REQUIRED ===${NC}"
if [ -f "$STATE_FILE" ]; then
    echo -e "${BLUE}The app was re-signed and needs Full Disk Access again.${NC}"
fi
echo "1. Open System Settings > Privacy & Security > Full Disk Access."
echo "2. Remove any existing 'applet' or 'OneThingSync' entries."
echo "3. Drag the new app below into the list and turn it ON."
open "$INSTALL_ROOT"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

echo -e "\n${GREEN}Press ENTER when permissions are set.${NC}"
read -r DUMMY < /dev/tty

# 8. LAUNCH AGENT
APP_BINARY="$APP_PATH/Contents/MacOS/applet"

cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.onething.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BINARY</string>
    </array>
    <key>StartInterval</key>
    <integer>5</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/onething.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/onething.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LaunchOnlyOnce</key>
    <false/>
</dict>
</plist>
EOF

launchctl unload "$PLIST_PATH" 2>/dev/null
launchctl load "$PLIST_PATH"

echo -e "\n${GREEN}Done!${NC}"
