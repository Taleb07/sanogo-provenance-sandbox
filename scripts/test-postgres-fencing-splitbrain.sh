#!/usr/bin/env bash
set -euo pipefail

PG_IMAGE="postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
NET="sanogo-fencing"
WORKDIR="${RUNNER_TEMP:-/tmp}/sanogo-fencing"
DB_SECRET="$WORKDIR/db_password"
REPL_SECRET="$WORKDIR/repl_password"
FENCE_DIR="$WORKDIR/fence"

cleanup() {
  set +e
  docker rm -f fence-primary fence-standby >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm sanogo-fence-primary sanogo-fence-standby >/dev/null 2>&1 || true
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

mkdir -p "$WORKDIR" "$FENCE_DIR"
chmod 700 "$WORKDIR" "$FENCE_DIR"
openssl rand -hex 32 > "$DB_SECRET"
openssl rand -hex 32 > "$REPL_SECRET"
chmod 600 "$DB_SECRET" "$REPL_SECRET"
REPL_PASS="$(cat "$REPL_SECRET")"

docker network create --internal "$NET" >/dev/null
docker volume create sanogo-fence-primary >/dev/null
docker volume create sanogo-fence-standby >/dev/null

echo "epoch=1" > "$FENCE_DIR/cluster.epoch"
echo "writer=fence-primary" >> "$FENCE_DIR/cluster.epoch"
chmod 600 "$FENCE_DIR/cluster.epoch"

docker run --rm -v sanogo-fence-standby:/target "$PG_IMAGE" sh -ceu 'chown postgres:postgres /target'

echo "=== start primary ==="
docker run -d   --name fence-primary   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password   -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256"   -v sanogo-fence-primary:/var/lib/postgresql/data   -v "$DB_SECRET:/run/secrets/db_password:ro"   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres     -c wal_level=replica     -c max_wal_senders=5     -c hot_standby=on     -c password_encryption=scram-sha-256   >/dev/null

wait_pg fence-primary

docker exec -i fence-primary psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';
CREATE TABLE public.fence_probe(id integer primary key, marker text not null);
INSERT INTO public.fence_probe VALUES (1,'epoch-1-primary');
SQL

docker exec fence-primary sh -ceu 'printf "%s\n" "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"'
docker exec fence-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_reload_conf();" >/dev/null

printf 'fence-primary:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i   --network "$NET"   --user postgres   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m,mode=1777   -e PGPASSFILE=/tmp/pgpass   -v sanogo-fence-standby:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu 'umask 077; cat > /tmp/pgpass; pg_basebackup -h fence-primary -U replicator -D /var/lib/postgresql/data -Fp -Xs -P'   >/dev/null

printf 'fence-primary:*:*:replicator:%s\n' "$REPL_PASS" | docker run --rm -i   --user postgres   -v sanogo-fence-standby:/var/lib/postgresql/data   "$PG_IMAGE"   sh -ceu 'umask 077; cat > /var/lib/postgresql/data/.pgpass; touch /var/lib/postgresql/data/standby.signal; printf "%s\n" "primary_conninfo = '\''host=fence-primary user=replicator passfile=/var/lib/postgresql/data/.pgpass'\''" >> /var/lib/postgresql/data/postgresql.auto.conf'

docker run -d   --name fence-standby   --network "$NET"   --read-only   --security-opt no-new-privileges   --cap-drop ALL   --cap-add CHOWN   --cap-add DAC_OVERRIDE   --cap-add FOWNER   --cap-add SETGID   --cap-add SETUID   --pids-limit 256   --memory 512m   --cpus 1   -v sanogo-fence-standby:/var/lib/postgresql/data   --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m   --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,size=16m   "$PG_IMAGE"   postgres -c hot_standby=on   >/dev/null

wait_pg fence-standby

for _ in $(seq 1 60); do
  state="$(docker exec fence-primary psql -U postgres -Atqc "select coalesce(max(state),'') from pg_stat_replication;" || true)"
  [ "$state" = "streaming" ] && break
  sleep 1
done
test "$state" = "streaming"
echo "FENCE_REPLICATION_READY_RC=0"

docker exec fence-primary psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_create_restore_point('pre_failover_fence_barrier');" >/dev/null
sleep 1

echo "=== simulate primary failure ==="
docker stop -t 5 fence-primary >/dev/null
docker exec fence-standby psql -U postgres -v ON_ERROR_STOP=1 -c "select pg_promote(true, 30);" >/dev/null
test "$(docker exec fence-standby psql -U postgres -Atqc "select pg_is_in_recovery();")" = "f"
echo "epoch=2" > "$FENCE_DIR/cluster.epoch"
echo "writer=fence-standby" >> "$FENCE_DIR/cluster.epoch"
chmod 600 "$FENCE_DIR/cluster.epoch"
echo "FENCE_PROMOTION_EPOCH_BUMP_RC=0"

docker exec fence-standby psql -U postgres -v ON_ERROR_STOP=1 -c "insert into public.fence_probe values (2,'epoch-2-standby-promoted');" >/dev/null
echo "FENCE_NEW_PRIMARY_WRITE_RC=0"

echo "=== prove native split-brain risk if old primary is restarted without fencing ==="
docker start fence-primary >/dev/null
wait_pg fence-primary
OLD_PRIMARY_RECOVERY="$(docker exec fence-primary psql -U postgres -Atqc "select pg_is_in_recovery();")"
test "$OLD_PRIMARY_RECOVERY" = "f"
docker exec fence-primary psql -U postgres -v ON_ERROR_STOP=1 -c "insert into public.fence_probe values (3,'unsafe-old-primary-write');" >/dev/null
echo "NATIVE_SPLIT_BRAIN_RISK_PROVEN_RC=0"

echo "=== apply deterministic SANOGO fencing ==="
EXPECTED_WRITER="$(awk -F= '$1=="writer"{print $2}' "$FENCE_DIR/cluster.epoch")"
test "$EXPECTED_WRITER" = "fence-standby"
docker stop -t 5 fence-primary >/dev/null
test "$(docker inspect -f '{{.State.Running}}' fence-primary)" = "false"
echo "FENCE_OLD_PRIMARY_STOPPED_RC=0"

cat > "$WORKDIR/start-old-primary-if-authorized.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
node="$1"
fence_file="$2"
expected="$(awk -F= '$1=="writer"{print $2}' "$fence_file")"
if [ "$node" != "$expected" ]; then
  echo "DENY_STALE_WRITER node=$node expected=$expected" >&2
  exit 42
fi
exit 0
EOF
chmod 700 "$WORKDIR/start-old-primary-if-authorized.sh"

set +e
"$WORKDIR/start-old-primary-if-authorized.sh" fence-primary "$FENCE_DIR/cluster.epoch" >/tmp/fence-deny.out 2>&1
DENY_RC=$?
set -e
test "$DENY_RC" -eq 42
grep -q "DENY_STALE_WRITER" /tmp/fence-deny.out
echo "FENCE_STALE_WRITER_DENY_RC=0"

"$WORKDIR/start-old-primary-if-authorized.sh" fence-standby "$FENCE_DIR/cluster.epoch"
echo "FENCE_CURRENT_WRITER_ALLOW_RC=0"

test "$(docker inspect -f '{{.State.Running}}' fence-primary)" = "false"
docker exec fence-standby psql -U postgres -v ON_ERROR_STOP=1 -c "insert into public.fence_probe values (4,'writer-after-fencing');" >/dev/null
test "$(docker exec fence-standby psql -U postgres -Atqc "select marker from public.fence_probe where id=4;")" = "writer-after-fencing"
echo "FENCE_SINGLE_WRITER_POST_CONDITION_RC=0"

printf '%s\n'   "FENCE_REPLICATION_READY_RC=0"   "FENCE_PROMOTION_EPOCH_BUMP_RC=0"   "FENCE_NEW_PRIMARY_WRITE_RC=0"   "NATIVE_SPLIT_BRAIN_RISK_PROVEN_RC=0"   "FENCE_OLD_PRIMARY_STOPPED_RC=0"   "FENCE_STALE_WRITER_DENY_RC=0"   "FENCE_CURRENT_WRITER_ALLOW_RC=0"   "FENCE_SINGLE_WRITER_POST_CONDITION_RC=0"
