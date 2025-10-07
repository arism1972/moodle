#!/usr/bin/env bash
set -euo pipefail

# === CONFIG (προσαρμόζεις αν χρειάζεται) ===
WWWROOT="/var/www/html/moodle"
DATAROOT="/var/moodledata"
WEB_USER="www-data"

# === Στόχοι αναβάθμισης ===
# Ελέγχουμε αν πληροίς τις απαιτήσεις για 4.1 (πρώτο βήμα) και 4.5 (δεύτερο βήμα)
REQ_41_PHP_MIN="7.4.0"
REQ_41_MYSQL_MIN="5.7.0"
REQ_41_MARIA_MIN="10.4.0"
REQ_41_PG_MIN="12.0"

REQ_45_PHP_MIN="8.1.0"
REQ_45_MYSQL_MIN="8.0.0"
REQ_45_MARIA_MIN="10.6.7"
REQ_45_PG_MIN="13.0"

# === Helpers ===
ver_ge() { php -r "exit(version_compare('$1','$2','>=')?0:1);"; }  # returns 0 if $1 >= $2
pass() { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*"; }
fail() { echo -e "❌ $*"; }

echo "=== Moodle Preflight Check ==="
echo "WWWROOT : $WWWROOT"
echo "DATAROOT: $DATAROOT"
echo

[[ -f "$WWWROOT/config.php" ]] || { fail "Δεν βρέθηκε $WWWROOT/config.php"; exit 1; }

# PHP version
PHPV=$(php -r 'echo PHP_VERSION;')
echo "PHP      : $PHPV"
if ver_ge "$PHPV" "$REQ_45_PHP_MIN"; then
  pass "PHP OK για 4.5+"
elif ver_ge "$PHPV" "$REQ_41_PHP_MIN"; then
  pass "PHP OK για 4.1 (αλλά ΟΧΙ για 4.5 — θα χρειαστείς αναβάθμιση PHP μετά το 4.1)"
else
  fail "PHP < $REQ_41_PHP_MIN — χρειάζεται αναβάθμιση PHP πριν από 4.1"
fi

# PHP modules
NEEDED_MODS_41=(intl mbstring curl gd xml zip soap exif)
NEEDED_MODS_45=(sodium "${NEEDED_MODS_41[@]}")

PHP_MODS=$(php -m | tr '[:upper:]' '[:lower:]')
missing_41=()
missing_45=()
for m in "${NEEDED_MODS_41[@]}"; do echo "$PHP_MODS" | grep -q "^$m$" || missing_41+=("$m"); done
for m in "${NEEDED_MODS_45[@]}"; do echo "$PHP_MODS" | grep -q "^$m$" || missing_45+=("$m"); done

if [ ${#missing_41[@]} -eq 0 ]; then pass "PHP modules OK για 4.1"; else warn "Λείπουν (4.1): ${missing_41[*]}"; fi
if [ ${#missing_45[@]} -eq 0 ]; then pass "PHP modules OK για 4.5 (περιλαμβάνει sodium)"; else warn "Λείπουν (4.5): ${missing_45[*]}"; fi

# PHP ini: max_input_vars
MIV=$(php -r "echo (int)ini_get('max_input_vars');")
if [ "$MIV" -ge 5000 ]; then pass "max_input_vars=$MIV (OK για 4.5)"; else warn "max_input_vars=$MIV (<5000). Ρύθμισε σε >=5000 για PHP 8.x"; fi

# Διαβάζουμε DB στοιχεία από config.php
IFS='|' read -r DBTYPE DBHOST DBNAME DBUSER DBPASS DBDRIVER DBCOLLATION DBPREFIX <<<"$(php -r "
define('CLI_SCRIPT', true);
require '$WWWROOT/config.php';
echo \"$CFG->dbtype|$CFG->dbhost|$CFG->dbname|$CFG->dbuser|$CFG->dbpass|$CFG->dbtype|\".($CFG->dboptions['dbcollation']??'').\"|$CFG->prefix\";
")"

echo "DB type  : $DBTYPE"
echo "DB host  : $DBHOST"
echo "DB name  : $DBNAME"
echo "DB prefix: ${DBPREFIX:-'(default mdl_)'}"

# Prefix length check (<=10 για 4.5)
plen=${#DBPREFIX}
if [ "$plen" -le 10 ]; then pass "DB prefix length=$plen (OK για 4.5)"; else fail "DB prefix length=$plen (>10) — απαιτείται ≤10 για 4.5"; fi

# Συνδέσου στη βάση και έλεγξε version
DBV="unknown"
DBFLAVOR="unknown"
if [[ "$DBTYPE" =~ ^(mysqli|mariadb|mysql)$ ]]; then
  if command -v mysql >/dev/null 2>&1; then
    DBV=$(mysql -N -h "$DBHOST" -u "$DBUSER" -p"$DBPASS" -e "SELECT VERSION();" 2>/dev/null || echo "unknown")
    if echo "$DBV" | grep -qi mariadb; then DBFLAVOR="mariadb"; else DBFLAVOR="mysql"; fi
    echo "DB ver   : $DBV ($DBFLAVOR)"
    if [ "$DBFLAVOR" = "mysql" ]; then
      if ver_ge "${DBV%%-*}" "$REQ_45_MYSQL_MIN"; then pass "DB OK για 4.5"; 
      elif ver_ge "${DBV%%-*}" "$REQ_41_MYSQL_MIN"; then pass "DB OK για 4.1 (όχι 4.5)"; else fail "DB < $REQ_41_MYSQL_MIN — αναβάθμιση DB"; fi
    else
      if ver_ge "${DBV%%-*}" "$REQ_45_MARIA_MIN"; then pass "DB OK για 4.5";
      elif ver_ge "${DBV%%-*}" "$REQ_41_MARIA_MIN"; then pass "DB OK για 4.1 (όχι 4.5)"; else fail "DB < $REQ_41_MARIA_MIN — αναβάθμιση MariaDB"; fi
    fi
  else
    warn "Δεν βρέθηκε mysql client· δεν έγινε έλεγχος έκδοσης DB"
  fi

elif [[ "$DBTYPE" =~ ^(pgsql|postgres|postgresql)$ ]]; then
  if command -v psql >/dev/null 2>&1; then
    DBV=$(PGPASSWORD="$DBPASS" psql -h "$DBHOST" -U "$DBUSER" -d "$DBNAME" -tAc "SHOW server_version;" 2>/dev/null || echo "unknown")
    DBFLAVOR="postgresql"
    echo "DB ver   : $DBV ($DBFLAVOR)"
    if ver_ge "$DBV" "$REQ_45_PG_MIN"; then pass "DB OK για 4.5";
    elif ver_ge "$DBV" "$REQ_41_PG_MIN"; then pass "DB OK για 4.1 (όχι 4.5)"; else fail "DB < $REQ_41_PG_MIN — αναβάθμιση PostgreSQL"; fi
  else
    warn "Δεν βρέθηκε psql· δεν έγινε έλεγχος έκδοσης DB"
  fi
else
  warn "Άγνωστος DB τύπος στο config.php: $DBTYPE"
fi

# moodledata write test
if sudo -u "$WEB_USER" bash -c "test -w \"$DATAROOT\" && touch \"$DATAROOT/_writetest\" && rm \"$DATAROOT/_writetest\""; then
  pass "moodledata writeable από $WEB_USER"
else
  fail "moodledata ΜΗ writeable από $WEB_USER — έλεγξε ownership/permissions"
fi

# Δίσκος (εκτίμηση: ελεύθερα >= μέγεθος moodledata + 1GB)
MD_SIZE_K=$(du -sk "$DATAROOT" | awk '{print $1}')
FREE_K=$(df -k "$DATAROOT" | awk 'NR==2{print $4}')
NEEDED_K=$((MD_SIZE_K + 1048576))
if [ "$FREE_K" -ge "$NEEDED_K" ]; then
  pass "Ελεύθερος χώρος OK (free=$(numfmt --to=iec $((FREE_K*1024))) / moodledata=$(numfmt --to=iec $((MD_SIZE_K*1024))))"
else
  warn "Λίγος χώρος: free=$(numfmt --to=iec $((FREE_K*1024))) < needed~$(numfmt --to=iec $((NEEDED_K*1024)))"
fi

# Προαιρετικά: Moodle CLI checks (αν υπάρχει)
if [ -f "$WWWROOT/admin/cli/checks.php" ]; then
  echo
  echo "— Moodle CLI checks —"
  sudo -u "$WEB_USER" php "$WWWROOT/admin/cli/checks.php" || true
fi

echo
echo "→ Σύσταση: τρέξε και το Environment report στο UI:"
echo "   Site administration → Server → Environment (επιλέγεις Target version 4.1 και μετά 4.5)"
