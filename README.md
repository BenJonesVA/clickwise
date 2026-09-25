# Clickwise

Compact party and raid frames for **World of Warcraft: Wrath of the Lich King 3.3.5a**, built around combat-safe click-casting and buff tracking.

> **Status: early release (v0.1.0).** The core frames, click-casting and heal prediction are working in-game. The buff engine and buff assignments are newer and still being tested. Expect rough edges, and please [open an issue](../../issues) if you hit one.

Clickwise is **3.3.5 only** (`Interface: 30300`). On any other client it disables itself and prints a message instead of erroring.

## Features

- **Compact unit frames** for party, raid and (optionally) pets, with class-colored health bars, a tank/healer role icon, and health text as deficit, percent or off. The font and size of the names are set on the Layout tab (any font LibSharedMedia knows, so the SharedMedia addon's fonts show up too); the health text uses the same font, one size smaller.
- **Click-casting** on any mouse button (1-5) with any Alt/Ctrl/Shift combination. Bindings are secure, so they keep working in combat.
  - Actions: cast a spell (optionally a specific rank), run a macro, target, assist, set focus, cast a buff group, or cast an assigned buff.
  - Every class ships with a healing/utility template. A template spell is only applied if your character actually knows it.
  - Bindings are stored per class, so characters sharing a profile don't overwrite each other.
- **Range fade** dims units that are out of range.
- **Incoming heal prediction** via LibHealComm-4.0, with a configurable look-ahead window and an option to include your own heals.
- **Missing-buff tracking.** Buffs are grouped by what they do, so any equivalent buff counts. For example, Power Word: Fortitude and Prayer of Fortitude both satisfy the Stamina group, whoever cast them. Missing buffs show as icons on the frame, and you can reorder the spell priority per group. **Rank comparison:** if someone else's buff is a lower rank of a spell you also know, it still counts as missing, so a click upgrades it; this only applies to the exact same spell (their Prayer of Fortitude isn't compared against your Power Word: Fortitude).
- **Buff assignments.** Set rules per role (tank, healer, damage dealer), per class, or for everyone else. Clickwise shows the first buff in the list the unit is missing. An "Assigned buff" click binding casts it out of combat. If the game refuses a buff with "A more powerful spell is already active", Clickwise remembers that for that player and moves on to the next buff in the list (for five minutes, or until the blocking buff is gone, or until you cast that buff there again); `/cw buffs <unit>` lists such refusals.
- **Personal buffs.** Buffs only you can put on yourself can be tracked on your own frame and given to the Self rule, so a click on your frame casts them: Righteous Fury, seals, paladin auras, Inner Fire, Shadowform, mage and warlock armors, elemental shields, hunter aspects and Trueshot Aura, Bone Shield. They are off until you switch them on in the Buffs tab. Only auras you cast count (another paladin's Devotion Aura is not yours), they never show on anyone else's frame, and a click never casts an aura, aspect or Righteous Fury while it is up, because casting it again may cancel it. Warriors and rogues get none: their upkeep is stances and weapon poisons, which show up as no readable aura. Run `/cw buffcheck` after updating: a line that says an ID "resolves to" another spell is a wrong ID (please report it); a line that says an ID "is not on this client" is harmless, that spell is just never offered.
- **Active defensives.** The defensive cooldowns that are up on a unit right now (Shield Wall, Last Stand, Ardent Defender, Icebound Fortitude, Vampiric Blood, Survival Instincts, Anti-Magic Shell, Dancing Rune Weapon, Barkskin, Divine Protection, Frenzied Regeneration, and the externals Guardian Spirit, Pain Suppression, Hand of Sacrifice and Hand of Protection) show as up to two icons in the middle of the frame with the seconds left, so you can see a tank is already covered before you spend a second external. A gold border means someone else cast it on them, grey means it is their own cooldown. It shows what is running, never what is ready: another player's cooldown is not readable on 3.3.5. One box on the General tab turns it off, and the hover tooltip lists them with who cast them. `/cw defensives [unit]` prints what it sees, and `/cw buffcheck` checks their spell IDs.
- **Debuff highlight and important debuffs.** A frame gets a colored border when its unit carries a debuff you can remove (Magic blue, Curse purple, Disease brown, Poison green), with the debuff's icon, and a click can cure it. On top of that, **important debuffs** are picked out by name and come before everything else, typed or not, curable or not: a bomb, a plague or a stacking boss debuff gets a pink border, its icon and its stack count, even when the type rule would have shown a Hunter's Mark or nothing at all. A built-in list of Icecrown Citadel, Trial of the Crusader, Ulduar and Naxxramas debuffs is shipped (from memory, not verified against the client; a wrong name just never matches), and `/cw watch add <debuff>` puts your own names at the top of it (`/cw debuffs` shows the exact names on your target). One box on the Layout tab, *Important debuffs first*, turns it off. The cure click still picks by type: an important debuff that cannot be removed has no cure.
- **Smart mode.** Build a named rule set in the Smart tab and give a click the action "Smart set". A set is an ordered list of rules, **IF** up to four conditions (all of them, or any one) **THEN** a spell, a buff group, your taunt, a saved macro or your assigned buffs, plus an optional **otherwise**; the first rule that holds wins. Conditions are things the game can answer when you click (the unit is dead, you are in combat, your talent spec, your form or stance, you are in a raid), things about the unit that cannot change in a fight (its role, its class, whether it is you) and things read live and skipped in combat: auras on the unit (a buff or debuff by name, a debuff type, a debuff you can remove), **the unit's health is below 10-90%** (a macro cannot read health) and **the unit is in combat** (a macro can only test your OWN combat state, `[combat]` / `[nocombat]`; the unit's is read when the click is written, out of combat, and refreshed as it changes). A spell is picked from a searchable list of your spellbook, not typed, and the action **Run macro** picks one of your saved macros by name (its lines run through a hidden button of ours, so start its spells with `[@mouseover]` to act on the frame you click); **Assigned buff** casts whatever the Assignments tab would cast for that unit, gated by the rule's own conditions. Each frame gets its own compiled macro (`/cw smart [unit]` shows every rule and the result), which stops at 255 characters. Deleting a set a click still runs is refused.
- **Movable hover tooltip.** On the General tab, **Move tooltip** shows a box you drag anywhere on the screen; the unit tooltip then appears there (it grows away from the nearest screen corner). Right-click the box or press **Done moving** when it is in place; **Reset tooltip** puts it back where Blizzard does.
- **Tank and utility clicks for every tank class.** A **Taunt** action taunts whatever the clicked member is targeting, with your class's own taunt (Taunt, Hand of Reckoning, Dark Command or Growl), and works in combat. The warrior, paladin, death knight and druid templates carry it on Ctrl+Shift+Left. Templates also carry Intervene, Vigilance, the paladin hands and Righteous Defense, Innervate, Rebirth, Misdirection, Tricks of the Trade, Pain Suppression and Guardian Spirit for the classes that have them.
- **Aggro border and threat bar.** In combat, a healer or damage dealer who has the enemy gets a pulsing red ring around their frame, and one about to take it a yellow ring. A thin bar along the bottom edge shows how far each unit is toward pulling. Tanks, pets and members whose role is not known yet get neither. `/cw threat` shows what the addon sees.
- **Combat-safe layout changes.** Anything that touches secure frames while you are in combat is queued and applied when combat ends.
- **A profile per character.** Every character gets its own profile the first time it logs in, so one character's layout, bindings and buff rules never change another's. The Profiles tab shows which profile you are on and who shares it, and can switch, create, copy, reset and delete profiles, or move a character that is on a shared profile onto its own copy. `/cw profile` prints the same.
- **A profile per talent spec.** Turn it on in the Profiles tab and each of your two talent specs uses its own profile, switched automatically when you change spec (a dual-spec paladin can tank in one and heal in the other). Whatever profile you pick while in a spec is remembered for it.
- **A profile per role.** Turn it on in the Profiles tab and each role (tank, healer, damage) uses its own profile, switched automatically when your role changes: a change of spec, a dungeon finder role, a main tank assignment, or "My role" set by hand. Use it when the same talents tank in one group and heal in the next. It is exclusive with the profile per talent spec (the role usually follows the spec). With it on, "My role" is kept on the character instead of in the profile.
- **A look per role.** The Role look tab gives each role (tank, healer, damage) a look of its own inside one profile: frame width and height, incoming heal prediction, the debuff icon, and the threat bar (also on tanks' frames, so a tank sees how close everyone is to pulling). Switch a role's look on and it takes over from the General and Layout tabs whenever you play that role; the rest of the profile is shared. A tank starts smaller with no heal prediction, a healer larger with it. The two tabs show a line when a look is on. It works with or without a profile per role.
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
| `/cw debuffs [unit]` | Debug aid: list a unit's harmful auras with their type and whether they are important |
| `/cw watch [add\|remove <debuff>]` | Show, add or remove your own important debuff names |

`<key>` is `[alt-][ctrl-][shift-]<button>` with a button from 1 to 5. Left click (target) and right click (unit menu) are built in unless you bind over them.

To move the frames, run `/cw unlock` and drag the blue **Clickwise** tab above them.

## Roadmap

Planned, not built yet:

- Automatic profile switching based on instance and group state

## Known limitations

- Auto-downgrade for low-level targets (deliberately casting a lower rank) is not supported. Rank comparison for missing buffs *is* now done (see Missing-buff tracking above), but it depends on `UnitAura`'s rank text, a field other 3.3.5 addons avoid as unreliable; `/cw buffs <unit>` prints it so this can be confirmed on ChromieCraft.
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

Clickwise is inspired by Clique, HealBot, Grid2, VuhDo and Decursive, and uses buff spell data cross-checked against HealBot 3.3.5.4 (the personal buffs' spell IDs are not: `/cw buffcheck` verifies them in the game). Bundled libraries belong to their respective authors and keep their own licenses.

Made by Oakbridge Software.
