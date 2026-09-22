-- Test mode: a made-up group, so buffs, debuffs, range fade, combat colors and layout can be tried without
-- other players.  /cw test [5|10|25|40|off|combat]   (also the buttons at the bottom of the General tab)
--
-- The game cannot be told that a group exists: the secure headers build their frames from the real roster.
-- So test mode adds a second set of plain buttons beside the real ones, each showing an INVENTED unit
-- ("cwtest1" ...). Every unit query the addon makes goes through CW.API (Compat.lua), which answers for an
-- invented unit from CW.fake and leaves everything else to the game, so the test frames run the real code:
-- the assignment walk (your rules, your spells), the debuff highlight, the range fade, the combat colors, the
-- tooltip and the click macros. The test frames are members of UnitFrame.frames like any other frame, so the
-- settings windows repaint them too.
--
-- What it cannot do is cast: a secure click needs a real unit. A click on a test frame instead reads the
-- attributes of that frame (exactly what a real click would run), says what it would cast, and for a buff or
-- a cure pretends the spell landed: the aura appears (or the debuff goes), the pick moves on, the macro is
-- rewritten. Which is what makes the walk (several buffs, one per click) testable alone.
--
-- Session only: nothing is saved and nothing starts by itself. The frames are plain (not secure), so test
-- mode can be switched on, off and resized in combat.
--
-- An invented unit:  {index, token, guid, name, class, classLoc, role, health, healthMax, online, dead,
--   ghost, inRange, fighting, threat (0-3), threatPct, incoming (an incoming heal), buffs, debuffs}
-- where an aura is {name, icon, caster, duration, expires, count, type}; see the API block in Compat.lua.

local CW = Clickwise
local Test = CW:NewModule("Test", "AceEvent-3.0", "AceTimer-3.0")
CW.Test = Test

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local floor, max, min, random = math.floor, math.max, math.min, math.random
local ipairs = ipairs
local GetTime, GetSpellInfo = GetTime, GetSpellInfo

local MAX_UNITS = 40
local TICK = 1.5            -- seconds between the small changes that make the frames move
local BUFF_SECONDS = 1800   -- how long a buff "cast" on a test frame lasts
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

Test.SIZES = {5, 10, 25, 40}

local NAMES = {
	"Aldric", "Brenna", "Corvin", "Dahlia", "Edmund", "Fenna", "Gorm", "Hilda", "Ivo", "Jessa",
	"Kellan", "Lyra", "Marek", "Nessa", "Orrin", "Petra", "Quill", "Rowan", "Sable", "Tobin",
	"Ulric", "Vera", "Wendel", "Xara", "Yorick", "Zelda", "Anselm", "Bryn", "Cedric", "Dara",
	"Elric", "Freya", "Garrick", "Hana", "Isolde", "Joren", "Kira", "Lucan", "Mira", "Nolan",
}

-- roles by place in a group of five, one row per group (groups 3+ have no tank: a 25-man has two)
local ROLE_ROWS = {
	{"TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER"},
	{"TANK", "DAMAGER", "DAMAGER", "HEALER", "DAMAGER"},
	{"DAMAGER", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER"},
	{"DAMAGER", "DAMAGER", "DAMAGER", "HEALER", "DAMAGER"},
}
local TANK_CLASSES = {"WARRIOR", "PALADIN", "DEATHKNIGHT", "DRUID"}
local HEAL_CLASSES = {"PRIEST", "PALADIN", "DRUID", "SHAMAN"}
local DPS_CLASSES = {"MAGE", "ROGUE", "HUNTER", "WARLOCK", "DEATHKNIGHT", "SHAMAN", "DRUID", "WARRIOR", "PALADIN", "PRIEST"}
local MAX_HEALTH = {TANK = 32000, HEALER = 15000, DAMAGER = 18000}
local HEALTH_PCT = {1, 0.92, 0.7, 0.55, 1, 0.35, 1, 0.88, 0.15, 0.62} -- green, yellow and red bands

-- one of each debuff type the highlight knows, and one without a type (which it ignores)
local DEBUFFS = {
	{type = "Magic", name = "Slow", icon = "Interface\\Icons\\Spell_Frost_FrostShock"},
	{type = "Curse", name = "Curse of Agony", icon = "Interface\\Icons\\Spell_Shadow_CurseOfSargeras"},
	{type = "Disease", name = "Crypt Fever", icon = "Interface\\Icons\\Spell_Nature_NullifyDisease"},
	{type = "Poison", name = "Deadly Poison", icon = "Interface\\Icons\\Spell_Nature_NullifyPoison"},
}
local UNTYPED = {name = "Sunder Armor", icon = QUESTION_MARK, count = 3}

--------------------------------------------------------------------------------
-- Inventing units
--------------------------------------------------------------------------------
local function AddDebuff(u, kind)
	u.debuffs[#u.debuffs + 1] = {name = kind.name, icon = kind.icon, type = kind.type, count = kind.count or 1}
end

-- `duration` = nil: a permanent aura; `left` = seconds until it runs out (default: the whole duration)
local function AddBuff(u, name, caster, duration, left)
	local _, _, icon = GetSpellInfo(name)
	u.buffs[#u.buffs + 1] = {name = name, icon = icon or QUESTION_MARK, caster = caster,
		duration = duration or 0, expires = duration and (GetTime() + (left or duration)) or 0}
end

local function NewUnit(i)
	local g, k = floor((i - 1) / 5), (i - 1) % 5
	local role = ROLE_ROWS[g % 4 + 1][k + 1]
	if g >= 2 and role == "TANK" then role = "DAMAGER" end
	local class
	if role == "TANK" then
		class = TANK_CLASSES[g % 4 + 1]
	elseif role == "HEALER" then
		class = HEAL_CLASSES[i % 4 + 1]
	else
		class = DPS_CLASSES[(i * 3) % 10 + 1]
	end

	local u = {
		index = i, token = "cwtest" .. i, guid = ("0xTEST%010d"):format(i), name = NAMES[i] or ("Test" .. i),
		class = class, classLoc = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class,
		role = role, online = true, dead = false, ghost = false, inRange = true, fighting = false,
		threat = 0, threatPct = 0, incoming = 0, buffs = {}, debuffs = {},
	}
	u.healthMax = floor(MAX_HEALTH[role] * (1 + (i % 3) * 0.05))
	u.health = floor(u.healthMax * HEALTH_PCT[(i - 1) % 10 + 1])
	if i % 11 == 5 then
		u.dead, u.health = true, 0
	elseif i % 13 == 8 then
		u.online = false
	end
	if i % 7 == 3 then u.inRange = false end
	if u.health < u.healthMax * 0.75 and i % 3 == 0 then u.incoming = floor(u.healthMax * 0.25) end

	if role == "TANK" then
		u.threat = 3
	elseif i % 8 == 3 then
		u.threat, u.threatPct = 1, 85
	elseif i % 12 == 5 then
		u.threat, u.threatPct = 2, 100
	end

	-- debuffs: most frames have one of the four types, some two (the highlight picks the most urgent), some an
	-- untyped one on top
	local kind = i % 5
	if kind > 0 then AddDebuff(u, DEBUFFS[kind]) end
	if i % 6 == 0 then AddDebuff(u, DEBUFFS[(kind + 1) % 4 + 1]) end
	if i % 4 == 1 then AddDebuff(u, UNTYPED) end
	return u
end

-- Defensives (Defensives.lua): every third frame has one of the big externals from another test unit, the tanks their own
-- cooldown, so the icons, their borders and the countdown can be watched. `left` = seconds until it runs out.
local EXTERNAL_IDS = {47788, 33206, 6940, 1022}
local OWN_IDS = {871, 12975, 31850, 48792, 22812}

local function AddDefensive(u, id, caster, duration, left)
	if not CW.Defensives then return end -- nil if this file list is stale (a new .lua file needs a full client restart)
	local name
	for _, entry in ipairs(CW.Defensives.LIST) do
		if entry.id == id then name = entry.name end -- (as resolved by the client, which is what an aura is called)
	end
	local _, _, icon = GetSpellInfo(id)
	u.buffs[#u.buffs + 1] = {name = name or tostring(id), icon = icon or QUESTION_MARK, caster = caster,
		duration = duration, expires = GetTime() + left}
end

local function AddExternal(u, count, left)
	local other = u.index % count + 1
	AddDefensive(u, EXTERNAL_IDS[u.index % #EXTERNAL_IDS + 1], "cwtest" .. other, 12, left)
end

local function SeedDefensives(u, count)
	if u.index % 3 == 1 and count > 1 then AddExternal(u, count, 5 + (u.index % 4) * 3) end
	if u.role == "TANK" then AddDefensive(u, OWN_IDS[u.index % #OWN_IDS + 1], u.token, 15, 12) end
end

-- Buffs: for every buff group a mix of missing, provided by someone else, the player's own and the player's own
-- about to run out (the pulse). The player's own are only invented for spells the player knows, one per exclusive
-- slot (a paladin cannot have two of his blessings on one target).
local function SeedBuffs(u, count)
	local Buffs = CW.Buffs
	local mineSlots = {}
	for gi, group in ipairs(CW.BuffGroups) do
		local state = (u.index + gi) % 6
		if group.selfOnly then
			-- a personal buff only ever shows on the player's own frame, and the test group has none
		elseif state == 1 or state == 2 then
			local other = (u.index + gi) % count + 1
			if other == u.index then other = other % count + 1 end
			local spell = group.spells[(u.index + gi) % #group.spells + 1]
			AddBuff(u, spell.name, "cwtest" .. other)
		elseif state == 3 or state == 4 then
			local spell = Buffs:GetCastSpell(group.key)
			local _, slot = Buffs:SpellGroup(spell)
			if spell and not (slot and mineSlots[slot]) then
				if slot then mineSlots[slot] = true end
				local left = state == 4 and (10 + (u.index % 4) * 8) or BUFF_SECONDS
				AddBuff(u, spell, "player", BUFF_SECONDS, left)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- The frames
--------------------------------------------------------------------------------
local BUTTON_OF = {LeftButton = "1", RightButton = "2", MiddleButton = "3", Button4 = "4", Button5 = "5"}

function Test:Build()
	if self.container then return end
	local c = CreateFrame("Frame", "ClickwiseTestContainer", UIParent)
	c:SetSize(120, 40)
	self.container = c
	self.buttons = {}
	for i = 1, MAX_UNITS do
		local btn = CreateFrame("Button", nil, c)
		btn:Hide() -- CreateFrame returns shown frames on 3.3.5
		btn:RegisterForClicks("AnyUp")
		CW.UnitFrame:InitButton(btn, true)
		btn:SetScript("OnClick", function(self, mouse) Test:Click(self, mouse) end)
		self.buttons[i] = btn
	end
end

-- Same arrangement as the real headers (Frames.lua): groups of five, side by side, or stacked when horizontal.
function Test:Layout()
	local c, count = self.container, self.count
	if not (c and count) then return end
	local db = CW.db.profile
	local f = db.frame
	local width, height = CW:Look("width"), CW:Look("height")
	local anchor = CW.Frames.container
	c:SetScale(anchor:GetScale())
	c:ClearAllPoints()
	c:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -50) -- below the real frames: they follow the drag tab
	for i = 1, count do
		local btn = self.buttons[i]
		local g, k = floor((i - 1) / 5), (i - 1) % 5
		local x, y
		if db.horizontal then
			x, y = k * (width + f.spacing), -g * (height + f.groupSpacing)
		else
			x, y = g * (width + f.groupSpacing), -k * (height + f.spacing)
		end
		btn:SetSize(width, height)
		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", c, "TOPLEFT", x, y)
	end
end

function Test:IsActive()
	return self.count ~= nil
end

-- Tear down without a message: frames hidden and forgotten, invented units gone, combat colors back to the truth.
function Test:Clear()
	if not self.count then return end
	self:SetCombat(false, true)
	if self.timer then
		self:CancelTimer(self.timer, true)
		self.timer = nil
	end
	self.count = nil
	for _, btn in ipairs(self.buttons) do
		if btn.cwFakeUnit then
			btn.cwFakeUnit = nil
			btn:Hide()
			CW.UnitFrame:UpdateUnit(btn) -- no unit any more: it leaves the GUID index
		end
	end
	wipe(CW.fake)
	wipe(CW.fakeGuid)
	self.units = nil
end

function Test:Start(count)
	if not (CW.Frames and CW.Frames.container and CW.db) then
		CW:Print(L["Test group: the frames are not built yet."])
		return
	end
	count = max(1, min(MAX_UNITS, floor(tonumber(count) or 5)))
	self:Clear()
	self:Build()

	self.units = {}
	for i = 1, count do
		local u = NewUnit(i)
		self.units[i] = u
		CW.fake[u.token] = u
		CW.fakeGuid[u.guid] = u
	end
	for _, u in ipairs(self.units) do
		SeedBuffs(u, count)
		SeedDefensives(u, count)
	end
	self.count, self.ticks = count, 0

	self:Layout()
	for i = 1, count do
		local btn = self.buttons[i]
		btn.cwFakeUnit = self.units[i].token
		btn:Show()
		CW.UnitFrame:UpdateUnit(btn)
	end
	self.timer = self:ScheduleRepeatingTimer("Tick", TICK)
	CW:Print((L["Test group: %d made-up members, shown below your frames. Click one to see what your click would cast. /cw test combat switches combat colors, /cw test off ends it."]):format(count))
end

function Test:Stop()
	if not self.count then return false end
	self:Clear()
	CW:Print(L["Test group off."])
	return true
end

-- Pretend the group is fighting: the health bars take their combat colors and the threat states matter.
-- (A real combat start or end sets the colors right again.)
function Test:SetCombat(on, quiet)
	if not self.count then return end
	on = on and true or false
	if on == (self.combat or false) then return end
	self.combat = on
	for _, u in ipairs(self.units) do u.fighting = on end
	local cc = CW.CombatColor
	if cc then
		cc.inCombat = on or (UnitAffectingCombat("player") and true or false)
		cc:Refresh()
	end
	local threat = CW.Threat
	if threat then
		threat.inCombat = on or (UnitAffectingCombat("player") and true or false)
		threat:Refresh()
	end
	if not quiet then CW:Print(on and L["Test combat on."] or L["Test combat off."]) end
end

function Test:ToggleCombat()
	if not self.count then
		CW:Print(L["Start a test group first: /cw test"])
		return
	end
	self:SetCombat(not self.combat)
end

function Test:Command(arg)
	arg = (arg or ""):lower()
	if arg == "" then
		if self.count then self:Stop() else self:Start(5) end
	elseif arg == "off" or arg == "stop" then
		self:Stop()
	elseif arg == "combat" then
		self:ToggleCombat()
	elseif tonumber(arg) then
		self:Start(tonumber(arg))
	else
		CW:Print(L["Usage: /cw test [5|10|25|40|off|combat]"])
	end
end

--------------------------------------------------------------------------------
-- Life: the health moves, heals come in, a debuff comes and goes
--------------------------------------------------------------------------------
-- An aura of an invented unit changed: tell the buff and debuff modules the way the game would.
function Test:AuraChanged(u)
	CW.Buffs:OnUnitAura(nil, u.token)
	if CW.Debuffs then CW.Debuffs:OnUnitAura(nil, u.token) end
	if CW.Defensives then CW.Defensives:OnUnitAura(nil, u.token) end
	if CW.Smart then CW.Smart:OnUnitAura(nil, u.token) end
end

function Test:Tick()
	if not self.count then return end
	self.ticks = self.ticks + 1
	for _, u in ipairs(self.units) do
		if u.online and not u.dead then
			if random() < 0.35 then
				local change = random(-(self.combat and 22 or 12), 10) / 100
				u.health = max(floor(u.healthMax * 0.05), min(u.healthMax, u.health + floor(u.healthMax * change)))
			end
			u.incoming = (u.health < u.healthMax * 0.75 and random() < 0.5) and floor(u.healthMax * 0.25) or 0
			if self.combat and u.role == "DAMAGER" and random() < 0.15 then
				u.threat, u.threatPct = random(0, 2), random(40, 100)
			end
			CW.UnitFrame:UpdateGUID(u.guid)
			if CW.Smart then CW.Smart:OnUnitHealth(nil, u.token) end -- (the game's UNIT_HEALTH: a rule that looks at health)
		end
	end
	if self.ticks % 3 == 0 then
		-- an external lands on someone (it runs out by itself: the countdown and the safety net clear it)
		local u = self.units[random(1, self.count)]
		if u.online and not u.dead and self.count > 1 then
			AddExternal(u, self.count, 12)
			self:AuraChanged(u)
		end
	end
	if self.ticks % 4 == 0 then
		local u = self.units[random(1, self.count)]
		if u.online and not u.dead then
			if #u.debuffs > 0 then
				for i = #u.debuffs, 1, -1 do u.debuffs[i] = nil end
			else
				AddDebuff(u, DEBUFFS[random(1, #DEBUFFS)])
			end
			self:AuraChanged(u)
		end
	end
end

--------------------------------------------------------------------------------
-- Clicks
--------------------------------------------------------------------------------
-- The pretend cast: a buff lands (replacing the player's own of that group or exclusive slot), a cure removes
-- the debuff it is for.
function Test:Cast(u, spell)
	local base = (spell:gsub("%s*%(.-%)$", "")) -- "Name(Rank 3)" -> "Name"
	CW:Print((L["Test: your click casts %s on %s."]):format(spell, u.name))
	local changed = false
	if u.dead and base == CW.ClickCast:RezSpell() then
		-- a resurrection: back on their feet with a third of the health
		u.dead, u.ghost, u.health = false, false, floor(u.healthMax * 0.35)
		CW.UnitFrame:UpdateGUID(u.guid)
	end
	local key, slot = CW.Buffs:SpellGroup(base)
	if key then
		for i = #u.buffs, 1, -1 do
			local a = u.buffs[i]
			if a.caster == "player" then
				local k, s = CW.Buffs:SpellGroup(a.name)
				if k == key or (slot and s == slot) then table.remove(u.buffs, i) end
			end
		end
		AddBuff(u, base, "player", BUFF_SECONDS)
		changed = true
	end
	if CW.Debuffs then
		for i, d in ipairs(u.debuffs) do
			if d.type and CW.Debuffs.CureFor({{type = d.type, curable = CW.Debuffs:CanCure(d.type)}}) == base then
				table.remove(u.debuffs, i)
				changed = true
				break -- one debuff per cast
			end
		end
	end
	if changed then self:AuraChanged(u) end
end

-- The client cannot tell whether an invented unit is dead, so a clause that tests it ([target=cwtest3,dead], from a Smart
-- mode rule) is answered here: true drops the test, false makes the bracket never hold.
local function AnswerDead(clauses, u)
	return (clauses:gsub("%[([^%]]-)%]", function(body)
		local ok, kept = true, {}
		for cond in body:gmatch("[^,]+") do
			if cond == "dead" then ok = ok and u.dead
			elseif cond == "nodead" then ok = ok and not u.dead
			else kept[#kept + 1] = cond end
		end
		if not ok then kept[#kept + 1] = "combat"; kept[#kept + 1] = "nocombat" end -- both: never true
		return "[" .. table.concat(kept, ",") .. "]"
	end))
end

-- What the click does, read from the frame's own attributes (the ones a secure click would run).
function Test:Click(btn, mouse)
	local u = btn.cwFakeUnit and CW.fake[btn.cwFakeUnit]
	local suffix = BUTTON_OF[mouse]
	if not (u and suffix) then return end
	local prefix = CW.MakeModifier(IsAltKeyDown(), IsControlKeyDown(), IsShiftKeyDown())
	local kind = btn:GetAttribute(prefix .. "type" .. suffix)
	if kind == "spell" then
		local spell = btn:GetAttribute(prefix .. "spell" .. suffix)
		if spell then self:Cast(u, spell) end
	elseif kind == "macro" then
		-- the lines run one after another: a /cast that has a clause holding ends the click (one spell per press), so does a
		-- /stopmacro whose conditions hold; a /click names the hidden button of a saved macro (Smart mode), which is not run here
		local spell, macroButton
		for line in (btn:GetAttribute(prefix .. "macrotext" .. suffix) or ""):gmatch("[^\n]+") do
			local cmd, args = line:match("^/(%a+)%s*(.*)$")
			if cmd == "cast" or cmd == "click" or cmd == "stopmacro" then
				-- an invented unit has no target for [harm,nodead] to test: those two are left out
				args = AnswerDead(args:gsub(",harm,nodead%]", "]"), u)
				local ok, action = pcall(SecureCmdOptionParse, args) -- picks the clause whose conditions hold now
				if ok and action then
					if cmd == "stopmacro" then break end
					if action ~= "" then
						if cmd == "cast" then spell = action else macroButton = action end
						break
					end
				end
			end
		end
		if macroButton then
			CW:Print((L["Test: your click runs the saved macro of the button %s on %s."]):format(macroButton, u.name))
			return
		end
		if spell and spell == CW.ClickCast:TauntSpell() then
			CW:Print((L["Test: your click casts %s on what %s is targeting."]):format(spell, u.name))
		elseif spell then
			self:Cast(u, spell)
		else
			CW:Print((L["Test: your click casts nothing on %s right now."]):format(u.name))
		end
	elseif kind == "target" or (kind == nil and suffix == "1") then
		CW:Print((L["Test: your click targets %s."]):format(u.name))
	elseif kind == nil and suffix == "2" then
		CW:Print(L["Test: your click opens the unit menu (not available on test frames)."])
	else
		CW:Print((L["Test: your click does %s, which test frames cannot show."]):format(tostring(kind or "nothing")))
	end
end

function Test:OnEnable()
	self:RegisterMessage("CLICKWISE_SETTINGS", "Layout") -- a size / spacing / layout option changed
end
