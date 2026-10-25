<#
.SYNOPSIS
  Everything before publishing: builds the stack, starts every application, checks the notices and versions, and
  generates the installers without publishing them.

.DESCRIPTION
  1. build      build.cmd: libraries in order with their tests, then each application's tests and native image
  2. start      each application's exe, from its installer.json, must still be running after a few seconds. Tests run
                on the JVM, so this is what catches a native image that cannot start (a resource it never registered)
  3. linux      each application with a linux section needs its Linux binaries, which build.sh builds in the Linux
                VM: logs\linux\BUILD.txt must name exactly the commits checked out here. When they do not, the
                preflight asks the VM for that build as it starts, so the two build at the same time: build.sh
                --watch in the VM takes the request (logs\linux\REQUEST.txt) and answers in logs\linux\WATCH.txt.
                This step waits for that answer. Without a watcher, run from a console a person is at, it waits
                for a build started by hand; otherwise it fails
  4. notices    notices\notices.py --check
  5. versions   lists each application whose installer.json version is already published: its exe will be
                regenerated as that same release, so bump it if it changed
  6. generate   deploy.ps1 without -Publish, then the diff here

  Nothing is uploaded, committed or pushed. The generated files are left in place to look at: publishing is
  deploy.ps1 -Publish, and git checkout -- apps puts them back. Logs land in logs\. Stops at the first failing step.

.PARAMETER SkipBuild
  Use the exes already in each application's target\ (after fixing one application and rebuilding only it).

.PARAMETER Seconds
  How long each application must stay up.

.PARAMETER BuildOnly
  Stop after the notices: build, start, the Linux build and the notices checked, generating nothing. release-preflight.ps1 generates its own.

.PARAMETER LinuxLocal
  Also have the VM install its build for real, from a local preflight (local-linux.sh --install), and wait for
  that: logs\linux\LOCAL.txt must name the same build as BUILD.txt. release-preflight.ps1 asks for it.

.PARAMETER LinuxMinutes
  How long to wait for the VM before failing.

.PARAMETER WindowsOnly
  Leave the Linux VM out: no request to it, no linux step, and no generate step (the installers it writes carry
  every platform). For trying the Windows build alone; preflight.sh is the same for Linux. Not enough to publish.

.PARAMETER Platform
  windows: the preflight of a Windows release, which is published on its own (deploy.ps1 -Platform windows):
  build, start, notices, versions and generate, with the Linux VM left out. Linux releases itself, in the VM
  (preflight.sh --release, then deploy.sh).
#>
param([switch]$SkipBuild, [int]$Seconds = 8, [switch]$BuildOnly, [switch]$LinuxLocal, [int]$LinuxMinutes = 240,
      [switch]$WindowsOnly, [ValidateSet('', 'windows')][string]$Platform)
if ($WindowsOnly -and $LinuxLocal) { Write-Host '-WindowsOnly leaves the VM out; -LinuxLocal asks it to install' -ForegroundColor Red; exit 1 }
if ($Platform -and $WindowsOnly) { Write-Host '-Platform windows is -WindowsOnly with the installers generated; give one' -ForegroundColor Red; exit 1 }
$ErrorActionPreference = 'Stop'
$linuxHere = -not $WindowsOnly -and $Platform -ne 'windows'

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

# The Linux binaries are built in the Linux VM by build.sh, which writes logs\linux\BUILD.txt: the commit of every
# checkout it built. They are fit to publish beside these exes only while every one of those is still checked out.
$linuxLogs = Join-Path $logs 'linux'
New-Item -ItemType Directory -Force $linuxLogs | Out-Null
function Test-LinuxBuild {
    $stamp = Join-Path $linuxLogs 'BUILD.txt'
    if (-not (Test-Path $stamp)) { return @('no Linux build: logs\linux\BUILD.txt is missing') }
    $builtFrom = @{}
    foreach ($line in Get-Content $stamp) {
        if ($line -match '^\s*(#|$)') { continue }
        $f = $line -split '\s+'
        $builtFrom[$f[0]] = $f[1]
    }
    $problems = @()
    foreach ($repo in $builtFrom.Keys) {
        $head = (git -C (Join-Path $root $repo) rev-parse HEAD) -join ''
        if ($head -ne $builtFrom[$repo]) {
            $problems += "${repo}: the Linux build is of $($builtFrom[$repo].Substring(0, 9)), the checkout is at $(if ($head) { $head.Substring(0, 9) } else { 'nothing' })"
        }
    }
    foreach ($a in $apps | Where-Object { $_.App.linux }) {
        $repo = Split-Path $a.Repo -Leaf
        if (-not $builtFrom.ContainsKey($repo)) { $problems += "${repo}: not in the Linux build" }
        foreach ($b in $a.App.linux.binaries) {
            if (-not (Test-Path (Join-Path $a.Repo $b.source))) { $problems += "$($a.App.id): no $($b.source)" }
        }
    }
    $problems
}

# local-linux.sh --install writes logs\linux\LOCAL.txt once it has installed every Linux application: the lines of
# the BUILD.txt it installed.
function Get-BuiltLines([string]$file) {
    $path = Join-Path $linuxLogs $file
    if (-not (Test-Path $path)) { return $null }
    (@(Get-Content $path -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*(#|$)' }) -join "`n")
}
function Test-LinuxLocal {
    $installed = Get-BuiltLines 'LOCAL.txt'
    if ($null -eq $installed) { return @('no local install in the VM: logs\linux\LOCAL.txt is missing') }
    if ($installed -ne (Get-BuiltLines 'BUILD.txt')) { return @('the local install in the VM is of another build than logs\linux\BUILD.txt') }
    @()
}

# build.sh --watch, in the VM, runs what logs\linux\REQUEST.txt asks for, once per id, and answers in WATCH.txt:
# "<waiting|running|done|failed> <id>", then what failed. It rewrites watch.alive every few seconds while it runs.
function Request-Linux {
    $steps = @()
    if (@(Test-LinuxBuild).Count -gt 0) { $steps += 'build' }
    if ($LinuxLocal -and ($steps -or @(Test-LinuxLocal).Count -gt 0)) { $steps += 'local' }
    if (-not $steps) { return $null }
    $id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 100000)
    $tmp = Join-Path $linuxLogs 'REQUEST.txt.tmp'
    [IO.File]::WriteAllText($tmp, "id $id`nsteps $($steps -join ' ')`n", (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp (Join-Path $linuxLogs 'REQUEST.txt')
    Write-Host "  asked the Linux VM for: $($steps -join ', ') (request $id)"
    $id
}
function Get-LinuxWatch {
    $w = [pscustomobject]@{ Alive = $false; State = ''; Id = ''; Lines = @() }
    $alive = Get-Item (Join-Path $linuxLogs 'watch.alive') -ErrorAction SilentlyContinue
    if ($alive) { $w.Alive = ([DateTime]::UtcNow - $alive.LastWriteTimeUtc).TotalSeconds -lt 60 }
    $lines = @(Get-Content (Join-Path $linuxLogs 'WATCH.txt') -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 0) {
        $first = $lines[0] -split '\s+', 2
        $w.State = $first[0]
        if ($first.Count -gt 1) { $w.Id = $first[1].Trim() }
        $w.Lines = @($lines | Select-Object -Skip 1)
    }
    $w
}

$linuxApps = if (-not $linuxHere) { @() } else { @($apps | Where-Object { $_.App.linux } | ForEach-Object { $_.App.name }) }
$linuxRequest = $null
if ($linuxApps) {
    # Asked now, so the VM builds while this computer does.
    Step 'linux request'
    $linuxRequest = Request-Linux
    if (-not $linuxRequest) { Write-Host '  the Linux build in the VM is already of these sources' }
    elseif (-not (Get-LinuxWatch).Alive) { Write-Host '  no watcher is running in the VM yet (./build.sh --watch); the linux step waits for one' -ForegroundColor Yellow }
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

Step 'linux'
if (-not $linuxHere) {
    Write-Host "  left out ($(if ($WindowsOnly) { '-WindowsOnly' } else { '-Platform windows' }))"
} elseif (-not $linuxApps) {
    Write-Host '  no application has a linux section'
} else {
    # Read-Host fails under -NonInteractive, and has no one to answer it with redirected input
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
                   -not ([Environment]::GetCommandLineArgs() -match '^-NonI')
    $deadline = (Get-Date).AddMinutes($LinuxMinutes)
    $said = ''
    while ($true) {
        # The answer first: a watcher that has just finished has written BUILD.txt and LOCAL.txt before it.
        $w = Get-LinuxWatch
        $problems = @(Test-LinuxBuild)
        if ($LinuxLocal -and -not $problems) { $problems = @(Test-LinuxLocal) }
        if (-not $problems) { break }
        if (-not $linuxRequest) { $linuxRequest = Request-Linux }
        $ours = $linuxRequest -and $w.Id -eq $linuxRequest
        if ($ours -and $w.State -in 'failed', 'done') {
            # failed, or done while the checkouts moved on (a commit during the build)
            $problems + $w.Lines | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if ($w.State -eq 'failed') { 'Red' } else { 'Yellow' }) }
            if (-not $interactive) { Fail "the Linux build in the VM ($($w.State); logs\linux\watch.log)" }
            Read-Host '  Fix it, then press Enter to have the VM build again (Ctrl+C stops)' | Out-Null
            $linuxRequest = Request-Linux
            $said = ''
            continue
        }
        if ($w.Alive) {
            $now = 'waiting for the watcher in the VM to take the request'
            if ($ours -and $w.State -eq 'running') { $now = "the VM is building ($($w.Lines -join ' ')); its output is in logs\linux\watch.log" }
            if ($now -ne $said) { Write-Host "  $now"; $said = $now }
        } elseif ($said -ne 'no watcher') {
            $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
            Write-Host '  No watcher is running in the Linux VM. In the VM, from a terminal on its desktop, in this folder:'
            Write-Host '    ./build.sh --watch              builds what this asks for (--install-watcher: always, from now on)'
            Write-Host "    ./build.sh$(if ($LinuxLocal) { ' && ./local-linux.sh --install' })   or build by hand; this notices when it is done"
            if (-not $interactive) { Fail 'the Linux build is missing, or not of these sources, and no watcher in the VM builds it' }
            $said = 'no watcher'
        }
        if ((Get-Date) -gt $deadline) { Fail "no Linux build of these sources after $LinuxMinutes minutes (-LinuxMinutes)" }
        # Ten seconds, or less when Enter is pressed
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $enter = $false
            try { $enter = $interactive -and [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter' } catch {}
            if ($enter) { break }
        }
    }
    Write-Host "  built in the VM from these sources$(if ($LinuxLocal) { ', and installed there' }): $($linuxApps -join ', ')"
}

Step 'notices'
$python = Find-Python
if (-not $python) { Fail 'no Python found (python, py, or anaconda3)' }
& $python (Join-Path $dist 'notices\notices.py') --check
if ($LASTEXITCODE -ne 0) { Fail 'the notices' }
if ($BuildOnly) { Write-Host "`nBuilt, started and checked." -ForegroundColor Green; exit 0 }

Step 'versions'
# Published means this version's entry in the manifest already has a build for the platform: one publishes into a
# release on its own, so another platform's build of the same version is no reason to bump.
$platforms = @('windows') + @(if ($linuxHere) { 'linux' })
foreach ($a in $apps) {
    $manifest = Join-Path $dist "apps\$($a.App.id)\manifest.json"
    $m = if (Test-Path $manifest) { Get-Content $manifest -Raw | ConvertFrom-Json }
    $entry = @($m.versions | Where-Object { $_.version -eq $a.App.version }) | Select-Object -First 1
    $done = @($platforms | Where-Object { $a.App.$_ -and $entry.platforms.$_ })
    $has = @($entry.platforms.PSObject.Properties.Name | Where-Object { $_ })
    if ($done) {
        Write-Host "  $($a.App.name) $($a.App.version) is already published for $($done -join ', '); bump it in $($a.Config) if it changed" -ForegroundColor Yellow
    } else {
        Write-Host "  $($a.App.name) $($a.App.version) (latest: $(if ($m.latest) { $m.latest } else { 'none' })$(if ($has) { "; this version has $($has -join ', ')" }))"
    }
}

if ($WindowsOnly) {
    Write-Host "`nWindows preflight passed. Publishing needs the Linux build too: run .\preflight.ps1 without -WindowsOnly." -ForegroundColor Green
    exit 0
}

Step 'generate'
$deployArgs = @{}
if ($Platform) { $deployArgs.Platform = $Platform }
try { & (Join-Path $dist 'deploy.ps1') @deployArgs } catch { Fail "deploy.ps1: $_" }

Step 'diff'
git -C $dist status --short

Write-Host "`nPreflight passed. Look at git diff here, then .\deploy.ps1 -Publish$(if ($Platform) { " -Platform $Platform" })." -ForegroundColor Green
