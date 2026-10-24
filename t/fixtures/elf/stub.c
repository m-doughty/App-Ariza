/*
 * Stands in for the libraries a fixture names in DT_NEEDED. build.sh
 * links it under the sonames libcrypto.so.3 and libc.so.6 so the
 * fixtures name the libraries a real SQLCipher does, without linking a
 * real one. The stubs themselves are not kept.
 */
int ariza_stub(void) { return 7; }
