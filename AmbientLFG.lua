local ADDON_NAME, ns = ...

local defaults = {
	enabled = true,
	ignores = { "wts", "sell", "boost", "carry" },
	sound = true,
	interval = 10,
	debug = false,
	blockedLeaders = {},
}

-- Pure matching logic lives in AmbientLFG_Match.lua (unit-tested outside
-- the game); this file keeps the WoW-API-touching orchestration.
local Match = ns.Match
local safeStr, safeBool, safeNum = Match.safeStr, Match.safeBool, Match.safeNum
local normalizeText, matchesIgnoreWord = Match.normalizeText, Match.matchesIgnoreWord
local roleIsOpen, matchableText = Match.roleIsOpen, Match.matchableText
local rolesToList, rolesToString = Match.rolesToList, Match.rolesToString
local searchDescription = Match.searchDescription

local db
local frame = CreateFrame("Frame")
local ticker
local scanPending = false
local backoffUntil = 0
local consecutiveFailures = 0
local suspended = false
-- how long a group stays "already seen"; long enough to cover a play session
-- and a few reloads, short enough that the same leader listing tomorrow alerts
local ALERT_MEMORY = 6 * 60 * 60
local alerted = {} -- replaced by the SavedVariables table at login
local activityNameCache = {}
local stats = { autoIssued = 0 }
local matches = {} -- currently-listed groups matching a rule, for the UI
local lastSearch -- captured args from the most recent C_LFGList.Search call
local boxText = "" -- the search box as of the last search the player ran
local boxCategory -- the section that box belongs to, read the same way
-- A group already on the board when watching starts is not news. Without this
-- a login, a /reload, or a change of search alerts on every listing the search
-- returns at once. Those listings are recorded by resultID, not by leader,
-- because a listing's details stream in over the following seconds: keying on
-- anything that needs details would prime nothing and alert on all of it.
local primed = false
local primedFor
local preexisting = {}
-- The listing IDs the current search actually returned. LFG_LIST_SEARCH_RESULT_-
-- UPDATED fires for any listing the client is tracking, including ones left over
-- from an earlier, wider search, so a resultID arriving from an event is not
-- evidence that it passed the search box. Only IDs in here may alert.
local currentSet = {}

local function msg(text)
	print("|cff33ff99AmbientLFG|r: " .. text)
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
				-- an activity is one instance at one difficulty, never a
				-- single boss; for raids the shortName is JUST the difficulty
				-- ("Mythic") — worthless alone, so fall back to the full name
				local shortLower = shortName:lower()
				local displayName = shortName
				if displayName == "" or shortLower == "mythic" or shortLower == "heroic"
					or shortLower == "normal" or shortLower == "mythic keystone"
					or shortLower == "lfr" or shortLower == "raid finder" then
					displayName = fullName
				end
				-- the short name drops the difficulty; recover it from the
				-- full name ("Nerub-ar Palace (Mythic)") when it's missing
				local lowerFull, lowerDisplay = fullName:lower(), displayName:lower()
				for _, diff in ipairs({ "Mythic Keystone", "Mythic", "Heroic", "Normal" }) do
					local lowerDiff = diff:lower()
					if lowerFull:find(lowerDiff, 1, true) then
						if not lowerDisplay:find(lowerDiff, 1, true) then
							displayName = ("%s (%s)"):format(displayName, diff == "Mythic Keystone" and "M+" or diff)
						end
						break
					end
				end
				cached = {
					name = fullName:lower(),
					display = displayName,
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

-- Which seats you can take is Blizzard's own Filter setting — "Tank role
-- available" and friends — read back rather than asked for a second time.
-- Two settings for one thing can disagree, and a disagreement (its Tank, our
-- DPS) matches nothing while looking exactly like the addon being broken.
--
local function specRole()
	local spec = GetSpecialization and GetSpecialization()
	local role = spec and GetSpecializationRole and GetSpecializationRole(spec)
	return safeStr(role)
end

-- Raids have no role filter in the game, so the addon keeps its own for them.
local function raidRoles()
	return Match.resolveRaidRoles(db and db.raidRoles, specRole())
end

-- Blizzard sends its "role available" boxes with Dungeons searches only and
-- drops them for every other category, so they do not apply outside Dungeons
-- here either: a Tank tick left over from dungeons would otherwise quietly
-- narrow a raid search by a setting the game itself is ignoring.
local function dungeonRoles()
	local f = C_LFGList.GetAdvancedFilter and C_LFGList.GetAdvancedFilter()
	if type(f) ~= "table" then
		return {}
	end
	return {
		TANK = safeBool(f.needsTank) and true or nil,
		HEALER = safeBool(f.needsHealer) and true or nil,
		DAMAGER = safeBool(f.needsDamage) and true or nil,
	}
end

local function wantedRoles()
	if lastSearch and lastSearch[1] == Match.CATEGORY_DUNGEONS then
		return dungeonRoles()
	end
	return raidRoles()
end

-- What the search returned is what the player asked for — the addon does not
-- second-guess it. All that is left to decide per listing is whether there is
-- a seat you could take.
--
-- Roles are either/or, not all-of: ticking Tank and Healer says which roles
-- you can play, and a group needing every role at once is an empty group.
local function rolesOpen(resultID, info, categoryID, maxPlayers)
	local wanted = rolesToList(wantedRoles())
	if #wanted == 0 then
		return true
	end
	local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
	if type(counts) ~= "table" then
		return false
	end
	for _, role in ipairs(wanted) do
		if roleIsOpen(role, counts, safeNum(info.numMembers), categoryID, maxPlayers) then
			return true
		end
	end
	return false
end

-- 12.0: listing titles and comments are kstrings — opaque |Kk1234|k tokens
-- that render as text in the UI but are unreadable to addons. Text matching
-- only ever sees the leader name and activity name, so seller filtering
-- works on leaders: ignore words match leader names, and leaders on the
-- player's in-game ignore list are skipped outright.
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
	local haystack = normalizeText(
		matchableText(name) .. " " .. matchableText(comment) .. " " .. leader
	):lower() .. actNames
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
	local word = matchesIgnoreWord(haystack, db.ignores)
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
local function logBlock(leader, reason)
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
	-- flashing does nothing at all while WoW has focus, so there is no setting
	-- for it: the case it exists for is the alt-tabbed player it can't annoy
	FlashClientIcon()
	for i = 1, math.min(#hits, 3) do
		RaidNotice_AddMessage(RaidWarningFrame,
			Match.alertLine(hits[i].name, hits[i].activity, hits[i].leader),
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
		local info = C_LFGList.GetSearchResultInfo(entry.resultID)
		if not currentSet[entry.resultID] then
			-- the search moved on while this was waiting for its details
			pendingConfirm[key] = nil
		elseif not info or safeBool(info.isDelisted) then
			-- listing gone; un-mark so it can re-match later
			pendingConfirm[key] = nil
		else
			local name, leader, ready = listingIdentity(info)
			local haystack, categoryID, maxPlayers, comment, actDisplay, reason
			if ready then
				haystack, categoryID, maxPlayers, comment, actDisplay = listingHaystack(info, name, leader)
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
				logBlock(leader, reason)
			elseif not rolesOpen(entry.resultID, info, categoryID, maxPlayers) then
				pendingConfirm[key] = nil
			else
				pendingConfirm[key] = nil
				if not alerted[key] then
					alerted[key] = time()
					hits[#hits + 1] = {
						name = name ~= "" and name or leader,
						leader = leader,
						activity = actDisplay,
					}
					-- raw title/comment kept in SavedVariables so disguised
					-- seller text can be inspected byte-for-byte afterwards
					db.history = db.history or {}
					table.insert(db.history, {
						at = time(),
						name = name,
						comment = safeStr(info.comment),
						leader = leader,
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

-- The names in the player's own group, and only while a listing of theirs is
-- up: with nothing listed no search result can be their own group. This is the
-- fallback for recognising that listing when its own hasSelf flag is
-- unreadable, so nil is the ordinary answer and costs one call.
local ownNames = {}
local function ownGroupNames()
	if not (C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo()) then
		return nil
	end
	wipe(ownNames)
	ownNames[1] = safeStr(UnitName("player"))
	local prefix = IsInRaid() and "raid" or "party"
	for i = 1, GetNumGroupMembers() do
		ownNames[#ownNames + 1] = safeStr(UnitName(prefix .. i))
	end
	return ownNames
end

local function scanOne(resultID)
	if not db or not db.enabled then
		return
	end
	if type(resultID) ~= "number" or (issecretvalue and issecretvalue(resultID)) then
		return
	end
	if not currentSet[resultID] then
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
	if Match.isOwnListing(info.hasSelf, leader, ownGroupNames()) then
		return
	end
	local haystack, categoryID, maxPlayers, comment, actDisplay = listingHaystack(info, name, leader)
	recordAdToken(comment, leader)
	if not rolesOpen(resultID, info, categoryID, maxPlayers) then
		return
	end
	local reason = blockedReason(haystack, leader, comment)
	if reason then
		logBlock(leader, reason)
		return
	end
	-- leaderName can stream as "Name" first and "Name-Realm" later; key on the
	-- realm-stripped name so the same group can't re-alert when the format
	-- flips. One group is one entry now that there is nothing else to key on.
	local key = Match.shortName(leader)
	local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
	matches[key] = {
		name = name ~= "" and name or leader,
		leader = leader,
		resultID = resultID,
		activity = actDisplay,
		lastSeen = GetTime(),
		tanks = counts and safeNum(counts.TANK),
		healers = counts and safeNum(counts.HEALER),
		dps = counts and safeNum(counts.DAMAGER),
	}
	if preexisting[resultID] then
		alerted[key] = alerted[key] or time()
		return
	end
	if not alerted[key] and not pendingConfirm[key] then
		pendingConfirm[key] = { resultID = resultID, tries = 0 }
		if db.debug then
			msg(("match queued for confirmation: %s's group"):format(leader))
		end
		scheduleConfirm()
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

-- Blizzard's own panel reads GetFilteredSearchResults, not GetSearchResults.
-- The engine applies the Group Finder's search box to it — and for keystones
-- that box is a key-RANGE filter evaluated against the real key level, not a
-- text match on the title. Titles reach addons as unreadable tokens, so this
-- is the only way a key level can be filtered at all. The text lives in
-- engine state keyed to the secure search box, so it survives the window
-- being closed and applies to searches the addon issues itself.
local function searchResults()
	if C_LFGList.GetFilteredSearchResults then
		local _, filtered = C_LFGList.GetFilteredSearchResults()
		if type(filtered) == "table" then
			return filtered
		end
	end
	local _, results = C_LFGList.GetSearchResults()
	return results
end

-- Readable even though the box refuses SetText from addons: the security
-- attribute blocks writes only.
local function searchBoxText()
	local panel = LFGListFrame and LFGListFrame.SearchPanel
	local box = panel and panel.SearchBox
	return box and safeStr(box:GetText()) or ""
end

-- The box is the filter, and the engine reads it off Blizzard's own editbox at
-- search time rather than taking it as an argument — so the widget IS the
-- state. It is readable only while the panel is up; with the Group Finder shut
-- it reads empty, which is not the same as the filter being empty. So the box
-- is re-read every time it can be, and a reading taken with the panel down is
-- not allowed to overwrite it.
--
-- Re-read rather than captured once: the player can clear the box, or switch
-- tabs, without running a search, and a remembered string would then name a
-- filter the engine no longer has.
local function rememberBoxText()
	local panel = LFGListFrame and LFGListFrame.SearchPanel
	if panel and panel:IsVisible() then
		boxText = searchBoxText()
		-- the field Blizzard's own search panel hands to C_LFGList.Search
		boxCategory = safeNum(panel.categoryID)
	end
	return boxText
end

-- An empty search box is not a filter, it is every group in the category. It
-- would alert on the whole board and keep alerting as the board churns, which
-- is indistinguishable from the addon being broken. So an empty box counts as
-- no search at all: nothing is watched until the player types one.
--
-- Switching the Group Finder to another section disarms it the same way, and for
-- the same reason: the panel on screen is a different search from the captured
-- one, so the window would go on naming a search — and offering the raid-only
-- role boxes for it — that the player has navigated away from. Only a section
-- positively read as a different one counts; an unreadable panel changes
-- nothing, so a Blizzard rename cannot silently switch the addon off.
local function armed()
	if lastSearch == nil or rememberBoxText() == "" then
		return false
	end
	return boxCategory == nil or boxCategory == lastSearch[1]
end

-- Watching ends when the player is in the group they were looking for. The
-- captured search has done its job, and going on alerting for more of the same
-- is the addon talking over the thing it was asked to find.
--
-- Leaving that group does not put it back. Nothing re-arms itself here, for the
-- same reason a reload does not: the search box is engine state that can only be
-- read while Blizzard's panel is on screen, so a search replayed without it is
-- every group in the category while still naming a filter it no longer has.
-- Run the search again and it is watched again.
local function disarm()
	lastSearch = nil
	boxText = ""
	boxCategory = nil
	primed = false
	primedFor = nil
	wipe(matches)
	wipe(pendingConfirm)
	wipe(currentSet)
end

local function scanResults()
	local results = searchResults()
	if type(results) ~= "table" then
		return
	end
	stats.lastResultsAt = GetTime()
	stats.lastResultCount = #results
	if not db.enabled or not armed() then
		return
	end
	wipe(currentSet)
	for _, id in ipairs(results) do
		currentSet[id] = true
	end
	if not primed then
		primed = true
		wipe(preexisting)
		for _, id in ipairs(results) do
			preexisting[id] = true
		end
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

-- The watched search is the player's own, replayed verbatim. Nothing is
-- constructed: a search the addon builds only approximates the panel's filters,
-- and the one filter that matters most — the search box, which is the only way
-- a keystone level can be selected at all — is engine state the addon cannot
-- read into a call it assembles itself. So with no captured search there is
-- nothing to watch, and the addon says so rather than guessing.
local function issueSearch()
	-- deliberately no per-cycle chat line even in debug mode — it was pure
	-- noise; the scan summary and the UI heartbeat already show the cadence
	if not armed() then
		return
	end
	stats.autoIssued = stats.autoIssued + 1
	stats.lastAutoAt = GetTime()
	if not pcall(C_LFGList.Search, unpack(lastSearch, 1, lastSearch.n)) then
		lastSearch = nil
		msg("searching failed — open the Group Finder and search once to re-arm")
	end
end

-- While the player is browsing the Group Finder themselves, auto-search
-- stands down: firing then would stomp the results they're looking at, and
-- two searches inside Blizzard's ~3s throttle window make the panel show
-- "no results". Their own searches still feed the scanner.
local function playerIsBrowsing()
	return LFGListFrame and LFGListFrame:IsVisible()
end

-- Nil unless the player's own group is listed, in which case it says so. A live
-- listing stops background searching outright: the Group Finder is showing
-- applicants rather than the search panel, and a player whose group is already
-- recruiting is not looking for a group to join.
local function cannotSearch()
	if not (C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo()) then
		return nil
	end
	return Match.listedBlockText(UnitIsGroupLeader and UnitIsGroupLeader("player") or false)
end

-- 12.0: C_LFGList.Search is hardware-event protected — calling it from a
-- timer gets ADDON_ACTION_BLOCKED (confirmed via BugGrabber 2026-07-11).
-- The ticker only queues; the search fires from the player's next hardware
-- event, which is a click in the world or any keypress.
local firePendingSearch -- assigned once issueSearch is in scope

-- Keys are hardware events as much as clicks are, and a player who moves with
-- the keyboard can go a long time without clicking anything — long enough for
-- a queued search to just sit there. The watcher propagates every key onward
-- untouched, so it changes nothing about what that key does, and it listens
-- only while a search is actually queued.
--
-- It also stands down in combat, and the two halves of that are not the same
-- call. SetPropagateKeyboardInput is restricted in combat (10.1.5), so calling
-- it there is blocked and reported against the addon; EnableKeyboard is not
-- restricted, so it is what the combat toggle is built out of. Propagation is
-- a durable property of the frame rather than a per-keystroke one, so setting
-- it once at creation is what keeps every key passing through untouched.
-- A queued search waits for the next click instead, which costs a cycle.
local keyWatcher = CreateFrame("Frame", nil, UIParent)
keyWatcher:SetPropagateKeyboardInput(true)
keyWatcher:EnableKeyboard(false)
keyWatcher:SetScript("OnKeyDown", function(self)
	if InCombatLockdown() then
		-- reaching this at all means the event stand-down did not take, so do it
		-- here where a key proves the frame is still listening
		self:EnableKeyboard(false)
		return
	end
	self:SetPropagateKeyboardInput(true)
	firePendingSearch()
end)
keyWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
keyWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")

local function listenForKeys()
	keyWatcher:EnableKeyboard(pendingAuto and not InCombatLockdown())
end
keyWatcher:SetScript("OnEvent", listenForKeys)

local function setPending(state)
	pendingAuto = state
	stats.pending = state
	listenForKeys()
end

local function autoSearch()
	if not db.enabled or not lastSearch then
		return
	end
	stats.browsing = playerIsBrowsing() or nil
	if suspended or GetTime() < backoffUntil or stats.browsing or cannotSearch() then
		return
	end
	-- the Group Finder isn't usable in battlegrounds/arenas; searching
	-- there just generates failure spam
	local _, instanceType = IsInInstance()
	if instanceType == "pvp" or instanceType == "arena" then
		return
	end
	if not pendingAuto then
		setPending(true)
	end
end

function firePendingSearch()
	if pendingAuto and db and db.enabled
		and not suspended
		and GetTime() >= backoffUntil
		and not playerIsBrowsing()
		and not cannotSearch()
		and GetTime() - (stats.lastAnySearchAt or 0) >= 5 then
		setPending(false)
		issueSearch()
	end
end

WorldFrame:HookScript("OnMouseDown", firePendingSearch)

local function restartTicker()
	-- toggling Watch (or changing the interval) is the manual way to
	-- retry after a suspension
	suspended = false
	consecutiveFailures = 0
	stats.suspended = false
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
	if db.enabled then
		ticker = C_Timer.NewTicker(db.interval, autoSearch)
	end
end

-- Two things depend on noticing that the watched search CHANGED, as opposed to
-- being re-run: the groups the old search found are no longer matches and must
-- leave the list at once rather than aging out, and the new search's first
-- results are a board the player has not seen, so they prime instead of
-- alerting. The addon's own replays produce an identical signature and so are
-- correctly not treated as a change.
local function searchSignature(args)
	local parts = {}
	local function add(v, depth)
		if issecretvalue and issecretvalue(v) then
			return
		end
		local t = type(v)
		if t == "table" and depth < 4 then
			local keys = {}
			for k in pairs(v) do
				if type(k) == "string" or type(k) == "number" then
					keys[#keys + 1] = k
				end
			end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do
				parts[#parts + 1] = tostring(k)
				add(v[k], depth + 1)
			end
		elseif t == "number" or t == "boolean" or t == "string" then
			parts[#parts + 1] = tostring(v)
		end
	end
	for i = 1, args.n do
		add(args[i], 0)
	end
	parts[#parts + 1] = boxText
	return table.concat(parts, "\1")
end

hooksecurefunc(C_LFGList, "Search", function(...)
	lastSearch = { n = select("#", ...), ... }
	stats.lastAnySearchAt = GetTime()
	rememberBoxText()
	local sig = searchSignature(lastSearch)
	if sig ~= primedFor then
		primedFor = sig
		primed = false
		wipe(matches)
		wipe(pendingConfirm)
		wipe(currentSet)
	end
end)


frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
frame:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
frame:RegisterEvent("LFG_LIST_SEARCH_FAILED")
frame:RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED")
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "PLAYER_LOGIN" then
		AmbientLFGDB = AmbientLFGDB or {}
		db = AmbientLFGDB
		for k, v in pairs(defaults) do
			if db[k] == nil then
				db[k] = v
			end
		end
		db.keywords = nil -- pre-rule format, never shipped
		db.flash = nil -- taskbar flashing is unconditional now
		db.roles = nil -- Blizzard's own Filter says which seats you can take
		-- Enabled and auto-search were two switches for one thing: watching
		-- means searching, and the addon saw nothing without it. Either one
		-- off meant not watching, so either one off stays off.
		if db.auto ~= nil then
			db.enabled = db.enabled and db.auto
			db.auto = nil
		end
		-- "Already seen" has to outlive a /reload, or every reload re-alerts
		-- every group you'd dismissed. Entries expire so that a leader who
		-- lists again tomorrow is genuinely new.
		db.alerted = type(db.alerted) == "table" and db.alerted or {}
		local cutoff = time() - ALERT_MEMORY
		for key, at in pairs(db.alerted) do
			if type(at) ~= "number" or at < cutoff then
				db.alerted[key] = nil
			end
		end
		alerted = db.alerted
		-- Rule words could never see a keystone level: a listing's title
		-- reaches an addon as an opaque token even when the group typed it.
		-- The Group Finder's own search box can, so the search is the filter
		-- now and the saved rules are dropped rather than migrated.
		if db.rules then
			db.rules = nil
			msg("rules have been replaced by the search you run yourself — open the Group Finder, set up the search you want, run it once, and /alfg watches it.")
		end
		-- A reload cannot carry the watched search with it. The search box is
		-- not an argument to the search — the engine reads Blizzard's editbox
		-- as it runs — and a reload builds that box empty. A restored search
		-- therefore replays with no filter at all, which is every group in the
		-- category, while still naming the filter it no longer has. So a reload
		-- disarms: run your search once and it is watched again.
		db.boxText = nil
		db.lastSearch = nil
		restartTicker()
	elseif event == "LFG_LIST_SEARCH_FAILED" then
		-- back off exponentially on repeated failures (throttle, or the
		-- player simply can't use the Group Finder right now), and give up
		-- with ONE message instead of retrying forever
		consecutiveFailures = consecutiveFailures + 1
		local backoff = math.min(30 * 2 ^ (consecutiveFailures - 1), 300)
		backoffUntil = GetTime() + backoff
		stats.backoffUntil = backoffUntil
		if consecutiveFailures >= 5 and not suspended then
			suspended = true
			stats.suspended = true
			msg("watching suspended — the Group Finder keeps rejecting searches (not usable right now?). It resumes after a successful manual search, or untick and retick Watch.")
		elseif db and db.debug then
			msg(("search failed — backing off %ds"):format(backoff))
		end
	elseif event == "LFG_LIST_APPLICATION_STATUS_UPDATED" then
		if Match.joinedGroup(arg2) then
			disarm()
			msg("you're in a group — watching stopped. Run your search again in the Group Finder if you want to keep looking.")
		end
	elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
		markDirty(arg1)
	else
		consecutiveFailures = 0
		backoffUntil = 0
		stats.backoffUntil = nil
		if suspended then
			suspended = false
			stats.suspended = false
			if db and db.debug then
				msg("searches working again — watching resumed")
			end
		end
		queueScan()
	end
end)

local function watchedSearch()
	if not armed() then
		return nil
	end
	return searchDescription(lastSearch[1], boxText)
end

-- Which section the watched search is in, or nil when nothing is being watched.
-- The window hangs a raid-only control off this, so everyone asks the one
-- question rather than keeping a boolean each and letting them disagree.
--
-- Armed, not merely "there was a search once": a raid-only control still on
-- screen after the player has left the Raids section claims to narrow a search
-- that is no longer being watched.
local function watchedCategory()
	return armed() and lastSearch[1] or nil
end

-- Nil outside a raid search; otherwise what the box does or does not narrow to.
local function raidDifficulty()
	if not armed() then
		return nil
	end
	return Match.raidDifficultyHint(lastSearch[1], boxText)
end

local function status()
	msg(("v%s | %s (searching every %ds)"):format(
		(C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON_NAME, "Version") or "?",
		db.enabled and "on" or "off",
		db.interval))
	local watching = watchedSearch()
	msg(cannotSearch()
		or (watching and ("watching: %s"):format(watching))
		or "nothing to watch — open the Group Finder, set up the search you want, and run it once")
	msg("alerting when there is an open seat for: " .. rolesToString(wantedRoles())
		.. (watchedCategory() == Match.CATEGORY_DUNGEONS and " (set in the Group Finder's Filter)"
			or db.raidRoles and " (raids: set in /alfg ui)"
			or " (raids: your current spec)"))
	msg("ignoring groups containing: " .. (#db.ignores > 0 and table.concat(db.ignores, ", ") or "(nothing)"))
end

-- A listing that fails to alert looks the same from outside whether its roles
-- were full, its leader was blocked, or the result was a husk. /alfg diag
-- prints what the addon actually received for the listings on screen, and why
-- each one was or was not a match.
--
-- It prints rather than writing SavedVariables: a dump that needs a /reload to
-- become readable reports nothing at the moment you run it, so a run that found
-- nothing and a run that never happened look identical.
local function fieldKind(v)
	if v == nil then
		return "nil"
	elseif issecretvalue and issecretvalue(v) then
		return "secret"
	elseif type(v) ~= "string" then
		return type(v)
	elseif v:find("^|K") then
		return "kstring"
	end
	return "text"
end

local DIAG_LIMIT = 12
local function diag()
	local _, raw = C_LFGList.GetSearchResults()
	-- guarded with an if, not `X and X()`: an `and` in a multiple assignment is
	-- adjusted to one value, so the second return would always have been nil and
	-- the count this whole command exists to print would have read -1
	local filtered
	if C_LFGList.GetFilteredSearchResults then
		_, filtered = C_LFGList.GetFilteredSearchResults()
	end
	local rawN = type(raw) == "table" and #raw or -1
	local filtN = type(filtered) == "table" and #filtered or -1
	-- Equal counts say nothing about the search box. The box is part of the
	-- search request, so the server has already applied it to both lists; what
	-- the pair reports is whether the client dropped anything further. Whether
	-- the box narrowed is answered by the key levels in the rows below.
	msg(("diag: box=%q (live %q) raw=%d filtered=%d"):format(boxText, searchBoxText(), rawN, filtN))
	msg(("  watching: %s | seats wanted: %s"):format(watchedSearch() or "(nothing)", rolesToString(wantedRoles())))

	local results = searchResults()
	if type(results) ~= "table" or #results == 0 then
		msg("  no listings on hand — search once in the Group Finder first")
		return
	end
	for i = 1, math.min(#results, DIAG_LIMIT) do
		local resultID = results[i]
		local info = type(resultID) == "number" and C_LFGList.GetSearchResultInfo(resultID) or nil
		if info then
			local name, leader = listingIdentity(info)
			local haystack, categoryID, maxPlayers, comment, actDisplay = listingHaystack(info, name, leader)
			local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
			local roles = "?"
			if type(counts) == "table" then
				roles = ("n%d T%d H%d D%d"):format(safeNum(info.numMembers),
					safeNum(counts.TANK), safeNum(counts.HEALER), safeNum(counts.DAMAGER))
			end
			local verdict = Match.isOwnListing(info.hasSelf, leader, ownGroupNames()) and "your own listing"
				or blockedReason(haystack, leader, comment)
			if not verdict and not rolesOpen(resultID, info, categoryID, maxPlayers) then
				verdict = "no open seat for " .. rolesToString(wantedRoles())
			end
			msg(("  [%d] name=%s %q cmt=%s cat=%s %s act=%q -> %s"):format(
				i, fieldKind(info.name), safeStr(info.name):sub(1, 40),
				fieldKind(info.comment), tostring(categoryID), roles,
				tostring(actDisplay):sub(1, 30), verdict or "MATCH"))
		end
	end
	if #results > DIAG_LIMIT then
		msg(("  ... %d more"):format(#results - DIAG_LIMIT))
	end
end

SLASH_AMBIENTLFG1 = "/ambientlfg"
SLASH_AMBIENTLFG2 = "/alfg"
SLASH_AMBIENTLFG3 = "/pma"
SlashCmdList.AMBIENTLFG = function(input)
	local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "on" or cmd == "off" then
		db.enabled = cmd == "on"
		restartTicker()
		status()
	elseif cmd == "interval" then
		local n = tonumber(rest)
		if n and n >= 5 then
			db.interval = math.floor(n)
			restartTicker()
			msg(("search interval set to %ds"):format(db.interval))
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
		wipe(preexisting)
		msg("alert history cleared — already-seen groups will alert again")
	elseif cmd == "diag" then
		diag()
	elseif cmd == "test" then
		alertMatches({ { name = "Test Group", leader = "Testleader", activity = "Mythic+ (M+)" } })
	elseif cmd == "list" or cmd == "" or cmd == "status" then
		status()
	else
		msg("commands: ui, ignore <word>, unignore <word>, block <leader>, unblock <leader>, on/off, interval <sec>, debug on/off, reset, test, diag")
	end
end

-- exports for AmbientLFGUI.lua
ns.msg = msg
ns.restartTicker = restartTicker
ns.GetDB = function() return db end
ns.IsArmed = armed
ns.GetWatchedSearch = watchedSearch
ns.RaidDifficultyHint = raidDifficulty
ns.CannotSearchReason = cannotSearch
ns.GetStats = function() return stats end
ns.GetSearchBoxText = searchBoxText
ns.GetWantedRoles = wantedRoles
ns.GetRaidRoles = raidRoles
ns.RaidRolesAreAuto = function()
	return db == nil or db.raidRoles == nil
end
-- Passing nil goes back to following the player's spec; passing a set pins it.
ns.SetRaidRoles = function(roles)
	db.raidRoles = roles
end
ns.WatchedCategory = watchedCategory
ns.GetMatches = function() return matches end
ns.BlockLeader = blockLeader
ns.ResetAlerted = function() wipe(alerted); wipe(preexisting) end
ns.TestAlert = function()
	alertMatches({ { name = "Test Group", leader = "Testleader", activity = "Mythic+ (M+)" } })
end
