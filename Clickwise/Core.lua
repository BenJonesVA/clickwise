-- Clickwise core: addon object, saved variables, combat-deferral queue, group-type
-- tracking and slash commands. WotLK 3.3.5 only.

local CW = Clickwise
local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")

LibStub("AceAddon-3.0"):NewAddon(CW, "Clickwise", "AceEvent-3.0", "AceConsole-3.0")

local InCombatLockdown = InCombatLockdown
local pairs, select, unpack, tonumber, tostring = pairs, select, unpack, tonumber, tostring

local defaults = {
	-- per character (not per profile): one profile for each talent spec, see CW:ApplySpecProfile
	char = {
		specProfiles = {enabled = false}, -- [1] / [2] = the profile the character uses in that talent spec
		roleProfiles = {enabled = false, role = "AUTO"}, -- TANK / HEALER / DAMAGER = the profile for that role; role = "My role" while it is on
	},
	profile = {
		-- the player's own role: AUTO (detected: assigned role, talents) or TANK | HEALER | DAMAGER set by hand.
		-- A paladin can be either; this is what the role-dependent parts (combat colors, the role icon, the
		-- assignment rules for "Self"'s role, the aggro rings) go by for the player's own frame.
		myRole = "AUTO",
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
			fontSize = 10, -- the health text (one smaller)
			nameFont = "", -- a LibSharedMedia font name; "" = the game's own font
			nameSize = 10,
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
		-- aggro border and threat bar (Threat.lua); the warning percentage is combatColor.threat
		threat = {
			border = true, -- a ring around a healer / damage dealer who has, or is about to take, the enemy
			bar = true,    -- a thin bar along the bottom edge: how far the unit is toward pulling
			barOnTanks = false, -- the bar also on the frames of tanks (else only on healers and damage dealers)
		},
		-- debuff highlight (Debuffs.lua)
		debuffs = {
			enabled = true,
			onlyMine = true, -- only debuffs the player can remove (else every typed debuff, the others darker)
			icon = true,     -- also show the debuff's icon in the frame's top-right corner
		},
		-- active defensives (Defensives.lua): the cooldowns that are up on a unit, in the middle of its frame
		defensives = {
			enabled = true,
		},
		-- Smart mode (Smart.lua): named rule sets per class, profile.smartSets[CLASS][name] = {rules = {...}, otherwise = action}
		smartSets = {},
		-- hover tooltip on the unit frames (UnitFrame.lua)
		tooltip = {
			mode = "DETAILED", -- DETAILED | BASIC (Blizzard's unit tooltip only) | OFF
			buffs = true,      -- DETAILED: buff status (who supplied it, time left)
			bindings = true,   -- DETAILED: what each click does with the modifier keys held right now
		},
		healPred = {
			enabled = true,
			includeOwn = true,
			timeFrame = 4, -- only count heals landing within this many seconds
			color = {r = 0.1, g = 0.9, b = 0.3, a = 0.55},
		},
		-- A look per role (see CW:Look): while the player plays that role and its look is on, these values stand in for
		-- the settings named in CW.LOOK_BASE. The other settings are shared by every role.
		roleLook = {
			TANK = {enabled = false, width = 72, height = 28, healPred = false, debuffIcon = true, threatBar = true, threatBarTanks = true},
			HEALER = {enabled = false, width = 96, height = 40, healPred = true, debuffIcon = true, threatBar = true, threatBarTanks = false},
			DAMAGER = {enabled = false, width = 72, height = 28, healPred = false, debuffIcon = true, threatBar = true, threatBarTanks = false},
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

	-- No default profile name: every character gets a profile of its own ("Name - Realm"), so one character's
	-- setup never changes another's. (Passing `true` would put every character on one shared "Default".)
	-- A character that already has a profile keeps it. The Profiles tab shares or copies one on purpose.
	self.db = LibStub("AceDB-3.0"):New("ClickwiseDB", defaults)
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
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
	self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "OnSpecChanged")
	self:RegisterEvent("PARTY_MEMBERS_CHANGED", "OnGroupChanged")
	self:RegisterEvent("RAID_ROSTER_UPDATE", "OnGroupChanged")
	-- what can change the role the player is playing (a dungeon finder role, a main tank assignment, the talents)
	self:RegisterEvent("PLAYER_ROLES_ASSIGNED", "OnRoleMayHaveChanged")
	self:RegisterEvent("PLAYER_TALENT_UPDATE", "OnRoleMayHaveChanged")
	local LGT = LibStub("LibGroupTalents-1.0", true)
	if LGT and LGT.RegisterCallback then
		LGT.RegisterCallback(self, "LibGroupTalents_RoleChange", "OnRoleMayHaveChanged")
	end
	self:UpdateGroupType()
	self:UpdateLookRole()
end

function CW:OnSpellsChanged()
	CW.RebuildSpellbook()
	self:SendMessage("CLICKWISE_SPELLS_CHANGED")
end

function CW:OnEnteringWorld()
	self:UpdateGroupType()
	self:OnSpecChanged()
end

function CW:OnGroupChanged()
	self:UpdateGroupType()
	self:OnRoleMayHaveChanged()
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
	self:UpdateLookRole() -- (the look is part of the profile: the new one may have another look for the role in play)
	self:RememberSpecProfile()
	self:RememberRoleProfile()
	self:SendMessage("CLICKWISE_PROFILE")
	self:RefreshAll()
end

-- The name AceDB gives this character's own profile.
function CW:CharKey()
	return UnitName("player") .. " - " .. GetRealmName()
end

-- The other characters that use profile `name` (sorted "Name - Realm" strings).
function CW:ProfileUsers(name)
	local out = {}
	local keys = self.db.sv and self.db.sv.profileKeys
	if keys then
		local me = self:CharKey()
		for char, profile in pairs(keys) do
			if profile == name and char ~= me then out[#out + 1] = char end
		end
	end
	table.sort(out)
	return out
end

-- Every profile name, sorted.
function CW:ProfileNames()
	local names = self.db:GetProfiles()
	table.sort(names)
	return names
end

-- Switch this character to profile `name` (created, with the default settings, if it is new).
function CW:UseProfile(name)
	name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return false end
	self.db:SetProfile(name)
	return true
end

--------------------------------------------------------------------------------
-- A profile per talent spec (a dual-spec paladin tanks in one spec and heals in the other).
-- char.specProfiles = {enabled, [1] = profile name, [2] = profile name}. While it is on, the profile the
-- character uses is remembered for the active spec (whatever way it was chosen), and a change of spec switches to
-- the profile of the new one. A spec with no profile yet keeps the current one and records it. A spec change
-- cannot happen in combat, but the game can be entered in it: the switch waits for combat to end.
--------------------------------------------------------------------------------
function CW:ActiveSpec()
	return (GetActiveTalentGroup and GetActiveTalentGroup()) or 1
end

function CW:SpecProfiles()
	return self.db.char.specProfiles
end

-- Called whenever the profile changed: the active spec now uses it.
function CW:RememberSpecProfile()
	local sp = self.db.char.specProfiles
	if sp.enabled then sp[self:ActiveSpec()] = self.db:GetCurrentProfile() end
end

function CW:SetSpecProfilesEnabled(on)
	local sp = self.db.char.specProfiles
	sp.enabled = on and true or false
	if sp.enabled then
		if self.db.char.roleProfiles.enabled then self:SetRoleProfilesEnabled(false) end -- (the role usually follows the spec: both would switch)
		self:RememberSpecProfile()
	end
end

-- Choose the profile a spec uses: switched to at once when it is the active spec, else when the spec is next used.
function CW:SetSpecProfile(group, name)
	name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return false end
	self.db.char.specProfiles[group] = name
	if group == self:ActiveSpec() then self:UseProfile(name) end
	return true
end

function CW:ApplySpecProfile()
	local sp = self.db.char.specProfiles
	if not sp.enabled then return end
	local group, current = self:ActiveSpec(), self.db:GetCurrentProfile()
	local name = sp[group]
	if not name then
		sp[group] = current -- first time in this spec: keep the profile in use
	elseif name ~= current then
		self.db:SetProfile(name)
	end
end

function CW:OnSpecChanged()
	if not self.db then return end
	self:RunOOC("spec.profile", CW.ApplySpecProfile, CW)
	self:OnRoleMayHaveChanged()
end

--------------------------------------------------------------------------------
-- A profile per role (a paladin that tanks in one group and heals in the next: same talents, different frames).
-- char.roleProfiles = {enabled, role, TANK = name, HEALER = name, DAMAGER = name}. It works like the profile per
-- talent spec, with the role CW.GetUnitRole reports for the player in place of the spec (the dungeon finder role,
-- else the talents, else "My role" set by hand). The two are exclusive: the role usually follows the spec, so both
-- would switch at once. A role that is not known yet (the talents are not inspected) switches nothing.
--
-- "My role" set by hand then lives on the character (roleProfiles.role), not in the profile: a role that picks the
-- profile cannot be stored inside it (the Tank profile saying Healer would bounce between the two forever).
-- profileRole is the role the profile in use was chosen for; it can differ from the live role while combat holds
-- back a switch, and a profile chosen by hand in that window belongs to the role it was in use for.
--------------------------------------------------------------------------------
CW.ROLES = {"TANK", "HEALER", "DAMAGER"}

function CW:RoleProfiles()
	return self.db.char.roleProfiles
end

-- The "My role" setting: in the profile, or on the character while a profile per role is on. "AUTO" = detect.
function CW:MyRole()
	local rp = self.db.char.roleProfiles
	return (rp.enabled and rp.role or self.db.profile.myRole) or "AUTO"
end

function CW:SetMyRole(role)
	local rp = self.db.char.roleProfiles
	if rp.enabled then rp.role = role else self.db.profile.myRole = role end
	self:OnRoleMayHaveChanged()
	self:RefreshAll()
end

-- Called whenever the profile changed: the role in play now uses it.
function CW:RememberRoleProfile()
	local rp = self.db.char.roleProfiles
	if rp.enabled and self.profileRole then rp[self.profileRole] = self.db:GetCurrentProfile() end
end

function CW:SetRoleProfilesEnabled(on)
	local rp = self.db.char.roleProfiles
	on = on and true or false
	if on == (rp.enabled and true or false) then return end
	if on then
		self.db.char.specProfiles.enabled = false
		rp.role = self.db.profile.myRole or "AUTO" -- the role in force stays in force
		rp.enabled = true
		self.profileRole = CW.GetUnitRole("player")
		self:RememberRoleProfile()
	else
		self.db.profile.myRole = rp.role or "AUTO"
		rp.enabled = false
		self.profileRole = nil
	end
	self:RefreshAll()
end

-- Choose the profile a role uses: switched to at once when it is the role in play, else when that role is next played.
function CW:SetRoleProfile(role, name)
	name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return false end
	self.db.char.roleProfiles[role] = name
	if role == CW.GetUnitRole("player") then
		self.profileRole = role
		self:UseProfile(name)
	end
	return true
end

function CW:ApplyRoleProfile()
	local rp = self.db.char.roleProfiles
	if not rp.enabled then return end
	local role = CW.GetUnitRole("player")
	if not role then return end
	self.profileRole = role
	local name, current = rp[role], self.db:GetCurrentProfile()
	if not name then
		rp[role] = current -- first time in this role: keep the profile in use
	elseif name ~= current then
		self.db:SetProfile(name)
	end
end

-- (the look must follow the role whether or not a profile per role is on, so only the profile part is guarded)
function CW:OnRoleMayHaveChanged()
	if not self.db then return end
	if self:UpdateLookRole() then self:RefreshAll() end
	if self.db.char.roleProfiles.enabled then
		self:RunOOC("role.profile", CW.ApplyRoleProfile, CW)
	end
end

--------------------------------------------------------------------------------
-- A look per role: one profile that looks different while you tank and while you heal.
-- profile.roleLook[ROLE] = {enabled, width, height, healPred, debuffIcon, threatBar, threatBarTanks}. While the role
-- the player plays has its look on, CW:Look(name) answers from it; otherwise from the ordinary settings, which the
-- General and Layout tabs keep editing (nothing here ever writes to them). Every place that draws with one of these
-- asks CW:Look. The role is the one CW.GetUnitRole reports; a role that is not known yet (the talents are not
-- inspected) uses the ordinary settings, never the look of the role played before.
--------------------------------------------------------------------------------
CW.LOOK_BASE = {
	width = {"frame", "width"},
	height = {"frame", "height"},
	healPred = {"healPred", "enabled"},
	debuffIcon = {"debuffs", "icon"},
	threatBar = {"threat", "bar"},
	threatBarTanks = {"threat", "barOnTanks"},
}

-- Re-read the role in play. Answers whether that changed what is shown: the role differs and either look is on.
function CW:UpdateLookRole()
	local looks = self.db.profile.roleLook
	local old, new = self.lookRole, CW.GetUnitRole("player")
	self.lookRole = new
	if old == new then return false end
	return ((old and looks[old] and looks[old].enabled) or (new and looks[new] and looks[new].enabled)) and true or false
end

-- The role whose look is in use right now, or nil.
function CW:LookRole()
	local role = self.lookRole
	local look = role and self.db.profile.roleLook[role]
	return (look and look.enabled) and role or nil
end

function CW:Look(name)
	local role = self:LookRole()
	if role then return self.db.profile.roleLook[role][name] end
	local base = CW.LOOK_BASE[name]
	return self.db.profile[base[1]][base[2]]
end

-- Delete a profile (never the one in use); a spec or a role that used it forgets it.
function CW:DeleteProfile(name)
	if name == self.db:GetCurrentProfile() then return false end
	self.db:DeleteProfile(name, true)
	local sp = self.db.char.specProfiles
	for group = 1, 2 do
		if sp[group] == name then sp[group] = nil end
	end
	local rp = self.db.char.roleProfiles
	for _, role in ipairs(CW.ROLES) do
		if rp[role] == name then rp[role] = nil end
	end
	return true
end

-- Move this character onto a profile of its own: a copy of the one it uses now, unless that profile
-- already exists (then it is just switched to, never overwritten). Returns "already", "switched" or "created".
function CW:GiveOwnProfile()
	local key, old = self:CharKey(), self.db:GetCurrentProfile()
	if old == key then return "already" end
	local exists = false
	for _, name in ipairs(self:ProfileNames()) do
		if name == key then exists = true end
	end
	self.db:SetProfile(key)
	if exists then return "switched" end
	self.db:CopyProfile(old, true)
	return "created"
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
	elseif cmd == "debuffs" then
		-- debugging aid: a unit's harmful auras with the debuff type the client reports
		for _, line in ipairs(CW.Debuffs:DumpUnit(rest ~= "" and rest or "target")) do
			self:Print(line)
		end
	elseif cmd == "defensives" then
		-- debugging aid: the defensive cooldowns up on a unit, who cast them and the time left
		if CW.Defensives then
			for _, line in ipairs(CW.Defensives:DumpUnit(rest ~= "" and rest or "target")) do
				self:Print(line)
			end
		else
			-- Defensives.lua is listed in the .toc but was not loaded: the client only reads the file list at launch
			self:Print("Defensives.lua was not loaded. Fully restart the game client (a /reload is not enough after files are added to the .toc).")
		end
	elseif cmd == "smart" then
		-- debugging aid: what each rule set compiles to for a unit's frame, rule by rule
		if CW.Smart then
			for _, line in ipairs(CW.Smart:DumpUnit(rest ~= "" and rest or "player")) do
				self:Print(line)
			end
		else
			-- Smart.lua is listed in the .toc but was not loaded: the client only reads the file list at launch
			self:Print("Smart.lua was not loaded. Fully restart the game client (a /reload is not enough after files are added to the .toc).")
		end
	elseif cmd == "dispels" then
		-- debugging aid: which removal spells the client resolved and knows, and what that covers
		for _, line in ipairs(CW.Debuffs:Describe()) do
			self:Print(line)
		end
	elseif cmd == "profile" then
		-- this character's profile, who else uses it, and (with a name) a switch
		if rest ~= "" then
			self:UseProfile(rest)
		end
		local current = self.db:GetCurrentProfile()
		self:Print((L["Profile: %s (this character: %s)."]):format(current, self:CharKey()))
		local users = self:ProfileUsers(current)
		if #users > 0 then
			self:Print((L["Also used by: %s."]):format(table.concat(users, ", ")))
		else
			self:Print(L["No other character uses this profile."])
		end
		self:Print((L["Profiles: %s."]):format(table.concat(self:ProfileNames(), ", ")))
		if self.db.char.roleProfiles.enabled then
			self:Print((L["A profile per role is on; you play %s."]):format(CW.GetUnitRole("player") or "?"))
		end
		local lookRole = self:LookRole()
		if lookRole then
			self:Print((L["The look of the %s role is on."]):format(lookRole))
		end
	elseif cmd == "threat" then
		-- debugging aid: the enemy the threat bar measures against, and each frame's status and percentage
		for _, line in ipairs(CW.Threat:Describe()) do
			self:Print(line)
		end
	elseif cmd == "test" then
		-- a made-up group to try the frames without other players (Test.lua)
		CW.Test:Command(rest)
	elseif cmd == "buffcheck" then
		-- debugging aid: verify the buff spell IDs in BuffData.lua against this client
		self:Print(CW.Buffs:CheckMacroSupport())
		for _, line in ipairs(CW.Buffs:CheckData()) do
			self:Print(line)
		end
		if CW.Defensives then
			for _, line in ipairs(CW.Defensives:CheckData()) do
				self:Print(line)
			end
		end
		if CW.Smart then
			for _, line in ipairs(CW.Smart:CheckConditionals()) do
				self:Print(line)
			end
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
		self:Print("/cw [config] | lock | unlock | reset | binds | bind <key> <spell> | unbind <key> | resetbinds | buffs [unit] | buffcheck | debuffs [unit] | defensives [unit] | smart [unit] | dispels | threat | profile [name] | test [5|10|25|40|off|combat]")
	end
end
