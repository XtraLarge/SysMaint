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
