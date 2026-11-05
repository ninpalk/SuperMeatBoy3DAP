-- World-map cinematic skip. Fast completion preserves normal finish callbacks.
local M = {}
local RATE = 10000.0
local log = function() end
local reported = {}
local function map(object)
    if not object or not object:IsValid() then return false end
    local ok, name = pcall(function() return object:GetWorld():GetFullName() end)
    return ok and name:find('L_WorldMap', 1, true) ~= nil
end
local function report(kind, object, asset)
    local key = kind .. object:GetAddress()
    if not reported[key] then
        reported[key] = true
        log('WORLDMAP_CINEMATIC_SKIP ' .. kind .. ' ' .. (asset or object:GetFullName()))
    end
end
local function skipPlayer(player)
    if not map(player) then return end
    -- Stop looping world-map sequences so they can reach their finish callbacks.
    pcall(function() player.PlaybackSettings.LoopCount.Value = 0 end)
    player:SetPlayRate(RATE)
    local ok, name = pcall(function() return player:GetSequence():GetFullName() end)
    report('sequence', player, ok and name or nil)
end
local function darkWidget(widget)
    return map(widget) and widget:GetFullName():lower():find('unlockedpopup_darkworld', 1, true) ~= nil
end
local function darkTimeline(timeline)
    if not map(timeline) then return false end
    local ok, name = pcall(function() return timeline:GetOuter():GetFullName():lower() end)
    return ok and (name:find('darkworldportal', 1, true) ~= nil
        or name:find('gm_worldmap',1,true) ~= nil
        or name:find('pc_worldmap',1,true) ~= nil
        or name:find('bp_worldmapcharacter',1,true) ~= nil)
end
local function guarded(callback)
    return function(...)
        local ok, err = pcall(callback, ...)
        if not ok and not reported[tostring(err)] then
            reported[tostring(err)] = true
            log('WORLDMAP_CINEMATIC_ERROR ' .. tostring(err))
        end
    end
end
function M.initialize(install, logger)
    log = logger
    local root = '/Script/MovieScene.MovieSceneSequencePlayer:'
    for _, name in ipairs({'Play', 'PlayReverse', 'PlayTo'}) do
        install(root .. name, nil, guarded(function(context) skipPlayer(context:get()) end))
    end
    install(root .. 'PlayLooping', guarded(function(context, loops)
        if map(context:get()) then loops:set(0) end
    end), guarded(function(context) skipPlayer(context:get()) end))
    install(root .. 'SetPlayRate', guarded(function(context, rate)
        if map(context:get()) then rate:set(RATE) end
    end))
    for _, name in ipairs({'PlayAnimation', 'PlayAnimationForward', 'PlayAnimationReverse', 'PlayAnimationTimeRange'}) do
        install('/Script/UMG.UserWidget:' .. name, nil, guarded(function(context, animation)
            local widget = context:get()
            if darkWidget(widget) then
                widget:SetPlaybackSpeed(animation:get(), RATE)
                report('dark-popup', widget)
            end
        end))
    end
    install('/Script/UMG.UserWidget:SetPlaybackSpeed', guarded(function(context, animation, rate)
        if darkWidget(context:get()) then rate:set(RATE) end
    end))
    for _, name in ipairs({'Play', 'PlayFromStart', 'Reverse', 'ReverseFromEnd'}) do
        install('/Script/Engine.TimelineComponent:' .. name, nil, guarded(function(context)
            local timeline = context:get()
            if darkTimeline(timeline) then
                timeline:SetLooping(false)
                timeline:SetPlayRate(RATE)
                report('dark-portal-timeline', timeline)
            end
        end))
    end
    install('/Script/Engine.TimelineComponent:SetPlayRate', guarded(function(context, rate)
        if darkTimeline(context:get()) then rate:set(RATE) end
    end))
end
function M.update()
    -- Covers auto-play and direct native playback that can bypass reflected Play.
    for _, player in ipairs(FindAllOf('MovieSceneSequencePlayer') or {}) do
        if map(player) then
            local ok, err = pcall(function()
                if player:IsPlaying() then skipPlayer(player) end
            end)
            if not ok then log('WORLDMAP_CINEMATIC_POLL_ERROR ' .. tostring(err)) end
        end
    end
    for _, timeline in ipairs(FindAllOf('TimelineComponent') or {}) do
        if darkTimeline(timeline) then
            local ok, err = pcall(function()
                if timeline:IsPlaying() then
                    timeline:SetLooping(false)
                    timeline:SetPlayRate(RATE)
                    report('map-camera-timeline', timeline)
                end
            end)
            if not ok then log('WORLDMAP_CINEMATIC_TIMELINE_ERROR ' .. tostring(err)) end
        end
    end
end
return M
