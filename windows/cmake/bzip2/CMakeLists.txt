# bzip2 has no upstream CMake build — 1.0.8 ships a hand-written Makefile that
# assumes a Unix toolchain. The library itself is seven translation units that
# have not changed since 2019, so building it is a shorter and more auditable
# step than carrying a patched autotools/nmake setup.
#
# Static only, and no tools: libarchive links bzlib and nothing here ships
# bzip2(1).
cmake_minimum_required(VERSION 3.16)
project(bzip2 C)

# BZIP2_SOURCE_DIR points at the extracted upstream tree; this file deliberately
# lives outside it so the download stays pristine and checksum-verifiable.
if(NOT DEFINED BZIP2_SOURCE_DIR)
  message(FATAL_ERROR "BZIP2_SOURCE_DIR must point at the extracted bzip2 source")
endif()
# A native Windows path arrives with backslashes, and CMake reads \U in one as a
# string escape when install() re-serializes the path into cmake_install.cmake.
file(TO_CMAKE_PATH "${BZIP2_SOURCE_DIR}" BZIP2_SOURCE_DIR)

add_library(bz2 STATIC
  ${BZIP2_SOURCE_DIR}/blocksort.c
  ${BZIP2_SOURCE_DIR}/huffman.c
  ${BZIP2_SOURCE_DIR}/crctable.c
  ${BZIP2_SOURCE_DIR}/randtable.c
  ${BZIP2_SOURCE_DIR}/compress.c
  ${BZIP2_SOURCE_DIR}/decompress.c
  ${BZIP2_SOURCE_DIR}/bzlib.c
)
target_include_directories(bz2 PUBLIC ${BZIP2_SOURCE_DIR})

if(MSVC)
  # Upstream is C89 and trips a pile of MSVC's "unsafe CRT" and conversion
  # warnings that are not ours to fix.
  target_compile_definitions(bz2 PRIVATE _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
  target_compile_options(bz2 PRIVATE /W0)
endif()

install(TARGETS bz2 ARCHIVE DESTINATION lib)
install(FILES ${BZIP2_SOURCE_DIR}/bzlib.h DESTINATION include)
