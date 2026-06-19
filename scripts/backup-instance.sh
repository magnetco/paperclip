#!/usr/bin/env bash
set -euo pipefail

# Backup a Paperclip instance (DB + config + optional file bundles).
#
# Usage:
#   ./scripts/backup-instance.sh
#   ./scripts/backup-instance.sh --commit
#   PAPERCLIP_HOME=./data/local-dev ./scripts/backup-instance.sh --commit
#
# Rolling export (git-trackable): backups/paperclip-local-dev/current/
# Full archives (local only):     backups/paperclip-local-dev/archives/<timestamp>/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DATA_DIR="${PAPERCLIP_HOME:-$PROJECT_ROOT/data/local-dev}"
INSTANCE_ID="${PAPERCLIP_INSTANCE_ID:-default}"
DO_COMMIT=false
FILENAME_PREFIX="paperclip"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)
      DO_COMMIT=true
      shift
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --instance)
      INSTANCE_ID="$2"
      shift 2
      ;;
    --prefix)
      FILENAME_PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

DATA_DIR="$(cd "$DATA_DIR" 2>/dev/null && pwd || echo "$(cd "$PROJECT_ROOT" && pwd)/${DATA_DIR#./}")"
INSTANCE_ROOT="$DATA_DIR/instances/$INSTANCE_ID"
BACKUP_ROOT="$PROJECT_ROOT/backups/paperclip-local-dev"
ARCHIVE_DIR="$BACKUP_ROOT/archives/$(date +%Y%m%d-%H%M%S)"
CURRENT_DIR="$BACKUP_ROOT/current"

if [[ ! -d "$INSTANCE_ROOT" ]]; then
  echo "Instance not found: $INSTANCE_ROOT" >&2
  echo "Start Paperclip once with PAPERCLIP_HOME=$DATA_DIR or pass --data-dir." >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR" "$CURRENT_DIR"

export PAPERCLIP_HOME="$DATA_DIR"
export PAPERCLIP_INSTANCE_ID="$INSTANCE_ID"

cd "$PROJECT_ROOT"

echo "[backup] instance: $INSTANCE_ROOT"
echo "[backup] archive:  $ARCHIVE_DIR"

# Logical SQL dump via Paperclip CLI.
pnpm paperclipai db:backup \
  --data-dir "$DATA_DIR" \
  --dir "$ARCHIVE_DIR" \
  --filename-prefix "$FILENAME_PREFIX" >/dev/null

SQL_FILE="$(ls -t "$ARCHIVE_DIR"/${FILENAME_PREFIX}-*.sql 2>/dev/null | head -1)"
if [[ -z "$SQL_FILE" || ! -f "$SQL_FILE" ]]; then
  echo "[backup] database dump failed — is Paperclip running?" >&2
  exit 1
fi

cp "$SQL_FILE" "$ARCHIVE_DIR/database.sql"
cp "$SQL_FILE" "$CURRENT_DIR/database.sql"

# Instance config (no master key).
if [[ -f "$INSTANCE_ROOT/config.json" ]]; then
  cp "$INSTANCE_ROOT/config.json" "$ARCHIVE_DIR/config.json"
  cp "$INSTANCE_ROOT/config.json" "$CURRENT_DIR/config.json"
fi

# Optional file bundles for full restore without re-uploading attachments.
for bundle in storage workspaces projects; do
  src="$INSTANCE_ROOT"
  case "$bundle" in
    storage) src="$INSTANCE_ROOT/data/storage" ;;
    workspaces) src="$INSTANCE_ROOT/workspaces" ;;
    projects) src="$INSTANCE_ROOT/projects" ;;
  esac
  if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null || true)" ]]; then
    tar -czf "$ARCHIVE_DIR/${bundle}.tar.gz" -C "$(dirname "$src")" "$(basename "$src")"
    cp "$ARCHIVE_DIR/${bundle}.tar.gz" "$CURRENT_DIR/${bundle}.tar.gz"
  fi
done

# Manifest for restore instructions (never includes secrets).
node --input-type=module -e "
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, statSync, existsSync } from 'node:fs';
import { basename } from 'node:path';

const archiveDir = process.argv[1];
const currentDir = process.argv[2];
const instanceRoot = process.argv[3];

function sha256(file) {
  if (!existsSync(file)) return null;
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

const files = ['database.sql', 'config.json', 'storage.tar.gz', 'workspaces.tar.gz', 'projects.tar.gz'];
const manifest = {
  createdAt: new Date().toISOString(),
  instanceRoot,
  paperclipVersion: null,
  files: Object.fromEntries(
    files.map((name) => {
      const path = archiveDir + '/' + name;
      if (!existsSync(path)) return [name, null];
      const stat = statSync(path);
      return [name, { bytes: stat.size, sha256: sha256(path) }];
    }),
  ),
  restoreNotes: [
    'database.sql restores companies, agents, issues, goals, comments, and metadata',
    'secrets/master.key is NOT backed up here — keep a separate copy or secrets are unrecoverable',
    'Optional *.tar.gz bundles restore uploads and agent workspaces',
  ],
};

for (const dir of [archiveDir, currentDir]) {
  writeFileSync(dir + '/manifest.json', JSON.stringify(manifest, null, 2) + '\n');
}
" "$ARCHIVE_DIR" "$CURRENT_DIR" "$INSTANCE_ROOT"

echo "[backup] current export: $CURRENT_DIR"
ls -lh "$CURRENT_DIR"

if [[ "$DO_COMMIT" == "true" ]]; then
  if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[backup] not a git repo; skipping commit" >&2
    exit 0
  fi

  git -C "$PROJECT_ROOT" add backups/.gitignore backups/paperclip-local-dev/current/
  if git -C "$PROJECT_ROOT" diff --cached --quiet; then
    echo "[backup] no changes to commit"
  else
    git -C "$PROJECT_ROOT" commit -m "$(cat <<EOF
chore(backup): snapshot paperclip instance data

Automated export from $DATA_DIR (instance: $INSTANCE_ID).
Secrets/master.key are excluded.
EOF
)"
    echo "[backup] committed rolling export"
  fi
fi
