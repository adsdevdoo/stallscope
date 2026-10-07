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

    Output: StallScope-Report_<hostname>_<timestamp>.txt on the current user's Desktop,
    plus StallScope-Snapshot_<hostname>_<timestamp>.json. The next run compares against
    the latest snapshot and shows what grew in between (handles, memory, kernel pool tags).

    Watch mode (catch the freeze while it happens):
        .\StallScope.ps1 -Watch -Minutes 60
    Samples CPU/DPC/ISR, disk latency, memory and scheduler lag every second and logs
    each stall with the processes active at that moment. Output: StallScope-Watch_*.txt + .csv.
#>

[CmdletBinding()]
param(
    [int]$EventLogDays = 7,

    # Watch mode: sample the system every IntervalSec for Minutes (0 = until Ctrl+C)
    # and log every second where something stalls, instead of the one-shot report.
    [switch]$Watch,
    [int]$Minutes = 30,
    [int]$IntervalSec = 1,

    # Snapshot to compare against for leak growth; default = latest snapshot of this host on Desktop
    [string]$Baseline = ''
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

# ==============================================================================
# WATCH MODE: sample every second, log the moments where the system stalls
# ==============================================================================
if ($Watch) {
    $watchTxt = Join-Path $desktop "StallScope-Watch_${hostName}_${stamp}.txt"
    $watchCsv = Join-Path $desktop "StallScope-Watch_${hostName}_${stamp}.csv"
    $inv      = [Globalization.CultureInfo]::InvariantCulture
    $cs       = Get-CimInstance Win32_ComputerSystem
    $logical  = [int]$cs.NumberOfLogicalProcessors
    $ramMB    = [double]$cs.TotalPhysicalMemory / 1MB
    $interval = [math]::Max(1, $IntervalSec)
    $probeFile = Join-Path $env:TEMP "stallscope-probe-$PID.tmp"
    $probeBuf  = New-Object byte[] 4096

    # Disk perf instance "0 C:" -> "0 C: (Samsung SSD 990 PRO 2TB)"
    $diskNames = @{}
    try { Get-PhysicalDisk | ForEach-Object { $diskNames[[string]$_.DeviceId] = $_.FriendlyName } } catch { }
    function Get-DiskLabel([string]$inst) {
        $num = ($inst -split ' ')[0]
        if ($diskNames[$num]) { "$inst ($($diskNames[$num]))" } else { $inst }
    }

    # Thresholds for "this second was a stall"
    $T = @{
        LagMs       = 2000   # our own 1s timer fired this late -> the whole system was paused
        SampleMs    = 3000   # WMI sampling took this long -> system was unresponsive
        ProbeMs     = 500    # 4 KB write-through on system drive
        DiskMs      = 100    # avg read/write latency of any physical disk in the interval
        CpuPct      = 95     # with run queue > logical CPUs
        DpcIntPct   = 10     # total DPC+ISR time
        CoreDpcInt  = 50     # DPC+ISR time on a single core
        AvailPct    = 3      # available RAM
        CommitPct   = 95
    }

    # Raw perf classes: locale-independent, deltas computed here (formatted classes need a refresher)
    function Get-RawSample {
        [pscustomobject]@{
            Cpu  = @(Get-CimInstance Win32_PerfRawData_PerfOS_Processor)
            Sys  = Get-CimInstance Win32_PerfRawData_PerfOS_System
            Mem  = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
            Disk = @(Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' })
            Proc = @(Get-CimInstance Win32_PerfRawData_PerfProc_Process |
                     Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
                     Select-Object Name, IDProcess, PercentProcessorTime, IODataBytesPersec, Timestamp_Sys100NS)
        }
    }

    function Measure-Interval($a, $b) {
        $r = [ordered]@{}
        $ta = $a.Cpu | Where-Object Name -eq '_Total'; $tb = $b.Cpu | Where-Object Name -eq '_Total'
        $dt = [double]$tb.Timestamp_Sys100NS - [double]$ta.Timestamp_Sys100NS
        if ($dt -le 0) { $dt = 1 }
        $r.Cpu       = [math]::Max(0, [math]::Min(100, 100 * (1 - ([double]$tb.PercentProcessorTime - [double]$ta.PercentProcessorTime) / $dt)))
        $r.Dpc       = 100 * ([double]$tb.PercentDPCTime - [double]$ta.PercentDPCTime) / $dt
        $r.Interrupt = 100 * ([double]$tb.PercentInterruptTime - [double]$ta.PercentInterruptTime) / $dt
        $r.CoreDpcInt = 0; $r.Core = ''
        foreach ($cb in ($b.Cpu | Where-Object Name -ne '_Total')) {
            $ca = $a.Cpu | Where-Object Name -eq $cb.Name
            if (-not $ca) { continue }
            $cdt = [double]$cb.Timestamp_Sys100NS - [double]$ca.Timestamp_Sys100NS
            if ($cdt -le 0) { continue }
            $v = 100 * (([double]$cb.PercentDPCTime - [double]$ca.PercentDPCTime) + ([double]$cb.PercentInterruptTime - [double]$ca.PercentInterruptTime)) / $cdt
            if ($v -gt $r.CoreDpcInt) { $r.CoreDpcInt = $v; $r.Core = $cb.Name }
        }
        $r.Queue     = [int]$b.Sys.ProcessorQueueLength
        $r.AvailMB   = [double]$b.Mem.AvailableMBytes
        $r.CommitPct = 100 * [double]$b.Mem.CommittedBytes / [double]$b.Mem.CommitLimit
        $mdt = ([double]$b.Mem.Timestamp_PerfTime - [double]$a.Mem.Timestamp_PerfTime) / [double]$b.Mem.Frequency_PerfTime
        $r.PagesPerSec = if ($mdt -gt 0) { ([double]$b.Mem.PagesPersec - [double]$a.Mem.PagesPersec) / $mdt } else { 0 }

        $r.Disk = ''; $r.ReadMs = 0; $r.WriteMs = 0; $r.DiskQueue = 0
        foreach ($db in $b.Disk) {
            $da = $a.Disk | Where-Object Name -eq $db.Name
            if (-not $da) { continue }
            $f  = [double]$db.Frequency_PerfTime
            $rb = [double]$db.AvgDisksecPerRead_Base  - [double]$da.AvgDisksecPerRead_Base
            $wb = [double]$db.AvgDisksecPerWrite_Base - [double]$da.AvgDisksecPerWrite_Base
            $rms = if ($rb -gt 0) { 1000 * ([double]$db.AvgDisksecPerRead  - [double]$da.AvgDisksecPerRead)  / $f / $rb } else { 0 }
            $wms = if ($wb -gt 0) { 1000 * ([double]$db.AvgDisksecPerWrite - [double]$da.AvgDisksecPerWrite) / $f / $wb } else { 0 }
            if ([math]::Max($rms, $wms) -gt [math]::Max($r.ReadMs, $r.WriteMs)) { $r.Disk = $db.Name; $r.ReadMs = $rms; $r.WriteMs = $wms }
            if ([int]$db.CurrentDiskQueueLength -gt $r.DiskQueue) { $r.DiskQueue = [int]$db.CurrentDiskQueueLength }
        }

        # Per-process CPU (% of whole machine) and I/O in the interval
        $pa = @{}; foreach ($p in $a.Proc) { $pa["$($p.IDProcess)|$($p.Name)"] = $p }
        $r.Procs = foreach ($p in $b.Proc) {
            $q = $pa["$($p.IDProcess)|$($p.Name)"]
            if (-not $q) { continue }
            $pdt = [double]$p.Timestamp_Sys100NS - [double]$q.Timestamp_Sys100NS
            if ($pdt -le 0) { continue }
            [pscustomobject]@{
                Name = ($p.Name -replace '#\d+$','')
                Id   = $p.IDProcess
                Cpu  = 100 * ([double]$p.PercentProcessorTime - [double]$q.PercentProcessorTime) / $pdt / $logical
                IoMB = ([double]$p.IODataBytesPersec - [double]$q.IODataBytesPersec) / 1MB
            }
        }
        [pscustomobject]$r
    }

    function Format-Top($procs, $prop, $unit, $n = 3) {
        ($procs | Sort-Object $prop -Descending | Select-Object -First $n | Where-Object { $_.$prop -gt 0.05 } |
            ForEach-Object { $svc = $script:SvcByPidW[[int]$_.Id]; $nm = if ($svc) { "$($_.Name)[$svc]" } else { $_.Name }
                             [string]::Format($inv, '{0}({1}) {2:0.#}{3}', $nm, $_.Id, $_.$prop, $unit) }) -join ', '
    }
    $script:SvcByPidW = @{}
    try {
        Get-CimInstance Win32_Service | Where-Object { $_.ProcessId } |
            Group-Object ProcessId | ForEach-Object { $script:SvcByPidW[[int]$_.Name] = ($_.Group.Name -join ',') }
    } catch { }

    $csvW = New-Object System.IO.StreamWriter($watchCsv, $false, [System.Text.UTF8Encoding]::new($true))
    $csvW.AutoFlush = $true
    $csvW.WriteLine('Time,LagMs,SampleMs,ProbeMs,CpuPct,DpcPct,InterruptPct,MaxCoreDpcIntPct,RunQueue,AvailMB,CommitPct,PagesPerSec,WorstDisk,DiskReadMs,DiskWriteMs,MaxDiskQueue,TopCpu,TopIo,Reasons')

    $rows   = New-Object System.Collections.Generic.List[object]
    $stalls = New-Object System.Collections.Generic.List[object]
    $start  = Get-Date
    $end    = if ($Minutes -gt 0) { $start.AddMinutes($Minutes) } else { [datetime]::MaxValue }

    Write-Host ("StallScope watch: every {0}s {1}. Ctrl+C stops and still writes the summary." -f $interval,
        $(if ($Minutes -gt 0) { "for $Minutes min (until $($end.ToString('HH:mm:ss')))" } else { 'until Ctrl+C' })) -ForegroundColor Cyan
    Write-Host "Log: $watchCsv" -ForegroundColor Cyan

    $prev = Get-RawSample
    $sw   = [Diagnostics.Stopwatch]::StartNew()
    $tick = 0
    $lastStatus = Get-Date
    try {
        while ((Get-Date) -lt $end) {
            $tick++
            $planned = [double]$tick * $interval * 1000
            $wait = $planned - $sw.ElapsedMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
            $lag = [math]::Max(0, $sw.ElapsedMilliseconds - $planned)
            $now = Get-Date

            # 4 KB write-through probe: what an app saving a file would feel right now
            $probeMs = -1
            try {
                $p0 = $sw.ElapsedMilliseconds
                $fs = New-Object System.IO.FileStream($probeFile, [IO.FileMode]::Create, [IO.FileAccess]::Write,
                                                      [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
                $fs.Write($probeBuf, 0, $probeBuf.Length); $fs.Flush($true); $fs.Dispose()
                $probeMs = $sw.ElapsedMilliseconds - $p0
            } catch { }

            $s0  = $sw.ElapsedMilliseconds
            $cur = Get-RawSample
            $sampleMs = $sw.ElapsedMilliseconds - $s0
            $m = Measure-Interval $prev $cur
            $prev = $cur

            $reasons = New-Object System.Collections.Generic.List[string]
            if ($lag -gt $T.LagMs)            { $reasons.Add("STALL timer late $([int]$lag) ms") }
            if ($sampleMs -gt $T.SampleMs)    { $reasons.Add("STALL WMI sample $sampleMs ms") }
            if ($probeMs -gt $T.ProbeMs)      { $reasons.Add("DISK probe $probeMs ms") }
            if ([math]::Max($m.ReadMs, $m.WriteMs) -gt $T.DiskMs) {
                $reasons.Add([string]::Format($inv, 'DISK {0} r={1:0} w={2:0} ms', (Get-DiskLabel $m.Disk), $m.ReadMs, $m.WriteMs)) }
            if ($m.Cpu -gt $T.CpuPct -and $m.Queue -gt $logical) { $reasons.Add([string]::Format($inv, 'CPU {0:0}% queue {1}', $m.Cpu, $m.Queue)) }
            if (($m.Dpc + $m.Interrupt) -gt $T.DpcIntPct) { $reasons.Add([string]::Format($inv, 'DPC/ISR total {0:0.#}%', $m.Dpc + $m.Interrupt)) }
            if ($m.CoreDpcInt -gt $T.CoreDpcInt) { $reasons.Add([string]::Format($inv, 'DPC/ISR core {0} {1:0}%', $m.Core, $m.CoreDpcInt)) }
            if (100 * $m.AvailMB / $ramMB -lt $T.AvailPct) { $reasons.Add([string]::Format($inv, 'LOW RAM {0:0} MB free', $m.AvailMB)) }
            if ($m.CommitPct -gt $T.CommitPct) { $reasons.Add([string]::Format($inv, 'COMMIT {0:0}%', $m.CommitPct)) }

            $topCpu = Format-Top $m.Procs 'Cpu' '%'
            $topIo  = Format-Top $m.Procs 'IoMB' 'MB'
            $row = [pscustomobject]@{
                Time = $now; LagMs = $lag; SampleMs = $sampleMs; ProbeMs = $probeMs
                Cpu = $m.Cpu; Dpc = $m.Dpc; Interrupt = $m.Interrupt; CoreDpcInt = $m.CoreDpcInt; Queue = $m.Queue
                AvailMB = $m.AvailMB; CommitPct = $m.CommitPct; PagesPerSec = $m.PagesPerSec
                Disk = $m.Disk; ReadMs = $m.ReadMs; WriteMs = $m.WriteMs; DiskQueue = $m.DiskQueue
                TopCpu = $topCpu; TopIo = $topIo; Reasons = ($reasons -join '; ')
            }
            $rows.Add($row)
            $csvW.WriteLine([string]::Format($inv,
                '{0:yyyy-MM-dd HH:mm:ss},{1:0},{2},{3},{4:0.0},{5:0.00},{6:0.00},{7:0.0},{8},{9:0},{10:0.0},{11:0},"{12}",{13:0.0},{14:0.0},{15},"{16}","{17}","{18}"',
                $now, $lag, $sampleMs, $probeMs, $m.Cpu, $m.Dpc, $m.Interrupt, $m.CoreDpcInt, $m.Queue, $m.AvailMB, $m.CommitPct,
                $m.PagesPerSec, $m.Disk, $m.ReadMs, $m.WriteMs, $m.DiskQueue, $topCpu, $topIo, $row.Reasons))

            if ($reasons.Count -gt 0) {
                $stalls.Add($row)
                Write-Host ("[{0:HH:mm:ss}] {1}  | CPU: {2}  | IO: {3}" -f $now, $row.Reasons, $topCpu, $topIo) -ForegroundColor Yellow
            }
            if (((Get-Date) - $lastStatus).TotalSeconds -ge 60) {
                $lastStatus = Get-Date
                Write-Host ("[{0:HH:mm:ss}] {1} samples, {2} flagged" -f $lastStatus, $rows.Count, $stalls.Count) -ForegroundColor DarkGray
            }
            # After a long stall do not fire a burst of catch-up ticks
            $tick = [math]::Max($tick, [math]::Floor($sw.ElapsedMilliseconds / ($interval * 1000)))
        }
    } finally {
        $csvW.Dispose()
        Remove-Item -LiteralPath $probeFile -ErrorAction SilentlyContinue
        $stop = Get-Date

        Add-Header 'Watch mode summary'
        Add-Line ("Window: {0:yyyy-MM-dd HH:mm:ss} - {1:HH:mm:ss} ({2:N1} min), interval {3}s, {4} samples, {5} flagged" -f `
            $start, $stop, ($stop - $start).TotalMinutes, $interval, $rows.Count, $stalls.Count)
        Add-Line "Raw per-second data: $watchCsv"
        Add-Line ''
        Add-Line ('Thresholds: ' + (($T.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))

        Add-SubHeader 'Metric statistics (avg / p95 / max)'
        if ($rows.Count -gt 0) {
            $stat = {
                param($name, $prop, $fmt)
                $v = @($rows | ForEach-Object { [double]$_.$prop } | Sort-Object)
                $p95 = $v[[math]::Min($v.Count - 1, [math]::Floor($v.Count * 0.95))]
                [pscustomobject]@{
                    Metric = $name
                    Avg    = [string]::Format($inv, $fmt, ($v | Measure-Object -Average).Average)
                    P95    = [string]::Format($inv, $fmt, $p95)
                    Max    = [string]::Format($inv, $fmt, $v[-1])
                }
            }
            @(
                & $stat 'Timer lag, ms'            LagMs       '{0:0}'
                & $stat 'Disk probe (4KB WT), ms'  ProbeMs     '{0:0}'
                & $stat 'CPU, %'                   Cpu         '{0:0.0}'
                & $stat 'Run queue'                Queue       '{0:0}'
                & $stat 'DPC, %'                   Dpc         '{0:0.00}'
                & $stat 'Interrupt, %'             Interrupt   '{0:0.00}'
                & $stat 'Max core DPC+ISR, %'      CoreDpcInt  '{0:0.0}'
                & $stat 'Worst disk read, ms'      ReadMs      '{0:0.0}'
                & $stat 'Worst disk write, ms'     WriteMs     '{0:0.0}'
                & $stat 'Available RAM, MB'        AvailMB     '{0:0}'
                & $stat 'Commit, %'                CommitPct   '{0:0.0}'
                & $stat 'Pages/sec'                PagesPerSec '{0:0}'
            ) | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Add-Line $_.TrimEnd() }
        } else {
            Add-Line '(no samples)'
        }

        Add-SubHeader 'Stall episodes (consecutive flagged seconds merged)'
        if ($stalls.Count -eq 0) {
            Add-Line 'No stalls detected in this window. If a freeze happened while watching, note its time - it was'
            Add-Line 'below all thresholds (likely GPU/driver or app-level). Try a longer window or check the CSV around that time.'
        } else {
            $episodes = New-Object System.Collections.Generic.List[object]
            $cur = $null
            foreach ($s in $stalls) {
                # Generous gap: during a stall sampling itself slows down and seconds get skipped
                if ($cur -and ($s.Time - $cur.Last).TotalSeconds -le ($interval * 3 + 3)) {
                    $cur.Last = $s.Time; $cur.Rows.Add($s)
                } else {
                    $cur = [pscustomobject]@{ First = $s.Time; Last = $s.Time; Rows = (New-Object System.Collections.Generic.List[object]) }
                    $cur.Rows.Add($s); $episodes.Add($cur)
                }
            }
            Add-Line "$($episodes.Count) episode(s):"
            foreach ($e in $episodes) {
                $worst = $e.Rows | Sort-Object { $_.LagMs + $_.ProbeMs + [math]::Max($_.ReadMs, $_.WriteMs) } -Descending | Select-Object -First 1
                $kinds = ($e.Rows | ForEach-Object { $_.Reasons -split '; ' } | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique) -join '+'
                Add-Line ''
                $durSec = [int](($e.Last - $e.First).TotalSeconds) + $interval
                Add-Line ("[{0:HH:mm:ss} - {1:HH:mm:ss}] {2}s  {3}" -f $e.First, $e.Last, $durSec, $kinds)
                Add-Line "   worst second: $($worst.Time.ToString('HH:mm:ss')) :: $($worst.Reasons)"
                Add-Line "   top CPU:      $($worst.TopCpu)"
                Add-Line "   top I/O:      $($worst.TopIo)"
            }
            Add-Line ''
            Add-Line 'How to read: STALL = the whole system paused (even this script); DISK = storage stall, see which'
            Add-Line 'disk and which process did I/O; DPC/ISR = a driver hogging a core (GPU/network/audio/storage);'
            Add-Line 'CPU = saturation with a run queue; LOW RAM/COMMIT = memory pressure and paging.'
        }

        Add-SubHeader 'System log warnings/errors during the window'
        try {
            $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2,3; StartTime = $start } -ErrorAction SilentlyContinue
            if ($ev) {
                $ev | Sort-Object TimeCreated | Select-Object -First 50 | ForEach-Object {
                    $msg = if ($_.Message) { ($_.Message -replace "`r?`n",' ').Trim() } else { '' }
                    if ($msg.Length -gt 160) { $msg = $msg.Substring(0,160) + '...' }
                    Add-Line ("[{0:HH:mm:ss}] ID={1} {2} :: {3}" -f $_.TimeCreated, $_.Id, $_.ProviderName, $msg)
                }
            } else { Add-Line '(none)' }
        } catch { Add-Line "[ERROR]: $($_.Exception.Message)" }

        [System.IO.File]::WriteAllLines($watchTxt, $script:Lines, [System.Text.UTF8Encoding]::new($true))
        Write-Host ''
        Write-Host " Watch summary: $watchTxt" -ForegroundColor Green
        Write-Host " Per-second CSV: $watchCsv" -ForegroundColor Green
    }
    return
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
# Processes that legitimately hold many GB (leak checks report them at lower severity)
$script:ExpectedHeavy = 'java','idea64','vmmem','vmmemWSL','vmwp','sqlservr','devenv','chrome','msedge','firefox','MsMpEng','Memory Compression'

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
    $script:PoolTagsAll = $tags
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
# 8. TREND VS PREVIOUS RUN (leak growth)
# ==============================================================================
Add-Header '8. Trend vs previous run (what grew in between)'
Add-Line "Each run saves a snapshot (handles/memory per process, kernel pool tags) next to the report."
Add-Line "The next run compares against the latest snapshot of this host. Run again after a few hours."

$snapshotPath = Join-Path $desktop "StallScope-Snapshot_${hostName}_${stamp}.json"
$script:Snapshot      = $null
$script:TrendFindings = New-Object System.Collections.Generic.List[string]

function ConvertTo-Dt($v) {
    # PS 5.1 ConvertFrom-Json keeps ISO dates as strings, PS 7 turns them into DateTime
    if ($v -is [datetime]) { $v } else { [datetime]::Parse([string]$v, $null, [Globalization.DateTimeStyles]::RoundtripKind) }
}

Try-Run {
    $os = Get-CimInstance Win32_OperatingSystem
    $m  = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
    $tags = if ($script:PoolTagsAll) { $script:PoolTagsAll } else { [DiagPoolTags]::Query() }
    $script:Snapshot = [pscustomobject]@{
        Version        = 1
        Host           = $hostName
        Time           = (Get-Date).ToString('o')
        BootTime       = $os.LastBootUpTime.ToString('o')
        CommitMB       = [math]::Round($m.CommittedBytes/1MB)
        PagedPoolMB    = [math]::Round($m.PoolPagedBytes/1MB,1)
        NonPagedPoolMB = [math]::Round($m.PoolNonpagedBytes/1MB,1)
        Processes      = @(Get-Process | ForEach-Object {
            $st = try { $_.StartTime.ToString('o') } catch { '' }
            [pscustomobject]@{
                Key       = "$($_.Id)|$($_.Name)|$st"   # same PID + name + start time = same process instance
                Id        = $_.Id
                Label     = Get-ProcLabel $_
                Name      = $_.Name
                Handles   = $_.HandleCount
                PrivateMB = [math]::Round($_.PrivateMemorySize64/1MB,1)
                Threads   = $_.Threads.Count
            }
        })
        PoolTags       = @($tags | Where-Object { ($_.PagedUsed + $_.NonPagedUsed) -gt 1MB } | ForEach-Object {
            [pscustomobject]@{ Tag = $_.Tag; PagedMB = [math]::Round($_.PagedUsed/1MB,2); NonPagedMB = [math]::Round($_.NonPagedUsed/1MB,2) }
        })
    }

    $basePath = if ($Baseline) { $Baseline } else {
        Get-ChildItem $desktop -Filter "StallScope-Snapshot_${hostName}_*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $basePath -or -not (Test-Path -LiteralPath $basePath)) {
        Add-Line ''
        Add-Line "No previous snapshot found - this run becomes the baseline."
        return
    }
    $base  = Get-Content -LiteralPath $basePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $hours = ((Get-Date) - (ConvertTo-Dt $base.Time)).TotalHours
    Add-Line ''
    Add-Line "Baseline: $basePath"
    Add-Line ("Elapsed:  {0:N2} h" -f $hours)

    if ([math]::Abs(((ConvertTo-Dt $base.BootTime) - $os.LastBootUpTime).TotalMinutes) -gt 1) {
        Add-Line "System was rebooted after the baseline - growth comparison is meaningless. This run becomes the new baseline."
        return
    }
    if ($hours -lt 0.05) { Add-Line "Baseline is less than 3 minutes old - nothing to compare yet."; return }
    $confident = $hours -ge 0.25
    if (-not $confident) { Add-Line "Less than 15 min since baseline: deltas shown, but no findings raised (too noisy)." }

    Add-Line ''
    [pscustomobject]@{
        Commit_MB       = "{0} -> {1} ({2:+0;-0})" -f $base.CommitMB, $script:Snapshot.CommitMB, ($script:Snapshot.CommitMB - $base.CommitMB)
        PagedPool_MB    = "{0} -> {1} ({2:+0;-0})" -f $base.PagedPoolMB, $script:Snapshot.PagedPoolMB, ($script:Snapshot.PagedPoolMB - $base.PagedPoolMB)
        NonPagedPool_MB = "{0} -> {1} ({2:+0;-0})" -f $base.NonPagedPoolMB, $script:Snapshot.NonPagedPoolMB, ($script:Snapshot.NonPagedPoolMB - $base.NonPagedPoolMB)
    } | Format-List | Out-String | ForEach-Object { Add-Line $_.Trim() }

    # Processes alive in both snapshots
    $baseProc = @{}
    foreach ($p in $base.Processes) { $baseProc[$p.Key] = $p }
    $diff = @(foreach ($p in $script:Snapshot.Processes) {
        $b = $baseProc[$p.Key]
        if (-not $b) { continue }
        [pscustomobject]@{
            Process        = $p.Label
            Name           = $p.Name
            Id             = $p.Id
            Handles        = $p.Handles
            dHandles       = $p.Handles - $b.Handles
            'dHandles/h'   = [math]::Round(($p.Handles - $b.Handles) / $hours)
            PrivateMB      = $p.PrivateMB
            dPrivateMB     = [math]::Round($p.PrivateMB - $b.PrivateMB, 1)
            'dPrivateMB/h' = [math]::Round(($p.PrivateMB - $b.PrivateMB) / $hours, 1)
        }
    })

    Add-Line ''
    Add-Line "Top growth by handles (same process instance in both snapshots):"
    $g = $diff | Where-Object { $_.dHandles -gt 0 } | Sort-Object dHandles -Descending | Select-Object -First 10
    if ($g) { $g | Select-Object Process, Id, Handles, dHandles, 'dHandles/h' | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Add-Line $_.TrimEnd() } }
    else    { Add-Line '(nothing grew)' }

    Add-Line ''
    Add-Line "Top growth by private memory:"
    $g = $diff | Where-Object { $_.dPrivateMB -gt 0 } | Sort-Object dPrivateMB -Descending | Select-Object -First 10
    if ($g) { $g | Select-Object Process, Id, PrivateMB, dPrivateMB, 'dPrivateMB/h' | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Add-Line $_.TrimEnd() } }
    else    { Add-Line '(nothing grew)' }

    # Pool tags are case-sensitive
    $baseTag = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($t in $base.PoolTags) { $baseTag[$t.Tag] = $t }
    $tagDiff = @(foreach ($t in $script:Snapshot.PoolTags) {
        $b = $baseTag[$t.Tag]
        $bp = if ($b) { [double]$b.PagedMB } else { 0 }
        $bn = if ($b) { [double]$b.NonPagedMB } else { 0 }
        $d  = ($t.PagedMB - $bp) + ($t.NonPagedMB - $bn)
        [pscustomobject]@{
            Tag            = "'$($t.Tag)'"
            RawTag         = $t.Tag
            PagedMB        = $t.PagedMB
            dPagedMB       = [math]::Round($t.PagedMB - $bp, 1)
            NonPagedMB     = $t.NonPagedMB
            dNonPagedMB    = [math]::Round($t.NonPagedMB - $bn, 1)
            'dTotalMB/h'   = [math]::Round($d / $hours, 1)
            dTotal         = $d
        }
    })
    Add-Line ''
    Add-Line "Top growth by kernel pool tag:"
    $g = $tagDiff | Where-Object { $_.dTotal -gt 0.5 } | Sort-Object dTotal -Descending | Select-Object -First 10
    if ($g) { $g | Select-Object Tag, PagedMB, dPagedMB, NonPagedMB, dNonPagedMB, 'dTotalMB/h' | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Add-Line $_.TrimEnd() } }
    else    { Add-Line '(nothing grew)' }

    if (-not $confident) { return }
    $span = "{0:N1} h" -f $hours
    foreach ($d in $diff) {
        if ($d.dHandles -gt 2000 -and $d.'dHandles/h' -gt 1000) {
            $script:TrendFindings.Add("[HIGH] Handle leak in progress: $($d.Process) (PID $($d.Id)) +$($d.dHandles) handles in $span ($($d.'dHandles/h')/h), now $($d.Handles).")
        }
        if ($d.dPrivateMB -gt 500 -and $d.'dPrivateMB/h' -gt 200) {
            $sev = if ($script:ExpectedHeavy -contains $d.Name) { 'MED' } else { 'HIGH' }
            $script:TrendFindings.Add("[$sev] Memory growing: $($d.Process) (PID $($d.Id)) +$($d.dPrivateMB) MB in $span ($($d.'dPrivateMB/h') MB/h), now $($d.PrivateMB) MB.")
        }
    }
    foreach ($t in $tagDiff) {
        if ($t.dTotal -gt 100 -and $t.'dTotalMB/h' -gt 50) {
            $script:TrendFindings.Add("[HIGH] Kernel pool tag $($t.Tag) grew by $([math]::Round($t.dTotal)) MB in $span ($($t.'dTotalMB/h') MB/h). See owner in 'Kernel pool tags' (section 3).")
        }
    }
    foreach ($pool in 'PagedPoolMB','NonPagedPoolMB') {
        $d = $script:Snapshot.$pool - $base.$pool
        if ($d -gt 500 -and ($d / $hours) -gt 200) {
            $script:TrendFindings.Add("[HIGH] $pool grew by $([math]::Round($d)) MB in $span - kernel-side leak in progress.")
        }
    }
}

# ==============================================================================
# 9. REMOTE DESKTOP: exposure, logon attempts, TermService handles
# ==============================================================================
Add-Header '9. Remote Desktop (RDP)'
Add-Line "Incoming RDP connection attempts (e.g. password guessing from the internet) go through termsrv.dll and"
Add-Line "can leak Event handles in the TermService svchost: millions of handles -> kernel memory pressure -> stalls."

$script:RdpFindings = New-Object System.Collections.Generic.List[string]
function Test-PublicIp([string]$ip) {
    if ([string]::IsNullOrWhiteSpace($ip) -or $ip -eq '-') { return $false }
    -not ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|::1$|fe80:|fc|fd|0\.0\.0\.0|::$)')
}

if (-not ('DiagHandleTypes' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DiagHandleTypes {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr h, int cls, IntPtr buf, int len, out int ret);
    static Dictionary<int, string> TypeNames() {
        var map = new Dictionary<int, string>();
        int len = 0x10000;
        while (true) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret; int st = NtQueryObject(IntPtr.Zero, 3, buf, len, out ret);   // ObjectTypesInformation
                if (st == unchecked((int)0xC0000004)) { len = Math.Max(len * 2, ret); continue; }
                if (st != 0) return map;
                bool x64 = IntPtr.Size == 8;
                int n = Marshal.ReadInt32(buf);
                long p = buf.ToInt64() + IntPtr.Size;
                for (int i = 0; i < n; i++) {
                    IntPtr e = new IntPtr(p);
                    ushort nameLen = (ushort)Marshal.ReadInt16(e, 0), nameMax = (ushort)Marshal.ReadInt16(e, 2);
                    string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(e, x64 ? 8 : 4), nameLen / 2);
                    map[Marshal.ReadByte(e, x64 ? 90 : 82)] = name;                   // TypeIndex
                    long next = p + (x64 ? 104 : 96) + nameMax;
                    p = (next + IntPtr.Size - 1) / IntPtr.Size * IntPtr.Size;
                }
                return map;
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }
    // Handle count per object type for one process (SystemExtendedHandleInformation = 64)
    public static Dictionary<string, int> ByType(int pid) {
        var types = TypeNames();
        var res = new Dictionary<string, int>();
        int len = 0x1000000;
        while (true) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret; int st = NtQuerySystemInformation(64, buf, len, out ret);
                if (st == unchecked((int)0xC0000004)) { len = Math.Max(len * 2, ret + 0x100000); continue; }
                if (st != 0) throw new Exception("NtQuerySystemInformation(64) failed, NTSTATUS 0x" + st.ToString("X8"));
                long count = Marshal.ReadIntPtr(buf).ToInt64();
                int size = IntPtr.Size == 8 ? 40 : 28, first = IntPtr.Size * 2;
                for (long i = 0; i < count; i++) {
                    IntPtr e = new IntPtr(buf.ToInt64() + first + i * size);
                    if (Marshal.ReadIntPtr(e, IntPtr.Size).ToInt64() != pid) continue;
                    int idx = (ushort)Marshal.ReadInt16(e, IntPtr.Size * 3 + 6);
                    string t; if (!types.TryGetValue(idx, out t)) t = "#" + idx;
                    int c; res.TryGetValue(t, out c); res[t] = c + 1;
                }
                return res;
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@
}

Add-SubHeader 'RDP configuration'
$rdpPort = 3389
Try-Run {
    $ts  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    $tcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
    if ($tcp.PortNumber) { $script:RdpPortNum = [int]$tcp.PortNumber } else { $script:RdpPortNum = 3389 }
    [pscustomobject]@{
        RdpEnabled         = ($ts.fDenyTSConnections -eq 0)
        Port               = $script:RdpPortNum
        NLA                = ($tcp.UserAuthentication -eq 1)
        SecurityLayer      = $tcp.SecurityLayer
        MinEncryptionLevel = $tcp.MinEncryptionLevel
    } | Format-List
    Add-Line "Account lockout policy (net accounts):"
    # Last lines of 'net accounts' are lockout threshold/duration/window on any locale
    (net accounts 2>$null) | Where-Object { $_ -match ':' } | Select-Object -Last 4 | ForEach-Object { Add-Line "  $_" }
}
if ($script:RdpPortNum) { $rdpPort = $script:RdpPortNum }

Add-SubHeader 'Inbound firewall rules allowing the RDP port'
Try-Run {
    @(foreach ($f in (Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -contains [string]$rdpPort })) {
        $r = $f | Get-NetFirewallRule
        if ($r.Direction -ne 'Inbound' -or $r.Enabled -ne 'True' -or $r.Action -ne 'Allow') { continue }
        [pscustomobject]@{
            Rule          = $r.DisplayName
            Profile       = $r.Profile
            RemoteAddress = (($r | Get-NetFirewallAddressFilter).RemoteAddress -join ',')
        }
    }) | Format-Table -AutoSize -Wrap
}

Add-SubHeader 'Current TCP connections to the RDP port'
Try-Run {
    $conns = @(Get-NetTCPConnection -LocalPort $rdpPort -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Listen' })
    $pub = @($conns | Where-Object { Test-PublicIp $_.RemoteAddress })
    Add-Line "Total: $($conns.Count), from public addresses: $($pub.Count)"
    if ($conns) {
        $conns | Select-Object LocalAddress, RemoteAddress, RemotePort, State,
                               @{N='Public';E={ Test-PublicIp $_.RemoteAddress }} |
            Sort-Object Public -Descending | Select-Object -First 20 | Format-Table -AutoSize
    }
    if ($pub.Count -gt 0) {
        $script:RdpFindings.Add("[HIGH] RDP port $rdpPort is reachable from the internet: $($pub.Count) connection(s) from public addresses right now ($((($pub.RemoteAddress | Select-Object -Unique -First 5)) -join ', ')).")
    }
}

Add-SubHeader 'TermService handles by object type'
Try-Run {
    $tsPid = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
    if (-not $tsPid) { Add-Line "TermService is not running."; return }
    $p = Get-Process -Id $tsPid -ErrorAction SilentlyContinue
    Add-Line ("TermService PID {0}, started {1}, total handles {2}" -f $tsPid, $(try { $p.StartTime.ToString('yyyy-MM-dd HH:mm') } catch { '?' }), $p.HandleCount)
    $byType = [DiagHandleTypes]::ByType([int]$tsPid)
    $byType.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 |
        Select-Object @{N='Type';E={$_.Key}}, @{N='Handles';E={$_.Value}} | Format-Table -AutoSize
    $ev = [int]$byType['Event']
    if ($ev -gt 50000) {
        $script:RdpFindings.Add("[HIGH] TermService holds $ev Event handles (normal: a few hundred). Known pattern: Event objects leaked by termsrv/rdpcorets on incoming RDP connection attempts. Restarting TermService frees them; they grow back as long as the attempts continue.")
    }
}

Add-SubHeader "Failed network logons (Security 4625) in the last $EventLogDays days"
Try-Run {
    $oldest = (Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction SilentlyContinue).TimeCreated
    $logCfg = Get-WinEvent -ListLog Security -ErrorAction SilentlyContinue
    if ($oldest) {
        $coverH = ((Get-Date) - $oldest).TotalHours
        Add-Line ("Security log covers {0:N1} h (oldest event {1:yyyy-MM-dd HH:mm}), max size {2} MB" -f $coverH, $oldest, [math]::Round($logCfg.MaximumSizeInBytes/1MB))
        if ($coverH -lt 24 * [math]::Min(7, $EventLogDays)) {
            $script:RdpFindings.Add(("[MED] Security log keeps only {0:N1} h of history (max {1} MB) - older logon attempts cannot be checked." -f $coverH, [math]::Round($logCfg.MaximumSizeInBytes/1MB)))
        }
    }
    $fails = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $since } -MaxEvents 200000 -ErrorAction SilentlyContinue)
    # 4625 properties: [5] TargetUserName, [10] LogonType, [19] IpAddress (positional = locale-independent and fast)
    $rows = foreach ($e in $fails) {
        [pscustomobject]@{ Time = $e.TimeCreated; User = $e.Properties[5].Value; Type = $e.Properties[10].Value; Ip = [string]$e.Properties[19].Value }
    }
    $ext = @($rows | Where-Object { Test-PublicIp $_.Ip })
    Add-Line "Failed logons: $($fails.Count), from public addresses: $($ext.Count), distinct public IPs: $(($ext.Ip | Select-Object -Unique).Count)"
    if ($ext) {
        $hours = [math]::Max(0.1, (($ext | Measure-Object Time -Maximum).Maximum - ($ext | Measure-Object Time -Minimum).Minimum).TotalHours)
        Add-Line ("Rate: {0:N0} per hour" -f ($ext.Count / $hours))
        Add-Line ''
        Add-Line "Top source IPs:"
        $ext | Group-Object Ip | Sort-Object Count -Descending | Select-Object -First 10 |
            Select-Object Count, @{N='IP';E={$_.Name}},
                          @{N='Users tried';E={ ($_.Group.User | Select-Object -Unique -First 5) -join ', ' }},
                          @{N='Last';E={ ($_.Group | Measure-Object Time -Maximum).Maximum.ToString('MM-dd HH:mm') }} |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Add-Line $_.TrimEnd() }
        Add-Line "Top user names tried:"
        $ext | Group-Object User | Sort-Object Count -Descending | Select-Object -First 10 Count, @{N='User';E={$_.Name}} |
            Format-Table -AutoSize | Out-String | ForEach-Object { Add-Line $_.TrimEnd() }
        $existing = @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object Name)
        $hit = @($ext.User | Select-Object -Unique | Where-Object { $existing -contains $_ })
        if ($hit) { Add-Line "Attempted names that EXIST on this machine: $($hit -join ', ')" }
        if ($ext.Count -ge 100) {
            $script:RdpFindings.Add(("[HIGH] Password guessing over the network: {0} failed logons from {1} public IPs (~{2:N0}/h). Top: {3}." -f `
                $ext.Count, ($ext.Ip | Select-Object -Unique).Count, ($ext.Count / $hours),
                (($ext | Group-Object Ip | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')))
        }
        if ($hit) { $script:RdpFindings.Add("[HIGH] Guessed user names that exist on this machine: $($hit -join ', ').") }
    }
}

Add-SubHeader "Successful logons from public addresses (Security 4624) in the last $EventLogDays days"
Try-Run {
    $ok = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = $since } -ErrorAction SilentlyContinue)
    # 4624 properties: [5] TargetUserName, [8] LogonType, [18] IpAddress
    $ext = @(foreach ($e in $ok) {
        $ip = [string]$e.Properties[18].Value
        if (Test-PublicIp $ip) { [pscustomobject]@{ Time = $e.TimeCreated; User = $e.Properties[5].Value; LogonType = $e.Properties[8].Value; Ip = $ip } }
    })
    if ($ext) {
        $ext | Sort-Object Time -Descending | Select-Object -First 20 | Format-Table -AutoSize
        $script:RdpFindings.Add("[HIGH] $($ext.Count) successful logon(s) from public addresses: " + (($ext | Select-Object -First 3 | ForEach-Object { "$($_.Time.ToString('MM-dd HH:mm')) $($_.User)@$($_.Ip) type $($_.LogonType)" }) -join '; ') + ". Verify these were you.")
    } else {
        Add-Line "None (within the period the Security log still covers)."
    }
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
    Get-Process | Where-Object { $_.PrivateMemorySize64 -gt 4GB -and $script:ExpectedHeavy -notcontains $_.Name } | ForEach-Object {
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

# 15) Growth since the previous snapshot (section 8)
foreach ($f in $script:TrendFindings) { $findings.Add($f) }

# 16) Remote Desktop (section 9)
foreach ($f in $script:RdpFindings) { $findings.Add($f) }

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

# --- Save snapshot for the next run's trend comparison -----------------------
if ($script:Snapshot) {
    try {
        [System.IO.File]::WriteAllText($snapshotPath, ($script:Snapshot | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
        Write-Host " Snapshot saved: $snapshotPath (baseline for the next run)" -ForegroundColor Green
    } catch {
        Write-Host "Failed to write snapshot: $($_.Exception.Message)" -ForegroundColor Red
    }
}
