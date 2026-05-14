#!/bin/bash

USER="ollama"
THIS_PATH="$(realpath "$0")"
CONFIG_FILE="$(dirname "$THIS_PATH")/.ollama-interfaces"
INTERFACES=()

# Hilfsfunktion
show_help() {
    echo ""
    echo "Usage: ollama-firewall.sh [OPTION]"
    echo ""
    echo "Controls whether Ollama has access to the Internet."
    echo "Applies to all network interfaces: ${INTERFACES[*]}"
    echo ""
    echo "Options:"
    echo "  open       Remove firewall rules – Allow Ollama to access the Internet"
    echo "             (e.g. for: ollama pull <modell>)"
    echo "  close      Set firewall rules – Ollama is disconnected from the internet"
    echo "  status     Shows whether the rules are currently active"
    echo "  --help     Show help"
    echo ""
    echo "Typical process for loading a model:"
    echo "  sudo ./ollama-firewall open"
    echo "  ollama pull qwen3-coder"
    echo "  sudo ./ollama-firewall close"
    echo ""
}

# Load interfaces from configuration file
load_interfaces() {
    if [[ -f "$CONFIG_FILE" ]] && [[ -s "$CONFIG_FILE" ]]; then
        # Datei existiert und ist nicht leer
        INTERFACES=($(cat "$CONFIG_FILE"))
        echo "Load interfaces from configuration file: ${INTERFACES[*]}"
    else
        # file not found or empty
        echo "Configuration file not found or empty."
        echo "Please select the network interfaces you want to use for Ollama:"
        
        # list all interfaces
        local interfaces_list=($(ip link show | grep -E '^[0-9]+:' | cut -d: -f2 | tr -d ' '))
        local selected_interfaces=()
        
        for iface in "${interfaces_list[@]}"; do
            if [[ "$iface" != "lo" ]]; then
                echo "  $iface"
            fi
        done
        
        echo ""
        echo "Enter the interfaces (separated by spaces), e.g., 'eth0 wlan0':"
        read -r input_interfaces
        
        if [[ -n "$input_interfaces" ]]; then
            selected_interfaces=($input_interfaces)
            # Speichere die Auswahl in der Konfigurationsdatei
            echo "${selected_interfaces[*]}" > "$CONFIG_FILE"
            INTERFACES=("${selected_interfaces[@]}")
            echo "Interface selection saved in $CONFIG_FILE"
        else
            echo "No interfaces selected. Using default interface 'eth0'."
            INTERFACES=("eth0")
        fi
    fi
}

# Prüfen ob Regel für ein Interface aktiv ist
rule_active() {
    local iface="$1"
    sudo iptables -C OUTPUT -m owner --uid-owner "$USER" -o "$iface" -j DROP 2>/dev/null
    return $?
}

# Status anzeigen
show_status() {
    echo ""
    local all_closed=true
    local all_open=true

    for iface in "${INTERFACES[@]}"; do
        if rule_active "$iface"; then
            echo "🔒 $iface – closed"
            all_open=false
        else
            echo "🔓 $iface – open"
            all_closed=false
        fi
    done

    echo ""
    if $all_closed; then
        echo "→ Ollama does not have internet access on any interface"
    elif $all_open; then
        echo "→ Ollama has internet access on all interfaces"
    else
        echo "→ ⚠️  Mixed state – check the interfaces at the top"
    fi
    echo ""
}

# Türe öffnen
ollama_open() {
    echo ""
    local sth_changed=false
    for iface in "${INTERFACES[@]}"; do
        if rule_active "$iface"; then
            sudo iptables -D OUTPUT -m owner --uid-owner "$USER" -o "$iface" -j DROP
            echo "🔓 $iface – rule removed"
            sth_changed=true
        else
            echo "⚠️  $iface – was already open"
        fi
    done
    echo ""
    if $sth_changed; then
        echo "✓ Ollama has now access to the internet"
        echo "  Don't forget to do afterward: sudo ./ollama-firewall close"
    fi
    echo ""
}

# Türe schließen
ollama_close() {
    echo ""
    local sth_changed=false
    for iface in "${INTERFACES[@]}"; do
        if rule_active "$iface"; then
            echo "⚠️  $iface – was already closed"
        else
            sudo iptables -I OUTPUT -m owner --uid-owner "$USER" -o "$iface" -j DROP
            echo "🔒 $iface – Rule set"
            sth_changed=true
        fi
    done
    if $sth_changed; then
        sudo iptables-save | sudo tee /etc/iptables/iptables.rules > /dev/null
        echo ""
        echo "✓ Ollama is offline – rules saved"
    fi
    echo ""
}

# Hauptlogik

load_interfaces

case "$1" in
    open)
        ollama_open
        ;;
    close)
        ollama_close
        ;;
    status)
        show_status
        ;;
    --help|-h|"")
        show_help
        ;;
    *)
        echo "❌ unknown option: $1"
        show_help
        exit 1
        ;;
esac
