# VitaPresence
Change your Discord rich presence to your currently playing PS Vita game!

Inspired by [SwitchPresence](https://github.com/Sun-Research-University/SwitchPresence-Rewritten)
<br>

![vitapresence](https://user-images.githubusercontent.com/12598379/78289782-fc45eb80-7522-11ea-8d5c-1deb49b1cb9c.png)

Works with PSVita & Adrenaline (including custom bubbles) games/apps

## What's in this repository
| Folder | Contents |
|---|---|
| [`plugin/`](plugin) | The Vita kernel plugin (`VitaPresence.skprx`), which reports the game in the foreground over Wi-Fi |
| [`pc/`](pc) | The Windows client: a tray app (`VitaPresence-GUI`) and a command-line client (`VitaPresence-CLI`) |
| [`mac/`](mac) | The macOS client: a menu-bar app and a command-line client (`vitapresence-cli`) |

## Disclaimer
The client app (on a Windows PC or a Mac) must be running in the background, and the computer must be on the same network as your Vita.

It would be nice to have rich presence working with only the Vita itself, but this isn't currently possible due to Discord's RPC API restrictions.

## Setup
- Install the .skprx plugin within the `*KERNEL` section of your taiHEN config.txt
- Create an application at the [Discord Developer Portal](https://discord.com/developers/applications), call your application `PS Vita` or whatever you would like and then enter your client ID and Vita's IP or MAC address into the VitaPresence client!
<br>

## macOS
The macOS client is a native menu-bar app for macOS 13 or later (Apple silicon and Intel). It works with the same plugin, shows the game and connection status in the menu bar, can find your Vita on the network, and comes with a command-line client. See [mac/README.md](mac/README.md) for installation, setup, building from source and troubleshooting.

## Credits
- [Electry](https://github.com/Electry) for the original VitaPresence plugin and Windows client
- [Sun-Research-University](https://github.com/Sun-Research-University) for the idea & desktop app codebase
