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
git checkout -b fix/ssh-key-rollout
```

Commit changes:

```bash
git add <files>
git commit -m "Fix managed SSH key block handling"
```

Push the branch:

```bash
git push -u origin fix/ssh-key-rollout
```

Create a pull request:

```bash
gh pr create --fill
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
