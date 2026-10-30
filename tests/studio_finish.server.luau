-- A bounded movement driver exercises real checkpoint/finish code; fixture persistence only.
local Players = game:GetService("Players")
local Heartbeat = game:GetService("RunService").Heartbeat
local Economy = require(script.Parent.Economy)
local Path = require(game.ReplicatedStorage.Hookman.CoursePath)
local player = Players:GetPlayers()[1]
local course
local deadline = os.clock() + 10
repeat
	for _, child in ipairs(workspace.HookmanCourses:GetChildren()) do
		if child:GetAttribute("OwnerId") == player.UserId then
			course = child
			break
		end
	end
	if not course then
		task.wait(0.05)
	end
until course or os.clock() > deadline
assert(course, "Start a run before executing finish driver")
local root = player.Character.HumanoidRootPart
local before = table.clone(Economy.get(player))
local path = Path.new(course)
local distance = path:distanceAlong(root.Position)
local y = root.Position.Y
root.Anchored = true
local ok, message = pcall(function()
	local finish = path:distanceAlong(course.GoalPad.Position) + 8
	local start = os.clock()
	while distance < finish and course.Parent and os.clock() - start < 20 do
		local dt = Heartbeat:Wait()
		distance = math.min(distance + 180 * math.min(dt, 0.05), finish)
		local p, forward = path:atDistance(distance)
		root.CFrame = CFrame.lookAt(Vector3.new(p.X, y, p.Z), Vector3.new(p.X, y, p.Z) + forward)
		root.AssemblyLinearVelocity = Vector3.zero
	end
	local untilReturn = os.clock() + 5
	while course.Parent and os.clock() < untilReturn do
		task.wait(0.05)
	end
	assert(not course.Parent, "Course was not reclaimed after finish")
	local after = Economy.get(player)
	assert(after.lifetimeScore == before.lifetimeScore + 400, "Checkpoint/finish reward mismatch")
	assert(after.coins == before.coins + 20, "Coin settlement mismatch")
	assert(after.runScore == 0)
	script:SetAttribute("Report", "PASS sequential checkpoints -> finish -> saved once -> lobby -> course reclaimed")
end)
root.Anchored = false
script:SetAttribute("Complete", true)
if not ok then
	script:SetAttribute("Report", "FAIL " .. tostring(message))
	error(message)
end
