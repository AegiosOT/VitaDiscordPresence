# Building VitaPresence

The [releases](https://github.com/AegiosOT/VitaDiscordPresence/releases) include the Mac app and the Vita plugin. These steps are for building from the source tree. The Mac guide's signing, notarization, and troubleshooting notes stay in [mac/README.md](mac/README.md).

## macOS

Xcode 16 or later, so the build uses Swift 6. The app runs on macOS 13 or later. There are no third-party dependencies.

`Formula/vitapresence.rb` is that build as a Homebrew formula. The tap is this repository, and Homebrew clones the default branch, so the formula is available once that branch contains it:

```sh
brew tap aegiosot/vitapresence https://github.com/AegiosOT/VitaDiscordPresence
brew install --HEAD vitapresence
```

```sh
cd mac
make app       # VitaPresence.app
make test      # tests
make install   # copies the app to /Applications
make cli       # vitapresence-cli
```

Builds go to `~/Library/Caches/io.github.aegiosot.VitaPresence/`, outside the repository. An iCloud-synced folder such as Desktop or Documents adds Finder metadata to the bundle, and code signing then fails.

`make app` signs the app ad hoc, which is enough on your own Mac. macOS ties Local Network permission and the login item to that signature, so a rebuild may ask for Local Network access again.

`swift build` and `swift test` work in `mac/` as well. In an iCloud-synced folder, pass a scratch path outside it, which is what `make test` does:

```sh
swift test --scratch-path ~/Library/Caches/io.github.aegiosot.VitaPresence/swiftpm
```

The tests use loopback mocks. They do not scan the network, look up artwork, or talk to Discord.

## Windows

Windows 10 or later, and the [.NET 10 SDK](https://dotnet.microsoft.com/download). The tray app is WinUI 3, so it builds on Windows only. The class library, the Discord helper, the command-line client, and their tests also build on macOS.

From `pc/`:

```sh
dotnet test VitaPresence.Core.Tests
dotnet build VitaPresence.sln
dotnet run --project VitaPresence
```

`dotnet run --project VitaPresence.Cli` is the command-line client. `--scan` prints each Vita's IP, MAC, and title. `--address`, `--port`, `--no-artwork`, and `--client-id` match the Mac client.

The build copies `vitapresence-discord` next to the app. That helper owns the Discord connection and, when it exits, Discord drops the card.

## Vita plugin

The releases already include `VitaPresence.skprx`. To build it on a Mac, install VitaSDK with vdpm:

```sh
brew install wget cmake
export VITASDK="$HOME/vitasdk"
export PATH="$VITASDK/bin:$PATH"
git clone https://github.com/vitasdk/vdpm
cd vdpm && ./bootstrap-vitasdk.sh
vdpm install taihen
```

The default install path, `/usr/local/vitasdk`, needs sudo. Add the two `export` lines to your shell profile if you want them to stick.

From the repository root, build outside the tree:

```sh
cmake -S plugin -B /tmp/vitapresence-plugin
cmake --build /tmp/vitapresence-plugin
```

The plugin is `/tmp/vitapresence-plugin/VitaPresence.skprx`.

`plugin/test/run.sh` checks the plugin's packet code on the Mac, with no Vita and no VitaSDK.
