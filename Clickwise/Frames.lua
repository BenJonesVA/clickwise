-- Container + secure group headers + layout.
--
-- Unit assignment is done by Blizzard's SecureGroupHeader templates (which keep working in
-- combat). Everything WE do to headers (attributes, show/hide, anchors, container moves)
-- goes through CW:RunOOC. Attribute sets follow Grid2-WoTLK's GridLayoutLayouts.lua, which is
-- known to work on 3.3.5, including its "force child creation" trick that pre-creates every
-- child button out of combat (Blizzard cannot initialise new unit buttons in combat).
--
-- Layout:
--   solo / party : [party header (5)] [party pet header (5)]
--   raid         : [group 1] [group 2] ... [group 8]      (or stacked when "horizontal")

local CW = Clickwise
local Frames = CW:NewModule("Frames", "AceEvent-3.0", "AceTimer-3.0")
CW.Frames = Frames

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local ipairs, select, type = ipairs, select, type
local InCombatLockdown = InCombatLockdown

local HEADER_TEMPLATE = {
	party = "SecurePartyHeaderTemplate",
	partypet = "SecurePartyPetHeaderTemplate",
	raid = "SecureRaidGroupHeaderTemplate",
}
local NUM_RAID_GROUPS = 8
local UNITS_PER_HEADER = 5

--------------------------------------------------------------------------------
-- Called by the header for every newly created child button
--------------------------------------------------------------------------------
local function InitialConfig(...)
	-- Blizzard passes the new child button (plus its name); be tolerant about argument order.
	local btn
	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		if type(arg) == "table" and arg.GetObjectType and arg:GetObjectType() == "Button" then
			btn = arg
			break
		end
	end
	if not btn then return end
	btn:SetAttribute("useparent-toggleForVehicle", true)
	btn:SetAttribute("useparent-allowVehicleTarget", true)
	btn:SetAttribute("useparent-unitsuffix", true)
	CW.UnitFrame:InitButton(btn)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
function Frames:CreateContainer()
	local c = CreateFrame("Frame", "ClickwiseContainer", UIParent)
	c:SetSize(120, 40)
	c:SetMovable(true)
	c:SetClampedToScreen(true)
	self.container = c

	local tab = CreateFrame("Frame", "ClickwiseMoverTab", c)
	tab:SetSize(110, 14)
	tab:SetPoint("BOTTOMLEFT", c, "TOPLEFT", 0, 2)
	tab:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
		insets = {left = 1, right = 1, top = 1, bottom = 1},
	})
	tab:SetBackdropColor(0.1, 0.3, 0.6, 0.85)
	tab:SetBackdropBorderColor(0, 0, 0, 1)
	tab:EnableMouse(true)
	tab:RegisterForDrag("LeftButton")
	local label = tab:CreateFontString(nil, "OVERLAY")
	label:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
	label:SetPoint("CENTER")
	label:SetText("Clickwise (drag)")
	tab:SetScript("OnDragStart", function()
		if InCombatLockdown() then
			CW:Print(L["Cannot move frames in combat."])
			return
		end
		c:StartMoving()
	end)
	tab:SetScript("OnDragStop", function()
		c:StopMovingOrSizing()
		Frames:SavePosition()
	end)
	tab:Hide()
	self.tab = tab
end

local function NewHeader(name, kind, parent)
	local h = CreateFrame("Frame", name, parent, HEADER_TEMPLATE[kind])
	h:Hide() -- keep it inert until template/initialConfigFunction are in place
	h:SetAttribute("template", "ClickwiseUnitButtonTemplate")
	h.initialConfigFunction = InitialConfig
	h.cwKind = kind
	return h
end

function Frames:CreateHeaders()
	local c = self.container
	self.party = NewHeader("ClickwisePartyHeader", "party", c)
	self.partyPets = NewHeader("ClickwisePartyPetHeader", "partypet", c)
	self.raid = {}
	for i = 1, NUM_RAID_GROUPS do
		local h = NewHeader("ClickwiseRaidHeader" .. i, "raid", c)
		h:SetAttribute("groupFilter", tostring(i))
		self.raid[i] = h
	end
end

--------------------------------------------------------------------------------
-- Position / lock
--------------------------------------------------------------------------------
function Frames:SavePosition()
	local c = self.container
	local left, top = c:GetLeft(), c:GetTop()
	if left and top then
		local e = c:GetEffectiveScale()
		local p = CW.db.profile.position
		p.x, p.y = left * e, top * e
	end
end

function Frames:RestorePosition()
	local c = self.container
	local p = CW.db.profile.position
	c:ClearAllPoints()
	if p.x and p.y then
		local e = c:GetEffectiveScale()
		c:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x / e, p.y / e)
	else
		c:SetPoint("CENTER", UIParent, "CENTER", -300, 0)
	end
end

function Frames:ResetPosition()
	CW:RunOOC("frames.reset", function()
		local p = CW.db.profile.position
		p.x, p.y = nil, nil
		Frames:RestorePosition()
	end)
end

function Frames:SetLocked(locked)
	CW.db.profile.locked = locked and true or false
	if self.tab then
		if locked then self.tab:Hide() else self.tab:Show() end
	end
	CW:Print(locked and L["Frames are locked."] or L["Frames are unlocked. Drag the Clickwise tab to move them."])
end

--------------------------------------------------------------------------------
-- Layout (out of combat only)
--------------------------------------------------------------------------------
local function ClearChildPoints(header)
	local i = 1
	local child = header:GetAttribute("child1")
	while child do
		child:ClearAllPoints()
		i = i + 1
		child = header:GetAttribute("child" .. i)
	end
end

-- Blizzard bug: unit buttons cannot be initialised in combat, so create them all now.
-- (Grid2 GridLayout.lua ForceFramesCreation)
local function ForceFramesCreation(header)
	if header.cwFramesForced then return end
	header:Show()
	local startingIndex = header:GetAttribute("startingIndex")
	header:SetAttribute("startingIndex", 1 - UNITS_PER_HEADER)
	header:SetAttribute("startingIndex", startingIndex)
	-- Only remember success if a child really exists now; otherwise retry the next time this
	-- header is shown (e.g. a raid-group header may be unable to pre-create while solo).
	header.cwFramesForced = header:GetAttribute("child1") ~= nil
end

local function ConfigureHeader(header, horizontal, spacing, groupSpacing)
	local point, xOffset, yOffset, columnAnchor
	if horizontal then
		point, xOffset, yOffset, columnAnchor = "LEFT", spacing, 0, "TOP"
	else
		point, xOffset, yOffset, columnAnchor = "TOP", 0, -spacing, "LEFT"
	end
	ClearChildPoints(header)
	header:SetAttribute("point", point)
	header:SetAttribute("xOffset", xOffset)
	header:SetAttribute("yOffset", yOffset)
	header:SetAttribute("sortMethod", "INDEX")
	header:SetAttribute("showPlayer", true)
	header:SetAttribute("showParty", true)
	header:SetAttribute("showSolo", true)
	header:SetAttribute("toggleForVehicle", true)
	header:SetAttribute("allowVehicleTarget", true)
	header:SetAttribute("maxColumns", 1)
	header:SetAttribute("unitsPerColumn", UNITS_PER_HEADER)
	header:SetAttribute("columnSpacing", groupSpacing)
	header:SetAttribute("columnAnchorPoint", columnAnchor)
	if header.cwKind == "partypet" then
		-- Grid2: force these so the bug in SecureGroupPetHeader_Update doesn't trigger
		header:SetAttribute("useOwnerUnit", false)
		header:SetAttribute("unitsuffix", nil)
	elseif header.cwKind == "raid" then
		header:SetAttribute("showRaid", true)
	end
end

-- Anchor `header` next to `previous` (or to the container when previous is nil).
local function Place(header, container, previous, horizontal, groupSpacing)
	header:ClearAllPoints()
	if not previous then
		header:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
	elseif horizontal then
		header:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -groupSpacing)
	else
		header:SetPoint("TOPLEFT", previous, "TOPRIGHT", groupSpacing, 0)
	end
end

function Frames:ApplyLayout()
	if InCombatLockdown() then
		CW:RunOOC("frames.layout", Frames.ApplyLayout, Frames)
		return
	end
	local c = self.container
	if not c then return end

	local db = CW.db.profile
	local f = db.frame
	local horizontal = db.horizontal

	-- scale, keeping the top-left corner in place
	if math.abs((c:GetScale() or 1) - db.scale) > 0.001 then
		self:SavePosition()
		c:SetScale(db.scale)
	end
	self:RestorePosition()
	if db.locked then self.tab:Hide() else self.tab:Show() end

	local groupType = CW.groupType or CW.GetGroupType()
	local shown = {}

	if groupType == "raid" then
		for i = 1, NUM_RAID_GROUPS do
			local h = self.raid[i]
			ConfigureHeader(h, horizontal, f.spacing, f.groupSpacing)
			Place(h, c, self.raid[i - 1], horizontal, f.groupSpacing)
			ForceFramesCreation(h)
			h:Show()
			shown[#shown + 1] = h
		end
		self.party:Hide()
		self.partyPets:Hide()
	else
		ConfigureHeader(self.party, horizontal, f.spacing, f.groupSpacing)
		Place(self.party, c, nil, horizontal, f.groupSpacing)
		ForceFramesCreation(self.party)
		self.party:Show()
		shown[#shown + 1] = self.party

		if f.showPets then
			ConfigureHeader(self.partyPets, horizontal, f.spacing, f.groupSpacing)
			Place(self.partyPets, c, self.party, horizontal, f.groupSpacing)
			ForceFramesCreation(self.partyPets)
			self.partyPets:Show()
			shown[#shown + 1] = self.partyPets
		else
			self.partyPets:Hide()
		end
		for i = 1, NUM_RAID_GROUPS do
			self.raid[i]:Hide()
		end
	end

	self.shownHeaders = shown
	self:ScheduleUpdateSize()
end

function Frames:Build()
	if self.container then return end
	self:CreateContainer()
	self:CreateHeaders()

	-- Pre-create child buttons for EVERY header now, while guaranteed out of combat, so that a
	-- later party -> raid switch never needs to initialise buttons mid-fight. ApplyLayout below
	-- then hides whatever the current group type does not need.
	local f = CW.db.profile
	local function precreate(h)
		ConfigureHeader(h, f.horizontal, f.frame.spacing, f.frame.groupSpacing)
		ForceFramesCreation(h)
	end
	precreate(self.party)
	precreate(self.partyPets)
	for i = 1, NUM_RAID_GROUPS do
		precreate(self.raid[i])
	end

	self:ApplyLayout()
end

-- Container size (used for screen clamping / the drag tab) follows the shown headers.
function Frames:ScheduleUpdateSize()
	if self.sizeTimer then
		self:CancelTimer(self.sizeTimer, true)
	end
	self.sizeTimer = self:ScheduleTimer("UpdateSize", 0.5)
end

function Frames:UpdateSize()
	self.sizeTimer = nil
	if InCombatLockdown() then
		CW:RunOOC("frames.size", Frames.UpdateSize, Frames)
		return
	end
	local c = self.container
	local cl, ct = c:GetLeft(), c:GetTop()
	if not (cl and ct and self.shownHeaders) then return end
	local right, bottom = cl + 20, ct - 20
	for _, h in ipairs(self.shownHeaders) do
		local hr, hb = h:GetRight(), h:GetBottom()
		if hr and hr > right then right = hr end
		if hb and hb < bottom then bottom = hb end
	end
	c:SetSize(right - cl, ct - bottom)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
function Frames:OnGroupType()
	CW:RunOOC("frames.layout", Frames.ApplyLayout, Frames)
end

function Frames:ApplySettings()
	CW:RunOOC("frames.layout", Frames.ApplyLayout, Frames)
end

function Frames:OnRoster()
	if self.container then
		self:ScheduleUpdateSize()
	end
end

function Frames:OnEnable()
	self:RegisterMessage("CLICKWISE_GROUP_TYPE", "OnGroupType")
	self:RegisterMessage("CLICKWISE_SETTINGS", "ApplySettings")
	self:RegisterMessage("CLICKWISE_ROSTER", "OnRoster")
	-- Core has already determined the group type; build now (or right after combat).
	CW:RunOOC("frames.build", Frames.Build, Frames)
end
