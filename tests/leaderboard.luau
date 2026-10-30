local fs = require("@lune/fs")
local passed = 0
local function signal()
	local handlers = {}
	return {
		Connect = function(_, callback)
			table.insert(handlers, callback)
		end,
		Fire = function(_, ...)
			for _, callback in ipairs(handlers) do
				callback(...)
			end
		end,
	}
end
local function fixture()
	local workers, records, failures = {}, {}, 0
	local players = { PlayerRemoving = signal() }
	local player = { UserId = 1, DisplayName = "Tester", Parent = players }
	function players:GetPlayerByUserId(id)
		return id == 1 and player.Parent and player or nil
	end
	local datastore = {
		UpdateAsync = function(_, key, transform)
			if failures > 0 then
				failures -= 1
				error("temporary failure")
			end
			local nextValue = transform(records[key])
			records[key] = nextValue
			return nextValue
		end,
	}
	local environment = setmetatable({
		game = {
			GetService = function(_, name)
				if name == "Players" then
					return players
				end
				return {
					GetOrderedDataStore = function()
						return datastore
					end,
				}
			end,
		},
		task = {
			spawn = function(callback, ...)
				table.insert(workers, { callback, table.pack(...) })
			end,
			wait = function() end,
		},
		warn = function() end,
	}, { __index = getfenv() })
	local chunk = assert(loadstring(fs.readFile("src/ServerScriptService/Leaderboard.luau")))
	setfenv(chunk, environment)
	local board = chunk()
	-- Worker 1 is the periodic query loop, intentionally not executed by this deterministic fixture.
	local index = 2
	local function flush()
		while index <= #workers do
			local worker = workers[index]
			index += 1
			worker[1](table.unpack(worker[2], 1, worker[2].n))
		end
	end
	return board, player, players, records, flush, function(count)
		failures = count
	end
end
local function test(name, callback)
	callback()
	passed += 1
	print("PASS", name)
end
test("coalesced writes cannot lower an existing global best", function()
	local board, player, _, records, flush = fixture()
	records["1"] = 500
	board.submit(player, 100)
	board.submit(player, 300)
	board.submit(player, 200)
	flush()
	assert(records["1"] == 500)
	assert(board.server()[1].score == 300)
end)
test("same-score submission retries a previously exhausted write", function()
	local board, player, _, records, flush, fail = fixture()
	fail(3)
	board.submit(player, 100)
	flush()
	assert(records["1"] == nil)
	board.submit(player, 100)
	flush()
	assert(records["1"] == 100)
end)
test("late completed writes cannot resurrect departed live ranking", function()
	local board, player, players, records, flush = fixture()
	board.submit(player, 100)
	players.PlayerRemoving:Fire(player)
	player.Parent = nil
	flush()
	assert(records["1"] == 100 and #board.server() == 0)
	board.submit(player, 120)
	flush()
	assert(records["1"] == 120 and #board.server() == 0)
end)
test("nonfinite negative and fractional scores are rejected", function()
	local board, player, _, records, flush = fixture()
	for _, value in ipairs({ 0 / 0, math.huge, -1, 2.5 }) do
		board.submit(player, value)
	end
	flush()
	assert(next(records) == nil and #board.server() == 0)
end)
print(passed .. " leaderboard tests passed")
