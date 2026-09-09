-- ============================================================
-- PET DETECTOR + WEBHOOK (No GUI, No Auto-Hop)
-- ============================================================

local http = game:GetService("HttpService")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer

-- 🔴 YOUR NEW WEBHOOK
local WEBHOOK_URL = "https://discord.com/api/webhooks/1547065267669180456/9xPV4yWIrinx66SS8rQVKVHqiDTg7lWtuKAoDx9LKGWjq1RDcyRTPD60TOEbDKhAac-3"

-- ⚙️ Minimum MPS (30 million)
local MINIMUM_MPS = 30000000

-- ============================================================
-- Format MPS
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
-- Load game data
-- ============================================================
local AnimalsData, MutationsData, TraitsData

local function loadData()
    local ok, data = pcall(function()
        return require(game:GetService("ReplicatedStorage"):WaitForChild("Datas"):WaitForChild("Animals"))
    end)
    if ok then AnimalsData = data end

    local ok2, data2 = pcall(function()
        return require(game:GetService("ReplicatedStorage"):WaitForChild("Datas"):WaitForChild("Mutations"))
    end)
    if ok2 then MutationsData = data2 end

    local ok3, data3 = pcall(function()
        return require(game:GetService("ReplicatedStorage"):WaitForChild("Datas"):WaitForChild("Traits"))
    end)
    if ok3 then TraitsData = data3 end

    return AnimalsData ~= nil
end

-- ============================================================
-- Get channel for a plot (works with or without MynxxSyncGet)
-- ============================================================
local function getPlotChannel(plotName)
    if _G.MynxxSyncGet then
        local ch = _G.MynxxSyncGet(plotName)
        if ch then return ch end
    end

    -- Fallback: scan heap for Synchronizer Channel
    if type(getgc) == "function" then
        local Pkgs = game:GetService("ReplicatedStorage"):FindFirstChild("Packages")
        local Sync = Pkgs and Pkgs:FindFirstChild("Synchronizer")
        if Sync then
            local ok, mod = pcall(require, Sync)
            if ok and type(mod) == "table" then
                local Channel = mod and mod.Channel
                if Channel then
                    local gc = getgc(true)
                    for _, v in ipairs(gc) do
                        if type(v) == "table" and getmetatable(v) == Channel then
                            local idx = rawget(v, "Index")
                            if idx == plotName then
                                return v
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ============================================================
-- Scan ALL plots for pets ≥ 30M/s
-- ============================================================
local function getAllPets()
    local pets = {}

    if not loadData() then
        print("[Detector] Failed to load game data!")
        return pets
    end

    local Plots = workspace:FindFirstChild("Plots")
    if not Plots then
        print("[Detector] No Plots found!")
        return pets
    end

    print("[Detector] Scanning " .. #Plots:GetChildren() .. " plots...")

    for _, plot in ipairs(Plots:GetChildren()) do
        local channel = getPlotChannel(plot.Name)
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

                                -- Apply mutation modifier
                                if mutation ~= "None" and MutationsData then
                                    local m = MutationsData[mutation]
                                    if m and m.Modifier then
                                        mps = mps * (1 + m.Modifier)
                                    end
                                end

                                -- Apply traits modifier
                                if animalData.Traits and type(animalData.Traits) == "table" and TraitsData then
                                    for _, tr in ipairs(animalData.Traits) do
                                        local t = TraitsData[tr]
                                        if t and t.MultiplierModifier then
                                            mps = mps * (1 + t.MultiplierModifier)
                                        end
                                    end
                                end

                                -- Only keep if ≥ 30M/s
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

    -- Sort by MPS (highest first)
    table.sort(pets, function(a, b) return a.mps > b.mps end)
    return pets
end

-- ============================================================
-- Send webhook
-- ============================================================
local function sendWebhook()
    print("[Detector] Scanning for pets ≥ 30M/s...")
    local pets = getAllPets()

    if #pets == 0 then
        sendToDiscord("❌ **No pets found above 30M/s.**")
        print("[Detector] No pets found.")
        return
    end

    -- Get top 5
    local top5 = {}
    for i = 1, math.min(5, #pets) do
        top5[i] = pets[i]
    end

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

    if #pets > 5 then
        description = description .. string.format("\n*…and %d more pets ≥30M/s*", #pets - 5)
    end

    local embed = {
        title = "🌍 Top 5 Pets (All Plots, ≥30M/s)",
        description = description,
        color = 0x9B59B6,
        footer = { text = "Rustyhub | " .. os.date("%Y-%m-%d %H:%M:%S") .. " | " .. #pets .. " pets" }
    }

    sendToDiscord(nil, embed)
    print("[Detector] Sent! " .. #pets .. " pets found.")
end

-- ============================================================
-- RUN
-- ============================================================
print("[Detector] Waiting 8 seconds for game to load...")
task.wait(8)
sendWebhook()