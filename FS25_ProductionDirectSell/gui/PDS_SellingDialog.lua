--
-- PDS_SellingDialog
--
-- The "SELLING" screen: pick a product actually in storage, pick a sell
-- point (best price first, using the game's real vanilla prices), pick an
-- amount, see the gross value / random delivery fee / final payout, then
-- confirm. Nothing is sold until PDS_ConfirmDialog's confirm callback fires.
--

PDS_SellingDialog = {}
local PDS_SellingDialog_mt = Class(PDS_SellingDialog, MessageDialog)

local COLOR = PDS_ConfirmDialog ~= nil and PDS_ConfirmDialog.COLOR or {
    value = { 0.96, 0.96, 0.96, 1 },
    green = { 0.49, 0.80, 0.20, 1 },
    orange = { 1.00, 0.66, 0.20, 1 },
    red = { 0.95, 0.33, 0.30, 1 },
}

function PDS_SellingDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or PDS_SellingDialog_mt)
    self.productionPoint = nil
    self.products = {}
    self.sellPoints = {}
    self.selectedProductIndex = nil
    self.selectedSellPointIndex = nil
    self.currentFeePercent = nil
    self.pendingAmount = 0
    self.isBusy = false
    self.isShown = false
    return self
end

local function setText(element, text)
    if element ~= nil and element.setText ~= nil then
        element:setText(text ~= nil and tostring(text) or "")
    end
end

local function setVisible(element, visible)
    if element ~= nil and element.setVisible ~= nil then
        element:setVisible(visible == true)
    end
end

local function setDisabled(element, disabled)
    if element ~= nil and element.setDisabled ~= nil then
        element:setDisabled(disabled == true)
    end
end

local function money(value)
    return g_i18n:formatMoney(value or 0, 0, true, true)
end

local function volume(value)
    return g_i18n:formatVolume(value or 0, 0)
end

function PDS_SellingDialog:onGuiSetupFinished()
    PDS_SellingDialog:superClass().onGuiSetupFinished(self)
    self.productList:setDataSource(self)
    self.productList:setDelegate(self)
    self.sellPointList:setDataSource(self)
    self.sellPointList:setDelegate(self)
end

---Called by PDS_Main right before the dialog is shown.
function PDS_SellingDialog:setProductionPoint(productionPoint, products)
    self.productionPoint = productionPoint
    self.products = products or {}
    self.selectedProductIndex = #self.products > 0 and 1 or nil
    self.sellPoints = {}
    self.selectedSellPointIndex = nil
    self.currentFeePercent = nil
    self.isBusy = false
end

function PDS_SellingDialog:onOpen()
    PDS_SellingDialog:superClass().onOpen(self)
    self.isShown = true
    setText(self.productionNameText, self.productionPoint ~= nil and self.productionPoint:getName() or "")
    setText(self.messageText, "")
    self:setBusy(false)
    self.productList:reloadData()
    setVisible(self.productsEmptyText, #self.products == 0)
    if self.selectedProductIndex ~= nil then
        self:setSelectedIndexQuiet(self.productList, self.selectedProductIndex)
    end
    self:refreshSellPointsForSelectedProduct()
    FocusManager:setFocus(self.productList)
end

function PDS_SellingDialog:onClose()
    PDS_SellingDialog:superClass().onClose(self)
    self.isShown = false
    self.productionPoint = nil
end

-------------------------------------------------------------------------------
-- list data source / delegate (both lists share this controller, like the
-- vanilla InGameMenuProductionFrame does for its own two lists)
-------------------------------------------------------------------------------

function PDS_SellingDialog:getNumberOfSections(list)
    return 1
end

function PDS_SellingDialog:getNumberOfItemsInSection(list, section)
    if list == self.productList then
        return #self.products
    elseif list == self.sellPointList then
        return #self.sellPoints
    end
    return 0
end

function PDS_SellingDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.productList then
        local product = self.products[index]
        cell:getAttribute("name"):setText(product.name)
        cell:getAttribute("amount"):setText(volume(product.available))
    elseif list == self.sellPointList then
        local sellPoint = self.sellPoints[index]
        local marker = index == self.selectedSellPointIndex and "> " or ""
        cell:getAttribute("name"):setText(marker .. sellPoint.name)
        local priceElement = cell:getAttribute("price")
        priceElement:setText(string.format(g_i18n:getText("pds_format_pricePer1000"), money(sellPoint.price * 1000)))
        if Utils.isBitSet(sellPoint.trend, SellingStation.PRICE_CLIMBING) then
            priceElement:applyProfile("pdsRowValueTextUp", true)
        elseif Utils.isBitSet(sellPoint.trend, SellingStation.PRICE_FALLING) then
            priceElement:applyProfile("pdsRowValueTextDown", true)
        else
            priceElement:applyProfile("pdsRowValueText", true)
        end
    end
end

function PDS_SellingDialog:onProductSelectionChanged(list, section, index)
    if list ~= self.productList or index == nil or self.suppressSelectionCallback then
        return
    end
    self.selectedProductIndex = index
    self:refreshSellPointsForSelectedProduct()
end

function PDS_SellingDialog:onSellPointSelectionChanged(list, section, index)
    if list ~= self.sellPointList or index == nil or self.suppressSelectionCallback then
        return
    end
    self.selectedSellPointIndex = index
    self.currentFeePercent = PDS_Manager.generateFeePercent()
    self:resetAmountToAvailable()
    self.sellPointList:reloadData()
    self:updateSummary()
end

---Sets a list's selected index without re-triggering our own
-- onXSelectionChanged handler (which would re-roll the fee needlessly).
function PDS_SellingDialog:setSelectedIndexQuiet(list, index)
    self.suppressSelectionCallback = true
    list:setSelectedIndex(index)
    self.suppressSelectionCallback = false
end

-------------------------------------------------------------------------------
-- state helpers
-------------------------------------------------------------------------------

function PDS_SellingDialog:getSelectedProduct()
    if self.selectedProductIndex == nil then
        return nil
    end
    return self.products[self.selectedProductIndex]
end

function PDS_SellingDialog:getSelectedSellPoint()
    if self.selectedSellPointIndex == nil then
        return nil
    end
    return self.sellPoints[self.selectedSellPointIndex]
end

function PDS_SellingDialog:refreshSellPointsForSelectedProduct()
    local product = self:getSelectedProduct()
    self.sellPoints = product ~= nil and PDS_Manager.getSellPoints(product.fillType) or {}
    self.selectedSellPointIndex = #self.sellPoints > 0 and 1 or nil
    self.currentFeePercent = #self.sellPoints > 0 and PDS_Manager.generateFeePercent() or nil
    self:resetAmountToAvailable()
    self.sellPointList:reloadData()
    setVisible(self.sellPointsEmptyText, #self.sellPoints == 0)
    if self.selectedSellPointIndex ~= nil then
        self:setSelectedIndexQuiet(self.sellPointList, self.selectedSellPointIndex)
    end
    self:updateSummary()
end

function PDS_SellingDialog:resetAmountToAvailable()
    local product = self:getSelectedProduct()
    self.pendingAmount = product ~= nil and product.available or 0
    self.amountText = product ~= nil and string.format("%d", math.floor(product.available)) or ""
    setText(self.amountInput, self.amountText)
end

---Clamps self.amountText (the last text the player typed) against the
-- currently selected product's available amount.
function PDS_SellingDialog:parseAmountText()
    local product = self:getSelectedProduct()
    local available = product ~= nil and product.available or 0
    local value = tonumber(self.amountText)
    if value == nil then
        return 0
    end
    return PDS_Manager.clamp(value, 0, available)
end

function PDS_SellingDialog:onAmountTextChanged(element, text)
    text = text or ""
    if text ~= "" and text:find("[^%d%.]") then
        text = element.lastValidAmountText or ""
        element:setText(text)
    end
    element.lastValidAmountText = text
    self.amountText = text
    self.pendingAmount = self:parseAmountText()
    self:updateSummary()
end

function PDS_SellingDialog:onAmountEnterPressed(element, text)
    local amount = self:parseAmountText()
    self.pendingAmount = amount
    self.amountText = string.format("%d", math.floor(amount))
    element.lastValidAmountText = self.amountText
    setText(self.amountInput, self.amountText)
    self:updateSummary()
end

---Refreshes every label in the summary panel from current selection/amount.
function PDS_SellingDialog:updateSummary()
    local product = self:getSelectedProduct()
    local sellPoint = self:getSelectedSellPoint()

    setText(self.availableText, product ~= nil and volume(product.available) or "-")
    setText(self.sellPointNameText, sellPoint ~= nil and sellPoint.name or g_i18n:getText("pds_value_noSellPoint"))
    setText(self.priceText, sellPoint ~= nil and string.format(g_i18n:getText("pds_format_pricePer1000"), money(sellPoint.price * 1000)) or "-")

    local canSell = product ~= nil and sellPoint ~= nil and self.currentFeePercent ~= nil
    setDisabled(self.sellAllButton, not canSell or self.isBusy)
    setDisabled(self.sellCustomButton, not canSell or self.isBusy)
    setDisabled(self.amountInput, not canSell or self.isBusy)

    if not canSell then
        setText(self.grossText, "-")
        setText(self.feeText, "-")
        setText(self.payoutText, "-")
        return
    end

    local quote = PDS_Manager.buildQuote(sellPoint.price, self.pendingAmount, self.currentFeePercent)
    setText(self.grossText, money(quote.gross))
    setText(self.feeText, string.format(g_i18n:getText("pds_format_fee"), quote.feePercent * 100, money(quote.feeAmount)))
    setText(self.payoutText, money(quote.payout))
end

function PDS_SellingDialog:setBusy(busy)
    self.isBusy = busy
    self:updateSummary()
end

-------------------------------------------------------------------------------
-- selling
-------------------------------------------------------------------------------

function PDS_SellingDialog:tryOpenConfirm(amount)
    local product = self:getSelectedProduct()
    local sellPoint = self:getSelectedSellPoint()
    if product == nil or sellPoint == nil or self.currentFeePercent == nil then
        return
    end
    amount = PDS_Manager.clamp(amount, 0, product.available)
    if amount < PDS_Manager.MIN_SELL_LITERS then
        setText(self.messageText, g_i18n:getText("pds_error_amountTooLow"))
        return
    end

    local quote = PDS_Manager.buildQuote(sellPoint.price, amount, self.currentFeePercent)

    PDS_Main.confirmDialog:setContent({
        title = g_i18n:getText("pds_title_confirmSale"),
        subtitle = product.name,
        rows = {
            { label = g_i18n:getText("pds_label_amount"), value = volume(amount) },
            { label = g_i18n:getText("pds_label_sellPoint"), value = sellPoint.name },
            { label = g_i18n:getText("pds_label_price"), value = string.format(g_i18n:getText("pds_format_pricePer1000"), money(sellPoint.price * 1000)) },
            { label = g_i18n:getText("pds_label_gross"), value = money(quote.gross) },
            { label = g_i18n:getText("pds_label_fee"), value = string.format(g_i18n:getText("pds_format_fee"), quote.feePercent * 100, money(quote.feeAmount)), color = COLOR.orange },
            { label = g_i18n:getText("pds_label_youReceive"), value = money(quote.payout), color = COLOR.green },
        },
        message = g_i18n:getText("pds_message_confirmSale"),
        confirmText = g_i18n:getText("pds_button_confirmSale"),
        cancelText = g_i18n:getText("pds_button_cancel"),
        accent = COLOR.green,
        callback = function(confirmed)
            if confirmed then
                self:sendSaleRequest(product.fillType, sellPoint.station, amount, quote.feePercent)
            end
        end,
    })
    g_gui:showDialog("PDS_ConfirmDialog")
end

function PDS_SellingDialog:sendSaleRequest(fillType, station, amount, feePercent)
    self:setBusy(true)
    setText(self.messageText, g_i18n:getText("pds_message_selling"))
    PDS_Main.requestSale(self.productionPoint, fillType, station, amount, feePercent)
end

---Called by PDS_Main.onSellResult once the server has replied.
function PDS_SellingDialog:onSaleFinished(success, quoteOrReasonKey)
    if not self.isShown then
        return
    end
    if success then
        self:close()
        return
    end
    self:setBusy(false)
    setText(self.messageText, g_i18n:getText(PDS_Main.FAILURE_TEXT_KEYS[quoteOrReasonKey] or "pds_error_generic"))
    -- storage may have changed underneath us (partial sale, another player, ...) - refresh
    if self.productionPoint ~= nil then
        self.products = PDS_Manager.getSellableProducts(self.productionPoint)
        self.productList:reloadData()
        self:refreshSellPointsForSelectedProduct()
    end
end

function PDS_SellingDialog:onClickSellAll()
    local product = self:getSelectedProduct()
    if product ~= nil then
        self:tryOpenConfirm(product.available)
    end
end

function PDS_SellingDialog:onClickSellCustom()
    local amount = self:parseAmountText()
    self:tryOpenConfirm(amount)
end

function PDS_SellingDialog:onClickCancel()
    self:close()
end
