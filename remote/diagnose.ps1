# Pstsc: RemoteApp diagnostics. Run on the remote PC in an administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File diagnose.ps1
# Writes pstsc-diagnose.txt to the Pstsc shared folder (\\tsclient\pstsc) when connected
# through Pstsc desktop mode, otherwise to this PC's desktop. Nothing is sent anywhere.
$ErrorActionPreference = 'SilentlyContinue'
$out = New-Object Collections.Generic.List[string]
function Section($title) { $out.Add(''); $out.Add("===== $title =====") }
function Add($text) { $out.Add(($text | Out-String).TrimEnd()) }
$since = (Get-Date).AddHours(-3)

Section 'Windows'
$os = Get-CimInstance Win32_OperatingSystem
Add "$($os.Caption) / build $($os.BuildNumber) / boot $($os.LastBootUpTime)"
Add "Admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))"

Section 'RDP / RemoteApp registry'
$keys = @(
    'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
)
foreach ($k in $keys) {
    $out.Add("[$k]")
    $p = Get-ItemProperty $k
    if ($p) {
        $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -isnot [byte[]] } |
            ForEach-Object { $out.Add("  $($_.Name) = $($_.Value)") }
    } else { $out.Add('  (missing)') }
}

Section 'Services'
Add (Get-Service TermService, UmRdpService, SessionEnv | Format-Table Name, Status, StartType -AutoSize)

Section 'Sessions'
Add (quser 2>&1)
Add (qwinsta 2>&1)

Section 'RemoteApp binaries'
foreach ($f in 'rdpinit.exe', 'rdpshell.exe', 'conhost.exe', 'WindowsPowerShell\v1.0\powershell.exe') {
    $path = Join-Path $env:windir "System32\$f"
    $out.Add("  $f : $(Test-Path $path)")
}

Section 'termsrv.dll (modified = RDP Wrapper etc.)'
$t = Get-Item "$env:windir\System32\termsrv.dll"
Add "  version $($t.VersionInfo.FileVersion), modified $($t.LastWriteTime)"
Add "  signature $((Get-AuthenticodeSignature $t.FullName).Status)"

$logs = @(
    'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
    'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational',
    'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational',
    'Microsoft-Windows-TerminalServices-RDPClient/Operational'
)
foreach ($log in $logs) {
    Section "Events: $log (last 3h)"
    Add (Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -MaxEvents 40 |
        Format-Table TimeCreated, Id, LevelDisplayName, @{ n = 'Message'; e = { ($_.Message -split "`n")[0..2] -join ' ' } } -AutoSize -Wrap)
}

Section 'Events: Application/System errors (last 3h)'
Add (Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; StartTime = $since; Level = 1, 2, 3 } -MaxEvents 60 |
    Format-Table TimeCreated, ProviderName, Id, @{ n = 'Message'; e = { ($_.Message -split "`n")[0..1] -join ' ' } } -AutoSize -Wrap)

$target = '\\tsclient\pstsc'
if (-not (Test-Path $target)) { $target = [Environment]::GetFolderPath('Desktop') }
$file = Join-Path $target 'pstsc-diagnose.txt'
[IO.File]::WriteAllLines($file, $out, (New-Object Text.UTF8Encoding $false))
Write-Host "Saved: $file"
