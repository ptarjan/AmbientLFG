local ADDON_NAME, ns = ...

local defaults = {
	enabled = true,
	rules = {},
	ignores = { "wts", "sell", "boost", "carry" },
	sound = true,
	flash = true,
	auto = false,
	interval = 10,
	debug = false,
	blockedLeaders = {},
}

local ROLE_TOKENS = {
	tank = "TANK", tanks = "TANK",
	healer = "HEALER", heal = "HEALER", heals = "HEALER", healers = "HEALER",
	dps = "DAMAGER", dd = "DAMAGER", damager = "DAMAGER",
}
local ROLE_REMAINING = {
	TANK = "TANK_REMAINING",
	HEALER = "HEALER_REMAINING",
	DAMAGER = "DAMAGER_REMAINING",
}
local ROLE_LABEL = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

local CATEGORY_DUNGEONS = GROUP_FINDER_CATEGORY_ID_DUNGEONS or 2
local CATEGORY_RAIDS = 3

local db
local frame = CreateFrame("Frame")
local ticker
local scanPending = false
local backoffUntil = 0
local alerted = {}
local activityNameCache = {}
local stats = { autoIssued = 0 }
local matches = {} -- currently-listed groups matching a rule, for the UI
local lastSearch -- captured args from the most recent C_LFGList.Search call

local function msg(text)
	print("|cff33ff99AmbientLFG|r: " .. text)
end

-- 12.0 secret values: any field off a search result can be secret; never
-- concatenate or compare one without guarding first.
local function safeStr(v)
	if v == nil or (issecretvalue and issecretvalue(v)) then
		return ""
	end
	return tostring(v)
end

local function safeBool(v)
	if issecretvalue and issecretvalue(v) then
		return false
	end
	return v
end

local function safeNum(v)
	if type(v) ~= "number" or (issecretvalue and issecretvalue(v)) then
		return nil
	end
	return v
end

-- "lura" -> "l+u+r+a+" so doubled/stretched spellings (Lurra, Luraa) still
-- hit. Compiled once per word — this runs for every word × every listing.
local patternCache = {}
local function fuzzyPattern(word)
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

local function normalizeText(text)
	return (text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
		if #ch == 1 then
			return ch
		end
		local mapped = normalizeCodepoint(decodeUTF8(ch))
		return mapped and string.char(mapped) or ch
	end))
end

local function activityData(info)
	local ids = info.activityIDs
	if type(ids) ~= "table" then
		ids = { info.activityID }
	end
	local names, categoryID, maxPlayers, display = "", nil, nil, nil
	for _, id in ipairs(ids) do
		if type(id) == "number" and not (issecretvalue and issecretvalue(id)) then
			local cached = activityNameCache[id]
			if cached == nil then
				local actInfo = C_LFGList.GetActivityInfoTable(id)
				local fullName = actInfo and safeStr(actInfo.fullName) or ""
				local shortName = actInfo and safeStr(actInfo.shortName) or ""
				-- for raid bosses the shortName is often JUST the difficulty
				-- ("Mythic") — worthless alone; fall back to the full name
				local shortLower = shortName:lower()
				local display = shortName
				if display == "" or shortLower == "mythic" or shortLower == "heroic"
					or shortLower == "normal" or shortLower == "mythic keystone"
					or shortLower == "lfr" or shortLower == "raid finder" then
					display = fullName
				end
				-- the short name drops the difficulty; recover it from the
				-- full name ("Raid - Boss (Mythic)") when it's missing
				local lowerFull, lowerDisplay = fullName:lower(), display:lower()
				for _, diff in ipairs({ "Mythic Keystone", "Mythic", "Heroic", "Normal" }) do
					local lowerDiff = diff:lower()
					if lowerFull:find(lowerDiff, 1, true) then
						if not lowerDisplay:find(lowerDiff, 1, true) then
							display = ("%s (%s)"):format(display, diff == "Mythic Keystone" and "M+" or diff)
						end
						break
					end
				end
				cached = {
					name = fullName:lower(),
					display = display,
					categoryID = actInfo and safeNum(actInfo.categoryID),
					maxPlayers = actInfo and safeNum(actInfo.maxNumPlayers),
				}
				activityNameCache[id] = cached
			end
			names = names .. " " .. cached.name
			categoryID = categoryID or cached.categoryID
			maxPlayers = maxPlayers or cached.maxPlayers
			if not display and cached.display ~= "" then
				display = cached.display
			end
		end
	end
	return names, categoryID, maxPlayers, display
end

local function ruleToString(rule)
	local parts = {}
	for _, w in ipairs(rule.words) do
		parts[#parts + 1] = w
	end
	for _, role in ipairs(rule.roles) do
		parts[#parts + 1] = "+" .. ROLE_LABEL[role]
	end
	if rule.category == CATEGORY_DUNGEONS then
		parts[#parts + 1] = "+dungeon"
	end
	return table.concat(parts, " ")
end

-- Raid listings have no per-role caps, so Blizzard's *_REMAINING counts are
-- effectively always positive there (a 2/4/14 raid still reports open tank
-- slots). Standard-composition thresholds are the meaningful check instead.
local ROLE_NEED = {
	[CATEGORY_DUNGEONS] = { TANK = 1, HEALER = 1, DAMAGER = 3 },
	[CATEGORY_RAIDS] = { TANK = 2, HEALER = 4, DAMAGER = math.huge },
}

local function roleIsOpen(role, counts, info, categoryID, maxPlayers)
	local numMembers = safeNum(info.numMembers)
	if maxPlayers and maxPlayers > 0 and numMembers and numMembers >= maxPlayers then
		return false
	end
	local need = categoryID and ROLE_NEED[categoryID] and ROLE_NEED[categoryID][role]
	if need then
		local have = safeNum(counts[role])
		-- unknown counts as open: a spurious alert beats a missed group
		return have == nil or have < need
	end
	local remaining = safeNum(counts[ROLE_REMAINING[role]])
	return remaining == nil or remaining > 0
end

local function ruleMatches(rule, haystack, resultID, info, categoryID, maxPlayers)
	if rule.category and categoryID and rule.category ~= categoryID then
		return false
	end
	for _, word in ipairs(rule.words) do
		if not haystack:find(fuzzyPattern(word)) then
			return false
		end
	end
	if #rule.roles > 0 then
		local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
		if type(counts) ~= "table" then
			return false
		end
		for _, role in ipairs(rule.roles) do
			if not roleIsOpen(role, counts, info, categoryID, maxPlayers) then
				return false
			end
		end
	end
	return true
end

-- 12.0: listing titles and comments are kstrings — opaque |Kk1234|k tokens
-- that render as text in the UI but are unreadable to addons. Text matching
-- only ever sees the leader name and activity name, so seller filtering
-- works on leaders: ignore words match leader names, and leaders on the
-- player's in-game ignore list are skipped outright.
local function matchesIgnoreWord(haystack)
	-- also match with all separators stripped, so "W T S" / "W.T.S" hit "wts"
	local compact = haystack:gsub("[^%w]", "")
	for _, word in ipairs(db.ignores or {}) do
		local pattern = fuzzyPattern(word)
		if haystack:find(pattern) or compact:find(pattern) then
			return word
		end
	end
end

-- A missing leader or an "Unknown" placeholder title means the listing's
-- data hasn't loaded (or never will — delisted husks stay in the raw
-- results but the panel hides them).
local function listingIdentity(info)
	local name = safeStr(info.name)
	local leader = safeStr(info.leaderName)
	local ready = leader ~= "" and name ~= "" and name ~= (UNKNOWN or "Unknown")
	return name, leader, ready
end

local function listingHaystack(info, name, leader)
	local actNames, categoryID, maxPlayers, actDisplay = activityData(info)
	local comment = safeStr(info.comment)
	local haystack = normalizeText(name .. " " .. comment .. " " .. leader):lower()
		.. actNames
	return haystack, categoryID, maxPlayers, comment, actDisplay
end

-- Seller ads are auto-learned: comments are opaque kstring tokens, but
-- identical text produces the identical token, and selling orgs paste the
-- same ad under several characters. A comment token seen under 2+ distinct
-- leaders marks that ad text AND all its leaders as sellers for the session.
-- Titles are NOT clustered — Blizzard's default title makes unrelated
-- groups share a title token.
local tokenLeaders = {}
local blockedTokens, blockedLeaders = {}, {}

local function purgeMatches(leader)
	for key, m in pairs(matches) do
		if m.leader == leader then
			matches[key] = nil
		end
	end
end

local function recordAdToken(comment, leader)
	if not comment:find("^|K") then
		return
	end
	local seen = tokenLeaders[comment]
	if not seen then
		seen = { n = 0 }
		tokenLeaders[comment] = seen
	end
	if not seen[leader] then
		seen[leader] = true
		seen.n = seen.n + 1
	end
	if seen.n >= 2 and not blockedTokens[comment] then
		blockedTokens[comment] = true
		local count = 0
		for l in pairs(seen) do
			if l ~= "n" then
				blockedLeaders[l] = true
				purgeMatches(l)
				count = count + 1
			end
		end
		if db.debug then
			msg(("auto-blocked an ad text shared by %d leaders"):format(count))
		end
	end
end

local function blockedReason(haystack, leader, comment)
	if db.blockedLeaders and db.blockedLeaders[leader] then
		return "blocked by you"
	end
	if C_FriendList and C_FriendList.IsIgnored and C_FriendList.IsIgnored(leader) then
		return "on your ignore list"
	end
	local word = matchesIgnoreWord(haystack)
	if word then
		return ("ignore word \"%s\""):format(word)
	end
	if blockedLeaders[leader] then
		return "known seller"
	end
	if comment ~= "" and blockedTokens[comment] then
		-- a newly-seen character using known ad text is the same org
		blockedLeaders[leader] = true
		purgeMatches(leader)
		return "known seller ad text"
	end
end

-- every suppressed MATCH (a group that would have alerted) is recorded to
-- SavedVariables so blocking decisions can be audited afterwards
local loggedBlocks = {}
local function logBlock(leader, reason, rule)
	local k = leader .. "|" .. reason
	if loggedBlocks[k] then
		return
	end
	loggedBlocks[k] = true
	db.blockLog = db.blockLog or {}
	table.insert(db.blockLog, {
		at = time(),
		leader = leader,
		reason = reason,
		rule = ruleToString(rule),
	})
	while #db.blockLog > 30 do
		table.remove(db.blockLog, 1)
	end
	if db.debug then
		msg(("suppressed a matching group from %s (%s)"):format(leader, reason))
	end
end

local function blockLeader(leader)
	db.blockedLeaders = db.blockedLeaders or {}
	db.blockedLeaders[leader] = true
	purgeMatches(leader)
	msg(("blocked %s — their groups will never alert"):format(leader))
end

local lastSoundAt = 0

local function alertMatches(hits)
	-- in a busy category new matches can arrive every search cycle; the
	-- banner/chat show each one but the sound only repeats after a pause
	if db.sound and GetTime() - lastSoundAt > 30 then
		lastSoundAt = GetTime()
		PlaySound(SOUNDKIT.RAID_WARNING, "Master")
	end
	if db.flash then
		FlashClientIcon()
	end
	for i = 1, math.min(#hits, 3) do
		RaidNotice_AddMessage(RaidWarningFrame,
			("Group Finder match: \"%s\" (rule: %s)"):format(hits[i].name, hits[i].rule),
			ChatTypeInfo["RAID_WARNING"])
	end
	if #hits > 3 then
		RaidNotice_AddMessage(RaidWarningFrame,
			("...and %d more matches — see /alfg"):format(#hits - 3),
			ChatTypeInfo["RAID_WARNING"])
	end
	-- chat frames render protected title tokens as "Unknown" (raid banners
	-- and UI font strings render them fine) — chat gets the leaders instead
	local leaders = {}
	for _, h in ipairs(hits) do
		leaders[#leaders + 1] = h.leader or h.name
	end
	msg(("Group Finder match%s from %s — open the Group Finder and sign up."):format(
		#hits > 1 and "es" or "", table.concat(leaders, ", ")))
end

-- Listing details (comment, leaderName, member counts) stream in over the
-- seconds AFTER the results event. Alerting on first sight fires on
-- incomplete data — a "WTS" comment that hasn't loaded yet can't be ignored.
-- So matches are held in pendingConfirm and re-verified 2s later against
-- the fully-loaded listing before the alert actually fires.
local pendingConfirm = {}
local confirmScheduled = false
local scheduleConfirm

local function confirmPending()
	confirmScheduled = false
	local hits = {}
	for key, entry in pairs(pendingConfirm) do
		local rule = db.rules[entry.ruleIndex]
		local info = rule and C_LFGList.GetSearchResultInfo(entry.resultID)
		if not info or safeBool(info.isDelisted) then
			-- listing gone or rule deleted; un-mark so it can re-match later
			pendingConfirm[key] = nil
		else
			local name, leader, ready = listingIdentity(info)
			local haystack, categoryID, maxPlayers, comment, reason
			if ready then
				haystack, categoryID, maxPlayers, comment = listingHaystack(info, name, leader)
				recordAdToken(comment, leader)
				reason = blockedReason(haystack, leader, comment)
			end
			if not ready then
				entry.tries = entry.tries + 1
				if entry.tries >= 3 then
					pendingConfirm[key] = nil
					if db.debug then
						msg("dropped a match whose data never loaded")
					end
				else
					scheduleConfirm()
				end
			elseif reason then
				pendingConfirm[key] = nil
				logBlock(leader, reason, rule)
			elseif not ruleMatches(rule, haystack, entry.resultID, info, categoryID, maxPlayers) then
				pendingConfirm[key] = nil
			else
				pendingConfirm[key] = nil
				if not alerted[key] then
					alerted[key] = true
					hits[#hits + 1] = { name = name ~= "" and name or leader, leader = leader, rule = ruleToString(rule) }
					-- raw title/comment kept in SavedVariables so disguised
					-- seller text can be inspected byte-for-byte afterwards
					db.history = db.history or {}
					table.insert(db.history, {
						at = time(),
						name = name,
						comment = safeStr(info.comment),
						leader = leader,
						rule = ruleToString(rule),
					})
					while #db.history > 20 do
						table.remove(db.history, 1)
					end
				end
			end
		end
	end
	if #hits > 0 then
		alertMatches(hits)
	end
end

scheduleConfirm = function()
	if not confirmScheduled then
		confirmScheduled = true
		C_Timer.After(2, confirmPending)
	end
end

local function scanOne(resultID)
	if not db or not db.enabled or #db.rules == 0 then
		return
	end
	if type(resultID) ~= "number" or (issecretvalue and issecretvalue(resultID)) then
		return
	end
	local info = C_LFGList.GetSearchResultInfo(resultID)
	if not info or safeBool(info.isDelisted) then
		return
	end
	local name, leader, ready = listingIdentity(info)
	-- most listings aren't ready on the first pass after a search (details
	-- stream in); bail before doing any of the expensive string work
	if not ready then
		return
	end
	local haystack, categoryID, maxPlayers, comment, actDisplay = listingHaystack(info, name, leader)
	recordAdToken(comment, leader)
	for ruleIndex, rule in ipairs(db.rules) do
		if ruleMatches(rule, haystack, resultID, info, categoryID, maxPlayers) then
			local reason = blockedReason(haystack, leader, comment)
			if reason then
				logBlock(leader, reason, rule)
				return
			end
			-- leaderName can stream as "Name" first and "Name-Realm" later;
			-- key on the realm-stripped name so the same group can't
			-- re-alert when the format flips
			local key = (leader:match("^([^%-]+)") or leader) .. "|" .. ruleIndex
			local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
			matches[key] = {
				name = name ~= "" and name or leader,
				leader = leader,
				activity = actDisplay,
				rule = ruleToString(rule),
				lastSeen = GetTime(),
				tanks = counts and safeNum(counts.TANK),
				healers = counts and safeNum(counts.HEALER),
				dps = counts and safeNum(counts.DAMAGER),
			}
			if not alerted[key] and not pendingConfirm[key] then
				pendingConfirm[key] = { resultID = resultID, ruleIndex = ruleIndex, tries = 0 }
				if db.debug then
					msg(("match queued for confirmation: %s's group"):format(leader))
				end
				scheduleConfirm()
			end
			return
		end
	end
end

-- Scans are time-sliced: bursts of hundreds of listings caused visible
-- frame hitches when processed in one go, so at most SCAN_CHUNK listings
-- are evaluated per frame.
local SCAN_CHUNK = 15
local scanList, scanIndex, scanIsFull

local function scanStep()
	if not scanList then
		return
	end
	local started = debugprofilestop()
	local limit = math.min(scanIndex + SCAN_CHUNK - 1, #scanList)
	for i = scanIndex, limit do
		scanOne(scanList[i])
	end
	stats.scanMs = (stats.scanMs or 0) + (debugprofilestop() - started)
	scanIndex = limit + 1
	if scanIndex <= #scanList then
		C_Timer.After(0, scanStep)
	else
		local count = #scanList
		scanList = nil
		-- only the full post-search scan reports; the small incremental
		-- batches from streaming updates stay silent
		if db.debug and scanIsFull then
			msg(("scanned %d listings in %.1f ms"):format(count, stats.scanMs or 0))
		end
		scanIsFull = false
	end
end

local function startScan(list, isFull)
	scanIsFull = scanIsFull or isFull or false
	if scanList then
		for _, id in ipairs(list) do
			scanList[#scanList + 1] = id
		end
	else
		scanList = list
		scanIndex = 1
		stats.scanMs = 0
		scanStep()
	end
end

local function scanResults()
	local _, results = C_LFGList.GetSearchResults()
	if type(results) ~= "table" then
		return
	end
	stats.lastResultsAt = GetTime()
	stats.lastResultCount = #results
	if not db.enabled or #db.rules == 0 then
		return
	end
	startScan(results, true)
end

-- RESULT_UPDATED fires once per listing as details load — hundreds after a
-- search. Collect the IDs and scan just those, in chunks, instead of
-- rescanning the full result set on every event.
local dirty, dirtyScheduled = {}, false
local function markDirty(resultID)
	if type(resultID) ~= "number" or (issecretvalue and issecretvalue(resultID)) then
		return
	end
	dirty[resultID] = true
	if not dirtyScheduled then
		dirtyScheduled = true
		C_Timer.After(0.5, function()
			dirtyScheduled = false
			local list = {}
			for id in pairs(dirty) do
				list[#list + 1] = id
			end
			wipe(dirty)
			startScan(list)
		end)
	end
end

local function queueScan()
	if scanPending then
		return
	end
	scanPending = true
	C_Timer.After(0.3, function()
		scanPending = false
		scanResults()
	end)
end

local pendingAuto = false

-- Searches are constructed from the categories the rules imply (raids by
-- default, +dungeon per rule), rotating one category per cycle. A search the
-- player ran manually is captured and preferred as a fallback if the
-- constructed call is ever rejected (API signature drift across patches).
local searchRotation = 0

local function ruleCategories()
	local cats, seen = {}, {}
	for _, rule in ipairs(db.rules) do
		local cat = rule.category or CATEGORY_RAIDS
		if not seen[cat] then
			seen[cat] = true
			cats[#cats + 1] = cat
		end
	end
	return cats
end

local function constructedSearch(categoryID)
	-- dungeons only display recommended listings; raids search everything —
	-- a Recommended-only raid search returned 15 listings where the panel
	-- found 40
	local filters = 0
	if categoryID == CATEGORY_DUNGEONS then
		filters = Enum.LFGListFilter and Enum.LFGListFilter.Recommended or 1
	end
	-- before the Group Finder panel has initialized once, the saved language
	-- filter can be an empty set — which matches NOTHING and yields
	-- 0-result searches; fall back to the default (player locale) filter
	local language = C_LFGList.GetLanguageSearchFilter and C_LFGList.GetLanguageSearchFilter() or nil
	if (not language or next(language) == nil) and C_LFGList.GetDefaultLanguageSearchFilter then
		language = C_LFGList.GetDefaultLanguageSearchFilter()
	end
	-- the advanced filter is a dungeon-panel feature; never let an
	-- uninitialized copy constrain raid searches
	local advanced
	if categoryID == CATEGORY_DUNGEONS and C_LFGList.GetAdvancedFilter then
		advanced = C_LFGList.GetAdvancedFilter()
		if advanced and next(advanced) == nil then
			advanced = nil
		end
	end
	return pcall(C_LFGList.Search, categoryID, filters, 0, language, nil, advanced)
end

local function issueSearch()
	stats.autoIssued = stats.autoIssued + 1
	stats.lastAutoAt = GetTime()
	if db.debug then
		msg(("auto-search #%d issued"):format(stats.autoIssued))
	end
	local cats = ruleCategories()
	if #cats > 0 then
		searchRotation = searchRotation % #cats + 1
		local cat = cats[searchRotation]
		-- prefer replaying the player's own captured search when it targets
		-- this category: it reproduces the panel's exact filters, where the
		-- constructed search only approximates them
		if lastSearch and lastSearch[1] == cat
			and pcall(C_LFGList.Search, unpack(lastSearch, 1, lastSearch.n)) then
			return
		end
		if constructedSearch(cat) then
			return
		end
	end
	if lastSearch and not pcall(C_LFGList.Search, unpack(lastSearch, 1, lastSearch.n)) then
		lastSearch = nil
		db.lastSearch = nil
		msg("searching failed — open Group Finder and search once to re-arm")
	end
end

-- While the player is browsing the Group Finder themselves, auto-search
-- stands down: firing then would stomp the results they're looking at, and
-- two searches inside Blizzard's ~3s throttle window make the panel show
-- "no results". Their own searches still feed the scanner.
local function playerIsBrowsing()
	return LFGListFrame and LFGListFrame:IsVisible()
end

-- 12.0: C_LFGList.Search is hardware-event protected — calling it from a
-- timer gets ADDON_ACTION_BLOCKED (confirmed via BugGrabber 2026-07-11).
-- The ticker only queues; the search fires from the player's next click in
-- the world, which is a hardware event.
local function autoSearch()
	if not db.enabled or not db.auto or (#db.rules == 0 and not lastSearch) then
		return
	end
	if GetTime() < backoffUntil or playerIsBrowsing() then
		return
	end
	if not pendingAuto then
		pendingAuto = true
		stats.pending = true
	end
end

WorldFrame:HookScript("OnMouseDown", function()
	if pendingAuto and db and db.enabled and db.auto
		and GetTime() >= backoffUntil
		and not playerIsBrowsing()
		and GetTime() - (stats.lastAnySearchAt or 0) >= 5 then
		pendingAuto = false
		stats.pending = false
		issueSearch()
	end
end)

local function restartTicker()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
	if db.auto then
		ticker = C_Timer.NewTicker(db.interval, autoSearch)
	end
end

-- search args are plain data (numbers/booleans/tables); persisting them lets
-- auto-search re-arm at login instead of needing a manual search per session
local function sanitizeValue(v, depth)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	local t = type(v)
	if t == "number" or t == "boolean" or t == "string" then
		return v
	end
	if t == "table" and depth < 4 then
		local out = {}
		for k, val in pairs(v) do
			if type(k) == "string" or type(k) == "number" then
				local sv = sanitizeValue(val, depth + 1)
				if sv ~= nil then
					out[k] = sv
				end
			end
		end
		return out
	end
	return nil
end

hooksecurefunc(C_LFGList, "Search", function(...)
	lastSearch = { n = select("#", ...), ... }
	stats.lastAnySearchAt = GetTime()
	if db then
		db.lastSearch = sanitizeValue(lastSearch, 0)
	end
end)


frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
frame:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
frame:RegisterEvent("LFG_LIST_SEARCH_FAILED")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_LOGIN" then
		AmbientLFGDB = AmbientLFGDB or {}
		db = AmbientLFGDB
		for k, v in pairs(defaults) do
			if db[k] == nil then
				db[k] = v
			end
		end
		db.keywords = nil -- pre-rule format, never shipped
		if type(db.lastSearch) == "table" and type(db.lastSearch.n) == "number" then
			lastSearch = db.lastSearch
		end
		restartTicker()
	elseif event == "LFG_LIST_SEARCH_FAILED" then
		-- Blizzard throttles searches (~3s); when one fails, back way off so
		-- we don't wedge the Group Finder into its empty-results error state
		backoffUntil = GetTime() + 30
		stats.backoffUntil = backoffUntil
		if db and db.debug then
			msg("search failed (throttled?) — backing off 30s")
		end
	elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
		markDirty(arg1)
	else
		queueScan()
	end
end)

local function parseRule(input)
	local rule = { words = {}, roles = {} }
	for token in input:gmatch("%S+") do
		local tag = token:match("^%+(%S+)$")
		if tag then
			tag = tag:lower()
			if tag == "raid" or tag == "raids" then
				rule.category = CATEGORY_RAIDS
			elseif tag == "dungeon" or tag == "dungeons" or tag == "m+" or tag == "mplus" then
				rule.category = CATEGORY_DUNGEONS
			elseif ROLE_TOKENS[tag] then
				rule.roles[#rule.roles + 1] = ROLE_TOKENS[tag]
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

local function status()
	msg(("v%s | %s | auto-search: %s (every %ds)%s"):format(
		(C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON_NAME, "Version") or "?",
		db.enabled and "enabled" or "disabled",
		db.auto and "on" or "off",
		db.interval,
		(lastSearch or #db.rules > 0) and "" or " | add a rule to start watching"
	))
	if #db.rules == 0 then
		msg("no rules — add one with /alfg add mythic lura +tank")
	else
		for i, rule in ipairs(db.rules) do
			msg(("  rule %d: %s"):format(i, ruleToString(rule)))
		end
	end
	msg("ignoring groups containing: " .. (#db.ignores > 0 and table.concat(db.ignores, ", ") or "(nothing)"))
end

SLASH_AMBIENTLFG1 = "/ambientlfg"
SLASH_AMBIENTLFG2 = "/alfg"
SLASH_AMBIENTLFG3 = "/pma"
SlashCmdList.AMBIENTLFG = function(input)
	local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "add" and rest ~= "" then
		local rule, err = parseRule(rest)
		if rule then
			table.insert(db.rules, rule)
			msg(("added rule %d: %s"):format(#db.rules, ruleToString(rule)))
		else
			msg(err)
		end
	elseif (cmd == "del" or cmd == "remove") and rest ~= "" then
		local i = tonumber(rest)
		if i and db.rules[i] then
			local removed = table.remove(db.rules, i)
			msg(("removed rule %d: %s"):format(i, ruleToString(removed)))
		else
			msg("usage: /alfg del <rule number> (see /alfg list)")
		end
	elseif cmd == "clear" then
		wipe(db.rules)
		msg("rules cleared")
	elseif cmd == "on" or cmd == "off" then
		db.enabled = cmd == "on"
		status()
	elseif cmd == "auto" then
		db.auto = rest:lower() == "on"
		restartTicker()
		status()
	elseif cmd == "interval" then
		local n = tonumber(rest)
		if n and n >= 5 then
			db.interval = math.floor(n)
			restartTicker()
			msg(("auto-search interval set to %ds"):format(db.interval))
		else
			msg("interval must be at least 5 seconds")
		end
	elseif cmd == "ignore" and rest ~= "" then
		table.insert(db.ignores, rest:lower())
		msg(("ignoring groups containing \"%s\""):format(rest:lower()))
	elseif cmd == "unignore" and rest ~= "" then
		local target = rest:lower()
		local found
		for i, w in ipairs(db.ignores) do
			if w == target then
				table.remove(db.ignores, i)
				found = true
				break
			end
		end
		msg(found and ("no longer ignoring \"%s\""):format(target)
			or ("\"%s\" is not in the ignore list"):format(target))
	elseif cmd == "block" and rest ~= "" then
		blockLeader(rest)
	elseif cmd == "unblock" and rest ~= "" then
		local found
		for leader in pairs(db.blockedLeaders or {}) do
			if leader:lower() == rest:lower() then
				db.blockedLeaders[leader] = nil
				found = leader
				break
			end
		end
		msg(found and ("unblocked %s"):format(found) or ("\"%s\" is not blocked"):format(rest))
	elseif cmd == "debug" then
		db.debug = rest:lower() == "on"
		msg("chat log " .. (db.debug and "on" or "off"))
	elseif cmd == "reset" then
		wipe(alerted)
		msg("alert history cleared — already-seen groups will alert again")
	elseif cmd == "test" then
		alertMatches({ { name = "Test Group", rule = "test" } })
	elseif cmd == "list" or cmd == "" or cmd == "status" then
		status()
	else
		msg("commands: ui, add <words> [+tank +healer +dps +raid +dungeon], del <n>, clear, list, ignore <word>, unignore <word>, block <leader>, unblock <leader>, on/off, auto on/off, interval <sec>, debug on/off, reset, test")
	end
end

-- exports for AmbientLFGUI.lua
ns.msg = msg
ns.parseRule = parseRule
ns.ruleToString = ruleToString
ns.restartTicker = restartTicker
ns.GetDB = function() return db end
ns.IsArmed = function() return lastSearch ~= nil or (db ~= nil and #db.rules > 0) end
ns.GetStats = function() return stats end
ns.GetMatches = function() return matches end
ns.BlockLeader = blockLeader
ns.ResetAlerted = function() wipe(alerted) end
ns.TestAlert = function() alertMatches({ { name = "Test Group", leader = "Testleader", rule = "test" } }) end
