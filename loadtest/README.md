# Teste de carga (prova do HPA)

O HPA fica entre 2 e 5 replicas e escala por CPU a 70%. Este teste gera carga
para escalar de verdade e registrar a prova em `docs/`.

O k6 roda como Job dentro do cluster, apontando para o Service `todolist`. Nao
precisa de k6 instalado na maquina: a imagem `grafana/k6` traz o binario.

## Quando usar

Fora do fluxo do Argo CD. E um teste manual, disparado de proposito para gerar
evidencia. O cluster precisa estar no ar (`make up`).

## Rodar

```bash
export KUBECONFIG=~/.kube/talos-kubeconfig
kubectl apply -k loadtest/

# acompanhar a carga
kubectl -n todolist-staging logs -f job/loadtest

# em outro terminal: ver o HPA reagir (2 -> N)
kubectl -n todolist-staging get hpa todolist -w
kubectl -n todolist-staging get pods -l app=todolist -w
```

As credenciais do login vem do Secret `todolist-auth`, o mesmo que a app usa.
O alvo `http://todolist` e o Service no namespace `todolist-staging`.

## Evidencia

Durante a rampa (30s -> 20 VUs, 2 min -> 60 VUs), capture:

- `kubectl -n todolist-staging describe hpa todolist` mostrando a mudanca de replicas
- o painel de CPU/replicas no Grafana (`TodoList — Aplicacao e Recursos`)

Salve os prints em `docs/prints/`.

## Limpar

```bash
kubectl -n todolist-staging delete job loadtest
kubectl -n todolist-staging delete configmap loadtest-script
```

## Limites

- Roda so no `staging`. Em `production` seria a mesma coisa, com o cuidado de
  nao disparar alerta de erro para o time.
- O teste cria tarefas de verdade no banco de staging. `CLEANUP_TOKEN` ou o
  endpoint `/cleanup` remove as concluidas depois.
