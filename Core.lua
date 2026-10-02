-- ResetRadar: core. Saved data, reset logic, event handling, module registry and slash commands.
-- Everything that touches a game API goes through RR.Call/RR.SafeCall, so one broken API or module never takes the
-- rest of the addon down.

local ADDON_NAME, ns = ...
local L = ns.L

local RR = {}
ns.RR = RR
_G.ResetRadar = RR -- for /dump and debugging

RR.name = ADDON_NAME
RR.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "?"
if RR.version:find("@") then RR.version = "dev" end -- unpackaged git checkout
RR.SCHEMA = 1
RR.DEBOUNCE = 1.5
RR.items = {}          -- checklist definitions, see Checklist.lua
RR.modules = {}        -- name -> module
RR.moduleOrder = {}

local DAY = 86400
local WEEK = 7 * DAY

-- ---------- helpers ----------

function RR.Print(msg)
  print("|cff33ccff" .. L.ADDON_TITLE .. "|r " .. tostring(msg))
end

function RR.Debug(...)
  if RR.db and RR.db.settings.debug then
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("|cff888888[RR debug]|r " .. table.concat(parts, " "))
  end
end

-- pack/unpack that keep nil return values in the middle (plain {...} + unpack can drop them)
local function pack(...) return { n = select("#", ...), ... } end
local function unpackAll(t, from) return unpack(t, from or 1, t.n) end

-- Runs fn in pcall. Returns ok plus fn's results; logs the error in debug mode.
function RR.SafeCall(label, fn, ...)
  if type(fn) ~= "function" then return false end
  local result = pack(pcall(fn, ...))
  if not result[1] then
    RR.Debug(label or "?", "failed:", result[2])
  end
  return unpackAll(result)
end

-- Calls a dotted global API path ("C_WeeklyRewards.GetActivities") if it exists. Returns nil when missing or failing.
function RR.Call(path, ...)
  local fn = _G
  for part in path:gmatch("[^%.]+") do
    if type(fn) ~= "table" then fn = nil break end
    fn = fn[part]
  end
  if type(fn) ~= "function" then
    RR.Debug("API missing:", path)
    return nil
  end
  local result = pack(pcall(fn, ...))
  if not result[1] then
    RR.Debug("API error:", path, result[2])
    return nil
  end
  return unpackAll(result, 2)
end

-- Midnight (12.x) can hand out "secret" values in restricted situations; never compute with those.
function RR.IsSecret(value)
  return issecretvalue ~= nil and issecretvalue(value) or false
end

function RR.Now()
  return time()
end

function RR.FormatDuration(seconds)
  if not seconds or seconds <= 0 then return L.TIME_NOW end
  local d = math.floor(seconds / DAY)
  local h = math.floor((seconds % DAY) / 3600)
  local m = math.floor((seconds % 3600) / 60)
  if d > 0 then return string.format(L.TIME_DH, d, h) end
  if h > 0 then return string.format(L.TIME_HM, h, m) end
  return string.format(L.TIME_M, m)
end

function RR.FormatAgo(timestamp)
  if not timestamp then return L.NEVER end
  return string.format(L.TIME_AGO, RR.FormatDuration(RR.Now() - timestamp))
end

function RR.ClassColored(text, classFile)
  if classFile then
    local color = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile)
    if color then return color:WrapTextInColorCode(text) end
    local raid = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if raid and raid.colorStr then return "|c" .. raid.colorStr .. text .. "|r" end
  end
  return text
end

local function copyDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if type(v) == "table" then
      if type(target[k]) ~= "table" then target[k] = {} end
      copyDefaults(target[k], v)
    elseif target[k] == nil then
      target[k] = v
    end
  end
end
RR.CopyDefaults = copyDefaults

-- ---------- saved variables ----------

local DEFAULTS = {
  schema = 0,
  settings = {
    viewMode = "all",          -- "all" | "current"
    scale = 1.0,
    window = { width = 760, height = 460 },
    minimap = { show = true, angle = 215 },
    loginMessage = true,
    showHidden = false,
    debug = false,
    hiddenRows = {},           -- row path -> true (hidden for everyone)
    modules = {},              -- module name -> enabled
  },
  global = {},                 -- nextDaily / nextWeekly from the live API
  chars = {},                  -- "Name-Realm" -> character record
  account = { manual = {}, manualState = {}, nextManualId = 1 },
  modules = {},                -- module name -> module's own saved table
}

local CHAR_DEFAULTS = {
  hidden = false,
  hiddenItems = {},
  data = {},
  lockouts = {},
  quests = { known = {} },
  professions = {},
  renownStart = {},
}

-- Schema migrations: index = schema version it migrates TO. Never delete data in place; only add or move.
local MIGRATIONS = {
  [1] = function(db)
    -- first schema: nothing to move, copyDefaults fills new fields
  end,
}

function RR:InitDB()
  ResetRadarDB = ResetRadarDB or {}
  local db = ResetRadarDB
  copyDefaults(db, DEFAULTS)
  for version = (db.schema or 0) + 1, RR.SCHEMA do
    if MIGRATIONS[version] then
      local ok, err = pcall(MIGRATIONS[version], db)
      if not ok then RR.Print(string.format(L.MIGRATION_FAILED, version, tostring(err))) end
    end
  end
  db.schema = RR.SCHEMA
  for _, char in pairs(db.chars) do copyDefaults(char, CHAR_DEFAULTS) end
  self.db = db
end

function RR:GetCharKey()
  local name = UnitName("player")
  local realm = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
  if not name or not realm or realm == "" then return nil end
  return name .. "-" .. realm
end

function RR:GetChar(key)
  return self.db and self.db.chars[key]
end

function RR:GetCurrentChar()
  return self.charKey and self.db.chars[self.charKey]
end

function RR:UpdateCharBasics()
  local key = self:GetCharKey()
  if not key then return end
  self.charKey = key
  local char = self.db.chars[key]
  if not char then
    char = {}
    self.db.chars[key] = char
  end
  copyDefaults(char, CHAR_DEFAULTS)
  char.name = UnitName("player")
  char.realm = GetRealmName()
  local _, classFile = UnitClass("player")
  char.class = classFile
  char.level = UnitLevel("player")
  char.faction = UnitFactionGroup("player")
  char.lastSeen = RR.Now()
  return char
end

-- ---------- reset logic ----------

-- Stores the live reset timestamps. They come from the client, so region and server time are handled by the game.
function RR:UpdateResetTimes()
  local now = RR.Now()
  local daily = RR.Call("C_DateAndTime.GetSecondsUntilDailyReset") or (GetQuestResetTime and GetQuestResetTime())
  local weekly = RR.Call("C_DateAndTime.GetSecondsUntilWeeklyReset")
  if daily and not RR.IsSecret(daily) and daily > 0 then self.db.global.nextDaily = now + daily end
  if weekly and not RR.IsSecret(weekly) and weekly > 0 then self.db.global.nextWeekly = now + weekly end
  -- fall back to rolling the stored values forward when the API was unavailable
  local g = self.db.global
  if g.nextDaily then while g.nextDaily <= now do g.nextDaily = g.nextDaily + DAY end end
  if g.nextWeekly then while g.nextWeekly <= now do g.nextWeekly = g.nextWeekly + WEEK end end
end

function RR:GetNextReset(resetType)
  local g = self.db.global
  if resetType == "daily" then return g.nextDaily end
  if resetType == "weekly" then return g.nextWeekly end
  return nil
end

local function resetEntry(entry, def)
  entry.state = "open"
  entry.cur = 0
  entry.expires = nil
  entry.stale = true
  entry.tip = nil
  if def and def.onResetText then entry.text = def.onResetText else entry.text = nil end
end

-- Puts every expired entry of every character back to "open". Cheap; runs on login and whenever the window opens.
function RR:ApplyResets()
  if not self.db then return end
  self:UpdateResetTimes()
  local now = RR.Now()
  for _, char in pairs(self.db.chars) do
    for key, entry in pairs(char.data) do
      local def = self.itemsByKey and self.itemsByKey[key]
      if def and def.onReset and entry.expires and entry.expires <= now then
        RR.SafeCall("onReset " .. key, def.onReset, entry, char)
        entry.expires = nil
      end
      if entry.sub then
        for subKey, sub in pairs(entry.sub) do
          if sub.expires and sub.expires <= now then
            if sub.dropOnReset then
              entry.sub[subKey] = nil
            else
              resetEntry(sub)
            end
          end
        end
      end
      if entry.expires and entry.expires <= now then resetEntry(entry, def) end
    end
    for lockKey, lock in pairs(char.lockouts) do
      if lock.expires and lock.expires <= now then char.lockouts[lockKey] = nil end
    end
  end
  for _, state in pairs(self.db.account.manualState) do
    if state.expires and state.expires <= now then
      state.done = false
      state.expires = nil
    end
  end
  for _, mod in ipairs(self.moduleOrder) do
    if self:IsModuleActive(mod.name) then self:ModuleCall(mod, "OnApplyResets", now) end
  end
end

function RR:ResetCharacter(key)
  local char = self.db.chars[key]
  if not char then return false end
  char.data = {}
  char.lockouts = {}
  char.quests = { known = {} }
  char.lockoutsScanned = nil
  for _, mod in ipairs(self.moduleOrder) do
    if self:IsModuleActive(mod.name) then self:ModuleCall(mod, "OnResetCharacter", key, char) end
  end
  return true
end

function RR:RemoveCharacter(key)
  if key == self.charKey then
    RR.Print(L.CANNOT_REMOVE_CURRENT)
    return false
  end
  self.db.chars[key] = nil
  self:RefreshUI()
  return true
end

-- Finds a character key from user input ("Name" or "Name-Realm", case-insensitive).
function RR:FindCharKey(input)
  if not input or input == "" then return nil end
  input = input:lower()
  local match
  for key, char in pairs(self.db.chars) do
    if key:lower() == input then return key end
    if char.name and char.name:lower() == input then
      if match then return nil, L.AMBIGUOUS_CHAR end
      match = key
    end
  end
  return match
end

-- ---------- checklist registry ----------

-- def = { key, label, resetType = "daily"|"weekly"|nil, scope = "character"|"account", order, check = function(ctx), ... }
function RR:RegisterItem(def)
  assert(def.key and def.label, "checklist item needs key and label")
  def.scope = def.scope or "character"
  def.order = def.order or (#self.items + 1) * 10
  self.items[#self.items + 1] = def
  self.itemsByKey = self.itemsByKey or {}
  self.itemsByKey[def.key] = def
  table.sort(self.items, function(a, b) return a.order < b.order end)
end

-- Runs every check for the current character. Each check is isolated in pcall.
function RR:RunChecks(char)
  local now = RR.Now()
  local ctx = { char = char, now = now, L = L, RR = self }
  for _, def in ipairs(self.items) do
    if def.check and def.scope == "character" then
      local ok, result = RR.SafeCall("check " .. def.key, def.check, ctx)
      if ok and type(result) == "table" then
        local expires = def.resetType and self:GetNextReset(def.resetType)
        if result.expires == nil then result.expires = expires end
        if result.sub then
          for _, sub in pairs(result.sub) do
            if sub.expires == nil and not sub.noExpire then sub.expires = expires end
          end
        end
        result.scannedAt = now
        char.data[def.key] = result
      elseif ok and result == false then
        char.data[def.key] = nil -- check decided this item does not apply
      end
    end
  end
end

-- ---------- manual items ----------

function RR:AddManualItem(label, resetType, scope)
  label = label and strtrim(label)
  if not label or label == "" then return nil end
  local acc = self.db.account
  local id = acc.nextManualId
  acc.nextManualId = id + 1
  acc.manual[id] = { label = label, resetType = resetType or "weekly", scope = scope or "character" }
  self:RefreshUI()
  return id
end

function RR:RemoveManualItem(id)
  self.db.account.manual[id] = nil
  self.db.account.manualState[id] = nil
  for _, char in pairs(self.db.chars) do char.data["manual:" .. id] = nil end
  self:RefreshUI()
end

function RR:GetManualState(id, charKey)
  local item = self.db.account.manual[id]
  if not item then return nil end
  if item.scope == "account" then
    return self.db.account.manualState[id]
  end
  local char = self.db.chars[charKey]
  return char and char.data["manual:" .. id]
end

function RR:ToggleManual(id, charKey)
  local item = self.db.account.manual[id]
  if not item then return end
  local state
  if item.scope == "account" then
    state = self.db.account.manualState[id] or {}
    self.db.account.manualState[id] = state
  else
    local char = self.db.chars[charKey]
    if not char then return end
    state = char.data["manual:" .. id] or {}
    char.data["manual:" .. id] = state
  end
  state.done = not state.done
  state.expires = state.done and self:GetNextReset(item.resetType) or nil
  state.state = state.done and "done" or "open"
  self:RefreshUI()
end

-- ---------- summaries (minimap tooltip, login message) ----------

local COUNTED = { open = true, progress = true, done = true }

-- Counts checklist rows for one character. Returns { weeklyOpen, weeklyTotal, dailyOpen, dailyTotal, openLabels }.
function RR:GetSummary(charKey)
  local char = self.db.chars[charKey]
  local s = { weeklyOpen = 0, weeklyTotal = 0, dailyOpen = 0, dailyTotal = 0, openLabels = {} }
  if not char then return s end
  local hiddenRows = self.db.settings.hiddenRows
  local function count(path, resetType, state, label)
    if not resetType or not COUNTED[state] then return end
    if hiddenRows[path] or char.hiddenItems[path] then return end
    local prefix = resetType == "daily" and "daily" or "weekly"
    s[prefix .. "Total"] = s[prefix .. "Total"] + 1
    if state ~= "done" then
      s[prefix .. "Open"] = s[prefix .. "Open"] + 1
      s.openLabels[#s.openLabels + 1] = label
    end
  end
  for _, def in ipairs(self.items) do
    local entry = char.data[def.key]
    if entry and not def.noSummary and not hiddenRows[def.key] and not char.hiddenItems[def.key] then
      if entry.sub then
        for subKey, sub in pairs(entry.sub) do
          if not sub.noSummary then
            count(def.key .. ":" .. subKey, sub.resetType or def.resetType, sub.state, sub.label or def.label)
          end
        end
      else
        count(def.key, def.resetType, entry.state, def.label)
      end
    end
  end
  for id, item in pairs(self.db.account.manual) do
    local state = self:GetManualState(id, charKey)
    count("manual:" .. id, item.resetType, state and state.done and "done" or "open", item.label)
  end
  return s
end

function RR:ShowLoginMessage()
  if not self.db.settings.loginMessage or not self.charKey then return end
  local s = self:GetSummary(self.charKey)
  local line = string.format(L.LOGIN_SUMMARY, s.weeklyOpen, s.weeklyTotal, s.dailyOpen, s.dailyTotal)
  if #s.openLabels > 0 then
    local shown = {}
    for i = 1, math.min(5, #s.openLabels) do shown[i] = s.openLabels[i] end
    line = line .. " " .. table.concat(shown, ", ") .. (#s.openLabels > 5 and ", ..." or "")
  end
  RR.Print(line)
  for _, mod in ipairs(self.moduleOrder) do
    if self:IsModuleActive(mod.name) then
      local ok, extra = self:ModuleCall(mod, "GetLoginLine")
      if ok and extra then RR.Print(extra) end
    end
  end
end

-- ---------- modules ----------

-- mod = { title, defaultEnabled, events = {...}, defaults = {...}, OnInitialize, OnEnable, OnDisable, OnEvent,
--         OnScan(char), OnApplyResets(now), GetTabs() -> { {key, label, build(parent), refresh()} },
--         GetMinimapLines(lines), GetLoginLine(), BuildSettings(panel, y) -> y }
function RR:RegisterModule(name, mod)
  mod.name = name
  mod.errors = 0
  self.modules[name] = mod
  self.moduleOrder[#self.moduleOrder + 1] = mod
  return mod
end

local MAX_MODULE_ERRORS = 10

-- Calls a module method in pcall. A module that keeps failing is switched off for this session.
function RR:ModuleCall(mod, method, ...)
  if mod.broken or type(mod[method]) ~= "function" then return false end
  local result = pack(pcall(mod[method], mod, ...))
  if not result[1] then
    mod.errors = mod.errors + 1
    RR.Debug("module", mod.name, method, "failed:", result[2])
    if mod.errors >= MAX_MODULE_ERRORS then
      mod.broken = true
      RR.Print(string.format(L.MODULE_BROKEN, mod.title or mod.name))
    end
  end
  return unpackAll(result)
end

function RR:IsModuleEnabled(name)
  local mod = self.modules[name]
  if not mod then return false end
  local setting = self.db.settings.modules[name]
  if setting == nil then return mod.defaultEnabled and true or false end
  return setting
end

function RR:IsModuleActive(name)
  local mod = self.modules[name]
  return mod and mod.active and not mod.broken
end

function RR:SetModuleEnabled(name, enabled)
  local mod = self.modules[name]
  if not mod then return end
  self.db.settings.modules[name] = enabled and true or false
  if enabled and not mod.active then
    mod.active = true
    self:RegisterEvents(mod.events)
    self:ModuleCall(mod, "OnEnable")
  elseif not enabled and mod.active then
    mod.active = false
    self:ModuleCall(mod, "OnDisable")
  end
  if self.OnModulesChanged then self:OnModulesChanged() end
  self:RequestScan("module toggled")
end

function RR:InitModules()
  for _, mod in ipairs(self.moduleOrder) do
    self.db.modules[mod.name] = self.db.modules[mod.name] or {}
    mod.db = self.db.modules[mod.name]
    if mod.defaults then copyDefaults(mod.db, mod.defaults) end
    self:ModuleCall(mod, "OnInitialize", mod.db)
    if self:IsModuleEnabled(mod.name) then
      mod.active = true
      self:RegisterEvents(mod.events)
      self:ModuleCall(mod, "OnEnable")
    end
  end
end

-- ---------- scanning ----------

local scanTimer
local pendingAfterCombat = false

function RR:RequestScan(reason)
  if not self.db then return end
  RR.Debug("scan requested:", reason)
  if scanTimer then return end
  scanTimer = C_Timer.NewTimer(RR.DEBOUNCE, function()
    scanTimer = nil
    RR:Scan()
  end)
end

function RR:Scan()
  if InCombatLockdown() then
    pendingAfterCombat = true
    return
  end
  local char = self:UpdateCharBasics()
  if not char then return end
  self:UpdateResetTimes()
  self:ApplyResets()
  self:RunChecks(char)
  for _, mod in ipairs(self.moduleOrder) do
    if self:IsModuleActive(mod.name) then self:ModuleCall(mod, "OnScan", char) end
  end
  self:RefreshUI()
end

-- Raid/dungeon lockouts. Filled from UPDATE_INSTANCE_INFO after RequestRaidInfo(); shared by checklist and modules.
function RR:ScanLockouts()
  local char = self:GetCurrentChar()
  if not char or not GetNumSavedInstances then return end
  local now = RR.Now()
  local lockouts = {}
  local count = RR.Call("GetNumSavedInstances") or 0
  for i = 1, count do
    local name, _, reset, difficultyID, locked, extended, _, isRaid, _, difficultyName, numEncounters,
      encounterProgress, _, instanceID = GetSavedInstanceInfo(i)
    if name and (locked or extended) and reset and reset > 0 then
      local killed = {}
      for e = 1, numEncounters or 0 do
        local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, e)
        if bossName and isKilled then killed[bossName:lower()] = true end
      end
      local key = tostring(instanceID or name) .. ":" .. tostring(difficultyID)
      lockouts[key] = {
        name = name, nameLower = name:lower(), instanceID = instanceID, difficultyID = difficultyID,
        difficultyName = difficultyName, isRaid = isRaid, numEncounters = numEncounters or 0,
        progress = encounterProgress or 0, killed = killed, expires = now + reset, extended = extended,
      }
    end
  end
  char.lockouts = lockouts
  char.lockoutsScanned = now
  -- world bosses share the same request
  local bosses = {}
  for i = 1, (RR.Call("GetNumSavedWorldBosses") or 0) do
    local bossName, _, reset = GetSavedWorldBossInfo(i)
    if bossName then bosses[#bosses + 1] = { name = bossName, expires = now + (reset or 0) } end
  end
  char.worldBosses = bosses
end

-- ---------- events ----------

local frame = CreateFrame("Frame")
RR.eventFrame = frame
local registered = {}

-- Registers events in pcall: an event name that no longer exists is skipped and reported in debug mode.
function RR:RegisterEvents(events)
  for _, event in ipairs(events or {}) do
    if not registered[event] then
      local ok = pcall(frame.RegisterEvent, frame, event)
      registered[event] = ok and true or "missing"
      if not ok then RR.Debug("event not available:", event) end
    end
  end
end

local CORE_EVENTS = {
  "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "PLAYER_REGEN_ENABLED", "PLAYER_LEVEL_UP",
  "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "UPDATE_INSTANCE_INFO", "BOSS_KILL", "ENCOUNTER_END",
  "WEEKLY_REWARDS_UPDATE", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_MAPS_UPDATE", "CURRENCY_DISPLAY_UPDATE",
  "TRADE_SKILL_LIST_UPDATE", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "CALENDAR_UPDATE_EVENT_LIST",
  "NEW_MOUNT_ADDED", "TRANSMOG_COLLECTION_UPDATED", "MERCHANT_SHOW", "MERCHANT_CLOSED",
}

local SCAN_EVENTS = {
  PLAYER_ENTERING_WORLD = true, QUEST_LOG_UPDATE = true, WEEKLY_REWARDS_UPDATE = true,
  CHALLENGE_MODE_COMPLETED = true, CHALLENGE_MODE_MAPS_UPDATE = true, CURRENCY_DISPLAY_UPDATE = true,
  TRADE_SKILL_LIST_UPDATE = true, MAJOR_FACTION_RENOWN_LEVEL_CHANGED = true, PLAYER_LEVEL_UP = true,
  NEW_MOUNT_ADDED = true, TRANSMOG_COLLECTION_UPDATED = true,
}

local function requestRaidInfoSoon()
  C_Timer.After(2, function()
    if RequestRaidInfo then RequestRaidInfo() end
  end)
end

local handlers = {}

function handlers.PLAYER_LOGIN()
  RR:InitDB()
  local char = RR:UpdateCharBasics()
  if char then char.lastLogin = RR.Now() end
  RR:UpdateResetTimes()
  RR:InitModules()
  RR:ApplyResets()
  if RR.InitUI then RR.SafeCall("InitUI", RR.InitUI, RR) end
  if RR.InitSettings then RR.SafeCall("InitSettings", RR.InitSettings, RR) end
  if RequestRaidInfo then RequestRaidInfo() end
  RR.Call("C_MythicPlus.RequestMapInfo")
  RR.Call("C_MythicPlus.RequestRewards")
  RR.Call("C_Calendar.OpenCalendar")
  RR:RequestScan("login")
  C_Timer.After(6, function() RR.SafeCall("login message", RR.ShowLoginMessage, RR) end)
end

function handlers.PLAYER_LOGOUT()
  local char = RR:GetCurrentChar()
  if char then
    char.lastSeen = RR.Now()
    char.level = UnitLevel("player")
  end
end

function handlers.PLAYER_REGEN_ENABLED()
  if pendingAfterCombat then
    pendingAfterCombat = false
    RR:RequestScan("after combat")
  end
end

function handlers.UPDATE_INSTANCE_INFO()
  if InCombatLockdown() then
    pendingAfterCombat = true
    return
  end
  RR.SafeCall("ScanLockouts", RR.ScanLockouts, RR)
  RR:RequestScan("instance info")
end

function handlers.BOSS_KILL()
  requestRaidInfoSoon()
end

function handlers.ENCOUNTER_END(_, _, _, _, _, success)
  if success == 1 then requestRaidInfoSoon() end
end

function handlers.QUEST_TURNED_IN(questID)
  local char = RR:GetCurrentChar()
  local known = char and char.quests.known[questID]
  if known then
    known.doneAt = RR.Now()
  end
  RR:RequestScan("quest turned in")
end

function handlers.CALENDAR_UPDATE_EVENT_LIST()
  RR.SafeCall("ScanCalendar", RR.ScanCalendar, RR)
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event ~= "PLAYER_LOGIN" and not RR.db then return end
  local handler = handlers[event]
  if handler then RR.SafeCall(event, handler, ...) end
  if SCAN_EVENTS[event] then RR:RequestScan(event) end
  for _, mod in ipairs(RR.moduleOrder) do
    if mod.active and not mod.broken and mod.OnEvent then RR:ModuleCall(mod, "OnEvent", event, ...) end
  end
end)

RR:RegisterEvents(CORE_EVENTS)

-- ---------- calendar (active holidays such as Timewalking or the weekly bonus event) ----------

function RR:ScanCalendar()
  local today = RR.Call("C_DateAndTime.GetCurrentCalendarTime")
  if not today or not C_Calendar or not C_Calendar.GetNumDayEvents then return end
  local events = {}
  local num = RR.Call("C_Calendar.GetNumDayEvents", 0, today.monthDay) or 0
  for i = 1, num do
    local event = RR.Call("C_Calendar.GetDayEvent", 0, today.monthDay, i)
    if event and event.calendarType == "HOLIDAY" and event.title then
      events[#events + 1] = event.title
    end
  end
  self.db.global.activeEvents = events
  self.db.global.activeEventsDay = today.monthDay
  self:RefreshUI()
end

-- ---------- UI hooks (filled in by UI.lua) ----------

function RR:RefreshUI()
  if self.ui and self.ui.Refresh then RR.SafeCall("RefreshUI", self.ui.Refresh, self.ui) end
end

-- ---------- slash commands ----------

SLASH_RESETRADAR1 = "/resetradar"
SLASH_RESETRADAR2 = "/rradar"
SlashCmdList.RESETRADAR = function(input)
  if not RR.db then return end
  local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    RR:ToggleWindow()
  elseif cmd == "config" or cmd == "options" then
    RR:OpenSettings()
  elseif cmd == "farm" then
    RR:ShowWindow("farm")
  elseif cmd == "loot" then
    if RR:IsModuleActive("LootManager") then
      RR:ShowWindow("loot")
    else
      RR.Print(L.LOOT_DISABLED_HINT)
    end
  elseif cmd == "reset" then
    local key, err = RR:FindCharKey(rest)
    if key and RR:ResetCharacter(key) then
      RR.Print(string.format(L.CHAR_RESET_DONE, key))
      if key == RR.charKey then
        if RequestRaidInfo then RequestRaidInfo() end
        RR:RequestScan("manual reset")
      end
      RR:RefreshUI()
    else
      RR.Print(err or string.format(L.CHAR_NOT_FOUND, rest or ""))
    end
  elseif cmd == "debug" then
    RR.db.settings.debug = not RR.db.settings.debug
    RR.Print(RR.db.settings.debug and L.DEBUG_ON or L.DEBUG_OFF)
  elseif cmd == "scan" then
    if RequestRaidInfo then RequestRaidInfo() end
    RR:RequestScan("slash")
  else
    RR.Print(L.SLASH_HELP)
  end
end

function RR:ToggleWindow(tab)
  if self.ui and self.ui.Toggle then self.ui:Toggle(tab) else RR.Print(L.UI_NOT_READY) end
end

function RR:ShowWindow(tab)
  if self.ui and self.ui.Show then self.ui:Show(tab) else RR.Print(L.UI_NOT_READY) end
end

function RR:OpenSettings()
  if self.settingsCategory and Settings and Settings.OpenToCategory then
    local id = self.settingsCategory.GetID and self.settingsCategory:GetID() or self.settingsCategory.ID
    Settings.OpenToCategory(id)
  else
    RR.Print(L.SETTINGS_UNAVAILABLE)
  end
end
