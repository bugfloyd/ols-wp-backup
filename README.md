# OLS WordPress Backup Solution

A robust, server-level backup solution for OpenLiteSpeed servers hosting WordPress sites. This solution uses bash scripts to automatically detect websites and databases, create comprehensive backups, and securely store them in AWS S3.

## Detailed Documentation

For a complete explanation of how this backup solution works, including detailed script breakdowns, visit my blog post:
[Build a Robust S3-Powered Backup Solution for WordPress Hosted on OpenLiteSpeed Using Bash Scripts](https://bugfloyd.com/s3-backup-solution-for-wordpress-openlitespeed-using-bash)

## Overview

This repository contains scripts for creating a complete backup solution for OpenLiteSpeed WordPress servers:

- **backup.sh**: Automatically detects websites and databases, backs up website files, OpenLiteSpeed configurations, databases, database users, and system configurations to AWS S3.
- **restore.sh**: Selectively restores websites and databases from backups stored in S3.
- **Ansible Playbook**: Optional playbook for automated deployment of the backup solution.

### Why This Solution?

Traditional WordPress backup plugins have limitations:

- They rely on WordPress itself to function
- They're constrained by PHP and web server limits
- They consume significant server resources
- They can't backup server configurations

This solution addresses these limitations by running at the server level, independent of WordPress.

## Features

- **Automatic Detection**: Discovers websites and databases without manual configuration
- **Comprehensive Backups**:
  - Website files
  - Databases with proper transactions and consistency
  - Database users with their privileges
  - OpenLiteSpeed configurations
  - System configurations (package list, cron jobs)
- **AWS S3 Integration**: Securely stores backups off-site
- **Selective Restoration**: Restore specific websites or databases without affecting others
- **Smart Safety Checks**: Avoids overwriting existing content
- **Detailed Logging**: Comprehensive logs for troubleshooting

## Deployment Options

### Option 1: Manual Setup

1. **Install Required Dependencies**:

```bash
sudo apt update
sudo apt install zip
```

2. **Install AWS CLI**:

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
```

3. **Configure AWS CLI** (for servers outside AWS infrastructure):

```bash
aws configure
```

4. **Create Configuration File**:

```bash
sudo mkdir -p /etc
sudo nano /etc/backup-config.conf
```

Add:

```
S3_BUCKET="your-backup-bucket-name"
S3_BACKUP_DIR="ols-backups"
AWS_REGION_BACKUP="your-aws-region"
```

5. **Copy Scripts**:

```bash
sudo mkdir -p /opt/ols-backup
sudo cp backup.sh /opt/ols-backup/
sudo cp restore.sh /opt/ols-backup/
sudo chmod +x /opt/ols-backup/backup.sh
sudo chmod +x /opt/ols-backup/restore.sh
```

6. **Create Log Directory**:

```bash
sudo mkdir -p /var/log/ols-backups
```

7. **Set Up Cron Job** (daily backup at 3 AM):

```bash
sudo crontab -e
```

Add:

```
0 3 * * * /opt/ols-backup/backup.sh
```

### Option 2: Ansible Deployment

Important Note: The playbook does not configure AWS CLI credentials as it assumes the web server is running on AWS infrastructure with proper IAM roles applied to the instance. If you're using this outside of AWS, make sure to either update the playbook, or after running it, SSH into the server and configure the AWS CLI as mentioned in the manual deployment section above.

1. Edit the `vars.yml` file with your S3 bucket details
2. Update the `inventory.ini` file with your server details
3. Run the playbook:

```bash
ansible-playbook -i inventory.ini playbook.yml --extra-vars "@vars.yml"
```

## Usage

### Running Backups

Backups will run automatically according to the configured cron job. To run a backup manually:

```bash
sudo /opt/ols-backup/backup.sh
```

### Restoring from Backup

To restore a specific website and database:

```bash
sudo /opt/ols-backup/restore.sh example.com example_db YYYY-MM-DD_HH-MM-SS
```

Where:

- `example.com` is the website domain
- `example_db` is the database name
- `YYYY-MM-DD_HH-MM-SS` is the backup timestamp

## Contributions

Contributions are welcome! If you've made improvements or added features to the scripts, please feel free to submit a pull request.

When contributing:

- Ensure your code adheres to the existing style
- Add comments to explain complex operations
- Update the README.md if necessary
- Test your changes thoroughly before submitting

Some ideas for PRs:

- Implement checksum verification both during backup and before restoration to ensure data integrity
- Create tiered backup schedules:

  - Hourly backups for databases to minimize potential data loss
  - Daily backups for website files
  - Weekly/monthly backups for long-term archiving

- Add efficient file synchronization options using tools like rsync instead of bundling all files in every backup process
- Implement monitoring and notification systems:
- Email or Slack alerts when backups fail
- Status reports for successful backups
- Add a dry-run feature to test backup configurations without writing files
- Implement automated backup retention policies to manage storage costs
- Improve security by running backup processes with dedicated low-privilege UNIX and database users
