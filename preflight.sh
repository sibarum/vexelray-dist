#!/usr/bin/env bash
# preflight.ps1 for Linux, run in the Linux VM: everything short of publishing, for the apps that have a "linux"
# section, without the Windows host. It uploads, commits and pushes nothing.
#
#   1. sources    each checkout's branch, and whether it has uncommitted changes (reported, not refused)
#   2. build      ./build.sh: the stack, each app's native image, each app started (logs/linux/)
#   3. versions   each app whose installer.json version is already published: bump it if it changed
#   4. local      ./local-linux.sh --install: a local preflight in ~/vexelray-local, installed for real on this
#                 account, and each install record checked
#
#   ./preflight.sh                  all of it
#   ./preflight.sh --skip-build     use the Linux binaries already built (after rebuilding one app with --only)
#   ./preflight.sh --no-local       stop before the local install
#   ./preflight.sh --skip-tests     passed to build.sh, as are --seconds N and --no-start
#
# The notices check and generating apps/ stay with preflight.ps1 on Windows: they need the exes. Stops at the first
# step that fails.
set -uo pipefail

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
build=1 local=1 pass=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) build=0; shift ;;
        --no-local) local=0; shift ;;
        --skip-tests|--no-start) pass+=("$1"); shift ;;
        --seconds) pass+=("$1" "${2:?--seconds needs a number}"); shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
for r in $("$dist/build.sh" --list) vexelray-dist; do
    [ -d "$root/$r/.git" ] || continue
    branch=$(git -C "$root/$r" branch --show-current)
    changed=$(git -C "$root/$r" status --porcelain -uno | wc -l)
    if [ "$branch" != develop ] || [ "$changed" != 0 ]; then
        echo "  $r: on ${branch:-a detached HEAD}, $changed changed file(s)"
        dirty=1
    fi
done
[ -n "${dirty:-}" ] && echo "  (a release preflight wants every checkout on develop with nothing uncommitted)" \
                    || echo "  every checkout on develop, nothing uncommitted"

if [ $build = 1 ]; then
    step build
    "$dist/build.sh" ${pass[@]+"${pass[@]}"} || fail "the Linux build; see logs/linux/"
else
    step start
    "$dist/build.sh" --skip-build ${pass[@]+"${pass[@]}"} || fail "an app does not start; see logs/linux/"
fi

step versions
while IFS=$'\t' read -r _ id name version; do
    latest=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("latest") or "")' \
                "$dist/apps/$id/manifest.json" 2>/dev/null)
    if [ "$latest" = "$version" ]; then
        echo "  $name $version is already published; bump it if it changed"
    else
        echo "  $name $version (published: ${latest:-none})"
    fi
done <<< "$members"

if [ $local = 1 ]; then
    step local
    "$dist/local-linux.sh" --install || fail "the local install; see logs/linux/local-install.log"
fi

printf '\nLinux preflight passed: %s.\n' "$(cut -f3 <<< "$members" | paste -sd, - | sed 's/,/, /g')"
