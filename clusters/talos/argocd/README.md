# ArgoCD instalado por codigo (manifest remoto versionado por URL + versao).
# Reproducao: kubectl apply -n argocd -f install.yaml && kubectl apply -f projects/ applications/
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
# Bootstrap: aplica o install oficial e em seguida projects/ + applications/.
# install.yaml e um espelho local do upstream v3.1.8 (argoproj/argo-cd) para
# reprodutibilidade offline; origem registrada aqui.
# Upstream: https://raw.githubusercontent.com/argoproj/argo-cd/v3.1.8/manifests/install.yaml
