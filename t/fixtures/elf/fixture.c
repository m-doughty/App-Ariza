/*
 * The one function every ELF fixture in this directory exports.
 *
 * What the tests read is not this code but the dynamic section a linker
 * writes around it -- DT_NEEDED, DT_RPATH, DT_RUNPATH and the string
 * table they point into. build.sh says how each fixture was linked.
 */
int ariza_fixture(void) { return 42; }
