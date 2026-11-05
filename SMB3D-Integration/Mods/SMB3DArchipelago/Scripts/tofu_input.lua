-- Temporary bridge for missing native ability bindings on the replacement pawn.
local M={}
local reader,log
local pawn,pc,component,subsystem
local actions={}
local warned={}
local polls=0
local lastGate
local lastSample
local wallMode
local function valid(o) return o and o:IsValid() end
local function once(key,s) if not warned[key] then warned[key]=true;log(s) end end
local function each(array,fn)
    if type(array)=='table' then for _,value in ipairs(array) do fn(value) end
    else array:ForEach(function(i,value) fn(value:get()) end) end
end
local function release()
    for _,a in ipairs(actions) do
        if a.held and valid(pawn) then
            if a.release then pcall(function() pawn[a.release](pawn) end) end
            pcall(function() component:SetPropertyValue(a.flag,false) end)
        end
        a.held=false
    end
end
local function reset()
    release();pawn=nil;pc=nil;component=nil;subsystem=nil;actions={};polls=0;lastGate=nil;lastSample=nil
end
local function readKeys(a,checkDown)
    local names={}
    local down=false
    if not valid(subsystem) then return names,down end
    local action=component:GetPropertyValue(a.asset)
    if not valid(action) then return names,down end
    -- Consume each native FKey while the returned TArray is still alive.
    -- The previous version reconstructed a Lua FKey and retained its FName.
    each(subsystem:QueryKeysMappedToAction(action),function(key)
        local name='unknown'
        pcall(function() name=key.KeyName:ToString() end)
        names[#names+1]=tostring(name)
        if checkDown and pc:IsInputKeyDown(key) then down=true end
    end)
    return names,down
end
local function mapKeys()
    for _,a in ipairs(actions) do
        local ok,names=pcall(readKeys,a,false)
        a.keys=ok and names or {}
        if not ok then once(a.asset,'ABILITY_KEY_QUERY_FAILED '..a.asset..' '..tostring(names)) end
        once('mapped-'..a.asset,'ABILITY_MAPPED_KEYS '..a.asset..' keys='..table.concat(a.keys,','))
    end
end
local function bind(controller,replacement)
    pc=controller;pawn=replacement
    component=pawn:GetPropertyValue('CustomInputComponent')
    assert(valid(component),'No custom input component')
    actions={
        {asset='IAJump',flag='bJumpIsPressed',press='OnJumpPressed',release='OnJumpReleased',keys={},held=false},
        {asset='IADash',flag='bDashIsPressed',press='OnDashPressed',release='OnDashReleased',keys={},held=false},
        {asset='IASprint',flag='bSprintIsPressed',press='OnSprintPressed',release='OnSprintReleased',keys={},held=false},
        {asset='IAWallRun',flag='bWallRunIsPressed',keys={},held=false}
    }
    local ok,err=pcall(function()
        local library=StaticFindObject('/Script/Engine.Default__SubsystemBlueprintLibrary')
        local class=StaticFindObject('/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem')
        subsystem=library:GetLocalPlayerSubSystemFromPlayerController(pc,class)
    end)
    if not ok then once('subsystem','ABILITY_MAPPING_QUERY_UNAVAILABLE '..tostring(err)) end
    wallMode=nil
    local enum=StaticFindObject('/Script/SMB.ESMBAdvMovementMode')
    if valid(enum) then
        local ok,err=pcall(function() enum:ForEachName(function(name,value)
            local short=name:ToString():gsub('.*::',''):lower():gsub('[^a-z0-9]','')
            if short=='wallrun' or short=='wallrunning' then wallMode=value end
        end) end)
        if not ok then once('wall-mode','WALL_MODE_QUERY_FAILED '..tostring(err)) end
    end
    log('ABILITY_WALL_MODE '..tostring(wallMode))
    mapKeys()
    log('ABILITY_BRIDGE_READY jump/dash/sprint and wall-run state')
end
function M.update()
    local enabled,controller,replacement=reader()
    if not enabled or not valid(controller) or not valid(replacement) then if pawn then reset() end;return end
    if not pawn or pawn:GetAddress()~=replacement:GetAddress() then reset();bind(controller,replacement) end
    polls=polls+1
    if polls%250==0 then mapKeys() end
    local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    -- A missing gate suspends the bridge instead of sending actions in menus.
    local paused=gameplay:IsGamePaused(pawn)
    local ignored=pc:IsMoveInputIgnored()
    local dead=pawn:GetPropertyValue('bIsDead')==true
    local canMove=pawn:CanCharacterMove()
    local gate='paused='..tostring(paused)..' ignored='..tostring(ignored)..' dead='..tostring(dead)..' canMove='..tostring(canMove)
    if gate~=lastGate then lastGate=gate;log('ABILITY_GATE '..gate) end
    -- CanCharacterMove gates directional locomotion, not all abilities.
    -- Releasing jump here broke wall states and manufactured repeat presses.
    if paused or ignored or dead then release();return end
    local sample={}
    for _,a in ipairs(actions) do
        local ok,names,down=pcall(readKeys,a,true)
        if not ok then once('read-'..a.asset,'ABILITY_KEY_READ_FAILED '..tostring(names));down=false;names={} end
        if #names==0 then down=component:GetPropertyValue(a.flag)==true end
        sample[#sample+1]=a.asset..'='..tostring(down)
        -- Sustain native button state while held, not just on its first edge.
        component:SetPropertyValue(a.flag,down)
        if down~=a.held then
            a.held=down
            local name=down and a.press or a.release
            if down and a.asset=='IAJump' and wallMode~=nil and pawn:GetPropertyValue('AdvMovementMode')==wallMode then
                name='WallRunJump'
            end
            if name then
                local ok,err=pcall(function() pawn[name](pawn) end)
                if ok then log('ABILITY_FORWARDED '..name)
                else once(name,'ABILITY_HANDLER_FAILED '..name..' '..tostring(err)) end
            else log('ABILITY_STATE_FORWARDED '..a.flag..'='..tostring(down)) end
        end
    end
    local state=table.concat(sample,' ')
    if state~=lastSample then lastSample=state;log('ABILITY_BUTTON_STATE '..state) end
end
function M.initialize(stateReader,logger)
    reader=stateReader;log=logger
    if LoopInGameThreadWithDelay then LoopInGameThreadWithDelay(8,function()
        local ok,err=pcall(M.update)
        if not ok then release();once('update','ABILITY_BRIDGE_ERROR '..tostring(err)) end
    end) else log('ABILITY_BRIDGE_UNAVAILABLE no game-thread update loop') end
end
return M
