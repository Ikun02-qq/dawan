--[[ 载具内 NPC 补丁（Pilot / Gunner）

  问题：MI24V 机头虽然放了 Pilot / Gunner 两个人形模型，
        但它们只有 Head/UpperTorso/Helmet，没有 Humanoid 也没有 RootPart。
        所以所有靠 Humanoid 判定的功能（ESP / 子弹追踪 / 锁定）都不认。

  做法：给这类「贴在载具上的人形 Model」补：
        - Humanoid
        - HumanoidRootPart（锚在 Head 位置）

  不碰载具本体、不碰玩家、不碰其他功能。

  撤销：getgenv().__DAWG_CREWPATCH.stop()
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CREW_NAMES = { "pilot", "gunner", "crew", "driver" }
local CREW_PARENTS = { "Pilots" }

local tracked = {}   -- [model] = {hum, rootPart}
local syncConn = nil

local function nameOk(name)
	local n = string.lower(name)
	for _, kw in ipairs(CREW_NAMES) do
		if n == kw or n:find(kw) then return true end
	end
	return false
end

local function isOurRoot(part)
	return part:IsA("BasePart")
		and part.Name == "HumanoidRootPart"
		and part.Transparency >= 1
		and part.Size == Vector3.new(2, 2, 2)
		and part.CanQuery == false
end

--- 清理旧件
local function cleanOld(model)
	for _, d in ipairs(model:GetChildren()) do
		if isOurRoot(d) then pcall(function() d:Destroy() end) end
	end
	local oldHum = model:FindFirstChild("__DawgCrewHumanoid")
	if oldHum then pcall(function() oldHum:Destroy() end) end
	for _, d in ipairs(model:GetChildren()) do
		if d:IsA("Humanoid") and d.Name == "__DawgCrewHumanoid" then
			pcall(function() d:Destroy() end)
		end
	end
end

--- 给一个 crew model 补 Humanoid + RootPart
local function patchCrew(model)
	if not model:IsA("Model") then return false end
	if not nameOk(model.Name) then return false end
	-- 只处理在载具 Pilots 容器里的
	local parent = model.Parent
	if not parent or string.lower(parent.Name) ~= "pilots" then return false end
	-- 排除玩家
	if Players:GetPlayerFromCharacter(model) then return false end

	local head = model:FindFirstChild("Head")
	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
	local anchor = head or torso or model:FindFirstChildWhichIsA("BasePart")
	if not anchor then return false end

	cleanOld(model)

	local rec = tracked[model]
	if not rec then
		rec = {}
		tracked[model] = rec
	end

	-- 1) Humanoid
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		hum = Instance.new("Humanoid")
		hum.Name = "__DawgCrewHumanoid"
		hum.MaxHealth = 100
		hum.Health = 100
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		pcall(function() hum.Parent = model end)
	end
	rec.hum = hum

	-- 2) RootPart
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart") and not isOurRoot(rootPart)) then
		rootPart = Instance.new("Part")
		rootPart.Name = "HumanoidRootPart"
		rootPart.Size = Vector3.new(2, 2, 2)
		rootPart.Transparency = 1
		rootPart.CanCollide = false
		rootPart.CanQuery = false
		rootPart.CanTouch = false
		rootPart.Massless = true
		rootPart.Anchored = true
		rootPart.CFrame = anchor.CFrame
		pcall(function() rootPart.Parent = model end)
	end
	rec.root = rootPart

	-- 3) Humanoid 认 RootPart
	pcall(function()
		if hum and hum.RootPart ~= rootPart then hum.RootPart = rootPart end
	end)

	return true
end

--- 扫描
local function scan()
	local n = 0
	local function visitCrew(container)
		if not container then return end
		for _, c in ipairs(container:GetChildren()) do
			if c:IsA("Model") and string.lower(c.Name) == "pilots" then
				for _, sub in ipairs(c:GetChildren()) do
					if sub:IsA("Model") and nameOk(sub.Name) then
						if patchCrew(sub) then n = n + 1 end
					end
				end
			end
		end
	end
	-- 找所有载具容器
	local function walk(root, depth)
		if depth > 4 then return end
		for _, c in ipairs(root:GetChildren()) do
			if c:IsA("Model") and string.lower(c.Name):find("mi24") then
				local pilots = c:FindFirstChild("Pilots")
				if pilots then visitCrew(c) end
			end
			if c:IsA("Folder") or c:IsA("Model") then
				walk(c, depth + 1)
			end
		end
	end
	walk(workspace:FindFirstChild("AiZones") or workspace, 0)
	walk(workspace, 0)
	return n
end

--- 每帧同步位置（跟着飞机飞）
local function startSync()
	if syncConn then return end
	syncConn = RunService.RenderStepped:Connect(function()
		for model, rec in pairs(tracked) do
			if not model.Parent or not rec.root or not rec.root.Parent then
				tracked[model] = nil
			else
				local head = model:FindFirstChild("Head")
				local anchor = head or model:FindFirstChild("UpperTorso") or model:FindFirstChildWhichIsA("BasePart")
				if anchor then rec.root.CFrame = anchor.CFrame end
			end
		end
	end)
end

local first = scan()
startSync()
task.spawn(function()
	while true do
		task.wait(3)
		pcall(scan)
	end
end)

local names = {}
for m, rec in pairs(tracked) do
	names[#names + 1] = m.Name .. "(hum=" .. tostring(rec.hum ~= nil) .. ")"
end
print(string.format("[CrewPatch] 就位 · 处理 %d 个: %s", first, table.concat(names, ", ")))

local M = {
	scan = scan,
	count = function() local c = 0 for _ in pairs(tracked) do c = c + 1 end return c end,
	list = function()
		local l = {}
		for m, rec in pairs(tracked) do
			local head = m:FindFirstChild("Head")
			l[#l + 1] = string.format("%s.%s hum=%s root=%s headPos=%s",
				m.Parent and m.Parent.Parent and m.Parent.Parent.Name or "?",
				m.Name,
				tostring(rec.hum ~= nil),
				tostring(rec.root ~= nil),
				head and string.format("%.0f,%.0f,%.0f", head.Position.X, head.Position.Y, head.Position.Z) or "nil")
		end
		return l
	end,
	stop = function()
		if syncConn then syncConn:Disconnect() syncConn = nil end
		for model, rec in pairs(tracked) do
			if rec.root then pcall(function() rec.root:Destroy() end) end
			if rec.hum then pcall(function() rec.hum:Destroy() end) end
			tracked[model] = nil
		end
		print("[CrewPatch] 已撤销")
	end,
}
getgenv().__DAWG_CREWPATCH = M
return M
