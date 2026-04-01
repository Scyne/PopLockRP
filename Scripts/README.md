# PopLock Server Scripts

Management and automation scripts for the PopLock Minecraft server. Designed for a self-hosted Linux environment running PaperMC or Vanilla Minecraft inside a persistent `tmux` session.

---

## Repository Contents

| File | Location on Server | Description |
|---|---|---|
| `serv` | `/usr/local/bin/serv` | Interactive server control CLI |
| `start.sh` | `/usr/local/games/minecraft_server/java/start.sh` | Server startup loop with restart logic |
| `snapshot.sh` | `/usr/local/bin/snapshot.sh` | Automated daily snapshot script (run by cron) |
| `log4j2.xml` | `/usr/local/games/minecraft_server/java/log4j2.xml` | Log4j config to suppress noisy console output |
| `poplock_datapack.zip` | `/usr/local/games/minecraft_server/java/world/datapacks/` | Datapack providing silent server alert sound function |

---

## Prerequisites

The following packages must be installed on the host system:

```bash
sudo apt install tmux jq curl unzip
```

---

## Directory Structure

All server files live under a single root:

```
/usr/local/games/minecraft_server/java/
├── server.jar
├── start.sh
├── log4j2.xml
├── server.properties
├── whitelist.json
├── world/
│   └── datapacks/
│       └── poplock_datapack.zip
└── backups/
    ├── jars/
    ├── snapshot_YYYYMMDD_HHMMSS.tar.gz   ← daily snapshots
    └── minecraft_backup_YYYYMMDD_HHMMSS.tar.gz  ← manual backups
```

---

## Installation

### 1. Create the server directory

```bash
sudo mkdir -p /usr/local/games/minecraft_server/java
sudo chown -R $USER:$USER /usr/local/games/minecraft_server/java
```

### 2. Install `serv`

```bash
sudo cp serv /usr/local/bin/serv
sudo chmod +x /usr/local/bin/serv
```

### 3. Install `snapshot.sh`

```bash
sudo cp snapshot.sh /usr/local/bin/snapshot.sh
sudo chmod +x /usr/local/bin/snapshot.sh
```

### 4. Install `start.sh` and `log4j2.xml`

```bash
cp start.sh /usr/local/games/minecraft_server/java/start.sh
chmod +x /usr/local/games/minecraft_server/java/start.sh

cp log4j2.xml /usr/local/games/minecraft_server/java/log4j2.xml
```

### 5. Place your `server.jar`

Drop your PaperMC or Vanilla `server.jar` into `/usr/local/games/minecraft_server/java/`. It must be named exactly `server.jar`.

To download the latest PaperMC build directly:

```bash
# Replace 1.21.4 and the build number with current values from https://papermc.io/downloads
curl -o /usr/local/games/minecraft_server/java/server.jar \
  "https://api.papermc.io/v2/projects/paper/versions/1.21.4/builds/BUILDNUM/downloads/paper-1.21.4-BUILDNUM.jar"
```

Or use `serv update` after initial setup to pull the latest build automatically.

### 6. Accept the EULA

```bash
echo "eula=true" > /usr/local/games/minecraft_server/java/eula.txt
```

### 7. Install the alert datapack

```bash
sudo wget -O /usr/local/games/minecraft_server/java/world/datapacks/poplock_datapack.zip \
  https://github.com/Scyne/PopLockRP/raw/refs/heads/main/poplock_datapack.zip
```

> **Note:** The `world/datapacks/` directory is created by the server on first run. If installing before the first launch, create it manually:
> ```bash
> mkdir -p /usr/local/games/minecraft_server/java/world/datapacks
> ```

Once the server is running, activate the datapack once from the console:

```
datapack enable "file/poplock_datapack.zip"
```

It will auto-load on every subsequent restart.

---

## Cron Setup — Automated Daily Snapshots

The snapshot script begins a **30-minute in-game countdown** before stopping the server. To have the server go down at midnight, schedule the script to start at **11:30 PM**.

### Open the crontab

```bash
sudo crontab -e
```

### Add the following line

```
30 23 * * * /usr/local/bin/snapshot.sh >> /var/log/minecraft_snapshot.log 2>&1
```

This runs the snapshot script every night at 23:30 (11:30 PM). Output is appended to a log file for review.

### Verify the cron entry

```bash
sudo crontab -l
```

### Check snapshot logs

```bash
tail -f /var/log/minecraft_snapshot.log
```

---

## Snapshot Behavior

When the snapshot runs nightly:

1. If the server is **online**, it begins a countdown with in-game chat warnings and bell alerts at 30m → 15m → 10m → 5m → 1m → 30s → 15s → 5s
2. The server is gracefully stopped (force-killed after 30 seconds if needed)
3. A `.tar.gz` snapshot is saved to `backups/` containing:
   - All world directories (`world`, `world_nether`, `world_the_end`, etc.)
   - `whitelist.json`
   - `server.properties`
4. The server is automatically restarted
5. Snapshots older than **7 days** are deleted automatically

If the server is **offline** when the cron fires, the countdown is skipped and the snapshot is taken immediately.

---

## `serv` Command Reference

```bash
serv start      # Start the server in a background tmux session
serv stop       # Gracefully stop the server
serv restart    # Stop and restart the server
serv console    # Attach to the live server console (Ctrl+B then D to detach)
serv status     # Show online/offline status, version, uptime, memory, and player count
serv backup     # Take a full manual backup (stops and restarts server)
serv backup -s  # Silent backup (no output — useful for scripting)
serv restore    # Interactive restore menu — lists all snapshots, backups, and undo points
serv update     # Check for and apply the latest PaperMC or Vanilla update
serv chk        # Check for available updates without applying them
serv chk -s     # Silent update check (no output if already up to date)
```

---

## Backup & Restore System

There are three types of archives, all stored in `backups/`:

| Type | Filename Pattern | Created By | Contains |
|---|---|---|---|
| Daily Snapshot | `snapshot_YYYYMMDD_HHMMSS.tar.gz` | Cron / `snapshot.sh` | Worlds + whitelist + server.properties |
| Full Backup | `minecraft_backup_YYYYMMDD_HHMMSS.tar.gz` | `serv backup` | Entire server directory |
| Restore Undo | `restore_undo.tar.gz` | `serv restore` | Whatever was replaced in the last restore |

`serv restore` presents an interactive numbered list of all available archives. Selecting one will:

1. Stop the server if running
2. Create an undo backup of whatever is about to be replaced
3. Wipe and cleanly extract the selected archive
4. Remove stale `session.lock` files
5. Restart the server if it was running

To undo a restore, run `serv restore` again and select **Restore Undo**.

---

## Updating the Alert Datapack

If the datapack needs to be updated (e.g. after a Minecraft version bump changes the pack format):

```bash
# Re-download
sudo wget -O /usr/local/games/minecraft_server/java/world/datapacks/poplock_datapack.zip \
  https://github.com/Scyne/PopLockRP/raw/refs/heads/main/poplock_datapack.zip

# Reload without restarting
# Run from serv console:
reload
```

---

## Troubleshooting

**Server fails to start**
```bash
cat /tmp/minecraft_error.log
serv status
```

**Snapshot didn't run**
```bash
sudo crontab -l                          # verify cron entry exists
tail -50 /var/log/minecraft_snapshot.log # check last run output
grep CRON /var/log/syslog | tail -20     # verify cron fired at all
```

**Datapack function not found (`Unknown function poplock:alert`)**

The pack format number in `pack.mcmeta` may not match the server version. Get the correct number by running `version` in the server console, then rebuild the datapack with the matching format number and re-download it.

**tmux socket permission error**
```bash
sudo chmod 770 /tmp/minecraft-tmux
sudo chown $USER:$USER /tmp/minecraft-tmux
```

**Server won't stop gracefully during snapshot**

The snapshot script will force-kill after 30 seconds automatically. If this happens regularly, check available memory — the server may be thrashing under load before the snapshot window.
