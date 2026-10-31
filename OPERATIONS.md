# Operations

## Central execution model

`manage.sh` is the single runner. Every wrapper calls it with one flag and one task script:

- `run-update.sh` -> `UP`
- `run-keys.sh` -> `KY`
- `run-rsyslog.sh` -> `RS`
- `run-shell.sh` -> `SH`
- `run-autofs.sh` -> `AF`

For each entry in `.Systems.sh`, `manage.sh`:

1. Parses one host line.
2. Applies `--only` if present.
3. Checks whether the requested flag is enabled on that host.
4. Exports the parsed fields as environment variables.
5. Executes the selected task script once for that host.
6. Writes both live console output and `logs/last_run.*`.

`run-proxmox.sh` is separate from `manage.sh`. It updates `.Systems.sh` from the current guest inventory on the configured Proxmox hosts.

Runtime-wide defaults such as package sets, rsyslog target, key paths, and job counts live in `config.sh` or `/etc/sysmaint/config.sh`.

## Inventory format

The inventory is a Bash file containing a `HOSTNAMES` array. Header lines beginning with `!` define field names. Data lines use `#` as separator.

The standard fields are:

- `Typ`: informational host type
- `ID`: inventory ID
- `Name`: label used in output
- `IP`: exact target host or DNS name
- `BS`: operating system selector
  `P` marks a Proxmox host and is operationally handled like Debian by the update and shell package logic.
- `UP`, `FR`, `BK`, `KY`, `RS`, `SH`, `AF`: feature flags
- `JP`: optional jump host
- `SG`: optional comma-separated shell groups for shell rollout
- `Host`: optional parent host for reboot dependency handling
- `RB`: optional reboot delay in minutes

## SSH behavior

Shared SSH logic lives in `lib/common.sh`.

- `SSH_USER` defaults to `root`.
- SSH options are built centrally and handled as arrays.
- If `JP` is set, SSH and SCP use that host as jump host.
- `remove_known_host` clears old host keys before update runs.
- `SSH_OPTS_BASE` includes `ServerAliveInterval=15` / `ServerAliveCountMax=4` so dead established sessions are detected in ~60s.
- Every SSH/SCP call runs under a hard `timeout` cap (`SSH_CMD_TIMEOUT`, default 1800s; prechecks `SSH_PRECHECK_TIMEOUT`, default 60s) to bound banner-exchange hangs where keepalive does not apply. Set to `0` to disable.

## Update task

`tasks/update_task.sh` supports:

- Debian
- Univention
- SUSE

Behavior:

- Installs required helper packages.
- Runs the platform-specific update flow.
- Checks whether a reboot is required.
- Queues reboots instead of triggering them immediately.
- Schedules queued reboots only after all hosts were processed.

## SSH key task

`tasks/keys_task.sh` builds the desired managed key set from:

- `keys/old_user.pub`
- `keys/new_user.pub`
- optionally `keys/backup.pub` when `BK=1`

On the target host it:

- creates `/root/.ssh` if needed
- keeps one backup in `/root/.ssh/authorized_keys.bak`
- replaces only the block between `# BEGIN SYSMAINT MANAGED KEYS` and `# END SYSMAINT MANAGED KEYS`

Manual entries outside that block remain untouched.

## RSyslog task

`tasks/rsyslog_task.sh` writes a forwarding configuration, validates rsyslog if available, enables the service, and restarts it.

The destination comes from runtime configuration, normally `/etc/sysmaint/config.sh` on the management host.

Published example defaults:

- `TARGET_HOST=syslog.example.net`
- `TARGET_PORT=1514`

Productive runtime overrides these in local `config.sh` (kept out of this repo):

- `RSYSLOG_TARGET_HOST=<your-syslog-host>`
- `RSYSLOG_TARGET_PORT=1514`
- `RSYSLOG_TARGET_PROTOCOL=udp`

Operational rule:

- Test the task on one host first with `./run-rsyslog.sh only <ip-or-dns>`.
- Then run `./run-rsyslog.sh full`.
- Leave `RS=0` on systems that are currently stopped or not reachable, instead of carrying them as recurring failures in the full run.

## Shell task

`tasks/shell_task.sh` installs a minimal baseline:

- packages like `bash-completion`, `vim`, `less`
- `de_DE.UTF-8` locale
- aliases from `repository/aliases/` in the order `base_*`, `group_*`, `host_*`
- `/root/.vimrc` when missing
- sourcing of `/root/.bash_aliases`

If no alias directory exists, the shell task falls back to the older single-file baseline `repository/.bash_local`.

## AutoFS task

`tasks/autofs_task.sh` runs locally on the management host.

It creates:

- one master file per host under `AUTOFS_BASEDIR`
- one example map file per filesystem under `AUTOFS_BASEDIR/maps`

It only creates missing files and does not overwrite existing files.
If new files were created, it reloads or restarts the local `autofs` service so the new definitions become active.
For `sshfs` example maps, a configured `JP` value is translated into an `ssh_command` with `ProxyJump`.
With `--reset`, it removes the selected hosts' generated `.autofs` and `.map` files first and then recreates them.

## Unattended-upgrades audit and apply

`tasks/unattended_task.sh` checks and (opt-in) repairs the Debian
`unattended-upgrades` automation fleet-wide. It runs through `manage.sh` under
the existing `UP` flag (same host set as the manual update run: `BS=D/P` and
`UP=1`); no separate inventory column is used. The task additionally self-gates
on `BS=D/P`. Convenience wrapper: `run-unattended.sh`.

Modes:

- AUDIT (default, read-only): per host it checks whether `unattended-upgrades`
  is installed, whether `/etc/apt/apt.conf.d/20auto-upgrades` enables the two
  `APT::Periodic` keys, whether the effective `Origins-Pattern` set covers the
  policy canon, whether the auto-restart key is left off, whether
  `apt-daily.timer` and `apt-daily-upgrade.timer` are enabled and active, and
  the age of the `unattended-upgrades-stamp` (freshness, `never` = it never
  ran). A compact status table (OK / GAP + which pieces are missing / ERROR for
  unreachable hosts / SKIP for non-Debian) is printed at the end.
- APPLY (`--apply`, opt-in, changing): missing pieces are reconciled
  idempotently. Already-correct hosts stay completely untouched (every step is
  guarded by a prior check). Steps: install `unattended-upgrades` if missing;
  write the canonical `20auto-upgrades`; if the origins drift, deploy the
  managed drop-in `52sysmaint-unattended-origins.conf` (additive); enable the
  timers; finally validate the config with a read-only dry run.

Examples:

```
./run-unattended.sh                              # AUDIT all UP=1 Debian hosts
./run-unattended.sh audit only host-a host-b     # AUDIT selected hosts
./run-unattended.sh apply only host-a            # APPLY to one host
```

Policy parameter (security-only vs. all updates):

- The `Origins-Pattern` canon lives as a single clearly marked block in
  `tasks/unattended_task.sh` (`CANON_ORIGINS`, with the `NON_SECURITY_ORIGIN`
  toggle line). It is the only source of truth for both the audit comparison
  and the apply write.
- Keeping the `NON_SECURITY_ORIGIN` line = all Debian updates. Commenting it
  out = security-only. This is a one-line change; no other code is affected.
- The drop-in only adds missing canon origins, it never removes extra ones; a
  policy downgrade therefore needs the drop-in removed manually.

Operational rules:

- AUDIT is read-only and safe to run any time.
- APPLY enables timers and self-running patching = lasting effect. Roll APPLY
  out to more than a single test host only after explicit approval. Default
  stays AUDIT; `--apply` is always explicit.

## Weekly run and verification

`run-weekly.sh` runs every SysMaint task once in a fixed order and keeps a
dated log directory per run (`logs/weekly/<run>/`, the last 8 are kept):

1. `inventory`  `tools/sync-proxmox.sh --report` - compare the inventory with
   all Proxmox hosts (`BS=P`). New guests are analysed (OS via SSH) and added
   with fitting flags, migrated guests get their `Host` field updated. Gone
   guests, name and IP drift are only reported, never removed. Stopped guests
   are reported and later skipped. If the inventory directory is a Git
   repository, every change is committed there instead of writing `.bak` files.
2. `monitoring` `tools/compare-monitoring.py` - compare active inventory hosts
   with the monitoring hosts (`ICINGA_QUERY_CMD hosts`).
3. `keys`, `shell`, `rsyslog`, `autofs`, `unattended` (audit only).
4. `update` last, so that queued reboots happen after everything else.

`tools/weekly-summary.py` classifies the results (errors, warnings, info;
stopped guests and known exceptions are not errors), writes
`<run>/summary.txt` and `logs/last_weekly.status`, and `tools/send-report.py`
mails the summary through the local MTA (`REPORT_MAIL_TO`, no credentials).

`run-verify.sh` (some hours later, after the reboots) checks without changing
anything: SSH reachability, completed reboot, pending reboot, managed key
block, fresh syslog data per host in Loki (`LOKI_URL`, proves the rsyslog
forwarding), critical log entries since the run started, open hard monitoring
problems, and backup coverage: every running guest in an active vzdump/PBS
job, every disk with `backup=0` belongs to a host in BackupPC, physical hosts
in BackupPC, every BackupPC host monitored via `backuppc_hostname`, and a hint
on possible double backups. Backup freshness stays with the monitoring checks.

Known exceptions come from `EXCEPTIONS_CMD` (lines `HOST|CHECK|SINCE|REASON`,
host globs allowed, check `*` or `backup` for both backup checks). The source
of truth is kept outside this repository.

`tools/check_sysmaint_weekly` is a Nagios/Icinga plugin reading both status
files (WARNING/CRITICAL on findings or when a run is older than 8/15 days).
`contrib/systemd/` holds the timer units, `contrib/icinga-query.sh` a read-only
helper for the Icinga API that keeps the API password inside the container.

All environment-specific values live in the runtime config only:
`REPORT_MAIL_TO`, `REPORT_MAIL_FROM`, `WEEKLY_JOBS`, `LOKI_URL`,
`ICINGA_QUERY_CMD`, `BACKUPPC_HOSTS_CMD`, `EXCEPTIONS_CMD`.

`run_ssh` in `lib/common.sh` now runs with stdin detached: it is called inside
`while read` loops, where ssh used to swallow the rest of the loop input (the
old Proxmox sync therefore only ever found the first new guest).

## Repository checks and pre-commit guard

`scripts/check.sh` is the authoritative guard: it runs `bash -n` on the shell
scripts plus a naming-guard grep against internal network/host values (private
IP ranges, internal local domains, SSH keys, internal names). A hit turns the
run red and prevents internal values from reaching this public repository.

Two layers enforce it:

- CI gate: `.github/workflows/ci.yml` runs `scripts/check.sh` on every push and
  on pull requests to `main`. This is authoritative.
- Local pre-commit guard: `.git/hooks/pre-commit` runs `scripts/check.sh`
  before each commit as a pre-push safety net. It is installed idempotently by
  `scripts/link-runtime-overrides.sh` (which `scripts/update-local.sh` also
  calls), so it is restored after a fresh clone or a hooks reset. See INSTALL.md
  ("Enable the local pre-commit guard") for manual installation.
