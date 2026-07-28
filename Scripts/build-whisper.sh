#!/usr/bin/env bash
#
# build-whisper.sh — compile the pinned whisper.cpp submodule into static libraries
# that SwiftPM can link into PushToType.
#
# Output: .build/whisper/{lib,include}
#
# Why static: the app must run offline with zero install steps and no dylib search
# paths inside the bundle. Everything ends up inside the executable.
#
# Why these flags:
#   GGML_METAL=OFF   — target hardware is an Intel Mac (AMD Radeon). ggml's Metal
#                      backend is tuned for Apple Silicon unified memory; on this GPU
#                      the Accelerate CPU path is faster and far more predictable.
#   GGML_BLAS=ON     — Accelerate provides the sgemm used by the encoder.
#   BUILD_SHARED_LIBS=OFF, WHISPER_BUILD_{TESTS,EXAMPLES}=OFF — we only need the lib.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Vendor/whisper.cpp"
BUILD="$ROOT/.build/whisper-build"
OUT="$ROOT/.build/whisper"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
    echo "error: Vendor/whisper.cpp is empty. Run: git submodule update --init --recursive" >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake not found. Install it with: brew install cmake" >&2
    exit 1
fi

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "==> Configuring whisper.cpp ($(cd "$SRC" && git describe --tags --always))"
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=OFF \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_ACCELERATE=ON \
    -DGGML_OPENMP=OFF \
    >/dev/null

echo "==> Building (this takes a few minutes on first run)"
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null

echo "==> Collecting artifacts into .build/whisper"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"

# whisper + every ggml backend library the build produced.
find "$BUILD" -name 'libwhisper*.a' -o -name 'libggml*.a' | while read -r lib; do
    cp "$lib" "$OUT/lib/"
done

cp "$SRC/include/whisper.h" "$OUT/include/"
cp "$SRC/ggml/include/"*.h "$OUT/include/"

echo "==> Done:"
ls -1 "$OUT/lib"
