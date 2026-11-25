#!/bin/sh
#
# artifacts.sh
# Ain
#
# Created by Ain on 2026/11/20.
#

set -eu
format=$1
output=$2
shift 2
mkdir -p "$output"
objects=.theos/obj
if [ "$format" = automatic ]; then
    app='' library=''
    if [ -d "$objects" ]; then
        app="$(find "$objects" -type d -name '*.app' -prune -print -quit)"
        library="$(find "$objects" \( -name '*.dSYM' -o -name '*.app' \) -prune -o -type f -name '*.dylib' -print -quit)"
    fi
    if [ -n "$app" ] && [ -z "$library" ]; then
        format=ipa
    elif [ -f control ] || [ -f layout/DEBIAN/control ]; then
        format=deb
    elif [ -n "$app" ]; then
        format=ipa
    elif [ -n "$library" ]; then
        format=dylib
    else
        format=archive
    fi
fi
printf '%s\n' "Output format: $format"
# `make package` already builds everything it needs. Compiling here as well
# would run "all" twice in the same obj directory, and the second pass has to
# rename the freshly linked binary over the one the first pass produced. iSH's
# fakefs does not handle that overwrite reliably ("mv: Not a directory"), so
# only the formats that do not package keep an explicit build step.
if [ "$format" != deb ]; then
    /usr/bin/make "$@" all </dev/null
fi
case "$format" in
    deb)
        /usr/bin/make "$@" package IPHONE_PACKAGE_FORMAT=deb PACKAGE_FORMAT=deb </dev/null
        find packages -type f -name '*.deb' -exec cp -f {} "$output/" \;
        ;;
    ipa)
        stage="$(mktemp -d)"
        trap 'rm -rf "$stage"' EXIT
        mkdir "$stage/Payload"
        # Check the merged app first. It sits above the per-arch copies.
        find "$objects" -type d -name '*.app' -prune -printf '%d %p\0' |
          sort -z -n |
          xargs -0 -r sh -c '
            set -eu
            stage=$1
            output=$2
            shift 2
            for entry do
                app=${entry#* }
                [ -f "$app/Info.plist" ] || continue
                name=${app##*/}
                [ ! -f "$output/${name%.app}.ipa" ] || continue
                cp -R "$app" "$stage/Payload/$name"
                (cd "$stage" && zip -qry "$output/${name%.app}.ipa" "Payload/$name")
                rm -rf "$stage/Payload/$name"
            done
          ' sh "$stage" "$output"
        ;;
    dylib)
        find "$objects" \( -name '*.dSYM' -o -name '*.app' \) -prune -o \
            -type f -name '*.dylib' -printf '%d %p\0' |
          sort -z -n |
          xargs -0 -r sh -c '
            set -eu
            output=$1
            shift
            for entry do
                path=${entry#* }
                name=${path##*/}
                [ -f "$output/$name" ] || cp "$path" "$output/$name"
            done
          ' sh "$output"
        ;;
    archive)
        /bin/busybox tar -cf "$output/Build.tar" "$objects"
        ;;
    *) exit 2 ;;
esac
if [ -z "$(find "$output" -type f -print -quit)" ]; then
    echo "No matching $format artifact was generated." >&2
    exit 3
fi
