-- Clickwise core: addon object, saved variables, combat-deferral queue, group-type
-- tracking and slash commands. WotLK 3.3.5 only.

local CW = Clickwise
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

LibStub("AceAddon-3.0"):NewAddon(CW, "Clickwise", "AceEvent-3.0", "AceConsole-3.0")

local InCombatLockdown = InCombatLockdown
local pairs, select, unpack, tonumber, tostring = pairs, select, unpack, tonumber, tostring

local defaults = {
	profile = {
		locked = true,
		scale = 1,
		position = {}, -- x/y = absolute top-left in screen units; empty = default anchor (see Frames.lua)
		horizontal = false, -- false: units stack top-to-bottom, groups sit side by side
		frame = {
			width = 84,
			height = 34,
			spacing = 2,
			groupSpacing = 6,
			texture = "Blizzard",
			fontSize = 10,
			classColor = true,
			showPets = true,
			showRoleIcon = true,
			healthText = "DEFICIT", -- NONE | DEFICIT | PERCENT
		},
		range = {
			enabled = true,
			alpha = 0.4,
			interval = 0.4,
		},
		-- Health bar colors while the player is in combat (CombatColor.lua).
		-- mode: AUTO (the player's role decides: tank = threat, otherwise health) | HEALTH | THREAT | OFF
		combatColor = {
			mode = "AUTO",
			yellow = 50, -- health: yellow at or below this percentage
			red = 20, -- health: red below this percentage
			threat = 80, -- threat: yellow once a unit is this far (percent) toward pulling the enemy
		},
		healPred = {
			enabled = true,
			includeOwn = true,
			timeFrame = 4, -- only count heals landing within this many seconds
			color = {r = 0.1, g = 0.9, b = 0.3, a = 0.55},
		},
		-- bindings[CLASS] = user-defined list; a missing class entry = use the class template
		-- from Templates.lua. Keyed by class because profiles are shared between characters.
		bindings = {},
		-- Buff tracking (Buffs.lua). classes[CLASS][GROUP] = {enabled = bool|nil, order = {spell names}|nil};
		-- an absent entry means "defaults from BuffData.lua". Keyed by class like bindings.
		buffs = {
			enabled = true,
			showSatisfied = false, -- also draw already-buffed groups, dimmed
			expireWarn = 30, -- seconds before one of the player's own buffs runs out that its icon starts pulsing; 0 = off
			classes = {},
		},
	},
}
CW.defaults = defaults

--------------------------------------------------------------------------------
-- Combat deferral queue.
-- Secure frames cannot have attributes changed, be shown/hidden, or be resized while in
-- combat lockdown. Anything that touches them goes through RunOOC: it runs immediately
-- out of combat, otherwise it is queued (latest call per key wins) and flushed when
-- combat ends.
--------------------------------------------------------------------------------
local queue, order = {}, {}

function CW:RunOOC(key, func, ...)
	if not InCombatLockdown() then
		CW.Try(func, ...)
		return true
	end
	if not queue[key] then
		order[#order + 1] = key
	end
	queue[key] = {func = func, n = select("#", ...), ...}
	return false
end

function CW:HasQueued()
	return #order > 0
end

function CW:FlushQueue()
	if #order == 0 then return end
	local keys, jobs = order, queue
	order, queue = {}, {}
	for i = 1, #keys do
		local job = jobs[keys[i]]
		if job then
			CW.Try(job.func, unpack(job, 1, job.n))
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
function CW:OnInitialize()
	if not CW.isSupportedClient then
		-- Keep every module off; this addon is strictly 3.3.5.
		for _, module in self:IterateModules() do
			module:SetEnabledState(false)
		end
		self:Print((L["Only WotLK 3.3.5 is supported (this client reports interface %s). Clickwise is disabled."]):format(tostring(CW.tocVersion)))
		return
	end

	self.db = LibStub("AceDB-3.0"):New("ClickwiseDB", defaults, true)
	self.db.RegisterCallback(self, "OnProfileChanged", "RefreshProfile")
	self.db.RegisterCallback(self, "OnProfileCopied", "RefreshProfile")
	self.db.RegisterCallback(self, "OnProfileReset", "RefreshProfile")

	self:RegisterChatCommand("clickwise", "SlashCommand")
	self:RegisterChatCommand("cw", "SlashCommand")
end

function CW:OnEnable()
	if not CW.isSupportedClient then return end

	CW.RebuildSpellbook()
	self:RegisterEvent("SPELLS_CHANGED", "OnSpellsChanged")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnRegenEnabled")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "UpdateGroupType")
	self:RegisterEvent("PARTY_MEMBERS_CHANGED", "UpdateGroupType")
	self:RegisterEvent("RAID_ROSTER_UPDATE", "UpdateGroupType")
	self:UpdateGroupType()
end

function CW:OnSpellsChanged()
	CW.RebuildSpellbook()
	self:SendMessage("CLICKWISE_SPELLS_CHANGED")
end

function CW:OnRegenEnabled()
	self:FlushQueue()
end

--------------------------------------------------------------------------------
-- Group type ("solo" / "party" / "raid")
--------------------------------------------------------------------------------
function CW:UpdateGroupType()
	local groupType = CW.GetGroupType()
	if groupType ~= self.groupType then
		self.groupType = groupType
		self:SendMessage("CLICKWISE_GROUP_TYPE", groupType)
	end
	self:SendMessage("CLICKWISE_ROSTER")
end

--------------------------------------------------------------------------------
-- Settings refresh.
-- CLICKWISE_SETTINGS: a look/layout option changed (cheap, does not touch bindings).
-- CLICKWISE_PROFILE:  the whole profile changed, so bindings must be re-applied too.
--------------------------------------------------------------------------------
function CW:RefreshProfile()
	self:SendMessage("CLICKWISE_PROFILE")
	self:RefreshAll()
end

function CW:RefreshAll()
	self:SendMessage("CLICKWISE_SETTINGS")
	if InCombatLockdown() then
		self:Print(L["Changes will apply when combat ends."])
	end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
local function parseBindingKey(key)
	-- "shift-1", "ctrl-alt-2", "3" -> canonical modifier prefix + button, or nil
	if not key then return nil end
	key = key:lower()
	local alt, ctrl, shift = false, false, false
	while true do
		local mod, rest = key:match("^(%a+)%-(.+)$")
		if not mod then break end
		if mod == "alt" then alt = true
		elseif mod == "ctrl" then ctrl = true
		elseif mod == "shift" then shift = true
		else return nil end
		key = rest
	end
	local button = tonumber(key)
	if not button or button < 1 or button > 5 or button ~= math.floor(button) then
		return nil
	end
	return CW.MakeModifier(alt, ctrl, shift), tostring(button)
end

function CW:SlashCommand(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()

	if cmd == "lock" then
		self:GetModule("Frames"):SetLocked(true)
	elseif cmd == "unlock" then
		self:GetModule("Frames"):SetLocked(false)
	elseif cmd == "reset" then
		self:GetModule("Frames"):ResetPosition()
		self:Print(L["Position reset."])
	elseif cmd == "bind" then
		local key, spell = rest:match("^(%S+)%s+(.+)$")
		local modifier, button = parseBindingKey(key)
		if not modifier or not spell then
			self:Print(L["Usage: /cw bind <[alt-][ctrl-][shift-]button> <spell name>   (button = 1-5)"])
			return
		end
		self:GetModule("ClickCast"):SetBinding(modifier, button, spell)
		self:Print((L["Bound %s to %s."]):format(key, spell))
	elseif cmd == "unbind" then
		local modifier, button = parseBindingKey(rest)
		if not modifier then
			self:Print(L["Usage: /cw unbind <[alt-][ctrl-][shift-]button>"])
			return
		end
		if self:GetModule("ClickCast"):RemoveBinding(modifier, button) then
			self:Print((L["Removed binding %s."]):format(rest))
		else
			self:Print((L["No binding found for %s."]):format(rest))
		end
	elseif cmd == "binds" or cmd == "bindings" then
		for _, line in pairs(self:GetModule("ClickCast"):DescribeBindings()) do
			self:Print(line)
		end
	elseif cmd == "resetbinds" then
		self:GetModule("ClickCast"):ResetBindings()
		local _, class = UnitClass("player")
		self:Print((L["Bindings reset to the %s class template."]):format(class or "?"))
	elseif cmd == "buffs" then
		-- debugging aid: a unit's role / combat state / matched rule, then its helpful auras with caster and buff group
		for _, line in ipairs(CW.Buffs:DumpUnit(rest ~= "" and rest or "target")) do
			self:Print(line)
		end
	elseif cmd == "buffcheck" then
		-- debugging aid: verify the buff spell IDs in BuffData.lua against this client
		self:Print(CW.Buffs:CheckMacroSupport())
		for _, line in ipairs(CW.Buffs:CheckData()) do
			self:Print(line)
		end
	elseif cmd == "options" then
		local panel = self.optionsPanel
		if panel then
			-- Called twice on purpose: known 3.3.5 quirk where the first call only opens the frame.
			InterfaceOptionsFrame_OpenToCategory(panel)
			InterfaceOptionsFrame_OpenToCategory(panel)
		end
	elseif cmd == "config" or cmd == "" then
		if not self.db then return end
		if CW.Config then
			CW.Config:Toggle()
		else
			-- Config.lua is listed in the .toc but was not loaded: the client only reads the
			-- .toc file list at launch, so a full game restart (not /reload) is needed.
			self:Print("Settings window files were not loaded. Fully restart the game client (a /reload is not enough after files are added to the .toc).")
		end
	else
		self:Print("/cw [config] | lock | unlock | reset | binds | bind <key> <spell> | unbind <key> | resetbinds | buffs [unit] | buffcheck")
	end
end
