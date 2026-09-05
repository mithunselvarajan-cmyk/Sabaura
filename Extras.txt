local print = function() end
local warn  = function() end
do
    local HS = game:GetService("HttpService")
    local FILE = "MynxxHub.json"
    local data
    local function load()
        if data then return data end
        data = {}
        if readfile then
            pcall(function()
                local raw = readfile(FILE)
                local t = HS:JSONDecode(raw)
                if type(t) == "table" then data = t end
            end)
        end
        return data
    end
    _G.HubCfg = {
        get = function(section)
            local d = load()
            if type(d[section]) ~= "table" then d[section] = {} end
            return d[section]
        end,
        save = function()
            if not writefile then return end
            pcall(function() writefile(FILE, HS:JSONEncode(load())) end)
        end,
    }
end

-- ============================================================
-- ETALEMENT DU DEMARRAGE (anti-freeze a l execution)
-- Les blocs ci-dessous s executent en direct, mais on decale chacun de
-- quelques frames (stagSpawn) pour qu ils ne saturent pas la meme frame au
-- chargement. Ce n est PAS le delai de 7s (retire): l etalement total fait
-- ~0.25s, imperceptible, mais supprime le pic/freeze de lancement.
-- ============================================================
local __stgN = 0
local function stagSpawn(fn)
    __stgN = __stgN + 1
    local n = __stgN
    task.spawn(function()
        -- differe extras de 6s: laisse le TP (invisible.txt) s initialiser en
        -- priorite au chargement -> jeu plus fluide, TP mieux optimise.
        task.wait(6)
        for _ = 1, n do task.wait() end
        -- attendre que LocalPlayer existe: les blocs partent tot (stagSpawn) et
        -- certains lisent Players.LocalPlayer directement -> nil si trop tot
        local Players = game:GetService("Players")
        while not Players.LocalPlayer do task.wait() end
        fn()
    end)
end

-- comme stagSpawn mais SANS le differe de 6s ni le stagger: pour les blocs qui
-- doivent etre actifs IMMEDIATEMENT (anti-ragdoll, FOV). Attend juste LocalPlayer.
local function nowSpawn(fn)
    task.spawn(function()
        local Players = game:GetService("Players")
        while not Players.LocalPlayer do task.wait() end
        fn()
    end)
end

-- ============================================================
-- INVISIBLE STEAL + WALKSPEED  (portage COMPLET de mynxx)
-- Tout le code fonctionnel est repris: clone du rig, suppression du DoubleRig,
-- animation trickery, detection de lagback + ghosts + error orb, auto-recover,
-- auto-invis pendant le steal, death listener, walkspeed CFrame bypass.
-- Seule l UI a ete refaite en version minimale.
--
-- EXECUTION DIRECTE: ce bloc invisible steal demarre immediatement (nowSpawn:
-- PAS le differe de 6s de stagSpawn). WaitForChild gere l attente du
-- PlayerGui/Character sans bloquer le reste du script.
-- ============================================================
nowSpawn(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local HS         = game:GetService("HttpService")
    local LP         = Players.LocalPlayer
    local PG         = LP:WaitForChild("PlayerGui")

    ------------------------------------------------------------------
    -- CONFIG PERSISTANTE
    ------------------------------------------------------------------
    -- section "invis" du fichier partage MynxxHub.json
    local cfg = _G.HubCfg.get("invis")
    local function saveCfg()
        cfg.angle  = _G.InvisStealAngle
        cfg.depth  = _G.SinkSliderValue
        cfg.ws     = _G.MynxxWSValue
        cfg.wsOn   = _G.MynxxWSEnabled
        cfg.aInv   = _G.AutoInvisDuringSteal
        cfg.aRec   = _G.AutoRecoverLagback
        cfg.panelX = _G.InvisPanelX
        cfg.panelY = _G.InvisPanelY
        _G.HubCfg.save()
    end

    if _G.InvisStealAngle     == nil then _G.InvisStealAngle     = 225   end  -- valeur mynxx (etait 180)
    if _G.SinkSliderValue     == nil then _G.SinkSliderValue     = 8     end  -- garde 8 = s enfonce + profond (mieux cache)
    if _G.MynxxWSValue       == nil then _G.MynxxWSValue       = 28    end
    if _G.MynxxWSEnabled     == nil then _G.MynxxWSEnabled     = true  end
    if _G.AutoInvisDuringSteal== nil then _G.AutoInvisDuringSteal= false end
    if _G.AutoRecoverLagback  == nil then _G.AutoRecoverLagback  = true  end
    do
        if tonumber(cfg.angle) then _G.InvisStealAngle = tonumber(cfg.angle) end
        if tonumber(cfg.depth) then _G.SinkSliderValue = tonumber(cfg.depth) end
        if tonumber(cfg.ws)    then _G.MynxxWSValue   = tonumber(cfg.ws) end
        if type(cfg.wsOn) == "boolean" then _G.MynxxWSEnabled      = cfg.wsOn end
        if type(cfg.aInv) == "boolean" then _G.AutoInvisDuringSteal = cfg.aInv end
        if type(cfg.aRec) == "boolean" then _G.AutoRecoverLagback   = cfg.aRec end
        if tonumber(cfg.panelX) then _G.InvisPanelX = tonumber(cfg.panelX) end
        if tonumber(cfg.panelY) then _G.InvisPanelY = tonumber(cfg.panelY) end
    end
    _G.invisibleStealEnabled = false

    ------------------------------------------------------------------
    -- ETAT
    ------------------------------------------------------------------
    local animPlaying      = false
    local tracks           = {}
    local folderConns      = {}
    local serverGhosts     = {}
    local ghostEnabled     = true
    local lagbackCallCount = 0
    local lagbackWindow    = 0
    local lastLagback      = 0
    local errorOrbActive   = false
    local errorOrb, errorOrbConn
    local oldRoot, cloneRoot, hip, conn
    local refreshUI

    ------------------------------------------------------------------
    -- GHOSTS DE LAGBACK
    -- Quand le serveur nous rembobine, l ancien root saute d un coup. On pose
    -- une bille rouge la ou le serveur nous a remis. 7 lagbacks en 1s = le
    -- serveur nous refuse en boucle -> error orb, on arrete de spammer.
    ------------------------------------------------------------------
    local function clearErrorOrb()
        if errorOrb and errorOrb.Parent then errorOrb:Destroy() end
        errorOrb = nil; errorOrbActive = false
        if errorOrbConn then errorOrbConn:Disconnect(); errorOrbConn = nil end
    end

    local function createErrorOrb()
        if errorOrbActive then return end
        errorOrbActive = true
        for _, g in pairs(serverGhosts) do if g and g.Parent then g:Destroy() end end
        serverGhosts = {}
    end

    local function clearAllGhosts()
        for _, g in pairs(serverGhosts) do
            pcall(function() if g and g.Parent then g:Destroy() end end)
        end
        serverGhosts = {}; clearErrorOrb()
        lagbackCallCount = 0; lastLagback = 0
        pcall(function()
            if workspace.CurrentCamera then
                for _, c in pairs(workspace.CurrentCamera:GetChildren()) do
                    if c.Name == "LagbackGhost" then c:Destroy() end
                end
            end
        end)
    end

    local function createServerGhost(pos)
        if not ghostEnabled or errorOrbActive then return end
        local now = tick()
        if now - lastLagback < 0.05 then return end
        lastLagback = now
        if now - lagbackWindow > 1 then lagbackCallCount = 0; lagbackWindow = now end
        lagbackCallCount = lagbackCallCount + 1
        if lagbackCallCount >= 7 then createErrorOrb(); return end
        for _, g in pairs(serverGhosts) do if g and g.Parent then g:Destroy() end end
        serverGhosts = {}
        local g = Instance.new("Part")
        g.Name = "LagbackGhost"; g.Shape = Enum.PartType.Ball
        g.Size = Vector3.new(3, 3, 3); g.Color = Color3.fromRGB(255, 0, 0)
        g.Material = Enum.Material.Glass; g.Transparency = 0.3
        g.CanCollide = false; g.Anchored = true; g.CastShadow = false
        g.Position = pos + Vector3.new(0, 5, 0)
        g.Parent = workspace.CurrentCamera
        serverGhosts[#serverGhosts + 1] = g
    end

    ------------------------------------------------------------------
    -- WALKSPEED (CFrame bypass -- repris EXACTEMENT de message.txt/MYNXX)
    -- message.txt ne coupe le boost QUE sur MoveDirection == 0. L ancienne
    -- version extras ajoutait "velocity > 60 -> return", ce qui coupait le
    -- boost en plein saut / descente / elan et donnait cette sensation de
    -- walkspeed qui rame. Supprime.
    -- On garde uniquement le garde _G.MynxxStealHold: il n est vrai QUE
    -- pendant un TP scripte (invisible en jeu normal), et evite de relancer
    -- un lagback si tu tiens une touche pendant un steal-TP. Enleve cette
    -- ligne si tu veux la parite 100% message.txt.
    ------------------------------------------------------------------
    local WS = { enabled = false, conn = nil }
    local function setWalkSpeedEnabled(en)
        WS.enabled = en
        if WS.conn then WS.conn:Disconnect(); WS.conn = nil end
        if refreshUI then refreshUI() end
        if not en then return end
        WS.conn = RunService.Heartbeat:Connect(function(dt)
            if _G.FlingActive then return end   -- pause pendant un fling (sinon le CFrame ecrase la velocite)
            local c = LP.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local root = c and c:FindFirstChild("HumanoidRootPart")
            if not hum or not root or hum.Health <= 0 then return end
            -- walkspeed = parite 100% mynxx/message.txt: PAS de pause MynxxStealHold
            -- (c est cette pause qui coupait la vitesse -> "la speed qui rame")
            local target = tonumber(_G.MynxxWSValue) or 28
            if hum.MoveDirection.Magnitude > 0 and target > hum.WalkSpeed then
                root.CFrame = root.CFrame + (hum.MoveDirection * (target - hum.WalkSpeed) * dt)
            end
        end)
    end
    _G.setWalkSpeedEnabled = setWalkSpeedEnabled

    -- clamp 15..29 comme message.txt (au-dela le CFrame devient visible cote
    -- serveur et provoque des lagbacks)
    local function setWalkSpeedValue(v)
        v = math.clamp(math.floor((tonumber(v) or 28) + 0.5), 15, 29)
        _G.MynxxWSValue = v
        return v
    end
    _G.setWalkSpeedValue = setWalkSpeedValue
    setWalkSpeedValue(_G.MynxxWSValue)

    ------------------------------------------------------------------
    -- CLONE DU RIG
    ------------------------------------------------------------------
    local function removeFolders()
        local pf = workspace:FindFirstChild(LP.Name)
        if not pf then return end
        local dr = pf:FindFirstChild("DoubleRig")
        if dr then
            local rr = dr:FindFirstChild("HumanoidRootPart") or dr:FindFirstChildWhichIsA("BasePart")
            if rr and ghostEnabled then createServerGhost(rr.Position) end
            dr:Destroy()
        end
        local cs = pf:FindFirstChild("Constraints")
        if cs then cs:Destroy() end
        folderConns[#folderConns + 1] = pf.ChildAdded:Connect(function(child)
            if child.Name == "DoubleRig" then
                task.defer(function()
                    if not child or not child.Parent then return end
                    local rr = child:FindFirstChild("HumanoidRootPart") or child:FindFirstChildWhichIsA("BasePart")
                    if rr and ghostEnabled then createServerGhost(rr.Position) end
                    child:Destroy()
                end)
            elseif child.Name == "Constraints" then
                child:Destroy()
            end
        end)
    end



    if not _G._xenFixRig then
        local _rigBusy = false
        local _R = {
            {"Root","HumanoidRootPart","LowerTorso"},{"Waist","LowerTorso","UpperTorso"},
            {"Neck","UpperTorso","Head"},
            {"LeftShoulder","UpperTorso","LeftUpperArm"},{"LeftElbow","LeftUpperArm","LeftLowerArm"},
            {"LeftWrist","LeftLowerArm","LeftHand"},
            {"RightShoulder","UpperTorso","RightUpperArm"},{"RightElbow","RightUpperArm","RightLowerArm"},
            {"RightWrist","RightLowerArm","RightHand"},
            {"LeftHip","LowerTorso","LeftUpperLeg"},{"LeftKnee","LeftUpperLeg","LeftLowerLeg"},
            {"LeftAnkle","LeftLowerLeg","LeftFoot"},
            {"RightHip","LowerTorso","RightUpperLeg"},{"RightKnee","RightUpperLeg","RightLowerLeg"},
            {"RightAnkle","RightLowerLeg","RightFoot"},
        }
        local function _fix()
            local _ch = LP.Character
            if not _ch then return end
            local _h = _ch:FindFirstChildOfClass("Humanoid")
            if not _h or _h.RigType ~= Enum.HumanoidRigType.R15 or _h.Health <= 0 then return end
            for _, j in ipairs(_R) do
                local p, c = _ch:FindFirstChild(j[2]), _ch:FindFirstChild(j[3])
                if p and c then
                    local have = false
                    for _, d in ipairs(c:GetChildren()) do
                        if d:IsA("Motor6D") and d.Name == j[1] then have = true break end
                    end
                    if not have then
                        local a0 = p:FindFirstChild(j[1] .. "RigAttachment")
                        local a1 = c:FindFirstChild(j[1] .. "RigAttachment")
                        if a0 and a1 then
                            for _, d in ipairs(c:GetChildren()) do
                                if d:IsA("AnimationConstraint") and d.Name == j[1] then
                                    pcall(function() d.Enabled = false end)
                                end
                            end
                            pcall(function()
                                local m = Instance.new("Motor6D")
                                m.Name, m.Part0, m.Part1, m.C0, m.C1 = j[1], p, c, a0.CFrame, a1.CFrame
                                m.Parent = c
                            end)
                        end
                    end
                end
            end
        end
        _G._xenFixRig = function()
            if _rigBusy then return false end
            _rigBusy = true
            local ok = pcall(_fix)
            _rigBusy = false
            return ok
        end
    end

    local function invisClone()
        local c = LP.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return false end
        hip = hum.HipHeight
        oldRoot = c:FindFirstChild("HumanoidRootPart")
        if not oldRoot or not oldRoot.Parent then return false end
        for _, x in pairs(oldRoot:GetChildren()) do
            if x:IsA("Attachment") and (x.Name:find("Beam") or x.Name:find("Attach")) then x:Destroy() end
        end
        for _, x in pairs(oldRoot:GetChildren()) do
            if x:IsA("Beam") then x:Destroy() end
        end
        local tmp = Instance.new("Model"); tmp.Parent = game
        c.Parent = tmp
        cloneRoot = oldRoot:Clone(); cloneRoot.Parent = c
        oldRoot.Parent = workspace.CurrentCamera
        cloneRoot.CFrame = oldRoot.CFrame; c.PrimaryPart = cloneRoot
        c.Parent = workspace
        for _, v in pairs(c:GetDescendants()) do
            if v:IsA("Weld") or v:IsA("Motor6D") then
                if v.Part0 == oldRoot then v.Part0 = cloneRoot end
                if v.Part1 == oldRoot then v.Part1 = cloneRoot end
            end
        end
        tmp:Destroy()
        task.defer(function() if _G._xenFixRig then _G._xenFixRig() end end)
        return true
    end

    local function invisRevert()
        local c = LP.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not oldRoot or not oldRoot:IsDescendantOf(workspace) or not hum or hum.Health <= 0 then return end
        local tmp = Instance.new("Model"); tmp.Parent = game
        c.Parent = tmp
        oldRoot.Parent = c; c.PrimaryPart = oldRoot
        c.Parent = workspace; oldRoot.CanCollide = true
        for _, v in pairs(c:GetDescendants()) do
            if v:IsA("Weld") or v:IsA("Motor6D") then
                if v.Part0 == cloneRoot then v.Part0 = oldRoot end
                if v.Part1 == cloneRoot then v.Part1 = oldRoot end
            end
        end
        tmp:Destroy()
        if cloneRoot then
            local p = cloneRoot.CFrame
            cloneRoot:Destroy(); cloneRoot = nil
            oldRoot.CFrame = p
        end
        oldRoot = nil
        if hip then hum.HipHeight = hip end
        task.defer(function() if _G._xenFixRig then _G._xenFixRig() end end)
        clearAllGhosts()
    end

    local function animationTrickery()
        local c = LP.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return end
        local a = Instance.new("Animation")
        a.AnimationId = "http://www.roblox.com/asset/?id=18537363391"
        local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
        local tr = animator:LoadAnimation(a)
        tr.Priority = Enum.AnimationPriority.Action4
        tr:Play(0, 1, 0); a:Destroy()
        tracks[#tracks + 1] = tr
        tr.Stopped:Connect(function() if animPlaying then animationTrickery() end end)
        task.defer(function()
            tr.TimePosition = 0.7
            task.delay(0.3, function() pcall(function() tr:AdjustSpeed(math.huge) end) end)
        end)
    end

    ------------------------------------------------------------------
    -- ON / OFF
    ------------------------------------------------------------------
    local invisCooldown = 0

    local function invisTurnOff()
        clearAllGhosts()
        if not animPlaying then return end
        animPlaying = false; _G.invisibleStealEnabled = false
        for _, t in pairs(tracks) do pcall(function() t:Stop(0) end) end
        tracks = {}
        if conn then conn:Disconnect(); conn = nil end
        for _, x in ipairs(folderConns) do pcall(function() x:Disconnect() end) end
        folderConns = {}
        invisRevert(); clearAllGhosts()
        local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function()
                local animator = hum:FindFirstChildOfClass("Animator")
                if animator then
                    for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
                        if t.Priority == Enum.AnimationPriority.Action4
                        or t.Priority == Enum.AnimationPriority.Action3 then t:Stop(0) end
                    end
                end
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                task.defer(function()
                    if hum and hum.Parent then hum:ChangeState(Enum.HumanoidStateType.Running) end
                end)
            end)
        end
        -- la walkspeed suit l invis, sauf si tu l as coupee toi-meme
        if WS.enabled and _G.MynxxWSEnabled then setWalkSpeedEnabled(false) end
        invisCooldown = tick()
        if refreshUI then refreshUI() end
    end

    local function invisTurnOn()
        if animPlaying then return end
        local c = LP.Character
        if not c or not c:FindFirstChildOfClass("Humanoid") then return end
        animPlaying = true; _G.invisibleStealEnabled = true
        tracks = {}; removeFolders()
        if not invisClone() then
            animPlaying = false; _G.invisibleStealEnabled = false
            if refreshUI then refreshUI() end
            return
        end
        task.wait(0.05); animationTrickery()
        task.delay(1, function()
            if _G.invisibleStealEnabled and _G.MynxxWSEnabled and not WS.enabled then
                setWalkSpeedEnabled(true)
            end
        end)
        local lastSetPosition, skipFrames = nil, 5
        conn = RunService.PreSimulation:Connect(function()
            local ch = LP.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 or not oldRoot then return end
            local root = ch.PrimaryPart or ch:FindFirstChild("HumanoidRootPart")
            if not root then return end
            -- DETECTION LAGBACK: si l ancien root a saute de >6 studs entre
            -- 2 frames alors qu on porte un brainrot, c est le serveur qui
            -- nous a rembobines.
            if skipFrames > 0 then
                skipFrames = skipFrames - 1; lastSetPosition = nil
            elseif lastSetPosition and ghostEnabled then
                local cur = oldRoot.Position
                if (cur - lastSetPosition).Magnitude > 6
                   and not _G.RecoveryInProgress and LP:GetAttribute("Stealing") then
                    lastSetPosition = nil
                    createServerGhost(cur)
                    if _G.AutoRecoverLagback and _G._forceInvisToggle then
                        _G.RecoveryInProgress = true
                        task.spawn(function()
                            pcall(_G._forceInvisToggle); task.wait(0.6)
                            if LP:GetAttribute("Stealing") then pcall(_G._forceInvisToggle) end
                            _G.RecoveryInProgress = false
                        end)
                    end
                end
            end
            if cloneRoot then cloneRoot.CanCollide = true end
            if oldRoot and oldRoot.Parent then
                for _, x in pairs(oldRoot:GetChildren()) do
                    if x:IsA("Attachment") or x:IsA("Beam") then x:Destroy() end
                end
                local sink = (tonumber(_G.SinkSliderValue) or 8) * 0.5
                oldRoot.CFrame = (root.CFrame - Vector3.new(0, sink, 0))
                    * CFrame.Angles(math.rad(tonumber(_G.InvisStealAngle) or 180), 0, 0)
                oldRoot.AssemblyLinearVelocity = root.AssemblyLinearVelocity
                oldRoot.CanCollide = false
                lastSetPosition = oldRoot.Position
            end
        end)
        if refreshUI then refreshUI() end
    end

    _G.toggleInvisibleSteal = function()
        if (tick() - invisCooldown) < 0.3 then return end
        if animPlaying then invisTurnOff() else invisTurnOn() end
    end
    -- bypass du debounce: utilise par l auto-recover et l auto-invis
    _G._forceInvisToggle = function()
        if animPlaying then invisTurnOff() else invisTurnOn() end
    end

    ------------------------------------------------------------------
    -- RESPAWN / MORT
    ------------------------------------------------------------------
    local function setupDeathListener()
        local ch = LP.Character
        local h = ch and ch:FindFirstChildOfClass("Humanoid")
        if h then
            h.Died:Connect(function()
                clearErrorOrb(); clearAllGhosts(); lagbackCallCount = 0
            end)
        end
    end
    setupDeathListener()

    LP.CharacterAdded:Connect(function(newChar)
        task.wait(0.1)
        clearErrorOrb(); clearAllGhosts(); lagbackCallCount = 0
        pcall(function()
            for _, x in pairs(workspace.CurrentCamera:GetChildren()) do
                if x:IsA("BasePart") and x.Name == "HumanoidRootPart" then x:Destroy() end
            end
        end)
        if oldRoot   then pcall(function() oldRoot:Destroy() end);   oldRoot = nil end
        if cloneRoot then pcall(function() cloneRoot:Destroy() end); cloneRoot = nil end
        animPlaying = false; _G.invisibleStealEnabled = false
        if conn then conn:Disconnect(); conn = nil end
        setupDeathListener()
        if refreshUI then refreshUI() end
        task.wait(0.2)
        local cam = workspace.CurrentCamera
        local h = newChar and newChar:FindFirstChildOfClass("Humanoid")
        if cam and h then cam.CameraSubject = h; cam.CameraType = Enum.CameraType.Custom end
    end)

    ------------------------------------------------------------------
    -- AUTO INVIS PENDANT LE STEAL
    ------------------------------------------------------------------
    task.spawn(function()
        local wasStealing, autoEnabled = false, false
        task.wait(1)
        while task.wait(0.15) do
            if not _G.AutoInvisDuringSteal then
                wasStealing = false; autoEnabled = false
            else
                local isStealing = LP:GetAttribute("Stealing")
                if isStealing and not wasStealing and not _G.invisibleStealEnabled then
                    -- DELAI 0.5s: l invis s active 0.5 seconde APRES le debut du steal
                    -- (au lieu d instant). Re-check qu on steal toujours apres l attente
                    -- -> si le steal a fini avant 0.5s, pas d invis.
                    task.spawn(function()
                        task.wait(0.5)
                        if LP:GetAttribute("Stealing") and not _G.invisibleStealEnabled then
                            pcall(_G._forceInvisToggle); autoEnabled = true
                        end
                    end)
                end
                if not isStealing and autoEnabled and _G.invisibleStealEnabled then
                    task.wait(0.3)
                    if not LP:GetAttribute("Stealing") then
                        pcall(_G._forceInvisToggle); autoEnabled = false
                    end
                end
                wasStealing = isStealing
            end
        end
    end)

    ------------------------------------------------------------------
    -- UI MINIMALE
    ------------------------------------------------------------------
    -- meme parent que le GUI AUTO KICK: gethui()/CoreGui + DisplayOrder ->
    -- passe PAR-DESSUS l UI du jeu au lieu d etre recouvert (parente a PG).
    local guiParent = (gethui and gethui()) or game:GetService("CoreGui") or PG
    pcall(function()
        local old = guiParent:FindFirstChild("InvisStealUI")
        if old then old:Destroy() end
    end)
    local sg = Instance.new("ScreenGui")
    sg.Name = "InvisStealUI"; sg.ResetOnSpawn = false; sg.DisplayOrder = 131
    pcall(function() sg.Parent = guiParent end)
    if not sg.Parent then sg.Parent = PG end

    local f = Instance.new("Frame", sg)
    f.Size = UDim2.fromOffset(206, 264)   -- + 2 rangs de presets (angle 180/220 + walkspeed 20/27)
    -- position restauree depuis MynxxHub.json (section invis)
    f.Position = UDim2.fromOffset(tonumber(_G.InvisPanelX) or 14,
                                  tonumber(_G.InvisPanelY) or 400)
    f.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
    f.BorderSizePixel = 0; f.Active = true; f.Draggable = true
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
    -- Draggable natif de Roblox: pas d evenement de fin de drag, on ecoute donc
    -- Position et on sauve en differe (sinon on ecrirait le fichier a chaque
    -- pixel parcouru pendant le deplacement).
    do
        local pending = false
        f:GetPropertyChangedSignal("Position"):Connect(function()
            if pending then return end
            pending = true
            task.delay(0.5, function()
                pending = false
                _G.InvisPanelX = f.AbsolutePosition.X
                _G.InvisPanelY = f.AbsolutePosition.Y
                saveCfg()
            end)
        end)
    end

    local ttl = Instance.new("TextLabel", f)
    ttl.Size = UDim2.new(1, 0, 0, 22); ttl.BackgroundTransparency = 1
    ttl.Text = "INVIS STEAL"; ttl.Font = Enum.Font.GothamBlack
    ttl.TextSize = 12; ttl.TextColor3 = Color3.new(1, 1, 1)

    local ups = {}
    local function mkBtn(y, label, get, set)
        local b = Instance.new("TextButton", f)
        b.Size = UDim2.new(1, -16, 0, 22); b.Position = UDim2.fromOffset(8, y)
        b.Font = Enum.Font.GothamBold; b.TextSize = 11
        b.TextColor3 = Color3.new(1, 1, 1); b.BorderSizePixel = 0
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        local function up()
            local on = get()
            b.Text = label .. (on and ": ON" or ": OFF")
            b.BackgroundColor3 = on and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45)
        end
        b.MouseButton1Click:Connect(function() set(); up(); saveCfg() end)
        up(); ups[#ups + 1] = up
    end

    -- ligne compacte "Label: valeur" + [-] [+]
    local function mkRow(y, label, min, max, step, dec, get, set)
        local l = Instance.new("TextLabel", f)
        l.BackgroundTransparency = 1; l.Position = UDim2.fromOffset(8, y)
        l.Size = UDim2.fromOffset(126, 18)
        l.Font = Enum.Font.Gotham; l.TextSize = 11
        l.TextColor3 = Color3.fromRGB(210, 210, 210)
        l.TextXAlignment = Enum.TextXAlignment.Left
        local function txt()
            l.Text = label .. ": " .. string.format("%." .. dec .. "f", tonumber(get()) or min)
        end
        local function mk(px, d, sym)
            local b = Instance.new("TextButton", f)
            b.Size = UDim2.fromOffset(24, 16); b.Position = UDim2.fromOffset(px, y + 1)
            b.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
            b.TextColor3 = Color3.new(1, 1, 1)
            b.Font = Enum.Font.GothamBold; b.TextSize = 13; b.Text = sym
            b.BorderSizePixel = 0
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
            b.MouseButton1Click:Connect(function()
                local v = (tonumber(get()) or min) + d * step
                -- arrondi au pas pour eviter la derive flottante (0.30000000004)
                v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
                set(v); txt(); saveCfg()
            end)
        end
        mk(140, -1, "-"); mk(170, 1, "+"); txt()
        return txt
    end

    mkBtn(26, "INVIS",       function() return animPlaying end,
                             function() _G.toggleInvisibleSteal() end)
    mkBtn(52, "WALKSPEED",   function() return WS.enabled end,
                             function()
                                 _G.MynxxWSEnabled = not WS.enabled
                                 setWalkSpeedEnabled(_G.MynxxWSEnabled)
                             end)
    mkBtn(78, "AUTO INVIS",  function() return _G.AutoInvisDuringSteal end,
                             function() _G.AutoInvisDuringSteal = not _G.AutoInvisDuringSteal end)
    mkBtn(104, "AUTO RECOVER", function() return _G.AutoRecoverLagback end,
                             function() _G.AutoRecoverLagback = not _G.AutoRecoverLagback end)

    refreshUI = function() for _, u in ipairs(ups) do pcall(u) end end

    local refreshAngleBtns, refreshWsBtns
    local refreshRot = mkRow(136, "Rotation",  0,  360, 5,   0,
        function() return _G.InvisStealAngle end,
        function(v) _G.InvisStealAngle = v; if refreshAngleBtns then refreshAngleBtns() end end)
    mkRow(160, "Depth",     0,  18,  0.1, 1, function() return _G.SinkSliderValue end, function(v) _G.SinkSliderValue = v end)
    local refreshWs = mkRow(184, "WalkSpeed", 15, 29,  1,   0,
        function() return _G.MynxxWSValue end,
        function(v) _G.setWalkSpeedValue(v); if refreshWsBtns then refreshWsBtns() end end)

    -- RANG PRESETS ROTATION: 180 / 220 cote a cote (vert = angle actuel)
    do
        local b180, b220
        refreshAngleBtns = function()
            local a = tonumber(_G.InvisStealAngle) or 180
            if b180 then b180.BackgroundColor3 = (math.abs(a - 180) < 0.5) and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45) end
            if b220 then b220.BackgroundColor3 = (math.abs(a - 220) < 0.5) and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45) end
        end
        local function mkAngleBtn(x, deg, label)
            local b = Instance.new("TextButton", f)
            b.Size = UDim2.fromOffset(91, 22); b.Position = UDim2.fromOffset(x, 208)
            b.BackgroundColor3 = Color3.fromRGB(45, 45, 45); b.TextColor3 = Color3.new(1, 1, 1)
            b.Font = Enum.Font.GothamBold; b.TextSize = 11; b.Text = label; b.BorderSizePixel = 0
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
            b.MouseButton1Click:Connect(function()
                _G.InvisStealAngle = deg
                if refreshRot then refreshRot() end
                refreshAngleBtns(); saveCfg()
            end)
            return b
        end
        b180 = mkAngleBtn(8, 180, "180\u{00B0}")
        b220 = mkAngleBtn(99, 220, "220\u{00B0}")
        refreshAngleBtns(); ups[#ups + 1] = refreshAngleBtns
    end

    -- RANG PRESETS WALKSPEED: 20 / 27 cote a cote (vert = walkspeed actuel)
    do
        local b20, b27
        refreshWsBtns = function()
            local w = tonumber(_G.MynxxWSValue) or 20
            if b20 then b20.BackgroundColor3 = (math.abs(w - 20) < 0.5) and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45) end
            if b27 then b27.BackgroundColor3 = (math.abs(w - 27) < 0.5) and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45) end
        end
        local function mkWsBtn(x, val, label)
            local b = Instance.new("TextButton", f)
            b.Size = UDim2.fromOffset(91, 22); b.Position = UDim2.fromOffset(x, 234)
            b.BackgroundColor3 = Color3.fromRGB(45, 45, 45); b.TextColor3 = Color3.new(1, 1, 1)
            b.Font = Enum.Font.GothamBold; b.TextSize = 11; b.Text = label; b.BorderSizePixel = 0
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
            b.MouseButton1Click:Connect(function()
                _G.setWalkSpeedValue(val)
                if refreshWs then refreshWs() end
                refreshWsBtns(); saveCfg()
            end)
            return b
        end
        b20 = mkWsBtn(8, 20, "20")
        b27 = mkWsBtn(99, 27, "27")
        refreshWsBtns(); ups[#ups + 1] = refreshWsBtns
    end

    -- ACTIVATION AU CHARGEMENT (ligne 11089 de mynxx). C est ce qui manquait:
    -- mon code se contentait de rafraichir le bouton sans jamais appeler
    -- setWalkSpeedEnabled, donc le walkspeed n etait JAMAIS actif tant qu on
    -- ne passait pas par l invis. Chez mynxx c est une option autonome.
    if _G.MynxxWSEnabled then
        task.defer(function() setWalkSpeedEnabled(true) end)
    else
        refreshUI()
    end
end)

-- ============================================================
-- X-RAY  (portage de mynxx)
-- Rend semi-transparents les murs/decors des bases pour voir les brainrots
-- au travers. Event-driven: on applique une fois puis on suit DescendantAdded,
-- donc cout nul tant que rien ne streame (mynxx avait vire le re-walk 1.5s
-- qui faisait laguer).
--
-- 3 dependances de mynxx n existent pas ici et ont ete neutralisees:
--   _G.__laser            -> systeme de lasers absent, appels gardes
--   OriginalTransparency  -> table du FPS Boost Ultra, absente, gardee
--   Config/saveConfig/setToggle -> supprimes (plus de config, toujours ON)
--
-- CHARGEMENT INSTANTANE: le X-Ray part sans le differe de 6s (nowSpawn) pour
-- etre actif des l entree dans le jeu, comme le TP/auto-grab.
-- ============================================================
nowSpawn(function()
local okXR, errXR = pcall(function()
    local Players = game:GetService("Players")
    local LP = Players.LocalPlayer

    -- ANTI-CUMUL. Si un AUTRE script a deja un X-Ray actif (mynxx tourne en
    -- parallele avec "XRay":true dans sa config), les deux s empilent: le
    -- notre lit la transparence DEJA modifiee par l autre et la prend pour
    -- l originale -> 0.5 + (1-0.5)*0.60 = 0.80, d ou l effet "au max".
    -- On a 5s de retard sur les autres scripts, donc si _G.setXRay existe
    -- deja c est qu un X-Ray tourne: on laisse la main et on ne fait rien.
    if type(_G.setXRay) == "function" then
        warn("[XRAY] un autre X-Ray est deja actif -> celui-ci ne s applique pas (anti-cumul)")
        return
    end

    -- X-Ray TOUJOURS actif. L intensite est lue DIRECTEMENT depuis la config
    -- (section "carpet".xrayAlpha, la meme que le slider du menu Keybind) DES le
    -- lancement -> pas d attente du panneau (differe de 6s), pas de "pop" de 60%
    -- vers la valeur sauvee. Defaut 0.60 si aucune config.
    _G.XRayEnabled = true
    if _G.XRayAlpha == nil then
        local saved
        pcall(function()
            if _G.HubCfg then saved = tonumber(_G.HubCfg.get("carpet").xrayAlpha) end
        end)
        _G.XRayAlpha = math.clamp(saved or 0.60, 0, 1)
    end

    local origT = setmetatable({}, { __mode = "k" })
    local conns = {}
    local loopId = 0

    local function setTargetTransparency(instance, alpha, id)
        if not instance then return end
        if id and id ~= loopId then return end

        local function apply(obj)
            -- mynxx interceptait ici les lasers via _G.__laser (absent chez toi).
            -- L appel n etait PAS garde et aurait plante sur chaque objet.
            local laser = _G.__laser
            if laser and laser.IsLaserObject and laser.IsLaserObject(obj) then
                local plot = laser.GetPlotFromObject and laser.GetPlotFromObject(obj)
                if plot and laser.IsPlotBaseOpen and laser.IsPlotBaseOpen(plot) then
                    if laser.SaveLaserOriginal then laser.SaveLaserOriginal(obj) end
                    if laser.HideLaserObject then laser.HideLaserObject(obj) end
                end
                return
            end
            if obj:IsA("BasePart") then
                if origT[obj] == nil then
                    if obj.Transparency == alpha then origT[obj] = 0
                    else origT[obj] = obj.Transparency end
                end
                local o = origT[obj]
                if o < 1 then
                    local target = o + (1 - o) * alpha
                    if math.abs(obj.Transparency - target) > 0.01 then obj.Transparency = target end
                end
            elseif obj:IsA("TextLabel") or obj:IsA("TextButton") then
                if origT[obj] == nil then
                    local t, b = obj.TextTransparency, obj.BackgroundTransparency
                    if t == alpha then t = 0 end
                    if b == alpha then b = 0 end
                    origT[obj] = { text = t, bg = b }
                end
                local o = origT[obj]
                if o.text < 1 then
                    local tt = o.text + (1 - o.text) * alpha
                    if math.abs(obj.TextTransparency - tt) > 0.01 then obj.TextTransparency = tt end
                end
                if o.bg < 1 then
                    local tb = o.bg + (1 - o.bg) * alpha
                    if math.abs(obj.BackgroundTransparency - tb) > 0.01 then obj.BackgroundTransparency = tb end
                end
            elseif obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
                if origT[obj] == nil then
                    if obj.BackgroundTransparency == alpha then origT[obj] = 0
                    else origT[obj] = obj.BackgroundTransparency end
                end
                local o = origT[obj]
                if o < 1 then
                    local target = o + (1 - o) * alpha
                    if math.abs(obj.BackgroundTransparency - target) > 0.01 then obj.BackgroundTransparency = target end
                end
            elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                if origT[obj] == nil then
                    local i, b = obj.ImageTransparency, obj.BackgroundTransparency
                    if i == alpha then i = 0 end
                    if b == alpha then b = 0 end
                    origT[obj] = { img = i, bg = b }
                end
                local o = origT[obj]
                if o.img < 1 then
                    local ti = o.img + (1 - o.img) * alpha
                    if math.abs(obj.ImageTransparency - ti) > 0.01 then obj.ImageTransparency = ti end
                end
                if o.bg < 1 then
                    local tb = o.bg + (1 - o.bg) * alpha
                    if math.abs(obj.BackgroundTransparency - tb) > 0.01 then obj.BackgroundTransparency = tb end
                end
            end
        end

        apply(instance)
        local desc = instance:GetDescendants()
        for i, child in ipairs(desc) do
            apply(child)
            if i % 300 == 0 then
                task.wait()
                if id and id ~= loopId then return end
            end
        end
    end

    local XRAY_FOLDERS = { "Base", "PlotSign", "FriendPanel", "Cash",
                           "Decorations", "Skin", "Unlock", "Purchases" }

    local function trackSubtree(root, alpha, id)
        if not root then return end
        if id ~= loopId then return end
        setTargetTransparency(root, alpha, id)
        if id ~= loopId then return end
        conns[#conns + 1] = root.DescendantAdded:Connect(function(obj)
            if id ~= loopId then return end
            setTargetTransparency(obj, alpha, id)
        end)
    end

    local function processPlot(plot, alpha, id)
        if not plot then return end
        if id ~= loopId then return end
        for _, fname in ipairs(XRAY_FOLDERS) do
            if id ~= loopId then return end
            trackSubtree(plot:FindFirstChild(fname), alpha, id)
        end
        if id ~= loopId then return end
        conns[#conns + 1] = plot.ChildAdded:Connect(function(child)
            if id ~= loopId then return end
            for _, fname in ipairs(XRAY_FOLDERS) do
                if child.Name == fname then trackSubtree(child, alpha, id); break end
            end
        end)

        local podiums = plot:FindFirstChild("AnimalPodiums")
        if podiums then
            local function processPodium(podium)
                for _, child in ipairs(podium:GetChildren()) do
                    if child.Name == "Claim" then
                        trackSubtree(child, alpha, id)
                    elseif child.Name == "Base" then
                        trackSubtree(child:FindFirstChild("Decorations"), alpha, id)
                    elseif child:IsA("Model") and child.Name ~= "Decorations" then
                        trackSubtree(child, alpha, id)
                    end
                end
            end
            for _, podium in ipairs(podiums:GetChildren()) do processPodium(podium) end
            conns[#conns + 1] = podiums.ChildAdded:Connect(function(podium)
                if id ~= loopId then return end
                task.wait(0.1)
                if id ~= loopId then return end
                processPodium(podium)
            end)
        end
    end

    local function applyAllPlots(alpha, id)
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return end
        for _, plot in ipairs(plots:GetChildren()) do
            if id ~= loopId then return end
            processPlot(plot, alpha, id)
            -- pas de task.wait() inter-plot: on applique tous les plots dans la
            -- meme passe pour un X-Ray INSTANT au lancement. Le yield anti-freeze
            -- tous les 300 descendants (setTargetTransparency) suffit a lisser.
        end
        conns[#conns + 1] = plots.ChildAdded:Connect(function(plot)
            if id ~= loopId then return end
            task.wait(0.2)
            processPlot(plot, alpha, id)
        end)
    end

    local function setXRay(enabled)
        _G.XRayEnabled = enabled

        for _, c in ipairs(conns) do
            if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
        end
        conns = {}

        loopId = loopId + 1
        local id = loopId

        if enabled then
            local alpha = math.clamp(tonumber(_G.XRayAlpha) or 0.60, 0, 1)
            task.spawn(function()
                while id == loopId and not workspace:FindFirstChild("Plots") do
                    task.wait()   -- sondage a chaque frame: on attrape Plots des qu il apparait (X-Ray instant)
                end
                if id ~= loopId then return end
                pcall(applyAllPlots, alpha, id)
            end)
        else
            -- OFF instantane et complet: on echange le snapshot puis on restaure
            -- tout en UNE passe synchrone (pas de task.wait). Sans ca, un
            -- re-enable pouvait chevaucher la restauration et laisser des murs
            -- transparents.
            local snap = origT
            origT = setmetatable({}, { __mode = "k" })
            for obj, o in pairs(snap) do
                pcall(function()
                    if obj:IsA("BasePart") then
                        obj.Transparency = o
                    elseif obj:IsA("TextLabel") or obj:IsA("TextButton") then
                        obj.TextTransparency = o.text
                        obj.BackgroundTransparency = o.bg
                    elseif obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
                        obj.BackgroundTransparency = o
                    elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                        obj.ImageTransparency = o.img
                        obj.BackgroundTransparency = o.bg
                    end
                end)
            end
            -- mynxx restaurait ici les transparences du FPS Boost Ultra
            -- (table OriginalTransparency). Ce systeme n existe pas ici -> garde.
            local fps = _G.OriginalTransparency
            if type(fps) == "table" then
                for part, data in pairs(fps) do
                    if part and part.Parent and typeof(data) == "table" and data.trans then
                        pcall(function() part.Transparency = data.trans end)
                    end
                end
            end
            local laser = _G.__laser
            if laser and laser.RefreshAllPlotLasers then
                pcall(laser.RefreshAllPlotLasers)
            end
        end
    end
    _G.setXRay = setXRay
    _G.toggleXRay = function() setXRay(not _G.XRayEnabled) end

    -- Quand un joueur REJOINT le serveur alors qu on est deja dedans, sa base
    -- lui est assignee/streamee APRES coup et n emet pas toujours un plot
    -- ChildAdded propre. On re-applique donc le X-Ray (alpha COURANT, defaut
    -- 0.60 = les settings de base) des qu un joueur arrive, pour que la nouvelle
    -- base soit transparente instantanement. Debounce: si plusieurs joueurs
    -- rejoignent en meme temps, on ne rescanne qu une seule fois.
    local _xrReapplyPending = false
    Players.PlayerAdded:Connect(function()
        if not _G.XRayEnabled then return end
        if _xrReapplyPending then return end
        _xrReapplyPending = true
        task.spawn(function()
            task.wait(0.5)   -- laisse la base se streamer avant de rescanner
            _xrReapplyPending = false
            if _G.XRayEnabled then pcall(setXRay, true) end
        end)
    end)

    -- toujours actif
    task.spawn(function() setXRay(true) end)
end)

if not okXR then
    warn("[XRAY] BLOC EN ERREUR: " .. tostring(errXR))
    pcall(function()
        local sg = Instance.new("ScreenGui")
        sg.Name = "XRayError"; sg.ResetOnSpawn = false
        sg.Parent = (gethui and gethui()) or game:GetService("CoreGui")
        local t = Instance.new("TextLabel", sg)
        t.Size = UDim2.new(0, 460, 0, 44); t.Position = UDim2.new(0.5, -230, 0, 60)
        t.BackgroundColor3 = Color3.fromRGB(70, 12, 12)
        t.TextColor3 = Color3.new(1, 1, 1)
        t.Font = Enum.Font.GothamBold; t.TextSize = 11; t.TextWrapped = true
        t.Text = "XRAY ERREUR: " .. tostring(errXR)
    end)
end
end)

-- ============================================================
-- INFINITE JUMP (portage de mynxx: cooldown 0.1s, velocite 55)
-- Toujours actif. Tant que Espace est maintenu, on relance la vitesse
-- verticale a 55 toutes les 0.1s -- on saute donc en l air indefiniment.
-- Les composantes X/Z sont preservees pour ne pas casser l elan.
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okIJ, errIJ = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local LP         = Players.LocalPlayer

    _G.InfiniteJumpEnabled = true
    local lastJump, conn = 0, nil

    local function setInfiniteJump(en)
        _G.InfiniteJumpEnabled = en
        if conn then conn:Disconnect(); conn = nil end
        if not en then return end
        conn = RunService.Heartbeat:Connect(function()
            if not _G.InfiniteJumpEnabled then return end
            if not UIS:IsKeyDown(Enum.KeyCode.Space) then return end
            local now = tick()
            if now - lastJump < 0.1 then return end
            local c = LP.Character
            if not c then return end
            local hrp = c:FindFirstChild("HumanoidRootPart")
            local hum = c:FindFirstChildOfClass("Humanoid")
            if not hrp or not hum or hum.Health <= 0 then return end
            lastJump = now
            hrp.AssemblyLinearVelocity =
                Vector3.new(hrp.AssemblyLinearVelocity.X, 55, hrp.AssemblyLinearVelocity.Z)
        end)
    end
    _G.setInfiniteJump = setInfiniteJump

    setInfiniteJump(true)
end)

if not okIJ then warn("[INFJUMP] BLOC EN ERREUR: " .. tostring(errIJ)) end
end)

-- ============================================================
-- ANTI-RAGDOLL + ANTI-KNOCKBACK (standalone, portage 1:1 de buzz source.lua)
-- Force la sortie des etats Physics/Ragdoll/FallingDown/GettingUp, retire les
-- contraintes de ragdoll (BallSocket/NoCollision/Hinge + attachments A/B),
-- reactive les Motor6D, coupe les anims de chute, rend camera + controles.
-- Anti-knockback: remet AssemblyLinearVelocity a 0 sur ApplyImpulse et ecrete
-- les pics de vitesse pendant un ragdoll (seuil 40 / max 15).
-- Auto-actif au lancement. Toggles: _G.toggleAntiRagdoll(true|false),
-- _G.enableAntiKnockback(), _G.disableAntiKnockback().
--
-- Adaptations pour CET environnement (sinon TP / knockback casses):
--   * ApplyImpulse resolu via le resolveur de remotes hashes (_G.MynxxGetRemote),
--     avec repli sur le chemin litteral Packages.Net["RE/CombatService/ApplyImpulse"].
--   * garde _G.MynxxStealHold + skip >60 studs/s dans le clamp Heartbeat pour ne
--     PAS ecreter la vitesse pendant un TP scripte (sinon arret net = lagback).
-- ============================================================
nowSpawn(function()
local okAR, errAR = pcall(function()
    local Players           = game:GetService("Players")
    local RunService        = game:GetService("RunService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Workspace         = workspace
    local player            = Players.LocalPlayer
    while not player do task.wait(); player = Players.LocalPlayer end

    -- shims host buzz -> no-ops ici
    local Config = { AntiRagdoll = false }
    local function setToggle() end
    local function saveConfig() end

    -- ANTI RAGDOLL
    -- Anti-Ragdoll System (comprehensive with knockback suppression)
    do
        local antiRagdollConnections = {}
        local antiRagdollCharacter, antiRagdollHumanoid, antiRagdollRootPart, antiRagdollAnimator
        local lastVelocity = Vector3.new(0, 0, 0)
        local velocityChangeThreshold = 40
        local velocityMagnitudeThreshold = 25
        local maxVelocity = 15

        local function isFlyingCarpetActive()
            if not antiRagdollCharacter then return false end
            local tool = antiRagdollCharacter:FindFirstChildWhichIsA("Tool")
            if not tool then return false end
            local hrp = antiRagdollCharacter:FindFirstChild("HumanoidRootPart")
            if hrp then
                for _, obj in ipairs(hrp:GetChildren()) do
                    if obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then
                        return true
                    end
                end
            end
            return false
        end

        local function isRagdolled()
            if not antiRagdollHumanoid then return false end
            local state = antiRagdollHumanoid:GetState()
            return state == Enum.HumanoidStateType.Physics
                or state == Enum.HumanoidStateType.Ragdoll
                or state == Enum.HumanoidStateType.FallingDown
                or state == Enum.HumanoidStateType.GettingUp
        end

        local function enableAntiRagdollControls()
            pcall(function()
                local PlayerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
                require(PlayerModule):GetControls():Enable()
            end)
        end

        local function cleanupRagdoll()
            if not antiRagdollCharacter then return end
            local carpetEquipped = isFlyingCarpetActive()

            local function processChildren(parent)
                for _, obj in ipairs(parent:GetChildren()) do
                    if obj:IsA("BallSocketConstraint") or obj:IsA("NoCollisionConstraint") or obj:IsA("HingeConstraint")
                        or (obj:IsA("Attachment") and (obj.Name == "A" or obj.Name == "B")) then
                        obj:Destroy()
                    elseif obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then
                        if not carpetEquipped then obj:Destroy() end
                    elseif obj:IsA("Motor6D") then
                        obj.Enabled = true
                    elseif obj:IsA("BasePart") then
                        for _, child in ipairs(obj:GetChildren()) do
                            if child:IsA("BallSocketConstraint") or child:IsA("NoCollisionConstraint") or child:IsA("HingeConstraint") or child:IsA("Motor6D") then
                                if child:IsA("Motor6D") then
                                    child.Enabled = true
                                else
                                    child:Destroy()
                                end
                            elseif child:IsA("Attachment") and (child.Name == "A" or child.Name == "B") then
                                child:Destroy()
                            end
                        end
                    end
                end
            end

            pcall(function() processChildren(antiRagdollCharacter) end)

            if antiRagdollAnimator then
                for _, track in pairs(antiRagdollAnimator:GetPlayingAnimationTracks()) do
                    local animName = track.Animation and track.Animation.Name:lower() or ""
                    if animName:find("rag") or animName:find("fall") or animName:find("hurt") or animName:find("down") then
                        track:Stop(0)
                    end
                end
            end
        end

        local function setupAntiRagdollCharacter(char)
            antiRagdollCharacter = char
            antiRagdollHumanoid = char:WaitForChild("Humanoid", 10)
            antiRagdollRootPart = char:WaitForChild("HumanoidRootPart", 10)
            antiRagdollAnimator = antiRagdollHumanoid and antiRagdollHumanoid:WaitForChild("Animator", 10)
            lastVelocity = Vector3.new(0, 0, 0)
        end

        local function clearAntiRagdollConnections()
            for _, c in pairs(antiRagdollConnections) do
                pcall(function() c:Disconnect() end)
            end
            antiRagdollConnections = {}
        end

        local function setupAntiRagdollConnections()
            clearAntiRagdollConnections()
            if not antiRagdollHumanoid or not antiRagdollRootPart then return end

            table.insert(antiRagdollConnections, antiRagdollHumanoid.StateChanged:Connect(function()
                if (_G.AntiRagdollEnabled or _G.antiKnockbackEnabled) and isRagdolled() then
                    if not isFlyingCarpetActive() then
                        antiRagdollHumanoid:ChangeState(Enum.HumanoidStateType.Running)
                    end
                    cleanupRagdoll()
                    pcall(function() Workspace.CurrentCamera.CameraSubject = antiRagdollHumanoid end)
                    enableAntiRagdollControls()
                end
            end))

            -- ApplyImpulse: resolveur hashe d abord, repli sur le chemin litteral
            pcall(function()
                local impulse
                if _G.MynxxGetRemote then
                    impulse = _G.MynxxGetRemote("RemoteEvent", "CombatService/ApplyImpulse")
                end
                if not impulse then
                    local pkgs = ReplicatedStorage:FindFirstChild("Packages")
                    local net  = pkgs and pkgs:FindFirstChild("Net")
                    impulse = net and net:FindFirstChild("RE/CombatService/ApplyImpulse")
                end
                if impulse then
                    table.insert(antiRagdollConnections, impulse.OnClientEvent:Connect(function()
                        if (_G.AntiRagdollEnabled or _G.antiKnockbackEnabled) and isRagdolled() then
                            antiRagdollRootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                        end
                    end))
                end
            end)

            table.insert(antiRagdollConnections, antiRagdollCharacter.DescendantAdded:Connect(function()
                if (_G.AntiRagdollEnabled or _G.antiKnockbackEnabled) and isRagdolled() then
                    cleanupRagdoll()
                end
            end))

            table.insert(antiRagdollConnections, RunService.Heartbeat:Connect(function()
                if (_G.AntiRagdollEnabled or _G.antiKnockbackEnabled) and isRagdolled() then
                    -- PENDANT UN TP: on ne touche a rien (sinon la vitesse du vol
                    -- serait ecretee a 15 -> arret net -> lagback).
                    if _G.MynxxStealHold then return end
                    if antiRagdollRootPart.AssemblyLinearVelocity.Magnitude > 60 then
                        lastVelocity = antiRagdollRootPart.AssemblyLinearVelocity
                        return
                    end
                    cleanupRagdoll()
                    local velocity = antiRagdollRootPart.AssemblyLinearVelocity
                    if (velocity - lastVelocity).Magnitude > velocityChangeThreshold
                        and velocity.Magnitude > velocityMagnitudeThreshold then
                        antiRagdollRootPart.AssemblyLinearVelocity = velocity.Unit * math.min(velocity.Magnitude, maxVelocity)
                    end
                    lastVelocity = velocity
                end
            end))

            enableAntiRagdollControls()
            cleanupRagdoll()
        end

        local function startAntiRagdoll()
            _G.AntiRagdollEnabled = true
            _G.antiKnockbackEnabled = true
            Config.AntiRagdoll = true; setToggle("Anti Ragdoll", true); saveConfig()
            if player.Character then
                setupAntiRagdollCharacter(player.Character)
                setupAntiRagdollConnections()
            end
        end

        local function stopAntiRagdoll()
            _G.AntiRagdollEnabled = false
            _G.antiKnockbackEnabled = false
            Config.AntiRagdoll = false; setToggle("Anti Ragdoll", false); saveConfig()
            clearAntiRagdollConnections()
        end

        _G.toggleAntiRagdoll = function(enabled)
            if enabled then startAntiRagdoll() else stopAntiRagdoll() end
        end
        _G.enableAntiKnockback = function() startAntiRagdoll() end
        _G.disableAntiKnockback = function() stopAntiRagdoll() end

        player.CharacterAdded:Connect(function(char)
            clearAntiRagdollConnections()
            antiRagdollCharacter = nil; antiRagdollHumanoid = nil; antiRagdollRootPart = nil; antiRagdollAnimator = nil
            local humanoid = char:WaitForChild("Humanoid", 10)
            local rootPart = char:WaitForChild("HumanoidRootPart", 10)
            if not humanoid or not rootPart then return end
            task.wait(0.2)
            setupAntiRagdollCharacter(char)
            if _G.AntiRagdollEnabled or _G.antiKnockbackEnabled then
                setupAntiRagdollConnections()
            end
        end)

        if player.Character then
            setupAntiRagdollCharacter(player.Character)
            if _G.AntiRagdollEnabled or _G.antiKnockbackEnabled then
                setupAntiRagdollConnections()
            end
        end
    end

    -- auto-enable on run (anti-ragdoll + anti-knockback)
    if _G.toggleAntiRagdoll then _G.toggleAntiRagdoll(true) end
end)

if not okAR then warn("[ANTIRAGDOLL] BLOC EN ERREUR: " .. tostring(errAR)) end
end)

-- ============================================================
-- NO-COLLISION JOUEUR : place toutes les parts du perso dans le CollisionGroup
-- "PlayerNoCollision" (plus de collision physique avec les autres joueurs).
-- pcall sur l assignation: si le groupe n existe pas cote client, on ignore.
-- ============================================================
nowSpawn(function()
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer
    if not LocalPlayer then return end

    local NO_COLLIDE_GROUP = "PlayerNoCollision"

    local function applyChar(char)
        local hrp = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 10)
        if not hrp then return end
        local function setPart(part)
            if part:IsA("BasePart") and part.Name ~= "__HITBOX" then
                pcall(function() part.CollisionGroup = NO_COLLIDE_GROUP end)
            end
        end
        for _, part in ipairs(char:GetDescendants()) do setPart(part) end
        char.DescendantAdded:Connect(setPart)
    end

    if LocalPlayer.Character then task.spawn(applyChar, LocalPlayer.Character) end
    LocalPlayer.CharacterAdded:Connect(applyChar)
end)

-- ============================================================
-- ANTI GUMMY BEAR  (ex AntiGummy.lua, fusionne ici)
-- ON par defaut. Clear BlockTools / Web + BackpackReady, detruit les
-- instances Workspace "GummyBear" (existantes + ChildAdded). Grace 1.5s
-- au respawn pour ne pas casser le loadout. Toggle: _G.AntiGummy.set(on)
-- IMPORTANT: c est ce bloc qui debloque le STEAL apres un item web/gummy.
-- timeUntilCanSteal() (Teleport) renvoie -1 tant que l attribut "Web" est pose
-- -> sans ce clear, le steal (et le hold-pendant-ragdoll) ne part JAMAIS apres
-- s etre fait web/gummy. On remet aussi BlockTools/BackpackReady a l etat OK.
-- nowSpawn: actif tout de suite (pas le differe 6s de stagSpawn).
-- ============================================================
nowSpawn(function()
local okAG, errAG = pcall(function()
    local cloneref = (type(cloneref) == "function" and cloneref) or function(o) return o end
    local Players   = cloneref(game:GetService("Players"))
    local Workspace = cloneref(game:GetService("Workspace"))
    local Player    = Players.LocalPlayer

    local antiGummy = true
    local antiGummyRespawnGraceUntil = 0

    Player.CharacterAdded:Connect(function(char)
        local hum = char:WaitForChild("Humanoid", 5)
        if not hum then return end
        antiGummyRespawnGraceUntil = tick() + 1.5
    end)

    local function clearGummyToolBlockState(char)
        for _, inst in ipairs({ Player, char }) do
            if inst then
                if inst:GetAttribute("BlockTools") ~= nil and inst:GetAttribute("BlockTools") ~= false then
                    inst:SetAttribute("BlockTools", false)
                end
                if inst:GetAttribute("Web") ~= nil and inst:GetAttribute("Web") ~= false then
                    inst:SetAttribute("Web", false)
                end
            end
        end
        if char and char:GetAttribute("BackpackReady") == false then
            char:SetAttribute("BackpackReady", true)
        end
    end

    local function deleteGummyBears()
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj.Name == "GummyBear" then
                pcall(function() obj:Destroy() end)
            end
        end
    end

    Workspace.ChildAdded:Connect(function(child)
        if antiGummy and child.Name == "GummyBear" then
            pcall(function() child:Destroy() end)
        end
    end)

    task.spawn(function()
        while task.wait(0.1) do
            if not antiGummy then continue end
            local char = Player.Character
            if not char then continue end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hum or not hrp then continue end
            if tick() >= antiGummyRespawnGraceUntil then
                clearGummyToolBlockState(char)
            end
        end
    end)

    deleteGummyBears()

    _G.AntiGummy = {
        set = function(on)
            antiGummy = on and true or false
            if antiGummy then deleteGummyBears() end
        end,
    }
end)
if not okAG then warn("[ANTI-GUMMY] BLOC EN ERREUR: " .. tostring(errAG)) end
end)

-- ============================================================
-- CLEAN ERROR POPUPS (portage de mynxx)
-- Toujours actif. GuiService:ClearError() ferme les popups d erreur Roblox
-- ("Disconnected", messages de kick, erreurs reseau) toutes les 0.1s.
-- cloneref si dispo: evite que le jeu remonte a notre reference du service.
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
    _G.CleanErrorGUIs = true
    local GS
    if cloneref then
        pcall(function() GS = cloneref(game:GetService("GuiService")) end)
    end
    GS = GS or game:GetService("GuiService")
    task.spawn(function()
        while true do
            if _G.CleanErrorGUIs then pcall(function() GS:ClearError() end) end
            task.wait(1)   -- throttle anti-freeze: clear error GUIs 10x/s -> 1x/s (inutile plus vite)
        end
    end)
end)

-- ============================================================
-- CARPET SPEED + INSTANT CLONE (portage de mynxx) + MENU KEYBIND
--
-- Carpet Speed: tant qu un tapis/planeur est equipe, on pousse le
-- HumanoidRootPart a 140 studs/s dans la direction du deplacement.
-- Il se COUPE tout seul si tu equipes un autre outil, pendant un TP et
-- pendant un steal. Et il est TOUJOURS OFF au lancement: son etat n est
-- jamais sauvegarde, seules les touches le sont.
--
-- Instant Clone: equipe le Quantum Cloner, l active, puis declenche le
-- bouton "TeleportToClone" du ToolsFrames via firesignal.
--
-- ACTIF TOUT DE SUITE: pas de differe de 6s (nowSpawn au lieu de stagSpawn) ->
-- le Carpet Speed et ses keybinds sont dispos des le chargement.
-- ============================================================
nowSpawn(function()
local okCC, errCC = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local HS         = game:GetService("HttpService")
    local LP         = Players.LocalPlayer
    local PG         = LP:WaitForChild("PlayerGui")
    local guiParent  = (gethui and gethui()) or game:GetService("CoreGui") or PG

    ------------------------------------------------------------------
    -- CARPET SPEED
    ------------------------------------------------------------------
    local SPEED_BOOST_TOOL_NAMES = {
        ["Flying Carpet"] = true, ["Carpet"] = true, ["Cloud"] = true,
        ["Witch's Broom"] = true, ["Cupid's Wings"] = true, ["Santa's Sleigh"] = true,
        ["Magic Carpet"] = true, ["Waverider"] = true,
    }

    -- JAMAIS persiste -> OFF a chaque relance du jeu
    local carpetOn, carpetConn, toolConn = false, nil, nil
    local refreshUI

    local function preferredTool()
        local t = _G.MynxxCarpetTool
        if type(t) == "string" and t ~= "" then return t end
        return "Flying Carpet"
    end

    local function isSpeedBoostTool(tool)
        if not tool or not tool:IsA("Tool") then return false end
        if SPEED_BOOST_TOOL_NAMES[tool.Name] then return true end
        return tool.Name == preferredTool()
    end

    local function getEquippedTool(char)
        if not char then return nil end
        return char:FindFirstChildWhichIsA("Tool")
    end

    local function equipSpeedBoostToolOnce(c, hum)
        if not c or not hum then return nil end
        local bp = LP:FindFirstChild("Backpack")
        local pref = preferredTool()
        if c:FindFirstChild(pref) then return pref end
        local tb = bp and bp:FindFirstChild(pref)
        if tb then pcall(function() hum:EquipTool(tb) end); return pref end
        for name in pairs(SPEED_BOOST_TOOL_NAMES) do
            if c:FindFirstChild(name) then return name end
            local t = bp and bp:FindFirstChild(name)
            if t then pcall(function() hum:EquipTool(t) end); return name end
        end
        return nil
    end

    -- mynxx utilisait _G._isTpMoving, absent ici. _G.MynxxStealHold est pose
    -- par le TP de ce script pendant tout le vol: meme role.
    local function isCarpetSpeedBlocked()
        if _G._isTpMoving then return true end
        if _G.MynxxStealHold then return true end
        if LP:GetAttribute("Stealing") then return true end
        return false
    end
    _G.isCarpetSpeedBlocked = isCarpetSpeedBlocked

    local setCarpetSpeed
    setCarpetSpeed = function(en)
        if en and isCarpetSpeedBlocked() then return end
        carpetOn = en
        if refreshUI then refreshUI() end
        if carpetConn then carpetConn:Disconnect(); carpetConn = nil end
        if not en then return end

        local c = LP.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if c and hum then equipSpeedBoostToolOnce(c, hum) end

        carpetConn = RunService.Heartbeat:Connect(function()
            local ch = LP.Character
            if not ch then return end
            local hrp = ch:FindFirstChild("HumanoidRootPart")
            if isCarpetSpeedBlocked() then
                if hrp then
                    hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                end
                return
            end
            local hm = ch:FindFirstChildOfClass("Humanoid")
            if not hm or not hrp then return end
            local equipped = getEquippedTool(ch)
            -- autre outil equipe = on coupe net
            if equipped and not isSpeedBoostTool(equipped) then
                hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                setCarpetSpeed(false)
                return
            end
            if equipped and isSpeedBoostTool(equipped) then
                local md = hm.MoveDirection
                if md.Magnitude > 0 then
                    hrp.AssemblyLinearVelocity =
                        Vector3.new(md.X * 140, hrp.AssemblyLinearVelocity.Y, md.Z * 140)
                else
                    hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
                end
            end
        end)
    end
    _G.setCarpetSpeed = setCarpetSpeed
    _G.toggleCarpetSpeed = function() setCarpetSpeed(not carpetOn) end

    local function stopFromToolSwitch(char)
        if not carpetOn or not char then return end
        local equipped = getEquippedTool(char)
        if equipped and not isSpeedBoostTool(equipped) then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0) end
            setCarpetSpeed(false)
        end
    end
    local function bindToolWatch(char)
        if toolConn then pcall(function() toolConn:Disconnect() end); toolConn = nil end
        if not char then return end
        toolConn = char.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                task.defer(function() stopFromToolSwitch(char) end)
            end
        end)
    end

    LP.CharacterAdded:Connect(function(char)
        bindToolWatch(char)
        if carpetOn then
            task.defer(function()
                local hum = char:WaitForChild("Humanoid", 10)
                if hum and carpetOn then equipSpeedBoostToolOnce(char, hum) end
            end)
        end
    end)
    if LP.Character then bindToolWatch(LP.Character) end

    ------------------------------------------------------------------
    -- INSTANT CLONE
    ------------------------------------------------------------------
    local function instantClone()
        local c = LP.Character
        if not c then return end
        local h = c:FindFirstChildOfClass("Humanoid")
        if not h then return end
        local bp = LP:FindFirstChild("Backpack")
        local cl = (bp and bp:FindFirstChild("Quantum Cloner")) or c:FindFirstChild("Quantum Cloner")
        if not cl then return end
        pcall(function() h:UnequipTools() end); task.wait()
        if cl.Parent ~= c then pcall(function() h:EquipTool(cl) end); task.wait() end
        local tf = PG:FindFirstChild("ToolsFrames")
        local qc = tf and tf:FindFirstChild("QuantumCloner")
        local tb = qc and qc:FindFirstChild("TeleportToClone")
        if not tb then return end
        _G.isCloning = true
        pcall(function() cl:Activate() end)
        task.wait(0.05)
        tb.Visible = true
        pcall(function() firesignal(tb.MouseButton1Click) end)
        pcall(function() firesignal(tb.MouseButton1Up) end)
        pcall(function() firesignal(tb.Activated) end)
        task.delay(0.55, function() _G.isCloning = false end)
    end
    _G.instantClone = instantClone

    ------------------------------------------------------------------
    -- FLOAT (portage de mynxx)
    -- Plateforme invisible 7x1x7 ancree 3.35 studs sous le personnage, qui
    -- le suit a chaque frame -> on reste en l air. Interdit tant qu on porte
    -- un brainrot (le jeu te fait tomber / annule le vol), et coupee
    -- automatiquement si un steal demarre pendant que Float est actif.
    ------------------------------------------------------------------
    local floatOn, floatPart, floatConn = false, nil, nil

    local function removeFloatPlatform()
        if floatConn then floatConn:Disconnect(); floatConn = nil end
        if floatPart then pcall(function() floatPart:Destroy() end); floatPart = nil end
    end

    local function createFloatPlatform()
        removeFloatPlatform()
        local c = LP.Character
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local p = Instance.new("Part")
        p.Size = Vector3.new(7, 1, 7)
        p.Anchored = true; p.CanCollide = true
        p.CanTouch = false; p.CanQuery = false
        p.Transparency = 1; p.CastShadow = false
        p.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 3.35, 0))
        p.Parent = workspace
        floatPart = p
        floatConn = RunService.Heartbeat:Connect(function()
            if not floatOn then return end
            local ch = LP.Character
            local h = ch and ch:FindFirstChild("HumanoidRootPart")
            if h and floatPart then
                floatPart.CFrame = CFrame.new(h.Position - Vector3.new(0, 3.35, 0))
            end
        end)
    end

    local function setFloat(on)
        -- jamais de Float en portant un brainrot
        if on and LP:GetAttribute("Stealing") then
            if refreshUI then refreshUI() end
            return
        end
        floatOn = on
        if on then createFloatPlatform() else removeFloatPlatform() end
        if refreshUI then refreshUI() end
    end
    _G.setFloat = setFloat
    _G.toggleFloat = function() setFloat(not floatOn) end

    -- coupure auto si un steal demarre alors que Float est actif
    LP:GetAttributeChangedSignal("Stealing"):Connect(function()
        if floatOn and LP:GetAttribute("Stealing") then setFloat(false) end
    end)
    -- la plateforme ne survit pas au respawn: on la recree
    LP.CharacterAdded:Connect(function()
        task.wait(0.5)
        if floatOn then removeFloatPlatform(); createFloatPlatform() end
    end)

    ------------------------------------------------------------------
    -- KEYBINDS + MENU
    ------------------------------------------------------------------
    local kbCfg = _G.HubCfg.get("carpet")   -- section du fichier partage
    local panelFrame   -- ref du cadre, pour le keybind "Main Menu" (show/hide)
    local binds = {
        { id = "carpet", label = "Carpet Speed",
          key = (type(_G.MynxxCarpetSpeedKeyName) == "string" and _G.MynxxCarpetSpeedKeyName) or "Q",
          run = function() setCarpetSpeed(not carpetOn) end },
        { id = "clone",  label = "Instant Clone",
          key = (type(_G.MynxxCloneKeyName) == "string" and _G.MynxxCloneKeyName) or "V",
          run = function() task.spawn(instantClone) end },
        { id = "float",  label = "Float", key = "Z",
          run = function() setFloat(not floatOn) end },
        -- _G.FlingUp est defini par le bloc RESET, plus bas dans ce fichier.
        -- On y accede a l appel (pas a la construction), donc il existe
        -- forcement quand tu appuies sur la touche. X = fling en l air.
        { id = "reset",  label = "Fling Up", key = "X",
          run = function() if _G.FlingUp then task.spawn(_G.FlingUp) end end },
        { id = "invis",  label = "Invisible Steal", key = "U",
          run = function() if _G.toggleInvisibleSteal then pcall(_G.toggleInvisibleSteal) end end },
        { id = "walkspeed", label = "WalkSpeed", key = "H",
          run = function()
              if _G.setWalkSpeedEnabled then
                  _G.MynxxWSEnabled = not _G.MynxxWSEnabled
                  _G.setWalkSpeedEnabled(_G.MynxxWSEnabled)
              end
          end },
        { id = "drop",   label = "Drop Brainrot", key = "G",
          run = function() if _G.MynxxDropBrainrot then pcall(_G.MynxxDropBrainrot) end end },
        { id = "faceaway", label = "Face Away", key = "F",
          run = function() if _G.MynxxToggleFaceAway then pcall(_G.MynxxToggleFaceAway) end end },
        { id = "kick",   label = "Kick", key = "Y",
          run = function() if _G.MynxxKick then pcall(_G.MynxxKick) end end },
        { id = "autobuy", label = "Auto Buy", key = "K",
          run = function() if _G.MynxxToggleAutoBuy then pcall(_G.MynxxToggleAutoBuy) end end },
        { id = "menu",   label = "Main Menu", key = "LeftControl",
          run = function() if panelFrame then panelFrame.Visible = not panelFrame.Visible end end },
    }
    local panelX, panelY = 240, 120

    do
        for _, b in ipairs(binds) do
            if type(kbCfg[b.id]) == "string" and #kbCfg[b.id] > 0 then b.key = kbCfg[b.id] end
        end
        -- NOTE: on ne relit volontairement AUCUN etat ON/OFF ici.
        -- Carpet Speed doit repartir OFF a chaque lancement.
        if tonumber(kbCfg.x) then panelX = tonumber(kbCfg.x) end
        if tonumber(kbCfg.y) then panelY = tonumber(kbCfg.y) end
        -- Distance d achat Auto Buy sauvegardee (slider "Buy Range" du menu).
        if tonumber(kbCfg.buyRange) then
            local r = math.clamp(math.floor(tonumber(kbCfg.buyRange)), 5, 150)
            _G.MynxxAutoBuyFireRange = r
            _G.MynxxAutoBuyRange     = r
        end
    end
    local function saveKb()
        kbCfg.x = panelX; kbCfg.y = panelY
        for _, b in ipairs(binds) do kbCfg[b.id] = b.key end
        _G.HubCfg.save()
    end

    local capturing = nil

    -- ============================================================
    -- KEYBINDS CLAVIER/SOURIS (meme methode que invisible.txt): supporte les
    -- boutons LATERAUX MB4/MB5. UIS ne les recoit pas -> poll (IsMouseButtonPressed
    -- / Enum.KeyCode.MouseButton4-5 / VK Windows 0x05-0x06). Format des binds:
    -- "Key:Q" / "Mouse:MouseButton4". Legacy "Q" -> "Key:Q" (normalise).
    -- ============================================================
    local VK_XBUTTON1, VK_XBUTTON2 = 0x05, 0x06
    local function _norm(s)
        if type(s) ~= "string" or s == "" then return nil end
        if string.find(s, ":", 1, true) then return s end
        return "Key:" .. s
    end
    local function _bindPretty(s)
        local n = _norm(s); if not n then return "NONE" end
        local kind, name = string.match(n, "^([^:]+):(.+)$")
        if kind == "Mouse" then
            local map = { MouseButton1="MB1", MouseButton2="MB2", MouseButton3="MB3",
                          MouseButton4="MB4", XButton1="MB4", MouseButton5="MB5", XButton2="MB5" }
            return map[name] or name
        end
        return name or n
    end
    local function _isMouseBtn(input)
        local nm = input.UserInputType and input.UserInputType.Name
        return nm == "MouseButton1" or nm == "MouseButton2" or nm == "MouseButton3"
            or nm == "MouseButton4" or nm == "MouseButton5"
    end
    local function _inputMatches(input, bind)
        bind = _norm(bind); if not bind then return false end
        local kind, name = string.match(bind, "^([^:]+):(.+)$")
        if kind == "Key" then
            return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == name
        elseif kind == "Mouse" then
            return input.UserInputType.Name == name
        end
        return false
    end
    local function _vkDown(vk)
        for _, fn in ipairs({ iskeydown, iskeypressed }) do
            if typeof(fn) == "function" then local ok, r = pcall(fn, vk); if ok and r then return true end end
        end
        if typeof(getkeystate) == "function" then
            local ok, r = pcall(getkeystate, vk)
            if ok then
                if r == true then return true end
                if type(r) == "number" and (r < 0 or (bit32 and bit32.band(r, 0x8000) ~= 0)) then return true end
            end
        end
        return false
    end
    local function _sideDown(side)
        local name = "MouseButton" .. tostring(side)
        local ok, uit = pcall(function() return Enum.UserInputType[name] end)
        if ok and uit then local ok2, p = pcall(function() return UIS:IsMouseButtonPressed(uit) end); if ok2 and p then return true end end
        local okk, kc = pcall(function() return Enum.KeyCode[name] end)
        if okk and kc then
            local ok2, p = pcall(function() return UIS:IsKeyDown(kc) end); if ok2 and p then return true end
            if typeof(iskeydown) == "function" then local ok3, p3 = pcall(iskeydown, kc); if ok3 and p3 then return true end end
        end
        return _vkDown(side == 5 and VK_XBUTTON2 or VK_XBUTTON1)
    end
    local function _bindIsSide(bind, side)
        bind = _norm(bind); if not bind then return false end
        local want = "Mouse:MouseButton" .. tostring(side)
        if bind == want then return true end
        if side == 4 and (bind == "Mouse:XButton1" or bind == "Mouse:MB4") then return true end
        if side == 5 and (bind == "Mouse:XButton2" or bind == "Mouse:MB5") then return true end
        return false
    end
    -- declenche un bouton lateral: rebind si capture en cours, sinon run du bind
    local function _onSide(side)
        if capturing then
            local b = capturing; capturing = nil
            b.key = "Mouse:MouseButton" .. tostring(side); saveKb()
            if b.refresh then b.refresh() end
            return
        end
        for _, b in ipairs(binds) do
            if _bindIsSide(b.key, side) then b.run(); return end
        end
    end

    UIS.InputBegan:Connect(function(input, gameProcessed)
        -- CAPTURE (rebind): clavier OU souris. MB1 exclu (sert a cliquer l UI),
        -- MB4/MB5 geres par le poll ci-dessous.
        if capturing then
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local b = capturing; capturing = nil
                local nm = input.KeyCode.Name
                if nm ~= "Escape" then b.key = "Key:" .. nm; saveKb() end
                if b.refresh then b.refresh() end
            elseif _isMouseBtn(input) and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                local b = capturing; capturing = nil
                b.key = "Mouse:" .. input.UserInputType.Name; saveKb()
                if b.refresh then b.refresh() end
            end
            return
        end
        -- TRIGGER: clavier + souris normale (MB4/MB5 via le poll)
        for _, b in ipairs(binds) do
            if not (_bindIsSide(b.key, 4) or _bindIsSide(b.key, 5)) and _inputMatches(input, b.key) then
                -- mynxx: le reset doit marcher MEME pendant un steal ou avec une UI
                -- de jeu ouverte -> seul lui (et le menu) ignore gameProcessed.
                if b.id ~= "reset" and b.id ~= "menu" and gameProcessed then return end
                b.run()
                return
            end
        end
    end)

    -- POLL des boutons lateraux (rising edge). Gate: cout ~0 tant qu aucun bind
    -- lateral n existe et qu on ne capture pas -> juste des compares de string.
    do
        local prev4, prev5 = false, false
        game:GetService("RunService").Heartbeat:Connect(function()
            local need = capturing ~= nil
            if not need then
                for _, b in ipairs(binds) do
                    if _bindIsSide(b.key, 4) or _bindIsSide(b.key, 5) then need = true; break end
                end
            end
            if not need then prev4, prev5 = false, false; return end
            local d4, d5 = _sideDown(4), _sideDown(5)
            if d4 and not prev4 then _onSide(4) end
            if d5 and not prev5 then _onSide(5) end
            prev4, prev5 = d4, d5
        end)
    end

    -- menu
    pcall(function()
        local old = guiParent:FindFirstChild("CarpetCloneUI")
        if old then old:Destroy() end
    end)
    local sg = Instance.new("ScreenGui")
    sg.Name = "CarpetCloneUI"; sg.ResetOnSpawn = false; sg.DisplayOrder = 129
    pcall(function() sg.Parent = guiParent end)
    if not sg.Parent then sg.Parent = PG end

    local f = Instance.new("Frame", sg)
    f.Size = UDim2.fromOffset(214, 26 + #binds * 26 + 118)   -- + FOV + Buy Range + X-Ray
    f.Position = UDim2.fromOffset(panelX, panelY)
    panelFrame = f   -- pour le keybind "Main Menu" (show/hide)
    f.Visible = false   -- FERME par defaut, s ouvre avec la touche Main Menu (LeftControl)

    -- ICONE ENGRENAGE (haut-droite de l ecran): ouvre/ferme le menu Keybind & Actions
    do
        local gearGui = Instance.new("ScreenGui")
        gearGui.Name = "MynxxGearIcon"; gearGui.ResetOnSpawn = false
        gearGui.IgnoreGuiInset = true; gearGui.DisplayOrder = 130
        pcall(function() gearGui.Parent = guiParent end)
        if not gearGui.Parent then gearGui.Parent = PG end
        local gear = Instance.new("TextButton", gearGui)
        gear.Size = UDim2.fromOffset(34, 34)
        gear.Position = UDim2.new(1, -44, 0, 10)   -- coin haut-droite
        gear.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
        gear.BackgroundTransparency = 0.1
        gear.Text = "\u{2699}"   -- engrenage
        gear.TextColor3 = Color3.fromRGB(235, 235, 240)
        gear.Font = Enum.Font.GothamBold; gear.TextSize = 20
        gear.AutoButtonColor = true; gear.BorderSizePixel = 0
        Instance.new("UICorner", gear).CornerRadius = UDim.new(0, 8)
        local st = Instance.new("UIStroke", gear)
        st.Color = Color3.fromRGB(95, 95, 110); st.Transparency = 0.4; st.Thickness = 1
        gear.MouseButton1Click:Connect(function()
            if panelFrame then panelFrame.Visible = not panelFrame.Visible end
        end)
    end
    f.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
    f.BorderSizePixel = 0; f.Active = true; f.Draggable = true
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
    do
        local pending = false
        f:GetPropertyChangedSignal("Position"):Connect(function()
            if pending then return end
            pending = true
            task.delay(0.5, function()
                pending = false
                panelX, panelY = f.AbsolutePosition.X, f.AbsolutePosition.Y
                saveKb()
            end)
        end)
    end

    local ttl = Instance.new("TextLabel", f)
    ttl.Size = UDim2.new(1, 0, 0, 22); ttl.BackgroundTransparency = 1
    ttl.Text = "Keybind & Actions"; ttl.Font = Enum.Font.GothamBlack
    ttl.TextSize = 11; ttl.TextColor3 = Color3.new(1, 1, 1)

    for i, b in ipairs(binds) do
        local y = 26 + (i - 1) * 26
        local l = Instance.new("TextLabel", f)
        l.BackgroundTransparency = 1; l.Position = UDim2.fromOffset(10, y)
        l.Size = UDim2.fromOffset(118, 20)
        l.Font = Enum.Font.Gotham; l.TextSize = 11
        l.TextColor3 = Color3.fromRGB(210, 210, 210)
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Text = b.label

        local kb = Instance.new("TextButton", f)
        kb.Size = UDim2.fromOffset(72, 20); kb.Position = UDim2.fromOffset(132, y)
        kb.TextColor3 = Color3.new(1, 1, 1)
        kb.Font = Enum.Font.GothamBold; kb.TextSize = 11
        kb.BorderSizePixel = 0
        Instance.new("UICorner", kb).CornerRadius = UDim.new(0, 4)

        b.refresh = function()
            kb.Text = _bindPretty(b.key)
            -- vert quand le mode est actif, pour le voir d un coup d oeil
            local on = (b.id == "carpet" and carpetOn) or (b.id == "float" and floatOn)
                or (b.id == "faceaway" and _G.MynxxFaceAwayOn == true)
            kb.BackgroundColor3 = on and Color3.fromRGB(200, 60, 130)
                                     or Color3.fromRGB(45, 45, 45)
        end
        b.refresh()

        kb.MouseButton1Click:Connect(function()
            if capturing and capturing.refresh then capturing.refresh() end
            capturing = b
            kb.Text = "..."
            kb.BackgroundColor3 = Color3.fromRGB(120, 90, 30)
        end)
    end

    ------------------------------------------------------------------
    -- ACTIONS: FOV + Buy Range + X-Ray  (FPS Boost retire)
    ------------------------------------------------------------------
    local ay = 26 + #binds * 26 + 6

    -- FOV: label + [-] [+] (pilote _G.setFOV / _G.MynxxFOV, defini par le bloc FOV)
    do
        local fy = ay
        local l = Instance.new("TextLabel", f)
        l.BackgroundTransparency = 1; l.Position = UDim2.fromOffset(10, fy)
        l.Size = UDim2.fromOffset(118, 20)
        l.Font = Enum.Font.Gotham; l.TextSize = 11
        l.TextColor3 = Color3.fromRGB(210, 210, 210)
        l.TextXAlignment = Enum.TextXAlignment.Left
        local function txt() l.Text = "FOV: " .. tostring(math.floor((tonumber(_G.MynxxFOV) or 70) + 0.5)) end
        local function mk(px, d, sym)
            local b = Instance.new("TextButton", f)
            b.Size = UDim2.fromOffset(24, 20); b.Position = UDim2.fromOffset(px, fy)
            b.BackgroundColor3 = Color3.fromRGB(50, 50, 50); b.TextColor3 = Color3.new(1, 1, 1)
            b.Font = Enum.Font.GothamBold; b.TextSize = 14; b.Text = sym; b.BorderSizePixel = 0
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
            b.MouseButton1Click:Connect(function()
                if _G.setFOV then _G.setFOV((tonumber(_G.MynxxFOV) or 70) + d * 5) end
                txt(); saveKb()
            end)
        end
        mk(132, -1, "-"); mk(180, 1, "+"); txt()
    end

    -- BUY RANGE: slider facon david -> un seul rayon "propre" pour l Auto Buy.
    -- Pilote _G.MynxxAutoBuyFireRange (rayon d ACHAT: ce qui achetait TOUT le cercle)
    -- ET _G.MynxxAutoBuyRange (rayon de LOCK/vol) avec la MEME valeur, donc: on vole
    -- vers le brainrot le plus proche DANS ce rayon et on n achete QUE ce qui est
    -- dedans. Baisse le slider = ca arrete d acheter tout autour. Persiste dans le
    -- meme fichier de config (kbCfg.buyRange).
    do
        local AB_MIN, AB_MAX = 5, 150
        local R0 = tonumber(kbCfg.buyRange)
        if not R0 then R0 = 60 end
        R0 = math.clamp(math.floor(R0), AB_MIN, AB_MAX)

        local ry = ay + 28
        local lbl = Instance.new("TextLabel", f)
        lbl.BackgroundTransparency = 1; lbl.Position = UDim2.fromOffset(10, ry)
        lbl.Size = UDim2.fromOffset(194, 16)
        lbl.Font = Enum.Font.Gotham; lbl.TextSize = 11
        lbl.TextColor3 = Color3.fromRGB(210, 210, 210)
        lbl.TextXAlignment = Enum.TextXAlignment.Left

        -- zone de clic transparente (haute) au-dessus d une barre fine, sinon la barre
        -- de 6px est injouable et le Frame.Draggable du panneau volerait le clic.
        local hit = Instance.new("TextButton", f)
        hit.Text = ""; hit.AutoButtonColor = false; hit.BackgroundTransparency = 1
        hit.Position = UDim2.fromOffset(10, ry + 16); hit.Size = UDim2.fromOffset(194, 20)
        hit.BorderSizePixel = 0

        local bar = Instance.new("Frame", hit)
        bar.AnchorPoint = Vector2.new(0, 0.5)
        bar.Position = UDim2.new(0, 0, 0.5, 0); bar.Size = UDim2.fromOffset(194, 6)
        bar.BackgroundColor3 = Color3.fromRGB(45, 45, 45); bar.BorderSizePixel = 0
        Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

        local fill = Instance.new("Frame", bar)
        fill.BackgroundColor3 = Color3.fromRGB(200, 60, 130); fill.BorderSizePixel = 0
        Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

        local knob = Instance.new("Frame", bar)
        knob.Size = UDim2.fromOffset(12, 12); knob.AnchorPoint = Vector2.new(0.5, 0.5)
        knob.BackgroundColor3 = Color3.fromRGB(235, 235, 240); knob.BorderSizePixel = 0
        knob.ZIndex = 2
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

        local function paint(v)
            local pct = (v - AB_MIN) / (AB_MAX - AB_MIN)
            fill.Size = UDim2.new(pct, 0, 1, 0)
            knob.Position = UDim2.new(pct, 0, 0.5, 0)
            lbl.Text = "Buy Range: " .. v .. " studs"
        end
        local function apply(v, persist)
            v = math.clamp(math.floor(v + 0.5), AB_MIN, AB_MAX)
            _G.MynxxAutoBuyFireRange = v
            _G.MynxxAutoBuyRange     = v
            paint(v)
            if persist then kbCfg.buyRange = v; pcall(_G.HubCfg.save) end
        end
        apply(R0, false)

        local dragging = false
        local function fromX(px)
            local rel = (px - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1)
            apply(AB_MIN + math.clamp(rel, 0, 1) * (AB_MAX - AB_MIN), true)
        end
        hit.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true; fromX(input.Position.X)
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
                fromX(input.Position.X)
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    -- X-RAY INTENSITE: slider (0-100%) qui pilote _G.XRayAlpha puis reapplique
    -- via _G.setXRay(true). 0% = murs opaques, 100% = totalement transparents.
    -- Valeur persistee dans le meme fichier de config (kbCfg.xrayAlpha).
    do
        local XR_MIN, XR_MAX = 0, 100   -- pourcentage
        -- valeur de depart: config si presente, sinon _G.XRayAlpha (defaut 0.60)
        local a0 = tonumber(kbCfg.xrayAlpha)
        if not a0 then a0 = tonumber(_G.XRayAlpha) or 0.60 end
        local P0 = math.clamp(math.floor(a0 * 100 + 0.5), XR_MIN, XR_MAX)

        local ry = ay + 68
        local lbl = Instance.new("TextLabel", f)
        lbl.BackgroundTransparency = 1; lbl.Position = UDim2.fromOffset(10, ry)
        lbl.Size = UDim2.fromOffset(194, 16)
        lbl.Font = Enum.Font.Gotham; lbl.TextSize = 11
        lbl.TextColor3 = Color3.fromRGB(210, 210, 210)
        lbl.TextXAlignment = Enum.TextXAlignment.Left

        local hit = Instance.new("TextButton", f)
        hit.Text = ""; hit.AutoButtonColor = false; hit.BackgroundTransparency = 1
        hit.Position = UDim2.fromOffset(10, ry + 16); hit.Size = UDim2.fromOffset(194, 20)
        hit.BorderSizePixel = 0

        local bar = Instance.new("Frame", hit)
        bar.AnchorPoint = Vector2.new(0, 0.5)
        bar.Position = UDim2.new(0, 0, 0.5, 0); bar.Size = UDim2.fromOffset(194, 6)
        bar.BackgroundColor3 = Color3.fromRGB(45, 45, 45); bar.BorderSizePixel = 0
        Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

        local fill = Instance.new("Frame", bar)
        fill.BackgroundColor3 = Color3.fromRGB(200, 60, 130); fill.BorderSizePixel = 0
        Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

        local knob = Instance.new("Frame", bar)
        knob.Size = UDim2.fromOffset(12, 12); knob.AnchorPoint = Vector2.new(0.5, 0.5)
        knob.BackgroundColor3 = Color3.fromRGB(235, 235, 240); knob.BorderSizePixel = 0
        knob.ZIndex = 2
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

        local function paint(p)
            local pct = (p - XR_MIN) / (XR_MAX - XR_MIN)
            fill.Size = UDim2.new(pct, 0, 1, 0)
            knob.Position = UDim2.new(pct, 0, 0.5, 0)
            lbl.Text = "X-Ray: " .. p .. "%"
        end

        -- reapplique le X-Ray sans spammer setXRay a chaque pixel (debounce)
        local reapplyPending = false
        local function scheduleReapply()
            if reapplyPending then return end
            reapplyPending = true
            task.delay(0.12, function()
                reapplyPending = false
                if type(_G.setXRay) == "function" and _G.XRayEnabled then
                    pcall(_G.setXRay, true)
                end
            end)
        end

        local function apply(p, persist)
            p = math.clamp(math.floor(p + 0.5), XR_MIN, XR_MAX)
            _G.XRayAlpha = p / 100
            paint(p)
            scheduleReapply()
            if persist then kbCfg.xrayAlpha = _G.XRayAlpha; pcall(_G.HubCfg.save) end
        end
        -- init: peint sans reapply immediat (le bloc X-Ray s applique deja tout seul),
        -- mais pousse la valeur config dans _G.XRayAlpha
        _G.XRayAlpha = P0 / 100
        paint(P0)
        scheduleReapply()

        local dragging = false
        local function fromX(px)
            local rel = (px - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1)
            apply(XR_MIN + math.clamp(rel, 0, 1) * (XR_MAX - XR_MIN), true)
        end
        hit.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true; fromX(input.Position.X)
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
                fromX(input.Position.X)
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    refreshUI = function()
        for _, b in ipairs(binds) do if b.refresh then pcall(b.refresh) end end
    end

end)

if not okCC then warn("[CARPET/CLONE] BLOC EN ERREUR: " .. tostring(errCC)) end
end)

-- ============================================================
-- SCROLL OUT DANS UNE BASE (portage de mynxx)
-- Le jeu bride le zoom des qu on entre dans une base: il rabaisse
-- CameraMaxZoomDistance, et le toit "pousse" la camera vers toi via
-- l occlusion PopperCam. On corrige les trois causes a chaque frame:
--   1. CameraMaxZoomDistance remis a 128 -- la valeur PAR DEFAUT de Roblox,
--      pas plus: une valeur exotique se verrait tout de suite.
--   2. CameraMinZoomDistance a 0.5 pour garder la vue premiere personne.
--   3. Occlusion en Invisicam au lieu de Zoom(PopperCam): Invisicam conserve
--      la distance de zoom et se contente de rendre les obstacles
--      transparents, alors que PopperCam rapproche la camera de force.
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okZ, errZ = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local LP         = Players.LocalPlayer

    _G.UnlockZoom = true

    local _zoomLast = 0
    RunService.RenderStepped:Connect(function()
        if not _G.UnlockZoom then return end
        -- PERF: reasserter le zoom toutes les ~0.4s suffit (les reglages ne changent
        -- pas chaque frame). Avant: pcall + 3 lectures de proprietes CHAQUE frame.
        local now = os.clock()
        if now - _zoomLast < 0.4 then return end
        _zoomLast = now
        pcall(function()
            if LP.CameraMaxZoomDistance ~= 128 then
                LP.CameraMaxZoomDistance = 128
            end
            if LP.CameraMinZoomDistance > 0.5 then
                LP.CameraMinZoomDistance = 0.5
            end
            if LP.DevCameraOcclusionMode ~= Enum.DevCameraOcclusionMode.Invisicam then
                LP.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam
            end
        end)
    end)
end)

if not okZ then warn("[ZOOM] BLOC EN ERREUR: " .. tostring(errZ)) end
end)


-- ============================================================
-- AUTO KICK + REJOIN (portage de mynxx) + petit GUI
--
-- Auto Kick: des qu un texte de l interface contient "you stole", on quitte
-- le serveur immediatement -> le loot est securise.
-- On surveille TOUS les TextLabel / TextButton / TextBox du PlayerGui, y
-- compris ceux crees plus tard (DescendantAdded) et les ScreenGui ajoutes
-- apres coup (ChildAdded), car la notification de steal est instanciee a la
-- volee. Chaque objet est aussi suivi sur son changement de .Text: le jeu
-- reutilise souvent le meme label au lieu d en creer un nouveau.
--
-- Rejoin: retour sur LE MEME serveur via TeleportToPlaceInstance(JobId).
-- Uniquement des retries, aucun repli public -> on ne peut jamais atterrir
-- sur un autre serveur.
--
-- NON repris de mynxx (demande): grief detector, webhook (__MynxxStealEmit),
-- retour en serveur prive (KickToPrivateServer), et le delai de 0.2s qui
-- n existait que pour laisser le webhook partir -> ici le kick est instantane.
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okAK, errAK = pcall(function()
    local Players         = game:GetService("Players")
    local TeleportService = game:GetService("TeleportService")
    local HS              = game:GetService("HttpService")
    local LP              = Players.LocalPlayer
    local PG              = LP:WaitForChild("PlayerGui")
    local guiParent       = (gethui and gethui()) or game:GetService("CoreGui") or PG

    local cfg = _G.HubCfg.get("autokick")   -- section du fichier partage
    if _G.AutoKickOnSteal == nil then _G.AutoKickOnSteal = true end
    if _G.AutoKickKeyword == nil then _G.AutoKickKeyword = "you stole" end
    if _G.MynxxPrivateCode == nil then _G.MynxxPrivateCode = "" end
    -- Kick apres achat Auto Buy: TOUJOURS actif (pas de bouton), reutilise CE meme
    -- auto kick -> serveur prive si un code est renseigne.
    _G.MynxxKickAfterBuy = true
    local panelX, panelY = 240, 300
    do
        if type(cfg.on) == "boolean" then _G.AutoKickOnSteal = cfg.on end
        if tonumber(cfg.x) then panelX = tonumber(cfg.x) end
        if tonumber(cfg.y) then panelY = tonumber(cfg.y) end
        if type(cfg.psCode) == "string" then _G.MynxxPrivateCode = cfg.psCode end
    end
    local function saveCfg()
        cfg.on = _G.AutoKickOnSteal; cfg.x = panelX; cfg.y = panelY
        cfg.psCode = _G.MynxxPrivateCode
        _G.HubCfg.save()
    end

    ------------------------------------------------------------------
    -- AUTO KICK
    ------------------------------------------------------------------
    local fired = false
    local function doKick()
        if fired then return end
        fired = true
        -- si un code de serveur prive est renseigne -> on rejoint CE serveur
        -- prive au lieu de couper. Sinon (champ vide) -> kick normal (shutdown).
        local code = _G.MynxxPrivateCode
        if type(code) == "string" and code ~= "" then
            task.delay(0.2, function()
                pcall(function()
                    game:GetService("ExperienceService"):LaunchExperience({
                        placeId = game.PlaceId,
                        linkCode = code,
                    })
                end)
            end)
            return
        end
        pcall(function() game:Shutdown() end)
        pcall(function() LP:Kick("\nAuto Kick") end)
    end
    -- Expose pour l Auto Buy: meme kick (serveur prive si code renseigne).
    _G.MynxxDoAutoKick = doKick

    local function check(txt)
        if not _G.AutoKickOnSteal then return end
        if type(txt) ~= "string" or txt == "" then return end
        local kw = tostring(_G.AutoKickKeyword or "you stole")
        if string.find(string.lower(txt), kw, 1, true) then doKick() end
    end

    local hooked = setmetatable({}, { __mode = "k" })
    local function hookObj(obj)
        if hooked[obj] then return end
        hooked[obj] = true
        check(obj.Text)
        obj:GetPropertyChangedSignal("Text"):Connect(function() check(obj.Text) end)
    end

    local function isText(o)
        return o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")
    end

    local function watchRoot(root)
        for _, obj in ipairs(root:GetDescendants()) do
            if isText(obj) then hookObj(obj) end
        end
        root.DescendantAdded:Connect(function(desc)
            if isText(desc) then hookObj(desc) end
        end)
    end

    for _, g in ipairs(PG:GetChildren()) do pcall(watchRoot, g) end
    PG.ChildAdded:Connect(function(g) pcall(watchRoot, g) end)

    ------------------------------------------------------------------
    -- REJOIN (meme serveur)
    ------------------------------------------------------------------
    local function rejoin()
        local jobId = game.JobId
        task.spawn(function()
            if not jobId or jobId == "" then return end
            for _ = 1, 4 do
                local ok = pcall(function()
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LP)
                end)
                if ok then break end
                task.wait(1.5)
            end
        end)
    end
    _G.Rejoin = rejoin

    ------------------------------------------------------------------
    -- GUI
    ------------------------------------------------------------------
    pcall(function()
        local old = guiParent:FindFirstChild("AutoKickUI")
        if old then old:Destroy() end
    end)
    local sg = Instance.new("ScreenGui")
    sg.Name = "AutoKickUI"; sg.ResetOnSpawn = false; sg.DisplayOrder = 131
    pcall(function() sg.Parent = guiParent end)
    if not sg.Parent then sg.Parent = PG end

    local f = Instance.new("Frame", sg)
    f.Size = UDim2.fromOffset(180, 148)
    f.Position = UDim2.fromOffset(panelX, panelY)
    f.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
    f.BorderSizePixel = 0; f.Active = true; f.Draggable = true
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
    do
        local pending = false
        f:GetPropertyChangedSignal("Position"):Connect(function()
            if pending then return end
            pending = true
            task.delay(0.5, function()
                pending = false
                panelX, panelY = f.AbsolutePosition.X, f.AbsolutePosition.Y
                saveCfg()
            end)
        end)
    end

    local ttl = Instance.new("TextLabel", f)
    ttl.Size = UDim2.new(1, 0, 0, 22); ttl.BackgroundTransparency = 1
    ttl.Text = "Utility"; ttl.Font = Enum.Font.GothamBlack
    ttl.TextSize = 11; ttl.TextColor3 = Color3.new(1, 1, 1)

    local b = Instance.new("TextButton", f)
    b.Size = UDim2.new(1, -44, 0, 24); b.Position = UDim2.fromOffset(8, 26)
    b.Font = Enum.Font.GothamBold; b.TextSize = 11
    b.TextColor3 = Color3.new(1, 1, 1); b.BorderSizePixel = 0
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    local function refresh()
        b.Text = "AUTO KICK" .. (_G.AutoKickOnSteal and ": ON" or ": OFF")
        b.BackgroundColor3 = _G.AutoKickOnSteal and Color3.fromRGB(200, 60, 130)
                                                 or Color3.fromRGB(45, 45, 45)
    end
    b.MouseButton1Click:Connect(function()
        _G.AutoKickOnSteal = not _G.AutoKickOnSteal
        refresh(); saveCfg()
    end)
    refresh()

    local rb = Instance.new("TextButton", f)
    rb.Size = UDim2.new(1, -16, 0, 24); rb.Position = UDim2.fromOffset(8, 56)
    rb.Font = Enum.Font.GothamBold; rb.TextSize = 11
    rb.TextColor3 = Color3.new(1, 1, 1); rb.BorderSizePixel = 0
    rb.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    rb.Text = "REJOIN"
    Instance.new("UICorner", rb).CornerRadius = UDim.new(0, 5)
    rb.MouseButton1Click:Connect(function()
        rb.Text = "REJOIN..."
        rejoin()
    end)

    -- JOIN QUEUE (teleport hook de join.txt): bascule le hook de file d attente.
    -- OFF -> joins normaux (throttle anti-529). ON -> joins mis en file + retries.
    local jq = Instance.new("TextButton", f)
    jq.Size = UDim2.new(1, -16, 0, 24); jq.Position = UDim2.fromOffset(8, 86)
    jq.Font = Enum.Font.GothamBold; jq.TextSize = 11
    jq.TextColor3 = Color3.new(1, 1, 1); jq.BorderSizePixel = 0
    jq.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    jq.Text = "JOIN QUEUE: OFF"
    Instance.new("UICorner", jq).CornerRadius = UDim.new(0, 5)
    local function refreshJQ()
        local on = _G.MynxxJoinQueueEnabled == true
        jq.Text = "JOIN QUEUE" .. (on and ": ON" or ": OFF")
        jq.BackgroundColor3 = on and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45)
    end
    refreshJQ()
    jq.MouseButton1Click:Connect(function()
        if _G.MynxxToggleJoinQueue then pcall(_G.MynxxToggleJoinQueue) end
        refreshJQ()
    end)
    -- statut du hook -> texte du bouton, puis retour au libelle ON/OFF apres 2.5s
    local jqTok = 0
    _G.MynxxJoinQueueStatus = function(text, isError)
        jqTok = jqTok + 1
        local myTok = jqTok
        jq.Text = tostring(text)
        task.delay(2.5, function()
            if jqTok == myTok then refreshJQ() end
        end)
    end

    -- KICK MANUEL (visuel): affiche l ecran de kick Roblox avec le message
    -- PAS de game:Shutdown (ca c est l auto kick). Bouton dans CE panneau.
    local kb = Instance.new("TextButton", f)
    kb.Size = UDim2.new(1, -16, 0, 24); kb.Position = UDim2.fromOffset(8, 116)
    kb.Font = Enum.Font.GothamBold; kb.TextSize = 11
    kb.TextColor3 = Color3.fromRGB(220, 70, 70); kb.BorderSizePixel = 0
    kb.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    kb.Text = "KICK"
    Instance.new("UICorner", kb).CornerRadius = UDim.new(0, 5)
    kb.MouseButton1Click:Connect(function()
        pcall(function() LP:Kick("\nMynxx") end)
    end)

    ------------------------------------------------------------------
    -- CODE SERVEUR PRIVE: emoji a cote de AUTO KICK -> popup avec un champ.
    -- Champ REMPLI -> le kick rejoint ce serveur prive. Champ VIDE -> kick
    -- normal (shutdown). Sauve a la sortie du champ.
    ------------------------------------------------------------------
    local pop = Instance.new("Frame", f)
    pop.Size = UDim2.fromOffset(180, 58)
    pop.Position = UDim2.fromOffset(0, 152)   -- juste sous le panneau (agrandi pour KICK)
    pop.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
    pop.BorderSizePixel = 0; pop.Active = true; pop.Visible = false
    Instance.new("UICorner", pop).CornerRadius = UDim.new(0, 8)

    local pt = Instance.new("TextLabel", pop)
    pt.Size = UDim2.new(1, 0, 0, 20); pt.Position = UDim2.fromOffset(0, 4)
    pt.BackgroundTransparency = 1
    pt.Text = "PRIVATE SERVER CODE"; pt.Font = Enum.Font.GothamBold
    pt.TextSize = 11; pt.TextColor3 = Color3.new(1, 1, 1)

    local tb = Instance.new("TextBox", pop)
    tb.Size = UDim2.fromOffset(134, 24); tb.Position = UDim2.fromOffset(8, 26)
    tb.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    tb.TextColor3 = Color3.new(1, 1, 1); tb.BorderSizePixel = 0
    tb.Font = Enum.Font.Gotham; tb.TextSize = 11
    tb.ClearTextOnFocus = false
    tb.TextXAlignment = Enum.TextXAlignment.Left
    tb.PlaceholderText = "A219012DJF"
    tb.PlaceholderColor3 = Color3.fromRGB(120, 120, 120)
    tb.Text = _G.MynxxPrivateCode or ""
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 5)
    do
        local p = Instance.new("UIPadding", tb)
        p.PaddingLeft = UDim.new(0, 6); p.PaddingRight = UDim.new(0, 6)
    end

    -- MASQUE: le code tape est cache (texte de la box rendu invisible) et on
    -- dessine des puces par-dessus. L oeil a droite bascule l affichage clair.
    -- Champ VIDE -> pas de masque, on montre le placeholder (A219012DJF).
    -- Le vrai texte reste dans tb.Text (jamais modifie) -> edition + save OK.
    local reveal = false
    local dots = Instance.new("TextLabel", pop)
    dots.Size = tb.Size; dots.Position = tb.Position
    dots.BackgroundTransparency = 1
    dots.Font = tb.Font; dots.TextSize = tb.TextSize
    dots.TextColor3 = tb.TextColor3
    dots.TextXAlignment = Enum.TextXAlignment.Left
    dots.Text = ""
    do
        local p = Instance.new("UIPadding", dots)
        p.PaddingLeft = UDim.new(0, 6); p.PaddingRight = UDim.new(0, 6)
    end

    local function renderMask()
        local has = #tb.Text > 0
        if reveal or not has then
            tb.TextTransparency = 0
            dots.Visible = false
        else
            tb.TextTransparency = 1
            dots.Visible = true
            dots.Text = string.rep("\u{2022}", #tb.Text)
        end
    end
    tb:GetPropertyChangedSignal("Text"):Connect(renderMask)
    renderMask()

    local eye = Instance.new("TextButton", pop)
    eye.Size = UDim2.fromOffset(26, 24); eye.Position = UDim2.fromOffset(146, 26)
    eye.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    eye.TextColor3 = Color3.new(1, 1, 1); eye.BorderSizePixel = 0
    eye.Font = Enum.Font.GothamBold; eye.TextSize = 13
    eye.Text = "\u{1F441}"
    Instance.new("UICorner", eye).CornerRadius = UDim.new(0, 5)
    eye.MouseButton1Click:Connect(function()
        reveal = not reveal
        eye.BackgroundColor3 = reveal and Color3.fromRGB(200, 60, 130) or Color3.fromRGB(45, 45, 45)
        renderMask()
    end)

    tb.FocusLost:Connect(function()
        _G.MynxxPrivateCode = tb.Text
        saveCfg()
    end)

    -- emoji a cote de AUTO KICK (le bouton a ete retreci pour laisser la place)
    local gear = Instance.new("TextButton", f)
    gear.Size = UDim2.fromOffset(24, 24); gear.Position = UDim2.fromOffset(148, 26)
    gear.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    gear.TextColor3 = Color3.new(1, 1, 1); gear.BorderSizePixel = 0
    gear.Font = Enum.Font.GothamBold; gear.TextSize = 14
    gear.Text = "⚙️"
    Instance.new("UICorner", gear).CornerRadius = UDim.new(0, 5)
    gear.MouseButton1Click:Connect(function()
        pop.Visible = not pop.Visible
    end)
end)

if not okAK then warn("[AUTOKICK] BLOC EN ERREUR: " .. tostring(errAK)) end
end)

-- ============================================================
-- JOIN QUEUE (teleport hook) - portage de join.txt
-- Intercepte TeleportToPlaceInstance / TeleportAsync.
--   * OFF : laisse passer les joins mais les throttle (anti-kick 529).
--   * ON  : met le join en file d attente avec retries + cooldown global.
-- Le bouton "Join Queue" du panneau Utility bascule l etat via
-- _G.MynxxToggleJoinQueue. Le hook est installe des le lancement (desactive)
-- pour prendre effet des le prochain id des qu on passe ON.
-- ============================================================
nowSpawn(function()
local okJQ, errJQ = pcall(function()
    local TeleportService = game:GetService("TeleportService")
    local Players         = game:GetService("Players")
    local hasES, ExperienceService = pcall(function() return game:GetService("ExperienceService") end)
    if not hasES then ExperienceService = nil end

    local MAX_ATTEMPTS = 5
    local RETRY_DELAY  = 3
    local MIN_INTERVAL = 3
    local RAW_INTERVAL = 2

    local enabled = false
    local hooked  = false
    local bypass  = false
    local launchGen = 0
    local activeJobId = nil
    local lastAttemptAt = 0
    local lastRawAt = 0
    local oldNamecall
    local oldTeleportToPlaceInstance

    local function setStatus(text, isError)
        if type(_G.MynxxJoinQueueStatus) == "function" then
            pcall(_G.MynxxJoinQueueStatus, tostring(text), isError and true or false)
        end
    end

    local function cleanJobId(jobId)
        jobId = tostring(jobId or "")
        return (jobId:gsub("[%s\"'{}%[%]]", ""))
    end

    local function shouldDropRaw()
        if os.clock() - lastRawAt < RAW_INTERVAL then return true end
        lastRawAt = os.clock()
        return false
    end

    local function rawTeleport(placeId, jobId)
        bypass = true
        local ok, err = pcall(function()
            if oldTeleportToPlaceInstance then
                oldTeleportToPlaceInstance(TeleportService, placeId, jobId, Players.LocalPlayer)
            else
                TeleportService:TeleportToPlaceInstance(placeId, jobId, Players.LocalPlayer)
            end
        end)
        bypass = false
        return ok, err
    end

    local function attemptOnce(placeId, jobId)
        if ExperienceService then
            return pcall(function()
                return ExperienceService:LaunchExperience({ placeId = placeId, gameInstanceId = jobId })
            end)
        end
        return rawTeleport(placeId, jobId)
    end

    local function launch(placeId, jobId)
        placeId = tonumber(placeId)
        jobId = cleanJobId(jobId)
        if not placeId or placeId == 0 then placeId = game.PlaceId end
        if jobId == "" then setStatus("No JobId given", true); return false end
        -- meme id spamme: seul le PREMIER fire lance, les repeats sont ignores
        if jobId == activeJobId then return true end
        activeJobId = jobId
        launchGen = launchGen + 1
        local myGen = launchGen
        task.spawn(function()
            for attempt = 1, MAX_ATTEMPTS do
                if launchGen ~= myGen then return end
                local cool = MIN_INTERVAL - (os.clock() - lastAttemptAt)
                if cool > 0 then task.wait(cool) end
                if launchGen ~= myGen then return end
                lastAttemptAt = os.clock()
                setStatus(("Launching... (%d/%d)"):format(attempt, MAX_ATTEMPTS), false)
                local ok, err = attemptOnce(placeId, jobId)
                if ok then setStatus("Queued / launching", false); return end
                warn("[JoinQueue] attempt " .. attempt .. " failed: " .. tostring(err))
                setStatus(tostring(err), true)
                task.wait(RETRY_DELAY)
            end
            if launchGen ~= myGen then return end
            setStatus("Gave up, waiting next id", true)
            activeJobId = nil
        end)
        return true
    end

    -- vraie raison de l echec au lieu du popup HTTP generique
    TeleportService.TeleportInitFailed:Connect(function(_, result, message)
        warn("[JoinQueue] teleport failed: " .. tostring(result) .. " - " .. tostring(message))
        setStatus(tostring(result) .. ": " .. tostring(message), true)
    end)

    -- (Le "kill" des popups ErrorPrompt de join.txt a ete RETIRE: il detruisait
    --  les Frame "ErrorPrompt" de CoreGui pendant que Roblox les redimensionnait
    --  encore -> spam "MessageArea is not a valid member of ErrorPrompt". La
    --  reference n avait pas ce killer. Idem pour GuiService:ClearError global.)

    local function installHook()
        if hooked then return end
        hooked = true
        if hookfunction then
            oldTeleportToPlaceInstance = hookfunction(
                TeleportService.TeleportToPlaceInstance,
                newcclosure(function(self, placeId, jobId, ...)
                    -- OFF = passthrough propre (pas de throttle): le hook n existe
                    -- de toute facon QUE si tu as active Join Queue au moins une fois.
                    if enabled and not bypass then launch(placeId, jobId); return end
                    return oldTeleportToPlaceInstance(self, placeId, jobId, ...)
                end)
            )
        end
        if hookmetamethod and getnamecallmethod then
            oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                local method = getnamecallmethod()
                if enabled and not bypass and self == TeleportService
                    and (method == "TeleportToPlaceInstance" or method == "TeleportAsync") then
                    local args = { ... }
                    if method == "TeleportToPlaceInstance" then
                        launch(args[1], args[2]); return
                    end
                    local options = args[3]
                    local jobId = options and options.ServerInstanceId
                    if jobId and jobId ~= "" then launch(args[1], jobId); return end
                end
                return oldNamecall(self, ...)
            end))
        end
    end

    _G.MynxxJoinQueueEnabled = false
    local function setEnabled(state)
        enabled = state and true or false
        _G.MynxxJoinQueueEnabled = enabled
        if enabled then
            -- HOOK INSTALLE ICI SEULEMENT (au 1er ON). Tant que Join Queue reste
            -- OFF, on ne hook NI TeleportToPlaceInstance NI __namecall -> le jeu
            -- ne voit aucun hook -> pas de detection / pas de kick au lancement.
            installHook()
        else
            launchGen = launchGen + 1; activeJobId = nil
        end
    end
    _G.MynxxSetJoinQueue = setEnabled
    _G.MynxxToggleJoinQueue = function() setEnabled(not enabled); return enabled end

    -- PAS de installHook() au lancement (c est ce qui te faisait kick): rien n est
    -- hooke tant que tu n as pas active Join Queue. Le hook n arrive qu au 1er ON.
end)
if not okJQ then warn("[JOINQUEUE] BLOC EN ERREUR: " .. tostring(errJQ)) end
end)

-- ============================================================
-- AUTO UNLOCK ON STEAL  (portage de message.txt / MYNXX)
--
-- Des que tu commences un steal (attribut "Stealing" -> true), on declenche le
-- ProximityPrompt du "Unlock" de l etage ou tu te trouves, sur le plot le plus
-- proche (< 40 studs) -> la porte de la base s ouvre toute seule pendant le vol.
-- Etage 1 si Y < 12, sinon etage 2 (comme message.txt).
-- Pas d UI: ON par defaut. _G.AutoUnlockOnSteal = false pour couper.
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okUL, errUL = pcall(function()
    local Players = game:GetService("Players")
    local LP      = Players.LocalPlayer

    if _G.AutoUnlockOnSteal == nil then _G.AutoUnlockOnSteal = true end

    local function getUnlockHRP()
        local c = LP.Character
        if not c then return end
        return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("UpperTorso")
    end

    -- ouvre le "Unlock" d indice `number` (trie par hauteur = etage) du plot le
    -- plus proche, en tirant tous ses ProximityPrompt
    local function smartInteract(number)
        local hrp = getUnlockHRP()
        if not hrp then return end
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return end
        local closestPlot, minDistance = nil, 40
        for _, plot in pairs(plots:GetChildren()) do
            local ok, plotPos = pcall(function()
                if plot:IsA("Model") then
                    return plot.PrimaryPart and plot.PrimaryPart.Position or plot:GetPivot().Position
                else
                    return plot.Position
                end
            end)
            if ok and plotPos then
                local dist = (hrp.Position - plotPos).Magnitude
                if dist < minDistance then
                    closestPlot = plot; minDistance = dist
                end
            end
        end
        if closestPlot and closestPlot:FindFirstChild("Unlock") then
            local items = {}
            for _, item in pairs(closestPlot.Unlock:GetChildren()) do
                local pos = item:IsA("Model") and item:GetPivot().Position or item.Position
                table.insert(items, { Obj = item, Y = pos.Y })
            end
            table.sort(items, function(a, b) return a.Y < b.Y end)
            if items[number] then
                for _, pr in pairs(items[number].Obj:GetDescendants()) do
                    if pr:IsA("ProximityPrompt") then
                        pcall(function() fireproximityprompt(pr) end)
                    end
                end
            end
        end
    end

    local function getCurrentUnlockFloor()
        local hrp = getUnlockHRP()
        if not hrp then return 1 end
        return (hrp.Position.Y < 12) and 1 or 2
    end

    LP:GetAttributeChangedSignal("Stealing"):Connect(function()
        if not _G.AutoUnlockOnSteal then return end
        if LP:GetAttribute("Stealing") ~= true then return end
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local floor = getCurrentUnlockFloor()
        task.spawn(function()
            task.wait(0.1)
            pcall(smartInteract, floor)
        end)
    end)
end)

if not okUL then warn("[AUTOUNLOCK] BLOC EN ERREUR: " .. tostring(errUL)) end
end)

-- ============================================================
-- TIMER ESP + SUBSPACE MINE ESP (portage de mynxx)
-- Actifs par defaut, rafraichis toutes les 0.5s.
--
-- Timer ESP: le jeu affiche deja un timer par etage sous forme de
-- BillboardGui contenant un "RemainingTime". On le recopie dans notre
-- propre billboard AlwaysOnTop (donc visible a travers les murs), et
-- UNIQUEMENT pour le premier etage: on garde les timers dont la hauteur
-- est a moins de 4 studs du plus bas de la base, les autres sont retires.
--
-- Subspace Mine ESP: encadre les SubspaceTripmine du dossier ToolsAdds et
-- affiche le proprietaire (extrait du nom de la part).
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okESP, errESP = pcall(function()

    ------------------------------------------------------------------
    -- SUBSPACE MINE ESP
    ------------------------------------------------------------------
    if _G.SubspaceMineESP == nil then _G.SubspaceMineESP = true end
    local mineData = {}

    local function refreshMineESP()
        local tools = workspace:FindFirstChild("ToolsAdds")
        if not tools then return end
        local current = {}
        for _, obj in ipairs(tools:GetChildren()) do
            if obj:IsA("BasePart") and obj.Name:match("SubspaceTripmine") then
                current[obj] = true
                if not mineData[obj] then
                    local owner = obj.Name:match("SubspaceTripmine(.+)") or "Unknown"
                    local sel = Instance.new("SelectionBox", obj)
                    sel.Color3 = Color3.fromRGB(167, 142, 255)
                    sel.LineThickness = 0.05
                    local bb = Instance.new("BillboardGui", obj)
                    bb.Size = UDim2.new(0, 250, 0, 50)
                    bb.StudsOffset = Vector3.new(0, 2.5, 0)
                    bb.AlwaysOnTop = false
                    local lbl = Instance.new("TextLabel", bb)
                    lbl.Size = UDim2.new(1, 0, 1, 0)
                    lbl.BackgroundTransparency = 1
                    lbl.Text = owner .. "'s Subspace Mine"
                    lbl.TextColor3 = Color3.fromRGB(167, 142, 255)
                    lbl.TextStrokeTransparency = 0
                    lbl.Font = Enum.Font.GothamBold
                    lbl.TextSize = 16
                    mineData[obj] = { sel = sel, bb = bb }
                end
            end
        end
        -- mine disparue -> on nettoie
        for obj, d in pairs(mineData) do
            if not current[obj] or not obj.Parent then
                pcall(function() d.sel:Destroy() end)
                pcall(function() d.bb:Destroy() end)
                mineData[obj] = nil
            end
        end
    end

    local function clearMineESP()
        for obj, d in pairs(mineData) do
            pcall(function() d.sel:Destroy() end)
            pcall(function() d.bb:Destroy() end)
            mineData[obj] = nil
        end
    end

    ------------------------------------------------------------------
    -- TIMER ESP
    ------------------------------------------------------------------
    if _G.TimerESP == nil then _G.TimerESP = true end
    local TIMER_COLOR = Color3.fromRGB(255, 215, 0)   -- jaune

    local function clearTimerESP()
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return end
        for _, plot in ipairs(plots:GetChildren()) do
            for _, desc in ipairs(plot:GetDescendants()) do
                if desc.Name == "TimerESP" and desc:IsA("BillboardGui") then
                    pcall(function() desc:Destroy() end)
                end
            end
        end
    end
    _G.clearTimerESP = clearTimerESP

    local function refreshTimerESP()
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return end
        for _, plot in ipairs(plots:GetChildren()) do
            -- le jeu pose un timer par etage: on releve tous ceux de ce plot
            -- puis on ne garde que les plus bas (= 1er etage)
            local found, minY = {}, math.huge
            for _, g in ipairs(plot:GetDescendants()) do
                if g:IsA("BillboardGui") and g:FindFirstChild("RemainingTime") then
                    local base = g.Adornee or g.Parent
                    if base and base:IsA("BasePart") then
                        found[#found + 1] = { g = g, base = base, y = base.Position.Y }
                        if base.Position.Y < minY then minY = base.Position.Y end
                    end
                end
            end
            for _, item in ipairs(found) do
                local base, g = item.base, item.g
                local existing = base:FindFirstChild("TimerESP")
                if item.y <= minY + 4 then          -- 1er etage uniquement
                    local rt = g:FindFirstChild("RemainingTime")
                    if rt then
                        if not existing then
                            local bb = Instance.new("BillboardGui")
                            bb.Name = "TimerESP"
                            bb.Adornee = base
                            bb.Size = UDim2.new(0, 98, 0, 26)
                            bb.AlwaysOnTop = true      -- visible a travers les murs
                            bb.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
                            local lbl = Instance.new("TextLabel", bb)
                            lbl.Size = UDim2.new(1, 0, 1, 0)
                            lbl.BackgroundTransparency = 1
                            lbl.Text = rt.Text
                            lbl.Font = Enum.Font.GothamBold
                            lbl.TextSize = 15
                            -- jaune + contour noir OPAQUE: en blanc avec un
                            -- contour a 35% le texte se melangeait au decor
                            -- et ressortait gris
                            lbl.TextColor3 = TIMER_COLOR
                            lbl.TextStrokeTransparency = 0
                            lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
                            bb.Parent = base
                        else
                            local l = existing:FindFirstChildOfClass("TextLabel")
                            if l then
                                l.Text = rt.Text
                                -- on reapplique la couleur: les billboards
                                -- crees avant ce changement resteraient blancs
                                if l.TextColor3 ~= TIMER_COLOR then
                                    l.TextColor3 = TIMER_COLOR
                                    l.TextStrokeTransparency = 0
                                end
                            end
                        end
                    end
                elseif existing then
                    pcall(function() existing:Destroy() end)   -- pas le 1er etage
                end
            end
        end
    end

    ------------------------------------------------------------------
    -- BOUCLE COMMUNE
    ------------------------------------------------------------------
    task.spawn(function()
        while true do
            -- PAUSE pendant un TP (anti-freeze) + throttle 6s (ESP non utilises pour l instant)
            if not (_G._isTpMoving or _G.MynxxStealHold) then
                if _G.TimerESP then pcall(refreshTimerESP) else pcall(clearTimerESP) end
                if _G.SubspaceMineESP then pcall(refreshMineESP) else pcall(clearMineESP) end
            end
            task.wait(6)
        end
    end)
end)

if not okESP then warn("[ESP] BLOC EN ERREUR: " .. tostring(errESP)) end
end)

-- ============================================================
-- RESET (portage COMPLET de mynxx.lua) -- reset simple & NON detecte
--
-- Remplace l ancien reset (qui scannait plein de candidats + posait son propre
-- hook + firait des remotes en aveugle). Ici, 1:1 depuis mynxx:
--   * CAPTURE PASSIVE du reset-remote: un hook FireServer/__namecall grab le
--     PREMIER remote "RE/*" que le JEU tire, et rappelle TOUJOURS l original
--     untouched. mynxx: seprvhub (UD) utilise ce hook exact -> ce n est PAS un
--     vecteur de detection. Fallback: _G.MynxxGetRemote("RemoteEvent","UseItem")
--     (resolu via secure_call, donc non detecte non plus).
--   * instantReset(): spamme ce remote avec une charge bidon jusqu au respawn
--     (la vie est server-authoritative, Health=0 ne fait rien).
--   * Le bouton Reset du menu Echap est reroute dessus.
--   * Auto Reset on Balloon: detecte 'ran "balloon" on you' -> executeReset(true).
--
-- _G.InstantReset() | _G.executeReset([isBalloon]) | _G.setAutoResetBalloon(on)
-- ============================================================

-- Ancien capture-par-frequence (+ hook) + fallback UseItem RETIRES. Le reset trouve
-- maintenant son remote de facon HOOKLESS (getgc + debug.getconstants/getupvalues sur
-- le ToolActivationController) dans le bloc ci-dessous. Aucun hook.

-- nowSpawn (PAS stagSpawn): le RESET doit etre actif IMMEDIATEMENT au chargement,
-- sans le differe de 6s d extras -> le reset marche des le debut.
nowSpawn(function()
local okRS, errRS = pcall(function()
    local Players = game:GetService("Players")
    local LP      = Players.LocalPlayer
    local PG      = LP:WaitForChild("PlayerGui")

    ------------------------------------------------------------------
    -- INSTANT RESET (HOOKLESS): trouve le remote de reset via getgc +
    -- debug.getconstants/getupvalues sur le ToolActivationController (nom
    -- reset/activ/ragdoll/balloon) et le resout via _G.Net, PUIS le spam.
    -- AUCUN hook FireServer/__namecall. Fallback: void-drop.
    ------------------------------------------------------------------
    local RUN = game:GetService("RunService")
    local RESET_TOKEN = "randomstring"
    local resetRemote, flooding = nil, false
    -- Players.RespawnTime = 0: respawn instantane apres le reset
    -- au lieu des ~5s par defaut. Reduit fortement le temps "mort -> respawn".
    pcall(function() Players.RespawnTime = 0 end)

    local function resolveByName(name)
        if type(name) ~= "string" or name == "" then return nil end
        local Net = _G.Net
        if not Net then return nil end
        local ok, r = pcall(function() return Net:RemoteEvent(name) end)
        if ok and typeof(r) == "Instance" and r:IsA("RemoteEvent") then return r end
        return nil
    end
    local function looksLikeResetName(s)
        if type(s) ~= "string" then return false end
        local low = s:lower()
        return (low:find("activ") or low:find("reset") or low:find("respawn")
            or low:find("ragdoll") or low:find("balloon")) ~= nil
    end
    local function isResetRemote(v)
        return typeof(v) == "Instance" and v:IsA("RemoteEvent")
            and type(v.Name) == "string" and v.Name:match("^RE/%x") ~= nil
    end
    local function sourceName(f)
        local dd = debug or {}
        local src
        if dd.info then local ok, s = pcall(dd.info, f, "s"); if ok and type(s) == "string" then src = s end end
        if (not src) and dd.getinfo then local ok, info = pcall(dd.getinfo, f); if ok and type(info) == "table" then src = info.short_src or info.source end end
        if not src then
            local env; pcall(function() env = getfenv(f) end)
            if type(env) == "table" then local s2; pcall(function() s2 = env.script end); if typeof(s2) == "Instance" then src = s2.Name end end
        end
        if type(src) == "string" then return src:match("[%.>/\\]([%w_ ]+)$") or src end
        return nil
    end
    local function isToolCtrl(name)
        if type(name) ~= "string" then return false end
        return name == "ToolActivationController" or name:find("ToolActiv") ~= nil
            or name:find("Activation") ~= nil or name:find("ToolController") ~= nil
    end
    local function nameShaped(s)
        return type(s) == "string" and #s >= 2 and #s <= 60 and s:match("^[%w_/]+$") ~= nil
    end

    local _lastScan = -1e9
    local function findResetRemote(force)
        local ov = resolveByName(_G.mynxxResetRemoteName)
        if ov then _G.mynxxResetRemoteFoundName = _G.mynxxResetRemoteName; return ov end
        if not getgc then return nil end
        if (not force) and (os.clock() - _lastScan) < 5 then return nil end
        _lastScan = os.clock()
        local dd = debug or {}
        local getconsts, getups = dd.getconstants, dd.getupvalues
        local directRemote
        local nameSet = {}
        pcall(function()
            local gc = getgc(true)
            for i = 1, #gc do
                local f = gc[i]
                if type(f) == "function" and (not iscclosure or not iscclosure(f)) then
                    local src = sourceName(f)
                    if isToolCtrl(src) then
                        if getconsts then
                            local cs; pcall(function() cs = getconsts(f) end)
                            if type(cs) == "table" then
                                for _, c in pairs(cs) do
                                    if nameShaped(c) and looksLikeResetName(c) then nameSet[c] = true end
                                end
                            end
                        end
                        if getups and not directRemote then
                            local ups; pcall(function() ups = getups(f) end)
                            if type(ups) == "table" then
                                for _, u in pairs(ups) do
                                    if isResetRemote(u) then directRemote = u; break end
                                    if type(u) == "table" then
                                        local n = 0
                                        for _, vv in pairs(u) do
                                            if isResetRemote(vv) then directRemote = vv; break end
                                            n = n + 1; if n >= 200 then break end
                                        end
                                        if directRemote then break end
                                    end
                                end
                            end
                        end
                    end
                end
                if (i % 2000) == 0 then RUN.Heartbeat:Wait() end
            end
        end)
        if directRemote then _G.mynxxResetRemoteFoundName = directRemote.Name; return directRemote end
        local tryNames = {}
        for nm in pairs(nameSet) do tryNames[#tryNames + 1] = nm end
        table.sort(tryNames)
        for _, nm in ipairs(tryNames) do
            local r = resolveByName(nm)
            if r then _G.mynxxResetRemoteFoundName = nm; return r end
        end
        return nil
    end

    task.spawn(function()
        -- trouve le remote EN FOND (jusqu a l avoir) -> presser reset ne declenche
        -- JAMAIS de scan getgc au moment du reset = plus de lag quand tu resets.
        local tries = 0
        while not resetRemote do
            local r = findResetRemote(true)
            if r then resetRemote = r; break end
            tries = tries + 1
            task.wait(tries < 8 and 3 or 30)   -- agressif 8x puis lent (anti-lag si jamais trouve)
        end
    end)

    -- fallback si aucun remote trouve: void-drop (chute dans le void -> respawn natif)
    local function voidDropReset(oldChar)
        local t0 = os.clock()
        local destroyY = tonumber(workspace.FallenPartsDestroyHeight) or -500
        while LP.Character == oldChar and (os.clock() - t0) < 6 do
            local h = oldChar and oldChar:FindFirstChild("HumanoidRootPart")
            if not h or not h.Parent then break end
            pcall(function()
                h.Anchored = false
                h.CFrame = CFrame.new(h.Position.X, destroyY - 60, h.Position.Z)
                h.AssemblyLinearVelocity = Vector3.new(0, -400, 0)
            end)
            task.wait()
        end
    end

    local function instantReset()
        if flooding then return end
        local plr = LP
        if not plr then return end
        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        flooding = true
        _G.mynxxResetAt = os.clock()
        local prevAD = _G.AntiDieDisabled
        _G.AntiDieDisabled = true
        pcall(function() hum.BreakJointsOnDeath = true end)
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
        pcall(function() hum.Health = 0 end)
        task.spawn(function()
            local added = false
            local ac
            ac = plr.CharacterAdded:Connect(function()
                added = true
                if ac then ac:Disconnect() ac = nil end
            end)
            local t0 = os.clock()
            while not added and os.clock() - t0 < 5 do task.wait(0.05) end
            if ac then ac:Disconnect() ac = nil end
            _G.AntiDieDisabled = prevAD
            flooding = false
        end)
    end
    _G.InstantReset = instantReset
    _G.mynxxInstaReset = instantReset

    ------------------------------------------------------------------
    -- FLING UP (touche X, rebindable dans "Keybind & Actions")
    -- Coupe le controleur du Humanoid (PlatformStand) et applique une grosse
    -- velocite verticale pendant FLING_SUSTAIN -> decollage net et CONSTANT,
    -- que tu bouges ou pas. _G.FlingActive met en pause le walkspeed CFrame
    -- pendant l operation (sinon son Heartbeat ecrase la velocite du fling).
    ------------------------------------------------------------------
    if _G.ResetFlingsUp == nil then _G.ResetFlingsUp = false end
    local FLING_POWER   = 99999999   -- vitesse verticale appliquee
    local FLING_SUSTAIN = 0.15       -- duree d application (s) pour vraiment decoller
    local function flingUp()
        local RS = game:GetService("RunService")
        local char = LP.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        -- PrimaryPart = le bon root meme pendant l invis steal (clone).
        local hrp  = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
        if not hrp or not hum or hum.Health <= 0 then return end

        _G.FlingActive = true

        pcall(function()
            hum.Sit = false
            hum.PlatformStand = true                           -- humanoid ne clampe plus au sol
            if hrp.Anchored then hrp.Anchored = false end
        end)

        local up = Vector3.new(0, FLING_POWER, 0)
        local t0 = os.clock()
        while os.clock() - t0 < FLING_SUSTAIN do
            char = LP.Character
            hum  = char and char:FindFirstChildOfClass("Humanoid")
            hrp  = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
            if not hrp or not hum or hum.Health <= 0 then break end
            if hrp.Anchored then hrp.Anchored = false end      -- desancre si bloque
            hrp.AssemblyLinearVelocity = up   -- moderne
            hrp.Velocity = up                 -- fallback legacy
            RS.Heartbeat:Wait()
        end

        pcall(function()
            if hum and hum.Parent then
                hum.PlatformStand = false
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end)
        _G.FlingActive = false
    end
    _G.FlingUp = flingUp

    ------------------------------------------------------------------
    -- BOUTON RESET DU MENU ECHAP
    -- Par defaut le bouton "Reset Character" fait un VRAI respawn (filet de
    -- securite pour te de-stuck). Le fling reste sur la touche X (_G.FlingUp).
    -- Mets _G.ResetFlingsUp = true si tu veux que le bouton du menu fling aussi.
    ------------------------------------------------------------------
    local be = Instance.new("BindableEvent")
    be.Event:Connect(function()
        if _G.ResetFlingsUp then
            pcall(flingUp)
        else
            pcall(instantReset)
        end
    end)
    task.spawn(function()
        for _ = 1, 12 do
            local ok = pcall(function()
                game:GetService("StarterGui"):SetCore("ResetButtonCallback", be)
            end)
            if ok then break end
            task.wait(1)
        end
    end)

    ------------------------------------------------------------------
    -- executeReset (cooldown 20s propre au declenchement balloon)
    ------------------------------------------------------------------
    local lastBalloonResetTime = 0
    local function executeReset(isBalloon)
        if isBalloon then
            if tick() - lastBalloonResetTime < 20 then return end
            lastBalloonResetTime = tick()
        end
        instantReset()
    end
    _G.executeReset = executeReset

    ------------------------------------------------------------------
    -- AUTO RESET ON BALLOON: 'ran "balloon" on you' -> executeReset(true)
    -- Persiste dans la section "reset" de MynxxHub.json.
    ------------------------------------------------------------------
    if _G.AutoResetBalloon == nil then _G.AutoResetBalloon = true end
    do
        local cfg = _G.HubCfg.get("reset")
        if type(cfg.balloon) == "boolean" then _G.AutoResetBalloon = cfg.balloon end
    end
    _G.setAutoResetBalloon = function(on)
        _G.AutoResetBalloon = on and true or false
        local cfg = _G.HubCfg.get("reset")
        cfg.balloon = _G.AutoResetBalloon
        _G.HubCfg.save()
    end
    task.spawn(function()
        while true do
            task.wait(6)   -- throttle anti-freeze (scan PlayerGui espace a 6s)
            if _G.AutoResetBalloon and not (_G._isTpMoving or _G.MynxxStealHold) then
                pcall(function()
                    for _, g in ipairs(PG:GetDescendants()) do
                        if g:IsA("TextLabel") or g:IsA("TextButton") then
                            local t = g.Text
                            if t and string.find(t, 'ran "balloon" on you', 1, true) then
                                executeReset(true)
                                break
                            end
                        end
                    end
                end)
            end
        end
    end)
end)

if not okRS then warn("[RESET] BLOC EN ERREUR: " .. tostring(errRS)) end
end)

-- ============================================================
-- LINE TO BASE (portage de mynxx, en BLANC)
-- Un Beam entre ton HumanoidRootPart et le panneau de TA base.
-- Seule difference avec mynxx: la couleur, passee de rouge (255,40,40)
-- a blanc pur.
--
-- Detection de ta base: mynxx utilise d abord _G.isMyPlot_Instant (qui
-- n existe pas ici) puis un repli. On garde uniquement le repli: le
-- BillboardGui "YourBase" du PlotSign, sinon le texte du panneau compare
-- a ton pseudo.
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okLB, errLB = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local LP         = Players.LocalPlayer

    local BEAM_NAME  = "PlotBeam"
    local ATT0_NAME  = "PlotBeamAttach_Player"
    local ATT1_NAME  = "PlotBeamAttach_Plot"
    local BEAM_COLOR = Color3.fromRGB(255, 255, 255)   -- full white

    if _G.LineToBase == nil then _G.LineToBase = true end

    local plotBeam, plotAtt0, plotAtt1
    -- ANCRAGE PERSISTANT: une part invisible, ancree a la derniere position connue de
    -- ta base. Le beam pointe dessus. Comme c est une instance locale, elle n est PAS
    -- soumise au streaming (contrairement a la part du plot qui se decharge quand tu
    -- t eloignes -> c est ce qui faisait disparaitre la ligne). Conteneur = Folder
    -- persistant (voir _anchorHolder), PAS la CurrentCamera (recreee au respawn).
    local beamAnchor, lastPlotPos
    -- CONTENEUR PERSISTANT: un Folder local dans workspace. Avant, l ancre etait
    -- parentee a workspace.CurrentCamera, MAIS la Camera est DETRUITE et recreee a
    -- chaque respawn/reset -> l ancre partait avec, et c est ce qui faisait
    -- disparaitre la ligne apres un reset. Un Folder local dans workspace survit au
    -- respawn et n est PAS soumis au streaming (instance cote client).
    local function _anchorHolder()
        local h = workspace:FindFirstChild("MynxxBeamHolder")
        if not h or not h:IsA("Folder") then
            if h then pcall(function() h:Destroy() end) end
            h = Instance.new("Folder")
            h.Name = "MynxxBeamHolder"
            h.Parent = workspace
        end
        return h
    end
    local function ensureAnchor()
        if beamAnchor and beamAnchor.Parent then return beamAnchor end
        if beamAnchor then pcall(function() beamAnchor:Destroy() end) end
        local p = Instance.new("Part")
        p.Name = "PlotBeamAnchor"; p.Anchored = true
        p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
        p.Transparency = 1; p.CastShadow = false; p.Size = Vector3.new(1, 1, 1)
        p.Parent = _anchorHolder()
        beamAnchor = p
        return p
    end

    local function applyStyle(beam)
        if not beam then return end
        beam.FaceCamera    = true
        beam.LightEmission = 1
        beam.Color         = ColorSequence.new(BEAM_COLOR)
        beam.Transparency  = NumberSequence.new(0)   -- full white, opaque
        beam.Width0        = 0.45
        beam.Width1        = 0.45
        beam.TextureMode   = Enum.TextureMode.Wrap
        beam.TextureSpeed  = 0
        beam.Enabled       = true
    end

    local function destroyBeam()
        if plotBeam then pcall(function() plotBeam:Destroy() end) end
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            local old = hrp:FindFirstChild("PlotBeamGlow")
            if old then pcall(function() old:Destroy() end) end
        end
        if plotAtt0 then pcall(function() plotAtt0:Destroy() end) end
        if plotAtt1 then pcall(function() plotAtt1:Destroy() end) end
        if beamAnchor then pcall(function() beamAnchor:Destroy() end) end
        plotBeam, plotAtt0, plotAtt1, beamAnchor, lastPlotPos = nil, nil, nil, nil, nil
    end

    local _myPlotCache, _myPlotCacheT = nil, 0
    local function _scanMyPlot()
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return nil end
        for _, plot in ipairs(plots:GetChildren()) do
            local sign = plot:FindFirstChild("PlotSign")
            if sign then
                local yb = sign:FindFirstChild("YourBase")
                if yb and yb:IsA("BillboardGui") and yb.Enabled then return plot end
                local sg = sign:FindFirstChildWhichIsA("SurfaceGui", true)
                if sg then
                    local label = sg:FindFirstChildWhichIsA("TextLabel", true)
                    if label and label.Text then
                        local t = label.Text:lower()
                        if t:find(LP.DisplayName:lower(), 1, true)
                           or t:find(LP.Name:lower(), 1, true) then
                            return plot
                        end
                    end
                end
            end
        end
        return nil
    end
    -- CACHE: ta base ne bouge pas -> inutile de refaire le scan recursif ~6x/s
    -- (c etait un cout constant pendant le TP). On re-scanne au max toutes les
    -- 1.5s, ou tout de suite si le plot cache a disparu (respawn/streaming).
    local function findMyPlot()
        if _myPlotCache and _myPlotCache.Parent and (os.clock() - _myPlotCacheT) < 1.5 then
            return _myPlotCache
        end
        _myPlotCache = _scanMyPlot()
        _myPlotCacheT = os.clock()
        return _myPlotCache
    end
    -- Expose pour l Auto Buy (kick uniquement si le brainrot atterrit dans MA base).
    _G.MynxxFindMyPlot = findMyPlot

    local function getAnchorPart(plot)
        if not plot then return nil end
        local sign = plot:FindFirstChild("PlotSign")
        if sign then
            if sign:IsA("BasePart") then return sign end
            local part = sign:FindFirstChildWhichIsA("BasePart", true)
            if part then return part end
        end
        local main = plot:FindFirstChild("MainRootPart")
        if main and main:IsA("BasePart") then return main end
        return plot:FindFirstChildWhichIsA("BasePart")
    end

    local function ensureBeam(hrp, plotPos)
        if not hrp or not hrp.Parent or not plotPos then return end
        ensureAnchor()
        beamAnchor.Position = plotPos

        -- attachment cote joueur
        if not plotAtt0 or not plotAtt0.Parent or plotAtt0.Parent ~= hrp then
            if plotAtt0 then pcall(function() plotAtt0:Destroy() end) end
            plotAtt0 = Instance.new("Attachment")
            plotAtt0.Name = ATT0_NAME
            plotAtt0.Parent = hrp
        end

        -- attachment cote base, sur l ANCHOR persistant (pas la part du plot)
        if not plotAtt1 or not plotAtt1.Parent or plotAtt1.Parent ~= beamAnchor then
            if plotAtt1 then pcall(function() plotAtt1:Destroy() end) end
            plotAtt1 = Instance.new("Attachment")
            plotAtt1.Name = ATT1_NAME
            plotAtt1.Position = Vector3.new(0, 4, 0)
            plotAtt1.Parent = beamAnchor
        end

        if not plotBeam or not plotBeam.Parent then
            if plotBeam then pcall(function() plotBeam:Destroy() end) end
            local oldGlow = hrp:FindFirstChild("PlotBeamGlow")
            if oldGlow then pcall(function() oldGlow:Destroy() end) end
            plotBeam = Instance.new("Beam")
            plotBeam.Name = BEAM_NAME
            applyStyle(plotBeam)
            plotBeam.Parent = hrp
        end
        plotBeam.Attachment0 = plotAtt0
        plotBeam.Attachment1 = plotAtt1
    end

    -- REPARATION CHAQUE frame: ensureBeam recree att/beam des qu ils ont saute
    -- (toggle invis -> le clone qui portait le beam est detruit au revert, respawn,
    -- blip de streaming...). Seul le SCAN de la base est throttle (findMyPlot cache
    -- deja a 1.5s) -> ligne PERMANENTE au lieu de "parfois la, parfois pas", cout
    -- negligeable (ensureBeam ne fait que verifier des refs existantes).
    local check = 10   -- scan des la 1re frame (ligne visible tout de suite)
    RunService.Heartbeat:Connect(function()
        if not _G.LineToBase then
            if plotBeam or plotAtt0 or plotAtt1 or beamAnchor then destroyBeam() end
            return
        end

        local char = LP.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            -- respawn: on lache juste le beam + l attachment joueur, mais on
            -- GARDE l anchor + la derniere position connue de la base
            if plotBeam then pcall(function() plotBeam:Destroy() end); plotBeam = nil end
            if plotAtt0 then pcall(function() plotAtt0:Destroy() end); plotAtt0 = nil end
            return
        end

        -- SCAN throttle (~1 frame sur 10): rafraichit la position connue de ta base
        -- si elle est streamee la. findMyPlot a deja son propre cache 1.5s.
        check = check + 1
        if check >= 10 then
            check = 0
            local myPlot = findMyPlot()
            if myPlot then
                local plotPart = getAnchorPart(myPlot)
                if plotPart and plotPart.Parent then
                    lastPlotPos = plotPart.Position
                end
            end
        end

        -- CHAQUE frame: des qu on a une position connue, on (re)pose la ligne dessus
        -- MEME si la base est dechargee (streaming) ou si le beam a ete detruit par un
        -- toggle invis / respawn -> auto-heal instantane, plus de disparition.
        if lastPlotPos then
            pcall(ensureBeam, hrp, lastPlotPos)
        end
    end)

    -- RESET / RESPAWN: au nouveau character, le beam + l attachment cote joueur ont
    -- ete detruits avec l ancien HRP. On lache leurs refs et on force un rescan
    -- immediat (check=10) -> la ligne se reforme des la 1re frame, a CHAQUE reset,
    -- sans dependre du timing de l auto-heal. L ancre + lastPlotPos sont conserves.
    LP.CharacterAdded:Connect(function()
        plotBeam, plotAtt0 = nil, nil
        check = 10
    end)

    _G.toggleLineToBase = function(on)
        _G.LineToBase = (on == nil) and (not _G.LineToBase) or (on and true or false)
        if not _G.LineToBase then destroyBeam() end
    end
end)

if not okLB then warn("[LINETOBASE] BLOC EN ERREUR: " .. tostring(errLB)) end
end)

-- ============================================================
-- ANTI BEE & DISCO  --  portage COMPLET de message.txt (SharedState.ANTI_BEE_DISCO)
--
-- Repris tel quel de message.txt:
--   * nuke par NOM des mauvais objets de Lighting
--     (Blue / DiscoEffect / BeeBlur / ColorCorrection)
--   * protectControls: l abeille remplace Controls.moveFunction pour bloquer
--     ton deplacement -> on repose notre fonction a chaque frame (sauf TP)
--   * blockBuzzingSound: coupe le son "Buzzing" de l abeille (chaque frame)
--   * Enable / Disable + _G.ANTI_BEE_DISCO expose (comme message.txt)
--
-- CONSERVE de l ancien bloc extras (demande): le "tueur de post-effets par
-- CLASSE" (Blur / Bloom / SunRays / ColorCorrection / DepthOfField), fusionne
-- dans nuke() -> supprime aussi les post-effets que le filtre par nom rate.
--
-- Adaptations: pas de Config ni de ShowNotification (console muette). L etat
-- vit dans _G.EffetsRemover (defaut true = actif au lancement, =false pour
-- couper). _G.setEffetsRemover(on) garde pour compat avec l ancien bloc.
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
nowSpawn(function()
local okER, errER = pcall(function()
    local Players     = game:GetService("Players")
    local RunService  = game:GetService("RunService")
    local Lighting    = game:GetService("Lighting")
    local LocalPlayer = Players.LocalPlayer

    if _G.EffetsRemover == nil then _G.EffetsRemover = true end

    -- structure reprise de SharedState.ANTI_BEE_DISCO (message.txt)
    local AB = {
        running              = false,
        connections          = {},
        originalMoveFunction = nil,
        controlsProtected    = false,
        -- anti-bee & disco par NOM (message.txt)
        badLightingNames = { Blue = true, DiscoEffect = true, BeeBlur = true, ColorCorrection = true },
        -- effets remover par CLASSE (conserve de l ancien bloc extras)
        killClasses = {
            BlurEffect            = true,
            BloomEffect           = true,
            SunRaysEffect         = true,
            ColorCorrectionEffect = true,
            DepthOfFieldEffect    = true,
        },
    }

    -- nuke:
    --   * par NOM (bee/disco griefeurs) -> on DETRUIT: le jeu ne les gere pas.
    --   * par CLASSE (post-effets) -> on DESACTIVE (Enabled=false) au lieu de
    --     detruire. Certains post-effets sont geres par les scripts du jeu
    --     (ex: Lighting.SunRays lu chaque frame par CycleController). Les
    --     DETRUIRE cassait ces scripts -> spam "SunRays is not a valid member
    --     of Lighting". Desactives, ils restent des instances valides mais
    --     n affichent plus rien.
    AB.nuke = function(obj)
        if not obj or not obj.Parent then return end
        if AB.badLightingNames[obj.Name] then
            pcall(function() obj:Destroy() end)
            return
        end
        if AB.killClasses[obj.ClassName] then
            pcall(function() obj.Enabled = false end)
        end
    end

    AB.disconnectAll = function()
        for _, conn in ipairs(AB.connections) do
            if typeof(conn) == "RBXScriptConnection" then conn:Disconnect() end
        end
        AB.connections = {}
    end

    -- l abeille remplace Controls.moveFunction pour te bloquer: on repose la
    -- notre a chaque frame (sauf pendant un TP, sinon on casse le trajet)
    AB.protectControls = function()
        if AB.controlsProtected then return end
        -- BUG CORRIGE: au demarrage (nowSpawn) le PlayerModule n est PAS encore
        -- charge. L ancien FindFirstChild renvoyait nil -> "if not PlayerModule then
        -- return" -> la protection ne s installait JAMAIS -> l inversion des touches
        -- (bee) n etait jamais contree. On ATTEND le module (WaitForChild) et on
        -- retente l acquisition des Controls jusqu a l avoir (au lancement = propre).
        task.spawn(function()
            local ps = LocalPlayer:WaitForChild("PlayerScripts", 60)
            local pm = ps and ps:WaitForChild("PlayerModule", 60)
            if not pm then return end
            local Controls
            for _ = 1, 300 do
                local ok, c = pcall(function() return require(pm):GetControls() end)
                if ok and c and type(c.moveFunction) == "function" then Controls = c break end
                task.wait(0.1)
            end
            if not Controls or AB.controlsProtected then return end
            -- capture la VRAIE moveFunction (propre au lancement, avant tout bee).
            if not AB.originalMoveFunction then AB.originalMoveFunction = Controls.moveFunction end
            local function protectedMoveFunction(self, moveVector, relativeToCamera)
                if AB.originalMoveFunction then AB.originalMoveFunction(self, moveVector, relativeToCamera) end
            end
            -- re-force NOTRE moveFunction chaque frame -> annule tout remplacement
            -- (bee = inversion du deplacement). Jamais pendant un TP.
            table.insert(AB.connections, RunService.Heartbeat:Connect(function()
                if not AB.running or not _G.EffetsRemover then return end
                if _G._isTpMoving then return end
                if Controls.moveFunction ~= protectedMoveFunction then
                    Controls.moveFunction = protectedMoveFunction
                end
            end))
            Controls.moveFunction = protectedMoveFunction
            AB.controlsProtected = true
        end)
    end

    AB.restoreControls = function()
        if not AB.controlsProtected then return end
        pcall(function()
            local PlayerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
            local PlayerModule = PlayerScripts and PlayerScripts:FindFirstChild("PlayerModule")
            if not PlayerModule then return end
            local Controls = require(PlayerModule):GetControls()
            if Controls and AB.originalMoveFunction then
                Controls.moveFunction = AB.originalMoveFunction
                AB.controlsProtected = false
            end
        end)
    end

    AB.blockBuzzingSound = function()
        pcall(function()
            local PlayerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
            local beeScript = PlayerScripts and PlayerScripts:FindFirstChild("Bee", true)
            if beeScript then
                local buzzing = beeScript:FindFirstChild("Buzzing")
                if buzzing and buzzing:IsA("Sound") then
                    buzzing:Stop()
                    buzzing.Volume = 0
                end
            end
        end)
    end

    AB.Enable = function()
        if AB.running then return end
        AB.running = true
        _G.EffetsRemover = true
        -- 1er passage: on nettoie tout Lighting (par classe + par nom)
        for _, inst in ipairs(Lighting:GetDescendants()) do AB.nuke(inst) end
        -- tout nouvel effet ajoute a Lighting est tue a la volee
        table.insert(AB.connections, Lighting.DescendantAdded:Connect(function(obj)
            if not AB.running or not _G.EffetsRemover then return end
            AB.nuke(obj)
        end))
        AB.protectControls()
        -- coupe le buzz a chaque frame (comme message.txt)
        table.insert(AB.connections, RunService.Heartbeat:Connect(function()
            if not AB.running or not _G.EffetsRemover then return end
            AB.blockBuzzingSound()
        end))
    end

    AB.Disable = function()
        if not AB.running then return end
        AB.running = false
        _G.EffetsRemover = false
        AB.restoreControls()
        AB.disconnectAll()
    end

    _G.ANTI_BEE_DISCO = AB
    -- compat avec l ancien bloc: _G.setEffetsRemover(true/false)
    _G.setEffetsRemover = function(on)
        if on then AB.Enable() else AB.Disable() end
    end

    -- actif par defaut (comportement extras)
    if _G.EffetsRemover then AB.Enable() end
end)

if not okER then warn("[ANTIBEEDISCO] BLOC EN ERREUR: " .. tostring(errER)) end
end)

-- ============================================================
-- ACTIONS  --  nouveau panneau + GESTION DU FOV (portage de message.txt)
--
-- FOV: on force le champ de vision de la camera a la valeur choisie a CHAQUE
-- frame (RenderStepped). Le jeu remet souvent le FOV a sa valeur par defaut
-- (zoom, entree de base, effets divers): l enforcement continu garantit que
-- "c est toujours la meme" -- ta valeur ne bouge plus.
--   Reglable de 50 a 120 (defaut 70). Slider + boutons [-]/[+].
--   Persiste dans MynxxHub.json, section "actions".
--   _G.MynxxFOV = valeur courante   |  _G.setFOV(v) pour la changer a chaud
--   _G.MynxxFOVEnabled = false       pour couper l enforcement.
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
nowSpawn(function()
local okAC, errAC = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local LP         = Players.LocalPlayer
    local PG         = LP:WaitForChild("PlayerGui")
    local guiParent  = (gethui and gethui()) or game:GetService("CoreGui") or PG

    ------------------------------------------------------------------
    -- CONFIG (section "actions" du fichier partage MynxxHub.json)
    ------------------------------------------------------------------
    local MINV, MAXV, DEFV = 50, 120, 70
    local cfg = _G.HubCfg.get("actions")
    if _G.MynxxFOV        == nil then _G.MynxxFOV        = DEFV end
    if _G.MynxxFOVEnabled == nil then _G.MynxxFOVEnabled = true end
    local panelX, panelY = 240, 470
    do
        if tonumber(cfg.fov) then _G.MynxxFOV = math.clamp(tonumber(cfg.fov), MINV, MAXV) end
        if tonumber(cfg.x)   then panelX = tonumber(cfg.x) end
        if tonumber(cfg.y)   then panelY = tonumber(cfg.y) end
    end
    local function saveCfg()
        cfg.fov = _G.MynxxFOV
        cfg.x = panelX; cfg.y = panelY
        _G.HubCfg.save()
    end

    ------------------------------------------------------------------
    -- FOV: valeur + enforcement continu (le coeur du systeme message.txt)
    ------------------------------------------------------------------
    local function setFOVValue(v)
        v = math.clamp(math.floor((tonumber(v) or DEFV) + 0.5), MINV, MAXV)
        _G.MynxxFOV = v
        pcall(function() cfg.fov = v; _G.HubCfg.save() end)   -- PERSISTE le FOV (ne se sauvait jamais)
        return v
    end
    _G.setFOV = setFOVValue
    setFOVValue(_G.MynxxFOV)

    -- on ecrase le FOV a chaque frame -> le jeu ne peut plus le reprendre
    RunService.RenderStepped:Connect(function()
        if not _G.MynxxFOVEnabled then return end
        local cam = workspace.CurrentCamera
        if cam then
            local target = tonumber(_G.MynxxFOV) or DEFV
            if math.abs(cam.FieldOfView - target) > 0.01 then
                cam.FieldOfView = target
            end
        end
    end)

    -- GUI ACTIONS (FOV) DEPLACE dans le panneau "Keybind & Actions" (fusion)
end)

if not okAC then warn("[ACTIONS] BLOC EN ERREUR: " .. tostring(errAC)) end
end)

-- ============================================================
-- PLAYER ESP + BASE OWNER ESP  (portage de mynxx)
--
-- PLAYER ESP: un billboard au-dessus de chaque autre joueur -> pseudo (rouge
-- s il tient un outil dangereux), outil tenu (bleu), et "Stealing..." en rouge
-- quand il vole. Gele pendant un TP (_G._isTpMoving). ON par defaut.
--
-- BASE OWNER ESP: contour rouge + tag "BASE OWNER" sur le proprietaire de la
-- base ou TU te trouves (un seul a la fois, jamais toi). ON par defaut.
--
-- Adaptations extras: Config -> _G.MynxxPlayerESP / _G.MynxxBaseOwnerESP
-- (persistes section "esp"), pas de setToggle/saveConfig. Le proprietaire est
-- lu depuis le panneau PlotSign (le Synchronizer de mynxx n existe pas ici), et
-- le nom du brainrot vole est simplifie en "Stealing..." (pas de getStealingInfo
-- ni de tracking morph). Toggles: _G.setPlayerESP(on) | _G.setBaseOwnerESP(on)
--
-- Differe de 5s comme les autres ajouts.
-- ============================================================
stagSpawn(function()
local okESP2, errESP2 = pcall(function()
    local Players    = game:GetService("Players")
    local LP         = Players.LocalPlayer
    local guiParent  = (gethui and gethui()) or game:GetService("CoreGui")

    -- CONFIG (section "esp")
    local cfg = _G.HubCfg.get("esp")
    if _G.MynxxPlayerESP    == nil then _G.MynxxPlayerESP    = true end
    if _G.MynxxBaseOwnerESP == nil then _G.MynxxBaseOwnerESP = true end
    do
        if type(cfg.player) == "boolean" then _G.MynxxPlayerESP    = cfg.player end
        if type(cfg.owner)  == "boolean" then _G.MynxxBaseOwnerESP = cfg.owner end
    end
    local function saveCfg()
        cfg.player = _G.MynxxPlayerESP
        cfg.owner  = _G.MynxxBaseOwnerESP
        _G.HubCfg.save()
    end

    ------------------------------------------------------------------
    -- HELPERS PARTAGES (plot + proprietaire)
    ------------------------------------------------------------------
    local function getPlotAtPosition(pos)
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return nil end
        local closestPlot, minDistance = nil, math.huge
        for _, plot in ipairs(plots:GetChildren()) do
            local plotPos
            if plot:IsA("Model") then
                plotPos = plot.PrimaryPart and plot.PrimaryPart.Position or plot:GetPivot().Position
            else
                plotPos = plot.Position
            end
            if plotPos then
                local distH = math.sqrt((pos.X - plotPos.X)^2 + (pos.Z - plotPos.Z)^2)
                if distH < minDistance then minDistance = distH; closestPlot = plot end
            end
        end
        if closestPlot and minDistance < 72 then return closestPlot end
        return nil
    end

    -- proprietaire lu depuis le panneau PlotSign ("Pseudo's Base")
    local function getPlotOwner(plot)
        if not plot then return nil end
        local sign = plot:FindFirstChild("PlotSign")
        local textLabel = sign
            and sign:FindFirstChild("SurfaceGui")
            and sign.SurfaceGui:FindFirstChild("Frame")
            and sign.SurfaceGui.Frame:FindFirstChild("TextLabel")
        if textLabel then
            local baseText = textLabel.Text
            local nickname = (baseText and baseText:match("^(.-)'")) or baseText
            if nickname and nickname ~= "" then
                for _, p in ipairs(Players:GetPlayers()) do
                    if (p.DisplayName == nickname) or (p.Name == nickname) then return p end
                end
            end
        end
        return nil
    end

    ------------------------------------------------------------------
    -- PLAYER ESP
    ------------------------------------------------------------------
    local playerBillboards = {}
    local DANGER_TOOLS = { ["Boogie Bomb"]=true, ["Medusa's Head"]=true, ["Body Swap Potion"]=true,
        ["Laser Cape"]=true, ["Rainbowrath Sword"]=true, ["Gummy Bear"]=true }
    local function getHeldTool(p)
        local c = p.Character; if not c then return nil end
        for _, o in ipairs(c:GetChildren()) do if o:IsA("Tool") then return o.Name end end
        return nil
    end
    local function makePlayerBillboard(plr)
        local bb = Instance.new("BillboardGui")
        bb.Name = "PlayerESP_" .. tostring(plr.UserId); bb.Size = UDim2.new(0, 170, 0, 48)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 2.8, 0); bb.AlwaysOnTop = true
        bb.LightInfluence = 0; bb.ResetOnSpawn = false
        local nameLbl = Instance.new("TextLabel", bb); nameLbl.Size = UDim2.new(1, 0, 0, 18)
        nameLbl.BackgroundTransparency = 1; nameLbl.Font = Enum.Font.GothamBold; nameLbl.TextSize = 14
        nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255); nameLbl.TextStrokeTransparency = 0.4
        nameLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0); nameLbl.Text = plr.Name
        local toolLbl = Instance.new("TextLabel", bb); toolLbl.Name = "ToolLabel"
        toolLbl.Size = UDim2.new(1, 0, 0, 13); toolLbl.Position = UDim2.new(0, 0, 0, 18)
        toolLbl.BackgroundTransparency = 1; toolLbl.Font = Enum.Font.GothamMedium; toolLbl.TextSize = 11
        toolLbl.TextColor3 = Color3.fromRGB(100, 220, 255); toolLbl.TextStrokeTransparency = 0.4
        toolLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0); toolLbl.Text = getHeldTool(plr) or ""
        local stealLbl = Instance.new("TextLabel", bb); stealLbl.Name = "StealLabel"
        stealLbl.Size = UDim2.new(1, 0, 0, 13); stealLbl.Position = UDim2.new(0, 0, 0, 31)
        stealLbl.BackgroundTransparency = 1; stealLbl.Font = Enum.Font.GothamBold; stealLbl.TextSize = 11
        stealLbl.TextColor3 = Color3.fromRGB(255, 60, 60); stealLbl.TextStrokeTransparency = 0.4
        stealLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0); stealLbl.Text = ""
        return bb, nameLbl
    end
    local function createOrRefreshPlayerESP(plr)
        if plr == LP then return end
        local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local hum = plr.Character:FindFirstChild("Humanoid")
        if hum then hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end
        local uid = plr.UserId; local entry = playerBillboards[uid]
        if not entry or not entry.bb or not entry.bb.Parent then
            if entry and entry.bb then pcall(function() entry.bb:Destroy() end) end
            local bb, nameLbl = makePlayerBillboard(plr)
            bb.Adornee = hrp; bb.Parent = hrp
            playerBillboards[uid] = { bb = bb, nameLbl = nameLbl, player = plr }
        elseif entry.bb.Adornee ~= hrp then
            entry.bb.Adornee = hrp; entry.bb.Parent = hrp
        end
    end
    local function clearPlayerESP()
        for uid, entry in pairs(playerBillboards) do
            if entry.bb then pcall(entry.bb.Destroy, entry.bb) end
            playerBillboards[uid] = nil
        end
    end
    _G.setPlayerESP = function(on)
        _G.MynxxPlayerESP = on and true or false
        if not _G.MynxxPlayerESP then clearPlayerESP() end
        saveCfg()
    end

    task.spawn(function()
        while true do
            task.wait(6)   -- throttle anti-freeze (Player ESP non utilise pour l instant)
            if _G._isTpMoving or _G.MynxxStealHold then continue end   -- ESP gele pendant un TP
            if _G.MynxxPlayerESP then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LP then pcall(createOrRefreshPlayerESP, plr) end
                end
                for _, entry in pairs(playerBillboards) do
                    if entry.bb and entry.bb.Parent then
                        pcall(function()
                            local tl = entry.bb:FindFirstChild("ToolLabel")
                            if tl then
                                local ht = getHeldTool(entry.player)
                                tl.Text = ht or ""
                                if entry.nameLbl then
                                    entry.nameLbl.TextColor3 = (ht and DANGER_TOOLS[ht])
                                        and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(255, 255, 255)
                                end
                            end
                        end)
                        pcall(function()
                            local sl = entry.bb:FindFirstChild("StealLabel")
                            if sl then
                                sl.Text = entry.player:GetAttribute("Stealing") and "Stealing..." or ""
                            end
                        end)
                    end
                end
            else
                clearPlayerESP()
            end
        end
    end)

    ------------------------------------------------------------------
    -- BASE OWNER ESP
    ------------------------------------------------------------------
    local entries = {}   -- userId -> { hl = Highlight, bb = BillboardGui }
    local function destroyEntry(e)
        if not e then return end
        if e.hl then pcall(function() e.hl:Destroy() end) end
        if e.bb then pcall(function() e.bb:Destroy() end) end
    end
    local function clearAllOwner()
        for uid, e in pairs(entries) do destroyEntry(e); entries[uid] = nil end
    end
    local function makeTag()
        local bb = Instance.new("BillboardGui")
        bb.Name = "BaseOwnerTag"; bb.Size = UDim2.new(0, 160, 0, 34)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0); bb.AlwaysOnTop = true; bb.LightInfluence = 0
        local lbl = Instance.new("TextLabel", bb)
        lbl.Size = UDim2.fromScale(1, 1); lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.GothamBlack; lbl.TextSize = 18
        lbl.TextColor3 = Color3.fromRGB(255, 60, 60)
        lbl.TextStrokeTransparency = 0; lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        lbl.Text = "BASE OWNER"
        return bb
    end
    local function setOwnerTarget(plr)
        for uid, e in pairs(entries) do
            if not plr or uid ~= plr.UserId then destroyEntry(e); entries[uid] = nil end
        end
        if not plr or not plr.Character then return end
        local uid = plr.UserId
        local e = entries[uid]; if not e then e = {}; entries[uid] = e end
        if not e.hl or not e.hl.Parent then
            if e.hl then pcall(function() e.hl:Destroy() end) end
            local hl = Instance.new("Highlight")
            hl.Name = "BaseOwnerESP"
            hl.FillColor = Color3.fromRGB(255, 0, 0); hl.FillTransparency = 0.6
            hl.OutlineColor = Color3.fromRGB(255, 0, 0); hl.OutlineTransparency = 0
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = guiParent
            e.hl = hl
        end
        if e.hl.Adornee ~= plr.Character then e.hl.Adornee = plr.Character end
        if not e.bb or not e.bb.Parent then
            if e.bb then pcall(function() e.bb:Destroy() end) end
            e.bb = makeTag(); e.bb.Parent = guiParent
        end
        local head = plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart")
        if head and e.bb.Adornee ~= head then e.bb.Adornee = head end
    end
    local function refreshOwner()
        local char = LP.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then setOwnerTarget(nil); return end
        local plot = getPlotAtPosition(hrp.Position)
        local owner = plot and getPlotOwner(plot)
        if owner == LP then owner = nil end   -- jamais ta propre base
        setOwnerTarget(owner)
    end
    _G.setBaseOwnerESP = function(on)
        _G.MynxxBaseOwnerESP = on and true or false
        if _G.MynxxBaseOwnerESP then pcall(refreshOwner) else clearAllOwner() end
        saveCfg()
    end
    _G.clearBaseOwnerESP = clearAllOwner

    task.spawn(function()
        while true do
            task.wait(6)   -- throttle anti-freeze (Base Owner ESP non utilise pour l instant)
            if _G.MynxxBaseOwnerESP and not (_G._isTpMoving or _G.MynxxStealHold) then pcall(refreshOwner)
            elseif next(entries) then clearAllOwner() end
        end
    end)
end)

if not okESP2 then warn("[ESP2] BLOC EN ERREUR: " .. tostring(errESP2)) end
end)

-- (FPS BOOST retire a la demande de l utilisateur : moteur + toggle supprimes.
--  Le watermark FPS/PING reste, c est le bloc separe juste en dessous.)

-- ============================================================
-- WATERMARK FPS / PING  --  cadre centre en haut de l ecran (dark theme)
-- On incremente juste un compteur de frames (cout ~0) et on lit/affiche
-- ~2x/sec. Ping = Roblox Data Ping (ms), le vrai round-trip reseau.
-- Aucun calcul lourd par frame => zero lag. Style aligne sur le BASE TIMER HUD.
-- ============================================================
stagSpawn(function()
    local okWMU, errWMU = pcall(function()
    local Players    = game:GetService("Players")
    local RunService  = game:GetService("RunService")
    local Stats       = game:GetService("Stats")
    local LP          = Players.LocalPlayer
    local PG          = LP:WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "MynxxWatermark"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.DisplayOrder = 999998
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    gui.Parent = PG

    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0.5, 0)
    frame.Position = UDim2.new(0.5, 0, 0, 6)   -- tout en haut, le BASE TIMER se met juste dessous
    frame.Size = UDim2.new(0, 190, 0, 24)
    frame.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = frame
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(95, 95, 110); stroke.Transparency = 0.35; stroke.Thickness = 1; stroke.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -12, 1, 0)
    label.Position = UDim2.new(0, 6, 0, 0)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(235, 235, 240)
    label.TextStrokeTransparency = 0.4
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.Text = "FPS: --  |  PING: --"
    label.Parent = frame

    local _fCount, _fAccum, _fps = 0, 0, 0
    RunService.RenderStepped:Connect(function(dt)
        _fCount = _fCount + 1; _fAccum = _fAccum + dt
        if _fAccum >= 0.5 then _fps = math.floor(_fCount / _fAccum + 0.5); _fCount = 0; _fAccum = 0 end
    end)
    task.spawn(function()
        while frame.Parent do
            local ping = 0
            pcall(function() ping = math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue() + 0.5) end)
            label.Text = string.format("FPS: %d  |  PING: %dms", _fps, ping)
            task.wait(0.5)
        end
    end)
    end)
    if not okWMU then warn("[WATERMARK FPS/PING] BLOC EN ERREUR: " .. tostring(errWMU)) end
end)

-- ============================================================
-- BASE TIMER HUD  --  le timer de la base ou TU te trouves, en haut de l ecran
-- Le jeu pose un BillboardGui "RemainingTime" par etage sur chaque plot (le
-- meme que lit le Timer ESP). Ici on prend la base la PLUS PROCHE de toi
-- (celle ou tu es), on lit le timer de son 1er etage (billboard le plus bas)
-- et on l affiche dans un cadre centre en haut, style watermark (dark theme).
-- Cache automatiquement quand tu n es sur aucune base. Pause pendant les TP.
-- ============================================================
stagSpawn(function()
    local okBT, errBT = pcall(function()
    local Players   = game:GetService("Players")
    local Workspace = game:GetService("Workspace")
    local LP        = Players.LocalPlayer
    local PG        = LP:WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "MynxxBaseTimer"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.DisplayOrder = 999998
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    gui.Parent = PG

    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0.5, 0)
    frame.Position = UDim2.new(0.5, 0, 0, 54)   -- juste sous le watermark FPS/PING
    frame.Size = UDim2.new(0, 120, 0, 52)
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.Parent = gui

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 1, 0)
    label.Position = UDim2.new(0, 0, 0, 0)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 38
    label.TextColor3 = Color3.fromRGB(200, 200, 210)
    label.TextStrokeTransparency = 0.5
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.Text = "--"
    label.Parent = frame

    -- base (plot) la plus proche de toi, dans un rayon de 80 studs (= celle ou tu es)
    local function nearestPlot(pos)
        local plots = Workspace:FindFirstChild("Plots")
        if not plots then return nil end
        local best, bestD = nil, 80 * 80
        for _, plot in ipairs(plots:GetChildren()) do
            local pp
            if plot:IsA("Model") then
                pp = plot.PrimaryPart and plot.PrimaryPart.Position or plot:GetPivot().Position
            elseif plot:IsA("BasePart") then
                pp = plot.Position
            end
            if pp then
                local dx, dz = pos.X - pp.X, pos.Z - pp.Z
                local d2 = dx * dx + dz * dz
                if d2 < bestD then bestD = d2; best = plot end
            end
        end
        return best
    end

    -- timer du 1er etage (le billboard RemainingTime le plus BAS) d un plot
    local function plotTimerText(plot)
        local bestY, bestTxt = math.huge, nil
        for _, g in ipairs(plot:GetDescendants()) do
            if g:IsA("BillboardGui") then
                local rt = g:FindFirstChild("RemainingTime")
                if rt then
                    local base = g.Adornee or g.Parent
                    local y = (base and base:IsA("BasePart")) and base.Position.Y or math.huge
                    if y < bestY then bestY = y; bestTxt = rt.Text end
                end
            end
        end
        return bestTxt
    end

    task.spawn(function()
        while gui.Parent do
            task.wait(0.5)
            -- pause pendant un TP scripte (moment critique pour les FPS)
            if not _G._isTpMoving then
                local char = LP.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                local plot = hrp and nearestPlot(hrp.Position)
                local txt = plot and plotTimerText(plot)
                if txt and txt ~= "" then
                    if label.Text ~= txt then label.Text = txt end
                    if not frame.Visible then frame.Visible = true end
                elseif frame.Visible then
                    frame.Visible = false
                end
            end
        end
    end)
    end)
    if not okBT then warn("[BASE TIMER] BLOC EN ERREUR: " .. tostring(errBT)) end
end)

-- ============================================================
-- ANTI-DIE  (deplace depuis invisible.txt)
-- Le TP arrive a la base en chute/velocity -> fall damage / ragdoll -> mort.
-- On desactive les states mortels ET on revive en boucle. Toujours actif.
-- WHITELIST DU RESET: tout est gate par _G.AntiDieDisabled, que instantReset
-- (plus haut, MEME script) met a true le temps de te respawn, puis restaure.
-- Etant dans le meme fichier que le reset, ce flag est FIABLE (pas de sandbox
-- _G entre scripts) -> le reset passe meme avec l anti-die actif.
-- ============================================================
if _G.AntiDieDisabled == nil then _G.AntiDieDisabled = false end
nowSpawn(function()
local okAD, errAD = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local LP         = Players.LocalPlayer

    local _conn, _diedConn, _hbConn
    local function _harden(hum)
        pcall(function() hum.BreakJointsOnDeath = false end)
        pcall(function() hum.RequiresNeck = false end)
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false) end)
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false) end)
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false) end)
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Physics, false) end)
    end
    local function _revive(hum)
        pcall(function() hum.Health = hum.MaxHealth end)
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
    end
    local function _bind()
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        _harden(hum)
        if _conn then pcall(function() _conn:Disconnect() end) end
        if _diedConn then pcall(function() _diedConn:Disconnect() end) end
        if _hbConn then pcall(function() _hbConn:Disconnect() end) end
        _conn = hum:GetPropertyChangedSignal("Health"):Connect(function()
            if _G.AntiDieDisabled then return end
            if hum.Health <= 0 then _revive(hum) end
        end)
        _diedConn = hum.Died:Connect(function()
            if _G.AntiDieDisabled then return end
            _revive(hum)
        end)
        local _lastHarden = 0
        _hbConn = RunService.Heartbeat:Connect(function()
            if _G.AntiDieDisabled or not hum or not hum.Parent then return end
            local now = os.clock()
            if now - _lastHarden >= 0.5 then _lastHarden = now; _harden(hum) end
            if hum.Health <= 0 then _revive(hum) end
            -- pendant un TP on verrouille la vie au max (preventif, pas curatif)
            if _G.MynxxTPHealLock and hum.Health < hum.MaxHealth then
                pcall(function() hum.Health = hum.MaxHealth end)
            end
            local state = hum:GetState()
            if state == Enum.HumanoidStateType.Dead or state == Enum.HumanoidStateType.Ragdoll
               or state == Enum.HumanoidStateType.FallingDown then
                pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
            end
        end)
    end
    _bind()
    LP.CharacterAdded:Connect(function(char)
        local hum = char:WaitForChild("Humanoid", 5)
        if hum then _harden(hum) end
        task.wait(0.1)
        _bind()
    end)
end)
if not okAD then warn("[ANTI-DIE] BLOC EN ERREUR: " .. tostring(errAD)) end
end)

-- ============================================================
-- DROP BRAINROT (walk-fling, porte 1:1 de mynxx.lua) + KICK (self)
-- Drop Brainrot: fling velocity bref -> le brainrot porte se detache.
-- Kick: game:Shutdown() + LP:Kick("") -> quitte le serveur instantanement.
-- Exposes en globals, appeles par les keybinds G (drop) et Y (kick).
-- ============================================================
stagSpawn(function()
local okDK, errDK = pcall(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local LP         = Players.LocalPlayer

    local _wfConns, _wfActive = {}, false
    local function stopWalkFling()
        _wfActive = false
        for _, c in ipairs(_wfConns) do
            if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
        end
        _wfConns = {}
    end
    local function startWalkFling()
        _wfActive = true
        local ch = LP.Character; if not ch then return end
        local rr = ch:FindFirstChild("HumanoidRootPart")
        -- pendant l invisible steal le vrai root est planque dans la camera
        for _, o in pairs(workspace.CurrentCamera:GetChildren()) do
            if o.Name == "HumanoidRootPart" then rr = o; break end
        end
        if not rr then return end
        table.insert(_wfConns, RunService.Stepped:Connect(function()
            if not _wfActive then return end
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LP and p.Character then
                    for _, pt in ipairs(p.Character:GetChildren()) do
                        if pt:IsA("BasePart") then pt.CanCollide = false end
                    end
                end
            end
        end))
        local co = coroutine.create(function()
            if _G.invisibleStealEnabled then rr.CFrame = rr.CFrame * CFrame.new(0, 3, 0) end
            while _wfActive do
                RunService.Heartbeat:Wait(); if not rr or not rr.Parent then break end
                local v = rr.Velocity; rr.Velocity = v * 10000 + Vector3.new(0, 10000, 0)
                RunService.RenderStepped:Wait(); if rr then rr.Velocity = v end
                RunService.Stepped:Wait(); if rr then rr.Velocity = v + Vector3.new(0, 0.1, 0) end
            end
        end)
        coroutine.resume(co); table.insert(_wfConns, co)
    end

    _G.MynxxDropBrainrot = function()
        if _wfActive then return end
        startWalkFling()
        task.delay(0.4, stopWalkFling)
    end

    _G.MynxxKick = function()
        pcall(function() game:Shutdown() end)
        pcall(function() LP:Kick("") end)
    end
end)
if not okDK then warn("[DROP/KICK] BLOC EN ERREUR: " .. tostring(errDK)) end
end)


-- ============================================================
-- (Config, setToggle, ShowNotification, Workspace, LocalPlayer, SharedState,
-- LPH_NO_VIRTUALIZE macro Luraph -> identite, kickPlayer, CarpetState...).
-- Vole via BodyPosition vers le brainrot "Purchase" le plus proche a portee
-- (_G.MynxxAutoBuyRange) et l achete en boucle (rate-limite = pas de flood/kick).
-- Toggle: _G.MynxxToggleAutoBuy / keybind "K" (Keybind & Actions). OFF par defaut.
-- ============================================================
stagSpawn(function()
local okAB, errAB = pcall(function()
    local Players            = game:GetService("Players")
    local RunService         = game:GetService("RunService")
    local ReplicatedStorage  = game:GetService("ReplicatedStorage")
    local Workspace          = workspace
    local LocalPlayer        = Players.LocalPlayer
    if _G.MynxxAutoBuyRange == nil then _G.MynxxAutoBuyRange = 60 end        -- rayon de LOCK/vol (vers le + proche)
    if _G.MynxxAutoBuyFireRange == nil then _G.MynxxAutoBuyFireRange = 150 end -- rayon d ACHAT (balaye tout le conveyor autour)
    -- SHIM des dependances (tout ce que le bloc verbatim attend)
    local Config = setmetatable({
        AutoBuyEnabled = false, AutoGrabSpeed = 17, AutoKickOnSteal = false, TpSettings = {},
    }, { __index = function(_, k)
        if k == "AutoBuyRange" then return tonumber(_G.MynxxAutoBuyRange) or 60 end
        return nil
    end })
    local function saveConfig() end
    local function setToggle() end
    local function ShowNotification() end
    local SharedState = { ConveyorAnimals = {} }
    local function LPH_NO_VIRTUALIZE(fn) return fn end
    -- Kick apres achat: on prefere le doKick de l AUTO KICK (part en SERVEUR PRIVE
    -- si un code est renseigne), sinon repli sur le kick simple.
    local function kickPlayer()
        if _G.MynxxDoAutoKick then pcall(_G.MynxxDoAutoKick)
        elseif _G.MynxxKick then pcall(_G.MynxxKick) end
    end
    local CarpetState = nil
    local function setCarpetSpeed() end
    local AnimalsData, AnimalsShared, NumberUtils   -- optionnels (getBrainrotName, non appele)

    local toggleAutoBuy
    -- Wrapped in a function (run immediately at the bottom) instead of a bare do-block so
    -- all of auto-buy's locals get their OWN Luau register budget. A bare do-block's locals
    -- count against the main chunk's 200-local limit, which this scope's helpers overflowed
    -- ("Out of local registers"). Behaviour is identical: it still runs synchronously here,
    -- and toggleAutoBuy (declared above) is assigned as an upvalue so the UI sees it.
    local function _initAutoBuyScope() -- AUTO BUY SCOPE (NOT lazy: toggleAutoBuy must exist immediately for the UI)
    local autoBuyActive = false
    -- Auto-buy radius ring removed (user request): no visible ring at all, and one
    -- less per-frame neon part to render. Destroy any stray ring left by older builds.
    pcall(function()
        local e = Workspace:FindFirstChild("XiAutoBuyRing")
        if e then e:Destroy() end
    end)
    
    -- Explicit assignment to the OUTER `local toggleAutoBuy` declared at line ~6899.
    -- Was previously `function toggleAutoBuy(on)` -- syntactic sugar that some
    -- contexts can mis-resolve; this form guarantees we update the outer upvalue
    -- the UI closure at line 8131 captures.
    toggleAutoBuy = function(on)
        if on ~= nil then
            autoBuyActive = on
        else
            autoBuyActive = not autoBuyActive
        end
        Config.AutoBuyEnabled = autoBuyActive
        pcall(saveConfig)
        pcall(setToggle, "Auto Buy", autoBuyActive)
        -- radius ring removed; clean up any stray ring when auto-buy is switched off
        if not autoBuyActive then
            pcall(function() local e = Workspace:FindFirstChild("XiAutoBuyRing"); if e then e:Destroy() end end)
        end
        pcall(ShowNotification, "AUTO BUY", autoBuyActive and "ENABLED" or "DISABLED")
        if _G.AutoBuyOnToggle then
            pcall(_G.AutoBuyOnToggle, autoBuyActive)
        end
    end
    
    local RARITY_WORDS = {
        common = true, uncommon = true, rare = true, epic = true,
        legendary = true, secret = true, divine = true, rainbow = true,
        cursed = true, gold = true, diamond = true,
    }
    
    local function getBrainrotName(model)
        if not model then return "Brainrot", "" end
        local nameFound, genFound = "", ""
        for _, bb in ipairs(model:GetDescendants()) do
            if bb:IsA("BillboardGui") then
                for _, lbl in ipairs(bb:GetDescendants()) do
                    if lbl:IsA("TextLabel") and lbl.Text and lbl.Text ~= "" then
                        local t = lbl.Text:match("^%s*(.-)%s*$")
                        local tl = t:lower()
                        if RARITY_WORDS[tl] then continue end
                        if t:match("^%$[%d%.]+[KkMmBb]?/s$") then
                            if genFound == "" then genFound = t end
                            continue
                        end
                        if t:match("^%$[%d%.]+[KkMmBb]?$") then continue end
                        if t:match("^[%d%.]+[KkMmBb]?$") then continue end
                        if nameFound == "" and #t > 1 then nameFound = t end
                    end
                end
            end
        end
        if nameFound == "" then
            pcall(function()
                local info = AnimalsData[model.Name]
                if info and info.DisplayName then
                    nameFound = info.DisplayName
                    local gv = AnimalsShared:GetGeneration(model.Name, nil, nil, nil)
                    local gt = "$" .. NumberUtils:ToString(gv) .. "/s"
                    genFound = gt
                end
            end)
        end
        if nameFound == "" then nameFound = model.Name ~= "" and model.Name or "Brainrot" end
        return nameFound, genFound
    end
    
    local function scanConveyor()
        -- Only the prompt + its part are needed to auto-buy. The old version ALSO called
        -- getBrainrotName() per prompt (another model:GetDescendants each) and walked up to
        -- 8 ancestors -- pure wasted cost that made this whole-Workspace scan brutal, above
        -- all under Luraph. model = realPart.Parent is a cheap liveness handle for partAlive.
        local results = {}
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if not (obj:IsA("ProximityPrompt") and obj.Enabled) then continue end
            local txt = obj.ActionText or ""
            if not (txt == "Purchase" or txt:lower():find("purchase") or txt:lower():find("comprar")) then continue end
            local part = obj.Parent
            if not part then continue end
            local realPart = (part:IsA("Attachment") and part.Parent) or part
            if not (realPart and realPart:IsA("BasePart")) then continue end
            results[#results + 1] = { prompt = obj, part = realPart, model = realPart.Parent }
        end
        return results
    end
    
    SharedState.ConveyorAnimals = {}
    local function refreshConveyor()
        local ok, found = pcall(scanConveyor)
        if ok and found then
            SharedState.ConveyorAnimals = found
        end
    end
    -- No scan at load: defer the first (expensive) Workspace:GetDescendants scan until
    -- Auto Buy is actually toggled on, so it never adds to startup lag.
    _G.refreshConveyor = refreshConveyor
    
    local purchaseRemote = nil
    local function resolvePurchaseRemote()
        if purchaseRemote and purchaseRemote.Parent then return purchaseRemote end
        pcall(function()
            local net = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Net")
            if not net then return end
            local kws = {"buy", "purchase", "animal", "shop", "acquire", "conveyor"}
            for _, v in ipairs(net:GetChildren()) do
                local nl = (v.Name or ""):lower()
                for _, kw in ipairs(kws) do
                    if nl:find(kw) then
                        purchaseRemote = v
                        return
                    end
                end
            end
        end)
        return purchaseRemote
    end
    
    -- Weak-keyed so destroyed prompts are GC'd (never leaks): rate-limit each prompt and
    -- never stack yielding InvokeServer threads. This keeps buying continuous but BOUNDED
    -- so the per-frame buy loop can't flood the server (which would get you rate-limited
    -- or kicked) or spawn unbounded threads under lag.
    local _lastPurchaseFire = setmetatable({}, {__mode = "k"})
    local _purchaseInFlight = setmetatable({}, {__mode = "k"})
    local PURCHASE_MIN_INTERVAL = 0.03   -- ~33 fires/sec per prompt (faster, still bounded)
    
    local function firePurchaseNatural(prompt)
        if not prompt or not prompt.Parent or not prompt.Enabled then return end
        local now = os.clock()
        local last = _lastPurchaseFire[prompt]
        if last and (now - last) < PURCHASE_MIN_INTERVAL then return end
        _lastPurchaseFire[prompt] = now
        pcall(function()
            if fireproximityprompt then fireproximityprompt(prompt) end
        end)
        -- FIRE DIRECT DU REMOTE D ACHAT: DESACTIVE PAR DEFAUT (anti-detection).
        -- resolvePurchaseRemote scanne Net par mot-cle ("buy"/"purchase"/...) et
        -- tombe sur un remote LEURRE (nom lisible = honeypot du jeu). Firer ce
        -- leurre = DETECTION -> c est ce qui te bannissait apres quelques minutes.
        -- fireproximityprompt (ci-dessus) fire deja le VRAI remote HASHE du prompt,
        -- sans scan par mot-cle -> pas de leurre. On ne fait le fire direct QUE si
        -- tu l actives explicitement (_G.MynxxAutoBuyFireRemote = true), au cas ou
        -- fireproximityprompt seul n achete pas.
        if _G.MynxxAutoBuyFireRemote then
            if _purchaseInFlight[prompt] then return end
            _purchaseInFlight[prompt] = true
            task.spawn(function()
                local remote = resolvePurchaseRemote()
                if remote then
                    pcall(function()
                        if remote:IsA("RemoteFunction") then
                            remote:InvokeServer(prompt.Parent)
                        elseif remote:IsA("RemoteEvent") then
                            remote:FireServer(prompt.Parent)
                        end
                    end)
                end
                _purchaseInFlight[prompt] = nil
            end)
        end
    end
    
    local carpetLockConn = nil
    local _abReturning = false   -- true while flying back to the brainrot after a medusa/knockback
    local FLY_GEAR_NAMES = { "Flying Carpet", "Carpet", "Cloud", "Witch's Broom", "Cupid's Wings", "Santa's Sleigh", "Magic Carpet", "Waverider" }
    local function isCarpetTool(t)
        if not (t and t:IsA("Tool")) then return false end
        local carpetName = (Config.TpSettings and Config.TpSettings.Tool) or ""
        if carpetName ~= "" and t.Name == carpetName then return true end
        local nm = t.Name or ""
        for _, n in ipairs(FLY_GEAR_NAMES) do if nm == n then return true end end
        local nl = nm:lower()
        return nl:find("carpet") ~= nil or nl:find("broom") ~= nil or nl:find("glider") ~= nil or nl:find("wings") ~= nil
    end
    local function unequipCarpet()
        -- Move ONLY the flying gear back to the Backpack (leaving every OTHER tool
        -- equipped) so the player never has the flying gear in hand during normal auto-buy
        -- but can still freely equip / switch / use their own tools. Movement uses the
        -- BodyPosition below, so no tool needs to be held.
        pcall(function()
            local char = LocalPlayer.Character
            local bp = LocalPlayer:FindFirstChild("Backpack")
            if not char or not bp then return end
            for _, t in ipairs(char:GetChildren()) do
                if isCarpetTool(t) then t.Parent = bp end
            end
        end)
    end
    local function equipFlyGear()
        -- Equip whatever fly gear the player owns (carpet/broom/wings/...) so the return
        -- to the brainrot after a medusa/knockback is FLOWN on the gear, not walked.
        pcall(function()
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not char or not hum then return end
            for _, t in ipairs(char:GetChildren()) do if isCarpetTool(t) then return end end  -- already holding one
            local bp = LocalPlayer:FindFirstChild("Backpack")
            if bp then
                for _, t in ipairs(bp:GetChildren()) do
                    if isCarpetTool(t) then hum:EquipTool(t); return end
                end
            end
        end)
    end
    -- Keep the fly gear on by default so the player visibly hovers over the brainrot ON the
    -- gear -- but ONLY re-equip it when the hands are empty, so a tool the player manually
    -- switched to is left alone (they can still swap tools; the gear just comes back if idle).
    local function keepFlyGearIfIdle()
        -- _G.MynxxAutoBuyKeepCarpet == false -> on ne re-equipe JAMAIS le carpet
        -- pendant l auto-buy: le joueur garde/utilise librement ses propres tools.
        -- Le hover sur le brainrot reste assure par le BodyPosition (carpet pas
        -- necessaire en main). Defaut (nil) = comportement d avant (carpet visible).
        if _G.MynxxAutoBuyKeepCarpet == false then return end
        pcall(function()
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not char or not hum then return end
            for _, t in ipairs(char:GetChildren()) do
                if t:IsA("Tool") then return end   -- already holding SOMETHING -> leave it
            end
            local bp = LocalPlayer:FindFirstChild("Backpack")
            if bp then
                for _, t in ipairs(bp:GetChildren()) do
                    if isCarpetTool(t) then hum:EquipTool(t); return end
                end
            end
        end)
    end
    local function startCarpetLock()
        if carpetLockConn then carpetLockConn:Disconnect(); carpetLockConn = nil end
        -- Put the player ON a fly gear (carpet/broom/...) ONCE when a new brainrot is
        -- locked, so they visibly fly over it. We do NOT re-equip it every frame, so the
        -- player can freely switch to any other tool afterwards and it stays switched.
        if _G.MynxxAutoBuyKeepCarpet == false then return end   -- laisser le joueur libre de ses tools
        equipFlyGear()
    end
    
    local function stopCarpetLock()
        if carpetLockConn then carpetLockConn:Disconnect(); carpetLockConn = nil end
    end
    
    local HOVER_HEIGHT = 6.0   -- studs to float ABOVE the WHOLE brainrot model (see _abTopOff)
    local BUY_INTERVAL = 0.03
    local DETECT_RADIUS = 17
    local lockedTarget = nil
    local lockedPart = nil
    local lockedModel = nil
    local _lockedBuyFired = false  -- true once we've fired a purchase at the current locked target
    local _abTopOff = 2            -- (part center -> TOP of the whole brainrot model), set per lock
    local _lastAbove = nil        -- last hover target, held briefly across a buy->relock gap
    local _lastTargetTime = 0

    local function partAlive()
        return lockedPart and lockedPart.Parent and lockedModel and lockedModel.Parent
    end
    
    local function promptAlive()
        return lockedTarget and lockedTarget.prompt and lockedTarget.prompt.Parent and lockedTarget.prompt.Enabled
    end
    
    local bodyPos = nil
    local function ensureBodyPos(hrp)
        -- CRITICALLY DAMPED BodyPosition: P scales with the speed slider (fast approach),
        -- D = 2*sqrt(P*mass) so it settles onto the target with NO overshoot -> it can't
        -- oscillate, fling, or launch the character through the map ("ohne dass es kaputt
        -- geht"), and it sticks rock-steady on the brainrot (constant). Physics/BodyPosition
        -- keeps the client as network owner, so movement replicates smoothly (no rubber-band
        -- like a hard per-frame CFrame set would risk).
        local speed = math.clamp(Config.AutoGrabSpeed or 17, 5, 100)
        -- FIRM hold at hover height so the player stays OVER the brainrot and does NOT drift
        -- away ("nicht weg"). It's not "gluing" -- the height (HOVER_HEIGHT) keeps it a clear
        -- fly-over ABOVE the brainrot rather than stuck on it.
        local P = 8000 + speed * 300
        local mass = hrp.AssemblyMass
        if not mass or mass <= 0 then mass = 14 end
        local D = 2 * math.sqrt(P * mass)
        -- Finite, mass-scaled MaxForce: even with the speed maxed out via config, the
        -- single-frame impulse can never get big enough to tunnel/launch the character
        -- through map geometry. Default speed behavior is completely unaffected.
        local maxF = mass * 60000
        if bodyPos and bodyPos.Parent == hrp then
            bodyPos.MaxForce = Vector3.new(maxF, maxF, maxF)
            bodyPos.P = P
            bodyPos.D = D
            return bodyPos
        end
        if bodyPos then bodyPos:Destroy() end
        local bp = Instance.new("BodyPosition")
        bp.MaxForce = Vector3.new(maxF, maxF, maxF)
        bp.P = P
        bp.D = D
        bp.Position = hrp.Position
        bp.Parent = hrp
        bodyPos = bp
        return bp
    end
    
    local function destroyBodyPos()
        if bodyPos then bodyPos:Destroy(); bodyPos = nil end
    end
    
    local RETURN_SPEED = 220
    RunService.PreSimulation:Connect(LPH_NO_VIRTUALIZE(function()
        if not autoBuyActive then
            destroyBodyPos()
            _abReturning = false
            return
        end
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp then destroyBodyPos(); return end
        -- Medusa / boogie / knockback can anchor, ragdoll or platform-stand you; clear it
        -- every frame so nothing can pin you away from the brainrot.
        if hrp.Anchored then hrp.Anchored = false end
        if hum then
            if hum.PlatformStand then hum.PlatformStand = false end
            local st = hum:GetState()
            if st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.Physics then
                pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
            end
        end
        if not partAlive() then
            -- The locked brainrot just got bought (or lost). DON'T drop -- keep FLOATING at the
            -- last hover spot for a short grace so we don't fall off before the NEXT brainrot is
            -- locked (fixes "nach einem kauf klebt es manchmal nicht am brainrot").
            if _lastAbove and (os.clock() - _lastTargetTime) < 0.7 then
                local bp = ensureBodyPos(hrp)
                bp.Position = _lastAbove
                local lv = hrp.AssemblyLinearVelocity
                if lv.Magnitude > 250 then hrp.AssemblyLinearVelocity = lv.Unit * 250 end
            else
                destroyBodyPos()
            end
            _abReturning = false
            return
        end
        -- Float clearly ABOVE the WHOLE brainrot model (on the carpet, like the reference
        -- image) instead of on the small prompt part -- so the body never hangs INSIDE a tall
        -- brainrot. _abTopOff is the part-center -> model-top offset captured at lock time.
        local above = Vector3.new(lockedPart.Position.X, lockedPart.Position.Y + _abTopOff + HOVER_HEIGHT, lockedPart.Position.Z)
        _lastAbove = above
        _lastTargetTime = os.clock()
        local dist = (hrp.Position - above).Magnitude
        -- Hysteresis: once knocked >30 studs off (medusa/boogie/hit), fly back on the
        -- gear until within 10 studs, then resume sticking. Normal locks are <=17 studs
        -- so this NEVER triggers during ordinary approach.
        if _abReturning then
            if dist < 10 then _abReturning = false end
        elseif dist > 30 then
            _abReturning = true
        end
        if _abReturning then
            -- Flew off: equip the fly gear the player has and rocket straight back.
            destroyBodyPos()
            equipFlyGear()
            local d = above - hrp.Position
            if d.Magnitude > 0.1 then hrp.AssemblyLinearVelocity = d.Unit * RETURN_SPEED end
            hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
        else
            -- Gentle hover ABOVE the brainrot on the fly gear: soft hold, no spin-lock, so
            -- it does NOT glue/pin the player -- they float, can drift and switch tools,
            -- while staying in buy range.
            local bp = ensureBodyPos(hrp)
            bp.Position = above
            local lv = hrp.AssemblyLinearVelocity
            if lv.Magnitude > 250 then hrp.AssemblyLinearVelocity = lv.Unit * 250 end
        end
    end))
    
    task.spawn(LPH_NO_VIRTUALIZE(function()
        while true do
            if not autoBuyActive then task.wait(0.05); continue end
            -- On n achete QUE le brainrot VERROUILLE (celui sur lequel on hover).
            -- Le balayage "achete tout le conveyor dans le rayon" a ete retire a la
            -- demande: plus d achat massif, on ne prend que la cible courante.
            if promptAlive() then firePurchaseNatural(lockedTarget.prompt); _lockedBuyFired = true end
            RunService.Heartbeat:Wait()
        end
    end))
    
    local _lastConveyorScan = 0
    task.spawn(function()
        while true do
            task.wait(0.1)
            if not autoBuyActive then
                lockedTarget = nil
                lockedPart = nil
                lockedModel = nil
                _lockedBuyFired = false
                stopCarpetLock()
                destroyBodyPos()
                continue
            end
            -- Keep the fly gear on (only when idle, so manual tool switches are respected).
            keepFlyGearIfIdle()
            if lockedPart or lockedModel then
                if partAlive() then
                    continue   -- still on the current brainrot -- keep buying / hovering
                end
                -- Our locked brainrot vanished from the conveyor while we were firing purchases
                -- at it => WE bought it (it's now in our base). Auto-kick then, exactly as the
                -- user wants. Reliable at the conveyor (always rendered) and never false-fires
                -- on join, unlike watching the base brainrot count.
                -- Notre brainrot verrouille a quitte le tapis (achete). L AUTO KICK
                -- apres achat a ete RETIRE a la demande: l Auto Buy ne kick JAMAIS.
                -- On nettoie juste l etat et on re-lock le prochain.
                pcall(refreshConveyor)
                _lastConveyorScan = os.clock()   -- we just scanned, don't double-scan below
                lockedTarget = nil
                lockedPart = nil
                lockedModel = nil
                _lockedBuyFired = false
                -- Fall THROUGH to re-lock the next brainrot in THIS same iteration -- no 0.1s
                -- gap where the character would drop off before the next target locks.
            end
            -- Throttle the (whole-Workspace) rescan: 0.1s was far too frequent and is the
            -- main Auto-Buy lag source, especially under Luraph. ~3 scans/sec is plenty to
            -- pick up newly-spawned conveyor brainrots.
            if os.clock() - _lastConveyorScan > 0.35 then
                _lastConveyorScan = os.clock()
                pcall(refreshConveyor)
            end
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then continue end
            local radius = Config.AutoBuyRange or DETECT_RADIUS
            local best, bestDist = nil, math.huge
            for _, entry in ipairs(SharedState.ConveyorAnimals) do
                if entry.prompt and entry.prompt.Parent and entry.prompt.Enabled and entry.part and entry.part.Parent then
                    local d = (hrp.Position - entry.part.Position).Magnitude
                    if d <= radius and d < bestDist then
                        bestDist = d
                        best = entry
                    end
                end
            end
            if best then
                lockedTarget = best
                lockedPart = best.part
                lockedModel = best.model or best.part.Parent
                _lockedBuyFired = false
                -- Measure to the TOP of the whole brainrot MODEL, not just the small prompt part
                -- (best.model is only the immediate parent, so the hover was landing INSIDE a
                -- tall brainrot -> "im brainrot"). Walk up to the first real Model and use its
                -- full bounding box; clamp so a giant container can't fling us to the sky.
                _abTopOff = math.max(lockedPart.Size.Y * 0.5, 3)
                pcall(function()
                    local m = lockedPart
                    for _ = 1, 6 do
                        if m and m:IsA("Model") then break end
                        m = m and m.Parent
                    end
                    if m and m:IsA("Model") then
                        local cf, size = m:GetBoundingBox()
                        local off = (cf.Position.Y + size.Y * 0.5) - lockedPart.Position.Y
                        if off > _abTopOff then _abTopOff = off end
                    end
                end)
                if _abTopOff > 14 then _abTopOff = 14 end
                ShowNotification("AUTO BUY", "Locked")
                startCarpetLock()
            end
        end
    end)
    
    _G.AutoBuyOnToggle = function(active)
        if active then
            if _G.refreshConveyor then pcall(_G.refreshConveyor) end
            -- Auto-buy moves via BodyPosition; switch Carpet Speed off so its per-frame
            -- force-equip doesn't fight the carpet unequip (flicker) or the movement.
            if CarpetState and CarpetState.enabled then pcall(setCarpetSpeed, false) end
            startCarpetLock()
        else
            stopCarpetLock()
            destroyBodyPos()
        end
    end
    end
    _initAutoBuyScope() -- END AUTO BUY SCOPE (run immediately, exactly like the old do-block)

    -- expose pour le keybind "K" + suivi de l etat dans _G.MynxxAutoBuy
    _G.MynxxToggleAutoBuy = function() if toggleAutoBuy then pcall(toggleAutoBuy) end end
    _G.MynxxSetAutoBuy    = function(on) if toggleAutoBuy then pcall(toggleAutoBuy, on) end end
    local _origOnToggle = _G.AutoBuyOnToggle
    _G.AutoBuyOnToggle = function(active)
        _G.MynxxAutoBuy = active and true or false
        if _origOnToggle then pcall(_origOnToggle, active) end
    end
end)
if not okAB then warn("[AUTOBUY] BLOC EN ERREUR: " .. tostring(errAB)) end
end)

-- ============================================================
-- FLASHER (ex "Face Away")
-- Fait toujours regarder le perso a l OPPOSE d une cible (base owner /
-- nearest / joueur choisi / click-to-face). Meme logique que faceaway.txt,
-- GUI restyle au theme du hub (cadre noir opaque + boutons verts ON/OFF,
-- comme INVIS STEAL). Options identiques a l original, customisables ensuite.
-- Differe comme les autres via stagSpawn ; config/pos dans MynxxHub.json.
-- Touches: F = toggle (Q est deja pris par Carpet Speed), RightShift = cacher.
-- ============================================================
stagSpawn(function()
local okFL, errFL = pcall(function()
    local Players          = game:GetService("Players")
    local RunService       = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local TweenService     = game:GetService("TweenService")

    local localPlayer = Players.LocalPlayer
    local playerGui   = localPlayer:WaitForChild("PlayerGui", 30)
    if not playerGui then return end

    if _G._FlasherLoaded then return end
    _G._FlasherLoaded = true

    --=== CONFIG ===============================================================
    local TOGGLE_KEY   = nil                      -- toggle via le menu "Keybind & Actions" (bind Face Away, defaut F)
    local UI_KEY       = Enum.KeyCode.RightShift  -- affiche/cache le panneau
    local TURN_SPEED   = 0                         -- 0 = snap instantane
    local CLICK_RADIUS = 120                       -- px pour le click-to-face

    --=== CONFIG PANEL (fichier partage MynxxHub.json) =========================
    local cfg    = _G.HubCfg.get("flasher")
    local panelX = tonumber(cfg.panelX) or 460
    local panelY = tonumber(cfg.panelY) or 120
    local function saveCfg()
        cfg.panelX = panelX; cfg.panelY = panelY
        _G.HubCfg.save()
    end

    --=== STATE ================================================================
    local enabled          = false
    local selectedPlayer   = nil
    local useNearest       = false
    local useBaseOwner     = true
    local clickFaceTarget  = nil
    local clickFaceEnabled = false
    local searchText       = ""
    local rowButtons       = {}

    --=== THEME (hub) ==========================================================
    local FRAME_BG = Color3.fromRGB(12, 12, 12)
    local ROW      = Color3.fromRGB(35, 35, 35)
    local GREEN    = Color3.fromRGB(200, 60, 130)
    local GREY     = Color3.fromRGB(45, 45, 45)
    local ACCENT   = Color3.fromRGB(88, 140, 255)
    local TEXT     = Color3.fromRGB(235, 235, 240)
    local SUBTEXT  = Color3.fromRGB(150, 150, 160)

    local function corner(parent, r)
        Instance.new("UICorner", parent).CornerRadius = UDim.new(0, r or 6)
    end
    local function pad(parent, px)
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, px); p.PaddingRight  = UDim.new(0, px)
        p.PaddingTop  = UDim.new(0, px); p.PaddingBottom = UDim.new(0, px)
        p.Parent = parent
    end

    --=== BASE OWNER HELPERS (identiques a l original) =========================
    local function getPlotAtPosition(pos)
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return nil end
        local best, bestDist = nil, math.huge
        for _, plot in ipairs(plots:GetChildren()) do
            local pp
            if plot:IsA("Model") then
                pp = (plot.PrimaryPart and plot.PrimaryPart.Position) or plot:GetPivot().Position
            else
                pp = plot.Position
            end
            if pp then
                local d = math.sqrt((pos.X - pp.X)^2 + (pos.Z - pp.Z)^2)
                if d < bestDist then bestDist = d; best = plot end
            end
        end
        return (best and bestDist < 72) and best or nil
    end

    local function getPlotOwner(plot)
        if not plot then return nil end
        local sign = plot:FindFirstChild("PlotSign")
        local lbl  = sign
            and sign:FindFirstChild("SurfaceGui")
            and sign.SurfaceGui:FindFirstChild("Frame")
            and sign.SurfaceGui.Frame:FindFirstChild("TextLabel")
        if lbl then
            local nick = (lbl.Text and lbl.Text:match("^(.-)'")) or lbl.Text
            if nick and nick ~= "" then
                for _, p in ipairs(Players:GetPlayers()) do
                    if p.DisplayName == nick or p.Name == nick then return p end
                end
            end
        end
        return nil
    end

    local function resolveBaseOwner()
        local char = localPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return nil end
        local owner = getPlotOwner(getPlotAtPosition(hrp.Position))
        return (owner ~= localPlayer) and owner or nil
    end

    local function getRoot(player)
        local c = player and player.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end

    local function findNearest(myRoot)
        local closest, closestDist = nil, math.huge
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= localPlayer then
                local root = getRoot(player)
                if root then
                    local dist = (root.Position - myRoot.Position).Magnitude
                    if dist < closestDist then closest, closestDist = player, dist end
                end
            end
        end
        return closest
    end

    --=== GUI (theme hub: cadre noir + boutons verts ON/OFF) ===================
    local guiParent = (gethui and gethui()) or game:GetService("CoreGui") or playerGui
    pcall(function()
        local old = guiParent:FindFirstChild("FlasherUI")
        if old then old:Destroy() end
    end)
    local gui = Instance.new("ScreenGui")
    gui.Name = "FlasherUI"; gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 131
    pcall(function() gui.Parent = guiParent end)
    if not gui.Parent then gui.Parent = playerGui end

    local main = Instance.new("Frame", gui)
    main.Name = "Main"
    main.Size = UDim2.fromOffset(210, 176)
    main.Position = UDim2.fromOffset(panelX, panelY)
    main.BackgroundColor3 = FRAME_BG
    main.BorderSizePixel = 0; main.Active = true; main.Draggable = true
    corner(main, 8)
    do
        local pending = false
        main:GetPropertyChangedSignal("Position"):Connect(function()
            if pending then return end
            pending = true
            task.delay(0.5, function()
                pending = false
                panelX, panelY = main.AbsolutePosition.X, main.AbsolutePosition.Y
                saveCfg()
            end)
        end)
    end

    local titleLbl = Instance.new("TextLabel", main)
    titleLbl.Size = UDim2.new(1, 0, 0, 24); titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBlack; titleLbl.Text = "Face Away"
    titleLbl.TextSize = 12; titleLbl.TextColor3 = TEXT

    -- forward decls (les handlers appellent ces fonctions avant leur definition)
    local updateStatus, refreshHighlight, rebuildList, updateHighlight, pulseHighlight

    -- bouton toggle plein-largeur "LABEL: ON/OFF" (vert/gris) -- look INVIS STEAL
    local ups = {}
    local function mkToggle(y, label, get, set)
        local b = Instance.new("TextButton", main)
        b.Size = UDim2.new(1, -16, 0, 24); b.Position = UDim2.fromOffset(8, y)
        b.Font = Enum.Font.GothamBold; b.TextSize = 11
        b.TextColor3 = TEXT; b.BorderSizePixel = 0; b.AutoButtonColor = true
        corner(b, 5)
        local function up()
            local on = get()
            b.Text = label .. (on and ": ON" or ": OFF")
            b.BackgroundColor3 = on and GREEN or GREY
        end
        b.MouseButton1Click:Connect(function() set(); up() end)
        up(); ups[#ups + 1] = up
        return b
    end
    local function refreshToggles() for _, u in ipairs(ups) do pcall(u) end end

    local function setEnabled(state)
        enabled = state
        _G.MynxxFaceAwayOn = enabled
        local char = localPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate = not enabled end
        refreshToggles()
        if updateStatus then updateStatus() end
    end
    -- expose pour le keybind "Face Away" du menu Keybind & Actions (bloc carpet)
    _G.MynxxToggleFaceAway = function() setEnabled(not enabled) end

    local function setClickFace(state)
        clickFaceEnabled = state
        if not state then
            clickFaceTarget = nil
            if refreshHighlight then refreshHighlight() end
            if updateStatus then updateStatus() end
        end
        refreshToggles()
    end

    -- rang de boutons (main toggle + modes de ciblage)
    mkToggle(30, "Face Away",
        function() return enabled end,
        function() setEnabled(not enabled) end)

    mkToggle(58, "BASE OWNER",
        function() return useBaseOwner end,
        function()
            clickFaceTarget = nil
            useBaseOwner = true; useNearest = false; selectedPlayer = nil
            refreshToggles()
            if refreshHighlight then refreshHighlight() end
            if updateStatus then updateStatus() end
        end)

    mkToggle(86, "NEAREST",
        function() return useNearest end,
        function()
            clickFaceTarget = nil
            useBaseOwner = false; useNearest = true; selectedPlayer = nil
            refreshToggles()
            if refreshHighlight then refreshHighlight() end
            if updateStatus then updateStatus() end
        end)

    mkToggle(114, "CLICK-TO-FACE",
        function() return clickFaceEnabled end,
        function() setClickFace(not clickFaceEnabled) end)

    -- (Search bar + players list retires : ciblage via BASE OWNER / NEAREST /
    --  CLICK-TO-FACE uniquement.)

    local status = Instance.new("TextLabel", main)
    status.Size = UDim2.new(1, -16, 0, 24); status.Position = UDim2.new(0, 8, 1, -30)
    status.BackgroundTransparency = 1; status.Font = Enum.Font.Gotham
    status.TextSize = 11; status.TextColor3 = SUBTEXT
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextTruncate = Enum.TextTruncate.AtEnd

    --=== BEHAVIOUR ============================================================
    function updateStatus()
        if clickFaceTarget and clickFaceTarget.Parent then
            status.Text = "Target: " .. clickFaceTarget.DisplayName .. " (click)"
        elseif useBaseOwner then
            local owner = resolveBaseOwner()
            status.Text = owner
                and ("Target: base owner (" .. owner.DisplayName .. ")")
                or  "Target: base owner (searching...)"
        elseif useNearest then
            local myRoot  = getRoot(localPlayer)
            local nearest = myRoot and findNearest(myRoot)
            status.Text = nearest
                and ("Target: nearest (" .. nearest.DisplayName .. ")")
                or  "Target: nearest player"
        elseif selectedPlayer and selectedPlayer.Parent then
            status.Text = "Target: " .. selectedPlayer.DisplayName .. " (@" .. selectedPlayer.Name .. ")"
        else
            status.Text = "Target: none"
        end
    end

    function refreshHighlight()
        for key, button in pairs(rowButtons) do
            local sel = (not useNearest and not useBaseOwner and not clickFaceTarget
                and key == selectedPlayer)
            button.BackgroundColor3 = sel and GREEN or ROW
        end
    end

    -- Liste des joueurs retiree : rebuildList est un no-op (conserve car les
    -- connexions PlayerAdded / PlayerRemoving et l INIT l appellent encore).
    function rebuildList()
        refreshHighlight()
    end

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == TOGGLE_KEY then setEnabled(not enabled)
        elseif input.KeyCode == UI_KEY  then main.Visible = not main.Visible end
    end)

    Players.PlayerAdded:Connect(function() task.defer(rebuildList) end)
    Players.PlayerRemoving:Connect(function(player)
        if player == selectedPlayer then selectedPlayer = nil; useBaseOwner = true end
        if player == clickFaceTarget then clickFaceTarget = nil end
        task.defer(rebuildList); task.defer(updateStatus)
    end)

    localPlayer.CharacterAdded:Connect(function()
        task.wait(0.2); setEnabled(enabled)
    end)

    --=== AUTO-ON PENDANT LE STEAL (comportement d origine) ====================
    task.spawn(function()
        local wasStealing, autoEnabled = false, false
        task.wait(1)
        while task.wait(0.15) do
            local isStealing = localPlayer:GetAttribute("Stealing")
            if isStealing and not wasStealing and not enabled then
                task.spawn(function()
                    task.wait(0.5)
                    if localPlayer:GetAttribute("Stealing") and not enabled then
                        setEnabled(true); autoEnabled = true
                    end
                end)
            end
            if not isStealing and autoEnabled and enabled then
                task.spawn(function()
                    task.wait(0.3)
                    if not localPlayer:GetAttribute("Stealing") and autoEnabled then
                        setEnabled(false); autoEnabled = false
                    end
                end)
            end
            wasStealing = isStealing
        end
    end)

    task.spawn(function()
        while task.wait(1) do
            if useBaseOwner or useNearest or clickFaceTarget then updateStatus() end
        end
    end)

    --=== HIGHLIGHT DE LA CIBLE ================================================
    local CLICK_COLOR = Color3.fromRGB(255, 170, 60)
    local targetHighlight = Instance.new("Highlight")
    targetHighlight.Name                = "FlasherTargetHighlight"
    targetHighlight.FillTransparency    = 0.6
    targetHighlight.OutlineTransparency = 0
    targetHighlight.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    targetHighlight.Enabled             = false
    targetHighlight.Parent              = gui

    function updateHighlight(targetPlayer)
        local char = targetPlayer and targetPlayer.Character
        if char and (enabled or clickFaceTarget) then
            local color = (targetPlayer == clickFaceTarget) and CLICK_COLOR or ACCENT
            if targetHighlight.Adornee ~= char then targetHighlight.Adornee = char end
            targetHighlight.FillColor    = color
            targetHighlight.OutlineColor = color
            targetHighlight.Enabled      = true
        else
            targetHighlight.Enabled = false
            targetHighlight.Adornee = nil
        end
    end

    function pulseHighlight()
        targetHighlight.FillTransparency = 0.05
        TweenService:Create(targetHighlight,
            TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { FillTransparency = 0.6 }):Play()
    end

    --=== CLICK-TO-FACE (clic droit sur un joueur) =============================
    local function playerAtCursor()
        local camera = workspace.CurrentCamera
        if not camera then return nil end
        local mousePos = UserInputService:GetMouseLocation()
        local best, bestDist = nil, CLICK_RADIUS
        for _, player in ipairs(Players:GetPlayers()) do
            local char = player ~= localPlayer and player.Character
            if char then
                for _, partName in ipairs({ "HumanoidRootPart", "Head" }) do
                    local part = char:FindFirstChild(partName)
                    if part then
                        local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
                        if onScreen then
                            local d = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
                            if d < bestDist then best, bestDist = player, d end
                        end
                    end
                end
            end
        end
        return best
    end

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if not clickFaceEnabled then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
        local hitPlayer = playerAtCursor()
        if not hitPlayer then return end
        if clickFaceTarget == hitPlayer then
            clickFaceTarget = nil
        else
            clickFaceTarget = hitPlayer
            updateHighlight(clickFaceTarget)
            pulseHighlight()
        end
        refreshHighlight()
        updateStatus()
    end)

    --=== FACING LOGIC =========================================================
    local function resolveTarget(myRoot)
        if clickFaceTarget and clickFaceTarget.Parent then return clickFaceTarget end
        if useBaseOwner then return resolveBaseOwner() end
        if not useNearest then return selectedPlayer end
        return findNearest(myRoot)
    end

    local function flasherStep(dt)
        local myRoot = getRoot(localPlayer)
        local target = myRoot and resolveTarget(myRoot) or clickFaceTarget
        updateHighlight(target)
        if not enabled or not myRoot then return end

        local char = localPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.AutoRotate then hum.AutoRotate = false end

        local targetRoot = getRoot(target)
        if not targetRoot then return end

        local flat = Vector3.new(
            targetRoot.Position.X - myRoot.Position.X,
            0,
            targetRoot.Position.Z - myRoot.Position.Z
        )
        if flat.Magnitude < 0.05 then return end

        local goal = CFrame.lookAt(myRoot.Position, myRoot.Position - flat.Unit)
        if TURN_SPEED <= 0 then
            myRoot.CFrame = goal
        else
            myRoot.CFrame = myRoot.CFrame:Lerp(goal, 1 - math.exp(-TURN_SPEED * dt))
        end

        local av = myRoot.AssemblyAngularVelocity
        if av.Y ~= 0 then
            myRoot.AssemblyAngularVelocity = Vector3.new(av.X, 0, av.Z)
        end
    end

    RunService.RenderStepped:Connect(flasherStep)
    RunService.Heartbeat:Connect(flasherStep)

    --=== INIT =================================================================
    rebuildList()
    updateStatus()
    setEnabled(false)
end)
if not okFL then warn("[FLASHER] BLOC EN ERREUR: " .. tostring(errFL)) end
end)
