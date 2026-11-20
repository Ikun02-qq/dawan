--[[ 爱沙尼亚边境（7353845952）专用 · 三个功能

  1. INVENTORY CHECKER —— 查准星最近玩家的装备（格子布局，滚轮缩放）
  2. 玩家高亮 —— 所有玩家红色描边
  3. ZOOM —— 按 Z 放大视野

  用法：
    loadstring(readfile("dawg/loot_zoom.lua"))()

  数据来源（实测）：
    角色.Holstered/ItemBack1..2、ItemHip1 → ObjectValue → ObjectValue(物品) → StringValue(名称)
    角色.Holding → 当前手持
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GENV = (type(getgenv) == "function" and getgenv()) or _G
local HOLDER = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")

local CFG = {
	invKey = Enum.KeyCode.G,
	zoomKey = Enum.KeyCode.Z,
	zoomModKey = nil,   -- 缩放触发键（nil=鼠标右键，可设 Enum.KeyCode.X / Enum.UserInputType.MouseButton2）
	zoomFov = 6,    -- 放大后的 FOV（越小越放大；默认视野 70，现在 6 ≈ 11 倍）
	zoomTween = 0.18,
	maxDist = 99999,   -- 不限制（要限制就改小）
	highlight = false,   -- 玩家高亮默认关（必须手动开，总开关只管能不能生效）
	masterEnabled = false,   -- 总开关（透视的总闸），关时不渲染任何高亮
	hlColor = Color3.fromRGB(255, 60, 60),
	hlOutline = Color3.fromRGB(255, 255, 255),
	hlFillTransparency = 0.72,
	hlOutlineTransparency = 0.1,
}

--- 判断输入是否命中缩放触发键
local function isZoomModInput(input)
	local k = CFG.zoomModKey
	if k == nil then
		return input.UserInputType == Enum.UserInputType.MouseButton2
	end
	if typeof(k) == "EnumItem" then
		if k.EnumType == Enum.UserInputType then
			return input.UserInputType == k
		end
		return input.KeyCode == k
	end
	return false
end

--- 缩放触发键的显示文字
local function zoomModLabel()
	local k = CFG.zoomModKey
	if k == nil then return "右键" end
	if typeof(k) == "EnumItem" then
		if k.EnumType == Enum.UserInputType then
			if k == Enum.UserInputType.MouseButton1 then return "左键" end
			if k == Enum.UserInputType.MouseButton2 then return "右键" end
			if k == Enum.UserInputType.MouseButton3 then return "中键" end
			return k.Name:gsub("MouseButton", "MB")
		end
		-- KeyCode 显示常见按键的短名
		local n = k.Name
		if #n > 6 then
			return n:sub(1, 6)
		end
		return n
	end
	return "右键"
end

-- ============ 数据读取 ============
local function readSlot(slot)
	if not slot then return nil end
	local obj = slot
	for _ = 1, 5 do
		if obj == nil then return nil end
		if obj:IsA("StringValue") then return obj.Name end
		if obj:IsA("ObjectValue") then
			obj = obj.Value
		else
			return obj.Name
		end
	end
	return nil
end

--- 读玩家全部物品（从 ReplicatedStorage.Players.<name>.Inventory）
--- 每件物品是 ObjectValue，Name=物品名，属性 Slot/Durability/LoadedAmmo
local function readInventory(plr)
	local rs = game:GetService("ReplicatedStorage")
	local pf = rs:FindFirstChild("Players")
	local pFolder = pf and pf:FindFirstChild(plr.Name)
	local inv = pFolder and pFolder:FindFirstChild("Inventory")
	local items = {}
	if inv then
		for _, item in ipairs(inv:GetChildren()) do
			local slot = item:GetAttribute("Slot") or ""
			items[#items + 1] = {
				name = item.Name,
				slot = tostring(slot),
				durability = item:GetAttribute("Durability"),
				maxDur = item:GetAttribute("MaxDurability"),
				ammo = item:GetAttribute("LoadedAmmo"),
				instance = item,
			}
		end
	end
	-- 兜底：角色身上的 Holstered/Holding（背包数据没同步时用）
	if #items == 0 then
		local ch = plr.Character
		if ch then
			local hol = ch:FindFirstChild("Holstered")
			if hol then
				for _, slot in ipairs(hol:GetChildren()) do
					if slot:IsA("ObjectValue") then
						local nm = readSlot(slot)
						if nm then
							items[#items + 1] = { name = nm, slot = slot.Name }
						end
					end
				end
			end
			local hold = ch:FindFirstChild("Holding")
			if hold then
				local nm = readSlot(hold)
				if nm then items[#items + 1] = { name = nm, slot = "Holding", held = true } end
			end
		end
	end
	return items
end

--- 物品分类到 12 个装备格
local SLOT_MAP = {
	-- [格子索引] = 匹配的 Slot 属性
	[1] = { "ItemBack1", "Holding" },                    -- PRI 主武器
	[2] = { "ItemBack2" },                               -- SEC 副武器
	[3] = { "ItemHip1" },                                -- HOL 手枪
	[4] = { "ItemHip2" },                                -- HOL 备用手枪
	[5] = { "ClothingChestRig" },                        -- RIG 胸挂
	[6] = { "ClothingMask", "ClothingHeadware" },        -- MASK 面罩/头盔
	[7] = { "ClothingShirt" },                           -- GEAR 上衣
	[8] = { "ClothingPants" },                           -- GEAR 裤子
	[9] = { "ClothingGloves" },                          -- PCH 手套
	[10] = { "Melee" },                                  -- PCH 近战
	[11] = { "EquipmentLighter", "EquipmentCompass", "EquipmentMap" },  -- PCH 装备
	[12] = { "EquipmentGPS" },                           -- GEAR GPS
}

local function classifyToSlots(items)
	local slots = {}
	local rest = {}
	for _, it in ipairs(items) do
		local placed = false
		for idx, keys in pairs(SLOT_MAP) do
			if not slots[idx] then
				for _, k in ipairs(keys) do
					if it.slot == k then
						slots[idx] = it
						placed = true
						break
					end
				end
				if placed then break end
			end
		end
		if not placed then rest[#rest + 1] = it end
	end
	return slots, rest
end

local function nearestByCrosshair()
	local cam = workspace.CurrentCamera
	local lp = Players.LocalPlayer
	if not cam then return nil end
	local vp = cam.ViewportSize
	local cx, cy = vp.X / 2, vp.Y / 2
	local myHrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	local best, bestD = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp and p.Character then
			local hrp = p.Character:FindFirstChild("HumanoidRootPart")
			local hum = p.Character:FindFirstChildOfClass("Humanoid")
			if hrp and hum and hum.Health > 0 and myHrp then
				local wd = (hrp.Position - myHrp.Position).Magnitude
				if wd <= CFG.maxDist then
					local sp, on = cam:WorldToViewportPoint(hrp.Position)
					if on then
						local d = math.sqrt((sp.X - cx) ^ 2 + (sp.Y - cy) ^ 2)
						if d < bestD then best, bestD = p, d end
					end
				end
			end
		end
	end
	return best, bestD
end

local function distanceTo(plr)
	local lp = Players.LocalPlayer
	local a = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	local b = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
	if a and b then return math.floor((a.Position - b.Position).Magnitude) end
	return -1
end

-- ============ 颜色 ============
local COL = {
	bg = Color3.fromRGB(22, 24, 34),
	row = Color3.fromRGB(34, 37, 52),
	accent = Color3.fromRGB(120, 255, 160),
	text = Color3.fromRGB(226, 226, 226),
	sub = Color3.fromRGB(150, 160, 180),
	blue = Color3.fromRGB(120, 200, 255),
	held = Color3.fromRGB(255, 200, 100),
}

-- 清旧
for _, root in ipairs({ HOLDER, game:GetService("CoreGui") }) do
	pcall(function()
		local old = root:FindFirstChild("DawgLootZoom")
		if old then old:Destroy() end
	end)
end

local gui = Instance.new("ScreenGui")
gui.Name = "DawgLootZoom"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.Parent = HOLDER

-- ============ 背包面板 ============
local panel = Instance.new("Frame")
panel.Name = "InvPanel"
panel.AnchorPoint = Vector2.new(1, 0)
panel.Position = UDim2.new(1, -12, 0, 46)
panel.Size = UDim2.fromOffset(370, 440)
panel.BackgroundColor3 = COL.bg
panel.BackgroundTransparency = 0.05
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
local pc = Instance.new("UICorner")
pc.CornerRadius = UDim.new(0, 10)
pc.Parent = panel
local ps = Instance.new("UIStroke")
ps.Color = Color3.fromRGB(70, 130, 190)
ps.Thickness = 1
ps.Transparency = 0.3
ps.Parent = panel

local uscale = Instance.new("UIScale")
uscale.Scale = 1
uscale.Parent = panel

-- 标题
local title = Instance.new("TextLabel")
title.Name = "Title"
title.Position = UDim2.fromOffset(14, 10)
title.Size = UDim2.new(1, -110, 0, 18)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(245, 245, 250)
title.Text = "INVENTORY CHECKER"
title.Parent = panel

local money = Instance.new("TextLabel")
money.Name = "Money"
money.AnchorPoint = Vector2.new(1, 0)
money.Position = UDim2.new(1, -14, 10, 0)
money.Size = UDim2.fromOffset(74, 20)
money.BackgroundColor3 = COL.row
money.BackgroundTransparency = 0.2
money.BorderSizePixel = 0
money.Font = Enum.Font.GothamBold
money.TextSize = 13
money.TextColor3 = Color3.fromRGB(255, 210, 80)
money.Text = "$0"
money.Parent = panel
local mcc = Instance.new("UICorner")
mcc.CornerRadius = UDim.new(0, 5)
mcc.Parent = money

-- 目标卡
local card = Instance.new("Frame")
card.Name = "TargetCard"
card.Position = UDim2.fromOffset(14, 36)
card.Size = UDim2.new(1, -28, 0, 48)
card.BackgroundColor3 = COL.row
card.BackgroundTransparency = 0.18
card.BorderSizePixel = 0
card.Parent = panel
local ccc = Instance.new("UICorner")
ccc.CornerRadius = UDim.new(0, 7)
ccc.Parent = card
local ccs = Instance.new("UIStroke")
ccs.Color = Color3.fromRGB(60, 100, 145)
ccs.Thickness = 1
ccs.Transparency = 0.5
ccs.Parent = card

local avatar = Instance.new("ImageLabel")
avatar.Name = "Avatar"
avatar.Position = UDim2.fromOffset(8, 7)
avatar.Size = UDim2.fromOffset(34, 34)
avatar.BackgroundColor3 = Color3.fromRGB(45, 48, 62)
avatar.BorderSizePixel = 0
avatar.Image = ""
avatar.Parent = card
local ac = Instance.new("UICorner")
ac.CornerRadius = UDim.new(1, 0)
ac.Parent = avatar

local tName = Instance.new("TextLabel")
tName.Name = "PlayerName"
tName.Position = UDim2.fromOffset(50, 7)
tName.Size = UDim2.new(1, -140, 0, 18)
tName.BackgroundTransparency = 1
tName.Font = Enum.Font.GothamBold
tName.TextSize = 14
tName.TextXAlignment = Enum.TextXAlignment.Left
tName.TextColor3 = Color3.fromRGB(245, 245, 250)
tName.Text = "—"
tName.Parent = card

local tInfo = Instance.new("TextLabel")
tInfo.Name = "Info"
tInfo.Position = UDim2.fromOffset(50, 25)
tInfo.Size = UDim2.new(1, -140, 0, 14)
tInfo.BackgroundTransparency = 1
tInfo.Font = Enum.Font.Gotham
tInfo.TextSize = 11
tInfo.TextXAlignment = Enum.TextXAlignment.Left
tInfo.TextColor3 = COL.sub
tInfo.Text = ""
tInfo.Parent = card

local tag = Instance.new("TextLabel")
tag.Name = "Tag"
tag.AnchorPoint = Vector2.new(1, 0.5)
tag.Position = UDim2.new(1, -10, 0.5, 0)
tag.Size = UDim2.fromOffset(66, 22)
tag.BackgroundColor3 = Color3.fromRGB(28, 58, 88)
tag.BackgroundTransparency = 0.15
tag.BorderSizePixel = 0
tag.Font = Enum.Font.GothamBold
tag.TextSize = 11
tag.TextColor3 = COL.blue
tag.Text = "PLAYER"
tag.Parent = card
local tcc = Instance.new("UICorner")
tcc.CornerRadius = UDim.new(0, 5)
tcc.Parent = card:FindFirstChild("Tag")

-- 装备标题
local gearTitle = Instance.new("TextLabel")
gearTitle.Name = "GearTitle"
gearTitle.Position = UDim2.fromOffset(14, 90)
gearTitle.Size = UDim2.new(1, -28, 0, 16)
gearTitle.BackgroundTransparency = 1
gearTitle.Font = Enum.Font.GothamBold
gearTitle.TextSize = 12
gearTitle.TextXAlignment = Enum.TextXAlignment.Left
gearTitle.TextColor3 = COL.blue
gearTitle.Text = "EQUIPPED GEAR"
gearTitle.Parent = panel

-- 装备格 6×2
local gearGrid = Instance.new("Frame")
gearGrid.Name = "GearGrid"
gearGrid.Position = UDim2.fromOffset(14, 108)
gearGrid.Size = UDim2.new(1, -28, 0, 160)
gearGrid.BackgroundTransparency = 1
gearGrid.Parent = panel
local gl = Instance.new("UIGridLayout")
gl.CellSize = UDim2.fromOffset(52, 75)
gl.CellPadding = UDim2.fromOffset(6, 6)
gl.SortOrder = Enum.SortOrder.LayoutOrder
gl.Parent = gearGrid

local SLOT_LABELS = { "PRI", "SEC", "HOL", "HOL", "RIG", "MASK", "GEAR", "GEAR", "PCH", "PCH", "PCH", "GEAR" }
local gearCells = {}

local function ensureGearCell(i)
	if gearCells[i] then return gearCells[i] end
	local cell = Instance.new("Frame")
	cell.Name = "Cell" .. i
	cell.BackgroundColor3 = COL.row
	cell.BackgroundTransparency = 0.22
	cell.BorderSizePixel = 0
	cell.LayoutOrder = i
	cell.Parent = gearGrid
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = cell
	local s2 = Instance.new("UIStroke")
	s2.Color = Color3.fromRGB(55, 90, 125)
	s2.Thickness = 1
	s2.Transparency = 0.55
	s2.Parent = cell

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Slot"
	lbl.Position = UDim2.fromOffset(4, 2)
	lbl.Size = UDim2.new(1, -8, 0, 12)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 9
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = Color3.fromRGB(110, 170, 220)
	lbl.Text = SLOT_LABELS[i] or "GEAR"
	lbl.Parent = cell

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.Position = UDim2.fromOffset(4, 14)
	icon.Size = UDim2.new(1, -8, 0, 30)
	icon.BackgroundTransparency = 1
	icon.Font = Enum.Font.GothamBold
	icon.TextSize = 22
	icon.TextColor3 = Color3.fromRGB(235, 240, 250)
	icon.Text = ""
	icon.Parent = cell

	local nm = Instance.new("TextLabel")
	nm.Name = "ItemName"
	nm.Position = UDim2.fromOffset(3, 46)
	nm.Size = UDim2.new(1, -6, 0, 26)
	nm.BackgroundTransparency = 1
	nm.Font = Enum.Font.Gotham
	nm.TextSize = 9
	nm.TextWrapped = true
	nm.TextXAlignment = Enum.TextXAlignment.Center
	nm.TextColor3 = Color3.fromRGB(205, 210, 220)
	nm.Text = ""
	nm.Parent = cell

	gearCells[i] = { frame = cell, icon = icon, name = nm, slot = lbl }
	return gearCells[i]
end

-- 背包标题
local bagTitle = Instance.new("TextLabel")
bagTitle.Name = "BagTitle"
bagTitle.Position = UDim2.fromOffset(14, 276)
bagTitle.Size = UDim2.new(1, -100, 0, 16)
bagTitle.BackgroundTransparency = 1
bagTitle.Font = Enum.Font.GothamBold
bagTitle.TextSize = 12
bagTitle.TextXAlignment = Enum.TextXAlignment.Left
bagTitle.TextColor3 = COL.blue
bagTitle.Text = "BACKPACK & CONTAINERS"
bagTitle.Parent = panel

local bagCount = Instance.new("TextLabel")
bagCount.Name = "BagCount"
bagCount.AnchorPoint = Vector2.new(1, 0)
bagCount.Position = UDim2.new(1, -14, 276, 0)
bagCount.Size = UDim2.fromOffset(80, 16)
bagCount.BackgroundTransparency = 1
bagCount.Font = Enum.Font.Gotham
bagCount.TextSize = 11
bagCount.TextXAlignment = Enum.TextXAlignment.Right
bagCount.TextColor3 = COL.sub
bagCount.Text = "0 items"
bagCount.Parent = panel

local bagGrid = Instance.new("Frame")
bagGrid.Name = "BagGrid"
bagGrid.Position = UDim2.fromOffset(14, 294)
bagGrid.Size = UDim2.new(1, -28, 1, -304)
bagGrid.BackgroundTransparency = 1
bagGrid.Parent = panel
local bl = Instance.new("UIGridLayout")
bl.CellSize = UDim2.fromOffset(52, 66)
bl.CellPadding = UDim2.fromOffset(6, 6)
bl.SortOrder = Enum.SortOrder.LayoutOrder
bl.Parent = bagGrid

local bagCells = {}
local function ensureBagCell(i)
	if bagCells[i] then return bagCells[i] end
	local cell = Instance.new("Frame")
	cell.Name = "Bag" .. i
	cell.BackgroundColor3 = COL.row
	cell.BackgroundTransparency = 0.22
	cell.BorderSizePixel = 0
	cell.LayoutOrder = i
	cell.Parent = bagGrid
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = cell
	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.Position = UDim2.fromOffset(4, 8)
	icon.Size = UDim2.new(1, -8, 0, 28)
	icon.BackgroundTransparency = 1
	icon.Font = Enum.Font.GothamBold
	icon.TextSize = 20
	icon.Text = ""
	icon.Parent = cell
	local cnt = Instance.new("TextLabel")
	cnt.Name = "Count"
	cnt.Position = UDim2.fromOffset(4, 34)
	cnt.Size = UDim2.new(1, -8, 0, 12)
	cnt.BackgroundTransparency = 1
	cnt.Font = Enum.Font.GothamBold
	cnt.TextSize = 10
	cnt.TextColor3 = Color3.fromRGB(180, 220, 255)
	cnt.Text = ""
	cnt.Parent = cell
	local nm = Instance.new("TextLabel")
	nm.Name = "ItemName"
	nm.Position = UDim2.fromOffset(3, 46)
	nm.Size = UDim2.new(1, -6, 0, 18)
	nm.BackgroundTransparency = 1
	nm.Font = Enum.Font.Gotham
	nm.TextSize = 8
	nm.TextWrapped = true
	nm.TextColor3 = Color3.fromRGB(190, 195, 205)
	nm.Text = ""
	nm.Parent = cell
	bagCells[i] = { frame = cell, icon = icon, count = cnt, name = nm }
	return bagCells[i]
end

-- ============ 图标映射 ============
local ICON = {
	-- 武器
	Railgun = "⚡", AKMN = "🔫", AKS = "🔫", AK = "🔫", M4 = "🔫", TT33 = "🔫",
	PM = "🔫", Makarov = "🔫", Mosin = "🔫", PPSH41 = "🔫", MK23 = "🔫",
	IZh81 = "🔫", IZh12 = "🔫", Sniper = "🔫", Rifle = "🔫", Shotgun = "🔫",
	TOZ106 = "🔫", TOZ = "🔫", Saiga = "🔫", VZ61 = "🔫", Scorpion = "🔫",
	RPG7 = "🚀", NagantRevolver = "🔫", Nagant = "🔫",
	-- 近战 / 工具
	DV2 = "🔪", Knife = "🔪", Axe = "🪓", Wrench = "🔧", HandWraps = "🥊",
	-- 装备
	Lighter = "🔥", Pathfinder = "🧭", EstonianBorderMap = "🗺", EstonianBorderMapWinter = "🗺",
	-- 衣物
	WastelandShirt = "👕", WastelandPants = "👖", WastelandBackpack = "🎒",
	Balaclava = "😷", SSH68 = "⛑", Smersh = "🦺", Tortilla = "🎒", CamoPants = "👖",
	Pokushanka = "🧢", HandWraps2 = "🥊",
	-- 消耗品
	Bandage = "🩹", Medkit = "💉", DuctTape = "🧻", Nails = "📌", Nuts = "🔩",
	SerumGreen = "🧪", SerumRed = "🧪", Serum = "🧪",
}
local function iconFor(name)
	if ICON[name] then return ICON[name] end
	local n = string.lower(tostring(name))
	if n:find("rpg") or n:find("launcher") or n:find("grenade") then return "🚀" end
	if n:find("rifle") or n:find("gun") or n:find("mosin") or n:find("ak") or n:find("sniper")
		or n:find("pistol") or n:find("izh") or n:find("toz") or n:find("mp") or n:find("ump")
		or n:find("shotgun") or n:find("saiga") or n:find("sks") or n:find("m4") or n:find("m16")
		or n:find("nagant") or n:find("revolv") or n:find("tt") or n:find("colt") then return "🔫" end
	if n:find("knife") or n:find("blade") then return "🔪" end
	if n:find("shirt") then return "👕" end
	if n:find("pant") then return "👖" end
	if n:find("backpack") or n:find("bag") then return "🎒" end
	if n:find("balaclava") or n:find("mask") then return "😷" end
	if n:find("helm") or n:find("ssh") or n:find("hat") or n:find("cap") or n:find("tank") then return "⛑" end
	if n:find("rig") or n:find("smersh") or n:find("vest") or n:find("6b2") or n:find("6b3") or n:find("6b5") then return "🦺" end
	if n:find("serum") or n:find("med") then return "🧪" end
	if n:find("map") then return "🗺" end
	if n:find("compass") then return "🧭" end
	if n:find("glove") or n:find("wrap") then return "🥊" end
	if n:find("case") then return "📦" end
	if n:find("serum") or n:find("med") then return "🧪" end
	if n:find("rig") or n:find("bag") or n:find("pack") then return "🎒" end
	return "📦"
end

-- ============ 刷新 ============
local function refreshInv()
	local plr = nearestByCrosshair()
	if not plr then
		tName.Text = "没有目标"
		tInfo.Text = string.format("准星附近 %d 格内没有玩家", CFG.maxDist)
		tInfo.TextColor3 = COL.sub
		avatar.Image = ""
		money.Text = "$0"
		for i = 1, 12 do
			local c = ensureGearCell(i)
			c.icon.Text = ""
			c.name.Text = ""
		end
		for _, c in pairs(bagCells) do c.frame.Visible = false end
		bagCount.Text = "0 items"
		return
	end

	local items = readInventory(plr)
	local dist = distanceTo(plr)
	local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	local alive = hum and hum.Health > 0

	tName.Text = plr.Name
	tInfo.Text = string.format("%s · %d studs", alive and "[ALIVE]" or "[DEAD]", dist)
	tInfo.TextColor3 = alive and Color3.fromRGB(120, 220, 140) or Color3.fromRGB(200, 100, 100)
	local thumb = plr:GetAttribute("Thumbnail")
	avatar.Image = thumb and tostring(thumb) or ""
	money.Text = "$" .. tostring(#items)

	local assign, rest = classifyToSlots(items)
	local others = rest
	for i = 1, 12 do
		local cell = ensureGearCell(i)
		local it = assign[i]
		if it then
			cell.icon.Text = iconFor(it.name)
			local extra = ""
			if it.durability and it.maxDur then
				extra = string.format(" %d/%d", it.durability, it.maxDur)
			elseif it.ammo then
				extra = " " .. tostring(it.ammo)
			end
			cell.name.Text = tostring(it.name):sub(1, 10) .. extra
		else
			cell.icon.Text = ""
			cell.name.Text = ""
		end
	end

	local n = #others
	bagCount.Text = n .. " items"
	for i = 1, math.max(n, 1) do
		local cell = bagCells[i] or ensureBagCell(i)
		local it = others[i]
		if it then
			cell.frame.Visible = true
			cell.icon.Text = iconFor(it.name)
			cell.count.Text = ""
			cell.name.Text = tostring(it.name):sub(1, 10)
		else
			cell.frame.Visible = false
		end
	end
	for i = n + 1, #bagCells do
		if bagCells[i] then bagCells[i].frame.Visible = false end
	end
end

-- ============ 玩家高亮 ============
local hlFolder = Instance.new("Folder")
hlFolder.Name = "DawgPlayerHL"
hlFolder.Parent = HOLDER
local hlState = {}

local function updateHighlights()
	local lp = Players.LocalPlayer
	for plr, hl in pairs(hlState) do
		if not plr.Parent or plr == lp or not plr.Character then
			pcall(function() hl:Destroy() end)
			hlState[plr] = nil
		elseif hl.Adornee ~= plr.Character then
			hl.Adornee = plr.Character
		end
	end
	if not CFG.highlight or not CFG.masterEnabled then
		-- 自己的开关关了，或者总开关关了 → 销毁全部
		for plr, hl in pairs(hlState) do
			pcall(function() hl:Destroy() end)
			hlState[plr] = nil
		end
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp and plr.Character and not hlState[plr] then
			local hum = plr.Character:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local hl = Instance.new("Highlight")
				hl.Name = "HL_" .. plr.Name
				hl.FillColor = CFG.hlColor
				hl.OutlineColor = CFG.hlOutline
				hl.FillTransparency = CFG.hlFillTransparency
				hl.OutlineTransparency = CFG.hlOutlineTransparency
				hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				hl.Adornee = plr.Character
				hl.Parent = hlFolder
				hlState[plr] = hl
			end
		end
	end
end

Players.PlayerRemoving:Connect(function(plr)
	local hl = hlState[plr]
	if hl then
		pcall(function() hl:Destroy() end)
		hlState[plr] = nil
	end
end)

-- ============ ZOOM ============
local baseFov = nil
local zoomOn = false
local zoomArmedRef = nil

local function applyZoom(on)
	local cam = workspace.CurrentCamera
	if not cam then return end
	if baseFov == nil then baseFov = cam.FieldOfView end
	zoomOn = on
	if zoomArmedRef then zoomArmedRef(on) end
	if on then
		-- 开启：记录当前 FOV 作为基准，不立即放大
		baseFov = cam.FieldOfView
	else
		-- 关闭：恢复到基准
		if baseFov then
			TweenService:Create(cam, TweenInfo.new(CFG.zoomTween, Enum.EasingStyle.Quad), { FieldOfView = baseFov }):Play()
		end
		baseFov = nil
	end
end

-- ============ 输入 ============
local invOpen = false
local wasInv, wasZoom = false, false

RunService.RenderStepped:Connect(function()
	local invDown = UIS:IsKeyDown(CFG.invKey)
	if invDown and not wasInv then
		invOpen = not invOpen
		panel.Visible = invOpen
		if invOpen then refreshInv() end
	end
	wasInv = invDown

	local zoomDown = UIS:IsKeyDown(CFG.zoomKey)
	if zoomDown ~= wasZoom then applyZoom(zoomDown) end
	wasZoom = zoomDown
end)

-- 滚轮调倍率：必须按住鼠标右键 + 缩放功能开着
local zoomArmed = false
zoomArmedRef = function(v) zoomArmed = v end
local rmbDown = false

UIS.InputBegan:Connect(function(input, gp)
	if isZoomModInput(input) then
		rmbDown = true
		if zoomArmed then
			local cam = workspace.CurrentCamera
			if cam and baseFov then
				TweenService:Create(cam, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { FieldOfView = math.max(4, math.min(CFG.zoomFov, baseFov)) }):Play()
			end
		end
	end
end)
UIS.InputEnded:Connect(function(input)
	if isZoomModInput(input) then
		rmbDown = false
		if zoomArmed and baseFov then
			local cam = workspace.CurrentCamera
			if cam then
				TweenService:Create(cam, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { FieldOfView = baseFov }):Play()
			end
		end
	end
end)

UIS.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
	if not zoomArmed then return end
	if not rmbDown then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	-- 滚轮上 = 放大（FOV 变小），滚轮下 = 缩小
	local cur = cam.FieldOfView
	local nxt = math.clamp(cur - input.Position.Z * 4, 4, 120)
	cam.FieldOfView = nxt
	CFG.zoomFov = nxt   -- 记住用户调到的倍率，下次按住右键直接用这个
end)

-- 刷新循环
local acc, hlAcc = 0, 0
RunService.Heartbeat:Connect(function(dt)
	hlAcc = hlAcc + dt
	if hlAcc >= 1.0 then
		hlAcc = 0
		pcall(updateHighlights)
	end
	if not panel.Visible then return end
	acc = acc + dt
	if acc < 0.35 then return end
	acc = 0
	pcall(refreshInv)
end)

task.spawn(function()
	task.wait(1.0)
	pcall(updateHighlights)
end)

-- ============ 导出 ============
local M = {
	cfg = CFG,
	readInventory = readInventory,
	nearest = nearestByCrosshair,
	refresh = refreshInv,
	toggleInv = function()
		invOpen = not invOpen
		panel.Visible = invOpen
		if invOpen then refreshInv() end
		return invOpen
	end,
	setZoom = function(on) applyZoom(on and true or false) return zoomOn end,
	toggleZoom = function() applyZoom(not zoomOn) return zoomOn end,
	isZoomOn = function() return zoomOn end,
	setInvKey = function(kc) CFG.invKey = kc end,
	setZoomKey = function(kc) CFG.zoomKey = kc end,
	setZoomModKey = function(k)
		CFG.zoomModKey = k
		return zoomModLabel()
	end,
	getZoomModLabel = function() return zoomModLabel() end,
	setMaster = function(on)
		CFG.masterEnabled = on and true or false
		updateHighlights()
		return CFG.masterEnabled
	end,
	setHighlight = function(on)
		CFG.highlight = on and true or false
		updateHighlights()
		return CFG.highlight
	end,
	setScale = function(v) uscale.Scale = math.clamp(tonumber(v) or 1, 0.7, 1.8) end,
	hlCount = function() local n = 0 for _ in pairs(hlState) do n = n + 1 end return n end,
	destroy = function()
		pcall(function() gui:Destroy() end)
		GENV.__DAWG_LOOTZOOM = nil
	end,
}

GENV.__DAWG_LOOTZOOM = M
print(string.format("[战利品/缩放] 就绪 · %s 背包 · %s 缩放 · 高亮常驻", CFG.invKey.Name, CFG.zoomKey.Name))
return M
