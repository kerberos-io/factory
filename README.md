# Kerberos Factory

Kerberos Factory brings the Kerberos Agent to another level. The Kerberos Agent can be deployed anywhere you want, it can run as a binary, Docker container and inside a Kubernetes cluster. The latter is where Kerberos Factory shines, it is a UI that allows you to deploy and configure your Kerberos Agents into your Kubernetes cluster more easily.

![Kerberos Factory](https://user-images.githubusercontent.com/1546779/135861184-156c7e16-2a67-407c-830b-bb6cc10b67fc.png)


## Installation

For installing Kerberos Factory, you can follow [the how-to on our documentation website](http://doc.kerberos.io/factory/installation). In this repository you will find all the configuration files used in the installation tutorial.

## Dependencies

In this tutorial we will install a couple of components to run Kerberos Factory. We will use and install.

- OpenEBS for storage
- MongoDB for structuring information (configs)
- MetalLB to provide a loadbalance (for Nginx or Traefik)