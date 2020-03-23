<h3 style="color:red">Work in progress...</h3>

# End to end Traffic Director + L7 ILB demo

## Description
This demo deploys an architecture as shown below:

![Architecture](./image/TD_overview.png)


* The network, Firewall rules, cluster and Traffic Director are deployed via gcloud (shell script).

* The K8s deployments, services, ingress and L7 ILB are all via K8s resource manifest files.


## Before you get started
...you might want have a look at the sample code in [L7-ILB demo](../L7_ILB) and [TD demo](../TD) as understanding those two example deployments build the base for this demo and I will not re-iterate on the basic concepts here.


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

## Clean Up
```bash
./create-td.sh -p $PROJECT_ID -d
./install.sh -p $PROJECT_ID -d
```

