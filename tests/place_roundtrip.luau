local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local path = process.args[1] or "Hookman.rbxl"
local place = roblox.deserializePlace(fs.readFile(path))
local counts = {}
local scripts = 0
for _, object in place:GetDescendants() do
	counts[object.ClassName] = (counts[object.ClassName] or 0) + 1
	if object:IsA("LuaSourceContainer") then
		assert(#object.Source > 0, "Empty source: " .. object:GetFullName())
		if process.args[2] == "--verify-sources" then
			local names, current = {}, object
			while current and current ~= place do
				table.insert(names, 1, current.Name)
				current = current.Parent
			end
			local suffix = object.ClassName == "Script" and ".server.luau"
				or object.ClassName == "LocalScript" and ".client.luau"
				or ".luau"
			local sourcePath = "src/" .. table.concat(names, "/") .. suffix
			assert(object.Source == fs.readFile(sourcePath), "Packaged source mismatch: " .. sourcePath)
		end
		scripts += 1
	end
end
print("Decoded", #place:GetDescendants(), "instances and", scripts, "scripts from", path)
assert(scripts >= 14)
if process.args[2] == "--verify-sources" then
	assert(scripts == 19, "Unexpected script count")
	assert(not place.ReplicatedStorage:FindFirstChild("HookmanJudge"), "Obsolete judge endpoint retained")
	assert(not place.ServerScriptService:FindFirstChild("HookmanIntegration"), "Test fixture leaked into place")
	assert(not place.ServerScriptService.HookmanStage.Disabled, "Production stage is disabled")
	print("All packaged sources match editable files; production entry enabled; no fixture or obsolete endpoint")
end
