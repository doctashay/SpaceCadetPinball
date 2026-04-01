#!/usr/bin/env bash

set -euo pipefail

# Space Cadet Pinball legacy macOS 10.4+ build/port test driver.
# Assumptions:
# - Toolchain and dependencies are installed via MacPorts + Legacy Support.
# - GCC 14 is used as the compiler frontend.
# - SDL2 renderer is forced to OpenGL (OpenGL2-era backend on legacy systems).
#
# Usage:
#   ./test_build_10.5.sh
#   ./test_build_10.5.sh --run
#   ./test_build_10.5.sh --run --audio-check
#
# Environment overrides:
#   MACPORTS_PREFIX      (default: /opt/local)
#   TARGET_ARCH          (default: ppc)
#   TARGET_SYSROOT       (optional; SDK sysroot path)
#   TARGET_DEPLOYMENT    (default: 10.4)
#   BUILD_DIR            (default: build-10.4)
#   INSTALL_PREFIX       (default: <repo>/out-10.4)
#   APP_BUNDLE_DIR       (default: <repo>/SpaceCadetPinball.app)
#   APP_VERSION          (default: 2.1.1-ppc)
#   DAT_SOURCE           (default: auto-detect PINBALL.DAT/pinball.dat)
#   WAV_SOURCE_DIR       (default: DAT source directory)
#   PROFILE              (default: safe; values: safe|aggressive)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
TARGET_ARCH="${TARGET_ARCH:-ppc}"
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-10.4}"
TARGET_SYSROOT="${TARGET_SYSROOT:-}"
BUILD_DIR="${BUILD_DIR:-build-10.4}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$SCRIPT_DIR/out-10.4}"
APP_BUNDLE_DIR="${APP_BUNDLE_DIR:-$SCRIPT_DIR/SpaceCadetPinball.app}"
APP_VERSION="${APP_VERSION:-2.1.1-ppc}"
DAT_SOURCE="${DAT_SOURCE:-}"
WAV_SOURCE_DIR="${WAV_SOURCE_DIR:-}"
PROFILE="${PROFILE:-safe}"
DO_RUN=0
AUDIO_CHECK=0

for arg in "$@"; do
    case "$arg" in
        --run)
            DO_RUN=1
            ;;
        --audio-check)
            AUDIO_CHECK=1
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

echo "== SpaceCadetPinball macOS 10.4+ OpenGL2 port test =="
echo "Repo:               $SCRIPT_DIR"
echo "MacPorts prefix:    $MACPORTS_PREFIX"
echo "Target arch:        $TARGET_ARCH"
echo "Deployment target:  $TARGET_DEPLOYMENT"
echo "Build directory:    $BUILD_DIR"
echo "Install prefix:     $INSTALL_PREFIX"
echo "App bundle:         $APP_BUNDLE_DIR"

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

COMMON_CFLAGS="-O3 -pipe -arch $TARGET_ARCH -mcpu=G4 -mtune=G4 -fomit-frame-pointer -DNDEBUG -mmacosx-version-min=$TARGET_DEPLOYMENT"
COMMON_CXXFLAGS="$COMMON_CFLAGS"
COMMON_LDFLAGS="-arch $TARGET_ARCH -mcpu=G4 -mtune=G4 -mmacosx-version-min=$TARGET_DEPLOYMENT"

case "$PROFILE" in
    safe)
        ;;
    aggressive)
        COMMON_CFLAGS="$COMMON_CFLAGS -ffast-math"
        COMMON_CXXFLAGS="$COMMON_CXXFLAGS -ffast-math"
        ;;
    *)
        echo "Unknown PROFILE value: $PROFILE (expected safe or aggressive)" >&2
        exit 2
        ;;
esac

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
echo "4) Create SpaceCadetPinball.app and embed game data."
echo "5) Stage output under $INSTALL_PREFIX for manual runtime validation."
echo "6) Optional smoke run with OpenGL renderer forced via SDL hints."

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
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

BIN_PATH="$SCRIPT_DIR/bin/SpaceCadetPinball"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Expected binary not found: $BIN_PATH" >&2
    exit 1
fi

if [[ -z "$DAT_SOURCE" ]]; then
    for candidate in \
        "$SCRIPT_DIR/PINBALL.DAT" \
        "$SCRIPT_DIR/pinball.dat" \
        "$SCRIPT_DIR/bin/PINBALL.DAT" \
        "$SCRIPT_DIR/bin/pinball.dat"; do
        if [[ -f "$candidate" ]]; then
            DAT_SOURCE="$candidate"
            break
        fi
    done
fi
if [[ -z "$DAT_SOURCE" || ! -f "$DAT_SOURCE" ]]; then
    echo "PINBALL.DAT source file not found." >&2
    echo "Set DAT_SOURCE=/absolute/path/to/PINBALL.DAT and run again." >&2
    exit 1
fi

APP_CONTENTS="$APP_BUNDLE_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
rm -rf "$APP_BUNDLE_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

cp "$BIN_PATH" "$APP_MACOS/SpaceCadetPinball"
cp "$DAT_SOURCE" "$APP_MACOS/PINBALL.DAT"

if [[ -z "$WAV_SOURCE_DIR" ]]; then
    WAV_SOURCE_DIR="$(cd "$(dirname "$DAT_SOURCE")" && pwd)"
fi

copied_wav_count=0
if [[ -d "$WAV_SOURCE_DIR" ]]; then
    shopt -s nullglob
    for wav_file in "$WAV_SOURCE_DIR"/*.WAV "$WAV_SOURCE_DIR"/*.wav; do
        cp "$wav_file" "$APP_MACOS/"
        copied_wav_count=$((copied_wav_count + 1))
    done
    shopt -u nullglob
fi

if [[ -d "$WAV_SOURCE_DIR/SOUND" ]]; then
    mkdir -p "$APP_MACOS/SOUND"
    shopt -s nullglob
    for wav_file in "$WAV_SOURCE_DIR/SOUND"/*.WAV "$WAV_SOURCE_DIR/SOUND"/*.wav; do
        cp "$wav_file" "$APP_MACOS/SOUND/"
        copied_wav_count=$((copied_wav_count + 1))
    done
    shopt -u nullglob
fi

INFO_PLIST_TEMPLATE="$SCRIPT_DIR/Platform/macOS/Info.plist"
if [[ -f "$INFO_PLIST_TEMPLATE" ]]; then
    cp "$INFO_PLIST_TEMPLATE" "$APP_CONTENTS/Info.plist"
    sed -i '' "s/CHANGEME_SW_VERSION/$APP_VERSION/" "$APP_CONTENTS/Info.plist"
    sed -i '' "s/<string>10\\.11<\\/string>/<string>$TARGET_DEPLOYMENT<\\/string>/" "$APP_CONTENTS/Info.plist"
else
    cat > "$APP_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>SpaceCadetPinball</string>
    <key>CFBundleIdentifier</key>
    <string>com.github.k4zmu2a.spacecadetpinball</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SpaceCadetPinball</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>$TARGET_DEPLOYMENT</string>
</dict>
</plist>
EOF
fi

ICON_PATH="$SCRIPT_DIR/space.icns"
if [[ -f "$ICON_PATH" ]]; then
    cp "$ICON_PATH" "$APP_RESOURCES/space.icns"
    if [[ -f "$APP_CONTENTS/Info.plist" ]]; then
        if rg -n "<key>CFBundleIconFile</key>" "$APP_CONTENTS/Info.plist" >/dev/null 2>&1; then
            sed -i '' "s#<key>CFBundleIconFile</key>[[:space:]]*<string>[^<]*</string>#<key>CFBundleIconFile</key>\n\t<string>space.icns</string>#" "$APP_CONTENTS/Info.plist"
        else
            sed -i '' "s#<key>CFBundleExecutable</key>[[:space:]]*<string>SpaceCadetPinball</string>#<key>CFBundleExecutable</key>\n\t<string>SpaceCadetPinball</string>\n\t<key>CFBundleIconFile</key>\n\t<string>space.icns</string>#" "$APP_CONTENTS/Info.plist"
        fi
    fi
fi

echo -n "APPL????" > "$APP_CONTENTS/PkgInfo"

echo
echo "Build complete."
echo "Binary: $BIN_PATH"
echo "App:    $APP_BUNDLE_DIR"
echo "Data:   $APP_MACOS/PINBALL.DAT"
echo "WAVs:   copied $copied_wav_count file(s)"
echo "Installed under: $INSTALL_PREFIX"

if [[ "$DO_RUN" -eq 1 ]]; then
    echo
    echo "Launching with SDL_RENDER_DRIVER=$SDL_RENDER_DRIVER"
    "$APP_MACOS/SpaceCadetPinball" -sw || true
fi

if [[ "$AUDIO_CHECK" -eq 1 ]]; then
    echo
    echo "Audio smoke-check:"
    echo "1) Ensure game starts WITHOUT '-noaudio'."
    echo "2) Verify startup log includes: 'Audio device opened: ...'."
    echo "3) Start a game and confirm launch/bounce sounds."
    echo "4) Verify background music starts after table load."
fi

