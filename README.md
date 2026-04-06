# SysMaint

SysMaint is a shell-based maintenance toolkit for administering multiple Linux systems from one management host. This repository is intentionally publishable: it contains only example inventory data, example public keys, and generic configuration snippets.

For productive use, keep real host inventories, SSH public keys, jump hosts, syslog destinations, and similar internal data outside the repository. The published code now prefers external runtime files under `/etc/sysmaint` and falls back to the in-repo examples only when no external files are present.

## What it does

- Runs updates on selected Debian, Univention, and SUSE systems.
- Rolls out a managed SSH key block while leaving manual `authorized_keys` entries outside that block untouched.
- Deploys rsyslog forwarding.
- Installs a baseline shell configuration.
- Generates local AutoFS mapping files on the management host.
- Writes console output live and also stores the latest run log and status summary.

## Repository layout

- `.Systems.sh`: example inventory with per-host feature flags
- `manage.sh`: central runner
- `lib/common.sh`: shared SSH, SCP, filtering, and logging helpers
- `tasks/update_task.sh`: update logic
- `tasks/keys_task.sh`: SSH key rollout
- `tasks/rsyslog_task.sh`: rsyslog rollout
- `tasks/shell_task.sh`: shell baseline rollout
- `tasks/autofs_task.sh`: local AutoFS file generation
- `run-*.sh`: convenience wrappers around `manage.sh`
- `scripts/`: helper scripts for checks, PR workflow, and releases
- `repository/`: example shell and editor dotfiles
  `.bash_local` is the generic shell baseline file
- `keys/`: example public key files for the key rollout
- `logs/`: runtime output directory, kept out of versioned logs by `.gitignore`

## Runtime defaults

The published repository prefers external runtime files:

- inventory: `/etc/sysmaint/.Systems.sh`
- key directory: `/etc/sysmaint/keys`
- shell repository overrides: `/etc/sysmaint/repository`

If those files do not exist, SysMaint falls back to the example files inside the repository. This keeps the Git repository publishable while making productive use safer by default.

## Quick start

```bash
chmod +x manage.sh run-*.sh tasks/*.sh
./run-update.sh full
./run-keys.sh full
./run-rsyslog.sh full
./run-shell.sh full
./run-autofs.sh full
./run-status.sh
```

To run against one exact host entry from `.Systems.sh`:

```bash
./run-update.sh --only app-01.example.net
./run-shell.sh --only 192.0.2.10
```

`--only` matches only the exact IP or DNS field from `.Systems.sh`.
Running against all matching systems now requires the explicit argument `full`.

## Configuration model

Each inventory entry carries flags that decide which task is active for that target:

- `UP`: run OS updates
- `FR`: force reboot scheduling after updates
- `BK`: include the backup public key in the managed SSH key block
- `KY`: manage SSH keys
- `RS`: deploy rsyslog forwarding
- `SH`: deploy shell baseline files
- `AF`: generate AutoFS files for the host
- `JP`: jump host for SSH and SCP access

## Change control

The repository is intended to be operated with GitHub branch protection on `main`:

- no direct unreviewed changes to `main`
- changes go through commits and pull requests
- branch history stays versioned and revertible

Operationally, that means:

1. Work in a branch.
2. Commit the change.
3. Open a pull request.
4. Review and merge.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the exact workflow.

## Workflow helpers

The repository includes small helper scripts for disciplined GitHub usage:

- `./scripts/start-branch.sh fix ssh-key-rollout`
- `./scripts/check.sh`
- `./scripts/open-pr.sh`
- `./scripts/release.sh v0.2.0 "Short release title"`
- `./scripts/update-local.sh`
- `./scripts/link-runtime-overrides.sh`

Release notes are tracked in [CHANGELOG.md](CHANGELOG.md).

When external runtime files exist, the local clone can also expose them transparently via:

- `.Systems.override.sh` -> `/etc/sysmaint/.Systems.sh`
- `keys.override` -> `/etc/sysmaint/keys`
- `repository.override` -> `/etc/sysmaint/repository`

## Sensitive data strategy

This repository is designed to stay free of infrastructure secrets and internal naming:

- `.Systems.sh` ships with example hosts only.
- `keys/*.pub` contain example public keys only.
- `logs/last_run.log` and `logs/last_run.status` are not stored in Git.
- RSyslog defaults use generic values.
- Example shell dotfiles contain no internal hostnames or private paths.

For real environments, prefer one of these approaches:

1. Keep the repository untouched and run with external files:
   `SYSTEMS_FILE=/etc/sysmaint/.Systems.sh KEY_DIR=/etc/sysmaint/keys ./run-keys.sh`
2. Replace the example files locally after clone and keep them in a private branch.
3. Maintain sensitive runtime files outside Git and deploy them separately.

## Documentation

- Installation: [INSTALL.md](INSTALL.md)
- Operations and task behavior: [OPERATIONS.md](OPERATIONS.md)
- Change and release workflow: [CONTRIBUTING.md](CONTRIBUTING.md)
- Release history: [CHANGELOG.md](CHANGELOG.md)

## Notes

- Logging supplements console output; it does not replace it.
- Reboots are queued during update runs and scheduled only after all hosts were processed.
- The SSH key task maintains exactly one backup file: `/root/.ssh/authorized_keys.bak`.
- The SSH key task replaces only the marked SysMaint block in `authorized_keys`.
- The backup key exists only on systems with `BK=1` inside the managed block.
- The AutoFS task works locally on the management host.
