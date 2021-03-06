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

REGIONS=( "europe-west3" "europe-west4" )
USED_ZONES=( a b c )                        # multiple for regional clusters
SVC_NAMES=( service1 service2 service3 )    # for multiple services
NETWORK_NAME="td-vpc"
BACKEND_SVC="td-backend"
HEALTH_CHECK_NAME="td-health-check"
URL_MAP="td-url-map"
URL_MAP_IP="td-url-map-ip"
PATH_MATCHER="td-path-matcher"
TARGET_HTTP_PROXY="td-proxy"
TARGET_HTTP_PROXY_IP="td-proxy-ip"
GLOBAL_FORWARDING_RULE="td-forwarding-rule"
GLOBAL_FORWARDING_RULE_IP="td-forwarding-rule-ip"
GLOBAL_FORWARDING_RULE_ADDR="0.0.0.0"
GLOBAL_FORWARDING_RULE_ADDR_IP="10.99.1.1"
GLOBAL_FORWARDING_RULE_PORT="80"
GLOBAL_FORWARDING_RULE_LB_SCHEME="INTERNAL_SELF_MANAGED"

# Delete traffic director resources if -d was provided
if [ $DELETE == 1 ]; then
    echo "########## Start deleting Traffic Director resources ##########"
    # TD - delete forwarding rule
    gcloud compute forwarding-rules delete $GLOBAL_FORWARDING_RULE \
        --project=$PROJECT -q \
        --global
    gcloud compute forwarding-rules delete $GLOBAL_FORWARDING_RULE_IP \
        --project=$PROJECT -q \
        --global

    # TD - delete target http proxy
    gcloud compute target-http-proxies delete $TARGET_HTTP_PROXY \
        --project=$PROJECT -q
    gcloud compute target-http-proxies delete $TARGET_HTTP_PROXY_IP \
        --project=$PROJECT -q
    
    # TD - delete URL maps
    gcloud compute url-maps delete $URL_MAP \
        --project=$PROJECT -q
    gcloud compute url-maps delete $URL_MAP_IP \
        --project=$PROJECT -q

    # TD - delete backend services
    for svc in "${SVC_NAMES[@]}"
    do
        gcloud compute backend-services delete $BACKEND_SVC-$svc \
            --project=$PROJECT -q --global
    done

    # TD - delete health check
    gcloud compute health-checks delete $HEALTH_CHECK_NAME \
        --project=$PROJECT -q

    echo "Deleted all traffic director resources."
    exit
fi

# [3b] create one health check used by all backend service.
# You can also create multiple health checks or 1 different check per service.
echo "########## Creating HTTP health check ##########"
gcloud compute health-checks create http $HEALTH_CHECK_NAME \
    --project=$PROJECT \
    --check-interval=4s \
    --timeout=4s \
    --healthy-threshold=2 \
    --unhealthy-threshold=4 \
    --request-path="/" \
    --use-serving-port

echo "########## Creating TD Backend services and linking them to NEGs ##########"
for svc in "${SVC_NAMES[@]}"
do
    # [3] create one multi-regional & multi-zonal backend service per GKE service
    gcloud compute backend-services create $BACKEND_SVC-$svc \
        --project=$PROJECT \
        --network=$NETWORK_NAME \
        --global \
        --health-checks $HEALTH_CHECK_NAME \
        --load-balancing-scheme INTERNAL_SELF_MANAGED
    
    for REGION in "${REGIONS[@]}"
    do
        # Get the Network Entpoint group NAME of the GKE service
        NEG_NAME=$(gcloud beta compute network-endpoint-groups list \
        --project=$PROJECT \
        --filter="zone:$REGION-a" \
        | grep td-$svc | awk '{print $1}')
        echo "NEG name: $NEG_NAME"
        
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
    done
done

# [2a] create ULR map based on yaml file. First we need to replace the [PROJECT_ID] and [URL_MAP_NAME]
sed 's/PROJECT_ID/'$PROJECT'/g' urlmap1_template.yaml > urlmap1.yaml
sed -i 's/URL_MAP_NAME/'$URL_MAP'/g' urlmap1.yaml
sed 's/PROJECT_ID/'$PROJECT'/g' urlmapip_template.yaml > urlmapip.yaml
sed -i 's/URL_MAP_NAME/'$URL_MAP_IP'/g' urlmapip.yaml
sed 's/PROJECT_ID/'$PROJECT'/g' urlmap2_template.yaml > urlmap2.yaml
sed -i 's/URL_MAP_NAME/'$URL_MAP'/g' urlmap2.yaml

gcloud compute url-maps import $URL_MAP \
    --project=$PROJECT \
    --source=urlmap1.yaml -q

gcloud compute url-maps import $URL_MAP_IP \
    --project=$PROJECT \
    --source=urlmapip.yaml -q

# [2] create the target http proxy
gcloud compute target-http-proxies create $TARGET_HTTP_PROXY \
    --project=$PROJECT \
    --url-map $URL_MAP

gcloud compute target-http-proxies create $TARGET_HTTP_PROXY_IP \
    --project=$PROJECT \
    --url-map $URL_MAP_IP

# [1] create the forwarding rule
gcloud compute forwarding-rules create $GLOBAL_FORWARDING_RULE \
    --project=$PROJECT \
    --global \
    --load-balancing-scheme=$GLOBAL_FORWARDING_RULE_LB_SCHEME \
    --address $GLOBAL_FORWARDING_RULE_ADDR \
    --target-http-proxy $TARGET_HTTP_PROXY \
    --ports $GLOBAL_FORWARDING_RULE_PORT \
    --network $NETWORK_NAME
gcloud compute forwarding-rules create $GLOBAL_FORWARDING_RULE_IP \
    --project=$PROJECT \
    --global \
    --load-balancing-scheme=$GLOBAL_FORWARDING_RULE_LB_SCHEME \
    --address $GLOBAL_FORWARDING_RULE_ADDR_IP \
    --target-http-proxy $TARGET_HTTP_PROXY_IP \
    --ports $GLOBAL_FORWARDING_RULE_PORT \
    --network $NETWORK_NAME

# Traffic Director is configured to load balance traffic for the services specified in the URL map across backends in the network endpoint group.
