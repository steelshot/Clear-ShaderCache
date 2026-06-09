<#
.SYNOPSIS
    Manages a boot task that empties GPU shader caches (DirectX/OpenGL/Vulkan) for all users.

.DESCRIPTION
    -CreateTask                Create the task in a disabled state.
    -ToggleTask                Enable the task if disabled, disable it if enabled.
    -DeleteTask                Fully unregister the task.
    -PrintStatus               Report whether the task exists, is enabled/disabled, and its run info.
    -CreateDesktopShortcuts    (Re)create the desktop shortcuts for the current user.
    -RunTaskAction             Empty the caches, write a log file, and disable the task (one-off run).

    The task runs as NT AUTHORITY\SYSTEM at startup, before user logon, so the cache
    files are not locked by user-mode GPU processes.

.NOTES
    Works on PowerShell 7 (pwsh) or Windows PowerShell 5.1; it reuses whichever
    engine launches it. Most modes self-elevate if needed.

    Vendor cache roots searched:
      AppData\Local    - NVIDIA\*Cache*, AMD\*Cache*, D3DSCache
      AppData\LocalLow - Intel\*Cache*, AMD\*Cache*

    Copyright (c) 2026 Džiugas Eiva. Licensed under the MIT License (see LICENSE).
#>

[CmdletBinding(DefaultParameterSetName = 'ToggleTask')]
param(
    # Create the task in a disabled state.
    [Parameter(ParameterSetName = 'CreateTask')]
    [switch]$CreateTask,

    # Enable the task if disabled, disable it if enabled.
    [Parameter(ParameterSetName = 'ToggleTask')]
    [switch]$ToggleTask,

    # Fully unregister the task.
    [Parameter(ParameterSetName = 'DeleteTask')]
    [switch]$DeleteTask,

    # Report the task's status.
    [Parameter(ParameterSetName = 'PrintStatus')]
    [switch]$PrintStatus,

    # (Re)create the desktop shortcuts for the current user.
    [Parameter(ParameterSetName = 'CreateDesktopShortcuts')]
    [switch]$CreateDesktopShortcuts,

    # Empty the caches, then disable the task. Invoked by the task at boot.
    [Parameter(ParameterSetName = 'RunTaskAction')]
    [switch]$RunTaskAction,

    # Wait for a keypress before the window closes (used by the desktop shortcuts).
    [switch]$Pause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


# --- Constants -------------------------------------------------------------

$TaskName        = 'EmptyGpuCacheAtBoot'
$TaskDescription = 'Empties GPU DirectX/OpenGL/Vulkan shader caches for all users at boot, then disables itself.'

# Log file written by -RunTaskAction. The boot run is hidden and runs as SYSTEM, so this
# file is the way to review what the cleanup did.
$LogPath         = Join-Path $env:ProgramData 'ShaderCacheCleanup\last-run.log'

# Resolve the absolute path to this script so the task can re-invoke it.
$ScriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    throw 'Unable to resolve the script path. Run this file directly (not piped to stdin).'
}


# --- Helpers ---------------------------------------------------------------

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PwshPath {
    # Prefer the full path of the engine currently running this script, so the
    # task and shortcuts reuse exactly the same host (pwsh or powershell). That
    # path is guaranteed to exist because it is the process executing right now.
    $self = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($self)) { return $self }

    # Fallback (only if the host path is unavailable): prefer pwsh, else fall
    # back to Windows PowerShell, which is always present on Windows.
    foreach ($candidate in 'pwsh.exe', 'powershell.exe') {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Invoke-SelfElevation {
    # Re-launch this script elevated, forwarding the original arguments.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    $argList += @('-File', $ScriptPath)

    if ($CreateTask)    { $argList += '-CreateTask' }
    if ($ToggleTask)    { $argList += '-ToggleTask' }
    if ($DeleteTask)    { $argList += '-DeleteTask' }
    if ($PrintStatus)   { $argList += '-PrintStatus' }
    if ($RunTaskAction) { $argList += '-RunTaskAction' }
    if ($Pause)         { $argList += '-Pause' }

    Write-Host 'Elevation required - relaunching as administrator...' -ForegroundColor Yellow
    Start-Process -FilePath (Get-PwshPath) -ArgumentList $argList -Verb RunAs | Out-Null
}

function Wait-ForKey {
    # Hold the window open until a key is pressed (used by the desktop shortcuts).
    Write-Host ''
    Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
    [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}


# --- Cleanup ---------------------------------------------------------------

function Clear-GpuCaches {
    # Patterns (relative to each user's %LocalAppData%) where we search for cache
    # subdirectories and empty their contents. '*Cache*' captures DXCache / GLCache /
    # VkCache / NV_Cache, etc.
    $subDirPatterns = @(
        'NVIDIA\*Cache*'
        'AMD\*Cache*'
    )

    # Patterns (relative to each user's %LocalAppData%\..\LocalLow). Intel stores its
    # shader cache under AppData\LocalLow, not AppData\Local. AMD also stores a DxCache
    # directory under AppData\LocalLow.
    $subDirPatternsLow = @(
        'Intel\*Cache*'
        'AMD\*Cache*'
    )

    # Directories (relative to each user's %LocalAppData%) to empty directly - their
    # contents (files and subdirs) are removed without searching for subdirs first.
    # D3DSCache stores .idx/.blob files directly on most systems, so it must be treated
    # as a cache root rather than a parent that contains named cache subdirectories.
    $directDirs = @(
        'D3DSCache'
    )

    # Start a fresh log each run so it always reflects the latest cleanup.
    $log = [System.Collections.Generic.List[string]]::new()
    $log.Add("GPU shader cache cleanup - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

    $usersRoot = Join-Path $env:SystemDrive 'Users'
    $profiles  = Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue

    $removedCount = 0
    $skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($userProfile in $profiles) {
        $localAppData    = Join-Path $userProfile.FullName 'AppData\Local'
        $localAppDataLow = Join-Path $userProfile.FullName 'AppData\LocalLow'
        if (-not (Test-Path -LiteralPath $localAppData)) { continue }

        # --- Vendor cache subdirectories (NVIDIA, AMD) - AppData\Local ---
        foreach ($pattern in $subDirPatterns) {
            $cacheDirs = Get-ChildItem -Path (Join-Path $localAppData $pattern) -Directory -ErrorAction SilentlyContinue

            foreach ($cacheDir in $cacheDirs) {
                # Empty the directory's contents but leave the directory itself in place.
                $items = Get-ChildItem -LiteralPath $cacheDir.FullName -Force -ErrorAction SilentlyContinue

                foreach ($item in $items) {
                    try {
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                        $removedCount++
                    }
                    catch {
                        $skipped.Add($item.FullName)
                        Write-Warning "Skipped (in use or protected): $($item.FullName)"
                    }
                }

                $log.Add("Emptied: $($cacheDir.FullName)")
                Write-Host "Emptied: $($cacheDir.FullName)" -ForegroundColor DarkGray
            }
        }

        # --- Vendor cache subdirectories (Intel) - AppData\LocalLow ---
        if (Test-Path -LiteralPath $localAppDataLow) {
            foreach ($pattern in $subDirPatternsLow) {
                $cacheDirs = Get-ChildItem -Path (Join-Path $localAppDataLow $pattern) -Directory -ErrorAction SilentlyContinue

                foreach ($cacheDir in $cacheDirs) {
                    $items = Get-ChildItem -LiteralPath $cacheDir.FullName -Force -ErrorAction SilentlyContinue

                    foreach ($item in $items) {
                        try {
                            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                            $removedCount++
                        }
                        catch {
                            $skipped.Add($item.FullName)
                            Write-Warning "Skipped (in use or protected): $($item.FullName)"
                        }
                    }

                    $log.Add("Emptied: $($cacheDir.FullName)")
                    Write-Host "Emptied: $($cacheDir.FullName)" -ForegroundColor DarkGray
                }
            }
        }

        # --- Direct cache roots (D3DSCache) ---
        foreach ($rel in $directDirs) {
            $cacheDir = Join-Path $localAppData $rel
            if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) { continue }

            $items = Get-ChildItem -LiteralPath $cacheDir -Force -ErrorAction SilentlyContinue

            foreach ($item in $items) {
                try {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
                catch {
                    $skipped.Add($item.FullName)
                    Write-Warning "Skipped (in use or protected): $($item.FullName)"
                }
            }

            $log.Add("Emptied: $cacheDir")
            Write-Host "Emptied: $cacheDir" -ForegroundColor DarkGray
        }
    }

    $log.Add("Items removed: $removedCount")
    $log.Add("Items skipped: $($skipped.Count)")
    if ($skipped.Count -gt 0) {
        $log.Add('--- Skipped (in use or protected) ---')
        $log.AddRange($skipped)
    }

    # Write the log file so the run can be reviewed later.
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Set-Content -LiteralPath $LogPath -Value $log -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write log to '$LogPath': $($_.Exception.Message)"
    }

    Write-Host "GPU cache cleanup complete. Removed: $removedCount, skipped: $($skipped.Count)." -ForegroundColor Green
    Write-Host "Log: $LogPath" -ForegroundColor DarkGray
}


# --- Task management -------------------------------------------------------

function Register-CleanupTask {
    $action = New-ScheduledTaskAction -Execute (Get-PwshPath) `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -RunTaskAction"

    # Earliest practical point at boot, no random/extra delay.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT0S'

    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -Compatibility Win8 `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $settings.Priority = 4  # higher-than-default priority for an early-boot run
    $settings.Enabled  = $false  # created disabled; enable it with -ToggleTask

    Register-ScheduledTask -TaskName $TaskName `
        -Description $TaskDescription `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-Host "Created task '$TaskName' in a disabled state." -ForegroundColor Green
    Write-Host "  -> Run -ToggleTask to enable it for the next startup." -ForegroundColor Cyan
}

function Remove-CleanupTask {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Deleted task '$TaskName'." -ForegroundColor Yellow
        return $true
    }

    Write-Host "Task '$TaskName' does not exist - nothing to delete." -ForegroundColor DarkGray
    return $false
}

function Get-TaskScriptPath {
    # Extract the script path passed via -File "..." in the task's action arguments.
    param($Task)

    foreach ($action in $Task.Actions) {
        $arguments = $action.Arguments
        if ([string]::IsNullOrWhiteSpace($arguments)) { continue }
        if ($arguments -match '-File\s+"([^"]+)"') { return $Matches[1] }
        if ($arguments -match '-File\s+(\S+)')     { return $Matches[1] }
    }
    return $null
}


# --- Desktop shortcuts -----------------------------------------------------

function Set-LnkRunAsAdmin {
    # Flip the "Run as administrator" flag (byte 0x15, bit 0x20) in the .lnk header.
    param([string]$LnkPath)

    $bytes = [System.IO.File]::ReadAllBytes($LnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($LnkPath, $bytes)
}

function New-DesktopShortcut {
    param(
        [string]$Path,
        [string]$Arguments,
        [string]$Description,
        [switch]$RunAsAdmin
    )

    $pwshExe = Get-PwshPath

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath       = $pwshExe
    $sc.Arguments        = $Arguments
    $sc.WorkingDirectory = Split-Path -Path $ScriptPath -Parent
    $sc.IconLocation     = "$pwshExe,0"
    $sc.Description      = $Description
    $sc.Save()

    if ($RunAsAdmin) { Set-LnkRunAsAdmin -LnkPath $Path }
}

function New-DesktopShortcuts {
    # Username/machine agnostic: resolves the current user's Desktop and this script's
    # own location at runtime, so the shortcuts are correct wherever they are generated.
    $desktop = [Environment]::GetFolderPath('Desktop')
    $common  = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    # Remove the legacy (un-suffixed) toggle shortcut if it exists.
    $legacyLnk = Join-Path $desktop 'Clear Shader Cache.lnk'
    if (Test-Path -LiteralPath $legacyLnk) { Remove-Item -LiteralPath $legacyLnk -Force }

    $toggleLnk = Join-Path $desktop 'Clear Shader Cache (Toggle).lnk'
    New-DesktopShortcut -Path $toggleLnk -Arguments "$common -ToggleTask -Pause" `
        -Description 'Toggle (enable/disable) the GPU shader cache cleanup boot task' -RunAsAdmin

    $statusLnk = Join-Path $desktop 'Clear Shader Cache (Status).lnk'
    New-DesktopShortcut -Path $statusLnk -Arguments "$common -PrintStatus -Pause" `
        -Description 'Show GPU shader cache cleanup task status' -RunAsAdmin

    Write-Host "Created desktop shortcuts in: $desktop" -ForegroundColor Green
    Write-Host "  $toggleLnk   (run as admin - toggle)"
    Write-Host "  $statusLnk   (run as admin - status)"
}


# --- Status ----------------------------------------------------------------

function Show-CleanupTaskStatus {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$TaskName' is NOT registered." -ForegroundColor Yellow
        Write-Host "  -> Run -CreateTask to create it, then -ToggleTask to enable it." -ForegroundColor Cyan
        Write-Host "  This script: $ScriptPath"
        return
    }

    $enabled = [bool]$task.Settings.Enabled
    if ($enabled) {
        Write-Host "Task '$TaskName' is registered and ENABLED." -ForegroundColor Green
    }
    else {
        Write-Host "Task '$TaskName' is registered and DISABLED." -ForegroundColor Yellow
    }

    # Labels are padded to a common width so all the colons line up.
    Write-Host "  State    : $($task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue

    # An AtStartup task has no scheduled time, so show 'At next boot' when enabled
    # and 'N/A' when disabled, rather than a blank value.
    if (-not $enabled) {
        $nextRun = 'N/A'
    }
    elseif ($info -and $info.NextRunTime) {
        $nextRun = $info.NextRunTime
    }
    else {
        $nextRun = 'At next boot'
    }
    Write-Host "  Next run : $nextRun"
    if ($info) {
        Write-Host "  Last run : $($info.LastRunTime)  (result: $($info.LastTaskResult))"
    }

    # Show the script the task is wired to run, and whether it actually exists there.
    $taskScript = Get-TaskScriptPath -Task $task
    if (-not $taskScript) {
        Write-Host "  Script   : (could not parse the script path from the task action)" -ForegroundColor Red
        return
    }

    if (Test-Path -LiteralPath $taskScript -PathType Leaf) {
        Write-Host "  Script   : $taskScript  [found]" -ForegroundColor Green
    }
    else {
        Write-Host "  Script   : $taskScript  [NOT FOUND]" -ForegroundColor Red
        Write-Host "  -> The task points to a missing script. Re-run -CreateTask from the current location to fix it." -ForegroundColor Red
    }

    # Show where the last cleanup's log lives (lists any skipped/locked items).
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        Write-Host "  Last log : $LogPath" -ForegroundColor Cyan
    }
}


# --- Entry point -----------------------------------------------------------

try {
    if ($CreateDesktopShortcuts) {
        # Writes to the current user's Desktop; no elevation required.
        New-DesktopShortcuts
        return
    }

    if (-not (Test-IsAdministrator)) {
        # Everything below (including -PrintStatus, since the SYSTEM task can't be
        # read without elevation) needs admin rights. The elevated copy handles the
        # keypress pause, so don't pause this launcher window.
        Invoke-SelfElevation
        $Pause = $false
        return
    }

    if ($CreateTask) {
        # Create the task in a disabled state. -Force re-creates it if it already exists.
        Register-CleanupTask
        return
    }

    if ($DeleteTask) {
        [void](Remove-CleanupTask)
        return
    }

    if ($PrintStatus) {
        Show-CleanupTaskStatus
        return
    }

    if ($RunTaskAction) {
        # Empty the caches, then disable the task so it runs only once per enable.
        Clear-GpuCaches
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        return
    }

    if ($ToggleTask) {
        # Toggle the existing task between enabled and disabled. If it does not exist yet,
        # tell the user to run -CreateTask first.
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        switch ($true) {
            (-not $task) {
                Write-Host "Task '$TaskName' is NOT registered." -ForegroundColor Yellow
                Write-Host "  -> Run -CreateTask to create it first." -ForegroundColor Cyan
                break
            }
            (-not [bool]$task.Settings.Enabled) {
                Enable-ScheduledTask -TaskName $TaskName | Out-Null
                Write-Host ''
                Write-Host "Enabled task '$TaskName'." -ForegroundColor Green
                Write-Host "  -> It WILL run at the next startup." -ForegroundColor Cyan
                Write-Host ''
                break
            }
            default {
                Disable-ScheduledTask -TaskName $TaskName | Out-Null
                Write-Host ''
                Write-Host "Disabled task '$TaskName'." -ForegroundColor Yellow
                Write-Host "  -> It will NOT run at the next startup." -ForegroundColor Cyan
                Write-Host ''
            }
        }
        return
    }

    # No switch supplied: print the available actions.
    Write-Host 'Clear Shader Cache - available actions:' -ForegroundColor Cyan
    Write-Host '  -CreateTask                Create the task in a disabled state.'
    Write-Host '  -ToggleTask                Enable the task if disabled, disable it if enabled.'
    Write-Host '  -DeleteTask                Fully unregister the task.'
    Write-Host '  -PrintStatus               Show the task status.'
    Write-Host '  -CreateDesktopShortcuts    (Re)create the desktop shortcuts.'
}
finally {
    if ($Pause) { Wait-ForKey }
}
