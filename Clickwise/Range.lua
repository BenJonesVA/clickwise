-- Range fading. LibRangeCheck is not used; instead (in order of reliability):
--   1. IsSpellInRange() with a friendly spell the player knows (class list below)
--   2. UnitInRange() (group members / pets)
--   3. CheckInteractDistance(unit, 4) (~28yd), then UnitIsVisible() as a last resort
-- Dead units use the class resurrection spell so the fade reflects "can I rez them".
-- Frames are faded with SetAlpha, which is legal in combat.

local CW = Clickwise
local Range = CW:NewModule("Range", "AceEvent-3.0")
CW.Range = Range

local pairs = pairs
local UnitIsUnit, UnitIsConnected, UnitIsDeadOrGhost = UnitIsUnit, UnitIsConnected, UnitIsDeadOrGhost
local UnitInRange, UnitIsVisible = UnitInRange, UnitIsVisible
local IsSpellInRange, CheckInteractDistance = IsSpellInRange, CheckInteractDistance
local GetSpellInfo = GetSpellInfo

-- spell IDs are used (locale-safe); the localized name is resolved at runtime.
local RANGE_SPELLS = {
	PRIEST = {2061},         -- Flash Heal (40yd)
	DRUID = {5185},          -- Healing Touch (40yd)
	PALADIN = {635},         -- Holy Light (40yd)
	SHAMAN = {331},          -- Healing Wave (40yd)
	MAGE = {1459},           -- Arcane Intellect (30yd)
	WARLOCK = {5697},        -- Unending Breath (30yd)
	WARRIOR = {3411},        -- Intervene (25yd)
	ROGUE = {57934},         -- Tricks of the Trade (20yd)
}
local REZ_SPELLS = {
	PRIEST = 2006,           -- Resurrection
	PALADIN = 7328,          -- Redemption
	DRUID = 50769,           -- Revive
	SHAMAN = 2008,           -- Ancestral Spirit
	DEATHKNIGHT = 61999,     -- Raise Ally
}

local rangeSpell, rezSpell
local enabled, fadedAlpha, interval = true, 0.4, 0.4
local elapsed = 0

function Range:RebuildSpells()
	local _, class = UnitClass("player")
	rangeSpell, rezSpell = nil, nil

	local list = RANGE_SPELLS[class]
	if list then
		for i = 1, #list do
			local name = GetSpellInfo(list[i])
			if name and CW.KnowsSpell(name) then
				rangeSpell = name
				break
			end
		end
	end

	local rezId = REZ_SPELLS[class]
	if rezId then
		local name = GetSpellInfo(rezId)
		if name and CW.KnowsSpell(name) then
			rezSpell = name
		end
	end
end

-- true = in range (full alpha), false = out of range (faded)
local function CheckUnit(unit)
	if UnitIsUnit(unit, "player") then
		return true
	end
	if not UnitIsConnected(unit) then
		return false
	end
	if rezSpell and UnitIsDeadOrGhost(unit) then
		local r = IsSpellInRange(rezSpell, unit)
		if r ~= nil then
			return r == 1
		end
	end
	if rangeSpell then
		local r = IsSpellInRange(rangeSpell, unit)
		if r ~= nil then
			return r == 1
		end
	end
	if UnitInRange then
		local r = UnitInRange(unit)
		if r ~= nil then
			return r and true or false
		end
	end
	if CheckInteractDistance(unit, 4) then
		return true
	end
	return UnitIsVisible(unit) and true or false
end
Range.CheckUnit = CheckUnit

function Range:UpdateButton(btn)
	local unit = btn.unit
	if not unit then return end
	local inRange = true
	if enabled then
		inRange = CheckUnit(unit)
	end
	if btn.cwInRange ~= inRange then
		btn.cwInRange = inRange
		btn:SetAlpha(inRange and 1 or fadedAlpha)
		CW.Buffs:Paint(btn) -- missing-buff icons grey out when the unit is out of range
	end
end

function Range:OnUpdate(dt)
	elapsed = elapsed + dt
	if elapsed < interval then return end
	elapsed = 0
	if not enabled then return end
	local frames = CW:GetModule("UnitFrame").frames
	for btn in pairs(frames) do
		if btn:IsShown() then
			self:UpdateButton(btn)
		end
	end
end

function Range:ApplySettings()
	local db = CW.db.profile.range
	enabled, fadedAlpha, interval = db.enabled, db.alpha, db.interval
	local frames = CW:GetModule("UnitFrame").frames
	for btn in pairs(frames) do
		btn.cwInRange = nil -- force re-apply with the new alpha / enabled state
		self:UpdateButton(btn)
	end
end

function Range:OnEnable()
	self.driver = self.driver or CreateFrame("Frame")
	self.driver:SetScript("OnUpdate", function(_, dt) Range:OnUpdate(dt) end)
	self:RegisterMessage("CLICKWISE_SETTINGS", "ApplySettings")
	self:RegisterMessage("CLICKWISE_SPELLS_CHANGED", "RebuildSpells")
	self:RebuildSpells()
	self:ApplySettings()
end

function Range:OnDisable()
	if self.driver then
		self.driver:SetScript("OnUpdate", nil)
	end
end
