####### Variables #######

variable "ami_id" {
  default     = "ami-0d643189857b024cc"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  default     = "t3.micro"
}

variable "server_name" {
  description = "Nombre base del servidor web"
  default     = "docker-server"
}

variable "environment" {
  description = "Ambiente de la aplicación"
  default     = "test"
}

variable "docker_image" {
  description = "Nombre de la imagen en DockerHub"
  type        = string
  default     = "augusto573/hello-world" 
}

variable "image_tag" {
  description = "Tag de la imagen de Docker"
  type        = string
  default     = "v1"
}

####### Provider #######
provider "aws" {
  region = "us-east-1"
}

provider "tls" {}

####### Data Sources (Red) #######
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
  }
}

####### Security Groups ####### 
resource "aws_security_group" "alb_sg" {
  name        = "${var.server_name}-alb-sg"
  description = "Permitir HTTP al Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.server_name}-alb-sg"
    Environment = "prod"
    Owner       = "arriofrio@uce.edu.ec"
    Team        = "DevOps"
    Project     = "UCE"
  }
}

resource "aws_security_group" "instance_sg" {
  name        = "${var.server_name}-instance-sg"
  description = "Security group para instancias via ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.server_name}-instance-sg"
    Environment = "prod"
    Owner       = "arriofrio@uce.edu.ec"
    Team        = "DevOps"
    Project     = "UCE"
  }
}

####### Key Pair #######
resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "docker-server-ssh" {
  key_name   = "docker-server-ssh"
  public_key = tls_private_key.pk.public_key_openssh
  
  tags = {
    Name        = "${var.server_name}-key"
    Environment = "prod"
    Owner       = "arriofrio@uce.edu.ec"
    Team        = "DevOps"
    Project     = "UCE"
  }
}

resource "local_file" "ssh_key" {
  filename        = "${var.server_name}.pem"
  content         = tls_private_key.pk.private_key_pem
  file_permission = "0400"
}

####### Launch Template #######
resource "aws_launch_template" "docker_lt" {
  name_prefix   = "${var.server_name}-lt-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.docker-server-ssh.key_name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              service docker start
              systemctl enable Docker

              docker run -d -p 80:80 --restart always --name app ${var.docker_image}:${var.image_tag}
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.server_name}-asg"
      Environment = "prod"
      Owner       = "arriofrio@uce.edu.ec"
      Project     = "UCE"
    }
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

####### Load Balancer & Target Group #######
resource "aws_lb" "app_lb" {
  name               = "${var.server_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name    = "${var.server_name}-alb"
    Project = "UCE"
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "${var.server_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

####### Auto Scaling Group #######
resource "aws_autoscaling_group" "app_asg" {
  name                = "${var.server_name}-asg"
  vpc_zone_identifier = data.aws_subnets.default.ids
  
  min_size            = 3
  max_size            = 7
  desired_capacity    = 3

  target_group_arns   = [aws_lb_target_group.app_tg.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.docker_lt.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50 
    }
    triggers = ["tag"] 
  }

  tag {
    key                 = "Name"
    value               = "${var.server_name}-instance"
    propagate_at_launch = true
  }
}

output "load_balancer_dns" {
  description = "DNS público del Load Balancer"
  value       = aws_lb.app_lb.dns_name
}