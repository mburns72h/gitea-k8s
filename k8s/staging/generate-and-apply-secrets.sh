#!/bin/bash
# Generate and apply secrets for Gitea staging deployment
set -e

echo "Generating secrets for gitea-staging..."

# Generate passwords
POSTGRES_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
GITEA_DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
REPMGR_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/')
INTERNAL_TOKEN=$(openssl rand -base64 105 | tr -d '\n/')
SECRET_KEY=$(openssl rand -base64 32 | tr -d '/')
LFS_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/')
OAUTH2_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/')

# Generate MD5 hash for pgpool
MD5_HASH=$(echo -n "${GITEA_DB_PASSWORD}giteauser" | md5sum | awk '{print $1}')
PGPOOL_CUSTOM_USERS="giteauser:md5${MD5_HASH}"

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Update secrets.yaml
sed -i.bak \
    -e "s|CHANGE_ME_postgres_admin_password|${POSTGRES_ADMIN_PASSWORD}|g" \
    -e "s|CHANGE_ME_gitea_db_password|${GITEA_DB_PASSWORD}|g" \
    -e "s|CHANGE_ME_repmgr_password|${REPMGR_PASSWORD}|g" \
    -e "s|CHANGE_ME_redis_password|${REDIS_PASSWORD}|g" \
    -e "s|CHANGE_ME_generate_with_gitea_generate_secret_INTERNAL_TOKEN|${INTERNAL_TOKEN}|g" \
    -e "s|CHANGE_ME_generate_with_gitea_generate_secret_SECRET_KEY|${SECRET_KEY}|g" \
    -e "s|md5CHANGE_ME_MD5_HASH|${PGPOOL_CUSTOM_USERS}|g" \
    "${SCRIPT_DIR}/secrets.yaml"

# Replace all occurrences of CHANGE_ME_generate_with_gitea_generate_secret_JWT_SECRET
# First with LFS_JWT_SECRET, second with OAUTH2_JWT_SECRET
awk -v lfs="${LFS_JWT_SECRET}" -v oauth="${OAUTH2_JWT_SECRET}" '
BEGIN { count=0 }
/CHANGE_ME_generate_with_gitea_generate_secret_JWT_SECRET/ {
    count++
    if (count == 1) {
        sub(/CHANGE_ME_generate_with_gitea_generate_secret_JWT_SECRET/, lfs)
    } else if (count == 2) {
        sub(/CHANGE_ME_generate_with_gitea_generate_secret_JWT_SECRET/, oauth)
    }
}
{ print }
' "${SCRIPT_DIR}/secrets.yaml" > "${SCRIPT_DIR}/secrets.yaml.tmp"
mv "${SCRIPT_DIR}/secrets.yaml.tmp" "${SCRIPT_DIR}/secrets.yaml"

echo "Secrets generated and updated in secrets.yaml"
echo "Applying secrets to gitea-staging namespace..."

kubectl apply -f "${SCRIPT_DIR}/secrets.yaml"

echo "Done! Secrets applied to gitea-staging namespace."
