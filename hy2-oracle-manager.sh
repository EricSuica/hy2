#!/usr/bin/env bash
# HY2 Oracle Ubuntu installer + private CLI manager
# Requires Ubuntu/Debian with systemd, apt, and root/sudo privileges.
set -Eeuo pipefail
umask 077

APP_DIR=/etc/hysteria
CFG="$APP_DIR/config.yaml"
STATE="$APP_DIR/hy2-manager.env"
CERT="$APP_DIR/server.crt"
KEY="$APP_DIR/server.key"
BACKUPS="$APP_DIR/hy2-backups"
COMMAND=/usr/local/bin/hy2
FW_TAG=hy2-manager

say() { printf '\n\033[1;36m[HY2]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[注意]\033[0m %s\n' "$*" >&2; }
fail() { printf '\n\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
ask_yes() {
  local a
  read -r -p "$1 [y/N]: " a || return 1
  [[ "$a" == y || "$a" == Y || "$a" == yes || "$a" == YES ]]
}

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
[[ -r /etc/os-release ]] || fail '没有识别到 Linux 发行版。'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu || "${ID:-}" == debian || "${ID_LIKE:-}" == *debian* ]] || fail '此脚本只面向 Ubuntu/Debian。'
command -v systemctl >/dev/null 2>&1 || fail '需要 systemd。'

valid_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    sys.exit(0 if isinstance(ip, ipaddress.IPv4Address) and ip.is_global else 1)
except ValueError:
    sys.exit(1)
PY
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

load_state() {
  [[ -r "$STATE" ]] || fail '尚未由本脚本管理：请使用 bash hy2-oracle-manager.sh 安装。'
  # Manager state is root-owned, mode 600, and only this script writes it.
  # shellcheck disable=SC1090
  source "$STATE"
  : "${SERVER_IP:?}" "${PORT:?}" "${AUTH:?}" "${OBFS:?}"
}

save_state() {
  local temp
  temp=$(mktemp "$APP_DIR/.state.XXXXXX")
  {
    printf 'SERVER_IP=%q\n' "$SERVER_IP"
    printf 'PORT=%q\n' "$PORT"
    printf 'AUTH=%q\n' "$AUTH"
    printf 'OBFS=%q\n' "$OBFS"
  } > "$temp"
  install -o root -g root -m 600 "$temp" "$STATE"
  rm -f "$temp"
}

create_cert() {
  local tkey tcrt
  tkey=$(mktemp "$APP_DIR/.key.XXXXXX")
  tcrt=$(mktemp "$APP_DIR/.crt.XXXXXX")
  if ! openssl req -x509 -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -sha256 -days 825 \
    -keyout "$tkey" -out "$tcrt" \
    -subj "/CN=$SERVER_IP" \
    -addext "subjectAltName=IP:$SERVER_IP" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1; then
      rm -f "$tkey" "$tcrt"
      fail '生成证书失败。'
  fi
  install -o root -g hysteria -m 640 "$tkey" "$KEY"
  install -o root -g hysteria -m 644 "$tcrt" "$CERT"
  rm -f "$tkey" "$tcrt"
}

make_config() {
  local target=$1
  cat > "$target" <<EOF
listen: 0.0.0.0:$PORT

tls:
  cert: $CERT
  key: $KEY

auth:
  type: password
  password: "$AUTH"

obfs:
  type: salamander
  salamander:
    password: "$OBFS"
EOF
}

# Only script-owned rules are removed on changes; Oracle defaults are left alone.
firewall_has() {
  iptables -C INPUT -p udp --dport "$1" \
    -m comment --comment "$FW_TAG" -j ACCEPT >/dev/null 2>&1
}
firewall_add() {
  local p=$1
  if ! firewall_has "$p"; then
    iptables -I INPUT 1 -p udp --dport "$p" \
      -m comment --comment "$FW_TAG" -j ACCEPT
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$p/udp" comment "$FW_TAG" >/dev/null
  fi
}
firewall_remove() {
  local p=$1
  if firewall_has "$p"; then
    iptables -D INPUT -p udp --dport "$p" \
      -m comment --comment "$FW_TAG" -j ACCEPT || true
  fi
  # Do not delete UFW rules automatically: an existing user rule might be affected.
  # If UFW is active, old UFW allow rules must be reviewed manually after a port change.
}
firewall_save() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null || warn '无法持久化 iptables，请检查 netfilter-persistent。'
    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
  else
    warn '未检测到 netfilter-persistent；重启后 iptables 规则可能丢失。'
  fi
}

apply_config() {
  local tmp old had_old=0
  tmp=$(mktemp "$APP_DIR/.config.new.XXXXXX")
  old=$(mktemp "$APP_DIR/.config.old.XXXXXX")
  make_config "$tmp"
  if [[ -f "$CFG" ]]; then
    cp -p "$CFG" "$old"
    had_old=1
  fi
  install -o root -g hysteria -m 640 "$tmp" "$CFG"
  rm -f "$tmp"
  if ! systemctl enable --now hysteria-server >/dev/null 2>&1 \
      || ! systemctl restart hysteria-server >/dev/null 2>&1 \
      || ! systemctl is-active --quiet hysteria-server; then
    warn '新配置启动失败，正在恢复上一份配置。'
    journalctl -u hysteria-server -n 15 --no-pager >&2 || true
    if (( had_old )); then
      cp -p "$old" "$CFG"
      systemctl restart hysteria-server >/dev/null 2>&1 || true
    else
      rm -f "$CFG"
    fi
    rm -f "$old"
    return 1
  fi
  rm -f "$old"
  return 0
}

pin_sha256() {
  openssl x509 -in "$CERT" -noout -fingerprint -sha256 \
    | sed -E 's/^[^=]+=//' | tr -d ':' | tr '[:upper:]' '[:lower:]'
}
make_uri() {
  local mode=$1 pin
  pin=$(pin_sha256)
  python3 - "$mode" "$SERVER_IP" "$PORT" "$AUTH" "$OBFS" "$pin" <<'PY'
import sys
from urllib.parse import quote, urlencode
mode, ip, port, auth, obfs, pin = sys.argv[1:]
# Official Hysteria clients often need insecure=1 WITH a valid pinSHA256.
# Android clients on newer Xray may need insecure=0 WITH the same pin.
params = {
    "obfs": "salamander",
    "obfs-password": obfs,
    "pinSHA256": pin,
    "insecure": "1" if mode == "ios" else "0",
}
print(f"hysteria2://{quote(auth, safe='')}@{ip}:{port}/?{urlencode(params)}#Oracle-HY2")
PY
}

qr_show() {
  local mode=${1:-ios} uri
  [[ "$mode" == ios || "$mode" == android ]] || fail '用法：hy2 qr ios 或 hy2 qr android'
  load_state
  uri=$(make_uri "$mode")
  printf '\n\033[1;32m=== %s 二维码 ===\033[0m\n' "$([[ $mode == ios ]] && echo 'Shadowrocket / 官方 Hysteria' || echo 'v2rayNG / Xray')"
  printf '节点：%s:%s UDP | Salamander | 证书 SHA-256 固定\n' "$SERVER_IP" "$PORT"
  printf '二维码包含完整凭据；请勿公开截图。\n\n'
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -t ANSIUTF8 -l L -m 1
  else
    warn '缺少 qrencode，不能在终端显示二维码。'
  fi
  printf '\n是否输出可复制的完整链接？[y/N]: '
  local a
  read -r a || a=''
  if [[ "$a" == y || "$a" == Y ]]; then
    printf '\n%s\n' "$uri"
  fi
  if [[ "$mode" == android ]]; then
    warn 'v2rayNG 导入后请确认 pinSHA256 被识别，且未单独跳过证书校验；新版内核可能存在兼容性差异。'
  else
    warn '仅在客户端确实验证 pinSHA256 时，才能安全地使用 insecure=1。'
  fi
}

show_info() {
  load_state
  say '当前 Hysteria 2 配置'
  printf '公网 IP      : %s\n' "$SERVER_IP"
  printf '协议/端口    : QUIC / UDP %s\n' "$PORT"
  printf '混淆方式     : Salamander\n'
  printf '登录密码     : （隐藏，菜单 4 可查看）\n'
  printf '混淆密码     : （隐藏，菜单 4 可查看）\n'
  printf '服务状态     : %s\n' "$(systemctl is-active hysteria-server 2>/dev/null || echo unknown)"
  printf '开机启动     : %s\n' "$(systemctl is-enabled hysteria-server 2>/dev/null || echo unknown)"
  printf '证书有效期至 : '
  openssl x509 -in "$CERT" -noout -enddate 2>/dev/null || echo '读取失败'
  printf '证书指纹     : %s\n' "$(pin_sha256)"
  printf '配置文件     : %s\n' "$CFG"
  printf '本地规则     : '
  if firewall_has "$PORT"; then echo 'HY2 已放行'; else echo '未检测到脚本管理的规则'; fi
  printf '\n提醒：Oracle VCN/NSG 的 UDP %s 入站规则需要在控制台单独检查。\n' "$PORT"
}

reveal_config() {
  load_state
  warn '下面将直接显示密码等敏感信息，周围有人或正在录屏时不要操作。'
  if ask_yes '确定显示完整配置吗？'; then
    printf '\n--- %s ---\n' "$CFG"
    cat "$CFG"
    printf '\n--- 证书指纹 ---\n'
    pin_sha256; printf '\n'
  fi
}

rotate_auth() {
  load_state
  warn '重置登录密码后，所有旧客户端节点都需要重新导入。'
  ask_yes '确认生成新的认证密码？' || return 0
  local old=$AUTH
  AUTH=$(openssl rand -hex 24)
  if apply_config; then save_state; say '认证密码已更新。请重新扫描二维码。'; else AUTH=$old; warn '修改失败，旧密码仍有效。'; fi
}
rotate_obfs() {
  load_state
  warn '重置混淆密码后，所有旧客户端节点都需要重新导入。'
  ask_yes '确认生成新的混淆密码？' || return 0
  local old=$OBFS
  OBFS=$(openssl rand -hex 24)
  if apply_config; then save_state; say '混淆密码已更新。请重新扫描二维码。'; else OBFS=$old; warn '修改失败，旧密码仍有效。'; fi
}

change_port() {
  load_state
  local new old=$PORT
  read -r -p "新 UDP 端口（当前 $old）：" new || return 0
  if ! valid_port "$new"; then warn '端口必须在 1-65535 之间。'; return 0; fi
  new=$((10#$new))
  [[ "$new" != "$PORT" ]] || { say '端口未变化。'; return 0; }
  warn "请先在 Oracle 云端安全列表或 NSG 开放 UDP $new，否则手机会断连。"
  ask_yes '确认修改端口？' || return 0
  firewall_add "$new"
  PORT=$new
  if apply_config; then
    save_state
    firewall_remove "$old"
    firewall_save
    say "端口已切换为 UDP $PORT，旧客户端需要重新导入。"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
      warn "UFW 已启用，请手动检查并删除不需要的旧 UDP $old 放行规则。"
    fi
  else
    PORT=$old
    firewall_remove "$new"
    firewall_save
    warn '端口更改失败，已回滚。'
  fi
}

change_ip() {
  load_state
  local new old=$SERVER_IP
  read -r -p "新公网 IPv4（当前 $old）：" new || return 0
  if ! valid_ipv4 "$new"; then warn '请输入有效的全球可路由公网 IPv4。'; return 0; fi
  [[ "$new" != "$old" ]] || { say 'IP 未变化。'; return 0; }
  warn '修改 IP 会重新签发自签证书并改变指纹；旧客户端必须重新导入。'
  ask_yes '确认修改 IP 并重新生成证书？' || return 0
  local keybak certbak
  keybak=$(mktemp "$APP_DIR/.oldkey.XXXXXX")
  certbak=$(mktemp "$APP_DIR/.oldcert.XXXXXX")
  cp -p "$KEY" "$keybak"; cp -p "$CERT" "$certbak"
  SERVER_IP=$new
  create_cert
  if apply_config; then
    save_state
    rm -f "$keybak" "$certbak"
    say 'IP 和证书已经更新。请重新扫描二维码。'
  else
    SERVER_IP=$old
    cp -p "$keybak" "$KEY"; cp -p "$certbak" "$CERT"
    systemctl restart hysteria-server >/dev/null 2>&1 || true
    rm -f "$keybak" "$certbak"
    warn '更新失败，已恢复原 IP 和证书。'
  fi
}

rotate_cert() {
  load_state
  warn '更新自签证书后，SHA-256 指纹会变化，所有手机都需要重新扫码。'
  ask_yes '确认重签自签证书？' || return 0
  local keybak certbak
  keybak=$(mktemp "$APP_DIR/.oldkey.XXXXXX")
  certbak=$(mktemp "$APP_DIR/.oldcert.XXXXXX")
  cp -p "$KEY" "$keybak"; cp -p "$CERT" "$certbak"
  create_cert
  if systemctl restart hysteria-server >/dev/null 2>&1 && systemctl is-active --quiet hysteria-server; then
    rm -f "$keybak" "$certbak"
    say '证书已更新。请重新扫描二维码。'
  else
    cp -p "$keybak" "$KEY"; cp -p "$certbak" "$CERT"
    systemctl restart hysteria-server >/dev/null 2>&1 || true
    rm -f "$keybak" "$certbak"
    warn '证书更新失败，已恢复原证书。'
  fi
}

logs() { journalctl -u hysteria-server -n 70 --no-pager; }
status_check() {
  load_state
  say 'HY2 自检'
  hysteria version | grep -m1 'Version:' || true
  systemctl --no-pager status hysteria-server | head -n 14 || true
  printf '\n--- UDP 监听 ---\n'
  ss -lunp | grep -F ":$PORT " || warn '未找到对应 UDP 监听。'
  printf '\n--- 证书 SAN ---\n'
  openssl x509 -in "$CERT" -noout -ext subjectAltName || true
  printf '\n--- iptables ---\n'
  iptables -L INPUT -n --line-numbers | grep -E 'udp|REJECT|tcp dpt:22' || true
  warn "无法仅从服务器判断 Oracle 控制台是否开放 UDP $PORT；请在 OCI 控制台查看。"
}

install_or_adopt() {
  [[ ! -f "$STATE" ]] || { say '检测到已安装管理器，进入菜单。'; menu; return; }
  say '正在安装依赖（不会删除 SSH / iptables 现有规则）...'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates python3 qrencode iptables
  if ! command -v hysteria >/dev/null 2>&1 || [[ ! -e /etc/systemd/system/hysteria-server.service ]]; then
    say '通过 Hysteria 官方安装脚本安装服务...'
    local dl
    dl=$(mktemp)
    if ! curl -fsSL https://get.hy2.sh/ -o "$dl"; then rm -f "$dl"; fail '官方脚本下载失败。'; fi
    if ! bash "$dl"; then rm -f "$dl"; fail 'Hysteria 官方安装失败。'; fi
    rm -f "$dl"
  else
    say '检测到 Hysteria 程序，跳过重复下载。'
  fi
  getent group hysteria >/dev/null || fail '没有发现 hysteria 用户组。请检查官方安装日志。'
  [[ -e /etc/systemd/system/hysteria-server.service ]] || fail '没有发现 hysteria-server systemd 服务。'

  install -d -o root -g hysteria -m 750 "$APP_DIR"
  install -d -o root -g root -m 700 "$BACKUPS"
  if [[ -f "$CFG" && -s "$CFG" ]]; then
    warn '检测到已有 /etc/hysteria/config.yaml；本安装将覆盖它（会先备份）。'
    ask_yes '确认接管当前 HY2 配置？' || fail '已取消，原有服务未修改。'
    local stamp
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    cp -p "$CFG" "$BACKUPS/config-pre-manager-$stamp.bak"
    chmod 600 "$BACKUPS/config-pre-manager-$stamp.bak"
    [[ ! -e "$KEY" ]] || { cp -p "$KEY" "$BACKUPS/key-pre-manager-$stamp.bak"; chmod 600 "$BACKUPS/key-pre-manager-$stamp.bak"; }
    [[ ! -e "$CERT" ]] || { cp -p "$CERT" "$BACKUPS/cert-pre-manager-$stamp.bak"; chmod 600 "$BACKUPS/cert-pre-manager-$stamp.bak"; }
  fi

  say '检测公网 IPv4...'
  local detected=''
  detected=$(curl -4fsS --connect-timeout 3 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if ! valid_ipv4 "$detected"; then
    read -r -p '未能自动识别公网 IP，请填写 Oracle 公网 IPv4：' detected || fail '没有提供 IP。'
    valid_ipv4 "$detected" || fail '不是有效公网 IPv4。'
  fi
  SERVER_IP=$detected
  PORT=443
  AUTH=$(openssl rand -hex 24)
  OBFS=$(openssl rand -hex 24)
  say "采用公网 IP：$SERVER_IP；UDP 端口：$PORT"
  create_cert

  say '放行 Ubuntu iptables 中的 UDP 443...'
  firewall_add "$PORT"
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    say '安装 iptables-persistent 以保存防火墙规则...'
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || warn '持久化组件安装失败。'
  fi
  firewall_save

  say '启动 Hysteria 2...'
  if ! apply_config; then
    # If an existing server was being adopted, restore its backed-up key and cert.
    if [[ -n "${stamp:-}" ]]; then
      [[ ! -f "$BACKUPS/key-pre-manager-$stamp.bak" ]] || cp -p "$BACKUPS/key-pre-manager-$stamp.bak" "$KEY"
      [[ ! -f "$BACKUPS/cert-pre-manager-$stamp.bak" ]] || cp -p "$BACKUPS/cert-pre-manager-$stamp.bak" "$CERT"
      [[ ! -f "$BACKUPS/config-pre-manager-$stamp.bak" ]] || cp -p "$BACKUPS/config-pre-manager-$stamp.bak" "$CFG"
      systemctl restart hysteria-server >/dev/null 2>&1 || true
    fi
    fail '服务未能启动。请使用 journalctl -u hysteria-server 排查。'
  fi
  save_state
  if [[ "$(readlink -f "$0")" != "$COMMAND" ]]; then
    install -o root -g root -m 755 "$0" "$COMMAND"
  fi
  say '安装成功！今后任何目录输入 hy2 即可进入管理菜单。'
  printf '\nOracle 控制台仍需检查：VCN/NSG 的 UDP %s 入站规则已开放。\n' "$PORT"
  show_info
  say '下面是 Shadowrocket 兼容二维码：'
  qr_show ios
  say 'Android 可在菜单中选择对应二维码。'
}

menu() {
  while true; do
    cat <<'EOF'

╔══════════════════════════════════════╗
║      HY2 Oracle 管理面板             ║
╠══════════════════════════════════════╣
║  1. 查看服务状态与配置（隐去密码）    ║
║  2. Shadowrocket 二维码              ║
║  3. v2rayNG 二维码                   ║
║  4. 查看完整配置（包含密码）          ║
║  5. 重置 HY2 登录密码               ║
║  6. 重置 Salamander 混淆密码        ║
║  7. 修改 UDP 监听端口                ║
║  8. 修改公网 IP 并重签证书           ║
║  9. 重新签发自签证书                 ║
║ 10. 查看服务日志                     ║
║ 11. 诊断端口与防火墙                 ║
║ 12. 重启服务                         ║
║ 13. 停止 / 启动服务                  ║
║  0. 退出                             ║
╚══════════════════════════════════════╝
EOF
    local choice
    read -r -p '请选择 [0-13]：' choice || { echo; break; }
    case "$choice" in
      1) show_info;;
      2) qr_show ios;;
      3) qr_show android;;
      4) reveal_config;;
      5) rotate_auth;;
      6) rotate_obfs;;
      7) change_port;;
      8) change_ip;;
      9) rotate_cert;;
      10) logs;;
      11) status_check;;
      12) systemctl restart hysteria-server && say '服务已重启。';;
      13)
        if systemctl is-active --quiet hysteria-server; then
          ask_yes '确认停止 HY2 服务？' && systemctl stop hysteria-server || true
        else
          systemctl start hysteria-server && say '服务已启动。'
        fi
        ;;
      0) break;;
      *) warn '无效选项。';;
    esac
  done
}

case "${1:-}" in
  install)
    install_or_adopt;;
  qr)
    qr_show "${2:-ios}";;
  status)
    show_info;;
  logs)
    logs;;
  help|--help|-h)
    cat <<'EOF'
HY2 Oracle Manager
  sudo bash hy2-oracle-manager.sh install  首次安装/接管
  hy2                                  打开交互式管理菜单
  hy2 status                           查看当前状态
  hy2 qr ios                           输出 Shadowrocket 二维码
  hy2 qr android                       输出 v2rayNG 二维码
  hy2 logs                             查看最新日志
EOF
    ;;
  '')
    if [[ -f "$STATE" ]]; then menu; else install_or_adopt; fi;;
  *) fail '未知子命令。使用 hy2 --help 查看用法。';;
esac
