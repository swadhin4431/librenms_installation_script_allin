#!/bin/bash
# Script is Used For Ubuntu=16.04
# Script to install LibreNMS with default configurations, providing to the user an initial contact with the tool.

export DEBIAN_FRONTEND=noninteractive

random_password() {
    MATRIX='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    LENGTH=10
    while [ ${n:=1} -le $LENGTH ]; do
        PASS="$PASS${MATRIX:$(($RANDOM%${#MATRIX})):1}"
        let n+=1
    done
    echo "$PASS"
}

function check_root {
    if [ "x$(id -u)" != 'x0' ]; then
        echo 'Error: this script can only be executed by root'
        exit 1
    fi
}

function check_os {
    if [ -e '/etc/redhat-release' ]; then
        echo 'Error: sorry, this installer works only on Debian or Ubuntu'
        exit 1
    fi  
}

function check_installed {   
    tmpfile=$(mktemp -p /tmp)
    dpkg --get-selections > $tmpfile
    for pkg in mariadb-server apache2 php7.2; do
        if [ ! -z "$(grep $pkg $tmpfile)" ]; then
            conflicts="$pkg $conflicts"
        fi
    done
    rm -f $tmpfile
    if [ ! -z "$conflicts" ] && [ -z "$force" ]; then
        echo 'Error: This script runs only on a clean installation'
        echo 'Following packages are already installed:'
        echo "$conflicts"
        exit 1
    fi
}

function install_dependences {
    apt-get update
    apt-get upgrade -y
    cat <(echo "") | add-apt-repository ppa:ondrej/php
    cat <(echo "") | add-apt-repository ppa:ondrej/apache2
    sudo apt-get update
    apt-get install -y curl apache2 composer fping git graphviz imagemagick libapache2-mod-php7.2 mtr-tiny nmap php7.2-cli php7.2-curl php7.2-gd php7.2-json php7.2-mbstring php7.2-mysql php7.2-snmp php7.2-xml php7.2-zip python-memcache python-mysqldb rrdtool snmp snmpd whois
}

function install_mysql {
sudo apt-get update
mysqlrootpassword=$(random_password)
mysqllibrepassword=$(random_password)
echo -ne '\n' | apt-get install -y mariadb-server
sudo systemctl start mysql
sudo mysql_secure_installation <<EOF

y
$mysqlrootpassword
$mysqlrootpassword
y
y
y
y
EOF
    echo "CREATE DATABASE librenms CHARACTER SET utf8 COLLATE utf8_unicode_ci;
            GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost' IDENTIFIED BY '$mysqllibrepassword';
            FLUSH PRIVILEGES;
            SET GLOBAL time_zone = '+05:30';" | sudo mysql -u root
    
    sed -i '\:skip-external-locking:ainnodb_file_per_table=1\nsql-mode=""' /etc/mysql/mariadb.conf.d/50-server.cnf 
    sudo tee -a /etc/mysql/mariadb.cnf <<< 'init_command="SET time_zone='"'+5:30'"'"'

    sudo rm /etc/mysql/my.cnf
    sudo systemctl restart mysql.service

}

function install_librenms {
    useradd librenms -d /opt/librenms -M -r
    usermod -a -G librenms www-data
    cd /opt
    git clone https://github.com/librenms/librenms.git librenms
    cd /opt/librenms
    mkdir rrd logs
    chown www-data. logs
    chmod 775 rrd
    chown librenms. rrd

    install_mysql

    sudo sed -i 's/;date.timezone =\+/date.timezone = Asia\/Kolkata/' /etc/php/7.2/apache2/php.ini
    sudo sed -i 's/;date.timezone =\+/date.timezone = Asia\/Kolkata/' /etc/php/7.2/cli/php.ini

    a2enmod php7.2
    a2dismod mpm_event
    a2enmod mpm_prefork

    if [[ $(apache2 -v | head -n 1) =~ 'Apache/2.4' ]]; then
        echo '<VirtualHost *:80>
  DocumentRoot /opt/librenms/html/
  ServerName  localhost.localdomain
  AllowEncodedSlashes NoDecode
  <Directory "/opt/librenms/html/">
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
  </Directory>
</VirtualHost>' > /etc/apache2/sites-available/librenms.conf
        a2dissite 000-default            
    else        
        echo '<VirtualHost *:80>
    DocumentRoot /opt/librenms/html/
    ServerName localhost.localdomain
    AllowEncodedSlashes On
    <Directory "/opt/librenms/html/">
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>
</VirtualHost>' > /etc/apache2/sites-available/librenms
        a2dissite default            
    fi

    a2ensite librenms.conf
    a2enmod rewrite
    systemctl restart apache2
    
    cp /opt/librenms/config.php.default /opt/librenms/config.php
    sed -i 's/USERNAME/librenms/g' /opt/librenms/config.php
    sed -i "s/PASSWORD/$mysqllibrepassword/g" /opt/librenms/config.php
    cp /opt/librenms/librenms.nonroot.cron /etc/cron.d/librenms

    cd /opt/librenms
    ./scripts/composer_wrapper.php install --no-dev
    echo "yes" | sudo ./lnms migrate --force
    sudo timedatectl set-timezone Asia/Kolkata
    echo "ALTER TABLE notifications CHANGE datetime datetime timestamp NOT NULL DEFAULT '1970-01-02 00:00:00' ;
ALTER TABLE users CHANGE created_at created_at timestamp NOT NULL DEFAULT '1970-01-02 00:00:01' ;" | sudo mysql -u librenms -p$mysqllibrepassword librenms
    
    librepassword=$(random_password)
    /usr/bin/php7.2 build-base.php
    /usr/bin/php7.2 addhost.php localhost public v2c
    /usr/bin/php7.2 adduser.php admin $librepassword 10
    /usr/bin/php7.2 discovery.php -h all
    /usr/bin/php7.2 poller.php -h all

    chown -R librenms:librenms /opt/librenms
    setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
    setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
}

function its_done {
    host=$(curl -s http://whatismyip.akamai.com)
    echo
    echo ' ### Done! ###'
    echo
    echo 'LibreNMS was successfully installed, be happy :)'
    echo
    echo "Url: http://$host"
    echo "Username: admin"
    echo "Password: $librepassword"
    echo "Mysql root password: $mysqlrootpassword"
    echo "Mysql libre password: $mysqllibrepassword"
}

function install {
    check_root
    check_os
#    check_installed
    install_dependences
    install_librenms
    its_done
}

echo
echo
echo ' ### LibreNMS Faststart ###'
echo
echo 'This script will install librenms in your environment for inicial use and small tests'
echo
echo 'Note: To install this script only works to run on clean OS'
read -p 'Do you want to proceed? [y/n]: ' answer
if [ "$answer" != 'y' ] && [ "$answer" != 'Y'  ]; then
    echo 'Goodbye'
    exit 1
fi

install
