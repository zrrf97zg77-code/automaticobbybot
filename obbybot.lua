-- MULTI-OBBY MOVEMENT ASSISTANT (Delta/mobile fixed)
-- Small mobile toggle + character alignment
-- Geometry scanning + landing estimates + jump guidance
-- For an obby you own or are authorized to test.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

--==================================================
-- SETTINGS
--==================================================

local SCAN_RADIUS = 45
local SCAN_INTERVAL = 0.40
local MAX_CANDIDATES = 8
local ARRIVAL_DISTANCE = 4.5

local JUMP_SPEED = 50
local GRAVITY = Workspace.Gravity

--==================================================
-- STATE
--==================================================

local enabled = false
local alignCharacter = true
local character, humanoid, root
local candidates = {}
local target = nil
local lastScan = 0

--==================================================
-- MOBILE UI (fixed parenting)
--==================================================

task.wait(0.5)

local gui = Instance.new("ScreenGui")
gui.Name = "MultiObbyAssistant"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999

local parented = pcall(function()
    gui.Parent = player:WaitForChild("PlayerGui", 10)
end)

if not parented or not gui.Parent then
    gui.Parent = game:GetService("CoreGui")
end

-- Toggle button
local button = Instance.new("TextButton")
button.Name = "Toggle"
button.Size = UDim2.fromOffset(60, 60)
button.Position = UDim2.new(1, -80, 0.55, 0)
button.BackgroundColor3 = Color3.fromRGB(145, 55, 55)
button.TextColor3 = Color3.new(1, 1, 1)
button.Text = "OB"
button.TextScaled = true
button.AutoButtonColor = true
button.Active = true
button.Parent = gui

local round = Instance.new("UICorner")
round.CornerRadius = UDim.new(1, 0)
round.Parent = button

local outline = Instance.new("UIStroke")
outline.Thickness = 2
outline.Color = Color3.new(1, 1, 1)
outline.Parent = button

-- Status label
local status = Instance.new("TextLabel")
status.Size = UDim2.new(0, 220, 0, 70)
status.Position = UDim2.new(1, -235, 0.55, 70)
status.BackgroundColor3 = Color3.fromRGB(25, 27, 35)
status.BackgroundTransparency = 0.1
status.TextColor3 = Color3.new(1, 1, 1)
status.TextWrapped = true
status.TextScaled = true
status.Text = "Assistant OFF"
status.Parent = gui

local statusRound = Instance.new("UICorner")
statusRound.CornerRadius = UDim.new(0, 8)
statusRound.Parent = status

print("[ObbyAssist] GUI parented to:", gui.Parent)

--==================================================
-- CHARACTER
--==================================================

local function bindCharacter(char)
    character = char
    humanoid = char:WaitForChild("Humanoid")
    root = char:WaitForChild("HumanoidRootPart")
    target = nil
    print("[ObbyAssist] Character bound")
end

if player.Character then
    task.spawn(bindCharacter, player.Character)
end

player.CharacterAdded:Connect(bindCharacter)

--==================================================
-- GEOMETRY SCANNER
--==================================================

local function scanPlatforms()
    if not root or not character then
        return {}
    end

    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character}

    local parts = Workspace:GetPartBoundsInRadius(
        root.Position,
        SCAN_RADIUS,
        params
    )

    local found = {}

    for _, part in ipairs(parts) do
        if part:IsA("BasePart")
            and part.CanCollide
            and part.Transparency < 1
            and part.Size.X >= 2
            and part.Size.Z >= 2 then

            local topY = part.Position.Y + part.Size.Y / 2

            local landing = Vector3.new(
                part.Position.X,
                topY + humanoid.HipHeight + root.Size.Y / 2,
                part.Position.Z
            )

            local delta = landing - root.Position
            local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
            local vertical = delta.Y
            local distance = delta.Magnitude

            if distance > ARRIVAL_DISTANCE
                and vertical > -25
                and vertical < 20 then

                table.insert(found, {
                    part = part,
                    position = landing,
                    distance = distance,
                    horizontal = horizontal,
                    height = vertical
                })
            end
        end
    end

    table.sort(found, function(a, b)
        local scoreA = a.distance + math.abs(a.height) * 1.3
        local scoreB = b.distance + math.abs(b.height) * 1.3
        return scoreA < scoreB
    end)

    while #found > MAX_CANDIDATES do
        table.remove(found)
    end

    return found
end

--==================================================
-- LANDING ESTIMATE (proper kinematic solve)
--==================================================

local function estimateLanding(targetY)
    if not root then return nil, nil end

    local position = root.Position
    local velocity = root.AssemblyLinearVelocity
    local g = math.max(GRAVITY, 1)

    local dy = (targetY or position.Y) - position.Y
    local a = -0.5 * g
    local b = velocity.Y
    local c = -dy

    local disc = b * b - 4 * a * c
    if disc < 0 then return nil, nil end

    local sqrtDisc = math.sqrt(disc)
    local t1 = (-b + sqrtDisc) / (2 * a)
    local t2 = (-b - sqrtDisc) / (2 * a)
    local t = math.min(t1, t2)
    if t < 0 then t = math.max(t1, t2) end
    if t < 0 then return nil, nil end

    t = math.clamp(t, 0.05, 2.0)

    local predicted = Vector3.new(
        position.X + velocity.X * t,
        position.Y + velocity.Y * t - 0.5 * g * t * t,
        position.Z + velocity.Z * t
    )

    return predicted, t
end

--==================================================
-- LINE OF SIGHT (excludes target part)
--==================================================

local function blocked(item)
    if not root or not item then return true end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character, item.part}

    local origin = root.Position + Vector3.new(0, humanoid.HipHeight, 0)
    local direction = item.position - origin

    return Workspace:Raycast(origin, direction, params) ~= nil
end

local function chooseTarget()
    for _, item in ipairs(candidates) do
        if item.part:IsDescendantOf(Workspace) and not blocked(item) then
            return item
        end
    end
    return candidates[1]
end

--==================================================
-- CHARACTER-ONLY FACING
--==================================================

local function alignFacing()
    if not enabled or not alignCharacter or not root or not humanoid then
        return
    end

    local direction = humanoid.MoveDirection

    if direction.Magnitude > 0.15 then
        local flat = Vector3.new(direction.X, 0, direction.Z)

        if flat.Magnitude > 0.01 then
            humanoid.AutoRotate = false

            local desired = CFrame.lookAt(
                root.Position,
                root.Position + flat.Unit
            )

            root.CFrame = root.CFrame:Lerp(desired, 0.18)
        end
    else
        humanoid.AutoRotate = true
    end
end

--==================================================
-- GUIDANCE
--==================================================

local function updateStatus()
    if not enabled then
        status.Text = "Assistant OFF"
        return
    end

    if not root or not humanoid then
        status.Text = "Waiting for character..."
        return
    end

    if not target then
        status.Text = "No suitable platform found nearby."
        return
    end

    local delta = target.position - root.Position
    local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude

    local landing = estimateLanding(target.position.Y)
    local advice

    if humanoid.FloorMaterial == Enum.Material.Air then
        advice = "AIRBORNE: prepare landing"
    elseif delta.Y > 4 and horizontal < 16 then
        advice = "UP: jump may be needed"
    elseif horizontal > 18 then
        advice = "FAR: inspect route"
    elseif blocked(target) then
        advice = "BLOCKED: try another route"
    else
        advice = "APPROACH: align movement"
    end

    local prediction = ""
    if landing then
        prediction = string.format(
            "\nEst land: %.1f, %.1f",
            landing.X, landing.Z
        )
    end

    status.Text = string.format(
        "%s\nDist %.1f | Hgt %.1f%s",
        advice,
        horizontal,
        delta.Y,
        prediction
    )
end

--==================================================
-- TOGGLE
--==================================================

button.Activated:Connect(function()
    enabled = not enabled

    button.Text = enabled and "ON" or "OB"
    button.BackgroundColor3 = enabled
        and Color3.fromRGB(45, 175, 105)
        or Color3.fromRGB(145, 55, 55)

    if not enabled then
        target = nil
        if humanoid then
            humanoid.AutoRotate = true
        end
    end

    updateStatus()
    print("[ObbyAssist] Toggled:", enabled)
end)

--==================================================
-- MAIN LOOP
--==================================================

RunService.Heartbeat:Connect(function()
    if not enabled or not root or not humanoid then
        return
    end

    alignFacing()

    if os.clock() - lastScan >= SCAN_INTERVAL then
        lastScan = os.clock()

        candidates = scanPlatforms()

        if target then
            local distance = (target.position - root.Position).Magnitude
            if distance < ARRIVAL_DISTANCE
                or not target.part:IsDescendantOf(Workspace) then
                target = nil
            end
        end

        if not target then
            target = chooseTarget()
        end

        updateStatus()
    end
end)

print("[ObbyAssist] Multi-Obby Movement Assistant ready.")
