-- Rustyhub Detector + Hopper + Auto-Execute
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

-- AUTO-EXECUTE ON TELEPORT
local REJOIN_URL = "https://raw.githubusercontent.com/mithunselvarajan-cmyk/Sabaura/refs/heads/main/deepseek_lua_20260910_1c39ce.lua"

do
    local queueFn = queue_on_teleport
        or (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)

    if queueFn then
        queueFn("loadstring(game:HttpGet('" .. REJOIN_URL .. "'))()")
        print("[AutoExec] Script will re-run after hop.")
    else
        print("[AutoExec] queue_on_teleport not supported - loop will still survive hops.")
    end
end

-- YOUR WEBHOOK
local WEBHOOK_URL = "https://discord.com/api/webhooks/1547354879914287254/G8D8vvggkVXd7XmaTOCLPUZg_ssxL2KdQHvNoCs3CMFpml5GF_dQp5pNfvV7HXqJpmLs"

-- SETTINGS
local MINIMUM_MPS = 30000000
local HOP_INTERVAL = 20
local TRIGGER_DELAY = 2

-- UI
local LP = Players.LocalPlayer
local PG = LP:WaitForChild("PlayerGui")

local guiParent = (gethui and gethui()) or game:GetService("CoreGui") or PG
pcall(function()
    local old = guiParent:FindFirstChild("RustyhubUI")
    if old then old:Destroy() end
end)

local sg = Instance.new("ScreenGui")
sg.Name = "RustyhubUI"
sg.ResetOnSpawn = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.DisplayOrder = 999999
sg.IgnoreGuiInset = true
pcall(function() sg.Parent = guiParent end)
if not sg.Parent then sg.Parent = PG end

local f = Instance.new("Frame", sg)
f.Name = "Main"
f.Active = true
f.Size = UDim2.fromOffset(240, 130)
f.Position = UDim2.fromOffset(20, 20)
f.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
f.BorderSizePixel = 0
Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextButton", f)
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Text = "Rustyhub"
title.Font = Enum.Font.GothamBlack
title.TextSize = 13
title.TextColor3 = Color3.new(1, 1, 1)
title.AutoButtonColor = false
title.Active = true
title.Parent = f

do
    local dragging, dragStart, startX, startY
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startX = f.Position.X.Offset
            startY = f.Position.Y.Offset
        end
    end)
    title.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local d = input.Position - dragStart
        f.Position = UDim2.fromOffset(startX + d.X, startY + d.Y)
    end)
end

local lblStatus = Instance.new("TextLabel", f)
lblStatus.Size = UDim2.new(1, -20, 0, 20)
lblStatus.Position = UDim2.fromOffset(10, 34)
lblStatus.BackgroundTransparency = 1
lblStatus.Font = Enum.Font.GothamBold
lblStatus.TextSize = 12
lblStatus.TextColor3 = Color3.fromRGB(120, 220, 120)
lblStatus.TextXAlignment = Enum.TextXAlignment.Left
lblStatus.Text = "[ON] Running"

local lblPets = Instance.new("TextLabel", f)
lblPets.Size = UDim2.new(1, -20, 0, 20)
lblPets.Position = UDim2.fromOffset(10, 54)
lblPets.BackgroundTransparency = 1
lblPets.Font = Enum.Font.Gotham
lblPets.TextSize = 12
lblPets.TextColor3 = Color3.fromRGB(220, 220, 220)
lblPets.TextXAlignment = Enum.TextXAlignment.Left
lblPets.Text = "Pets 30M+: 0"

local lblRejoin = Instance.new("TextLabel", f)
lblRejoin.Size = UDim2.new(1, -20, 0, 20)
lblRejoin.Position = UDim2.fromOffset(10, 74)
lblRejoin.BackgroundTransparency = 1
lblRejoin.Font = Enum.Font.GothamBold
lblRejoin.TextSize = 12
lblRejoin.TextColor3 = Color3.fromRGB(255, 200, 80)
lblRejoin.TextXAlignment = Enum.TextXAlignment.Left
lblRejoin.Text = "Rejoin in: --s"

local lblScan = Instance.new("TextLabel", f)
lblScan.Size = UDim2.new(1, -20, 0, 20)
lblScan.Position = UDim2.fromOffset(10, 94)
lblScan.BackgroundTransparency = 1
lblScan.Font = Enum.Font.Gotham
lblScan.TextSize = 11
lblScan.TextColor3 = Color3.fromRGB(160, 160, 160)
lblScan.TextXAlignment = Enum.TextXAlignment.Left
lblScan.Text = "Last scan: --:--:--"

-- Format MPS
local function formatMPS(mps)
    if mps >= 1e12 then return string.format("%.2fT/s", mps/1e12) end
    if mps >= 1e9  then return string.format("%.2fB/s", mps/1e9)  end
    if mps >= 1e6  then return string.format("%.2fM/s", mps/1e6)  end
    if mps >= 1e3  then return string.format("%.2fK/s", mps/1e3)  end
    return string.format("%.0f/s", mps)
end

-- Send to Discord
local function sendToDiscord(content, embed)
    local data = { content = content or "", embeds = embed and {embed} or {} }
    local json = HttpService:JSONEncode(data)
    local headers = { ["Content-Type"] = "application/json" }

    local reqFn = request
        or (syn and syn.request)
        or (fluxus and fluxus.request)
        or http_request
        or (typeof(http) == "table" and http.request)

    if not reqFn then
        print("[Webhook] No request function available.")
        return
    end

    pcall(function()
        reqFn({ Url = WEBHOOK_URL, Method = "POST", Headers = headers, Body = json })
    end)
end

-- TEST MESSAGE ON EXECUTE
sendToDiscord("Rustyhub script executed!\nServer: " .. game.JobId .. "\n" .. os.date("%Y-%m-%d %H:%M:%S"))
print("[Rustyhub] Test message sent to webhook.")

-- Scan ALL plots
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
                                    table.insert(pets, {
                                        name = info.DisplayName or name,
                                        mps = mps,
                                        mutation = mutation,
                                        plot = plot.Name,
                                        slot = slot
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

-- Send webhook
local function sendWebhook()
    local pets = getAllPets()
    lblPets.Text = "Pets 30M+: " .. #pets
    lblScan.Text = "Last scan: " .. os.date("%H:%M:%S")

    if #pets == 0 then
        sendToDiscord("No pets found above 30M/s!")
        print("[Detector] No pets found.")
        return
    end

    local top5 = {}
    for i = 1, math.min(5, #pets) do top5[i] = pets[i] end

    local description = ""
    for i, pet in ipairs(top5) do
        description = description .. string.format(
            "#%d %s - %s | %s %s\n",
            i,
            pet.name,
            formatMPS(pet.mps),
            pet.plot,
            pet.mutation ~= "None" and "| " .. pet.mutation or ""
        )
    end

    if #pets > 5 then
        description = description .. string.format("\n...and %d more pets 30M+", #pets - 5)
    end

    local embed = {
        title = "Top 5 Pets (All Plots, 30M+)",
        description = description,
        color = 0x9B59B6,
        footer = { text = "Rustyhub | " .. os.date("%Y-%m-%d %H:%M:%S") .. " | " .. #pets .. " pets" }
    }

    sendToDiscord(nil, embed)
    print("[Detector] Sent! " .. #pets .. " pets found.")
end

-- JOIN / LEAVE TRIGGERS
Players.PlayerAdded:Connect(function(plr)
    task.spawn(function()
        print("[Trigger] JOIN: " .. plr.Name .. " - scanning in 2s")
        task.wait(TRIGGER_DELAY)
        sendWebhook()
    end)
end)

Players.PlayerRemoving:Connect(function(plr)
    task.spawn(function()
        print("[Trigger] LEAVE: " .. plr.Name .. " - scanning in 2s")
        task.wait(TRIGGER_DELAY)
        sendWebhook()
    end)
end)

-- MAIN LOOP: scan + hop every 20s with countdown
local function main()
    print("[Hopper] Started. Auto-hop every " .. HOP_INTERVAL .. "s.")
    task.wait(8)

    while true do
        sendWebhook()

        for t = HOP_INTERVAL, 1, -1 do
            lblRejoin.Text = "Rejoin in: " .. t .. "s"
            task.wait(1)
        end

        lblRejoin.Text = "Hopping..."
        lblRejoin.TextColor3 = Color3.fromRGB(255, 120, 120)
        print("[Hopper] Teleporting now...")
        pcall(function()
            TeleportService:Teleport(game.PlaceId)
        end)
        task.wait(8)
        lblRejoin.TextColor3 = Color3.fromRGB(255, 200, 80)
    end
end

task.spawn(main)