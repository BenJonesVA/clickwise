-- Buff groups: sets of mechanically equivalent buffs. A unit that has ANY aura of a group counts as
-- buffed for that group, whoever cast it (single-target and group versions apply different aura
-- names, e.g. Prayer of Fortitude is not Power Word: Fortitude, so both must be listed).
--
-- Every spell is {id = spellId, name = "English name"}. The IDs come from HealBot 3.3.5.4's
-- localization file (real 3.3.5 code); at runtime the name is re-resolved with GetSpellInfo(id) and
-- the English name is only the fallback. IDs are per SPELL, not per rank: auras are matched by
-- name, which is the same for every rank.
--
-- Order inside `spells` is the DEFAULT casting priority (first spell the player knows wins); the
-- player can reorder it in the Buffs tab. The single-target version comes first because the group
-- version needs a reagent.
--
-- defaultOn = false: niche buffs that are off until the player enables them.
--
-- slot = "NAME" on a spell: the same caster can only have ONE spell of that slot on a target (a
-- paladin's own blessings replace each other; a warrior's shouts likewise). Buffs.lua uses it so the
-- player is never shown two "missing" icons that cannot both be cleared: once one slot spell is up
-- from the player on a unit, the other slot groups stop counting as missing, and while none is up
-- only the first missing slot group is shown. Buffs from OTHER casters do not occupy the slot.
-- [belief] both rules are game knowledge; delete the `slot` field to make the spells independent.
--
-- Deliberate difference from the design doc: Commanding Shout is NOT grouped with Fortitude. It
-- raises maximum health, Fortitude raises stamina, so one does not replace the other. It gets its
-- own "Health" group. Battle Shout IS grouped with Blessing of Might (both are attack power buffs
-- that do not stack with each other on 3.3.5).
-- [belief] group equivalences come from game knowledge, not from anything readable in the API;
-- they are plain data, so a wrong one is a one-line fix.

local CW = Clickwise
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

CW.BuffGroups = {
	{key = "STAMINA", label = L["Stamina"], spells = {
		{id = 1243, name = "Power Word: Fortitude"},
		{id = 21562, name = "Prayer of Fortitude"},
	}},
	{key = "WILD", label = L["Mark of the Wild"], spells = {
		{id = 1126, name = "Mark of the Wild"},
		{id = 21849, name = "Gift of the Wild"},
	}},
	{key = "INTELLECT", label = L["Intellect"], spells = {
		{id = 1459, name = "Arcane Intellect"},
		{id = 23028, name = "Arcane Brilliance"},
		{id = 61024, name = "Dalaran Intellect"},
		{id = 61316, name = "Dalaran Brilliance"},
	}},
	{key = "SPIRIT", label = L["Spirit"], spells = {
		{id = 14752, name = "Divine Spirit"},
		{id = 27681, name = "Prayer of Spirit"},
	}},
	{key = "KINGS", label = L["Blessing of Kings"], spells = {
		{id = 20217, name = "Blessing of Kings", slot = "BLESSING"},
		{id = 25898, name = "Greater Blessing of Kings", slot = "BLESSING"},
	}},
	{key = "MIGHT", label = L["Attack power"], spells = {
		{id = 19740, name = "Blessing of Might", slot = "BLESSING"},
		{id = 25782, name = "Greater Blessing of Might", slot = "BLESSING"},
		{id = 6673, name = "Battle Shout", slot = "SHOUT"},
	}},
	{key = "WISDOM", label = L["Blessing of Wisdom"], spells = {
		{id = 19742, name = "Blessing of Wisdom", slot = "BLESSING"},
		{id = 25894, name = "Greater Blessing of Wisdom", slot = "BLESSING"},
	}},
	{key = "HEALTH", label = L["Maximum health"], spells = {
		{id = 469, name = "Commanding Shout", slot = "SHOUT"},
	}},
	{key = "HORN", label = L["Strength and agility"], spells = {
		{id = 57330, name = "Horn of Winter"},
	}},
	{key = "SANCTUARY", label = L["Blessing of Sanctuary"], defaultOn = false, spells = {
		{id = 20911, name = "Blessing of Sanctuary", slot = "BLESSING"},
		{id = 25899, name = "Greater Blessing of Sanctuary", slot = "BLESSING"},
	}},
	{key = "SHADOW", label = L["Shadow Protection"], defaultOn = false, spells = {
		{id = 976, name = "Shadow Protection"},
		{id = 27683, name = "Prayer of Shadow Protection"},
	}},
	{key = "THORNS", label = L["Thorns"], defaultOn = false, spells = {
		{id = 467, name = "Thorns"},
	}},
}

-- Who an assignment rule (Assignments tab) can target. When resolving a unit the most specific rule
-- wins: its role, then its class, then "ALL". Roles are the ones CW.GetUnitRole reports.
CW.BuffTargets = {
	{key = "ALL", label = L["Everyone else"]},
	{key = "ROLE:TANK", label = L["Tanks"]},
	{key = "ROLE:HEALER", label = L["Healers"]},
	{key = "ROLE:DAMAGER", label = L["Damage dealers"]},
	{key = "CLASS:WARRIOR"}, {key = "CLASS:PALADIN"}, {key = "CLASS:DEATHKNIGHT"}, {key = "CLASS:DRUID"},
	{key = "CLASS:PRIEST"}, {key = "CLASS:SHAMAN"}, {key = "CLASS:HUNTER"}, {key = "CLASS:ROGUE"},
	{key = "CLASS:MAGE"}, {key = "CLASS:WARLOCK"},
}
