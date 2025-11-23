#!/bin/bash
cat <<'EOF'
 _____       _   _           _          _   _              ___  ___                _ _      
|  _  |     | | (_)         (_)        | | (_)             |  \/  |               | | |     
| | | |_ __ | |_ _ _ __ ___  _ ______ _| |_ _  ___  _ __   | .  . | ___   ___   __| | | ___ 
| | | | '_ \| __| | '_ ` _ \| |_  / _` | __| |/ _ \| '_ \  | |\/| |/ _ \ / _ \ / _` | |/ _ \
\ \_/ / |_) | |_| | | | | | | |/ / (_| | |_| | (_) | | | | | |  | | (_) | (_) | (_| | |  __/
 \___/| .__/ \__|_|_| |_| |_|_/___\__,_|\__|_|\___/|_| |_| \_|  |_/\___/ \___/ \__,_|_|\___|
      | |                                                                                   
      |_|                                                                                   
EOF

# Pastikan script dijalankan sebagai root
if [[ $EUID -ne 0 ]]; then
   echo "Harap jalankan script ini sebagai root"
   exit 1
fi

echo "===> Install Redis Server"
apt update -y
apt install -y redis-server

echo "===> Enable Redis to start on boot"
systemctl enable --now redis-server

echo "===> Configure Redis for Moodle"
REDIS_CONF="/etc/redis/redis.conf"
# ubah supervised menjadi systemd jika ada
if grep -q '^supervised' "$REDIS_CONF"; then
    sed -i 's/^supervised .*/supervised systemd/' "$REDIS_CONF"
else
    echo "supervised systemd" >> "$REDIS_CONF"
fi
# set memory & policy idempotent (ubah jika baris dikomentari atau berbeda)
sed -i 's/^#\? *maxmemory .*/maxmemory 256mb/' "$REDIS_CONF"
sed -i 's/^#\? *maxmemory-policy .*/maxmemory-policy allkeys-lru/' "$REDIS_CONF"

systemctl restart redis-server

# Jika PHP sudah terpasang di sistem, pastikan PHP Redis extension terinstall dan aktif
echo "===> Pastikan PHP Redis extension terpasang (php-redis / php8.2-redis) jika PHP sudah ada"
apt update -y
if command -v php >/dev/null 2>&1; then
    # Coba pasang paket versi khusus dan generik; apt akan mengabaikan jika sudah terpasang
    apt install -y php8.2-redis php-redis || true

    # Restart php-fpm service jika ada
    PHP_FPM_SERVICE=$(systemctl list-units --type=service --no-legend | awk '/php.*fpm/ {print $1; exit}')
    if [ -n "$PHP_FPM_SERVICE" ]; then
        echo "===> Restarting $PHP_FPM_SERVICE to load php-redis"
        systemctl restart "$PHP_FPM_SERVICE" || true
    else
        echo "===> php-fpm service tidak ditemukan; jika Anda menjalankan PHP-FPM, restart manual layanan tersebut."
    fi
else
    echo "===> PHP tidak terdeteksi; lewati pemasangan php-redis. Jika PHP nantinya dipasang, instal 'php-redis' dan restart php-fpm."
fi

# Fungsi: sisipkan blok Redis ke config.php secara idempotent
add_redis_block() {
    # Daftar lokasi config.php Moodle yang mungkin
    CFG_CANDIDATES=(
        "/var/www/html/moodle/config.php"
        "/var/www/html/moodle/public/config.php"
    )

    REDIS_BLOCK='$CFG->session_handler_class = '\''\core\session\redis'\'';
$CFG->session_redis_host = '\''127.0.0.1'\'';
$CFG->session_redis_port = 6379;
$CFG->session_redis_database = 0;
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->cachestore_redis_server = '\''127.0.0.1'\'';
$CFG->cachestore_redis_port = 6379;
$CFG->cachestore_redis_database = 1;
$CFG->cachestore_redis_prefix = '\''moodle_'\'';
$CFG->cachestore_redis_acquire_lock_timeout = 120;
'

    added_any=false

    for CFG_FILE in "${CFG_CANDIDATES[@]}"; do
        if [ ! -f "$CFG_FILE" ]; then
            continue
        fi

        # Jika sudah ada konfigurasi Redis, lewati
        if grep -q "session_handler_class" "$CFG_FILE"; then
            echo "Redis settings already present in $CFG_FILE — skipping"
            added_any=true
            continue
        fi

        # Cari baris require_once untuk menyisipkan sebelum baris itu
        lineno=$(grep -n "require_once(__DIR__ . '/lib/setup.php');" "$CFG_FILE" | cut -d: -f1 || true)

        if [ -n "$lineno" ]; then
            head -n $((lineno-1)) "$CFG_FILE" > "$CFG_FILE.tmp"
            printf "%s\n" "$REDIS_BLOCK" >> "$CFG_FILE.tmp"
            tail -n +"$lineno" "$CFG_FILE" >> "$CFG_FILE.tmp"
            mv "$CFG_FILE.tmp" "$CFG_FILE"
            echo "Inserted Redis block into $CFG_FILE before require_once(...)"
        else
            # Jika require_once tidak ditemukan, append di akhir
            printf "\n%s\n" "$REDIS_BLOCK" >> "$CFG_FILE"
            echo "Appended Redis block to end of $CFG_FILE"
        fi

        chown www-data:www-data "$CFG_FILE"
        chmod 640 "$CFG_FILE"
        added_any=true
    done

    if [ "$added_any" = false ]; then
        echo "Tidak menemukan file config Moodle di lokasi yang diharapkan. Pastikan Moodle sudah terpasang."
        echo "Lokasi yang diperiksa: ${CFG_CANDIDATES[*]}"
    fi
}

# Jalankan fungsi inject Redis (idempotent)
add_redis_block

echo "===> Selesai: Redis terinstal dan konfigurasi Redis telah ditambahkan ke config Moodle jika ditemukkan."