-- Shared luacheck config for ptarjan's WoW addons.
-- Canonical copy: D:\World of Warcraft\tools\luacheckrc_shared.lua
-- Each repo carries a copy as .luacheckrc (FixRaid appends legacy globals).
-- Run locally: "D:\World of Warcraft\tools\luacheck.exe" .

std = "lua51"
max_line_length = false
unused_args = false
self = false
exclude_files = { "libs", "locales", "tools" }

-- WoW API, frames, and constants these addons read
read_globals = {
    -- API namespaces
    "C_AddOns", "C_ChatInfo", "C_DamageMeter", "C_FriendList", "C_Item",
    "C_LFGList", "C_Spell", "C_Timer", "Enum",
    -- functions
    "AuraUtil", "CanInspect", "ChatFrameUtil", "CreateAtlasMarkup",
    "CreateFrame", "FlashClientIcon", "GetAddOnMetadata",
    "GetBindingFromClick", "GetBindingKey", "GetCurrentKeyBoardFocus",
    "GetGuildInfo", "GetInspectSpecialization", "GetInstanceInfo",
    "GetItemInfo", "GetLocale", "GetNumGroupMembers", "GetPlayerInfoByGUID",
    "GetRaidRosterInfo", "GetRaidTargetIndex", "GetRealZoneText",
    "GetRealmName", "GetReadyCheckStatus", "GetSpecialization",
    "GetSpecializationInfo", "GetSpecializationRole", "GetTime",
    "GetUnitName", "GuildControlGetNumRanks", "GuildControlGetRankName",
    "InCombatLockdown", "IsControlKeyDown", "IsInGroup", "IsInInstance",
    "IsInRaid", "IsShiftKeyDown", "NotifyInspect", "OpenFriendsFrame",
    "PlaySound", "RaidNotice_AddMessage", "RandomRoll", "SendChatMessage",
    "SetRaidSubgroup", "StaticPopup_Show", "SwapRaidSubgroup",
    "ToggleFriendsFrame", "UnitClass", "UnitExists", "UnitFullName",
    "UnitGroupRolesAssigned", "UnitIsConnected", "UnitIsDeadOrGhost",
    "UnitIsGroupLeader", "UnitIsInMyGuild", "UnitIsRaidOfficer",
    "UnitIsUnit", "UnitName", "debugprofilestop", "hooksecurefunc",
    "issecretvalue", "securecallfunction",
    -- Lua shims WoW exposes as globals
    "date", "time", "strsplit", "strtrim", "strbyte", "strfind", "strlen",
    "strlower", "strmatch", "strsub", "strupper", "tinsert", "tremove",
    "wipe", "format", "gmatch", "gsub", "floor", "ceil", "max", "min",
    "sort", "random", "tconcat",
    -- frames and UI objects
    "DEFAULT_CHAT_FRAME", "GameTooltip", "GameFontHighlight",
    "GameFontHighlightLarge", "InterfaceOptionsFrame", "LFGListFrame",
    "RaidFrame", "RaidWarningFrame", "SettingsPanel", "UIParent",
    "WorldFrame", "BackdropTemplateMixin",
    -- constants and localized strings
    "CHAT_MSG_RAID", "CLASS_SORT_ORDER", "ChatTypeInfo",
    "ERR_RAID_MEMBER_ADDED_S", "ERR_RAID_MEMBER_REMOVED_S",
    "ERR_RAID_YOU_JOINED", "FILL_PLUS_STATUS_BAR",
    "GROUP_FINDER_CATEGORY_ID_DUNGEONS", "INLINE_HEALER_ICON",
    "INLINE_TANK_ICON", "LE_PARTY_CATEGORY_INSTANCE",
    "LOCALIZED_CLASS_NAMES_FEMALE", "LOCALIZED_CLASS_NAMES_MALE",
    "RAID_CLASS_COLORS", "RANDOM_ROLL_RESULT", "ROLE_CHANGED_INFORM",
    "SOUNDKIT", "TANK", "HEALER", "UNKNOWN",
    -- other addons integrated with
    "AceGUI", "DBM", "Details", "ElvUI", "LibStub", "Recount", "Skada",
    "tdpsPet", "tdpsPlayer",
}

-- globals these addons own or are allowed to write
globals = {
    -- SavedVariables
    "ReadyCheckShameDB", "CauldronTrackerDB", "AmbientLFGDB", "FixRaidDB",
    "TranscendenceReminderDB",
    -- slash command registration
    "SlashCmdList",
    "SLASH_AMBIENTLFG1", "SLASH_AMBIENTLFG2", "SLASH_AMBIENTLFG3",
    "SLASH_CAULDRON1", "SLASH_CAULDRON2",
    "SLASH_READYCHECKSTATS1", "SLASH_READYCHECKSTATS2",
    -- Blizzard tables addons legitimately add entries to
    "StaticPopupDialogs", "UISpecialFrames",
}
