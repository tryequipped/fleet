# Equipped Agent: Migration & Operations Guide

## Overview

The Equipped Agent is a rebranded fork of Fleet's Orbit agent. It connects to the same Fleet server using the same protocol, but installs under `/opt/equipped/` with its own LaunchDaemon identity (`com.equipped.agent`).

## What Changes vs Stock fleetd

| Item | Stock fleetd | Equipped Agent |
|---|---|---|
| Install path | `/opt/orbit/` | `/opt/equipped/` |
| LaunchDaemon | `com.fleetdm.orbit` | `com.equipped.agent` |
| Plist | `/Library/LaunchDaemons/com.fleetdm.orbit.plist` | `/Library/LaunchDaemons/com.equipped.agent.plist` |
| Logs | `/var/log/orbit/` | `/var/log/equipped/` |
| Service name | `Fleet osquery` | `Equipped Agent` |
| Keychain entry | `com.fleetdm.fleetd.enroll.secret` | `com.equipped.agent.enroll.secret` |
| Auto-updates | TUF from updates.fleetdm.com | Disabled (Phase 1) |
| Fleet Desktop | Enabled | Disabled (Phase 1) |

## What Stays the Same

- Fleet server protocol (all `/api/fleet/orbit/*` endpoints)
- `ORBIT_*` environment variable names
- `orbit_info` osquery table name
- osquery TLS enrollment protocol
- Host identity (hardware UUID, node key, osquery DB)

## Migration from Stock fleetd

### Prerequisites

1. Build the equipped-agent binary:
   ```bash
   go build -o /tmp/equipped-agent \
     -ldflags "-X github.com/fleetdm/fleet/v4/orbit/pkg/build.Version=1.0.0-equipped" \
     ./orbit/cmd/orbit/
   ```

2. Verify it built correctly:
   ```bash
   /tmp/equipped-agent version
   # Should show: orbit 1.0.0-equipped
   ```

### Run Migration

```bash
sudo ./orbit/scripts/migrate-to-equipped.sh --equipped-binary /tmp/equipped-agent
```

The script:
1. Backs up all state to `/opt/orbit-backup-YYYYMMDD-HHMMSS/`
2. Stops stock fleetd
3. Copies state (secrets, node key, osquery DB, certs) to `/opt/equipped/`
4. Copies osqueryd binary tree to `/opt/equipped/bin/osqueryd/`
5. Installs equipped-agent binary
6. Installs `com.equipped.agent` LaunchDaemon plist
7. Starts the agent

### Verify Migration

```bash
# Agent should be running
sudo launchctl print system/com.equipped.agent | head -10

# Logs should show successful Fleet connection
sudo tail -20 /var/log/equipped/orbit.stderr.log

# Check version
/opt/equipped/bin/orbit/orbit version

# In Fleet UI: host should show equipped-agent version
```

**Expected log output on success:**
```
INF trying to read fleet-url and enroll-secret from a configuration profile
INF found configuration values in system profile
INF running with auto updates disabled
INF Found osquery version: 5.x.x
INF orbitClient.GetServerCapabilities() map[...]
INF start osqueryd cmd="..."
```

### Rollback

```bash
sudo ./orbit/scripts/rollback-to-fleetd.sh
```

The script:
1. Stops Equipped Agent
2. Removes `com.equipped.agent` plist
3. Verifies stock fleetd plist still exists
4. Starts stock fleetd

After rollback, clean up:
```bash
sudo rm -rf /opt/equipped /var/log/equipped
```

## Troubleshooting

### View Logs

```bash
# Live log stream
sudo tail -f /var/log/equipped/orbit.stderr.log

# Check if agent is running
sudo launchctl print system/com.equipped.agent

# Check osqueryd process
ps aux | grep osqueryd
```

### Common Issues

**"path does not exist" for osqueryd:**
The osqueryd binary tree wasn't copied. Fix:
```bash
sudo cp -rp /opt/orbit/bin/osqueryd /opt/equipped/bin/
sudo launchctl bootout system/com.equipped.agent
sudo launchctl bootstrap system /Library/LaunchDaemons/com.equipped.agent.plist
```

**"EscrowBuddyRunner: received nil UpdateRunner":**
Benign info message. Updates are disabled (Phase 1), so disk encryption escrow features that depend on the updater are skipped.

**Agent keeps restarting (exit code 1):**
Check stderr log for the actual error. Common causes:
- Missing osqueryd binary
- Permissions on `/opt/equipped/` files
- osquery DB corruption (try removing `/opt/equipped/osquery.db/` — it will re-enroll)

**Host appears as new in Fleet after migration:**
The osquery DB wasn't copied. The DB contains the host's enrollment identity. Without it, the host re-enrolls as a new device.

### Remote Troubleshooting

From the Fleet server, you can check host status:
```sql
-- Run as live query in Fleet UI
SELECT * FROM orbit_info;
SELECT * FROM osquery_info;
SELECT computer_name, hardware_serial FROM system_info;
```

### File Locations Reference

```
/opt/equipped/
├── bin/
│   ├── orbit/orbit          # The equipped-agent binary
│   └── osqueryd/             # osqueryd binary tree (copied from stock)
├── secret.txt                # Enroll secret
├── secret-orbit-node-key.txt # Orbit node key (host identity)
├── hardware-uuid.txt         # Hardware UUID
├── fleet_url.txt             # Fleet server URL (if set by profile)
├── certs.pem                 # TLS certificates
├── osquery.flags             # osquery flags
├── osquery.db/               # osquery database (host identity)
├── osquery_log/              # osquery result logs
├── identifier                # Fleet Desktop token
├── lenses/                   # Augeas lenses for osquery
└── orbit-osquery.em          # osquery extension socket

/var/log/equipped/
├── orbit.stderr.log          # Agent stderr (main log)
└── orbit.stdout.log          # Agent stdout

/Library/LaunchDaemons/
└── com.equipped.agent.plist  # LaunchDaemon definition
```
