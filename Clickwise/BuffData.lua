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
-- selfOnly = true on a group: a buff only the player can put on themselves (seals, armors, aspects...). It is
-- tracked on the player's own frame and nowhere else, only auras the player cast count (another paladin's
-- Devotion Aura is not yours), and it can only be given to the "Self" assignment target. All of them are
-- defaultOn = false: the player opts in per buff in the Buffs tab. A group of this kind lists a whole family
-- that excludes itself (one seal, one armor, one aspect at a time): any spell of it up counts as done and the
-- priority order picks which one a click casts.
--
-- toggle = true on a group: casting the spell again while it is up may CANCEL it (auras, aspects, forms,
-- Righteous Fury). The Assigned buff click never casts such a group while it is up, and it gives no expiry
-- warning (there is nothing a click could refresh). [belief] which spells toggle is game knowledge; guessing
-- "toggles" wrongly only costs a refresh click, guessing "does not" could cancel the buff, so the flag errs
-- toward on for anything permanent.
--
-- [belief] The spell IDs of the selfOnly groups are from memory of the 3.3.5 spell list, not from HealBot's
-- file like the ones above. A wrong but valid ID would silently rename a group to another spell, so
-- `/cw buffcheck` after adding one is not optional: it lists every ID that does not resolve to the name here.
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

	-- Personal buffs (see selfOnly / toggle above).
	{key = "RIGHTEOUS_FURY", label = L["Righteous Fury"], defaultOn = false, selfOnly = true, toggle = true, spells = {
		{id = 25780, name = "Righteous Fury"},
	}},
	{key = "SEAL", label = L["Seal"], defaultOn = false, selfOnly = true, spells = {
		{id = 31801, name = "Seal of Vengeance"}, -- Alliance
		{id = 53736, name = "Seal of Corruption"}, -- Horde
		{id = 20375, name = "Seal of Command"},
		{id = 21084, name = "Seal of Righteousness"},
		{id = 20165, name = "Seal of Light"},
		{id = 20166, name = "Seal of Wisdom"},
		{id = 20164, name = "Seal of Justice"},
	}},
	{key = "AURA", label = L["Paladin aura"], defaultOn = false, selfOnly = true, toggle = true, spells = {
		{id = 465, name = "Devotion Aura"},
		{id = 7294, name = "Retribution Aura"},
		{id = 19746, name = "Concentration Aura"},
		{id = 19891, name = "Fire Resistance Aura"},
		{id = 19888, name = "Frost Resistance Aura"},
		{id = 19876, name = "Shadow Resistance Aura"},
		{id = 32223, name = "Crusader Aura"},
	}},
	{key = "INNER_FIRE", label = L["Inner Fire"], defaultOn = false, selfOnly = true, spells = {
		{id = 588, name = "Inner Fire"},
	}},
	{key = "SHADOWFORM", label = L["Shadowform"], defaultOn = false, selfOnly = true, toggle = true, spells = {
		{id = 15473, name = "Shadowform"},
	}},
	{key = "ARMOR", label = L["Armor"], defaultOn = false, selfOnly = true, spells = {
		{id = 30482, name = "Molten Armor"},
		{id = 6117, name = "Mage Armor"},
		{id = 7302, name = "Ice Armor"},
		{id = 168, name = "Frost Armor"},
		{id = 28176, name = "Fel Armor"},
		{id = 706, name = "Demon Armor"},
		{id = 687, name = "Demon Skin"},
	}},
	{key = "ELEMENTAL_SHIELD", label = L["Elemental shield"], defaultOn = false, selfOnly = true, spells = {
		{id = 24398, name = "Water Shield"},
		{id = 324, name = "Lightning Shield"},
	}},
	{key = "ASPECT", label = L["Aspect"], defaultOn = false, selfOnly = true, toggle = true, spells = {
		{id = 61846, name = "Aspect of the Dragonhawk"},
		{id = 13165, name = "Aspect of the Hawk"},
		{id = 34074, name = "Aspect of the Viper"},
		{id = 13163, name = "Aspect of the Monkey"},
		{id = 13161, name = "Aspect of the Beast"},
		{id = 20043, name = "Aspect of the Wild"},
		{id = 13159, name = "Aspect of the Pack"},
		{id = 5118, name = "Aspect of the Cheetah"},
	}},
	{key = "TRUESHOT", label = L["Trueshot Aura"], defaultOn = false, selfOnly = true, toggle = true, spells = {
		{id = 19506, name = "Trueshot Aura"},
	}},
	{key = "BONE_SHIELD", label = L["Bone Shield"], defaultOn = false, selfOnly = true, spells = {
		{id = 49222, name = "Bone Shield"},
	}},
}

-- Who an assignment rule (Assignments tab) can target. When resolving a unit the most specific rule
-- wins: "SELF" (the player's own frame), then its role, then its class, then "ALL". Roles are the ones
-- CW.GetUnitRole reports.
CW.BuffTargets = {
	{key = "ALL", label = L["Everyone else"]},
	{key = "SELF", label = L["Self"]},
	{key = "ROLE:TANK", label = L["Tanks"]},
	{key = "ROLE:HEALER", label = L["Healers"]},
	{key = "ROLE:DAMAGER", label = L["Damage dealers"]},
	{key = "CLASS:WARRIOR"}, {key = "CLASS:PALADIN"}, {key = "CLASS:DEATHKNIGHT"}, {key = "CLASS:DRUID"},
	{key = "CLASS:PRIEST"}, {key = "CLASS:SHAMAN"}, {key = "CLASS:HUNTER"}, {key = "CLASS:ROGUE"},
	{key = "CLASS:MAGE"}, {key = "CLASS:WARLOCK"},
}
