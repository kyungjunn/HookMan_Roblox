--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CourseBuilder = require(script.Parent.CourseBuilder)
local CoursePath = require(ReplicatedStorage.Hookman.CoursePath)
local CourseService = {}
local root = Instance.new("Folder")
root.Name = "HookmanCourses"
root.Parent = workspace
local slots = {}
local active = {}
local SLOT_SPACING = 12000 -- maximum course length < 3100, plus lateral play bounds
local MAX_SLOTS = math.max(1, game:GetService("Players").MaxPlayers)

function CourseService.acquire(runId: string, ownerId: number, level: number, zone)
	assert(not active[runId], "Duplicate course allocation")
	local slot
	for i = 1, MAX_SLOTS do
		if not slots[i] then
			slot = i
			break
		end
	end
	if not slot then
		return nil, "빈 코스가 없습니다"
	end
	slots[slot] = runId
	local folder
	local ok, result = pcall(function()
		folder = CourseBuilder.build(level, zone.palette)
		folder.Name = "Course_" .. runId
		folder:SetAttribute("RunId", runId)
		folder:SetAttribute("OwnerId", ownerId)
		folder:SetAttribute("Zone", zone.id)
		local offset = Vector3.new(slot * SLOT_SPACING, 0, 0)
		for _, object in ipairs(folder:GetDescendants()) do
			if object:IsA("BasePart") then
				object.CFrame += offset
				local base = object:GetAttribute("Base")
				if typeof(base) == "CFrame" then
					object:SetAttribute("Base", base + offset)
				end
			end
		end
		folder:SetAttribute("PathNodeCount", #folder.PathNodes:GetChildren())
		local path = CoursePath.new(folder)
		local checkpoints, hazards, hooks = {}, {}, {}
		for _, cp in ipairs(folder.Checkpoints:GetChildren()) do
			table.insert(checkpoints, cp)
		end
		table.sort(checkpoints, function(a, b)
			return path:distanceAlong(a.Position) < path:distanceAlong(b.Position)
		end)
		for _, hazard in ipairs(folder.Hazards:GetChildren()) do
			table.insert(hazards, hazard)
		end
		for _, hook in ipairs(folder.HookPoints:GetChildren()) do
			hooks[hook.Name] = hook
		end
		folder.Parent = root
		return {
			folder = folder,
			path = path,
			checkpoints = checkpoints,
			hazards = hazards,
			hooks = hooks,
			goal = folder.GoalPad,
			start = folder.StartPad,
			failY = folder.FailPlane.Position.Y,
			slot = slot,
		}
	end)
	if not ok then
		if folder then
			folder:Destroy()
		end
		slots[slot] = nil
		warn("[HOOKMAN] course allocation failed: " .. tostring(result))
		return nil, "코스를 준비하지 못했습니다"
	end
	active[runId] = result
	return result
end
function CourseService.release(runId: string)
	local course = active[runId]
	if not course then
		return
	end
	active[runId] = nil
	slots[course.slot] = nil
	course.folder:Destroy()
end
function CourseService.drive(course, now: number)
	for _, hazard in ipairs(course.hazards) do
		local kind, base = hazard:GetAttribute("Kind"), hazard:GetAttribute("Base")
		if typeof(base) ~= "CFrame" then
			continue
		end
		local w = now * (hazard:GetAttribute("Speed") or 1) + (hazard:GetAttribute("Phase") or 0)
		local amp = hazard:GetAttribute("Amp") or 0
		if kind == "Sweeper" then
			hazard.CFrame = base * CFrame.new(math.sin(w) * amp, 0, 0)
		elseif kind == "Spinner" then
			hazard.CFrame = base * CFrame.Angles(0, w, 0)
		elseif kind == "Bobber" then
			hazard.CFrame = base * CFrame.new(0, math.sin(w) * amp, 0)
		end
	end
end
return CourseService
