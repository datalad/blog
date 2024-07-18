---
title: 'Self-hosted music streaming from a git-annex repository'
date: 2024-07-18T15:27:47+02:00
author:
- Michael Hanke
tags:
- DataLad
- git-annex
- music streaming
- Navidrome
cover:
  image: cover.webp
  alt: DataLad minions reading and climbing books to write something.
  relative: true
description: >
  No Amazon, Apple and friends: Your own music streaming with Navidrome on a Raspberry Pi5, managed with DataLad.
showToc: true
---

Managing my music collection was the very first thing I tried with [git-annex](https://git-annex.branchable.com).
That was more than 13 years ago, and till today I continue to use the very same git-annex repository for this purpose.

{{< figure
    src="gitlog.webp"
    caption="Screenshot of the first commit's `git log` of my oldest git-annex repository that is still in active use today."
    alt="It reads: Commit <some SHA> Author Michael Hanke <michael.hanke@gmail.com> Date Wed Feb 23 18:37:54 2011 -0500 git-annex setup"
    >}}

I still have a clone on my laptop. I had others on machines like the small box
plugged into the wall with speakers connected and runnning
[mpd](https://www.musicpd.org). I was doing git-annex things: getting and
dropping music from my laptop, making sure I had at least one copy on a
backup-drive, pushing music where `mpd` could see it, etc.

But to be fair, there wasn't a whole lot going on in this repository between
2016 and 2024. Why? Because the money I spent on buying *some music* did suddenly
rent me *all the music*. And with the introduction of sensible mobile bandwidth
at low cost *that music* was with me all the time. Zero cost of shuffling
things around. And yeah, I know, what you don't own ... but it was very
convenient.

So this lasted a few years. But the pain grew. It hurt the first time a song I
really liked vanished from "my" library (distribution license expired). It
turned out that I actually did not listen to more albums than I could have
bought for the money I do pay constantly for renting all the music. "The
algorithm" also too rarely recommends a new song I actually like. And then
all the technical problems. Things were mostly fine on the phone, although not
always, and I do have a recent model. But on my Debian desktop ... this week it
needs this browser, and next week another, often it doesn't play at all. But
even that aside, it is hard to ignore the general
[enshittification](https://en.wikipedia.org/wiki/Enshittification) of things in
this domain.

Earlier this year, I bought a series 5 [Raspberry
Pi](https://en.wikipedia.org/wiki/Raspberry_Pi) to run an at-home-service for
something I am also going to write about here in the future. This small box was
so ridiculously over-powered for the task that I started looking into what else
I could self-host, to not have the machine idle all day long.

That is how I stumbled upon [Navidrome](https://www.navidrome.org) (GPLv3), a
music streaming server that is
[advertized](https://www.navidrome.org/docs/overview/#features) as "very low
resource usage" and specifically labeled for running on a Raspberry Pi.
Although there are [many
alternatives](https://github.com/basings/selfhosted-music-overview), what made
me try this one first was a statement in their
[FAQ](https://www.navidrome.org/docs/faq/#-how-can-i-edit-my-music-metadata-id3-tags-how-can-i-renamemove-my-files):
"Navidrome does not write to your music folder or the files by design".  It
would not only let me curate music metadata together with and where the files
are---and then not mess with them---it is even asking me to do so! I liked
that and it made me hope that I could more-or-less just point it to my music
repository and it would just stream all *my music*.


## Server installation

With only minor modifications I followed the [installation instructions for
Linux](https://www.navidrome.org/docs/installation/linux). I put the Navidrome
working directory in a different location, and disabled Jukebox-mode (it can
use a system audio device to play music, but I don't need that). I ended up
with this configuration file:

```toml
# limit to access localhost
Address = "127.0.0.1"
BaseUrl = "http://music.pididdy.local"
MusicFolder = "/home/music/collection"
# take any playlist from anywhere in the music collection
PlaylistsPath = ".:**/**"
AutoImportPlaylists = true
# don't play on the system audio device
Jukebox.Enabled = false
```

I have [caddy](https://caddyserver.com) on the Raspberry Pi, and I am using
it to reverse-proxy the Navidrome service in my local network.

```
music.pididdy.local:80 {
    reverse_proxy localhost:4533
}
```

The provided [systemd
unit](https://www.navidrome.org/docs/installation/linux/#create-a-systemd-unit)
worked fine after editing paths and user names to match my configuration.


## Deploy the music collection

With the server running, it was time to set up the music collection where
Navidrome could see it. My desired scenario was this:

- have a clone of my music repository in a directory that Navidrome can read, and only a different user can write to
- use git-annex or [DataLad](https://www.datalad.org) to transfer music to and from that clone

I was hoping that Navidrome would be fine with thousands of dead symlinks in
the checkout for all the music that is currently *not* on that machine. I was
hoping that it would be fine with the files in the annex not having any
filename extensions (there was no SHA256**E**
[backend](https://git-annex.branchable.com/backends) in 2011). I was hoping
that it would rescan the library, list any newly deposited songs, and also
silently unlist the music that was dropped from the machine.

And that is (almost) exactly how it turned out!

I cloned the music repository, and used git-annex to transfer a first album to
it. It got picked up almost immediately (the default rescan interval is one
minute). I could navigate to the built-in web UI and start playing songs.
Perfect!  Moving more albums added them equally fast and simple to the
collection streamable via Navidrome.

The only thing that did not work right away with the default setup was
automatically unlisting songs that I dropped from the Navidrome-accessible
clone of my music repository. Navidrome would keep them in its database, and
error if I attempted to play any of them. Not having to fiddle with Navidrome's
view of my music collection beyond git-annex operations was important to me,
and dropping files will be needed whenever I run out of space on the Pi or
simple do not want to have some music being available for streaming anymore.

Fortunately, this was easy to address with [a feature that git-annex is
offering](https://git-annex.branchable.com/forum/How_do_I_hide_files_not_present_in_the_local_annex__63__/)
for more than five years already. I put the work tree of the music repository
on the Raspberry Pi into `hide-missing` mode with git-annex's
[adjust](https://git-annex.branchable.com/git-annex-adjust) command.

```sh
❯ git annex adjust --hide-missing
adjust  ok
```

This removes all symlinks of annexed files that are not available in that
clone.  The removal of the symlinks is enough for Navidrome to unlist dropped
songs. This command can be re-executed whenever a change of file availability
happens. The updates can also be automated via the
`annex.adjustedbranchrefresh` configuration option (see the [git-annex
manpage](https://git-annex.branchable.com/git-annex/) for details).
Setting it to `1` is enough to re-adjust the work tree when moving files
to the server.

```sh
❯ git config --add annex.adjustedbranchrefresh 1
```

However, I did not find the automatic re-adjusting working when dropping files
with a client-side execution of `git annex move -f navidrome ...`. In this case,
I trigger it manually via

```sh
❯ ssh music@pididdy.local git -C collection/annexed annex adjust --hide-missing
```

All in all, this is awesome! After an initial configuration, Navidrome pretty
much runs on its own, watching my music collection and doing the right things
automatically.  For normal operations, the same is true for the Navidrome-clone
of my music repository. Whenever I want to add music to the streaming
collection, I simply transfer it to the Raspberry Pi with git-annex or Datalad.
And all the other git-annex goodness seamlessly applies too. The
Navidrome-clone is just another node in the network of annexes, with hardly any
tuning related to its purpose.

## Picking a streaming client app

With the Navidrome web UI, one can search and listen to music immediately from
any device. But the user experience can, of course, be nicer with a dedicated
app that integrates well, in particular on a mobile device. Navidrome [supports
the Subsonic API](https://www.navidrome.org/docs/developers/subsonic-api/)
which makes it usable with any client apps that understand this protocol, of
which [there are many](https://www.navidrome.org/docs/overview/#apps).

In order to pick a free-and-open-source app to use on my Android phone, I went
to [F-Droid](https://f-droid.org), and installed all I could find.  I picked
[Ultrasonic](https://f-droid.org/en/packages/org.moire.ultrasonic) after trying
all candidates for a few minutes. It is fast, intuitive, and does the job in a
way that feels solid.

The setup in the app is straightforward: Put in the server URL, an account
name, and the password. The app syncs with the server quickly, and from there
on the main challenge is to decide what to listen to. At first, I struggled a
bit to make "listen to random songs of this particular artist" work, but adding
arbitrary artists, albums, or songs to the play queue and then working with
that queue works for this use case and many others, so I am in a happy place
with Ultrasonic.

## Metadata curation

Navidrome's presentation and sorting of music is fully based on metadata or
tags, working with just file and directory names is [not
supported](https://www.navidrome.org/docs/faq/#-can-you-add-a-browsing-by-folder-optionmode-to-navidrome).
I think that is a sensible choice. Nothing beats detailed, high-quality
metadata. Fortunately, my collection was already somewhat well tagged.

But a lot has happened since 2016, and tagging music is fairly convenient with
tools like [Beets](https://beets.io) and [MusicBrainz
Picard](https://picard.musicbrainz.org), both recommended by Navidrome for this
purpose. I picked Picard to update the metadata for my music collection, before
pushing it to Navidrome. This wasn't an arbitrary choice. Picard does not have
`OK` buttons, but they say "Make it so!" -- this is how they got me 🙃.

Here is my workflow:

- I `git annex get` the files I want to update metadata for.
- Afterwards, I `git annex unlock` them. This is needed, because Picard does not recognize the annex symlinks pointing to my `SHA1`-backend annex content as something it can work with. This is sad, but ultimately not an issue, because I want to modify the file content when adding tags, so unlocking is needed anyways. I chose to unlock on a case by case basis, rather than putting the entire work tree in adjusted `unlocked` mode.
- Now I open Picard, make it read my whole collection---which really is just the files I unlocked, and only takes a second.
- I click on the "Cluster" button of the [main screen](https://picard-docs.musicbrainz.org/en/getting_started/screen_main.html)
- I select the album I am interested in and click on "Lookup"
- After some inspection of what it did, I click "Save.

This writes new music files, applying the naming pattern I configured in
Picard. This is how a typical outcome of this operation looks like from Git's
perspective:

```
❯ git status
On branch main
Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
        typechange: The Darkness/permission to land/01 - the darkness - black shuck.mp3
        typechange: The Darkness/permission to land/02 - the darkness - get your hands off my woman.mp3
        typechange: The Darkness/permission to land/03 - the darkness - growing on me.mp3
        typechange: The Darkness/permission to land/04 - the darkness - i believe in a thing called love.mp3
        typechange: The Darkness/permission to land/05 - the darkness - love is only a feeling.mp3
        typechange: The Darkness/permission to land/06 - the darkness - givin' up.mp3
        typechange: The Darkness/permission to land/07 - the darkness - stuck in a rut.mp3
        typechange: The Darkness/permission to land/08 - the darkness - friday night.mp3
        typechange: The Darkness/permission to land/09 - the darkness - love on the rocks with no ice.mp3
        typechange: The Darkness/permission to land/10 - the darkness - holding my own.mp3

Changes not staged for commit:
  (use "git add/rm <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
        deleted:    The Darkness/permission to land/01 - the darkness - black shuck.mp3
        deleted:    The Darkness/permission to land/02 - the darkness - get your hands off my woman.mp3
        deleted:    The Darkness/permission to land/03 - the darkness - growing on me.mp3
        deleted:    The Darkness/permission to land/04 - the darkness - i believe in a thing called love.mp3
        deleted:    The Darkness/permission to land/05 - the darkness - love is only a feeling.mp3
        deleted:    The Darkness/permission to land/06 - the darkness - givin' up.mp3
        deleted:    The Darkness/permission to land/07 - the darkness - stuck in a rut.mp3
        deleted:    The Darkness/permission to land/08 - the darkness - friday night.mp3
        deleted:    The Darkness/permission to land/09 - the darkness - love on the rocks with no ice.mp3
        deleted:    The Darkness/permission to land/10 - the darkness - holding my own.mp3

Untracked files:
  (use "git add <file>..." to include in what will be committed)
        The Darkness/Permission to Land/

❯ ls The\ Darkness/Permission\ to\ Land
01 Stuck in a Rut.mp3                    06 Growing on Me.mp3
02 Love on the Rocks With No Ice.mp3     07 Givin’ Up.mp3
03 Love Is Only a Feeling.mp3            08 Get Your Hands Off My Woman.mp3
04 I Believe in a Thing Called Love.mp3  09 Friday Night.mp3
05 Holding My Own.mp3                    10 Black Shuck.mp3
```

The old files have vanished, and new ones have been written using standardized
patterns. But also the remains of the `unlock` operation are still lingering.

At this point, I will briefly stray from using `git-annex` commands, because I
really do just run `datalad save 'The Darkness'` to bring the repository to
a clean state in one go.

```
❯ datalad save 'The Darkness'
...
action summary:                                                                      
  add (ok: 10)
  delete (ok: 10)
  save (ok: 1)

❯ git status
On branch main
nothing to commit, working tree clean
```

Now I can drop the annex content for the original files

```
❯ git annex unused --used-refspec +main && git annex dropunused all
```

I move (just) the freshly tagged files to the Raspberry Pi

```
❯ git annex copy -t navidrome 'The Darkness'
```

And the only thing that remains is to sync the branch that Navidrome is seeing.
I do this on two steps. First pushing the local state to the Navidrome-clone,
which does not change the collection Navidrome sees just yet. And in a second step,
sync the update in the Navidrome-clone itself. The last step will readjust
the work tree to only show the current set of available music. And a minute later,
I can listen to this album on any connected device.

```
❯ git annex sync navidrome
❯ ssh music@pididdy.local git -C collection/annexed annex sync
```

## Conclusions

So is running my own music streaming server worth it? Absolutely!  Navidrome
was easily and quickly set up. It may have needed an hour and a bit from the
start to the first music playing.

I am *very* pleased with the way the git-annex repository and Navidrome are
"interoperable" with each other, by mutually not getting into the respective
other's territory.

It feels great to own everything, and know that any minute invested will be
worthwhile and the outcome won't be taken away randomly in the future. At the
same time, I experience no loss of user convenience. I can see myself using this
setup for a long time. I am considering to put a similar "watch this
repository" deployment of Navidrome on my
[VPS](https://en.wikipedia.org/wiki/Virtual_private_server). In exactly the same
way that is shown here, I can ready music for streaming when I am on the road. There
would be virtually no additional overhead from a second Navidrome deployment,
because all the goodness is in the music repository. Except for the statistics,
these are per-instance and live in a SQLite database. It should be possible to
export this information in a way that enables aggregation, and storage within
the music repo...

The relatively little information that is uniquely in Navidrome's internal data
structures also implies a rather small potential for any vendor lock-in. If I
want to, or need to stop using Navidrome, I just could with little impact.

What remains worrisome is that there are very few places left that allow
buying digital music -- I might need to get a CD drive again.

Oh, and the system load caused by Navidrome is indeed low, also with multiple
concurrent streams. I need to look into more things that this Raspberry Pi
could do for me...
