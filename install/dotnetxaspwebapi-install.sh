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

if [[ -z "${var_project_name:-}" ]]; then
  read -r -p "${TAB3}Type the assembly name of the project: " var_project_name
fi
var_project_name="${var_project_name:-default}"

msg_info "Setting up FTP Server"
useradd -m -d /var/www ftpuser 2>/dev/null || usermod -d /var/www ftpuser
FTP_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
usermod --password $(echo "${FTP_PASS}" | openssl passwd -1 -stdin) ftpuser
mkdir -p /var/www/html
usermod -d /var/www ftp 2>/dev/null || true
chown -R ftpuser:ftpuser /var/www

sed -i "s|#write_enable=YES|write_enable=YES|g" /etc/vsftpd.conf
sed -i "s|#chroot_local_user=YES|chroot_local_user=NO|g" /etc/vsftpd.conf

systemctl restart -q vsftpd.service

cat <<EOF >~/ftp.creds
FTP-Credentials
Username: ftpuser
Password: ${FTP_PASS}
Root Directory: /var/www (html/ for default site)
EOF

msg_ok "FTP server setup completed"

msg_info "Setting up Nginx Server"
rm -f /var/www/html/index.nginx-debian.html

cat <<EOF >/etc/nginx/conf.d/dotnet_upgrade_map.conf
map \$http_connection \$connection_upgrade {
  "~*Upgrade" \$http_connection;
  default keep-alive;
}
EOF

cat <<EOF >/etc/nginx/sites-available/default
server {
  listen        80 default_server;
  server_name   ${var_project_name}.com *.${var_project_name}.com localhost;
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

msg_info "Creating Sample Application"
mkdir -p /tmp/${var_project_name}
cat <<EOF >/tmp/${var_project_name}/${var_project_name}.csproj
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>${TARGET_FRAMEWORK}</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>${var_project_name}</AssemblyName>
  </PropertyGroup>

</Project>
EOF

cat <<EOF >/tmp/${var_project_name}/Program.cs
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Results.Content("<html><body><h1>Hello from your new Dotnet X ASP WebAPI LXC.</h1><p>Check ~/ftp.creds for FTP-user and Password</p><p>Upload your project to the /var/www/html directory, overwriting this sample application.</p><p>I hope you enjoy your new host!</br><i>Robert Burger</i></p></body></html>", "text/html"));

app.Run();
EOF

DOTNET_CLI_TELEMETRY_OPTOUT=1 $STD dotnet publish /tmp/${var_project_name}/${var_project_name}.csproj -c Release -o /var/www/html
rm -rf /tmp/${var_project_name}
chown -R ftpuser:ftpuser /var/www/html
msg_ok "Created Sample Application"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/kestrel-aspnetapi.service
[Unit]
Description=.NET Web API App running on Linux
After=network.target

[Service]
WorkingDirectory=/var/www/html
ExecStart=/usr/bin/dotnet /var/www/html/${var_project_name}.dll --urls http://127.0.0.1:5000
Restart=always
# Restart service after 10 seconds if the dotnet service crashes:
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=dotnet-${var_project_name}
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
Environment=ASPNETCORE_URLS=http://127.0.0.1:5000

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now kestrel-aspnetapi
msg_ok "Created Service"

msg_info "Configuring Login Profile"
cat <<'EOF' >/etc/profile.d/99-dotnet-sites.sh
#!/bin/bash
# Only run in interactive shells
[[ $- != *i* ]] && return

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP="${IP:-localhost}"

echo -e "\e[1;36m=== Dotnet X ASP WebAPI Status ===\e[0m"
printf "  \e[1;34m%-22s %-34s %-12s %-10s\e[0m\n" "Assembly Name" "External Link" "Internal" "Status"
printf "  \e[1;34m%-22s %-34s %-12s %-10s\e[0m\n" "----------------------" "----------------------------------" "------------" "----------"

for service in /etc/systemd/system/kestrel-*.service; do
  [ -f "$service" ] || continue
  name=$(basename "$service" .service | sed 's/kestrel-//')
  if [ "$name" = "aspnetapi" ]; then
    dll=$(grep 'ExecStart=' "$service" 2>/dev/null | head -n1 | sed -n 's/.*\/var\/www\/[^\/]*\/\([^. ]*\)\.dll.*/\1/p')
    name="${dll:-default}"
  fi
  i_port=$(grep '127.0.0.1:' "$service" 2>/dev/null | head -n1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
  i_port="${i_port:-5000}"
  e_port=$(grep 'listen ' "/etc/nginx/sites-available/$name" 2>/dev/null | head -n1 | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p')
  e_port="${e_port:-80}"
  status=$(systemctl is-active "kestrel-$name" 2>/dev/null || systemctl is-active "kestrel-aspnetapi" 2>/dev/null)

  if [ "$status" = "active" ]; then
    status_fmt="\e[32mActive\e[0m"
  else
    status_fmt="\e[31m${status:-stopped}\e[0m"
  fi

  printf "  %-22s %-34s %-12s %b\n" "$name" "http://${IP}:${e_port}" "$i_port" "$status_fmt"
done | sort -t: -k3,3n
echo ""
echo -e "  \e[1;33mManage sites:\e[0m  add-dotnet-site | remove-dotnet-site | rename-dotnet-site | reset-dotnet-site <name>"
echo -e "  \e[1;36mDocumentation:\e[0m https://github.com/community-scripts/ProxmoxVED/blob/main/docs/guides/dotnetxaspwebapi.md"
echo ""
EOF
chmod +x /etc/profile.d/99-dotnet-sites.sh
msg_ok "Configured Login Profile"

msg_info "Installing Site Management Utility"
cat <<'EOF' >/usr/local/bin/add-dotnet-site
#!/usr/bin/env bash
# add-dotnet-site - Helper utility to add an ASP.NET Core Web API site to this LXC
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31mThis script must be run as root.\e[0m" >&2
  exit 1
fi

echo -e "\e[1;36m=== Add ASP.NET Core Web API Site ===\e[0m\n"

TARGET_FRAMEWORK="net9.0"
if command -v dotnet >/dev/null 2>&1; then
  if dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    TARGET_FRAMEWORK="net10.0"
  fi
fi

max_i_port=4999
for svc in /etc/systemd/system/kestrel-*.service; do
  [ -f "$svc" ] || continue
  p=$(grep '127.0.0.1:' "$svc" 2>/dev/null | head -n1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > max_i_port )); then
    max_i_port=$p
  fi
done
next_i_port=$((max_i_port + 1))

max_e_port=8079
for conf in /etc/nginx/sites-available/*; do
  [ -f "$conf" ] || continue
  for p in $(grep 'listen ' "$conf" 2>/dev/null | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p'); do
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p > max_e_port )); then
      max_e_port=$p
    fi
  done
done
next_e_port=$((max_e_port + 1))

while true; do
  read -r -p "Enter entry assembly name (without .dll, e.g. MyApp.Web): " site_name
  site_name="$(echo "$site_name" | sed 's/[^a-zA-Z0-9._-]//g')"
  if [[ -z "$site_name" ]]; then
    echo -e "\e[31mAssembly name cannot be empty.\e[0m"
    continue
  fi
  if [[ -d "/var/www/${site_name}" ]]; then
    echo -e "\e[31mDirectory /var/www/${site_name} already exists. Please choose a different name.\e[0m"
    continue
  fi
  if [[ -f "/etc/systemd/system/kestrel-${site_name}.service" ]]; then
    echo -e "\e[31mService kestrel-${site_name}.service already exists. Please choose a different name.\e[0m"
    continue
  fi
  break
done

read -r -p "Enter external HTTP port [default: ${next_e_port}]: " site_port
site_port="${site_port:-$next_e_port}"
while ! [[ "$site_port" =~ ^[1-9][0-9]*$ ]] || (( site_port < 1 || site_port > 65535 )); do
  read -r -p "Invalid port. Enter a valid port number [1-65535]: " site_port
done

if id -u ftpuser >/dev/null 2>&1; then
  usermod -d /var/www ftpuser 2>/dev/null || true
fi
mkdir -p "/var/www/${site_name}"
chown -R ftpuser:ftpuser "/var/www/${site_name}" 2>/dev/null || true

echo -e "\n\e[34m[Info]\e[0m Creating sample project for ${site_name} (${TARGET_FRAMEWORK})..."
mkdir -p "/tmp/${site_name}"
cat <<EOCSPROJ >"/tmp/${site_name}/${site_name}.csproj"
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>${TARGET_FRAMEWORK}</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>${site_name}</AssemblyName>
  </PropertyGroup>

</Project>
EOCSPROJ

cat <<EOCS >"/tmp/${site_name}/Program.cs"
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Results.Content("<html><body><h1>Hello from your new Dotnet X ASP WebAPI LXC for project <b>${site_name}</b>.</h1><p>Check ~/ftp.creds for FTP-user and Password</p><p>Upload your project to the /var/www/${site_name} directory, overwriting this sample application.</p><p>I hope you enjoy your new host!</br><i>Robert Burger</i></p></body></html>", "text/html"));

app.Run();
EOCS

DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet publish "/tmp/${site_name}/${site_name}.csproj" -c Release -o "/var/www/${site_name}" >/dev/null
rm -rf "/tmp/${site_name}"
chown -R ftpuser:ftpuser "/var/www/${site_name}" 2>/dev/null || true
echo -e "\e[32m[OK]\e[0m Built sample application."

echo -e "\e[34m[Info]\e[0m Configuring Nginx..."
mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled
if [[ ! -f /etc/nginx/conf.d/dotnet_upgrade_map.conf ]]; then
  cat <<EOMAP >/etc/nginx/conf.d/dotnet_upgrade_map.conf
map \$http_connection \$connection_upgrade {
  "~*Upgrade" \$http_connection;
  default keep-alive;
}
EOMAP
fi

cat <<EONGINX >"/etc/nginx/sites-available/${site_name}"
server {
  listen        ${site_port};
  server_name   ${site_name}.com *.${site_name}.com localhost;
  location / {
      proxy_pass         http://127.0.0.1:${next_i_port}/;
      proxy_http_version 1.1;
      proxy_set_header   Upgrade \$http_upgrade;
      proxy_set_header   Connection \$connection_upgrade;
      proxy_set_header   Host \$host;
      proxy_cache_bypass \$http_upgrade;
      proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto \$scheme;
  }
}
EONGINX
ln -sf "/etc/nginx/sites-available/${site_name}" "/etc/nginx/sites-enabled/${site_name}"
nginx -t >/dev/null 2>&1
systemctl reload nginx 2>/dev/null || systemctl restart nginx
echo -e "\e[32m[OK]\e[0m Nginx configured and reloaded."

echo -e "\e[34m[Info]\e[0m Creating systemd service..."
cat <<EOSVC >"/etc/systemd/system/kestrel-${site_name}.service"
[Unit]
Description=.NET Web API App (${site_name}) running on Linux
After=network.target

[Service]
WorkingDirectory=/var/www/${site_name}
ExecStart=/usr/bin/dotnet /var/www/${site_name}/${site_name}.dll --urls http://127.0.0.1:${next_i_port}
Restart=always
# Restart service after 10 seconds if the dotnet service crashes:
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=dotnet-${site_name}
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
Environment=ASPNETCORE_URLS=http://127.0.0.1:${next_i_port}

[Install]
WantedBy=multi-user.target
EOSVC

systemctl daemon-reload
systemctl enable --now "kestrel-${site_name}"
echo -e "\e[32m[OK]\e[0m Service kestrel-${site_name} started."

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP="${IP:-localhost}"
echo -e "\n\e[32mSuccessfully added site '${site_name}'!\e[0m"
echo -e "  External Link: \e[1;36mhttp://${IP}:${site_port}\e[0m"
echo -e "  Internal Port: \e[1;33m${next_i_port}\e[0m"
echo -e "  Directory:     \e[1;37m/var/www/${site_name}\e[0m"
echo -e "  Service:       \e[1;37mkestrel-${site_name}\e[0m"
echo -e "\nUpload your published project to \e[1;37m/var/www/${site_name}\e[0m via FTP."
EOF
chmod +x /usr/local/bin/add-dotnet-site
msg_ok "Installed Site Management Utility (add-dotnet-site)"

msg_info "Installing Site Removal Utility"
cat <<'EOF' >/usr/local/bin/remove-dotnet-site
#!/usr/bin/env bash
# remove-dotnet-site - Helper utility to remove an ASP.NET Core Web API site from this LXC
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31mThis script must be run as root.\e[0m" >&2
  exit 1
fi

echo -e "\e[1;36m=== Remove ASP.NET Core Web API Site ===\e[0m\n"

SITES=()
for svc in /etc/systemd/system/kestrel-*.service; do
  [ -f "$svc" ] || continue
  name=$(basename "$svc" .service | sed 's/kestrel-//')
  if [ "$name" = "aspnetapi" ]; then
    dll=$(grep 'ExecStart=' "$svc" 2>/dev/null | head -n1 | sed -n 's/.*\/var\/www\/[^\/]*\/\([^. ]*\)\.dll.*/\1/p')
    name="${dll:-default}"
  fi
  SITES+=("$name")
done

if [[ ${#SITES[@]} -eq 0 ]]; then
  echo -e "\e[33mNo configured .NET sites found.\e[0m"
  exit 0
fi

site_name="${1:-}"

if [[ -z "$site_name" ]]; then
  echo "Available sites:"
  for i in "${!SITES[@]}"; do
    s="${SITES[$i]}"
    e_port=$(grep 'listen ' "/etc/nginx/sites-available/$s" 2>/dev/null | head -n1 | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p' || echo "80")
    echo "  $((i + 1))) $s (Port: $e_port)"
  done
  echo ""
  read -r -p "Enter site name or number to remove: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SITES[@]} )); then
    site_name="${SITES[$((choice - 1))]}"
  else
    site_name="$(echo "$choice" | sed 's/[^a-zA-Z0-9._-]//g')"
  fi
fi

found=0
for s in "${SITES[@]}"; do
  if [[ "$s" == "$site_name" ]]; then
    found=1
    break
  fi
done

if [[ $found -eq 0 ]]; then
  if [[ ! -f "/etc/systemd/system/kestrel-${site_name}.service" && ! -f "/etc/nginx/sites-available/${site_name}" && ! -d "/var/www/${site_name}" ]]; then
    echo -e "\e[31mSite '${site_name}' not found.\e[0m" >&2
    exit 1
  fi
fi

echo -e "\n\e[33mWARNING: This will permanently remove the service and Nginx configuration for '${site_name}'.\e[0m"
read -r -p "Are you sure you want to proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
  echo "Operation cancelled."
  exit 0
fi

echo -e "\n\e[34m[Info]\e[0m Stopping and removing service..."
if [[ -f "/etc/systemd/system/kestrel-${site_name}.service" ]]; then
  systemctl stop "kestrel-${site_name}" 2>/dev/null || true
  systemctl disable "kestrel-${site_name}" 2>/dev/null || true
  rm -f "/etc/systemd/system/kestrel-${site_name}.service"
elif [[ "$site_name" == "default" || "$site_name" == "aspnetapi" ]]; then
  systemctl stop kestrel-aspnetapi 2>/dev/null || true
  systemctl disable kestrel-aspnetapi 2>/dev/null || true
  rm -f /etc/systemd/system/kestrel-aspnetapi.service
fi
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
echo -e "\e[32m[OK]\e[0m Service removed."

echo -e "\e[34m[Info]\e[0m Removing Nginx configuration..."
rm -f "/etc/nginx/sites-enabled/${site_name}"
rm -f "/etc/nginx/sites-available/${site_name}"
if [[ "$site_name" == "default" || "$site_name" == "aspnetapi" ]]; then
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-available/default
fi
nginx -t >/dev/null 2>&1 && (systemctl reload nginx 2>/dev/null || systemctl restart nginx)
echo -e "\e[32m[OK]\e[0m Nginx configuration removed and reloaded."

read -r -p "Delete application directory (/var/www/${site_name})? [y/N]: " del_files
if [[ "$del_files" =~ ^[yY]([eE][sS])?$ ]]; then
  rm -rf "/var/www/${site_name}"
  if [[ "$site_name" == "default" || "$site_name" == "aspnetapi" ]]; then
    rm -rf /var/www/html
  fi
  echo -e "\e[32m[OK]\e[0m Application files deleted."
else
  echo -e "\e[33m[Info]\e[0m Application files kept at /var/www/${site_name}."
fi

echo -e "\n\e[32mSite '${site_name}' was successfully removed.\e[0m"
EOF
chmod +x /usr/local/bin/remove-dotnet-site
msg_ok "Installed Site Removal Utility (remove-dotnet-site)"

msg_info "Installing Site Reset Utility"
cat <<'EOF' >/usr/local/bin/reset-dotnet-site
#!/usr/bin/env bash
# reset-dotnet-site - Helper utility to stop, start, and check status of an ASP.NET Core site
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31mThis script must be run as root.\e[0m" >&2
  exit 1
fi

echo -e "\e[1;36m=== Reset ASP.NET Core Web API Site ===\e[0m\n"

SITES=()
for svc in /etc/systemd/system/kestrel-*.service; do
  [ -f "$svc" ] || continue
  name=$(basename "$svc" .service | sed 's/kestrel-//')
  if [ "$name" = "aspnetapi" ]; then
    dll=$(grep 'ExecStart=' "$svc" 2>/dev/null | head -n1 | sed -n 's/.*\/var\/www\/[^\/]*\/\([^. ]*\)\.dll.*/\1/p')
    name="${dll:-default}"
  fi
  SITES+=("$name")
done

site_name="${1:-}"

if [[ -z "$site_name" ]]; then
  if [[ ${#SITES[@]} -eq 0 ]]; then
    echo -e "\e[33mNo configured .NET sites found.\e[0m"
    exit 0
  fi

  echo "Available sites:"
  for i in "${!SITES[@]}"; do
    s="${SITES[$i]}"
    e_port=$(grep 'listen ' "/etc/nginx/sites-available/$s" 2>/dev/null | head -n1 | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p' || echo "80")
    echo "  $((i + 1))) $s (Port: $e_port)"
  done
  echo ""
  read -r -p "Enter site name or number to reset: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SITES[@]} )); then
    site_name="${SITES[$((choice - 1))]}"
  else
    site_name="$(echo "$choice" | sed 's/[^a-zA-Z0-9._-]//g')"
  fi
fi

svc_name="kestrel-${site_name}"
if [[ ! -f "/etc/systemd/system/${svc_name}.service" ]]; then
  if [[ ("$site_name" == "default" || "$site_name" == "aspnetapi") && -f "/etc/systemd/system/kestrel-aspnetapi.service" ]]; then
    svc_name="kestrel-aspnetapi"
  else
    echo -e "\e[31mService '${svc_name}' not found.\e[0m" >&2
    exit 1
  fi
fi

echo -e "\e[34m[Info]\e[0m Stopping ${svc_name}..."
systemctl stop "$svc_name"

echo -e "\e[34m[Info]\e[0m Starting ${svc_name}..."
systemctl start "$svc_name"

echo -e "\e[32m[OK]\e[0m Service reset. Status:\n"
systemctl status "$svc_name" --no-pager || true
EOF
chmod +x /usr/local/bin/reset-dotnet-site
msg_ok "Installed Site Reset Utility (reset-dotnet-site)"

msg_info "Installing Site Rename Utility"
cat <<'EOF' >/usr/local/bin/rename-dotnet-site
#!/usr/bin/env bash
# rename-dotnet-site - Helper utility to rename an existing ASP.NET Core site to a new assembly name
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31mThis script must be run as root.\e[0m" >&2
  exit 1
fi

echo -e "\e[1;36m=== Rename ASP.NET Core Web API Site ===\e[0m\n"

SITES=()
for svc in /etc/systemd/system/kestrel-*.service; do
  [ -f "$svc" ] || continue
  name=$(basename "$svc" .service | sed 's/kestrel-//')
  if [ "$name" = "aspnetapi" ]; then
    dll=$(grep 'ExecStart=' "$svc" 2>/dev/null | head -n1 | sed -n 's/.*\/var\/www\/[^\/]*\/\([^. ]*\)\.dll.*/\1/p')
    name="${dll:-default}"
  fi
  SITES+=("$name")
done

if [[ ${#SITES[@]} -eq 0 ]]; then
  echo -e "\e[33mNo configured .NET sites found.\e[0m"
  exit 0
fi

old_name="${1:-}"

if [[ -z "$old_name" ]]; then
  echo "Available sites:"
  for i in "${!SITES[@]}"; do
    s="${SITES[$i]}"
    e_port=$(grep 'listen ' "/etc/nginx/sites-available/$s" 2>/dev/null | head -n1 | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p' || echo "80")
    echo "  $((i + 1))) $s (Port: $e_port)"
  done
  echo ""
  read -r -p "Enter site name or number to rename: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SITES[@]} )); then
    old_name="${SITES[$((choice - 1))]}"
  else
    old_name="$(echo "$choice" | sed 's/[^a-zA-Z0-9._-]//g')"
  fi
fi

old_svc_file=""
if [[ -f "/etc/systemd/system/kestrel-${old_name}.service" ]]; then
  old_svc_file="/etc/systemd/system/kestrel-${old_name}.service"
  old_svc_name="kestrel-${old_name}"
elif [[ ("$old_name" == "default" || "$old_name" == "aspnetapi") && -f "/etc/systemd/system/kestrel-aspnetapi.service" ]]; then
  old_svc_file="/etc/systemd/system/kestrel-aspnetapi.service"
  old_svc_name="kestrel-aspnetapi"
else
  echo -e "\e[31mSite '${old_name}' not found.\e[0m" >&2
  exit 1
fi

new_name="${2:-}"
while true; do
  if [[ -z "$new_name" ]]; then
    read -r -p "Enter new entry assembly name for '${old_name}' (without .dll, e.g. NewApp.Web): " new_name
  fi
  new_name="$(echo "$new_name" | sed 's/[^a-zA-Z0-9._-]//g')"
  if [[ -z "$new_name" ]]; then
    echo -e "\e[31mNew assembly name cannot be empty.\e[0m"
    new_name=""
    continue
  fi
  if [[ "$new_name" == "$old_name" ]]; then
    echo -e "\e[31mNew name must be different from the old name.\e[0m"
    new_name=""
    continue
  fi
  if [[ -d "/var/www/${new_name}" ]]; then
    echo -e "\e[31mDirectory /var/www/${new_name} already exists. Please choose a different name.\e[0m"
    new_name=""
    continue
  fi
  if [[ -f "/etc/systemd/system/kestrel-${new_name}.service" ]]; then
    echo -e "\e[31mService kestrel-${new_name}.service already exists. Please choose a different name.\e[0m"
    new_name=""
    continue
  fi
  break
done

echo -e "\n\e[33mRenaming '${old_name}' -> '${new_name}':\e[0m"
echo "  - Service: kestrel-${old_name} -> kestrel-${new_name}"
echo "  - Directory: /var/www/${old_name} -> /var/www/${new_name}"
echo "  - Nginx: /etc/nginx/sites-available/${new_name}"
read -r -p "Are you sure you want to proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
  echo "Operation cancelled."
  exit 0
fi

i_port=$(grep '127.0.0.1:' "$old_svc_file" 2>/dev/null | head -n1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
i_port="${i_port:-5000}"

old_dir=$(grep 'WorkingDirectory=' "$old_svc_file" 2>/dev/null | head -n1 | cut -d= -f2)
old_dir="${old_dir:-/var/www/${old_name}}"

e_port="80"
if [[ -f "/etc/nginx/sites-available/${old_name}" ]]; then
  e_port=$(grep 'listen ' "/etc/nginx/sites-available/${old_name}" 2>/dev/null | head -n1 | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p' || echo "80")
elif [[ -f "/etc/nginx/sites-available/default" ]]; then
  e_port=$(grep 'listen ' "/etc/nginx/sites-available/default" 2>/dev/null | head -n1 | sed -n 's/.*listen[[:space:]]*\([0-9]*\).*/\1/p' || echo "80")
fi

echo -e "\n\e[34m[Info]\e[0m Stopping old service ${old_svc_name}..."
systemctl stop "$old_svc_name" 2>/dev/null || true
systemctl disable "$old_svc_name" 2>/dev/null || true
rm -f "$old_svc_file"

new_dir="/var/www/${new_name}"
echo -e "\e[34m[Info]\e[0m Renaming directory: ${old_dir} -> ${new_dir}..."
if [[ -d "$old_dir" ]]; then
  mv "$old_dir" "$new_dir"
else
  mkdir -p "$new_dir"
fi

for ext in dll pdb deps.json runtimeconfig.json; do
  if [[ -f "${new_dir}/${old_name}.${ext}" && ! -f "${new_dir}/${new_name}.${ext}" ]]; then
    mv "${new_dir}/${old_name}.${ext}" "${new_dir}/${new_name}.${ext}" 2>/dev/null || true
  fi
done
chown -R ftpuser:ftpuser "$new_dir" 2>/dev/null || true

echo -e "\e[34m[Info]\e[0m Updating Nginx configuration..."
rm -f "/etc/nginx/sites-enabled/${old_name}" "/etc/nginx/sites-available/${old_name}"
if [[ "$old_name" == "default" || "$old_name" == "aspnetapi" ]]; then
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
fi

cat <<EONGINX >"/etc/nginx/sites-available/${new_name}"
server {
  listen        ${e_port};
  server_name   ${new_name}.com *.${new_name}.com localhost;
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
EONGINX
ln -sf "/etc/nginx/sites-available/${new_name}" "/etc/nginx/sites-enabled/${new_name}"
nginx -t >/dev/null 2>&1
systemctl reload nginx 2>/dev/null || systemctl restart nginx
echo -e "\e[32m[OK]\e[0m Nginx updated."

echo -e "\e[34m[Info]\e[0m Creating new systemd service kestrel-${new_name}..."
cat <<EOSVC >"/etc/systemd/system/kestrel-${new_name}.service"
[Unit]
Description=.NET Web API App (${new_name}) running on Linux
After=network.target

[Service]
WorkingDirectory=/var/www/${new_name}
ExecStart=/usr/bin/dotnet /var/www/${new_name}/${new_name}.dll --urls http://127.0.0.1:${i_port}
Restart=always
# Restart service after 10 seconds if the dotnet service crashes:
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=dotnet-${new_name}
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
Environment=ASPNETCORE_URLS=http://127.0.0.1:${i_port}

[Install]
WantedBy=multi-user.target
EOSVC

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
systemctl enable --now "kestrel-${new_name}"
echo -e "\e[32m[OK]\e[0m Service kestrel-${new_name} started."

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP="${IP:-localhost}"
echo -e "\n\e[32mSuccessfully renamed site '${old_name}' to '${new_name}'!\e[0m"
echo -e "  External Link: \e[1;36mhttp://${IP}:${e_port}\e[0m"
echo -e "  Internal Port: \e[1;33m${i_port}\e[0m"
echo -e "  Directory:     \e[1;37m/var/www/${new_name}\e[0m"
echo -e "  Service:       \e[1;37mkestrel-${new_name}\e[0m"
echo -e "\nUpload your published project to \e[1;37m/var/www/${new_name}\e[0m via FTP."
EOF
chmod +x /usr/local/bin/rename-dotnet-site
msg_ok "Installed Site Rename Utility (rename-dotnet-site)"

echo -e "\n${INFO}${YW}Configured .NET ASP WebAPI Applications:${CL}"
printf "\n  ${BL}%-20s %-35s %-15s${CL}\n" "Assembly Name" "External Link" "Internal Port"
printf "  ${BL}%-20s %-35s %-15s${CL}\n" "--------------------" "-----------------------------------" "---------------"
printf "  %-20s %-35s %-15s\n\n" "${var_project_name}" "http://${LOCAL_IP}" "5000"
echo -e "${INFO}${YW}Manage sites anytime: ${GN}add-dotnet-site${YW} | ${RD}remove-dotnet-site${YW} | ${BL}rename-dotnet-site${YW} | ${GN}reset-dotnet-site${CL}\n"

motd_ssh
customize
cleanup_lxc
