-- Uses the game's reflected GI_SMB auto-skip switch; never enables speedrun mode.
local M = {}
local saved = {}
local log = function() end
local function instances()
    return FindAllOf('GI_SMB_C') or {}
end
local function apply(instance, enabled)
    if not instance:IsValid() or instance:GetFullName():find('Default__', 1, true) then return end
    local key = tostring(instance:GetAddress())
    if enabled then
        local value = instance:GetPropertyValue('bAutoSkip')
        if type(value) ~= 'boolean' then return end
        if not saved[key] then saved[key] = {value=value} end
        if value ~= true then
            instance:SetPropertyValue('bAutoSkip', true)
            log('MAP_AUTOSKIP enabled bAutoSkip on ' .. instance:GetFullName())
        end
    elseif saved[key] then
        instance:SetPropertyValue('bAutoSkip', saved[key].value)
        saved[key] = nil
        log('MAP_AUTOSKIP restored bAutoSkip on ' .. instance:GetFullName())
    end
end
function M.beforeTravel(isMap)
    for _, instance in ipairs(instances()) do apply(instance, isMap) end
end
function M.update()
    for _, instance in ipairs(instances()) do
        local ok, name = pcall(function() return instance:GetWorld():GetFullName() end)
        -- Unknown/transitional world: preserve the pre-travel decision.
        if ok and name then apply(instance, name:find('L_WorldMap', 1, true) ~= nil) end
    end
end
function M.initialize(logger) log = logger; M.update() end
return M
