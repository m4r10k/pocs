#!/bin/bash

PROJECT="hewagner-demos-2"    # change!
REGION="europe-west3"
NETWORK_NAME="ilb-vpc"
GKE_SUBNET_NAME="ilb-subnet"
PROXY_ONLY_SUBNET_NAME="ilb-proxy-only-subnet"
GKE_IP_RANGE="10.10.0.0/26"
PROXY_ONLY_IP_RANGE="10.10.0.64/26"
FW_PREFIX="ilb-vpc-"
GKE_MASTER_EXT_IP="172.16.10.0/28"
KEYRING_NAME="key-ring-1"
KEY_NAME="key-1"
CLU_NAME="cluster-l7-ilb"


# Enable APIS
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    cloudkms.googleapis.com \
    --project=$PROJECT


### NETWORKING
### https://cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal#configure-a-network

# create vpc
gcloud compute networks create $NETWORK_NAME \
    --project=$PROJECT \ 
    --subnet-mode=custom

# create GKE subnet
gcloud networks subnets create $SUBNET_NAME \
    --project=$PROJECT \
    --network=$NETWORK_NAME \
    --region=$REGION \
    --range=

# create proxy only subnet
gcloud compute networks subnets create $PROXY_ONLY_SUBNET_NAME \
    --project=$PROJECT \
    --network=$NETWORK_NAME \
    --region=$REGION \
    --range=$PROXY_ONLY_IP_RANGE \
    --purpose=INTERNAL_HTTPS_LOAD_BALANCER \
    --role=ACTIVE


# allow ssh access to any nodes in the gke subnet with "allow-ssh" tag
gcloud compute firewall-rules create $FW_PREFIX-fw-allow-ssh \
    --network=$NETWORK_NAME \
    --action=allow \
    --direction=ingress \
    --target-tags=allow-ssh \
    --rules=tcp:22


### Prepare for application-layer secrets
# Create customer managed encryption key for App-layer-secrets
gcloud kms keyrings create $KEYRING_NAME \
    --location $REGION \ 
    --project=$PROJECT

gcloud kms keys create $KEY_NAME \
  --project=$PROJECT \
  --purpose=encryption \
  --location $REGION \
  --keyring $KEYRING_NAME


# Grant access to the container engine service account
PRJN=$(gcloud projects list --filter='project_id:'$PROJECT --format='value(PROJECT_NUMBER)')
SA=service-$PRJN@container-engine-robot.iam.gserviceaccount.com
gcloud kms keys add-iam-policy-binding $KEY_NAME \
  --location $REGION \
  --keyring $KEYRING_NAME \
  --member serviceAccount:$SA \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project $PROJECT



### Create GKE cluster
gcloud beta container clusters create $CLU_NAME \
    --project $PROJECT \ 
    --region $REGION \
    --no-enable-basic-auth \ 
    --release-channel "rapid" \
    --machine-type "n1-standard-1" \
    --image-type "COS" \
    --disk-type "pd-standard" \
    --disk-size "100" \
    --metadata disable-legacy-endpoints=true \
    --scopes "https://www.googleapis.com/auth/cloud-platform" \
    --num-nodes "1" \
    --enable-stackdriver-kubernetes \
    --enable-private-nodes \
    --master-ipv4-cidr $GKE_MASTER_EXT_IP \
    --enable-ip-alias \
    --network "projects/$PROJECT/global/networks/$NETWORK_NAME" \
    --subnetwork "projects/$PROJECT/regions/$REGION/subnetworks/$SUBNET_NAME" \
    --default-max-pods-per-node "110" \
    --no-enable-master-authorized-networks \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,ApplicationManager \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade 1 \
    --max-unavailable-upgrade 0 \
    --database-encryption-key "projects/$PROJECT/locations/$REGION/keyRings/$KEYRING_NAME/cryptoKeys/$KEY_NAME" \
    --identity-namespace "$PROJECT.svc.id.goog"