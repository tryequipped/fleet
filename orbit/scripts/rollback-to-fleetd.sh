#!/bin/bash
# rollback-to-fleetd.sh — Roll back from Equipped Agent to stock fleetd
#
# This script:
# 1. Stops the Equipped Agent
# 2. Removes the com.equipped.agent LaunchDaemon
# 3. Re-enables the stock com.fleetdm.orbit LaunchDaemon
# 4. Starts stock fleetd
#
# The original /opt/orbit/ is left untouched by migration,
# so rollback simply restarts the old service.
#
# Usage:
#   sudo ./rollback-to-fleetd.sh
#
set -euo pipefail

OLD_LABEL="com.fleetdm.orbit"
NEW_LABEL="com.equipped.agent"
OLD_PLIST="/Library/LaunchDaemons/${OLD_LABEL}.plist"
NEW_PLIST="/Library/LaunchDaemons/${NEW_LABEL}.plist"

# --- Preflight ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must run as root. Use: sudo $0"
  exit 1
fi

echo "=== Rollback to Stock fleetd ==="

# --- Step 1: Stop Equipped Agent ---
echo "[1/4] Stopping Equipped Agent ($NEW_LABEL)..."
if launchctl print "system/$NEW_LABEL" &>/dev/null; then
  launchctl bootout "system/$NEW_LABEL" 2>/dev/null || true
  sleep 2
  echo "  Stopped."
else
  echo "  Not running."
fi

# --- Step 2: Remove Equipped plist ---
echo "[2/4] Removing Equipped LaunchDaemon..."
if [[ -f "$NEW_PLIST" ]]; then
  rm "$NEW_PLIST"
  echo "  Removed $NEW_PLIST"
else
  echo "  Plist not found (already removed)."
fi

# --- Step 3: Verify old plist exists ---
echo "[3/4] Checking stock fleetd plist..."
if [[ ! -f "$OLD_PLIST" ]]; then
  echo "ERROR: Stock fleetd plist not found at $OLD_PLIST"
  echo "Cannot rollback — the original plist may have been removed."
  echo "Check the backup directory for a copy."
  exit 1
fi
echo "  Found $OLD_PLIST"

# --- Step 4: Start stock fleetd ---
echo "[4/4] Starting stock fleetd ($OLD_LABEL)..."
launchctl bootstrap system "$OLD_PLIST"
launchctl kickstart "system/$OLD_LABEL"
sleep 3

# --- Verify ---
echo ""
echo "=== Verification ==="
if launchctl print "system/$OLD_LABEL" &>/dev/null; then
  STATE=$(launchctl print "system/$OLD_LABEL" 2>/dev/null | grep "state =" | awk '{print $3}')
  echo "Service state: $STATE"
  echo "Orbit version: $(/opt/orbit/bin/orbit/orbit version 2>/dev/null || echo 'unknown')"
else
  echo "WARNING: Service not found. Check: sudo launchctl print system/$OLD_LABEL"
fi

echo ""
echo "=== Rollback Complete ==="
echo ""
echo "Stock fleetd is running. /opt/equipped/ can be safely removed:"
echo "  sudo rm -rf /opt/equipped /var/log/equipped"
echo ""
echo "Useful commands:"
echo "  Check status:    sudo launchctl print system/$OLD_LABEL"
echo "  View logs:       sudo tail -f /var/log/orbit/orbit.stderr.log"
