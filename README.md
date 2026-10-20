# Quick deploy Minio & Polaris 

This project provides a sample custom docker-compose.yml file and a setup.sh to quickly spin up Minio and Polaris REST catalog containers on the same Linux server. The objective of this project is to allow quick deployment of Minio and Polaris REST catalog services set up and ready for lab testing on Iceberg in Dataiku with minimal user intervention.


## Files

1.  **docker-compose.yml**: Deploys and configures the following containers - 
    - Minio container with service listening on port 9000 and UI on port 9001, default credentials(minioadmin/minioadmin) and default bucket(dataiku). 
    - Postgres database (polaris) to support Polaris REST catalog listening on port 5432.  
    - Polaris REST catalog container with API endpoint listening on port 8181 and management on port 8282, with connectivities configured to the Postgres database and Minio service, and a transient polaris-setup-worker to run setup.sh to create the following resources in the catalog.

2.  **setup.sh**: Executed by transient setup worker to provision the Polaris REST catalog. The key resources created 
    - warehouse/catalog = dataiku_catalog
    - principal user = dataiku (with CLIENT_ID and CLIENT_SECRET writtin into polaris_creds.env) with associated roles 
    - namespace = dataiku  

3.  **polaris_creds.env**: This file gets overwritten with the Polaris REST catalog user credentials. Docker-compose is not able to create this file - ensure this file already exists in the folder with write permissions.  

## Setup Instructions with Dataiku

You can either run this on a standalone Linux server with network connectivity to the DSS instance OR simply run them on the DSS instance. Ensure docker compose is installed on the server:

*  Place all three files (docker-compose.yml, setup.sh and polaris_credts.env) in the same folder and run `docker compose up -d`
*  Take note of your primary IP address [HOST_IP] of the host machine. In cloud environemnt, it is typically in 10.x.x.x address. This will be the IP address the Minio and Polaris services listening on.


### Creating the connections

*  At Dataiku instance, create a new S3 connection and provide the following parameters:
    #### Connection
    - Credentials: AWS keypair
    - Access key: minioadmin
    - Secret key: minioadmin
    - Region/Endpoint: http://[HOST_IP]:9000
    #### Path restrictions
    - Bucket: dataiku
    #### Advanced
    - Use path style: CHECKED

*  At Dataiku instance, create a new Iceberg connection and provide the following parameters:
    #### Connection
    - Catalog type: REST
    - URI: http://[HOST_IP]:8181/api/catalog
    - Warehouse: dataiku_catalog
    - Authentication type: User/Password
        - User: [CLIENT_ID]
        - Password: [CLIENT_SECRET]
    #### Properties
    - Catalog properties: scope -> PRINCIPAL_ROLE:ALL
    #### Namespaces
    - Default namespace: dataiku
    #### Rules for new datasets
    - namespace: dataiku
    #### Custom properties
    - Catalog name: dataiku_catalog

*  To tear down setup, run `docker compose down`

## Additional Notes

The polaris-setup-worker spins up on `network_mode=host` in order to be on the same network as the host machine and setup.sh will then try to retrieve the host's machine IP address in order to configure the Polaris REST catalog to connect with the Minio service also listening on the same IP address. This process should work fine in most situations but not thoroughly validated.
