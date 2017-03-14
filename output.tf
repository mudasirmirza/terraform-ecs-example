
output "alb_address" {
  value = "${aws_alb.main.dns_name}"
}
