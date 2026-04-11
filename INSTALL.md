# Installation

## Scope

These instructions describe how to install SysMaint on a dedicated management host and keep sensitive inventory and key material outside the Git repository.

## Requirements

- Linux management host with Bash
- `ssh`, `scp`, `awk`, `sed`, `tee`, `mktemp`
- For Debian or Univention targets: `apt-get`
- For SUSE targets: `zypper`
- Root SSH access to managed targets

## 1. Clone the repository

```bash
git clone git@github.com:<your-account>/SysMaint.git
cd SysMaint
chmod +x manage.sh run-*.sh tasks/*.sh
```

## 2. Create local runtime directories

```bash
install -d -m 700 /etc/sysmaint
install -d -m 700 /etc/sysmaint/keys
install -d -m 700 /etc/sysmaint/repository
```

## 3. Provide your real inventory

Create `/etc/sysmaint/.Systems.sh` based on the example file in the repository. Keep only your real internal names, IPs, and jump hosts in that external file.

Minimal example:

```bash
cp .Systems.sh /etc/sysmaint/.Systems.sh
vi /etc/sysmaint/.Systems.sh
chmod 600 /etc/sysmaint/.Systems.sh
```

## 4. Provide your real SSH public keys

Store your productive public keys outside the repository:

```bash
install -d -m 700 /etc/sysmaint/keys/managed
cp keys/managed/*.pub /etc/sysmaint/keys/managed/
cp keys/backup.pub /etc/sysmaint/keys/backup.pub
cp repository/.bash_aliases /etc/sysmaint/repository/.bash_aliases
cp repository/.vimrc /etc/sysmaint/repository/.vimrc
vi /etc/sysmaint/keys/managed/admin-old.pub
vi /etc/sysmaint/keys/managed/admin-new.pub
vi /etc/sysmaint/keys/backup.pub
vi /etc/sysmaint/repository/.bash_aliases
vi /etc/sysmaint/repository/.vimrc
chmod 600 /etc/sysmaint/keys/managed/*.pub /etc/sysmaint/keys/backup.pub
chmod 600 /etc/sysmaint/repository/.bash_aliases /etc/sysmaint/repository/.vimrc
```

If you still use the older flat layout with `old_user.pub` and `new_user.pub`, SysMaint continues to accept it as a fallback until you move to `keys/managed/`.

## 5. Run tasks with external configuration

```bash
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-update.sh full
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-update.sh full --jobs 6
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh KEY_DIR=/etc/sysmaint/keys ./run-keys.sh full
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh TARGET_HOST=syslog.example.net ./run-rsyslog.sh full
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-shell.sh full
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh AUTOFS_BASEDIR=/etc/auto.master.d ./run-autofs.sh full
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh AUTOFS_BASEDIR=/etc/auto.master.d ./run-autofs.sh full --reset
```

## 6. Restrict host scope when needed

`only` can take multiple values and matches case-insensitively only against the exact inventory `IP` field:

```bash
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-update.sh only app-01.example.net
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-update.sh only app-01.example.net --jobs 4
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-keys.sh only 192.0.2.20 192.0.2.21
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh KEY_DIR=/etc/sysmaint/keys ./run-keys.sh only 192.0.2.20 --reset
```

## 7. Review results

```bash
./run-status.sh
less logs/last_run.log
```

## 8. Update the local installation

If the repository was cloned to `/root/SysMaint`, you can update it with:

```bash
cd /root/SysMaint
./scripts/update-local.sh
```

You can also install a small wrapper such as `/usr/local/bin/sysmaint-update` that just calls that script.

To create transparent links to the active runtime files:

```bash
cd /root/SysMaint
./scripts/link-runtime-overrides.sh
```

## Recommended Git practice

- Keep the repository content generic and publishable.
- Keep productive inventory and real key files outside the repository.
- Commit script and documentation changes normally.
- If you need audited local runtime changes, version `/etc/sysmaint` separately in another private repository or in a secure configuration management system.

## Optional runtime tuning in `/etc/sysmaint/.Systems.sh`

You can keep additional runtime defaults in the same external inventory file, for example:

```bash
DEFAULT_JOBS=8
DEFAULT_REBOOT_DELAY=1
LOCAL_REBOOT_DELAY=5

KEYS_MANAGED_DIR=/etc/sysmaint/keys/managed
BACKUP_KEY_FILE=/etc/sysmaint/keys/backup.pub

SHELL_PACKAGES_D="bash-completion vim less"
SHELL_PACKAGES_U="$SHELL_PACKAGES_D"
SHELL_PACKAGES_S="vim less"

AUTOFS_PACKAGES_D="autofs cifs-utils nfs-common sshfs"

RSYSLOG_TARGET_HOST="syslog.home.arpa"
RSYSLOG_TARGET_PORT=1514
RSYSLOG_TARGET_PROTOCOL="udp"
```

You can also add an optional `Host` field to inventory entries when reboot dependencies matter. If both a guest and its host are queued for reboot, SysMaint now suppresses the separate guest reboot and reports it as covered by the host reboot.
You can additionally use an optional `RB` field per inventory entry to set a reboot delay in minutes. Without `RB`, SysMaint uses `DEFAULT_REBOOT_DELAY`, except for the currently running management system and its host chain, which use `LOCAL_REBOOT_DELAY`.
