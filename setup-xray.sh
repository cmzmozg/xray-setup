#!/bin/bash
set -e

# ============================================================
# XRAY SETUP — ЕВРО-НОДА + РФ-НОДА
# Использование:
#   ./setup-xray.sh          — интерактивное меню
#   ./setup-xray.sh euro     — установить Евро-ноду
#   ./setup-xray.sh rf       — установить РФ-ноду
#   ./setup-xray.sh status   — статус текущей ноды
#   ./setup-xray.sh ports    — управление портами UFW
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ALLOWED_IPS=("194.36.178.75" "109.174.35.73" "178.49.143.82")
XRAY_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ищем euro-node.conf: сначала текущая папка, затем папка скрипта, затем /root
if   [[ -f "$PWD/euro-node.conf" ]];        then STATE_FILE="$PWD/euro-node.conf"
elif [[ -f "$SCRIPT_DIR/euro-node.conf" ]]; then STATE_FILE="$SCRIPT_DIR/euro-node.conf"
elif [[ -f "/root/euro-node.conf" ]];       then STATE_FILE="/root/euro-node.conf"
else STATE_FILE="$PWD/euro-node.conf"  # путь для сохранения (Евро-нода)
fi

# ============================================================
# ОБЩИЕ ФУНКЦИИ
# ============================================================

print_banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║     XRAY VLESS+XHTTP+Reality+PQ  INSTALLER      ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root${NC}"; exit 1
  fi
}

install_deps() {
  echo -e "${YELLOW}[1/6] Установка зависимостей...${NC}"
  apt-get update -qq
  apt-get install -y -qq curl wget unzip ufw uuid-runtime openssl dnsutils conntrack python3
  echo -e "${GREEN}  Зависимости установлены${NC}"
}

install_xray() {
  echo -e "${YELLOW}[2/6] Установка Xray-core...${NC}"
  XRAY_VERSION=$(curl -sI "https://github.com/XTLS/Xray-core/releases/latest" \
    | grep -i "^location:" | grep -oP 'v[\d.]+')
  [[ -z "$XRAY_VERSION" ]] && XRAY_VERSION="v26.2.6"
  echo -e "${GREEN}  Версия: $XRAY_VERSION${NC}"

  TMP_DIR=$(mktemp -d)
  wget -q --show-progress -O "$TMP_DIR/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
  unzip -q "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray"
  install -m 755 "$TMP_DIR/xray/xray" /usr/local/bin/xray
  mkdir -p /usr/local/etc/xray /usr/local/share/xray /var/log/xray

  echo -e "${GREEN}  Загрузка geoip.dat и geosite.dat...${NC}"
  wget -q -O /usr/local/share/xray/geoip.dat \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  wget -q -O /usr/local/share/xray/geosite.dat \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
  rm -rf "$TMP_DIR"

  cat > /etc/systemd/system/xray.service << 'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  echo -e "${GREEN}  Xray установлен: $(/usr/local/bin/xray version | head -1)${NC}"
}

apply_sysctl() {
  grep -q "somaxconn=9000000" /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf << 'SYSCTL'
net.core.somaxconn=9000000
net.ipv4.tcp_max_syn_backlog=9000000
net.ipv4.tcp_fastopen=3
SYSCTL
  sysctl -p > /dev/null 2>&1
}

start_xray() {
  echo -e "${YELLOW}[6/6] Запуск Xray...${NC}"
  systemctl enable xray > /dev/null 2>&1
  systemctl restart xray
  sleep 2
  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}  Xray запущен${NC}"
  else
    echo -e "${RED}  Ошибка! journalctl -xe -u xray${NC}"; exit 1
  fi
}

get_server_ip() {
  curl -s --max-time 5 -4 ifconfig.me \
    || curl -s --max-time 5 -4 api.ipify.org \
    || curl -s --max-time 5 ip4.seeip.org
}

print_mgmt() {
  echo -e "${BOLD}━━━ Управление ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  systemctl status xray"
  echo -e "  journalctl -fu xray"
  echo -e "  ufw status verbose"
  echo ""
}

# ============================================================
# БАЗОВЫЙ UFW (вызывается автоматически при установке ноды)
# Политика: разрешить только SSH/22 и порт Xray — всё остальное
# заблокировано по умолчанию (deny incoming).
# Пункт меню «4)» позволяет дополнительно открыть нужные порты.
# ============================================================

setup_ufw_base() {
  local XRAY_PORT="$1"
  echo -e "${YELLOW}[5/6] Настройка UFW...${NC}"
  ufw --force reset > /dev/null 2>&1
  ufw default deny incoming  > /dev/null 2>&1
  ufw default allow outgoing > /dev/null 2>&1
  ufw default deny forward   > /dev/null 2>&1

  # SSH открыт для всех
  ufw allow 22/tcp > /dev/null 2>&1
  echo -e "${GREEN}  SSH (22/tcp) открыт для всех${NC}"

  # Порт Xray открыт для всех
  ufw allow "$XRAY_PORT"/tcp > /dev/null 2>&1
  echo -e "${GREEN}  Xray ($XRAY_PORT/tcp) открыт для всех${NC}"

  ufw --force enable > /dev/null 2>&1
  conntrack -F 2>/dev/null || true
  echo -e "${GREEN}  UFW активирован — все остальные входящие порты закрыты${NC}"
  echo -e "${YELLOW}  ℹ️  Открыть дополнительные порты — пункт меню «4) Настройка портов»${NC}"
}

# ============================================================
# ЕВРО-НОДА
# ============================================================

setup_euro() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║        ЕВРО-НОДА (выходная) Setup        ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"

  XRAY_PORT=443
  SNI_DONOR="www.amd.com"
  XHTTP_PATH="/"

  install_deps
  install_xray

  # ---------- ключи ----------
  echo -e "${YELLOW}[3/6] Генерация ключей Reality...${NC}"
  KEYS=$($XRAY_BIN x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep -i "^PrivateKey" | awk '{print $NF}')
  PUBLIC_KEY=$(echo "$KEYS"  | grep -i "^Password"   | awk '{print $NF}')
  [[ -z "$PRIVATE_KEY" ]] && PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
  [[ -z "$PUBLIC_KEY"  ]] && PUBLIC_KEY=$(echo "$KEYS"  | grep -i "public"  | awk '{print $NF}')

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}Ошибка генерации ключей:${NC}"; echo "$KEYS"; exit 1
  fi

  UUID=$(uuidgen)
  SHORT_ID=$(openssl rand -hex 8)
  echo -e "${GREEN}  UUID:       $UUID${NC}"
  echo -e "${GREEN}  Short ID:   $SHORT_ID${NC}"
  echo -e "${GREEN}  Public key: $PUBLIC_KEY${NC}"

  # ---------- конфиг ----------
  echo -e "${YELLOW}[4/6] Запись конфига...${NC}"
  mkdir -p "$XRAY_DIR"

  cat > "$XRAY_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["1.1.1.1", "8.8.8.8"] },
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI_DONOR}:443",
        "xver": 0,
        "serverNames": ["$SNI_DONOR"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      },
      "xhttpSettings": {
        "path": "$XHTTP_PATH",
        "mode": "auto",
        "extra": { "xPaddingBytes": "100-1000" }
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"]
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "tag": "direct",
    "settings": { "domainStrategy": "UseIPv4" }
  }]
}
EOF

  # ---------- Post-Quantum ML-KEM-768 ----------
  echo -e "${YELLOW}  Активация Post-Quantum ML-KEM-768...${NC}"
  python3 << PYEOF
import subprocess, json

out = subprocess.check_output(["/usr/local/bin/xray", "vlessenc"]).decode()
lines = out.strip().split("\n")

decrypt_lines = [l for l in lines if '"decryption"' in l]
encrypt_lines = [l for l in lines if '"encryption"' in l]

pq_decrypt = decrypt_lines[1].split('"decryption": "')[1].rstrip('"') if len(decrypt_lines) > 1 else None
pq_encrypt  = encrypt_lines[1].split('"encryption": "')[1].rstrip('"')  if len(encrypt_lines) > 1 else None

if pq_decrypt:
    with open("/usr/local/etc/xray/config.json") as f:
        cfg = json.load(f)
    cfg["inbounds"][0]["settings"]["decryption"] = pq_decrypt
    with open("/usr/local/etc/xray/config.json", "w") as f:
        json.dump(cfg, f, indent=2)
    with open("/tmp/pq_encrypt.txt", "w") as f:
        f.write(pq_encrypt or "none")
    print("  PQ OK: " + (pq_decrypt[:40] + "..."))
else:
    with open("/tmp/pq_encrypt.txt", "w") as f:
        f.write("none")
    print("  PQ: не поддерживается этой версией Xray")
PYEOF

  apply_sysctl
  setup_ufw_base "$XRAY_PORT"
  start_xray

  SERVER_IP=$(get_server_ip)
  PQ_ENC=$(cat /tmp/pq_encrypt.txt 2>/dev/null || echo "none")

  # ---------- сохраняем данные для РФ-ноды ----------
  mkdir -p "$XRAY_DIR"
  cat > "$STATE_FILE" << CONF
EURO_IP=$SERVER_IP
EURO_PORT=$XRAY_PORT
EURO_UUID=$UUID
EURO_PUBLIC_KEY=$PUBLIC_KEY
EURO_SHORT_ID=$SHORT_ID
EURO_SNI=$SNI_DONOR
EURO_ENCRYPTION=$PQ_ENC
CONF
  echo -e "${GREEN}  Данные Евро-ноды сохранены → $STATE_FILE${NC}"

  # ---------- итог ----------
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         ЕВРО-НОДА НАСТРОЕНА — СОХРАНИ ДАННЫЕ        ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "${BOLD}━━━ Данные для РФ-ноды ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  EURO_IP=$SERVER_IP"
  echo -e "  EURO_PORT=$XRAY_PORT"
  echo -e "  EURO_UUID=$UUID"
  echo -e "  EURO_PUBLIC_KEY=$PUBLIC_KEY"
  echo -e "  EURO_SHORT_ID=$SHORT_ID"
  echo -e "  EURO_SNI=$SNI_DONOR"
  echo -e "  (сохранено в $STATE_FILE)"
  echo ""

  echo -e "${BOLD}━━━ VLESS URI (прямое подключение) ━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=${PQ_ENC}&security=reality&sni=${SNI_DONOR}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F&mode=auto#EURO-Reality-PQ${NC}"
  echo ""

  echo -e "${BOLD}━━━ Проверка Reality ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  curl -v https://${SERVER_IP} --resolve ${SNI_DONOR}:443:${SERVER_IP}"
  echo ""

  print_mgmt

  echo -e "${YELLOW}  ⚠️  Следующий шаг: запусти setup-xray.sh rf на РФ-сервере${NC}"
  echo -e "${YELLOW}     Скопируй файл $STATE_FILE или введи данные вручную${NC}"
}

# ============================================================
# РФ-НОДА
# ============================================================

setup_rf() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║        РФ-НОДА (мост/входная) Setup      ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"

  CLIENT_PORT=443
  RF_SNI="vkvideo.ru"

  # ---------- данные евро-ноды ----------
  echo -e "${YELLOW}━━━ Данные Евро-ноды ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Пробуем загрузить из сохранённого файла
  if [[ -f "$STATE_FILE" ]]; then
    echo -e "${GREEN}  Найден файл конфигурации: $STATE_FILE${NC}"
    echo -e "  Загрузить данные из файла? [Y/n]: \c"
    read -r LOAD_CONF
    if [[ -z "$LOAD_CONF" || "$LOAD_CONF" =~ ^[Yy]$ ]]; then
      source "$STATE_FILE"
      echo -e "${GREEN}  Данные загружены:${NC}"
      echo -e "    EURO_IP=$EURO_IP"
      echo -e "    EURO_PORT=$EURO_PORT"
      echo -e "    EURO_UUID=$EURO_UUID"
    fi
  fi

  # Если данных нет — вводим вручную
  if [[ -z "$EURO_IP" ]]; then
    echo -e "  ${BOLD}Введите данные Евро-ноды вручную:${NC}"
    read -rp "  EURO_IP: " EURO_IP
    read -rp "  EURO_PORT [443]: " EURO_PORT
    EURO_PORT=${EURO_PORT:-443}
    read -rp "  EURO_UUID: " EURO_UUID
    read -rp "  EURO_PUBLIC_KEY: " EURO_PUBLIC_KEY
    read -rp "  EURO_SHORT_ID: " EURO_SHORT_ID
    read -rp "  EURO_SNI [www.amd.com]: " EURO_SNI
    EURO_SNI=${EURO_SNI:-www.amd.com}
    read -rp "  EURO_ENCRYPTION [none]: " EURO_ENCRYPTION
    EURO_ENCRYPTION=${EURO_ENCRYPTION:-none}
  fi

  # Проверка обязательных полей
  for VAR in EURO_IP EURO_UUID EURO_PUBLIC_KEY EURO_SHORT_ID; do
    if [[ -z "${!VAR}" ]]; then
      echo -e "${RED}  Ошибка: $VAR не задан${NC}"; exit 1
    fi
  done
  EURO_PORT=${EURO_PORT:-443}
  EURO_SNI=${EURO_SNI:-www.amd.com}
  EURO_ENCRYPTION=${EURO_ENCRYPTION:-none}

  install_deps
  install_xray

  # ---------- ключи клиентов ----------
  echo -e "${YELLOW}[3/6] Генерация ключей Reality для клиентов...${NC}"
  KEYS=$($XRAY_BIN x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep -i "^PrivateKey" | awk '{print $NF}')
  PUBLIC_KEY=$(echo "$KEYS"  | grep -i "^Password"   | awk '{print $NF}')
  [[ -z "$PRIVATE_KEY" ]] && PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
  [[ -z "$PUBLIC_KEY"  ]] && PUBLIC_KEY=$(echo "$KEYS"  | grep -i "public"  | awk '{print $NF}')

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}Ошибка генерации ключей:${NC}"; echo "$KEYS"; exit 1
  fi

  UUID=$(uuidgen)
  SHORT_ID=$(openssl rand -hex 8)
  echo -e "${GREEN}  UUID:       $UUID${NC}"
  echo -e "${GREEN}  Short ID:   $SHORT_ID${NC}"
  echo -e "${GREEN}  Public key: $PUBLIC_KEY${NC}"
  echo -e "${GREEN}  SNI:        $RF_SNI${NC}"

  # ---------- конфиг ----------
  echo -e "${YELLOW}[4/6] Запись конфига...${NC}"

  export UUID PRIVATE_KEY SHORT_ID RF_SNI CLIENT_PORT
  export EURO_IP EURO_PORT EURO_UUID EURO_PUBLIC_KEY EURO_SHORT_ID EURO_SNI EURO_ENCRYPTION

  python3 << 'PYEOF'
import json, os, subprocess

# PQ ключи для входящих клиентов
_out = subprocess.check_output(["/usr/local/bin/xray", "vlessenc"]).decode()
_dec = [l for l in _out.split("\n") if '"decryption"' in l]
_enc = [l for l in _out.split("\n") if '"encryption"' in l]
pq_decryption = _dec[1].split('"decryption": "')[1].rstrip('"') if len(_dec) > 1 else "none"
pq_encryption  = _enc[1].split('"encryption": "')[1].rstrip('"')  if len(_enc) > 1 else "none"

config = {
    "log": {"loglevel": "warning"},
    "dns": {
        "servers": [
            {"address": "223.5.5.5", "domains": ["geosite:category-ru", "geosite:yandex"]},
            "1.1.1.1",
            "8.8.8.8"
        ]
    },
    "inbounds": [{
        "tag": "inbound-clients",
        "port": int(os.environ["CLIENT_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": os.environ["UUID"]}],
            "decryption": pq_decryption
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": os.environ["RF_SNI"] + ":443",
                "xver": 0,
                "serverNames": [os.environ["RF_SNI"]],
                "privateKey": os.environ["PRIVATE_KEY"],
                "shortIds": [os.environ["SHORT_ID"]]
            },
            "xhttpSettings": {
                "path": "/",
                "mode": "packet-up",
                "extra": {"xPaddingBytes": "100-1000"}
            }
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic", "fakedns"]
        }
    }],
    "outbounds": [
        {
            "tag": "chain-to-euro",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": os.environ["EURO_IP"],
                    "port": int(os.environ["EURO_PORT"]),
                    "users": [{
                        "id": os.environ["EURO_UUID"],
                        "encryption": os.environ["EURO_ENCRYPTION"]
                    }]
                }]
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "fingerprint": "randomized",
                    "serverName": os.environ["EURO_SNI"],
                    "publicKey": os.environ["EURO_PUBLIC_KEY"],
                    "shortId": os.environ["EURO_SHORT_ID"]
                },
                "xhttpSettings": {
                    "path": "/",
                    "mode": "auto"
                }
            }
        },
        {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {"domainStrategy": "UseIPv4"}
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "outboundTag": "block",
                "ip": ["geoip:private"],
                "domain": ["geosite:category-ads-all"]
            },
            {
                "type": "field",
                "outboundTag": "direct",
                "domain": [
                    "geosite:category-ru",
                    "geosite:yandex",
                    "regexp:\\.ru$",
                    "full:cp.cloudflare.com"
                ]
            },
            {
                "type": "field",
                "outboundTag": "direct",
                "ip": ["geoip:ru"]
            },
            {
                "type": "field",
                "inboundTag": ["inbound-clients"],
                "outboundTag": "chain-to-euro"
            }
        ]
    }
}

with open("/usr/local/etc/xray/config.json", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

with open("/tmp/pq_encrypt_rf.txt", "w") as f:
    f.write(pq_encryption)

print("  Config OK | PQ decryption: " + pq_decryption[:40] + "...")
PYEOF

  apply_sysctl
  setup_ufw_base "$CLIENT_PORT"
  start_xray

  SERVER_IP=$(get_server_ip)
  PQ_ENC_RF=$(cat /tmp/pq_encrypt_rf.txt 2>/dev/null || echo "none")

  # ---------- итог ----------
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║            РФ-НОДА НАСТРОЕНА УСПЕШНО                ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "${BOLD}━━━ Схема трафика ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Клиент → РФ-нода:$CLIENT_PORT → Евро-нода ($EURO_IP):$EURO_PORT → Интернет"
  echo ""

  echo -e "${BOLD}━━━ VLESS URI для клиента (v2rayTUN / Hiddify) ━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}vless://${UUID}@${SERVER_IP}:${CLIENT_PORT}?encryption=${PQ_ENC_RF}&security=reality&sni=${RF_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F&mode=packet-up#RF-Bridge-PQ${NC}"
  echo ""

  echo -e "${BOLD}━━━ Роутинг ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ✅ geosite:category-ru, geosite:yandex, geoip:ru, .ru → DIRECT"
  echo -e "  🚫 geosite:ads → BLOCK"
  echo -e "  🌍 Всё остальное → Евро-нода ($EURO_IP)"
  echo ""

  print_mgmt
}

# ============================================================
# УПРАВЛЕНИЕ ПОРТАМИ
# ============================================================

manage_ports() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║            НАСТРОЙКА ПОРТОВ (UFW)                   ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  # Определяем порт Xray из конфига
  XRAY_LISTEN_PORT=""
  if [[ -f "$XRAY_DIR/config.json" ]]; then
    XRAY_LISTEN_PORT=$(python3 -c "
import json
try:
    with open('$XRAY_DIR/config.json') as f:
        c = json.load(f)
    print(c['inbounds'][0]['port'])
except:
    print('')
" 2>/dev/null)
  fi

  echo -e "${BOLD}━━━ Текущие разрешённые входящие порты (UFW) ━━━━━━━━━━━━━━━${NC}"
  if ufw status | grep -q "Status: active"; then
    echo -e "  ${GREEN}● UFW активен${NC}"
  else
    echo -e "  ${RED}● UFW неактивен${NC}"
  fi

  if [[ -n "$XRAY_LISTEN_PORT" ]]; then
    echo -e "  Xray слушает на порту: ${BOLD}$XRAY_LISTEN_PORT${NC}"
  else
    echo -e "  ${YELLOW}Xray конфиг не найден — порт неизвестен${NC}"
  fi
  echo ""

  # Показываем текущие ALLOW правила
  CURRENT_ALLOWS=$(ufw status | grep "ALLOW" | grep -v "ALLOW FWD" || true)
  if [[ -n "$CURRENT_ALLOWS" ]]; then
    echo -e "  Сейчас разрешено:"
    echo "$CURRENT_ALLOWS" | while read -r line; do
      echo -e "    ${GREEN}$line${NC}"
    done
  else
    echo -e "  ${YELLOW}Нет явных ALLOW правил (всё входящее закрыто)${NC}"
  fi
  echo ""

  echo -e "${BOLD}━━━ Открыть дополнительный порт ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  По умолчанию разрешены только:"
  echo -e "    ${GREEN}22/tcp${NC}   — SSH"
  if [[ -n "$XRAY_LISTEN_PORT" ]]; then
    echo -e "    ${GREEN}$XRAY_LISTEN_PORT/tcp${NC} — Xray (VLESS)"
  fi
  echo -e "  Всё остальное — закрыто."
  echo ""
  echo -e "  Введите порты для открытия через пробел (или Enter чтобы выйти):"
  echo -n "  > "
  read -r EXTRA_INPUT

  if [[ -z "$EXTRA_INPUT" ]]; then
    echo -e "${YELLOW}  Без изменений.${NC}"
    return
  fi

  TO_OPEN=()
  for P in $EXTRA_INPUT; do
    if [[ "$P" =~ ^[0-9]+$ ]] && (( P >= 1 && P <= 65535 )); then
      if [[ "$P" == "22" ]]; then
        echo -e "  ${CYAN}Порт 22 (SSH) уже открыт — пропущен${NC}"
      elif [[ "$P" == "$XRAY_LISTEN_PORT" ]]; then
        echo -e "  ${CYAN}Порт $P (Xray) уже открыт — пропущен${NC}"
      else
        TO_OPEN+=("$P")
      fi
    else
      echo -e "  ${RED}Некорректный порт: $P — пропущен${NC}"
    fi
  done

  if [[ ${#TO_OPEN[@]} -eq 0 ]]; then
    echo -e "${YELLOW}  Нечего открывать.${NC}"
    return
  fi

  echo ""
  echo -e "${BOLD}━━━ Итог: будет открыто ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  for P in "${TO_OPEN[@]}"; do
    echo -e "  ${GREEN}ufw allow $P/tcp${NC}"
  done
  echo ""

  echo -n "  Применить? [y/N]: "
  read -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}  Отменено.${NC}"
    return
  fi

  echo ""
  echo -e "${YELLOW}  Применяю правила...${NC}"
  for PORT in "${TO_OPEN[@]}"; do
    ufw allow "$PORT"/tcp > /dev/null 2>&1
    echo -e "  ${GREEN}✅ Открыт: $PORT/tcp${NC}"
  done
  ufw reload > /dev/null 2>&1
  echo ""
  echo -e "${BOLD}━━━ Текущие разрешённые порты ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  ufw status | grep "ALLOW" | grep -v "ALLOW FWD" | while read -r line; do
    echo -e "  ${GREEN}$line${NC}"
  done
  echo ""
}



show_status() {
  echo -e "${CYAN}${BOLD}━━━ Статус Xray ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "  ${GREEN}● Xray: активен${NC}"
    echo -e "  Uptime: $(systemctl show xray --property=ActiveEnterTimestamp | cut -d= -f2)"
  else
    echo -e "  ${RED}● Xray: не запущен${NC}"
  fi

  echo ""
  echo -e "${CYAN}${BOLD}━━━ Конфигурация ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [[ -f "$XRAY_DIR/config.json" ]]; then
    python3 -c "
import json
with open('$XRAY_DIR/config.json') as f:
    c = json.load(f)
ib = c['inbounds'][0]
print(f'  Порт:     {ib[\"port\"]}')
print(f'  Протокол: {ib[\"protocol\"]}')
print(f'  Сеть:     {ib[\"streamSettings\"][\"network\"]}')
print(f'  Security: {ib[\"streamSettings\"][\"security\"]}')
ob = c['outbounds']
tags = [o['tag'] for o in ob]
print(f'  Outbounds: {tags}')
" 2>/dev/null || echo -e "  ${YELLOW}Не удалось разобрать конфиг${NC}"
  else
    echo -e "  ${YELLOW}Конфиг не найден${NC}"
  fi

  echo ""
  echo -e "${CYAN}${BOLD}━━━ Сохранённые данные Евро-ноды ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [[ -f "$STATE_FILE" ]]; then
    grep -v "ENCRYPTION" "$STATE_FILE" || true
    echo -e "  EURO_ENCRYPTION=<...длинная строка PQ...>"
  else
    echo -e "  ${YELLOW}Файл $STATE_FILE не найден${NC}"
  fi
  echo ""
}

# ============================================================
# МЕНЮ
# ============================================================

show_menu() {
  print_banner
  echo -e "${BOLD}  Выберите действие:${NC}"
  echo ""
  echo -e "  ${GREEN}1)${NC} Настроить ${BOLD}Евро-ноду${NC} (выходная, VPS за рубежом)"
  echo -e "  ${GREEN}2)${NC} Настроить ${BOLD}РФ-ноду${NC}   (входная, VPS в России)"
  echo -e "  ${GREEN}3)${NC} Показать  ${BOLD}статус${NC}    (текущая нода)"
  echo -e "  ${GREEN}4)${NC} Настройка ${BOLD}портов${NC}    (закрытие опасных портов UFW)"
  echo -e "  ${GREEN}0)${NC} Выход"
  echo ""
  echo -n "  Ваш выбор [0-4]: "
  read -r CHOICE

  case "$CHOICE" in
    1) setup_euro   ;;
    2) setup_rf     ;;
    3) show_status  ;;
    4) manage_ports ;;
    0) echo -e "${CYAN}Выход.${NC}"; exit 0 ;;
    *) echo -e "${RED}Неверный выбор${NC}"; show_menu ;;
  esac
}

# ============================================================
# ТОЧКА ВХОДА
# ============================================================

check_root

case "${1:-}" in
  euro)   setup_euro   ;;
  rf)     setup_rf     ;;
  status) show_status  ;;
  ports)  manage_ports ;;
  *)      show_menu    ;;
esac
