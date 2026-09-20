-- Buffs tab of the settings window.
--
--   top   : master switches (track missing buffs, also show satisfied ones dimmed)
--   left  : the buff groups this character can cast (a known spell in the group), each with an
--           on/off checkbox; click a row to select it
--   right : for the selected group, its spells the player knows in priority order with Up/Down
--           buttons. The top spell is what a "Buff group" binding casts (see the Bindings tab).
--
-- All changes go through CW.Buffs, which tells the icons and the click bindings to refresh.

local CW = Clickwise
local Config = CW.Config
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local ipairs = ipairs

local ROW_H = 24
local MAX_ROWS = 12
local SPELL_ROWS = 4
local FORM_X = 330
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Region:SetShown does not exist on 3.3.5
local function SetShown(widget, show)
	if show then widget:Show() else widget:Hide() end
end

local function SpellIcon(name)
	local _, _, icon = GetSpellInfo(name)
	return icon or QUESTION_MARK
end

local function Build(page)
	local Buffs = CW.Buffs
	local S = {key = nil}
	local groups = {} -- groups the player can cast, in data order
	local Refresh, RefreshRight

	Config.NewCheck(page, 4, -8, L["Show missing buffs on the frames"], {"buffs", "enabled"})
	Config.NewCheck(page, 320, -8, L["Also show buffs that are already up (dimmed)"], {"buffs", "showSatisfied"})

	----------------------------------------------------------------------------
	-- Left column: groups
	----------------------------------------------------------------------------
	Config.NewLabel(page, 0, -46, L["Buff groups you can cast"], "GameFontNormal")
	local empty = Config.NewLabel(page, 0, -72, L["Your class has no buff spells Clickwise can track yet."], "GameFontHighlightSmall")
	empty:SetWidth(300)

	local rows = {}
	for i = 1, MAX_ROWS do
		local row = CreateFrame("Button", nil, page)
		row:SetSize(300, ROW_H)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -68 - (i - 1) * ROW_H)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints(row)
		CW.SetSolidColor(row.sel, 0.2, 0.5, 1, 0.25)
		row.sel:Hide()

		local checkName = Config.UniqueName("ClickwiseBuffGroupCheck")
		row.check = CreateFrame("CheckButton", checkName, row, "InterfaceOptionsCheckButtonTemplate")
		row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
		row.check:SetHitRectInsets(0, 0, 0, 0) -- the template's hit area otherwise covers the whole row
		_G[checkName .. "Text"]:SetText("")
		row.check:SetScript("OnClick", function(self)
			if row.key then
				Buffs:SetGroupEnabled(row.key, self:GetChecked() and true or false)
				Refresh()
			end
		end)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", row, "LEFT", 32, 0)
		row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.text:SetJustifyH("LEFT")

		row:SetScript("OnClick", function()
			if row.key then
				S.key = row.key
				Refresh()
			end
		end)
		rows[i] = row
	end

	----------------------------------------------------------------------------
	-- Right column: priority of the selected group
	----------------------------------------------------------------------------
	local title = Config.NewLabel(page, FORM_X, -46, "", "GameFontNormal")
	local hint = Config.NewLabel(page, FORM_X, -68,
		L["Priority, highest first. A click bound to this group casts the first spell you know."], "GameFontHighlightSmall")
	hint:SetWidth(290)

	local spellRows = {}
	for i = 1, SPELL_ROWS do
		local y = -108 - (i - 1) * 28
		local r = {}
		r.icon = page:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(20, 20)
		r.icon:SetPoint("TOPLEFT", page, "TOPLEFT", FORM_X, y)
		r.text = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
		r.text:SetWidth(150)
		r.text:SetJustifyH("LEFT")
		r.up = Config.NewButton(page, FORM_X + 190, y + 1, 44, L["Up"], function()
			if S.key and r.spell and Buffs:MoveSpell(S.key, r.spell, -1) then Refresh() end
		end)
		r.down = Config.NewButton(page, FORM_X + 238, y + 1, 54, L["Down"], function()
			if S.key and r.spell and Buffs:MoveSpell(S.key, r.spell, 1) then Refresh() end
		end)
		spellRows[i] = r
	end

	local casts = Config.NewLabel(page, FORM_X, -232, "", "GameFontHighlightSmall")
	casts:SetWidth(290)
	local resetButton = Config.NewButton(page, FORM_X, -262, 180, L["Reset this group"], function()
		if S.key then
			Buffs:ResetGroup(S.key)
			Refresh()
		end
	end)
	local bindNote = Config.NewLabel(page, FORM_X, -300,
		L["To cast a buff with a click, add a binding in the Bindings tab with the action 'Buff group'."], "GameFontHighlightSmall")
	bindNote:SetWidth(290)

	-- one setting for every group, so it is not tied to the selected row
	Config.NewSlider(page, FORM_X, -372, L["Warn before a buff runs out (seconds)"], {"buffs", "expireWarn"}, 0, 300, 5, "%d", 290)
	local warnNote = Config.NewLabel(page, FORM_X, -398,
		L["A buff you cast pulses on the frame, faster as it runs out, and is solid once it is gone. 0 turns the warning off."],
		"GameFontHighlightSmall")
	warnNote:SetWidth(290)

	function RefreshRight()
		local group = S.key and Buffs:GetGroup(S.key)
		local show = group ~= nil
		title:SetText(show and (group.selfOnly and (L["%s (only on you)"]):format(group.label) or group.label) or "")
		SetShown(hint, show)
		SetShown(casts, show)
		SetShown(bindNote, show)
		SetShown(resetButton, show)

		local known = show and Buffs:GetKnownOrder(S.key) or {}
		for i = 1, SPELL_ROWS do
			local r, name = spellRows[i], known[i]
			if name then
				r.spell = name
				r.icon:SetTexture(SpellIcon(name))
				r.text:SetText(name)
				r.icon:Show()
				r.text:Show()
				r.up:Show()
				r.down:Show()
				if i == 1 then r.up:Disable() else r.up:Enable() end
				if i == #known then r.down:Disable() else r.down:Enable() end
			else
				r.spell = nil
				r.icon:Hide()
				r.text:Hide()
				r.up:Hide()
				r.down:Hide()
			end
		end
		if show then
			local cast = Buffs:GetCastSpell(S.key)
			casts:SetText(cast and ((L["A click casts: %s"]):format(cast)) or "")
		end
	end

	function Refresh()
		groups = {}
		for _, g in ipairs(Buffs:GetGroups()) do
			if Buffs:IsAvailable(g.key) then groups[#groups + 1] = g end
		end

		local valid = false
		for _, g in ipairs(groups) do
			if g.key == S.key then valid = true end
		end
		if not valid then S.key = groups[1] and groups[1].key or nil end

		for i = 1, MAX_ROWS do
			local row, g = rows[i], groups[i]
			if g then
				row.key = g.key
				row.check:SetChecked(Buffs:IsGroupEnabled(g.key))
				row.icon:SetTexture(SpellIcon(Buffs:GetCastSpell(g.key)))
				row.text:SetText(g.label)
				if g.key == S.key then row.sel:Show() else row.sel:Hide() end
				row:Show()
			else
				row.key = nil
				row:Hide()
			end
		end
		if #groups == 0 then empty:Show() else empty:Hide() end
		RefreshRight()
	end

	function page:OnRefresh()
		Refresh()
	end
end

Config.builders.buffs = Build
