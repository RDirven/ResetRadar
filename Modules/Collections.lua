-- ResetRadar module: Collections.
-- Scans the Encounter Journal (on request) for every raid/dungeon, boss and difficulty and remembers which loot
-- has a transmog appearance and which loot is a mount. From that it shows:
--   * a Transmog tab: per instance and difficulty how many appearances you still miss, per boss on click, and per
--     character how many of those bosses are still unlocked this reset;
--   * automatic Farm Targets for every boss-drop mount you do not own yet (read by FarmTargets.lua).
-- Collected status is checked live (account-wide), so the scan only has to be redone after a patch.

local _, ns = ...
local RR, L = ns.RR, ns.L

local M = {
  title = L.COLL_TITLE,
  description = L.COLL_DESC,
  defaultEnabled = true,
  events = { "TRANSMOG_COLLECTION_UPDATED", "NEW_MOUNT_ADDED", "PLAYER_REGEN_ENABLED", "ADDON_LOADED",
    "EJ_DIFFICULTY_UPDATE", "EJ_LOOT_DATA_RECIEVED" },
  defaults = {
    autoMounts = true,
    includeDungeons = true,
    completionist = false,   -- count every item source instead of unique appearances
    hideComplete = true,
    instanceFilter = "raids", -- "raids" | "dungeons" | "all"
    sortBy = "tier",          -- "tier" | "missing"
    expanded = {},
    hiddenAutoMounts = {},
    journalOverlay = true,    -- Want star, collected mark and missing counts in the Adventure Guide
    plannerChar = nil,        -- character shown in the planner (nil = logged-in character)
    plannerDungeons = false,
    plannerArmorOnly = true,  -- only count armor the character's class can wear (plus cloaks/weapons/other)
  },
}

local RAID_DIFFS = { 17, 14, 15, 16, 3, 4, 5, 6, 7, 9, 33 }
local DUNGEON_DIFFS = { 1, 2, 23, 24 }
local DIFF_ORDER = {}
for i, d in ipairs({ 17, 7, 14, 3, 4, 9, 15, 5, 6, 16, 33, 1, 2, 23, 24 }) do DIFF_ORDER[d] = i end
local ARMOR_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local READ_DELAY, RETRY_DELAY, MAX_RETRIES = 0.15, 0.3, 5
local ARMOR_NAMES = { [0] = L.COLL_ARMOR_OTHER, L.COLL_ARMOR_CLOTH, L.COLL_ARMOR_LEATHER, L.COLL_ARMOR_MAIL, L.COLL_ARMOR_PLATE }

local function difficultyName(id)
  return (GetDifficultyInfo and GetDifficultyInfo(id)) or ("#" .. tostring(id))
end

-- ---------- journal scan ----------

local scanner -- state of a running scan, nil when idle

local function ejAvailable()
  return EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_SelectInstance and EJ_SetDifficulty
    and EJ_GetNumLoot and EJ_IsValidInstanceDifficulty and EJ_GetEncounterInfoByIndex and C_EncounterJournal
    and C_EncounterJournal.GetLootInfoByIndex
end

local function journalOpen()
  return EncounterJournal and EncounterJournal.IsShown and EncounterJournal:IsShown()
end

function M:IsScanning()
  return scanner ~= nil
end

function M:ScanProgress()
  if not scanner then return nil end
  return scanner.i, #scanner.instances
end

function M:StartScan()
  if scanner then return end
  if InCombatLockdown() then RR.Print(L.COLL_COMBAT) return end
  if not ejAvailable() then RR.Print(L.COLL_NO_API) return end
  if journalOpen() then RR.Print(L.COLL_CLOSE_EJ) return end

  local s = { instances = {}, i = 0, result = { instances = {}, mounts = {} } }
  s.prevTier = EJ_GetCurrentTier and EJ_GetCurrentTier()
  if EJ_GetLootFilter then s.prevClass, s.prevSpec = EJ_GetLootFilter() end
  if C_EncounterJournal.GetSlotFilter then s.prevSlot = C_EncounterJournal.GetSlotFilter() end

  -- tiers in ascending order, so an instance repeated in "Current Season" keeps its own expansion
  local seen = {}
  local kinds = self.db.includeDungeons and { true, false } or { true }
  for tier = 1, EJ_GetNumTiers() do
    EJ_SelectTier(tier)
    local tierName = EJ_GetTierInfo and EJ_GetTierInfo(tier) or tostring(tier)
    for _, isRaid in ipairs(kinds) do
      local index = 1
      local jid, name = EJ_GetInstanceByIndex(index, isRaid)
      while jid do
        if not seen[jid] then
          seen[jid] = true
          s.instances[#s.instances + 1] = { jid = jid, name = name, isRaid = isRaid, tier = tier, tierName = tierName }
        end
        index = index + 1
        jid, name = EJ_GetInstanceByIndex(index, isRaid)
      end
    end
  end
  scanner = s
  RR.Print(string.format(L.COLL_SCAN_STARTED, #s.instances))
  RR:RefreshUI()
  self:NextInstance()
end

local function later(delay, method, ...)
  local args = { n = select("#", ...), ... }
  C_Timer.After(delay, function()
    if scanner then RR.SafeCall("journal " .. method, M[method], M, unpack(args, 1, args.n)) end
  end)
end

local function restoreJournal(s)
  if s.prevTier and EJ_SelectTier then pcall(EJ_SelectTier, s.prevTier) end
  if EJ_SetLootFilter then
    if s.prevClass then pcall(EJ_SetLootFilter, s.prevClass, s.prevSpec or 0)
    elseif EJ_ResetLootFilter then pcall(EJ_ResetLootFilter) end
  end
  if s.prevSlot and C_EncounterJournal.SetSlotFilter then pcall(C_EncounterJournal.SetSlotFilter, s.prevSlot) end
end

function M:CancelScan(reason)
  if not scanner then return end
  restoreJournal(scanner)
  scanner = nil
  if reason then RR.Print(reason) end
  RR:RefreshUI()
end

function M:NextInstance()
  local s = scanner
  if InCombatLockdown() then s.paused = "instance" return end
  s.i = s.i + 1
  local inst = s.instances[s.i]
  if not inst then return self:FinishScan() end
  EJ_SelectInstance(inst.jid)
  inst.mapID = EJ_GetInstanceInfo and select(10, EJ_GetInstanceInfo(inst.jid)) or nil
  inst.bossNames = {}
  local e = 1
  local bossName, _, encounterID = EJ_GetEncounterInfoByIndex(e, inst.jid)
  while bossName do
    inst.bossNames[encounterID] = bossName
    e = e + 1
    bossName, _, encounterID = EJ_GetEncounterInfoByIndex(e, inst.jid)
  end
  inst.diffs = {}
  for _, d in ipairs(inst.isRaid and RAID_DIFFS or DUNGEON_DIFFS) do
    if EJ_IsValidInstanceDifficulty(d) then inst.diffs[#inst.diffs + 1] = d end
  end
  s.out = { name = inst.name, mapID = inst.mapID, isRaid = inst.isRaid, tier = inst.tier, tierName = inst.tierName, diffs = {} }
  s.d = 0
  self:NextDifficulty()
  RR:RefreshUI()
end

function M:NextDifficulty()
  local s = scanner
  local inst = s.instances[s.i]
  s.d = s.d + 1
  local d = inst.diffs[s.d]
  if not d then
    if next(s.out.diffs) then s.result.instances[inst.jid] = s.out end
    return later(0.05, "NextInstance")
  end
  EJ_SelectInstance(inst.jid)
  if EJ_SetLootFilter then EJ_SetLootFilter(0, 0) end -- all classes
  local noFilter = Enum and Enum.ItemSlotFilterType and Enum.ItemSlotFilterType.NoFilter
  if noFilter and C_EncounterJournal.SetSlotFilter then C_EncounterJournal.SetSlotFilter(noFilter) end
  EJ_SetDifficulty(d)
  s.attempt = 0
  later(READ_DELAY, "ReadLoot", d)
end

-- Returns "mount", mountID  |  "transmog", "itemID:sourceID:appearanceID:armor"  |  nil
local function classify(info)
  local mountID = RR.Call("C_MountJournal.GetMountFromItem", info.itemID)
  if mountID and mountID > 0 then return "mount", mountID end
  local appearanceID, sourceID = RR.Call("C_TransmogCollection.GetItemInfo", info.link)
  if not sourceID then return nil end
  local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(info.itemID)
  local armor = 0
  if classID == ARMOR_CLASS and subclassID and subclassID >= 1 and subclassID <= 4 and equipLoc ~= "INVTYPE_CLOAK" then
    armor = subclassID
  end
  return "transmog", string.format("%d:%d:%d:%d", info.itemID, sourceID, appearanceID or 0, armor)
end

function M:ReadLoot(d)
  local s = scanner
  if InCombatLockdown() then s.paused = "difficulty" return end
  if journalOpen() then return self:CancelScan(L.COLL_CLOSE_EJ) end
  local inst = s.instances[s.i]
  local n = EJ_GetNumLoot() or 0
  local pending, loot = 0, {}
  for i = 1, n do
    local info = C_EncounterJournal.GetLootInfoByIndex(i)
    if info and info.itemID then
      if info.link then loot[#loot + 1] = info else pending = pending + 1 end
    end
  end
  if pending > 0 and s.attempt < MAX_RETRIES then
    s.attempt = s.attempt + 1
    return later(RETRY_DELAY, "ReadLoot", d)
  end

  local bosses, any = {}, false
  for _, info in ipairs(loot) do
    local kind, value = classify(info)
    local encounterID = info.encounterID or 0
    local bossName = inst.bossNames[encounterID] or L.COLL_UNKNOWN_BOSS
    if kind == "transmog" then
      bosses[encounterID] = bosses[encounterID] or { name = bossName, list = {} }
      local list = bosses[encounterID].list
      list[#list + 1] = value
      any = true
    elseif kind == "mount" then
      local mount = s.result.mounts[value] or { mountID = value, itemID = info.itemID, sources = {} }
      s.result.mounts[value] = mount
      local key = inst.jid .. ":" .. encounterID
      local source = mount.sources[key]
      if not source then
        source = {
          type = "lockout", mapID = inst.mapID, instance = inst.name, encounter = bossName, difficulties = {},
          resetType = inst.isRaid and "weekly" or "daily", journalInstanceID = inst.jid,
        }
        mount.sources[key] = source
      end
      source.difficulties[#source.difficulties + 1] = d
    end
  end
  if any then
    local stored = {}
    for encounterID, boss in pairs(bosses) do
      stored[encounterID] = { name = boss.name, items = table.concat(boss.list, ";") }
    end
    s.out.diffs[d] = { bosses = stored, incomplete = pending > 0 or nil }
  end
  self:NextDifficulty()
end

function M:FinishScan()
  local s = scanner
  restoreJournal(s)
  -- mount sources: map -> list
  for _, mount in pairs(s.result.mounts) do
    local list = {}
    for _, source in pairs(mount.sources) do list[#list + 1] = source end
    mount.sources = list
  end
  s.result.scannedAt = RR.Now()
  s.result.build = select(4, GetBuildInfo())
  self.db.journal = s.result
  scanner = nil
  self:Invalidate()
  local instances, mounts = 0, 0
  for _ in pairs(s.result.instances) do instances = instances + 1 end
  for _ in pairs(s.result.mounts) do mounts = mounts + 1 end
  RR.Print(string.format(L.COLL_SCAN_DONE, instances, mounts))
  local farm = RR.modules.FarmTargets
  if farm and RR:IsModuleActive("FarmTargets") then RR:ModuleCall(farm, "UpdateCollected") end
  RR:RefreshUI()
end

-- ---------- collected status and summaries ----------

local summaryCache
local collectedCache = {}

local tierCache -- forward declaration; filled by M:TierSets below

function M:Invalidate()
  summaryCache = nil
  tierCache = nil
  wipe(collectedCache)
end

-- Returns appearanceCollected, sourceCollected (nil when unknown).
local function isCollected(sourceID)
  local c = collectedCache[sourceID]
  if c == nil then
    local info = RR.Call("C_TransmogCollection.GetAppearanceInfoBySource", sourceID)
    if info then
      c = { app = info.appearanceIsCollected and true or false, src = info.sourceIsCollected and true or false }
    else
      local has = RR.Call("C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance", sourceID)
      c = { app = has and true or false, src = has and true or false }
    end
    collectedCache[sourceID] = c
  end
  return c.app, c.src
end

local function parseItems(items)
  local list = {}
  for entry in (items or ""):gmatch("[^;]+") do
    local itemID, sourceID, appearanceID, armor = entry:match("^(%d+):(%d+):(%d+):(%d+)$")
    if itemID then
      list[#list + 1] = { itemID = tonumber(itemID), sourceID = tonumber(sourceID),
        appearanceID = tonumber(appearanceID), armor = tonumber(armor) }
    end
  end
  return list
end

-- summary[jid][d] = { missing, total, armor = {[0..4]=n}, bosses = { [encounterID] = { name, missing, total, items } } }
function M:Summary()
  if summaryCache then return summaryCache end
  local journal = self.db.journal
  local completionist = self.db.completionist
  local summary = {}
  if journal then
    for jid, inst in pairs(journal.instances) do
      summary[jid] = {}
      for d, diff in pairs(inst.diffs) do
        local row = { missing = 0, total = 0, armor = {}, bosses = {} }
        local seenRow = {}
        for encounterID, boss in pairs(diff.bosses) do
          local b = { name = boss.name, missing = 0, total = 0, items = {} }
          local seenBoss = {}
          for _, item in ipairs(parseItems(boss.items)) do
            local key = completionist and item.sourceID or (item.appearanceID > 0 and item.appearanceID or -item.sourceID)
            local appCollected, srcCollected = isCollected(item.sourceID)
            local have = completionist and srcCollected or appCollected
            if not seenBoss[key] then
              seenBoss[key] = true
              b.total = b.total + 1
              if not have then
                b.missing = b.missing + 1
                b.items[#b.items + 1] = item
              end
            end
            if not seenRow[key] then
              seenRow[key] = true
              row.total = row.total + 1
              if not have then
                row.missing = row.missing + 1
                row.armor[item.armor] = (row.armor[item.armor] or 0) + 1
              end
            end
          end
          row.bosses[encounterID] = b
        end
        summary[jid][d] = row
      end
    end
  end
  summaryCache = summary
  return summary
end

-- The character's lockout for an instance + difficulty (by map ID, else by name), or nil.
local function findLock(char, inst, d)
  local lock = char.lockouts and char.lockouts[tostring(inst.mapID) .. ":" .. tostring(d)]
  if not lock and inst.name then
    local wanted = inst.name:lower()
    for _, l in pairs(char.lockouts or {}) do
      if l.difficultyID == d and l.nameLower == wanted then lock = l break end
    end
  end
  return lock
end

local function bossKilled(lock, bossName, now)
  return lock and lock.expires and lock.expires > now and lock.killed[(bossName or ""):lower()] and true or false
end

-- For one character: bosses with missing loot that are still unlocked. Returns available, total (or nil if unknown).
function M:CharAvailability(charKey, inst, d, row)
  local char = RR.db.chars[charKey]
  if not char then return nil end
  local total, available = 0, 0
  local lock = findLock(char, inst, d)
  local now = RR.Now()
  for _, boss in pairs(row.bosses) do
    if boss.missing > 0 then
      total = total + 1
      if not bossKilled(lock, boss.name, now) then available = available + 1 end
    end
  end
  if not char.lockoutsScanned then return nil, total end
  return available, total
end

-- Auto targets for FarmTargets: one per boss-drop mount found in the journal.
function M:GetAutoMountTargets()
  local list = {}
  if not self.db.autoMounts or not self.db.journal then return list end
  for mountID, mount in pairs(self.db.journal.mounts or {}) do
    if not self.db.hiddenAutoMounts[mountID] then
      list[#list + 1] = {
        id = "auto:" .. mountID, itemID = mount.itemID, kind = "mount", mountID = mountID,
        sources = mount.sources, auto = true,
      }
    end
  end
  return list
end

function M:HideAutoMount(mountID)
  self.db.hiddenAutoMounts[mountID] = true
  RR:RefreshUI()
end

-- ---------- Want from the Transmog tab ----------

-- Want contexts for every missing item of the given bosses on one difficulty.
local function wantContexts(inst, d, bosses)
  local list = {}
  for _, boss in ipairs(bosses) do
    for _, item in ipairs(boss.items or {}) do
      list[#list + 1] = {
        itemID = item.itemID, sourceID = item.sourceID, difficulty = d, mapID = inst.mapID, instance = inst.name,
        encounter = boss.name, isRaid = inst.isRaid,
      }
    end
  end
  return list
end

local function wantMenu(owner, title, inst, d, bosses)
  local farm = RR.modules.FarmTargets
  if not farm or not RR:IsModuleActive("FarmTargets") then RR.Print(L.WANT_NEED_FARM) return end
  local list = wantContexts(inst, d, bosses)
  RR.ShowMenu(owner, {
    { text = title, isTitle = true },
    { text = string.format(L.WANT_ALL, #list), disabled = #list == 0, func = function()
      RR.Print(string.format(L.WANT_ALL_DONE, farm:AddWants(list), title))
    end },
    { text = L.WANT_NONE, disabled = #list == 0, func = function()
      RR.Print(string.format(L.WANT_NONE_DONE, farm:RemoveWants(list), title))
    end },
  })
end

-- ---------- weekly planner ----------

local CLASS_ARMOR = {
  WARRIOR = 4, PALADIN = 4, DEATHKNIGHT = 4, HUNTER = 3, SHAMAN = 3, EVOKER = 3,
  ROGUE = 2, DRUID = 2, MONK = 2, DEMONHUNTER = 2, MAGE = 1, PRIEST = 1, WARLOCK = 1,
}

-- For one character: per instance and difficulty, the missing appearances on bosses that are still unlocked this
-- reset, most first. Returns nil when the journal was never scanned or the character's lockouts are unknown.
function M:PlannerEntries(charKey)
  local char = RR.db.chars[charKey]
  local journal = self.db.journal
  if not char or not journal or not char.lockoutsScanned then return nil end
  local armor = self.db.plannerArmorOnly and CLASS_ARMOR[char.class or ""]
  local summary = self:Summary()
  local now = RR.Now()
  local entries = {}
  for jid, inst in pairs(journal.instances) do
    if inst.isRaid or self.db.plannerDungeons then
      for d, row in pairs(summary[jid] or {}) do
        if row.missing > 0 then
          local lock = findLock(char, inst, d)
          local e = { jid = jid, inst = inst, d = d, items = 0, open = 0, total = 0, bosses = {} }
          for _, boss in pairs(row.bosses) do
            local usable = {}
            for _, item in ipairs(boss.items) do
              if not armor or item.armor == 0 or item.armor == armor then usable[#usable + 1] = item end
            end
            if #usable > 0 then
              e.total = e.total + 1
              if not bossKilled(lock, boss.name, now) then
                e.open = e.open + 1
                e.items = e.items + #usable
                e.bosses[#e.bosses + 1] = { name = boss.name, items = usable }
              end
            end
          end
          if e.items > 0 then
            table.sort(e.bosses, function(a, b) return #a.items > #b.items end)
            entries[#entries + 1] = e
          end
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.items ~= b.items then return a.items > b.items end
    if a.inst.tier ~= b.inst.tier then return a.inst.tier > b.inst.tier end
    return a.inst.name < b.inst.name
  end)
  return entries
end

-- ---------- tier sets ----------
-- Class sets of the current expansion whose variant label is a raid difficulty (so PvP sets are left out); the
-- newest patch wins. Collected status comes from C_TransmogSets and is account-wide per class.

local CLASS_IDS = {
  WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8,
  WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

local function difficultyLabels()
  local order = {}
  for i, key in ipairs({ "PLAYER_DIFFICULTY3", "PLAYER_DIFFICULTY1", "PLAYER_DIFFICULTY2", "PLAYER_DIFFICULTY6" }) do
    local text = _G[key]
    if type(text) == "string" then order[text] = i end
  end
  if not next(order) then order = { ["Raid Finder"] = 1, ["Normal"] = 2, ["Heroic"] = 3, ["Mythic"] = 4 } end
  return order
end

local function classOfMask(mask)
  if type(mask) ~= "number" or mask <= 0 then return nil end
  for classFile, id in pairs(CLASS_IDS) do
    if mask == 2 ^ (id - 1) then return classFile end
  end
end

local function appearanceName(appearanceID)
  local sources = RR.Call("C_TransmogCollection.GetAllAppearanceSources", appearanceID)
  local sourceID = type(sources) == "table" and sources[1]
  local info = sourceID and RR.Call("C_TransmogCollection.GetSourceInfo", sourceID)
  return info and info.name
end

-- Returns { label, variants = { "Normal", ... }, classes = { [classFile] = { [variant] = { total, missing = { names } } } } }
-- or nil when the API is missing or no tier set was found.
function M:TierSets()
  if tierCache ~= nil then return tierCache or nil end
  tierCache = false
  local sets = RR.Call("C_TransmogSets.GetAllSets")
  if type(sets) ~= "table" then return nil end
  local expansion = (GetExpansionLevel and GetExpansionLevel()) or LE_EXPANSION_LEVEL_CURRENT
  local diffOrder = difficultyLabels()
  local best, bestPatch = {}, -1
  for _, set in ipairs(sets) do
    local classFile = classOfMask(set.classMask)
    if classFile and set.expansionID == expansion and diffOrder[set.description or ""] then
      local patch = set.patchID or 0
      if patch > bestPatch then best, bestPatch = {}, patch end
      if patch == bestPatch then best[#best + 1] = { set = set, classFile = classFile } end
    end
  end
  if #best == 0 then return nil end
  local result = { label = best[1].set.label or best[1].set.name, variants = {}, classes = {} }
  local seenVariant = {}
  for _, entry in ipairs(best) do
    local set, variant = entry.set, entry.set.description
    if not seenVariant[variant] then
      seenVariant[variant] = true
      result.variants[#result.variants + 1] = variant
    end
    local appearances = RR.Call("C_TransmogSets.GetSetPrimaryAppearances", set.setID) or {}
    local cell = { total = 0, missing = {} }
    for _, a in ipairs(appearances) do
      cell.total = cell.total + 1
      if not a.collected then cell.missing[#cell.missing + 1] = appearanceName(a.appearanceID) or ("#" .. tostring(a.appearanceID)) end
    end
    result.classes[entry.classFile] = result.classes[entry.classFile] or {}
    result.classes[entry.classFile][variant] = cell
  end
  table.sort(result.variants, function(a, b) return (diffOrder[a] or 9) < (diffOrder[b] or 9) end)
  tierCache = result
  return result
end

-- ---------- Adventure Guide overlay ----------
-- Decorates the loot list of Blizzard's Adventure Guide (loaded on demand) via ScrollUtil callbacks, which only add
-- our own child frames: a Want star (adds the item for the selected difficulty to the checklist) and a collected
-- mark. A small bar under the guide shows missing appearances per difficulty from the journal scan.

local overlay = {}
local STAR_ON, STAR_OFF = "auctionhouse-icon-favorite", "auctionhouse-icon-favorite-off"

local function setAtlasOr(texture, atlas, fallback)
  if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
    texture:SetAtlas(atlas)
  else
    texture:SetTexture(fallback)
  end
end

local function journalContext()
  local jid = EncounterJournal and EncounterJournal.instanceID
  if not jid then return nil end
  local name, _, _, _, _, _, _, _, _, mapID = EJ_GetInstanceInfo(jid)
  return {
    jid = jid, instance = name, mapID = mapID, difficulty = EJ_GetDifficulty and EJ_GetDifficulty(),
    isRaid = EJ_InstanceIsRaid and EJ_InstanceIsRaid() or false, encounterID = EncounterJournal.encounterID,
  }
end

local function lootInfo(frame, elementData)
  local index = (type(elementData) == "table" and elementData.index) or frame.index
  local info = index and RR.Call("C_EncounterJournal.GetLootInfoByIndex", index)
  if info and info.itemID then return info end
  if frame.itemID then return { itemID = frame.itemID, link = frame.link, encounterID = frame.encounterID } end
end

-- true / false / nil (nil = not a collectible)
local function lootCollected(info)
  local mountID = RR.Call("C_MountJournal.GetMountFromItem", info.itemID)
  if mountID and mountID > 0 then
    return select(11, RR.Call("C_MountJournal.GetMountInfoByID", mountID)) and true or false
  end
  if not info.link then return nil end
  local _, sourceID = RR.Call("C_TransmogCollection.GetItemInfo", info.link)
  if not sourceID then return nil end
  return (isCollected(sourceID))
end

local function decorate(frame, elementData)
  if type(frame) ~= "table" or not frame.CreateTexture then return end
  local deco = frame.ResetRadarDeco
  if not deco then
    deco = {}
    local anchor = frame.icon or frame.Icon or frame
    deco.star = CreateFrame("Button", nil, frame)
    deco.star:SetSize(16, 16)
    deco.star:SetPoint("TOPLEFT", anchor, "TOPLEFT", -4, 4)
    deco.star:SetFrameLevel(frame:GetFrameLevel() + 5)
    deco.star.tex = deco.star:CreateTexture(nil, "OVERLAY")
    deco.star.tex:SetAllPoints()
    deco.check = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    deco.check:SetSize(14, 14)
    deco.check:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 3, -3)
    setAtlasOr(deco.check, "common-icon-checkmark", "Interface\\RaidFrame\\ReadyCheck-Ready")
    deco.star:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(L.ADDON_TITLE)
      GameTooltip:AddLine(self.wanted and L.WANT_TIP_ON or L.WANT_TIP_OFF, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    deco.star:SetScript("OnLeave", function() GameTooltip:Hide() end)
    deco.star:SetScript("OnClick", function(self)
      local farm = RR.modules.FarmTargets
      local ctx = journalContext()
      if not self.info or not ctx or not ctx.difficulty or not farm or not RR:IsModuleActive("FarmTargets") then
        RR.Print(L.WANT_NEED_FARM)
        return
      end
      ctx.itemID, ctx.link = self.info.itemID, self.info.link
      ctx.encounter = self.info.encounterID and EJ_GetEncounterInfo and EJ_GetEncounterInfo(self.info.encounterID) or nil
      local added = farm:ToggleWant(ctx)
      local name = C_Item.GetItemInfo(ctx.itemID) or ("item:" .. ctx.itemID)
      RR.Print(string.format(added and L.WANT_ADDED or L.WANT_REMOVED, name))
      M:RefreshJournal()
    end)
    frame.ResetRadarDeco = deco
  end
  local info = M.active and M.db.journalOverlay and lootInfo(frame, elementData)
  if not info then
    deco.star:Hide()
    deco.check:Hide()
    return
  end
  local ctx = journalContext()
  local farm = RR.modules.FarmTargets
  local wanted = ctx and farm and RR:IsModuleActive("FarmTargets") and farm:IsWanted(info.itemID, ctx.difficulty) or false
  deco.star.info, deco.star.wanted = info, wanted
  setAtlasOr(deco.star.tex, wanted and STAR_ON or STAR_OFF, "Interface\\Common\\FavoritesIcon")
  deco.star.tex:SetDesaturated(not wanted)
  deco.star:SetAlpha(wanted and 1 or 0.45)
  deco.star:Show()
  deco.check:SetShown(lootCollected(info) == true)
end

-- Text for the bar: missing per difficulty for the open instance, current difficulty highlighted.
function M:JournalSummaryText()
  local ctx = journalContext()
  if not ctx then return nil end
  local journal = self.db.journal
  if not journal then return L.EJ_BAR_NO_SCAN end
  local rows = journal.instances[ctx.jid] and self:Summary()[ctx.jid]
  if not rows or not next(rows) then return L.EJ_BAR_NONE end
  local diffs = {}
  for d in pairs(rows) do diffs[#diffs + 1] = d end
  table.sort(diffs, function(a, b) return (DIFF_ORDER[a] or 99) < (DIFF_ORDER[b] or 99) end)
  local parts = {}
  for _, d in ipairs(diffs) do
    local row = rows[d]
    local color = row.missing == 0 and "|cff40ff40" or "|cffff8080"
    local part = string.format("%s %s%d/%d|r", difficultyName(d), color, row.missing, row.total)
    if d == ctx.difficulty then part = "|cffffd100[|r" .. part .. "|cffffd100]|r" end
    parts[#parts + 1] = part
  end
  local text = L.EJ_BAR_MISSING .. " " .. table.concat(parts, "  ")
  local current = ctx.difficulty and rows[ctx.difficulty]
  local boss = current and ctx.encounterID and current.bosses[ctx.encounterID]
  if boss then text = text .. "   " .. string.format(L.EJ_BAR_BOSS, boss.name or "?", boss.missing, boss.total) end
  return text
end

function M:RefreshJournal()
  if not overlay.hooked or not EncounterJournal or not EncounterJournal:IsShown() then return end
  if overlay.scrollBox and overlay.scrollBox.ForEachFrame then
    pcall(overlay.scrollBox.ForEachFrame, overlay.scrollBox, function(frame, elementData)
      RR.SafeCall("journal decorate", decorate, frame, elementData)
    end)
  end
  local bar = overlay.bar
  if bar then
    local text = self.active and self.db.journalOverlay and self:JournalSummaryText()
    if text then
      bar.text:SetText(text)
      bar:Show()
    else
      bar:Hide()
    end
  end
end

local refreshPending
local function refreshSoon()
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(0.1, function()
    refreshPending = false
    RR.SafeCall("journal refresh", M.RefreshJournal, M)
  end)
end

function M:HookJournal()
  if overlay.hooked then return end
  local info = EncounterJournal and EncounterJournal.encounter and EncounterJournal.encounter.info
  local scrollBox = info and info.LootContainer and info.LootContainer.ScrollBox
  if not scrollBox or not ScrollUtil then
    RR.Debug("Adventure Guide loot list not found; overlay disabled")
    return
  end
  overlay.hooked = true
  overlay.scrollBox = scrollBox
  local function onFrame(a, b, c)
    -- ScrollUtil passes (frame, elementData); a raw callback passes (owner, frame, elementData)
    local frame, elementData = a, b
    if type(a) ~= "table" or not a.GetObjectType then frame, elementData = b, c end
    RR.SafeCall("journal decorate", decorate, frame, elementData)
    refreshSoon()
  end
  if ScrollUtil.AddInitializedFrameCallback then
    ScrollUtil.AddInitializedFrameCallback(scrollBox, onFrame, M, true)
  elseif ScrollUtil.AddAcquiredFrameCallback then
    ScrollUtil.AddAcquiredFrameCallback(scrollBox, onFrame, M, true)
  end

  local bar = CreateFrame("Frame", nil, EncounterJournal, "BackdropTemplate")
  RR.CreateBackdrop(bar, 0.92)
  bar:SetPoint("TOPLEFT", EncounterJournal, "BOTTOMLEFT", 0, -2)
  bar:SetPoint("TOPRIGHT", EncounterJournal, "BOTTOMRIGHT", 0, -2)
  bar:SetHeight(22)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("LEFT", 8, 0)
  bar.text:SetPoint("RIGHT", -8, 0)
  bar.text:SetJustifyH("LEFT")
  bar.text:SetWordWrap(false)
  bar:Hide()
  overlay.bar = bar
  EncounterJournal:HookScript("OnShow", refreshSoon)
  refreshSoon()
end

-- ---------- module hooks ----------

function M:OnInitialize(db)
  self.db = db
end

local invalidateTimer
function M:OnEvent(event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == "Blizzard_EncounterJournal" then RR.SafeCall("HookJournal", M.HookJournal, M) end
    return
  elseif event == "EJ_DIFFICULTY_UPDATE" or event == "EJ_LOOT_DATA_RECIEVED" then
    if not scanner then refreshSoon() end
    return
  end
  if event == "PLAYER_REGEN_ENABLED" and scanner and scanner.paused then
    local paused = scanner.paused
    scanner.paused = nil
    if paused == "difficulty" then scanner.d = scanner.d - 1 return self:NextDifficulty() end
    return self:NextInstance()
  elseif event == "TRANSMOG_COLLECTION_UPDATED" or event == "NEW_MOUNT_ADDED" then
    if invalidateTimer then return end
    invalidateTimer = C_Timer.NewTimer(RR.DEBOUNCE, function()
      invalidateTimer = nil
      M:Invalidate()
      RR:RefreshUI()
      refreshSoon()
    end)
  end
end

function M:OnEnable()
  if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
    RR.SafeCall("HookJournal", M.HookJournal, M)
  end
end

function M:OnDisable()
  self:CancelScan()
  if overlay.bar then overlay.bar:Hide() end
end

function M:AddMinimapLines(tt)
  if not self.db.journal then return end
  local missing = 0
  for _, diffs in pairs(self:Summary()) do
    for _, row in pairs(diffs) do missing = missing + row.missing end
  end
  tt:AddLine(string.format(L.COLL_MINIMAP, missing), 0.8, 0.6, 1)
end

function M:BuildSettings(layout)
  local db = self.db
  layout:AddHeader(L.COLL_TITLE)
  layout:AddCheck(L.COLL_OPT_AUTOMOUNTS, L.COLL_OPT_AUTOMOUNTS_TIP, function() return db.autoMounts end,
    function(v) db.autoMounts = v RR:RefreshUI() end)
  layout:AddCheck(L.COLL_OPT_DUNGEONS, L.COLL_OPT_DUNGEONS_TIP, function() return db.includeDungeons end,
    function(v) db.includeDungeons = v end)
  layout:AddCheck(L.COLL_OPT_OVERLAY, L.COLL_OPT_OVERLAY_TIP, function() return db.journalOverlay end,
    function(v) db.journalOverlay = v refreshSoon() end)
  layout:AddCheck(L.COLL_OPT_COMPLETIONIST, L.COLL_OPT_COMPLETIONIST_TIP, function() return db.completionist end,
    function(v) db.completionist = v M:Invalidate() RR:RefreshUI() end)
end

-- ---------- UI: Transmog tab ----------

local FILTER_LABEL = { raids = L.COLL_FILTER_RAIDS, dungeons = L.COLL_FILTER_DUNGEONS, all = L.COLL_FILTER_ALL }
local FILTER_NEXT = { raids = "dungeons", dungeons = "all", all = "raids" }

local function missingTooltip(title, items, armorCounts)
  return function(tt)
    tt:AddLine(title)
    if armorCounts then
      local parts = {}
      for armor = 0, 4 do
        if armorCounts[armor] then parts[#parts + 1] = string.format("%s %d", ARMOR_NAMES[armor], armorCounts[armor]) end
      end
      if #parts > 0 then tt:AddLine(table.concat(parts, ", "), 1, 1, 1, true) end
    end
    for i, item in ipairs(items or {}) do
      if i > 20 then tt:AddLine(string.format(L.COLL_MORE, #items - 20), 0.7, 0.7, 0.7) break end
      local name, _, quality = C_Item.GetItemInfo(item.itemID)
      if not name and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(item.itemID) end
      local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
      tt:AddDoubleLine(name or ("item:" .. item.itemID), ARMOR_NAMES[item.armor] or "",
        color and color.r or 1, color and color.g or 1, color and color.b or 1, 0.7, 0.7, 0.7)
    end
  end
end

local function availabilityCell(charKey, inst, d, row)
  local available, total = M:CharAvailability(charKey, inst, d, row)
  if total == 0 then return RR.FormatState("na", "-") end
  if available == nil then return RR.FormatState("na", "?") end
  local state = (available == total and "done") or (available > 0 and "progress") or "open"
  return RR.FormatState(state, string.format("%d/%d", available, total))
end

local function buildTransmogTab(parent)
  local tab = {}
  local db = M.db

  local scanBtn = RR.CreateButton(parent, L.COLL_SCAN, 120, function()
    if M:IsScanning() then M:CancelScan(L.COLL_SCAN_CANCELLED) else M:StartScan() end
  end)
  scanBtn:SetPoint("TOPLEFT", 4, -4)
  local filterBtn = RR.CreateButton(parent, "", 110, function()
    db.instanceFilter = FILTER_NEXT[db.instanceFilter] or "raids"
    tab:Refresh()
  end)
  filterBtn:SetPoint("LEFT", scanBtn, "RIGHT", 4, 0)
  local sortBtn = RR.CreateButton(parent, "", 130, function()
    db.sortBy = db.sortBy == "tier" and "missing" or "tier"
    tab:Refresh()
  end)
  sortBtn:SetPoint("LEFT", filterBtn, "RIGHT", 4, 0)
  local completeCheck = RR.CreateCheck(parent, L.COLL_HIDE_COMPLETE, function(v) db.hideComplete = v tab:Refresh() end)
  completeCheck:SetPoint("LEFT", sortBtn, "RIGHT", 8, 0)
  local status = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("TOPLEFT", 4, -30)
  status:SetPoint("RIGHT", -4, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  local holder = CreateFrame("Frame", nil, parent)
  holder:SetPoint("TOPLEFT", 0, -46)
  holder:SetPoint("BOTTOMRIGHT")
  local grid = RR.CreateGrid(holder, 280)

  function tab:Refresh()
    filterBtn:SetLabel(FILTER_LABEL[db.instanceFilter] or L.COLL_FILTER_RAIDS)
    sortBtn:SetLabel(db.sortBy == "tier" and L.COLL_SORT_TIER or L.COLL_SORT_MISSING)
    completeCheck:SetChecked(db.hideComplete)
    local columns = { { key = "_missing", label = L.COLL_COL_MISSING } }
    for _, col in ipairs(RR:CharColumns()) do columns[#columns + 1] = col end
    local rows = {}

    if M:IsScanning() then
      local i, n = M:ScanProgress()
      scanBtn:SetLabel(L.COLL_CANCEL)
      status:SetText(string.format(L.COLL_SCANNING, i, n))
    else
      scanBtn:SetLabel(db.journal and L.COLL_RESCAN or L.COLL_SCAN)
    end

    local journal = db.journal
    if not journal then
      if not M:IsScanning() then status:SetText(L.COLL_NO_DATA) end
      grid:SetData(columns, { { label = L.COLL_NO_DATA_ROW } })
      grid:Render()
      return
    end

    local summary = M:Summary()
    local entries, totalMissing = {}, 0
    for jid, inst in pairs(journal.instances) do
      local wanted = db.instanceFilter == "all" or (db.instanceFilter == "raids") == (inst.isRaid and true or false)
      if wanted then
        for d in pairs(inst.diffs) do
          local row = summary[jid] and summary[jid][d]
          if row then
            totalMissing = totalMissing + row.missing
            if not (db.hideComplete and row.missing == 0) then
              entries[#entries + 1] = { jid = jid, inst = inst, d = d, row = row }
            end
          end
        end
      end
    end
    table.sort(entries, function(a, b)
      if db.sortBy == "missing" and a.row.missing ~= b.row.missing then return a.row.missing > b.row.missing end
      if a.inst.tier ~= b.inst.tier then return a.inst.tier > b.inst.tier end
      if a.inst.isRaid ~= b.inst.isRaid then return a.inst.isRaid and true or false end
      if a.inst.name ~= b.inst.name then return a.inst.name < b.inst.name end
      return (DIFF_ORDER[a.d] or 99) < (DIFF_ORDER[b.d] or 99)
    end)

    if not M:IsScanning() then
      local outdated = journal.build ~= select(4, GetBuildInfo())
      status:SetText(string.format(L.COLL_STATUS, totalMissing, RR.FormatAgo(journal.scannedAt))
        .. (outdated and ("  |cffff8000" .. L.COLL_OUTDATED .. "|r") or ""))
    end

    local lastTier
    for _, e in ipairs(entries) do
      if db.sortBy == "tier" and e.inst.tier ~= lastTier then
        lastTier = e.inst.tier
        rows[#rows + 1] = { label = e.inst.tierName, header = true }
      end
      local key = e.jid .. ":" .. e.d
      local expanded = db.expanded[key]
      local row = e.row
      rows[#rows + 1] = {
        label = (expanded and "- " or "+ ") .. e.inst.name .. " |cff808080" .. difficultyName(e.d) .. "|r",
        tooltip = missingTooltip(e.inst.name .. " - " .. difficultyName(e.d), nil, row.armor),
        onClick = function()
          db.expanded[key] = not expanded or nil
          tab:Refresh()
        end,
        onRightClick = function(owner)
          local all = {}
          for _, boss in pairs(row.bosses) do all[#all + 1] = boss end
          wantMenu(owner, e.inst.name .. " - " .. difficultyName(e.d), e.inst, e.d, all)
        end,
        cell = function(colKey)
          if colKey == "_missing" then
            local state = row.missing == 0 and "done" or "open"
            return RR.FormatState(state, string.format("%d/%d", row.missing, row.total)),
              missingTooltip(string.format(L.COLL_TIP_MISSING, row.missing, row.total), nil, row.armor)
          end
          return availabilityCell(colKey, e.inst, e.d, row), RR.TipFromLines(e.inst.name, { L.COLL_TIP_AVAIL })
        end,
      }
      if expanded then
        local bosses = {}
        for _, boss in pairs(row.bosses) do bosses[#bosses + 1] = boss end
        table.sort(bosses, function(a, b) return (a.name or "") < (b.name or "") end)
        for _, boss in ipairs(bosses) do
          if not (db.hideComplete and boss.missing == 0) then
            rows[#rows + 1] = {
              label = "      " .. (boss.name or "?"),
              tooltip = missingTooltip(boss.name or "?", boss.items),
              onRightClick = function(owner)
                wantMenu(owner, (boss.name or "?") .. " - " .. difficultyName(e.d), e.inst, e.d, { boss })
              end,
              cell = function(colKey)
                if colKey == "_missing" then
                  return RR.FormatState(boss.missing == 0 and "done" or "open",
                    string.format("%d/%d", boss.missing, boss.total)), missingTooltip(boss.name or "?", boss.items)
                end
                if boss.missing == 0 then return RR.FormatState("na", "-") end
                local char = RR.db.chars[colKey]
                if not char or not char.lockoutsScanned then return RR.FormatState("na", "?") end
                local single = { bosses = { boss } }
                local available = M:CharAvailability(colKey, e.inst, e.d, single)
                return available == 1 and RR.FormatState("done", L.FARM_CHANCE) or RR.FormatState("open", L.FARM_LOCKED)
              end,
            }
          end
        end
      end
    end
    if #entries == 0 then rows[#rows + 1] = { label = L.COLL_NOTHING_MISSING } end
    grid:SetData(columns, rows)
    grid:Render()
  end
  return tab
end

-- ---------- UI: Planner tab ----------

local function plannerCharKey()
  local key = M.db.plannerChar
  if key and RR.db.chars[key] then return key end
  return RR.charKey
end

local function buildPlannerTab(parent)
  local tab = {}
  local db = M.db

  local charBtn = RR.CreateButton(parent, "", 170, function(self)
    local items = { { text = L.PLAN_PICK_CHAR, isTitle = true } }
    for key, char in pairs(RR.db.chars) do
      if not char.hidden then
        items[#items + 1] = { key = key, text = RR:CharDisplayName(key), func = function()
          db.plannerChar = key ~= RR.charKey and key or nil
          tab:Refresh()
        end }
      end
    end
    table.sort(items, function(a, b)
      if not a.key or not b.key then return not a.key end
      return a.key < b.key
    end)
    RR.ShowMenu(self, items)
  end)
  charBtn:SetPoint("TOPLEFT", 4, -4)
  local dungeonCheck = RR.CreateCheck(parent, L.PLAN_DUNGEONS, function(v) db.plannerDungeons = v tab:Refresh() end)
  dungeonCheck:SetPoint("LEFT", charBtn, "RIGHT", 8, 0)
  local armorCheck = RR.CreateCheck(parent, L.PLAN_ARMOR_ONLY, function(v) db.plannerArmorOnly = v tab:Refresh() end)
  armorCheck:SetPoint("LEFT", dungeonCheck, "RIGHT", 120, 0)
  local status = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("TOPLEFT", 4, -30)
  status:SetPoint("RIGHT", -4, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  local holder = CreateFrame("Frame", nil, parent)
  holder:SetPoint("TOPLEFT", 0, -46)
  holder:SetPoint("BOTTOMRIGHT")
  local grid = RR.CreateGrid(holder, 300)
  local columns = {
    { key = "items", label = L.PLAN_COL_ITEMS }, { key = "bosses", label = L.PLAN_COL_BOSSES },
    { key = "wanted", label = L.PLAN_COL_WANTED },
  }

  -- Wanted items with a chance for this character in this instance + difficulty.
  local function wantedCount(charKey, inst, d)
    local farm = RR.modules.FarmTargets
    if not farm or not RR:IsModuleActive("FarmTargets") then return 0 end
    local n = 0
    for _, target in pairs(farm.db.targets) do
      local source = target.want and target.sources[1]
      if source and not farm.db.collected[target.id]
        and (source.mapID == inst.mapID or (source.instance and inst.name and source.instance:lower() == inst.name:lower())) then
        for _, wd in ipairs(source.difficulties or {}) do
          if wd == d and farm:Status(charKey, target) == "chance" then n = n + 1 break end
        end
      end
    end
    return n
  end

  local function bossTooltip(e)
    return function(tt)
      tt:AddLine(e.inst.name .. " - " .. difficultyName(e.d))
      for _, boss in ipairs(e.bosses) do
        tt:AddDoubleLine(boss.name or "?", string.format(L.PLAN_TIP_ITEMS, #boss.items), 1, 1, 1, 1, 0.5, 0.5)
      end
      tt:AddLine(L.PLAN_TIP_RCLICK, 0.5, 0.5, 0.5)
    end
  end

  function tab:Refresh()
    local charKey = plannerCharKey()
    charBtn:SetLabel(charKey and RR:CharDisplayName(charKey) or "?")
    dungeonCheck:SetChecked(db.plannerDungeons)
    armorCheck:SetChecked(db.plannerArmorOnly)
    local rows = {}
    local entries = charKey and M:PlannerEntries(charKey)
    if not db.journal then
      status:SetText(L.COLL_NO_DATA)
    elseif not entries then
      status:SetText(L.PLAN_NO_LOCKOUTS)
    else
      local total = 0
      for _, e in ipairs(entries) do total = total + e.items end
      status:SetText(string.format(L.PLAN_STATUS, total, #entries, RR.FormatDuration((RR:GetNextReset("weekly") or RR.Now()) - RR.Now())))
      for _, e in ipairs(entries) do
        local wanted = wantedCount(charKey, e.inst, e.d)
        rows[#rows + 1] = {
          label = e.inst.name .. " |cff808080" .. difficultyName(e.d) .. "|r",
          tooltip = bossTooltip(e),
          onRightClick = function(owner)
            wantMenu(owner, e.inst.name .. " - " .. difficultyName(e.d), e.inst, e.d, e.bosses)
          end,
          cell = function(colKey)
            if colKey == "items" then return RR.FormatState("open", tostring(e.items)), bossTooltip(e) end
            if colKey == "bosses" then
              return RR.FormatState(e.open == e.total and "done" or "progress", string.format("%d/%d", e.open, e.total)),
                bossTooltip(e)
            end
            return RR.FormatState(wanted > 0 and "done" or "na", wanted > 0 and tostring(wanted) or "-")
          end,
        }
      end
    end
    if #rows == 0 then rows[1] = { label = entries and L.PLAN_NOTHING or L.COLL_NO_DATA_ROW } end
    grid:SetData(columns, rows)
    grid:Render()
  end
  return tab
end

-- ---------- UI: Tier sets tab ----------

local function buildTierTab(parent)
  local tab = {}
  local status = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("TOPLEFT", 4, -8)
  status:SetPoint("RIGHT", -4, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetPoint("TOPLEFT", 0, -26)
  holder:SetPoint("BOTTOMRIGHT")
  local grid = RR.CreateGrid(holder, 260)

  function tab:Refresh()
    local tier = M:TierSets()
    if not tier then
      status:SetText(L.TIER_NONE)
      grid:SetData({}, { { label = L.TIER_NONE } })
      grid:Render()
      return
    end
    -- one row per class you have characters of
    local byClass, classes = {}, {}
    for key, char in pairs(RR.db.chars) do
      if char.class and not char.hidden then
        if not byClass[char.class] then
          byClass[char.class] = {}
          classes[#classes + 1] = char.class
        end
        table.insert(byClass[char.class], key)
      end
    end
    table.sort(classes)
    local columns = {}
    for _, variant in ipairs(tier.variants) do columns[#columns + 1] = { key = variant, label = variant } end
    local rows = {}
    for _, classFile in ipairs(classes) do
      local cells = tier.classes[classFile] or {}
      local names = {}
      for _, key in ipairs(byClass[classFile]) do names[#names + 1] = RR:CharDisplayName(key, true) end
      local className = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]) or classFile
      rows[#rows + 1] = {
        label = RR.ClassColored(className, classFile) .. "  |cff808080" .. table.concat(names, ", ") .. "|r",
        cell = function(variant)
          local c = cells[variant]
          if not c or c.total == 0 then return RR.FormatState("na", "-") end
          local text = string.format("%d/%d", #c.missing, c.total)
          local tip = function(tt)
            tt:AddLine(string.format("%s - %s (%s)", tier.label or "?", className, variant))
            if #c.missing == 0 then tt:AddLine(L.TIER_COMPLETE, 0.5, 1, 0.5) end
            for _, name in ipairs(c.missing) do tt:AddLine(name, 1, 1, 1) end
            tt:AddLine(string.format(L.TIER_TIP_SOURCE, variant), 0.5, 0.5, 0.5, true)
          end
          return RR.FormatState(#c.missing == 0 and "done" or "open", text), tip
        end,
      }
    end
    if #rows == 0 then rows[1] = { label = L.TIER_NONE } end
    status:SetText(string.format(L.TIER_STATUS, tier.label or "?"))
    grid:SetData(columns, rows)
    grid:Render()
  end
  return tab
end

function M:GetTabs()
  return {
    { key = "transmog", label = L.TAB_TRANSMOG, build = buildTransmogTab, order = 22 },
    { key = "tier", label = L.TAB_TIER, build = buildTierTab, order = 23 },
    { key = "planner", label = L.TAB_PLANNER, build = buildPlannerTab, order = 24 },
  }
end

RR:RegisterModule("Collections", M)
