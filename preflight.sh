#!/usr/bin/env bash
# preflight.ps1 for Linux, run in the Linux VM: everything short of publishing, for the apps that have a "linux"
# section, without the Windows host. It uploads, commits and pushes nothing.
#
#   1. sources    each checkout's branch, and whether it has uncommitted changes (reported, not refused)
#   2. build      ./build.sh: the stack, each app's native image, each app started (logs/linux/)
#   3. versions   each app whose installer.json version is already published for Linux: bump it if it changed
#   4. local      ./local-linux.sh --install: a local preflight in ~/vexelray-local, installed for real on this
#                 account, and each install record checked
#   5. generate   with --release only: ./deploy.sh without --publish, then the diff here and in ../sibarum.github.io
#
#   ./preflight.sh                  all of it
#   ./preflight.sh --skip-build     use the Linux binaries already built (after rebuilding one app with --only)
#   ./preflight.sh --no-local       stop before the local install
#   ./preflight.sh --skip-tests     passed to build.sh, as are --seconds N and --no-start
#   ./preflight.sh --release        the preflight of a Linux release, on the release branch Windows cut: every
#                                   checkout must be on one branch other than develop, with nothing uncommitted
#
# The notices check stays with preflight.ps1 on Windows: it reads the exes. Stops at the first step that fails.
set -uo pipefail

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
build=1 local=1 release=0 pass=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) build=0; shift ;;
        --no-local) local=0; shift ;;
        --release) release=1; shift ;;
        --skip-tests|--no-start) pass+=("$1"); shift ;;
        --seconds) pass+=("$1" "${2:?--seconds needs a number}"); shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "preflight.sh is the Linux one; on Windows, run preflight.ps1" >&2; exit 1; }

step() { printf '\n== %s\n' "$1"; }
fail() { echo "PREFLIGHT FAILED: $1" >&2; exit 1; }

# Each member of installer-suite.json with a linux section: its checkout, id, name, version.
members=$(python3 -I - "$dist/installer-suite.json" <<'EOF'
import json, os, sys
suite = sys.argv[1]
for m in json.load(open(suite))["members"]:
    config = os.path.realpath(os.path.join(os.path.dirname(suite), m["config"]))
    app = json.load(open(config))
    if "linux" in app:
        print("\t".join([os.path.basename(os.path.dirname(config)), app["id"], app["name"], app["version"]]))
EOF
) || fail "could not read installer-suite.json"

step sources
# A release is built from the release branch Windows cut (vexelray-dist stays on develop: it holds the manifests); a
# snapshot preflight from develop.
want=develop
[ $release = 1 ] && want=$(git -C "$root/vexelray" branch --show-current)
[ $release = 1 ] && [ "$want" = develop ] && fail "--release: the checkouts are on develop; .\\release.ps1 switch -Branch release/X on Windows first"
for r in $("$dist/build.sh" --list) vexelray-dist; do
    [ -d "$root/$r/.git" ] || continue
    expect=$want; [ $r = vexelray-dist ] && expect=develop
    branch=$(git -C "$root/$r" branch --show-current)
    changed=$(git -C "$root/$r" status --porcelain -uno | wc -l)
    if [ "$branch" != "$expect" ] || [ "$changed" != 0 ]; then
        echo "  $r: on ${branch:-a detached HEAD}, $changed changed file(s)"
        dirty=1
    fi
done
if [ -n "${dirty:-}" ]; then
    [ $release = 1 ] && fail "a release is built from $want with nothing uncommitted"
    echo "  (a release preflight wants every checkout on develop with nothing uncommitted)"
else
    echo "  every checkout on $want, nothing uncommitted"
fi

if [ $build = 1 ]; then
    step build
    "$dist/build.sh" ${pass[@]+"${pass[@]}"} || fail "the Linux build; see logs/linux/"
else
    step start
    "$dist/build.sh" --skip-build ${pass[@]+"${pass[@]}"} || fail "an app does not start; see logs/linux/"
fi

step versions
# Published means this version's entry already has a Linux build; Windows having published it is no reason to bump.
while IFS=$'\t' read -r _ id name version; do
    linux=$(awk -F'\t' '$1 == "latest" { print $2 }' "$dist/apps/$id/manifest.linux.txt" 2>/dev/null)
    if grep -qx "version	$version" "$dist/apps/$id/manifest.linux.txt" 2>/dev/null; then
        echo "  $name $version is already published for Linux; bump it if it changed"
    else
        echo "  $name $version (Linux has: ${linux:-none})"
    fi
done <<< "$members"

if [ $local = 1 ]; then
    step local
    "$dist/local-linux.sh" --install || fail "the local install; see logs/linux/local-install.log"
fi

if [ $release = 1 ]; then
    step generate
    "$dist/deploy.sh" || fail "deploy.sh"
    step diff
    git -C "$dist" status --short
    [ -d "$root/sibarum.github.io/.git" ] && git -C "$root/sibarum.github.io" status --short
    printf '\nLinux release preflight passed. Look at git diff here (and in ../sibarum.github.io), then ./deploy.sh --publish.\n'
    exit 0
fi

printf '\nLinux preflight passed: %s.\n' "$(cut -f3 <<< "$members" | paste -sd, - | sed 's/,/, /g')"
