-- Debuff highlight: a colored border (and the debuff's icon) on a unit's frame while it carries a
-- debuff of a type the player can remove, in the usual colors:
--   Magic = blue, Curse = purple, Disease = brown, Poison = green.
--
-- What the player can remove comes from the spells the player knows (CURES below, resolved against the
-- spellbook cache and rebuilt whenever the spellbook changes), so a Paladin with Purify sees Disease and
-- Poison and, once Cleanse is learned, Magic too. With "only debuffs I can remove" off, other typed
-- debuffs are shown as well, darker, so a curable one always stands out.
--
-- When a unit has several, the one shown is: curable before not curable, then Magic > Curse > Disease >
-- Poison. Only debuffs that carry a type count (a plain bleed or a stun has none and is ignored).
--
-- Display only: textures under a non-secure child frame, so painting is legal in combat.
--
-- [belief] UnitAura's debuff type is the English word on an English client ("Magic", "Curse", "Disease",
-- "Poison"); on other locales it is localized, and this addon ships enUS only.

local CW = Clickwise
local Debuffs = CW:NewModule("Debuffs", "AceEvent-3.0", "AceTimer-3.0")
CW.Debuffs = Debuffs

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local pairs, ipairs, type = pairs, ipairs, type
local UnitAura, UnitGUID, UnitExists = UnitAura, UnitGUID, UnitExists
local UnitIsConnected, UnitIsDeadOrGhost = UnitIsConnected, UnitIsDeadOrGhost
local GetSpellInfo = GetSpellInfo

local FLUSH_DELAY = 0.2 -- UNIT_AURA is spammy in raids; coalesce per GUID (as Buffs.lua does)
local EDGE = 2          -- border thickness inside the frame's own 1 unit border
local DIM = 0.55        -- a debuff the player cannot remove is drawn this much darker

-- Spells that remove debuffs from a friendly unit: {spell id, English name, types it removes}. The order is the
-- preference for the smart cure click: for a type, the first KNOWN spell here is the one cast (the broader or
-- better spell comes first: Cleanse before Purify, Abolish before Cure).
-- IDs are per spell, not per rank; the name is re-resolved with GetSpellInfo(id) and the English name is
-- the fallback. [belief] all from game knowledge / Decursive 2.5.1's table, not readable from the API;
-- `/cw dispels` prints what the client resolved so a wrong entry is a one-line fix here.
Debuffs.CURES = {
	{id = 527, name = "Dispel Magic", types = {"Magic"}},                    -- priest
	{id = 552, name = "Abolish Disease", types = {"Disease"}},               -- priest
	{id = 528, name = "Cure Disease", types = {"Disease"}},                  -- priest
	{id = 4987, name = "Cleanse", types = {"Magic", "Disease", "Poison"}},   -- paladin
	{id = 1152, name = "Purify", types = {"Disease", "Poison"}},             -- paladin
	{id = 2893, name = "Abolish Poison", types = {"Poison"}},                -- druid
	{id = 8946, name = "Cure Poison", types = {"Poison"}},                   -- druid
	{id = 2782, name = "Remove Curse", types = {"Curse"}},                   -- druid
	{id = 475, name = "Remove Curse", types = {"Curse"}},                    -- mage
	{id = 526, name = "Cure Toxins", types = {"Poison", "Disease"}},         -- shaman
	{id = 51886, name = "Cleanse Spirit", types = {"Curse"}},                -- shaman, restoration talent
}

Debuffs.COLORS = {
	Magic = {0.2, 0.6, 1},
	Curse = {0.7, 0.25, 0.9},
	Disease = {0.65, 0.45, 0.1},
	Poison = {0.1, 0.8, 0.2},
}
local PRIORITY = {Magic = 1, Curse = 2, Disease = 3, Poison = 4}
local COLORS = Debuffs.COLORS

local canCure, cureSpell = {}, {} -- [type] = true / the spell that removes it, for the spells the player knows

function Debuffs:RebuildCures()
	canCure, cureSpell = {}, {}
	for _, cure in ipairs(self.CURES) do
		local name = GetSpellInfo(cure.id) or cure.name
		if CW.KnowsSpell(name) then
			for _, debuffType in ipairs(cure.types) do
				canCure[debuffType] = true
				cureSpell[debuffType] = cureSpell[debuffType] or name
			end
		end
	end
end

function Debuffs:CanCure(debuffType)
	return canCure[debuffType] and true or false
end

-- "Magic (Cleanse), Curse (Remove Curse)": what the player can remove, or nil when nothing.
function Debuffs:CureSummary()
	local can = {}
	for _, debuffType in ipairs({"Magic", "Curse", "Disease", "Poison"}) do
		if canCure[debuffType] then can[#can + 1] = debuffType .. " (" .. cureSpell[debuffType] .. ")" end
	end
	return #can > 0 and table.concat(can, ", ") or nil
end

-- Lines for `/cw dispels`: what the player can remove and which spells the client resolved.
function Debuffs:Describe()
	local lines = {}
	for _, cure in ipairs(self.CURES) do
		local name = GetSpellInfo(cure.id)
		local known = CW.KnowsSpell(name or cure.name)
		lines[#lines + 1] = ("%s (id %d)%s%s: %s"):format(cure.name, cure.id,
			(name and name ~= cure.name) and (" resolves to " .. name) or (name and "" or " does not resolve"),
			known and " [known]" or "", table.concat(cure.types, ", "))
	end
	local summary = self:CureSummary()
	lines[#lines + 1] = summary and ("You can remove: " .. summary) or "You know no spell that removes debuffs."
	return lines
end

-- Lines for `/cw debuffs [unit]`: every harmful aura with the type the client reports (empty = none).
function Debuffs:DumpUnit(unit)
	if not UnitExists(unit) then return {"No such unit: " .. tostring(unit)} end
	local lines = {}
	for i = 1, 40 do
		local name, _, _, count, debuffType = UnitAura(unit, i, "HARMFUL")
		if not name then break end
		lines[#lines + 1] = ("%d. %s  [type: %s, stacks: %s, you can remove it: %s]"):format(i, name,
			debuffType and debuffType ~= "" and debuffType or "-", tostring(count),
			(debuffType and canCure[debuffType]) and "yes" or "no")
	end
	if #lines == 0 then lines[1] = "No debuffs on " .. unit .. "." end
	return lines
end

--------------------------------------------------------------------------------
-- Pure rule (asserted directly by the harness)
--------------------------------------------------------------------------------
-- list = {{type =, curable =, ...}, ...}. The entry to show: curable before not curable, then by type
-- priority; nil when nothing qualifies (`onlyCurable` drops the ones the player cannot remove).
function Debuffs.Choose(list, onlyCurable)
	local best
	for _, d in ipairs(list) do
		local rank = PRIORITY[d.type]
		if rank and (d.curable or not onlyCurable) then
			if not best or (d.curable and not best.curable)
				or (d.curable == best.curable and rank < PRIORITY[best.type]) then
				best = d
			end
		end
	end
	return best
end

-- The spell the smart cure click casts for a unit with these debuffs (a Collect result): the one that removes
-- the most urgent debuff the player can remove, or nil. Deliberately independent of the display options.
function Debuffs.CureFor(list)
	local d = Debuffs.Choose(list, true)
	return d and cureSpell[d.type] or nil
end

-- Every typed harmful aura on the unit.
function Debuffs:Collect(unit)
	local list = {}
	for i = 1, 40 do
		local name, _, icon, count, debuffType = UnitAura(unit, i, "HARMFUL")
		if not name then break end
		if debuffType and PRIORITY[debuffType] then
			list[#list + 1] = {name = name, icon = icon, count = count, type = debuffType, curable = canCure[debuffType] or false}
		end
	end
	return list
end

-- Lines for the hover tooltip: every typed debuff, curable ones first, with the spell that removes it.
-- Each line is {left, right, r, g, b}.
function Debuffs:TooltipLines(btn)
	local out = {}
	local unit = btn.unit
	if not (unit and CW.db.profile.debuffs.enabled) then return out end
	self:UpdateButton(btn) -- a fresh read: the hover can come before the coalesced aura update, and the border must agree
	local list = self:Collect(unit)
	table.sort(list, function(a, b)
		if a.curable ~= b.curable then return a.curable end
		return PRIORITY[a.type] < PRIORITY[b.type]
	end)
	for _, d in ipairs(list) do
		local c = COLORS[d.type]
		local k = d.curable and 1 or DIM
		local right = d.type
		if d.curable then right = right .. " (" .. cureSpell[d.type] .. ")" end
		local left = d.name
		if type(d.count) == "number" and d.count > 1 then left = left .. " x" .. d.count end
		out[#out + 1] = {left = left, right = right, r = c[1] * k, g = c[2] * k, b = c[3] * k}
	end
	return out
end

--------------------------------------------------------------------------------
-- Widgets (created with the unit button; see UnitFrame:InitButton)
--------------------------------------------------------------------------------
function Debuffs:InitButton(btn)
	if btn.cwDebuffHolder then return end
	local holder = CreateFrame("Frame", nil, btn)
	holder:SetFrameLevel(btn:GetFrameLevel() + 5)
	holder:SetAllPoints(btn)
	local edges = {}
	for i = 1, 4 do
		local tex = holder:CreateTexture(nil, "OVERLAY")
		CW.SetSolidColor(tex, 1, 1, 1, 1)
		tex:Hide()
		edges[i] = tex
	end
	-- top, bottom, left, right: inside the frame's own 1 unit border
	edges[1]:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
	edges[1]:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -1, -1)
	edges[1]:SetHeight(EDGE)
	edges[2]:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 1, 1)
	edges[2]:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
	edges[2]:SetHeight(EDGE)
	edges[3]:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
	edges[3]:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 1, 1)
	edges[3]:SetWidth(EDGE)
	edges[4]:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -1, -1)
	edges[4]:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
	edges[4]:SetWidth(EDGE)

	local icon = holder:CreateTexture(nil, "OVERLAY")
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -EDGE - 2, -EDGE - 2) -- the role icon has the top-left corner
	icon:Hide()
	btn.cwDebuffHolder, btn.cwDebuffEdges, btn.cwDebuffIcon = holder, edges, icon
	self:LayoutButton(btn)
end

function Debuffs:LayoutButton(btn)
	local icon = btn.cwDebuffIcon
	if not icon then return end
	local size = math.max(8, math.min(14, math.floor(CW.db.profile.frame.height * 0.36)))
	icon:SetSize(size, size)
end

--------------------------------------------------------------------------------
-- Scan and paint
--------------------------------------------------------------------------------
function Debuffs:Paint(btn)
	local edges = btn.cwDebuffEdges
	if not edges then return end
	local d = btn.cwDebuff
	if not d then
		for i = 1, 4 do edges[i]:Hide() end
		btn.cwDebuffIcon:Hide()
		return
	end
	local c = COLORS[d.type]
	local k = d.curable and 1 or DIM
	for i = 1, 4 do
		CW.SetSolidColor(edges[i], c[1] * k, c[2] * k, c[3] * k, 1)
		edges[i]:Show()
	end
	if CW.db.profile.debuffs.icon and d.icon then
		btn.cwDebuffIcon:SetTexture(d.icon)
		btn.cwDebuffIcon:Show()
	else
		btn.cwDebuffIcon:Hide()
	end
end

function Debuffs:UpdateButton(btn)
	if not btn.cwDebuffEdges then return end
	local s = CW.db.profile.debuffs
	local unit = btn.unit
	local best, cure
	if unit and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) and (s.enabled or CW.ClickCast:HasCureBinding()) then
		local list = self:Collect(unit)
		if s.enabled then best = self.Choose(list, s.onlyMine) end
		cure = self.CureFor(list)
	end
	btn.cwDebuff = best
	self:Paint(btn)
	if btn.cwCureSpell ~= cure then
		btn.cwCureSpell = cure
		CW.ClickCast:Sync(btn) -- a smart cure click is rewritten (out of combat) when the pick changes
	end
end

function Debuffs:RefreshAll()
	for btn in pairs(CW.UnitFrame.frames) do
		if btn.cwDebuffEdges then
			self:LayoutButton(btn)
			self:UpdateButton(btn)
		end
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local dirty, flushScheduled = {}, false

function Debuffs:FlushDirty()
	flushScheduled = false
	local guidFrames = CW.UnitFrame.guidFrames
	for guid in pairs(dirty) do
		dirty[guid] = nil
		local set = guidFrames[guid]
		if set then
			for btn in pairs(set) do self:UpdateButton(btn) end
		end
	end
end

function Debuffs:OnUnitAura(_, unit)
	if type(unit) ~= "string" then return end
	local guid = UnitGUID(unit)
	if not guid or not CW.UnitFrame.guidFrames[guid] then return end
	dirty[guid] = true
	if not flushScheduled then
		flushScheduled = true
		self:ScheduleTimer("FlushDirty", FLUSH_DELAY)
	end
end

function Debuffs:OnSpellsChanged()
	self:RebuildCures()
	self:RefreshAll()
end

function Debuffs:OnEnable()
	self:RebuildCures()
	self:RegisterEvent("UNIT_AURA", "OnUnitAura")
	self:RegisterMessage("CLICKWISE_SETTINGS", "RefreshAll")
	self:RegisterMessage("CLICKWISE_PROFILE", "RefreshAll")
	self:RegisterMessage("CLICKWISE_SPELLS_CHANGED", "OnSpellsChanged")
	self:RefreshAll()
end
