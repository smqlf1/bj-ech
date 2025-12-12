#!/bin/sh

REPO_OWNER="byJoey"
REPO_NAME="ech-wk"
BIN_PATH="/usr/bin/ech-workers"
CONF_FILE="/etc/ech-workers.conf"
TMP_DIR="/tmp/ech-workers"

# 默认配置
DEFAULT_BEST_IP="joeyblog.net"
DEFAULT_SERVER_ADDR="echo.example.com:443"
DEFAULT_LISTEN_ADDR="0.0.0.0:30001"
DEFAULT_TOKEN=""
DEFAULT_DNS="https://dns.alidns.com/dns-query"
DEFAULT_ECH_DOMAIN="cloudflare-ech.com"
DEFAULT_ROUTING="global"

# --- 系统检测 ---
check_sys() {
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"
        INIT_TYPE="procd"
        INIT_FILE="/etc/init.d/ech-workers"
    elif command -v systemctl >/dev/null 2>&1; then
        OS_TYPE="linux_systemd"
        INIT_TYPE="systemd"
        INIT_FILE="/etc/systemd/system/ech-workers.service"
    else
        OS_TYPE="linux_generic"
        INIT_TYPE="unknown"
        INIT_FILE=""
    fi
}

# --- 依赖安装 ---
install_pkg() {
    local pkg=$1
    command -v "$pkg" >/dev/null 2>&1 && return 0

    echo "正在安装 $pkg ..."
    if [ "$OS_TYPE" = "openwrt" ]; then
        opkg update && opkg install "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg"
    elif command -v apk >/dev/null 2>&1; then
        apk add "$pkg"
    else
        echo "无法自动安装 $pkg，请手动安装。"
        return 1
    fi
}

# 基础环境检查
check_env() {
    install_pkg wget
    install_pkg tar
    # 常规 Linux 可能需要 ca-certificates
    if [ "$OS_TYPE" != "openwrt" ]; then
        install_pkg ca-certificates
    fi
}

# 获取当前架构
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

# 获取下载链接
get_latest_release_url() {
    echo "正在获取版本信息..." >&2
    
    api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    # 增加 --no-check-certificate 兼容老旧系统
    json_content=$(wget -qO- --no-check-certificate "$api_url")
    
    if [ -z "$json_content" ]; then
        echo "获取 API 失败，请检查网络。" >&2
        return 1
    fi

    ARCH=$(get_arch)
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
        echo "错误: 不支持的系统架构: $ARCH" >&2
        return 1
    fi
    
    echo "检测到系统: $OS_TYPE, 架构: $ARCH" >&2

    download_url=""
    
    # 策略：OpenWrt 优先找 softrouter 版，常规 Linux 优先找标准版
    if [ "$OS_TYPE" = "openwrt" ]; then
        # 优先 softrouter
        download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}-softrouter[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
    else
        # 优先标准版
        download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}.tar.gz[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
    fi

    # 如果首选策略失败，尝试另一种
    if [ -z "$download_url" ]; then
        echo "首选版本未找到，尝试备用版本..." >&2
        if [ "$OS_TYPE" = "openwrt" ]; then
            download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}.tar.gz[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
        else
            download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}-softrouter[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
        fi
    fi

    if [ -z "$download_url" ]; then
        echo "未找到适合架构 ($ARCH) 的下载链接" >&2
        return 1
    fi

    echo "$download_url"
}

# 安装二进制
ensure_binary() {
    if [ -x "$BIN_PATH" ]; then return 0; fi

    check_env
    URL=$(get_latest_release_url)
    if [ $? -ne 0 ]; then return 1; fi

    echo "下载地址: $URL"
    mkdir -p "$(dirname "$BIN_PATH")"
    mkdir -p "$TMP_DIR"

    echo "正在下载..."
    wget -q --show-progress --no-check-certificate -O "$TMP_DIR/ech-workers.tar.gz" "$URL"
    
    if [ ! -f "$TMP_DIR/ech-workers.tar.gz" ]; then
        echo "下载失败"
        return 1
    fi

    echo "解压中..."
    tar -zxvf "$TMP_DIR/ech-workers.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1

    EXTRACTED_BIN=$(find "$TMP_DIR" -type f -name "ech-workers" | head -n 1)
    
    if [ -n "$EXTRACTED_BIN" ]; then
        mv "$EXTRACTED_BIN" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        echo "安装成功: $BIN_PATH"
        rm -rf "$TMP_DIR"
    else
        echo "解压错误: 未找到二进制文件"
        return 1
    fi
}

# 确保配置存在
ensure_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        mkdir -p "$(dirname "$CONF_FILE")"
        cat >"$CONF_FILE" <<EOF
BEST_IP="$DEFAULT_BEST_IP"
SERVER_ADDR="$DEFAULT_SERVER_ADDR"
LISTEN_ADDR="$DEFAULT_LISTEN_ADDR"
TOKEN="$DEFAULT_TOKEN"
DNS="$DEFAULT_DNS"
ECH_DOMAIN="$DEFAULT_ECH_DOMAIN"
ROUTING="$DEFAULT_ROUTING"
EOF
    fi
}

# 确保服务配置 (核心差异部分)
ensure_init() {
    ensure_conf # 确保配置文件存在，因为 systemd 需要读取

    if [ "$INIT_TYPE" = "procd" ]; then
        # --- OpenWrt Procd ---
        cat >"$INIT_FILE" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
BIN="/usr/bin/ech-workers"
CONF="/etc/ech-workers.conf"

start_service() {
    [ -x "$BIN" ] || return 1
    [ -f "$CONF" ] && . "$CONF"
    : "${DNS:=https://dns.alidns.com/dns-query}"
    : "${ECH_DOMAIN:=cloudflare-ech.com}"
    : "${ROUTING:=global}"

    procd_open_instance
    procd_set_param command "$BIN" \
        -f "${SERVER_ADDR}" \
        -l "${LISTEN_ADDR}" \
        -token "${TOKEN}" \
        -ip "${BEST_IP}" \
        -dns "${DNS}" \
        -ech "${ECH_DOMAIN}" \
        -routing "${ROUTING}"
    procd_set_param respawn
    procd_set_param stdout 1 
    procd_set_param stderr 1
    procd_close_instance
}
EOF
        chmod +x "$INIT_FILE"
        /etc/init.d/ech-workers enable >/dev/null 2>&1

    elif [ "$INIT_TYPE" = "systemd" ]; then
        # --- Linux Systemd ---
        # 注意：这里使用了 EnvironmentFile 来加载配置
        cat >"$INIT_FILE" <<EOF
[Unit]
Description=ECH Workers Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONF_FILE
ExecStart=$BIN_PATH -f \${SERVER_ADDR} -l \${LISTEN_ADDR} -token \${TOKEN} -ip \${BEST_IP} -dns \${DNS} -ech \${ECH_DOMAIN} -routing \${ROUTING}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ech-workers >/dev/null 2>&1
    else
        echo "警告: 未知的初始化系统，无法自动配置开机自启。请手动运行。"
    fi
}

# 服务控制函数
svc_restart() {
    if [ "$INIT_TYPE" = "procd" ]; then
        /etc/init.d/ech-workers restart
    elif [ "$INIT_TYPE" = "systemd" ]; then
        systemctl restart ech-workers
    else
        killall ech-workers 2>/dev/null
        # 简易后台运行
        nohup "$BIN_PATH" -f "$SERVER_ADDR" -l "$LISTEN_ADDR" -token "$TOKEN" -ip "$BEST_IP" -dns "$DNS" -ech "$ECH_DOMAIN" -routing "$ROUTING" >/dev/null 2>&1 &
    fi
}

svc_stop() {
    if [ "$INIT_TYPE" = "procd" ]; then
        /etc/init.d/ech-workers stop
    elif [ "$INIT_TYPE" = "systemd" ]; then
        systemctl stop ech-workers
    else
        killall ech-workers
    fi
}

svc_log() {
    echo "--- 日志 (Ctrl+C 退出) ---"
    if [ "$INIT_TYPE" = "procd" ]; then
        logread -e ech-workers -f
    elif [ "$INIT_TYPE" = "systemd" ]; then
        journalctl -u ech-workers -f -n 20
    else
        echo "非服务模式运行，无法查看服务日志。"
    fi
}

# 加载/保存配置
load_conf() { [ -f "$CONF_FILE" ] && . "$CONF_FILE"; }
save_conf() {
    cat >"$CONF_FILE" <<EOF
BEST_IP="${BEST_IP}"
SERVER_ADDR="${SERVER_ADDR}"
LISTEN_ADDR="${LISTEN_ADDR}"
TOKEN="${TOKEN}"
DNS="${DNS}"
ECH_DOMAIN="${ECH_DOMAIN}"
ROUTING="${ROUTING}"
EOF
}

# 菜单
show_menu() {
    while true; do
        clear
        ensure_conf
        load_conf
        
        STATUS="未运行"
        if pgrep -f "ech-workers" >/dev/null; then STATUS="运行中"; fi
        
        ARCH_SHOW=$(get_arch)

        echo "=================================="
        echo "   ech-wk 通用管理脚本"
        echo "   系统: $OS_TYPE ($INIT_TYPE)"
        echo "   架构: $ARCH_SHOW"
        echo "   状态: $STATUS"
        echo "=================================="
        echo "1. 设置 优选IP    [$BEST_IP]"
        echo "2. 设置 服务地址  [$SERVER_ADDR]"
        echo "3. 设置 监听地址  [$LISTEN_ADDR]"
        echo "4. 设置 Token     [${TOKEN:0:6}***]"
        echo "5. 设置 分流模式  [$ROUTING]"
        echo "----------------------------------"
        echo "6. 启动 / 重启服务"
        echo "7. 停止服务"
        echo "8. 查看实时日志"
        echo "9. 退出"
        echo "=================================="
        printf "请输入选项: "
        read -r choice

        case "$choice" in
            1) printf "新优选IP: "; read -r BEST_IP; save_conf ;;
            2) printf "新服务地址: "; read -r SERVER_ADDR; save_conf ;;
            3) printf "新监听地址: "; read -r LISTEN_ADDR; save_conf ;;
            4) printf "新Token: "; read -r TOKEN; save_conf ;;
            5) 
                echo "1) global (全局)  2) bypass_cn (绕过CN)"
                printf "选择: "; read -r r_mode
                [ "$r_mode" = "2" ] && ROUTING="bypass_cn" || ROUTING="global"
                save_conf 
                ;;
            6) 
                ensure_binary
                ensure_init
                svc_restart
                echo "服务已重启..."
                sleep 2
                ;;
            7) 
                svc_stop
                echo "服务已停止"
                sleep 2
                ;;
            8) 
                svc_log
                ;;
            9) exit 0 ;;
            *) ;;
        esac
    done
}

# 入口
check_sys
show_menu
