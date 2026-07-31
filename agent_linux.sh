set -e

SERVER_IP="127.0.0.1"
SERVER_PORT="8080"
INTERVAL_SEC=30
API_ENDPOINT="http://${SERVER_IP}:${SERVER_PORT}/"

collect_payload() {
    {
        echo "=== System Info ==="
        echo "Hostname: $(hostname)"
        echo "User: $(whoami)"
        echo "OS: $(uname -a)"
        echo "IP: $(hostname -I 2>/dev/null | tr -s ' ' ',')"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
    }
}

send_payload() {
    local payload
    payload=$(collect_payload)
    if curl -s -m 10 --data-urlencode "data=${payload}" "$API_ENDPOINT" > /dev/null 2>&1; then
        echo "[+] Sent successfully at $(date '+%H:%M:%S')"
    else
        echo "[!] Failed to reach server at $(date '+%H:%M:%S')"
    fi
}

echo "[*] Agent started. Sending to ${API_ENDPOINT} every ${INTERVAL_SEC}s (Ctrl+C to stop)"
while true; do
    send_payload
    sleep "$INTERVAL_SEC"
done
