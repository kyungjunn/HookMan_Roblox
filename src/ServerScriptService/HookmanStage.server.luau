--!strict
-- Each player owns one run and one private course. Only this service transitions runs.
local Players = game:GetService("Players")
local Heartbeat = game:GetService("RunService").Heartbeat
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Shared = ReplicatedStorage:WaitForChild("Hookman")
local Config = require(Shared.Config)
local Rules = require(Shared.RunRules)
local RewardRules = require(Shared.RewardRules)
local ShopCatalog = require(Shared.ShopCatalog)
local ZoneCatalog = require(Shared.ZoneCatalog)
local Economy = require(script.Parent.Economy)
local CourseService = require(script.Parent.CourseService)
local HookService = require(script.Parent.HookService)
local LobbyBuilder = require(script.Parent.LobbyBuilder)
local Leaderboard = require(script.Parent.Leaderboard)

local function remote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), name .. " has wrong class")
		return existing
	end
	local result = Instance.new("RemoteEvent")
	result.Name, result.Parent = name, ReplicatedStorage
	return result
end
local runEvent, actionEvent, verdictEvent = remote("HookmanRun"), remote("HookmanAction"), remote("HookmanVerdict")
local goalEvent, hazardEvent, zoneEvent = remote("HookmanGoal"), remote("HookmanHazard"), remote("HookmanZone")
local lobby = LobbyBuilder.build()
local runs, versions, packets, nextLevels, connections, buckets = {}, {}, {}, {}, {}, {}
local clearDelay = 1.5
local characterGroup = "HookmanCharacters"
if not PhysicsService:IsCollisionGroupRegistered(characterGroup) then
	PhysicsService:RegisterCollisionGroup(characterGroup)
end
PhysicsService:CollisionGroupSetCollidable(characterGroup, characterGroup, false)

local function emit(player: Player, run, state: string)
	versions[player] = (versions[player] or 0) + 1
	if run then
		run.state = state
	end
	local packet = {
		runId = run and run.id or "",
		state = state,
		version = versions[player],
		course = run and run.course and run.course.folder or nil,
		level = run and run.level or 1,
		zoneId = run and run.zone.id or ZoneCatalog.Default,
		checkpoint = run and run.checkpoint or 0,
	}
	packets[player] = packet
	if player.Parent then
		runEvent:FireClient(player, packet)
	end
end
Economy.setRunSnapshotProvider(function(player)
	return packets[player]
end)

local function rootOf(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	return root, humanoid
end
local function moveRoot(root, humanoid, position: Vector3, forward: Vector3, velocity: Vector3)
	humanoid.PlatformStand, humanoid.AutoRotate = false, true
	root.CFrame = CFrame.lookAt(position, position + forward)
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = velocity, Vector3.zero
end
local function endRun(player: Player, expected)
	if expected and runs[player] ~= expected then
		return
	end
	local run = runs[player]
	if run then
		emit(player, run, "Returning")
		HookService.reset(run)
		Economy.endRun(player, run.id)
		runs[player] = nil
		CourseService.release(run.id)
	end
	local root, humanoid = rootOf(player)
	if root then
		moveRoot(root, humanoid, LobbyBuilder.spawnPoint(lobby), Vector3.zAxis, Vector3.zero)
	end
	emit(player, nil, "Lobby")
end
local function resetRun(player: Player, run)
	if runs[player] ~= run or run.state ~= "Running" then
		return
	end
	emit(player, run, "Resetting")
	HookService.reset(run)
	local root, humanoid = rootOf(player)
	if not root then
		endRun(player, run)
		return
	end
	local point, velocity
	if run.checkpoint > 0 then
		point = run.course.checkpoints[run.checkpoint].Position + Vector3.new(0, 40, 0)
		velocity = run.course.path:forwardAt(point) * 40
	else
		local start = run.course.start
		point = start.Position + Vector3.new(0, start.Size.Y / 2 + 3, 0)
		velocity = Vector3.zero
	end
	moveRoot(root, humanoid, point, run.course.path:forwardAt(point), velocity)
	run.previousPosition, run.previousTime = point, os.clock()
	run.observation = nil
	run.graceUntil = os.clock() + Config.Hazard.GraceTime
	run.lastProgressAt = os.clock()
	emit(player, run, "Running")
end

local function startRun(player: Player, zoneId: string)
	if runs[player] or not Economy.isReady(player) then
		return
	end
	local root, humanoid = rootOf(player)
	if not root or (root.Position - LobbyBuilder.spawnPoint(lobby)).Magnitude > 180 then
		return
	end
	local profile, zone = Economy.get(player), ZoneCatalog.get(zoneId)
	if not profile or not zone then
		return
	end
	if not ZoneCatalog.unlocked(zone, profile.lifetimeScore) then
		zoneEvent:FireClient(player, false, zone.id, zone.requireScore)
		return
	end
	local level = (nextLevels[player] or {})[zone.id] or zone.startLevel
	local run = {
		id = HttpService:GenerateGUID(false),
		state = "Preparing",
		zone = table.freeze(table.clone(zone)),
		level = level,
		effect = table.freeze(ShopCatalog.effectOf(table.clone(profile.equipped))),
		checkpoint = 0,
		combo = 0,
		score = 0,
		sequence = 0,
		scoredHooks = {},
		startedAt = os.clock(),
		graceUntil = 0,
		lastProgressAt = os.clock(),
		hazardsPrevious = {},
	}
	if not Economy.beginRun(player, run.id, zone.id) then
		return
	end
	runs[player] = run
	emit(player, run, "Preparing")
	local course, reason = CourseService.acquire(run.id, player.UserId, level, zone)
	if not course then
		warn("[HOOKMAN] " .. tostring(reason))
		endRun(player, run)
		return
	end
	run.course = course
	if runs[player] ~= run or not player.Parent then
		CourseService.release(run.id)
		return
	end
	-- resetRun establishes the first authoritative movement observation after teleport.
	run.state = "Running"
	resetRun(player, run)
end

local function finishRun(player: Player, run)
	if runs[player] ~= run or run.state ~= "Running" then
		return
	end
	local elapsed = os.clock() - run.startedAt
	emit(player, run, "Settling")
	HookService.reset(run)
	local total, coins = RewardRules.finish(run.score, run.level, run.zone)
	task.spawn(function()
		local applied, saved = Economy.finishRun(player, run.id, total, coins)
		if runs[player] ~= run or not player.Parent then
			return
		end
		if applied then
			nextLevels[player] = nextLevels[player] or {}
			nextLevels[player][run.zone.id] = math.min(run.level + run.zone.levelStep, run.zone.maxLevel)
			goalEvent:FireClient(player, elapsed, run.level, total, coins, run.zone.id, saved, run.id)
			Leaderboard.markDirty()
		end
		task.delay(clearDelay, function()
			if runs[player] == run and run.state == "Settling" then
				endRun(player, run)
			end
		end)
	end)
end

local function allowedRequest(player: Player, now: number): boolean
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = Rules.RequestBurst, time = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(Rules.RequestBurst, bucket.tokens + (now - bucket.time) * Rules.RequestRate)
	bucket.time = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end
actionEvent.OnServerEvent:Connect(function(player, request)
	local now = os.clock()
	if not allowedRequest(player, now) or type(request) ~= "table" then
		return
	end
	local run = runs[player]
	if
		not run
		or run.state ~= "Running"
		or request.runId ~= run.id
		or not Rules.integer(request.sequence, 1, 1e9)
		or request.sequence <= run.sequence
	then
		return
	end
	run.sequence = request.sequence
	if request.action == "abandon" then
		endRun(player, run)
		return
	end
	local root = rootOf(player)
	if not root or not Rules.vector(root.Position) or not Rules.vector(root.AssemblyLinearVelocity) then
		return
	end
	local movementOk = run.previousPosition
		and Rules.validMovement(
			run.previousPosition,
			root.Position,
			root.AssemblyLinearVelocity,
			math.max(now - run.previousTime, 1 / 240)
		)
	if not movementOk then
		verdictEvent:FireClient(
			player,
			{ runId = run.id, sequence = request.sequence, accepted = false, reason = "movement", combo = 0 }
		)
		resetRun(player, run)
		return
	end
	local verdict = HookService.handle(run, request, now, root)
	if verdict.accepted and verdict.grade and verdict.award then
		run.score =
			math.min(run.score + RewardRules.judge(verdict.grade, run.combo, run.effect, run.zone), Rules.MaxScore)
		Economy.setRunScore(player, run.id, run.score)
	end
	verdictEvent:FireClient(player, verdict)
end)

for _, pad in ipairs(lobby.ZonePads:GetChildren()) do
	local zoneId = pad:GetAttribute("ZoneId")
	if pad:IsA("BasePart") and type(zoneId) == "string" then
		pad.CanTouch = true
		pad.Touched:Connect(function(hit)
			local character = hit:FindFirstAncestorOfClass("Model")
			local player = character and Players:GetPlayerFromCharacter(character)
			if player then
				startRun(player, zoneId)
			end
		end)
	end
end

local function onCharacter(player: Player, character: Model)
	local old = connections[player]
	if old then
		for _, connection in ipairs(old) do
			connection:Disconnect()
		end
	end
	connections[player] = {}
	local function collision(object)
		if object:IsA("BasePart") then
			object.CollisionGroup = characterGroup
		end
	end
	for _, object in ipairs(character:GetDescendants()) do
		collision(object)
	end
	table.insert(connections[player], character.DescendantAdded:Connect(collision))
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not player.Parent or player.Character ~= character or not humanoid or not root then
		return
	end
	table.insert(
		connections[player],
		humanoid.Died:Connect(function()
			endRun(player, runs[player])
		end)
	)
	endRun(player, runs[player])
end
local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		local run = runs[player]
		if run then
			endRun(player, run)
		end
	end)
	emit(player, nil, "Lobby")
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end
Players.PlayerAdded:Connect(onPlayer)
Players.PlayerRemoving:Connect(function(player)
	local run = runs[player]
	if run then
		CourseService.release(run.id)
	end
	runs[player], versions[player], packets[player], nextLevels[player], buckets[player] = nil, nil, nil, nil, nil
	if connections[player] then
		for _, connection in ipairs(connections[player]) do
			connection:Disconnect()
		end
	end
	connections[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayer(player)
end

Heartbeat:Connect(function()
	local now = os.clock()
	for player, run in pairs(runs) do
		if run.state ~= "Running" or not run.course then
			continue
		end
		CourseService.drive(run.course, now)
		local root = rootOf(player)
		if not root then
			continue
		end
		local position, velocity = root.Position, root.AssemblyLinearVelocity
		local dt = now - run.previousTime
		if dt <= 0 then
			continue
		end
		if not Rules.validMovement(run.previousPosition, position, velocity, dt) then
			resetRun(player, run)
			continue
		end
		local frame = run.course.path:frame(position)
		if position.Y <= run.course.failY + 8 or position.Y > 800 or frame.offset > Rules.CourseRadius then
			resetRun(player, run)
			continue
		end
		local previous = run.previousPosition
		local cp = run.course.checkpoints[run.checkpoint + 1]
		if cp and Rules.crossedPlane(previous, position, cp.CFrame, cp.Size.X / 2 + 2, 220) then
			run.checkpoint += 1
			run.lastProgressAt = now
		end
		if now >= run.graceUntil then
			for _, hazard in ipairs(run.course.hazards) do
				local previousCF = run.hazardsPrevious[hazard] or hazard.CFrame
				if
					Rules.segmentBox(
						previousCF:PointToObjectSpace(previous),
						hazard.CFrame:PointToObjectSpace(position),
						hazard.Size / 2 + Vector3.new(2, 2, 2)
					)
				then
					run.graceUntil = now + Config.Hazard.GraceTime
					run.combo = 0
					run.score = math.max(0, run.score - Config.Score.HazardPenalty)
					root.AssemblyLinearVelocity = velocity * 0.25 - frame.forward * Config.Hazard.Knockback
					Economy.setRunScore(player, run.id, run.score)
					hazardEvent:FireClient(player, run.id)
					break
				end
			end
		end
		for _, hazard in ipairs(run.course.hazards) do
			run.hazardsPrevious[hazard] = hazard.CFrame
		end
		local goal = run.course.goal
		if
			run.checkpoint == #run.course.checkpoints
			and Rules.crossedPlane(previous, position, goal.CFrame, goal.Size.X / 2, goal.Size.Y / 2)
		then
			finishRun(player, run)
		elseif now - run.startedAt > 900 then
			endRun(player, run)
		end
		run.previousPosition, run.previousTime = position, now
		run.observation = { position = position, velocity = velocity, time = now }
	end
end)
task.spawn(function()
	while lobby.Parent do
		LobbyBuilder.renderRank(lobby, Leaderboard.global(), Leaderboard.server())
		task.wait(5)
	end
end)
print("[HOOKMAN] private run service ready")
