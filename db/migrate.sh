#!/usr/bin/env bash
# REV-M3 — applies ``db/migrations/*.sql`` files in lexical order against
# the design_review database, idempotently, recording applied versions
# in ``public.schema_migrations``.  Invoked by process-compose's
# ``postgres-migrate`` step; can also be run by hand.
set -euo pipefail

: "${ISONIM_REVIEW_PGPORT:?ISONIM_REVIEW_PGPORT must be set}"
MIG_DIR="${ISONIM_REVIEW_MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrations}"
PSQL=(psql -h 127.0.0.1 -p "$ISONIM_REVIEW_PGPORT"
      -U design_review_migrator -d isonim_design_review
      -v ON_ERROR_STOP=1)

echo "[postgres-migrate] migrations dir: $MIG_DIR"

"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version    INT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  content_sha TEXT
)"

shopt -s nullglob
for f in "$MIG_DIR"/[0-9][0-9][0-9]_*.sql; do
  base="$(basename "$f")"
  prefix="${base%%_*}"
  # Strip leading zeros; ``10#`` arithmetic forces base-10 even for "08".
  version=$((10#$prefix))
  applied=$("${PSQL[@]}" -At -c \
    "SELECT 1 FROM public.schema_migrations WHERE version = $version")
  if [ "$applied" = "1" ]; then
    echo "[postgres-migrate] skip $base (version=$version already applied)"
    continue
  fi
  sha=$(shasum -a 256 "$f" | cut -d ' ' -f 1)
  echo "[postgres-migrate] apply $base (version=$version)"
  # Run psql with the migration file's directory as the working dir so
  # ``\i lib.sql`` in 002 resolves to db/migrations/lib.sql.
  ( cd "$MIG_DIR" && "${PSQL[@]}" -f "$base" )
  "${PSQL[@]}" -c \
    "INSERT INTO public.schema_migrations (version, content_sha) VALUES ($version, '$sha')"
done
echo "[postgres-migrate] all migrations applied"
