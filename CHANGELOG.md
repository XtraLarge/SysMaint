# Changelog

## v0.2.0 - 2026-07-03

Accumulated changes published since v0.1.0.

- Added unattended-upgrades audit/apply tooling (`run-unattended.sh` and task) to verify and reconcile automatic security-update coverage across the fleet.
- Set the unattended-upgrades policy to security-only origins to avoid conflicts with externally managed origin drop-ins.
- Added a naming-guard CI gate (on push and pull request) plus a pre-commit hook to keep internal identifiers and secrets out of the public repository.
- Hardened the naming-guard to scan only tracked files and to cover internal domains and secret assignments.
- Set an explicit secure PATH in the remote update scripts so commands resolve under minimal invocation environments.
- Added `fzf` to the shell package set and a screen-reattach convenience alias.
- Added Proxmox host support to inventory sync and staged shell alias groups.
- Split runtime defaults into a dedicated config file and removed an internal hostname from the operations documentation.

## v0.1.0 - 2026-04-06

- Initial publishable SysMaint release.
- Sanitized example inventory, keys, and dotfiles for publication.
- Added installation and operations documentation.
- Added external runtime defaults for `/etc/sysmaint`.
- Documented GitHub-based change and release workflow.
