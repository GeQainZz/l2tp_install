#!/usr/bin/env bash
set -euo pipefail

# =========================
# CentOS 7 L2TP/IPsec 一键搭建脚本
# 适配系统：CentOS 7 (x86_64)
# 功能：自动配置 EPEL, StrongSwan, xl2tpd, ppp, iptables
#
# 用法：
#   1. 标准安装 (默认端口 1701)
#      bash l2tp_centos7.sh
#
#   2. 指定端口安装
#      bash l2tp_centos7.sh 1701
#
#   3. 无痕模式 (不生成日志文件，不保存密码文件到磁盘，只输出到屏幕)
#      bash l2tp_centos7.sh --no-trace
# =========================

# ---------- 参数解析 ----------
L2TP_PORT="1701"
NO_TRACE="false"

# 简单的参数处理循环
for arg in "$@"; do
    case $arg in
        --no-trace)
            NO_TRACE="true"
            ;;
        *)
            # 如果是数字，认为是端口
            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                L2TP_PORT="$arg"
            fi
            ;;
    esac
done

# ---------- 日志设置 ----------
TS_NOW="$(date +%Y%m%d_%H%M%S)"

if [[ "$NO_TRACE" == "true" ]]; then
    # 无痕模式：日志文件指向 /dev/null
    LOG_FILE="/dev/null"
else
    # 正常模式：记录日志
    LOG_FILE="/root/l2tp_安装日志_${TS_NOW}.log"
fi

# 定义日志函数
log() { echo -e "[$(date '+%F %T')] $*"; }
ok()  { log "\033[32m✅ $*\033[0m"; }
warn(){ log "\033[33m⚠️ $*\033[0m"; }
die() { log "\033[31m❌ $*\033[0m"; exit 1; }

# 如果不是无痕模式，将输出同时重定向到文件
if [[ "$NO_TRACE" == "false" ]]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# ---------- 基础检查 ----------
[[ $EUID -eq 0 ]] || die "请用 root 执行：sudo bash $0"

# 检查系统版本是否为 CentOS 7
if [ -f /etc/redhat-release ]; then
    if ! grep -q "CentOS Linux release 7" /etc/redhat-release; then
        warn "检测到系统可能不是 CentOS 7。当前系统：$(cat /etc/redhat-release)"
        read -p "是否继续强制安装？(y/n): " -r REPLY
        [[ $REPLY =~ ^[Yy]$ ]] || die "已取消安装"
    fi
else
    die "未检测到 /etc/redhat-release，本脚本专为 CentOS 7 设计。"
fi

if [[ "$L2TP_PORT" != "1701" ]]; then
    warn "你设置的 L2TP 端口是 ${L2TP_PORT}。注意：Windows 自带客户端通常只支持 1701。"
fi

# 获取出口网卡
IFACE="$(ip -4 route list default 2>/dev/null | awk '{print $5}' | head -n1 || true)"
[[ -n "${IFACE}" ]] || die "无法检测默认出口网卡"
ok "检测到出口网卡：${IFACE}"

# ---------- 生成随机凭据 ----------
gen_rand() {
    local n="${1:-16}"
    # 关键修改：添加 LC_ALL=C 避免字符集错误，添加 || true 避免 pipefail 导致脚本退出
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${n}" || true
}

VPN_USER="u$(gen_rand 8)"
VPN_PASS="$(gen_rand 16)"
VPN_PSK="$(gen_rand 20)"

VPN_NET="10.0.0.0/24"
VPN_LOCAL="10.0.0.1"
VPN_RANGE_START="10.0.0.10"
VPN_RANGE_END="10.0.0.100"

log "============================================================"
log "🔧 开始安装 L2TP/IPsec (CentOS 7)"
log "📌 L2TP 端口：UDP ${L2TP_PORT}"
if [[ "$NO_TRACE" == "true" ]]; then
    log "👻 模式：无痕 (不保存日志和凭据文件)"
else
    log "🧾 日志文件：${LOG_FILE}"
fi
log "============================================================"

# ---------- 1. 安装依赖 (CentOS 7) ----------
log "==> 1/6 安装依赖软件包..."
# 安装 EPEL 源，因为 strongswan 和 xl2tpd 不在标准源中
yum install -y epel-release
# 安装核心组件
yum install -y strongswan xl2tpd ppp iptables-services net-tools wget curl

ok "依赖安装完成"

# ---------- 2. 防火墙切换 (Firewalld -> IPTables) ----------
# 为了保证 iptables 规则的纯净性和兼容性，建议在 VPN 服务器上使用 iptables-services
log "==> 切换防火墙为 iptables-services..."
if systemctl is-active --quiet firewalld; then
    systemctl stop firewalld
    systemctl disable firewalld
    warn "已禁用 firewalld"
fi

systemctl enable iptables
systemctl start iptables
# 清空旧规则
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
ok "iptables 服务已接管"

# ---------- 3. 写入 strongSwan 配置 ----------
log "==> 2/6 写入 strongSwan(IPsec) 配置..."

# CentOS 7 strongswan 配置通常在 /etc/strongswan/ipsec.conf 或 /etc/ipsec.conf
# 这里写入标准位置
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
ok "IPsec 配置写入完成"

# ---------- 4. 写入 xl2tpd 配置 ----------
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
ok "xl2tpd 配置写入完成"

# ---------- 5. PPP 配置 + 用户 ----------
log "==> 4/6 配置 PPP 并创建账号..."
cat >/etc/ppp/options.xl2tpd <<'EOF'
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 1.1.1.1
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
# 移除旧的同名用户（如果有）
grep -vE "^[[:space:]]*${VPN_USER}[[:space:]]+" /etc/ppp/chap-secrets > /etc/ppp/chap-secrets.tmp || true
mv /etc/ppp/chap-secrets.tmp /etc/ppp/chap-secrets
# 添加新用户
echo "${VPN_USER}  l2tpd  ${VPN_PASS}  *" >> /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets
ok "PPP 账号创建完成"

# ---------- 6. 开启内核转发 ----------
log "==> 5/6 开启 IPv4 转发..."
if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1\s*$' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
# 某些 CentOS 环境下需要手动加载 L2TP 模块 (通常不需要，以防万一)
modprobe ppp_lib >/dev/null 2>&1 || true
modprobe ppp_deflate >/dev/null 2>&1 || true

sysctl -p >/dev/null
ok "IPv4 转发已开启"

# ---------- 7. NAT + 放行端口 ----------
log "==> 6/6 配置 iptables..."
# NAT
iptables -t nat -C POSTROUTING -s "${VPN_NET}" -o "${IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${VPN_NET}" -o "${IFACE}" -j MASQUERADE

# FORWARD
iptables -C FORWARD -s "${VPN_NET}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "${VPN_NET}" -j ACCEPT
iptables -C FORWARD -d "${VPN_NET}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "${VPN_NET}" -j ACCEPT

# INPUT (UDP 500, 4500, L2TP端口)
iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 500 -j ACCEPT
iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -C INPUT -p udp --dport "${L2TP_PORT}" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "${L2TP_PORT}" -j ACCEPT

# 保存规则 (CentOS 7 iptables-services)
service iptables save >/dev/null
ok "iptables 规则已保存"

# ---------- 重启服务 ----------
log "==> 重启服务..."
systemctl restart strongswan
systemctl restart xl2tpd
systemctl enable strongswan xl2tpd >/dev/null
ok "服务已启动 (strongswan, xl2tpd)"

# ---------- 获取公网IP ----------
PUB_IP="$(curl -fsSL ip.sb 2>/dev/null || curl -fsSL ifconfig.me 2>/dev/null || echo '<获取失败>')"

# ---------- 准备输出信息 ----------
# 无论是否无痕，先准备好内容
CRED_CONTENT=$(cat <<EOF
L2TP/IPsec VPN 连接信息
========================
服务器地址: ${PUB_IP}
VPN 类型  : L2TP/IPsec PSK
预共享密钥: ${VPN_PSK}
用户名    : ${VPN_USER}
密码      : ${VPN_PASS}
L2TP 端口 : ${L2TP_PORT}
EOF
)

OUT_FILE="/root/l2tp_credentials.txt"

if [[ "$NO_TRACE" == "true" ]]; then
    # 无痕模式：不保存文件
    ok "无痕模式已启用：不保存凭据文件到磁盘。"
    SAVE_MSG="（无痕模式：未保存到文件）"
else
    # 正常模式：保存文件
    echo "$CRED_CONTENT" > "${OUT_FILE}"
    chmod 600 "${OUT_FILE}"
    SAVE_MSG="${OUT_FILE}"
    ok "连接信息已保存到：${OUT_FILE}"
fi

# ---------- 最终显示 ----------
echo
echo -e "\033[36m╔══════════════════════════════════════════════╗\033[0m"
echo -e "\033[36m║             🎉 安装完成                        ║\033[0m"
echo -e "\033[36m╠══════════════════════════════════════════════╣\033[0m"
printf "\033[36m║\033[0m  服务器地址  : %-28s \033[36m║\033[0m\n" "${PUB_IP}"
printf "\033[36m║\033[0m  预共享密钥  : %-28s \033[36m║\033[0m\n" "${VPN_PSK}"
printf "\033[36m║\033[0m  用户名      : %-28s \033[36m║\033[0m\n" "${VPN_USER}"
printf "\033[36m║\033[0m  密码        : %-28s \033[36m║\033[0m\n" "${VPN_PASS}"
echo -e "\033[36m╠══════════════════════════════════════════════╣\033[0m"
printf "\033[36m║\033[0m  凭据保存位置: %-28s \033[36m║\033[0m\n" "${SAVE_MSG}"
echo -e "\033[36m╚══════════════════════════════════════════════╝\033[0m"
echo

log "==> 端口检查："
netstat -nunlp | egrep ":(500|4500|${L2TP_PORT})\b" || true