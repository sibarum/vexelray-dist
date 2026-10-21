#!/usr/bin/env bash
# The Linux half of a release, run in the Linux VM on the checkout it shares with the Windows host.
# Clean-installs the VexelRay stack in dependency order, then tests every application that has a "linux" section in
# its installer.json and builds its native image (-Pnative-linux, into target-linux/), then starts each one.
# build.cmd does the same on Windows; deploy.ps1, on Windows, generates and publishes both.
#
#   ./build.sh                      everything, then start each application
#   ./build.sh --only Pix           rebuild one application (its checkout's name) after a fix, then start it
#   ./build.sh --skip-build         only start the applications already built
#   ./build.sh --seconds 15         how long each application must stay up (8)
#   ./build.sh --no-start           build only; for a VM with no desktop session
#
# Logs land in logs/linux/. Stops at the first library that fails; an application that fails is reported, and the
# run fails. Only a build where everything passed writes logs/linux/BUILD.txt, the commit each checkout was built
# from, which preflight.ps1 compares with the checkouts before it lets deploy.ps1 near the Linux binaries.
set -uo pipefail

LIBS=(vexelray-build intrabuf atchung supirvast dxgi-bridge kronometer tactroller vexelray imagelib-wrapper vexelray-gui
      vexelray-framework ffmpeg-wrapper vexelray-codec vex-suite-common cott-engine cardinal concordance-indexer
      vexelray-sim-core vexelray-installer)
APPS=(mainframe text-editor-vexel-demo Pix vexplore vexelray-sim-fluid vexelray-sim-rigid calculator-vexel-demo
      vexelray-maistro vexelray-inspector)

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
logs="$dist/logs/linux"
stamp="$logs/BUILD.txt"

only= build=1 start=1 seconds=8
while [ $# -gt 0 ]; do
    case "$1" in
        --only) only=${2:?--only needs an application checkout}; shift 2 ;;
        --skip-build) build=0; shift ;;
        --no-start) start=0; shift ;;
        --seconds) seconds=${2:?--seconds needs a number}; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "build.sh is the Linux build; on Windows, run build.cmd" >&2; exit 1; }
if [ -n "$only" ]; then
    [[ " ${APPS[*]} " == *" $only "* ]] || { echo "--only $only: not one of: ${APPS[*]}" >&2; exit 2; }
    [ -f "$stamp" ] || { echo "--only rebuilds one application of a whole build, and there is none yet: run ./build.sh" >&2; exit 1; }
fi

# An application is built here when its installer.json has a "linux" section.
has_linux() { grep -q '"linux"[[:space:]]*:' "$root/$1/installer.json" 2>/dev/null; }
# The files its linux section ships from target-linux/ (Windows sources are under target/).
linux_sources() { grep -o '"source"[[:space:]]*:[[:space:]]*"target-linux/[^"]*"' "$root/$1/installer.json" | sed 's/.*"\(target-linux\/[^"]*\)"/\1/'; }

mkdir -p "$logs"

# ---- build ------------------------------------------------------------------------------------------------------
if [ $build = 1 ]; then
    missing=()
    command -v mvn >/dev/null || missing+=("Maven (mvn on PATH)")
    if command -v java >/dev/null; then
        major=$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)
        [ "${major:-0}" -ge 25 ] || missing+=("GraalVM 25 (java on PATH is ${major:-unknown})")
    else
        missing+=("GraalVM 25 (java on PATH)")
    fi
    if ! command -v native-image >/dev/null && [ ! -x "${JAVA_HOME:-/nonexistent}/bin/native-image" ]; then
        missing+=("native-image: GraalVM 25 as JAVA_HOME, not a plain JDK")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Install these first (DEPLOYING.md, One-time setup):" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi

    if [ -n "$only" ]; then
        libs=() apps=("$only")
    else
        rm -f "$stamp"   # a build that fails part way must not pass for the last good one
        libs=("${LIBS[@]}") apps=("${APPS[@]}")
    fi

    for r in "${libs[@]}"; do
        echo "[$r] clean install"
        if ! (cd "$root/$r" && mvn -B clean install) > "$logs/$r.log" 2>&1; then
            echo "[$r] FAILED, see logs/linux/$r.log" >&2
            exit 1
        fi
    done

    failed=0 built=()
    for r in "${apps[@]}"; do
        if ! has_linux "$r"; then echo "[$r] no linux section in installer.json; not built"; continue; fi
        echo "[$r] tests"
        if ! (cd "$root/$r" && mvn -B clean install) > "$logs/app-$r.log" 2>&1; then
            echo "[$r] FAILED, see logs/linux/app-$r.log" >&2; failed=1; continue
        fi
        echo "[$r] native image"
        if ! (cd "$root/$r" && mvn -B -Pnative-linux clean package -DskipTests) > "$logs/native-$r.log" 2>&1; then
            echo "[$r] NATIVE FAILED, see logs/linux/native-$r.log" >&2; failed=1; continue
        fi
        for s in $(linux_sources "$r"); do
            [ -f "$root/$r/$s" ] || { echo "[$r] the build left no $s, which installer.json ships" >&2; failed=1; }
        done
        built+=("$r")
    done
    [ $failed = 0 ] || { echo "Some applications failed." >&2; exit 1; }

    # What was built, a checkout a line: <checkout> <commit>, and "changed" when it had uncommitted changes.
    # preflight.ps1 reads it. --only keeps the other lines of the whole build it rebuilds one application of.
    built_from() {
        local changed=
        [ -n "$(git -C "$root/$1" status --porcelain -uno)" ] && changed=' changed'
        printf '%s %s%s\n' "$1" "$(git -C "$root/$1" rev-parse HEAD)" "$changed"
    }
    {
        printf '# Linux build, %s, on %s\n' "$(date '+%Y-%m-%d %H:%M')" "$(uname -n)"
        if [ -n "$only" ]; then grep -v -e '^#' -e "^$only " "$stamp"; fi
        for r in ${libs[@]+"${libs[@]}"} ${built[@]+"${built[@]}"}; do built_from "$r"; done
    } > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
    echo "Build done: logs/linux/BUILD.txt"
fi

# ---- start ------------------------------------------------------------------------------------------------------
# The tests run on the JVM, so this is what catches a native image that cannot start: one missing a resource or a
# foreign call it never registered in its reachability metadata.
[ $start = 1 ] || exit 0
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "No desktop session (neither DISPLAY nor WAYLAND_DISPLAY is set), so the applications cannot be started." >&2
    echo "Run this from a terminal on the VM's desktop, or pass --no-start to skip the check." >&2
    exit 1
fi
dead=0
for r in $([ -n "$only" ] && echo "$only" || echo "${APPS[@]}"); do
    has_linux "$r" || continue
    for s in $(linux_sources "$r"); do
        case "$s" in *.tar.gz|*.tgz|*.txt|*.jar) continue ;; esac
        bin="$root/$r/$s" name=$(basename "$s")
        [ -x "$bin" ] || { echo "  $name: no executable $bin" >&2; dead=1; continue; }
        (cd "$(dirname "$bin")" && exec "$bin") > "$logs/start-$name.log" 2>&1 &
        pid=$!
        sleep "$seconds"
        if kill -0 "$pid" 2>/dev/null; then
            echo "  $name up"
            kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        else
            echo "  $name exited within ${seconds}s; see logs/linux/start-$name.log" >&2; dead=1
        fi
    done
done
[ $dead = 0 ] || { echo "An application does not start." >&2; exit 1; }
echo "Every Linux application started."
