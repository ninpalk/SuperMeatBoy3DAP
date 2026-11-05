-- Server-driven, session-scoped Tofu Trap. Uses validated v0.15 spawn/input behavior.
local M={}
local base,getState,session
local acknowledged={}
local deferred={}
local sceneKey
local sceneCompleted=false
local traveling=false
local active, originalPawn, replacement, pc, gi, originalSelector
local changes={}
local refreshTicks
local attempted=false
local settleTicks
local initialReady=false
local originalClass
local playerLookupReady=false
local sourceInputSettings
local installed={}
local function log(s) print('[SMB3DTofuTrap] '..s..'\n') end
local function valid(o) return o and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function inLevel(o)
    return valid(o) and o:GetWorld():GetFullName():match('L_W[1-5]_')~=nil
end
local function controller()
    for _,o in ipairs(FindAllOf('PC_Level_C') or {}) do if inLevel(o) then return o end end
end
local function currentScene(controller)
    local world=controller:GetWorld()
    return world:GetFullName()..':'..tostring(world:GetAddress())
end
local function player()
    for _,o in ipairs(FindAllOf('SMBPlayerChar') or {}) do
        if inLevel(o) and o:IsPlayerControlled() then return o end
    end
end
local function instance()
    for _,o in ipairs(FindAllOf('GI_SMB_C') or {}) do
        if valid(o) and not o:GetFullName():find('Default__',1,true) then return o end
    end
end
local function row()
    local dt=StaticFindObject('/Game/Misc/CSVs/DT_PlayerChars.DT_PlayerChars')
    assert(valid(dt),'Character table is not loaded')
    for name,data in pairs(dt:GetRowMap()) do
        local text=tostring(name); pcall(function() text=name:ToString() end)
        if text=='TofuBoy' then return data end
    end
    error('TofuBoy row missing')
end
local function visibility(pawn,enabled)
    pawn:SetActorHiddenInGame(not enabled)
    pawn:SetActorEnableCollision(enabled)
    pawn:SetActorTickEnabled(enabled)
end
local function patchReferences(old,new)
    local seen={}
    for _,kind in ipairs({'PC_Level_C','SMBIngameGameMode','BP_Camera_C','BP_RecordAndReplayManager_C','BP_LevelGoal_Empty_C'}) do
        for _,o in ipairs(FindAllOf(kind) or {}) do
            if inLevel(o) then
                local class=o:GetClass()
                for n=1,5 do
                    if not valid(class) then break end
                    class:ForEachProperty(function(prop)
                        if not prop:IsA(PropertyTypes.ObjectProperty) then return end
                        local field=prop:GetFName():ToString()
                        local key=tostring(o:GetAddress())..':'..field
                        if seen[key] then return end
                        seen[key]=true
                        local ok,value=pcall(function() return o:GetPropertyValue(field) end)
                        if ok and same(value,old) then
                            local change={object=o,field=field,old=value,new=new}
                            changes[#changes+1]=change
                            o:SetPropertyValue(field,new)
                            log('REFERENCE_UPDATED '..o:GetFullName()..'.'..field)
                        end
                    end)
                    class=class:GetSuperStruct()
                end
            end
        end
    end
end
local function restoreReferences()
    for n=#changes,1,-1 do
        local c=changes[n]
        pcall(function()
            if valid(c.object) and same(c.object:GetPropertyValue(c.field),c.new) then c.object:SetPropertyValue(c.field,c.old) end
        end)
    end
    changes={}
end
local function clearSelector(reason)

    if originalSelector~=nil and valid(gi) then gi:SetPropertyValue('CurrentPlayerCharacterClass',originalSelector) end
    log('CLEARED '..reason)
end
local function restore()
    if not valid(originalPawn) and originalClass and valid(pc) and valid(replacement) then
        if originalSelector~=nil and valid(gi) then gi:SetPropertyValue('CurrentPlayerCharacterClass',originalSelector) end
        -- The replacement capsule occupies this position and can reject a spawn.
        replacement:SetActorEnableCollision(false)
        local ok,result=pcall(function()
            return pc:GetWorld():SpawnActor(originalClass,replacement:K2_GetActorLocation(),replacement:K2_GetActorRotation())
        end)
        if not ok or not valid(result) then
            replacement:SetActorEnableCollision(true)
            error('Unable to recreate original character: '..tostring(result))
        end
        originalPawn=result
        for _,change in ipairs(changes) do change.old=originalPawn end
        log('ORIGINAL_RECREATED '..originalPawn:GetFullName())
    end

    if valid(originalPawn) and valid(pc) then
        if valid(replacement) then
            originalPawn:K2_TeleportTo(replacement:K2_GetActorLocation(),replacement:K2_GetActorRotation())
        end
        restoreReferences()
        visibility(originalPawn,true)
        pc:Possess(originalPawn)
        local ok,err=pcall(function() pc:ClientRestart(originalPawn);originalPawn:OnInitializationComplete() end)
        if not ok then log('RESTORE_INPUT_RESTART_FAILED '..tostring(err)) end
        if valid(replacement) then
            -- References and possession have been restored before destruction.
            replacement:K2_DestroyActor()
            log('REPLACEMENT_DESTROYED after restore')
        end
        replacement=nil
        log('RESTORED original player; temporary replacement removed')
    end
    clearSelector('manual restore'); active=false;refreshTicks=nil
    if valid(originalPawn) and valid(pc) then originalPawn:EnableInput(pc) end
end
local function lifecycle(pawn,name,...)
    local args=table.pack(...)
    local ok,err=pcall(function() pawn[name](pawn,table.unpack(args,1,args.n)) end)
    if ok then log('LIFECYCLE '..name) else log('LIFECYCLE_UNAVAILABLE '..name..' '..tostring(err)) end
    return ok
end
local function showMesh(pawn)
    visibility(pawn,true)
    -- ACharacter::GetMesh is not reflected in this build. Read its reflected
    -- Mesh property, with a component lookup if the property is unavailable.
    local ok,mesh=pcall(function() return pawn:GetPropertyValue('Mesh') end)
    local found=false
    local function show(component)
        component:SetHiddenInGame(false,true);component:SetVisibility(true,true)
        found=true
    end
    if ok and valid(mesh) then show(mesh) else
        for _,component in ipairs(FindAllOf('SkeletalMeshComponent') or {}) do
            if valid(component) and same(component:GetOwner(),pawn) then show(component) end
        end
    end
    if not found then log('MESH_LOOKUP_EMPTY '..pawn:GetFullName()) end
end
local function setupInput(pawn,source)
    local custom=pawn:GetPropertyValue('CustomInputComponent')
    assert(valid(custom),'Replacement custom input component missing')
    if source then
        for field,value in pairs(source) do custom:SetPropertyValue(field,value) end
        log('INPUT_DIRECTION_SETUP copied from original pawn')
    end
    -- Native actor InputComponent drives the input stack; CustomInputComponent
    -- is the pointer read by SMB abilities. They must reference the same object.
    local native=pawn:GetPropertyValue('InputComponent')
    log('INPUT_COMPONENTS native='..(valid(native) and native:GetFullName() or 'none')..' custom='..custom:GetFullName())
    pawn:DisableInput(pc)
    pawn:SetPropertyValue('InputComponent',custom)
    pawn:EnableInput(pc)
    log('INPUT_STACK_READY '..custom:GetFullName())
end
local function captureInput(pawn)
    local input=pawn:GetPropertyValue('CustomInputComponent')
    assert(valid(input),'Original custom input component missing')
    local saved={}
    for _,field in ipairs({'bUseExternalMovementDir','bForwardInputEnabled','bRightInputEnabled','CurrentPlayerInputMode'}) do
        local value=input:GetPropertyValue(field)
        if type(value)=='boolean' or type(value)=='number' then saved[field]=value end
    end
    for _,field in ipairs({'ExternalForward','ExternalRight'}) do
        local v=input:GetPropertyValue(field)
        if v then saved[field]={X=v.X,Y=v.Y,Z=v.Z} end
    end
    local camera=input:GetPropertyValue('Camera')
    if valid(camera) then saved.Camera=camera end
    return saved
end
local function refreshReplacement(initial)
    if not valid(replacement) or not replacement:IsPlayerControlled() then return end
    if initial then
        -- The normal spawn initializes this after possession; direct SpawnActor
        -- runs BeginPlay before there is a player controller.
        lifecycle(replacement,'OnInitializationComplete')
        -- Do not call fOnPlayerCharReplaced: it can restart level spawning.
        local restarted=lifecycle(pc,'ClientRestart',replacement)
        if not restarted then error('Controller input restart failed; refusing incomplete swap') end
        setupInput(replacement,sourceInputSettings)
    end
    lifecycle(replacement,'IOnPlayerSpawned')
    lifecycle(replacement,'IOnRespawnCameraFadeInFinished')
    showMesh(replacement)
    if valid(originalPawn) then originalPawn:SetActorHiddenInGame(true);originalPawn:SetActorEnableCollision(false) end
    local ok,canMove=pcall(function() return replacement:CanCharacterMove() end)
    log('PLAYER_READY initial='..tostring(initial)..' CanCharacterMove='..(ok and tostring(canMove) or 'unavailable'))
end
local function spawnTofu()
    pc=controller();originalPawn=player();gi=instance()
    assert(pc and originalPawn and gi,'No live level player/controller/instance')
    sourceInputSettings=captureInput(originalPawn)
    originalClass=originalPawn:GetClass()
    local data=row()
    assert(data.PlayerCharClass==18,'Unexpected TofuBoy row enum')
    local system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    assert(valid(system),'System library unavailable')
    -- Load the exact soft class from the captured character row, no guessed path.
    local class=system:LoadClassAsset_Blocking(data.PlayerCharClassBP)
    assert(valid(class),'Unable to load TofuBoy playable Blueprint')
    log('CLASS_LOADED '..class:GetFullName())
    originalSelector=gi:GetPropertyValue('CurrentPlayerCharacterClass')
    local view=pc:GetViewTarget()
    gi:SetPropertyValue('CurrentPlayerCharacterClass',data.PlayerCharClass)
    replacement=pc:GetWorld():SpawnActor(class,originalPawn:K2_GetActorLocation(),originalPawn:K2_GetActorRotation())
    assert(valid(replacement),'SpawnActor returned invalid pawn')
    assert(replacement:IsA('/Script/SMB.TofuBoy'),'Spawned class is not a TofuBoy')
    -- Retain original pawn for rollback; do not destroy it or fake a death.
    pc:Possess(replacement)
    assert(replacement:IsPlayerControlled(),'Possession verification failed')
    patchReferences(originalPawn,replacement)
    if valid(view) and not same(view,originalPawn) then pc:SetViewTargetWithBlend(view,0.0,0,0.0,false) end
    -- Retain event processing on the parked original during this experiment.
    -- Remove its input, visibility and collision while preserving rollback.
    originalPawn:SetActorHiddenInGame(true)
    originalPawn:SetActorEnableCollision(false)
    originalPawn:DisableInput(pc)
    active=true
    refreshReplacement(true)
    settleTicks=3; initialReady=false
    log('APPLIED_VERIFIED '..replacement:GetFullName()..'; immediate replacement initialized. F8 restores.')
end
local function request()
    if attempted then log('ATTEMPT_ALREADY_USED: re-enter the level before another test'); return end
    if not controller() then log('IGNORED enter a normal level'); return end
    if not playerLookupReady then log('REFUSED: game player lookup hook unavailable');return end
    attempted=true
    local ok,err=pcall(spawnTofu)
    if not ok then
        log('SPAWN_FAILED '..tostring(err))
        local good,problem=pcall(restore)
        if not good then log('RESTORE_FAILED '..tostring(problem)) end
    end
end
local function install()
    if not controller() then return end
    for _,path in ipairs({'/Game/Misc/GM_Level.GM_Level_C:IOnPlayerSpawned',
        '/Game/Misc/GM_Level.GM_Level_C:IOnRespawnCameraFadeInFinished'}) do
    if not installed[path] then
        local fn=StaticFindObject(path)
        if valid(fn) then
            local ok,err=pcall(RegisterHook,path,function()
                if active then refreshTicks=2;log('RESPAWN_OBSERVED refreshing replacement after spawn') end
            end)
            if ok then installed[path]=true;log('HOOK_READY '..path) else log('HOOK_FAILED '..tostring(err)) end
        end
    end
    end
end
local function tick()
    install()
    if active and valid(replacement) then
        local controlled=pc:K2_GetPawn()
        if not same(controlled,replacement) then
            log('CONTROL_TAKEN_BACK actual='..(valid(controlled) and controlled:GetFullName() or 'none'))
            -- Do not fight the game's controller indefinitely or create more actors.
            restore(); settleTicks=nil; return
        end
        if settleTicks then
            settleTicks=settleTicks-1
            if settleTicks<=0 then
                settleTicks=nil;initialReady=true
                -- Remove the original source pawn only after verified possession.
                -- This removes its old input component and lets actor queries find
                -- the replacement instead of an unpossessed hidden Meat Boy.
                if valid(originalPawn) then
                    originalPawn:K2_DestroyActor()
                    originalPawn=nil
                    log('ORIGINAL_REMOVED after stable possession')
                end
                log('CONTROL_STABLE controller pawn='..controlled:GetFullName())
            end
        end
    end
    if refreshTicks and active then
        refreshTicks=refreshTicks-1
        if refreshTicks<=0 then refreshTicks=nil;refreshReplacement(false) end
    end
    if active and valid(gi) then
        gi:SetPropertyValue('CurrentPlayerCharacterClass',18)
        if valid(originalPawn) then
            originalPawn:SetActorHiddenInGame(true)
            originalPawn:SetActorEnableCollision(false)
        end
    end
end
local function safe(fn)
    local ok,err=pcall(fn);if not ok then log('ERROR '..tostring(err)) end
end
local function hook(path,fn)
    local ok,err=pcall(RegisterHook,path,function() safe(fn) end)
    if not ok then log('HOOK_FAILED '..path..' '..tostring(err)) end
end
-- Native post-hook return override: game's player lookup must resolve the
-- same pawn as the level controller, not the old parked character.
local lookupOK,lookupError=pcall(RegisterHook,'/Script/SMB.TunnelLibrary:GetMeatBoy',function() end,function()
    if active and inLevel(replacement) and valid(pc) and same(pc:K2_GetPawn(),replacement) then
        return replacement
    end
end)
playerLookupReady=lookupOK
if not lookupOK then log('PLAYER_LOOKUP_HOOK_FAILED '..tostring(lookupError)) end
hook('/Script/Engine.GameplayStatics:OpenLevel',function()
    local c=controller();if c then sceneKey=currentScene(c) end
    traveling=true
    clearSelector('level travel');active=false;refreshTicks=nil;settleTicks=nil;attempted=false;changes={};originalPawn=nil;replacement=nil;originalSelector=nil;originalClass=nil;sourceInputSettings=nil
end)

-- A completed scene stays blocked until a different UWorld is observed.
-- OpenLevel can return before the old world is removed, so do not reset here.
for _,name in ipairs({'SetLevelFinished','SetLevelFinishedForLevel','SetBossDefeated'}) do
    hook('/Script/SMB.SaveSlotDataLibrary:'..name,function()
        local c=controller()
        if c then sceneKey=currentScene(c);sceneCompleted=true;log('TOFU_SCENE_COMPLETED traps wait for next scene') end
    end)
end
local function acknowledge(index)
    local file,err=io.open(base..'/tofu-acks-'..session..'.txt','a')
    if not file then error('Cannot acknowledge Tofu Trap: '..tostring(err)) end
    local written,writeError=file:write(index..'\n')
    local closed,closeError=file:close()
    if not written or not closed then error('Cannot persist Tofu Trap consumption: '..tostring(writeError or closeError)) end
    acknowledged[index]=true
end
local function incoming()
    local state=getState()
    if state.session~=session then
        if active then restore() end
        session=state.session;acknowledged={};deferred={};attempted=false
        if session then
            local file=io.open(base..'/tofu-acks-'..session..'.txt','r')
            if file then for line in file:lines() do acknowledged[line]=true end;file:close() end
        end
    end
    local existingController=controller()
    if existingController then
        local observed=currentScene(existingController)
        if observed~=sceneKey then sceneKey=observed;sceneCompleted=false;traveling=false end
    end
    if not session or not state.connected then return end
    local file=io.open(base..'/tofu-in-'..session..'.txt','r')
    if not file then return end
    local text=file:read('*a');file:close()
    if text:sub(1,10)~='TOFUTRAP1\n' then return end
    -- Do not consume or acknowledge queued traps before they can activate.
    local levelController=controller()
    local current=player()
    if not levelController or not current then return end
    local scene=currentScene(levelController)
    if scene~=sceneKey then
        sceneKey=scene;sceneCompleted=false;traveling=false
    end
    local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    local blocked=sceneCompleted or traveling or gameplay:IsGamePaused(current)
        or levelController:IsMoveInputIgnored() or current:GetPropertyValue('bIsDead')==true
        or not current:CanCharacterMove()
    for line in text:gmatch('[^\n]+') do
        local index=line:match('^(%d+)$')
        if index and not acknowledged[index] then
            if blocked then
                if not deferred[index] then
                    deferred[index]=scene
                    log('TOFU_TRAP_DEFERRED index='..index..' until scene change')
                end
            elseif deferred[index]~=scene then
                -- Persist consumption before applying: reconnects never replay it.
                acknowledge(index);deferred[index]=nil
                if active then log('TOFU_TRAP_CONSUMED already active; item index='..index)
                elseif attempted then log('TOFU_TRAP_FAILED prior swap failed in this scene; item index='..index)
                else log('TOFU_TRAP_RECEIVED index='..index);request() end
            end
        end
    end
end
function M.initialize(directory,stateReader,logger)
    base=directory;getState=stateReader;log=logger
    local scriptPath=debug.getinfo(1,'S').source:match('^@(.+[/\\])')
    local abilities=dofile(scriptPath..'tofu_input.lua')
    abilities.initialize(function()
        return active and valid(replacement) and valid(pc) and same(pc:K2_GetPawn(),replacement),pc,replacement
    end,log)
    if LoopInGameThreadWithDelay then LoopInGameThreadWithDelay(250,function() safe(function() incoming();tick() end) end) end
    log('Tofu Trap bridge initialized v0.6.1 (deferred until controllable next scene).')
end
return M
