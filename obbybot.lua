--// ADAPTIVE OBBY RUNNER V2
--// Roblox Studio | For an obby you control
--// Detects platforms up to 50 studs away and actively moves.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- SETTINGS
local SCAN_RADIUS = 50
local MAX_JUMP_DISTANCE = 24
local MAX_HEIGHT_DIFFERENCE = 12
local ARRIVAL_DISTANCE = 4
local FALL_Y_OFFSET = 35

local enabled = false
local character
local humanoid
local root
local target
local currentPlatform
local scanTimer = 0
local jumpCooldown = 0
local statusText

local memory = {}

--==================================================
-- GUI
--==================================================

local oldGui = playerGui:FindFirstChild("AdaptiveObbyRunner")
if oldGui then
    oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "AdaptiveObbyRunner"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = playerGui

local button = Instance.new("TextButton")
button.Name = "Toggle"
button.Size = UDim2.fromOffset(125, 48)
button.Position = UDim2.new(1, -145, 0.55, 0)
button.BackgroundColor3 = Color3.fromRGB(180, 55, 55)
button.TextColor3 = Color3.new(1, 1, 1)
button.TextScaled = true
button.Font = Enum.Font.GothamBold
button.Text = "BOT: OFF"
button.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = button

statusText = Instance.new("TextLabel")
statusText.Size = UDim2.fromOffset(230, 35)
statusText.Position = UDim2.new(1, -250, 0.55, 52)
statusText.BackgroundTransparency = 0.25
statusText.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
statusText.TextColor3 = Color3.new(1, 1, 1)
statusText.TextScaled = true
statusText.Font = Enum.Font.Gotham
statusText.Text = "Ready"
statusText.Parent = gui

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 8)
statusCorner.Parent = statusText

local function setStatus(message)
    if statusText then
        statusText.Text = message
    end
end

--==================================================
-- CHARACTER
--==================================================

local function bindCharacter(char)
    character = char
    humanoid = char:WaitForChild("Humanoid")
    root = char:WaitForChild("HumanoidRootPart")

    target = nil
    currentPlatform = nil
    jumpCooldown = 0

    setStatus("Character ready")
end

if player.Character then
    bindCharacter(player.Character)
end

player.CharacterAdded:Connect(bindCharacter)

--==================================================
-- PLATFORM SCANNING
--==================================================

local function getLandingHeight(part)
    return part.Position.Y
        + part.Size.Y / 2
        + humanoid.HipHeight
        + root.Size.Y / 2
end

local function getPlatformKey(part)
    return part:GetFullName()
end

local function getCandidates()
    if not root or not character then
        return {}
    end

    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character}

    -- Detection range is 50 studs.
    local parts = Workspace:GetPartBoundsInRadius(
        root.Position,
        SCAN_RADIUS,
        params
    )

    local candidates = {}

    for _, part in ipairs(parts) do
        if part:IsA("BasePart")
            and part.CanCollide
            and part.Transparency < 1
            and part.Size.X >= 2
            and part.Size.Z >= 2 then

            local dx = part.Position.X - root.Position.X
            local dz = part.Position.Z - root.Position.Z
            local horizontal = Vector3.new(dx, 0, dz).Magnitude

            local landingY = getLandingHeight(part)
            local heightDifference = landingY - root.Position.Y

            -- Ignore platforms below the player or too high to reach.
            if horizontal > ARRIVAL_DISTANCE
                and horizontal <= MAX_JUMP_DISTANCE
                and heightDifference >= -10
                and heightDifference <= MAX_HEIGHT_DIFFERENCE then

                local key = getPlatformKey(part)
                local learned = memory[key] or 0.5

                -- Prefer nearby platforms with manageable height.
                local score =
                    horizontal
                    + math.abs(heightDifference) * 1.3
                    + (1 - learned) * 3

                table.insert(candidates, {
                    part = part,
                    score = score,
                    horizontal = horizontal,
                    height = heightDifference,
                    key = key,
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.score < b.score
    end)

    return candidates
end

--==================================================
-- TARGET SELECTION
--==================================================

local function chooseTarget()
    local candidates = getCandidates()

    if #candidates == 0 then
        target = nil
        setStatus("Searching nearby platforms...")
        return
    end

    target = candidates[1].part

    setStatus(string.format(
        "Target locked: %.0f studs",
        candidates[1].horizontal
    ))
end

--==================================================
-- MOVEMENT
--==================================================

local function moveToTarget(dt)
    if not target or not target.Parent then
        target = nil
        humanoid:Move(Vector3.zero, false)
        return
    end

    local destination = Vector3.new(
        target.Position.X,
        root.Position.Y,
        target.Position.Z
    )

    local difference = destination - root.Position
    local flat = Vector3.new(difference.X, 0, difference.Z)
    local distance = flat.Magnitude

    if distance <= ARRIVAL_DISTANCE then
        currentPlatform = target
        target = nil
        humanoid:Move(Vector3.zero, false)
        setStatus("Platform reached!")
        return
    end

    if distance > 0.1 then
        -- Actively move the Humanoid toward the target.
        humanoid:Move(flat.Unit, false)
    end

    -- Jump when approaching the platform or when it is elevated.
    local targetTop = target.Position.Y + target.Size.Y / 2
    local verticalGap = targetTop - root.Position.Y

    local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

    if grounded and jumpCooldown <= 0 then
        if distance <= 13 or verticalGap > 2 then
            humanoid.Jump = true
            jumpCooldown = 0.65
        end
    end

    jumpCooldown = math.max(0, jumpCooldown - dt)

    -- Face the direction of travel.
    if flat.Magnitude > 0.1 then
        local lookAt = CFrame.lookAt(
            root.Position,
            root.Position + flat.Unit
        )

        root.CFrame = root.CFrame:Lerp(lookAt, 0.08)
    end

    setStatus(string.format(
        "Moving to platform: %.0f studs",
        distance
    ))
end

--==================================================
-- FAILURE MEMORY
--==================================================

local lastY = 0
local lastTargetKey
local lastJumpTime = 0

local function recordFailure()
    if lastTargetKey then
        memory[lastTargetKey] =
            math.max(0, (memory[lastTargetKey] or 0.5) - 0.15)
    end

    target = nil
    setStatus("Fall detected; searching again")
end

--==================================================
-- TOGGLE
--==================================================

button.Activated:Connect(function()
    enabled = not enabled

    if enabled then
        button.Text = "BOT: ON"
        button.BackgroundColor3 = Color3.fromRGB(45, 160, 85)
        setStatus("Scanning platforms...")
        scanTimer = SCAN_RADIUS -- scan immediately
    else
        button.Text = "BOT: OFF"
        button.BackgroundColor3 = Color3.fromRGB(180, 55, 55)

        if humanoid then
            humanoid:Move(Vector3.zero, false)
        end

        setStatus("Bot stopped")
    end
end)

--==================================================
-- MAIN LOOP
--==================================================

RunService.Heartbeat:Connect(function(dt)
    if not enabled then
        return
    end

    if not character
        or not character.Parent
        or not humanoid
        or not root
        or humanoid.Health <= 0 then
        return
    end

    scanTimer += dt

    -- Recover after falling; normal game respawning is still required.
    if root.Position.Y < lastY - FALL_Y_OFFSET then
        recordFailure()
    end

    lastY = root.Position.Y

    -- Re-scan periodically, not just once.
    if scanTimer >= 0.25 then
        scanTimer = 0

        if not target or not target.Parent then
            chooseTarget()
        end
    end

    -- If the current target disappears, find another one.
    if target and not target:IsDescendantOf(Workspace) then
        target = nil
    end

    if target then
        lastTargetKey = getPlatformKey(target)
        moveToTarget(dt)
    elseif humanoid.FloorMaterial ~= Enum.Material.Air then
        humanoid:Move(Vector3.zero, false)
    end
end)

print("[Adaptive Obby Runner] Loaded. Tap BOT: ON to start.")
