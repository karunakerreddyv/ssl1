#!/bin/bash
# =============================================================================
# Pravaha Platform - Setup Automated Backups
# Two-Server Deployment - App Server
# =============================================================================
#
# Purpose:
#   Configures cron jobs for automated backups of application data and volumes.
#   Database backup should be configured separately on the database server.
#
# Usage:
#   ./setup-automated-backups.sh                    # Interactive setup
#   ./setup-automated-backups.sh --hourly-volumes   # Hourly volume backups
#   ./setup-automated-backups.sh --daily-full       # Daily full backups
#   ./setup-automated-backups.sh --remove           # Remove automated backups
#   ./setup-automated-backups.sh --show             # Show current configuration
#
# Architecture Notes:
#   - This script configures app server backups ONLY
#   - Database backups must be configured on the database server
#   - Coordinate backup schedules with database server for consistent recovery
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "$SCRIPT_DIR")}"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
LOG_DIR="$DEPLOY_DIR/logs"
CRON_MARKER="# Pravaha App Backup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Ensure directories exist
mkdir -p "$LOG_DIR"

# =============================================================================
# Cron Management Functions
# =============================================================================

remove_existing_crons() {
    log_info "Removing existing Pravaha app backup cron jobs..."
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - 2>/dev/null || true
}

add_cron_job() {
    local schedule="$1"
    local backup_options="$2"
    local description="$3"

    local cron_line="$schedule $BACKUP_SCRIPT $backup_options >> $LOG_DIR/backup.log 2>&1 $CRON_MARKER - $description"

    # Add to crontab
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -

    log_success "Added: $description"
}

show_current_crons() {
    echo ""
    echo "Current Pravaha app backup jobs:"
    echo "----------------------------------------"
    crontab -l 2>/dev/null | grep "$CRON_MARKER" || echo "  No automated backups configured"
    echo ""
}

# =============================================================================
# Backup Schedule Configurations
# =============================================================================

setup_recommended() {
    log_info "Setting up recommended backup schedule for app server..."

    remove_existing_crons

    # Hourly volume backups (keeps 24) - lightweight, just volumes
    add_cron_job "0 * * * *" "--volumes-only --retention 24" "Hourly volume backup"

    # Daily full backups at 2 AM (keeps 7) - configs + volumes
    add_cron_job "0 2 * * *" "--retention 7" "Daily full backup"

    # Weekly full backup on Sunday at 3 AM (keeps 4)
    add_cron_job "0 3 * * 0" "--retention 4" "Weekly full backup"

    log_success "Recommended backup schedule configured"

    echo ""
    log_warning "IMPORTANT: This configures APP SERVER backups only."
    log_warning "Database backups must be configured on the database server."
    log_warning "Coordinate backup times for consistent disaster recovery."
}

setup_minimal() {
    log_info "Setting up minimal backup schedule for app server..."

    remove_existing_crons

    # Daily full backup at 2 AM (keeps 7)
    add_cron_job "0 2 * * *" "--retention 7" "Daily full backup"

    log_success "Minimal backup schedule configured"
}

setup_enterprise() {
    log_info "Setting up enterprise backup schedule for app server..."

    remove_existing_crons

    # Every 15 minutes volume backup (keeps 96 = 24 hours)
    add_cron_job "*/15 * * * *" "--volumes-only --retention 96" "15-min volume backup"

    # Hourly full backups (keeps 24)
    add_cron_job "0 * * * *" "--retention 24" "Hourly full backup"

    # Daily archive at 3 AM (keeps 30)
    add_cron_job "0 3 * * *" "--retention 30" "Daily archive backup"

    log_success "Enterprise backup schedule configured"

    echo ""
    log_warning "IMPORTANT: This configures APP SERVER backups only."
    log_warning "Database backups must be configured on the database server."
    log_warning "For enterprise setups, consider synchronizing backup windows."
}

setup_with_remote_db() {
    log_info "Setting up backup schedule with external database backup..."

    remove_existing_crons

    # Daily full backup WITH database at 2 AM (keeps 7)
    # This requires network access to the database server
    add_cron_job "0 2 * * *" "--database --retention 7" "Daily full backup (with DB)"

    # Hourly volume-only backups (keeps 24)
    add_cron_job "0 * * * *" "--volumes-only --retention 24" "Hourly volume backup"

    log_success "Backup schedule with remote database backup configured"

    echo ""
    log_warning "Note: Remote database backup requires:"
    log_warning "  - Network access from app server to database server"
    log_warning "  - POSTGRES_HOST configured in .env"
    log_warning "  - PostgreSQL user with backup permissions"
}

# =============================================================================
# Interactive Setup
# =============================================================================

interactive_setup() {
    echo "=============================================="
    echo "Pravaha Platform - Automated Backup Setup"
    echo "=============================================="
    echo "Deployment: Two-Server (App Server)"
    echo ""
    echo "Select a backup schedule:"
    echo ""
    echo "  1) Recommended (Hourly volumes, Daily full, Weekly archive)"
    echo "  2) Minimal (Daily full only)"
    echo "  3) Enterprise (15-min volumes, Hourly full, Daily archive)"
    echo "  4) With Remote DB (Include external database in backups)"
    echo "  5) Custom (configure manually)"
    echo "  6) Remove all automated backups"
    echo "  7) Show current configuration"
    echo ""
    read -p "Enter choice [1-7]: " choice

    case $choice in
        1) setup_recommended ;;
        2) setup_minimal ;;
        3) setup_enterprise ;;
        4) setup_with_remote_db ;;
        5)
            echo ""
            echo "To add custom cron jobs, edit crontab manually:"
            echo "  crontab -e"
            echo ""
            echo "Example entries for two-server app backup:"
            echo "  # Every 6 hours - volumes only (lightweight)"
            echo "  0 */6 * * * $BACKUP_SCRIPT --volumes-only >> $LOG_DIR/backup.log 2>&1"
            echo ""
            echo "  # Every night at 2 AM - full backup (configs + volumes)"
            echo "  0 2 * * * $BACKUP_SCRIPT >> $LOG_DIR/backup.log 2>&1"
            echo ""
            echo "  # Weekly with database backup (requires external DB access)"
            echo "  0 3 * * 0 $BACKUP_SCRIPT --database >> $LOG_DIR/backup.log 2>&1"
            ;;
        6)
            remove_existing_crons
            log_success "All automated backups removed"
            ;;
        7) show_current_crons ;;
        *)
            log_warning "Invalid choice"
            exit 1
            ;;
    esac

    show_current_crons
}

# =============================================================================
# Database Server Coordination Guide
# =============================================================================

show_db_server_guide() {
    echo ""
    echo "=============================================="
    echo "Database Server Backup Coordination"
    echo "=============================================="
    echo ""
    echo "For complete disaster recovery, configure database backups on your"
    echo "database server. Recommended schedule to coordinate with app server:"
    echo ""
    echo "On the DATABASE SERVER, add these cron jobs:"
    echo ""
    echo "  # Hourly database backups (coordinate with app server hourly backups)"
    echo "  0 * * * * pg_dump -U postgres autoanalytics -Fc > /backups/autoanalytics_\$(date +\%Y\%m\%d_\%H).dump"
    echo "  0 * * * * pg_dump -U postgres superset -Fc > /backups/superset_\$(date +\%Y\%m\%d_\%H).dump"
    echo ""
    echo "  # Daily full database backup at 1:55 AM (5 min before app backup)"
    echo "  55 1 * * * pg_dumpall -U postgres > /backups/all_databases_\$(date +\%Y\%m\%d).sql"
    echo ""
    echo "  # Cleanup old backups"
    echo "  0 4 * * * find /backups -name '*.dump' -mtime +7 -delete"
    echo ""
    echo "Timing coordination:"
    echo "  - Database backup starts at 1:55 AM"
    echo "  - App server backup starts at 2:00 AM"
    echo "  - This ensures database state is captured before app backup completes"
    echo ""
}

# =============================================================================
# Verify Backup Script
# =============================================================================

verify_backup_script() {
    if [[ ! -x "$BACKUP_SCRIPT" ]]; then
        log_error "Backup script not found or not executable: $BACKUP_SCRIPT"
        log_info "Creating executable permissions..."
        chmod +x "$BACKUP_SCRIPT" 2>/dev/null || {
            log_error "Could not set execute permission on backup script"
            exit 1
        }
    fi
}

# =============================================================================
# Main
# =============================================================================

verify_backup_script

# Parse arguments
case "${1:-}" in
    --hourly-volumes)
        remove_existing_crons
        add_cron_job "0 * * * *" "--volumes-only --retention 24" "Hourly volume backup"
        show_current_crons
        ;;
    --daily-full)
        remove_existing_crons
        add_cron_job "0 2 * * *" "--retention 7" "Daily full backup"
        show_current_crons
        ;;
    --daily-with-db)
        remove_existing_crons
        add_cron_job "0 2 * * *" "--database --retention 7" "Daily full backup (with DB)"
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
    --db-guide)
        show_db_server_guide
        ;;
    -h|--help)
        echo "Usage: $0 [option]"
        echo ""
        echo "Options:"
        echo "  --hourly-volumes  Set up hourly volume-only backups"
        echo "  --daily-full      Set up daily full backups"
        echo "  --daily-with-db   Set up daily backups including external database"
        echo "  --recommended     Set up recommended schedule"
        echo "  --enterprise      Set up enterprise schedule"
        echo "  --remove          Remove all automated backups"
        echo "  --show            Show current configuration"
        echo "  --db-guide        Show database server backup coordination guide"
        echo ""
        echo "Run without arguments for interactive setup."
        echo ""
        echo "Note: This configures APP SERVER backups only."
        echo "      Database backups should be configured on the database server."
        exit 0
        ;;
    *)
        interactive_setup
        ;;
esac

echo ""
echo "Backup logs will be written to: $LOG_DIR/backup.log"
echo "To view recent backups: ls -la $DEPLOY_DIR/backups/"
echo ""
echo "For database server backup coordination, run:"
echo "  $0 --db-guide"
