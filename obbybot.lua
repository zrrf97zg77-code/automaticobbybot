
-- TOH ADAPTIVE BOT | DELTA MOBILE
-- Session-based learning; no Studio required.
-- Remove any previous bot before running.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- SETTINGS
local SCAN_RANGE = 38
local SCAN_ANGLE = 80
local SCAN_RAYS = 17
local SCAN_INTERVAL = 0.08
local JUMP_COOLDOWN = 0.24
local MAX_TARGET_HEIGHT = 9
local MAX_TARGET_DROP = 15
local TARGET_REACHED = 4
local MEMORY_RADIUS = 7

-- STATE
local enabled = false
local humanoid = nil
local root = nil
local targetPosition = nil
local targetPart = nil
local moveDirection = Vector3.zero
local jumpRequested = false
local status = "BOT OFF"
local lastJump = 0
local scanTimer = 0
local lastY = nil
local lastGroundedPosition = nil
local lastGroundedTime = 0
local lastTargetKey = nil
local fallStartY = nil
local jumpAttempts = 0
local progressTimer = 0
local lastProgressPosition = nil
local stuckTime = 0

-- Learning memory for this session.
-- Memory entries are keyed by approximate world position.
local memory = {}

local function keyFor(pos)
    return string.format(
        "%d:%d:%d",
        math.floor(pos.X / MEMORY_RADIUS + 0.5),
        math.floor(pos.Y / MEMORY_RADIUS + 0.5),
        math.floor(pos.Z / MEMORY_RADIUS + 0.5)
    )
end

local function getMemory(pos)
    local key = keyFor(pos)
    if not memory[key] then
        memory[key] = {
            failures = 0,
            successes = 0,
            lastFailure = 0
        }
    end
    return memory[key], key
end

local function recordFailure()
    if not lastTargetKey then return end

    local entry = memory[lastTargetKey]
    if entry then
        entry.failures = math.min(entry.failures + 1, 8)
        entry.lastFailure = os.clock()
    end

    targetPosition = nil
    targetPart = nil
    jumpAttempts = jumpAttempts + 1
    lastTargetKey = nil
end

local function recordSuccess()
    if not lastTargetKey then return end

    local entry = memory[lastTargetKey]
    if entry then
        entry.successes = math.min(entry.successes + 1, 20)
        entry.failures = math.max(0, entry.failures - 1)
    end

    lastTargetKey = nil
    jumpAttempts = 0
end

-- UI
local old = playerGui:FindFirstChild("AdaptiveTOHBot")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "AdaptiveTOHBot"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.Parent = playerGui

local button = Instance.new("TextButton")
button.Size = UDim2.fromOffset(112, 42)
button.Position = UDim2.new(0, 14, 0.35, 0)
button.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
button.TextColor3 = Color3.new(1, 1, 1)
button.Text = "TOH BOT: OFF"
button.TextSize = 13
button.Font = Enum.Font.GothamBold
button.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 9)
corner.Parent = button

local function updateButton()
    button.Text = enabled and ("BOT: " .. status) or "TOH BOT: OFF"
    button.BackgroundColor3 = enabled
        and Color3.fromRGB(35, 135, 75)
        or Color3.fromRGB(55, 55, 65)
end

-- Raycast configuration
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

local function bindCharacter(char)
    humanoid = char:WaitForChild("Humanoid", 8)
    root = char:WaitForChild("HumanoidRootPart", 8)

    rayParams.FilterDescendantsInstances = {char}

    targetPosition = nil
    targetPart = nil
    moveDirection = Vector3.zero
    jumpRequested = false
    lastTargetKey = nil
    lastY = root and root.Position.Y or nil
    lastGroundedPosition = nil
    fallStartY = nil
    stuckTime = 0
end

player.CharacterAdded:Connect(bindCharacter)
if player.Character then
    task.spawn(bindCharacter, player.Character)
end

-- Find a walkable surface below a point.
local function groundAt(position, depth)
    local result = Workspace:Raycast(
        position,
        Vector3.new(0, -depth, 0),
        rayParams
    )

    if result and result.Instance:IsA("BasePart")
        and result.Instance.CanCollide
        and result.Normal.Y > 0.7 then
        return result
    end

    return nil
end

-- Find a platform in a forward fan.
-- Returns the surface hit position, not the part's center.
local function scanPlatforms()
    if not root then return nil end

    local origin = root.Position
    local facing = Vector3.new(
        root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z
    )

    if facing.Magnitude < 0.01 then
        facing = Vector3.new(0, 0, -1)
    else
        facing = facing.Unit
    end

    local right = Vector3.new(-facing.Z, 0, facing.X)
    local bestScore = -math.huge
    local bestPosition = nil
    local bestPart = nil
    local bestKey = nil

    -- Widen the scan after repeated failures.
    local angleWidth = math.min(SCAN_ANGLE + jumpAttempts * 5, 115)

    for i = 0, SCAN_RAYS - 1 do
        local t = i / (SCAN_RAYS - 1)
        local angle = math.rad(-angleWidth + 2 * angleWidth * t)

        local direction = (
            facing * math.cos(angle)
            + right * math.sin(angle)
        ).Unit

        -- Cast from slightly above the character's feet.
        local castOrigin = origin + Vector3.new(0, 1, 0)
        local result = Workspace:Raycast(
            castOrigin, direction * SCAN_RANGE, rayParams
        )

        if result and result.Instance:IsA("BasePart")
            and result.Instance.CanCollide
            and result.Normal.Y > 0.7 then

            local hit = result.Position
            local delta = hit - origin
            local horizontal = Vector3.new(delta.X, 0, delta.Z)
            local distance = horizontal.Magnitude
            local height = delta.Y

            if distance > 2
                and height < MAX_TARGET_HEIGHT
                and height > -MAX_TARGET_DROP then

                local dot = facing:Dot(horizontal.Unit)

                if dot > -0.05 then
                    local entry, key = getMemory(hit)

                    -- Recent failures cost more; successful landings
                    -- slightly improve the score.
                    local failurePenalty = entry.failures * 5
                    if os.clock() - entry.lastFailure > 18 then
                        failurePenalty = failurePenalty * 0.5
                    end

                    local score =
                        dot * 12
                        - distance * 0.28
                        - math.abs(height - 2) * 0.65
                        - failurePenalty
                        + math.min(entry.successes, 5) * 1.5

                    -- Prefer a wider surface when other factors
                    -- are approximately equal.
                    score += math.min(
                        result.Instance.Size.X,
                        result.Instance.Size.Z
                    ) * 0.12

                    if score > bestScore then
                        bestScore = score
                        bestPosition = hit
                        bestPart = result.Instance
                        bestKey = key
                    end
                end
            end
        end
    end

    return bestPosition, bestPart, bestKey
end

local function computeMove()
    if not root or not humanoid then return end

    -- Discard deleted or obviously outdated targets.
    if targetPart and not targetPart.Parent then
        targetPosition = nil
        targetPart = nil
        lastTargetKey = nil
    end

    if targetPosition then
        local offset = targetPosition - root.Position

        if offset.Magnitude > SCAN_RANGE + 12
            or offset.Y > MAX_TARGET_HEIGHT + 3
            or offset.Y < -MAX_TARGET_DROP - 3 then
            targetPosition = nil
            targetPart = nil
            lastTargetKey = nil
        end
    end

    if not targetPosition then
        local pos, part, key = scanPlatforms()

        if pos then
            targetPosition = pos
            targetPart = part
            lastTargetKey = key
        end
    end

    if not targetPosition then
        status = "SCANNING"
        moveDirection = Vector3.zero
        jumpRequested = false
        return
    end

    local origin = root.Position
    local delta = targetPosition - origin
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local distance = flat.Magnitude

    -- Check for a successful landing on the chosen surface.
    if humanoid.FloorMaterial ~= Enum.Material.Air
        and targetPart
        and (root.Position - targetPosition).Magnitude < 7 then

        recordSuccess()
        targetPosition = nil
        targetPart = nil
        moveDirection = Vector3.zero
        jumpRequested = false
        status = "LANDED"
        return
    end

    if distance < 0.7 then
        moveDirection = Vector3.zero
        jumpRequested = false
        return
    end

    local direction = flat.Unit
    moveDirection = direction

    -- Check the ground ahead at several points.
    local gapDetected = false
    local lookDistance = math.min(distance, 6)

    for _, fraction in ipairs({0.45, 0.8, 1.15}) do
        local point = origin
            + direction * math.min(lookDistance * fraction, 6)
            + Vector3.new(0, -2.5, 0)

        if not groundAt(point, 7) then
            gapDetected = true
            break
        end
    end

    local heightDifference = targetPosition.Y - origin.Y
    local needsJump =
        (gapDetected and distance > 2.8 and distance < 15)
        or (heightDifference > 2.5 and distance < 12)

    -- Alter the jump trigger after repeated failures.
    if jumpAttempts >= 2 and distance < 10
        and heightDifference > 0.5 then
        needsJump = true
    end

    jumpRequested = needsJump
    status = needsJump and "JUMPING" or "MOVING"
end

-- Track falls and lack of progress.
local function trackProgress()
    if not root or not humanoid then return end

    local position = root.Position
    local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

    if grounded then
        lastGroundedPosition = position
        lastGroundedTime = os.clock()
        fallStartY = nil
    else
        if not fallStartY then
            fallStartY = position.Y
        end

        -- A substantial downward drop without a landing is a likely
        -- failed attempt. Do not repeatedly count the same fall.
        if fallStartY and position.Y < fallStartY - 14 then
            recordFailure()
            fallStartY = nil
            status = "REPLANNING"
        end
    end

    if lastProgressPosition then
        local moved = (position - lastProgressPosition).Magnitude
        if moved < 0.3 and grounded then
            stuckTime += 0.1
        else
            stuckTime = 0
        end

        if stuckTime > 2.5 then
            -- Abandon a stale target and try a new route.
            targetPosition = nil
            targetPart = nil
            lastTargetKey = nil
            stuckTime = 0
            status = "REPLANNING"
        end
    end

    lastProgressPosition = position
end

-- Main loop
button.Activated:Connect(function()
    enabled = not enabled

    if enabled then
        targetPosition = nil
        targetPart = nil
        lastTargetKey = nil
        moveDirection = Vector3.zero
        jumpRequested = false
        scanTimer = 0
        status = "SCANNING"
    else
        moveDirection = Vector3.zero
        jumpRequested = false

        if humanoid then
            humanoid:Move(Vector3.zero, false)
        end

        status = "BOT OFF"
    end

    updateButton()
end)

RunService.Heartbeat:Connect(function(dt)
    if not enabled or not humanoid or not root
        or humanoid.Health <= 0 then
        return
    end

    scanTimer += dt
    progressTimer += dt

    if scanTimer >= SCAN_INTERVAL then
        scanTimer = 0

        local ok, err = pcall(computeMove)
        if not ok then
            warn("[Adaptive TOH Bot]", err)
            status = "ERROR"
        end
    end

    if progressTimer >= 0.1 then
        progressTimer = 0
        trackProgress()
    end

    if moveDirection.Magnitude > 0.01 then
        humanoid:Move(moveDirection, false)
    end

    if jumpRequested
        and humanoid.FloorMaterial ~= Enum.Material.Air
        and os.clock() - lastJump >= JUMP_COOLDOWN then

        humanoid.Jump = true
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

        lastJump = os.clock()
        jumpRequested = false
    end

    updateButton()
end)

print("[Adaptive TOH Bot] Loaded. Tap the button to start.")
