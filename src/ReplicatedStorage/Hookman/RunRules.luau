--!strict
local Rules = {}
Rules.MaxScore = 1e12
Rules.MaxSpeed = 420
Rules.PositionSlack = 10
Rules.MaxSampleGap = 0.5
Rules.CourseRadius = 240
Rules.MinHookTime = 0.15
Rules.MaxHookTime = 15
Rules.RequestRate = 12
Rules.RequestBurst = 16

function Rules.finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function Rules.integer(value: any, low: number, high: number): boolean
	return Rules.finite(value) and value >= low and value <= high and value % 1 == 0
end
function Rules.vector(value: any): boolean
	return typeof(value) == "Vector3" and Rules.finite(value.X) and Rules.finite(value.Y) and Rules.finite(value.Z)
end
function Rules.validMovement(previous: Vector3, current: Vector3, velocity: Vector3, dt: number): boolean
	return Rules.vector(previous)
		and Rules.vector(current)
		and Rules.vector(velocity)
		and Rules.finite(dt)
		and dt > 0
		and dt <= Rules.MaxSampleGap
		and velocity.Magnitude <= Rules.MaxSpeed
		and (current - previous).Magnitude <= Rules.MaxSpeed * dt + Rules.PositionSlack
end

-- A forward crossing, not merely a projection beyond the finish line.
function Rules.crossedPlane(
	previous: Vector3,
	current: Vector3,
	cf: CFrame,
	halfWidth: number,
	halfHeight: number
): boolean
	local a, b = cf:PointToObjectSpace(previous), cf:PointToObjectSpace(current)
	-- CFrame.LookVector points toward local -Z.
	if a.Z < 0 or b.Z > 0 or a.Z - b.Z < 0.001 then
		return false
	end
	local t = a.Z / (a.Z - b.Z)
	local p = a:Lerp(b, t)
	return math.abs(p.X) <= halfWidth and math.abs(p.Y) <= halfHeight
end

-- Slab intersection catches thin obstacles between physics samples.
function Rules.segmentBox(a: Vector3, b: Vector3, half: Vector3): boolean
	local enter, leave = 0, 1
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local start, delta, limit = a[axis], b[axis] - a[axis], half[axis]
		if math.abs(delta) < 1e-6 then
			if math.abs(start) > limit then
				return false
			end
		else
			local x, y = (-limit - start) / delta, (limit - start) / delta
			enter = math.max(enter, math.min(x, y))
			leave = math.min(leave, math.max(x, y))
			if enter > leave then
				return false
			end
		end
	end
	return true
end
return Rules
