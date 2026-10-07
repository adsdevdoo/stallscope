# StallScope

**Find out why Windows freezes for 5-30 seconds and then recovers on its own.**

StallScope is a single PowerShell script that collects everything relevant to periodic system stalls
(disks, event log, drivers, power settings, memory, leaks, kernel pools) into one text report
and finishes with an auto-analysis of probable causes.

- Built-in Windows tools only: no installs, no WDK, no third-party binaries
- Works on non-English Windows (no locale-dependent performance counter paths)
- Read-only: it does not change any system settings
- Windows 10/11, Windows Server 2019/2022/2025

## Quick start

Open PowerShell **as Administrator** and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\StallScope.ps1
```

The report is saved to your Desktop as `StallScope-Report_<hostname>_<timestamp>.txt`.

Without admin rights SMART counters, the event log and kernel pool data come back empty.

Next to the report it saves `StallScope-Snapshot_<hostname>_<timestamp>.json`.
Run it again a few hours later and section 8 shows what grew in between (see [Trend vs previous run](#trend-vs-previous-run)).

### Catch a freeze while it happens

A one-shot report can miss a freeze that lasts seconds and happens at random. Watch mode samples the system
every second and records each moment where something stalls:

```powershell
powershell -ExecutionPolicy Bypass -File .\StallScope.ps1 -Watch -Minutes 60
```

Leave it running and keep working; when the freeze happens, the summary tells you what was going on at that second.
See [Watch mode](#watch-mode).

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-EventLogDays` | `7` | How many days of System/Application event log to analyze |
| `-Watch` | off | Watch mode instead of the one-shot report |
| `-Minutes` | `30` | Watch duration; `0` = until Ctrl+C |
| `-IntervalSec` | `1` | Watch sampling interval |
| `-Baseline` | latest snapshot | Snapshot JSON to compare against (default: the latest one of this host on the Desktop) |

```powershell
powershell -ExecutionPolicy Bypass -File .\StallScope.ps1 -EventLogDays 14
```

## What it checks

| # | Section | Details |
|---|---------|---------|
| 0 | System | OS, uptime, motherboard, BIOS, CPU, RAM |
| 1 | Disks | Health, SMART-like counters (temperature, errors, max read/write latency), free space, storage pools |
| 2 | Event log | Disk timeouts (129), controller errors (11), Kernel-Power (41), critical errors, storage provider events, BSODs and dump files |
| 3 | Resources | Top processes by CPU/RAM, **leak suspects**, **kernel pool tags**, third-party services, performance snapshot |
| 4 | Drivers | AMD chipset, NVMe/SATA/RAID controller drivers and versions |
| 5 | Power | Active plan, PCIe ASPM, disk idle timeout, CPU min/max state, USB selective suspend, sleep states |
| 6 | Memory | XMP/DOCP check (configured vs rated speed), voltage, totals |
| 7 | Temperatures | ACPI thermal zones, disk temperatures |
| 8 | Trend | Growth since the previous snapshot: handles and private memory per process, kernel pool tags, totals |

### Leak detection

Long-running machines often freeze not because of hardware, but because something slowly eats a shared resource.
StallScope looks for:

- **Handle leaks**: top processes by handle count; `svchost` is shown with the services it hosts
  (e.g. `svchost [TermService]`), so you know exactly which service to restart
- **Memory leaks**: background processes with several GB of private memory
- **Commit charge** close to the commit limit
- **Kernel pools** (paged / non-paged) above a threshold scaled to installed RAM

### Kernel pool tags

A built-in equivalent of `poolmon.exe`, based on `NtQuerySystemInformation(SystemPoolTagInformation)`.
For the top paged and non-paged tags it shows used memory, live allocations, and the owner:

- well-known Windows tags are labelled directly (`MmSt`, `File`, `Ntff`, `FMfn`, ...)
- other tags are matched against the binaries of currently loaded drivers
  (same idea as `findstr /m /l <tag> *.sys`)

Short or common tags can match several drivers, so treat the owners as candidates, not proof.

### Trend vs previous run

A single snapshot cannot tell a leak from a process that is simply big. Every run stores a compact JSON snapshot
(handles, threads and private memory per process instance, kernel pool tags, commit and pool totals);
the next run compares against the latest one and reports growth per hour:

```text
Process                         Id Handles dHandles dHandles/h
-------                         -- ------- -------- ----------
svchost [TermService]        91704   41200    37500      18750
```

- Processes are matched by PID + name + start time, so a restarted process is never compared with its predecessor
- If the machine was rebooted in between, the comparison is skipped and the run becomes the new baseline
- Findings are raised only when at least 15 minutes passed (shorter intervals are too noisy)

## Watch mode

`-Watch` samples every second, using raw performance classes (locale-independent):

| Signal | Flagged when | Meaning |
|--------|--------------|---------|
| Timer lag | the script's own 1 s timer fires > 2 s late | the whole system paused |
| WMI sample time | collecting one sample takes > 3 s | the system was unresponsive |
| Disk probe | a 4 KB write-through on the system drive takes > 500 ms | what an app saving a file feels |
| Disk latency | avg read/write of any physical disk > 100 ms | storage stall (disk named) |
| CPU | > 95% with run queue > logical CPUs | saturation |
| DPC/ISR | > 10% total or > 50% on a single core | a driver hogging a core (GPU, network, audio, storage) |
| Memory | available < 3% of RAM, commit > 95% | memory pressure |

For every flagged second it records the top processes by CPU and by I/O in that second
(`svchost` with its services). Output:

- `StallScope-Watch_<hostname>_<timestamp>.csv`: every sample, written live (survives a crash or Ctrl+C)
- `StallScope-Watch_<hostname>_<timestamp>.txt`: avg / p95 / max per metric, stall episodes (consecutive flagged
  seconds merged) with the worst second and its top processes, and System log warnings/errors during the window

```text
[16:55:54 - 16:56:00] 7s  STALL+CPU
   worst second: 16:55:54 :: STALL WMI sample 3741 ms; CPU 100% queue 205
   top CPU:      pwsh(47892) 95.8%, idea64(2920) 1.7%, chrome(7052) 0.5%
   top I/O:      chrome(7052) 6MB, chrome(15744) 5.2MB, chrome(28732) 0.9MB
```

If a freeze happened while watching but nothing was flagged, it stayed below all thresholds
(often GPU/driver or a single hung application): check the CSV around that time.

## Auto-analysis

At the end of the report every finding is tagged `[HIGH]`, `[MED]` or `[OK]`. It flags, among others:

- Event IDs 129 / 11 / 41
- Disks with non-Healthy status, or historical NVMe read latency > 500 ms
- Low free space on the system drive, high current disk latency
- XMP/DOCP disabled, power plan that enables aggressive power saving
- Processes with > 100k handles, background processes with > 4 GB private memory
- Commit charge > 85% of limit, oversized kernel pools, single pool tags > 500 MB
- Sustained CPU saturation
- Handles, private memory or pool tags growing since the previous snapshot

Example:

```text
[HIGH] Handle leak: svchost [TermService] (PID 1688) holds 5041618 handles (normal < 10k). Exhausts kernel memory and causes periodic stalls. Restart that process/service; if it is svchost, restart the service listed in brackets.
[HIGH] Memory leak suspect: logioptionsplus_agent (PID 14000) uses 24.2 GB private memory. Restart/update/uninstall it and watch whether it grows again.
[OK] Memory is running at rated speed.
```

The report also ends with a list of the most common fixes for the 5-30 second freeze symptom
(PCIe ASPM, disk idle timeout, power plan, chipset drivers, NVMe firmware, BIOS options, XMP stability).

## Notes

- Some checks and recommendations are tuned for AMD Ryzen platforms with NVMe drives; the rest is platform-neutral.
- On desktop AM4/AM5 boards ACPI thermal zones usually do not report real CPU temperature; use HWiNFO64 or Ryzen Master for that.
- Reports contain hardware details (models, serial numbers, installed software). Review them before sharing publicly.

## License

[MIT](LICENSE)
