-- Clickwise: compatibility helpers. Loaded first (see .toc order); everything here must
-- only use APIs that exist on the WotLK 3.3.5 client (Interface 30300).
-- Retail / Classic-era APIs (C_*, SetColorTexture, SetAtlas, BackdropTemplate, IsInRaid,
-- GetNumGroupMembers, ...) are deliberately never referenced in this addon.

Clickwise = Clickwise or {}
local CW = Clickwise

local _, _, _, tocVersion = GetBuildInfo()
tocVersion = tonumber(tocVersion) or 0
CW.tocVersion = tocVersion
CW.isSupportedClient = (tocVersion >= 30300 and tocVersion < 30400)

local tonumber, type, pcall, select = tonumber, type, pcall, select
local strformat = string.format
local GetNumRaidMembers, GetNumPartyMembers = GetNumRaidMembers, GetNumPartyMembers

--------------------------------------------------------------------------------
-- Error surfacing. Errors thrown from background/event contexts can go missing in the
-- default UI (see lessonslearned.md "Silent failure signature"); route them explicitly.
--------------------------------------------------------------------------------
function CW.Try(func, ...)
	local ok, err = pcall(func, ...)
	if not ok then
		geterrorhandler()(err)
	end
	return ok
end

--------------------------------------------------------------------------------
-- Group API (3.3.5 has no IsInRaid / IsInGroup / GetNumGroupMembers)
--------------------------------------------------------------------------------
function CW.IsInRaid()
	return GetNumRaidMembers() > 0
end

function CW.IsInGroup()
	return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

-- Returns "raid", "party" or "solo".
function CW.GetGroupType()
	if GetNumRaidMembers() > 0 then
		return "raid"
	elseif GetNumPartyMembers() > 0 then
		return "party"
	end
	return "solo"
end

--------------------------------------------------------------------------------
-- Textures / colors
--------------------------------------------------------------------------------
-- SetColorTexture does not exist on 3.3.5; the old SetTexture(r,g,b,a) form does.
function CW.SetSolidColor(tex, r, g, b, a)
	if tex.SetColorTexture then
		tex:SetColorTexture(r, g, b, a or 1)
	else
		tex:SetTexture(r, g, b, a or 1)
	end
end

local FALLBACK_COLOR = {r = 0.6, g = 0.6, b = 0.6}
function CW.GetClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then
		return c.r, c.g, c.b
	end
	return FALLBACK_COLOR.r, FALLBACK_COLOR.g, FALLBACK_COLOR.b
end

--------------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------------
-- Truncate to at most maxChars characters without cutting a UTF-8 sequence in half.
function CW.TruncateUTF8(str, maxChars)
	if not str then return "" end
	if maxChars < 1 then return "" end
	local len, i, n = #str, 1, 0
	while i <= len do
		n = n + 1
		if n > maxChars then
			return str:sub(1, i - 1)
		end
		local b = str:byte(i)
		if b < 0x80 then
			i = i + 1
		elseif b < 0xE0 then
			i = i + 2
		elseif b < 0xF0 then
			i = i + 3
		else
			i = i + 4
		end
	end
	return str
end

function CW.FormatNumber(n)
	if n >= 10000 then
		return strformat("%.0fk", n / 1000)
	elseif n >= 1000 then
		return strformat("%.1fk", n / 1000)
	end
	return strformat("%d", n)
end

--------------------------------------------------------------------------------
-- Spellbook cache. GetSpellInfo(name) is not a reliable "is this spell known" test on
-- 3.3.5, so scan the spellbook. Rebuilt on SPELLS_CHANGED (see Core.lua).
--------------------------------------------------------------------------------
CW.knownSpells = {}
CW.spellRank = {}
CW.spellList = {} -- sorted, de-duplicated names of non-passive spells (for the binding editor's picker)

function CW.RebuildSpellbook()
	local known, ranks, list = {}, {}, {}
	for tab = 1, (GetNumSpellTabs() or 0) do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		if offset and numSpells then
			for i = offset + 1, offset + numSpells do
				local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
				if name then
					if not known[name] and not (IsPassiveSpell and IsPassiveSpell(i, BOOKTYPE_SPELL)) then
						list[#list + 1] = name
					end
					known[name] = true
					ranks[name] = rank -- highest rank is listed last, so last one wins
				end
			end
		end
	end
	table.sort(list)
	CW.knownSpells = known
	CW.spellRank = ranks
	CW.spellList = list
end

function CW.KnowsSpell(name)
	return name and CW.knownSpells[name] or false
end

--------------------------------------------------------------------------------
-- Roles.
-- 3.3.5 has UnitGroupRolesAssigned(unit) but it returns THREE BOOLEANS
-- (isTank, isHealer, isDamage) and is only populated for LFD groups.
-- Chain: LFD role -> raid Main Tank assignment -> class shortcut -> LibGroupTalents.
-- Returns "TANK", "HEALER", "DAMAGER" or nil when unknown.
--------------------------------------------------------------------------------
local LGT
local LGT_ROLE = {tank = "TANK", healer = "HEALER", melee = "DAMAGER", caster = "DAMAGER"}
local PURE_DAMAGE = {HUNTER = true, MAGE = true, ROGUE = true, WARLOCK = true}

function CW.GetUnitRole(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return nil
	end

	if UnitGroupRolesAssigned then
		local isTank, isHealer, isDamage = UnitGroupRolesAssigned(unit)
		if isTank then
			return "TANK"
		elseif isHealer then
			return "HEALER"
		elseif isDamage then
			return "DAMAGER"
		end
	end

	local name = UnitName(unit)
	if name and GetPartyAssignment and GetPartyAssignment("MAINTANK", name, 1) then
		return "TANK"
	end

	local _, class = UnitClass(unit)
	if class and PURE_DAMAGE[class] then
		return "DAMAGER"
	end

	if LGT == nil then
		LGT = LibStub("LibGroupTalents-1.0", true) or false
	end
	if LGT then
		return LGT_ROLE[LGT:GetUnitRole(unit) or ""]
	end
	return nil
end
