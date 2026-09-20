-- Bindings tab of the settings window.
--
--   left  : list of this character's effective bindings (class template until edited, then a
--           per-class custom list) with Reset-to-template
--   right : editor form -- modifiers, mouse button, action type, spell (typed or picked from a
--           searchable list of the spellbook) / macro text -- with Save / Remove / New
--
-- All edits go through CW.ClickCast, which defers secure-attribute changes until combat ends.

local CW = Clickwise
local Config = CW.Config
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local ipairs, tonumber, floor, tinsert = ipairs, tonumber, math.floor, table.insert
local strlower, strfind = string.lower, string.find

local ROW_H = 20
local LIST_ROWS = 13
local PICK_ROWS = 7
local FORM_X = 310 -- left edge of the editor column, relative to the page
local WHEN_BUTTON_W = 116 -- wide enough for "Out of combat" (the longest label) at the game's font size

local BUTTON_ITEMS = {
	{value = "1", label = L["Left click"]},
	{value = "2", label = L["Right click"]},
	{value = "3", label = L["Middle click"]},
	{value = "4", label = L["Button 4"]},
	{value = "5", label = L["Button 5"]},
}
local BUTTON_SHORT = {["1"] = L["Left"], ["2"] = L["Right"], ["3"] = L["Middle"], ["4"] = "Btn4", ["5"] = "Btn5"}

local KIND_ITEMS = {
	{value = "spell", label = L["Cast spell"]},
	{value = "buff", label = L["Buff group"]},
	{value = "assigned", label = L["Assigned buff"]},
	{value = "cure", label = L["Cure debuff"]},
	{value = "rez", label = L["Resurrect"]},
	{value = "taunt", label = L["Taunt"]},
	{value = "macro", label = L["Macro"]},
	{value = "target", label = L["Target unit"]},
	{value = "focus", label = L["Set focus"]},
	{value = "assist", label = L["Assist unit"]},
}
local KIND_LABEL = {}
for _, item in ipairs(KIND_ITEMS) do KIND_LABEL[item.value] = item.label end

-- When a casting binding fires (see ClickCast.lua). The order is the order the button cycles through.
local WHEN_ORDER = {"ANY", "OOC", "COMBAT"}
local WHEN_LABEL = {ANY = L["Any time"], OOC = L["Out of combat"], COMBAT = L["In combat"]}
local WHEN_TAG = {OOC = L["ooc"], COMBAT = L["combat"]} -- short marker in the binding list
local function IsCast(kind) return kind == "spell" or kind == "buff" or kind == "assigned" end
-- The `when` domain a binding of this kind lives in ("CURE" / "REZ" are the smart clicks' own, see ClickCast.lua).
local function WhenFor(kind, when)
	if kind == "cure" then return "CURE" end
	if kind == "rez" then return "REZ" end
	return IsCast(kind) and when or "ANY"
end

local function Trim(s)
	return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "alt-ctrl-shift-" -> "Alt+Ctrl+Shift+"
local function ModifierText(prefix)
	return ((prefix or ""):gsub("(%a+)%-", function(word)
		return word:sub(1, 1):upper() .. word:sub(2) .. "+"
	end))
end

local function KeyText(b)
	local tag = WHEN_TAG[CW.ClickCast.WhenOf(b)]
	return ModifierText(b.modifier) .. (BUTTON_SHORT[b.button] or "?") .. (tag and (" (" .. tag .. ")") or "")
end

local function ActionText(b)
	if b.type == "spell" then
		return b.spell .. (b.rank and (" (" .. b.rank .. ")") or "")
	elseif b.type == "assigned" then
		return L["Assigned buff"]
	elseif b.type == "buff" then
		local group = CW.Buffs:GetGroup(b.group)
		return L["Buff"] .. ": " .. (group and group.label or tostring(b.group))
	elseif b.type == "macro" then
		return L["Macro"] .. ": " .. ((b.macro or ""):match("[^\r\n]*"))
	elseif b.type == "taunt" then
		local spell = CW.ClickCast:TauntSpell()
		return L["Taunt"] .. (spell and (": " .. spell) or "")
	end
	return KIND_LABEL[b.type] or tostring(b.type)
end

local function SpellIcon(b)
	local spell = b.spell
	if b.type == "buff" then
		spell = CW.Buffs:GetCastSpell(b.group)
	end
	if spell and (b.type == "spell" or b.type == "buff") then
		local _, _, icon = GetSpellInfo(spell)
		return icon
	end
	return nil
end

-- Match typed text against the spellbook ignoring case, so "flash heal" becomes "Flash Heal".
local function ResolveSpellName(text)
	if CW.knownSpells[text] then return text end
	local lower = strlower(text)
	for _, name in ipairs(CW.spellList) do
		if strlower(name) == lower then return name end
	end
	return text
end

local function Build(page)
	local ClickCast = CW.ClickCast
	local S = {alt = false, ctrl = false, shift = false, button = "1", kind = "spell", selectedKey = nil,
		group = CW.BuffGroups[1].key, when = "ANY", whenChosen = false}
	local data = {} -- sorted bindings currently shown in the list
	local filtered = {} -- spell picker contents

	local UpdateList, UpdatePicker, UpdateStatus, SyncForm

	----------------------------------------------------------------------------
	-- Left column: binding list
	----------------------------------------------------------------------------
	local listTitle = Config.NewLabel(page, 0, -8, "", "GameFontNormal")

	local listScroll = CreateFrame("ScrollFrame", "ClickwiseBindListScroll", page, "FauxScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -30)
	listScroll:SetSize(262, LIST_ROWS * ROW_H)
	listScroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, UpdateList)
	end)

	local function WheelScroll(scrollName, delta)
		local bar = _G[scrollName .. "ScrollBar"]
		bar:SetValue(bar:GetValue() - delta * ROW_H * 2)
	end

	local function SortedBindings()
		local out = {}
		for _, b in ipairs(ClickCast:GetBindings()) do out[#out + 1] = b end
		table.sort(out, function(a, b)
			if a.button ~= b.button then return a.button < b.button end
			if (a.modifier or "") ~= (b.modifier or "") then return (a.modifier or "") < (b.modifier or "") end
			return ClickCast.WhenOf(a) < ClickCast.WhenOf(b)
		end)
		return out
	end

	-- one click can carry an "out of combat" and an "in combat" binding, so the key includes when
	local function BindingKey(b) return (b.modifier or "") .. b.button .. ":" .. ClickCast.WhenOf(b) end

	local rows = {}
	local function LoadForm(b) end -- forward; defined below
	for i = 1, LIST_ROWS do
		local row = CreateFrame("Button", nil, page)
		row:SetSize(262, ROW_H)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -30 - (i - 1) * ROW_H)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", function(_, delta) WheelScroll("ClickwiseBindListScroll", delta) end)
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints(row)
		CW.SetSolidColor(row.sel, 0.2, 0.5, 1, 0.25)
		row.sel:Hide()
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
		row.key = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.key:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.key:SetWidth(112)
		row.key:SetJustifyH("LEFT")
		row.action = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		row.action:SetPoint("LEFT", row.key, "RIGHT", 2, 0)
		row.action:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self)
			if self.binding then LoadForm(self.binding) end
		end)
		rows[i] = row
	end

	function UpdateList()
		data = SortedBindings()
		FauxScrollFrame_Update(listScroll, #data, LIST_ROWS, ROW_H)
		local offset = FauxScrollFrame_GetOffset(listScroll)
		for i = 1, LIST_ROWS do
			local row, b = rows[i], data[i + offset]
			if b then
				row.binding = b
				local icon = SpellIcon(b)
				if icon then
					row.icon:SetTexture(icon)
					row.icon:Show()
				else
					row.icon:Hide()
				end
				row.key:SetText(KeyText(b))
				row.action:SetText(CW.TruncateUTF8(ActionText(b), 20))
				if S.selectedKey == BindingKey(b) then row.sel:Show() else row.sel:Hide() end
				row:Show()
			else
				row.binding = nil
				row:Hide()
			end
		end
		local classLoc = UnitClass("player")
		listTitle:SetText((L["%s bindings"]):format(classLoc or "?") .. " - " ..
			(ClickCast:IsCustom() and L["custom"] or L["class template"]))
	end

	Config.NewButton(page, 0, -30 - LIST_ROWS * ROW_H - 10, 200, L["Reset to class template"], function()
		ClickCast:ResetBindings()
		S.selectedKey = nil
		UpdateList()
		UpdateStatus()
	end)
	local note = Config.NewLabel(page, 0, -30 - LIST_ROWS * ROW_H - 42,
		L["Left click = target and right click = unit menu unless you bind them here."], "GameFontHighlightSmall")
	note:SetWidth(262)

	----------------------------------------------------------------------------
	-- Right column: editor form
	----------------------------------------------------------------------------
	local function MakeCheck(x, y, label, onClick)
		local name = Config.UniqueName("ClickwiseBindCheck")
		local cb = CreateFrame("CheckButton", name, page, "InterfaceOptionsCheckButtonTemplate")
		cb:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
		local text = _G[name .. "Text"]
		text:SetText(label)
		-- The template's click area reaches 100 units past the box, which is wider than the gap between
		-- the modifier boxes: neighbours overlapped and the topmost one took the click. Cover just the
		-- box and its own label, and sit above anything else on the page.
		cb:SetHitRectInsets(0, -((text:GetStringWidth() or 30) + 4), 0, 0)
		cb:SetFrameLevel(page:GetFrameLevel() + 5)
		cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
		return cb
	end

	local function MakeEditBox(x, y, width, maxLetters, onChanged)
		local eb = CreateFrame("EditBox", Config.UniqueName("ClickwiseBindEdit"), page, "InputBoxTemplate")
		eb:SetPoint("TOPLEFT", page, "TOPLEFT", x + 6, y)
		eb:SetSize(width, 20)
		eb:SetAutoFocus(false)
		eb:SetMaxLetters(maxLetters)
		eb:SetScript("OnEscapePressed", eb.ClearFocus)
		eb:SetScript("OnEnterPressed", eb.ClearFocus)
		if onChanged then eb:SetScript("OnTextChanged", onChanged) end
		return eb
	end

	Config.NewLabel(page, FORM_X, -8, L["Modifiers"])
	local checkAlt = MakeCheck(FORM_X, -24, "Alt", function(v) S.alt = v; UpdateStatus() end)
	local checkCtrl = MakeCheck(FORM_X + 62, -24, "Ctrl", function(v) S.ctrl = v; UpdateStatus() end)
	local checkShift = MakeCheck(FORM_X + 124, -24, "Shift", function(v) S.shift = v; UpdateStatus() end)

	-- when the click fires: a button that cycles Any time > Out of combat > In combat (casts only)
	local whenLabel = Config.NewLabel(page, FORM_X + 196, -8, L["Cast when"])
	local whenButton
	local function SyncWhen()
		whenButton:SetText(WHEN_LABEL[S.when] or WHEN_LABEL.ANY)
		if IsCast(S.kind) then
			whenLabel:Show()
			whenButton:Show()
		else
			whenLabel:Hide()
			whenButton:Hide()
		end
	end
	whenButton = Config.NewButton(page, FORM_X + 196, -25, WHEN_BUTTON_W, WHEN_LABEL.ANY, function()
		local i = 1
		for idx, w in ipairs(WHEN_ORDER) do
			if w == S.when then i = idx end
		end
		S.when = WHEN_ORDER[i % #WHEN_ORDER + 1]
		S.whenChosen = true
		SyncWhen()
		UpdateStatus()
	end)

	Config.NewLabel(page, FORM_X, -60, L["Mouse button"])
	Config.NewDropdown(page, FORM_X, -76, 110, BUTTON_ITEMS,
		function() return S.button end,
		function(v) S.button = v; UpdateStatus() end)

	local kindLabel = Config.NewLabel(page, FORM_X + 150, -60, L["Action"])
	local function OnKindChanged() end -- replaced below once the sections exist
	Config.NewDropdown(page, FORM_X + 150, -76, 110, KIND_ITEMS,
		function() return S.kind end,
		function(v) S.kind = v; OnKindChanged(); UpdateStatus() end)

	-- spell section -----------------------------------------------------------
	local spellSection = {}
	spellSection[#spellSection + 1] = Config.NewLabel(page, FORM_X, -112, L["Spell name"])
	local spellBox = MakeEditBox(FORM_X, -128, 200, 60, function(_, userInput)
		if userInput then UpdateStatus() end
	end)
	spellSection[#spellSection + 1] = spellBox
	spellSection[#spellSection + 1] = Config.NewLabel(page, FORM_X + 216, -112, L["Rank (optional)"])
	local rankBox = MakeEditBox(FORM_X + 216, -128, 40, 2, function(_, userInput)
		if userInput then UpdateStatus() end
	end)
	rankBox:SetNumeric(true)
	spellSection[#spellSection + 1] = rankBox

	spellSection[#spellSection + 1] = Config.NewLabel(page, FORM_X, -158, L["Search your spellbook"], "GameFontHighlightSmall")
	local filterBox = MakeEditBox(FORM_X, -172, 200, 40, function(_, userInput)
		if userInput then UpdatePicker(true) end
	end)
	spellSection[#spellSection + 1] = filterBox

	local pickScroll = CreateFrame("ScrollFrame", "ClickwiseBindPickScroll", page, "FauxScrollFrameTemplate")
	pickScroll:SetPoint("TOPLEFT", page, "TOPLEFT", FORM_X, -198)
	pickScroll:SetSize(270, PICK_ROWS * ROW_H)
	pickScroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() UpdatePicker() end)
	end)
	spellSection[#spellSection + 1] = pickScroll

	local pickRows = {}
	for i = 1, PICK_ROWS do
		local row = CreateFrame("Button", nil, page)
		row:SetSize(270, ROW_H)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", FORM_X, -198 - (i - 1) * ROW_H)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", function(_, delta) WheelScroll("ClickwiseBindPickScroll", delta) end)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
		row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.text:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self)
			if self.spell then
				spellBox:SetText(self.spell)
				spellBox:ClearFocus()
				UpdateStatus()
			end
		end)
		pickRows[i] = row
		spellSection[#spellSection + 1] = row
	end

	function UpdatePicker(resetScroll)
		local text = strlower(Trim(filterBox:GetText()))
		filtered = {}
		for _, name in ipairs(CW.spellList) do
			if text == "" or strfind(strlower(name), text, 1, true) then
				filtered[#filtered + 1] = name
			end
		end
		if resetScroll then
			pickScroll:SetVerticalScroll(0)
		end
		FauxScrollFrame_Update(pickScroll, #filtered, PICK_ROWS, ROW_H)
		local offset = FauxScrollFrame_GetOffset(pickScroll)
		for i = 1, PICK_ROWS do
			local row, name = pickRows[i], filtered[i + offset]
			if name and S.kind == "spell" then
				row.spell = name
				local _, _, icon = GetSpellInfo(name)
				row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
				row.text:SetText(name)
				row:Show()
			else
				row.spell = nil
				row:Hide()
			end
		end
	end

	-- macro section -----------------------------------------------------------
	local macroSection = {}
	macroSection[#macroSection + 1] = Config.NewLabel(page, FORM_X, -112, L["Macro text (255 characters max)"])
	local macroFrame = CreateFrame("Frame", nil, page)
	macroFrame:SetPoint("TOPLEFT", page, "TOPLEFT", FORM_X, -130)
	macroFrame:SetSize(290, 150)
	macroFrame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = {left = 3, right = 3, top = 3, bottom = 3},
	})
	macroFrame:SetBackdropColor(0, 0, 0, 0.6)
	local macroBox = CreateFrame("EditBox", Config.UniqueName("ClickwiseBindMacro"), macroFrame)
	macroBox:SetPoint("TOPLEFT", macroFrame, "TOPLEFT", 8, -8)
	macroBox:SetPoint("BOTTOMRIGHT", macroFrame, "BOTTOMRIGHT", -8, 8)
	macroBox:SetMultiLine(true)
	macroBox:SetAutoFocus(false)
	macroBox:SetMaxLetters(255)
	macroBox:SetFontObject(ChatFontNormal)
	macroBox:SetScript("OnEscapePressed", macroBox.ClearFocus)
	macroBox:SetScript("OnTextChanged", function(_, userInput)
		if userInput then UpdateStatus() end
	end)
	macroSection[#macroSection + 1] = macroFrame
	macroSection[#macroSection + 1] = Config.NewLabel(page, FORM_X, -286,
		L["Tip: [target=mouseover] in a macro acts on the frame under the cursor."], "GameFontHighlightSmall")

	-- buff group section -------------------------------------------------------
	local buffSection = {}
	local buffItems = {}
	for _, group in ipairs(CW.BuffGroups) do
		buffItems[#buffItems + 1] = {value = group.key, label = group.label}
	end
	buffSection[#buffSection + 1] = Config.NewLabel(page, FORM_X, -112, L["Buff group"])
	buffSection[#buffSection + 1] = Config.NewDropdown(page, FORM_X, -128, 200, buffItems,
		function() return S.group end,
		function(v) S.group = v; UpdateStatus() end)
	buffSection[#buffSection + 1] = Config.NewLabel(page, FORM_X, -170,
		L["Casts your highest-priority known spell of the group. Set the priority in the Buffs tab."], "GameFontHighlightSmall")
	buffSection[#buffSection]:SetWidth(290)

	-- cure debuff section ---------------------------------------------------------
	local cureSection = {}
	cureSection[#cureSection + 1] = Config.NewLabel(page, FORM_X, -112,
		L["Casts the spell that removes the worst debuff the unit has that you can remove (Cleanse, Remove Curse, Dispel Magic...). Only while you are out of combat: in combat, and when there is nothing to remove, the click does your other binding on the same click."],
		"GameFontHighlightSmall")
	cureSection[#cureSection]:SetWidth(290)

	-- resurrect section ------------------------------------------------------------
	local rezSection = {}
	rezSection[#rezSection + 1] = Config.NewLabel(page, FORM_X, -112,
		L["Casts your resurrection on a dead or released member. Only while you are out of combat: on a living member, and in combat, the click does your other binding on the same click (a left click still targets)."],
		"GameFontHighlightSmall")
	rezSection[#rezSection]:SetWidth(290)

	-- taunt section ---------------------------------------------------------------
	local tauntSection = {}
	tauntSection[#tauntSection + 1] = Config.NewLabel(page, FORM_X, -112,
		L["Taunts the enemy this member is targeting, with your class's taunt (Taunt, Hand of Reckoning, Dark Command or Growl). Works in combat. A member with no enemy targeted: nothing happens."],
		"GameFontHighlightSmall")
	tauntSection[#tauntSection]:SetWidth(290)

	-- assigned buff section ------------------------------------------------------
	local assignedSection = {}
	assignedSection[#assignedSection + 1] = Config.NewLabel(page, FORM_X, -112,
		L["Casts the buff the Assignments tab picks for that unit: the first one in its list the unit does not already have. It starts as 'Out of combat'; change that with 'Cast when'."],
		"GameFontHighlightSmall")
	assignedSection[#assignedSection]:SetWidth(290)

	local function ShowSection(section, show)
		for _, widget in ipairs(section) do
			if show then widget:Show() else widget:Hide() end
		end
	end

	function OnKindChanged()
		ShowSection(spellSection, S.kind == "spell")
		ShowSection(macroSection, S.kind == "macro")
		ShowSection(buffSection, S.kind == "buff")
		ShowSection(assignedSection, S.kind == "assigned")
		ShowSection(cureSection, S.kind == "cure")
		ShowSection(rezSection, S.kind == "rez")
		ShowSection(tauntSection, S.kind == "taunt")
		-- an assigned buff is meant for out of combat (heals are what you want during the fight)
		if not S.whenChosen then
			S.when = (S.kind == "assigned") and "OOC" or "ANY"
		end
		SyncWhen()
		UpdatePicker(true)
	end

	-- status + buttons ----------------------------------------------------------
	local status = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", page, "TOPLEFT", FORM_X, -376)
	status:SetWidth(300)
	status:SetJustifyH("LEFT")
	status:SetJustifyV("TOP")

	local function CurrentModifier() return CW.MakeModifier(S.alt, S.ctrl, S.shift) end

	function UpdateStatus()
		local lines = {}
		local modifier = CurrentModifier()
		local when = WhenFor(S.kind, S.when)
		local key = modifier .. S.button .. ":" .. when

		-- what saving would replace: the bindings on this click that overlap in time (see ClickCast.lua)
		local editing = false
		for _, existing in ipairs(ClickCast:GetCollisions(modifier, S.button, when)) do
			if BindingKey(existing) == S.selectedKey and BindingKey(existing) == key then
				editing = true
			else
				lines[#lines + 1] = "|cffffcc00" .. (L["Replaces the existing binding: %s"]):format(ActionText(existing)) .. "|r"
			end
		end
		if editing then
			lines[#lines + 1] = L["Editing an existing binding."]
		end
		-- a gated click does nothing the rest of the time: point at the other half
		if when == "OOC" or when == "COMBAT" then
			local other = (when == "OOC") and "COMBAT" or "OOC"
			if not ClickCast:GetBinding(modifier, S.button, other) then
				lines[#lines + 1] = when == "OOC"
					and L["Only when neither you nor that player is fighting; this click does nothing in combat. Add an 'In combat' binding on the same click (a heal?)."]
					or L["Only when you or that player is fighting; this click does nothing out of combat. Add an 'Out of combat' binding on the same click (a buff?)."]
			end
		end
		if S.kind == "spell" then
			local text = Trim(spellBox:GetText())
			if text == "" then
				lines[#lines + 1] = "|cffff7070" .. L["Type or pick a spell."] .. "|r"
			else
				local resolved = ResolveSpellName(text)
				if not CW.KnowsSpell(resolved) then
					lines[#lines + 1] = "|cffffcc00" .. L["Not in your spellbook - it will still be saved."] .. "|r"
				elseif CW.spellRank[resolved] and CW.spellRank[resolved] ~= "" then
					lines[#lines + 1] = (L["Highest known rank: %s (blank rank = always the highest)"]):format(CW.spellRank[resolved])
				end
			end
		elseif S.kind == "buff" then
			local group = CW.Buffs:GetGroup(S.group)
			if group and not CW.Buffs:IsAvailable(S.group) then
				lines[#lines + 1] = "|cffffcc00" .. L["You do not know a spell of this group - the binding will do nothing until you do."] .. "|r"
			elseif group then
				lines[#lines + 1] = (L["Casts: %s"]):format(CW.Buffs:GetCastSpell(S.group) or "?")
			end
		elseif S.kind == "assigned" then
			if not CW.Buffs:HasRules() then
				lines[#lines + 1] = "|cffffcc00" .. L["No assignments yet - set them up in the Assignments tab."] .. "|r"
			end
		elseif S.kind == "cure" then
			local summary = CW.Debuffs and CW.Debuffs:CureSummary()
			if summary then
				lines[#lines + 1] = (L["Removes: %s"]):format(summary)
			else
				lines[#lines + 1] = "|cffffcc00" .. L["You know no spell that removes debuffs - this does nothing until you do."] .. "|r"
			end
			-- what the click does in combat and with nothing to remove
			local other = ClickCast:GetBinding(modifier, S.button, "COMBAT") or ClickCast:GetBinding(modifier, S.button, "ANY")
			if other then
				lines[#lines + 1] = (L["Otherwise this click: %s"]):format(ActionText(other))
			elseif S.button == "1" then
				lines[#lines + 1] = L["Otherwise this click targets the unit."]
			else
				lines[#lines + 1] = "|cffffcc00" .. L["Nothing else is bound to this click, so it does nothing in combat. Bind a heal on the same click."] .. "|r"
			end
		elseif S.kind == "rez" then
			local spell = CW.ClickCast:RezSpell()
			if spell then
				lines[#lines + 1] = (L["Casts: %s"]):format(spell)
			else
				lines[#lines + 1] = "|cffffcc00" .. L["You know no resurrection spell - this does nothing until you do."] .. "|r"
			end
			local other = ClickCast:GetBinding(modifier, S.button, "COMBAT") or ClickCast:GetBinding(modifier, S.button, "ANY")
			if other then
				lines[#lines + 1] = (L["Otherwise this click: %s"]):format(ActionText(other))
			elseif S.button == "1" then
				lines[#lines + 1] = L["Otherwise this click targets the unit."]
			end
		elseif S.kind == "taunt" then
			local spell = CW.ClickCast:TauntSpell()
			if spell then
				lines[#lines + 1] = (L["Casts: %s"]):format(spell)
			else
				lines[#lines + 1] = "|cffffcc00" .. L["You know no taunt spell - this does nothing until you do."] .. "|r"
			end
		elseif S.kind == "macro" and Trim(macroBox:GetText()) == "" then
			lines[#lines + 1] = "|cffff7070" .. L["Enter the macro text."] .. "|r"
		end
		if modifier == "" and (S.button == "1" or S.button == "2") and S.kind ~= "cure" and S.kind ~= "rez" then
			lines[#lines + 1] = "|cffffcc00" .. L["This overrides the built-in target / menu click."] .. "|r"
		end
		if InCombatLockdown() then
			lines[#lines + 1] = L["In combat: changes apply when combat ends."]
		end
		status:SetText(table.concat(lines, "\n"))
	end

	local function ClearForm()
		S.alt, S.ctrl, S.shift, S.button, S.kind, S.selectedKey = false, false, false, "1", "spell", nil
		S.group = CW.BuffGroups[1].key
		S.when, S.whenChosen = "ANY", false
		spellBox:SetText("")
		rankBox:SetText("")
		macroBox:SetText("")
		SyncForm()
		UpdateList()
	end

	function LoadForm(b)
		local modifier = b.modifier or ""
		S.alt = strfind(modifier, "alt-", 1, true) ~= nil
		S.ctrl = strfind(modifier, "ctrl-", 1, true) ~= nil
		S.shift = strfind(modifier, "shift-", 1, true) ~= nil
		S.button = b.button
		S.kind = b.type
		S.group = b.group or CW.BuffGroups[1].key
		S.when, S.whenChosen = (b.type == "cure" or b.type == "rez") and "ANY" or ClickCast.WhenOf(b), true
		S.selectedKey = BindingKey(b)
		spellBox:SetText(b.spell or "")
		rankBox:SetText(b.rank and (b.rank:match("%d+") or "") or "")
		macroBox:SetText(b.macro or "")
		SyncForm()
		UpdateList()
	end

	local function Save()
		local entry = {modifier = CurrentModifier(), button = S.button, type = S.kind}
		if IsCast(S.kind) then entry.when = S.when end
		if S.kind == "spell" then
			local text = Trim(spellBox:GetText())
			if text == "" then UpdateStatus() return end
			entry.spell = ResolveSpellName(text)
			local rank = tonumber(rankBox:GetText())
			if rank and rank >= 1 then entry.rank = "Rank " .. floor(rank) end
		elseif S.kind == "buff" then
			entry.group = S.group
		elseif S.kind == "macro" then
			local text = Trim(macroBox:GetText())
			if text == "" then UpdateStatus() return end
			entry.macro = text
		end
		ClickCast:SetBindingEntry(entry)
		S.selectedKey = BindingKey(entry)
		UpdateList()
		UpdateStatus()
	end

	local function Remove()
		local modifier = CurrentModifier()
		if ClickCast:RemoveBinding(modifier, S.button, WhenFor(S.kind, S.when)) then
			S.selectedKey = nil
			UpdateList()
		end
		UpdateStatus()
	end

	Config.NewButton(page, FORM_X, -348, 110, L["Save binding"], Save)
	Config.NewButton(page, FORM_X + 116, -348, 90, L["Remove"], Remove)
	Config.NewButton(page, FORM_X + 212, -348, 70, L["New"], ClearForm)

	-- refresh -------------------------------------------------------------------
	function SyncForm()
		checkAlt:SetChecked(S.alt)
		checkCtrl:SetChecked(S.ctrl)
		checkShift:SetChecked(S.shift)
		for _, control in ipairs(page.controls) do control:Refresh() end
		OnKindChanged()
		UpdateStatus()
	end

	function page:OnRefresh()
		UpdateList()
		UpdatePicker(true)
		SyncForm()
	end
end

Config.builders.bindings = Build
