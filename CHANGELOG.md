# Changelog

## v0.3.0 - 2026-08-29

- Fixed SSH `BatchMode` keyword error and race condition in `finish_parallel_job` when `JOBS > 1` — result file was missing for some parallel update tasks (#2611).
- Set `global(localHostname)` in rsyslog configuration to prevent DNS casing variance in Loki log indexing.
- Added `UU_KNOWN_SURP_HOSTS` configuration variable: surplus-only origins on listed hosts are now reported as `KNOWN-ACCEPTED` (`origins=known-surp<N>`) instead of `GAP/drift`, eliminating audit noise for hosts where `apply` is intentionally blocked (e.g. after a Policy-B→A rollback). Hosts with a genuinely missing origin (`miss>0`) are still reported as `GAP` regardless of the list.
- Separated unreachable-host status from audit-failure: hosts that cannot be reached over SSH are now classified as `UNREACHABLE` instead of being grouped with genuine audit errors (#1783, #1837).
- Hardened SSH connection options: added keepalive, hard connection timeout, and repaired broken `SSH_OPTS_BASE` parsing (#11).

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
