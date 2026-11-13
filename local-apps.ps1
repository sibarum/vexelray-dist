<#
.SYNOPSIS
  Builds the stack and some of the applications, and installs those on this computer from local installers.

.DESCRIPTION
  The everyday loop: "framework build, native image of these apps, and installers". The libraries are clean-installed
  in order (build.cmd), then each named application is tested and built as its release native image, started to see
  that it stays up, given its installer (as deploy.ps1 -Local -Platform windows does, for these applications only),
  and installed from local\ served at http://127.0.0.1:<Port>, quietly. Last, each install record's exe is compared
  with the one just built.

  An application whose tests or native image fail is reported and left out of the rest; the others go on. A library
  that fails stops everything. Nothing is published, committed or pushed, and Linux is not involved.

  Applications are named by checkout (mainframe), by installer id (text-editor), or by name with or without
  "VexelRay " (IDE, Rasterware, Inspector): whatever installer-suite.json lists.

  Run from PowerShell, not Git Bash (vcvars64.bat, and MSVC's link.exe). From an agent's shell, run it inside one
  hidden console (Start-Process powershell -WindowStyle Hidden ... -PassThru; $p.WaitForExit()), or every child
  flashes a window. Logs are in logs\ as build.cmd's are.

.EXAMPLE
  .\local-apps.ps1 IDE, MainFrame, Vexplore, Inspector, Rasterware
.EXAMPLE
  .\local-apps.ps1 mainframe -SkipBuild        # installers and install from the exe already in target\
#>
param([Parameter(Mandatory)][string[]]$Apps, [switch]$SkipBuild, [switch]$NoInstall, [int]$Port = 8417,
      [int]$Seconds = 8)
$ErrorActionPreference = 'Stop'
$dist = $PSScriptRoot
$root = Split-Path $dist -Parent

# ---- which applications ----------------------------------------------------------------
$suite = Get-Content (Join-Path $dist 'installer-suite.json') -Raw | ConvertFrom-Json
$known = foreach ($m in $suite.members) {
    $config = [IO.Path]::GetFullPath((Join-Path $dist $m.config))
    $app = Get-Content $config -Raw | ConvertFrom-Json
    $exeBins = @($app.windows.binaries | Where-Object { $_.source -like '*.exe' })
    $exes = @($exeBins | ForEach-Object { Join-Path (Split-Path $config -Parent) $_.source })
    # The name the exe is installed under: its "file" when the installer renames it (vexelray-maistro.exe is maistro.exe).
    $installedExe = if ($exeBins -and $exeBins[0].file) { $exeBins[0].file } elseif ($exes) { Split-Path $exes[0] -Leaf }
    [pscustomobject]@{ Member = $m; Config = $config; App = $app; Checkout = Split-Path (Split-Path $config -Parent) -Leaf
                       Exe = $exes[0]; InstalledExe = $installedExe; Names = @((Split-Path (Split-Path $config -Parent) -Leaf), $app.id, $app.name,
                                                  ($app.name -replace '^VexelRay ', '')) }
}
$chosen = foreach ($a in $Apps) {
    $hit = @($known | Where-Object { $_.Names -contains $a })
    if ($hit.Count -ne 1) { throw "No single application is called '$a'. Known: $(($known | ForEach-Object { $_.Checkout }) -join ', ')" }
    $hit[0]
}
$chosen = @($chosen | Sort-Object Checkout -Unique)
Write-Host "Applications: $(($chosen | ForEach-Object { $_.App.name }) -join ', ')"

# ---- 1. build ----------------------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host '== build'
    $failedApps = @()
    $libraryFailed = $false
    $checkouts = ($chosen | ForEach-Object { $_.Checkout }) -join ' '
    # call: without it cmd /c can return 0 from a batch file that ran exit /b 1 (see the end of build.cmd).
    & cmd /c "call `"$dist\build.cmd`" $checkouts" | ForEach-Object {
        Write-Host $_
        if ($_ -match '^\[(.+?)\] (NATIVE )?FAILED') {
            $name = $Matches[1]
            if ($chosen.Checkout -contains $name) { $failedApps += $name } else { $libraryFailed = $true }
        }
    }
    if ($libraryFailed) { throw 'A library failed to build; see logs\.' }
    if ($failedApps) {
        Write-Host "Left out, failed to build: $($failedApps -join ', ') (logs\app-<name>.log, logs\native-<name>.log)" -ForegroundColor Yellow
        $chosen = @($chosen | Where-Object { $failedApps -notcontains $_.Checkout })
    }
}
$missing = @($chosen | Where-Object { -not (Test-Path $_.Exe) })
if ($missing) { throw "Not built: $(($missing | ForEach-Object { $_.Exe }) -join ', ')" }
if (-not $chosen) { throw 'Nothing left to install.' }

# ---- 2. start ----------------------------------------------------------------------------
Write-Host "== start: each exe must still be running after $Seconds s"
$procs = foreach ($a in $chosen) { [pscustomobject]@{ A = $a; P = Start-Process $a.Exe -PassThru -WorkingDirectory (Split-Path $a.Exe) } }
Start-Sleep $Seconds
$died = @()
foreach ($x in $procs) {
    $x.P.Refresh()
    if ($x.P.HasExited) { $died += $x.A.App.name; Write-Host "  $($x.A.App.name): exited, code $($x.P.ExitCode)" -ForegroundColor Yellow }
    else { Write-Host "  $($x.A.App.name): running"; Stop-Process -Id $x.P.Id -Force }
}
if ($died) { throw "Did not stay up: $($died -join ', '). Its log is in its checkout's target\logs\." }

# ---- 3. installers -----------------------------------------------------------------------
Write-Host '== installers'
$jar = Get-ChildItem (Join-Path $root 'vexelray-installer\installer-core\target') -Filter 'installer-core-*-cli.jar' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $jar) { throw 'Not built: the installer CLI jar (mvn install in vexelray-installer)' }
$base = "http://127.0.0.1:$Port"
$out = Join-Path $dist 'local'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
foreach ($a in $chosen) {
    $app = $a.App
    if ($app.version -notlike '*-SNAPSHOT') { throw "$($app.name) is at a release version, $($app.version): a local install is of snapshots" }
    $appOut = Join-Path $out "apps\$($app.id)"
    $assets = Join-Path $out "assets\$($app.id)"
    & java -jar $jar --config $a.Config --version $app.version --out $appOut --assets $assets `
        --base-url "$base/apps/$($app.id)" --asset-base-url "$base/releases" --platform windows | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Generating $($app.name) failed" }
    $tagFormat = if ($app.tagFormat) { $app.tagFormat } else { 'v{version}' }
    $release = Join-Path $out "releases\$($tagFormat.Replace('{version}', $app.version))"
    New-Item -ItemType Directory -Force $release | Out-Null
    Copy-Item (Join-Path $assets "$($app.version)\*") $release -Force
    Write-Host "  $($app.name) $($app.version)"
}
$pinned = [ordered]@{
    id = "$($suite.id)-local"; name = "$($suite.name) local"
    description = "Snapshot builds of $(($chosen | ForEach-Object { $_.App.name }) -join ', '), built on this computer."
    repo = $suite.repo; branch = $suite.branch; repoPath = 'preflight'
    members = @($chosen | ForEach-Object {
        $p = [ordered]@{ config = $_.Config; version = $_.App.version; manifestUrl = "$base/apps/$($_.App.id)/manifest.json" }
        if ($_.Member.page) { $p.page = $_.Member.page }
        $p
    })
}
New-Item -ItemType Directory -Force (Join-Path $dist 'logs') | Out-Null
$pinnedPath = Join-Path $dist 'logs\local-apps-suite.json'
[IO.File]::WriteAllText($pinnedPath, ($pinned | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
& java -jar $jar --suite $pinnedPath --out $out --base-url $base | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Generating the suite failed' }
if ($NoInstall) { Write-Host "Installers in $out; serve.ps1 -Root local serves them."; return }

# ---- 4. install --------------------------------------------------------------------------
Write-Host "== install, from $base"
$server = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $dist 'serve.ps1'), '-Root', $out, '-Port', $Port
try {
    $up = $false
    for ($i = 0; $i -lt 40 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 250
        if ($server.HasExited) { throw "the local server stopped; is port $Port in use? (-Port to change)" }
        try { Invoke-WebRequest -UseBasicParsing -Uri "$base/install.ps1" -TimeoutSec 2 | Out-Null; $up = $true } catch {}
    }
    if (-not $up) { throw "the local server did not answer on port $Port" }
    # Quiet, and every member even if optional. INSTALL_CLOSE_APPS is left unset: an app holding a file open fails its
    # install, which is rolled back, rather than being closed under whoever is using it.
    $env:INSTALL_QUIET = '1'
    $env:INSTALL_EVERYTHING = '1'
    Invoke-Expression (Invoke-RestMethod "$base/install.ps1")
} finally {
    Stop-Process $server -Force -ErrorAction SilentlyContinue
    Remove-Item Env:INSTALL_QUIET, Env:INSTALL_EVERYTHING -ErrorAction SilentlyContinue
}

# ---- 5. check ------------------------------------------------------------------------------
# The versions are snapshots, the same as whatever was installed before, so the check is the exe itself.
Write-Host '== check: each installed exe is the one just built'
$registry = Join-Path $env:LOCALAPPDATA 'vexelray-installer\installs'
$wrong = @()
foreach ($a in $chosen) {
    $rec = Join-Path $registry "$($a.App.id).json"
    $want = (Get-FileHash $a.Exe -Algorithm SHA256).Hash
    $file = if (Test-Path $rec) {
        (Get-Content $rec -Raw | ConvertFrom-Json).files | Where-Object { $_.path -like '*.exe' -and $_.kind -eq 'binary' } |
            Where-Object { (Split-Path $_.path -Leaf) -eq $a.InstalledExe } | Select-Object -First 1
    }
    $ok = $file -and (Test-Path $file.path) -and (Get-FileHash $file.path -Algorithm SHA256).Hash -eq $want
    if ($ok) { Write-Host "  $($a.App.name) $($a.App.version): installed, $($file.path)" -ForegroundColor Green }
    else { Write-Host "  $($a.App.name): not the build just made (see the install output above)" -ForegroundColor Yellow; $wrong += $a.App.name }
}
if ($wrong) { throw "Not installed from this build: $($wrong -join ', ')" }
Write-Host 'Done.'
