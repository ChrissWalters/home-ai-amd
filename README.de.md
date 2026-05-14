# home-ai-amd

Lokale KI-Infrastruktur auf AMD-Hardware unter Linux (getestet auf CachyOS / Arch).  
Ollama läuft nativ auf dem Host, alle weiteren Dienste laufen in Docker-Containern – netzwerkseitig isoliert und ohne unkontrolliertes „Nach-Hause-Telefonieren".

---

## Inhalt dieses Repos

```
home-ai-amd/
├── README.md
├── ollama-firewall.sh      # Firewall-Schalter für Ollama (auf/zu)
├── ollama-power.sh         # Ollama starten / stoppen / status
└── ai-stack/
    └── docker-compose.yml  # Open WebUI + n8n
```

---

## Voraussetzungen

| Komponente | Empfehlung / Getestet mit |
|---|---|
| Betriebssystem | CachyOS / Arch Linux |
| GPU | AMD RX 7800 XT (16 GB VRAM) |
| RAM | 32 GB |
| CPU | AMD Ryzen 7 7700X |
| Docker | 29.x + Compose 5.x |

> Andere AMD-GPUs mit ROCm-Unterstützung funktionieren ebenfalls – GPU-spezifische Werte (HSA_OVERRIDE_GFX_VERSION) müssen dann angepasst werden.

---

## Netzwerk-Architektur

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
│  │  ai_host   (172.30.0.0/24)  Bridge mit host-gateway  │   │
│  │  ai_intern (172.31.0.0/24)  kein Internet (internal) │   │
│  │  ai_extern (automatisch)    optional, mit Internet   │   │
│  │                                                      │   │
│  │  open-webui ──► ai_intern + ai_host                  │   │
│  │  n8n        ──► ai_intern + ai_host                  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

| Netz | Subnetz | Internet | Zweck |
|---|---|---|---|
| `ai_host` | 172.30.0.0/24 | nein | Container → Ollama auf dem Host |
| `ai_intern` | 172.31.0.0/24 | nein | Interne Kommunikation zwischen Containern |
| `ai_extern` | automatisch | **ja** | Optionaler Internetzugriff (z.B. erster Start, n8n-Webhooks) |

---

## Schritt-für-Schritt-Installation

### 1. Repo klonen

```bash
cd /ZIEL-VERZEICHNIS/
git clone https://github.com/DEIN-USERNAME/home-ai-amd.git
cd home-ai-amd
```

---

### 2. Nutzergruppen einrichten

Damit dein Nutzer auf die AMD-GPU und Docker zugreifen darf:

```bash
sudo usermod -aG video,render,docker $USER
```

> **Wichtig:** Danach ausloggen und neu einloggen (oder neu starten) – die Gruppen wirken erst nach einer neuen Session.

---

### 3. Ollama nativ installieren (mit ROCm, Arch/CachyOS)

```bash
sudo pacman -S rocm-hip-sdk rocm-opencl-sdk ollama-rocm
```

---

### 4. Ollama konfigurieren

Ollama wird über eine systemd-Drop-in-Datei konfiguriert. Diese Datei steuert GPU-Zuordnung, Datenschutz und Performance.

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo nano /etc/systemd/system/ollama.service.d/custom.conf
```

Inhalt einfügen:

```ini
[Service]
# ── AMD GPU (Beispiel: RX 7800 XT = RDNA3 = gfx1100) ────────────────────────
# Werte müssen ggf. für die eigene GPU angepasst werden!
Environment="HSA_OVERRIDE_GFX_VERSION=11.0.0"
Environment="ROCR_VISIBLE_DEVICES=0"

# ── Datenschutz ──────────────────────────────────────────────────────────────
Environment="OLLAMA_NO_CLOUD=1"
Environment="OLLAMA_NOHISTORY=1"

# ── Netzwerk ─────────────────────────────────────────────────────────────────
# 0.0.0.0 ist erforderlich, damit Docker-Container über host.docker.internal
# auf Ollama zugreifen können. Ollama ist trotzdem nur lokal erreichbar,
# da keine Portweiterleitung nach außen konfiguriert ist.
Environment="OLLAMA_HOST=0.0.0.0:11434"

# ── Performance ──────────────────────────────────────────────────────────────
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_PARALLEL=1"
# Modell bleibt 30 Minuten im VRAM geladen (0 = immer, -1 = sofort entladen)
Environment="OLLAMA_KEEP_ALIVE=30m"
```

Speichern: `Strg+O` → Enter → `Strg+X`

Dienst aktivieren:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
```

---

### 5. Ollama das Internet entziehen (Firewall)

Der `ollama`-Systemnutzer wird auf Netzwerkebene gesperrt – unabhängig davon was Ollama intern macht.

```bash
# Skripte ausführbar machen
chmod +x ollama-firewall.sh
chmod +x ollama-power.sh

# Aktive Netzwerk-Interfaces anzeigen (alles außer "lo" ist relevant)
ip link show

# Firewall-Regel pro Interface setzen (Beispiel: zwei Interfaces)
sudo iptables -I OUTPUT -m owner --uid-owner ollama -o enp14s0 -j DROP
sudo iptables -I OUTPUT -m owner --uid-owner ollama -o wlan0 -j DROP

# Regeln dauerhaft speichern
sudo pacman -S iptables-nft
sudo iptables-save | sudo tee /etc/iptables/iptables.rules
sudo systemctl enable --now iptables

# Prüfen ob die Regeln aktiv sind
sudo iptables -L OUTPUT -v --line-numbers
```

---

### 6. Modelle herunterladen

Da Ollama nach Schritt 5 kein Internet mehr hat, wird die Firewall kurzzeitig geöffnet.  
Dafür gibt es das Skript `ollama-firewall.sh`:

```bash
# Firewall öffnen
sudo ./ollama-firewall.sh auf

# Modelle herunterladen (Beispiele für 16 GB VRAM)
ollama pull gemma4:e4b       # Allrounder, 9.6 GB, passt komplett in VRAM
ollama pull qwen3:14b        # Allrounder, ~9 GB, passt komplett in VRAM
ollama pull qwen3-coder      # Coding-Assistent, 19 GB – läuft mit CPU-Offloading

# Firewall wieder schließen
sudo ./ollama-firewall.sh zu

# Status prüfen
sudo ./ollama-firewall.sh status
```

> **Hinweis zu `qwen3-coder`:** Mit 19 GB überschreitet dieses Modell den VRAM leicht.  
> Es läuft problemlos mit CPU-Offloading (ca. 17% CPU / 83% GPU), mit leichten Performance-Einbußen gegenüber einem rein GPU-basierten Betrieb.

#### Ollama verwalten

```bash
./ollama-power.sh status   # Zeigt ob Ollama läuft und welche Modelle geladen sind
./ollama-power.sh stop     # Ollama stoppen → VRAM, RAM und CPU werden freigegeben
./ollama-power.sh start    # Ollama wieder starten
```

> `ollama-power.sh stop` eignet sich z.B. vor ressourcenintensiven Aufgaben (Gaming etc.).

---

### 7. Docker installieren

```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker

# Testen (Nutzer muss in der docker-Gruppe sein – siehe Schritt 2)
docker run hello-world
```

Für Nutzer außerhalb ARCH (z.B. Ubuntu) sollte der Installationsanleitung von Docker zu Docker Compose gefolgt werden:

[https://docs.docker.com/compose/install/linux/#install-using-the-repository](https://docs.docker.com/compose/install/linux/#install-using-the-repository)

---

### 8. Docker-Stack starten

#### Erster Start (mit Internet)

Beim allerersten Start von Open WebUI werden eingebettete Modelle (z.B. für Speech-to-Text) heruntergeladen.  
Dafür muss `ai_extern` kurzzeitig aktiviert und der Offline-Modus deaktiviert werden:

```bash
nano ai-stack/docker-compose.yml
```

Folgende Änderungen vornehmen:

1. Unter `open-webui` → `networks` die Zeile `# - ai_extern` einkommentieren (# entfernen)
2. Unter `environment` → Abschnitt `# Offline-Modus` alle vier Zeilen auskommentieren (# voranstellen)

Speichern: `Strg+O` → Enter → `Strg+X`

```bash
cd ai-stack/
docker compose up -d
docker compose logs -f   # Warten bis Open WebUI vollständig gestartet ist
```

Wenn alle Downloads abgeschlossen sind:

```bash
docker compose down
```

Änderungen rückgängig machen (ai_extern auskommentieren, Offline-Modus wieder aktivieren), dann:

```bash
docker compose up -d
```

#### Normaler Betrieb (ohne Internet)

```bash
cd ai-stack/
docker compose up -d

# Logs beobachten (optional, Strg+C zum Beenden)
docker compose logs -f
```

Erreichbar unter:

| Dienst | URL |
|---|---|
| Open WebUI (Chat) | http://localhost:3000 |
| n8n (Workflows) | http://localhost:5678 |

---

### 9. Firewall für Docker-Subnetze konfigurieren

Damit die Docker-Container auf Ollama zugreifen können und gleichzeitig kein unkontrollierter Traffic möglich ist:

> **Wichtig:** Erst Docker Compose starten (Schritt 8), damit die Bridge-Netze existieren. Dann diese Regeln setzen.

```bash
# Docker-Subnetzen Zugriff auf Ollama erlauben
sudo ufw allow from 172.30.0.0/24 to any port 11434   # ai_host
sudo ufw allow from 172.17.0.0/16 to any port 11434   # Standard Docker-Bridge
sudo ufw reload

# Prüfen ob die Regeln aktiv sind
sudo ufw status verbose

# Sicherstellen dass Container über ai_host nicht ins Internet können
# (verhindert Umgehungsversuche über den Host)
sudo iptables -I DOCKER-USER -i br-ai-host ! -d 172.30.0.1 -j DROP

# Regel dauerhaft speichern
sudo iptables-save | sudo tee /etc/iptables/iptables.rules
sudo systemctl enable --now iptables
```

---

### 10. Verbindung testen

```bash
# Ollama vom Container aus erreichbar?
docker exec -it open-webui curl http://host.docker.internal:11434
# Erwartete Ausgabe: Ollama is running
```

---

## Modell-Übersicht (16 GB VRAM)

| Modell | Größe | VRAM-Nutzung | Stärke |
|---|---|---|---|
| `gemma4:e4b` | 9.6 GB | komplett in VRAM | Allrounder, multimodal, Deutsch |
| `qwen3:14b` | ~9 GB | komplett in VRAM | Allrounder, starkes Reasoning |
| `qwen3-coder` | 19 GB | GPU + CPU-Offloading | Coding-Assistent |

---

## n8n mit Ollama verbinden

In n8n einen Ollama-Node anlegen und folgende URL eintragen:

```
http://host.docker.internal:11434
```

---

## Continue.dev in VSCodium einrichten

Extension `Continue` (von Continue Dev, Inc.) aus dem Open VSX Registry installieren.

**Konfigurationsdatei öffnen:**

1. Continue-Sidebar öffnen (`Ctrl+L`)
2. Den Agenten-Selektor anklicken (oben am Chat-Eingabefeld)
3. Über **Local Config** hovern und das **Zahnrad-Icon** anklicken → `config.yaml` öffnet sich im Editor
4. Alternativ: Datei direkt bearbeiten unter `~/.continue/config.yaml`

> **Hinweis:** `config.json` ist deprecated. Continue verwendet jetzt ausschließlich `config.yaml`.

Folgenden Inhalt einfügen (oder die Modell-Einträge in eine bestehende Datei ergänzen):

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

## Datenschutz-Übersicht

| Dienst | Wo | Internet | Maßnahmen |
|---|---|---|---|
| **Ollama** | Host (nativ) | ❌ iptables-Regel | `OLLAMA_NO_CLOUD=1`, `OLLAMA_NOHISTORY=1` |
| **Open WebUI** | Docker | ❌ ai_intern + ai_host | Telemetrie deaktiviert, Offline-Modus |
| **n8n** | Docker | ❌ / ✅ optional | Telemetrie deaktiviert |
| **Continue.dev** | VSCodium | ❌ | Nur lokales Ollama-Backend |