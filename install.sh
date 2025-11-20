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

echo -e "${BLUE}=== One Thing Sync Installer ===${NC}"

# --- 1. DEPENDENCY CHECK ---
echo "Checking dependencies..."

if ! command -v node &> /dev/null; then
    echo -e "${RED}Error: Node.js is not installed.${NC}"
    echo "Please install Node.js (https://nodejs.org) and try again."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Installing jq (JSON processor)..."
    brew install jq || { echo -e "${RED}Failed to install jq. Do you have Homebrew?${NC}"; exit 1; }
fi

if ! command -v one-thing &> /dev/null; then
    echo "Installing 'one-thing' CLI tool..."
    npm install --global one-thing || { echo -e "${RED}Failed to install npm package.${NC}"; exit 1; }
fi

mkdir -p "$INSTALL_DIR"

# --- 2. CONFIGURATION (Interactive) ---
# We force read from /dev/tty so this works even if the script is piped via curl
echo -e "\n${GREEN}Sync Setup${NC}"

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
        # Create blob and capture the Location header
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

    # Save URL
    echo "$SYNC_URL" > "$URL_FILE"
fi

# --- 3. GENERATE WORKER SCRIPT ---
# We write the script content to the install dir
cat << 'EOF' > "$SYNC_SCRIPT"
#!/bin/bash
INSTALL_DIR="$HOME/.one-thing-sync"
URL_FILE="$INSTALL_DIR/url.txt"
STATE_FILE="$INSTALL_DIR/state.txt"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -f "$URL_FILE" ]; then exit 0; fi
SYNC_URL=$(cat "$URL_FILE")
if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; fi

LOCAL_TEXT=$(one-thing --get 2>/dev/null || echo "")
REMOTE_JSON=$(curl -s "$SYNC_URL")
REMOTE_TEXT=$(echo "$REMOTE_JSON" | jq -r '.text')
LAST_KNOWN=$(cat "$STATE_FILE")

if [ "$REMOTE_TEXT" == "null" ]; then REMOTE_TEXT=""; fi

# Sync Logic
if [ "$LOCAL_TEXT" != "$LAST_KNOWN" ] && [ ! -z "$LOCAL_TEXT" ]; then
    if [ "$LOCAL_TEXT" != "$REMOTE_TEXT" ]; then
        JSON_PAYLOAD=$(jq -n --arg txt "$LOCAL_TEXT" '{text: $txt}')
        curl -s -X PUT -H "Content-Type: application/json" -d "$JSON_PAYLOAD" "$SYNC_URL" > /dev/null
    fi
    echo "$LOCAL_TEXT" > "$STATE_FILE"
elif [ "$REMOTE_TEXT" != "$LAST_KNOWN" ]; then
    one-thing "$REMOTE_TEXT"
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
echo "You are now syncing."
echo "To uninstall, run: $UNINSTALL_SCRIPT"
