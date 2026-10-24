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
#   ./build.sh --skip-tests         run no tests at all (NO_TESTS below are skipped always)
#   ./build.sh --check              only check that this VM has everything a build needs
#   ./build.sh --watch              wait for preflight.ps1 on the Windows host to ask, and build what it asks for
#   ./build.sh --install-watcher    run --watch as a service of this desktop session from now on (--remove-watcher)
#
# Logs land in logs/linux/. Stops at the first library that fails; an application that fails is reported, and the
# run fails. Only a build where everything passed writes logs/linux/BUILD.txt, the commit each checkout was built
# from, which preflight.ps1 compares with the checkouts before it lets deploy.ps1 near the Linux binaries.
# GraalVM 25 is found by itself (JAVA_HOME, PATH, ~/.local/opt, /opt, /usr/lib/jvm, SDKMAN) when JAVA_HOME is not one.
set -uo pipefail

LIBS=(vexelray-build intrabuf atchung supirvast dxgi-bridge kronometer tactroller vexelray imagelib-wrapper vexelray-gui
      vexelray-framework ffmpeg-wrapper vexelray-codec vex-suite-common cott-engine cardinal concordance-indexer
      vexelray-sim-core vexelray-installer)
APPS=(mainframe text-editor-vexel-demo Pix vexplore vexelray-sim-fluid vexelray-sim-rigid calculator-vexel-demo
      vexelray-maistro vexelray-inspector)
# Built here without their tests. The preflight only takes a Linux build of the commits Windows has just built and
# tested, so these have passed already; supirvast's are GPU-heavy and fail on the VM's software renderer (llvmpipe).
# Nor are the tests of a *-windows module, which hold the Windows-only code and call Windows itself. Tests of code
# that only Linux builds (the -linux modules) still run.
NO_TESTS=(supirvast)

dist=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$dist")
logs="$dist/logs/linux"
stamp="$logs/BUILD.txt"

only='' build=1 start=1 seconds=8 mode=build tests=1
while [ $# -gt 0 ]; do
    case "$1" in
        --only) only=${2:?--only needs an application checkout}; shift 2 ;;
        --skip-build) build=0; shift ;;
        --no-start) start=0; shift ;;
        --skip-tests) tests=0; shift ;;
        --seconds) seconds=${2:?--seconds needs a number}; shift 2 ;;
        --check) mode=check; shift ;;
        --list) printf '%s\n' "${LIBS[@]}" "${APPS[@]}"; exit 0 ;;   # every checkout it builds, for preflight.sh
        --watch) mode=watch; shift ;;
        --install-watcher) mode=install-watcher; shift ;;
        --remove-watcher) mode=remove-watcher; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "build.sh is the Linux build; on Windows, run build.cmd" >&2; exit 1; }
if [ -n "$only" ]; then
    [[ " ${APPS[*]} " == *" $only "* ]] || { echo "--only $only: not one of: ${APPS[*]}" >&2; exit 2; }
    [ -f "$stamp" ] || { echo "--only rebuilds one application of a whole build, and there is none yet: run ./build.sh" >&2; exit 1; }
fi

# -DskipTests for a checkout whose tests are not run here: it still compiles them, for modules that use its test jars.
skips_tests() { [ $tests = 0 ] || [[ " ${NO_TESTS[*]} " == *" $1 "* ]]; }
excludes="$logs/windows-tests.excludes"
test_args() { if skips_tests "$1"; then echo -DskipTests; else echo "-Dsurefire.excludesFile=$excludes"; fi; }
# Every test class of every *-windows module in the checkouts, as surefire's exclude patterns (dev/x/FooTest.java).
windows_test_excludes() {
    local r
    for r in "${LIBS[@]}" "${APPS[@]}"; do
        git -C "$root/$r" ls-files -- '*-windows/src/test/java/*.java' '*-windows/*/src/test/java/*.java'
    done | sed -n 's|.*-windows/\(.*/\)\{0,1\}src/test/java/||p' | sort -u
}

# mvn in checkout $1, its output to $2. The checkouts are on the shared folder, which cannot hold a Unix domain socket,
# and tests that listen on one beside their discovery file put it under target-linux/: VEXELRAY_HOME, which wins over
# the poms' vexelray.home, moves that to this VM's own disk, fresh for each run.
mvn_in() {
    local r=$1 log=$2 home code
    shift 2
    home=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/vexelray-home.XXXXXX") || return 1
    (cd "$root/$r" && VEXELRAY_HOME=$home mvn -B "$@") > "$log" 2>&1
    code=$?
    rm -rf "$home"
    return $code
}

# An application is built here when its installer.json has a "linux" section.
has_linux() { grep -q '"linux"[[:space:]]*:' "$root/$1/installer.json" 2>/dev/null; }
# The files its linux section ships from target-linux/ (Windows sources are under target/).
linux_sources() { grep -o '"source"[[:space:]]*:[[:space:]]*"target-linux/[^"]*"' "$root/$1/installer.json" | sed 's/.*"\(target-linux\/[^"]*\)"/\1/'; }

mkdir -p "$logs"

# ---- GraalVM ----------------------------------------------------------------------------------------------------
# A JDK is GraalVM 25 when it has native-image and its java is 25 or later.
java_major() { "$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1; }
is_graalvm() { [ -x "$1/bin/native-image" ] && [ -x "$1/bin/java" ] && [ "$(java_major "$1")" -ge 25 ] 2>/dev/null; }
find_graalvm() {
    local c candidates=()
    [ -n "${JAVA_HOME:-}" ] && candidates+=("$JAVA_HOME")
    c=$(command -v native-image 2>/dev/null) && candidates+=("$(dirname "$(dirname "$(readlink -f "$c")")")")
    c=$(command -v java 2>/dev/null) && candidates+=("$(dirname "$(dirname "$(readlink -f "$c")")")")
    # The newest first, in each place GraalVM is unpacked or installed to.
    while IFS= read -r c; do candidates+=("$c"); done < <(
        ls -d "$HOME"/.local/opt/graalvm* /opt/graalvm* /usr/lib/jvm/graalvm* "$HOME"/.sdkman/candidates/java/*graal* \
            2>/dev/null | sort -rV)
    for c in ${candidates[@]+"${candidates[@]}"}; do
        if is_graalvm "$c"; then echo "$c"; return 0; fi
    done
    return 1
}

# ---- check ------------------------------------------------------------------------------------------------------
# What a build needs, checked before it starts rather than found missing half an hour in. Sets JAVA_HOME and PATH to
# the GraalVM it finds, for Maven and everything it runs.
check_setup() {
    local missing=() graal r
    command -v mvn >/dev/null || missing+=("Maven (mvn on PATH)")
    if graal=$(find_graalvm); then
        export JAVA_HOME=$graal PATH="$graal/bin:$PATH"
    else
        missing+=("GraalVM 25 with native-image: unpack it into ~/.local/opt, or set JAVA_HOME to it")
    fi
    command -v gcc >/dev/null || missing+=("gcc, which native-image links with (build-essential)")
    [ -f /usr/include/zlib.h ] || missing+=("the zlib headers native-image links against (zlib1g-dev)")
    command -v python3 >/dev/null || missing+=("python3, which local-linux.sh reads the configs with")
    if [ -z "$only" ]; then
        # The Linux builds of the native libraries, staged once by each wrapper's own -linux module.
        [ -f "$root/imagelib-wrapper/imagelib-wrapper-linux/native/dist/linux-x86_64/libimagelib.so" ] ||
            missing+=("imagelib's Linux library: ./native/build.sh in imagelib-wrapper/imagelib-wrapper-linux")
        [ -f "$root/ffmpeg-wrapper/ffmpeg-wrapper-linux/native/dist/linux-x86_64/libs.txt" ] ||
            missing+=("ffmpeg-wrapper's Linux shim and FFmpeg: ./native/build.sh in ffmpeg-wrapper/ffmpeg-wrapper-linux")
        # The camera's recording encoder, staged beside every app as ffmpeg-record.
        [ -f "$root/ffmpeg-wrapper/ffmpeg-wrapper-record-linux/native/dist/linux-x86_64/libs.txt" ] ||
            missing+=("ffmpeg-wrapper's Linux recording encoder: ./native/build.sh in ffmpeg-wrapper/ffmpeg-wrapper-record-linux")
    fi
    for r in "${LIBS[@]}" "${APPS[@]}"; do
        [ -f "$root/$r/pom.xml" ] || missing+=("the checkout $root/$r")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Install these first (DEPLOYING.md, One-time setup):" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
    echo "GraalVM: $JAVA_HOME ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))"
    if command -v vulkaninfo >/dev/null; then
        local gpu
        gpu=$(vulkaninfo --summary 2>/dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*= //p' | head -1)
        echo "Vulkan: ${gpu:-no device}"
    fi
}

# ---- watch ------------------------------------------------------------------------------------------------------
# preflight.ps1, on the Windows host, asks for a Linux build by writing logs/linux/REQUEST.txt into the shared folder:
#   id <a new id for each request>
#   steps build local      build: ./build.sh; local: then ./local-linux.sh --install, a real install on this VM
# The watcher runs each new request once and says how it went in logs/linux/WATCH.txt, which preflight.ps1 reads:
#   <state> <id>           waiting, running, done or failed, and the request it is about
#   <lines>                what failed
# while it keeps logs/linux/watch.alive fresh, so preflight.ps1 knows there is a watcher to wait for. Its output goes
# to logs/linux/watch.log, a request at a time.
watch() {
    local request="$logs/REQUEST.txt" status="$logs/WATCH.txt" alive="$logs/watch.alive" log="$logs/watch.log"
    local child='' id='' steps='' handled='' poll=5 why
    put_status() { printf '%s\n' "$@" > "$status.tmp" && mv -f "$status.tmp" "$status"; }
    beat() { printf '%s %s\n' "$(uname -n)" "$$" > "$alive"; }
    stop() {
        trap - INT TERM EXIT
        if [ -n "$child" ]; then
            kill -TERM -- "-$child" 2>/dev/null
            put_status "failed $id" "the watcher in the VM was stopped while it ran this request"
        fi
        rm -f "$alive"
        exit 0
    }
    trap stop INT TERM EXIT

    # A request already answered, by this watcher or an earlier one, is not run again.
    handled=$(sed -n '1s/^\(done\|failed\) //p' "$status" 2>/dev/null)
    [ -f "$status" ] || put_status "waiting -"
    local pass=(--seconds "$seconds")
    [ $start = 0 ] && pass+=(--no-start)
    [ $tests = 0 ] && pass+=(--skip-tests)
    # Each request in a session of its own, so stopping the watcher stops Maven and native-image with it.
    local script='for s in $STEPS; do case $s in
            build) "$DIST/build.sh" "$@" || exit 1 ;;
            local) "$DIST/local-linux.sh" --install || exit 1 ;;
            *) echo "unknown step in REQUEST.txt: $s"; exit 1 ;;
        esac; done'
    echo "Watching for preflight.ps1's requests in logs/linux/ (Ctrl+C stops)."
    while :; do
        beat
        id=$(sed -n 's/^id[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$request" 2>/dev/null | tr -d '\r' | head -1)
        if [ -z "$id" ] || [ "$id" = "$handled" ]; then sleep $poll; continue; fi
        steps=$(sed -n 's/^steps[[:space:]]\{1,\}//p' "$request" | tr -d '\r' | head -1)
        echo "$(date '+%H:%M') request $id: ${steps:-build}"
        put_status "running $id" "${steps:-build}"
        STEPS=${steps:-build} DIST=$dist setsid -w bash -c "$script" watch "${pass[@]}" > "$log" 2>&1 &
        child=$!
        while kill -0 "$child" 2>/dev/null; do beat; sleep $poll; done
        if wait "$child"; then
            put_status "done $id"
            echo "$(date '+%H:%M') request $id: done"
        else
            # What preflight.ps1 shows of it: the lines that say what failed.
            mapfile -t why < <(grep -E 'FAILED|failed|exited within|no executable|ERROR:|not installed|Install these|  - ' "$log" | tail -n 8)
            put_status "failed $id" ${why[@]+"${why[@]}"} "see logs/linux/watch.log"
            echo "$(date '+%H:%M') request $id: FAILED, see logs/linux/watch.log" >&2
        fi
        child='' handled=$id
    done
}

# --install-watcher: a systemd user service in the graphical session, which has the desktop the applications are
# started on.
unit_name=vexelray-build-watch.service
unit_file="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit_name"
install_watcher() {
    command -v systemctl >/dev/null || { echo "no systemctl: run ./build.sh --watch in a terminal instead" >&2; exit 1; }
    mkdir -p "$(dirname "$unit_file")"
    cat > "$unit_file" <<EOF
[Unit]
Description=VexelRay Linux build, on request from preflight.ps1 on the Windows host
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=$dist/build.sh --watch --seconds $seconds$([ $start = 0 ] && echo ' --no-start')$([ $tests = 0 ] && echo ' --skip-tests')
Restart=on-failure
RestartSec=30

[Install]
WantedBy=graphical-session.target
EOF
    systemctl --user daemon-reload && systemctl --user enable --now "$unit_name" || exit 1
    echo "The watcher runs now, and with every desktop session: $unit_file"
    echo "Its output: logs/linux/watch.log, and journalctl --user -u $unit_name"
}
remove_watcher() {
    systemctl --user disable --now "$unit_name" 2>/dev/null
    rm -f "$unit_file"
    systemctl --user daemon-reload 2>/dev/null
    echo "The watcher is removed."
}

case $mode in
    check) check_setup; exit ;;
    watch) check_setup || exit 1; watch ;;
    install-watcher) check_setup || exit 1; install_watcher; exit ;;
    remove-watcher) remove_watcher; exit ;;
esac

# Two builds must never run over each other's target-linux/ (a watcher's and one started by hand, say). The lock is
# on this VM's own disk: the shared folder's locks do not hold.
exec 9> "${XDG_RUNTIME_DIR:-/tmp}/vexelray-build.lock"
flock -n 9 || { echo "Another build.sh is running in this VM (the watcher's?); wait for it." >&2; exit 1; }

# ---- build ------------------------------------------------------------------------------------------------------
if [ $build = 1 ]; then
    check_setup || exit 1

    windows_test_excludes > "$excludes"
    if [ -n "$only" ]; then
        libs=() apps=("$only")
    else
        rm -f "$stamp"   # a build that fails part way must not pass for the last good one
        libs=("${LIBS[@]}") apps=("${APPS[@]}")
    fi

    for r in "${libs[@]}"; do
        echo "[$r] clean install$(skips_tests "$r" && echo ', without tests')"
        if ! mvn_in "$r" "$logs/$r.log" clean install "$(test_args "$r")"; then
            echo "[$r] FAILED, see logs/linux/$r.log" >&2
            exit 1
        fi
    done

    failed=0 built=()
    for r in "${apps[@]}"; do
        if ! has_linux "$r"; then echo "[$r] no linux section in installer.json; not built"; continue; fi
        echo "[$r] $(skips_tests "$r" && echo 'build, without tests' || echo tests)"
        if ! mvn_in "$r" "$logs/app-$r.log" clean install "$(test_args "$r")"; then
            echo "[$r] FAILED, see logs/linux/app-$r.log" >&2; failed=1; continue
        fi
        echo "[$r] native image"
        if ! mvn_in "$r" "$logs/native-$r.log" -Pnative-linux clean package -DskipTests; then
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
        printf '# Linux build, %s, on %s, %s\n' "$(date '+%Y-%m-%d %H:%M')" "$(uname -n)" \
            "$([ $tests = 0 ] && echo 'no tests' || echo "tests but ${NO_TESTS[*]}'s and the -windows modules'")"
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
