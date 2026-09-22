--
-- PDS_SellRequestEvent
--
-- One event class, two directions (same pattern as the vanilla game's own
-- request/reply events):
--   client -> server : "sell this much of this product from this production
--                        at this sell point, here's the fee I showed the player"
--   server -> client : "here's what actually happened" (success + final
--                        numbers, or a failure reason)
--
-- The server never trusts the client for price or ownership - it only trusts
-- the requested amount and fee, and even the fee gets clamped back into
-- 2%-18% in PDS_Manager.executeSale. Price, farm and validity are all
-- re-derived from live server state.
--

PDS_SellRequestEvent = {}
local PDS_SellRequestEvent_mt = Class(PDS_SellRequestEvent, Event)
InitEventClass(PDS_SellRequestEvent, "PDS_SellRequestEvent")

function PDS_SellRequestEvent.emptyNew()
    return Event.new(PDS_SellRequestEvent_mt)
end

---Client -> server request.
function PDS_SellRequestEvent.new(productionPoint, fillType, station, amount, feePercent)
    local self = PDS_SellRequestEvent.emptyNew()
    self.isReply = false
    self.productionPoint = productionPoint
    self.fillType = fillType
    self.station = station
    self.amount = amount
    self.feePercent = feePercent
    return self
end

---Server -> client reply.
function PDS_SellRequestEvent.newReply(success, quoteOrReason)
    local self = PDS_SellRequestEvent.emptyNew()
    self.isReply = true
    self.success = success == true
    if self.success then
        self.quote = quoteOrReason
    else
        self.reasonKey = quoteOrReason
    end
    return self
end

function PDS_SellRequestEvent:readStream(streamId, connection)
    self.isReply = streamReadBool(streamId)
    if not self.isReply then
        self.productionPoint = NetworkUtil.readNodeObject(streamId)
        self.fillType = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        self.station = NetworkUtil.readNodeObject(streamId)
        self.amount = streamReadFloat32(streamId)
        self.feePercent = streamReadFloat32(streamId)
    else
        self.success = streamReadBool(streamId)
        if self.success then
            self.quote = {
                fillType = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS),
                amount = streamReadFloat32(streamId),
                pricePerLiter = streamReadFloat32(streamId),
                feePercent = streamReadFloat32(streamId),
                gross = streamReadFloat32(streamId),
                feeAmount = streamReadFloat32(streamId),
                payout = streamReadFloat32(streamId),
                productionPointName = streamReadString(streamId),
                stationName = streamReadString(streamId),
            }
        else
            self.reasonKey = streamReadString(streamId)
        end
    end
    self:run(connection)
end

function PDS_SellRequestEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isReply)
    if not self.isReply then
        NetworkUtil.writeNodeObject(streamId, self.productionPoint)
        streamWriteUIntN(streamId, self.fillType, FillTypeManager.SEND_NUM_BITS)
        NetworkUtil.writeNodeObject(streamId, self.station)
        streamWriteFloat32(streamId, self.amount)
        streamWriteFloat32(streamId, self.feePercent or 0)
    else
        streamWriteBool(streamId, self.success)
        if self.success then
            local quote = self.quote
            streamWriteUIntN(streamId, quote.fillType, FillTypeManager.SEND_NUM_BITS)
            streamWriteFloat32(streamId, quote.amount)
            streamWriteFloat32(streamId, quote.pricePerLiter)
            streamWriteFloat32(streamId, quote.feePercent)
            streamWriteFloat32(streamId, quote.gross)
            streamWriteFloat32(streamId, quote.feeAmount)
            streamWriteFloat32(streamId, quote.payout)
            streamWriteString(streamId, quote.productionPointName or "")
            streamWriteString(streamId, quote.stationName or "")
        else
            streamWriteString(streamId, self.reasonKey or "unknown")
        end
    end
end

function PDS_SellRequestEvent:run(connection)
    if self.isReply then
        -- we are the client: hand the result to whoever is waiting on it
        if connection:getIsServer() then
            PDS_Main.onSellResult(self.success, self.success and self.quote or self.reasonKey)
        end
        return
    end

    -- we are the server: a client asked us to run a sale
    if connection:getIsServer() then
        return
    end

    local success, quoteOrReason = PDS_Manager.executeSale(self.productionPoint, self.fillType, self.station, self.amount, self.feePercent)
    connection:sendEvent(PDS_SellRequestEvent.newReply(success, quoteOrReason))
end
