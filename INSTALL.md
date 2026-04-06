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
cp keys/old_user.pub /etc/sysmaint/keys/old_user.pub
cp keys/new_user.pub /etc/sysmaint/keys/new_user.pub
cp keys/backup.pub /etc/sysmaint/keys/backup.pub
cp repository/.bash_local /etc/sysmaint/repository/.bash_local
cp repository/.vimrc /etc/sysmaint/repository/.vimrc
vi /etc/sysmaint/keys/old_user.pub
vi /etc/sysmaint/keys/new_user.pub
vi /etc/sysmaint/keys/backup.pub
vi /etc/sysmaint/repository/.bash_local
vi /etc/sysmaint/repository/.vimrc
chmod 600 /etc/sysmaint/keys/*.pub
chmod 600 /etc/sysmaint/repository/.bash_local /etc/sysmaint/repository/.vimrc
```

## 5. Run tasks with external configuration

```bash
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-update.sh
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh KEY_DIR=/etc/sysmaint/keys ./run-keys.sh
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh TARGET_HOST=syslog.example.net ./run-rsyslog.sh
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-shell.sh
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh AUTOFS_BASEDIR=/etc/auto.master.d ./run-autofs.sh
```

## 6. Restrict host scope when needed

`--only` matches exactly the `IP` field from your inventory:

```bash
SYSTEMS_FILE=/etc/sysmaint/.Systems.sh ./run-update.sh --only app-01.example.net
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
