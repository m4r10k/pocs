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

REGION="europe-west3"
VM_ZONE="europe-west3-c"
USED_ZONES=( a b c )                        # multiple for regional clusters
SVC_NAMES=( service-1 service-2 service-3 ) # for multiple services
NETWORK_NAME="td-vpc"
GKE_SUBNET_NAME="td-subnet"
GKE_IP_RANGE="10.11.0.0/26"
CLU_NAME="td-cluster"
BACKEND_SVC="td-backend"
HEALTH_CHECK_NAME="td-gke-health-check"
URL_MAP="td-url-map"
PATH_MATCHER="td-path-matcher"
TARGET_HTTP_PROXY="td-proxy"
GLOBAL_FORWARDING_RULE="td-gke-forwarding-rule"
GLOBAL_FORWARDING_RULE_IP="0.0.0.0"
GLOBAL_FORWARDING_RULE_PORT="80"
GLOBAL_FORWARDING_RULE_LB_SCHEME="INTERNAL_SELF_MANAGED"

# Delete traffic director resources if -d was provided
if [ $DELETE == 1 ]; then
    # TD - delete forwarding rule
    gcloud compute forwarding-rules delete $GLOBAL_FORWARDING_RULE \
        --project=$PROJECT -q \
        --global

    # TD - delete target http proxy
    gcloud compute target-http-proxies delete $TARGET_HTTP_PROXY \
        --project=$PROJECT -q
    
    # TD - delete 
    # TD - delete URL maps
    gcloud compute url-maps delete $URL_MAP \
        --project=$PROJECT -q

    # TD - delete backend services
    for svc in "${SVC_NAMES[@]}"
    do
        gcloud compute backend-services delete $BACKEND_SVC-$svc \
            --project=$PROJECT -q --global
    done
    exit
fi

# [3b] create one health check used by all backend service.
# You can also create multiple health checks or 1 different check per service.
gcloud compute health-checks create http $HEALTH_CHECK_NAME \
    --project=$PROJECT \
    --use-serving-port

for svc in "${SVC_NAMES[@]}"
do
    # [3] create one backend service per GKE service
    gcloud compute backend-services create $BACKEND_SVC-$svc \
        --project=$PROJECT \
        --global \
        --health-checks $HEALTH_CHECK_NAME \
        --load-balancing-scheme INTERNAL_SELF_MANAGED

    # Get the Network Entpoint group NAME of the GKE service
    NEG_NAME=$(gcloud beta compute network-endpoint-groups list \
    --project=$PROJECT \
    --filter="zone:$REGION-a" \
    | grep td-$svc | awk '{print $1}')
    
     # [3a] Add all (3) NEGs (one per zone) as backends to the backend service
    for zone in "${USED_ZONES[@]}"
    do
        gcloud compute backend-services add-backend $BACKEND_SVC-$svc \
            --project=$PROJECT \
            --global \
            --network-endpoint-group $NEG_NAME \
            --network-endpoint-group-zone $REGION-$zone \
            --balancing-mode RATE \
            --max-rate-per-endpoint 5
    done

    echo "Deleted all traffic director resources."
done

# [2a] create only one ULR map that uses the first backend service as default
gcloud compute url-maps create $URL_MAP \
    --project=$PROJECT \
    --default-service $BACKEND_SVC-service-1     # change default later

# [2a-1] create the URL map path matcher for service x
gcloud compute url-maps add-path-matcher $URL_MAP \
    --project=$PROJECT \
    --default-service $BACKEND_SVC-service-1 \
    --backend-service-path-rules="/service-1/*=$BACKEND_SVC-service-1,/service-2/*=$BACKEND_SVC-service-2,/service-3/*=$BACKEND_SVC-service-3" \
    --path-matcher-name $PATH_MATCHER

# [2a-2] create the URL map host rule matcher for service x
gcloud compute url-maps add-host-rule $URL_MAP \
    --project=$PROJECT \
    --hosts service-1,service-2,service-3  \
    --path-matcher-name $PATH_MATCHER


# [2] create the target http proxy
gcloud compute target-http-proxies create $TARGET_HTTP_PROXY \
    --project=$PROJECT \
    --url-map $URL_MAP

# [1] create the forwarding rule
gcloud compute forwarding-rules create $GLOBAL_FORWARDING_RULE \
    --project=$PROJECT \
    --global \
    --load-balancing-scheme=$GLOBAL_FORWARDING_RULE_LB_SCHEME \
    --address=$GLOBAL_FORWARDING_RULE_IP \
    --target-http-proxy=$TARGET_HTTP_PROXY \
    --ports $GLOBAL_FORWARDING_RULE_PORT \
    --network $NETWORK_NAME

# Traffic Director is configured to load balance traffic for the services specified in the URL map across backends in the network endpoint group.
