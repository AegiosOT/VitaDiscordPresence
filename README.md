# VitaPresence
Change your Discord rich presence to your currently playing PS Vita game!

Inspired by [SwitchPresence](https://github.com/Sun-Research-University/SwitchPresence-Rewritten)
<br>

![vitapresence](https://user-images.githubusercontent.com/12598379/78289782-fc45eb80-7522-11ea-8d5c-1deb49b1cb9c.png)

Works with PSVita & Adrenaline (including custom bubbles) games/apps

## What's in this repository
| Folder | Contents |
|---|---|
| [`plugin/`](plugin) | The Vita kernel plugin (`VitaPresence.skprx`), which reports the game in the foreground (since v1.1 with its PlayStation Store content ID) over Wi-Fi |
| [`pc/`](pc) | The Windows client: a tray app (`VitaPresence-GUI`) and a command-line client (`VitaPresence-CLI`) |
| [`mac/`](mac) | The macOS client: a menu-bar app and a command-line client (`vitapresence-cli`) |

## Disclaimer
The client app (on a Windows PC or a Mac) must be running in the background, and the computer must be on the same network as your Vita.

It would be nice to have rich presence working with only the Vita itself, but this isn't currently possible due to Discord's RPC API restrictions.

## Setup
- Install the .skprx plugin within the `*KERNEL` section of your taiHEN config.txt. Version 1.1 from the [releases](https://github.com/AegiosOT/VitaDiscordPresence/releases) is recommended: it lets the macOS client show the game's official PlayStation Store artwork. The original v1.0 plugin works too.
- **macOS:** install the VitaPresence app, open it, and click **Allow** when macOS asks about your local network. That's all: it finds your Vita by itself, comes with its own Discord application, and Discord shows the game's name, artwork and play time. See [mac/README.md](mac/README.md).
- **Windows:** create an application at the [Discord Developer Portal](https://discord.com/developers/applications), call your application `PS Vita` or whatever you would like and then enter your client ID and Vita's IP or MAC address into the VitaPresence client!
<br>

## macOS
The macOS client is a native menu-bar app for macOS 13 or later (Apple silicon and Intel). It needs no setup: it finds your Vita on the network by itself and uses a built-in Discord application. Discord shows the game's name as the title, its artwork (from the PlayStation Store, HexFlow-Covers or NeoVitaDB) and how long you've been playing. It works with the original plugin too, and comes with a command-line client. See [mac/README.md](mac/README.md) for installation, setup, privacy, building from source and troubleshooting.

## Credits
- [Electry](https://github.com/Electry) for the original VitaPresence plugin and Windows client
- [Sun-Research-University](https://github.com/Sun-Research-University) for the idea & desktop app codebase
- Game artwork in the macOS client: the PlayStation Store, [HexFlow-Covers](https://github.com/Andiweli/HexFlow-Covers) by Andiweli ([CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)) and [NeoVitaDB](https://github.com/robin994/NeoVitaDB-Catalog) by robin994
