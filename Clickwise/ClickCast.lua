-- Click-cast binding engine (secure-attribute based, modelled on Clique r139).
--
-- A binding is {modifier = "alt-ctrl-shift-" prefix or "", button = "1".."5",
--               type = "spell"|"buff"|"assigned"|"macro"|"target"|"focus"|"assist", spell/rank/macro/unit/group,
--               when = "ANY"|"OOC"|"COMBAT"}.
-- type "buff" names a buff GROUP (BuffData.lua); it casts the player's top-priority known spell of it.
-- type "assigned" casts whatever the Assignments rules pick for that unit (Buffs.lua).
-- type "cure" is a smart click: while the unit carries a debuff the player can remove, it casts the spell that
-- removes it (Debuffs.lua picks the spell); with nothing to cure the click does the OTHER binding on the same
-- click (or the default). It never collides with an ordinary binding on its click: `when` is "CURE", a domain
-- of its own. It only acts while the PLAYER is out of combat (the macro's [nocombat]): the pick is written into
-- the macro out of combat and frozen once combat starts, and a frozen cure would still be there after the
-- debuff is gone, taking the click away from the heal for the rest of the fight. In combat use a plain spell binding.
-- type "rez" is the same kind of smart click for the dead: while the unit is dead (or a ghost) and the player
-- knows the class resurrection (Resurrection, Redemption, Ancestral Spirit, Revive) it casts that; a living
-- unit gets the click's other binding (a plain left click still targets). Its own `when` domain, "REZ", and
-- out of combat only, for the same reason as the cure. Deaths mostly happen in combat, when nothing can be
-- rewritten: the pick is written as soon as the fight ends.
-- type "taunt" is the tank's click: it taunts the enemy the clicked member is targeting, with the class's own
-- taunt (Taunt for a warrior, Hand of Reckoning for a paladin, Dark Command for a death knight, Growl for a
-- druid), so one template serves every tank class. A taunt needs a HOSTILE target, which a friendly frame does not
-- have, so the macro aims at the member's target: "/cast [target=<unit>target,harm,nodead] <taunt>". Unlike the
-- smart clicks it works in combat (that is when a tank taunts) and it takes the click over like an ordinary
-- binding. The macro names the unit token, so it is rewritten (out of combat) when the button's unit changes.
-- Bindings become exact-match secure attributes ("shift-type1", "shift-spell1", ...) on every
-- unit button; exact matches beat the "*type1"/"*type2" wildcard defaults from templates.xml,
-- so left = target and right = menu keep working for every unbound modifier combination.
--
-- COMBAT GATING (`when`, casts only): "OOC" = only out of combat, "COMBAT" = only in combat, "ANY" = always
-- (an "assigned" binding without `when` means "OOC", which is what it always did). A click can carry
-- one "OOC" and one "COMBAT" binding at the same time (buff after the fight, heal during it); "ANY"
-- excludes both.
--   Secure code cannot read another unit's combat state (the only conditionals are [combat] / [nocombat],
--   which test the PLAYER), and attributes cannot change in combat. So a gated click becomes one macro,
--   "/cast [nocombat,target=<unit>] Buff; [combat,target=<unit>] Heal", and the unit's own combat state
--   (UnitAffectingCombat, polled) is folded in while the player is out of combat and free to rewrite it:
--     OOC    : blocked while the unit is in combat (out of combat: [nocombat])
--     COMBAT : always allowed while the unit is in combat (otherwise [combat])
--   Once the player is in combat the macro is frozen, so from then on the player's own combat state decides.
--   The macro names the unit token the button shows when it was written; the buttons are rewritten as soon
--   as that changes, but a roster reshuffle IN combat leaves gated clicks aimed at the old token until
--   combat ends (plain spell bindings follow the button's unit and have no such gap).
--
-- Attributes on secure frames can not be changed in combat, so every apply is deferred with
-- CW:RunOOC and flushed on PLAYER_REGEN_ENABLED.

local CW = Clickwise
local ClickCast = CW:NewModule("ClickCast", "AceEvent-3.0", "AceTimer-3.0")
CW.ClickCast = ClickCast

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local pairs, ipairs, tinsert = pairs, ipairs, table.insert
local InCombatLockdown, UnitAffectingCombat = InCombatLockdown, CW.API.UnitAffectingCombat -- (the API's: see Compat.lua)
local UnitIsConnected, UnitIsDeadOrGhost = CW.API.UnitIsConnected, CW.API.UnitIsDeadOrGhost
local GetSpellInfo = GetSpellInfo

local BUTTON_NAMES = {["1"] = "Left", ["2"] = "Right", ["3"] = "Middle", ["4"] = "Button4", ["5"] = "Button5"}
local COMBAT_POLL = 0.5 -- seconds between reads of every frame's unit combat state (only while a gated binding exists)

-- Binding kinds that cast a spell, and so can be gated on combat.
local CASTS = {spell = true, buff = true, assigned = true}
local WHEN_TEXT = {OOC = L["Out of combat"], COMBAT = L["In combat"]}

local tauntSpell -- the class taunt the player knows, or nil (see RebuildTaunt below)

-- The smart clicks: each lives in a `when` domain of its own, beside the ordinary bindings (its fallback).
local SMART = {cure = "CURE", rez = "REZ"}
local SMART_DOMAIN = {CURE = true, REZ = true}

-- When the binding fires: "ANY", "OOC" or "COMBAT"; "CURE" / "REZ" for the smart clicks.
local function WhenOf(b)
	if SMART[b.type] then return SMART[b.type] end
	if not CASTS[b.type] then return "ANY" end
	local w = b.when
	if w == "ANY" or w == "OOC" or w == "COMBAT" then return w end
	return b.type == "assigned" and "OOC" or "ANY"
end
ClickCast.WhenOf = WhenOf

-- The secure-template modifier prefix order is fixed: alt, ctrl, shift.
function CW.MakeModifier(alt, ctrl, shift)
	return (alt and "alt-" or "") .. (ctrl and "ctrl-" or "") .. (shift and "shift-" or "")
end

--------------------------------------------------------------------------------
-- Binding list
--------------------------------------------------------------------------------
local function CopyBinding(b)
	local c = {}
	for k, v in pairs(b) do c[k] = v end
	c.modifier = c.modifier or ""
	return c
end

local function ClassKey()
	local _, class = UnitClass("player")
	return class
end

-- The user's own list for this character's class, or nil while still on the class template.
-- Stored per CLASS (profile.bindings[class]) because profiles are shared between characters.
local function GetCustom()
	local all = CW.db.profile.bindings
	return all and all[ClassKey()]
end

function ClickCast:IsCustom()
	return GetCustom() ~= nil
end

-- Effective bindings: the user's own list if they have one, otherwise the class template
-- restricted to spells the player actually knows.
function ClickCast:GetBindings()
	local custom = GetCustom()
	if custom then
		return custom
	end
	local out = {}
	local template = CW.ClassTemplates[ClassKey()]
	if template then
		for _, b in ipairs(template) do
			if b.type ~= "spell" or CW.KnowsSpell(b.spell) then
				out[#out + 1] = b
			end
		end
	end
	return out
end

-- Convert "using the template" into an editable user list (copy-on-write).
local function EnsureCustom()
	local custom = GetCustom()
	if not custom then
		custom = {}
		for _, b in ipairs(ClickCast:GetBindings()) do
			custom[#custom + 1] = CopyBinding(b)
		end
		CW.db.profile.bindings[ClassKey()] = custom
	end
	return custom
end

-- Older builds stored one flat list per profile; move it under this character's class.
local function MigrateBindings()
	local profile = CW.db.profile
	if type(profile.bindings) ~= "table" then
		profile.bindings = {}
	elseif profile.bindings[1] ~= nil then
		local flat = {}
		for i = 1, #profile.bindings do flat[i] = profile.bindings[i] end
		for i = #profile.bindings, 1, -1 do table.remove(profile.bindings, i) end
		profile.bindings[ClassKey()] = flat
		return true
	end
end

local function SameKey(b, modifier, button)
	return (b.modifier or "") == modifier and b.button == button
end

-- Two bindings on the same click collide unless one is "OOC" and the other "COMBAT". A smart click only
-- collides with another of its own kind: it lives beside the ordinary bindings, which are its fallback.
local function Collides(b, modifier, button, when)
	if not SameKey(b, modifier, button) then return false end
	local w = WhenOf(b)
	if SMART_DOMAIN[w] or SMART_DOMAIN[when] then return w == when end
	return w == when or w == "ANY" or when == "ANY"
end

-- The bindings a new one on this click with this `when` would replace.
function ClickCast:GetCollisions(modifier, button, when)
	local out = {}
	for _, b in ipairs(self:GetBindings()) do
		if Collides(b, modifier or "", button, when or "ANY") then out[#out + 1] = b end
	end
	return out
end

-- entry = {modifier, button, type = "spell"|"macro"|"target"|"focus"|"assist", spell, rank, macro, when}
-- Replaces the existing bindings it collides with (see Collides).
function ClickCast:SetBindingEntry(entry)
	local list = EnsureCustom()
	entry.modifier = entry.modifier or ""
	if CASTS[entry.type] then
		entry.when = WhenOf(entry)
	else
		entry.when = nil -- only casts can be gated
	end
	local when = WhenOf(entry)
	for i = #list, 1, -1 do
		if Collides(list[i], entry.modifier, entry.button, when) then
			table.remove(list, i)
		end
	end
	tinsert(list, entry)
	self:ApplyAll()
end

function ClickCast:SetBinding(modifier, button, spell) -- slash-command convenience
	self:SetBindingEntry({modifier = modifier, button = button, type = "spell", spell = spell})
end

-- `when` nil: the first binding on that click.
function ClickCast:GetBinding(modifier, button, when)
	for _, b in ipairs(self:GetBindings()) do
		if SameKey(b, modifier, button) and (when == nil or WhenOf(b) == when) then
			return b
		end
	end
end

-- `when` nil: every binding on that click.
function ClickCast:RemoveBinding(modifier, button, when)
	if not self:GetBinding(modifier, button, when) then
		return false
	end
	local list = EnsureCustom()
	for i = #list, 1, -1 do
		if SameKey(list[i], modifier, button) and (when == nil or WhenOf(list[i]) == when) then
			table.remove(list, i)
		end
	end
	self:ApplyAll()
	return true
end

function ClickCast:ResetBindings()
	CW.db.profile.bindings[ClassKey()] = nil
	self:ApplyAll()
end

function ClickCast:DescribeBindings()
	local lines = {}
	for _, b in ipairs(self:GetBindings()) do
		local what = b.spell or b.macro or (b.group and ("buff group " .. b.group)) or (b.type == "cure" and "cure debuff") or (b.type == "rez" and "resurrect") or b.type
		if b.rank then what = what .. " (" .. b.rank .. ")" end
		local when = WHEN_TEXT[WhenOf(b)]
		if when then what = what .. " [" .. when .. "]" end
		lines[#lines + 1] = (b.modifier or "") .. b.button .. " (" .. (BUTTON_NAMES[b.button] or "?") .. "): " .. what
	end
	if #lines == 0 then
		lines[1] = L["No bindings for this class."]
	end
	return lines
end

--------------------------------------------------------------------------------
-- Applying to buttons
--------------------------------------------------------------------------------
local function SetAttr(btn, applied, prefix, name, suffix, value)
	local key = prefix .. name .. suffix
	btn:SetAttribute(key, value)
	applied[#applied + 1] = key
end

-- The spell a casting binding casts on this button, or nil.
local function CastName(b, btn)
	if b.type == "spell" then
		if not b.spell then return nil end
		return b.rank and (b.spell .. "(" .. b.rank .. ")") or b.spell -- "Name(Rank N)"
	elseif b.type == "buff" then
		return b.group and CW.Buffs:GetCastSpell(b.group)
	elseif b.type == "assigned" then
		return btn.cwAssignedSpell -- picked per unit by Buffs.lua; nil for a unit no rule applies to
	elseif b.type == "cure" then
		return btn.cwCureSpell -- picked per unit by Debuffs.lua; nil while the unit has nothing the player can remove
	elseif b.type == "rez" then
		return btn.cwRezSpell -- picked per unit below (UpdateRez); nil while the unit is alive
	elseif b.type == "taunt" then
		return tauntSpell -- the class taunt; nil until the player knows it
	end
end

-- "alt-ctrl-shift-" -> "Alt+Ctrl+Shift" (empty for no modifier)
function ClickCast.ModifierText(modifier)
	local parts = {}
	if modifier:find("alt-", 1, true) then parts[#parts + 1] = L["Alt"] end
	if modifier:find("ctrl-", 1, true) then parts[#parts + 1] = L["Ctrl"] end
	if modifier:find("shift-", 1, true) then parts[#parts + 1] = L["Shift"] end
	return table.concat(parts, "+")
end

local BUTTON_ORDER = {"1", "2", "3", "4", "5"}
local BUTTON_TIP = {["1"] = L["Left"], ["2"] = L["Right"], ["3"] = L["Middle"], ["4"] = L["Button 4"], ["5"] = L["Button 5"]}
local DEFAULT_CLICK = {["1"] = L["Target"], ["2"] = L["Menu"]} -- the "*type1" / "*type2" wildcard defaults of templates.xml
local KIND_TEXT = {target = L["Target"], focus = L["Focus"], assist = L["Assist"], macro = L["Macro"], cure = L["Cure debuff"], rez = L["Resurrect"], taunt = L["Taunt"]}

-- Lines for the hover tooltip: what each click does with this modifier prefix ("" or "alt-ctrl-shift-") held.
-- Each line is {left = button, right = action, r, g, b}. Second result: whether bindings on other modifier
-- combinations exist (the tooltip hints at them).
function ClickCast:TooltipLines(btn, modifier)
	modifier = modifier or ""
	local bound, others = {}, false
	for _, b in ipairs(self:GetBindings()) do
		if (b.modifier or "") == modifier then
			local list = bound[b.button]
			if not list then
				list = {}
				bound[b.button] = list
			end
			list[#list + 1] = b
		else
			others = true
		end
	end
	local lines = {}
	for _, button in ipairs(BUTTON_ORDER) do
		local list = bound[button]
		if list then
			for _, b in ipairs(list) do
				local what = CastName(b, btn)
				if SMART[b.type] or b.type == "taunt" then
					what = KIND_TEXT[b.type] .. (what and (": " .. what) or "")
				elseif not what then
					what = (b.type == "assigned" and L["Assigned buff"]) or KIND_TEXT[b.type] or b.group or b.spell or "?"
				end
				local when = WHEN_TEXT[WhenOf(b)]
				if when then what = what .. " (" .. when .. ")" end
				lines[#lines + 1] = {left = BUTTON_TIP[button], right = what, r = 1, g = 1, b = 1}
			end
		elseif DEFAULT_CLICK[button] then
			lines[#lines + 1] = {left = BUTTON_TIP[button], right = DEFAULT_CLICK[button], r = 0.6, g = 0.6, b = 0.6}
		end
	end
	return lines, others
end

-- Does this button's unit count as "in combat" right now? (a boolean, never nil)
local function UnitFights(btn)
	return (btn.unit and UnitAffectingCombat(btn.unit)) and true or false
end

-- Whether any binding of the list needs the macro path: a casting binding that is gated, an assigned one or a smart click.
local function NeedsMacro(items)
	for _, b in ipairs(items) do
		if b.type == "assigned" or b.type == "taunt" or SMART[b.type] or (CASTS[b.type] and WhenOf(b) ~= "ANY") then return true end
	end
	return false
end

-- The unit whose target a taunt aims at: "party2" -> "party2target"; the player's own target is just "target".
local function TauntTarget(unit)
	if unit == "player" then return "target" end
	return unit .. "target"
end

-- The macro for one click that carries gated / assigned bindings (see the header comment), or nil when
-- nothing applies to this button right now.
local function BuildClickMacro(btn, items, button)
	local fights = btn.cwUnitCombat
	local gated, open = {}, {}
	local smart = {}
	for _, b in ipairs(items) do
		local spell, unit = CastName(b, btn), b.unit or btn.unit
		if SMART[b.type] then
			-- first in the macro, and only while the player is out of combat (see the header comment)
			if spell and unit then smart[#smart + 1] = ("[nocombat,target=%s] %s"):format(unit, spell) end
		elseif spell and unit then
			local when, cond = WhenOf(b), ""
			local skip = false
			if when == "OOC" then
				if fights then skip = true else cond = "nocombat," end
			elseif when == "COMBAT" then
				if not fights then cond = "combat," end -- the unit is fighting: allowed whatever we are doing
			end
			if not skip then
				local target, extra = unit, ""
				if b.type == "taunt" then target, extra = TauntTarget(unit), ",harm,nodead" end
				local clause = ("[%starget=%s%s] %s"):format(cond, target, extra, spell)
				if cond ~= "" then gated[#gated + 1] = clause else open[#open + 1] = clause end
			end
		end
	end
	-- an unconditional clause matches whatever follows it, so it goes last
	for _, clause in ipairs(open) do gated[#gated + 1] = clause end
	for i = #smart, 1, -1 do table.insert(gated, 1, smart[i]) end
	if #gated == 0 then return nil end
	local text = "/cast " .. table.concat(gated, "; ")
	-- a left click that only has smart clauses keeps targeting the unit once combat starts (the macro replaced
	-- the default target click); other buttons have nothing to fall back to and the editor says so
	-- [belief] `/target [combat] <unit>` is understood by a secure macro; if not, the line is a harmless no-op
	if #smart > 0 and #smart == #gated and button == "1" and btn.unit then
		text = text .. "\n/target [combat] " .. btn.unit
	end
	return text
end

-- The parts of a button's attributes that follow live state: the unit it shows, whether that unit is
-- fighting, the buff the assignment rules picked for it, the spell that removes its debuff and the rez.
local function Signature(btn)
	return (btn.unit or "") .. "|" .. (btn.cwUnitCombat and "1" or "0") .. "|" .. (btn.cwAssignedSpell or "")
		.. "|" .. (btn.cwCureSpell or "") .. "|" .. (btn.cwRezSpell or "")
end

-- A binding that does not depend on live state: plain secure attributes that follow the button's own unit.
local function ApplyPlain(btn, applied, b)
	local prefix, suffix, kind = b.modifier or "", b.button, b.type
	if kind == "spell" and b.spell then
		SetAttr(btn, applied, prefix, "type", suffix, "spell")
		SetAttr(btn, applied, prefix, "spell", suffix, CastName(b, btn)) -- "Name(Rank N)" is accepted by type=spell
		if b.unit then
			SetAttr(btn, applied, prefix, "unit", suffix, b.unit)
		end
	elseif kind == "buff" and b.group then
		-- a buff GROUP binding: resolved here (out of combat) to the player's highest-priority
		-- known spell of that group, so the secure attribute never depends on live aura state
		local spell = CastName(b, btn)
		if spell then
			SetAttr(btn, applied, prefix, "type", suffix, "spell")
			SetAttr(btn, applied, prefix, "spell", suffix, spell)
		end
	elseif kind == "macro" and b.macro then
		SetAttr(btn, applied, prefix, "type", suffix, "macro")
		SetAttr(btn, applied, prefix, "macrotext", suffix, b.macro)
	elseif kind == "target" or kind == "focus" or kind == "assist" then
		SetAttr(btn, applied, prefix, "type", suffix, kind)
	end
end

-- Must only be called out of combat.
function ClickCast:ApplyToButton(btn)
	-- clear everything this addon set previously so removed bindings really go away
	local previous = btn.cwAttrs
	if previous then
		for i = 1, #previous do
			btn:SetAttribute(previous[i], nil)
		end
	end

	-- the bindings of one click are decided together: they may have to share one macro
	local clicks, order = {}, {}
	for _, b in ipairs(self:GetBindings()) do
		local prefix, suffix = b.modifier or "", b.button
		local id = prefix .. suffix
		local click = clicks[id]
		if not click then
			click = {prefix = prefix, suffix = suffix, items = {}}
			clicks[id] = click
			order[#order + 1] = click
		end
		click.items[#click.items + 1] = b
	end

	local applied = {}
	for _, click in ipairs(order) do
		if NeedsMacro(click.items) then
			local text = BuildClickMacro(btn, click.items, click.suffix)
			if text then
				SetAttr(btn, applied, click.prefix, "type", click.suffix, "macro")
				SetAttr(btn, applied, click.prefix, "macrotext", click.suffix, text)
			end -- else: nothing applies right now, the click falls back to the wildcard defaults
		else
			for _, b in ipairs(click.items) do
				ApplyPlain(btn, applied, b)
			end
		end
	end
	btn.cwAttrs = applied
	btn.cwSigApplied = Signature(btn)
end

-- Is any binding gated on combat (so unit combat states matter)?
function ClickCast:HasGatedBinding()
	for _, b in ipairs(self:GetBindings()) do
		if CASTS[b.type] and WhenOf(b) ~= "ANY" then return true end
	end
	return false
end

-- Does any binding's attribute depend on live state (unit, unit combat, assigned pick, cure / rez pick)?
function ClickCast:IsDynamic()
	for _, b in ipairs(self:GetBindings()) do
		if b.type == "assigned" or b.type == "taunt" or SMART[b.type] or (CASTS[b.type] and WhenOf(b) ~= "ANY") then return true end
	end
	return false
end

-- The class taunt: {spell id, English name}. The English name is tried first, then whatever the id resolves to, so a
-- wrong id cannot hide a known spell. [belief] the ids and names, from game knowledge; a Death Knight's Death
-- Grip and a Hunter's Distracting Shot are no taunts and are not here.
local TAUNT = {
	WARRIOR = {355, "Taunt"},
	PALADIN = {62124, "Hand of Reckoning"},
	DEATHKNIGHT = {56222, "Dark Command"},
	DRUID = {6795, "Growl"},
}

function ClickCast:RebuildTaunt()
	tauntSpell = nil
	local entry = TAUNT[ClassKey()]
	if entry then
		for _, name in ipairs({entry[2], GetSpellInfo(entry[1])}) do
			if CW.KnowsSpell(name) then
				tauntSpell = name
				return
			end
		end
	end
end

function ClickCast:TauntSpell()
	return tauntSpell
end

-- The class resurrection: {spell id, English name}. Not Rebirth (combat only, and the smart clicks are out of
-- combat only) and not the Death Knight's Raise Ally or the Warlock's Soulstone, which are no resurrection.
-- [belief] the ids and names, from game knowledge (Range.lua uses the same ids for its dead-unit range check).
local REZ = {
	PRIEST = {2006, "Resurrection"},
	PALADIN = {7328, "Redemption"},
	SHAMAN = {2008, "Ancestral Spirit"},
	DRUID = {50769, "Revive"},
}
local rezSpell -- the spell the player knows, or nil

function ClickCast:RebuildRez()
	rezSpell = nil
	local entry = REZ[ClassKey()]
	if entry then
		local name = GetSpellInfo(entry[1]) or entry[2]
		if CW.KnowsSpell(name) then rezSpell = name end
	end
end

function ClickCast:RezSpell()
	return rezSpell
end

-- Is there a smart resurrect click?
function ClickCast:HasRezBinding()
	for _, b in ipairs(self:GetBindings()) do
		if b.type == "rez" then return true end
	end
	return false
end

local function RezPick(btn)
	local unit = btn.unit
	if rezSpell and unit and UnitIsConnected(unit) and UnitIsDeadOrGhost(unit) and ClickCast:HasRezBinding() then
		return rezSpell
	end
end

-- Called when a unit's dead / offline state changed (UnitFrame:UpdateHealth): the click is rewritten out of combat.
function ClickCast:UpdateRez(btn)
	local pick = RezPick(btn)
	if btn.cwRezSpell ~= pick then
		btn.cwRezSpell = pick
		self:Sync(btn)
	end
end

-- Is there a smart cure click? (Debuffs.lua then works out each unit's cure spell even with the highlight off.)
function ClickCast:HasCureBinding()
	for _, b in ipairs(self:GetBindings()) do
		if b.type == "cure" then return true end
	end
	return false
end

-- Called whenever something the signature covers may have changed (Buffs:UpdateButton, the poll below).
-- The rewrite itself waits for the end of combat.
function ClickCast:Sync(btn)
	local sig = Signature(btn)
	if sig == btn.cwSigApplied then return end
	if self:IsDynamic() then
		CW:RunOOC("clickcast.sync", ClickCast.RefreshDynamic, ClickCast)
	else
		btn.cwSigApplied = sig -- nothing uses it; stop re-checking
	end
end

-- Rewrite the buttons whose unit, unit combat state or assigned buff changed. Out of combat only. The
-- combat state is read fresh: whatever the poll saw last may be up to COMBAT_POLL old, or stale after a fight.
function ClickCast:RefreshDynamic()
	local gated = self:HasGatedBinding()
	for btn in pairs(CW.UnitFrame.frames) do
		btn.cwUnitCombat = gated and UnitFights(btn) or false
		if Signature(btn) ~= btn.cwSigApplied then
			self:ApplyToButton(btn)
		end
	end
end

-- Timer: notice units entering / leaving combat. Only runs its loop while a gated binding exists.
function ClickCast:PollCombat()
	if not self:HasGatedBinding() then return end
	local changed = false
	for btn in pairs(CW.UnitFrame.frames) do
		local fights = UnitFights(btn)
		if fights ~= btn.cwUnitCombat then
			btn.cwUnitCombat = fights
			if Signature(btn) ~= btn.cwSigApplied then changed = true end
		end
	end
	if changed then
		CW:RunOOC("clickcast.sync", ClickCast.RefreshDynamic, ClickCast)
	end
end

function ClickCast:ApplyAll()
	if InCombatLockdown() then
		CW:RunOOC("clickcast.apply", ClickCast.ApplyAll, ClickCast)
		return
	end
	local gated = self:HasGatedBinding()
	self:RebuildRez() -- the spellbook may have changed
	self:RebuildTaunt()
	if CW.Debuffs and self:HasCureBinding() then
		CW.Debuffs:RefreshAll() -- every button's cure pick must be current before its click is written
	end
	for btn in pairs(CW.UnitFrame.frames) do
		btn.cwRezSpell = RezPick(btn) -- likewise the rez pick
		btn.cwUnitCombat = gated and UnitFights(btn) or false -- read fresh: the poll may not have run yet
		self:ApplyToButton(btn)
	end
end

function ClickCast:OnEnable()
	self:RebuildRez()
	self:RebuildTaunt()
	if MigrateBindings() then
		self:ApplyAll() -- buttons may already exist and were set up from the template
	end
	self:RegisterMessage("CLICKWISE_SPELLS_CHANGED", "ApplyAll") -- templates depend on known spells
	self:RegisterMessage("CLICKWISE_PROFILE", "ApplyAll")        -- profile switched / copied / reset
	self:RegisterMessage("CLICKWISE_BUFFS_CHANGED", "ApplyAll")  -- buff-group bindings follow the priority order
	self:ScheduleRepeatingTimer("PollCombat", COMBAT_POLL)
	-- Deliberately NOT subscribed to CLICKWISE_SETTINGS: no options-panel control changes
	-- bindings, and re-writing every secure attribute on every option tweak is wasteful.
end
