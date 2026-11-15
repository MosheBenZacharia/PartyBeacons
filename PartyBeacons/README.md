# Party Beacons

Party Beacons helps you keep track of your party in the open world. Each party member gets a clean, high-contrast class marker above their nameplate. When a member is out of view, their marker moves to the edge of your screen and points toward them, with the distance in yards.

Built for **WoW Forever**. It sits on top of the default nameplates and does not change them.

## Features

* **Nameplate marker**: a class icon in a class-colored ring, just above each party member's nameplate. It keeps full contrast and a constant size while the nameplate fades.
* **Screen-edge indicator**: when a member has no nameplate on screen, the marker slides to the screen edge in their direction. Top means ahead of you, the sides mean left or right, and the bottom means behind you.
* **Per-character on/off**: turn it on for the character you play with friends and off for the one you pug on.
* **Options panel**: marker size, height above the nameplate, class icon or plain class color, edge indicators on or off, distance from the screen edge, and a maximum distance for edge indicators.
* Dead members are greyed out. Offline members are hidden.

## Setup

Turn on friendly player nameplates in the game's options. The nameplate marker needs them.

## Commands

* `/pb` (or `/partybeacons`): open the options panel
* `/pb on` / `/pb off`: turn the markers on or off for this character
* `/pb maxdist <0-1000>`: hide edge indicators beyond this many yards (default 500, 0 = no limit)
* `/pb test`: preview the markers without a party
* `/pb help`: list every command
* `/pb debug`: open a window with copyable information for bug reports

## Good to know

* **Open world only.** Inside dungeons and raids the game does not share player positions and protects friendly nameplates, so nothing is shown there.
* **Edge indicators are approximate.** The game does not tell addons where the camera is pointing, so directions are measured from the way your character faces. They are accurate while the camera is behind your character and drift while you swing the camera around.
* A member on another continent or in an instance has no indicator.
* In a raid, only the members of your own subgroup are marked.

## Credits and license

Copyright (c) 2026 Ooga Vibers. Licensed under the GNU General Public License v3 (see LICENSE).

The world-position and secret-value helpers are adapted from [PartyArrow](https://github.com/tcconway/PartyArrow) by TC Conway (GPLv3), which is based on PlayerArrow by Jayama.
