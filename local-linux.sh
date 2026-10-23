#!/usr/bin/env bash
# deploy.ps1 -Local for Linux, run in the Linux VM: every app that has a "linux" section gets its installer and its
# release, and the suite gets a preflight pinned to those versions, all in one folder of this VM and pointing at it
# through file:// instead of GitHub. Nothing is published, and nothing outside that folder is written.
#
#   ./local-linux.sh                    into ~/vexelray-local (replacing what is there)
#   ./local-linux.sh --out <dir>        somewhere else
#   ./local-linux.sh --install          then install every app from it, and check each one's install record
#
# Then install from it, for real, on this account: sh ~/vexelray-local/install.sh (INSTALL_ONLY=pix,calculator for
# some), or let --install do it. Each install's updater points at that folder until a published install replaces it.
# It needs the Linux binaries in each app's target-linux/ (build.sh) and the installer CLI in vexelray-installer's
# target-linux/. --install writes logs/linux/LOCAL.txt once every app has installed: the build it installed, as
# logs/linux/BUILD.txt names it, which preflight.ps1 -LinuxLocal looks for.
set -uo pipefail

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
out="$HOME/vexelray-local"
install=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=${2:?--out needs a folder}; shift 2 ;;
        --install) install=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"| sed 's/^# \{0,1\}//'; exit 0 ;;
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
# Replaced only when it is this script's own (.local-linux, written first, so a run that failed half way still owns
# its folder), or empty: --out names a folder, and a typo must not empty one.
if [ -n "$(ls -A "$out")" ] && [ ! -f "$out/.local-linux" ] && [ ! -f "$out/preflight-suite.json" ]; then
    echo "$out is not empty and not an earlier local-linux.sh folder; give an empty or new one" >&2
    exit 2
fi
rm -rf "${out:?}"/* && mkdir -p "$out/apps" "$out/assets" "$out/releases" && echo "written by $dist/local-linux.sh" > "$out/.local-linux"

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
        if ! (cd "$(dirname "$config")" && java -jar "$cli" --config "$config" --version "$version" --platform linux --out "$out/apps/$id" \
                --assets "$out/assets/$id" --base-url "$base/apps/$id" --asset-base-url "$base/releases") \
                > "$out/apps/$id.log" 2>&1; then
            echo "Generating $id failed; see $out/apps/$id.log" >&2
            exit 1
        fi
        # Where --asset-base-url says each file is, <base>/<tag>/<file>, as on GitHub. --platform linux: the Windows
        # binaries are neither needed nor generated, so there is only what the Linux scripts fetch.
        mkdir -p "$out/releases/$tag"
        for f in "$out/assets/$id/$version"/*; do ln -s "$f" "$out/releases/$tag/$(basename "$f")"; done
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
if [ $install = 0 ]; then
    echo
    echo "To install from it: sh $out/install.sh"
    exit 0
fi

# ---- install ----------------------------------------------------------------------------------------------------
# A real install on this account, as release-preflight.ps1's local step is on Windows. The suite installs every
# member it pins, so each app with a linux section must then have a record of exactly its snapshot.
echo "== install"
logs="$dist/logs/linux"
mkdir -p "$logs"
rm -f "$logs/LOCAL.txt"
INSTALL_EVERYTHING=1 sh "$out/install.sh" < /dev/null 2>&1 | tee "$logs/local-install.log"
code=${PIPESTATUS[0]}
registry=${INSTALL_REGISTRY_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vexelray-installer/installs}
bad=0
while IFS=$'\t' read -r _ id version _ linux _; do
    [ "$linux" = linux ] || continue
    got=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("version", ""))' \
            "$registry/$id.json" 2>/dev/null)
    if [ "$got" = "$version" ]; then echo "  $id $got installed"
    else echo "  $id: ${got:-not} installed, not $version" >&2; bad=1; fi
done <<< "$members"
if [ "$code" != 0 ] || [ $bad = 1 ]; then
    echo "The local install failed; see logs/linux/local-install.log" >&2
    exit 1
fi
{
    printf '# Local install from %s, %s\n' "$out" "$(date '+%Y-%m-%d %H:%M')"
    grep -v '^#' "$logs/BUILD.txt" 2>/dev/null
} > "$logs/LOCAL.txt"
echo "Every Linux app installed from $out."
