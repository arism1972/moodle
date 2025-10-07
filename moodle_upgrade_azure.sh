#!/usr/bin/env bash
# Moodle upgrade helper for Ubuntu + Apache2 (Azure VM friendly)
# Author: M365 Copilot for Aris Meletíou
# Usage examples:
#   sudo bash moodle_upgrade_azure.sh --wwwroot /var/www/html/moodle \
#       --dataroot /var/moodledata --backup-dir /var/backups/moodle \
#       --branch 401   # (Upgrades to Moodle 4.1 LTS)
#
#   sudo bash moodle_upgrade_azure.sh --wwwroot /var/www/html/moodle \
#       --dataroot /var/moodledata --backup-dir /var/backups/moodle \
#       --branch 405   # (Upgrades to Moodle 4.5 LTS)
#
# Notes:
# - The script uses official tarballs (SourceForge mirrors) for the selected branch.
# - It performs: maintenance mode, full backups (DB+code+moodledata), code replacement,
#   plugin carry-over, CLI upgrade, cache purge, maintenance off.
# - Requires: curl or wget, tar, php-cli, mysqldump/pg_dump, gzip.
# - Run as root (sudo). Apache service name assumed: apache2.

set -euo pipefail

# ---------- helper functions ----------
log() { echo -e "\n[INFO] $*"; }
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }

# ---------- defaults (override via flags) ----------
WWWROOT="/var/www/html/moodle"
DATAROOT="/var/moodledata"
BACKUP_DIR="/var/backups/moodle"
BRANCH="401"              # 401=4.1 LTS, 405=4.5 LTS
WEB_USER="www-data"       # Apache on Ubuntu
APACHE_SERVICE="apache2"
DOWNLOAD_TOOL="curl"       # or wget

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wwwroot) WWWROOT="$2"; shift 2;;
    --dataroot) DATAROOT="$2"; shift 2;;
    --backup-dir) BACKUP_DIR="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --web-user) WEB_USER="$2"; shift 2;;
    --apache-service) APACHE_SERVICE="$2"; shift 2;;
    --download-tool) DOWNLOAD_TOOL="$2"; shift 2;;
    -h|--help)
      cat <<EOF
Usage: sudo bash $0 --wwwroot /path/to/moodle --dataroot /path/to/moodledata \
                    --backup-dir /path/to/backups --branch 401|405
Options:
  --wwwroot           Moodle code directory (default: /var/www/html/moodle)
  --dataroot          moodledata directory (default: /var/moodledata)
  --backup-dir        backup output directory (default: /var/backups/moodle)
  --branch            401 (4.1 LTS) or 405 (4.5 LTS). Default: 401
  --web-user          Web server user (default: www-data)
  --apache-service    Apache systemd service name (default: apache2)
  --download-tool     curl|wget (default: curl)
EOF
      exit 0;;
    *) die "Unknown option: $1";;
  esac
done

# ---------- sanity checks ----------
[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."
[[ -d "$WWWROOT" ]] || die "WWWROOT not found: $WWWROOT"
[[ -f "$WWWROOT/config.php" ]] || die "config.php not found in $WWWROOT"
[[ -d "$DATAROOT" ]] || die "DATAROOT not found: $DATAROOT"
command -v php >/dev/null || die "php CLI is required"
command -v tar >/dev/null || die "tar is required"
command -v gzip >/dev/null || die "gzip is required"
if [[ "$DOWNLOAD_TOOL" == "curl" ]]; then
  command -v curl >/dev/null || die "curl not found; install or use --download-tool wget"
else
  command -v wget >/dev/null || die "wget not found; install or use --download-tool curl"
fi

# optional DB clients
command -v mysqldump >/dev/null || true
command -v pg_dump >/dev/null || true

TIMESTAMP=$(date +%F_%H%M%S)
WORKDIR=$(mktemp -d /tmp/moodle-upg-XXXX)
TMPDL="$WORKDIR/moodle.tgz"
mkdir -p "$BACKUP_DIR"

log "Parameters:\n  WWWROOT=$WWWROOT\n  DATAROOT=$DATAROOT\n  BACKUP_DIR=$BACKUP_DIR\n  BRANCH=$BRANCH\n  WEB_USER=$WEB_USER\n  APACHE_SERVICE=$APACHE_SERVICE\n  DOWNLOAD_TOOL=$DOWNLOAD_TOOL"

# ---------- derive download URL for selected branch ----------
# Using SourceForge stable directories because they provide predictable 'moodle-latest-<branch>.tgz'
case "$BRANCH" in
  401) DLPATH="https://sourceforge.net/projects/moodle/files/Moodle/stable401/moodle-latest-401.tgz/download" ;;
  405) DLPATH="https://sourceforge.net/projects/moodle/files/Moodle/stable405/moodle-latest-405.tgz/download" ;;
  *) die "Unsupported --branch '$BRANCH'. Use 401 or 405." ;;
esac

log "Downloading Moodle branch $BRANCH from: $DLPATH"
if [[ "$DOWNLOAD_TOOL" == "curl" ]]; then
  curl -fL "$DLPATH" -o "$TMPDL"
else
  wget -O "$TMPDL" "$DLPATH"
fi
[[ -s "$TMPDL" ]] || die "Download failed"

# ---------- enable CLI maintenance mode ----------
log "Enabling CLI maintenance mode"
cd "$WWWROOT"
sudo -u "$WEB_USER" php admin/cli/maintenance.php --enable || die "Failed to enable maintenance mode"

# ---------- read DB credentials from config.php using PHP ----------
log "Reading DB credentials from config.php"
DBINFO=$(php -r "define('CLI_SCRIPT', true); require '$WWWROOT/config.php'; echo \"$CFG->dbtype|$CFG->dbhost|$CFG->dbname|$CFG->dbuser|$CFG->dbpass\";") || die "Failed to read DB info"
DBTYPE=$(echo "$DBINFO" | cut -d'|' -f1)
DBHOST=$(echo "$DBINFO" | cut -d'|' -f2)
DBNAME=$(echo "$DBINFO" | cut -d'|' -f3)
DBUSER=$(echo "$DBINFO" | cut -d'|' -f4)
DBPASS=$(echo "$DBINFO" | cut -d'|' -f5)

# ---------- backups ----------
log "Creating database backup"
DBBK="$BACKUP_DIR/db_${DBNAME}_${TIMESTAMP}.sql.gz"
case "$DBTYPE" in
  mysqli|mariadb|mysql)
    if command -v mysqldump >/dev/null; then
      # use a temp my.cnf so password isn't exposed
      MYCNF="$WORKDIR/my.cnf"
      cat > "$MYCNF" <<EOF
[client]
user=$DBUSER
password=$DBPASS
host=$DBHOST
EOF
      chmod 600 "$MYCNF"
      mysqldump --defaults-file="$MYCNF" \
        --single-transaction --routines --triggers --events \
        --hex-blob --default-character-set=utf8mb4 \
        --no-tablespaces \
        "$DBNAME" | gzip -9 > "$DBBK"
    else
      log "mysqldump not found; skipping DB dump for MySQL/MariaDB"
    fi
    ;;
  pgsql|postgres|postgresql)
    if command -v pg_dump >/dev/null; then
      export PGPASSWORD="$DBPASS"
      pg_dump -h "$DBHOST" -U "$DBUSER" -d "$DBNAME" | gzip -9 > "$DBBK"
      unset PGPASSWORD
    else
      log "pg_dump not found; skipping DB dump for PostgreSQL"
    fi
    ;;
  *)
    log "Unknown DBTYPE '$DBTYPE' - skipping DB dump"
    ;;
esac
[[ -s "$DBBK" ]] && log "DB backup saved to $DBBK" || log "DB backup skipped or empty"

log "Archiving moodledata"
MDZIP="$BACKUP_DIR/moodledata_${TIMESTAMP}.tar.gz"
tar -C "$(dirname "$DATAROOT")" -czf "$MDZIP" "$(basename "$DATAROOT")"

log "Archiving current code (excluding moodledata)"
CODEZIP="$BACKUP_DIR/code_${TIMESTAMP}.tar.gz"
PARENT=$(dirname "$WWWROOT")
BASENAME=$(basename "$WWWROOT")
# exclude huge caches/local dirs from code backup
 tar -C "$PARENT" --exclude="$BASENAME/.git" -czf "$CODEZIP" "$BASENAME"

# ---------- prepare new code ----------
log "Extracting new Moodle package"
EXTRACTDIR="$WORKDIR/newcode"
mkdir -p "$EXTRACTDIR"
tar -xzf "$TMPDL" -C "$EXTRACTDIR"
[[ -d "$EXTRACTDIR/moodle" ]] || die "Package did not contain 'moodle' directory"

log "Moving old code aside and deploying new code"
OLD_DIR="${WWWROOT}.old_${TIMESTAMP}"
mkdir -p "$OLD_DIR"
# move contents (not the folder itself) to preserve possible bind mounts
shopt -s dotglob
mv "$WWWROOT"/* "$OLD_DIR"/
shopt -u dotglob

# copy new code in place
cp -a "$EXTRACTDIR/moodle"/* "$WWWROOT"/

# restore config.php
cp -a "$OLD_DIR/config.php" "$WWWROOT/"

# carry over custom plugins (present in old code but not in new)
log "Carrying over third-party plugins if any (mod/, blocks/, theme/, local/, question/, auth/)"
for comp in mod blocks theme local question auth report tool enrol filter availability; do
  if [[ -d "$OLD_DIR/$comp" ]]; then
    while IFS= read -r -d '' plugin; do
      name=$(basename "$plugin")
      if [[ ! -e "$WWWROOT/$comp/$name" ]]; then
        log "→ copying $comp/$name"
        cp -a "$plugin" "$WWWROOT/$comp/"
      fi
    done < <(find "$OLD_DIR/$comp" -mindepth 1 -maxdepth 1 -type d -print0)
  fi
done

# permissions
log "Fixing ownership and permissions"
chown -R "$WEB_USER":"$WEB_USER" "$WWWROOT" "$DATAROOT"
find "$WWWROOT" -type f -exec chmod 0640 {} +
find "$WWWROOT" -type d -exec chmod 0750 {} +

# ---------- run upgrade ----------
log "Running Moodle CLI upgrade"
cd "$WWWROOT"
sudo -u "$WEB_USER" php admin/cli/upgrade.php --non-interactive || die "Upgrade failed"

# ---------- purge caches ----------
log "Purging caches"
sudo -u "$WEB_USER" php admin/cli/purge_caches.php || true

# ---------- disable maintenance ----------
log "Disabling maintenance mode"
sudo -u "$WEB_USER" php admin/cli/maintenance.php --disable || true

# ---------- restart Apache ----------
log "Restarting Apache ($APACHE_SERVICE)"
systemctl reload "$APACHE_SERVICE" || systemctl restart "$APACHE_SERVICE" || true

log "Upgrade completed. Old code kept at: $OLD_DIR"
log "Backups:\n  DB:       $DBBK\n  moodledata: $MDZIP\n  code:     $CODEZIP"

