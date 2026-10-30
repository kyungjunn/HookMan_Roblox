--!strict
-- HOOKMAN 랭킹.
--
-- 두 축을 같이 보여준다:
--   글로벌 = OrderedDataStore 상위 N. 서버를 넘어선 장기 경쟁.
--   서버   = 지금 이 서버에 있는 사람들의 최고 점수. 당장 옆 사람과의 경쟁.
--
-- 글로벌만 두면 신규 서버·Studio 에서 늘 비어 보이고(=경쟁이 없는 것처럼 읽힌다),
-- 서버만 두면 목표가 너무 작다. 둘 다 있어야 "오늘의 상대"와 "최종 목표"가 동시에 생긴다.
--
-- Economy 를 require 하지 않는다. Economy 가 submit() 으로 밀어 넣는 단방향이라
-- 순환 참조가 없고, 랭킹이 죽어도 경제는 계속 돈다.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local Leaderboard = {}

export type Entry = { userId: number, name: string, score: number }

-- v1 이 아니라 v2 다. 점수 밸런스가 바뀌면 예전 기록과 같은 표에 두면 안 된다.
-- 콤보 상한 3.0 시절 점수와 4.0 시절 점수는 애초에 다른 게임의 숫자다.
local ODS_NAME = "HookmanBest_v2"
local TOP_N = 10
local SERVER_N = 5
local REFRESH = 45
local MIN_REFRESH = 15
local MAX_SCORE = 9007199254740991
local MAX_WRITE_ATTEMPTS = 3

-- DataStore 는 Studio 에서 API 서비스가 꺼져 있으면 통째로 실패한다.
-- 저장/조회 전부 "실패해도 되는 것"으로 취급한다. 랭킹이 안 뜨는 건 버그지만
-- 랭킹 때문에 게임이 죽는 건 사고다.
local ods: OrderedDataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetOrderedDataStore(ODS_NAME)
	end)
	ods = ok and s or nil
	if not ok then
		warn(("[HOOKMAN] rank store unavailable: %s"):format(tostring(s)))
	end
end

local cachedGlobal: { Entry } = {}
local liveBest: { [Player]: number } = {}
-- PlayerRemoving fires before Parent changes; weak keys cover late saves
-- during that interval without retaining disconnected Player instances.
local departed: { [Player]: boolean } = setmetatable({}, { __mode = "k" })
local nameCache: { [number]: string } = {}
local dirty = false
type WriteState = { pending: number, confirmed: number, running: boolean }
local writes: { [number]: WriteState } = {}

local function validScore(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= MAX_SCORE and value % 1 == 0
end

-- Only one worker owns a user's writes, including across leave/rejoin. Workers
-- never touch liveBest: a save finishing after PlayerRemoving cannot restore it.
local function flushUser(userId: number, state: WriteState)
	local attempts = 0
	while state.pending > state.confirmed and attempts < MAX_WRITE_ATTEMPTS do
		local submitted = state.pending
		local ok, result = pcall(function()
			return (ods :: OrderedDataStore):UpdateAsync(tostring(userId), function(old)
				if old == nil then
					return submitted
				end
				if not validScore(old) then
					error("invalid stored leaderboard score")
				end
				return math.max(old, submitted)
			end)
		end)
		if ok and validScore(result) and result >= submitted then
			state.confirmed = math.max(state.confirmed, result)
			attempts = 0
			dirty = true
		else
			attempts += 1
			warn(
				("[HOOKMAN] rank submit failed for %d (attempt %d/%d): %s"):format(
					userId,
					attempts,
					MAX_WRITE_ATTEMPTS,
					tostring(result)
				)
			)
			if attempts < MAX_WRITE_ATTEMPTS then
				task.wait(2 ^ (attempts - 1))
			end
		end
	end
	state.running = false
	-- Connected users retain failed pending values so even a same-score heartbeat
	-- retries them. Disconnected users retain no idle per-player state.
	local player = Players:GetPlayerByUserId(userId)
	if not player or departed[player] then
		writes[userId] = nil
	end
end

----------------------------------------------------------------------
-- 제출
----------------------------------------------------------------------
-- bestScore(개인 최고)만 올린다. 누적 점수로 줄을 세우면 오래 접속한 사람이 이기는
-- 출석 랭킹이 되고, 런 점수로 줄을 세우면 매 런 갱신이라 순위가 의미를 잃는다.
function Leaderboard.submit(plr: Player, bestScore: number)
	if not validScore(bestScore) then
		warn(("[HOOKMAN] invalid rank score for %d"):format(plr.UserId))
		return
	end
	if plr.Parent == Players and not departed[plr] then
		liveBest[plr] = math.max(liveBest[plr] or 0, bestScore)
		nameCache[plr.UserId] = plr.DisplayName
	end
	if not ods then
		return
	end
	local userId = plr.UserId
	local state = writes[userId]
	if not state then
		state = { pending = bestScore, confirmed = -1, running = false }
		writes[userId] = state
	else
		state.pending = math.max(state.pending, bestScore)
	end
	if not state.running and state.pending > state.confirmed then
		state.running = true
		task.spawn(flushUser, userId, state)
	end
end

----------------------------------------------------------------------
-- 조회
----------------------------------------------------------------------
local function nameOf(userId: number): string
	local n = nameCache[userId]
	if n then
		return n
	end
	local ok, got = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	n = ok and got or ("User%d"):format(userId)
	nameCache[userId] = n
	return n
end

local function fetchGlobal()
	if not ods then
		return
	end
	local ok, pages = pcall(function()
		return (ods :: OrderedDataStore):GetSortedAsync(false, TOP_N)
	end)
	if not ok then
		warn(("[HOOKMAN] rank refresh failed: %s"):format(tostring(pages)))
		return
	end
	local out: { Entry } = {}
	for _, row in ipairs(pages:GetCurrentPage()) do
		local uid = tonumber(row.key)
		if uid and uid > 0 and uid % 1 == 0 and uid <= MAX_SCORE and validScore(row.value) then
			table.insert(out, { userId = uid, name = nameOf(uid), score = row.value })
		end
	end
	cachedGlobal = out
end

function Leaderboard.global(): { Entry }
	return cachedGlobal
end

-- 이 서버 사람들만. 접속 중인 플레이어라 이름 조회가 필요 없다.
function Leaderboard.server(): { Entry }
	local out: { Entry } = {}
	for plr, score in pairs(liveBest) do
		if plr.Parent == Players then
			table.insert(out, { userId = plr.UserId, name = plr.DisplayName, score = score })
		end
	end
	table.sort(out, function(a, b)
		return a.score > b.score
	end)
	while #out > SERVER_N do
		table.remove(out)
	end
	return out
end

-- 글로벌 상위 N 안에서의 순위. 밖이면 nil.
-- "11위" 같은 정확한 전체 순위는 ODS 로는 페이지를 다 넘겨야 나온다. 그만한 값이 없다.
function Leaderboard.rankOf(plr: Player): number?
	for i, e in ipairs(cachedGlobal) do
		if e.userId == plr.UserId then
			return i
		end
	end
	return nil
end

-- 이 서버 안에서의 순위. 항상 나온다 (혼자면 1위).
function Leaderboard.serverRankOf(plr: Player): number
	local mine = liveBest[plr] or 0
	local rank = 1
	for other, score in pairs(liveBest) do
		if other ~= plr and other.Parent == Players and score > mine then
			rank += 1
		end
	end
	return rank
end

-- 갱신 요청. 다음 주기에 글로벌을 다시 읽는다.
-- 클리어할 때마다 즉시 GetSortedAsync 를 때리면 DataStore 요청 한도에 바로 걸린다.
function Leaderboard.markDirty()
	dirty = true
end

Players.PlayerRemoving:Connect(function(plr)
	departed[plr] = true
	liveBest[plr] = nil
	nameCache[plr.UserId] = nil
	local state = writes[plr.UserId]
	if state and not state.running then
		writes[plr.UserId] = nil
	end
end)

task.spawn(function()
	fetchGlobal()
	local lastRefresh = os.clock()
	while true do
		task.wait(1)
		local elapsed = os.clock() - lastRefresh
		-- Dirty requests may accelerate a refresh, but never bypass its cooldown.
		-- Other servers' writes become visible even if this server stays idle.
		if elapsed >= REFRESH or (dirty and elapsed >= MIN_REFRESH) then
			dirty = false
			fetchGlobal()
			lastRefresh = os.clock()
		end
	end
end)

return Leaderboard
