<#
.SYNOPSIS
  Everything before publishing: builds the stack, starts every application, checks the notices and versions, and
  generates the installers without publishing them.

.DESCRIPTION
  1. build      build.cmd: libraries in order with their tests, then each application's tests and native image
  2. start      each application's exe, from its installer.json, must still be running after a few seconds. Tests run
                on the JVM, so this is what catches a native image that cannot start (a resource it never registered)
  3. notices    notices\notices.py --check
  4. versions   lists each application whose installer.json version is already published: its exe will be
                regenerated as that same release, so bump it if it changed
  5. generate   deploy.ps1 without -Publish, then the diff here and in ..\sibarum.github.io

  Nothing is uploaded, committed or pushed. The generated files are left in place to look at: publishing is
  deploy.ps1 -Publish, and git checkout -- apps puts them back. Logs land in logs\. Stops at the first failing step.

.PARAMETER SkipBuild
  Use the exes already in each application's target\ (after fixing one application and rebuilding only it).

.PARAMETER Seconds
  How long each application must stay up.

.PARAMETER BuildOnly
  Stop after the notices: build, start and check, generating nothing. release-preflight.ps1 generates its own.
#>
param([switch]$SkipBuild, [int]$Seconds = 8, [switch]$BuildOnly)
$ErrorActionPreference = 'Stop'

$dist  = $PSScriptRoot
$root  = Split-Path $dist -Parent
$logs  = Join-Path $dist 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$suite = Get-Content (Join-Path $dist 'installer-suite.json') -Raw | ConvertFrom-Json
$apps  = foreach ($m in $suite.members) {
    $config = [IO.Path]::GetFullPath((Join-Path $dist $m.config))
    [pscustomobject]@{ Config = $config; Repo = Split-Path $config -Parent; App = Get-Content $config -Raw | ConvertFrom-Json }
}

function Step($name) { Write-Host "`n== $name" -ForegroundColor Cyan }
function Fail($msg)  { Write-Host "PREFLIGHT FAILED: $msg" -ForegroundColor Red; exit 1 }

# Python is not on PowerShell's PATH everywhere; the Store's python.exe stub answers but runs nothing.
function Find-Python {
    $ErrorActionPreference = 'Continue'   # the stub's complaint on stderr would otherwise stop the script
    foreach ($c in @('python', 'py', "$env:USERPROFILE\anaconda3\python.exe", "$env:USERPROFILE\miniconda3\python.exe")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            & $c --version *> $null
            if ($LASTEXITCODE -eq 0) { return $c }
        }
    }
    return $null
}

if (-not $SkipBuild) {
    Step 'build'
    # call: without it cmd /c can return 0 from a batch file that ran exit /b 1 (see the end of build.cmd).
    # Its output is checked for FAILED as well, so a failure can never pass as a build.
    $failed = $false
    & cmd /c "call `"$dist\build.cmd`"" | ForEach-Object { Write-Host $_; if ($_ -match 'FAILED') { $failed = $true } }
    if ($LASTEXITCODE -ne 0 -or $failed) { Fail 'the build; see logs\' }
}

Step 'start'
$dead = @()
foreach ($a in $apps) {
    foreach ($b in $a.App.windows.binaries | Where-Object { $_.source -like '*.exe' }) {
        $exe = Join-Path $a.Repo $b.source
        if (-not (Test-Path $exe)) { $dead += "$($a.App.id): no $exe"; continue }
        $out = Join-Path $logs "start-$($b.name).log"
        $p = Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru `
                -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        Start-Sleep -Seconds $Seconds
        if ($p.HasExited) {
            $dead += "$($b.name) exited within ${Seconds}s; see logs\start-$($b.name).log.err"
        } else {
            Write-Host "  $($b.name) up"
            Stop-Process $p -Force
        }
    }
}
if ($dead) { $dead | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; Fail 'an application does not start' }

Step 'notices'
$python = Find-Python
if (-not $python) { Fail 'no Python found (python, py, or anaconda3)' }
& $python (Join-Path $dist 'notices\notices.py') --check
if ($LASTEXITCODE -ne 0) { Fail 'the notices' }
if ($BuildOnly) { Write-Host "`nBuilt, started and checked." -ForegroundColor Green; exit 0 }

Step 'versions'
foreach ($a in $apps) {
    $manifest = Join-Path $dist "apps\$($a.App.id)\manifest.json"
    $latest = if (Test-Path $manifest) { (Get-Content $manifest -Raw | ConvertFrom-Json).latest }
    if ($latest -eq $a.App.version) {
        Write-Host "  $($a.App.name) $($a.App.version) is already published; bump it in $($a.Config) if it changed" -ForegroundColor Yellow
    } else {
        Write-Host "  $($a.App.name) $($a.App.version) (published: $(if ($latest) { $latest } else { 'none' }))"
    }
}

Step 'generate'
try { & (Join-Path $dist 'deploy.ps1') } catch { Fail "deploy.ps1: $_" }

Step 'diff'
git -C $dist status --short
$site = Join-Path $root 'sibarum.github.io'
if (Test-Path (Join-Path $site '.git')) { git -C $site status --short }

Write-Host "`nPreflight passed. Look at git diff here (and in ..\sibarum.github.io), then .\deploy.ps1 -Publish." -ForegroundColor Green
