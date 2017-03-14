/*
This does not cover creation of VPC all that you 
will need to create separately

You need to place this file in the directory where 
VPC creation module is present and you will need to
add dependencies in this according to your requirements
*/


## Security Groups

resource "aws_security_group" "lb_sg" {
  description = "controls access to the application ELB"

  vpc_id = "${module.vpc.vpc_id}"
  name   = "${var.vpc_name}-ecs-lbsg"

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_security_group" "instance_sg" {
  description = "controls direct access to application instances"
  vpc_id      = "${module.vpc.vpc_id}"
  name        = "${var.vpc_name}-instancesg"

  ingress {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22

    cidr_blocks = [
      "${var.vpc_cidr}",
    ]
  }

  ingress {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80

    security_groups = [
      "${aws_security_group.lb_sg.id}",
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## LaunchConfig

resource "aws_launch_configuration" "ecs-test-lcfg" {
  name = "${var.ecs_cluster_name}-LaunchConfig"
  security_groups = [
    "${aws_security_group.instance_sg.id}",
  ]

  key_name                    = "${var.key_pair_name}"
  image_id                    = "${var.ecs_ami_id}"
  instance_type               = "${var.launch_config_instance_type}"
  iam_instance_profile        = "${aws_iam_instance_profile.app.name}"
  user_data                   = "#!/bin/bash\necho ECS_CLUSTER=${var.ecs_cluster_name} >> /etc/ecs/ecs.config"
  associate_public_ip_address = false

  lifecycle {
    create_before_destroy = true
  }

}

## AutoScaling Group

resource "aws_autoscaling_group" "app" {
  name                 = "${var.ecs_cluster_name}-ASG"
  vpc_zone_identifier  = ["${module.vpc.private_subnets}"]
  min_size             = "${var.asg_min}"
  max_size             = "${var.asg_max}"
  desired_capacity     = "${var.asg_desired}"
  launch_configuration = "${aws_launch_configuration.ecs-test-lcfg.name}"
  health_check_type    = "EC2"

  lifecycle { create_before_destroy = true }

  depends_on = [
    "aws_launch_configuration.ecs-test-lcfg"
  ]

}

resource "aws_autoscaling_policy" "up" {
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = "${aws_autoscaling_group.app.name}"
  cooldown               = 120
  name                   = "${var.vpc_name}_ecs_${var.ecs_cluster_name}_asg_up"
  scaling_adjustment     = 2

  depends_on = [
    "aws_autoscaling_group.app"
  ]
}

resource "aws_cloudwatch_metric_alarm" "memory_usage_high" {
  alarm_actions       = [ "${aws_autoscaling_policy.up.arn}" ]
  alarm_description   = "This metric monitors ECS instance memory usage"
  alarm_name          = "${var.vpc_name}_ecs_${var.ecs_cluster_name}_memory_usage_high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryReservation"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70

  dimensions {
    ClusterName = "${aws_ecs_cluster.main.name}"
  }

  depends_on = [
    "aws_autoscaling_policy.up"
  ]
}

resource "aws_autoscaling_policy" "down" {
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = "${aws_autoscaling_group.app.name}"
  cooldown               = 120
  name                   = "${var.vpc_name}_ecs_${var.ecs_cluster_name}_asg_down"
  scaling_adjustment     = -1

  depends_on = [
    "aws_autoscaling_group.app"
  ]
}

resource "aws_cloudwatch_metric_alarm" "memory_usage_low" {
  alarm_actions       = [ "${aws_autoscaling_policy.down.arn}" ]
  alarm_description   = "This metric monitors ECS instance memory usage"
  alarm_name          = "${var.vpc_name}_ecs_${var.ecs_cluster_name}_memory_usage_low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryReservation"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 10

  dimensions {
    ClusterName = "${aws_ecs_cluster.main.name}"
  }

  depends_on = [
    "aws_autoscaling_policy.down"
  ]
}

## Template files

data "template_file" "instance_profile" {
  template = "${file("${path.module}/instance-profile-policy.json")}"

  vars {
    app_log_group_arn      = "${aws_cloudwatch_log_group.ecs-app.arn}"
    ecs_log_group_arn      = "${aws_cloudwatch_log_group.ecs.arn}"
    ecs_config_bucket_name = "${var.ecs_config_bucket_name}"
  }
}

## ECS Cluster

resource "aws_ecs_cluster" "main" {
  name = "${var.ecs_cluster_name}"
}


## ECS Task nginx

data "template_file" "task_definition_nginx" {
  template = "${file("${path.module}/task-definition.json")}"

  vars {
    image_url        = "nginx"
    container_name   = "nginx"
    log_group_region = "${var.aws_region}"
    log_group_name   = "${aws_cloudwatch_log_group.ecs-app.name}"
    host_port        = 80
    container_port   = 80
  }
}

resource "aws_ecs_task_definition" "nginx" {
  family                = "${var.vpc_name}_nginx"
  container_definitions = "${data.template_file.task_definition_nginx.rendered}"

  depends_on = [
    "data.template_file.task_definition_nginx",
  ]

}

resource "aws_ecs_service" "nginx" {
  name               = "${var.vpc_name}-nginx"
  cluster            = "${aws_ecs_cluster.main.id}"
  task_definition    = "${aws_ecs_task_definition.nginx.arn}"
  desired_count      = 1
  iam_role           = "${aws_iam_role.ecs_service.name}"

  load_balancer {
    target_group_arn = "${aws_alb_target_group.ecs-test-nginx.id}"
    container_name   = "nginx"
    container_port   = "80"
  }

  depends_on = [
    "aws_iam_role.ecs_service",
    "aws_alb_listener.front_end_nginx",
  ]
}

resource "aws_alb_target_group" "ecs-test-nginx" {
  name     = "${var.vpc_name}-ecs-nginx"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${module.vpc.vpc_id}"

  health_check {
    port                = "traffic-port"
    protocol            = "HTTP"

    matcher             = 200
    path                = "/"

    timeout             = 2
    interval            = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }

  depends_on = [
    "aws_alb.main"
  ]

}

resource "aws_alb_listener" "front_end_nginx" {
  load_balancer_arn  = "${aws_alb.main.id}"
  port               = "80"
  protocol           = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.ecs-test-nginx.id}"
    type             = "forward"
  }

  depends_on = [
    "aws_alb_target_group.ecs-test-nginx"
  ]

}


### ECS AutoScaling Alarm
resource "aws_cloudwatch_metric_alarm" "nginx_service_high" {
  alarm_name          = "nginx-service-CPU-Utilization-High-30"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "30"

  dimensions {
    ClusterName = "${aws_ecs_cluster.main.name}"
    ServiceName = "${aws_ecs_service.nginx.name}"
  }

  alarm_actions = ["${aws_appautoscaling_policy.nginx_up.arn}"]
}

resource "aws_cloudwatch_metric_alarm" "nginx_service_low" {
  alarm_name          = "nginx-service-CPU-Utilization-Low-5"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "5"

  dimensions {
    ClusterName = "${aws_ecs_cluster.main.name}"
    ServiceName = "${aws_ecs_service.nginx.name}"
  }

  alarm_actions = ["${aws_appautoscaling_policy.nginx_down.arn}"]
}

resource "aws_appautoscaling_target" "nginx_scale_target" {
  service_namespace = "ecs"
  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.nginx.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = "${aws_iam_role.ecs_autoscale_role.arn}"
  min_capacity = 1
  max_capacity = 4

  depends_on = [
    "aws_ecs_cluster.main",
    "aws_ecs_service.nginx"
  ]

}

resource "aws_appautoscaling_policy" "nginx_up" {
  name                      = "nginx-scale-up"
  service_namespace         = "ecs"
  resource_id               = "service/${var.ecs_cluster_name}/${aws_ecs_service.nginx.name}"
  scalable_dimension        = "ecs:service:DesiredCount"

  adjustment_type           = "ChangeInCapacity"
  cooldown                  = 300
  metric_aggregation_type   = "Average"

  step_adjustment {
    metric_interval_lower_bound = 0
    scaling_adjustment = 1
  }
  depends_on = [
    "aws_appautoscaling_target.nginx_scale_target"
  ]
}

resource "aws_appautoscaling_policy" "nginx_down" {
  name                      = "nginx-scale-down"
  service_namespace         = "ecs"
  resource_id               = "service/${var.ecs_cluster_name}/${aws_ecs_service.nginx.name}"
  scalable_dimension        = "ecs:service:DesiredCount"

  adjustment_type           = "ChangeInCapacity"
  cooldown                  = 300
  metric_aggregation_type   = "Average"

  step_adjustment {
    metric_interval_lower_bound = 0
    scaling_adjustment = -1
  }
  depends_on = [
    "aws_appautoscaling_target.nginx_scale_target"
  ]
}

## IAM

resource "aws_iam_role" "ecs_service" {
  name               = "${var.vpc_name}_role"
  assume_role_policy = "${file("${path.module}/ecs-assume-role.json")}"
}

resource "aws_iam_role" "ecs_autoscale_role" {
  name               = "ecsAutoscaleRole"
  assume_role_policy = "${file("${path.module}/autoscale-assume-role.json")}"
}

resource "aws_iam_role" "app_instance" {
  name = "${var.vpc_name}-instance-role"
  assume_role_policy = "${file("${path.module}/ec2-assume-role.json")}"
}

resource "aws_iam_policy_attachment" "ecs_service_role_attach" {
  name       = "ecs-service-role-attach"
  roles      = ["${aws_iam_role.ecs_service.name}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

resource "aws_iam_policy_attachment" "ecs_autoscale_role_attach" {
  name       = "ecs-autoscale-role-attach"
  roles      = ["${aws_iam_role.ecs_autoscale_role.name}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole"
}

resource "aws_iam_instance_profile" "app" {
  name  = "${var.vpc_name}-instprofile"
  roles = ["${aws_iam_role.app_instance.name}"]
}

resource "aws_iam_role_policy" "instance" {
  name   = "ECSInstanceRole"
  role   = "${aws_iam_role.app_instance.name}"
  policy = "${data.template_file.instance_profile.rendered}"
}

## ALB

resource "aws_alb" "main" {
  name            = "${var.vpc_name}-alb-ecs"
  subnets         = ["${module.vpc.public_subnet_list}"]
  security_groups = ["${aws_security_group.lb_sg.id}"]
  internal        = false

  depends_on = [
    "aws_launch_configuration.ecs-test-lcfg"
  ]

}

## CloudWatch Logs

resource "aws_cloudwatch_log_group" "ecs" {
  name = "${var.vpc_name}-ecs-group/ecs-agent"
}

resource "aws_cloudwatch_log_group" "ecs-app" {
  name = "${var.vpc_name}-ecs-group/ecs-app"
}
