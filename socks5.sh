#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian 一键搭建 SOCKS5（Dante）
# - 修复 pipefail 下随机生成 SIGPIPE 退出的问题
# - 公网 IP 获取改为：curl --max-time 2 ip.sb
# =========================

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo -i 后再执行"
  exit 1
fi

log()  { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*"; }

# ---- 可自定义项（不想随机就改这里）----
SOCKS_USER="${SOCKS_USER:-socksuser}"
SOCKS_PASS="${SOCKS_PASS:-}"
SOCKS_PORT="${SOCKS_PORT:-}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"

# ---- 安全的随机字符串（避免 pipefail + SIGPIPE）----
rand_str() {
  local n="${1:-16}"
  head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "${n}"
}

# ---- 随机生成密码/端口 ----
if [[ -z "${SOCKS_PASS}" ]]; then
  SOCKS_PASS="$(rand_str 20)"
fi
if [[ -z "${SOCKS_PORT}" ]]; then
  SOCKS_PORT="$(( (RANDOM % 40000) + 20000 ))"
fi

# ---- 安装依赖 ----
export DEBIAN_FRONTEND=noninteractive
log "更新 apt 并安装 dante-server..."
apt-get update -y
apt-get install -y dante-server curl iproute2

# ---- 找到默认出口网卡 ----
IFACE="$(ip route | awk '/default/ {print $5; exit}')"
if [[ -z "${IFACE}" ]]; then
  err "未找到默认网卡（ip route default）。请检查网络配置。"
  exit 1
fi
log "检测到默认出口网卡：${IFACE}"

# ---- 创建系统用户（无登录 shell）----
if id -u "${SOCKS_USER}" >/dev/null 2>&1; then
  warn "用户 ${SOCKS_USER} 已存在，将更新其密码。"
else
  log "创建用户：${SOCKS_USER}"
  useradd -M -s /usr/sbin/nologin "${SOCKS_USER}"
fi
echo "${SOCKS_USER}:${SOCKS_PASS}" | chpasswd
log "已设置/更新 ${SOCKS_USER} 密码"

# ---- 备份并写入 Dante 配置 ----
CONF="/etc/danted.conf"
if [[ -f "${CONF}" ]]; then
  cp -a "${CONF}" "${CONF}.bak.$(date +%F_%H%M%S)"
  log "已备份原配置到 ${CONF}.bak.*"
fi

cat > "${CONF}" <<EOF
logoutput: syslog

internal: ${LISTEN_ADDR} port = ${SOCKS_PORT}
external: ${IFACE}

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect bind udpassociate
  log: connect disconnect error
  socksmethod: username
}
EOF

chmod 600 "${CONF}"
log "已写入 Dante 配置：${CONF}"

# ---- 启动并设置自启（Debian 包的服务名通常是 danted）----
log "启动 danted 并设置开机自启..."
systemctl daemon-reload || true

UNIT=""
if systemctl list-unit-files | grep -q '^danted\.service'; then
  UNIT="danted"
elif systemctl list-unit-files | grep -q '^dante-server\.service'; then
  UNIT="dante-server"
else
  UNIT="danted"
fi

systemctl enable --now "${UNIT}" || {
  err "启动服务失败，输出状态和日志："
  systemctl status "${UNIT}" --no-pager -l || true
  journalctl -u "${UNIT}" --no-pager -n 200 || true
  exit 1
}

sleep 1
if systemctl is-active --quiet "${UNIT}"; then
  log "${UNIT} 运行正常"
else
  err "${UNIT} 未正常运行，最近日志："
  journalctl -u "${UNIT}" --no-pager -n 200 || true
  exit 1
fi

# ---- 获取公网 IP：改为 ip.sb ----
PUBLIC_IP="$(curl -s --max-time 2 ip.sb 2>/dev/null | tr -d ' \r\n' || true)"

echo
echo "==================== SOCKS5 节点信息 ===================="
echo "服务名       : ${UNIT}"
echo "服务器公网 IP : ${PUBLIC_IP:-<获取失败，请填你的服务器IP>}"
echo "监听地址     : ${LISTEN_ADDR}"
echo "端口         : ${SOCKS_PORT}"
echo "用户名       : ${SOCKS_USER}"
echo "密码         : ${SOCKS_PASS}"
echo
echo "连接串示例："
echo "socks5://${SOCKS_USER}:${SOCKS_PASS}@${PUBLIC_IP:-<你的服务器IP>}:${SOCKS_PORT}"
echo
echo "查看日志："
echo "journalctl -u ${UNIT} -f"
echo "========================================================="
echo

warn "若云服务器有安全组/防火墙，请放行 TCP 端口 ${SOCKS_PORT}。"