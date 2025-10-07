#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# MySQL 8.4 LTS Upgrade Script for Ubuntu 24.04 (Noble)
# -----------------------------------------------------------------------------
# Τι κάνει:
#  - Ελέγχει τρέχουσα έκδοση MySQL και απαιτήσεις εργαλείων
#  - Παίρνει ασφαλές backup όλων των βάσεων (mysqldump --all-databases)
#  - Προσθέτει / ενημερώνει το επίσημο MySQL APT repository
#  - Ρυθμίζει το repo να χρησιμοποιεί το component "mysql-8.4" (LTS)
#  - Εκτελεί apt update && apt install mysql-server για αναβάθμιση στην 8.4.x
#  - Κάνει επανεκκίνηση υπηρεσίας και έλεγχο έκδοσης
#
# Τεκμηρίωση:
#  - MySQL APT Repository (προσθήκη/αναβάθμιση): https://dev.mysql.com/doc/mysql-apt-repo-quick-guide/en/
#  - Αναβάθμιση MySQL 8.4 (γενικές οδηγίες & βέλτιστες πρακτικές): https://dev.mysql.com/doc/refman/8.4/en/upgrading.html
#  - Εγκατάσταση MySQL σε Linux με APT: https://dev.mysql.com/doc/refman/8.4/en/linux-installation-apt-repo.html
# -----------------------------------------------------------------------------
set -Eeuo pipefail

# ---------------------- ΡΥΘΜΙΣΕΙΣ ΧΡΗΣΤΗ ------------------------------------
BACKUP_DIR_BASE="/var/backups/mysql"
MYSQL_APT_URL_DEFAULT="https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb"  # μπορείς να το αλλάξεις σε νεότερο
REPO_LIST_GLOB="/etc/apt/sources.list.d/mysql*.list"

# Επιλογές
DRY_RUN=false
SKIP_BACKUP=false
APT_PKG_URL="$MYSQL_APT_URL_DEFAULT"

usage() {
  cat <<USAGE
Χρήση: sudo bash $(basename "$0") [επιλογές]

Επιλογές:
  --dry-run             Εκτέλεση χωρίς αλλαγές (echo μόνο)
  --skip-backup         Παράλειψη backup όλων των βάσεων (ΔΕΝ προτείνεται)
  --repo-url <URL>      URL για το mysql-apt-config .deb (προεπιλογή: $MYSQL_APT_URL_DEFAULT)
  -h, --help            Εμφάνιση βοήθειας

Το script:
  1) Ελέγχει ότι είσαι root και ότι υπάρχουν wget, dpkg, apt, mysql, mysqldump.
  2) Παίρνει backup όλων των βάσεων σε /var/backups/mysql/<timestamp>/all-dbs.sql.gz
  3) Προσθέτει/ανανεώνει το επίσημο MySQL APT repo και επιλέγει το component mysql-8.4 (LTS)
  4) Κάνει apt update && apt install -y mysql-server
  5) Επανεκκινεί υπηρεσία και εμφανίζει την νέα έκδοση
USAGE
}

# ---------------------- ΒΟΗΘΗΤΙΚΕΣ ΣΥΝΑΡΤΗΣΕΙΣ ------------------------------
log() { echo -e "[MySQL 8.4 UPG] $*"; }
run() { if $DRY_RUN; then log "DRY-RUN: $*"; else eval "$@"; fi }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Απαιτείται η εντολή: $1"; exit 1; }; }
require_root() { [[ $EUID -eq 0 ]] || { echo "Πρέπει να τρέξεις ως root"; exit 1; }; }

ver_num() { # μετατροπή X.Y σε σύγκριση
  printf "%03d%03d" ${1%%.*} ${1#*.}
}

current_mysql_version() {
  local v
  v=$(mysql --version 2>/dev/null | sed -n 's/.*Distrib \([0-9]\+\.[0-9]\+\).*/\1/p')
  echo "$v"
}

backup_all_dbs() {
  local TS BACKUP_DIR MYCNF DUMP
  TS=$(date +%Y%m%d%H%M%S)
  BACKUP_DIR="$BACKUP_DIR_BASE/$TS"
  mkdir -p "$BACKUP_DIR"
  MYCNF="$BACKUP_DIR/.my.cnf"
  DUMP="$BACKUP_DIR/all-dbs.sql"

  # Προσπάθεια χρήσης socket auth (sudo mysql). Αν αποτύχει, ζήτα στοιχεία
  if mysql -e 'SELECT 1' >/dev/null 2>&1; then
    log "✳️  Παίρνω backup όλων των βάσεων (socket auth) → $DUMP.gz"
    run "mysqldump --all-databases --single-transaction --quick --routines --triggers --events > '$DUMP'"
  else
    log "ℹ Δεν ήταν εφικτή σύνδεση με socket. Θα ζητηθούν διαπιστευτήρια για backup."
    read -rp "MySQL host [localhost]: " HOST; HOST=${HOST:-localhost}
    read -rp "MySQL user [root]: " USER; USER=${USER:-root}
    read -rsp "Password for $USER@$HOST: " PASS; echo
    umask 077
    cat > "$MYCNF" <<EOF
[client]
user=$USER
password=$PASS
host=$HOST
EOF
    log "✳️  Παίρνω backup όλων των βάσεων → $DUMP.gz"
    run "mysqldump --defaults-extra-file='$MYCNF' --all-databases --single-transaction --quick --routines --triggers --events > '$DUMP'"
  fi
  run "gzip -f '$DUMP'"
  log "📦 Backup ολοκληρώθηκε: $DUMP.gz"
}

install_mysql_apt_repo() {
  local TMP_DEB="/tmp/mysql-apt-config.deb"
  log "⬇️  Λήψη MySQL APT config από: $APT_PKG_URL"
  run "wget -qO '$TMP_DEB' '$APT_PKG_URL'"
  log "📦 Εγκατάσταση πακέτου mysql-apt-config"
  # Η εγκατάσταση είναι συνήθως διαδραστική. Θα διορθώσουμε το component κατόπιν με sed.
  run "DEBIAN_FRONTEND=noninteractive dpkg -i '$TMP_DEB' || true"

  # Εξασφάλισε ότι το component server είναι mysql-8.4 (LTS) στα mysql*.list αρχεία
  for f in $REPO_LIST_GLOB; do
    [[ -f "$f" ]] || continue
    if grep -qE '\bmysql-(8\.0|innovation)\b' "$f"; then
      log "🛠 Αλλαγή component σε mysql-8.4 στο $f"
      run "sed -ri 's/\bmysql-(innovation|8\.0)\b/mysql-8.4/g' '$f'"
    fi
    log "➡ Περιεχόμενο $f:"; cat "$f" || true
  done
}

apt_update_and_upgrade() {
  log "🔄 apt update"
  run "apt update"
  log "⬆️  Εγκατάσταση/Αναβάθμιση mysql-server → 8.4.x (σύμφωνα με το repo)"
  run "DEBIAN_FRONTEND=noninteractive apt install -y mysql-server"
}

restart_and_verify() {
  log "🔁 Επανεκκίνηση υπηρεσίας MySQL"
  run "systemctl restart mysql"
  sleep 2
  run "systemctl is-active --quiet mysql"
  local ver
  ver=$(current_mysql_version)
  log "✅ Τρέχουσα έκδοση MySQL: ${ver:-άγνωστη}"
  if [[ -n "$ver" && $(ver_num "$ver") -lt $(ver_num 8.4) ]]; then
    log "❌ Η έκδοση παραμένει <$ver>. Έλεγξε τα repo αρχεία στο $REPO_LIST_GLOB και ξαναδοκίμασε."
    exit 1
  fi
}

# ---------------------- ΚΥΡΙΟ ΠΡΟΓΡΑΜΜΑ --------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --skip-backup) SKIP_BACKUP=true; shift ;;
    --repo-url) APT_PKG_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Άγνωστη επιλογή: $1"; usage; exit 1 ;;
  esac
done

require_root
need_cmd wget; need_cmd dpkg; need_cmd apt; need_cmd mysql; need_cmd mysqldump; need_cmd systemctl; need_cmd sed; need_cmd gzip

CURRENT_VER=$(current_mysql_version || true)
if [[ -n "$CURRENT_VER" ]]; then
  log "Εντοπίστηκε MySQL: $CURRENT_VER"
  if [[ $(ver_num "$CURRENT_VER") -ge $(ver_num 8.4) ]]; then
    log "ℹ Ήδη σε MySQL >= 8.4. Δεν απαιτείται αναβάθμιση."
    exit 0
  fi
else
  log "⚠ Δεν βρέθηκε τρέχουσα εγκατάσταση MySQL ή το client binary. Θα προχωρήσουμε στην εγκατάσταση 8.4."
fi

if ! $SKIP_BACKUP; then
  backup_all_dbs
else
  log "⏭ Παράλειψη backup όπως ζητήθηκε (ΜΗ ΠΡΟΤΕΙΝΕΤΑΙ)."
fi

install_mysql_apt_repo
apt_update_and_upgrade
restart_and_verify

log "🎉 Ολοκληρώθηκε η μετάβαση σε MySQL 8.4.x. Συνιστάται έλεγχος εφαρμογών και logs: /var/log/mysql/*.log"
# -----------------------------------------------------------------------------
