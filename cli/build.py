#!/usr/bin/env python3
"""Omi build menu (Python)."""

import os
import subprocess
import sys

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILD_DIR = os.path.join(ROOT_DIR, "build")


def mkdir(path):
    os.makedirs(path, exist_ok=True)


def run(cmd):
    print(" ".join(cmd))
    return subprocess.call(cmd) == 0


def has_cmd(cmd):
    return subprocess.call(["which", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def build_haxe(target):
    target_dir = os.path.join(BUILD_DIR, target)
    mkdir(target_dir)
    if target == "cpp":
        return run(["haxe", "-cp", ROOT_DIR, "-main", "Omi", "-cpp", target_dir])
    if target == "js":
        return run(["haxe", "-cp", ROOT_DIR, "-main", "Omi", "-js", os.path.join(target_dir, "omi.js")])
    if target == "python":
        return run(["haxe", "-cp", ROOT_DIR, "-main", "Omi", "-python", os.path.join(target_dir, "omi.py")])
    if target == "php":
        return run(["haxe", "-cp", ROOT_DIR, "-main", "Omi", "-php", target_dir])
    if target == "cs":
        return run(["haxe", "-cp", ROOT_DIR, "-main", "Omi", "-cs", target_dir])
    if target == "java":
        return run(["haxe", "-cp", ROOT_DIR, "-main", "Omi", "-java", target_dir])
    return False


def build_c89():
    target_dir = os.path.join(BUILD_DIR, "c89")
    mkdir(target_dir)
    if has_cmd("gcc"):
        return run(["gcc", "-std=c89", "-O2", "-o", os.path.join(target_dir, "omi"), os.path.join(ROOT_DIR, "omi.c"), "-lsqlite3"])
    if has_cmd("clang"):
        return run(["clang", "-std=c89", "-O2", "-o", os.path.join(target_dir, "omi"), os.path.join(ROOT_DIR, "omi.c"), "-lsqlite3"])
    print("No C compiler found (gcc/clang). Skipping C89 build.")
    return False


def build_csharp():
    target_dir = os.path.join(BUILD_DIR, "csharp")
    mkdir(target_dir)
    if has_cmd("mcs"):
        return run(["mcs", f"-out:{os.path.join(target_dir, 'omi.exe')}", os.path.join(ROOT_DIR, "omi.cs"), "-r:System.Data.SQLite"])
    print("mcs not found. Skipping C# build.")
    return False


def build_all():
    if has_cmd("haxe"):
        for tgt in ["cpp", "js", "python", "php", "cs", "java"]:
            build_haxe(tgt)
    else:
        print("Haxe not found in PATH. Skipping Haxe targets.")
    build_c89()
    build_csharp()


def main():
    mkdir(BUILD_DIR)
    menu = (
        "Build targets:\n"
        " 1) All (Haxe + C89 + C#)\n"
        " 2) Haxe: cpp\n"
        " 3) Haxe: js\n"
        " 4) Haxe: python\n"
        " 5) Haxe: php\n"
        " 6) Haxe: cs\n"
        " 7) Haxe: java\n"
        " 8) C89 (native)\n"
        " 9) C# / Mono\n"
        " 0) Quit\n"
    )
    print(menu)
    choice = input("Select target: ").strip()

    if choice == "1":
        build_all()
    elif choice == "2":
        build_haxe("cpp")
    elif choice == "3":
        build_haxe("js")
    elif choice == "4":
        build_haxe("python")
    elif choice == "5":
        build_haxe("php")
    elif choice == "6":
        build_haxe("cs")
    elif choice == "7":
        build_haxe("java")
    elif choice == "8":
        build_c89()
    elif choice == "9":
        build_csharp()
    elif choice == "0":
        sys.exit(0)
    else:
        print("Unknown choice")
        sys.exit(1)

    print("Build complete. Output in", BUILD_DIR)


if __name__ == "__main__":
    main()
