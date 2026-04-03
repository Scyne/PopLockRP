#!/usr/bin/env bash
# ─── PopLock API Auto-Installer ───────────────────────────────────────────────
set -euo pipefail

# ─── Root Check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Please run with sudo."
  exit 1
fi

echo ""
echo "=== PopLock API Installer ==="
echo ""

# ─── Dependency Checks ────────────────────────────────────────────────────────

echo "[1/8] Checking dependencies..."

MISSING=()
for cmd in node curl openssl systemctl sed; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: The following required commands are missing:"
  for m in "${MISSING[@]}"; do echo "       - $m"; done
  echo ""
  echo "Install Node.js with:"
  echo "  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -"
  echo "  apt-get install -y nodejs"
  exit 1
fi

NODE_VERSION=$(node --version)
echo "       Node.js found: $NODE_VERSION"

# ─── Resolve Minecraft Directory ──────────────────────────────────────────────

echo "[2/8] Resolving Minecraft directory..."

SERV_SCRIPT="/usr/local/bin/serv"
DEFAULT_DIR="/usr/local/games/minecraft_server/java"

if [[ -f "$SERV_SCRIPT" ]]; then
  EXTRACTED=$(grep -m 1 '^MINECRAFT_DIR=' "$SERV_SCRIPT" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  MC_DIR="${EXTRACTED:-$DEFAULT_DIR}"
  echo "       Found serv script → MINECRAFT_DIR=$MC_DIR"
else
  MC_DIR="$DEFAULT_DIR"
  echo "       serv script not found — using default: $MC_DIR"
fi

if [[ ! -d "$MC_DIR" ]]; then
  echo "ERROR: Minecraft directory does not exist: $MC_DIR"
  echo "       Ensure the server is installed before running this installer."
  exit 1
fi

# ─── Verify Supporting Scripts ────────────────────────────────────────────────

echo "[3/8] Verifying supporting scripts..."

WARN=false
for f in "/usr/local/bin/serv" "/usr/local/bin/servreport.sh" "/usr/local/bin/snapshot.sh"; do
  if [[ ! -f "$f" ]]; then
    echo "  [WARN] $f not found — some API endpoints may not work until it is installed."
    WARN=true
  else
    echo "       OK: $f"
  fi
done

# ─── Determine Service User ───────────────────────────────────────────────────

echo "[4/8] Determining service user..."

MC_OWNER=$(stat -c '%U' "$MC_DIR")
if [[ "$MC_OWNER" == "root" ]]; then
  echo "  [WARN] $MC_DIR is owned by root. The API service will also run as root."
  echo "         Consider chowning the directory to a dedicated user."
  SERVICE_USER="root"
  SERVICE_GROUP="root"
else
  SERVICE_USER="$MC_OWNER"
  SERVICE_GROUP=$(stat -c '%G' "$MC_DIR")
  echo "       Service will run as: $SERVICE_USER:$SERVICE_GROUP"
fi

# ─── Create API Directory & Download Files ────────────────────────────────────

echo "[5/8] Downloading API files..."

API_DIR="$MC_DIR/api"
mkdir -p "$API_DIR"

BASE_URL="https://github.com/Scyne/PopLockRP/raw/refs/heads/main/api"
declare -A FILES=(
  ["poplock-api.js"]="$BASE_URL/poplock-api.js"
  ["poplock-api.conf"]="$BASE_URL/poplock-api.conf"
  ["poplock-api.service"]="$BASE_URL/poplock-api.service"
)

for filename in "${!FILES[@]}"; do
  url="${FILES[$filename]}"
  dest="$API_DIR/$filename"
  echo "       Downloading $filename..."
  if ! curl -fsSL "$url" -o "$dest"; then
    echo "ERROR: Failed to download $filename from $url"
    echo "       Check the URL exists and that this machine has internet access."
    exit 1
  fi
  # Verify the file is non-empty and not an HTML error page
  if [[ ! -s "$dest" ]]; then
    echo "ERROR: Downloaded file is empty: $dest"
    exit 1
  fi
  if grep -qi '<!DOCTYPE html' "$dest" 2>/dev/null; then
    echo "ERROR: Download returned an HTML page instead of the expected file."
    echo "       The GitHub URL may be incorrect or the file may not exist yet."
    echo "       URL: $url"
    rm -f "$dest"
    exit 1
  fi
done

echo "       All files downloaded successfully."

# ─── Patch Paths ──────────────────────────────────────────────────────────────

echo "[6/8] Patching file paths..."

CONF_PATH="$API_DIR/poplock-api.conf"
JS_PATH="$API_DIR/poplock-api.js"
SERVICE_PATH="$API_DIR/poplock-api.service"

# Patch config path in JS (default: /etc/poplock-api.conf)
sed -i "s|/etc/poplock-api.conf|$CONF_PATH|g" "$JS_PATH"

# Patch MINECRAFT_DIR in JS if it differs from the hardcoded default
DEFAULT_MC_PATH="/usr/local/games/minecraft_server/java"
if [[ "$MC_DIR" != "$DEFAULT_MC_PATH" ]]; then
  sed -i "s|$DEFAULT_MC_PATH|$MC_DIR|g" "$JS_PATH"
  echo "       Patched MINECRAFT_DIR → $MC_DIR"
fi

# Patch service file
sed -i "s|/usr/local/bin/poplock-api.js|$JS_PATH|g" "$SERVICE_PATH"
sed -i "s|/etc/poplock-api.conf|$CONF_PATH|g"       "$SERVICE_PATH"
sed -i "s|User=scyne|User=$SERVICE_USER|g"           "$SERVICE_PATH"
sed -i "s|Group=scyne|Group=$SERVICE_GROUP|g"        "$SERVICE_PATH"

echo "       Paths patched."

# ─── Generate & Inject API Key ────────────────────────────────────────────────

echo "[7/8] Generating API key..."

NEW_API_KEY=$(openssl rand -hex 32)
sed -i "s|REPLACE_WITH_YOUR_SECRET_KEY|$NEW_API_KEY|g" "$CONF_PATH"

# Lock down the config so only the service user can read it
chmod 600 "$CONF_PATH"
chown "$SERVICE_USER:$SERVICE_GROUP" "$CONF_PATH"
chown "$SERVICE_USER:$SERVICE_GROUP" "$JS_PATH"

echo "       API key generated and written to $CONF_PATH"

# ─── Systemd Setup ────────────────────────────────────────────────────────────

echo "[8/8] Installing systemd service..."

cp "$SERVICE_PATH" /etc/systemd/system/poplock-api.service
systemctl daemon-reload
systemctl enable poplock-api

# If the service is already running, restart it — otherwise start fresh
if systemctl is-active --quiet poplock-api; then
  systemctl restart poplock-api
else
  systemctl start poplock-api
fi

sleep 2

# ─── Result ───────────────────────────────────────────────────────────────────

echo ""
if systemctl is-active --quiet poplock-api; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         Installation Successful!                     ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  echo "  API directory : $API_DIR"
  echo "  Service       : poplock-api.service (running)"
  echo "  Listening on  : http://0.0.0.0:6767"
  echo ""
  echo "  Your API Key  :"
  echo "  $NEW_API_KEY"
  echo ""
  echo "  Keep this key safe — it controls all write endpoints."
  echo "  It is stored in: $CONF_PATH"
  echo ""
  if [[ "$WARN" == true ]]; then
    echo "  ⚠  One or more supporting scripts were missing at install time."
    echo "     Some API endpoints will return errors until they are in place."
    echo "     Re-run this installer after installing serv, servreport.sh, etc."
    echo ""
  fi
  echo "  Test it:"
  echo "    curl http://localhost:6767/"
  echo "    curl http://localhost:6767/api/status"
  echo ""
  echo "  Logs:"
  echo "    journalctl -u poplock-api -f"
else
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         Installation Failed!                         ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  echo "  The service failed to start. Check the logs:"
  echo "    journalctl -u poplock-api -e --no-pager"
  echo ""
  echo "  Common causes:"
  echo "    - Node.js not found at /usr/bin/node"
  echo "    - $MC_DIR not readable by $SERVICE_USER"
  echo "    - Port 6767 already in use (lsof -i :6767)"
  exit 1
fi
