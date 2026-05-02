#requires -Version 7.0
<#
.SYNOPSIS
  Installs prerequisites and registers (or replaces) a Windows Scheduled
  Task that runs Invoke-Backup.ps1 daily at the time specified in
  config.json.

.DESCRIPTION
  Steps performed:
    1. Logs the run to setup.log next to this script.
    2. Reports whether the current session is elevated (admin is NOT
       normally required, but is reported in case a step fails).
    3. Ensures the NuGet package provider and Az.Storage module are
       installed for the current user (no admin needed).
    4. Loads config.json + .env, validates required keys.
    5. Locates pwsh.exe.
    6. Registers the daily Scheduled Task with -StartWhenAvailable so a
       missed run (machine off / asleep at the scheduled time) fires as
       soon as the machine is back. With -WakeToRun, Windows wakes from
       sleep at the scheduled time to run the backup.

.PARAMETER TaskName
  Name of the scheduled task. Default: 'SimpleBackupSystem'.

.PARAMETER ConfigPath
  Path to config.json (used to read ScheduleTime / fallback values).

.PARAMETER EnvPath
  Path to .env (SOURCE_FOLDER, STORAGE_ACCOUNT, SAS_TOKEN).

.PARAMETER ScriptPath
  Path to Invoke-Backup.ps1.

.PARAMETER WakeToRun
  When set, the Scheduled Task is configured with the "Wake the computer
  to run this task" flag, so Windows wakes from sleep at the scheduled
  time. Without this flag, sleep blocks the run until the machine is
  woken normally — combined with -StartWhenAvailable, the task fires
  on the next wake.

.PARAMETER SkipPrereqs
  Skip prerequisite installation. Use if you've already set up modules.

.PARAMETER EnableTaskHistory
  Enables the system-wide Task Scheduler History event log
  ('Microsoft-Windows-TaskScheduler/Operational'), so the History tab in
  Task Scheduler shows past run results. This is a global Windows setting
  (off by default) and requires admin privileges. Once enabled it stays on
  until disabled — you only need to pass this flag once.
#>
[CmdletBinding()]
param(
    [string]$TaskName   = 'SimpleBackupSystem',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$EnvPath    = (Join-Path $PSScriptRoot '.env'),
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Invoke-Backup.ps1'),
    [string]$LogPath    = (Join-Path $PSScriptRoot 'setup.log'),
    [switch]$WakeToRun,
    [switch]$SkipPrereqs,
    [switch]$EnableTaskHistory
)

$ErrorActionPreference = 'Stop'

# ─── Logging ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line } catch { }
}

# ─── Helpers ─────────────────────────────────────────────────────────────
function Read-DotEnv {
    param([string]$Path)
    $hash = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $hash }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { continue }
        $eq = $trim.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $trim.Substring(0, $eq).Trim()
        $val = $trim.Substring($eq + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $hash[$key] = $val
    }
    return $hash
}

function Test-IsAdmin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [Security.Principal.WindowsPrincipal]::new($id)
    return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-Prerequisites {
    Write-Log '─── Prerequisite check ────────────────────────────────'
    Write-Log "PowerShell : $($PSVersionTable.PSVersion)"

    # NuGet provider — required by Install-Module on a fresh machine.
    $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
             Sort-Object Version -Descending | Select-Object -First 1
    if (-not $nuget) {
        Write-Log 'NuGet provider not found; installing for CurrentUser...'
        try {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
            Write-Log 'NuGet provider installed.'
        } catch {
            Write-Log "NuGet provider install FAILED: $($_.Exception.Message)" 'ERROR'
            Write-Log 'If this fails on a locked-down machine, retry in an elevated pwsh:' 'INFO'
            Write-Log '  Install-PackageProvider -Name NuGet -Force' 'INFO'
            throw
        }
    } else {
        Write-Log "NuGet provider OK ($($nuget.Version))"
    }

    # Trust PSGallery for the current user so Install-Module is unattended.
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
        Write-Log 'Marking PSGallery as Trusted (CurrentUser)...'
        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        } catch {
            Write-Log "Could not mark PSGallery trusted: $($_.Exception.Message)" 'WARN'
            Write-Log 'Continuing — Install-Module will use -Force.' 'INFO'
        }
    }

    # Az.Storage module
    $mod = Get-Module -ListAvailable -Name Az.Storage |
           Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        Write-Log 'Az.Storage not installed; installing for CurrentUser...'
        try {
            Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $mod = Get-Module -ListAvailable -Name Az.Storage |
                   Sort-Object Version -Descending | Select-Object -First 1
            Write-Log "Az.Storage installed (version $($mod.Version))"
        } catch {
            Write-Log "Az.Storage install FAILED: $($_.Exception.Message)" 'ERROR'
            Write-Log 'Retry manually:  Install-Module Az.Storage -Scope CurrentUser -Force' 'INFO'
            Write-Log 'If you see a TLS error, run first:' 'INFO'
            Write-Log "  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12" 'INFO'
            throw
        }
    } else {
        Write-Log "Az.Storage OK (version $($mod.Version))"
    }

    Write-Log '─── Prerequisites ready ───────────────────────────────'
}

# ─── Main ────────────────────────────────────────────────────────────────
try {
    Write-Log "Register-BackupTask started (TaskName='$TaskName', WakeToRun=$WakeToRun)"
    Write-Log "Running elevated: $(Test-IsAdmin) (admin is NOT required for the typical path)"

    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script not found: $ScriptPath" }

    if (-not $SkipPrereqs) {
        Install-Prerequisites
    } else {
        Write-Log 'Skipping prerequisite check (-SkipPrereqs).'
    }

    $config  = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $envVars = Read-DotEnv -Path $EnvPath

    $time = $config.ScheduleTime
    if (-not $time) { throw "ScheduleTime missing in config.json (expected 'HH:mm')." }

    $source         = if ($envVars['SOURCE_FOLDER'])   { $envVars['SOURCE_FOLDER'] }   else { $config.SourceFolder }
    $storageAccount = if ($envVars['STORAGE_ACCOUNT']) { $envVars['STORAGE_ACCOUNT'] } else { $config.StorageAccount }
    if (-not $source)         { Write-Log 'SOURCE_FOLDER not set in .env or config.json — Invoke-Backup.ps1 will fail until it is.' 'WARN' }
    if (-not $storageAccount) { Write-Log 'STORAGE_ACCOUNT not set in .env or config.json — Invoke-Backup.ps1 will fail until it is.' 'WARN' }

    # Locate pwsh.exe (PowerShell 7)
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) {
        $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $pwsh)) {
        throw 'pwsh.exe not found. Install PowerShell 7 (https://aka.ms/powershell).'
    }
    Write-Log "pwsh.exe: $pwsh"

    $action = New-ScheduledTaskAction `
        -Execute $pwsh `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
        -WorkingDirectory $PSScriptRoot

    $trigger = New-ScheduledTaskTrigger -Daily -At $time

    # Build settings — WakeToRun is conditional.
    $settingsArgs = @{
        StartWhenAvailable        = $true
        AllowStartIfOnBatteries   = $true
        DontStopIfGoingOnBatteries = $true
        ExecutionTimeLimit        = (New-TimeSpan -Hours 2)
        MultipleInstances         = 'IgnoreNew'
    }
    if ($WakeToRun) { $settingsArgs.WakeToRun = $true }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Removed existing task '$TaskName'."
    }

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Daily SimpleBackupSystem (SBS) backup of OneDrive documents to Azure Blob Storage.' | Out-Null

    Write-Log "Scheduled task '$TaskName' registered."
    Write-Log "  Daily at        : $time"
    Write-Log "  Source folder   : $(if ($source)         { $source }         else { '<not set — fix in .env>' })"
    Write-Log "  Storage account : $(if ($storageAccount) { $storageAccount } else { '<not set — fix in .env>' })"
    Write-Log "  Container       : $($config.Container)"
    Write-Log "  StartWhenAvailable : true (catches up after missed runs)"
    Write-Log "  WakeToRun          : $([bool]$WakeToRun)"

    if ($EnableTaskHistory) {
        $logName = 'Microsoft-Windows-TaskScheduler/Operational'
        if (-not (Test-IsAdmin)) {
            Write-Log "-EnableTaskHistory requires admin. Run from an elevated pwsh or do it manually:" 'WARN'
            Write-Log "  wevtutil set-log '$logName' /enabled:true" 'WARN'
        } else {
            try {
                & wevtutil.exe set-log $logName /enabled:true
                if ($LASTEXITCODE -ne 0) { throw "wevtutil exited with code $LASTEXITCODE" }
                Write-Log "Task Scheduler history (Cronologia) enabled system-wide."
            } catch {
                Write-Log "Could not enable Task Scheduler history: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    Write-Log ''
    Write-Log "To remove later:  Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
