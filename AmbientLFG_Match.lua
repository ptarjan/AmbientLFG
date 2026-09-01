local _, ns = ...

--------------------------------------------------------------------------------
-- Pure matching logic, extracted so it can be unit-tested outside the game
-- (tests/ loads this file standalone with a stub ns). No WoW API calls here;
-- issecretvalue is checked for existence so the guards no-op under plain Lua.
--------------------------------------------------------------------------------

local Match = {}
ns.Match = Match

Match.ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }
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

-- The one application status that means the player is now in the group they
-- went looking for. Not "invited": an invitation can be declined or time out,
-- and standing down on it would end the watch over a group never joined.
function Match.joinedGroup(status)
	return Match.safeStr(status) == "inviteaccepted"
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

-- The same character arrives as "Name" and as "Name-Realm" depending on when
-- the field streamed in, so a name is keyed and compared on its realm-stripped
-- form.
function Match.shortName(name)
	local s = Match.safeStr(name)
	return s:match("^([^%-]+)") or s
end

-- The line a raid-warning banner is given. Every field of a listing can arrive
-- as a secret value, and formatting one makes the whole line secret — Blizzard's
-- RaidWarning measures the line it is handed, so a secret line kills Blizzard's
-- own code doing arithmetic on the length. Anything unreadable is dropped, and
-- the leader's name stands in for a title that cannot be read.
function Match.alertLine(name, activity, leader)
	local title = Match.safeStr(name)
	local who = title ~= "" and ('"' .. title .. '"') or Match.shortName(leader)
	if who == "" then
		who = "a group"
	end
	local act = Match.safeStr(activity)
	return ("Group Finder: %s%s"):format(who, act ~= "" and (" — " .. act) or "")
end

-- Your own group's listing comes back in your own search results. It is not a
-- group to join, so it never alerts and never sits in the matches list. A
-- listing reports hasSelf, which is exactly this question; when that flag is
-- unreadable the listing is recognised by its leader being someone in your own
-- group. ownNames is nil unless a listing of yours is actually up, so with
-- nothing listed the name check cannot fire.
function Match.isOwnListing(hasSelf, leaderName, ownNames)
	if Match.safeBool(hasSelf) then
		return true
	end
	local leader = Match.shortName(leaderName):lower()
	if leader == "" then
		return false
	end
	for _, name in ipairs(ownNames or {}) do
		if Match.shortName(name):lower() == leader then
			return true
		end
	end
	return false
end

-- "lura" -> "l+u+r+a+" so doubled/stretched spellings (Lurra, Luraa) still
-- hit. Compiled once per word — this runs for every word × every listing.
-- Digits are fenced instead of stretched: a number means a quantity, so "+18"
-- must not run on into "+188" and "+2" must not swallow every key from +20 to
-- +29. A word's digits therefore match exactly, with a frontier at each end
-- so no further digit may sit beside them.
local patternCache = {}
function Match.fuzzyPattern(word)
	local pattern = patternCache[word]
	if not pattern then
		pattern = (word:lower():gsub("[%w%p]", function(c)
			if c:match("%d") then
				return c
			end
			return c:match("%w") and c .. "+" or "%" .. c .. "+"
		end))
		if word:match("^%d") then
			pattern = "%f[%d]" .. pattern
		end
		if word:match("%d$") then
			pattern = pattern .. "%f[%D]"
		end
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

-- 12.0: listing titles and comments arrive as kstrings — opaque |K…|k tokens
-- that the UI renders as text but that addons cannot read. A token's
-- characters are an id, not words, so matching against them can only ever
-- produce a false hit: a tokenized field contributes nothing, while a field
-- that is still plain text is matched as before.
function Match.matchableText(text)
	return text:find("^|K") and "" or text
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

-- Roles are stored as a set so the UI checkboxes and the slash command write
-- the same thing, and read back in a fixed order so the status line does not
-- reshuffle between /reloads.
function Match.rolesToList(roles)
	local list = {}
	for _, role in ipairs(Match.ROLE_ORDER) do
		if roles and roles[role] then
			list[#list + 1] = role
		end
	end
	return list
end

function Match.rolesToString(roles)
	local list = Match.rolesToList(roles)
	if #list == 0 then
		return "any role"
	end
	local parts = {}
	for _, role in ipairs(list) do
		parts[#parts + 1] = Match.ROLE_LABEL[role]
	end
	return table.concat(parts, ", ")
end

-- The Group Finder's "role available" boxes are a Dungeons filter — the game
-- drops them for every other category — so raid searches have no role filter of
-- their own and the addon keeps one. Its default is the role you are actually
-- playing, resolved live so a respec moves it instead of leaving a stale tick
-- behind; nil means "follow my spec", and an explicit set overrides it.
function Match.resolveRaidRoles(saved, role)
	if type(saved) == "table" then
		return saved
	end
	if role and Match.ROLE_LABEL[role] then
		return { [role] = true }
	end
	return {}
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

-- The addon watches whichever search the player last ran, so the only thing it
-- can say about that search is what the Search call carried: a category, and
-- the search box text the engine applies on top of it. The box is the ONLY way
-- a keystone level can be selected — a listing's title reaches an addon as an
-- opaque token even when the group typed it — so it is named here rather than
-- left as invisible state.
function Match.searchDescription(categoryID, boxText)
	local where = "Group Finder"
	if categoryID == Match.CATEGORY_DUNGEONS then
		where = "Dungeons"
	elseif categoryID == Match.CATEGORY_RAIDS then
		where = "Raids"
	end
	if boxText and boxText ~= "" then
		return ("%s, filtered by \"%s\""):format(where, boxText)
	end
	return where
end

-- A raid activity is named for its difficulty — "Manaforge Omega (Heroic)" —
-- and the search box's autocomplete matches those names, so typing "(hero" and
-- taking the entry it offers pins the search to that one activity. Nothing else
-- in the Group Finder filters a raid search by difficulty: the role boxes are a
-- Dungeons filter and the key-range parsing is a Dungeons behaviour. So a raid
-- search with no difficulty in the box is watching all four at once, which is
-- almost never what the player means, and the window says so.
Match.RAID_DIFFICULTIES = { "lfr", "normal", "heroic", "mythic" }

function Match.raidDifficultyHint(categoryID, boxText)
	if categoryID ~= Match.CATEGORY_RAIDS then
		return nil
	end
	local lower = (boxText or ""):lower()
	for _, difficulty in ipairs(Match.RAID_DIFFICULTIES) do
		-- four letters, so "(hero" and "heroic" both hit and neither has to be
		-- typed in full — the same prefix the autocomplete answers to
		if lower:find(difficulty:sub(1, 4), 1, true) then
			return ("%s only"):format(difficulty), true
		end
	end
	return "every difficulty — type \"(heroic\" or \"(mythic\" in the box and pick the entry it offers", false
end

-- While your own listing is up, background watching stands down: a group that
-- is already recruiting for you is not one to be alerted about, and the Group
-- Finder shows your applicants instead of the search panel, so "run a search
-- once to arm it" is advice that cannot be followed and reads as the addon
-- being broken. The game puts a Browse Groups button in that view for a party
-- leader and for nobody else.
function Match.listedBlockText(isLeader)
	local why = "your group is listed, so watching is paused until the listing is taken down"
	if isLeader then
		return why .. " — the Group Finder opens on your applicants, and \"Browse Groups\" there reaches the search"
	end
	return why .. " — the Group Finder shows applicants instead of the search"
end

-- The window says two things about one state: a status line naming what the
-- addon is doing, and — when the list is empty — the move that fills it. They
-- are decided in one pass so they cannot disagree; an empty list reading "no
-- matching groups right now" while the addon is switched off answers a question
-- nobody asked, and an empty list is exactly when someone needs telling.
--
-- Fields: enabled, listed (the block text, or nil), armed, browsing, suspended,
-- throttled (seconds left, or nil), pending, interval.
function Match.stateLines(s)
	if not s.enabled then
		return "|cffff6666Off|r",
			"Switched off — tick |cffffd100Enabled|r above and matches will start arriving"
	elseif s.listed then
		-- a live listing stops watching whether or not a search was ever armed,
		-- so it answers before "search once to arm it", which cannot be done
		return ("|cffffcc00Paused — %s|r"):format(s.listed),
			"Paused while your own group is listed — take the listing down to start watching again"
	elseif not s.armed then
		return "|cffffcc00Idle — fill in the Group Finder's search box and search once to arm it|r",
			"Nothing is being watched yet — open the Group Finder, type what you are after in the search box, and search once. The addon then replays that search for you."
	elseif s.browsing then
		-- silence here reads as the addon being broken; it is deliberate
		return "|cffffcc00Paused while the Group Finder is open|r — searching now would stomp the results you're looking at",
			"Nothing here while you are browsing — close the Group Finder and matches will start arriving"
	elseif s.suspended then
		return "|cffff6666Suspended — searches keep failing (Group Finder not usable right now?). Untick and retick to retry.|r",
			"Searches are failing — untick |cffffd100Enabled|r and tick it again to retry"
	elseif s.throttled then
		return ("|cffff9933Search throttled — pausing %ds|r"):format(s.throttled),
			"No matching groups right now — the next search is waiting out the game's throttle"
	elseif s.pending then
		return "|cff66ff66Search queued — fires on your next click in the world|r",
			"No matching groups right now — the next search fires on your next click or keypress"
	end
	return ("|cff66ff66Watching — searches every %ds, on your next click|r"):format(s.interval),
		"No matching groups right now — one appears here the moment it is listed. Nothing to do but play; you will get a banner."
end

return Match
