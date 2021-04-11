# TODO: Add outputs with ip of instances and load balancer
# TODO: SSL certificate
# TODO: Define security groups for launch template / autoscaler / elb
# TODO: Define IAM users for launch template / autoscaler / elb
# TODO: Add RDS support
# TODO: Instances should not have public ip
# TODO: Rotate logs
# https://www.oss-group.co.nz/blog/automated-certificates-aws
# Use an application load balancer to handle SSL termination as the class lb does
# not seem to work
# I will experiment with nginx configuration to find a solution for the classic
# load balancer
# Task -> Load balance grpc server with an application load balancer
# Task -> Load balance a websockets server with an application or network load balancer
# For TLS, We need to add the following to /etc/nginx/nginx.conf to redirect http -> https
#if ($http_x_forwarded_proto != 'https') {
#  return 301 https://$host$request_uri;
#}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.32.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}


resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
}


resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "main"
  }
}

resource "aws_subnet" "sub1a" {
  availability_zone = "us-east-1a"
  vpc_id     = aws_vpc.main_vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  depends_on = [aws_internet_gateway.gw]

}

resource "aws_subnet" "sub1b" {
  availability_zone = "us-east-1b"
  vpc_id     = aws_vpc.main_vpc.id
  cidr_block = "10.0.2.0/24"
  map_public_ip_on_launch = true
  depends_on = [aws_internet_gateway.gw]
}


resource "aws_route_table" "prod-public-crt" {
    vpc_id = aws_vpc.main_vpc.id
    
    route {
        //associated subnet can reach everywhere
        cidr_block = "0.0.0.0/0" 
        //CRT uses this IGW to reach internet
        gateway_id = aws_internet_gateway.gw.id
    }
    depends_on = [aws_internet_gateway.gw]
}

resource "aws_route_table_association" "prod-crta-public-subnet-1a"{
    subnet_id = aws_subnet.sub1a.id
    route_table_id = aws_route_table.prod-public-crt.id
}

resource "aws_route_table_association" "prod-crta-public-subnet-1b"{
    subnet_id = aws_subnet.sub1b.id
    route_table_id = aws_route_table.prod-public-crt.id
}

resource "aws_security_group" "ssh-allowed" {
    vpc_id = aws_vpc.main_vpc.id
    
    egress {
        from_port = 0
        to_port = 0
        protocol = -1
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        // This means, all ip address are allowed to ssh ! 
        // Do not do it in the production. 
        // Put your office or home address in it!
        cidr_blocks = ["0.0.0.0/0"]
    }
    //If you do not add this rule, you can not reach the NGIX  
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
        from_port = 443
        to_port = 443
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
}


resource "aws_key_pair" "nginx_key_pair" {
  key_name   = "nginx-key-pair"
  public_key = var.public_key
}

resource "aws_launch_template" "nginx_lt" {
  name = "nginx-launch-template"
  description = "Starts an ubuntu instance running nginx"
  image_id      = "ami-042e8287309f5df03" # ubuntu 20.04
  instance_type = "t3.nano"
  key_name      = "nginx-key-pair"
  user_data     = filebase64("${path.module}/init.sh")
  vpc_security_group_ids = [aws_security_group.ssh-allowed.id]
}


# Find a certificate that is issued
data "aws_acm_certificate" "issued_cert" {
  domain   = "*.${var.domain_name}"
  statuses = ["ISSUED"]
}

resource "aws_s3_bucket_public_access_block" "public_access_block" {
  # TODO: This policy creates a public bucket which is dangerous.
  # Revisit this to make sure only the ELB is able to write in this bucket
  bucket = aws_s3_bucket.s3_nginx_logs.id
  block_public_acls = true
  ignore_public_acls = true
  block_public_policy = true
  restrict_public_buckets = true
}

locals {
  s3_bucket_name = "${var.domain_name}.nginx.logs"
}

data "aws_iam_policy_document" "main" {
   statement {
    sid    = "elb-logs-put-object"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.s3_bucket_name}/*"]
  }
}


resource "aws_s3_bucket" "s3_nginx_logs" {
  acl = "log-delivery-write"
  bucket = local.s3_bucket_name
  policy        = data.aws_iam_policy_document.main.json
  force_destroy = true
}

data "aws_elb_service_account" "main" {
}

resource "aws_elb" "nginx_elb" {
  name = "nginx-elb"
  # TODO: Why should we define a subnet instead of an availability zone?
  # Exactly one of availability_zones or subnets must be specified: this determines if the ELB exists in a VPC or in EC2-classic.
  subnets = [aws_subnet.sub1a.id, aws_subnet.sub1b.id]
  security_groups = [aws_security_group.ssh-allowed.id]

  # SSL
  listener {
    # SSL termination happens in the load balancer, so
    # we route requests to port 80 of nginx
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 443
    lb_protocol       = "https"
    ssl_certificate_id = data.aws_acm_certificate.issued_cert.arn
  }
  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    # For some strange reason, the AWS lb healthcheck fails if it is
    # HTTP
    target              = "TCP:80"
    interval            = 30
  }
  access_logs {
    bucket        = aws_s3_bucket.s3_nginx_logs.bucket
    interval      = 5
  }
}

resource "aws_autoscaling_group" "nginx_asg" {
  vpc_zone_identifier = [aws_subnet.sub1a.id, aws_subnet.sub1b.id]
  desired_capacity   = 1
  max_size           = 2
  min_size           = 1
  load_balancers     = [aws_elb.nginx_elb.name]

  launch_template {
    id      = aws_launch_template.nginx_lt.id
    version = "$Latest"
  }
}

resource "aws_autoscaling_policy" "as_policy" {
  name                   = "autoscaling-policy"
  autoscaling_group_name = aws_autoscaling_group.nginx_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 40
  }
}


# You must have an already existing hosted zone in AWS.
# Your have to create the zone manually, so that terraform
# does not destroy the hosted zone and deregister the domain name when you run `terraform destroy`

data "aws_route53_zone" "primary" {
  name = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "main" {
  name    = "nginx.${data.aws_route53_zone.primary.name}"
  type    = "A"
  zone_id = data.aws_route53_zone.primary.zone_id
  alias {
    name                   = aws_elb.nginx_elb.dns_name
    evaluate_target_health = true
    zone_id                = aws_elb.nginx_elb.zone_id
  }
}

output "url" {
  value = "Visit https://${aws_route53_record.main.fqdn} to verify it works"
}