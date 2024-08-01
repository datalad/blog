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
- workflows
cover:
  image: cover.webp
  alt: A screenshot of Forgejo action runner status and result page, with the Forgejo, podman, and systemd logos on top.
  relative: true
description: >
  Add a containerized action runner to Forgejo that eases migration from GitHub actions.
showToc: true
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
that Forgejo runs on, or an entirely different one, as long as the runner can
reach the Forgejo instance via HTTP(S).

I will focus on the essential steps to get a runner up and talking to Forgejo.
I will not cover every aspect of configuration runners or using actions. The
[actions administrator guide](https://forgejo.org/docs/latest/admin/actions/)
 and the [actions user guide](https://forgejo.org/docs/latest/user/actions/)
cover this in more depth.

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

Podman v4.3 (as in the current Debian 12) is fine. Later versions also work, and
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
way to many things called "runner" already, so we will name it `.registration`.
The following `sed` call makes these changes.

```sh
sed -e 's,file: .runner,file: .registration,' -e 's,docker_host:.*$,docker_host: "-",' \
  -i /etc/forgejo-runner/runner.yaml
```

Depending on the host's network setup, it may be necessary (or desirable) to
adjust the `container.network` setting in this file. This can be set to `host`,
`bridge`, or the name of of a specific network. If left empty (default) a custom,
container-specific network is created automatically.

Next, we can create the directory where the runner will place all its runtime
data.

```sh
mkdir -p ~/runner
```

Now we can register the new runner with Forgejo. This requires a token that can be
obtained via the site administration web UI, as shown in the following screenshot.

{{< figure
    src="gettoken.webp"
    caption="How to find the runner registration token in the site adminstration interface."
    alt="Screen shows a sidebar on the left, with an 'Actions' menu item (marked with a '1'), a submenu item 'Runners' (marked with '2'), and a button 'Create new runner' on the top-right of the image (marked with a '3')."
    >}}

Push the "Create new runner button" and replace `<YOUR-TOKEN>` in the following command
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
    --token <YOUR-TOKEN> \
    --name <NAME-OF-RUNNER> \
    --instance <FORGEJO-SITE-URL>
```

The above command bindmounts both runtime directory and configuration directory
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

## Making (GitHub) actions work

A big question remains: How special are Forgejo actions? People coming from
GitHub may have heavily invested into an action setup. Would it need to be
redone from scratch? Or is there some kind of migration path? We know that
Forgejo actions "are not and will never be identical". But how close are they?

Let's look at a concrete example: the [`codespell` action for this blog on
GitHub](https://github.com/datalad/blog/blob/main/.github/workflows/codespell.yml).

```yaml
name: Codespell

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  codespell:
    name: Check for spelling errors
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Annotate locations with typos
        uses: codespell-project/codespell-problem-matcher@v1
      - name: Codespell
        uses: codespell-project/actions-codespell@v2
```

This is a fairly simple action. But then, many real-world actions are not much more
complicated than this.

When pushed to a Forgejo project with enabled actions, Forgejo will actually try
to run this action, even though it is declared at
`.github/workflows/codespell.yml` and not `.forgejo/workflows/codespell.yml`.
But the action won't run, because there is no runner for `ubuntu-latest`, which the
action declares it needs to run on.

This could be fixed by "forking" the action to
`.forgejo/workflows/codespell.yml` and replacing `ubuntu-latest` with a
supported platform. As can be seen from the screenshot above, the runner we
created has the label `docker`, and this is what `runs-on` is matched against.

However, we can also just make our runner support `ubuntu-latest` too! All it takes
is adding any additional environments to `/etc/forgejo-runner/runner.yaml`, like so:

```yaml
…
runner:
  …
  labels:
    - "docker:docker://node:20-bookworm"
    # we add this one to be somewhat compatible with Github, but stick with Debian
    - "ubuntu-latest:docker://node:20-bookworm"
```

After a restart

```sh
sudo -u forgejo-runner -s systemctl --user restart container-forgejo-runner
```

this will make the runner support both `docker` and `ubuntu-latest`, and the `codespell`
action will start.

If you look carefully, the configuration maps the environment label to a
container that podman can obtain and launch. Both labels map to
`docker://node:20-bookworm`, which is the [Debian 12 based Node.js container on
Docker
Hub](https://hub.docker.com/_/node/tags?page=&page_size=&ordering=&name=20-bookworm).
So `ubuntu-latest` is a bit of a misnomer in this case. But the mapping could
be anything, also to an Ubuntu image, and also to any place podman can reach --
not just Docker Hub. A single runner can support different environments
simultaneously.

With this change the action will start now, but it will fail, even when there
are no typos.

The reason for that is that a `uses:` declaration like
`codespell-project/codespell-problem-matcher@v1` only makes sense for a
monolithic platform like GitHub. Somehow this identifier needs to be
turned into a URL that the action runner can clone from.

Now, Forgejo support a `DEFAULT_ACTIONS_URL`
[configuration](https://forgejo.org/docs/next/admin/actions/#default-actions-url),
but it points to `https://code.forgejo.org` and not `https://github.com` for
very good reasons (read its documentation!), and one should think hard whether
to change that. The alternative is to just put a full URL to begin with:

```diff
       - name: Checkout
         uses: actions/checkout@v4
       - name: Annotate locations with typos
-        uses: codespell-project/codespell-problem-matcher@v1
+        uses: "https://github.com/codespell-project/codespell-problem-matcher@v1"
       - name: Codespell
-        uses: codespell-project/actions-codespell@v2
+        uses: "https://github.com/codespell-project/actions-codespell@v2"
```

And with this change, the actions runs and succeeds -- after fixing the typos ;-)

{{< figure
    src="action-success.webp"
    caption="Result report of a successful `codespell` action run, as provided by the Forgejo web UI."
    alt="The screenshot shows numerous green checkmarks for the commit 'Fix typos', the action 'Check for spelling errors', and all 5 individual steps of the action, including 'Codespell', and 'Complete job'"
    >}}

## Under the hood

How much resources such a runner consumes will obviously depend on its usage.
Much of the storage demands will come from the involved container images

```console
$ sudo -u forgejo-runner -s podman images
REPOSITORY                                          TAG          IMAGE ID   CREATED       SIZE
docker.io/library/act-https---github-com-codespell… latest       cfa572bc5  14 hours ago  58.7 MB
docker.io/library/node                              20-bookworm  1a8e51cfa  7 days ago    1.12 GB
docker.io/library/python                            3.8-alpine   3d4312379  3 weeks ago   49.6 MB
code.forgejo.org/forgejo/runner                     3.5.0-amd64  526f5a8fe  7 weeks ago   38.6 MB
```

A comparatively smaller chunk will be the runner cache with the clones of the used actions.

```console
$ du -sh /home/forgejo-runner/runner/.*
17M     /home/forgejo-runner/runner/.cache
4.0K    /home/forgejo-runner/runner/.registration

$ du -sh /home/forgejo-runner/runner/.cache/act/*
15M     /home/forgejo-runner/runner/.cache/act/actions-checkout@v4
804K    /home/forgejo-runner/runner/.cache/act/https---github.com-codespell-project-actions-codespell@v2
212K    /home/forgejo-runner/runner/.cache/act/https---github.com-codespell-project-codespell-problem-matcher@v1
```

Via the configuration at `/etc/forgejo-runner/runner.yaml` the number of
simultaneously running tasks (one by default), the maximum runtime of a task
can be configured, and other aspects can be configured -- allowing for a large
degree of customization.

On top of that comes all the traffic caused by, for example, installing custom
software dependencies during action runs. It can make a lot of sense to provide
more tailored environments via container images to make this step leaner and
faster.  Something like `debian-bookwork-with-gitannex`. Podman can pull such
images from many places, including a Forgejo instance's package system. More on
that in a future article.


## Conclusions

Setting up a runner for Forgejo actions is a fairly straightforward task.
Being able to run it under a regular user account makes it easier to lock
down what resources are available to a runner. Of course, this does not
imply that it is a good idea to accept arbitrary tasks from a Forgejo
instance that anyone can sign up to.

Having at least one runner available, though, makes a big difference.
It connects a Forgejo instance to a whole universe of automated tasks
that goes well beyond just software testing.
