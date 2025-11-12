Docker Backup/Restore Demo
==========================

This repository includes a self-contained Docker workflow that builds a Postgres + pgBackRest image and exercises a full backup/restore cycle against the bundled Northwind sample database.

Prerequisites
-------------

- Docker Engine is installed and running (Docker Desktop on macOS/Windows, or a local daemon on Linux).
- You have cloned this repository and are working from its root directory.

Build the Image
---------------

The `Dockerfile` compiles pgBackRest from source on top of the official `postgres:16` image and copies in the Northwind dataset.

```bash
docker build --tag pgbr-pg .
```

Run the Backup/Restore Script
-----------------------------

`test_backup_restore.sh` orchestrates the full scenario end-to-end:

1. Starts a fresh container from the `pgbr-pg` image with named volumes for Postgres data (`pgdata`) and the pgBackRest repo (`pgrepo`).
2. Loads the Northwind sample database and tweaks `shared_buffers` to demonstrate config recovery.
3. Forces checkpoints and WAL switches so pgBackRest can archive everything.
4. Creates the `demo` stanza, performs a full backup, and captures the backup label.
5. Simulates a disaster by dropping the test objects, stops Postgres, and wipes `PGDATA`.
6. Restores the captured backup without `--delta`, restarts Postgres, and verifies both the configuration value and row counts.

Run the script from the repository root:

```bash
./test_backup_restore.sh
```

Expect to see log output confirming the backup label (e.g. `20251112-124654F`), the restored `shared_buffers` value (`999MB`), and the Northwind `customers` row count returning to `91`.

Manual pgBackRest Commands
--------------------------

If you prefer to run individual pgBackRest commands yourself, start the container first:

```bash
docker run -d --name pgbr-test -e POSTGRES_PASSWORD=secret -p 5433:5432 \
  -v pgdata:/var/lib/postgresql/data \
  -v pgrepo:/var/lib/pgbackrest \
  pgbr-pg
```

Then, execute pgBackRest inside the running container:

- Create the stanza:

  ```bash
  docker exec pgbr-test pgbackrest --stanza=demo stanza-create
  ```

- Take a full backup (an incremental automatically becomes full the first time):

  ```bash
  docker exec pgbr-test pgbackrest --stanza=demo backup
  ```

- Inspect backups and capture the latest backup label:

  ```bash
  docker exec pgbr-test pgbackrest --stanza=demo info
  BACKUP_LABEL=$(docker exec pgbr-test pgbackrest --stanza=demo info | awk '/full backup:/ {print $3; exit}')
  echo "Latest label: ${BACKUP_LABEL}"
  ```

- Restore the captured backup (stop Postgres first and wipe `PGDATA`):

  ```bash
  docker stop pgbr-test
  docker run --rm --entrypoint bash \
    -v pgdata:/var/lib/postgresql/data \
    -v pgrepo:/var/lib/pgbackrest \
    pgbr-pg \
    -lc "rm -rf /var/lib/postgresql/data/* && pgbackrest --stanza=demo restore --set='${BACKUP_LABEL}' --type=immediate"
  docker start pgbr-test
  ```

Cleanup
-------

If you want to remove the demo artifacts after the run:

```bash
docker stop pgbr-test 2>/dev/null || true
docker rm pgbr-test 2>/dev/null || true
docker volume rm pgdata pgrepo 2>/dev/null || true
```

Troubleshooting
---------------

- **Permission denied connecting to Docker**: ensure your user can talk to the Docker daemon (`docker ps` should succeed). On macOS, start Docker Desktop first.
- **Port conflicts**: the script maps Postgres to port `5433` on the host. Adjust the `-p 5433:5432` flag inside the script if that port is already in use.
- **Long WAL archive waits**: the script waits for WAL archiving via sleeps; on slower machines you can increase the delays around `pg_switch_wal()` if needed.


