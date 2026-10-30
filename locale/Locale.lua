PTLocale = {}
PTUtil.SetEnvironment(PTLocale)
local compost = AceLibrary("Compost-2.0")

Translations = nil

-- Set to true to enable the ability to dump all things that need translations
local EXPORT_MODE = false

function SetTranslations(translations)
    Translations = translations

    if not EXPORT_MODE then
        -- Non-English version
        function Translate(str)
            return Translations[str] or str
        end
        T = Translate
    end
end

function AddTranslations(translations)
    if not Translations then
        SetTranslations(translations)
        return
    end
    for key, value in pairs(translations) do
        Translations[key] = value
    end
end

function TranslateKey(key, fallback)
    local translated = Translate(key)
    if translated ~= key then
        return translated
    end
    return fallback or key
end

TK = TranslateKey

function IsUsingTranslations()
    return Translations ~= nil or EXPORT_MODE
end

-- English version
function Translate(str)
    return str
end

if EXPORT_MODE then
    NeedsTranslation = {}

    function Translate(str)
        if not PTUtil.ArrayContains(NeedsTranslation, str) then
            table.insert(NeedsTranslation, str)
        end
        return Translations and Translations[str] or str
    end

    -- /run PTLocale.ExportNeedsTranslate()
    function ExportNeedsTranslate()
        local needsTranslate = table.concat(NeedsTranslation, "\n")
        ExportFile("NeedsTranslate", needsTranslate)
    end
end

T = Translate

-- String-safe translate for UI display text. Translates strings via the active Translate
-- function (resolved dynamically, so it respects SetTranslations), and passes through any
-- non-string value (numbers, nil) untouched. Used by the GUI components to localize labels
-- without disturbing dynamic/non-text values.
function TranslateText(text)
    if type(text) == "string" then
        return Translate(text)
    end
    return text
end

function TranslateTextKey(key, text)
    if type(text) == "string" then
        return TranslateKey(key, text)
    end
    return text
end

function TranslateAura(name)
    if name == "Power Word:Fortitude" then
        name = "Power Word: Fortitude"
    end
    return TranslateKey("Aura."..name, Translate(name))
end

TA = TranslateAura

function AuraArray(array)
    if not IsUsingTranslations() then
        return
    end
    for i, value in ipairs(array) do
        array[i] = TranslateAura(value)
    end
end

function AuraKeys(set)
    if not IsUsingTranslations() then
        return
    end
    local toInsert = compost:GetTable()
    for key, value in pairs(set) do
        set[key] = nil
        toInsert[TranslateAura(key)] = value
    end
    for key, value in pairs(toInsert) do
        set[key] = value
    end
    compost:Reclaim(toInsert)
end

function AuraValues(table)
    if not IsUsingTranslations() then
        return
    end
    for key, value in pairs(table) do
        table[key] = TranslateAura(value)
    end
end

function Keys(set)
    if not IsUsingTranslations() then
        return
    end
    local toInsert = compost:GetTable()
    for key, value in pairs(set) do
        local translated = Translate(key)
        if translated then
            set[key] = nil
            toInsert[Translate(key)] = value
        end
    end
    for key, value in pairs(toInsert) do
        set[key] = value
    end
    compost:Reclaim(toInsert)
end

function Values(table)
    if not IsUsingTranslations() then
        return
    end
    for key, value in pairs(table) do
        table[key] = Translate(value)
    end
end

function KeysValues(table)
    if not IsUsingTranslations() then
        return
    end
    local toInsert = compost:GetTable()
    for key, value in pairs(table) do
        local translated = Translate(key)
        if translated then
            table[key] = nil
            toInsert[translated] = Translate(value)
        end
    end
    for key, value in pairs(toInsert) do
        table[key] = value
    end
    compost:Reclaim(toInsert)
end

function Array(array)
    if not IsUsingTranslations() then
        return
    end
    for i, value in ipairs(array) do
        array[i] = Translate(value)
    end
end