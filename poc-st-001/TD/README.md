# Deploy a private GKE with Traffic Director integration

## Description
Source files for the deployment of a GKE Cluster with 3 services which communicate with each other via the Traffic Director.

The network, Firewall rules, cluster and Traffic Director are deployed via gcloud (shell script).

The K8s deployments, services, ingress and L7 ILB are all via K8s resource manifest files.

This demo implementation is based on: https://cloud.google.com/traffic-director/docs/set-up-gke-pods


## How Traffic Director works
The diagram below shows how the TD components "Global forwarding rule", "Target HTTP Proxy" and "Backend Services" work together with Network Enpoint groups and Kubernetes deployments in regional GKE clusters:
![TD overview](./image/TD_overview.png)


## Demo Architecture
The diagram below shows the architecture we build in this demo:
...

## Install instructions
### Set up networking, GKE clusters and build containers
* Open the command line, make sure gcloud is installed and authenticate yourself with gcloud auth login
* Create a project env var and set it to your project id
    ```bash
    PROJECT_ID=[your prj id]
    ```
* Run the following script
    ```bash
    ./install.sh -p $PROJECT_ID
    ```
    This should take about 5-10 minutes to create.
* Before we start deploying the services to the clusters, first fetch the cluster config into env vars:
    ```bash
    gcloud container clusters get-credentials td-cluster-w3 --region europe-west3 --project $PROJECT_ID
    WEST3=`kubectl config current-context`
    gcloud container clusters get-credentials td-cluster-w4 --region europe-west4 --project $PROJECT_ID
    WEST4=`kubectl config current-context`
    ```


### Deploy the micro services
* First let's replace the PROJECT_ID in the manifest files with our Project ID
    ```bash
    sed 's/PROJECT_ID/'$PROJECT_ID'/g' k8s/app1-template.yaml > k8s/app1.yaml
    sed 's/PROJECT_ID/'$PROJECT_ID'/g' k8s/app2-template.yaml > k8s/app2.yaml
    sed 's/PROJECT_ID/'$PROJECT_ID'/g' k8s/app3-template.yaml > k8s/app3.yaml
    ```
* Now we can deploy the microservices in our 2 regional GKE cluster
    ```bash
    kubectl apply -f k8s/app1.yaml --cluster $WEST3
    kubectl apply -f k8s/app2.yaml --cluster $WEST3
    kubectl apply -f k8s/app3.yaml --cluster $WEST3
    kubectl apply -f k8s/app1.yaml --cluster $WEST4
    kubectl apply -f k8s/app2.yaml --cluster $WEST4
    kubectl apply -f k8s/app3.yaml --cluster $WEST4
    ```
* This will install the services 1, 2 & 3 on both GKE clusters. The deployment for each service has 3 replicas, which will be spread over 3 different zones.
* Each pod consists of a container running the code + a sidecar container used as proxy for all communication with the pod.
* The neg annotation in the service manifest triggers the creation of Network endpoint groups on GCP. These NEGs are directly connected to the pods and will be used by Traffic Director. 
* Service1 communicates with service2 and service2 with service3


### Deploy the Traffic Director
* Now that we have our pods & services up and running we can continue with configuring the traffic director:
    ```bash
    ./create-td.sh -p $PROJECT_ID
    ```
* This creates all resources needed for TD. Have a look at the **create-td.sh** file to learn how it works.


## Testing the deployment
We will test our application in multiple ways. Let's start simple by testing if the L7 routing works:

### Test L7 routing & traffic splitting
* For this we deploy a new pod who is running "Busybox" + an xDS API-compatible sidecare proxy (Istio/Envoy) in one cluster:
    ```bash
    kubectl apply -f k8s/td_client.yaml --cluster=$WEST3

    # Get name of busybox pod
    BUSYBOX_POD1=$(kubectl get po -n td -l run=client -o=jsonpath='{.items[0].metadata.name}' --cluster=$WEST3)
    ```
* Now let's call the host "test.com" (defined in the urlmap1.yaml file) multiple times. We should see that the requests are splitted betwenn app1 and app2:
    ```bash
    # Command to execute that tests connectivity to the service service-test.
    TEST_CMD="wget -q -O - test.com; echo;"

    # Execute the test command on the pod.
    for i in {1..10}; do kubectl exec -it $BUSYBOX_POD1 -n td --cluster=$WEST3 -c busybox -- /bin/sh -c "$TEST_CMD"; done
    ```
    The reply should look something like this:
    ```bash
    ...App 1; hostname: app1-75c66f86cb-7zvlj...
    ...App 2; hostname: app2-78b8ff9498-wsmmj...
    ...App 1; hostname: app1-75c66f86cb-7zvlj...
    ...App 2; hostname: app2-78b8ff9498-wsmmj...
    ...App 1; hostname: app1-75c66f86cb-7zvlj...
    ```
* While we've configured the root path (test.com/) to split traffic, the paths /service1, /service2 & /service3 are configured to route to the pods of the corresponding services. TD will automatically route the requests to the pods with the lowest latency. So if load on a particular zone/region is not too high, requests close to the zone/region will be handeled always by the same pods (closest). If we for example call the /service2 from our busybox, the requests will always be handeled by the pod(s) in the same zone as busybox is running.
    ```bash
    # Command to execute that tests connectivity to the service service-test.
    TEST_CMD="wget -q -O - test.com/service2; echo;"

    # Execute the test command on the pod.
    for i in {1..10}; do kubectl exec -it $BUSYBOX_POD1 -n td --cluster=$WEST3 -c busybox -- /bin/sh -c "$TEST_CMD"; done
    ```
    The reply should look something like this:
    ```bash
    ...App 2; hostname: app2-78b8ff9498-wsmmj...
    ...App 2; hostname: app2-78b8ff9498-wsmmj...
    ```
    If we deploy a second busybox on the other cluster in europe-west4, our requests get answered by a pod in the west4 region:
    ```bash
    kubectl apply -f k8s/td_client.yaml --cluster=$WEST4
    BUSYBOX_POD2=$(kubectl get po -n td -l run=client -o=jsonpath='{.items[0].metadata.name}' --cluster=$WEST4)
    TEST_CMD="wget -q -O - test.com/service2; echo;"
    for i in {1..10}; do kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"; done
    ```
    Now the reply should look something like this (you can see the last 5 characters for the pod are different):
    ```bash
    ...App 2; hostname: app2-78b8ff9498-47b5w...
    ...App 2; hostname: app2-78b8ff9498-47b5w...
    ```
    If west4 is down (we delete our deployment there) the requests will automatically be routed to west3:
    ```bash
    kubectl delete deployment app2 -n td --cluster $WEST4
    sleep 30
    for i in {1..10}; do kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"; done
    kubectl apply -f k8s/app2.yaml --cluster $WEST4
    ```
### VIP-based routing

In the wget request above we've always used the hostname "test.com" which was resolved to the pod IP address by the Traffic director. For this we specified the address 0.0.0.0 when creating the forwarding rule in "create-td.sh" file. But you might have noticed that we also created one forwarding rule with the Virtual IP (VIP) 10.99.1.1. So in case we don't want (or can) use hostnames for our requests we can also use VIPs. In our case here the service3 is exposed behind the VIP 10.99.1.1. But if you request 10.99.1.1/service2 you will be routed to service2. Have a closer look at the urlmapip.yaml file for details.

    ```bash
    TEST_CMD="wget -q -O - 10.99.1.1; echo;"
    kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"

    TEST_CMD="wget -q -O - 10.99.1.1/service1; echo;"
    kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"

    TEST_CMD="wget -q -O - 10.99.1.1/service2; echo;"
    kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"

    TEST_CMD="wget -q -O - 10.99.1.1/blablabla; echo;"
    kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"
    ```

### Advanced traffic routing

* Now let's simulate that 30% of traffic to service 3 is delayed by 3 seconds and that another 30% of the traffic is responded by 503 http errors. For this we need to change the urlmap:

    ```bash
    gcloud compute url-maps import td-url-map --project=$PROJECT_ID --source=urlmap2.yaml -q
    TEST_CMD="wget -q -O - test.com/service3; echo;"
    for i in {1..15}; do kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"; done
    ```
    You can see that some requests result in a "503 Service unavailable" and others in a delayed response.

### Traffic steering based on http headers (cookie)
* Now we send a request again to test.com. We did this already at the beginning and saw that traffic was splittet between app 1 (70%) and app 2 (30%). But this time we include a cookie header field named "dogfood":
    ```bash
    TEST_CMD="wget --header="Cookie:dogfood=true" -q -O - test.com; echo;"
    for i in {1..5}; do kubectl exec -it $BUSYBOX_POD2 -n td --cluster=$WEST4 -c busybox -- /bin/sh -c "$TEST_CMD"; done
    ```
    We can see that all traffic is redirected to app 3. In this case we can steer the traffic based on HTTP header information. Have a look at the urlmap2.yaml file to see how it works.
    

## Fast install + quick test
```bash
PROJECT_ID=[your project ID]
./install.sh -p $PROJECT_ID

gcloud container clusters get-credentials td-cluster-w3 --region europe-west3 --project $PROJECT_ID
WEST3=`kubectl config current-context`
gcloud container clusters get-credentials td-cluster-w4 --region europe-west4 --project $PROJECT_ID
WEST4=`kubectl config current-context`

sed 's/PROJECT_ID/'$PROJECT_ID'/g' k8s/app1-template.yaml > k8s/app1.yaml
sed 's/PROJECT_ID/'$PROJECT_ID'/g' k8s/app2-template.yaml > k8s/app2.yaml
sed 's/PROJECT_ID/'$PROJECT_ID'/g' k8s/app3-template.yaml > k8s/app3.yaml
kubectl apply -f k8s/app1.yaml --cluster $WEST3
kubectl apply -f k8s/app2.yaml --cluster $WEST3
kubectl apply -f k8s/app3.yaml --cluster $WEST3
kubectl apply -f k8s/app1.yaml --cluster $WEST4
kubectl apply -f k8s/app2.yaml --cluster $WEST4
kubectl apply -f k8s/app3.yaml --cluster $WEST4
kubectl apply -f td_client.yaml --cluster $WEST3
sleep 15
./create-td.sh -p $PROJECT_ID
sleep 15

kubectl exec -it $(kubectl get po -n td -l run=client -o=jsonpath='{.items[0].metadata.name}' --cluster=$WEST3) --cluster=$WEST3 -n td -c busybox -- /bin/sh -c 'wget -q -O - test.com/service2'; echo
```

## Error handling
If anything goes wrong ...
* make sure that all pre-requisites are full-filled: https://cloud.google.com/traffic-director/docs/setting-up-traffic-director
* Use the official docu to go through step by step: https://cloud.google.com/traffic-director/docs/set-up-gke-pods


## Clean Up
./create-td.sh -p hewagner-demos-2 -d
kubectl delete svc service1 service2 service3 -n td
kubectl delete deployment app10 app20 app30 client -n td
./install.sh -p hewagner-demos-2 -d


