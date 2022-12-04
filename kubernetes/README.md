# Kerberos Factory on Kubernetes

As described in the `README.md` of this repository. Kerberos Factory runs on kubernetes to leverage the resilience and auto-scaling. It allows Kerberos Agents to be deployed in a kubernetes cluster without the management and complexity of creating kubernetes resources files.

## Managed Kubernetes vs Self-hosted Kubernetes

Just like `docker`, you bring your Kubernetes cluster where you want `edge` or `cloud`; private or public. Depending where you will host and how (e.g. managed Kubernetes cluster vs self-hosted) you'll have less/more responsibilities and/or control. Where and how is totally up to you, and your company preferences.

This installation guide will slight modify depending on if you are self-hosting or leveraging a managed Kubernetes service by a cloud provider. Within a self-hosted installation you'll be required to install specific Kubernetes resources yourself, such as persistent volumes, storage and a load balancer.

![Kerberos Factory deployments](assets/kerberosfactory-deployments.svg)

### A. Managed Kubernetes
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

### B. Self-hosted Kubernetes
1 [Prerequisites](#prerequisites-1)
2. [Docker](#docker)
3. [Kubernetes](#kubernetes)
4. [Untaint all nodes](#untaint-all-nodes)
5. [Calico](#calico)
6. [Introduction](#introduction-1)
7. [Kerberos Vault](#kerberos-vault-1)
8. [MetalLB](#metallb)
9. [OpenEBS](#openebs)
10. [Proceed with managed Kubernetes](#proceed-with-managed-kubernetes)

## A. Managed Kubernetes

## B. Self-hosted Kubernetes

You might have the requirement to self-host your Kubernetes cluster due to various good reasons. In this case the installation of Kerberos Factory will be slightly "more" difficult, in the sense that specific resources are not available by default; compared to the managed Kubernetes installation.

The good things is that installation of a self-hosted Kubernetes cluster, contains the same steps as a managed Kubernetes installation with a few extra resources on top. 

### Prerequisites

We'll assume you have a blank Ubuntu 20.04 LTS machine (or multiple machines/nodes) at your posession. We'll start with updating the Ubuntu operating system.

    apt-get update -y && apt-get upgrade -y

### Docker

Let's install our container runtime `docker` so we can run our containers.

    apt install docker.io -y

Once installed modify the `cgroup driver`, so kubernetes will be using it correctly. By default Kubernetes cgroup driver was set to systems but docker was set to systemd.

    sudo mkdir /etc/docker
    cat <<EOF | sudo tee /etc/docker/daemon.json
    {
      "exec-opts": ["native.cgroupdriver=systemd"],
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "100m"
      },
      "storage-driver": "overlay2"
    }
    EOF
    
    sudo systemctl enable docker
    sudo systemctl daemon-reload
    sudo systemctl restart docker

### Kubernetes

After Docker being installed go ahead and install the different Kubernetes servicess and tools.

    apt update -y
    apt install apt-transport-https curl -y
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add
    apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
    apt update -y && apt install kubeadm kubelet kubectl kubernetes-cni -y

Make sure you disable swap, this is required by Kubernetes.

    swapoff -a

And if you want to make it permanent after every boot.

    sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

***Special note***: If you already had Kubernetes installed, make sure you are running latest version and/or have properly cleaned up previous installation.

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

    kubectl taint nodes --all node-role.kubernetes.io/master-

### Calico

Calico is an open source networking and network security solution for containers, virtual machines, and native host-based workloads. (https://www.projectcalico.org/). We will use it as our network layer in our Kubernetes cluster. You could use otthers like Flannel aswell, but we prefer Calico.

    curl https://docs.projectcalico.org/manifests/calico.yaml -O
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

    cd kubernetes

### MetalLB

In a self-hosted scenario, we do not have fancy Load balancers and Public IPs from which we can "automatically" benefit. To overcome thism, solutions such as MetalLB - Baremetal Load Balancer - have been developed (https://metallb.universe.tf/installation/). MetalLB will dedicate an internal IP address, or IP range, which will be assigned to one or more Load Balancers. Using this dedicated IP address, you can reach your services or ingress.

    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/namespace.yaml
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/metallb.yaml
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

Now you're done with installing the self-hosted prerequisites, you should be able to proceed with the [A. Managed Kubernetes](#a-managed-kubernetes) section. This will install all the remaining resources.