# Clear Shader Cache (Windows 10/11)

## What this is and how it works

A tiny PowerShell tool that empties GPU **DirectX / OpenGL / Vulkan** shader caches for
**all users**. It registers a one-off `AtStartup` task that runs as `NT AUTHORITY\SYSTEM`
before you log in, so the cache files aren't locked and can be deleted without having to
boot into Safe Mode. After the clean-up the task disables itself — it only runs again
when you re-enable it with `-ToggleTask`.

It cleans these folders' **contents** (the folders themselves are kept) under every
`C:\Users\*\AppData\Local\` and `C:\Users\*\AppData\LocalLow\`:

| Folder | Root |
|--------|------|
| `NVIDIA\*Cache*` | `AppData\Local` |
| `AMD\*Cache*` | `AppData\Local` |
| `Intel\*Cache*` | `AppData\LocalLow` |
| `AMD\*Cache*` | `AppData\LocalLow` |
| `D3DSCache` | `AppData\Local` |

## Requirements

- **Windows 10 or 11**

> [!NOTE]
> **PowerShell 7 (`pwsh`)** is used by default when it's installed; otherwise the built-in
> Windows PowerShell is used.

## Install

1. Download the **Source code (zip)** from the [latest release](https://github.com/steelshot/Clear-ShaderCache/releases/latest) and extract it (keep `install.bat` and `Clear-ShaderCache.ps1` in the **same folder**).
2. Double-click **`install.bat`** and accept the UAC prompt.

It copies the script to `C:\Clear-ShaderCache.ps1`, creates the boot task (disabled), and
adds two desktop shortcuts. Enable the task with the **Clear Shader Cache (Toggle)**
shortcut (or `-ToggleTask`) when you want it to run at the next boot.

## Usage

After install you get two desktop shortcuts:

| Shortcut                        | What it does                                                                                  | Admin |
|---------------------------------|-----------------------------------------------------------------------------------------------|:-----:|
| **Clear Shader Cache (Toggle)** | Toggles the boot task: **enable** it, or **disable** it if already enabled.                   |   ✔   |
| **Clear Shader Cache (Status)** | Shows whether the task is enabled/disabled, next/last run, the script path, and the last log. |   ✔   |

Or run the script directly:

```powershell
# Create the task in a disabled state
powershell -File C:\Clear-ShaderCache.ps1 -CreateTask

# Enable if disabled, disable if enabled
powershell -File C:\Clear-ShaderCache.ps1 -ToggleTask

# Fully remove (unregister) the task
powershell -File C:\Clear-ShaderCache.ps1 -DeleteTask

# Show status
powershell -File C:\Clear-ShaderCache.ps1 -PrintStatus

# (Re)create the desktop shortcuts for the current user
powershell -File C:\Clear-ShaderCache.ps1 -CreateDesktopShortcuts

# Empty the caches now, then disable the task (this is what the task runs at boot)
powershell -File C:\Clear-ShaderCache.ps1 -RunTaskAction

# If you have PowerShell 7, you can use 'pwsh' instead of 'powershell' above
```


## Logs

Each clean-up writes a fresh log to:

```
C:\ProgramData\ShaderCacheCleanup\last-run.log
```

It records the emptied folders, how many items were removed, and the full paths of any
files that were skipped (in use / protected). `-PrintStatus` prints the log path when one
exists.

## Uninstall

```powershell
powershell -File C:\Clear-ShaderCache.ps1 -DeleteTask   # remove the scheduled task
```

Then delete `C:\Clear-ShaderCache.ps1`, the `C:\ProgramData\ShaderCacheCleanup` folder, and
the two desktop shortcuts.

## Safety notes

- Only **contents** of the listed cache folders are removed; the folders stay. GPU drivers
  rebuild these caches automatically.
- Items that are somehow still locked are skipped (and logged) instead of aborting.
- Public/Default profiles are matched by the `C:\Users\*` glob but are normally empty.
