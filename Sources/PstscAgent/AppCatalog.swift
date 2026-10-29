import CryptoKit
import Foundation

/// A Start menu entry on the remote PC. appID is its AppUserModelID, launchable via shell:AppsFolder.
struct RemoteApp: Codable, Hashable {
    let name: String
    let appID: String
}

/// The remote PC's Start menu, exported by a hidden PowerShell helper into a shared folder.
///
/// On every RemoteApp connection the helper:
/// 1. writes `Get-StartApps` as JSON to \\tsclient\pstsc\apps.json (our shared folder), then
/// 2. stays running hidden (once per session, guarded by a mutex) so the remote session does not
///    log off when the user closes the last remote program, like Parallels keeps Windows running.
final class AppCatalog {
    private(set) var apps: [RemoteApp] = []
    var onChange: (() -> Void)?
    /// The helper finished exporting app icons (they keep arriving for a while after the list).
    var onIconsChange: (() -> Void)?
    /// Called about once a second while icons download, so the UI can show progress.
    var onIconsProgress: (() -> Void)?

    static let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pstsc", isDirectory: true)
    static let sharedFolder = supportFolder.appendingPathComponent("share", isDirectory: true)
    private static let exportFile = sharedFolder.appendingPathComponent("apps.json")
    private static let cacheFolder = supportFolder.appendingPathComponent("catalog", isDirectory: true)

    /// The remote PC this catalog's apps belong to. The app list is cached per host so that
    /// connecting to a different PC never shows the previous PC's programs.
    private var host = ""
    private var pollTimer: Timer?
    private var iconTimer: Timer?
    /// Seconds spent waiting for apps.json (0…exportTimeout). Kept across a reconnect to the same PC.
    private var exportElapsed = 0
    /// Highest list-wait percent shown, so a reconnect never draws a lower number.
    private var listFloor = 0
    private static let exportTimeout = 60
    private static let iconsDoneFile = sharedFolder.appendingPathComponent("icons.done")

    init() {
        try? FileManager.default.createDirectory(at: Self.sharedFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
    }

    /// A per-host cache file, keyed by a hash of the host so any address is a safe file name.
    private static func cacheFile(for host: String) -> URL {
        let key = Insecure.MD5.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent("\(key).json")
    }

    /// Call before each connection. Switches to the given PC: shows that PC's cached apps (or none)
    /// and removes the previous PC's export so a stale file is never mistaken for this PC's list.
    func beginConnection(host: String, resetProgress: Bool = true) {
        let sameHost = !self.host.isEmpty && self.host.caseInsensitiveCompare(host) == .orderedSame
        self.host = host
        pollTimer?.invalidate()
        iconTimer?.invalidate()
        if resetProgress || !sameHost {
            exportElapsed = 0
            listFloor = 0
        }
        if let data = try? Data(contentsOf: Self.cacheFile(for: host)),
           let cached = try? JSONDecoder().decode([RemoteApp].self, from: data) {
            apps = cached
        } else if !sameHost {
            apps = []
        }
        // Drop the previous connection's export; this PC's helper writes a fresh one.
        try? FileManager.default.removeItem(at: Self.exportFile)
        try? FileManager.default.removeItem(at: Self.iconsDoneFile)
        onChange?()
    }

    // MARK: Remote helper

    /// conhost --headless runs the console program without any window; "-WindowStyle Hidden"
    /// alone still flashes a PowerShell window that then lingers minimized.
    static let helperProgram = #"C:\Windows\System32\conhost.exe"#

    /// The helper itself lives in the shared folder (see helperScript); the command line only waits
    /// for drive redirection to come up and dot-sources it. This keeps the RemoteApp arguments short.
    static var helperArguments: String {
        let bootstrap = #"""
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-Path '\\tsclient\pstsc\helper.ps1') { . '\\tsclient\pstsc\helper.ps1'; break }
            Start-Sleep -Seconds 1
        }
        """#
        // -EncodedCommand takes Base64 of UTF-16LE and sidesteps all quoting problems.
        let encoded = Data(bootstrap.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        return #"--headless C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe "#
            + "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand \(encoded)"
    }

    /// Writes helper.ps1 into the shared folder; call before every RemoteApp connection.
    static func prepareHelper() {
        try? FileManager.default.createDirectory(at: sharedFolder.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try? helperScript.write(to: sharedFolder.appendingPathComponent("helper.ps1"), atomically: true, encoding: .utf8)
        try? resourceScript.write(to: sharedFolder.appendingPathComponent("resources.ps1"), atomically: true, encoding: .utf8)
    }

    // MARK: Resource report

    static let resourceReport = sharedFolder.appendingPathComponent("resources.txt")

    /// Runs resources.ps1 hidden on the remote PC; the result lands in resourceReport.
    static var resourceArguments: String {
        #"--headless C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive "#
            + #"-ExecutionPolicy Bypass -File \\tsclient\pstsc\resources.ps1"#
    }

    /// What the Pstsc session costs the remote PC: whole-PC CPU/memory, then every process in our
    /// session plus the Remote Desktop service, with CPU measured over 3 seconds.
    /// WMI class names are used because performance counter names are localized on Korean Windows.
    private static let resourceScript = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    $sid = (Get-Process -Id $PID).SessionId
    $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $termPid = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
    function Snapshot {
        $map = @{}
        Get-Process | Where-Object { $_.SessionId -eq $sid -or $_.Id -eq $termPid } | ForEach-Object {
            $map[$_.Id] = [pscustomobject]@{ Name = $_.ProcessName; Cpu = $_.TotalProcessorTime.TotalMilliseconds; Mem = $_.WorkingSet64 }
        }
        $map
    }
    $before = Snapshot
    $sysCpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    Start-Sleep -Seconds 3
    $after = Snapshot
    $sysCpu2 = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMB = [math]::Round($os.FreePhysicalMemory / 1024)

    $rows = foreach ($id in $after.Keys) {
        $b = $before[$id]; $a = $after[$id]
        $cpu = if ($b) { ($a.Cpu - $b.Cpu) / (3000 * $cores) * 100 } else { 0 }
        $name = if ($id -eq $termPid) { 'svchost (TermService)' } else { $a.Name }
        [pscustomobject]@{ Name = $name; PID = $id; CPU = [math]::Round($cpu, 1); MemMB = [math]::Round($a.Mem / 1MB, 1) }
    }
    $rows = $rows | Sort-Object MemMB -Descending
    $sumCpu = [math]::Round(($rows | Measure-Object CPU -Sum).Sum, 1)
    $sumMem = [math]::Round(($rows | Measure-Object MemMB -Sum).Sum)

    $lines = @()
    $lines += "measured: " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "  session: $sid  logical CPUs: $cores"
    $lines += "PC CPU: $sysCpu% -> $sysCpu2%   PC memory: $($totalMB - $freeMB) / $totalMB MB used"
    $lines += "Pstsc session + TermService: CPU $sumCpu%  memory $sumMem MB  ($($rows.Count) processes)"
    $lines += ""
    $lines += ($rows | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
    [IO.File]::WriteAllText('\\tsclient\pstsc\resources.txt', ($lines -join "`r`n"), (New-Object Text.UTF8Encoding $false))
    """#

    /// 1. Start menu list -> apps.json
    /// 2. a 96 px icon per app -> icons/<md5 of AppID>.png (only missing ones), then icons.done
    /// 3. once per session (mutex), keeps an invisible 1x1 window open so the remote session does not
    ///    log off when the last visible program closes or hides to the tray.
    private static let helperScript = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    $share = '\\tsclient\pstsc'
    $utf8 = New-Object Text.UTF8Encoding $false
    $apps = @(Get-StartApps | Select-Object Name, AppID)
    $json = ConvertTo-Json -InputObject $apps -Compress
    [IO.File]::WriteAllText("$share\apps.json", $json, $utf8)

    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
    using System;
    using System.Drawing;
    using System.Drawing.Imaging;
    using System.Runtime.InteropServices;
    public static class PstscIcons {
        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr bitmap); }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx; public int cy; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);
        /// Frees managed garbage and hands unused pages back to Windows (Task Manager memory drops).
        public static void Trim() {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            SetProcessWorkingSetSize(GetCurrentProcess(), new IntPtr(-1), new IntPtr(-1));
        }
        public static bool Save(string parsingName, int size, string file) {
            try {
                Guid iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
                IShellItemImageFactory factory;
                SHCreateItemFromParsingName(parsingName, IntPtr.Zero, ref iid, out factory);
                SIZE s; s.cx = size; s.cy = size;
                IntPtr bitmap;
                if (factory.GetImage(s, 0x5, out bitmap) != 0) return false; // ICONONLY | BIGGERSIZEOK
                try {
                    using (Bitmap raw = Image.FromHbitmap(bitmap)) {
                        Rectangle r = new Rectangle(0, 0, raw.Width, raw.Height);
                        BitmapData d = raw.LockBits(r, ImageLockMode.ReadOnly, raw.PixelFormat);
                        // FromHbitmap drops alpha; reread the same bytes as premultiplied ARGB.
                        using (Bitmap argb = new Bitmap(d.Width, d.Height, d.Stride, PixelFormat.Format32bppPArgb, d.Scan0)) {
                            argb.Save(file, ImageFormat.Png);
                        }
                        raw.UnlockBits(d);
                    }
                } finally { DeleteObject(bitmap); }
                return true;
            } catch { return false; }
        }
    }
    '@
    $md5 = [Security.Cryptography.MD5]::Create()
    foreach ($app in $apps) {
        $hash = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($app.AppID)) | ForEach-Object { $_.ToString('x2') })
        $file = "$share\icons\$hash.png"
        if (-not (Test-Path $file)) {
            $tmp = Join-Path $env:TEMP "pstsc-$hash.png"
            if ([PstscIcons]::Save("shell:AppsFolder\" + $app.AppID, 96, $tmp)) { Move-Item -Force $tmp $file }
        }
    }
    [IO.File]::WriteAllText("$share\icons.done", (Get-Date).ToString('o'), $utf8)

    # Windows logs a RemoteApp session off once no app window is visible (programs hidden in the
    # tray do not count), which also kills those tray programs. A 1x1, almost transparent window
    # keeps the session alive; Pstsc never shows it on the Mac (title PstscKeepAlive).
    # Each connection's helper takes over from the previous one, so the keep-alive always runs the
    # current, memory-trimmed version. Only our own helpers are stopped: their -EncodedCommand
    # decodes to the bootstrap (helper.ps1) or an older Pstsc script (PstscKeepAlive).
    $sid = (Get-Process -Id $PID).SessionId
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.SessionId -eq $sid } |
        ForEach-Object {
            if ($_.CommandLine -match '-EncodedCommand\s+(\S+)') {
                $text = ''
                try { $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } catch {}
                if ($text -match 'PstscKeepAlive|tsclient\\pstsc\\helper\.ps1') { Stop-Process -Id $_.ProcessId -Force }
            }
        }

    $mutex = New-Object Threading.Mutex($false, 'Local\PstscKeepAlive-3')
    $owned = $false
    try { $owned = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if ($owned) {
        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object Windows.Forms.Form
        $form.Text = 'PstscKeepAlive'
        $form.FormBorderStyle = 'None'
        $form.StartPosition = 'Manual'
        $form.Location = New-Object Drawing.Point(0, 0)
        $form.Size = New-Object Drawing.Size(1, 1)
        $form.MinimumSize = New-Object Drawing.Size(1, 1)
        $form.Opacity = 0.01
        $form.ShowInTaskbar = $true
        $form.Add_Shown({ [PstscIcons]::Trim() })
        # Working set creeps back up over time; give it back every 5 minutes.
        $timer = New-Object Windows.Forms.Timer
        $timer.Interval = 300000
        $timer.Add_Tick({ [PstscIcons]::Trim() })
        $timer.Start()
        [Windows.Forms.Application]::Run($form)
    }
    """#

    /// Waits up to a minute for the helper's fresh export and loads it.
    func watchForExport() {
        pollTimer?.invalidate()
        let started = Date()
        var waited = 0
        onIconsProgress?()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            waited += 1
            self.exportElapsed = min(Self.exportTimeout - 1, self.exportElapsed + 1)
            if let modified = try? Self.exportFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= started.addingTimeInterval(-2), self.loadExport() {
                timer.invalidate()
                self.watchForIcons(since: started)
            } else if waited >= Self.exportTimeout {
                FileHandle.standardError.write(Data("[pstsc] app list export did not arrive\n".utf8))
                timer.invalidate()
            }
            self.onIconsProgress?()
        }
    }

    /// 0–99 while still waiting for the remote app list; nil once there is a list to show, or
    /// before the helper was launched (nothing to measure yet).
    func listWaitPercent() -> Int? {
        guard apps.isEmpty, pollTimer?.isValid == true || exportElapsed > 0 else { return nil }
        let percent = min(99, exportElapsed * 100 / Self.exportTimeout)
        listFloor = max(listFloor, percent)
        return listFloor
    }

    /// Icons take a while (one per app, only missing ones); poll for icons.done for up to 5 minutes,
    /// reporting progress each second so the Start menu can show a percentage.
    private func watchForIcons(since started: Date) {
        iconTimer?.invalidate()
        let done = Self.sharedFolder.appendingPathComponent("icons.done")
        var elapsed = 0
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += 1
            if let modified = try? done.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= started.addingTimeInterval(-2) {
                timer.invalidate()
                self.onIconsChange?()
            } else if elapsed >= 300 {
                timer.invalidate()
            } else {
                self.onIconsProgress?()
            }
        }
    }

    /// How many of the current apps already have an icon on the Mac, out of the total.
    /// nil while the app list hasn't arrived, or once the helper has finished (some apps have no
    /// extractable icon, so "every icon present" may never happen).
    func iconProgress() -> (done: Int, total: Int)? {
        guard iconTimer?.isValid == true,
              !FileManager.default.fileExists(atPath: Self.iconsDoneFile.path) else { return nil }
        let total = apps.count
        guard total > 0 else { return nil }
        let folder = Self.sharedFolder.appendingPathComponent("icons", isDirectory: true)
        let fm = FileManager.default
        var done = 0
        for app in apps {
            let key = Insecure.MD5.hash(data: Data(app.appID.utf8)).map { String(format: "%02x", $0) }.joined()
            if fm.fileExists(atPath: folder.appendingPathComponent("\(key).png").path) { done += 1 }
        }
        return done >= total ? nil : (done, total)
    }

    private struct Entry: Decodable {
        let Name: String?
        let AppID: String?
    }

    private func loadExport() -> Bool {
        guard var data = try? Data(contentsOf: Self.exportFile), !data.isEmpty else { return false }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }

        // ConvertTo-Json writes a bare object instead of an array when there is only one entry.
        let entries = (try? JSONDecoder().decode([Entry].self, from: data))
            ?? (try? JSONDecoder().decode(Entry.self, from: data)).map { [$0] }
        guard let entries else { return false }

        let loaded = entries.compactMap { entry -> RemoteApp? in
            guard let name = entry.Name, let id = entry.AppID, !name.isEmpty, !id.isEmpty else { return nil }
            return RemoteApp(name: name, appID: id)
        }
        apps = Array(Set(loaded)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let cache = try? JSONEncoder().encode(apps) {
            try? cache.write(to: Self.cacheFile(for: host))
        }
        FileHandle.standardError.write(Data("[pstsc] loaded \(apps.count) remote apps\n".utf8))
        onChange?()
        return true
    }
}
