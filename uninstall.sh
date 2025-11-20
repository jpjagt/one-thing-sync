#!/bin/bash
echo "Stopping background service..."
launchctl unload "$HOME/Library/LaunchAgents/com.onething.sync.plist" 2>/dev/null
rm "$HOME/Library/LaunchAgents/com.onething.sync.plist"
rm -rf "$HOME/.one-thing-sync"
echo "One Thing Sync removed."
