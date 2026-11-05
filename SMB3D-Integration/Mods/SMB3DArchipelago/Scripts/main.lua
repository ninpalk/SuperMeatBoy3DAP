local scriptPath = debug.getinfo(1, 'S').source:match('^@(.+[/\\])')
assert(scriptPath, 'Cannot resolve mod script directory')
local access = dofile(scriptPath .. 'access.lua')
local boundaries = dofile(scriptPath .. 'gates.lua')
local deaths = dofile(scriptPath .. 'deathlink.lua')
local tofu = dofile(scriptPath .. 'tofu.lua')
local ending = dofile(scriptPath .. 'ending.lua')
local characters = dofile(scriptPath .. 'characters.lua')
local warpGoals = dofile(scriptPath .. 'warp_goals.lua')
local mapTrace = dofile(scriptPath .. 'map_trace.lua')
local mapPresentations = dofile(scriptPath .. 'map_presentations.lua')
local base = os.getenv('SMB3D_BRIDGE_DIR') or
    ((os.getenv('LOCALAPPDATA') or '') .. '/SuperMeatBoy3DArchipelago/bridge')
local state = {items = {}, checks = {}}
local localChecks = {}
local currentSession = nil
local attemptSession = nil
local stateText = nil
local bossAssets = {}
local seenActors = {}
local errors = {}
local function log(s) print('[SMB3DAP] ' .. s .. '\n') end
boundaries.initialize(log)
local function once(key, message)
    if not errors[key] then errors[key] = true; log(message) end
end
local function str(value)
    if type(value) == 'string' then return value end
    return value:ToString()
end
local function short(asset)
    return asset:gsub('%?.*$', ''):gsub('%.umap$', ''):match('([^/]+)$') or asset
end
local function library()
    local object = StaticFindObject('/Script/SMB.Default__SaveSlotDataLibrary')
    assert(object:IsValid(), 'SaveSlotDataLibrary default object unavailable')
    return object
end
local function dark(context)
    local value = library():IsDarkWorldActive(context)
    assert(type(value) == 'boolean', 'Dark/light mode unavailable')
    return value
end
local function worldOf(asset)
    local w = asset:match('L_W([1-5])_')
    if w then return tonumber(w) end
    local ok, value = pcall(function() return library():GetWorldIDFromLevel(asset) end)
    if ok and type(value) == 'number' and value >= 1 and value <= 5 then return value end
end
local function nativeWorld(worldID)
    local first = library():GetWorldIDFromLevel('L_W1_L01')
    assert(first == 0 or first == 1, 'Cannot establish native world index base')
    return worldID + (first == 0 and 1 or 0)
end
local function isAllowed(asset, mode)
    local warp=access.parseWarp(asset)
    if warp then return access.warpZone(state,warp) end
    if short(asset):match('^([^%.]+)') == 'L_W5_Escape' then
        return state.goal == 'beat_the_game' and access.boss(state, 5)
    end
    local boss = bossAssets[short(asset)]
    if boss then return access.boss(state, boss) end
    local w, n = access.parse(asset)
    if w then return access.level(state, w, n, mode) end
    return nil
end
local function refreshState()
    local file = io.open(base .. '/state.txt', 'r')
    if not file then return end
    local text = file:read('*a'); file:close()
    if text == stateText then return end
    local new = access.readState(text)
    if not new then once('state', 'Invalid bridge state; keeping previous access.'); return end
    if currentSession ~= new.session then
        currentSession = new.session; localChecks = {}; seenActors = {}
        log('Selected AP run ' .. currentSession:sub(1, 12))
        -- Restore mod-local offline completions when reopening the game without the client.
        local journal = io.open(base .. '/checks-' .. currentSession .. '.txt', 'r')
        if journal then for line in journal:lines() do localChecks[line] = true end; journal:close() end
    end
    for name in pairs(localChecks) do new.checks[name] = true end
    state = new; stateText = text
end
local function check(name)
    refreshState()
    if not currentSession then log('No AP run selected; did not queue ' .. name); return end
    if state.checks[name] then return end
    local file, err = io.open(base .. '/checks-' .. currentSession .. '.txt', 'a')
    if not file then log('CHECK_WRITE_FAILED ' .. tostring(err)); return end
    local ok = file:write(name .. '\n')
    local closed = file:close()
    if not ok or not closed then log('CHECK_WRITE_FAILED ' .. name); return end
    localChecks[name] = true; state.checks[name] = true
    log('CHECK_QUEUED ' .. name)
end
local function finish(context, asset, bandage, boss, aplus)
    local ok, err = pcall(function()
        refreshState()
        if attemptSession ~= currentSession or not currentSession then
            log('Completion ignored: re-enter the level after selecting an AP run.'); return
        end
        if bandage and state.bandagesanity == false then return end
        local object = context:get()
        if aplus and (not state.speedsanity or not object:GetFullName():find('LevelGoal', 1, true)) then return end
        local assetName = asset and str(asset:get()) or object:GetFullName()
        if aplus and bossAssets[short(assetName)] then return end
        local warp=access.parseWarp(assetName)
        if warp then
            if state.warpzonesanity and not bandage and not boss and not aplus and access.warpZone(state,warp) then
                check('World '..warp..' Warp Zone')
            end
            return
        end
        local w, n = access.parse(assetName)
        if aplus then
            local goalWorld, goalLevel = access.parse(object:GetFullName())
            if w ~= goalWorld or n ~= goalLevel then return end
        end
        if boss then
            local world = worldOf(assetName)
            if world and access.boss(state, world) then check('World ' .. world .. ' Boss') end
        elseif w then
            local mode = dark(object)
            if access.level(state, w, n, mode) then
                if bandage and not mode then check(w .. '-' .. n .. ' Bandage')
                elseif not bandage then check((mode and 'Dark ' or '') .. w .. '-' .. n .. (aplus and ' A+' or '')) end
            end
        else once('finish:' .. assetName, 'UNMAPPED_COMPLETION ' .. assetName) end
    end)
    if not ok then log('Completion hook failed: ' .. tostring(err)) end
end
local function install(path, pre, post)
    local ok, err
    if post then
        local original = post
        local hasReturn = false
        local fn = StaticFindObject(path)
        if fn:IsValid() then fn:ForEachProperty(function(property)
            if property:GetFName():ToString() == 'ReturnValue' then hasReturn = true end
        end) end
        if hasReturn then post = function(context, returnValue, ...) return original(context, ...) end end
        ok, err = pcall(RegisterHook, path, pre or function() end, post)
    else ok, err = pcall(RegisterHook, path, pre) end
    log((ok and 'Hook installed: ' or 'HOOK_FAILED ') .. path .. (ok and '' or (' ' .. tostring(err))))
end
install('/Script/SMB.SaveSlotDataLibrary:SetLevelFinished', nil,
    function(self, context) finish(context, nil, false, false) end)
install('/Script/SMB.SaveSlotDataLibrary:SetLevelFinishedForLevel', nil,
    function(self, context, asset) finish(context, asset, false, false) end)
install('/Script/SMB.SaveSlotDataLibrary:SetBandageCollected', nil,
    function(self, context) finish(context, nil, true, false) end)
install('/Script/SMB.SaveSlotDataLibrary:SetBossDefeated', nil,
    function(self, context, asset) finish(context, asset, false, true) end)
-- These native award setters were observed on the A+ goal clear, not on a slow
-- replay. No target times, timers or saved grade flags are modified here.
install('/Script/SMB.SaveSlotDataLibrary:SetAPlusTimeAchieved', nil,
    function(self, context) finish(context, nil, false, false, true) end)
install('/Script/SMB.SaveSlotDataLibrary:SetAPlusTimeAchievedForLevel', nil,
    function(self, context, asset) finish(context, asset, false, false, true) end)

install('/Script/Engine.GameplayStatics:OpenLevel', function(self, context, levelName, absolute, options)
    local ok, err = pcall(function()
        refreshState()
        local asset = str(levelName:get())
        local map = short(asset)
        if map == 'L_WorldMap' then
            mapPresentations.beforeMap(context:get())
            return
        end
        if map == 'L_MainMenu' or map == 'L_StartUp' then return end
        local w = worldOf(asset)
        if not w then return end -- startup/menu/world map have no world ID
        local allowed = isAllowed(asset, dark(context:get()))
        if allowed ~= true then
            levelName:set(FName('/Game/Levels/L_WorldMap')); absolute:set(true); options:set('')
            log('BLOCKED_TRAVEL ' .. asset)
        else
            attemptSession = currentSession
            if map:match('^([^%.]+)') == 'L_W5_Escape' then log('ESCAPE_ACCESS_ALLOWED goal=beat_the_game') end
        end
    end)
    if not ok then
        -- A failed mode lookup must not accidentally allow a locked dark level.
        local asset = str(levelName:get())
        if asset:match('L_W[1-5]_') then
            levelName:set(FName('/Game/Levels/L_WorldMap')); absolute:set(true); options:set('')
        end
        once('travel', 'Travel gate error: ' .. tostring(err))
    end
end)

-- The map character uses these queries to decide whether to run vanilla
-- unlock attempts. For it, report already handled; actual AP access is enforced
-- independently on level entries, hub portals, boundaries, and OpenLevel.
local function mapUnlockDriver(context)
    if not context or not context:IsValid() then return false end
    local name=context:GetFullName()
    return name:match('^BP_WorldMapCharacter_C ')~=nil
        and name:find('/L_WorldMap.L_WorldMap:',1,true)~=nil
end
local function alreadyPresented(context,kind)
    if not mapUnlockDriver(context) then return false end
    once('already-presented:'..kind,'MAP_UNLOCK_ALREADY_HANDLED '..kind)
    return true
end

install('/Script/SMB.SaveSlotDataLibrary:IsWorldUnlocked', nil, function(self, context, world, sequence)
    refreshState()
    sequence:set(true)
    if alreadyPresented(context:get(),'world') then return true end
    local allowed = access.world(state, nativeWorld(world:get()))
    return allowed
end)
install('/Script/SMB.SaveSlotDataLibrary:IsBossUnlocked', nil, function(self, context, asset, sequence)
    refreshState()
    sequence:set(true)
    if alreadyPresented(context:get(),'boss') then return true end
    local w = worldOf(str(asset:get()))
    if not w then return false end
    local allowed = access.boss(state, w)

    return allowed
end)
-- AP runs must be able to earn a bandage again even when a vanilla save had it.
install('/Script/SMB.SaveSlotDataLibrary:GetBandageCollectedForLevel', nil, function(self, context, asset)
    refreshState()
    if not currentSession or state.bandagesanity == false then return end
    local w, n = access.parse(str(asset:get()))
    if w then return state.checks[w .. '-' .. n .. ' Bandage'] == true end
end)

-- These two additional vanilla prerequisites are queried through their reflected
-- parameter names; no positional signature is assumed for the unobserved getters.
local function reflectedQuery(name, handler)
    local path = '/Script/SMB.SaveSlotDataLibrary:' .. name
    local fn = StaticFindObject(path)
    if not fn:IsValid() then log('Optional query unavailable: ' .. name); return end
    local parameters = {}
    local inspected, errorText = pcall(function() fn:ForEachProperty(function(property)
        local field = property:GetFName():ToString()
        log('QUERY_SIGNATURE ' .. property:GetFullName())
        if field ~= 'ReturnValue' then parameters[#parameters + 1] = field end
    end) end)
    if not inspected then log('Optional query signature unavailable: ' .. name .. ' ' .. tostring(errorText)); return end
    install(path, nil, function(self, ...)
        local args, named = {...}, {}
        for i, field in ipairs(parameters) do
            if args[i] then named[field] = args[i]:get() end
        end
        local ok, value = pcall(handler, named)
        if ok then return value end
        once('query:' .. name, 'Optional query failed: ' .. name .. ' ' .. tostring(value))
    end)
end
reflectedQuery('IsDarkWorldUnlocked', function(args)
    refreshState()
    local context = args.WorldContextObject
    if alreadyPresented(context,'dark') then return true end
    if context and context:IsValid() then
        local inLevel = context:GetFullName():find('LevelGoal', 1, true) ~= nil
        if not inLevel then
            local ok, name = pcall(function() return context:GetWorld():GetFullName() end)
            inLevel = ok and name:match('L_W[1-5]_') ~= nil
        end
        if inLevel then
            -- The goal's vanilla "new dark unlock" branch must see this as already
            -- handled. Actual AP access remains enforced on entries and travel.
            once('dark-cinematic', 'VANILLA_DARK_UNLOCK_SEQUENCE_SUPPRESSED (in-level query)')
            return true
        end
    end
    if args.InLevelAssetName then
        local w, n = access.parse(str(args.InLevelAssetName))
        if w then return access.level(state, w, n, true) end
    end
    local world = args.WorldID and nativeWorld(args.WorldID)
    if world then
        if not access.world(state, world) then return false end
        for n = 1, 15 do if state.items['Dark ' .. world .. '-' .. n .. ' Access'] then return true end end
        return false
    end
    for w = 1, 5 do
        for n = 1, 15 do if access.level(state, w, n, true) then return true end end
    end
    return false
end)
reflectedQuery('GetAPlusTimeAchievedForLevel', function(args)
    local context = args.WorldContextObject
    if not context or not context:IsValid() or not context:IsA('/Script/SMB.WorldMapLevelEntry') then return end
    if not dark(context) or not args.InLevelAssetName then return end
    local w, n = access.parse(str(args.InLevelAssetName))
    if w then return access.level(state, w, n, true) end
end)

local function visuals(portal, allowed)
    for field, visible in pairs({LockedCross = not allowed, NS_HUB_Portal_Closed = not allowed,
                                NS_HUB_Portal_Effect = allowed}) do
        local component = portal:GetPropertyValue(field)
        if component:IsValid() then component:SetVisibility(visible, true); component:SetHiddenInGame(not visible, true) end
    end
end
local function updatePortals()
    local portals, desired = {}, {}
    for _, portal in ipairs(FindAllOf('BP_HubPortal_C') or {}) do
        if portal:IsValid() and portal:GetFullName():find(':PersistentLevel.', 1, true) then
            portals[portal:GetFullName()] = portal
        end
    end
    for name, portal in pairs(portals) do
        local w = portal:GetPropertyValue('WorldIdx')
        if type(w) == 'number' and w >= 1 and w <= 5 then
            local allowed = access.world(state, w)
            desired[name] = allowed
            local target = portal:GetPropertyValue('TargetLocation')
            if target:IsValid() and portals[target:GetFullName()] then desired[target:GetFullName()] = allowed end
        end
    end
    for name, portal in pairs(portals) do
        local allowed = desired[name] == true
        local key = name .. ':' .. portal:GetAddress()
        local changed = seenActors[key] ~= allowed or portal:GetPropertyValue('bIsUnlocked') ~= allowed
        portal:SetPropertyValue('bIsUnlocked', allowed)
        if changed and allowed then portal:CE_Unlock() end
        visuals(portal, allowed)
        if changed then log('PORTAL_ACCESS ' .. name .. '=' .. tostring(allowed)) end
        seenActors[key] = allowed
    end
end
local function updateEntries()
    for _, entry in ipairs(FindAllOf('WorldMapLevelEntry') or {}) do
        if entry:IsValid() then
            local asset = str(entry:GetPropertyValue('LevelAssetName'))
            local boss = entry:GetPropertyValue('bIsBossEntry')
            if boss then bossAssets[short(asset)] = worldOf(asset) end
            local allowed = isAllowed(asset, dark(entry))
            if allowed ~= nil then
                local trigger = entry:GetPropertyValue('TriggerBox')
                if trigger:IsValid() then trigger:SetCollisionEnabled(allowed and 1 or 0) end
                local key = entry:GetFullName() .. ':' .. entry:GetAddress()
                if seenActors[key] ~= allowed then log('LEVEL_ACCESS ' .. asset .. '=' .. tostring(allowed)) end
                seenActors[key] = allowed
            end
        end
    end
end
local function tick()
    refreshState()
    local heartbeat = io.open(base .. '/heartbeat.json', 'w')
    if heartbeat then heartbeat:write('{"time":' .. os.time() .. ',"version":"0.9.4"}'); heartbeat:close() end
    local warpOK, warpError = pcall(warpGoals.update)
    if not warpOK then once('warp-observer', 'Warp goal observer failed: ' .. tostring(warpError)) end
    local charsOK, charsError = pcall(characters.update)
    if not charsOK then once('characters', 'Character availability update failed: ' .. tostring(charsError)) end
    local endingOK, endingError = pcall(ending.update)
    if not endingOK then once('ending', 'Credits goal detection failed: ' .. tostring(endingError)) end
    local deathOK, deathError = pcall(deaths.update)
    if not deathOK then once('deathlink', 'DeathLink update failed: ' .. tostring(deathError)) end
    local boundaryOK, boundaryError = pcall(boundaries.update, log)
    if not boundaryOK then once('boundary', 'World-boundary update failed: ' .. tostring(boundaryError)) end
    local ok, err = pcall(updatePortals)
    if not ok then once('portal', 'Portal update failed: ' .. tostring(err)) end
    ok, err = pcall(updateEntries)
    if not ok then once('entry', 'Level-entry update failed: ' .. tostring(err)) end
end
deaths.initialize(base, function() refreshState(); return state end, log)
tofu.initialize(base, function() refreshState(); return state end, log)
ending.initialize(base, function() refreshState(); return state end, log)
characters.initialize(log)
mapTrace.initialize(log)
mapPresentations.initialize(library,log)
warpGoals.initialize(function() refreshState(); return state end,
    function() return currentSession ~= nil and attemptSession == currentSession end,
    check, access.parseWarp, access.warpZone, log)
if LoopInGameThreadWithDelay then LoopInGameThreadWithDelay(500, tick)
else
    local pending = false
    LoopAsync(500, function()
        if not pending then pending = true; ExecuteInGameThread(function() tick(); pending = false end) end
        return false
    end)
end
RegisterKeyBind(Key.F2, function() ExecuteInGameThread(function()
    log('STATUS session=' .. tostring(currentSession) .. ' bridge=' .. base)
    tick()
end) end)
log('Loaded v0.9.4. Map unlock driver sees already handled; AP entry gates retained. Bridge: ' .. base)
