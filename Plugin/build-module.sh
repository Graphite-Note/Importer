#!/bin/sh
# File: build-module.sh
# ---------------------
# Layer: Build
# Description: Builds the Notion importer plugin's WebAssembly module with the Swift SDK for WebAssembly, with
#              Embedded Swift (the plugin's) or the whole standard library, and strips it.
#
# Authors: Bahey Shalash
# Version: 0.1
# Date: 27/11/2026
#
# Usage: Plugin/build-module.sh [embedded | standard-library] [output .wasm]
# The swift.org toolchain and the Swift SDK for WebAssembly of the same version must be installed: SWIFT names the
# toolchain's swift (default: swift), SWIFT_SDKS_PATH a folder of Swift SDKs when they are not in the default place,
# SCRATCH_PATH the build folder (default: Plugin/.build). Xcode's toolchain cannot build for WebAssembly.

set -eu

flavor="${1:-embedded}"
plugin_folder="$(cd "$(dirname "$0")" && pwd)"
output="${2:-$plugin_folder/build/importer.wasm}"
swift="${SWIFT:-swift}"
scratch="${SCRATCH_PATH:-$plugin_folder/.build}"
sdk_version="6.4.2-RELEASE"

sdk_options=""
if [ -n "${SWIFT_SDKS_PATH:-}" ]; then sdk_options="--swift-sdks-path $SWIFT_SDKS_PATH"; fi

case "$flavor" in
embedded)
    sdk="swift-${sdk_version}_wasm-embedded"
    # Embedded Swift links the Unicode tables and the cooperative executor only when asked.
    # shellcheck disable=SC2086
    resources="$("$swift" sdk configure --show-configuration $sdk_options "$sdk" wasm32-unknown-wasip1 \
        | sed -n 's/^swiftResourcesPath: //p' | head -1)"
    library_folder="$resources/embedded/wasm32-unknown-wasip1"
    extra="-Xlinker -L$library_folder -Xlinker -lswiftUnicodeDataTables -Xlinker -lswift_ConcurrencyDefaultExecutor"
    ;;
standard-library)
    sdk="swift-${sdk_version}_wasm"
    extra=""
    ;;
*)
    echo "Usage: $0 [embedded | standard-library] [output .wasm]" >&2
    exit 2
    ;;
esac

# shellcheck disable=SC2086
"$swift" build --package-path "$plugin_folder" --scratch-path "$scratch/$flavor" -c release $sdk_options --swift-sdk "$sdk" \
    --product ImporterWasm -Xswiftc -Osize -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor $extra

bin_folder="$("$swift" build --package-path "$plugin_folder" --scratch-path "$scratch/$flavor" -c release $sdk_options \
    --swift-sdk "$sdk" --show-bin-path)"
mkdir -p "$(dirname "$output")"
# The toolchain's llvm-objcopy, next to its swift, strips the module's names and debug sections.
objcopy="${LLVM_OBJCOPY:-$(dirname "$(command -v "$swift")")/llvm-objcopy}"
if [ -x "$objcopy" ]; then
    "$objcopy" --strip-all "$bin_folder/ImporterWasm.wasm" "$output"
else
    echo "llvm-objcopy not found: the module is left unstripped." >&2
    cp "$bin_folder/ImporterWasm.wasm" "$output"
fi
echo "Built $output ($(wc -c < "$output" | tr -d ' ') bytes)"
