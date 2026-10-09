
-- Adaptive Obby Runner
-- Roblox Studio prototype for an obby you control.
-- Place in StarterPlayer > StarterPlayerScripts.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CONFIG = {
    ScanRadius = 35,
    ScanInterval = 0.35,
    ArrivalDistance = 4,
    MaxJumpHeight = 12,
    MaxHorizontalJump = 15,
    FallY = -30,
    LearningAlpha = 0.25,
}

local enabled = false
local character, humanoid, root
local target
local lastScan = 0
local jumpStartedAt = 0
local wasAirborne = false
local lastPosition
local lastTargetKey
local lastJumpOutcome = "Ready"

-- Learning memory persists during this LocalScript's lifetime.
-- Success increases preference for a route; failure reduces it.
local memory = {}

local function getKey(part)
    return part:GetFullName()
end

local function learn(key, success)
    local entry = memory[key]

    if not entry then
        entry = {
            attempts = 0,
            successes = 0,
            score = 0.5,
        }
        memory[key] = entry
    end

    entry.attempts += 1

    if success then
        entry.successes += 1
    end

    local outcome = success and 1 or 0

    entry.score =
        entry.score * (1 - CONFIG.LearningAlpha)
        + outcome * CONFIG.LearningAlpha

    print(string.format(
        "[Runner] Learned %s: %d/%d successes, score %.2f",
        key,
        entry.successes,
        entry.attempts,
        entry.score
    ))
end

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
button.Size = UDim2.fromOffset(64, 64)
button.Position = UDim2.new(1, -84, 0.55, -32)
button.BackgroundColor3 = Color3.fromRGB(170, 55, 55)
button.TextColor3 = Color3.new(1, 1, 1)
button.Font = Enum.Font.GothamBold
button.TextScaled = true
button.Text = "OFF"
button.Active = true
button.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(1, 0)
corner.Parent = button

local status = Instance.new("TextLabel")
status.Name = "Status"
status.Size = UDim2.fromOffset(225, 65)
status.Position = UDim2.new(1, -240, 0.55, 38)
status.BackgroundColor3 = Color3.fromRGB(25, 27, 35)
status.BackgroundTransparency = 0.1
status.TextColor3 = Color3.new(1, 1, 1)
status.TextWrapped = true
status.TextScaled = true
status.Font = Enum.Font.Gotham
status.Text = "Runner stopped"
status.Parent = gui

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 8)
statusCorner.Parent = status

--==================================================
-- CHARACTER
--==================================================

local function bindCharacter(char)
    character = char
    humanoid = char:WaitForChild("Humanoid")
    root = char:WaitForChild("HumanoidRootPart")

    target = nil
    lastTargetKey = nil
    wasAirborne = false
    lastPosition = root.Position

    print("[Runner] Character ready")
end

if player.Character then
    task.spawn(bindCharacter, player.Character)
end

player.CharacterAdded:Connect(bindCharacter)

--==================================================
-- PLATFORM SCANNING
--==================================================

local function scanPlatforms()
    if not character or not root or not humanoid then
        return {}
    end

    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character}

    local parts = Workspace:GetPartBoundsInRadius(
        root.Position,
        CONFIG.ScanRadius,
        params
    )

    local results = {}

    for _, part in ipairs(parts) do
        if part:IsA("BasePart")
            and part.CanCollide
            and part.Transparency < 1
            and part.Size.X >= 2
            and part.Size.Z >= 2 then

            local landingY =
                part.Position.Y
                + part.Size.Y / 2
                + humanoid.HipHeight
                + root.Size.Y / 2

            local landing = Vector3.new(
                part.Position.X,
                landingY,
                part.Position.Z
            )

            local delta = landing - root.Position
            local horizontal = Vector3.new(
                delta.X, 0, delta.Z
            ).Magnitude

            local height = delta.Y

            if horizontal > CONFIG.ArrivalDistance
                and horizontal <= CONFIG.MaxHorizontalJump
                and height > -8
                and height <= CONFIG.MaxJumpHeight then

                local key = getKey(part)
                local entry = memory[key]
                local learnedScore = entry and entry.score or 0.5

                -- Lower is better. Learned successful routes
                -- receive a modest preference.
                local score =
                    horizontal
                    + math.abs(height) * 1.4
                    + (1 - learnedScore) * 4

                table.insert(results, {
                    part = part,
                    position = landing,
                    horizontal = horizontal,
                    height = height,
                    score = score,
                    key = key,
                })
            end
        end
    end

    table.sort(results, function(a, b)
        return a.score < b.score
    end)

    return results
end

--==================================================
-- TARGET VALIDATION
--==================================================

local function targetIsValid(item)
    if not item or not item.part then
        return false
    end

    if not item.part:IsDescendantOf(Workspace) then
        return false
    end

    local delta = item.position - root.Position
    local horizontal = Vector3.new(
        delta.X, 0, delta.Z
    ).Magnitude

    return horizontal <= CONFIG.MaxHorizontalJump
        and delta.Y <= CONFIG.MaxJumpHeight
        and delta.Y > -8
end

--==================================================
-- MOVEMENT
--==================================================

local function moveToward(item)
    if not humanoid or not root or not item then
        return
    end

    local delta = item.position - root.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)

    if flat.Magnitude > 0.1 then
        humanoid:Move(flat.Unit, false)
    end

    -- Face movement direction without rotating the camera.
    if flat.Magnitude > 0.1 then
        local desired = CFrame.lookAt(
            root.Position,
            root.Position + flat.Unit
        )

        root.CFrame = root.CFrame:Lerp(desired, 0.12)
    end

    -- Jump when approaching a higher platform or an edge.
    if humanoid.FloorMaterial ~= Enum.Material.Air then
        if item.height > 2
            or (item.horizontal < 7 and item.height > 0.5) then

            humanoid.Jump = true
            jumpStartedAt = os.clock()
            wasAirborne = true
        end
    end
end

--==================================================
-- FALL RECOVERY
--==================================================

local function handleFall()
    if not root or not humanoid then
        return
    end

    if root.Position.Y < CONFIG.FallY then
        status.Text = "Fell! Waiting for respawn..."
        target = nil

        humanoid:Move(Vector3.zero, false)
        return
    end

    if humanoid.Health <= 0 then
        status.Text = "Respawning..."
        target = nil
    end
end

--==================================================
-- TOGGLE
--==================================================

button.Activated:Connect(function()
    enabled = not enabled

    button.Text = enabled and "ON" or "OFF"
    button.BackgroundColor3 = enabled
        and Color3.fromRGB(45, 175, 105)
        or Color3.fromRGB(170, 55, 55)

    if not enabled and humanoid then
        humanoid:Move(Vector3.zero, false)
        humanoid.Jump = false
        humanoid.AutoRotate = true
    end

    status.Text = enabled and "Runner starting..." or "Runner stopped"

    print("[Runner] Enabled:", enabled)
end)

--==================================================
-- MAIN LOOP
--==================================================

RunService.Heartbeat:Connect(function()
    if not enabled then
        return
    end

    if not character or not humanoid or not root
        or humanoid.Health <= 0 then
        status.Text = "Waiting for character..."
        return
    end

    handleFall()

    if root.Position.Y < CONFIG.FallY then
        return
    end

    local airborne =
        humanoid.FloorMaterial == Enum.Material.Air

    if wasAirborne and not airborne and lastTargetKey then
        -- Landing is considered successful if we remain
        -- alive and reach the target's vicinity.
        local success = false

        if target and target.part
            and target.part:IsDescendantOf(Workspace) then

            local distance = (
                root.Position - target.position
            ).Magnitude

            success = distance < 7
        end

        learn(lastTargetKey, success)
        lastJumpOutcome = success and "Success" or "Missed"

        wasAirborne = false
    end

    if os.clock() - lastScan >= CONFIG.ScanInterval then
        lastScan = os.clock()

        if target and not targetIsValid(target) then
            target = nil
        end

        if not target then
            local options = scanPlatforms()
            target = options[1]

            if target then
                lastTargetKey = target.key
            end
        end
    end

    if target then
        moveToward(target)

        status.Text = string.format(
            "RUNNING\nTarget: %.1f studs\nLast jump: %s",
            target.horizontal,
            lastJumpOutcome
        )
    else
        humanoid:Move(Vector3.zero, false)
        status.Text = "Searching for platform..."
    end

    lastPosition = root.Position
end)

print("[Runner] Loaded. Tap OFF to start.")
