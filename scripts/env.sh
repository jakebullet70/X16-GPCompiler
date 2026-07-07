#!/usr/bin/env bash
# Shared toolchain paths for Blitz-X16 build/run scripts.
# JDK is intentionally not on PATH on this machine, so we point at it directly.
export JAVA="/c/dev/b4x/java19/bin/java.exe"
export X16EMU="/c/8bitProgramming/x16emu/x16emu.exe"

# Prog8 shells out to "64tass" by name, so its dir must be on PATH.
export PATH="/c/8bitProgramming/64tass-1.60:$PATH"

# Repo root = parent of this scripts/ dir.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# Prog8 compiler: use the project-local copy so the toolchain is self-contained.
export PROG8C="$ROOT/prog8c.jar"
