#!/usr/bin/env bash
set -euo pipefail

PG_IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
WORKDIR="${RUNNER_TEMP:-/tmp}/sanogo-cross-job-backup"
OUTDIR="${1:-backup-output}"
DB_SECRET="$WORKDIR/db_password"

cleanup() {
  set +e
  docker rm -f backup-source >/dev/null 2>&1 || true
  docker volume rm sanogo-backup-source >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

mkdir -p "$WORKDIR" "$OUTDIR"
chmod 700 "$WORKDIR" "$OUTDIR"
openssl rand -hex 32 > "$DB_SECRET"
chmod 600 "$DB_SECRET"

docker volume create sanogo-backup-source >/dev/null

docker run -d   --name backup-source   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -v sanogo-backup-source:/var/lib/postgresql/data   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE" >/dev/null

for _ in $(seq 1 90); do
  docker exec backup-source pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec backup-source pg_isready -U postgres >/dev/null

docker exec backup-source psql -U postgres -q -v ON_ERROR_STOP=1 -c "CREATE TABLE public.backup_probe(id integer PRIMARY KEY, tenant_id text NOT NULL, marker text NOT NULL); INSERT INTO public.backup_probe(id, tenant_id, marker) VALUES (1, 'TENANT_ALPHA', 'alpha-backup-row'), (2, 'TENANT_BETA', 'beta-backup-row');" >/dev/null
test "$(docker exec backup-source psql -U postgres -qAt -c "select count(*) from public.backup_probe;")" = "2"
echo "CROSS_JOB_SOURCE_DATA_READY_RC=0"

EXPECTED_ROWS="$(docker exec backup-source psql -U postgres -qAt -F '|' -c "select id,tenant_id,marker from public.backup_probe order by id;")"
printf '%s\n' "$EXPECTED_ROWS" > "$OUTDIR/expected_rows.txt"
EXPECTED_SHA256="$(sha256sum "$OUTDIR/expected_rows.txt" | awk '{print $1}')"

docker exec backup-source pg_dump -U postgres -Fc postgres > "$OUTDIR/postgres.dump"
test -s "$OUTDIR/postgres.dump"
BACKUP_SHA256="$(sha256sum "$OUTDIR/postgres.dump" | awk '{print $1}')"

cat > "$OUTDIR/backup-manifest.json" <<JSON
{
  "format": "pg_dump_custom",
  "database": "postgres",
  "synthetic_only": true,
  "expected_rows_sha256": "$EXPECTED_SHA256",
  "backup_sha256": "$BACKUP_SHA256",
  "postgres_image": "$PG_IMAGE"
}
JSON

(cd "$OUTDIR" && sha256sum postgres.dump expected_rows.txt backup-manifest.json > SHA256SUMS.txt)

echo "CROSS_JOB_BACKUP_CREATED_RC=0"
echo "CROSS_JOB_BACKUP_SHA256=$BACKUP_SHA256"
echo "CROSS_JOB_EXPECTED_ROWS_SHA256=$EXPECTED_SHA256"
