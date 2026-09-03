# Dotnet X ASP Web API Multi LXC Guide

A complete guide for deploying, managing, and hosting multiple independent ASP.NET Core Web API applications within a single LXC container on Proxmox VE using the **Dotnet X ASP Web API Multi** (`dotnetxaspwebapimulti`) script.

---

## 📋 Overview

The **Dotnet X ASP Web API Multi** script creates a consolidated, multi-tenant Ubuntu 24.04 LXC container designed to host several ASP.NET Core applications side-by-side with full process isolation:

- **Multi-Site Architecture**: Each application runs as its own managed systemd service (`kestrel-<site_name>.service`), listens on its own localhost port (`5000`, `5001`, `5002`...), and is exposed through Nginx on separate external ports (`8080`, `8081`, `8082`...).
- **.NET SDK/Runtime**: Supports .NET 9.0, .NET 10.0, or both installed side-by-side.
- **Nginx Reverse Proxy**: Pre-configured reverse proxy with WebSocket/HTTP upgrade support (`$http_connection` map) routing traffic to each application.
- **vsftpd FTP Server**: FTP server rooted at `/var/www` so that all site directories (`/var/www/<site1>`, `/var/www/<site2>`) are visible and accessible in a single FTP session.
- **Dynamic Login Status Dashboard**: Displays an interactive, color-coded health and status table of all hosted applications on every console (`pct enter`), noVNC, or SSH login.
- **Built-in CLI Management Suite (`/usr/local/bin/`)**:
  - `add-dotnet-site`: Interactively adds, scaffolds, compiles, reverse-proxies, and starts an additional ASP.NET Core application.
  - `remove-dotnet-site`: Interactively selects, confirms, and tears down an existing site (stops service, deletes Nginx reverse proxy, and optionally removes files).
  - `reset-dotnet-site`: Restarts and checks the live status of any hosted application.

---

## 🚀 Quick Start

Run the installation script in your Proxmox VE shell:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/ct/dotnetxaspwebapimulti.sh)"
```

---

## ⚙️ Container Specifications & Defaults

| Resource / Setting | Default Value | Notes |
| :--- | :--- | :--- |
| **Operating System** | Ubuntu 24.04 LTS | Base container distribution |
| **CPU Allocation** | 2 vCPUs | Scalable for multiple concurrent APIs |
| **Memory (RAM)** | 2048 MB | Sufficient for multiple active .NET runtimes |
| **Disk Size** | 10 GB | Stores multiple project builds and logs |
| **Privileged** | Yes (`var_unprivileged=0`) | Standard for containerized hosting |
| **Primary Port** | 8080 | First site external port; subsequent sites increment (8081, 8082...) |
| **Internal Kestrel Ports** | 5000 | First site internal port; subsequent sites increment (5001, 5002...) |

---

## 🔧 Installation Settings & Variables

You can run the installation interactively or pass environment variables for automated deployments:

### Supported Variables

| Variable | Description | Allowed Values / Examples | Default |
| :--- | :--- | :--- | :--- |
| `var_dotnet_version` | Target .NET SDK version | `9.0`, `10.0`, `Both` | `9.0` |
| `var_site_count` | Number of initial sites to create | Integer (`1` to `10`) | `2` |

### Interactive Installation Flow
When prompted during setup:
1. **Choose .NET Version**: Select whether to install .NET 9.0, 10.0, or Both.
2. **Number of Sites**: Enter how many initial applications to scaffold (e.g. `3`).
3. **Site Configuration Loop**: For each site, you will be prompted for:
   - **Entry Assembly Name**: The name of the project assembly without `.dll` (e.g. `TrackMyTracksBlazor`, `CircuitDex`, `GlassyEyes.Web`).
   - **External HTTP Port**: The port Nginx listens on (defaults to `8080`, `8081`, `8082`...).

---

## 🌐 Multi-Site Architecture & Port Routing

Each application is isolated into its own directory, internal port, and systemd service:

| Site Name | Directory | External Port | Internal Port | Systemd Service |
| :--- | :--- | :--- | :--- | :--- |
| **Site 1** | `/var/www/<site1>` | `http://<IP>:8080` | `127.0.0.1:5000` | `kestrel-<site1>.service` |
| **Site 2** | `/var/www/<site2>` | `http://<IP>:8081` | `127.0.0.1:5001` | `kestrel-<site2>.service` |
| **Site 3** | `/var/www/<site3>` | `http://<IP>:8082` | `127.0.0.1:5002` | `kestrel-<site3>.service` |

### Port Binding Precedence
To prevent port conflicts, each systemd service starts with:
```bash
ExecStart=/usr/bin/dotnet /var/www/<site>/<site>.dll --urls http://127.0.0.1:<internal_port>
```
The `--urls` command-line argument has highest precedence in ASP.NET Core, guaranteeing that applications bind only to their designated internal port even if an uploaded `appsettings.json` contains a default port binding.

### Pre-Compiled Starter Application
Each defined site is automatically compiled with a starter minimal API returning rendered HTML. Browsing to `http://<IP>:<port>` immediately confirms that the site is active and routing correctly.

---

## 📤 Deploying Your Applications via FTP

### 1. Publish Each Project
From Visual Studio or the command line:
```bash
dotnet publish -c Release -o ./publish
```
> [!IMPORTANT]
> The primary entry DLL must match the assembly name specified for that site (e.g. `CircuitDex.dll`).

### 2. Connect via FTP
1. Display your container's FTP credentials:
   ```bash
   cat ~/ftp.creds
   ```
2. In your FTP client (FileZilla, WinSCP, Cyberduck):
   - **Host**: `<CONTAINER_IP>`
   - **Port**: `21`
   - **Username**: `ftpuser`
   - **Password**: *(found in `~/ftp.creds`)*
3. You will see the `/var/www` directory containing folders for each site (`TrackMyTracksBlazor/`, `CircuitDex/`, `GlassyEyes.Web/`).
4. Upload each project's published files into its respective folder, overwriting the starter application.

### 3. Restart the Application
Restart the updated application:
```bash
reset-dotnet-site CircuitDex
```

---

## 🛠️ Site Management Suite (`/usr/local/bin/`)

Three dedicated management tools are pre-installed in `/usr/local/bin/`:

### 1. `add-dotnet-site`
Adds another site to the container at any time without reinstalling.

```bash
add-dotnet-site
```

- **SDK Auto-Detection**: Inspects `dotnet --list-sdks` and selects `net10.0` or `net9.0`.
- **Port Auto-Allocation**: Scans existing services and automatically proposes the next available internal port (e.g. `5003`) and external port (e.g. `8083`).
- **Input Validation**: Sanitizes assembly names and verifies no directory or service collisions exist.
- **Scaffolding**: Creates `/var/www/<site>`, writes sample project, publishes binaries, and sets `ftpuser:ftpuser` permissions.
- **Reverse Proxy**: Generates and enables `/etc/nginx/sites-available/<site>` and reloads Nginx.
- **Systemd**: Generates, reloads, and starts `kestrel-<site>.service`.
- **Dashboard Update**: Immediately appears in the dynamic login status table.

---

### 2. `remove-dotnet-site`
Safely removes an existing site with confirmation safeguards.

```bash
# Interactive selection menu:
remove-dotnet-site

# Or direct invocation by name:
remove-dotnet-site CircuitDex
```

- **Interactive Menu**: Displays an enumerated list of all configured sites and their external ports.
- **Safety Confirmation**: Requires explicit confirmation (`[y/N]`) before proceeding.
- **Service Removal**: Stops, disables, and deletes `kestrel-<site>.service`, then runs `systemctl daemon-reload`.
- **Nginx Removal**: Deletes `/etc/nginx/sites-enabled/<site>` and `/etc/nginx/sites-available/<site>` and reloads Nginx.
- **File Deletion Option**: Asks if you want to delete the files at `/var/www/<site>` or keep them on disk.

---

### 3. `reset-dotnet-site`
Stops, starts, and checks the status of an application.

```bash
# Direct invocation:
reset-dotnet-site GlassyEyes.Web

# Or interactive menu:
reset-dotnet-site
```

- **Actions**: Executes `systemctl stop`, `systemctl start`, and outputs the live `systemctl status` with `--no-pager`.

---

## 📊 Dynamic Login Status Dashboard

On every console or SSH login, `/etc/profile.d/99-dotnet-sites.sh` dynamically scans all running services and outputs a live status table:

```text
=== Dotnet X ASP WebAPI Status ===
  Assembly Name          External Link                      Internal     Status    
  ---------------------- ---------------------------------- ------------ ----------
  TrackMyTracksBlazor    http://192.168.1.150:8080          5000         Active    
  CircuitDex             http://192.168.1.150:8081          5001         Active    
  GlassyEyes.Web         http://192.168.1.150:8082          5002         Active    
```

---

## 🔍 Useful Commands & Diagnostics

### View Live Application Logs
```bash
journalctl -u kestrel-<site_name> -f
```

### Check All Kestrel Services
```bash
systemctl list-units "kestrel-*"
```

### Test Nginx Configuration
```bash
nginx -t
```
