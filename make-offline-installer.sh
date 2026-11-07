#!/usr/bin/env bash
# Package the generated VexelRay preflight (~/vexelray-local) as one self-extracting, offline Linux installer.
#
# Run it after the preflight has been regenerated from fresh native images. The result is a single .run file
# that carries the suite install.sh, every application's installer and manifest, and every release file the
# manifests point at. On the target machine (no network needed, no curl needed):
#
#   sh vexelray-preflight-offline.run                       # or: chmod +x it, then ./vexelray-preflight-offline.run
#   sh vexelray-preflight-offline.run --install-everything  # arguments and INSTALL_* variables go to install.sh
#
# The generated scripts are not changed here. At install time the .run extracts itself to a temporary folder,
# points the baked-in file:// URLs at that folder, and puts a curl/wget stand-in first on PATH that serves
# file:// URLs and refuses everything else, so nothing can reach the network.
#
#   ./make-offline-installer.sh                          # from ~/vexelray-local into the current folder
#   ./make-offline-installer.sh -o ~/out [SOURCE-DIR]
set -euo pipefail

out=$PWD
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=${2:?-o needs a folder}; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
        *) break ;;
    esac
done
SRC=$(cd "${1:-$HOME/vexelray-local}" && pwd -P)
PREFIX="file://$SRC"

[ -f "$SRC/install.sh" ] || { echo "No suite install.sh in $SRC. Generate the preflight first." >&2; exit 1; }
grep -qF "$PREFIX/" "$SRC/install.sh" || { echo "$SRC/install.sh does not point at $PREFIX; was it generated for another folder?" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Everything the payload needs: the suite script, and for each app with a Linux manifest its tools and every
# file:// URL that manifest names. Each named file must exist and match the SHA-256 the manifest gives it,
# which catches release files rebuilt after the preflight was generated.
echo install.sh > "$work/list"
bad=0
for mf in "$SRC"/apps/*/manifest.linux.txt; do
    app=$(basename "$(dirname "$mf")")
    awk -F'\t' -v p="$PREFIX/" '
        { sha = ""; url = ""
          for (i = 2; i <= NF; i++) {
              if ($i ~ /^[0-9a-f]{64}$/) sha = $i
              else if (index($i, p) == 1) url = substr($i, length(p) + 1)
          }
          if (url != "") print sha "\t" url }' "$mf" | sort -u > "$work/refs"
    while IFS=$'\t' read -r sha rel; do
        if [ ! -f "$SRC/$rel" ]; then
            echo "  $app: missing $rel" >&2; bad=1; continue
        fi
        if [ -n "$sha" ] && [ "$(sha256sum < "$SRC/$rel" | cut -d' ' -f1)" != "$sha" ]; then
            echo "  $app: $rel does not match its manifest SHA-256 (regenerate the preflight)" >&2; bad=1; continue
        fi
        echo "$rel" >> "$work/list"
    done < "$work/refs"
    echo "apps/$app/manifest.linux.txt" >> "$work/list"
    echo "  $app: $(wc -l < "$work/refs") files"
done
[ $bad = 0 ] || { echo "Not packaged: the preflight in $SRC is incomplete or stale." >&2; exit 1; }
sort -u -o "$work/list" "$work/list"

echo "Compressing $(cd "$SRC" && du -chL $(cat "$work/list") | tail -n 1 | cut -f1) ..."
tar -C "$SRC" -chf - -T "$work/list" | gzip -6 > "$work/payload.tgz"
payload_sha=$(sha256sum < "$work/payload.tgz" | cut -d' ' -f1)

cat > "$work/header" <<'STUB'
#!/bin/sh
# VexelRay preflight - offline installer for Linux, made by make-offline-installer.sh.
#
#   sh ./THIS-FILE [--install-everything]      (or chmod +x it and run it)
#
# Installs for the current user only, without sudo and without the network. Arguments and INSTALL_* variables
# (INSTALL_ONLY=a,b, INSTALL_NO_SHORTCUTS=1, ...) are passed on to the suite installer. Set TMPDIR to extract
# somewhere other than /tmp. Run this file again to reinstall; the installed update.sh scripts need the online
# preflight, so they will not work from here.
set -u
VX_PREFIX='@PREFIX@'
VX_SHA='@SHA@'
VX_LINE=@LINE@

vx_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || vx_die "This installer is for Linux."
for c in tar gzip sha256sum awk sed mktemp; do
    command -v $c >/dev/null 2>&1 || vx_die "$c is not installed."
done
self=$0
[ -f "$self" ] || vx_die "Run this as a file (sh ./$(basename "$0")), not through a pipe."

vx_tmp=$(mktemp -d "${TMPDIR:-/tmp}/vexelray-offline.XXXXXX") || vx_die "Cannot create a temporary folder."
trap 'rm -rf -- "$vx_tmp"' EXIT
trap 'exit 1' INT TERM HUP
pkg="$vx_tmp/pkg"
mkdir -p "$pkg" "$vx_tmp/bin"

printf 'Checking the package...\n'
[ "$(tail -n +$VX_LINE "$self" | sha256sum | cut -d' ' -f1)" = "$VX_SHA" ] || vx_die "This file is damaged or incomplete (SHA-256 mismatch). Copy it again."
printf 'Extracting...\n'
tail -n +$VX_LINE "$self" | tar -xzf - -C "$pkg" || vx_die "Could not extract to $vx_tmp (out of space? set TMPDIR to another folder)."

# Point the baked-in URLs at the extracted copy, then give the tools their new SHA-256 in each manifest.
new=$(printf '%s' "file://$pkg" | sed 's/[|&\\]/\\&/g')
old=$(printf '%s' "$VX_PREFIX" | sed 's/[.[*^$|\\]/\\&/g')
for f in "$pkg/install.sh" "$pkg"/apps/*/*.sh "$pkg"/apps/*/manifest.linux.txt; do
    [ -f "$f" ] || continue
    sed "s|$old|$new|g" "$f" > "$f.new" && mv -- "$f.new" "$f" || vx_die "Could not prepare $f."
done
for d in "$pkg"/apps/*/; do
    shas=
    for t in install.sh update.sh uninstall.sh; do
        [ -f "$d$t" ] && shas="$shas $t=$(sha256sum < "$d$t" | cut -d' ' -f1)"
    done
    awk -F'\t' -v OFS='\t' -v shas="$shas" '
        BEGIN { n = split(shas, a, " "); for (i = 1; i <= n; i++) { split(a[i], kv, "="); s[kv[1]] = kv[2] } }
        $1 == "tool" && ($2 in s) { $3 = s[$2] } { print }' "${d}manifest.linux.txt" > "$vx_tmp/mf" &&
        mv -- "$vx_tmp/mf" "${d}manifest.linux.txt" || vx_die "Could not prepare ${d}manifest.linux.txt."
done

# curl and wget stand-ins: copy file:// URLs, refuse anything else. They are first on PATH, so the
# installers use them whether or not the real ones are installed.
cat > "$vx_tmp/bin/curl" <<'EOF'
#!/bin/sh
out= url=
while [ $# -gt 0 ]; do
    case $1 in
        -o|-O) out=$2; shift ;;
        --retry|--connect-timeout|-C) shift ;;
        --*=*|-*) ;;
        *) url=$1 ;;
    esac
    shift
done
case $url in
    file://*) p=${url#file://} ;;
    *) printf 'offline installer: refusing to fetch %s\n' "$url" >&2; exit 7 ;;
esac
[ -f "$p" ] || { printf 'offline installer: not in the package: %s\n' "$p" >&2; exit 37; }
if [ -n "$out" ] && [ "$out" != - ]; then cp -- "$p" "$out"; else cat -- "$p"; fi
EOF
cp "$vx_tmp/bin/curl" "$vx_tmp/bin/wget"
chmod +x "$vx_tmp/bin/curl" "$vx_tmp/bin/wget"

PATH="$vx_tmp/bin:$PATH" sh "$pkg/install.sh" "$@" < /dev/null
exit $?
STUB

# The payload starts on the line after the header.
line=$(( $(wc -l < "$work/header") + 1 ))
sed -i -e "s|@PREFIX@|$PREFIX|" -e "s|@SHA@|$payload_sha|" -e "s|@LINE@|$line|" "$work/header"

mkdir -p "$out"
dest="$out/vexelray-preflight-offline-$(date +%Y%m%d-%H%M).run"
cat "$work/header" "$work/payload.tgz" > "$dest"
chmod +x "$dest"
echo
echo "Built $dest ($(du -h "$dest" | cut -f1))"
echo "  On the target: sh $(basename "$dest")"
