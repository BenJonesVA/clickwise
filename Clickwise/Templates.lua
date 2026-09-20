-- Default click-cast templates per class (WotLK 3.3.5 spell names, enUS client).
--
-- Left click = target and right click = unit menu are provided by the unit button template
-- (templates.xml), so they are not listed here. Entries are CANDIDATES: ClickCast.lua only
-- applies a spell entry when the player actually knows the spell, so talent-dependent or
-- misspelled names are harmless. Tank / utility templates (Misdirection, Tricks, taunts,
-- Hand of Salvation, Intervene, ...) are in, for the four tank classes and the classes that support a tank.
--
-- Fields: button "1".."5"; modifier "" or an "alt-ctrl-shift-" prefix; type "spell";
--         spell = spell name; rank = optional "Rank N" (nil = highest rank).

local CW = Clickwise

local function bind(modifier, button, spell)
	return {modifier = modifier, button = button, type = "spell", spell = spell}
end

-- the smart resurrect click (ClickCast.lua): a plain left click on a dead member out of combat; living members
-- still get the default target click
local function rez()
	return {modifier = "", button = "1", type = "rez"}
end

-- the tank's click (ClickCast.lua): taunts the enemy the clicked member is targeting, with the class's own taunt
-- (Taunt / Hand of Reckoning / Dark Command / Growl). The same click for every tank class.
local function taunt()
	return {modifier = "ctrl-shift-", button = "1", type = "taunt"}
end

CW.ClassTemplates = {
	PRIEST = {
		bind("shift-", "1", "Flash Heal"),
		bind("shift-", "2", "Greater Heal"),
		bind("ctrl-", "1", "Renew"),
		bind("ctrl-", "2", "Power Word: Shield"),
		bind("alt-", "1", "Dispel Magic"),
		bind("alt-", "2", "Abolish Disease"),
		bind("", "3", "Prayer of Mending"),
		bind("shift-", "3", "Resurrection"),
		rez(),
		bind("alt-", "3", "Pain Suppression"),
		bind("ctrl-", "3", "Guardian Spirit"),
	},
	PALADIN = {
		bind("shift-", "1", "Flash of Light"),
		bind("shift-", "2", "Holy Light"),
		bind("ctrl-", "1", "Holy Shock"),
		bind("ctrl-", "2", "Beacon of Light"),
		bind("alt-", "1", "Cleanse"),
		bind("alt-", "2", "Sacred Shield"),
		bind("shift-", "3", "Redemption"),
		rez(),
		-- tank and utility (a plain spell binding works in combat)
		bind("", "3", "Hand of Sacrifice"),
		bind("ctrl-", "3", "Hand of Protection"),
		bind("alt-", "3", "Hand of Salvation"),
		bind("", "4", "Hand of Freedom"),
		bind("ctrl-shift-", "2", "Righteous Defense"), -- cast on the member: taunts what is attacking them
		taunt(),
	},
	DRUID = {
		bind("shift-", "1", "Nourish"),
		bind("shift-", "2", "Healing Touch"),
		bind("ctrl-", "1", "Rejuvenation"),
		bind("ctrl-", "2", "Regrowth"),
		bind("alt-", "1", "Remove Curse"),
		bind("alt-", "2", "Abolish Poison"),
		bind("", "3", "Lifebloom"),
		bind("alt-", "3", "Swiftmend"),
		bind("shift-", "3", "Revive"),
		rez(),
		bind("ctrl-", "3", "Innervate"),
		bind("ctrl-shift-", "3", "Rebirth"), -- the combat resurrection; the smart rez click is out of combat only
		taunt(), -- Growl
	},
	SHAMAN = {
		bind("shift-", "1", "Lesser Healing Wave"),
		bind("shift-", "2", "Healing Wave"),
		bind("ctrl-", "1", "Riptide"),
		bind("ctrl-", "2", "Chain Heal"),
		bind("alt-", "1", "Cure Toxins"),
		bind("alt-", "2", "Cleanse Spirit"),
		bind("", "3", "Earth Shield"),
		bind("shift-", "3", "Ancestral Spirit"),
		rez(),
	},
	MAGE = {
		bind("alt-", "1", "Remove Curse"),
		bind("shift-", "1", "Arcane Brilliance"),
	},
	DEATHKNIGHT = {
		bind("shift-", "3", "Raise Ally"),
		taunt(), -- Dark Command
	},
	WARRIOR = {
		bind("", "3", "Intervene"),
		bind("shift-", "3", "Vigilance"),
		taunt(), -- Taunt
	},
	HUNTER = {
		bind("", "3", "Misdirection"),
	},
	ROGUE = {
		bind("", "3", "Tricks of the Trade"),
	},
	-- WARLOCK: target + menu only.
}
