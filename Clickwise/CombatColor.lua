-- Combat colors: while the player is in combat the health bars change color to show what matters
-- for the player's role.
--
--   HEALTH  (healers, and anything that is not a tank)
--           green above the yellow threshold, yellow at or below it, red below the red threshold.
--   THREAT  (tanks)
--           green while the unit has no threat problem, yellow while it is about to take the enemy off
--           the tank (it out-threatens the tank, or its threat is past the warning percentage of what it
--           needs to pull), red once it has the enemy's attention. Tanks and pets stay green.
--
-- The mode is "AUTO" by default: the player's own role decides (tank = THREAT, everything else = HEALTH).
-- All thresholds are profile settings (profile.combatColor).
--
-- Display only: nothing here touches a secure attribute, so it works in combat like the rest of the
-- bar updates. UnitFrame:UpdateHealth asks GetColor() for an override when it paints a bar.
--
-- 3.3.5 facts used: UnitThreatSituation(unit) returns nil / 0 (no threat) / 1 (more threat than the
-- tank but not tanking) / 2 (tanking without the most threat) / 3 (securely tanking).
-- UnitDetailedThreatSituation(unit, mob) also returns the scaled percentage: how far the unit is
-- toward pulling (100 = pulls). Threat has no per-second event, so the threat mode repaints on a
-- timer while the player is in combat.

local CW = Clickwise
local CombatColor = CW:NewModule("CombatColor", "AceEvent-3.0", "AceTimer-3.0")
CW.CombatColor = CombatColor

-- unit queries come from CW.API so that Test.lua's invented units answer them (see Compat.lua)
local API = CW.API
local UnitHealth, UnitHealthMax, UnitIsPlayer, UnitAffectingCombat = API.UnitHealth, API.UnitHealthMax, API.UnitIsPlayer, API.UnitAffectingCombat
local UnitThreatSituation, UnitDetailedThreatSituation = API.UnitThreatSituation, API.UnitDetailedThreatSituation
local UnitExists, UnitCanAttack, UnitGUID = API.UnitExists, API.UnitCanAttack, API.UnitGUID

local POLL = 0.5

CombatColor.GREEN = {0.1, 0.8, 0.2}
CombatColor.YELLOW = {1, 0.85, 0.05}
CombatColor.RED = {0.9, 0.1, 0.1}
local GREEN, YELLOW, RED = CombatColor.GREEN, CombatColor.YELLOW, CombatColor.RED

CombatColor.MODES = {"AUTO", "HEALTH", "THREAT", "OFF"}

--------------------------------------------------------------------------------
-- Pure color rules (tested on their own)
--------------------------------------------------------------------------------
-- pct = 0..100. Yellow at or below `yellow`, red below `red`; a red limit above the yellow one is
-- treated as equal to it so the bands never invert.
function CombatColor.HealthColor(pct, yellow, red)
	yellow, red = yellow or 50, red or 20
	if red > yellow then red = yellow end
	local c = GREEN
	if pct < red then
		c = RED
	elseif pct <= yellow then
		c = YELLOW
	end
	return c[1], c[2], c[3]
end

-- status = UnitThreatSituation (nil / 0..3); scaled = the "toward pulling" percentage or nil.
function CombatColor.ThreatColor(status, scaled, warn)
	status = status or 0
	local c = GREEN
	if status >= 2 then
		c = RED
	elseif status == 1 or (scaled and scaled >= (warn or 80)) then
		c = YELLOW
	end
	return c[1], c[2], c[3]
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
local function Settings()
	return CW.db.profile.combatColor
end

-- "HEALTH", "THREAT" or nil (off) after resolving AUTO from the player's role.
function CombatColor:Mode()
	local mode = Settings().mode
	if mode == "OFF" then return nil end
	if mode == "HEALTH" or mode == "THREAT" then return mode end
	return self.myRole == "TANK" and "THREAT" or "HEALTH"
end

--------------------------------------------------------------------------------
-- Color for one button, or nil when the normal bar color applies (out of combat, off, no unit)
--------------------------------------------------------------------------------
function CombatColor:GetColor(btn, cur, max)
	if not self.inCombat then return nil end
	local unit = btn.unit
	if not unit then return nil end
	local mode = self:Mode()
	if not mode then return nil end
	local s = Settings()

	if mode == "HEALTH" then
		cur = cur or UnitHealth(unit) or 0
		max = max or UnitHealthMax(unit) or 0
		if not max or max < 1 then return nil end
		return CombatColor.HealthColor(cur / max * 100, s.yellow, s.red)
	end

	-- THREAT: tanks and pets are meant to hold the enemy, so they stay green
	if not UnitIsPlayer(unit) or btn.cwRole == "TANK" then -- cwRole: cached by UnitFrame:UpdateRole
		return GREEN[1], GREEN[2], GREEN[3]
	end
	local status = UnitThreatSituation(unit)
	local scaled
	if UnitExists("target") and UnitCanAttack("player", "target") then
		local _, _, pct = UnitDetailedThreatSituation(unit, "target")
		scaled = pct
	end
	return CombatColor.ThreatColor(status, scaled, s.threat)
end

--------------------------------------------------------------------------------
-- State and events
--------------------------------------------------------------------------------
function CombatColor:UpdateRole()
	self.myRole = CW.GetUnitRole("player")
end

-- Repaint every bar; run the poll only while it can matter (threat mode, in combat).
function CombatColor:Refresh()
	if self.timer then
		self:CancelTimer(self.timer)
		self.timer = nil
	end
	if self.inCombat and self:Mode() == "THREAT" then
		self.timer = self:ScheduleRepeatingTimer("Poll", POLL)
	end
	CW.UnitFrame:UpdateAllHealth()
end

function CombatColor:Poll()
	CW.UnitFrame:UpdateAllHealth()
end

function CombatColor:OnCombatStart()
	self.inCombat = true
	self:UpdateRole()
	self:Refresh()
end

function CombatColor:OnCombatEnd()
	self.inCombat = false
	self:Refresh()
end

function CombatColor:OnRoleChanged()
	self:UpdateRole()
	if self.inCombat then self:Refresh() end
end

-- a threat event names the unit whose situation changed; repaint just that unit's frames
function CombatColor:OnThreat(_, unit)
	if not (self.inCombat and self:Mode() == "THREAT") then return end
	local guid = type(unit) == "string" and UnitGUID(unit)
	if guid then
		CW.UnitFrame:UpdateGUID(guid)
	else
		CW.UnitFrame:UpdateAllHealth()
	end
end

function CombatColor:OnEnable()
	self.inCombat = UnitAffectingCombat("player") and true or false
	self:UpdateRole()
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
	self:RegisterEvent("PLAYER_ROLES_ASSIGNED", "OnRoleChanged")
	self:RegisterEvent("PLAYER_TALENT_UPDATE", "OnRoleChanged")
	self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "OnRoleChanged")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnRoleChanged")
	self:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE", "OnThreat")
	self:RegisterMessage("CLICKWISE_SETTINGS", "Refresh")
	self:RegisterMessage("CLICKWISE_PROFILE", "Refresh")

	local LGT = LibStub("LibGroupTalents-1.0", true)
	if LGT and LGT.RegisterCallback then
		LGT.RegisterCallback(self, "LibGroupTalents_RoleChange", "OnRoleChanged")
	end
	self:Refresh()
end
