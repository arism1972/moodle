#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Moodle 5.1 Clean Setup & Apache/Public Check (Ubuntu 24.04)
# ----------------------------------------------------------------------------
# This script automates end-to-end setup for a clean Moodle 5.1 install on
# Ubuntu 24.04 with Apache2, PHP 8.x, and MySQL (8.4 LTS or 9.x Innovation).
# It also validates Apache VirtualHost points to the new Moodle 5.1 `public/`
# folder and runs CLI install + basic post-install checks.
#
# References:
# - Moodle 5.1 public/ document root change: https://moodledev.io/general/releases/5.1
# - CLI install/upgrade docs: https://docs.moodle.org/en/Upgrading
#
# Usage:
#   sudo bash moodle51_setup.sh \
#     --wwwroot https://dev.moodle.myenglishhub.gr \
#     --moodledir /var/www/html/moodle \
#     --dataroot /var/moodledata \
#     --dbname moodle \
#     --dbuser moodleuser \
#     --dbpass 'yourpassword' \
#     --adminuser admin \
#     --adminpass 'StrongPass123!' \
#     --adminemail you@example.com \
#     --sitefullname "Moodle Dev" \
#     --siteshortname "MoodleDev"
#
# Optional flags:
#   --domain dev.moodle.myenglishhub.gr      # overrides host derived from wwwroot
#   --dropdb                                 # drops DB if exists before (clean)
#   --skip-apache                            # do not modify Apache vhost
#   --skip-git                               # do not git clone (assume code exists)
#   --dry-run                                # print steps only
#
# Output: Writes a log and exits non-zero on error.
# ----------------------------------------------------------------------------
set -Eeuo pipefail

LOG_FILE="/var/log/moodle51-setup-$(date +%Y%m%d%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------- defaults ----------------------
WWWROOT=""
MOODLEDIR="/var/www/html/moodle"
DATAROOT="/var/moodledata"
DBNAME="moodle"
DBUSER="moodleuser"
DBPASS=""
ADMINUSER="admin"
ADMINPASS=""
ADMINEMAIL="admin@example.com"
SITEFULLNAME="Moodle Site"
SITESHORTNAME="Moodle"
DOMAIN=""
DROPDB=false
SKIP_APACHE=false
SKIP_GIT=false
DRY_RUN=false

# ---------------------- helpers ----------------------
usage(){ cat <<USAGE
Usage: sudo bash $0 --wwwroot <URL> --dbpass <pass> --adminpass <pass> [options]
Required:
  --wwwroot URL                 e.g. https://dev.example.org
  --dbpass  PASSWORD            MySQL password for DB user
  --adminpass PASSWORD          Moodle admin password
Optional:
  --moodledir PATH              default: /var/www/html/moodle
  --dataroot PATH               default: /var/moodledata
  --dbname NAME                 default: moodle
  --dbuser USER                 default: moodleuser
  --adminuser USER              default: admin
  --adminemail EMAIL            default: admin@example.com
  --sitefullname NAME           default: "Moodle Site"
  --siteshortname NAME          default: "Moodle"
  --domain FQDN                 overrides host derived from --wwwroot
  --dropdb                      drop & recreate database before install
  --skip-apache                 do not touch Apache vhost
  --skip-git                    do not git clone (assumes MOODLEDIR exists)
  --dry-run                     print actions but do not apply changes
USAGE
}

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
run(){ if $DRY_RUN; then echo "DRY-RUN: $*"; else eval "$@"; fi }
fail(){ echo "ERROR: $*"; exit 1; }

derive_domain(){
  local url="$1" host
  host=$(echo "$url" | sed -E 's#^https?://([^/]+)/?.*$#\1#')
  echo "$host"
}

# ---------------------- parse args ----------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wwwroot) WWWROOT="$2"; shift 2;;
    --moodledir) MOODLEDIR="$2"; shift 2;;
    --dataroot) DATAROOT="$2"; shift 2;;
    --dbname) DBNAME="$2"; shift 2;;
    --dbuser) DBUSER="$2"; shift 2;;
    --dbpass) DBPASS="$2"; shift 2;;
    --adminuser) ADMINUSER="$2"; shift 2;;
    --adminpass) ADMINPASS="$2"; shift 2;;
    --adminemail) ADMINEMAIL="$2"; shift 2;;
    --sitefullname) SITEFULLNAME="$2"; shift 2;;
    --siteshortname) SITESHORTNAME="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --dropdb) DROPDB=true; shift;;
    --skip-apache) SKIP_APACHE=true; shift;;
    --skip-git) SKIP_GIT=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

[[ -n "$WWWROOT" && -n "$DBPASS" && -n "$ADMINPASS" ]] || { usage; exit 1; }
[[ -n "$DOMAIN" ]] || DOMAIN="$(derive_domain "$WWWROOT")"

# ---------------------- preflight ----------------------
[[ $EUID -eq 0 ]] || fail "Run as root"
need git; need php; need mysql; need curl; need sed; need awk; need systemctl; need apache2ctl

# Show summary
cat <<SUM
--- Parameters ---
WWWROOT       : $WWWROOT
DOMAIN        : $DOMAIN
MOODLEDIR     : $MOODLEDIR
DATAROOT      : $DATAROOT
DBNAME/USER   : $DBNAME / $DBUSER
ADMIN         : $ADMINUSER / $ADMINEMAIL
DRY_RUN       : $DRY_RUN
DROPDB        : $DROPDB
SKIP_APACHE   : $SKIP_APACHE
SKIP_GIT      : $SKIP_GIT
Log file      : $LOG_FILE
---------------
SUM

# ---------------------- Apache vhost check/update ----------------------
if ! $SKIP_APACHE; then
  echo "[Apache] Ensuring DocumentRoot points to $MOODLEDIR/public"
  # Try to locate an enabled vhost for DOMAIN
  VHOST_SSL="/etc/apache2/sites-enabled/${DOMAIN}-le-ssl.conf"
  VHOST_PLAIN="/etc/apache2/sites-enabled/${DOMAIN}.conf"

  if [[ -f "$VHOST_SSL" ]]; then TARGET_VHOST="$VHOST_SSL"; elif [[ -f "$VHOST_PLAIN" ]]; then TARGET_VHOST="$VHOST_PLAIN"; else TARGET_VHOST=""; fi

  if [[ -z "$TARGET_VHOST" ]]; then
    echo "[Apache] No dedicated vhost found for $DOMAIN in sites-enabled; will not modify vhost."
  else
    echo "[Apache] Editing vhost: $TARGET_VHOST"
    run "cp -a '$TARGET_VHOST' '${TARGET_VHOST}.bak.$(date +%s)'"
    # Set DocumentRoot and Directory block to point to public/
    run "sed -ri 's#^\s*DocumentRoot\s+.*#\tDocumentRoot ${MOODLEDIR}/public#' '$TARGET_VHOST'"
    # Ensure Directory stanza exists (simple append if not present)
    if ! grep -q "<Directory ${MOODLEDIR}/public>" "$TARGET_VHOST"; then
      cat <<EOD | tee -a "$TARGET_VHOST" >/dev/null
<Directory ${MOODLEDIR}/public>
    Require all granted
    AllowOverride All
</Directory>
EOD
    fi
    run "a2enmod rewrite >/dev/null 2>&1 || true"
    apache2ctl configtest || fail "apache2 configtest failed"
    run "systemctl reload apache2"
    # Verify via curl against loopback with Host header
    echo "[Apache] Verifying vhost serves something for ${DOMAIN}"
    run "curl -kI -H 'Host: ${DOMAIN}' https://127.0.0.1 || true"
  fi
fi

# ---------------------- Fetch Moodle 5.1 code ----------------------
if ! $SKIP_GIT; then
  echo "[Code] Cloning Moodle 5.1 stable into $MOODLEDIR"
  run "mkdir -p '$(dirname "$MOODLEDIR")'"
  if [[ -d "$MOODLEDIR/.git" ]]; then
    echo "[Code] Existing git repo found in $MOODLEDIR; pulling latest MOODLE_501_STABLE"
    run "cd '$MOODLEDIR' && git fetch --all && git checkout MOODLE_501_STABLE && git pull --ff-only"
  else
    run "rm -rf '$MOODLEDIR'"
    run "git clone -b MOODLE_501_STABLE --depth 1 git://git.moodle.org/moodle.git '$MOODLEDIR'"
  fi
fi

# Permissions for web write (config.php creation)
run "chown -R www-data:www-data '$MOODLEDIR'"

# ---------------------- Create moodledata ----------------------
run "mkdir -p '$DATAROOT'"
run "chown -R www-data:www-data '$DATAROOT'"
run "chmod 770 '$DATAROOT'"

# ---------------------- Database prep ----------------------
MYSQL_ROOT_CMD(){ mysql -u root "$@"; }
# If root password is set, user may need to adapt; here we use interactive prompt

if $DROPDB; then
  echo "[DB] Dropping & creating database $DBNAME"
  run "mysql -u root -p -e \"DROP DATABASE IF EXISTS \\`$DBNAME\\`; CREATE DATABASE \\`$DBNAME\\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
else
  echo "[DB] Ensuring database $DBNAME exists"
  run "mysql -u root -p -e \"CREATE DATABASE IF NOT EXISTS \\`$DBNAME\\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
fi

echo "[DB] Ensuring user/grants for $DBUSER"
run "mysql -u root -p -e \"CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '${DBPASS}'; GRANT ALL PRIVILEGES ON \\`${DBNAME}\\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;\""

# ---------------------- Pre-check for wwwroot/public alignment ----------------------
# Moodle 5.1 requires public/ as webroot. We do a sanity check by hitting loopback with Host header.
if ! $SKIP_APACHE; then
  echo "[Check] wwwroot/public alignment test"
  HTTP_STATUS=$(curl -kI -H "Host: ${DOMAIN}" -s https://127.0.0.1 | awk 'NR==1{print $2}') || true
  echo "[Check] curl status (loopback): ${HTTP_STATUS:-N/A}"
fi

# ---------------------- CLI Install ----------------------
if [[ -f "$MOODLEDIR/config.php" ]]; then
  echo "[Install] config.php already exists – skipping CLI install."
else
  echo "[Install] Running Moodle CLI installer"
  INSTALL_CMD=(
    sudo -u www-data php "$MOODLEDIR/admin/cli/install.php"
    --lang=en
    --wwwroot="$WWWROOT"
    --dataroot="$DATAROOT"
    --dbtype=mysqli
    --dbname="$DBNAME"
    --dbuser="$DBUSER"
    --dbpass="$DBPASS"
    --fullname="$SITEFULLNAME"
    --shortname="$SITESHORTNAME"
    --adminuser="$ADMINUSER"
    --adminpass="$ADMINPASS"
    --adminemail="$ADMINEMAIL"
    --non-interactive
  )
  echo "[Install] ${INSTALL_CMD[*]}"
  $DRY_RUN || "${INSTALL_CMD[@]}" || fail "CLI install failed"
fi

# ---------------------- Post-install checks ----------------------
if [[ -f "$MOODLEDIR/config.php" ]]; then
  echo "[Post] config.php created"
else
  fail "config.php not found after install"
fi

# purge caches & run cron & basic checks
run "sudo -u www-data php '$MOODLEDIR/admin/cli/purge_caches.php' || true"
run "sudo -u www-data php '$MOODLEDIR/admin/cli/cron.php' || true"
# Optional: checks.php exists in recent versions for environment checks
if [[ -f "$MOODLEDIR/admin/cli/checks.php" ]]; then
  run "sudo -u www-data php '$MOODLEDIR/admin/cli/checks.php' || true"
fi

# Summary
cat <<DONE
-----------------------------------------------------------------
Moodle 5.1 setup finished.
- WWWROOT   : $WWWROOT
- MOODLEDIR : $MOODLEDIR
- DATAROOT  : $DATAROOT
- DB        : $DBNAME (user=$DBUSER)
- config.php: $( [[ -f "$MOODLEDIR/config.php" ]] && echo present || echo missing )

Next steps:
1) Open $WWWROOT in your browser and log in as $ADMINUSER.
2) Site administration → Server → Environment → select 5.1 and verify green.
3) Review scheduled tasks and set up system cron if not present.

Log: $LOG_FILE
-----------------------------------------------------------------
DONE
