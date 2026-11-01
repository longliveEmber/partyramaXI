# PartyramaXI

**An addon for Ashita v4 by Banedon.**

PartyramaXI replaces Final Fantasy XI's own party, alliance and target windows with its own:

- a themed **party and alliance list** with HP / MP / TP bars, actions and status icons;
- a **target bar** that shows enemies, players and NPCs, with level, check, weaknesses and effect timers;
- a custom **pointer**;
- **RecastXI** spell and ability recast timers, built in.

Every part can be switched on or off, and everything is set up in game.

Version 1.0.2 · GNU GPL v3 or later (see `LICENSE`) · free to use, change and share.

PartyramaXI is built on **hideparty** by atom0s (Ashita Development Team), the addon that hides the game's party
windows. Its window hiding lives on in the Hideparty module. See [Credits](#credits) for everyone whose work is used.

---

## Contents
1. [Install](#install)
2. [The settings window](#the-settings-window)
3. [Modules](#modules)
4. [Pinning status effects on the party list](#pinning-status-effects-on-the-party-list)
5. [Pinned Abilities (RecastXI)](#pinned-abilities-recastxi)
6. [Pictures, fonts and backgrounds](#pictures-fonts-and-backgrounds)
7. [Commands](#commands)
8. [Troubleshooting](#troubleshooting)
9. [Credits](#credits)

---

## Install

1. Copy the `partyramaxi` folder into `Ashita\addons\`. You should end up with `Ashita\addons\partyramaxi\partyramaxi.lua`.
2. Type `/addon load partyramaxi` in game. To load it every time, add that line to your Ashita script.
3. Type `/pxi config` to open the settings.

Settings are saved per character in `Ashita\config\addons\partyramaxi\<character>\`. Your RecastXI settings are saved
in the same folder, as `recast.lua`.

The first load starts from ready-made settings. Their window positions were made on a 3840 x 2160 screen. On a
smaller screen they are fitted to it once, and you can then move everything where you like.

Don't load the original **hideparty** addon at the same time, because both would try to hide the same windows. If you
also use the standalone **RecastXI** addon, load only one of the two trackers.

---

## The settings window

Open it with `/pxi config`.

- **Sidebar (left):** one entry per module. A dot shows whether that module is on. The search box above the sidebar
  finds any setting by its name or its help text, in every module.
- **Description box (top):** what the selected module does, its **Enabled / Disabled** button and its **Test** button.
  Test shows sample members, a sample target or sample timers, so you can set things up anywhere.
- **Sub-tabs:** each module's settings are split into tabs along the top. Inside a tab, settings are in groups with
  colored headings.
- **Key settings (gold ★):** the settings that matter most are marked with a gold star. The **Key settings** buttons
  jump straight to them.
- **Hints:** hover over a setting to see what it does. Pointing at a group highlights the part of the screen it changes.
  A greyed-out setting does not apply right now, and its tooltip says why.
- **Edit positions** (Party list): drag any part of a card with the mouse, and use the Across / Up-down boxes to
  fine-tune it by the pixel.
- **Reset everything** (in the sidebar) puts every module back to the ready-made settings, RecastXI included.

Changes apply straight away and are saved automatically.

---

## Modules

### Hideparty
Hides the game's own windows, each on its own: the party window, alliance parties 2 and 3, the target window and the
spell / ability info window. Hiding the target window also hides the game's target arrows; the Pointer module draws
its own instead. Every hidden window comes back when the addon is unloaded.

### Pointer
Arrows over your target and sub-target.
- **Position:** where the game puts its arrow, or over the character's head.
- **Style:** a pointing hand (the default), a dagger, a triangle, a chevron or a rotating crystal, or your own picture
  dropped into `icons\arrows\`.
- **Look:** size, colors, outline, turn and animation (bob, pulse).

### Party list
A full party and alliance list. Each member gets a card with:
- job icon, name, job and level;
- HP / MP / TP bars;
- current action, with a cast bar;
- status icons with countdowns.

| Tab | What it covers |
|---|---|
| General | Where the list sits, spacing, pets and summons, the party invite flag |
| Appearance | Theme, background (color, gradient or picture), border, cards, player highlight. "Assume RecastXI Theme" gives the list the same frame as the recast window |
| Text | Fonts and sizes for group titles, names, jobs and current actions |
| Bars | HP, MP and TP: color, size, finish, trails and numbers |
| Overhead bars | Health bars over party members' heads in battle, sized by distance |
| Icons | Status icons (icon pack, countdown, sort and pin, canceling), job icons, leader marks, the list's own pointer |
| Alliance | Alliance cards, which are kept to one line by default, each with its own look |

**Selecting members:** click a card, or bind keys with `/bind F9 /pxi list next` and `/bind F8 /pxi list prev`.
Selecting a member also targets them. If the game is waiting for a target (for example a spell sent with `<stpc>`),
selecting a member casts it on them.

**Status icons:** status effects show for you and your own party. The game does not send effects for alliance
members. Countdowns are shown for effects that PartyramaXI saw land. Other effects show a grey count-up timer.
Click one of your own effects and confirm to cancel it, as in the game. Canceling can also be done with keys or a controller, or turned off, in Icons > Canceling Effects. Timers are
kept through zoning and reloads, in `data\`.

### Target bar
Information next to your target. Enemies, players and NPCs each have their own tab and their own settings.
- Name, health bar, distance, level and the /check result (difficulty, plus evasion and defense).
- Effect icons on the target, with countdown rings or bars.
- **Weaknesses and resistances:** elements, damage types and status effects. When the **MobDB** addon is installed, its
  numbers are used; otherwise the LandSandBoat data built into this addon is used.
- **Monster info badges:** notorious monster, aggressive, links, how it detects you, and more.
- **Players:** linkshell color and name labels such as LFP, AWAY, ANON or Bazaar.
- **Battle:** the bar can glide aside and fade parts out while you fight.
- **Docked card:** when your target is off screen, a card sits above the party list. With **Effects like the party
  list** on (Target bar > General > Docked card), the effects on it show under the card, drawn like the party list's
  status icons (same countdown look, sort and pins). They wrap into more rows so every icon stays inside the card,
  with their own **Card icon size** and **Countdown on the card icons** switch.

The target is /checked for you automatically, and those replies are kept out of your chat log. A notorious monster
or battlefield enemy that can't be gauged shows `??`.

### RecastXI
Spell and ability recast timers. You can attach the window above the party list or place it on its own.
- **Themes:** San d'Oria Regalia, Bastok Steam, Windurst Verdant, Voidwatch and Dragoon Forever (Drachen or Wyrm palette).
- **Pictures:** element and magic type icons, a header crest and header textures.
- **Effects:** bar effects and a flash when a recast is ready.
- **Not enough MP:** shown on a spell that is off recast but costs more MP than you have. The cost counts Manafont,
  Manawell, Light Arts, Dark Arts, Penury and Parsimony.

| Tab | What it covers |
|---|---|
| General | Placement (attached or separate), window, when it shows (cutscenes, out of battle, nothing on recast), rows, animation, SP1 / SP2 badges, debug |
| Pinned Abilities | Which spells and abilities show, and which come first (see below) |
| Appearance | Theme, frame, header, header texture, outer glow |
| Text | Font and font sizes |
| Bars | Effects level, rows and timer bars, bar effects, Ready flash |
| Icons | Element and magic type pictures, the icon pack and the fallback pack |

---

## Pinning status effects on the party list

Pinning chooses which status icons come first on the party cards, and which ones you never want to see.

Open `/pxi config` and go to **Party List > Icons > Sort and pin**.

**To pin an effect:**
1. Under **Pin an effect**, type part of a spell or effect name, for example `haste`, `protect` or `sleep`.
2. Press **Pin** beside the one you want. It is added to **Pinned effects**, set to **Show**.
3. In **Pinned effects**, choose what that effect does:
   - **Show:** it is drawn first, ahead of every unpinned effect, whenever someone has it.
   - **Hide:** it is never drawn on any card.
   - **Hide on party only:** it is drawn on your own card, but not on the other members' cards.
4. Put your pins in order. **Up** moves an effect one place up and **Top** makes it the first one. Pinned effects set
   to Show are drawn in this order.
5. To unpin an effect, press **Remove**.

**Good to know:**
- Pins, sort order and the magic type order are saved **per job**. A job you have not set up yet starts with the last
  job's choices, so set them up once and then adjust per job.
- **Sort** (same tab) decides the order of everything that isn't pinned. The choices are game order, last applied
  first, time left, or by type of magic in an order you choose.
- Pinning only changes the order and what is hidden. The countdowns work the same for pinned and unpinned effects.

---

## Pinned Abilities (RecastXI)

Pinned Abilities chooses which spells and abilities the recast window shows, and which come first.

Open `/pxi config`, choose **RecastXI** in the sidebar, then the **Pinned Abilities** tab. You can also type
`/pxi recast pinned`, or right-click the recast window's header.

**To pin a spell or ability:**
1. Find it in the **Spells** or **Abilities** list. Type part of its name in **Search** to narrow both lists.
2. Press **Pin** beside it. It moves into **Pinned Spells** or **Pinned Abilities** at the top of the tab.
3. Pinned rows always come first in the recast window, in the order of that list. Use the **up / down arrows** to move
   a row, **Top** to make it the first one and **Unpin** to take it out.

**To hide or show rows:**
- The tick box beside each spell or ability shows or hides its row. Unticked rows are never shown.
- **Show all** and **Hide all** change every row that matches the search. To show only a few rows, press Hide all,
  then tick the ones you want.
- **Unpin all** empties both pinned lists for this job.
- **Refresh list** reads your spells and abilities again, for example after you learn a spell or change sub job.

**Shortcuts, without opening the settings:**
- Right-click a row in the recast window, then pick **Pin (show first)**, **Unpin** or **Hide this row**.
- Hover over the header and press the small **Pinned Abilities** button that appears.
- Type `/pxi recast pin Cure IV` or `/pxi recast unpin Cure IV`. A unique part of the name is enough. If more than one
  spell matches, the matches are listed so you can type more. `/pxi recast pins` lists what is pinned.
- To turn off the button and the right-click menus, untick **Pinned Abilities button and right-click menus**
  (General tab).

**Good to know:**
- Each **main job** has its own list. Tick **Separate profile per sub job** to give every main and sub job pair its
  own list. For example, WHM/RDM and WHM/SCH would then be set up apart.
- A pinned spell you can't use right now (not learned, level sync, wrong sub job) shows as **Not available**. It is
  kept, and comes back when you can use it.
- To keep pinned rows on screen even when they are ready, tick **Keep pinned entries visible** (General > When it
  shows).

---

## Pictures, fonts and backgrounds

All of these live in the addon's folder. Press **Rescan** in the settings, or reload the addon, after adding files.

```
addons\partyramaxi\
  icons\packs\<Pack>\   status icon packs (for example HXUI's 0.png .. 639.png). Pick a pack and a fallback pack
                        in Target bar > Icons, Party list > Icons > Icon Pack, and RecastXI > Icons.
  icons\status\         loose status icons named by status id (134.png = Dia)
  icons\jobs\           job icons for the party list (WAR.png, WHM.png ...)
  icons\arrows\         your own pointer pictures (PNG, pointing down, transparent background)
  icons\elements\ weak\ mob\ categories\   element, damage type, monster info and magic type icons
                        (several styles; add your own folder to make another style)
  icons\crests\ fx\     RecastXI header crests and header textures
  fonts\                extra .ttf / .otf fonts, listed in every font drop-down
  backgrounds\          PNG backgrounds for the party list
  data\                 saved party effect timers (safe to delete)
```

No icon packs come with the addon. Put any pack you like into `icons\packs\`. Anything without a picture gets a
drawn tile, so nothing breaks when a file is missing. Each folder has a README.txt with the details.

---

## Commands

`/pxi` and `/partyramaxi` do the same thing.

| Command | What it does |
|---|---|
| `/pxi config` | Open the settings window |
| `/pxi` | Turn hiding the game's windows on or off |
| `/pxi hide \| show [party\|alliance1\|alliance2\|target\|castinfo\|all]` | Choose which game windows are hidden |
| `/pxi list [on\|off]` | The party list |
| `/pxi list next \| prev \| clear` | Select the next / previous member (bind keys to these) |
| `/pxi list theme [name]` | List the party list themes, or switch to one |
| `/pxi list leader \| aleader \| qm <name>` | Mark a leader by hand if the game's flags are read wrong |
| `/pxi buffs` | Open the status icon cursor with the keyboard (bind a key to it) |
| `/pxi enemy [on\|off]` | The target bar |
| `/pxi fx [on\|off]` | Effect icons on the target |
| `/pxi fx packs` | Rescan the icon packs and list what was found |
| `/pxi arrow <native\|entity\|off>` | Where the pointer sits |
| `/pxi test` | Show samples of everything for a few seconds |
| `/pxi info` | Show what was found and what is being drawn |
| `/pxi checkdebug` | Log the /check replies, for when a level or check does not show |
| `/pxi reset` | Reset this character's settings |
| `/pxi help` | List every command |
| `/pxi recast` | Open the RecastXI settings |
| `/pxi recast test` | Sample timers |
| `/pxi recast lock \| unlock` | Lock the recast window in place |
| `/pxi recast pinned` | Open the Pinned Abilities tab |
| `/pxi recast pin <name> \| unpin <name> \| pins` | Pin, unpin or list pinned spells and abilities |
| `/pxi recast theme <regalia\|bastok\|windurst\|voidwatch\|dragoon>` | Switch the RecastXI theme |
| `/pxi recast mp` | Show your MP, cost effects and spell costs |
| `/pxi recast safe [on\|off]` | Plain drawing, if the recast window ever draws wrong |
| `/pxi recast help` | List every RecastXI command |

---

## Troubleshooting

- **A window of the game still shows:** check Hideparty in the settings. `/pxi info` says which windows were found.
- **A level or check result does not show:** notorious monsters and battlefield enemies can't be gauged and show `??`.
  For anything else, `/pxi checkdebug` logs the replies.
- **An icon is missing:** make sure the pack is in `icons\packs\` and is picked in the settings, then press Rescan.
- **The recast window draws stretched across the screen:** type `/pxi recast safe on`.
- **Something stopped working:** errors are shown in the chat log. `/addon reload partyramaxi` starts the addon again.

---

## Credits

**PartyramaXI and RecastXI** by Banedon, GNU GPL v3 or later.

**hideparty 1.1** by **atom0s**, Ashita Development Team (GPL v3). PartyramaXI started from hideparty, and its
native window hiding (the Hideparty module, `pxiwin.lua`) is based on it. Thank you to atom0s and the Ashita team for
Ashita itself.

PartyramaXI also uses the following work:
- **Windower Resources** (Windower Team, BSD license, see `THIRD_PARTY_Windower_Resources_LICENSE.txt`): spell and
  status names and durations (`pxifxdata.lua`).
- **Debuffed** by Xathe (Windower): the approach for tracking effects on the target.
- **LandSandBoat** (github.com/LandSandBoat/server, GPL v3): spell effects for spells Windower lists no status for
  (`pxifxlsb.lua`), and monster levels, weaknesses and info (`pximobdata.lua`).
- **MobDB** by ThornyFFXI: when the MobDB addon is installed, its data files are read for weaknesses. MobDB itself is
  not included.
- **XIUI** (Velyn): the signatures used to detect events and a hidden interface.
- **Fonts** in `fonts\` are Google Fonts under the SIL Open Font License 1.1 (licenses in `fonts\licenses\`).
- Game icons and names belong to Square Enix. Icon packs belong to their authors and are not included.

Changes, forks and improvements are welcome. Please keep the license and these credits.
