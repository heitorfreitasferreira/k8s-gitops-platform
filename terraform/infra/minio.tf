# MinIO fora do cluster: VM Debian 12 + bucket S3 para backups do Postgres.
#
# A VM vive na mesma rede NAT das VMs Talos, com IP fixo .20, e nao e exposta
# na LAN de trabalho. O console ganha dominio via Ingress do Traefik
# (terraform/infra/minio-console-ingress.yaml, render local); a API S3 fica so na rede interna.

locals {
  minio_address  = cidrhost(var.network_cidr, var.minio_hostnum)
  minio_mac      = "52:54:00:ca:fe:14"
  minio_endpoint = "http://${local.minio_address}:9000"

  # Release legado com binario pre-compilado (o ultimo que ainda tem assets).
  # O dl.min.io foi desligado (410 Gone): a edicao comunitaria virou so codigo
  # fonte, entao o binario vem pinado do GitHub, com checksum verificado.
  minio_release      = var.minio_release
  minio_binary_url   = "https://github.com/minio/minio/releases/download/${local.minio_release}/minio.linux-amd64.${local.minio_release}"
  minio_checksum_url = "https://github.com/minio/minio/releases/download/${local.minio_release}/minio.linux-amd64.${local.minio_release}.sha256sum"
}

# ---------------------------------------------------------------------------
# Disco: Debian 12 genericcloud (imagem oficial, com cloud-init embutido).
# ---------------------------------------------------------------------------

# Imagem baixada uma vez; o disco da VM e uma camada CoW sobre ela (o provider
# nao aceita `size` junto de `source`, entao sao dois volumes, igual ao Talos).
resource "libvirt_volume" "minio_base" {
  name   = "${var.cluster_name}-minio-debian-12.qcow2"
  pool   = var.storage_pool
  source = var.debian_image_url
  format = "qcow2"
}

resource "libvirt_volume" "minio" {
  name           = "${var.cluster_name}-minio.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.minio_base.id
  format         = "qcow2"
  size           = var.minio_disk_size_gb * 1024 * 1024 * 1024
}

# Cresce a particao raiz para o tamanho do disco no primeiro boot.
resource "libvirt_cloudinit_disk" "minio" {
  name = "${var.cluster_name}-minio-cloudinit.iso"
  pool = var.storage_pool

  user_data = <<-EOT
    #cloud-config
    hostname: ${var.cluster_name}-minio
    manage_etc_hosts: true
    growpart:
      mode: auto
      devices: ["/"]
    # Usuario padrao da imagem Debian cloud, com sudo e chave do operador
    # (passada por variavel, nunca commitada). Sem isso nao ha como
    # inspecionar a VM: a imagem desabilita login por senha.
    users:
      - name: debian
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        ssh_authorized_keys:
          - ${var.minio_ssh_pubkey}
    runcmd:
      # Guest agent primeiro: sem ele o libvirt nao enxerga IP da VM.
      - [sh, -xc, "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-guest-agent && systemctl enable --now qemu-guest-agent"]
      # node_exporter: metricas de host desta VM (CPU, memoria, disco, rede) para
      # o dashboard "VMs / Hosts" e os alertas de node. Escuta em todas as
      # interfaces (o Prometheus do cluster raspa <ip>:9100 pela rede NAT).
      - [sh, -xc, "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-node-exporter && sed -i 's|^ARGS=.*|ARGS=\"--web.listen-address=:9100\"|' /etc/default/prometheus-node-exporter && systemctl enable --now prometheus-node-exporter"]
      - [sh, -xc, "cd /tmp && curl -fsSL -o minio ${local.minio_binary_url} && curl -fsSL -o minio.sha256sum ${local.minio_checksum_url} && test \"$(sha256sum minio | cut -d' ' -f1)\" = \"$(cut -d' ' -f1 minio.sha256sum)\" && install -o root -g root -m 0755 minio /usr/local/bin/minio && rm -f minio minio.sha256sum"]
      - [sh, -xc, "id -u minio-user >/dev/null 2>&1 || useradd -r -m -s /usr/sbin/nologin minio-user"]
      - [sh, -xc, "mkdir -p /data && chown minio-user:minio-user /data"]
      # Delimitador com aspas de proposito: sem elas o shell expandiria
      # $MINIO_OPTS/$MINIO_VOLUMES na hora de escrever o unit (vazios ali) e o
      # console cairia em porta aleatoria. Com <<'EOF2' a expansao fica para o
      # systemd, que le do EnvironmentFile. (No YAML do cloud-init, \' vira '.)
      - [sh, -xc, "cat >/etc/default/minio <<\\'EOF2\nMINIO_ROOT_USER=${var.minio_root_user}\nMINIO_ROOT_PASSWORD=${var.minio_root_password}\nMINIO_VOLUMES=/data\nMINIO_OPTS=--console-address :9001\nEOF2"]
      - [sh, -xc, "cat >/etc/systemd/system/minio.service <<\\'EOF2\n[Unit]\nDescription=MinIO S3 storage\nAfter=network-online.target\nWants=network-online.target\n[Service]\nUser=minio-user\nGroup=minio-user\nEnvironmentFile=/etc/default/minio\nExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\nEOF2"]
      - [sh, -xc, "systemctl daemon-reload && systemctl enable --now minio.service"]
  EOT

  # DHCP de proposito: o provider registra o IP fixo como reserva DHCP da rede
  # (igual ao Talos). IP estatico no guest dispensaria o dnsmasq, mas o
  # `wait_for_lease` do dominio esta desligado (provider 0.8.3 nao enxerga o
  # lease neste host); a prontidao e checada no health da API :9000.
  network_config = <<-EOT
    version: 2
    ethernets:
      id0:
        match:
          macaddress: "${local.minio_mac}"
        dhcp4: true
  EOT
}

# ---------------------------------------------------------------------------
# VM: 1 vCPU / 2 GiB / 20 GiB.
# ---------------------------------------------------------------------------

resource "libvirt_domain" "minio" {
  name       = "${var.cluster_name}-minio"
  type       = "kvm"
  vcpu       = var.minio_vcpu
  memory     = var.minio_memory_mb
  machine    = var.minio_machine_type
  firmware   = var.minio_machine_type == "q35" ? var.firmware_path : null
  qemu_agent = true
  cloudinit  = libvirt_cloudinit_disk.minio.id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.minio.id
  }

  network_interface {
    network_name = var.network_name
    mac          = local.minio_mac
    addresses    = [local.minio_address]
    # Sem espera de lease de proposito: o provider 0.8.3 nunca enxerga o lease
    # do dnsmasq neste host e o apply travaria ate o deadline. O IP continua
    # deterministico pela reserva DHCP (.20); a prontidao e checada no
    # health da API :9000 antes de criar o bucket.
    wait_for_lease = false
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  lifecycle {
    ignore_changes = [
      nvram,
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}

# ---------------------------------------------------------------------------
# Bucket: provider aws com path-style contra o endpoint MinIO.
#
# O MinIO demora a subir depois da VM (download do binario no primeiro boot),
# entao o primeiro apply pode falhar aqui: basta repetir o apply.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "minio" {
  bucket        = var.minio_bucket_name
  force_destroy = false

  depends_on = [libvirt_domain.minio]
}
