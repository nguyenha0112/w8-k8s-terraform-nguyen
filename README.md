# K8s on AWS - Terraform 1-Click

Deploy a lightweight landing page into a Minikube Kubernetes cluster running
on one AWS EC2 instance, then expose the application to the Internet through an
AWS Application Load Balancer (ALB).

The complete infrastructure and application deployment are automated by
Terraform. The application is not installed directly on EC2.

## Challenge Requirements

| Requirement | Implementation |
| --- | --- |
| Infrastructure created by Terraform | VPC, subnets, routing, security groups, EC2, IAM, ALB, listener, and target group |
| Kubernetes runs on EC2 | Minikube with the Docker driver |
| App runs inside Kubernetes | nginx Deployment with two Pods, ConfigMap landing page, and NodePort Service |
| App is accessible through an ALB | ALB forwards HTTP traffic to an EC2 host proxy, then to the Minikube NodePort |
| One-click deployment | `terraform init; terraform apply -auto-approve` |
| At least two Terraform providers | `hashicorp/aws` and `hashicorp/cloudinit` |
| Clean removal | `terraform destroy -auto-approve` |

## Architecture

```text
Internet
   |
   v
AWS Application Load Balancer :80
   |
   v
ALB Target Group
Target: EC2 instance :8080
   |
   v
systemd-managed socat proxy
EC2 :8080 -> Minikube IP :30080
   |
   v
Kubernetes NodePort Service :30080
   |
   v
nginx Deployment, 2 Pods
   |
   v
ConfigMap-based landing page
```

AWS infrastructure:

```text
VPC 10.42.0.0/16
├── Public subnet 10.42.0.0/24, Availability Zone A
│   └── EC2 instance running Docker and Minikube
├── Public subnet 10.42.1.0/24, Availability Zone B
├── Internet Gateway and public route table
└── Internet-facing ALB spanning both public subnets
```

## Traffic Flow

1. A browser sends an HTTP request to the ALB DNS name on port `80`.
2. The ALB forwards the request to the registered EC2 instance on port `8080`.
3. A systemd-managed `socat` process forwards EC2 port `8080` to the Minikube
   node IP on Kubernetes NodePort `30080`.
4. The Kubernetes Service selects one of the nginx Pods.
5. nginx serves the landing page mounted from a Kubernetes ConfigMap.

The EC2 security group allows port `8080` only from the ALB security group.
SSH and the Kubernetes NodePort are not exposed to the Internet.

## Why This Design

### Minikube

Minikube is used because the challenge requires Minikube or kind on one EC2
instance. The Docker driver keeps the cluster lightweight and avoids installing
Kubernetes components directly on the host.

### NodePort and Host Proxy

The Minikube Docker node uses an internal Docker network address that the ALB
cannot target directly. A fixed NodePort gives the application a stable port
inside Minikube, while the host proxy gives the ALB a stable EC2 port.

This keeps the application inside Kubernetes while allowing a normal ALB
instance target group to reach it.

### Custom VPC

The project creates its own VPC instead of relying on the account's default
VPC. This makes the deployment reproducible across clean AWS accounts and gives
the ALB the required subnets in two Availability Zones.

### Systems Manager

The EC2 instance receives an IAM instance profile for AWS Systems Manager.
This allows troubleshooting without opening SSH port `22`.

## Terraform Provider Wiring

This project uses two providers in the same Terraform configuration:

```hcl
provider "aws" {
  region = var.aws_region
}

provider "cloudinit" {}
```

The `cloudinit` provider renders the EC2 bootstrap script as MIME cloud-init
user data:

```hcl
data "cloudinit_config" "minikube" {
  part {
    content_type = "text/x-shellscript"
    content      = templatefile("${path.module}/templates/bootstrap.sh.tftpl", ...)
  }
}
```

The `aws` provider consumes the rendered result when creating EC2:

```hcl
resource "aws_instance" "minikube" {
  user_data_base64 = data.cloudinit_config.minikube.rendered
}
```

Provider dependency:

```text
templatefile
   -> cloudinit_config.minikube.rendered
   -> aws_instance.minikube.user_data_base64
   -> EC2 bootstraps Minikube and deploys the Kubernetes app
```

The Terraform Kubernetes provider is intentionally not used. The Minikube
cluster and its kubeconfig exist only after EC2 boots, and the kubeconfig stays
inside EC2. Deploying the manifest through cloud-init allows the infrastructure
and application to be created in one Terraform apply without exposing the
Kubernetes API or requiring a second apply.

## What EC2 Bootstrap Does

The script in `templates/bootstrap.sh.tftpl` performs these steps:

1. Installs Docker, `curl`, `socat`, Minikube, kubectl, and the SSM agent.
2. Creates swap space so Minikube can run reliably on the Free Tier-compatible
   `t3.small` instance.
3. Starts Minikube with the Docker driver.
4. Creates a Kubernetes ConfigMap containing the landing page HTML.
5. Creates an nginx Deployment with two replicas.
6. Creates a NodePort Service on port `30080`.
7. Waits for the Deployment rollout to complete.
8. Starts a systemd service that proxies EC2 port `8080` to the NodePort.

## Prerequisites

- Terraform `>= 1.5`
- AWS CLI authenticated to an AWS account
- AWS permissions for EC2, VPC, ELBv2, IAM, and Systems Manager
- An AWS region with at least two Availability Zones

Defaults:

```text
AWS region:    ap-southeast-1
Instance type: t3.small
Minikube:      v1.37.0
kubectl:       v1.34.1
```

To override defaults, create `terraform.tfvars` based on
`terraform.tfvars.example`.

## 1-Click Deploy

From a clean repository, run:

```powershell
terraform init; terraform apply -auto-approve
```

Terraform prints:

```text
app_url     = "http://<alb-dns-name>"
instance_id = "i-xxxxxxxxxxxxxxxxx"
```

EC2 must download the Minikube base image and Kubernetes images during the
first boot. The ALB URL can return `502 Bad Gateway` for several minutes until
the cluster, Pods, proxy, and ALB health checks are ready.

Get the URL again:

```powershell
terraform output -raw app_url
```

## Verification

### Verify the Public URL

Open the `app_url` output in a browser. The page should display:

```text
K8s on AWS
Terraform 1-Click deployment is running successfully.
```

This browser page is the required ALB evidence.

### Verify the App Runs in Kubernetes

Use AWS Systems Manager Run Command or Session Manager on the EC2 instance:

```bash
sudo minikube status
sudo kubectl get nodes
sudo kubectl get deployment,pods,service,configmap
sudo kubectl describe service hello-app
```

Expected Kubernetes resources:

```text
deployment.apps/hello-app
pod/hello-app-...
service/hello-app
configmap/hello-app-html
```

The nginx package is not installed as an application on EC2. nginx runs only
inside the Kubernetes Pods.

### Verify the ALB Target

In the AWS console:

```text
EC2 -> Target Groups -> minikube-alb-tg -> Targets
```

The EC2 target on port `8080` should be `Healthy`.

## Troubleshooting

The first bootstrap can take several minutes. Use Systems Manager to inspect:

```bash
sudo cloud-init status --long
sudo tail -n 200 /var/log/cloud-init-output.log
sudo minikube status
sudo kubectl get pods,service
sudo systemctl status minikube-app-proxy
```

Common observations:

- `502 Bad Gateway`: the ALB target is not healthy yet.
- Target is unhealthy: Minikube, Pods, or the proxy may still be starting.
- cloud-init is running: wait for Minikube image downloads to complete.
- cloud-init is in error: inspect `/var/log/cloud-init-output.log`.

## Destroy

Destroy all resources after collecting evidence:

```powershell
terraform destroy -auto-approve
```

This removes EC2, ALB, IAM resources, networking resources, and the Terraform
managed infrastructure. EC2 and ALB can incur charges while they exist.

## Project Structure

```text
.
├── main.tf
├── outputs.tf
├── variables.tf
├── versions.tf
├── terraform.tfvars.example
├── templates/
│   └── bootstrap.sh.tftpl
└── README.md
```
