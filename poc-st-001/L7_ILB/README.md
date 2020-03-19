# Deploy a private GKE cluster with L7 ILB access to services

# Description
Source files for the deployment of a GKE Cluster with 3 services which are accessible via the L7 ILB.

The network, Firewall rules and cluster are deployed via gcloud (shell script).

The K8s deployments, services, ingress and L7 ILB are all deployed declaratively via K8s resource manifest files.