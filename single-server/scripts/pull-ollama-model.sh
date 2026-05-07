#!/usr/bin/env bash
# =============================================================================
# Pravaha — Ollama Model Management
# =============================================================================
# Pull, list, or remove LLM models from the Ollama container.
#
# Usage:
#   ./pull-ollama-model.sh llama3.1            # Pull a model
#   ./pull-ollama-model.sh mistral codellama   # Pull multiple models
#   ./pull-ollama-model.sh --list              # List installed models
#   ./pull-ollama-model.sh --remove mistral    # Remove a model
#   ./pull-ollama-model.sh --help              # Show usage
# =============================================================================

set -euo pipefail

CONTAINER_NAME="pravaha-ollama"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if Ollama container is running
check_ollama() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Ollama container '${CONTAINER_NAME}' is not running."
        log_info "Start it with: docker compose --profile llm up -d"
        exit 1
    fi
}

# List installed models
list_models() {
    check_ollama
    echo ""
    log_info "Installed Ollama models:"
    echo "----------------------------------------------"
    docker exec "$CONTAINER_NAME" ollama list 2>/dev/null || log_warning "No models installed"
    echo ""

    # Show disk usage
    local volume_size
    volume_size=$(docker system df -v 2>/dev/null | grep "ollama_models" | awk '{print $3}' || echo "unknown")
    log_info "Model storage: ${volume_size}"
}

# Pull a model
pull_model() {
    local model="$1"
    check_ollama

    log_info "Pulling model: ${model}"
    log_info "This may take several minutes for first download..."
    echo ""

    if docker exec "$CONTAINER_NAME" ollama pull "$model"; then
        echo ""
        log_success "Model '${model}' pulled successfully"

        # Show model info
        docker exec "$CONTAINER_NAME" ollama show "$model" --modelfile 2>/dev/null | head -5 || true
    else
        echo ""
        log_error "Failed to pull model '${model}'"
        log_info "Check available models at: https://ollama.com/library"
        return 1
    fi
}

# Remove a model
remove_model() {
    local model="$1"
    check_ollama

    log_warning "Removing model: ${model}"
    if docker exec "$CONTAINER_NAME" ollama rm "$model" 2>/dev/null; then
        log_success "Model '${model}' removed"
    else
        log_error "Failed to remove model '${model}' (may not be installed)"
    fi
}

# Show usage
show_help() {
    echo "Pravaha — Ollama Model Management"
    echo ""
    echo "Usage:"
    echo "  $(basename "$0") <model> [model2...]   Pull one or more models"
    echo "  $(basename "$0") --list                 List installed models"
    echo "  $(basename "$0") --remove <model>       Remove a model"
    echo "  $(basename "$0") --help                 Show this help"
    echo ""
    echo "Recommended 7B models (4-8GB RAM):"
    echo "  llama3.1      Meta Llama 3.1 (general purpose, best quality)"
    echo "  mistral       Mistral 7B (fast, good quality)"
    echo "  qwen2.5       Qwen 2.5 (multilingual)"
    echo "  codellama     Code Llama (optimized for code)"
    echo "  phi3          Microsoft Phi-3 (small, fast)"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") llama3.1"
    echo "  $(basename "$0") llama3.1 codellama"
    echo "  $(basename "$0") --list"
    echo "  $(basename "$0") --remove codellama"
}

# =============================================================================
# Main
# =============================================================================

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

case "$1" in
    --list|-l)
        list_models
        ;;
    --remove|-r)
        if [[ $# -lt 2 ]]; then
            log_error "Usage: $(basename "$0") --remove <model>"
            exit 1
        fi
        remove_model "$2"
        ;;
    --help|-h)
        show_help
        ;;
    *)
        # Pull one or more models
        for model in "$@"; do
            pull_model "$model"
        done
        echo ""
        log_info "Installed models:"
        list_models
        ;;
esac
