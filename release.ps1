<#
.SYNOPSIS
  Cuts a source release of every VexelRay repository, publishes it, or moves them all to the next snapshot.

.DESCRIPTION
  A release is cut here, on Windows, which always goes first: on a release branch cut from develop (release/0.1.2),
  which every repository has. Each other operating system then builds that branch and deploys on its own, as late as
  it is ready; every binary names the version in the poms, and the commit it was built from.

  .\release.ps1 release  -Branch release/X   each repo: switch to the branch, X-SNAPSHOT -> X, build and test all in
                          order, then commit "Release X" and tag vX (only once every build has passed; a failure
                          commits nothing). The checkouts are left on the branch, to build and deploy from
  .\release.ps1 publish  -Branch release/X   each repo: push the branch and its tag vX. Every repo is checked first;
                          one that cannot be published stops the run before anything is pushed
  .\release.ps1 next      each repo: switch to develop, X-SNAPSHOT -> X+1-SNAPSHOT (last number bumped) once vX is
                          tagged, install all, commit
  .\release.ps1 finish   -Branch release/X   publish, next, then push each develop
  .\release.ps1 deployed -Branch release/X -Platform windows|linux
                          each repo that platform was built from: tag vX-<platform> on the commit it was built from
                          (this checkout's HEAD; for linux, the commits in logs\linux\BUILD.txt) and push the tag, so
                          the repositories say what each platform shipped. Run it right after that platform's publish
  .\release.ps1 switch   -Branch release/X   each repo onto that branch (or develop), once none has uncommitted
                          changes: for the Linux VM, which shares these checkouts, after next moved develop on
  .\release.ps1 status   each repo: name, version, branch, commit, changed files, subject

  -DryRun                 publish, finish and deployed: the checks, and what would be pushed, without pushing

  Run with the sibling checkouts beside this folder and clean working trees for the poms. Only publish, finish and
  deployed push. Logs land in logs\.

  Only the version strings are rewritten: in every tracked pom.xml, and in vexelray-framework's project template
  presets. A -SNAPSHOT string that is not some repository's own version stops the run, because the rewrite would
  otherwise leave a dependency behind.
#>
param([Parameter(Position = 0)][ValidateSet('release', 'publish', 'next', 'finish', 'deployed', 'switch', 'status')][string]$Command,
      [string]$Branch, [ValidateSet('windows', 'linux')][string]$Platform, [switch]$DryRun)
$ErrorActionPreference = 'Stop'

$Here  = $PSScriptRoot
$Root  = Split-Path $Here -Parent
$Logs  = Join-Path $Here 'logs'
$Repos = ('vexelray-build intrabuf atchung supirvast dxgi-bridge kronometer tactroller vexelray imagelib-wrapper ' +
          'vexelray-gui vexelray-framework ffmpeg-wrapper vexelray-codec vex-suite-common cott-engine cardinal ' +
          'concordance-indexer vexelray-sim-core vexelray-installer mainframe text-editor-vexel-demo Pix vexplore ' +
          'vexelray-sim-fluid vexelray-sim-rigid calculator-vexel-demo vexelray-maistro vexelray-inspector') -split ' '
$Template = 'vexelray-framework-template/src/main/resources/dev/vexelray/framework/template/vexel-desktop/template.manifest'
$Trailer  = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
$Snapshot = [regex]'\d+(?:\.\d+)*-SNAPSHOT'
$Utf8     = New-Object Text.UTF8Encoding $false

function Say([string]$msg) { Write-Host $msg }
function Stop-Release([string]$msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

function Quote([string]$a) {
    if ($a -and $a -notmatch '[\s"]') { return $a }
    '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# A console program with no window of its own (a console-less caller would otherwise flash one per call), its
# output read exactly as it was written: git show's text is written back into the poms.
function Run([string]$exe, [string[]]$a, [string]$dir, [string]$raw) {
    if (-not $raw) { $raw = ($a | ForEach-Object { Quote $_ }) -join ' ' }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe, $raw
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    if ($dir) { $psi.WorkingDirectory = $dir }
    $p = [Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err.Result }
}

# The arguments flattened, so a list of files passes as files. A bare -- would be taken by PowerShell itself: quote it.
function Git([string]$repo) {
    $a = @($args | ForEach-Object { $_ })
    $r = Run 'git' (@('-C', (Join-Path $Root $repo)) + $a) $null
    if ($r.Code -ne 0) { throw "git $($a -join ' ') in ${repo}: $($r.Err.Trim())" }
    $r.Out
}
function Ok([string]$repo) { (Run 'git' (@('-C', (Join-Path $Root $repo)) + @($args | ForEach-Object { $_ })) $null).Code -eq 0 }
function Lines([string]$text) { @($text -split "`r?`n" | Where-Object { $_ }) }

function Files([string]$repo) {
    # the template's files/pom.xml is the version a generated project starts at, not a reference to the stack
    $fs = @(Lines (Git $repo ls-files) | Where-Object { $_.EndsWith('pom.xml') -and $_ -notlike '*/vexel-desktop/files/*' })
    if ($repo -eq 'vexelray-framework') { $fs += $Template }
    $fs
}

function Own-Version([string]$repo, [string]$rev = 'HEAD') {
    $body = [regex]::Replace((Git $repo show "${rev}:pom.xml"), '(?s)<parent>.*?</parent>', '')
    ([regex]'<version>([^<]+)</version>').Match($body).Groups[1].Value
}

function Bump([string]$release) {
    $parts = $release.Split('.')
    $parts[-1] = [string]([int]$parts[-1] + 1)
    ($parts -join '.') + '-SNAPSHOT'
}

# Each file as it is at rev, with exactly the strings in mapping replaced, in the file's own line endings.
function Rewrite([string]$repo, $mapping, [string]$rev) {
    foreach ($f in Files $repo) {
        $text = (Git $repo show "${rev}:$f").Replace("`r`n", "`n")
        foreach ($old in $mapping.Keys) {
            $text = [regex]::Replace($text, '(?<![\w.])' + [regex]::Escape($old) + '(?![\w.-])', $mapping[$old].Replace('$', '$$'))
        }
        $path = Join-Path (Join-Path $Root $repo) $f
        if ([IO.File]::ReadAllText($path).Contains("`r`n")) { $text = $text.Replace("`n", "`r`n") }
        [IO.File]::WriteAllText($path, $text, $Utf8)
    }
}

function Mvn([string]$repo, [string]$goals, [string]$log) {
    # As build.cmd does: vexplore's RemotesTest runs Git's sftp-server.exe, which needs msys-2.0.dll from Git's
    # usr\bin. Appended, not prepended, so usr\bin's own tools never shadow the system's.
    $path = $env:PATH
    $env:PATH = "$path;C:\Program Files\Git\usr\bin"
    try {
        # cmd.exe parses its own command line, so it gets it as written, not quoted for a C program
        $r = Run 'cmd.exe' @() (Join-Path $Root $repo) "/d /c `"mvn -B $goals > `"$(Join-Path $Logs $log)`" 2>&1`""
    } finally {
        $env:PATH = $path
    }
    $r.Code -eq 0
}

function Commit([string]$repo, [string]$subject) {
    foreach ($f in Files $repo) { Git $repo add $f | Out-Null }
    Git $repo commit -q -m $subject -m $Trailer | Out-Null
}

function Need-Branch {
    if (-not $Branch) { Stop-Release "$Command needs -Branch, the release branch (release/0.1.2)" }
}

# Every repo onto the release branch, all checked before any moves: each has it, and nothing uncommitted.
function Switch-ToBranch {
    $problems = @()
    foreach ($r in $Repos) {
        if (-not (Ok $r rev-parse -q --verify "refs/heads/$Branch")) { $problems += "$r has no branch $Branch" }
        if ((Git $r status --porcelain -uno).Trim()) { $problems += "$r has uncommitted changes" }
    }
    if ($problems) { Stop-Release ("Nothing switched:`n  " + ($problems -join "`n  ")) }
    foreach ($r in $Repos) { Git $r switch -q $Branch | Out-Null }
    Say "every repository is on $Branch"
}

function Do-Release {
    Need-Branch
    Switch-ToBranch
    $snapshots = [ordered]@{}
    foreach ($r in $Repos) { $snapshots[$r] = Own-Version $r }
    foreach ($r in $Repos) {
        $v = $snapshots[$r]
        if (-not $v.EndsWith('-SNAPSHOT')) { Stop-Release "$r is at $v, not a snapshot" }
        $rel = $v.Substring(0, $v.Length - '-SNAPSHOT'.Length)
        if ((Git $r tag -l "v$rel").Trim()) { Stop-Release "$r already has the tag v$rel" }
    }
    $mapping = [ordered]@{}
    foreach ($v in $snapshots.Values) { $mapping[$v] = $v.Substring(0, $v.Length - '-SNAPSHOT'.Length) }
    foreach ($r in $Repos) {
        foreach ($f in Files $r) {
            $stray = @($Snapshot.Matches((Git $r show "HEAD:$f")) | ForEach-Object { $_.Value } |
                       Where-Object { -not $mapping.Contains($_) } | Sort-Object -Unique)
            if ($stray) { Stop-Release "$r/$f names $($stray -join ', '), which is no repository's own version" }
        }
    }
    foreach ($r in $Repos) { Rewrite $r $mapping 'HEAD' }
    Say 'versions rewritten'
    foreach ($r in $Repos) {
        Say "[$r] clean install $($mapping[$snapshots[$r]])"
        if (-not (Mvn $r 'clean install' "release-$r.log")) {
            Stop-Release ("[$r] BUILD FAILED, see logs\release-$r.log; nothing committed " +
                          '(the rewritten poms are left in place: git checkout -- . in each repo to drop them)')
        }
    }
    foreach ($r in $Repos) {
        $v = $mapping[$snapshots[$r]]
        Commit $r "Release $v"
        Git $r tag -a "v$v" -m "Release $v" | Out-Null
        Say "[$r] committed and tagged v$v"
    }
    Say 'RELEASE DONE'
}

# The tag of the release HEAD is at: vX for the poms' X, with HEAD at it or after it (an app commits its
# installer.json after the release), and the poms unchanged since. Returns the tag, or why there is none.
function Release-Tag([string]$repo) {
    $v = Own-Version $repo
    $tag = "v$v"
    if ($v.EndsWith('-SNAPSHOT')) { return @($null, "$repo is at $v, not a release") }
    if (-not (Git $repo tag -l $tag).Trim()) { return @($null, "$repo is at $v but has no tag $tag") }
    if (-not (Ok $repo merge-base --is-ancestor $tag HEAD)) { return @($null, "${repo}: $tag is not on HEAD's history") }
    if (-not (Ok $repo diff --quiet $tag HEAD '--' (Files $repo))) { return @($null, "${repo}: the poms changed after $tag") }
    @($tag, $null)
}

function Do-Publish {
    Need-Branch
    $plan = @(); $problems = @()
    foreach ($r in $Repos) {
        if ((Lines (Git $r remote)) -notcontains 'origin') { $problems += "$r has no origin remote"; continue }
        if (-not (Ok $r fetch -q --tags origin)) { $problems += "${r}: fetching origin failed"; continue }
        if ((Git $r branch --show-current).Trim() -ne $Branch) { $problems += "$r is not on $Branch"; continue }
        $tag, $why = Release-Tag $r
        if ($why) { $problems += $why; continue }
        if ((Git $r status --porcelain -uno).Trim()) { $problems += "$r has uncommitted changes" }
        if ((Ok $r rev-parse -q --verify "refs/remotes/origin/$Branch") -and
            -not (Ok $r merge-base --is-ancestor "origin/$Branch" $Branch)) {
            $problems += "${r}: origin/$Branch has commits $Branch has not"
        }
        $plan += [pscustomobject]@{ Repo = $r; Tag = $tag }
    }
    if ($problems) { Stop-Release ("Nothing pushed:`n  " + ($problems -join "`n  ")) }
    foreach ($p in $plan) { Say "[$($p.Repo)] push $Branch and $($p.Tag)" }
    if ($DryRun) { Say 'DRY RUN: nothing pushed'; return }
    foreach ($p in $plan) {
        $r = $p.Repo
        # a plain push, so origin refuses anything but a fast-forward
        if (-not (Ok $r push -q origin $Branch $p.Tag)) {
            Stop-Release "[$r] push failed; the repositories before it are published, rerun to go on"
        }
        Say "[$r] published $($p.Tag) on $Branch"
    }
    Say 'PUBLISH DONE'
}

# develop, still at the X-SNAPSHOT the release branch was cut at, moves on once vX is tagged there.
function Do-Next {
    $problems = @()
    foreach ($r in $Repos) {
        if ((Git $r status --porcelain -uno).Trim()) { $problems += "$r has uncommitted changes"; continue }
        $v = Own-Version $r 'develop'
        if (-not $v.EndsWith('-SNAPSHOT')) { $problems += "${r}: develop is at $v, not a snapshot"; continue }
        $rel = $v.Substring(0, $v.Length - '-SNAPSHOT'.Length)
        if (-not (Git $r tag -l "v$rel").Trim()) { $problems += "${r}: develop is at $v, and v$rel is not tagged yet" }
    }
    if ($problems) { Stop-Release ("Nothing moved:`n  " + ($problems -join "`n  ")) }
    foreach ($r in $Repos) { Git $r switch -q develop | Out-Null }
    # Only whole X-SNAPSHOT strings: a bare "1.0" is also the XML declaration's version and any number of other
    # things, so it is never what gets matched.
    $mapping = [ordered]@{}
    foreach ($r in $Repos) {
        $v = Own-Version $r
        $mapping[$v] = Bump $v.Substring(0, $v.Length - '-SNAPSHOT'.Length)
    }
    foreach ($r in $Repos) { Rewrite $r $mapping 'HEAD' }
    Say 'versions rewritten'
    foreach ($r in $Repos) {
        Say "[$r] install"
        if (-not (Mvn $r 'install -DskipTests' "next-$r.log")) { Stop-Release "[$r] BUILD FAILED, see logs\next-$r.log; nothing committed" }
    }
    foreach ($r in $Repos) {
        Commit $r 'Next development version'
        Say "[$r] $(Own-Version $r)"
    }
    Say 'NEXT DONE'
}

# vX-<platform> on the commit each repository's build for that platform was made from. Each binary names its commit
# too, but only to someone holding it: the tags say in the repositories what each platform shipped as X, to diff,
# rebuild or branch a fix from.
function Do-Deployed {
    Need-Branch
    if (-not $Platform) { Stop-Release 'deployed needs -Platform: windows or linux' }
    $built = [ordered]@{}
    if ($Platform -eq 'linux') {
        $stamp = Join-Path $Logs 'linux\BUILD.txt'
        if (-not (Test-Path $stamp)) { Stop-Release 'no logs\linux\BUILD.txt: nothing says what the Linux build was made from' }
        foreach ($line in Get-Content $stamp) {
            if ($line -match '^\s*(#|$)') { continue }
            $f = $line -split '\s+'
            if ($Repos -contains $f[0]) { $built[$f[0]] = $f[1] }
        }
    } else {
        foreach ($r in $Repos) {
            if ((Git $r branch --show-current).Trim() -ne $Branch) { Stop-Release "$r is not on $Branch, so its HEAD is not what $Platform was built from" }
            if ((Git $r status --porcelain -uno).Trim()) { Stop-Release "$r has uncommitted changes, so its HEAD is not what $Platform was built from" }
            $built[$r] = (Git $r rev-parse HEAD).Trim()
        }
    }
    $plan = @(); $problems = @()
    foreach ($r in $built.Keys) {
        $c = $built[$r]
        if (-not (Ok $r merge-base --is-ancestor $c $Branch)) { $problems += "${r}: $($c.Substring(0, 9)) is not on $Branch"; continue }
        $v = Own-Version $r $c
        if ($v.EndsWith('-SNAPSHOT')) { $problems += "${r}: $($c.Substring(0, 9)) is at $v, before the release"; continue }
        if (-not (Ok $r merge-base --is-ancestor "v$v" $c)) { $problems += "${r}: v$v is not in the history of $($c.Substring(0, 9))"; continue }
        $tag = "v$v-$Platform"
        $have = (Git $r tag -l $tag).Trim()
        if ($have -and (Git $r rev-parse "$tag^{commit}").Trim() -ne $c) { $problems += "${r}: $tag is already on another commit"; continue }
        $plan += [pscustomobject]@{ Repo = $r; Tag = $tag; Commit = $c; Version = $v; New = -not $have }
    }
    if ($problems) { Stop-Release ("Nothing tagged:`n  " + ($problems -join "`n  ")) }
    foreach ($p in $plan) { Say "[$($p.Repo)] $($p.Tag) on $($p.Commit.Substring(0, 9))$(if (-not $p.New) { ', already tagged' })" }
    if ($DryRun) { Say 'DRY RUN: nothing tagged or pushed'; return }
    foreach ($p in $plan) {
        if ($p.New) { Git $p.Repo tag -a $p.Tag $p.Commit -m "Release $($p.Version) for $Platform" | Out-Null }
        if (-not (Ok $p.Repo push -q origin $p.Tag)) { Stop-Release "[$($p.Repo)] pushing $($p.Tag) failed; rerun to go on" }
    }
    Say 'DEPLOYED TAGS DONE'
}

function Do-PushDevelop {
    foreach ($r in $Repos) {
        if (-not (Ok $r push -q origin develop)) { Stop-Release "[$r] pushing develop failed" }
        Say "[$r] pushed develop at $(Own-Version $r)"
    }
    Say 'PUSH DONE'
}

# What a build of every repository would be built from; release-preflight.ps1 reads it.
function Do-Status {
    foreach ($r in $Repos) {
        [pscustomobject]@{
            Repo    = $r
            Version = Own-Version $r
            Branch  = (Git $r branch --show-current).Trim()
            Commit  = (Git $r rev-parse --short HEAD).Trim()
            Changed = @(Lines (Git $r status --porcelain -uno)).Count
            Subject = (Git $r log -1 --format=%s).Trim()
        }
    }
}

New-Item -ItemType Directory -Force $Logs | Out-Null
# Exits 0 or 1 either way, so a caller can go by $LASTEXITCODE (this script runs git and mvn without setting it).
try {
    switch ($Command) {
        'release' { Do-Release }
        'publish' { Do-Publish }
        'next'    { Do-Next }
        'finish'  { Do-Publish; if (-not $DryRun) { Do-Next; Do-PushDevelop } }
        'deployed' { Do-Deployed }
        'switch'  { Need-Branch; Switch-ToBranch }
        'status'  { Do-Status }
        default   { Get-Help $PSCommandPath -Detailed; exit 1 }
    }
} catch {
    Stop-Release "$_"
}
exit 0
