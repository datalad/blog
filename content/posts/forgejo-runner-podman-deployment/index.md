---
title: "Operate a runner for Forgejo actions with podman and systemd"
date: 2024-08-01T12:09:00+02:00
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
  alt: TODO
  relative: true
description: >
  TODO
---

This article is part three of a series on self-hosting
[Forgejo-aneksajo](https://codeberg.org/matrss/forgejo-aneksajo).  If you have
not read [part one](/posts/forgejo-aneksajo/), and
[part two](/posts/forgejo-aneksajo-podman-deployment/) already, check them out.
In many ways, this article is a direct continuation.

If you are self-hosting a Forgejo instance already, it can make a lot of sense
to also operate a runner for its
[actions](https://forgejo.org/docs/next/user/actions/). Forgejo' actions will
feel very familiar to anyone who has used [Github's
actions](https://github.com/features/actions). That being said, the [Forgejo
documentation](https://forgejo.org/docs/next/user/actions/) clearly states that
"they are not and will never be identical".

Nevertheless, the concepts, and even the syntax are the same. Actions are
containerized workflows that can be used for more-or-less arbitrary purposes,
based on action specifications contained in individual repositories. Forgejo
can trigger actions based on a number of events. In order to actually execute
an action, it needs at least one runner registered at a Forgejo instance.

In the following, we will deploy a runner and register it with a Forgejo
instance.  We will, again, use the podman-plus-systemd approach from [the
previous post](/posts/forgejo-aneksajo-podman-deployment/) on setting up
Forgejo itself in this way. The outcome will be a containerized runner service,
completely in user space. This runner deployment could be on the same machine
that Forgejo runs on, or an entirely different one.

I will focus on the essential steps to get a runner up and talking to Forgejo.
I will not cover every aspect of configuration runners or using actions. The
[Actions Administrator guide](https://forgejo.org/docs/latest/admin/actions/)
 and the [Actions User guide](https://forgejo.org/docs/latest/user/actions/)
cover this in depth.

## Target setup

What we want to achieve is

- operate a runner in a podman container, managed by systemd
- keep the runner configuration under the host's `/etc`,
  as [before](/posts/forgejo-aneksajo-podman-deployment/#service-configuration),
  to keep it tracked by [etckeeper](http://etckeeper.branchable.com)
- all actions, their containers, caches, etc. shall all be executed and kept
  by a dedicated user account


## Software dependencies

If Forgejo is already set up as described [in my previous
post](/posts/forgejo-aneksajo-podman-deployment), everything should already
be installed. If not, we need systemd (almost certainly running already),
and the Debian packages of `podman`, and `crun` -- just `apt install` them.

```sh
sudo apt install podman crun
```

Podman v4.3 (as in the current Debian 12) is fine. Later version also work, and
can even provide [a nicer service
setup](/posts/forgejo-aneksajo-podman-deployment/#setup-with-podman-v44-and-later).
The "lightweight OCI runtime" `crun` is needed, because podman will/might use
it for running further containers with particular actions within the scope of
the containerized runner. Podman is pretty much impersonating a Docker that
runs inside another Docker container.

## User setup

Just like for Forgejo, we create a dedicated user. This time called
`forgejo-runner`. We enabled "lingering" to have systemd run services
for this user when it is not logged in.

```
sudo adduser forgejo-runner --disabled-password --disabled-login
sudo loginctl enable-linger forgejo-runner
```

We will place the configuration of the runner at `/etc/forgejo-runner`, and
make it writable for the `forgejo-runner` user, for now, because we will
generate a default configuration in second.

```
sudo mkdir /etc/forgejo-runner
sudo chown forgejo-runner: /etc/forgejo-runner
```

## Podman and service setup

The rest of the setup is done as the `forgejo-runner` user.

```
sudo -u forgejo-runner -s
```

We need `XDG_RUNTIME_DIR` to point to the right location. Place something
like the following into `.zshenv` or `.basrc`, depending on your shell setup,
to automate this.

```sh
if [ -z "${XDG_RUNTIME_DIR}" ]; then
  XDG_RUNTIME_DIR=/run/user/$(id -u)
  export XDG_RUNTIME_DIR
fi
```

Now we can obtain the container with the runner. In this example, we are using
the currently latest version 3.5.0 on `amd64`, but [others are available
too](https://code.forgejo.org/forgejo/-/packages/container/runner).

```
podman pull code.forgejo.org/forgejo/runner:3.5.0-amd64
```

Now we can use the runner itself to generate a default configuration that we
place at `/etc/forgejo-runner/runner.yaml`.

```sh
podman run \
  --rm -it --user 0:0 \
  code.forgejo.org/forgejo/runner:3.5.0-amd64 \
  forgejo-runner generate-config > /etc/forgejo-runner/runner.yaml
```

This configuration is basically ready-to-go. However, to work with podman,
we must adjust the `docker_host` setting (to not be empty). Moreover,
I dislike the runner registration file to be call `.runner`. There are
way to many things called "runner" already, so I will name it `.registration`.
The following `sed` call makes these changes.

```sh
sed -e 's,file: .runner,file: .registration,' -e 's,docker_host:.*$,docker_host: "-",' \
  -i /etc/forgejo-runner/runner.yaml
```

Now we can create the directory where the runner will place all its runtime
data.

```sh
mkdir -p ~/runner
```

Now we can register the new runner with Forgejo. This requires a token that can be
obtained via the site administration web UI, as shown in the following screenshot.

{{< figure
    src="gettoken.webp"
    caption="TODO"
    alt="TODO"
    >}}

Push the "Create new runner button" and replace `<TOKEN>` in the following command
with the displayed secret. You also need to invent a name for the new runner
(`<NAME-OF-RUNNER>`), and point it to your Forgejo site.

```sh
podman run \
  --rm -it --user 0:0 \
  -v ~/runner:/data \
  -v /etc/forgejo-runner:/data/config \
  code.forgejo.org/forgejo/runner:3.5.0-amd64 \
  forgejo-runner register \
    --config config/runner.yaml \
    --no-interactive \
    --token vADHNZjinRNTC0fStzLV3zTrjgo4H9KSCC8JiEGJ \
    --name <NAME-OF-RUNNER> \
    --instance <FORGEJO-SITE-URL>
```

The above command bindmount both runtime directory and configuration directory
in the container.  Passing the `--config` flag to `forgejo-runner register` is
essential here.

Next we need to enable socket-based communication for podman in this user account.
This is how the runner container can communicate with the host user's podman
to pull and execute additional containers.

```sh
systemctl --user enable --now podman.socket
```

Now we are ready to launch the runner container with the daemon setup for the
first time, only to be able to generate a systemd service unit from it.
[Quadlets simplify
this](/posts/forgejo-aneksajo-podman-deployment/#setup-with-podman-v44-and-later)
with podman v4.4+, but here we use an approach that works with Debian 12's v4.3.

```sh
podman run \
  --name forgejo-runner \
  --detach --rm --user 0:0 \
  -v ~/runner:/data \
  -v /etc/forgejo-runner:/data/config \
  -v /run/user/$(id -u)/podman/podman.sock:/var/run/docker.sock:rw \
  -e DOCKER_HOST=unix:///var/run/docker.sock \
  code.forgejo.org/forgejo/runner:3.5.0-amd64 \
  forgejo-runner --config /data/config/runner.yaml daemon
```

This time we also bind the podman socket and announce it in the container. Again,
Passing the `--config` flag to `forgejo-runner` is essential.

Now we generate the service unit, and can dispose of the container afterwards.

```sh
( mkdir -p ~/.config/systemd/user \
  && cd ~/.config/systemd/user \
  && podman generate systemd \
       --restart-policy=always --new --files --name forgejo-runner )
podman stop forgejo-runner
```

At this point we are ready to launch, stop, and inspect the containerized runner
service with standard `systemctl` commands, as the `forgejo-runner` user.

```sh
# launch
systemctl --user start container-forgejo-runner
# check that it is running
systemctl --user status container-forgejo-runner
# enable to be brought up at boot automatically
systemctl --user enable container-forgejo-runner
```

When visiting the Forgejo runner listing in the site administration web UI
again, the new runner should now be listed and labeled as "idle". Try setting up
a test action now, and see if it runs successfully.

If everything works, we can remove write access to the runner configuration
again.

```sh
sudo chown -R root: /etc/forgejo-runner
```

## Conclusions

TODO
