PTGuiTitle = PTGuiComponent:Extend("title")
PTGuiTitle:ImportComponent("text", true, "SetText", "SetFont", "SetNonSpaceWrap", "SetJustifyH", "SetJustifyV", "SetTextColor")
PTGuiTitle:ImportComponent("text", false, "GetText", "GetFont", "GetStringWidth", "CanNonSpaceWrap", "GetJustifyH", "GetJustifyV", "GetTextColor")

function PTGuiTitle:New()
    local obj = setmetatable({}, self)
    local frame = CreateFrame("Frame", self:GenerateName(), nil)
    obj:SetHandle(frame)
    local tex = frame:CreateTexture(nil, "LOW")
    tex:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    tex:SetTexCoord(58 / 256, 197 / 256, 0 / 64, 40 / 64)
    tex:SetAllPoints()
    local text = PTGuiLib.Get("text", frame)
    obj:AddComponent("text", text)
    obj:SetPrimary()
    text:SetPoint("CENTER", frame, "CENTER")
    return obj
end

-- Route SetText through the text subcomponent (rather than the imported direct-to-handle setter)
-- so the title is localized by PTGuiText:SetText.
function PTGuiTitle:SetText(text)
    self:GetComponent("text"):SetText(text)
    return self
end

PTGuiLib.RegisterComponent(PTGuiTitle)