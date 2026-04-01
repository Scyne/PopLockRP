#!/bin/bash

# ─── Environment & Variables ─────────────────────────────────────────────────
# Set PATH to ensure cron can find commands like tmux, pgrep, tar, and find
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SERV_SCRIPT="/usr/local/bin/serv"

if [ ! -f "$SERV_SCRIPT" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Cannot find $SERV_SCRIPT to load variables!"
  exit 1
fi

# Safely extract and evaluate just the variables from the top of the serv script
# (Ensure MINECRAFT_DIR in serv is set to the absolute path: /usr/local/games/minecraft_server/java)
eval "$(grep -E '^(MINECRAFT_DIR|ARCHIVE_DIR|SESSION_NAME|TMUX_SOCKET|SERVER_JAR)=' "$SERV_SCRIPT")"

# ─── Helper Functions ────────────────────────────────────────────────────────

# Sends a message and an audible alert to the in-game chat.
# The sound is played via a datapack function to suppress per-player feedback messages.
send_broadcast() {
  local message="$1"
  if pgrep -f "java.*-jar $SERVER_JAR" > /dev/null; then
    # Play the alert sound via datapack function (silent — no feedback message to players)
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" C-u "function poplock:alert" Enter
    sleep 0.3

    # Send the text broadcast
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" C-u "say §e[Server] $message" Enter

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Broadcasted: $message"
  fi
}

# ─── Countdown & Stop Logic ──────────────────────────────────────────────────

was_running=false

# If the server is running, initiate the countdown sequence
if pgrep -f "java.*-jar $SERVER_JAR" > /dev/null; then
  was_running=true
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Server is online. Starting 30-minute snapshot countdown."

  send_broadcast "The server will go down for a daily snapshot in 30 minutes."
  sleep 15m

  send_broadcast "The server will go down for a daily snapshot in 15 minutes."
  sleep 5m

  send_broadcast "The server will go down for a daily snapshot in 10 minutes."
  sleep 5m

  send_broadcast "The server will go down for a daily snapshot in 5 minutes."
  sleep 4m

  send_broadcast "The server will go down for a daily snapshot in 1 minute!"
  sleep 1m

  send_broadcast "Server going down for snapshot in 30 seconds! Please log off now."
  sleep 15

  send_broadcast "Server going down for snapshot in 15 seconds!"
  sleep 10

  send_broadcast "Server going down for snapshot in 5 seconds!"
  sleep 5

  send_broadcast "Saving world states and stopping server for snapshot..."

  # Send stop command and wait for graceful shutdown
  tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" C-u "stop" Enter

  for i in $(seq 1 30); do
    sleep 1
    if ! pgrep -f "java.*-jar $SERVER_JAR" > /dev/null; then
      break
    fi
  done

  # Force kill if it hung during shutdown
  if pgrep -f "java.*-jar $SERVER_JAR" > /dev/null; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Server didn't stop gracefully. Force killing..."
    pkill -f "java.*-jar $SERVER_JAR" || true
  fi

  tmux -S "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Server is offline. Skipping countdown and proceeding to snapshot."
fi

# ─── Snapshot Creation ───────────────────────────────────────────────────────

timestamp=$(date +"%Y%m%d_%H%M%S")
mkdir -p "$ARCHIVE_DIR"
snapshot_file="$ARCHIVE_DIR/snapshot_$timestamp.tar.gz"

cd "$MINECRAFT_DIR" || exit 1

# Gather target files and folders (captures world, world_nether, world_the_end, etc.)
targets=()
for w in world*; do
  [ -e "$w" ] && targets+=("$w")
done
[ -f "whitelist.json" ] && targets+=("whitelist.json")
[ -f "server.properties" ] && targets+=("server.properties")

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Creating snapshot: $snapshot_file"

# Create the tarball with only the specific targets
if [ ${#targets[@]} -gt 0 ]; then
  tar -czf "$snapshot_file" "${targets[@]}"
  if [ $? -eq 0 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Snapshot successfully saved."
  else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Snapshot failed!"
  fi
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: No target files found to snapshot."
fi

# ─── Restart Server ──────────────────────────────────────────────────────────

if [ "$was_running" = true ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restarting server..."
  # Changed ./start.sh to the absolute path $MINECRAFT_DIR/start.sh to prevent cron execution errors
  tmux -S "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$MINECRAFT_DIR" \
    "cd $MINECRAFT_DIR && export SERVER_JAR=$SERVER_JAR && bash $MINECRAFT_DIR/start.sh 2>/tmp/minecraft_error.log"
  chmod 770 "$TMUX_SOCKET"
fi

# ─── Rolling History Cleanup ─────────────────────────────────────────────────

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Cleaning up snapshots older than 7 days..."

# Find files matching the snapshot naming convention older than 7 days and delete them
find "$ARCHIVE_DIR" -name "snapshot_*.tar.gz" -type f -mtime +7 -exec rm -f {} \;

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Daily snapshot routine complete."

