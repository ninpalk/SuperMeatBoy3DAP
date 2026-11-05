-- Runtime character availability; does not grant level/boss progress.
local M={}
local log=function() end
local installed=false
local seen={}
function M.update()
    for _,gi in ipairs(FindAllOf('GI_SMB_C') or {}) do
        if gi:IsValid() and not gi:GetFullName():find('Default__',1,true) then
            if gi:GetPropertyValue('bFreeCharacterSelection')~=true then
                gi:SetPropertyValue('bFreeCharacterSelection',true)
            end
            local key=tostring(gi:GetAddress())
            if not seen[key] then seen[key]=true;log('ALL_CHARACTERS_AVAILABLE runtime free selection enabled') end
        end
    end
    -- Blueprint functions may not exist until their owning class loads.
    local path='/Game/Misc/PC_Ingame_.PC_Ingame__C:fGetCharacterUnlockStatus'
    if not installed then
        local fn=StaticFindObject(path)
        if fn and fn:IsValid() then
            local ok,err=pcall(RegisterHook,path,function(self,charName,tryAll,alreadyUnlocked,canBeUnlocked)
                local good,problem=pcall(function()
                    alreadyUnlocked:set(true)
                    canBeUnlocked:set(false)
                end)
                if not good then log('CHARACTER_QUERY_OVERRIDE_FAILED '..tostring(problem)) end
            end)
            if ok then installed=true;log('Character availability query hooked')
            else log('CHARACTER_QUERY_HOOK_FAILED '..tostring(err)) end
        end
    end
end
function M.initialize(logger)
    log=logger
    M.update()
end
return M
