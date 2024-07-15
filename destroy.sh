#!/bin/bash

#no set -e, bucket will not be destroyed

gcloud container clusters get-credentials default-my-beautiful-cluster2-gke --zone us-west1-c
sleep 5
kubectl delete -f crossplane/cluster/dns.yaml
kubectl delete nodepool gke-crossplane-np
kubectl delete cluster gke-crossplane-cluster
terraform destroy