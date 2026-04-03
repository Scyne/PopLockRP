# PopLock API

A zero-dependency, single-file Node.js HTTP API for managing the PopLock Minecraft server. Designed to be lightweight and robust, it runs purely on Node's built-in modules and includes a systemd service to survive server reboots.

Read endpoints are entirely public, while write/modification endpoints are secured behind an API key. 

## 🏗️ Architecture: n8n & Discord Integration

This API is designed to act as the secure backend for an **n8n Discord Slash Command flow**:
1. **n8n** stores the secret API key.
2. Discord users trigger slash commands which hit n8n webhooks.
3. n8n validates the user's Discord role and permissions.
4. n8n proxies the authorized request to the PopLock API.
5. **Result:** End-users can manage the server via Discord, but nobody interacts with the server directly.

---

## 🚀 Installation & Setup

### 1. Install the Server Script
Copy the main application file to your system binaries:
```bash
sudo cp poplock-api.js /usr/local/bin/poplock-api.js
```

### 2. Configure the API Key
Set up the configuration file and secure its permissions:
```bash
sudo cp poplock-api.conf /etc/poplock-api.conf
sudo chmod 600 /etc/poplock-api.conf
```

Generate a secure 32-byte hex string for your API key:
```bash
openssl rand -hex 32
```

Open the config file and replace `REPLACE_WITH_YOUR_SECRET_KEY` with the generated string:
```bash
sudo nano /etc/poplock-api.conf
```

### 3. Install and Start the Service
Copy the systemd unit file, reload the daemon, and enable the service to start automatically on boot:
```bash
sudo cp poplock-api.service /etc/systemd/system/poplock-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now poplock-api
sudo systemctl status poplock-api
```

---

## 🗺️ Endpoint Map

Base URL: `http://<your-server-ip>:6767`

### 📖 Read Endpoints (Public)
| Method | Route | Description |
| :--- | :--- | :--- |
| **GET** | `/` | Plain text `servreport` output |
| **GET** | `/api` | Endpoint index and API version |
| **GET** | `/api/status` | Online/offline status, version, uptime, and memory |
| **GET** | `/api/players/online` | List of currently online players |
| **GET** | `/api/players/whitelist` | Full whitelist output |
| **GET** | `/api/logs/latest?lines=200` | Latest server log (adjustable line count) |
| **GET** | `/api/logs/snapshot?lines=200` | Snapshot cron log (adjustable line count) |
| **GET** | `/api/backups` | All backups listed with size and type |
| **GET** | `/api/properties` | `server.properties` returned as JSON |
| **GET** | `/api/report` | `servreport` returned as JSON |

### ✍️ Write Endpoints (Secured)
*Requires the `X-API-Key` header with your configured secret key.*

| Method | Route | Auth | Description |
| :--- | :--- | :---: | :--- |
| **POST** | `/api/server/start` | 🔑 | Start the Minecraft server |
| **POST** | `/api/server/stop` | 🔑 | Stop the Minecraft server |
| **POST** | `/api/server/restart` | 🔑 | Restart the Minecraft server |
| **POST** | `/api/command` | 🔑 | Send any console command (Body: `{"command": "say hello"}`) |
| **POST** | `/api/whitelist/add` | 🔑 | Add player to whitelist (Body: `{"player": "username"}`) |
| **POST** | `/api/whitelist/remove` | 🔑 | Remove player from whitelist (Body: `{"player": "username"}`) |
| **POST** | `/api/backup` | 🔑 | Trigger a silent background backup |
