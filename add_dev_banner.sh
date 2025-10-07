#!/bin/bash

# Ορισμός μεταβλητών
MOODLE_PATH="/var/www/html/moodle"
THEME_PATH="$MOODLE_PATH/theme/boost"
LAYOUT_FILE="$THEME_PATH/templates/columns2.mustache"
BACKUP_FILE="$LAYOUT_FILE.bak"

# Έλεγχος αν υπάρχει το αρχείο layout
if [ ! -f "$LAYOUT_FILE" ]; then
    echo "Το αρχείο layout δεν βρέθηκε: $LAYOUT_FILE"
    exit 1
fi

# Δημιουργία backup
cp "$LAYOUT_FILE" "$BACKUP_FILE"
echo "Δημιουργήθηκε αντίγραφο ασφαλείας: $BACKUP_FILE"

# Προσθήκη banner στο header
# Τοποθετούμε το banner ακριβώς μετά το <body> ή μέσα στο <div id="page-header">
sed -i '/<div id="page-header">/a <div style="background-color:red;color:white;text-align:center;padding:10px;font-weight:bold;">DEV ENVIRONMENT</div>' "$LAYOUT_FILE"

echo "Προστέθηκε banner DEV ENVIRONMENT στο αρχείο layout του Boost theme."

# Καθαρισμός cache του Moodle
sudo -u www-data /usr/bin/php "$MOODLE_PATH/admin/cli/purge_caches.php"

echo "Καθαρίστηκε η cache του Moodle."
