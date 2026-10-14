<#
.SYNOPSIS
  Generates every application's installer and the suite installer into this repository, and optionally publishes.

.DESCRIPTION
  Reads each application's installer.json from the sibling checkouts and the native images their builds left in
  target\ (run build.cmd first). Writes:
    apps\<id>\         install.ps1, uninstall.ps1, update.ps1, manifest.json, README.md   (committed)
    install.ps1, README.md                                                    the suite      (committed)
    assets\<id>\<ver>\ each application's exe and icon, as uploaded to its release           (ignored)
    exe\               every exe in one place                                                (ignored)
  and, when the sibling checkout ..\sibarum.github.io exists, the landing page served at https://sibarum.github.io:
    index.html, install.ps1, img\                                    (committed and pushed there)

  -Publish also creates each release (tag <id>-v<version>) on sibarum/vexelray-dist and uploads its files.
  It uses $env:GITHUB_TOKEN if set, and otherwise asks for a token (input hidden, never stored): a fine-grained
  token with Contents: read and write on vexelray-dist. Commit and push afterwards: the manifests name the uploads.
#>
param([switch]$Publish)
$ErrorActionPreference = 'Stop'

$dist = $PSScriptRoot
$root = Split-Path $dist -Parent
$jar  = Get-ChildItem (Join-Path $root 'vexelray-installer\installer-core\target') -Filter 'installer-core-*-cli.jar' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $jar) { throw 'Not built: the installer CLI jar (mvn install in vexelray-installer)' }
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

$suite = Get-Content (Join-Path $dist 'installer-suite.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force (Join-Path $dist 'exe') | Out-Null

foreach ($m in $suite.members) {
    $config = [IO.Path]::GetFullPath((Join-Path $dist $m.config))
    $app = Get-Content $config -Raw | ConvertFrom-Json
    $out = Join-Path $dist "apps\$($app.id)"
    $assets = Join-Path $dist "assets\$($app.id)"
    $javaArgs = @('-jar', $jar, '--config', $config, '--version', $app.version, '--out', $out, '--assets', $assets)
    if ($Publish) { $javaArgs += '--publish' }
    Write-Host "== $($app.name) $($app.version)"
    & java @javaArgs
    if ($LASTEXITCODE -ne 0) { throw "Generating $($app.name) failed" }
    Copy-Item (Join-Path $assets "$($app.version)\*.exe") (Join-Path $dist 'exe') -Force
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
