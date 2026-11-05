local M = {}
local base, getState, log
local hooked = {}
local acknowledged = {}
local sequence = 0
local boot = tostring(os.time()) .. '-' .. tostring(math.random(100000,999999))
local session
local dead = false
local forced = false
local forcedAt = 0
local forcedObserved = false
local forcedPawn
local warned = {}

local function once(key, message)
    if not warned[key] then warned[key]=true; log(message) end
end
local function inLevel(actor)
    return actor and actor:IsValid() and actor:GetWorld():GetFullName():match('L_W[1-5]_') ~= nil
end
local function player()
    for _, pawn in ipairs(FindAllOf('SMBPlayerChar') or {}) do
        if pawn:IsValid() and inLevel(pawn) and pawn:IsPlayerControlled() then return pawn end
    end
end
local function gameMode()
    for _, mode in ipairs(FindAllOf('SMBIngameGameMode') or {}) do
        if inLevel(mode) then return mode end
    end
end
local function localDeath(mode)
    if not inLevel(mode) or dead then return end
    dead = true
    if forced then
        forcedObserved = true
        forced = false
        log('DEATHLINK_ECHO_SUPPRESSED')
        return
    end
    local state = getState()
    if not state.session or not state.death_link then return end
    sequence = sequence + 1
    local file, err = io.open(base .. '/deaths-' .. state.session .. '.txt', 'a')
    if not file then log('DEATHLINK_WRITE_FAILED ' .. tostring(err)); return end
    file:write(boot .. '-' .. sequence .. '\t' .. os.time() .. '\n'); file:close()
    log('DEATHLINK_LOCAL_DEATH ' .. sequence)
end

local function hookMode(mode)
    local class = mode:GetClass()
    local callbacks = {}
    class:ForEachFunction(function(fn)
        local name = fn:GetFName():ToString()
        if name == 'IOnPlayerDied' then callbacks.death = fn:GetFullName():gsub('^Function ', '') end
        if name == 'IOnPlayerSpawned' then callbacks.spawn = fn:GetFullName():gsub('^Function ', '') end
        if name == 'BIE_Respawn' then callbacks.fallback = fn:GetFullName():gsub('^Function ', '') end
    end)
    local deathPath = callbacks.death or callbacks.fallback
    if deathPath and not hooked[deathPath] then
        local ok, err = pcall(RegisterHook, deathPath, function(context)
            local good, problem = pcall(localDeath, context:get())
            if not good then log('DEATHLINK_OBSERVER_FAILED ' .. tostring(problem)) end
        end)
        if ok then hooked[deathPath]=true; log('DeathLink death observer: ' .. deathPath)
        else once(deathPath, 'DEATHLINK_HOOK_FAILED ' .. tostring(err)) end
    end
    if callbacks.spawn and not hooked[callbacks.spawn] then
        local ok = pcall(RegisterHook, callbacks.spawn, function()
            dead=false; forced=false
        end)
        if ok then hooked[callbacks.spawn]=true end
    end
    if not deathPath then once('observer', 'DEATHLINK_WARNING no Blueprint death observer on ' .. mode:GetFullName()) end
end

local function ack(identity)
    acknowledged[identity] = true
    local file = io.open(base .. '/death-acks-' .. session .. '.txt', 'a')
    if file then file:write(identity .. '\n'); file:close() end
end
local function incoming(state)
    local file = io.open(base .. '/death-in-' .. session .. '.txt', 'r')
    if not file then return end
    local text = file:read('*a'); file:close()
    for identity, timestamp in text:gmatch('([a-f0-9]+)\t([%d%.]+)\n') do
        if not acknowledged[identity] then
            local age = os.time() - tonumber(timestamp)
            local pawn, mode = player(), gameMode()
            if not state.death_link or age > 10 or age < -2 or not pawn or not mode or dead then
                ack(identity)
                log('DEATHLINK_DISCARDED (disabled, expired, menu, or already dead)')
            else
                -- Mark before any death callback can execute; never echo this death.
                forced=true; forcedObserved=false; forcedAt=os.time(); forcedPawn=pawn:GetAddress()
                ack(identity)
                local ok, err = pcall(function() pawn:ReplayDefaultDeath() end)
                if not ok then
                    log('DEATHLINK_DEFAULT_DEATH_FAILED ' .. tostring(err))
                    mode:Respawn(0.0, nil)
                    forcedObserved=true
                end
                log('DEATHLINK_APPLIED default death requested')
            end
        end
    end
end

function M.initialize(directory, stateReader, logger)
    base=directory; getState=stateReader; log=logger
end
function M.update()
    local state=getState()
    if state.session ~= session then
        session=state.session; dead=false; forced=false; forcedPawn=nil; acknowledged={}
        if session then
            local file=io.open(base .. '/death-acks-' .. session .. '.txt', 'r')
            if file then for line in file:lines() do acknowledged[line]=true end; file:close() end
        end
    end
    local mode=gameMode()
    if mode then hookMode(mode) end
    if forcedPawn and os.time()-forcedAt >= 1 then
        -- ReplayDefaultDeath is also used for replay visuals. If it didn't reach
        -- the actual player's death observer, use the game's verified respawn API.
        if not forcedObserved and mode then
            forced=true
            mode:Respawn(0.0, nil)
            forcedObserved=true
            log('DEATHLINK_APPLIED respawn fallback')
        end
        if os.time()-forcedAt >= 3 then forced=false; forcedPawn=nil; dead=false end
    end
    if session then incoming(state) end
end
return M
