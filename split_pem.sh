#!/bin/bash

# Ορισμός αρχείου εισόδου και φακέλου εξόδου
INPUT_FILE="full.pem"
OUTPUT_DIR="/etc/ssl/moodle"

# Δημιουργία φακέλου εξόδου αν δεν υπάρχει
sudo mkdir -p "$OUTPUT_DIR"

# Εξαγωγή του ιδιωτικού κλειδιού
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$INPUT_FILE" | sudo tee "$OUTPUT_DIR/privatekey.pem" > /dev/null

# Ρύθμιση δικαιωμάτων για το ιδιωτικό κλειδί
sudo chmod 600 "$OUTPUT_DIR/privatekey.pem"
sudo chown root:root "$OUTPUT_DIR/privatekey.pem"

# Εξαγωγή όλων των CERTIFICATE blocks
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$INPUT_FILE" > /tmp/all_certs.pem

# Εντοπισμός γραμμής έναρξης του δεύτερου CERTIFICATE block (chain)
CHAIN_START=$(awk '/BEGIN CERTIFICATE/{i++}i==2{print NR; exit}' /tmp/all_certs.pem)

# Δημιουργία certificate.pem (πρώτο CERTIFICATE block)
head -n $((CHAIN_START - 1)) /tmp/all_certs.pem | sudo tee "$OUTPUT_DIR/certificate.pem" > /dev/null

# Δημιουργία chain.pem (υπόλοιπα CERTIFICATE blocks)
tail -n +$CHAIN_START /tmp/all_certs.pem | sudo tee "$OUTPUT_DIR/chain.pem" > /dev/null

# Καθαρισμός προσωρινών αρχείων
rm /tmp/all_certs.pem

echo "Τα αρχεία δημιουργήθηκαν στον φάκελο $OUTPUT_DIR:"
echo " - certificate.pem"
echo " - privatekey.pem"
echo " - chain.pem"
