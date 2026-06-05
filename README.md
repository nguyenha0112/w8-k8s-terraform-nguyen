# K8s on AWS - Terraform 1-Click

Repo này dùng Terraform để dựng một EC2 trên AWS, cài Minikube trong EC2,
deploy một landing page nginx vào Kubernetes, rồi expose app ra Internet qua
AWS Application Load Balancer (ALB).

App **không được cài trực tiếp trên EC2**. App chạy trong Kubernetes Pods của
Minikube cluster.

## Yêu Cầu Và Cách Đáp Ứng

| Yêu cầu | Cách làm trong repo |
| --- | --- |
| Hạ tầng dựng bằng Terraform | Terraform tạo VPC, subnet, route table, security group, EC2, IAM, ALB, listener, target group |
| Kubernetes chạy bằng Minikube hoặc kind trên EC2 | Dùng Minikube với Docker driver trên EC2 |
| App chạy trong Kubernetes | nginx Deployment 2 Pods, ConfigMap landing page, NodePort Service |
| App truy cập được qua ALB | ALB forward HTTP vào EC2 port `8080`, sau đó proxy vào Minikube NodePort `30080` |
| 1-click automation | `terraform init; terraform apply -auto-approve` |
| Có >=2 Terraform provider | `hashicorp/aws` và `hashicorp/cloudinit` |
| Destroy sạch sau khi xong | `terraform destroy -auto-approve` |

## Sơ Đồ Kiến Trúc

```text
Internet
   |
   v
AWS Application Load Balancer :80
   |
   v
Target Group
Target: EC2 instance :8080
   |
   v
systemd socat proxy trên EC2
   |
   v
Minikube IP :30080
   |
   v
Kubernetes NodePort Service
   |
   v
nginx Deployment, 2 Pods
   |
   v
ConfigMap landing page
```

Hạ tầng AWS:

```text
VPC 10.42.0.0/16
├── Public subnet 10.42.0.0/24, AZ A
│   └── EC2 chạy Docker + Minikube
├── Public subnet 10.42.1.0/24, AZ B
├── Internet Gateway + public route table
└── Internet-facing ALB nằm trên 2 public subnet
```

## Luồng Traffic

Khi mở URL ALB trên browser:

```text
Browser
  -> ALB :80
  -> EC2 :8080
  -> socat proxy
  -> Minikube NodePort :30080
  -> Kubernetes Service hello-app
  -> nginx Pod
  -> HTML landing page
```

Giải thích port:

| Port | Ý nghĩa |
| --- | --- |
| `80` trên ALB | HTTP public cho browser |
| `8080` trên EC2 | Port host để ALB target vào |
| `30080` trên Minikube | Kubernetes NodePort |
| `80` trong Pod | Port nginx container |

EC2 security group chỉ cho ALB security group truy cập port `8080`.
Không mở SSH `22`, không mở NodePort `30080` ra Internet.

## Vì Sao Chọn Thiết Kế Này?

### Vì sao dùng Minikube?

Đề bài yêu cầu chạy Kubernetes bằng Minikube hoặc kind trên EC2. Minikube phù
hợp với mô hình single-node Kubernetes và dễ bootstrap bằng script trong EC2.

### Vì sao dùng Docker driver?

Minikube dùng Docker driver để tạo Kubernetes node bên trong Docker trên EC2:

```text
EC2 Ubuntu
  -> Docker
      -> Minikube node
          -> Kubernetes Pods
```

### Vì sao cần NodePort và proxy?

App chạy trong Kubernetes nên cần expose Service ra ngoài cluster. Repo dùng
NodePort `30080`.

Vì Minikube Docker driver chạy node trong Docker network nội bộ, ALB không gọi
trực tiếp Pod hoặc Docker internal network. Vì vậy EC2 mở port `8080` cho ALB,
rồi `socat` proxy từ EC2 `8080` vào Minikube NodePort `30080`.

### Vì sao dùng SSM thay vì SSH?

Nếu dùng SSH thì cần key pair và mở port `22`. Repo này dùng AWS Systems
Manager để debug EC2:

```text
EC2 có IAM role AmazonSSMManagedInstanceCore
EC2 có SSM Agent
Không cần key pair
Không cần mở port 22
```

## Terraform Providers Và Provider Wiring

Repo dùng 2 provider:

```hcl
provider "aws" {
  region = var.aws_region
}

provider "cloudinit" {}
```

### `aws` provider

Dùng để tạo tài nguyên AWS:

```text
VPC, subnet, route table, security group
IAM role, instance profile
EC2
ALB, listener, target group
```

### `cloudinit` provider

Dùng để render và đóng gói bootstrap script thành `user_data_base64`.

File bootstrap:

```text
templates/bootstrap.sh.tftpl
```

Đoạn render:

```hcl
data "cloudinit_config" "minikube" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
      minikube_version = var.minikube_version
      kubectl_version  = var.kubectl_version
    })
  }
}
```

Đoạn wire sang AWS EC2:

```hcl
resource "aws_instance" "minikube" {
  user_data_base64 = data.cloudinit_config.minikube.rendered
}
```

Luồng wiring:

```text
bootstrap.sh.tftpl
  -> cloudinit provider render/gzip/base64
  -> data.cloudinit_config.minikube.rendered
  -> aws_instance.minikube.user_data_base64
  -> EC2 boot
  -> cloud-init trong Ubuntu chạy script
```

Lưu ý: Ubuntu EC2 có sẵn `cloud-init` để chạy user-data khi boot. Terraform
`cloudinit` provider là phần chạy ở phía Terraform để đóng gói user-data trước
khi gửi vào EC2.

## Bootstrap Script Làm Gì?

File `templates/bootstrap.sh.tftpl` là template user-data script. Khi EC2 boot
lần đầu, cloud-init chạy script này.

Script thực hiện:

```text
Cài Docker, curl, socat
Tạo swap 2 GB
Cài/bật SSM Agent
Tải Minikube
Tải kubectl
Start Minikube bằng Docker driver
Tạo Kubernetes ConfigMap chứa HTML landing page
Tạo nginx Deployment 2 replicas
Tạo NodePort Service port 30080
Đợi rollout hoàn tất
Tạo systemd service proxy EC2 8080 -> Minikube 30080
```

## Vì Sao Không Dùng Kubernetes Provider?

Kubernetes provider cần cluster có sẵn trước khi Terraform chạy. Nhưng trong
bài này, Minikube cluster chỉ tồn tại sau khi EC2 boot và chạy bootstrap script.
Kubeconfig cũng nằm trong EC2.

Vì vậy repo không dùng Kubernetes provider. EC2 tự chạy:

```bash
kubectl apply -f /root/app.yaml
```

Cách này giúp toàn bộ workflow chạy được trong một lần Terraform apply.

## Yêu Cầu Trước Khi Chạy

- Terraform `>= 1.5`
- AWS CLI đã đăng nhập account AWS
- IAM user/role có quyền tạo EC2, VPC, ELBv2, IAM, SSM
- Region có ít nhất 2 Availability Zones

Giá trị mặc định:

```text
AWS region:    ap-southeast-1
Instance type: t3.small
Minikube:      v1.37.0
kubectl:       v1.34.1
```

Nếu muốn override biến, copy:

```text
terraform.tfvars.example -> terraform.tfvars
```

## Lệnh Deploy

Từ repo sạch, chạy:

```powershell
terraform init; terraform apply -auto-approve
```

Giải thích:

```text
terraform init
  -> tải provider

terraform apply -auto-approve
  -> tự động tạo hạ tầng, không hỏi nhập yes
```

Sau khi apply xong, lấy URL:

```powershell
terraform output -raw app_url
```

EC2 cần vài phút để tải Minikube image, start cluster và deploy app. Trong thời
gian đó ALB có thể trả `502 Bad Gateway`. Đợi Target Group chuyển `Healthy` rồi
mở lại URL.

## Verify

### 1. Kiểm tra browser

Mở URL từ output:

```text
http://<alb-dns-name>
```

Trang mong đợi:

```text
Xbrain Cloud & AI Operations
Keep your systems running at their best.
```

### 2. Kiểm tra ALB target healthy

```powershell
$tgArn = aws elbv2 describe-target-groups `
  --region ap-southeast-1 `
  --names minikube-alb-tg `
  --query TargetGroups[0].TargetGroupArn `
  --output text

aws elbv2 describe-target-health `
  --region ap-southeast-1 `
  --target-group-arn $tgArn `
  --query TargetHealthDescriptions[].TargetHealth `
  --output json
```

Kết quả mong đợi:

```json
[
  {
    "State": "healthy"
  }
]
```

### 3. Kiểm tra app chạy trong Kubernetes

Chạy qua AWS SSM:

```powershell
$instanceId = terraform output -raw instance_id

$cmdId = aws ssm send-command `
  --region ap-southeast-1 `
  --instance-ids $instanceId `
  --document-name AWS-RunShellScript `
  --parameters commands="HOME=/root kubectl get all" `
  --query Command.CommandId `
  --output text

Start-Sleep -Seconds 5

aws ssm get-command-invocation `
  --region ap-southeast-1 `
  --command-id $cmdId `
  --instance-id $instanceId `
  --query StandardOutputContent `
  --output text
```

Kết quả mong đợi:

```text
pod/hello-app-...          1/1 Running
pod/hello-app-...          1/1 Running
service/hello-app          NodePort 80:30080
deployment.apps/hello-app  2/2
```

## Destroy

Sau khi chụp evidence, chạy:

```powershell
terraform destroy -auto-approve
```

Kiểm tra state:

```powershell
terraform state list
```

Nếu không có output, Terraform không còn quản lý resource nào.

## Cấu Trúc Repo

```text
.
├── README.md
├── EVIDENCE_PACK.vi.md
├── main.tf
├── outputs.tf
├── variables.tf
├── versions.tf
├── terraform.tfvars.example
├── templates/
│   └── bootstrap.sh.tftpl
├── .terraform.lock.hcl
└── .gitignore
```

Ý nghĩa:

| File | Tác dụng |
| --- | --- |
| `versions.tf` | Khai báo Terraform version và providers |
| `variables.tf` | Khai báo biến đầu vào |
| `main.tf` | Tạo hạ tầng AWS và wire cloudinit vào EC2 |
| `outputs.tf` | In `app_url` và `instance_id` |
| `templates/bootstrap.sh.tftpl` | User-data script để EC2 tự cài Minikube và deploy app |
| `terraform.tfvars.example` | File mẫu override biến |
| `.terraform.lock.hcl` | Lock provider version |
| `EVIDENCE_PACK.vi.md` | Bằng chứng chạy bài |
| `.gitignore` | Không push state/cache/local notes |

## Không Push State

Repo không push:

```text
.terraform/
terraform.tfstate
terraform.tfstate.backup
terraform.tfvars
```

Lý do:

```text
.terraform/ là cache provider local, chạy terraform init sẽ tự tạo lại.
terraform.tfstate chứa thông tin resource/account AWS, không nên public.
terraform.tfvars là cấu hình local của từng người.
```
