# VitaPresence for macOS

A native menu-bar app that shows the game you're playing on your PS Vita as your Discord status (Rich
Presence): the game's name, its artwork and how long you've been playing. It comes with a command-line
client, `vitapresence-cli`.

The VitaPresence kernel plugin on the Vita reports the app in the foreground over Wi-Fi. VitaPresence on the
Mac finds the Vita on your network, asks it every few seconds, looks up the game's artwork and passes it all
on to the Discord desktop app. There is nothing to set up: no Discord application to create and no IP
address to type.

![Settings, with the address field open](../docs/settings-address.gif)

![Settings, with More open](../docs/settings-more.gif)

The window is one page. The card at the top is what Discord will show. **Console** is the Vita it remembers,
**Presence** is the artwork, the LiveArea and the elapsed time, and **General** is launch and how often it
asks the Vita. **More** holds a custom image, state text, and your own Discord application.

- [Requirements](#requirements)
- [Setup](#setup)
- [What your friends see](#what-your-friends-see)
- [Where the artwork comes from](#where-the-artwork-comes-from)
- [Menu and settings](#menu-and-settings)
- [Advanced](#advanced)
- [Command-line client](#command-line-client)
- [Building from source](#building-from-source)
- [Testing without a Vita](#testing-without-a-vita)
- [Troubleshooting](#troubleshooting)
- [Signing and notarization](#signing-and-notarization)
- [Building the Vita plugin on macOS](#building-the-vita-plugin-on-macos)
- [License and credits](#license-and-credits)

## Requirements

- macOS 13 Ventura or later, on Apple silicon or Intel.
- The Discord desktop app, running and logged in on the same Mac. Discord in a web browser can't show Rich
  Presence.
- A PS Vita with HENkaku/taiHEN and the VitaPresence plugin, on the same local network as the Mac.

## Setup

### 1. Install the app

1. Install with Homebrew (needs Xcode 16 or later), or download the macOS
   release from the [Releases page](https://github.com/AegiosOT/VitaDiscordPresence/releases):

   ```sh
   brew tap aegiosot/vitapresence https://github.com/AegiosOT/VitaDiscordPresence
   brew install --HEAD vitapresence
   vitapresence
   ```

   A downloaded zip contains `VitaPresence.app`. Drag that into your Applications
   folder. You can also [build it yourself](#building-from-source).

### 2. Install the plugin on the Vita

1. Get `VitaPresence.skprx`:
   - **v1.1** (recommended) from the [Releases page](https://github.com/AegiosOT/VitaDiscordPresence/releases)
     of this repository. Besides the game, it reports the game's PlayStation Store content ID, which lets
     VitaPresence show the official store artwork.
   - The original **v1.0** from the [VitaPresence releases](https://github.com/Electry/VitaPresence/releases)
     works too. VitaPresence then looks the game up by its name, and more games show their box art instead
     of the store picture.
2. Copy it to `ux0:tai/` on the Vita, for example with VitaShell over USB or FTP. To update from v1.0,
   replace the old file.
3. Add it to the `*KERNEL` section of `ux0:tai/config.txt` (already done if you're updating):

   ```
   *KERNEL
   ux0:tai/VitaPresence.skprx
   ```

   taiHEN reads `ux0:tai/config.txt` when it exists and `ur0:tai/config.txt` otherwise; edit the one your
   Vita uses.
4. Reboot the Vita. Kernel plugins are loaded only at boot.

### 3. Open VitaPresence

1. Open VitaPresence from your Applications folder. It lives in the menu bar, using the app icon, and has
   no Dock icon.
2. On macOS 15 and later, macOS asks whether VitaPresence may find and connect to devices on your local
   network. Click **Allow**: that's how it finds your Vita.
3. That's it. Wake the Vita and start a game: Discord shows it as your status. The first time, finding the Vita can take a few seconds; after that VitaPresence asks it directly.

VitaPresence finds the Vita by itself (the menu says "Looking for your Vita…" until it does) and remembers
where it answered, so the next launch reconnects right away. It uses a Discord application that comes with
it, and connects whenever it starts.

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
- **Local Network.** If you clicked **Don't Allow**, the menu shows **Allow Local Network Access…**, which
  opens **System Settings > Privacy & Security > Local Network**, where you can turn VitaPresence on.
- **Updating from the first macOS version.** Your settings are kept, so an address you entered and your own
  Discord application stay in use. To find the Vita automatically and use the built-in application instead,
  open **Settings…**, clear the address and turn off **Use my own Discord application**.

## What your friends see

On your profile and in the member list, Discord shows:

- **The game's name** as the title: "Playing **Persona 4 Golden**". The line below says "PlayStation Vita",
  or "PSP on PlayStation Vita" and "PS1 on PlayStation Vita" for games running in Adrenaline. Adrenaline's
  own menu shows as "Adrenaline".
- **The game's artwork** next to it. Hovering over the picture shows the name and the title ID, such as
  "Persona 4 Golden (PCSE00120)". The text shows up first and the picture a moment later, once VitaPresence
  has found it. Without artwork, Discord shows the application's icon.
- **How long you've been playing** the game.
- Your **state text**, if you set one, as one more line.

In the LiveArea (the Vita's home screen), Discord shows "Playing **PlayStation Vita**" and "In the
LiveArea", with the PlayStation Vita logo. With **Show the LiveArea** turned off, nothing is shown there.

## Where the artwork comes from

VitaPresence uses the first picture it finds. What it tries depends on the title:

- **A PS Vita, PSP or PS1 game:** the PlayStation Store picture for the content ID (v1.1 plugin), then a
  store search that accepts only a product with exactly the same title ID (PS1 discs are not searched; the
  store sells them under different IDs), then a [NeoVitaDB](https://github.com/robin994/NeoVitaDB-Catalog)
  icon when that catalog lists the same title ID and name, then box art from
  [HexFlow-Covers](https://github.com/Andiweli/HexFlow-Covers).
- **Homebrew:** the store picture for a content ID when the plugin sends one, then the NeoVitaDB icon, then
  a HexFlow cover. A title ID shared by several homebrew apps is used only when the names match.
- **Adrenaline's menu:** Adrenaline's NeoVitaDB icon.
- **The LiveArea:** the PlayStation Vita logo. It isn't looked up.
- **System apps:** the bubble icon for the built-in apps (Settings, the browser, Photos, Music, and the
  other home-screen apps). It isn't looked up. An internal system title with no known icon still has none.

HexFlow-Covers is licensed under
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/); the covers remain the property of
their publishers.

Built-in apps such as Settings use a fixed icon, the same way the LiveArea does, so nothing is looked up
for them. For games, VitaPresence checks that a picture loads before handing it to Discord, and remembers
what it found (pictures for 30 days, games without one for 3 days) in
`~/Library/Caches/io.github.aegiosot.VitaPresence/artwork.json`. The **Custom image** setting replaces the
artwork with an image of your choice.

### Privacy

- To find the artwork, the Mac looks up the running game: on store.playstation.com by its content ID or its
  name, and on GitHub (HexFlow-Covers) and NeoVitaDB by its title ID.
- The picture's web address goes to Discord, whose servers fetch the picture and show it to your friends.
  The Settings window loads the same picture for its thumbnail, without storing the site's cookies.
- Apart from these lookups, VitaPresence connects only to the Discord app on your Mac and to devices on your
  local network, to find and ask your Vita. It has no server of its own, and your settings and your Vita's
  address stay on your Mac.
- Turn off **Show game artwork** in Settings (or pass `--no-artwork` to `vitapresence-cli`) and nothing is
  looked up. Discord then shows the application's icon, or your custom image.

## Menu and settings

### Menu bar icon

| Icon | Meaning |
|---|---|
| Vita | VitaPresence is running. |
| Warning triangle | Something needs your attention: Local Network access denied, several Vitas found, an invalid address, or an invalid ID for your own Discord application. |

### Menu

- **Status lines:** the game and how long you've been playing it, what the Vita is doing (for example
  "Looking for your Vita…", "Connected", or why it can't be reached) and Discord's state.
- **Connect / Disconnect:** starts or stops polling. Disconnecting clears your presence.
- **Allow Local Network Access…:** shown only while macOS blocks the connection to the Vita. Opens the right
  page of System Settings.
- **Settings…** (⌘,)
- **Launch at Login:** starts VitaPresence when you log in.
- **Quit VitaPresence** (⌘Q): clears your presence and quits.

### Settings

Nothing needs to be set, but you can adjust what Discord shows. Changes are saved and applied automatically:
text as soon as you stop typing for a moment or press Return, everything else right away. The recordings
at the top of this page are this window: the address field, then **More**.

| Section | Setting | What it does |
|---|---|---|
| Console | Saved Vitas | Each Vita you connect is saved. The selected one is found again at launch, including after its IP address changes, when its MAC address is known. **Find on Network** lists the Vitas running the plugin; **Use** saves that one and connects. **Enter an address** is the manual IP or MAC address (see [A fixed address](#a-fixed-address)). |
| Presence | Show game artwork | Looks up the game's picture and shows it next to the game. On by default. |
| | Show the LiveArea | On: shows "In the LiveArea" while you're on the home screen. Off: clears your presence there. On by default. |
| | Show elapsed time | Shows how long you've been playing the current game. On by default. |
| | More | Custom image, state text, and your own Discord application. A custom image is an art asset of your own Discord application, or an https URL of at most 256 characters with no spaces. It replaces the artwork, which is not looked up while it is set. A value Discord would reject is ignored and the game's artwork is used instead. State text is an optional line under the game, such as "Handheld mode". |
| General | Connect automatically at launch | On by default. |
| | Launch at login | Same as the menu item. |
| | Check every … seconds | How often to ask the Vita, 3 to 300 seconds. 10 by default. |

The top of the window shows the status lines with the picture friends see next to the game, and a
Connect or Disconnect button.

### How it behaves

- **Finding the Vita:** with the address blank, VitaPresence asks at the address where the selected Vita
  answered last. It scans the local network for the plugin only when it doesn't know that address, or after
  the Vita has missed two polls in a row; between scans it waits 30 seconds at first, and up to 5 minutes
  while nothing is found. Connecting, waking the Mac, or the network coming back looks again right away. If
  the saved Vita's MAC address shows up at a new IP address, that address is used. Any other Vita is not
  adopted: VitaPresence keeps the one it already knew and asks you to choose. It does not switch to a
  different Vita that happens to be the only one awake.
- The elapsed time restarts when you switch games or go to the LiveArea, and when the Vita has been
  unreachable for a minute.
- A missed poll keeps your presence. Discord is dropped only after the Vita has been unreachable for about a
  minute (and at least two polls). While the Vita doesn't answer,
  VitaPresence backs off: it waits 5 seconds, then 10, 20 and at most 30 seconds between attempts, but never
  asks more often than the poll interval.
- It polls right away when the Mac wakes from sleep or the network comes back.
- Discord accepts at most 5 presence updates in any 20 seconds. VitaPresence stays within that limit and,
  while it is waiting, keeps only the newest state. A game switch waits about a second and a half for the
  artwork so the name and the picture can go out together; if the lookup is slower, the name is sent first
  and the picture follows. A picture Discord refuses is dropped for a minute so the game name still shows.
- When Discord rejects the ID of your own application, VitaPresence tries it again after 5 minutes, or as
  soon as you change it.
- Quitting or disconnecting clears your presence.

## Advanced

You don't need any of this for normal use.

### A fixed address

Enter the Vita's address under **Console > Enter an address** in Settings when there are several Vitas on
your network, or when VitaPresence doesn't find yours by itself.

- **IP address**, such as `192.168.1.20`: shown in the Vita's Wi-Fi settings and in your router's list of
  connected devices. Easiest: click **Find on Network** and choose your Vita from the list. That saves it
  and reconnects to it later. The Vita must be awake and running the plugin.
- **MAC address**: in **Settings > System > System Information** on the Vita. VitaPresence then looks up the
  current IP address itself, from the Mac's ARP cache or by scanning the local network (at most once a
  minute).
- Routers can give the Vita a different IP address after a while. Reserve an address for it in your router
  (a DHCP reservation), enter the MAC address, or leave the field blank.

Clear the field (or type `auto`) to go back to finding the Vita automatically.

### Your own Discord application

VitaPresence comes with a Discord application, so you don't need one. With your own, Discord shows your
application's icon when there's no artwork (as with a system app), and you can use its art assets as the custom
image.

1. Open the [Discord Developer Portal](https://discord.com/developers/applications) and click **New
   Application**. Any name works: Discord shows the game's name as the title.
2. On the **General Information** page, copy the **Application ID** (a number of 16 to 25 digits).
3. Optional: under **Rich Presence > Art Assets**, upload images. An asset's name can then be entered as the
   **Custom image**.
4. In VitaPresence's Settings, turn on **Use my own Discord application** and paste the ID. Turning the option
   off goes back to the built-in application and clears **Custom image** when it is an asset name. An https
   URL is kept.

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
vitapresence-cli [options]
vitapresence-cli <ip|mac> [<client-id>] [options]
vitapresence-cli --scan [--port <n>]
vitapresence-cli --help | --version
```

Without arguments it works like the app out of the box: it finds the Vita on the local network and uses the
built-in Discord application. The second form takes the address, and optionally the ID of your own Discord
application, in the order of the Windows client.

| Option | Meaning |
|---|---|
| `--address <ip\|mac\|auto>` | The Vita's IPv4 or MAC address. Default: `auto`, which finds the Vita on the local network. |
| `--client-id <id>` | The ID of your own Discord application. Default: the built-in application. |
| `--state <text>` | Line under the game name. |
| `--interval <seconds>` | Time between polls, 3 to 300 (default 10). |
| `--large-image <key\|url>` | Custom image instead of the game artwork: an art asset name of your own application, or an https URL of at most 256 characters. |
| `--no-artwork` | Don't look up or show the game artwork. |
| `--no-elapsed` | Don't show the elapsed time. |
| `--hide-livearea` | Show nothing while the Vita is in the LiveArea. |
| `--verbose` | Print every status update with details (host, failed polls, session start, last answer, artwork URL), not only changes. |
| `--scan` | List the Vitas on the local network that run the plugin, then exit. |
| `--port <n>` | Port of the Vita plugin (default 51966). For testing. |
| `--discord-socket <path>` | Connect only to this Discord IPC socket instead of looking for Discord's usual `discord-ipc-0` to `discord-ipc-9` sockets. For testing. |
| `-h`, `--help` | Show the help. |
| `--version` | Show the version. |

A value can also be attached with `=`, as in `--state="Handheld mode"`.

### Examples

```sh
# Find the Vita on the local network and show what it's playing
vitapresence-cli

# Use the Vita at 192.168.1.20
vitapresence-cli --address 192.168.1.20

# The Windows client's arguments: the address and your own application's ID
vitapresence-cli 192.168.1.20 123456789012345678

# By MAC address, with an extra line, without artwork, and a poll every 15 seconds
vitapresence-cli --address a4:5e:60:01:02:03 --state "Handheld mode" --no-artwork --interval 15

# Find Vitas on the local network
vitapresence-cli --scan
```

The output looks like this (the status texts depend on the situation):

```
[12:00:58] Starting vitapresence-cli 2.0.0: Vita automatic port 51966, Discord application built-in (1556140114374037715), polling every 10 s. Press Ctrl-C to stop.
[12:00:58] Vita: Looking for your Vita… | Discord: Connecting to Discord… | Presence: not shown
[12:00:58] Vita: Looking for your Vita… | Discord: Connected as Alex | Presence: not shown
[12:01:01] Vita: Connecting to your Vita… | Discord: Connected as Alex | Presence: not shown
[12:01:01] Vita: Connected at 192.168.1.20 - Persona 4 Golden (PCSE00120) | Discord: Connected as Alex | Presence: not shown
[12:01:01] Vita: Connected at 192.168.1.20 - Persona 4 Golden (PCSE00120) | Discord: Connected as Alex | Presence: shown
[12:01:02] Vita: Connected at 192.168.1.20 - Persona 4 Golden (PCSE00120) | Discord: Connected as Alex | Presence: shown with image
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

- **Finding the Vita:** `vitapresence-cli` doesn't remember where the Vita answered, so without `--address`
  it scans the local network every time it starts, which takes a few seconds. Like the app, it caches artwork
  lookups in `~/Library/Caches/io.github.aegiosot.VitaPresence/` (`artwork.json`, `neovitadb.json`);
  `--no-artwork` writes nothing. The app does remember where the Vita answered.
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
  look up the MAC address and names the Vitas it found; use the IP address, or no address, with that build.

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
(what `make test` does), because test bundles built inside it fail code signing too. The tests use only
loopback mocks: they don't scan the network, look up artwork online or talk to the real Discord.

## Testing without a Vita

`scripts/mock-vita.py` pretends to be a Vita running the plugin. It needs only the Python 3 that comes with
the Command Line Tools. Every connection gets the packet the plugin sends, and the title changes every 15
seconds. When a title has a content ID, the mock acts like the v1.1 plugin and every packet is 184 bytes;
otherwise it sends the 148-byte packets of v1.0.

```sh
cd mac
scripts/mock-vita.py
```

Then enter `127.0.0.1` as the address in VitaPresence's Settings, or run
`vitapresence-cli --address 127.0.0.1`. Automatic discovery, **Find on Network** and `--scan` skip the Mac's
own addresses, so they don't find the mock. Connections to `127.0.0.1` don't need Local Network access. The
mock logs every connection. Its titles are real games, so VitaPresence looks up their artwork as usual.

| Option | Meaning |
|---|---|
| `--host` | Address to listen on (default `127.0.0.1`; `0.0.0.0` lets other devices connect). |
| `--port` | TCP port (default 51966). |
| `--cycle SECONDS` | Time before switching to the next title (default 15). |
| `--titles "ID:Name[:ContentID],…"` | The titles to cycle through; `LiveArea` stands for the home screen. Default: `LiveArea,PCSE00120:Persona 4 Golden:UP0005-PCSE00120_00-PERSONA4GOLDEN01,XMB:Adrenaline XMB Menu,PCSA00011:Gravity Rush`. |

The app always uses port 51966. With the command-line client the mock can use another port:

```sh
scripts/mock-vita.py --port 40000 --cycle 5
vitapresence-cli --address 127.0.0.1 --port 40000
```

## Troubleshooting

| Problem | What to do |
|---|---|
| **Looking for your Vita…** doesn't end, or **No Vita found** | Wake the Vita and make sure it's connected to the same network as the Mac and runs the plugin (see [Setup](#2-install-the-plugin-on-the-vita)). Guest networks and routers with "client isolation" (or "AP isolation") keep devices from seeing each other. VitaPresence looks again every 30 seconds at first, and up to every 5 minutes while nothing answers; connecting again, or **Find on Network**, looks right away. If the Vita still isn't found, enter its IP address (see [A fixed address](#a-fixed-address)). |
| **Several Vitas found** | Click **Find on Network** in Settings and choose yours with **Use**, or enter its address under **Enter an address**. |
| **Vita not responding** (the connection times out) or **Can't reach the Vita** | Wake the Vita and make sure it's connected to the same network as the Mac. With a fixed address, check it: the Vita's IP address may have changed (see [A fixed address](#a-fixed-address)). |
| **The VitaPresence plugin isn't running** (connection refused) | The Vita answered, but nothing listens on port 51966. Check that `VitaPresence.skprx` is in the `*KERNEL` section of `ux0:tai/config.txt`, and reboot the Vita. Right after booting, the plugin takes a couple of seconds before it accepts connections. |
| **Unexpected reply** | Something other than the plugin answered on port 51966. Check that the address belongs to the Vita. |
| **Local Network access is turned off** (denied) | Open **System Settings > Privacy & Security > Local Network** and turn on VitaPresence. The menu item **Allow Local Network Access…** opens that page. For `vitapresence-cli`, run it from Terminal or allow your terminal app there. |
| **Discord isn't running** | Start the Discord desktop app and log in; VitaPresence connects by itself. Discord in a web browser doesn't support Rich Presence. |
| **Invalid Discord application ID** | This only happens with your own application. Copy the **Application ID** from its General Information page in the Developer Portal, not the public key or a client secret, or turn off **Use my own Discord application**. A rejected ID is tried again after 5 minutes, or as soon as you change it. |
| **Presence not visible**, although VitaPresence says it's shown | In Discord, open **Settings > Activity Privacy** and turn on sharing your detected activities with others. Nobody sees your activity while your status is Invisible. |
| **No artwork** | Check that **Show game artwork** is on, that the Mac is online, and that no custom image is set. System apps and some homebrew have no artwork. With the v1.0 plugin, update to v1.1 for the store pictures. Games without artwork are checked again after 3 days; to check right away, quit VitaPresence, delete `~/Library/Caches/io.github.aegiosot.VitaPresence/artwork.json` and open it again. |
| **The custom image doesn't show** | Use an https URL of at most 256 characters and no spaces, or an art asset name of your own Discord application (newly uploaded assets can take a few minutes to appear). With the built-in application, an asset name is ignored. Turn off **Use my own Discord application** and an asset name is cleared; an https URL is kept. |
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

This is optional: the releases include the plugin. To build it yourself from `plugin/`:

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

2. From the repository's root folder, configure and build into a folder outside the repository:

   ```sh
   cmake -S plugin -B /tmp/vitapresence-plugin
   cmake --build /tmp/vitapresence-plugin
   ```

   The plugin is then `/tmp/vitapresence-plugin/VitaPresence.skprx`.

The source builds as is with the current VitaSDK (GCC 15) and CMake 4. Version 1.1 sends the game's content
ID where upstream pull request [Electry/VitaPresence#13](https://github.com/Electry/VitaPresence/pull/13) put
it, so clients made for that pull request read it too.

`plugin/test/run.sh` tests the plugin's code on the Mac, without a Vita or the VitaSDK: it builds
`plugin/src/main.c` against stand-ins for the Vita's kernel functions, with AddressSanitizer, and checks every
packet the plugin would send.

## License and credits

GPL-2.0, like the rest of the repository (see [LICENSE](../LICENSE)). Based on
[VitaPresence](https://github.com/Electry/VitaPresence) by Electry.

Game artwork comes from:

- the [PlayStation Store](https://store.playstation.com); the pictures belong to their publishers.
- [HexFlow-Covers](https://github.com/Andiweli/HexFlow-Covers) by Andiweli, licensed under
  [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/); the covers remain © their
  publishers. VitaPresence links to the covers unchanged.
- [NeoVitaDB](https://github.com/robin994/NeoVitaDB-Catalog) by robin994; the icons belong to their apps'
  authors.
