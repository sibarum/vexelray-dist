#!/usr/bin/env bash
# deploy.ps1 -Platform windows for Linux, run in the Linux VM: each app that has a "linux" section gets its Linux
# installer generated into apps/<id>/, from the binaries build.sh left in its target-linux/, and the suite is
# regenerated. What the manifests already have for Windows is kept: each operating system publishes
# its build of a version into the app's release on its own. Pull this repository first, so the manifests merged into
# are the ones the other platforms committed.
#
#   ./deploy.sh              generate, and print what to upload; nothing is published
#   ./deploy.sh --publish    also create each app's release (or add to the one there) and upload its Linux files
#
# --publish uses $GITHUB_TOKEN if set, and otherwise asks for a token (input hidden, never stored): a fine-grained
# token with Contents: read and write on vexelray-dist. It refuses a build that logs/linux/BUILD.txt does not name
# as these checkouts. Commit and push afterwards (develop, then main): the manifests name the uploads. Then tag what
# was built: .\release.ps1 deployed -Branch release/X -Platform linux, on the Windows host.
set -uo pipefail

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
publish=0
while [ $# -gt 0 ]; do
    case "$1" in
        --publish) publish=1; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "deploy.sh is the Linux one; on Windows, run deploy.ps1 -Platform windows" >&2; exit 1; }
cli=$(ls -t "$root"/vexelray-installer/installer-core/target-linux/installer-core-*-cli.jar 2>/dev/null | head -n 1)
[ -n "$cli" ] || { echo "no installer CLI: mvn -pl installer-core package in vexelray-installer, on Linux" >&2; exit 1; }

# The Linux binaries are fit to publish only while every checkout build.sh built is still at the commit it built.
stamp="$dist/logs/linux/BUILD.txt"
[ -f "$stamp" ] || { echo "no Linux build: logs/linux/BUILD.txt is missing (./build.sh)" >&2; exit 1; }
stale=0
while read -r repo commit; do
    case "$repo" in ''|\#*) continue ;; esac
    head=$(git -C "$root/$repo" rev-parse HEAD 2>/dev/null)
    if [ "$head" != "$commit" ]; then
        echo "$repo: the Linux build is of ${commit:0:9}, the checkout is at ${head:0:9}" >&2
        stale=1
    fi
done < "$stamp"
[ $stale = 0 ] || { echo "Build again (./build.sh): the binaries are not of these checkouts" >&2; exit 1; }

# Each member of installer-suite.json that has a linux section: its config's full path and id.
members=$(python3 -I - "$dist/installer-suite.json" <<'EOF'
import json, os, sys
suite = sys.argv[1]
for m in json.load(open(suite))["members"]:
    config = os.path.realpath(os.path.join(os.path.dirname(suite), m["config"]))
    if "linux" in json.load(open(config)):
        print("\t".join([config, json.load(open(config))["id"]]))
EOF
) || { echo "could not read installer-suite.json" >&2; exit 1; }

asked=0
if [ $publish = 1 ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    # Asked for, not stored: it lives in this process's environment only for the run.
    read -rsp 'GitHub token (Contents: read and write on vexelray-dist): ' GITHUB_TOKEN < /dev/tty; echo
    [ -n "$GITHUB_TOKEN" ] || { echo "No token given." >&2; exit 1; }
    export GITHUB_TOKEN
    asked=1
fi
trap '[ $asked = 1 ] && unset GITHUB_TOKEN' EXIT

while IFS=$'\t' read -r config id; do
    args=(--config "$config" --platform linux --out "$dist/apps/$id" --assets "$dist/assets/$id")
    [ $publish = 1 ] && args+=(--publish)
    (cd "$(dirname "$config")" && java -jar "$cli" "${args[@]}") || { echo "Generating $id failed" >&2; exit 1; }
done <<< "$members"

echo "== suite"
java -jar "$cli" --suite "$dist/installer-suite.json" --out "$dist" || { echo "Generating the suite failed" >&2; exit 1; }
