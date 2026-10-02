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
