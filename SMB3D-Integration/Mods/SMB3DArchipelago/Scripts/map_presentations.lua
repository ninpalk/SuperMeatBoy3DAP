-- Only presentation-seen bits; never grants worlds, levels, grades, or bosses.
-- Signatures captured from the running game in v0.9.2.
local M={}
local library,log
local prepared={}
local function mark(context)
    local lib=library()
    for w=1,5 do
        local idx=lib:GetWorldIDFromLevel('L_W'..w..'_L01')
        assert(type(idx)=='number','Missing native world index')
        lib:SetWorldUnlockSequencePlayed(context,idx)
        lib:SetDarkWorldSequencePlayed(context,idx)
        lib:SetBossUnlockSequencePlayed(context,'L_W'..w..'_Boss')
    end
    log('MAP_PRESENTATIONS_MARKED_SEEN worlds=5 dark=5 bosses=5')
end
local function clearPending(pc)
    -- This is the transient presentation request seen true in the capture.
    -- Do not touch bIsTransitioningToDarkWorld (normal portal switching).
    if pc:GetPropertyValue('bIsUnlockingDarkWorld')==true then
        pc:SetPropertyValue('bIsUnlockingDarkWorld',false)
        log('MAP_PENDING_DARK_PRESENTATION_CLEARED '..pc:GetFullName())
    end
end
function M.beforeMap(context)
    local ok,err=pcall(function()
        mark(context)
        for _,pc in ipairs(FindAllOf('PlayerController') or {}) do
            if pc:IsValid() then
                local name=pc:GetFullName()
                if name:match('^PC_Level_C ') or name:match('^PC_WorldMap_C ') then clearPending(pc) end
            end
        end
    end)
    if not ok then log('MAP_PRESENTATION_PREPARE_FAILED '..tostring(err)) end
end
function M.beforeBeginPlay(actor)
    if not actor or not actor:IsValid() then return end
    local name=actor:GetFullName()
    if not (name:match('^PC_WorldMap_C ') or name:match('^BP_WorldMapCharacter_C ')) then return end
    if not name:find('/L_WorldMap.L_WorldMap:',1,true) then return end
    local key=name..':'..tostring(actor:GetAddress())
    if prepared[key] then return end
    local ok,err=pcall(function()
        mark(actor)
        if name:match('^PC_WorldMap_C ') then clearPending(actor) end
    end)
    if ok then prepared[key]=true else log('MAP_PRESENTATION_BEGINPLAY_FAILED '..tostring(err)) end
end
function M.initialize(getLibrary,logger)
    library=getLibrary;log=logger
    if RegisterBeginPlayPreHook then
        RegisterBeginPlayPreHook(function(param)
            local ok,err=pcall(function()
                local actor=param:get()
                M.beforeBeginPlay(actor)
            end)
            if not ok then log('MAP_PRESENTATION_HOOK_FAILED '..tostring(err)) end
        end)
    end
end
return M
