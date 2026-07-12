local ADDON_NAME, ns = ...

local FRAME_WIDTH = 400
local FRAME_HEIGHT = 534
local PADDING = 10
local ROW_HEIGHT = 24

local ui

local ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }
local ROLE_UI = {
	TANK = { label = "Tank", atlas = "roleicon-tiny-tank" },
	HEALER = { label = "Healer", atlas = "roleicon-tiny-healer" },
	DAMAGER = { label = "DPS", atlas = "roleicon-tiny-dps" },
}

local function MakeCheckbox(parent, label, onClick)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	text:SetText(label)
	cb.label = text
	cb:SetScript("OnClick", function(self)
		onClick(self:GetChecked() and true or false)
	end)
	return cb
end

local function MakeButton(parent, label, width, onClick)
	local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	btn:SetSize(width, 22)
	btn:SetText(label)
	btn:SetScript("OnClick", onClick)
	return btn
end

local Refresh -- forward declaration

local function AcquireRuleRow(f, i)
	f.ruleRows = f.ruleRows or {}
	local row = f.ruleRows[i]
	if not row then
		row = CreateFrame("Frame", nil, f.scrollChild)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("LEFT", f.scrollChild, "LEFT", 0, 0)
		row:SetPoint("RIGHT", f.scrollChild, "RIGHT", 0, 0)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()

		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
		row.text:SetPoint("RIGHT", row, "RIGHT", -28, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)

		row.delete = CreateFrame("Button", nil, row, "UIPanelCloseButton")
		row.delete:SetSize(20, 20)
		row.delete:SetPoint("RIGHT", row, "RIGHT", -2, 0)
		row.delete:SetScript("OnClick", function(self)
			if self.matchLeader then
				ns.BlockLeader(self.matchLeader)
				Refresh()
				return
			end
			local db = ns.GetDB()
			if db and db.rules[self.ruleIndex] then
				table.remove(db.rules, self.ruleIndex)
				Refresh()
			end
		end)
		row.delete:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.matchLeader
				and ("Block %s — never alert for their groups again"):format(self.matchLeader)
				or "Delete this rule")
			GameTooltip:Show()
		end)
		row.delete:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)

		f.ruleRows[i] = row
	end
	row:Show()
	return row
end

local function RuleDisplayText(rule)
	local parts = {}
	for _, w in ipairs(rule.words) do
		parts[#parts + 1] = w
	end
	local text = table.concat(parts, " ")
	for _, role in ipairs(rule.roles) do
		text = text .. " " .. CreateAtlasMarkup(ROLE_UI[role].atlas, 14, 14)
	end
	if rule.category then
		-- 2 = GROUP_FINDER_CATEGORY_ID_DUNGEONS; raids are the default
		text = text .. (rule.category == 2 and " |cff999999(Dungeons)|r" or " |cff999999(Raids)|r")
	end
	return text
end

Refresh = function()
	if not ui or not ui:IsShown() then
		return
	end
	local db = ns.GetDB()
	if not db then
		return
	end

	ui.enabledCB:SetChecked(db.enabled)
	ui.soundCB:SetChecked(db.sound)
	ui.flashCB:SetChecked(db.flash)
	ui.autoCB:SetChecked(db.auto)
	ui.debugCB:SetChecked(db.debug)
	if not ui.intervalBox:HasFocus() then
		ui.intervalBox:SetText(tostring(db.interval))
	end
	if not ui.ignoreBox:HasFocus() then
		ui.ignoreBox:SetText(table.concat(db.ignores or {}, ", "))
	end

	local rules = db.rules
	local y = 0
	local rowIndex = 0
	local function nextRow()
		rowIndex = rowIndex + 1
		local row = AcquireRuleRow(ui, rowIndex)
		row:SetPoint("TOP", ui.scrollChild, "TOP", 0, -y)
		y = y + ROW_HEIGHT
		return row
	end

	for i, rule in ipairs(rules) do
		local row = nextRow()
		row.bg:SetColorTexture(0.15, 0.15, 0.15, i % 2 == 0 and 0.4 or 0)
		row.text:SetText(RuleDisplayText(rule))
		row.delete.ruleIndex = i
		row.delete.matchLeader = nil
		row.delete:Show()
	end

	-- live list of currently-listed groups matching a rule; the opaque
	-- title tokens render as real text inside a FontString
	local matchStore = ns.GetMatches()
	local matchList = {}
	local now = GetTime()
	local maxAge = (db.interval or 10) * 3 + 10
	for key, m in pairs(matchStore) do
		if now - m.lastSeen > maxAge then
			matchStore[key] = nil
		else
			matchList[#matchList + 1] = m
		end
	end
	table.sort(matchList, function(a, b) return a.lastSeen > b.lastSeen end)

	y = y + 8 -- visual break between the rules and the live matches
	local header = nextRow()
	header.bg:SetColorTexture(0.1, 0.3, 0.12, 0.7)
	header.text:SetText(("|cff66ff66Current matches (%d)|r"):format(#matchList))
	header.delete:Hide()

	for i, m in ipairs(matchList) do
		local row = nextRow()
		row.bg:SetColorTexture(0.1, 0.25, 0.12, i % 2 == 0 and 0.35 or 0.15)
		local comp = ("%s%s %s%s %s%s"):format(
			CreateAtlasMarkup(ROLE_UI.TANK.atlas, 12, 12), m.tanks or "?",
			CreateAtlasMarkup(ROLE_UI.HEALER.atlas, 12, 12), m.healers or "?",
			CreateAtlasMarkup(ROLE_UI.DAMAGER.atlas, 12, 12), m.dps or "?")
		local activity = m.activity and ("|cffffd100%s|r "):format(m.activity) or ""
		row.text:SetText(("%s  %s%s"):format(comp, activity, m.name))
		row.delete.ruleIndex = nil
		row.delete.matchLeader = m.leader
		row.delete:Show()
	end

	if ui.ruleRows then
		for i = rowIndex + 1, #ui.ruleRows do
			ui.ruleRows[i]:Hide()
		end
	end

	if #rules == 0 and #matchList == 0 then
		ui.emptyText:Show()
	else
		ui.emptyText:Hide()
	end
	ui.scrollChild:SetHeight(math.max(y, 1))

	local stats = ns.GetStats()
	local heartbeat = ""
	if stats.lastResultsAt then
		heartbeat = ("\nLast results: %ds ago (%d groups)"):format(
			math.max(0, math.floor(GetTime() - stats.lastResultsAt)),
			stats.lastResultCount or 0)
	end
	if stats.autoIssued > 0 then
		heartbeat = heartbeat .. (" | %d auto-searches"):format(stats.autoIssued)
	end
	if not db.enabled then
		ui.statusText:SetText("|cffff6666Alerts disabled|r" .. heartbeat)
	elseif db.auto and not ns.IsArmed() then
		ui.statusText:SetText("|cffffcc00Auto-search idle — add a rule to start watching|r" .. heartbeat)
	elseif db.auto and stats.backoffUntil and GetTime() < stats.backoffUntil then
		ui.statusText:SetText(("|cffff9933Search throttled — pausing %ds|r"):format(
			math.ceil(stats.backoffUntil - GetTime())) .. heartbeat)
	elseif db.auto and stats.pending then
		ui.statusText:SetText("|cff66ff66Search queued — fires on your next click in the world|r" .. heartbeat)
	elseif db.auto then
		ui.statusText:SetText(("|cff66ff66Watching — searches every %ds, on your next click|r"):format(db.interval) .. heartbeat)
	else
		ui.statusText:SetText("Alerting on manual refreshes only (enable auto-search to monitor)" .. heartbeat)
	end
end

local function CreateUI()
	local f = CreateFrame("Frame", "PremadeAlertFrame", UIParent, "BackdropTemplate")
	f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	f:SetPoint("CENTER")
	f:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
	})
	f:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
	f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING)
	title:SetText("Premade Alert")
	title:SetTextColor(1, 0.84, 0)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() f:Hide() end)

	-- Escape-to-close without UISpecialFrames: inserting there taints
	-- CloseSpecialWindows, which Blizzard's LFGList code calls while secure.
	-- Keyboard is fully disabled in combat because SetPropagateKeyboardInput
	-- is itself restricted during lockdown.
	f:SetScript("OnKeyDown", function(self, key)
		if InCombatLockdown() then
			return
		end
		if key == "ESCAPE" then
			self:SetPropagateKeyboardInput(false)
			self:Hide()
		else
			self:SetPropagateKeyboardInput(true)
		end
	end)
	f:SetScript("OnShow", function(self)
		self:EnableKeyboard(not InCombatLockdown())
		Refresh()
		self.refreshTicker = C_Timer.NewTicker(1, Refresh)
	end)
	f:SetScript("OnHide", function(self)
		if self.refreshTicker then
			self.refreshTicker:Cancel()
			self.refreshTicker = nil
		end
	end)
	f:RegisterEvent("PLAYER_REGEN_DISABLED")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	f:SetScript("OnEvent", function(self, event)
		self:EnableKeyboard(event == "PLAYER_REGEN_ENABLED")
	end)

	-- Options: Enabled / Sound / Flash
	local db = ns.GetDB
	f.enabledCB = MakeCheckbox(f, "Enabled", function(checked)
		db().enabled = checked
		Refresh()
	end)
	f.enabledCB:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -30)

	f.soundCB = MakeCheckbox(f, "Sound", function(checked)
		db().sound = checked
	end)
	f.soundCB:SetPoint("LEFT", f.enabledCB.label, "RIGHT", 16, 0)

	f.flashCB = MakeCheckbox(f, "Flash taskbar", function(checked)
		db().flash = checked
	end)
	f.flashCB:SetPoint("LEFT", f.soundCB.label, "RIGHT", 16, 0)

	-- Auto-search + interval
	f.autoCB = MakeCheckbox(f, "Auto-search every", function(checked)
		db().auto = checked
		ns.restartTicker()
		Refresh()
	end)
	f.autoCB:SetPoint("TOPLEFT", f.enabledCB, "BOTTOMLEFT", 0, -2)

	f.intervalBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	f.intervalBox:SetSize(36, 20)
	f.intervalBox:SetPoint("LEFT", f.autoCB.label, "RIGHT", 10, 0)
	f.intervalBox:SetAutoFocus(false)
	f.intervalBox:SetNumeric(true)
	f.intervalBox:SetMaxLetters(3)
	local function commitInterval(self)
		local n = tonumber(self:GetText())
		if n and n >= 5 then
			db().interval = math.floor(n)
			ns.restartTicker()
		end
		Refresh()
	end
	f.intervalBox:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	f.intervalBox:SetScript("OnEditFocusLost", commitInterval)
	f.intervalBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	local secText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	secText:SetPoint("LEFT", f.intervalBox, "RIGHT", 4, 0)
	secText:SetText("sec")

	f.debugCB = MakeCheckbox(f, "Chat log", function(checked)
		db().debug = checked
	end)
	f.debugCB:SetPoint("LEFT", secText, "RIGHT", 16, 0)

	-- Rules list
	local rulesHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	rulesHeader:SetPoint("TOPLEFT", f.autoCB, "BOTTOMLEFT", 0, -8)
	rulesHeader:SetText("Rules — an alert fires if ANY rule matches")
	rulesHeader:SetTextColor(0.7, 0.7, 0.7)

	local listBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
	listBg:SetPoint("TOPLEFT", rulesHeader, "BOTTOMLEFT", 0, -4)
	listBg:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
	listBg:SetPoint("BOTTOM", f, "BOTTOM", 0, 200)
	listBg:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
	})
	listBg:SetBackdropColor(0, 0, 0, 0.4)
	listBg:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)

	local scrollFrame = CreateFrame("ScrollFrame", nil, listBg, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", listBg, "TOPLEFT", 4, -4)
	scrollFrame:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -24, 4)

	local scrollChild = CreateFrame("Frame", nil, scrollFrame)
	scrollChild:SetWidth(FRAME_WIDTH - PADDING * 2 - 32)
	scrollChild:SetHeight(1)
	scrollFrame:SetScrollChild(scrollChild)
	f.scrollChild = scrollChild

	f.emptyText = listBg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.emptyText:SetPoint("CENTER")
	f.emptyText:SetText("No rules yet — add one below, e.g. \"mythic lura\" + Tank")
	f.emptyText:SetTextColor(0.5, 0.5, 0.5)

	-- Ignore words
	local ignoreLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ignoreLabel:SetPoint("TOPLEFT", listBg, "BOTTOMLEFT", 0, -10)
	ignoreLabel:SetText("Ignore:")
	ignoreLabel:SetTextColor(0.7, 0.7, 0.7)

	f.ignoreBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	f.ignoreBox:SetHeight(20)
	f.ignoreBox:SetPoint("LEFT", ignoreLabel, "RIGHT", 10, 0)
	f.ignoreBox:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
	f.ignoreBox:SetAutoFocus(false)
	local function commitIgnores(self)
		local words = {}
		for word in (self:GetText() or ""):gmatch("[^,%s]+") do
			words[#words + 1] = word:lower()
		end
		db().ignores = words
		Refresh()
	end
	f.ignoreBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	f.ignoreBox:SetScript("OnEditFocusLost", commitIgnores)
	f.ignoreBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	-- Add-rule area
	local addHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	addHeader:SetPoint("TOPLEFT", ignoreLabel, "BOTTOMLEFT", 0, -12)
	addHeader:SetText("New rule — ALL its words must match, plus open roles")
	addHeader:SetTextColor(0.7, 0.7, 0.7)

	f.addBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	f.addBox:SetHeight(20)
	f.addBox:SetPoint("TOPLEFT", addHeader, "BOTTOMLEFT", 6, -6)
	f.addBox:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
	f.addBox:SetAutoFocus(false)

	-- section picker (radio-style pair, raids default)
	local raidCB = MakeCheckbox(f, "Raids", function() end)
	raidCB:SetPoint("TOPLEFT", f.addBox, "BOTTOMLEFT", -6, -2)
	local dungeonCB = MakeCheckbox(f, "Dungeons", function() end)
	dungeonCB:SetPoint("LEFT", raidCB.label, "RIGHT", 12, 0)
	raidCB:SetScript("OnClick", function()
		raidCB:SetChecked(true)
		dungeonCB:SetChecked(false)
	end)
	dungeonCB:SetScript("OnClick", function()
		dungeonCB:SetChecked(true)
		raidCB:SetChecked(false)
	end)
	raidCB:SetChecked(true)
	f.raidCB, f.dungeonCB = raidCB, dungeonCB

	-- difficulty picker (optional; mutually exclusive, click again to clear).
	-- Difficulty is matched via the activity name, so each option just
	-- contributes the corresponding rule word.
	local DIFFS = {
		{ label = "Normal", word = "normal" },
		{ label = "Heroic", word = "heroic" },
		{ label = "Mythic", word = "mythic" },
		{ label = "M+", word = "keystone" },
	}
	f.diffCBs = {}
	local prevDiff
	for i, d in ipairs(DIFFS) do
		local cb = MakeCheckbox(f, d.label, function() end)
		if prevDiff then
			cb:SetPoint("LEFT", prevDiff.label, "RIGHT", 10, 0)
		else
			cb:SetPoint("TOPLEFT", raidCB, "BOTTOMLEFT", 0, -2)
		end
		cb:SetScript("OnClick", function(self)
			local nowChecked = self:GetChecked()
			for _, other in ipairs(f.diffCBs) do
				other:SetChecked(false)
			end
			self:SetChecked(nowChecked)
		end)
		cb.word = d.word
		f.diffCBs[i] = cb
		prevDiff = cb
	end

	f.roleCBs = {}
	local anchor
	for _, role in ipairs(ROLE_ORDER) do
		local cb = MakeCheckbox(f, CreateAtlasMarkup(ROLE_UI[role].atlas, 14, 14) .. " " .. ROLE_UI[role].label, function() end)
		if anchor then
			cb:SetPoint("LEFT", anchor.label, "RIGHT", 12, 0)
		else
			cb:SetPoint("TOPLEFT", f.diffCBs[1], "BOTTOMLEFT", 0, -2)
		end
		anchor = cb
		f.roleCBs[role] = cb
	end

	-- default the role selection to whatever the player's current spec is
	local function resetRoleChecks()
		local spec = GetSpecialization and GetSpecialization()
		local myRole = spec and GetSpecializationRole and GetSpecializationRole(spec)
		for role, cb in pairs(f.roleCBs) do
			cb:SetChecked(role == myRole)
		end
	end
	resetRoleChecks()

	local function addRule()
		local db = ns.GetDB()
		local input = f.addBox:GetText() or ""
		if dungeonCB:GetChecked() then
			input = input .. " +dungeon"
		end
		for _, cb in ipairs(f.diffCBs) do
			if cb:GetChecked() then
				input = input .. " " .. cb.word
			end
		end
		for _, role in ipairs(ROLE_ORDER) do
			if f.roleCBs[role]:GetChecked() then
				input = input .. " +" .. ROLE_UI[role].label:lower()
			end
		end
		local rule, err = ns.parseRule(input)
		if not rule then
			ns.msg(err)
			return
		end
		table.insert(db.rules, rule)
		f.addBox:SetText("")
		f.addBox:ClearFocus()
		raidCB:SetChecked(true)
		dungeonCB:SetChecked(false)
		for _, cb in ipairs(f.diffCBs) do
			cb:SetChecked(false)
		end
		resetRoleChecks()
		Refresh()
	end

	f.addButton = MakeButton(f, "Add", 70, addRule)
	f.addButton:SetPoint("LEFT", anchor.label, "RIGHT", 16, 0)
	f.addButton:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
	f.addBox:SetScript("OnEnterPressed", addRule)
	f.addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	-- Footer: status + test
	f.statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statusText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADDING, 12)
	f.statusText:SetPoint("RIGHT", f, "RIGHT", -90, 0)
	f.statusText:SetJustifyH("LEFT")
	f.statusText:SetWordWrap(true)

	f.testButton = MakeButton(f, "Test alert", 74, function()
		ns.TestAlert()
	end)
	f.testButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING, 8)

	return f
end

local function ToggleUI()
	if not ui then
		ui = CreateUI()
	end
	if ui:IsShown() then
		ui:Hide()
	else
		ui:Show()
	end
end
ns.ToggleUI = ToggleUI

-- Bare /pma (or /pma ui) opens the window; everything else falls through to
-- the core handler, then the open window refreshes to reflect it.
local origHandler = SlashCmdList.PREMADEALERT
SlashCmdList.PREMADEALERT = function(input)
	local trimmed = strtrim(input or ""):lower()
	if trimmed == "" or trimmed == "ui" then
		ToggleUI()
		return
	end
	origHandler(input)
	Refresh()
end
