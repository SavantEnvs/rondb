#!/usr/bin/env bash
#
# mayhem/build.sh - builds the MySQL Router libFuzzer harnesses that ship in the RonDB tree, plus the
# Router's own known-answer unit tests (the oracle for mayhem/test.sh).
#
# Runs inside the commit image as `mayhem` in /mayhem. Re-runnable and offline: RonDB bundles boost,
# protobuf, zlib etc., so nothing is fetched; only apt -dev packages (installed in the Dockerfile) are used.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_BUILD="$SRC/build/fuzz"
TEST_BUILD="$SRC/build/test"
mkdir -p "$SRC/build"

# harness name (binary under /mayhem) -> CMake target name in the RonDB tree is routertest_fuzz_<name>
HARNESSES=(
  http_auth_backend
  http_auth_method_basic
  http_base64
  router_uri
  router_uri_tostring
  routing_parser_show_warnings
  routing_sql_lexer
  mysql_protocol_binary_datetime
  mysql_protocol_binary_time
  mysql_protocol_binlog_dump
  mysql_protocol_binlog_dump_gtid
  mysql_protocol_change_user
  mysql_protocol_client_greeting
  mysql_protocol_clone
  mysql_protocol_init_schema
  mysql_protocol_list_fields
  mysql_protocol_ping
  mysql_protocol_query
  mysql_protocol_quit
  mysql_protocol_register_replica
  mysql_protocol_reload
  mysql_protocol_reset_connection
  mysql_protocol_set_option
  mysql_protocol_statistics
  mysql_protocol_stmt_close
  mysql_protocol_stmt_execute
  mysql_protocol_stmt_fetch
  mysql_protocol_stmt_param_append_data
  mysql_protocol_stmt_prepare
  mysql_protocol_stmt_reset
)
CMAKE_TARGETS=()
for h in "${HARNESSES[@]}"; do CMAKE_TARGETS+=("routertest_fuzz_${h}"); done

# 1) LeakSanitizer off + run-once driver (C object so clang++ does not mangle LLVMFuzzerTestOneInput).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o

# 2) Sanitized project + fuzz harnesses. The whole Router dependency closure is compiled with
#    $SANITIZER_FLAGS and with libFuzzer coverage instrumentation (fuzzer-no-link); each harness is linked
#    with -fsanitize=fuzzer by upstream's own LIBFUZZER_ADD_TEST. Upstream's -fprofile-instr-generate
#    source-coverage flags are switched off (COMPILER_HAS_PROFILE_INSTR_GENERATE=0): the extra profiling
#    runtime only slows fuzzing.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
# Configure once: re-running cmake over an existing MySQL cache drops the sanitizer flags on the second pass,
# so a re-run of build.sh only runs make (which regenerates by itself when CMake inputs change).
[ -f "$FUZZ_BUILD/Makefile" ] || cmake -S "$SRC" -B "$FUZZ_BUILD" -G "Unix Makefiles" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SRC/build/lsan_off.o" \
  -DCOMPILER_HAS_PROFILE_INSTR_GENERATE=0 -DCOMPILER_HAS_COVERAGE_MAPPING=0 \
  -DWITH_ROUTER=ON -DWITH_UNIT_TESTS=ON
make -C "$FUZZ_BUILD" -j"$MAYHEM_JOBS" "${CMAKE_TARGETS[@]}"

for h in "${HARNESSES[@]}"; do
  t="routertest_fuzz_${h}"
  bin=$(find "$FUZZ_BUILD" -type f -name "$t" -perm -u+x | head -n1)
  [ -n "$bin" ] || { echo "missing fuzz binary for $t" >&2; exit 1; }
  cp -f "$bin" "$SRC/fuzz_${h}"

  # Standalone (non-libFuzzer) reproducer: replay upstream's link line with the run-once driver instead of -fsanitize=fuzzer.
  link=$(find "$FUZZ_BUILD" -path "*/CMakeFiles/${t}.dir/link.txt" | head -n1)
  [ -n "$link" ] || { echo "missing link.txt for $t" >&2; exit 1; }
  ( cd "$(dirname "$link")/../.." && \
    cmd=$(sed -E 's# -fsanitize=fuzzer( |$)# #g; s# -o [^ ]+# '"$SRC"'/build/standalone_main.o -o '"$SRC/fuzz_${h}-standalone"'#' "$link") && \
    eval "$cmd" )
done

# 3) The Router's own unit tests (known-answer codec/URI/base64 suites) with the project's NORMAL flags.
[ -f "$TEST_BUILD/Makefile" ] || cmake -S "$SRC" -B "$TEST_BUILD" -G "Unix Makefiles" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DWITH_ROUTER=ON -DWITH_UNIT_TESTS=ON
make -C "$TEST_BUILD" -j"$MAYHEM_JOBS" \
  routertest_mysql_protocol_classic_protocol_wire routertest_http_base64 routertest_http_uri routertest_router_uri
