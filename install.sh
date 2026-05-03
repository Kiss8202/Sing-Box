
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

# 链接文件路径
ALL_LINKS_FILE="${LINK_DIR}/all.txt"
REALITY_LINKS_FILE="${LINK_DIR}/reality.txt"
HYSTERIA2_LINKS_FILE="${LINK_DIR}/hysteria2.txt"
SOCKS5_LINKS_FILE="${LINK_DIR}/socks5.txt"
SHADOWTLS_LINKS_FILE="${LINK_DIR}/shadowtls.txt"
HTTPS_LINKS_FILE="${LINK_DIR}/https.txt"
ANYTLS_LINKS_FILE="${LINK_DIR}/anytls.txt"

# 脚本路径
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

# ==================== 全局变量 ====================
INBOUNDS_JSON=""
ALL_LINKS_TEXT=""
SERVER_IP=""
REALITY_LINKS=""
HYSTERIA2_LINKS=""
SOCKS5_LINKS=""
SHADOWTLS_LINKS=""
HTTPS_LINKS=""
ANYTLS_LINKS=""

# IP 配置
SERVER_IPV6=""
INBOUND_IP_MODE="ipv4"   # ipv4 或 ipv6，控制入站监听地址
OUTBOUND_IP_MODE="dual"  # ipv4, ipv6 或 dual，控制出站连接（默认双栈）
IP_CONFIG_FILE="/etc/sing-box/ip_config.conf"

# 中转配置数组
RELAY_TAGS=()        # 中转标签数组
RELAY_JSONS=()       # 中转JSON配置数组
RELAY_DESCS=()       # 中转描述数组
RELAY_FILE="/etc/sing-box/relays.conf"

# 节点数组
INBOUND_TAGS=()
INBOUND_PORTS=()
INBOUND_PROTOS=()
INBOUND_RELAY_TAGS=()  # 存储每个节点使用的中转标签，"direct" 表示直连
INBOUND_SNIS=()

# 密钥变量
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

# 默认SNI
DEFAULT_SNI="time.is"

# ==================== 打印函数 ====================
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

show_banner() {
    clear
    echo ""
}

# ==================== 系统检测 ====================
detect_system() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS="${NAME}"
    else
        print_error "无法检测系统"
        exit 1
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            print_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    print_success "系统: ${OS} (${ARCH})"
}

# ==================== 安装 sing-box ====================
install_singbox() {
    print_info "检查依赖和 sing-box..."
    
    if ! command -v jq &>/dev/null || ! command -v openssl &>/dev/null; then
        print_info "安装依赖包..."
        apt-get update -qq && apt-get install -y curl wget jq openssl uuid-runtime >/dev/null 2>&1 || true
    fi
    
    # 获取最新版本号
    LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
    [[ -z "$LATEST" ]] && LATEST="1.12.0"
    
    if command -v sing-box &>/dev/null; then
        CURRENT=$(sing-box version 2>&1 | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
        print_info "当前版本: ${CURRENT}，最新版本: ${LATEST}"
        
        if [[ "$CURRENT" == "$LATEST" ]]; then
            print_success "已是最新版本，无需更新"
            return 0
        fi
        
        echo ""
        echo -e "${YELLOW}发现新版本！${NC}"
        echo -e "  当前: ${GREEN}${CURRENT}${NC}"
        echo -e "  最新: ${GREEN}${LATEST}${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC} 更新到最新版本"
        echo -e "  ${GREEN}[2]${NC} 不更新，继续使用当前版本"
        echo -e "  ${GREEN}[0]${NC} 退出脚本"
        echo ""
        read -p "请选择 [0-2]: " ver_choice
        case $ver_choice in
            1) ;; # 继续执行下载安装
            2) print_info "跳过更新" ; return 0 ;;
            0) print_info "用户退出" ; exit 0 ;;
            *) print_error "无效选项，跳过更新" ; return 0 ;;
        esac
    else
        print_info "sing-box 未安装，准备下载安装..."
    fi
    
    print_info "下载 sing-box v${LATEST}..."
    if ! wget -q --show-progress -O /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz" 2>&1; then
        print_error "下载失败，请检查网络或版本号"
        return 1
    fi
    
    if ! tar -xzf /tmp/sb.tar.gz -C /tmp; then
        print_error "解压失败"
        rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
        return 1
    fi
    
    install -Dm755 /tmp/sing-box-${LATEST}-linux-${ARCH}/sing-box ${INSTALL_DIR}/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
    
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
    print_success "sing-box ${LATEST} 安装/更新完成"
}

# ==================== 证书生成 ====================
gen_cert_for_sni() {
    local sni="$1"
    local node_cert_dir="${CERT_DIR}/${sni}"
    
    mkdir -p "${node_cert_dir}"
    
    if ! openssl genrsa -out "${node_cert_dir}/private.key" 2048 2>/dev/null; then
        print_error "生成私钥失败"
        return 1
    fi
    if ! openssl req -new -x509 -days 36500 -key "${node_cert_dir}/private.key" -out "${node_cert_dir}/cert.pem" -subj "/C=US/ST=California/L=Cupertino/O=Apple Inc./CN=${sni}" 2>/dev/null; then
        print_error "生成证书失败"
        return 1
    fi
    
    print_success "证书生成完成 (${sni}, 有效期100年)"
    return 0
}

# ==================== 密钥管理 ====================
gen_keys() {
    print_info "生成密钥和 UUID..."
    
    if [[ -f "${KEY_FILE}" ]]; then
        print_info "从文件加载已保存的密钥..."
        source "${KEY_FILE}"
        print_success "密钥加载完成"
        return 0
    fi
    
    KEYS=$(${INSTALL_DIR}/sing-box generate reality-keypair 2>/dev/null)
    REALITY_PRIVATE=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    SHORT_ID=$(openssl rand -hex 8)
    HY2_PASSWORD=$(openssl rand -hex 16)
    SS_PASSWORD=$(openssl rand -base64 16)  # SS 2022 需要 base64 格式
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
    print_success "密钥已保存到 ${KEY_FILE}"
}

# ==================== 自定义密钥交互 ====================
# 允许用户在添加节点时自定义认证信息
customize_auth() {
    local proto="$1"
    echo ""
    echo -e "${YELLOW}当前全局 ${proto} 认证信息:${NC}"
    case $proto in
        Reality|HTTPS)
            echo -e "  UUID: ${UUID}"
            ;;
        Hysteria2)
            echo -e "  密码: ${HY2_PASSWORD}"
            ;;
        ShadowTLS)
            echo -e "  ShadowTLS 密码: ${SHADOWTLS_PASSWORD}"
            echo -e "  Shadowsocks 密码: ${SS_PASSWORD}"
            ;;
        AnyTLS)
            echo -e "  密码: ${ANYTLS_PASSWORD}"
            ;;
        SOCKS5)
            echo -e "  用户名: ${SOCKS_USER}"
            echo -e "  密码: ${SOCKS_PASS}"
            ;;
    esac
    read -p "是否自定义此节点的认证信息? (y/N): " custom
    if [[ ! "$custom" =~ ^[Yy]$ ]]; then
        return 1
    fi
    return 0
}

# ==================== 链接文件管理 ====================
save_links_to_files() {
    mkdir -p "${LINK_DIR}"
    
    echo -en "${ALL_LINKS_TEXT}" > "${ALL_LINKS_FILE}"
    echo -en "${REALITY_LINKS}" > "${REALITY_LINKS_FILE}"
    echo -en "${HYSTERIA2_LINKS}" > "${HYSTERIA2_LINKS_FILE}"
    echo -en "${SOCKS5_LINKS}" > "${SOCKS5_LINKS_FILE}"
    echo -en "${SHADOWTLS_LINKS}" > "${SHADOWTLS_LINKS_FILE}"
    echo -en "${HTTPS_LINKS}" > "${HTTPS_LINKS_FILE}"
    echo -en "${ANYTLS_LINKS}" > "${ANYTLS_LINKS_FILE}"
    
    chmod 700 "${LINK_DIR}" 2>/dev/null || true
    print_success "链接已保存到 ${LINK_DIR}"
}

load_links_from_files() {
    mkdir -p "${LINK_DIR}"
    
    [[ -f "${ALL_LINKS_FILE}" ]] && ALL_LINKS_TEXT=$(cat "${ALL_LINKS_FILE}")
    [[ -f "${REALITY_LINKS_FILE}" ]] && REALITY_LINKS=$(cat "${REALITY_LINKS_FILE}")
    [[ -f "${HYSTERIA2_LINKS_FILE}" ]] && HYSTERIA2_LINKS=$(cat "${HYSTERIA2_LINKS_FILE}")
    [[ -f "${SOCKS5_LINKS_FILE}" ]] && SOCKS5_LINKS=$(cat "${SOCKS5_LINKS_FILE}")
    [[ -f "${SHADOWTLS_LINKS_FILE}" ]] && SHADOWTLS_LINKS=$(cat "${SHADOWTLS_LINKS_FILE}")
    [[ -f "${HTTPS_LINKS_FILE}" ]] && HTTPS_LINKS=$(cat "${HTTPS_LINKS_FILE}")
    [[ -f "${ANYTLS_LINKS_FILE}" ]] && ANYTLS_LINKS=$(cat "${ANYTLS_LINKS_FILE}")
}

# 从配置文件加载节点信息
load_inbounds_from_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return 1
    fi
    
    if ! command -v jq &>/dev/null; then
        return 1
    fi
    
    # 清空数组
    INBOUND_TAGS=()
    INBOUND_PORTS=()
    INBOUND_PROTOS=()
    INBOUND_SNIS=()
    INBOUND_RELAY_TAGS=()
    INBOUNDS_JSON=""
    
    local inbounds_count=$(jq '.inbounds | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
    
    if [[ "$inbounds_count" -eq 0 ]]; then
        return 1
    fi
    
    local inbound_list=""
    
    for ((i=0; i<inbounds_count; i++)); do
        local inbound=$(jq -c ".inbounds[${i}]" "${CONFIG_FILE}" 2>/dev/null)
        
        if [[ -z "$inbound" ]]; then
            continue
        fi
        
        # 添加到 INBOUNDS_JSON（包含所有入站，保证 ShadowTLS 内部组件不丢失）
        if [[ -z "$inbound_list" ]]; then
            inbound_list="$inbound"
        else
            inbound_list="${inbound_list},${inbound}"
        fi
        
        # 提取信息用于节点数组显示
        local tag=$(echo "$inbound" | jq -r '.tag' 2>/dev/null || echo "unknown")
        local port=$(echo "$inbound" | jq -r '.listen_port' 2>/dev/null || echo "0")
        local type=$(echo "$inbound" | jq -r '.type' 2>/dev/null || echo "unknown")
        
        # 跳过 shadowsocks-in-* (内部组件，不单独显示为节点)
        if [[ "$tag" == "shadowsocks-in-"* ]]; then
            continue
        fi
        
        # 判断协议类型
        local proto="unknown"
        local sni=""
        
        if [[ "$tag" == *"vless-in-"* ]]; then
            proto="Reality"
            sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        elif [[ "$tag" == *"hy2-in-"* ]]; then
            proto="Hysteria2"
            sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        elif [[ "$tag" == *"shadowtls-in-"* ]]; then
            proto="ShadowTLS v3"
            sni=$(echo "$inbound" | jq -r '.handshake.server // ""' 2>/dev/null)
        elif [[ "$tag" == *"socks-in"* ]]; then
            proto="SOCKS5"
        elif [[ "$tag" == *"vless-tls-in-"* ]]; then
            proto="HTTPS"
            sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        elif [[ "$tag" == *"anytls-in-"* ]]; then
            proto="AnyTLS"
            sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
        fi
        
        [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
        
        INBOUND_TAGS+=("$tag")
        INBOUND_PORTS+=("$port")
        INBOUND_PROTOS+=("$proto")
        INBOUND_SNIS+=("$sni")
        INBOUND_RELAY_TAGS+=("direct")  # 默认直连，稍后从路由规则更新
    done
    
    INBOUNDS_JSON="$inbound_list"
    
    # 从路由规则中恢复中转配置
    local route_rules=$(jq -c '.route.rules[]? // empty' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "$route_rules" ]]; then
        while IFS= read -r rule; do
            local inbound_array=$(echo "$rule" | jq -r '.inbound[]? // empty' 2>/dev/null)
            local outbound=$(echo "$rule" | jq -r '.outbound // ""' 2>/dev/null)
            
            if [[ -n "$outbound" && "$outbound" != "direct" ]]; then
                # 为匹配的 inbound 设置中转标签
                while IFS= read -r inbound_tag; do
                    for i in "${!INBOUND_TAGS[@]}"; do
                        if [[ "${INBOUND_TAGS[$i]}" == "$inbound_tag" ]]; then
                            INBOUND_RELAY_TAGS[$i]="$outbound"
                            break
                        fi
                    done
                done <<< "$inbound_array"
            fi
        done <<< "$route_rules"
    fi
    
    return 0
}

# 从配置文件重新生成链接（用于修复缺失链接或更新IP后）
regenerate_links_from_config() {
    print_info "正在从配置文件重新生成链接..."
    
    # 清空所有链接变量
    ALL_LINKS_TEXT=""
    REALITY_LINKS=""
    HYSTERIA2_LINKS=""
    SOCKS5_LINKS=""
    SHADOWTLS_LINKS=""
    HTTPS_LINKS=""
    ANYTLS_LINKS=""
    
    # 加载密钥文件
    if [[ -f "${KEY_FILE}" ]]; then
        source "${KEY_FILE}"
    fi
    
    # 确保 SERVER_IP 已设置
    if [[ -z "${SERVER_IP}" ]]; then
        get_ip
    fi
    
    if [[ ! -f "${CONFIG_FILE}" ]] || ! command -v jq &>/dev/null; then
        print_warning "无法重新生成链接：配置文件不存在或 jq 未安装"
        return 1
    fi
    
    local inbounds_count=$(jq '.inbounds | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
    
    if [[ "$inbounds_count" -eq 0 ]]; then
        print_warning "配置文件中没有找到节点"
        return 1
    fi
    
    # 遍历每个inbound生成链接
    for ((i=0; i<inbounds_count; i++)); do
        local inbound=$(jq -c ".inbounds[${i}]" "${CONFIG_FILE}" 2>/dev/null)
        
        if [[ -z "$inbound" ]]; then
            continue
        fi
        
        local type=$(echo "$inbound" | jq -r '.type' 2>/dev/null)
        local port=$(echo "$inbound" | jq -r '.listen_port' 2>/dev/null)
        local tag=$(echo "$inbound" | jq -r '.tag' 2>/dev/null)
        
        if [[ -z "$type" || -z "$port" ]]; then
            continue
        fi
        
        # 根据类型生成链接
        case "$type" in
            "vless")
                local tls_enabled=$(echo "$inbound" | jq -r '.tls.enabled // false' 2>/dev/null)
                if [[ "$tls_enabled" == "true" ]]; then
                    local reality_enabled=$(echo "$inbound" | jq -r '.tls.reality.enabled // false' 2>/dev/null)
                    if [[ "$reality_enabled" == "true" ]]; then
                        # Reality
                        local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // ""' 2>/dev/null)
                        local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
                        local pbk=$(echo "$inbound" | jq -r '.tls.reality.public_key // ""' 2>/dev/null)
                        local sid=$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // ""' 2>/dev/null)
                        
                        [[ -z "$uuid" && -n "${UUID}" ]] && uuid="${UUID}"
                        [[ -z "$pbk" && -n "${REALITY_PUBLIC}" ]] && pbk="${REALITY_PUBLIC}"
                        [[ -z "$sid" && -n "${SHORT_ID}" ]] && sid="${SHORT_ID}"
                        [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                        
                        if [[ -n "$uuid" && -n "$pbk" ]]; then
                            local link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#Reality-${SERVER_IP}"
                            local line="[Reality] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                            ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
                            REALITY_LINKS="${REALITY_LINKS}${line}"
                        fi
                    else
                        # HTTPS
                        local uuid=$(echo "$inbound" | jq -r '.users[0].uuid // ""' 2>/dev/null)
                        local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
                        
                        [[ -z "$uuid" && -n "${UUID}" ]] && uuid="${UUID}"
                        [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                        
                        if [[ -n "$uuid" ]]; then
                            local link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&security=tls&sni=${sni}&type=tcp&allowInsecure=1#HTTPS-${SERVER_IP}"
                            local line="[HTTPS] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                            ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
                            HTTPS_LINKS="${HTTPS_LINKS}${line}"
                        fi
                    fi
                fi
                ;;
            "hysteria2")
                local password=$(echo "$inbound" | jq -r '.users[0].password // ""' 2>/dev/null)
                local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
                
                [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                
                if [[ -n "$password" ]]; then
                    local link="hysteria2://${password}@${SERVER_IP}:${port}?insecure=1&sni=${sni}#Hysteria2-${SERVER_IP}"
                    local line="[Hysteria2] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
                    HYSTERIA2_LINKS="${HYSTERIA2_LINKS}${line}"
                fi
                ;;
            "socks")
                local username=$(echo "$inbound" | jq -r '.users[0].username // ""' 2>/dev/null)
                local password=$(echo "$inbound" | jq -r '.users[0].password // ""' 2>/dev/null)
                local link=""
                
                if [[ -n "$username" && -n "$password" ]]; then
                    link="socks5://${username}:${password}@${SERVER_IP}:${port}#SOCKS5-${SERVER_IP}"
                else
                    link="socks5://${SERVER_IP}:${port}#SOCKS5-${SERVER_IP}"
                fi
                
                if [[ -n "$link" ]]; then
                    local line="[SOCKS5] ${SERVER_IP}:${port}\n${link}\n----------------------------------------\n\n"
                    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
                    SOCKS5_LINKS="${SOCKS5_LINKS}${line}"
                fi
                ;;
            "shadowtls")
                local shadowtls_password=$(echo "$inbound" | jq -r '.users[0].password // ""' 2>/dev/null)
                local sni=$(echo "$inbound" | jq -r '.handshake.server // ""' 2>/dev/null)
                
                [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                
                if [[ -n "$shadowtls_password" ]]; then
                    # 查找对应的 shadowsocks-in inbound
                    local ss_inbound=$(jq -c ".inbounds[] | select(.tag == \"shadowsocks-in-${port}\")" "${CONFIG_FILE}" 2>/dev/null)
                    local ss_password=$(echo "$ss_inbound" | jq -r '.password // ""' 2>/dev/null)
                    local ss_method=$(echo "$ss_inbound" | jq -r '.method // "2022-blake3-aes-128-gcm"' 2>/dev/null)
                    
                    if [[ -n "$ss_password" ]]; then
                        local ss_userinfo=$(echo -n "${ss_method}:${ss_password}" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
                        local plugin_json="{\"version\":\"3\",\"password\":\"${shadowtls_password}\",\"host\":\"${sni}\",\"port\":\"${port}\",\"address\":\"${SERVER_IP}\"}"
                        local plugin_base64=$(echo -n "$plugin_json" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
                        local link="ss://${ss_userinfo}@${SERVER_IP}:${port}?shadow-tls=${plugin_base64}#ShadowTLS-${SERVER_IP}"
                        
                        # 生成客户端配置文件
                        local client_config_file="${LINK_DIR}/shadowtls_client_${port}.json"
                        cat > "${client_config_file}" << EOFCLIENT
{
  "log": {"level": "info"},
  "dns": {"servers": [{"tag": "google", "address": "8.8.8.8"}]},
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1080,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": ["ShadowTLS-${port}"],
      "default": "ShadowTLS-${port}"
    },
    {
      "type": "shadowsocks",
      "tag": "ShadowTLS-${port}",
      "method": "${ss_method}",
      "password": "${ss_password}",
      "detour": "shadowtls-out-${port}"
    },
    {
      "type": "shadowtls",
      "tag": "shadowtls-out-${port}",
      "server": "${SERVER_IP}",
      "server_port": ${port},
      "version": 3,
      "password": "${shadowtls_password}",
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "utls": {"enabled": true, "fingerprint": "chrome"}
      }
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "rules": [
      {"geosite": "cn", "outbound": "direct"},
      {"geoip": "cn", "outbound": "direct"}
    ],
    "final": "proxy"
  }
}
EOFCLIENT
                        
                        local line="[ShadowTLS v3] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n客户端配置: ${client_config_file}\n----------------------------------------\n\n"
                        ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
                        SHADOWTLS_LINKS="${SHADOWTLS_LINKS}${line}"
                    fi
                fi
                ;;
            "anytls")
                local password=$(echo "$inbound" | jq -r '.users[0].password // ""' 2>/dev/null)
                local sni=$(echo "$inbound" | jq -r '.tls.server_name // ""' 2>/dev/null)
                
                [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                
                if [[ -n "$password" ]]; then
                    local link="anytls://${password}@${SERVER_IP}:${port}?security=tls&fp=chrome&insecure=1&sni=${sni}&type=tcp#AnyTLS-${SERVER_IP}"
                    local line="[AnyTLS] ${SERVER_IP}:${port} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
                    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
                    ANYTLS_LINKS="${ANYTLS_LINKS}${line}"
                fi
                ;;
        esac
    done
    
    print_success "链接重新生成完成"
    save_links_to_files
}

# ==================== IP 配置管理 ====================
save_ip_config() {
    mkdir -p "$(dirname "${IP_CONFIG_FILE}")"
    cat > "${IP_CONFIG_FILE}" << EOF
# Sing-box IP 配置
SERVER_IP="${SERVER_IP}"
SERVER_IPV6="${SERVER_IPV6}"
INBOUND_IP_MODE="${INBOUND_IP_MODE}"
OUTBOUND_IP_MODE="${OUTBOUND_IP_MODE}"
EOF
}

load_ip_config() {
    if [[ -f "${IP_CONFIG_FILE}" ]]; then
        source "${IP_CONFIG_FILE}"
    fi
}

# ==================== 中转配置管理 ====================
save_relays_to_file() {
    mkdir -p "$(dirname "${RELAY_FILE}")"
    
    cat > "${RELAY_FILE}" << EOF
# Sing-box 中转配置文件
# 格式: TAG|DESCRIPTION|JSON_CONFIG
EOF
    
    for i in "${!RELAY_TAGS[@]}"; do
        local tag="${RELAY_TAGS[$i]}"
        local desc="${RELAY_DESCS[$i]}"
        local json="${RELAY_JSONS[$i]}"
        local json_base64=$(echo "$json" | base64 -w0)
        echo "${tag}|${desc}|${json_base64}" >> "${RELAY_FILE}"
    done
}

load_relays_from_file() {
    RELAY_TAGS=()
    RELAY_JSONS=()
    RELAY_DESCS=()
    
    if [[ ! -f "${RELAY_FILE}" ]]; then
        return 0
    fi
    
    while IFS='|' read -r tag desc json_base64; do
        [[ "$tag" =~ ^#.*$ || -z "$tag" ]] && continue
        
        local json=$(echo "$json_base64" | base64 -d 2>/dev/null)
        if [[ -n "$json" ]]; then
            RELAY_TAGS+=("$tag")
            RELAY_DESCS+=("$desc")
            RELAY_JSONS+=("$json")
        fi
    done < "${RELAY_FILE}"
}

cleanup_links() {
    rm -rf "${LINK_DIR}" 2>/dev/null || true
    ALL_LINKS_TEXT=""
    REALITY_LINKS=""
    HYSTERIA2_LINKS=""
    SOCKS5_LINKS=""
    SHADOWTLS_LINKS=""
    HTTPS_LINKS=""
    ANYTLS_LINKS=""
}

regenerate_all_links() {
    echo ""
    echo -e "${YELLOW}此操作将从配置文件重新生成所有节点链接${NC}"
    echo ""
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        print_error "配置文件不存在，无法重新生成链接"
        return 1
    fi
    
    print_info "清理旧链接文件..."
    cleanup_links
    
    print_info "从配置文件重新生成链接..."
    if regenerate_links_from_config; then
        print_success "链接文件已重新生成"
        print_info "可以在 [配置/查看节点] 菜单中查看"
    else
        print_error "重新生成链接失败"
        return 1
    fi
}

# ==================== 网络工具 ====================
get_ip() {
    print_info "获取服务器 IP 地址..."
    
    local ipv4=$(curl -s4m5 ifconfig.me 2>/dev/null || curl -s4m5 api.ipify.org 2>/dev/null || curl -s4m5 ip.sb 2>/dev/null)
    local ipv6=$(curl -s6m5 ifconfig.me 2>/dev/null || curl -s6m5 api6.ipify.org 2>/dev/null || curl -s6m5 ip.sb 2>/dev/null)
    
    echo ""
    if [[ -n "$ipv4" ]]; then
        echo -e "  ${GREEN}检测到 IPv4:${NC} ${ipv4}"
    fi
    if [[ -n "$ipv6" ]]; then
        echo -e "  ${GREEN}检测到 IPv6:${NC} ${ipv6}"
    fi
    echo ""
    
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        print_error "无法获取服务器 IP 地址"
        exit 1
    fi
    
    if [[ -n "$ipv4" ]]; then
        SERVER_IP="$ipv4"
        SERVER_IPV6="$ipv6"
        if [[ -n "$ipv6" ]]; then
            print_success "检测到双栈网络，默认使用 IPv4: ${SERVER_IP}"
            echo -e "${CYAN}提示: 可在主菜单 [出入站配置] 中切换 IPv6${NC}"
        else
            print_success "使用 IPv4: ${SERVER_IP}"
        fi
    elif [[ -n "$ipv6" ]]; then
        SERVER_IP="$ipv6"
        SERVER_IPV6=""
        INBOUND_IP_MODE="ipv6"
        OUTBOUND_IP_MODE="dual"
        print_success "使用 IPv6: ${SERVER_IP}"
        print_info "已自动设置入站为 IPv6，出站为双栈模式"
    fi
    
    save_ip_config
}

check_port_in_use() {
    local port="$1"
    ss -tuln | grep -q ":${port} " && return 0 || return 1
}

read_port_with_check() {
    local default_port="$1"
    
    while true; do
        read -p "监听端口 [${default_port}]: " PORT
        PORT=${PORT:-${default_port}}
        
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
            print_error "端口无效，请输入 1-65535 之间的数字"
            continue
        fi
        
        if check_port_in_use "$PORT"; then
            print_warning "端口 ${PORT} 已被占用，请重新输入"
            continue
        fi
        
        break
    done
}

# ==================== 各协议配置（增加交互自定义） ====================
setup_reality() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入伪装域名（建议使用常见HTTPS网站域名）${NC}"
    read -p "伪装域名 [${DEFAULT_SNI}]: " SNI
    SNI=${SNI:-${DEFAULT_SNI}}
    
    # 自定义 UUID
    local use_uuid="${UUID}"
    if customize_auth "Reality"; then
        read -p "请输入自定义 UUID (留空使用全局): " custom_uuid
        [[ -n "$custom_uuid" ]] && use_uuid="$custom_uuid"
    fi
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"vless\",
  \"tag\": \"vless-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"uuid\": \"${use_uuid}\", \"flow\": \"xtls-rprx-vision\"}],
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${SNI}\",
    \"reality\": {
      \"enabled\": true,
      \"handshake\": {\"server\": \"${SNI}\", \"server_port\": 443},
      \"private_key\": \"${REALITY_PRIVATE}\",
      \"short_id\": [\"${SHORT_ID}\"]
    }
  }
}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    LINK="vless://${use_uuid}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#Reality-${SERVER_IP}"
    
    PROTO="Reality"
    EXTRA_INFO="UUID: ${use_uuid}\nPublic Key: ${REALITY_PUBLIC}\nShort ID: ${SHORT_ID}\nSNI: ${SNI}"
    local line="[Reality] ${SERVER_IP}:${PORT} (SNI: ${SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    REALITY_LINKS="${REALITY_LINKS}${line}"
    
    INBOUND_TAGS+=("vless-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "Reality 配置完成 (SNI: ${SNI})"
    save_links_to_files
}

setup_hysteria2() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入伪装域名（建议使用常见HTTPS网站域名）${NC}"
    read -p "伪装域名 [${DEFAULT_SNI}]: " HY2_SNI
    HY2_SNI=${HY2_SNI:-${DEFAULT_SNI}}
    
    # 自定义密码
    local use_pass="${HY2_PASSWORD}"
    if customize_auth "Hysteria2"; then
        read -p "请输入自定义密码 (留空使用全局): " custom_pass
        [[ -n "$custom_pass" ]] && use_pass="$custom_pass"
    fi
    
    print_info "为 ${HY2_SNI} 生成自签证书..."
    if ! gen_cert_for_sni "${HY2_SNI}"; then
        return 1
    fi
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"hysteria2\",
  \"tag\": \"hy2-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"password\": \"${use_pass}\"}],
  \"tls\": {
    \"enabled\": true,
    \"alpn\": [\"h3\"],
    \"server_name\": \"${HY2_SNI}\",
    \"certificate_path\": \"${CERT_DIR}/${HY2_SNI}/cert.pem\",
    \"key_path\": \"${CERT_DIR}/${HY2_SNI}/private.key\"
  }
}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    LINK="hysteria2://${use_pass}@${SERVER_IP}:${PORT}?insecure=1&sni=${HY2_SNI}#Hysteria2-${SERVER_IP}"
    PROTO="Hysteria2"
    EXTRA_INFO="密码: ${use_pass}\n证书: 自签证书(${HY2_SNI})\nSNI: ${HY2_SNI}"
    local line="[Hysteria2] ${SERVER_IP}:${PORT} (SNI: ${HY2_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    HYSTERIA2_LINKS="${HYSTERIA2_LINKS}${line}"
    
    INBOUND_TAGS+=("hy2-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${HY2_SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "Hysteria2 配置完成 (SNI: ${HY2_SNI})"
    save_links_to_files
}

setup_socks5() {
    echo ""
    read_port_with_check 1080
    read -p "是否启用认证? [Y/n]: " ENABLE_AUTH
    ENABLE_AUTH=${ENABLE_AUTH:-Y}
    
    local use_user="${SOCKS_USER}"
    local use_pass="${SOCKS_PASS}"
    
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        if customize_auth "SOCKS5"; then
            read -p "用户名 [${SOCKS_USER}]: " custom_user
            read -p "密码 [${SOCKS_PASS}]: " custom_pass
            use_user="${custom_user:-$SOCKS_USER}"
            use_pass="${custom_pass:-$SOCKS_PASS}"
        fi
    fi
    
    print_info "生成配置文件..."
    
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        local inbound="{
  \"type\": \"socks\",
  \"tag\": \"socks-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"username\": \"${use_user}\", \"password\": \"${use_pass}\"}]
}"
        LINK="socks5://${use_user}:${use_pass}@${SERVER_IP}:${PORT}#SOCKS5-${SERVER_IP}"
        EXTRA_INFO="用户名: ${use_user}\n密码: ${use_pass}"
    else
        local inbound="{
  \"type\": \"socks\",
  \"tag\": \"socks-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT}
}"
        LINK="socks5://${SERVER_IP}:${PORT}#SOCKS5-${SERVER_IP}"
        EXTRA_INFO="无认证"
    fi
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    PROTO="SOCKS5"
    local line="[SOCKS5] ${SERVER_IP}:${PORT}\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    SOCKS5_LINKS="${SOCKS5_LINKS}${line}"
    
    INBOUND_TAGS+=("socks-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "SOCKS5 配置完成"
    save_links_to_files
}

setup_shadowtls() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入伪装域名（建议使用常见HTTPS网站域名）${NC}"
    read -p "伪装域名 [${DEFAULT_SNI}]: " SHADOWTLS_SNI
    SHADOWTLS_SNI=${SHADOWTLS_SNI:-${DEFAULT_SNI}}
    
    local use_stls_pass="${SHADOWTLS_PASSWORD}"
    local use_ss_pass="${SS_PASSWORD}"
    if customize_auth "ShadowTLS"; then
        read -p "ShadowTLS 密码 [${SHADOWTLS_PASSWORD}]: " custom_stls
        read -p "Shadowsocks 密码 [${SS_PASSWORD}]: " custom_ss
        use_stls_pass="${custom_stls:-$SHADOWTLS_PASSWORD}"
        use_ss_pass="${custom_ss:-$SS_PASSWORD}"
    fi
    
    print_info "生成配置文件..."
    print_warning "ShadowTLS 通过伪装真实域名的TLS握手工作"
    
    local inbound="{
  \"type\": \"shadowtls\",
  \"tag\": \"shadowtls-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"version\": 3,
  \"users\": [{\"password\": \"${use_stls_pass}\"}],
  \"handshake\": {
    \"server\": \"${SHADOWTLS_SNI}\",
    \"server_port\": 443
  },
  \"strict_mode\": true,
  \"detour\": \"shadowsocks-in-${PORT}\"
},
{
  \"type\": \"shadowsocks\",
  \"tag\": \"shadowsocks-in-${PORT}\",
  \"listen\": \"127.0.0.1\",
  \"network\": \"tcp\",
  \"method\": \"2022-blake3-aes-128-gcm\",
  \"password\": \"${use_ss_pass}\"
}"
    
    local ss_userinfo=$(echo -n "2022-blake3-aes-128-gcm:${use_ss_pass}" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
    local plugin_json="{\"version\":\"3\",\"password\":\"${use_stls_pass}\",\"host\":\"${SHADOWTLS_SNI}\",\"port\":\"${PORT}\",\"address\":\"${SERVER_IP}\"}"
    local plugin_base64=$(echo -n "$plugin_json" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
    
    LINK="ss://${ss_userinfo}@${SERVER_IP}:${PORT}?shadow-tls=${plugin_base64}#ShadowTLS-${SERVER_IP}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    PROTO="ShadowTLS v3"
    local line="[ShadowTLS v3] ${SERVER_IP}:${PORT} (SNI: ${SHADOWTLS_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    SHADOWTLS_LINKS="${SHADOWTLS_LINKS}${line}"
    
    # 生成客户端配置文件
    local client_config_file="${LINK_DIR}/shadowtls_client_${PORT}.json"
    cat > "${client_config_file}" << EOFCLIENT
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "address": "8.8.8.8"
      }
    ]
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1080,
      "sniff": true,
      "set_system_proxy": false
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": ["ShadowTLS-${PORT}"],
      "default": "ShadowTLS-${PORT}"
    },
    {
      "type": "shadowsocks",
      "tag": "ShadowTLS-${PORT}",
      "method": "2022-blake3-aes-128-gcm",
      "password": "${use_ss_pass}",
      "detour": "shadowtls-out-${PORT}"
    },
    {
      "type": "shadowtls",
      "tag": "shadowtls-out-${PORT}",
      "server": "${SERVER_IP}",
      "server_port": ${PORT},
      "version": 3,
      "password": "${use_stls_pass}",
      "tls": {
        "enabled": true,
        "server_name": "${SHADOWTLS_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "geosite": "cn",
        "outbound": "direct"
      },
      {
        "geoip": "cn",
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
EOFCLIENT
    
    EXTRA_INFO="Shadowsocks方法: 2022-blake3-aes-128-gcm\nShadowsocks密码: ${use_ss_pass}\nShadowTLS密码: ${use_stls_pass}\n伪装域名: ${SHADOWTLS_SNI}\n\n${RED}重要: ShadowTLS 支持链接格式！${NC}\n${YELLOW}也可使用客户端配置文件:${NC}\n  ${client_config_file}\n\n${CYAN}下载命令:${NC}\n  scp root@${SERVER_IP}:${client_config_file} ./\n\n${CYAN}或直接查看:${NC}\n  cat ${client_config_file}"
    
    INBOUND_TAGS+=("shadowtls-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${SHADOWTLS_SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "ShadowTLS v3 配置完成 (SNI: ${SHADOWTLS_SNI})"
    print_info "客户端配置文件已保存: ${client_config_file}"
    save_links_to_files
}

setup_https() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入伪装域名（建议使用常见HTTPS网站域名）${NC}"
    read -p "伪装域名 [${DEFAULT_SNI}]: " HTTPS_SNI
    HTTPS_SNI=${HTTPS_SNI:-${DEFAULT_SNI}}
    
    local use_uuid="${UUID}"
    if customize_auth "HTTPS"; then
        read -p "请输入自定义 UUID (留空使用全局): " custom_uuid
        [[ -n "$custom_uuid" ]] && use_uuid="$custom_uuid"
    fi
    
    print_info "为 ${HTTPS_SNI} 生成自签证书..."
    if ! gen_cert_for_sni "${HTTPS_SNI}"; then
        return 1
    fi
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"vless\",
  \"tag\": \"vless-tls-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"uuid\": \"${use_uuid}\"}],
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${HTTPS_SNI}\",
    \"certificate_path\": \"${CERT_DIR}/${HTTPS_SNI}/cert.pem\",
    \"key_path\": \"${CERT_DIR}/${HTTPS_SNI}/private.key\"
  }
}"
    
    LINK="vless://${use_uuid}@${SERVER_IP}:${PORT}?encryption=none&security=tls&sni=${HTTPS_SNI}&type=tcp&allowInsecure=1#HTTPS-${SERVER_IP}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    PROTO="HTTPS"
    EXTRA_INFO="UUID: ${use_uuid}\n证书: 自签证书(${HTTPS_SNI})\nSNI: ${HTTPS_SNI}"
    local line="[HTTPS] ${SERVER_IP}:${PORT} (SNI: ${HTTPS_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    HTTPS_LINKS="${HTTPS_LINKS}${line}"
    
    INBOUND_TAGS+=("vless-tls-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${HTTPS_SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "HTTPS 配置完成 (SNI: ${HTTPS_SNI})"
    save_links_to_files
}

setup_anytls() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入伪装域名（建议使用常见HTTPS网站域名）${NC}"
    read -p "伪装域名 [${DEFAULT_SNI}]: " ANYTLS_SNI
    ANYTLS_SNI=${ANYTLS_SNI:-${DEFAULT_SNI}}
    
    local use_pass="${ANYTLS_PASSWORD}"
    if customize_auth "AnyTLS"; then
        read -p "请输入自定义密码 (留空使用全局): " custom_pass
        [[ -n "$custom_pass" ]] && use_pass="$custom_pass"
    fi
    
    print_info "为 ${ANYTLS_SNI} 生成自签证书..."
    if ! gen_cert_for_sni "${ANYTLS_SNI}"; then
        return 1
    fi
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"anytls\",
  \"tag\": \"anytls-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"password\": \"${use_pass}\"}],
  \"padding_scheme\": [],
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${ANYTLS_SNI}\",
    \"certificate_path\": \"${CERT_DIR}/${ANYTLS_SNI}/cert.pem\",
    \"key_path\": \"${CERT_DIR}/${ANYTLS_SNI}/private.key\"
  }
}"
    
    LINK="anytls://${use_pass}@${SERVER_IP}:${PORT}?security=tls&fp=chrome&insecure=1&sni=${ANYTLS_SNI}&type=tcp#AnyTLS-${SERVER_IP}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    PROTO="AnyTLS"
    EXTRA_INFO="密码: ${use_pass}\n自签证书: ${ANYTLS_SNI}\nSNI: ${ANYTLS_SNI}"
    local line="[AnyTLS] ${SERVER_IP}:${PORT} (SNI: ${ANYTLS_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    ANYTLS_LINKS="${ANYTLS_LINKS}${line}"
    
    INBOUND_TAGS+=("anytls-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${ANYTLS_SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "AnyTLS 配置完成 (SNI: ${ANYTLS_SNI})"
    save_links_to_files
}

# ==================== 中转配置解析（保持不变） ====================
# ... (parse_socks_link, parse_http_link, parse_ss_link, parse_vmess_link, parse_vless_link, parse_trojan_link 均未改动，不再重复)

# ==================== 配置生成 ====================
generate_config() {
    print_info "生成最终配置文件..."
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        print_error "未找到任何入站节点，请先添加节点"
        return 1
    fi
    
    # 加载中转配置
    load_relays_from_file
    
    # 构建 outbounds 数组
    local outbounds_array=()
    
    for relay_json in "${RELAY_JSONS[@]}"; do
        outbounds_array+=("$relay_json")
    done
    
    local direct_outbound='{"type": "direct", "tag": "direct"}'
    outbounds_array+=("$direct_outbound")
    
    local outbounds="["
    for i in "${!outbounds_array[@]}"; do
        [[ $i -gt 0 ]] && outbounds+=", "
        outbounds+="${outbounds_array[$i]}"
    done
    outbounds+="]"
    
    # 构建路由规则
    local route_rules=()
    
    for i in "${!INBOUND_TAGS[@]}"; do
        local relay_tag="${INBOUND_RELAY_TAGS[$i]}"
        if [[ "$relay_tag" != "direct" ]]; then
            route_rules+=("{\"inbound\":[\"${INBOUND_TAGS[$i]}\"],\"outbound\":\"${relay_tag}\"}")
        fi
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
    
    # DNS 配置
    local dns_json
    if [[ "$OUTBOUND_IP_MODE" == "ipv6" ]]; then
        dns_json='{
    "servers": [
      {
        "tag": "local",
        "type": "local"
      },
      {
        "tag": "remote",
        "type": "udp",
        "server": "8.8.8.8"
      }
    ],
    "final": "remote",
    "strategy": "prefer_ipv6"
  }'
    elif [[ "$OUTBOUND_IP_MODE" == "dual" ]]; then
        dns_json='{
    "servers": [
      {
        "tag": "local",
        "type": "local"
      },
      {
        "tag": "remote",
        "type": "udp",
        "server": "8.8.8.8"
      }
    ],
    "final": "remote"
  }'
    else
        dns_json='{
    "servers": [
      {
        "tag": "local",
        "type": "local"
      },
      {
        "tag": "remote",
        "type": "udp",
        "server": "8.8.8.8"
      }
    ],
    "final": "remote",
    "strategy": "prefer_ipv4"
  }'
    fi
    
    cat > ${CONFIG_FILE} << EOFCONFIG
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": ${dns_json},
  "inbounds": [${INBOUNDS_JSON}],
  "outbounds": ${outbounds},
  "route": ${route_json}
}
EOFCONFIG
    
    print_success "配置文件生成完成"
    return 0
}

start_svc() {
    print_info "验证配置文件..."
    
    local check_output
    check_output=$(${INSTALL_DIR}/sing-box check -c ${CONFIG_FILE} 2>&1)
    local check_exit_code=$?
    
    if [[ $check_exit_code -ne 0 ]]; then
        print_error "配置验证失败 (退出码: ${check_exit_code})"
        echo -e "${YELLOW}错误详情:${NC}"
        echo "$check_output"
        echo ""
        echo -e "${YELLOW}配置文件内容:${NC}"
        cat ${CONFIG_FILE}
        return 1
    fi
    
    if echo "$check_output" | grep -q "WARN"; then
        print_warning "配置验证通过，但有警告："
        echo "$check_output" | grep "WARN"
        echo ""
    else
        print_success "配置验证通过"
    fi
    
    print_info "启动 sing-box 服务..."
    systemctl restart sing-box
    sleep 2
    
    if systemctl is-active --quiet sing-box; then
        print_success "服务启动成功"
        return 0
    else
        print_error "服务启动失败，查看日志："
        journalctl -u sing-box -n 10 --no-pager
        return 1
    fi
}

# ==================== 结果显示 ====================
show_result() {
    clear
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                       ║${NC}"
    echo -e "${CYAN}║               ${GREEN}🎉 配置完成！${CYAN}            ║${NC}"
    echo -e "${CYAN}║                                                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}服务器信息:${NC}"
    echo -e "  协议: ${GREEN}${PROTO}${NC}"
    echo -e "  IP: ${GREEN}${SERVER_IP}${NC}"
    echo -e "  端口: ${GREEN}${PORT}${NC}"
    echo ""
    
    if [[ -n "$EXTRA_INFO" ]]; then
        echo -e "${YELLOW}协议详情:${NC}"
        echo -e "$EXTRA_INFO" | sed 's/^/  /'
        echo ""
    fi
    
    echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}📋 节点链接:${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${YELLOW}${LINK}${NC}"
    echo ""
}

# ==================== 协议选择菜单 ====================
show_menu() {
    show_banner
    echo -e "${YELLOW}请选择要添加的协议节点:${NC}"
    echo ""
    echo -e "${GREEN}[1]${NC} VlessReality ${CYAN}→ 抗审查最强，伪装真实TLS，无需证书${NC} ${YELLOW}(⭐ 强烈推荐)${NC}"
    echo ""
    echo -e "${GREEN}[2]${NC} Hysteria2 ${CYAN}→ 基于QUIC，速度快，垃圾线路专用${NC}"
    echo ""
    echo -e "${GREEN}[3]${NC} SOCKS5 ${CYAN}→ 适合中转的代理协议${NC}"
    echo ""
    echo -e "${GREEN}[4]${NC} ShadowTLS v3 ${CYAN}→ TLS流量伪装${NC}"
    echo ""
    echo -e "${GREEN}[5]${NC} HTTPS ${CYAN}→ 标准HTTPS，可过CDN${NC}"
    echo ""
    echo -e "${GREEN}[6]${NC} AnyTLS ${CYAN}→ 通用TLS协议${NC}"
    echo ""
    read -p "选择 [1-6]: " choice
    
    case $choice in
        1) setup_reality ;;
        2) setup_hysteria2 ;;
        3) setup_socks5 ;;
        4) setup_shadowtls ;;
        5) setup_https ;;
        6) setup_anytls ;;
        *) print_error "无效选项" ; return 1 ;;
    esac
    
    if [[ -n "$INBOUNDS_JSON" ]]; then
        if generate_config && start_svc; then
            show_result
        else
            print_error "配置应用失败，请检查设置"
            return 1
        fi
    fi
}

# ==================== 主菜单、配置查看、卸载等保持不变，仅需将 generate_config 中的 exit 1 改为 return 1 即可 ====================
# （以下为关键函数精简版，完整主菜单保持原样，但已修改错误处理）

main_menu() {
    while true; do
        if [[ -f "${CONFIG_FILE}" ]]; then
            load_inbounds_from_config
        fi
        load_relays_from_file
        load_ip_config
        
        show_main_menu
        read -p "请选择 [0-6]: " m_choice
        
        case $m_choice in
            1) show_menu ;;
            2) setup_relay ;;
            3) ip_config_menu ;;
            4) config_and_view_menu ;;
            5) regenerate_all_links ;;
            6) delete_self ;;
            0) print_info "已退出" ; exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        echo ""
        read -p "按回车返回主菜单..." dummy
    done
}

main() {
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限"
        exit 1
    fi
    
    detect_system
    install_singbox || { print_error "安装 sing-box 失败"; exit 1; }
    mkdir -p /etc/sing-box
    gen_keys
    
    load_ip_config
    if [[ -z "${SERVER_IP}" ]]; then
        get_ip
    fi
    
    setup_sb_shortcut
    
    if [[ -f "${CONFIG_FILE}" ]]; then
        load_inbounds_from_config
    fi
    load_relays_from_file
    load_links_from_files
    
    if [[ -f "${CONFIG_FILE}" ]] && [[ -z "$ALL_LINKS_TEXT" ]]; then
        print_info "检测到链接文件缺失，正在重新生成..."
        regenerate_links_from_config
    fi
    
    main_menu
}

main
