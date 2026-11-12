#!/bin/sh
# Builds the examples (or the ones named) with Jacket's jaic.
#   ./build.sh               build everything under examples/
#   ./build.sh examples/todos
set -e
root="$(cd "$(dirname "$0")" && pwd)"
if [ $# -eq 0 ]; then set -- "$root"/examples/*/; fi
for dir in "$@"; do
    echo "== $dir"
    (cd "$dir" && jaic build.jai -import_dir "$root/modules" -no_color)
done
