-- Glowcery List: marks vendor items needed for tracked recipes.
local ADDON = "GlowceryList"
local ICON = "Interface\\GossipFrame\\VendorGossipIcon"
local f = CreateFrame("Frame")
GlowceryListDB = GlowceryListDB or {}

local function db()
  GlowceryListDB.tracked = GlowceryListDB.tracked or {} -- [name] = { [itemID] = qty }
  return GlowceryListDB.tracked
end

local function itemIDFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end

-- Build { [itemID] = totalNeeded } from all tracked recipes
local function GetNeeded()
  local need = {}
  -- 1) Built-in recipe tracking (modern API, if the client has it)
  if C_TradeSkillUI and C_TradeSkillUI.GetRecipesTracked and C_TradeSkillUI.GetRecipeSchematic then
    for _, recrafting in ipairs({ false, true }) do
      local ok, ids = pcall(C_TradeSkillUI.GetRecipesTracked, recrafting)
      if ok and ids then
        for _, recipeID in ipairs(ids) do
          local s = C_TradeSkillUI.GetRecipeSchematic(recipeID, recrafting)
          for _, slot in ipairs(s and s.reagentSlotSchematics or {}) do
            local r = slot.reagents and slot.reagents[1]
            if r and r.itemID then
              need[r.itemID] = (need[r.itemID] or 0) + (slot.quantityRequired or 1)
            end
          end
        end
      end
    end
  end
  -- 2) Recipes tracked through this addon's Track button
  for _, reagents in pairs(db()) do
    for id, qty in pairs(reagents) do need[id] = (need[id] or 0) + qty end
  end
  return need
end

local function Missing(itemID, needed)
  local have = 0
  if C_Item and C_Item.GetItemCount then
    have = C_Item.GetItemCount(itemID, true, false, true, true) or 0
  elseif GetItemCount then
    have = GetItemCount(itemID, true) or 0
  end
  return math.max(needed - have, 0)
end

---------------------------------------------------------------- Merchant overlay
local function Decorate(button)
  if button.rsIcon then return end
  local t = button:CreateTexture(nil, "OVERLAY", nil, 7)
  t:SetTexture(ICON); t:SetSize(16, 16)
  t:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
  local fs = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  fs:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
  fs:SetTextColor(0.2, 1, 0.2)
  -- pulsing glow on its own frame above the button
  local gf = CreateFrame("Frame", nil, button)
  gf:SetAllPoints(button)
  gf:SetFrameLevel(button:GetFrameLevel() + 5)
  local g = gf:CreateTexture(nil, "OVERLAY")
  if not (g.SetAtlas and g:SetAtlas("bags-glow-white")) then
    g:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    g:SetSize(70, 70)
    g:SetPoint("CENTER")
  else
    g:SetPoint("TOPLEFT", -6, 6); g:SetPoint("BOTTOMRIGHT", 6, -6)
  end
  g:SetBlendMode("ADD")
  g:SetVertexColor(0.3, 1, 0.3)
  local ag = gf:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0.3); a:SetToAlpha(1); a:SetDuration(0.7)
  -- keep icon/count above the glow
  t:SetParent(gf); fs:SetParent(gf)
  button.rsIcon, button.rsText, button.rsGlow, button.rsAnim = t, fs, gf, ag
end

local function UpdateMerchant()
  if not MerchantFrame or not MerchantFrame:IsShown() then return end
  local need = GetNeeded()
  local per = MERCHANT_ITEMS_PER_PAGE or 10
  for i = 1, per do
    local button = _G["MerchantItem" .. i .. "ItemButton"]
    if button then
      Decorate(button)
      local show = false
      if MerchantFrame.selectedTab == nil or MerchantFrame.selectedTab == 1 then
        local index = ((MerchantFrame.page or 1) - 1) * per + i
        local id = GetMerchantItemID and GetMerchantItemID(index)
                   or itemIDFromLink(GetMerchantItemLink(index))
        if id and need[id] then
          local miss = Missing(id, need[id])
          if miss > 0 then
            show = true
            button.rsText:SetText(miss)
          end
        end
      end
      button.rsIcon:SetShown(show)
      button.rsText:SetShown(show)
      button.rsGlow:SetShown(show)
      if show then
        if not button.rsAnim:IsPlaying() then button.rsAnim:Play() end
      else
        button.rsAnim:Stop()
      end
    end
  end
end

-- Tooltip line on any item you still need
local function TooltipLine(tt, data)
  if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
  local id = data and data.id
  if not id and tt.GetItem then
    local _, link = tt:GetItem()
    id = itemIDFromLink(link)
  end
  if not id then return end
  local n = GetNeeded()[id]
  if n then
    local miss = Missing(id, n)
    tt:AddLine(("|T%s:14|t Tracked recipe: need %d (missing %d)"):format(ICON, n, miss), 0.2, 1, 0.2)
    tt:Show()
  end
end
local function SafeTooltipLine(tt, data) pcall(TooltipLine, tt, data) end
if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, SafeTooltipLine)
else
  GameTooltip:HookScript("OnTooltipSetItem", SafeTooltipLine)
end

---------------------------------------------------------------- Track button (classic trade skill window)
local function SelectedReagents()
  if not GetTradeSkillSelectionIndex then return end
  local idx = GetTradeSkillSelectionIndex()
  if not idx or idx == 0 then return end
  local name, kind = GetTradeSkillInfo(idx)
  if not name or kind == "header" then return end
  local reagents = {}
  for r = 1, GetTradeSkillNumReagents(idx) do
    local _, _, count = GetTradeSkillReagentInfo(idx, r)
    local id = itemIDFromLink(GetTradeSkillReagentItemLink(idx, r))
    if id then reagents[id] = (reagents[id] or 0) + (count or 1) end
  end
  return name, reagents
end

local trackBtn
local function UpdateTrackButton()
  if not trackBtn then return end
  local name = SelectedReagents()
  trackBtn:SetEnabled(name ~= nil)
  trackBtn:SetText(name and db()[name] and "Untrack" or "Track buy")
end

local function MakeTrackButton()
  if trackBtn or not TradeSkillFrame then return end
  trackBtn = CreateFrame("Button", "GlowceryListTrackButton", TradeSkillFrame, "UIPanelButtonTemplate")
  trackBtn:SetSize(80, 22)
  local anchor = TradeSkillCreateAllButton or TradeSkillCreateButton
  if anchor then trackBtn:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
  else trackBtn:SetPoint("TOPRIGHT", TradeSkillFrame, "TOPRIGHT", -40, -40) end
  trackBtn:SetScript("OnClick", function()
    local name, reagents = SelectedReagents()
    if not name then return end
    if db()[name] then
      db()[name] = nil
      print("|cff33ff33Glowcery List:|r stopped tracking " .. name)
    else
      db()[name] = reagents
      print("|cff33ff33Glowcery List:|r tracking " .. name)
    end
    UpdateTrackButton(); UpdateMerchant()
  end)
  if TradeSkillFrame_Update then hooksecurefunc("TradeSkillFrame_Update", UpdateTrackButton) end
  UpdateTrackButton()
end

---------------------------------------------------------------- Events / slash
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("TRADE_SKILL_SHOW")
pcall(f.RegisterEvent, f, "TRACKED_RECIPE_UPDATE")
f:SetScript("OnEvent", function(_, event, arg)
  if event == "PLAYER_LOGIN" then
    if MerchantFrame_UpdateMerchantInfo then hooksecurefunc("MerchantFrame_UpdateMerchantInfo", UpdateMerchant) end
    if MerchantFrame_Update then hooksecurefunc("MerchantFrame_Update", UpdateMerchant) end
  elseif event == "TRADE_SKILL_SHOW" or (event == "ADDON_LOADED" and arg == "Blizzard_TradeSkillUI") then
    MakeTrackButton()
  else
    UpdateMerchant()
  end
end)

SLASH_GLOWCERYLIST1 = "/glowcery"
SlashCmdList.GLOWCERYLIST = function(msg)
  if msg == "clear" then
    wipe(db()); UpdateMerchant(); UpdateTrackButton()
    print("|cff33ff33Glowcery List:|r cleared all tracked recipes")
    return
  end
  print("|cff33ff33Glowcery List|r tracked recipes:")
  local any = false
  for name in pairs(db()) do print("  - " .. name); any = true end
  if not any then print("  (none from the Track buy button)") end
  print("  /glowcery clear - untrack everything")
end
