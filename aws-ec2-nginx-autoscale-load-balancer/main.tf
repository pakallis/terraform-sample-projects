# TODO: Add outputs with ip of instances and load balancer
# TODO: SSL certificate
# TODO: Define security groups for launch template / autoscaler / elb
# TODO: Define IAM users for launch template / autoscaler / elb
# TODO: Add RDS support
# TODO: Instances should not have public ip
# https://www.oss-group.co.nz/blog/automated-certificates-aws

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


resource "aws_elb" "nginx_elb" {
  name = "nginx-elb"
  # TODO: Why should we define a subnet instead of an availability zone?
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
}

resource "aws_autoscaling_group" "nginx_asg" {
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

resource "aws_route53_record" "pakallis" {
  name    = "nginx.${data.aws_route53_zone.primary.name}"
  type    = "A"
  zone_id = data.aws_route53_zone.primary.zone_id
  alias {
    name                   = aws_elb.nginx_elb.dns_name
    evaluate_target_health = true
    zone_id                = aws_elb.nginx_elb.zone_id
  }
}