#!/bin/bash
# =============================================================================
# setup-gitea-otimizado-proxmox.sh
# Cria uma arquitetura dividida: 1 LXC para o Gitea + 1 LXC para os Runners
# Usa Debian 13 (Trixie) - Execute no HOST do Proxmox como root
# ============================================================================

set -e

# ─── CONFIGURAÇÕES DE REDE E ID ──────────────────────────────────────────────
LXC_BRIDGE="vmbr1"
LXC_GW="10.11.10.254"
TEMPLATE_PATH="/var/lib/vz/template/cache/debian-13-standard_13.1-2_amd64.tar.zst"
LXC_PASSWORD="Senha1122"

# LXC 1: Servidor Gitea (Seguro e Isolado)
GITEA_ID=204"
GITEA_IP_CIDR="10.11.10.73/24"
GITEA_IP="10.11.10.73"
GITEA_PORT=3000
GITEA_HOSTNAME="giteadga-server"
GITEA_CONTAINER_NAME="giteadgasrv"
GITEA_VOLUME_NAME="giteadga_datasrv"

# LXC 2: Central de Runners (Robusto para compilações)
RUNNERS_ID=203
RUNNERS_IP_CIDR="10.11.10.74/24"
RUNNERS_IP="10.11.10.74"
RUNNERS_HOSTNAME="giteadga-runners"
ACT_RUNNER_1_CONTAINER_NAME="act_runner_1"
ACT_RUNNER_1_VOLUME="act_runner_1_data"
ACT_RUNNER_2_CONTAINER_NAME="act_runner_2"
ACT_RUNNER_2_VOLUME="act_runner_2_data"
ACT_RUNNER_3_CONTAINER_NAME="act_runner_3"
ACT_RUNNER_3_VOLUME="act_runner_3_data"
lq ta /
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── 1. VALIDAÇÃO DO TEMPLATE DEBIAN 13 ──────────────────────────────────────
if [ ! -f "$TEMPLATE_PATH" ]; then
  log "Construindo template Debian 13 via dab..."
  if ! command -v dab &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq dab
  fi
  mkdir -p /tmp/dab-debian13 && cd /tmp/dab-debian13
  wget -q -O dab.conf "https://git.proxmox.com/?p=dab-pve-appliances.git;a=blob_plain;f=debian-13-trixie-std-64/dab.conf;hb=HEAD"
  wget -q -O Makefile "https://git.proxmox.com/?p=dab-pve-appliances.git;a=blob_plain;f=debian-13-trixie-std-64/Makefile;hb=HEAD"
  dab init && dab bootstrap && dab finalize --compressor zstd-max
  cp *.tar.zst "$TEMPLATE_PATH"
  cd /
fi

# ─── 2. CRIAR LXC 1: SERVIDOR GITEA (PRIVILEGIADO COM NESTING) ─────────────────
log "Criando LXC ID $GITEA_ID - Servidor Gitea (Seguro)..."
pct create $GITEA_ID $TEMPLATE_PATH \
  --hostname $GITEA_HOSTNAME \
  --memory 1536 \
  --cores 1 \
  --rootfs local-lvm:40 \
  --net0 name=eth0,bridge=$LXC_BRIDGE,ip=$GITEA_IP_CIDR,gw=$LXC_GW \
  --unprivileged 0 \
  --password $LXC_PASSWORD \
  --features keyctl=1,nesting=1

# Ajustes finos de segurança para permitir Docker/overlayfs no container Gitea
cat >> /etc/pve/lxc/${GITEA_ID}.conf << LXCCONF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
LXCCONF

pct start $GITEA_ID
sleep 5

log "Instalando Docker no Servidor Gitea..."
pct exec $GITEA_ID -- bash -c "
  apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
"

log "Configurando docker-compose do Gitea Server..."
pct exec $GITEA_ID -- bash -c "
  mkdir -p /root/gitea
  cat > /root/gitea/docker-compose.yml << EOF
services:
  giteadga:
    image: gitea/gitea:latest
    container_name: ${GITEA_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - \"3000:3000\"
      - \"222:22\"
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__server__ROOT_URL=http://${GITEA_IP}:${GITEA_PORT}
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__database__PATH=/data/gitea/gitea.db
    volumes:
      - ${GITEA_VOLUME_NAME}:/data
volumes:
  ${GITEA_VOLUME_NAME}:
EOF
  cd /root/gitea && docker compose up -d
"

# ─── 3. CRIAR LXC 2: CENTRAL DE RUNNERS (PRIVILEGIADO COM NESTING) ───────────
log "Criando LXC ID $RUNNERS_ID - Central de Executores (Runners)..."
pct create $RUNNERS_ID $TEMPLATE_PATH \
  --hostname $RUNNERS_HOSTNAME \
  --memory 2048 \
  --cores 2 \
  --rootfs local-lvm:80 \
  --net0 name=eth0,bridge=$LXC_BRIDGE,ip=$RUNNERS_IP_CIDR,gw=$LXC_GW \
  --unprivileged 0 \
  --password $LXC_PASSWORD \
  --features keyctl=1,nesting=1

# Ajustes finos de segurança apenas no container de execução de código
cat >> /etc/pve/lxc/${RUNNERS_ID}.conf << LXCCONF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
LXCCONF

pct start $RUNNERS_ID
sleep 5

log "Instalando Docker na Central de Runners..."
pct exec $RUNNERS_ID -- bash -c "
  apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
"

log "Configurando a estrutura dos 3 Act Runners..."
pct exec $RUNNERS_ID -- bash -c "
  mkdir -p /root/runners
  cat > /root/runners/docker-compose.yml << EOF
services:
  act_runner_1:
    image: gitea/act_runner:latest
    container_name: ${ACT_RUNNER_1_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://${GITEA_IP}:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=COLOQUE_SEU_TOKEN_AQUI
      - GITEA_RUNNER_NAME=${ACT_RUNNER_1_CONTAINER_NAME}
      - GITEA_RUNNER_LABELS=deploy,producao
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${ACT_RUNNER_1_VOLUME}:/data

  act_runner_2:
    image: gitea/act_runner:latest
    container_name: ${ACT_RUNNER_2_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://${GITEA_IP}:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=COLOQUE_SEU_TOKEN_AQUI
      - GITEA_RUNNER_NAME=${ACT_RUNNER_2_CONTAINER_NAME}
      - GITEA_RUNNER_LABELS=testes,staging
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${ACT_RUNNER_2_VOLUME}:/data

  act_runner_3:
    image: gitea/act_runner:latest
    container_name: ${ACT_RUNNER_3_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://${GITEA_IP}:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN=COLOQUE_SEU_TOKEN_AQUI
      - GITEA_RUNNER_NAME=${ACT_RUNNER_3_CONTAINER_NAME}
      - GITEA_RUNNER_LABELS=build,compilacao
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${ACT_RUNNER_3_VOLUME}:/data

volumes:
  ${ACT_RUNNER_1_VOLUME}:
  ${ACT_RUNNER_2_VOLUME}:
  ${ACT_RUNNER_3_VOLUME}:
EOF
"

echo ""
echo "============================================================"
echo -e "${GREEN}  INFRAESTRUTURA DISTRIBUÍDA PRONTA COM SUCESSO!${NC}"
echo "============================================================"
echo "  Gitea Server IP : $GITEA_IP (ID: $GITEA_ID)"
echo "  Gitea Runners IP: $RUNNERS_IP (ID: $RUNNERS_ID)"
echo "============================================================"
echo "  PRÓXIMOS PASSOS:"
echo "  1. Vá em seu navegador: http://$GITEA_IP:3000"
echo "  2. Pegue o Token de administrador em Site Administration -> Runners"
echo "  3. Acesse o LXC dos Runners para atualizar o token:"
echo "     pct exec $RUNNERS_ID -- nano /root/runners/docker-compose.yml"
echo "  4. Inicie os executores de testes:"
echo "     pct exec $RUNNERS_ID -- bash -c 'cd /root/runners && docker compose up -d'"
echo "============================================================"
