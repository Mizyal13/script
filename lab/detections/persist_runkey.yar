rule Windows_Registry_RunKey_Persistence {
    meta:
        author = "lab"
        description = "Detect write of a binary path into the current-user Run key (run once per boot)"
        os = "windows"

    strings:
        $s1 = "Software\\Microsoft\\Windows\\CurrentVersion\\Run" ascii
        $s2 = "WindowsUpdateChecker" ascii nocase
        $s3 = "\\AppData\\" ascii nocase
        $s4 = "%TEMP%\\" ascii nocase

    condition:
        uint16(0) == 0x5A4D and          // MZ header
        ($s1 and $s2) or                 // Run key + known value name
        ($s1 and ($s3 or $s4))          // Run key + temp/appdata binary
}
