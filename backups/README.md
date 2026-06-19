# Paperclip instance backups (Gavin local dev)

Rolling exports for `PAPERCLIP_HOME=./data/local-dev`.

## What is tracked in git

`paperclip-local-dev/current/`:

- `database.sql` — logical dump (companies, agents, issues, goals, …)
- `config.json` — instance settings
- `manifest.json` — checksums and restore notes

**Not committed:** `secrets/master.key`, raw `db/`, timestamped `archives/`, large tarballs (by default).

Keep `data/local-dev/instances/default/secrets/master.key` backed up separately (1Password, etc.) or encrypted secrets in the DB cannot be decrypted.

## Commands

```sh
# One-off backup (local archive + update current/)
pnpm backup:instance

# Backup and git commit when current/ changed
pnpm backup:instance:commit

# macOS: install launchd job (every 6 hours, auto-commit)
./scripts/install-backup-schedule.sh
```

## Restore (manual)

1. Stop Paperclip.
2. Replace or recreate `data/local-dev/instances/default/`.
3. Restore `secrets/master.key` from your secure store if you had one.
4. Use Paperclip worktree seed / `runDatabaseRestore` path with `current/database.sql`, or ask Agent mode to wire a `db:restore` helper.
