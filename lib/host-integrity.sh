#!/usr/bin/env bash
# lib/host-integrity.sh -- detect tampering with packaged system binaries and
# early host memory pressure. Sourced by validate-and-report.sh; do not run
# directly. Nothing here modifies the system: every function only reads.
#
# WHY (INC-2026-09-29): a test helper run as root overwrote /usr/bin/{mkdir,
# ssh,curl,mountpoint} on the R740 hypervisor at 21:23. Nothing noticed; host
# memory pressure began at 21:35, the host froze at 21:39, and the game server
# was offline for about 2h16m. An hourly check of "did a system binary stop
# matching its package?" would have alerted within the hour, and the memory
# pressure warning would have fired before the freeze.
# Full writeup: Project-Arrakis/meta archive/incidents/2026-09-29-*.md
#
# Two integrity modes:
#   host_integrity_recent MINUTES  cheap, hourly: files changed in the last
#       MINUTES minutes under the scan dirs are mapped to their packages and
#       those packages are verified with `dpkg -V`; recent executables in
#       /usr/bin and /usr/sbin that no package owns are flagged too. A
#       legitimate apt upgrade changes files but verifies clean, so it is silent.
#   host_integrity_full            heavy (about a minute), daily: `dpkg -V`
#       over every package.

HOST_INTEGRITY_PATH_RE="${HOST_INTEGRITY_PATH_RE:-^/(usr/)?(s?bin|lib|lib64|libexec)/}"
HOST_INTEGRITY_SCAN_DIRS="${HOST_INTEGRITY_SCAN_DIRS:-/usr/bin /usr/sbin /usr/lib /usr/libexec}"
HOST_INTEGRITY_UNPACKAGED_RE="${HOST_INTEGRITY_UNPACKAGED_RE:-^/usr/s?bin/}"

# stdin: `dpkg -V` output. stdout: paths of mismatched or missing non-config
# files under the binary/library directories.
host_integrity_filter_dpkg_v() {
  awk -v re="$HOST_INTEGRITY_PATH_RE" '
    NF >= 2 {
      path = $NF
      attr = (NF >= 3) ? $2 : ""
      if (attr == "c") next                      # configuration file
      if ($1 == "missing" || $1 ~ /^[?.a-zA-Z0-9]{9}$/) {
        if (path ~ re) print path
      }
    }'
}

# stdin: paths. stdout: paths not listed in $HOST_INTEGRITY_ALLOWLIST (if any).
host_integrity_apply_allowlist() {
  local al="${HOST_INTEGRITY_ALLOWLIST:-}"
  if [ -n "$al" ] && [ -f "$al" ]; then
    grep -vxFf "$al" || true
  else
    cat
  fi
}

# args: MINUTES. Prints "modified: PATH" / "unpackaged: PATH" lines; silent when clean.
host_integrity_recent() {
  local minutes="${1:?minutes required}" f pkg
  local -A pkgs=()
  local -a unpackaged=() scan_dirs=()
  read -ra scan_dirs <<<"$HOST_INTEGRITY_SCAN_DIRS"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    pkg="$(dpkg -S "$f" 2>/dev/null | head -n 1 | cut -d: -f1)" || pkg=""
    if [ -n "$pkg" ]; then
      pkgs["$pkg"]=1
    elif [[ "$f" =~ $HOST_INTEGRITY_UNPACKAGED_RE ]]; then
      unpackaged+=("$f")
    fi
  done < <(find "${scan_dirs[@]}" -xdev -type f -mmin "-$minutes" 2>/dev/null)

  if [ "${#unpackaged[@]}" -gt 0 ]; then
    printf '%s\n' "${unpackaged[@]}" | host_integrity_apply_allowlist | sed 's/^/unpackaged: /'
  fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    dpkg -V "${!pkgs[@]}" 2>/dev/null | host_integrity_filter_dpkg_v | host_integrity_apply_allowlist | sed 's/^/modified: /'
  fi
  return 0
}

# Prints "modified: PATH" lines for every mismatch across all packages.
host_integrity_full() {
  dpkg -V 2>/dev/null | host_integrity_filter_dpkg_v | host_integrity_apply_allowlist | sed 's/^/modified: /'
  return 0
}

# Prints the 60-second "some" memory stall percentage, or returns 1 if PSI is unavailable.
host_memory_pressure_avg60() {
  local f="${HOST_PSI_MEMORY_FILE:-/proc/pressure/memory}"
  [ -r "$f" ] || return 1
  awk '/^some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg60=/) { sub("avg60=", "", $i); print $i } }' "$f"
}

# args: THRESHOLD (percent, default 20). Returns 0 when avg60 >= threshold; 1 otherwise or if unknown.
host_memory_pressure_high() {
  local th="${1:-20}" v
  v="$(host_memory_pressure_avg60)" || return 1
  [ -n "$v" ] || return 1
  awk -v v="$v" -v t="$th" 'BEGIN { exit !(v + 0 >= t + 0) }'
}
