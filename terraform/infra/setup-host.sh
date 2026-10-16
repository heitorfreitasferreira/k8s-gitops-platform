#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="$ROOT/terraform.tfvars"
URI="${LIBVIRT_URI:-}"

fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
for tool in virsh python3 openssl awk; do command -v "$tool" >/dev/null || fail "falta '$tool'. Instale os pre-requisitos conforme terraform/infra/README.md."; done
NETWORK="${LIBVIRT_NETWORK:-}"
if [[ -n "$URI" ]]; then
  URIS=("$URI")
else
  CURRENT_URI="$(virsh uri 2>/dev/null || true)"
  URIS=("$CURRENT_URI" qemu:///system qemu:///session)
fi
for candidate_uri in "${URIS[@]}"; do
  [[ -n "$candidate_uri" ]] || continue
  if [[ -n "$NETWORK" ]]; then
    NETWORKS=("$NETWORK")
  else
    mapfile -t NETWORKS < <(virsh -c "$candidate_uri" net-list --name 2>/dev/null | sed '/^[[:space:]]*$/d')
  fi
  for candidate_network in "${NETWORKS[@]}"; do
    xml="$(virsh -c "$candidate_uri" net-dumpxml "$candidate_network" 2>/dev/null || true)"
    if grep -Eq "<forward mode=['\"]nat" <<<"$xml"; then
      URI="$candidate_uri"
      NETWORK="$candidate_network"
      break 2
    fi
  done
done
[[ -n "$URI" && -n "$NETWORK" ]] || fail "nenhuma rede NAT ativa detectada. Ative uma rede libvirt NAT ou defina LIBVIRT_URI/LIBVIRT_NETWORK."

POOL="${LIBVIRT_POOL:-}"
if [[ -z "$POOL" ]]; then
  mapfile -t POOLS < <(virsh -c "$URI" pool-list --name 2>/dev/null | sed '/^[[:space:]]*$/d')
  POOL="${POOLS[0]:-}"
fi
[[ -n "$POOL" ]] || fail "nenhum pool de storage ativo detectado. Defina LIBVIRT_POOL."

virsh -c "$URI" net-info "$NETWORK" >/dev/null 2>&1 || fail "libvirt indisponivel em $URI ou rede '$NETWORK' inexistente. Defina LIBVIRT_URI/LIBVIRT_NETWORK se usar outros nomes."
virsh -c "$URI" pool-info "$POOL" >/dev/null 2>&1 || fail "pool '$POOL' inexistente. Defina LIBVIRT_POOL para o pool ativo."
NET_XML="$(virsh -c "$URI" net-dumpxml "$NETWORK")"
POOL_XML="$(virsh -c "$URI" pool-dumpxml "$POOL")"
NETWORK_CIDR="$(python3 -c 'import ipaddress,sys,xml.etree.ElementTree as E; r=E.fromstring(sys.stdin.read()); n=r.find("./ip"); assert n is not None, "a rede nao tem subnet IPv4"; print(ipaddress.ip_network((n.attrib["address"],n.attrib["netmask"]),strict=False))' <<<"$NET_XML")" || fail "nao foi possivel detectar o CIDR IPv4 da rede libvirt."
POOL_PATH="$(python3 -c 'import sys,xml.etree.ElementTree as E; r=E.fromstring(sys.stdin.read()); print(r.findtext("./target/path", ""))' <<<"$POOL_XML")"
[[ -n "$POOL_PATH" && -d "$POOL_PATH" ]] || fail "diretorio de storage do pool '$POOL' nao existe: $POOL_PATH"

FIRMWARE="${FIRMWARE_PATH:-}"
if [[ -z "$FIRMWARE" ]]; then
  for candidate in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [[ -r "$candidate" ]]; then FIRMWARE="$candidate"; break; fi
  done
fi
[[ -n "$FIRMWARE" && -r "$FIRMWARE" ]] || fail "OVMF nao detectado. Instale firmware UEFI ou defina FIRMWARE_PATH."
command -v mkisofs >/dev/null || fail "falta mkisofs (Arch: cdrtools, Debian/Ubuntu: genisoimage ou cdrtools, Fedora: genisoimage)."
[[ ! -e "$TFVARS" ]] || fail "$TFVARS ja existe. Preserve seus segredos; remova ou mova esse arquivo manualmente apenas se quiser gerar uma configuracao nova."

# Requisitos para o cluster completo (3 nos Talos + VM MinIO).
CPU_COUNT="$(nproc)"
MEMORY_MIB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
DISK_KIB="$(df -Pk "$POOL_PATH" | awk 'NR==2 {print $4}')"
DISK_GIB="$((DISK_KIB / 1024 / 1024))"
printf 'Host detectado: %s CPUs, %s MiB RAM, %s GiB livres em %s\n' "$CPU_COUNT" "$MEMORY_MIB" "$DISK_GIB" "$POOL_PATH"
if (( CPU_COUNT < 8 || MEMORY_MIB < 16384 || DISK_GIB < 80 )); then
  printf 'AVISO: minimo recomendado para cluster completo: 8 CPUs, 16 GiB RAM e 80 GiB livres.\n'
  printf 'O MinIO isolado usa 1 CPU, 2 GiB RAM e 20 GiB de disco.\n'
fi

SSH_PUBKEY="${MINIO_SSH_PUBKEY:-}"
if [[ -z "$SSH_PUBKEY" ]]; then
  for key in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_ecdsa.pub "$HOME"/.ssh/id_rsa.pub; do
    if [[ -r "$key" ]]; then SSH_PUBKEY="$(<"$key")"; break; fi
  done
fi
[[ -n "$SSH_PUBKEY" ]] || fail "chave publica SSH nao encontrada. Crie uma com ssh-keygen ou exporte MINIO_SSH_PUBKEY."
MINIO_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -hex 24)}"
MINIO_HOSTNUM="${MINIO_HOSTNUM:-20}"
MINIO_IP="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(int(ipaddress.ip_network(sys.argv[1],strict=False).network_address)+int(sys.argv[2])))' "$NETWORK_CIDR" "$MINIO_HOSTNUM")"

cat >"$TFVARS" <<EOF
# Gerado localmente por setup-host.sh. Arquivo ignorado pelo Git.
libvirt_uri = "$URI"
network_name = "$NETWORK"
network_cidr = "$NETWORK_CIDR"
storage_pool = "$POOL"
firmware_path = "$FIRMWARE"
minio_root_user = "minioadmin"
minio_root_password = "$MINIO_PASSWORD"
minio_ssh_pubkey = "$SSH_PUBKEY"
minio_hostnum = $MINIO_HOSTNUM
EOF
chmod 600 "$TFVARS"

INGRESS_TEMPLATE="$ROOT/templates/minio-console-ingress.yaml.tftpl"
INGRESS_RENDERED="$ROOT/minio-console-ingress.yaml"
[[ -r "$INGRESS_TEMPLATE" ]] || fail "template do Ingress nao encontrado: $INGRESS_TEMPLATE"
sed "s|\${MINIO_IP}|$MINIO_IP|g" "$INGRESS_TEMPLATE" >"$INGRESS_RENDERED"

printf 'Configuracao local gerada: %s\n' "$TFVARS"
printf 'Ingress local renderizado: %s (IP %s)\n' "$INGRESS_RENDERED" "$MINIO_IP"
printf 'Rede detectada: %s (%s), pool: %s\n' "$NETWORK" "$NETWORK_CIDR" "$POOL"
printf 'Segredo aleatorio salvo apenas em terraform.tfvars (modo 600, ignorado pelo Git).\n'
printf 'Proximo: cd %s && terraform init && terraform apply\n' "$ROOT"
printf 'API S3: terraform output -raw minio_endpoint. Console via minio.localhost quando Traefik estiver ativo.\n'
