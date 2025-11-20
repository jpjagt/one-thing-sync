#!/bin/bash
# Use the generated uninstaller if it exists, otherwise clean manually
if [ -f "$HOME/.one-thing-sync/uninstall.sh" ]; then
    "$HOME/.one-thing-sync/uninstall.sh"
else
    echo "Cleaning up..."
    launchctl unload "$HOME/Library/LaunchAgents/com.onething.sync.plist" 2>/dev/null
    rm "$HOME/Library/LaunchAgents/com.onething.sync.plist"
    rm -rf "$HOME/.one-thing-sync"
    echo "Done."
fi
