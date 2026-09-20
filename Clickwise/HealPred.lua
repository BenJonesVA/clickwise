-- Incoming-heal prediction via LibHealComm-4.0 (minor 66, the 3.3.5-era copy).
-- This module only supplies numbers and triggers frame refreshes; UnitFrame.lua draws
-- the overlay. Callback layout (from Grid2-WoTLK's StatusHealth.lua):
--   HealStarted/Updated/Delayed/Stopped(event, casterGUID, spellID, spellType, endTime|interrupted, targetGUID...)
--   ModifierChanged(event, guid, modifier)

local CW = Clickwise
local HealPred = CW:NewModule("HealPred", "AceEvent-3.0")
CW.HealPred = HealPred

local HealComm = LibStub("LibHealComm-4.0", true)
local GetTime = GetTime
local select = select

local enabled, includeOwn, timeFrame = true, true, 4

HealPred.available = HealComm and true or false

-- Effective incoming heal (after healing-taken modifiers) for a unit GUID.
function HealPred:GetIncoming(guid)
	local fake = guid and CW.fakeGuid[guid] -- an invented unit (Test.lua) carries its own incoming heal
	if fake then return enabled and fake.incoming or 0 end
	if not (HealComm and enabled and guid) then
		return 0
	end
	local untilTime = timeFrame > 0 and (GetTime() + timeFrame) or nil
	local amount
	if includeOwn then
		amount = HealComm:GetHealAmount(guid, HealComm.ALL_HEALS, untilTime)
	else
		amount = HealComm:GetOthersHealAmount(guid, HealComm.ALL_HEALS, untilTime)
	end
	if not amount or amount <= 0 then
		return 0
	end
	return amount * (HealComm:GetHealModifier(guid) or 1)
end

function HealPred:OnHealEvent(_, _, _, _, _, ...)
	local UnitFrame = CW:GetModule("UnitFrame")
	for i = 1, select("#", ...) do
		UnitFrame:UpdateGUID((select(i, ...)))
	end
end

function HealPred:OnModifierChanged(_, guid)
	CW:GetModule("UnitFrame"):UpdateGUID(guid)
end

function HealPred:ApplySettings()
	local db = CW.db.profile.healPred
	enabled, includeOwn, timeFrame = db.enabled, db.includeOwn, db.timeFrame
	CW:GetModule("UnitFrame"):UpdateAllHealth()
end

function HealPred:OnEnable()
	self:RegisterMessage("CLICKWISE_SETTINGS", "ApplySettings")
	self:ApplySettings()
	if not HealComm then return end
	HealComm.RegisterCallback(self, "HealComm_HealStarted", "OnHealEvent")
	HealComm.RegisterCallback(self, "HealComm_HealUpdated", "OnHealEvent")
	HealComm.RegisterCallback(self, "HealComm_HealDelayed", "OnHealEvent")
	HealComm.RegisterCallback(self, "HealComm_HealStopped", "OnHealEvent")
	HealComm.RegisterCallback(self, "HealComm_ModifierChanged", "OnModifierChanged")
end

function HealPred:OnDisable()
	if not HealComm then return end
	HealComm.UnregisterCallback(self, "HealComm_HealStarted")
	HealComm.UnregisterCallback(self, "HealComm_HealUpdated")
	HealComm.UnregisterCallback(self, "HealComm_HealDelayed")
	HealComm.UnregisterCallback(self, "HealComm_HealStopped")
	HealComm.UnregisterCallback(self, "HealComm_ModifierChanged")
end
