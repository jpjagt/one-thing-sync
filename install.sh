#!/bin/bash

# Define Paths
INSTALL_DIR="$HOME/.one-thing-sync"
SYNC_SCRIPT="$INSTALL_DIR/sync.sh"
UNINSTALL_SCRIPT="$INSTALL_DIR/uninstall.sh"
URL_FILE="$INSTALL_DIR/url.txt"
STATE_FILE="$INSTALL_DIR/state.txt"
PLIST_PATH="$HOME/Library/LaunchAgents/com.onething.sync.plist"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== One Thing Sync Installer (Native) ===${NC}"

# --- 1. DEPENDENCY CHECK (Just Python3) ---
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is missing (it should be on macOS by default).${NC}"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# --- 2. CONFIGURATION ---
echo -e "\n${GREEN}Sync Setup${NC}"
SKIP_SETUP=false

if [ -f "$URL_FILE" ]; then
    EXISTING_URL=$(cat "$URL_FILE")
    echo "Found existing sync URL: $EXISTING_URL"
    echo "1) Keep existing"
    echo "2) Overwrite/New"
    read -p "Select option: " -r REPLACE_OPT < /dev/tty
    if [[ "$REPLACE_OPT" == "1" ]]; then
        SKIP_SETUP=true
    fi
fi

if [ "$SKIP_SETUP" != "true" ]; then
    echo "1) CREATE a new sync session (Host)"
    echo "2) JOIN an existing session (Paste URL)"
    read -p "Select option (1 or 2): " -r OPTION < /dev/tty

    if [ "$OPTION" == "1" ]; then
        echo "Creating storage bucket..."
        # We use python to parse the JSON response to get the ID/URL cleanly if needed
        # But JSONBlob POST returns the Location header.
        SYNC_URL=$(curl -s -D - -o /dev/null -X POST -H "Content-Type: application/json" -d '{"text": "Sync Active"}' https://jsonblob.com/api/jsonBlob | grep -i "Location:" | awk '{print $2}' | tr -d '\r')

        if [ -z "$SYNC_URL" ]; then
            echo -e "${RED}Error contacting JSONBlob API.${NC}"
            exit 1
        fi

        echo -e "${GREEN}Created!${NC}"
        echo -e "---------------------------------------------------"
        echo -e "YOUR SYNC URL: ${BLUE}$SYNC_URL${NC}"
        echo -e "Send this URL to your friend."
        echo -e "---------------------------------------------------"
        echo "Press enter to continue..."
        read -r DUMMY < /dev/tty
    elif [ "$OPTION" == "2" ]; then
        read -p "Paste the Sync URL here: " -r SYNC_URL < /dev/tty
    else
        echo "Invalid option."
        exit 1
    fi

    # Strip whitespace
    SYNC_URL=$(echo "$SYNC_URL" | xargs)
    echo "$SYNC_URL" > "$URL_FILE"
fi

# --- 3. GENERATE WORKER SCRIPT (Pure Bash + Python3) ---
cat << 'EOF' > "$SYNC_SCRIPT"
#!/bin/bash
INSTALL_DIR="$HOME/.one-thing-sync"
URL_FILE="$INSTALL_DIR/url.txt"
STATE_FILE="$INSTALL_DIR/state.txt"

# Environment setup for standard macOS paths
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -f "$URL_FILE" ]; then exit 0; fi
SYNC_URL=$(cat "$URL_FILE")
if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; fi

# --- HELPER FUNCTIONS (Python 3) ---

# 1. READ LOCAL: defaults read -> python decode unicode
get_local_text() {
    # 'defaults read' might fail if empty, so we capture error
    RAW=$(defaults read com.sindresorhus.One-Thing text 2>/dev/null || echo "")
    # Python script to mimic the JS decodeUnicodeEscapes logic
    python3 -c "import sys; print(sys.argv[1].encode('utf-8').decode('unicode_escape'))" "$RAW"
}

# 2. URL ENCODE
url_encode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# 3. JSON PARSE
get_remote_text() {
    # curl -> python json parse
    curl -s "$1" | python3 -c "import sys, json; print(json.load(sys.stdin).get('text', ''))"
}

# 4. JSON STRINGIFY (For pushing updates)
create_json_payload() {
    python3 -c "import sys, json; print(json.dumps({'text': sys.argv[1]}))" "$1"
}

# --- EXECUTION ---

LOCAL_TEXT=$(get_local_text)
REMOTE_TEXT=$(get_remote_text "$SYNC_URL")
LAST_KNOWN=$(cat "$STATE_FILE")

# Handle possible nulls from empty JSON
if [ "$REMOTE_TEXT" == "None" ]; then REMOTE_TEXT=""; fi

# Debuging (Optional - comment out in prod)
# echo "L: $LOCAL_TEXT | R: $REMOTE_TEXT | Last: $LAST_KNOWN"

# --- SYNC LOGIC ---

# Check if Local changed from Last Known -> Push
if [ "$LOCAL_TEXT" != "$LAST_KNOWN" ] && [ ! -z "$LOCAL_TEXT" ]; then
    # Don't push if it matches remote already (loop prevention)
    if [ "$LOCAL_TEXT" != "$REMOTE_TEXT" ]; then
        PAYLOAD=$(create_json_payload "$LOCAL_TEXT")
        curl -s -X PUT -H "Content-Type: application/json" -d "$PAYLOAD" "$SYNC_URL" > /dev/null
    fi
    echo "$LOCAL_TEXT" > "$STATE_FILE"

# Check if Remote changed from Last Known -> Pull
elif [ "$REMOTE_TEXT" != "$LAST_KNOWN" ]; then
    ENCODED=$(url_encode "$REMOTE_TEXT")
    # Open URL scheme invisibly
    open --background "one-thing:?text=$ENCODED"
    echo "$REMOTE_TEXT" > "$STATE_FILE"
fi
EOF

chmod +x "$SYNC_SCRIPT"

# --- 4. GENERATE UNINSTALLER ---
cat << EOF > "$UNINSTALL_SCRIPT"
#!/bin/bash
echo "Stopping background service..."
launchctl unload "$PLIST_PATH" 2>/dev/null
rm "$PLIST_PATH"
rm -rf "$INSTALL_DIR"
echo "One Thing Sync removed."
EOF
chmod +x "$UNINSTALL_SCRIPT"

# --- 5. REGISTER LAUNCH AGENT ---
cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.onething.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SYNC_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>5</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

# Reload Agent
launchctl unload "$PLIST_PATH" 2>/dev/null
launchctl load "$PLIST_PATH"

echo -e "\n${GREEN}Installation Complete!${NC}"
echo "Sync is running in the background."
echo "To uninstall, run: $UNINSTALL_SCRIPT"
