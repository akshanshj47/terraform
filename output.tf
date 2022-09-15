output "load_balancer_ip" {
  value = aws_lb.ecslb.dns_name
}
