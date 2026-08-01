rule Http_Beaconing_Strings {
    meta:
        author = "lab"
        description = "Common client strings for a polling C2 agent (URL pattern, user-agent, JSON command keys)"
        os = "windows"

    strings:
        $ua = "Mozilla/5.0" ascii
        $q1 = "/cmd?id=" ascii
        $q2 = "/result" ascii
        $poll = "POST /?id=" ascii
        $json = "machine=" ascii
        $b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" ascii

    condition:
        uint16(0) == 0x5A4D and 2 of them
}
