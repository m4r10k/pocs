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

REGION1="europe-west3"
REGION2="europe-west3"
NETWORK_NAME="td-vpc"
GKE_SUBNET_NAME_1="td-subnet-w3"
GKE_SUBNET_NAME_2="td-subnet-w4"
GKE_IP_RANGE_1="10.11.0.0/20"
GKE_IP_RANGE_2="10.12.0.0/20"
FW_PREFIX="td-vpc"
GKE_MASTER_EXT_IP_1="172.16.1.0/28"
GKE_MASTER_EXT_IP_2="172.16.2.0/28"
CLU_NAME_1="td-cluster-w3"
CLU_NAME_1="td-cluster-w4"
CONTAINER_NAME_1="td-green"
CONTAINER_NAME_2="td-blue"
CONTAINER_NAME_3="td-red"
CONTAINER_VERSION="v1.0.1"
ROUTER_NAME_1="td-router-w3"
ROUTER_NAME_2="td-router-w4"
NAT_1="td-nat-w3"
NAT_2="td-nat-w4"
NAMESPACE="td"
SERVICE_PREFIX="service"

# Delete resources if -d was provided
if [ $DELETE == 1 ]; then
    # delete the cluster
    gcloud container clusters delete $CLU_NAME_1 \
        --project=$PROJECT \
        --region=$REGION1 \
        -q --async
    gcloud container clusters delete $CLU_NAME_2 \
        --project=$PROJECT \
        --region=$REGION2 \
        -q --async

    # delete the containers in the registry
    gcloud container images delete \
        gcr.io/$PROJECT/$CONTAINER_NAME_1:$CONTAINER_VERSION \
        --project $PROJECT -q
    gcloud container images delete \
        gcr.io/$PROJECT/$CONTAINER_NAME_2:$CONTAINER_VERSION \
        --project $PROJECT -q
    gcloud container images delete \
        gcr.io/$PROJECT/$CONTAINER_NAME_3:$CONTAINER_VERSION \
        --project $PROJECT -q


    # delete NEGs
    for neg in $(gcloud compute network-endpoint-groups list --project=$PROJECT --format="value(name)" --filter="zone:$REGION1-a" | grep "$NAMESPACE-$SERVICE_PREFIX")
    do
        echo $neg
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION1-a -q --project=$PROJECT
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION1-b -q --project=$PROJECT
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION1-c -q --project=$PROJECT
    done
    for neg in $(gcloud compute network-endpoint-groups list --project=$PROJECT --format="value(name)" --filter="zone:$REGION2-a" | grep "$NAMESPACE-$SERVICE_PREFIX")
    do
        echo $neg
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION2-a -q --project=$PROJECT
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION2-b -q --project=$PROJECT
        gcloud compute network-endpoint-groups delete $neg --zone=$REGION2-c -q --project=$PROJECT
    done

    # delete firewall rules
    gcloud compute firewall-rules delete $FW_PREFIX-fw-allow-ssh \
        --project=$PROJECT -q
    gcloud compute firewall-rules delete $FW_PREFIX-fw-allow-health-checks \
        --project=$PROJECT -q
    gcloud compute firewall-rules delete $FW_PREFIX-fw-http-rfc1918 \
        --project=$PROJECT -q

    # delete subnet and VPC
    while :
    do
        echo "Waiting for GKE clusters beeing deleted"
        clu1=$(gcloud container clusters list --project=$PROJECT --filter="NAME:$CLU_NAME_1" --format="value(name)")
        clu2=$(gcloud container clusters list --project=$PROJECT --filter="NAME:$CLU_NAME_2" --format="value(name)")

        if [ "$clu1" = "$CLU_NAME_1" ] || [ "$clu2" = "$CLU_NAME_2" ]
        then
            echo "Waiting..."
        else
            echo "Cluster have been deleted..."
            break
        fi
        sleep 15
    done

    # delete networking services
    gcloud compute routers nats delete $NAT_1 \
        --project=$PROJECT \
        --region=$REGION1 \
        --router=$ROUTER_NAME \
        -q
    gcloud compute routers nats delete $NAT_2 \
        --project=$PROJECT \
        --region=$REGION2 \
        --router=$ROUTER_NAME \
        -q
    gcloud compute routers delete $ROUTER_NAME_1 \
        --region=$REGION1 \
        --project=$PROJECT \
        -q
    gcloud compute routers delete $ROUTER_NAME_2 \
        --region=$REGION2 \
        --project=$PROJECT \
        -q
    gcloud compute networks subnets delete $GKE_SUBNET_NAME_1 \
        --project=$PROJECT \
        --region=$REGION1 \
        -q
    gcloud compute networks subnets delete $GKE_SUBNET_NAME_2 \
        --project=$PROJECT \
        --region=$REGION2 \
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
    trafficdirector.googleapis.com \
    --project=$PROJECT

# Enable the sidecar proxy to access the xDS-server 
# (trafficdirector.googleapis.com). The proxy uses for this
# the service account of the GKE node instance and that's why
# it needs the compute.networkViewer role.
SERVICE_ACCOUNT_EMAIL=`gcloud iam service-accounts list \
  --project=$PROJECT \
  --format='value(email)' \
  --filter='displayName:Compute Engine default service account'`
gcloud projects add-iam-policy-binding ${PROJECT} \
  --member serviceAccount:${SERVICE_ACCOUNT_EMAIL} \
  --role roles/compute.networkViewer


### NETWORKING
# create vpc
gcloud compute networks create $NETWORK_NAME \
    --project=$PROJECT \
    --subnet-mode=custom \
    --bgp-routing-mode=global

# create GKE subnet
gcloud compute networks subnets create $GKE_SUBNET_NAME_1 \
    --project=$PROJECT \
    --network=$NETWORK_NAME \
    --region=$REGION1 \
    --range=$GKE_IP_RANGE_1

gcloud compute networks subnets create $GKE_SUBNET_NAME_2 \
    --project=$PROJECT \
    --network=$NETWORK_NAME \
    --region=$REGION2 \
    --range=$GKE_IP_RANGE_2

# allow ssh access to any nodes in the gke subnet with "allow-ssh" tag
gcloud compute firewall-rules create $FW_PREFIX-fw-allow-ssh \
    --project=$PROJECT \
    --network=$NETWORK_NAME \
    --action=allow \
    --direction=ingress \
    --target-tags=allow-ssh \
    --rules=tcp:22

# allow health checks
gcloud compute firewall-rules create $FW_PREFIX-fw-allow-health-checks \
    --project=$PROJECT \
    --network $NETWORK_NAME \
    --action ALLOW \
    --direction INGRESS \
    --source-ranges 35.191.0.0/16,130.211.0.0/22 \
    --rules tcp

# allow RFC1918 traffic
gcloud compute firewall-rules create $FW_PREFIX-fw-http-rfc1918 \
    --project=$PROJECT \
    --network $NETWORK_NAME \
    --action ALLOW \
    --direction INGRESS \
    --source-ranges 10.0.0.0/8,192.168.0.0/16,172.16.0.0/16 \
    --rules tcp:80,tcp:8000


### Create GKE clusters
gcloud beta container clusters create $CLU_NAME_1 \
    --project $PROJECT \
    --region $REGION1 \
    --network $NETWORK_NAME \
    --subnetwork $GKE_SUBNET_NAME_1 \
    --scopes https://www.googleapis.com/auth/cloud-platform \
    --no-enable-basic-auth \
    --release-channel "regular" \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr $GKE_MASTER_EXT_IP_1 \
    --no-enable-master-authorized-networks \
    --num-nodes "2" \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,ApplicationManager \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade 1 \
    --max-unavailable-upgrade 0 \
    --enable-stackdriver-kubernetes

gcloud beta container clusters create $CLU_NAME_2 \
    --project $PROJECT \
    --region $REGION2 \
    --network $NETWORK_NAME \
    --subnetwork $GKE_SUBNET_NAME_2 \
    --scopes https://www.googleapis.com/auth/cloud-platform \
    --no-enable-basic-auth \
    --release-channel "regular" \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr $GKE_MASTER_EXT_IP_2 \
    --no-enable-master-authorized-networks \
    --num-nodes "2" \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,ApplicationManager \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade 1 \
    --max-unavailable-upgrade 0 \
    --enable-stackdriver-kubernetes

# Test if cluster was created
cluster1=$(gcloud container clusters list --project=$PROJECT --format='value(NAME)' | grep $CLU_NAME_1)
cluster2=$(gcloud container clusters list --project=$PROJECT --format='value(NAME)' | grep $CLU_NAME_2)
if [ $cluster1 == $CLU_NAME_1 ] && [ $cluster2 == $CLU_NAME_2 ]
then
    echo "### Sucessfully deployed GKE clusters. ###"

    gcloud container clusters get-credentials $CLU_NAME_1 \
        --region $REGION1 \
        --project $PROJECT
    
    echo "Testing kubectl by showing cluster nodes 1..."
    kubectl get nodes

    echo "Creating namespace 'td...'"
    kubectl create namespace $NAMESPACE

    gcloud container clusters get-credentials $CLU_NAME_2 \
        --region $REGION2 \
        --project $PROJECT
    
    echo "Testing kubectl by showing cluster nodes 1..."
    kubectl get nodes

    echo "Creating namespace 'td...'"
    kubectl create namespace $NAMESPACE

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

# Create a Cloud Router for NAT
gcloud compute routers create $ROUTER_NAME_1 \
    --project $PROJECT \
    --region=$REGION1 \
    --network=$NETWORK_NAME 
gcloud compute routers create $ROUTER_NAME_2 \
    --project $PROJECT \
    --region=$REGION2 \
    --network=$NETWORK_NAME 
    
# Enable Cloud NAT because we have a private cluster
gcloud compute routers nats create $NAT_1 \
    --router=$ROUTER_NAME_1 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --enable-logging \
	--region $REGION1 \
	--project $PROJECT
gcloud compute routers nats create $NAT_2 \
    --router=$ROUTER_NAME_2 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --enable-logging \
	--region $REGION2 \
	--project $PROJECT
