# Deploy a private GKE with Traffic Director integration

# Description
Source files for the deployment of a GKE Cluster with 3 services which communicate with each other via the Traffic Director.

The network, Firewall rules, cluster and Traffic Director are deployed via gcloud (shell script).

The K8s deployments, services, ingress and L7 ILB are all via K8s resource manifest files.