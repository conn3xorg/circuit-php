variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "php_version" {
  type        = string
  default     = null
  description = "PHP version to install, such as \"8.4\". When null, the distribution's own: 8.4 on Debian 13, 8.3 on Ubuntu 24.04 and Rocky Linux 10, 8.5 on Fedora 45. Any other version comes from Ondřej Surý's repository on Debian and Ubuntu, and Remi's modular repository on the Red Hat family."

  validation {
    condition     = var.php_version == null || can(regex("^[5-9]\\.[0-9]+$", coalesce(var.php_version, "-")))
    error_message = "php_version is a major and minor version, such as \"8.4\"."
  }
}

variable "extensions" {
  type        = list(string)
  default     = []
  description = "PHP extensions to install, by the name PHP knows them by, such as [\"mysqli\", \"gd\", \"intl\"]. The circuit picks each distribution's package."

  validation {
    condition     = alltrue([for e in var.extensions : can(regex("^[a-z0-9_]+$", e))])
    error_message = "Each extension is a name such as \"mysqli\" or \"pdo_pgsql\", in lower case, without php- or .so."
  }
}

variable "ini" {
  type        = map(string)
  default     = {}
  description = "php.ini settings to override, such as { memory_limit = \"256M\", upload_max_filesize = \"64M\" }. They apply to PHP-FPM and the command line."

  validation {
    condition     = alltrue([for k, v in var.ini : can(regex("^[A-Za-z0-9_.\\[\\]-]+$", k)) && !strcontains(v, "\n")])
    error_message = "Each ini key is a php.ini directive such as \"date.timezone\", and each value fits on one line."
  }
}

variable "pools" {
  type = map(object({
    user              = optional(string)
    group             = optional(string)
    listen            = optional(string)
    listen_owner      = optional(string)
    listen_group      = optional(string)
    listen_mode       = optional(string, "0660")
    pm                = optional(string, "dynamic")
    max_children      = optional(number, 5)
    start_servers     = optional(number, 2)
    min_spare_servers = optional(number, 1)
    max_spare_servers = optional(number, 3)
    max_requests      = optional(number, 0)
    settings          = optional(map(string), {})
  }))
  default     = {}
  description = "PHP-FPM pools, by name. Each runs as user and group, the web server's user by default, and listens on a socket, by default /run/php/NAME.sock on Debian and Ubuntu or /run/php-fpm/NAME.sock on the Red Hat family, or on listen, a socket path or an address and port. A pool named www replaces the distribution's own."

  validation {
    condition     = alltrue([for name in keys(var.pools) : can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]*$", name))])
    error_message = "Pool names may use letters, digits, - and _."
  }

  validation {
    condition     = alltrue([for p in values(var.pools) : alltrue([for v in compact([p.user, p.group, p.listen_owner, p.listen_group]) : can(regex("^[a-z_][a-z0-9_.-]*$", v))])])
    error_message = "user, group, listen_owner and listen_group must be user or group names, such as \"www-data\"."
  }

  validation {
    condition     = alltrue([for p in values(var.pools) : p.listen == null || can(regex("^(/[^\\s;]+|([0-9.]+|\\[[0-9a-fA-F:]+\\]):[0-9]+|[0-9]+)$", coalesce(p.listen, "-")))])
    error_message = "A pool's listen is an absolute socket path, such as \"/run/php/app.sock\", or an address and port, such as \"127.0.0.1:9001\"."
  }

  validation {
    condition     = alltrue([for p in values(var.pools) : can(regex("^0?[0-7]{3}$", p.listen_mode))])
    error_message = "listen_mode is an octal mode, such as \"0660\"."
  }

  validation {
    condition     = alltrue([for p in values(var.pools) : contains(["static", "dynamic", "ondemand"], p.pm)])
    error_message = "A pool's pm is static, dynamic or ondemand."
  }

  validation {
    condition = alltrue([for p in values(var.pools) : alltrue([
      for n in [p.max_children, p.start_servers, p.min_spare_servers, p.max_spare_servers, p.max_requests] : n >= 0 && floor(n) == n
    ]) && p.max_children >= 1])
    error_message = "A pool's process counts are whole numbers, and max_children is 1 or more."
  }

  # PHP-FPM refuses to start a dynamic pool whose numbers don't fit together.
  validation {
    condition = alltrue([for p in values(var.pools) : p.pm != "dynamic" || (
      p.min_spare_servers >= 1 && p.min_spare_servers <= p.start_servers && p.start_servers <= p.max_spare_servers && p.max_spare_servers <= p.max_children
    )])
    error_message = "A dynamic pool needs 1 <= min_spare_servers <= start_servers <= max_spare_servers <= max_children."
  }

  validation {
    condition     = alltrue([for p in values(var.pools) : alltrue([for k, v in p.settings : can(regex("^[A-Za-z0-9_.\\[\\]-]+$", k)) && !strcontains(v, "\n")])])
    error_message = "Each key in settings is a pool directive, such as \"request_terminate_timeout\" or \"php_admin_value[memory_limit]\", and each value fits on one line."
  }
}

variable "install_composer" {
  type        = bool
  default     = false
  description = "Install Composer as /usr/local/bin/composer."
}

variable "composer_version" {
  type        = string
  default     = "2.11.0"
  description = "Composer release to install. Change composer_sha256 with it."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.composer_version))
    error_message = "composer_version is a release such as \"2.11.0\"."
  }
}

variable "composer_sha256" {
  type        = string
  default     = "9674f12a2a181100d889ebfd0b4510805b3e94cea57869b14b383753d602599b"
  description = "SHA-256 of composer.phar for composer_version, as published at https://getcomposer.org/download/VERSION/composer.phar.sha256sum."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.composer_sha256))
    error_message = "composer_sha256 is 64 lower-case hex characters."
  }
}
