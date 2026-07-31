# C2 Listener - Monitoring Lab Server

Server listener HTTP sederhana untuk monitoring mesin lab. Bisa di-deploy sekali jalan lewat satu perintah `curl | bash`, lalu kirim link pelacak ke mesin lab (Windows/Linux) untuk memantau IP, lokasi, dan data perangkat.

> **Catatan:** Gunakan hanya di lab / lingkungan yang kamu miliki dan punya izin. Jangan dipakai untuk target tanpa persetujuan.

## File

| File | Fungsi |
|---|---|
| `main.sh` | Script utama. Generate `c2_listener.py`, buka port firewall, deteksi IP, start listener. Bisa dijalankan lewat `curl \| bash`. |
| `agent_linux.sh` | Agent untuk mesin lab Linux: kirim info sistem berkala ke server. |
| `agent_windows.ps1` | Agent untuk mesin lab Windows: kirim info sistem berkala ke server. |
| `c2_listener.py` | Listener (dihasilkan otomatis oleh `main.sh`, tidak perlu di-commit). |
| `received_logs/` | Folder penyimpanan hasil log (dihasilkan otomatis). |

## Quick Start

### 1. Push repo ke GitHub

Repo harus **public** (agar bisa di-curl dari server), atau siapkan URL raw yang bisa diakses.

### 2. Deploy di server monitoring (Ubuntu)

Cukup satu perintah di server:

```bash
curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/main.sh | bash
```

Script otomatis melakukan:

1. Cek / install `python3` (via apt-get)
2. Generate `c2_listener.py` dan buat folder `received_logs/`
3. Buka port **8080** di firewall:
   - `ufw allow 8080/tcp` (Ubuntu)
   - `firewall-cmd --add-port=8080/tcp` (firewalld)
   - `iptables -A INPUT -p tcp --dport 8080 -j ACCEPT`
4. Deteksi IP server dan cetak link pelacak
5. Langsung start listener di port 8080

> Jika server adalah VM cloud (AWS/GCP/Azure/DigitalOcean), selain ufw **tetap harus membuka port 8080 di security group** cloud provider-nya.

### 3. Kirim link ke mesin lab Windows

Setelah server jalan, muncul di layar:

```
http://IP_SERVER:8080/?id=NAMA_MESIN_LAB
```

Ganti `NAMA_MESIN_LAB` dengan nama unik mesin. Saat link dibuka di browser mesin lab, server mencatat:

- **IP** dan waktu klik
- **Lokasi** (via ip-api.com untuk IP publik; untuk IP lokal ditulis "Local network")
- **Fingerprint perangkat** (user agent, platform, CPU, RAM, bahasa, timezone, resolusi layar, dsb.)

Semua tersimpan di `received_logs/`:
- `click_<IP>_<waktu>.log` - data klik link
- `<IP>_<waktu>.log` - data/fingerprint yang terkirim

### 4. Monitoring

Di layar server, tiap klik/kirim muncul seperti ini:

```
[+] Link clicked from IP: 192.168.1.20 | Time: 2026-07-31_20-49-47 | ID: win-lab-1
    Path: / | Location: Local network (private IP, cannot be geolocated)
--------------------------------------------------
```

## Agent untuk Mesin Lab

### Linux

1. Edit `SERVER_IP` di baris atas `agent_linux.sh`:

   ```bash
   SERVER_IP="IP_SERVER"
   ```

2. Jalankan:

   ```bash
   bash agent_linux.sh
   ```

### Windows

1. Edit `$ServerIP` di baris atas `agent_windows.ps1`:

   ```powershell
   $ServerIP = "IP_SERVER"
   ```

2. Jalankan di PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File agent_windows.ps1
   ```

### Opsional: sesuaikan interval kirim

- Linux: ubah `INTERVAL_SEC` (detik, default `30`)
- Windows: ubah `$IntervalSec` (detik, default `30`)

## Verifikasi Koneksi

Tes manual dari mesin lab mana pun:

```bash
curl -X POST --data-urlencode "data=tes-dari-lab" http://IP_SERVER:8080/
```

Jika server membalas `ACK` dan muncul di log, koneksi berhasil.

## Menjalankan Ulang Listener

Jika listener berhenti (misal server restart), start lagi tanpa rebuild:

```bash
cd /path/to/folder
python3 -u c2_listener.py
```

## Troubleshooting

| Masalah | Solusi |
|---|---|
| `Address already in use` | Port 8080 dipakai program lain. Matikan dulu atau ubah `PORT=8080` di baris atas `main.sh` dan `c2_listener.py`. |
| Link tidak bisa diakses mesin lab | Pastikan ufw/security group sudah membuka port 8080, dan IP yang dikirim adalah IP LAN server (`hostname -I`). |
| Lokasi selalu "Local network" | Normal jika mesin lab berada di jaringan lokal (IP privat tidak bisa di-geolocate). |
| Setelah edit `main.sh`, perubahan tidak berlaku | `main.sh` menimpa `c2_listener.py` setiap dijalankan. Selalu edit lewat `main.sh`, jangan langsung edit `c2_listener.py`. |

## Disclaimer

Script ini untuk tujuan pendidikan, riset, dan pengujian keamanan di lab sendiri. Penggunaan di luar lingkungan yang kamu miliki dapat melanggar hukum.
