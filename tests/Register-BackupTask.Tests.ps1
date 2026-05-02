#requires -Version 7.0
#requires -Modules Pester

# Contract tests for Register-BackupTask.ps1.
# Most of the script is orchestration around Windows ScheduledTask cmdlets,
# which aren't worth mocking. We verify it parses and declares the documented
# parameters — enough to catch accidental removals/renames/type changes.

BeforeAll {
    $script:scriptPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'Register-BackupTask.ps1')
    $script:cmd = Get-Command $script:scriptPath
}

Describe 'Register-BackupTask.ps1' {
    Context 'String parameters' {
        It 'declares -<_> as [string]' -ForEach @('TaskName','ConfigPath','EnvPath','ScriptPath','LogPath') {
            $script:cmd.Parameters.ContainsKey($_) | Should -BeTrue
            $script:cmd.Parameters[$_].ParameterType | Should -Be ([string])
        }
    }

    Context 'Switch parameters' {
        It 'declares -<_> as [switch]' -ForEach @('WakeToRun','SkipPrereqs','EnableTaskHistory') {
            $script:cmd.Parameters.ContainsKey($_) | Should -BeTrue
            $script:cmd.Parameters[$_].SwitchParameter | Should -BeTrue
        }
    }

    Context 'Comment-based help block' {
        BeforeAll {
            $script:source = Get-Content $script:scriptPath -Raw
        }

        It 'contains a .SYNOPSIS section' {
            $script:source | Should -Match '(?m)^\.SYNOPSIS\b'
        }

        It 'documents -<_>' -ForEach @('TaskName','ConfigPath','EnvPath','ScriptPath','WakeToRun','SkipPrereqs','EnableTaskHistory') {
            $script:source | Should -Match "(?m)^\.PARAMETER\s+$_\b"
        }
    }
}
