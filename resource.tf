resource "aws_vpc" "ecsvpc" {
  cidr_block = "10.7.0.0/16"
}


resource "aws_subnet" "ecs_public" {
  count                   = 2
  cidr_block              = cidrsubnet(aws_vpc.ecsvpc.cidr_block, 8, 2 + count.index)
  availability_zone       = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id                  = aws_vpc.ecsvpc.id
  map_public_ip_on_launch = true
}

resource "aws_subnet" "ecs_private" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.ecsvpc.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.ecsvpc.id
}

resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.ecsvpc.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.ecsvpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}

resource "aws_eip" "gateway" {
  count      = 2
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]
}

resource "aws_nat_gateway" "gateway" {
  count         = 2
  subnet_id     = element(aws_subnet.ecs_public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.ecsvpc.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = element(aws_subnet.ecs_private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

resource "aws_security_group" "ecslb_sg" {
  name        = "ecslb_sg"
  vpc_id      = aws_vpc.ecsvpc.id

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
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "ecslb" {
  name            = "ecslb"
  subnets         = aws_subnet.ecs_public.*.id
  security_groups = [aws_security_group.ecslb_sg.id]
}

resource "aws_lb_target_group" "ecs_targetgroup" {
  name        = "ecs-targetgroup"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.ecsvpc.id
  target_type = "ip"
}

resource "aws_lb_listener" "ecslb" {
  load_balancer_arn = aws_lb.ecslb.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.ecs_targetgroup.id
    type             = "forward"
  }
}

resource "aws_ecs_task_definition" "ecs_task" {
  family                   = "ecs_task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048

  container_definitions = <<DEFINITION
[
  {
    "image": "heroku/nodejs-hello-world",
    "cpu": 1024,
    "memory": 2048,
    "name": "ecs_task",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 3000,
        "hostPort": 3000
      }
    ]
  }
]
DEFINITION
}

resource "aws_security_group" "ecs_task_sg" {
  name        = "ecs_task_sg"
  vpc_id      = aws_vpc.ecsvpc.id

  ingress {
    protocol        = "tcp"
    from_port       = 3000
    to_port         = 3000
    security_groups = [aws_security_group.ecslb_sg.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "dev_cluster" {
  name = "dev_cluster"
}

resource "aws_ecs_service" "ecs_task" {
  name            = "hello-world-service"
  cluster         = aws_ecs_cluster.dev_cluster.id
  task_definition = aws_ecs_task_definition.ecs_task.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_task_sg.id]
    subnets         = aws_subnet.ecs_private.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs_targetgroup.id
    container_name   = "ecs_task"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.ecslb]
}
