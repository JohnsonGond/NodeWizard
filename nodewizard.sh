#!/usr/bin/env bash
# ==============================================================================
#                 _   _           _     __        ___                  _ 
#                | \ | | ___   __| | ___\ \      / (_)______ _ _ __ __| |
#                |  \| |/ _ \ / _` |/ _ \\ \ /\ / /| |_  / _` | '__/ _` |
#                | |\  | (_) | (_| |  __/ \ V  V / | |/ / (_| | | | (_| |
#                |_| \_|\___/ \__,_|\___|  \_/\_/  |_/___|\__,_|_|  \__,_|
#
#        🧙‍♂️ Cloud Infrastructure Node Provisioning Wizard (NodeWizard)
# ==============================================================================
# 适用系统: Debian 11/12+, Ubuntu 22.04/24.04+ (x86_64 / arm64)
# 核心特性:
#   1. 交互式导航: 启动菜单控制，支持“全量交付”、“配置巡检”、“安全加固”、“仅代理核心”、“提取链接”、“IPv6策略管理”
#   2. 幂等与可复跑: 智能识别已有配置，复跑时可无缝保留已有 UUID/Reality 密钥与已有用户
#   3. 权限与账户: 智能检测已有 sudoer 运维用户并支持直接复用，杜绝冗余账户
#   4. SSH 智能感知: 明确打印当前端口，端口 >30000 默认保持不折腾，换端口自动清理旧 UFW 规则
#   5. IPv6 自由管控: 支持系统内核彻底禁用、代理层出站阻断、WARP IPv6 兜底与一键恢复出厂双栈
#   6. 动态地理感知: 自适应识别节点国别城市，匹配最优伪装源站及带有国旗 Emoji 的客户端配置
#   7. 深度代理分流: 独家黑洞拦截 Geolocation 定位 API (防 Wi-Fi 穿透) + Google Play 走 WARP
#   8. 社区生态解耦: 动态硬件调优委托 tcpfit，巡检哨兵直接拉起官方 IP-Sentinel 原生向导
# ==============================================================================

set -uo pipefail

# ── 颜色常量定义 ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

msg_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
msg_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
msg_err()  { echo -e "${RED}[ERR ]${NC} $*"; }
msg_step() { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}"; }

DEFAULT_SAFE_USER="safeuser"

# ── 1. 终端横幅 ─────────────────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat <<'BANNER'
  _   _           _     __        ___                  _ 
 | \ | | ___   __| | ___\ \      / (_)______ _ _ __ __| |
 |  \| |/ _ \ / _` |/ _ \\ \ /\ / /| |_  / _` | '__/ _` |
 | |\  | (_) | (_| |  __/ \ V  V / | |/ / (_| | | | (_| |
 |_| \_|\___/ \__,_|\___|  \_/\_/  |_/___|\__,_|_|  \__,_|
BANNER
    echo -e "${NC}"
    echo -e "  ${BOLD}${MAGENTA}🧙‍♂️ Cloud Infrastructure Node Provisioning Wizard (NodeWizard)${NC}"
    echo -e "  ${CYAN}工业级基座加固 · 动态地理感知 · Xray+WARP 深度路由 · 社区工具无缝解耦${NC}"
    echo "=========================================================================="
    echo ""
}

# ── 2. 运行权限校验与自动提权 ───────────────────────────────────────────────
check_environment() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            msg_warn "检测到当前以非 root 用户运行，正在尝试通过 sudo 自动提权..."
            exec sudo -E bash "$0" "$@"
        else
            msg_err "NodeWizard 必须以 root 权限运行，且当前环境未检测到 sudo 命令！请切换至 root 后重试。"
            exit 1
        fi
    fi

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VER=$VERSION_ID
    else
        msg_err "无法识别当前操作系统发行版。"
        exit 1
    fi

    if [[ "$OS_NAME" != "debian" && "$OS_NAME" != "ubuntu" ]]; then
        msg_warn "当前系统检测为: $OS_NAME $OS_VER。本脚本专为 Debian 11/12+ 及 Ubuntu 22+ 深度调校。"
        read -rp "是否仍要继续？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
}

# ── 3. 动态地理与 IP 探测 ───────────────────────────────────────────────────
detect_node_geo() {
    SERVER_IP=$(curl -s4 --max-time 4 https://api.ipify.org || curl -s4 --max-time 4 https://ifconfig.me || echo "127.0.0.1")

    # 检测是否有全局公网 IPv6
    NODE_IPV6=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | awk '{print $2}' | head -n1 | cut -d'/' -f1 || echo "")

    local geo_json
    geo_json=$(curl -s4 --max-time 4 "http://ip-api.com/json/${SERVER_IP}?fields=status,country,countryCode,city,isp,query" 2>/dev/null || echo "{}")

    if [[ "$(echo "$geo_json" | jq -r '.status // empty' 2>/dev/null)" == "success" ]]; then
        NODE_CC=$(echo "$geo_json" | jq -r '.countryCode' | tr '[:lower:]' '[:upper:]')
        NODE_COUNTRY=$(echo "$geo_json" | jq -r '.country')
        NODE_CITY=$(echo "$geo_json" | jq -r '.city')
        NODE_ISP=$(echo "$geo_json" | jq -r '.isp')
    else
        NODE_CC="US"
        NODE_COUNTRY="United States"
        NODE_CITY="Los Angeles"
        NODE_ISP="Cloud Provider"
    fi

    case "$NODE_CC" in
        US) NODE_FLAG="🇺🇸" ;;
        JP) NODE_FLAG="🇯🇵" ;;
        HK) NODE_FLAG="🇭🇰" ;;
        SG) NODE_FLAG="🇸🇬" ;;
        TW) NODE_FLAG="🇹🇼" ;;
        KR) NODE_FLAG="🇰🇷" ;;
        GB|UK) NODE_FLAG="🇬🇧" ;;
        DE) NODE_FLAG="🇩🇪" ;;
        FR) NODE_FLAG="🇫🇷" ;;
        CA) NODE_FLAG="🇨🇦" ;;
        AU) NODE_FLAG="🇦🇺" ;;
        *)  NODE_FLAG="🌐" ;;
    esac
}

# ── 4. 辅助函数: 计算可用随机高位端口 (>30000) ───────────────────────────────
get_random_high_port() {
    local port
    while true; do
        port=$(shuf -i 35000-65000 -n 1)
        if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# ── 5. 辅助函数: 获取当前实际 SSH 端口 ───────────────────────────────────────
get_current_ssh_port() {
    local current_port=22
    if ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' >/dev/null 2>&1; then
        current_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
    elif [[ -f /etc/ssh/sshd_config ]]; then
        local p
        p=$(grep -E "^[# ]*Port [0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
        [[ -n "$p" ]] && current_port=$p
    fi
    echo "$current_port"
}

# ── 6. 辅助函数: 探测已有具备 sudo 权限的非 root 用户 ────────────────────────
detect_existing_sudoers() {
    local sudoers=()
    while IFS=: read -r username _ uid _ _ home shell; do
        if [[ "$uid" -ge 1000 && "$uid" -lt 65000 && "$shell" != */nologin && "$shell" != */false ]]; then
            if id -nG "$username" 2>/dev/null | grep -qw -E "sudo|wheel" || grep -rq "^[[:space:]]*${username}[[:space:]]" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
                sudoers+=("$username")
            fi
        fi
    done < /etc/passwd
    echo "${sudoers[@]}"
}

# ── 7. 核心看板: 巡检当前节点配置状态 ─────────────────────────────────────────
audit_node_status() {
    print_banner
    echo -e "${BOLD}${CYAN}🔍【当前节点系统与服务配置巡检看板】${NC}\n"

    # 1. 基础系统与网络画像
    echo -e "${BOLD}${BLUE}1. 系统与网络画像${NC}"
    echo -e "  操作系统发行版    : ${BOLD}${OS_NAME} ${OS_VER}${NC} ($(uname -m))"
    echo -e "  系统内核版本      : $(uname -r)"
    echo -e "  节点公网 IPv4     : ${BOLD}${CYAN}${SERVER_IP}${NC}"
    if [[ -n "$NODE_IPV6" ]]; then
        echo -e "  节点公网 IPv6     : ${BOLD}${MAGENTA}${NODE_IPV6}${NC} (双栈就绪)"
    else
        echo -e "  节点公网 IPv6     : 未分配 (纯 IPv4 机器)"
    fi
    echo -e "  物理归属地        : ${BOLD}${NODE_FLAG} ${NODE_COUNTRY} - ${NODE_CITY}${NC} (${NODE_ISP})"
    local current_dns
    current_dns=$(grep -E '^nameserver ' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || echo "未知")
    echo -e "  系统 DNS 服务器   : ${current_dns}"

    # 2. 账户与 SSH 状态
    echo -e "\n${BOLD}${BLUE}2. 运维账户与 SSH 安全防线${NC}"
    local existing_sudoers=($(detect_existing_sudoers))
    if [[ ${#existing_sudoers[@]} -gt 0 ]]; then
        echo -e "  已有 sudo 运维用户 : ${BOLD}${GREEN}${existing_sudoers[*]}${NC}"
    else
        echo -e "  已有 sudo 运维用户 : ${YELLOW}暂无非 root sudoer (仅 root 存在)${NC}"
    fi

    local current_ssh_port
    current_ssh_port=$(get_current_ssh_port)
    if [[ "$current_ssh_port" -gt 30000 ]]; then
        echo -e "  当前 SSH 监听端口  : ${BOLD}${GREEN}${current_ssh_port}${NC} [安全高位端口 (>30000)]"
    else
        echo -e "  当前 SSH 监听端口  : ${BOLD}${YELLOW}${current_ssh_port}${NC} [非高位端口 (<=30000)，易遭爆破]"
    fi

    local root_login="允许 (未加固)"
    if grep -E "^[[:space:]]*PermitRootLogin[[:space:]]+no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null | grep -q "no"; then
        root_login="${GREEN}已禁用 (安全)${NC}"
    fi
    echo -e "  Root 直接密码登录 : ${root_login}"

    local pwd_auth="允许 (未加固)"
    if grep -E "^[[:space:]]*PasswordAuthentication[[:space:]]+no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null | grep -q "no"; then
        pwd_auth="${GREEN}已禁用/仅限密钥 (安全)${NC}"
    fi
    echo -e "  密码认证登录      : ${pwd_auth}"

    # 3. 防火墙与防暴破
    echo -e "\n${BOLD}${BLUE}3. 防火墙与防暴破状态${NC}"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        echo -e "  UFW 防火墙状态    : ${BOLD}${GREEN}运行中 (Active)${NC}"
        local ufw_ports
        ufw_ports=$(ufw status 2>/dev/null | grep -E 'ALLOW' | awk '{print $1}' | tr '\n' ' ' || echo "无")
        echo -e "  UFW 已放行规则    : ${ufw_ports}"
    else
        echo -e "  UFW 防火墙状态    : ${YELLOW}未启用或未安装${NC}"
    fi

    if systemctl is-active fail2ban >/dev/null 2>&1; then
        echo -e "  Fail2ban 防护     : ${BOLD}${GREEN}运行中 (Active)${NC}"
    else
        echo -e "  Fail2ban 防护     : ${YELLOW}未激活${NC}"
    fi

    # 4. 内核与网络调度
    echo -e "\n${BOLD}${BLUE}4. 内核网络与内存状态${NC}"
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    if [[ "$cc" == "bbr" ]]; then
        echo -e "  TCP 拥塞控制算法  : ${BOLD}${GREEN}BBR (已开启)${NC}"
    else
        echo -e "  TCP 拥塞控制算法  : ${YELLOW}${cc} (推荐调优为 BBR)${NC}"
    fi

    local swap_total
    swap_total=$(free -h 2>/dev/null | grep -i swap | awk '{print $2}' || echo "0")
    echo -e "  当前虚拟内存 Swap : ${swap_total}"

    local sys_v6_dis
    sys_v6_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$sys_v6_dis" == "1" ]]; then
        echo -e "  系统内核 IPv6 开关: ${BOLD}${RED}已在系统内核全局禁用 (disable_ipv6=1，绝无泄漏)${NC}"
    else
        echo -e "  系统内核 IPv6 开关: ${BOLD}${GREEN}正常启用 (内核协议栈活跃)${NC}"
    fi

    # 5. Xray 代理核心与分流矩阵
    echo -e "\n${BOLD}${BLUE}5. Xray 代理核心与深度分流矩阵${NC}"
    if systemctl is-active xray >/dev/null 2>&1; then
        echo -e "  Xray 服务状态     : ${BOLD}${GREEN}运行中 (Active)${NC} (版本: $(xray version 2>/dev/null | head -n1 | awk '{print $2}'))"
        if [[ -f /usr/local/etc/xray/config.json ]]; then
            local curr_sni curr_uuid
            curr_sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "未知"' /usr/local/etc/xray/config.json 2>/dev/null)
            curr_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // "未知"' /usr/local/etc/xray/config.json 2>/dev/null)
            echo -e "  Reality 伪装源站  : ${BOLD}${CYAN}${curr_sni}${NC}"
            echo -e "  当前客户端 UUID   : ${curr_uuid}"

            # IPv6 出站策略检测
            if grep -q '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json 2>/dev/null && grep -A 2 '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json | grep -q '"outboundTag": "block"'; then
                echo -e "  代理 IPv6 出站策略: ${BOLD}${GREEN}出站阻断 (Block ::/0，纯净 IPv4 模式)${NC}"
            elif grep -q '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json 2>/dev/null && grep -A 2 '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json | grep -q '"outboundTag": "warp"'; then
                echo -e "  代理 IPv6 出站策略: ${BOLD}${CYAN}WARP IPv6 兜底 (隐藏原生 IPv6，展示 Cloudflare IPv6)${NC}"
            else
                echo -e "  代理 IPv6 出站策略: ${YELLOW}原生直连 (若访问 IPv6 目标将直接暴露 VPS IPv6)${NC}"
            fi

            # DNS 锁定策略检测
            local dns_qs
            dns_qs=$(jq -r '.dns.queryStrategy // "默认"' /usr/local/etc/xray/config.json 2>/dev/null)
            if [[ "$dns_qs" == "UseIPv4" ]]; then
                echo -e "  Xray DNS 查询策略 : ${BOLD}${GREEN}UseIPv4 (强制仅解析 A 记录，彻底杜绝 AAAA 泄露)${NC}"
            else
                echo -e "  Xray DNS 查询策略 : ${dns_qs}"
            fi

            if grep -q '"domain:geolocation.googleapis.com"' /usr/local/etc/xray/config.json 2>/dev/null; then
                echo -e "  Geolocation 黑洞  : ${BOLD}${GREEN}已生效 (Wi-Fi/基站防物理位置泄露)${NC}"
            else
                echo -e "  Geolocation 黑洞  : ${YELLOW}未配置${NC}"
            fi
            if grep -q '"tag": "warp"' /usr/local/etc/xray/config.json 2>/dev/null; then
                echo -e "  WARP 兜底出站     : ${BOLD}${GREEN}已集成 (国内推送/Play 商店兜底)${NC}"
            else
                echo -e "  WARP 兜底出站     : ${YELLOW}未启用${NC}"
            fi
        fi
    else
        echo -e "  Xray 服务状态     : ${YELLOW}未安装或未运行${NC}"
    fi

    # 6. 巡检哨兵与工具
    echo -e "\n${BOLD}${BLUE}6. 运维巡检与扩展工具${NC}"
    if systemctl is-active ip-sentinel-agent-daemon >/dev/null 2>&1; then
        echo -e "  IP-Sentinel 哨兵  : ${BOLD}${GREEN}运行中 (守护中)${NC}"
    else
        echo -e "  IP-Sentinel 哨兵  : 未安装 / 未运行"
    fi
    if command -v tcpfit >/dev/null 2>&1; then
        echo -e "  tcpfit 调优工具   : ${BOLD}${GREEN}已就绪${NC} (/usr/local/bin/tcpfit)"
    else
        echo -e "  tcpfit 调优工具   : 未安装"
    fi

    echo ""
    echo "=========================================================================="
    read -rp "巡检完成。按回车键返回主菜单..." _
}

# ── 8. 查看当前客户端节点配置与订阅链接 (菜单选项 [5]) ─────────────────────────
view_client_configs() {
    print_banner
    if ! systemctl is-active xray >/dev/null 2>&1 || [[ ! -f /usr/local/etc/xray/config.json ]]; then
        msg_err "当前节点尚未安装或运行 Xray 核心，无法生成客户端链接。请先选择 [1] 或 [4] 进行部署。"
        read -rp "按回车键返回主菜单..." _
        return
    fi

    msg_info "正在读取现有 Xray 凭据并生成最新客户端配置..."

    local cfg="/usr/local/etc/xray/config.json"
    local uuid sni target port priv_key pub_key short_id

    uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$cfg" 2>/dev/null)
    port=$(jq -r '.inbounds[0].port // 443' "$cfg" 2>/dev/null)
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$cfg" 2>/dev/null)
    target=$(jq -r '.inbounds[0].streamSettings.realitySettings.target // empty' "$cfg" 2>/dev/null)
    priv_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$cfg" 2>/dev/null)
    short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$cfg" 2>/dev/null)

    if [[ -n "$priv_key" ]]; then
        pub_key=$(xray x25519 -i "$priv_key" 2>/dev/null | grep 'Password' | awk '{print $3}' || echo "")
    fi

    local default_node_title="${NODE_FLAG} ${NODE_CITY} 落地"

    echo ""
    echo "=========================================================================="
    echo -e "         ${BOLD}${GREEN}📋 NodeWizard 当前节点客户端订阅配置与一键链接${NC}"
    echo "=========================================================================="
    echo -e "  节点地理标识      : ${BOLD}${NODE_FLAG} ${NODE_COUNTRY} - ${NODE_CITY}${NC} (${NODE_ISP})"
    echo -e "  公网 IP 地址      : ${BOLD}${CYAN}${SERVER_IP}${NC}"
    echo -e "  VLESS 监听端口    : ${BOLD}${port} (TCP)${NC}"
    echo -e "  Reality 伪装源站  : ${BOLD}${target}${NC} (SNI: ${sni})"
    echo -e "  Reality PublicKey : ${BOLD}${GREEN}${pub_key}${NC}"
    echo -e "  Reality ShortId   : ${BOLD}${short_id}${NC}"
    echo -e "  VLESS UUID        : ${BOLD}${uuid}${NC}"
    echo -e "  Client Fingerprint: ${BOLD}chrome${NC}"
    echo "=========================================================================="

    echo -e "\n${BOLD}${BLUE}【1. Clash Meta (Mihomo) / Clash Verge 客户端配置块】${NC}"
    echo -e "${YELLOW}直接复制以下内容粘贴至你的 Clash 配置文件 proxies: 列表下：${NC}\n"

    cat <<EOF
proxies:
  # ================= 模式 1: 直连模式 =================
  - name: "${default_node_title} [直连]"
    type: vless
    server: ${SERVER_IP}
    port: ${port}
    uuid: ${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${sni}
    reality-opts:
      public-key: ${pub_key}
      short-id: ${short_id}
    client-fingerprint: chrome

  # ================= 模式 2: 链式中继落地模式 =================
  - name: "${default_node_title} [中继落地]"
    type: vless
    server: ${SERVER_IP}
    port: ${port}
    uuid: ${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${sni}
    reality-opts:
      public-key: ${pub_key}
      short-id: ${short_id}
    client-fingerprint: chrome
    dialer-proxy: "机场-低延迟节点名称"   # <-- 替换为您已有中转/机场订阅中的节点名称
EOF

    echo -e "\n${BOLD}${BLUE}【2. Shadowrocket / 通用一键导入链接】${NC}"
    echo -e "* 直连模式："
    echo -e "${CYAN}vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#${NODE_FLAG}%20${NODE_CITY}%E7%9B%B4%E8%BF%9E${NC}"
    echo -e "* 链式中继落地模式："
    echo -e "${CYAN}vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#${NODE_FLAG}%20${NODE_CITY}%E4%B8%AD%E7%BB%A7%E8%90%BD%E5%9C%B0${NC}"

    echo ""
    echo "=========================================================================="
    read -rp "提取完成。按回车键返回主菜单..." _
}

# ── 9. IPv6 专属出站治理管理子菜单 (菜单选项 [6]) ─────────────────────────────
manage_ipv6_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}${CYAN}🌐【IPv6 双栈网络治理与出站策略管理】${NC}\n"

        # 探测当前状态
        local sys_dis
        sys_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
        local xray_v6_strat="原生直连"
        if [[ -f /usr/local/etc/xray/config.json ]]; then
            if grep -q '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json 2>/dev/null && grep -A 2 '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json | grep -q '"outboundTag": "block"'; then
                xray_v6_strat="出站阻断 (Block ::/0)"
            elif grep -q '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json 2>/dev/null && grep -A 2 '"ip": \["\:\:\/0"\]' /usr/local/etc/xray/config.json | grep -q '"outboundTag": "warp"'; then
                xray_v6_strat="WARP IPv6 兜底"
            fi
        fi

        echo -e "当前系统运行状态:"
        if [[ "$sys_dis" == "1" ]]; then
            echo -e "  * 系统内核状态: ${BOLD}${RED}已全局彻底禁用 (disable_ipv6=1，绝无泄漏)${NC}"
        else
            echo -e "  * 系统内核状态: ${BOLD}${GREEN}正常启用 (内核协议栈活跃)${NC}"
        fi
        echo -e "  * 节点原生 IPv6: ${BOLD}${MAGENTA}${NODE_IPV6:-无原生公网 IPv6}${NC}"
        echo -e "  * Xray 代理策略: ${BOLD}${CYAN}${xray_v6_strat}${NC}\n"

        echo -e "请选择针对此节点的 IPv6 治理模式："
        echo -e "  ${BOLD}[1]${NC} ${RED}🛡️ 系统内核级彻底禁用 IPv6 (最彻底方案，100% 杜绝任何 IPv6 泄露)${NC}"
        echo -e "  ${BOLD}[2]${NC} ${GREEN}🧱 代理层出站阻断 (Block ::/0 + DoH UseIPv4，保留 VPS 入站)${NC}"
        echo -e "  ${BOLD}[3]${NC} ${CYAN}☁️ IPv6 转 Cloudflare WARP 兜底 (隐藏原生 IPv6，展示 Cloudflare IPv6)${NC}"
        echo -e "  ${BOLD}[4]${NC} ${YELLOW}🔄 恢复正常/原生双栈直连 (一键解除内核与代理阻断，恢复正常出站)${NC}"
        echo -e "  ${BOLD}[0]${NC} 返回上级主菜单"
        echo "=========================================================================="
        read -rp "请输入选项编号 [0-4]: " v6_choice

        case "$v6_choice" in
            1)
                msg_info "正在系统内核层面彻底禁用 IPv6 协议栈..."
                cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
                sysctl --system >/dev/null 2>&1 || true
                msg_ok "系统内核级 IPv6 协议栈已彻底关闭！测试网站绝无泄露可能。"
                sleep 2
                ;;
            2)
                msg_info "正在恢复内核 IPv6 栈并配置 Xray 代理层出站阻断..."
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                sysctl --system >/dev/null 2>&1 || true

                # 修改 Xray 配置为出站阻断 ::/0
                IPV6_STRATEGY="1"
                if [[ -f /usr/local/etc/xray/config.json ]]; then
                    setup_xray_and_warp
                fi
                msg_ok "代理层 IPv6 出站阻断策略配置生效！"
                sleep 2
                ;;
            3)
                msg_info "正在恢复内核 IPv6 栈并配置 Xray 代理层 WARP 兜底..."
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                sysctl --system >/dev/null 2>&1 || true

                IPV6_STRATEGY="2"
                if [[ -f /usr/local/etc/xray/config.json ]]; then
                    setup_xray_and_warp
                fi
                msg_ok "IPv6 走 WARP 出站策略配置生效！"
                sleep 2
                ;;
            4)
                msg_info "正在恢复原生 IPv6 双栈直连状态..."
                # 1. 恢复内核 IPv6
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                sysctl --system >/dev/null 2>&1 || true

                # 2. 恢复 Xray 原生直连 (移除 ::/0 规则，DNS 恢复 UseIP)
                IPV6_STRATEGY="4"
                if [[ -f /usr/local/etc/xray/config.json ]]; then
                    setup_xray_and_warp
                fi
                msg_ok "已全面恢复正常双栈连接！原生 IPv6 出入站已全面解锁。"
                sleep 2
                ;;
            0)
                break
                ;;
            *)
                msg_warn "输入无效，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

# ── 10. 基础运行依赖安装 ─────────────────────────────────────────────────────
install_dependencies() {
    msg_step "【Step 1/7】更新软件源并安装基础运行工具链"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget jq openssl iproute2 python3 ca-certificates \
        ufw fail2ban procps dnsutils sudo logrotate unattended-upgrades >/dev/null 2>&1
    msg_ok "基础运行环境就绪"
}

# ── 11. 用户体系与 SSH 端口智能感知加固 (清晰显示端口 + >30000 默认不折腾) ────
setup_user_and_ssh() {
    msg_step "【Step 2/7】配置专用运维用户、免密 sudo 与 SSH 端口安全迁移"

    # 1. 扫描检测系统中已有的非 root sudoer 用户
    local existing_sudoers=($(detect_existing_sudoers))
    local chosen_user=""

    if [[ ${#existing_sudoers[@]} -gt 0 ]]; then
        echo -e "\n${BOLD}${CYAN}检测到系统中已存在具备 sudo 权限的非 root 用户:${NC} ${BOLD}${GREEN}${existing_sudoers[*]}${NC}"
        echo -e "  ${BOLD}[1]${NC} ${GREEN}直接复用已有用户 (推荐，直接为其配置密钥链，避免产生多余用户)${NC}"
        echo -e "  ${BOLD}[2]${NC} 新建专用运维用户"
        read -rp "请选择 [1-2] (默认 1): " user_choice
        user_choice=${user_choice:-1}

        if [[ "$user_choice" == "1" ]]; then
            if [[ ${#existing_sudoers[@]} -eq 1 ]]; then
                chosen_user="${existing_sudoers[0]}"
                msg_ok "已选定复用已有用户: ${BOLD}${GREEN}${chosen_user}${NC}"
            else
                echo "请选择要复用的具体用户:"
                local u_idx=1
                for u in "${existing_sudoers[@]}"; do
                    echo "  [$u_idx] $u"
                    u_idx=$((u_idx + 1))
                done
                read -rp "请输入编号 [1-${#existing_sudoers[@]}] (默认 1): " pick_u
                pick_u=${pick_u:-1}
                local sel_idx=$((pick_u - 1))
                chosen_user="${existing_sudoers[$sel_idx]}"
                msg_ok "已选定复用已有用户: ${BOLD}${GREEN}${chosen_user}${NC}"
            fi
        fi
    fi

    # 若未复用已有用户，则新建用户
    if [[ -z "$chosen_user" ]]; then
        echo ""
        read -rp "请输入新运维用户名 [默认: ${DEFAULT_SAFE_USER}]: " input_user
        chosen_user=${input_user:-$DEFAULT_SAFE_USER}

        if ! id -u "$chosen_user" >/dev/null 2>&1; then
            msg_info "正在创建专用运维用户: ${chosen_user} ..."
            useradd -m -s /bin/bash "$chosen_user"
        fi
        usermod -aG sudo "$chosen_user" >/dev/null 2>&1 || true
        msg_ok "用户 ${chosen_user} 创建就绪"
    fi

    MAINT_USER="$chosen_user"

    # 赋予无密码 sudo 权限
    echo "${MAINT_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-${MAINT_USER}"
    chmod 0440 "/etc/sudoers.d/99-${MAINT_USER}"

    # 2. 配置专属 SSH 密钥链 (在线动态拉取 / 现场生成 / 手动粘贴)
    local user_ssh_dir="/home/${MAINT_USER}/.ssh"
    mkdir -p "$user_ssh_dir" /root/.ssh
    chmod 700 "$user_ssh_dir" /root/.ssh

    echo ""
    msg_info "正在配置 ${MAINT_USER} 的 SSH Authorized Keys 认证密钥..."
    echo -e "请选择 SSH 身份认证密钥配置方式："
    echo -e "  ${BOLD}[1]${NC} ${GREEN}🚀 在线同步 Termius 专属密钥链 (通过 sshid.io 动态拉取公钥)${NC}"
    echo -e "  ${BOLD}[2]${NC} ${CYAN}🔑 现场为本节点生成全新独立 ED25519 密钥对 (即时输出私钥供本地保存)${NC}"
    echo -e "  ${BOLD}[3]${NC} ✍️ 手动粘贴公钥字符串"
    read -rp "请选择 [1-3] (默认 1): " key_mode_choice
    key_mode_choice=${key_mode_choice:-1}

    case "$key_mode_choice" in
        2)
            msg_info "正在生成全新高安全 ED25519 密钥对..."
            local tmp_key="/tmp/nodewizard_ed25519_${MAINT_USER}"
            rm -f "${tmp_key}" "${tmp_key}.pub"
            ssh-keygen -t ed25519 -N "" -f "$tmp_key" -C "${MAINT_USER}@${SERVER_IP}-$(date +%Y%m%d)" >/dev/null 2>&1

            # 写入公钥
            cat "${tmp_key}.pub" >> "${user_ssh_dir}/authorized_keys"

            echo ""
            echo "=========================================================================="
            echo -e "  ${BOLD}${YELLOW}⚠️  【重要凭证】新节点专属 ED25519 私钥已生成，请立即完整复制保存！${NC}"
            echo -e "  ${RED}关闭或断开此窗口后，服务器将不再保存此私钥！请直接导入 Termius 或本地私钥文件。${NC}"
            echo "=========================================================================="
            echo -e "${CYAN}${BOLD}"
            cat "$tmp_key"
            echo -e "${NC}"
            echo "=========================================================================="
            read -rp "请确认已将上述私钥完整复制并妥善保存好，按回车键继续后续加固流程..." _

            # 安全粉碎擦除私钥
            shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
            rm -f "${tmp_key}.pub"
            msg_ok "新节点专属 ED25519 密钥对配置就绪 (私钥已安全擦除)"
            ;;
        3)
            echo ""
            read -rp "请粘贴您的公钥内容 (形如 ssh-ed25519 AAAA... 或 ssh-rsa AAAA...): " pasted_key
            if [[ -n "$pasted_key" ]]; then
                echo "$pasted_key" >> "${user_ssh_dir}/authorized_keys"
                msg_ok "自定义公钥已追加"
            else
                msg_warn "未输入公钥内容"
            fi
            ;;
        *)
            # 模式 1: 动态在线同步 sshid.io/<username>
            echo ""
            msg_info "Termius 用户公钥在线同步服务 (由 sshid.io 提供)"
            local sshid_username=""
            read -rp "请输入您的 Termius / sshid 用户名 (直接回车跳过): " sshid_username
            if [[ -n "$sshid_username" ]]; then
                msg_info "正在向 https://sshid.io/${sshid_username} 在线同步最新公钥链..."
                local fetched_keys
                fetched_keys=$(curl -fsSL --max-time 8 "https://sshid.io/${sshid_username}" 2>/dev/null || curl -fsSL --max-time 8 "https://sshid.io/${sshid_username}/ED25519" 2>/dev/null || echo "")

                if [[ -n "$fetched_keys" && "$fetched_keys" =~ (ssh-ed25519|ssh-rsa|ecdsa-) ]]; then
                    echo "$fetched_keys" >> "${user_ssh_dir}/authorized_keys"
                    msg_ok "成功从 sshid.io/@${sshid_username} 动态同步拉取到最新 SSH passkeys！"
                else
                    msg_warn "未能从 https://sshid.io/${sshid_username} 拉取到有效公钥，请核实用户名或网络连接。"
                fi
            fi
            ;;
    esac

    # 询问是否追加辅助/备用公钥
    echo ""
    read -rp "是否需要追加一条自定义备用公钥作为双保险？[y/N] (默认 N): " add_backup_key
    if [[ "$add_backup_key" =~ ^[Yy]$ ]]; then
        read -rp "请粘贴备用公钥: " extra_key
        if [[ -n "$extra_key" ]]; then
            echo "$extra_key" >> "${user_ssh_dir}/authorized_keys"
            msg_ok "备用公钥已成功追加"
        fi
    fi

    # 安全保底：如果 authorized_keys 仍为空，强制生成一对临时密钥防止失联
    if [[ ! -s "${user_ssh_dir}/authorized_keys" ]]; then
        echo ""
        msg_warn "检测到当前未配置任何有效的 SSH 公钥！为防止关闭密码登录后失联，现为您自动生成紧急恢复 ED25519 密钥对..."
        local emergency_key="/tmp/nodewizard_emergency_${MAINT_USER}"
        rm -f "${emergency_key}" "${emergency_key}.pub"
        ssh-keygen -t ed25519 -N "" -f "$emergency_key" -C "emergency-${MAINT_USER}@${SERVER_IP}" >/dev/null 2>&1
        cat "${emergency_key}.pub" >> "${user_ssh_dir}/authorized_keys"

        echo "=========================================================================="
        echo -e "  ${BOLD}${RED}⚠️  【紧急恢复私钥】请务必立即复制并保存以下私钥，否则您将无法登录服务器！${NC}"
        echo "=========================================================================="
        echo -e "${YELLOW}${BOLD}"
        cat "$emergency_key"
        echo -e "${NC}"
        echo "=========================================================================="
        read -rp "确认已复制此紧急私钥后，按回车键继续..." _
        shred -u "$emergency_key" 2>/dev/null || rm -f "$emergency_key"
        rm -f "${emergency_key}.pub"
        msg_ok "紧急 ED25519 公钥已注入"
    fi

    sort -u "${user_ssh_dir}/authorized_keys" -o "${user_ssh_dir}/authorized_keys"
    chmod 600 "${user_ssh_dir}/authorized_keys"
    chown -R "${MAINT_USER}:${MAINT_USER}" "$user_ssh_dir"

    # 同步 root 的 authorized_keys 作为应急防失联保障
    cp "${user_ssh_dir}/authorized_keys" /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    msg_ok "公钥凭据链注入完毕 (已为 ${MAINT_USER} 与 root 双向同步)"

    # 3. 处理 Ubuntu 22.10+ / 24.04 的 systemd ssh.socket 干扰
    if systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-enabled ssh.socket >/dev/null 2>&1; then
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl enable --now ssh.service >/dev/null 2>&1 || true
    fi

    # 4. SSH 端口智能感知与迁移策略 (>30000 判定)
    OLD_SSH_PORT=$(get_current_ssh_port)
    local need_change_port=false

    echo ""
    if [[ "$OLD_SSH_PORT" -gt 30000 && "$OLD_SSH_PORT" -le 65535 ]]; then
        echo -e "${BOLD}${GREEN}[ OK ] 检测到当前 SSH 监听端口为: ${OLD_SSH_PORT} [已是安全高位端口 (>30000)]${NC}"
        read -rp "是否保持现有端口 (${OLD_SSH_PORT})？[Y/n] (默认 Y，不改动避免 Termius 标签失效): " keep_port_choice
        keep_port_choice=${keep_port_choice:-Y}
        if [[ ! "$keep_port_choice" =~ ^[Yy]$ ]]; then
            need_change_port=true
        else
            TARGET_SSH_PORT=$OLD_SSH_PORT
            msg_ok "保持当前安全 SSH 端口: ${TARGET_SSH_PORT}"
        fi
    else
        echo -e "${BOLD}${YELLOW}[WARN] 检测到当前 SSH 监听端口为: ${OLD_SSH_PORT} [非安全高位端口 (<=30000)，易遭扫描爆破]${NC}"
        need_change_port=true
    fi

    if [[ "$need_change_port" == "true" ]]; then
        local recommended_port
        recommended_port=$(get_random_high_port)
        echo -e "系统已为您计算推荐可用随机高位安全端口: ${BOLD}${GREEN}${recommended_port}${NC}"
        read -rp "请输入新 SSH 端口 [直接回车默认使用随机高位 ${recommended_port}，或输入自定义端口]: " input_ssh_port
        TARGET_SSH_PORT=${input_ssh_port:-$recommended_port}

        # 合法性校验
        if ! [[ "$TARGET_SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$TARGET_SSH_PORT" -lt 1024 ]] || [[ "$TARGET_SSH_PORT" -gt 65535 ]]; then
            msg_warn "输入端口不合法，自动回退采用推荐端口: ${recommended_port}"
            TARGET_SSH_PORT=$recommended_port
        fi
    fi

    msg_info "应用高安全级别 SSH 策略 (端口: ${TARGET_SSH_PORT}, 仅密钥登录, 禁用密码与 Root)..."
    local ssh_conf="/etc/ssh/sshd_config"
    cp "$ssh_conf" "${ssh_conf}.bak_$(date +%Y%m%d%H%M%S)"

    sed -i -E "s/^[# ]*Port [0-9]+/Port ${TARGET_SSH_PORT}/" "$ssh_conf"
    grep -q "^Port ${TARGET_SSH_PORT}" "$ssh_conf" || echo "Port ${TARGET_SSH_PORT}" >> "$ssh_conf"

    sed -i -E 's/^[# ]*PermitRootLogin .*/PermitRootLogin no/' "$ssh_conf"
    grep -q "^PermitRootLogin no" "$ssh_conf" || echo "PermitRootLogin no" >> "$ssh_conf"

    sed -i -E 's/^[# ]*PasswordAuthentication .*/PasswordAuthentication no/' "$ssh_conf"
    grep -q "^PasswordAuthentication no" "$ssh_conf" || echo "PasswordAuthentication no" >> "$ssh_conf"

    sed -i -E 's/^[# ]*PubkeyAuthentication .*/PubkeyAuthentication yes/' "$ssh_conf"
    grep -q "^PubkeyAuthentication yes" "$ssh_conf" || echo "PubkeyAuthentication yes" >> "$ssh_conf"

    sed -i -E 's/^[# ]*KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' "$ssh_conf"
    grep -q "^KbdInteractiveAuthentication no" "$ssh_conf" || echo "KbdInteractiveAuthentication no" >> "$ssh_conf"

    # 防火墙先开孔，绝对防锁死
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${TARGET_SSH_PORT}/tcp" comment 'SSH Port' >/dev/null 2>&1 || true
    fi

    # 语法测试与安全回滚
    if sshd -t 2>/dev/null; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        msg_ok "SSH 服务已在端口生效: ${BOLD}${GREEN}${TARGET_SSH_PORT}${NC} (运维用户: ${MAINT_USER})"
    else
        msg_err "sshd 配置校验未通过！已自动恢复原有配置，请检查 ${ssh_conf}。"
    fi
}

# ── 12. UFW 防火墙与 Fail2ban 自动防御 (含 UFW 历史旧端口清理) ─────────────────
setup_firewall_and_security() {
    msg_step "【Step 3/7】配置 UFW 极简白名单防火墙与 Fail2ban 自动防御"

    # 清理因端口变动产生的历史废弃 UFW 规则 (避免规则列表堆积)
    if [[ -n "${OLD_SSH_PORT:-}" && "$OLD_SSH_PORT" != "$TARGET_SSH_PORT" ]]; then
        msg_info "检测到 SSH 端口由 ${OLD_SSH_PORT} 变更为 ${TARGET_SSH_PORT}，正在清理 UFW 中旧端口规则..."
        ufw delete allow "${OLD_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    fi

    msg_info "配置 UFW 极简入站白名单 (默认阻断，精准放行: ${TARGET_SSH_PORT}/tcp, 443/tcp)..."
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow "${TARGET_SSH_PORT}/tcp" comment 'SSH Port' >/dev/null 2>&1
    ufw allow 443/tcp comment 'Xray Reality Port' >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    msg_ok "UFW 防火墙启用就绪 (仅保留当前 SSH 与 443 端口)"

    msg_info "配置 Fail2ban 联动防御 (监控端口: ${TARGET_SSH_PORT}, 3 次密码错误自动拉黑 24 小时)..."
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 86400
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ${TARGET_SSH_PORT}
logpath  = %(sshd_log)s
EOF
    systemctl restart fail2ban >/dev/null 2>&1 || true
    systemctl enable fail2ban >/dev/null 2>&1 || true
    msg_ok "Fail2ban 暴力破解守护已激活"
}

# ── 13. 系统底模优化与 tcpfit 预装 ───────────────────────────────────────────
setup_system_base_and_tcpfit() {
    msg_step "【Step 4/7】配置系统 BBR 原生保底、DNS、Swap、日志限额并预装 tcpfit"

    # 1. Swap 内存保底
    local total_swap_kb
    total_swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [[ "$total_swap_kb" -lt 524288 ]]; then
        msg_info "正在创建 1GB /swapfile 虚拟内存防小内存 OOM..."
        fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        msg_ok "1GB Swapfile 创建并激活成功"
    else
        msg_ok "系统已有足够 Swap (${total_swap_kb} kB)"
    fi

    # 2. 原生 BBR + FQ 保底生效 (0.5秒即时生效)
    msg_info "启用内核原生 BBR + FQ 拥塞控制基线..."
    cat <<EOF > /etc/sysctl.d/99-bbr-baseline.conf
vm.swappiness = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
EOF
    sysctl --system >/dev/null 2>&1 || true
    msg_ok "内核原生 BBR + FQ 基础调优已生效"

    # 3. Google 权威 DNS
    msg_info "配置系统 DNS 解析器至 Google DNS (8.8.8.8 / 8.8.4.4)..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat <<EOF > /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
EOF
    systemctl restart systemd-resolved >/dev/null 2>&1 || true

    # 4. journald 日志配额限制 (100MB 硬顶，防爆盘)
    mkdir -p /etc/systemd/journald.conf.d
    cat <<EOF > /etc/systemd/journald.conf.d/size-limit.conf
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    msg_ok "systemd-journald 日志硬顶配额 (100MB) 生效"

    # 5. 预装 tcpfit 工具至全局 PATH
    msg_info "预装社区专业调优工具 tcpfit 至 /usr/local/bin/tcpfit ..."
    curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh -o /usr/local/bin/tcpfit 2>/dev/null || true
    chmod +x /usr/local/bin/tcpfit 2>/dev/null || true
    msg_ok "tcpfit 预装完毕 (可随时在终端输入 ${BOLD}tcpfit${NC} 运行)"
}

# ── 14. IPv6 双栈治理策略交互 ─────────────────────────────────────────────────
configure_ipv6_policy() {
    msg_step "【Step 5/7】IPv6 双栈网络治理与防泄露策略配置"

    IPV6_STRATEGY="1"

    if [[ -n "$NODE_IPV6" ]]; then
        echo -e "${BOLD}${CYAN}[INFO] 检测到当前实例具备公网 IPv6 双栈能力 (IPv6: ${NODE_IPV6})${NC}"
        echo -e "为防止测试网站或 WebRTC 探测直接暴露 VPS 原生 IPv6 地址，请选择治理方案："
        echo -e "  ${BOLD}[1]${NC} ${RED}🛡️ 系统内核级彻底禁用 IPv6 (最彻底方案，100% 杜绝任何 IPv6 泄露，最推荐)${NC}"
        echo -e "  ${BOLD}[2]${NC} ${GREEN}🧱 代理层出站阻断 (Block ::/0 + DoH UseIPv4，保留 VPS 入站)${NC}"
        echo -e "  ${BOLD}[3]${NC} ${CYAN}☁️ IPv6 转 Cloudflare WARP 兜底 (隐藏原生 IPv6，展示 Cloudflare IPv6)${NC}"
        echo -e "  ${BOLD}[4]${NC} ${YELLOW}🔄 保持双栈原生直连 (不限制 IPv6)${NC}"
        echo ""
        read -rp "请选择 IPv6 出站策略 [1-4] (默认 1): " input_v6_strat
        IPV6_STRATEGY=${input_v6_strat:-1}

        case "$IPV6_STRATEGY" in
            1)
                msg_info "正在系统内核层面彻底禁用 IPv6 协议栈 (disable_ipv6=1)..."
                cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
                sysctl --system >/dev/null 2>&1 || true
                msg_ok "系统内核级已彻底禁用 IPv6 协议栈！任何测试站绝无探测到 IPv6 的可能。"
                ;;
            2)
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                sysctl --system >/dev/null 2>&1 || true
                msg_ok "选定策略: 【代理层拦截 IPv6 出站】(DNS 锁死 UseIPv4 + Block ::/0)"
                ;;
            3)
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                sysctl --system >/dev/null 2>&1 || true
                msg_ok "选定策略: 【IPv6 走 WARP 兜底出站】(对外展示 Cloudflare IPv6)"
                ;;
            *)
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                sysctl --system >/dev/null 2>&1 || true
                msg_ok "选定策略: 【保持双栈原生直连】"
                ;;
        esac
    else
        msg_ok "当前机器为纯 IPv4 实例，自动启用【纯净 IPv4 闭环】保障。"
    fi
}

# ── 15. 自适应 Reality 伪装源站选择 ──────────────────────────────────────────
select_reality_target() {
    msg_step "【Step 6/7】自适应 Reality 伪装源站配置"

    local default_target="www.popsci.com:443"
    if [[ "$NODE_CC" == "JP" ]]; then
        default_target="www.yahoo.co.jp:443"
    fi

    # 若可复跑已有配置，则优先读取现有的 target
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        local curr_t
        curr_t=$(jq -r '.inbounds[0].streamSettings.realitySettings.target // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        [[ -n "$curr_t" ]] && default_target="$curr_t"
    fi

    echo -e "依据节点位置 (${NODE_FLAG} ${NODE_COUNTRY})，为您智能优选候选源站 (原生支持 HTTP/2 与 TLS 1.3):"
    if [[ "$NODE_CC" == "JP" ]]; then
        echo -e "  [1] ${BOLD}${GREEN}www.yahoo.co.jp:443${NC}      (🇯🇵 日本本地超高权重门户，延迟极低，首选推荐)"
        echo -e "  [2] www.popsci.com:443       (Fastly 顶级源站，信誉极高)"
        echo -e "  [3] addons.mozilla.org:443   (Mozilla 官方顶级站)"
        echo -e "  [4] download.docker.com:443  (Docker 官方源站)"
    else
        echo -e "  [1] ${BOLD}${GREEN}www.popsci.com:443${NC}       (Fastly 原生顶级无 CDN 源站，信誉极高，首选推荐)"
        echo -e "  [2] addons.mozilla.org:443   (Mozilla 官方顶级站)"
        echo -e "  [3] download.docker.com:443  (Docker 官方源站)"
        echo -e "  [4] images.unsplash.com:443  (Unsplash 高吞吐静态图床)"
    fi
    echo -e "  [0] 手动输入自定义伪装源站"
    echo ""
    read -rp "请选择伪装源站 [0-4] (直接回车默认 [1] ${default_target}): " target_choice
    target_choice=${target_choice:-1}

    case "$target_choice" in
        1) REALITY_TARGET="$default_target" ;;
        2) REALITY_TARGET="addons.mozilla.org:443" ;;
        3) REALITY_TARGET="download.docker.com:443" ;;
        4) REALITY_TARGET="images.unsplash.com:443" ;;
        0)
            read -rp "请输入自定义伪装源站 (域名:443): " custom_target
            REALITY_TARGET="$custom_target"
            ;;
        *) REALITY_TARGET="$default_target" ;;
    esac

    REALITY_SNI=$(echo "$REALITY_TARGET" | cut -d':' -f1)
    msg_ok "选定 Reality Target: ${BOLD}${GREEN}${REALITY_TARGET}${NC} (SNI: ${REALITY_SNI})"
}

# ── 16. Xray 原生部署、WARP 兜底与深度分流矩阵 ─────────────────────────────────
setup_xray_and_warp() {
    msg_step "【Step 7/7】部署 Xray 原生核心、WARP 兜底与独家深度路由矩阵"

    # 1. 安装 Xray 官方最新核心
    if ! command -v xray >/dev/null 2>&1; then
        msg_info "正在通过官方安装脚本部署最新 Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    fi
    msg_ok "Xray 核心已就绪 ($(xray version | head -n1 | awk '{print $2}'))"

    # 2. nobody 降权与 Linux Capabilities 特权绑定
    mkdir -p /etc/systemd/system/xray.service.d
    cat <<EOF > /etc/systemd/system/xray.service.d/10-permissions.conf
[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755
EOF

    # 3. 密钥与凭据处理 (可复跑识别)
    local reuse_creds=false
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        local old_uuid old_priv old_pub old_short
        old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        old_priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        old_short=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' /usr/local/etc/xray/config.json 2>/dev/null)

        if [[ -n "$old_uuid" && -n "$old_priv" ]]; then
            echo ""
            msg_info "检测到系统已存在 Xray 生产配置 (UUID: ${old_uuid})"
            read -rp "是否保留现有的 UUID 与 Reality 密钥凭据？[Y/n] (默认 Y，免去重新配置客户端): " keep_resp
            keep_resp=${keep_resp:-Y}
            if [[ "$keep_resp" =~ ^[Yy]$ ]]; then
                reuse_creds=true
                VLESS_UUID="$old_uuid"
                REALITY_PRIV_KEY="$old_priv"
                REALITY_SHORT_ID="$old_short"
                REALITY_PUB_KEY=$(xray x25519 -i "$REALITY_PRIV_KEY" 2>/dev/null | grep 'Password' | awk '{print $3}' || echo "")
                if [[ -z "$REALITY_PUB_KEY" ]]; then
                    msg_warn "未能从已有私钥推算公钥，重新生成 Reality 密钥对..."
                    local x25519_regen
                    x25519_regen=$(xray x25519)
                    REALITY_PRIV_KEY=$(echo "$x25519_regen" | grep 'PrivateKey' | awk '{print $2}')
                    REALITY_PUB_KEY=$(echo "$x25519_regen" | grep 'Password' | awk '{print $3}')
                fi
                msg_ok "已成功复用现有 VLESS UUID 与 Reality 密钥对！"
            fi
        fi
    fi

    if [[ "$reuse_creds" == "false" ]]; then
        msg_info "生成全新 VLESS UUID 与 x25519 Reality 密钥对..."
        VLESS_UUID=$(xray uuid)
        local x25519_output
        x25519_output=$(xray x25519)
        REALITY_PRIV_KEY=$(echo "$x25519_output" | grep 'PrivateKey' | awk '{print $2}')
        REALITY_PUB_KEY=$(echo "$x25519_output" | grep 'Password' | awk '{print $3}')
        REALITY_SHORT_ID=$(openssl rand -hex 8)
    fi

    # 4. 注册 Cloudflare WARP 原生 WireGuard 出站
    local warp_priv="" warp_v4="" warp_peer_pub="" warp_reserved="[0, 0, 0]"
    local has_warp=false

    # 优先复用已有 WARP 凭据
    if [[ -f /usr/local/etc/xray/config.json ]] && grep -q '"tag": "warp"' /usr/local/etc/xray/config.json 2>/dev/null; then
        local w_priv w_v4 w_peer w_res
        w_priv=$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.secretKey // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        w_v4=$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.address[0] // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        w_peer=$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.peers[0].publicKey // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        w_res=$(jq -c '.outbounds[] | select(.tag=="warp") | .settings.reserved // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        if [[ -n "$w_priv" && -n "$w_v4" ]]; then
            warp_priv="$w_priv"
            warp_v4="$w_v4"
            warp_peer_pub="$w_peer"
            warp_reserved="${w_res:-[0, 0, 0]}"
            has_warp=true
            msg_ok "成功复用现有 Cloudflare WARP 出站凭据 (IPv4: ${warp_v4})"
        fi
    fi

    if [[ "$has_warp" == "false" ]]; then
        msg_info "向 Cloudflare API 申请原生 WARP WireGuard 出站凭据..."
        python3 -c "
import urllib.request, json, subprocess, datetime, base64

try:
    out = subprocess.check_output(['xray', 'wg']).decode()
    lines = dict(line.split(': ', 1) for line in out.strip().split('\n'))
    priv_key = lines['PrivateKey']
    pub_key = lines['Password (PublicKey)']

    url = 'https://api.cloudflareclient.com/v0a3371/reg'
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    payload = {
        'key': pub_key,
        'install_id': '',
        'fcm_token': '',
        'tos': now,
        'model': 'PC',
        'serial_number': '',
        'locale': 'en_US'
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode('utf-8'),
        headers={'User-Agent': 'okhttp/3.12.1', 'Content-Type': 'application/json; charset=UTF-8'},
        method='POST'
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        res = json.loads(resp.read().decode())
        cfg = res['config']
        cid = cfg.get('client_id', '')
        reserved = list(base64.b64decode(cid)) if cid else [0, 0, 0]
        peer = cfg['peers'][0]
        v4_addr = cfg['interface']['addresses']['v4'] + '/32'

        with open('/tmp/warp_creds.json', 'w') as f:
            json.dump({
                'priv_key': priv_key,
                'v4_addr': v4_addr,
                'peer_pub': peer['public_key'],
                'reserved': reserved
            }, f)
except Exception as e:
    with open('/tmp/warp_creds.json', 'w') as f:
        json.dump({'failed': True, 'error': str(e)}, f)
"
        if [[ -f /tmp/warp_creds.json ]] && ! grep -q '"failed"' /tmp/warp_creds.json; then
            warp_priv=$(jq -r '.priv_key' /tmp/warp_creds.json)
            warp_v4=$(jq -r '.v4_addr' /tmp/warp_creds.json)
            warp_peer_pub=$(jq -r '.peer_pub' /tmp/warp_creds.json)
            warp_reserved=$(jq -c '.reserved' /tmp/warp_creds.json)
            has_warp=true
            rm -f /tmp/warp_creds.json
            msg_ok "Cloudflare WARP 注册就绪 (内网 IPv4: ${warp_v4})"
        else
            msg_warn "Cloudflare WARP 自动注册受阻，优雅回退至全 Direct 直连模式。"
            rm -f /tmp/warp_creds.json 2>/dev/null || true
        fi
    fi

    # 5. 构建 Xray 配置中的 IPv6 专属分流规则块
    local v6_rule_block=""
    local dns_query_strat="UseIPv4"

    if [[ "${IPV6_STRATEGY:-1}" == "1" ]]; then
        # 阻断所有直连 IPv6 目标请求，DNS 严格锁定 UseIPv4
        v6_rule_block=$(cat <<'EOF'
      {
        "type": "field",
        "ip": ["::/0"],
        "outboundTag": "block"
      },
EOF
)
        dns_query_strat="UseIPv4"
    elif [[ "${IPV6_STRATEGY:-1}" == "2" ]]; then
        # IPv6 目标走 WARP
        v6_rule_block=$(cat <<'EOF'
      {
        "type": "field",
        "ip": ["::/0"],
        "outboundTag": "warp"
      },
EOF
)
        dns_query_strat="UseIPv4"
    else
        v6_rule_block=""
        dns_query_strat="UseIP"
    fi

    # 6. 写入具有三重闭环与 DoH 加密解析的 config.json
    msg_info "写入 Xray 生产级配置文件: /usr/local/etc/xray/config.json ..."
    mkdir -p /usr/local/etc/xray /var/log/xray
    chown -R nobody:nogroup /var/log/xray

    if [[ -f /usr/local/etc/xray/config.json ]]; then
        cp /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak_$(date +%Y%m%d%H%M%S)"
    fi

    cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "queryStrategy": "${dns_query_strat}",
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query",
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIV_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }$(if [[ "$has_warp" == "true" ]]; then cat <<WARP_JSON
,
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${warp_priv}",
        "address": [
          "${warp_v4}"
        ],
        "peers": [
          {
            "publicKey": "${warp_peer_pub}",
            "endpoint": "162.159.192.1:2408"
          }
        ],
        "reserved": ${warp_reserved},
        "mtu": 1280
      },
      "tag": "warp"
    }
WARP_JSON
fi)
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
${v6_rule_block}
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "domain:geolocation.googleapis.com",
          "domain:geocode.googleapis.com",
          "domain:userlocation.googleapis.com",
          "domain:userlocations.googleapis.com",
          "domain:locationhistory-pa.googleapis.com",
          "domain:locationhistoryaggregates-pa.googleapis.com",
          "domain:locationhistoryplacedetails-pa.googleapis.com",
          "domain:semanticlocation-pa.googleapis.com",
          "domain:gs-loc.apple.com",
          "domain:gs-loc-cn.apple.com",
          "domain:maps-api.apple.com",
          "domain:ls.apple.com",
          "domain:location.services.mozilla.com",
          "domain:api.beacondb.net",
          "domain:location.microsoft.com",
          "domain:inference.location.live.net",
          "domain:api.skyhookwireless.com"
        ]
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": [
          "domain:play.google.com",
          "domain:play-fe.googleapis.com",
          "domain:play.googleapis.com",
          "domain:play-lh.googleusercontent.com",
          "domain:gvt1.com",
          "domain:gvt2.com",
          "domain:gvt3.com",
          "domain:xn--ngstr-lra8j.com",
          "domain:maven.google.com",
          "domain:storage-download.googleapis.com",
          "domain:googleapis.cn",
          "domain:android.clients.google.com",
          "domain:dl.google.com",
          "domain:dl-ssl.google.com",
          "domain:gstatic.com",
          "domain:googleusercontent.com"
        ],
        "outboundTag": "$(if [[ "$has_warp" == "true" ]]; then echo "warp"; else echo "direct"; fi)"
      },
      {
        "type": "field",
        "domain": [
          "geosite:google"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "$(if [[ "$has_warp" == "true" ]]; then echo "warp"; else echo "direct"; fi)"
      }
    ]
  }
}
EOF

    # 7. 配置 Logrotate 轮转规则
    msg_info "配置 /etc/logrotate.d/xray 日志安全轮转 (每日轮转 / 单文件上限 20MB / 保留 7 份)..."
    cat <<'EOF' > /etc/logrotate.d/xray
/var/log/xray/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    maxsize 20M
    su nobody nogroup
}
EOF

    # 8. 启动并测试 Xray
    systemctl daemon-reload
    if xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        systemctl restart xray
        systemctl enable xray >/dev/null 2>&1
        msg_ok "Xray 核心已成功启动并设置为开机自启！"
    else
        msg_err "Xray 配置文件测试失败，请检查 /usr/local/etc/xray/config.json"
        exit 1
    fi
}

# ── 17. 社区扩展能力 (IP-Sentinel 原生交互 & 可选 tcpfit) ────────────────────
optional_community_extensions() {
    msg_step "【扩展组件】社区专业工具按需交互 (IP-Sentinel & tcpfit)"

    # 1. IP-Sentinel 巡检哨兵
    echo ""
    read -rp "是否在此节点部署 IP-Sentinel 巡检与防风控哨兵？[y/N] (默认 N): " deploy_sentinel
    deploy_sentinel=${deploy_sentinel:-N}

    if [[ "$deploy_sentinel" =~ ^[Yy]$ ]]; then
        msg_info "正在直接拉起 IP-Sentinel 官方交互安装向导..."
        echo -e "${YELLOW}>> 提示: 官方脚本将自动检测端口、配置告警与防火墙，请按其原生提示输入即可。${NC}"
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/install.sh)" || true
        msg_ok "IP-Sentinel 安装流程执行完毕"
    else
        msg_info "已跳过 IP-Sentinel 部署。"
    fi

    # 2. tcpfit 深度画像与限速探测
    echo ""
    read -rp "是否立即启动 tcpfit 进行深度网络画像与限速拐点探测？[y/N] (默认 N，可随时在终端输入 tcpfit 单独执行): " run_tcpfit
    run_tcpfit=${run_tcpfit:-N}

    if [[ "$run_tcpfit" =~ ^[Yy]$ ]]; then
        msg_info "启动 tcpfit 社区调优引擎..."
        if command -v tcpfit >/dev/null 2>&1; then
            /usr/local/bin/tcpfit
        else
            bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)
        fi
    else
        msg_info "已跳过现场 tcpfit 测速。${BOLD}系统已具有原生 BBR+FQ 保底，后续有空可随时在终端输入 tcpfit 运行。${NC}"
    fi
}

# ── 18. 客户端订阅配置与交付 ─────────────────────────────────────────────────
generate_client_configs() {
    msg_step "【交付物】生成客户端开箱即用型订阅配置"

    local default_node_title="${NODE_FLAG} ${NODE_CITY} 落地"

    echo ""
    read -rp "请输入为此节点绑定的【直连域名】 (如 us-2-dir.yourdomain.com，直接回车使用公网 IP): " input_dir_dom
    local domain_dir=${input_dir_dom:-$SERVER_IP}

    read -rp "请输入为此节点绑定的【中继域名】 (如 us-2-rly.yourdomain.com，直接回车同上): " input_rly_dom
    local domain_rly=${input_rly_dom:-$domain_dir}

    echo ""
    echo "=========================================================================="
    echo -e "         ${BOLD}${GREEN}🎉 恭喜！NodeWizard 已成功完成工业级代理节点交付！${NC}"
    echo "=========================================================================="
    echo -e "  节点地理标识      : ${BOLD}${NODE_FLAG} ${NODE_COUNTRY} - ${NODE_CITY}${NC} (${NODE_ISP})"
    echo -e "  公网 IP 地址      : ${BOLD}${CYAN}${SERVER_IP}${NC}"
    echo -e "  SSH 登录端口      : ${BOLD}${YELLOW}${TARGET_SSH_PORT}${NC} (运维用户: ${MAINT_USER} / 仅密钥登录)"
    echo -e "  VLESS 监听端口    : ${BOLD}443 (TCP)${NC}"
    echo -e "  Reality 伪装源站  : ${BOLD}${REALITY_TARGET}${NC} (SNI: ${REALITY_SNI})"
    echo -e "  Reality PublicKey : ${BOLD}${GREEN}${REALITY_PUB_KEY}${NC}"
    echo -e "  Reality ShortId   : ${BOLD}${REALITY_SHORT_ID}${NC}"
    echo -e "  VLESS UUID        : ${BOLD}${VLESS_UUID}${NC}"
    echo -e "  Client Fingerprint: ${BOLD}chrome${NC}"
    echo -e "  核心安全防线      : ${BOLD}UFW 白名单 / Fail2ban / Geolocation黑洞 / WARP兜底 / BBR${NC}"
    echo "=========================================================================="

    echo -e "\n${BOLD}${BLUE}【1. Clash Meta (Mihomo) / Clash Verge 客户端配置块】${NC}"
    echo -e "${YELLOW}直接复制以下内容粘贴至你的 Clash 配置文件 proxies: 列表下：${NC}\n"

    cat <<EOF
proxies:
  # ================= 模式 1: 直连模式 (通过专用直连子域名) =================
  - name: "${default_node_title} [直连]"
    type: vless
    server: ${domain_dir}
    port: 443
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${REALITY_PUB_KEY}
      short-id: ${REALITY_SHORT_ID}
    client-fingerprint: chrome

  # ================= 模式 2: 链式中继模式 (通过专用中继子域名 + XUDP 防泄露) =================
  - name: "${default_node_title} [中继落地]"
    type: vless
    server: ${domain_rly}
    port: 443
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${REALITY_PUB_KEY}
      short-id: ${REALITY_SHORT_ID}
    client-fingerprint: chrome
    dialer-proxy: "机场-低延迟节点名称"   # <-- 替换为您已有中转/机场订阅中的节点名称
EOF

    echo -e "\n${BOLD}${BLUE}【2. Shadowrocket / 通用一键导入链接】${NC}"
    echo -e "* 直连模式："
    echo -e "${CYAN}vless://${VLESS_UUID}@${domain_dir}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${NODE_FLAG}%20${NODE_CITY}%E7%9B%B4%E8%BF%9E${NC}"
    echo -e "* 链式中继落地模式："
    echo -e "${CYAN}vless://${VLESS_UUID}@${domain_rly}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${NODE_FLAG}%20${NODE_CITY}%E4%B8%AD%E7%BB%A7%E8%90%BD%E5%9C%B0${NC}"

    echo -e "\n=========================================================================="
    echo -e "                   ${BOLD}${RED}⚠️  新机上线后必做的 3 项外部核验 ⚠️${NC}"
    echo "=========================================================================="
    echo -e " 1. ${BOLD}云服务商网页控制台安全组 (Security Group)${NC}："
    echo -e "    若机器位于 AWS / 阿里云 / 腾讯云 / 甲骨文 / 搬瓦工等，请在网页后台放行："
    echo -e "    - SSH 端口: ${BOLD}${YELLOW}${TARGET_SSH_PORT}/tcp${NC}"
    echo -e "    - Xray 端口: ${BOLD}${GREEN}443/tcp${NC}"
    echo ""
    echo -e " 2. ${BOLD}免密 SSH 登录测试 (千万别关当前窗口！)${NC}："
    echo -e "    请保持当前终端窗口打开，在本地另开新终端执行："
    echo -e "    ${BOLD}ssh -p ${TARGET_SSH_PORT} ${MAINT_USER}@${SERVER_IP}${NC}"
    echo -e "    测试确认能够成功免密登录且可 ${BOLD}sudo -i${NC} 后，方可关闭原窗口。"
    echo ""
    echo -e " 3. ${BOLD}Cloudflare DNS 域名解析 (若配置了子域名)${NC}："
    echo -e "    添加 A 记录指向 ${SERVER_IP}，${RED}${BOLD}务必保持灰云 (DNS only)${NC}，切勿开启小黄云 CDN！"
    echo "=========================================================================="
}

# ── 19. 调度入口与交互主菜单 ─────────────────────────────────────────────────
run_full_deployment() {
    install_dependencies
    setup_user_and_ssh
    setup_firewall_and_security
    setup_system_base_and_tcpfit
    configure_ipv6_policy
    select_reality_target
    setup_xray_and_warp
    optional_community_extensions
    generate_client_configs
}

run_security_only() {
    install_dependencies
    setup_user_and_ssh
    setup_firewall_and_security
    setup_system_base_and_tcpfit
    msg_ok "系统安全与 SSH 端口加固完成！"
}

run_proxy_only() {
    install_dependencies
    configure_ipv6_policy
    select_reality_target
    setup_xray_and_warp
    generate_client_configs
}

main() {
    check_environment
    detect_node_geo

    while true; do
        print_banner
        echo -e "当前节点定位: ${BOLD}${NODE_FLAG} ${NODE_COUNTRY} - ${NODE_CITY}${NC} (IP: ${CYAN}${SERVER_IP}${NC})\n"
        echo -e "请选择操作模式："
        echo -e "  ${BOLD}[1]${NC} ${GREEN}🚀 一键开启 NodeWizard 全自动交付 (基座加固 + Xray + WARP + 订阅)${NC}"
        echo -e "  ${BOLD}[2]${NC} ${CYAN}🔍 巡检当前节点配置状态 (查看已配端口/用户/防火墙/BBR/代理状态)${NC}"
        echo -e "  ${BOLD}[3]${NC} 🛡️ 仅执行系统安全与 SSH 端口加固 (用户/密钥/防火墙/Fail2ban)"
        echo -e "  ${BOLD}[4]${NC} ⚡ 仅安装 / 重构 Xray-Reality 核心与 WARP 路由矩阵"
        echo -e "  ${BOLD}[5]${NC} ${YELLOW}📋 查看当前客户端节点配置与订阅链接 (Clash Meta / Shadowrocket)${NC}"
        echo -e "  ${BOLD}[6]${NC} ${MAGENTA}🌐 IPv6 双栈治理与出站策略管理 (内核阻断/代理阻断/WARP代付/一键恢复)${NC}"
        echo -e "  ${BOLD}[0]${NC} 退出 NodeWizard"
        echo "=========================================================================="
        read -rp "请输入选项编号 [0-6] (默认 1): " main_opt
        main_opt=${main_opt:-1}

        case "$main_opt" in
            1)
                run_full_deployment
                break
                ;;
            2)
                audit_node_status
                ;;
            3)
                run_security_only
                break
                ;;
            4)
                run_proxy_only
                break
                ;;
            5)
                view_client_configs
                ;;
            6)
                manage_ipv6_menu
                ;;
            0)
                echo -e "\n已退出 NodeWizard。祝使用愉快！"
                exit 0
                ;;
            *)
                msg_warn "输入无效，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

main "$@"
