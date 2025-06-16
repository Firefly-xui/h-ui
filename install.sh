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

  # 直接使用简体中文，不需要选择语言
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

# 新增：等待数据库文件创建的函数
wait_for_database() {
  local db_path="$1"
  local max_wait=60  # 最大等待60秒
  local count=0
  
  echo_content yellow "等待数据库初始化..."
  
  while [[ ! -f "${db_path}" && $count -lt $max_wait ]]; do
    sleep 1
    ((count++))
    echo -n "."
  done
  echo
  
  if [[ -f "${db_path}" ]]; then
    return 0
  else
    echo_content red "数据库文件未创建: ${db_path}"
    return 1
  fi
}

# 修改后的数据库更新函数
update_database_credentials() {
  local db_path="${HUI_DB_PATH}"
  local username="$1"
  local password="$2"
  
  # 等待数据库文件创建
  if ! wait_for_database "${db_path}"; then
    return 1
  fi
  
  # 计算密码哈希
  local pass_hash=$(calculate_password_hash "${username}" "${password}")
  local con_pass="${username}.${password}"
  local current_time=$(date '+%Y-%m-%d %H:%M:%S')
  local expire_time=253370736000000
  
  # 更新数据库中的管理员账户并锁定
  if sqlite3 "${db_path}" <<EOF
BEGIN TRANSACTION;
UPDATE account SET 
  username = '${username}',
  pass = '${pass_hash}',
  con_pass = '${con_pass}',
  update_time = '${current_time}',
  quota = -1,
  download = 0,
  upload = 0,
  expire_time = ${expire_time},
  role = 'admin',
  deleted = 0
WHERE id = 1;
COMMIT;
EOF
  then
    echo_content green "数据库凭据更新成功"
    return 0
  else
    echo_content red "数据库凭据更新失败"
    return 1
  fi
}

# 修改安装函数
install_h_ui_systemd() {
  if systemctl status h-ui >/dev/null 2>&1; then
    echo_content skyBlue "---> H UI 已经安装，正在重新配置用户凭据"
    
    get_user_config
    
    if update_database_credentials "${h_ui_username}" "${h_ui_password}"; then
      systemctl restart h-ui
      sleep 3
      echo_content yellow "=========================================="
      echo_content yellow "h-ui 面板端口: $(systemctl show h-ui --property=ExecStart | grep -oP '\-p \K[0-9]+')"
      echo_content yellow "h-ui 登录用户名: ${h_ui_username}"
      echo_content yellow "h-ui 登录密码: ${h_ui_password}"
      echo_content yellow "=========================================="
      echo_content skyBlue "---> H UI 用户凭据更新成功"
    else
      echo_content red "用户凭据更新失败"
    fi
    return 0
  fi

  echo_content green "---> 安装 H UI"
  mkdir -p ${HUI_DATA_SYSTEMD} &&
    export HUI_DATA="${HUI_DATA_SYSTEMD}"

  sed -i '/^HUI_DATA=/d' /etc/environment &&
    echo "HUI_DATA=${HUI_DATA_SYSTEMD}" | tee -a /etc/environment >/dev/null

  get_user_config

  # 这些服务可能不存在，忽略错误
  timedatectl set-timezone ${h_ui_time_zone} && timedatectl set-local-rtc 0
  systemctl restart rsyslog 2>/dev/null || true
  if [[ "${release}" == "centos" || "${release}" == "rocky" ]]; then
    systemctl restart crond 2>/dev/null || true
  elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
    systemctl restart cron 2>/dev/null || true
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
    systemctl start h-ui

  # 检查服务状态
  if systemctl is-active --quiet h-ui; then
    echo_content green "H UI服务启动成功"
    
    # 等待并更新数据库凭据
    echo_content yellow "正在初始化数据库..."
    if update_database_credentials "${h_ui_username}" "${h_ui_password}"; then
      # 重启服务以应用更改
      systemctl restart h-ui
      sleep 3
      
      if systemctl is-active --quiet h-ui; then
        echo_content green "安装完成，服务运行正常"
      else
        echo_content yellow "警告: 服务重启后状态异常，但安装已完成"
      fi
    else
      echo_content yellow "警告: 凭据更新失败，请稍后使用选项5重置管理员账户"
    fi
  else
    echo_content red "H UI服务启动失败"
    systemctl status h-ui
    exit 1
  fi

  echo_content yellow "=========================================="
  echo_content yellow "h-ui 面板端口: ${h_ui_port}"
  echo_content yellow "h-ui 登录用户名: ${h_ui_username}"
  echo_content yellow "h-ui 登录密码: ${h_ui_password}"
  echo_content yellow "=========================================="
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
    local db_path="${HUI_DATA_SYSTEMD}h-ui.db"
    
    if [[ ! -f "${db_path}" ]]; then
      echo_content red "---> 数据库文件未找到"
      exit 1
    fi
    
    echo_content yellow "重置管理员账户..."
    
    # 生成新的随机密码
    local new_password=$(openssl rand -base64 12)
    local new_username="sysadmin"
    
    if update_database_credentials "${new_username}" "${new_password}"; then
      systemctl restart h-ui
      sleep 3
      echo_content yellow "=========================================="
      echo_content yellow "新管理员用户名: ${new_username}"
      echo_content yellow "新管理员密码: ${new_password}"
      echo_content yellow "=========================================="
      echo_content skyBlue "---> H UI 重置管理员用户名和密码成功"
    else
      echo_content red "---> 重置失败"
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
