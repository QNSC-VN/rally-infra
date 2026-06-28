terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── CloudWatch Log Group ───────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.cluster_name}/${var.service_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ── IAM — ECS Task Execution Role ─────────────────────────────────────────────
resource "aws_iam_role" "execution" {
  name = "rally-ecs-exec-${var.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow execution role to pull secrets from Secrets Manager (+ KMS decrypt if CMK used)
resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0
  name  = "rally-ecs-exec-${var.service_name}-secrets"
  role  = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.secret_arns
      }],
      var.kms_key_arn != "" ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }] : []
    )
  })
}

# ── IAM — ECS Task Role ────────────────────────────────────────────────────────
resource "aws_iam_role" "task" {
  name = "rally-ecs-task-${var.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# Grant SQS permissions to task role (worker needs to consume queues)
resource "aws_iam_role_policy" "task_sqs" {
  count = length(var.sqs_queue_arns) > 0 ? 1 : 0
  name  = "rally-ecs-task-${var.service_name}-sqs"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]
      Resource = var.sqs_queue_arns
    }]
  })
}

resource "aws_iam_role_policy" "task_sns" {
  count = length(var.sns_topic_arns) > 0 ? 1 : 0
  name  = "rally-ecs-task-${var.service_name}-sns"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = var.sns_topic_arns
    }]
  })
}

# ── Task Definition ────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.cluster_name}-${var.service_name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.image_uri
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = var.environment_vars

      secrets = [for s in var.secrets : {
        name      = s.name
        valueFrom = s.secret_arn
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", var.health_check_command]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      readonlyRootFilesystem = false
      user                   = "1001:1001"
    }
  ])

  tags = var.tags
}

# ── ALB Target Group ───────────────────────────────────────────────────────────
resource "aws_lb_target_group" "this" {
  count = var.attach_alb ? 1 : 0

  name        = "${var.cluster_name}-${var.service_name}"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-${var.service_name}" })
}

# ── ALB Listener Rule ──────────────────────────────────────────────────────────
resource "aws_lb_listener_rule" "this" {
  count = var.attach_alb ? 1 : 0

  listener_arn = var.alb_listener_arn
  priority     = var.alb_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    path_pattern { values = var.alb_path_patterns }
  }

  tags = var.tags
}

# ── ECS Service ────────────────────────────────────────────────────────────────
resource "aws_ecs_service" "this" {
  name                               = var.service_name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = var.attach_alb ? 90 : null
  enable_execute_command             = var.enable_ecs_exec
  propagate_tags                     = "SERVICE"

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.attach_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.service_name
      container_port   = var.container_port
    }
  }

  tags = merge(var.tags, { Name = var.service_name })

  lifecycle {
    ignore_changes = [task_definition]   # task def updated by deploy workflow
  }
}

# ── Auto-scaling ───────────────────────────────────────────────────────────────
resource "aws_appautoscaling_target" "this" {
  max_capacity       = var.max_count
  min_capacity       = var.min_count
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.service_name}-scale-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_pct
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.service_name}-scale-mem"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.memory_target_pct
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}
