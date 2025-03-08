#!/bin/bash

CONFIG_FILE="/etc/backup-config.conf"

RESTORE_DIR="/tmp/ols_backups/restore"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="/var/log/ols-backups/restore"
LOG_FILE="${LOG_DIR}/restore_${DATE}.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging function
log() {
    local LEVEL="$1"
    local MESSAGE="$2"
    echo "$(date +"%Y-%m-%d %H:%M:%S") [$LEVEL] $MESSAGE" | tee -a "$LOG_FILE"
}

# Load configuration
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

# Ensure necessary parameters are provided
if [[ $# -ne 3 ]]; then
    log "ERROR" "Usage: $0 <website_domain> <database_name> <backup_date_time>"
    exit 1
fi

WEBSITE_DOMAIN="$1"
DATABASE_NAME="$2"
BACKUP_DATE_TIME="$3"

# Validate backup_date_time format
if ! [[ "$BACKUP_DATE_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
    log "ERROR" "Invalid backup date-time format. Expected format: YYYY-MM-DD_HH-MM-SS"
    exit 1
fi

log "INFO" "Restore process started."

# Create restore directory
mkdir -p "$RESTORE_DIR"
mkdir -p "/var/www/$WEBSITE_DOMAIN"

# Check if website directory is empty
if [ -n "$(ls -A /var/www/$WEBSITE_DOMAIN 2>/dev/null)" ]; then
    log "INFO" "Website directory /var/www/$WEBSITE_DOMAIN is not empty. Skipping site restore."
else
    WEBSITE_BACKUP_FILE="sites/${WEBSITE_DOMAIN}_${BACKUP_DATE_TIME}.zip"
    WEBSITE_BACKUP_PATH="s3://${S3_BUCKET}/${S3_BACKUP_DIR}/${BACKUP_DATE_TIME}/${WEBSITE_BACKUP_FILE}"

    aws s3 cp "$WEBSITE_BACKUP_PATH" "$RESTORE_DIR/" --region "$AWS_REGION_BACKUP" >>"$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to download website backup from S3."
        exit 1
    fi

    if [[ ! -f "$RESTORE_DIR/${WEBSITE_DOMAIN}_${BACKUP_DATE_TIME}.zip" ]]; then
        log "ERROR" "Website backup file not found after download."
        exit 1
    fi

    log "INFO" "Website backup downloaded. Extracting files."
    unzip -q "$RESTORE_DIR/${WEBSITE_DOMAIN}_${BACKUP_DATE_TIME}.zip" -d "/var/www/$WEBSITE_DOMAIN" >>"$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to extract website files."
        exit 1
    fi

    # Ensure correct ownership and permissions
    chown -R www-data:www-data "/var/www/$WEBSITE_DOMAIN"
    chmod -R 755 "/var/www/$WEBSITE_DOMAIN"

    log "INFO" "Website files restored to /var/www/$WEBSITE_DOMAIN with correct ownership and permissions."
fi

# Check if database exists and has tables
DB_EXISTS=$(mariadb -N -B -e "SHOW DATABASES LIKE '$DATABASE_NAME';")

if [[ -z "$DB_EXISTS" ]]; then
    log "INFO" "Database $DATABASE_NAME does not exist. Creating it..."
    mariadb -e "CREATE DATABASE $DATABASE_NAME;" >>"$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create database $DATABASE_NAME."
        exit 1
    fi
fi

TABLE_COUNT=$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME';" | awk '{print $1}')

if [[ "$TABLE_COUNT" -gt 0 ]]; then
    log "INFO" "Database $DATABASE_NAME exists and has tables. Skipping database restore."
else
    DB_BACKUP_FILE="db/${DATABASE_NAME}_${BACKUP_DATE_TIME}.sql.gz"
    DB_BACKUP_PATH="s3://${S3_BUCKET}/${S3_BACKUP_DIR}/${BACKUP_DATE_TIME}/${DB_BACKUP_FILE}"

    aws s3 cp "$DB_BACKUP_PATH" "$RESTORE_DIR/" --region "$AWS_REGION_BACKUP" >>"$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to download database backup from S3."
        exit 1
    fi

    if [[ ! -f "$RESTORE_DIR/${DATABASE_NAME}_${BACKUP_DATE_TIME}.sql.gz" ]]; then
        log "ERROR" "Database backup file not found after download."
        exit 1
    fi

    log "INFO" "Database backup downloaded. Restoring database."
    gunzip -c "$RESTORE_DIR/${DATABASE_NAME}_${BACKUP_DATE_TIME}.sql.gz" | mariadb "$DATABASE_NAME" >>"$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to restore database."
        exit 1
    fi

    log "INFO" "Database $DATABASE_NAME restored successfully."
fi

# Restore database users and permissions
log "INFO" "Checking for user mapping file to restore database users and permissions."

# Download the user-database mapping file
USERS_MAP_FILE="db/users_db_map_${BACKUP_DATE_TIME}.json"
USERS_MAP_PATH="s3://${S3_BUCKET}/${S3_BACKUP_DIR}/${BACKUP_DATE_TIME}/${USERS_MAP_FILE}"

aws s3 cp "$USERS_MAP_PATH" "$RESTORE_DIR/" --region "$AWS_REGION_BACKUP" >>"$LOG_FILE" 2>&1
if [[ $? -ne 0 ]]; then
    log "WARNING" "Failed to download user-database mapping file from S3. Skipping user restoration."
else
    if [[ -f "$RESTORE_DIR/users_db_map_${BACKUP_DATE_TIME}.json" ]]; then
        log "INFO" "User mapping file found. Processing database users."

        # Download the SQL statements for user creation
        USERS_SQL_FILE="db/mariadb_users_${BACKUP_DATE_TIME}.sql.gz"
        USERS_SQL_PATH="s3://${S3_BUCKET}/${S3_BACKUP_DIR}/${BACKUP_DATE_TIME}/${USERS_SQL_FILE}"

        aws s3 cp "$USERS_SQL_PATH" "$RESTORE_DIR/" --region "$AWS_REGION_BACKUP" >>"$LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            log "WARNING" "Failed to download user SQL file from S3. Skipping user restoration."
        else
            # Extract users SQL file
            gunzip -f "$RESTORE_DIR/mariadb_users_${BACKUP_DATE_TIME}.sql.gz" >>"$LOG_FILE" 2>&1

            if [[ ! -f "$RESTORE_DIR/mariadb_users_${BACKUP_DATE_TIME}.sql" ]]; then
                log "ERROR" "Failed to extract user SQL file."
            else
                log "INFO" "Processing users for database: $DATABASE_NAME"

                # Use jq to extract users with access to the specified database
                # First check if jq is installed
                if ! command -v jq &>/dev/null; then
                    log "WARNING" "jq is not installed. Cannot parse JSON mapping file. Installing jq..."
                    apt-get update && apt-get install -y jq >>"$LOG_FILE" 2>&1
                    if [[ $? -ne 0 ]]; then
                        log "ERROR" "Failed to install jq. Skipping user restoration."
                        rm -f "$RESTORE_DIR/mariadb_users_${BACKUP_DATE_TIME}.sql"
                    fi
                fi

                if command -v jq &>/dev/null; then
                    # Process each user with access to the database
                    jq -r --arg db "$DATABASE_NAME" '.users | to_entries[] | select(.value.dbs | map(. == $db or . == "ALL_DBS") | any) | .key' "$RESTORE_DIR/users_db_map_${BACKUP_DATE_TIME}.json" | while read -r user_host; do
                        if [[ -n "$user_host" ]]; then
                            # Extract username and hostname
                            user=$(echo "$user_host" | cut -d'@' -f1)
                            host=$(echo "$user_host" | cut -d'@' -f2)

                            # Check if user already exists
                            USER_EXISTS=$(mariadb -N -B -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user='$user' AND host='$host')")

                            if [[ "$USER_EXISTS" -eq 0 ]]; then
                                log "INFO" "Creating user: $user@$host"

                                # Extract and execute the CREATE USER statement for this user
                                grep -A 1 -m 1 "CREATE USER.*'$user'@'$host'" "$RESTORE_DIR/mariadb_users_${BACKUP_DATE_TIME}.sql" | mariadb >>"$LOG_FILE" 2>&1

                                if [[ $? -ne 0 ]]; then
                                    log "ERROR" "Failed to create user $user@$host."
                                else
                                    log "INFO" "User $user@$host created successfully."
                                fi
                            else
                                log "INFO" "User $user@$host already exists. Skipping creation."
                            fi

                            # Grant permissions only for the database being restored
                            log "INFO" "Granting permissions to $user@$host for database $DATABASE_NAME"
                            mariadb -e "GRANT ALL PRIVILEGES ON \`$DATABASE_NAME\`.* TO '$user'@'$host';" >>"$LOG_FILE" 2>&1

                            if [[ $? -ne 0 ]]; then
                                log "ERROR" "Failed to grant permissions to $user@$host for database $DATABASE_NAME."
                            else
                                log "INFO" "Permissions granted to $user@$host for database $DATABASE_NAME."
                            fi
                        fi
                    done

                    # Apply the grant changes
                    mariadb -e "FLUSH PRIVILEGES;" >>"$LOG_FILE" 2>&1

                    log "INFO" "Database user restoration completed."
                fi

                # Clean up SQL file
                rm -f "$RESTORE_DIR/mariadb_users_${BACKUP_DATE_TIME}.sql"
            fi
        fi
    else
        log "WARNING" "User mapping file not found after download. Skipping user restoration."
    fi
fi

# Cleanup
log "INFO" "Cleaning up temporary files."
rm -rf "$RESTORE_DIR"

log "INFO" "Restore process completed successfully."
