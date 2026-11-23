#!/usr/bin/env bash
# Builds Pyx into a double-clickable app for the computer it runs on.
#   ./packaging/build.sh [version] [app-image|installer]
#     version  : like 1.0.0 (default 1.0.0)
#     app-image: a ready-to-run app folder  (all systems; Windows: zip it, Mac: a .app)
#     installer: Windows -> Pyx-<version>.exe     Mac -> Pyx-<version>.dmg
# Needs a full JDK 21 (javac + jpackage). The Windows installer also needs WiX Toolset 3.
# Windows and Mac installers can only be built ON Windows / Mac: the GitHub workflow in .github/ does that for you.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
TARGET="${2:-app-image}"
NAME="Pyx"
FLATLAF="flatlaf-3.5.4.jar"
JLAYER="jlayer-1.0.1.4.jar"
BASE_MODULES="java.desktop,java.prefs,java.logging,jdk.unsupported"

case "$(uname -s)" in
  Darwin) OS=mac ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) OS=linux ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. Install a full JDK 21 (not just a JRE)."; exit 1; }; }
need javac; need jar; need jpackage

# --- the two libraries the program needs: use libs/ if they are there, else download them
mkdir -p libs
fetch() { # file url
  if [ ! -f "libs/$1" ]; then echo "Downloading $1 ..."; curl -fsSL -o "libs/$1" "$2"; fi
}
fetch "$FLATLAF" "https://repo1.maven.org/maven2/com/formdev/flatlaf/3.5.4/$FLATLAF"
fetch "$JLAYER"  "https://repo1.maven.org/maven2/com/googlecode/soundlibs/jlayer/1.0.1.4/$JLAYER"

# --- compile and make the program jar
rm -rf build
if [ "$TARGET" = app-image ]; then rm -rf dist; fi   # the installer step reuses the app image made just before it
mkdir -p build/classes build/input dist
echo "Compiling ..."
javac -encoding UTF-8 --release 17 -cp "libs/*" -d build/classes src/Pyx.java
cp packaging/icon.png build/classes/icon.png   # window/taskbar icon, read by Pyx.appIcons()
printf 'Main-Class: Pyx\nClass-Path: %s %s\n' "$FLATLAF" "$JLAYER" > build/manifest.txt
jar cfm build/input/pyx.jar build/manifest.txt -C build/classes .
cp "libs/$FLATLAF" "libs/$JLAYER" build/input/

# which parts of Java the program and its libraries really use (so the bundled Java is small but never missing something)
DETECTED="$(jdeps --ignore-missing-deps --multi-release 17 --print-module-deps --class-path 'build/input/*' build/input/pyx.jar 2>/dev/null || true)"
MODULES="$BASE_MODULES${DETECTED:+,$DETECTED}"
echo "Java modules to bundle: $MODULES"

COMMON=(--name "$NAME" --app-version "$VERSION" --vendor "Pyx"
        --description "Practise Mandarin tones by shadowing recordings"
        --input build/input --main-jar pyx.jar --main-class Pyx
        --add-modules "$MODULES" --dest dist)

ICON=packaging/icon.png
[ "$OS" = windows ] && ICON=packaging/icon.ico
[ "$OS" = mac ] && ICON=packaging/icon.icns

if [ "$TARGET" = app-image ]; then
  echo "Building app image ($OS) ..."
  EXTRA=()
  if [ "$OS" = mac ]; then EXTRA=(--mac-package-identifier org.pyx.app); fi
  jpackage --type app-image "${COMMON[@]}" --icon "$ICON" ${EXTRA[@]+"${EXTRA[@]}"}
  if [ "$OS" = mac ]; then
    # Apple-silicon Macs refuse to run code with no signature at all, so give it a free "ad hoc" one.
    echo "Signing (ad hoc) ..."
    codesign --force --deep --sign - "dist/$NAME.app"
    codesign --verify --deep --strict "dist/$NAME.app"
  fi
  echo "Done: dist/"; ls dist
  exit 0
fi

# installer
case "$OS" in
  windows)
    echo "Building the Windows installer ..."
    # per-user install: students do not need an administrator password
    jpackage --type exe "${COMMON[@]}" --icon "$ICON" \
      --win-menu --win-menu-group "$NAME" --win-shortcut --win-dir-chooser --win-per-user-install \
      --win-upgrade-uuid "8d3c2f4e-5a71-4c0e-9b6a-2f1d7e90a4b3"
    ;;
  mac)
    echo "Building the Mac disk image ..."
    # package the app image built (and signed) by 'app-image' first
    [ -d "dist/$NAME.app" ] || { echo "Run './packaging/build.sh $VERSION app-image' first."; exit 1; }
    mkdir -p build/dmg-src && rm -rf build/dmg-src/* && cp -R "dist/$NAME.app" build/dmg-src/
    jpackage --type dmg --name "$NAME" --app-version "$VERSION" --vendor "Pyx" \
      --app-image "build/dmg-src/$NAME.app" --icon "$ICON" --dest dist \
      --mac-package-identifier org.pyx.app
    ;;
  *) echo "Installers are only built for Windows and Mac (this is $OS). Use the app-image target."; exit 1 ;;
esac
echo "Done: dist/"; ls dist
