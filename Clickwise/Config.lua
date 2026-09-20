-- Clickwise settings window: a standalone, movable, tabbed frame (General | Layout |
-- Bindings | Buffs | Assignments), opened with /cw or from the Interface Options entry. It replaces the
-- old single-page Interface Options layout, which overflowed that panel's fixed width.
--
-- Built lazily on first open (the DB does not exist when this file loads). Every template
-- frame gets an explicit unique name: OptionsSliderTemplate / UIDropDownMenuTemplate /
-- InputBoxTemplate look up children through their parent's name on 3.3.5.
--
-- Shared widget helpers live on CW.Config so ConfigBindings.lua can reuse them.

local CW = Clickwise
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local ipairs, tostring, floor, tinsert = ipairs, tostring, math.floor, table.insert

local Config = {}
CW.Config = Config
Config.builders = {} -- page key -> function(page); filled by ConfigBindings.lua etc.

local WINDOW_W, WINDOW_H = 680, 520

local nameCounter = 0
function Config.UniqueName(prefix)
	nameCounter = nameCounter + 1
	return prefix .. nameCounter
end

--------------------------------------------------------------------------------
-- DB access by path, e.g. {"frame", "width"}
--------------------------------------------------------------------------------
function Config.Get(path)
	local t = CW.db.profile
	for i = 1, #path - 1 do t = t[path[i]] end
	return t[path[#path]]
end

function Config.Set(path, value)
	local t = CW.db.profile
	for i = 1, #path - 1 do t = t[path[i]] end
	t[path[#path]] = value
	CW:RefreshAll()
end

--------------------------------------------------------------------------------
-- Widget helpers. Each registers itself in page.controls so a page can Refresh() them all.
--------------------------------------------------------------------------------
function Config.NewLabel(page, x, y, text, fontObject)
	local fs = page:CreateFontString(nil, "ARTWORK", fontObject or "GameFontNormal")
	fs:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

function Config.NewCheck(page, x, y, label, path)
	local name = Config.UniqueName("ClickwiseCfgCheck")
	local cb = CreateFrame("CheckButton", name, page, "InterfaceOptionsCheckButtonTemplate")
	cb:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
	local text = _G[name .. "Text"]
	text:SetText(label)
	-- the template's click area reaches 100 units past the box; cover only the box and its own label
	cb:SetHitRectInsets(0, -((text:GetStringWidth() or 30) + 4), 0, 0)
	cb:SetScript("OnClick", function(self)
		Config.Set(path, self:GetChecked() and true or false)
	end)
	function cb:Refresh()
		self:SetChecked(Config.Get(path) and true or false)
	end
	page.controls[#page.controls + 1] = cb
	return cb
end

-- The label follows the drag live, but the value is only committed on mouse release:
-- committing per tick would rebuild the whole layout dozens of times per drag.
function Config.NewSlider(page, x, y, label, path, minV, maxV, step, fmt, width)
	local name = Config.UniqueName("ClickwiseCfgSlider")
	local s = CreateFrame("Slider", name, page, "OptionsSliderTemplate")
	s:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
	s:SetWidth(width or 240)
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	_G[name .. "Low"]:SetText(tostring(minV))
	_G[name .. "High"]:SetText(tostring(maxV))
	local text = _G[name .. "Text"]
	local function show(v) text:SetText(label .. ": " .. (fmt):format(v)) end
	s:SetScript("OnValueChanged", function(self, value)
		value = floor(value / step + 0.5) * step
		show(value)
		if self.cwUpdating then return end
		if self.cwDragging then
			self.cwPending = value
		else
			Config.Set(path, value)
		end
	end)
	s:SetScript("OnMouseDown", function(self) self.cwDragging = true end)
	s:SetScript("OnMouseUp", function(self)
		self.cwDragging = false
		if self.cwPending ~= nil then
			local value = self.cwPending
			self.cwPending = nil
			Config.Set(path, value)
		end
	end)
	function s:Refresh()
		self.cwUpdating = true
		local v = Config.Get(path)
		self:SetValue(v)
		show(v)
		self.cwUpdating = false
	end
	page.controls[#page.controls + 1] = s
	return s
end

-- items = {{value=, label=}, ...}; get() -> current value; set(value) is called on selection.
function Config.NewDropdown(page, x, y, width, items, get, set)
	local dd = CreateFrame("Frame", Config.UniqueName("ClickwiseCfgDrop"), page, "UIDropDownMenuTemplate")
	dd:SetPoint("TOPLEFT", page, "TOPLEFT", x - 16, y + 2) -- the template has a 16 unit left inset
	local initialised = false
	function dd:Refresh()
		if not initialised then
			initialised = true
			UIDropDownMenu_Initialize(dd, function()
				for _, item in ipairs(items) do
					local info = UIDropDownMenu_CreateInfo()
					info.text = item.label
					info.value = item.value
					info.checked = (get() == item.value)
					info.func = function()
						set(item.value)
						UIDropDownMenu_SetSelectedValue(dd, item.value)
					end
					UIDropDownMenu_AddButton(info)
				end
			end)
			UIDropDownMenu_SetWidth(dd, width)
		end
		UIDropDownMenu_SetSelectedValue(dd, get())
	end
	page.controls[#page.controls + 1] = dd
	return dd
end

function Config.NewButton(parent, x, y, width, label, onClick)
	local b = CreateFrame("Button", Config.UniqueName("ClickwiseCfgButton"), parent, "UIPanelButtonTemplate")
	b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	b:SetSize(width, 22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end

--------------------------------------------------------------------------------
-- Pages
--------------------------------------------------------------------------------
local COMBAT_COLOR_MODES = {
	{value = "AUTO", label = L["Automatic (by my role)"]},
	{value = "HEALTH", label = L["Health (healer)"]},
	{value = "THREAT", label = L["Threat (tank)"]},
	{value = "OFF", label = L["Off"]},
}

local MY_ROLES = {
	{value = "AUTO", label = L["Automatic"]},
	{value = "TANK", label = L["Tank"]},
	{value = "HEALER", label = L["Healer"]},
	{value = "DAMAGER", label = L["Damage"]},
}

local TOOLTIP_MODES = {
	{value = "DETAILED", label = L["Detailed"]},
	{value = "BASIC", label = L["Standard"]},
	{value = "OFF", label = L["Off"]},
}

local function BuildGeneral(page)
	Config.NewCheck(page, 4, -8, L["Lock frames"], {"locked"})
	Config.NewCheck(page, 4, -36, L["Show pets"], {"frame", "showPets"})
	Config.NewCheck(page, 4, -64, L["Range fade"], {"range", "enabled"})
	Config.NewCheck(page, 4, -92, L["Incoming heal prediction"], {"healPred", "enabled"})
	Config.NewCheck(page, 4, -120, L["Include my own heals"], {"healPred", "includeOwn"})

	Config.NewSlider(page, 340, -30, L["Out-of-range alpha"], {"range", "alpha"}, 0.1, 0.9, 0.05, "%.2f")
	Config.NewSlider(page, 340, -90, L["Heal look-ahead (seconds)"], {"healPred", "timeFrame"}, 1, 10, 1, "%d")

	-- hover tooltip (UnitFrame.lua): Detailed adds health / role / buffs / what each click does
	Config.NewLabel(page, 340, -152, L["Unit tooltip"])
	Config.NewDropdown(page, 430, -148, 110, TOOLTIP_MODES,
		function() return Config.Get({"tooltip", "mode"}) end,
		function(value) Config.Set({"tooltip", "mode"}, value) end)
	-- one above the other: side by side the first label ran into the second box
	Config.NewCheck(page, 336, -180, L["Show click bindings"], {"tooltip", "bindings"})
	Config.NewCheck(page, 336, -206, L["Show buff status"], {"tooltip", "buffs"})

	Config.NewButton(page, 8, -170, 150, L["Reset position"], function()
		CW.Frames:ResetPosition()
	end)
	-- the player's own role: detected from the talents, or set by hand (a paladin can tank or heal)
	Config.NewLabel(page, 8, -208, L["My role"])
	Config.NewDropdown(page, 84, -204, 100, MY_ROLES,
		function() return CW:MyRole() end,
		function(value) CW:SetMyRole(value) end)
	local tip = Config.NewLabel(page, 8, -240,L["Tip: unlock the frames, then drag the blue 'Clickwise' tab above them."], "GameFontHighlightSmall")
	tip:SetWidth(600)

	-- health bars change color in combat (CombatColor.lua)
	Config.NewLabel(page, 8, -256, L["Combat colors"])
	Config.NewDropdown(page, 110, -252, 150, COMBAT_COLOR_MODES,
		function() return Config.Get({"combatColor", "mode"}) end,
		function(value) Config.Set({"combatColor", "mode"}, value) end)
	local ccNote = Config.NewLabel(page, 8, -286,
		L["In combat the bars turn green, then yellow, then red. Automatic: threat colors if you tank, health colors otherwise."],
		"GameFontHighlightSmall")
	ccNote:SetWidth(600)
	Config.NewSlider(page, 8, -330, L["Yellow at health (%)"], {"combatColor", "yellow"}, 5, 100, 5, "%d", 190)
	Config.NewSlider(page, 230, -330, L["Red below health (%)"], {"combatColor", "red"}, 0, 95, 5, "%d", 190)
	Config.NewSlider(page, 452, -330, L["Threat warning (%)"], {"combatColor", "threat"}, 10, 100, 5, "%d", 170)

	-- a made-up group to try the frames without other players (Test.lua)
	Config.NewLabel(page, 8, -388, L["Test group"])
	for i, n in ipairs(CW.Test.SIZES) do
		Config.NewButton(page, 100 + (i - 1) * 52, -384, 48, tostring(n), function() CW.Test:Start(n) end)
	end
	Config.NewButton(page, 100 + #CW.Test.SIZES * 52, -384, 48, L["Off"], function() CW.Test:Stop() end)
	Config.NewButton(page, 100 + (#CW.Test.SIZES + 1) * 52, -384, 110, L["Test combat"], function() CW.Test:ToggleCombat() end)
end

local HEALTH_TEXT = {
	{value = "NONE", label = L["None"]},
	{value = "DEFICIT", label = L["Deficit"]},
	{value = "PERCENT", label = L["Percent"]},
}

-- The fonts LibSharedMedia knows ("" = the game's own). With the SharedMedia addon there can be a hundred, and a
-- dropdown does not scroll on 3.3.5 (it would run off the screen), so the font is stepped through with two arrows.
local function FontList()
	local list = {""}
	local LSM = LibStub("LibSharedMedia-3.0", true)
	for _, name in ipairs((LSM and LSM:List("font")) or {}) do list[#list + 1] = name end
	return list
end

local function StepFont(delta)
	local list = FontList()
	local current = Config.Get({"frame", "nameFont"}) or ""
	local index = 1
	for i, name in ipairs(list) do
		if name == current then index = i end
	end
	Config.Set({"frame", "nameFont"}, list[(index - 1 + delta) % #list + 1])
end

local function BuildLayout(page)
	Config.NewCheck(page, 4, -8, L["Horizontal layout"], {"horizontal"})
	Config.NewCheck(page, 4, -36, L["Class colored bars"], {"frame", "classColor"})
	Config.NewCheck(page, 4, -64, L["Show tank / healer role icon"], {"frame", "showRoleIcon"})

	Config.NewLabel(page, 8, -104, L["Health text"])
	Config.NewDropdown(page, 100, -100, 110, HEALTH_TEXT,
		function() return Config.Get({"frame", "healthText"}) end,
		function(value) Config.Set({"frame", "healthText"}, value) end)

	-- the font of the names (UnitFrame.lua), shown in its own face; the size is the slider on the right
	Config.NewLabel(page, 8, -136, L["Name font"])
	local fontHolder
	local fontPrev = Config.NewButton(page, 86, -132, 22, "<", function() StepFont(-1); fontHolder:Refresh() end)
	fontHolder = CreateFrame("Frame", nil, page)
	fontHolder:SetSize(150, 22)
	fontHolder:SetPoint("TOPLEFT", page, "TOPLEFT", 112, -132)
	local fontName = fontHolder:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fontName:SetAllPoints(fontHolder)
	fontName:SetJustifyH("CENTER")
	local fontNext = Config.NewButton(page, 266, -132, 22, ">", function() StepFont(1); fontHolder:Refresh() end)
	function fontHolder:Refresh()
		local name = Config.Get({"frame", "nameFont"}) or ""
		local path = CW.UnitFrame.FontPath(name)
		if not fontName:SetFont(path, 12) then fontName:SetFont(STANDARD_TEXT_FONT, 12) end
		-- (a font is named when it exists: "Friz Quadrata TT" IS the game's font file, and still a choice of its own)
		local LSM = LibStub("LibSharedMedia-3.0", true)
		fontName:SetText(name ~= "" and LSM and LSM:Fetch("font", name, true) and name or L["Default font"])
	end
	page.controls[#page.controls + 1] = fontHolder
	page.cwFontName, page.cwFontPrev, page.cwFontNext = fontName, fontPrev, fontNext

	-- debuff highlight (Debuffs.lua)
	Config.NewLabel(page, 8, -176, L["Debuffs"])
	Config.NewCheck(page, 4, -198, L["Highlight debuffs"], {"debuffs", "enabled"})
	Config.NewCheck(page, 4, -226, L["Only debuffs I can remove"], {"debuffs", "onlyMine"})
	Config.NewCheck(page, 4, -254, L["Show the debuff icon"], {"debuffs", "icon"})

	-- aggro border and threat bar (Threat.lua)
	Config.NewLabel(page, 8, -292, L["Threat"])
	Config.NewCheck(page, 4, -314, L["Aggro border"], {"threat", "border"})
	Config.NewCheck(page, 4, -342, L["Threat bar"], {"threat", "bar"})
	local threatNote = Config.NewLabel(page, 8, -374,
		L["Red ring: has the enemy. Yellow: about to take it. Tanks and pets get none. The warning percentage is on the General tab."],
		"GameFontHighlightSmall")
	threatNote:SetWidth(310)

	Config.NewSlider(page, 340, -30, L["Scale"], {"scale"}, 0.5, 2, 0.05, "%.2f")
	Config.NewSlider(page, 340, -90, L["Frame width"], {"frame", "width"}, 40, 160, 1, "%d")
	Config.NewSlider(page, 340, -150, L["Frame height"], {"frame", "height"}, 20, 80, 1, "%d")
	Config.NewSlider(page, 340, -210, L["Frame spacing"], {"frame", "spacing"}, 0, 10, 1, "%d")
	Config.NewSlider(page, 340, -270, L["Group spacing"], {"frame", "groupSpacing"}, 0, 30, 1, "%d")
	Config.NewSlider(page, 340, -330, L["Name size"], {"frame", "nameSize"}, 6, 20, 1, "%d")
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------
local TABS = {
	{key = "general", label = L["General"], build = BuildGeneral},
	{key = "layout", label = L["Layout"], build = BuildLayout},
	{key = "bindings", label = L["Bindings"]}, -- builder registered by ConfigBindings.lua
	{key = "buffs", label = L["Buffs"]}, -- builder registered by ConfigBuffs.lua
	{key = "assign", label = L["Assignments"]}, -- builder registered by ConfigAssign.lua
	{key = "profiles", label = L["Profiles"]}, -- builder registered by ConfigProfiles.lua
}

function Config:SelectTab(index)
	self.selected = index
	for i, tab in ipairs(TABS) do
		if i == index then
			tab.page:Show()
			tab.button:LockHighlight()
		else
			tab.page:Hide()
			tab.button:UnlockHighlight()
		end
	end
	self:RefreshPage()
end

function Config:RefreshPage()
	local tab = TABS[self.selected or 1]
	if not (tab and tab.page) then return end
	for _, control in ipairs(tab.page.controls) do
		control:Refresh()
	end
	if tab.page.OnRefresh then
		tab.page:OnRefresh()
	end
end

function Config:Build()
	if self.frame then return end

	local f = CreateFrame("Frame", "ClickwiseConfigFrame", UIParent)
	f:SetSize(WINDOW_W, WINDOW_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = {left = 11, right = 12, top = 12, bottom = 11},
	})
	f:SetScript("OnShow", function() Config:RefreshPage() end)
	self.frame = f
	tinsert(UISpecialFrames, "ClickwiseConfigFrame") -- Escape closes it

	local header = f:CreateTexture(nil, "ARTWORK")
	header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	header:SetSize(300, 64)
	header:SetPoint("TOP", f, "TOP", 0, 12)
	local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOP", header, "TOP", 0, -14)
	title:SetText("Clickwise")

	local close = CreateFrame("Button", "ClickwiseConfigClose", f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

	local x = 24
	for i, tab in ipairs(TABS) do
		local b = CreateFrame("Button", "ClickwiseConfigTab" .. i, f, "UIPanelButtonTemplate")
		b:SetSize(100, 24)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -44)
		b:SetText(tab.label)
		b:SetScript("OnClick", function() Config:SelectTab(i) end)
		x = x + 104
		tab.button = b

		local page = CreateFrame("Frame", nil, f)
		page:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -82)
		page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 24)
		page.controls = {}
		page:Hide()
		tab.page = page

		local builder = tab.build or Config.builders[tab.key]
		if builder then builder(page) end
	end

	self:SelectTab(1)
	-- CreateFrame returns SHOWN frames on 3.3.5; start hidden so the first Toggle() opens it
	-- instead of seeing "already shown" and closing it again.
	f:Hide()
end

function Config:Toggle()
	self:Build()
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self.frame:Show()
	end
end

function Config:Open(tabKey)
	self:Build()
	self.frame:Show()
	if tabKey then
		for i, tab in ipairs(TABS) do
			if tab.key == tabKey then self:SelectTab(i) end
		end
	end
end
