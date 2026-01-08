#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian L2TP/IPsec 一键搭建脚本
# 组件：strongSwan(IPsec) + xl2tpd(L2TP) + ppp(CHAP)
# 适配：Debian 10/11/12（Debian 12 使用 strongswan-starter）
# 用法：bash l2tp_install.sh [L2TP_PORT]
# =========================

L2TP_PORT="${1:-1701}"

# ---------- 日志：同时输出到控制台与文件 ----------
TS_NOW="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/root/l2tp_安装日志_${TS_NOW}.log"

log() { echo -e "[$(date '+%F %T')] $*"; }
ok()  { log "✅ $*"; }
warn(){ log "⚠️ $*"; }
die() { log "❌ $*"; exit 1; }

# 所有输出同时 tee 到文件
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- 基础检查 ----------
[[ $EUID -eq 0 ]] || die "请用 root 执行：sudo bash $0 [端口]"

if [[ "$L2TP_PORT" != "1701" ]]; then
  warn "你设置的 L2TP 端口是 ${L2TP_PORT}。多数系统自带 L2TP 客户端只支持 UDP 1701，可能无法连接。"
fi

IFACE="$(ip -4 route list default 2>/dev/null | awk '{print $5}' | head -n1 || true)"
[[ -n "${IFACE}" ]] || die "无法检测默认出口网卡（没有默认路由？）"
ok "检测到出口网卡：${IFACE}"

# ---------- 生成随机凭据（避免 pipefail/SIGPIPE 退出） ----------
gen_rand() {
  local n="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${n}" || true
  else
    dd if=/dev/urandom bs=1 count=256 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${n}" || true
  fi
}

VPN_USER="u$(gen_rand 10)"
VPN_PASS="$(gen_rand 18)"
VPN_PSK="$(gen_rand 24)"

VPN_NET="10.0.0.0/24"
VPN_LOCAL="10.0.0.1"
VPN_RANGE_START="10.0.0.10"
VPN_RANGE_END="10.0.0.100"

log "============================================================"
log "🔧 开始安装 L2TP/IPsec（Debian）"
log "📌 L2TP 端口：UDP ${L2TP_PORT}"
log "🧾 日志文件：${LOG_FILE}"
log "============================================================"

# ---------- 安装依赖 ----------
log "==> 1/6 安装依赖软件包（strongSwan/xl2tpd/ppp/iptables）..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y strongswan xl2tpd ppp iptables iptables-persistent openssl
ok "依赖安装完成"

# ---------- 写 strongSwan 配置 ----------
log "==> 2/6 写入 strongSwan(IPsec) 配置..."
cat >/etc/ipsec.conf <<EOF
config setup
  uniqueids=no

conn l2tp-psk
  keyexchange=ikev1
  authby=psk
  type=transport
  left=%any
  leftprotoport=17/${L2TP_PORT}
  right=%any
  rightprotoport=17/%any
  auto=add
EOF

cat >/etc/ipsec.secrets <<EOF
%any %any : PSK "${VPN_PSK}"
EOF
chmod 600 /etc/ipsec.secrets
ok "IPsec 配置写入完成（/etc/ipsec.conf, /etc/ipsec.secrets）"

# ---------- 写 xl2tpd 配置 ----------
log "==> 3/6 写入 xl2tpd(L2TP) 配置..."
mkdir -p /etc/xl2tpd
cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = ${L2TP_PORT}
ipsec saref = yes

[lns default]
ip range = ${VPN_RANGE_START}-${VPN_RANGE_END}
local ip = ${VPN_LOCAL}
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
ok "xl2tpd 配置写入完成（/etc/xl2tpd/xl2tpd.conf）"

# ---------- PPP 配置 + 用户 ----------
log "==> 4/6 配置 PPP 并创建账号..."
cat >/etc/ppp/options.xl2tpd <<'EOF'
ipcp-accept-local
ipcp-accept-remote
ms-dns 1.1.1.1
ms-dns 8.8.8.8
noccp
auth
hide-password
idle 1800
mtu 1400
mru 1400
nodefaultroute
debug
lock
proxyarp
connect-delay 5000
EOF

touch /etc/ppp/chap-secrets
# 防止重复：移除同名用户旧条目
grep -vE "^[[:space:]]*${VPN_USER}[[:space:]]+" /etc/ppp/chap-secrets > /etc/ppp/chap-secrets.tmp || true
mv /etc/ppp/chap-secrets.tmp /etc/ppp/chap-secrets
echo "${VPN_USER}  l2tpd  ${VPN_PASS}  *" >> /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets
ok "PPP 配置与账号创建完成（/etc/ppp/options.xl2tpd, /etc/ppp/chap-secrets）"

# ---------- 开启转发 ----------
log "==> 5/6 开启 IPv4 转发..."
if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1\s*$' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IPv4 转发已开启"

# ---------- NAT + 放行端口 ----------
log "==> 6/6 配置 NAT 与放行端口（iptables）..."
iptables -t nat -C POSTROUTING -s "${VPN_NET}" -o "${IFACE}" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "${VPN_NET}" -o "${IFACE}" -j MASQUERADE

iptables -C FORWARD -s "${VPN_NET}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "${VPN_NET}" -j ACCEPT
iptables -C FORWARD -d "${VPN_NET}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "${VPN_NET}" -j ACCEPT

iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 500 -j ACCEPT
iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -C INPUT -p udp --dport "${L2TP_PORT}" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "${L2TP_PORT}" -j ACCEPT

netfilter-persistent save >/dev/null || true
ok "iptables 已配置并持久化（netfilter-persistent）"

# ---------- Debian 12 服务名兼容 ----------
log "==> 重启服务..."
SS_SERVICE="strongswan-starter"
if systemctl list-unit-files | grep -q '^strongswan\.service'; then
  SS_SERVICE="strongswan"
fi

systemctl restart "${SS_SERVICE}"
systemctl restart xl2tpd
systemctl enable "${SS_SERVICE}" xl2tpd >/dev/null
ok "服务已重启并设置开机自启：${SS_SERVICE}, xl2tpd"

# ---------- 写连接信息文件 ----------
PUB_IP="$(curl -fsSL ip.sb 2>/dev/null || true)"
OUT_FILE="/root/l2tp_credentials.txt"

cat >"${OUT_FILE}" <<EOF
L2TP/IPsec VPN 连接信息
========================
服务器地址: ${PUB_IP:-<请填写你的公网IP或域名>}
VPN 类型 : L2TP/IPsec PSK
预共享密钥: ${VPN_PSK}
用户名   : ${VPN_USER}
密码     : ${VPN_PASS}
L2TP 端口 : ${L2TP_PORT}

注意事项：
1) 云服务器安全组也必须放行：UDP 500 / 4500 / ${L2TP_PORT}
2) 建议端口保持 1701（系统自带客户端兼容性最好）
3) 已启用 NAT：${VPN_NET} -> ${IFACE}
EOF
chmod 600 "${OUT_FILE}"
ok "连接信息已保存到：${OUT_FILE}"

# ---------- 最终美观输出 ----------
echo
echo "╔══════════════════════════════════════════════╗"
echo "║              🎉 安装完成（L2TP/IPsec）       ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  服务器地址   : %-28s ║\n" "${PUB_IP:-<你的公网IP或域名>}"
printf "║  VPN 类型     : %-28s ║\n" "L2TP/IPsec PSK"
printf "║  预共享密钥PSK: %-28s ║\n" "${VPN_PSK}"
printf "║  用户名       : %-28s ║\n" "${VPN_USER}"
printf "║  密码         : %-28s ║\n" "${VPN_PASS}"
printf "║  L2TP 端口    : %-28s ║\n" "${L2TP_PORT}"
echo "╠══════════════════════════════════════════════╣"
printf "║  连接信息文件 : %-28s ║\n" "${OUT_FILE}"
printf "║  安装日志文件 : %-28s ║\n" "${LOG_FILE}"
echo "╚══════════════════════════════════════════════╝"
echo

log "==> 服务状态（供快速排查）"
systemctl --no-pager -l status "${SS_SERVICE}" || true
systemctl --no-pager -l status xl2tpd || true

log "==> 端口监听检查（500/4500/1701）"
ss -ulpn | egrep ':(500|4500|1701)\b' || true
