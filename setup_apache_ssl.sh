#!/bin/bash

# Ορισμός μεταβλητών για τα paths των αρχείων
CERT_DIR="/etc/ssl/moodle"
CERT_FILE="certificate.pem"
KEY_FILE="privatekey.pem"
CHAIN_FILE="chain.pem"
APACHE_CONF="/etc/apache2/sites-available/moodle-ssl.conf"

# Δημιουργία φακέλου για τα certificates
sudo mkdir -p $CERT_DIR

# Αντιγραφή των αρχείων certificate στον φάκελο (υποθέτουμε ότι βρίσκονται στον τρέχοντα φάκελο)
sudo cp $CERT_FILE $CERT_DIR/
sudo cp $KEY_FILE $CERT_DIR/
sudo cp $CHAIN_FILE $CERT_DIR/

# Ρύθμιση δικαιωμάτων
sudo chmod 600 $CERT_DIR/$KEY_FILE
sudo chown root:root $CERT_DIR/$KEY_FILE

# Δημιουργία Apache Virtual Host για HTTPS
sudo bash -c "cat > $APACHE_CONF" <<EOL
<VirtualHost *:443>
    ServerName moodle.example.com

    DocumentRoot /var/www/moodle

    SSLEngine on
    SSLCertificateFile $CERT_DIR/$CERT_FILE
    SSLCertificateKeyFile $CERT_DIR/$KEY_FILE
    SSLCertificateChainFile $CERT_DIR/$CHAIN_FILE

    <Directory /var/www/moodle>
        AllowOverride All
    </Directory>
</VirtualHost>
EOL

# Ενεργοποίηση SSL module και του νέου site
sudo a2enmod ssl
sudo a2ensite moodle-ssl.conf

# Επανεκκίνηση Apache
sudo systemctl restart apache2

echo "✅ Η εγκατάσταση του SSL certificate ολοκληρώθηκε επιτυχώς για το Apache."
