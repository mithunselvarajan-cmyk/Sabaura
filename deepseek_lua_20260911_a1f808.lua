local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

local BOT_TOKEN = "MTU0NzkzMDUzMzYyMTgwMTAyMQ.Gw_b1n.YwBoKRWfLSCAvN-TnPwTdaEBB1Ew5bkP1MHnDA"
local CHANNEL_ID = "1547354637370134528"
local POLL_INTERVAL = 2
local MAX_AGE_SEC = 30

local existingGui = CoreGui:FindFirstChild("RustyNickleHubJoiner") or LocalPlayer.PlayerGui:FindFirstChild("RustyNickleHubJoiner")
if existingGui then existingGui:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "RustyNickleHubJoiner"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = (pcall(function() return CoreGui end) and CoreGui) or LocalPlayer.PlayerGui

local CircleBtn = Instance.new("TextButton")
CircleBtn.Name = "RustyNickleJoinerCircle"
CircleBtn.Size = UDim2.new(0, 85, 0, 85)
CircleBtn.Position = UDim2.new(0.85, 0, 0.2, 0)
CircleBtn.BackgroundColor3 = Color3.fromRGB(15, 10, 20)
CircleBtn.Text = "RUSTYNICKLE\nJOINER"
CircleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CircleBtn.Font = Enum.Font.GothamBold
CircleBtn.TextSize = 10
CircleBtn.Visible = false
CircleBtn.Active = true
CircleBtn.Draggable = true
CircleBtn.Parent = ScreenGui

local CircleCorner = Instance.new("UICorner")
CircleCorner.CornerRadius = UDim.new(1, 0)
CircleCorner.Parent = CircleBtn

local CircleStroke = Instance.new("UIStroke")
CircleStroke.Color = Color3.fromRGB(255, 0, 85)
CircleStroke.Thickness = 2.5
CircleStroke.Parent = CircleBtn

local CircleGradient = Instance.new("UIGradient")
CircleGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 100)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 5, 20))
})
CircleGradient.Rotation = 45
CircleGradient.Parent = CircleBtn

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 720, 0, 440)
MainFrame.Position = UDim2.new(0.5, -360, 0.5, -220)
MainFrame.BackgroundColor3 = Color3.fromRGB(8, 8, 14)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 14)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = Color3.fromRGB(255, 0, 85)
MainStroke.Thickness = 2
MainStroke.Parent = MainFrame

CircleBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = true
    CircleBtn.Visible = false
end)

local Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.Size = UDim2.new(0, 185, 1, 0)
Sidebar.BackgroundColor3 = Color3.fromRGB(12, 10, 18)
Sidebar.BorderSizePixel = 0
Sidebar.ZIndex = 2
Sidebar.Parent = MainFrame

local SidebarCorner = Instance.new("UICorner")
SidebarCorner.CornerRadius = UDim.new(0, 14)
SidebarCorner.Parent = Sidebar

local SidebarDivider = Instance.new("Frame")
SidebarDivider.Size = UDim2.new(0, 1, 1, 0)
SidebarDivider.Position = UDim2.new(1, -1, 0, 0)
SidebarDivider.BackgroundColor3 = Color3.fromRGB(35, 20, 45)
SidebarDivider.BorderSizePixel = 0
SidebarDivider.Parent = Sidebar

local CrownIcon = Instance.new("TextLabel")
CrownIcon.Size = UDim2.new(0, 30, 0, 30)
CrownIcon.Position = UDim2.new(0, 12, 0, 12)
CrownIcon.BackgroundTransparency = 1
CrownIcon.Text = "👑"
CrownIcon.TextSize = 20
CrownIcon.Parent = Sidebar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -50, 0, 30)
TitleLabel.Position = UDim2.new(0, 42, 0, 12)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "RUSTY\nNICKLEJOIN"
TitleLabel.TextColor3 = Color3.fromRGB(255, 0, 85)
TitleLabel.TextSize = 13
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Sidebar

local StatusIndicator = Instance.new("TextLabel")
StatusIndicator.Name = "StatusIndicator"
StatusIndicator.Size = UDim2.new(1, -20, 0, 15)
StatusIndicator.Position = UDim2.new(0, 15, 0, 48)
StatusIndicator.BackgroundTransparency = 1
StatusIndicator.Text = "● Starting..."
StatusIndicator.TextColor3 = Color3.fromRGB(0, 230, 120)
StatusIndicator.TextSize = 11
StatusIndicator.Font = Enum.Font.GothamMedium
StatusIndicator.TextXAlignment = Enum.TextXAlignment.Left
StatusIndicator.Parent = Sidebar

local NavContainer = Instance.new("Frame")
NavContainer.Size = UDim2.new(1, -20, 0, 200)
NavContainer.Position = UDim2.new(0, 10, 0, 75)
NavContainer.BackgroundTransparency = 1
NavContainer.Parent = Sidebar

local UIListLayout = Instance.new("UIListLayout")
UIListLayout.Parent = NavContainer
UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayout.Padding = UDim.new(0, 6)

local PagesContainer = Instance.new("Frame")
PagesContainer.Name = "PagesContainer"
PagesContainer.Size = UDim2.new(1, -205, 1, -40)
PagesContainer.Position = UDim2.new(0, 195, 0, 35)
PagesContainer.BackgroundTransparency = 1
PagesContainer.Parent = MainFrame

local Pages = {}

local function createPage(name)
    local Page = Instance.new("Frame")
    Page.Name = name .. "Page"
    Page.Size = UDim2.new(1, 0, 1, 0)
    Page.BackgroundTransparency = 1
    Page.Visible = false
    Page.Parent = PagesContainer
    Pages[name] = Page
    return Page
end

local LogsPage = createPage("Logs")
local HistoryPage = createPage("History")
local UsersPage = createPage("Users")
local SettingsPage = createPage("Settings")

local TopControls = Instance.new("Frame")
TopControls.Size = UDim2.new(0, 60, 0, 25)
TopControls.Position = UDim2.new(1, -65, 0, 8)
TopControls.BackgroundTransparency = 1
TopControls.Parent = MainFrame

local MinWinBtn = Instance.new("TextButton")
MinWinBtn.Size = UDim2.new(0, 24, 0, 20)
MinWinBtn.BackgroundColor3 = Color3.fromRGB(20, 15, 28)
MinWinBtn.Text = "—"
MinWinBtn.TextColor3 = Color3.fromRGB(180, 180, 200)
MinWinBtn.Font = Enum.Font.GothamBold
MinWinBtn.TextSize = 12
MinWinBtn.Parent = TopControls
local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0, 4)
MinCorner.Parent = MinWinBtn

MinWinBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
    CircleBtn.Visible = true
end)

local CloseWinBtn = Instance.new("TextButton")
CloseWinBtn.Size = UDim2.new(0, 24, 0, 20)
CloseWinBtn.Position = UDim2.new(0, 28, 0, 0)
CloseWinBtn.BackgroundColor3 = Color3.fromRGB(40, 15, 25)
CloseWinBtn.Text = "✕"
CloseWinBtn.TextColor3 = Color3.fromRGB(255, 50, 80)
CloseWinBtn.Font = Enum.Font.GothamBold
CloseWinBtn.TextSize = 11
CloseWinBtn.Parent = TopControls
local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 4)
CloseCorner.Parent = CloseWinBtn

CloseWinBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
    CircleBtn.Visible = true
end)

local navButtons = {}
local tabIcons = { Logs = "📄", History = "🕒", Users = "👤", Settings = "⚙️" }

local function selectTab(tabName)
    for name, button in pairs(navButtons) do
        if name == tabName then
            button.BackgroundColor3 = Color3.fromRGB(25, 12, 30)
            button.UIStroke.Transparency = 0
            button.TextColor3 = Color3.fromRGB(255, 255, 255)
            Pages[name].Visible = true
        else
            button.BackgroundColor3 = Color3.fromRGB(12, 10, 18)
            button.UIStroke.Transparency = 1
            button.TextColor3 = Color3.fromRGB(150, 140, 170)
            Pages[name].Visible = false
        end
    end
end

local function createNavButton(name, order)
    local Btn = Instance.new("TextButton")
    Btn.Name = name .. "Btn"
    Btn.Size = UDim2.new(1, 0, 0, 36)
    Btn.LayoutOrder = order
    Btn.BackgroundColor3 = Color3.fromRGB(12, 10, 18)
    Btn.Text = "   " .. (tabIcons[name] or "") .. "  " .. name
    Btn.TextColor3 = Color3.fromRGB(150, 140, 170)
    Btn.Font = Enum.Font.GothamMedium
    Btn.TextSize = 13
    Btn.TextXAlignment = Enum.TextXAlignment.Left
    Btn.Parent = NavContainer

    local Arrow = Instance.new("TextLabel")
    Arrow.Size = UDim2.new(0, 20, 1, 0)
    Arrow.Position = UDim2.new(1, -22, 0, 0)
    Arrow.BackgroundTransparency = 1
    Arrow.Text = "›"
    Arrow.TextColor3 = Color3.fromRGB(255, 0, 85)
    Arrow.Font = Enum.Font.GothamBold
    Arrow.TextSize = 16
    Arrow.Parent = Btn

    local BtnCorner = Instance.new("UICorner")
    BtnCorner.CornerRadius = UDim.new(0, 8)
    BtnCorner.Parent = Btn

    local BtnStroke = Instance.new("UIStroke")
    BtnStroke.Color = Color3.fromRGB(255, 0, 85)
    BtnStroke.Thickness = 1
    BtnStroke.Transparency = 1
    BtnStroke.Parent = Btn

    navButtons[name] = Btn
    Btn.MouseButton1Click:Connect(function() selectTab(name) end)
end

createNavButton("Logs", 1)
createNavButton("History", 2)
createNavButton("Users", 3)
createNavButton("Settings", 4)

local UserProfileCard = Instance.new("Frame")
UserProfileCard.Size = UDim2.new(1, -20, 0, 50)
UserProfileCard.Position = UDim2.new(0, 10, 1, -96)
UserProfileCard.BackgroundColor3 = Color3.fromRGB(20, 8, 22)
UserProfileCard.Parent = Sidebar

local UserCardCorner = Instance.new("UICorner")
UserCardCorner.CornerRadius = UDim.new(0, 8)
UserCardCorner.Parent = UserProfileCard

local UserCardStroke = Instance.new("UIStroke")
UserCardStroke.Color = Color3.fromRGB(255, 0, 85)
UserCardStroke.Thickness = 1
UserCardStroke.Parent = UserProfileCard

local AvatarImage = Instance.new("ImageLabel")
AvatarImage.Size = UDim2.new(0, 36, 0, 36)
AvatarImage.Position = UDim2.new(0, 7, 0.5, -18)
AvatarImage.BackgroundColor3 = Color3.fromRGB(30, 15, 35)
AvatarImage.Image = "rbxthumb://type=AvatarHeadShot&id=" .. LocalPlayer.UserId .. "&w=150&h=150"
AvatarImage.Parent = UserProfileCard

local AvatarCorner = Instance.new("UICorner")
AvatarCorner.CornerRadius = UDim.new(1, 0)
AvatarCorner.Parent = AvatarImage

local AvatarStroke = Instance.new("UIStroke")
AvatarStroke.Color = Color3.fromRGB(255, 0, 85)
AvatarStroke.Thickness = 1
AvatarStroke.Parent = AvatarImage

local DisplayNameLabel = Instance.new("TextLabel")
DisplayNameLabel.Size = UDim2.new(1, -52, 0, 18)
DisplayNameLabel.Position = UDim2.new(0, 48, 0, 8)
DisplayNameLabel.BackgroundTransparency = 1
DisplayNameLabel.Text = LocalPlayer.DisplayName
DisplayNameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
DisplayNameLabel.Font = Enum.Font.GothamBold
DisplayNameLabel.TextSize = 12
DisplayNameLabel.TextXAlignment = Enum.TextXAlignment.Left
DisplayNameLabel.TextTruncate = Enum.TextTruncate.AtEnd
DisplayNameLabel.Parent = UserProfileCard

local UsernameLabel = Instance.new("TextLabel")
UsernameLabel.Size = UDim2.new(1, -52, 0, 16)
UsernameLabel.Position = UDim2.new(0, 48, 0, 24)
UsernameLabel.BackgroundTransparency = 1
UsernameLabel.Text = "@" .. LocalPlayer.Name
UsernameLabel.TextColor3 = Color3.fromRGB(150, 140, 170)
UsernameLabel.Font = Enum.Font.Gotham
UsernameLabel.TextSize = 10
UsernameLabel.TextXAlignment = Enum.TextXAlignment.Left
UsernameLabel.TextTruncate = Enum.TextTruncate.AtEnd
UsernameLabel.Parent = UserProfileCard

local HideBtn = Instance.new("TextButton")
HideBtn.Size = UDim2.new(1, -20, 0, 34)
HideBtn.Position = UDim2.new(0, 10, 1, -40)
HideBtn.BackgroundColor3 = Color3.fromRGB(18, 12, 24)
HideBtn.Text = "👁  Hide UI"
HideBtn.TextColor3 = Color3.fromRGB(220, 210, 230)
HideBtn.Font = Enum.Font.GothamMedium
HideBtn.TextSize = 12
HideBtn.Parent = Sidebar

local HideCorner = Instance.new("UICorner")
HideCorner.CornerRadius = UDim.new(0, 8)
HideCorner.Parent = HideBtn

local HideStroke = Instance.new("UIStroke")
HideStroke.Color = Color3.fromRGB(255, 0, 85)
HideStroke.Thickness = 1
HideStroke.Parent = HideBtn

HideBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
    CircleBtn.Visible = true
end)

local LiveHeader = Instance.new("TextLabel")
LiveHeader.Size = UDim2.new(0, 150, 0, 20)
LiveHeader.Position = UDim2.new(0, 0, 0, 0)
LiveHeader.BackgroundTransparency = 1
LiveHeader.Text = "📡  LIVE JOIN FEED"
LiveHeader.TextColor3 = Color3.fromRGB(255, 0, 85)
LiveHeader.Font = Enum.Font.GothamBold
LiveHeader.TextSize = 12
LiveHeader.TextXAlignment = Enum.TextXAlignment.Left
LiveHeader.Parent = LogsPage

local ClearBtn = Instance.new("TextButton")
ClearBtn.Size = UDim2.new(0, 65, 0, 22)
ClearBtn.Position = UDim2.new(1, -65, 0, 0)
ClearBtn.BackgroundColor3 = Color3.fromRGB(45, 12, 25)
ClearBtn.Text = "🗑 Clear"
ClearBtn.TextColor3 = Color3.fromRGB(255, 80, 110)
ClearBtn.Font = Enum.Font.GothamBold
ClearBtn.TextSize = 11
ClearBtn.Parent = LogsPage

local ClearCorner = Instance.new("UICorner")
ClearCorner.CornerRadius = UDim.new(0, 6)
ClearCorner.Parent = ClearBtn

local ClearStroke = Instance.new("UIStroke")
ClearStroke.Color = Color3.fromRGB(255, 0, 85)
ClearStroke.Thickness = 1
ClearStroke.Parent = ClearBtn

local FeedFrame = Instance.new("ScrollingFrame")
FeedFrame.Size = UDim2.new(1, 0, 1, -30)
FeedFrame.Position = UDim2.new(0, 0, 0, 28)
FeedFrame.BackgroundColor3 = Color3.fromRGB(10, 8, 16)
FeedFrame.BorderSizePixel = 0
FeedFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
FeedFrame.ScrollBarThickness = 4
FeedFrame.Parent = LogsPage

local FeedCorner = Instance.new("UICorner")
FeedCorner.CornerRadius = UDim.new(0, 10)
FeedCorner.Parent = FeedFrame

local FeedStroke = Instance.new("UIStroke")
FeedStroke.Color = Color3.fromRGB(40, 20, 55)
FeedStroke.Thickness = 1
FeedStroke.Parent = FeedFrame

local FeedLayout = Instance.new("UIListLayout")
FeedLayout.Parent = FeedFrame
FeedLayout.Padding = UDim.new(0, 6)

local EmptyLogsIcon = Instance.new("TextLabel")
EmptyLogsIcon.Size = UDim2.new(1, 0, 0, 40)
EmptyLogsIcon.Position = UDim2.new(0, 0, 0.35, 0)
EmptyLogsIcon.BackgroundTransparency = 1
EmptyLogsIcon.Text = "📋"
EmptyLogsIcon.TextSize = 32
EmptyLogsIcon.Parent = FeedFrame

local EmptyLogsText = Instance.new("TextLabel")
EmptyLogsText.Size = UDim2.new(1, 0, 0, 20)
EmptyLogsText.Position = UDim2.new(0, 0, 0.35, 42)
EmptyLogsText.BackgroundTransparency = 1
EmptyLogsText.Text = "Waiting for fresh detection..."
EmptyLogsText.TextColor3 = Color3.fromRGB(200, 200, 220)
EmptyLogsText.Font = Enum.Font.GothamBold
EmptyLogsText.TextSize = 13
EmptyLogsText.Parent = FeedFrame

local EmptyLogsSub = Instance.new("TextLabel")
EmptyLogsSub.Size = UDim2.new(1, 0, 0, 15)
EmptyLogsSub.Position = UDim2.new(0, 0, 0.35, 62)
EmptyLogsSub.BackgroundTransparency = 1
EmptyLogsSub.Text = "—— Servers appear here (<30s old) ——"
EmptyLogsSub.TextColor3 = Color3.fromRGB(100, 90, 120)
EmptyLogsSub.Font = Enum.Font.Gotham
EmptyLogsSub.TextSize = 11
EmptyLogsSub.Parent = FeedFrame

ClearBtn.MouseButton1Click:Connect(function()
    for _, item in ipairs(FeedFrame:GetChildren()) do
        if item:IsA("Frame") then item:Destroy() end
    end
    EmptyLogsIcon.Visible = true
    EmptyLogsText.Visible = true
    EmptyLogsSub.Visible = true
    FeedFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
end)

local HistoryHeader = Instance.new("TextLabel")
HistoryHeader.Size = UDim2.new(1, 0, 0, 25)
HistoryHeader.BackgroundTransparency = 1
HistoryHeader.Text = "Join History"
HistoryHeader.TextColor3 = Color3.fromRGB(255, 255, 255)
HistoryHeader.Font = Enum.Font.GothamBold
HistoryHeader.TextSize = 16
HistoryHeader.TextXAlignment = Enum.TextXAlignment.Left
HistoryHeader.Parent = HistoryPage

local UsersHeader = Instance.new("TextLabel")
UsersHeader.Size = UDim2.new(1, 0, 0, 25)
UsersHeader.BackgroundTransparency = 1
UsersHeader.Text = "Global Users"
UsersHeader.TextColor3 = Color3.fromRGB(255, 255, 255)
UsersHeader.Font = Enum.Font.GothamBold
UsersHeader.TextSize = 16
UsersHeader.TextXAlignment = Enum.TextXAlignment.Left
UsersHeader.Parent = UsersPage

local SettingsTitle = Instance.new("TextLabel")
SettingsTitle.Size = UDim2.new(1, 0, 0, 25)
SettingsTitle.BackgroundTransparency = 1
SettingsTitle.Text = "Settings"
SettingsTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
SettingsTitle.Font = Enum.Font.GothamBold
SettingsTitle.TextSize = 16
SettingsTitle.TextXAlignment = Enum.TextXAlignment.Left
SettingsTitle.Parent = SettingsPage

local SettingsScroll = Instance.new("ScrollingFrame")
SettingsScroll.Size = UDim2.new(1, 0, 1, -30)
SettingsScroll.Position = UDim2.new(0, 0, 0, 30)
SettingsScroll.BackgroundTransparency = 1
SettingsScroll.BorderSizePixel = 0
SettingsScroll.ScrollBarThickness = 4
SettingsScroll.Parent = SettingsPage

local SettingsLayout = Instance.new("UIListLayout")
SettingsLayout.Parent = SettingsScroll
SettingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
SettingsLayout.Padding = UDim.new(0, 8)

local function createSettingContainer(title, sub, order)
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, -8, 0, 58)
    Frame.BackgroundColor3 = Color3.fromRGB(15, 12, 22)
    Frame.LayoutOrder = order
    Frame.Parent = SettingsScroll

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 10)
    Corner.Parent = Frame

    local Stroke = Instance.new("UIStroke")
    Stroke.Color = Color3.fromRGB(45, 25, 60)
    Stroke.Thickness = 1
    Stroke.Parent = Frame

    local TxtLabel = Instance.new("TextLabel")
    TxtLabel.Size = UDim2.new(0.5, 0, 0, 20)
    TxtLabel.Position = UDim2.new(0, 12, 0, 10)
    TxtLabel.BackgroundTransparency = 1
    TxtLabel.Text = title
    TxtLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    TxtLabel.Font = Enum.Font.GothamBold
    TxtLabel.TextSize = 13
    TxtLabel.TextXAlignment = Enum.TextXAlignment.Left
    TxtLabel.Parent = Frame

    local SubLabel = Instance.new("TextLabel")
    SubLabel.Size = UDim2.new(0.5, 0, 0, 16)
    SubLabel.Position = UDim2.new(0, 12, 0, 30)
    SubLabel.BackgroundTransparency = 1
    SubLabel.Text = sub
    SubLabel.TextColor3 = Color3.fromRGB(140, 130, 160)
    SubLabel.Font = Enum.Font.Gotham
    SubLabel.TextSize = 11
    SubLabel.TextXAlignment = Enum.TextXAlignment.Left
    SubLabel.Parent = Frame

    return Frame
end

local UnloadBox = createSettingContainer("Unload", "Remove the script completely", 1)
local UnloadBtn = Instance.new("TextButton")
UnloadBtn.Size = UDim2.new(0, 80, 0, 28)
UnloadBtn.Position = UDim2.new(1, -92, 0.5, -14)
UnloadBtn.BackgroundColor3 = Color3.fromRGB(120, 30, 40)
UnloadBtn.Text = "Unload"
UnloadBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
UnloadBtn.Font = Enum.Font.GothamBold
UnloadBtn.TextSize = 12
UnloadBtn.Parent = UnloadBox
local UnloadCorner = Instance.new("UICorner")
UnloadCorner.CornerRadius = UDim.new(0, 6)
UnloadCorner.Parent = UnloadBtn

UnloadBtn.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
end)

local ThemeBox = createSettingContainer("Theme Color", "Choose your accent color", 2)
ThemeBox.Size = UDim2.new(1, -8, 0, 65)

local ThemeContainer = Instance.new("Frame")
ThemeContainer.Size = UDim2.new(0, 240, 0, 24)
ThemeContainer.Position = UDim2.new(1, -250, 0.5, -12)
ThemeContainer.BackgroundTransparency = 1
ThemeContainer.Parent = ThemeBox

local ThemeLayout = Instance.new("UIListLayout")
ThemeLayout.Parent = ThemeContainer
ThemeLayout.FillDirection = Enum.FillDirection.Horizontal
ThemeLayout.Padding = UDim.new(0, 6)

local colors = {
    Color3.fromRGB(255, 0, 85),
    Color3.fromRGB(110, 80, 230),
    Color3.fromRGB(0, 170, 255),
    Color3.fromRGB(180, 80, 255),
    Color3.fromRGB(40, 200, 120),
    Color3.fromRGB(255, 170, 0)
}

for _, color in ipairs(colors) do
    local Dot = Instance.new("TextButton")
    Dot.Size = UDim2.new(0, 22, 0, 22)
    Dot.BackgroundColor3 = color
    Dot.Text = ""
    Dot.Parent = ThemeContainer

    local DotCorner = Instance.new("UICorner")
    DotCorner.CornerRadius = UDim.new(1, 0)
    DotCorner.Parent = Dot

    Dot.MouseButton1Click:Connect(function()
        MainStroke.Color = color
        CircleStroke.Color = color
        TitleLabel.TextColor3 = color
        UserCardStroke.Color = color
        AvatarStroke.Color = color
        ClearStroke.Color = color
        LiveHeader.TextColor3 = color
        HideStroke.Color = color
    end)
end

SettingsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    SettingsScroll.CanvasSize = UDim2.new(0, 0, 0, SettingsLayout.AbsoluteContentSize.Y + 20)
end)

selectTab("Logs")

local function httpGetWithHeaders(url, headers)
    local out
    pcall(function() out = game:HttpGet(url, true, headers) end)
    if type(out) == "string" and #out > 0 then return out end

    local reqFn = request or (syn and syn.request) or (fluxus and fluxus.request)
        or http_request or (typeof(http) == "table" and http.request)
    if reqFn then
        local ok, res = pcall(function()
            return reqFn({ Url = url, Method = "GET", Headers = headers })
        end)
        if ok and type(res) == "table" then
            local body = res.Body or res.body
            if type(body) == "string" and #body > 0 then return body end
        end
    end
    return nil
end

local function fetchMessages(limit)
    local url = "https://discord.com/api/v10/channels/" .. CHANNEL_ID .. "/messages?limit=" .. tostring(limit or 5)
    local body = httpGetWithHeaders(url, { ["Authorization"] = "Bot " .. BOT_TOKEN })
    if not body then return nil, "no response" end

    if body:sub(1, 1) == "{" and (body:find('"code"') or body:find('"message"')) then
        local ok, err = pcall(function() return HttpService:JSONDecode(body) end)
        if ok and type(err) == "table" and err.message then
            return nil, "API: " .. tostring(err.message):sub(1, 60)
        end
    end

    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(data) ~= "table" then return nil, "bad JSON" end
    return data
end

local function buildText(msg)
    local text = msg.content or ""
    if msg.embeds then
        for _, e in ipairs(msg.embeds) do
            if e.title then text = text .. "\n" .. e.title end
            if e.description then text = text .. "\n" .. e.description end
            if e.footer and e.footer.text then text = text .. "\n" .. e.footer.text end
        end
    end
    return text
end

local function extractTop(text)
    local line = text:match("Top:%s*([^\n]+)")
    if not line then return nil end

    local name, mps, rest = line:match("^(.-)%s*%-%s*([%d%.]+[KMBT]?)%s*(.*)$")
    if not name then return nil end

    local mutation = ""
    if rest then
        mutation = rest:match("|%s*([^|]+)") or ""
        mutation = mutation:gsub("^%s+", ""):gsub("%s+$", "")
    end

    local jobId = text:match("gameInstanceId=([%x%-]+)")
    local placeId = text:match("placeId=(%d+)")
    if not jobId then return nil end

    return {
        name = name:gsub("%s+$", ""),
        mps = mps .. "/s",
        mutation = mutation,
        jobId = jobId,
        placeId = placeId or tostring(game.PlaceId),
    }
end

local function msgAgeSec(msg)
    if not msg.timestamp then return 999 end
    local ok, dt = pcall(function() return DateTime.fromIsoDate(msg.timestamp) end)
    if not ok or not dt then return 999 end
    return (DateTime.now().UnixTimestampMillis - dt.UnixTimestampMillis) / 1000
end

local entries = {}
local seenIds = {}

local function joinServer(pid, jid)
    if not (pid and jid) then return end
    if jid == game.JobId then
        StatusIndicator.Text = "● Already here"
        return
    end
    pcall(function()
        TeleportService:TeleportToGameInstance(tonumber(pid), jid)
    end)
end

local function buildEntry(msgId, pet, ageAtBuild)
    local ItemFrame = Instance.new("Frame")
    ItemFrame.Name = msgId
    ItemFrame.Size = UDim2.new(1, -8, 0, 60)
    ItemFrame.BackgroundColor3 = Color3.fromRGB(18, 14, 26)
    ItemFrame.Parent = FeedFrame
    ItemFrame.LayoutOrder = -os.time()

    local ItemCorner = Instance.new("UICorner")
    ItemCorner.CornerRadius = UDim.new(0, 6)
    ItemCorner.Parent = ItemFrame

    local ItemStroke = Instance.new("UIStroke")
    ItemStroke.Color = Color3.fromRGB(40, 20, 55)
    ItemStroke.Thickness = 1
    ItemStroke.Parent = ItemFrame

    local NameLbl = Instance.new("TextLabel")
    NameLbl.Size = UDim2.new(0.7, 0, 0, 20)
    NameLbl.Position = UDim2.new(0, 10, 0, 8)
    NameLbl.BackgroundTransparency = 1
    NameLbl.Text = pet.name
    NameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
    NameLbl.Font = Enum.Font.GothamBold
    NameLbl.TextSize = 13
    NameLbl.TextXAlignment = Enum.TextXAlignment.Left
    NameLbl.TextTruncate = Enum.TextTruncate.AtEnd
    NameLbl.Parent = ItemFrame

    local MpsLbl = Instance.new("TextLabel")
    MpsLbl.Size = UDim2.new(0.7, 0, 0, 16)
    MpsLbl.Position = UDim2.new(0, 10, 0, 30)
    MpsLbl.BackgroundTransparency = 1
    local mutTxt = (pet.mutation ~= "" and (" · " .. pet.mutation)) or ""
    MpsLbl.Text = pet.mps .. mutTxt .. "  ·  " .. math.floor(ageAtBuild) .. "s ago"
    MpsLbl.TextColor3 = Color3.fromRGB(0, 230, 120)
    MpsLbl.Font = Enum.Font.Gotham
    MpsLbl.TextSize = 11
    MpsLbl.TextXAlignment = Enum.TextXAlignment.Left
    MpsLbl.Parent = ItemFrame

    local JoinBtn = Instance.new("TextButton")
    JoinBtn.Size = UDim2.new(0, 90, 0, 36)
    JoinBtn.Position = UDim2.new(1, -100, 0.5, -18)
    JoinBtn.BackgroundColor3 = Color3.fromRGB(180, 20, 70)
    JoinBtn.Text = "JOIN"
    JoinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    JoinBtn.Font = Enum.Font.GothamBold
    JoinBtn.TextSize = 13
    JoinBtn.Parent = ItemFrame

    local JoinCorner = Instance.new("UICorner")
    JoinCorner.CornerRadius = UDim.new(0, 8)
    JoinCorner.Parent = JoinBtn

    local JoinStroke = Instance.new("UIStroke")
    JoinStroke.Color = Color3.fromRGB(255, 0, 85)
    JoinStroke.Thickness = 1.5
    JoinStroke.Parent = JoinBtn

    JoinBtn.MouseButton1Click:Connect(function()
        JoinBtn.Text = "..."
        joinServer(pet.placeId, pet.jobId)
    end)

    FeedFrame.CanvasSize = UDim2.new(0, 0, 0, FeedLayout.AbsoluteContentSize.Y + 10)
    return ItemFrame
end

task.spawn(function()
    while true do
        StatusIndicator.Text = "● Fetching..."
        StatusIndicator.TextColor3 = Color3.fromRGB(255, 200, 80)

        local msgs, err = fetchMessages(5)

        if not msgs then
            StatusIndicator.Text = "● " .. (err or "error")
            StatusIndicator.TextColor3 = Color3.fromRGB(255, 120, 120)
        else
            StatusIndicator.Text = "● Connected"
            StatusIndicator.TextColor3 = Color3.fromRGB(0, 230, 120)

            for _, msg in ipairs(msgs) do
                if msg.id and not seenIds[msg.id] then
                    seenIds[msg.id] = true

                    local age = msgAgeSec(msg)
                    if age <= MAX_AGE_SEC then
                        local text = buildText(msg)
                        local pet = extractTop(text)

                        if pet then
                            if not entries[msg.id] then
                                local frame = buildEntry(msg.id, pet, age)
                                entries[msg.id] = { frame = frame, createdAt = os.time() }
                                EmptyLogsIcon.Visible = false
                                EmptyLogsText.Visible = false
                                EmptyLogsSub.Visible = false
                            end
                        end
                    end
                end
            end

            local now = os.time()
            for id, e in pairs(entries) do
                if e.frame and e.frame.Parent then
                    local age = now - e.createdAt
                    if age > MAX_AGE_SEC then
                        e.frame:Destroy()
                        entries[id] = nil
                    end
                else
                    entries[id] = nil
                end
            end

            if next(entries) == nil then
                EmptyLogsIcon.Visible = true
                EmptyLogsText.Visible = true
                EmptyLogsSub.Visible = true
            end
        end

        task.wait(POLL_INTERVAL)
    end
end)