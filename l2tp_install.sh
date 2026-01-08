#!/usr/bin/env bash
set -euo pipefail

L2TP_PORT="${1:-1701}"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0 [L2TP_PORT]"
  exit 1
fi

# 强提示：改端口可能不兼容系统自带客户端
if [[ "$L2TP_PORT" != "1701" ]]; then
  echo "⚠️ 警告：你把 L2TP 端口改成了 $L2TP_PORT。多数系统自带 L2TP 客户端仅支持 UDP 1701，可能无法连接。"
fi

# 检测默认出口网卡
IFACE="$(ip -4 route list default 2>/dev/null | awk '{print $5}' | head -n1)"
if [[ -z "${IFACE:-}" ]]; then
  echo "无法检测默认网卡，请确保机器有默认路由。"
  exit 1
fi

# 生成随机凭据
gen_rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
VPN_USER="u$(gen_rand 10)"
VPN_PASS="$(gen_rand 18)"
VPN_PSK="$(gen_rand 24)"

VPN_NET="10.0.0.0/24"
VPN_LOCAL="10.0.0.1"
VPN_RANGE_START="10.0.0.10"
VPN_RANGE_END="10.0.0.100"

echo "==> 安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y strongswan xl2tpd ppp iptables iptables-persistent >/dev/null

echo "==> 写入 strongSwan(IPsec) 配置..."
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

echo "==> 写入 xl2tpd(L2TP) 配置..."
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

echo "==> 写入 PPP 配置..."
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

echo "==> 创建 VPN 用户..."
# chap-secrets: client  server  secret  IPs
grep -qE '^\s*'"${VPN_USER}"'\s' /etc/ppp/chap-secrets 2>/dev/null && \
  sed -i.bak -E 's/^(\s*'"${VPN_USER}"'\s+).*/'"${VPN_USER}"'  l2tpd  '"${VPN_PASS}"'  */' /etc/ppp/chap-secrets || true

echo "${VPN_USER}  l2tpd  ${VPN_PASS}  *" >> /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets

echo "==> 开启 IP 转发..."
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "==> 配置 NAT 与放行端口..."
# NAT
iptables -t nat -C POSTROUTING -s "${VPN_NET}" -o "${IFACE}" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "${VPN_NET}" -o "${IFACE}" -j MASQUERADE

iptables -C FORWARD -s "${VPN_NET}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "${VPN_NET}" -j ACCEPT
iptables -C FORWARD -d "${VPN_NET}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "${VPN_NET}" -j ACCEPT

# INPUT allow IPsec + L2TP
iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 500 -j ACCEPT
iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -C INPUT -p udp --dport "${L2TP_PORT}" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "${L2TP_PORT}" -j ACCEPT

netfilter-persistent save >/dev/null || true

echo "==> 重启并开机自启服务..."
systemctl restart strongswan
systemctl restart xl2tpd
systemctl enable strongswan xl2tpd >/dev/null

# 保存一份到文件，方便你以后查
OUT_FILE="/root/l2tp_credentials.txt"
cat >"${OUT_FILE}" <<EOF
L2TP/IPsec VPN 信息
====================
Server IP: (请填你的公网 IP 或域名)
VPN Type: L2TP/IPsec PSK
IPsec PSK: ${VPN_PSK}
Username:  ${VPN_USER}
Password:  ${VPN_PASS}
L2TP Port: ${L2TP_PORT}

Notes:
- 推荐端口保持 1701（系统自带客户端兼容性最好）
- 已启用 NAT: ${VPN_NET} -> ${IFACE}
EOF
chmod 600 "${OUT_FILE}"

echo
echo "✅ 安装完成！连接信息如下："
echo "----------------------------------------"
echo "VPN 类型: L2TP/IPsec PSK"
echo "IPsec PSK: ${VPN_PSK}"
echo "用户名:    ${VPN_USER}"
echo "密码:      ${VPN_PASS}"
echo "L2TP 端口: ${L2TP_PORT}"
echo "默认网卡:  ${IFACE}"
echo "已保存到:  ${OUT_FILE}"
echo "----------------------------------------"
echo "客户端里服务器地址请填：你的公网 IP 或域名"
