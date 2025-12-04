#!/usr/bin/env bash
set -euo pipefail

# frp-panel one-click manager (master/server/client)
# install | update | uninstall | start | stop | restart | status | logs
# install-all | update-all | uninstall-all

REPO="VaalaCat/frp-panel"
BIN_NAME="frp-panel"
INSTALL_DIR="/usr/local/bin"
ETC_DIR="/etc/frp-panel"
DATA_DIR="/var/lib/frp-panel"
LOG_DIR="/var/log/frp-panel"

ROLES=("master" "server" "client")

# -------- helpers --------
color() { echo -e "\033[$1m$2\033[0m"; }
info() { color "32" "[INFO] $*"; }
warn() { color "33" "[WARN] $*"; }
err()  { color "31" "[ERR ] $*"; exit 1; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请用 root 运行（sudo bash $0 ...）"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os_arch() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7l" ;;
    armv6l) ARCH="armv6l" ;;
    riscv64) ARCH="riscv64" ;;
    *)
      err "不支持的架构: $ARCH"
      ;;
  esac

  case "$OS" in
    linux|darwin) ;;
    *) err "不支持的系统: $OS（脚本面向 Linux/macOS；systemd 仅 Linux）" ;;
  esac
}

latest_release_tag() {
  have_cmd curl || err "缺少 curl"
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"
  [[ -n "$TAG" ]] || err "获取最新版本失败（GitHub API）"
  echo "$TAG"
}

asset_name_for_role() {
  local role="$1"
  if [[ "$role" == "client" ]]; then
    echo "frp-panel-client-${OS}-${ARCH}"
  else
    echo "frp-panel-${OS}-${ARCH}"
  fi
}

download_release_asset() {
  local tag="$1"
  local asset="$2"
  local tmpdir="$3"
  local url="https://github.com/${REPO}/releases/download/${tag}/${asset}"

  info "下载 ${url}"
  curl -fL "$url" -o "${tmpdir}/${asset}" \
    || err "下载失败：${asset}（检查 Release 是否有该 OS/ARCH 资产）"
  chmod +x "${tmpdir}/${asset}"
}

ensure_dirs() {
  mkdir -p "$ETC_DIR" "$DATA_DIR" "$LOG_DIR"
}

svc_name_for_role() {
  local role="$1"
  echo "frp-panel-${role}"
}

write_systemd_unit() {
  local role="$1"
  local svc unit_file conf_file

  svc="$(svc_name_for_role "$role")"
  unit_file="/etc/systemd/system/${svc}.service"
  conf_file="${ETC_DIR}/${role}.env"

  if [[ ! -f "$conf_file" ]]; then
    cat > "$conf_file" <<EOF
# ${role} module env for frp-panel
# 在这里填面板生成的启动参数 / 鉴权信息
# 示例（master 必填）：
# APP_GLOBAL_SECRET=change_me
# MASTER_RPC_HOST=你的master公网IP
# MASTER_RPC_PORT=9001
# MASTER_API_PORT=9000
# MASTER_API_SCHEME=http
EOF
    info "生成默认配置：$conf_file"
  fi

  cat > "$unit_file" <<EOF
[Unit]
Description=frp-panel ${role}
After=network.target

[Service]
Type=simple
EnvironmentFile=${conf_file}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME} ${role}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  info "写入 systemd：$unit_file"
  systemctl daemon-reload
  systemctl enable "$svc" >/dev/null
}

install_role() {
  local role="$1"
  [[ "$role" =~ ^(master|server|client)$ ]] || err "role 必须是 master/server/client"

  detect_os_arch
  ensure_dirs

  local tag asset tmpdir
  tag="$(latest_release_tag)"
  asset="$(asset_name_for_role "$role")"
  tmpdir="$(mktemp -d)"

  download_release_asset "$tag" "$asset" "$tmpdir"
  install -m 755 "${tmpdir}/${asset}" "${INSTALL_DIR}/${BIN_NAME}"

  if [[ "$OS" == "linux" && have_cmd systemctl ]]; then
    write_systemd_unit "$role"
    systemctl restart "$(svc_name_for_role "$role")" || true
  else
    warn "非 Linux/systemd：已放置二进制到 ${INSTALL_DIR}/${BIN_NAME}"
    warn "请手工运行：${BIN_NAME} ${role}"
  fi

  rm -rf "$tmpdir"
  info "安装完成：${role} @ ${tag}"
}

update_role() {
  local role="$1"
  [[ "$role" =~ ^(master|server|client)$ ]] || err "role 必须是 master/server/client"

  detect_os_arch
  ensure_dirs

  local tag asset tmpdir
  tag="$(latest_release_tag)"
  asset="$(asset_name_for_role "$role")"
  tmpdir="$(mktemp -d)"

  download_release_asset "$tag" "$asset" "$tmpdir"
  install -m 755 "${tmpdir}/${asset}" "${INSTALL_DIR}/${BIN_NAME}"

  if [[ "$OS" == "linux" && have_cmd systemctl ]]; then
    systemctl restart "$(svc_name_for_role "$role")" || true
  fi

  rm -rf "$tmpdir"
  info "更新完成：${role} -> ${tag}"
}

uninstall_role() {
  local role="$1"
  [[ "$role" =~ ^(master|server|client)$ ]] || err "role 必须是 master/server/client"
  detect_os_arch

  if [[ "$OS" == "linux" && have_cmd systemctl ]]; then
    local svc
    svc="$(svc_name_for_role "$role")"
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${svc}.service"
    systemctl daemon-reload
    info "systemd 已删除：$svc"
  fi

  rm -f "${INSTALL_DIR}/${BIN_NAME}"
  info "二进制已删除：${INSTALL_DIR}/${BIN_NAME}"

  warn "配置/数据保留（防误删）："
  warn "  配置：${ETC_DIR}/${role}.env"
  warn "  数据：${DATA_DIR}"
  warn "  日志：${LOG_DIR}"
}

svc_ctl() {
  local action="$1" role="$2"
  [[ "$role" =~ ^(master|server|client)$ ]] || err "role 必须是 master/server/client"

  if [[ "$OS" != "linux" || ! $(have_cmd systemctl && echo yes) ]]; then
    err "该操作只支持 Linux systemd"
  fi
  systemctl "$action" "$(svc_name_for_role "$role")"
}

logs_role() {
  local role="$1"
  [[ "$role" =~ ^(master|server|client)$ ]] || err "role 必须是 master/server/client"
  journalctl -u "$(svc_name_for_role "$role")" -e --no-pager
}

install_all() { for r in "${ROLES[@]}"; do install_role "$r"; done; }
update_all()  { for r in "${ROLES[@]}"; do update_role  "$r"; done; }
uninstall_all(){ for r in "${ROLES[@]}"; do uninstall_role "$r"; done; }

usage() {
  cat <<EOF
用法：
  sudo bash $0 install      master|server|client
  sudo bash $0 update       master|server|client
  sudo bash $0 uninstall    master|server|client
  sudo bash $0 start        master|server|client
  sudo bash $0 stop         master|server|client
  sudo bash $0 restart      master|server|client
  sudo bash $0 status       master|server|client
  sudo bash $0 logs         master|server|client

三端一键：
  sudo bash $0 install-all
  sudo bash $0 update-all
  sudo bash $0 uninstall-all

示例：
  sudo bash $0 install-all
  sudo bash $0 install master
EOF
}

main() {
  need_root
  local cmd="${1:-}"
  local role="${2:-}"

  [[ -n "$cmd" ]] || { usage; exit 1; }

  case "$cmd" in
    install)       install_role "$role" ;;
    update)        update_role "$role" ;;
    uninstall)     uninstall_role "$role" ;;
    install-all)   install_all ;;
    update-all)    update_all ;;
    uninstall-all) uninstall_all ;;

    start|stop|restart|status)
      detect_os_arch
      svc_ctl "$cmd" "$role"
      ;;
    logs)
      detect_os_arch
      logs_role "$role"
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
