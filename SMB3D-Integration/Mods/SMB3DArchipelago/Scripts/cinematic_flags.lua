-- Suppress vanilla world-map unlock scenes using the game's own "seen" setters.
local M = {}
local cached = {}
local log = function() end
local library
local setters = {'SetWorldUnlockSequencePlayed', 'SetDarkWorldSequencePlayed', 'SetBossUnlockSequencePlayed'}

local function schema(name)
    if cached[name] then return cached[name] end
    local fn = StaticFindObject('/Script/SMB.SaveSlotDataLibrary:' .. name)
    if not fn:IsValid() then log('CINEMATIC_FLAG_MISSING ' .. name); return end
    local fields = {}
    fn:ForEachProperty(function(property)
        local field = property:GetFName():ToString()
        if field ~= 'ReturnValue' then
            fields[#fields + 1] = {name=field, type=property:GetFullName():match('^(%S+)')}
            log('CINEMATIC_FLAG_SCHEMA ' .. property:GetFullName())
        end
    end)
    cached[name] = {fn=fn, fields=fields}
    return cached[name]
end

local function mark(name, context, asset)
    local data = schema(name)
    if not data then return end
    local arguments = {}
    for _, field in ipairs(data.fields) do
        local lower = field.name:lower()
        local value
        if field.name == 'WorldContextObject' then value = context
        elseif field.type == 'StrProperty' and lower:find('level',1,true) then value = asset
        elseif field.type == 'NameProperty' and lower:find('level',1,true) then value = FName(asset)
        elseif field.type == 'IntProperty' and lower:find('world',1,true) then
            value = library():GetWorldIDFromLevel(asset)
        elseif field.type == 'BoolProperty' and (lower:find('played',1,true) or lower:find('value',1,true)) then
            value = true
        else
            log('CINEMATIC_FLAG_UNSUPPORTED ' .. name .. '.' .. field.name .. ' ' .. tostring(field.type))
            return
        end
        arguments[#arguments + 1] = value
    end
    library():CallFunction(data.fn, table.unpack(arguments))
    log('WORLDMAP_SEQUENCE_MARKED_SEEN ' .. name .. ' ' .. asset)
end

function M.initialize(libraryGetter, logger)
    library=libraryGetter; log=logger
end
function M.beforeMap(context, bossAssets)
    if not context or not context:IsValid() then return end
    for w=1,5 do
        local asset = 'L_W' .. w .. '_L01'
        for _, name in ipairs({'SetWorldUnlockSequencePlayed', 'SetDarkWorldSequencePlayed'}) do
            local ok, err = pcall(mark, name, context, asset)
            if not ok then log('CINEMATIC_FLAG_FAILED ' .. name .. ' ' .. tostring(err)) end
        end
    end
    for asset in pairs(bossAssets or {}) do
        local ok, err = pcall(mark, 'SetBossUnlockSequencePlayed', context, asset)
        if not ok then log('CINEMATIC_FLAG_FAILED SetBossUnlockSequencePlayed ' .. tostring(err)) end
    end
end
return M
