---
title: "Deploying and managing Forgejo-aneksajo with podman and systemd"
date: 2024-07-31T08:00:00+02:00
author:
- Michael Hanke
tags:
- Forgejo
- self-hosted
- Git hosting
- podman
- systemd
cover:
  image: cover.webp
  alt: A screenshot of `systemd status` for a container process, and the Forgejo, podman, and systemd logos on top.
  relative: true
description: >
  Run Forgejo as a containerized service in user-space with SSH-passthrough on the host.
showToc: true
---

In a [previous article](/posts/forgejo-aneksajo/), I described my first steps
with [Forgejo-aneksajo](https://codeberg.org/matrss/forgejo-aneksajo), and
deploying it on my Raspberry Pi. This got me so excited that I started looking
into deploying it on more machines. However, I quickly realized that the
Docker-based approach I had used originally was not going to yield a setup
that I would see myself wanting to maintain for an extended period of time.

I knew I wanted something that I could completely `apt install` from
[Debian](https://www.debian.org), that is maintained there as a whole, and not
pieced together from only loosely connected components. With that in mind,
I spent a few days reading and learning about my options. 

I will put the conclusions upfront: *[Podman](https://podman.io) is an amazingly
flexible solution that is neatly integrated with [systemd](https://systemd.io),
and just the two together provide everything needed.*

Put simply, systemd is the tool that is used to manage pretty much anything
there is to manage on a modern Linux system. Whatever machine Forgejo will need
to run on for me, systemd is already a given.

Podman is in many ways like Docker, but a Docker that lets containers feel like
normal processes, although not as much as with [Singularity](https://en.wikipedia.org/wiki/Singularity_(software)). It is daemonless, and fully supports running containers as a
normal user ("rootless"). Podman knows directly how to handle images,
containers, and groups of related containers (pods). There is a lot to say
about podman, for which there is no space here.  A good place to start reading
is [redhat.com](https://www.redhat.com/en/topics/containers/what-is-podman) --
they are a driving force behind the podman development. I do want to note that
podman can even work with [SIF-formatted
containers](https://www.redhat.com/en/blog/expanding-podman-capabilities-deploy-sif-formatted-containers),
a technology that is widely used for scientific and HPC computing.

## Deployment target

In the following, I will describe an approach to deploying Forgejo that

- runs the service entirely in users space
- uses systemd to start, stop, and monitor the service
- exposes the service via a reverse proxy configuration (like
  `https://git.example.com`)
- uses "SSH-passthrough" to avoid running a Forgejo-internal SSH server
  and having to expose it in addition to an SSH server that is already run
  on the host
- builds the [Forgejo-aneksajo](https://codeberg.org/matrss/forgejo-aneksajo)
  container image from source, but otherwise only uses tools that are
  shipped with Debian 12+, or can be installed immediately from Debian's
  official package repository
- works on [Pi OS](https://www.raspberrypi.com/software), and off-the-shelf
  Debian 12 images offered by cloud/VPS providers.

Debian 12 provides podman version 4.3. However, there have been substantial
improvements of the systemd integration from version 4.4 onwards. In
anticipation of a future upgrade (Debian 13 is likely to ship with podman v5),
we will also be taking a brief look at these new features.


## Software dependencies

For the setup described here, we need the following packages (all available via
`apt install` from Debian) in addition to systemd -- which is assumed to be
available already.

- `podman` to build and run containers
- `caddy` to serve as a [reverse proxy](https://en.wikipedia.org/wiki/Reverse_proxy)
  for Forgejo. Any other solution, say [nginx](https://nginx.org/en), should work too,
  but is not described here.

## User setup

As a first step, we will create a dedicated `git` user on the target system.
This user will not only run the Forgejo service, but it will also be means to
provide SSH-based access to it, through the host system.

For clarity, we will perform all setup steps from a normal user account on the
target machine, and use `sudo` whenever elevated permissions are needed.

We are creating a regular (non-system) `git` user, planing to put all
Forgejo data under `/home/git`, so we can use `adduser` as simple as:

```sh
sudo adduser git --disabled-password
```

If we would leave out `--disabled-password`, we could set a password, and
enable pushing an existing Forgejo container from another machine directly into
this user account via something like (replace `example.com` with the target
host address):

```sh
podman image scp localhost/forgejo-aneksajo:7-latest-rootless git@example.com::
```

But for this article, we will be building the container directly on the target
machine.

At this point it is worth checking, if the `git` user is properly configured for
user namespace mapping. This is essential for running rootless containers,
where processes *inside* the container need to operate under different
users and groups. Both `/etc/subuid` and `/etc/subgid` must contain a mapping
definition for the `git` user at this point (actual values are system-dependent).

```console
❯ grep 'git' /etc/subuid
git:265536:65536
❯ grep 'git' /etc/subgid
git:265536:65536
```

[This article](https://www.redhat.com/sysadmin/controlling-access-rootless-podman-users) has some more background on user namespaces.

We plan to run the container as the `git` user, via systemd. This requires that
systemd is running a controlling process for this user, even when the user is not
logged in. This is achieved via systemd's [user lingering](https://www.freedesktop.org/software/systemd/man/247/loginctl.html#enable-linger%20USER%E2%80%A6):

```sh
sudo loginctl enable-linger git
```

This will also cause a working directory for the `git` user to be available
at `/run/user/$UID`.

## Service configuration

I want all configuration for the Forgejo setup to be underneath `/etc`, such
that it is tracked together with all the other configuration of that machine by
[etckeeper](http://etckeeper.branchable.com). I will not talk about this tool,
but it is indispensable for me.

All configuration will be placed under `/etc/forgejo`

```sh
sudo mkdir -p /etc/forgejo
```

### SSH-passthrough

We want SSH-based access to Forgejo to go through the `git` user and the SSH
server running on the *host* machine. This allows for disabling Forgejo's own
SSH server, and avoids having to expose a dedicated port for it. Any user will
use the generic `git@<host>/...` to access Forgejo, and only Forgejo will
determine whether a particular repository may be accessed, based on the used
SSH-key.  The [gitea
documentation](https://docs.gitea.com/next/installation/install-with-docker-rootless)
has some more information on this.

To make this work, we will create a small script that will serve as a
restricted login shell for the `git` user. We place this under `/etc` too,
because its purpose is to relay commands to the Forgejo service container,
identified by its name `forgejo`, which needs to be kept in sync with the rest of the
setup.

```sh
sudo mkdir /etc/forgejo/bin
# create the "login shell"
cat << EOT | sudo tee /etc/forgejo/bin/forgejo-shell
#!/bin/sh
# 
podman exec -i --env SSH_ORIGINAL_COMMAND="\$SSH_ORIGINAL_COMMAND" forgejo sh "\$@"
EOT
# make executable to function as a login shell
sudo chmod +x /etc/forgejo/bin/forgejo-shell
# set as login shell for the `git` user
sudo usermod --shell /etc/forgejo/bin/forgejo-shell git
```

The second key aspect of the SSH-passthrough setup is to relay access
authorization for the `git` user to Forgejo in the container. For that, we
place a configuration drop-in into the host's `sshd` configuration, calling
[gitea keys](https://docs.gitea.com/administration/command-line#keys) inside
the container to act as an
[AuthorizedKeysCommand](https://man.openbsd.org/sshd_config#AuthorizedKeysCommand).

```sh
cat << EOT | sudo tee /etc/ssh/sshd_config.d/forgejo-ssh-passthrough.conf
Match User git
  AuthorizedKeysCommandUser git
  AuthorizedKeysCommand /usr/bin/podman exec -i forgejo /usr/local/bin/gitea keys -c /etc/gitea/app.ini -e git -u %u -t %t -k %k 
EOT
```

The SSH server on the host needs to be restarted to load the new configuration.

```
sudo systemctl restart sshd
```

### Reverse-proxy setup

Eventually, the Forgejo container will run and offer http access via port `3000`.
We will tell podman to expose this port also on the host's port `3000`. This makes
Forgejo accessible via `http://localhost:3000`, or whatever hostname identifies the
machine.

However, we want to have proper HTTPS and use something like
`https://git.example.com`, where `example.com` is replaced with whatever your
domain is. This is (most) easily achieved with [Caddy](https://caddyserver.com),
including automated certificate generation for `https`.

First point your domain DNS configuration for host `git` to the server's (IP)
address. Afterwards, `sudo apt install caddy`, add the following to
`/etc/caddy/Caddyfile` and `sudo systemctl reload caddy` afterwards (again
replacing `example.com` with your domain).

```
# forgejo
git.example.com {
    reverse_proxy localhost:3000
}
```

Caddy with provising the necessary certificate automatically.

### Obtain a Forgejo-aneksajo container image

For the moment, images for a recent version are available from [Docker
Hub](https://hub.docker.com/r/mihanke/forgejo-aneksajo) (for architectures
`amd64` and `arm64`). Get one via, for example

```sh
podman pull docker.io/mihanke/forgejo-aneksajo:7-rootless-latest
```

However, if you do not have a want an account on Docker Hub, or a good enough
version is not available (yet), it is straightforward to build one from source.
The following script does exactly that. Importantly, we will build the image directly
with the `git` user.

```sh
# become the `git` user
sudo -u git -s

# clone the Forgejo-aneksajo sources into a `src/` directory
mkdir ~/src
git clone https://codeberg.org/matrss/forgejo-aneksajo.git ~/src/forgejo-aneksajo
# check out the release we want to build
git -C ~/src/forgejo-aneksajo checkout v7.0.5-git-annex1

# set up and check that systemd is functional for the `git` user
export XDG_RUNTIME_DIR="/run/user/$UID"
systemctl --user status

# build the image
podman build \
  --tag forgejo-aneksajo:7.0.5-rootless \
  --tag forgejo-aneksajo:7-latest-rootless \
  -f ~/src/forgejo-aneksajo/Dockerfile.rootless
```

The `podman build` call points to `Dockerfile.rootless`. This is important.
The "rootless" container setup works substantially different compared to the
regular one. Only the "rootless" setup is covered here!


### Initial Forgejo launch

For the initial start of Forgejo, we will make the configuration directory
writable for the `git` user, because Forgejo will place a default configuration
at `/etc/forgejo/app.ini`, and it will behave differently when this file
already exists, and fail when the directory is not writable. Later, we will
remove these permissions again.

```
sudo chown git: /etc/forgejo
```

We could also immediately deposit a complete configuration at
`/etc/forgejo/app.ini`. However, the initial configuration wizard will pick up
some environment properties (this is the reason why we configured caddy
already), and yield a functional setup that needs minimal adjustment.  It will
also produce a configuration suitable for the deployed Forgejo version, even
some time in the future for a different Forgejo release.

The following script will ready the environment for Forgejo,
create a container, generate a systemd service unit for it,
and start the container (via systemd) for the first time.
All of this is done with the `git` user.

A couple of things are important:

- we create a `gitea/` and a `git/` directory that will contain
  Forgejo instance related information separate from the Git
  repositories host by that instance. The latter will just be a
  standard collection of bare Git repositories (with an annex).
- we bind the host's configuration at `/etc/forgejo` to the location
  Forgejo expects in the container
- the name of the container is set to `forgejo`, while the
  corresponding systemd service is called `container-forgejo`.
- the `forgejo` container will only expose port `3000` for http(s)
  access and the web UI.
- we map the `git` user on the host system to the `git` user inside
  the container (it has `uid=1000`), such that any files created by
  it within the container, are owned by the use running the container
  on the host. In other words, all files created will be owned by
  the `git` user on the host.

```sh
# the following code runs as the `git` user
sudo -u git -s

# create the directory to host the Forgejo instance data
# and the repositories
mkdir ~/gitea ~/git

# `systemctl` needs `XDG_RUNTIME_DIR`
export XDG_RUNTIME_DIR="/run/user/$UID"

# create the container
podman container create \
  --name forgejo \
  -p 3000:3000 \
  -v "$HOME/gitea:/var/lib/gitea:Z" \
  -v "$HOME/git:/var/lib/gitea/git:Z" \
  -v '/etc/forgejo:/etc/gitea:Z' \
  --userns 'keep-id:uid=1000,gid=1000' \
  localhost/forgejo-aneksajo:7-latest-rootless

# generate a systemd service unit from the container
mkdir -p ~/.config/systemd/user
( cd ~/.config/systemd/user \
  && podman generate systemd \
       --restart-policy=always --new --files --name forgejo )

# we only needed the container to create the service unit.
# otherwise, we create a new one each time, no need to keep this one
# around
podman rm forgejo

# start for the first time
systemctl --user start container-forgejo
```

If this looks a bit clunky to you, you are not alone with this opinion, and you'll be glad that starting with podman version 4.4+ [this can be done much nicer](#setup-with-podman-v44-and-later).

For podman v4.3, we create a container, similar to what would need to be done
with Docker, but only to generate a systemd service unit from the setup.
Afterwards, we can immediately remove the container again, because the service
unit will create a new one, each time it starts (`--new`). Take a look at the
`.service` file generated in `.config/systemd/user/`. In case something does
not work when launching the container, it can help to comment out the
`Restart=` line for better error reporting.

Once the container is running, open a webbrowser and point it to the web UI.
With the reverse-proxy setup done as described above, go to
`https://git.example.com` (replacing `example.com` with your domain).  This
will bring up the setup wizard. All values can be kept at their default to
configure a Forgejo instance that uses SQLite as a database. A setup with a
dedicated database server/container is out of scope for this article. That being said,
a podman "pod" would be a suitable vehicle to implement this.

Now push the button to initialize the Forgejo instance, which will populate the
`gitea/` directory in the `git` user's home directory.

Go ahead and register a first user via the web UI now. This user will
automatically get administrator status. More users can be elevated to this role
later on.

At this point, we can stop the container again:

```sh
systemctl --user stop container-forgejo
```

(executed as the `git` user).

### Finalizing

Initializing the Forgejo instance has created a default configuration at
`/etc/forgejo/app.ini`, which is already sensible, but can be tuned further. A
discussion of all options is out of scope here. Use the [Forgejo
documentation](https://forgejo.org/docs/latest/admin/config-cheat-sheet/) as a
starting point to learn about the possibilities.

That being said, here are a few configuration snippets that are noteworthy, and can be added/adjusted as desired.

```
[annex]
ENABLED = true
```

This enables [git-annex](https://git-annex.branchable.com) support. Without it,
Forgejo-aneksajo behaves just like a vanilla Forgejo.

```
[server]
DISABLE_SSH = false
; we use ssh-passthrough, no need for the internal ssh server
START_SSH_SERVER = false
; remove custom port from displayed URLs
SSH_PORT = 22
```

With the SSH-passthrough configuration targeted here, we can disabled Forgejo's
internal SSH server entirely. However, we do *not* want to disable its SSH
features entirely! Setting the `SSH_PORT` to the standard `22` causes Forgejo
to stop putting a custom port into the SSH URLs it displays. This is
important, because SSH-access is happening via the SSH server running on the
host, on that port `22`.

```
[service]
DISABLE_REGISTRATION = true
```

Disabling the registration feature can be a good idea. Accounts can still be
created by an admin user via the web UI. This is likely sufficient for a small
user base, and avoids having to deal with undesired sign-ups by random agents.

Now it is a good idea to restrict the access to the configuration again.

```sh
sudo chown root:git /etc/forgejo/app.ini
sudo chmod 640 /etc/forgejo/app.ini
```

We make the configuration file writeable by `root` only, and readable by the
`git` group (the main group of the `git` user) only. This prevents modification
of the configuration by the user that runs the Forgejo service, and also makes
adding secrets to the configuration file slightly more secure.  Adding a secret
may be necessary for setting up email SMTP server access.

At this point, and as the `git` user, we can tell systemd to launch the
container at boot, and restart it now.


```sh
systemctl --user enable container-forgejo
systemctl --user start container-forgejo
```

The service should now be fully functional. It is a good idea to test the essentials:

- reboot the machine and make sure the container is started automatically by
  and for the `git` user
- add an SSH-key for a Forgejo user via the web UI, and test cloning and push
  from another machine

## Setup with podman v4.4 and later

Podman v4.4 introduced [Quadlets](https://www.redhat.com/sysadmin/quadlet-podman),
which address some of the clunkier parts of the setup procedure shown above.

With quadlets it is no longer necessary to generate a systemd service unit from
an existing podman container, and then place it into a location recognized by
systemd, to be able to enabled the service.

Instead, podman ships a [systemd generator that auto-generates transient
service
units](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
from quadlet files. These files are similar to service units in syntax and
semantics.  Quadlets can define containers, volumes, networks, and more. They
more-or-less replace "compose" files, but in a way that is tightly integrated
with systemd.

A proper discussion of this feature is well beyond the scope of this article.
However, here is a small example that hopefully illustrates how nice it is.

Quadlets for user-space containers can be placed into a number of locations
(see the
[documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)),
including underneath `/etc`, such that they are also within `etckeeper`'s
reach.

```sh
sudo mkdir -p /etc/containers/systemd/users/$(id -u git)
```

Now we can place a container definition into this directory. We name the
file `container-forgejo.container`. Only the `.container` extension makes it
a container specification. We only add the `container-` prefix to keep
the name of the result service unit the same as with the podman v4.3 setup.

```sh
cat << EOT | sudo tee /etc/containers/systemd/users/$(id -u git)/container-forgejo.container
[Unit]
Description=Forgejo-aneksajo container
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=container-forgejo
# image to use for the container
# if the image is not available locally already, it is pulled, so
# something like the following is also possible
#Image=docker.io/mihanke/forgejo-aneksajo:7-latest-rootless
Image=localhost/forgejo-aneksajo:7-latest-rootless
PublishPort=3000:3000
Volume=%h/gitea:/var/lib/gitea:Z
Volume=%h/git:/var/lib/gitea/git:Z
Volume=/etc/forgejo:/etc/gitea:Z
# the user running 'git' forgejo inside the container is 1000:1000, we
# map it to the user running the forgejo container on the host
UserNS=keep-id:uid=1000,gid=1000
Network=host

[Service]
Restart=always
TimeoutStartSec=900
WorkingDirectory=%t

[Install]
# Start by default on boot
WantedBy=default.target
EOT
```

The content shown above roughly matches the container setup we used before. It looks
like a service unit specification and can use all of systemd's features (templating, placeholders, etc.). Only the `[Container]` is specific to this quadlet.

This quadlet makes any direct use of podman commands shown above fully
obsolete. With this file in place (and the old service unit removed), the `git`
user can `systemctl --user start|stop container-forgejo` immediately.  No
static `.service` file will be generated anymore. It is also not necessary to
explicitly `enable` the container service. This is handled automatically by
systemd's dependency management.

## Conclusions

The setup describe here is a lot nicer than [the one I created
originally](/posts/forgejo-aneksajo). Not only are all software dependencies
outside the container coming from Debian directly, but also the integration
with the host system is much better. The containerized Forgejo service
is managed by systemd in the same way all other services are managed.
Forgejo runs under a non-privileged host account, and the SSH-access via that
`git` user feels just like one is used to from GitHub/Lab and friends.

I will likely revisit the Forgejo setup again when it is time to deploy [a
runner for its
actions](https://forgejo.org/docs/latest/admin/actions/#forgejo-runner). But
for now I am rather happy how this turned out.

One could argue that it is no less difficult to understand enough of systemd to
be able to do this, than would be for Docker. However, I think investing the
learning into systemd has benefits well beyond the world of containers. It was
well worth the time for me.
