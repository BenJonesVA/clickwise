-- Assignments tab of the settings window.
--
--   left  : every target a rule can be written for (Everyone else, the three roles, the ten classes),
--           each with a summary of its buff list; click one to edit it
--   right : the selected target's ordered buff list (highest priority first) with Up / Down / Remove,
--           an "Add" dropdown of the groups this character can cast, and Clear rule
--
-- Resolution (Buffs.lua): a unit uses the rule of its role, else of its class, else "Everyone else".
-- Every buff in the list the unit does not already have (from anyone) is shown on its frame, and an
-- "Assigned buff" binding casts the first of them (out of combat unless the binding says otherwise); the next
-- click casts the next. Buffs that replace each other (a paladin's blessings) are alternatives.

local CW = Clickwise
local Config = CW.Config
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local ipairs = ipairs

local ROW_H = 22
local CHAIN_ROWS = 6
local FORM_X = 330

local function SetShown(widget, show) -- Region:SetShown does not exist on 3.3.5
	if show then widget:Show() else widget:Hide() end
end

local function Build(page)
	local Buffs = CW.Buffs
	local S = {target = "ROLE:TANK", addKey = nil}
	local addItems = {} -- filled in place: the dropdown re-reads it every time it opens
	local Refresh, addDropdown, addButton

	Config.NewLabel(page, 0, -8, L["Who gets which buff"], "GameFontNormal")

	----------------------------------------------------------------------------
	-- Left column: targets
	----------------------------------------------------------------------------
	local rows = {}
	for i, target in ipairs(CW.BuffTargets) do
		local row = CreateFrame("Button", nil, page)
		row:SetSize(310, ROW_H)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -30 - (i - 1) * ROW_H)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints(row)
		CW.SetSolidColor(row.sel, 0.2, 0.5, 1, 0.25)
		row.sel:Hide()
		row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.name:SetWidth(96)
		row.name:SetJustifyH("LEFT")
		row.summary = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.summary:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.summary:SetWidth(200)
		row.summary:SetJustifyH("LEFT")
		row.key = target.key
		row:SetScript("OnClick", function()
			S.target = target.key
			Refresh()
		end)
		rows[i] = row
	end

	----------------------------------------------------------------------------
	-- Right column: the selected target's list
	----------------------------------------------------------------------------
	local title = Config.NewLabel(page, FORM_X, -8, "", "GameFontNormal")
	local hint = Config.NewLabel(page, FORM_X, -30,
		L["Buffs the unit lacks are cast in this order, one per click. Buffs that replace each other (a paladin's blessings) are alternatives: the first one nobody else provides."],
		"GameFontHighlightSmall")
	hint:SetWidth(290)

	local chainRows = {}
	for i = 1, CHAIN_ROWS do
		local y = -76 - (i - 1) * 26
		local r = {}
		r.icon = page:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(18, 18)
		r.icon:SetPoint("TOPLEFT", page, "TOPLEFT", FORM_X, y)
		r.text = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
		r.text:SetWidth(120)
		r.text:SetJustifyH("LEFT")
		r.up = Config.NewButton(page, FORM_X + 152, y + 2, 40, L["Up"], function()
			r.move(-1)
		end)
		r.down = Config.NewButton(page, FORM_X + 196, y + 2, 54, L["Down"], function()
			r.move(1)
		end)
		r.remove = Config.NewButton(page, FORM_X + 254, y + 2, 26, "X", function()
			local list = Buffs:GetRule(S.target)
			table.remove(list, i)
			Buffs:SetRule(S.target, list)
			Refresh()
		end)
		r.move = function(delta)
			local list = Buffs:GetRule(S.target)
			local j = i + delta
			if list[i] and list[j] then
				list[i], list[j] = list[j], list[i]
				Buffs:SetRule(S.target, list)
				Refresh()
			end
		end
		chainRows[i] = r
	end

	local addLabel = Config.NewLabel(page, FORM_X, -240, L["Add a buff"], "GameFontNormalSmall")
	addDropdown = Config.NewDropdown(page, FORM_X, -256, 150, addItems,
		function() return S.addKey or (addItems[1] and addItems[1].value) end, -- Refresh() may run before our own
		function(v) S.addKey = v end)
	addButton = Config.NewButton(page, FORM_X + 176, -257, 60, L["Add"], function()
		if S.addKey then
			local list = Buffs:GetRule(S.target)
			list[#list + 1] = S.addKey
			Buffs:SetRule(S.target, list)
			Refresh()
		end
	end)
	local clearButton = Config.NewButton(page, FORM_X, -300, 130, L["Clear this rule"], function()
		Buffs:SetRule(S.target, nil)
		Refresh()
	end)
	local note = Config.NewLabel(page, FORM_X, -336,
		L["Bind a click to 'Assigned buff' in the Bindings tab (it starts as out of combat only; 'Cast when' changes that). A unit uses its role's rule, else its class's, else Everyone else. If a tank is not recognised as one, use a class rule."],
		"GameFontHighlightSmall")
	note:SetWidth(290)

	function Refresh()
		-- left column
		for _, row in ipairs(rows) do
			row.name:SetText(Buffs:TargetLabel(row.key))
			local labels = {}
			for _, key in ipairs(Buffs:GetRule(row.key)) do
				labels[#labels + 1] = Buffs:GetGroup(key).label
			end
			row.summary:SetText(#labels > 0 and CW.TruncateUTF8(table.concat(labels, " > "), 36) or "-")
			if row.key == S.target then row.sel:Show() else row.sel:Hide() end
		end

		-- right column
		title:SetText(Buffs:TargetLabel(S.target))
		local list = Buffs:GetRule(S.target)
		local inList = {}
		for i = 1, CHAIN_ROWS do
			local r, key = chainRows[i], list[i]
			if key then
				inList[key] = true
				local group = Buffs:GetGroup(key)
				local castable = Buffs:IsAvailable(key)
				r.icon:SetTexture(castable and select(3, GetSpellInfo(Buffs:GetCastSpell(key))) or "Interface\\Icons\\INV_Misc_QuestionMark")
				r.text:SetText(i .. ". " .. (castable and group.label or (group.label .. " (unknown)")))
				r.icon:Show()
				r.text:Show()
				r.up:Show()
				r.down:Show()
				r.remove:Show()
				if i == 1 then r.up:Disable() else r.up:Enable() end
				if i == #list then r.down:Disable() else r.down:Enable() end
			else
				r.icon:Hide()
				r.text:Hide()
				r.up:Hide()
				r.down:Hide()
				r.remove:Hide()
			end
		end

		-- candidates for "Add": groups this character can cast and that are not in the list yet
		for i = #addItems, 1, -1 do addItems[i] = nil end
		for _, group in ipairs(Buffs:GetGroups()) do
			if Buffs:IsAvailable(group.key) and not inList[group.key] then
				addItems[#addItems + 1] = {value = group.key, label = group.label}
			end
		end
		local valid = false
		for _, item in ipairs(addItems) do
			if item.value == S.addKey then valid = true end
		end
		if not valid then S.addKey = addItems[1] and addItems[1].value or nil end
		local canAdd = #addItems > 0 and #list < CHAIN_ROWS
		SetShown(addLabel, canAdd)
		SetShown(addDropdown, canAdd)
		SetShown(addButton, canAdd)
		if canAdd then addDropdown:Refresh() end
		SetShown(clearButton, #list > 0)
	end

	function page:OnRefresh()
		Refresh()
	end
end

Config.builders.assign = Build
