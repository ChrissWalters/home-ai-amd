# home-ai-amd

Local AI infrastructure on AMD hardware running Linux (tested on CachyOS / Arch).  
Ollama runs natively on the host, all other services run in Docker containers – network-isolated and without uncontrolled "phoning home".

---

## Repository Contents

```
home-ai-amd/
├── README.md
├── ollama-firewall.sh      # Firewall toggle for Ollama (open/close)
├── ollama-power.sh         # Ollama start / stop / status
└── ai-stack/
    └── docker-compose.yml  # Open WebUI + n8n
```

---

## Prerequisites

| Component | Recommendation / Tested with |
|---|---|
| Operating System | CachyOS / Arch Linux |
| GPU | AMD RX 7800 XT (16 GB VRAM) |
| RAM | 32 GB |
| CPU | AMD Ryzen 7 7700X |
| Docker | 29.x + Compose 5.x |

> Other AMD GPUs with ROCm support also work – GPU-specific values (HSA_OVERRIDE_GFX_VERSION) may need to be adjusted accordingly.

---

## Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  HOST (CachyOS)                                             │
│                                                             │
│  Ollama :11434  ◄──────────── host.docker.internal          │
│  (0.0.0.0)                                                  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Docker                                              │   │
│  │                                                      │   │
│  │  ai_host   (172.30.0.0/24)  Bridge with host-gateway │   │
│  │  ai_intern (172.31.0.0/24)  no internet (internal)   │   │
│  │  ai_extern (automatic)      optional, with internet  │   │
│  │                                                      │   │
│  │  open-webui ──► ai_intern + ai_host                  │   │
│  │  n8n        ──► ai_intern + ai_host                  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

| Network | Subnet | Internet | Purpose |
|---|---|---|---|
| `ai_host` | 172.30.0.0/24 | no | Container → Ollama on the host |
| `ai_intern` | 172.31.0.0/24 | no | Internal communication between containers |
| `ai_extern` | automatic | **yes** | Optional internet access (e.g. first start, n8n webhooks) |

---

## Step-by-Step Installation

### 1. Clone the Repository

```bash
cd /TARGET-DIRECTORY/
git clone https://github.com/YOUR-USERNAME/home-ai-amd.git
cd home-ai-amd
```

---

### 2. Set Up User Groups

To allow your user to access the AMD GPU and Docker:

```bash
sudo usermod -aG video,render,docker $USER
```

> **Important:** Log out and log back in afterwards (or reboot) – the groups only take effect after a new session.

---

### 3. Install Ollama Natively (with ROCm, Arch/CachyOS)

```bash
sudo pacman -S rocm-hip-sdk rocm-opencl-sdk ollama-rocm
```

---

### 4. Configure Ollama

Ollama is configured via a systemd drop-in file. This file controls GPU assignment, privacy, and performance.

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo nano /etc/systemd/system/ollama.service.d/custom.conf
```

Insert the following content:

```ini
[Service]
# ── AMD GPU (example: RX 7800 XT = RDNA3 = gfx1100) ────────────────────────
# Values may need to be adjusted for your specific GPU!
Environment="HSA_OVERRIDE_GFX_VERSION=11.0.0"
Environment="ROCR_VISIBLE_DEVICES=0"

# ── Privacy ──────────────────────────────────────────────────────────────────
Environment="OLLAMA_NO_CLOUD=1"
Environment="OLLAMA_NOHISTORY=1"

# ── Network ──────────────────────────────────────────────────────────────────
# 0.0.0.0 is required so that Docker containers can access Ollama
# via host.docker.internal. Ollama is still only accessible locally,
# as no external port forwarding is configured.
Environment="OLLAMA_HOST=0.0.0.0:11434"

# ── Performance ──────────────────────────────────────────────────────────────
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_PARALLEL=1"
# Model stays loaded in VRAM for 30 minutes (0 = always, -1 = unload immediately)
Environment="OLLAMA_KEEP_ALIVE=30m"
```

Save: `Ctrl+O` → Enter → `Ctrl+X`

Enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
```

---

### 5. Block Ollama's Internet Access (Firewall)

The `ollama` system user is blocked at the network level – regardless of what Ollama does internally.

```bash
# Make scripts executable
chmod +x ollama-firewall.sh
chmod +x ollama-power.sh

# Show active network interfaces (everything except "lo" is relevant)
ip link show

# Set firewall rule per interface (example: two interfaces)
sudo iptables -I OUTPUT -m owner --uid-owner ollama -o enp14s0 -j DROP
sudo iptables -I OUTPUT -m owner --uid-owner ollama -o wlan0 -j DROP

# Save rules permanently
sudo pacman -S iptables-nft
sudo iptables-save | sudo tee /etc/iptables/iptables.rules
sudo systemctl enable --now iptables

# Verify that the rules are active
sudo iptables -L OUTPUT -v --line-numbers
```

---

### 6. Download Models

Since Ollama has no internet access after step 5, the firewall is temporarily opened.  
The `ollama-firewall.sh` script is used for this:

```bash
# Open firewall
sudo ./ollama-firewall.sh auf

# Download models (examples for 16 GB VRAM)
ollama pull gemma4:e4b       # All-rounder, 9.6 GB, fits completely in VRAM
ollama pull qwen3:14b        # All-rounder, ~9 GB, fits completely in VRAM
ollama pull qwen3-coder      # Coding assistant, 19 GB – runs with CPU offloading

# Close firewall again
sudo ./ollama-firewall.sh zu

# Check status
sudo ./ollama-firewall.sh status
```

> **Note on `qwen3-coder`:** At 19 GB, this model slightly exceeds the VRAM capacity.  
> It runs without issues using CPU offloading (approx. 17% CPU / 83% GPU), with minor performance trade-offs compared to pure GPU operation.

#### Manage Ollama

```bash
./ollama-power.sh status   # Shows whether Ollama is running and which models are loaded
./ollama-power.sh stop     # Stop Ollama → VRAM, RAM and CPU are released
./ollama-power.sh start    # Start Ollama again
```

> `ollama-power.sh stop` is useful before resource-intensive tasks (gaming, etc.).

---

### 7. Install Docker

```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker

# Test (user must be in the docker group – see step 2)
docker run hello-world
```

For users outside Arch (e.g. Ubuntu), follow the official Docker installation guide for Docker Compose:

[https://docs.docker.com/compose/install/linux/#install-using-the-repository](https://docs.docker.com/compose/install/linux/#install-using-the-repository)


---

### 8. Start the Docker Stack

#### First Start (with Internet)

On the very first start of Open WebUI, embedded models (e.g. for speech-to-text) are downloaded.  
For this, `ai_extern` must be temporarily enabled and offline mode must be disabled:

```bash
nano ai-stack/docker-compose.yml
```

Make the following changes:

1. Under `open-webui` → `networks`, uncomment the line `# - ai_extern` (remove the #)
2. Under `environment` → section `# Offline mode`, comment out all four lines (add # at the beginning)

Save: `Ctrl+O` → Enter → `Ctrl+X`

```bash
cd ai-stack/
docker compose up -d
docker compose logs -f   # Wait until Open WebUI has fully started
```

When all downloads are complete:

```bash
docker compose down
```

Revert the changes (comment out ai_extern, re-enable offline mode), then:

```bash
docker compose up -d
```

#### Normal Operation (without Internet)

```bash
cd ai-stack/
docker compose up -d

# Watch logs (optional, Ctrl+C to exit)
docker compose logs -f
```

Available at:

| Service | URL |
|---|---|
| Open WebUI (Chat) | http://localhost:3000 |
| n8n (Workflows) | http://localhost:5678 |

---

### 9. Configure Firewall for Docker Subnets

To allow Docker containers to access Ollama while preventing uncontrolled traffic:

> **Important:** Start Docker Compose first (step 8) so that the bridge networks exist. Then apply these rules.

```bash
# Allow Docker subnets to access Ollama
sudo ufw allow from 172.30.0.0/24 to any port 11434   # ai_host
sudo ufw allow from 172.17.0.0/16 to any port 11434   # Default Docker bridge
sudo ufw reload

# Verify that the rules are active
sudo ufw status verbose

# Ensure containers via ai_host cannot reach the internet
# (prevents bypass attempts through the host)
sudo iptables -I DOCKER-USER -i br-ai-host ! -d 172.30.0.1 -j DROP

# Save rule permanently
sudo iptables-save | sudo tee /etc/iptables/iptables.rules
sudo systemctl enable --now iptables
```

---

### 10. Test the Connection

```bash
# Is Ollama reachable from within the container?
docker exec -it open-webui curl http://host.docker.internal:11434
# Expected output: Ollama is running
```

---

## Model Overview (16 GB VRAM)

| Model | Size | VRAM Usage | Strength |
|---|---|---|---|
| `gemma4:e4b` | 9.6 GB | fully in VRAM | All-rounder, multimodal, German |
| `qwen3:14b` | ~9 GB | fully in VRAM | All-rounder, strong reasoning |
| `qwen3-coder` | 19 GB | GPU + CPU offloading | Coding assistant |

---

## Connect n8n with Ollama

Create an Ollama node in n8n and enter the following URL:

```
http://host.docker.internal:11434
```

---

## Set Up Continue.dev in VSCodium

Install the `Continue` extension (by Continue Dev, Inc.) from the Open VSX Registry.

**Open the configuration file:**

1. Open the Continue sidebar (`Ctrl+L`)
2. Click the agent selector (top of the chat input)
3. Hover over **Local Config** and click the **gear icon** → `config.yaml` opens in the editor
4. Alternatively: edit the file directly at `~/.continue/config.yaml`

> **Note:** `config.json` is deprecated. Continue now uses `config.yaml` exclusively.

Insert the following content (or add the model entries to an existing file):

```yaml
name: Local Ollama
version: 1.0.0
schema: v1

models:
  - name: qwen3-coder (Chat)
    provider: ollama
    model: qwen3-coder
    apiBase: http://localhost:11434
    roles:
      - chat
      - edit
      - apply

  - name: qwen3-coder (Autocomplete)
    provider: ollama
    model: qwen3-coder
    apiBase: http://localhost:11434
    roles:
      - autocomplete
    autocompleteOptions:
      debounceDelay: 150
      maxPromptTokens: 2048
```

---

## Privacy Overview

| Service | Location | Internet | Measures |
|---|---|---|---|
| **Ollama** | Host (native) | ❌ iptables rule | `OLLAMA_NO_CLOUD=1`, `OLLAMA_NOHISTORY=1` |
| **Open WebUI** | Docker | ❌ ai_intern + ai_host | Telemetry disabled, offline mode |
| **n8n** | Docker | ❌ / ✅ optional | Telemetry disabled |
| **Continue.dev** | VSCodium | ❌ | Local Ollama backend only |
