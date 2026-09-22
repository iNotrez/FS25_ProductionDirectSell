--
-- PDS_Manager
--
-- All the non-GUI, non-networking logic: which products a production point
-- currently has in stock, which sell points accept a given product (sorted
-- best price first, using the game's own vanilla price calculation), and the
-- actual server-authoritative sale (remove stored product, pay the farm).
--
-- Nothing in here talks to the network directly - PDS_SellRequestEvent calls
-- PDS_Manager.executeSale() once it has decided a request is worth running.
--

PDS_Manager = {}

PDS_Manager.MIN_FEE_PERCENT = 0.02
PDS_Manager.MAX_FEE_PERCENT = 0.18
PDS_Manager.MIN_SELL_LITERS = 1

---A random delivery fee for one transaction, 2%-18%. Call once per
-- product/sell-point selection and hold onto the result - never call this
-- again just to redraw the same screen.
function PDS_Manager.generateFeePercent()
    return PDS_Manager.MIN_FEE_PERCENT + math.random() * (PDS_Manager.MAX_FEE_PERCENT - PDS_Manager.MIN_FEE_PERCENT)
end

local function clamp(value, low, high)
    if value == nil then
        return low
    end
    return math.max(low, math.min(high, value))
end
PDS_Manager.clamp = clamp

---True if productionPoint is a live, owned production point we can sell from.
function PDS_Manager.isSellableProductionPoint(productionPoint, farmId)
    if productionPoint == nil or productionPoint.storage == nil or productionPoint.isDeleted then
        return false
    end
    if productionPoint.outputFillTypeIdsArray == nil or #productionPoint.outputFillTypeIdsArray == 0 then
        return false
    end
    local owner = productionPoint.getOwnerFarmId ~= nil and productionPoint:getOwnerFarmId() or productionPoint.ownerFarmId
    return owner ~= nil and owner ~= AccessHandler.EVERYONE and owner == farmId
end

---Products this production point actually has in storage right now (no 0L
-- entries, no outputs it merely knows how to make). Sorted alphabetically.
function PDS_Manager.getSellableProducts(productionPoint)
    local products = {}
    if productionPoint == nil or productionPoint.storage == nil or productionPoint.outputFillTypeIdsArray == nil then
        return products
    end
    for _, fillType in ipairs(productionPoint.outputFillTypeIdsArray) do
        local level = productionPoint.storage:getFillLevel(fillType)
        if level >= PDS_Manager.MIN_SELL_LITERS then
            local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillType)
            table.insert(products, {
                fillType = fillType,
                name = fillTypeDesc ~= nil and fillTypeDesc.title or tostring(fillType),
                available = level,
                capacity = productionPoint.storage:getCapacity(fillType),
            })
        end
    end
    table.sort(products, function(a, b) return a.name < b.name end)
    return products
end

---True if station is a real, still-existing selling station that buys fillType.
function PDS_Manager.isValidSellPoint(station, fillType)
    if station == nil or fillType == nil or station.isDeleted then
        return false
    end
    if not station:isa(SellingStation) then
        return false
    end
    return station:getIsFillTypeAllowed(fillType) == true
end

---Every sell point that accepts fillType, highest vanilla price first.
function PDS_Manager.getSellPoints(fillType)
    local points = {}
    if fillType == nil then
        return points
    end
    local stations = g_currentMission.storageSystem:getUnloadingStations()
    for _, station in pairs(stations) do
        if PDS_Manager.isValidSellPoint(station, fillType) and not station.hideFromPricesMenu then
            local price = station:getEffectiveFillTypePrice(fillType)
            if price ~= nil and price > 0 then
                table.insert(points, {
                    station = station,
                    name = station:getName(),
                    price = price,
                    trend = station.getCurrentPricingTrend ~= nil and station:getCurrentPricingTrend(fillType) or 0,
                })
            end
        end
    end
    table.sort(points, function(a, b) return a.price > b.price end)
    return points
end

---Builds the numbers the confirm screen and receipt both show, without
-- touching any game state. feePercent may be nil (a fresh one is rolled).
function PDS_Manager.buildQuote(pricePerLiter, amount, feePercent)
    local gross = pricePerLiter * amount
    local fee = clamp(feePercent, PDS_Manager.MIN_FEE_PERCENT, PDS_Manager.MAX_FEE_PERCENT)
    local feeAmount = gross * fee
    local payout = gross - feeAmount
    return {
        pricePerLiter = pricePerLiter,
        amount = amount,
        feePercent = fee,
        gross = gross,
        feeAmount = feeAmount,
        payout = payout,
    }
end

---Server-authoritative sale. Re-derives price and farm from live game state -
-- never trusts a client-sent price. Returns success, quoteOrReasonKey.
function PDS_Manager.executeSale(productionPoint, fillType, station, amount, feePercent)
    if not g_currentMission:getIsServer() then
        return false, "notServer"
    end

    local farmId = productionPoint ~= nil and (productionPoint.getOwnerFarmId ~= nil and productionPoint:getOwnerFarmId() or productionPoint.ownerFarmId) or nil
    if not PDS_Manager.isSellableProductionPoint(productionPoint, farmId) then
        return false, "invalidProduction"
    end

    if not table.hasElement(productionPoint.outputFillTypeIdsArray, fillType) then
        return false, "invalidProduct"
    end

    if not PDS_Manager.isValidSellPoint(station, fillType) then
        return false, "invalidSellPoint"
    end

    local available = productionPoint.storage:getFillLevel(fillType)
    local sellAmount = clamp(amount, 0, available)
    if sellAmount < PDS_Manager.MIN_SELL_LITERS then
        return false, "nothingToSell"
    end

    local pricePerLiter = station:getEffectiveFillTypePrice(fillType)
    if pricePerLiter == nil or pricePerLiter <= 0 then
        return false, "notAccepted"
    end

    local quote = PDS_Manager.buildQuote(pricePerLiter, sellAmount, feePercent)
    quote.fillType = fillType
    quote.farmId = farmId
    quote.productionPointName = productionPoint:getName()
    quote.stationName = station:getName()

    productionPoint.storage:setFillLevel(available - sellAmount, fillType)
    g_currentMission:addMoney(quote.payout, farmId, MoneyType.SOLD_PRODUCTS, true, true)

    return true, quote
end
