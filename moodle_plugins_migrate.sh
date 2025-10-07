#!/usr/bin/env bash
# moodle_plugins_migrate.sh
# Check & migrate ONLY non-core (missing) plugins from an old Moodle codebase
# to a fresh new Moodle codebase. Designed for major upgrades (e.g., 4.1 -> 4.5).
#
# Usage examples:
#   sudo bash moodle_plugins_migrate.sh \
#       --oldroot /var/www/html/moodle_old \
#       --newroot /var/www/html/moodle \
#       --web-user www-data \
#       --dry-run
#
#   sudo bash moodle_plugins_migrate.sh \
#       --oldroot /var/www/html/moodle_old \
#       --newroot /var/www/html/moodle \
#       --web-user www-data
#
# What it does
# - Scans common plugin locations in OLD_ROOT
# - For each plugin directory found, copies it to NEW_ROOT ONLY IF it does not already exist there
#   (so core plugins in the new package are not overwritten)
# - Verifies plugin directory contains a version.php (heuristic)
# - Prints a summary and optionally fixes ownership/permissions
#
# Notes
# - Run after you have deployed a CLEAN new Moodle codebase and copied config.php
# - See Moodle Upgrading docs: install clean code, then add compatible plugin code before running the CLI upgrade
#
# Exit on error; fail on unset variables
set -euo pipefail

# -------------- defaults --------------
OLD_ROOT=""
NEW_ROOT=""
WEB_USER="www-data"
DRY_RUN=false
FIX_PERMS=true

# Pairs of plugin roots to scan: "relative/old/path|relative/new/path"
PLUGIN_ROOTS=(
  "mod|mod"
  "blocks|blocks"
  "theme|theme"
  "local|local"
  "auth|auth"
  "enrol|enrol"
  "filter|filter"
  "report|report"
  "question|question"
  "repository|repository"
  "portfolio|portfolio"
  "plagiarism|plagiarism"
  "availability/condition|availability/condition"
  "course/format|course/format"
  "admin/tool|admin/tool"
  "lib/editor/atto/plugins|lib/editor/atto/plugins"
  "lib/editor/tiny/plugins|lib/editor/tiny/plugins"
)

usage() {
  cat <<EOF
Usage: sudo bash $0 --oldroot <OLD_MOODLE_DIR> --newroot <NEW_MOODLE_DIR> [options]
Options:
  --web-user <user>   Web server user for ownership fix (default: www-data)
  --dry-run           Show what would be copied, do not modify filesystem
  --no-fix-perms      Do not change ownership/permissions after copying
  -h|--help           This help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oldroot) OLD_ROOT="$2"; shift 2;;
    --newroot) NEW_ROOT="$2"; shift 2;;
    --web-user) WEB_USER="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-fix-perms) FIX_PERMS=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

[[ -n "$OLD_ROOT" && -d "$OLD_ROOT" ]] || { echo "[ERROR] --oldroot not found: $OLD_ROOT"; exit 1; }
[[ -n "$NEW_ROOT" && -d "$NEW_ROOT" ]] || { echo "[ERROR] --newroot not found: $NEW_ROOT"; exit 1; }

report_copied=()
report_skipped=()
report_missing=()

copy_plugin() {
  local src="$1" dst="$2"
  if $DRY_RUN; then
    echo "[DRY-RUN] Would copy: $src -> $dst"
  else
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    echo "[COPIED] $src -> $dst"
  fi
}

is_plugin_dir() {
  local dir="$1"
  # Heuristic: contains version.php somewhere at the root of the plugin directory
  [[ -f "$dir/version.php" ]] && return 0
  # Some plugin types (e.g., editors) may place version.php deeper but this is rare; keep strict.
  return 1
}

scan_root() {
  local rel_old="$1" rel_new="$2"
  local src_root="$OLD_ROOT/$rel_old"
  local dst_root="$NEW_ROOT/$rel_new"

  if [[ ! -d "$src_root" ]]; then
    echo "[INFO] Skipping missing root: $rel_old"
    return
  fi

  # Iterate immediate subdirectories (each expected to be a plugin)
  shopt -s nullglob
  local entries=("$src_root"/*)
  shopt -u nullglob
  if (( ${#entries[@]} == 0 )); then
    echo "[INFO] No entries under: $rel_old"
    return
  fi

  for p in "${entries[@]}"; do
    [[ -d "$p" ]] || continue
    local name
    name=$(basename "$p")

    # Special case: for nested roots like availability/condition or course/format, p is plugin folder already
    local src_dir="$p"
    local dst_dir="$dst_root/$name"

    if [[ -e "$dst_dir" ]]; then
      echo "[SKIP] Exists in new code: $rel_new/$name"
      report_skipped+=("$rel_new/$name (exists)")
      continue
    fi

    if is_plugin_dir "$src_dir"; then
      copy_plugin "$src_dir" "$dst_dir"
      report_copied+=("$rel_new/$name")
    else
      echo "[WARN] Not a plugin (no version.php): $rel_old/$name — skipped"
      report_missing+=("$rel_old/$name (no version.php)")
    fi
  done
}

echo "=== Moodle Plugin Migration ==="
echo "OLD_ROOT: $OLD_ROOT"
echo "NEW_ROOT: $NEW_ROOT"
echo "WEB_USER: $WEB_USER"
echo "DRY_RUN : $DRY_RUN"
echo

for pair in "${PLUGIN_ROOTS[@]}"; do
  IFS='|' read -r rel_old rel_new <<<"$pair"
  echo "-- Scanning $rel_old -> $rel_new --"
  scan_root "$rel_old" "$rel_new"
  echo
done

if $FIX_PERMS && ! $DRY_RUN; then
  echo "[INFO] Fixing ownership and permissions"
  chown -R "$WEB_USER":"$WEB_USER" "$NEW_ROOT"
  find "$NEW_ROOT" -type f -exec chmod 0640 {} +
  find "$NEW_ROOT" -type d -exec chmod 0750 {} +
fi

# Summary
echo "=== Summary ==="
if ((${#report_copied[@]})); then
  echo "Copied plugins:"; for i in "${report_copied[@]}"; do echo "  - $i"; done
else
  echo "Copied plugins: (none)"
fi
if ((${#report_skipped[@]})); then
  echo "Skipped (already present):"; for i in "${report_skipped[@]}"; do echo "  - $i"; done
fi
if ((${#report_missing[@]})); then
  echo "Skipped (no version.php):"; for i in "${report_missing[@]}"; do echo "  - $i"; done
fi

echo "Done. Review the list above, then run the Moodle CLI upgrade:"
echo "  sudo -u $WEB_USER php /var/www/html/moodle/admin/cli/upgrade.php"
