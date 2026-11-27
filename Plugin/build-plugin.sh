#!/bin/sh
# File: build-plugin.sh
# ---------------------
# Layer: Build
# Description: Builds the Notion importer plugin as a release carries it: main.js with the WebAssembly module inside
#              it (built with Embedded Swift by build-module.sh), manifest.json and styles.css.
#
# Authors: Bahey Shalash
# Version: 0.1
# Date: 27/11/2026
#
# Usage: Plugin/build-plugin.sh [output folder]. SWIFT, SWIFT_SDKS_PATH and SCRATCH_PATH as for build-module.sh.

set -eu

plugin_folder="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$plugin_folder/build}"
mkdir -p "$output"
"$plugin_folder/build-module.sh" embedded "$output/importer.wasm"
node "$plugin_folder/assemble-main.mjs" "$output/importer.wasm" "$output/main.js"
cp "$plugin_folder/../manifest.json" "$output/manifest.json"
cp "$plugin_folder/styles.css" "$output/styles.css"
echo "Built the plugin in $output: main.js $(wc -c < "$output/main.js" | tr -d ' ') bytes"
