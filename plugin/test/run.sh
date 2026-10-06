#!/bin/sh
# Builds the plugin's host test harness with AddressSanitizer and UndefinedBehaviorSanitizer, then runs it.
# Needs a C compiler with sanitizer support (clang or gcc); the VitaSDK isn't involved.
#
# Usage: plugin/test/run.sh [directory]   (with a directory, also saves sample packets there)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/vitapresence-hosttest.XXXXXX")
trap 'rm -rf "$build"' EXIT

${CC:-cc} -std=gnu99 -g -O1 -Wall -Wextra -Wno-unused-parameter -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -I "$here/fakesdk" "$here/harness.c" -o "$build/harness"
# The harness's fake Vita file system lives in $TMPDIR. Putting it inside $build means the EXIT trap
# removes it even when the harness aborts.
TMPDIR="$build" "$build/harness" "$@"
