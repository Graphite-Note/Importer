#!/bin/bash
# File: compare-with-linked.sh
# ----------------------------
# Layer: Tests
# Description: Imports each export twice, with the `importer` command (the package as apps link it, writing a folder
#              with Foundation) and with the plugin's engine and WebAssembly module in Node, and checks that both
#              vaults hold the same files with the same bytes (compare-vaults.cjs). An export refused by one must be
#              refused by the other, with the same reason.
#
# Authors: Bahey Shalash
# Version: 0.1
# Date: 27/11/2026
#
# Usage: compare-with-linked.sh <importer command> <importer.wasm> <work folder> <export.zip>…

set -eu

command_path="$1"
module="$2"
work="$3"
shift 3
tests_folder="$(cd "$(dirname "$0")" && pwd)"
date="$(date +%Y-%m-%d)"
year="$(date +%Y)"
status=0

for export in "$@"; do
    name="$(basename "$export")"
    linked="$work/linked-$name"
    plugin="$work/plugin-$name"
    rm -rf "$linked" "$plugin"
    mkdir -p "$linked" "$plugin"
    linked_status=0
    plugin_status=0
    "$command_path" notion "$export" --vault "$linked" --into Notion > "$work/linked-$name.txt" || linked_status=$?
    summary="$(node "$tests_folder/import-with-plugin.cjs" "$module" "$plugin" Notion "$date" "$year" "$export" 2>&1)" \
        || plugin_status=$?
    if [ "$linked_status" != 0 ] || [ "$plugin_status" != 0 ]; then
        # An export refused by one must be refused by the other, with the same reason.
        if [ "$linked_status" != 0 ] && [ "$plugin_status" != 0 ] && [ "$(cat "$work/linked-$name.txt")" = "$summary" ]; then
            echo "$name: refused by both: $summary"
        else
            echo "$name: linked exit $linked_status, plugin exit $plugin_status: $(cat "$work/linked-$name.txt") / $summary"
            status=1
        fi
        continue
    fi
    if ! count="$(node "$tests_folder/compare-vaults.cjs" "$linked" "$plugin")"; then
        echo "$name: the vaults differ:"
        echo "$count"
        status=1
        continue
    fi
    echo "$name: the same $count files. Plugin: $summary"
done
exit $status
