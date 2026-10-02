#!/usr/bin/env bash
set -euo pipefail

PG_IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
NET="sanogo-db-ha-pitr"
WORKDIR="${RUNNER_TEMP:-/tmp}/sanogo-db-ha-pitr"
DB_SECRET="$WORKDIR/db_password"
REPL_SECRET="$WORKDIR/repl_password"
PGPASS_DB="$WORKDIR/pgpass_db"
PGPASS_REPL="$WORKDIR/pgpass_repl"

cleanup() {
  set +e
  for c in ha-primary ha-standby pitr-primary pitr-restore; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm sanogo-ha-primary sanogo-ha-standby sanogo-pitr-primary sanogo-pitr-base sanogo-pitr-archive sanogo-pitr-restore >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

wait_pg() {
  local container="$1"
  for _ in $(seq 1 90); do
    if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become ready: $container" >&2
  return 1
}

mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
openssl rand -hex 32 > "$DB_SECRET"
openssl rand -hex 32 > "$REPL_SECRET"
chmod 600 "$DB_SECRET" "$REPL_SECRET"
DB_PASS="$(cat "$DB_SECRET")"
REPL_PASS="$(cat "$REPL_SECRET")"
printf '*:*:*:postgres:%s\n' "$DB_PASS" > "$PGPASS_DB"
printf 'ha-primary:*:*:replicator:%s\n' "$REPL_PASS" > "$PGPASS_REPL"
chmod 600 "$PGPASS_DB" "$PGPASS_REPL"

docker network create --internal "$NET" >/dev/null
docker volume create sanogo-ha-primary >/dev/null
docker volume create sanogo-ha-standby >/dev/null
docker volume create sanogo-pitr-primary >/dev/null
docker volume create sanogo-pitr-base >/dev/null
docker volume create sanogo-pitr-archive >/dev/null

echo "=== HA: start primary ==="
docker run -d   --name ha-primary   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256"   -v sanogo-ha-primary:/var/lib/postgresql/data   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres     -c wal_level=replica     -c max_wal_senders=5     -c max_replication_slots=5     -c hot_standby=on     -c wal_keep_size=64MB     -c password_encryption=scram-sha-256   >/dev/null

wait_pg ha-primary

docker exec -i ha-primary psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';
SQL

docker exec ha-primary sh -ceu '
  printf "%s\n" "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
'
docker exec ha-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_reload_conf();" >/dev/null

echo "=== HA: clone standby from primary ==="
docker run --rm   --network "$NET"   --user postgres   -e PGPASSFILE=/run/secrets/pgpass   -v sanogo-ha-standby:/var/lib/postgresql/data   -v "$PGPASS_REPL:/run/secrets/pgpass:ro"   "$PG_IMAGE"   pg_basebackup     -h ha-primary     -U replicator     -D /var/lib/postgresql/data     -Fp -Xs -P -R   >/dev/null

docker run --rm   --user postgres   -v sanogo-ha-standby:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu '
    printf "%s\n" "primary_conninfo = '''host=ha-primary user=replicator passfile=/run/secrets/pgpass'''" >> /var/lib/postgresql/data/postgresql.auto.conf
  '

docker run -d   --name ha-standby   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -v sanogo-ha-standby:/var/lib/postgresql/data   -v "$PGPASS_REPL:/run/secrets/pgpass:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres -c hot_standby=on   >/dev/null

wait_pg ha-standby

for _ in $(seq 1 60); do
  STATE="$(docker exec ha-primary psql -U postgres -Atqc "select coalesce(max(state),'') from pg_stat_replication;" || true)"
  if [ "$STATE" = "streaming" ]; then break; fi
  sleep 1
done
test "$STATE" = "streaming"
echo "HA_STREAMING_REPLICATION_RC=0"

docker exec ha-primary psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS ha_probe(id integer primary key, marker text not null);
INSERT INTO ha_probe VALUES (1,'before-failover') ON CONFLICT (id) DO UPDATE SET marker=excluded.marker;
SQL

for _ in $(seq 1 60); do
  MARKER="$(docker exec ha-standby psql -U postgres -Atqc "select marker from ha_probe where id=1;" 2>/dev/null || true)"
  if [ "$MARKER" = "before-failover" ]; then break; fi
  sleep 1
done
test "$MARKER" = "before-failover"
RECOVERY="$(docker exec ha-standby psql -U postgres -Atqc "select pg_is_in_recovery();")"
test "$RECOVERY" = "t"
echo "HA_REPLICATION_DATA_BINDING_RC=0"

echo "=== HA: fail primary and promote standby ==="
docker stop -t 10 ha-primary >/dev/null
docker exec ha-standby psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_promote(wait_seconds => 30);" >/dev/null
RECOVERY_AFTER="$(docker exec ha-standby psql -U postgres -Atqc "select pg_is_in_recovery();")"
test "$RECOVERY_AFTER" = "f"
docker exec ha-standby psql -U postgres -v ON_ERROR_STOP=1 -c "insert into ha_probe values (2,'after-failover');" >/dev/null
POST_FAILOVER="$(docker exec ha-standby psql -U postgres -Atqc "select marker from ha_probe where id=2;")"
test "$POST_FAILOVER" = "after-failover"
echo "HA_FAILOVER_PROMOTION_RC=0"
echo "HA_POST_FAILOVER_WRITE_RC=0"

echo "=== PITR: start archive-enabled primary ==="
docker run -d   --name pitr-primary   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256"   -v sanogo-pitr-primary:/var/lib/postgresql/data   -v sanogo-pitr-archive:/archive   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres     -c wal_level=replica     -c archive_mode=on     -c archive_timeout=1     -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f"   >/dev/null

wait_pg pitr-primary

docker exec pitr-primary psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE pitr_probe(id integer primary key, marker text not null);
INSERT INTO pitr_probe VALUES (1,'keep-before-target');
CHECKPOINT;
SQL

echo "=== PITR: take physical base backup ==="
docker run --rm   --network "$NET"   --user postgres   -e PGPASSFILE=/run/secrets/pgpass   -v sanogo-pitr-base:/var/lib/postgresql/data   -v "$PGPASS_DB:/run/secrets/pgpass:ro"   "$PG_IMAGE"   pg_basebackup     -h pitr-primary     -U postgres     -D /var/lib/postgresql/data     -Fp -Xs -P   >/dev/null

TARGET_TIME="$(docker exec pitr-primary psql -U postgres -Atqc "select clock_timestamp();")"
sleep 2
docker exec pitr-primary psql -U postgres -v ON_ERROR_STOP=1 -c "insert into pitr_probe values (2,'drop-after-target');" >/dev/null
docker exec pitr-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_switch_wal();" >/dev/null
sleep 3
docker stop -t 10 pitr-primary >/dev/null

echo "=== PITR: configure restore to target time ==="
docker run --rm   --user postgres   -v sanogo-pitr-base:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu "touch /var/lib/postgresql/data/recovery.signal
cat >> /var/lib/postgresql/data/postgresql.auto.conf <<EOF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '$TARGET_TIME'
recovery_target_action = 'promote'
EOF"

docker run -d   --name pitr-restore   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -v sanogo-pitr-base:/var/lib/postgresql/data   -v sanogo-pitr-archive:/archive:ro   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres   >/dev/null

wait_pg pitr-restore

for _ in $(seq 1 90); do
  IN_RECOVERY="$(docker exec pitr-restore psql -U postgres -Atqc "select pg_is_in_recovery();" 2>/dev/null || true)"
  if [ "$IN_RECOVERY" = "f" ]; then break; fi
  sleep 1
done
test "$IN_RECOVERY" = "f"

KEEP="$(docker exec pitr-restore psql -U postgres -Atqc "select count(*) from pitr_probe where marker='keep-before-target';")"
DROP="$(docker exec pitr-restore psql -U postgres -Atqc "select count(*) from pitr_probe where marker='drop-after-target';")"
test "$KEEP" = "1"
test "$DROP" = "0"
echo "PITR_TARGET_RESTORE_RC=0"
echo "PITR_PRE_TARGET_DATA_PRESENT_RC=0"
echo "PITR_POST_TARGET_DATA_EXCLUDED_RC=0"

printf '%s\n' \
  "HA_STREAMING_REPLICATION_RC=0" \
  "HA_REPLICATION_DATA_BINDING_RC=0" \
  "HA_FAILOVER_PROMOTION_RC=0" \
  "HA_POST_FAILOVER_WRITE_RC=0" \
  "PITR_TARGET_RESTORE_RC=0" \
  "PITR_PRE_TARGET_DATA_PRESENT_RC=0" \
  "PITR_POST_TARGET_DATA_EXCLUDED_RC=0"
