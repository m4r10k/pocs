# Deploy a private GKE with Traffic Director integration

# Description
Source files for the deployment of a GKE Cluster with 3 services which communicate with each other via the Traffic Director.

The network, Firewall rules, cluster and Traffic Director are deployed via gcloud (shell script).

The K8s deployments, services, ingress and L7 ILB are all via K8s resource manifest files.

This demo implementation is based on: https://cloud.google.com/traffic-director/docs/set-up-gke-pods



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
    kubectl apply -f service.yaml
    ```
* Now that we have our pods & services up and running we can continue with configuring the traffic director:
    ```
    ./create-td.sh -p [PROJECT_ID]
    ```


## Testing the deployment
* First we deploy a new pod running Busybox + an xDS API-compatible sidecare proxy (Istio/Envoy):
    ```
    kubectl apply -f td_client.yaml
    ```


# Get name of busybox pod
BUSYBOX_POD=$(kubectl get po -n td -l run=client -o=jsonpath='{.items[0].metadata.name}')

# Command to execute that tests connectivity to the service service-test.
TEST_CMD="wget -q -O - service-1; echo"

# Execute the test command on the pod.
kubectl exec -it $BUSYBOX_POD -n td -c busybox -- /bin/sh -c "$TEST_CMD"



# Error handling
If anything goes wrong ...
* make sure that all pre-requisites are full-filled: https://cloud.google.com/traffic-director/docs/setting-up-traffic-director
* Use the official docu to go through step by step: https://cloud.google.com/traffic-director/docs/set-up-gke-pods