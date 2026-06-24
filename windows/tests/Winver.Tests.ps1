BeforeAll {
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
}

Describe 'winver Windows scripts' {
  It 'setup.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\setup.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'doctor.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\doctor.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'run-job.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\run-job.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'job.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\job.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'repo job scripts parse without executing' {
    foreach ($script in Get-ChildItem -Path (Join-Path $RepoRoot 'jobs') -Filter '*.ps1') {
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
      $errors | Should -BeNullOrEmpty
    }
  }

  It 'job.ps1 lists repo-defined jobs' {
    $repo = Join-Path $TestDrive 'repo'
    $jobs = Join-Path $repo 'jobs'
    New-Item -ItemType Directory -Force -Path $jobs | Out-Null
    Set-Content -Path (Join-Path $jobs 'hello.ps1') -Value "Write-Output 'hello'" -Encoding utf8

    $result = & (Join-Path $RepoRoot 'windows\job.ps1') -Action list -RepoPath $repo -WinverHome (Join-Path $TestDrive '.winver')
    $result | Should -Contain 'hello'
  }

  It 'job.ps1 rejects traversal names before dry-run start' {
    $repo = Join-Path $TestDrive 'repo-reject'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'jobs') | Out-Null

    {
      & (Join-Path $RepoRoot 'windows\job.ps1') -Action start -Name '..\bad' -RepoPath $repo -WinverHome (Join-Path $TestDrive '.winver') -SkipPull -DryRun
    } | Should -Throw '*Job names*'
  }

  It 'job.ps1 dry-runs a named job with decoded arguments' {
    $repo = Join-Path $TestDrive 'repo-dry-run'
    $jobs = Join-Path $repo 'jobs'
    New-Item -ItemType Directory -Force -Path $jobs | Out-Null
    Set-Content -Path (Join-Path $jobs 'hello.ps1') -Value "Write-Output 'hello'" -Encoding utf8
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('["--version"]'))

    $result = & (Join-Path $RepoRoot 'windows\job.ps1') -Action start -Name 'hello' -ArgsJsonBase64 $encoded -RepoPath $repo -WinverHome (Join-Path $TestDrive '.winver') -SkipPull -DryRun
    $joined = $result -join "`n"
    $joined | Should -Match 'job=hello'
    $joined | Should -Match 'args=--version'
  }

  It 'job.ps1 reports job status' {
    $winverHome = Join-Path $TestDrive '.winver-status'
    $jobDir = Join-Path $winverHome 'logs\20260101-000000-hello'
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
    @{
      id = '20260101-000000-hello'
      pid = 0
      startedAt = '2026-01-01T00:00:00Z'
    } | ConvertTo-Json | Set-Content -Path (Join-Path $jobDir 'meta.json') -Encoding utf8
    Set-Content -Path (Join-Path $jobDir 'exit.code') -Value '0'
    Set-Content -Path (Join-Path $jobDir 'stdout.log') -Value 'ok'
    Set-Content -Path (Join-Path $jobDir 'stderr.log') -Value ''

    $result = & (Join-Path $RepoRoot 'windows\job.ps1') -Action status -Target '20260101-000000-hello' -WinverHome $winverHome
    $joined = $result -join "`n"
    $joined | Should -Match 'id=20260101-000000-hello'
    $joined | Should -Match 'exit=0'
  }

  It 'job.ps1 archives a runs folder' {
    $winverHome = Join-Path $TestDrive '.winver-archive'
    $runDir = Join-Path $winverHome 'runs\myrun'
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    Set-Content -Path (Join-Path $runDir 'result.txt') -Value 'ok'

    $result = & (Join-Path $RepoRoot 'windows\job.ps1') -Action archive -Kind runs -Target myrun -WinverHome $winverHome
    $archiveLine = $result | Where-Object { $_ -like 'archive=*' } | Select-Object -First 1
    $archive = $archiveLine.Substring('archive='.Length)
    Test-Path -LiteralPath $archive | Should -BeTrue
  }

  It 'control.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\control.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'admin scripts parse without executing' {
    foreach ($script in @(
      'windows\admin\policy.ps1',
      'windows\admin\init-admin.ps1',
      'windows\admin\broker.ps1',
      'windows\admin\uefi.ps1',
      'windows\admin\break-glass.ps1',
      'windows\winver.ps1'
    )) {
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $script), [ref]$tokens, [ref]$errors) | Out-Null
      $errors | Should -BeNullOrEmpty
    }
  }
}
