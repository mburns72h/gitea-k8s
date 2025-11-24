#!/bin/bash
# Generate secrets for Gitea deployment
# This script helps generate secure random passwords and tokens

set -e

echo "=== Gitea Secret Generator ==="
echo ""

# Generate PostgreSQL passwords
echo "PostgreSQL Passwords:"
echo "--------------------"
POSTGRES_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
GITEA_DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
REPMGR_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
echo "postgresql-password: $POSTGRES_ADMIN_PASSWORD"
echo "gitea_db_password: $GITEA_DB_PASSWORD"
echo "repmgr-password: $REPMGR_PASSWORD"
echo ""

# Generate Redis password
echo "Redis Password:"
echo "---------------"
REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
echo "redis-password: $REDIS_PASSWORD"
echo ""

# Generate Gitea secrets
echo "Gitea Application Secrets:"
echo "--------------------------"
INTERNAL_TOKEN=$(openssl rand -base64 105 | tr -d '\n/')
SECRET_KEY=$(openssl rand -base64 32 | tr -d '/')
LFS_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/')
OAUTH2_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/')
echo "internal_token: $INTERNAL_TOKEN"
echo "secret_key: $SECRET_KEY"
echo "lfs_jwt_secret: $LFS_JWT_SECRET"
echo "oauth2_jwt_secret: $OAUTH2_JWT_SECRET"
echo ""

# Generate MD5 hash for pgpool custom users
echo "Generating pgpool custom users hash..."
MD5_HASH=$(echo -n "${GITEA_DB_PASSWORD}giteauser" | md5sum | awk '{print $1}')
PGPOOL_CUSTOM_USERS="giteauser:md5${MD5_HASH}"
echo "pgpool custom users: $PGPOOL_CUSTOM_USERS"
echo ""

# Optionally update secrets.yaml
read -p "Do you want to update secrets.yaml with these values? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sed -i.bak \
        -e "s|CHANGE_ME_postgres_admin_password|${POSTGRES_ADMIN_PASSWORD}|g" \
        -e "s|CHANGE_ME_gitea_db_password|${GITEA_DB_PASSWORD}|g" \
        -e "s|CHANGE_ME_repmgr_password|${REPMGR_PASSWORD}|g" \
        -e "s|CHANGE_ME_redis_password|${REDIS_PASSWORD}|g" \
        -e "s|CHANGE_ME_generate_with_gitea_generate_secret_INTERNAL_TOKEN|${INTERNAL_TOKEN}|g" \
        -e "s|CHANGE_ME_generate_with_gitea_generate_secret_SECRET_KEY|${SECRET_KEY}|g" \
        -e "s|CHANGE_ME_generate_with_gitea_generate_secret_JWT_SECRET|${LFS_JWT_SECRET}|g" \
        -e "s|CHANGE_ME_generate_with_gitea_generate_secret_JWT_SECRET|${OAUTH2_JWT_SECRET}|g" \
        secrets.yaml

    # Update pgpool custom users secret separately
    sed -i \
        -e "s|usernames: \"giteauser\"|usernames: \"${PGPOOL_CUSTOM_USERS}\"|g" \
        -e "s|passwords: \"CHANGE_ME_gitea_db_password\"|passwords: \"${GITEA_DB_PASSWORD}\"|g" \
        secrets.yaml

    echo "secrets.yaml updated! Backup saved as secrets.yaml.bak"
else
    echo "Secrets not updated. Please manually update secrets.yaml with the values above."
fi

echo ""
echo "=== Important Notes ==="
echo "1. Store these passwords securely (password manager recommended)"
echo "2. The admin password for Gitea will be auto-generated on first startup"
echo "3. Check pod logs after deployment to get the generated admin password"
echo "4. You can reset the admin password later using 'gitea admin user change-password'"
