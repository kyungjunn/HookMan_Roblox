-- Run only in Studio Edit through MCP. Does not touch production DataStores.
local services = game:GetService("ServerScriptService")
assert(not game:GetService("RunService"):IsRunning(), "Stop play before preparing fixtures")
assert(not services:FindFirstChild("HookmanIntegration"), "Fixture already installed")
local stage = services:FindFirstChild("HookmanStage")
assert(stage and not stage.Disabled, "Production stage must initially be enabled")
local fixture = Instance.new("Folder")
fixture.Name = "HookmanIntegration"
local store = Instance.new("ModuleScript")
store.Name = "TestDataStore"
store.Source = [=[
local Service = { records = {}, calls = 0 }
local function copy(value)
 if type(value) ~= "table" then return value end
 local out = {} for key, child in pairs(value) do out[key] = copy(child) end return out
end
local function getStore(name)
 Service.records[name] = Service.records[name] or {}
 local records = Service.records[name]
 return {
  UpdateAsync = function(_, key, transform)
   Service.calls += 1
   local value = transform(copy(records[key]))
   if value ~= nil then records[key] = copy(value) end
   return value and copy(value) or nil
  end,
  GetSortedAsync = function(_, ascending, limit)
   local entries = {}
   for key, value in pairs(records) do table.insert(entries, {key = key, value = value}) end
   table.sort(entries, function(a, b) return a.value > b.value end)
   while #entries > limit do table.remove(entries) end
   return { GetCurrentPage = function() return entries end }
  end,
 }
end
Service.GetDataStore = function(_, name) return getStore(name) end
Service.GetOrderedDataStore = function(_, name) return getStore(name) end
return Service
]=]
store.Parent = fixture
for _, source in ipairs(services:GetChildren()) do
	if source:IsA("ModuleScript") then
		local clone = source:Clone()
		if clone.Name == "ProfileStore" or clone.Name == "Leaderboard" then
			local old = 'local DataStoreService = game:GetService("DataStoreService")'
			local position = string.find(clone.Source, old, 1, true)
			assert(position, "Persistence fixture substitution missing")
			clone.Source = string.sub(clone.Source, 1, position - 1)
				.. "local DataStoreService = require(script.Parent.TestDataStore)"
				.. string.sub(clone.Source, position + #old)
		end
		clone.Parent = fixture
	end
end
local testStage = stage:Clone()
testStage.Disabled = true
testStage.Parent = fixture
stage.Disabled = true
fixture.Parent = services
testStage.Disabled = false
return "Isolated fixture prepared; production stage disabled; all profile/rank writes use memory only"
