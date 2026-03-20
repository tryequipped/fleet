#!/bin/bash
# migrate-to-equipped.sh — Migrate from stock fleetd to Equipped Agent
#
# This script:
# 1. Backs up the current fleetd state
# 2. Stops the stock fleetd LaunchDaemon
# 3. Copies state (secrets, node key, osquery DB, certs) to /opt/equipped/
# 4. Installs the equipped-agent binary
# 5. Installs the com.equipped.agent LaunchDaemon
# 6. Starts the Equipped Agent
#
# Prerequisites:
#   - Must run as root (sudo)
#   - equipped-agent binary must exist at EQUIPPED_BINARY path
#   - Stock fleetd must be currently installed at /opt/orbit/
#
# Usage:
#   sudo ./migrate-to-equipped.sh [--equipped-binary /path/to/equipped-agent]
#
# Rollback:
#   sudo ./rollback-to-fleetd.sh
#
set -euo pipefail

# --- Configuration ---
EQUIPPED_BINARY="${EQUIPPED_BINARY:-/tmp/equipped-agent}"
OLD_ROOT="/opt/orbit"
NEW_ROOT="/opt/equipped"
OLD_LABEL="com.fleetdm.orbit"
NEW_LABEL="com.equipped.agent"
OLD_PLIST="/Library/LaunchDaemons/${OLD_LABEL}.plist"
NEW_PLIST="/Library/LaunchDaemons/${NEW_LABEL}.plist"
BACKUP_DIR="/opt/orbit-backup-$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/equipped"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --equipped-binary) EQUIPPED_BINARY="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Preflight checks ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must run as root. Use: sudo $0"
  exit 1
fi

if [[ ! -f "$EQUIPPED_BINARY" ]]; then
  echo "ERROR: Equipped agent binary not found at: $EQUIPPED_BINARY"
  echo "Build it first: go build -o /tmp/equipped-agent ./orbit/cmd/orbit/"
  exit 1
fi

if [[ ! -d "$OLD_ROOT" ]]; then
  echo "ERROR: Stock fleetd not found at $OLD_ROOT"
  exit 1
fi

echo "=== Equipped Agent Migration ==="
echo "Binary:     $EQUIPPED_BINARY"
echo "Old root:   $OLD_ROOT"
echo "New root:   $NEW_ROOT"
echo "Backup dir: $BACKUP_DIR"
echo ""

# --- Step 1: Backup current state ---
echo "[1/6] Backing up current fleetd state to $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
# Copy critical state files (not the full TUF cache)
for f in secret.txt secret-orbit-node-key.txt hardware-uuid.txt fleet_url.txt \
         certs.pem osquery.flags identifier server-overrides.json \
         fleet_client.crt fleet_client.key; do
  if [[ -f "$OLD_ROOT/$f" ]]; then
    cp -p "$OLD_ROOT/$f" "$BACKUP_DIR/"
    echo "  Backed up: $f"
  fi
done
# Backup osquery DB (needed for host identity continuity)
if [[ -d "$OLD_ROOT/osquery.db" ]]; then
  cp -rp "$OLD_ROOT/osquery.db" "$BACKUP_DIR/"
  echo "  Backed up: osquery.db/"
fi
# Note: osqueryd binaries at /opt/orbit/bin/osqueryd/ are not backed up
# (they're large and unchanged). The migration copies them to /opt/equipped/bin/.
# Backup the old plist
if [[ -f "$OLD_PLIST" ]]; then
  cp -p "$OLD_PLIST" "$BACKUP_DIR/"
  echo "  Backed up: $(basename "$OLD_PLIST")"
fi
echo "  Backup complete."

# --- Step 2: Stop stock fleetd ---
echo "[2/6] Stopping stock fleetd ($OLD_LABEL)..."
if launchctl print "system/$OLD_LABEL" &>/dev/null; then
  launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
  sleep 2
  echo "  Stopped."
else
  echo "  Not running (already stopped)."
fi

# --- Step 3: Create new directory structure + copy state ---
echo "[3/6] Setting up $NEW_ROOT and copying state..."
mkdir -p "$NEW_ROOT/bin/orbit"
mkdir -p "$LOG_DIR"

# Copy state files from old root (preserving permissions)
for f in secret.txt secret-orbit-node-key.txt hardware-uuid.txt fleet_url.txt \
         certs.pem osquery.flags identifier server-overrides.json \
         fleet_client.crt fleet_client.key; do
  if [[ -f "$OLD_ROOT/$f" ]]; then
    cp -p "$OLD_ROOT/$f" "$NEW_ROOT/"
  fi
done
# Copy osquery DB for host identity continuity
if [[ -d "$OLD_ROOT/osquery.db" ]]; then
  cp -rp "$OLD_ROOT/osquery.db" "$NEW_ROOT/"
  echo "  Copied osquery.db (host identity preserved)"
fi
# Copy osqueryd binary tree (the agent needs osqueryd to function)
if [[ -d "$OLD_ROOT/bin/osqueryd" ]]; then
  cp -rp "$OLD_ROOT/bin/osqueryd" "$NEW_ROOT/bin/"
  echo "  Copied osqueryd binary tree"
fi
# Copy desktop binary tree if present
if [[ -d "$OLD_ROOT/bin/desktop" ]]; then
  cp -rp "$OLD_ROOT/bin/desktop" "$NEW_ROOT/bin/"
  echo "  Copied desktop binary tree"
fi
# Copy lenses if present (osquery table definitions)
if [[ -d "$OLD_ROOT/lenses" ]]; then
  cp -rp "$OLD_ROOT/lenses" "$NEW_ROOT/"
fi
# Copy staging dir if present
if [[ -d "$OLD_ROOT/staging" ]]; then
  cp -rp "$OLD_ROOT/staging" "$NEW_ROOT/"
fi

# --- Step 4: Install equipped-agent binary ---
echo "[4/6] Installing equipped-agent binary..."
cp "$EQUIPPED_BINARY" "$NEW_ROOT/bin/orbit/orbit"
chmod 755 "$NEW_ROOT/bin/orbit/orbit"
# Create symlink so the binary path matches what the plist expects
ln -sf "$NEW_ROOT/bin/orbit/orbit" "$NEW_ROOT/bin/orbit/equipped-agent"
echo "  Installed at $NEW_ROOT/bin/orbit/orbit"
echo "  Version: $($NEW_ROOT/bin/orbit/orbit version 2>/dev/null || echo 'unknown')"

# --- Step 5: Install LaunchDaemon plist ---
echo "[5/6] Installing LaunchDaemon ($NEW_LABEL)..."

# Read fleet URL from the old config (try fleet_url.txt, then old plist)
FLEET_URL=""
if [[ -f "$NEW_ROOT/fleet_url.txt" ]]; then
  FLEET_URL=$(cat "$NEW_ROOT/fleet_url.txt" | tr -d '[:space:]')
fi
if [[ -z "$FLEET_URL" ]] && [[ -f "$OLD_PLIST" ]]; then
  FLEET_URL=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:ORBIT_FLEET_URL" "$OLD_PLIST" 2>/dev/null || true)
fi

cat > "$NEW_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>ORBIT_DISABLE_UPDATES</key>
		<string>true</string>
		<key>ORBIT_FLEET_DESKTOP</key>
		<string>false</string>
		<key>ORBIT_USE_SYSTEM_CONFIGURATION</key>
		<string>true</string>
		<key>ORBIT_ORBIT_CHANNEL</key>
		<string>stable</string>
		<key>ORBIT_OSQUERYD_CHANNEL</key>
		<string>stable</string>
		<key>ORBIT_UPDATE_INTERVAL</key>
		<string>15m0s</string>
	</dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.equipped.agent</string>
	<key>ProgramArguments</key>
	<array>
		<string>/opt/equipped/bin/orbit/orbit</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/var/log/equipped/orbit.stderr.log</string>
	<key>StandardOutPath</key>
	<string>/var/log/equipped/orbit.stdout.log</string>
	<key>ThrottleInterval</key>
	<integer>10</integer>
</dict>
</plist>
PLIST
chmod 644 "$NEW_PLIST"
echo "  Installed plist at $NEW_PLIST"

# --- Step 6: Start the agent ---
echo "[6/6] Starting Equipped Agent..."
launchctl bootstrap system "$NEW_PLIST"
launchctl kickstart "system/$NEW_LABEL"
sleep 3

# --- Verify ---
echo ""
echo "=== Verification ==="
if launchctl print "system/$NEW_LABEL" &>/dev/null; then
  STATE=$(launchctl print "system/$NEW_LABEL" 2>/dev/null | grep "state =" | awk '{print $3}')
  echo "Service state: $STATE"
else
  echo "WARNING: Service not found. Check: sudo launchctl print system/$NEW_LABEL"
fi

if [[ -f "$LOG_DIR/orbit.stderr.log" ]]; then
  LINES=$(wc -l < "$LOG_DIR/orbit.stderr.log" 2>/dev/null || echo 0)
  echo "Stderr log: $LOG_DIR/orbit.stderr.log ($LINES lines)"
  echo "Last 5 lines:"
  tail -5 "$LOG_DIR/orbit.stderr.log" 2>/dev/null || true
fi

echo ""
echo "=== Migration Complete ==="
echo ""
echo "Useful commands:"
echo "  Check status:    sudo launchctl print system/$NEW_LABEL"
echo "  View logs:       sudo tail -f $LOG_DIR/orbit.stderr.log"
echo "  Agent version:   $NEW_ROOT/bin/orbit/orbit version"
echo "  Rollback:        sudo ./orbit/scripts/rollback-to-fleetd.sh"
echo ""
echo "Backup saved at: $BACKUP_DIR"
