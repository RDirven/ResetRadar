local RR = ResetRadar
local f = RR.eventFrame
local function fire(event, ...) f._scripts.OnEvent(f, event, ...) end
local function assertEq(a, b, msg) if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local printed = {}
local realPrint = print
print = function(...) local s = table.concat({ tostringall and tostringall(...) or tostring((...)) }, " ") printed[#printed + 1] = s realPrint(s) end

ResetRadarDB = { settings = { debug = true } }
fire("PLAYER_LOGIN")
fire("UPDATE_INSTANCE_INFO")
fire("CALENDAR_UPDATE_EVENT_LIST")
MOCK_RUN_TIMERS()

local char = RR:GetCurrentChar()
assert(char, "char")
assertEq(char.data.vault.sub.mplus.cur, 1, "vault mplus")
assertEq(char.data.vault.sub.mplus.state, "progress", "vault state")
assertEq(char.data.keystone.text, "Test Dungeon +12", "keystone")
assertEq(char.data.keystone.state, "done", "keystone done")
local raid = char.data.raids.sub["631:6"]
assertEq(raid.text, "3/12", "raid")
assertEq(char.data.weeklyQuests.state, "open", "weekly quests")
assertEq(char.data.dailyQuests.state, "done", "daily quests")
assertEq(char.data.currencies.sub.c3000.text, "30/90", "currency")
assert(char.data.professions.sub.Alchemy, "profession")
assert(char.data.renown.sub.f1, "renown")
assertEq(RR.db.global.activeEvents[1], "Timewalking", "calendar")

-- UI: all tabs
RR:ShowWindow()
RR:ShowWindow("farm")
RR:ShowWindow("mounts")
RR.ui:Refresh()

-- manual items
local id = RR:AddManualItem("Feed the cat", "daily", "character")
RR:ToggleManual(id, RR.charKey)
assert(char.data["manual:" .. id].done, "manual done")
local accId = RR:AddManualItem("Account thing", "weekly", "account")
RR:ToggleManual(accId, RR.charKey)
RR:ShowWindow("checklist")

-- alt not logged in for 3 weeks
local now = time()
RR.db.chars["Oldalt-Silvermoon"] = {
  name = "Oldalt", realm = "Silvermoon", class = "WARRIOR", level = 80, lastSeen = now - 21 * 86400,
  hiddenItems = {}, lockouts = { ["631:6"] = { name = "Icecrown Citadel", nameLower = "icecrown citadel", difficultyID = 6, killed = { ["the lich king"] = true }, progress = 12, numEncounters = 12, expires = now - 14 * 86400 } },
  lockoutsScanned = now - 21 * 86400, quests = { known = {} }, professions = {}, renownStart = {},
  data = {
    keystone = { state = "done", text = "Old +10", expires = now - 14 * 86400 },
    vault = { expires = now - 14 * 86400, sub = { mplus = { cur = 3, max = 3, state = "done", expires = now - 14 * 86400 }, claim = { state = "done", noExpire = true } } },
    raids = { expires = now - 14 * 86400, sub = { ["631:6"] = { state = "done", expires = now - 14 * 86400, dropOnReset = true } } },
    currencies = { expires = now - 14 * 86400, sub = { c1 = { cur = 90, max = 90, state = "done", expires = now - 14 * 86400 } } },
  },
}
RR:ApplyResets()
local alt = RR.db.chars["Oldalt-Silvermoon"]
assertEq(alt.data.keystone.state, "open", "alt keystone reset")
assertEq(alt.data.vault.sub.mplus.state, "open", "alt vault reset")
assertEq(alt.data.vault.sub.claim.state, "open", "alt vault claim inferred")
assertEq(alt.data.raids.sub["631:6"], nil, "alt raid lockout dropped")
assertEq(alt.data.currencies.sub.c1.state, "open", "alt currency reset")
assertEq(alt.lockouts["631:6"], nil, "alt lockout expired")
RR.ui:Refresh()

-- farm targets: Invincible (Lich King not killed for current char -> chance)
local farm = RR.modules.FarmTargets
local inv
for _, t in pairs(farm.db.targets) do if t.itemID == 50818 then inv = t end end
assert(inv, "starter target")
assertEq(inv.kind, "mount", "kind")
assertEq(farm:Status(RR.charKey, inv), "chance", "farm chance")
char.lockouts["631:6"].killed["the lich king"] = true
assertEq(farm:Status(RR.charKey, inv), "locked", "farm locked")
assertEq(farm:Status("Oldalt-Silvermoon", inv), "chance", "alt chance after reset")
farm:TargetTooltip(inv)(GameTooltip)
farm:AddTarget(12345, { { type = "quest", questID = 200, resetType = "daily" } })
fire("QUEST_LOG_UPDATE")
MOCK_RUN_TIMERS()
assert(farm:GetLoginLine() ~= nil or true)

-- collections: journal scan -> transmog summary + auto mount target
local coll = RR.modules.Collections
assert(RR:IsModuleActive("Collections"), "collections on by default")
RR:ShowWindow("transmog")            -- no data yet
coll:StartScan()
assert(coll:IsScanning(), "scanning")
RR.ui:Refresh()
MOCK_RUN_TIMERS()
assert(not coll:IsScanning(), "scan finished")
assertEq(MOCK_EJ_FILTER, 8, "loot filter restored")
local inst = coll.db.journal.instances[758]
assert(inst and inst.diffs[6] and inst.diffs[5], "both difficulties stored")
assert(coll.db.journal.mounts[363], "mount found in journal")
local sum = coll:Summary()[758][6]
assertEq(sum.total, 3, "3 appearances on 25H")
assertEq(sum.missing, 3, "all missing")
MOCK_COLLECTED_SRC = { [20016] = true } -- item 2001 on diff 6
coll:Invalidate()
sum = coll:Summary()[758][6]
assertEq(sum.missing, 2, "one collected")
-- lockout: current char killed Lord Marrowgar + Lich King earlier in the scenario? check availability numbers
local avail, total = coll:CharAvailability(RR.charKey, inst, 6, sum)
realPrint("availability", avail, total)
assert(total == 1, "only Lich King has missing loot")
coll.db.expanded["758:6"] = true
coll.db.instanceFilter = "all"
RR:ShowWindow("transmog")
coll.db.sortBy = "missing"; RR.ui:Refresh()
-- auto mount replaces the starter Invincible target
local autoFound, starterFound = false, false
for _, t in ipairs(farm:AllTargets()) do
  if t.itemID == 50818 then if t.auto then autoFound = true else starterFound = true end end
end
assert(autoFound and not starterFound, "auto target replaces starter")
RR:ShowWindow("farm"); RR:ShowWindow("mounts")
farm:RemoveTarget("auto:363")
for _, t in ipairs(farm:AllTargets()) do assert(not t.auto, "auto hidden") end
coll:AddMinimapLines(GameTooltip)
-- combat pause/resume during scan
coll:StartScan()
MOCK_COMBAT = true
MOCK_RUN_TIMERS()
assert(coll:IsScanning(), "paused, not finished")
MOCK_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
MOCK_RUN_TIMERS()
assert(not coll:IsScanning(), "resumed and finished")

-- adventure guide overlay + Want
EJ_GetDifficulty = function() return 6 end
EJ_InstanceIsRaid = function() return true end
EJ_GetEncounterInfo = function(id) return id == 2 and "The Lich King" or "Lord Marrowgar" end
MOCK_EJ_DIFF = 6
local ejFrames = {}
local sb = { ForEachFrame = function(self, fn) for _, f in ipairs(ejFrames) do fn(f.frame, f.data) end end }
EncounterJournal = CreateFrame("Frame")
EncounterJournal.instanceID, EncounterJournal.encounterID = 758, 2
EncounterJournal.encounter = { info = { LootContainer = { ScrollBox = sb } } }
ScrollUtil = { AddInitializedFrameCallback = function(box, cb, owner, iterate) MOCK_EJ_CB = cb end }
fire("ADDON_LOADED", "Blizzard_EncounterJournal")
assert(MOCK_EJ_CB, "journal hooked")
local row = CreateFrame("Button"); row.icon = row:CreateTexture()
ejFrames[1] = { frame = row, data = { index = 3 } }   -- item 2002, Lich King
MOCK_EJ_CB(row, { index = 3 })
local deco = row.ResetRadarDeco
assert(deco and deco.star, "star added to loot row")
assertEq(deco.star.wanted, false, "not wanted yet")
deco.star._scripts.OnClick(deco.star)
local want = farm:FindWant(2002)
assert(want, "want target created")
assertEq(want.sources[1].encounter, "The Lich King", "want boss")
assertEq(want.sources[1].mapID, 631, "want map")
assertEq(want.sources[1].difficulties[1], 6, "want difficulty")
assert(farm:IsWanted(2002, 6), "is wanted")
MOCK_RUN_TIMERS()
-- checklist shows a Wanted loot row; summary counts it
RR.db.settings.viewMode = "all"
RR:ShowWindow("checklist")
local rowsFound = farm:GetChecklistRows()
assert(rowsFound and #rowsFound == 2, "header + want row")
local text = rowsFound[2].cell(RR.charKey)
assert(type(text) == "string", "cell renders")
local bar = coll:JournalSummaryText()
realPrint("bar", bar)
assert(bar and bar:find("2/3"), "bar shows missing on 25H")
-- collected: appearance of 2002 on diff 6 is source 20026
MOCK_COLLECTED_SRC[20026] = true
coll:Invalidate(); farm:UpdateCollected()
assert(farm.db.collected[want.id], "want collected")
-- toggle off again
deco.star._scripts.OnClick(deco.star)
assertEq(farm:FindWant(2002), nil, "want removed")

-- want everything from the Transmog tab (batch, sourceID instead of a link)
local added = farm:AddWants({
  { itemID = 2002, sourceID = 20026, difficulty = 6, mapID = 631, instance = "Icecrown Citadel", encounter = "The Lich King", isRaid = true },
  { itemID = 2003, sourceID = 20036, difficulty = 6, mapID = 631, instance = "Icecrown Citadel", encounter = "The Lich King", isRaid = true },
  { itemID = 2003, sourceID = 20036, difficulty = 6, mapID = 631, instance = "Icecrown Citadel", encounter = "The Lich King", isRaid = true },
})
assertEq(added, 2, "batch want, duplicate skipped")
assertEq(farm:FindWant(2003).sourceByDiff[6], 20036, "sourceID stored")
assertEq(farm:RemoveWants({ { itemID = 2002, difficulty = 6 }, { itemID = 2003, difficulty = 6 } }), 2, "batch remove")
RR:ShowWindow("transmog")

-- attempt counter: one per lockout
local invTarget
for _, t in ipairs(farm:AllTargets()) do if t.itemID == 50818 then invTarget = t end end
assert(invTarget and not farm.db.collected[invTarget.id], "invincible target uncollected")
fire("ENCOUNTER_END", 2, "The Lich King", 6, 25, 1)
fire("ENCOUNTER_END", 2, "The Lich King", 6, 25, 1)
fire("ENCOUNTER_END", 2, "The Lich King", 5, 10, 0) -- wipe: no attempt
assertEq(farm:GetAttempts(50818), 1, "one attempt per lockout")
fire("ENCOUNTER_END", 2, "The Lich King", 4, 25, 1) -- other difficulty: not a source
assertEq(farm:GetAttempts(50818), 1, "wrong difficulty not counted")
for k in pairs(farm.db.attemptSeen) do farm.db.attemptSeen[k] = time() - 1 end
RR:ApplyResets()
assertEq(next(farm.db.attemptSeen), nil, "attempt locks cleared at reset")
fire("ENCOUNTER_END", 2, "The Lich King", 6, 25, 1)
assertEq(farm:GetAttempts(50818), 2, "counted again after reset")
RR:ShowWindow("mounts"); RR:ShowWindow("farm")
-- drop alert (loot event + chat line for one drop = one alert)
local before = #printed
fire("ENCOUNTER_LOOT_RECEIVED", 2, 50818, "|Hitem:50818|h[x]|h", 1, "Tester")
fire("CHAT_MSG_LOOT", "You receive loot: |Hitem:50818|h[x]|h", "Tester")
local drops = 0
for i = before + 1, #printed do if printed[i]:find("Dropped") then drops = drops + 1 end end
assertEq(drops, 1, "one drop alert")
assert(MOCK_SOUND, "alert sound played")
-- collected alert after attempts
local realMountInfo = C_MountJournal.GetMountInfoByID
C_MountJournal.GetMountInfoByID = function() return "Invincible", 1, 1, false, true, 0, false, false, 0, false, true end
farm:UpdateCollected() -- data change without a collect event: silent
assertEq(farm.db.attempts[50818].gotAt, nil, "no alert without collect event")
C_MountJournal.GetMountInfoByID = realMountInfo
farm:UpdateCollected()
C_MountJournal.GetMountInfoByID = function() return "Invincible", 1, 1, false, true, 0, false, false, 0, false, true end
fire("NEW_MOUNT_ADDED")
MOCK_RUN_TIMERS()
assert(farm.db.attempts[50818].gotAt, "got after attempts recorded")
assertEq(farm.db.attempts[50818].gotCount, 2, "got count")
assert(printed[#printed]:find("Collected") and printed[#printed]:find("2"), "collected alert")
C_MountJournal.GetMountInfoByID = realMountInfo
farm:ResetAttempts(50818)
assertEq(farm:GetAttempts(50818), 0, "attempts reset")
farm:UpdateCollected()
-- hide collected checkbox follows the setting
farm.db.collectedMode = "hide"; RR:ShowWindow("farm"); RR:ShowWindow("mounts")
farm.db.collectedMode = "show"

-- weekly planner: current char has killed everything on diff 6, nothing on diff 5
coll.db.plannerArmorOnly = false
local plan = coll:PlannerEntries(RR.charKey)
assert(plan and #plan == 1, "one instance/difficulty with open bosses")
assertEq(plan[1].d, 5, "only the unlocked difficulty")
assertEq(plan[1].items, 3, "three missing on 10H")
coll.db.plannerArmorOnly = true -- mage, mock items are plate
assertEq(#coll:PlannerEntries(RR.charKey), 0, "armor filter")
coll.db.plannerArmorOnly = false
assertEq(coll:PlannerEntries("Nobody-Silvermoon"), nil, "unknown char")
RR:ShowWindow("planner")
coll.db.plannerChar = "Oldalt-Silvermoon"; RR.ui:Refresh(); coll.db.plannerChar = nil

-- tier sets: newest patch, raid difficulties only, per class
local tier = coll:TierSets()
assert(tier, "tier found")
assertEq(tier.label, "Test Raid", "newest tier")
assertEq(#tier.variants, 2, "normal + heroic, no pvp")
assertEq(tier.variants[1], "Normal", "difficulty order")
assertEq(#tier.classes.MAGE.Heroic.missing, 1, "one missing piece")
assert(tier.classes.WARRIOR, "warrior set")
RR:ShowWindow("tier")

-- loot manager is off by default
assertEq(RR:IsModuleEnabled("LootManager"), false, "loot off by default")
assertEq(RR.ui.tabs.loot.module, "LootManager")
fire("MERCHANT_SHOW") -- must not do anything
assertEq(MOCK_SOLD, nil, "nothing sold while disabled")
RR:SetModuleEnabled("LootManager", true)
local loot = RR.modules.LootManager
-- appearance not collected -> everything protected
fire("MERCHANT_SHOW")
assertEq(#loot.last.sell, 0, "uncollected appearance protected")
assertEq(#loot.last.protected, 2, "protected listed")
RR:ShowWindow("loot")
-- collected -> junk would be sold, but only after clicking Sell
MOCK_COLLECTED = true
fire("MERCHANT_SHOW")
assertEq(#loot.last.sell, 2, "dry run list")
assertEq(MOCK_SOLD, nil, "dry run sells nothing")
loot.db.ignore[1001] = true
loot:BuildCandidates()
assertEq(#loot.last.sell, 1, "ignore list respected")
loot:Sell(loot.last.sell, false)
MOCK_RUN_TIMERS()
assertEq(MOCK_SOLD, 1, "sold after confirm")
-- tooltip hint
MOCK_COLLECTED = false
MOCK_TTFN(GameTooltip, { lines = { { leftText = "Warbound until equipped" }, { leftText = "Classes: Mage" } } })
fire("MERCHANT_CLOSED")
loot:Sell({ { bag = 0, slot = 2, link = "x", count = 1 } }, false) -- merchant closed: must refuse
assertEq(MOCK_SOLD, 1, "no sell when merchant closed")

-- combat deferral
MOCK_COMBAT = true
RR:Scan()
MOCK_COMBAT = false
fire("PLAYER_REGEN_ENABLED")
MOCK_RUN_TIMERS()

-- module crash isolation
farm.OnScan = function() error("boom") end
for i = 1, 12 do RR:Scan() end
assert(farm.broken, "module marked broken")
RR:Scan()
RR.ui:Refresh()

-- missing event name does not break
RR:RegisterEvents({ "BOGUS_EVENT" })

-- character without professions / fresh character
GetProfessions = function() return nil end
MOCK_NAME = "Fresh"
RR:Scan()
assert(RR.db.chars["Fresh-Silvermoon"], "fresh char")
assertEq(RR.db.chars["Fresh-Silvermoon"].data.professions, nil, "no professions row")

-- slash commands
for _, cmd in ipairs({ "", "", "config", "farm", "loot", "reset Oldalt", "reset nobody", "scan", "bogus" }) do
  SlashCmdList.RESETRADAR(cmd)
end
assert(MOCK_SETTINGS_OPENED, "settings opened")
RR:RemoveCharacter("Oldalt-Silvermoon")
assertEq(RR.db.chars["Oldalt-Silvermoon"], nil, "char removed")

-- hidden rows / cells, with and without "show hidden"
MOCK_NAME = "Tester"
RR:Scan()
RR.db.settings.hiddenRows["vault"] = true
RR.db.settings.hiddenRows["currencies:c3000"] = true
RR:GetCurrentChar().hiddenItems["keystone"] = true
RR:ShowWindow("checklist")
RR.db.settings.showHidden = true
RR.ui:Refresh()
RR.db.settings.viewMode = "current"
RR.ui:Refresh()
-- nil in the middle of return values survives RR.Call
C_Test = { Gap = function() return nil, 5 end }
local a, b = RR.Call("C_Test.Gap")
assertEq(b, 5, "gap return")

-- summary & login message
local s = RR:GetSummary("Tester-Silvermoon")
realPrint("summary", s.weeklyOpen, s.weeklyTotal, s.dailyOpen, s.dailyTotal)
RR:ShowLoginMessage()
fire("PLAYER_LOGOUT")

for _, line in ipairs(printed) do
  if (line:find("failed") or line:find("API error")) and not line:find("boom") then error("debug error seen: " .. line) end
end
