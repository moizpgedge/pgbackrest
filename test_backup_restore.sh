#!/usr/bin/env bash
set -euo pipefail

IMAGE=pgbr-pg
CONTAINER=pgbr-test

echo "=== Clean old container/volumes ==="
docker stop "$CONTAINER" 2>/dev/null || true
docker rm "$CONTAINER" 2>/dev/null || true
docker volume rm pgdata pgrepo 2>/dev/null || true

echo "=== Start fresh container ==="
docker run -d \
  --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=secret \
  -p 5433:5432 \
  -v pgdata:/var/lib/postgresql/data \
  -v pgrepo:/var/lib/pgbackrest \
  "$IMAGE"

echo "=== Wait for Postgres ==="
until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
  sleep 1
done

echo "=== Create test table + row ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "DROP TABLE IF EXISTS restore_test;"

docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "CREATE TABLE restore_test(id int primary key, note text);"



echo "=== Verify test table BEFORE backup ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "SELECT * FROM restore_test;"

echo "=== Change shared_buffers in postgresql.conf BEFORE backup ==="
docker exec "$CONTAINER" bash -lc 'echo "shared_buffers = 999MB" >> $PGDATA/postgresql.conf'

echo "=== Reload config so new shared_buffers is active ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "SELECT pg_reload_conf();"

echo "=== Show shared_buffers BEFORE backup (from running Postgres) ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "SHOW shared_buffers;"

echo "=== Create Northwind DB and load data ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS northwind;"

docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "CREATE DATABASE northwind;"

docker exec "$CONTAINER" \
  psql -U postgres -d northwind -f /northwind.sql

echo "=== Verify Northwind customers count BEFORE backup ==="
docker exec "$CONTAINER" \
  psql -U postgres -d northwind -c "SELECT count(*) AS customers_count FROM customers;"

# Force checkpoint to flush Northwind files to disk and WAL
docker exec "$CONTAINER" psql -U postgres -d postgres -c "CHECKPOINT;"

# Force WAL switch to ensure all changes are archived
docker exec "$CONTAINER" psql -U postgres -d postgres -c "SELECT pg_switch_wal();"

# Wait longer for WAL archiving to complete
sleep 30

# Wait for WAL archiving to complete
sleep 5

echo "=== Create stanza ==="
docker exec "$CONTAINER" pgbackrest --stanza=demo stanza-create

echo "=== Take backup (latest) ==="
docker exec "$CONTAINER" pgbackrest --stanza=demo backup
docker exec "$CONTAINER" pgbackrest --stanza=demo info
BACKUP_LABEL=$(docker exec "$CONTAINER" pgbackrest --stanza=demo info | awk '/full backup:/ {print $3; exit}')
echo "Extracted BACKUP_LABEL: $BACKUP_LABEL"
if [ -z "$BACKUP_LABEL" ]; then
  echo "ERROR: Could not extract backup label. Aborting."
  exit 1
fi

echo "=== Drop test table + Northwind DB (simulate disaster) ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "DROP TABLE restore_test;"

docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "DROP DATABASE northwind;"

docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "\dt restore_test*"

echo "=== Stop Postgres container ==="
docker stop "$CONTAINER"

echo "=== List available backups before restore ==="
docker run --rm \
  --entrypoint bash \
  -v pgdata:/var/lib/postgresql/data \
  -v pgrepo:/var/lib/pgbackrest \
  "$IMAGE" \
  -lc "pgbackrest --stanza=demo info"

echo "=== Restore latest backup WITHOUT --delta (wipe PGDATA first) ==="
docker run --rm \
  --entrypoint bash \
  -v pgdata:/var/lib/postgresql/data \
  -v pgrepo:/var/lib/pgbackrest \
  "$IMAGE" \
  -lc "rm -rf /var/lib/postgresql/data/* && pgbackrest --stanza=demo restore --set='$BACKUP_LABEL' --type=immediate"

echo "=== Start container after restore ==="
docker start "$CONTAINER"

echo "=== Wait for Postgres after restore ==="
until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
  sleep 1
done

echo "=== Show shared_buffers AFTER restore ==="
docker exec "$CONTAINER" \
  psql -U postgres -d postgres -c "SHOW shared_buffers;"


echo "=== Check restored Northwind customers count ==="
docker exec "$CONTAINER" \
  psql -U postgres -d northwind -c "SELECT count(*) AS customers_count FROM customers;"

echo "=== Done ==="
