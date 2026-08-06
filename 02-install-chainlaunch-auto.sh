#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================================
# KMASC - Cài ChainLaunch tự động bằng wizard chính thức
#
# Script tự trả lời:
#   - Community edition                     -> 1
#   - TLS self-signed                       -> 1
#   - System service                        -> 1
#   - Các câu hỏi Y/n                       -> y
#   - Common Name                           -> <PUBLIC_IP>.nip.io
#   - Port                                  -> CHAINLAUNCH_PORT (mặc định 8100)
#
# Tùy chọn:
#   CHAINLAUNCH_PORT=8100
#   PUBLIC_IP=1.2.3.4
#   PUBLIC_HOST=chainlaunch.example.com
#   MAX_ATTEMPTS=3
#   FORCE_REINSTALL=0
#
# Ví dụ:
#   sudo bash 02-install-chainlaunch-auto.sh
#   sudo CHAINLAUNCH_PORT=443 bash 02-install-chainlaunch-auto.sh
# ============================================================================

CHAINLAUNCH_PORT="${CHAINLAUNCH_PORT:-8100}"
PUBLIC_IP="${PUBLIC_IP:-}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
INSTALLER_URL="${INSTALLER_URL:-https://chainlaunch.dev/deploy.sh}"

CHAINLAUNCH_HOME="${CHAINLAUNCH_HOME:-/root/.chainlaunch}"
DATA_DIR="${DATA_DIR:-${CHAINLAUNCH_HOME}/data}"
DB_FILE="${DB_FILE:-${CHAINLAUNCH_HOME}/chainlaunch.db}"
TLS_CERT="${TLS_CERT:-${CHAINLAUNCH_HOME}/tls/server.crt}"
TLS_KEY="${TLS_KEY:-${CHAINLAUNCH_HOME}/tls/server.key}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-${CHAINLAUNCH_HOME}/credentials.txt}"
SUMMARY_FILE="${SUMMARY_FILE:-${CHAINLAUNCH_HOME}/install-summary.txt}"
LOG_DIR="${LOG_DIR:-/var/log/kmasc-chainlaunch}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/install.log}"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
die()  { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf "${RED}[FAIL]${NC} Lỗi tại dòng %s, mã thoát %s\n" "${BASH_LINENO[0]}" "$exit_code" >&2
  printf "Xem log: %s\n" "$LOG_FILE" >&2
  exit "$exit_code"
}
trap on_error ERR

[[ "$(id -u)" -eq 0 ]] || die "Hãy chạy bằng quyền root: sudo bash $0"
command -v curl >/dev/null 2>&1 || die "Thiếu curl. Hãy chạy 01-install-prerequisites.sh trước."
command -v expect >/dev/null 2>&1 || die "Thiếu expect. Hãy chạy 01-install-prerequisites.sh trước."
command -v docker >/dev/null 2>&1 || die "Thiếu Docker. Hãy chạy 01-install-prerequisites.sh trước."
systemctl is-active --quiet docker || systemctl start docker

[[ "$CHAINLAUNCH_PORT" =~ ^[0-9]+$ ]] || die "CHAINLAUNCH_PORT phải là số."
(( CHAINLAUNCH_PORT >= 1 && CHAINLAUNCH_PORT <= 65535 )) || die "CHAINLAUNCH_PORT không hợp lệ."
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || die "MAX_ATTEMPTS phải là số nguyên dương."
(( MAX_ATTEMPTS >= 1 )) || die "MAX_ATTEMPTS phải >= 1."

detect_public_ip() {
  local candidate=""
  local endpoint
  for endpoint in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    candidate="$(curl -4fsS --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf "%s" "$candidate"
      return 0
    fi
  done

  candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$candidate" ]] || return 1
  printf "%s" "$candidate"
}

if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(detect_public_ip || true)"
fi
[[ -n "$PUBLIC_IP" ]] || die "Không phát hiện được PUBLIC_IP. Chạy lại với PUBLIC_IP=x.x.x.x"

if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="${PUBLIC_IP}.nip.io"
fi

if [[ "$CHAINLAUNCH_PORT" == "443" ]]; then
  DASHBOARD_URL="https://${PUBLIC_HOST}"
else
  DASHBOARD_URL="https://${PUBLIC_HOST}:${CHAINLAUNCH_PORT}"
fi
LOCAL_URL="https://127.0.0.1:${CHAINLAUNCH_PORT}"

info "Public IP      : $PUBLIC_IP"
info "TLS hostname   : $PUBLIC_HOST"
info "Dashboard URL  : $DASHBOARD_URL"
info "Port           : $CHAINLAUNCH_PORT"
info "Installer      : $INSTALLER_URL"

load_credentials() {
  ADMIN_USER=""
  ADMIN_PASSWORD=""

  if [[ -f "$CREDENTIALS_FILE" ]]; then
    set +u
    # File do installer chính thức tạo và được thiết kế để source.
    # shellcheck disable=SC1090
    source "$CREDENTIALS_FILE" 2>/dev/null || true
    set -u
    ADMIN_USER="${CHAINLAUNCH_USER:-${ADMIN_USER:-}}"
    ADMIN_PASSWORD="${CHAINLAUNCH_PASSWORD:-${ADMIN_PASSWORD:-}}"

    if [[ -z "$ADMIN_USER" ]]; then
      ADMIN_USER="$(awk -F': *' 'tolower($1) ~ /username/ {print $2; exit}' "$CREDENTIALS_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$ADMIN_PASSWORD" ]]; then
      ADMIN_PASSWORD="$(awk -F': *' 'tolower($1) ~ /password/ {print $2; exit}' "$CREDENTIALS_FILE" 2>/dev/null || true)"
    fi
  fi

  ADMIN_USER="${ADMIN_USER:-admin}"

  if [[ -z "$ADMIN_PASSWORD" && -f "${CHAINLAUNCH_HOME}/.wizard-state/admin_password" ]]; then
    ADMIN_PASSWORD="$(tr -d '[:space:]' < "${CHAINLAUNCH_HOME}/.wizard-state/admin_password")"
  fi
}

health_check() {
  load_credentials

  systemctl is-active --quiet chainlaunch || return 1
  [[ -n "${ADMIN_PASSWORD:-}" ]] || return 1

  curl -skf \
    --connect-timeout 5 \
    --max-time 15 \
    -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
    "${LOCAL_URL}/api/v1/nodes" >/dev/null
}

print_success_and_exit() {
  load_credentials
  [[ -n "${ADMIN_PASSWORD:-}" ]] || die "Dịch vụ chạy nhưng không đọc được mật khẩu từ $CREDENTIALS_FILE"

  install -d -m 700 "$CHAINLAUNCH_HOME"
  cat >"$SUMMARY_FILE" <<EOF
KMASC ChainLaunch deployment
============================
URL=${DASHBOARD_URL}
LOCAL_URL=${LOCAL_URL}
USERNAME=${ADMIN_USER}
PASSWORD=${ADMIN_PASSWORD}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_HOST=${PUBLIC_HOST}
PORT=${CHAINLAUNCH_PORT}
DATA_DIR=${DATA_DIR}
DATABASE=${DB_FILE}
TLS_CERT=${TLS_CERT}
TLS_KEY=${TLS_KEY}
SERVICE=chainlaunch.service
EOF
  chmod 600 "$SUMMARY_FILE"

  echo
  printf "${GREEN}=================== CHAINLAUNCH SETUP COMPLETE ===================${NC}\n"
  printf "URL đăng nhập : %s\n" "$DASHBOARD_URL"
  printf "Tài khoản     : %s\n" "$ADMIN_USER"
  printf "Mật khẩu      : %s\n" "$ADMIN_PASSWORD"
  printf "Dịch vụ       : %s\n" "$(systemctl is-active chainlaunch)"
  printf "Phiên bản     : %s\n" "$(chainlaunch version 2>/dev/null || chainlaunch --version 2>/dev/null || echo unknown)"
  printf "Credentials   : %s\n" "$CREDENTIALS_FILE"
  printf "Summary       : %s\n" "$SUMMARY_FILE"
  printf "Log cài đặt   : %s\n" "$LOG_FILE"
  printf "${GREEN}=================================================================${NC}\n"
  echo
  echo "Lệnh quản trị:"
  echo "  systemctl status chainlaunch --no-pager"
  echo "  systemctl restart chainlaunch"
  echo "  journalctl -u chainlaunch -n 200 --no-pager"
  echo
  echo "CẢNH BÁO: File credentials/summary chứa mật khẩu; không đưa lên GitHub."
  exit 0
}

if [[ "$FORCE_REINSTALL" != "1" ]] && health_check; then
  ok "ChainLaunch đã hoạt động; không cài đè."
  print_success_and_exit
fi

backup_existing_state() {
  if [[ -d "$CHAINLAUNCH_HOME" || -f /etc/systemd/system/chainlaunch.service ]]; then
    local backup_dir="/root/chainlaunch-preinstall-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    [[ -f /etc/systemd/system/chainlaunch.service ]] && \
      cp -a /etc/systemd/system/chainlaunch.service "$backup_dir/" || true
    [[ -f "$CREDENTIALS_FILE" ]] && \
      cp -a "$CREDENTIALS_FILE" "$backup_dir/" || true
    [[ -f "$DB_FILE" ]] && \
      cp -a "$DB_FILE" "$backup_dir/" || true

    chmod -R go-rwx "$backup_dir"
    ok "Đã sao lưu file quan trọng trước cài/upgrade: $backup_dir"
  fi
}

backup_existing_state

INSTALLER_FILE="$(mktemp /tmp/chainlaunch-deploy.XXXXXX.sh)"
EXPECT_FILE="$(mktemp /tmp/chainlaunch-deploy.XXXXXX.exp)"
cleanup() {
  rm -f "$INSTALLER_FILE" "$EXPECT_FILE"
}
trap cleanup EXIT

download_installer() {
  info "Tải installer chính thức..."
  curl -fL --retry 3 --retry-delay 3 "$INSTALLER_URL" -o "$INSTALLER_FILE"
  chmod 700 "$INSTALLER_FILE"
  bash -n "$INSTALLER_FILE"
  ok "Installer hợp lệ."
  info "SHA-256 installer: $(sha256sum "$INSTALLER_FILE" | awk '{print $1}')"
}

write_expect_script() {
  cat >"$EXPECT_FILE" <<'EXPECT_EOF'
#!/usr/bin/expect -f
set timeout 1800

set installer $env(CL_INSTALLER_FILE)
set port      $env(CL_PORT)
set hostname  $env(CL_PUBLIC_HOST)

log_user 1
spawn bash $installer

expect {
  -re {Install Docker now\?.*\[[Yy]/[Nn]\].*:} {
    send -- "y\r"
    exp_continue
  }
  -re {Re-install / upgrade\?.*\[[Yy]/[Nn]\].*:} {
    send -- "y\r"
    exp_continue
  }
  -re {Install.*now\?.*\[[Yy]/[Nn]\].*:} {
    send -- "y\r"
    exp_continue
  }
  -re {Which edition.*} {
    exp_continue
  }
  -re {Enter choice \[1-2\].*:} {
    send -- "1\r"
    exp_continue
  }
  -re {Enter choice \[1-3\].*:} {
    send -- "1\r"
    exp_continue
  }
  -re {Choose.*\[1-2\].*:} {
    send -- "1\r"
    exp_continue
  }
  -re {Choose.*\[1-3\].*:} {
    send -- "1\r"
    exp_continue
  }
  -re {Certificate Common Name.*:} {
    send -- "$hostname\r"
    exp_continue
  }
  -re {(HTTP|HTTPS) port.*:} {
    send -- "$port\r"
    exp_continue
  }
  -re {Proceed with this configuration\?.*\[[Yy]/[Nn]\].*:} {
    send -- "y\r"
    exp_continue
  }
  -re {Continue\?.*\[[Yy]/[Nn]\].*:} {
    send -- "y\r"
    exp_continue
  }
  -re {Press Enter.*} {
    send -- "\r"
    exp_continue
  }
  eof {
    catch wait result
    set exit_code [lindex $result 3]
    exit $exit_code
  }
  timeout {
    send_user "\nERROR: ChainLaunch installer timed out.\n"
    exit 124
  }
}
EXPECT_EOF
  chmod 700 "$EXPECT_FILE"
}

repair_systemd_service() {
  local bin_path=""
  if command -v chainlaunch >/dev/null 2>&1; then
    bin_path="$(command -v chainlaunch)"
  elif [[ -x "${CHAINLAUNCH_HOME}/bin/chainlaunch" ]]; then
    bin_path="${CHAINLAUNCH_HOME}/bin/chainlaunch"
  else
    return 1
  fi

  load_credentials
  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    ADMIN_USER="admin"
    ADMIN_PASSWORD="$(openssl rand -hex 12)"
    warn "Không tìm thấy mật khẩu wizard; đã tạo mật khẩu khôi phục mới."
  fi

  mkdir -p "$DATA_DIR" "$(dirname "$DB_FILE")" "$(dirname "$TLS_CERT")"

  [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || {
    warn "Không tìm thấy TLS certificate/key; chưa thể sửa service."
    return 1
  }

  local help_text
  help_text="$("$bin_path" serve --help 2>&1 || true)"
  grep -q -- '--port' <<<"$help_text" || {
    warn "Binary hiện tại không hỗ trợ --port; không tạo service fallback."
    return 1
  }

  info "Tạo lại systemd service bằng các flag được binary hỗ trợ..."
  cat >/etc/systemd/system/chainlaunch.service <<EOF
[Unit]
Description=ChainLaunch Blockchain Infrastructure Platform
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
Environment="CHAINLAUNCH_USER=${ADMIN_USER}"
Environment="CHAINLAUNCH_PASSWORD=${ADMIN_PASSWORD}"
ExecStart=${bin_path} serve --data=${DATA_DIR} --db=${DB_FILE} --port=${CHAINLAUNCH_PORT} --tls-cert=${TLS_CERT} --tls-key=${TLS_KEY}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable chainlaunch >/dev/null
  systemctl restart chainlaunch
  return 0
}

wait_for_health() {
  local seconds="${1:-180}"
  local elapsed=0

  while (( elapsed < seconds )); do
    if health_check; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    printf "."
  done
  echo
  return 1
}

download_installer
write_expect_script

attempt=1
while (( attempt <= MAX_ATTEMPTS )); do
  info "Cài ChainLaunch - lần ${attempt}/${MAX_ATTEMPTS}"

  export CL_INSTALLER_FILE="$INSTALLER_FILE"
  export CL_PORT="$CHAINLAUNCH_PORT"
  export CL_PUBLIC_HOST="$PUBLIC_HOST"

  set +e
  expect "$EXPECT_FILE"
  installer_status=$?
  set -e

  if (( installer_status != 0 )); then
    warn "Installer trả mã ${installer_status}."
  fi

  systemctl daemon-reload || true
  systemctl enable --now chainlaunch >/dev/null 2>&1 || true

  info "Chờ ChainLaunch sẵn sàng..."
  if wait_for_health 180; then
    ok "ChainLaunch đã phản hồi API."
    print_success_and_exit
  fi

  warn "Health check chưa đạt. Kiểm tra lỗi flag/service và tự sửa..."
  if systemctl cat chainlaunch 2>/dev/null | grep -Eq -- '--external-url|--https-addr'; then
    warn "Phát hiện flag cũ --external-url/--https-addr từng gây lỗi ở bản trước."
  fi

  repair_systemd_service || true

  if wait_for_health 120; then
    ok "ChainLaunch đã hoạt động sau khi sửa systemd."
    print_success_and_exit
  fi

  warn "Lần ${attempt} chưa thành công."
  journalctl -u chainlaunch -n 80 --no-pager || true
  attempt=$((attempt + 1))

  if (( attempt <= MAX_ATTEMPTS )); then
    warn "Thử lại sau 10 giây..."
    sleep 10
  fi
done

echo
printf "${RED}ChainLaunch chưa triển khai thành công sau %s lần thử.${NC}\n" "$MAX_ATTEMPTS"
echo "Chẩn đoán nhanh:"
echo "  systemctl status chainlaunch --no-pager -l"
echo "  journalctl -u chainlaunch -n 200 --no-pager"
echo "  chainlaunch serve --help"
echo "  ss -lntp | grep ':${CHAINLAUNCH_PORT}'"
echo "Log đầy đủ: $LOG_FILE"
exit 1
