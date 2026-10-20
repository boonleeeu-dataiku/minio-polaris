#!/bin/sh
set -e

export HOST_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | grep -v '172.' | awk '{print $2}' | cut -d/ -f1 | head -n 1) 
echo "Retrieved HOST_IP as ${HOST_IP}"

echo "Waiting for Polaris API to be ready..."
while ! curl -s http://localhost:8181/api/management/v1/health > /dev/null; do
  sleep 2
done

echo "Authenticating as root..."
# 1. Get OAuth Token (Fixed grep to work in Alpine/Curl image)
RESPONSE=$(curl -s -X POST http://localhost:8181/api/catalog/v1/oauth/tokens \
  -d "grant_type=client_credentials&client_id=root&client_secret=s3cr3t&scope=PRINCIPAL_ROLE:ALL")

TOKEN=$(echo $RESPONSE | sed 's/.*"access_token":"\([^"]*\)".*/\1/')

if [ -z "$TOKEN" ]; then
  echo "Failed to retrieve token. Response: $RESPONSE"
  exit 1
fi

# 2. Create the catalog (Example: S3/MinIO)
echo "Creating Iceberg Catalog..."

CATALOG_JSON=$(cat <<EOF
{
  "name": "dataiku_catalog",
    "type": "INTERNAL",
    "properties": { 
        "default-base-location": "s3://dataiku/", 
        "s3.endpoint": "http://$HOST_IP:9000", 
        "s3.path-style-access": "true",
        "polaris.config.drop-with-purge.enabled": "true"
    },
    "storageConfigInfo": { 
        "storageType": "S3", 
        "allowedLocations": ["s3://dataiku/"],
        "endpoint": "http://$HOST_IP:9000",
        "pathStyleAccess": "true",
        "region": "$S3_REGION"
    }
}
EOF
)

curl -X POST http://localhost:8181/api/management/v1/catalogs \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$CATALOG_JSON"


sleep 1
# 3. Create a principal
echo "Creating the principal user - 'dataiku'..."

PRINCIPAL_RESP=$(curl -X POST http://localhost:8181/api/management/v1/principals \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{  
    "name": "dataiku",
    "type": "user"
  }'
)

# Extract Client ID and Secret using sed (works in Alpine/Curl image)
DATAIKU_CLIENT_ID=$(echo $PRINCIPAL_RESP | sed 's/.*"clientId":"\([^"]*\)".*/\1/')
DATAIKU_CLIENT_SECRET=$(echo $PRINCIPAL_RESP | sed 's/.*"clientSecret":"\([^"]*\)".*/\1/')

# Print to logs so you can see them
echo "DATAIKU_CLIENT_ID: $DATAIKU_CLIENT_ID"
echo "DATAIKU_CLIENT_SECRET: $DATAIKU_CLIENT_SECRET"

# Save to a file in /tmp (or a mapped volume) so you can read them later
echo "CLIENT_ID=$DATAIKU_CLIENT_ID" > /usr/local/bin/polaris_creds.env
echo "CLIENT_SECRET=$DATAIKU_CLIENT_SECRET" >> /usr/local/bin/polaris_creds.env

sleep 1
# 4. Create a principal-role
echo "Creating the principal-role - 'dataiku_role'..."

curl -X POST http://localhost:8181/api/management/v1/principal-roles \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "principalRole": {
        "name": "dataiku_role"
    }
  }'

sleep 1
# 5. Assign the principal-role to the principal
echo "Assigning the principal-role to the principal..."

curl -X PUT http://localhost:8181/api/management/v1/principals/dataiku/principal-roles \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "principalRole": {
        "name": "dataiku_role"
    }
  }'

sleep 1
# 6. Create a catalog-role
echo "Creating the catalog-role - 'dataiku_catalog_role'..."

curl -X POST http://localhost:8181/api/management/v1/catalogs/dataiku_catalog/catalog-roles \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "catalogRole": {
        "name": "dataiku_catalog_role"
    }
  }'

sleep 1
# 7. Assign the catalog-role to the principal-role of catalog (dataiku_catalog)
echo "Assigning the catalog-role to the principal-role ..."

curl -X PUT http://localhost:8181/api/management/v1/principal-roles/dataiku_role/catalog-roles/dataiku_catalog \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "catalogRole": {
        "name": "dataiku_catalog_role"
    }
  }'

sleep 1
# 8. Grant privileged permissions to the catalog-role
echo "Granting privileged permissions to 'dataiku_catalog_role'..."

curl -X PUT http://localhost:8181/api/management/v1/catalogs/dataiku_catalog/catalog-roles/dataiku_catalog_role/grants \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "grant": {
        "type": "catalog",
        "privilege": "CATALOG_MANAGE_CONTENT"
    }
  }'

sleep 1
# 9. Create a namespace under dataiku-catalog
echo "Creating the namespace 'dataiku' in 'dataiku-catalog'..."

curl -X POST http://localhost:8181/api/catalog/v1/dataiku_catalog/namespaces \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Warehouse: dataiku_catalog" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": ["dataiku"]
  }'

echo "Setup complete!"


