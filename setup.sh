#!/bin/bash


# possible issues:
# - folders order
# - service account (it was created manually)
#
# TODO:
# provide credentials in file gcp-credentials.json
# to current directory and delete it after completion;
# alternatively, specify your path to credentials (line 44)

#set -e

gcloud container clusters get-credentials default-my-beautiful-cluster2-gke --zone us-west1-c
sleep 5

helm repo add \
crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane \
--version 1.15.0

echo "------------------------------------------------"
echo "waiting for crossplane-system pods deployment..."
for (( ; ; ))
do
        sleep 1
        allPods=$(kubectl get pods -n crossplane-system --no-headers | wc -l)
        runningPods=$(kubectl get pods -n crossplane-system --no-headers | grep -P "(\d+)\/\1\s+Running" | wc -l)
        if [ $allPods == $runningPods ]
        then
                echo "all pods are ready"
                break
        fi
done
echo "------------------------------------------------"

kubectl apply -f ./crossplane/provider.yaml

kubectl create secret \
generic gcp-secret \
-n crossplane-system \
--from-file=creds=../gcp-credentials.json

echo "------------------------------------------------"
echo "installing crds..."
for (( ; ; ))
do
        sleep 1
        healthyProviders=$(kubectl describe provider | grep "Status:                True" | wc -l)
        if [ $healthyProviders == 8 ] # 4 for type:installed and 4 for type:healthy
        then
                echo "all providers are healthy, crds are installed"
                break
        fi
done
echo "------------------------------------------------"

kubectl apply -f ./crossplane/provider-config.yaml
sleep 3

echo "creating new gke cluster..."
kubectl apply -f crossplane/cluster/gke.yaml
echo "the process of getting ready takes approximately 10 minutes"
for (( ; ; ))
do
        sleep 1
        statusIsTrue=$(kubectl describe cluster | grep "Status:                True" | wc -l)
        if [ $statusIsTrue == 3 ] # 1 for each of: Ready, Synced, LastAsyncOperation
        then
                echo "cluster is ready"
                break
        fi
done

echo "------------------------------------------------"
echo "writing cluster endpoint to local kubeconfig file"
gcloud container clusters get-credentials gke-crossplane-cluster --zone us-west1-c
sleep 5
echo "------------------------------------------------"
echo "now setting up crossplane-created cluster:"
echo "installing argocd"
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd \
--namespace argocd \
--create-namespace argo/argo-cd \
--version 7.1.1
echo "waiting for argocd-server deployment"
for (( ; ; ))
do
        sleep 1
        serverIsRunning=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server | grep -P "(\d+)\/\1\s+Running" | wc -l)
        if [ $serverIsRunning == 1 ]
        then
                echo "argocd server is ready"
                break
        fi
done