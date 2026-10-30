local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Vector3, CFrame = roblox.Vector3, roblox.CFrame
local passed = 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		error(name .. ": " .. tostring(err), 0)
	end
	passed += 1
	print("PASS", name)
end
local cache = {}
local modules = {
	Config = "src/ReplicatedStorage/Hookman/Config.luau",
	RunRules = "src/ReplicatedStorage/Hookman/RunRules.luau",
	RewardRules = "src/ReplicatedStorage/Hookman/RewardRules.luau",
	ReleaseJudge = "src/ReplicatedStorage/Hookman/ReleaseJudge.luau",
	CoursePath = "src/ReplicatedStorage/Hookman/CoursePath.luau",
	HookService = "src/ServerScriptService/HookService.luau",
	ProfileStore = "src/ServerScriptService/ProfileStore.luau",
}
local shared = { Config = "Config", RunRules = "RunRules", ReleaseJudge = "ReleaseJudge" }
local function loadModule(name)
	if cache[name] then
		return cache[name]
	end
	local chunk = assert(loadstring(fs.readFile(modules[name]), "@" .. modules[name]))
	local environment = setmetatable({
		Vector3 = Vector3,
		CFrame = CFrame,
		Color3 = roblox.Color3,
		script = { Parent = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}) },
		game = {
			JobId = "test",
			GetService = function(_, service)
				if service == "ReplicatedStorage" then
					return { Hookman = shared }
				end
				return {}
			end,
		},
		require = loadModule,
	}, { __index = getfenv() })
	setfenv(chunk, environment)
	cache[name] = chunk()
	return cache[name]
end
local Rules = loadModule("RunRules")
local Rewards = loadModule("RewardRules")
local Config = loadModule("Config")
local Profiles = loadModule("ProfileStore")
local Hooks = loadModule("HookService")
local zone = { scoreMul = 1, coinMul = 1, startLevel = 1, maxLevel = 6 }
local effect = { scoreMul = 1, perfectMul = 1, dualRope = false }
local straightPath = {
	forwardAt = function()
		return Vector3.zAxis
	end,
}

test("finite values and request sequence bounds", function()
	assert(not Rules.finite(0 / 0) and not Rules.finite(math.huge))
	assert(not Rules.integer(1.2, 1, 10) and not Rules.integer("1", 1, 10))
	assert(not Rules.integer(0, 1, 10) and Rules.integer(10, 1, 10))
end)
test("movement rejects teleport, nonfinite velocity and stale samples", function()
	assert(Rules.validMovement(Vector3.zero, Vector3.new(4, 0, 0), Vector3.new(200, 0, 0), 0.02))
	assert(not Rules.validMovement(Vector3.zero, Vector3.new(1000, 0, 0), Vector3.zero, 0.02))
	assert(not Rules.validMovement(Vector3.zero, Vector3.zero, Vector3.new(math.huge, 0, 0), 0.02))
	assert(not Rules.validMovement(Vector3.zero, Vector3.zero, Vector3.zero, 1))
end)
test("finish requires directional crossing inside width and height", function()
	local cf = CFrame.lookAt(Vector3.zero, Vector3.zAxis)
	assert(Rules.crossedPlane(Vector3.new(0, 0, -20), Vector3.new(0, 0, 20), cf, 160, 250))
	assert(not Rules.crossedPlane(Vector3.new(0, 0, 20), Vector3.new(0, 0, -20), cf, 160, 250))
	assert(not Rules.crossedPlane(Vector3.new(10000, 0, -20), Vector3.new(10000, 0, 20), cf, 160, 250))
	assert(not Rules.crossedPlane(Vector3.new(0, 1000, -20), Vector3.new(0, 1000, 20), cf, 160, 250))
	assert(not Rules.crossedPlane(Vector3.new(0, 0, 10), Vector3.new(0, 0, 20), cf, 160, 250))
end)
test("swept collision catches thin obstacle and rejects parallel miss", function()
	assert(Rules.segmentBox(Vector3.new(0, 0, -100), Vector3.new(0, 0, 100), Vector3.new(4, 4, 1)))
	assert(not Rules.segmentBox(Vector3.new(10, 0, -100), Vector3.new(10, 0, 100), Vector3.new(4, 4, 1)))
	assert(Rules.segmentBox(Vector3.zero, Vector3.zero, Vector3.one))
end)
test("score whitelist blocks Config keys and bad combos", function()
	assert(Rewards.judge("PERFECT", 30, effect, zone) == 480)
	assert(not pcall(Rewards.judge, "ClearBonus", 30, effect, zone))
	assert(not pcall(Rewards.judge, "PERFECT", 0 / 0, effect, zone))
	assert(not pcall(Rewards.judge, "PERFECT", math.huge, effect, zone))
end)
test("reward conversion separates zone score and coin multipliers", function()
	local total, coins = Rewards.finish(1200, 1, zone)
	assert(total == 1600 and coins == 80)
	local high = { scoreMul = 3.2, coinMul = 1.6, startLevel = 16, maxLevel = 20 }
	local highTotal, highCoins = Rewards.finish(3840, 16, high)
	assert(highTotal == 9920 and highCoins == 248)
end)

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, entry in pairs(value) do
		result[key] = deepCopy(entry)
	end
	return result
end
local function fixture()
	local state = { now = 1000, records = {}, failures = 0, calls = 0, lost = 0 }
	local store = {}
	function store:UpdateAsync(key, transform)
		state.calls += 1
		if state.failures > 0 then
			state.failures -= 1
			error("injected datastore outage")
		end
		local nextValue = transform(deepCopy(state.records[key]))
		if nextValue ~= nil then
			state.records[key] = deepCopy(nextValue)
			return deepCopy(nextValue)
		end
		return nil
	end
	local function make(job, token)
		return Profiles.new({
			store = store,
			clock = function()
				return state.now
			end,
			wait = function(seconds)
				state.now += seconds
			end,
			token = function()
				return token
			end,
			jobId = job,
			sanitize = function(raw)
				return { coins = type(raw) == "table" and raw.coins or 0 }
			end,
			serialize = deepCopy,
			onLost = function()
				state.lost += 1
			end,
		})
	end
	return state, make
end

test("load failure cannot overwrite existing profile", function()
	local state, make = fixture()
	state.records.p1 = { coins = 987 }
	state.failures = 20
	local profiles = make("job-a", "token-a")
	assert(profiles:acquire(1, function()
		return false
	end) == nil)
	assert(state.records.p1.coins == 987)
	assert(profiles.sessions[1] == nil)
end)
test("unexpired session prevents concurrent ownership", function()
	local state, make = fixture()
	local a, b = make("job-a", "token-a"), make("job-b", "token-b")
	local session = a:acquire(1, function()
		return false
	end)
	assert(session and not b:acquire(1, function()
		return false
	end))
	assert(state.records.p1._session.token == "token-a")
end)
test("expired lease cannot save over a new owner", function()
	local state, make = fixture()
	local a, b = make("job-a", "token-a"), make("job-b", "token-b")
	local old = a:acquire(1, function()
		return false
	end)
	state.now += 121
	local current = b:acquire(1, function()
		return false
	end)
	assert(current)
	old.profile.coins = 500
	assert(not a:save(old))
	assert(state.records.p1.coins == 0 and state.records.p1._session.token == "token-b")
end)
test("ownership stolen before expiry stops writes", function()
	local state, make = fixture()
	local profiles = make("job-a", "token-a")
	local session = profiles:acquire(1, function()
		return false
	end)
	state.records.p1._session.token = "another-owner"
	session.profile.coins = 100
	profiles:markDirty(session)
	assert(not profiles:save(session))
	assert(session.lost and state.lost == 1 and state.records.p1.coins == 0)
end)
test("save and release persist current revision without session metadata", function()
	local state, make = fixture()
	local profiles = make("job-a", "token-a")
	local session = profiles:acquire(1, function()
		return false
	end)
	session.profile.coins = 35
	local revision = profiles:markDirty(session)
	assert(profiles:save(session, revision))
	assert(state.records.p1.coins == 35)
	session.profile.coins = 50
	profiles:markDirty(session)
	assert(profiles:release(session))
	assert(state.records.p1.coins == 50 and state.records.p1._session == nil)
	assert(not profiles:save(session))
end)
test("canceled acquisition releases only its own lease", function()
	local state, make = fixture()
	local profiles = make("job-a", "token-a")
	local checks = 0
	local session = profiles:acquire(1, function()
		checks += 1
		return checks >= 3
	end)
	assert(session == nil and state.records.p1._session == nil)
end)

test("hook validation rejects foreign targets and unowned dual rope", function()
	local course = roblox.Instance.new("Folder")
	local hook = roblox.Instance.new("Part")
	hook.Name, hook.Position, hook.Parent = "Hook_01_L", Vector3.new(-40, 80, 50), course
	hook:SetAttribute("Side", -1)
	local other = roblox.Instance.new("Part")
	other.Name, other.Position, other.Parent = "Hook_01_R", Vector3.new(40, 80, 50), course
	other:SetAttribute("Side", 1)
	local root = roblox.Instance.new("Part")
	root.Position = Vector3.zero
	local run = {
		id = "run",
		combo = 0,
		effect = effect,
		course = { folder = course, path = straightPath, hooks = { Hook_01_L = hook, Hook_01_R = other } },
		scoredHooks = {},
	}
	assert(not Hooks.handle(run, { action = "attach", sequence = 1, hookId = "foreign" }, 1, root).accepted)
	assert(Hooks.handle(run, { action = "attach", sequence = 2, hookId = hook.Name }, 1, root).accepted)
	assert(
		not Hooks.handle(run, { action = "attach", sequence = 3, hookId = other.Name, secondary = true }, 1.1, root).accepted
	)
	local released = Hooks.handle(run, { action = "release", sequence = 4 }, 1.01, root)
	assert(not released.accepted and released.reason == "attachment_time")
	assert(not Hooks.handle(run, { action = "release", sequence = 5 }, 2, root).accepted)
end)
test("one hook cannot farm score and release cannot award twice", function()
	local course, hook, root = roblox.Instance.new("Folder"), roblox.Instance.new("Part"), roblox.Instance.new("Part")
	hook.Name, hook.Position, hook.Parent = "Hook", Vector3.new(0, 80, 60), course
	root.Position = Vector3.zero
	local run = {
		id = "run",
		combo = 0,
		effect = effect,
		course = { folder = course, path = straightPath, hooks = { Hook = hook } },
		scoredHooks = {},
	}
	for i = 1, 2 do
		local start = i * 2
		assert(Hooks.handle(run, { action = "attach", sequence = i * 2 - 1, hookId = "Hook" }, start, root).accepted)
		run.observation = { position = Vector3.zero, velocity = Vector3.new(0, 50, 86.60254), time = start + 0.3 }
		local verdict = Hooks.handle(run, { action = "release", sequence = i * 2 }, start + 0.31, root)
		assert(verdict.accepted and verdict.grade == "PERFECT")
		assert(verdict.award == (i == 1) and run.combo == 1)
	end
	assert(not Hooks.handle(run, { action = "release", sequence = 5 }, 5, root).accepted)
end)
test("path instances never share another course geometry", function()
	local Path = loadModule("CoursePath")
	local function courseAt(x)
		local folder = roblox.Instance.new("Folder")
		local nodes = roblox.Instance.new("Folder")
		nodes.Name = "PathNodes"
		nodes.Parent = folder
		for i = 1, 3 do
			local p = roblox.Instance.new("Part")
			p.Name = string.format("Node_%03d", i)
			p.Position = Vector3.new(x, 0, i * 100)
			p.Parent = nodes
		end
		return folder
	end
	local a, b = Path.new(courseAt(0)), Path.new(courseAt(12000))
	assert(a:frame(Vector3.new(0, 0, 150)).offset == 0)
	assert(b:frame(Vector3.new(0, 0, 150)).offset == 12000)
	assert(a:distanceAlong(Vector3.new(0, 0, 150)) == 50)
end)
print(string.format("%d unit tests passed", passed))
