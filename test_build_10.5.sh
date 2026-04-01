#!/usr/bin/env bash

set -euo pipefail

# Space Cadet Pinball legacy macOS 10.5 build/port test driver.
# Assumptions:
# - Toolchain and dependencies are installed via MacPorts + Legacy Support.
# - GCC 14 is used as the compiler frontend.
# - SDL2 renderer is forced to OpenGL (OpenGL2-era backend on legacy systems).
#
# Usage:
#   ./test_build_10.5.sh
#   ./test_build_10.5.sh --run
#
# Environment overrides:
#   MACPORTS_PREFIX      (default: /opt/local)
#   TARGET_ARCH          (default: ppc)
#   TARGET_SYSROOT       (optional; SDK sysroot path)
#   TARGET_DEPLOYMENT    (default: 10.5)
#   BUILD_DIR            (default: build-10.5)
#   INSTALL_PREFIX       (default: <repo>/out-10.5)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
TARGET_ARCH="${TARGET_ARCH:-ppc}"
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-10.5}"
TARGET_SYSROOT="${TARGET_SYSROOT:-}"
BUILD_DIR="${BUILD_DIR:-build-10.5}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$SCRIPT_DIR/out-10.5}"
DO_RUN=0

for arg in "$@"; do
    case "$arg" in
        --run)
            DO_RUN=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

echo "== SpaceCadetPinball macOS 10.5 OpenGL2 port test =="
echo "Repo:               $SCRIPT_DIR"
echo "MacPorts prefix:    $MACPORTS_PREFIX"
echo "Target arch:        $TARGET_ARCH"
echo "Deployment target:  $TARGET_DEPLOYMENT"
echo "Build directory:    $BUILD_DIR"
echo "Install prefix:     $INSTALL_PREFIX"

require_cmd cmake
require_cmd pkg-config
require_cmd gcc-mp-14
require_cmd g++-mp-14

if [[ ! -d "$MACPORTS_PREFIX/include/SDL2" ]]; then
    echo "SDL2 headers not found under $MACPORTS_PREFIX/include/SDL2" >&2
    echo "Install with MacPorts first (example):" >&2
    echo "  sudo port install libsdl2 libsdl2_mixer libsdl2_image libsdl2_ttf" >&2
    exit 1
fi

if [[ ! -f "$MACPORTS_PREFIX/lib/pkgconfig/sdl2.pc" ]]; then
    echo "sdl2.pc not found under $MACPORTS_PREFIX/lib/pkgconfig" >&2
    echo "Ensure MacPorts pkgconfig files are installed." >&2
    exit 1
fi

export PATH="$MACPORTS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$MACPORTS_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CC="${CC:-gcc-mp-14}"
export CXX="${CXX:-g++-mp-14}"

# Runtime renderer preference: request OpenGL backend explicitly.
export SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-opengl}"
export SDL_RENDER_VSYNC="${SDL_RENDER_VSYNC:-1}"

COMMON_CFLAGS="-O2 -pipe -arch $TARGET_ARCH -mmacosx-version-min=$TARGET_DEPLOYMENT"
COMMON_CXXFLAGS="$COMMON_CFLAGS"
COMMON_LDFLAGS="-arch $TARGET_ARCH -mmacosx-version-min=$TARGET_DEPLOYMENT"

if [[ -n "$TARGET_SYSROOT" ]]; then
    COMMON_CFLAGS="$COMMON_CFLAGS -isysroot $TARGET_SYSROOT"
    COMMON_CXXFLAGS="$COMMON_CXXFLAGS -isysroot $TARGET_SYSROOT"
    COMMON_LDFLAGS="$COMMON_LDFLAGS -isysroot $TARGET_SYSROOT"
fi

mkdir -p "$BUILD_DIR"

echo
echo "== Plan checkpoints =="
echo "1) Toolchain and dependency probe (gcc14, cmake, pkg-config, SDL2)."
echo "2) Configure for legacy target (macOS 10.5, $TARGET_ARCH) using MacPorts libs."
echo "3) Build with verbose output to surface ABI/API incompatibilities."
echo "4) Stage output under $INSTALL_PREFIX for manual runtime validation."
echo "5) Optional smoke run with OpenGL renderer forced via SDL hints."

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$MACPORTS_PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET_DEPLOYMENT" \
    -DCMAKE_OSX_ARCHITECTURES="$TARGET_ARCH" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DSDL2_PATH="$MACPORTS_PREFIX" \
    -DSDL2_MIXER_PATH="$MACPORTS_PREFIX"

cmake --build "$BUILD_DIR" --verbose
cmake --install "$BUILD_DIR"

echo
echo "Build complete."
echo "Binary: $SCRIPT_DIR/bin/SpaceCadetPinball"
echo "Installed under: $INSTALL_PREFIX"

if [[ "$DO_RUN" -eq 1 ]]; then
    echo
    echo "Launching with SDL_RENDER_DRIVER=$SDL_RENDER_DRIVER"
    "$SCRIPT_DIR/bin/SpaceCadetPinball" -sw || true
fi

