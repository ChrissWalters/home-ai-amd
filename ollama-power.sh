#!/bin/bash

SKRIPT_PFAD="$(realpath "$0")"

show_help() {
    echo ""
    echo "Usage: sudo $SKRIPT_PFAD [OPTION]"
    echo ""
    echo "Controls the Ollama service – e.g., before gaming."
    echo ""
    echo "Options:"
    echo "  stop      Stop Ollama  → VRAM, RAM and CPU resources are freed"
    echo "  start     Start Ollama   → Service becomes available again"
    echo "  restart   Restart Ollama (e.g., after configuration changes)"
    echo "  status    Shows whether Ollama is currently running"
    echo "  --help    Display this help"
    echo ""
    echo "Examples:"
    echo "  sudo ./ollama-power.sh stop     ← before gaming"
    echo "  sudo ./ollama-power.sh start    ← enable again afterwards"
    echo ""
}

show_status() {
    echo ""
    if systemctl is-active --quiet ollama; then
        echo "✅ Ollama active"
        echo ""
        # Displays loaded models, if any
        MODELLE=$(ollama ps 2>/dev/null)
        if echo "$MODELLE" | grep -q "NAME"; then
            echo "models loaded:"
            echo "$MODELLE"
        else
            echo "   No model is currently loaded in memory"
        fi
    else
        echo "⛔ Ollama has stopped – VRAM and RAM are free"
    fi
    echo ""
}

case "$1" in
    stop)
        if systemctl is-active --quiet ollama; then
            # first unload loaded models
            ollama ps 2>/dev/null | grep -v "NAME" | awk '{print $1}' | while read -r modell; do
                [ -n "$modell" ] && ollama stop "$modell" 2>/dev/null
            done
            sudo systemctl stop ollama
            sudo systemctl daemon-reload
            echo "⛔ Ollama has stopped – VRAM and RAM are free"
            echo "   start with: sudo ./ollama-power.sh start"
        else
            echo "⚠️  Ollama is already stopped"
        fi
        ;;
    start)
        if systemctl is-active --quiet ollama; then
            echo "⚠️  Ollama is already running"
        else
            sudo systemctl start ollama
            echo "✅ Ollama started"
        fi
        ;;
    restart)
        sudo systemctl restart ollama
        echo "🔄 Ollama restarted"
        ;;
    status)
        show_status
        ;;
    --help|-h|"")
        show_help
        ;;
    *)
        echo "❌ Unbekannte Option: $1"
        show_help
        exit 1
        ;;
esac
