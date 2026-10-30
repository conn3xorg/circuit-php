output "listen" {
  description = "Where each pool listens, by host and pool name: a socket path or an address and port, to hand to the web server."
  value       = local.listen
}

output "service" {
  description = "The PHP-FPM service on each host, such as php8.4-fpm on Debian 13 or php-fpm on the Red Hat family."
  value       = { for host, l in local.layout : host => l.service }
}
