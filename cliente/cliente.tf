###############################
# Providers Configuration
###############################
provider "aws" {
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "eks-cliente"]
  }
}

###############################
# VPC Configuration
###############################
# Busca a VPC criada no primeiro script
data "aws_vpc" "existing_vpc" {
  filter {
    name   = "tag:Name"
    values = ["microservice-vpc"]  # Novo nome da VPC
  }
}

# Busca subnets privadas
data "aws_subnets" "private_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing_vpc.id]
  }

  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

# Busca subnets públicas
data "aws_subnets" "public_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing_vpc.id]
  }

  filter {
    name   = "tag:kubernetes.io/role/elb"
    values = ["1"]
  }
}

# Importa o Security Group para o EKS criado no primeiro script
data "aws_security_group" "eks" {
  filter {
    name   = "group-name"
    values = ["eks-sg-cliente"]  # Atualizar para o nome específico
  }

  vpc_id = data.aws_vpc.existing_vpc.id
}

###############################
# IAM Roles and Policies
###############################
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role-cliente"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "eks-cluster-role-cliente"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role" "eks_nodegroup_role" {
  name = "eks-nodegroup-role-cliente"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "eks-nodegroup-role-cliente"
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodegroup_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodegroup_role.name
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodegroup_role.name
}

###############################
# EKS Cluster
###############################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "eks-cliente"
  cluster_version = "1.28"

  # Configuração de rede
  vpc_id     = data.aws_vpc.existing_vpc.id
  subnet_ids = data.aws_subnets.private_subnets.ids

   # Configuração do Endpoint
  cluster_endpoint_public_access  = true    # Permite acesso público ao cluster
  cluster_endpoint_private_access = false   # Desativa acesso privado (requer VPC para funcionar)

  # Security Group importado
  cluster_security_group_id = data.aws_security_group.eks.id

  # IAM Role para o cluster
  iam_role_arn = aws_iam_role.eks_cluster_role.arn

  # Node Group Configuration
  eks_managed_node_groups = {
    cliente-node-group = {  # Mais consistente com nomenclatura
      desired_size = 1
      min_size     = 1
      max_size     = 2

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      disk_size = 20

      iam_role_arn = aws_iam_role.eks_nodegroup_role.arn

      labels = {
        Environment = "dev"
      }
    }
  }

  # Cluster Addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

tags = {
    Environment = "dev"
    Terraform   = "true"
    Name        = "eks-cliente"
  }
}

###############################
# Kubernetes Configuration
###############################
data "aws_ecr_authorization_token" "token" {}

resource "kubernetes_secret" "ecr_secret" {
  depends_on = [module.eks, aws_iam_role_policy_attachment.ecr_read_only]
  
  metadata {
    name = "ecr-secret"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${data.aws_ecr_authorization_token.token.proxy_endpoint}" = {
          "username" = "AWS"
          "password" = data.aws_ecr_authorization_token.token.password
          "auth"     = base64encode("AWS:${data.aws_ecr_authorization_token.token.password}")
        }
      }
    })
  }
}

resource "kubernetes_deployment" "microservice_cliente" {
  depends_on = [kubernetes_secret.ecr_secret]

  metadata {
    name = "microservice-cliente-deployment"
    labels = {
      app = "microservice-cliente"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "microservice-cliente"
      }
    }

    template {
      metadata {
        labels = {
          app = "microservice-cliente"
        }
      }

      spec {
        container {
          name  = "microservice-cliente"
          image = "740588470221.dkr.ecr.us-east-1.amazonaws.com/microservice_app:microservice_cliente_app"

          port {
            container_port = 3001
          }

          resources {
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
            requests = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          # Adicionando variáveis de ambiente para dependências e configuração do banco
          env {
            name  = "DB_USERNAME"
            value = var.db_username
          }

          env {
            name  = "DB_PASSWORD"
            value = var.db_password
          }

          env {
            name  = "DB_ENDPOINT_CLI"
            value = var.db_endpoint
          }

          env {
            name  = "SERVICE_NAME"
            value = "microservice-cliente"
          }
        }

        image_pull_secrets {
          name = "ecr-secret"
        }
      }
    }
  }
}

resource "kubernetes_service" "microservice_cliente" {
  depends_on = [kubernetes_deployment.microservice_cliente]

  metadata {
    name = "microservice-cliente-service"
  }

  spec {
    selector = {
      app = "microservice-cliente"
    }

    port {
      port        = 80
      target_port = 3001
    }

    type = "LoadBalancer"
  }
}

variable "db_username" {
  description = "Database username for the application"
}

variable "db_password" {
  description = "Database password for the application"
}

variable "db_endpoint" {
  description = "DocumentDB endpoint for the application"
}

output "microservice_cliente_loadbalancer_endpoint" {
  description = "Endpoint do LoadBalancer para o serviço microservice-cliente"
  value       = kubernetes_service.microservice_cliente.status[0].load_balancer[0].ingress[0].hostname
}
