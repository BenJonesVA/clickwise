-- Threat: while the player is in combat, the unit frames show who has (or is about to take) the enemy's attention.
--
--   Aggro border  a ring just OUTSIDE the frame (the debuff highlight owns the inside edge).
--                 red and pulsing: a healer or damage dealer has the enemy (status 2 or 3).
--                 yellow and steady: about to take it: more threat than the tank (status 1), or at / past the
--                 warning percentage of what it needs to pull (the "Threat warning" setting, combatColor.threat).
--   Threat bar    a thin bar along the bottom edge: how far the unit is toward pulling (100% = it pulls).
--
-- Tanks get neither (they are meant to hold the enemy), nor do pets, nor a unit whose role is not known yet:
-- in a plain five-man the tank is only known once LibGroupTalents has inspected them, and a tank that holds the
-- enemy must not flash red meanwhile. A unit whose role becomes known is picked up at once (UnitFrame:UpdateButton).
--
-- The border needs nothing but UnitThreatSituation(unit), which answers for whatever the unit is fighting. The bar
-- needs the scaled percentage, and that is measured against ONE enemy, so Mob() picks it: the player's hostile
-- target, else the hostile target of a friendly target (a healer targets a party member), else the focus, else
-- the target of a tank in the group. No enemy found = no bar (the border still works).
--
-- Display only: textures under a non-secure child frame, so it is legal in combat. UNIT_THREAT_SITUATION_UPDATE
-- names the unit whose status changed; the percentage has no event, so a 0.5 s poll runs while in combat.
--
-- 3.3.5 facts: [ref] UnitThreatSituation returns nil / 0 (lower threat than the tank, not tanking) / 1 (more threat
-- than the tank, not tanking) / 2 (tanking without the most threat) / 3 (securely tanking);
-- UnitDetailedThreatSituation(unit, mob) returns isTanking, status, scaledPercent, rawPercent, threatValue.
-- [belief] UnitCanAttack("player", "targettarget") answers on 3.3.5.

local CW = Clickwise
local Threat = CW:NewModule("Threat", "AceEvent-3.0", "AceTimer-3.0")
CW.Threat = Threat

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local pairs, ipairs, type, floor = pairs, ipairs, type, math.floor
-- unit queries come from CW.API so that Test.lua's invented units answer them (see Compat.lua)
local API = CW.API
local UnitThreatSituation, UnitDetailedThreatSituation = API.UnitThreatSituation, API.UnitDetailedThreatSituation
local UnitExists, UnitCanAttack, UnitGUID, UnitIsPlayer, UnitAffectingCombat, UnitName =
	API.UnitExists, API.UnitCanAttack, API.UnitGUID, API.UnitIsPlayer, API.UnitAffectingCombat, API.UnitName

local POLL = 0.5         -- seconds between threat percentage reads while in combat
local PULSE = 0.8        -- seconds per pulse of the red ring
local TICK = 0.02        -- pulse driver: animation step (a few frames: the pulse is 0.8 s, so 0.05 stepped visibly)
local EDGE = 2           -- ring thickness, drawn outside the frame (the default frame spacing is 2)
local BAR_HEIGHT = 2     -- the bar sits at the very bottom; the buff icons start 3 units up
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

Threat.AGGRO, Threat.WARN = "AGGRO", "WARN"
local RED, YELLOW = {0.95, 0.1, 0.1}, {1, 0.85, 0.05}

--------------------------------------------------------------------------------
-- Pure rules (asserted directly by the harness)
--------------------------------------------------------------------------------
-- The ring a unit gets: "AGGRO", "WARN" or nil. Only a unit KNOWN to be a healer or damage dealer can raise one.
function Threat.Alert(role, status, scaled, warn)
	if role ~= "HEALER" and role ~= "DAMAGER" then return nil end
	status = status or 0
	if status >= 2 then return Threat.AGGRO end
	if status == 1 or (scaled and scaled >= (warn or 80)) then return Threat.WARN end
	return nil
end

-- The bar's fill (0..100) or nil for no bar: nothing for tanks, and nothing without a percentage to show.
function Threat.BarFill(role, scaled)
	if role == "TANK" or not scaled or scaled <= 0 then return nil end
	if scaled > 100 then return 100 end
	return scaled
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
local function Settings()
	return CW.db.profile.threat
end

local function Warn()
	return CW.db.profile.combatColor.threat
end

local function Wanted()
	local s = Settings()
	return s.border or s.bar
end

--------------------------------------------------------------------------------
-- The enemy the percentage is measured against
--------------------------------------------------------------------------------
local function Hostile(unit)
	return UnitExists(unit) and UnitCanAttack("player", unit)
end

-- The unit token, or nil when there is nothing hostile to measure against.
function Threat:FindMob()
	if Hostile("target") then return "target" end
	if UnitExists("target") and Hostile("targettarget") then return "targettarget" end
	if Hostile("focus") then return "focus" end
	for btn in pairs(CW.UnitFrame.frames) do
		local unit = btn.unit
		if unit and btn.cwRole == "TANK" and unit ~= "player" and not btn.cwFakeUnit then
			local token = unit .. "target"
			if Hostile(token) then return token end
		end
	end
	return nil
end

-- Re-read the enemy (once per poll and per target change); the frames use the cached answer.
function Threat:RefreshMob()
	self.mob = self:FindMob() or false
end

-- What the bar and the tooltip measure against: nil when nothing hostile is in reach.
function Threat:GetMob()
	if self.mob == nil then self:RefreshMob() end
	return self.mob or nil
end

--------------------------------------------------------------------------------
-- Widgets (created with the unit button; see UnitFrame:InitButton)
--------------------------------------------------------------------------------
function Threat:InitButton(btn)
	if btn.cwThreatHolder then return end
	local holder = CreateFrame("Frame", nil, btn)
	holder:SetFrameLevel(btn:GetFrameLevel() + 6)
	holder:SetAllPoints(btn)

	local edges = {}
	for i = 1, 4 do
		local tex = holder:CreateTexture(nil, "OVERLAY")
		CW.SetSolidColor(tex, 1, 1, 1, 1)
		tex:Hide()
		edges[i] = tex
	end
	-- top, bottom, left, right: outside the frame
	edges[1]:SetPoint("TOPLEFT", holder, "TOPLEFT", -EDGE, EDGE)
	edges[1]:SetPoint("TOPRIGHT", holder, "TOPRIGHT", EDGE, EDGE)
	edges[1]:SetHeight(EDGE)
	edges[2]:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", -EDGE, -EDGE)
	edges[2]:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", EDGE, -EDGE)
	edges[2]:SetHeight(EDGE)
	edges[3]:SetPoint("TOPLEFT", holder, "TOPLEFT", -EDGE, EDGE)
	edges[3]:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", -EDGE, -EDGE)
	edges[3]:SetWidth(EDGE)
	edges[4]:SetPoint("TOPRIGHT", holder, "TOPRIGHT", EDGE, EDGE)
	edges[4]:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", EDGE, -EDGE)
	edges[4]:SetWidth(EDGE)

	local bar = CreateFrame("StatusBar", nil, holder)
	bar:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 1, 1)
	bar:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
	bar:SetHeight(BAR_HEIGHT)
	bar:SetStatusBarTexture(BAR_TEXTURE)
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(0)
	bar:Hide()

	btn.cwThreatHolder, btn.cwThreatEdges, btn.cwThreatBar = holder, edges, bar
end

--------------------------------------------------------------------------------
-- The red ring pulses: one driver for all frames, shown only while one is in `pulsing`
--------------------------------------------------------------------------------
local pulsing = {}

local function UpdateDriver()
	local driver = Threat.driver
	if not driver then return end
	if next(pulsing) then driver:Show() else driver:Hide() end
end

local function SetRingAlpha(btn, alpha)
	for i = 1, 4 do btn.cwThreatEdges[i]:SetAlpha(alpha) end
end

-- The brightness of the pulse right now: one phase for every ring, so they pulse together.
local function PulseAlpha()
	return CW.Buffs.FlashAlpha((GetTime() % PULSE) / PULSE)
end

function Threat:CreateDriver()
	if self.driver then return end
	local driver = CreateFrame("Frame")
	local acc = 0
	driver:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc < TICK then return end
		acc = 0
		local alpha = PulseAlpha()
		for btn in pairs(pulsing) do SetRingAlpha(btn, alpha) end
	end)
	driver:Hide()
	self.driver = driver
end

--------------------------------------------------------------------------------
-- Paint
--------------------------------------------------------------------------------
local function HideAll(btn)
	for i = 1, 4 do btn.cwThreatEdges[i]:Hide() end
	btn.cwThreatBar:Hide()
	pulsing[btn] = nil
end

-- What the frame shows for the unit right now; the numbers are kept on the button for the tooltip and /cw threat.
function Threat:UpdateButton(btn)
	if not btn.cwThreatEdges then return end
	local unit = btn.unit
	btn.cwThreatStatus, btn.cwThreatScaled, btn.cwThreatAlert = nil, nil, nil
	if not (self.inCombat and unit and Wanted() and UnitIsPlayer(unit)) then
		HideAll(btn)
		UpdateDriver()
		return
	end

	local s = Settings()
	local status = UnitThreatSituation(unit)
	local scaled
	-- (an invented unit of Test.lua answers for any enemy; a real one goes through the search above)
	local mob = btn.cwFakeUnit and "target" or self:GetMob()
	if mob then
		local _, _, pct = UnitDetailedThreatSituation(unit, mob)
		scaled = pct
	end
	local role = btn.cwRole -- cached by UnitFrame:UpdateRole, which runs before this
	local alert = Threat.Alert(role, status, scaled, Warn())
	btn.cwThreatStatus, btn.cwThreatScaled, btn.cwThreatAlert = status, scaled, alert

	local edges = btn.cwThreatEdges
	if s.border and alert then
		local c = alert == Threat.AGGRO and RED or YELLOW
		-- a repaint (every threat event, every poll) must not restart the pulse at full brightness: that is a visible skip
		local alpha = alert == Threat.AGGRO and PulseAlpha() or 1
		for i = 1, 4 do
			CW.SetSolidColor(edges[i], c[1], c[2], c[3], 1)
			edges[i]:SetAlpha(alpha)
			edges[i]:Show()
		end
		pulsing[btn] = (alert == Threat.AGGRO) or nil
	else
		for i = 1, 4 do edges[i]:Hide() end
		pulsing[btn] = nil
	end

	local fill = s.bar and Threat.BarFill(role, scaled) or nil
	if fill then
		local r, g, b = CW.CombatColor.ThreatColor(status, scaled, Warn())
		btn.cwThreatBar:SetStatusBarColor(r, g, b)
		btn.cwThreatBar:SetValue(fill)
		btn.cwThreatBar:Show()
	else
		btn.cwThreatBar:Hide()
	end
	UpdateDriver()
end

function Threat:UpdateAll()
	for btn in pairs(CW.UnitFrame.frames) do self:UpdateButton(btn) end
end

-- One line for the hover tooltip, or nil.
function Threat:TooltipLine(btn)
	local scaled = btn.cwThreatScaled
	if not scaled or btn.cwRole == "TANK" then return nil end
	local r, g, b = CW.CombatColor.ThreatColor(btn.cwThreatStatus, scaled, Warn())
	return {left = L["Threat"], right = (L["%d%% toward pulling"]):format(floor(scaled + 0.5)), r = r, g = g, b = b}
end

-- Lines for `/cw threat`: what the module sees, unit by unit.
function Threat:Describe()
	local lines = {}
	lines[#lines + 1] = ("In combat: %s. Enemy measured against: %s."):format(self.inCombat and "yes" or "no", self:GetMob() or "none found")
	local frames = {}
	for btn in pairs(CW.UnitFrame.frames) do
		local unit = btn.unit
		if unit and UnitExists(unit) then
			-- (a hidden frame is listed too, marked: a header keeps the buttons of a layout that is not on screen)
			frames[#frames + 1] = ("%s (%s): role %s, status %s, toward pulling %s, ring %s%s"):format(
				UnitName(unit) or "?", unit, btn.cwRole or "unknown", tostring((UnitThreatSituation(unit))), -- (the client returns NO value, not nil, for a unit without threat: keep it to one)
				btn.cwThreatScaled and (floor(btn.cwThreatScaled + 0.5) .. "%") or "-", btn.cwThreatAlert or "none",
				btn:IsShown() and "" or " [frame hidden]")
		end
	end
	table.sort(frames)
	for _, line in ipairs(frames) do lines[#lines + 1] = line end
	if #frames == 0 then lines[#lines + 1] = "No unit frames." end
	return lines
end

--------------------------------------------------------------------------------
-- State and events
--------------------------------------------------------------------------------
-- The poll runs only while it can matter: in combat with the border or the bar on.
function Threat:Refresh()
	if self.timer then
		self:CancelTimer(self.timer)
		self.timer = nil
	end
	self:RefreshMob()
	if self.inCombat and Wanted() then
		self.timer = self:ScheduleRepeatingTimer("Poll", POLL)
	end
	self:UpdateAll()
end

function Threat:Poll()
	self:RefreshMob()
	self:UpdateAll()
end

function Threat:OnCombatStart()
	self.inCombat = true
	self:Refresh()
end

function Threat:OnCombatEnd()
	self.inCombat = UnitAffectingCombat("player") and true or false
	self:Refresh()
end

-- a threat event names the unit whose status changed
function Threat:OnThreat(_, unit)
	if not (self.inCombat and Wanted()) then return end
	local guid = type(unit) == "string" and UnitGUID(unit)
	local set = guid and CW.UnitFrame.guidFrames[guid]
	if set then
		for btn in pairs(set) do self:UpdateButton(btn) end
	else
		self:UpdateAll()
	end
end

-- a new target may be a new enemy: the percentage is measured against it from the next look
function Threat:OnTargetChanged()
	if not (self.inCombat and Wanted()) then return end
	self:RefreshMob()
	self:UpdateAll()
end

function Threat:OnEnable()
	self:CreateDriver()
	self.inCombat = UnitAffectingCombat("player") and true or false
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
	self:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE", "OnThreat")
	self:RegisterEvent("PLAYER_TARGET_CHANGED", "OnTargetChanged")
	self:RegisterEvent("PLAYER_FOCUS_CHANGED", "OnTargetChanged")
	self:RegisterMessage("CLICKWISE_SETTINGS", "Refresh")
	self:RegisterMessage("CLICKWISE_PROFILE", "Refresh")
	self:Refresh()
end
