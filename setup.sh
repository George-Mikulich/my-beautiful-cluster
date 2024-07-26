#!/bin/bash


# possible issues & weakpoints:
# - export fullpath variable
# - argocd-cm configmap patched manually
# - maybe i need to specify argocd-cm settings while installing helm chart
# - if ingress_host variable is empty, sed will set ip address to empty line and regex will be useless
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

helm install \
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
        export fullpath="${answer:-../key.json}"
        kubectl create secret \
        generic gcp-secret \
        -n external-secrets \
        --from-file=creds=$fullpath
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
kubectl apply -f external-secrets-operator/crossplane-key.yaml -n crossplane-system


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

echo "Installing external secret operator"
helm repo add external-secrets \
    https://charts.external-secrets.io

helm repo update

helm install \
    external-secrets \
    external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace

kubectl create secret \
        generic gcp-secret \
        -n external-secrets \
        --from-file=creds=$fullpath

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

kubectl apply -f external-secrets-operator/secret-store.yaml
kubectl create namespace cert-manager
sleep 3
kubectl apply -f external-secrets-operator/dns-solver-key.yaml -n cert-manager
echo "------------------------------------------------"
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

# kubectl apply -f argocd/custom-cm.yaml  # okta server was deleted                                                   (what i could do: https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/values.yaml)
echo "you need to edit deployment manually."
echo "Add --insecure flag spec.template.spec.containers.args"
echo "It should look like this:"
echo "containers: 
- args: 
  - /usr/local/bin/argocd-server 
  - --port=8080 
  - --metrics-port=8083 
  - --insecure"
echo "sorry, there is no better way so far"
read -n1 -r -p "Press any key if you are ready..." key
kubectl edit deployment argocd-server -n argocd -o yaml
echo "------------------------------------------------"
echo "deploying apps through argocd"
helm install argocd-apps \
--namespace argocd \
argo/argocd-apps \
--version 2.0.0 \
--values argocd/app_of_apps.yaml
echo "------------------------------------------------"
echo "installing cert-manager"
helm repo add jetstack https://charts.jetstack.io --force-update
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.15.1 \
  --set crds.enabled=true
echo "waiting for cert-manager pods deployment..."
for (( ; ; ))
do
        sleep 1
        allPods=$(kubectl get pods -n cert-manager --no-headers | wc -l)
        runningPods=$(kubectl get pods -n cert-manager --no-headers | grep -P "(\d+)\/\1\s+Running" | wc -l)
        if [ $allPods == $runningPods ]
        then
                echo "cert-manager is ready"
                break
        fi
done

kubectl apply -f cert-manager/CIssuer.yaml
sleep 5
kubectl apply -f cert-manager/cert.yaml
sleep 3

kubectl apply -f argocd/gateway.yaml  #beautify????
kubectl apply -f argocd/vS.yaml
kubectl apply -f kiali/gateway.yaml
kubectl apply -f kiali/vS.yaml
echo "------------------------------------------------"
# database (PG) operator
helm install pgo oci://registry.developers.crunchydata.com/crunchydata/pgo \
 -n postgres-operator \
 --create-namespace
kubectl apply -f crunchy/cluster.yaml

# For UI
#
# read -r -p 'Create password for user hippo@example.com (default is admin): ' answer
# export PG_USER_PASSWORD="${answer:-admin}"
# kubectl create secret generic pgadmin-password-secret \
#   -n postgres-operator \
#   --from-literal=password=$PG_USER_PASSWORD
# kubectl apply -f crunchy/admin.yaml

kubectl apply -f crunchy/custom-psql-svc.yaml -n postgres-operator

echo "------------------------------------------------"
echo "waiting for istio ingress"
for (( ; ; ))
do
        sleep 1
        ingressIsRunning=$(kubectl get pods -n istio-system -l istio=ingressgateway --field-selector=status.phase=Running --no-headers | wc -l)
        if [ $ingressIsRunning == 1 ]
        then
                echo "Istio Ingress Gateway is ready"
                break
        fi
done
#?
export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "To create DNS records we need Istio Ingress address, so we couldn't have done it earlier"

kubectl config use-context gke_my-beautiful-cluster2_us-west1-c_default-my-beautiful-cluster2-gke
sleep 5
echo "IP address of Ingress: ${INGRESS_HOST}"
echo "creating DNS zone and A records"
sed -i "s/[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*/${INGRESS_HOST}/" crossplane/cluster/dns.yaml
kubectl apply -f crossplane/cluster/dns.yaml
echo "------------------------------------------------"

kubectl config use-context gke_my-beautiful-cluster2_us-west1-c_gke-crossplane-cluster
sleep 5

PGPASSWORD=$(kubectl get secrets -n postgres-operator "hippo-pguser-hippo" -o go-template='{{.data.password | base64decode}}')
kubectl create secret generic db-creds \
 --from-literal=user=hippo \
 --from-literal=password="$PGPASSWORD"

echo "-----------------------------"

kubectl create namespace control
sleep 5
kubectl apply -f test/control-depl.yaml
kubectl apply -f test/control-svc.yaml
kubectl apply -f test/control-gate.yaml
kubectl apply -f test/control-vS.yaml