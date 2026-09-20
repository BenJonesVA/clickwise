# Clickwise

Compact party and raid frames for **World of Warcraft: Wrath of the Lich King 3.3.5a**, built around combat-safe click-casting and buff tracking.

> **Status: early release (v0.1.0).** The core frames, click-casting and heal prediction are working in-game. The buff engine and buff assignments are newer and still being tested. Expect rough edges, and please [open an issue](../../issues) if you hit one.

Clickwise is **3.3.5 only** (`Interface: 30300`). On any other client it disables itself and prints a message instead of erroring.

## Features

- **Compact unit frames** for party, raid and (optionally) pets, with class-colored health bars, a tank/healer role icon, and health text as deficit, percent or off.
- **Click-casting** on any mouse button (1-5) with any Alt/Ctrl/Shift combination. Bindings are secure, so they keep working in combat.
  - Actions: cast a spell (optionally a specific rank), run a macro, target, assist, set focus, cast a buff group, or cast an assigned buff.
  - Every class ships with a healing/utility template. A template spell is only applied if your character actually knows it.
  - Bindings are stored per class, so characters sharing a profile don't overwrite each other.
- **Range fade** dims units that are out of range.
- **Incoming heal prediction** via LibHealComm-4.0, with a configurable look-ahead window and an option to include your own heals.
- **Missing-buff tracking.** Buffs are grouped by what they do, so any equivalent buff counts. For example, Power Word: Fortitude and Prayer of Fortitude both satisfy the Stamina group, whoever cast them. Missing buffs show as icons on the frame, and you can reorder the spell priority per group.
- **Buff assignments.** Set rules per role (tank, healer, damage dealer), per class, or for everyone else. Clickwise shows the first buff in the list the unit is missing. An "Assigned buff" click binding casts it out of combat.
- **Tank and utility clicks for every tank class.** A **Taunt** action taunts whatever the clicked member is targeting, with your class's own taunt (Taunt, Hand of Reckoning, Dark Command or Growl), and works in combat. The warrior, paladin, death knight and druid templates carry it on Ctrl+Shift+Left. Templates also carry Intervene, Vigilance, the paladin hands and Righteous Defense, Innervate, Rebirth, Misdirection, Tricks of the Trade, Pain Suppression and Guardian Spirit for the classes that have them.
- **Aggro border and threat bar.** In combat, a healer or damage dealer who has the enemy gets a pulsing red ring around their frame, and one about to take it a yellow ring. A thin bar along the bottom edge shows how far each unit is toward pulling. Tanks, pets and members whose role is not known yet get neither. `/cw threat` shows what the addon sees.
- **Combat-safe layout changes.** Anything that touches secure frames while you are in combat is queued and applied when combat ends.
- **A profile per character.** Every character gets its own profile the first time it logs in, so one character's layout, bindings and buff rules never change another's. The Profiles tab shows which profile you are on and who shares it, and can switch, create, copy, reset and delete profiles, or move a character that is on a shared profile onto its own copy. `/cw profile` prints the same.
- **A profile per talent spec.** Turn it on in the Profiles tab and each of your two talent specs uses its own profile, switched automatically when you change spec (a dual-spec paladin can tank in one and heal in the other). Whatever profile you pick while in a spec is remembered for it.
- **A profile per role.** Turn it on in the Profiles tab and each role (tank, healer, damage) uses its own profile, switched automatically when your role changes: a change of spec, a dungeon finder role, a main tank assignment, or "My role" set by hand. Use it when the same talents tank in one group and heal in the next. It is exclusive with the profile per talent spec (the role usually follows the spec). With it on, "My role" is kept on the character instead of in the profile.
- **My role.** Your own role (tank, healer or damage) is detected from your talents, or set by hand on the General tab. Combat colors, the role icon and the aggro rings follow it, so a paladin can switch between tanking and healing.
- **Own settings window** with tabs for General, Layout, Bindings, Buffs, Assignments and Profiles.

## Installation

1. Download this repository (**Code > Download ZIP**) or clone it.
2. Copy the **`Clickwise`** folder (the one containing `Clickwise.toc`) into your client's `Interface\AddOns\` directory:

   ```
   World of Warcraft\Interface\AddOns\Clickwise\Clickwise.toc
   ```

3. Fully restart the game client. A `/reload` is not enough on first install, because the client only reads the `.toc` file list at launch.

Dependencies (Ace3 pieces, LibHealComm-4.0, LibGroupTalents-1.0, LibSharedMedia-3.0) are bundled in `Clickwise/Libs`.

## Usage

Type `/cw` (or `/clickwise`) to open the settings window.

| Command | What it does |
|---|---|
| `/cw` or `/cw config` | Open or close the settings window |
| `/cw unlock` / `/cw lock` | Unlock the frames for dragging / lock them again |
| `/cw reset` | Reset the frame position |
| `/cw binds` | List your current click-cast bindings |
| `/cw bind <key> <spell>` | Bind a spell, e.g. `/cw bind shift-1 Flash Heal` |
| `/cw unbind <key>` | Remove a binding |
| `/cw resetbinds` | Restore your class template |
| `/cw buffs [unit]` | Debug aid: list a unit's helpful auras, casters and buff groups |
| `/cw buffcheck` | Debug aid: check that the buff spell IDs resolve on your client |

`<key>` is `[alt-][ctrl-][shift-]<button>` with a button from 1 to 5. Left click (target) and right click (unit menu) are built in unless you bind over them.

To move the frames, run `/cw unlock` and drag the blue **Clickwise** tab above them.

## Roadmap

Planned, not built yet:

- Tracking of active tank defensives and external cooldowns on the frames
- Debuff bouquets: priority-based indicators so dangerous debuffs override minor ones, with class-aware cleanse filtering
- A richer hover tooltip on unit frames (missing buffs, who supplied the ones present)
- Automatic profile switching based on instance and group state

## Known limitations

- Buff rank comparison and auto-downgrade for low-level targets are not supported, because the API does not expose enough data to do it reliably.
- Assigned-buff clicks only work out of combat.
- Cooldowns of other players cannot be read on 3.3.5, so defensive-cooldown tracking is limited to active auras.
- Only the enUS spell names are shipped in the default templates.

## Development

The repository root holds the addon in `Clickwise/`, plus tooling:

- `sync-to-wow.ps1` mirrors the addon into a local 3.3.5 client's AddOns folder for testing. Edit the `$dest` path at the top of the script first.
- `tools/harness.py` runs the addon under a real Lua 5.1 interpreter against a mocked 3.3.5 API, to catch behavioral bugs that a syntax check cannot:

  ```
  pip install lupa
  python tools/harness.py
  ```

- `lessonslearned.md` collects the 3.3.5 API findings behind the project (what exists, what doesn't, and the shims that work).

## Credits

Clickwise is inspired by Clique, HealBot, Grid2, VuhDo and Decursive, and uses buff spell data cross-checked against HealBot 3.3.5.4. Bundled libraries belong to their respective authors and keep their own licenses.

Made by Oakbridge Software.
