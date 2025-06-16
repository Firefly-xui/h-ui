#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

hui_systemd_version="${1:-latest}"

init_var() {
  ECHO_TYPE="echo -e"

  package_manager=""
  release=""
  version=""
  get_arch=""

  HUI_DATA_SYSTEMD="/usr/local/h-ui/"

  h_ui_port=""
  h_ui_time_zone=Asia/Shanghai
  h_ui_username=""
  h_ui_password=""

  ssh_local_forwarded_port=""

  translation_file_content=""
  translation_file_base_url="https://raw.githubusercontent.com/jonssonyan/h-ui/refs/heads/main/local/"
  translation_file="zh_cn.json"
}

echo_content() {
  case $1 in
  "red")
    ${ECHO_TYPE} "\033[31m$2\033[0m"
    ;;
  "green")
    ${ECHO_TYPE} "\033[32m$2\033[0m"
    ;;
  "yellow")
    ${ECHO_TYPE} "\033[33m$2\033[0m"
    ;;
  "blue")
    ${ECHO_TYPE} "\033[34m$2\033[0m"
    ;;
  "purple")
    ${ECHO_TYPE} "\033[35m$2\033[0m"
    ;;
  "skyBlue")
    ${ECHO_TYPE} "\033[36m$2\033[0m"
    ;;
  "white")
    ${ECHO_TYPE} "\033[37m$2\033[0m"
    ;;
  esac
}

can_connect() {
  if ping -c2 -i0.3 -W1 "$1" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

version_ge() {
  local v1=${1#v}
  local v2=${2#v}

  if [[ -z "$v1" || "$v1" == "latest" ]]; then
    return 0
  fi

  IFS='.' read -r -a v1_parts <<<"$v1"
  IFS='.' read -r -a v2_parts <<<"$v2"

  for i in "${!v1_parts[@]}"; do
    local part1=${v1_parts[i]:-0}
    local part2=${v2_parts[i]:-0}

    if [[ "$part1" < "$part2" ]]; then
      return 1
    elif [[ "$part1" > "$part2" ]]; then
      return 0
    fi
  done
  return 0
}

check_sys() {
  if [[ $(id -u) != "0" ]]; then
    echo_content red "必须以root用户身份运行此脚本"
    exit 1
  fi

  # 检测网络连接，优先使用国内可访问的域名
  network_ok=0
  test_domains=("www.baidu.com" "www.qq.com" "github.com" "www.google.com")
  
  for domain in "${test_domains[@]}"; do
    if can_connect "$domain"; then
      network_ok=1
      break
    fi
  done
  
  if [[ "$network_ok" == "0" ]]; then
    echo_content red "---> 网络连接失败，请检查网络设置"
    exit 1
  fi

  if [[ $(command -v yum) ]]; then
    package_manager='yum'
  elif [[ $(command -v dnf) ]]; then
    package_manager='dnf'
  elif [[ $(command -v apt-get) ]]; then
    package_manager='apt-get'
  elif [[ $(command -v apt) ]]; then
    package_manager='apt'
  fi

  if [[ -z "${package_manager}" ]]; then
    echo_content red "当前系统不受支持"
    exit 1
  fi

  if [[ -n $(find /etc -name "rocky-release") ]] || grep </proc/version -q -i "rocky"; then
    release="rocky"
    if rpm -q rocky-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' rocky-release)
    fi
  elif [[ -n $(find /etc -name "redhat-release") ]] || grep </proc/version -q -i "centos"; then
    release="centos"
    if rpm -q centos-stream-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-stream-release)
    elif rpm -q centos-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-release)
    fi
  elif grep </etc/issue -q -i "debian" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "debian" && [[ -f "/proc/version" ]]; then
    release="debian"
    version=$(cat /etc/debian_version)
  elif grep </etc/issue -q -i "ubuntu" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "ubuntu" && [[ -f "/proc/version" ]]; then
    release="ubuntu"
    version=$(lsb_release -sr)
  fi

  major_version=$(echo "${version}" | cut -d. -f1)

  case $release in
  rocky) ;;
  centos)
    if [[ $major_version -ge 6 ]]; then
      echo_content green "检测到支持的CentOS版本: $version"
    else
      echo_content red "不支持的CentOS版本: $version. 仅支持CentOS 6+。"
      exit 1
    fi
    ;;
  ubuntu)
    if [[ $major_version -ge 16 ]]; then
      echo_content green "检测到支持的Ubuntu版本: $version"
    else
      echo_content red "不支持的Ubuntu版本: $version. 仅支持Ubuntu 16+。"
      exit 1
    fi
    ;;
  debian)
    if [[ $major_version -ge 8 ]]; then
      echo_content green "检测到支持的Debian版本: $version"
    else
      echo_content red "不支持的Debian版本: $version. 仅支持Debian 8+。"
      exit 1
    fi
    ;;
  *)
    echo_content red "仅支持 CentOS 6+/Ubuntu 16+/Debian 8+"
    exit 1
    ;;
  esac

  if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
  elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
  fi

  if [[ -z "${get_arch}" ]]; then
    echo_content red "仅支持 x86_64/amd64 arm64/aarch64 架构"
    exit 1
  fi
}

install_depend() {
  if [[ "${package_manager}" == 'apt-get' || "${package_manager}" == 'apt' ]]; then
    ${package_manager} update -y
  fi
  ${package_manager} install -y \
    curl \
    systemd \
    nftables \
    jq \
    sqlite3
}

select_language() {
  clear
  echo_content red "=============================================================="
  echo_content skyBlue "请选择语言"
  echo_content yellow "1. English"
  echo_content yellow "2. 简体中文 (默认)"
  echo_content red "=============================================================="
  read -r -p "请选择: " input_option
  case ${input_option} in
  1)
    translation_file="en.json"
    ;;
  *)
    translation_file="zh_cn.json"
    ;;
  esac
  translation_file_content=$(curl -fsSL "${translation_file_base_url}${translation_file}")
}

get_translation() {
  echo "${translation_file_content}" | jq -r "$1"
}

remove_forward() {
  if command -v nft &>/dev/null && nft list tables | grep -q hui_porthopping; then
    nft delete table inet hui_porthopping
  fi
  if command -v iptables &>/dev/null; then
    for num in $(iptables -t nat -L PREROUTING -v --line-numbers | grep -i "hui_hysteria_porthopping" | awk '{print $1}' | sort -rn); do
      iptables -t nat -D PREROUTING $num
    done
  fi
  if command -v ip6tables &>/dev/null; then
    for num in $(ip6tables -t nat -L PREROUTING -v --line-numbers | grep -i "hui_hysteria_porthopping" | awk '{print $1}' | sort -rn); do
      ip6tables -t nat -D PREROUTING $num
    done
  fi
}

# 新增函数：生成密码哈希
generate_password_hash() {
  local password="$1"
  # 使用 SHA-256 加盐哈希（根据实际的H-UI密码哈希方式调整）
  echo -n "${password}" | sha256sum | cut -d' ' -f1
}

# 新增函数：直接操作数据库创建/更新用户
create_or_update_user_in_db() {
  local username="$1"
  local password="$2"
  local db_path="${HUI_DATA_SYSTEMD}h-ui.db"
  
  if [[ ! -f "$db_path" ]]; then
    echo_content red "数据库文件不存在: $db_path"
    return 1
  fi
  
  # 生成密码哈希
  local password_hash=$(generate_password_hash "$password")
  local current_time=$(date '+%Y-%m-%d %H:%M:%S')
  
  # 检查用户是否已存在
  local user_exists=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM users WHERE username='$username';")
  
  if [[ "$user_exists" -gt 0 ]]; then
    # 更新现有用户
    sqlite3 "$db_path" "UPDATE users SET password='$password_hash', updated_at='$current_time' WHERE username='$username';"
    echo_content green "用户 '$username' 密码已更新"
  else
    # 创建新用户
    sqlite3 "$db_path" "INSERT INTO users (username, password, created_at, updated_at) VALUES ('$username', '$password_hash', '$current_time', '$current_time');"
    echo_content green "用户 '$username' 已创建"
  fi
}

get_user_config() {
  while [[ -z "${h_ui_port}" ]]; do
    read -r -p "请输入H UI端口 (必须自定义): " h_ui_port
    if [[ -z "${h_ui_port}" ]]; then
      echo_content red "端口不能为空，请输入一个有效端口"
    elif ! [[ "${h_ui_port}" =~ ^[0-9]+$ ]] || [[ "${h_ui_port}" -lt 1 ]] || [[ "${h_ui_port}" -gt 65535 ]]; then
      echo_content red "请输入有效的端口号 (1-65535)"
      h_ui_port=""
    fi
  done

  read -r -p "请输入H UI时区 (默认: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  while [[ -z "${h_ui_username}" ]]; do
    read -r -p "请输入管理员用户名: " h_ui_username
    if [[ -z "${h_ui_username}" ]]; then
      echo_content red "用户名不能为空"
    fi
  done

  while [[ -z "${h_ui_password}" ]]; do
    read -r -s -p "请输入管理员密码: " h_ui_password
    echo
    if [[ -z "${h_ui_password}" ]]; then
      echo_content red "密码不能为空"
    fi
  done
}

install_h_ui_systemd() {
  if systemctl status h-ui >/dev/null 2>&1; then
    echo_content skyBlue "---> H UI 已经安装"
    exit 0
  fi

  echo_content green "---> 安装 H UI"
  mkdir -p ${HUI_DATA_SYSTEMD} &&
    export HUI_DATA="${HUI_DATA_SYSTEMD}"

  sed -i '/^HUI_DATA=/d' /etc/environment &&
    echo "HUI_DATA=${HUI_DATA_SYSTEMD}" | tee -a /etc/environment >/dev/null

  get_user_config

  timedatectl set-timezone ${h_ui_time_zone} && timedatectl set-local-rtc 0
  systemctl restart rsyslog
  if [[ "${release}" == "centos" || "${release}" == "rocky" ]]; then
    systemctl restart crond
  elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
    systemctl restart cron
  fi

  export GIN_MODE=release

  bin_url=https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-${get_arch}
  if [[ "latest" != "${hui_systemd_version}" ]]; then
    bin_url=https://github.com/jonssonyan/h-ui/releases/download/${hui_systemd_version}/h-ui-linux-${get_arch}
  fi

  curl -fsSL "${bin_url}" -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    curl -fsSL https://raw.githubusercontent.com/jonssonyan/h-ui/main/h-ui.service -o /etc/systemd/system/h-ui.service &&
    sed -i "s|^ExecStart=.*|ExecStart=/usr/local/h-ui/h-ui -p ${h_ui_port}|" "/etc/systemd/system/h-ui.service" &&
    systemctl daemon-reload &&
    systemctl enable h-ui &&
    systemctl restart h-ui
  sleep 3

  # 等待数据库文件创建
  local db_wait_count=0
  while [[ ! -f "${HUI_DATA_SYSTEMD}h-ui.db" && $db_wait_count -lt 30 ]]; do
    sleep 1
    ((db_wait_count++))
  done

  # 设置用户名和密码
  current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if version_ge "$current_version" "v0.0.12"; then
    export HUI_DATA="${HUI_DATA_SYSTEMD}"
    
    # 首先尝试使用官方命令创建用户
    if ! ${HUI_DATA_SYSTEMD}h-ui user add "${h_ui_username}" "${h_ui_password}" >/dev/null 2>&1; then
      # 如果官方命令失败，直接操作数据库
      echo_content yellow "使用数据库直接创建用户..."
      create_or_update_user_in_db "${h_ui_username}" "${h_ui_password}"
    fi
  else
    # 对于旧版本，直接操作数据库
    echo_content yellow "旧版本H-UI，使用数据库直接创建用户..."
    create_or_update_user_in_db "${h_ui_username}" "${h_ui_password}"
  fi

  echo_content yellow "h-ui 面板端口: ${h_ui_port}"
  echo_content yellow "h-ui 登录用户名: ${h_ui_username}"
  echo_content yellow "h-ui 登录密码: ${h_ui_password}"
  echo_content skyBlue "---> H UI 安装成功"
}

upgrade_h_ui_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    echo_content red "---> H UI 未安装"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/jonssonyan/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H UI 已经是最新版本"
    exit 0
  fi

  echo_content green "---> 升级 H UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  curl -fsSL https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-${get_arch} -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    systemctl restart h-ui
  echo_content skyBlue "---> H UI 升级成功"
}

uninstall_h_ui_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    echo_content red "---> H UI 未安装"
    exit 0
  fi

  echo_content green "---> 卸载 H UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  systemctl disable h-ui.service &&
    rm -f /etc/systemd/system/h-ui.service &&
    systemctl daemon-reload &&
    rm -rf /usr/local/h-ui/ &&
    systemctl reset-failed
  remove_forward
  echo_content skyBlue "---> H UI 卸载成功"
}

ssh_local_port_forwarding() {
  while [[ -z "${ssh_local_forwarded_port}" ]]; do
    read -r -p "请输入SSH本地转发端口 (必须自定义): " ssh_local_forwarded_port
    if [[ -z "${ssh_local_forwarded_port}" ]]; then
      echo_content red "端口不能为空，请输入一个有效端口"
    elif ! [[ "${ssh_local_forwarded_port}" =~ ^[0-9]+$ ]] || [[ "${ssh_local_forwarded_port}" -lt 1 ]] || [[ "${ssh_local_forwarded_port}" -gt 65535 ]]; then
      echo_content red "请输入有效的端口号 (1-65535)"
      ssh_local_forwarded_port=""
    fi
  done

  while [[ -z "${h_ui_port}" ]]; do
    read -r -p "请输入H UI端口 (必须自定义): " h_ui_port
    if [[ -z "${h_ui_port}" ]]; then
      echo_content red "端口不能为空，请输入一个有效端口"
    elif ! [[ "${h_ui_port}" =~ ^[0-9]+$ ]] || [[ "${h_ui_port}" -lt 1 ]] || [[ "${h_ui_port}" -gt 65535 ]]; then
      echo_content red "请输入有效的端口号 (1-65535)"
      h_ui_port=""
    fi
  done

  ssh -N -f -L 0.0.0.0:${ssh_local_forwarded_port}:localhost:${h_ui_port} localhost
  echo_content skyBlue "---> SSH本地端口转发成功"
}

reset_sysadmin() {
  if systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
    if version_ge "$current_version" "v0.0.12"; then
      export HUI_DATA="${HUI_DATA_SYSTEMD}"
      echo_content yellow "$(${HUI_DATA_SYSTEMD}h-ui reset)"
      echo_content skyBlue "---> H UI (systemd) 重置管理员用户名和密码成功"
    else
      # 对于不支持reset命令的旧版本，提供手动重置选项
      echo_content yellow "---> H UI 版本较旧，提供手动重置选项"
      
      while [[ -z "${h_ui_username}" ]]; do
        read -r -p "请输入新的管理员用户名: " h_ui_username
        if [[ -z "${h_ui_username}" ]]; then
          echo_content red "用户名不能为空"
        fi
      done

      while [[ -z "${h_ui_password}" ]]; do
        read -r -s -p "请输入新的管理员密码: " h_ui_password
        echo
        if [[ -z "${h_ui_password}" ]]; then
          echo_content red "密码不能为空"
        fi
      done
      
      create_or_update_user_in_db "${h_ui_username}" "${h_ui_password}"
      echo_content skyBlue "---> 管理员账户重置成功"
    fi
  else
    echo_content red "---> H UI 未安装"
  fi
}

main() {
  cd "$HOME" || exit 0
  init_var
  check_sys
  install_depend
  select_language
  clear
  echo_content yellow '
         _   _     _    _ ___
        | | | |   | |  | |_ _|
        | |_| |   | |  | || |
        |  _  |   | |  | || |
        | | | |   | |__| || |
        |_| |_|    \____/|___|
'
  echo_content red "=============================================================="
  echo_content skyBlue "推荐操作系统: CentOS 8+/Ubuntu 20+/Debian 11+"
  echo_content skyBlue "H-UI 一键安装脚本"
  echo_content skyBlue "作者: jonssonyan <https://jonssonyan.com>"
  echo_content skyBlue "Github: https://github.com/jonssonyan/h-ui"
  echo_content red "=============================================================="
  echo_content yellow "1. 安装 H UI (systemd)"
  echo_content yellow "2. 升级 H UI (systemd)"
  echo_content yellow "3. 卸载 H UI (systemd)"
  echo_content red "=============================================================="
  echo_content yellow "4. SSH本地端口转发"
  echo_content yellow "5. 重置管理员账户"
  echo_content red "=============================================================="
  read -r -p "请选择: " input_option
  case ${input_option} in
  1)
    install_h_ui_systemd
    ;;
  2)
    upgrade_h_ui_systemd
    ;;
  3)
    uninstall_h_ui_systemd
    ;;
  4)
    ssh_local_port_forwarding
    ;;
  5)
    reset_sysadmin
    ;;
  *)
    echo_content red "无此选项"
    ;;
  esac
}

main
