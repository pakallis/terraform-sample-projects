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
  # TODO: Do not hardcode subnet
  # Exactly one of availability_zones or subnets must be specified: this determines if the ELB exists in a VPC or in EC2-classic.
  subnets = ["subnet-21abc479"]

  # SSL
  listener {
    instance_port     = 443
    instance_protocol = "https"
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
    target              = "HTTP:80/"
    interval            = 30
  }
  access_logs {
    bucket        = aws_s3_bucket.s3_nginx_logs.bucket
    interval      = 5
  }
}

resource "aws_autoscaling_group" "nginx_asg" {
  # TODO: Do not hardcode AZ
  availability_zones = ["us-east-1a"]
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
# does not destroy the hosted zone and domain name.

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