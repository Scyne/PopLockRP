#!/bin/bash

# Flag to control the loop
keep_running=true

# Function to handle shutdown signal
function handle_shutdown() {
    echo "Shutdown signal received. Server will not restart after stopping."
    keep_running=false
}

# Trap SIGINT (Ctrl+C) and SIGTERM signals
trap handle_shutdown SIGINT SIGTERM

echo "Server starting... Press CTRL+C once to stop after current session."
echo "Press CTRL+C twice in quick succession to force immediate shutdown."

while $keep_running; do
    # Check for stop signal file
    if [ -f "stop_signal" ]; then
        echo "Stop signal file detected. Server will not restart after stopping."
        keep_running=false
        rm -f stop_signal
    fi

    java -Xmx3072M -Xms2048M -XX:+UseG1GC -XX:MaxGCPauseMillis=50 \
        -Dlog4j.configurationFile=log4j2.xml \
        -jar $SERVER_JAR nogui

    # Check again after server stops
    if [ -f "stop_signal" ]; then
        echo "Stop signal file detected. Server will not restart."
        keep_running=false
        rm -f stop_signal
    fi

    if $keep_running; then
        echo "Server restarting in 5 seconds..."
        echo "Press CTRL+C to prevent restart."
        sleep 5
        # Check one more time before restarting
        if [ -f "stop_signal" ]; then
            echo "Stop signal file detected. Server will not restart."
            keep_running=false
            rm -f stop_signal
        fi
    fi
done

echo "Server shutdown complete."

