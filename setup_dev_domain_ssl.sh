#!/bin/bash

# === Μεταβλητές ===
domain="dev.moodle.myenglishhub.gr"
email="admin@myenglishhub.gr"
web_root="/var/www/html/moodle"
apache_conf="/etc/apache2/sites-available/${domain}.conf"

# === Εγκατάσταση Apache και Certbot ===
sudo apt update
sudo apt install -y apache2 certbot python3-certbot-apache

# === Δημιουργία Virtual Host για το subdomain ===
sudo bash -c "cat > ${apache_conf}" <<EOF
<VirtualHost *:80>
    ServerAdmin ${email}
    ServerName ${domain}
    DocumentRoot ${web_root}

    <Directory ${web_root}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
</VirtualHost>
EOF

# === Ενεργοποίηση site και επανεκκίνηση Apache ===
sudo a2ensite ${domain}
sudo systemctl reload apache2

# === Εγκατάσταση SSL με Let's Encrypt ===
sudo certbot --apache -d ${domain} --non-interactive --agree-tos -m ${email} --redirect

# === Τέλος ===
echo "✅ Το subdomain ${domain} έχει ρυθμιστεί με SSL!"
