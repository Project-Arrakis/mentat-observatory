#!/usr/bin/env bash
# lib/timeouts.sh -- bound every gh/curl call so one hung network call cannot
# stall the hourly cron (#17). Source this file; it defines wrapper functions
# that shadow the binaries for the rest of the calling script. A call that
# exceeds the limit returns 124 (like timeout(1)), which callers already treat
# as a failed call. Override with ACP_NET_TIMEOUT (seconds).

gh() { command timeout "${ACP_NET_TIMEOUT:-60}" gh "$@"; }
curl() { command timeout "${ACP_NET_TIMEOUT:-60}" curl "$@"; }
