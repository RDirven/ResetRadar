-- ResetRadar: main window, reusable grid, context menus and the minimap button. Only own frames, no Blizzard
-- templates that could carry taint; the window is rebuilt from saved data, never from live API calls.

local _, ns = ...
local RR, L = ns.RR, ns.L

local ui = { tabs = {}, tabOrder = {}, current = "checklist" }
RR.ui = ui

local LABEL_WIDTH = 210
local COL_WIDTH = 92
local ROW_HEIGHT = 18
local HEADER_HEIGHT = 22
local FONT = "GameFontHighlightSmall"

local ICONS = {
  done = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t",
  progress = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12:12|t",
  open = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12:12|t",
}
local COLORS = {
  done = "|cff40ff40", progress = "|cffffd100", open = "|cffff5050", info = "|cffffffff", na = "|cff808080",
}
RR.STATE_COLORS = COLORS
RR.STATE_ICONS = ICONS

-- Cell text: icon (shape differs per state, readable without color) + colored text.
function RR.FormatState(state, text)
  state = state or "na"
  local defaultText = (state == "done" and L.DONE) or (state == "progress" and L.IN_PROGRESS)
    or (state == "open" and L.OPEN) or "-"
  local icon = ICONS[state] and (ICONS[state] .. " ") or ""
  return icon .. (COLORS[state] or "") .. (text or defaultText) .. "|r"
end

local function entryText(entry)
  if not entry then return RR.FormatState("na", "-") end
  local text = entry.text
  if not text and entry.max and entry.max > 0 then text = string.format("%d/%d", entry.cur or 0, entry.max) end
  if entry.stale and entry.state ~= "open" then text = (text or "") .. "*" end
  return RR.FormatState(entry.state, text)
end
RR.EntryText = entryText

-- ---------- small widgets ----------

local function createBackdrop(frame, alpha)
  if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
  })
  frame:SetBackdropColor(0.05, 0.05, 0.07, alpha or 0.92)
  frame:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
end
RR.CreateBackdrop = createBackdrop

function RR.CreateButton(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(width or 80, 20)
  createBackdrop(b, 0.9)
  b:SetBackdropColor(0.15, 0.15, 0.2, 1)
  b.text = b:CreateFontString(nil, "OVERLAY", FONT)
  b.text:SetPoint("CENTER")
  b.text:SetText(text)
  b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.6, 0.6, 0.8, 1) end)
  b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.25, 0.25, 0.3, 1) end)
  b:SetScript("OnClick", onClick)
  b.SetLabel = function(self, t) self.text:SetText(t) end
  return b
end

function RR.CreateCheck(parent, text, onClick)
  local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  c:SetSize(22, 22)
  local label = c.Text or c.text
  if type(label) ~= "table" then
    label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", c, "RIGHT", 2, 0)
  end
  label:SetText(text)
  c.label = label
  c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false, self) end)
  return c
end

function RR.CreateEditBox(parent, width, numeric)
  local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
  e:SetSize(width or 120, 20)
  createBackdrop(e, 1)
  e:SetFontObject(ChatFontNormal)
  e:SetTextInsets(4, 4, 0, 0)
  e:SetAutoFocus(false)
  if numeric then e:SetNumeric(true) end
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return e
end

-- Shift-click an item into a focused ResetRadar edit box. hooksecurefunc never taints the hooked function.
local linkTargets = {}
function RR.AcceptItemLinks(editBox)
  linkTargets[#linkTargets + 1] = editBox
end
if ChatEdit_InsertLink then
  hooksecurefunc("ChatEdit_InsertLink", function(link)
    for _, box in ipairs(linkTargets) do
      if box:IsVisible() and box:HasFocus() and link then
        box:SetText(link)
        return
      end
    end
  end)
end

-- ---------- context menu ----------
-- items = { { text, func, disabled, isTitle }, ... }

local fallbackMenu
function RR.ShowMenu(owner, items)
  if MenuUtil and MenuUtil.CreateContextMenu then
    local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
      for _, item in ipairs(items) do
        if item.isTitle then
          root:CreateTitle(item.text)
        else
          local b = root:CreateButton(item.text, function() RR.SafeCall("menu", item.func) end)
          if item.disabled and b.SetEnabled then b:SetEnabled(false) end
        end
      end
    end)
    if ok then return end
  end
  -- fallback: minimal own menu
  if not fallbackMenu then
    fallbackMenu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    fallbackMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    createBackdrop(fallbackMenu, 1)
    fallbackMenu.buttons = {}
    fallbackMenu:EnableMouse(true)
    fallbackMenu:SetScript("OnLeave", function(self)
      if not self:IsMouseOver() then self:Hide() end
    end)
  end
  local m = fallbackMenu
  for _, b in ipairs(m.buttons) do b:Hide() end
  local width = 120
  for i, item in ipairs(items) do
    local b = m.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, m)
      b:SetHeight(18)
      b.text = b:CreateFontString(nil, "OVERLAY", FONT)
      b.text:SetPoint("LEFT", 6, 0)
      b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      m.buttons[i] = b
    end
    b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
    b:SetPoint("RIGHT", -2, 0)
    b.text:SetText(item.isTitle and ("|cffffd100" .. item.text .. "|r") or item.text)
    b:SetScript("OnClick", (not item.isTitle and not item.disabled) and function()
      m:Hide()
      RR.SafeCall("menu", item.func)
    end or nil)
    b:Show()
    width = math.max(width, b.text:GetStringWidth() + 20)
  end
  m:SetSize(width, #items * 18 + 4)
  local x, y = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  m:ClearAllPoints()
  m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale - 5, y / scale + 5)
  m:Show()
end

-- ---------- grid ----------
-- columns = { { key, label, tooltip = fn(tt), onRightClick = fn } }
-- rows = { { key, label, icon, header, dim, tooltip = fn(tt), onRightClick = fn, cell = fn(colKey) -> text, tip, click, rclick } }

local function showTooltip(owner, fn)
  if not fn then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  local ok = pcall(fn, GameTooltip)
  if ok and GameTooltip:NumLines() > 0 then GameTooltip:Show() else GameTooltip:Hide() end
end
RR.ShowTooltip = showTooltip

local function tipFromLines(title, lines)
  if not lines or #lines == 0 then return nil end
  return function(tt)
    if title then tt:AddLine(title) end
    for _, line in ipairs(lines) do tt:AddLine(line, 1, 1, 1, true) end
  end
end
RR.TipFromLines = tipFromLines

function RR.CreateGrid(parent, labelWidth)
  local grid = { colOffset = 0, rows = {}, columns = {}, rowFrames = {}, labelWidth = labelWidth or LABEL_WIDTH }

  local header = CreateFrame("Frame", nil, parent)
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:SetHeight(HEADER_HEIGHT)
  grid.header = header
  header.cols = {}

  grid.prev = RR.CreateButton(header, "<", 22, function() grid.colOffset = math.max(0, grid.colOffset - 1) grid:Render() end)
  grid.prev:SetPoint("LEFT", 2, 0)
  grid.next = RR.CreateButton(header, ">", 22, function() grid.colOffset = grid.colOffset + 1 grid:Render() end)
  grid.next:SetPoint("LEFT", grid.prev, "RIGHT", 2, 0)
  grid.pageText = header:CreateFontString(nil, "OVERLAY", FONT)
  grid.pageText:SetPoint("LEFT", grid.next, "RIGHT", 6, 0)

  local scroll = CreateFrame("ScrollFrame", nil, parent)
  scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", -8, 0)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(10, 10)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, child:GetHeight() - self:GetHeight())
    local value = math.min(max, math.max(0, self:GetVerticalScroll() - delta * ROW_HEIGHT * 3))
    self:SetVerticalScroll(value)
    grid:UpdateThumb()
  end)
  grid.scroll, grid.child = scroll, child

  local thumb = parent:CreateTexture(nil, "OVERLAY")
  thumb:SetColorTexture(0.6, 0.6, 0.7, 0.6)
  thumb:SetWidth(4)
  grid.thumb = thumb

  function grid:UpdateThumb()
    local viewH, contentH = scroll:GetHeight(), child:GetHeight()
    if contentH <= viewH + 1 or viewH <= 0 then thumb:Hide() return end
    local h = math.max(16, viewH * viewH / contentH)
    local offset = (scroll:GetVerticalScroll() / (contentH - viewH)) * (viewH - h)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 6, -offset)
    thumb:SetHeight(h)
    thumb:Show()
  end

  local function getRowFrame(i)
    local f = grid.rowFrames[i]
    if f then return f end
    f = CreateFrame("Frame", nil, child)
    f:SetHeight(ROW_HEIGHT)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.label = CreateFrame("Button", nil, f)
    f.label:SetPoint("TOPLEFT")
    f.label:SetSize(grid.labelWidth, ROW_HEIGHT)
    f.label:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.icon = f.label:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(14, 14)
    f.icon:SetPoint("LEFT", 2, 0)
    f.text = f.label:CreateFontString(nil, "OVERLAY", FONT)
    f.text:SetJustifyH("LEFT")
    f.text:SetWordWrap(false)
    f.text:SetPoint("RIGHT", -4, 0)
    f.label:SetScript("OnEnter", function(self) showTooltip(self, self.tooltip) end)
    f.label:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.label:SetScript("OnClick", function(self, button)
      if button == "RightButton" and self.rclick then self.rclick(self) elseif button == "LeftButton" and self.click then self.click(self) end
    end)
    f.cells = {}
    grid.rowFrames[i] = f
    return f
  end

  local function getCell(f, c)
    local cell = f.cells[c]
    if cell then return cell end
    cell = CreateFrame("Button", nil, f)
    cell:SetSize(COL_WIDTH, ROW_HEIGHT)
    cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    cell.text = cell:CreateFontString(nil, "OVERLAY", FONT)
    cell.text:SetPoint("LEFT", 4, 0)
    cell.text:SetPoint("RIGHT", -2, 0)
    cell.text:SetJustifyH("LEFT")
    cell.text:SetWordWrap(false)
    cell:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    cell:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
    cell:SetScript("OnEnter", function(self) showTooltip(self, self.tooltip) end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cell:SetScript("OnClick", function(self, button)
      if button == "RightButton" and self.rclick then self.rclick(self) elseif button == "LeftButton" and self.click then self.click(self) end
    end)
    f.cells[c] = cell
    return cell
  end

  local function getHeaderCol(c)
    local h = header.cols[c]
    if h then return h end
    h = CreateFrame("Button", nil, header)
    h:SetSize(COL_WIDTH, HEADER_HEIGHT)
    h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.text:SetPoint("LEFT", 4, 0)
    h.text:SetPoint("RIGHT", -2, 0)
    h.text:SetJustifyH("LEFT")
    h.text:SetWordWrap(false)
    h:SetScript("OnEnter", function(self) showTooltip(self, self.tooltip) end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    h:SetScript("OnClick", function(self, button) if button == "RightButton" and self.rclick then self.rclick(self) end end)
    header.cols[c] = h
    return h
  end

  function grid:SetData(columns, rows)
    self.columns, self.rows = columns or {}, rows or {}
  end

  function grid:Render()
    local width = parent:GetWidth()
    if not width or width <= 0 then return end
    local visible = math.max(1, math.floor((width - self.labelWidth - 12) / COL_WIDTH))
    local maxOffset = math.max(0, #self.columns - visible)
    self.colOffset = math.min(self.colOffset, maxOffset)
    local paging = #self.columns > visible
    self.prev:SetShown(paging)
    self.next:SetShown(paging)
    self.pageText:SetText(paging and string.format(L.COLUMNS_RANGE, self.colOffset + 1,
      math.min(#self.columns, self.colOffset + visible), #self.columns) or "")

    for c = 1, math.max(visible, #header.cols) do
      local col = self.columns[self.colOffset + c]
      local h = (c <= visible and col) and getHeaderCol(c) or header.cols[c]
      if h then
        if c <= visible and col then
          h:SetPoint("LEFT", header, "LEFT", self.labelWidth + (c - 1) * COL_WIDTH, 0)
          h.text:SetText(col.label)
          h.tooltip, h.rclick = col.tooltip, col.onRightClick
          h:Show()
        else
          h:Hide()
        end
      end
    end

    child:SetWidth(math.max(10, scroll:GetWidth()))
    for i, row in ipairs(self.rows) do
      local f = getRowFrame(i)
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
      f:SetPoint("RIGHT", child, "RIGHT")
      if row.header then
        f.bg:SetColorTexture(0.2, 0.2, 0.28, 0.6)
      elseif i % 2 == 0 then
        f.bg:SetColorTexture(1, 1, 1, 0.03)
      else
        f.bg:SetColorTexture(0, 0, 0, 0)
      end
      if row.icon then
        f.icon:SetTexture(row.icon)
        f.icon:Show()
        f.text:SetPoint("LEFT", 20, 0)
      else
        f.icon:Hide()
        f.text:SetPoint("LEFT", row.header and 4 or 14, 0)
      end
      local label = row.label or ""
      if row.header then label = "|cffffd100" .. label .. "|r" end
      if row.dim then label = "|cff808080" .. label .. "|r" end
      f.text:SetText(label)
      f.label.tooltip, f.label.rclick, f.label.click = row.tooltip, row.onRightClick, row.onClick
      for c = 1, math.max(visible, #f.cells) do
        local col = self.columns[self.colOffset + c]
        if c <= visible and col and row.cell then
          local cell = getCell(f, c)
          cell:SetPoint("LEFT", f, "LEFT", self.labelWidth + (c - 1) * COL_WIDTH, 0)
          local ok, text, tip, click, rclick = pcall(row.cell, col.key, col)
          if not ok then RR.Debug("cell failed:", text) text, tip, click, rclick = "|cffff0000!|r", nil, nil, nil end
          cell.text:SetText(text or "")
          cell.tooltip, cell.click, cell.rclick = tip, click, rclick
          cell:Show()
        elseif f.cells[c] then
          f.cells[c]:Hide()
        end
      end
      f:Show()
    end
    for i = #self.rows + 1, #self.rowFrames do self.rowFrames[i]:Hide() end
    child:SetHeight(math.max(10, #self.rows * ROW_HEIGHT))
    local maxScroll = math.max(0, child:GetHeight() - scroll:GetHeight())
    if scroll:GetVerticalScroll() > maxScroll then scroll:SetVerticalScroll(maxScroll) end
    self:UpdateThumb()
  end

  return grid
end

-- ---------- characters as columns ----------

-- Returns sorted character keys for the current view (current character first).
function RR:GetVisibleCharKeys()
  local keys = {}
  local showHidden = self.db.settings.showHidden
  if self.db.settings.viewMode == "current" then
    if self.charKey and self.db.chars[self.charKey] then keys[1] = self.charKey end
    return keys
  end
  for key, char in pairs(self.db.chars) do
    if showHidden or not char.hidden then keys[#keys + 1] = key end
  end
  local current = self.charKey
  table.sort(keys, function(a, b)
    if a == current then return true end
    if b == current then return false end
    local ca, cb = self.db.chars[a], self.db.chars[b]
    if (ca.level or 0) ~= (cb.level or 0) then return (ca.level or 0) > (cb.level or 0) end
    return a < b
  end)
  return keys
end

-- Name in class color; realm added when two characters share a name.
function RR:CharDisplayName(key, short)
  local char = self.db.chars[key]
  if not char then return key end
  local name = char.name or key
  local duplicate = false
  for otherKey, other in pairs(self.db.chars) do
    if otherKey ~= key and other.name == char.name then duplicate = true break end
  end
  if duplicate and not short then name = name .. "-" .. (char.realm or "?") end
  if duplicate and short then name = name .. "*" end
  return RR.ClassColored(name, char.class)
end

function RR:CharColumns()
  local cols = {}
  for _, key in ipairs(self:GetVisibleCharKeys()) do
    local char = self.db.chars[key]
    local label = self:CharDisplayName(key, true)
    if char.hidden then label = "|cff808080(" .. (char.name or key) .. ")|r" end
    cols[#cols + 1] = {
      key = key,
      label = label,
      tooltip = function(tt)
        tt:AddLine(self:CharDisplayName(key))
        tt:AddLine(string.format(L.CHAR_TIP_LEVEL, char.level or 0, char.realm or "?"), 1, 1, 1)
        tt:AddLine(string.format(L.CHAR_TIP_SEEN, RR.FormatAgo(char.lastSeen)), 0.8, 0.8, 0.8)
        tt:AddLine(L.CHAR_TIP_RCLICK, 0.5, 0.5, 0.5)
      end,
      onRightClick = function(owner)
        RR.ShowMenu(owner, {
          { text = char.name or key, isTitle = true },
          { text = char.hidden and L.MENU_SHOW_CHAR or L.MENU_HIDE_CHAR, func = function()
            char.hidden = not char.hidden
            RR:RefreshUI()
          end },
          { text = L.MENU_RESET_CHAR, func = function()
            RR:ResetCharacter(key)
            RR.Print(string.format(L.CHAR_RESET_DONE, key))
            RR:RefreshUI()
          end },
          { text = L.MENU_REMOVE_CHAR, disabled = key == RR.charKey, func = function()
            RR.pendingRemove = key
            StaticPopup_Show("RESETRADAR_REMOVE_CHAR", key)
          end },
        })
      end,
    }
  end
  return cols
end

StaticPopupDialogs["RESETRADAR_REMOVE_CHAR"] = {
  text = L.CONFIRM_REMOVE_CHAR,
  button1 = YES, button2 = NO,
  OnAccept = function() if RR.pendingRemove then RR:RemoveCharacter(RR.pendingRemove) end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ---------- checklist tab ----------

local function rowHiddenMenu(owner, path, label, charKey)
  local settings = RR.db.settings
  local items = { { text = label, isTitle = true } }
  items[#items + 1] = {
    text = settings.hiddenRows[path] and L.MENU_SHOW_ROW or L.MENU_HIDE_ROW,
    func = function()
      settings.hiddenRows[path] = not settings.hiddenRows[path] or nil
      RR:RefreshUI()
    end,
  }
  if charKey then
    local char = RR.db.chars[charKey]
    items[#items + 1] = {
      text = string.format(char.hiddenItems[path] and L.MENU_SHOW_FOR or L.MENU_HIDE_FOR, char.name or charKey),
      func = function()
        char.hiddenItems[path] = not char.hiddenItems[path] or nil
        RR:RefreshUI()
      end,
    }
  end
  RR.ShowMenu(owner, items)
end

local function buildChecklistRows(columns)
  local db = RR.db
  local settings = db.settings
  local rows = {}
  local function cellFor(path, getEntry, label)
    return function(charKey)
      local char = db.chars[charKey]
      if char.hiddenItems[path] then
        return settings.showHidden and "|cff606060" .. L.HIDDEN .. "|r" or "", nil, nil,
          function(owner) rowHiddenMenu(owner, path, label, charKey) end
      end
      local entry = getEntry(char)
      local tip
      if entry then
        local lines = {}
        if entry.tip then for _, l in ipairs(entry.tip) do lines[#lines + 1] = l end end
        if entry.stale then lines[#lines + 1] = "|cff808080" .. L.STALE_TIP .. "|r" end
        if entry.expires then lines[#lines + 1] = "|cff808080" .. string.format(L.RESETS_IN, RR.FormatDuration(entry.expires - RR.Now())) .. "|r" end
        tip = tipFromLines(label .. " - " .. RR:CharDisplayName(charKey), lines)
      end
      return entryText(entry), tip, nil, function(owner) rowHiddenMenu(owner, path, label, charKey) end
    end
  end

  for _, def in ipairs(RR.items) do
    local isGroup, subKeys, subLabels = false, {}, {}
    local any = false
    for _, col in ipairs(columns) do
      local entry = db.chars[col.key].data[def.key]
      if entry then
        any = true
        if entry.sub then
          isGroup = true
          for subKey, sub in pairs(entry.sub) do
            if not subLabels[subKey] then subKeys[#subKeys + 1] = subKey end
            subLabels[subKey] = sub.label or subLabels[subKey] or subKey
          end
        end
      end
    end
    local hiddenDef = settings.hiddenRows[def.key]
    if any and (not hiddenDef or settings.showHidden) then
      if isGroup then
        if #subKeys > 0 then
          rows[#rows + 1] = {
            label = def.label, header = true, dim = hiddenDef,
            onRightClick = function(owner) rowHiddenMenu(owner, def.key, def.label) end,
          }
          if not hiddenDef then
            table.sort(subKeys, function(a, b) return tostring(subLabels[a]) < tostring(subLabels[b]) end)
            for _, subKey in ipairs(subKeys) do
              local path = def.key .. ":" .. subKey
              local hidden = settings.hiddenRows[path]
              if not hidden or settings.showHidden then
                rows[#rows + 1] = {
                  label = subLabels[subKey], dim = hidden,
                  onRightClick = function(owner) rowHiddenMenu(owner, path, subLabels[subKey]) end,
                  cell = cellFor(path, function(char)
                    local e = char.data[def.key]
                    return e and e.sub and e.sub[subKey]
                  end, subLabels[subKey]),
                }
              end
            end
          end
        end
      else
        rows[#rows + 1] = {
          label = def.label, dim = hiddenDef,
          onRightClick = function(owner) rowHiddenMenu(owner, def.key, def.label) end,
          cell = cellFor(def.key, function(char) return char.data[def.key] end, def.label),
        }
      end
    end
  end

  -- manual items
  local manualIds = {}
  for id in pairs(db.account.manual) do manualIds[#manualIds + 1] = id end
  table.sort(manualIds)
  if #manualIds > 0 then
    rows[#rows + 1] = { label = L.MANUAL_ITEMS, header = true }
    for _, id in ipairs(manualIds) do
      local item = db.account.manual[id]
      local path = "manual:" .. id
      local hidden = settings.hiddenRows[path]
      if not hidden or settings.showHidden then
        local suffix = string.format(" |cff808080(%s, %s)|r", item.resetType == "daily" and L.DAILY or L.WEEKLY,
          item.scope == "account" and L.ACCOUNT or L.CHARACTER)
        rows[#rows + 1] = {
          label = item.label .. suffix, dim = hidden,
          tooltip = tipFromLines(item.label, { L.MANUAL_TIP }),
          onRightClick = function(owner)
            RR.ShowMenu(owner, {
              { text = item.label, isTitle = true },
              { text = hidden and L.MENU_SHOW_ROW or L.MENU_HIDE_ROW, func = function()
                settings.hiddenRows[path] = not settings.hiddenRows[path] or nil
                RR:RefreshUI()
              end },
              { text = L.MENU_DELETE_ITEM, func = function() RR:RemoveManualItem(id) end },
            })
          end,
          cell = function(charKey)
            local char = db.chars[charKey]
            if char.hiddenItems[path] then
              return settings.showHidden and "|cff606060" .. L.HIDDEN .. "|r" or "", nil, nil,
                function(owner) rowHiddenMenu(owner, path, item.label, charKey) end
            end
            local state = RR:GetManualState(id, charKey)
            local done = state and state.done
            return RR.FormatState(done and "done" or "open"), tipFromLines(item.label, { L.CLICK_TOGGLE }),
              function() RR:ToggleManual(id, charKey) end,
              function(owner) rowHiddenMenu(owner, path, item.label, charKey) end
          end,
        }
      end
    end
  end
  return rows
end

local function buildChecklistTab(parent)
  local tab = { frame = parent }
  local settings = RR.db.settings

  local viewBtn = RR.CreateButton(parent, "", 150, function()
    settings.viewMode = settings.viewMode == "all" and "current" or "all"
    RR:RefreshUI()
  end)
  viewBtn:SetPoint("TOPLEFT", 4, -4)
  tab.viewBtn = viewBtn

  local hiddenCheck = RR.CreateCheck(parent, L.SHOW_HIDDEN, function(checked)
    settings.showHidden = checked
    RR:RefreshUI()
  end)
  hiddenCheck:SetPoint("LEFT", viewBtn, "RIGHT", 8, 0)
  tab.hiddenCheck = hiddenCheck

  -- add-manual-item form (anchored from the right edge)
  local newReset, newScope = "weekly", "character"
  local addName = RR.CreateEditBox(parent, 150)
  local addBtn = RR.CreateButton(parent, L.ADD, 50, function()
    if RR:AddManualItem(addName:GetText(), newReset, newScope) then addName:SetText("") end
    addName:ClearFocus()
  end)
  addBtn:SetPoint("TOPRIGHT", -4, -4)
  local scopeBtn = RR.CreateButton(parent, L.CHARACTER, 70, function(self)
    newScope = newScope == "character" and "account" or "character"
    self:SetLabel(newScope == "character" and L.CHARACTER or L.ACCOUNT)
  end)
  scopeBtn:SetPoint("RIGHT", addBtn, "LEFT", -4, 0)
  local resetBtn = RR.CreateButton(parent, L.WEEKLY, 60, function(self)
    newReset = newReset == "weekly" and "daily" or "weekly"
    self:SetLabel(newReset == "weekly" and L.WEEKLY or L.DAILY)
  end)
  resetBtn:SetPoint("RIGHT", scopeBtn, "LEFT", -4, 0)
  addName:SetPoint("RIGHT", resetBtn, "LEFT", -4, 0)
  local addHint = addName:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  addHint:SetPoint("LEFT", 4, 0)
  addHint:SetText(L.ADD_ITEM_HINT)
  addName:SetScript("OnTextChanged", function(self) addHint:SetShown(self:GetText() == "") end)
  addName:SetScript("OnEnterPressed", function() addBtn:Click() end)

  local gridHolder = CreateFrame("Frame", nil, parent)
  gridHolder:SetPoint("TOPLEFT", 0, -30)
  gridHolder:SetPoint("BOTTOMRIGHT")
  tab.grid = RR.CreateGrid(gridHolder)

  function tab:Refresh()
    viewBtn:SetLabel(settings.viewMode == "all" and L.VIEW_ALL or L.VIEW_CURRENT)
    hiddenCheck:SetChecked(settings.showHidden)
    local columns = RR:CharColumns()
    self.grid:SetData(columns, buildChecklistRows(columns))
    self.grid:Render()
  end
  return tab
end

-- ---------- main window ----------

function ui:RegisterTab(key, label, build, order)
  self.tabs[key] = { key = key, label = label, build = build, order = order or 100 }
end

function ui:RebuildTabs()
  if not self.frame then return end
  wipe(self.tabOrder)
  for key, t in pairs(self.tabs) do
    local visible = true
    if t.module then visible = RR:IsModuleActive(t.module) end
    if visible then self.tabOrder[#self.tabOrder + 1] = t end
    if not visible and t.content then t.content:Hide() end
  end
  table.sort(self.tabOrder, function(a, b) return a.order < b.order end)
  self.tabButtons = self.tabButtons or {}
  for _, b in ipairs(self.tabButtons) do b:Hide() end
  local prev
  for i, t in ipairs(self.tabOrder) do
    local b = self.tabButtons[i]
    if not b then
      b = RR.CreateButton(self.frame, "", 100)
      self.tabButtons[i] = b
    end
    b:SetLabel(t.label)
    b:SetWidth(math.max(80, b.text:GetStringWidth() + 20))
    b:SetScript("OnClick", function() ui:SelectTab(t.key) end)
    b:ClearAllPoints()
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 10, -30) end
    b:Show()
    b.key = t.key
    prev = b
  end
  if not self.tabs[self.current] or (self.tabs[self.current].module and not RR:IsModuleActive(self.tabs[self.current].module)) then
    self.current = "checklist"
  end
end

function ui:SelectTab(key)
  if not self.tabs[key] or (self.tabs[key].module and not RR:IsModuleActive(self.tabs[key].module)) then
    key = "checklist"
  end
  self.current = key
  for _, t in pairs(self.tabs) do
    if t.content then t.content:SetShown(t.key == key) end
  end
  local t = self.tabs[key]
  if not t.content then
    t.content = CreateFrame("Frame", nil, self.frame)
    t.content:SetPoint("TOPLEFT", 10, -56)
    t.content:SetPoint("BOTTOMRIGHT", -10, 24)
    local ok, result = pcall(t.build, t.content)
    if ok then t.obj = result else RR.Print(string.format(L.TAB_FAILED, t.label)) RR.Debug(result) end
  end
  for _, b in ipairs(self.tabButtons or {}) do
    if b:IsShown() then b:SetBackdropColor(b.key == key and 0.3 or 0.15, b.key == key and 0.3 or 0.15, b.key == key and 0.45 or 0.2, 1) end
  end
  self:Refresh()
end

function ui:Refresh()
  if not self.frame or not self.frame:IsShown() then return end
  local db = RR.db
  local g = db.global
  local now = RR.Now()
  local status = string.format(L.RESET_STATUS, RR.FormatDuration((g.nextDaily or now) - now),
    RR.FormatDuration((g.nextWeekly or now) - now))
  if g.activeEvents and #g.activeEvents > 0 then
    status = status .. "  |cffffd100" .. L.ACTIVE_EVENTS .. "|r " .. table.concat(g.activeEvents, ", ")
  end
  self.status:SetText(status)
  local t = self.tabs[self.current]
  if t and t.obj and t.obj.Refresh then
    local ok, err = pcall(t.obj.Refresh, t.obj)
    if not ok then RR.Debug("tab refresh failed:", err) end
  end
end

function ui:Create()
  local settings = RR.db.settings
  local f = CreateFrame("Frame", "ResetRadarMainFrame", UIParent, "BackdropTemplate")
  createBackdrop(f, 0.94)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetResizable(true)
  if f.SetResizeBounds then f:SetResizeBounds(660, 260, 1800, 1200) end
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    settings.window.point, settings.window.relPoint, settings.window.x, settings.window.y = point, relPoint, x, y
  end)
  f:SetSize(settings.window.width or 760, settings.window.height or 460)
  if settings.window.point then
    f:SetPoint(settings.window.point, UIParent, settings.window.relPoint or settings.window.point,
      settings.window.x or 0, settings.window.y or 0)
  else
    f:SetPoint("CENTER")
  end
  f:SetScale(settings.scale or 1)
  f:Hide()
  tinsert(UISpecialFrames, "ResetRadarMainFrame") -- closes on Escape

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -8)
  title:SetText(L.ADDON_TITLE)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  local gear = RR.CreateButton(f, L.SETTINGS, 70, function() RR:OpenSettings() end)
  gear:SetPoint("TOPRIGHT", -30, -6)

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("BOTTOMLEFT", 10, 7)
  status:SetPoint("RIGHT", -24, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  self.status = status

  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    settings.window.width, settings.window.height = f:GetWidth(), f:GetHeight()
    local point, _, relPoint, x, y = f:GetPoint()
    settings.window.point, settings.window.relPoint, settings.window.x, settings.window.y = point, relPoint, x, y
    ui:Refresh()
  end)

  f:SetScript("OnShow", function()
    RR:ApplyResets()
    ui:Refresh()
  end)
  f:SetScript("OnSizeChanged", function() if f:IsShown() then ui:Refresh() end end)
  self.frame = f
  self:RebuildTabs()
end

function ui:Show(tab)
  if not self.frame then self:Create() end
  self:RebuildTabs()
  self.frame:Show()
  self:SelectTab(tab and self.tabs[tab] and tab or self.current)
end

function ui:Toggle(tab)
  if self.frame and self.frame:IsShown() and (not tab or tab == self.current) then
    self.frame:Hide()
  else
    self:Show(tab)
  end
end

function ui:ApplyScale()
  if self.frame then self.frame:SetScale(RR.db.settings.scale or 1) end
end

function RR:OnModulesChanged()
  ui:RebuildTabs()
  if ui.frame and ui.frame:IsShown() then ui:SelectTab(ui.current) end
  if self.minimap then self.minimap:UpdateVisibility() end
end

-- ---------- minimap button (no LibDataBroker / LibDBIcon) ----------

local function createMinimapButton()
  if not Minimap then return nil end
  local settings = RR.db.settings.minimap
  local b = CreateFrame("Button", "ResetRadarMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER")
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
  icon:SetSize(18, 18)
  icon:SetPoint("CENTER")
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(52, 52)
  border:SetPoint("TOPLEFT")

  local function place()
    local angle = math.rad(settings.angle or 215)
    local radius = (Minimap:GetWidth() / 2) + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
  end
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function() -- only while dragging, never for data
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      settings.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      place()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then RR:OpenSettings() else RR:ToggleWindow() end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(L.ADDON_TITLE)
    if RR.charKey then
      RR:ApplyResets()
      local s = RR:GetSummary(RR.charKey)
      GameTooltip:AddLine(string.format(L.TOOLTIP_WEEKLY, s.weeklyOpen, s.weeklyTotal), 1, 1, 1)
      GameTooltip:AddLine(string.format(L.TOOLTIP_DAILY, s.dailyOpen, s.dailyTotal), 1, 1, 1)
    end
    for _, mod in ipairs(RR.moduleOrder) do
      if RR:IsModuleActive(mod.name) then RR:ModuleCall(mod, "AddMinimapLines", GameTooltip) end
    end
    GameTooltip:AddLine(L.TOOLTIP_CLICKS, 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  function b:UpdateVisibility()
    self:SetShown(RR.db.settings.minimap.show)
  end
  place()
  b:UpdateVisibility()
  return b
end

function RR:InitUI()
  ui:RegisterTab("checklist", L.TAB_CHECKLIST, buildChecklistTab, 10)
  for _, mod in ipairs(self.moduleOrder) do
    if mod.GetTabs then
      local ok, tabs = pcall(mod.GetTabs, mod)
      if ok and tabs then
        for _, t in ipairs(tabs) do
          ui:RegisterTab(t.key, t.label, t.build, t.order)
          ui.tabs[t.key].module = mod.name
        end
      end
    end
  end
  self.minimap = createMinimapButton()
end
