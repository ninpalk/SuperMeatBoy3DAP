-- Permanent barriers between worlds. AP grants affect warps, never these gates.
-- Blueprint CE_Deactivate is a post hook: it is not cancelled by returning false.
local M = {}
local hooksInstalled = {}
local reported = {}
local warning = {}
local log = function() end

local function reportOnce(key, message)
    if not warning[key] then warning[key] = true; log(message) end
end

function M.close(gate)
    if not gate or not gate:IsValid() then return end
    local name = gate:GetFullName()
    if not name:match('^BP_AreaGate_C ') or not name:find(':PersistentLevel.', 1, true) then return end
    local timelines, colliders = {}, {}
    local seen = {}
    local class = gate:GetClass()
    local depth = 0
    while class:IsValid() and depth < 3 do
        class:ForEachProperty(function(property)
            if not property:GetFullName():match('^Object') then return end
            local field = property:GetFName():ToString()
            local ok, component = pcall(function() return gate:GetPropertyValue(field) end)
            if not ok or not component or not component:IsValid() then return end
            local address = component:GetAddress()
            if seen[address] then return end
            seen[address] = true
            if component:IsA('/Script/Engine.TimelineComponent') then
                timelines[#timelines + 1] = component
            elseif component:IsA('/Script/Engine.PrimitiveComponent') then
                colliders[#colliders + 1] = component
            end
        end)
        class = class:GetSuperStruct()
        depth = depth + 1
    end
    -- Re-run the timeline's closed-position update, including gates already opened
    -- by vanilla save data. Do not fire timeline events or completion outputs.
    for _, timeline in ipairs(timelines) do
        timeline:Stop()
        timeline:SetPlaybackPosition(0.0, false, true)
    end
    gate:SetActorHiddenInGame(false)
    gate:SetActorEnableCollision(true)
    for _, component in ipairs(colliders) do
        -- QueryAndPhysics restores physical blocking, not just overlap detection.
        component:SetCollisionEnabled(3)
        component:SetCollisionResponseToChannel(2, 2) -- Pawn channel: Block.
    end
    local key = name .. ':' .. gate:GetAddress()
    if not reported[key] then
        reported[key] = true
        log('WORLD_BOUNDARY_SEALED ' .. name .. ' timelines=' .. #timelines .. ' colliders=' .. #colliders)
    end
    if #colliders == 0 then reportOnce('collider:' .. name, 'WORLD_BOUNDARY_WARNING no reflected collider: ' .. name) end
end

local function installHooks()
    local root = '/Game/Actors/Misc/WorldMap/BP_AreaGate.BP_AreaGate_C:'
    for _, event in ipairs({'CE_Deactivate', 'ReceiveBeginPlay'}) do
        local path = root .. event
        if not hooksInstalled[path] then
            local fn = StaticFindObject(path)
            if fn:IsValid() then
                local ok, err = pcall(RegisterHook, path, function(context)
                    local applied, problem = pcall(function() M.close(context:get()) end)
                    if not applied then reportOnce(path, 'WORLD_BOUNDARY_HOOK_FAILED ' .. tostring(problem)) end
                end)
                if ok then hooksInstalled[path] = true; log('Boundary hook installed: ' .. path)
                else reportOnce('install:' .. path, 'WORLD_BOUNDARY_HOOK_FAILED ' .. tostring(err)) end
            end
        end
    end
end

function M.initialize(logger)
    log = logger
    installHooks()
    -- Install the Blueprint hooks as soon as a gate actor is created, before its
    -- BeginPlay can open it using existing vanilla progress.
    if NotifyOnNewObject then
        local ok, err = pcall(NotifyOnNewObject,
            '/Game/Actors/Misc/WorldMap/BP_AreaGate.BP_AreaGate_C', function()
                installHooks()
            end)
        if not ok then reportOnce('notify', 'WORLD_BOUNDARY_NOTIFY_FAILED ' .. tostring(err)) end
    end
end

function M.update(logger)
    log = logger
    installHooks()
    for _, gate in ipairs(FindAllOf('BP_AreaGate_C') or {}) do
        local ok, err = pcall(M.close, gate)
        if not ok then reportOnce('gate:' .. tostring(err), 'WORLD_BOUNDARY_UPDATE_FAILED ' .. tostring(err)) end
    end
end
return M
