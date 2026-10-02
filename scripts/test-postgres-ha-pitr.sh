#!/usr/bin/env bash
set -euo pipefail

PG_IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
NET="sanogo-db-ha-pitr"
WORKDIR="${RUNNER_TEMP:-/tmp}/sanogo-db-ha-pitr"
DB_SECRET="$WORKDIR/db_password"
REPL_SECRET="$WORKDIR/repl_password"

cleanup() {
  set +e
  for c in ha-primary ha-standby pitr-primary pitr-restore; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm sanogo-ha-primary sanogo-ha-standby sanogo-pitr-primary sanogo-pitr-base sanogo-pitr-archive >/dev/null 2>&1 || true
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

docker network create --internal "$NET" >/dev/null
for v in sanogo-ha-primary sanogo-ha-standby sanogo-pitr-primary sanogo-pitr-base sanogo-pitr-archive; do
  docker volume create "$v" >/dev/null
done

for v in sanogo-ha-standby sanogo-pitr-base sanogo-pitr-archive; do
  docker run --rm -v "$v:/target" "$PG_IMAGE" sh -ceu 'chown postgres:postgres /target'
done

echo "=== HA: start primary ==="
docker run -d --name ha-primary --network "$NET" --read-only --security-opt no-new-privileges --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --pids-limit 256 --memory 512m --cpus 1 -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" -v sanogo-ha-primary:/var/lib/postgresql/data -v "$DB_SECRET:/run/secrets/db_password:ro" --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m "$PG_IMAGE" postgres -c wal_level=replica -c max_wal_senders=5 -c max_replication_slots=5 -c hot_standby=on -c wal_keep_size=64MB -c password_encryption=scram-sha-256 >/dev/null
wait_pg ha-primary

docker exec -i ha-primary psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';
SQL

docker exec ha-primary sh -ceu 'printf "%s\n" "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"'
docker exec ha-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_reload_conf();" >/dev/null

echo "=== HA: clone standby from primary ==="
printf 'ha-primary:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i --network "$NET" --user postgres --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m,mode=1777 -e PGPASSFILE=/tmp/pgpass -v sanogo-ha-standby:/var/lib/postgresql/data "$PG_IMAGE" sh -ceu 'umask 077; cat > /tmp/pgpass; pg_basebackup -h ha-primary -U replicator -D /var/lib/postgresql/data -Fp -Xs -P' >/dev/null

printf 'ha-primary:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i --user postgres -v sanogo-ha-standby:/var/lib/postgresql/data "$PG_IMAGE" sh -ceu 'umask 077; cat > /var/lib/postgresql/data/.pgpass; touch /var/lib/postgresql/data/standby.signal; printf "%s\n" "primary_conninfo = '\''host=ha-primary user=replicator passfile=/var/lib/postgresql/data/.pgpass'\''" >> /var/lib/postgresql/data/postgresql.auto.conf'

docker run -d --name ha-standby --network "$NET" --read-only --security-opt no-new-privileges --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --pids-limit 256 --memory 512m --cpus 1 -v sanogo-ha-standby:/var/lib/postgresql/data --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m "$PG_IMAGE" postgres -c hot_standby=on >/dev/null
wait_pg ha-standby

STATE=""
for _ in $(seq 1 60); do
  STATE="$(docker exec ha-primary psql -U postgres -Atqc "select coalesce(max(state),'') from pg_stat_replication;" || true)"
  if [ "$STATE" = "streaming" ]; then
    break
  fi
  sleep 1
done
test "$STATE" = "streaming"
echo "HA_STREAMING_REPLICATION_RC=0"

docker exec ha-standby psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_wal_replay_resume();" >/dev/null

docker exec ha-primary psql -U postgres -q -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS public.ha_probe(id integer primary key, marker text not null); INSERT INTO public.ha_probe VALUES (1,'before-failover') ON CONFLICT (id) DO UPDATE SET marker=excluded.marker;" >/dev/null
PRIMARY_MARKER="$(docker exec ha-primary psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "SELECT marker FROM public.ha_probe WHERE id=1;")"
test "$PRIMARY_MARKER" = "before-failover"
echo "HA_PRIMARY_PROBE_WRITE_RC=0"

BARRIER_LSN="$(docker exec ha-primary psql -U postgres -Atqc "select pg_create_restore_point('sanogo_ha_probe_barrier');")"
REPLAY_REACHED="f"
for _ in $(seq 1 60); do
  REPLAY_REACHED="$(docker exec ha-standby psql -U postgres -Atqc "select coalesce(pg_last_wal_replay_lsn() >= '$BARRIER_LSN'::pg_lsn,false);" 2>/dev/null || true)"
  if [ "$REPLAY_REACHED" = "t" ]; then
    break
  fi
  sleep 1
done

if [ "$REPLAY_REACHED" != "t" ]; then
  echo "HA_REPLAY_BARRIER_TIMEOUT=1" >&2
  echo "HA_BARRIER_LSN=$BARRIER_LSN" >&2
  docker exec ha-primary psql -U postgres -c "select current_database(),application_name,state,sent_lsn,write_lsn,flush_lsn,replay_lsn,sync_state from pg_stat_replication;" >&2 || true
  docker exec ha-standby psql -U postgres -c "select current_database(),pg_is_in_recovery(),pg_is_wal_replay_paused(),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn(),to_regclass('public.ha_probe');" >&2 || true
  docker logs --tail 80 ha-standby >&2 || true
  exit 31
fi

RELATION="$(docker exec ha-standby psql -U postgres -Atqc "select coalesce(to_regclass('public.ha_probe')::text,'');")"
if [ "$RELATION" != "ha_probe" ]; then
  echo "HA_RELATION_NOT_VISIBLE_AFTER_BARRIER=1" >&2
  echo "HA_BARRIER_LSN=$BARRIER_LSN" >&2
  docker exec ha-primary psql -U postgres -c "select current_database(),to_regclass('public.ha_probe'),pg_current_wal_flush_lsn();" >&2 || true
  docker exec ha-standby psql -U postgres -c "select current_database(),pg_is_in_recovery(),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn(),to_regclass('public.ha_probe');" >&2 || true
  docker logs --tail 80 ha-standby >&2 || true
  exit 32
fi

MARKER="$(docker exec ha-standby psql -U postgres -Atqc "select marker from public.ha_probe where id=1;")"
test "$MARKER" = "before-failover"
test "$(docker exec ha-standby psql -U postgres -Atqc "select pg_is_in_recovery();")" = "t"
echo "HA_REPLICATION_LSN_REPLAY_RC=0"
echo "HA_REPLICATION_DATA_BINDING_RC=0"

echo "=== HA: fail primary and promote standby ==="
docker stop -t 10 ha-primary >/dev/null
docker exec ha-standby psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_promote(true, 30);" >/dev/null
test "$(docker exec ha-standby psql -U postgres -Atqc "select pg_is_in_recovery();")" = "f"
docker exec ha-standby psql -U postgres -v ON_ERROR_STOP=1 -c "insert into ha_probe values (2,'after-failover');" >/dev/null
test "$(docker exec ha-standby psql -U postgres -Atqc "select marker from ha_probe where id=2;")" = "after-failover"
echo "HA_FAILOVER_PROMOTION_RC=0"
echo "HA_POST_FAILOVER_WRITE_RC=0"

echo "=== PITR: start archive-enabled primary ==="
docker run -d --name pitr-primary --network "$NET" --read-only --security-opt no-new-privileges --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --pids-limit 256 --memory 512m --cpus 1 -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" -v sanogo-pitr-primary:/var/lib/postgresql/data -v sanogo-pitr-archive:/archive -v "$DB_SECRET:/run/secrets/db_password:ro" --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m "$PG_IMAGE" postgres -c wal_level=replica -c archive_mode=on -c archive_timeout=1 -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f" >/dev/null
wait_pg pitr-primary

docker exec pitr-primary psql -U postgres -q -v ON_ERROR_STOP=1 -c "CREATE TABLE public.pitr_probe(id integer primary key, marker text not null); INSERT INTO public.pitr_probe VALUES (1,'keep-before-target'); CHECKPOINT;" >/dev/null
PITR_PRIMARY_MARKER="$(docker exec pitr-primary psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "SELECT marker FROM public.pitr_probe WHERE id=1;")"
test "$PITR_PRIMARY_MARKER" = "keep-before-target"
echo "PITR_PRIMARY_PROBE_WRITE_RC=0"

echo "=== PITR: take physical base backup ==="
printf 'pitr-primary:*:*:postgres:%s\n' "$DB_PASS" | docker run --rm -i --network "$NET" --user postgres --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m,mode=1777 -e PGPASSFILE=/tmp/pgpass -v sanogo-pitr-base:/var/lib/postgresql/data "$PG_IMAGE" sh -ceu 'umask 077; cat > /tmp/pgpass; pg_basebackup -h pitr-primary -U postgres -D /var/lib/postgresql/data -Fp -Xs -P' >/dev/null

TARGET_TIME="$(docker exec pitr-primary psql -U postgres -Atqc "select clock_timestamp();")"
sleep 2
docker exec pitr-primary psql -U postgres -v ON_ERROR_STOP=1 -c "insert into pitr_probe values (2,'drop-after-target');" >/dev/null
ARCHIVED_BEFORE="$(docker exec pitr-primary psql -U postgres -Atqc "select archived_count from pg_stat_archiver;")"
docker exec pitr-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_switch_wal();" >/dev/null

ARCHIVED_AFTER="$ARCHIVED_BEFORE"
for _ in $(seq 1 60); do
  ARCHIVED_AFTER="$(docker exec pitr-primary psql -U postgres -Atqc "select archived_count from pg_stat_archiver;")"
  if [ "$ARCHIVED_AFTER" -gt "$ARCHIVED_BEFORE" ]; then
    break
  fi
  sleep 1
done
test "$ARCHIVED_AFTER" -gt "$ARCHIVED_BEFORE"
echo "PITR_WAL_ARCHIVE_RC=0"

docker stop -t 10 pitr-primary >/dev/null

echo "=== PITR: configure restore to target time ==="
docker run --rm --user postgres -v sanogo-pitr-base:/var/lib/postgresql/data "$PG_IMAGE" sh -ceu "touch /var/lib/postgresql/data/recovery.signal; printf '%s\n' \"restore_command = 'cp /archive/%f %p'\" \"recovery_target_time = '$TARGET_TIME'\" \"recovery_target_action = 'promote'\" >> /var/lib/postgresql/data/postgresql.auto.conf"

docker run -d --name pitr-restore --network "$NET" --read-only --security-opt no-new-privileges --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --pids-limit 256 --memory 512m --cpus 1 -v sanogo-pitr-base:/var/lib/postgresql/data -v sanogo-pitr-archive:/archive:ro --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m "$PG_IMAGE" postgres >/dev/null
wait_pg pitr-restore

IN_RECOVERY="t"
for _ in $(seq 1 90); do
  IN_RECOVERY="$(docker exec pitr-restore psql -U postgres -Atqc "select pg_is_in_recovery();" 2>/dev/null || true)"
  if [ "$IN_RECOVERY" = "f" ]; then
    break
  fi
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

printf '%s\n' "HA_STREAMING_REPLICATION_RC=0" "HA_REPLICATION_DATA_BINDING_RC=0" "HA_FAILOVER_PROMOTION_RC=0" "HA_POST_FAILOVER_WRITE_RC=0" "PITR_WAL_ARCHIVE_RC=0" "PITR_TARGET_RESTORE_RC=0" "PITR_PRE_TARGET_DATA_PRESENT_RC=0" "PITR_POST_TARGET_DATA_EXCLUDED_RC=0"
