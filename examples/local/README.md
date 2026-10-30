# Local example

Applies circuit-php to a throwaway Rocky Linux 10 container with systemd, with Apache from [circuit-apache](https://github.com/conn3xorg/circuit-apache) in front. You need Conn3x and Podman.

PHP-FPM runs one pool, `app`, started on demand, with the MySQL, GD, intl, mbstring, zip, curl and XML extensions, two php.ini settings and Composer. Apache serves `app.example.test` on `:8080` from `/srv/app` and hands `.php` files to the pool's socket. A third circuit in `main.tf` writes a PHP page that prints PHP's version and whether `mysqli` is loaded, and installs curl.

On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To fetch the page:

```sh
ssh -p 2298 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 curl -s -H 'Host: app.example.test' localhost:8080
```

It prints something like `8.3.36 mysqli`.

`up.sh` listens on `127.0.0.1:2298`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, the key and the state.
