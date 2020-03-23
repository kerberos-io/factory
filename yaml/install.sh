# -----------------
# Setup k8s factory

kubectl create -f ./clusterrole.yaml

kubectl create serviceaccount tiller --namespace kube-system
kubectl create -f ./tiller-clusterrolebinding.yaml
helm init --service-account tiller

helm install --name traefik -f ./traefik/values.yaml stable/traefik
helm install --name mongodb stable/mongodb --values ./mongodb/values.yaml
kubectl apply -f ./factory/kubernetes.yaml
