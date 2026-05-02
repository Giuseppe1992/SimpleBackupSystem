#requires -Version 7.0
<#
.SYNOPSIS
  Installs developer dependencies for this project (PSScriptAnalyzer, Pester).
  Run once per machine before ./Invoke-Tests.ps1.

  Production runtime dependencies (Az.Storage) are NOT installed here — those
  are handled by Register-BackupTask.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Install-DevModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinimumVersion,
        [switch]$SkipPublisherCheck
    )
    $existing = Get-Module -ListAvailable -Name $Name
    if ($MinimumVersion) {
        $existing = $existing | Where-Object { $_.Version -ge [version]$MinimumVersion }
    }
    if ($existing) {
        $v = ($existing | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Host "  $Name $v already installed" -ForegroundColor Green
        return
    }
    Write-Host "  installing $Name..." -ForegroundColor Yellow
    $installArgs = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true }
    if ($MinimumVersion)     { $installArgs['MinimumVersion']     = $MinimumVersion }
    if ($SkipPublisherCheck) { $installArgs['SkipPublisherCheck'] = $true }
    Install-Module @installArgs
    $v = (Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Host "  $Name $v installed" -ForegroundColor Green
}

Write-Host '── Developer dependencies ──' -ForegroundColor Cyan
Install-DevModule -Name 'PSScriptAnalyzer'
Install-DevModule -Name 'Pester' -MinimumVersion '5.0.0' -SkipPublisherCheck
Write-Host ''
Write-Host 'Done. You can now run ./Invoke-Tests.ps1' -ForegroundColor Green
