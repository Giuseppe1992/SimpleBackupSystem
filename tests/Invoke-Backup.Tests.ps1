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

Describe 'Test-PathExcluded' {
    It 'returns false when no patterns are provided' {
        Test-PathExcluded -RelativePath 'foo/bar.txt' -Patterns @() | Should -BeFalse
    }

    It 'returns false when patterns is null' {
        Test-PathExcluded -RelativePath 'foo/bar.txt' -Patterns $null | Should -BeFalse
    }

    It 'matches a literal filename at any depth' {
        Test-PathExcluded -RelativePath 'a/b/c/Thumbs.db' -Patterns @('Thumbs.db') | Should -BeTrue
        Test-PathExcluded -RelativePath 'Thumbs.db'        -Patterns @('Thumbs.db') | Should -BeTrue
    }

    It 'is case-insensitive on filename match' {
        Test-PathExcluded -RelativePath 'a/THUMBS.DB' -Patterns @('thumbs.db') | Should -BeTrue
    }

    It 'matches a wildcard filename pattern at any depth' {
        Test-PathExcluded -RelativePath 'foo/draft.bak' -Patterns @('*.bak') | Should -BeTrue
        Test-PathExcluded -RelativePath 'draft.bak'     -Patterns @('*.bak') | Should -BeTrue
    }

    It 'matches a path pattern with a slash' {
        Test-PathExcluded -RelativePath 'build/output.log' -Patterns @('build/*') | Should -BeTrue
    }

    It 'matches a path pattern recursively (* spans separators)' {
        Test-PathExcluded -RelativePath 'build/sub/deep/output.log' -Patterns @('build/*') | Should -BeTrue
    }

    It 'does not match a path pattern outside its prefix' {
        Test-PathExcluded -RelativePath 'src/output.log' -Patterns @('build/*') | Should -BeFalse
    }

    It 'normalizes backslashes to forward slashes before matching' {
        Test-PathExcluded -RelativePath 'build\output.log' -Patterns @('build/*') | Should -BeTrue
    }

    It 'returns true if any pattern in the list matches' {
        Test-PathExcluded -RelativePath 'foo/Thumbs.db' -Patterns @('*.bak','Thumbs.db','build/*') | Should -BeTrue
    }

    It 'returns false if no pattern matches' {
        Test-PathExcluded -RelativePath 'docs/readme.txt' -Patterns @('*.bak','Thumbs.db') | Should -BeFalse
    }

    It 'ignores empty pattern entries' {
        Test-PathExcluded -RelativePath 'docs/readme.txt' -Patterns @('','*.bak') | Should -BeFalse
    }
}
