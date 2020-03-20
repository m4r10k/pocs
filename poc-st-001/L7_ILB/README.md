# Deploy a private GKE cluster with L7 ILB access to services

## Description
This folder deploys a GKE Cluster with 3 services which are accessible via the **GKE L7 ILB**. All services are accessible via the same IP and PORT, but via different URL paths. In addition to a path-based routing service-2 and service-3 are configured with **Session Affinity**.

The network, Firewall rules and cluster are deployed via gcloud (shell script).

The K8s deployments, backend-config, services, ingress and L7 ILB are all deployed declaratively via K8s resource manifest files.

## Install instructions

* Open the command line, make sure gcloud is installed and authenticate yourself with gcloud auth login
* Change the PROJECT Env var in install.sh
* Run the following
    ```
    ./install.sh -p [PROJECT_ID]
    ```
    This should take about 5-10 minutes to create.
    Afterwards you can start deploying to your new cluster...
    ```
    kubectl apply -f deployment.yaml
    kubectl apply -f backendconfig.yaml
    kubectl apply -f service.yaml
    kubectl apply -f ingress.yaml
    ```
* Wait for a a few minutes until the ILB is successfully deployed. Once the following command returns an IP address you can proceed:
    ```
    LB_IP=$(kubectl get ingress --namespace=l7-ilb -o jsonpath="{.items[0].status.loadBalancer.ingress[0].ip}")
    echo $LB_IP
    ```

## Explore our deployment
Before we test the deployment let's have a look what actually happened:
1) Go to console.cloud.gogole.com
2) Have a look at Kubernetes Engine "Workloads" and "Service & Ingress" page
3) Have a look at the 12 automatically created NEGs at Compute Engine / Network Endpoint Groups
4) Go to Networking Services/Load Balancing and have a look at the load balancer which contains "...ilb-l7-ilb-ingress...". You can see the Global Forwarding Rules (Frontend), Target http proxy (url maps with host and path rules), and the backend services with the Traffic policies.
5) In the backend services you can see/change
   * Session affinity
   * Connection draining timeout
   * Load balancing policy
   * Circuit braking
   * Oulier detection
6) At this point in time (march 2020) you can't add routing actions (traffic splitting, mirroring, fault injection, header transformations, etc.) to the target http proxy yet (only rules)


## Testing our deployment
* SSH into our Test-vm
    ```
    # ssh into VM
    gcloud compute ssh l7-ilb-test-vm \
        --project=[PROJECT] \
        --zone=europe-west3-c
    ```
* Now simply call the different services via curl (replace the IP with the LB_IP we've extracted above):
    ```
    curl [IP]
    curl [IP]/service1
    curl [IP]/service2
    curl [IP]/service3
    ```
    You can see that the host & path rules of the target http proxy work as expected and route the traffic to the correct service. 

* Now let's test check if our backendconfig.yaml was applied correctly. You might have noticed in the backendconfig.yaml that I've configured IP-based session affinity for service 2 and cookie-based affinity for service 3. If you call service-2 multiple times with curl you will see that it returns always the same hostname, which means we always get routed to the same pod:
    ```
    for i in 1 2 3 4 5 6 7 8 9; do
        curl [IP]/service2
        echo ""
    done
    ```

    But if you call service-3 multiple times with curl you will still see an iterating hostname, which means we get still routed to different pods: 

    ```
    for i in {1..10}; do
        curl [IP]/service3
        echo ""
    done
    ```

    Why? Because we are sending curl commands without any cookies! 
 
    To test it correctly let's send a new curl request and print the cookie value the L7 ILB returns:

    ```
    curl -c - [IP]/service3
    ```

    You'll see that the Name of the cookie is GCILB and the value a random string. If we send this cookie now with our following requests, then we should always get routed to the same pod:

    ```
    for i in {1..15}; do
        curl --cookie "GCILB=[COOKIE VALUE]" [IP]/service3
        echo ""
    done
    ```

## Changing the code
If you want to update the source code of one of the 3 services proceed as following:
1) open and change the code, e.g. in src/app1/main.go
2) Open the deployment.yaml file and change the container image version of the deployment you want to update. Eg.: from v1.0.0 to v1.1.0
3) build a new container image version and push it to the registry
   ```
   cd src/app1/
   gcloud builds submit --tag gcr.io/[PROJECT_ID]/[CONTAINER_NAME]:[VERSION]--project=[PROJECT_ID]

   # Example:
   gcloud builds submit --tag gcr.io/hewagner-demos-2/hello-go-green:v1.1.0 --project=hewagner-demos-2
   ```
4) Apply your deployment.yaml file:
   ```
   kubectl apply -f deployment.yaml
   ```

## Clean up your project
After you are done testing and exploring you can clean up your project again with the -d flag:
```
./install.sh -p [PROJECT_ID] -d
```