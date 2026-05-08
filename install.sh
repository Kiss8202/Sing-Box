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

# Alpine 标记
ALPINE=0
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
        # 标记是否为 Alpine
        if [[ "$ID" == "alpine" ]]; then
            ALPINE=1
        else
            ALPINE=0
        fi
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
# ==================== 服务控制（兼容 systemd / OpenRC） ====================
svc_start() {
    if [[ $ALPINE -eq 1 ]]; then
        rc-service sing-box start 2>/dev/null
    else
        systemctl start sing-box
    fi
}

svc_stop() {
    if [[ $ALPINE -eq 1 ]]; then
        rc-service sing-box stop 2>/dev/null
    else
        systemctl stop sing-box
    fi
}

svc_restart() {
    if [[ $ALPINE -eq 1 ]]; then
        rc-service sing-box restart 2>/dev/null
    else
        systemctl restart sing-box
    fi
}

svc_enable() {
    if [[ $ALPINE -eq 1 ]]; then
        rc-update add sing-box default >/dev/null 2>&1
    else
        systemctl enable sing-box >/dev/null 2>&1
    fi
}

svc_disable() {
    if [[ $ALPINE -eq 1 ]]; then
        rc-update del sing-box default >/dev/null 2>&1
    else
        systemctl disable sing-box >/dev/null 2>&1
    fi
}

svc_is_active() {
    if [[ $ALPINE -eq 1 ]]; then
        rc-service sing-box status 2>/dev/null | grep -q 'started'
    else
        systemctl is-active --quiet sing-box
    fi
}
# ==================== 日志自动清理配置（首次安装时生效） ====================
LOGROTATE_FLAG="/etc/sing-box/.logrotate_setup"

setup_log_cleanup() {
    [[ -f "${LOGROTATE_FLAG}" ]] && return 0

    print_info "配置日志自动清理（7天 / 100M）..."

    if [[ $ALPINE -eq 1 ]]; then
        # 安装 logrotate 和 dcron，打印错误以便排错
        apk add --no-cache logrotate dcron || {
            print_error "安装 logrotate/dcron 失败，请检查网络或 apk 源"
            return 1
        }

        # 创建 logrotate 配置
        cat > /etc/logrotate.d/sing-box << 'EOF'
/var/log/sing-box.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    maxsize 100M
}
EOF

        # 确保 dcron 在默认运行级别并启动
        rc-update add dcron default 2>/dev/null
        rc-service dcron start 2>/dev/null

        # 等待服务启动，然后检查状态
        sleep 1
        if ! rc-service dcron status | grep -q started; then
            print_error "dcron 服务启动失败，请手动检查"
            return 1
        fi

        print_success "Alpine 日志清理已配置（logrotate + dcron）"
    else
        mkdir -p /etc/systemd/journald.conf.d
        cat > /etc/systemd/journald.conf.d/sing-box-log.conf << 'EOF'
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
EOF
        systemctl restart systemd-journald
        print_success "systemd journald 日志限制已生效"
    fi

    # 仅在全部成功后创建标记文件
    mkdir -p "$(dirname "${LOGROTATE_FLAG}")"
    touch "${LOGROTATE_FLAG}"
}
# ==================== 安装 sing-box ====================
install_singbox() {
    print_info "检查 sing-box 安装状态（支持断点续装）..."

    # ---------- 1. 安装系统依赖（检查 jq 即可代表基础工具） ----------
    if ! command -v jq &>/dev/null; then
        print_info "缺少基础依赖，开始安装..."
        if [[ $ALPINE -eq 1 ]]; then
            # Alpine 低内存：逐个安装
            for pkg in curl wget jq openssl util-linux coreutils gcompat; do
                apk add --no-cache "$pkg" >/dev/null 2>&1
                sleep 0.5
            done
        else
            apt-get update -qq && apt-get install -y curl wget jq openssl uuid-runtime >/dev/null 2>&1
        fi
        print_success "依赖安装完成"
    else
        print_success "基础依赖已就绪"
    fi

    # ---------- 2. 检查 sing-box 二进制是否可执行 ----------
    local need_download=1
    if [[ -x "${INSTALL_DIR}/sing-box" ]]; then
        # 尝试运行版本检查，若返回正常则认为可用
        if ${INSTALL_DIR}/sing-box version >/dev/null 2>&1; then
            local version=$(${INSTALL_DIR}/sing-box version 2>&1 | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
            print_success "sing-box 已安装且可执行 (版本: ${version})"
            need_download=0
        else
            print_warning "检测到损坏的 sing-box，将重新下载安装"
            rm -f "${INSTALL_DIR}/sing-box"
        fi
    fi

    # ---------- 3. 下载、解压、安装二进制（如需要） ----------
    if [[ $need_download -eq 1 ]]; then
        LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
        [[ -z "$LATEST" ]] && LATEST="1.12.0"
        print_info "目标版本: ${LATEST}"

        # 清理可能残留的半成品
        rm -rf /tmp/sb.tar.gz /tmp/sing-box-${LATEST}-linux-${ARCH}

        print_info "下载 sing-box (${LATEST} linux-${ARCH}) ..."
        wget -q --show-progress -O /tmp/sb.tar.gz \
            "https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz" 2>&1
        if [[ ! -f /tmp/sb.tar.gz ]]; then
            print_error "下载失败，请检查网络后重新运行脚本"
            return 1
        fi

        # 小内存机器解压时很可能被杀，解压前确保文件完整
        print_info "解压 sing-box ..."
        if tar -xzf /tmp/sb.tar.gz -C /tmp 4>/dev/null; then
            rm -f /tmp/sb.tar.gz
        else
            print_error "解压失败（可能内存不足被 kill），请增加 swap 后重新运行脚本"
            rm -f /tmp/sb.tar.gz
            return 1
        fi

        # 安装二进制
        if [[ -f "/tmp/sing-box-${LATEST}-linux-${ARCH}/sing-box" ]]; then
            install -Dm755 "/tmp/sing-box-${LATEST}-linux-${ARCH}/sing-box" "${INSTALL_DIR}/sing-box"
            rm -rf "/tmp/sing-box-${LATEST}-linux-${ARCH}"
            print_success "sing-box 二进制安装完成"
        else
            print_error "解压后未找到 sing-box 二进制，请检查"
            return 1
        fi
    fi

    # ---------- 4. 创建或修复服务文件 ----------
    local need_service=0
    if [[ $ALPINE -eq 1 ]]; then
        if [[ ! -f /etc/init.d/sing-box ]]; then
            need_service=1
        else
            # 如果服务文件不含预期的日志重定向命令，则重写
            if ! grep -q "/var/log/sing-box.log" /etc/init.d/sing-box; then
                need_service=1
            fi
        fi
    else
        if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
            need_service=1
        fi
    fi

    if [[ $need_service -eq 1 ]]; then
        print_info "创建/更新服务文件..."
        if [[ $ALPINE -eq 1 ]]; then
            cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"

command="/bin/sh"
command_args="-c 'exec /usr/local/bin/sing-box run -c /etc/sing-box/config.json >> /var/log/sing-box.log 2>&1'"
pidfile="/run/${name}.pid"
required_files="/etc/sing-box/config.json"

supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
            chmod +x /etc/init.d/sing-box
            print_success "OpenRC 服务已创建"
        else
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
            print_success "systemd 服务已创建"
        fi
    else
        print_success "服务文件已就绪"
    fi

    # ---------- 5. 开机自启 ----------
    svc_enable

    # ---------- 6. 配置日志清理（首次安装自动设置） ----------
    setup_log_cleanup

    print_success "sing-box 安装/修复完成"
}
# ==================== 证书生成 ====================
gen_cert_for_sni() {
    local sni="$1"
    local node_cert_dir="${CERT_DIR}/${sni}"
    
    mkdir -p "${node_cert_dir}"
    
    openssl genrsa -out "${node_cert_dir}/private.key" 2048 2>/dev/null
    openssl req -new -x509 -days 36500 -key "${node_cert_dir}/private.key" -out "${node_cert_dir}/cert.pem" -subj "/C=US/ST=California/L=Cupertino/O=Apple Inc./CN=${sni}" 2>/dev/null
    
    print_success "证书生成完成 (${sni}, 有效期100年)"
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
    
    # UUID 生成：优先使用 uuidgen（Alpine 需要 util-linux），否则用 /proc 伪文件
    UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
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
    print_success "密钥已保存到 ${KEY_FILE}"
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

# ==================== 从配置文件加载节点信息 ====================
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
        
        # 添加到 INBOUNDS_JSON
        if [[ -z "$inbound_list" ]]; then
            inbound_list="$inbound"
        else
            inbound_list="${inbound_list},${inbound}"
        fi
        
        # 提取信息
        local tag=$(echo "$inbound" | jq -r '.tag' 2>/dev/null || echo "unknown")
        local port=$(echo "$inbound" | jq -r '.listen_port' 2>/dev/null || echo "0")
        local type=$(echo "$inbound" | jq -r '.type' 2>/dev/null || echo "unknown")
        
        # 跳过 shadowsocks-in-* (ShadowTLS 的内部组件)
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
# ==================== 从配置文件重新生成链接 ====================
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
                local obfs_type=$(echo "$inbound" | jq -r '.obfs.type // ""' 2>/dev/null)
                local obfs_password=$(echo "$inbound" | jq -r '.obfs.password // ""' 2>/dev/null)
                local port_range_num=$(echo "$inbound" | jq -r '.port_range // 0' 2>/dev/null)
                local listen_port=$(echo "$inbound" | jq -r '.listen_port' 2>/dev/null)
                
                [[ -z "$sni" ]] && sni="${DEFAULT_SNI}"
                
                if [[ -n "$password" ]]; then
                    local port_part="$port"
                    if [[ "$port_range_num" -gt 1 ]]; then
                        # 端口跳跃
                        local end_port=$(( listen_port + port_range_num - 1 ))
                        port_part="${listen_port}-${end_port}"
                    fi
                    local link="hysteria2://${password}@${SERVER_IP}:${port_part}?insecure=1&sni=${sni}"
                    if [[ "$obfs_type" == "salamander" && -n "$obfs_password" ]]; then
                        link="${link}&obfs=salamander&obfs-password=${obfs_password}"
                    fi
                    link="${link}#Hysteria2-${SERVER_IP}"
                    local line="[Hysteria2] ${SERVER_IP}:${port_part} (SNI: ${sni})\n${link}\n----------------------------------------\n\n"
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
                    local ss_inbound=$(jq -c ".inbounds[] | select(.tag == \"shadowsocks-in-${port}\")" "${CONFIG_FILE}" 2>/dev/null)
                    local ss_password=$(echo "$ss_inbound" | jq -r '.password // ""' 2>/dev/null)
                    local ss_method=$(echo "$ss_inbound" | jq -r '.method // "2022-blake3-aes-128-gcm"' 2>/dev/null)
                    
                    if [[ -n "$ss_password" ]]; then
                        local ss_userinfo=$(echo -n "${ss_method}:${ss_password}" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
                        local plugin_json="{\"version\":\"3\",\"password\":\"${shadowtls_password}\",\"host\":\"${sni}\",\"port\":\"${port}\",\"address\":\"${SERVER_IP}\"}"
                        local plugin_base64=$(echo -n "$plugin_json" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
                        local link="ss://${ss_userinfo}@${SERVER_IP}:${port}?shadow-tls=${plugin_base64}#ShadowTLS-${SERVER_IP}"
                        
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
        # 使用 base64 编码 JSON 避免换行问题
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
        # 跳过注释和空行
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
    local old_ip="${SERVER_IP}"
    local old_ipv6="${SERVER_IPV6}"
    
    # 获取 IPv4
    local ipv4=$(curl -s4m5 ifconfig.me 2>/dev/null || curl -s4m5 api.ipify.org 2>/dev/null || curl -s4m5 ip.sb 2>/dev/null)
    
    # 获取 IPv6
    local ipv6=$(curl -s6m5 ifconfig.me 2>/dev/null || curl -s6m5 api6.ipify.org 2>/dev/null || curl -s6m5 ip.sb 2>/dev/null)
    
    # 显示检测到的 IP
    echo ""
    if [[ -n "$ipv4" ]]; then
        echo -e "  ${GREEN}检测到 IPv4:${NC} ${ipv4}"
    fi
    if [[ -n "$ipv6" ]]; then
        echo -e "  ${GREEN}检测到 IPv6:${NC} ${ipv6}"
    fi
    echo ""
    
    # 如果两个都没有，报错退出
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        print_error "无法获取服务器 IP 地址"
        exit 1
    fi
    
    # 优先使用 IPv4，没有 IPv4 时使用 IPv6
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
        [[ -z "$INBOUND_IP_MODE" ]] && INBOUND_IP_MODE="ipv6"
        [[ -z "$OUTBOUND_IP_MODE" ]] && OUTBOUND_IP_MODE="dual"
        print_success "使用 IPv6: ${SERVER_IP}"
        print_info "已自动设置入站为 IPv6，出站为双栈模式"
    fi
    
    if [[ -n "$old_ip" && "$old_ip" != "$SERVER_IP" ]]; then
        print_warning "服务器 IPv4 已从 ${old_ip} 变更为 ${SERVER_IP}"
        print_info "建议使用主菜单 [5] 重新生成链接文件"
    fi
    if [[ -n "$old_ipv6" && "$old_ipv6" != "$SERVER_IPV6" ]]; then
        print_warning "服务器 IPv6 已从 ${old_ipv6} 变更为 ${SERVER_IPV6}"
        print_info "建议使用主菜单 [5] 重新生成链接文件"
    fi
    # 保存 IP 配置
    save_ip_config
}

check_port_in_use() {
    local port="$1"
    
    if command -v ss &>/dev/null; then
        ss -tuln | awk '{print $5}' | grep -E "[:.]${port}$" >/dev/null 2>&1 && return 0 || return 1
    elif command -v netstat &>/dev/null; then
        netstat -tuln | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1 && return 0 || return 1
    else
        return 1
    fi
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
# ==================== Reality 配置 ====================
setup_reality() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入SNI域名（建议使用常见HTTPS网站域名）${NC}"
    echo -e "${CYAN}例如: itunes.apple.com, www.bing.com, time.is${NC}"
    read -p "SNI域名 [${DEFAULT_SNI}]: " SNI
    SNI=${SNI:-${DEFAULT_SNI}}
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"vless\",
  \"tag\": \"vless-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"uuid\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\"}],
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
    
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#Reality-${SERVER_IP}"
    
    PROTO="Reality"
    EXTRA_INFO="UUID: ${UUID}\nPublic Key: ${REALITY_PUBLIC}\nShort ID: ${SHORT_ID}\nSNI: ${SNI}"
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

# ==================== Hysteria2 配置（已升级） ====================
setup_hysteria2() {
    echo ""
    # 是否启用端口跳跃
    read -p "是否启用端口跳跃？(y/N): " ENABLE_PORT_JUMP
    ENABLE_PORT_JUMP=${ENABLE_PORT_JUMP:-N}
    PORT_START=""
    PORT_END=""
    if [[ "$ENABLE_PORT_JUMP" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}端口跳跃将在设定的范围随机选择端口进行通信，提高隐蔽性${NC}"
        while true; do
            read -p "起始端口 (例如 1000): " PORT_START
            read -p "结束端口 (例如 2000): " PORT_END
            if ! [[ "$PORT_START" =~ ^[0-9]+$ && "$PORT_END" =~ ^[0-9]+$ ]]; then
                print_error "端口必须为数字"
                continue
            fi
            if (( PORT_START < 1 || PORT_START > 65535 )); then
                print_error "起始端口超出范围"
                continue
            fi
            if (( PORT_END < PORT_START || PORT_END > 65535 )); then
                print_error "结束端口必须大于起始端口且小于65536"
                continue
            fi
            if check_port_in_use "$PORT_START"; then
                print_warning "起始端口 ${PORT_START} 已被占用，请重新输入"
                continue
            fi
            break
        done
        PORT=$PORT_START
    else
        read_port_with_check 443
    fi
    
    echo -e "${YELLOW}请输入SNI域名（建议使用常见HTTPS网站域名）${NC}"
    echo -e "${CYAN}例如: itunes.apple.com, www.bing.com, time.is${NC}"
    read -p "SNI域名 [${DEFAULT_SNI}]: " HY2_SNI
    HY2_SNI=${HY2_SNI:-${DEFAULT_SNI}}
    
    # 是否启用 Salamander 混淆
    read -p "是否启用 Salamander 混淆？(y/N): " ENABLE_OBFS
    ENABLE_OBFS=${ENABLE_OBFS:-N}
    OBFS_PASSWORD=""
    if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
        read -p "混淆密码 (留空随机生成16位hex): " OBFS_PASSWORD
        if [[ -z "$OBFS_PASSWORD" ]]; then
            OBFS_PASSWORD=$(openssl rand -hex 16)
        fi
        print_info "混淆密码: ${OBFS_PASSWORD}"
    fi
    
    print_info "为 ${HY2_SNI} 生成自签证书..."
    gen_cert_for_sni "${HY2_SNI}"
    
    print_info "生成配置文件..."
    
    # 构建 obfs 配置
    local obfs_config=""
    if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
        obfs_config=",
    \"obfs\": {
      \"type\": \"salamander\",
      \"password\": \"${OBFS_PASSWORD}\"
    }"
    fi
    
    # 构建端口跳跃配置
    local port_range_config=""
    local listen_port=$PORT
    if [[ "$ENABLE_PORT_JUMP" =~ ^[Yy]$ ]]; then
        listen_port=$PORT_START
        local range_num=$((PORT_END - PORT_START + 1))
        port_range_config=",
    \"listen_port_range\": true,
    \"port_range\": ${range_num}"
    fi
    
    # 生成 inbound
    local inbound="{
  \"type\": \"hysteria2\",
  \"tag\": \"hy2-in-${listen_port}\",
  \"listen\": \"::\",
  \"listen_port\": ${listen_port},
  \"users\": [{\"password\": \"${HY2_PASSWORD}\"}],
  \"tls\": {
    \"enabled\": true,
    \"alpn\": [\"h3\"],
    \"server_name\": \"${HY2_SNI}\",
    \"certificate_path\": \"${CERT_DIR}/${HY2_SNI}/cert.pem\",
    \"key_path\": \"${CERT_DIR}/${HY2_SNI}/private.key\"
  }${obfs_config}${port_range_config}
}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    # 构建链接
    local port_display=$PORT
    if [[ "$ENABLE_PORT_JUMP" =~ ^[Yy]$ ]]; then
        port_display="${PORT_START}-${PORT_END}"
    fi
    LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${port_display}?insecure=1&sni=${HY2_SNI}"
    if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
        LINK="${LINK}&obfs=salamander&obfs-password=${OBFS_PASSWORD}"
    fi
    LINK="${LINK}#Hysteria2-${SERVER_IP}"
    
    PROTO="Hysteria2"
    EXTRA_INFO="密码: ${HY2_PASSWORD}\n证书: 自签证书(${HY2_SNI})\nSNI: ${HY2_SNI}"
    if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
        EXTRA_INFO="${EXTRA_INFO}\nSalamander混淆: 已启用 (密码: ${OBFS_PASSWORD})"
    fi
    if [[ "$ENABLE_PORT_JUMP" =~ ^[Yy]$ ]]; then
        EXTRA_INFO="${EXTRA_INFO}\n端口跳跃: ${PORT_START}-${PORT_END}"
    fi
    
    local line="[Hysteria2] ${SERVER_IP}:${port_display} (SNI: ${HY2_SNI})\n${LINK}\n----------------------------------------\n\n"
    ALL_LINKS_TEXT="${ALL_LINKS_TEXT}${line}"
    HYSTERIA2_LINKS="${HYSTERIA2_LINKS}${line}"
    
    INBOUND_TAGS+=("hy2-in-${listen_port}")
    INBOUND_PORTS+=("${listen_port}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${HY2_SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "Hysteria2 配置完成 (SNI: ${HY2_SNI})"
    if [[ "$ENABLE_PORT_JUMP" =~ ^[Yy]$ ]]; then
        print_success "端口跳跃已启用: ${PORT_START}-${PORT_END}"
    fi
    save_links_to_files
}

# ==================== SOCKS5 配置 ====================
setup_socks5() {
    echo ""
    read_port_with_check 1080
    read -p "是否启用认证? [Y/n]: " ENABLE_AUTH
    ENABLE_AUTH=${ENABLE_AUTH:-Y}
    
    print_info "生成配置文件..."
    
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        local inbound="{
  \"type\": \"socks\",
  \"tag\": \"socks-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"username\": \"${SOCKS_USER}\", \"password\": \"${SOCKS_PASS}\"}]
}"
        LINK="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${PORT}#SOCKS5-${SERVER_IP}"
        EXTRA_INFO="用户名: ${SOCKS_USER}\n密码: ${SOCKS_PASS}"
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

# ==================== ShadowTLS 配置 ====================
setup_shadowtls() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入SNI域名（建议使用常见HTTPS网站域名）${NC}"
    echo -e "${CYAN}例如: itunes.apple.com, www.bing.com, time.is${NC}"
    read -p "SNI域名 [${DEFAULT_SNI}]: " SHADOWTLS_SNI
    SHADOWTLS_SNI=${SHADOWTLS_SNI:-${DEFAULT_SNI}}
    
    print_info "生成配置文件..."
    print_warning "ShadowTLS 通过伪装真实域名的TLS握手工作"
    
    local inbound="{
  \"type\": \"shadowtls\",
  \"tag\": \"shadowtls-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"version\": 3,
  \"users\": [{\"password\": \"${SHADOWTLS_PASSWORD}\"}],
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
  \"password\": \"${SS_PASSWORD}\"
}"
    
    local ss_userinfo=$(echo -n "2022-blake3-aes-128-gcm:${SS_PASSWORD}" | base64 -w0 | sed 's/+/-/g; s/\//_/g; s/=//g')
    local plugin_json="{\"version\":\"3\",\"password\":\"${SHADOWTLS_PASSWORD}\",\"host\":\"${SHADOWTLS_SNI}\",\"port\":\"${PORT}\",\"address\":\"${SERVER_IP}\"}"
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
      "password": "${SS_PASSWORD}",
      "detour": "shadowtls-out-${PORT}"
    },
    {
      "type": "shadowtls",
      "tag": "shadowtls-out-${PORT}",
      "server": "${SERVER_IP}",
      "server_port": ${PORT},
      "version": 3,
      "password": "${SHADOWTLS_PASSWORD}",
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
    
    EXTRA_INFO="Shadowsocks方法: 2022-blake3-aes-128-gcm\nShadowsocks密码: ${SS_PASSWORD}\nShadowTLS密码: ${SHADOWTLS_PASSWORD}\n伪装域名: ${SHADOWTLS_SNI}\n\n${RED}重要: ShadowTLS 不支持链接格式！${NC}\n${YELLOW}请使用客户端配置文件:${NC}\n  ${client_config_file}\n\n${CYAN}下载命令:${NC}\n  scp root@${SERVER_IP}:${client_config_file} ./\n\n${CYAN}或直接查看:${NC}\n  cat ${client_config_file}"
    
    INBOUND_TAGS+=("shadowtls-in-${PORT}")
    INBOUND_PORTS+=("${PORT}")
    INBOUND_PROTOS+=("${PROTO}")
    INBOUND_SNIS+=("${SHADOWTLS_SNI}")
    INBOUND_RELAY_TAGS+=("direct")
    
    print_success "ShadowTLS v3 配置完成 (SNI: ${SHADOWTLS_SNI})"
    print_info "客户端配置文件已保存: ${client_config_file}"
    save_links_to_files
}

# ==================== HTTPS 配置 ====================
setup_https() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入SNI域名（建议使用常见HTTPS网站域名）${NC}"
    echo -e "${CYAN}例如: itunes.apple.com, www.bing.com, time.is${NC}"
    read -p "SNI域名 [${DEFAULT_SNI}]: " HTTPS_SNI
    HTTPS_SNI=${HTTPS_SNI:-${DEFAULT_SNI}}
    
    print_info "为 ${HTTPS_SNI} 生成自签证书..."
    gen_cert_for_sni "${HTTPS_SNI}"
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"vless\",
  \"tag\": \"vless-tls-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"uuid\": \"${UUID}\"}],
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${HTTPS_SNI}\",
    \"certificate_path\": \"${CERT_DIR}/${HTTPS_SNI}/cert.pem\",
    \"key_path\": \"${CERT_DIR}/${HTTPS_SNI}/private.key\"
  }
}"
    
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=tls&sni=${HTTPS_SNI}&type=tcp&allowInsecure=1#HTTPS-${SERVER_IP}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    PROTO="HTTPS"
    EXTRA_INFO="UUID: ${UUID}\n证书: 自签证书(${HTTPS_SNI})\nSNI: ${HTTPS_SNI}"
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

# ==================== AnyTLS 配置 ====================
setup_anytls() {
    echo ""
    read_port_with_check 443
    
    echo -e "${YELLOW}请输入SNI域名（建议使用常见HTTPS网站域名）${NC}"
    echo -e "${CYAN}例如: itunes.apple.com, www.bing.com, time.is${NC}"
    read -p "SNI域名 [${DEFAULT_SNI}]: " ANYTLS_SNI
    ANYTLS_SNI=${ANYTLS_SNI:-${DEFAULT_SNI}}
    
    print_info "为 ${ANYTLS_SNI} 生成自签证书..."
    gen_cert_for_sni "${ANYTLS_SNI}"
    
    print_info "生成配置文件..."
    
    local inbound="{
  \"type\": \"anytls\",
  \"tag\": \"anytls-in-${PORT}\",
  \"listen\": \"::\",
  \"listen_port\": ${PORT},
  \"users\": [{\"password\": \"${ANYTLS_PASSWORD}\"}],
  \"padding_scheme\": [],
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${ANYTLS_SNI}\",
    \"certificate_path\": \"${CERT_DIR}/${ANYTLS_SNI}/cert.pem\",
    \"key_path\": \"${CERT_DIR}/${ANYTLS_SNI}/private.key\"
  }
}"
    
    LINK="anytls://${ANYTLS_PASSWORD}@${SERVER_IP}:${PORT}?security=tls&fp=chrome&insecure=1&sni=${ANYTLS_SNI}&type=tcp#AnyTLS-${SERVER_IP}"
    
    if [[ -z "$INBOUNDS_JSON" ]]; then
        INBOUNDS_JSON="$inbound"
    else
        INBOUNDS_JSON="${INBOUNDS_JSON},${inbound}"
    fi
    
    PROTO="AnyTLS"
    EXTRA_INFO="密码: ${ANYTLS_PASSWORD}\n自签证书: ${ANYTLS_SNI}\nSNI: ${ANYTLS_SNI}"
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
# ==================== 中转配置菜单 ====================
# ==================== 中转链接解析 ====================
parse_socks_link() {
    local link="$1"
    
    if [[ "$link" =~ ^socks://([A-Za-z0-9+/=]+) ]]; then
        print_info "检测到 base64 编码的 SOCKS 链接，正在解码..."
        local base64_part="${BASH_REMATCH[1]}"
        local decoded=$(echo "$base64_part" | base64 -d 2>/dev/null)
        
        if [[ -z "$decoded" ]]; then
            print_error "base64 解码失败"
            return 1
        fi
        
        link="socks5://${decoded}"
    fi
    
    local data=$(echo "$link" | sed 's|socks5\?://||')
    data=$(echo "$data" | cut -d'?' -f1 | cut -d'#' -f1)
    
    local relay_json=""
    local relay_desc=""
    
    if [[ "$data" =~ @ ]]; then
        local userpass=$(echo "$data" | cut -d'@' -f1)
        local username=$(echo "$userpass" | cut -d':' -f1)
        local password=$(echo "$userpass" | cut -d':' -f2-)
        local server_port=$(echo "$data" | cut -d'@' -f2)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2)
        
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            print_error "端口无效: ${port}"
            return 1
        fi
        
        local tag="relay-socks5-${#RELAY_TAGS[@]}"
        relay_json="{
  \"type\": \"socks\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"version\": \"5\",
  \"username\": \"${username}\",
  \"password\": \"${password}\"
}"
        relay_desc="SOCKS5 ${server}:${port} (认证)"
    else
        local server=$(echo "$data" | cut -d':' -f1)
        local port=$(echo "$data" | cut -d':' -f2)
        
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            print_error "端口无效: ${port}"
            return 1
        fi
        
        local tag="relay-socks5-${#RELAY_TAGS[@]}"
        relay_json="{
  \"type\": \"socks\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"version\": \"5\"
}"
        relay_desc="SOCKS5 ${server}:${port}"
    fi
    
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")
    
    save_relays_to_file
    print_success "SOCKS5 中转已添加: ${relay_desc}"
}

parse_http_link() {
    local link="$1"
    local protocol=$(echo "$link" | cut -d':' -f1)
    local data=$(echo "$link" | sed 's|https\?://||')
    
    local tls="false"
    [[ "$protocol" == "https" ]] && tls="true"
    
    local relay_json=""
    local relay_desc=""
    local tag="relay-http-${#RELAY_TAGS[@]}"
    
    if [[ "$data" =~ @ ]]; then
        local userpass=$(echo "$data" | cut -d'@' -f1)
        local username=$(echo "$userpass" | cut -d':' -f1)
        local password=$(echo "$userpass" | cut -d':' -f2)
        local server_port=$(echo "$data" | cut -d'@' -f2)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2 | cut -d'/' -f1 | cut -d'#' -f1 | cut -d'?' -f1)
        
        relay_json="{
  \"type\": \"http\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"username\": \"${username}\",
  \"password\": \"${password}\",
  \"tls\": {\"enabled\": ${tls}}
}"
        relay_desc="${protocol^^} ${server}:${port} (认证)"
    else
        local server=$(echo "$data" | cut -d':' -f1)
        local port=$(echo "$data" | cut -d':' -f2 | cut -d'/' -f1 | cut -d'#' -f1 | cut -d'?' -f1)
        
        relay_json="{
  \"type\": \"http\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"tls\": {\"enabled\": ${tls}}
}"
        relay_desc="${protocol^^} ${server}:${port}"
    fi
    
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")
    
    save_relays_to_file
    print_success "HTTP(S) 中转已添加: ${relay_desc}"
}

parse_ss_link() {
    local link="$1"
    local data=$(echo "$link" | sed 's|ss://||' | cut -d'#' -f1)
    
    if [[ "$data" =~ @ ]]; then
        local userinfo=$(echo "$data" | cut -d'@' -f1)
        local server_port=$(echo "$data" | cut -d'@' -f2 | cut -d'?' -f1)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2)
        
        local decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
        if [[ -z "$decoded" ]]; then
            print_error "Shadowsocks 链接解码失败"
            return 1
        fi
        
        local method=$(echo "$decoded" | cut -d':' -f1)
        local password=$(echo "$decoded" | cut -d':' -f2-)
        
        local tag="relay-ss-${#RELAY_TAGS[@]}"
        local relay_json="{
  \"type\": \"shadowsocks\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"method\": \"${method}\",
  \"password\": \"${password}\"
}"
        local relay_desc="Shadowsocks ${server}:${port}"
        
        RELAY_TAGS+=("$tag")
        RELAY_JSONS+=("$relay_json")
        RELAY_DESCS+=("$relay_desc")
        
        save_relays_to_file
        print_success "Shadowsocks 中转已添加: ${relay_desc}"
    else
        print_error "Shadowsocks 链接格式错误"
        return 1
    fi
}

parse_vmess_link() {
    local link="$1"
    local base64_data=$(echo "$link" | sed 's|vmess://||')
    local json=$(echo "$base64_data" | base64 -d 2>/dev/null)
    
    if [[ -z "$json" ]]; then
        print_error "VMess 链接解码失败"
        return 1
    fi
    
    if ! command -v jq &>/dev/null; then
        print_error "需要 jq 工具来解析 VMess 链接"
        return 1
    fi
    
    local server=$(echo "$json" | jq -r '.add // .address')
    local port=$(echo "$json" | jq -r '.port')
    local uuid=$(echo "$json" | jq -r '.id')
    local alterId=$(echo "$json" | jq -r '.aid // 0')
    local security=$(echo "$json" | jq -r '.scy // "auto"')
    
    local tag="relay-vmess-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"vmess\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"uuid\": \"${uuid}\",
  \"alter_id\": ${alterId},
  \"security\": \"${security}\"
}"
    local relay_desc="VMess ${server}:${port}"
    
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")
    
    save_relays_to_file
    print_success "VMess 中转已添加: ${relay_desc}"
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
    
    local security="none"
    local sni=""
    local flow=""
    
    if [[ -n "$params" ]]; then
        [[ "$params" =~ security=([^&]+) ]] && security="${BASH_REMATCH[1]}"
        [[ "$params" =~ sni=([^&]+) ]] && sni="${BASH_REMATCH[1]}"
        [[ "$params" =~ flow=([^&]+) ]] && flow="${BASH_REMATCH[1]}"
    fi
    
    local tls_config=""
    if [[ "$security" == "tls" || "$security" == "reality" ]]; then
        tls_config=",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${sni}\"
  }"
    fi
    
    local flow_config=""
    [[ -n "$flow" ]] && flow_config=",
  \"flow\": \"${flow}\""
    
    local tag="relay-vless-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"vless\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"uuid\": \"${uuid}\"${flow_config}${tls_config}
}"
    local relay_desc="VLESS ${server}:${port}"
    
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")
    
    save_relays_to_file
    print_success "VLESS 中转已添加: ${relay_desc}"
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
    
    local sni=""
    [[ "$params" =~ sni=([^&]+) ]] && sni="${BASH_REMATCH[1]}"
    
    local tag="relay-trojan-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"trojan\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"password\": \"${password}\",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${sni}\"
  }
}"
    local relay_desc="Trojan ${server}:${port}"
    
    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")
    
    save_relays_to_file
    print_success "Trojan 中转已添加: ${relay_desc}"
}

setup_relay() {
    # 加载中转配置
    load_relays_from_file
    
    while true; do
        echo ""
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              ${GREEN}中转配置菜单${CYAN}                  ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # 显示当前中转列表
        if [[ ${#RELAY_TAGS[@]} -gt 0 ]]; then
            echo -e "${YELLOW}当前中转列表:${NC}"
            for i in "${!RELAY_TAGS[@]}"; do
                idx=$((i+1))
                echo -e "  ${GREEN}[${idx}]${NC} ${RELAY_DESCS[$i]}"
            done
            echo ""
        else
            echo -e "${YELLOW}当前没有配置中转${NC}"
            echo ""
        fi
        
        echo -e "  ${GREEN}[1]${NC} 添加新的中转链接"
        echo -e "  ${GREEN}[2]${NC} 为节点配置中转"
        echo -e "  ${GREEN}[3]${NC} 删除中转链接"
        echo -e "  ${GREEN}[0]${NC} 返回主菜单"
        echo ""
        read -p "请选择 [0-3]: " r_choice
        
        case $r_choice in
            1)
                echo ""
                echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
                echo -e "${CYAN}║          ${GREEN}支持的中转协议格式${CYAN}              ║${NC}"
                echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${GREEN}1. SOCKS5 代理${NC}"
                echo -e "   ${YELLOW}格式:${NC} socks5://[用户名:密码@]服务器:端口"
                echo -e "   ${CYAN}示例:${NC}"
                echo -e "     socks5://user:pass@1.2.3.4:1080"
                echo -e "     socks5://1.2.3.4:1080 ${YELLOW}(无认证)${NC}"
                echo ""
                echo -e "${GREEN}2. HTTP/HTTPS 代理${NC}"
                echo -e "   ${YELLOW}格式:${NC} http(s)://[用户名:密码@]服务器:端口"
                echo -e "   ${CYAN}示例:${NC}"
                echo -e "     http://user:pass@1.2.3.4:8080"
                echo -e "     https://1.2.3.4:443 ${YELLOW}(无认证)${NC}"
                echo ""
                echo -e "${GREEN}3. Shadowsocks${NC}"
                echo -e "   ${YELLOW}格式:${NC} ss://base64(加密方式:密码)@服务器:端口"
                echo -e "   ${CYAN}示例:${NC}"
                echo -e "     ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@1.2.3.4:8388"
                echo ""
                echo -e "${GREEN}4. VMess${NC}"
                echo -e "   ${YELLOW}格式:${NC} vmess://base64(JSON配置)"
                echo -e "   ${CYAN}说明:${NC} 标准 V2Ray 分享链接"
                echo ""
                echo -e "${GREEN}5. VLESS${NC}"
                echo -e "   ${YELLOW}格式:${NC} vless://UUID@服务器:端口?参数#备注"
                echo -e "   ${CYAN}示例:${NC}"
                echo -e "     vless://uuid@1.2.3.4:443?security=tls&sni=example.com"
                echo -e "   ${YELLOW}支持参数:${NC} security, sni, flow, type 等"
                echo ""
                echo -e "${GREEN}6. Trojan${NC}"
                echo -e "   ${YELLOW}格式:${NC} trojan://密码@服务器:端口?参数#备注"
                echo -e "   ${CYAN}示例:${NC}"
                echo -e "     trojan://password@1.2.3.4:443?sni=example.com"
                echo -e "   ${YELLOW}支持参数:${NC} sni, type, security 等"
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${YELLOW}提示:${NC} 直接粘贴完整的节点分享链接即可，脚本会自动识别协议类型"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                read -p "粘贴中转链接: " RELAY_LINK
                
                if [[ -z "$RELAY_LINK" ]]; then
                    print_warning "未提供链接，中转配置保持不变"
                else
                    if [[ "$RELAY_LINK" =~ ^socks ]]; then
                        parse_socks_link "$RELAY_LINK"
                    elif [[ "$RELAY_LINK" =~ ^https? ]]; then
                        parse_http_link "$RELAY_LINK"
                    elif [[ "$RELAY_LINK" =~ ^ss:// ]]; then
                        parse_ss_link "$RELAY_LINK"
                    elif [[ "$RELAY_LINK" =~ ^vmess:// ]]; then
                        parse_vmess_link "$RELAY_LINK"
                    elif [[ "$RELAY_LINK" =~ ^vless:// ]]; then
                        parse_vless_link "$RELAY_LINK"
                    elif [[ "$RELAY_LINK" =~ ^trojan:// ]]; then
                        parse_trojan_link "$RELAY_LINK"
                    else
                        print_error "不支持的链接格式"
                    fi
                fi
                ;;
            2)
                if [[ ${#INBOUND_TAGS[@]} -eq 0 ]]; then
                    print_warning "当前尚未添加任何节点，请先添加节点"
                    continue
                fi
                
                if [[ ${#RELAY_TAGS[@]} -eq 0 ]]; then
                    print_warning "尚未添加任何中转链接，请先选择选项 [1] 添加中转"
                    continue
                fi
                
                # 选择节点
                echo ""
                echo -e "${CYAN}选择要配置中转的节点:${NC}"
                for i in "${!INBOUND_TAGS[@]}"; do
                    idx=$((i+1))
                    local relay_status="${INBOUND_RELAY_TAGS[$i]}"
                    local relay_desc="直连"
                    
                    if [[ "$relay_status" != "direct" ]]; then
                        # 查找中转描述
                        for j in "${!RELAY_TAGS[@]}"; do
                            if [[ "${RELAY_TAGS[$j]}" == "$relay_status" ]]; then
                                relay_desc="中转: ${RELAY_DESCS[$j]}"
                                break
                            fi
                        done
                    fi
                    
                    echo -e "  ${GREEN}[${idx}]${NC} ${INBOUND_PROTOS[$i]}:${INBOUND_PORTS[$i]} → ${YELLOW}${relay_desc}${NC}"
                done
                echo ""
                read -p "请输入节点序号 (输入 0 返回): " node_idx
                
                if [[ "$node_idx" == "0" ]]; then
                    continue
                fi
                
                if ! [[ "$node_idx" =~ ^[0-9]+$ ]] || (( node_idx < 1 || node_idx > ${#INBOUND_TAGS[@]} )); then
                    print_error "无效的节点序号"
                    continue
                fi
                
                local n=$((node_idx-1))
                
                # 选择中转
                echo ""
                echo -e "${CYAN}选择中转方式:${NC}"
                echo -e "  ${GREEN}[0]${NC} 直连 (不使用中转)"
                for i in "${!RELAY_TAGS[@]}"; do
                    idx=$((i+1))
                    echo -e "  ${GREEN}[${idx}]${NC} ${RELAY_DESCS[$i]}"
                done
                echo ""
                read -p "请选择: " relay_idx
                
                if [[ "$relay_idx" == "0" ]]; then
                    INBOUND_RELAY_TAGS[$n]="direct"
                    print_success "节点已设置为直连"
                elif [[ "$relay_idx" =~ ^[0-9]+$ ]] && (( relay_idx >= 1 && relay_idx <= ${#RELAY_TAGS[@]} )); then
                    local r=$((relay_idx-1))
                    INBOUND_RELAY_TAGS[$n]="${RELAY_TAGS[$r]}"
                    print_success "节点已设置为: ${RELAY_DESCS[$r]}"
                else
                    print_error "无效选择"
                    continue
                fi
                
                # 应用配置
                if [[ -n "$INBOUNDS_JSON" ]]; then
                    generate_config && start_svc
                fi
                ;;
            3)
                if [[ ${#RELAY_TAGS[@]} -eq 0 ]]; then
                    print_warning "当前没有中转链接"
                    continue
                fi
                
                echo ""
                echo -e "${CYAN}删除中转链接:${NC}"
                echo -e "  ${GREEN}[0]${NC} 删除全部中转"
                for i in "${!RELAY_TAGS[@]}"; do
                    idx=$((i+1))
                    echo -e "  ${GREEN}[${idx}]${NC} ${RELAY_DESCS[$i]}"
                done
                echo ""
                read -p "请选择要删除的中转 (输入 0 删除全部, 输入 -1 取消): " del_idx
                
                if [[ "$del_idx" == "-1" ]]; then
                    continue
                elif [[ "$del_idx" == "0" ]]; then
                    echo ""
                    read -p "确认删除全部中转? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        RELAY_TAGS=()
                        RELAY_JSONS=()
                        RELAY_DESCS=()
                        rm -f "${RELAY_FILE}"
                        
                        # 将所有节点设置为直连
                        for i in "${!INBOUND_RELAY_TAGS[@]}"; do
                            INBOUND_RELAY_TAGS[$i]="direct"
                        done
                        
                        print_success "已删除全部中转配置"
                        
                        # 重新生成配置
                        if [[ -n "$INBOUNDS_JSON" ]]; then
                            generate_config && start_svc
                        fi
                    fi
                elif [[ "$del_idx" =~ ^[0-9]+$ ]] && (( del_idx >= 1 && del_idx <= ${#RELAY_TAGS[@]} )); then
                    local d=$((del_idx-1))
                    local del_tag="${RELAY_TAGS[$d]}"
                    local del_desc="${RELAY_DESCS[$d]}"
                    
                    echo ""
                    read -p "确认删除中转: ${del_desc}? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        # 删除中转
                        unset RELAY_TAGS[$d]
                        unset RELAY_JSONS[$d]
                        unset RELAY_DESCS[$d]
                        
                        # 重建数组
                        RELAY_TAGS=("${RELAY_TAGS[@]}")
                        RELAY_JSONS=("${RELAY_JSONS[@]}")
                        RELAY_DESCS=("${RELAY_DESCS[@]}")
                        
                        # 将使用该中转的节点改为直连
                        for i in "${!INBOUND_RELAY_TAGS[@]}"; do
                            if [[ "${INBOUND_RELAY_TAGS[$i]}" == "$del_tag" ]]; then
                                INBOUND_RELAY_TAGS[$i]="direct"
                            fi
                        done
                        
                        save_relays_to_file
                        print_success "已删除中转: ${del_desc}"
                        
                        # 重新生成配置
                        if [[ -n "$INBOUNDS_JSON" ]]; then
                            generate_config && start_svc
                        fi
                    fi
                else
                    print_error "无效选择"
                fi
                ;;
            0)
                break
                ;;
            *)
                print_error "无效选项"
                ;;
        esac
    done
}

# ==================== 出入站 IP 配置菜单 ====================
ip_config_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              ${GREEN}出入站 IP 配置${CYAN}                ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "$
