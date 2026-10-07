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

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-EventLogDays` | `7` | How many days of System/Application event log to analyze |

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

## Auto-analysis

At the end of the report every finding is tagged `[HIGH]`, `[MED]` or `[OK]`. It flags, among others:

- Event IDs 129 / 11 / 41
- Disks with non-Healthy status, or historical NVMe read latency > 500 ms
- Low free space on the system drive, high current disk latency
- XMP/DOCP disabled, power plan that enables aggressive power saving
- Processes with > 100k handles, background processes with > 4 GB private memory
- Commit charge > 85% of limit, oversized kernel pools, single pool tags > 500 MB
- Sustained CPU saturation

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
