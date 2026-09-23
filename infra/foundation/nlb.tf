resource "aws_lb" "apis" {
  name                             = "${var.project_name}-nlb"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = aws_subnet.private[*].id
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "apis" {
  for_each = local.api_node_ports

  name        = "${var.project_name}-${each.key}"
  port        = each.value
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.this.id

  health_check {
    protocol = "HTTP"
    path     = "/health"
  }
}

resource "aws_lb_listener" "apis" {
  for_each = local.api_node_ports

  load_balancer_arn = aws_lb.apis.arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apis[each.key].arn
  }
}

# Registra os nodes do managed node group nos target groups. O for_each usa chaves fixas,
# entao o nome do ASG (conhecido so depois do apply) nao exige -target no primeiro apply.
resource "aws_autoscaling_attachment" "apis" {
  for_each = local.api_node_ports

  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.apis[each.key].arn
}