#!/usr/bin/env bash
set -euo pipefail

PG_IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
NET="sanogo-recovery-timing"
WORKDIR="${RUNNER_TEMP:-/tmp}/sanogo-recovery-timing"
DB_SECRET="$WORKDIR/db_password"
REPL_SECRET="$WORKDIR/repl_password"

cleanup() {
  set +e
  for c in timing-primary timing-standby timing-pitr timing-restore; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm sanogo-timing-primary sanogo-timing-standby sanogo-timing-pitr sanogo-timing-base sanogo-timing-archive >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

wait_pg() {
  local c="$1"
  for _ in $(seq 1 90); do
    if docker exec "$c" pg_isready -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
openssl rand -hex 32 > "$DB_SECRET"
openssl rand -hex 32 > "$REPL_SECRET"
chmod 600 "$DB_SECRET" "$REPL_SECRET"
DB_PASS="$(cat "$DB_SECRET")"
REPL_PASS="$(cat "$REPL_SECRET")"

docker network create --internal "$NET" >/dev/null
for v in sanogo-timing-primary sanogo-timing-standby sanogo-timing-pitr sanogo-timing-base sanogo-timing-archive; do
  docker volume create "$v" >/dev/null
done
for v in sanogo-timing-standby sanogo-timing-base sanogo-timing-archive; do
  docker run --rm -v "$v:/target" "$PG_IMAGE" sh -ceu 'chown postgres:postgres /target'
done

echo "=== HA timing setup ==="
docker run -d   --name timing-primary   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256"   -v sanogo-timing-primary:/var/lib/postgresql/data   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres     -c wal_level=replica     -c max_wal_senders=5     -c hot_standby=on     -c password_encryption=scram-sha-256   >/dev/null
wait_pg timing-primary

docker exec -i timing-primary psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';
CREATE TABLE public.timing_probe(id integer primary key, marker text not null);
INSERT INTO public.timing_probe VALUES (1,'baseline');
SQL
docker exec timing-primary sh -ceu 'printf "%s\n" "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"'
docker exec timing-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_reload_conf();" >/dev/null

printf 'timing-primary:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i   --network "$NET" --user postgres   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m,mode=1777   -e PGPASSFILE=/tmp/pgpass   -v sanogo-timing-standby:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu 'umask 077; cat > /tmp/pgpass; pg_basebackup -h timing-primary -U replicator -D /var/lib/postgresql/data -Fp -Xs -P' >/dev/null

printf 'timing-primary:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i   --user postgres   -v sanogo-timing-standby:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu 'umask 077; cat > /var/lib/postgresql/data/.pgpass; touch /var/lib/postgresql/data/standby.signal; printf "%s\n" "primary_conninfo = '\''host=timing-primary user=replicator passfile=/var/lib/postgresql/data/.pgpass'\''" >> /var/lib/postgresql/data/postgresql.auto.conf'

docker run -d   --name timing-standby   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -v sanogo-timing-standby:/var/lib/postgresql/data   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE" postgres -c hot_standby=on >/dev/null
wait_pg timing-standby

for _ in $(seq 1 60); do
  state="$(docker exec timing-primary psql -U postgres -Atqc "select coalesce(max(state),'') from pg_stat_replication;" || true)"
  [ "$state" = "streaming" ] && break
  sleep 1
done
test "$state" = "streaming"

docker exec timing-primary psql -U postgres -v ON_ERROR_STOP=1 -c "insert into public.timing_probe values (2,'must-survive-failover');" >/dev/null
BARRIER_LSN="$(docker exec timing-primary psql -U postgres -Atqc "select pg_create_restore_point('timing_failover_barrier');")"

for _ in $(seq 1 60); do
  reached="$(docker exec timing-standby psql -U postgres -Atqc "select coalesce(pg_last_wal_replay_lsn() >= '$BARRIER_LSN'::pg_lsn,false);" 2>/dev/null || true)"
  [ "$reached" = "t" ] && break
  sleep 1
done
test "$reached" = "t"
echo "TIMING_PREFAILOVER_REPLAY_BARRIER_RC=0"

FAILURE_START_MS="$(date +%s%3N)"
docker stop -t 1 timing-primary >/dev/null
docker exec timing-standby psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_promote(true, 30);" >/dev/null
for _ in $(seq 1 90); do
  recovery="$(docker exec timing-standby psql -U postgres -Atqc "select pg_is_in_recovery();" 2>/dev/null || true)"
  if [ "$recovery" = "f" ]; then
    if docker exec timing-standby psql -U postgres -v ON_ERROR_STOP=1 -c "insert into public.timing_probe values (3,'post-failover-write');" >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 1
done
FAILURE_END_MS="$(date +%s%3N)"
DB_FAILOVER_RECOVERY_MS=$((FAILURE_END_MS - FAILURE_START_MS))
test "$DB_FAILOVER_RECOVERY_MS" -ge 0

SURVIVE="$(docker exec timing-standby psql -U postgres -Atqc "select count(*) from public.timing_probe where marker='must-survive-failover';")"
test "$SURVIVE" = "1"
POST="$(docker exec timing-standby psql -U postgres -Atqc "select count(*) from public.timing_probe where marker='post-failover-write';")"
test "$POST" = "1"
echo "CONTROLLED_FAILOVER_DATA_LOSS_ROWS=0"
echo "DB_FAILOVER_RECOVERY_MS=$DB_FAILOVER_RECOVERY_MS"
echo "DB_FAILOVER_RECOVERY_TIMING_RC=0"

echo "=== PITR timing setup ==="
docker run -d   --name timing-pitr   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256"   -v sanogo-timing-pitr:/var/lib/postgresql/data   -v sanogo-timing-archive:/archive   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres     -c wal_level=replica     -c archive_mode=on     -c archive_timeout=1     -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f"   >/dev/null
wait_pg timing-pitr

docker exec -i timing-pitr psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';
CREATE TABLE public.pitr_timing_probe(id integer primary key, marker text not null);
INSERT INTO public.pitr_timing_probe VALUES (1,'before-target');
SQL
docker exec timing-pitr sh -ceu 'printf "%s\n" "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"'
docker exec timing-pitr psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_reload_conf();" >/dev/null

printf 'timing-pitr:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i   --network "$NET" --user postgres   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m,mode=1777   -e PGPASSFILE=/tmp/pgpass   -v sanogo-timing-base:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu 'umask 077; cat > /tmp/pgpass; pg_basebackup -h timing-pitr -U replicator -D /var/lib/postgresql/data -Fp -Xs -P' >/dev/null

TARGET_TIME="$(docker exec timing-pitr psql -U postgres -Atqc "select clock_timestamp();")"
sleep 2
docker exec timing-pitr psql -U postgres -v ON_ERROR_STOP=1 -c "insert into public.pitr_timing_probe values (2,'after-target');" >/dev/null
BEFORE_ARCHIVED="$(docker exec timing-pitr psql -U postgres -Atqc "select archived_count from pg_stat_archiver;")"
docker exec timing-pitr psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_switch_wal();" >/dev/null
for _ in $(seq 1 60); do
  AFTER_ARCHIVED="$(docker exec timing-pitr psql -U postgres -Atqc "select archived_count from pg_stat_archiver;")"
  [ "$AFTER_ARCHIVED" -gt "$BEFORE_ARCHIVED" ] && break
  sleep 1
done
test "$AFTER_ARCHIVED" -gt "$BEFORE_ARCHIVED"
docker stop -t 1 timing-pitr >/dev/null

docker run --rm --user postgres   -v sanogo-timing-base:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu "touch /var/lib/postgresql/data/recovery.signal; printf '%s\n' \"restore_command = 'cp /archive/%f %p'\" \"recovery_target_time = '$TARGET_TIME'\" \"recovery_target_action = 'promote'\" >> /var/lib/postgresql/data/postgresql.auto.conf"

PITR_START_MS="$(date +%s%3N)"
docker run -d   --name timing-restore   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -v sanogo-timing-base:/var/lib/postgresql/data   -v sanogo-timing-archive:/archive:ro   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE" postgres >/dev/null

wait_pg timing-restore
for _ in $(seq 1 90); do
  recovery="$(docker exec timing-restore psql -U postgres -Atqc "select pg_is_in_recovery();" 2>/dev/null || true)"
  [ "$recovery" = "f" ] && break
  sleep 1
done
test "$recovery" = "f"
PITR_END_MS="$(date +%s%3N)"
PITR_RESTORE_MS=$((PITR_END_MS - PITR_START_MS))

PRE="$(docker exec timing-restore psql -U postgres -Atqc "select count(*) from public.pitr_timing_probe where marker='before-target';")"
POST="$(docker exec timing-restore psql -U postgres -Atqc "select count(*) from public.pitr_timing_probe where marker='after-target';")"
test "$PRE" = "1"
test "$POST" = "0"

echo "PITR_RESTORE_MS=$PITR_RESTORE_MS"
echo "PITR_RECOVERY_TIMING_RC=0"
echo "PITR_TARGET_DATA_STATE_RC=0"

cat > "$WORKDIR/recovery-metrics.json" <<JSON
{
  "db_failover_recovery_ms": $DB_FAILOVER_RECOVERY_MS,
  "controlled_failover_data_loss_rows": 0,
  "pitr_restore_ms": $PITR_RESTORE_MS,
  "scope": "single GitHub-hosted runner sandbox",
  "contractual_rpo_rto_claim": false
}
JSON

cat "$WORKDIR/recovery-metrics.json"
