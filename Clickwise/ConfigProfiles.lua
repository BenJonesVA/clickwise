-- Profiles tab of the settings window.
--
-- A profile holds every setting: the frame layout and position, the bindings, the buff rules, the thresholds.
-- Each character gets a profile of its own the first time it logs in ("Name - Realm"), so one character's setup
-- never changes another's; a character can also use another's profile on purpose (two paladins that should
-- look and click the same). The tab shows which profile this character uses and who else shares it, and can
-- switch, create, copy into, reset and delete profiles. It is a thin layer over AceDB; the logic (own profile,
-- who shares one) lives in Core.lua.

local CW = Clickwise
local Config = CW.Config
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local ipairs, wipe = ipairs, wipe

-- "Spec 1 (Holy)": the talent tree with the most points, when the client says which
local function SpecLabel(group)
	local label = (L["Spec %d"]):format(group)
	if GetNumTalentTabs and GetTalentTabInfo then
		local best, bestPoints = nil, 0
		for tab = 1, GetNumTalentTabs() do
			local name, _, points = GetTalentTabInfo(tab, false, false, group)
			if name and type(points) == "number" and points > bestPoints then best, bestPoints = name, points end
		end
		if best then label = label .. " (" .. best .. ")" end
	end
	return label
end

local function Trim(s)
	return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Build(page)
	local S = {copyFrom = nil, deleteName = nil}
	local useItems, copyItems, deleteItems = {}, {}, {}

	local function Has(items, value)
		for _, item in ipairs(items) do
			if item.value == value then return true end
		end
		return false
	end

	-- The dropdown lists are read every time a menu opens; keep them current, and the copy / delete choice valid.
	local function Fill()
		local current = CW.db:GetCurrentProfile()
		wipe(useItems); wipe(copyItems); wipe(deleteItems)
		for _, name in ipairs(CW:ProfileNames()) do
			useItems[#useItems + 1] = {value = name, label = name}
			if name ~= current then
				copyItems[#copyItems + 1] = {value = name, label = name}
				deleteItems[#deleteItems + 1] = {value = name, label = name}
			end
		end
		if not Has(copyItems, S.copyFrom) then S.copyFrom = copyItems[1] and copyItems[1].value or nil end
		if not Has(deleteItems, S.deleteName) then S.deleteName = deleteItems[1] and deleteItems[1].value or nil end
		return current
	end

	local function Changed()
		Config:RefreshPage()
	end

	Config.NewLabel(page, 0, -8, L["Profiles"])
	local info = Config.NewLabel(page, 0, -32, "", "GameFontHighlight")
	info:SetWidth(620)
	local shared = Config.NewLabel(page, 0, -52, "", "GameFontHighlightSmall")
	shared:SetWidth(620)
	local note = Config.NewLabel(page, 0, -76,
		L["A profile holds the frame layout, bindings, buff rules and every other setting. Each character gets a profile of its own the first time it logs in, so one character's setup never changes another's. Characters can share a profile on purpose."],
		"GameFontHighlightSmall")
	note:SetWidth(620)

	-- use ----------------------------------------------------------------------------
	Config.NewLabel(page, 0, -132, L["Use profile"])
	Config.NewDropdown(page, 130, -128, 220, useItems,
		function() return Fill() end, -- (first control: fills the lists the others read)
		function(name) CW:UseProfile(name); Changed() end)

	Config.NewButton(page, 380, -130, 240, L["Give this character its own profile"], function()
		local result = CW:GiveOwnProfile()
		CW:Print(result == "created" and L["This character now has its own profile, a copy of the one it used."]
			or result == "switched" and L["This character switched to its own profile."]
			or L["This character already has its own profile."])
		Changed()
	end)

	-- new ------------------------------------------------------------------------------
	Config.NewLabel(page, 0, -172, L["New profile"])
	local box = CreateFrame("EditBox", Config.UniqueName("ClickwiseProfileEdit"), page, "InputBoxTemplate")
	box:SetPoint("TOPLEFT", page, "TOPLEFT", 136, -168)
	box:SetSize(200, 20)
	box:SetAutoFocus(false)
	box:SetMaxLetters(40)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	Config.NewButton(page, 380, -170, 140, L["Create and use"], function()
		local name = Trim(box:GetText())
		if name == "" then return end
		CW:UseProfile(name)
		box:SetText("")
		Changed()
	end)

	-- copy -----------------------------------------------------------------------------
	Config.NewLabel(page, 0, -212, L["Copy settings from"])
	Config.NewDropdown(page, 130, -208, 220, copyItems,
		function() return S.copyFrom end,
		function(name) S.copyFrom = name end)
	Config.NewButton(page, 380, -210, 80, L["Copy"], function()
		if not S.copyFrom or S.copyFrom == CW.db:GetCurrentProfile() then return end
		CW.db:CopyProfile(S.copyFrom)
		CW:Print((L["Copied the settings of %s."]):format(S.copyFrom))
		Changed()
	end)
	-- (what is left of the row is 160 units wide: the note wraps to two lines instead of running out of the window)
	local replaces = Config.NewLabel(page, 470, -211, L["Replaces everything in the profile in use."], "GameFontHighlightSmall")
	replaces:SetWidth(160)

	-- reset ----------------------------------------------------------------------------
	Config.NewButton(page, 0, -252, 220, L["Reset this profile"], function()
		CW.db:ResetProfile()
		CW:Print(L["Profile reset."])
		Changed()
	end)

	-- delete ---------------------------------------------------------------------------
	Config.NewLabel(page, 250, -256, L["Delete profile"])
	Config.NewDropdown(page, 344, -252, 120, deleteItems,
		function() return S.deleteName end,
		function(name) S.deleteName = name end)
	Config.NewButton(page, 520, -254, 80, L["Delete"], function()
		local name = S.deleteName
		if not name or name == CW.db:GetCurrentProfile() then return end
		CW:DeleteProfile(name)
		CW:Print((L["Deleted profile %s."]):format(name))
		Changed()
	end)

	-- a profile per talent spec ------------------------------------------------------------
	local specCheck = CreateFrame("CheckButton", Config.UniqueName("ClickwiseCfgCheck"), page, "InterfaceOptionsCheckButtonTemplate")
	specCheck:SetPoint("TOPLEFT", page, "TOPLEFT", -2, -286)
	local specCheckText = _G[specCheck:GetName() .. "Text"]
	specCheckText:SetText(L["A different profile for each talent spec"])
	specCheck:SetHitRectInsets(0, -((specCheckText:GetStringWidth() or 30) + 4), 0, 0)
	specCheck:SetScript("OnClick", function(self)
		CW:SetSpecProfilesEnabled(self:GetChecked() and true or false)
		Changed()
	end)
	function specCheck:Refresh()
		self:SetChecked(CW:SpecProfiles().enabled and true or false)
	end
	page.controls[#page.controls + 1] = specCheck

	local specLabels = {}
	for group = 1, 2 do
		local x = (group - 1) * 320
		specLabels[group] = Config.NewLabel(page, x, -326, SpecLabel(group))
		Config.NewDropdown(page, x + 130, -322, 150, useItems,
			function() return CW:SpecProfiles()[group] end,
			function(name) CW:SetSpecProfile(group, name); Changed() end)
	end
	page.cwSpecLabels, page.cwSpecCheck = specLabels, specCheck

	-- a profile per role ---------------------------------------------------------------------
	local roleCheck = CreateFrame("CheckButton", Config.UniqueName("ClickwiseCfgCheck"), page, "InterfaceOptionsCheckButtonTemplate")
	roleCheck:SetPoint("TOPLEFT", page, "TOPLEFT", -2, -352)
	local roleCheckText = _G[roleCheck:GetName() .. "Text"]
	roleCheckText:SetText(L["A different profile for each role"])
	roleCheck:SetHitRectInsets(0, -((roleCheckText:GetStringWidth() or 30) + 4), 0, 0)
	roleCheck:SetScript("OnClick", function(self)
		CW:SetRoleProfilesEnabled(self:GetChecked() and true or false)
		Changed()
	end)
	function roleCheck:Refresh()
		self:SetChecked(CW:RoleProfiles().enabled and true or false)
	end
	page.controls[#page.controls + 1] = roleCheck

	local ROLE_NAMES = {TANK = L["Tank"], HEALER = L["Healer"], DAMAGER = L["Damage"]}
	local roleLabels = {}
	for i, role in ipairs(CW.ROLES) do
		local x = (i - 1) * 210
		roleLabels[role] = Config.NewLabel(page, x, -392, ROLE_NAMES[role])
		Config.NewDropdown(page, x + 56, -388, 110, useItems,
			function() return CW:RoleProfiles()[role] end,
			function(name) CW:SetRoleProfile(role, name); Changed() end)
	end
	page.cwRoleLabels, page.cwRoleCheck = roleLabels, roleCheck

	page.cwInfo, page.cwShared = info, shared -- (the harness reads them)

	function page:OnRefresh()
		for group = 1, 2 do
			specLabels[group]:SetText(SpecLabel(group) .. (CW:ActiveSpec() == group and " *" or ""))
		end
		local playing = CW.GetUnitRole("player")
		for _, role in ipairs(CW.ROLES) do
			roleLabels[role]:SetText(ROLE_NAMES[role] .. (playing == role and " *" or ""))
		end
		local current = CW.db:GetCurrentProfile()
		info:SetText((L["Profile in use: %s"]):format(current))
		local users = CW:ProfileUsers(current)
		if #users > 0 then
			shared:SetText("|cffffcc00" .. (L["Shared with: %s. A change made here changes it for them too."]):format(table.concat(users, ", ")) .. "|r")
		else
			shared:SetText(L["Only this character uses it."])
		end
	end
end

Config.builders.profiles = Build
