#!/bin/bash

# --- PATHS ---
INSTALL_ROOT="$HOME/.one-thing-sync"
WORKER_SCRIPT="$INSTALL_ROOT/worker.sh"
CONFIG_FILE="$INSTALL_ROOT/config.txt"
STATE_FILE="$INSTALL_ROOT/state.txt"
PLIST_PATH="$HOME/Library/LaunchAgents/com.onething.sync.plist"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== One Thing Sync Installer ===${NC}"

# 1. CLEANUP OLD INSTALLATION (preserve config)
echo -e "\n${BLUE}Cleaning up old installation...${NC}"
launchctl unload "$PLIST_PATH" 2>/dev/null
rm -f "$PLIST_PATH"
# Remove old files but keep config.txt
rm -f "$INSTALL_ROOT/worker.sh"
rm -f "$INSTALL_ROOT/worker.mjs"
rm -f "$INSTALL_ROOT/worker.scpt"
rm -f "$INSTALL_ROOT/run-node.sh"
rm -f "$INSTALL_ROOT/onething-runner"
rm -f "$INSTALL_ROOT/onething-node"
rm -f "$INSTALL_ROOT/state.txt"
rm -rf "$INSTALL_ROOT/OneThingSync.app"

# 2. SETUP DIRS
mkdir -p "$INSTALL_ROOT"

# 3. CONFIGURATION
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

# 4. CREATE WORKER SCRIPT
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

# 5. CREATE DEDICATED RUNNER BINARY
# Compile a tiny C program that just executes worker.sh
# This avoids: applet control-key dialog, copying system binaries (gets killed)
echo -e "\n${BLUE}Creating dedicated runner binary...${NC}"
RUNNER_BIN="$INSTALL_ROOT/onething-runner"

cat << 'CCODE' > /tmp/onething-runner.c
#include <unistd.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    execv("/bin/bash", (char *[]){"/bin/bash", argv[1], NULL});
    return 1;
}
CCODE

cc -o "$RUNNER_BIN" /tmp/onething-runner.c
rm /tmp/onething-runner.c
codesign --force --sign - --identifier "com.jpjagt.onething-runner" "$RUNNER_BIN"

# 6. PERMISSION REQUEST
echo -e "\n${YELLOW}=== ACTION REQUIRED ===${NC}"
echo "1. Open System Settings > Privacy & Security > Full Disk Access."
echo "2. Click '+' and navigate to: ~/.one-thing-sync/"
echo "3. Select 'onething-runner' and turn it ON."
echo ""
echo "   (This is a dedicated binary just for this sync tool)"
open "$INSTALL_ROOT"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

echo -e "\n${GREEN}Press ENTER when permissions are set.${NC}"
read -r DUMMY < /dev/tty

# 7. LAUNCH AGENT
RUNNER_BIN="$INSTALL_ROOT/onething-runner"

cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.onething.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RUNNER_BIN</string>
        <string>$WORKER_SCRIPT</string>
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
