# The PopLock Resource Repo

This repository contains the server visuals and management scripts used to run the PopLock server.

---

## Resource Pack

### Manual Installation (Java Edition)

1. Download the resource pack ZIP file from this repository
2. Open Minecraft
3. From the main menu, click "Options"
4. Select "Resource Packs"
5. Click "Open Pack Folder" in the bottom left corner
6. Drag and drop the downloaded ZIP file into this folder
7. Return to the Resource Packs menu in Minecraft
8. Find the resource pack in the "Available" section
9. Hover over it and click the arrow that appears to move it to the "Selected" section
10. Click "Done" to apply the resource pack

### Compatibility

This resource pack is designed for Minecraft 26.1. Using it with other versions may result in missing textures or visual glitches.

### Features

- Custom textures for blocks and items
- Enhanced visual effects
- Redesigned user interface elements
- Improved environmental aesthetics

### Screenshots

[Screenshots will be added here]

### Credits

Created by Polymathema

---

## Server Scripts

The `/scripts` folder contains the full management and automation stack for the PopLock server. Designed for a self-hosted Linux environment running PaperMC or Vanilla Minecraft inside a persistent `tmux` session.

See [`/scripts/README.md`](scripts/README.md) for full setup and usage documentation.

### Scripts Overview

| File | Description |
|---|---|
| `serv` | Interactive server control CLI — start, stop, backup, restore, update, and more |
| `start.sh` | Server startup loop with automatic restart and graceful shutdown logic |
| `snapshot.sh` | Automated daily snapshot script intended to be run by cron at 11:30 PM |
| `log4j2.xml` | Log4j config to suppress noisy console output from server commands |

### Quick Reference

```bash
serv start      # Start the server
serv stop       # Stop the server
serv restart    # Restart the server
serv console    # Attach to the live server console (Ctrl+B then D to detach)
serv status     # Show status, version, uptime, memory, and player count
serv backup     # Take a full manual backup
serv restore    # Interactive restore menu for snapshots and backups
serv update     # Check for and apply the latest PaperMC or Vanilla update
serv chk        # Check for available updates without applying
```

### Daily Snapshot Cron

The snapshot script starts a 30-minute in-game countdown before taking the server down, so it should be scheduled at **11:30 PM** to bring the server down at midnight:

```
30 23 * * * /usr/local/bin/snapshot.sh >> /var/log/minecraft_snapshot.log 2>&1
```

---

## Server API

The repository also includes a lightweight, zero-dependency Node.js REST API (`poplock-api.js`) for remote server management. Included in the project are the main application file, a systemd service file (`poplock-api.service`), and a configuration file (`poplock-api.conf`) to ensure it runs persistently and securely.

**Key Features:**
* **Read Endpoints (Public):** Check server status, list online players, read server logs, and view available backups.
* **Write Endpoints (Secured):** Start, stop, and restart the server, run console commands, manage the whitelist, and trigger silent backups. Write actions are protected by a required `X-API-Key` header.
* **Integration Ready:** Designed to act as a secure backend for automation platforms like n8n, allowing you to build flows (such as Discord slash commands) where authorized users can manage the server without needing direct SSH access.
