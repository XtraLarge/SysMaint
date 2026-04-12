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

## Inventory format

The inventory is a Bash file containing a `HOSTNAMES` array. Header lines beginning with `!` define field names. Data lines use `#` as separator.

The standard fields are:

- `Typ`: informational host type
- `ID`: inventory ID
- `Name`: label used in output
- `IP`: exact target host or DNS name
- `BS`: operating system selector
- `UP`, `FR`, `BK`, `KY`, `RS`, `SH`, `AF`: feature flags
- `JP`: optional jump host
- `AG`: optional comma-separated alias groups for shell rollout
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

Default destination:

- `TARGET_HOST=syslog.example.net`
- `TARGET_PORT=1514`

These values should normally be supplied per run or through the environment.

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
