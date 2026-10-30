# circuit-php

A Conn3x circuit that installs PHP with PHP-FPM, the extensions you name, your php.ini settings and your FPM pools. Put it next to [circuit-apache](https://github.com/conn3xorg/circuit-apache) or [circuit-nginx](https://github.com/conn3xorg/circuit-nginx), and [circuit-mysql](https://github.com/conn3xorg/circuit-mysql) or [circuit-mariadb](https://github.com/conn3xorg/circuit-mariadb), and you have a LAMP or LEMP stack described in one place.

PHP looks different on every distribution. Debian 13 calls the MySQL driver `php8.4-mysql` and keeps pools in `/etc/php/8.4/fpm/pool.d`; Rocky Linux calls it `php-mysqlnd` and keeps pools in `/etc/php-fpm.d`. The service is `php8.4-fpm` on one and `php-fpm` on the other, and so is the binary that tests the config. You name extensions the way PHP does, `mysqli` or `pdo_pgsql`, and the circuit finds the package. Every change shows up in `conn3x plan` as a diff, and PHP-FPM's own config test runs before each reload, so a broken pool fails the apply while the running PHP-FPM carries on with the pools it has.

You get your distribution's PHP unless you ask for another version. Then it comes from the repositories most people use for that: [Ondřej Surý's](https://deb.sury.org/) on Debian and Ubuntu, and [Remi Collet's](https://rpms.remirepo.net/) on Rocky Linux, AlmaLinux, RHEL and Fedora. Their signing keys ship with the circuit, in [files](files).

## Usage

```hcl
module "php" {
  source = "github.com/conn3xorg/circuit-php?ref=v0.1.0"

  hosts                = { web1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  extensions = ["mysqli", "pdo_mysql", "gd", "intl", "mbstring", "zip"]
  ini = {
    memory_limit        = "256M"
    upload_max_filesize = "64M"
    post_max_size       = "64M"
    expose_php          = "Off"
  }

  pools = {
    app = { pm = "ondemand", max_children = 10 }
  }

  install_composer = true
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

The `listen` output tells your web server where each pool is: `/run/php/app.sock` on Debian and Ubuntu, `/run/php-fpm/app.sock` on the Red Hat family. Hand it on as `module.php.listen["web1"]["app"]`, as in the next two sections, and the web server config stays right on either.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its packages and paths by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.web : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it with Apache on a throwaway container first, see [examples/local](examples/local).

### With Apache

circuit-apache serves the files, and hands `.php` to the pool's socket through `mod_proxy_fcgi`. Put the handler in the virtual host's `extra`:

```hcl
module "apache" {
  source = "github.com/conn3xorg/circuit-apache?ref=v0.1.0"

  hosts                = { web1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  vhosts = {
    app = {
      server_name   = "example.com"
      document_root = "/srv/app"
      extra         = <<-EOT
        DirectoryIndex index.php
        <FilesMatch "\.php$">
            SetHandler "proxy:unix:${module.php.listen["web1"]["app"]}|fcgi://localhost"
        </FilesMatch>
      EOT
    }
  }

  modules = ["proxy_fcgi"]
}
```

A pool's socket belongs to the web server's user unless you say otherwise: `www-data` on Debian and Ubuntu, `apache` on the Red Hat family, which is the user Apache runs as. That's the combination CI tests on all four distributions.

The socket's directory differs between the two families, and circuit-apache writes one config for all its hosts. With both families in one fleet, give circuit-apache a `for_each` over the hosts, so each gets its own path:

```hcl
module "apache" {
  source   = "github.com/conn3xorg/circuit-apache?ref=v0.1.0"
  for_each = local.hosts

  hosts = { (each.key) = each.value }
  # ... and module.php.listen[each.key]["app"] in the handler.
}
```

### With nginx

circuit-nginx serves one static site, so give PHP a server block of your own beside it, in `conf.d`:

```hcl
circuit "php_site" {
  hosts = { web1 = "203.0.113.10" }

  ssh {
    user             = "root"
    private_key_file = "~/.ssh/id_ed25519"
  }

  step "site" {
    file {
      path    = "/etc/nginx/conf.d/app.conf"
      content = <<-EOT
        server {
            listen 8080;
            server_name example.com;
            root /srv/app;
            index index.php;

            location ~ \.php$ {
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_pass unix:${module.php.listen["web1"]["app"]};
            }
        }
      EOT
    }
    depends_on = [module.nginx]
    notify     = [handler.reload]
  }

  handler "reload" {
    service {
      name   = "nginx"
      action = "reload"
    }
  }
}
```

nginx runs as `www-data` on Debian and Ubuntu, which owns the socket already. On the Red Hat family it runs as `nginx`, so give the pool `listen_group = "nginx"`: the socket's owner stays `apache`, and nginx connects through the group.

### A newer PHP

```hcl
php_version = "8.5"
```

On Debian and Ubuntu, `php8.5-fpm` and the extensions install beside the distribution's PHP, from Ondřej Surý's repository: `packages.sury.org` on Debian, his Launchpad PPA on Ubuntu. Every other version's PHP-FPM is stopped and disabled, so the pools' sockets are free for the new one. Going back to an older version, or to null, works the same way. The old packages stay installed, and `php` on the command line is set to the new version.

On the Red Hat family, the circuit adds Remi's modular repository and the one with the libraries it needs (remi-safe on Enterprise Linux, remi on Fedora), and switches dnf's `php` module to `remi-8.5`. PHP keeps its package names and paths, and what's already installed moves to the new version, up or down. Rocky Linux and AlmaLinux get EPEL as well, which Remi's packages need. On RHEL, set up EPEL first.

The keys ship for Debian 12 and 13, Ubuntu 22.04 and 24.04, Enterprise Linux 10 and Fedora 45. On another release, leave `php_version` null.

## What it does

On each host, in order:

1. With `php_version` set, adds Surý's or Remi's repository, as above.
2. Installs PHP-FPM and the command-line PHP, then a package for each extension in `extensions`. Many extensions are built into a package the circuit installs anyway, such as `ctype` or `openssl`, and that's fine. Each extension package restarts a running PHP-FPM as it installs, and a handful in a row can trip systemd's start limit; when that happens, the circuit clears it and starts PHP-FPM again.
3. Writes the `ini` settings to a file that loads after the distribution's own: `/etc/php/VERSION/mods-available/conn3x.ini`, linked into the `fpm` and `cli` `conf.d` as `99-conn3x.ini`, on Debian and Ubuntu; `/etc/php.d/99-conn3x.ini` on the Red Hat family. They apply to PHP-FPM and to `php` on the command line.
4. Writes a file for each pool in the pool directory, `NAME.conf`. On Debian and Ubuntu, points `php` at this version, and stops and disables any other version's PHP-FPM.
5. With `install_composer`, downloads Composer's `composer.phar` for `composer_version` to `/usr/local/bin/composer` and checks its SHA-256 against `composer_sha256`.
6. Runs PHP-FPM's config test, `php-fpm8.4 -t` or `php-fpm -t`, whenever the ini file or a pool changed, or a pool was added or taken out. When it fails, so does the apply, with PHP-FPM's error, before any reload.
7. Starts PHP-FPM now and at boot, and reloads it gracefully after the test passes or an extension is installed: workers finish their requests, then PHP-FPM starts again with the new config.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution and release, which decide the packages and paths.

### Pools

A pool runs as `user` and `group`, the web server's user by default, and listens on `listen`: a socket path or an address and port, such as `"127.0.0.1:9001"`. A socket gets `listen_owner`, `listen_group` and `listen_mode`, by default the web server's user and `0660`.

`pm` is `dynamic` by default, with `max_children` 5, `start_servers` 2, `min_spare_servers` 1 and `max_spare_servers` 3. `ondemand` starts workers as requests come in and stops them when they've been idle, which suits a small host with a quiet site. `static` keeps `max_children` running. For anything else, `settings` goes into the pool file as written:

```hcl
pools = {
  app = {
    user = "app"
    settings = {
      "request_terminate_timeout"     = "60s"
      "php_admin_value[memory_limit]" = "512M"
      "php_admin_flag[log_errors]"    = "on"
    }
  }
}
```

The distribution's own `www` pool stays as it is. A pool you name `www` replaces it. Take a pool out of `pools` and the next apply deletes its file and reloads PHP-FPM.

### Extensions

Name extensions in lower case, the way `extension_loaded()` takes them. The circuit knows where the two families put the ones that differ: `mysqli`, `pdo_mysql` and `mysqlnd` are in `php8.4-mysql` on Debian and `php-mysqlnd` on Rocky Linux; `dom`, `simplexml` and the other XML extensions are in `xml`; `zip`, `apcu`, `redis` and the other PECL extensions are `php-pecl-NAME` on the Red Hat family. Anything else is `phpVERSION-NAME` or `php-NAME`.

CI installs `mysqli`, `pdo_mysql`, `gd`, `intl`, `mbstring`, `zip`, `curl` and `xml` on every distribution and checks PHP loads each one.

### What it doesn't do

- Create the users pools run as. Use [circuit-users](https://github.com/conn3xorg/circuit-users) or your own steps for anything other than the web server's user.
- Configure the web server. See [With Apache](#with-apache) and [With nginx](#with-nginx).
- Remove extensions. Taking one out of `extensions` leaves its package installed.
- Uninstall an old version after a `php_version` change, on Debian and Ubuntu. Its PHP-FPM is stopped and disabled; remove its packages yourself when you're done with them.
- Label a pool's TCP port for SELinux. Use a socket, which works on any host, or label the port yourself.
- Remove PHP. Deleting the module leaves PHP installed and running with the last config.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `php_version` | string | `null` | PHP version, such as `"8.5"`. When null, the distribution's own: 8.4 on Debian 13, 8.3 on Ubuntu 24.04 and Rocky Linux 10, 8.5 on Fedora 45. See [A newer PHP](#a-newer-php). |
| `extensions` | list(string) | `[]` | Extensions to install, by the name PHP knows them by, such as `["mysqli", "gd", "intl"]`. See [Extensions](#extensions). |
| `ini` | map(string) | `{}` | php.ini settings, such as `{ memory_limit = "256M" }`. Values are written as given, so quote one the way php.ini needs. |
| `pools` | map(object) | `{}` | PHP-FPM pools, by name. Each takes optional `user`, `group`, `listen`, `listen_owner`, `listen_group`, `listen_mode`, `pm` (`static`, `dynamic` or `ondemand`), `max_children`, `start_servers`, `min_spare_servers`, `max_spare_servers`, `max_requests` and `settings`, a map of further pool directives. See [Pools](#pools). |
| `install_composer` | bool | `false` | Install Composer as `/usr/local/bin/composer`. |
| `composer_version` | string | `"2.11.0"` | Composer release to install. Change `composer_sha256` with it. |
| `composer_sha256` | string | The SHA-256 of 2.11.0 | SHA-256 of `composer.phar` for `composer_version`, as published at `https://getcomposer.org/download/VERSION/composer.phar.sha256sum`. |

## Outputs

| Name | Description |
| --- | --- |
| `listen` | Where each pool listens, by host and pool name, such as `{ web1 = { app = "/run/php/app.sock" } }`. |
| `service` | The PHP-FPM service on each host, such as `php8.4-fpm` or `php-fpm`, for a deploy hook that reloads it. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, with a package mirror the host can reach. With `php_version` set, the host has to reach `packages.sury.org`, `ppa.launchpadcontent.net` or `rpms.remirepo.net`, and with `install_composer`, `getcomposer.org`.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 with the distribution's PHP and Apache from circuit-apache, checks that the second plan has no changes, that PHP-FPM is running and the pool's socket belongs to the web server's user, fetches a PHP page through Apache that prints PHP's version and whether `mysqli` is loaded, and checks the extensions, an ini setting on the command line and `composer --version`. The CI containers run with SELinux off.

By hand, on arm64 containers of all four: switched each to another version and back with a plan that had no changes after each: Debian 13 from 8.4 to Surý's 8.5, Ubuntu 24.04 from 8.3 to Surý's 8.5 and back, Rocky Linux 10 from 8.3 to Remi's 8.5, and Fedora 45 from 8.5 down to Remi's 8.4. The PHP page through Apache showed the new version each time. With PHP-FPM stopped by systemd's start limit, installing another extension cleared it and started PHP-FPM again. An unknown pool directive stopped the apply with PHP-FPM's error while the running PHP-FPM kept serving. Adding a pool on a TCP port and taking it out again deleted its file and reloaded PHP-FPM. On Ubuntu 24.04, circuit-nginx with the server block from [With nginx](#with-nginx) served the PHP page.

On Ubuntu 24.04 and Rocky Linux 10 droplets (1 vCPU, 1 GB), with circuit-apache given a `for_each` as above, the example's checks passed and the second plan had no changes. Rocky Linux ran with SELinux enforcing: PHP-FPM ran confined as `httpd_t`, its socket was labelled `httpd_var_run_t`, Apache reached it, and the audit log had no denials. After a reboot, both came back serving the page, with a plan that had no changes. Then both moved to 8.5, Ubuntu from Surý's PPA and Rocky Linux from Remi's repository, and served the page again with no denials.

## License

MPL-2.0. See [LICENSE](LICENSE). PHP itself is under the PHP License, and Composer under MIT.
