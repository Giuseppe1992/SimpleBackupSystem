#requires -Version 7.0
<#
.SYNOPSIS
  Runs PSScriptAnalyzer (lint) and Pester (unit tests) for this project.
  Exits with code 1 if either step finds errors / failing tests.

  Required modules are installed by ./Install-DevTools.ps1 — run that once
  per machine before invoking this script.
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipPester
)

$ErrorActionPreference = 'Stop'
$failed = $false

function Import-DevDependency {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinimumVersion,
        [Parameter(Mandatory)][string]$ProbeCommand
    )
    # If the cmdlet is already exposed, the module is usable — don't touch it.
    # (Avoid -Force on binary modules: hosts like the VS Code PowerShell extension
    # may have pre-loaded the assembly, and reloading throws "assembly already loaded".)
    if (Get-Command $ProbeCommand -ErrorAction SilentlyContinue) { return }

    $available = Get-Module -ListAvailable -Name $Name
    if ($MinimumVersion) {
        $available = $available | Where-Object { $_.Version -ge [version]$MinimumVersion }
    }
    if (-not $available) {
        $spec = if ($MinimumVersion) { " (>= $MinimumVersion)" } else { '' }
        throw "$Name$spec is not installed. Run ./Install-DevTools.ps1 first."
    }

    $importArgs = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($MinimumVersion) { $importArgs['MinimumVersion'] = $MinimumVersion }
    Import-Module @importArgs

    if (-not (Get-Command $ProbeCommand -ErrorAction SilentlyContinue)) {
        throw "$Name was imported but '$ProbeCommand' is not available. The module's assembly may be loaded in a broken state by a host process (e.g. the VS Code PowerShell extension). Open a fresh standalone pwsh terminal and retry."
    }
}

if (-not $SkipAnalyzer) {
    Import-DevDependency -Name 'PSScriptAnalyzer' -ProbeCommand 'Invoke-ScriptAnalyzer'
    Write-Host '── PSScriptAnalyzer ──' -ForegroundColor Cyan
    $issues = Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse `
        -ExcludeRule 'PSAvoidUsingWriteHost','PSUseShouldProcessForStateChangingFunctions','PSUseBOMForUnicodeEncodedFile'
    if ($issues) {
        $issues | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message
        if (($issues | Where-Object Severity -eq 'Error').Count -gt 0) { $failed = $true }
    } else {
        Write-Host 'No issues found.' -ForegroundColor Green
    }
}

if (-not $SkipPester) {
    Import-DevDependency -Name 'Pester' -MinimumVersion '5.0.0' -ProbeCommand 'New-PesterConfiguration'
    Write-Host ''
    Write-Host '── Pester ──' -ForegroundColor Cyan
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $PSScriptRoot 'tests'
    $cfg.Run.Exit = $false
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $cfg
    if ($result.FailedCount -gt 0) { $failed = $true }
}

Write-Host ''
if ($failed) {
    Write-Host 'FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'OK' -ForegroundColor Green
