variable "port" {
  type    = number
  default = 2298
}

locals {
  hosts = { box = "127.0.0.1" }
}

module "php" {
  source = "../.."

  hosts                = local.hosts
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  extensions = ["mysqli", "pdo_mysql", "gd", "intl", "mbstring", "zip", "curl", "xml"]
  ini        = { memory_limit = "256M", expose_php = "Off" }

  # One pool for the site, started on demand. Its socket belongs to the web
  # server's user, www-data or apache.
  pools = {
    app = { pm = "ondemand", max_children = 4 }
  }

  install_composer = true
}

# Apache on :8080 serves /srv/app and hands .php files to the pool's socket.
module "apache" {
  source = "github.com/conn3xorg/circuit-apache?ref=v0.1.0"

  hosts                = local.hosts
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  vhosts = {
    app = {
      server_name   = "app.example.test"
      port          = 8080
      document_root = "/srv/app"
      extra         = <<-EOT
        DirectoryIndex index.php
        <FilesMatch "\.php$">
            SetHandler "proxy:unix:${module.php.listen["box"]["app"]}|fcgi://localhost"
        </FilesMatch>
      EOT
    }
  }

  modules = ["proxy_fcgi"]
}

# A PHP page, and curl to fetch it with. It runs after both modules, so its
# package run doesn't overlap theirs.
circuit "content" {
  hosts = local.hosts

  ssh {
    user             = "root"
    port             = var.port
    private_key_file = "./id_ed25519"
    known_hosts_file = "./known_hosts"
  }

  step "curl" {
    package {
      name = "curl"
    }
    depends_on = [module.php, module.apache]
  }

  step "page" {
    file {
      path    = "/srv/app/index.php"
      content = "<?php echo PHP_VERSION, extension_loaded('mysqli') ? ' mysqli' : '';\n"
    }
  }
}
