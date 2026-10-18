"""Cuts a source release of every VexelRay repository, or moves them all to the next snapshot.

    python release.py release   each repo: X-SNAPSHOT -> X, build and test all in order, then commit "Release X"
                                and tag vX (only once every build has passed; a failure commits nothing)
    python release.py next      each repo: X -> X+1-SNAPSHOT (last number bumped), install all, commit
    python release.py status    each repo, a line: name, version, branch, commit, changed files, subject (tab-separated)

Run from PowerShell, with the sibling checkouts beside this folder and clean working trees for the poms. Nothing is
pushed; see DEPLOYING.md for that. Logs land in logs/.

Only the version strings are rewritten: in every tracked pom.xml, and in vexelray-framework's project template
presets. A -SNAPSHOT string that is not some repository's own version stops the run, because the rewrite would
otherwise leave a dependency behind.
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOGS = os.path.join(HERE, "logs")
REPOS = ("vexelray-build intrabuf atchung supirvast dxgi-bridge kronometer tactroller vexelray imagelib-wrapper "
         "vexelray-gui vexelray-framework vexelray-codec vex-suite-common cott-engine cardinal concordance-indexer "
         "vexelray-sim-core vexelray-installer mainframe text-editor-vexel-demo Pix vexplore vexelray-sim-fluid vexelray-sim-rigid "
         "calculator-vexel-demo vexelray-maistro vexelray-inspector").split()
TEMPLATE = "vexelray-framework-template/src/main/resources/dev/vexelray/framework/template/vexel-desktop/template.manifest"
TRAILER = "\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
SNAPSHOT = re.compile(r"\d+(?:\.\d+)*-SNAPSHOT")


def git(repo, *a, check=True):
    return subprocess.run(["git", "-C", os.path.join(ROOT, repo), *a], capture_output=True, text=True,
                          encoding="utf-8", check=check).stdout


def files(repo):
    # the template's files/pom.xml is the version a generated project starts at, not a reference to the stack
    fs = [f for f in git(repo, "ls-files").splitlines() if f.endswith("pom.xml") and "/vexel-desktop/files/" not in f]
    if repo == "vexelray-framework":
        fs.append(TEMPLATE)
    return fs


def own_version(repo, rev="HEAD"):
    body = re.sub(r"<parent>.*?</parent>", "", git(repo, "show", f"{rev}:pom.xml"), flags=re.S)
    return re.search(r"<version>([^<]+)</version>", body).group(1)


def bump(release):
    parts = release.split(".")
    parts[-1] = str(int(parts[-1]) + 1)
    return ".".join(parts) + "-SNAPSHOT"


def rewrite(repo, mapping, rev):
    """Each file as it is at rev, with exactly the strings in mapping replaced, in the file's own line endings."""
    for f in files(repo):
        text = git(repo, "show", f"{rev}:{f}").replace("\r\n", "\n")
        for old, new in mapping.items():
            text = re.sub(r"(?<![\w.])" + re.escape(old) + r"(?![\w.-])", new, text)
        path = os.path.join(ROOT, repo, f)
        with open(path, "rb") as h:
            crlf = b"\r\n" in h.read()
        with open(path, "w", encoding="utf-8", newline="") as h:
            h.write(text.replace("\n", "\r\n") if crlf else text)


def mvn(repo, goals, log):
    with open(os.path.join(LOGS, log), "w", encoding="utf-8") as h:
        return subprocess.run(f"mvn -B {goals}", shell=True, cwd=os.path.join(ROOT, repo),
                              stdout=h, stderr=subprocess.STDOUT).returncode == 0


def say(msg):
    print(msg, flush=True)


def release():
    snapshots = {r: own_version(r) for r in REPOS}
    for r, v in snapshots.items():
        if not v.endswith("-SNAPSHOT"):
            sys.exit(f"{r} is at {v}, not a snapshot")
        if git(r, "tag", "-l", "v" + v[:-len("-SNAPSHOT")]).strip():
            sys.exit(f"{r} already has the tag v{v[:-len('-SNAPSHOT')]}")
    mapping = {v: v[:-len("-SNAPSHOT")] for v in snapshots.values()}
    for r in REPOS:
        for f in files(r):
            stray = set(SNAPSHOT.findall(git(r, "show", f"HEAD:{f}"))) - set(mapping)
            if stray:
                sys.exit(f"{r}/{f} names {', '.join(sorted(stray))}, which is no repository's own version")
    for r in REPOS:
        rewrite(r, mapping, "HEAD")
    say("versions rewritten")
    for r in REPOS:
        say(f"[{r}] clean install {mapping[snapshots[r]]}")
        if not mvn(r, "clean install", f"release-{r}.log"):
            sys.exit(f"[{r}] BUILD FAILED, see logs/release-{r}.log; nothing committed "
                     f"(the rewritten poms are left in place: git checkout -- . in each repo to drop them)")
    for r in REPOS:
        v = mapping[snapshots[r]]
        for f in files(r):
            git(r, "add", f)
        git(r, "commit", "-q", "-m", f"Release {v}{TRAILER}")
        git(r, "tag", "-a", f"v{v}", "-m", f"Release {v}")
        say(f"[{r}] committed and tagged v{v}")
    say("RELEASE DONE")


def next_snapshot():
    releases = {}
    for r in REPOS:
        tag = git(r, "describe", "--tags", "--exact-match", "HEAD", check=False).strip()
        if not tag.startswith("v"):
            sys.exit(f"{r}: HEAD is not a release tag")
        releases[r] = own_version(r)
    # From the commit before the release, where every version is still X-SNAPSHOT: a bare "1.0" is also the XML
    # declaration's version and any number of other things, so it is never what gets matched.
    mapping = {v + "-SNAPSHOT": bump(v) for v in releases.values()}
    for r in REPOS:
        rewrite(r, mapping, "HEAD~1")
    say("versions rewritten")
    for r in REPOS:
        say(f"[{r}] install")
        if not mvn(r, "install -DskipTests", f"next-{r}.log"):
            sys.exit(f"[{r}] BUILD FAILED, see logs/next-{r}.log; nothing committed")
    for r in REPOS:
        for f in files(r):
            git(r, "add", f)
        git(r, "commit", "-q", "-m", f"Next development version{TRAILER}")
        say(f"[{r}] {own_version(r)}")
    say("NEXT DONE")


def status():
    """What a build of every repository would be built from; release-preflight.ps1 reads it."""
    for r in REPOS:
        changed = len(git(r, "status", "--porcelain", "-uno").splitlines())
        line = [r, own_version(r), git(r, "branch", "--show-current").strip(),
                git(r, "rev-parse", "--short", "HEAD").strip(), str(changed), git(r, "log", "-1", "--format=%s").strip()]
        print("\t".join(line), flush=True)


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    {"release": release, "next": next_snapshot, "status": status}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
