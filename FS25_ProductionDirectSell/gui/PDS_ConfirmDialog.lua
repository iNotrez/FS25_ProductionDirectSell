--
-- PDS_ConfirmDialog
--
-- Generic confirmation / message dialog, reused for "CONFIRM SALE" and for
-- plain error/info popups.
--
--   PDS_Main.confirmDialog:setContent({
--       title = "CONFIRM SALE",
--       subtitle = "Bread",
--       rows = { {label = "Amount", value = "2,500 L"}, ... },  -- max 7
--       message = "optional paragraph",
--       confirmText = "Confirm sale",   -- nil = information only (single OK button)
--       cancelText = "Cancel",
--       accent = COLOR.green,
--       callback = function(confirmed) end,
--   })
--

PDS_ConfirmDialog = {}
local PDS_ConfirmDialog_mt = Class(PDS_ConfirmDialog, MessageDialog)

PDS_ConfirmDialog.MAX_ROWS = 7

PDS_ConfirmDialog.COLOR = {
    value = { 0.96, 0.96, 0.96, 1 },
    green = { 0.49, 0.80, 0.20, 1 },
    orange = { 1.00, 0.66, 0.20, 1 },
    red = { 0.95, 0.33, 0.30, 1 },
}

function PDS_ConfirmDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or PDS_ConfirmDialog_mt)
    self.content = nil
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

local function setTextColor(element, color)
    if element ~= nil and element.setTextColor ~= nil and color ~= nil then
        element:setTextColor(color[1], color[2], color[3], color[4])
    end
end

local function setImageColor(element, color)
    if element ~= nil and element.setImageColor ~= nil and color ~= nil then
        element:setImageColor(nil, color[1], color[2], color[3], color[4])
    end
end

function PDS_ConfirmDialog:setContent(content)
    self.content = content or {}
    if self.isShown then
        self:updateContent()
    end
end

function PDS_ConfirmDialog:onOpen()
    PDS_ConfirmDialog:superClass().onOpen(self)
    self.isShown = true
    self:updateContent()
end

function PDS_ConfirmDialog:onClose()
    PDS_ConfirmDialog:superClass().onClose(self)
    self.isShown = false
end

function PDS_ConfirmDialog:isInfoOnly()
    return self.content == nil or self.content.confirmText == nil
end

function PDS_ConfirmDialog:updateContent()
    local content = self.content or {}
    setText(self.titleText, content.title or "")
    setText(self.subtitleText, content.subtitle or "")
    setImageColor(self.accentBar, content.accent or PDS_ConfirmDialog.COLOR.green)

    local rows = content.rows or {}
    for i = 1, PDS_ConfirmDialog.MAX_ROWS do
        local row = rows[i]
        local label = self["rowLabel" .. i]
        local value = self["rowValue" .. i]
        setVisible(label, row ~= nil)
        setVisible(value, row ~= nil)
        if row ~= nil then
            setText(label, row.label or "")
            setText(value, row.value or "")
            setTextColor(value, row.color or PDS_ConfirmDialog.COLOR.value)
        end
    end

    setText(self.messageText, content.message or "")

    local infoOnly = self:isInfoOnly()
    setVisible(self.backButton, not infoOnly)
    setDisabled(self.backButton, infoOnly)
    setVisible(self.buttonSeparator, not infoOnly)
    if self.confirmButton ~= nil then
        self.confirmButton:setText(infoOnly and g_i18n:getText("button_ok") or content.confirmText)
    end
    if self.backButton ~= nil and content.cancelText ~= nil then
        self.backButton:setText(content.cancelText)
    end
    if self.backButton ~= nil and self.backButton.parent ~= nil and self.backButton.parent.invalidateLayout ~= nil then
        self.backButton.parent:invalidateLayout()
    end
end

function PDS_ConfirmDialog:finish(confirmed)
    local callback = self.content ~= nil and self.content.callback or nil
    self:close()
    if callback ~= nil then
        callback(confirmed)
    end
end

function PDS_ConfirmDialog:onClickConfirm()
    self:finish(true)
end

function PDS_ConfirmDialog:onClickBack()
    self:finish(false)
end

---Esc also closes an information-only dialog (its Back button is hidden).
function PDS_ConfirmDialog:inputEvent(action, value, eventUsed)
    eventUsed = PDS_ConfirmDialog:superClass().inputEvent(self, action, value, eventUsed)
    if not eventUsed and self.isShown and self:isInfoOnly() and InputAction ~= nil and action == InputAction.MENU_BACK then
        self:finish(false)
        eventUsed = true
    end
    return eventUsed
end
