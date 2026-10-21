#!/usr/bin/env bash
# lib/timeouts.sh -- bound network calls so one hung call cannot stall the
# hourly cron while it holds the flock (#17, #56). Source this file; it defines
# wrapper functions that shadow the binaries for the rest of the calling script.
#
# Scope (be precise): this covers bare `gh ...` and `curl ...` calls and `git`
# network subcommands (fetch/push/pull/ls-remote/clone) made from the sourcing
# shell. It does NOT reach (a) calls already written as `timeout N gh ...`
# (those keep their own, explicit limits and ignore ACP_NET_TIMEOUT), or (b)
# child processes: notify-discord.sh runs as its own process and sets
# `curl --max-time` itself.
#
# A timed-out call returns 124 (timeout(1)). Callers written as
# `... || true` / `|| echo ""` treat 124 like any other failure, i.e. as an
# empty result; that is the existing fail-open convention, not new behaviour.
# `-k 5` sends SIGKILL if the process ignores SIGTERM.

gh() { command timeout -k 5 "${ACP_NET_TIMEOUT:-60}" gh "$@"; }
curl() { command timeout -k 5 "${ACP_NET_TIMEOUT:-60}" curl "$@"; }
git() {
  case "${1:-}" in
    fetch|push|pull|ls-remote|clone)
      command timeout -k 5 "${ACP_GIT_TIMEOUT:-120}" git "$@" ;;
    *) command git "$@" ;;
  esac
}
