#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Kristian Skov
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/linux-nginx?view=aspnetcore-9.0&tabs=linux-ubuntu

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -z "${var_dotnet_version:-}" ]]; then
  echo -e "${TAB3}Select .NET SDK version to install:"
  echo -e "${TAB3} 1) .NET 9.0 SDK"
  echo -e "${TAB3} 2) .NET 10.0 SDK"
  echo -e "${TAB3} 3) Both (.NET 9.0 & .NET 10.0 SDK)"
  read -r -p "${TAB3}Enter choice [1-3, default: 1]: " var_dotnet_version
fi
var_dotnet_version="${var_dotnet_version:-1}"

case "$var_dotnet_version" in
  2|10|10.0)
    DOTNET_PACKAGES="dotnet-sdk-10.0"
    DOTNET_DESC=".NET 10.0 SDK"
    ;;
  3|both|all)
    DOTNET_PACKAGES="dotnet-sdk-9.0 dotnet-sdk-10.0"
    DOTNET_DESC=".NET 9.0 & 10.0 SDK"
    ;;
  *)
    DOTNET_PACKAGES="dotnet-sdk-9.0"
    DOTNET_DESC=".NET 9.0 SDK"
    ;;
esac

msg_info "Installing Dependencies (${DOTNET_DESC})"
$STD apt-get update
$STD apt-get install -y \
  ssh \
  software-properties-common

$STD add-apt-repository -y ppa:dotnet/backports
$STD apt-get update
$STD apt-get install -y \
  $DOTNET_PACKAGES \
  vsftpd \
  nginx
msg_ok "Installed Dependencies (${DOTNET_DESC})"

if [[ -z "${var_project_name:-}" ]]; then
  read -r -p "${TAB3}Type the assembly name of the project: " var_project_name
fi
var_project_name="${var_project_name:-default}"

msg_info "Setting up FTP Server"
useradd -m -d /var/www/html ftpuser 2>/dev/null || usermod -d /var/www/html ftpuser
FTP_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
usermod --password $(echo "${FTP_PASS}" | openssl passwd -1 -stdin) ftpuser
mkdir -p /var/www/html
usermod -d /var/www/html ftp 2>/dev/null || true
chown -R ftpuser:ftpuser /var/www/html

sed -i "s|#write_enable=YES|write_enable=YES|g" /etc/vsftpd.conf
sed -i "s|#chroot_local_user=YES|chroot_local_user=NO|g" /etc/vsftpd.conf

systemctl restart -q vsftpd.service

cat <<EOF >~/ftp.creds
FTP-Credentials
Username: ftpuser
Password: ${FTP_PASS}
EOF

msg_ok "FTP server setup completed"

msg_info "Setting up Nginx Server"
rm -f /var/www/html/index.nginx-debian.html

cat <<EOF >/etc/nginx/sites-available/default
map \$http_connection \$connection_upgrade {
  "~*Upgrade" \$http_connection;
  default keep-alive;
}
server {
  listen        80;
  server_name   ${var_project_name}.com *.${var_project_name}.com;
  location / {
      proxy_pass         http://127.0.0.1:5000/;
      proxy_http_version 1.1;
      proxy_set_header   Upgrade \$http_upgrade;
      proxy_set_header   Connection \$connection_upgrade;
      proxy_set_header   Host \$host;
      proxy_cache_bypass \$http_upgrade;
      proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto \$scheme;
  }
}
EOF
systemctl reload nginx 2>/dev/null || systemctl restart -q nginx
msg_ok "Nginx Server Created"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/kestrel-aspnetapi.service
[Unit]
Description=.NET Web API App running on Linux
After=network.target

[Service]
WorkingDirectory=/var/www/html
ExecStart=/usr/bin/dotnet /var/www/html/${var_project_name}.dll
Restart=always
# Restart service after 10 seconds if the dotnet service crashes:
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=dotnet-${var_project_name}
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now kestrel-aspnetapi
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
