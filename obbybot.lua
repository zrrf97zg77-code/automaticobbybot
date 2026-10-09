
-- TOH ADAPTIVE BOT | DELTA MOBILE
-- Based on the original working movement approach.
-- Remove older bot scripts before running.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- SETTINGS
local SCAN_RANGE = 45
local SCAN_INTERVAL = 0.10
local JUMP_COOLDOWN = 0.22
local TARGET_REACHED = 4
local MAX_UP = 9
local MAX_DOWN = 16

-- STATE
local enabled = false
local humanoid, root
local targetPart, targetPosition
local targetMemory = {}
local moveDirection = Vector3.zero
local shouldJump = false
local lastJump = 0
local scanClock = 0
local stuckClock = 0
local lastPosition
local status = "OFF"

-- UI
local oldGui = playerGui:FindFirstChild("TOHAdaptiveBot")
if oldGui then oldGui:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "TOHAdaptiveBot"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local button = Instance.new("TextButton")
button.Size = UDim2.fromOffset(112, 42)
button.Position = UDim2.new(0, 14, 0.35, 0)
button.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
button.TextColor3 = Color3.new(1, 1, 1)
button.TextSize = 13
button.Font = Enum.Font.GothamBold
button.Text = "TOH BOT: OFF"
button.Parent = gui

Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)

local function updateButton()
    button.Text = enabled and ("BOT: " .. status) or "TOH BOT: OFF"
    button.BackgroundColor3 = enabled
        and Color3.fromRGB(40, 135, 70)
        or Color3.fromRGB(55, 55, 65)
end

-- RAYCAST
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

local function bindCharacter(character)
    humanoid = character:WaitForChild("Humanoid", 8)
    root = character:WaitForChild("HumanoidRootPart", 8)

    rayParams.FilterDescendantsInstances = {character}
    targetPart = nil
    targetPosition = nil
    moveDirection = Vector3.zero
    shouldJump = false
    stuckClock = 0
    lastPosition = nil
end

player.CharacterAdded:Connect(bindCharacter)
if player.Character then
    task.spawn(bindCharacter, player.Character)
end

local function groundBelow(position, depth)
    local result = Workspace:Raycast(
        position,
        Vector3.new(0, -depth, 0),
        rayParams
    )

    return result
        and result.Instance:IsA("BasePart")
        and result.Instance.CanCollide
        and result.Normal.Y > 0.65
end

-- TARGET MEMORY
local function memoryKey(position)
    return string.format(
        "%d,%d,%d",
        math.floor(position.X / 6 + 0.5),
        math.floor(position.Y / 6 + 0.5),
        math.floor(position.Z / 6 + 0.5)
    )
end

local function scanPlatforms()
    if not root then return nil end

    local origin = root.Position
    local look = Vector3.new(
        root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z
    )

    if look.Magnitude < 0.01 then
        look = Vector3.new(0, 0, -1)
    else
        look = look.Unit
    end

    local right = Vector3.new(-look.Z, 0, look.X)
    local bestScore = -math.huge
    local bestPart, bestPosition, bestKey

    -- Wide forward fan.
    for i = 0, 24 do
        local angle = math.rad(-105 + i * (210 / 24))
        local direction = (
            look * math.cos(angle) + right * math.sin(angle)
        ).Unit

        -- Multiple heights help detect elevated landing surfaces.
        for _, yOffset in ipairs({2, 6, 10}) do
            local rayOrigin = origin + Vector3.new(0, yOffset, 0)
            local result = Workspace:Raycast(
                rayOrigin, direction * SCAN_RANGE, rayParams
            )

            if result and result.Instance:IsA("BasePart")
                and result.Instance.CanCollide
                and result.Normal.Y > 0.65 then

                local hit = result.Position
                local delta = hit - origin
                local flat = Vector3.new(delta.X, 0, delta.Z)
                local distance = flat.Magnitude
                local height = delta.Y

                if distance > 2
                    and height < MAX_UP
                    and height > -MAX_DOWN then

                    local forwardDot = look:Dot(flat.Unit)

                    if forwardDot > -0.2 then
                        local key = memoryKey(hit)
                        local memory = targetMemory[key] or {
                            failures = 0,
                            successes = 0
                        }

                        local score =
                            forwardDot * 10
                            - distance * 0.22
                            - math.abs(height - 2) * 0.65
                            + memory.successes * 1.5
                            - memory.failures * 4

                        if score > bestScore then
                            bestScore = score
                            bestPart = result.Instance
                            bestPosition = hit
                            bestKey = key
                        end
                    end
                end
            end
        end
    end

    return bestPart, bestPosition, bestKey
end

local currentKey

local function chooseTarget()
    local part, position, key = scanPlatforms()

    if part and position then
        targetPart = part
        targetPosition = position
        currentKey = key
        return true
    end

    return false
end

local function replan()
    targetPart = nil
    targetPosition = nil
    currentKey = nil
    shouldJump = false
    moveDirection = Vector3.zero
    chooseTarget()
end

local function think()
    if not humanoid or not root or humanoid.Health <= 0 then
        return
    end

    if targetPart and not targetPart.Parent then
        replan()
    end

    if targetPosition then
        local offset = targetPosition - root.Position

        if offset.Magnitude > SCAN_RANGE + 12
            or offset.Y > MAX_UP + 4
            or offset.Y < -MAX_DOWN - 4 then
            replan()
        end
    end

    if not targetPosition then
        if not chooseTarget() then
            -- Keep moving forward while scanning instead of freezing.
            local look = root.CFrame.LookVector
            moveDirection = Vector3.new(look.X, 0, look.Z).Unit
            shouldJump = false
            status = "SCANNING"
            return
        end
    end

    local delta = targetPosition - root.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local distance = flat.Magnitude

    if humanoid.FloorMaterial ~= Enum.Material.Air
        and distance < TARGET_REACHED
        and math.abs(delta.Y) < 5 then

        local memory = targetMemory[currentKey]
        if memory then
            memory.successes = math.min(memory.successes + 1, 10)
            memory.failures = math.max(memory.failures - 1, 0)
        end

        replan()
        status = "LANDED"
        return
    end

    if distance < 0.1 then
        moveDirection = Vector3.zero
        shouldJump = false
        return
    end

    moveDirection = flat.Unit

    local checkDistance = math.min(distance, 5)
    local checkPosition = root.Position
        + moveDirection * checkDistance
        + Vector3.new(0, -2, 0)

    local hasGroundAhead = groundBelow(checkPosition, 7)
    local heightDifference = delta.Y

    shouldJump =
        (not hasGroundAhead and distance > 2.5 and distance < 14)
        or (heightDifference > 2.5 and distance < 12)

    status = shouldJump and "JUMPING" or "MOVING"
end

local function trackStuck(dt)
    if not root or not humanoid then return end

    if lastPosition then
        local moved = (root.Position - lastPosition).Magnitude

        if moved < 0.15 and humanoid.FloorMaterial ~= Enum.Material.Air then
            stuckClock += dt
        else
            stuckClock = 0
        end

        if stuckClock > 2 then
            if currentKey then
                local memory = targetMemory[currentKey] or {
                    failures = 0,
                    successes = 0
                }

                memory.failures = math.min(memory.failures + 1, 8)
                targetMemory[currentKey] = memory
            end

            stuckClock = 0
            replan()
            status = "REPLANNING"
        end
    end

    lastPosition = root.Position
end

button.Activated:Connect(function()
    enabled = not enabled

    if enabled then
        replan()
        status = "SCANNING"
    else
        moveDirection = Vector3.zero
        shouldJump = false

        if humanoid then
            humanoid:Move(Vector3.zero, false)
        end

        status = "OFF"
    end

    updateButton()
end)

RunService.Heartbeat:Connect(function(dt)
    if not enabled or not humanoid or not root
        or humanoid.Health <= 0 then
        return
    end

    scanClock += dt

    if scanClock >= SCAN_INTERVAL then
        scanClock = 0

        local ok, err = pcall(think)
        if not ok then
            warn("[TOH Bot]", err)
            status = "ERROR"
        end
    end

    trackStuck(dt)

    -- Preserve the original movement method that worked.
    if moveDirection.Magnitude > 0.01 then
        humanoid:Move(moveDirection, false)
    end

    if shouldJump
        and humanoid.FloorMaterial ~= Enum.Material.Air
        and os.clock() - lastJump >= JUMP_COOLDOWN then

        humanoid.Jump = true
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        lastJump = os.clock()
        shouldJump = false
    end

    updateButton()
end)

print("[TOH Bot] Loaded. Tap the toggle to start.")
