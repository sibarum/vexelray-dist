#!/usr/bin/env bash
# deploy.ps1 -Local for Linux, run in the Linux VM: every app that has a "linux" section gets its installer and its
# release, and the suite gets a preflight pinned to those versions, all in one folder of this VM and pointing at it
# through file:// instead of GitHub. Nothing is published, and nothing outside that folder is written.
#
#   ./local-linux.sh                    into ~/vexelray-local (replacing what is there)
#   ./local-linux.sh --out <dir>        somewhere else
#
# Then install from it, for real, on this account: sh ~/vexelray-local/install.sh (INSTALL_ONLY=pix,calculator for
# some). Each install's updater points at that folder until a published install replaces it. It needs the Linux
# binaries in each app's target-linux/ (build.sh) and the installer CLI in vexelray-installer's target-linux/.
set -uo pipefail

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
out="$HOME/vexelray-local"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=${2:?--out needs a folder}; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "local-linux.sh is the Linux one; on Windows, run deploy.ps1 -Local" >&2; exit 1; }
cli=$(ls -t "$root"/vexelray-installer/installer-core/target-linux/installer-core-*-cli.jar 2>/dev/null | head -n 1)
[ -n "$cli" ] || { echo "no installer CLI: mvn -pl installer-core package in vexelray-installer, on Linux" >&2; exit 1; }
out=$(realpath -m "$out")
case $out in "$root"|"$root"/*) echo "--out $out is inside the checkouts; give a folder of this VM's own" >&2; exit 2 ;; esac
mkdir -p "$out"
base="file://$out"
# Replaced only when it is this script's own, or empty: --out names a folder, and a typo must not empty one.
if [ -n "$(ls -A "$out")" ] && [ ! -f "$out/preflight-suite.json" ]; then
    echo "$out is not empty and not an earlier local-linux.sh folder; give an empty or new one" >&2
    exit 2
fi
rm -rf "${out:?}"/* && mkdir -p "$out/apps" "$out/assets" "$out/releases"

# Each member of installer-suite.json, in its order: its config's full path, id, version, release tag, whether it has
# a linux section, and its page.
members=$(python3 -I - "$dist/installer-suite.json" <<'EOF'
import json, os, sys
suite = sys.argv[1]
for m in json.load(open(suite))["members"]:
    config = os.path.realpath(os.path.join(os.path.dirname(suite), m["config"]))
    app = json.load(open(config))
    tag = app.get("tagFormat", "v{version}").replace("{version}", app["version"])
    print("\t".join([config, app["id"], app["version"], tag, "linux" if "linux" in app else "-", m.get("page", "")]))
EOF
) || { echo "could not read installer-suite.json" >&2; exit 1; }

pinned=()
while IFS=$'\t' read -r config id version tag linux page; do
    entry="\"config\": \"$config\", \"version\": \"$version\""
    [ -n "$page" ] && entry="$entry, \"page\": \"$page\""
    if [ "$linux" = linux ]; then
        echo "== $id $version"
        if ! (cd "$(dirname "$config")" && java -jar "$cli" --config "$config" --version "$version" --out "$out/apps/$id" \
                --assets "$out/assets/$id" --base-url "$base/apps/$id" --asset-base-url "$base/releases") \
                > "$out/apps/$id.log" 2>&1; then
            echo "Generating $id failed; see $out/apps/$id.log" >&2
            exit 1
        fi
        # Where --asset-base-url says each file is, <base>/<tag>/<file>, as on GitHub. Only what the Linux scripts
        # fetch: the exe and the Windows archives are deleted rather than kept beside them.
        mkdir -p "$out/releases/$tag"
        for f in "$out/assets/$id/$version"/*; do
            case $f in
                *.exe|*-windows-*.zip) rm -f "$f" ;;
                *) ln -s "$f" "$out/releases/$tag/$(basename "$f")" ;;
            esac
        done
        entry="$entry, \"manifestUrl\": \"$base/apps/$id/manifest.json\""
    else
        echo "== $id $version (no linux section: the suite says so if it is asked for)"
    fi
    pinned+=("{ $entry }")
done <<< "$members"

joined=$(printf '%s,\n    ' "${pinned[@]}"); joined=${joined%,*}
cat > "$out/preflight-suite.json" <<EOF
{ "id": "vexelray-preflight", "name": "VexelRay preflight",
  "description": "Snapshot builds of every VexelRay application, built together from the same sources, to try before they are released.",
  "repo": "sibarum/vexelray-dist", "branch": "main", "repoPath": "preflight",
  "members": [
    $joined
  ] }
EOF
python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$out/preflight-suite.json" \
    || { echo "the pinned suite is not valid JSON: $out/preflight-suite.json" >&2; exit 1; }
echo "== preflight suite"
java -jar "$cli" --suite "$out/preflight-suite.json" --out "$out" --base-url "$base" > "$out/suite.log" 2>&1 \
    || { echo "Generating the suite failed; see $out/suite.log" >&2; exit 1; }
echo
echo "To install from it: sh $out/install.sh"
