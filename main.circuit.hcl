# Facts give each host's distribution and release. Debian and Ubuntu put
# the PHP version in every package name and path, so the circuit needs to
# know which version each release ships; the Red Hat family has one php-fpm
# whatever the version.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }

    postcondition {
      condition     = self.os_family != "debian" || var.php_version != null || contains(keys(local.distro_php), "${self.os_id}/${self.os_version}")
      error_message = "Host ${each.key} runs ${self.os_id} ${self.os_version}, and the circuit doesn't know which PHP it ships. Set php_version."
    }

    # The repositories' signing keys ship with the circuit, one per release
    # family, so only these releases can take a php_version.
    postcondition {
      condition = var.php_version == null || (
        self.os_family == "debian" ? contains(keys(local.codename), self.os_version) :
        self.os_id == "fedora" ? contains(keys(local.remi_key), "fedora${self.os_version}") :
        contains(keys(local.remi_key), "el${split(".", self.os_version)[0]}")
      )
      error_message = "Host ${each.key} runs ${self.os_id} ${self.os_version}. php_version works on Debian 12 and 13, Ubuntu 22.04 and 24.04, Enterprise Linux 10 and Fedora 45; leave it null for the distribution's own PHP."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  deb_hosts = { for name, h in var.hosts : name => h if local.family[name] == "debian" }

  # The PHP each Debian and Ubuntu release ships.
  distro_php = { "debian/12" = "8.2", "debian/13" = "8.4", "ubuntu/22.04" = "8.1", "ubuntu/24.04" = "8.3" }
  codename   = { "12" = "bookworm", "13" = "trixie", "22.04" = "jammy", "24.04" = "noble" }
  version    = { for name, f in local.family : name => f == "debian" ? coalesce(var.php_version, lookup(local.distro_php, "${local.os[name]}/${data.conn3x_host.facts[name].os_version}", "unknown")) : "" }

  # Ondřej Surý builds every supported PHP for Debian on packages.sury.org,
  # and for Ubuntu in a Launchpad PPA. Remi Collet does the same for the Red
  # Hat family as module streams, which replace the distribution's php
  # packages in place, with the same names and paths.
  sury_hosts = { for name, h in local.deb_hosts : name => h if var.php_version != null }
  remi_hosts = { for name, h in var.hosts : name => h if var.php_version != null && local.family[name] == "redhat" }
  php_re     = replace(coalesce(var.php_version, "-"), ".", "\\.")
  epel_hosts = { for name, h in local.remi_hosts : name => h if contains(["rocky", "almalinux"], local.os[name]) }
  remi_key   = { el10 = "remi-el10.asc", fedora45 = "remi-fedora45.asc" }
  remi = {
    for name in keys(local.remi_hosts) : name => local.os[name] == "fedora" ? {
      path = "fedora/$releasever", libs = "remi", key = lookup(local.remi_key, "fedora${data.conn3x_host.facts[name].os_version}", "")
      } : {
      path = "enterprise/$releasever_major", libs = "safe", key = lookup(local.remi_key, "el${split(".", data.conn3x_host.facts[name].os_version)[0]}", "")
    }
  }

  layout = {
    for name, f in local.family : name => f == "debian" ? {
      prefix   = "php${local.version[name]}-"
      service  = "php${local.version[name]}-fpm"
      fpm      = "php-fpm${local.version[name]}"
      pool_dir = "/etc/php/${local.version[name]}/fpm/pool.d"
      ini      = "/etc/php/${local.version[name]}/mods-available/conn3x.ini"
      run_dir  = "/run/php"
      web_user = "www-data"
      } : {
      prefix   = "php-"
      service  = "php-fpm"
      fpm      = "php-fpm"
      pool_dir = "/etc/php-fpm.d"
      ini      = "/etc/php.d/99-conn3x.ini"
      run_dir  = "/run/php-fpm"
      web_user = "apache"
    }
  }

  other_fpm = { for name, l in local.layout : name => "systemctl list-unit-files --no-legend 'php*-fpm.service' | awk '{print $1}' | grep -vx '${l.service}.service'" }

  # Extensions packaged under another name, by family. The rest are in a
  # package named after the extension, such as php8.4-gd or php-gd. common
  # is the package that has an extension built in.
  builtin = ["calendar", "ctype", "exif", "fileinfo", "filter", "ftp", "gettext", "hash", "iconv", "json", "openssl", "pcre", "phar", "session", "sockets", "tokenizer", "zlib"]
  extension_package = {
    debian = merge(
      { for e in concat(local.builtin, ["ffi", "pdo", "posix", "shmop", "sodium", "sysvmsg", "sysvsem", "sysvshm"]) : e => "common" },
      { mysqli = "mysql", mysqlnd = "mysql", pdo_mysql = "mysql", pdo_pgsql = "pgsql", pdo_sqlite = "sqlite3" },
      { for e in ["dom", "simplexml", "xmlreader", "xmlwriter", "xsl"] : e => "xml" },
    )
    redhat = merge(
      { for e in concat(local.builtin, ["bz2", "curl"]) : e => "common" },
      { mysqli = "mysqlnd", pdo_mysql = "mysqlnd", pdo_pgsql = "pgsql", sqlite3 = "pdo", pdo_sqlite = "pdo" },
      { for e in ["dom", "simplexml", "xmlreader", "xmlwriter", "xsl"] : e => "xml" },
      { for e in ["posix", "shmop", "sysvmsg", "sysvsem", "sysvshm"] : e => "process" },
      { for e in ["apcu", "igbinary", "imagick", "memcached", "mongodb", "redis", "zip"] : e => "pecl-${e}" },
    )
  }

  listen = {
    for host, l in local.layout : host => {
      for name, p in var.pools : name => coalesce(p.listen, "${l.run_dir}/${name}.sock")
    }
  }

  pool_config = {
    for host, l in local.layout : host => {
      for name, p in var.pools : name => join("\n", concat(
        [
          "; Written by Conn3x. Changes here are overwritten on the next apply.",
          "[${name}]",
          "user = ${coalesce(p.user, l.web_user)}",
          "group = ${coalesce(p.group, p.user, l.web_user)}",
          "listen = ${local.listen[host][name]}",
        ],
        startswith(local.listen[host][name], "/") ? [
          "listen.owner = ${coalesce(p.listen_owner, l.web_user)}",
          "listen.group = ${coalesce(p.listen_group, p.listen_owner, l.web_user)}",
          "listen.mode = ${p.listen_mode}",
        ] : [],
        [
          "pm = ${p.pm}",
          "pm.max_children = ${p.max_children}",
        ],
        p.pm == "dynamic" ? [
          "pm.start_servers = ${p.start_servers}",
          "pm.min_spare_servers = ${p.min_spare_servers}",
          "pm.max_spare_servers = ${p.max_spare_servers}",
        ] : [],
        ["pm.max_requests = ${p.max_requests}"],
        [for k, v in p.settings : "${k} = ${v}"],
        [""],
      ))
    }
  }

  ini_config = join("\n", concat(
    ["; Written by Conn3x. Changes here are overwritten on the next apply.", "; priority=99"],
    [for k, v in var.ini : "${k} = ${v}"],
    [""],
  ))
}

circuit "php_epel" {
  hosts = local.epel_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Remi's packages need libraries from EPEL. Rocky Linux and AlmaLinux ship
  # epel-release in their own extras repository; RHEL doesn't, so EPEL has
  # to be on there already.
  step "release" {
    package {
      name = "epel-release"
    }
  }
}

circuit "php_remi" {
  hosts = local.remi_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The modular repository has PHP itself. The libraries some extensions
  # need in newer versions than the distribution's, such as libzip, are in
  # remi-safe on Enterprise Linux and in remi on Fedora.
  step "repo" {
    for_each = toset(["modular", "libs"])
    repository {
      name = "remi-${item.value}"
      url  = "https://rpms.remirepo.net/${local.remi[each.key].path}/${item.value == "libs" ? local.remi[each.key].libs : item.value}/$basearch/"
      key  = file("${path.module}/files/${local.remi[each.key].key}")
    }
    depends_on = [conn3x_package.php_epel__release]
  }

  # Switches the php module to Remi's stream for php_version. Packages
  # already installed from another stream move to the new one: distro-sync
  # moves them up, and on Fedora, whose dnf5 distro-sync won't go below what
  # is installed, downgrade moves them down. The guard checks the result.
  step "stream" {
    command {
      command = "dnf -y module reset php && dnf -y module enable php:remi-${var.php_version} && if rpm -q --quiet php-common; then dnf -y distro-sync 'php*' && { dnf -y downgrade 'php*' || true; }; fi"
      unless  = "dnf -q module list --enabled php 2>/dev/null | grep -Eq '^php +remi-${local.php_re} ' && { ! rpm -q --quiet php-common || rpm -q --qf '%%{VERSION}' php-common | grep -q '^${local.php_re}\\.'; }"
    }
  }
}

circuit "php_sury" {
  hosts = local.sury_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "repo" {
    repository {
      name       = "php"
      url        = local.os[each.key] == "ubuntu" ? "https://ppa.launchpadcontent.net/ondrej/php/ubuntu" : "https://packages.sury.org/php"
      key        = file("${path.module}/files/${local.os[each.key] == "ubuntu" ? "ondrej-php-ppa.asc" : "sury-php.asc"}")
      suites     = [local.codename[data.conn3x_host.facts[each.key].os_version]]
      components = ["main"]
    }
  }
}

circuit "php" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "fpm" {
    package {
      name = "${local.layout[each.key].prefix}fpm"
    }
    depends_on = [conn3x_repository.php_sury__repo, conn3x_command.php_remi__stream]
  }

  step "cli" {
    package {
      name = "${local.layout[each.key].prefix}cli"
    }
  }

  step "extension" {
    for_each = toset(var.extensions)
    package {
      name = "${local.layout[each.key].prefix}${lookup(local.extension_package[local.family[each.key]], item.value, item.value)}"
    }
    notify = [handler.reload]
  }

  # Each extension package restarts a running PHP-FPM as it installs: an rpm
  # file trigger on the Red Hat family, a dpkg trigger on Debian. Installed
  # one by one, a few of them restart it more often than systemd's start
  # limit allows, and systemd then refuses to start it at all. Apache can
  # start PHP-FPM early on the Red Hat family, where php-fpm adds a Wants=
  # to httpd.service. Clears the refusal and starts it again.
  step "start_limit" {
    command {
      command  = "systemctl reset-failed ${local.layout[each.key].service} && systemctl start ${local.layout[each.key].service}"
      unless   = "! systemctl -q is-failed ${local.layout[each.key].service}"
      triggers = { for k, v in conn3x_package.php__extension : k => v.revision if startswith(k, "${each.key}/") }
    }
  }

  step "ini" {
    file {
      path      = local.layout[each.key].ini
      content   = local.ini_config
      on_remove = "delete"
    }
  }

  step "pool" {
    for_each = var.pools
    file {
      path      = "${local.layout[each.key].pool_dir}/${item.key}.conf"
      content   = local.pool_config[each.key][item.key]
      on_remove = "delete"
    }
  }

  # Conn3x downloads with curl or wget on the host, and minimal Debian
  # images have neither.
  step "curl" {
    for_each = var.install_composer ? ["curl"] : []
    package {
      name = item.value
    }
  }

  step "composer" {
    for_each = var.install_composer ? ["composer"] : []
    download {
      url    = "https://getcomposer.org/download/${var.composer_version}/composer.phar"
      sha256 = var.composer_sha256
      dest   = "/usr/local/bin/composer"
      mode   = "0755"
    }
  }

  # PHP-FPM's own config test, after the pool and ini files change and
  # before the reload, so a broken pool fails the apply and the running
  # PHP-FPM keeps the pools it has. It runs, and reloads, when a pool is
  # added or taken out too.
  step "check" {
    command {
      command = "${local.layout[each.key].fpm} -t"
      triggers = {
        ini   = conn3x_file.php__ini[each.key].revision
        pools = { for k, v in conn3x_file.php__pool : k => v.revision if startswith(k, "${each.key}/") }
        names = keys(var.pools)
      }
    }
    depends_on = [conn3x_link.php_deb__ini, conn3x_command.php_deb__other_versions]
    notify     = [handler.reload]
  }

  step "running" {
    service {
      name    = local.layout[each.key].service
      state   = "started"
      enabled = true
    }
  }

  # A graceful reload: workers finish the requests they're serving, then
  # PHP-FPM starts again with the new pools and php.ini.
  handler "reload" {
    service {
      name   = local.layout[each.key].service
      action = "reload"
    }
  }
}

# Debian and Ubuntu: the ini file goes in mods-available and is linked into
# each SAPI's conf.d, as phpenmod does.
circuit "php_deb" {
  hosts = local.deb_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "ini" {
    for_each = ["fpm", "cli"]
    link {
      path      = "/etc/php/${local.version[each.key]}/${item.value}/conf.d/99-conn3x.ini"
      target    = local.layout[each.key].ini
      on_remove = "delete"
    }
    depends_on = [conn3x_file.php__ini]
  }

  # Debian's alternatives point php at the highest version installed, which
  # after a move down isn't this one.
  step "cli" {
    command {
      command = "update-alternatives --set php /usr/bin/php${local.version[each.key]}"
      unless  = "[ \"$(readlink -f /usr/bin/php)\" = /usr/bin/php${local.version[each.key]} ]"
    }
  }

  # A new php_version installs beside the old one, whose PHP-FPM would keep
  # the pools' sockets. Stops and disables every other version's PHP-FPM.
  step "other_versions" {
    command {
      command = "${local.other_fpm[each.key]} | xargs -r systemctl disable --now"
      unless  = "for u in $(${local.other_fpm[each.key]}); do systemctl -q is-active $u || systemctl -q is-enabled $u && exit 1; done; true"
    }
  }
}
