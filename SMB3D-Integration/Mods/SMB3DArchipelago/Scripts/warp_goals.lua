-- Observe a true runtime secret-level goal, not saved completion on entry.
local M={}
local readState,canReport,report,parseWarp,allowed,log
local hooked={}
local function install(fn)
    local path=fn:GetFullName():gsub('^Function ','')
    if hooked[path] then return end
    local ok,err=pcall(RegisterHook,path,function(context,reached)
        local good,problem=pcall(function()
            if not reached or reached:get()~=true or not canReport() then return end
            local object=context:get()
            local world=object:GetWorld()
            local w=parseWarp(world:GetFullName())
            local state=readState()
            if w and state.warpzonesanity and allowed(state,w) then report('World '..w..' Warp Zone') end
        end)
        if not good then log('WARP_GOAL_CALLBACK_FAILED '..tostring(problem)) end
    end)
    if ok then hooked[path]=true;log('Warp goal observer: '..path)
    else log('WARP_GOAL_HOOK_FAILED '..tostring(err)) end
end
function M.update()
    for _,kind in ipairs({'GI_SMB_C','LevelScriptActor'}) do
        for _,object in ipairs(FindAllOf(kind) or {}) do
            if object:IsValid() and not object:GetFullName():find('Default__',1,true) then
                local ok,w=pcall(function() return parseWarp(object:GetWorld():GetFullName()) end)
                if ok and w then
                    local class=object:GetClass()
                    for depth=1,3 do
                        if not class:IsValid() then break end
                        class:ForEachFunction(function(fn)
                            if fn:GetFName():ToString()=='BI_GetReachedGoal' then install(fn) end
                        end)
                        class=class:GetSuperStruct()
                    end
                end
            end
        end
    end
end
function M.initialize(stateReader,attemptReady,check,warpParser,warpAllowed,logger)
    readState=stateReader;canReport=attemptReady;report=check;parseWarp=warpParser;allowed=warpAllowed;log=logger
end
return M
