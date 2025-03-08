#!/bin/bash

CONFIG_FILE="/etc/backup-config.conf"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

BACKUP_DIR="/tmp/ols_backups/backups"
LOG_DIR="/var/log/ols-backups/backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOG_DIR}/backup_${DATE}.log"

SITES=()
DATABASES=()

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging function
log() {
    local LEVEL="$1"
    local MESSAGE="$2"
    echo "$(date +"%Y-%m-%d %H:%M:%S") [$LEVEL] $MESSAGE" | tee -a "$LOG_FILE"
}

log "INFO" "Backup process started."

# Load static configuration from /etc/backup-config.conf
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    log "ERROR" "Configuration file $CONFIG_FILE not found!"
    exit 1
fi

# Validate required variables
REQUIRED_VARS=("S3_BUCKET" "S3_BACKUP_DIR" "AWS_REGION_BACKUP")

for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR}" ]]; then
        log "ERROR" "Required variable '$VAR' is not set in $CONFIG_FILE"
        exit 1
    fi
done

# Extract virtual host names from OpenLiteSpeed's configuration
if [[ -f "$LSWS_CONF" ]]; then
    # Extract virtualhost names
    while IFS= read -r line; do
        if [[ "$line" =~ virtualhost\ (.+)\ \{ ]]; then
            SITES+=("${BASH_REMATCH[1]}")
        fi
    done <"$LSWS_CONF"

    # Extract template members
    while IFS= read -r line; do
        if [[ "$line" =~ member\ (.+) ]]; then
            SITES+=("${BASH_REMATCH[1]}")
        fi
    done <"$LSWS_CONF"
else
    log "WARNING" "LiteSpeed configuration file not found at $LSWS_CONF"
fi

# Remove duplicates
SITES=($(echo "${SITES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

# Required utilities
REQUIRED_TOOLS=("zip" "mariadb-dump" "aws" "dpkg" "crontab")

log "INFO" "Checking required utilities."
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        log "ERROR" "Missing required tool: $tool. Install it and rerun the script."
        exit 1
    fi
done

# Fetch database list excluding system databases
DB_LIST=$(mariadb -N -B -e "SHOW DATABASES;" 2>>"$LOG_FILE" | grep -Ev "^(information_schema|mysql|performance_schema|sys)$")

if [[ $? -eq 0 ]]; then
    DATABASES=($DB_LIST)
else
    log "WARNING" "Failed to fetch databases from MariaDB. Ensure MariaDB is running and accessible."
fi

log "INFO" "SITES: ${SITES[*]}"
log "INFO" "DATABASES: ${DATABASES[*]}"
log "INFO" "S3_BUCKET=$S3_BUCKET"
log "INFO" "S3_BACKUP_DIR=$S3_BACKUP_DIR"
log "INFO" "AWS_REGION_BACKUP=$AWS_REGION_BACKUP"

# Create backup directory
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR/sites"
mkdir -p "$BACKUP_DIR/db"
mkdir -p "$BACKUP_DIR/conf"
mkdir -p "$BACKUP_DIR/sys"

# Backup website directories
log "INFO" "Backing up website directories."
for SITE in "${SITES[@]}"; do
    ZIP_NAME="${BACKUP_DIR}/sites/${SITE}_${DATE}.zip"
    if [ -d "/var/www/$SITE" ]; then
        (cd /var/www/$SITE && zip -rq "$ZIP_NAME" .) >>"$LOG_FILE" 2>&1
        log "INFO" "Website $SITE backed up successfully: $ZIP_NAME"
    else
        log "WARNING" "Directory /var/www/$SITE does not exist, skipping."
    fi
done

# Backup OpenLiteSpeed configs
log "INFO" "Backing up OpenLiteSpeed configurations."
OLS_ZIP="${BACKUP_DIR}/conf/ols_configs_${DATE}.zip"
(cd /usr/local/lsws && zip -rq "$OLS_ZIP" "conf" "admin/conf") >>"$LOG_FILE" 2>&1
log "INFO" "OpenLiteSpeed configs backed up successfully: $OLS_ZIP"

# Backup MariaDB databases
log "INFO" "Backing up MariaDB databases."
for DB in "${DATABASES[@]}"; do
    DB_ZIP="${BACKUP_DIR}/db/${DB}_${DATE}.sql.gz"
    mariadb-dump --single-transaction --quick --lock-tables=false "$DB" | gzip >"$DB_ZIP" 2>>"$LOG_FILE"
    if [ $? -eq 0 ]; then
        log "INFO" "Database $DB backed up successfully: $DB_ZIP"
    else
        log "ERROR" "Failed to backup database: $DB"
    fi
done

# Backup MariaDB users and privileges
log "INFO" "Backing up MariaDB users and privileges."
USERS_SQL="${BACKUP_DIR}/db/mariadb_users_${DATE}.sql"
USERS_ZIP="${BACKUP_DIR}/db/mariadb_users_${DATE}.sql.gz"
USERS_MAP="${BACKUP_DIR}/db/users_db_map_${DATE}.json"

# Create header for users SQL
echo "-- MariaDB user backup created on $(date)" >"$USERS_SQL"

# First, generate a proper JSON file for user-database mapping
echo "{" >"$USERS_MAP"
echo "  \"users\": {" >>"$USERS_MAP"

# Get all users and the databases they have access to
FIRST_USER=true
mariadb -N -B -e "
    SELECT CONCAT(
        '    \"', u.user, '@', u.host, '\": {',
        '\"plugin\": \"', u.plugin, '\",',
        '\"dbs\": [',
        IF(MAX(db.db) IS NULL, '', 
            GROUP_CONCAT(DISTINCT 
                CONCAT('\"', 
                    CASE WHEN db.db = '*' THEN 'ALL_DBS' ELSE db.db END,
                '\"')
                SEPARATOR ', '
            )
        ),
        ']',
        '}'
    )
    FROM mysql.user u
    LEFT JOIN mysql.db db ON u.user = db.user AND u.host = db.host
    WHERE u.user NOT IN ('mariadb.sys', 'root', 'mysql')
    GROUP BY u.user, u.host, u.plugin;" | while read -r line; do
    if [ "$FIRST_USER" = true ]; then
        echo "$line" >>"$USERS_MAP"
        FIRST_USER=false
    else
        echo "," >>"$USERS_MAP"
        echo "$line" >>"$USERS_MAP"
    fi
done

# Close the JSON structure
echo "  }" >>"$USERS_MAP"
echo "}" >>"$USERS_MAP"

# Add user creation statements with proper authentication methods
mariadb -N -B -e "
    SELECT CONCAT(
        'CREATE USER IF NOT EXISTS ''', user, '''@''', host, ''' ',
        CASE 
            WHEN plugin = 'mysql_native_password' THEN 
                CONCAT('IDENTIFIED WITH mysql_native_password USING ''', authentication_string, '''')
            WHEN plugin = 'unix_socket' THEN 
                'IDENTIFIED WITH unix_socket'
            WHEN plugin = 'ed25519' THEN 
                CONCAT('IDENTIFIED WITH ed25519 USING ''', authentication_string, '''') 
            WHEN plugin = 'pam' THEN 
                'IDENTIFIED WITH pam'
            ELSE
                CONCAT('IDENTIFIED WITH ', plugin, 
                      IF(authentication_string != '', 
                         CONCAT(' USING ''', authentication_string, ''''), 
                         ''))
        END, 
        ';'
    ) 
    FROM mysql.user 
    WHERE user NOT IN ('mariadb.sys', 'root', 'mysql');" >>"$USERS_SQL" 2>>"$LOG_FILE"

# Extract users and their privileges
echo "# Grants for each user" >>"$USERS_SQL"
mariadb -N -B -e "
    SELECT CONCAT('SHOW GRANTS FOR ''', user, '''@''', host, ''';') 
    FROM mysql.user 
    WHERE user NOT IN ('mariadb.sys', 'root', 'mysql');" |
    mariadb 2>/dev/null |
    grep -v "Grants for" |
    sed 's/$/;/' >>"$USERS_SQL" 2>>"$LOG_FILE"

# Compress the users SQL file
gzip "$USERS_SQL" 2>>"$LOG_FILE"

if [ -f "$USERS_ZIP" ]; then
    log "INFO" "MariaDB users backed up successfully: $USERS_ZIP"
    log "INFO" "User-to-database mapping created: $USERS_MAP"
else
    log "ERROR" "Failed to backup MariaDB users"
fi

# Backup System Package List
log "INFO" "Backing up installed system packages."
dpkg --get-selections >"$BACKUP_DIR/sys/packages_${DATE}.list" 2>>"$LOG_FILE"
log "INFO" "System packages backed up successfully: $BACKUP_DIR/sys/packages_${DATE}.list"

# Backup Crontab
log "INFO" "Backing up crontab."
crontab -l >"$BACKUP_DIR/sys/crontab_${DATE}.bak" 2>>"$LOG_FILE"
log "INFO" "Crontab backed up successfully: $BACKUP_DIR/sys/crontab_${DATE}.bak"

# Upload backups to S3
log "INFO" "Uploading backups to S3."
aws s3 cp --region "$AWS_REGION_BACKUP" --recursive "$BACKUP_DIR" "s3://${S3_BUCKET}/${S3_BACKUP_DIR}/${DATE}/" >>"$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
    log "INFO" "Backup uploaded successfully to S3: s3://${S3_BUCKET}/${S3_BACKUP_DIR}/${DATE}/"
else
    log "ERROR" "Failed to upload backup to S3."
fi

# Cleanup local backups
log "INFO" "Cleaning up local backup files."
rm -rf "$BACKUP_DIR"

log "INFO" "Backup process completed successfully."
