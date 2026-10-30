--!strict
local Shared = game:GetService("ReplicatedStorage").Hookman
local Config = require(Shared.Config)
local Rules = require(Shared.RunRules)
local ReleaseJudge = require(Shared.ReleaseJudge)
local HookService = {}

function HookService.reset(run)
	run.primaryHook, run.secondaryHook, run.attachedAt = nil, nil, nil
	run.combo = 0
end

function HookService.handle(run, request, now: number, root: BasePart)
	local verdict = { runId = run.id, sequence = request.sequence, accepted = false, combo = run.combo }
	if request.action == "attach" then
		if type(request.hookId) ~= "string" or #request.hookId > 80 then
			verdict.reason = "invalid_hook"
			return verdict
		end
		local hook = run.course.hooks[request.hookId]
		if not hook or not hook:IsDescendantOf(run.course.folder) then
			verdict.reason = "foreign_hook"
			return verdict
		end
		local delta = hook.Position - root.Position
		if
			delta.Magnitude < Config.Hook.MinRange - 8
			or delta.Magnitude > Config.Hook.MaxRange + 18
			or delta.Y < -Config.Hook.MaxDrop - 18
		then
			verdict.reason = "hook_range"
			return verdict
		end
		local forward = run.course.path:forwardAt(root.Position)
		if Vector3.new(delta.X, 0, delta.Z):Dot(forward) < Config.Hook.MinForwardZ - 18 then
			verdict.reason = "hook_direction"
			return verdict
		end
		if run.primaryHook then
			if
				request.secondary ~= true
				or not run.effect.dualRope
				or run.secondaryHook
				or hook == run.primaryHook
				or hook:GetAttribute("Side") == run.primaryHook:GetAttribute("Side")
			then
				verdict.reason = "hook_state"
				return verdict
			end
			run.secondaryHook = hook
		else
			if request.secondary == true then
				verdict.reason = "no_primary"
				return verdict
			end
			run.primaryHook, run.attachedAt = hook, now
		end
		verdict.accepted = true
	elseif request.action == "release" then
		local hook, since = run.primaryHook, run.attachedAt
		run.primaryHook, run.secondaryHook, run.attachedAt = nil, nil, nil
		if not hook or not since or not hook.Parent then
			verdict.reason = "no_attachment"
			return verdict
		end
		if now - since < Rules.MinHookTime or now - since > Rules.MaxHookTime then
			verdict.reason = "attachment_time"
			return verdict
		end
		-- Grade a recent validated server observation, never a client-supplied grade or combo.
		local observation = run.observation
		if
			not observation
			or now - observation.time > 0.3
			or not Rules.vector(observation.velocity)
			or observation.time < since
		then
			verdict.reason = "missing_observation"
			return verdict
		end
		local result = ReleaseJudge.evaluate(hook.Position, observation.position, observation.velocity)
		local fresh = not run.scoredHooks[hook.Name]
		run.scoredHooks[hook.Name] = true
		if fresh then
			if result.grade == "PERFECT" or result.grade == "GREAT" then
				run.combo = math.min(run.combo + 1, 10000)
			elseif result.grade == "MISS" then
				run.combo = 0
			end
		end
		verdict.award = fresh
		verdict.accepted, verdict.grade, verdict.combo = true, result.grade, run.combo
	else
		verdict.reason = "unknown_action"
	end
	return verdict
end
return HookService
