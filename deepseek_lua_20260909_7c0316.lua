-- ============================================================
-- RUSTYHUB HOPPER + GUI + COUNTDOWN (20s, New Webhook)
-- ============================================================

local http = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

-- 🔴 YOUR NEW WEBHOOK
local WEBHOOK_URL = "https://discord.com/api/webhooks/1544873313531330561/NN2IFxAuQ8rcV4gVLj08ZOuEqBF3WFTLkp8T6vgrre5texODzpSp9-7Ch1uGFpZm1EPm"

-- ⚙️ Settings
local MINIMUM_MPS = 30000000        -- 30 million
local HOP_INTERVAL = 20             -- 20 seconds

-- ============================================================
-- CREATE THE GUI
-- ============================================================
local function createGUI()
    local player = Players.LocalPlayer
    local pg = player:WaitForChild("PlayerGui")

    local old = pg:FindFirstChild("RustyhubGUI")
    if old then old:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name = "RustyhubGUI"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.Parent = pg

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 260, 0, 150)
    frame.Position = UDim2.new(0, 10, 0, 10)
    frame.BackgroundColor3 = Color3.fromRGB(12, 0, 18)
    frame.BorderSizePixel = 0
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    frame.Parent = sg

    -- Title (draggable)
    local title = Instance.new("TextButton")
    title.Size = UDim2.new(1, 0, 0, 30)
    title.BackgroundTransparency = 1
    title.Text = "✨ Rustyhub"
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 16
    title.TextColor3 = Color3.fromRGB(180, 80, 255)
    title.AutoButtonColor = false
    title.Active = true
    title.Parent = frame

    -- Make draggable
    local drag = { active = false, startX = 0, startY = 0, startPosX = 0, startPosY = 0 }
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            drag.active = true
            drag.startX = input.Position.X
            drag.startY = input.Position.Y
            drag.startPosX = frame.Position.X.Offset
            drag.startPosY = frame.Position.Y.Offset
        end
    end)
    title.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            drag.active = false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if drag.active and input.UserInputType == Enum.UserInputType.MouseMovement then
            local deltaX = input.Position.X - drag.startX
            local deltaY = input.Position.Y - drag.startY
            frame.Position = UDim2.fromOffset(drag.startPosX + deltaX, drag.startPosY + deltaY)
        end
    end)

    -- Status labels
    local labels = {}
    local labelConfigs = {
        { name = "Status", text = "● Running", color = Color3.fromRGB(100, 255, 100) },
        { name = "Pets", text = "Pets ≥30M: 0" },
        { name = "Countdown", text = "Next hop in: --s" },
        { name = "LastScan", text = "Last scan: --:--:--" },
    }

    for i, cfg in ipairs(labelConfigs) do
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -20, 0, 24)
        lbl.Position = UDim2.new(0, 10, 0, 30 + (i-1)*26)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 13
        lbl.TextColor3 = cfg.color or Color3.fromRGB(220, 220, 220)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Text = cfg.text
        lbl.Parent = frame
        labels[cfg.name] = lbl
    end

    -- Rejoin button inside GUI
    local rejoinBtn = Instance.new("TextButton")
    rejoinBtn.Size = UDim2.new(0, 80, 0, 28)
    rejoinBtn.Position = UDim2.new(1, -90, 1, -36)
    rejoinBtn.BackgroundColor3 = Color3.fromRGB(110, 0, 200)
    rejoinBtn.TextColor3 = Color3.new(1, 1, 1)
    rejoinBtn.Text = "⟳ Rejoin"
    rejoinBtn.Font = Enum.Font.GothamBold
    rejoinBtn.TextSize = 14
    rejoinBtn.BorderSizePixel = 0
    Instance.new("UICorner", rejoinBtn).CornerRadius = UDim.new(0, 8)
    rejoinBtn.Parent = frame

    rejoinBtn.MouseButton1Click:Connect(function()
        rejoinBtn.Text = "⏳..."
        rejoinBtn.BackgroundColor3 = Color3.fromRGB(200, 100, 0)
        task.spawn(function()
            serverHop()
        end)
    end)

    return labels, rejoinBtn
end

local guiLabels, guiRejoinBtn

-- ============================================================
-- UPDATE GUI FUNCTION
-- ============================================================
local function updateGUI(status, petsFound, countdown, lastScan)
    if not guiLabels then return end
    guiLabels.Status.Text = status and "● Running" or "● Stopped"
    guiLabels.Pets.Text = "Pets ≥30M: " .. (petsFound or 0)
    guiLabels.Countdown.Text = "Next hop in: " .. (countdown or 0) .. "s"
    guiLabels.LastScan.Text = "Last scan: " .. (lastScan or os.date("%H:%M:%S"))
end

-- ============================================================
-- Helper: Format MPS
-- ============================================================
local function formatMPS(mps)
    if mps >= 1e12 then return string.format("%.2fT/s", mps/1e12) end
    if mps >= 1e9  then return string.format("%.2fB/s", mps/1e9)  end
    if mps >= 1e6  then return string.format("%.2fM/s", mps/1e6)  end
    if mps >= 1e3  then return string.format("%.2fK/s", mps/1e3)  end
    return string.format("%.0f/s", mps)
end

-- ============================================================
-- Send to Discord
-- ============================================================
local function sendToDiscord(content, embed)
    local data = { content = content or "", embeds = embed and {embed} or {} }
    local json = http:JSONEncode(data)
    local headers = { ["Content-Type"] = "application/json" }
    pcall(function()
        request({ Url = WEBHOOK_URL, Method = "POST", Headers = headers, Body = json })
    end)
end

-- ============================================================
-- Scan ALL plots for pets ≥30M/s
-- ============================================================
local function getAllPets()
    local pets = {}
    local ok, AnimalsData = pcall(function()
        return require(game:GetService("ReplicatedStorage"):WaitForChild("Datas"):WaitForChild("Animals"))
    end)
    if not ok then return pets end

    local Plots = workspace:FindFirstChild("Plots")
    if not Plots then return pets end

    for _, plot in ipairs(Plots:GetChildren()) do
        local channel = nil
        if _G.MynxxSyncGet then
            channel = _G.MynxxSyncGet(plot.Name)
        end
        if not channel and type(getgc) == "function" then
            local Pkgs = game:GetService("ReplicatedStorage"):FindFirstChild("Packages")
            local Sync = Pkgs and Pkgs:FindFirstChild("Synchronizer")
            if Sync then
                local okMod, mod = pcall(require, Sync)
                if okMod and type(mod) == "table" then
                    local Channel = mod and mod.Channel
                    if Channel then
                        local gc = getgc(true)
                        for _, v in ipairs(gc) do
                            if type(v) == "table" and getmetatable(v) == Channel then
                                local idx = rawget(v, "Index")
                                if idx == plot.Name then
                                    channel = v
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if channel then
            local ct = rawget(channel, "CacheTable")
            if ct and ct.AnimalList then
                for slot, animalData in pairs(ct.AnimalList) do
                    if type(animalData) == "table" then
                        local name = animalData.Index
                        if name then
                            local info = AnimalsData[name]
                            if info and info.Generation then
                                local mps = info.Generation
                                local mutation = animalData.Mutation or "None"

                                if mutation ~= "None" then
                                    local okMut, MutData = pcall(function()
                                        return require(game:GetService("ReplicatedStorage"):WaitForChild("Datas"):WaitForChild("Mutations"))
                                    end)
                                    if okMut then
                                        local m = MutData[mutation]
                                        if m and m.Modifier then
                                            mps = mps * (1 + m.Modifier)
                                        end
                                    end
                                end

                                if animalData.Traits and type(animalData.Traits) == "table" then
                                    local okTr, TraitsData = pcall(function()
                                        return require(game:GetService("ReplicatedStorage"):WaitForChild("Datas"):WaitForChild("Traits"))
                                    end)
                                    if okTr then
                                        for _, tr in ipairs(animalData.Traits) do
                                            local t = TraitsData[tr]
                                            if t and t.MultiplierModifier then
                                                mps = mps * (1 + t.MultiplierModifier)
                                            end
                                        end
                                    end
                                end

                                if mps >= MINIMUM_MPS then
                                    local ownerName = "Unknown"
                                    if ct.Owner then
                                        if type(ct.Owner) == "string" then
                                            ownerName = ct.Owner
                                        elseif type(ct.Owner) == "number" then
                                            local plr = Players:GetPlayerByUserId(ct.Owner)
                                            ownerName = plr and plr.Name or tostring(ct.Owner)
                                        elseif typeof(ct.Owner) == "Instance" and ct.Owner:IsA("Player") then
                                            ownerName = ct.Owner.Name
                                        end
                                    end
                                    table.insert(pets, {
                                        name = info.DisplayName or name,
                                        mps = mps,
                                        mutation = mutation,
                                        plot = plot.Name,
                                        slot = slot,
                                        owner = ownerName
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(pets, function(a, b) return a.mps > b.mps end)
    return pets
end

-- ============================================================
-- Build join link
-- ============================================================
local function buildJoinLink(jobId)
    return "https://www.roblox.com/games/start?placeId=" .. game.PlaceId .. "&gameInstanceId=" .. jobId
end

-- ============================================================
-- Send webhook
-- ============================================================
local function sendWebhook()
    local jobId = game.JobId
    local pets = getAllPets()
    local petCount = #pets
    updateGUI(true, petCount, HOP_INTERVAL, os.date("%H:%M:%S"))

    if petCount == 0 then
        sendToDiscord(string.format(
            "❌ **No pets ≥30M/s found**\n🆔 Server: `%s`\n🔗 [Join](%s)",
            jobId, buildJoinLink(jobId)
        ))
        return
    end

    local top5 = {}
    for i = 1, math.min(5, petCount) do top5[i] = pets[i] end

    local description = ""
    local emojis = {"🥇", "🥈", "🥉", "4️⃣", "5️⃣"}
    for i, pet in ipairs(top5) do
        description = description .. string.format(
            "%s **%s** — `%s` | 🏠 %s %s\n",
            emojis[i] or "•",
            pet.name,
            formatMPS(pet.mps),
            pet.plot,
            pet.mutation ~= "None" and "🧬 " .. pet.mutation or ""
        )
    end
    if petCount > 5 then
        description = description .. string.format("\n*…and %d more pets ≥30M/s*", petCount - 5)
    end

    description = description .. string.format(
        "\n\n🆔 **Server:** `%s`\n🔗 **[Click to join this server](%s)**",
        jobId, buildJoinLink(jobId)
    )

    local embed = {
        title = "🌍 Top 5 Pets (All Plots, ≥30M/s)",
        description = description,
        color = 0x9B59B6,
        footer = { text = "Rustyhub | " .. os.date("%Y-%m-%d %H:%M:%S") .. " | " .. petCount .. " pets" }
    }
    sendToDiscord(nil, embed)
    print("[Webhook] Sent! Server: " .. jobId .. " | Pets: " .. petCount)
end

-- ============================================================
-- Server hop function
-- ============================================================
local function serverHop()
    print("[Hopper] Teleporting to a new server...")
    pcall(function()
        TeleportService:Teleport(game.PlaceId)
    end)
end

-- ============================================================
-- MAIN LOOP with countdown
-- ============================================================
local function main()
    print("[Rustyhub] Started. Auto-hop every " .. HOP_INTERVAL .. "s.")
    task.wait(10)

    while true do
        -- Countdown loop
        for t = HOP_INTERVAL, 1, -1 do
            updateGUI(true, nil, t, nil)
            task.wait(1)
        end
        -- Time to hop: send webhook and hop
        sendWebhook()
        serverHop()
        task.wait(8)  -- wait for new server to load
    end
end

-- ============================================================
-- START
-- ============================================================
-- Create GUI
guiLabels, guiRejoinBtn = createGUI()
updateGUI(true, 0, HOP_INTERVAL, os.date("%H:%M:%S"))

-- Send webhook on initial load
game.Loaded:Connect(function()
    task.wait(8)
    sendWebhook()
end)

-- Start main loop
task.spawn(main)