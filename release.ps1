<#
.SYNOPSIS
  Cuts a source release of every VexelRay repository, publishes it, or moves them all to the next snapshot.

.DESCRIPTION
  .\release.ps1 release   each repo: X-SNAPSHOT -> X, build and test all in order, then commit "Release X" and tag
                          vX (only once every build has passed; a failure commits nothing)
  .\release.ps1 publish   each repo: push develop and its release tag, and fast-forward its release branch (main or
                          master, whichever origin has; main when it has neither) to develop. Every repo is checked
                          first; one that cannot be published stops the run before anything is pushed
  .\release.ps1 next      each repo: X -> X+1-SNAPSHOT (last number bumped), install all, commit
  .\release.ps1 finish    publish, next, then push each develop: everything after a release, in one go
  .\release.ps1 status    each repo: name, version, branch, commit, changed files, subject

  -DryRun                 publish and finish: the checks, and what would be pushed, without pushing

  Run with the sibling checkouts beside this folder and clean working trees for the poms. Only publish and finish
  push. Logs land in logs\.

  Only the version strings are rewritten: in every tracked pom.xml, and in vexelray-framework's project template
  presets. A -SNAPSHOT string that is not some repository's own version stops the run, because the rewrite would
  otherwise leave a dependency behind.
#>
param([Parameter(Position = 0)][ValidateSet('release', 'publish', 'next', 'finish', 'status')][string]$Command,
      [switch]$DryRun)
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

function Do-Release {
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
    $plan = @(); $problems = @()
    foreach ($r in $Repos) {
        if ((Lines (Git $r remote)) -notcontains 'origin') { $problems += "$r has no origin remote"; continue }
        if (-not (Ok $r fetch -q --tags origin)) { $problems += "${r}: fetching origin failed"; continue }
        $tag, $why = Release-Tag $r
        if ($why) { $problems += $why; continue }
        if ((Git $r branch --show-current).Trim() -ne 'develop') { $problems += "$r is not on develop" }
        if ((Git $r status --porcelain -uno).Trim()) { $problems += "$r has uncommitted changes" }
        if ((Ok $r rev-parse -q --verify refs/remotes/origin/develop) -and
            -not (Ok $r merge-base --is-ancestor origin/develop develop)) {
            $problems += "${r}: origin/develop has commits develop has not"
        }
        # main or master, whichever origin has; main, to be created, when it has neither
        $have = @('main', 'master' | Where-Object { Ok $r rev-parse -q --verify "refs/remotes/origin/$_" })
        $branch = if ($have.Count -eq 1) { $have[0] } else { 'main' }
        if ($have.Count -gt 1) { $problems += "${r}: origin has both main and master; which one releases is unclear" }
        elseif ($have.Count -eq 1 -and -not (Ok $r merge-base --is-ancestor "origin/$branch" develop)) {
            $problems += "${r}: origin/$branch has commits develop has not, so it cannot fast-forward"
        }
        $plan += [pscustomobject]@{ Repo = $r; Tag = $tag; Branch = $branch; New = $have.Count -eq 0 }
    }
    if ($problems) { Stop-Release ("Nothing pushed:`n  " + ($problems -join "`n  ")) }
    foreach ($p in $plan) {
        Say "[$($p.Repo)] push develop and $($p.Tag), $(if ($p.New) { 'create' } else { 'fast-forward' }) $($p.Branch)"
    }
    if ($DryRun) { Say 'DRY RUN: nothing pushed'; return }
    foreach ($p in $plan) {
        $r = $p.Repo
        # develop:<branch> is a plain push, so origin refuses anything but a fast-forward, and no checkout moves
        if (-not (Ok $r push -q origin develop $p.Tag "develop:refs/heads/$($p.Branch)")) {
            Stop-Release "[$r] push failed; the repositories before it are published, rerun to go on"
        }
        if (Ok $r rev-parse -q --verify "refs/heads/$($p.Branch)") { Git $r fetch -q origin "$($p.Branch):$($p.Branch)" | Out-Null }
        Say "[$r] published $($p.Tag) on $($p.Branch)"
    }
    Say 'PUBLISH DONE'
}

function Do-Next {
    $releases = [ordered]@{}; $tags = @{}
    foreach ($r in $Repos) {
        $tag, $why = Release-Tag $r
        if ($why) { Stop-Release $why }
        $tags[$r] = $tag
        $releases[$r] = Own-Version $r
    }
    # From the commit before the release, where every version is still X-SNAPSHOT: a bare "1.0" is also the XML
    # declaration's version and any number of other things, so it is never what gets matched.
    $mapping = [ordered]@{}
    foreach ($v in $releases.Values) { $mapping["$v-SNAPSHOT"] = Bump $v }
    foreach ($r in $Repos) { Rewrite $r $mapping "$($tags[$r])~1" }
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
        'status'  { Do-Status }
        default   { Get-Help $PSCommandPath -Detailed; exit 1 }
    }
} catch {
    Stop-Release "$_"
}
exit 0
