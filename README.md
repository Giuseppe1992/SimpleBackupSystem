# SimpleBackupSystem (SBS)

Daily PowerShell 7 backup tool for Windows. It:

- Scans a folder (recursively) for document and image files.
- Filters by extensions defined in `config.json`.
- Builds a zip in `%TEMP%` named `Backup_yyyyMMdd_HHmmss.zip`, preserving
  the original subfolder structure inside the archive.
- Uploads the zip to an Azure Storage container.
- Deletes the local zip after a successful upload.
- Runs every day via Windows Task Scheduler, including catch-up runs after
  the machine has been off / asleep at the scheduled time.

## Requirements

- Windows 10 or 11
- [PowerShell 7](https://aka.ms/powershell) (`pwsh`) — must be installed
  manually before running anything else
- An Azure Storage account with a container (default name: `backup`)
- A SAS token with at least `Write, Add, Create` permission on Blob /
  Object resource types

The `Az.Storage` PowerShell module is **installed automatically** by
`Register-BackupTask.ps1` (CurrentUser scope, no admin needed). You can
also install it manually:

```powershell
Install-Module Az.Storage -Scope CurrentUser
```

### Admin rights

Admin is **not required** for the typical setup. Both the module install
(`-Scope CurrentUser`) and per-user scheduled-task registration run in
the user context. `Register-BackupTask.ps1` reports whether the session
is elevated in `setup.log`, so if a step fails (e.g. NuGet provider
install on a locked-down corporate machine) you'll have a clear hint
that you might need an elevated `pwsh`.

## Repository layout

| Path | Purpose | Committed? |
| --- | --- | --- |
| [Invoke-Backup.ps1](Invoke-Backup.ps1) | Backup logic: filter, zip, upload, cleanup | yes |
| [Register-BackupTask.ps1](Register-BackupTask.ps1) | Registers the daily Scheduled Task | yes |
| [Install-DevTools.ps1](Install-DevTools.ps1) | Installs `PSScriptAnalyzer` + `Pester` (dev only) | yes |
| [Invoke-Tests.ps1](Invoke-Tests.ps1) | Runs lint + Pester suite | yes |
| [tests/](tests/) | Pester unit tests | yes |
| [sample-source/](sample-source/) | Sample folder tree for smoke-testing the backup | yes |
| [config.json](config.json) | Non-secret settings | yes |
| [.env.example](.env.example) | Template for local `.env` | yes |
| `.env` | Holds `SOURCE_FOLDER`, `STORAGE_ACCOUNT`, `SAS_TOKEN` | **no** (gitignored) |
| `logs/` | Per-run backup logs (`backup_<timestamp>.log`) | **no** (gitignored) |
| `setup.log` | `Register-BackupTask.ps1` log | **no** (gitignored) |

## Configuration

Settings are split into two files. Anything machine-specific or sensitive
lives in `.env` (gitignored). Anything safe to share lives in `config.json`
(committed).

### `.env` (gitignored)

Copy `.env.example` to `.env` and fill in:

```dotenv
SOURCE_FOLDER=C:\Users\you\Documents
STORAGE_ACCOUNT=yourstorageaccount
SAS_TOKEN=?sv=2024-...&sig=...
```

The leading `?` on the SAS token is optional.

> **Cloud-synced source folders (OneDrive / iCloud / Dropbox / etc.)**
> If `SOURCE_FOLDER` lives in a cloud folder with "Files-on-Demand"
> enabled, online-only files (placeholder icons) are not physically on
> disk. Reading them during backup forces a hydration that may be slow,
> fail offline, or be skipped entirely. Before relying on the backup,
> mark the source folder and all subfolders as **"Always keep on this
> device"** (OneDrive: right-click → *Always keep on this device*).
> Otherwise some files may not end up in the zip.

### `config.json` (committed)

```json
{
  "Container":      "backup",
  "ScheduleTime":   "02:00",
  "FileExtensions": [".pdf", ".docx", ".xlsx", ".jpg", "..."]
}
```

- `Container` — the Azure Blob container name.
- `ScheduleTime` — `HH:mm` (24h) — when the daily task runs.
- `FileExtensions` — included extensions (case-insensitive, dot-prefixed).
- `ExcludePatterns` *(optional)* — glob patterns excluded even when their
  extension matches `FileExtensions`. Patterns containing `/` are matched
  against the relative path from `SourceFolder`; patterns without `/`
  match against the leaf filename only. Wildcards: `*` (any chars) and
  `?` (single char). Matching is case-insensitive.

  Examples:

  ```json
  "ExcludePatterns": [
    "*.bak",                 "// any .bak file"
    "Thumbs.db",             "// Thumbs.db at any depth"
    "build/*",               "// everything under top-level build/"
    "*/.cache/*",            "// any path containing /.cache/"
    "drafts/scratch.docx"    "// one specific file"
  ]
  ```

  (JSON has no comment syntax — strip the `// ...` parts in your real
  config.)

The file also contains empty `SourceFolder`, `StorageAccount` and
`SasToken` keys as optional fallbacks — see precedence below.

### Setting precedence

For `SOURCE_FOLDER`, `STORAGE_ACCOUNT`, and `SAS_TOKEN`:

1. If `.env` provides the value, that wins.
2. Otherwise, the corresponding `SourceFolder` / `StorageAccount` /
   `SasToken` from `config.json` is used.
3. If neither is set, the script fails with a clear error.

This means you can run without a `.env` (handy for quick local testing) —
but **never commit a `config.json` with real values for these three
fields**. They belong in `.env`.

## First run

```powershell
# 1. Set up secrets and config
Copy-Item .env.example .env
# ...edit .env (SOURCE_FOLDER, STORAGE_ACCOUNT, SAS_TOKEN) and
#    config.json (Container, ScheduleTime, FileExtensions)...

# 2. Register the daily Scheduled Task.
#    This also installs prerequisites (NuGet provider, Az.Storage)
#    for the current user. Logs to setup.log next to the script.
pwsh -File .\Register-BackupTask.ps1

# 3. (Optional) Test the backup once, manually
pwsh -File .\Invoke-Backup.ps1
```

A task named `SimpleBackupSystem` is created. Inspect with `taskschd.msc`
or:

```powershell
Get-ScheduledTask -TaskName SimpleBackupSystem | Get-ScheduledTaskInfo
```

### Register-BackupTask.ps1 parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-TaskName` | `SimpleBackupSystem` | Name of the scheduled task |
| `-WakeToRun` | off | Wake Windows from sleep at the scheduled time |
| `-SkipPrereqs` | off | Skip the NuGet / `Az.Storage` install step |
| `-EnableTaskHistory` | off | Turn on the system-wide Task Scheduler history event log so the History tab shows past results. Requires admin; safe to skip — the per-run files in `logs/` already capture run output. |

Examples:

```powershell
# Default registration
pwsh -File .\Register-BackupTask.ps1

# Wake the machine from sleep to run the backup
pwsh -File .\Register-BackupTask.ps1 -WakeToRun

# Re-register without re-checking modules
pwsh -File .\Register-BackupTask.ps1 -SkipPrereqs

# Also enable Task Scheduler history (run from an elevated pwsh)
pwsh -File .\Register-BackupTask.ps1 -WakeToRun -EnableTaskHistory
```

### Invoke-Backup.ps1 parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ConfigPath` | `./config.json` | Path to `config.json` |
| `-EnvPath` | `./.env` | Path to `.env` |
| `-LogDirectory` | `./logs` | Directory for per-run log files |
| `-LogRetentionDays` | `30` | Delete log files older than this many days at the start of each run. Pass `0` to disable pruning. |

## Behavior on missed runs and sleep

The task is registered with `-StartWhenAvailable`, so if the machine is
off or unavailable at the scheduled time, Windows fires the task as soon
as the machine is back online and the user is logged in. You will not
silently skip a day because the laptop was shut.

For sleep specifically:

- **Default**: if Windows is asleep at the scheduled time, the task does
  not fire until the next wake; combined with `-StartWhenAvailable` it
  catches up on the next wake.
- **With `-WakeToRun`**: Windows wakes from sleep at the scheduled time
  to run the backup. This is per-task and does not change global power
  settings; the device must support and have wake-from-sleep enabled in
  BIOS/firmware (most modern PCs do).

## Logs

Each run writes its own file under `logs/`, named
`backup_<yyyy-MM-dd_HH-mm-ss>.log`. At the start of every run, files older
than `-LogRetentionDays` (default 30 days) are pruned. On failure the
script exits non-zero so the Scheduled Task history shows the error
(if you've enabled it via `-EnableTaskHistory`).

## Development

Unit tests live in [tests/](tests/) and use [Pester](https://pester.dev) 5+
with [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
for lint.

```powershell
# Once per machine — installs PSScriptAnalyzer + Pester (CurrentUser scope)
pwsh -File .\Install-DevTools.ps1

# Run lint + all tests
pwsh -File .\Invoke-Tests.ps1

# Lint only / tests only
pwsh -File .\Invoke-Tests.ps1 -SkipPester
pwsh -File .\Invoke-Tests.ps1 -SkipAnalyzer
```

[sample-source/](sample-source/) is a pre-built folder tree (17 files at
depths 0–3, mix of matching and non-matching extensions) you can point
`SOURCE_FOLDER` at to smoke-test `Invoke-Backup.ps1` without touching real
data.

## Removing the task

```powershell
Unregister-ScheduledTask -TaskName SimpleBackupSystem -Confirm:$false
```

## Security notes

- `.env` and `*.log` are gitignored.
- The SAS token is the only secret. Use a token with **only** the
  permissions needed (Write/Add/Create), set an expiry, and rotate it.
- If you ever paste a token into `config.json`, rotate it before the
  first commit.
