<#
    StallScope.ps1
    ---------------------------------------------------------------
    Diagnostics of periodic Windows freezes (Server 2019/2022/2025, Win10/11).
    Symptom under investigation: 5-30 sec freezes that recover on their own.
    Covers disks/SMART, event log, drivers, power, memory, temperatures,
    handle/memory leaks, commit charge and kernel pool tags.
    Uses only built-in Windows tools.

    How to run:
        1) Right-click PowerShell -> Run as Administrator
        2) Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        3) .\StallScope.ps1

    Or one-liner from any prompt:
        powershell -ExecutionPolicy Bypass -File .\StallScope.ps1

    Output: StallScope-Report_<hostname>_<timestamp>.txt on the current user's Desktop.
#>

[CmdletBinding()]
param(
    [int]$EventLogDays = 7
)

# --- Output preparation ------------------------------------------------------
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$OutputEncoding        = [System.Text.UTF8Encoding]::new($true)

# Force UTF-8 on console streams (harmless on any locale)
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

$desktop  = [Environment]::GetFolderPath('Desktop')
$stamp    = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$hostName = $env:COMPUTERNAME
$report   = Join-Path $desktop "StallScope-Report_${hostName}_${stamp}.txt"

# Line buffer - written to file once at the end
$script:Lines = New-Object System.Collections.Generic.List[string]

function Add-Line {
    param([string]$Text = '')
    [void]$script:Lines.Add($Text)
}

function Add-Header {
    param([string]$Title)
    Add-Line ''
    Add-Line ('=' * 78)
    Add-Line "  $Title"
    Add-Line ('=' * 78)
}

function Add-SubHeader {
    param([string]$Title)
    Add-Line ''
    Add-Line "--- $Title ---"
}

function Try-Run {
    <#
        Safely run a block, capture output into the report buffer.
        - If block throws, log the reason without killing the whole script.
        - Handles blocks that call Add-Line directly (no double "no data" line).
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Block,
        [string] $Label = ''
    )
    $countBefore = $script:Lines.Count
    try {
        $out = & $Block 2>&1
        $producedStdout = $false
        if ($null -ne $out) {
            $text = ($out | Out-String -Width 200).TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$script:Lines.Add($text)
                $producedStdout = $true
            }
        }
        if (-not $producedStdout -and $script:Lines.Count -eq $countBefore) {
            [void]$script:Lines.Add('(no data)')
        }
    } catch {
        [void]$script:Lines.Add("[ERROR$(if($Label){' in '+$Label})]: $($_.Exception.Message)")
    }
}

# --- Report header -----------------------------------------------------------
Add-Line "Windows Freeze Diagnostics Report"
Add-Line "Host:           $hostName"
Add-Line "User:           $env:USERDOMAIN\$env:USERNAME"
Add-Line "Generated at:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Event log window: last $EventLogDays days"

# Admin check - many queries return empty without admin
$isAdmin = ([Security.Principal.WindowsPrincipal]`
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Line "Running as Administrator: $isAdmin"
if (-not $isAdmin) {
    Add-Line "WARNING: without admin rights, SMART/EventLog/temperatures data will be empty."
}

# --- 0. Basic system info ----------------------------------------------------
Add-Header '0. System'
Try-Run {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        OS              = $os.Caption
        Version         = $os.Version
        Build           = $os.BuildNumber
        InstallDate     = $os.InstallDate
        LastBootUpTime  = $os.LastBootUpTime
        UptimeDays      = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
    } | Format-List
}
Try-Run {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $bb  = Get-CimInstance Win32_BaseBoard
    $bios= Get-CimInstance Win32_BIOS
    [pscustomobject]@{
        Manufacturer    = $cs.Manufacturer
        Model           = $cs.Model
        Motherboard     = "$($bb.Manufacturer) $($bb.Product)"
        BIOSVersion     = $bios.SMBIOSBIOSVersion
        BIOSDate        = $bios.ReleaseDate
        TotalRAM_GB     = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
        LogicalCPUs     = $cs.NumberOfLogicalProcessors
    } | Format-List
}
Try-Run {
    Get-CimInstance Win32_Processor |
        Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed,CurrentClockSpeed |
        Format-List
}

# ==============================================================================
# 1. DISKS: model, type, SMART, free space
# ==============================================================================
Add-Header '1. Disks: model, type, SMART, free space'

Add-SubHeader 'Physical disks (Get-PhysicalDisk)'
Try-Run {
    Get-PhysicalDisk |
        Select-Object DeviceId, FriendlyName, MediaType, BusType,
                      @{N='Size_GB';E={[math]::Round($_.Size/1GB,1)}},
                      HealthStatus, OperationalStatus,
                      @{N='Wear%';E={$_.Wear}}, FirmwareVersion, SerialNumber |
        Sort-Object DeviceId | Format-Table -AutoSize
}

Add-SubHeader 'SMART-like reliability counters (Get-StorageReliabilityCounter)'
Add-Line "Watch for: Temperature, ReadErrorsTotal, WriteErrorsTotal, Wear, PowerOnHours."
Add-Line "Any ReadErrors/WriteErrors > 0 or Temperature > 70C is suspicious."
Add-Line "ReadLatencyMax_ms > 500 is a strong smoking gun for freeze symptoms."
Try-Run {
    Get-PhysicalDisk | ForEach-Object {
        $pd = $_
        $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Disk             = $pd.FriendlyName
            Bus              = $pd.BusType
            Temp_C           = $rc.Temperature
            TempMax_C        = $rc.TemperatureMax
            Wear             = $rc.Wear
            PowerOnHours     = $rc.PowerOnHours
            StartStopCycles  = $rc.StartStopCycles
            ReadErrorsTot    = $rc.ReadErrorsTotal
            WriteErrorsTot   = $rc.WriteErrorsTotal
            ReadLatencyMax_ms= $rc.ReadLatencyMax
            WriteLatencyMax_ms=$rc.WriteLatencyMax
        }
    } | Format-Table -AutoSize
}

Add-SubHeader 'Logical volumes (free space)'
Try-Run {
    Get-Volume | Where-Object { $_.DriveLetter } |
        Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
                      @{N='Size_GB';E={[math]::Round($_.Size/1GB,1)}},
                      @{N='Free_GB';E={[math]::Round($_.SizeRemaining/1GB,1)}},
                      @{N='Free_%';E={ if($_.Size){[math]::Round(($_.SizeRemaining/$_.Size)*100,1)}else{0} }} |
        Sort-Object DriveLetter | Format-Table -AutoSize
}

Add-SubHeader 'Storage pools / Storage Spaces (if used)'
Try-Run { Get-StoragePool -ErrorAction SilentlyContinue | Format-Table -AutoSize }

# ==============================================================================
# 2. EVENT LOG: critical errors + IDs 129/11/41
# ==============================================================================
Add-Header "2. Event Log (System + Application, last $EventLogDays days)"

$since = (Get-Date).AddDays(-1 * [math]::Abs($EventLogDays))

Add-SubHeader 'Target IDs: 129 (disk timeout), 11 (disk controller), 41 (kernel-power)'
Try-Run {
    $targetIds = 129, 11, 41
    $hits = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        StartTime = $since
        Id        = $targetIds
    } -ErrorAction SilentlyContinue

    if (-not $hits) {
        Add-Line "No events with ID 129/11/41 in the window - GOOD sign."
    } else {
        Add-Line "Found $($hits.Count) events. Summary by ID/provider:"
        $hits | Group-Object Id, ProviderName |
            Select-Object @{N='ID/Provider';E={$_.Name}}, Count |
            Sort-Object Count -Descending | Format-Table -AutoSize | Out-String -Width 200 |
            ForEach-Object { Add-Line $_.TrimEnd() }

        Add-Line ''
        Add-Line "Most recent 20 events (chronological, newest first):"
        $hits | Sort-Object TimeCreated -Descending | Select-Object -First 20 |
            ForEach-Object {
                $msg = if ($_.Message) { ($_.Message -replace "`r?`n",' ').Trim() } else { '(no message text)' }
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0,200) + '...' }
                Add-Line ("[{0}] ID={1} {2} :: {3}" -f `
                    $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'),
                    $_.Id, $_.ProviderName, $msg)
            }
    }
}

Add-SubHeader 'All Critical events in System log'
Try-Run {
    Get-WinEvent -FilterHashtable @{LogName='System'; Level=1; StartTime=$since} -ErrorAction SilentlyContinue |
        Sort-Object TimeCreated -Descending |
        Select-Object TimeCreated, Id, ProviderName,
                      @{N='Message';E={
                          $m = if ($_.Message) { ($_.Message -replace "`r?`n",' ').Trim() } else { '' }
                          if ($m.Length -gt 180) { $m.Substring(0,180) + '...' } else { $m }
                      }} |
        Format-Table -AutoSize -Wrap
}

Add-SubHeader 'All Error events in System: top-20 by source'
Try-Run {
    Get-WinEvent -FilterHashtable @{LogName='System'; Level=2; StartTime=$since} -ErrorAction SilentlyContinue |
        Group-Object ProviderName, Id |
        Select-Object Count, Name |
        Sort-Object Count -Descending |
        Select-Object -First 20 |
        Format-Table -AutoSize
}

Add-SubHeader 'Events from storahci/stornvme/disk/nvme/iaStorAVC providers'
Try-Run {
    $providers = 'storahci','stornvme','disk','nvme','iaStorAVC','Microsoft-Windows-StorPort','Ntfs','volmgr'
    Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since; ProviderName=$providers} -ErrorAction SilentlyContinue |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 30 TimeCreated, Id, LevelDisplayName, ProviderName,
                      @{N='Message';E={
                          $m = if ($_.Message) { ($_.Message -replace "`r?`n",' ').Trim() } else { '' }
                          if ($m.Length -gt 180) { $m.Substring(0,180) + '...' } else { $m }
                      }} |
        Format-Table -AutoSize -Wrap
}

Add-SubHeader 'All Critical/Error events in Application log'
Try-Run {
    Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$since} -ErrorAction SilentlyContinue |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 30 TimeCreated, Id, LevelDisplayName, ProviderName,
                      @{N='Message';E={
                          $m = if ($_.Message) { ($_.Message -replace "`r?`n",' ').Trim() } else { '' }
                          if ($m.Length -gt 180) { $m.Substring(0,180) + '...' } else { $m }
                      }} |
        Format-Table -AutoSize -Wrap
}

Add-SubHeader 'BugCheck (BSOD) events in window'
Try-Run {
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting','BugCheck'; StartTime=$since} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, Message | Format-List
}
Try-Run {
    # Check for MEMORY.DMP and minidump files
    $dmps = @()
    if (Test-Path "$env:SystemRoot\MEMORY.DMP") { $dmps += Get-Item "$env:SystemRoot\MEMORY.DMP" }
    if (Test-Path "$env:SystemRoot\Minidump") {
        $dmps += Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue
    }
    if ($dmps) {
        Add-Line "Crash dump files found:"
        $dmps | Select-Object FullName, @{N='Size_MB';E={[math]::Round($_.Length/1MB,2)}}, LastWriteTime |
            Format-Table -AutoSize
    } else {
        Add-Line "No crash dump files found."
    }
}

# ==============================================================================
# 3. SERVICES AND RESOURCE USAGE
# ==============================================================================
Add-Header '3. Services and resource usage'

Add-SubHeader 'Top-20 processes by CPU time'
Try-Run {
    Get-Process | Where-Object { $_.CPU } |
        Sort-Object CPU -Descending | Select-Object -First 20 `
            Name, Id,
            @{N='CPU_sec';E={[math]::Round($_.CPU,1)}},
            @{N='RAM_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}},
            @{N='Handles';E={$_.HandleCount}},
            @{N='Threads';E={$_.Threads.Count}} |
        Format-Table -AutoSize
}

Add-SubHeader 'Top-20 processes by RAM'
Try-Run {
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 20 `
        Name, Id,
        @{N='RAM_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}},
        @{N='PrivateMB';E={[math]::Round($_.PrivateMemorySize64/1MB,1)}},
        @{N='CPU_sec';E={[math]::Round($_.CPU,1)}} |
        Format-Table -AutoSize
}

Add-SubHeader 'Leak suspects: handles, private memory, commit, kernel pools'
Add-Line "Handle count > 100k in one process is a leak (normal is < 10k; lsass ~40k)."
Add-Line "Private memory of many GB in a background utility (mouse/RGB/audio agents) is a leak."
Add-Line "Leaks grow with uptime - compare against UptimeDays in section 0."

# Process label with hosted service names (svchost PID -> TermService etc.)
$script:SvcByPid = @{}
try {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId } |
        Group-Object ProcessId | ForEach-Object { $script:SvcByPid[[int]$_.Name] = ($_.Group.Name -join ',') }
} catch { }
function Get-ProcLabel {
    param($Proc)
    $svc = $script:SvcByPid[[int]$Proc.Id]
    if ($svc) { "$($Proc.Name) [$svc]" } else { $Proc.Name }
}

Try-Run {
    Add-Line "Top-10 processes by handle count:"
    Get-Process | Sort-Object HandleCount -Descending | Select-Object -First 10 |
        Select-Object @{N='Process';E={ Get-ProcLabel $_ }}, Id,
                      @{N='Handles';E={$_.HandleCount}},
                      @{N='Threads';E={$_.Threads.Count}},
                      @{N='PrivateMB';E={[math]::Round($_.PrivateMemorySize64/1MB,1)}},
                      @{N='Started';E={ try { $_.StartTime.ToString('yyyy-MM-dd HH:mm') } catch { '' } }} |
        Format-Table -AutoSize -Wrap | Out-String -Width 200 | ForEach-Object { Add-Line $_.TrimEnd() }
}
Try-Run {
    # Raw perf class is locale-independent (Get-Counter paths break on non-English Windows)
    $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
    [pscustomobject]@{
        Commit_GB        = [math]::Round($m.CommittedBytes/1GB,1)
        CommitLimit_GB   = [math]::Round($m.CommitLimit/1GB,1)
        'Commit_%'       = [math]::Round(($m.CommittedBytes/$m.CommitLimit)*100,1)
        PagedPool_MB     = [math]::Round($m.PoolPagedBytes/1MB,1)
        NonPagedPool_MB  = [math]::Round($m.PoolNonpagedBytes/1MB,1)
    } | Format-List
    Add-Line "Guidelines: Commit > 85% of limit causes stalls/allocation failures;"
    Add-Line "PagedPool > 4 GB or NonPagedPool > 2 GB means a kernel-side leak (driver or handle leak)."
}

Add-SubHeader 'Kernel pool tags: top consumers (poolmon equivalent, no WDK needed)'
Add-Line "Every kernel allocation carries a 4-char tag. A tag with huge Used and Allocs >> Frees is the leaker."
Add-Line "Owner = loaded driver binaries containing the tag string (like 'findstr /m /l <tag> *.sys');"
Add-Line "short/common tags may match several drivers - treat the list as candidates, not proof."

# Well-known Windows kernel tags (owner is the OS itself, not a third-party driver)
# Pool tags are case-sensitive ('NtfF' != 'Ntff'), PowerShell @{} is not - hence the ordinal hashtable
$script:KnownPoolTags = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
@{
    'Cont'='Contiguous physical memory (device DMA buffers)'
    'MmSt'='Mm section prototype PTEs (mapped files)'; 'MmRe'='Mm ASLR relocation'; 'MmCa'='Mm control areas'
    'Toke'='Token objects';  'File'='File objects';   'Thre'='Thread objects';  'Proc'='Process objects'
    'Even'='Event objects';  'Sema'='Semaphores';     'ObNm'='Object names';    'ObHd'='Object handle DB'
    'Ntff'='NTFS FCB';       'Ntfx'='NTFS general';   'NtFs'='NTFS StrucSup';   'FMfn'='FltMgr file names'
    'FMfc'='FltMgr file contexts'; 'FMsl'='FltMgr stream lists'; 'EtwB'='ETW buffers'; 'EtwR'='ETW realtime'
    'smNp'='Store manager (memory compression)'; 'CM31'='Registry'; 'CM25'='Registry'; 'CM16'='Registry'
    'Irp '='I/O request packets'; 'Mdl '='Memory descriptor lists'; 'Vad '='Virtual address descriptors'
    'AlIn'='ALPC';           'Devi'='Device objects';  'IoNm'='I/O names'
    'NDnd'='NDIS';           'Ipng'='TCP/IP';         'TcpE'='TCP endpoints';   'AleE'='WFP ALE endpoints'
    'Vi54'='Video memory manager (dxgkrnl)'; 'DxgK'='DirectX kernel'
}.GetEnumerator() | ForEach-Object { $script:KnownPoolTags[$_.Key] = $_.Value }

if (-not ('DiagPoolTags' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DiagPoolTags {
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int retLen);
    public class Entry {
        public string Tag; public long PagedUsed; public long NonPagedUsed;
        public long PagedAllocs; public long PagedFrees; public long NonPagedAllocs; public long NonPagedFrees;
    }
    // SystemPoolTagInformation = 22; layout of SYSTEM_POOLTAG differs for x86/x64
    public static List<Entry> Query() {
        int len = 0x100000;
        for (int attempt = 0; attempt < 8; attempt++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret;
                int st = NtQuerySystemInformation(22, buf, len, out ret);
                if (st == unchecked((int)0xC0000004)) { len = Math.Max(len * 2, ret + 0x10000); continue; }
                if (st != 0) throw new Exception("NtQuerySystemInformation failed, NTSTATUS 0x" + st.ToString("X8"));
                bool x64 = IntPtr.Size == 8;
                int count = Marshal.ReadInt32(buf);
                int first = x64 ? 8 : 4, size = x64 ? 40 : 28;
                var list = new List<Entry>(count);
                for (int i = 0; i < count; i++) {
                    IntPtr p = IntPtr.Add(buf, first + i * size);
                    var tb = new byte[4];
                    Marshal.Copy(p, tb, 0, 4);
                    var chars = new char[4];
                    for (int k = 0; k < 4; k++) chars[k] = (tb[k] >= 32 && tb[k] < 127) ? (char)tb[k] : '.';
                    var e = new Entry();
                    e.Tag            = new string(chars);
                    e.PagedAllocs    = (uint)Marshal.ReadInt32(p, 4);
                    e.PagedFrees     = (uint)Marshal.ReadInt32(p, 8);
                    e.PagedUsed      = x64 ? Marshal.ReadInt64(p, 16) : (uint)Marshal.ReadInt32(p, 12);
                    e.NonPagedAllocs = (uint)Marshal.ReadInt32(p, x64 ? 24 : 16);
                    e.NonPagedFrees  = (uint)Marshal.ReadInt32(p, x64 ? 28 : 20);
                    e.NonPagedUsed   = x64 ? Marshal.ReadInt64(p, 32) : (uint)Marshal.ReadInt32(p, 24);
                    list.Add(e);
                }
                return list;
            } finally { Marshal.FreeHGlobal(buf); }
        }
        throw new Exception("NtQuerySystemInformation: buffer too small after retries");
    }
}
'@
}

$script:PoolTop = @()
Try-Run {
    $tags = [DiagPoolTags]::Query()
    $topNP = $tags | Sort-Object NonPagedUsed -Descending | Select-Object -First 10
    $topP  = $tags | Sort-Object PagedUsed    -Descending | Select-Object -First 10

    # Map tags -> loaded driver binaries that contain the tag string
    $wanted = @($topNP + $topP | Where-Object { -not $script:KnownPoolTags.ContainsKey($_.Tag) } |
                ForEach-Object { $_.Tag } | Select-Object -Unique)
    $owners = @{}
    foreach ($t in $wanted) { $owners[$t] = New-Object System.Collections.Generic.List[string] }
    if ($wanted.Count -gt 0) {
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $paths = Get-CimInstance Win32_SystemDriver -Filter "State='Running'" | ForEach-Object {
            $_.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:SystemRoot -replace '^System32', "$env:SystemRoot\System32"
        } | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        foreach ($path in $paths) {
            try { $text = $latin1.GetString([System.IO.File]::ReadAllBytes($path)) } catch { continue }
            foreach ($t in $wanted) {
                if ($text.IndexOf($t, [StringComparison]::Ordinal) -ge 0) { $owners[$t].Add([IO.Path]::GetFileName($path)) }
            }
        }
    }
    $ownerOf = {
        param($tag)
        if ($script:KnownPoolTags.ContainsKey($tag)) { return "Windows: $($script:KnownPoolTags[$tag])" }
        $o = $owners[$tag]
        if (-not $o -or $o.Count -eq 0) { return '(not found in loaded drivers - likely ntoskrnl/OS)' }
        $s = ($o | Select-Object -First 5) -join ', '
        if ($o.Count -gt 5) { $s += " (+$($o.Count - 5) more)" }
        $s
    }

    $fmt = {
        param($rows, $pool)
        $rows | ForEach-Object {
            $allocs = if ($pool -eq 'NP') { $_.NonPagedAllocs } else { $_.PagedAllocs }
            $frees  = if ($pool -eq 'NP') { $_.NonPagedFrees }  else { $_.PagedFrees }
            $used   = if ($pool -eq 'NP') { $_.NonPagedUsed }   else { $_.PagedUsed }
            [pscustomobject]@{
                Tag      = "'$($_.Tag)'"
                Used_MB  = [math]::Round($used/1MB,1)
                Live     = $allocs - $frees
                Allocs   = $allocs
                Frees    = $frees
                Owner    = & $ownerOf $_.Tag
            }
        }
    }

    Add-Line "Top-10 NON-PAGED pool tags:"
    & $fmt $topNP 'NP' | Format-Table -AutoSize -Wrap | Out-String -Width 220 | ForEach-Object { Add-Line $_.TrimEnd() }
    Add-Line ''
    Add-Line "Top-10 PAGED pool tags:"
    & $fmt $topP 'P' | Format-Table -AutoSize -Wrap | Out-String -Width 220 | ForEach-Object { Add-Line $_.TrimEnd() }

    $script:PoolTop = @(
        & $fmt ($topNP | Select-Object -First 3) 'NP' | ForEach-Object { $_ | Add-Member -NotePropertyName Pool -NotePropertyValue 'non-paged' -PassThru }
        & $fmt ($topP  | Select-Object -First 3) 'P'  | ForEach-Object { $_ | Add-Member -NotePropertyName Pool -NotePropertyValue 'paged' -PassThru }
    )
}

Add-SubHeader 'Running services (total, plus non-Microsoft third-party)'
Try-Run {
    $svc = Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' }
    Add-Line "Total running services: $($svc.Count)"
    Add-Line ''
    Add-Line "Non-Microsoft third-party services:"
    $svc | Where-Object { $_.PathName -notmatch '\\(Windows\\system32|Windows\\System32|Windows\\Microsoft)' } |
        Select-Object Name, DisplayName, StartMode, StartName,
                      @{N='Path';E={ ($_.PathName -replace '^\s*"?([^"]+\.exe).*$','$1') }} |
        Sort-Object Name | Format-Table -AutoSize -Wrap
}

Add-SubHeader 'Quick performance counter snapshot (1 sec sample)'
Try-Run {
    Get-Counter -Counter `
        '\Processor(_Total)\% Processor Time',
        '\Memory\Available MBytes',
        '\Memory\Pages/sec',
        '\PhysicalDisk(_Total)\Avg. Disk Queue Length',
        '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
        '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
        '\System\Processor Queue Length' -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty CounterSamples |
    Select-Object Path, @{N='Value';E={[math]::Round($_.CookedValue,4)}} | Format-Table -AutoSize
    Add-Line ''
    Add-Line "Guidelines: Avg.Disk sec/Read and /Write > 0.025 (25 ms) means disk is slow;"
    Add-Line "Avg.Disk Queue Length > 2 sustained means the disk is a bottleneck."
}

# ==============================================================================
# 4. CHIPSET / NVMe / SATA DRIVERS
# ==============================================================================
Add-Header '4. AMD chipset and storage controller drivers'

Add-SubHeader 'AMD chipset / system devices'
Try-Run {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Manufacturer -match 'AMD|Advanced Micro' -or $_.FriendlyName -match 'AMD' } |
        Select-Object Class, FriendlyName, Manufacturer, Status |
        Sort-Object Class, FriendlyName | Format-Table -AutoSize -Wrap
}

Add-SubHeader 'NVMe / SATA / storage controller drivers (versions)'
Try-Run {
    $storageClasses = 'SCSIAdapter','HDC','System'
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Class -in $storageClasses -and ($_.FriendlyName -match 'NVMe|AHCI|SATA|Storage|RAID|StorPort|chipset') } |
        ForEach-Object {
            $d = $_
            $verProp = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion'  -ErrorAction SilentlyContinue
            $dateProp= Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverDate'     -ErrorAction SilentlyContinue
            $provProp= Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Class    = $d.Class
                Name     = $d.FriendlyName
                Status   = $d.Status
                Provider = $provProp.Data
                Version  = $verProp.Data
                Date     = $dateProp.Data
            }
        } | Format-Table -AutoSize -Wrap
}

Add-SubHeader 'System storage/power drivers (by name)'
Try-Run {
    $names = 'storahci','stornvme','amdsata','amdxata','amdpsp','amdgpio2','amdsps','amdkmpfd','amdppm','amdk8','amdpci','amdsbs'
    Get-CimInstance Win32_SystemDriver | Where-Object { $names -contains $_.Name } |
        Select-Object Name, DisplayName, State, StartMode, PathName | Format-Table -AutoSize -Wrap
}

Add-SubHeader 'AMD Chipset Software installation (from Uninstall registry)'
Try-Run {
    $regPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'AMD|Ryzen|Chipset' } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Sort-Object DisplayName | Format-Table -AutoSize -Wrap
}

# ==============================================================================
# 5. POWER MANAGEMENT
# ==============================================================================
Add-Header '5. Power management'

Add-SubHeader 'Active power scheme'
Try-Run { powercfg /getactivescheme }

Add-SubHeader 'All available schemes'
Try-Run { powercfg /list }

Add-SubHeader 'Key parameters of the active scheme'
Try-Run {
    # Extract 36-char UUID from powercfg output, locale-independent
    $activeMatch = (powercfg /getactivescheme | Out-String) | Select-String -Pattern '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $active = if ($activeMatch) { $activeMatch.Matches.Value } else { '' }
    Add-Line "Active GUID: $active"
    if (-not $active) {
        Add-Line "[!] Could not extract active scheme GUID - skipping powercfg /query"
        return
    }
    Add-Line ''

    # PCI Express -> Link State Power Management (common freeze cause with NVMe)
    Add-Line ">>> PCI Express -> Link State Power Management (ASPM):"
    powercfg /query $active SUB_PCIEXPRESS ASPM 2>$null
    Add-Line ''
    # Hard disk -> Turn off after
    Add-Line ">>> Hard disk -> Turn off after:"
    powercfg /query $active SUB_DISK DISKIDLE 2>$null
    Add-Line ''
    # Processor: min/max state
    Add-Line ">>> Processor power management (Min/Max state):"
    powercfg /query $active SUB_PROCESSOR PROCTHROTTLEMIN 2>$null
    powercfg /query $active SUB_PROCESSOR PROCTHROTTLEMAX 2>$null
    Add-Line ''
    # USB selective suspend
    Add-Line ">>> USB selective suspend:"
    powercfg /query $active 2A737441-1930-4402-8D77-B2BEBBA308A3 48E6B7A6-50F5-4782-A5D4-53BB8F07E226 2>$null
}

Add-SubHeader 'Sleep states availability (powercfg /a)'
Add-Line "Full powercfg /energy produces an HTML report and takes ~60s. Here we only list available sleep states."
Try-Run {
    powercfg /a
}

# ==============================================================================
# 6. MEMORY: XMP / speed
# ==============================================================================
Add-Header '6. Memory: XMP / speed / voltage'

Add-SubHeader 'Memory modules (Win32_PhysicalMemory)'
Try-Run {
    Get-CimInstance Win32_PhysicalMemory |
        Select-Object BankLabel, DeviceLocator, Manufacturer, PartNumber,
                      @{N='Size_GB';E={[math]::Round($_.Capacity/1GB,1)}},
                      @{N='RatedSpeed_MTs';E={$_.Speed}},
                      @{N='ConfiguredSpeed_MTs';E={$_.ConfiguredClockSpeed}},
                      @{N='ConfiguredVoltage_V';E={ if($_.ConfiguredVoltage){[math]::Round($_.ConfiguredVoltage/1000,3)}else{$null} }},
                      FormFactor, SMBIOSMemoryType |
        Format-Table -AutoSize -Wrap
    Add-Line ''
    Add-Line "If ConfiguredSpeed is lower than RatedSpeed - XMP/DOCP is NOT enabled in BIOS."
    Add-Line "On Ryzen platforms with 4 DIMMs, stable rated speed sometimes needs manual tRFC and SoC voltage tuning."
}

Add-SubHeader 'Memory summary'
Try-Run {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        TotalVisible_GB = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
        FreePhysical_GB = [math]::Round($os.FreePhysicalMemory/1MB,1)
        TotalVirtual_GB = [math]::Round($os.TotalVirtualMemorySize/1MB,1)
        FreeVirtual_GB  = [math]::Round($os.FreeVirtualMemory/1MB,1)
    } | Format-List
}

# ==============================================================================
# 7. TEMPERATURES (CPU / disks)
# ==============================================================================
Add-Header '7. Temperatures'

Add-SubHeader 'CPU/ACPI thermal zones (MSAcpi_ThermalZoneTemperature)'
Add-Line "NOTE: on desktop AMD AM4 (X570) boards ACPI thermal zones usually do NOT report real Ryzen core temperature."
Add-Line "You will get either a 'Not supported' error or a fixed ~27.8C value."
Add-Line "For real CPU temperature use HWiNFO64 / Ryzen Master / AIDA64 (out of scope for built-in tools)."
Try-Run {
    Get-CimInstance -Namespace 'root\WMI' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue |
        Select-Object InstanceName,
                      @{N='Temp_C';E={ [math]::Round(($_.CurrentTemperature - 2732)/10,1) }},
                      @{N='CriticalTrip_C';E={ if($_.CriticalTripPoint){[math]::Round(($_.CriticalTripPoint - 2732)/10,1)} }} |
        Format-Table -AutoSize
}

Add-SubHeader 'Disk temperatures (from Get-StorageReliabilityCounter)'
Try-Run {
    Get-PhysicalDisk | ForEach-Object {
        $rc = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Disk     = $_.FriendlyName
            Bus      = $_.BusType
            Temp_C   = $rc.Temperature
            TempMax_C= $rc.TemperatureMax
        }
    } | Format-Table -AutoSize
    Add-Line ''
    Add-Line "NVMe guidelines: 35-55C normal, >70C throttling, >80C danger zone."
}

# ==============================================================================
# AUTO-ANALYSIS SUMMARY
# ==============================================================================
Add-Header 'Auto-analysis - probable causes'

$findings = New-Object System.Collections.Generic.List[string]

# 1) Event 129
try {
    $e129 = Get-WinEvent -FilterHashtable @{LogName='System'; Id=129; StartTime=$since} -ErrorAction SilentlyContinue
    if ($e129) {
        $findings.Add("[HIGH] Found $($e129.Count) Event ID 129 (Reset to device, storahci/stornvme) - direct match for '5-30 sec freeze' symptom. Usual culprit: NVMe SSD with aggressive PCIe ASPM, or outdated storage controller driver.")
    } else {
        $findings.Add("[OK] No Event ID 129 in the window - but that does not rule the issue out if freezes are rare.")
    }
} catch { }

# 2) Event 41 (kernel-power)
try {
    $e41 = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; StartTime=$since} -ErrorAction SilentlyContinue
    if ($e41) {
        $findings.Add("[HIGH] Found $($e41.Count) Kernel-Power 41 events - system rebooted/shut down uncleanly. Possible causes: undumped BSOD, unstable PSU, overheat, unstable XMP.")
    }
} catch { }

# 3) Event 11 (disk controller)
try {
    $e11 = Get-WinEvent -FilterHashtable @{LogName='System'; Id=11; ProviderName='disk','iaStorAVC','storahci','stornvme'; StartTime=$since} -ErrorAction SilentlyContinue
    if ($e11) {
        $findings.Add("[HIGH] Found $($e11.Count) ID 11 events from storage controller providers - possible SATA cable/port/SSD/firmware issues.")
    }
} catch { }

# 4) Memory: ConfiguredSpeed < RatedSpeed
try {
    $mem = Get-CimInstance Win32_PhysicalMemory
    $slow = $mem | Where-Object { $_.ConfiguredClockSpeed -and $_.Speed -and ($_.ConfiguredClockSpeed -lt $_.Speed) }
    if ($slow) {
        $findings.Add("[MED] XMP/DOCP appears DISABLED: modules rated for $($mem[0].Speed) MT/s, running at $($slow[0].ConfiguredClockSpeed) MT/s. Does not cause freezes directly but degrades performance and often indicates suboptimal BIOS setup.")
    } else {
        $findings.Add("[OK] Memory is running at rated speed.")
    }
} catch { }

# 5) Power scheme
try {
    $scheme = (powercfg /getactivescheme) 2>$null | Out-String
    # Detect Balanced / Power Saver by GUID (locale-independent) or name
    if ($scheme -match '381b4222-f694-41f0-9685-ff5bb260df2e|a1841308-3541-4fab-bc81-f71556f20b4a|Balanced|Power saver') {
        $findings.Add("[MED] Active scheme looks like Balanced or Power Saver. For a Ryzen workstation, prefer 'High performance' (or AMD Ryzen High performance if AMD Chipset Software provides it). Balanced enables core parking and aggressive PCIe ASPM by default.")
    }
} catch { }

# 6) Free space on system drive
try {
    $sysVol = Get-Volume -DriveLetter ($env:SystemDrive[0]) -ErrorAction SilentlyContinue
    if ($sysVol -and $sysVol.Size -gt 0) {
        $freePct = ($sysVol.SizeRemaining / $sysVol.Size) * 100
        if ($freePct -lt 10) {
            $findings.Add("[HIGH] System drive $($env:SystemDrive) has only $([math]::Round($freePct,1))% free. NTFS and SSDs slow down noticeably below 10% free.")
        }
    }
} catch { }

# 7) Disk health
try {
    $bad = Get-PhysicalDisk | Where-Object { $_.HealthStatus -ne 'Healthy' -or $_.OperationalStatus -ne 'OK' }
    if ($bad) {
        $findings.Add("[HIGH] Disks with non-Healthy status: " + (($bad | ForEach-Object { "$($_.FriendlyName) [$($_.HealthStatus)/$($_.OperationalStatus)]" }) -join '; '))
    }
} catch { }

# 8) High disk latency right now
try {
    $lat = Get-Counter -Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Read','\PhysicalDisk(_Total)\Avg. Disk sec/Write' -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
    foreach ($s in $lat.CounterSamples) {
        if ($s.CookedValue -gt 0.05) {
            $findings.Add("[MED] High current disk latency: $($s.Path) = $([math]::Round($s.CookedValue*1000,1)) ms. Normal for SSD is <5 ms, HDD <20 ms.")
        }
    }
} catch { }

# 9) ReadLatencyMax_ms high on any disk (historical smoking gun for freezes)
try {
    Get-PhysicalDisk | ForEach-Object {
        $rc = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($rc -and $rc.ReadLatencyMax -and $rc.ReadLatencyMax -gt 500) {
            $findings.Add("[HIGH] $($_.FriendlyName) reports historical ReadLatencyMax = $($rc.ReadLatencyMax) ms. Anything above 500 ms points at PCIe ASPM waking up a sleeping NVMe or a controller stall - main cause of user-visible freezes.")
        }
    }
} catch { }

# 10) Handle leaks
try {
    Get-Process | Where-Object { $_.HandleCount -gt 100000 } | ForEach-Object {
        $findings.Add("[HIGH] Handle leak: $(Get-ProcLabel $_) (PID $($_.Id)) holds $($_.HandleCount) handles (normal < 10k). Exhausts kernel memory and causes periodic stalls. Restart that process/service; if it is svchost, restart the service listed in brackets.")
    }
} catch { }

# 11) Private memory leaks (excluding expected heavy hitters)
try {
    $expectedHeavy = 'java','idea64','vmmem','vmmemWSL','vmwp','sqlservr','devenv','chrome','msedge','firefox','MsMpEng','Memory Compression'
    Get-Process | Where-Object { $_.PrivateMemorySize64 -gt 4GB -and $expectedHeavy -notcontains $_.Name } | ForEach-Object {
        $findings.Add("[HIGH] Memory leak suspect: $(Get-ProcLabel $_) (PID $($_.Id)) uses $([math]::Round($_.PrivateMemorySize64/1GB,1)) GB private memory. Restart/update/uninstall it and watch whether it grows again.")
    }
} catch { }

# 12) Commit charge and kernel pools
try {
    $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
    $commitPct = ($m.CommittedBytes / $m.CommitLimit) * 100
    if ($commitPct -gt 85) {
        $findings.Add("[HIGH] Commit charge at $([math]::Round($commitPct,1))% of limit ($([math]::Round($m.CommittedBytes/1GB,1)) / $([math]::Round($m.CommitLimit/1GB,1)) GB). Near the limit Windows stalls growing the pagefile and allocations fail. Find the memory hogs above or enlarge the pagefile.")
    }
    # Pools scale with RAM: fixed floor, or a share of physical memory on big machines
    $ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $pagedLimit    = [math]::Max(4GB, $ramBytes * 0.04)
    $nonPagedLimit = [math]::Max(2GB, $ramBytes * 0.02)
    if ($m.PoolPagedBytes -gt $pagedLimit) {
        $findings.Add("[HIGH] Paged pool = $([math]::Round($m.PoolPagedBytes/1GB,1)) GB (limit for this RAM: $([math]::Round($pagedLimit/1GB,1)) GB) - kernel-side leak (often a handle leak or a driver). See 'Kernel pool tags' in section 3.")
    }
    if ($m.PoolNonpagedBytes -gt $nonPagedLimit) {
        $findings.Add("[HIGH] Non-paged pool = $([math]::Round($m.PoolNonpagedBytes/1GB,1)) GB (limit for this RAM: $([math]::Round($nonPagedLimit/1GB,1)) GB) - driver leak (network/storage/filter driver). See 'Kernel pool tags' in section 3.")
    }
} catch { }

# 13) Individual pool tags that are suspiciously large
try {
    foreach ($t in $script:PoolTop) {
        if ($t.Used_MB -gt 500) {
            $findings.Add("[HIGH] Pool tag $($t.Tag) holds $($t.Used_MB) MB of $($t.Pool) pool ($($t.Live) live allocations). Owner: $($t.Owner). Update or remove that driver; if it is a Windows tag, look at what drives it (e.g. MmSt = many mapped files, Toke/File/Thre = handle leaks).")
        }
    }
} catch { }

# 14) Sustained CPU saturation (3 samples, locale-independent)
try {
    $samples = 1..3 | ForEach-Object {
        (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        Start-Sleep -Seconds 1
    }
    $avg = ($samples | Measure-Object -Average).Average
    if ($avg -gt 85) {
        $findings.Add("[MED] CPU is saturated: average $([math]::Round($avg,0))% over 3 samples. Everything (including UI) gets queued - check top processes by CPU in section 3.")
    }
} catch { }

if ($findings.Count -eq 0) {
    Add-Line "No obvious auto-markers detected. Review sections above manually, especially #2 (event log) and #5 (power scheme)."
} else {
    foreach ($f in $findings) { Add-Line $f }
}

Add-Header 'Recommendations for the 5-30 sec freeze symptom'
Add-Line @'
In order of likelihood on Ryzen + AMD chipset + NVMe:

1. DISABLE PCI Express Link State Power Management (usually THE fix).
   powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
   powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
   powercfg /setactive       SCHEME_CURRENT
   This removes the most common cause of Event ID 129 on NVMe.

2. DISABLE "Turn off hard disk after".
   powercfg /change disk-timeout-ac 0
   powercfg /change disk-timeout-dc 0

3. SWITCH power plan to High Performance.
   powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

4. UPDATE AMD chipset driver: amd.com -> Drivers + Support -> Chipset -> your chipset -> latest.
   This also installs the correct CPPC/PPM processor power driver.

5. UPDATE NVMe SSD firmware (vendor firmware tool). Samsung 970/980, WD SN550/SN750,
   Crucial P5/P5 Plus are known to freeze on older firmware.

6. CHECK motherboard BIOS options (AMD X570/B550 examples):
   - Advanced -> AMD CBS -> NBIO -> PCIe ASPM = Disabled;
   - Advanced -> AMD CBS -> NBIO -> SoC Power Management = Typical Current Idle
     (NOT Low Current Idle - Low Current Idle on X570 is known to cause freezes);
   - Global C-State Control = Auto/Enabled (Disabled only if instability persists).

7. VERIFY XMP/DOCP. On 4-DIMM Ryzen configurations rated 3200+ MT/s sometimes
   requires manual SoC voltage (1.10-1.15V) and tRFC tuning. If unstable, drop to 2933 MT/s.

8. CHECK real CPU/disk temperatures with HWiNFO64 (free):
   - CPU package (Tctl/Tdie) - should stay below 85C under load;
   - NVMe SSD - should stay below 70C; if higher, add heatsink/airflow.

9. IF freezes persist - collect extended data:
   powercfg /energy /duration 600   (leave system under load, get HTML report)
   perfmon /rel                     (Reliability Monitor for a per-day view)

If Event ID 129 events disappear after steps 1-3, the culprit was PCIe/NVMe power saving.
'@

# --- Write report to disk ----------------------------------------------------
try {
    [System.IO.File]::WriteAllLines($report, $script:Lines, [System.Text.UTF8Encoding]::new($true))
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host " Report saved: $report" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host " Send this file back and I can help you interpret the key sections."  -ForegroundColor Green
} catch {
    Write-Host "Failed to write report: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Dumping report contents to console:" -ForegroundColor Yellow
    $script:Lines | ForEach-Object { Write-Host $_ }
}
