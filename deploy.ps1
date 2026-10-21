<#
.SYNOPSIS
  Generates every application's installer and the suite installer into this repository, and optionally publishes.

.DESCRIPTION
  Reads each application's installer.json from the sibling checkouts and the native images their builds left in
  target\ (run build.cmd first) and, for an application with a linux section, target-linux\ (build.sh, in the
  Linux VM; preflight.ps1 checks that build is of these sources). Writes:
    apps\<id>\         install.ps1, uninstall.ps1, update.ps1, manifest.json, README.md   (committed)
                       and, with a linux section, install.sh, uninstall.sh, update.sh, manifest.linux.txt
    install.ps1, install.sh, README.md                                        the suite      (committed)
    assets\<id>\<ver>\ each application's exe, Linux binaries and icons, as uploaded to its release (ignored)
    exe\               every exe in one place                                                (ignored)
  and, when the sibling checkout ..\sibarum.github.io exists, the landing page served at https://sibarum.github.io:
    index.html, install.ps1, install.sh, img\                        (committed and pushed there)

  -Publish also creates each release (tag <id>-v<version>) on sibarum/vexelray-dist and uploads its files.
  It uses $env:GITHUB_TOKEN if set, and otherwise asks for a token (input hidden, never stored): a fine-grained
  token with Contents: read and write on vexelray-dist. Commit and push afterwards: the manifests name the uploads.

  -Preflight is for snapshot builds (every installer.json at an X-SNAPSHOT version). It writes the applications as
  above, but instead of the suite and the landing page it writes preflight\install.ps1 and README.md: a suite that
  installs exactly these versions, rather than each application's latest release.

  -Local writes the same preflight, but all of it into local\ (ignored) and pointing at http://127.0.0.1:<Port>
  instead of GitHub: apps\<id>\, releases\<tag>\ (laid out as GitHub's release downloads are) and install.ps1.
  Serve local\ there (serve.ps1) and the scripts install from this computer exactly as they would from GitHub.
  It never publishes, and changes nothing outside local\ and logs\.
#>
param([switch]$Publish, [switch]$Preflight, [switch]$Local, [int]$Port = 8417)
$ErrorActionPreference = 'Stop'
if ($Local -and $Publish) { throw '-Local publishes nothing; use -Preflight -Publish' }

$dist = $PSScriptRoot
$root = Split-Path $dist -Parent
$jar  = Get-ChildItem (Join-Path $root 'vexelray-installer\installer-core\target') -Filter 'installer-core-*-cli.jar' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $jar) { throw 'Not built: the installer CLI jar (mvn install in vexelray-installer)' }
$suite = Get-Content (Join-Path $dist 'installer-suite.json') -Raw | ConvertFrom-Json
$members = foreach ($m in $suite.members) {
    $config = [IO.Path]::GetFullPath((Join-Path $dist $m.config))
    [pscustomobject]@{ Member = $m; Config = $config; App = Get-Content $config -Raw | ConvertFrom-Json }
}
if ($Preflight -or $Local) {
    # a preflight must never publish a release: those are final
    $released = @($members | Where-Object { $_.App.version -notlike '*-SNAPSHOT' } | ForEach-Object { "$($_.App.name) $($_.App.version)" })
    if ($released) { throw "A preflight is of snapshots; these are at release versions: $($released -join ', ')" }
}
$base = "http://127.0.0.1:$Port"
$out = if ($Local) { Join-Path $dist 'local' } else { $dist }
if ($Local -and (Test-Path $out)) { Remove-Item -Recurse -Force $out }

$askedForToken = $false
if ($Publish -and -not $env:GITHUB_TOKEN) {
    # A fine-grained token with Contents: read and write on sibarum/vexelray-dist. Asked for, not stored:
    # it lives in this process's environment only for the run, and is cleared at the end.
    $secure = Read-Host -Prompt 'GitHub token (Contents: read and write on vexelray-dist)' -AsSecureString
    $env:GITHUB_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if (-not $env:GITHUB_TOKEN) { throw 'No token given.' }
    $askedForToken = $true
}
try {

New-Item -ItemType Directory -Force (Join-Path $dist 'exe') | Out-Null

foreach ($a in $members) {
    $app = $a.App
    $appOut = Join-Path $out "apps\$($app.id)"
    $assets = Join-Path $out "assets\$($app.id)"
    $javaArgs = @('-jar', $jar, '--config', $a.Config, '--version', $app.version, '--out', $appOut, '--assets', $assets)
    if ($Local) { $javaArgs += @('--base-url', "$base/apps/$($app.id)", '--asset-base-url', "$base/releases") }
    if ($Publish) { $javaArgs += '--publish' }
    Write-Host "== $($app.name) $($app.version)"
    & java @javaArgs
    if ($LASTEXITCODE -ne 0) { throw "Generating $($app.name) failed" }
    if ($Local) {
        # where --asset-base-url says each file is, <base>/<tag>/<file>, as on GitHub
        $tagFormat = if ($app.tagFormat) { $app.tagFormat } else { 'v{version}' }
        $release = Join-Path $out "releases\$($tagFormat.Replace('{version}', $app.version))"
        New-Item -ItemType Directory -Force $release | Out-Null
        Copy-Item (Join-Path $assets "$($app.version)\*") $release -Force
    } else {
        Copy-Item (Join-Path $assets "$($app.version)\*.exe") (Join-Path $dist 'exe') -Force
    }
}

if ($Preflight -or $Local) {
    # The suite, with every member pinned to the version just generated.
    $pinned = [ordered]@{
        id = "$($suite.id)-preflight"
        name = "$($suite.name) preflight"
        description = "Snapshot builds of every $($suite.name) application, built together from the same sources, to try before they are released. The install command for the releases is in the README one folder up."
        repo = $suite.repo
        branch = $suite.branch
        repoPath = 'preflight'
        members = @($members | ForEach-Object {
            $p = [ordered]@{ config = $_.Config; version = $_.App.version }
            if ($_.Member.page) { $p.page = $_.Member.page }
            if ($Local) { $p.manifestUrl = "$base/apps/$($_.App.id)/manifest.json" }
            $p
        })
    }
    $logs = Join-Path $dist 'logs'
    New-Item -ItemType Directory -Force $logs | Out-Null
    $pinnedPath = Join-Path $logs 'preflight-suite.json'
    [IO.File]::WriteAllText($pinnedPath, ($pinned | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    $suiteOut = if ($Local) { $out } else { Join-Path $dist 'preflight' }
    Write-Host '== preflight suite'
    $javaArgs = @('-jar', $jar, '--suite', $pinnedPath, '--out', $suiteOut)
    if ($Local) { $javaArgs += @('--base-url', $base) }
    & java @javaArgs
    if ($LASTEXITCODE -ne 0) { throw 'Generating the preflight suite failed' }
    return
}

Write-Host '== suite'
& java -jar $jar --suite (Join-Path $dist 'installer-suite.json') --out $dist
if ($LASTEXITCODE -ne 0) { throw 'Generating the suite failed' }

$site = Join-Path $root 'sibarum.github.io'
if (Test-Path (Join-Path $site '.git')) {
    Write-Host '== landing page'
    & java -jar $jar --suite (Join-Path $dist 'installer-suite.json') --site --out $site
    if ($LASTEXITCODE -ne 0) { throw 'Generating the landing page failed' }
} else {
    Write-Warning "No checkout at ${site}: the landing page was not regenerated"
}
} finally {
    if ($askedForToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
}
