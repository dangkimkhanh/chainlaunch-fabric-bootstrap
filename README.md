# KMASC ChainLaunch Bootstrap

Bộ script tự động chuẩn bị Ubuntu và cài ChainLaunch Community bằng wizard chính thức.

## File

- `01-install-prerequisites.sh`: cài công cụ nền, Docker CE chính thức, NTP và swap.
- `02-install-chainlaunch-auto.sh`: tự chọn Community/TLS self-signed/System service bằng lựa chọn `1`, tự trả lời `y`, kiểm tra API và in URL/tài khoản/mật khẩu.

## Chạy trên VPS Ubuntu 22.04+

```bash
chmod +x 01-install-prerequisites.sh 02-install-chainlaunch-auto.sh

sudo CHAINLAUNCH_PORT=8100 ./01-install-prerequisites.sh
sudo CHAINLAUNCH_PORT=8100 ./02-install-chainlaunch-auto.sh
```

Dùng cổng 443:

```bash
sudo CHAINLAUNCH_PORT=443 ./01-install-prerequisites.sh
sudo CHAINLAUNCH_PORT=443 ./02-install-chainlaunch-auto.sh
```

Chỉ định IP/domain thủ công:

```bash
sudo PUBLIC_IP=103.167.88.159 \
     PUBLIC_HOST=103.167.88.159.nip.io \
     CHAINLAUNCH_PORT=8100 \
     ./02-install-chainlaunch-auto.sh
```

## Kết quả

Script thứ hai in:

- URL dashboard
- Username
- Password
- Trạng thái service
- Đường dẫn credentials và log

Credentials được giữ ở:

```text
/root/.chainlaunch/credentials.txt
/root/.chainlaunch/install-summary.txt
```

Hai file này có quyền `600`. Không đưa chúng lên GitHub.

## Quản trị

```bash
systemctl status chainlaunch --no-pager
systemctl restart chainlaunch
journalctl -u chainlaunch -n 200 --no-pager
```

## Lưu ý

- Script chỉ tự mở cổng khi UFW đã ở trạng thái active; nó không tự bật UFW để tránh khóa nhầm SSH.
- Script cài đặt thử tối đa 3 lần, có thể đổi bằng `MAX_ATTEMPTS`.
- Để nâng cấp/cài lại có chủ đích:

```bash
sudo FORCE_REINSTALL=1 ./02-install-chainlaunch-auto.sh
```
