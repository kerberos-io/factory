# Kerberos Factory on Kubernetes

As described in the `README.md` of this repository. Kerberos Factory runs on kubernetes to leverage the resilience and auto-scaling. It allows Kerberos Agents to be deployed in a kubernetes cluster without the management and complexity of creating kubernetes resources files.

## Managed Kubernetes vs Self-hosted Kubernetes

Just like `docker`, you bring your Kubernetes cluster where you want `edge` or `cloud`; private or public. Depending where you will host and how (e.g. managed Kubernetes cluster vs self-hosted) you'll have less/more responsibilities and/or control. Where and how is totally up to you, and your company preferences.

This installation guide will slighy modify depending on if you are self-hosting or leveraging a managed Kubernetes service by a cloud provider. Within a self-hosted installation you'll be required to install specific Kubernetes resources yourself, such as persistent volumes, storage and a load baluancer.

![Kerberos Factory deployments](assets/kerberosfactory-deployments.svg)

### A. Self-hosted Kubernetes

1. [Prerequisites](#prerequisites-1)
2. [Container Engine](#container-engine)
3. [Kubernetes](#kubernetes)
4. [Untaint all nodes](#untaint-all-nodes)
5. [Calico](#calico)
6. [Introduction](#introduction-1)
7. [Kerberos Factory](#kerberos-factory-1)
8. [MetalLB](#metallb)
9. [OpenEBS](#openebs)
10. [Proceed with managed Kubernetes](#proceed-with-managed-kubernetes)

### B. Managed Kubernetes

1. [Prerequisites](#prerequisites)
2. [Introduction](#introduction)
3. [Kerberos Factory](#kerberos-factory)
4. [Namespace](#namespace)
5. [Helm](#helm)
6. [Traefik](#traefik)
7. [Ingress-Nginx (alternative for Traefik)](#ingress-nginx-alternative-for-traefik)
8. [MongoDB](#mongodb)
9. [Config Map](#config-map)
10. [Deployment](#deployment)
11. [Test out configuration](#test-out-configuration)
12. [Access the system](#access-the-system)

## A. Self-hosted Kubernetes

To simplify the installation we will start with the most common setup, where we will install Kerberos Factory on a self-hosted Kubernetes services.

In most cases you will require to host your Kerberos Factory (and Kerberos Agents) very close to your cameras, to improve latency and efficency. However it's perfect possible to host a managed Kubernetes cluster, and connect to remote cameras through a secured connection (VPN).

The good things is that installation of a self-hosted Kubernetes cluster, contains the same steps as a managed Kubernetes installation with a few extra resources on top. Let's start with setting up our self-hosted Kubernetes machine; if you already have a cluster setup you might [skip the Kubernetes installation](#calico), or if you are running a managed Kubernetes you can jump to [B. Managed Kubernetes directly](#b-managed-kubernetes-1).

### Prerequisites

We'll assume you have a blank Ubuntu 20.04 / 22.04 LTS machine (or multiple machines/nodes) at your posession. We'll start with updating the Ubuntu operating system.

    apt-get update -y && apt-get upgrade -y

### Container Engine

    export OS_VERSION_ID=xUbuntu_$(cat /etc/os-release | grep VERSION_ID | awk -F"=" '{print $2}' | tr -d '"')
    export CRIO_VERSION=1.25

Add repositories

    echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS_VERSION_ID/ /"|sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
    echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS_VERSION_ID/ /"|sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list
    curl -L https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION/$OS_VERSION_ID/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
    curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS_VERSION_ID/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -

Update package index and install crio:

    apt-get update
    apt-get install cri-o cri-o-runc cri-tools -y

Enable and start crio:

    systemctl daemon-reload
    systemctl enable crio --now

### Kubernetes

After Container Engine being installed go ahead and install the different Kubernetes servicess and tools.

    apt update -y
    apt-gt install -y apt-transport-https ca-certificates curl
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

    apt-get update
    apt-get install -y kubelet kubeadm kubectl

Hold these packages to prevent unintentional updates:

    apt-mark hold kubelet kubeadm kubectl

Make sure you disable swap, this is required by Kubernetes.

    swapoff -a

And if you want to make it permanent after every boot.

    sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

**_Special note_**: If you already had Kubernetes installed, make sure you are running latest version and/or have properly cleaned up previous installation.

    kubeadm reset
    rm -rf $HOME/.kube

Initiate a new Kubernetes cluster using following command. This will use the current CIDR. If you want to use another CIDR, specify following arguments: `--pod-network-cidr=10.244.0.0/16`.

    kubeadm init

Once successful you should see the following. Note the `discovery token` which you need to use to connect additional nodes to your cluster.

    Your Kubernetes control-plane has initialized successfully!

    To start using your cluster, you need to run the following as a regular user:

      mkdir -p $HOME/.kube
      sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
      sudo chown $(id -u):$(id -g) $HOME/.kube/config

    You should now deploy a pod network to the cluster.
    Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
      https://kubernetes.io/docs/concepts/cluster-administration/addons/

    Then you can join any number of worker nodes by running the following on each as root:

    kubeadm join 192.168.1.103:6443 --token ej7ckt.uof7o2iplqf0r2up \
        --discovery-token-ca-cert-hash sha256:9cbcc00d34be2dbd605174802d9e52fbcdd617324c237bf58767b369fa586209

Now we have a Kubernetes cluster, we need to make sure we add make it available in our `kubeconfig`. This will allow us to query our Kubernetes cluster with the `kubectl` command.

    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

### Untaint all nodes

By default, and in this example, we only have one node our master node. In a production scenario we would have additional worker nodes. By default the master nodes are marked as `tainted`, this means they cannot run workloads. To allow master nodes to run workloads, we need to untaint them. If we wouldn't do this our pods would never be scheduled, as we do not have worker nodes at this moment.

    kubectl taint nodes <your_node_name> node-role.kubernetes.io/control-plane-

### Calico

Calico is an open source networking and network security solution for containers, virtual machines, and native host-based workloads. (https://www.projectcalico.org/). We will use it as our network layer in our Kubernetes cluster. You could use otthers like Flannel aswell, but we prefer Calico.

    curl https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml -O
    kubectl apply -f calico.yaml

### Introduction

As you might have read in the `A. Managed Kubernetes` section, Kerberos Factory requires some initial components to be installed.

- Helm
- MongoDB
- Traefik (or alternatively Nginx ingress)

However for a self-hosted cluster, we'll need following components on top:

- MetalLB
- OpenEBS

For simplicity we'll start with the installation of `MetalLB` and `OpenEBS`. Afterwards we'll move back to the `A. Managed Kubernetes` section, to install the remaining components.

### Kerberos Factory

We'll start by cloning the configurations from our [Github repo](https://github.com/kerberos-io/factory). This repo contains all the relevant configuration files required.

    git clone https://github.com/kerberos-io/factory

Make sure to change directory to the `kubernetes` folder.

    cd factory/kubernetes

### MetalLB

In a self-hosted scenario, we do not have fancy Load balancers and Public IPs from which we can "automatically" benefit. To overcome thism, solutions such as MetalLB - Baremetal Load Balancer - have been developed (https://metallb.universe.tf/installation/). MetalLB will dedicate an internal IP address, or IP range, which will be assigned to one or more Load Balancers. Using this dedicated IP address, you can reach your services or ingress.

    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.10.1/manifests/namespace.yaml
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.10.1/manifests/metallb.yaml
    kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

After installing the different MetalLB components, we need to modify a `configmap.yaml` file, which you can find here `./metallb/configmap.yaml`. This file contains information of how MetalLB can get and use internal IP's as LoadBalancers.

      apiVersion: v1
      kind: ConfigMap
      metadata:
        namespace: metallb-system
        name: config
      data:
        config: |
          address-pools:
          - name: default
            protocol: layer2
            addresses:
    -->     - 192.168.1.200-192.168.1.210

You can change the IP range above to match your needs. MetalLB will use this range as a reference to assign IP addresses to your LoadBalancers. Once ready you can apply the configuration map.

    kubectl apply -f ./metallb/configmap.yaml

Once installed, all services created in your Kubernetes cluster will receive an unique IP address as configured in the `configmap.yaml`.

### OpenEBS

Some of the services we'll leverage such as MongoDB or Minio require storage, to persist their data safely. In a managed Kubernetes cluster, the relevant cloud provider will allocate storage automatically for you, as you might expect this is not the case for a self-hosted cluster.

Therefore we will need to prepare some storage or persistent volume. To simplify this we can leverage the OpenEBS storage solution, which can automatically provision PV (Persistent volumes) for us.

Let us start with installing the OpenEBS operator. Please note that you might need to change the mount folder. Download the `openebs-operator.yaml`.

    wget https://openebs.github.io/charts/openebs-operator.yaml

Scroll to the bottom, until you hit the `StorageClass` section. Modify the `BasePath` value to the destination (external mount) you prefer.

    #Specify the location (directory) where
    # where PV(volume) data will be saved.
    # A sub-directory with pv-name will be
    # created. When the volume is deleted,
    # the PV sub-directory will be deleted.
    #Default value is /var/openebs/local
    - name: BasePath
      value: "/var/openebs/local/"

Once you are ok with the `BasePath` go ahead and apply the operator.

    kubectl apply -f openebs-operator.yaml

Once done it should start installing several resources in the `openebs` namespace. If all resources are created successfully we can launch the `helm install` for MongoDB.

### Proceed with managed Kubernetes

Now you're done with installing the self-hosted prerequisites, you should be able to proceed with the [B. Managed Kubernetes](#b-managed-kubernetes) section. This will install all the remaining resources.

## B. Managed Kubernetes

As of now there are many cloud providers such as, but not limited too, Azure, Google Cloud, AWS, and many more. Each cloud provider has build a management service on top of Kubernetes which takes over the heavy lifting of managing a cluster yourself. It makes specific resources such as built-in loadbalancers, storage, and more availble for your needs. The cloud provider manages all the complex things for you in the back-end and implements features such as load balancing, data replication etc.

### Prerequisites

For this installation we assume you have chosen a specific cloud provider that provides you with a manager Kubernetes. We'll assume you have the relevant `.kubeconfig` configuration to be able to connect the api server of your Kubernetes installation. Make sure you can run following commands on you cluster.

    kubectl get nodes

or

    kubectl get pods --all-namespaces

### Introduction

Kerberos Factory requires some initial components to be installed. If you run Kerberos Factory in the same cluster as where you have a Kerberos Vault installed, there is not much to do, and you might skip the most of the paragraphs.

If you plan to run Kerberos Factory in a different cluster (which is perfectly possible), you will need to make sure you complete this initial setup. To be more specific you will need to have following components running:

- Helm
- MongoDB
- Traefik (or alternatively Nginx ingress)

We'll assume you are starting an installation from scratch and therefore still need to install and configure previously mentioned components.

### Kerberos Factory

We'll start by cloning the configurations from our [Github repo](https://github.com/kerberos-io/factory). This repo contains all the relevant configuration files required.

    git clone https://github.com/kerberos-io/factory

Make sure to change directory to the `kubernetes` folder.

    cd factory/kubernetes

### Namespace

A best practices is to isole tools and/or applications in a namespace, this will group relevant (micro)services. As a best practice we'll create a namespace `kerberos-factory`.

    kubectl create namespace kerberos-factory

This namespace will later be used to deploy the relevant services for Kerberos Factory.

### Helm

Next we will install a couple of dependencies which are required for Kerberos Factory. [**Helm**](https://helm.sh/) is a package manager for Kubernetes, it helps you to set up services more easily (this could be a MQTT broker, a database, etc).
Instead of writing yaml files for every service we need, we use so-called Charts (libraries), that you can reuse and configure the, with the appropriate settings.

Use one of the preferred OS package managers to install the Helm client:

    brew install helm

    choco install kubernetes-helm

    scoop install helm

    gofish install helm

### MongoDB

When using Kerberos Factory, it will persist the configurations of your Kerberos Agents in a MongoDB database. As used before, we are using `helm` to install MongoDB in our Kubernetes cluster.

Have a look into the `./mongodb/values.yaml` file, you will find plenty of configurations for the MongoDB helm chart. To change the username and password of the MongoDB instance, go ahead and [find the attribute where](https://github.com/kerberos-io/factory/blob/master/kubernetes/mongodb/values.yaml#L148) you can change the root password.

    helm repo add bitnami https://charts.bitnami.com/bitnami
    kubectl create namespace mongodb

Note: If you are installing a self-hosted Kubernetes cluster, we recommend using `openebs`. Therefore make sure to uncomment the `global`.`storageClass` attribute, and make sure it's using `openebs-hostpath` instead.

    helm install mongodb -n mongodb bitnami/mongodb --values ./mongodb/values.yaml

Once installed successfully, we should verify if the password has been set correctly. Print out the password using `echo $MONGODB_ROOT_PASSWORD` and confirm the password is what you've specified in the `values.yaml` file.

    export MONGODB_ROOT_PASSWORD=$(kubectl get secret -n mongodb mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)
    echo $MONGODB_ROOT_PASSWORD

### Config Map

Kerberos Factory requires a configuration to connect to the MongoDB instance. To handle this `configmap` map is created in the `./mongodb/mongodb.config.yaml` file.

Modify the MongoDB credentials in the `./mongodb/mongodb.config.yaml`, and make sure they match the credentials of your MongoDB instance, as described above.

        - name: MONGODB_USERNAME
          value: "root"
        - name: MONGODB_PASSWORD
    -->   value: "yourmongodbpassword"

Create the config map.

    kubectl apply -f ./mongodb/mongodb.config.yaml -n kerberos-factory

### Deployment

To install the Kerberos Factory web app inside your cluster, simply execute below `kubectl` command. This will create the deployment for us with the necessary configurations, and exposed it on internal/external IP address, thanks to our `LoadBalancer` MetalLB or cloud provider.

    kubectl apply -f ./kerberos-factory/deployment.yaml -n kerberos-factory

Kerberos Factory will create Kerberos Agents on our behalf, and so create Kubernetes resource deployments. Therefore we'll need to enable some `ClusterRole` and `ClusterRoleBinding`, so we are able to create deployments from Kerberos Factory web app through the Kubernetes Golang SDK.

    kubectl apply -f ./kerberos-factory/clusterrole.yaml -n kerberos-factory

Verify that the Kerberos Factory got assigned an internal IP address.

    kubectl get svc -n kerberos-factory

You should see the service `factory-lb` being created, together with and IP address assigned from the MetalLB pool or cloud provider.

        NAME                               TYPE           CLUSTER-IP       EXTERNAL-IP    PORT(S)        AGE
    --> factory-lb                         LoadBalancer   10.107.209.226   192.168.1.81   80:30636/TCP   24m

### (Optional) Ingress

By default Kerberos Factory deployment will use and create a `LoadBalancer`. This means that Kerberos Factory will be granted an internal/external IP from which you can navigate to and consume the Kerberos Factory UI. However if you wish to use the `Ingress` functionality by assigning a readable DNS name, you'll need to modify a few things.

First make sure to install either Traefik or Ingress-nginx, following sections below. Once you have chosen an `Ingress`, open the `./kerberos-factory/ingress.yaml` configuration file. At the of the bottom file you will find an endpoint, similar to the `Ingress` file below. Update the hostname to your own preferred domain, and add these to your DNS server or `/etc/hosts` file (pointing to the same IP address as the Traefik/Ingress-nginx IP address).

        spec:
          rules:
    -->   - host: factory.domain.com
            http:
              paths:
              - path: /
                backend:
                  serviceName: factory
                  servicePort: 80

If you are using Ingress Nginx, do not forgot to comment `Traefik` and uncomment `Ingress Nginx`.

    apiVersion: extensions/v1beta1
    kind: Ingress
    metadata:
      name: factory
      annotations:
        #kubernetes.io/ingress.class: traefik
        kubernetes.io/ingress.class: nginx
        kubernetes.io/tls-acme: "true"
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
        cert-manager.io/cluster-issuer: "letsencrypt-prod"

Once done, apply the `Ingress` file.

    kubectl apply -f ./kerberos-factory/ingress.yaml -n kerberos-factory

#### (Option 1) Traefik

[**Traefik**](https://containo.us/traefik/) is a reverse proxy and load balancer which allows you to expose your deployments more easily. Kerberos uses Traefik to expose its APIs more easily.

Add the Helm repository and install traefik.

    kubectl create namespace traefik
    helm repo add traefik https://helm.traefik.io/traefik
    helm install traefik traefik/traefik -n traefik

After installation, you should have an IP attached to Traefik service, look for it by executing the `get service` command. You will see the ip address in the `EXTERNAL-IP` attribute.

    kubectl get svc

        NAME                        TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)                      AGE
        kubernetes                  ClusterIP      10.0.0.1       <none>          443/TCP                      36h
    --> traefik                     LoadBalancer   10.0.27.93     40.114.168.96   443:31623/TCP,80:31804/TCP   35h
        traefik-dashboard           NodePort       10.0.252.6     <none>          80:31146/TCP                 35h

Go to your DNS provider and link the domain you've configured in the first step `traefik.domain.com` to the IP address of thT `EXTERNAL-IP` attribute. When browsing to `traefik.domain.com`, you should see the traefik dashboard showing up.

#### (Option 2) Ingress-Nginx (alternative for Traefik)

If you don't like `Traefik` but you prefer `Ingress Nginx`, that works as well.

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    kubectl create namespace ingress-nginx
    helm install ingress-nginx -n ingress-nginx ingress-nginx/ingress-nginx

### Test out configuration

If everything worked out as expected, you should now have following services in your cluster across different namespaces:

- MongoDB
- Traefik or Nginx
- Kerberos Factory

It should look like this.

    $ kubectl get pods -n kerberos-factory
    NAME                              READY   STATUS    RESTARTS   AGE
    kerberos-factory-6f5c877d7c-hf77p          1/1     Running   0          2d11h

    $ kubectl get pods -n mongodb
    NAME                              READY   STATUS    RESTARTS   AGE
    mongodb-758d5c5ddd-qsfq9          1/1     Running   0          5m31s

    $ kubectl get pods -n traefik
    NAME                              READY   STATUS    RESTARTS   AGE
    traefik-7d566ccc47-mwslb          1/1     Running   0          4d12h

### Access the system

Once everything is configured correctly, you should be able to access the Kerberos Factory application. By navigating to the internal/external IP address (`LoadBalancer`) or domain (`Ingress`) with your browser you will see the Kerberos Factory login page showing up.

![Once successfully installed Kerberos Factory, it will show you the login page.](../assets/factory-login.gif)
