-- Credits goal: only the real, visible credits widget in the final escape.
local M={}
local directory,readState,log
local session,reported=false,false
local warned={}
local function route(state)
    if not state.items['World 5 Access'] then return false end
    local count=0
    for n=1,15 do
        if state.items['5-'..n..' Access'] and state.checks['5-'..n] then count=count+1 end
    end
    return count>=10
end
function M.update()
    local state=readState()
    if state.session~=session then session=state.session;reported=false;warned={} end
    if not session or state.goal~='beat_the_game' or reported or not route(state) then return end
    for _,widget in ipairs(FindAllOf('W_Credits_C') or {}) do
        if widget:IsValid() and not widget:GetFullName():find('Default__',1,true) and widget:IsInViewport() and widget:IsVisible() then
            local world=widget:GetWorld():GetFullName()
            -- The same widget may be reachable from a menu. Merely viewing
            -- menu/theater credits must never count as clearing the escape.
            if world:match('L_W5_Escape[%.:%s]') then
                local file,err=io.open(directory..'/ending-'..session..'.txt','w')
                if not file then error('Cannot record ending: '..tostring(err)) end
                local ok,problem=file:write('CREDITS1\ncredits\n')
                local closed,closeError=file:close()
                if not ok or not closed then error('Cannot persist ending: '..tostring(problem or closeError)) end
                reported=true;log('ENDING_CREDITS_REACHED '..widget:GetFullName()..' world='..world)
            elseif not warned[world] then
                warned[world]=true;log('ENDING_CREDITS_IGNORED outside final escape: '..world)
            end
        end
    end
end
function M.initialize(base,stateReader,logger)
    directory=base;readState=stateReader;log=logger
end
return M
