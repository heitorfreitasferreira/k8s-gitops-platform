# Terraform: infra + platform

Este diretorio nao e um root aplicavel. Os roots sao `infra/` e `platform/`,
cada um com state local.

Ordem de subida: `infra` primeiro, `platform` depois. Use o `Makefile` na raiz:

```bash
make up    # infra apply, depois platform apply
make down  # platform destroy, depois infra destroy
```

Detalhes em `infra/README.md` e `platform/README.md`.
