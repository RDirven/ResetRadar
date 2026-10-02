-- ResetRadar: settings panel in the game's Settings window (Settings.RegisterCanvasLayoutCategory).

local _, ns = ...
local RR, L = ns.RR, ns.L

-- Small layout helper so modules can add their own controls: panel:AddHeader / AddCheck / AddNumber / AddText.
local function createLayout(content)
  local layout = { content = content, y = -10, refreshers = {} }

  function layout:AddHeader(text)
    self.y = self.y - 8
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 10, self.y)
    fs:SetText(text)
    self.y = self.y - 24
    return fs
  end

  function layout:AddText(text)
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 16, self.y)
    fs:SetPoint("RIGHT", content, "RIGHT", -20, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    self.y = self.y - math.max(14, fs:GetStringHeight() + 6)
    return fs
  end

  -- get() -> bool, set(bool, checkbox). set may return false to undo the click (e.g. waiting for a confirmation).
  function layout:AddCheck(text, tooltip, get, set, indent)
    local c = RR.CreateCheck(content, text, function(checked, self)
      local result = set(checked, self)
      if result == false then self:SetChecked(not checked) end
    end)
    c:SetPoint("TOPLEFT", 12 + (indent or 0), self.y)
    if tooltip then
      c:SetScript("OnEnter", function(self) RR.ShowTooltip(self, RR.TipFromLines(text, { tooltip })) end)
      c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    self.refreshers[#self.refreshers + 1] = function() c:SetChecked(get() and true or false) end
    self.y = self.y - 26
    return c
  end

  function layout:AddNumber(text, tooltip, get, set, indent, width)
    local label = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 16 + (indent or 0), self.y - 3)
    label:SetText(text)
    local box = RR.CreateEditBox(content, width or 70, false)
    box:SetPoint("LEFT", label, "RIGHT", 8, 0)
    local function commit()
      local value = tonumber(box:GetText())
      if value then set(value) end
      box:SetText(tostring(get() or ""))
    end
    box:SetScript("OnEnterPressed", function(self) commit() self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", commit)
    if tooltip then
      box:SetScript("OnEnter", function(self) RR.ShowTooltip(self, RR.TipFromLines(text, { tooltip })) end)
      box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    self.refreshers[#self.refreshers + 1] = function() box:SetText(tostring(get() or "")) end
    self.y = self.y - 26
    return box
  end

  function layout:Refresh()
    for _, fn in ipairs(self.refreshers) do pcall(fn) end
  end
  return layout
end
RR.CreateSettingsLayout = createLayout

StaticPopupDialogs["RESETRADAR_ENABLE_LOOT"] = {
  text = L.LOOT_ENABLE_WARNING,
  button1 = L.LOOT_ENABLE_ACCEPT, button2 = CANCEL,
  OnAccept = function()
    RR.db.settings.lootWarningAccepted = true
    RR:SetModuleEnabled("LootManager", true)
    if RR.settingsLayout then RR.settingsLayout:Refresh() end
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

function RR:InitSettings()
  if not Settings or not Settings.RegisterCanvasLayoutCategory then
    RR.Debug("Settings API not available")
    return
  end
  local panel = CreateFrame("Frame")
  panel:Hide()

  local scroll = CreateFrame("ScrollFrame", nil, panel)
  scroll:SetPoint("TOPLEFT", 0, -4)
  scroll:SetPoint("BOTTOMRIGHT", -4, 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(600, 1200)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
  end)
  scroll:SetScript("OnSizeChanged", function(self, w) content:SetWidth(w) end)

  local layout = createLayout(content)
  local s = self.db.settings

  layout:AddHeader(L.ADDON_TITLE .. "  |cff808080" .. RR.version .. "|r")
  layout:AddCheck(L.OPT_MINIMAP, nil, function() return s.minimap.show end, function(v)
    s.minimap.show = v
    if RR.minimap then RR.minimap:UpdateVisibility() end
  end)
  layout:AddCheck(L.OPT_LOGIN, L.OPT_LOGIN_TIP, function() return s.loginMessage end, function(v) s.loginMessage = v end)
  layout:AddCheck(L.OPT_CURRENT_ONLY, nil, function() return s.viewMode == "current" end, function(v)
    s.viewMode = v and "current" or "all"
    RR:RefreshUI()
  end)
  layout:AddNumber(L.OPT_SCALE, L.OPT_SCALE_TIP, function() return s.scale end, function(v)
    s.scale = math.min(2, math.max(0.5, v))
    if RR.ui then RR.ui:ApplyScale() end
  end)
  layout:AddCheck(L.OPT_DEBUG, L.OPT_DEBUG_TIP, function() return s.debug end, function(v) s.debug = v end)

  layout:AddHeader(L.OPT_MODULES)
  for _, mod in ipairs(self.moduleOrder) do
    layout:AddCheck(mod.title or mod.name, mod.description, function() return RR:IsModuleEnabled(mod.name) end,
      function(v)
        if v and mod.requiresConfirmation and not RR:IsModuleEnabled(mod.name) then
          StaticPopup_Show("RESETRADAR_ENABLE_LOOT")
          return false -- enabled from the popup only
        end
        RR:SetModuleEnabled(mod.name, v)
      end)
  end

  for _, mod in ipairs(self.moduleOrder) do
    if mod.BuildSettings then
      local ok, err = pcall(mod.BuildSettings, mod, layout)
      if not ok then RR.Debug("settings for", mod.name, "failed:", err) end
    end
  end
  content:SetHeight(-layout.y + 20)

  panel:SetScript("OnShow", function() layout:Refresh() end)
  local category = Settings.RegisterCanvasLayoutCategory(panel, L.ADDON_TITLE)
  Settings.RegisterAddOnCategory(category)
  self.settingsCategory = category
  self.settingsLayout = layout
end
