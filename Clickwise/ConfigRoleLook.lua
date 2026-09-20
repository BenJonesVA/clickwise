-- Role look tab of the settings window.
--
-- A role can have a look of its own: while you play that role and its look is on, the frame size, the incoming
-- heal prediction, the debuff icon and the threat bar come from here instead of from the General and Layout tabs
-- (CW:Look in Core.lua). One column per role; the values are stored in profile.roleLook[ROLE].

local CW = Clickwise
local Config = CW.Config
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

local ipairs = ipairs

local COLUMN = 214

-- (the tab follows a change made here or by the game while the window is open: a new role, a profile switch, which
-- brings the other profile's values. A stale slider would write its old number into the new profile when dragged.)
local listener = {}
LibStub("AceEvent-3.0"):Embed(listener)

local function Build(page)
	local note = Config.NewLabel(page, 0, -8,
		L["A role can have a look of its own. While you play it and its look is on, the frame size, heal prediction, debuff icon and threat bar below replace the ones on the General and Layout tabs. Everything else is shared by every role."],
		"GameFontHighlightSmall")
	note:SetWidth(620)

	local ROLE_NAMES = {TANK = L["Tank"], HEALER = L["Healer"], DAMAGER = L["Damage"]}
	local labels = {}
	for i, role in ipairs(CW.ROLES) do
		local x = (i - 1) * COLUMN
		local function path(name) return {"roleLook", role, name} end
		labels[role] = Config.NewLabel(page, x + 4, -56, ROLE_NAMES[role])
		Config.NewCheck(page, x, -78, L["Use this look"], path("enabled"))
		Config.NewSlider(page, x + 4, -134, L["Frame width"], path("width"), 40, 160, 1, "%d", 190)
		Config.NewSlider(page, x + 4, -194, L["Frame height"], path("height"), 20, 80, 1, "%d", 190)
		Config.NewCheck(page, x, -250, L["Incoming heal prediction"], path("healPred"))
		Config.NewCheck(page, x, -278, L["Show the debuff icon"], path("debuffIcon"))
		Config.NewCheck(page, x, -306, L["Threat bar"], path("threatBar"))
		Config.NewCheck(page, x, -334, L["Threat bar on tanks too"], path("threatBarTanks"))
	end

	local status = Config.NewLabel(page, 0, -378, "", "GameFontHighlight")
	status:SetWidth(620)
	page.cwRoleNames, page.cwLookStatus = labels, status

	function page:OnRefresh()
		local playing = CW.GetUnitRole("player")
		for _, role in ipairs(CW.ROLES) do
			labels[role]:SetText(ROLE_NAMES[role] .. (playing == role and " *" or ""))
		end
		if not playing then
			status:SetText(L["Your role is not known yet, so the General and Layout settings are used."])
		elseif CW:LookRole() then
			status:SetText((L["You play %s: its look is on."]):format(ROLE_NAMES[playing]))
		else
			status:SetText((L["You play %s: its look is off, the General and Layout settings are used."]):format(ROLE_NAMES[playing]))
		end
	end
	listener:RegisterMessage("CLICKWISE_SETTINGS", function()
		if page:IsShown() then Config:RefreshPage() end
	end)
end

Config.builders.rolelook = Build
