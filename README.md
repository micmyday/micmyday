# MicMyDay

A macOS menu-bar app that turns speech into text wherever your cursor is.
Transcription runs on your Mac, or through a provider you choose with your
own key.

**[micmyday.com](https://micmyday.com)**

## Support & community

Need help setting up MicMyDay, choosing a model, or creating a rewrite profile?
[Join our Discord](https://discord.gg/59d3eTABXk) to ask questions, share your
workflows, and suggest improvements.

For direct support, visit [micmyday.com/support](https://micmyday.com/support/).

## Why the source is public

MicMyDay listens to a microphone and types into other apps, so it is fair to
want to know what it does with what it hears. With a local model, nothing
leaves the machine. The code is here so that can be checked rather than taken
on trust.

It is published to be read, not built on. MicMyDay is sold under a separate
commercial licence, which only works while the copyright sits in one place, so
outside contributions are not accepted.

## Licence

GPL-3.0. Third-party components are listed in `MicMyDay/Resources/ThirdPartyNotices.txt`.

## Building

```sh
make build
make test
make run
```

Xcode, macOS 14 or later, Apple Silicon.

## Building from source, and what the paid download is for

The source is GPL-3.0. Anyone may compile it and run it, for nothing, forever.
A build made from source says so and behaves accordingly:

```sh
make build-local
```

That compiles with `LOCAL_BUILD` defined, which has two effects. The licence
check is compiled out entirely, so the app is licensed by definition and never
asks for a key or counts a trial. And the updater is never started, because a
copy you compiled should not be replaced by one you did not; you update it by
pulling and building again.

| | Cost | What you get |
|---|---|---|
| Build from source | Free | Xcode, a compile, and manual updates |
| Signed download | Trial, then a licence | Installed by dragging, notarised, updates itself, and support |

So the licence does not buy the right to run the code, which the GPL already
gives you. It buys the prepared article.

Two safeguards keep the distinction honest. An ordinary build cannot pick the
flag up by accident, because it comes from the environment and is empty
otherwise. And every build records how it was made in its own `Info.plist`
under `MMDLocalBuild`, which the release script reads: it refuses to publish a
binary compiled from source, since that would hand every downloader a free copy
that can never update itself, and nothing about it would look wrong until
neither of those things happened.

## Releasing

```sh
make version                     # 1.0.0 (build 1)
make release                     # next build of this version
make release VERSION=1.1.0       # new version, build climbs by one
make release VERSION=1.1.0 BUILD=42
```

Both numbers are optional. They are read from `MicMyDay/Resources/Info.plist`,
which is the record of what shipped last, so the next build never has to be
remembered. The build number always climbs, whether or not the version did, and
a build that is not above the last one is refused: the App Store rejects a build
it has already seen, and the updater will not offer one whose build does not
exceed the installed copy's.

`make release` archives, exports a Developer ID build, checks the signature
belongs to this project's team, packages a DMG, notarises and staples it, signs
it for the updater, and adds an entry to `appcast.xml`. It publishes nothing.
When it finishes it prints what remains: write the release notes, create the
GitHub release with the DMG attached, and commit the version bump and the
appcast last, once the download URL works. An appcast entry pointing at a file
that does not exist yet breaks updates for everyone who already has the app.

The DMG is always called `MicMyDay.dmg`, with no version in the filename, so
that GitHub's permanent redirect resolves:

    https://github.com/micmyday/micmyday/releases/latest/download/MicMyDay.dmg

That link always serves the newest release and never has to be changed wherever
it is published. The version is carried by the tag, the release title and the
app itself rather than by the filename. The updater is unaffected, because the
appcast points at the tagged path for one exact release: a feed that followed
whatever was newest would eventually offer a file its signature did not match.

Notarisation reads a keychain profile, created once with:

```sh
xcrun notarytool store-credentials micmyday-notary \
    --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
```
