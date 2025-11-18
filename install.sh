#!/bin/bash

# Pastikan script dijalankan sebagai root
if [[ $EUID -ne 0 ]]; then
   echo "Harap jalankan script ini sebagai root"
   exit 1
fi

# Ambil IP address IPv4 utama
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "===> Update & Install Apache2"
apt update && apt install -y apache2

echo "===> Menambahkan repo PHP 8.2"
add-apt-repository ppa:ondrej/php -y
apt update

echo "===> Install PHP 8.2 dan ekstensi yang diperlukan Moodle"
apt install -y php8.2 php8.2-{cli,fpm,common,gd,mbstring,mysql,xml,xmlrpc,soap,intl,zip,curl,opcache}

echo "===> Install Modul Mod PHP Apache"
sudo apt install libapache2-mod-php8.2

echo "===> Menambahkan repository MariaDB"
curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | sudo gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://archive.mariadb.org/mariadb-10.11/repo/ubuntu $(lsb_release -cs) main" \
 |sudo tee /etc/apt/sources.list.d/mariadb.list

echo "===> Install MariaDB"
apt update && apt install -y mariadb-server

echo "===> Check mariaDB versions"
mariadb --version

echo "===> Membuat database untuk Moodle"
DB_NAME=$(tr -dc 'A-Za-z' </dev/urandom | head -c 5)
DB_USER=$(tr -dc 'A-Za-z' </dev/urandom | head -c 10)
DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)

mysql -u root <<EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "===> Memastikan unzip sudah terpasang"
apt install -y unzip

echo "===> Download Moodle"
cd /tmp
wget https://packaging.moodle.org/stable500/moodle-latest-500.zip

echo "===> Ekstrak file Moodle"
unzip moodle-latest-500.zip

echo "===> Pindahkan Moodle ke /var/www/html"
mv moodle /var/www/html/moodle

echo "===> Membuat folder moodledata"
mkdir /var/www/html/moodledata
chmod 777 /var/www/html/moodledata

echo "===> Set ownership ke www-data"
chown -R www-data:www-data /var/www/html/moodle /var/www/html/moodledata

echo "===> Mengubah DocumentRoot Apache ke /var/www/html/moodle"
sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/moodle|' /etc/apache2/sites-available/000-default.conf

echo "===> Mengaktifkan mod_rewrite dan restart Apache"
a2enmod rewrite
systemctl restart apache2

echo "===> Menambahkan max_input_vars = 5000 ke php.ini"
PHP_INI="/etc/php/8.2/apache2/php.ini"
if grep -q "^max_input_vars" "$PHP_INI"; then
    sed -i 's/^max_input_vars.*/max_input_vars = 5000/' "$PHP_INI"
else
    echo "max_input_vars = 5000" >> "$PHP_INI"
fi

echo "===> Restart Apache untuk menerapkan perubahan PHP"
systemctl restart apache2

echo "===> Membuat config.php untuk Moodle"

cat <<EOF > /var/www/html/moodle/config.php
<?php  // Moodle configuration file

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${DB_NAME}';
\$CFG->dbuser    = '${DB_USER}';
\$CFG->dbpass    = '${DB_PASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => 3306,
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = 'http://${SERVER_IP}';
\$CFG->dataroot  = '/var/www/html/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
EOF

chown www-data:www-data /var/www/html/moodle/config.php
chmod 640 /var/www/html/moodle/config.php

echo "===> Selesai! Moodle siap digunakan tanpa setup awal melalui browser."
echo "========================================"
echo "Database Name : ${DB_NAME}"
echo "Database User : ${DB_USER}"
echo "Database Pass : ${DB_PASS}"
echo "Moodle URL    : http://${SERVER_IP}"
echo "========================================"
echo "⚠️  Jika server memiliki domain atau IP publik berbeda, harap edit file berikut:"
echo "   /var/www/html/moodle/config.php"
echo "   dan ubah nilai \$CFG->wwwroot = 'http://${SERVER_IP}'; sesuai alamat yang benar."