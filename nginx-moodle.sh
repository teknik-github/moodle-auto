#!/bin/bash

# Pastikan script dijalankan sebagai root
if [[ $EUID -ne 0 ]]; then
   echo "Harap jalankan script ini sebagai root"
   exit 1
fi

# Ambil IP address IPv4 utama
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "===> Update & Install nginx"
apt update && apt install -y nginx

echo "===> Menambahkan repo PHP 8.2"
add-apt-repository ppa:ondrej/php -y
apt update

echo "===> Install PHP 8.2 FPM dan ekstensi yang diperlukan Moodle"
apt install -y php8.2 php8.2-fpm php8.2-{cli,common,gd,mbstring,mysql,xml,xmlrpc,soap,intl,zip,curl,opcache,redis}

echo "===> Menambahkan repository MariaDB"
curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | sudo gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://archive.mariadb.org/mariadb-10.11/repo/ubuntu $(lsb_release -cs) main" \
 |sudo tee /etc/apt/sources.list.d/mariadb.list

echo "===> Install Composer"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('sha384', 'composer-setup.php') === 'c8b085408188070d5f52bcfe4ecfbee5f727afa458b2573b8eaaf77b3419b0bf2768dc67c86944da1544f06fa544fd47') { echo 'Installer verified'.PHP_EOL; } else { echo 'Installer corrupt'.PHP_EOL; unlink('composer-setup.php'); exit(1); }"
php composer-setup.php
php -r "unlink('composer-setup.php');"
sudo mv composer.phar /usr/local/bin/composer

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
wget https://github.com/moodle/moodle/archive/refs/tags/v5.1.0.zip


echo "===> Ekstrak file Moodle"
unzip v5.1.0.zip

echo "===> Pindahkan Moodle ke /var/www/html"
mv moodle-5.1.0 /var/www/html/moodle

echo "===> Install dependensi Moodle dengan Composer"
cd /var/www/html/moodle/public
composer install --no-dev --classmap-authoritative

echo "===> Membuat folder moodledata"
mkdir /var/www/html/moodledata
chmod 777 /var/www/html/moodledata

echo "===> Set ownership ke www-data"
chown -R www-data:www-data /var/www/html/moodle /var/www/html/moodledata

echo "===> Membuat konfigurasi nginx untuk Moodle"
NGINX_SITE="/etc/nginx/sites-available/default"
cat <<'EOF' > "$NGINX_SITE"
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root /var/www/html/moodle/public/;
    index index.php index.html index.htm;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?q=$uri&$args;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
        try_files $uri =404;
        expires max;
        log_not_found off;
    }
}
EOF

echo "===> Test nginx config and restart nginx + php-fpm"
nginx -t
systemctl reload nginx
systemctl restart php8.2-fpm

echo "===> Menambahkan max_input_vars = 5000 ke php.ini FPM"
PHP_INI="/etc/php/8.2/fpm/php.ini"
if grep -q "^max_input_vars" "$PHP_INI"; then
    sed -i 's/^max_input_vars.*/max_input_vars = 5000/' "$PHP_INI"
else
    echo "max_input_vars = 5000" >> "$PHP_INI"
fi

echo "===> Restart php-fpm & nginx untuk menerapkan perubahan PHP"
systemctl restart php8.2-fpm
systemctl reload nginx

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

\$CFG->pathtophp = '/usr/bin/php';

// There is no php closing tag in this file,
EOF

chown www-data:www-data /var/www/html/moodle/config.php
chmod 640 /var/www/html/moodle/config.php

read -p "===> Apakah anda inggin install SSL? (yes/no): " SSL

if [ "$SSL" == "yes" ]; then
    apt update
    apt install -y certbot python3-certbot-nginx

    read -p "Domain (contoh: example.com): " SSL_Domain
    nginx -t && systemctl reload nginx

    echo "===> Menjalankan certbot untuk domain ${SSL_Domain}"
    certbot --nginx -d "${SSL_Domain}" --non-interactive --agree-tos -m admin@${SSL_Domain} || {
        echo "Certbot gagal, periksa log. Konfigurasi nginx tetap terpasang."
    }

    echo "===> SSL selesai (atau perlu cek manual jika gagal)."

    cat <<EOF > /var/www/html/moodle/config.php
<?php  // Moodle configuration file

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();
=
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

\$CFG->wwwroot   = 'https://${SSL_Domain}';
\$CFG->dataroot  = '/var/www/html/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');

\$CFG->sslproxy = true; 
\$CFG->pathtophp = '/usr/bin/php';

// There is no php closing tag in this file,
EOF

else
    echo "===> Selesai! Moodle siap digunakan tanpa setup awal melalui browser."
    echo "========================================"
    echo "Database Name : ${DB_NAME}"
    echo "Database User : ${DB_USER}"
    echo "Database Pass : ${DB_PASS}"
    echo "Moodle URL    : http://${SERVER_IP}"
    echo "========================================"
    echo "⚠️  Jika server memiliki domain atau IP publik berbeda, harap edit file berikut:"
    echo "   /var/www/html/moodle/config.php atau /var/www/html/moodle/public/config.php"
    echo "   dan ubah nilai \$CFG->wwwroot = 'http://${SERVER_IP}'; sesuai alamat yang benar."
fi
