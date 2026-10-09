
--// OBBY BOT — PLATFORM NAVIGATION PROTOTYPE
--// Toggle: ON/OFF
--// Designed for testing in an authorized obby environment.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local CONFIG = {
    ScanDistance = 50,
    ArrivalDistance = 4,
    JumpHeightTrigger = 3,
    JumpCooldown = 0.8,
    MoveSpeed = 1,
}

local enabled = false
local currentTarget = nil
local lastJump = 0
local heartbeatConnection
local characterConnection

-- GUI
local gui = Instance.new("ScreenGui")
gui.Name = "ObbyBotUI"
gui.ResetOnSpawn = false

local ok = pcall(function()
    gui.Parent = game:GetService("CoreGui")
end)

if not ok or not gui.Parent then
    gui.Parent = player:WaitForChild("PlayerGui")
end

local button = Instance.new("TextButton")
button.Name = "Toggle"
button.Size = UDim2.fromOffset(110, 42)
button.Position = UDim2.new(0, 20, 0.45, 0)
button.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
button.TextColor3 = Color3.new(1, 1, 1)
button.Text = "BOT: OFF"
button.TextSize = 16
button.Font = Enum.Font.GothamBold
button.Parent = gui

Instance.new("UICorner", button).CornerRadius =
    UDim.new(0, 10)

local function getCharacter()
    local character = player.Character
    if not character then return end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")
    local root =
        character:FindFirstChild("HumanoidRootPart")

    if humanoid and root and humanoid.Health > 0 then
        return character, humanoid, root
    end
end

-- Find nearby platform-like parts.
local function findTarget(root)
    local bestPart = nil
    local bestScore = math.huge

    for _, part in ipairs(Workspace:GetDescendants()) do
        if not part:IsA("BasePart")
            or not part.Anchored
            or not part.CanCollide
            or part.Transparency >= 1 then
            continue
        end

        if part.Size.X < 2 or part.Size.Z < 2 then
            continue
        end

        local offset = part.Position - root.Position
        local horizontal = Vector3.new(
            offset.X, 0, offset.Z
        ).Magnitude

        local vertical = offset.Y

        if horizontal > CONFIG.ScanDistance
            or vertical < -2
            or vertical > 18 then
            continue
        end

        -- Prefer platforms ahead and above, but avoid
        -- selecting the floor directly beneath the player.
        if horizontal < 5 and math.abs(vertical) < 2 then
            continue
        end

        local score = horizontal + math.abs(vertical) * 1.5

        if score < bestScore then
            bestScore = score
            bestPart = part
        end
    end

    return bestPart
end

local function stopMovement(humanoid)
    if humanoid then
        humanoid:Move(Vector3.zero, false)
    end
end

button.Activated:Connect(function()
    enabled = not enabled
    button.Text = enabled and "BOT: ON" or "BOT: OFF"
    button.BackgroundColor3 = enabled
        and Color3.fromRGB(30, 140, 80)
        or Color3.fromRGB(45, 45, 45)

    if not enabled then
        local _, humanoid = getCharacter()
        stopMovement(humanoid)
        currentTarget = nil
    end
end)

heartbeatConnection = RunService.Heartbeat:Connect(function()
    if not enabled then return end

    local _, humanoid, root = getCharacter()
    if not humanoid or not root then return end

    -- Refresh target when needed.
    if not currentTarget
        or not currentTarget.Parent
        or (currentTarget.Position - root.Position).Magnitude
            > CONFIG.ScanDistance + 10 then
        currentTarget = findTarget(root)
    end

    if not currentTarget then
        stopMovement(humanoid)
        return
    end

    local offset = currentTarget.Position - root.Position
    local horizontal = Vector3.new(offset.X, 0, offset.Z)
    local distance = horizontal.Magnitude

    if distance <= CONFIG.ArrivalDistance then
        stopMovement(humanoid)
        currentTarget = nil
        return
    end

    if distance > 0 then
        -- Move in the target direction, relative to the world.
        humanoid:Move(horizontal.Unit * CONFIG.MoveSpeed, false)
    end

    -- Attempt a jump for a platform above the character.
    if offset.Y > CONFIG.JumpHeightTrigger
        and os.clock() - lastJump >= CONFIG.JumpCooldown
        and humanoid.FloorMaterial ~= Enum.Material.Air then

        lastJump = os.clock()
        humanoid.Jump = true
    end
end)

player.CharacterAdded:Connect(function()
    currentTarget = nil
    lastJump = 0
end)

script.Destroying:Connect(function()
    enabled = false

    if heartbeatConnection then
        heartbeatConnection:Disconnect()
    end

    if characterConnection then
        characterConnection:Disconnect()
    end

    gui:Destroy()
end)
