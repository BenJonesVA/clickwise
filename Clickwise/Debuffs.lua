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
-- Poison. Only debuffs that carry a type count (a plain bleed or a stun has none and is ignored), except the
-- important ones named below.
--
-- IMPORTANT DEBUFFS (the "bouquet"): the type rule above ranks by dispel type, which knows nothing about WHICH debuff it is,
-- so a Hunter's Mark (Magic) can outrank a boss mechanic, and a debuff with no type (a bleed, a bomb) is never seen at
-- all. A debuff whose NAME is on the important list comes before everything else, typed or not, curable or not, and is
-- drawn in its own color with its icon and stack count. The list is Debuffs.IMPORTANT (shipped data) after the player's own
-- names (profile.debuffs.watch, edited with /cw watch), so the player's come first. Only the DISPLAY follows it: the smart
-- cure click still picks by type (Choose's `typeOnly`), because an important debuff that cannot be removed has no cure.
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
-- unit queries come from CW.API so that Test.lua's invented units answer them (see Compat.lua)
local API = CW.API
local UnitAura, UnitGUID, UnitExists = API.UnitAura, API.UnitGUID, API.UnitExists
local UnitIsConnected, UnitIsDeadOrGhost = API.UnitIsConnected, API.UnitIsDeadOrGhost
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
local IMPORTANT_COLOR = {1, 0.3, 0.7} -- none of the four type colors, and not the threat ring's red / yellow
Debuffs.IMPORTANT_COLOR = IMPORTANT_COLOR

-- Encounter debuffs worth a glance, highest priority first (after the player's own list). enUS names, matched
-- ignoring case and any rank. [belief] these names are from memory of the 3.3.5 raids, not read from the API: a
-- wrong or missing one is harmless (it just never matches), and `/cw watch add <name>` adds what is missing.
Debuffs.IMPORTANT = {
	-- Icecrown Citadel
	"Necrotic Plague", "Unbound Plague", "Mark of the Fallen Champion", "Frost Beacon", "Instability", "Unchained Magic",
	"Impaled", "Gastric Bloat", "Vile Gas", "Mutated Infection", "Boiling Blood", "Rune of Blood",
	-- Trial of the Crusader
	"Legion Flame", "Incinerate Flesh", "Burning Bile", "Paralytic Toxin",
	-- Ulduar, Naxxramas
	"Light Bomb", "Gravity Bomb", "Living Bomb", "Mutating Injection", "Web Wrap",
}

local importantRank = {} -- [lowercased name] = position in the combined list (1 = highest priority)

local function Normalize(name)
	return type(name) == "string" and name:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
end

-- The combined list is rebuilt whenever settings or the profile change (RefreshAll).
function Debuffs:RebuildImportant()
	importantRank = {}
	local s = CW.db.profile.debuffs
	if not s.important then return end
	local n = 0
	local function add(name)
		local key = Normalize(name)
		if key ~= "" and not importantRank[key] then
			n = n + 1
			importantRank[key] = n
		end
	end
	for _, name in ipairs(s.watch or {}) do add(name) end
	for _, name in ipairs(self.IMPORTANT) do add(name) end
end

-- Position of a debuff name in the important list, or nil.
function Debuffs:ImportantRank(name)
	return importantRank[Normalize(name)]
end

-- The player's own names, in order (a copy).
function Debuffs:GetWatch()
	local out = {}
	for i, name in ipairs(CW.db.profile.debuffs.watch or {}) do out[i] = name end
	return out
end

-- Put a name at the top of the player's own list (it moves there if it is already on it). Returns the stored
-- name, or nil for an empty one.
function Debuffs:AddWatch(name)
	local key = Normalize(name)
	if key == "" then return nil end
	local s = CW.db.profile.debuffs
	local list = {}
	for _, old in ipairs(s.watch or {}) do
		if Normalize(old) ~= key then list[#list + 1] = old end
	end
	local stored = name:gsub("^%s+", ""):gsub("%s+$", "")
	table.insert(list, 1, stored)
	s.watch = list
	self:RefreshAll()
	return stored
end

-- Take a name off the player's own list. Returns whether it was there.
function Debuffs:RemoveWatch(name)
	local key = Normalize(name)
	local s = CW.db.profile.debuffs
	local list, found = {}, false
	for _, old in ipairs(s.watch or {}) do
		if Normalize(old) == key then found = true else list[#list + 1] = old end
	end
	if found then
		s.watch = list
		self:RefreshAll()
	end
	return found
end

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

-- `/cw watch`, `/cw watch add <debuff>`, `/cw watch remove <debuff>`: the reply lines.
function Debuffs:WatchCommand(rest)
	local sub, name = (rest or ""):match("^(%S*)%s*(.-)%s*$")
	sub = sub:lower()
	if sub == "add" then
		local stored = self:AddWatch(name)
		if not stored then return {"Usage: /cw watch add <debuff name>"} end
		return {("Watching %s: it now comes first on every frame, whatever its type."):format(stored)}
	elseif sub == "remove" or sub == "del" or sub == "delete" then
		if self:RemoveWatch(name) then return {("No longer watching %s."):format(name)} end
		return {("%s is not on your own list (the built-in list is not editable)."):format(name)}
	elseif sub ~= "" then
		return {"Usage: /cw watch | /cw watch add <debuff name> | /cw watch remove <debuff name>"}
	end
	local mine = self:GetWatch()
	local lines = {}
	lines[1] = #mine > 0 and ("Your important debuffs, highest priority first: " .. table.concat(mine, ", "))
		or "You have no important debuffs of your own yet: /cw watch add <debuff name> (see `/cw debuffs` for the exact names)."
	lines[2] = ("Built in: %s."):format(table.concat(self.IMPORTANT, ", "))
	if not CW.db.profile.debuffs.important then lines[3] = "Important debuffs are switched off (Layout tab: Important debuffs first)." end
	return lines
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
		local rank = importantRank[Normalize(name)]
		lines[#lines + 1] = ("%d. %s  [type: %s, stacks: %s, you can remove it: %s%s]"):format(i, name,
			debuffType and debuffType ~= "" and debuffType or "-", tostring(count),
			(debuffType and canCure[debuffType]) and "yes" or "no", rank and (", important #" .. rank) or "")
	end
	if #lines == 0 then lines[1] = "No debuffs on " .. unit .. "." end
	return lines
end

--------------------------------------------------------------------------------
-- Pure rule (asserted directly by the harness)
--------------------------------------------------------------------------------
-- list = {{type =, curable =, important =, ...}, ...}. The entry to show: an important one first (the lowest
-- `important` position wins; it needs no type and ignores `onlyCurable`), else curable before not curable, then by
-- type priority; nil when nothing qualifies (`onlyCurable` drops the ones the player cannot remove). `typeOnly` skips
-- the important tier (the cure click: only a typed debuff has a cure).
function Debuffs.Choose(list, onlyCurable, typeOnly)
	if not typeOnly then
		local top
		for _, d in ipairs(list) do
			if d.important and (not top or d.important < top.important) then top = d end
		end
		if top then return top end
	end
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
	local d = Debuffs.Choose(list, true, true)
	return d and cureSpell[d.type] or nil
end

-- Every typed harmful aura on the unit, and every important one (typed or not).
function Debuffs:Collect(unit)
	local list = {}
	for i = 1, 40 do
		local name, _, icon, count, debuffType = UnitAura(unit, i, "HARMFUL")
		if not name then break end
		local typed = debuffType and PRIORITY[debuffType] and debuffType or nil
		local important = importantRank[Normalize(name)]
		if typed or important then
			list[#list + 1] = {name = name, icon = icon, count = count, type = typed, curable = typed and canCure[typed] or false,
				important = important}
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
		if (a.important ~= nil) ~= (b.important ~= nil) then return a.important ~= nil end
		if a.important then return a.important < b.important end
		if a.curable ~= b.curable then return a.curable end
		return PRIORITY[a.type] < PRIORITY[b.type]
	end)
	for _, d in ipairs(list) do
		local c = d.important and IMPORTANT_COLOR or COLORS[d.type]
		local k = (d.curable or d.important) and 1 or DIM
		local right = d.type
		if d.important then right = d.type and (L["Important"] .. ", " .. d.type) or L["Important"] end
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
	local count = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- stacks of an important debuff
	count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, 0)
	count:Hide()
	btn.cwDebuffHolder, btn.cwDebuffEdges, btn.cwDebuffIcon, btn.cwDebuffCount = holder, edges, icon, count
	self:LayoutButton(btn)
end

function Debuffs:LayoutButton(btn)
	local icon = btn.cwDebuffIcon
	if not icon then return end
	local size = math.max(8, math.min(14, math.floor(CW:Look("height") * 0.36)))
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
		btn.cwDebuffCount:Hide()
		return
	end
	local c = d.important and IMPORTANT_COLOR or COLORS[d.type]
	local k = (d.curable or d.important) and 1 or DIM
	for i = 1, 4 do
		CW.SetSolidColor(edges[i], c[1] * k, c[2] * k, c[3] * k, 1)
		edges[i]:Show()
	end
	-- an important debuff always shows its icon: without a type color, the icon is what says which one it is
	if (d.important or CW:Look("debuffIcon")) and d.icon then
		btn.cwDebuffIcon:SetTexture(d.icon)
		btn.cwDebuffIcon:Show()
	else
		btn.cwDebuffIcon:Hide()
	end
	if d.important and type(d.count) == "number" and d.count > 1 and btn.cwDebuffIcon:IsShown() then
		btn.cwDebuffCount:SetText(d.count)
		btn.cwDebuffCount:Show()
	else
		btn.cwDebuffCount:Hide()
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
	self:RebuildImportant()
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
