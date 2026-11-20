--[[ MI24V RootPart 补丁（纯净版）

  只做一件事：给 MI24V 补一个 HumanoidRootPart。
  不碰相机、不碰准星、不碰 Aimbot、不碰 ESP。

  目的：让游戏里那些靠 Humanoid.RootPart 定位的功能（比如子弹追踪）
        能识别到这类没有原生 RootPart 的 AI 载具。

  撤销：getgenv().__DAWG_ROOTPATCH.stop()
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local VEHICLE_NAMES = { "mi24", "mi8", "heli", "btr", "tank" }

local tracked = {}
local syncConn = nil

local function nameOk(name)
	local n = string.lower(name)
	for _, kw in ipairs(VEHICLE_NAMES) do
		if n:find(kw) then return true end
	end
	return false
end

local function isPlainPlayerCharacter(model)
	if Players:GetPlayerFromCharacter(model) then return true end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character == model or p.Name == model.Name then return true end
	end
	return false
end

--- 判断是不是我们造的锚点
local function isOurPart(part)
	return part:IsA("BasePart")
		and part.Name == "HumanoidRootPart"
		and part.Transparency >= 1
		and part.Size == Vector3.new(2, 2, 2)
		and part.CanQuery == false
end

--- 清理该模型下所有旧锚点
local function cleanOld(model)
	local n = 0
	for _, d in ipairs(model:GetChildren()) do
		if isOurPart(d) then
			pcall(function() d:Destroy() end)
			n = n + 1
		end
	end
	return n
end

--- 给模型补 RootPart
local function patch(model)
	if not model:IsA("Model") then return false end
	if not nameOk(model.Name) then return false end
	if isPlainPlayerCharacter(model) then return false end
	if not model:FindFirstChildOfClass("Humanoid") then return false end

	-- 原生就有 RootPart 的不动
	local native = model:FindFirstChild("HumanoidRootPart")
	if native and native:IsA("BasePart") and not isOurPart(native) then
		return false
	end

	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not anchor then return false end

	cleanOld(model)

	local part = Instance.new("Part")
	part.Name = "HumanoidRootPart"
	part.Size = Vector3.new(2, 2, 2)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = true
	part.CFrame = anchor.CFrame
	pcall(function() part.Parent = model end)

	-- 让 Humanoid 认它
	pcall(function()
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum and hum.RootPart ~= part then
			hum.RootPart = part
		end
	end)

	tracked[model] = part
	return true
end

--- 扫描
local function scan()
	local n = 0
	local seen = {}
	local function visit(container)
		if not container or seen[container] then return end
		seen[container] = true
		for _, c in ipairs(container:GetChildren()) do
			if c:IsA("Model") and nameOk(c.Name) then
				if patch(c) then n = n + 1 end
			end
			if c:IsA("Folder") or c:IsA("Model") then
				for _, sub in ipairs(c:GetChildren()) do
					if sub:IsA("Model") and nameOk(sub.Name) then
						if patch(sub) then n = n + 1 end
					end
				end
			end
		end
	end
	visit(workspace:FindFirstChild("AiZones"))
	visit(workspace:FindFirstChild("Vehicles"))
	return n
end

--- 每帧同步位置（载具会飞）
local function startSync()
	if syncConn then return end
	syncConn = RunService.RenderStepped:Connect(function()
		for model, part in pairs(tracked) do
			if not model.Parent or not part.Parent then
				tracked[model] = nil
			else
				local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
				if anchor then part.CFrame = anchor.CFrame end
			end
		end
	end)
end

local first = scan()
startSync()

-- 持续检测新载具
task.spawn(function()
	while true do
		task.wait(2)
		pcall(scan)
	end
end)

local names = {}
for m in pairs(tracked) do names[#names + 1] = m.Name end
print(string.format("[RootPatch] 就位 · 处理 %d 个载具: %s", first, table.concat(names, ", ")))

local M = {
	scan = scan,
	count = function() local c = 0 for _ in pairs(tracked) do c = c + 1 end return c end,
	list = function()
		local l = {}
		for m, p in pairs(tracked) do
			l[#l + 1] = string.format("%s root@%.0f,%.0f,%.0f primary@%.0f,%.0f,%.0f",
				m.Name,
				p.Position.X, p.Position.Y, p.Position.Z,
				m.PrimaryPart and m.PrimaryPart.Position.X or 0,
				m.PrimaryPart and m.PrimaryPart.Position.Y or 0,
				m.PrimaryPart and m.PrimaryPart.Position.Z or 0)
		end
		return l
	end,
	stop = function()
		if syncConn then syncConn:Disconnect() syncConn = nil end
		for model, part in pairs(tracked) do
			pcall(function() part:Destroy() end)
			tracked[model] = nil
		end
		print("[RootPatch] 已撤销")
	end,
}
getgenv().__DAWG_ROOTPATCH = M
return M
