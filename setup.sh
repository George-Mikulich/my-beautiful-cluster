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

echo "Installing external secret operator"
helm repo add external-secrets \
    https://charts.external-secrets.io

helm repo update

helm upgrade --install \
    external-secrets \
    external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace

echo "waiting for external-secrets pods deployment..."
for (( ; ; ))
do
        sleep 1
        allPods=$(kubectl get pods -n external-secrets --no-headers | wc -l)
        runningPods=$(kubectl get pods -n external-secrets --no-headers | grep -P "(\d+)\/\1\s+Running" | wc -l)
        if [ $allPods == $runningPods ]
        then
                echo "ESO is ready"
                break
        fi
done

echo "Credentials are needed for external secrets (all other secrets will be managed by ESO)"
for (( createSecretErrorCode=1; $createSecretErrorCode != 0 ; ))
do
        echo "Please specify full path to Service Account key (.json file)"
        read -r -p '(Default path is ../key.json): ' answer
        fpath="${answer:-../key.json}"
        kubectl create secret \
        generic gcp-secret \
        -n external-secrets \
        --from-file=creds=$fpath
        createSecretErrorCode=$?
        if [ $createSecretErrorCode != 0 ]
        then
                echo "There is no such file, try again"
                echo
        fi
done

sleep 3
kubectl apply -f external-secrets-operator/secret-store.yaml
sleep 3
kubectl apply -f external-secrets-operator/external-secret.yaml -n crossplane-system


echo "------------------------------------------------"
kubectl apply -f ./crossplane/provider.yaml
echo "installing crds..."
for (( ; ; ))
do
        sleep 1
        healthyProviders=$(kubectl describe provider | grep "Status:                True" | wc -l)
        if [ $healthyProviders == 10 ] # 5 for type:installed and 5 for type:healthy
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
echo "------------------------------------------------"
echo "deploying apps through argocd"
helm install argocd-apps \
--namespace argocd \
argo/argocd-apps \
--version 2.0.0 \
--values argocd/app_of_apps.yaml



