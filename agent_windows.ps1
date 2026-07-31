$ServerIP = "127.0.0.1"
$ServerPort = "8080"
$IntervalSec = 30
$Endpoint = "http://${ServerIP}:${ServerPort}/"

function Get-Payload {
    $os = Get-CimInstance Win32_OperatingSystem
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress
    $payload = @"
=== System Info ===
Hostname: $env:COMPUTERNAME
User: $env:USERNAME
OS: $($os.Caption) $($os.Version)
IP: $ip
Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
    return $payload
}

function Send-Payload {
    $payload = Get-Payload
    try {
        Invoke-WebRequest -Uri $Endpoint -Method Post -Body @{ data = $payload } -UseBasicParsing -TimeoutSec 10 | Out-Null
        Write-Host "[+] Sent successfully at $(Get-Date -Format 'HH:mm:ss')"
    } catch {
        Write-Host "[!] Failed to reach server at $(Get-Date -Format 'HH:mm:ss')"
    }
}

Write-Host "[*] Agent started. Sending to $Endpoint every ${IntervalSec}s (Ctrl+C to stop)"
while ($true) {
    Send-Payload
    Start-Sleep -Seconds $IntervalSec
}
