#!/bin/sh
set -e

BASE=http://localhost:8181/api
ROOT_SECRET="${POLARIS_ROOT_SECRET:-s3cr3t}"
CREDS_FILE=/out/polaris_creds.env

# Host IP that Minio listens on; override by exporting HOST_IP before `docker compose up`
HOST_IP="${HOST_IP:-$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | grep -v ' 172\.' | awk '{print $2}' | cut -d/ -f1 | head -n 1)}"
if [ -z "$HOST_IP" ]; then
  echo "Could not determine HOST_IP; set it explicitly and retry."
  exit 1
fi
echo "Using HOST_IP ${HOST_IP}"

echo "Waiting for Polaris API to be ready..."
while ! curl -sf http://localhost:8182/q/health > /dev/null; do
  sleep 2
done

echo "Authenticating as root..."
RESPONSE=$(curl -s -X POST ${BASE}/catalog/v1/oauth/tokens \
  -d "grant_type=client_credentials&client_id=root&client_secret=${ROOT_SECRET}&scope=PRINCIPAL_ROLE:ALL")
TOKEN=$(echo "$RESPONSE" | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
  echo "Failed to retrieve token. Response: $RESPONSE"
  exit 1
fi

# call METHOD PATH JSON [WAREHOUSE]
# Fails on HTTP errors, except 409 (already exists) so the script can be re-run.
# Response body is left in /tmp/resp and the HTTP status in $CODE.
call() {
  if [ -n "$4" ]; then
    CODE=$(curl -s -o /tmp/resp -w '%{http_code}' -X "$1" "${BASE}$2" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
      -H "Warehouse: $4" -d "$3")
  else
    CODE=$(curl -s -o /tmp/resp -w '%{http_code}' -X "$1" "${BASE}$2" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
      -d "$3")
  fi
  case "$CODE" in
    2??) ;;
    409) echo "  already exists, skipping" ;;
    *) echo "Request $1 $2 failed with HTTP $CODE: $(cat /tmp/resp)"; exit 1 ;;
  esac
}

echo "Creating Iceberg Catalog 'dataiku_catalog'..."
call POST /management/v1/catalogs "{
  \"name\": \"dataiku_catalog\",
  \"type\": \"INTERNAL\",
  \"properties\": {
    \"default-base-location\": \"s3://dataiku/\",
    \"s3.endpoint\": \"http://${HOST_IP}:9000\",
    \"s3.path-style-access\": \"true\"
  },
  \"storageConfigInfo\": {
    \"storageType\": \"S3\",
    \"allowedLocations\": [\"s3://dataiku/\"],
    \"endpoint\": \"http://${HOST_IP}:9000\",
    \"pathStyleAccess\": true,
    \"region\": \"${S3_REGION}\"
  }
}"

echo "Creating the principal user - 'dataiku'..."
call POST /management/v1/principals '{"name": "dataiku", "type": "user"}'
if [ "$CODE" = "409" ]; then
  echo "Principal exists; keeping existing credentials in $(basename $CREDS_FILE)."
else
  CLIENT_ID=$(sed -n 's/.*"clientId" *: *"\([^"]*\)".*/\1/p' /tmp/resp)
  CLIENT_SECRET=$(sed -n 's/.*"clientSecret" *: *"\([^"]*\)".*/\1/p' /tmp/resp)
  if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "Could not parse principal credentials: $(cat /tmp/resp)"
    exit 1
  fi
  echo "CLIENT_ID=$CLIENT_ID" > "$CREDS_FILE"
  echo "CLIENT_SECRET=$CLIENT_SECRET" >> "$CREDS_FILE"
  echo "DATAIKU_CLIENT_ID: $CLIENT_ID"
  echo "DATAIKU_CLIENT_SECRET: $CLIENT_SECRET"
fi

echo "Creating the principal-role - 'dataiku_role'..."
call POST /management/v1/principal-roles '{"principalRole": {"name": "dataiku_role"}}'

echo "Assigning the principal-role to the principal..."
call PUT /management/v1/principals/dataiku/principal-roles '{"principalRole": {"name": "dataiku_role"}}'

echo "Creating the catalog-role - 'dataiku_catalog_role'..."
call POST /management/v1/catalogs/dataiku_catalog/catalog-roles '{"catalogRole": {"name": "dataiku_catalog_role"}}'

echo "Assigning the catalog-role to the principal-role..."
call PUT /management/v1/principal-roles/dataiku_role/catalog-roles/dataiku_catalog '{"catalogRole": {"name": "dataiku_catalog_role"}}'

echo "Granting privileged permissions to 'dataiku_catalog_role'..."
call PUT /management/v1/catalogs/dataiku_catalog/catalog-roles/dataiku_catalog_role/grants \
  '{"grant": {"type": "catalog", "privilege": "CATALOG_MANAGE_CONTENT"}}'

echo "Creating the namespace 'dataiku' in 'dataiku_catalog'..."
call POST /catalog/v1/dataiku_catalog/namespaces '{"namespace": ["dataiku"]}' dataiku_catalog

echo "Setup complete!"
