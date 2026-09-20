-- Unit buttons: widgets, updates and event dispatch.
--
-- Buttons are spawned by the secure group headers (see Frames.lua) and handed to
-- UnitFrame:InitButton from the header's initialConfigFunction.
--
-- Combat-safety rules followed here: only non-protected operations happen in combat
-- (SetValue, SetText, SetAlpha, colors, texcoords). Anything that resizes/re-anchors a
-- secure button, or changes attributes, goes through CW:RunOOC.
--
-- Frames are indexed by unit GUID (not unit token) so that "player" vs "raidN" aliasing,
-- pets/vehicles and LibHealComm's GUID-based callbacks all resolve to the right buttons.

local CW = Clickwise
local UnitFrame = CW:NewModule("UnitFrame", "AceEvent-3.0")
CW.UnitFrame = UnitFrame

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local LSM = LibStub("LibSharedMedia-3.0", true)
local LGT

local pairs, floor, min = pairs, math.floor, math.min
local UnitHealth, UnitHealthMax, UnitGUID, UnitName, UnitClass = UnitHealth, UnitHealthMax, UnitGUID, UnitName, UnitClass
local UnitIsDeadOrGhost, UnitIsConnected, UnitIsGhost, UnitIsPlayer, UnitIsUnit = UnitIsDeadOrGhost, UnitIsConnected, UnitIsGhost, UnitIsPlayer, UnitIsUnit
local InCombatLockdown = InCombatLockdown
local SecureButton_GetModifiedUnit = SecureButton_GetModifiedUnit

UnitFrame.frames = {} -- set of every button: [btn] = true
local guidFrames = {} -- [guid] = { [btn] = true }
UnitFrame.guidFrames = guidFrames -- read by Buffs (aura events are per GUID)

local FALLBACK_BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	tile = false, edgeSize = 1,
	insets = {left = 1, right = 1, top = 1, bottom = 1},
}
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_COORDS = {
	TANK = {0, 19 / 64, 22 / 64, 41 / 64},
	HEALER = {20 / 64, 39 / 64, 1 / 64, 20 / 64},
}

local function GetBarTexture()
	local name = CW.db.profile.frame.texture
	return (LSM and LSM:Fetch("statusbar", name, true)) or FALLBACK_BAR_TEXTURE
end

--------------------------------------------------------------------------------
-- Right-click unit menu (Blizzard's UnitPopup, driven from our own named dropdown;
-- unit dropdown frames must be named on 3.3.5).
--------------------------------------------------------------------------------
local menuUnit
local menuFrame

-- NOTE: the dropdown initializer is not reliably passed the frame on 3.3.5 (Grid2 ignores its
-- arguments too), so use the menuFrame upvalue instead of a parameter.
local function InitMenu()
	local unit = menuUnit
	if not unit or not UnitExists(unit) then return end
	local which, id
	if UnitIsUnit(unit, "player") then
		which = "SELF"
	elseif UnitIsUnit(unit, "pet") then
		which = "PET"
	elseif UnitIsPlayer(unit) then
		local raidIndex = UnitInRaid(unit) -- 0-based on 3.3.5
		if raidIndex then
			which, id = "RAID_PLAYER", raidIndex + 1
		elseif UnitInParty(unit) then
			which = "PARTY"
		else
			which = "PLAYER"
		end
	else
		which = "TARGET"
	end
	UnitPopup_ShowMenu(menuFrame, which, unit, nil, id)
end

function UnitFrame.ShowMenu(btn)
	if not menuFrame then
		menuFrame = CreateFrame("Frame", "ClickwiseUnitDropDown", UIParent, "UIDropDownMenuTemplate")
		UIDropDownMenu_Initialize(menuFrame, InitMenu, "MENU")
	end
	menuUnit = btn.unit
	ToggleDropDownMenu(1, nil, menuFrame, "cursor")
end

--------------------------------------------------------------------------------
-- Hover tooltip: Blizzard's unit tooltip first (its anchor, name, level and class), then in DETAILED mode
-- the unit's health / role / range, the buff status (Buffs:TooltipLines) and what each click does with the
-- modifier keys held right now (ClickCast:TooltipLines). Rebuilt when the mouse enters and when a modifier
-- key changes; there is no other live refresh (the buttons have no OnUpdate).
--------------------------------------------------------------------------------
local hovered -- the button the mouse is over
local ROLE_TEXT = {TANK = L["Tank"], HEALER = L["Healer"], DAMAGER = L["Damage"]}

-- Lines are {left, right, r, g, b}; a line without `right` is one piece of text in that color.
function UnitFrame:TooltipLines(btn)
	local out = {}
	local t = CW.db.profile.tooltip
	local unit = btn.unit
	if t.mode ~= "DETAILED" or not unit then return out end

	local function section(title, lines)
		out[#out + 1] = {left = " "}
		out[#out + 1] = {left = title, r = 1, g = 0.82, b = 0}
		for _, line in ipairs(lines) do out[#out + 1] = line end
	end

	local cur, max = UnitHealth(unit) or 0, UnitHealthMax(unit) or 0
	if max > 0 and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
		out[#out + 1] = {left = L["Health"], right = ("%s / %s (%d%%)"):format(CW.FormatNumber(cur), CW.FormatNumber(max),
			floor(cur / max * 100 + 0.5)), r = 1, g = 1, b = 1}
	end
	if btn.cwRole and ROLE_TEXT[btn.cwRole] then
		out[#out + 1] = {left = L["Role"], right = ROLE_TEXT[btn.cwRole], r = 1, g = 1, b = 1}
	end
	if btn.cwInRange == false then
		out[#out + 1] = {left = L["Range"], right = L["Out of range"], r = 1, g = 0.3, b = 0.3}
	end

	if t.buffs then
		local lines = CW.Buffs:TooltipLines(btn)
		if #lines > 0 then section(L["Buffs"], lines) end
	end
	if t.bindings then
		local modifier = CW.MakeModifier(IsAltKeyDown(), IsControlKeyDown(), IsShiftKeyDown())
		local lines, more = CW.ClickCast:TooltipLines(btn, modifier)
		if #lines > 0 then
			local title = L["Click bindings"]
			local held = CW.ClickCast.ModifierText(modifier)
			if held ~= "" then title = title .. " (" .. held .. ")" end
			if more and modifier == "" then
				lines[#lines + 1] = {left = L["Hold Alt, Ctrl or Shift for more."], r = 0.6, g = 0.6, b = 0.6}
			end
			section(title, lines)
		end
	end
	return out
end

function UnitFrame:ShowTooltip(btn)
	hovered = btn
	if CW.db.profile.tooltip.mode == "OFF" or not (btn.unit and UnitExists(btn.unit)) then return end
	UnitFrame_OnEnter(btn) -- Blizzard's: anchor and the standard unit tooltip
	if GameTooltip:GetOwner() ~= btn then return end -- it declined (e.g. while targeting a spell)
	local lines = self:TooltipLines(btn) -- (an error here still leaves the standard tooltip up)
	for _, line in ipairs(lines) do
		if line.right then
			GameTooltip:AddDoubleLine(line.left, line.right, 1, 0.82, 0, line.r or 1, line.g or 1, line.b or 1)
		else
			GameTooltip:AddLine(line.left, line.r or 1, line.g or 1, line.b or 1)
		end
	end
	if #lines > 0 then GameTooltip:Show() end -- shown again so the frame grows to fit the added lines
end

function UnitFrame:HideTooltip(btn)
	if hovered == btn then hovered = nil end
	UnitFrame_OnLeave(btn)
end

-- A frame hidden under the mouse (its unit left the group) gets no OnLeave: take its tooltip down.
function UnitFrame:OnButtonHide(btn)
	if hovered == btn then
		hovered = nil
		if GameTooltip:GetOwner() == btn then GameTooltip:Hide() end
	end
end

-- A modifier key went down / up: the tooltip lists the bindings of the keys held, so rebuild it.
function UnitFrame:OnModifier()
	local btn = hovered
	if btn and btn:IsShown() and GameTooltip:GetOwner() == btn then
		self:ShowTooltip(btn)
	end
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------
local function CreateBar(btn, levelOffset)
	local bar = CreateFrame("StatusBar", nil, btn)
	bar:SetFrameLevel(btn:GetFrameLevel() + levelOffset)
	bar:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
	bar:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
	bar:SetStatusBarTexture(FALLBACK_BAR_TEXTURE)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	return bar
end

function UnitFrame:InitButton(btn)
	if btn.cwInit then return end
	btn.cwInit = true
	self.frames[btn] = true

	btn:SetBackdrop(BACKDROP)
	btn:SetBackdropColor(0, 0, 0, 0.6)
	btn:SetBackdropBorderColor(0, 0, 0, 1)

	-- Incoming-heal bar sits BEHIND the health bar and is filled to (current + incoming);
	-- only the part past the health fill is visible, so no per-update resizing is needed.
	btn.heal = CreateBar(btn, 1)
	btn.health = CreateBar(btn, 2)

	local textFrame = CreateFrame("Frame", nil, btn)
	textFrame:SetFrameLevel(btn:GetFrameLevel() + 3)
	textFrame:SetAllPoints(btn)
	btn.nameText = textFrame:CreateFontString(nil, "OVERLAY")
	btn.nameText:SetPoint("TOP", textFrame, "TOP", 0, -4)
	-- bottom-right so the buff icons (Buffs.lua) can use the bottom-left corner
	btn.statusText = textFrame:CreateFontString(nil, "OVERLAY")
	btn.statusText:SetPoint("BOTTOMRIGHT", textFrame, "BOTTOMRIGHT", -3, 4)
	btn.roleIcon = textFrame:CreateTexture(nil, "OVERLAY")
	btn.roleIcon:SetTexture(ROLE_TEXTURE)
	btn.roleIcon:SetSize(12, 12)
	btn.roleIcon:SetPoint("TOPLEFT", textFrame, "TOPLEFT", 2, -2)
	btn.roleIcon:Hide()

	CW.Buffs:InitButton(btn)

	btn.menu = UnitFrame.ShowMenu
	btn:SetScript("OnEnter", function(self) UnitFrame:ShowTooltip(self) end)
	btn:SetScript("OnLeave", function(self) UnitFrame:HideTooltip(self) end)
	btn:SetScript("OnShow", function(self) UnitFrame:UpdateUnit(self) end)
	btn:SetScript("OnHide", function(self) UnitFrame:OnButtonHide(self) end)
	btn:SetScript("OnAttributeChanged", function(self, name)
		if name == "unit" then
			UnitFrame:UpdateUnit(self)
		end
	end)

	-- Hide the button automatically when its unit stops existing (secure, works in combat).
	RegisterUnitWatch(btn)

	self:LayoutButton(btn)

	-- User bindings: set now if we can, otherwise as soon as combat ends.
	local ClickCast = CW:GetModule("ClickCast")
	if InCombatLockdown() then
		CW:RunOOC("clickcast.apply", ClickCast.ApplyAll, ClickCast)
	else
		ClickCast:ApplyToButton(btn)
	end

	self:UpdateUnit(btn)
end

-- Sizes, textures, fonts and colors from the profile.
function UnitFrame:LayoutButton(btn)
	local db = CW.db.profile
	local f = db.frame

	if not InCombatLockdown() then
		btn:SetAttribute("initial-width", f.width)
		btn:SetAttribute("initial-height", f.height)
		btn:SetSize(f.width, f.height)
	end

	local texture = GetBarTexture()
	btn.health:SetStatusBarTexture(texture)
	btn.heal:SetStatusBarTexture(texture)
	local c = db.healPred.color
	btn.heal:SetStatusBarColor(c.r, c.g, c.b, c.a)

	btn.nameText:SetFont(STANDARD_TEXT_FONT, f.fontSize, "OUTLINE")
	btn.statusText:SetFont(STANDARD_TEXT_FONT, f.fontSize - 1, "OUTLINE")
	btn.cwMaxNameChars = floor((f.width - 4) / (f.fontSize * 0.55))
	CW.Buffs:LayoutButton(btn)
end

--------------------------------------------------------------------------------
-- Updates
--------------------------------------------------------------------------------
-- Resolve the button's current unit (vehicle-aware) and re-index it by GUID.
function UnitFrame:UpdateUnit(btn)
	local unit = SecureButton_GetModifiedUnit(btn)
	btn.unit = unit

	local guid = unit and UnitGUID(unit) or nil
	if guid ~= btn.guid then
		local old = btn.guid and guidFrames[btn.guid]
		if old then
			old[btn] = nil
			if not next(old) then
				guidFrames[btn.guid] = nil
			end
		end
		btn.guid = guid
		if guid then
			local set = guidFrames[guid]
			if not set then
				set = {}
				guidFrames[guid] = set
			end
			set[btn] = true
		end
	end

	if unit then
		self:UpdateButton(btn)
	end
end

function UnitFrame:UpdateButton(btn)
	if not btn.unit then return end
	self:UpdateName(btn)
	self:UpdateRole(btn) -- before health: the bar color reads the cached role
	self:UpdateHealth(btn)
	self:UpdateTarget(btn)
	CW.Range:UpdateButton(btn)
	CW.Buffs:UpdateButton(btn)
end

function UnitFrame:UpdateName(btn)
	local unit = btn.unit
	if not unit then return end
	btn.nameText:SetText(CW.TruncateUTF8(UnitName(unit) or "", btn.cwMaxNameChars or 10))
	-- Deliberate: with class-colored bars the name goes white for contrast; with plain
	-- health-gradient bars the name carries the class color instead.
	if CW.db.profile.frame.classColor or not UnitIsPlayer(unit) then
		btn.nameText:SetTextColor(1, 1, 1)
	else
		local _, class = UnitClass(unit)
		btn.nameText:SetTextColor(CW.GetClassColor(class))
	end
end

function UnitFrame:UpdateHealth(btn)
	local unit = btn.unit
	if not unit then return end

	local f = CW.db.profile.frame
	local cur, max = UnitHealth(unit), UnitHealthMax(unit)
	if not max or max < 1 then max = 1 end
	cur = cur or 0

	local offline = not UnitIsConnected(unit)
	local dead = UnitIsDeadOrGhost(unit)
	if btn.cwOffline ~= offline or btn.cwDead ~= dead then
		btn.cwOffline, btn.cwDead = offline, dead
		CW.Buffs:Paint(btn) -- missing-buff icons grey out for dead / offline units
	end

	btn.health:SetMinMaxValues(0, max)
	btn.health:SetValue(cur)

	-- bar color
	local r, g, b
	local cr, cg, cb
	local combatColor = CW.CombatColor -- nil if this file list is stale (a new .lua file needs a full client restart)
	if combatColor and not (offline or dead) then cr, cg, cb = combatColor:GetColor(btn, cur, max) end
	if offline then
		r, g, b = 0.4, 0.4, 0.4
	elseif dead then
		r, g, b = 0.25, 0.25, 0.25
	elseif cr then
		r, g, b = cr, cg, cb -- in combat: the role's warning colors (CombatColor.lua)
	elseif f.classColor then
		if UnitIsPlayer(unit) then
			local _, class = UnitClass(unit)
			r, g, b = CW.GetClassColor(class)
		else
			r, g, b = 0.1, 0.75, 0.25 -- pets / vehicles
		end
	else
		local pct = cur / max
		r, g, b = (pct < 0.5) and 1 or (1 - pct) * 2, (pct > 0.5) and 1 or pct * 2, 0
	end
	btn.health:SetStatusBarColor(r, g, b)

	-- incoming heals
	local incoming = 0
	if not (offline or dead) and cur < max then
		incoming = CW.HealPred:GetIncoming(btn.guid)
	end
	if incoming > 0 then
		btn.heal:SetMinMaxValues(0, max)
		btn.heal:SetValue(min(cur + incoming, max))
	else
		btn.heal:SetValue(0)
	end

	-- status / health text
	local text = ""
	if offline then
		text = "Offline"
	elseif UnitIsGhost(unit) then
		text = "Ghost"
	elseif dead then
		text = "Dead"
	elseif cur < max then
		if f.healthText == "DEFICIT" then
			text = "-" .. CW.FormatNumber(max - cur)
		elseif f.healthText == "PERCENT" then
			text = floor(cur / max * 100 + 0.5) .. "%"
		end
	end
	btn.statusText:SetText(text)
end

function UnitFrame:UpdateRole(btn)
	-- cached on the button: CombatColor reads it on every bar paint (resolving a role can consult LibGroupTalents)
	btn.cwRole = btn.unit and CW.GetUnitRole(btn.unit) or nil
	local coords
	if btn.cwRole and CW.db.profile.frame.showRoleIcon then
		coords = ROLE_COORDS[btn.cwRole]
	end
	if coords then
		btn.roleIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
		btn.roleIcon:Show()
	else
		btn.roleIcon:Hide()
	end
end

function UnitFrame:UpdateTarget(btn)
	if btn.unit and UnitIsUnit(btn.unit, "target") then
		btn:SetBackdropBorderColor(1, 1, 1, 1)
	else
		btn:SetBackdropBorderColor(0, 0, 0, 1)
	end
end

function UnitFrame:UpdateGUID(guid)
	local set = guid and guidFrames[guid]
	if set then
		for btn in pairs(set) do
			self:UpdateHealth(btn)
		end
	end
end

function UnitFrame:UpdateAllHealth()
	for btn in pairs(self.frames) do
		self:UpdateHealth(btn)
	end
end

function UnitFrame:RefreshAllUnits()
	for btn in pairs(self.frames) do
		self:UpdateUnit(btn)
	end
end

function UnitFrame:UpdateAllTargets()
	for btn in pairs(self.frames) do
		self:UpdateTarget(btn)
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
function UnitFrame:OnUnitHealth(_, unit)
	if type(unit) == "string" then
		self:UpdateGUID(UnitGUID(unit))
	else
		-- e.g. PARTY_MEMBER_ENABLE/DISABLE without a usable unit token: refresh everything
		self:UpdateAllHealth()
	end
end

function UnitFrame:OnUnitName(_, unit)
	local guid = type(unit) == "string" and UnitGUID(unit)
	local set = guid and guidFrames[guid]
	if set then
		for btn in pairs(set) do
			self:UpdateName(btn)
		end
	end
end

function UnitFrame:ApplySettings()
	CW:RunOOC("unitframe.layout", function()
		for btn in pairs(UnitFrame.frames) do
			UnitFrame:LayoutButton(btn)
		end
		UnitFrame:RefreshAllUnits()
	end)
end

function UnitFrame:OnEnable()
	self:RegisterEvent("UNIT_HEALTH", "OnUnitHealth")
	self:RegisterEvent("UNIT_MAXHEALTH", "OnUnitHealth")
	self:RegisterEvent("UNIT_NAME_UPDATE", "OnUnitName")
	self:RegisterEvent("PARTY_MEMBER_ENABLE", "OnUnitHealth")  -- online again
	self:RegisterEvent("PARTY_MEMBER_DISABLE", "OnUnitHealth") -- went offline
	self:RegisterEvent("PLAYER_TARGET_CHANGED", "UpdateAllTargets")
	self:RegisterEvent("MODIFIER_STATE_CHANGED", "OnModifier") -- [belief] the 3.3.5 name; if wrong the tooltip just stays static
	self:RegisterEvent("UNIT_ENTERED_VEHICLE", "RefreshAllUnits")
	self:RegisterEvent("UNIT_EXITED_VEHICLE", "RefreshAllUnits")
	self:RegisterEvent("UNIT_PET", "RefreshAllUnits")
	self:RegisterEvent("PLAYER_ROLES_ASSIGNED", "RefreshAllUnits")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "RefreshAllUnits")
	self:RegisterMessage("CLICKWISE_ROSTER", "RefreshAllUnits")
	self:RegisterMessage("CLICKWISE_SETTINGS", "ApplySettings")

	LGT = LGT or LibStub("LibGroupTalents-1.0", true)
	if LGT and LGT.RegisterCallback then
		LGT.RegisterCallback(self, "LibGroupTalents_RoleChange", "RefreshAllUnits")
	end
end

function UnitFrame:OnDisable()
	if LGT and LGT.UnregisterCallback then
		LGT.UnregisterCallback(self, "LibGroupTalents_RoleChange")
	end
end
