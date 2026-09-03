# Dotnet X ASP Web API LXC Guide

A complete guide for deploying, managing, and hosting ASP.NET Core Web API applications on Proxmox VE using the **Dotnet X ASP Web API** (`dotnetxaspwebapi`) and **Dotnet X ASP Web API Multi** (`dotnetxaspwebapimulti`) container scripts.

---

## 📋 Overview

The Dotnet X ASP Web API scripts create an optimized, lightweight Ubuntu 24.04 LXC container pre-configured with:
- **.NET SDK/Runtime** (choice of .NET 9.0, .NET 10.0, or both).
- **Nginx Reverse Proxy**: Automatically proxies external HTTP requests to internal Kestrel endpoints with WebSocket/HTTP upgrade support.
- **Kestrel Systemd Services**: Runs each application as a managed, auto-restarting systemd service.
- **vsftpd FTP Deployment Server**: Allows straightforward uploading of published binaries directly into site directories.
- **Interactive Login Status Dashboard**: Dynamically checks and displays all hosted applications and their health upon every console or SSH login.
- **Site Management Suite (`/usr/local/bin/`)**:
  - `add-dotnet-site`: Interactively adds, compiles, reverse-proxies, and starts a new ASP.NET Core site.
  - `remove-dotnet-site`: Interactively selects, confirms, and tears down a site (service, Nginx configuration, and files).
  - `reset-dotnet-site`: Restarts and checks the live status of a site's systemd service.

---

## 🚀 Quick Start

Run the desired script in your Proxmox VE Shell:

### Single-Site Container (`dotnetxaspwebapi`)
Recommended for single-service workloads or standalone APIs:
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/ct/dotnetxaspwebapi.sh)"
```

### Multi-Site Container (`dotnetxaspwebapimulti`)
Recommended when hosting multiple independent APIs on different external ports on a single container:
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/ct/dotnetxaspwebapimulti.sh)"
```

---

## ⚙️ Container Specifications & Defaults

| Setting | Single Site (`dotnetxaspwebapi`) | Multi-Site (`dotnetxaspwebapimulti`) |
| :--- | :--- | :--- |
| **OS** | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| **CPU** | 1 vCPU | 2 vCPU |
| **RAM** | 1024 MB | 2048 MB |
| **Disk** | 8 GB | 10 GB |
| **Privileged** | Yes (`var_unprivileged=0`) | Yes (`var_unprivileged=0`) |
| **Default HTTP Port** | 80 | 8080 (then 8081, 8082...) |
| **Default Kestrel Port** | 5000 | 5000 (then 5001, 5002...) |

---

## 🔧 Installation Settings & Variables

You can run the installation interactively or pass environment variables for automated deployments:

### Supported Variables

| Variable | Description | Allowed Values / Examples | Default |
| :--- | :--- | :--- | :--- |
| `var_dotnet_version` | Target .NET version | `9.0`, `10.0`, `Both` | `9.0` |
| `var_project_name` | Single-site assembly name *(without `.dll`)* | e.g. `MyApi.Web` | `default` |
| `var_site_count` | Number of initial sites *(multi-site only)* | Integer (`1` to `10`) | `2` |

---

## 🌐 Architecture & Port Mapping

Each hosted application uses a two-tier architecture:
1. **Nginx** listens on the configured **external port** (e.g. `8080`) and terminates client HTTP requests.
2. **Kestrel** listens on an isolated **internal localhost port** (e.g. `127.0.0.1:5000`) specified on `ExecStart` via `--urls http://127.0.0.1:<port>`.

```
Client Request -> [Nginx Reverse Proxy :8080] -> [Kestrel Service :5000] -> /var/www/<site>/<site>.dll
Client Request -> [Nginx Reverse Proxy :8081] -> [Kestrel Service :5001] -> /var/www/<site2>/<site2>.dll
```

### Initial Starter Application
During container setup, the installer automatically generates, compiles, and runs a starter minimal API for every defined site. Visiting `http://<CONTAINER_IP>:<EXTERNAL_PORT>` in your browser immediately confirms that Nginx, Kestrel, and the systemd service are working properly.

---

## 📤 Deploying Your Application

### 1. Publish Your Project
Publish your ASP.NET Core project from your development machine:
```bash
dotnet publish -c Release -o ./publish
```

> [!IMPORTANT]
> Ensure your entry assembly filename matches the name configured for the site (e.g. `CircuitDex.dll`).

### 2. Connect via FTP
The container includes a configured FTP server (`vsftpd`).
1. Find your FTP credentials inside the container:
   ```bash
   cat ~/ftp.creds
   ```
2. Connect to the container's IP using your preferred FTP client (FileZilla, WinSCP, Cyberduck):
   - **Protocol**: FTP (Plain FTP)
   - **Host**: `<CONTAINER_IP>`
   - **Port**: `21`
   - **Username**: `ftpuser`
   - **Password**: *(found in `~/ftp.creds`)*
3. The FTP root directory is `/var/www`. You will see the folder for each site:
   - For single-site default: `/var/www/html`
   - For multi-site / additional sites: `/var/www/<site_name>`
4. Upload your published files into the site's directory, overwriting the starter files.

### 3. Restart the Service
After uploading new binaries, restart the service using `reset-dotnet-site`:
```bash
reset-dotnet-site <site_name>
```

---

## 🛠️ Site Management CLI Utilities

Every container includes three management scripts located in `/usr/local/bin/` so they are always available in `$PATH`:

### 1. `add-dotnet-site`
Adds a new ASP.NET Core Web API site to the container.

```bash
add-dotnet-site
```

**What it does:**
- Automatically detects the installed .NET SDK (`net10.0` or `net9.0`).
- Automatically scans existing services and proposes the next available internal Kestrel port (`5001`, `5002`...) and external HTTP port (`8080`, `8081`, `8082`...).
- Prompts for the entry assembly name (without `.dll`).
- Creates `/var/www/<site_name>`, scaffolds and publishes a starter project, and sets `ftpuser:ftpuser` permissions.
- Creates `/etc/nginx/sites-available/<site_name>`, links it to `sites-enabled`, tests configuration, and reloads Nginx.
- Creates `/etc/systemd/system/kestrel-<site_name>.service` and enables/starts it.
- Dynamically integrates with the login status dashboard.

---

### 2. `remove-dotnet-site`
Safely removes an existing site with confirmation prompts.

```bash
# Interactive selection:
remove-dotnet-site

# Or specify by name:
remove-dotnet-site MySiteName
```

**What it does:**
- Displays an enumerated list of currently configured sites with their external ports.
- Prompts for confirmation (`[y/N]`) before proceeding.
- Stops and disables `kestrel-<site_name>.service`, removes the unit file, and reloads systemd.
- Removes `/etc/nginx/sites-available/<site_name>` and `/etc/nginx/sites-enabled/<site_name>`, and reloads Nginx.
- Prompts whether to delete the files at `/var/www/<site_name>` or keep them on disk.

---

### 3. `reset-dotnet-site`
Restarts a site's systemd service and displays its live status and log output.

```bash
# Direct restart by name:
reset-dotnet-site MySiteName

# Or interactive menu:
reset-dotnet-site
```

**What it does:**
- Stops the service: `systemctl stop kestrel-<site_name>`
- Starts the service: `systemctl start kestrel-<site_name>`
- Displays status: `systemctl status kestrel-<site_name> --no-pager`

---

## 📊 Dynamic Login Status Dashboard

Upon logging into the container console (`pct enter <CTID>`, Proxmox noVNC web console, or SSH), a status table is dynamically generated by `/etc/profile.d/99-dotnet-sites.sh`:

```text
=== Dotnet X ASP WebAPI Status ===
  Assembly Name          External Link                      Internal     Status    
  ---------------------- ---------------------------------- ------------ ----------
  TrackMyTracksBlazor    http://192.168.1.150:8080          5000         Active    
  CircuitDex             http://192.168.1.150:8081          5001         Active    
  GlassyEyes.Web         http://192.168.1.150:8082          5002         Active    
```

Whenever a site is added or removed using the CLI tools, this dashboard updates automatically.

---

## 🔍 Troubleshooting & Useful Commands

### Check System Logs
View real-time application logs from Kestrel:
```bash
journalctl -u kestrel-<site_name> -f
```

### Test Nginx Configuration
Verify Nginx syntax after manual configuration changes:
```bash
nginx -t
```

### Port Conflicts
Each Kestrel service is launched with `--urls http://127.0.0.1:<port>`. This flag has higher precedence than `appsettings.json`, ensuring the app binds to its assigned localhost port even if your published `appsettings.json` contains a default `"Urls": "http://localhost:5000"`.
