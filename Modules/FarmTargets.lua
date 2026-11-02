-- ResetRadar module: Farm Targets.
-- Shows per character whether a farm source (raid/dungeon boss on a difficulty, or a daily/weekly quest) is still
-- available this reset. It never claims drop chances: "chance" only means "a kill / loot roll is still available".
-- Lockout data comes from the core scan (RequestRaidInfo -> UPDATE_INSTANCE_INFO -> char.lockouts).

local _, ns = ...
local RR, L = ns.RR, ns.L

local M = {
  title = L.FARM_TITLE,
  description = L.FARM_DESC,
  defaultEnabled = true,
  events = { "NEW_MOUNT_ADDED", "NEW_PET_ADDED", "NEW_TOY_ADDED", "TRANSMOG_COLLECTION_UPDATED", "GET_ITEM_INFO_RECEIVED",
    "TRANSMOG_COLLECTION_SOURCE_ADDED", "ENCOUNTER_END", "ENCOUNTER_LOOT_RECEIVED", "CHAT_MSG_LOOT" },
  defaults = {
    targets = {},
    nextId = 1,
    starterAdded = false,
    collectedMode = "show",   -- "show" (greyed, marked collected) | "hide"
    loginLine = true,
    collected = {},           -- target id -> true (account-wide cache)
    attempts = {},            -- itemID -> { count, last, gotAt, gotCount } (account-wide, like Rarity)
    attemptSeen = {},         -- "char:item:boss:difficulty" -> expires; one attempt per lockout
    alerts = true,            -- raid-warning text when a target drops or gets collected
    alertSound = true,
  },
}

-- Difficulty IDs (see DifficultyID on warcraft.wiki.gg). Labels come from GetDifficultyInfo when available.
local DIFFICULTIES = { 1, 2, 23, 3, 4, 5, 6, 7, 9, 14, 15, 16, 17, 33 }

local function difficultyName(id)
  local name = GetDifficultyInfo and GetDifficultyInfo(id)
  return name or ("#" .. tostring(id))
end

-- Starter list. Instance map IDs, boss names and difficulty IDs are best knowledge, not verified in-game for 12.x:
-- check them with /rradar debug and the lockout tooltip, and edit via the form if needed.
-- shareLockout = true means one kill on any listed difficulty uses up the chance on all of them.
local STARTER = {
  { itemID = 50818, sources = { { type = "lockout", mapID = 631, instance = "Icecrown Citadel", encounter = "The Lich King", difficulties = { 6 }, resetType = "weekly" } } },
  { itemID = 45693, sources = { { type = "lockout", mapID = 603, instance = "Ulduar", encounter = "Yogg-Saron", difficulties = { 4 }, resetType = "weekly" } } },
  { itemID = 32458, sources = { { type = "lockout", mapID = 550, instance = "Tempest Keep", encounter = "Kael'thas Sunstrider", difficulties = { 4 }, resetType = "weekly" } } },
  { itemID = 30480, sources = { { type = "lockout", mapID = 532, instance = "Karazhan", encounter = "Attumen the Huntsman", difficulties = { 3 }, resetType = "weekly" } } },
  { itemID = 49636, sources = { { type = "lockout", mapID = 249, instance = "Onyxia's Lair", encounter = "Onyxia", difficulties = { 3, 4 }, resetType = "weekly" } } },
  { itemID = 63040, sources = { { type = "lockout", mapID = 657, instance = "The Vortex Pinnacle", encounter = "Altairus", difficulties = { 2 }, resetType = "daily" } } },
  { itemID = 44151, sources = { { type = "lockout", mapID = 575, instance = "Utgarde Pinnacle", encounter = "Skadi the Ruthless", difficulties = { 2 }, resetType = "daily" } } },
  { itemID = 32768, sources = { { type = "lockout", mapID = 556, instance = "Sethekk Halls", encounter = "Anzu", difficulties = { 2 }, resetType = "daily" } } },
  { itemID = 35513, sources = { { type = "lockout", mapID = 585, instance = "Magisters' Terrace", encounter = "Kael'thas Sunstrider", difficulties = { 2 }, resetType = "daily" } } },
  { itemID = 87777, sources = { { type = "lockout", mapID = 1008, instance = "Mogu'shan Vaults", encounter = "Elegon", difficulties = { 3, 4, 5, 6 }, resetType = "weekly" } } },
  { itemID = 93666, sources = { { type = "lockout", mapID = 1098, instance = "Throne of Thunder", encounter = "Horridon", difficulties = { 3, 4, 5, 6 }, resetType = "weekly" } } },
  { itemID = 78919, sources = { { type = "lockout", mapID = 967, instance = "Dragon Soul", encounter = "Ultraxion", difficulties = { 3, 4, 5, 6 }, resetType = "weekly" } } },
  { itemID = 104253, sources = { { type = "lockout", mapID = 1136, instance = "Siege of Orgrimmar", encounter = "Garrosh Hellscream", difficulties = { 16 }, resetType = "weekly" } } },
  { itemID = 123890, sources = { { type = "lockout", mapID = 1448, instance = "Hellfire Citadel", encounter = "Archimonde", difficulties = { 16 }, resetType = "weekly" } } },
}

-- ---------- item info ----------

local function itemName(target)
  if target.name then return target.name end
  local name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(target.itemID)
  if name then
    target.name, target.icon = name, icon
    return name
  end
  return "item:" .. tostring(target.itemID)
end

-- " [12 att.]" after a target's name, or "" without attempts.
local function attemptsSuffix(target)
  local a = M.db.attempts[target.itemID]
  if not a or a.count == 0 then return "" end
  return " |cffb0b0ff" .. string.format(L.ATTEMPTS_SHORT, a.count) .. "|r"
end

local function itemIcon(target)
  if target.icon then return target.icon end
  local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(target.itemID)
  target.icon = icon
  return icon or 134400
end

-- Decide what kind of collectible an item is. Mounts, pets and toys are account-wide.
local function detectKind(itemID)
  local mountID = RR.Call("C_MountJournal.GetMountFromItem", itemID)
  if mountID and mountID > 0 then return "mount", mountID end
  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local result = { pcall(C_PetJournal.GetPetInfoByItemID, itemID) }
    local speciesID = result[1] and result[14] -- 13th return value; result[1] is pcall's status
    if type(speciesID) == "number" and speciesID > 0 then return "pet", speciesID end
  end
  if C_ToyBox and C_ToyBox.GetToyInfo then
    local toyItem = RR.Call("C_ToyBox.GetToyInfo", itemID)
    if toyItem then return "toy" end
  end
  local _, sourceID = RR.Call("C_TransmogCollection.GetItemInfo", itemID)
  if sourceID then return "transmog", sourceID end
  return "item"
end

local function isCollected(target)
  local kind = target.kind
  if kind == "mount" then
    local mountID = target.mountID or RR.Call("C_MountJournal.GetMountFromItem", target.itemID)
    if not mountID then return nil end
    return select(11, RR.Call("C_MountJournal.GetMountInfoByID", mountID)) and true or false
  elseif kind == "pet" then
    local num = target.speciesID and RR.Call("C_PetJournal.GetNumCollectedInfo", target.speciesID)
    if num == nil then return nil end
    return num > 0
  elseif kind == "toy" then
    if not PlayerHasToy then return nil end
    return PlayerHasToy(target.itemID) and true or false
  elseif kind == "transmog" and target.sourceByDiff then
    -- wanted from the journal: every wanted difficulty has its own appearance
    for _, sourceID in pairs(target.sourceByDiff) do
      local info = RR.Call("C_TransmogCollection.GetAppearanceInfoBySource", sourceID)
      if not info then return nil end
      if not info.appearanceIsCollected then return false end
    end
    return true
  elseif kind == "transmog" then
    local _, sourceID = RR.Call("C_TransmogCollection.GetItemInfo", target.itemID)
    if not sourceID then return nil end
    local info = RR.Call("C_TransmogCollection.GetAppearanceInfoBySource", sourceID)
    if info then return info.appearanceIsCollected and true or false end
    return RR.Call("C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance", sourceID) and true or false
  end
  return false -- plain items are never "collected"
end

-- ---------- targets ----------

function M:AddTarget(itemID, sources)
  itemID = tonumber(itemID)
  if not itemID or not sources or #sources == 0 then return nil end
  local kind, extra = detectKind(itemID)
  local id = self.db.nextId
  self.db.nextId = id + 1
  local target = { id = id, itemID = itemID, kind = kind, sources = sources }
  if kind == "mount" then target.mountID = extra elseif kind == "pet" then target.speciesID = extra end
  self.db.targets[id] = target
  itemName(target)
  self:UpdateCollected()
  RR:RefreshUI()
  return target
end

function M:RemoveTarget(id)
  if type(id) == "string" and id:match("^auto:") then
    local coll = RR.modules.Collections
    if coll and coll.db then coll:HideAutoMount(tonumber(id:match("^auto:(%d+)"))) end
    return
  end
  self.db.targets[id] = nil
  self.db.collected[id] = nil
  RR:RefreshUI()
end

-- ---------- "Want" from the Adventure Guide ----------
-- ctx = { itemID, link, difficulty, mapID, instance, encounter, isRaid }. One target per item; each click adds or
-- removes the selected difficulty. Wanted items appear as rows in the checklist.

function M:FindWant(itemID)
  for _, target in pairs(self.db.targets) do
    if target.want and target.itemID == itemID then return target end
  end
end

function M:IsWanted(itemID, difficulty)
  local target = self:FindWant(itemID)
  if not target then return false end
  for _, d in ipairs(target.sources[1].difficulties) do
    if d == difficulty then return true end
  end
  return false
end

function M:RemoveWant(itemID, d)
  local target = self:FindWant(itemID)
  if not target then return false end
  local diffs = target.sources[1].difficulties
  for i, existing in ipairs(diffs) do
    if existing == d then
      table.remove(diffs, i)
      if target.sourceByDiff then target.sourceByDiff[d] = nil end
      if #diffs == 0 then self:RemoveTarget(target.id) else RR:RefreshUI() end
      return true
    end
  end
  return false
end

function M:ToggleWant(ctx)
  if self:IsWanted(ctx.itemID, ctx.difficulty) then
    self:RemoveWant(ctx.itemID, ctx.difficulty)
    return false
  end
  return self:AddWant(ctx)
end

-- Adds one item for one difficulty (no-op when already wanted). ctx.sourceID may replace ctx.link (Transmog tab).
-- silent = skip the collected update and refresh, for adding many items at once.
function M:AddWant(ctx, silent)
  local d = ctx.difficulty
  if self:IsWanted(ctx.itemID, d) then return false end
  local target = self:FindWant(ctx.itemID)
  if target then
    local diffs = target.sources[1].difficulties
    diffs[#diffs + 1] = d
  else
    local kind, extra = detectKind(ctx.itemID)
    local id = self.db.nextId
    self.db.nextId = id + 1
    target = {
      id = id, itemID = ctx.itemID, kind = kind, want = true,
      sources = { {
        type = "lockout", mapID = ctx.mapID, instance = ctx.instance, encounter = ctx.encounter,
        difficulties = { d }, resetType = ctx.isRaid and "weekly" or "daily",
      } },
    }
    if kind == "mount" then target.mountID = extra elseif kind == "pet" then target.speciesID = extra end
    self.db.targets[id] = target
  end
  if target.kind == "transmog" then
    local sourceID = ctx.sourceID
    if not sourceID and ctx.link then sourceID = select(2, RR.Call("C_TransmogCollection.GetItemInfo", ctx.link)) end
    if sourceID then
      target.sourceByDiff = target.sourceByDiff or {}
      target.sourceByDiff[d] = sourceID
    end
  end
  itemName(target)
  if not silent then
    self:UpdateCollected()
    RR:RefreshUI()
  end
  return true
end

-- Adds a batch of want contexts. Returns how many were new.
function M:AddWants(list)
  local added = 0
  for _, ctx in ipairs(list) do
    if self:AddWant(ctx, true) then added = added + 1 end
  end
  self:UpdateCollected()
  RR:RefreshUI()
  return added
end

-- Removes a batch of { itemID, difficulty }. Returns how many were removed.
function M:RemoveWants(list)
  local removed = 0
  for _, ctx in ipairs(list) do
    if self:RemoveWant(ctx.itemID, ctx.difficulty) then removed = removed + 1 end
  end
  RR:RefreshUI()
  return removed
end

local WANT_STATE = { chance = "open", locked = "done" }

-- Checklist rows: one per wanted item. Open = boss still available this reset, done = already killed.
function M:GetChecklistRows()
  local wants = {}
  for _, target in pairs(self.db.targets) do
    if target.want then wants[#wants + 1] = target end
  end
  if #wants == 0 then return nil end
  table.sort(wants, function(a, b) return itemName(a) < itemName(b) end)
  local rows = { { label = L.WANT_HEADER, header = true } }
  for _, target in ipairs(wants) do
    local collected = self.db.collected[target.id]
    if not (collected and self.db.collectedMode == "hide") then
      rows[#rows + 1] = {
        path = "want:" .. target.id,
        label = itemName(target) .. attemptsSuffix(target) .. "  |cff808080" .. self:SourceText(target.sources[1]) .. "|r",
        icon = itemIcon(target), dim = collected,
        tooltip = self:TargetTooltip(target),
        onRightClick = function(owner)
          RR.ShowMenu(owner, {
            { text = itemName(target), isTitle = true },
            { text = L.WANT_REMOVE, func = function() M:RemoveTarget(target.id) end },
          })
        end,
        cell = function(charKey)
          if collected then return RR.FormatState("done", L.FARM_COLLECTED_SHORT) end
          local status = M:Status(charKey, target)
          local state = WANT_STATE[status]
          if not state then return RR.FormatState("na", status == "unknown" and "?" or L.FARM_INELIGIBLE) end
          return RR.FormatState(state, status == "chance" and L.FARM_CHANCE or L.FARM_LOCKED), M:TargetTooltip(target)
        end,
      }
    end
  end
  return rows
end

function M:AddSummaryEntries(charKey, count)
  for _, target in pairs(self.db.targets) do
    if target.want and not self.db.collected[target.id] then
      local state = WANT_STATE[self:Status(charKey, target)]
      if state then count("want:" .. target.id, target.sources[1].resetType or "weekly", state, itemName(target)) end
    end
  end
end

-- Own targets plus the boss-drop mounts found by the Collections module. An auto target replaces a starter entry
-- for the same item (journal data is more precise); a target you added yourself always wins.
function M:AllTargets()
  local list, autoItems, ownItems = {}, {}, {}
  local coll = RR.modules.Collections
  local auto = (coll and RR:IsModuleActive("Collections")) and coll:GetAutoMountTargets() or {}
  for _, target in ipairs(auto) do autoItems[target.itemID] = true end
  for _, target in pairs(self.db.targets) do
    if not target.starter then ownItems[target.itemID] = true end
  end
  for _, target in pairs(self.db.targets) do
    if not (target.starter and autoItems[target.itemID]) then list[#list + 1] = target end
  end
  for _, target in ipairs(auto) do
    if not ownItems[target.itemID] then list[#list + 1] = target end
  end
  return list
end

-- Collected status per target id as last seen this session. Only an update that follows a real "something new
-- was collected" event may alert on a false -> true change; collection data that finishes loading after login
-- updates silently, so it never causes a false alert.
local seenCollected = {}
local collectEventPending = false

function M:UpdateCollected()
  local mayAlert = collectEventPending
  collectEventPending = false
  for _, target in ipairs(self:AllTargets()) do
    local id = target.id
    if target.kind == nil or target.kind == "item" then
      local kind, extra = detectKind(target.itemID)
      target.kind = kind
      if kind == "mount" then target.mountID = extra elseif kind == "pet" then target.speciesID = extra end
    end
    local collected = isCollected(target)
    if collected ~= nil then
      self.db.collected[id] = collected or nil
      if collected and mayAlert and seenCollected[id] == false then self:OnTargetCollected(target) end
      seenCollected[id] = collected
    end
  end
end

-- ---------- attempts and alerts ----------

function M:Alert(text)
  RR.Print(text)
  if not self.db.alerts then return end
  if RaidNotice_AddMessage and RaidWarningFrame then
    local color = ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.82, b = 0 }
    pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color)
  end
  if self.db.alertSound and PlaySound then
    pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master")
  end
end

function M:OnTargetCollected(target)
  local a = self.db.attempts[target.itemID]
  if a and not a.gotAt then a.gotAt, a.gotCount = RR.Now(), a.count end
  local text = string.format(L.ALERT_COLLECTED, itemName(target))
  if a and a.count > 0 then text = text .. " " .. string.format(L.ALERT_AFTER_ATTEMPTS, a.count) end
  self:Alert(text)
end

function M:GetAttempts(itemID)
  local a = self.db.attempts[itemID]
  return a and a.count or 0, a
end

function M:ResetAttempts(itemID)
  self.db.attempts[itemID] = nil
  RR:RefreshUI()
end

local function hasDifficulty(source, difficultyID)
  for _, d in ipairs(source.difficulties or {}) do
    if d == difficultyID then return true end
  end
  return false
end

-- A successful boss kill counts as one attempt for every uncollected target that drops from that boss on that
-- difficulty, at most once per character per lockout (a second kill in the same reset cannot drop it again).
function M:RecordKill(encounterName, difficultyID)
  if type(encounterName) ~= "string" or RR.IsSecret(encounterName) or RR.IsSecret(difficultyID) then return end
  local charKey = RR.charKey
  if not charKey then return end
  local boss = encounterName:lower()
  local now = RR.Now()
  local counted = {}
  for _, target in ipairs(self:AllTargets()) do
    if not self.db.collected[target.id] and not counted[target.itemID] then
      for _, source in ipairs(target.sources or {}) do
        if source.type == "lockout" and source.encounter and source.encounter:lower() == boss
          and hasDifficulty(source, difficultyID) then
          counted[target.itemID] = true
          local seenKey = string.format("%s:%d:%s:%d", charKey, target.itemID, boss, difficultyID)
          local seen = self.db.attemptSeen[seenKey]
          if not seen or seen <= now then
            self.db.attemptSeen[seenKey] = RR:GetNextReset(source.resetType or "weekly") or (now + 86400)
            local a = self.db.attempts[target.itemID] or { count = 0 }
            a.count, a.last = a.count + 1, now
            self.db.attempts[target.itemID] = a
            RR.Print(string.format(L.ATTEMPT_COUNTED, itemName(target), a.count))
          end
          break
        end
      end
    end
  end
  RR:RefreshUI()
end

local recentDrops = {}

-- An uncollected target showed up in loot (yours or a group member's).
function M:CheckDrop(itemID, who)
  itemID = tonumber(itemID)
  if not itemID then return end
  local now = RR.Now()
  if recentDrops[itemID] and recentDrops[itemID] > now - 10 then return end -- loot event + chat line for one drop
  for _, target in ipairs(self:AllTargets()) do
    if target.itemID == itemID and not self.db.collected[target.id] then
      recentDrops[itemID] = now
      local name = itemName(target)
      self:Alert(who and who ~= "" and string.format(L.ALERT_DROP_BY, name, who) or string.format(L.ALERT_DROP, name))
      return
    end
  end
end

-- ---------- status per character ----------
-- Returns "chance" | "locked" | "ineligible" | "unknown"

local function sourceStatus(char, source, now)
  if source.minLevel and (char.level or 0) < source.minLevel then return "ineligible" end
  if source.type == "quest" then
    local q = char.farmQuests and char.farmQuests[source.questID]
    if not q then return "unknown" end
    if q.done and (not q.expires or q.expires > now) then return "locked" end
    return "chance"
  end
  -- lockout source
  if not char.lockoutsScanned then return "unknown" end
  local anyKilled, anyFree = false, false
  for _, difficulty in ipairs(source.difficulties or {}) do
    local lock = char.lockouts[tostring(source.mapID) .. ":" .. tostring(difficulty)]
    if not lock and source.instance then
      local wanted = source.instance:lower()
      for _, l in pairs(char.lockouts) do
        if l.difficultyID == difficulty and l.nameLower == wanted then lock = l break end
      end
    end
    local killed = false
    if lock and lock.expires and lock.expires > now then
      if source.encounter and source.encounter ~= "" then
        killed = lock.killed[source.encounter:lower()] and true or false
      else
        killed = lock.progress >= lock.numEncounters
      end
    end
    if killed then anyKilled = true else anyFree = true end
  end
  if source.shareLockout and anyKilled then return "locked" end
  return anyFree and "chance" or "locked"
end

function M:Status(charKey, target)
  local char = RR.db.chars[charKey]
  if not char then return "unknown" end
  local now = RR.Now()
  local best = "ineligible"
  local rank = { ineligible = 0, unknown = 1, locked = 2, chance = 3 }
  for _, source in ipairs(target.sources or {}) do
    local s = sourceStatus(char, source, now)
    if rank[s] > rank[best] then best = s end
  end
  return best
end

local STATUS_TEXT = {
  chance = function() return RR.FormatState("done", L.FARM_CHANCE) end,
  locked = function() return RR.FormatState("open", L.FARM_LOCKED) end,
  ineligible = function() return RR.FormatState("na", L.FARM_INELIGIBLE) end,
  unknown = function() return RR.FormatState("na", "?") end,
}

function M:CharsByStatus(target)
  local result = { chance = {}, locked = {}, ineligible = {}, unknown = {} }
  for key, char in pairs(RR.db.chars) do
    if not char.hidden then
      local s = self:Status(key, target)
      result[s][#result[s] + 1] = key
    end
  end
  for _, list in pairs(result) do table.sort(list) end
  return result
end

local function namesLine(keys)
  local names = {}
  for _, key in ipairs(keys) do names[#names + 1] = RR:CharDisplayName(key) end
  return table.concat(names, ", ")
end

function M:SourceText(source)
  if source.type == "quest" then
    return string.format(L.FARM_SOURCE_QUEST, source.label or tostring(source.questID),
      source.resetType == "daily" and L.DAILY or L.WEEKLY)
  end
  local diffs = {}
  for _, d in ipairs(source.difficulties or {}) do diffs[#diffs + 1] = difficultyName(d) end
  return string.format("%s - %s (%s)", source.instance or tostring(source.mapID),
    (source.encounter and source.encounter ~= "") and source.encounter or L.FARM_FULL_CLEAR, table.concat(diffs, "/"))
end

function M:TargetTooltip(target)
  return function(tt)
    tt:SetItemByID(target.itemID)
    tt:AddLine(" ")
    for _, source in ipairs(target.sources) do tt:AddLine(self:SourceText(source), 0.8, 0.8, 1, true) end
    local by = self:CharsByStatus(target)
    local total = #by.chance + #by.locked + #by.ineligible + #by.unknown
    if self.db.collected[target.id] then tt:AddLine(L.FARM_COLLECTED, 0.5, 1, 0.5) end
    local count, a = self:GetAttempts(target.itemID)
    if a and a.gotAt then
      tt:AddLine(string.format(L.ATTEMPTS_GOT, a.gotCount or count), 0.5, 1, 0.5)
    elseif count > 0 then
      tt:AddLine(string.format(L.ATTEMPTS_TIP, count, RR.FormatAgo(a.last)), 0.7, 0.7, 1)
    end
    if #by.chance > 0 then
      tt:AddLine(string.format(L.FARM_TIP_CHANCE, namesLine(by.chance), #by.chance, total), 1, 1, 1, true)
    end
    if #by.locked > 0 then tt:AddLine(string.format(L.FARM_TIP_LOCKED, namesLine(by.locked)), 1, 1, 1, true) end
    if #by.ineligible > 0 then tt:AddLine(string.format(L.FARM_TIP_INELIGIBLE, namesLine(by.ineligible)), 1, 1, 1, true) end
    if #by.unknown > 0 then tt:AddLine(string.format(L.FARM_TIP_UNKNOWN, namesLine(by.unknown)), 0.7, 0.7, 0.7, true) end
    tt:AddLine(L.FARM_NO_CHANCE_CLAIM, 0.5, 0.5, 0.5, true)
  end
end

function M:ActiveTargets(kindFilter)
  local list = {}
  for _, target in ipairs(self:AllTargets()) do
    local collected = self.db.collected[target.id]
    if (not collected or self.db.collectedMode == "show") and (not kindFilter or target.kind == kindFilter) then
      list[#list + 1] = target
    end
  end
  table.sort(list, function(a, b) return itemName(a) < itemName(b) end)
  return list
end

-- ---------- module hooks ----------

function M:OnInitialize(db)
  self.db = db
  if not db.starterAdded then
    db.starterAdded = true
    for _, s in ipairs(STARTER) do
      local id = db.nextId
      db.nextId = id + 1
      db.targets[id] = { id = id, itemID = s.itemID, sources = s.sources, starter = true }
    end
  end
end

function M:OnEnable()
  self:UpdateCollected()
end

-- Records daily/weekly quest sources for the logged-in character.
function M:OnScan(char)
  char.farmQuests = char.farmQuests or {}
  for _, target in pairs(self.db.targets) do
    for _, source in ipairs(target.sources or {}) do
      if source.type == "quest" and source.questID then
        local done = RR.Call("C_QuestLog.IsQuestFlaggedCompleted", source.questID) and true or false
        char.farmQuests[source.questID] = { done = done, expires = done and RR:GetNextReset(source.resetType or "daily") or nil }
      end
    end
  end
  self:UpdateCollected()
end

function M:OnApplyResets(now)
  for _, char in pairs(RR.db.chars) do
    for _, q in pairs(char.farmQuests or {}) do
      if q.expires and q.expires <= now then q.done, q.expires = false, nil end
    end
  end
  for key, expires in pairs(self.db.attemptSeen) do
    if expires <= now then self.db.attemptSeen[key] = nil end
  end
end

function M:OnResetCharacter(_, char)
  char.farmQuests = {}
end

local collectTimer
function M:OnEvent(event, ...)
  if event == "ENCOUNTER_END" then
    local _, encounterName, difficultyID, _, success = ...
    if success == 1 then self:RecordKill(encounterName, difficultyID) end
    return
  elseif event == "ENCOUNTER_LOOT_RECEIVED" then
    local _, itemID, _, _, playerName = ...
    if not RR.IsSecret(itemID) and not RR.IsSecret(playerName) then self:CheckDrop(itemID, playerName) end
    return
  elseif event == "CHAT_MSG_LOOT" then
    local text, playerName = ...
    if type(text) ~= "string" or RR.IsSecret(text) or RR.IsSecret(playerName) then return end
    for itemID in text:gmatch("item:(%d+)") do self:CheckDrop(itemID, playerName) end
    return
  end
  if event == "NEW_MOUNT_ADDED" or event == "NEW_PET_ADDED" or event == "NEW_TOY_ADDED"
    or event == "TRANSMOG_COLLECTION_SOURCE_ADDED" then
    collectEventPending = true
  end
  if event == "GET_ITEM_INFO_RECEIVED" or event == "NEW_MOUNT_ADDED" or event == "NEW_PET_ADDED"
    or event == "NEW_TOY_ADDED" or event == "TRANSMOG_COLLECTION_UPDATED" or event == "TRANSMOG_COLLECTION_SOURCE_ADDED" then
    if collectTimer then return end
    collectTimer = C_Timer.NewTimer(RR.DEBOUNCE, function()
      collectTimer = nil
      RR.SafeCall("farm collected", M.UpdateCollected, M)
      RR:RefreshUI()
    end)
  end
end

function M:CountWithChance(charKey)
  local list = {}
  for _, target in ipairs(self:AllTargets()) do
    if not self.db.collected[target.id] and self:Status(charKey, target) == "chance" then list[#list + 1] = itemName(target) end
  end
  table.sort(list)
  return list
end

function M:AddMinimapLines(tt)
  if not RR.charKey then return end
  local n = #self:CountWithChance(RR.charKey)
  tt:AddLine(string.format(L.FARM_MINIMAP, n), 0.6, 1, 0.6)
end

function M:GetLoginLine()
  if not self.db.loginLine or not RR.charKey then return nil end
  local list = self:CountWithChance(RR.charKey)
  if #list == 0 then return nil end
  local shown = {}
  for i = 1, math.min(6, #list) do shown[i] = list[i] end
  return string.format(L.FARM_LOGIN, table.concat(shown, ", ") .. (#list > 6 and ", ..." or ""))
end

function M:BuildSettings(layout)
  layout:AddHeader(L.FARM_TITLE)
  layout:AddCheck(L.FARM_OPT_HIDE_COLLECTED, nil, function() return M.db.collectedMode == "hide" end, function(v)
    M.db.collectedMode = v and "hide" or "show"
    RR:RefreshUI()
  end)
  layout:AddCheck(L.FARM_OPT_LOGIN, nil, function() return M.db.loginLine end, function(v) M.db.loginLine = v end)
  layout:AddCheck(L.FARM_OPT_ALERTS, L.FARM_OPT_ALERTS_TIP, function() return M.db.alerts end,
    function(v) M.db.alerts = v end)
  layout:AddCheck(L.FARM_OPT_ALERT_SOUND, nil, function() return M.db.alertSound end,
    function(v) M.db.alertSound = v end, 20)
end

local function setHideCollected(v)
  M.db.collectedMode = v and "hide" or "show"
  if RR.settingsLayout then RR.settingsLayout:Refresh() end
  RR:RefreshUI()
end

-- ---------- UI: add form ----------

-- Encounter Journal picker. EJ_SelectTier changes the journal's current tier, so it is restored afterwards.
local function buildEJMenu(owner, onPick)
  if not EJ_GetNumTiers or not MenuUtil or not MenuUtil.CreateContextMenu then
    RR.Print(L.FARM_EJ_UNAVAILABLE)
    return
  end
  local previousTier = EJ_GetCurrentTier and EJ_GetCurrentTier()
  local ok, err = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
    for tier = EJ_GetNumTiers(), 1, -1 do
      local tierName = EJ_GetTierInfo(tier)
      local tierMenu = root:CreateButton(tierName or ("Tier " .. tier))
      EJ_SelectTier(tier)
      for _, isRaid in ipairs({ true, false }) do
        local index = 1
        local instanceID, instanceName = EJ_GetInstanceByIndex(index, isRaid)
        while instanceID do
          local mapID = select(10, EJ_GetInstanceInfo(instanceID))
          local instMenu = tierMenu:CreateButton((isRaid and "" or "|cffaaaaaa") .. instanceName .. (isRaid and "" or "|r"))
          EJ_SelectInstance(instanceID)
          local e = 1
          local encName = EJ_GetEncounterInfoByIndex(e, instanceID)
          while encName do
            local captured = encName
            instMenu:CreateButton(encName, function()
              onPick({ mapID = mapID, instance = instanceName, encounter = captured, isRaid = isRaid })
            end)
            e = e + 1
            encName = EJ_GetEncounterInfoByIndex(e, instanceID)
          end
          index = index + 1
          instanceID, instanceName = EJ_GetInstanceByIndex(index, isRaid)
        end
      end
    end
  end)
  if previousTier and EJ_SelectTier then pcall(EJ_SelectTier, previousTier) end
  if not ok then
    RR.Debug("EJ menu failed:", err)
    RR.Print(L.FARM_EJ_UNAVAILABLE)
  end
end

local function buildAddForm(parent, onAdded)
  local form = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  RR.CreateBackdrop(form, 0.98)
  form:SetSize(560, 190)
  form:SetPoint("TOP", 0, -30)
  form:SetFrameStrata("DIALOG")
  form:EnableMouse(true)
  form:Hide()

  local function label(text, x, y)
    local fs = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
  end

  label(L.FARM_FORM_ITEM, 10, -12)
  local itemBox = RR.CreateEditBox(form, 250)
  itemBox:SetPoint("TOPLEFT", 120, -8)
  RR.AcceptItemLinks(itemBox)
  local itemInfo = form:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  itemInfo:SetPoint("LEFT", itemBox, "RIGHT", 6, 0)
  itemInfo:SetPoint("RIGHT", -10, 0)
  itemInfo:SetJustifyH("LEFT")

  label(L.FARM_FORM_SOURCE, 10, -40)
  local pickBtn = RR.CreateButton(form, L.FARM_FORM_PICK, 150)
  pickBtn:SetPoint("TOPLEFT", 120, -36)

  label(L.FARM_FORM_INSTANCE, 10, -66)
  local instanceBox = RR.CreateEditBox(form, 170)
  instanceBox:SetPoint("TOPLEFT", 120, -62)
  label(L.FARM_FORM_MAPID, 300, -66)
  local mapBox = RR.CreateEditBox(form, 60, true)
  mapBox:SetPoint("TOPLEFT", 360, -62)

  label(L.FARM_FORM_BOSS, 10, -92)
  local bossBox = RR.CreateEditBox(form, 170)
  bossBox:SetPoint("TOPLEFT", 120, -88)
  label(L.FARM_FORM_QUEST, 300, -92)
  local questBox = RR.CreateEditBox(form, 60, true)
  questBox:SetPoint("TOPLEFT", 360, -88)

  label(L.FARM_FORM_DIFFS, 10, -118)
  local diffBox = RR.CreateEditBox(form, 100)
  diffBox:SetPoint("TOPLEFT", 120, -114)
  local diffBtn = RR.CreateButton(form, L.FARM_FORM_DIFF_PICK, 60, function(self)
    local items = { { text = L.FARM_FORM_DIFFS, isTitle = true } }
    for _, d in ipairs(DIFFICULTIES) do
      items[#items + 1] = { text = string.format("%d - %s", d, difficultyName(d)), func = function()
        local current = diffBox:GetText()
        diffBox:SetText(current == "" and tostring(d) or (current .. "," .. d))
      end }
    end
    RR.ShowMenu(self, items)
  end)
  diffBtn:SetPoint("LEFT", diffBox, "RIGHT", 4, 0)
  label(L.FARM_FORM_MINLEVEL, 300, -118)
  local levelBox = RR.CreateEditBox(form, 40, true)
  levelBox:SetPoint("TOPLEFT", 360, -114)

  local resetType = "weekly"
  local resetBtn = RR.CreateButton(form, L.WEEKLY, 70, function(self)
    resetType = resetType == "weekly" and "daily" or "weekly"
    self:SetLabel(resetType == "weekly" and L.WEEKLY or L.DAILY)
  end)
  resetBtn:SetPoint("TOPLEFT", 120, -140)
  local shared = false
  local sharedCheck = RR.CreateCheck(form, L.FARM_FORM_SHARED, function(v) shared = v end)
  sharedCheck:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)

  local status = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  status:SetPoint("BOTTOMLEFT", 10, 10)

  pickBtn:SetScript("OnClick", function(self)
    buildEJMenu(self, function(pick)
      instanceBox:SetText(pick.instance or "")
      mapBox:SetText(pick.mapID and tostring(pick.mapID) or "")
      bossBox:SetText(pick.encounter or "")
      if diffBox:GetText() == "" then diffBox:SetText(pick.isRaid and "14,15,16" or "2,23") end
    end)
  end)

  local function resolveItemID()
    local text = strtrim(itemBox:GetText() or "")
    local id = tonumber(text) or tonumber(text:match("item:(%d+)"))
    if not id and text ~= "" then
      local link = select(2, C_Item.GetItemInfo(text)) -- only works for items in the client cache
      id = link and tonumber(link:match("item:(%d+)"))
    end
    return id
  end

  itemBox:SetScript("OnTextChanged", function()
    local id = resolveItemID()
    if id then
      local name = C_Item.GetItemInfo(id)
      itemInfo:SetText(name and (name .. " (" .. id .. ")") or ("#" .. id))
    else
      itemInfo:SetText("")
    end
  end)

  local addBtn = RR.CreateButton(form, L.ADD, 70, function()
    local id = resolveItemID()
    if not id then status:SetText("|cffff5050" .. L.FARM_ERR_ITEM .. "|r") return end
    local source
    local questID = tonumber(questBox:GetText())
    if questID then
      source = { type = "quest", questID = questID, label = bossBox:GetText() ~= "" and bossBox:GetText() or nil, resetType = resetType }
    else
      local diffs = {}
      for d in (diffBox:GetText() or ""):gmatch("%d+") do diffs[#diffs + 1] = tonumber(d) end
      local mapID = tonumber(mapBox:GetText())
      local instance = strtrim(instanceBox:GetText() or "")
      if (#diffs == 0) or (not mapID and instance == "") then
        status:SetText("|cffff5050" .. L.FARM_ERR_SOURCE .. "|r")
        return
      end
      source = {
        type = "lockout", mapID = mapID, instance = instance ~= "" and instance or nil,
        encounter = strtrim(bossBox:GetText() or ""), difficulties = diffs, resetType = resetType,
        shareLockout = shared or nil,
      }
    end
    source.minLevel = tonumber(levelBox:GetText())
    local target = M:AddTarget(id, { source })
    if target then
      status:SetText("|cff40ff40" .. string.format(L.FARM_ADDED, itemName(target)) .. "|r")
      itemBox:SetText("")
      if onAdded then onAdded() end
    end
  end)
  addBtn:SetPoint("BOTTOMRIGHT", -84, 8)
  local closeBtn = RR.CreateButton(form, CLOSE or "Close", 70, function() form:Hide() end)
  closeBtn:SetPoint("BOTTOMRIGHT", -8, 8)
  return form
end

-- ---------- UI: tabs ----------

local function targetRow(target)
  local collected = M.db.collected[target.id]
  local label = itemName(target)
  local srcText = target.sources[1] and M:SourceText(target.sources[1]) or ""
  if #target.sources > 1 then srcText = srcText .. string.format(" +%d", #target.sources - 1) end
  if collected then label = label .. " |cff40ff40(" .. L.FARM_COLLECTED_SHORT .. ")|r" end
  if target.auto then label = label .. " |cff8080ff(" .. L.FARM_AUTO .. ")|r" end
  label = label .. attemptsSuffix(target)
  return {
    label = label .. "  |cff808080" .. srcText .. "|r",
    icon = itemIcon(target), dim = collected,
    tooltip = M:TargetTooltip(target),
    onRightClick = function(owner)
      RR.ShowMenu(owner, {
        { text = itemName(target), isTitle = true },
        { text = target.auto and L.FARM_HIDE_AUTO or L.FARM_REMOVE, func = function() M:RemoveTarget(target.id) end },
        { text = L.ATTEMPTS_RESET, disabled = M:GetAttempts(target.itemID) == 0,
          func = function() M:ResetAttempts(target.itemID) end },
      })
    end,
    cell = function(charKey)
      if collected then return RR.FormatState("na", L.FARM_COLLECTED_SHORT) end
      local s = M:Status(charKey, target)
      return STATUS_TEXT[s](), M:TargetTooltip(target)
    end,
  }
end

local function buildFarmTab(parent)
  local tab = {}
  local addForm
  local addBtn = RR.CreateButton(parent, L.FARM_ADD_TARGET, 110, function()
    addForm = addForm or buildAddForm(parent, function() tab:Refresh() end)
    addForm:SetShown(not addForm:IsShown())
  end)
  addBtn:SetPoint("TOPLEFT", 4, -4)
  local hideCheck = RR.CreateCheck(parent, L.FARM_HIDE_COLLECTED, setHideCollected)
  hideCheck:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
  local note = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("LEFT", hideCheck, "RIGHT", 110, 0)
  note:SetPoint("RIGHT", -4, 0)
  note:SetJustifyH("LEFT")
  note:SetText(L.FARM_NOTE)

  local holder = CreateFrame("Frame", nil, parent)
  holder:SetPoint("TOPLEFT", 0, -30)
  holder:SetPoint("BOTTOMRIGHT")
  local grid = RR.CreateGrid(holder, 300)

  function tab:Refresh()
    hideCheck:SetChecked(M.db.collectedMode == "hide")
    local rows = {}
    for _, target in ipairs(M:ActiveTargets()) do rows[#rows + 1] = targetRow(target) end
    if #rows == 0 then rows[1] = { label = L.FARM_EMPTY } end
    grid:SetData(RR:CharColumns(), rows)
    grid:Render()
  end
  return tab
end

local function buildMountTab(parent)
  local tab = {}
  local hideCheck = RR.CreateCheck(parent, L.FARM_HIDE_COLLECTED, setHideCollected)
  hideCheck:SetPoint("TOPLEFT", 4, -3)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetPoint("TOPLEFT", 0, -30)
  holder:SetPoint("BOTTOMRIGHT")
  local grid = RR.CreateGrid(holder, 320)
  local columns = { { key = "count", label = L.MOUNTS_COL_CHANCES }, { key = "attempts", label = L.MOUNTS_COL_ATTEMPTS } }

  function tab:Refresh()
    hideCheck:SetChecked(M.db.collectedMode == "hide")
    local list = {}
    for _, target in ipairs(M:ActiveTargets("mount")) do
      local by = M:CharsByStatus(target)
      list[#list + 1] = { target = target, by = by, n = M.db.collected[target.id] and -1 or #by.chance }
    end
    table.sort(list, function(a, b)
      if a.n ~= b.n then return a.n > b.n end
      return itemName(a.target) < itemName(b.target)
    end)
    local rows = {}
    for _, item in ipairs(list) do
      local target, by = item.target, item.by
      local collected = M.db.collected[target.id]
      rows[#rows + 1] = {
        label = itemName(target), icon = itemIcon(target), dim = collected,
        tooltip = M:TargetTooltip(target),
        onRightClick = function(owner)
          RR.ShowMenu(owner, {
            { text = itemName(target), isTitle = true },
            { text = L.ATTEMPTS_RESET, disabled = M:GetAttempts(target.itemID) == 0,
              func = function() M:ResetAttempts(target.itemID) end },
          })
        end,
        cell = function(colKey)
          if colKey == "attempts" then
            local count = M:GetAttempts(target.itemID)
            return RR.FormatState("info", count > 0 and tostring(count) or "-"), M:TargetTooltip(target)
          end
          if collected then return RR.FormatState("na", L.FARM_COLLECTED_SHORT) end
          local total = #by.chance + #by.locked + #by.ineligible + #by.unknown
          return RR.FormatState(#by.chance > 0 and "done" or "open", string.format("%d/%d", #by.chance, total)),
            M:TargetTooltip(target)
        end,
      }
    end
    if #rows == 0 then rows[1] = { label = L.MOUNTS_EMPTY } end
    grid:SetData(columns, rows)
    grid:Render()
  end
  return tab
end

function M:GetTabs()
  return {
    { key = "farm", label = L.TAB_FARM, build = buildFarmTab, order = 20 },
    { key = "mounts", label = L.TAB_MOUNTS, build = buildMountTab, order = 25 },
  }
end

RR:RegisterModule("FarmTargets", M)
