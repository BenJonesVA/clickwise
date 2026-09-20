-- Buff tracking: shows a small icon on a unit's frame for every tracked buff group it is missing.
--
-- Groups come from BuffData.lua (sets of equivalent buffs). For each unit the helpful auras are
-- scanned once per change and reduced to one state per group:
--   nil   = missing            (bright icon, greyed out when the unit is dead / offline / out of range)
--   MINE  = a group buff is up and the player cast it
--   OTHER = a group buff is up and someone else cast it (or the caster is not a resolvable unit)
-- Satisfied groups are hidden unless "show satisfied buffs" is on, then they are drawn dimmed.
-- "Any buff of the group counts" is what fixes the classic "permanent missing buff because an
-- equivalent or higher buff from another player is already up" annoyance.
--
-- Only groups the player can actually cast (a known spell in the group) are tracked. Which spell a
-- click casts is decided by the player's priority order for that group (Buffs tab) and resolved
-- OUT of combat by ClickCast, so no secure attribute ever depends on live aura state.
--
-- ASSIGNMENTS: a rule (Assignments tab) gives a target (a role, a class or everyone else) an ordered list
-- of buff groups. For a unit that matches a rule the list is walked in order: a group the unit has from
-- SOMEONE ELSE is skipped (the fallback case: another paladin already gave the tank Sanctuary, so the
-- next entry is used); a group the unit has from the player ends the walk (nothing more to cast); the
-- first group the unit lacks is the buff to cast. If a higher entry goes missing again while a lower one
-- from the player is up, the higher one is shown again (strict priority). The chosen buff is shown as the
-- unit's icon and is what an "Assigned buff" binding casts. The pick is handed to ClickCast as a spell
-- name (btn.cwAssignedSpell); ClickCast turns it into the click's macro, gated on combat as the binding
-- asks (default: out of combat only), and rewrites it when the pick or the unit changes.
--
-- EXPIRY WARNING: a buff the PLAYER cast that has less than `buffs.expireWarn` seconds left is drawn like a
-- missing one, but pulsing: slowly when the warning starts, faster as the time runs out. When the aura
-- is gone it is simply missing, so the icon is solid - the two ends of the warning match. Only display
-- state: the assignment chain and the click macro never look at remaining time, so nothing secure
-- changes while the clock runs. Nothing fires an event as time passes, so a small OnUpdate driver
-- (running only while some frame has a timed buff) animates the icons and notices when a buff enters
-- its warning window.
--
-- The icons are plain textures under a non-secure child frame, so painting them is legal in combat.
-- Rank comparison / auto-downgrade for low-level targets is deliberately not done: 3.3.5 exposes no
-- reliable rank-vs-level data and the aura "rank" field is not trustworthy (see lessonslearned.md).

local CW = Clickwise
local Buffs = CW:NewModule("Buffs", "AceEvent-3.0", "AceTimer-3.0")
CW.Buffs = Buffs

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local pairs, ipairs, type = pairs, ipairs, type
local UnitAura, UnitIsUnit, UnitGUID, UnitIsPlayer = UnitAura, UnitIsUnit, UnitGUID, UnitIsPlayer
local UnitIsConnected, UnitIsDeadOrGhost = UnitIsConnected, UnitIsDeadOrGhost
local GetSpellInfo, GetTime = GetSpellInfo, GetTime
local InCombatLockdown = InCombatLockdown
local cos, pi = math.cos, math.pi

local MINE, OTHER = 1, 2
local MAX_ICONS = 4
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local FLUSH_DELAY = 0.2 -- UNIT_AURA is spammy in raids; coalesce per GUID
local TICK = 0.05       -- expiry driver: animation step
local FLASH_SLOW, FLASH_FAST = 1.6, 0.25 -- seconds per pulse: when the warning starts / right before expiry
local FLASH_MIN_ALPHA = 0.25             -- the dim end of a pulse, as a fraction of the icon's normal alpha
local RESCAN_GAP = 0.5  -- an expired buff whose UNIT_AURA never came is re-read at most this often

Buffs.MINE, Buffs.OTHER = MINE, OTHER

-- Pure helpers (asserted directly by the harness).
-- Seconds per pulse for `remaining` seconds left of a `window`-second warning.
function Buffs.FlashPeriod(remaining, window)
	local f = window > 0 and remaining / window or 0
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	return FLASH_FAST + (FLASH_SLOW - FLASH_FAST) * f
end

-- Alpha factor for a pulse phase in [0, 1): 1 at phase 0, FLASH_MIN_ALPHA at phase 0.5.
function Buffs.FlashAlpha(phase)
	return FLASH_MIN_ALPHA + (1 - FLASH_MIN_ALPHA) * (0.5 + 0.5 * cos(phase * 2 * pi))
end

local groupByKey = {}
for _, group in ipairs(CW.BuffGroups) do groupByKey[group.key] = group end

local groupOf = {}   -- [aura name] = group key
local slotOf = {}    -- [spell / aura name] = exclusive slot (see BuffData.lua)
local tracked = {}   -- ordered list of {key, label, icon, spell, slot} for groups being shown
local trackedKeys = {}
local scanKeys = {}  -- groups whose aura state is read: the tracked ones plus every group named in a rule
local info = {}      -- [group key] = {key, label, icon, spell, slot} for every group the player can cast
local ruleLists = {} -- [target key] = ordered list of castable group keys (+ .set), see Rebuild
local hasRules = false
local enabled, showSatisfied, warnSeconds = true, false, 0
local dirty, flushScheduled = {}, false
local watch = {}         -- [button] = true while it has a buff in (or about to enter) its expiry warning

--------------------------------------------------------------------------------
-- Saved settings. profile.buffs.classes[CLASS][GROUP] = {enabled = bool|nil, order = {names}|nil}
-- Per class because profiles are shared between characters and castable groups are class-specific.
--------------------------------------------------------------------------------
local function GroupDB(key, create)
	local _, class = UnitClass("player")
	local classes = CW.db.profile.buffs.classes
	local c = classes[class]
	if not c then
		if not create then return nil end
		c = {}
		classes[class] = c
	end
	local g = c[key]
	if not g and create then
		g = {}
		c[key] = g
	end
	return g
end

function Buffs:GetGroups()
	return CW.BuffGroups
end

function Buffs:GetGroup(key)
	return groupByKey[key]
end

-- Groups currently shown on the frames, in order: {key, label, icon, spell}.
function Buffs:GetTracked()
	return tracked
end

-- The player can cast at least one spell of the group.
function Buffs:IsAvailable(key)
	local group = groupByKey[key]
	if not group then return false end
	for _, s in ipairs(group.spells) do
		if CW.KnowsSpell(s.name) then return true end
	end
	return false
end

function Buffs:IsGroupEnabled(key)
	local g = GroupDB(key)
	if g and g.enabled ~= nil then
		return g.enabled
	end
	local group = groupByKey[key]
	return group ~= nil and group.defaultOn ~= false
end

function Buffs:SetGroupEnabled(key, value)
	GroupDB(key, true).enabled = value and true or false
	self:Changed()
end

-- Every spell name of the group in priority order: the player's saved order first, then any
-- spells the saved order does not mention, in data order.
function Buffs:GetOrder(key)
	local group = groupByKey[key]
	if not group then return {} end
	local valid = {}
	for _, s in ipairs(group.spells) do valid[s.name] = true end
	local out, seen = {}, {}
	local g = GroupDB(key)
	if g and g.order then
		for _, name in ipairs(g.order) do
			if valid[name] and not seen[name] then
				out[#out + 1] = name
				seen[name] = true
			end
		end
	end
	for _, s in ipairs(group.spells) do
		if not seen[s.name] then out[#out + 1] = s.name end
	end
	return out
end

-- Spell names of the group the player knows, in priority order (what the Buffs tab lists).
function Buffs:GetKnownOrder(key)
	local out = {}
	for _, name in ipairs(self:GetOrder(key)) do
		if CW.KnowsSpell(name) then out[#out + 1] = name end
	end
	return out
end

-- Highest-priority spell of the group that the player knows, or nil.
function Buffs:GetCastSpell(key)
	for _, name in ipairs(self:GetOrder(key)) do
		if CW.KnowsSpell(name) then return name end
	end
end

-- Swap `name` with the next known spell up (delta = -1) or down (delta = 1).
function Buffs:MoveSpell(key, name, delta)
	local order = self:GetOrder(key)
	local i
	for idx, n in ipairs(order) do
		if n == name then i = idx break end
	end
	if not i then return false end
	local j = i + delta
	while j >= 1 and j <= #order and not CW.KnowsSpell(order[j]) do
		j = j + delta
	end
	if j < 1 or j > #order then return false end
	order[i], order[j] = order[j], order[i]
	GroupDB(key, true).order = order
	self:Changed()
	return true
end

function Buffs:ResetGroup(key)
	local g = GroupDB(key)
	if g then
		g.order, g.enabled = nil, nil
	end
	self:Changed()
end

--------------------------------------------------------------------------------
-- Assignment rules. profile.buffs.classes[CLASS].rules[TARGET] = {group keys, highest priority first}
--------------------------------------------------------------------------------
function Buffs:TargetLabel(key)
	for _, target in ipairs(CW.BuffTargets) do
		if target.key == key then
			if target.label then return target.label end
			local class = key:match("^CLASS:(.+)$")
			return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class or key
		end
	end
	return key
end

-- The saved list for a target (a copy; may be empty).
function Buffs:GetRule(targetKey)
	local out = {}
	local _, class = UnitClass("player")
	local c = CW.db.profile.buffs.classes[class]
	local list = c and c.rules and c.rules[targetKey]
	if list then
		for _, key in ipairs(list) do
			if groupByKey[key] then out[#out + 1] = key end
		end
	end
	return out
end

function Buffs:HasRules()
	return hasRules
end

-- list = ordered group keys; an empty or nil list removes the rule.
function Buffs:SetRule(targetKey, list)
	local _, class = UnitClass("player")
	local classes = CW.db.profile.buffs.classes
	local c = classes[class]
	if not c then
		c = {}
		classes[class] = c
	end
	c.rules = c.rules or {}
	if list and #list > 0 then
		local copy, seen = {}, {}
		for _, key in ipairs(list) do
			if groupByKey[key] and not seen[key] then
				copy[#copy + 1] = key
				seen[key] = true
			end
		end
		c.rules[targetKey] = (#copy > 0) and copy or nil
	else
		c.rules[targetKey] = nil
	end
	self:Changed()
end

-- Tell everything that depends on the buff configuration (this module's icons and the click
-- bindings that resolve a group to a spell).
function Buffs:Changed()
	CW:SendMessage("CLICKWISE_BUFFS_CHANGED")
end

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------
-- Re-resolve every spell name from its ID (locale-safe); the English name in the data table is
-- only the fallback when the client does not know the ID.
function Buffs:ResolveNames()
	for _, group in ipairs(CW.BuffGroups) do
		for _, s in ipairs(group.spells) do
			s.english = s.english or s.name -- keep the data table's name for /cw buffcheck
			local name = GetSpellInfo(s.id)
			if type(name) == "string" and name ~= "" then
				s.name = name
			end
		end
	end
end

-- Lines for `/cw buffcheck`: data entries whose ID does not resolve to the expected English name
-- (only meaningful on an English client).
function Buffs:CheckData()
	local lines, bad = {}, 0
	for _, group in ipairs(CW.BuffGroups) do
		for _, s in ipairs(group.spells) do
			local name = GetSpellInfo(s.id)
			local expected = s.english or s.name
			if name ~= expected then
				bad = bad + 1
				lines[#lines + 1] = ("%s: id %d resolves to %s, expected %s"):format(group.key, s.id, tostring(name), expected)
			end
		end
	end
	lines[#lines + 1] = (bad == 0) and "All buff spell IDs resolve to the expected names." or (bad .. " buff spell ID(s) look wrong.")
	return lines
end

-- Lines for `/cw buffs [unit]`: every helpful aura with its caster and buff group.
function Buffs:DumpUnit(unit)
	if not UnitExists(unit) then
		return {"No such unit: " .. tostring(unit)}
	end
	local lines = {}
	local role = CW.GetUnitRole(unit)
	local _, class = UnitClass(unit)
	local list, targetKey = self:FindRule(unit)
	local rule = "none"
	if list then
		local labels = {}
		for _, key in ipairs(list) do labels[#labels + 1] = key end
		rule = targetKey .. " (" .. table.concat(labels, " > ") .. ")"
	end
	lines[1] = ("role: %s, class: %s, in combat: %s, matched rule: %s"):format(tostring(role), tostring(class),
		UnitAffectingCombat(unit) and "yes" or "no", rule)
	for i = 1, 40 do
		local name, _, _, _, _, _, _, caster, _, _, spellId = UnitAura(unit, i, "HELPFUL")
		if not name then break end
		lines[#lines + 1] = ("%d. %s  [caster: %s, spell %s, group: %s]"):format(
			i, name, tostring(caster), tostring(spellId), groupOf[name] or "-")
	end
	if #lines == 1 then lines[2] = "No buffs on " .. unit .. "." end
	return lines
end

--------------------------------------------------------------------------------
-- Which groups are shown
--------------------------------------------------------------------------------
function Buffs:Rebuild()
	local opts = CW.db.profile.buffs
	enabled, showSatisfied = opts.enabled, opts.showSatisfied
	warnSeconds = tonumber(opts.expireWarn) or 0

	groupOf, slotOf, tracked, trackedKeys, scanKeys, info, ruleLists = {}, {}, {}, {}, {}, {}, {}
	for _, group in ipairs(CW.BuffGroups) do
		for _, s in ipairs(group.spells) do
			groupOf[s.name] = group.key
			slotOf[s.name] = s.slot
		end
		if self:IsAvailable(group.key) then
			local spell = self:GetCastSpell(group.key)
			local _, _, icon = GetSpellInfo(spell)
			local entry = {key = group.key, label = group.label, icon = icon or QUESTION_MARK, spell = spell,
				slot = slotOf[spell]}
			info[group.key] = entry
			if enabled and self:IsGroupEnabled(group.key) then
				tracked[#tracked + 1] = entry
				trackedKeys[group.key] = true
				scanKeys[group.key] = true
			end
		end
	end

	-- assignment rules, reduced to the groups the player can actually cast
	hasRules = false
	for _, target in ipairs(CW.BuffTargets) do
		local list = {set = {}}
		for _, key in ipairs(self:GetRule(target.key)) do
			if info[key] then
				list[#list + 1] = key
				list.set[key] = true
				scanKeys[key] = true
			end
		end
		if #list > 0 then
			ruleLists[target.key] = list
			hasRules = true
		end
	end
end

-- The rule list that applies to a unit: its role, then its class, then "ALL". Second return value:
-- the target key that matched (shown by /cw buffs).
function Buffs:FindRule(unit)
	if not (hasRules and unit and UnitIsPlayer(unit)) then return nil end
	local role = CW.GetUnitRole(unit)
	if role and ruleLists["ROLE:" .. role] then return ruleLists["ROLE:" .. role], "ROLE:" .. role end
	local _, class = UnitClass(unit)
	if class and ruleLists["CLASS:" .. class] then return ruleLists["CLASS:" .. class], "CLASS:" .. class end
	return ruleLists["ALL"], ruleLists["ALL"] and "ALL" or nil
end

-- Line for `/cw buffcheck`: are the `[nocombat]` / `[combat]` macro conditionals understood by this client?
-- Out of combat SecureCmdOptionParse must answer "ok" for the first and "blocked" for the second; if not,
-- combat-gated clicks (Assigned buff, "out of combat" / "in combat" bindings) could never cast, silently.
function Buffs:CheckMacroSupport()
	if not SecureCmdOptionParse then
		return "SecureCmdOptionParse is missing: cannot test the [nocombat] / [combat] macro conditionals."
	end
	if InCombatLockdown() then
		return "In combat: run /cw buffcheck out of combat to test the [nocombat] / [combat] macro conditionals."
	end
	local out, inn = SecureCmdOptionParse("[nocombat] ok; blocked"), SecureCmdOptionParse("[combat] ok; blocked")
	if out == "ok" and inn == "blocked" then
		return "[nocombat] / [combat] macro conditionals work (combat-gated clicks can cast)."
	end
	return "[nocombat] / [combat] macro conditionals NOT understood (got " .. tostring(out) .. " / " .. tostring(inn)
		.. "): combat-gated clicks would never cast."
end

--------------------------------------------------------------------------------
-- Widgets (created with the unit button; see UnitFrame:InitButton)
--------------------------------------------------------------------------------
function Buffs:InitButton(btn)
	if btn.cwBuffIcons then return end
	local holder = CreateFrame("Frame", nil, btn)
	holder:SetFrameLevel(btn:GetFrameLevel() + 4)
	holder:SetAllPoints(btn)
	local icons = {}
	for i = 1, MAX_ICONS do
		local tex = holder:CreateTexture(nil, "OVERLAY")
		tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		tex:Hide()
		icons[i] = tex
	end
	btn.cwBuffHolder, btn.cwBuffIcons, btn.cwBuffState, btn.cwBuffSlots = holder, icons, {}, {}
	btn.cwExpire, btn.cwExpiring = {}, {} -- [group] = expiration time (false = a permanent aura) / in-warning subset
	self:LayoutButton(btn)
end

-- Icon size follows the frame height (three rows of text/bar fit in 34 units); icons sit in a row
-- along the bottom-left corner.
function Buffs:LayoutButton(btn)
	local icons = btn.cwBuffIcons
	if not icons then return end
	local height = CW.db.profile.frame.height
	local size = math.max(8, math.min(14, math.floor(height * 0.36)))
	for i = 1, MAX_ICONS do
		icons[i]:SetSize(size, size)
		icons[i]:ClearAllPoints()
		icons[i]:SetPoint("BOTTOMLEFT", btn.cwBuffHolder, "BOTTOMLEFT", 3 + (i - 1) * (size + 1), 3)
	end
end

--------------------------------------------------------------------------------
-- Scan (aura state) and paint (icons)
--------------------------------------------------------------------------------
-- The expiry driver only runs while some button is in `watch`.
local function UpdateDriver()
	local driver = Buffs.driver
	if not driver then return end
	if next(watch) then driver:Show() else driver:Hide() end
end

function Buffs:Scan(btn)
	local state, slots = btn.cwBuffState, btn.cwBuffSlots
	if not state then return end
	local exp, expiring = btn.cwExpire, btn.cwExpiring
	for k in pairs(state) do state[k] = nil end
	for k in pairs(slots) do slots[k] = nil end
	for k in pairs(exp) do exp[k] = nil end
	for k in pairs(expiring) do expiring[k] = nil end
	btn.cwChain, btn.cwDone, btn.cwAssignedSpell, btn.cwWarnAt = nil, nil, nil, nil
	local unit = btn.unit
	if not ((enabled and #tracked > 0 or hasRules) and unit and UnitIsPlayer(unit)) then
		watch[btn] = nil
		UpdateDriver()
		return
	end

	for i = 1, 40 do
		local name, _, _, _, _, duration, expires, caster = UnitAura(unit, i, "HELPFUL")
		if not name then break end
		local key = groupOf[name]
		if key and scanKeys[key] then
			if type(caster) == "string" and UnitIsUnit(caster, "player") then
				state[key] = MINE
				if slotOf[name] then slots[slotOf[name]] = key end -- the player's own slot spell is up
				-- when the group runs out: the latest of the player's auras in it; a permanent one never does
				local timed = type(duration) == "number" and duration > 0 and type(expires) == "number" and expires > 0
				local have = exp[key]
				if not timed then
					exp[key] = false
				elseif have == nil or (have ~= false and expires > have) then
					exp[key] = expires
				end
			elseif state[key] == nil then
				state[key] = OTHER
			end
		end
	end

	-- expiry warning (display only): which of the player's own buffs are inside the window, and when the
	-- next one will enter it
	if warnSeconds > 0 then
		local now = GetTime()
		for key, expires in pairs(exp) do
			if expires and state[key] == MINE then
				if expires - now <= warnSeconds then
					expiring[key] = expires
				else
					local at = expires - warnSeconds
					if not btn.cwWarnAt or at < btn.cwWarnAt then btn.cwWarnAt = at end
				end
			end
		end
	end
	-- (assigned in one place at the end: the driver calls Scan while iterating `watch`, and only
	-- existing keys may be assigned during a traversal)
	watch[btn] = (btn.cwWarnAt or next(expiring)) and true or nil
	UpdateDriver()

	-- assignment chain (see the header comment): skip what someone else provides, stop at what the
	-- player already gave, otherwise the first missing entry is the buff to cast
	local rule = btn.cwRule
	if rule then
		local target, done
		for _, key in ipairs(rule) do
			local have = state[key]
			if have == MINE then
				done = key
				break
			elseif have == nil then
				target = key
				break
			end
		end
		btn.cwChain, btn.cwDone = target, done
		-- the click always has something to cast: the missing entry, else re-buff what the player gave,
		-- else (everything provided by others) the top entry
		local pick = target or done or rule[1]
		btn.cwAssignedSpell = info[pick].spell
	end
end

function Buffs:Paint(btn)
	local icons = btn.cwBuffIcons
	if not icons then return end
	local shown = 0
	for i = 1, MAX_ICONS do icons[i].cwExpires = nil end

	-- expires: the aura's expiration time when the icon is a pulsing expiry warning, else nil
	local function show(group, alpha, grey, expires)
		shown = shown + 1
		local tex = icons[shown]
		tex:SetTexture(group.icon)
		-- Not relying on SetDesaturated alone: also darken the vertex color so the
		-- "unreachable" state is visible even if desaturation is unsupported.
		tex:SetDesaturated(grey)
		if grey then tex:SetVertexColor(0.6, 0.6, 0.6) else tex:SetVertexColor(1, 1, 1) end
		tex.cwBase, tex.cwExpires = alpha, expires -- the pulse multiplies the base alpha (see Tick)
		if expires and expires > GetTime() then
			tex.cwPhase = tex.cwPhase or 0 -- kept across repaints so an aura event does not restart the pulse
			tex:SetAlpha(alpha * self.FlashAlpha(tex.cwPhase))
		else
			tex:SetAlpha(alpha)
		end
		tex:Show()
	end

	local unit = btn.unit
	if enabled and unit and (#tracked > 0 or hasRules) and UnitIsPlayer(unit) then
		local state, slots, expiring = btn.cwBuffState, btn.cwBuffSlots, btn.cwExpiring
		local reachable = btn.cwInRange ~= false and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit)
		local base, greyed = reachable and 1 or 0.8, not reachable
		local ruleSet = btn.cwRule and btn.cwRule.set
		local slotTaken = {}

		-- The assignment chain's pick comes first: it is the buff the player decided this unit needs.
		-- It takes its exclusive slot even if another of the player's slot spells is already up (the
		-- assignment says to replace it).
		local chain = btn.cwChain and info[btn.cwChain]
		if chain then
			if chain.slot then slotTaken[chain.slot] = true end
			show(chain, base, greyed)
		end

		-- The buff the walk stopped at (the player's own) is what a click re-casts: when it is about to
		-- run out it pulses. Skipped when the pick above replaces it anyway (same exclusive slot).
		local done = btn.cwDone and info[btn.cwDone]
		if done and expiring[done.key] and shown < MAX_ICONS and not (done.slot and slotTaken[done.slot]) then
			if done.slot then slotTaken[done.slot] = true end
			show(done, base, greyed, expiring[done.key])
		end

		-- Pass 1: everything that needs attention - missing tracked buffs and the player's own buffs that
		-- are about to expire (groups named in the unit's rule are decided by the chain above). They come
		-- before satisfied ones so satisfied icons can never push them out of the limited icon slots. A
		-- group whose spell shares an exclusive slot is skipped when the player already has another spell
		-- of that slot on the unit, or when an earlier group took it.
		for _, group in ipairs(tracked) do
			if shown < MAX_ICONS and not (ruleSet and ruleSet[group.key]) then
				local slot, key = group.slot, group.key
				if not state[key] then
					if not (slot and (slots[slot] or slotTaken[slot])) then
						if slot then slotTaken[slot] = true end
						show(group, base, greyed)
					end
				elseif expiring[key] then
					if not (slot and ((slots[slot] and slots[slot] ~= key) or slotTaken[slot])) then
						if slot then slotTaken[slot] = true end
						show(group, base, greyed, expiring[key])
					end
				end
			end
		end

		-- Pass 2: satisfied buffs, dimmed, only when asked for and only in the remaining space (the ones
		-- already drawn as an expiry warning are skipped).
		if showSatisfied then
			for _, group in ipairs(tracked) do
				if state[group.key] and not expiring[group.key] and shown < MAX_ICONS then
					show(group, 0.35, false)
				end
			end
		end
	end
	for i = shown + 1, MAX_ICONS do
		icons[i]:Hide()
	end
end

-- One animation step for a button in `watch` (see the header comment).
function Buffs:Tick(btn, now, dt)
	local icons = btn.cwBuffIcons
	if not icons then
		watch[btn] = nil
		return
	end
	if btn.cwWarnAt and now >= btn.cwWarnAt then
		self:UpdateButton(btn, true) -- a buff just entered its warning window
		return
	end
	local gone = false
	for i = 1, MAX_ICONS do
		local tex = icons[i]
		local expires = tex.cwExpires
		if expires then
			local left = expires - now
			if left > 0 then
				tex.cwPhase = (tex.cwPhase + dt / self.FlashPeriod(left, warnSeconds)) % 1
				tex:SetAlpha(tex.cwBase * self.FlashAlpha(tex.cwPhase))
			else
				tex:SetAlpha(tex.cwBase) -- ran out: solid, exactly like the missing icon that replaces it
				gone = true
			end
		end
	end
	if gone and now - (btn.cwRescanAt or 0) >= RESCAN_GAP then
		btn.cwRescanAt = now
		self:UpdateButton(btn, true) -- normally UNIT_AURA got here first; this is the safety net
	end
end

-- keepRule: the unit did not change (an aura event), so the cached rule for it is still right.
function Buffs:UpdateButton(btn, keepRule)
	if not keepRule then
		btn.cwRule = self:FindRule(btn.unit)
	end
	self:Scan(btn)
	self:Paint(btn)
	-- the unit or the assigned pick may have changed: gated / assigned click macros are built from them
	CW.ClickCast:Sync(btn)
end

function Buffs:RefreshAll()
	self:Rebuild()
	for btn in pairs(CW.UnitFrame.frames) do
		if btn.cwBuffIcons then
			self:LayoutButton(btn)
			self:UpdateButton(btn)
		end
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
function Buffs:FlushDirty()
	flushScheduled = false
	local guidFrames = CW.UnitFrame.guidFrames
	for guid in pairs(dirty) do
		dirty[guid] = nil
		local set = guidFrames[guid]
		if set then
			for btn in pairs(set) do
				self:UpdateButton(btn, true)
			end
		end
	end
end

function Buffs:OnUnitAura(_, unit)
	if type(unit) ~= "string" then return end
	local guid = UnitGUID(unit)
	if not guid or not CW.UnitFrame.guidFrames[guid] then return end
	dirty[guid] = true
	if not flushScheduled then
		flushScheduled = true
		self:ScheduleTimer("FlushDirty", FLUSH_DELAY)
	end
end

-- The expiry driver: a plain non-secure frame whose OnUpdate only runs while it is shown, i.e. while some
-- button is in `watch`.
function Buffs:CreateDriver()
	if self.driver then return end
	local driver = CreateFrame("Frame")
	local acc = 0
	driver:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc < TICK then return end
		local dt = acc
		acc = 0
		local now = GetTime()
		for btn in pairs(watch) do
			Buffs:Tick(btn, now, dt)
		end
	end)
	driver:Hide()
	self.driver = driver
end

function Buffs:OnEnable()
	self:CreateDriver()
	self:ResolveNames()
	self:RegisterEvent("UNIT_AURA", "OnUnitAura")
	self:RegisterMessage("CLICKWISE_SETTINGS", "RefreshAll")
	self:RegisterMessage("CLICKWISE_BUFFS_CHANGED", "RefreshAll")
	self:RegisterMessage("CLICKWISE_SPELLS_CHANGED", function()
		Buffs:ResolveNames()
		Buffs:RefreshAll()
	end)
	self:RefreshAll()
end
