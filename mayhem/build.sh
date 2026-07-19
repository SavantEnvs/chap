#!/usr/bin/env bash
# chap/mayhem/build.sh — build vmware/chap (analyzes un-instrumented process core files for leaks,
# memory growth, and corruption) for two Mayhem targets, plus chap's own golden-output test suite for
# mayhem/test.sh.
#
# Targets (both ported from the old integration):
#   (1) chap        — FILE-INPUT (CLI): chap parses a core DUMP file given as argv[1]. The whole core-file
#                     reader + analysis engine (ELF32/ELF64 core parsing, libc-malloc heap reconstruction,
#                     allocation graph, leak detection) runs on the input bytes. Mayhem feeds the fuzz file
#                     as the core: `/mayhem/chap @@`. No libFuzzer harness — the natural fuzz surface is
#                     the tool on a core file. Built at /mayhem/chap.
#   (2) unmangled   — libFuzzer harness (mayhem/fuzz_Unmangled.cpp) over chap's own C++ symbol demangler
#                     chap::CPlusPlus::Unmangler<char> (src/CPlusPlus/Unmangler.h) on the fuzz bytes as a
#                     mangled name. Built at /mayhem/fuzz_Unmangled (+ -standalone reproducer).
#
# chap is C++/CMake. thirdparty/replxx is a git submodule (a readline replacement linked into chap);
# build.sh inits it from .gitmodules (the base ships git). The whole chap binary — including the core
# reader — is compiled WITH $SANITIZER_FLAGS so the fuzzed code is instrumented, not just the harness.
#
# Build contract from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/STANDALONE_FUZZ_MAIN).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ── Submodule: thirdparty/replxx (linked into chap) ──────────────────────────────────────────────
# Populate from .gitmodules if the working-tree copy is empty (the base has git; the CI checkout uses
# submodules: recursive, but build.sh inits it too so a bare COPY of the tree still builds).
if [ -z "$(ls -A thirdparty/replxx 2>/dev/null)" ]; then
  git submodule update --init thirdparty/replxx
fi

# Weak __asan_default_options (detect_leaks=0) baked into each target so no ASAN_OPTIONS is ever needed
# in a Mayhemfile. Compiled to an object linked into BOTH targets.
ASAN_OPTS_OBJ=/tmp/asan_default_options.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/asan_default_options.c" -o "$ASAN_OPTS_OBJ"

# Relax ONE benign UBSan check for chap: `alignment`. chap is a core-file reader that intentionally
# loads multi-byte values from UNALIGNED offsets in the memory-mapped core image (VirtualAddressMap.h
# reinterpret-casts into the mmap'd bytes). Under halting UBSan that `alignment` check fires on EVERY
# core — including chap's own valid test cores — aborting before the fuzzer explores any real defect
# (PORTING.md "benign UB that floods under halting UBSan"). ASan and the REST of UBSan stay ON and
# HALTING, so real memory/UB defects in the parser still crash the fuzzer. Applied only when UBSan is
# active (skipped for the empty-sanitizer off-switch). Smoke-tested: a valid core then runs to exit 0.
CHAP_SAN_FLAGS="$SANITIZER_FLAGS"
if printf '%s' "$SANITIZER_FLAGS" | grep -q undefined; then
  CHAP_SAN_FLAGS="$SANITIZER_FLAGS -fno-sanitize=alignment"
fi

# ── 1) SANITIZED build of chap (the FILE-INPUT target; the WHOLE tool is instrumented) ───────────
# CMake builds the `chap` executable (src/FileAnalyzer.cpp + Replxx::Replxx static lib). We inject
# $SANITIZER_FLAGS into the C/CXX flags so the core-file reader and analysis engine are instrumented.
# The weak __asan_default_options object is linked in via CMAKE_EXE_LINKER_FLAGS (additive — no upstream
# CMake edit). BUILD_TESTING=OFF here — the CTest suite is built separately below with NORMAL flags.
cmake -S "$SRC" -B "$SRC/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$CHAP_SAN_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$CHAP_SAN_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$ASAN_OPTS_OBJ"
cmake --build "$SRC/build" -j"$MAYHEM_JOBS" --target chap

[ -f "$SRC/build/chap" ] || { echo "ERROR: $SRC/build/chap not produced" >&2; \
  find "$SRC/build" -name chap -type f -print >&2; exit 1; }
cp -f "$SRC/build/chap" /mayhem/chap

# ── 2) libFuzzer + standalone for the Unmangled demangler harness ────────────────────────────────
# The harness includes "Unmangler.h" (header-only template) directly -> -I src/CPlusPlus. It also
# includes <fuzzer/FuzzedDataProvider.h> (shipped in clang's resource dir). No chap object needed.
HARNESS="$SRC/mayhem/fuzz_Unmangled.cpp"
UNMANGLER_INC=(-I "$SRC/src/CPlusPlus")

# libFuzzer target -> /mayhem/fuzz_Unmangled
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${UNMANGLER_INC[@]}" \
    "$HARNESS" "$ASAN_OPTS_OBJ" $LIB_FUZZING_ENGINE \
    -o /mayhem/fuzz_Unmangled

# standalone reproducer (no libFuzzer runtime) -> /mayhem/fuzz_Unmangled-standalone.
# Compile the LLVM run-once driver as a C object first so its extern "C" LLVMFuzzerTestOneInput ref
# isn't mangled by clang++ at link.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${UNMANGLER_INC[@]}" \
    "$HARNESS" /tmp/standalone_main.o "$ASAN_OPTS_OBJ" \
    -o /mayhem/fuzz_Unmangled-standalone

# ── 3) Build chap's OWN expectedOutput CTest suite with NORMAL flags (clean, separate tree) so
#       test.sh only RUNS it (honest PATCH oracle, no sanitizer noise). BUILD_TESTING=ON wires the
#       test/expectedOutput golden-output tests via CTest. ──────────────────────────────────────────
env -u CFLAGS -u CXXFLAGS \
cmake -S "$SRC" -B "$SRC/build-tests" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=ON \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target chap

echo "build.sh complete:"
ls -la /mayhem/chap /mayhem/fuzz_Unmangled /mayhem/fuzz_Unmangled-standalone "$SRC/build-tests/chap" 2>&1 || true
