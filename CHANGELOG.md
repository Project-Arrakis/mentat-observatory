# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (2026-10-07)

- **Accepted silent skips (`known-silent-skips.txt`).** A security job that fails *open* in a repo we do not own (an upstream project) is a real finding but not one this monitor can fix, and a plain `WARN` kept the hourly report in "issues found" indefinitely. `lib/ci-health.sh` now consults `known-silent-skips.txt` (`repo|job|tracking url|YYYY-MM-DD`): a skip that is listed and unexpired is reported as `OK` with its tracking link and is not counted as an issue; an unlisted skip still warns, and an entry stops applying the day after its expiry so the warning comes back on its own. The first entry is Red-Blink's `security-checks` job, which prints `SKIP: gitleaks is not installed.` (draft fix upstream: Red-Blink/dune-awakening-selfhost-docker#255), accepted until 2026-12-07. Operator-visible only in the hourly report; no new secret, schedule or dependency. Docs reviewed: this file and the README.

### Changed (2026-10-07)

- **Discord notifications now come from the Mentat (Sahir Venn) instead of a separate "ACP Dev Bot".** The hourly job is named **Projection** (a Mentat's forward computation of what is likely to go wrong: fork drift, CI health, stale PRs). `notify-discord.sh` now sends the webhook sender name `Sahir Venn`, the Mentat bot icon (the 256 px icon hosted in the public `mentat` repo), and a footer of `Projection · the Mentat's hourly computation` for the hourly events or `Mentat · development pipeline` for the manual `branch-created`/`pr-created` events. Per-host overrides: `NOTIFY_SENDER_NAME`, `NOTIFY_AVATAR_URL`, `NOTIFY_FOOTER_TEXT`; they reach Python through the environment and are never interpolated into code (covered by a test that tries quotes and shell syntax). Operator-visible change only: no new secret, schedule, path or dependency. The repository slug, the cron schedule and the `~/.config/acp-ops-monitor/` config directory are unchanged. Docs reviewed: this file and the README, where the claim that the deployed `notify-discord.sh` is a symlink was wrong (it is an installed copy, deployed by `install.sh`) and is corrected.

### Fixed (2026-08-21)

- **`check_ci()` used `gh run list --branch main --limit 1`, which picks whichever *workflow* happens to be chronologically newest, not necessarily the one containing the real security jobs.** Confirmed directly on `dune-awakening-selfhost-docker`: the same push triggers CI/CodeQL/Semgrep/etc, and `--limit 1` returned a CodeQL run (no security jobs at all) while the CI workflow's own `security-checks` job, run moments earlier on the same commit, was invisible to this check. Rewritten to use the commit's aggregated check-runs (`GET /repos/{repo}/commits/{ref}/check-runs`) instead, which covers every workflow's jobs for one exact commit in a single call.
- **This monitor's own CI-health check was blind to a job reporting "success" while its real work silently never ran** — exactly the bug found the same day in `dune-awakening-selfhost-docker`'s `security-checks` job (gitleaks/trivy binaries missing, script fails open, job still concludes `success`). `check_ci()` now additionally fetches the log of any successful security-related job and checks for known fail-open markers (`SKIP: <tool> is not installed`, `missing ... license`), reporting `WARN` instead of `OK` when found. Verified end-to-end against the real (still-unpatched at time of writing) `dune-awakening-selfhost-docker` main branch — correctly flags `security-checks` as silently skipped, and stays clean (`OK`) against a repo whose scanners genuinely run.
- **Repo references in `check-upstream-prs.sh` and `validate-and-report.sh` still pointed at the pre-migration `yacketrj/*` slugs** (`arrakis-control-panel`, `acp-landing`, `dune-ops-observability-addon`, `dune-docker-addons`, `dune-awakening-selfhost-docker`, `acp-ops-monitor`) instead of the current `Project-Arrakis/*` org repos. These were still resolving via GitHub's rename/transfer redirect, so nothing was actively broken, but it's fragile (redirects aren't guaranteed for every API path, and break if a new repo is ever created at the old name) — updated to the canonical names (`arrakis-control-panel`→`sentinel`, `acp-landing`→`sentinel-web`).

### Fixed (2026-08-17)

- **Divergence issue dedupe + auto-close** (#33): the diverged-fork alert
  added 2026-08-15 correctly suppressed same/shrinking-count spam, but a
  *growing* divergence still called `gh issue create` fresh every time
  instead of updating the issue already open for the same underlying,
  unreconciled divergence — confirmed in the wild as 7 separate duplicate
  open issues (#289, #297, #298, #300, #310, #312, #314) describing the
  exact same problem at different snapshots, none of which this script
  ever closed even after the divergence was actually reconciled (#279/#316).
  The state file now stores `BEHIND ISSUE_NUMBER` (space-separated,
  backward-compatible with the old single-number format) instead of just
  `BEHIND`: a growing count now comments on the tracked open issue instead
  of creating a duplicate (falling back to creating a fresh one only if no
  issue is tracked, or the tracked one was closed by someone else in the
  meantime), and the `BEHIND == 0` (resolved) path now auto-closes the
  tracked issue with a resolution comment instead of silently going green
  forever with an open issue nobody ever closes. 9 new bats tests cover the
  state-file format (old/new/empty), the reuse-vs-create branch, and the
  auto-close-on-resolve branch.

### Fixed (2026-08-15, second pass)

- **`gh issue create` crash on a nonexistent `priority:high` label**: three
  call sites in `validate-and-report.sh` (upstream release detection, PR
  conflict filing, and the new diverged-fork alert added earlier the same
  day) applied `priority:high` against `yacketrj/dune-awakening-selfhost-docker`,
  whose real label taxonomy uses `severity:*`, not `priority:*`. `gh issue
  create` fails outright on a nonexistent label, and this call wasn't
  guarded the way most others in this file are — under `set -euo
  pipefail`, this crashed the entire script the moment any of these three
  code paths were reached. Found on the very first real end-to-end run
  after installing the corrected crontab (the upstream-release-detection
  path fired immediately, since v1.3.87 was already released and unknown
  to this monitor's state cache). Fixed to `severity:high`, confirmed
  against the repo's real label list.

### Added (2026-08-15)

- **Diverged-fork threshold/alert**: `validate-and-report.sh`'s "diverged"
  branch (ahead-of-and/or-behind upstream) previously reported "OK, by
  design" forever, for any amount of divergence, with no alert. Now files
  a real GitHub issue (state-file deduped, same pattern as release
  detection) whenever the fork is genuinely behind upstream AND that
  behind-count has grown since the last report — catching real,
  unreconciled upstream work (e.g. a maintainer's follow-up fix on a PR
  this fork already got merged) instead of silently accumulating it.
  8 new bats tests.

### Fixed (2026-08-15)

- **Stale host paths**: `CORE_DIR`/`CATALOG_DIR` defaults (in both
  `validate-and-report.sh` and `install.sh`) still pointed at the original
  WSL box's directory layout (`~/projects/dune/...`); this account's repos
  now live at `~/projects/repos/...` on the current host. Both scripts'
  `set -euo pipefail` meant the entire monitor aborted immediately on
  every run since the host move — combined with no crontab ever having
  been installed on the new host either, this monitor had not actually
  run at all since the migration. Now correctly defaults to the real
  current path and still honors `ACP_CORE_DIR`/`ACP_CATALOG_DIR`
  overrides for future host moves.
- **Hardcoded `/home/darkdante/...` paths** (6 occurrences across
  `validate-and-report.sh` and `install.sh`'s printed crontab line):
  `darkdante` was the old WSL box's real username; this account runs as
  `root` on the current host. Replaced with `${HOME}` throughout, matching
  `check-upstream-prs.sh`'s own already-correct convention.
- **SC2168 shellcheck error** (`local` used outside a function) in
  `validate-and-report.sh` — a real, pre-existing error, not just a
  warning, that had been failing this repo's own CI on `main` since at
  least 2026-08-10.

### Added (2026-08-10)

- **Upstream test drift detection** in `validate-and-report.sh` (section 6b).
  Compares Core fork tests against upstream, reports new/diverged tests.
- **Dead-man's switch**: timestamp check warns if monitor hasn't run in >90 min.
- **Network timeouts**: 60s on `gh pr/release`, 30s on `gh run`, 10s on `gh auth`.
- **State pruning**: state files older than 30 days auto-deleted.
- **20 bats tests** for `validate-and-report.sh` notification logic.

### Fixed (2026-08-10)

- **Hourly "All Clear" spam**: suppressed identical clean-state notifications.
  Now only sends on transition from issues→clean.
- **Log location**: moved from world-readable `/tmp` to `~/.cache/` (mode 700).
- **State files**: moved from `/tmp` to `~/.cache/`.
- **GH_TOKEN pre-flight**: scripts exit with clear error if unauthenticated.
- **Flock locking**: prevents concurrent cron runs.
- **install.sh paths**: updated to 2026-07-25 directory layout.

### Added (2026-07-25)

- Home directory structure-lint integration in `validate-and-report.sh` (section 6).
- Failed systemd unit detection (section 5).
- CI failure detection across all 7 monitored repos.
- PR mergeability checks for Core and Catalog forks.
- Catalog fork sync with same safety guards as Core fork.
- `sync_decision()` extraction into `lib/sync-direction.sh` with bats test suite.
- Discord webhook restoration and notification infrastructure.
