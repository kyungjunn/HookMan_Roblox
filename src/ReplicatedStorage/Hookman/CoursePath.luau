--!strict
-- Immutable path objects belong to a specific course, never a global workspace lookup.
local CoursePath = {}
CoursePath.__index = CoursePath

function CoursePath.new(course: Instance)
	local parts = {}
	local folder = course:FindFirstChild("PathNodes")
	assert(folder, "Course has no PathNodes")
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			table.insert(parts, part)
		end
	end
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)
	assert(#parts >= 2, "Course needs at least two path nodes")
	local expected = course:GetAttribute("PathNodeCount")
	assert(expected == nil or #parts == expected, "Course path is still replicating")
	local nodes, cumulative = {}, { 0 }
	for i, part in ipairs(parts) do
		nodes[i] = Vector3.new(part.Position.X, 0, part.Position.Z)
		if i > 1 then
			assert((nodes[i] - nodes[i - 1]).Magnitude > 0.001, "Duplicate path node")
			cumulative[i] = cumulative[i - 1] + (nodes[i] - nodes[i - 1]).Magnitude
		end
	end
	return setmetatable({ nodes = nodes, cumulative = cumulative, course = course }, CoursePath)
end

function CoursePath:frame(position: Vector3)
	local p = Vector3.new(position.X, 0, position.Z)
	local bestI, bestT, bestD2 = 1, 0, math.huge
	for i = 1, #self.nodes - 1 do
		local a, b = self.nodes[i], self.nodes[i + 1]
		local ab = b - a
		local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
		local delta = p - (a + ab * t)
		local d2 = delta:Dot(delta)
		if d2 < bestD2 then
			bestI, bestT, bestD2 = i, t, d2
		end
	end
	local a, b = self.nodes[bestI], self.nodes[bestI + 1]
	local segment = b - a
	local forward = segment.Unit
	local right = forward:Cross(Vector3.yAxis)
	local point = a + segment * bestT
	return {
		point = point,
		forward = forward,
		right = right,
		distance = self.cumulative[bestI] + segment.Magnitude * bestT,
		lateral = (p - point):Dot(right),
		offset = math.sqrt(bestD2),
	}
end

function CoursePath:forwardAt(position: Vector3): Vector3
	return self:frame(position).forward
end
function CoursePath:rightAt(position: Vector3): Vector3
	return self:frame(position).right
end
function CoursePath:distanceAlong(position: Vector3): number
	return self:frame(position).distance
end
function CoursePath:lateralAt(position: Vector3): number
	return self:frame(position).lateral
end
function CoursePath:totalLength(): number
	return self.cumulative[#self.cumulative]
end
function CoursePath:atDistance(distance: number): (Vector3, Vector3)
	local target = math.clamp(distance, 0, self:totalLength())
	for i = 1, #self.nodes - 1 do
		if target <= self.cumulative[i + 1] then
			local segment = self.nodes[i + 1] - self.nodes[i]
			return self.nodes[i] + segment.Unit * (target - self.cumulative[i]), segment.Unit
		end
	end
	error("Invalid path distance")
end
return CoursePath
