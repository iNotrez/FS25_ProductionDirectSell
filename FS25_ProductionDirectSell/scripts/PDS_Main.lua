--
-- PDS_Main
--
-- Entry point (the only file listed in modDesc.xml). Wires the mod into the
-- game's life cycle and into the vanilla Production menu:
--
--   loadMap            load GUI profiles + dialogs
--   InGameMenuProductionFrame.onFrameOpen/onFrameClose (appended)
--                       register/unregister the PDS_OPEN_SELLING key for as
--                       long as the Production menu is actually open
--   openSellingForSelected  grab the selected production point and open
--                       the selling dialog
--   requestSale / onSellResult  send the sale to the server, show the result
--
-- Note on the keybind: this does NOT use the vanilla menuButtonInfo /
-- bottom-bar-button system. That system only wires up as many buttons as
-- there are physical button slots in the frame's own layout (a small fixed
-- number) - the Production frame can already use all of them itself
-- (Back/Next/Prev plus Activate/Toggle-mode or Tag/Visit depending on what's
-- focused), so a button appended on top of those is silently dropped and its
-- key never gets registered. Registering our own action event directly on
-- frame open/close sidesteps that limit entirely and is guaranteed to work.
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

function PDS_Main:loadMap(filename)
    if g_gui == nil then
        Logging.error("[ProductionDirectSell] g_gui not available, mod disabled")
        return
    end

    g_gui:loadProfiles(PDS_Main.MOD_DIRECTORY .. "gui/guiProfiles.xml")

    PDS_Main.confirmDialog = PDS_ConfirmDialog.new()
    g_gui:loadGui(PDS_Main.MOD_DIRECTORY .. "gui/PDS_ConfirmDialog.xml", "PDS_ConfirmDialog", PDS_Main.confirmDialog)

    PDS_Main.sellingDialog = PDS_SellingDialog.new()
    g_gui:loadGui(PDS_Main.MOD_DIRECTORY .. "gui/PDS_SellingDialog.xml", "PDS_SellingDialog", PDS_Main.sellingDialog)

    PDS_Main.installProductionMenuHook()
end

function PDS_Main:deleteMap()
    PDS_Main.confirmDialog = nil
    PDS_Main.sellingDialog = nil
    PDS_Main.sellKeyEventId = nil
end

-------------------------------------------------------------------------------
-- Production menu integration
-------------------------------------------------------------------------------

---Only true while the player has an owned production selected/open in the
-- vanilla Production menu - exactly the gate the spec asks for.
function PDS_Main.getSelectedOwnedProductionPoint()
    local inGameMenu = g_currentMission ~= nil and g_currentMission.inGameMenu or nil
    local pageProduction = inGameMenu ~= nil and inGameMenu.pageProduction or nil
    if pageProduction == nil or pageProduction.getSelectedProduction == nil then
        return nil
    end
    if pageProduction.pointsSelector == nil or pageProduction.pointsSelector:getState() ~= InGameMenuProductionFrame.POINTS_OWNED then
        return nil
    end
    local _, productionPoint = pageProduction:getSelectedProduction()
    local farmId = g_currentMission:getFarmId()
    if not PDS_Manager.isSellableProductionPoint(productionPoint, farmId) then
        return nil
    end
    return productionPoint
end

---Registers the PDS_OPEN_SELLING key for as long as the Production frame is
-- open. Safe to call more than once (guarded by sellKeyEventId).
function PDS_Main.onProductionFrameOpen(pageProduction)
    if pageProduction ~= g_currentMission.inGameMenu.pageProduction or PDS_Main.sellKeyEventId ~= nil then
        return
    end
    local _, eventId = g_inputBinding:registerActionEvent(InputAction.PDS_OPEN_SELLING, PDS_Main, PDS_Main.onSellKeyPressed, false, true, false, true)
    if eventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(eventId, false)
        PDS_Main.sellKeyEventId = eventId
    end
end

function PDS_Main.onProductionFrameClose(pageProduction)
    if pageProduction ~= g_currentMission.inGameMenu.pageProduction or PDS_Main.sellKeyEventId == nil then
        return
    end
    g_inputBinding:removeActionEvent(PDS_Main.sellKeyEventId)
    PDS_Main.sellKeyEventId = nil
end

function PDS_Main:onSellKeyPressed(actionName, inputValue, callbackState, isAnalog)
    PDS_Main.openSellingForSelected()
end

function PDS_Main.installProductionMenuHook()
    if InGameMenuProductionFrame == nil then
        Logging.error("[ProductionDirectSell] InGameMenuProductionFrame not found, mod disabled")
        return
    end
    InGameMenuProductionFrame.onFrameOpen = Utils.appendedFunction(InGameMenuProductionFrame.onFrameOpen, PDS_Main.onProductionFrameOpen)
    InGameMenuProductionFrame.onFrameClose = Utils.appendedFunction(InGameMenuProductionFrame.onFrameClose, PDS_Main.onProductionFrameClose)
end

---Opens the selling dialog for whatever production is currently selected in
-- the vanilla Production menu. Safe to call from the menu button or the key.
function PDS_Main.openSellingForSelected()
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
