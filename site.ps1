<#
.SYNOPSIS
  Regenerates the landing page served at https://sibarum.github.io into the sibling checkout ..\sibarum.github.io.

.DESCRIPTION
  From installer-suite.json (its site section, and each member's page, icon and image): index.html, copies of the
  suite's install.ps1 and install.sh, img\ and versions.js. Not part of a release: versions.js reads each platform's
  version from the published manifests, so the page stays right after every deploy. Run it when the site itself
  changes (a new app, a description, a screenshot), then look at the diff there, commit and push; GitHub Pages
  publishes it within a minute. Needs the installer CLI (mvn install in vexelray-installer).
#>
$ErrorActionPreference = 'Stop'
$dist = $PSScriptRoot
$root = Split-Path $dist -Parent
$site = Join-Path $root 'sibarum.github.io'
if (-not (Test-Path (Join-Path $site '.git'))) { throw "No checkout at $site" }
$jar  = Get-ChildItem (Join-Path $root 'vexelray-installer\installer-core\target') -Filter 'installer-core-*-cli.jar' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $jar) { throw 'Not built: the installer CLI jar (mvn install in vexelray-installer)' }
& java -jar $jar --suite (Join-Path $dist 'installer-suite.json') --site --out $site
if ($LASTEXITCODE -ne 0) { throw 'Generating the landing page failed' }
git -C $site status --short
