-- ResetRadar: checklist definitions.
--
-- Adding an item is one RR:RegisterItem block:
--   key        unique id (also used in saved data)
--   label      row label (put the text in Locales.lua)
--   resetType  "daily" | "weekly" | nil (nil = informational, never reset)
--   scope      "character" (default) | "account"
--   order      sort order in the window
--   check      function(ctx) run for the logged-in character, inside pcall. ctx = { char, now, L, RR }.
--              Return { state = "open"|"progress"|"done"|"info"|"na", cur, max, text, tip = {lines} }
--              or a group: { sub = { [subKey] = { label, state, cur, max, text, tip, expires, dropOnReset } } }.
--              Return false to remove the item for this character, nil to keep the previous value.
--   onReset    optional function(entry, char) called when the stored value passes its reset time.
--
-- The tables in RR.Data let you pin quests and currencies by ID without writing a check.

local _, ns = ...
local RR, L = ns.RR, ns.L

RR.Data = {
  -- Quests to show as their own row. Find the ID on Wowhead. resetType decides when they go back to "open".
  -- Example: { questID = 12345, label = "Weekly: Example quest", resetType = "weekly" },
  pinnedQuests = {
  },
  -- Extra currencies to always track (the scanner already finds every currency with a weekly cap that is
  -- visible in your currency list). Example: { currencyID = 3008 },
  extraCurrencies = {
  },
}

local Enum = Enum or {}

local function stateFromProgress(cur, max)
  if not cur or not max or max == 0 then return "na" end
  if cur >= max then return "done" end
  if cur > 0 then return "progress" end
  return "open"
end

-- ---------- 1. Great Vault ----------

local VAULT_TYPES = {
  { key = "mplus", label = L.VAULT_MPLUS, enum = "Activities", fallback = 1 },
  { key = "raid", label = L.VAULT_RAID, enum = "Raid", fallback = 3 },
  { key = "world", label = L.VAULT_WORLD, enum = "World", fallback = 6 },
}

RR:RegisterItem({
  key = "vault", label = L.VAULT, resetType = "weekly", order = 10,
  check = function(ctx)
    if not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then return nil end
    local thresholdEnum = Enum.WeeklyRewardChestThresholdType or {}
    local sub = {}
    for _, t in ipairs(VAULT_TYPES) do
      local activities = RR.Call("C_WeeklyRewards.GetActivities", thresholdEnum[t.enum] or t.fallback)
      if activities and #activities > 0 then
        local unlocked, best, tip = 0, 0, {}
        table.sort(activities, function(a, b) return (a.index or 0) < (b.index or 0) end)
        for _, a in ipairs(activities) do
          if a.progress and a.threshold and a.progress >= a.threshold then
            unlocked = unlocked + 1
            best = math.max(best, a.level or 0)
          end
          tip[#tip + 1] = string.format(L.VAULT_SLOT_TIP, a.index or 0, math.min(a.progress or 0, a.threshold or 0),
            a.threshold or 0)
        end
        sub[t.key] = {
          label = t.label, cur = unlocked, max = #activities, state = stateFromProgress(unlocked, #activities),
          text = string.format("%d/%d", unlocked, #activities), tip = tip,
        }
      end
    end
    local claimable = RR.Call("C_WeeklyRewards.HasAvailableRewards")
    sub.claim = {
      label = L.VAULT_CLAIM, state = claimable and "open" or "done", noExpire = true,
      text = claimable and L.VAULT_READY or L.VAULT_NOTHING,
    }
    return { sub = sub }
  end,
  -- After the weekly reset, any unlocked slot from last week becomes a reward to collect.
  onReset = function(entry)
    if not entry.sub then return end
    local anyUnlocked = false
    for key, sub in pairs(entry.sub) do
      if key ~= "claim" and (sub.cur or 0) > 0 then anyUnlocked = true end
    end
    if anyUnlocked then
      entry.sub.claim = { label = L.VAULT_CLAIM, state = "open", text = L.VAULT_READY_INFERRED, noExpire = true }
    end
  end,
})

-- ---------- 2. Mythic+ keystone ----------

RR:RegisterItem({
  key = "keystone", label = L.KEYSTONE, resetType = "weekly", order = 20,
  onResetText = L.KEYSTONE_STALE,
  check = function(ctx)
    if not C_MythicPlus then return nil end
    local mapID = RR.Call("C_MythicPlus.GetOwnedKeystoneChallengeMapID")
    local level = RR.Call("C_MythicPlus.GetOwnedKeystoneLevel")
    local runs = RR.Call("C_MythicPlus.GetRunHistory", false, true) or {}
    local text
    if mapID and level and level > 0 then
      local name = RR.Call("C_ChallengeMode.GetMapUIInfo", mapID) or ("#" .. mapID)
      text = string.format("%s +%d", name, level)
    else
      text = L.KEYSTONE_NONE
    end
    local best = 0
    for _, run in ipairs(runs) do best = math.max(best, run.level or 0) end
    local tip = { string.format(L.KEYSTONE_RUNS, #runs) }
    if best > 0 then tip[#tip + 1] = string.format(L.KEYSTONE_BEST, best) end
    return { state = #runs > 0 and "done" or "open", text = text, tip = tip }
  end,
})

-- ---------- 3. Raid lockouts ----------

RR:RegisterItem({
  key = "raids", label = L.RAIDS, resetType = "weekly", order = 30,
  check = function(ctx)
    local lockouts = ctx.char.lockouts
    if not ctx.char.lockoutsScanned then return nil end -- wait for UPDATE_INSTANCE_INFO
    local sub = {}
    for key, lock in pairs(lockouts) do
      if lock.isRaid then
        local tip = {}
        for boss in pairs(lock.killed) do tip[#tip + 1] = boss end
        table.sort(tip)
        sub[key] = {
          label = string.format("%s (%s)", lock.name, lock.difficultyName or "?"),
          cur = lock.progress, max = lock.numEncounters,
          state = stateFromProgress(lock.progress, lock.numEncounters),
          text = string.format("%d/%d", lock.progress, lock.numEncounters),
          expires = lock.expires, dropOnReset = true, tip = tip,
        }
      end
    end
    return { sub = sub }
  end,
})

-- ---------- 4 + 5. Weekly and daily quests ----------
-- Detected from the quest log (frequency Daily/Weekly) and remembered per character. Completion is checked with
-- C_QuestLog.IsQuestFlaggedCompleted, which the game itself resets at the daily/weekly reset.

local KNOWN_QUEST_TTL = 28 * 86400

local function scanQuestLog(char, now)
  local known = char.quests.known
  local freqEnum = Enum.QuestFrequency or {}
  local DAILY, WEEKLY = freqEnum.Daily or 1, freqEnum.Weekly or 2
  local inLog = {}
  local n = RR.Call("C_QuestLog.GetNumQuestLogEntries") or 0
  for i = 1, n do
    local info = RR.Call("C_QuestLog.GetInfo", i)
    if info and not info.isHeader and not info.isHidden and info.questID and not info.isTask then
      local resetType = (info.frequency == WEEKLY and "weekly") or (info.frequency == DAILY and "daily") or nil
      if resetType then
        inLog[info.questID] = true
        known[info.questID] = known[info.questID] or {}
        local q = known[info.questID]
        q.title, q.resetType, q.lastSeen = info.title, resetType, now
      end
    end
  end
  for questID, q in pairs(known) do
    if not inLog[questID] and (now - (q.lastSeen or 0)) > KNOWN_QUEST_TTL then known[questID] = nil end
  end
  return inLog
end

local function questSummary(ctx, resetType)
  local char = ctx.char
  local inLog = ctx.questsInLog
  if not inLog then
    inLog = scanQuestLog(char, ctx.now)
    ctx.questsInLog = inLog
  end
  local done, open, tip = 0, 0, {}
  for questID, q in pairs(char.quests.known) do
    if q.resetType == resetType then
      local completed = RR.Call("C_QuestLog.IsQuestFlaggedCompleted", questID)
      if completed then
        done = done + 1
        tip[#tip + 1] = "|cff40ff40" .. (q.title or questID) .. "|r"
      elseif inLog[questID] then
        open = open + 1
        tip[#tip + 1] = "|cffff6060" .. (q.title or questID) .. "|r"
      end
    end
  end
  if done == 0 and open == 0 then return { state = "na", text = "-" } end
  local state = (open == 0 and "done") or (done > 0 and "progress") or "open"
  return { state = state, cur = done, max = done + open, text = string.format("%d/%d", done, done + open), tip = tip }
end

RR:RegisterItem({
  key = "weeklyQuests", label = L.WEEKLY_QUESTS, resetType = "weekly", order = 40,
  check = function(ctx) return questSummary(ctx, "weekly") end,
})

RR:RegisterItem({
  key = "dailyQuests", label = L.DAILY_QUESTS, resetType = "daily", order = 50,
  check = function(ctx) return questSummary(ctx, "daily") end,
})

RR:RegisterItem({
  key = "pinnedQuests", label = L.PINNED_QUESTS, resetType = "weekly", order = 55,
  check = function(ctx)
    if #RR.Data.pinnedQuests == 0 then return false end
    local sub = {}
    for _, q in ipairs(RR.Data.pinnedQuests) do
      local done = RR.Call("C_QuestLog.IsQuestFlaggedCompleted", q.questID)
      local onQuest = RR.Call("C_QuestLog.IsOnQuest", q.questID)
      sub["q" .. q.questID] = {
        label = q.label or ("Quest " .. q.questID), resetType = q.resetType or "weekly",
        state = done and "done" or (onQuest and "progress" or "open"),
        text = done and L.DONE or (onQuest and L.IN_PROGRESS or L.OPEN),
        expires = RR:GetNextReset(q.resetType or "weekly"),
      }
    end
    return { sub = sub }
  end,
})

-- ---------- 6. World bosses ----------

RR:RegisterItem({
  key = "worldBoss", label = L.WORLD_BOSS, resetType = "weekly", order = 60,
  check = function(ctx)
    if not ctx.char.lockoutsScanned then return nil end
    local bosses = ctx.char.worldBosses or {}
    local tip = {}
    for _, b in ipairs(bosses) do tip[#tip + 1] = b.name end
    return {
      state = #bosses > 0 and "done" or "open", cur = #bosses,
      text = #bosses > 0 and string.format(L.KILLED_N, #bosses) or L.OPEN, tip = tip,
    }
  end,
})

-- ---------- 7. Professions ----------
-- Skill levels come from GetProfessions(). Concentration can only be read while the profession window is open, so it
-- is stored with a timestamp at TRADE_SKILL_LIST_UPDATE (see Professions handler below). Weekly profession quests are
-- picked up by the weekly quest scanner above.

local function recordConcentration(char)
  local child = RR.Call("C_TradeSkillUI.GetChildProfessionInfo")
  if not child or not child.professionID or child.professionID == 0 then return end
  local currencyID = RR.Call("C_TradeSkillUI.GetConcentrationCurrencyID", child.professionID)
  if not currencyID or currencyID == 0 then return end
  local info = RR.Call("C_CurrencyInfo.GetCurrencyInfo", currencyID)
  if not info or RR.IsSecret(info.quantity) then return end
  local parentName = child.parentProfessionName or child.professionName
  if not parentName then return end
  char.professions[parentName] = char.professions[parentName] or {}
  local p = char.professions[parentName]
  p.concentration, p.concentrationMax, p.concentrationAt = info.quantity, info.maxQuantity, RR.Now()
end

RR:RegisterItem({
  key = "professions", label = L.PROFESSIONS, resetType = nil, order = 70, noSummary = true,
  check = function(ctx)
    if not GetProfessions then return nil end
    local char = ctx.char
    recordConcentration(char)
    local sub = {}
    local p1, p2, _, _, cooking = GetProfessions()
    for _, index in ipairs({ p1 or 0, p2 or 0, cooking or 0 }) do
      if index > 0 then
        local name, _, rank, maxRank = GetProfessionInfo(index)
        if name then
          local stored = char.professions[name]
          local text = string.format("%d/%d", rank or 0, maxRank or 0)
          local tip = { string.format(L.PROF_SKILL, rank or 0, maxRank or 0) }
          if stored and stored.concentration then
            text = string.format(L.PROF_CONC_SHORT, stored.concentration, stored.concentrationMax or 0)
            tip[#tip + 1] = string.format(L.PROF_CONC_TIP, stored.concentration, stored.concentrationMax or 0,
              RR.FormatAgo(stored.concentrationAt))
          else
            tip[#tip + 1] = L.PROF_CONC_UNKNOWN
          end
          sub[name] = { label = name, state = "info", text = text, tip = tip, noExpire = true, noSummary = true }
        end
      end
    end
    if not next(sub) then return false end
    return { sub = sub }
  end,
})

-- ---------- 8. Currencies with a weekly cap ----------

local function currencyIDs()
  local ids, seen = {}, {}
  local size = RR.Call("C_CurrencyInfo.GetCurrencyListSize") or 0
  for i = 1, size do
    local info = RR.Call("C_CurrencyInfo.GetCurrencyListInfo", i)
    if info and not info.isHeader then
      local link = RR.Call("C_CurrencyInfo.GetCurrencyListLink", i)
      local id = link and RR.Call("C_CurrencyInfo.GetCurrencyIDFromLink", link)
      if id and not seen[id] then seen[id] = true ids[#ids + 1] = id end
    end
  end
  for _, c in ipairs(RR.Data.extraCurrencies) do
    if not seen[c.currencyID] then seen[c.currencyID] = true ids[#ids + 1] = c.currencyID end
  end
  return ids
end

RR:RegisterItem({
  key = "currencies", label = L.CURRENCIES, resetType = "weekly", order = 80,
  check = function(ctx)
    if not C_CurrencyInfo then return nil end
    local sub = {}
    for _, id in ipairs(currencyIDs()) do
      local info = RR.Call("C_CurrencyInfo.GetCurrencyInfo", id)
      if info and info.name and not RR.IsSecret(info.quantity) then
        if (info.maxWeeklyQuantity or 0) > 0 then
          local earned = info.quantityEarnedThisWeek or 0
          sub["c" .. id] = {
            label = info.name, cur = earned, max = info.maxWeeklyQuantity,
            state = stateFromProgress(earned, info.maxWeeklyQuantity),
            text = string.format("%d/%d", earned, info.maxWeeklyQuantity),
          }
        elseif info.useTotalEarnedForMaxQty and (info.maxQuantity or 0) > 0 then
          -- seasonal cap that grows every week: shown, but never reset by us
          local earned = info.totalEarned or 0
          sub["c" .. id] = {
            label = info.name, cur = earned, max = info.maxQuantity, noExpire = true,
            state = earned >= info.maxQuantity and "done" or "progress",
            text = string.format("%d/%d", earned, info.maxQuantity), tip = { L.SEASON_CAP_TIP },
          }
        end
      end
    end
    return { sub = sub }
  end,
})

-- ---------- 9. Renown / major factions (weekly progress) ----------

RR:RegisterItem({
  key = "renown", label = L.RENOWN, resetType = nil, order = 90, noSummary = true,
  check = function(ctx)
    if not C_MajorFactions or not C_MajorFactions.GetMajorFactionIDs then return nil end
    local char = ctx.char
    local ids = RR.Call("C_MajorFactions.GetMajorFactionIDs", LE_EXPANSION_LEVEL_CURRENT) or {}
    local week = RR:GetNextReset("weekly") or 0
    local sub = {}
    for _, id in ipairs(ids) do
      local data = RR.Call("C_MajorFactions.GetMajorFactionData", id)
      if data and data.name and data.isUnlocked ~= false then
        local level, earned = data.renownLevel or 0, data.renownReputationEarned or 0
        local start = char.renownStart[id]
        if not start or start.week ~= week then
          start = { week = week, level = level, earned = earned }
          char.renownStart[id] = start
        end
        local tip = { string.format(L.RENOWN_TIP, level, earned, data.renownLevelThreshold or 0) }
        local gained = level - start.level
        local text = string.format(L.RENOWN_SHORT, level)
        if gained > 0 then
          text = text .. string.format(" (+%d)", gained)
        elseif earned > start.earned then
          tip[#tip + 1] = string.format(L.RENOWN_WEEK_TIP, earned - start.earned)
        end
        sub["f" .. id] = { label = data.name, state = "info", text = text, tip = tip, noExpire = true, noSummary = true }
      end
    end
    if not next(sub) then return false end
    return { sub = sub }
  end,
})
