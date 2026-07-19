/* Weak __asan_default_options baked into each Mayhem target so we never need ASAN_OPTIONS in a
 * Mayhemfile (which Mayhem forbids). detect_leaks=0: chap and the demangler legitimately leave
 * allocations live at process exit on many inputs (chap is a one-shot analyzer that exits without
 * tearing down its in-memory model), which LeakSanitizer would otherwise report as false-positive
 * "leaks" on essentially every run, drowning real ASan findings. The function is weak so a build that
 * sets ASAN_OPTIONS explicitly can still override it. */
const char *__asan_default_options(void) {
  return "detect_leaks=0";
}
