time = os.time; date = os.date; unpack = unpack or table.unpack
-- Minimal WoW API mock for load/run testing.
local function newObj(kind)
  local o = { _kind = kind, _scripts = {}, _shown = true, _text = "", _w = 800, _h = 400, _checked = false, _enabled = true }
  return setmetatable(o, { __index = function(t, k)
    local impl = {
      SetScript = function(self, name, fn) self._scripts[name] = fn end,
      GetScript = function(self, name) return self._scripts[name] end,
      CreateFontString = function() return newObj("FontString") end,
      CreateTexture = function() return newObj("Texture") end,
      GetHighlightTexture = function() return newObj("Texture") end,
      GetWidth = function(self) return self._w end, GetHeight = function(self) return self._h end,
      SetWidth = function(self, w) self._w = w end, SetHeight = function(self, h) self._h = h end,
      SetSize = function(self, w, h) self._w, self._h = w, h end,
      Show = function(self) self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end,
      Hide = function(self) self._shown = false end,
      SetShown = function(self, v) self._shown = v and true or false end,
      IsShown = function(self) return self._shown end, IsVisible = function(self) return self._shown end,
      SetText = function(self, s) self._text = s end, GetText = function(self) return self._text end,
      GetStringWidth = function() return 50 end, GetStringHeight = function() return 12 end,
      GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
      SetChecked = function(self, v) self._checked = v end, GetChecked = function(self) return self._checked end,
      SetEnabled = function(self, v) self._enabled = v end, IsEnabled = function(self) return self._enabled end,
      GetVerticalScroll = function() return 0 end, HasFocus = function() return false end,
      GetEffectiveScale = function() return 1 end, GetCenter = function() return 0, 0 end,
      IsMouseOver = function() return false end, NumLines = function() return 1 end,
      GetItem = function() return "Test", "|Hitem:1234|h[Test]|h" end,
      Click = function(self) if self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end end,
      RegisterEvent = function(self, e) if e == "BOGUS_EVENT" then error("unknown event") end end,
    }
    return impl[k] or function() end
  end })
end
MOCK_FRAMES = {}
function CreateFrame(kind, name, parent, template)
  local f = newObj(kind)
  if name then _G[name] = f end
  table.insert(MOCK_FRAMES, f)
  return f
end
UIParent = newObj("Frame"); Minimap = newObj("Frame"); GameTooltip = newObj("GameTooltip"); ItemRefTooltip = newObj("GameTooltip")
MerchantFrame = newObj("Frame"); ChatFontNormal = {}
UISpecialFrames = {}; StaticPopupDialogs = {}; function StaticPopup_Show(n, a) MOCK_POPUP = n end
YES, NO, CANCEL, CLOSE = "Yes", "No", "Cancel", "Close"
BackdropTemplateMixin = {}; function Mixin(o, m) return o end
RAID_CLASS_COLORS = { MAGE = { colorStr = "ff3fc7eb" } }
LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage", WARRIOR = "Warrior", PALADIN = "Paladin" }
ITEM_CLASSES_ALLOWED = "Classes: %s"; ITEM_SOULBOUND = "Soulbound"; ITEM_BIND_ON_EQUIP = "Binds when equipped"
ITEM_ACCOUNTBOUND_UNTIL_EQUIP = "Warbound until equipped"; ITEM_ACCOUNTBOUND = "Warbound"
LE_EXPANSION_LEVEL_CURRENT = 11; NUM_BAG_SLOTS = 4
Enum = { WeeklyRewardChestThresholdType = { Activities = 1, Raid = 3, World = 6 }, QuestFrequency = { Default = 0, Daily = 1, Weekly = 2 },
  ItemClass = { Weapon = 2, Armor = 4, Questitem = 12 }, TooltipDataType = { Item = 0 } }
function hooksecurefunc() end
function ChatEdit_InsertLink() end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
function GetCursorPosition() return 0, 0 end
function InCombatLockdown() return MOCK_COMBAT or false end
function UnitName() return MOCK_NAME or "Tester" end
function GetNormalizedRealmName() return "Silvermoon" end
function GetRealmName() return "Silvermoon" end
function UnitClass() return "Mage", "MAGE" end
function UnitLevel() return 90 end
function UnitFactionGroup() return "Alliance" end
function GetMoney() return MOCK_MONEY or 1000 end
function GetMoneyString(c) return tostring(c) .. "c" end
function GetAverageItemLevel() return 250, 245 end
function GetDifficultyInfo(id) return "Diff" .. id end
function RequestRaidInfo() MOCK_RAIDINFO = (MOCK_RAIDINFO or 0) + 1 end
function GetNumSavedInstances() return 1 end
function GetSavedInstanceInfo(i) return "Icecrown Citadel", 1, 3600*24*3, 6, true, false, 0, true, 25, "25 Player (Heroic)", 12, 3, false, 631 end
function GetSavedInstanceEncounterInfo(i, e) local names = { "Lord Marrowgar", "Lady Deathwhisper", "The Lich King" } return names[e] or ("Boss" .. e), nil, e <= 2 end
function GetNumSavedWorldBosses() return 0 end
function GetProfessions() return 1, nil, nil, nil, 5 end
function GetProfessionInfo(i) return i == 1 and "Alchemy" or "Cooking", 0, 50, 100 end
function GetExpansionLevel() return 11 end
function PlayerHasToy() return false end
local timers = {}
C_Timer = {
  After = function(s, fn) table.insert(timers, fn) end,
  NewTimer = function(s, fn) table.insert(timers, fn); return { Cancel = function() end } end,
}
function MOCK_RUN_TIMERS() for i = 1, 50 do local t = timers; timers = {}; if #t == 0 then return end; for _, fn in ipairs(t) do fn() end end end
C_AddOns = { GetAddOnMetadata = function() return "1.0.0" end }
C_ClassColor = { GetClassColor = function(c) return { WrapTextInColorCode = function(self, t) return "|cff" .. t .. "|r" end } end }
C_DateAndTime = { GetSecondsUntilDailyReset = function() return 3600 end, GetSecondsUntilWeeklyReset = function() return 86400 * 2 end,
  GetCurrentCalendarTime = function() return { monthDay = 2 } end }
C_Calendar = { OpenCalendar = function() end, GetNumDayEvents = function() return 1 end, GetDayEvent = function() return { calendarType = "HOLIDAY", title = "Timewalking" } end }
C_WeeklyRewards = { GetActivities = function(t) return { { index = 1, progress = 2, threshold = 1, level = 10 }, { index = 2, progress = 2, threshold = 4 }, { index = 3, progress = 2, threshold = 8 } } end,
  HasAvailableRewards = function() return false end }
C_MythicPlus = { GetOwnedKeystoneChallengeMapID = function() return 500 end, GetOwnedKeystoneLevel = function() return 12 end,
  GetRunHistory = function() return { { level = 10 } } end, RequestMapInfo = function() end, RequestRewards = function() end }
C_ChallengeMode = { GetMapUIInfo = function() return "Test Dungeon" end }
C_QuestLog = { GetNumQuestLogEntries = function() return 2 end,
  GetInfo = function(i) if i == 1 then return { questID = 100, title = "Weekly A", frequency = 2 } end return { questID = 200, title = "Daily B", frequency = 1 } end,
  IsQuestFlaggedCompleted = function(id) return id == 200 end, IsOnQuest = function() return false end }
C_CurrencyInfo = { GetCurrencyListSize = function() return 1 end, GetCurrencyListInfo = function() return { isHeader = false } end,
  GetCurrencyListLink = function() return "currency:3000" end, GetCurrencyIDFromLink = function() return 3000 end,
  GetCurrencyInfo = function(id) return { name = "Crests", quantity = 10, maxWeeklyQuantity = 90, quantityEarnedThisWeek = 30 } end }
C_TradeSkillUI = { GetChildProfessionInfo = function() return nil end }
C_MajorFactions = { GetMajorFactionIDs = function() return { 1 } end, GetMajorFactionData = function() return { name = "Faction", renownLevel = 5, renownReputationEarned = 100, renownLevelThreshold = 2500 } end }
C_Item = { GetItemInfo = function(x) return "Item", "|Hitem:" .. tostring(x) .. "|h[Item]|h", MOCK_QUALITY or 0, 1, 1, "Armor", "Cloth", 1, "INVTYPE_HEAD", 1, 50, 4, 1, 1, 11, nil end,
  GetItemIconByID = function() return 1 end, GetItemInfoInstant = function(id) return id, "Armor", "Plate", "INVTYPE_CHEST", 1, 4, 4 end, GetCurrentItemLevel = function() return 100 end }
C_MountJournal = { GetMountFromItem = function(id) if id == 50818 then return 363 end end, GetMountInfoByID = function() return "Invincible", 1, 1, false, true, 0, false, false, 0, false, false end }
C_PetJournal = { GetPetInfoByItemID = function() return nil end }
C_ToyBox = { GetToyInfo = function() return nil end }
C_TransmogCollection = { GetItemInfo = function(x)
    local id = tonumber(tostring(x):match("item:(%d+)") or x)
    if id and id >= 2000 and id < 3000 then return id, id * 10 + (tonumber(tostring(x):match("item:%d+:(%d+)")) or 0) end
    return 10, 20 end,
  GetAppearanceInfoBySource = function(src) if MOCK_COLLECTED_SRC and MOCK_COLLECTED_SRC[src] then return { appearanceIsCollected = true, sourceIsCollected = true } end return { appearanceIsCollected = MOCK_COLLECTED or false, sourceIsCollected = false } end }
C_Container = { GetContainerNumSlots = function(b) return b == 0 and 2 or 0 end,
  GetContainerItemInfo = function(b, s) return { itemID = 1000 + s, hyperlink = "|Hitem:" .. (1000 + s) .. "|h[X]|h", stackCount = 1, iconFileID = 1 } end,
  UseContainerItem = function(b, s) MOCK_SOLD = (MOCK_SOLD or 0) + 1 end }
C_TooltipInfo = { GetBagItem = function() return { lines = { { leftText = "Warbound until equipped" }, { leftText = "Classes: Mage" } } } end }
C_EquipmentSet = { GetEquipmentSetIDs = function() return {} end }
ItemLocation = { CreateFromBagAndSlot = function() return {} end }
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) MOCK_TTFN = fn end }
MenuUtil = { CreateContextMenu = function(owner, gen) local root; root = { CreateTitle = function() end, CreateButton = function() return root end, SetEnabled = function() end }; gen(owner, root) end }
EJ_GetNumTiers = function() return 1 end; EJ_GetTierInfo = function() return "Wrath of the Lich King" end; EJ_SelectTier = function() end; EJ_GetCurrentTier = function() return 1 end
EJ_GetInstanceByIndex = function(i, raid) if i == 1 and raid then return 758, "Icecrown Citadel" end end
EJ_GetInstanceInfo = function() return "Icecrown Citadel", nil, nil, nil, nil, nil, nil, nil, nil, 631 end
EJ_SelectInstance = function() end
EJ_GetEncounterInfoByIndex = function(e) local n = { "Lord Marrowgar", "The Lich King" } if n[e] then return n[e], nil, e end end
EJ_IsValidInstanceDifficulty = function(d) return d == 6 or d == 5 end
EJ_SetDifficulty = function(d) MOCK_EJ_DIFF = d end
EJ_SetLootFilter = function(c, sp) MOCK_EJ_FILTER = c end
EJ_GetLootFilter = function() return 8, 0 end
local lootReads = 0
EJ_GetNumLoot = function() return 4 end
C_EncounterJournal = { GetLootInfoByIndex = function(i)
  lootReads = lootReads + 1
  local items = { { itemID = 50818, encounterID = 2 }, { itemID = 2001, encounterID = 1 }, { itemID = 2002, encounterID = 2 }, { itemID = 2003, encounterID = 2 } }
  local it = items[i]
  if lootReads <= 4 then return { itemID = it.itemID, encounterID = it.encounterID } end -- first pass: not loaded yet
  return { itemID = it.itemID, encounterID = it.encounterID, link = "|Hitem:" .. it.itemID .. ":" .. MOCK_EJ_DIFF .. "|h[x]|h" }
end }
function GetBuildInfo() return "12.1.5", "99999", "Oct 1 2026", 120105 end
Settings = { RegisterCanvasLayoutCategory = function(p, n) return { GetID = function() return 1 end } end, RegisterAddOnCategory = function() end, OpenToCategory = function() MOCK_SETTINGS_OPENED = true end }
SlashCmdList = {}
