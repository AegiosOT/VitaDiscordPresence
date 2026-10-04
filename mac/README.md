# VitaPresence for macOS

A native menu-bar app that shows the game you're playing on your PS Vita as your Discord status (Rich
Presence), plus a command-line client, `vitapresence-cli`.

The VitaPresence kernel plugin on the Vita reports the app in the foreground over Wi-Fi. VitaPresence on the
Mac asks for it every few seconds and passes it on to the Discord desktop app.

- [Requirements](#requirements)
- [Install](#install)
- [Setup](#setup)
- [Menu and settings](#menu-and-settings)
- [Command-line client](#command-line-client)
- [Building from source](#building-from-source)
- [Testing without a Vita](#testing-without-a-vita)
- [Troubleshooting](#troubleshooting)
- [Signing and notarization](#signing-and-notarization)
- [Building the Vita plugin on macOS](#building-the-vita-plugin-on-macos)

## Requirements

- macOS 13 Ventura or later, on Apple silicon or Intel.
- The Discord desktop app, running and logged in on the same Mac. Discord in a web browser can't show Rich
  Presence.
- A PS Vita with HENkaku/taiHEN and the VitaPresence plugin, on the same local network as the Mac.

## Install

1. Download the macOS release (a zip with `VitaPresence.app`) from the
   [Releases page](https://github.com/AegiosOT/VitaDiscordPresence/releases), or
   [build it yourself](#building-from-source).
2. Unzip it and drag `VitaPresence.app` into your Applications folder.
3. Open it. VitaPresence lives in the menu bar as a game controller icon, which is a warning triangle until
   it's set up. On first launch the Settings window opens; VitaPresence shows a Dock icon only while that
   window is open.

### First run

- **Gatekeeper.** A build that isn't notarized by Apple is blocked the first time you open it, with a message
  that Apple could not verify it is free of malware. Open **System Settings > Privacy & Security**, scroll
  down and click **Open Anyway**, then confirm with your password. The button appears after the first attempt
  to open the app and stays available for about an hour. Alternatively, remove the quarantine flag in
  Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/VitaPresence.app
  ```

  On macOS 13 and 14 you can also Control-click the app and choose **Open**.
- **Local Network.** On macOS 15 and later, the first connection to the Vita makes macOS ask whether
  VitaPresence may find and connect to devices on your local network. Click **Allow**. If you clicked
  **Don't Allow**, the menu shows **Allow Local Network Access…**, which opens **System Settings > Privacy &
  Security > Local Network**, where you can turn VitaPresence on.
- **Settings.** Until an address and a client ID are set, the Settings window opens by itself at launch, and
  VitaPresence connects as soon as both are entered.

## Setup

### 1. Create a Discord application

1. Open the [Discord Developer Portal](https://discord.com/developers/applications) and click **New
   Application**.
2. Name it what Discord should show after "Playing", for example `PS Vita`.
3. On the **General Information** page, copy the **Application ID**. This is the client ID VitaPresence asks
   for (a number of 16 to 25 digits).
4. Optional: under **Rich Presence > Art Assets**, upload an image such as a Vita logo. Its name is the
   *large image key* you can enter in VitaPresence. An https image URL works too.

### 2. Install the plugin on the Vita

1. Get `VitaPresence.skprx` from the [VitaPresence releases](https://github.com/Electry/VitaPresence/releases).
   The released v1.0.0 plugin works unchanged with the macOS client.
2. Copy it to `ux0:tai/` on the Vita, for example with VitaShell over USB or FTP.
3. Add it to the `*KERNEL` section of `ux0:tai/config.txt`:

   ```
   *KERNEL
   ux0:tai/VitaPresence.skprx
   ```

   taiHEN reads `ux0:tai/config.txt` when it exists and `ur0:tai/config.txt` otherwise; edit the one your
   Vita uses.
4. Reboot the Vita. Kernel plugins are loaded only at boot.

### 3. Find the Vita's address

VitaPresence needs the Vita's IPv4 address, such as `192.168.1.20`, or its MAC address.

- Easiest: in VitaPresence's Settings, click **Find on Network** and choose your Vita from the list. The Vita
  must be awake and running the plugin.
- Your router's list of connected devices shows the Vita's IP address as well. The MAC address is in
  **Settings > System > System Information** on the Vita.
- Routers can give the Vita a different IP address after a while. Either reserve an address for it in your
  router (a DHCP reservation), or enter the MAC address: VitaPresence then looks up the current IP address
  itself, from the Mac's ARP cache or by scanning the local network (at most once a minute).

### 4. Connect

Enter the address and the client ID in Settings. VitaPresence saves them and connects as soon as both are
valid (if you turned off **Connect automatically at launch**, click **Connect**). Start a game on the Vita:
Discord shows it within one poll interval (10 seconds by default).

## Menu and settings

### Menu bar icon

| Icon | Meaning |
|---|---|
| Filled game controller | Your presence is showing on Discord. |
| Outlined game controller | Nothing is showing: disconnected, connecting, or the Vita isn't answering. |
| Warning triangle | Something needs your attention: Local Network access denied, an invalid client ID, or incomplete settings. |

### Menu

- **Status lines:** what the Vita is running (or why it can't be reached) and Discord's state.
- **Connect / Disconnect:** starts or stops polling. Disconnecting clears your presence.
- **Allow Local Network Access…:** shown only while macOS blocks the connection to the Vita. Opens the right
  page of System Settings.
- **Settings…** (⌘,)
- **Launch at Login:** starts VitaPresence when you log in.
- **Quit VitaPresence** (⌘Q): clears your presence and quits.

### Settings

Changes are saved and applied automatically: text as soon as you stop typing for a moment or press Return,
everything else right away.

| Section | Setting | What it does |
|---|---|---|
| PS Vita | IP or MAC address | The Vita's IPv4 or MAC address. **Find on Network** lists the Vitas running the plugin; **Use** fills in one's address. |
| Discord | Application ID | The Application ID (client ID) of your Discord application. A link opens the Developer Portal. |
| Presence | State text | Optional second line under the game name, such as "Handheld mode". |
| | Large image | Optional Art Asset name or https image URL. Hovering over the image shows the game name. |
| | Show elapsed time | Shows how long you've been playing the current game. On by default. |
| | Show the LiveArea | On: shows "In the LiveArea" while you're on the home screen. Off: clears your presence there. On by default. |
| General | Check every … seconds | How often to ask the Vita, 3 to 300 seconds. 10 by default. |
| | Connect automatically at launch | On by default. |
| | Launch at login | Same as the menu item. |

### How it behaves

- Discord shows the game's name (or its title ID when it has no name), your state text, the elapsed time and
  the large image.
- The elapsed time restarts when you switch games or go to the LiveArea, and when the Vita has been
  unreachable for a minute.
- A single missed poll keeps your presence; after two in a row it is cleared. While the Vita doesn't answer,
  VitaPresence backs off: it waits 5 seconds, then 10, 20 and at most 30 seconds between attempts, but never
  asks more often than the poll interval.
- It polls right away when the Mac wakes from sleep or the network comes back.
- Discord accepts at most 5 presence updates per 20 seconds. VitaPresence stays within that limit and sends
  the newest state as soon as it may.
- When Discord rejects the client ID, VitaPresence tries it again after 5 minutes, or as soon as you change it.
- Quitting or disconnecting clears your presence.

## Command-line client

`vitapresence-cli` does what the app does, in a terminal: it prints a line whenever the status changes and
clears your presence when you press Ctrl-C.

Build it with Swift (see [Building from source](#building-from-source) for the requirements) and run it from
the build folder, or copy it to a folder in your `PATH`:

```sh
cd mac
make cli
```

`make cli` prints where it put `vitapresence-cli`. It also signs it with an identifier, which it needs to
resolve MAC addresses (see [Notes](#notes)).

### Usage

```
vitapresence-cli --address <ip|mac> --client-id <id> [options]
vitapresence-cli <ip|mac> <client-id> [options]
vitapresence-cli --scan [--port <n>]
vitapresence-cli --help | --version
```

The second form takes the arguments in the order of the Windows client.

| Option | Meaning |
|---|---|
| `--address <ip\|mac>` | The Vita's IPv4 or MAC address. |
| `--client-id <id>` | Your Discord application ID. |
| `--state <text>` | Second line under the game name. |
| `--interval <seconds>` | Time between polls, 3 to 300 (default 10). |
| `--large-image <key\|url>` | Art Asset name or https image URL for the large image. |
| `--no-elapsed` | Don't show the elapsed time. |
| `--hide-livearea` | Show nothing while the Vita is in the LiveArea. |
| `--verbose` | Print every status update with details (host, failed polls, session start, last answer), not only changes. |
| `--scan` | List the Vitas on the local network that run the plugin, then exit. |
| `--port <n>` | Port of the Vita plugin (default 51966). For testing. |
| `--discord-socket <path>` | Connect only to this Discord IPC socket instead of looking for Discord's usual `discord-ipc-0` to `discord-ipc-9` sockets. For testing. |
| `-h`, `--help` | Show the help. |
| `--version` | Show the version. |

A value can also be attached with `=`, as in `--state="Handheld mode"`.

### Examples

```sh
# Show what the Vita at 192.168.1.20 is playing
vitapresence-cli --address 192.168.1.20 --client-id 123456789012345678

# The same, with the Windows client's arguments
vitapresence-cli 192.168.1.20 123456789012345678

# By MAC address, with a second line, an image, and a poll every 15 seconds
vitapresence-cli --address a4:5e:60:01:02:03 --client-id 123456789012345678 \
    --state "Handheld mode" --large-image vita-logo --interval 15

# Find Vitas on the local network
vitapresence-cli --scan
```

The output looks like this (the status texts depend on the situation):

```
[12:00:58] Starting vitapresence-cli 2.0.0: Vita 192.168.1.20 port 51966, Discord application 123456789012345678, polling every 10 s. Press Ctrl-C to stop.
[12:00:58] Vita: Connecting to your Vita… | Discord: Connecting to Discord… | Presence: not shown
[12:00:58] Vita: Connecting to your Vita… | Discord: Connected as Alex | Presence: not shown
[12:00:59] Vita: Connected - Persona 4 Golden (PCSE00120) | Discord: Connected as Alex | Presence: not shown
[12:00:59] Vita: Connected - Persona 4 Golden (PCSE00120) | Discord: Connected as Alex | Presence: shown
^C[12:05:12] Stopping (press Ctrl-C again to quit immediately)…
[12:05:12] Stopped.
```

`--scan` prints a table on standard output (progress and errors go to standard error). The MAC address shows
as `-` when macOS doesn't reveal it:

```
IP ADDRESS    MAC ADDRESS  TITLE
192.168.1.20  -            Persona 4 Golden (PCSE00120)
```

### Notes

- **Stopping:** Ctrl-C or SIGTERM clears the presence, disconnects from Discord and exits. A second Ctrl-C
  exits immediately; Discord then clears the presence by itself when the connection closes.
- **Exit status:** 0 success, 1 runtime failure (for example `--scan` found no Vita), 64 usage error (bad
  arguments or settings).
- **Local Network:** commands started from Terminal are always allowed to reach the local network. Other
  terminal apps, such as iTerm2 or Warp, must be turned on in **System Settings > Privacy & Security > Local
  Network**; otherwise `vitapresence-cli` reports that access was denied.
- **MAC addresses:** on macOS 27 only programs signed with an identifier, such as the app or the
  `vitapresence-cli` that `make cli` builds, can read the Mac's ARP cache, which maps the Vita's MAC address
  to its IP address. A `vitapresence-cli` built with plain `swift build` can't, so it reports that it can't
  look up the MAC address and names the Vitas it found; use the IP address with that build.

## Building from source

You need Swift 6: Xcode 16 or later, or just the matching Command Line Tools (`xcode-select --install`). The
result runs on macOS 13 or later. There are no third-party dependencies.

```sh
cd mac
make app       # builds VitaPresence.app
make test      # runs the tests
make install   # copies VitaPresence.app to /Applications
make cli       # builds vitapresence-cli
```

The build folder defaults to `~/Library/Caches/io.github.aegiosot.VitaPresence/`, outside the repository.
Folders synced with iCloud Drive (such as Desktop and Documents) add Finder metadata to app bundles, and code
signing then fails.

`make app` signs the app ad hoc, which is fine on your own Mac. macOS ties the Local Network permission and
the login item to the app's signature, though, so after a rebuild it may ask for Local Network access again.

`swift build` and `swift test` also work directly in `mac/`. In an iCloud-synced folder, give them a build
folder outside it, for example `swift test --scratch-path ~/Library/Caches/io.github.aegiosot.VitaPresence/swiftpm`
(what `make test` does), because test bundles built inside it fail code signing too.

## Testing without a Vita

`scripts/mock-vita.py` pretends to be a Vita running the plugin. It needs only the Python 3 that comes with
the Command Line Tools. Every connection gets the same 148-byte packet the plugin sends, and the title
changes every 15 seconds.

```sh
cd mac
scripts/mock-vita.py
```

Then enter `127.0.0.1` as the address in VitaPresence, or run
`vitapresence-cli --address 127.0.0.1 --client-id <id>`. Connections to `127.0.0.1` don't need Local Network
access. The mock logs every connection.

| Option | Meaning |
|---|---|
| `--host` | Address to listen on (default `127.0.0.1`; `0.0.0.0` lets other devices connect). |
| `--port` | TCP port (default 51966). |
| `--cycle SECONDS` | Time before switching to the next title (default 15). |
| `--titles "ID:Name,…"` | The titles to cycle through; `LiveArea` stands for the home screen. Default: `LiveArea,PCSE00120:Persona 4 Golden,XMB:Adrenaline XMB Menu,PCSB00245:Gravity Rush`. |

The app always uses port 51966. With the command-line client the mock can use another port:

```sh
scripts/mock-vita.py --port 40000 --cycle 5
vitapresence-cli --address 127.0.0.1 --port 40000 --client-id 123456789012345678
```

**Find on Network** and `--scan` skip the Mac's own addresses, so they don't list the mock.

## Troubleshooting

| Problem | What to do |
|---|---|
| **Vita not responding** (the connection times out) or **Can't reach the Vita** | Wake the Vita and make sure it's connected to the same network as the Mac. Check the address: the Vita's IP address may have changed (see [Find the Vita's address](#3-find-the-vitas-address)). |
| **The VitaPresence plugin isn't running** (connection refused) | The Vita answered, but nothing listens on port 51966. Check that `VitaPresence.skprx` is in the `*KERNEL` section of `ux0:tai/config.txt`, and reboot the Vita. Right after booting, the plugin takes a couple of seconds before it accepts connections. |
| **Unexpected reply** | Something other than the plugin answered on port 51966. Check that the address belongs to the Vita. |
| **Local Network access is turned off** (denied) | Open **System Settings > Privacy & Security > Local Network** and turn on VitaPresence. The menu item **Allow Local Network Access…** opens that page. For `vitapresence-cli`, run it from Terminal or allow your terminal app there. |
| **Discord isn't running** | Start the Discord desktop app and log in; VitaPresence connects by itself. Discord in a web browser doesn't support Rich Presence. |
| **Invalid Discord application ID** | Copy the **Application ID** from the General Information page of your application in the Developer Portal, not the public key or a client secret. A rejected ID is tried again after 5 minutes, or as soon as you change it. |
| **Presence not visible**, although VitaPresence says it's shown | In Discord, open **Settings > Activity Privacy** and turn on sharing your detected activities with others. Nobody sees your activity while your status is Invisible. |
| **The large image doesn't show** | The key must be the name of an Art Asset of the same Discord application, or an https image URL. Newly uploaded assets can take a few minutes to appear. |
| **The app can't be opened** ("Apple could not verify…") | See [First run](#first-run). |
| **Launch at Login doesn't stick** | Move VitaPresence to the Applications folder, then turn the option on again. Check **System Settings > General > Login Items & Extensions**. |

## Signing and notarization

This part is for people who distribute VitaPresence. To give the app to others without Gatekeeper warnings,
sign it with a Developer ID Application certificate (part of the paid Apple Developer Program) and have
Apple notarize it. `notarytool` and `stapler` come with the Command Line Tools.

1. Store your notary credentials in the keychain once:

   ```sh
   xcrun notarytool store-credentials vitapresence-notary --apple-id you@example.com --team-id TEAMID
   ```

2. Build with the bundling script that `make app` uses, passing your signing identity and the keychain
   profile:

   ```sh
   scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)" --notarize vitapresence-notary
   ```

   `--sign` signs the app with that identity instead of ad hoc, and `--notarize` submits the signed app to
   Apple's notary service and staples the ticket to it.

## Building the Vita plugin on macOS

This is optional: the released v1.0.0 `VitaPresence.skprx` works unchanged with this client. To build the
plugin yourself:

1. Install VitaSDK with vdpm:

   ```sh
   brew install wget cmake
   export VITASDK="$HOME/vitasdk"   # the default, /usr/local/vitasdk, needs sudo
   export PATH="$VITASDK/bin:$PATH"
   git clone https://github.com/vitasdk/vdpm
   cd vdpm && ./bootstrap-vitasdk.sh
   vdpm install taihen
   ```

   Add the two `export` lines to your shell profile to keep them.

2. With the current VitaSDK (GCC 15) the unmodified plugin source doesn't compile. Make two small edits to
   `plugin/src/main.c` in your copy (they are discussed in upstream pull request
   [Electry/VitaPresence#13](https://github.com/Electry/VitaPresence/pull/13), which contains the first one):
   - Line 10, `bool ksceSblACMgrIsPspEmu(SceUID pid);`, conflicts with the SDK's own declaration. Change
     `bool` to `int`, or delete the line.
   - In the `ksceKernelMemcpyUserToKernelForPid(…)` call, pass the address as a pointer:
     `(const void *)0x73CDE000` instead of `(uintptr_t)0x73CDE000`.

3. From the repository's root folder, configure and build into a folder outside the repository. CMake 4
   rejects the plugin's `cmake_minimum_required(VERSION 2.8)`, so configuring needs
   `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`:

   ```sh
   cmake -S plugin -B /tmp/vitapresence-plugin -DCMAKE_POLICY_VERSION_MINIMUM=3.5
   cmake --build /tmp/vitapresence-plugin
   ```

   The plugin is then `/tmp/vitapresence-plugin/VitaPresence.skprx`.

## License and credits

GPL-2.0, like the rest of the repository (see [LICENSE](../LICENSE)). Based on
[VitaPresence](https://github.com/Electry/VitaPresence) by Electry.
