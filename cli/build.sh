#!/bin/sh
# Build menu for Omi targets (Haxe + optional C89/C#)

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"

mkdir -p "$BUILD_DIR"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

build_haxe() {
  target="$1"
  mkdir -p "$BUILD_DIR/$target"
  case "$target" in
    cpp)
      haxe -cp "$ROOT_DIR" -main Omi -cpp "$BUILD_DIR/$target"
      ;;
    js)
      haxe -cp "$ROOT_DIR" -main Omi -js "$BUILD_DIR/$target/omi.js"
      ;;
    python)
      haxe -cp "$ROOT_DIR" -main Omi -python "$BUILD_DIR/$target/omi.py"
      ;;
    php)
      haxe -cp "$ROOT_DIR" -main Omi -php "$BUILD_DIR/$target"
      ;;
    cs)
      haxe -cp "$ROOT_DIR" -main Omi -cs "$BUILD_DIR/$target"
      ;;
    java)
      haxe -cp "$ROOT_DIR" -main Omi -java "$BUILD_DIR/$target"
      ;;
  esac
}

build_c89() {
  mkdir -p "$BUILD_DIR/c89"
  if has_cmd gcc; then
    gcc -std=c89 -O2 -o "$BUILD_DIR/c89/omi" "$ROOT_DIR/omi.c" -lsqlite3
  elif has_cmd clang; then
    clang -std=c89 -O2 -o "$BUILD_DIR/c89/omi" "$ROOT_DIR/omi.c" -lsqlite3
  else
    echo "No C compiler found (gcc/clang). Skipping C89 build."
  fi
}

build_csharp() {
  mkdir -p "$BUILD_DIR/csharp"
  if has_cmd mcs; then
    mcs -out:"$BUILD_DIR/csharp/omi.exe" "$ROOT_DIR/omi.cs" -r:System.Data.SQLite
  else
    echo "Mono compiler (mcs) not found. Skipping C# build."
  fi
}

build_all() {
  if has_cmd haxe; then
    build_haxe cpp
    build_haxe js
    build_haxe python
    build_haxe php
    build_haxe cs
    build_haxe java
  else
    echo "Haxe not found in PATH. Skipping Haxe targets."
  fi
  build_c89
  build_csharp
}

show_menu() {
  echo "Build targets:"
  echo " 1) All (Haxe + C89 + C#)"
  echo " 2) Haxe: cpp"
  echo " 3) Haxe: js"
  echo " 4) Haxe: python"
  echo " 5) Haxe: php"
  echo " 6) Haxe: cs"
  echo " 7) Haxe: java"
  echo " 8) C89 (native)"
  echo " 9) C# / Mono"
  echo " 0) Quit"
  printf "Select target: "
}

show_menu
read choice

case "$choice" in
  1) build_all ;;
  2) build_haxe cpp ;;
  3) build_haxe js ;;
  4) build_haxe python ;;
  5) build_haxe php ;;
  6) build_haxe cs ;;
  7) build_haxe java ;;
  8) build_c89 ;;
  9) build_csharp ;;
  0) exit 0 ;;
  *) echo "Unknown choice"; exit 1 ;;
 esac

echo "Build complete. Output in $BUILD_DIR"