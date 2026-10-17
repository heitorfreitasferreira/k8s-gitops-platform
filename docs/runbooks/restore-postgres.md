# Runbook: restore do Postgres a partir do MinIO (WAL-G)

Backup continuo com WAL-G no pod do Postgres:

- **WAL**: o Postgres roda com `archive_mode=on` e
  `archive_command=wal-g wal-push %p`. Cada segmento de WAL vai para o MinIO.
- **Base backup**: o sidecar `wal-g-backup` roda `wal-g backup-push $PGDATA`
  a cada 24h e mantem os ultimos 7 (`wal-g delete retain FULL 7 --confirm`).
- **Destino**: bucket `postgres-backups`, prefixo por ambiente
  (`s3://postgres-backups/staging` e `.../production`).
- **Credenciais**: Secret `minio-backup` no namespace, criado pelo Terraform.

Com base backup + WAL arquivado, o restore e point-in-time (PITR).

## Pre-requisitos

- `KUBECONFIG=~/.kube/talos-kubeconfig` exportado.
- Namespace e ambiente definidos. Exemplos usam `todolist-staging`.
- As variaveis abaixo iguais as do Secret (endpoint, bucket, chaves):

```sh
NS=todolist-staging
PGDATA=/var/lib/postgresql/data/pgdata
IMG=ghcr.io/heitorfreitasferreira/postgres-walg:<digest>
```

## 1. Parar a escrita

Para um restore consistente, tire a app do ar antes de sobrescrever o volume.

```sh
kubectl -n "$NS" scale deploy/todolist --replicas=0
kubectl -n "$NS" scale deploy/postgres --replicas=0
```

## 2. Conferir os backups disponiveis

Rode um pod temporario com a imagem do WAL-G, montando o mesmo PVC. Ele herda
as credenciais do Secret `minio-backup`.

```sh
kubectl -n "$NS" delete pod pg-restore --ignore-not-found
kubectl -n "$NS" run pg-restore --restart=Never \
  --image="$IMG" \
  --overrides='{
    "spec":{
      "securityContext":{"runAsNonRoot":true,"runAsUser":70,"runAsGroup":70},
      "containers":[{
        "name":"pg-restore",
        "image":"'"$IMG"'",
        "command":["sh","-c","sleep 3600"],
        "envFrom":[{"secretRef":{"name":"minio-backup"}}],
        "env":[{"name":"PGDATA","value":"'"$PGDATA"'"}],
        "volumeMounts":[{"name":"data","mountPath":"/var/lib/postgresql/data"}]
      }],
      "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"postgres-data"}}]
    }
  }'
kubectl -n "$NS" wait --for=condition=Ready pod/pg-restore --timeout=120s
kubectl -n "$NS" exec pg-restore -- wal-g backup-list
```

`backup-list` mostra os base backups (nome = data/hora). `LATEST` aponta para o
mais recente.

## 3. Restaurar o base backup

```sh
# Limpa o diretorio atual e baixa o base backup mais recente do MinIO.
kubectl -n "$NS" exec pg-restore -- sh -c \
  'rm -rf "$PGDATA" && install -d -m 0700 "$PGDATA" && wal-g backup-fetch "$PGDATA" LATEST'
```

## 4. Aplicar os WAL (recovery)

Aponte o `restore_command` para o WAL-G e ligue o recovery. Sem
`recovery_target_*`, o Postgres aplica todo o WAL disponivel (ultimo estado
arquivado).

```sh
kubectl -n "$NS" exec pg-restore -- sh -c '
  cat >> "$PGDATA/postgresql.auto.conf" <<EOF
restore_command = '"'"'wal-g wal-fetch %f %p'"'"'
EOF
  touch "$PGDATA/recovery.signal"
'
```

Para PITR ate um instante (opcional), adicione antes do `touch`:

```
recovery_target_time = '2026-10-17 03:00:00+00'
recovery_target_action = 'promote'
```

## 5. Remover o pod temporario e subir o Postgres

```sh
kubectl -n "$NS" delete pod pg-restore
kubectl -n "$NS" scale deploy/postgres --replicas=1
kubectl -n "$NS" wait --for=condition=Ready pod -l app=postgres --timeout=180s
```

O Postgres entra em recovery, aplica os WAL do MinIO e promove sozinho. A
saida do container (`kubectl -n "$NS" logs deploy/postgres -c postgres`) mostra
`redo done` e `database system is ready to accept connections`.

## 6. Validar e religar a app

```sh
kubectl -n "$NS" scale deploy/todolist --replicas=2
kubectl -n "$NS" exec deploy/postgres -c postgres -- \
  psql -U todolist -d todolist -c 'select count(*) from task;'
curl -k -o /dev/null -w '%{http_code}\n' -H "Host: staging.local" https://<traefik-ip>/healthz
```

Confirmar: contagem de linhas coerente com o instante do restore e `healthz`
200.

## Notas

- O restore nao apaga os backups: `backup-fetch` so le o MinIO.
- Se o base backup nao aparecer em `backup-list`, conferir o Secret
  `minio-backup` (endpoint, chaves) e a NetworkPolicy de egress do pod do
  Postgres (porta 9000 para o IP do MinIO).
- Alerta de falha: `PostgresBackupFalhando` dispara quando o sidecar
  `wal-g-backup` reinicia (falha no `backup-push`). O envio ate o ntfy e do
  Alertmanager.
