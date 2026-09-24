-- Smart mode: named rule sets a click can run. A set is an ordered list of rules
--   IF <conditions, all of them or any of them> THEN <action>
-- plus an optional "otherwise" action. The first rule that holds wins. A binding of type "smart" names a set.
--
-- A set compiles, per unit frame, into the clauses of ONE `/cast [a,b,target=unit] X; [c,target=unit] Y` line (a comma is
-- AND, the semicolon between clauses is "first match wins", and `[a][b]` is OR). The macro is a secure attribute, so it can
-- only be written out of combat, and that decides which conditions can exist. Three kinds:
--   live      a macro conditional the client tests when you click (dead, my combat state, my talent spec, my form...).
--             Works in combat, because the client decides at click time, not us.
--   stable    Lua decides while compiling (the unit's role, class, whether it is me). It cannot change during a fight, so
--             the result is folded into the macro and the rule keeps working in combat.
--   volatile  Lua decides while compiling, and the answer can change any second (a buff / debuff on the unit). Folded in
--             too, but the clause also carries [nocombat]: a frozen "this unit has a Magic debuff" would still be there
--             after the debuff is gone (the cure click of round 10 drew the same line). In combat such a rule is skipped.
-- Health ("unit's health is below N%") is a volatile condition like an aura: a macro cannot read health and the restricted
-- environment has no health function either, so the answer is Lua's, folded in while the click is written (out of combat) and
-- gated with [nocombat]. It is only ever right out of combat, and the editor says so. Its events are UNIT_HEALTH / UNIT_MAXHEALTH.
-- "Unit is in combat" is the same kind of volatile condition, for the same reason ClickCast.lua gates a click on combat: only
-- `[combat]` / `[nocombat]` exist, and they test the PLAYER, never another unit. There is no reliable per-unit combat-flag event
-- on 3.3.5 either, so this reuses ClickCast's own 0.5s poll (`btn.cwUnitCombat`) instead of a second one: the condition just
-- reads that field, and ClickCast is told to keep polling while any used set has a rule that reads it (see HasGatedBinding).
--
-- One more thing a rule can carry: the action "run saved macro N" (a macro of the macro frame, picked by name). A macro is many
-- lines and does not fit a /cast clause, so it runs through a hidden secure button of ours ("ClickwiseMacroN", macrotext = the
-- macro's body, rewritten out of combat when the macro changes) and the rule becomes a `/click [conds] ClickwiseMacroN` line.
-- The click's lines then run one after another with a `/stopmacro <what fired so far>` between them, so the first rule that
-- holds still wins: /cast [a] X; [b] Y / stopmacro [a][b] / click [c] Btn / stopmacro [c] / cast [d] Z.
-- [belief] `/click` may name a secure button, and `/stopmacro [conds]` exists, in a secure macro on 3.3.5;
-- `/cw buffcheck` looks for both commands.
--
-- The action "apply assigned buffs" casts whatever the Assignments tab (Buffs.lua) would cast for the unit: its own per-unit
-- scan already picks the spell (btn.cwAssignedSpell, the same field the Bindings tab's "Assigned buff" click reads), so this
-- action needs no macro/click plumbing of its own.
--
-- Compiling folds the frozen conditions away: an all-of rule with a false frozen condition is dropped, an any-of rule keeps
-- one bracket per branch that can still hold, and a clause that ends up with nothing to test (only target=) is
-- unconditional, which ends the macro: the rules behind it can never be reached.
--
-- [belief] `[spec:N]`, `[form:N]` and `[group:raid]` are understood by the 3.3.5 client, and a macro line over 255
-- characters is cut. `/cw buffcheck` tests the first; the second is why a set stops adding clauses at MACRO_LIMIT and says so.

local CW = Clickwise
local Smart = CW:NewModule("Smart", "AceEvent-3.0", "AceTimer-3.0")
CW.Smart = Smart

local L = LibStub("AceLocale-3.0"):GetLocale("Clickwise")
local pairs, ipairs, type, tostring, tonumber, next = pairs, ipairs, type, tostring, tonumber, next
local tinsert, tremove, concat, sort = table.insert, table.remove, table.concat, table.sort
local lower, upper = string.lower, string.upper
-- unit queries come from CW.API so that Test.lua's invented units answer them (see Compat.lua)
local API = CW.API
local UnitAura, UnitClass, UnitIsUnit, UnitGUID = API.UnitAura, API.UnitClass, API.UnitIsUnit, API.UnitGUID
local UnitHealth, UnitHealthMax, UnitIsDeadOrGhost, UnitIsConnected = API.UnitHealth, API.UnitHealthMax, API.UnitIsDeadOrGhost, API.UnitIsConnected

Smart.MACRO_LIMIT = 255 -- the longest macro line taken as safe (also the most the whole click text is allowed: see Compile)
Smart.BUDGET = Smart.MACRO_LIMIT - 4 -- what a set alone may use in Compile's count (a clause = its length + 2): "/cast " + the clauses = at most the limit
Smart.MAX_CONDS = 4     -- conditions one rule can hold (the editor has that many rows)
Smart.MAX_RULES = 8     -- rules one set can hold: the macro line has no room for many more clauses anyway
local FLUSH_DELAY = 0.2 -- UNIT_AURA / UNIT_HEALTH are spammy in raids; coalesce per GUID (as Buffs.lua does)

--------------------------------------------------------------------------------
-- The condition catalog: one entry per condition, so a new one is one more line.
--   key, text (reads after "IF"), kind = "live" | "stable" | "volatile"
--   arg = nil | "choice" (choices = {{value =, label =}, ...}) | "text" (a name typed by the player)
--   live:   frag = the macro conditional ("%s" takes the argument); unit = true when it tests the clicked unit
--   frozen: test(btn, unit, arg) -> boolean; watch = "health" for a volatile one that follows the unit's health (else its auras)
--------------------------------------------------------------------------------
local CLASSES = {
	{"WARRIOR", "Warrior"}, {"PALADIN", "Paladin"}, {"HUNTER", "Hunter"}, {"ROGUE", "Rogue"}, {"PRIEST", "Priest"},
	{"DEATHKNIGHT", "Death Knight"}, {"SHAMAN", "Shaman"}, {"MAGE", "Mage"}, {"WARLOCK", "Warlock"}, {"DRUID", "Druid"},
}
local classChoices = {}
for _, c in ipairs(CLASSES) do
	classChoices[#classChoices + 1] = {value = c[1], label = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[c[1]]) or c[2]}
end

local specChoices = {{value = "1", label = "1"}, {value = "2", label = "2"}}
local formChoices = {{value = "0", label = L["none"]}}
for i = 1, 6 do formChoices[#formChoices + 1] = {value = tostring(i), label = (L["number %d"]):format(i)} end

local healthChoices = {}
for pct = 10, 90, 10 do healthChoices[#healthChoices + 1] = {value = tostring(pct), label = pct .. "%"} end

-- Is the unit's health below `arg` percent? A dead, ghost or offline unit has no health to be low: never "below".
local function HealthBelow(unit, arg)
	local limit = tonumber(arg)
	if not limit or not UnitIsConnected(unit) or UnitIsDeadOrGhost(unit) then return false end
	local cur, max = UnitHealth(unit), UnitHealthMax(unit)
	if not (cur and max and max > 0) then return false end
	return cur / max * 100 < limit
end

-- Does the unit carry an aura for which match(name, debuffType, caster) is true?
local function HasAura(unit, filter, match)
	for i = 1, 40 do
		local name, _, _, _, debuffType, _, _, caster = UnitAura(unit, i, filter)
		if not name then return false end
		if match(name, debuffType, caster) then return true end
	end
	return false
end

local function SameName(a, b) return type(a) == "string" and type(b) == "string" and lower(a) == lower(b) end

Smart.CONDITIONS = {
	{key = "dead", kind = "live", unit = true, frag = "dead", text = L["unit is dead"]},
	{key = "combat", kind = "live", frag = "combat", text = L["I am in combat"]},
	{key = "spec", kind = "live", frag = "spec:%s", arg = "choice", text = L["my spec is"], choices = specChoices},
	{key = "form", kind = "live", frag = "form:%s", arg = "choice", text = L["my form / stance is"], choices = formChoices},
	{key = "raid", kind = "live", frag = "group:raid", text = L["I am in a raid"]},

	{key = "role", kind = "stable", arg = "choice", text = L["unit's role is"],
		choices = {{value = "TANK", label = L["Tank"]}, {value = "HEALER", label = L["Healer"]}, {value = "DAMAGER", label = L["Damage"]}},
		test = function(_, unit, arg) return CW.GetUnitRole(unit) == arg end},
	{key = "class", kind = "stable", arg = "choice", text = L["unit's class is"], choices = classChoices,
		test = function(_, unit, arg) local _, class = UnitClass(unit) return class == arg end},
	{key = "self", kind = "stable", text = L["unit is me"],
		test = function(_, unit) return UnitIsUnit(unit, "player") and true or false end},

	{key = "health", kind = "volatile", watch = "health", arg = "choice", text = L["unit's health is below"], choices = healthChoices,
		test = function(_, unit, arg) return HealthBelow(unit, arg) end},
	{key = "unitcombat", kind = "volatile", watch = "unitcombat", text = L["unit is in combat"],
		test = function(btn) return btn.cwUnitCombat and true or false end},
	{key = "debuffcure", kind = "volatile", text = L["unit has a curable debuff"],
		test = function(_, unit)
			return HasAura(unit, "HARMFUL", function(_, debuffType) return debuffType and CW.Debuffs and CW.Debuffs:CanCure(debuffType) end)
		end},
	{key = "debufftype", kind = "volatile", arg = "choice", text = L["unit has debuff type"],
		choices = {{value = "Magic", label = L["Magic"]}, {value = "Curse", label = L["Curse"]},
			{value = "Disease", label = L["Disease"]}, {value = "Poison", label = L["Poison"]}},
		test = function(_, unit, arg) return HasAura(unit, "HARMFUL", function(_, debuffType) return debuffType == arg end) end},
	{key = "debuff", kind = "volatile", arg = "text", text = L["unit has debuff"],
		test = function(_, unit, arg) return HasAura(unit, "HARMFUL", function(name) return SameName(name, arg) end) end},
	{key = "buff", kind = "volatile", arg = "text", text = L["unit has buff"],
		test = function(_, unit, arg) return HasAura(unit, "HELPFUL", function(name) return SameName(name, arg) end) end},
	{key = "mybuff", kind = "volatile", arg = "text", text = L["unit has my buff"],
		test = function(_, unit, arg)
			return HasAura(unit, "HELPFUL", function(name, _, caster) return SameName(name, arg) and caster == "player" end)
		end},
}
local COND = {}
for _, def in ipairs(Smart.CONDITIONS) do COND[def.key] = def end
Smart.COND = COND

-- The actions a rule can run. (Cure and rez stay ordinary bindings for now: a spell of your own does the same job here.)
Smart.ACTIONS = {
	{value = "spell", label = L["Cast spell"]},
	{value = "buff", label = L["Buff group"]},
	{value = "taunt", label = L["Taunt"]},
	{value = "macro", label = L["Run macro"]},
	{value = "assigned", label = L["Assigned buff"]},
	{value = "none", label = L["Nothing"]}, -- for "otherwise" only: the set then ends without a fallback
}

--------------------------------------------------------------------------------
-- Saved macros (the macro frame's): picked by name, run through a hidden secure button of ours (see the header)
--------------------------------------------------------------------------------
-- {value = name, label = name, icon = texture}: the account-wide macros, then this character's.
function Smart.MacroList()
	local out = {}
	if not (GetNumMacros and GetMacroInfo) then return out end
	local numAccount, numChar = GetNumMacros()
	local first = (MAX_ACCOUNT_MACROS or 36) + 1
	local function add(index)
		local name, icon = GetMacroInfo(index)
		if name then out[#out + 1] = {value = name, label = name, icon = icon} end
	end
	for i = 1, numAccount or 0 do add(i) end
	for i = first, first - 1 + (numChar or 0) do add(i) end
	return out
end

-- The macro's text for a secure button: no #show / #showtooltip lines (the macro frame's own comments), no blank lines.
function Smart.MacroBody(name)
	if not (name and name ~= "" and GetMacroIndexByName) then return nil end
	local index = GetMacroIndexByName(name)
	if not index or index == 0 then return nil end
	local _, _, body = GetMacroInfo(index)
	if not body then return nil end
	local lines = {}
	for line in (body:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		if line:find("%S") and line:sub(1, 1) ~= "#" then lines[#lines + 1] = line end
	end
	if #lines == 0 then return nil end
	return concat(lines, "\n")
end

local macroButtons, macroCount = {}, 0 -- [macro name] = {name = frame name, frame = the button, body = the text it runs (nil: cleared)}

-- The name of the secure button that runs the macro, or nil while it has none (not set up yet, or the macro is gone).
function Smart.MacroButton(name)
	local entry = macroButtons[name]
	return entry and entry.body and entry.name or nil
end

local function Cap(s) return (s:gsub("^%l", upper)) end
Smart.Cap = Cap

local function ChoiceLabel(def, value)
	for _, choice in ipairs(def.choices or {}) do
		if choice.value == value then return choice.label end
	end
	return tostring(value)
end

-- "NOT the unit's role is Tank", "the unit has the buff Renew"
function Smart.CondText(cond)
	local def = COND[cond.key]
	if not def then return "?" .. tostring(cond.key) end
	local text = def.text
	if def.arg == "choice" then
		text = text .. " " .. ChoiceLabel(def, cond.arg)
	elseif def.arg == "text" then
		text = text .. " " .. (cond.arg and cond.arg ~= "" and cond.arg or "?")
	end
	return (cond.neg and (L["NOT"] .. " ") or "") .. text
end

function Smart.ActionText(action)
	if not action then return L["nothing"] end
	if action.type == "spell" then return action.spell or "?" end
	if action.type == "buff" then
		local group = CW.Buffs:GetGroup(action.group)
		return L["Buff"] .. ": " .. (group and group.label or tostring(action.group))
	end
	if action.type == "taunt" then
		local spell = CW.ClickCast:TauntSpell()
		return L["Taunt"] .. (spell and (": " .. spell) or "")
	end
	if action.type == "macro" then return L["Macro"] .. ": " .. (action.macro or "?") end
	if action.type == "assigned" then return L["Assigned buff"] end
	return L["nothing"]
end

-- The conditions of a rule or a group in words: "IF a AND b" ("" for none)
local function CondsText(rule)
	local parts = {}
	for _, cond in ipairs(rule.conds or {}) do parts[#parts + 1] = Smart.CondText(cond) end
	if #parts == 0 then return "" end
	return L["IF"] .. " " .. concat(parts, " " .. (rule.mode == "any" and L["OR"] or L["AND"]) .. " ")
end
Smart.CondsText = CondsText

-- "IF a AND b THEN X"
function Smart.RuleText(rule)
	local ifText = CondsText(rule)
	return (ifText ~= "" and (ifText .. " ") or "") .. L["THEN"] .. " " .. Smart.ActionText(rule.action)
end

--------------------------------------------------------------------------------
-- The saved sets: profile.smartSets[CLASS][name] = {rules = {{mode = "all"|"any", conds = {{key, arg, neg}}, action = {type, ...}}}, otherwise = action}
-- Per class like the bindings (a set names spells, and the profile is shared between characters).
--------------------------------------------------------------------------------
local function ClassKey()
	local _, class = UnitClass("player")
	return class
end

function Smart:Sets()
	local profile = CW.db.profile
	if type(profile.smartSets) ~= "table" then profile.smartSets = {} end
	local key = ClassKey()
	if type(profile.smartSets[key]) ~= "table" then profile.smartSets[key] = {} end
	return profile.smartSets[key]
end

function Smart:GetSet(name)
	return name and self:Sets()[name] or nil
end

function Smart:SetNames()
	local out = {}
	for name in pairs(self:Sets()) do out[#out + 1] = name end
	sort(out)
	return out
end

-- The bindings (this class's list) that run a set.
function Smart:BindingsUsing(name)
	local out = {}
	for _, b in ipairs(CW.ClickCast:GetBindings()) do
		if b.type == "smart" and b.set == name then out[#out + 1] = b end
	end
	return out
end

-- The set names bindings use now, and whether any of their rules looks at auras (then UNIT_AURA matters), at
-- health (then UNIT_HEALTH does), or at another unit's combat state (then ClickCast must keep polling it).
function Smart:RefreshUsed()
	local used, seen, auras, health, unitCombat = {}, {}, false, false, false
	local function look(conds)
		for _, cond in ipairs(conds or {}) do
			local def = COND[cond.key]
			if def and def.kind == "volatile" then
				if def.watch == "health" then health = true
				elseif def.watch == "unitcombat" then unitCombat = true
				else auras = true end
			end
		end
	end
	for _, b in ipairs(CW.ClickCast:GetBindings()) do
		if b.type == "smart" and b.set and not seen[b.set] then
			seen[b.set] = true
			used[#used + 1] = b.set
			local set = self:GetSet(b.set)
			for _, rule in ipairs(set and set.rules or {}) do look(rule.conds) end
		end
	end
	sort(used)
	self.used, self.usesAuras, self.usesHealth, self.usesUnitCombat = used, auras, health, unitCombat
end

-- Something about the sets changed: the clicks are rewritten (out of combat, like every binding change).
function Smart:Changed()
	CW.ClickCast:ApplyAll()
end

local function Trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
Smart.Trim = Trim

-- Returns true, or false and the reason.
function Smart:CreateSet(name)
	name = Trim(name)
	if name == "" then return false, L["Type a name for the set."] end
	if #name > 24 then return false, L["That name is too long (24 characters at most)."] end
	if self:Sets()[name] then return false, L["A set with that name exists."] end
	self:Sets()[name] = {rules = {}}
	return true
end

-- Refused while a binding runs the set (deleting it would leave that click doing nothing): returns false and the bindings.
function Smart:DeleteSet(name)
	local using = self:BindingsUsing(name)
	if #using > 0 then return false, using end
	self:Sets()[name] = nil
	return true
end

function Smart:RenameSet(old, new)
	new = Trim(new)
	local sets = self:Sets()
	if not sets[old] then return false, L["No such set."] end
	if new == "" then return false, L["Type a name for the set."] end
	if #new > 24 then return false, L["That name is too long (24 characters at most)."] end
	if new == old then return true end
	if sets[new] then return false, L["A set with that name exists."] end
	sets[new], sets[old] = sets[old], nil
	for _, b in ipairs(CW.ClickCast:GetBindings()) do
		if b.type == "smart" and b.set == old then b.set = new end
	end
	self:Changed()
	return true
end

-- A rule as stored: empty condition rows dropped, values copied (the editor keeps editing its own copy).
function Smart.CleanRule(rule)
	local out = {mode = rule.mode == "any" and "any" or "all", conds = {}, action = {}}
	for _, cond in ipairs(rule.conds or {}) do
		if cond.key and COND[cond.key] then
			out.conds[#out.conds + 1] = {key = cond.key, arg = cond.arg, neg = cond.neg and true or nil}
		end
		if #out.conds >= Smart.MAX_CONDS then break end
	end
	for k, v in pairs(rule.action or {}) do out.action[k] = v end
	return out
end

-- Save a rule at `index` (nil: at the end). Returns the index.
function Smart:SaveRule(name, index, rule)
	local set = self:GetSet(name)
	if not set then return nil end
	rule = Smart.CleanRule(rule)
	if index and set.rules[index] then
		set.rules[index] = rule
	else
		if #set.rules >= Smart.MAX_RULES then return nil, (L["A set holds at most %d rules."]):format(Smart.MAX_RULES) end
		index = #set.rules + 1
		set.rules[index] = rule
	end
	self:Changed()
	return index
end

function Smart:DeleteRule(name, index)
	local set = self:GetSet(name)
	if not (set and set.rules[index]) then return false end
	tremove(set.rules, index)
	self:Changed()
	return true
end

-- Move a rule up (-1) or down (+1); returns its new index.
function Smart:MoveRule(name, index, delta)
	local set = self:GetSet(name)
	local target = index + delta
	if not (set and set.rules[index] and set.rules[target]) then return index end
	set.rules[index], set.rules[target] = set.rules[target], set.rules[index]
	self:Changed()
	return target
end

-- The fallback: an action table, or nil for none.
function Smart:SetOtherwise(name, action)
	local set = self:GetSet(name)
	if not set then return false end
	if action and action.type == "none" then action = nil end
	set.otherwise = action and Smart.CleanRule({action = action}).action or nil
	self:Changed()
	return true
end

--------------------------------------------------------------------------------
-- Compiling
--------------------------------------------------------------------------------
-- The spell an action casts, and (for a taunt) what to append to each bracket; or nil and the reason. A macro action gives
-- the name of its secure button and a fourth result, true: the rule is a `/click` line, not a clause of the /cast line.
local function ActionInfo(action, unit, btn)
	if type(action) ~= "table" then return nil, L["no action"] end
	if action.type == "spell" then
		if not action.spell or action.spell == "" then return nil, L["no spell named"] end
		if not CW.KnowsSpell(action.spell) then return nil, (L["%s is not in your spellbook"]):format(action.spell) end
		return action.spell, nil, unit
	elseif action.type == "buff" then
		local spell = action.group and CW.Buffs:GetCastSpell(action.group)
		if not spell then return nil, L["you know no spell of that buff group"] end
		return spell, nil, unit
	elseif action.type == "taunt" then
		local spell = CW.ClickCast:TauntSpell()
		if not spell then return nil, L["you know no taunt spell"] end
		-- a taunt aims at the enemy the unit is targeting, and needs one
		return spell, ",harm,nodead", CW.ClickCast.TauntTarget(unit)
	elseif action.type == "macro" then
		if not action.macro or action.macro == "" then return nil, L["no macro named"] end
		if not Smart.MacroBody(action.macro) then return nil, (L["no saved macro named %s"]):format(action.macro) end
		local button = Smart.MacroButton(action.macro)
		if not button then return nil, L["the macro has no button yet (it is set up out of combat)"] end
		return button, nil, unit, true
	elseif action.type == "assigned" then
		local pick = btn and btn.cwAssignedSpell
		if not pick then return nil, L["nothing is assigned to this unit right now"] end
		return pick, nil, unit
	end
	return nil, L["no action"]
end

-- One bracket: "[nocombat,target=party2,dead]"
local function Bracket(gate, target, parts, extra)
	local list = {}
	if gate then list[#list + 1] = "nocombat" end
	list[#list + 1] = "target=" .. target
	for _, part in ipairs(parts) do list[#list + 1] = part end
	return "[" .. concat(list, ",") .. (extra or "") .. "]"
end

-- The leading brackets of a clause ("[a][b] Spell" -> "[a][b]"): together they say "this clause fired".
local function LeadBrackets(clause)
	local out, pos = {}, 1
	while true do
		local s, e = clause:find("^%[[^%]]*%]", pos)
		if not s then break end
		out[#out + 1] = clause:sub(s, e)
		pos = e + 1
	end
	return concat(out)
end

local function LeadAll(clauses)
	local out = {}
	for _, clause in ipairs(clauses) do out[#out + 1] = LeadBrackets(clause) end
	return concat(out)
end

-- The conditions of a rule (or group) as terms: a list of {gate, parts}, one term per bracket the rule can compile to (an
-- any-of rule has one per branch that can still hold; an all-of rule has one). `parts` are the live macro conditionals, `gate`
-- says that a volatile answer went in (the bracket then carries [nocombat]). An empty list means the rule cannot hold now.
local function AndTerms(a, b)
	local out = {}
	for _, x in ipairs(a) do
		for _, y in ipairs(b) do
			local parts = {}
			for _, part in ipairs(x.parts) do parts[#parts + 1] = part end
			for _, part in ipairs(y.parts) do parts[#parts + 1] = part end
			out[#out + 1] = {gate = x.gate or y.gate, parts = parts}
		end
	end
	return out
end

-- Returns the terms, or nil and why the rule cannot apply.
local function CondTerms(conds, mode, btn, unit, taunt)
	local any = mode == "any" and #conds > 0
	local terms = any and {} or {{gate = false, parts = {}}}
	for _, cond in ipairs(conds) do
		local def = COND[cond.key]
		if not def then return nil, L["a condition this version does not know"] end
		if def.arg and (cond.arg == nil or cond.arg == "") then return nil, (L["needs a value: %s"]):format(def.text) end
		local mine
		if def.kind == "live" then
			if def.unit and taunt then
				return nil, L["a taunt aims at the enemy, so a test of the unit itself (dead) cannot share its rule"]
			end
			local frag = def.arg and def.frag:format(cond.arg) or def.frag
			if cond.neg then frag = "no" .. frag end
			mine = {{gate = false, parts = {frag}}}
		else
			local holds = def.test(btn, unit, cond.arg) and true or false
			if cond.neg then holds = not holds end
			if holds then
				mine = {{gate = def.kind == "volatile", parts = {}}}
			elseif not any then
				return nil, (L["does not hold now: %s"]):format(Smart.CondText(cond))
			else
				mine = {}
			end
		end
		if any then
			for _, term in ipairs(mine) do terms[#terms + 1] = term end
		else
			terms = AndTerms(terms, mine)
		end
	end
	if #terms == 0 then return nil, L["none of its conditions holds now"] end
	return terms
end

-- The clause of one rule for this unit: text (nil when the rule cannot apply), terminal (nothing left to test, so the
-- macro ends here) and, when it cannot apply, why; the fourth result is true for a macro (a `/click` line).
local function CompileRule(rule, btn, unit)
	local spell, extra, target, click = ActionInfo(rule.action, unit, btn)
	if not spell then return nil, false, extra end
	local terms, why = CondTerms(rule.conds or {}, rule.mode, btn, unit, rule.action.type == "taunt")
	if not terms then return nil, false, why end
	local brackets = {}
	for _, term in ipairs(terms) do
		if not term.gate and #term.parts == 0 and not extra then
			return Bracket(false, target, {}) .. " " .. spell, true, nil, click -- one branch always holds: it stands for the whole rule
		end
		brackets[#brackets + 1] = Bracket(term.gate, target, term.parts, extra)
	end
	return concat(brackets) .. " " .. spell, false, nil, click
end

-- The lines that follow a click's first /cast line: `rest` = segments, each {click = true, text = "[..] Button"} or
-- {clauses = {...}}. Between two of them goes `/stopmacro <what the one before fired on>`, so a later rule only runs when no
-- earlier one did. `before` = the brackets of what the first line holds.
function Smart.RestLines(rest, before)
	local lines, prev = {}, before or ""
	for _, seg in ipairs(rest or {}) do
		if prev ~= "" then lines[#lines + 1] = "/stopmacro " .. prev end
		if seg.click then
			lines[#lines + 1] = "/click " .. seg.text
			prev = LeadBrackets(seg.text)
		else
			lines[#lines + 1] = "/cast " .. concat(seg.clauses, "; ")
			prev = LeadAll(seg.clauses)
		end
	end
	return lines
end

-- All the lines of a compiled set (as the click would get them when the set stands alone).
function Smart.Lines(clauses, rest)
	local lines = {}
	if #clauses > 0 then lines[1] = "/cast " .. concat(clauses, "; ") end
	for _, line in ipairs(Smart.RestLines(rest, LeadAll(clauses))) do lines[#lines + 1] = line end
	return lines
end

-- What a compiled set adds to the click's signature
function Smart.Signature(clauses, rest)
	return concat(clauses, ";") .. (rest and ("\n" .. concat(Smart.RestLines(rest, LeadAll(clauses)), "\n")) or "")
end

-- The brackets of what the click holds so far: the first line's clauses, or the last segment after it.
function Smart.PrevBrackets(first, rest)
	local last = rest and rest[#rest]
	if not last then return LeadAll(first) end
	return last.click and LeadBrackets(last.text) or LeadAll(last.clauses)
end

-- The clauses of a set for a unit frame. `budget` = the characters the set may use (a clause costs its length plus the
-- "; " before it; a `/click` line, a `/stopmacro` line and a new /cast line each cost their length plus a newline); a rule
-- that does not fit ends the set, and the dump says so. `before` = the brackets of what the click's line holds ahead of the
-- set (cure / rez clauses), which the first /stopmacro must name too.
-- Returns the clauses (up to the first macro), the lines for the dump, the segments after the first macro (nil when there is
-- none) and what was used of the budget.
function Smart:Compile(btn, name, budget, before)
	local clauses, notes, rest = {}, {}, nil
	local set = self:GetSet(name)
	local unit = btn and btn.unit
	if not set then
		notes[1] = (L["No such set: %s"]):format(tostring(name))
		return clauses, notes, nil, 0
	end
	if not unit then return clauses, notes, nil, 0 end
	local used = 0
	local function add(text, click)
		local cost
		if click or (rest and rest[#rest].click) then
			local prev = rest and Smart.PrevBrackets(clauses, rest) or ((before or "") .. LeadAll(clauses))
			cost = 1 + (prev ~= "" and (1 + #("/stopmacro " .. prev)) or 0) + #((click and "/click " or "/cast ") .. text)
		else
			cost = #text + 2
		end
		if budget and used + cost > budget then return false end
		if click then
			rest = rest or {}
			rest[#rest + 1] = {click = true, text = text}
		elseif rest then
			local last = rest[#rest]
			if last.click then rest[#rest + 1] = {clauses = {text}} else last.clauses[#last.clauses + 1] = text end
		else
			clauses[#clauses + 1] = text
		end
		used = used + cost
		return true
	end
	local stopped
	for i, rule in ipairs(set.rules) do
		local text, terminal, why, click = CompileRule(rule, btn, unit)
		if not text then
			notes[#notes + 1] = ("%d. %s  ->  %s: %s"):format(i, Smart.RuleText(rule), L["skipped"], why)
		elseif not add(text, click) then
			notes[#notes + 1] = ("%d. %s  ->  %s: %s"):format(i, Smart.RuleText(rule), L["dropped"], L["the macro line would be over the length limit"])
			stopped = true
			break
		else
			notes[#notes + 1] = ("%d. %s  ->  %s"):format(i, Smart.RuleText(rule), text)
			if terminal then
				stopped = true
				if i < #set.rules or set.otherwise then
					notes[#notes + 1] = L["Nothing after this rule can be reached: it holds for every click."]
				end
				break
			end
		end
	end
	if not stopped and set.otherwise then
		local spell, extra, target, click = ActionInfo(set.otherwise, unit, btn)
		if not spell then
			notes[#notes + 1] = (L["otherwise: %s  ->  skipped: %s"]):format(Smart.ActionText(set.otherwise), extra)
		else
			local text = Bracket(false, target, {}, extra) .. " " .. spell
			if add(text, click) then
				notes[#notes + 1] = (L["otherwise: %s  ->  %s"]):format(Smart.ActionText(set.otherwise), text)
			else
				notes[#notes + 1] = (L["otherwise: %s  ->  dropped: %s"]):format(Smart.ActionText(set.otherwise), L["the macro line would be over the length limit"])
			end
		end
	end
	return clauses, notes, rest, used
end

--------------------------------------------------------------------------------
-- Keeping the clicks current. A button remembers what its sets compile to (btn.cwSmartSig, part of ClickCast's
-- signature); when a frozen answer changes the click is rewritten, out of combat.
--------------------------------------------------------------------------------
-- Recompute the signature; returns whether it changed. Does not touch the click.
function Smart:Refresh(btn)
	local sig
	if self.used and #self.used > 0 and btn.unit then
		local parts = {}
		for _, name in ipairs(self.used) do
			local clauses, _, rest = self:Compile(btn, name)
			parts[#parts + 1] = name .. "=" .. Smart.Signature(clauses, rest)
		end
		sig = concat(parts, "|")
	end
	local changed = sig ~= btn.cwSmartSig
	btn.cwSmartSig = sig
	return changed
end

function Smart:UpdateButton(btn)
	if self:Refresh(btn) then CW.ClickCast:Sync(btn) end
end

-- What the sets compile to, for /cw smart: lines for one unit.
function Smart:DumpUnit(unit)
	local target
	for btn in pairs(CW.UnitFrame.frames) do
		if btn.unit and (btn.unit == unit or (UnitIsUnit(btn.unit, unit))) then target = btn break end
	end
	if not target then return {(L["No frame shows %s."]):format(tostring(unit))} end
	local lines = {}
	local names = self:SetNames()
	if #names == 0 then return {L["No smart sets yet: make one in the Smart tab."]} end
	for _, name in ipairs(names) do
		local users = self:BindingsUsing(name)
		local keys = {}
		for _, b in ipairs(users) do keys[#keys + 1] = (b.modifier or "") .. b.button end
		lines[#lines + 1] = (L["Set %s for %s (used by: %s)"]):format(name, target.unit, #keys > 0 and concat(keys, ", ") or L["no binding"])
		local clauses, notes, rest = self:Compile(target, name, self.BUDGET) -- (what the click has room for, alone)
		for _, note in ipairs(notes) do lines[#lines + 1] = "  " .. note end
		local text = Smart.Lines(clauses, rest)
		if #text == 1 then
			lines[#lines + 1] = ("  %s  (%d / %d)"):format(text[1], #text[1], self.MACRO_LIMIT)
		elseif #text > 1 then
			for _, line in ipairs(text) do lines[#lines + 1] = "  " .. line end
			lines[#lines + 1] = ("  (%d / %d)"):format(#concat(text, "\n"), self.MACRO_LIMIT)
		else
			lines[#lines + 1] = "  " .. L["Nothing applies to this unit right now: the click does its default (or nothing in combat)."]
		end
	end
	return lines
end

-- One line for /cw buffcheck: the two slash commands a macro rule's lines are made of (see the header).
local function CommandsLine()
	local list = SecureCmdList
	local missing = {}
	if not (list and list["CLICK"]) then missing[#missing + 1] = "/click" end
	if not (list and list["STOPMACRO"]) then missing[#missing + 1] = "/stopmacro" end
	if #missing == 0 then
		return "Smart mode macro rules: /click and /stopmacro are both secure macro commands on this client. (Only a click in game shows that /stopmacro takes conditions: with a spell rule and a macro rule that both hold, ONE may fire.)"
	end
	return "Smart mode macro rules will NOT work: this client has no secure " .. concat(missing, " or ") .. " command."
end

-- Lines for /cw buffcheck: does this client understand every live conditional the catalog can emit? A conditional and its
-- "no" form must give different answers; an unknown one gives the same (or nothing) for both.
function Smart:CheckConditionals()
	local lines = self:CheckConditionalList()
	lines[#lines + 1] = CommandsLine()
	return lines
end

function Smart:CheckConditionalList()
	if not SecureCmdOptionParse then return {"SecureCmdOptionParse is missing: cannot test the Smart mode macro conditionals."} end
	local bad, count = {}, 0
	for _, def in ipairs(self.CONDITIONS) do
		if def.kind == "live" then
			count = count + 1
			local frag = def.arg and def.frag:format(def.choices[1].value) or def.frag
			local at = def.unit and "target=player," or ""
			local yes = SecureCmdOptionParse("[" .. at .. frag .. "] Y; N")
			local no = SecureCmdOptionParse("[" .. at .. "no" .. frag .. "] Y; N")
			if not (yes and no and yes ~= no) then bad[#bad + 1] = "[" .. frag .. "]" end
		end
	end
	if #bad == 0 then
		return {("All %d Smart mode macro conditionals are understood by this client."):format(count)}
	end
	return {("Smart mode conditionals NOT understood by this client: %s. Rules using them will not work: remove them from the catalog in Smart.lua."):format(concat(bad, ", "))}
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local dirty, flushScheduled = {}, false

function Smart:FlushDirty()
	flushScheduled = false
	local guidFrames = CW.UnitFrame.guidFrames
	for guid in pairs(dirty) do
		dirty[guid] = nil
		local set = guidFrames[guid]
		if set then
			for btn in pairs(set) do self:UpdateButton(btn) end
		end
	end
end

-- A unit's auras / health changed: its frames are recompiled soon (once per burst of events)
local function MarkUnit(self, unit)
	if InCombatLockdown() then
		-- attributes are locked: recompiling now would be thrown away, and UNIT_HEALTH never stops in a raid fight. One refresh
		-- (every frame, re-read) is queued for the end of combat instead.
		if not self.combatRefresh then
			self.combatRefresh = true
			CW:RunOOC("smart.refresh", Smart.RefreshAfterCombat, Smart)
		end
		return
	end
	if type(unit) ~= "string" then return end
	local guid = UnitGUID(unit)
	if not guid or not CW.UnitFrame.guidFrames[guid] then return end
	dirty[guid] = true
	if not flushScheduled then
		flushScheduled = true
		self:ScheduleTimer("FlushDirty", FLUSH_DELAY)
	end
end

function Smart:RefreshAfterCombat()
	self.combatRefresh = false
	CW.ClickCast:RefreshDynamic() -- (re-reads every frame's answers, then rewrites the clicks that changed)
end

function Smart:OnUnitAura(_, unit)
	if self.usesAuras then MarkUnit(self, unit) end
end

function Smart:OnUnitHealth(_, unit)
	if self.usesHealth then MarkUnit(self, unit) end
end

-- Out of combat only (a secure button's attributes are locked in combat): every saved macro a set of this class runs (bound
-- or not: the editor shows what a set compiles to) gets a hidden secure button that runs its text, and a macro that changed
-- (or went) gets its button rewritten (or cleared).
function Smart:SyncMacros()
	local wanted = {}
	local function want(action)
		if action and action.type == "macro" and action.macro and action.macro ~= "" then wanted[action.macro] = true end
	end
	for _, set in pairs(self:Sets()) do
		for _, rule in ipairs(set.rules or {}) do want(rule.action) end
		want(set.otherwise)
	end
	self.hasMacros = next(wanted) ~= nil
	if InCombatLockdown() then return end
	for name in pairs(wanted) do
		local body = Smart.MacroBody(name)
		local entry = macroButtons[name]
		if body and not entry then
			macroCount = macroCount + 1
			local frameName = "ClickwiseMacro" .. macroCount
			entry = {name = frameName, frame = CreateFrame("Button", frameName, UIParent, "SecureActionButtonTemplate")}
			macroButtons[name] = entry
		end
		if entry and entry.body ~= body then
			entry.frame:SetAttribute("type", body and "macro" or nil)
			entry.frame:SetAttribute("macrotext", body)
			entry.body = body
		end
	end
	for name, entry in pairs(macroButtons) do
		if not wanted[name] and entry.body then -- no set runs it any more: nothing to keep
			entry.frame:SetAttribute("type", nil)
			entry.frame:SetAttribute("macrotext", nil)
			entry.body = nil
		end
	end
end

-- The macro frame changed (a macro edited, renamed, deleted): the buttons and the clicks that name them are rewritten.
function Smart:OnMacrosChanged()
	if self.hasMacros then self:Changed() end
end

function Smart:OnEnable()
	self:RegisterEvent("UNIT_AURA", "OnUnitAura")
	self:RegisterEvent("UNIT_HEALTH", "OnUnitHealth")
	self:RegisterEvent("UNIT_MAXHEALTH", "OnUnitHealth")
	self:RegisterEvent("UPDATE_MACROS", "OnMacrosChanged")
	self:RefreshUsed()
	self:SyncMacros() -- (out of combat at login; the macros may only arrive with UPDATE_MACROS, which then rewrites the clicks)
end
