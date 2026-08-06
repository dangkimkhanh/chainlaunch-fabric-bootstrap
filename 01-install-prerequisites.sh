#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================================
# KMASC - Chuẩn bị tài nguyên cho ChainLaunch + Hyperledger Fabric
# Hỗ trợ: Ubuntu 22.04+ (amd64/arm64)
#
# Tùy chọn:
#   CHAINLAUNCH_PORT=8100   Cổng dashboard dự kiến
#   SWAP_SIZE_GB=4         Dung lượng swap tạo khi máy chưa có swap
#
# Ví dụ:
#   sudo CHAINLAUNCH_PORT=8100 bash 01-install-prerequisites.sh
# ============================================================================

CHAINLAUNCH_PORT="${CHAINLAUNCH_PORT:-8100}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-4}"
LOG_FILE="${LOG_FILE:-/var/log/kmasc-chainlaunch-prerequisites.log}"

mkdir -p "$(dirname "$LOG_FILE")"
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

[[ "$(id -u)" -eq 0 ]] || die "Hãy chạy script bằng quyền root: sudo bash $0"

[[ -r /etc/os-release ]] || die "Không đọc được /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Script này được chuẩn hóa cho Ubuntu 22.04+; hệ điều hành hiện tại: ${PRETTY_NAME:-unknown}"

major_version="${VERSION_ID%%.*}"
[[ "$major_version" =~ ^[0-9]+$ ]] || die "Không xác định được phiên bản Ubuntu"
(( major_version >= 22 )) || die "Cần Ubuntu 22.04 trở lên; hiện tại: ${VERSION_ID}"

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64|arm64) ;;
  *) die "Kiến trúc chưa hỗ trợ: $arch (chỉ amd64/arm64)" ;;
esac

info "Hệ điều hành: ${PRETTY_NAME}"
info "Kiến trúc: $arch"
info "Log: $LOG_FILE"

cpu_count="$(nproc)"
mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
mem_gb=$((mem_kb / 1024 / 1024))
disk_free_gb="$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"

(( cpu_count >= 2 )) || warn "Chỉ có ${cpu_count} CPU; ChainLaunch yêu cầu tối thiểu khoảng 2 core."
(( mem_gb >= 4 )) || warn "RAM khoảng ${mem_gb} GiB; nên có ít nhất 4 GiB, khuyến nghị 8 GiB+."
(( disk_free_gb >= 10 )) || die "Ổ đĩa trống chỉ còn ${disk_free_gb} GiB; cần tối thiểu khoảng 10 GiB."
(( disk_free_gb >= 20 )) || warn "Ổ đĩa trống ${disk_free_gb} GiB; khuyến nghị 20 GiB+."

info "Cập nhật danh sách gói và cài công cụ nền..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  ca-certificates curl wget git jq unzip zip tar openssl \
  gnupg lsb-release software-properties-common apt-transport-https \
  expect netcat-openbsd dnsutils iproute2 procps rsync acl \
  ufw xz-utils

ok "Các công cụ nền đã được cài."

info "Bật đồng bộ thời gian NTP..."
timedatectl set-ntp true || true
systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
if timedatectl show -p NTP --value 2>/dev/null | grep -qi true; then
  ok "NTP đã bật."
else
  warn "Chưa xác nhận được NTP; kiểm tra bằng: timedatectl status"
fi

install_docker_ce() {
  if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed"; then
    ok "Docker CE đã tồn tại; bỏ qua cài lại."
    return
  fi

  info "Gỡ các gói Docker xung đột (nếu có)..."
  local conflicting
  for conflicting in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$conflicting" >/dev/null 2>&1 || true
  done

  info "Thêm kho Docker CE chính thức..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "$codename" ]] || die "Không xác định được Ubuntu codename"

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update -y
  apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_docker_ce
systemctl enable --now docker
docker info >/dev/null
ok "Docker hoạt động: $(docker --version)"
ok "Docker Compose: $(docker compose version)"
ok "Docker Buildx: $(docker buildx version | head -n1)"

info "Chạy kiểm tra Docker hello-world..."
docker run --rm hello-world >/dev/null
ok "Docker hello-world thành công."

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "$SUDO_USER"
  warn "Đã thêm ${SUDO_USER} vào nhóm docker; cần đăng xuất/đăng nhập lại để áp dụng."
fi

create_swap_if_needed() {
  if swapon --show --noheadings | grep -q .; then
    ok "Máy đã có swap; bỏ qua tạo mới."
    return
  fi

  if [[ "$SWAP_SIZE_GB" == "0" ]]; then
    warn "SWAP_SIZE_GB=0 nên không tạo swap."
    return
  fi

  info "Máy chưa có swap; tạo ${SWAP_SIZE_GB} GiB tại /swapfile..."
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  else
    dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || \
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Đã tạo swap ${SWAP_SIZE_GB} GiB."
}

create_swap_if_needed

if ss -lnt "( sport = :${CHAINLAUNCH_PORT} )" 2>/dev/null | grep -q LISTEN; then
  warn "Cổng ${CHAINLAUNCH_PORT} đang được sử dụng:"
  ss -lntp "( sport = :${CHAINLAUNCH_PORT} )" || true
else
  ok "Cổng ${CHAINLAUNCH_PORT} đang trống."
fi

if ufw status 2>/dev/null | grep -q "Status: active"; then
  info "UFW đang bật; bảo đảm SSH và cổng ChainLaunch được phép..."
  ufw allow OpenSSH >/dev/null || true
  ufw allow "${CHAINLAUNCH_PORT}/tcp" >/dev/null || true
  ok "Đã thêm rule UFW cho TCP ${CHAINLAUNCH_PORT}."
else
  warn "UFW đang tắt; script không tự bật để tránh khóa nhầm SSH."
fi

echo
printf "${GREEN}================ CHUẨN BỊ TÀI NGUYÊN HOÀN TẤT ================${NC}\n"
printf "OS              : %s\n" "${PRETTY_NAME}"
printf "CPU             : %s core\n" "$cpu_count"
printf "RAM             : ~%s GiB\n" "$mem_gb"
printf "Disk trống       : %s GiB\n" "$disk_free_gb"
printf "Swap            : %s\n" "$(swapon --show --bytes --noheadings 2>/dev/null | awk '{sum+=$3} END {if(sum>0) printf "%.1f GiB",sum/1024/1024/1024; else print "0"}')"
printf "Docker          : %s\n" "$(docker --version)"
printf "Docker Compose  : %s\n" "$(docker compose version)"
printf "NTP             : %s\n" "$(timedatectl show -p NTP --value 2>/dev/null || echo unknown)"
printf "Cổng ChainLaunch: %s\n" "$CHAINLAUNCH_PORT"
printf "Log             : %s\n" "$LOG_FILE"
printf "${GREEN}==============================================================${NC}\n"
