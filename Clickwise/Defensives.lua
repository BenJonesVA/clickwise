-- Active defensives: the icons of the defensive cooldowns that are UP on a unit right now (Shield Wall, Guardian
-- Spirit, Pain Suppression...), drawn in the middle of the unit's frame with the seconds left on each. The point is to
-- see at a glance that a tank is already covered, so a second external is not wasted on top of the first.
--
-- It is about active auras only. What another player's cooldown is doing while it is NOT running (ready or not) cannot
-- be read on 3.3.5, so nothing here says or implies that a defensive is available.
--
-- LIST below is the whole catalogue, in priority order: when a unit has more than MAX_SHOWN of them, the first ones
-- win. An aura counts whoever cast it. An icon has a gold border when someone ELSE cast it on the unit (an external:
-- the healer's Guardian Spirit) and a grey one when it is the unit's own cooldown.
--
-- Display only: textures under a non-secure child frame, so painting is legal in combat. Set apart from Buffs.lua and
-- Debuffs.lua (which scan the same unit's auras for their own purposes) because it has its own settings and its own
-- widgets; the scan is one cheap walk per coalesced UNIT_AURA burst.
--
-- IDs: all from Grid2's 3.3.5 "Defensive Cooldowns" group (Grid2Options/modules/statuses/StatusAuraNew.lua) and
-- HealBot 3.3.5.4's localization file (Hand of Protection), so they are real 3.3.5 IDs. As everywhere, the name is
-- re-resolved with GetSpellInfo(id) and the English name is the fallback, and auras are matched by NAME:
-- `/cw buffcheck` also checks this list. Deliberately left out (say so if wanted): Shield Block and Holy Shield
-- (up half the time, so they would be on the icon nearly always), Divine Shield / Ice Block and the other immunity
-- bubbles, Hand of Salvation (it lowers threat, which a tank does not want).

local CW = Clickwise
local Defensives = CW:NewModule("Defensives", "AceEvent-3.0", "AceTimer-3.0")
CW.Defensives = Defensives

local pairs, ipairs, type = pairs, ipairs, type
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
-- unit queries come from CW.API so that Test.lua's invented units answer them (see Compat.lua)
local API = CW.API
local UnitAura, UnitGUID, UnitExists, UnitName, UnitIsUnit = API.UnitAura, API.UnitGUID, API.UnitExists, API.UnitName, API.UnitIsUnit
local UnitIsConnected, UnitIsDeadOrGhost = API.UnitIsConnected, API.UnitIsDeadOrGhost
local GetSpellInfo, GetTime = GetSpellInfo, GetTime

local FLUSH_DELAY = 0.2  -- UNIT_AURA is spammy in raids; coalesce per GUID (as Buffs.lua does)
local TICK = 0.25        -- seconds between the countdown updates
local RESCAN_GAP = 1     -- an icon whose time ran out asks for a fresh read at most this often (the safety net)
local MAX_SHOWN = 2      -- icons on a frame
local GAP = 3            -- between two icons
local BORDER = 1         -- thickness of an icon's coloured border
local EXTERNAL = {1, 0.82, 0.1}
local OWN = {0.7, 0.7, 0.7}

Defensives.LIST = {
	-- externals first: the ones somebody else puts on you
	{id = 47788, name = "Guardian Spirit"},
	{id = 33206, name = "Pain Suppression"},
	{id = 6940, name = "Hand of Sacrifice"},
	{id = 1022, name = "Hand of Protection"},
	-- the unit's own cooldowns, the big ones first
	{id = 871, name = "Shield Wall"},
	{id = 12975, name = "Last Stand"},
	{id = 31850, name = "Ardent Defender"},
	{id = 48792, name = "Icebound Fortitude"},
	{id = 55233, name = "Vampiric Blood"},
	{id = 61336, name = "Survival Instincts"},
	{id = 48707, name = "Anti-Magic Shell"},
	{id = 49028, name = "Dancing Rune Weapon"},
	{id = 22812, name = "Barkskin"},
	{id = 498, name = "Divine Protection"},
	{id = 22842, name = "Frenzied Regeneration"},
}

local rankOf = {} -- [resolved spell name] = place in LIST (1 = highest priority)
local watch = {}  -- [btn] = true while it shows a countdown

-- Re-resolve every name from its ID (locale-safe); the English name is only the fallback when the client does not
-- know the ID. `english` keeps the data table's name for /cw buffcheck.
function Defensives:ResolveNames()
	rankOf = {}
	for rank, entry in ipairs(self.LIST) do
		entry.english = entry.english or entry.name
		local name = GetSpellInfo(entry.id)
		if type(name) == "string" and name ~= "" then entry.name = name end
		rankOf[entry.name] = rank
	end
end

-- Lines for `/cw buffcheck`: the same check as for the buff groups (Buffs.CheckSpells).
function Defensives:CheckData()
	local entries = {}
	for _, entry in ipairs(self.LIST) do
		entries[#entries + 1] = {label = "DEFENSIVE", id = entry.id, expected = entry.english or entry.name}
	end
	return CW.Buffs.CheckSpells(entries, "defensive", "Defensives.lua")
end

-- "12" seconds, "2m" from a minute up; the countdown on an icon. `suffix`: "12s" (the tooltip).
function Defensives.FormatTime(left, suffix)
	if left >= 60 then return floor(left / 60 + 0.5) .. "m" end
	return ceil(left) .. (suffix and "s" or "")
end

--------------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------------
-- Every defensive aura up on the unit, highest priority first, one per spell:
--   {name, icon, rank, expires (nil = does not run out), external (cast by someone else), caster (a unit token)}
function Defensives:Collect(unit)
	local list, seen = {}, {}
	for i = 1, 40 do
		local name, _, icon, _, _, duration, expires, caster = UnitAura(unit, i, "HELPFUL")
		if not name then break end
		local rank = rankOf[name]
		if rank and not seen[name] then
			seen[name] = true
			local timed = type(duration) == "number" and duration > 0 and type(expires) == "number" and expires > 0
			list[#list + 1] = {name = name, icon = icon, rank = rank, expires = timed and expires or nil,
				external = type(caster) == "string" and not UnitIsUnit(caster, unit), caster = caster}
		end
	end
	table.sort(list, function(a, b) return a.rank < b.rank end)
	return list
end

-- Lines for `/cw defensives [unit]`
function Defensives:DumpUnit(unit)
	if not UnitExists(unit) then return {"No such unit: " .. tostring(unit)} end
	local lines = {}
	local now = GetTime()
	for i, d in ipairs(self:Collect(unit)) do
		local who = d.external and ("cast by " .. (d.caster and UnitName(d.caster) or "someone else")) or "its own"
		local left = d.expires and self.FormatTime(max(0, d.expires - now), true) or "no time limit"
		lines[#lines + 1] = ("%d. %s  [%s, %s]%s"):format(i, d.name, who, left, i <= MAX_SHOWN and "  <- on the frame" or "")
	end
	if #lines == 0 then lines[1] = "No tracked defensive is up on " .. unit .. "." end
	if not CW.db.profile.defensives.enabled then lines[#lines + 1] = "(Defensive icons are switched off on the General tab.)" end
	return lines
end

-- Lines for the hover tooltip: every defensive up, with who put it there and the time left. {left, right, r, g, b}.
function Defensives:TooltipLines(btn)
	local out = {}
	local unit = btn.unit
	if not (unit and CW.db.profile.defensives.enabled) then return out end
	self:UpdateButton(btn) -- a fresh read: the hover can come before the coalesced aura update
	local now = GetTime()
	for _, d in ipairs(btn.cwDef or {}) do
		local left = d.name
		if d.external and d.caster and UnitExists(d.caster) then left = left .. " (" .. (UnitName(d.caster) or "?") .. ")" end
		local c = d.external and EXTERNAL or OWN
		out[#out + 1] = {left = left, right = d.expires and self.FormatTime(max(0, d.expires - now), true) or "", r = c[1], g = c[2], b = c[3]}
	end
	return out
end

--------------------------------------------------------------------------------
-- Widgets (created with the unit button; see UnitFrame:InitButton)
--------------------------------------------------------------------------------
function Defensives:InitButton(btn)
	if btn.cwDefHolder then return end
	local holder = CreateFrame("Frame", nil, btn)
	holder:SetFrameLevel(btn:GetFrameLevel() + 6) -- above the name, the buff icons and the debuff icon
	holder:SetAllPoints(btn)
	local slots = {}
	for i = 1, MAX_SHOWN do
		local border = holder:CreateTexture(nil, "BACKGROUND")
		CW.SetSolidColor(border, 1, 1, 1, 1)
		local icon = holder:CreateTexture(nil, "ARTWORK")
		icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local text = holder:CreateFontString(nil, "OVERLAY")
		border:Hide()
		icon:Hide()
		text:Hide()
		slots[i] = {border = border, icon = icon, text = text}
	end
	btn.cwDefHolder, btn.cwDefSlots, btn.cwDefSize = holder, slots, 16
	self:LayoutButton(btn)
end

-- The icons follow the frame height (a tank's small frame gets small icons)
function Defensives:LayoutButton(btn)
	local slots = btn.cwDefSlots
	if not slots then return end
	local size = max(14, min(26, floor(CW:Look("height") * 0.7)))
	btn.cwDefSize = size
	for _, s in ipairs(slots) do
		s.icon:SetSize(size, size)
		s.border:SetSize(size + 2 * BORDER, size + 2 * BORDER)
		s.border:ClearAllPoints()
		s.border:SetPoint("CENTER", s.icon, "CENTER", 0, 0)
		s.text:SetFont(STANDARD_TEXT_FONT, max(8, min(12, floor(size * 0.5))), "OUTLINE")
		s.text:ClearAllPoints()
		s.text:SetPoint("CENTER", s.icon, "CENTER", 0, 0)
	end
	self:Paint(btn)
end

--------------------------------------------------------------------------------
-- Paint and update
--------------------------------------------------------------------------------
local function UpdateDriver()
	local driver = Defensives.driver
	if not driver then return end
	if next(watch) then driver:Show() else driver:Hide() end
end

function Defensives:Paint(btn)
	local slots = btn.cwDefSlots
	if not slots then return end
	local list = btn.cwDef
	local n = list and min(#list, MAX_SHOWN) or 0
	local size, now = btn.cwDefSize, GetTime()
	local timed = false
	for i, s in ipairs(slots) do
		local d = i <= n and list[i]
		if d then
			s.icon:ClearAllPoints()
			s.icon:SetPoint("CENTER", btn.cwDefHolder, "CENTER", (i - (n + 1) / 2) * (size + GAP), 0)
			s.icon:SetTexture(d.icon)
			local c = d.external and EXTERNAL or OWN
			CW.SetSolidColor(s.border, c[1], c[2], c[3], 1)
			s.expires = d.expires
			s.shownText = d.expires and self.FormatTime(max(0, d.expires - now)) or ""
			s.text:SetText(s.shownText)
			if d.expires then timed = true end
			s.border:Show()
			s.icon:Show()
			s.text:Show()
		else
			s.expires, s.shownText = nil, nil
			s.border:Hide()
			s.icon:Hide()
			s.text:Hide()
		end
	end
	-- (assigned in one place: the driver calls this while iterating `watch`, and only existing keys may be assigned
	-- during a traversal)
	watch[btn] = timed and true or nil
	UpdateDriver()
end

function Defensives:UpdateButton(btn)
	if not btn.cwDefSlots then return end
	local unit = btn.unit
	local list
	if unit and CW.db.profile.defensives.enabled and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
		list = self:Collect(unit)
		if #list == 0 then list = nil end
	end
	btn.cwDef = list
	self:Paint(btn)
end

-- One countdown step for a button in `watch`.
function Defensives:Tick(btn, now)
	local slots = btn.cwDefSlots
	if not slots then
		watch[btn] = nil
		return
	end
	local gone = false
	for _, s in ipairs(slots) do
		if s.expires then
			local left = s.expires - now
			local text = left > 0 and self.FormatTime(left) or ""
			if text ~= s.shownText then
				s.shownText = text
				s.text:SetText(text)
			end
			if left <= 0 then gone = true end
		end
	end
	if gone and now - (btn.cwDefRescan or 0) >= RESCAN_GAP then
		btn.cwDefRescan = now
		self:UpdateButton(btn) -- normally UNIT_AURA got here first; this is the safety net
	end
end

function Defensives:RefreshAll()
	for btn in pairs(CW.UnitFrame.frames) do
		if btn.cwDefSlots then
			self:LayoutButton(btn)
			self:UpdateButton(btn)
		end
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local dirty, flushScheduled = {}, false

function Defensives:FlushDirty()
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

function Defensives:OnUnitAura(_, unit)
	if type(unit) ~= "string" then return end
	local guid = UnitGUID(unit)
	if not guid or not CW.UnitFrame.guidFrames[guid] then return end
	dirty[guid] = true
	if not flushScheduled then
		flushScheduled = true
		self:ScheduleTimer("FlushDirty", FLUSH_DELAY)
	end
end

-- The countdown driver: a plain non-secure frame whose OnUpdate only runs while it is shown, i.e. while some button
-- is in `watch`.
function Defensives:CreateDriver()
	if self.driver then return end
	local driver = CreateFrame("Frame")
	local acc = 0
	driver:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc < TICK then return end
		acc = 0
		local now = GetTime()
		for btn in pairs(watch) do
			Defensives:Tick(btn, now)
		end
	end)
	driver:Hide()
	self.driver = driver
end

function Defensives:OnEnable()
	self:CreateDriver()
	self:ResolveNames()
	self:RegisterEvent("UNIT_AURA", "OnUnitAura")
	self:RegisterMessage("CLICKWISE_SETTINGS", "RefreshAll")
	self:RegisterMessage("CLICKWISE_PROFILE", "RefreshAll")
	self:RefreshAll()
end
