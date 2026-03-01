--[[
    ╔══════════════════════════════════════════════════════════════╗
    ║                      S I L E N T H O O K                    ║
    ║              Dead Rails — Systems Framework v2.1             ║
    ║                                                              ║
    ║  Modules:  Bonds · Inventory · Hook · Visuals · Lifecycle    ║
    ╚══════════════════════════════════════════════════════════════╝
--]]

-- ═══════════════════════════════════════════════════════════════
-- 0. ENVIRONMENT BOOTSTRAP & SAFETY CHECKS
-- ═══════════════════════════════════════════════════════════════

local FRAMEWORK_ID = "SilentHook"
local FRAMEWORK_VERSION = "2.1.0"

-- Prevent double-injection
if getgenv and getgenv()[FRAMEWORK_ID] then
    warn("[SilentHook] Already loaded — aborting duplicate injection.")
    return
end

-- Capability detection
local function requireCapability(name, func)
    if not func then
        warn(("[SilentHook] Missing capability: %s — framework cannot load."):format(name))
        return false
    end
    return true
end

local requiredCapabilities = {
    {"hookmetamethod", hookmetamethod},
    {"getnamecallmethod", getnamecallmethod},
    {"getrawmetatable", getrawmetatable},
    {"newcclosure", newcclosure},
    {"Drawing", Drawing and Drawing.new},
}

for _, cap in ipairs(requiredCapabilities) do
    if not requireCapability(cap[1], cap[2]) then
        return
    end
end

-- ═══════════════════════════════════════════════════════════════
-- 1. CORE SERVICES & REFERENCES
-- ═══════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local LocalPlayer  = Players.LocalPlayer
local Camera       = Workspace.CurrentCamera
local Mouse        = LocalPlayer:GetMouse()

-- ═══════════════════════════════════════════════════════════════
-- 2. STATE CONTAINER — Single source of truth for all toggles
-- ═══════════════════════════════════════════════════════════════

local State = {
    -- Bonds Module
    UnlimitedBondsVisual   = false,
    AutoFarmBonds          = false,
    UnlockAllClasses       = false,

    -- Inventory Module
    InstantInteraction     = false,
    AutoLoot               = false,

    -- Combat / Hook Module
    SilentAim              = false,
    SilentAimTarget        = "Head", -- Head / Torso
    SilentAimFOV           = 250,
    NoRecoilSpread         = false,
    SurvivalFreeze         = false,

    -- Visuals Module
    ESP_Players            = false,
    ESP_NPCs              = false,
    ESP_Extraction         = false,
    ESP_LootCrates         = false,
    ESP_ShowDistance        = true,
    ESP_ShowHealth         = true,
    ESP_MaxDistance         = 2000,

    -- Internal
    _connections = {},
    _drawings    = {},
    _originals   = {},
    _threads     = {},
    _running     = true,
}

-- ═══════════════════════════════════════════════════════════════
-- 3. UTILITY LIBRARY
-- ═══════════════════════════════════════════════════════════════

local Util = {}

function Util.safeConnect(signal, callback)
    local conn = signal:Connect(callback)
    table.insert(State._connections, conn)
    return conn
end

function Util.createThread(name, func)
    local thread = task.spawn(function()
        local ok, err = pcall(func)
        if not ok then
            warn(("[SilentHook][%s] Thread error: %s"):format(name, tostring(err)))
        end
    end)
    State._threads[name] = thread
    return thread
end

function Util.isAlive(character)
    if not character then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid and humanoid.Health > 0
end

function Util.getCharacterRoot(character)
    return character and (character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Head"))
end

function Util.worldToScreen(position)
    local screenPos, onScreen = Camera:WorldToViewportPoint(position)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

function Util.getDistance2D(v2a, v2b)
    return (v2a - v2b).Magnitude
end

function Util.getDistance3D(v3a, v3b)
    return (v3a - v3b).Magnitude
end

function Util.screenCenter()
    local viewport = Camera.ViewportSize
    return Vector2.new(viewport.X / 2, viewport.Y / 2)
end

function Util.isTeammate(player)
    if not LocalPlayer.Team or not player.Team then return false end
    return LocalPlayer.Team == player.Team
end

-- Deep search for a remote by name within ReplicatedStorage and its descendants
function Util.findRemote(name, className)
    className = className or "RemoteEvent"
    local function search(parent)
        for _, child in ipairs(parent:GetDescendants()) do
            if child:IsA(className) and child.Name == name then
                return child
            end
        end
        return nil
    end
    return search(ReplicatedStorage) or search(game)
end

-- Recursive find in data structures
function Util.deepFind(tbl, key)
    if type(tbl) ~= "table" then return nil end
    if tbl[key] ~= nil then return tbl[key] end
    for _, v in pairs(tbl) do
        local result = Util.deepFind(v, key)
        if result ~= nil then return result end
    end
    return nil
end

-- FOV circle check
function Util.isInFOV(worldPosition, fovRadius)
    local screenPos, onScreen = Util.worldToScreen(worldPosition)
    if not onScreen then return false, math.huge end
    local dist = Util.getDistance2D(screenPos, Util.screenCenter())
    return dist <= fovRadius, dist
end

-- ═══════════════════════════════════════════════════════════════
-- 4. LINORIA UI LIBRARY LOAD
-- ═══════════════════════════════════════════════════════════════

local LinoriaRepo = "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/"

local Library     = loadstring(game:HttpGet(LinoriaRepo .. "Library.lua"))()
local ThemeManager= loadstring(game:HttpGet(LinoriaRepo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(LinoriaRepo .. "addons/SaveManager.lua"))()

-- ═══════════════════════════════════════════════════════════════
-- 5. GUI CREATION — Parented to gethui()/CoreGui for stealth
-- ═══════════════════════════════════════════════════════════════

local Window = Library:CreateWindow({
    Title    = "SilentHook v" .. FRAMEWORK_VERSION .. " — Dead Rails",
    Center   = true,
    AutoShow = true,
    TabPadding = 2,
    MenuFadeTime = 0.15,
})

-- Stealth parenting
pcall(function()
    if gethui then
        Library.ScreenGui.Parent = gethui()
    elseif syn and syn.protect_gui then
        syn.protect_gui(Library.ScreenGui)
        Library.ScreenGui.Parent = CoreGui
    else
        Library.ScreenGui.Parent = CoreGui
    end
end)

-- Tabs
local TabBonds     = Window:AddTab("💰 Bonds")
local TabInventory = Window:AddTab("🎒 Inventory")
local TabCombat    = Window:AddTab("🎯 Combat")
local TabVisuals   = Window:AddTab("👁 Visuals")
local TabSettings  = Window:AddTab("⚙ Settings")

-- ═══════════════════════════════════════════════════════════════
-- 6. MODULE: BONDS & PROGRESSION
-- ═══════════════════════════════════════════════════════════════

local BondsModule = {}

-- 6a. Visual Bonds Override
function BondsModule.SetVisualBonds(enabled)
    State.UnlimitedBondsVisual = enabled
    if not enabled then return end

    Util.createThread("VisualBonds", function()
        while State.UnlimitedBondsVisual and State._running do
            pcall(function()
                -- Search common data paths
                local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
                if leaderstats then
                    local bonds = leaderstats:FindFirstChild("Bonds")
                        or leaderstats:FindFirstChild("bonds")
                        or leaderstats:FindFirstChild("Money")
                        or leaderstats:FindFirstChild("Coins")
                    if bonds and bonds:IsA("ValueBase") then
                        bonds.Value = 999999999
                    end
                end

                -- Also check PlayerData folder pattern
                local playerData = LocalPlayer:FindFirstChild("PlayerData")
                    or LocalPlayer:FindFirstChild("Data")
                    or LocalPlayer:FindFirstChild("Stats")
                if playerData then
                    for _, child in ipairs(playerData:GetDescendants()) do
                        if child:IsA("ValueBase") and
                           (child.Name:lower():find("bond") or child.Name:lower():find("money")
                            or child.Name:lower():find("currency")) then
                            child.Value = 999999999
                        end
                    end
                end

                -- Override any on-screen currency UI elements
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if playerGui then
                    for _, gui in ipairs(playerGui:GetDescendants()) do
                        if gui:IsA("TextLabel") and gui.Name:lower():find("bond") then
                            gui.Text = "999,999,999"
                        end
                    end
                end
            end)
            task.wait(0.5)
        end
    end)
end

-- 6b. Auto-Farm Bonds (server-side triggers)
function BondsModule.SetAutoFarm(enabled)
    State.AutoFarmBonds = enabled
    if not enabled then return end

    Util.createThread("AutoFarmBonds", function()
        while State.AutoFarmBonds and State._running do
            pcall(function()
                local character = LocalPlayer.Character
                local root = Util.getCharacterRoot(character)
                if not root or not Util.isAlive(character) then
                    task.wait(1)
                    return
                end

                -- Strategy 1: Trigger nearby NPC interaction remotes
                local interactionRemotes = {
                    "InteractNPC", "CompleteObjective", "CollectReward",
                    "SubmitTask", "ClaimBonds", "CompleteQuest",
                    "Interact", "AcceptQuest", "TurnInQuest"
                }

                for _, remoteName in ipairs(interactionRemotes) do
                    local remote = Util.findRemote(remoteName)
                    if remote then
                        pcall(function()
                            remote:FireServer()
                        end)
                    end
                    -- Also check RemoteFunctions
                    local remoteFunc = Util.findRemote(remoteName, "RemoteFunction")
                    if remoteFunc then
                        pcall(function()
                            remoteFunc:InvokeServer()
                        end)
                    end
                end

                -- Strategy 2: Auto-interact with world objective triggers
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ProximityPrompt") and obj.Enabled then
                        local promptRoot = obj.Parent
                            and (obj.Parent:FindFirstChild("HumanoidRootPart")
                                 or obj.Parent:IsA("BasePart") and obj.Parent
                                 or obj.Parent:FindFirstChildWhichIsA("BasePart"))

                        if promptRoot then
                            local promptPos = promptRoot:IsA("BasePart") and promptRoot.Position
                                or promptRoot:IsA("Model") and promptRoot:GetPivot().Position
                            if promptPos then
                                local dist = Util.getDistance3D(root.Position, promptPos)
                                if dist <= (obj.MaxActivationDistance + 5) then
                                    fireproximityprompt(obj)
                                end
                            end
                        end
                    end
                end

                -- Strategy 3: Interact with clickable objective parts
                for _, obj in ipairs(CollectionService:GetTagged("Objective") or {}) do
                    if obj:IsA("ClickDetector") then
                        pcall(function()
                            fireclickdetector(obj)
                        end)
                    end
                end
            end)
            task.wait(0.8)
        end
    end)
end

-- 6c. Unlock All Classes
function BondsModule.UnlockAllClasses(enabled)
    State.UnlockAllClasses = enabled
    if not enabled then return end

    pcall(function()
        -- Method 1: Direct data module interception
        local modules = ReplicatedStorage:GetDescendants()
        for _, module in ipairs(modules) do
            if module:IsA("ModuleScript") and
               (module.Name:lower():find("class") or module.Name:lower():find("character")
                or module.Name:lower():find("unlock")) then
                pcall(function()
                    local data = require(module)
                    if type(data) == "table" then
                        -- Recursively unlock
                        local function unlockAll(tbl)
                            for key, val in pairs(tbl) do
                                if type(key) == "string" then
                                    local keyLower = key:lower()
                                    if keyLower:find("unlock") or keyLower:find("locked")
                                       or keyLower:find("available") or keyLower:find("owned") then
                                        if type(val) == "boolean" then
                                            tbl[key] = true
                                        end
                                    end
                                    if keyLower:find("cost") or keyLower:find("price")
                                       or keyLower:find("require") then
                                        if type(val) == "number" then
                                            tbl[key] = 0
                                        end
                                    end
                                end
                                if type(val) == "table" then
                                    unlockAll(val)
                                end
                            end
                        end
                        unlockAll(data)
                    end
                end)
            end
        end

        -- Method 2: Override PlayerData unlock flags
        local playerData = LocalPlayer:FindFirstChild("PlayerData")
            or LocalPlayer:FindFirstChild("Data")
        if playerData then
            for _, child in ipairs(playerData:GetDescendants()) do
                if child:IsA("BoolValue") and
                   (child.Name:lower():find("unlock") or child.Name:lower():find("class")) then
                    child.Value = true
                end
            end
        end

        -- Method 3: Fire unlock remote if it exists
        local unlockRemote = Util.findRemote("UnlockClass")
            or Util.findRemote("PurchaseClass")
            or Util.findRemote("SelectClass")
        if unlockRemote then
            -- Try common class names for Dead Rails
            local classNames = {
                "Gunslinger", "Outlaw", "Sheriff", "Bandit", "Medic",
                "Engineer", "Scout", "Sniper", "Brawler", "Desperado",
                "Bounty Hunter", "Preacher", "Shaman", "Trapper"
            }
            for _, className in ipairs(classNames) do
                pcall(function()
                    unlockRemote:FireServer(className)
                end)
            end
        end
    end)

    Library:Notify({
        Title = "SilentHook",
        Content = "Class unlock spoof applied.",
        Duration = 3
    })
end

-- Bonds Tab UI
do
    local GroupBonds = TabBonds:AddLeftGroupbox("Currency")

    GroupBonds:AddToggle("VisualBonds", {
        Text = "Unlimited Bonds (Visual)",
        Default = false,
        Tooltip = "Overrides local Bond display to 999,999,999"
    }):OnChanged(function()
        BondsModule.SetVisualBonds(Toggles.VisualBonds.Value)
    end)

    GroupBonds:AddToggle("AutoFarmBonds", {
        Text = "Auto-Farm Bonds",
        Default = false,
        Tooltip = "Automates server-side Bond acquisition"
    }):OnChanged(function()
        BondsModule.SetAutoFarm(Toggles.AutoFarmBonds.Value)
    end)

    local GroupClasses = TabBonds:AddRightGroupbox("Progression")

    GroupClasses:AddButton({
        Text = "Unlock All Classes",
        Func = function()
            BondsModule.UnlockAllClasses(true)
        end,
        DoubleClick = false,
        Tooltip = "Spoofs class unlock status locally"
    })
end

-- ═══════════════════════════════════════════════════════════════
-- 7. MODULE: INVENTORY & GEAR LOGIC
-- ═══════════════════════════════════════════════════════════════

local InventoryModule = {}

-- 7a. Get Tommy Gun
function InventoryModule.GetTommyGun()
    pcall(function()
        -- Search for weapon acquisition remotes
        local weaponRemotes = {
            "GiveWeapon", "EquipWeapon", "AcquireWeapon",
            "BuyWeapon", "PickupWeapon", "SpawnWeapon",
            "GiveItem", "AddItem", "GrantItem"
        }

        local fired = false
        for _, remoteName in ipairs(weaponRemotes) do
            local remote = Util.findRemote(remoteName)
            if remote then
                pcall(function()
                    remote:FireServer("Tommy Gun")
                    remote:FireServer("TommyGun")
                    remote:FireServer("tommygun")
                    fired = true
                end)
            end

            local remoteFunc = Util.findRemote(remoteName, "RemoteFunction")
            if remoteFunc then
                pcall(function()
                    remoteFunc:InvokeServer("Tommy Gun")
                    remoteFunc:InvokeServer("TommyGun")
                    fired = true
                end)
            end
        end

        -- Alternative: Clone from ReplicatedStorage weapon assets
        if not fired then
            for _, item in ipairs(ReplicatedStorage:GetDescendants()) do
                if item:IsA("Tool") and
                   (item.Name:lower():find("tommy") or item.Name:lower():find("thompson")) then
                    local clone = item:Clone()
                    clone.Parent = LocalPlayer.Backpack
                    fired = true
                    break
                end
            end
        end

        if fired then
            Library:Notify({Title = "SilentHook", Content = "Tommy Gun acquisition triggered.", Duration = 3})
        else
            Library:Notify({Title = "SilentHook", Content = "Tommy Gun remote not found — asset may be named differently.", Duration = 4})
        end
    end)
end

-- 7b. Instant Interaction (ProximityPrompt)
function InventoryModule.SetInstantInteraction(enabled)
    State.InstantInteraction = enabled

    local function processPrompt(prompt)
        if not prompt:IsA("ProximityPrompt") then return end
        if enabled then
            if not prompt:GetAttribute("_SH_OrigDuration") then
                prompt:SetAttribute("_SH_OrigDuration", prompt.HoldDuration)
            end
            prompt.HoldDuration = 0
        else
            local orig = prompt:GetAttribute("_SH_OrigDuration")
            if orig then
                prompt.HoldDuration = orig
            end
        end
    end

    -- Process all existing prompts
    for _, prompt in ipairs(Workspace:GetDescendants()) do
        pcall(processPrompt, prompt)
    end

    -- Watch for new prompts
    if enabled then
        Util.safeConnect(Workspace.DescendantAdded, function(desc)
            if State.InstantInteraction then
                task.defer(processPrompt, desc)
            end
        end)
    end
end

-- 7c. Auto-Loot
function InventoryModule.SetAutoLoot(enabled)
    State.AutoLoot = enabled
    if not enabled then return end

    Util.createThread("AutoLoot", function()
        while State.AutoLoot and State._running do
            pcall(function()
                local character = LocalPlayer.Character
                local root = Util.getCharacterRoot(character)
                if not root or not Util.isAlive(character) then return end

                local AUTO_LOOT_RADIUS = 50

                -- Method 1: Fire collect remotes
                local collectRemotes = {
                    "Collect", "Loot", "PickUp", "Pickup", "Grab",
                    "CollectItem", "LootItem", "GatherItem"
                }
                for _, remoteName in ipairs(collectRemotes) do
                    local remote = Util.findRemote(remoteName)
                    if remote then
                        -- Try to identify nearby lootable objects
                        for _, obj in ipairs(Workspace:GetDescendants()) do
                            if (obj:IsA("BasePart") or obj:IsA("Model")) and
                               (obj.Name:lower():find("loot") or obj.Name:lower():find("crate")
                                or obj.Name:lower():find("chest") or obj.Name:lower():find("drop")
                                or obj.Name:lower():find("pickup") or obj.Name:lower():find("item")
                                or obj:FindFirstChildWhichIsA("ProximityPrompt")) then

                                local pos = obj:IsA("BasePart") and obj.Position
                                    or obj:IsA("Model") and obj:GetPivot().Position
                                if pos and Util.getDistance3D(root.Position, pos) <= AUTO_LOOT_RADIUS then
                                    pcall(function()
                                        remote:FireServer(obj)
                                        remote:FireServer(obj.Name)
                                    end)
                                end
                            end
                        end
                    end
                end

                -- Method 2: Auto-fire nearby ProximityPrompts related to looting
                for _, prompt in ipairs(Workspace:GetDescendants()) do
                    if prompt:IsA("ProximityPrompt") and prompt.Enabled then
                        local promptParent = prompt.Parent
                        local promptName = (prompt.ActionText or ""):lower()
                        local parentName = promptParent and promptParent.Name:lower() or ""

                        local isLootPrompt = promptName:find("loot")
                            or promptName:find("collect")
                            or promptName:find("pick")
                            or promptName:find("grab")
                            or promptName:find("take")
                            or parentName:find("loot")
                            or parentName:find("crate")
                            or parentName:find("chest")
                            or parentName:find("drop")

                        if isLootPrompt then
                            local promptPos
                            if promptParent:IsA("BasePart") then
                                promptPos = promptParent.Position
                            elseif promptParent:IsA("Model") then
                                promptPos = promptParent:GetPivot().Position
                            elseif promptParent.Parent and promptParent.Parent:FindFirstChildWhichIsA("BasePart") then
                                promptPos = promptParent.Parent:FindFirstChildWhichIsA("BasePart").Position
                            end

                            if promptPos and Util.getDistance3D(root.Position, promptPos) <= AUTO_LOOT_RADIUS then
                                pcall(fireproximityprompt, prompt)
                            end
                        end
                    end
                end

                -- Method 3: Auto-collect dropped tools
                for _, tool in ipairs(Workspace:GetChildren()) do
                    if tool:IsA("Tool") then
                        local handle = tool:FindFirstChild("Handle")
                        if handle and Util.getDistance3D(root.Position, handle.Position) <= AUTO_LOOT_RADIUS then
                            pcall(function()
                                tool.Parent = LocalPlayer.Backpack
                            end)
                        end
                    end
                end
            end)
            task.wait(0.3)
        end
    end)
end

-- Inventory Tab UI
do
    local GroupGear = TabInventory:AddLeftGroupbox("Gear")

    GroupGear:AddButton({
        Text = "Get Tommy Gun",
        Func = function()
            InventoryModule.GetTommyGun()
        end,
        DoubleClick = false,
        Tooltip = "Triggers weapon acquisition for Tommy Gun"
    })

    GroupGear:AddToggle("InstantInteract", {
        Text = "Instant Interaction",
        Default = false,
        Tooltip = "Sets all ProximityPrompt hold durations to 0"
    }):OnChanged(function()
        InventoryModule.SetInstantInteraction(Toggles.InstantInteract.Value)
    end)

    GroupGear:AddToggle("AutoLoot", {
        Text = "Auto-Loot",
        Default = false,
        Tooltip = "Automatically collects nearby lootable items"
    }):OnChanged(function()
        InventoryModule.SetAutoLoot(Toggles.AutoLoot.Value)
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- 8. MODULE: COMBAT & SURVIVAL (THE "HOOK" LAYER)
-- ═══════════════════════════════════════════════════════════════

local CombatModule = {}

-- 8a. Target Acquisition for Silent Aim
function CombatModule.GetClosestTarget()
    local character = LocalPlayer.Character
    local root = Util.getCharacterRoot(character)
    if not root then return nil, nil end

    local bestTarget = nil
    local bestDist = math.huge
    local bestPart = nil
    local center = Util.screenCenter()

    -- Check players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not Util.isTeammate(player) then
            local char = player.Character
            if char and Util.isAlive(char) then
                local targetPart = char:FindFirstChild(State.SilentAimTarget)
                    or char:FindFirstChild("Head")
                    or Util.getCharacterRoot(char)

                if targetPart then
                    local inFov, dist = Util.isInFOV(targetPart.Position, State.SilentAimFOV)
                    if inFov and dist < bestDist then
                        bestDist = dist
                        bestTarget = player
                        bestPart = targetPart
                    end
                end
            end
        end
    end

    -- Check NPCs (hostile entities in workspace)
    local npcContainers = {
        Workspace:FindFirstChild("NPCs"),
        Workspace:FindFirstChild("Enemies"),
        Workspace:FindFirstChild("Mobs"),
        Workspace:FindFirstChild("Zombies"),
        Workspace:FindFirstChild("Entities"),
        Workspace:FindFirstChild("AI"),
    }

    for _, container in ipairs(npcContainers) do
        if container then
            for _, npc in ipairs(container:GetChildren()) do
                if npc:IsA("Model") and Util.isAlive(npc) then
                    local targetPart = npc:FindFirstChild(State.SilentAimTarget)
                        or npc:FindFirstChild("Head")
                        or Util.getCharacterRoot(npc)

                    if targetPart then
                        local inFov, dist = Util.isInFOV(targetPart.Position, State.SilentAimFOV)
                        if inFov and dist < bestDist then
                            bestDist = dist
                            bestTarget = npc
                            bestPart = targetPart
                        end
                    end
                end
            end
        end
    end

    return bestTarget, bestPart
end

-- 8b. FOV Circle Drawing
local FOVCircle = Drawing.new("Circle")
FOVCircle.Thickness  = 1.5
FOVCircle.NumSides   = 64
FOVCircle.Radius     = State.SilentAimFOV
FOVCircle.Filled     = false
FOVCircle.Visible    = false
FOVCircle.Color      = Color3.fromRGB(255, 50, 50)
FOVCircle.Transparency = 0.7
table.insert(State._drawings, FOVCircle)

-- 8c. Silent Aim — __namecall Hook
do
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = {...}

        if State.SilentAim and State._running then
            if method == "FireServer" or method == "InvokeServer" then
                local remoteName = self.Name:lower()

                -- Detect weapon-fire remotes
                local isFireRemote = remoteName:find("fire")
                    or remoteName:find("shoot")
                    or remoteName:find("attack")
                    or remoteName:find("hit")
                    or remoteName:find("damage")
                    or remoteName:find("projectile")
                    or remoteName:find("bullet")
                    or remoteName:find("weapon")
                    or remoteName:find("gun")
                    or remoteName:find("ray")
                    or remoteName:find("cast")

                if isFireRemote then
                    local _, targetPart = CombatModule.GetClosestTarget()

                    if targetPart then
                        -- Mutate arguments to redirect to target
                        for i, arg in ipairs(args) do
                            if typeof(arg) == "Vector3" then
                                -- Replace position/direction vectors
                                local myRoot = Util.getCharacterRoot(LocalPlayer.Character)
                                if myRoot then
                                    local direction = (targetPart.Position - myRoot.Position).Unit
                                    args[i] = targetPart.Position
                                    -- Check if next arg could be a direction
                                    if args[i + 1] and typeof(args[i + 1]) == "Vector3" then
                                        args[i + 1] = direction
                                    end
                                end
                            elseif typeof(arg) == "CFrame" then
                                args[i] = CFrame.new(targetPart.Position)
                            elseif typeof(arg) == "table" then
                                -- Deep-replace position data in tables
                                local function redirectTable(t)
                                    for k, v in pairs(t) do
                                        local kLower = type(k) == "string" and k:lower() or ""
                                        if typeof(v) == "Vector3" then
                                            if kLower:find("pos") or kLower:find("origin")
                                               or kLower:find("target") or kLower:find("hit")
                                               or kLower:find("end") or kLower:find("point") then
                                                t[k] = targetPart.Position
                                            elseif kLower:find("dir") or kLower:find("normal") then
                                                local myRoot = Util.getCharacterRoot(LocalPlayer.Character)
                                                if myRoot then
                                                    t[k] = (targetPart.Position - myRoot.Position).Unit
                                                end
                                            end
                                        elseif typeof(v) == "CFrame" then
                                            t[k] = CFrame.new(targetPart.Position)
                                        elseif typeof(v) == "Instance" then
                                            if kLower:find("part") or kLower:find("target")
                                               or kLower:find("hit") then
                                                t[k] = targetPart
                                            end
                                        elseif type(v) == "table" then
                                            redirectTable(v)
                                        end
                                    end
                                end
                                redirectTable(arg)
                                args[i] = arg
                            elseif typeof(arg) == "Instance" and arg:IsA("BasePart") then
                                -- Replace target part references
                                args[i] = targetPart
                            end
                        end

                        return oldNamecall(self, unpack(args))
                    end
                end

                -- 8d. No Recoil / No Spread
                if State.NoRecoilSpread then
                    local isRecoilRemote = remoteName:find("recoil")
                        or remoteName:find("spread")
                        or remoteName:find("accuracy")
                        or remoteName:find("sway")
                        or remoteName:find("bloom")
                        or remoteName:find("kick")

                    if isRecoilRemote then
                        -- Zero out all numeric arguments (spread/recoil values)
                        for i, arg in ipairs(args) do
                            if type(arg) == "number" then
                                args[i] = 0
                            elseif typeof(arg) == "Vector3" then
                                args[i] = Vector3.zero
                            elseif typeof(arg) == "Vector2" then
                                args[i] = Vector2.zero
                            elseif type(arg) == "table" then
                                local function zeroTable(t)
                                    for k, v in pairs(t) do
                                        local kLower = type(k) == "string" and k:lower() or ""
                                        if type(v) == "number" and
                                           (kLower:find("recoil") or kLower:find("spread")
                                            or kLower:find("kick") or kLower:find("bloom")
                                            or kLower:find("sway") or kLower:find("deviation")) then
                                            t[k] = 0
                                        elseif type(v) == "table" then
                                            zeroTable(v)
                                        end
                                    end
                                end
                                zeroTable(arg)
                            end
                        end
                        return oldNamecall(self, unpack(args))
                    end

                    -- Also intercept weapon config remotes for spread/recoil data
                    if isFireRemote then
                        for i, arg in ipairs(args) do
                            if type(arg) == "table" then
                                local function stripRecoil(t)
                                    for k, v in pairs(t) do
                                        local kLower = type(k) == "string" and k:lower() or ""
                                        if type(v) == "number" then
                                            if kLower:find("spread") or kLower:find("recoil")
                                               or kLower:find("bloom") or kLower:find("deviation")
                                               or kLower:find("kick") or kLower:find("sway")
                                               or kLower:find("inaccuracy") then
                                                t[k] = 0
                                            end
                                        elseif typeof(v) == "Vector3" then
                                            if kLower:find("recoil") or kLower:find("kick") then
                                                t[k] = Vector3.zero
                                            end
                                        elseif type(v) == "table" then
                                            stripRecoil(v)
                                        end
                                    end
                                end
                                stripRecoil(arg)
                            end
                        end
                    end
                end
            end
        end

        return oldNamecall(self, ...)
    end))

    -- Store original for cleanup
    State._originals.__namecall = oldNamecall
end

-- 8e. No Recoil — Also hook weapon modules client-side
function CombatModule.SetNoRecoilSpread(enabled)
    State.NoRecoilSpread = enabled
    if not enabled then return end

    pcall(function()
        -- Find and modify weapon config modules
        for _, module in ipairs(ReplicatedStorage:GetDescendants()) do
            if module:IsA("ModuleScript") and
               (module.Name:lower():find("weapon") or module.Name:lower():find("gun")
                or module.Name:lower():find("firearm") or module.Name:lower():find("config")) then
                pcall(function()
                    local config = require(module)
                    if type(config) == "table" then
                        local function zeroRecoil(t)
                            for k, v in pairs(t) do
                                local kLower = type(k) == "string" and k:lower() or ""
                                if type(v) == "number" then
                                    if kLower:find("recoil") or kLower:find("spread")
                                       or kLower:find("bloom") or kLower:find("kick")
                                       or kLower:find("sway") or kLower:find("deviation")
                                       or kLower:find("inaccuracy") then
                                        t[k] = 0
                                    end
                                elseif typeof(v) == "Vector3" then
                                    if kLower:find("recoil") or kLower:find("kick") then
                                        t[k] = Vector3.zero
                                    end
                                elseif type(v) == "table" then
                                    zeroRecoil(v)
                                end
                            end
                        end
                        zeroRecoil(config)
                    end
                end)
            end
        end
    end)
end

-- 8f. Survival Freeze
function CombatModule.SetSurvivalFreeze(enabled)
    State.SurvivalFreeze = enabled
    if not enabled then return end

    Util.createThread("SurvivalFreeze", function()
        while State.SurvivalFreeze and State._running do
            pcall(function()
                -- Search common survival stat locations
                local statContainers = {
                    LocalPlayer:FindFirstChild("PlayerData"),
                    LocalPlayer:FindFirstChild("Data"),
                    LocalPlayer:FindFirstChild("Stats"),
                    LocalPlayer:FindFirstChild("Survival"),
                    LocalPlayer:FindFirstChild("leaderstats"),
                }

                local character = LocalPlayer.Character
                if character then
                    table.insert(statContainers, character:FindFirstChild("Stats"))
                    table.insert(statContainers, character:FindFirstChild("Survival"))
                    table.insert(statContainers, character:FindFirstChild("PlayerData"))
                end

                local survivalNames = {
                    "hunger", "thirst", "stamina", "energy",
                    "food", "water", "fatigue", "health",
                    "hydration", "nutrition", "endurance"
                }

                for _, container in ipairs(statContainers) do
                    if container then
                        for _, child in ipairs(container:GetDescendants()) do
                            if child:IsA("ValueBase") then
                                local nameLower = child.Name:lower()
                                for _, statName in ipairs(survivalNames) do
                                    if nameLower:find(statName) then
                                        if child:IsA("IntValue") or child:IsA("NumberValue") then
                                            -- Set to max (assume 100 as standard max)
                                            local maxVal = 100
                                            -- Try to find corresponding max value
                                            local maxChild = container:FindFirstChild("Max" .. child.Name)
                                                or container:FindFirstChild(child.Name .. "Max")
                                            if maxChild and maxChild:IsA("ValueBase") then
                                                maxVal = maxChild.Value
                                            end
                                            child.Value = maxVal
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- Also try to freeze via Humanoid properties
                if character then
                    local humanoid = character:FindFirstChildOfClass("Humanoid")
                    if humanoid then
                        -- Some games use custom properties on humanoid
                        pcall(function()
                            if humanoid:GetAttribute("Hunger") then
                                humanoid:SetAttribute("Hunger", 100)
                            end
                            if humanoid:GetAttribute("Thirst") then
                                humanoid:SetAttribute("Thirst", 100)
                            end
                            if humanoid:GetAttribute("Stamina") then
                                humanoid:SetAttribute("Stamina", 100)
                            end
                        end)
                    end
                end

                -- Override attribute-based survival systems
                if character then
                    for _, statName in ipairs(survivalNames) do
                        pcall(function()
                            local attrVal = character:GetAttribute(statName)
                                or character:GetAttribute(statName:sub(1,1):upper() .. statName:sub(2))
                            if attrVal and type(attrVal) == "number" then
                                character:SetAttribute(statName, 100)
                                character:SetAttribute(
                                    statName:sub(1,1):upper() .. statName:sub(2), 100
                                )
                            end
                        end)
                    end
                end
            end)
            task.wait(0.25)
        end
    end)
end

-- Combat Tab UI
do
    local GroupAim = TabCombat:AddLeftGroupbox("Aim Assist")

    GroupAim:AddToggle("SilentAim", {
        Text = "Silent Aim",
        Default = false,
        Tooltip = "Redirects projectiles to nearest target's head"
    }):OnChanged(function()
        State.SilentAim = Toggles.SilentAim.Value
        FOVCircle.Visible = Toggles.SilentAim.Value
    end)

    GroupAim:AddSlider("SilentAimFOV", {
        Text = "FOV Radius",
        Default = 250,
        Min = 50,
        Max = 800,
        Rounding = 0,
        Compact = false,
    }):OnChanged(function()
        State.SilentAimFOV = Options.SilentAimFOV.Value
        FOVCircle.Radius = State.SilentAimFOV
    end)

    GroupAim:AddDropdown("AimTarget", {
        Values = {"Head", "HumanoidRootPart", "UpperTorso", "Torso"},
        Default = 1,
        Multi = false,
        Text = "Target Part",
    }):OnChanged(function()
        State.SilentAimTarget = Options.AimTarget.Value
    end)

    local GroupWeapon = TabCombat:AddRightGroupbox("Weapon Mods")

    GroupWeapon:AddToggle("NoRecoil", {
        Text = "No Recoil / No Spread",
        Default = false,
        Tooltip = "Zeroes out spread and recoil coefficients"
    }):OnChanged(function()
        CombatModule.SetNoRecoilSpread(Toggles.NoRecoil.Value)
    end)

    local GroupSurvival = TabCombat:AddRightGroupbox("Survival")

    GroupSurvival:AddToggle("SurvivalFreeze", {
        Text = "Freeze Survival Stats",
        Default = false,
        Tooltip = "Locks Hunger, Thirst, Stamina at maximum"
    }):OnChanged(function()
        CombatModule.SetSurvivalFreeze(Toggles.SurvivalFreeze.Value)
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- 9. MODULE: VISUALS (Drawing API ESP)
-- ═══════════════════════════════════════════════════════════════

local VisualsModule = {}

-- ESP Data Store
local ESPObjects = {} -- [instance] = {drawings}

-- ESP Color Palette
local ESP_COLORS = {
    Player     = Color3.fromRGB(255, 80, 80),
    Teammate   = Color3.fromRGB(80, 255, 80),
    NPC        = Color3.fromRGB(255, 200, 50),
    Extraction = Color3.fromRGB(50, 200, 255),
    LootCrate  = Color3.fromRGB(255, 150, 255),
}

-- Create ESP drawing set for an entity
function VisualsModule.CreateESPSet()
    local set = {}

    set.BoxOutline = Drawing.new("Square")
    set.BoxOutline.Thickness = 3
    set.BoxOutline.Color = Color3.new(0, 0, 0)
    set.BoxOutline.Filled = false
    set.BoxOutline.Visible = false
    table.insert(State._drawings, set.BoxOutline)

    set.Box = Drawing.new("Square")
    set.Box.Thickness = 1.5
    set.Box.Filled = false
    set.Box.Visible = false
    table.insert(State._drawings, set.Box)

    set.Name = Drawing.new("Text")
    set.Name.Size = 14
    set.Name.Center = true
    set.Name.Outline = true
    set.Name.Visible = false
    table.insert(State._drawings, set.Name)

    set.Distance = Drawing.new("Text")
    set.Distance.Size = 13
    set.Distance.Center = true
    set.Distance.Outline = true
    set.Distance.Visible = false
    table.insert(State._drawings, set.Distance)

    set.HealthBarBG = Drawing.new("Square")
    set.HealthBarBG.Thickness = 1
    set.HealthBarBG.Filled = true
    set.HealthBarBG.Color = Color3.new(0, 0, 0)
    set.HealthBarBG.Transparency = 0.5
    set.HealthBarBG.Visible = false
    table.insert(State._drawings, set.HealthBarBG)

    set.HealthBar = Drawing.new("Square")
    set.HealthBar.Thickness = 1
    set.HealthBar.Filled = true
    set.HealthBar.Visible = false
    table.insert(State._drawings, set.HealthBar)

    set.Tracer = Drawing.new("Line")
    set.Tracer.Thickness = 1
    set.Tracer.Visible = false
    table.insert(State._drawings, set.Tracer)

    return set
end

function VisualsModule.HideESPSet(set)
    for _, drawing in pairs(set) do
        if drawing and drawing.Visible ~= nil then
            drawing.Visible = false
        end
    end
end

function VisualsModule.DestroyESPSet(set)
    for _, drawing in pairs(set) do
        pcall(function()
            drawing:Remove()
        end)
    end
end

function VisualsModule.UpdateESP(entity, set, label, color, isCharacter)
    local root = nil
    local head = nil
    local humanoid = nil

    if isCharacter then
        root = Util.getCharacterRoot(entity)
        head = entity:FindFirstChild("Head")
        humanoid = entity:FindFirstChildOfClass("Humanoid")
        if not root or not humanoid or humanoid.Health <= 0 then
            VisualsModule.HideESPSet(set)
            return
        end
    else
        -- For non-character entities (extraction points, loot crates)
        if entity:IsA("BasePart") then
            root = entity
        elseif entity:IsA("Model") then
            root = entity.PrimaryPart or entity:FindFirstChildWhichIsA("BasePart")
        end
        if not root then
            VisualsModule.HideESPSet(set)
            return
        end
    end

    local myRoot = Util.getCharacterRoot(LocalPlayer.Character)
    if not myRoot then
        VisualsModule.HideESPSet(set)
        return
    end

    local dist3D = Util.getDistance3D(myRoot.Position, root.Position)
    if dist3D > State.ESP_MaxDistance then
        VisualsModule.HideESPSet(set)
        return
    end

    local screenPos, onScreen, depth = Util.worldToScreen(root.Position)
    if not onScreen or depth < 0 then
        VisualsModule.HideESPSet(set)
        return
    end

    -- Dynamic sizing based on distance
    local scaleFactor = 1 / (depth * math.tan(math.rad(Camera.FieldOfView / 2)) * 2 / Camera.ViewportSize.Y)
    local boxHeight = math.clamp(scaleFactor * 5.5, 15, 600)
    local boxWidth = boxHeight * 0.55

    -- Box position (centered on screen position, offset upward)
    local boxPos = Vector2.new(screenPos.X - boxWidth / 2, screenPos.Y - boxHeight / 1.5)

    -- Box
    set.Box.Size = Vector2.new(boxWidth, boxHeight)
    set.Box.Position = boxPos
    set.Box.Color = color
    set.Box.Visible = true

    set.BoxOutline.Size = Vector2.new(boxWidth + 2, boxHeight + 2)
    set.BoxOutline.Position = boxPos - Vector2.new(1, 1)
    set.BoxOutline.Visible = true

    -- Name
    set.Name.Position = Vector2.new(screenPos.X, boxPos.Y - 16)
    set.Name.Text = label
    set.Name.Color = color
    set.Name.Visible = true

    -- Distance
    if State.ESP_ShowDistance then
        set.Distance.Position = Vector2.new(screenPos.X, boxPos.Y + boxHeight + 2)
        set.Distance.Text = ("[%d studs]"):format(dist3D)
        set.Distance.Color = Color3.new(1, 1, 1)
        set.Distance.Visible = true
    else
        set.Distance.Visible = false
    end

    -- Health bar (only for characters)
    if isCharacter and humanoid and State.ESP_ShowHealth then
        local healthPct = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
        local barWidth = 3
        local barX = boxPos.X - barWidth - 3

        set.HealthBarBG.Position = Vector2.new(barX, boxPos.Y)
        set.HealthBarBG.Size = Vector2.new(barWidth, boxHeight)
        set.HealthBarBG.Visible = true

        local barHeight = boxHeight * healthPct
        set.HealthBar.Position = Vector2.new(barX, boxPos.Y + (boxHeight - barHeight))
        set.HealthBar.Size = Vector2.new(barWidth, barHeight)
        set.HealthBar.Color = Color3.fromRGB(
            255 * (1 - healthPct),
            255 * healthPct,
            0
        )
        set.HealthBar.Visible = true
    else
        set.HealthBarBG.Visible = false
        set.HealthBar.Visible = false
    end

    -- Tracer
    set.Tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
    set.Tracer.To = Vector2.new(screenPos.X, boxPos.Y + boxHeight)
    set.Tracer.Color = color
    set.Tracer.Visible = true
end

-- ESP Render Loop
Util.safeConnect(RunService.RenderStepped, function()
    if not State._running then return end

    -- Update FOV circle position
    if State.SilentAim then
        FOVCircle.Position = Util.screenCenter()
        FOVCircle.Radius = State.SilentAimFOV
    end

    -- Player ESP
    if State.ESP_Players then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                local key = "player_" .. player.UserId
                if not ESPObjects[key] then
                    ESPObjects[key] = VisualsModule.CreateESPSet()
                end

                local color = Util.isTeammate(player)
                    and ESP_COLORS.Teammate
                    or ESP_COLORS.Player
                local label = player.DisplayName or player.Name

                VisualsModule.UpdateESP(
                    player.Character,
                    ESPObjects[key],
                    label,
                    color,
                    true
                )
            end
        end
    else
        -- Hide all player ESP
        for key, set in pairs(ESPObjects) do
            if key:sub(1, 7) == "player_" then
                VisualsModule.HideESPSet(set)
            end
        end
    end

    -- NPC ESP
    if State.ESP_NPCs then
        local npcContainers = {
            Workspace:FindFirstChild("NPCs"),
            Workspace:FindFirstChild("Enemies"),
            Workspace:FindFirstChild("Mobs"),
            Workspace:FindFirstChild("Zombies"),
            Workspace:FindFirstChild("Entities"),
            Workspace:FindFirstChild("AI"),
        }

        for _, container in ipairs(npcContainers) do
            if container then
                for _, npc in ipairs(container:GetChildren()) do
                    if npc:IsA("Model") and npc:FindFirstChildOfClass("Humanoid") then
                        local key = "npc_" .. npc:GetFullName()
                        if not ESPObjects[key] then
                            ESPObjects[key] = VisualsModule.CreateESPSet()
                        end
                        VisualsModule.UpdateESP(
                            npc,
                            ESPObjects[key],
                            npc.Name,
                            ESP_COLORS.NPC,
                            true
                        )
                    end
                end
            end
        end
    else
        for key, set in pairs(ESPObjects) do
            if key:sub(1, 4) == "npc_" then
                VisualsModule.HideESPSet(set)
            end
        end
    end

    -- Extraction Point ESP
    if State.ESP_Extraction then
        local extractionContainers = {
            Workspace:FindFirstChild("Extraction"),
            Workspace:FindFirstChild("ExtractionPoints"),
            Workspace:FindFirstChild("Extract"),
            Workspace:FindFirstChild("Exits"),
            Workspace:FindFirstChild("Escape"),
        }

        -- Also search by tag
        local taggedExtractions = {}
        pcall(function()
            taggedExtractions = CollectionService:GetTagged("Extraction")
        end)

        local allExtractions = {}

        for _, container in ipairs(extractionContainers) do
            if container then
                for _, point in ipairs(container:GetChildren()) do
                    table.insert(allExtractions, point)
                end
            end
        end
        for _, point in ipairs(taggedExtractions) do
            table.insert(allExtractions, point)
        end

        -- Fallback: search by name pattern
        if #allExtractions == 0 then
            for _, obj in ipairs(Workspace:GetDescendants()) do
                local nameLower = obj.Name:lower()
                if (nameLower:find("extract") or nameLower:find("escape")
                    or nameLower:find("exit") or nameLower:find("evac")) and
                   (obj:IsA("BasePart") or obj:IsA("Model")) then
                    table.insert(allExtractions, obj)
                end
            end
        end

        for i, point in ipairs(allExtractions) do
            local key = "extract_" .. tostring(i) .. "_" .. point.Name
            if not ESPObjects[key] then
                ESPObjects[key] = VisualsModule.CreateESPSet()
            end
            VisualsModule.UpdateESP(
                point,
                ESPObjects[key],
                "🚁 " .. point.Name,
                ESP_COLORS.Extraction,
                false
            )
        end
    else
        for key, set in pairs(ESPObjects) do
            if key:sub(1, 8) == "extract_" then
                VisualsModule.HideESPSet(set)
            end
        end
    end

    -- Loot Crate ESP
    if State.ESP_LootCrates then
        local lootItems = {}

        -- Search by common naming conventions
        for _, obj in ipairs(Workspace:GetDescendants()) do
            local nameLower = obj.Name:lower()
            if (nameLower:find("crate") or nameLower:find("chest")
                or nameLower:find("loot") or nameLower:find("supply")
                or nameLower:find("treasure") or nameLower:find("rare")
                or nameLower:find("legendary") or nameLower:find("stash")) and
               (obj:IsA("BasePart") or obj:IsA("Model")) then

                -- Prioritize "high-tier" indicators
                local isHighTier = nameLower:find("rare")
                    or nameLower:find("legendary")
                    or nameLower:find("epic")
                    or nameLower:find("golden")
                    or nameLower:find("premium")
                    or nameLower:find("military")
                    or (obj:GetAttribute("Tier") and obj:GetAttribute("Tier") >= 3)

                table.insert(lootItems, {obj = obj, highTier = isHighTier})
            end
        end

        -- Also check tagged objects
        pcall(function()
            for _, obj in ipairs(CollectionService:GetTagged("Loot")) do
                table.insert(lootItems, {obj = obj, highTier = false})
            end
            for _, obj in ipairs(CollectionService:GetTagged("HighTierLoot")) do
                table.insert(lootItems, {obj = obj, highTier = true})
            end
        end)

        for i, item in ipairs(lootItems) do
            local key = "loot_" .. tostring(i) .. "_" .. item.obj.Name
            if not ESPObjects[key] then
                ESPObjects[key] = VisualsModule.CreateESPSet()
            end

            local prefix = item.highTier and "⭐ " or "📦 "
            local color = item.highTier
                and Color3.fromRGB(255, 215, 0) -- Gold for high-tier
                or ESP_COLORS.LootCrate

            VisualsModule.UpdateESP(
                item.obj,
                ESPObjects[key],
                prefix .. item.obj.Name,
                color,
                false
            )
        end
    else
        for key, set in pairs(ESPObjects) do
            if key:sub(1, 5) == "loot_" then
                VisualsModule.HideESPSet(set)
            end
        end
    end

    -- Clean up ESP for removed instances
    for key, set in pairs(ESPObjects) do
        -- Check if the source entity still exists
        local entityType = key:match("^(%a+)_")
        local shouldClean = false

        if entityType == "player" then
            local userId = tonumber(key:match("player_(%d+)"))
            if userId then
                local player = Players:GetPlayerByUserId(userId)
                shouldClean = not player or not player.Character
            end
        end
        -- NPCs and world objects get cleaned if they become invalid
        -- (handled by the UpdateESP hiding mechanism)

        if shouldClean then
            VisualsModule.HideESPSet(set)
        end
    end
end)

-- Visuals Tab UI
do
    local GroupESP = TabVisuals:AddLeftGroupbox("ESP Toggles")

    GroupESP:AddToggle("ESP_Players", {
        Text = "Player ESP",
        Default = false,
        Tooltip = "Show boxes, names, health, and tracers for all players"
    }):OnChanged(function()
        State.ESP_Players = Toggles.ESP_Players.Value
    end)

    GroupESP:AddToggle("ESP_NPCs", {
        Text = "NPC ESP",
        Default = false,
        Tooltip = "Show ESP for NPCs and enemies"
    }):OnChanged(function()
        State.ESP_NPCs = Toggles.ESP_NPCs.Value
    end)

    GroupESP:AddToggle("ESP_Extraction", {
        Text = "Extraction Point ESP",
        Default = false,
        Tooltip = "Highlight extraction/exit locations"
    }):OnChanged(function()
        State.ESP_Extraction = Toggles.ESP_Extraction.Value
    end)

    GroupESP:AddToggle("ESP_LootCrates", {
        Text = "Loot Crate ESP",
        Default = false,
        Tooltip = "Highlight loot containers and high-tier crates"
    }):OnChanged(function()
        State.ESP_LootCrates = Toggles.ESP_LootCrates.Value
    end)

    local GroupESPOpts = TabVisuals:AddRightGroupbox("ESP Options")

    GroupESPOpts:AddToggle("ESP_ShowDistance", {
        Text = "Show Distance",
        Default = true,
    }):OnChanged(function()
        State.ESP_ShowDistance = Toggles.ESP_ShowDistance.Value
    end)

    GroupESPOpts:AddToggle("ESP_ShowHealth", {
        Text = "Show Health Bar",
        Default = true,
    }):OnChanged(function()
        State.ESP_ShowHealth = Toggles.ESP_ShowHealth.Value
    end)

    GroupESPOpts:AddSlider("ESP_MaxDistance", {
        Text = "Max ESP Distance",
        Default = 2000,
        Min = 100,
        Max = 5000,
        Rounding = 0,
        Compact = false,
    }):OnChanged(function()
        State.ESP_MaxDistance = Options.ESP_MaxDistance.Value
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- 10. MODULE: LIFECYCLE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════

local LifecycleModule = {}

function LifecycleModule.FullCleanup()
    warn("[SilentHook] Initiating full cleanup...")

    -- 1. Stop all running state
    State._running = false
    State.UnlimitedBondsVisual = false
    State.AutoFarmBonds = false
    State.SilentAim = false
    State.NoRecoilSpread = false
    State.SurvivalFreeze = false
    State.InstantInteraction = false
    State.AutoLoot = false
    State.ESP_Players = false
    State.ESP_NPCs = false
    State.ESP_Extraction = false
    State.ESP_LootCrates = false

    -- 2. Disconnect all connections
    for _, conn in ipairs(State._connections) do
        pcall(function()
            if conn and conn.Connected then
                conn:Disconnect()
            end
        end)
    end
    State._connections = {}

    -- 3. Restore original metatables
    if State._originals.__namecall then
        pcall(function()
            hookmetamethod(game, "__namecall", State._originals.__namecall)
        end)
    end

    -- 4. Restore ProximityPrompts
    for _, prompt in ipairs(Workspace:GetDescendants()) do
        if prompt:IsA("ProximityPrompt") then
            pcall(function()
                local orig = prompt:GetAttribute("_SH_OrigDuration")
                if orig then
                    prompt.HoldDuration = orig
                    prompt:SetAttribute("_SH_OrigDuration", nil)
                end
            end)
        end
    end

    -- 5. Destroy all Drawing API objects
    for _, drawing in ipairs(State._drawings) do
        pcall(function()
            drawing:Remove()
        end)
    end
    State._drawings = {}

    -- Destroy ESP object sets
    for key, set in pairs(ESPObjects) do
        VisualsModule.DestroyESPSet(set)
    end
    ESPObjects = {}

    -- FOV circle
    pcall(function()
        FOVCircle:Remove()
    end)

    -- 6. Cancel threads
    for name, thread in pairs(State._threads) do
        pcall(function()
            task.cancel(thread)
        end)
    end
    State._threads = {}

    -- 7. Destroy Linoria UI
    pcall(function()
        Library:Unload()
    end)

    -- 8. Clear global reference
    if getgenv then
        getgenv()[FRAMEWORK_ID] = nil
    end

    warn("[SilentHook] Cleanup complete — all hooks, drawings, and UI destroyed.")
end

-- Settings Tab UI
do
    local GroupConfig = TabSettings:AddLeftGroupbox("Configuration")

    SaveManager:SetLibrary(Library)
    ThemeManager:SetLibrary(Library)
    SaveManager:SetFolder("SilentHook/Dead_Rails")
    ThemeManager:SetFolder("SilentHook")

    SaveManager:BuildConfigSection(TabSettings)
    ThemeManager:ApplyToTab(TabSettings)

    local GroupLifecycle = TabSettings:AddRightGroupbox("Lifecycle")

    GroupLifecycle:AddButton({
        Text = "🧹 Clean Up (Full Unload)",
        Func = function()
            LifecycleModule.FullCleanup()
        end,
        DoubleClick = true,
        Tooltip = "Restores metatables, destroys UI, clears all drawings (double-click to confirm)"
    })

    GroupLifecycle:AddLabel("Framework: " .. FRAMEWORK_ID .. " v" .. FRAMEWORK_VERSION)
    GroupLifecycle:AddLabel("Environment: Dead Rails")

    local GroupInfo = TabSettings:AddRightGroupbox("Info")
    GroupInfo:AddLabel("Keybind: Right Shift — Toggle UI")
end

-- ═══════════════════════════════════════════════════════════════
-- 11. KEYBIND & FINALIZATION
-- ═══════════════════════════════════════════════════════════════

-- Toggle UI visibility
Library.ToggleKeybind = Options and Options.MenuKeybind
    or Library:SetToggleKeybind(Enum.KeyCode.RightShift)

-- Register global reference
if getgenv then
    getgenv()[FRAMEWORK_ID] = {
        Version  = FRAMEWORK_VERSION,
        State    = State,
        Cleanup  = LifecycleModule.FullCleanup,
        Modules  = {
            Bonds     = BondsModule,
            Inventory = InventoryModule,
            Combat    = CombatModule,
            Visuals   = VisualsModule,
        }
    }
end

-- Startup notification
Library:Notify({
    Title    = "SilentHook",
    Content  = ("v%s loaded successfully — Dead Rails\nPress RightShift to toggle menu"):format(FRAMEWORK_VERSION),
    Duration = 5
})

warn(("[SilentHook] v%s — Framework initialized. %d modules active."):format(
    FRAMEWORK_VERSION, 4
))
