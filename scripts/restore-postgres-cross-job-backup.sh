#!/usr/bin/env bash
set -euo pipefail

PG_IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
INPUT="${1:-downloaded-backup}"
WORKDIR="${RUNNER_TEMP:-/tmp}/sanogo-cross-job-restore"
DB_SECRET="$WORKDIR/db_password"

cleanup() {
  set +e
  docker rm -f backup-restore >/dev/null 2>&1 || true
  docker volume rm sanogo-backup-restore >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

test -f "$INPUT/postgres.dump"
test -f "$INPUT/expected_rows.txt"
test -f "$INPUT/backup-manifest.json"
test -f "$INPUT/SHA256SUMS.txt"

(
  cd "$INPUT"
  sha256sum -c SHA256SUMS.txt
)
echo "CROSS_JOB_ARTIFACT_INTEGRITY_RC=0"

BACKUP_SHA256="$(jq -r '.backup_sha256' "$INPUT/backup-manifest.json")"
EXPECTED_ROWS_SHA256="$(jq -r '.expected_rows_sha256' "$INPUT/backup-manifest.json")"
test "$(sha256sum "$INPUT/postgres.dump" | awk '{print $1}')" = "$BACKUP_SHA256"
test "$(sha256sum "$INPUT/expected_rows.txt" | awk '{print $1}')" = "$EXPECTED_ROWS_SHA256"

mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
openssl rand -hex 32 > "$DB_SECRET"
chmod 600 "$DB_SECRET"

docker volume create sanogo-backup-restore >/dev/null

docker run -d   --name backup-restore   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -v sanogo-backup-restore:/var/lib/postgresql/data   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE" >/dev/null

for _ in $(seq 1 90); do
  docker exec backup-restore pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec backup-restore pg_isready -U postgres >/dev/null

docker cp "$INPUT/postgres.dump" backup-restore:/tmp/postgres.dump
docker exec backup-restore pg_restore -U postgres -d postgres --clean --if-exists /tmp/postgres.dump >/dev/null

ACTUAL_ROWS="$(docker exec backup-restore psql -U postgres -qAt -F '|' -c "select id,tenant_id,marker from public.backup_probe order by id;")"
printf '%s\n' "$ACTUAL_ROWS" > "$WORKDIR/actual_rows.txt"
ACTUAL_ROWS_SHA256="$(sha256sum "$WORKDIR/actual_rows.txt" | awk '{print $1}')"

test "$ACTUAL_ROWS_SHA256" = "$EXPECTED_ROWS_SHA256"
test "$(docker exec backup-restore psql -U postgres -qAt -c "select count(*) from public.backup_probe;")" = "2"
test "$(docker exec backup-restore psql -U postgres -qAt -c "select count(distinct tenant_id) from public.backup_probe;")" = "2"

echo "CROSS_JOB_RESTORE_CONTENT_BINDING_RC=0"
echo "CROSS_JOB_RESTORE_ROW_COUNT_RC=0"
echo "CROSS_JOB_RESTORE_TENANT_DATA_RC=0"
echo "CROSS_JOB_BACKUP_RESTORE_RC=0"
