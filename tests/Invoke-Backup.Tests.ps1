#requires -Version 7.0
#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Invoke-Backup.ps1')
}

Describe 'Read-DotEnv' {
    BeforeEach {
        $script:envFile = Join-Path $TestDrive '.env.test'
    }

    It 'returns empty hashtable when file does not exist' {
        $missing = Join-Path $TestDrive 'does-not-exist.env'
        $result = Read-DotEnv -Path $missing
        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It 'parses simple key=value pairs' {
        Set-Content -LiteralPath $script:envFile -Value @('FOO=bar', 'BAZ=qux')
        $result = Read-DotEnv -Path $script:envFile
        $result['FOO'] | Should -Be 'bar'
        $result['BAZ'] | Should -Be 'qux'
    }

    It 'skips blank lines and # comments' {
        Set-Content -LiteralPath $script:envFile -Value @('', '# comment', 'KEY=value', '')
        $result = Read-DotEnv -Path $script:envFile
        $result.Count | Should -Be 1
        $result['KEY'] | Should -Be 'value'
    }

    It 'strips surrounding double quotes' {
        Set-Content -LiteralPath $script:envFile -Value 'KEY="quoted value"'
        $result = Read-DotEnv -Path $script:envFile
        $result['KEY'] | Should -Be 'quoted value'
    }

    It 'strips surrounding single quotes' {
        Set-Content -LiteralPath $script:envFile -Value "KEY='quoted value'"
        $result = Read-DotEnv -Path $script:envFile
        $result['KEY'] | Should -Be 'quoted value'
    }

    It 'preserves equals signs inside the value' {
        Set-Content -LiteralPath $script:envFile -Value 'TOKEN=abc=def=ghi'
        $result = Read-DotEnv -Path $script:envFile
        $result['TOKEN'] | Should -Be 'abc=def=ghi'
    }

    It 'trims whitespace around keys and values' {
        Set-Content -LiteralPath $script:envFile -Value '  KEY  =  value  '
        $result = Read-DotEnv -Path $script:envFile
        $result['KEY'] | Should -Be 'value'
    }

    It 'skips lines without an equals sign' {
        Set-Content -LiteralPath $script:envFile -Value @('not_a_pair', 'VALID=ok')
        $result = Read-DotEnv -Path $script:envFile
        $result.Count | Should -Be 1
        $result['VALID'] | Should -Be 'ok'
    }
}

Describe 'Remove-OldLogs' {
    BeforeEach {
        $script:logDir = Join-Path $TestDrive ('logs_{0}' -f [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:logDir | Out-Null
    }

    It 'removes files older than the retention window' {
        $oldFile = Join-Path $script:logDir 'backup_old.log'
        $newFile = Join-Path $script:logDir 'backup_new.log'
        Set-Content -LiteralPath $oldFile -Value 'old'
        Set-Content -LiteralPath $newFile -Value 'new'
        (Get-Item $oldFile).LastWriteTime = (Get-Date).AddDays(-45)

        Remove-OldLogs -Directory $script:logDir -RetentionDays 30

        Test-Path $oldFile | Should -BeFalse
        Test-Path $newFile | Should -BeTrue
    }

    It 'keeps everything when RetentionDays is 0' {
        $f = Join-Path $script:logDir 'backup_ancient.log'
        Set-Content -LiteralPath $f -Value 'data'
        (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-365)

        Remove-OldLogs -Directory $script:logDir -RetentionDays 0

        Test-Path $f | Should -BeTrue
    }

    It 'ignores files not matching backup_*.log' {
        $f = Join-Path $script:logDir 'unrelated.log'
        Set-Content -LiteralPath $f -Value 'data'
        (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-365)

        Remove-OldLogs -Directory $script:logDir -RetentionDays 30

        Test-Path $f | Should -BeTrue
    }

    It 'does not error when the directory is empty' {
        { Remove-OldLogs -Directory $script:logDir -RetentionDays 30 } | Should -Not -Throw
    }
}
