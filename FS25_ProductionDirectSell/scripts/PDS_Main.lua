--
-- PDS_Main
--
-- Entry point (the only file listed in modDesc.xml). Wires the mod into the
-- game's life cycle and into the vanilla Production menu:
--
--   loadMap            load GUI profiles + dialogs
--   InGameMenuProductionFrame.onFrameOpen/onFrameClose/onListSelectionChanged
--                       (all appended) - create/show/hide a real "Sell"
--                       button inside the frame, and register/unregister the
--                       PDS_OPEN_SELLING key for as long as the menu is open
--   openSellingForSelected  grab the selected production point and open
--                       the selling dialog
--   requestSale / onSellResult  send the sale to the server, show the result
--
-- Note on how the button is added: this does NOT use the vanilla
-- menuButtonInfo / bottom-bar-button system that a page's own buttons go
-- through. That system only wires up as many buttons as there are physical
-- button slots in the frame's own layout (a small fixed number), and the
-- Production frame can already use all of them itself (Back/Next/Prev plus
-- Activate/Toggle-mode or Tag/Visit depending on what's focused) - a button
-- appended on top of those is silently dropped. Instead, PDS_Main.sellButton
-- is built by cloning one of the menu's own existing buttons
-- (g_inGameMenu.menuButton[1]) into the same parent, the same technique the
-- FS25_BetterContracts mod uses to add its own buttons to a vanilla in-game
-- menu screen. A real GuiElement the player can click is not subject to
-- that slot limit at all.
--

PDS_Main = {}

PDS_Main.MOD_DIRECTORY = g_currentModDirectory or ""
PDS_Main.MOD_NAME = g_currentModName or "FS25_ProductionDirectSell"

local scripts = {
    "scripts/PDS_Manager.lua",
    "scripts/PDS_SellRequestEvent.lua",
    "gui/PDS_ConfirmDialog.lua",
    "gui/PDS_SellingDialog.lua",
}
for _, file in ipairs(scripts) do
    source(PDS_Main.MOD_DIRECTORY .. file)
end

---Temporary diagnostic logging (prefixed "[PDS]") - grep the FS25 log for
-- "[PDS]" to see exactly how far the mod got. Safe to remove once the
-- button/key are confirmed working end to end.
function PDS_Main.log(fmt, ...)
    print(string.format("[PDS] " .. fmt, ...))
end

function PDS_Main:loadMap(filename)
    PDS_Main.log("loadMap start")
    if g_gui == nil then
        Logging.error("[ProductionDirectSell] g_gui not available, mod disabled")
        return
    end

    g_gui:loadProfiles(PDS_Main.MOD_DIRECTORY .. "gui/guiProfiles.xml")

    PDS_Main.confirmDialog = PDS_ConfirmDialog.new()
    local confirmGui = g_gui:loadGui(PDS_Main.MOD_DIRECTORY .. "gui/PDS_ConfirmDialog.xml", "PDS_ConfirmDialog", PDS_Main.confirmDialog)
    PDS_Main.log("PDS_ConfirmDialog gui loaded: %s", tostring(confirmGui ~= nil))

    PDS_Main.sellingDialog = PDS_SellingDialog.new()
    local sellingGui = g_gui:loadGui(PDS_Main.MOD_DIRECTORY .. "gui/PDS_SellingDialog.xml", "PDS_SellingDialog", PDS_Main.sellingDialog)
    PDS_Main.log("PDS_SellingDialog gui loaded: %s", tostring(sellingGui ~= nil))

    PDS_Main.installProductionMenuHook()
    PDS_Main.log("loadMap done, InputAction.PDS_OPEN_SELLING = %s", tostring(InputAction ~= nil and InputAction.PDS_OPEN_SELLING or "InputAction table missing"))
end

function PDS_Main:deleteMap()
    PDS_Main.confirmDialog = nil
    PDS_Main.sellingDialog = nil
    PDS_Main.sellKeyEventId = nil
    PDS_Main.sellButton = nil
    PDS_Main.currentPageProduction = nil
end

-------------------------------------------------------------------------------
-- Production menu integration
-------------------------------------------------------------------------------

---Resolves the live InGameMenuProductionFrame instance. Prefers the
-- instance we were actually handed by its own onFrameOpen (cached as
-- currentPageProduction) since g_currentMission.inGameMenu.pageProduction
-- does not reliably match it (confirmed from the field log - comparing
-- against it was silently blocking the key/button from ever being set up).
-- Falls back to the global lookup for the rare case nothing has opened the
-- frame yet this session.
function PDS_Main.getPageProduction()
    if PDS_Main.currentPageProduction ~= nil then
        return PDS_Main.currentPageProduction
    end
    if g_currentMission == nil or g_currentMission.inGameMenu == nil then
        return nil
    end
    return g_currentMission.inGameMenu.pageProduction
end

---Only true while the player has an owned production selected/open in the
-- vanilla Production menu - exactly the gate the spec asks for.
function PDS_Main.getSelectedOwnedProductionPoint()
    local pageProduction = PDS_Main.getPageProduction()
    if pageProduction == nil or pageProduction.getSelectedProduction == nil then
        PDS_Main.log("getSelectedOwnedProductionPoint: no pageProduction (pageProduction=%s)", tostring(pageProduction))
        return nil
    end
    if pageProduction.pointsSelector == nil or pageProduction.pointsSelector:getState() ~= InGameMenuProductionFrame.POINTS_OWNED then
        PDS_Main.log("getSelectedOwnedProductionPoint: pointsSelector state is not POINTS_OWNED (state=%s)",
            tostring(pageProduction.pointsSelector ~= nil and pageProduction.pointsSelector:getState() or nil))
        return nil
    end
    local _, productionPoint = pageProduction:getSelectedProduction()
    if productionPoint == nil then
        PDS_Main.log("getSelectedOwnedProductionPoint: getSelectedProduction() returned no productionPoint")
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    if not PDS_Manager.isSellableProductionPoint(productionPoint, farmId) then
        PDS_Main.log("getSelectedOwnedProductionPoint: '%s' failed isSellableProductionPoint (myFarmId=%s, ownerFarmId=%s)",
            tostring(productionPoint:getName()), tostring(farmId),
            tostring(productionPoint.getOwnerFarmId ~= nil and productionPoint:getOwnerFarmId() or productionPoint.ownerFarmId))
        return nil
    end
    return productionPoint
end

---Registers the PDS_OPEN_SELLING key for as long as the Production frame is
-- open. Safe to call more than once (guarded by sellKeyEventId). This is a
-- best-effort convenience on top of the button below - a plain click always
-- works regardless of whether a custom action manages to fire on this
-- particular setup, so the button is the primary, guaranteed way in.
function PDS_Main.onProductionFrameOpen(pageProduction)
    PDS_Main.log("onProductionFrameOpen fired, pageProduction=%s", tostring(pageProduction))
    -- pageProduction (self) is already guaranteed to be the real
    -- InGameMenuProductionFrame instance here since we appended directly to
    -- its own class method - no need to cross-check it against
    -- g_currentMission.inGameMenu.pageProduction, which turned out not to
    -- reliably match (that check was silently blocking everything below).
    if pageProduction == nil then
        return
    end
    PDS_Main.currentPageProduction = pageProduction
    if PDS_Main.sellKeyEventId == nil then
        local ok, eventId = g_inputBinding:registerActionEvent(InputAction.PDS_OPEN_SELLING, PDS_Main, PDS_Main.onSellKeyPressed, false, true, false, true)
        PDS_Main.log("registerActionEvent result ok=%s eventId=%s", tostring(ok), tostring(eventId))
        if eventId ~= nil then
            g_inputBinding:setActionEventTextVisibility(eventId, false)
            PDS_Main.sellKeyEventId = eventId
        end
    end
    PDS_Main.createSellButton()
    PDS_Main.updateSellButtonVisibility()
end

function PDS_Main.onProductionFrameClose(pageProduction)
    -- Note: do NOT gate this on PDS_Main.getPageProduction() matching -
    -- during mission teardown g_currentMission.inGameMenu can already be
    -- nil by the time this fires, and we still need to release the key and
    -- hide the button regardless.
    if PDS_Main.sellKeyEventId ~= nil then
        g_inputBinding:removeActionEvent(PDS_Main.sellKeyEventId)
        PDS_Main.sellKeyEventId = nil
    end
    if PDS_Main.sellButton ~= nil then
        PDS_Main.sellButton:setVisible(false)
    end
end

function PDS_Main.onProductionListSelectionChanged(pageProduction, list, section, index)
    if pageProduction == nil then
        return
    end
    PDS_Main.currentPageProduction = pageProduction
    PDS_Main.updateSellButtonVisibility()
end

function PDS_Main:onSellKeyPressed(actionName, inputValue, callbackState, isAnalog)
    PDS_Main.log("onSellKeyPressed fired")
    PDS_Main.openSellingForSelected()
end

---A real, clickable button inside the vanilla Production menu, built by
-- cloning one of the menu's own bottom-bar buttons (the same technique the
-- FS25_BetterContracts mod uses to add buttons to a vanilla in-game menu
-- screen). This sidesteps the frame's fixed-size button-slot array entirely
-- - a genuine GuiElement the player can click always works, regardless of
-- how the surrounding menu happens to be wiring its own buttons that frame.
function PDS_Main.createSellButton()
    if PDS_Main.sellButton ~= nil then
        PDS_Main.log("createSellButton: already created, skipping")
        return
    end
    if g_inGameMenu == nil or g_inGameMenu.menuButton == nil or g_inGameMenu.menuButton[1] == nil then
        PDS_Main.log("createSellButton: ABORT - g_inGameMenu=%s menuButton=%s menuButton[1]=%s",
            tostring(g_inGameMenu), tostring(g_inGameMenu ~= nil and g_inGameMenu.menuButton or nil),
            tostring(g_inGameMenu ~= nil and g_inGameMenu.menuButton ~= nil and g_inGameMenu.menuButton[1] or nil))
        return
    end
    local template = g_inGameMenu.menuButton[1]
    PDS_Main.log("createSellButton: cloning template=%s parent=%s", tostring(template), tostring(template.parent))
    local ok, button = pcall(function() return template:clone(template.parent) end)
    if not ok then
        PDS_Main.log("createSellButton: clone() THREW: %s", tostring(button))
        return
    end
    PDS_Main.log("createSellButton: clone() returned %s", tostring(button))
    if button == nil then
        return
    end
    button:setText(g_i18n:getText("pds_action_openSelling"))
    button:setInputAction("PDS_OPEN_SELLING")
    button.onClickCallback = PDS_Main.onSellButtonClicked
    button:setDisabled(false)
    button:setVisible(false)
    if template.parent ~= nil and template.parent.invalidateLayout ~= nil then
        template.parent:invalidateLayout(true)
    end
    PDS_Main.sellButton = button
    PDS_Main.log("createSellButton: done, sellButton=%s", tostring(PDS_Main.sellButton))
end

function PDS_Main.onSellButtonClicked()
    PDS_Main.log("onSellButtonClicked fired")
    PDS_Main.openSellingForSelected()
end

---Shows the button only while a production the player owns, with something
-- actually in storage, is selected - exactly the gate the spec asks for.
function PDS_Main.updateSellButtonVisibility()
    if PDS_Main.sellButton == nil then
        PDS_Main.log("updateSellButtonVisibility: sellButton is nil, nothing to update")
        return
    end
    local productionPoint = PDS_Main.getSelectedOwnedProductionPoint()
    local productCount = productionPoint ~= nil and #PDS_Manager.getSellableProducts(productionPoint) or 0
    local visible = productionPoint ~= nil and productCount > 0
    PDS_Main.log("updateSellButtonVisibility: productionPoint=%s productCount=%d visible=%s",
        tostring(productionPoint ~= nil and productionPoint:getName() or nil), productCount, tostring(visible))
    PDS_Main.sellButton:setVisible(visible)
    if PDS_Main.sellButton.parent ~= nil and PDS_Main.sellButton.parent.invalidateLayout ~= nil then
        PDS_Main.sellButton.parent:invalidateLayout(true)
    end
end

function PDS_Main.installProductionMenuHook()
    if InGameMenuProductionFrame == nil then
        Logging.error("[ProductionDirectSell] InGameMenuProductionFrame not found, mod disabled")
        return
    end
    InGameMenuProductionFrame.onFrameOpen = Utils.appendedFunction(InGameMenuProductionFrame.onFrameOpen, PDS_Main.onProductionFrameOpen)
    InGameMenuProductionFrame.onFrameClose = Utils.appendedFunction(InGameMenuProductionFrame.onFrameClose, PDS_Main.onProductionFrameClose)
    InGameMenuProductionFrame.onListSelectionChanged = Utils.appendedFunction(InGameMenuProductionFrame.onListSelectionChanged, PDS_Main.onProductionListSelectionChanged)
    PDS_Main.log("installProductionMenuHook: hooks installed on InGameMenuProductionFrame")
end

---Opens the selling dialog for whatever production is currently selected in
-- the vanilla Production menu. Safe to call from the menu button or the key.
function PDS_Main.openSellingForSelected()
    PDS_Main.log("openSellingForSelected called")
    local productionPoint = PDS_Main.getSelectedOwnedProductionPoint()
    if productionPoint == nil then
        g_currentMission:showBlinkingWarning(g_i18n:getText("pds_warning_noProductionSelected"), 2000)
        return
    end
    local products = PDS_Manager.getSellableProducts(productionPoint)
    if #products == 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("pds_warning_nothingToSell"), 2000)
        return
    end
    if PDS_Main.sellingDialog == nil then
        return
    end
    PDS_Main.sellingDialog:setProductionPoint(productionPoint, products)
    g_gui:showDialog("PDS_SellingDialog")
end

-------------------------------------------------------------------------------
-- Sale request / result
-------------------------------------------------------------------------------

---Sends the sale to the server. The selling dialog stays open (and blocked)
-- until onSellResult() is called back.
function PDS_Main.requestSale(productionPoint, fillType, station, amount, feePercent)
    if g_client == nil then
        return
    end
    g_client:getServerConnection():sendEvent(PDS_SellRequestEvent.new(productionPoint, fillType, station, amount, feePercent))
end

---Called (client-side) once the server has replied to a PDS_SellRequestEvent.
function PDS_Main.onSellResult(success, quoteOrReasonKey)
    if success then
        local quote = quoteOrReasonKey
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("pds_notification_sold"), g_i18n:formatVolume(quote.amount, 0), quote.stationName, g_i18n:formatMoney(quote.payout, 0, true, true)), 4000)
    else
        local reasonKey = quoteOrReasonKey
        local textKey = PDS_Main.FAILURE_TEXT_KEYS[reasonKey] or "pds_error_generic"
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, g_i18n:getText(textKey), 4000)
    end
    if PDS_Main.sellingDialog ~= nil then
        PDS_Main.sellingDialog:onSaleFinished(success, quoteOrReasonKey)
    end
end

PDS_Main.FAILURE_TEXT_KEYS = {
    notServer = "pds_error_generic",
    invalidProduction = "pds_error_invalidProduction",
    invalidProduct = "pds_error_invalidProduct",
    invalidSellPoint = "pds_error_invalidSellPoint",
    nothingToSell = "pds_error_nothingToSell",
    notAccepted = "pds_error_invalidSellPoint",
}

addModEventListener(PDS_Main)
