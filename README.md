# CraftGuard

An [Ashita v4](https://ashitaxi.com/) addon for **CatsEyeXI** (a Final Fantasy XI private server) that tracks your effective crafting skill and actively protects you from wasting materials on synthesis attempts that can't come out High Quality.

## What it does

CraftGuard shows a small on-screen window with your effective skill for all 8 standard crafts (Woodworking, Smithing, Goldsmithing, Clothcraft, Leathercraft, Bonecraft, Alchemy, Cooking), broken down into:

- **Base** — your raw in-game skill.
- **KI** — the flat bonus from holding that craft's "Mega Moglification" guild-rank key item. This is tracked by reading the game's own key item packet (`0x055`) directly, rather than relying on Ashita's `HasKeyItem()`, which has historically been unreliable after client updates. The KI packet only arrives on login/zone-in or when a key item changes, so **zone once after loading the addon** for this column to populate.
- **Gear** — bonuses from equipped crafting gear (guild aprons, GP-shop items, all-craft items like Kupo Shield / Artisan's Torque).
- **Support** — the bonus from an active Guild Synthesis Support buff, with a live countdown.
- **Effective** — the total, with a marker if you're skill-capped.

It also shows:

- Whether **High Quality synthesis is currently disabled** (you're wearing a guild ring or Artisan's Ring that blocks HQ), and any HQ% chance bonus from Craftmaster's Ring(s).
- Whether **food is currently active** (a simple yes/no — it doesn't try to track which food or its specific bonus).

<img width="444" height="537" alt="image" src="https://github.com/user-attachments/assets/57808039-062d-4b8b-bf9f-afc4ece05d95" />


### Blocklist protection

CraftGuard can actively **block outgoing synthesis attempts** that use a crystal or ingredient on your personal blocklist, but only while HQ is currently disabled (i.e. you're wearing a ring that prevents HQ results). This is meant to stop you from accidentally burning valuable materials on a synth that can never come out HQ.

It works by intercepting the client's outgoing "Synth" packet (`0x096`) before it's sent to the server and cancelling it if a match is found — confirmed against CatsEyeXI via a real packet capture, not just assumed from generic FFXI packet docs. If it ever misbehaves, `/cg blocklist off` disables the blocking instantly without losing your saved list.

<img width="1451" height="44" alt="image" src="https://github.com/user-attachments/assets/9f05ed22-951c-46ee-b255-fb70affd6e0d" />


Your blocklist is stored per-character in Ashita's settings and persists across sessions.

## Installation

1. Download/clone this repo.
2. Copy the `craftguard` folder into your `Ashita/addons/` directory, so you end up with `Ashita/addons/craftguard/craftguard.lua` and `Ashita/addons/craftguard/data.lua`.
3. In-game (or in a `.txt` script/default.txt), load it:
   ```
   /addon load craftguard
   ```
4. Zone once so key item detection can populate.

## Commands

Trigger with either `/craftguard` or the short alias `/cg`.

| Command | Description |
|---|---|
| `/cg` | Toggle the window. |
| `/cg show` | Show the window. |
| `/cg hide` | Hide the window. |
| `/cg reload` | Reload `data.lua` and settings from disk (after editing `data.lua`). |
| `/cg itemfind <text>` | Searches all item names for `<text>` — useful if `data.lua` fails to resolve an item name on this server. |
| `/cg blocklist add <item>` | Adds an ingredient/crystal to your blocklist. |
| `/cg blocklist remove <item>` | Removes an item from your blocklist. |
| `/cg blocklist list` | Lists your current blocklist and whether blocking is on/off. |
| `/cg blocklist on` / `off` | Enables/disables blocklist enforcement without clearing your saved list. |
| `/cg help` | Shows the in-game command list. |

A couple of extra diagnostic commands exist but are intentionally left out of `/cg help` since they're rarely needed day-to-day:

- `/cg buffscan` — lists your currently active buffs with their id/name.
- `/cg bufffind <text>` — searches all buff names for `<text>`, active or not.

Both are handy if you ever need to find a new buff id to add to `data.lua`.

## Configuration

All server-specific data — item names, key item ids, gear bonus values, HQ-blocking items, and Synthesis Support buff ids — lives in `data.lua`, kept separate from the addon logic so it can be edited without touching `craftguard.lua`. Item names must match exactly what CatsEyeXI calls them in-game (server-side names can differ from retail, e.g. abbreviated item names); after editing, run `/cg reload` and check the chat log for any "could not resolve" warnings.

## Requirements

- [Ashita v4](https://ashitaxi.com/)
- Built and tested against **CatsEyeXI**. Item ids, key item ids, and packet structures may need adjusting for other private servers or retail — check `data.lua` and the `SYNTH_PACKET_*` constants near the top of `craftguard.lua`.

## Disclaimer

This addon reads and cancels outgoing game packets to implement the blocklist feature. It has been tested via a real packet capture against CatsEyeXI, but as with any third-party addon, use at your own risk. `/cg blocklist off` is always available as an immediate kill-switch if something looks wrong.
