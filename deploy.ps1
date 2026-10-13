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

  -Publish also creates each release (tag <id>-v<version>) on sibarum/vexelray-dist and uploads its files.
  It needs a GitHub token in $env:GITHUB_TOKEN. Commit and push afterwards: the manifests name the uploads.
#>
param([switch]$Publish)
$ErrorActionPreference = 'Stop'

$dist = $PSScriptRoot
$root = Split-Path $dist -Parent
$jar  = Join-Path $root 'vexelray-installer\installer-core\target\installer-core-0.1.0-SNAPSHOT-cli.jar'
if (-not (Test-Path $jar)) { throw "Not built: $jar (mvn install in vexelray-installer)" }
if ($Publish -and -not $env:GITHUB_TOKEN) { throw 'Set $env:GITHUB_TOKEN to publish.' }

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
