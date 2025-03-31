#!/bin/bash

# WordPress Installation Script for Debian LXC Container
# --- Requires root privileges ---

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipe commands return exit status of the last command that failed.
set -o pipefail

# --- Configuration ---
# You can change these variables if needed
WP_PATH="/var/www/html"             # WordPress installation directory (Apache default)
DB_NAME="wordpress_db"              # Database name
DB_USER="wp_user"                   # Database user
# Generate secure random passwords
DB_PASS=$(openssl rand -base64 12)
ROOT_DB_PASS=$(openssl rand -base64 15) # Secure password for MariaDB root

# --- Helper Functions ---
print_info() {
    echo -e "\033[34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[32m[SUCCESS]\033[0m $1"
}

print_warning() {
    echo -e "\033[33m[WARNING]\033[0m $1"
}

print_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

# --- Check for Root Privileges ---
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root. Use sudo ./install_wordpress.sh"
   exit 1
fi

# --- Start Installation ---
print_info "Starting WordPress Installation on Debian LXC..."

# 1. Update System Packages
print_info "Updating system packages..."
apt update && apt upgrade -y
print_success "System packages updated."

# 2. Install Dependencies (Apache, MariaDB, PHP, and common extensions)
print_info "Installing Apache, MariaDB, PHP, and required extensions..."
apt install apache2 mariadb-server php libapache2-mod-php php-mysql php-curl php-gd php-xml php-mbstring php-zip php-imagick wget unzip -y
print_success "Dependencies installed."

# 3. Configure MariaDB
print_info "Configuring MariaDB..."
# Start and enable MariaDB service
systemctl start mariadb
systemctl enable mariadb

# Secure MariaDB installation non-interactively
print_info "Securing MariaDB and setting root password..."
mysql -u root <<EOF
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_DB_PASS}';
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';
-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- Flush privileges to apply changes
FLUSH PRIVILEGES;
EOF
print_success "MariaDB secured."

print_info "Creating WordPress database and user..."
# Use the newly set root password for subsequent commands
mysql -u root -p"${ROOT_DB_PASS}" <<EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
print_success "WordPress database and user created."

# 4. Download and Install WordPress
print_info "Downloading and extracting latest WordPress..."
cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xzvf latest.tar.gz

# Clean existing default files (if any) and copy WordPress files
print_info "Copying WordPress files to ${WP_PATH}..."
# Be careful if WP_PATH has important data - this script assumes it's a fresh setup
rm -rf ${WP_PATH}/*
mkdir -p ${WP_PATH} # Ensure directory exists just in case
cp -r /tmp/wordpress/* ${WP_PATH}/
print_success "WordPress files copied."

# 5. Configure WordPress (wp-config.php)
print_info "Configuring wp-config.php..."
# Copy the sample config file
cp ${WP_PATH}/wp-config-sample.php ${WP_PATH}/wp-config.php

# Set database credentials
sed -i "s/database_name_here/${DB_NAME}/" ${WP_PATH}/wp-config.php
sed -i "s/username_here/${DB_USER}/" ${WP_PATH}/wp-config.php
sed -i "s/password_here/${DB_PASS}/" ${WP_PATH}/wp-config.php
sed -i "s/localhost/localhost/" ${WP_PATH}/wp-config.php # Ensure DB Host is localhost

# Set WordPress Security Salts/Keys
print_info "Generating and setting WordPress security keys/salts..."
SALT=$(wget -qO- https://api.wordpress.org/secret-key/1.1/salt/)
# Use awk to replace the entire block of salts
awk -v salts="$SALT" '
/AUTH_KEY/        { setting_salts = 1 }
/NONCE_SALT/      { setting_salts = 0; print salts; next }
!setting_salts    { print }
' ${WP_PATH}/wp-config.php > ${WP_PATH}/wp-config.tmp && mv ${WP_PATH}/wp-config.tmp ${WP_PATH}/wp-config.php

print_success "wp-config.php configured."

# 6. Set File Permissions
print_info "Setting file permissions for WordPress..."
chown -R www-data:www-data ${WP_PATH}
find ${WP_PATH} -type d -exec chmod 755 {} \;
find ${WP_PATH} -type f -exec chmod 644 {} \;
# Special permissions for wp-config.php (optional stricter)
# chmod 640 ${WP_PATH}/wp-config.php
print_success "File permissions set."

# 7. Configure Apache
print_info "Configuring Apache..."
# Enable rewrite module for permalinks
a2enmod rewrite

# Allow .htaccess overrides for the WordPress directory
# Modify the default Apache config - adjust if using a custom vhost
APACHE_CONF="/etc/apache2/sites-available/000-default.conf"
if [ -f "$APACHE_CONF" ]; then
    # Check if AllowOverride All is already set for WP_PATH directory block
    if ! grep -q "<Directory ${WP_PATH//\//\\/}>" "$APACHE_CONF" && ! grep -q "AllowOverride All" "$APACHE_CONF"; then
        sed -i "/<Directory ${WP_PATH//\//\\/}>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/" "$APACHE_CONF"
        print_info "Enabled AllowOverride All in ${APACHE_CONF}."
    elif ! grep -A 5 "<Directory ${WP_PATH//\//\\/}>" "$APACHE_CONF" | grep -q "AllowOverride All"; then
         # If directory exists but AllowOverride is not All, add it
         sed -i "/<Directory ${WP_PATH//\//\\/}>/a \\tAllowOverride All" "$APACHE_CONF"
         print_info "Added AllowOverride All to ${WP_PATH} directory block in ${APACHE_CONF}."
    else
        print_info "AllowOverride All seems already configured in ${APACHE_CONF}."
    fi
else
    # If default conf not found, check generic apache2.conf - less common scenario
    APACHE_CONF="/etc/apache2/apache2.conf"
     if ! grep -q "<Directory ${WP_PATH//\//\\/}>" "$APACHE_CONF" && ! grep -q "AllowOverride All" "$APACHE_CONF"; then
        sed -i "/<Directory ${WP_PATH//\//\\/}>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/" "$APACHE_CONF"
        print_info "Enabled AllowOverride All in ${APACHE_CONF}."
    else
         print_info "AllowOverride All seems already configured or default conf missing. Check manually."
    fi
fi


# Optional: Create a basic .htaccess for permalinks (WordPress usually handles this)
#cat > ${WP_PATH}/.htaccess <<EOF
## BEGIN WordPress
#<IfModule mod_rewrite.c>
#RewriteEngine On
#RewriteBase /
#RewriteRule ^index\.php$ - [L]
#RewriteCond %{REQUEST_FILENAME} !-f
#RewriteCond %{REQUEST_FILENAME} !-d
#RewriteRule . /index.php [L]
#</IfModule>
## END WordPress
#EOF
#chown www-data:www-data ${WP_PATH}/.htaccess
#chmod 644 ${WP_PATH}/.htaccess

# Restart Apache to apply changes
print_info "Restarting Apache..."
systemctl restart apache2
print_success "Apache configured and restarted."

# 8. Cleanup
print_info "Cleaning up temporary files..."
rm /tmp/latest.tar.gz
rm -rf /tmp/wordpress
print_success "Cleanup complete."

# --- Final Instructions ---
CONTAINER_IP=$(hostname -I | awk '{print $1}') # Get the primary IP

echo ""
print_success "WordPress Installation Completed!"
echo "--------------------------------------------------"
echo "Access WordPress via your browser:"
echo -e "\033[1mhttp://${CONTAINER_IP}/\033[0m"
echo ""
echo "Follow the on-screen instructions to set up your site title, admin user, etc."
echo ""
echo "Database Details (saved in wp-config.php):"
echo "  Database Name:   ${DB_NAME}"
echo "  Database User:   ${DB_USER}"
echo -e "  Database Password: \033[33m${DB_PASS}\033[0m"
echo ""
echo "MariaDB Root Password (use for database administration):"
echo -e "  Root User:       root"
echo -e "  Root Password:   \033[31;1m${ROOT_DB_PASS}\033[0m"
echo ""
print_warning "IMPORTANT: Store the MariaDB root password securely!"
echo "--------------------------------------------------"

exit 0
