-- Read-only, bounded map unlock trace. Never changes query results or game state.
local M={}
local log=function() end
local counts={}
local function describe(o)
    if not o or not o:IsValid() then return 'none' end
    return o:GetFullName()
end
local function object(v)
    local ok,o=pcall(function() return v:get() end)
    return ok and o or v
end
local function properties(o)
    local class=o:GetClass()
    for depth=1,2 do
        if not class or not class:IsValid() then break end
        local count=0
        class:ForEachProperty(function(p)
            local name=p:GetFName():ToString()
            local lower=name:lower()
            if count>=40 or not (lower:find('unlock',1,true) or lower:find('sequence',1,true)
                or lower:find('dark',1,true) or lower:find('skip',1,true)
                or lower:find('chapter',1,true) or lower:find('world',1,true)) then return end
            count=count+1
            local ok,v=pcall(function() return o:GetPropertyValue(name) end)
            local text=ok and tostring(v) or 'unreadable'
            if ok and type(v)=='userdata' then
                local good,n=pcall(describe,v)
                if good then text=n end
            end
            log('FIELD '..describe(o)..' '..p:GetFullName()..' = '..text)
        end)
        class=class:GetSuperStruct()
    end
end
local function event(name,context)
    local o=object(context)
    if not o or not o:IsValid() then return end
    local full=describe(o)
    if not full:find('BP_WorldMapCharacter_C ',1,true) then return end
    local key=name..':'..tostring(o:GetAddress())
    counts[key]=(counts[key] or 0)+1
    if counts[key]>3 then return end
    log('EVENT '..name..' '..full)
    properties(o)
end
function M.snapshot()
    log('SNAPSHOT BEGIN')
    for _,kind in ipairs({'BP_WorldMapCharacter_C','BP_DarkWorldPortal_C','PC_WorldMap_C','GI_SMB_C',
        'W_UnlockedPopup_DarkWorld_C','W_UnlockedPopup_NewWorld_C','W_UnlockedPopup_Boss_C'}) do
        local n=0
        for _,o in ipairs(FindAllOf(kind) or {}) do
            if n>=8 then break end
            if o:IsValid() and not describe(o):find('Default__',1,true) then
                n=n+1;log('OBJECT '..describe(o));properties(o)
                if kind:find('W_Unlocked',1,true) then
                    local good,v=pcall(function() return o:IsInViewport() end)
                    log('POPUP_VIEWPORT '..describe(o)..' '..(good and tostring(v) or 'unknown'))
                end
            end
        end
    end
    local lib=StaticFindObject('/Script/SMB.SaveSlotDataLibrary')
    if lib and lib:IsValid() then lib:ForEachFunction(function(fn)
        local name=fn:GetFName():ToString():lower()
        if name:find('sequence',1,true) or name:find('darkworld',1,true) then
            log('FUNCTION '..fn:GetFullName())
            fn:ForEachProperty(function(p) log('PARAMETER '..p:GetFullName()) end)
        end
    end) end
    log('SNAPSHOT END')
end
function M.initialize(logger)
    log=function(s) logger('MAP_TRACE '..s) end
    if RegisterCustomEvent then
        for _,name in ipairs({'CE_InitWorldUnlockSequences','CE_TryToUnlockWorld','CE_TryToUnlockDarkWorld',
            'CE_TryToUnlockBoss','CE_OnDarkWorldPortalCameraTransitionFinished',
            'CE_EDOnDarkWorldUnlockAnimationFinished','CE_EDOnWorldUnlockWidgetAnimationFinished',
            'CE_OnWorldUnlockSequenceFinished'}) do
            local eventName=name
            local ok,err=pcall(RegisterCustomEvent,eventName,function(context)
                local good,problem=pcall(event,eventName,context)
                if not good then log('ERROR '..eventName..' '..tostring(problem)) end
            end)
            if not ok then log('HOOK_FAILED '..eventName..' '..tostring(err)) end
        end
    end
    if Key.F6 then RegisterKeyBind(Key.F6,function() ExecuteInGameThread(function()
        local ok,err=pcall(M.snapshot)
        if not ok then log('SNAPSHOT_ERROR '..tostring(err)) end
    end) end) end
end
return M
