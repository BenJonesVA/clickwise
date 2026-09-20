-- Interface Options entry. The real settings live in the standalone window (Config.lua);
-- this page only points to it, because the Interface Options panel is too narrow for the
-- sliders and the binding editor.

local CW = Clickwise
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local panel = CreateFrame("Frame", "ClickwiseOptionsPanel", UIParent)
panel.name = "Clickwise"
CW.optionsPanel = panel

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Clickwise")

local blurb = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
blurb:SetWidth(380)
blurb:SetJustifyH("LEFT")
blurb:SetText(L["Clickwise now has its own settings window with tabs for General, Layout, Bindings and Buffs."] ..
	"\n\n" .. L["You can also open it any time with /cw."])

local open = CreateFrame("Button", "ClickwiseOptionsOpenButton", panel, "UIPanelButtonTemplate")
open:SetSize(200, 26)
open:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -20)
open:SetText(L["Open Clickwise settings"])
open:SetScript("OnClick", function()
	if not (CW.db and CW.Config) then return end
	HideUIPanel(InterfaceOptionsFrame)
	HideUIPanel(GameMenuFrame)
	CW.Config:Open()
end)

InterfaceOptions_AddCategory(panel)
