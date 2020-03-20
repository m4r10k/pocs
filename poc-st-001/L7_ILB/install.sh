#!/bin/bash
DELETE=0

while getopts ":p:d" opt; do
    case ${opt} in
        p ) PROJECT=$OPTARG;;
        d ) DELETE=1;;
        \? ) echo "usage: ./install.sh -p PROJECT_ID [-d]"; exit
    esac
done

if [ -z ${PROJECT+x} ]
then
    echo "You didn't provide the -p [PROJECT_ID]"
    exit
fi

# PROJECT="hewagner-demos-2"
REGION="europe-west3"
VM_ZONE="europe-west3-c"
NETWORK_NAME="ilb-vpc"
GKE_SUBNET_NAME="ilb-subnet"
PROXY_ONLY_SUBNET_NAME="ilb-proxy-only-subnet"
GKE_IP_RANGE="10.10.0.0/26"
PROXY_ONLY_IP_RANGE="10.10.0.64/26"
FW_PREFIX="ilb-vpc"
GKE_MASTER_EXT_IP="172.16.10.0/28"
KEYRING_NAME="key-ring-1"
KEY_NAME="key-1"
CLU_NAME="cluster-l7-ilb"
CONTAINER_NAME_1="hello-go-green"
CONTAINER_NAME_2="hello-go-blue"
CONTAINER_NAME_3="hello-go-red"
CONTAINER_VERSION="v1.0.0"
TEST_VM_NAME="l7-ilb-test-vm"

# Delete resources if -d was provided
if [ $DELETE == 1 ]; then
    # delete the cluster
    gcloud container clusters delete $CLU_NAME \
        --project=$PROJECT \
        --region=$REGION \
        -q --async


    # delete the test VM
    gcloud compute instances delete $TEST_VM_NAME \
        --project=$PROJECT \
        --zone=$VM_ZONE \
        -q

    # delete the containers in the registry
    gcloud container images delete \
        gcr.io/$PROJECT/$CONTAINER_NAME_1 \
        --project $PROJECT -q
    gcloud container images delete \
        gcr.io/$PROJECT/$CONTAINER_NAME_2 \
        --project $PROJECT -q
    gcloud container images delete \
        gcr.io/$PROJECT/$CONTAINER_NAME_3 \
        --project $PROJECT -q

    # delete NEGs
    for neg in $(gcloud compute network-endpoint-groups list --project=$PROJECT --format="value(name)" --filter="zone:europe-west3-a")
    do
        echo $neg
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION-a -q --project=$PROJECT
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION-b -q --project=$PROJECT
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION-c -q --project=$PROJECT
    done

    # delete firewall rules
    gcloud compute firewall-rules delete $FW_PREFIX-fw-allow-ssh \
        --project=$PROJECT -q

    # delete subnet and VPC
    gcloud compute networks subnets delete $GKE_SUBNET_NAME \
        --project=$PROJECT \
        --region=$REGION \
        -q
    gcloud compute networks subnets delete $PROXY_ONLY_SUBNET_NAME \
        --project=$PROJECT \
        --region=$REGION \
        -q
    gcloud compute networks delete $NETWORK_NAME \
        --project=$PROJECT \
        -q

    # deletion of kms key rings and keys is not possible
    
    exit
fi


# Enable APIS
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    cloudkms.googleapis.com \
    cloudbuild.googleapis.com \
    --project=$PROJECT


### NETWORKING
### https://cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal#configure-a-network

# create vpc
gcloud compute networks create $NETWORK_NAME \
    --project=$PROJECT \
    --subnet-mode=custom

# create GKE subnet
gcloud compute networks subnets create $GKE_SUBNET_NAME \
    --project=$PROJECT \
    --network=$NETWORK_NAME \
    --region=$REGION \
    --range=$GKE_IP_RANGE

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
    --project=$PROJECT \
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

# deploy test VM
gcloud beta compute instances create $TEST_VM_NAME \
    --project=$PROJECT \
    --zone=$VM_ZONE \
    --machine-type=n1-standard-1 \
    --subnet=$GKE_SUBNET_NAME \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --tags=allow-ssh \
    --async

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
    --subnetwork "projects/$PROJECT/regions/$REGION/subnetworks/$GKE_SUBNET_NAME" \
    --default-max-pods-per-node "110" \
    --no-enable-master-authorized-networks \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,ApplicationManager \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade 1 \
    --max-unavailable-upgrade 0 \
    --database-encryption-key "projects/$PROJECT/locations/$REGION/keyRings/$KEYRING_NAME/cryptoKeys/$KEY_NAME" \
    --identity-namespace "$PROJECT.svc.id.goog"


# Test if cluster was created
cluster=$(gcloud container clusters list --project=$PROJECT --format='value(NAME)' | grep $CLU_NAME)
if [ $cluster == $CLU_NAME ]
then
    echo "### Sucessfully deployed GKE cluster. ###"

    echo "Configure kubectl cmdline access..."
    gcloud container clusters get-credentials $CLU_NAME \
        --region $REGION \
        --project $PROJECT
    
    echo "Testing kubectl by showing cluster nodes..."
    kubectl get nodes

    echo "Creating namespace 'l7-ilb...'"
    kubectl create namespace l7-ilb
else
    echo "### Error. No cluster deployed. ###"
fi


# Building container images with Cloud Build
for i in 1 2 3
do
    container_name="CONTAINER_NAME_${i}"
    cd src/app$i/
    gcloud builds submit \
        --tag gcr.io/$PROJECT/$(echo "${!container_name}"):$CONTAINER_VERSION \
        --project=$PROJECT
    cd ../../

    container=$(gcloud container images list --project=$PROJECT --format='value(NAME)' | grep $(echo "${!container_name}"))

    if [ $container == "gcr.io/$PROJECT/$(echo "${!container_name}")" ]
    then
        echo "Sucessfully build container $i"
    else
        echo "Error building container $i"
    fi
done
