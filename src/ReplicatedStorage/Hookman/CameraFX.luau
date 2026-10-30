--!strict
-- 속도 비례 FOV, Perfect 펀치 줌, 화면 플래시

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Hookman"):WaitForChild("Config"))

local CameraFX = {}

local punch = 0
local flashFrame: Frame? = nil

local function ensureFlash(): Frame?
	if flashFrame and flashFrame.Parent then
		return flashFrame
	end
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local gui = pg:FindFirstChild("HookmanFX") :: ScreenGui?
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "HookmanFX"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = pg
	end
	local f = Instance.new("Frame")
	f.Name = "Flash"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = 50
	f.Parent = gui
	flashFrame = f
	return f
end

function CameraFX.update(dt: number, speed: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local C = Config.Camera
	local t = math.clamp(speed / C.FovSpeedRef, 0, 1)
	local target = C.BaseFov + (C.MaxFov - C.BaseFov) * t + punch
	cam.FieldOfView += (target - cam.FieldOfView) * math.min(dt * C.FovLerp, 1)
	punch -= punch * math.min(dt * 5, 1)
end

function CameraFX.judgeHit(grade: string)
	if grade == "PERFECT" then
		punch = 16
		local f = ensureFlash()
		if f then
			f.BackgroundColor3 = Color3.fromRGB(255, 240, 190)
			f.BackgroundTransparency = 0.9
			TweenService:Create(f, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
		end
	elseif grade == "GREAT" then
		punch = 7
	elseif grade == "MISS" then
		punch = -5
	end
end

return CameraFX
