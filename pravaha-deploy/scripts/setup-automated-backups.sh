#!/bin/bash
# =============================================================================
# Pravaha Platform - Setup Automated Backups
# Configures cron jobs for automated database and volume backups
# =============================================================================
#
# Usage:
#   ./setup-automated-backups.sh                    # Interactive setup
#   ./setup-automated-backups.sh --hourly-db        # Hourly DB backups
#   ./setup-automated-backups.sh --daily-full       # Daily full backups
#   ./setup-automated-backups.sh --remove           # Remove automated backups
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/pravaha}"
BACKUP_SCRIPT="$DEPLOY_DIR/scripts/backup.sh"
LOG_DIR="$DEPLOY_DIR/logs"
CRON_MARKER="# Pravaha Backup"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Ensure directories exist
mkdir -p "$LOG_DIR"

remove_existing_crons() {
    log_info "Removing existing Pravaha backup cron jobs..."
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - 2>/dev/null || true
}

add_cron_job() {
    local schedule="$1"
    local backup_type="$2"
    local description="$3"

    local cron_line="$schedule $BACKUP_SCRIPT $backup_type >> $LOG_DIR/backup.log 2>&1 $CRON_MARKER - $description"

    # Add to crontab
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -

    log_success "Added: $description"
}

show_current_crons() {
    echo ""
    echo "Current Pravaha backup jobs:"
    echo "----------------------------------------"
    crontab -l 2>/dev/null | grep "$CRON_MARKER" || echo "  No automated backups configured"
    echo ""
}

setup_recommended() {
    log_info "Setting up recommended backup schedule..."

    remove_existing_crons

    # Hourly database-only backups (keeps 24)
    add_cron_job "0 * * * *" "--db-only --retention 24" "Hourly DB backup"

    # Daily full backups at 2 AM (keeps 7)
    add_cron_job "0 2 * * *" "--full --retention 7" "Daily full backup"

    # Weekly full backup on Sunday at 3 AM (keeps 4)
    add_cron_job "0 3 * * 0" "--full --retention 4" "Weekly full backup"

    log_success "Recommended backup schedule configured"
}

setup_minimal() {
    log_info "Setting up minimal backup schedule..."

    remove_existing_crons

    # Daily database backup at 2 AM (keeps 7)
    add_cron_job "0 2 * * *" "--db-only --retention 7" "Daily DB backup"

    log_success "Minimal backup schedule configured"
}

setup_enterprise() {
    log_info "Setting up enterprise backup schedule..."

    remove_existing_crons

    # Every 15 minutes database backup (keeps 96 = 24 hours)
    add_cron_job "*/15 * * * *" "--db-only --retention 96" "15-min DB backup"

    # Hourly full backups (keeps 24)
    add_cron_job "0 * * * *" "--full --retention 24" "Hourly full backup"

    # Daily archive at 3 AM (keeps 30)
    add_cron_job "0 3 * * *" "--full --retention 30" "Daily archive backup"

    log_success "Enterprise backup schedule configured"
}

interactive_setup() {
    echo "=============================================="
    echo "Pravaha Platform - Automated Backup Setup"
    echo "=============================================="
    echo ""
    echo "Select a backup schedule:"
    echo ""
    echo "  1) Recommended (Hourly DB, Daily full, Weekly archive)"
    echo "  2) Minimal (Daily DB only)"
    echo "  3) Enterprise (15-min DB, Hourly full, Daily archive)"
    echo "  4) Custom (configure manually)"
    echo "  5) Remove all automated backups"
    echo "  6) Show current configuration"
    echo ""
    read -p "Enter choice [1-6]: " choice

    case $choice in
        1) setup_recommended ;;
        2) setup_minimal ;;
        3) setup_enterprise ;;
        4)
            echo ""
            echo "To add custom cron jobs, edit crontab manually:"
            echo "  crontab -e"
            echo ""
            echo "Example entries:"
            echo "  # Every 6 hours - database only"
            echo "  0 */6 * * * $BACKUP_SCRIPT --db-only >> $LOG_DIR/backup.log 2>&1"
            echo ""
            echo "  # Every night at 2 AM - full backup"
            echo "  0 2 * * * $BACKUP_SCRIPT --full >> $LOG_DIR/backup.log 2>&1"
            ;;
        5) remove_existing_crons ;;
        6) show_current_crons ;;
        *)
            log_warning "Invalid choice"
            exit 1
            ;;
    esac

    show_current_crons
}

# Parse arguments
case "${1:-}" in
    --hourly-db)
        remove_existing_crons
        add_cron_job "0 * * * *" "--db-only --retention 24" "Hourly DB backup"
        show_current_crons
        ;;
    --daily-full)
        remove_existing_crons
        add_cron_job "0 2 * * *" "--full --retention 7" "Daily full backup"
        show_current_crons
        ;;
    --recommended)
        setup_recommended
        show_current_crons
        ;;
    --enterprise)
        setup_enterprise
        show_current_crons
        ;;
    --remove)
        remove_existing_crons
        log_success "All automated backups removed"
        ;;
    --show)
        show_current_crons
        ;;
    *)
        interactive_setup
        ;;
esac

echo ""
echo "Backup logs will be written to: $LOG_DIR/backup.log"
echo "To view recent backups: ls -la $DEPLOY_DIR/backups/"
