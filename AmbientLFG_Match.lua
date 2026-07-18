local _, ns = ...

--------------------------------------------------------------------------------
-- Pure matching logic, extracted so it can be unit-tested outside the game
-- (tests/ loads this file standalone with a stub ns). No WoW API calls here;
-- issecretvalue is checked for existence so the guards no-op under plain Lua.
--------------------------------------------------------------------------------

local Match = {}
ns.Match = Match

Match.ROLE_TOKENS = {
	tank = "TANK", tanks = "TANK",
	healer = "HEALER", heal = "HEALER", heals = "HEALER", healers = "HEALER",
	dps = "DAMAGER", dd = "DAMAGER", damager = "DAMAGER",
}
Match.ROLE_REMAINING = {
	TANK = "TANK_REMAINING",
	HEALER = "HEALER_REMAINING",
	DAMAGER = "DAMAGER_REMAINING",
}
Match.ROLE_LABEL = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

Match.CATEGORY_DUNGEONS = GROUP_FINDER_CATEGORY_ID_DUNGEONS or 2
Match.CATEGORY_RAIDS = 3

-- 12.0 secret values: any field off a search result can be secret; never
-- concatenate or compare one without guarding first.
function Match.safeStr(v)
	if v == nil or (issecretvalue and issecretvalue(v)) then
		return ""
	end
	return tostring(v)
end

function Match.safeBool(v)
	if issecretvalue and issecretvalue(v) then
		return false
	end
	return v
end

function Match.safeNum(v)
	if type(v) ~= "number" or (issecretvalue and issecretvalue(v)) then
		return nil
	end
	return v
end

-- "lura" -> "l+u+r+a+" so doubled/stretched spellings (Lurra, Luraa) still
-- hit. Compiled once per word — this runs for every word × every listing.
local patternCache = {}
function Match.fuzzyPattern(word)
	local pattern = patternCache[word]
	if not pattern then
		pattern = (word:lower():gsub("[%w%p]", function(c)
			return c:match("%w") and c .. "+" or "%" .. c .. "+"
		end))
		patternCache[word] = pattern
	end
	return pattern
end

-- Sellers dodge text filters with Unicode lookalikes (ＷＴＳ, 𝐖𝐓𝐒, ᴡᴛꜱ, ШТЅ);
-- map the common fancy-letter ranges back to ASCII before matching.
local HOMOGLYPHS = {
	-- Latin small caps / phonetic letters (ᴡᴛꜱ-style)
	[0x1D00] = 97, [0x0299] = 98, [0x1D04] = 99, [0x1D05] = 100, [0x1D07] = 101,
	[0xA730] = 102, [0x0262] = 103, [0x029C] = 104, [0x026A] = 105, [0x1D0A] = 106,
	[0x1D0B] = 107, [0x029F] = 108, [0x1D0D] = 109, [0x0274] = 110, [0x1D0F] = 111,
	[0x1D18] = 112, [0x0280] = 114, [0xA731] = 115, [0x1D1B] = 116, [0x1D1C] = 117,
	[0x1D20] = 118, [0x1D21] = 119, [0x028F] = 121, [0x1D22] = 122,
	-- Cyrillic lookalikes
	[0x0410] = 65, [0x0412] = 66, [0x0415] = 69, [0x041A] = 75, [0x041C] = 77,
	[0x041D] = 72, [0x041E] = 79, [0x0420] = 80, [0x0421] = 67, [0x0422] = 84,
	[0x0425] = 88, [0x0405] = 83, [0x0430] = 97, [0x0435] = 101, [0x043E] = 111,
	[0x0440] = 112, [0x0441] = 99, [0x0443] = 121, [0x0445] = 120, [0x0455] = 115,
	-- Greek lookalikes
	[0x0391] = 65, [0x0392] = 66, [0x0395] = 69, [0x0397] = 72, [0x0399] = 73,
	[0x039A] = 75, [0x039C] = 77, [0x039D] = 78, [0x039F] = 79, [0x03A1] = 80,
	[0x03A4] = 84, [0x03A5] = 89, [0x03A7] = 88, [0x03BF] = 111,
}

local function normalizeCodepoint(cp)
	local mapped = HOMOGLYPHS[cp]
	if mapped then
		return mapped
	end
	if cp >= 0xFF01 and cp <= 0xFF5E then return cp - 0xFEE0 end -- fullwidth
	if cp >= 0x24B6 and cp <= 0x24CF then return cp - 0x24B6 + 65 end -- circled A-Z
	if cp >= 0x24D0 and cp <= 0x24E9 then return cp - 0x24D0 + 97 end -- circled a-z
	if cp >= 0x1D400 and cp <= 0x1D7CB then -- mathematical bold/italic/script/etc
		local off = (cp - 0x1D400) % 52
		if off < 26 then return 65 + off end
		return 97 + off - 26
	end
	if cp >= 0x1D7CE and cp <= 0x1D7FF then return 48 + ((cp - 0x1D7CE) % 10) end -- math digits
	if cp >= 0x1F130 and cp <= 0x1F149 then return 65 + (cp - 0x1F130) end -- squared A-Z
	if cp >= 0x1F170 and cp <= 0x1F189 then return 65 + (cp - 0x1F170) end -- neg squared A-Z
	return nil
end

local function decodeUTF8(ch)
	local b1 = ch:byte(1)
	if b1 < 0x80 then
		return b1
	end
	local b2 = ch:byte(2) or 0
	if b1 < 0xE0 then
		return (b1 - 0xC0) * 0x40 + (b2 - 0x80)
	end
	local b3 = ch:byte(3) or 0
	if b1 < 0xF0 then
		return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
	end
	local b4 = ch:byte(4) or 0
	return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
end

function Match.normalizeText(text)
	return (text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
		if #ch == 1 then
			return ch
		end
		local mapped = normalizeCodepoint(decodeUTF8(ch))
		return mapped and string.char(mapped) or ch
	end))
end

-- Does any ignore word appear in the haystack? Also matches with all
-- separators stripped, so "W T S" / "W.T.S" hit "wts".
function Match.matchesIgnoreWord(haystack, ignores)
	local compact = haystack:gsub("[^%w]", "")
	for _, word in ipairs(ignores or {}) do
		local pattern = Match.fuzzyPattern(word)
		if haystack:find(pattern) or compact:find(pattern) then
			return word
		end
	end
end

function Match.ruleToString(rule)
	local parts = {}
	for _, w in ipairs(rule.words) do
		parts[#parts + 1] = w
	end
	for _, role in ipairs(rule.roles) do
		parts[#parts + 1] = "+" .. Match.ROLE_LABEL[role]
	end
	if rule.category == Match.CATEGORY_DUNGEONS then
		parts[#parts + 1] = "+dungeon"
	end
	return table.concat(parts, " ")
end

-- Raid listings have no per-role caps, so Blizzard's *_REMAINING counts are
-- effectively always positive there (a 2/4/14 raid still reports open tank
-- slots). Standard-composition thresholds are the meaningful check instead.
Match.ROLE_NEED = {
	[Match.CATEGORY_DUNGEONS] = { TANK = 1, HEALER = 1, DAMAGER = 3 },
	[Match.CATEGORY_RAIDS] = { TANK = 2, HEALER = 4, DAMAGER = math.huge },
}

function Match.roleIsOpen(role, counts, numMembers, categoryID, maxPlayers)
	if maxPlayers and maxPlayers > 0 and numMembers and numMembers >= maxPlayers then
		return false
	end
	local need = categoryID and Match.ROLE_NEED[categoryID] and Match.ROLE_NEED[categoryID][role]
	if need then
		local have = Match.safeNum(counts[role])
		-- unknown counts as open: a spurious alert beats a missed group
		return have == nil or have < need
	end
	local remaining = Match.safeNum(counts[Match.ROLE_REMAINING[role]])
	return remaining == nil or remaining > 0
end

function Match.parseRule(input)
	local rule = { words = {}, roles = {} }
	for token in input:gmatch("%S+") do
		local tag = token:match("^%+(%S+)$")
		if tag then
			tag = tag:lower()
			if tag == "raid" or tag == "raids" then
				rule.category = Match.CATEGORY_RAIDS
			elseif tag == "dungeon" or tag == "dungeons" or tag == "m+" or tag == "mplus" then
				rule.category = Match.CATEGORY_DUNGEONS
			elseif Match.ROLE_TOKENS[tag] then
				rule.roles[#rule.roles + 1] = Match.ROLE_TOKENS[tag]
			else
				return nil, ("unknown tag \"+%s\" (use +tank, +healer, +dps, +raid, +dungeon)"):format(tag)
			end
		else
			rule.words[#rule.words + 1] = token:lower()
		end
	end
	if #rule.words == 0 and #rule.roles == 0 then
		return nil, "empty rule"
	end
	return rule
end

return Match
