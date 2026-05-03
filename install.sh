#!/bin/bash

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ==================== 路径配置 ====================
CONFIG_FILE="/etc/sing-box/config.json"
INSTALL_DIR="/usr/local/bin"
CERT_DIR="/etc/sing-box/certs"
LINK_DIR="/etc/sing-box/links"
KEY_FILE="/etc/sing-box/keys.txt"

ALL_LINKS_FILE="${LINK_DIR}/all.txt"
REALITY_LINKS_FILE="${LINK_DIR}/reality.txt"
HYSTERIA2_LINKS_FILE="${LINK_DIR}/hysteria2.txt"
SOCKS5_LINKS_FILE="${LINK_DIR}/socks5.txt"
SHADOWTLS_LINKS_FILE="${LINK_DIR}/shadowtls.txt"
HTTPS_LINKS_FILE="${LINK_DIR}/https.txt"
ANYTLS_LINKS_FILE="${LINK_DIR}/anytls.txt"

SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

# ==================== 全局变量 ====================
INBOUNDS_JSON=""                 # 所有入站 JSON 字符串
ALL_LINKS_TEXT=""                # 全部链接文本
SERVER_IP=""                     # 主 IPv4 地址
SERVER_IPV6=""                   # IPv6 地址
INBOUND_IP_MODE="ipv4"           # 入站监听地址族
OUTBOUND_IP_MODE="dual"          # 出站连接地址族
IP_CONFIG_FILE="/etc/sing-box/ip_config.conf"

RELAY_TAGS=()                    # 中转标签
RELAY_JSONS=()                   # 中转 JSON 配置
RELAY_DESCS=()                   # 中转描述
RELAY_FILE="/etc/sing-box/relays.conf"

INBOUND_TAGS=()                  # 节点标签
INBOUND_PORTS=()                 # 节点端口
INBOUND_PROTOS=()                # 节点协议
INBOUND_RELAY_TAGS=()            # 节点绑定的中转标签（"direct" 为直连）
INBOUND_SNIS=()                  # 节点 SNI

# 全局密钥（仅用于 Reality 公私钥等不变部分）
UUID=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
SHORT_ID=""
HY2_PASSWORD=""
SS_PASSWORD=""
SHADOWTLS_PASSWORD=""
ANYTLS_PASSWORD=""
SOCKS_USER=""
SOCKS_PASS=""

DEFAULT_SNI="time.is"

# ==================== 打印函数 ====================
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
show_banner()   { clear; echo ""; }
# ==================== 系统检测（兼容 Alpine） ====================
detect_system() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS="${ID}"
    elif [[ -f /etc/alpine-release ]]; then
        OS="alpine"
    else
        print_error "无法检测系统"; exit 1
    fi
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    print_success "系统: ${OS} (${ARCH})"
}

# ==================== 依赖安装 ====================
ensure_deps() {
    print_info "检查系统依赖..."
    if ! command -v jq &>/dev/null || ! command -v openssl &>/dev/null; then
        print_info "安装依赖包..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y curl wget jq openssl uuid-runtime >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk update && apk add curl wget jq openssl util-linux >/dev/null 2>&1
        else
            print_error "不支持的包管理器"; return 1
        fi
    fi
    print_success "依赖检查完成"
}

# ==================== sing-box 安装/更新（手动触发） ====================
install_or_update_singbox() {
    ensure_deps || { print_error "依赖安装失败"; return 1; }

    LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
    [[ -z "$LATEST" ]] && LATEST="1.12.0"

    if command -v sing-box &>/dev/null; then
        CURRENT=$(sing-box version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        print_info "当前版本: ${CURRENT}，最新版本: ${LATEST}"
        if [[ "$CURRENT" == "$LATEST" ]]; then
            print_success "已是最新版本，无需更新"; return 0
        fi
        echo -e "${YELLOW}发现新版本！${NC}"
        echo -e "  ${GREEN}[1]${NC} 更新到最新版本"
        echo -e "  ${GREEN}[2]${NC} 不更新，继续使用当前版本"
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -p "请选择 [0-2]: " ver_choice
        case $ver_choice in
            1) ;;
            2) print_info "跳过更新"; return 0 ;;
            0) return 0 ;;
            *) print_error "无效选择"; return 0 ;;
        esac
    else
        echo -e "${YELLOW}sing-box 未安装，准备下载安装...${NC}"
    fi

    print_info "下载 sing-box v${LATEST}..."
    wget -q --show-progress -O /tmp/sb.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz" || { print_error "下载失败"; return 1; }
    tar -xzf /tmp/sb.tar.gz -C /tmp || { print_error "解压失败"; rm -rf /tmp/sb.tar.gz /tmp/sing-box-*; return 1; }
    install -Dm755 /tmp/sing-box-${LATEST}-linux-${ARCH}/sing-box ${INSTALL_DIR}/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

    # 创建服务
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/sing-box.service << 'EOFSVC'
[Unit]
Description=sing-box service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
[Install]
WantedBy=multi-user.target
EOFSVC
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
    elif command -v rc-service &>/dev/null; then
        cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
    fi
    print_success "sing-box ${LATEST} 安装/更新完成"
}

# ==================== 证书生成 ====================
gen_cert_for_sni() {
    local sni="$1"
    local node_cert_dir="${CERT_DIR}/${sni}"
    mkdir -p "${node_cert_dir}"
    openssl genrsa -out "${node_cert_dir}/private.key" 2048 2>/dev/null
    openssl req -new -x509 -days 36500 -key "${node_cert_dir}/private.key" \
        -out "${node_cert_dir}/cert.pem" -subj "/C=US/ST=California/L=Cupertino/O=Apple Inc./CN=${sni}" 2>/dev/null
    print_success "证书生成完成"
}
# ==================== 密钥管理 ====================
gen_keys() {
    print_info "生成密钥和 UUID..."
    if [[ -f "${KEY_FILE}" ]]; then
        source "${KEY_FILE}"
        print_success "密钥已加载"; return 0
    fi
    KEYS=$(${INSTALL_DIR}/sing-box generate reality-keypair 2>/dev/null)
    REALITY_PRIVATE=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    SHORT_ID=$(openssl rand -hex 8)
    HY2_PASSWORD=$(openssl rand -hex 16)
    SS_PASSWORD=$(openssl rand -base64 16)
    SHADOWTLS_PASSWORD=$(openssl rand -hex 16)
    ANYTLS_PASSWORD=$(openssl rand -hex 16)
    SOCKS_USER="user_$(openssl rand -hex 4)"
    SOCKS_PASS=$(openssl rand -hex 16)
    save_keys_to_file
    print_success "密钥生成完成"
}

save_keys_to_file() {
    mkdir -p "$(dirname "${KEY_FILE}")"
    cat > "${KEY_FILE}" << EOF
UUID="${UUID}"
REALITY_PRIVATE="${REALITY_PRIVATE}"
REALITY_PUBLIC="${REALITY_PUBLIC}"
SHORT_ID="${SHORT_ID}"
HY2_PASSWORD="${HY2_PASSWORD}"
SS_PASSWORD="${SS_PASSWORD}"
SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD}"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD}"
SOCKS_USER="${SOCKS_USER}"
SOCKS_PASS="${SOCKS_PASS}"
EOF
    chmod 600 "${KEY_FILE}"
}

# ==================== 链接文件管理 ====================
save_links_to_files() {
    mkdir -p "${LINK_DIR}"
    echo -en "${ALL_LINKS_TEXT}"     > "${ALL_LINKS_FILE}"
    echo -en "${REALITY_LINKS}"      > "${REALITY_LINKS_FILE}"
    echo -en "${HYSTERIA2_LINKS}"    > "${HYSTERIA2_LINKS_FILE}"
    echo -en "${SOCKS5_LINKS}"       > "${SOCKS5_LINKS_FILE}"
    echo -en "${SHADOWTLS_LINKS}"    > "${SHADOWTLS_LINKS_FILE}"
    echo -en "${HTTPS_LINKS}"        > "${HTTPS_LINKS_FILE}"
    echo -en "${ANYTLS_LINKS}"       > "${ANYTLS_LINKS_FILE}"
    chmod 700 "${LINK_DIR}" 2>/dev/null || true
}

load_links_from_files() {
    mkdir -p "${LINK_DIR}"
    [[ -f "${ALL_LINKS_FILE}" ]]        && ALL_LINKS_TEXT=$(cat "${ALL_LINKS_FILE}")
    [[ -f "${REALITY_LINKS_FILE}" ]]    && REALITY_LINKS=$(cat "${REALITY_LINKS_FILE}")
    [[ -f "${HYSTERIA2_LINKS_FILE}" ]]  && HYSTERIA2_LINKS=$(cat "${HYSTERIA2_LINKS_FILE}")
    [[ -f "${SOCKS5_LINKS_FILE}" ]]     && SOCKS5_LINKS=$(cat "${SOCKS5_LINKS_FILE}")
    [[ -f "${SHADOWTLS_LINKS_FILE}" ]]  && SHADOWTLS_LINKS=$(cat "${SHADOWTLS_LINKS_FILE}")
    [[ -f "${HTTPS_LINKS_FILE}" ]]      && HTTPS_LINKS=$(cat "${HTTPS_LINKS_FILE}")
    [[ -f "${ANYTLS_LINKS_FILE}" ]]     && ANYTLS_LINKS=$(cat "${ANYTLS_LINKS_FILE}")
}

load_inbounds_from_config() {
    [[ ! -f "${CONFIG_FILE}" ]] && return 1
    command -v jq &>/dev/null || return 1
    INBOUND_TAGS=(); INBOUND_PORTS=(); INBOUND_PROTOS=(); INBOUND_SNIS=(); INBOUND_RELAY_TAGS=(); INBOUNDS_JSON=""
    local inbounds_count=$(jq '.inbounds | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
    [[ "$inbounds_count" -eq 0 ]] && return 1

    local inbound_list=""
    for ((i=0; i<inbounds_count; i++)); do
        local inbound=$(jq -c ".inbounds[${i}]" "${CONFIG_FILE}" 2>/dev/null)
        [[ -z "$inbound" ]] && continue
        # 拼接完整的 INBOUNDS_JSON
        [[ -z "$inbound_list" ]] && inbound_list="$inbound" || inbound_list="${inbound_list},${inbound}"
        local tag=$(echo "$inbound" | jq -r '.tag' 2>/dev/null)
        local port=$(echo "$inbound" | jq -r '.listen_port' 2>/dev/null)
        local type=$(echo "$inbound" | jq -r '.type' 2>/dev/null)
        [[ "$tag" == "shadowsocks-in-"* ]] && continue   # 不显示内部组件

        local proto="unknown"; local sni=""
        if [[ "$tag" == *"vless-in-"* ]]; then proto="Reality"; sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        elif [[ "$tag" == *"hy2-in-"* ]]; then proto="Hysteria2"; sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        elif [[ "$tag" == *"shadowtls-in-"* ]]; then proto="ShadowTLS v3"; sni=$(echo "$inbound" | jq -r '.handshake.server // ""' 2>/dev/null)
        elif [[ "$tag" == *"socks-in"* ]]; then proto="SOCKS5"
        elif [[ "$tag" == *"vless-tls-in-"* ]]; then proto="HTTPS"; sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        elif [[ "$tag" == *"anytls-in-"* ]]; then proto="AnyTLS"; sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        fi
        [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
        INBOUND_TAGS+=("$tag"); INBOUND_PORTS+=("$port"); INBOUND_PROTOS+=("$proto"); INBOUND_SNIS+=("$sni"); INBOUND_RELAY_TAGS+=("direct")
    done
    INBOUNDS_JSON="$inbound_list"

    # 恢复中转规则
    local route_rules=$(jq -c '.route.rules[]? // empty' "${CONFIG_FILE}" 2>/dev/null)
    [[ -n "$route_rules" ]] && while IFS= read -r rule; do
        local inbound_array=$(echo "$rule" | jq -r '.inbound[]? // empty' 2>/dev/null)
        local outbound=$(echo "$rule" | jq -r '.outbound // ""' 2>/dev/null)
        [[ -n "$outbound" && "$outbound" != "direct" ]] && while IFS= read -r inbound_tag; do
            for i in "${!INBOUND_TAGS[@]}"; do
                [[ "${INBOUND_TAGS[$i]}" == "$inbound_tag" ]] && INBOUND_RELAY_TAGS[$i]="$outbound" && break
            done
        done <<< "$inbound_array"
    done <<< "$route_rules"
    return 0
}

regenerate_links_from_config() {
    print_info "正在从配置文件重新生成链接..."
    ALL_LINKS_TEXT=""; REALITY_LINKS=""; HYSTERIA2_LINKS=""; SOCKS5_LINKS=""; SHADOWTLS_LINKS=""; HTTPS_LINKS=""; ANYTLS_LINKS=""
    [[ -f "${KEY_FILE}" ]] && source "${KEY_FILE}"
    [[ -z "${SERVER_IP}" ]] && get_ip
    [[ ! -f "${CONFIG_FILE}" ]] && { print_warning "配置文件不存在"; return 1; }
    local inbounds_count=$(jq '.inbounds | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
    for ((i=0; i<inbounds_count; i++)); do
        local inbound=$(jq -c ".inbounds[${i}]" "${CONFIG_FILE}" 2>/dev/null)
        local type=$(echo "$inbound" | jq -r '.type' 2>/dev/null)
        local port=$(echo "$inbound" | jq -r '.listen_port' 2>/dev/null)
        case "$type" in
            vless) # 包含 Reality 和 HTTPS
                if [[ "$(echo "$inbound" | jq -r '.tls.enabled // false')" == "true" ]]; then
                    if [[ "$(echo "$inbound" | jq -r '.tls.reality.enabled // false')" == "true" ]]; then
                        local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // ""')
                        local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""'); [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                        local pbk=$(echo "$inbound" | jq -r '.tls.reality.public_key // ""'); [[ -z "$pbk" ]] && pbk="${REALITY_PUBLIC}"
                        local sid=$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // ""'); [[ -z "$sid" ]] && sid="${SHORT_ID}"
                        local link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Reality-${SERVER_IP}"
                        local line="[Reality] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                        ALL_LINKS_TEXT+="$line"; REALITY_LINKS+="$line"
                    else
                        local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // ""')
                        local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""'); [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                        local link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&security=tls&sni=${sni}&type=tcp&allowInsecure=1#HTTPS-${SERVER_IP}"
                        local line="[HTTPS] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                        ALL_LINKS_TEXT+="$line"; HTTPS_LINKS+="$line"
                    fi
                fi
                ;;
            hysteria2)
                local password=$(echo "$inbound" | jq -r '.users[0].password // ""')
                local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""'); [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                local link="hysteria2://${password}@${SERVER_IP}:${port}?insecure=1&sni=${sni}#Hysteria2-${SERVER_IP}"
                local line="[Hysteria2] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                ALL_LINKS_TEXT+="$line"; HYSTERIA2_LINKS+="$line"
                ;;
            socks)
                local username=$(echo "$inbound" | jq -r '.users[0].username // ""')
                local password=$(echo "$inbound" | jq -r '.users[0].password // ""')
                local link
                [[ -n "$username" ]] && link="socks5://${username}:${password}@${SERVER_IP}:${port}#SOCKS5-${SERVER_IP}" || link="socks5://${SERVER_IP}:${port}#SOCKS5-${SERVER_IP}"
                local line="[SOCKS5] ${SERVER_IP}:${port}\n${link}\n----------------------------------------\n\n"
                ALL_LINKS_TEXT+="$line"; SOCKS5_LINKS+="$line"
                ;;
            shadowtls)
                local stls_pass=$(echo "$inbound" | jq -r '.users[0].password // ""')
                local sni=$(echo "$inbound" | jq -r '.handshake.server // ""'); [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                local ss_inbound=$(jq -c ".inbounds[] | select(.tag == \"shadowsocks-in-${port}\")" "${CONFIG_FILE}" 2>/dev/null)
                local ss_pass=$(echo "$ss_inbound" | jq -r '.password // ""')
                local ss_method=$(echo "$ss_inbound" | jq -r '.method // "2022-blake3-aes-128-gcm"')
                local ss_userinfo=$(echo -n "${ss_method}:${ss_pass}" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
                local plugin_json="{\"version\":\"3\",\"password\":\"${stls_pass}\",\"host\":\"${sni}\",\"port\":\"${port}\",\"address\":\"${SERVER_IP}\"}"
                local plugin_base64=$(echo -n "$plugin_json" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
                local link="ss://${ss_userinfo}@${SERVER_IP}:${port}?shadow-tls=${plugin_base64}#ShadowTLS-${SERVER_IP}"
                local line="[ShadowTLS v3] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                ALL_LINKS_TEXT+="$line"; SHADOWTLS_LINKS+="$line"
                ;;
            anytls)
                local password=$(echo "$inbound" | jq -r '.users[0].password // ""')
                local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""'); [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                local link="anytls://${password}@${SERVER_IP}:${port}?security=tls&fp=chrome&insecure=1&sni=${sni}&type=tcp#AnyTLS-${SERVER_IP}"
                local line="[AnyTLS] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                ALL_LINKS_TEXT+="$line"; ANYTLS_LINKS+="$line"
                ;;
        esac
    done
    save_links_to_files
    print_success "链接重新生成完成"
}
# ==================== 网络工具 ====================
get_ip() {
    local ipv4=$(curl -s4m5 ifconfig.me || curl -s4m5 api.ipify.org || curl -s4m5 ip.sb)
    local ipv6=$(curl -s6m5 ifconfig.me || curl -s6m5 api6.ipify.org || curl -s6m5 ip.sb)
    [[ -n "$ipv4" ]] && echo -e "IPv4: ${ipv4}" || echo "无IPv4"
    [[ -n "$ipv6" ]] && echo -e "IPv6: ${ipv6}" || echo "无IPv6"
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then print_error "无法获取IP"; exit 1; fi
    if [[ -n "$ipv4" ]]; then SERVER_IP="$ipv4"; SERVER_IPV6="$ipv6"
    else SERVER_IP="$ipv6"; INBOUND_IP_MODE="ipv6"; fi
    save_ip_config
}

check_port_in_use() { ss -tuln 2>/dev/null | grep -q ":${1} " && return 0 || return 1; }

read_port_with_check() {
    while true; do
        read -p "监听端口 [${1}]: " PORT; PORT=${PORT:-$1}
        [[ ! "$PORT" =~ ^[0-9]+$ || $PORT -lt 1 || $PORT -gt 65535 ]] && { print_error "端口无效"; continue; }
        check_port_in_use "$PORT" && { print_warning "端口占用"; continue; }
        break
    done
}

save_ip_config() {
    mkdir -p "$(dirname "${IP_CONFIG_FILE}")"
    cat > "${IP_CONFIG_FILE}" << EOF
SERVER_IP="${SERVER_IP}"
SERVER_IPV6="${SERVER_IPV6}"
INBOUND_IP_MODE="${INBOUND_IP_MODE}"
OUTBOUND_IP_MODE="${OUTBOUND_IP_MODE}"
EOF
}
load_ip_config() { [[ -f "${IP_CONFIG_FILE}" ]] && source "${IP_CONFIG_FILE}"; }

# ==================== 中转配置管理 ====================
save_relays_to_file() {
    mkdir -p "$(dirname "${RELAY_FILE}")"
    echo "# Sing-box 中转配置" > "${RELAY_FILE}"
    for i in "${!RELAY_TAGS[@]}"; do
        local b64=$(echo "${RELAY_JSONS[$i]}" | base64 -w0)
        echo "${RELAY_TAGS[$i]}|${RELAY_DESCS[$i]}|${b64}" >> "${RELAY_FILE}"
    done
}
load_relays_from_file() {
    RELAY_TAGS=(); RELAY_JSONS=(); RELAY_DESCS=()
    [[ ! -f "${RELAY_FILE}" ]] && return
    while IFS='|' read -r tag desc b64; do
        [[ "$tag" =~ ^# ]] && continue
        local json=$(echo "$b64" | base64 -d 2>/dev/null)
        [[ -n "$json" ]] && RELAY_TAGS+=("$tag") && RELAY_DESCS+=("$desc") && RELAY_JSONS+=("$json")
    done < "${RELAY_FILE}"
}

# ==================== 随机凭证生成 ====================
gen_random_uuid()      { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_random_hex16()     { openssl rand -hex 16; }
gen_random_base64_16() { openssl rand -base64 16; }
gen_random_user()      { echo "user_$(openssl rand -hex 4)"; }

# ==================== 中转链接解析 ====================
parse_socks_link() {
    local link="$1"
    local data=$(echo "$link" | sed 's|socks5\?://||' | cut -d'#' -f1)
    local tag="relay-socks5-${#RELAY_TAGS[@]}"
    if [[ "$data" == *"@"* ]]; then
        local userpass=$(echo "$data" | cut -d'@' -f1)
        local username=$(echo "$userpass" | cut -d':' -f1)
        local password=$(echo "$userpass" | cut -d':' -f2-)
        local server_port=$(echo "$data" | cut -d'@' -f2)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2)
        RELAY_TAGS+=("$tag")
        RELAY_JSONS+=("{\"type\":\"socks\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"version\":\"5\",\"username\":\"$username\",\"password\":\"$password\"}")
        RELAY_DESCS+=("SOCKS5 $server:$port (认证)")
    else
        local server=$(echo "$data" | cut -d':' -f1)
        local port=$(echo "$data" | cut -d':' -f2)
        RELAY_TAGS+=("$tag")
        RELAY_JSONS+=("{\"type\":\"socks\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"version\":\"5\"}")
        RELAY_DESCS+=("SOCKS5 $server:$port")
    fi
    save_relays_to_file
    print_success "已添加 SOCKS5 中转"
}

parse_http_link() {
    local link="$1"
    local proto=$(echo "$link" | cut -d':' -f1)
    local data=$(echo "$link" | sed 's|https\?://||')
    local tls="false"; [[ "$proto" == "https" ]] && tls="true"
    local tag="relay-http-${#RELAY_TAGS[@]}"
    if [[ "$data" == *"@"* ]]; then
        local userpass=$(echo "$data" | cut -d'@' -f1)
        local username=$(echo "$userpass" | cut -d':' -f1)
        local password=$(echo "$userpass" | cut -d':' -f2)
        local server_port=$(echo "$data" | cut -d'@' -f2 | cut -d'/' -f1)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2)
        RELAY_TAGS+=("$tag")
        RELAY_JSONS+=("{\"type\":\"http\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"username\":\"$username\",\"password\":\"$password\",\"tls\":{\"enabled\":$tls}}")
        RELAY_DESCS+=("HTTP(S) $server:$port (认证)")
    else
        local server=$(echo "$data" | cut -d':' -f1)
        local port=$(echo "$data" | cut -d':' -f2 | cut -d'/' -f1)
        RELAY_TAGS+=("$tag")
        RELAY_JSONS+=("{\"type\":\"http\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"tls\":{\"enabled\":$tls}}")
        RELAY_DESCS+=("HTTP(S) $server:$port")
    fi
    save_relays_to_file
    print_success "已添加 HTTP(S) 中转"
}

parse_ss_link() {
    local link="$1"
    local data=$(echo "$link" | sed 's|ss://||' | cut -d'#' -f1)
    if [[ "$data" != *"@"* ]]; then print_error "SS 链接格式错误"; return 1; fi
    local userinfo=$(echo "$data" | cut -d'@' -f1)
    local server_port=$(echo "$data" | cut -d'@' -f2 | cut -d'?' -f1)
    local server=$(echo "$server_port" | cut -d':' -f1)
    local port=$(echo "$server_port" | cut -d':' -f2)
    local decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
    local method=$(echo "$decoded" | cut -d':' -f1)
    local password=$(echo "$decoded" | cut -d':' -f2-)
    local tag="relay-ss-${#RELAY_TAGS[@]}"
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("{\"type\":\"shadowsocks\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"method\":\"$method\",\"password\":\"$password\"}")
    RELAY_DESCS+=("Shadowsocks $server:$port")
    save_relays_to_file
    print_success "已添加 Shadowsocks 中转"
}

parse_vmess_link() {
    local link="$1"
    local base64_data=$(echo "$link" | sed 's|vmess://||')
    local json=$(echo "$base64_data" | base64 -d 2>/dev/null)
    [[ -z "$json" ]] && { print_error "VMess 解码失败"; return 1; }
    local server=$(echo "$json" | jq -r '.add // .address')
    local port=$(echo "$json" | jq -r '.port')
    local uuid=$(echo "$json" | jq -r '.id')
    local alterId=$(echo "$json" | jq -r '.aid // 0')
    local security=$(echo "$json" | jq -r '.scy // "auto"')
    local tag="relay-vmess-${#RELAY_TAGS[@]}"
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("{\"type\":\"vmess\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"uuid\":\"$uuid\",\"alter_id\":$alterId,\"security\":\"$security\"}")
    RELAY_DESCS+=("VMess $server:$port")
    save_relays_to_file
    print_success "已添加 VMess 中转"
}

parse_vless_link() {
    local link="$1"
    local data=$(echo "$link" | sed 's|vless://||')
    local uuid=$(echo "$data" | cut -d'@' -f1)
    local server_port_params=$(echo "$data" | cut -d'@' -f2)
    local server=$(echo "$server_port_params" | cut -d':' -f1)
    local port_params=$(echo "$server_port_params" | cut -d':' -f2)
    local port=$(echo "$port_params" | cut -d'?' -f1)
    local params=$(echo "$port_params" | grep -o '?.*' | sed 's|?||' | cut -d'#' -f1)
    local security="none"; local sni=""; local flow=""
    [[ "$params" =~ security=([^&]+) ]] && security="${BASH_REMATCH[1]}"
    [[ "$params" =~ sni=([^&]+) ]] && sni="${BASH_REMATCH[1]}"
    [[ "$params" =~ flow=([^&]+) ]] && flow="${BASH_REMATCH[1]}"
    local tls_config=""
    [[ "$security" == "tls" || "$security" == "reality" ]] && tls_config=",\"tls\":{\"enabled\":true,\"server_name\":\"$sni\"}"
    local flow_config=""; [[ -n "$flow" ]] && flow_config=",\"flow\":\"$flow\""
    local tag="relay-vless-${#RELAY_TAGS[@]}"
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("{\"type\":\"vless\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"uuid\":\"$uuid\"${flow_config}${tls_config}}")
    RELAY_DESCS+=("VLESS $server:$port")
    save_relays_to_file
    print_success "已添加 VLESS 中转"
}

parse_trojan_link() {
    local link="$1"
    local data=$(echo "$link" | sed 's|trojan://||')
    local password=$(echo "$data" | cut -d'@' -f1)
    local server_port_params=$(echo "$data" | cut -d'@' -f2)
    local server=$(echo "$server_port_params" | cut -d':' -f1)
    local port_params=$(echo "$server_port_params" | cut -d':' -f2)
    local port=$(echo "$port_params" | cut -d'?' -f1)
    local params=$(echo "$port_params" | grep -o '?.*' | sed 's|?||' | cut -d'#' -f1)
    local sni=""; [[ "$params" =~ sni=([^&]+) ]] && sni="${BASH_REMATCH[1]}"
    local tag="relay-trojan-${#RELAY_TAGS[@]}"
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("{\"type\":\"trojan\",\"tag\":\"$tag\",\"server\":\"$server\",\"server_port\":$port,\"password\":\"$password\",\"tls\":{\"enabled\":true,\"server_name\":\"$sni\"}}")
    RELAY_DESCS+=("Trojan $server:$port")
    save_relays_to_file
    print_success "已添加 Trojan 中转"
}

# ==================== 节点添加（每个节点独立随机凭证） ====================
# Reality
setup_reality() {
    echo ""; read_port_with_check 443
    read -p "伪装域名 [${DEFAULT_SNI}]: " SNI; SNI=${SNI:-${DEFAULT_SNI}}
    local default_uuid=$(gen_random_uuid)
    echo -e "节点 UUID (回车使用随机):"
    read -p "UUID [${default_uuid}]: " use_uuid; use_uuid=${use_uuid:-$default_uuid}
    local inbound="{\"type\":\"vless\",\"tag\":\"vless-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT},\"users\":[{\"uuid\":\"${use_uuid}\",\"flow\":\"xtls-rprx-vision\"}],\"tls\":{\"enabled\":true,\"server_name\":\"${SNI}\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"${SNI}\",\"server_port\":443},\"private_key\":\"${REALITY_PRIVATE}\",\"short_id\":[\"${SHORT_ID}\"]}}}"
    [[ -z "$INBOUNDS_JSON" ]] && INBOUNDS_JSON="$inbound" || INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    LINK="vless://${use_uuid}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#Reality-${SERVER_IP}"
    local line="[Reality] ${SERVER_IP}:${PORT} (SNI: ${SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT+="$line"; REALITY_LINKS+="$line"
    INBOUND_TAGS+=("vless-in-${PORT}"); INBOUND_PORTS+=("${PORT}"); INBOUND_PROTOS+=("Reality"); INBOUND_SNIS+=("${SNI}"); INBOUND_RELAY_TAGS+=("direct")
    print_success "Reality 添加完成"; save_links_to_files
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ 节点链接（可直接复制）:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "UUID: ${use_uuid}  |  端口: ${PORT}"
    echo -e "伪装域名: ${SNI}"
    echo ""
    read -p "按回车继续..." _
}

# Hysteria2
setup_hysteria2() {
    echo ""; read_port_with_check 443
    read -p "伪装域名 [${DEFAULT_SNI}]: " HY2_SNI; HY2_SNI=${HY2_SNI:-${DEFAULT_SNI}}
    local default_pass=$(gen_random_hex16)
    echo -e "节点密码 (回车使用随机):"
    read -p "密码 [${default_pass}]: " use_pass; use_pass=${use_pass:-$default_pass}
    gen_cert_for_sni "${HY2_SNI}" || return 1
    local inbound="{\"type\":\"hysteria2\",\"tag\":\"hy2-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT},\"users\":[{\"password\":\"${use_pass}\"}],\"tls\":{\"enabled\":true,\"alpn\":[\"h3\"],\"server_name\":\"${HY2_SNI}\",\"certificate_path\":\"${CERT_DIR}/${HY2_SNI}/cert.pem\",\"key_path\":\"${CERT_DIR}/${HY2_SNI}/private.key\"}}"
    [[ -z "$INBOUNDS_JSON" ]] && INBOUNDS_JSON="$inbound" || INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    LINK="hysteria2://${use_pass}@${SERVER_IP}:${PORT}?insecure=1&sni=${HY2_SNI}#Hysteria2-${SERVER_IP}"
    local line="[Hysteria2] ${SERVER_IP}:${PORT} (SNI: ${HY2_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT+="$line"; HYSTERIA2_LINKS+="$line"
    INBOUND_TAGS+=("hy2-in-${PORT}"); INBOUND_PORTS+=("${PORT}"); INBOUND_PROTOS+=("Hysteria2"); INBOUND_SNIS+=("${HY2_SNI}"); INBOUND_RELAY_TAGS+=("direct")
    print_success "Hysteria2 添加完成"; save_links_to_files
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ 节点链接（可直接复制）:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "密码: ${use_pass}  |  端口: ${PORT}"
    echo -e "伪装域名: ${HY2_SNI}"
    echo ""
    read -p "按回车继续..." _
}

# SOCKS5
setup_socks5() {
    echo ""; read_port_with_check 1080
    read -p "启用认证? [Y/n]: " ENABLE_AUTH; ENABLE_AUTH=${ENABLE_AUTH:-Y}
    local use_user=""; local use_pass=""; local inbound=""; local link=""
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        local default_user=$(gen_random_user); local default_pass=$(gen_random_hex16)
        read -p "用户名 [${default_user}]: " use_user; use_user=${use_user:-$default_user}
        read -p "密码 [${default_pass}]: " use_pass; use_pass=${use_pass:-$default_pass}
        inbound="{\"type\":\"socks\",\"tag\":\"socks-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT},\"users\":[{\"username\":\"${use_user}\",\"password\":\"${use_pass}\"}]}"
        link="socks5://${use_user}:${use_pass}@${SERVER_IP}:${PORT}#SOCKS5-${SERVER_IP}"
    else
        inbound="{\"type\":\"socks\",\"tag\":\"socks-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT}}"
        link="socks5://${SERVER_IP}:${PORT}#SOCKS5-${SERVER_IP}"
    fi
    [[ -z "$INBOUNDS_JSON" ]] && INBOUNDS_JSON="$inbound" || INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    local line="[SOCKS5] ${SERVER_IP}:${PORT}\n${link}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT+="$line"; SOCKS5_LINKS+="$line"
    INBOUND_TAGS+=("socks-in-${PORT}"); INBOUND_PORTS+=("${PORT}"); INBOUND_PROTOS+=("SOCKS5"); INBOUND_SNIS+=(""); INBOUND_RELAY_TAGS+=("direct")
    print_success "SOCKS5 添加完成"; save_links_to_files
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ 节点链接（可直接复制）:${NC}"
    echo -e "${YELLOW}${link}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        echo -e "用户名: ${use_user}  |  密码: ${use_pass}"
    else
        echo -e "无认证"
    fi
    echo -e "端口: ${PORT}"
    echo ""
    read -p "按回车继续..." _
}

# ShadowTLS
setup_shadowtls() {
    echo ""; read_port_with_check 443
    read -p "伪装域名 [${DEFAULT_SNI}]: " SHADOWTLS_SNI; SHADOWTLS_SNI=${SHADOWTLS_SNI:-${DEFAULT_SNI}}
    local default_stls_pass=$(gen_random_hex16); local default_ss_pass=$(gen_random_base64_16)
    read -p "ShadowTLS密码 [${default_stls_pass}]: " use_stls_pass; use_stls_pass=${use_stls_pass:-$default_stls_pass}
    read -p "Shadowsocks密码 [${default_ss_pass}]: " use_ss_pass; use_ss_pass=${use_ss_pass:-$default_ss_pass}
    local inbound="{\"type\":\"shadowtls\",\"tag\":\"shadowtls-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT},\"version\":3,\"users\":[{\"password\":\"${use_stls_pass}\"}],\"handshake\":{\"server\":\"${SHADOWTLS_SNI}\",\"server_port\":443},\"strict_mode\":true,\"detour\":\"shadowsocks-in-${PORT}\"},{\"type\":\"shadowsocks\",\"tag\":\"shadowsocks-in-${PORT}\",\"listen\":\"127.0.0.1\",\"network\":\"tcp\",\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"${use_ss_pass}\"}"
    [[ -z "$INBOUNDS_JSON" ]] && INBOUNDS_JSON="$inbound" || INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    local ss_userinfo=$(echo -n "2022-blake3-aes-128-gcm:${use_ss_pass}" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
    local plugin_json="{\"version\":\"3\",\"password\":\"${use_stls_pass}\",\"host\":\"${SHADOWTLS_SNI}\",\"port\":\"${PORT}\",\"address\":\"${SERVER_IP}\"}"
    local plugin_b64=$(echo -n "$plugin_json" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
    LINK="ss://${ss_userinfo}@${SERVER_IP}:${PORT}?shadow-tls=${plugin_b64}#ShadowTLS-${SERVER_IP}"
    local line="[ShadowTLS v3] ${SERVER_IP}:${PORT} (SNI: ${SHADOWTLS_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT+="$line"; SHADOWTLS_LINKS+="$line"
    INBOUND_TAGS+=("shadowtls-in-${PORT}"); INBOUND_PORTS+=("${PORT}"); INBOUND_PROTOS+=("ShadowTLS v3"); INBOUND_SNIS+=("${SHADOWTLS_SNI}"); INBOUND_RELAY_TAGS+=("direct")
    print_success "ShadowTLS 添加完成"; save_links_to_files
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ 节点链接（可直接复制）:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "ShadowTLS密码: ${use_stls_pass}  |  SS密码: ${use_ss_pass}"
    echo -e "端口: ${PORT}  |  伪装域名: ${SHADOWTLS_SNI}"
    echo ""
    read -p "按回车继续..." _
}

# HTTPS
setup_https() {
    echo ""; read_port_with_check 443
    read -p "伪装域名 [${DEFAULT_SNI}]: " HTTPS_SNI; HTTPS_SNI=${HTTPS_SNI:-${DEFAULT_SNI}}
    local default_uuid=$(gen_random_uuid)
    read -p "UUID [${default_uuid}]: " use_uuid; use_uuid=${use_uuid:-$default_uuid}
    gen_cert_for_sni "${HTTPS_SNI}" || return 1
    local inbound="{\"type\":\"vless\",\"tag\":\"vless-tls-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT},\"users\":[{\"uuid\":\"${use_uuid}\"}],\"tls\":{\"enabled\":true,\"server_name\":\"${HTTPS_SNI}\",\"certificate_path\":\"${CERT_DIR}/${HTTPS_SNI}/cert.pem\",\"key_path\":\"${CERT_DIR}/${HTTPS_SNI}/private.key\"}}"
    [[ -z "$INBOUNDS_JSON" ]] && INBOUNDS_JSON="$inbound" || INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    LINK="vless://${use_uuid}@${SERVER_IP}:${PORT}?encryption=none&security=tls&sni=${HTTPS_SNI}&type=tcp&allowInsecure=1#HTTPS-${SERVER_IP}"
    local line="[HTTPS] ${SERVER_IP}:${PORT} (SNI: ${HTTPS_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT+="$line"; HTTPS_LINKS+="$line"
    INBOUND_TAGS+=("vless-tls-in-${PORT}"); INBOUND_PORTS+=("${PORT}"); INBOUND_PROTOS+=("HTTPS"); INBOUND_SNIS+=("${HTTPS_SNI}"); INBOUND_RELAY_TAGS+=("direct")
    print_success "HTTPS 添加完成"; save_links_to_files
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ 节点链接（可直接复制）:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "UUID: ${use_uuid}  |  端口: ${PORT}"
    echo -e "伪装域名: ${HTTPS_SNI}"
    echo ""
    read -p "按回车继续..." _
}

# AnyTLS
setup_anytls() {
    echo ""; read_port_with_check 443
    read -p "伪装域名 [${DEFAULT_SNI}]: " ANYTLS_SNI; ANYTLS_SNI=${ANYTLS_SNI:-${DEFAULT_SNI}}
    local default_pass=$(gen_random_hex16)
    read -p "密码 [${default_pass}]: " use_pass; use_pass=${use_pass:-$default_pass}
    gen_cert_for_sni "${ANYTLS_SNI}" || return 1
    local inbound="{\"type\":\"anytls\",\"tag\":\"anytls-in-${PORT}\",\"listen\":\"::\",\"listen_port\":${PORT},\"users\":[{\"password\":\"${use_pass}\"}],\"padding_scheme\":[],\"tls\":{\"enabled\":true,\"server_name\":\"${ANYTLS_SNI}\",\"certificate_path\":\"${CERT_DIR}/${ANYTLS_SNI}/cert.pem\",\"key_path\":\"${CERT_DIR}/${ANYTLS_SNI}/private.key\"}}"
    [[ -z "$INBOUNDS_JSON" ]] && INBOUNDS_JSON="$inbound" || INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    LINK="anytls://${use_pass}@${SERVER_IP}:${PORT}?security=tls&fp=chrome&insecure=1&sni=${ANYTLS_SNI}&type=tcp#AnyTLS-${SERVER_IP}"
    local line="[AnyTLS] ${SERVER_IP}:${PORT} (SNI: ${ANYTLS_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT+="$line"; ANYTLS_LINKS+="$line"
    INBOUND_TAGS+=("anytls-in-${PORT}"); INBOUND_PORTS+=("${PORT}"); INBOUND_PROTOS+=("AnyTLS"); INBOUND_SNIS+=("${ANYTLS_SNI}"); INBOUND_RELAY_TAGS+=("direct")
    print_success "AnyTLS 添加完成"; save_links_to_files
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ 节点链接（可直接复制）:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "密码: ${use_pass}  |  端口: ${PORT}"
    echo -e "伪装域名: ${ANYTLS_SNI}"
    echo ""
    read -p "按回车继续..." _
}

# 其他辅助函数
cleanup_links() {
    rm -rf "${LINK_DIR}" 2>/dev/null || true
    ALL_LINKS_TEXT=""; REALITY_LINKS=""; HYSTERIA2_LINKS=""; SOCKS5_LINKS=""; SHADOWTLS_LINKS=""; HTTPS_LINKS=""; ANYTLS_LINKS=""
}

regenerate_all_links() {
    echo ""
    echo -e "${YELLOW}此操作将从配置文件重新生成所有节点链接${NC}"
    echo ""
    [[ ! -f "${CONFIG_FILE}" ]] && { print_error "配置文件不存在"; return 1; }
    cleanup_links
    if regenerate_links_from_config; then
        print_success "链接文件已重新生成，可在 [配置/查看节点] 中查看"
    else
        print_error "重新生成链接失败"
        return 1
    fi
}
# ==================== 配置生成 ====================
generate_config() {
    print_info "生成最终配置文件..."
    [[ -z "$INBOUNDS_JSON" ]] && { print_error "未找到任何入站节点，请先添加节点"; return 1; }
    load_relays_from_file

    local outbounds_array=()
    for relay_json in "${RELAY_JSONS[@]}"; do outbounds_array+=("$relay_json"); done
    outbounds_array+=('{"type": "direct", "tag": "direct"}')
    local outbounds="["
    for i in "${!outbounds_array[@]}"; do
        [[ $i -gt 0 ]] && outbounds+=", "
        outbounds+="${outbounds_array[$i]}"
    done
    outbounds+="]"

    local route_rules=()
    for i in "${!INBOUND_TAGS[@]}"; do
        local rt="${INBOUND_RELAY_TAGS[$i]}"
        [[ "$rt" != "direct" ]] && route_rules+=("{\"inbound\":[\"${INBOUND_TAGS[$i]}\"],\"outbound\":\"${rt}\"}")
    done

    local route_json
    if [[ ${#route_rules[@]} -gt 0 ]]; then
        route_json="{\"rules\":["
        for i in "${!route_rules[@]}"; do
            [[ $i -gt 0 ]] && route_json+=","
            route_json+="${route_rules[$i]}"
        done
        route_json+="],\"final\":\"direct\",\"default_domain_resolver\":\"local\"}"
    else
        route_json="{\"final\":\"direct\",\"default_domain_resolver\":\"local\"}"
    fi

    # DNS 配置（使用 sing-box 新格式）
    local dns_json
    dns_json='{
    "servers": [
      {"tag": "local", "type": "local"},
      {"tag": "remote", "type": "udp", "server": "8.8.8.8"}
    ],
    "final": "remote"'
    [[ "$OUTBOUND_IP_MODE" == "ipv6" ]] && dns_json+=',"strategy": "prefer_ipv6"'
    [[ "$OUTBOUND_IP_MODE" == "ipv4" ]] && dns_json+=',"strategy": "prefer_ipv4"'
    dns_json+='}'

    cat > ${CONFIG_FILE} << EOFCONFIG
{
  "log": {"level": "info", "timestamp": true},
  "dns": ${dns_json},
  "inbounds": [${INBOUNDS_JSON}],
  "outbounds": ${outbounds},
  "route": ${route_json}
}
EOFCONFIG
    print_success "配置文件生成完成"
}

start_svc() {
    print_info "验证配置文件..."
    ${INSTALL_DIR}/sing-box check -c ${CONFIG_FILE} >/dev/null 2>&1 || { print_error "配置验证失败"; cat ${CONFIG_FILE}; return 1; }
    if command -v systemctl &>/dev/null; then
        systemctl restart sing-box; sleep 2
        systemctl is-active --quiet sing-box && print_success "服务启动成功" || { print_error "启动失败"; journalctl -u sing-box -n 10 --no-pager; return 1; }
    elif command -v rc-service &>/dev/null; then
        rc-service sing-box restart; sleep 2
        rc-service sing-box status &>/dev/null && print_success "服务启动成功" || print_error "启动失败"
    fi
}

# ==================== 保活（cron） ====================
setup_keepalive() {
    local keepalive_cmd="*/5 * * * * root pgrep sing-box >/dev/null || (systemctl restart sing-box 2>/dev/null || rc-service sing-box restart)"
    if [[ -f /etc/cron.d/sing-box-keepalive ]]; then
        print_info "保活任务已存在"
    else
        echo "$keepalive_cmd" > /etc/cron.d/sing-box-keepalive
        print_success "已添加保活任务（每5分钟检查）"
    fi
    case $1 in
        enable) : ;;
        disable) rm -f /etc/cron.d/sing-box-keepalive; print_success "已关闭保活" ;;
    esac
}

# ==================== 主菜单 & 子菜单 ====================
show_main_menu() {
    show_banner
    echo -e "${CYAN}╔═══════════════════════════════╗"
    echo -e "║      Sing-Box 管理面板        ║"
    echo -e "╚═══════════════════════════════╝${NC}"
    echo -e "当前IP: ${GREEN}${SERVER_IP}${NC}  入站:${INBOUND_IP_MODE} 出站:${OUTBOUND_IP_MODE}"
    echo -e "节点数: ${#INBOUND_TAGS[@]}"
    echo -e "  ${GREEN}[1]${NC} 添加节点"
    echo -e "  ${GREEN}[2]${NC} 中转配置"
    echo -e "  ${GREEN}[3]${NC} IP 配置"
    echo -e "  ${GREEN}[4]${NC} 配置/查看节点"
    echo -e "  ${GREEN}[5]${NC} 重新生成链接"
    echo -e "  ${GREEN}[6]${NC} 开启/关闭保活"
    echo -e "  ${GREEN}[7]${NC} 安装/更新 sing-box"
    echo -e "  ${GREEN}[8]${NC} 卸载"
    echo -e "  ${GREEN}[0]${NC} 退出"
}

main_menu() {
    while true; do
        [[ -f "${CONFIG_FILE}" ]] && load_inbounds_from_config
        load_relays_from_file
        load_ip_config
        show_main_menu
        read -p "请选择 [0-8]: " m_choice
        case $m_choice in
            1) show_menu ;;
            2) setup_relay ;;
            3) ip_config_menu ;;
            4) config_and_view_menu ;;
            5) regenerate_all_links ;;
            6) setup_keepalive enable ;;
            7) install_or_update_singbox ;;
            8) delete_self ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        [[ "$m_choice" != "0" ]] && read -p "按回车返回主菜单..." _
    done
}

# ==================== 主函数 ====================
main() {
    [[ $EUID -ne 0 ]] && { print_error "需要 root 权限"; exit 1; }
    detect_system
    ensure_deps                              # 仅安装依赖，不自动装 sing-box
    mkdir -p /etc/sing-box
    if ! command -v sing-box &>/dev/null; then
        print_warning "sing-box 未安装，请从主菜单选择 [7] 先安装"
    else
        gen_keys
    fi
    load_ip_config
    [[ -z "${SERVER_IP}" ]] && get_ip
    setup_sb_shortcut
    setup_keepalive enable
    [[ -f "${CONFIG_FILE}" ]] && load_inbounds_from_config
    load_relays_from_file
    load_links_from_files
    [[ -f "${CONFIG_FILE}" && -z "$ALL_LINKS_TEXT" ]] && regenerate_links_from_config
    main_menu
}

main
