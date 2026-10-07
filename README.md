# ACP Ops Monitor

Hourly cron jobs for monitoring the Dune Awakening ACP ecosystem: upstream PR
tracking, fork sync (with a hard safety guard against destructive resets),
CI validation, and Discord notifications.

## Monitored Repos

| Repo | Role | Checked by |
|---|---|---|
| `Red-Blink/dune-awakening-selfhost-docker` | Upstream Core | fork-sync source of truth |
| `yacketrj/dune-awakening-selfhost-docker` | Core fork | sync, PR mergeability, CI status |
| `Red-Blink/dune-docker-addons` | Upstream Catalog | PR mergeability |
| `yacketrj/dune-docker-addons` | Catalog fork | fork sync, CI status |
| `yacketrj/dune-ops-observability-addon` | Addon | PR tracking, CI status |
| `yacketrj/Arrakis-Control-Panel` | Discord bot (formerly `dune-awakening-selfhost-discordbot`) | PR tracking, CI status |
| `yacketrj/acp-landing` | Landing site | PR tracking, CI status |

## Scripts

| Script | Purpose |
|--------|---------|
| `check-upstream-prs.sh` | Track PRs across repos, notify on merges; also tracks real upstream release tags on `Red-Blink/*` repos and notifies once when a new tag first appears (added 2026-07-25, closing a real gap where an upstream release went undetected by this monitor and was only found manually during unrelated work) |
| `validate-and-report.sh` | Fork sync, rebase, mergeability, CI validation, and failed-systemd-unit detection (added 2026-07-25, closing a real gap where `dune-awakening-db-backup.service` had been silently failing daily since at least 2026-07-23 and was only found via manual `systemctl --failed` audit) |
| `notify-discord.sh` | Post events to Discord webhook. Messages appear as the Mentat (Sahir Venn) and the hourly job is called **Projection**; sender, avatar and footer are overridable with `NOTIFY_SENDER_NAME`, `NOTIFY_AVATAR_URL` and `NOTIFY_FOOTER_TEXT`. `~/.local/bin/notify-discord.sh` (what `validate-and-report.sh`'s `$NOTIFY` actually invokes) is an installed **copy**, not a symlink (corrected 2026-10-07; this line used to say symlink): edit here, then re-run `install.sh` to deploy it, and never edit the deployed path directly. |

## State Caches

Both PR tracking and release-tag tracking are stateful (diff-based, to notify only on real transitions, never on every hourly run):

- `~/.cache/acp-pr-states.json` — last-seen status per repo+PR-number
- `~/.cache/acp-upstream-release-states.json` — last-seen latest release tag per upstream repo (only `Red-Blink/*` repos are checked here; `yacketrj/*` repos aren't forks and have no separate "upstream release" concept beyond their own PR-merge tracking above)

Deleting a cache file resets its baseline — the next run will silently re-establish a baseline without notifying (by design, so a fresh deploy of this monitor doesn't fire a false "new" notification for every pre-existing PR/release).

## Host-Level Monitoring

`validate-and-report.sh` also checks `systemctl --failed` on every run (not stateful/diff-based like the PR/release trackers above — reports every run while any unit remains failed, since a stuck-failed unit is a persistent problem worth repeating until fixed). This covers real systemd services/timers this project depends on running on this host, notably:

- `discord-bot.service` — the live Arrakis Control Panel Discord bot (`Restart=always`)
- `dune-awakening-db-backup.timer` / `.service` — daily game-server database backup

## Secrets

- `~/.config/acp-ops-monitor/dev-webhook-url.txt` — Discord webhook URL for `notify-discord.sh` (or set `DISCORD_DEV_WEBHOOK_URL` instead). Chosen deliberately as a stable, non-project location: an earlier version of this file lived inside a project working directory that was later deleted during an unrelated cleanup, silently breaking all Discord notifications until found and fixed (2026-07-25). Not committed to git (gitignored).

## Setup

```bash
git clone https://github.com/yacketrj/acp-ops-monitor.git ~/acp-ops-monitor
bash ~/acp-ops-monitor/install.sh
```

`install.sh` checks for `git`/`gh`/`bash`, verifies `gh auth status`,
installs `notify-discord.sh` to `~/.local/bin`, checks that the core fork
clone exists with an `upstream` remote configured, and prints the crontab
line to add. It does **not** modify your crontab automatically — paste the
printed line into `crontab -e` yourself after reviewing it.

### Prerequisites

- `git`, `gh` (authenticated: `gh auth login`), `bash`
- A local clone of the core fork with both `origin` and `upstream` remotes
  configured, at `~/projects/repos/dune-awakening-selfhost-docker` (override
  with `ACP_CORE_DIR` if your clone lives elsewhere — this default is this
  account's own current path, not a portable assumption; it has already
  drifted twice as repos moved between hosts, see CHANGELOG's 2026-08-15
  entry)
- Optionally, a local clone of the catalog fork at
  `~/projects/repos/dune-docker-addons` (override with `ACP_CATALOG_DIR`;
  `validate-and-report.sh` skips this check gracefully if absent)
- A Discord webhook URL, provided via the `DISCORD_DEV_WEBHOOK_URL`
  environment variable (**cron does not read your shell's rc files** — set
  this directly in the crontab entry, as `install.sh` prints)

## Cron

Runs hourly. `install.sh` prints the exact line for your machine; it looks
like:

```crontab
DISCORD_DEV_WEBHOOK_URL=https://discord.com/api/webhooks/REDACTED
0 * * * * bash ~/acp-ops-monitor/check-upstream-prs.sh >> /tmp/acp-cron.log 2>&1; bash ~/acp-ops-monitor/validate-and-report.sh >> /tmp/acp-cron.log 2>&1
```

## Testing & Linting

Shell logic that decides whether to run a destructive git operation
(`git reset --hard` + force-push) is extracted into `lib/sync-direction.sh`
and covered by a [bats](https://github.com/bats-core/bats-core) test suite:

```bash
sudo apt-get install -y bats   # or: brew install bats-core
bats tests/
```

Shell scripts are linted with [ShellCheck](https://www.shellcheck.net/),
GitHub Actions workflows are linted with
[actionlint](https://github.com/rhysd/actionlint), and markdown docs are
linted with
[markdownlint-cli2](https://github.com/DavidAnson/markdownlint-cli2)
(config: `.markdownlint-cli2.jsonc` — line-length and table-pipe-spacing
rules are intentionally disabled since this repo's docs use long descriptive
prose rather than hard-wrapped columns; everything else, including
fenced-code-language and blanks-around-fences checks, stays enforced):

```bash
shellcheck *.sh lib/*.sh
actionlint .github/workflows/*.yml
npx --yes markdownlint-cli2@0.23.1 "**/*.md"
```

CI runs the full test and lint suite automatically on every push/PR (see
`.github/workflows/ci.yml`); `.pre-commit-config.yaml` runs the same checks
locally for parity.

## Incident History

On 2026-07-22, the fork-sync logic in `validate-and-report.sh` triggered a
`git reset --hard upstream/main` + force-push against the core fork's `main`
branch **three separate times in one day**, each time discarding a PR that
had just been merged (`#103`, `#104`, `#108`). The root cause: the original
condition only checked whether `upstream/main`'s SHA differed from
`origin/main`'s SHA — it did not check *direction*. That check fires
identically whether the fork is genuinely behind upstream, genuinely ahead
(has fork-local merged work upstream doesn't have yet), or has diverged.
Combined with an unconditional reset+force-push, any state other than
"already in sync" that wasn't "purely behind" got silently destroyed.

Fixed in PR [#7](https://github.com/yacketrj/acp-ops-monitor/pull/7) by
computing both `ahead` and `behind` commit counts and only treating the
"purely behind, nothing of its own to lose" case as sync-eligible. That fix
initially lived only as an inline comment next to duplicated logic in two
places (core fork sync, catalog fork sync) with no test coverage of its own
— the same class of bug could have been silently reintroduced by any future
edit. This was subsequently extracted into `lib/sync-direction.sh` with a
dedicated `bats` regression suite (`tests/sync-direction.bats`) that
explicitly reproduces the incident scenario (fork ahead by exactly one
merged commit, upstream unchanged) as a permanent test case.

## Compliance & Security Docs

- [`compliance/README.md`](compliance/README.md) — SOC 2 control tracking status for this repo
- [`docs/security-checklist.md`](docs/security-checklist.md) — pre-submission security checklist template, adapted for this ecosystem's Discord bot/adapter work
