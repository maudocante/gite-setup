#!/bin/bash
# =============================================================================
# setup-gitea-proxmox.sh
# Cria LXC privilegiado no Proxmox com Docker + Gitea + 3 Act Runners
# Usa Debian 13 (Trixie)
# Execute no HOST do Proxmox como root
# =============================================================================

set -e

# ─── CONFIGURAÇÕES ────────────────────────────────────────────────────────────
LXC_IP_CIDR="10.11.10.71/24"
LXC_IP="10.11.10.71"
LXC_GW="10.11.10.254"
LXC_ID=202
LXC_HOSTNAME="gitea-lxc"
LXC_PASSWORD="Senha1122"
LXC_MEMORY=2048
LXC_CORES=2
LXC_DISK="local-lvm:120"
LXC_BRIDGE="vmbr1"
GITEA_PORT=3000
GITEA_SSH_PORT=222
TEMPLATE_PATH="/var/lib/vz/template/cache/debian-13-standard_13.1-2_amd64.tar.zst"
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── 1. TEMPLATE DEBIAN 13 ───────────────────────────────────────────────────
if [ -f "$TEMPLATE_PATH" ]; then
  log "Template Debian 13 já existe em $TEMPLATE_PATH"
else
  log "Template Debian 13 não encontrado. Construindo via dab..."

  if ! command -v dab &>/dev/null; then
    log "Instalando dab..."
    apt-get update -qq
    apt-get install -y -qq dab
  fi

  mkdir -p /tmp/dab-debian13
  cd /tmp/dab-debian13

  log "Baixando configuração dab..."
  wget -q -O dab.conf \
    "https://git.proxmox.com/?p=dab-pve-appliances.git;a=blob_plain;f=debian-13-trixie-std-64/dab.conf;hb=HEAD"
  wget -q -O Makefile \
    "https://git.proxmox.com/?p=dab-pve-appliances.git;a=blob_plain;f=debian-13-trixie-std-64/Makefile;hb=HEAD"

  log "Construindo template Debian 13 (pode demorar alguns minutos)..."
  dab init
  dab bootstrap
  dab finalize --compressor zstd-max

  BUILT=""
  for f in *.tar.*; do
    [ -e "$f" ] || continue
    BUILT="$f"
    break
  done
  [ -z "$BUILT" ] && err "Falha ao construir o template Debian 13."

  cp "$BUILT" "$TEMPLATE_PATH"
  log "Template copiado para $TEMPLATE_PATH"
  cd /
fi

# ─── 2. CRIAR O LXC PRIVILEGIADO ─────────────────────────────────────────────
log "Criando LXC ID $LXC_ID ($LXC_HOSTNAME)..."
pct create $LXC_ID $TEMPLATE_PATH \
  --hostname $LXC_HOSTNAME \
  --memory $LXC_MEMORY \
  --cores $LXC_CORES \
  --rootfs $LXC_DISK \
  --net0 name=eth0,bridge=$LXC_BRIDGE,ip=$LXC_IP_CIDR,gw=$LXC_GW \
  --unprivileged 0 \
  --password $LXC_PASSWORD \
  --features keyctl=1,nesting=1

# ─── 3. SUPORTE DOCKER NO LXC ────────────────────────────────────────────────
log "Aplicando configurações Docker no LXC..."
cat >> /etc/pve/lxc/${LXC_ID}.conf << LXCCONF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
LXCCONF

# ─── 4. INICIAR O LXC ────────────────────────────────────────────────────────
log "Iniciando LXC..."
pct start $LXC_ID
sleep 6

# ─── 5. INSTALAR DOCKER ──────────────────────────────────────────────────────
log "Instalando Docker no LXC Debian 13..."
pct exec $LXC_ID -- bash -c "
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian trixie stable\" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable --now docker
  docker --version
"

# ─── 6. CRIAR docker-compose.yml ─────────────────────────────────────────────
# NOTA: usamos aspas duplas no heredoc para expandir as variáveis correctamente
log "Criando docker-compose.yml (Gitea + 3 Runners)..."
pct exec $LXC_ID -- bash -c "
  mkdir -p /root/gitea
  cat > /root/gitea/docker-compose.yml << COMPOSE
services:

  giteadga:
    image: gitea/gitea:latest
    container_name: giteadga
    restart: unless-stopped
    ports:
      - \"${GITEA_PORT}:3000\"
      - \"${GITEA_SSH_PORT}:22\"
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__server__ROOT_URL=http://${LXC_IP}:${GITEA_PORT}
      - GITEA__server__MAX_REQUEST_BODY_SIZE=-1
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__database__PATH=/data/gitea/gitea.db
      - GITEA__repository__upload__FILE_MAX_SIZE=1024
      - GITEA__repository__upload__MAX_FILES=20
      - GITEA__server__LFS_START_SERVER=true
      - GITEA__lfs__PATH=/data/gitea/lfs
    volumes:
      - giteadga_data:/data

  act_runner_1:
    image: gitea/act_runner:latest
    container_name: act_runner_1
    restart: unless-stopped
    depends_on:
      - giteadga
    extra_hosts:
      - giteadga:${LXC_IP}
    environment:
      - GITEA_INSTANCE_URL=http://${LXC_IP}:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=COLOQUE_SEU_TOKEN_AQUI
      - GITEA_RUNNER_NAME=dga-runner-1
      - GITEA_RUNNER_LABELS=deploy,producao
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - act_runner_1_data:/data

  act_runner_2:
    image: gitea/act_runner:latest
    container_name: act_runner_2
    restart: unless-stopped
    depends_on:
      - giteadga
    extra_hosts:
      - giteadga:${LXC_IP}
    environment:
      - GITEA_INSTANCE_URL=http://${LXC_IP}:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=COLOQUE_SEU_TOKEN_AQUI
      - GITEA_RUNNER_NAME=dga-runner-2
      - GITEA_RUNNER_LABELS=testes,staging
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - act_runner_2_data:/data

  act_runner_3:
    image: gitea/act_runner:latest
    container_name: act_runner_3
    restart: unless-stopped
    depends_on:
      - giteadga
    extra_hosts:
      - giteadga:${LXC_IP}
    environment:
      - GITEA_INSTANCE_URL=http://${LXC_IP}:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=COLOQUE_SEU_TOKEN_AQUI
      - GITEA_RUNNER_NAME=dga-runner-3
      - GITEA_RUNNER_LABELS=build,compilacao
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - act_runner_3_data:/data

volumes:
  giteadga_data:
  act_runner_1_data:
  act_runner_2_data:
  act_runner_3_data:
COMPOSE
"

# ─── 7. SUBIR APENAS O GITEA PRIMEIRO ────────────────────────────────────────
log "Subindo Gitea..."
pct exec $LXC_ID -- bash -c "cd /root/gitea && docker compose up -d giteadga"

# ─── 8. INSTRUÇÕES FINAIS ────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "${GREEN}  AMBIENTE CRIADO COM SUCESSO! (Debian 13 Trixie)${NC}"
echo "============================================================"
echo ""
echo "  LXC ID   : $LXC_ID"
echo "  IP       : $LXC_IP"
echo ""
echo "  Gitea    : http://$LXC_IP:$GITEA_PORT"
echo ""
echo "  PRÓXIMOS PASSOS:"
echo ""
echo "  1. Acesse http://$LXC_IP:$GITEA_PORT e complete a instalação"
echo ""
echo "  2. Vá em: Site Administration → Runners → Create new runner"
echo "     e copie o TOKEN gerado"
echo ""
echo "  3. Substitua o token nos 3 runners:"
echo "     pct exec $LXC_ID -- nano /root/gitea/docker-compose.yml"
echo "     (substitua COLOQUE_SEU_TOKEN_AQUI pelo token copiado)"
echo ""
echo "  4. Suba os 3 runners:"
echo "     pct exec $LXC_ID -- bash -c 'cd /root/gitea && docker compose up -d'"
echo ""
echo "  5. Verifique os logs:"
echo "     pct exec $LXC_ID -- docker logs act_runner_1 -f"
echo "     pct exec $LXC_ID -- docker logs act_runner_2 -f"
echo "     pct exec $LXC_ID -- docker logs act_runner_3 -f"
echo "============================================================"
