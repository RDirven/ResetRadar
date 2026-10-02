-- ResetRadar module: Loot Manager. OFF by default; can only be switched on after a warning popup.
--
-- What it does:
--  * At a merchant (MERCHANT_SHOW) it builds a dry-run list of items that match the enabled rules and shows it.
--    Nothing is sold until you press "Sell" (or you explicitly enabled "sell without confirmation").
--  * Rules: grey junk; soulbound gear whose appearance is already collected and below an item level;
--    warbound gear (separate switch, off by default).
--  * Never sells: equipped items (only bags 0-4 are scanned), equipment-set items, item-set (tier) pieces unless
--    allowed and older than the current expansion, ignored items, items whose appearance is not collected yet or
--    cannot be determined, quest items, items without a sell price, and high-value items without extra confirmation.
--  * Shows which characters still miss a warbound/BoE item's appearance and how it could be transferred.
--    It never sends mail or moves items itself.

local _, ns = ...
local RR, L = ns.RR, ns.L

local M = {
  title = L.LOOT_TITLE,
  description = L.LOOT_DESC,
  defaultEnabled = false,
  requiresConfirmation = true,
  events = { "MERCHANT_SHOW", "MERCHANT_CLOSED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_DISABLED" },
  defaults = {
    rules = { junk = true, bopCollected = false, warbound = false },
    ilvlThreshold = 0,       -- 0 = automatic: equipped average item level minus 15
    autoSell = false,
    highValueGold = 100,
    maxItems = 12,           -- the buyback tab holds 12 items; keep everything recoverable by default
    allowOldSetItems = false,
    openOnMerchant = true,
    tooltipHints = true,
    ignore = {},             -- itemID -> true
  },
}

local SELL_DELAY = 0.25
local ARMOR_FOR_CLASS = {
  WARRIOR = 4, PALADIN = 4, DEATHKNIGHT = 4,
  HUNTER = 3, SHAMAN = 3, EVOKER = 3,
  ROGUE = 2, DRUID = 2, MONK = 2, DEMONHUNTER = 2,
  MAGE = 1, PRIEST = 1, WARLOCK = 1,
}
local ITEMCLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local ITEMCLASS_ARMOR = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local ITEMCLASS_QUEST = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local merchantOpen = false
local selling = false

-- ---------- binding and class restrictions from tooltip lines ----------

local function stringSet(...)
  local set = {}
  for i = 1, select("#", ...) do
    local s = select(i, ...)
    if type(s) == "string" then set[s] = true end
  end
  return set
end

local BIND_WUE = stringSet(_G.ITEM_ACCOUNTBOUND_UNTIL_EQUIP, _G.ITEM_BIND_TO_ACCOUNT_UNTIL_EQUIP)
local BIND_WARBOUND = stringSet(_G.ITEM_ACCOUNTBOUND, _G.ITEM_BNETACCOUNTBOUND, _G.ITEM_BIND_TO_ACCOUNT,
  _G.ITEM_BIND_TO_BNETACCOUNT)
local BIND_SOULBOUND = stringSet(_G.ITEM_SOULBOUND, _G.ITEM_BIND_ON_PICKUP)
local BIND_BOE = stringSet(_G.ITEM_BIND_ON_EQUIP, _G.ITEM_BIND_ON_USE)

local classesPattern
if type(_G.ITEM_CLASSES_ALLOWED) == "string" then
  local escaped = _G.ITEM_CLASSES_ALLOWED:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  classesPattern = "^" .. escaped:gsub("%%%%s", "(.+)") .. "$"
end

local classByName
local function classFileFromName(name)
  if not classByName then
    classByName = {}
    for _, tbl in ipairs({ _G.LOCALIZED_CLASS_NAMES_MALE or {}, _G.LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
      for file, localized in pairs(tbl) do classByName[localized] = file end
    end
  end
  return classByName[strtrim(name)]
end

-- Returns binding ("wue"|"warbound"|"soulbound"|"boe"|nil) and a set of allowed class files (or nil).
local function parseLines(lines)
  local binding, classes
  for _, line in ipairs(lines or {}) do
    local text = line.leftText
    if type(text) == "string" and not RR.IsSecret(text) then
      if not binding then
        if BIND_WUE[text] then binding = "wue"
        elseif BIND_WARBOUND[text] then binding = "warbound"
        elseif BIND_SOULBOUND[text] then binding = "soulbound"
        elseif BIND_BOE[text] then binding = "boe" end
      end
      if classesPattern and not classes then
        local list = text:match(classesPattern)
        if list then
          classes = {}
          for name in list:gmatch("[^,]+") do
            local file = classFileFromName(name)
            if file then classes[file] = true end
          end
        end
      end
    end
  end
  return binding, classes
end

-- ---------- appearance analysis ----------

-- Returns { hasAppearance, collected (true/false/nil), eligible = {charKeys}, eligibleUnknown, transfer }.
local function analyzeAppearance(link, classID, subclassID, equipLoc, binding, classes)
  local result = { eligible = {} }
  local appearanceID, sourceID = RR.Call("C_TransmogCollection.GetItemInfo", link)
  if not appearanceID or not sourceID then return result end
  result.hasAppearance = true
  local info = RR.Call("C_TransmogCollection.GetAppearanceInfoBySource", sourceID)
  if info then
    result.collected = info.appearanceIsCollected and true or false
  end
  if result.collected ~= false then return result end

  -- Which characters could use (and so learn) this appearance?
  local check
  if classes then
    check = function(char) return classes[char.class] end
  elseif classID == ITEMCLASS_ARMOR and subclassID and subclassID >= 1 and subclassID <= 4 and equipLoc ~= "INVTYPE_CLOAK" then
    check = function(char) return ARMOR_FOR_CLASS[char.class] == subclassID end
  elseif classID == ITEMCLASS_ARMOR then
    check = function() return true end -- cloaks, shirts, tabards: every class
  else
    result.eligibleUnknown = true      -- weapons: proficiency per class is not checked
  end
  if check then
    for key, char in pairs(RR.db.chars) do
      if char.class and check(char) then result.eligible[#result.eligible + 1] = key end
    end
    table.sort(result.eligible)
  end
  if binding == "wue" or binding == "warbound" then
    result.transfer = "warbank"
  elseif binding == "boe" then
    result.transfer = "mail"
  elseif binding == "soulbound" then
    result.transfer = "none"
  else
    result.transfer = "unknown"
  end
  return result
end

local function transferText(a, firstName)
  if a.transfer == "warbank" then return string.format(L.LOOT_TRANSFER_WARBANK, firstName) end
  if a.transfer == "mail" then return string.format(L.LOOT_TRANSFER_MAIL, firstName) end
  if a.transfer == "none" then return L.LOOT_TRANSFER_NONE end
  return L.LOOT_TRANSFER_UNKNOWN
end

-- ---------- scanning bags ----------

local function equipmentSetItems()
  local ids = {}
  for _, setID in ipairs(RR.Call("C_EquipmentSet.GetEquipmentSetIDs") or {}) do
    for _, itemID in pairs(RR.Call("C_EquipmentSet.GetItemIDs", setID) or {}) do
      if type(itemID) == "number" and itemID > 0 then ids[itemID] = true end
    end
  end
  return ids
end

local function inEquipmentSet(bag, slot, itemID, setIDs)
  if C_Container.GetContainerItemEquipmentSetInfo then
    local ok, isInSet = pcall(C_Container.GetContainerItemEquipmentSetInfo, bag, slot)
    if ok and isInSet then return true end
  end
  return setIDs[itemID] and true or false
end

function M:IlvlThreshold()
  if (self.db.ilvlThreshold or 0) > 0 then return self.db.ilvlThreshold end
  local _, equipped = GetAverageItemLevel()
  return math.max(1, math.floor((equipped or 0) - 15))
end

-- Builds { sell = {...}, protected = {...}, deferred = n, uncached = n }. Pure read; never sells.
function M:BuildCandidates()
  local db = self.db
  local out = { sell = {}, protected = {}, deferred = 0, uncached = 0, total = 0 }
  if not C_Container or not C_Container.GetContainerNumSlots then return out end
  local threshold = self:IlvlThreshold()
  local highValue = (db.highValueGold or 0) * 10000
  local setIDs = equipmentSetItems()
  local currentExpansion = LE_EXPANSION_LEVEL_CURRENT or (GetExpansionLevel and GetExpansionLevel()) or 99
  local lastBag = NUM_BAG_SLOTS or 4

  for bag = 0, lastBag do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and info.hyperlink and not info.isLocked then
        local link = info.hyperlink
        local name, _, quality, _, _, _, _, _, equipLoc, icon, sellPrice, classID, subclassID, _, expansionID, setID =
          C_Item.GetItemInfo(link)
        if not name then
          out.uncached = out.uncached + 1
        elseif not info.hasNoValue and (sellPrice or 0) > 0 and classID ~= ITEMCLASS_QUEST then
          local item = {
            bag = bag, slot = slot, itemID = info.itemID, link = link, icon = icon or info.iconFileID,
            count = info.stackCount or 1, quality = quality, value = (sellPrice or 0) * (info.stackCount or 1),
          }
          local isGear = (classID == ITEMCLASS_ARMOR or classID == ITEMCLASS_WEAPON) and equipLoc and equipLoc ~= ""
          local tip = RR.Call("C_TooltipInfo.GetBagItem", bag, slot)
          local binding, classes = parseLines(tip and tip.lines)
          local appearance = analyzeAppearance(link, classID, subclassID, equipLoc, binding, classes)
          item.appearance, item.binding = appearance, binding

          local rule
          if quality == 0 and db.rules.junk then
            rule = "junk"
          elseif isGear and quality and quality <= 4 then
            local ilvl = C_Item.GetCurrentItemLevel(ItemLocation:CreateFromBagAndSlot(bag, slot)) or 0
            item.ilvl = ilvl
            if ilvl < threshold and appearance.collected == true then
              if binding == "soulbound" and db.rules.bopCollected then rule = "bop" end
              if (binding == "warbound" or binding == "wue") and db.rules.warbound then rule = "warbound" end
            end
          end

          -- safety checks, in order; the first one that applies protects the item
          local protect
          if db.ignore[info.itemID] then
            protect = L.LOOT_REASON_IGNORED
          elseif inEquipmentSet(bag, slot, info.itemID, setIDs) then
            protect = L.LOOT_REASON_EQSET
          elseif setID and setID > 0 and not (db.allowOldSetItems and expansionID and expansionID < currentExpansion) then
            protect = L.LOOT_REASON_TIER
          elseif appearance.hasAppearance and appearance.collected ~= true then
            protect = appearance.collected == false and L.LOOT_REASON_MISSING or L.LOOT_REASON_UNKNOWN_APPEARANCE
          end

          if protect then
            if rule or (appearance.collected == false and isGear) then
              item.reason = protect
              out.protected[#out.protected + 1] = item
            end
          elseif rule then
            item.rule = rule
            item.highValue = highValue > 0 and item.value >= highValue
            out.sell[#out.sell + 1] = item
          end
        end
      end
    end
  end

  table.sort(out.sell, function(a, b)
    if (a.rule == "junk") ~= (b.rule == "junk") then return a.rule == "junk" end
    return a.value < b.value
  end)
  local max = math.max(1, db.maxItems or 12)
  while #out.sell > max do
    table.remove(out.sell)
    out.deferred = out.deferred + 1
  end
  for _, item in ipairs(out.sell) do out.total = out.total + item.value end
  self.last = out
  return out
end

-- ---------- selling ----------

local function merchantReady()
  return merchantOpen and MerchantFrame and MerchantFrame:IsShown() and not InCombatLockdown()
end

function M:Sell(list, includeHighValue)
  if selling then return end
  if not merchantReady() then RR.Print(L.LOOT_NO_MERCHANT) return end
  local queue = {}
  for _, item in ipairs(list) do
    if not item.highValue or includeHighValue then queue[#queue + 1] = item end
  end
  if #queue == 0 then return end
  selling = true
  local moneyBefore = GetMoney()
  local sold = {}

  local function finish()
    C_Timer.After(0.6, function()
      selling = false
      local gained = GetMoney() - moneyBefore
      if #sold > 0 then
        local links = {}
        for i = 1, math.min(8, #sold) do
          links[i] = sold[i].link .. (sold[i].count > 1 and ("x" .. sold[i].count) or "")
        end
        RR.Print(string.format(L.LOOT_SOLD, #sold, GetMoneyString and GetMoneyString(math.max(0, gained)) or gained,
          table.concat(links, " ") .. (#sold > 8 and " ..." or "")))
        RR.Print(L.LOOT_BUYBACK_HINT)
      end
      M:Rebuild()
    end)
  end

  local function step()
    if #queue == 0 or not merchantReady() then
      if #queue > 0 then RR.Print(L.LOOT_ABORTED) end
      finish()
      return
    end
    local item = table.remove(queue, 1)
    local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
    -- re-verify the slot right before selling: same item, same stack, not locked
    if info and info.hyperlink == item.link and (info.stackCount or 1) == item.count and not info.isLocked then
      C_Container.UseContainerItem(item.bag, item.slot)
      sold[#sold + 1] = item
    end
    C_Timer.After(SELL_DELAY, step)
  end
  step()
end

StaticPopupDialogs["RESETRADAR_SELL_HIGHVALUE"] = {
  text = L.LOOT_CONFIRM_HIGHVALUE,
  button1 = L.LOOT_SELL, button2 = CANCEL,
  OnAccept = function() if M.last then M:Sell(M.last.sell, true) end end,
  timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

StaticPopupDialogs["RESETRADAR_AUTOSELL"] = {
  text = L.LOOT_AUTOSELL_WARNING,
  button1 = L.LOOT_ENABLE_ACCEPT, button2 = CANCEL,
  OnAccept = function()
    M.db.autoSell = true
    if RR.settingsLayout then RR.settingsLayout:Refresh() end
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

-- ---------- module hooks ----------

function M:OnInitialize(db)
  self.db = db
end

function M:Rebuild()
  if InCombatLockdown() or selling then return end
  RR.SafeCall("loot candidates", M.BuildCandidates, M)
  RR:RefreshUI()
end

function M:OnEvent(event)
  if event == "MERCHANT_SHOW" then
    merchantOpen = true
    local out = self:BuildCandidates()
    if #out.sell == 0 then return end
    if self.db.autoSell then
      self:Sell(out.sell, false) -- high-value items are never sold without the extra confirmation
    elseif self.db.openOnMerchant then
      RR:ShowWindow("loot")
    end
  elseif event == "MERCHANT_CLOSED" then
    merchantOpen = false
    RR:RefreshUI()
  elseif event == "BAG_UPDATE_DELAYED" then
    if merchantOpen and not selling then self:Rebuild() end
  end
end

-- Tooltip hint: "Missing on: X, Y. Send to X instead of selling." TooltipDataProcessor post-calls do not taint.
local tooltipHooked = false
local function onTooltip(tooltip, data)
  if not M.active or M.broken or not M.db.tooltipHints or InCombatLockdown() then return end
  if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
  local _, link = tooltip:GetItem()
  if not link or RR.IsSecret(link) then return end
  local name, _, _, _, _, _, _, _, equipLoc, _, _, classID, subclassID = C_Item.GetItemInfo(link)
  if not name or (classID ~= ITEMCLASS_ARMOR and classID ~= ITEMCLASS_WEAPON) then return end
  local binding, classes = parseLines(data and data.lines)
  if binding ~= "wue" and binding ~= "warbound" and binding ~= "boe" then return end
  local a = analyzeAppearance(link, classID, subclassID, equipLoc, binding, classes)
  if a.collected ~= false then return end
  tooltip:AddLine(" ")
  if a.eligibleUnknown then
    tooltip:AddLine(L.LOOT_TIP_MISSING_WEAPON, 1, 0.82, 0, true)
  elseif #a.eligible > 0 then
    local names = {}
    for _, key in ipairs(a.eligible) do names[#names + 1] = RR:CharDisplayName(key) end
    tooltip:AddLine(string.format(L.LOOT_TIP_MISSING, table.concat(names, ", ")), 1, 0.82, 0, true)
    local first = RR.db.chars[a.eligible[1]]
    tooltip:AddLine(transferText(a, first and first.name or a.eligible[1]), 0.8, 0.8, 0.8, true)
  else
    tooltip:AddLine(L.LOOT_TIP_NO_ELIGIBLE, 0.8, 0.8, 0.8, true)
  end
end

function M:OnEnable()
  if not tooltipHooked and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    tooltipHooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      RR.SafeCall("loot tooltip", onTooltip, tooltip, data)
    end)
  end
end

function M:BuildSettings(layout)
  local db = self.db
  layout:AddHeader(L.LOOT_TITLE)
  layout:AddText(L.LOOT_SETTINGS_INTRO)
  layout:AddCheck(L.LOOT_RULE_JUNK, nil, function() return db.rules.junk end, function(v) db.rules.junk = v end)
  layout:AddCheck(L.LOOT_RULE_BOP, L.LOOT_RULE_BOP_TIP, function() return db.rules.bopCollected end,
    function(v) db.rules.bopCollected = v end)
  layout:AddCheck(L.LOOT_RULE_WARBOUND, L.LOOT_RULE_WARBOUND_TIP, function() return db.rules.warbound end,
    function(v) db.rules.warbound = v end)
  layout:AddNumber(L.LOOT_OPT_ILVL, L.LOOT_OPT_ILVL_TIP, function() return db.ilvlThreshold end,
    function(v) db.ilvlThreshold = math.max(0, math.floor(v)) end)
  layout:AddNumber(L.LOOT_OPT_HIGHVALUE, L.LOOT_OPT_HIGHVALUE_TIP, function() return db.highValueGold end,
    function(v) db.highValueGold = math.max(0, v) end)
  layout:AddNumber(L.LOOT_OPT_MAX, L.LOOT_OPT_MAX_TIP, function() return db.maxItems end,
    function(v) db.maxItems = math.min(50, math.max(1, math.floor(v))) end)
  layout:AddCheck(L.LOOT_OPT_OLDSETS, L.LOOT_OPT_OLDSETS_TIP, function() return db.allowOldSetItems end,
    function(v) db.allowOldSetItems = v end)
  layout:AddCheck(L.LOOT_OPT_OPEN, nil, function() return db.openOnMerchant end, function(v) db.openOnMerchant = v end)
  layout:AddCheck(L.LOOT_OPT_TOOLTIP, nil, function() return db.tooltipHints end, function(v) db.tooltipHints = v end)
  layout:AddCheck(L.LOOT_OPT_AUTOSELL, L.LOOT_OPT_AUTOSELL_TIP, function() return db.autoSell end, function(v)
    if v and not db.autoSell then
      StaticPopup_Show("RESETRADAR_AUTOSELL")
      return false
    end
    db.autoSell = v
  end)
end

-- ---------- UI tab ----------

local RULE_TEXT = { junk = L.LOOT_RULE_JUNK_SHORT, bop = L.LOOT_RULE_BOP_SHORT, warbound = L.LOOT_RULE_WARBOUND_SHORT }

local function money(copper)
  if GetMoneyString then return GetMoneyString(copper or 0, true) end
  return tostring(math.floor((copper or 0) / 10000)) .. "g"
end

local function buildLootTab(parent)
  local tab = {}
  local includeHigh = false

  local status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  status:SetPoint("TOPLEFT", 4, -6)
  status:SetPoint("RIGHT", -280, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  local sellBtn = RR.CreateButton(parent, L.LOOT_SELL, 90, function()
    local out = M.last
    if not out or #out.sell == 0 then return end
    local hasHigh = false
    for _, item in ipairs(out.sell) do if item.highValue then hasHigh = true end end
    if includeHigh and hasHigh then
      StaticPopup_Show("RESETRADAR_SELL_HIGHVALUE", money((M.db.highValueGold or 0) * 10000))
    else
      M:Sell(out.sell, false)
    end
  end)
  sellBtn:SetPoint("TOPRIGHT", -4, -2)
  local rescanBtn = RR.CreateButton(parent, L.LOOT_RESCAN, 70, function() M:Rebuild() end)
  rescanBtn:SetPoint("RIGHT", sellBtn, "LEFT", -4, 0)
  local highCheck = RR.CreateCheck(parent, L.LOOT_INCLUDE_HIGH, function(v) includeHigh = v end)
  highCheck:SetPoint("RIGHT", rescanBtn, "LEFT", -120, 0)

  local ignoreBox = RR.CreateEditBox(parent, 120)
  ignoreBox:SetPoint("TOPLEFT", 4, -30)
  RR.AcceptItemLinks(ignoreBox)
  local ignoreBtn = RR.CreateButton(parent, L.LOOT_IGNORE_ADD, 110, function()
    local text = ignoreBox:GetText() or ""
    local id = tonumber(text) or tonumber(text:match("item:(%d+)"))
    if id then
      M.db.ignore[id] = true
      ignoreBox:SetText("")
      M:Rebuild()
    end
  end)
  ignoreBtn:SetPoint("LEFT", ignoreBox, "RIGHT", 4, 0)
  local hint = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", ignoreBtn, "RIGHT", 8, 0)
  hint:SetPoint("RIGHT", -4, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText(L.LOOT_BUYBACK_HINT)

  local holder = CreateFrame("Frame", nil, parent)
  holder:SetPoint("TOPLEFT", 0, -56)
  holder:SetPoint("BOTTOMRIGHT")
  local grid = RR.CreateGrid(holder, 300)
  local columns = {
    { key = "value", label = L.LOOT_COL_VALUE },
    { key = "rule", label = L.LOOT_COL_RULE },
    { key = "info", label = L.LOOT_COL_INFO },
  }

  local function itemRow(item, protected)
    return {
      label = item.link .. (item.count > 1 and (" x" .. item.count) or ""), icon = item.icon,
      tooltip = function(tt) tt:SetBagItem(item.bag, item.slot) end,
      onRightClick = function(owner)
        RR.ShowMenu(owner, {
          { text = item.link, isTitle = true },
          { text = M.db.ignore[item.itemID] and L.LOOT_UNIGNORE or L.LOOT_IGNORE, func = function()
            M.db.ignore[item.itemID] = not M.db.ignore[item.itemID] or nil
            M:Rebuild()
          end },
        })
      end,
      cell = function(col)
        if col == "value" then
          return money(item.value) .. (item.highValue and " |cffff8000!|r" or "")
        elseif col == "rule" then
          if protected then return RR.FormatState("na", L.LOOT_PROTECTED) end
          return RR.FormatState(item.highValue and "progress" or "open", RULE_TEXT[item.rule] or item.rule)
        else
          local a = item.appearance or {}
          if protected and a.collected == false then
            if a.eligibleUnknown then return "|cffffd100" .. L.LOOT_MISSING_SHORT .. "|r", RR.TipFromLines(item.link, { L.LOOT_TIP_MISSING_WEAPON }) end
            local names = {}
            for _, key in ipairs(a.eligible) do names[#names + 1] = RR:CharDisplayName(key) end
            local first = RR.db.chars[a.eligible[1] or ""]
            local lines = {
              #names > 0 and string.format(L.LOOT_TIP_MISSING, table.concat(names, ", ")) or L.LOOT_TIP_NO_ELIGIBLE,
            }
            if first then lines[#lines + 1] = transferText(a, first.name or a.eligible[1]) end
            return "|cffffd100" .. L.LOOT_MISSING_SHORT .. "|r", RR.TipFromLines(item.link, lines)
          end
          if protected then return "|cff808080" .. (item.reason or "") .. "|r" end
          return item.ilvl and ("ilvl " .. item.ilvl) or ""
        end
      end,
    }
  end

  function tab:Refresh()
    local out = M.last
    if merchantOpen and not out then out = M:BuildCandidates() end
    local rows = {}
    if not merchantOpen and not out then
      status:SetText(L.LOOT_OPEN_MERCHANT)
    elseif out then
      status:SetText(string.format(merchantOpen and L.LOOT_DRYRUN or L.LOOT_DRYRUN_CLOSED, #out.sell, money(out.total))
        .. (out.deferred > 0 and string.format(L.LOOT_DEFERRED, out.deferred) or ""))
      if #out.sell > 0 then
        rows[#rows + 1] = { label = L.LOOT_WOULD_SELL, header = true }
        for _, item in ipairs(out.sell) do rows[#rows + 1] = itemRow(item, false) end
      end
      if #out.protected > 0 then
        rows[#rows + 1] = { label = L.LOOT_PROTECTED_HEADER, header = true }
        for _, item in ipairs(out.protected) do rows[#rows + 1] = itemRow(item, true) end
      end
    end
    local ignored = {}
    for id in pairs(M.db.ignore) do ignored[#ignored + 1] = id end
    table.sort(ignored)
    if #ignored > 0 then
      rows[#rows + 1] = { label = L.LOOT_IGNORE_HEADER, header = true }
      for _, id in ipairs(ignored) do
        local name, link, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(id)
        rows[#rows + 1] = {
          label = link or name or ("item:" .. id), icon = icon,
          onRightClick = function(owner)
            RR.ShowMenu(owner, { { text = L.LOOT_UNIGNORE, func = function() M.db.ignore[id] = nil M:Rebuild() end } })
          end,
          cell = function(col) return col == "info" and ("|cff808080" .. L.LOOT_RCLICK_REMOVE .. "|r") or "" end,
        }
      end
    end
    sellBtn:SetEnabled(merchantOpen and out ~= nil and #out.sell > 0 and not selling)
    sellBtn:SetAlpha(sellBtn:IsEnabled() and 1 or 0.5)
    grid:SetData(columns, rows)
    grid:Render()
  end
  return tab
end

function M:GetTabs()
  return { { key = "loot", label = L.TAB_LOOT, build = buildLootTab, order = 30 } }
end

RR:RegisterModule("LootManager", M)
