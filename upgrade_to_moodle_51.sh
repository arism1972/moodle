#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Αναβάθμιση Moodle σε 5.1 σε Ubuntu 24.04
# - Υποστηρίζει: backup (code, DB, moodledata), έλεγχο PHP/MySQL, (προαιρετικά) upgrade MySQL,
#   λήψη καθαρού Moodle 5.1 (MOODLE_501_STABLE), αντιγραφή config.php & custom plugins,
#   προσαρμογή Apache DocumentRoot στο /public, εκτέλεση CLI upgrade, cron & purge caches.
# - Δεν κάνει manual έλεγχο συμβατότητας plugins.
#
# Τεκμηρίωση Moodle 5.0/5.1 (απαιτήσεις & αλλαγές):
# * Απαιτήσεις Moodle 5.0/5.1 (PHP>=8.2, MySQL>=8.4): https://moodledev.io/general/releases/5.0
# * Νέα δομή με φάκελο public/ στο Moodle 5.1: https://moodledev.io/general/releases/5.1
# * Οδηγός αναβάθμισης: https://docs.moodle.org/en/Upgrading
# -----------------------------------------------------------------------------
set -Eeuo pipefail

# ------------- Ρυθμίσεις Χρήστη ------------------------------------------------
# Ρύθμισε τις παρακάτω μεταβλητές ανάλογα με το σύστημά σου.
MOODLE_DIR="/var/www/moodle"           # Τρέχων φάκελος κώδικα Moodle
MOODLEDATA_DIR=""                      # Αν είναι κενό, θα εξαχθεί από το config.php
BACKUP_DIR_BASE="/var/backups/moodle"  # Πού θα φυλαχθούν τα backup
WEB_USER="www-data"                    # Χρήστης του web server (Apache)
GIT_BRANCH="MOODLE_501_STABLE"         # Branch για Moodle 5.1
APACHE_VHOST_FILE=""                   # Π.χ. /etc/apache2/sites-available/moodle.conf (αν μείνει κενό, δεν αλλάζει αυτόματα)
APACHE_SERVICE="apache2"

# Επιλογές συμπεριφοράς
DRY_RUN=false                 # true=δεν εκτελεί εντολές που αλλάζουν το σύστημα
AUTO_ROLLBACK=false           # true=σε αποτυχία, επαναφέρει κώδικα & DB
ALLOW_MYSQL_AUTO_UPGRADE=false # true=δοκίμασε αυτόματο major upgrade σε MySQL 8.4 (ΠΕΙΡΑΜΑΤΙΚΟ)
SKIP_MYSQL_CHECK=false         # true=παράλειψη ελέγχου/αναβάθμισης MySQL (με δική σου ευθύνη)

# ------------- Εσωτερικές μεταβλητές -----------------------------------------
TS="$(date +%Y%m%d%H%M%S)"
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/moodle51-upgrade-$TS.log"
MOODLE_OLD_DIR="${MOODLE_DIR}_old_$TS"
MOODLE_NEW_DIR="${MOODLE_DIR}_new_$TS"
BACKUP_DIR="$BACKUP_DIR_BASE/$TS"
DB_DUMP_FILE="$BACKUP_DIR/db_backup.sql"
CONFIG_FILE="$MOODLE_DIR/config.php"

# ------------- Βοηθητικές συναρτήσεις ----------------------------------------
log() { echo -e "[${TS}] $*" | tee -a "$LOG_FILE" ; }
run() { if $DRY_RUN; then log "DRY-RUN: $*"; else log ">$ $*"; eval "$@" | tee -a "$LOG_FILE"; fi }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Απαιτείται η εντολή $1"; exit 1; }; }

usage() {
  cat <<USAGE
Χρήση: sudo bash $(basename "$0") [επιλογές]

Επιλογές:
  --dry-run                  Δοκιμαστική εκτέλεση (χωρίς αλλαγές)
  --auto-rollback            Αυτόματο rollback σε περίπτωση αποτυχίας
  --allow-mysql-auto         Επιτρέπει απόπειρα αυτόματου upgrade MySQL σε 8.4 (πειραματικό)
  --skip-mysql               Παράλειψη ελέγχου/upgrade MySQL (μη προτείνεται)
  --vhost </path/to/conf>    Ορισμός αρχείου VirtualHost για αυτόματη αλλαγή σε /public

Παράμετροι που μπορείς να αλλάξεις μέσα στο script:
  MOODLE_DIR, MOODLEDATA_DIR, BACKUP_DIR_BASE, WEB_USER, GIT_BRANCH, APACHE_VHOST_FILE
USAGE
}

while [[ ${1:-} ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --auto-rollback) AUTO_ROLLBACK=true ;;
    --allow-mysql-auto) ALLOW_MYSQL_AUTO_UPGRADE=true ;;
    --skip-mysql) SKIP_MYSQL_CHECK=true ;;
    --vhost) shift; APACHE_VHOST_FILE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Άγνωστη επιλογή: $1"; usage; exit 1 ;;
  esac
  shift || true
done

trap 'on_error $LINENO' ERR
on_error() {
  log "❌ Σφάλμα στη γραμμή $1. Δες το log: $LOG_FILE"
  if $AUTO_ROLLBACK; then
    log "🔁 Εκτέλεση rollback..."
    rollback || true
  else
    log "Παράλειψη rollback (δεν έχει ενεργοποιηθεί)."
  fi
  exit 1
}

rollback() {
  # Επαναφορά κώδικα
  if [[ -d "$MOODLE_OLD_DIR" ]]; then
    log "▶ Επαναφορά κώδικα: $MOODLE_OLD_DIR -> $MOODLE_DIR"
    run "rm -rf '$MOODLE_DIR'"
    run "mv '$MOODLE_OLD_DIR' '$MOODLE_DIR'"
  fi
  # Επαναφορά DB
  if [[ -f "$DB_DUMP_FILE" ]]; then
    log "▶ Επαναφορά βάσης από $DB_DUMP_FILE"
    restore_db_from_dump
  fi
  # Apache restart
  if systemctl is-active --quiet "$APACHE_SERVICE"; then
    run "systemctl restart '$APACHE_SERVICE'"
  fi
}

parse_php_cfg_var() {
  # Χρησιμοποιεί PHP για ανάγνωση μεταβλητών από config.php
  local var="$1"
  php -r "include '$CONFIG_FILE'; echo isset(\$CFG->$var) ? \$CFG->$var : '';" 2>/dev/null
}

require_root() {
  if [[ $EUID -ne 0 ]]; then echo "Πρέπει να τρέξει ως root"; exit 1; fi
}

check_prereqs() {
  need_cmd php; need_cmd mysql; need_cmd mysqldump; need_cmd git; need_cmd tar; need_cmd tee
  if systemctl list-units | grep -q "$APACHE_SERVICE"; then need_cmd a2enmod; fi
}

check_php() {
  local phpver; phpver=$(php -r 'echo PHP_VERSION;')
  log "PHP έκδοση: $phpver"
  # Απαίτηση: >= 8.2
  php -r 'exit(version_compare(PHP_VERSION, "8.2.0", ">=")?0:1);' || { echo "Απαιτείται PHP >= 8.2"; exit 1; }
  # Έλεγχος sodium
  if ! php -m | grep -qi '^sodium$'; then
    log "⚠ Το PHP extension 'sodium' δεν βρέθηκε. Απαιτείται από Moodle 5.x. Εγκατάστησέ το (π.χ. php8.3-sodium)."
  fi
  # Έλεγχος max_input_vars
  local miv; miv=$(php -r 'echo ini_get("max_input_vars");')
  if [[ -z "$miv" || "$miv" -lt 5000 ]]; then
    log "⚠ PHP max_input_vars=$miv (<5000). Πρότεινεται 5000+ για Moodle 5.x. Ρύθμισέ το στο php.ini και κάνε restart Apache."
  fi
}

ver() { printf "%03d%03d" ${1%%.*} ${1#*.}; }

check_mysql() {
  local v; v=$(mysql --version | sed -n 's/.*Distrib \([0-9]\+\.[0-9]\+\).*/\1/p')
  log "MySQL έκδοση: ${v:-άγνωστη}"
  if $SKIP_MYSQL_CHECK; then
    log "⏭ Παράκαμψη ελέγχου MySQL όπως ζητήθηκε."
    return 0
  fi
  if [[ -z "$v" ]]; then echo "Αδυναμία εντοπισμού MySQL έκδοσης"; exit 1; fi
  # Απαίτηση: >= 8.4
  if (( $(ver "$v") < $(ver 8.4) )); then
    log "❗ Απαιτείται MySQL >= 8.4 για Moodle 5.x."
    if $ALLOW_MYSQL_AUTO_UPGRADE; then
      upgrade_mysql_84
    else
      cat <<MSG | tee -a "$LOG_FILE"
Η αναβάθμιση σε MySQL 8.4 δεν θα γίνει αυτόματα. Εκτέλεσε χειροκίνητα τα εξής και ξανά-τρέξε το script:

  wget -O /tmp/mysql-apt-config.deb https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb
  sudo DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb
  sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y mysql-server
  mysql --version   # Πρέπει να δείξει 8.4.x

(Σύμφωνα με τις απαιτήσεις του Moodle 5.0/5.1)
MSG
      exit 1
    fi
  fi
}

upgrade_mysql_84() {
  log "🛠 Απόπειρα αυτόματης αναβάθμισης MySQL σε 8.4 (πειραματικό)"
  run "wget -qO /tmp/mysql-apt-config.deb https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb"
  run "DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb"
  run "apt update"
  run "DEBIAN_FRONTEND=noninteractive apt install -y mysql-server"
  mysql --version | tee -a "$LOG_FILE"
}

prepare_dirs() {
  run "mkdir -p '$BACKUP_DIR' '$BACKUP_DIR_BASE'"
  run "touch '$LOG_FILE'"
}

extract_cfg() {
  if [[ ! -f "$CONFIG_FILE" ]]; then echo "Δεν βρέθηκε $CONFIG_FILE"; exit 1; fi
  DB_NAME="$(parse_php_cfg_var dbname)"
  DB_USER="$(parse_php_cfg_var dbuser)"
  DB_PASS="$(parse_php_cfg_var dbpass)"
  DB_HOST="$(parse_php_cfg_var dbhost)"
  if [[ -z "${MOODLEDATA_DIR}" ]]; then
    MOODLEDATA_DIR="$(parse_php_cfg_var dataroot)"
  fi
  log "DB: $DB_NAME@$DB_HOST (user=$DB_USER)"
  log "moodledata: $MOODLEDATA_DIR"
}

backup_all() {
  log "📦 Backup code, moodledata, database στο $BACKUP_DIR"
  run "tar -C '$(dirname "$MOODLE_DIR")' -czf '$BACKUP_DIR/moodle_code.tar.gz' '$(basename "$MOODLE_DIR")'"
  run "tar -C '$(dirname "$MOODLEDATA_DIR")' -czf '$BACKUP_DIR/moodledata.tar.gz' '$(basename "$MOODLEDATA_DIR")'"
  # Secure my.cnf για mysqldump
  local MYCNF="$BACKUP_DIR/.my.cnf"
  run "umask 077 && printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' '$DB_USER' '$DB_PASS' '${DB_HOST:-localhost}' > '$MYCNF'"
  run "mysqldump --defaults-extra-file='$MYCNF' --single-transaction --quick --routines --triggers '$DB_NAME' > '$DB_DUMP_FILE'"
}

maintenance_on()  { run "sudo -u '$WEB_USER' php '$MOODLE_DIR/admin/cli/maintenance.php' --enable"; }
maintenance_off() { run "sudo -u '$WEB_USER' php '$MOODLE_DIR/admin/cli/maintenance.php' --disable"; }

fetch_new_moodle() {
  log "⬇️  Λήψη καθαρού Moodle ($GIT_BRANCH) στο $MOODLE_NEW_DIR"
  run "git clone -b '$GIT_BRANCH' --depth 1 git://git.moodle.org/moodle.git '$MOODLE_NEW_DIR'"
  # Αντιγραφή config.php
  run "cp -a '$CONFIG_FILE' '$MOODLE_NEW_DIR/'"
}

copy_custom_plugins() {
  log "📦 Ανίχνευση & αντιγραφή custom plugins από το παλιό codebase"
  # Λίστα πιθανών περιοχών plugins
  mapfile -t AREAS <<'EOF'
  auth
  blocks
  course/format
  editor
  enrol
  filter
  grade/export
  grade/import
  grade/report
  grading/form
  local
  media/player
  message/output
  mod
  plagiarism
  portfolio
  qtype
  question/behaviour
  question/format
  repository
  report
  theme
  tool
  webservice
EOF
  for area in "${AREAS[@]}"; do
    local src="$MOODLE_OLD_DIR/$area"
    local dst="$MOODLE_NEW_DIR/$area"
    [[ -d "$src" && -d "$dst" ]] || continue
    # Για κάθε υποφάκελο στο src που ΔΕΝ υπάρχει στο dst => θεωρείται custom plugin
    for p in "$src"/*; do
      [[ -d "$p" ]] || continue
      local name="$(basename "$p")"
      if [[ ! -d "$dst/$name" ]]; then
        log "→ Custom plugin: $area/$name"
        run "cp -a '$p' '$dst/'"
      fi
    done
  done
}

switch_code() {
  log "🔁 Εναλλαγή codebase: $MOODLE_DIR -> $MOODLE_OLD_DIR και νέο -> $MOODLE_DIR"
  run "mv '$MOODLE_DIR' '$MOODLE_OLD_DIR'"
  run "mv '$MOODLE_NEW_DIR' '$MOODLE_DIR'"
}

update_apache_vhost() {
  if [[ -z "$APACHE_VHOST_FILE" || ! -f "$APACHE_VHOST_FILE" ]]; then
    log "ℹ Παράλειψη αυτόματης αλλαγής VirtualHost (APACHE_VHOST_FILE δεν δόθηκε/δεν βρέθηκε)."
    log "   Ρύθμισε χειροκίνητα DocumentRoot/Directory σε: $MOODLE_DIR/public και κάνε restart Apache."
    return 0
  fi
  log "🛠 Ενημέρωση VirtualHost: $APACHE_VHOST_FILE -> DocumentRoot/Directory -> $MOODLE_DIR/public"
  run "cp -a '$APACHE_VHOST_FILE' '${APACHE_VHOST_FILE}.bak.$TS'"
  run "sed -ri 's#^(\s*DocumentRoot\s+).*#\1$MOODLE_DIR/public#' '$APACHE_VHOST_FILE'"
  run "sed -ri 's#^(\s*<Directory\s+).*(>)#\1$MOODLE_DIR/public\2#' '$APACHE_VHOST_FILE' || true"
  run "a2enmod rewrite || true"
  run "systemctl reload '$APACHE_SERVICE'"
}

run_upgrade() {
  log "🚀 Εκτέλεση CLI αναβάθμισης"
  run "sudo -u '$WEB_USER' php '$MOODLE_DIR/admin/cli/upgrade.php' --non-interactive --allow-unstable=0"
}

post_tasks() {
  log "🧹 Καθαρισμός cache & έλεγχος cron"
  run "sudo -u '$WEB_USER' php '$MOODLE_DIR/admin/cli/purge_caches.php'"
  run "sudo -u '$WEB_USER' php '$MOODLE_DIR/admin/cli/cron.php'"
}

restore_db_from_dump() {
  local MYCNF="$BACKUP_DIR/.my.cnf"
  if [[ ! -f "$MYCNF" ]]; then
    # Δημιουργία προσωρινού my.cnf αν λείπει (χρήση τιμών από config)
    run "umask 077 && printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' '$DB_USER' '$DB_PASS' '${DB_HOST:-localhost}' > '$MYCNF'"
  fi
  run "mysql --defaults-extra-file='$MYCNF' '$DB_NAME' < '$DB_DUMP_FILE'"
}

main() {
  require_root
  prepare_dirs
  check_prereqs
  check_php
  check_mysql
  extract_cfg

  maintenance_on
  backup_all

  fetch_new_moodle
  copy_custom_plugins
  switch_code
  update_apache_vhost

  run_upgrade

  post_tasks
  maintenance_off

  log "✅ Αναβάθμιση ολοκληρώθηκε. Log: $LOG_FILE | Backups: $BACKUP_DIR"
  log "👉 Έλεγξε τη λειτουργία στο browser και το Site administration > Notifications."
}

main "$@"
