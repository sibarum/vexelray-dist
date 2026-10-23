<#
.SYNOPSIS
  A preflight release: every repository built together at its snapshot version into one suite installer, tried
  out on this computer first, then published as snapshot releases. Double-click release-preflight.cmd to run it.

.DESCRIPTION
  1. sources   every repository (release.ps1's list) and this one on develop with nothing uncommitted, so the
               preflight is exactly what was committed
  2. versions  when the repositories are still at the release just cut, moves them all to the next snapshot
               (release.ps1 next); then sets each application's installer.json to its pom's version, committing
               that in the application's repository
  3. build     preflight.ps1 -BuildOnly: build.cmd, start every exe, wait for the Linux VM's build.sh of these same
               commits (after step 2, which commits), check the notices. The preflight asks the VM's build.sh
               --watch for that build as it starts, and (unless -SkipLocal) for local-linux.sh --install after it:
               the same local install as step 4, on the VM
  4. local     deploy.ps1 -Local, served from local\ at http://127.0.0.1:<Port>, and the suite installer run from
               there in a window of its own: the same scripts as the published preflight, with nothing downloaded
               from GitHub. Each application's install record is checked afterwards. The VM cannot reach
               127.0.0.1, so the Linux install was tried in step 3, from a local preflight of its own
  5. publish   asks first (unless -Publish). deploy.ps1 -Preflight -Publish uploads each snapshot release, replacing
               a previous build of the same snapshot; preflight\ gets the suite installer and BUILD.txt (what was
               built, commit by commit); then commit, push develop, merge to main and push. Every installer reads
               main. The releases' manifests mark snapshots as prereleases, so the public command and every
               updater keep offering the last release

  Stops at the first step that fails. Logs are in logs\.

.PARAMETER LocalOnly
  Stop after the local install; publish nothing.
.PARAMETER Publish
  Publish without asking once the local install has worked.
.PARAMETER NoBump
  Stop instead of moving the repositories to the next snapshot.
.PARAMETER SkipBuild
  Use the exes already built (after fixing one application and rebuilding only it).
.PARAMETER SkipLocal
  Do not run the local install (it has been tried already), on Windows or in the Linux VM.
.PARAMETER AllowDirty
  Build even with uncommitted changes or a branch other than develop. The preflight is then not what was committed,
  so it is never published.
#>
param([switch]$LocalOnly, [switch]$Publish, [switch]$NoBump, [switch]$SkipBuild, [switch]$SkipLocal,
      [switch]$AllowDirty, [int]$Port = 8417)
$ErrorActionPreference = 'Stop'

$dist  = $PSScriptRoot
$root  = Split-Path $dist -Parent
$logs  = Join-Path $dist 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$trailer = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'

function Step($name) { Write-Host "`n== $name" -ForegroundColor Cyan }
function Fail($msg)  { Write-Host "PREFLIGHT RELEASE FAILED: $msg" -ForegroundColor Red; exit 1 }
function GitIn([string]$repo) {
    $ErrorActionPreference = 'Continue'   # git reports progress on stderr, which 2>&1 would otherwise make an error
    $o = & git -C $repo @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { Fail "git $($args -join ' ') in ${repo}: $o" }
    $o
}

$release = Join-Path $dist 'release.ps1'
function Status {
    $repos = & $release status
    if ($LASTEXITCODE -ne 0) { Fail 'release.ps1 status' }
    $repos
}

$suite = Get-Content (Join-Path $dist 'installer-suite.json') -Raw | ConvertFrom-Json
$apps = foreach ($m in $suite.members) {
    $config = [IO.Path]::GetFullPath((Join-Path $dist $m.config))
    [pscustomobject]@{ Config = $config; Repo = Split-Path $config -Parent }
}

# ---- 1. sources ------------------------------------------------------------------------
Step 'sources'
$repos = @(Status)
$distBranch = (GitIn $dist branch --show-current) -join ''
$distChanged = @(GitIn $dist status --porcelain -uno).Count
$problems = @($repos | Where-Object { $_.Branch -ne 'develop' -or $_.Changed -gt 0 } |
              ForEach-Object { "$($_.Repo): on $($_.Branch), $($_.Changed) changed file(s)" })
if ($distBranch -ne 'develop' -or $distChanged -gt 0) { $problems += "vexelray-dist: on $distBranch, $distChanged changed file(s)" }
$dirty = $problems.Count -gt 0
if ($dirty) {
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    if (-not $AllowDirty) { Fail 'commit (or put aside) these first, on develop; -AllowDirty builds them anyway, for a local try only' }
    Write-Host '  -AllowDirty: building them as they are. This preflight will not be published.' -ForegroundColor Yellow
} else {
    Write-Host "  $($repos.Count) repositories on develop, nothing uncommitted"
}

# ---- 2. versions -----------------------------------------------------------------------
Step 'versions'
$released = @($repos | Where-Object { $_.Version -notlike '*-SNAPSHOT' })
if ($released.Count -gt 0) {
    $released | ForEach-Object { Write-Host "  $($_.Repo) is at $($_.Version)" }
    if ($NoBump) { Fail 'the repositories are at a release, and -NoBump says not to move them to the next snapshot' }
    if ($released.Count -ne $repos.Count) { Fail 'only some repositories are at a release; release.ps1 next moves all of them, so sort this out by hand' }
    Write-Host '  moving every repository to the next snapshot (release.ps1 next)'
    & $release next
    if ($LASTEXITCODE -ne 0) { Fail 'release.ps1 next; see logs\next-*.log' }
    $repos = @(Status)
}
$synced = $false
foreach ($a in $apps) {
    $r = $repos | Where-Object { $_.Repo -eq (Split-Path $a.Repo -Leaf) } | Select-Object -First 1
    if (-not $r) { Fail "$($a.Repo) is in the suite but not in release.ps1's list" }
    $text = [IO.File]::ReadAllText($a.Config)
    $rx = [regex]'("version"\s*:\s*")([^"]*)(")'
    $m = $rx.Match($text)
    if (-not $m.Success) { Fail "$($a.Config) has no version" }
    if ($m.Groups[2].Value -eq $r.Version) { Write-Host "  $($r.Repo) $($r.Version)"; continue }
    Write-Host "  $($r.Repo): installer.json $($m.Groups[2].Value) -> $($r.Version)"
    [IO.File]::WriteAllText($a.Config, $rx.Replace($text, "`${1}$($r.Version)`${3}", 1), (New-Object Text.UTF8Encoding $false))
    if (-not $dirty) {
        GitIn $a.Repo add installer.json | Out-Null
        GitIn $a.Repo commit -q -m "installer.json at $($r.Version)" -m $trailer | Out-Null
        $synced = $true
    }
}
if ($synced) { $repos = @(Status) }   # BUILD.txt names the commits built

# ---- 3. build --------------------------------------------------------------------------
Step 'build'
$pfArgs = @{ BuildOnly = $true }
if ($SkipBuild) { $pfArgs.SkipBuild = $true }
if (-not $SkipLocal) { $pfArgs.LinuxLocal = $true }
& (Join-Path $dist 'preflight.ps1') @pfArgs
if ($LASTEXITCODE -ne 0) { Fail 'preflight.ps1 (above)' }
foreach ($a in $apps) {
    if (git -C $a.Repo status --porcelain -- THIRD-PARTY-NOTICES.txt) {
        Write-Host "  $(Split-Path $a.Repo -Leaf): THIRD-PARTY-NOTICES.txt changed; it is in this build, so commit it" -ForegroundColor Yellow
    }
}

function Write-Build([string]$folder, [string]$where) {
    $lines = @("$($suite.name) preflight, built $(Get-Date -Format 'yyyy-MM-dd HH:mm') $where", '')
    $lines += $repos | ForEach-Object { '{0,-24} {1,-16} {2,-9} {3}' -f $_.Repo, $_.Version, $_.Commit, $_.Subject }
    if ($dirty) { $lines += @('', 'Built with uncommitted changes (-AllowDirty).') }
    New-Item -ItemType Directory -Force $folder | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'BUILD.txt'), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}
$configs = @{}
foreach ($a in $apps) { $c = Get-Content $a.Config -Raw | ConvertFrom-Json; $configs[$c.id] = $c }

# ---- 4. local --------------------------------------------------------------------------
if (-not $SkipLocal) {
    Step 'local'
    try { & (Join-Path $dist 'deploy.ps1') -Local -Port $Port } catch { Fail "deploy.ps1 -Local: $_" }
    Write-Build (Join-Path $dist 'local') "for http://127.0.0.1:$Port"
    $server = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $dist 'serve.ps1'), '-Root', (Join-Path $dist 'local'), '-Port', $Port
    try {
        $up = $false
        for ($i = 0; $i -lt 40 -and -not $up; $i++) {
            Start-Sleep -Milliseconds 250
            if ($server.HasExited) { Fail "the local server stopped; is port $Port in use? (-Port to change)" }
            try { Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/install.ps1" -TimeoutSec 2 | Out-Null; $up = $true } catch {}
        }
        if (-not $up) { Fail "the local server did not answer on port $Port" }
        $command = "irm http://127.0.0.1:$Port/install.ps1 | iex"
        Write-Host "  $command"
        Write-Host '  in a window of its own; close it when it is done'
        # Encoded: Windows PowerShell hands `-Command "irm ... | iex"` to iex a line at a time.
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Start-Process powershell -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
    } finally {
        Stop-Process $server -Force -ErrorAction SilentlyContinue
    }
    $registry = Join-Path $env:LOCALAPPDATA 'vexelray-installer\installs'
    $notInstalled = @()
    foreach ($id in $configs.Keys) {
        $rec = Join-Path $registry "$id.json"
        $got = if (Test-Path $rec) { (Get-Content $rec -Raw | ConvertFrom-Json).version }
        $want = $configs[$id].version
        if ($got -eq $want) { Write-Host "  $($configs[$id].name) $got installed" -ForegroundColor Green }
        else { Write-Host "  $($configs[$id].name): $(if ($got) { $got } else { 'not' }) installed, not $want" -ForegroundColor Yellow; $notInstalled += $id }
    }
    if ($notInstalled) { Fail "the local install did not install $($notInstalled -join ', ') (unticked, or failed: see its log)" }
}

# ---- 5. publish ------------------------------------------------------------------------
$url = "https://raw.githubusercontent.com/$($suite.repo)/$($suite.branch)/preflight/install.ps1"
if ($LocalOnly -or $dirty) {
    Write-Host "`nPreflight built and tried locally; nothing published." -ForegroundColor Green
    if (-not $dirty) { Write-Host 'To publish this build: .\release-preflight.ps1 -SkipBuild -SkipLocal -Publish' }
    exit 0
}
if (-not $Publish) {
    Write-Host ''
    $answer = Read-Host "Publish this preflight? It uploads $($configs.Count) snapshot releases and pushes the manifests and preflight\ to main [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Not published. To publish it later: .\release-preflight.ps1 -SkipBuild -SkipLocal -Publish'; exit 0 }
}
Step 'publish'
try { & (Join-Path $dist 'deploy.ps1') -Preflight -Publish } catch { Fail "deploy.ps1 -Preflight -Publish: $_" }
Write-Build (Join-Path $dist 'preflight') "for $url"
GitIn $dist add apps preflight | Out-Null
$version = ($repos | Where-Object { $_.Repo -eq 'vexelray-framework' }).Version
GitIn $dist commit -q -m "Preflight $version, $(Get-Date -Format 'yyyy-MM-dd')" -m $trailer | Out-Null
GitIn $dist push -q origin develop | Out-Null
GitIn $dist checkout -q main | Out-Null
try {
    GitIn $dist pull -q --ff-only origin main | Out-Null
    GitIn $dist merge -q --no-edit develop | Out-Null
    GitIn $dist push -q origin main | Out-Null
} finally {
    git -C $dist checkout -q develop
}
Write-Host "`nPreflight published. Install it with:" -ForegroundColor Green
Write-Host "  irm $url | iex"
Write-Host "GitHub's raw host can take a few minutes to catch up."
