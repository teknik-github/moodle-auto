# moodle-auto

Automatis install Moodle LMS

Clone script:
```bash
git clone https://github.com/teknik-github/moodle-auto.git
```

Masuk dan buat install.sh izin esekusi
```bash
cd moodle-auto
chmod +x install.sh
```

Install moodle
```bash
sudo ./install.sh
```

Tunggu sampai instalasi selesai 10-20 menit tergantung dengan kecepatan storage kalian

Jika terdapat pesan ini harus di perhatikan
```bash
===> Selesai! Moodle siap digunakan tanpa setup awal melalui browser.
========================================
Database Name : moodle
Database User : moodleuser
Database Pass : cM7WjK3Ajm
Moodle URL    : http://172.168.1.xxx
========================================
⚠️  Jika server memiliki domain atau IP publik berbeda, harap edit file berikut:
   /var/www/html/moodle/config.php
   dan ubah nilai $CFG->wwwroot = 'http://172.168.1.xxx'; sesuai alamat yang benar.
```