#!/usr/bin/env bats
# host-integrity.bats -- tests for lib/host-integrity.sh.
# Added after INC-2026-09-29 (a test helper overwrote system binaries).
# SAFETY: setup refuses to run without a real BATS_TEST_TMPDIR, because the
# stubs below are executables written under it. Run via a read-only sandbox
# (see the repo README) so a bug here cannot touch the host.

setup() {
  : "${BATS_TEST_TMPDIR:?refusing to run outside bats}"
  case "$BATS_TEST_TMPDIR" in /bin* | /usr* | /sbin* | /lib* | /etc* | /) return 1 ;; esac
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/scan"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # shellcheck source=../lib/host-integrity.sh
  source "$SCRIPT_DIR/lib/host-integrity.sh"
  export HOST_INTEGRITY_SCAN_DIRS="$BATS_TEST_TMPDIR/scan"
  export HOST_INTEGRITY_UNPACKAGED_RE="^$BATS_TEST_TMPDIR/scan/"
  unset HOST_INTEGRITY_ALLOWLIST
}

# make_dpkg_stub: dpkg -S FILE -> "<pkg>: FILE" for names starting good-/bad-, exit 1 otherwise;
# dpkg -V PKG... -> a mismatch line for bad-pkg, nothing for good-pkg.
make_dpkg_stub() {
  cat >"$BATS_TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-S" ]; then
  b="$(basename "$2")"
  case "$b" in
    good-*) echo "goodpkg: $2"; exit 0 ;;
    bad-*)  echo "badpkg: $2"; exit 0 ;;
    *)      echo "dpkg-query: no path found matching pattern $2" >&2; exit 1 ;;
  esac
fi
if [ "$1" = "-V" ]; then
  shift
  for p in "$@"; do
    [ "$p" = "badpkg" ] && printf '??5??????   /usr/bin/mkdir\n'
  done
  exit 0
fi
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/dpkg"
}

@test "filter: reports a checksum mismatch in a binary directory" {
  run bash -c 'source "$1/lib/host-integrity.sh"; printf "??5??????   /usr/bin/ssh\n" | host_integrity_filter_dpkg_v' _ "$SCRIPT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/bin/ssh" ]
}

@test "filter: ignores configuration files (c marker)" {
  run bash -c 'source "$1/lib/host-integrity.sh"; printf "??5?????? c /usr/lib/foo.conf\n" | host_integrity_filter_dpkg_v' _ "$SCRIPT_DIR"
  [ -z "$output" ]
}

@test "filter: ignores paths outside binary and library directories" {
  run bash -c 'source "$1/lib/host-integrity.sh"; printf "??5??????   /usr/share/doc/x/readme\n??5??????   /etc/foo\n" | host_integrity_filter_dpkg_v' _ "$SCRIPT_DIR"
  [ -z "$output" ]
}

@test "filter: reports a missing binary" {
  run bash -c 'source "$1/lib/host-integrity.sh"; printf "missing     /usr/sbin/tool\n" | host_integrity_filter_dpkg_v' _ "$SCRIPT_DIR"
  [ "$output" = "/usr/sbin/tool" ]
}

@test "filter: ignores a missing configuration file and malformed lines" {
  run bash -c 'source "$1/lib/host-integrity.sh"; printf "missing   c /usr/lib/x.conf\ngarbage\n\n" | host_integrity_filter_dpkg_v' _ "$SCRIPT_DIR"
  [ -z "$output" ]
}

@test "allowlist removes exactly the listed paths" {
  printf '/usr/bin/ssh\n' >"$BATS_TEST_TMPDIR/allow"
  HOST_INTEGRITY_ALLOWLIST="$BATS_TEST_TMPDIR/allow" run bash -c 'source "$1/lib/host-integrity.sh"; printf "/usr/bin/ssh\n/usr/bin/curl\n" | host_integrity_apply_allowlist' _ "$SCRIPT_DIR"
  [ "$output" = "/usr/bin/curl" ]
}

@test "allowlist is a no-op when unset or the file is missing" {
  HOST_INTEGRITY_ALLOWLIST="$BATS_TEST_TMPDIR/nope" run bash -c 'source "$1/lib/host-integrity.sh"; printf "/usr/bin/ssh\n" | host_integrity_apply_allowlist' _ "$SCRIPT_DIR"
  [ "$output" = "/usr/bin/ssh" ]
}

@test "recent: a recently changed file whose package fails verification is reported" {
  make_dpkg_stub
  : >"$BATS_TEST_TMPDIR/scan/bad-tool"
  run host_integrity_recent 65
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified: /usr/bin/mkdir"* ]]
}

@test "recent: a recently changed file from a clean package is silent (legitimate upgrade)" {
  make_dpkg_stub
  : >"$BATS_TEST_TMPDIR/scan/good-tool"
  run host_integrity_recent 65
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recent: a recent file owned by no package is reported as unpackaged" {
  make_dpkg_stub
  : >"$BATS_TEST_TMPDIR/scan/mystery"
  run host_integrity_recent 65
  [[ "$output" == *"unpackaged: $BATS_TEST_TMPDIR/scan/mystery"* ]]
}

@test "recent: files older than the window are ignored" {
  make_dpkg_stub
  : >"$BATS_TEST_TMPDIR/scan/bad-tool"
  touch -d '3 hours ago' "$BATS_TEST_TMPDIR/scan/bad-tool"
  run host_integrity_recent 65
  [ -z "$output" ]
}

@test "recent: an unpackaged file outside the watched executable directories is not reported" {
  make_dpkg_stub
  export HOST_INTEGRITY_UNPACKAGED_RE='^/usr/(s?bin)/'
  : >"$BATS_TEST_TMPDIR/scan/mystery"
  run host_integrity_recent 65
  [ -z "$output" ]
}

@test "recent: respects the allowlist" {
  make_dpkg_stub
  : >"$BATS_TEST_TMPDIR/scan/bad-tool"
  printf '/usr/bin/mkdir\n' >"$BATS_TEST_TMPDIR/allow"
  HOST_INTEGRITY_ALLOWLIST="$BATS_TEST_TMPDIR/allow" run host_integrity_recent 65
  [ -z "$output" ]
}

@test "full: reports every mismatch found by dpkg -V, filtered" {
  cat >"$BATS_TEST_TMPDIR/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf '??5??????   /usr/bin/ssh\n??5?????? c /etc/ssh/ssh_config\n?M5??????   /usr/bin/mkdir\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/dpkg"
  run host_integrity_full
  [[ "$output" == *"modified: /usr/bin/ssh"* ]]
  [[ "$output" == *"modified: /usr/bin/mkdir"* ]]
  [[ "$output" != *"ssh_config"* ]]
}

@test "memory pressure: reads avg60 from the 'some' line" {
  printf 'some avg10=1.00 avg60=42.50 avg300=3.00 total=99\nfull avg10=0.00 avg60=9.00 avg300=0.00 total=1\n' >"$BATS_TEST_TMPDIR/psi"
  HOST_PSI_MEMORY_FILE="$BATS_TEST_TMPDIR/psi" run host_memory_pressure_avg60
  [ "$output" = "42.50" ]
}

@test "memory pressure: high when avg60 meets the threshold, not below" {
  printf 'some avg10=0.00 avg60=20.00 avg300=0.00 total=1\n' >"$BATS_TEST_TMPDIR/psi"
  HOST_PSI_MEMORY_FILE="$BATS_TEST_TMPDIR/psi" run host_memory_pressure_high 20
  [ "$status" -eq 0 ]
  HOST_PSI_MEMORY_FILE="$BATS_TEST_TMPDIR/psi" run host_memory_pressure_high 20.5
  [ "$status" -eq 1 ]
}

@test "memory pressure: a missing PSI file is not treated as high pressure" {
  HOST_PSI_MEMORY_FILE="$BATS_TEST_TMPDIR/none" run host_memory_pressure_high 20
  [ "$status" -eq 1 ]
}
