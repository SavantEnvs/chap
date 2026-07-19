// mayhem/lsan_off.cc — disable LeakSanitizer at BUILD time for every ASan-built chap target (fleet
// policy, PORTING.md). chap is a one-shot analyzer that exits without tearing down its in-memory
// model, and the demangler harness leaves allocations live too, so LSan would report a "leak" on
// essentially every run and drown the real findings. Leaks are not the bug class this fleet fuzzes
// for; ASan's memory-corruption checks and UBSan stay fully on and halting. `-fsanitize=address`
// always bundles LSan in, so the sanctioned off-switch is this weak-interface hook, compiled with
// $SANITIZER_FLAGS and linked into every sanitized binary (/mayhem/chap, /mayhem/fuzz_Unmangled and
// /mayhem/fuzz_Unmangled-standalone) — never a runtime LSan disable/enable wrap, never a compiled-in
// sanitizer default-options override and never a Mayhemfile ASAN_OPTIONS line (all three are gate
// FAILs; Mayhem alone owns the runtime option set).
extern "C" int __lsan_is_turned_off(void) { return 1; }
