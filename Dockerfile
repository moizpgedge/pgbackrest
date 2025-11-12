# Postgres base image (Debian-based, multi-arch, works on Mac)
FROM postgres:16

# Build args – official pgBackRest repo + main branch
ARG PGBR_REPO="https://github.com/pgEdge/pgbackrest"
ARG PGBR_BRANCH="main"

USER root

# Install build deps for pgBackRest
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
      meson \
      ninja-build \
      gcc \
      g++ \
      make \
      pkg-config \
      libpq-dev \
      libssl-dev \
      libxml2-dev \
      liblz4-dev \
      libzstd-dev \
      libbz2-dev \
      zlib1g-dev \
      libyaml-dev \
      libssh2-1-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone pgBackRest main and build
RUN git clone --branch "${PGBR_BRANCH}" --single-branch "${PGBR_REPO}" pgbackrest && \
    meson setup /build/pgbackrest-build /build/pgbackrest --buildtype=release && \
    ninja -C /build/pgbackrest-build && \
    ninja -C /build/pgbackrest-build install

# pgBackRest config
RUN mkdir -p /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest && \
    chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest && \
    printf '%s\n' \
      '[global]' \
      'repo1-path=/var/lib/pgbackrest' \
      'log-path=/var/log/pgbackrest' \
      'log-level-console=info' \
      'log-level-file=info' \
      'repo1-retention-full=2' \
      '' \
      '[demo]' \
      'pg1-path=/var/lib/postgresql/data' \
      > /etc/pgbackrest/pgbackrest.conf && \
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf && \
    chmod 640 /etc/pgbackrest/pgbackrest.conf

# Enable archive_mode on first init
RUN mkdir -p /docker-entrypoint-initdb.d && \
    cat >/docker-entrypoint-initdb.d/pgbackrest-archive.sh <<'EOF'
#!/bin/bash
set -e
echo "archive_mode = on" >> "$PGDATA/postgresql.conf"
echo "archive_command = 'pgbackrest --stanza=demo archive-push %p'" >> "$PGDATA/postgresql.conf"
echo "archive_timeout = 60" >> "$PGDATA/postgresql.conf"
EOF
RUN chmod +x /docker-entrypoint-initdb.d/pgbackrest-archive.sh

USER postgres
EXPOSE 5432
# ENTRYPOINT and CMD come from postgres:16
