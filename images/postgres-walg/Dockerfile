# ABOUTME: Postgres 16 (Alpine) com o binario do WAL-G para backup continuo no MinIO.
# ABOUTME: O binario do WAL-G e glibc, entao roda no Alpine via gcompat.
ARG POSTGRES_IMAGE=postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea

# ---------------------------------------------------------------------------
# Estagio 1: baixa o binario do WAL-G do release oficial, com checksum pinado.
# Mesmo padrao do cloud-init do MinIO (download pinado + sha256 verificado).
# ---------------------------------------------------------------------------
FROM alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507 AS fetch

ARG WALG_VERSION=3.0.7
ARG WALG_SHA256=76d51ed915165d45314bc947300b9d1776adb2d875d857f580a730fd6f66900e

RUN apk add --no-cache curl \
 && curl -fsSL -o /tmp/wal-g.tar.gz \
      "https://github.com/wal-g/wal-g/releases/download/v${WALG_VERSION}/wal-g-pg-ubuntu-22.04-amd64.tar.gz" \
 && echo "${WALG_SHA256}  /tmp/wal-g.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/wal-g.tar.gz -C /tmp \
 && install -m 0755 /tmp/wal-g-pg-ubuntu-22.04-amd64 /usr/local/bin/wal-g

# ---------------------------------------------------------------------------
# Estagio 2: imagem final, mesma base (mesmo uid 70 e mesmo layout de PGDATA).
# ---------------------------------------------------------------------------
FROM ${POSTGRES_IMAGE}

# gcompat carrega binarios glibc no musl do Alpine. O WAL-G so linka libc/libm.
USER root
RUN apk add --no-cache gcompat
COPY --from=fetch /usr/local/bin/wal-g /usr/local/bin/wal-g
