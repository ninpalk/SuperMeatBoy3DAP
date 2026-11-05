local M = {}
function M.parse(asset)
    if type(asset) ~= 'string' then return nil end
    local w, n = asset:match('L_W([1-5])_L0*(%d+)')
    if w and n and tonumber(n) >= 1 and tonumber(n) <= 15 then return tonumber(w), tonumber(n) end
end
function M.parseWarp(asset)
    if type(asset)~='string' then return nil end
    return tonumber(asset:match('L_W([1-5])_LS[%./:%s]') or asset:match('L_W([1-5])_LS$'))
end
local warpEntrances={[2]=6,[3]=10,[4]=3,[5]=8}
function M.warpZone(state, world)
    if not M.world(state,world) then return false end
    if world>1 and not M.level(state,world,warpEntrances[world],false) then return false end
    return not state.warpzonesanity or state.items['World '..world..' Warp Zone Access']==true
end
function M.world(state, world)
    return world == 1 or state.items['World ' .. world .. ' Access'] == true
end
function M.level(state, world, level, dark)
    if not M.world(state, world) then return false end
    if dark and state.darksanity == false then return false end
    if dark then return state.items['Dark ' .. world .. '-' .. level .. ' Access'] == true end
    return world == 1 or state.items[world .. '-' .. level .. ' Access'] == true
end
function M.clearCount(state, world)
    local count = 0
    for n = 1, 15 do if state.checks[world .. '-' .. n] then count = count + 1 end end
    return count
end
function M.boss(state, world)
    return M.world(state, world) and M.clearCount(state, world) >= 10
end
function M.readState(text)
    if text:sub(1, 10) ~= 'APBRIDGE1\n' then return nil end
    local state = {items = {}, checks = {}, death_link = false, speedsanity = false, connected = false, goal = 'all_bosses', darksanity = true, bandagesanity = true, warpzonesanity = false}
    for kind, value in text:gmatch('([^\t\n]+)\t([^\n]*)\n') do
        if kind == 'session' and value:match('^[a-f0-9]+$') and #value == 64 then state.session = value end
        if kind == 'goal' and (value == 'all_bosses' or value == 'beat_the_game') then state.goal = value end
        if kind == 'status' then state.connected = value == 'connected' end
        if kind == 'item' then state.items[value] = true end
        if kind == 'check' then state.checks[value] = true end
        if kind == 'death_link' then state.death_link = value == '1' end
        if kind == 'warpzonesanity' then state.warpzonesanity = value == '1' end
        if kind == 'darksanity' then state.darksanity = value == '1' end
        if kind == 'bandagesanity' then state.bandagesanity = value == '1' end
        if kind == 'speedsanity' then state.speedsanity = value == '1' end
    end
    if not state.session then return nil end
    return state
end
return M
