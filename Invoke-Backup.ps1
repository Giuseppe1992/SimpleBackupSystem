#requires -Version 7.0
<#
.SYNOPSIS
  Filters documents/images from a source folder, zips them (preserving
  subfolder structure) into %TEMP%, uploads the zip to Azure Blob Storage,
  and removes the local zip.

.PARAMETER ConfigPath
  Path to config.json. Defaults to ./config.json next to this script.

.PARAMETER EnvPath
  Path to .env (for SAS_TOKEN). Defaults to ./.env next to this script.

.PARAMETER LogDirectory
  Directory for per-run log files. Defaults to ./logs next to this script.
  Each run writes a separate file named backup_<yyyy-MM-dd_HH-mm-ss>.log.

.PARAMETER LogRetentionDays
  Delete log files older than this many days at the start of each run.
  Set to 0 to disable pruning. Defaults to 30.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath        = (Join-Path $PSScriptRoot 'config.json'),
    [string]$EnvPath           = (Join-Path $PSScriptRoot '.env'),
    [string]$LogDirectory      = (Join-Path $PSScriptRoot 'logs'),
    [int]   $LogRetentionDays  = 30
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line } catch { }
}

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

function Remove-OldLogs {
    param([string]$Directory, [int]$RetentionDays)
    if ($RetentionDays -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'backup_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Returns $true if a relative path matches any exclude pattern.
# Patterns containing '/' are matched against the relative path (e.g. 'build/*');
# patterns without '/' are matched against the leaf filename only (e.g. 'Thumbs.db' or '*.bak').
# Wildcards: * (any chars) and ? (single char). Matching is case-insensitive.
function Test-PathExcluded {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string[]]$Patterns
    )
    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
    $rel = $RelativePath -replace '\\','/'
    $name = Split-Path -Leaf $rel
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrEmpty($pattern)) { continue }
        if ($pattern.Contains('/')) {
            if ($rel -like $pattern) { return $true }
        } else {
            if ($name -like $pattern) { return $true }
        }
    }
    return $false
}

# Skip script body when dot-sourced (so tests can load the functions above)
if ($MyInvocation.InvocationName -eq '.') { return }

$zipPath = $null

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$LogPath = Join-Path $LogDirectory ('backup_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
Remove-OldLogs -Directory $LogDirectory -RetentionDays $LogRetentionDays

try {
    Write-Log 'Backup run started'

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found at $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $envVars = Read-DotEnv -Path $EnvPath

    # Resolve a setting: .env wins, else config.json. Returns $null if neither.
    function Resolve-Setting {
        param([string]$EnvKey, [string]$ConfigKey)
        if ($envVars.ContainsKey($EnvKey) -and $envVars[$EnvKey]) {
            Write-Log "${ConfigKey}: loaded from .env"
            return $envVars[$EnvKey]
        }
        $val = $config.$ConfigKey
        if ($val) {
            Write-Log "${ConfigKey}: loaded from config.json (consider moving to .env)"
            return $val
        }
        return $null
    }

    $source         = Resolve-Setting -EnvKey 'SOURCE_FOLDER'   -ConfigKey 'SourceFolder'
    $storageAccount = Resolve-Setting -EnvKey 'STORAGE_ACCOUNT' -ConfigKey 'StorageAccount'
    $sasToken       = Resolve-Setting -EnvKey 'SAS_TOKEN'       -ConfigKey 'SasToken'

    if (-not $source)         { throw 'SourceFolder not provided. Set SOURCE_FOLDER in .env or SourceFolder in config.json.' }
    if (-not $storageAccount) { throw 'StorageAccount not provided. Set STORAGE_ACCOUNT in .env or StorageAccount in config.json.' }
    if (-not $sasToken)       { throw 'SAS token not provided. Set SAS_TOKEN in .env or SasToken in config.json.' }

    foreach ($key in 'Container','FileExtensions') {
        if (-not $config.$key) { throw "Missing '$key' in config.json" }
    }

    # Az.Storage accepts the token with or without leading "?"; normalize.
    if ($sasToken.StartsWith('?')) { $sasToken = $sasToken.Substring(1) }

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source folder does not exist: $source"
    }
    $sourceFull = (Resolve-Path -LiteralPath $source).Path.TrimEnd('\','/')

    if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
        throw 'Az.Storage module not installed. Run: Install-Module Az.Storage -Scope CurrentUser'
    }
    Import-Module Az.Storage -ErrorAction Stop

    # Build extension set (case-insensitive, dot-prefixed)
    $extSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $config.FileExtensions) {
        if (-not $e.StartsWith('.')) { $e = '.' + $e }
        [void]$extSet.Add($e)
    }

    $excludePatterns = @()
    if ($config.PSObject.Properties.Match('ExcludePatterns').Count -gt 0 -and $config.ExcludePatterns) {
        $excludePatterns = @($config.ExcludePatterns)
    }

    Write-Log "Scanning $source (recursive)"
    $extMatched = @(Get-ChildItem -LiteralPath $source -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $extSet.Contains($_.Extension) })
    $files = @($extMatched | Where-Object {
        $rel = $_.FullName.Substring($sourceFull.Length).TrimStart('\','/')
        -not (Test-PathExcluded -RelativePath $rel -Patterns $excludePatterns)
    })
    $excludedCount = $extMatched.Count - $files.Count
    if ($excludePatterns.Count -gt 0) {
        Write-Log "Matched $($files.Count) file(s); excluded by pattern: $excludedCount"
    } else {
        Write-Log "Matched $($files.Count) file(s)"
    }

    if ($files.Count -eq 0) {
        Write-Log 'Nothing to back up. Exiting.' 'WARN'
        return
    }

    # Build zip in %TEMP%, preserving relative directory structure
    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $zipName = "Backup_$stamp.zip"
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) $zipName

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    Write-Log "Creating zip: $zipPath"
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($sourceFull.Length).TrimStart('\','/')
            $entryName = $rel -replace '\\','/'   # zip spec: forward slashes
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $f.FullName, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $zip.Dispose()
    }
    $zipSizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
    Write-Log "Zip created: $zipName ($zipSizeMB MB)"

    # Upload
    $ctx = New-AzStorageContext -StorageAccountName $storageAccount -SasToken $sasToken
    Write-Log "Uploading to $storageAccount/$($config.Container)/$zipName"
    Set-AzStorageBlobContent `
        -File $zipPath `
        -Container $config.Container `
        -Blob $zipName `
        -Context $ctx `
        -Force | Out-Null
    Write-Log 'Upload complete'

    Remove-Item -LiteralPath $zipPath -Force
    $zipPath = $null
    Write-Log 'Local zip removed'

    Write-Log 'Backup run finished successfully'
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    exit 1
}
