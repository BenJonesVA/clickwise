-- Smart tab of the settings window: the rule-set builder (rules and their compiled form live in Smart.lua).
--
--   left  : the rule set (a dropdown, New / Rename / Delete with one name box) and its rules as an ordered list,
--           the "Otherwise" row last, with Up / Down / Delete for the selected rule
--   right : the selected rule: how its conditions combine (all / any), up to four condition rows (NOT, a condition
--           from the catalog, its value), the action, Save / New rule, and a status area that reads the rule out in words,
--           warns, and shows the macro it compiles to for your own frame
--
-- Every edit goes through CW.Smart, which asks the click-cast engine to rewrite the clicks (out of combat).

local CW = Clickwise
local Config = CW.Config
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local ipairs, pairs, tostring = ipairs, pairs, tostring
local concat = table.concat

local ROW_H = 20
local LEFT_W = 262
local RIGHT_X = 290
local NOT_X, COND_X, PARAM_X = RIGHT_X, RIGHT_X + 48, RIGHT_X + 232
local COND_TOP, COND_STEP = -34, -30

local MODE_TEXT = {all = L["All of them"], any = L["Any one of them"]}
local BUTTON_TEXT = {["1"] = L["Left"], ["2"] = L["Right"], ["3"] = L["Middle"], ["4"] = L["Button 4"], ["5"] = L["Button 5"]}

local function Build(page)
	local Smart = CW.Smart
	if not Smart then
		-- Smart.lua is listed in the .toc but was not loaded (a stale file list): say so instead of an empty tab
		local note = Config.NewLabel(page, 8, -8, L["Smart.lua was not loaded. Fully restart the game client (a /reload is not enough after files are added to the .toc)."], "GameFontHighlight")
		note:SetWidth(560)
		return
	end
	local COND = Smart.COND
	local ClickCast = CW.ClickCast

	-- the form: what the editor is showing. sel: a rule's index, 0 = the "otherwise", nil = a new rule.
	local S = {set = nil, sel = nil, mode = "all", conds = {}, kind = "spell", spell = "", group = CW.BuffGroups[1].key, notice = nil}
	for i = 1, Smart.MAX_CONDS do S.conds[i] = {key = "", arg = nil, neg = false} end

	local UpdateList, UpdateStatus, SyncForm, SyncRow, SyncAction

	----------------------------------------------------------------------------
	-- Left column: the set and its rules
	----------------------------------------------------------------------------
	Config.NewLabel(page, 0, -4, L["Rule set"])
	local setItems = {}
	local function FillSetItems()
		for i = #setItems, 1, -1 do setItems[i] = nil end
		for _, name in ipairs(Smart:SetNames()) do setItems[#setItems + 1] = {value = name, label = name} end
		if #setItems == 0 then setItems[1] = {value = "", label = L["(no sets yet)"]} end
	end
	FillSetItems()
	local function Notice(text) S.notice = text end

	local function LoadRule(index)
		local set = Smart:GetSet(S.set)
		local rule = set and set.rules[index]
		for i = 1, Smart.MAX_CONDS do
			local c = rule and rule.conds[i]
			S.conds[i] = c and {key = c.key, arg = c.arg, neg = c.neg and true or false} or {key = "", arg = nil, neg = false}
		end
		S.mode = rule and rule.mode or "all"
		S.sel = rule and index or nil
		local action = rule and rule.action
		S.kind, S.spell, S.group = (action and action.type) or "spell", (action and action.spell) or "", (action and action.group) or CW.BuffGroups[1].key
	end

	local function LoadOtherwise()
		local set = Smart:GetSet(S.set)
		local action = set and set.otherwise
		for i = 1, Smart.MAX_CONDS do S.conds[i] = {key = "", arg = nil, neg = false} end
		S.mode, S.sel = "all", 0
		S.kind, S.spell, S.group = (action and action.type) or "none", (action and action.spell) or "", (action and action.group) or CW.BuffGroups[1].key
	end

	local function SelectSet(name)
		S.set = (name and name ~= "") and name or nil
		LoadRule(nil)
		S.notice = nil
		SyncForm()
	end

	local setDrop = Config.NewDropdown(page, 0, -20, 130, setItems,
		function() return S.set or "" end,
		function(value) SelectSet(value) end)

	Config.NewButton(page, 180, -22, 82, L["Delete set"], function()
		if not S.set then return end
		local ok, using = Smart:DeleteSet(S.set)
		if ok then
			local names = Smart:SetNames()
			S.set = names[1]
			LoadRule(nil)
			S.notice = nil
		else
			local keys = {}
			for _, b in ipairs(using) do
				local mod = ClickCast.ModifierText(b.modifier or "")
				keys[#keys + 1] = (mod ~= "" and (mod .. "+") or "") .. (BUTTON_TEXT[b.button] or b.button)
			end
			Notice((L["%s is used by a binding (%s): remove that binding first."]):format(S.set, concat(keys, ", ")))
		end
		SyncForm()
	end)

	local nameBox = CreateFrame("EditBox", Config.UniqueName("ClickwiseSmartName"), page, "InputBoxTemplate")
	nameBox:SetPoint("TOPLEFT", page, "TOPLEFT", 6, -58)
	nameBox:SetSize(120, 20)
	nameBox:SetAutoFocus(false)
	nameBox:SetMaxLetters(24)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
	Config.NewButton(page, 136, -58, 60, L["New set"], function()
		local ok, err = Smart:CreateSet(nameBox:GetText())
		if ok then
			S.set = Smart.Trim(nameBox:GetText())
			nameBox:SetText("")
			LoadRule(nil)
			S.notice = nil
		else
			Notice(err)
		end
		SyncForm()
	end)
	Config.NewButton(page, 200, -58, 62, L["Rename"], function()
		if not S.set then return end
		local new = Smart.Trim(nameBox:GetText())
		local ok, err = Smart:RenameSet(S.set, nameBox:GetText())
		if ok then
			S.set = new
			nameBox:SetText("")
			S.notice = nil
		else
			Notice(err)
		end
		SyncForm()
	end)

	Config.NewLabel(page, 0, -92, L["Rules (the first that holds wins)"])
	local rows = {}
	local function MakeRow(i, y)
		local row = CreateFrame("Button", nil, page)
		row:SetSize(LEFT_W, ROW_H)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, y)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints(row)
		CW.SetSolidColor(row.sel, 0.2, 0.5, 1, 0.25)
		row.sel:Hide()
		row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.text:SetWidth(LEFT_W - 8)
		row.text:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self)
			if self.index == 0 then LoadOtherwise() elseif self.index then LoadRule(self.index) end
			S.notice = nil
			SyncForm()
		end)
		rows[i] = row
		return row
	end
	for i = 1, Smart.MAX_RULES do MakeRow(i, -110 - (i - 1) * ROW_H) end
	local otherRow = MakeRow(Smart.MAX_RULES + 1, -110 - Smart.MAX_RULES * ROW_H)
	otherRow.index = 0

	function UpdateList()
		local set = Smart:GetSet(S.set)
		for i = 1, Smart.MAX_RULES do
			local row, rule = rows[i], set and set.rules[i]
			if rule then
				row.index = i
				row.text:SetText(CW.TruncateUTF8(i .. ". " .. Smart.RuleText(rule), 46))
				if S.sel == i then row.sel:Show() else row.sel:Hide() end
				row:Show()
			else
				row.index = nil
				row.sel:Hide()
				row:Hide()
			end
		end
		if set then
			otherRow.text:SetText(CW.TruncateUTF8(L["Otherwise"] .. ": " .. Smart.ActionText(set.otherwise), 46))
			if S.sel == 0 then otherRow.sel:Show() else otherRow.sel:Hide() end
			otherRow:Show()
		else
			otherRow:Hide()
		end
	end

	local function Move(delta)
		if S.set and S.sel and S.sel > 0 then
			S.sel = Smart:MoveRule(S.set, S.sel, delta)
			S.notice = nil
			SyncForm()
		end
	end
	Config.NewButton(page, 0, -296, 60, L["Up"], function() Move(-1) end)
	Config.NewButton(page, 64, -296, 60, L["Down"], function() Move(1) end)
	Config.NewButton(page, 128, -296, 100, L["Delete rule"], function()
		if S.set and S.sel and S.sel > 0 and Smart:DeleteRule(S.set, S.sel) then
			LoadRule(nil)
			S.notice = nil
			SyncForm()
		end
	end)

	----------------------------------------------------------------------------
	-- Right column: the rule
	----------------------------------------------------------------------------
	local ruleLabel = Config.NewLabel(page, RIGHT_X, -4, L["Conditions"])
	local modeButton = Config.NewButton(page, RIGHT_X + 92, -2, 150, MODE_TEXT.all, function()
		S.mode = (S.mode == "any") and "all" or "any"
		S.notice = nil
		SyncForm()
	end)

	local condItems = {{value = "", label = L["(no condition)"]}}
	for _, def in ipairs(Smart.CONDITIONS) do condItems[#condItems + 1] = {value = def.key, label = Smart.Cap(def.text)} end

	local condRows = {}
	for i = 1, Smart.MAX_CONDS do
		local y = COND_TOP + (i - 1) * COND_STEP
		local row = {items = {}}
		local checkName = Config.UniqueName("ClickwiseSmartNot")
		row.check = CreateFrame("CheckButton", checkName, page, "InterfaceOptionsCheckButtonTemplate")
		row.check:SetPoint("TOPLEFT", page, "TOPLEFT", NOT_X, y + 2)
		_G[checkName .. "Text"]:SetText(L["not"])
		row.check:SetHitRectInsets(0, -((_G[checkName .. "Text"]:GetStringWidth() or 20) + 4), 0, 0)
		row.check:SetScript("OnClick", function(self)
			S.conds[i].neg = self:GetChecked() and true or false
			S.notice = nil
			UpdateStatus()
		end)
		row.drop = Config.NewDropdown(page, COND_X, y, 130, condItems,
			function() return S.conds[i].key or "" end,
			function(value)
				local c = S.conds[i]
				c.key = value
				local def = COND[value]
				c.arg = (def and def.arg == "choice") and def.choices[1].value or nil
				S.notice = nil
				SyncRow(i)
				UpdateStatus()
			end)
		row.paramDrop = Config.NewDropdown(page, PARAM_X, y, 62, row.items,
			function() return S.conds[i].arg end,
			function(value) S.conds[i].arg = value; S.notice = nil; UpdateStatus() end)
		row.box = CreateFrame("EditBox", Config.UniqueName("ClickwiseSmartArg"), page, "InputBoxTemplate")
		row.box:SetPoint("TOPLEFT", page, "TOPLEFT", PARAM_X + 6, y - 2)
		row.box:SetSize(104, 20)
		row.box:SetAutoFocus(false)
		row.box:SetMaxLetters(40)
		row.box:SetScript("OnEscapePressed", row.box.ClearFocus)
		row.box:SetScript("OnEnterPressed", row.box.ClearFocus)
		row.box:SetScript("OnTextChanged", function(self, userInput)
			if userInput then
				S.conds[i].arg = Smart.Trim(self:GetText())
				S.notice = nil
				UpdateStatus()
			end
		end)
		condRows[i] = row
	end

	function SyncRow(i)
		local row, c = condRows[i], S.conds[i]
		local def = COND[c.key]
		row.check:SetChecked(c.neg and true or false)
		if def and def.arg == "choice" then
			for j = #row.items, 1, -1 do row.items[j] = nil end
			for _, choice in ipairs(def.choices) do row.items[#row.items + 1] = choice end
			row.paramDrop:Invalidate()
			row.paramDrop:Refresh()
			row.paramDrop:Show()
			row.box:Hide()
		elseif def and def.arg == "text" then
			row.paramDrop:Hide()
			row.box:SetText(c.arg or "")
			row.box:Show()
		else
			row.paramDrop:Hide()
			row.box:Hide()
		end
		row.drop:Refresh()
	end

	-- the action ---------------------------------------------------------------
	local ACTION_Y = COND_TOP + Smart.MAX_CONDS * COND_STEP - 4
	local actionLabel = Config.NewLabel(page, RIGHT_X, ACTION_Y, L["Then"])
	local actionItems = {}
	local otherwiseItems = {}
	for _, item in ipairs(Smart.ACTIONS) do
		otherwiseItems[#otherwiseItems + 1] = item
		if item.value ~= "none" then actionItems[#actionItems + 1] = item end
	end
	local kindItems = {} -- the list the dropdown reads: a rule has no "Nothing", the otherwise has
	local function FillKindItems()
		for i = #kindItems, 1, -1 do kindItems[i] = nil end
		for _, item in ipairs(S.sel == 0 and otherwiseItems or actionItems) do kindItems[#kindItems + 1] = item end
	end
	FillKindItems()
	local kindDrop = Config.NewDropdown(page, RIGHT_X, ACTION_Y - 18, 96, kindItems,
		function() return S.kind end,
		function(value) S.kind = value; S.notice = nil; SyncAction(); UpdateStatus() end)

	local ACTION_X = RIGHT_X + 150
	local spellBox = CreateFrame("EditBox", Config.UniqueName("ClickwiseSmartSpell"), page, "InputBoxTemplate")
	spellBox:SetPoint("TOPLEFT", page, "TOPLEFT", ACTION_X + 6, ACTION_Y - 20)
	spellBox:SetSize(176, 20)
	spellBox:SetAutoFocus(false)
	spellBox:SetMaxLetters(60)
	spellBox:SetScript("OnEscapePressed", spellBox.ClearFocus)
	spellBox:SetScript("OnEnterPressed", spellBox.ClearFocus)
	spellBox:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			S.spell = Smart.Trim(self:GetText())
			S.notice = nil
			UpdateStatus()
		end
	end)
	local groupItems = {}
	for _, group in ipairs(CW.BuffGroups) do groupItems[#groupItems + 1] = {value = group.key, label = group.label} end
	local groupDrop = Config.NewDropdown(page, ACTION_X, ACTION_Y - 18, 130, groupItems,
		function() return S.group end,
		function(value) S.group = value; S.notice = nil; UpdateStatus() end)
	local tauntNote = Config.NewLabel(page, ACTION_X, ACTION_Y - 22, L["at the enemy the unit is targeting"], "GameFontHighlightSmall")
	tauntNote:SetWidth(632 - ACTION_X - 4)

	function SyncAction()
		FillKindItems()
		kindDrop:Invalidate()
		kindDrop:Refresh()
		if S.kind == "spell" then spellBox:Show() else spellBox:Hide() end
		if S.kind == "buff" then groupDrop:Show() else groupDrop:Hide() end
		if S.kind == "taunt" then tauntNote:Show() else tauntNote:Hide() end
		spellBox:SetText(S.spell or "")
		groupDrop:Refresh()
	end

	-- save / new -----------------------------------------------------------------
	local BUTTON_Y = ACTION_Y - 52
	local function CurrentAction()
		local action = {type = S.kind}
		if S.kind == "spell" then action.spell = Config.ResolveSpellName(S.spell or "") end
		if S.kind == "buff" then action.group = S.group end
		return action
	end

	local saveButton = Config.NewButton(page, RIGHT_X, BUTTON_Y, 120, L["Save rule"], function()
		if not S.set then Notice(L["Make or pick a rule set first."]) UpdateStatus() return end
		local action = CurrentAction()
		if action.type == "spell" and (S.spell or "") == "" then Notice(L["Type a spell name."]) UpdateStatus() return end
		if S.sel == 0 then
			Smart:SetOtherwise(S.set, action)
			S.notice = nil
		else
			local rule = {mode = S.mode, conds = S.conds, action = action}
			for _, c in ipairs(S.conds) do
				local def = COND[c.key]
				if def and def.arg and (c.arg == nil or c.arg == "") then
					Notice((L["Give the condition a value: %s"]):format(Smart.Cap(def.text)))
					UpdateStatus()
					return
				end
			end
			local index, err = Smart:SaveRule(S.set, S.sel, rule)
			if not index then
				Notice(err)
			else
				LoadRule(index)
				S.notice = nil
			end
		end
		SyncForm()
	end)
	Config.NewButton(page, RIGHT_X + 126, BUTTON_Y, 100, L["New rule"], function()
		if not S.set then return end
		LoadRule(nil)
		S.notice = nil
		SyncForm()
	end)

	local status = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", page, "TOPLEFT", RIGHT_X, BUTTON_Y - 32)
	status:SetWidth(632 - RIGHT_X)
	status:SetJustifyH("LEFT")
	status:SetJustifyV("TOP")

	-- the rule as it stands in the form
	local function FormRule()
		local rule = {mode = S.mode, conds = {}, action = CurrentAction()}
		for _, c in ipairs(S.conds) do
			if c.key and COND[c.key] then rule.conds[#rule.conds + 1] = {key = c.key, arg = c.arg, neg = c.neg} end
		end
		return rule
	end

	-- your own frame: the set compiled for it, as the click would get it
	local function OwnFrame()
		for btn in pairs(CW.UnitFrame.frames) do
			if btn.unit == "player" then return btn end
		end
	end

	function UpdateStatus()
		local lines = {}
		if S.notice then lines[#lines + 1] = "|cffff7070" .. S.notice .. "|r" end
		local set = Smart:GetSet(S.set)
		if not set then
			lines[#lines + 1] = L["Type a name and press New set. Then add rules; a click runs the set once you pick 'Smart set' as its action on the Bindings tab."]
			status:SetText(concat(lines, "\n"))
			return
		end
		if S.sel == 0 then
			lines[#lines + 1] = L["Otherwise"] .. ": " .. Smart.ActionText(CurrentAction().type ~= "none" and CurrentAction() or nil)
			lines[#lines + 1] = L["Used when no rule above holds. 'Nothing' leaves the click to whatever else is on it."]
		else
			local rule = FormRule()
			lines[#lines + 1] = (S.sel and (S.sel .. ". ") or L["New rule"] .. ": ") .. Smart.RuleText(rule)
			for _, c in ipairs(rule.conds) do
				local def = COND[c.key]
				if def.kind == "volatile" then
					lines[#lines + 1] = "|cffffcc00" .. L["Auras are read when the click is written, so a rule that looks at them is skipped in combat."] .. "|r"
					break
				end
			end
			if rule.action.type == "taunt" then
				for _, c in ipairs(rule.conds) do
					if COND[c.key].unit then
						lines[#lines + 1] = "|cffff7070" .. L["a taunt aims at the enemy, so a test of the unit itself (dead) cannot share its rule"] .. "|r"
						break
					end
				end
			end
		end
		local action = CurrentAction()
		if action.type == "spell" and action.spell ~= "" and not CW.KnowsSpell(action.spell) then
			lines[#lines + 1] = "|cffffcc00" .. L["Not in your spellbook - a rule for it is left out until you learn it."] .. "|r"
		end
		if #Smart:BindingsUsing(S.set) == 0 then
			lines[#lines + 1] = L["No binding runs this set yet: pick 'Smart set' as the Action on the Bindings tab."]
		end
		local btn = OwnFrame()
		if btn then
			local clauses = Smart:Compile(btn, S.set, Smart.BUDGET)
			if #clauses > 0 then
				local text = "/cast " .. concat(clauses, "; ")
				lines[#lines + 1] = (L["For your own frame (%d / %d characters):"]):format(#text, Smart.MACRO_LIMIT)
				lines[#lines + 1] = text
			else
				lines[#lines + 1] = L["Nothing in this set applies to your own frame right now."]
			end
		end
		if InCombatLockdown() then lines[#lines + 1] = L["In combat: changes apply when combat ends."] end
		status:SetText(concat(lines, "\n"))
	end

	function SyncForm()
		FillSetItems()
		setDrop:Invalidate()
		setDrop:Refresh()
		local set = Smart:GetSet(S.set)
		local editing = S.sel == 0
		modeButton:SetText(MODE_TEXT[S.mode] or MODE_TEXT.all)
		for i = 1, Smart.MAX_CONDS do
			SyncRow(i)
			local row = condRows[i]
			if editing or not set then
				row.check:Hide(); row.drop:Hide(); row.paramDrop:Hide(); row.box:Hide()
			else
				row.check:Show(); row.drop:Show()
			end
		end
		if editing or not set then modeButton:Hide(); ruleLabel:Hide() else modeButton:Show(); ruleLabel:Show() end
		SyncAction()
		saveButton:SetText(editing and L["Save otherwise"] or L["Save rule"])
		UpdateList()
		UpdateStatus()
	end

	function page:OnRefresh()
		local names = Smart:SetNames()
		local found = false
		for _, name in ipairs(names) do
			if name == S.set then found = true end
		end
		if not found then
			S.set = names[1]
			LoadRule(nil)
		end
		SyncForm()
	end

	page.cwState, page.cwRows, page.cwOtherRow, page.cwCondRows = S, rows, otherRow, condRows
	page.cwSetDrop, page.cwKindDrop, page.cwGroupDrop, page.cwNameBox, page.cwSpellBox = setDrop, kindDrop, groupDrop, nameBox, spellBox
	page.cwModeButton, page.cwSaveButton, page.cwStatus = modeButton, saveButton, status
end

Config.builders.smart = Build
