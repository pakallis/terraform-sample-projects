# TODO: Launch configuration with spot instances to save $$
# TODO: Attach load balancer to auto-scaling group
# TODO: Add public key to vars
# TODO: Add outputs with ip of instances and load balancer
# TODO: SSL certificate
# TODO: Define security groups for launch template / autoscaler / elb

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

resource "aws_key_pair" "deployer" {
  key_name   = "deployer"
  public_key = var.public_key
}

resource "aws_launch_template" "main_lt" {
  name_prefix   = "launch-template"
  image_id      = "ami-042e8287309f5df03" # ubuntu 20.04
  instance_type = "t3.nano"
  key_name      = "deployer"
  user_data     = filebase64("${path.module}/init.sh")
}


resource "aws_elb" "main_elb" {
  name = "main-elb"
  # TODO: Why should we define a subnet instead of an availability zone?
  subnets = ["subnet-21abc479"]
  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
}

resource "aws_autoscaling_group" "main_asg" {
  availability_zones = ["us-east-1a"]
  desired_capacity   = 1
  max_size           = 2
  min_size           = 1
  load_balancers     = [aws_elb.main_elb.name]

  launch_template {
    id      = aws_launch_template.main_lt.id
    version = "$Latest"
  }
}

resource "aws_autoscaling_policy" "as_policy" {
  name                   = "autoscaling-policy"
  autoscaling_group_name = aws_autoscaling_group.main_asg.name
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
}

resource "aws_route53_record" "pakallis" {
  name    = "nginx.${data.aws_route53_zone.primary.name}"
  type    = "A"
  zone_id = data.aws_route53_zone.primary.zone_id
  alias {
    name                   = aws_elb.main_elb.dns_name
    evaluate_target_health = true
    zone_id = aws_elb.main_elb.zone_id
  }
}

