--!strict
-- Server-owned profiles, settlement and shop requests. Run judging lives in Stage.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Hookman")
local ShopCatalog = require(Shared:WaitForChild("ShopCatalog"))
local ZoneCatalog = require(Shared:WaitForChild("ZoneCatalog"))
local Leaderboard = require(script.Parent:WaitForChild("Leaderboard"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))
local Economy = {}

export type Profile = {
	coins: number,
	owned: { [string]: boolean },
	equipped: { [string]: string },
	runScore: number,
	bestScore: number,
	lifetimeScore: number,
	zone: string,
}
local MAX_INTEGER = 9007199254740991
local function integer(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= MAX_INTEGER and value % 1 == 0
end
local function cleanNumber(value: any): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.floor(math.clamp(value, 0, MAX_INTEGER))
end
local function remote(name: string, className: string): any
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then
		assert(existing:IsA(className), name .. " has wrong class")
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = ReplicatedStorage
	return instance
end
-- Publish readiness endpoints before any yielding profile acquisition.
local syncEvent = remote("HookmanProfile", "RemoteEvent") :: RemoteEvent
local snapshotFn = remote("HookmanSnapshot", "RemoteFunction") :: RemoteFunction
local shopFn = remote("HookmanShop", "RemoteFunction") :: RemoteFunction

local function sanitize(raw: any): Profile
	local p: Profile = {
		coins = 0,
		owned = {},
		equipped = {},
		runScore = 0,
		bestScore = 0,
		lifetimeScore = 0,
		zone = ZoneCatalog.Default,
	}
	for _, item in ipairs(ShopCatalog.Items) do
		if item.price <= 0 then
			p.owned[item.id] = true
		end
	end
	for _, kind in ipairs(ShopCatalog.Kinds) do
		p.equipped[kind] = ShopCatalog.Defaults[kind]
	end
	if type(raw) ~= "table" then
		return p
	end
	p.coins = cleanNumber(raw.coins)
	p.bestScore = cleanNumber(raw.bestScore)
	p.lifetimeScore = cleanNumber(raw.lifetimeScore)
	if type(raw.owned) == "table" then
		for id, value in pairs(raw.owned) do
			if type(id) == "string" and value == true and ShopCatalog.get(id) then
				p.owned[id] = true
			end
		end
	end
	if type(raw.equipped) == "table" then
		for kind, id in pairs(raw.equipped) do
			if type(kind) == "string" and type(id) == "string" then
				local item = ShopCatalog.get(id)
				if item and item.kind == kind and p.owned[id] then
					p.equipped[kind] = id
				end
			end
		end
	end
	if type(raw.zone) == "string" then
		local zone = ZoneCatalog.get(raw.zone)
		if zone and ZoneCatalog.unlocked(zone, p.lifetimeScore) then
			p.zone = zone.id
		end
	end
	return p
end
local function serialize(p: Profile): any
	local clean = sanitize(p)
	return {
		coins = clean.coins,
		owned = table.clone(clean.owned),
		equipped = table.clone(clean.equipped),
		bestScore = clean.bestScore,
		lifetimeScore = clean.lifetimeScore,
		zone = clean.zone,
	}
end
local states: { [Player]: any } = {}
local shuttingDown = false
local runSnapshotProvider: ((Player) -> any)? = nil
local persistence: any = nil
local storeOK, storeResult = pcall(function()
	return ProfileStore.new({
		sanitize = sanitize,
		serialize = serialize,
		onLost = function(userId: number)
			local player = Players:GetPlayerByUserId(userId)
			if player then
				player:Kick(
					"저장 연결이 만료되었습니다. 기록 보호를 위해 다시 접속해 주세요."
				)
			end
		end,
	})
end)
if storeOK then
	persistence = storeResult
else
	warn("[HOOKMAN] profile store unavailable")
end

function Economy.setRunSnapshotProvider(provider: (Player) -> any)
	runSnapshotProvider = provider
end
function Economy.isReady(player: Player): boolean
	local state = states[player]
	return not shuttingDown
		and state ~= nil
		and not state.leaving
		and persistence ~= nil
		and persistence:isReady(state.session)
end
function Economy.get(player: Player): Profile?
	if not Economy.isReady(player) then
		return nil
	end
	return states[player].session.profile
end
local function snapshot(player: Player): any
	local state = states[player]
	local p = Economy.get(player)
	if not p then
		return { ready = false, revision = state and state.revision or 0 }
	end
	return {
		ready = true,
		revision = state.revision,
		coins = p.coins,
		owned = table.clone(p.owned),
		equipped = table.clone(p.equipped),
		runScore = p.runScore,
		bestScore = p.bestScore,
		lifetimeScore = p.lifetimeScore,
		zone = p.zone,
		rank = Leaderboard.rankOf(player),
		serverRank = Leaderboard.serverRankOf(player),
		run = runSnapshotProvider and runSnapshotProvider(player) or nil,
	}
end
function Economy.sync(player: Player)
	local state = states[player]
	if not state or state.leaving or player.Parent ~= Players then
		return
	end
	state.revision += 1
	syncEvent:FireClient(player, snapshot(player))
end
snapshotFn.OnServerInvoke = function(player: Player)
	return snapshot(player)
end

local function save(player: Player, state: any, revision: number?): boolean
	local ok, saved = persistence:save(state.session, revision)
	if ok and saved then
		-- Only persisted values reach the ordered store, including renewal retry submissions.
		Leaderboard.submit(player, saved.bestScore)
	end
	return ok
end
function Economy.beginRun(player: Player, runId: any, zoneId: string): boolean
	local p = Economy.get(player)
	local state = states[player]
	if not p or runId == nil or state.activeRun ~= nil or type(zoneId) ~= "string" then
		return false
	end
	local zone = ZoneCatalog.get(zoneId)
	if not zone or not ZoneCatalog.unlocked(zone, p.lifetimeScore) then
		return false
	end
	state.activeRun = runId
	state.settled = false
	p.zone = zone.id
	p.runScore = 0
	persistence:markDirty(state.session)
	Economy.sync(player)
	return true
end
function Economy.setRunScore(player: Player, runId: any, score: number): boolean
	local p = Economy.get(player)
	local state = states[player]
	if not p or state.activeRun == nil or state.activeRun ~= runId or state.settled or not integer(score) then
		return false
	end
	p.runScore = score
	return true
end
function Economy.finishRun(player: Player, runId: any, total: number, coins: number): (boolean, boolean)
	local p = Economy.get(player)
	local state = states[player]
	if
		not p
		or state.activeRun == nil
		or state.activeRun ~= runId
		or state.settled
		or not integer(total)
		or not integer(coins)
		or p.coins > MAX_INTEGER - coins
		or p.lifetimeScore > MAX_INTEGER - total
	then
		return false, false
	end
	state.settled = true -- At-most-once, before the datastore can yield.
	p.coins += coins
	p.bestScore = math.max(p.bestScore, total)
	p.lifetimeScore += total
	p.runScore = 0
	local revision = persistence:markDirty(state.session)
	Economy.sync(player)
	return true, save(player, state, revision)
end
function Economy.endRun(player: Player, runId: any)
	local state = states[player]
	if not state or state.activeRun == nil or state.activeRun ~= runId then
		return
	end
	state.activeRun = nil
	state.settled = false
	if state.session and state.session.profile then
		state.session.profile.runScore = 0
	end
	Economy.sync(player)
end
-- Server-only convenience accessors; never fabricate a usable profile before readiness.
function Economy.trySetZone(player: Player, id: string): (boolean, string)
	local p = Economy.get(player)
	if not p then
		return false, "데이터를 불러오는 중입니다"
	end
	if states[player].activeRun ~= nil then
		return false, "런 종료 후 변경할 수 있습니다"
	end
	if type(id) ~= "string" or #id > 80 then
		return false, "잘못된 요청"
	end
	local zone = ZoneCatalog.get(id)
	if not zone then
		return false, "없는 존"
	end
	if not ZoneCatalog.unlocked(zone, p.lifetimeScore) then
		return false, ("누적 %d 점 필요"):format(zone.requireScore)
	end
	p.zone = zone.id
	persistence:markDirty(states[player].session)
	Economy.sync(player)
	return true, zone.name .. " 선택"
end
shopFn.OnServerInvoke = function(player: Player, action: any, id: any)
	local state = states[player]
	if not state then
		return { ok = false, msg = "데이터를 불러오는 중입니다" }
	end
	local now = os.clock()
	if now - state.lastShop < 0.2 then
		return { ok = false, msg = "잠시 후 다시 시도해 주세요" }
	end
	state.lastShop = now
	if type(action) ~= "string" or #action > 16 or type(id) ~= "string" or #id == 0 or #id > 80 then
		return { ok = false, msg = "잘못된 요청" }
	end
	local p = Economy.get(player)
	if not p then
		return { ok = false, msg = "데이터를 불러오는 중입니다" }
	end
	if state.activeRun ~= nil then
		return { ok = false, msg = "런 종료 후 변경할 수 있습니다" }
	end
	if action == "zone" then
		local ok, msg = Economy.trySetZone(player, id)
		return { ok = ok, msg = msg }
	end
	if action ~= "buy" and action ~= "equip" then
		return { ok = false, msg = "알 수 없는 동작" }
	end
	local item = ShopCatalog.get(id)
	if not item then
		return { ok = false, msg = "없는 아이템" }
	end
	if action == "buy" then
		if p.owned[id] then
			return { ok = false, msg = "이미 보유" }
		end
		if not integer(item.price) or p.coins < item.price then
			return { ok = false, msg = "코인 부족" }
		end
		p.coins -= item.price
		p.owned[id] = true
	elseif not p.owned[id] then
		return { ok = false, msg = "미보유" }
	end
	p.equipped[item.kind] = id
	persistence:markDirty(state.session)
	Economy.sync(player)
	return { ok = true, msg = action == "buy" and "구매 완료" or "장착" }
end

local function join(player: Player)
	if states[player] or shuttingDown then
		return
	end
	local state: any = { revision = 0, lastShop = -math.huge, leaving = false }
	states[player] = state
	if not persistence then
		player:Kick("데이터 저장소에 연결할 수 없습니다. 잠시 후 다시 접속해 주세요.")
		return
	end
	local session = persistence:acquire(player.UserId, function()
		return shuttingDown or state.leaving or player.Parent ~= Players or states[player] ~= state
	end)
	if not session then
		if not state.leaving and player.Parent == Players then
			player:Kick(
				"데이터를 안전하게 불러오지 못했습니다. 다른 접속을 종료한 뒤 잠시 후 다시 접속해 주세요."
			)
		end
		return
	end
	state.session = session
	Economy.sync(player)
	Leaderboard.submit(player, session.savedData.bestScore)
end
local function leave(player: Player)
	local state = states[player]
	if not state then
		return
	end
	state.leaving = true
	if persistence and state.session then
		local released, saved = persistence:release(state.session)
		if released and saved and integer(saved.bestScore) then
			Leaderboard.submit(player, saved.bestScore)
		end
	end
	if states[player] == state then
		states[player] = nil
	end
end
Players.PlayerAdded:Connect(join)
Players.PlayerRemoving:Connect(leave)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(join, player)
end
-- Renew even clean profiles; one worker per profile prevents overlapping periodic jobs.
task.spawn(function()
	while not shuttingDown do
		task.wait(15)
		for player, state in pairs(states) do
			if Economy.isReady(player) then
				Economy.sync(player) -- Rank cache changes are reflected without Heartbeat spam.
				if not state.saving then
					state.saving = true
					task.spawn(function()
						save(player, state)
						state.saving = false
					end)
				end
			end
		end
	end
end)
game:BindToClose(function()
	shuttingDown = true
	local queue = {}
	for player, state in pairs(states) do
		state.leaving = true
		table.insert(queue, player)
	end
	local index, workers = 0, math.min(4, #queue)
	local remaining = workers
	for _ = 1, workers do
		task.spawn(function()
			while true do
				index += 1
				local player = queue[index]
				if not player then
					break
				end
				leave(player)
			end
			remaining -= 1
		end)
	end
	local deadline = os.clock() + 25
	-- Also wait for canceled acquisitions to finish their token-only cleanup.
	while os.clock() < deadline do
		local pending = persistence and next(persistence.sessions) ~= nil
		if remaining == 0 and not pending then
			break
		end
		task.wait(0.05)
	end
end)
return Economy
