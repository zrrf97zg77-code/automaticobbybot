--!strict
-- Obby Auto-Runner v2 — Client LocalScript
-- Place in StarterPlayer/StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- CONFIG
local SCAN_RANGE = 50
local SCAN_HALF_ANGLE = 55          -- degrees left/right of facing
local RAY_COUNT = 9                 -- rays per scan sweep
local MOVEMENT_UPDATE_RATE = 0.08   -- seconds between scans
local EDGE_APPROACH_DIST = 3.5
local JUMP_CHECK_INTERVAL = 0.15
local STUCK_TIMEOUT = 1.5           -- seconds without meaningful progress
local STUCK_PROGRESS_THRESHOLD = 0.5

-- STATE
local botEnabled = false
local currentStatus = "BOT OFF"
local humanoid: Humanoid? = nil
local hrp: BasePart? = nil
local lastPos = Vector3.zero
local lastProgressTime = 0
local lastJumpTime = 0
local currentTarget: BasePart? = nil
local isJumping = false

-- SERVICES / FILTERS
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- UI (minimal toggle)
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ObbyBotUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0, 70, 0, 38)
toggleBtn.Position = UDim2.new(0, 12, 0, 12)
toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
toggleBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
toggleBtn.TextSize = 13
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Text = "BOT OFF"
toggleBtn.AutoButtonColor = false
toggleBtn.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = toggleBtn

-- CHARACTER BINDING
local function onCharacter(char: Model)
    local h = char:WaitForChild("Humanoid", 5) :: Humanoid?
    local r = char:WaitForChild("HumanoidRootPart", 5) :: BasePart?
    if not h or not r then return end
    humanoid = h
    hrp = r
    isJumping = false
    currentTarget = nil
    lastPos = r.Position
    lastProgressTime = tick()

    -- update ray filter to exclude own character
    rayParams.FilterDescendantsInstances = { char }
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
    task.defer(onCharacter, player.Character)
end

-- UTILITY: angle between two horizontal vectors
local function horizontalAngle(v1: Vector3, v2: Vector3): number
    local d1 = Vector3.new(v1.X, 0, v1.Z).Unit
    local d2 = Vector3.new(v2.X, 0, v2.Z).Unit
    return math.deg(math.acos(math.clamp(d1:Dot(d2), -1, 1)))
end

-- SCAN: cast rays in a forward cone, return best reachable part
local function scanForPlatforms(origin: Vector3, facing: Vector3): BasePart?
    local bestPart: BasePart? = nil
    local bestScore = -math.huge

    local fwd = Vector3.new(facing.X, 0, facing.Z).Unit
    local right = Vector3.new(fwd.Z, 0, -fwd.X)

    for i = 0, RAY_COUNT - 1 do
        local t = (i / (RAY_COUNT - 1)) * 2 - 1
        local angleRad = math.rad(SCAN_HALF_ANGLE * t)
        local dir = (fwd * math.cos(angleRad) + right * math.sin(angleRad)).Unit

        -- forward scan
        local result = Workspace:Raycast(origin, dir * SCAN_RANGE, rayParams)
        if not result then continue end
        local part = result.Instance
        if not part:IsA("BasePart") or part.Anchored == false then continue end
        if part.CanCollide == false then continue end

        -- must be roughly horizontal (floor-like)
        if math.abs(result.Normal.Y) < 0.7 then continue end

        -- distance and height scoring
        local hitPos = result.Position
        local dist = (hitPos - origin).Magnitude
        local heightDiff = hitPos.Y - origin.Y

        if heightDiff > 6 or heightDiff < -18 then continue end
        if dist < 2.5 then continue end

        -- score: prefer close, slightly higher, and aligned with facing
        local score = 0
        score += (SCAN_RANGE - dist) * 1.2
        score += math.abs(heightDiff - 2) * -0.5
        score += (1 - math.abs(t)) * 4

        if score > bestScore then
            bestScore = score
            bestPart = part
        end
    end
    return bestPart
end

-- CHECK: is there ground below within jump reach?
local function hasGroundBelow(pos: Vector3, maxDepth: number): boolean
    local result = Workspace:Raycast(pos, Vector3.new(0, -maxDepth, 0), rayParams)
    if result and result.Instance:IsA("BasePart") and result.Instance.CanCollide then
        if math.abs(result.Normal.Y) > 0.7 then
            return true
        end
    end
    return false
end

-- MAIN MOVEMENT LOGIC
local function updateBot()
    if not botEnabled or not humanoid or not hrp then
        return
    end

    local rootPos = hrp.Position
    local rootVel = hrp.AssemblyLinearVelocity
    local facing = hrp.CFrame.LookVector

    -- detect falling / respawn
    if rootPos.Y < -50 then
        currentStatus = "RECOVERING"
        return
    end

    -- stuck detection
    local now = tick()
    if (rootPos - lastPos).Magnitude > STUCK_PROGRESS_THRESHOLD then
        lastPos = rootPos
        lastProgressTime = now
    elseif now - lastProgressTime > STUCK_TIMEOUT then
        currentStatus = "RECOVERING"
        -- jump out of stuck state
        if humanoid.FloorMaterial ~= Enum.Material.Air then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
        lastProgressTime = now
        return
    end

    -- reacquire target if needed
    local targetPos: Vector3? = nil
    if currentTarget and currentTarget.Parent then
        targetPos = currentTarget.Position
    else
        currentStatus = "SCANNING"
        currentTarget = scanForPlatforms(rootPos, facing)
        if currentTarget then
            targetPos = currentTarget.Position
        end
    end

    if not targetPos then
        currentStatus = "SCANNING"
        -- no platform found: walk forward cautiously
        humanoid:Move(facing, false)
        return
    end

    -- horizontal direction to target
    local toTarget = Vector3.new(
        targetPos.X - rootPos.X,
        0,
        targetPos.Z - rootPos.Z
    )
    local flatDist = toTarget.Magnitude

    if flatDist < 0.5 then
        currentTarget = nil
        currentStatus = "SCANNING"
        return
    end

    local moveDir = toTarget.Unit

    -- edge approach: slow down near target edge
    local speedMult = 1
    if flatDist < EDGE_APPROACH_DIST then
        speedMult = math.max(0.35, flatDist / EDGE_APPROACH_DIST)
    end
    moveDir = moveDir * speedMult

    -- --- JUMP DECISION ---
    local shouldJump = false
    local heightDiff = targetPos.Y - rootPos.Y

    -- check if ground disappears ahead (gap)
    local aheadCheckDist = math.min(flatDist, 4)
    local aheadOrigin = rootPos + Vector3.new(0, -2.5, 0) + moveDir.Unit * aheadCheckDist
    local groundAhead = hasGroundBelow(aheadOrigin, 8)

    -- jump if gap detected and on ground
    if not groundAhead and flatDist > 2 and flatDist < 14 then
        shouldJump = true
    end

    -- jump if target is significantly higher
    if heightDiff > 2.5 and flatDist < 12 then
        shouldJump = true
    end

    -- jump if stuck against a wall (velocity low but trying to move)
    if rootVel.Magnitude < 1.5 and flatDist > 3 and flatDist < 10 then
        shouldJump = true
    end

    -- execute jump with cooldown
    if shouldJump and now - lastJumpTime > JUMP_CHECK_INTERVAL then
        if humanoid.FloorMaterial ~= Enum.Material.Air then
            currentStatus = "JUMPING"
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            lastJumpTime = now
            isJumping = true
        end
    elseif isJumping then
        currentStatus = "MOVING"
    else
        currentStatus = "MOVING"
    end

    -- apply movement every frame
    humanoid:Move(moveDir, false)

    -- clear jump state when grounded again
    if humanoid.FloorMaterial ~= Enum.Material.Air then
        isJumping = false
    end
end

-- UPDATE LOOP (throttled for performance)
local scanAccum = 0
RunService.RenderStepped:Connect(function(dt)
    if not botEnabled then
        return
    end
    scanAccum += dt
    if scanAccum >= MOVEMENT_UPDATE_RATE then
        scanAccum = 0
        local ok, err = pcall(updateBot)
        if not ok then
            warn("[ObbyBot] Error:", err)
            currentStatus = "RECOVERING"
        end
    end
    -- apply movement every frame for smooth control
    if humanoid and hrp then
        -- movement vector is set inside updateBot; if we're between scans,
        -- keep the last direction by calling Move with stored direction
        -- (updateBot handles this)
    end
end)

-- TOGGLE BUTTON
toggleBtn.MouseButton1Click:Connect(function()
    botEnabled = not botEnabled
    if botEnabled then
        toggleBtn.Text = "SCANNING"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(70, 150, 70)
        lastPos = hrp and hrp.Position or Vector3.zero
        lastProgressTime = tick()
        currentTarget = nil
    else
        toggleBtn.Text = "BOT OFF"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
        if humanoid then
            humanoid:Move(Vector3.zero, false)
        end
    end
end)

-- STATUS DISPLAY
RunService.Heartbeat:Connect(function()
    if botEnabled then
        toggleBtn.Text = currentStatus
    end
end)
