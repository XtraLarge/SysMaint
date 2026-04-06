# Contributing And Release Workflow

## Goal

Every usable state must exist as a committed and recoverable Git version. Changes should not land on `main` without traceability.

## Working rules

1. Do not edit `main` directly.
2. Create a topic branch for every change.
3. Commit with a clear message.
4. Open a pull request into `main`.
5. Review the diff before merge.
6. Merge only when the branch represents a usable state.

## Recommended branch names

- `feature/<topic>`
- `fix/<topic>`
- `docs/<topic>`
- `ops/<topic>`

## Minimum release standard

Before merging to `main`:

- shell syntax checks pass for changed scripts
- documentation reflects the new behavior
- no productive inventory, keys, logs, or internal names are added to Git
- the branch can be checked out and used as a coherent state

## Practical commands

Create a branch:

```bash
./scripts/start-branch.sh fix ssh-key-rollout
```

Run checks:

```bash
./scripts/check.sh
```

Commit changes:

```bash
git add <files>
git commit -m "Fix managed SSH key block handling"
```

Push the branch and open a pull request:

```bash
./scripts/open-pr.sh
```

## Protected main branch

`main` should be protected in GitHub with rules similar to these:

- require pull requests before merging
- require at least one approval
- dismiss stale approvals on new pushes
- require conversation resolution before merge
- block force-pushes
- block branch deletion

Those rules prevent undocumented direct changes and preserve a clean, revertible version history.

## Releases

Every release should point to a usable state on `main`.

Create a release tag and update the changelog with:

```bash
./scripts/release.sh v0.2.0 "Short release summary"
```

That script:

1. verifies that you are on `main`
2. pulls the latest `main`
3. runs repository checks
4. updates `CHANGELOG.md`
5. creates a release commit
6. creates an annotated tag
7. pushes the commit and tag to GitHub

## Updating an installed copy

For a production-style clone on the management host:

```bash
cd /root/SysMaint
./scripts/update-local.sh
```

The update script requires:

- clean working tree
- current branch is `main`
- fast-forward update from `origin/main`

It also refreshes transparent runtime links when `/etc/sysmaint` is present:

- `.Systems.override.sh`
- `keys.override`
- `repository.override`
