cmake_minimum_required(VERSION 3.16)

# The compiled Windows launcher a bundle ships as bin/<exec>.exe, and the
# portable core it is built on.
#
# Two build shapes, on purpose:
#
#   * On Windows (MSYS2 UCRT64 for x86_64, CLANGARM64 for aarch64) this
#     builds the executable that gets published as a release artefact and
#     pinned by resources/runner-checksums.txt.  That is the only lane
#     that produces something a bundle carries.
#   * Everywhere else it builds the core and its tests, and nothing else:
#     src/main_win32.c is not in the target list, and the file is
#     #ifdef'd besides.  The rules worth testing — the argv[0] boundary,
#     the quoting, the sidecar grammar, the environment values — are all
#     in the core, so `ctest` says something useful on a Mac or a Linux
#     CI runner, which is where this repository's suite actually runs.
#
# MSVC is deliberately not a target.  The runner is built by the same
# MSYS2 toolchains that build the notcurses packs a bundle carries, which
# keeps one C toolchain story for the whole Windows path.

project(ariza-runner
	DESCRIPTION "Compiled launcher for ariza bundles on Windows"
	LANGUAGES C)

option(ARIZA_RUNNER_BUILD_TESTS "Build the runner test suite" ON)
option(ARIZA_RUNNER_WERROR "Treat warnings as errors" OFF)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Strict -std=c17 (C_EXTENSIONS OFF) makes glibc hide POSIX interfaces
# unless a feature-test macro asks for them; _DEFAULT_SOURCE /
# _DARWIN_C_SOURCE keep the glibc / macOS default namespaces intact
# alongside it.  The core itself only needs <stdlib.h>, but the test
# harness prints, and the next thing added here should not have to
# rediscover this.
if(WIN32)
	add_compile_definitions(UNICODE _UNICODE)
else()
	add_compile_definitions(_POSIX_C_SOURCE=200809L _DEFAULT_SOURCE
		_DARWIN_C_SOURCE)
endif()

set(ARIZA_RUNNER_C_WARNINGS -Wall -Wextra -Wshadow -Wvla)
if(ARIZA_RUNNER_WERROR)
	list(APPEND ARIZA_RUNNER_C_WARNINGS -Werror)
endif()

add_library(ariza_runner_core STATIC
	src/strings.c
	src/config.c
	src/env.c
	src/cmdline.c)
target_include_directories(ariza_runner_core PUBLIC include)
set_target_properties(ariza_runner_core PROPERTIES
	C_STANDARD 17 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
target_compile_options(ariza_runner_core PRIVATE ${ARIZA_RUNNER_C_WARNINGS})

if(WIN32)
	add_executable(ariza_runner src/main_win32.c)
	target_link_libraries(ariza_runner PRIVATE ariza_runner_core)
	set_target_properties(ariza_runner PROPERTIES
		C_STANDARD 17 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
		# The release lanes rename this to
		# ariza-runner-windows-<arch>.exe; a bundle then stages it as
		# bin/<exec>.exe.  ARIZA_RUNNER_OUTPUT_NAME lets the lane do
		# the naming here instead of with a `mv`.
		OUTPUT_NAME "${ARIZA_RUNNER_OUTPUT_NAME}")
	if(NOT ARIZA_RUNNER_OUTPUT_NAME)
		set_target_properties(ariza_runner PROPERTIES OUTPUT_NAME ariza-runner)
	endif()
	target_compile_options(ariza_runner PRIVATE ${ARIZA_RUNNER_C_WARNINGS})
	# -municode gives wmain and a UTF-16 entry point.  Both mingw-w64
	# GCC (UCRT64) and clang's mingw driver (CLANGARM64) accept it, and
	# it has to reach the link as well as the compile: it selects
	# crt2u.o, which is what calls wmain rather than main.
	target_compile_options(ariza_runner PRIVATE -municode)
	target_link_options(ariza_runner PRIVATE -municode)
	# -static, because this executable is copied into a bundle and run
	# on machines that have never heard of MSYS2.  Without it the link
	# can pick up libgcc_s_seh-1.dll or libwinpthread-1.dll from the
	# build environment, and the failure would be invisible everywhere
	# it was tested and total on a user's machine — the same shape of
	# bug as an MSVC-built dependency importing vcruntime140.dll.  The
	# release lane asserts the import table afterwards, because a
	# compiler flag is a hope and the PE header is the fact.
	target_link_options(ariza_runner PRIVATE -static)
endif()

if(ARIZA_RUNNER_BUILD_TESTS)
	enable_testing()

	add_library(ariza_runner_test_support STATIC tests/support.c)
	target_link_libraries(ariza_runner_test_support PUBLIC ariza_runner_core)
	target_include_directories(ariza_runner_test_support PUBLIC tests)
	set_target_properties(ariza_runner_test_support PROPERTIES
		C_STANDARD 17 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
	target_compile_options(ariza_runner_test_support PRIVATE
		${ARIZA_RUNNER_C_WARNINGS})

	# The committed rendering of the sidecar template, which
	# tests/test_config.c parses with the real parser.  An absolute path
	# baked in at configure time, because ctest runs from the build
	# directory and this is the one file the C suite shares with the
	# Raku one.
	get_filename_component(ARIZA_GOLDEN_SIDECAR
		"${CMAKE_CURRENT_SOURCE_DIR}/../t/golden/launcher-windows-x86_64.ariza"
		ABSOLUTE)

	foreach(t IN ITEMS config env cmdline)
		add_executable(test_${t} tests/test_${t}.c)
		target_compile_definitions(test_${t} PRIVATE
			ARIZA_GOLDEN_SIDECAR="${ARIZA_GOLDEN_SIDECAR}")
		target_link_libraries(test_${t} PRIVATE ariza_runner_test_support)
		set_target_properties(test_${t} PROPERTIES
			C_STANDARD 17 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
		target_compile_options(test_${t} PRIVATE ${ARIZA_RUNNER_C_WARNINGS})
		add_test(NAME ${t} COMMAND test_${t})
	endforeach()
endif()
