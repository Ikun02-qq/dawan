--[[============================================================================
  MapLocate —— 游戏地图定位模块（可独立嵌入任意脚本）

  用法（三行接入）：
    local MapLocate = loadstring(readfile("dawg/map_locate_module.lua"))()
    MapLocate.start()
    -- 停止：MapLocate.stop()

  API：
    MapLocate.start()             启动（按 M 打开地图时自动生效）
    MapLocate.stop()              停止并清理自己创建的 UI
    MapLocate.toggle()            切换，返回当前状态
    MapLocate.isRunning()         是否在运行
    MapLocate.getInfo()           取当前位置 { u, v, grid, hasGps }
    MapLocate.setColor(r, g, b)   改三角颜色
    MapLocate.setHeading(bool)    是否显示朝向
    MapLocate.setSmooth(n)        旋转平滑系数 0-1
    MapLocate.showGridTag(bool)   是否显示格号文字

  原理（重要）：
    游戏的地图 MapFrame.Markers.SelfMarker 会由服务端游戏逻辑更新到正确位置，
    但游戏把 Markers.Visible 设成 false，玩家看不到。
    本模块只【读取】SelfMarker.Position 画自己的标记，不修改游戏任何对象。

    注意：没有 GPS 道具的账号，游戏不会更新 SelfMarker（恒为 0,0），
    此时模块显示「无 GPS 道具」提示。

  依赖：无（纯 Roblox API）
============================================================================]]

local MapLocate = {}

-- ============ 配置 ============
MapLocate.cfg = {
	cols = 27,              -- 地图网格列数（0..26）
	rows = 26,              -- 地图网格行数（A..Z）
	arrowColor = Color3.fromRGB(120, 255, 160),
	arrowSize = 26,
	arrowTextSize = 22,
	tagSize = 15,
	showHeading = true,
	headingSmooth = 0.45,   -- 1 = 瞬间对齐，越小越平滑
	showGridTag = false,  -- 默认不显示格号文字
	refreshInterval = 0.1,  -- 检查间隔（秒）
	debug = false,
	-- 没有 GPS 道具时的兜底公式（72 点拟合，平均误差 0.00 格（最大 0.04））
	fallback = {
		enabled = true,
		aX = 0.000124271, aZ = 0.000000305, aC = 0.474567,
		bX = -0.000000497, bZ = 0.000124179, bC = 0.524384,
	},
}

-- ============ 内部状态 ============
local state = {
	running = false,
	conn = nil,
	arrow = nil,
	tag = nil,
	owner = {},
	lastInfo = { u = 0, v = 0, grid = "", hasGps = false },
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GENV = (type(getgenv) == "function" and getgenv()) or _G

-- ============ 内部工具 ============
local function findMap()
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local mainGui = pg and pg:FindFirstChild("MainGui")
	return mainGui and mainGui:FindFirstChild("MapFrame", true)
end

local function findSelfMarker(mf)
	local markers = mf:FindFirstChild("Markers", true)
	return markers and markers:FindFirstChild("SelfMarker")
end

local function ensureArrow(host)
	local a = host:FindFirstChild("MapLocArrow")
	if not a then
		a = Instance.new("TextLabel")
		a.Name = "MapLocArrow"
		a.AnchorPoint = Vector2.new(0.5, 0.5)
		a.BackgroundTransparency = 1
		a.Font = Enum.Font.GothamBold
		a.Text = "▲"
		a.TextColor3 = MapLocate.cfg.arrowColor
		a.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		a.TextStrokeTransparency = 0.1
		a.TextXAlignment = Enum.TextXAlignment.Center
		a.TextYAlignment = Enum.TextYAlignment.Center
		a.ZIndex = 100
		a.Parent = host
	end
	a.Size = UDim2.fromOffset(MapLocate.cfg.arrowSize, MapLocate.cfg.arrowSize)
	a.TextSize = MapLocate.cfg.arrowTextSize
	a.TextColor3 = MapLocate.cfg.arrowColor
	a.Visible = true
	return a
end

local function ensureTag(host)
	local t = host:FindFirstChild("MapLocTag")
	if not t then
		t = Instance.new("TextLabel")
		t.Name = "MapLocTag"
		t.Size = UDim2.fromOffset(80, 18)
		t.AnchorPoint = Vector2.new(0.5, 1)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.TextColor3 = MapLocate.cfg.arrowColor
		t.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		t.TextStrokeTransparency = 0.1
		t.ZIndex = 101
		t.Parent = host
	end
	t.TextSize = MapLocate.cfg.tagSize
	t.Visible = true
	return t
end

local function cleanupUI()
	local mf = findMap()
	if not mf then return end
	for _, d in ipairs(mf:GetDescendants()) do
		if d.Name == "MapLocArrow" or d.Name == "MapLocTag" then
			pcall(function() d:Destroy() end)
		end
	end
	state.arrow = nil
	state.tag = nil
end

-- ============ 核心更新 ============
--- 三角跟随视角旋转（最短路径插值）
local function applyHeading(arrow)
	if not MapLocate.cfg.showHeading then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then return end
	local target = math.deg(math.atan2(flat.X, -flat.Z))
	local cur = arrow.Rotation
	local delta = ((target - cur + 180) % 360) - 180
	arrow.Rotation = cur + delta * MapLocate.cfg.headingSmooth
end

local function update()
	if not MapLocate.cfg then return end
	local mf = findMap()
	if not mf or not mf.Visible then return end

	local sm = findSelfMarker(mf)
	local host = mf:FindFirstChild("MainFrame") or mf
	local arrow = ensureArrow(host)
	local tag = ensureTag(host)
	state.arrow, state.tag = arrow, tag

	local u = sm and sm.Position.X.Scale or 0
	local v = sm and sm.Position.Y.Scale or 0

	-- 无 GPS 判断：游戏不更新 SelfMarker，位置会停在 (0.5,0.5) 或 (0,0)
	-- 满足任一条件即视为没有有效定位
	local noGps = (u == 0 and v == 0)
		or (math.abs(u - 0.5) < 1e-6 and math.abs(v - 0.5) < 1e-6)
	if noGps then
		-- 这号没 GPS：用公式估算（公式由有 GPS 的号采集游戏真值拟合）
		local ch = Players.LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		local fb = MapLocate.cfg.fallback
		if fb and fb.enabled and hrp then
			local x, z = hrp.Position.X, hrp.Position.Z
			local eu = fb.aX * x + fb.aZ * z + fb.aC
			local ev = fb.bX * x + fb.bZ * z + fb.bC
			if eu > 0 and eu < 1 and ev > 0 and ev < 1 then
				arrow.Visible = true
				arrow.Position = UDim2.fromScale(eu, ev)
				local ci2 = math.clamp(math.floor(eu * MapLocate.cfg.cols), 0, MapLocate.cfg.cols - 1)
				local ri2 = math.clamp(math.floor(ev * MapLocate.cfg.rows), 0, MapLocate.cfg.rows - 1)
				state.lastInfo = { u = eu, v = ev, grid = string.char(65 + ri2) .. ci2, hasGps = false }
				if MapLocate.cfg.showGridTag then
					tag.Visible = true
					tag.Text = "≈" .. state.lastInfo.grid
					tag.TextColor3 = Color3.fromRGB(255, 200, 100)
					tag.Position = UDim2.fromScale(eu, ev) - UDim2.fromOffset(0, 16)
				else
					tag.Visible = false
				end
				applyHeading(arrow)   -- 无 GPS 时也要跟随视角转
				return
			end
		end
		arrow.Visible = false
		tag.Visible = true
		tag.Text = "无 GPS 道具"
		tag.TextColor3 = Color3.fromRGB(255, 180, 90)
		tag.Position = UDim2.fromScale(0.5, 0.5)
		state.lastInfo = { u = 0, v = 0, grid = "", hasGps = false }
		return
	end

	tag.TextColor3 = MapLocate.cfg.arrowColor
	tag.Visible = MapLocate.cfg.showGridTag
	arrow.Position = UDim2.fromScale(u, v)
	tag.Position = UDim2.fromScale(u, v) - UDim2.fromOffset(0, 16)

	-- 格号
	local ci = math.clamp(math.floor(u * MapLocate.cfg.cols), 0, MapLocate.cfg.cols - 1)
	local ri = math.clamp(math.floor(v * MapLocate.cfg.rows), 0, MapLocate.cfg.rows - 1)
	local grid = string.char(65 + ri) .. ci
	tag.Text = grid

	applyHeading(arrow)

	state.lastInfo = { u = u, v = v, grid = grid, hasGps = true }

	if MapLocate.cfg.debug then
		print(string.format("[MapLocate] u=%.3f v=%.3f → %s", u, v, grid))
	end
end

-- ============ 公开 API ============
function MapLocate.start()
	if state.running then return true end
	state.running = true
	if GENV.__MAPLOCATE_OWNER then
		GENV.__MAPLOCATE_OWNER = nil
	end
	local myOwner = {}
	state.owner = myOwner
	GENV.__MAPLOCATE_OWNER = myOwner

	local acc = 0
	state.conn = RunService.Heartbeat:Connect(function(dt)
		if not state.running then return end
		if GENV.__MAPLOCATE_OWNER ~= myOwner then return end
		acc = acc + dt
		if acc < MapLocate.cfg.refreshInterval then return end
		acc = 0
		pcall(update)
	end)
	return true
end

function MapLocate.stop()
	state.running = false
	if state.conn then
		pcall(function() state.conn:Disconnect() end)
		state.conn = nil
	end
	if GENV.__MAPLOCATE_OWNER == state.owner then
		GENV.__MAPLOCATE_OWNER = nil
	end
	cleanupUI()
	return true
end

function MapLocate.toggle()
	if state.running then
		MapLocate.stop()
	else
		MapLocate.start()
	end
	return state.running
end

function MapLocate.isRunning()
	return state.running
end

--- 取当前位置信息
function MapLocate.getInfo()
	return {
		u = state.lastInfo.u,
		v = state.lastInfo.v,
		grid = state.lastInfo.grid,
		hasGps = state.lastInfo.hasGps,
	}
end

function MapLocate.setColor(r, g, b)
	MapLocate.cfg.arrowColor = Color3.fromRGB(r, g, b)
	if state.arrow then state.arrow.TextColor3 = MapLocate.cfg.arrowColor end
	if state.tag then state.tag.TextColor3 = MapLocate.cfg.arrowColor end
end

function MapLocate.setHeading(on)
	MapLocate.cfg.showHeading = on and true or false
end

function MapLocate.setSmooth(n)
	MapLocate.cfg.headingSmooth = math.clamp(tonumber(n) or 0.45, 0.05, 1)
end

function MapLocate.showGridTag(on)
	MapLocate.cfg.showGridTag = on and true or false
end

function MapLocate.destroy()
	MapLocate.stop()
	GENV.__MAPLOCATE = nil
end

GENV.__MAPLOCATE = MapLocate
return MapLocate
