#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Robert Burger
# Credit: Adapted from dotnetaspwebapi by Kristian Skov
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
    TARGET_FRAMEWORK="net10.0"
    ;;
  3|both|all)
    DOTNET_PACKAGES="dotnet-sdk-9.0 dotnet-sdk-10.0"
    DOTNET_DESC=".NET 9.0 & 10.0 SDK"
    TARGET_FRAMEWORK="net10.0"
    ;;
  *)
    DOTNET_PACKAGES="dotnet-sdk-9.0"
    DOTNET_DESC=".NET 9.0 SDK"
    TARGET_FRAMEWORK="net9.0"
    ;;
esac

if [[ -z "${var_site_count:-}" ]]; then
  read -r -p "${TAB3}How many sites would you like to configure? [default: 2]: " var_site_count
fi
var_site_count="${var_site_count:-2}"
if ! [[ "$var_site_count" =~ ^[1-9][0-9]*$ ]]; then
  var_site_count=2
fi

SITE_NAMES=()
SITE_PORTS=()
KESTREL_PORTS=()

for ((i=1; i<=var_site_count; i++)); do
  default_site="site${i}"
  var_name_ref="var_site_${i}_name"
  site_name="${!var_name_ref:-}"
  if [[ -z "$site_name" ]]; then
    read -r -p "${TAB3}Enter assembly/project name for Site ${i} [default: ${default_site}]: " site_name
  fi
  site_name="$(echo "$site_name" | sed 's/[^a-zA-Z0-9._-]//g')"
  site_name="${site_name:-$default_site}"

  default_port=$((8079 + i))
  var_port_ref="var_site_${i}_port"
  site_port="${!var_port_ref:-}"
  if [[ -z "$site_port" ]]; then
    read -r -p "${TAB3}Enter external HTTP port for ${site_name} [default: ${default_port}]: " site_port
  fi
  site_port="${site_port:-$default_port}"

  kestrel_port=$((4999 + i))

  SITE_NAMES+=("$site_name")
  SITE_PORTS+=("$site_port")
  KESTREL_PORTS+=("$kestrel_port")
done

msg_info "Installing Dependencies (${DOTNET_DESC})"
$STD apt update
$STD apt install -y \
  ssh \
  software-properties-common

$STD add-apt-repository -y ppa:dotnet/backports
$STD apt update
$STD apt install -y \
  $DOTNET_PACKAGES \
  vsftpd \
  nginx
msg_ok "Installed Dependencies (${DOTNET_DESC})"

msg_info "Setting up FTP Server"
useradd -m -d /var/www ftpuser 2>/dev/null || usermod -d /var/www ftpuser
FTP_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
usermod --password $(echo "${FTP_PASS}" | openssl passwd -1 -stdin) ftpuser
mkdir -p /var/www
usermod -d /var/www ftp 2>/dev/null || true
chown -R ftpuser:ftpuser /var/www

sed -i "s|#write_enable=YES|write_enable=YES|g" /etc/vsftpd.conf
sed -i "s|#chroot_local_user=YES|chroot_local_user=NO|g" /etc/vsftpd.conf

systemctl restart -q vsftpd.service

cat <<EOF >~/ftp.creds
FTP-Credentials
Username: ftpuser
Password: ${FTP_PASS}
Root Directory: /var/www
EOF

msg_ok "FTP server setup completed"

msg_info "Setting up Nginx Multi-Site Server"
rm -f /etc/nginx/sites-enabled/default /var/www/html/index.nginx-debian.html

cat <<EOF >/etc/nginx/conf.d/dotnet_upgrade_map.conf
map \$http_connection \$connection_upgrade {
  "~*Upgrade" \$http_connection;
  default keep-alive;
}
EOF

for i in "${!SITE_NAMES[@]}"; do
  site="${SITE_NAMES[$i]}"
  e_port="${SITE_PORTS[$i]}"
  i_port="${KESTREL_PORTS[$i]}"

  cat <<EOF >/etc/nginx/sites-available/${site}
server {
  listen        ${e_port};
  server_name   ${site}.com *.${site}.com localhost;
  location / {
      proxy_pass         http://127.0.0.1:${i_port}/;
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
  ln -sf /etc/nginx/sites-available/${site} /etc/nginx/sites-enabled/${site}
done

systemctl reload nginx 2>/dev/null || systemctl restart -q nginx
msg_ok "Nginx Multi-Site Server Created"

msg_info "Creating Sample Applications"
for i in "${!SITE_NAMES[@]}"; do
  site="${SITE_NAMES[$i]}"

  mkdir -p /tmp/${site} /var/www/${site}
  cat <<EOF >/tmp/${site}/${site}.csproj
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>${TARGET_FRAMEWORK}</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>${site}</AssemblyName>
  </PropertyGroup>

</Project>
EOF

  cat <<EOF >/tmp/${site}/Program.cs
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => "Hello from your new Dotnet X ASP WebAPI LXC - Project: ${site}.  <p>Check ~/ftp.creds for FTP-user and Password</p> <p>Upload your project to the /var/www/${site} directory, overwriting this sample application.</p> <p>I hope you enjoy your new host! <i>Robert Burger</i></p>");

app.Run();
EOF

  DOTNET_CLI_TELEMETRY_OPTOUT=1 $STD dotnet publish /tmp/${site}/${site}.csproj -c Release -o /var/www/${site}
  rm -rf /tmp/${site}
done
chown -R ftpuser:ftpuser /var/www
msg_ok "Created Sample Applications"

msg_info "Creating Services"
for i in "${!SITE_NAMES[@]}"; do
  site="${SITE_NAMES[$i]}"
  i_port="${KESTREL_PORTS[$i]}"

  cat <<EOF >/etc/systemd/system/kestrel-${site}.service
[Unit]
Description=.NET Web API App (${site}) running on Linux
After=network.target

[Service]
WorkingDirectory=/var/www/${site}
ExecStart=/usr/bin/dotnet /var/www/${site}/${site}.dll
Restart=always
# Restart service after 10 seconds if the dotnet service crashes:
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=dotnet-${site}
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
Environment=ASPNETCORE_URLS=http://127.0.0.1:${i_port}

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable -q --now kestrel-${site}
done
msg_ok "Created Services"

echo -e "\n${INFO}${YW}Configured .NET ASP WebAPI Applications:${CL}"
printf "\n  ${BL}%-20s %-35s %-15s${CL}\n" "Assembly Name" "External Link" "Internal Port"
printf "  ${BL}%-20s %-35s %-15s${CL}\n" "--------------------" "-----------------------------------" "---------------"
for i in "${!SITE_NAMES[@]}"; do
  site="${SITE_NAMES[$i]}"
  e_port="${SITE_PORTS[$i]}"
  i_port="${KESTREL_PORTS[$i]}"
  printf "  %-20s %-35s %-15s\n" "${site}" "http://${LOCAL_IP}:${e_port}" "${i_port}"
done
echo ""

motd_ssh
customize
cleanup_lxc
