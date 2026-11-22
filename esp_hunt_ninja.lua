--[[ 狩猎 ESP · 动物 + 玩家高亮 + 距离牌
     自适应：不假设 Humanoid / Tool，只认 Model + PrimaryPart
     执行：loadstring(readfile("dawg/esp_hunt.lua"))()
     卸载：getgenv().__DAWG_HUNT_ESP.destroy()
]]
local GENV = getgenv()

-- ============ 忍者执行器适配层 ============
-- 忍者（Ninja）跟 Potassium 的差异主要在三处，全部做成「有就用、没有就降级」，
-- 不做硬依赖：缺 Drawing 就不画线（高亮和标签照常），缺 getgc 就不开子追（面板给提示），
-- 缺 hookmetamethod 同理。降级信息都写进 GENV.__NINJA_CAPS 方便面板显示。
local CAPS = {
	getgenv = (type(getgenv) == "function"),
	gethui = (type(gethui) == "function"),
	Drawing = (typeof(Drawing) == "table" or typeof(Drawing) == "userdata"),
	getgc = (type(getgc) == "function"),
	hookmetamethod = (type(hookmetamethod) == "function"),
	newcclosure = (type(newcclosure) == "function"),
	readfile = (type(readfile) == "function"),
	writefile = (type(writefile) == "function"),
	identify = (type(identifyexecutor) == "function") and select(1, pcall(identifyexecutor)) and true or false,
}
GENV.__NINJA_CAPS = CAPS

-- Drawing 缺失时塞一个空壳，让后续所有 Drawing.xxx 调用变成无害的 no-op
if not CAPS.Drawing then
	Drawing = setmetatable({}, {
		__index = function(_, k)
			if k == "new" then
				return function()
					return setmetatable({}, {
						__index = function() return 0 end,
						__newindex = function() end,
					})
				end
			end
			if k == "clear" then return function() end end
			return nil
		end,
	})
end

-- 自动 boot DawgKit：忍者里通常不会预先加载，这里补齐
local Kit = GENV.__DAWG_KIT
if not Kit then
	local okBoot = pcall(function()
		if CAPS.readfile then
			local src = readfile("DawgKit.lua")
			if src and #src > 1000 then
				local fn = loadstring(src)
				if fn then fn() end
			end
		end
	end)
	Kit = GENV.__DAWG_KIT
	if not Kit then
		error("[忍者版] 找不到 DawgKit：请先把 DawgKit.lua 放进执行器工作目录（boot ok=" .. tostring(okBoot) .. "）")
	end
end
-- 忍者没有 gethui 时统一退回 CoreGui
local function uiHolder()
	if CAPS.gethui then
		local ok, h = pcall(gethui)
		if ok and h then return h end
	end
	return game:GetService("CoreGui")
end

-- 忍者里 identifyexecutor 可能不存在，给个兜底名
local EXEC_NAME = "未知执行器"
pcall(function()
	if type(identifyexecutor) == "function" then EXEC_NAME = tostring((identifyexecutor())) end
end)

-- 注意：这个执行器里 getgenv() ~= _G，句柄一律挂 genv（K86）
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

-- 不销毁旧实例。旧实例靠 GENV.__DAWG_GEN 世代号自行退休（见 connSync 守卫），
-- 面板容器 / Highlight / BillboardGui 全部按名字复用（见 holder 与 attach）。
-- 这样重载等于「新逻辑盖在旧实例上」，没有销毁-重建的空窗，也不会越叠越多。


local CFG = {
	animals = true,
	players = false,
	maxDist = 2000,
	useFluent = true,    -- Fluent 面板（本地优先，MinimizeKey=RightShift）
	refresh = 0.5,
	collectSamples = false,   -- 结算数据采集（默认关，样本已够）
	distEvery = 0.2,
	-- 子弹追踪（P33：替换 ProjectileCaster.Fire 的 dir，不 hook 任何 remote）
	-- 默认关：加载脚本时不接管 Caster，由用户在面板里自己打开
	-- 默认关：加载脚本时不接管 Caster。但记住上一次用户在面板里的选择，
	-- 否则重载后面板开关看着还是开、实际 CFG 已经回到 false —— 线不画、子弹却还在拐弯。
	btrack = (type(getgenv().__DAWG_BTRACK_LAST) == "boolean") and getgenv().__DAWG_BTRACK_LAST or false,
	btrackFov = 300,          -- 准星圈像素半径：圈内才算候选，圈就是按这个画的
	btrackLead = 1.0,       -- 提前量系数：1.0 = 按"距离/弹速"完整预判，0 = 不预判
	btrackNoDrop = true,    -- 去掉子弹下坠（实测重力 acc = (0, -35.04, 0)，只清 Y 分量）
	btrackMinDist = 5,
	btrackAimPart = "body",   -- 瞄准部位：body = 两肺中点，head = Eyes（头部骨骼上的 Attachment）
	btrackLine = true,      -- 屏幕中心到目标的锁定线
	btrackText = true,      -- 目标名字+距离
	btrackColor = Color3.fromRGB(0, 255, 120),
	btrackOffColor = Color3.fromRGB(255, 170, 60),
}


-- 按名字挑颜色（关键词映射，未知走默认）
local PALETTE = {
	deer = { fill = Color3.fromRGB(70, 220, 120), line = Color3.fromRGB(150, 255, 190) },
	bird = { fill = Color3.fromRGB(255, 210, 80), line = Color3.fromRGB(255, 240, 160) },
	fox  = { fill = Color3.fromRGB(255, 110, 50), line = Color3.fromRGB(255, 170, 120) },
	byPlayer = { fill = Color3.fromRGB(90, 160, 255), line = Color3.fromRGB(170, 210, 255) },
	mine = { fill = Color3.fromRGB(40, 230, 90), line = Color3.fromRGB(120, 255, 150), fillTransp = 0.55, width = 168 },
	hit  = { fill = Color3.fromRGB(20, 60, 200), line = Color3.fromRGB(90, 140, 255), fillTransp = 0.5, width = 140 },
	other = { fill = Color3.fromRGB(255, 60, 60), line = Color3.fromRGB(255, 140, 140) },
}

local SPECIES_CN = {
	-- 北美
	whitetaileddeer = "白尾鹿", muledeer = "骡鹿", blacktaileddeer = "黑尾鹿",
	moose = "驼鹿", elk = "马鹿", caribou = "驯鹿", reindeer = "驯鹿",
	pronghorn = "叉角羚", bighornsheep = "大角羊", dallsheep = "白大角羊",
	redfox = "赤狐", grayfox = "灰狐", arcticfox = "北极狐",
	graywolf = "灰狼", timberwolf = "林狼", wolf = "狼", coyote = "郊狼",
	bobcat = "短尾猫", lynx = "猞猁", cougar = "美洲狮", mountainlion = "美洲狮", puma = "美洲狮",
	blackbear = "黑熊", brownbear = "棕熊", grizzly = "灰熊", polarbear = "北极熊", bear = "熊",
	bison = "野牛", buffalo = "水牛", wildboar = "野猪", boar = "野猪", feralhog = "野猪",
	raccoon = "浣熊", opossum = "负鼠", skunk = "臭鼬", badger = "獾",
	beaver = "河狸", muskrat = "麝鼠", otter = "水獭", marten = "貂", mink = "水貂", wolverine = "狼獾",
	turkey = "火鸡", pheasant = "雉鸡", ruffedgrouse = "披肩榛鸡", grouse = "榛鸡",
	quail = "鹌鹑", duck = "野鸭", mallard = "绿头鸭", goose = "大雁", dove = "斑鸠", woodcock = "丘鹬",
	rabbit = "兔", hare = "野兔", snowshoehare = "雪鞋兔", squirrel = "松鼠",
	-- 非洲
	bluewildebeest = "蓝角马", wildebeest = "角马", plainszebra = "平原斑马", zebra = "斑马",
	spottedhyena = "斑鬣狗", hyena = "鬣狗", jackal = "胡狼", baboon = "狒狒",
	lion = "狮子", leopard = "豹", cheetah = "猎豹", elephant = "大象", africanelephant = "非洲象",
	capebuffalo = "非洲水牛", giraffe = "长颈鹿", hippo = "河马", rhino = "犀牛",
	crocodile = "鳄鱼", warthog = "疣猪", impala = "黑斑羚", kudu = "捻角羚",
	gemsbok = "南非剑羚", springbok = "跳羚", blesbok = "白脸牛羚", sable = "黑马羚",
	waterbuck = "水羚", eland = "大羚羊", duiker = "小羚羊", steenbok = "石羚", ostrich = "鸵鸟",
	-- 印度 / 亚洲
	chital = "花鹿", axisdeer = "花鹿", sambar = "水鹿", nilgai = "蓝牛羚",
	blackbuck = "印度黑羚", gaur = "印度野牛", slothbear = "懒熊", mugger = "泽鳄",
	-- 通用 / 其他
	bloodhound = "寻血猎犬", dog = "猎犬", tiger = "老虎", deer = "鹿", buck = "公鹿", doe = "母鹿",
	antelope = "羚羊", sheep = "绵羊", ram = "公羊", goat = "山羊",
}

local function speciesKey(name)
	local k = string.lower(tostring(name)):gsub("[%s_%-]+", "")
	-- 变异个体的模型名会带后缀（BlueWildebeestLeucistic / PiebaldMale 之类），
	-- 不剥掉就匹配不到汉化表，整个名字变英文。
	k = k:gsub("leucistic", ""):gsub("piebald", ""):gsub("melanistic", ""):gsub("albino", "")
	k = k:gsub("^female", ""):gsub("^male", ""):gsub("female$", ""):gsub("male$", "")
	return k
end

-- 游戏会用 "???" / "?" 这种占位名表示「未识别物种」，
-- 直接当名字用就会在 ESP 上看到「? ? ? 1200m」。所有取名的地方都要先过这层。
local function isPlaceholderName(s)
	if s == nil then return true end
	local t = tostring(s)
	if t == "" then return true end
	return t:match("^[%s%?]*$") ~= nil
end

local function localName(model)
	local k = speciesKey(model.Name)
	local cn = (not isPlaceholderName(model.Name)) and SPECIES_CN[k] or nil
	if not cn then
		local disp = model:GetAttribute("DisplayName")
		if disp and not isPlaceholderName(disp) then
			local k2 = speciesKey(disp)
			cn = SPECIES_CN[k2]
			if not cn then k = k2 end
		end
	end
	if not cn then
		-- 包含匹配兜底：取能匹配上的最长词根（wildboar / polar_bear / big_horn_sheep 这类都能吃到）
		local bestLen, bestCn = 0, nil
		for word, val in pairs(SPECIES_CN) do
			if #word > bestLen and string.find(k, word, 1, true) then
				bestLen, bestCn = #word, val
			end
		end
		cn = bestCn
	end
	if not cn then
		-- 兜底顺序：DisplayName 再查一遍中文表 -> DisplayName 原文 -> 模型名 -> Species 属性
		-- 全程排除 "???"，最后一步保证一定拿到非问号的名字
		local disp = model:GetAttribute("DisplayName")
		if disp and not isPlaceholderName(disp) then
			cn = SPECIES_CN[speciesKey(disp)] or tostring(disp)
		end
	end
	if not cn and not isPlaceholderName(model.Name) then cn = tostring(model.Name) end
	if not cn then
		local sp = model:GetAttribute("Species")
		if sp and not isPlaceholderName(sp) then
			cn = SPECIES_CN[speciesKey(sp)] or tostring(sp)
		end
	end
	if not cn then cn = "未知" end
	local sex = model:GetAttribute("Sex")
	local mark = (sex == "Female" and "♀") or (sex == "Male" and "♂") or ""
	return cn .. mark
end

-- 每个物种一个固定颜色：按物种 key 哈希取色，同类永远同色。
-- 必须缓存返回的表（style 是引用比较，每次新建表会导致每帧重设颜色、闪烁）。
-- 按物种区分颜色：按「首次出现顺序」分配（哈希会撞色，实测 Tiger/WildBoar 同色）。
-- 色池不含绿色系 —— 绿色是「尸体（我打的）」专用。
-- 老虎单独指定深红，一眼认出来。
local TIGER_PAL = { fill = Color3.fromRGB(165, 16, 16), line = Color3.fromRGB(215, 70, 70) }
local SPECIES_COLORS = {
	{ fill = Color3.fromRGB(255, 82, 82),   line = Color3.fromRGB(255, 140, 140) }, -- 红
	{ fill = Color3.fromRGB(255, 152, 50),  line = Color3.fromRGB(255, 196, 120) }, -- 橙
	{ fill = Color3.fromRGB(255, 220, 60),  line = Color3.fromRGB(255, 240, 140) }, -- 黄
	{ fill = Color3.fromRGB(90, 160, 255),  line = Color3.fromRGB(152, 196, 255) }, -- 蓝
	{ fill = Color3.fromRGB(182, 120, 255), line = Color3.fromRGB(212, 176, 255) }, -- 紫
	{ fill = Color3.fromRGB(255, 120, 210), line = Color3.fromRGB(255, 176, 236) }, -- 粉
	{ fill = Color3.fromRGB(255, 200, 132), line = Color3.fromRGB(255, 226, 182) }, -- 杏
	{ fill = Color3.fromRGB(160, 200, 255), line = Color3.fromRGB(200, 224, 255) }, -- 天蓝
	{ fill = Color3.fromRGB(255, 170, 170), line = Color3.fromRGB(255, 205, 205) }, -- 浅红
	{ fill = Color3.fromRGB(210, 180, 255), line = Color3.fromRGB(230, 210, 255) }, -- 浅紫
	{ fill = Color3.fromRGB(255, 110, 70),  line = Color3.fromRGB(255, 165, 130) }, -- 珊瑚
	{ fill = Color3.fromRGB(230, 90, 170),  line = Color3.fromRGB(245, 150, 200) }, -- 品红
	{ fill = Color3.fromRGB(120, 140, 255), line = Color3.fromRGB(170, 185, 255) }, -- 靛蓝
	{ fill = Color3.fromRGB(255, 235, 150), line = Color3.fromRGB(255, 245, 200) }, -- 米黄
	{ fill = Color3.fromRGB(205, 130, 90),  line = Color3.fromRGB(230, 175, 145) }, -- 土橙
	{ fill = Color3.fromRGB(255, 160, 200), line = Color3.fromRGB(255, 200, 225) }, -- 玫瑰
}

local speciesPalCache = {}
local nextPalIdx = 0
-- 变体中文（Default 不显示）
local VARIANT_CN = {
	-- 毛色变异
	Leucistic = "白化", Albino = "白化", Piebald = "花斑", Melanistic = "黑化",
	MelanisticLeucistic = "黑化白化", Blonde = "金色", Cinnamon = "肉桂",
	Red = "红化", Brown = "褐色", Grey = "灰色", Gray = "灰色", Silver = "银色",
	Dark = "暗色", Light = "浅色", Golden = "金色", Black = "黑色", White = "白色",
	Chestnut = "栗色", Tawny = "黄褐", Rust = "锈色", Cream = "奶油色",
	Chocolate = "巧克力色", Tan = "棕褐", Olive = "橄榄色", Blue = "蓝色",
}

--- 变异标记（活体上直接标出来，Default 不标）
local function variantTag(m)
	local v = m:GetAttribute("Variant")
	if v and v ~= "Default" and v ~= "" then
		return " ★" .. (VARIANT_CN[v] or tostring(v))
	end
	return ""
end

--- 重量 / 年龄（活体直接读属性就有）
local function extraInfo(m)
	local parts = {}
	local w = m:GetAttribute("Weight")
	if type(w) == "number" then parts[#parts + 1] = string.format("%.0fkg", w) end
	local a = m:GetAttribute("Age")
	if type(a) == "number" then parts[#parts + 1] = string.format("%.1f年", a) end
	if #parts == 0 then return "" end
	return " " .. table.concat(parts, " ")
end

-- 物种基础分（已实测的两个；其余未知先按 0，打多了可以补）
local SPECIES_BASE = {
	tiger = 108, wildboar = 0,
}

-- 实测样本表：每个物种的 (重量→加分, 年龄→加分)。加分不是线性的（花鹿 54kg→16，65kg→99），
-- 所以有样本就用「最近邻」查表，没有才退回到粗略公式。
local speciesSamples = GENV.__DAWG_SPECIES_SAMPLES
if type(speciesSamples) ~= "table" then
	speciesSamples = {}
	GENV.__DAWG_SPECIES_SAMPLES = speciesSamples
end

--- 按某个字段线性插值（点太少时退回最近邻）
local function interpBy(points, key, field, val)
	local sorted = {}
	for _, p in ipairs(points) do
		if type(p[key]) == "number" and type(p[field]) == "number" then sorted[#sorted + 1] = p end
	end
	if #sorted == 0 then return 0 end
	table.sort(sorted, function(a, b) return a[key] < b[key] end)
	if val <= sorted[1][key] then return sorted[1][field] end
	if val >= sorted[#sorted][key] then return sorted[#sorted][field] end
	for i = 1, #sorted - 1 do
		local a, b = sorted[i], sorted[i + 1]
		if val >= a[key] and val <= b[key] then
			local t = (val - a[key]) / math.max(b[key] - a[key], 1e-6)
			return a[field] + (b[field] - a[field]) * t
		end
	end
	return sorted[#sorted][field]
end

-- 只有老虎和豹的样本够拟合（老虎 2 点、豹有基础分 120 打底），其余物种的重量分按公母标准体重算、
-- 数据自相矛盾（母鹿 65kg +99，公鹿 74kg 只 +9），预估会误导，所以干脆不显示。
local ESTIMATE_OK = { tiger = true, leopard = true }

--- 预估分：只对老虎/豹给（样本够的物种）
local function estimateScore(m)
	local key = speciesKey(m.Name)
	if not ESTIMATE_OK[key] then return nil end
	local w = m:GetAttribute("Weight") or 0
	local a = m:GetAttribute("Age") or 0
	local sex = m:GetAttribute("Sex")
	local base = SPECIES_BASE[key] or 0

	local pts = speciesSamples[key]
	if pts and #pts > 0 then
		local wb = interpBy(pts, "w", "wb", w)
		local ab = interpBy(pts, "a", "ab", a)
		local sb = interpBy(pts, "w", "sb", w)
		return math.floor(sb + wb + ab + (sex == "Male" and 5 or 0) + 1 + 0.5)
	end

	-- 兜底公式（不准，只用于没打过的物种）
	local s = base + (sex == "Male" and 5 or 0) + w * 0.9 + math.pow(a, 1.85) * 5 + 1
	return math.floor(s + 0.5)
end

--- 活体预估分（只有老虎/豹有样本；其他物种返回空串）
local function liveScoreTag(m)
	local okE, est = pcall(estimateScore, m)
	if okE and type(est) == "number" and est > 0 then
		return string.format(" 约%d分", est)
	end
	return ""
end

--- 「值得打」标记：高龄 / 大体重
--- 年龄 ≥8 岁直接标；或 ≥5 岁且体重达到本物种已见样本最大值的 85%
local function hotTag(m)
	local age = m:GetAttribute("Age") or 0
	local w = m:GetAttribute("Weight") or 0
	if age >= 8 then return " ！" end
	if age >= 5 then
		local pts = speciesSamples[speciesKey(m.Name)]
		if pts and #pts >= 2 then
			local maxW = 0
			for _, p in ipairs(pts) do
				if (p.w or 0) > maxW then maxW = p.w end
			end
			if maxW > 0 and w >= maxW * 0.85 then return " ！" end
		end
	end
	return ""
end

local function colorFor(model)
	local key = speciesKey(model.Name)
	if key == "" then key = string.lower(tostring(model.Name)) end
	local cached = speciesPalCache[key]
	if cached then return cached end
	if key == "tiger" then
		speciesPalCache[key] = TIGER_PAL
		return TIGER_PAL
	end
	nextPalIdx = nextPalIdx + 1
	local c = SPECIES_COLORS[((nextPalIdx - 1) % #SPECIES_COLORS) + 1]
	local pal = { fill = c.fill, line = c.line, fillTransp = 0.62, width = 200 }
	speciesPalCache[key] = pal
	return pal
end

-- 不去碰旧实例（K59/K60 的销毁会被旧逻辑的 destroy 牵连）。
-- 旧实例靠世代号退休，容器与视觉实例全部复用。

-- 策略固定，不调 Kit.ac.harden()：它每次装载重扫一遍 ReplicatedStorage，
-- 偶尔撞上瞬时对象就判 level=high，把 maxSendHz 砍到 5、禁掉 namecall hook，
-- 表现就是"有时候好好的，重载一次就变卡变傻"。这游戏实测 level=none（338 个脚本 0 命中）。
local acPolicy = { maxSendHz = 10, allowNamecallHook = true }

local holder = uiHolder()
-- 重载策略：不销毁、不重建，直接接管旧容器。
-- 理由：销毁 → 重建之间有一帧空窗（动物标记全闪一下），而且旧引用一旦丢在场景里就会越叠越多。
-- 改成「有就复用、没有才建」，重载等于把新逻辑盖到同一套实例上，视觉上零中断。
local folder = holder:FindFirstChild("DawgHuntESP")
if not folder or not folder:IsA("Folder") then
	folder = Kit.new("Folder", { Name = "DawgHuntESP" }, holder)
end


---------------------------------------------------------------- 自适应目标源
-- 不同服务器 / 不同游戏，动物文件夹名字不一样：先认常见名，再按名字关键词兜底
local SOURCE_FOLDERS = { "Animals", "Mobs", "NPCs", "Enemies", "Creatures", "Wildlife" }
local NAME_HINTS = { "deer", "fox", "grouse", "bird", "boar", "bear", "rabbit", "wolf", "elk", "duck", "coyote", "animal" }

-- 这些文件夹里的东西可以显示，但不当瞄准目标（玩家的狗会一直贴脸，锁死视角）
local AIM_EXCLUDE = { "Dogs" }

local function isPet(model)
	local p = model.Parent
	while p and p ~= workspace do
		if p.Name == "Dogs" then return true end
		p = p.Parent
	end
	return false
end

local function collectAnimals()
	local list, seen = {}, {}
	local function add(m)
		if m and m:IsA("Model") and not seen[m] then
			seen[m] = true
			list[#list + 1] = m
		end
	end
	for _, fname in ipairs(SOURCE_FOLDERS) do
		local f = workspace:FindFirstChild(fname)
		if f then
			for _, m in ipairs(f:GetChildren()) do add(m) end
		end
	end
	if #list == 0 then
		-- 兜底只扫 workspace 直接子级，绝不 GetDescendants（K52：别全量扫）
		for _, m in ipairs(workspace:GetChildren()) do
			if m:IsA("Model") then
				local n = string.lower(m.Name)
				for _, k in ipairs(NAME_HINTS) do
					if string.find(n, k, 1, true) then
						add(m)
						break
					end
				end
			end
		end
	end
	return list
end

local targets = {}   -- [model] = {hl, billboard, label}
-- 挂 genv：重载脚本不丢（否则每次我改代码，你打过的记录就没了）
local myKills = getgenv().__DAWG_KILLS
if type(myKills) ~= "table" then
	myKills = {}
	getgenv().__DAWG_KILLS = myKills
end

local myKillModels = getgenv().__DAWG_KILL_MODELS
if type(myKillModels) ~= "table" then
	myKillModels = {}
	getgenv().__DAWG_KILL_MODELS = myKillModels
end

-- 候选击杀：开火时只登记 Id，等尸体真的出现（8 秒内）才转正成击杀。
-- 直接记「开火时准星附近的动物」会把打空的也标成尸体（K89）。
local pendingKills = getgenv().__DAWG_PENDING_KILLS
if type(pendingKills) ~= "table" then
	pendingKills = {}
	getgenv().__DAWG_PENDING_KILLS = pendingKills
end

local function markPending(model)
	if not model then return end
	local ok, id = pcall(function() return model:GetAttribute("Id") end)
	if ok and id ~= nil then
		pendingKills[tostring(id)] = os.clock()
	end
end

local function rememberKill(model)
	if not model then return end
	myKillModels[model] = true -- 引用：父级怎么变都认
	local ok, id = pcall(function() return model:GetAttribute("Id") end)
	if ok and id ~= nil then
		myKills[tostring(id)] = true
	end
end

-- 开火瞬间就记账：不依赖「锁定目标」（手动瞄准时 aim.target 是 nil，一枪死的动物根本记不上）。
-- 一次点击可能打死多只（霰弹），所以把准星附近的都记进来。
local fireConn
-- 射线判定：从相机中心往前打一条线，只有真正被这条线打中的动物才算「打中」。
-- 之前用「准星 160px 内全部记一笔」，周围没打中的也被记 → 它们后来死了就被误标成我的尸体。
local function raycastAnimal()
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ign = {}
	local ch = Players.LocalPlayer.Character
	if ch then ign[#ign + 1] = ch end
	if folder then ign[#ign + 1] = folder end
	-- 必须忽略相机下的后代：第一人称 viewmodel（手里那把枪的 WeaponRootPart）
	-- 就贴在相机前面 1 格，不忽略的话射线第一格就撞到自己手里的枪，
	-- raycastAnimal 立刻返回 nil，markPending 永远不执行 → 尸体不被认成自己的。
	if cam then ign[#ign + 1] = cam end
	params.FilterDescendantsInstances = ign
	local ok, result = pcall(function()
		return workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 2000, params)
	end)
	if not ok or not result or not result.Instance then return nil end
	local node = result.Instance
	local depth = 0
	local found = nil
	while node and depth < 6 do
		if targets[node] then found = node break end
		node = node.Parent
		depth = depth + 1
	end
	if not found then return nil end
	-- 第二道校验：命中的模型必须在准星 120 像素内。
	-- 装饰墙可能 CanQuery=false，射线会穿过去打到墙后的动物；靠屏幕距离把这种剔掉。
	local vp = cam.ViewportSize
	local sp, onScreen = cam:WorldToViewportPoint(found.PrimaryPart and found.PrimaryPart.Position or found:GetPivot().Position)
	if not onScreen then return nil end
	local dx, dy = sp.X - vp.X / 2, sp.Y - vp.Y / 2
	if math.sqrt(dx * dx + dy * dy) > 120 then return nil end
	return found
end

fireConn = UIS.InputBegan:Connect(function(input, gp)
	-- 不检查 gp：游戏自己的 UI 会消费点击，gp 常常是 true
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	local hit = raycastAnimal()
	if hit then markPending(hit) end

	-- 诊断：记录每次开火时 raycastAnimal 的结果与失败原因（最多 20 条）
	local diag = GENV.__DAWG_FIRE_DIAG
	if type(diag) ~= "table" then diag = {} GENV.__DAWG_FIRE_DIAG = diag end
	local rec = { t = os.clock(), ok = hit ~= nil }
	if hit then
		rec.name = hit.Name
	else
		local cam2 = workspace.CurrentCamera
		if cam2 then
			local p2 = RaycastParams.new()
			p2.FilterType = Enum.RaycastFilterType.Exclude
			local ig = {}
			local c2 = Players.LocalPlayer.Character
			if c2 then ig[#ig + 1] = c2 end
			if folder then ig[#ig + 1] = folder end
			if cam2 then ig[#ig + 1] = cam2 end
			p2.FilterDescendantsInstances = ig
			local ok2, r2 = pcall(function()
				return workspace:Raycast(cam2.CFrame.Position, cam2.CFrame.LookVector * 2000, p2)
			end)
			if ok2 and r2 and r2.Instance then
				rec.rayPart = r2.Instance.Name
				rec.rayDist = math.floor(r2.Distance)
				local node, dp = r2.Instance, 0
				while node and dp < 6 do
					if node:IsA("Model") then
						local ok3, id = pcall(function() return node:GetAttribute("Id") end)
						if ok3 and id ~= nil then
							rec.foundModel = node.Name
							rec.inTargets = targets[node] ~= nil
							local vp = cam2.ViewportSize
							local pos = node.PrimaryPart and node.PrimaryPart.Position or node:GetPivot().Position
							local sp, onScr = cam2:WorldToViewportPoint(pos)
							if onScr then
								local ddx, ddy = sp.X - vp.X / 2, sp.Y - vp.Y / 2
								rec.offsetPx = math.floor(math.sqrt(ddx * ddx + ddy * ddy))
							else
								rec.offsetPx = -1
							end
							break
						end
					end
					node = node.Parent
					dp = dp + 1
				end
			else
				rec.rayPart = "noHit"
			end
		end
	end
	diag[#diag + 1] = rec
	if #diag > 20 then table.remove(diag, 1) end
end)

-- 结算数据采集（只为推算公式用，不影响显示）
-- 面板上直接写着每项加成分：Tiger (+108) / 76 kg (+69) / 2 years (+18) / Male (+5)
local scoreSamples = GENV.__DAWG_SCORE_SAMPLES
if type(scoreSamples) ~= "table" then
	scoreSamples = {}
	GENV.__DAWG_SCORE_SAMPLES = scoreSamples
end
local lastSampleKey = nil

local function collectSample()
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local root = pg and pg:FindFirstChild("RootGui")
	if not root then return end
	local d = {}
	local hasScore = false
	for _, lbl in ipairs(root:GetDescendants()) do
		if lbl:IsA("TextLabel") then
			local t = lbl.Text
			if t == "Score" or t == "得分" then hasScore = true end
			local sv = t:match("^(%d+%.%d+)$")
			if sv then d.score = tonumber(sv) end
			local name, bonus = t:match("^(.-) %(%+(%d+)%)$")
			if name and bonus then
				bonus = tonumber(bonus)
				local kg = name:match("^(%d+) kg$") or name:match("^(%d+)%s*公斤$")
				local yr = name:match("^(%d+) years?$") or name:match("^(%d+)%s*年$")
				local sec = name:match("^(%d+) s$")
				if kg then d.weight = tonumber(kg) d.weightBonus = bonus
				elseif yr then d.age = tonumber(yr) d.ageBonus = bonus
				elseif sec then d.time = tonumber(sec) d.timeBonus = bonus
				elseif name == "Male" or name == "Female" or name == "男性" or name == "女性" then d.sex = name d.sexBonus = bonus
				elseif name == "Default" or name == "默认" or name == "Leucistic" or name == "Albino" or name == "Piebald" or name == "Melanistic" then d.variant = name d.variantBonus = bonus
				else d.species = name d.speciesBonus = bonus end
			end
		end
	end
	if not (hasScore and d.score and d.species) then return end
	-- 单次得分 = 各项加成分之和（面板上的 Score 是累积值，不能用）
	d.sum = (d.speciesBonus or 0) + (d.sexBonus or 0) + (d.weightBonus or 0)
		+ (d.ageBonus or 0) + (d.variantBonus or 0) + (d.timeBonus or 0)
	-- 去重键不含 score，否则同一次结算会被记很多条
	local key = string.format("%s|%s|%s|%s", tostring(d.species), tostring(d.weight), tostring(d.age), tostring(d.sex))
	if key == lastSampleKey then return end
	lastSampleKey = key
	table.insert(scoreSamples, d)
	if #scoreSamples > 60 then table.remove(scoreSamples, 1) end
	-- 同时进物种样本表（供预估分查表）
	local sk = speciesKey(tostring(d.species))
	if sk and sk ~= "" then
		speciesSamples[sk] = speciesSamples[sk] or {}
		table.insert(speciesSamples[sk], {
			w = d.weight, wb = d.weightBonus or 0,
			a = d.age, ab = d.ageBonus or 0,
			sb = d.speciesBonus or 0,
		})
		if #speciesSamples[sk] > 20 then table.remove(speciesSamples[sk], 1) end
	end
	if Kit.log then
		Kit.log(string.format("样本+1 %s %s %skg %s岁 → %d分（共%d条）",
			tostring(d.species), tostring(d.sex), tostring(d.weight), tostring(d.age), d.sum, #scoreSamples))
	end
end

-- 只让最新实例的循环活着：每次加载换一个 owner，旧循环发现自己不是 owner 就退出。
-- （之前只用 true/false 开关，多次重载会留下好几个循环同时跑、重复采样）
-- 样本已经够用了，默认不再采集（想继续收集把 CFG.collectSamples 设成 true）
if not CFG.collectSamples then
	GENV.__DAWG_COLLECT_OWNER = nil
else
	local myOwner = {}
	GENV.__DAWG_COLLECT_OWNER = myOwner
	task.spawn(function()
		while true do
			task.wait(0.5)
			if GENV.__DAWG_COLLECT_OWNER ~= myOwner then return end
			GENV.__DAWG_COLLECT_RUNS = (GENV.__DAWG_COLLECT_RUNS or 0) + 1
			local okC, errC = pcall(collectSample)
			if not okC then GENV.__DAWG_COLLECT_ERR = tostring(errC) end
		end
	end)
end

-- 尸体：只挑「我打的」
-- 三个来源：官方 AnimalRagdoll 标签（父级无关）、DeadAnimals 文件夹、我打过的模型引用
local CollectionService = game:GetService("CollectionService")

local function collectMyCarcasses()
	local list, seen = {}, {}

	local function add(m)
		if not m or not m:IsA("Model") or seen[m] or not m.Parent then return end
		local ok, id = pcall(function() return m:GetAttribute("Id") end)
		local idStr = (ok and id ~= nil) and tostring(id) or nil
		-- 认领分两步，缺一步就会「尸体高亮闪一下就没了」：
		--   ① 候选 pendingKills：射线打中时登记，5 分钟内真的成了尸体才转正；
		--   ② 转正后必须落成持久记录（myKills[id] + myKillModels[m]），
		--      否则 pendingKills 一删，下一轮扫描就认不出这具尸体了。
		local mine = (idStr ~= nil and myKills[idStr] == true) or myKillModels[m] == true
		if not mine and idStr then
			local ts = pendingKills[idStr]
			if ts and (os.clock() - ts) < 300 then
				mine = true
				myKills[idStr] = true
				myKillModels[m] = true
				pendingKills[idStr] = nil
			end
		end
		if mine then
			seen[m] = true
			list[#list + 1] = m
		end
	end

	for _, m in ipairs(CollectionService:GetTagged("AnimalRagdoll")) do add(m) end
	local dead = workspace:FindFirstChild("DeadAnimals")
	if dead then
		for _, m in ipairs(dead:GetChildren()) do add(m) end
	end
	-- 清掉超过 5 分钟还没变成尸体的候选
	for id, ts in pairs(pendingKills) do
		if os.clock() - ts > 300 then pendingKills[id] = nil end
	end
	-- myKillModels 不再参与判定，只做清理（历史残留的引用该放就放）
	for m in pairs(myKillModels) do
		if not m.Parent then myKillModels[m] = nil end
	end
	return list
end

-- 每只动物的唯一 key：优先 Id 属性（形如 1795353705360-1e7495f7-...-0，每只都不同），
-- 拿不到时退回 DebugId。绝不能用 model.Name —— 同一种动物会同时存在多只
-- （实测 4 只 RuffedGrouse、3 只 WhiteTailedDeerFemale），按名字命名会让它们
-- 共用同一个 Highlight / BillboardGui：后 attach 的那只抢走名字，前面的全变成没有高亮。
local function animalKey(model)
	local ok, id = pcall(function() return model:GetAttribute("Id") end)
	if ok and id ~= nil then return tostring(id) end
	local ok2, did = pcall(function() return model:GetDebugId() end)
	if ok2 and did then return tostring(did) end
	return tostring(model.Name) .. "_" .. tostring(math.floor(os.clock() * 1000))
end

local function attach(model, pal, tag)
	-- 复用同一 model 已有的高亮：只改参数，不新建。
	-- 重载时这层实例还在（容器被接管了），复用能避免「销毁→重建」之间的闪断，也不会越叠越多。
	local ukey = animalKey(model)
	local hlName = "HL_" .. ukey
	local hl = folder:FindFirstChild(hlName)
	if hl and hl:IsA("Highlight") then
		hl.FillColor = pal.fill
		hl.OutlineColor = pal.line
		hl.FillTransparency = pal.fillTransp or 0.62
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Adornee = model
	else
		hl = Kit.new("Highlight", {
			Name = hlName,
			FillColor = pal.fill, OutlineColor = pal.line,
			FillTransparency = pal.fillTransp or 0.62, OutlineTransparency = 0,
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
		}, folder)
		hl.Adornee = model
	end

	-- 牌子的高度按模型体型算：大动物（驼鹿 400kg 那种）会把牌子顶到身体里挡住高亮
	local cfgH = 2.5
	local okH, ext = pcall(function() return model:GetExtentsSize() end)
	if okH and ext and ext.Y > 0 then
		cfgH = ext.Y * 0.85 + 1.5
	end
	local bbName = "BB_" .. ukey
	local bb = folder:FindFirstChild(bbName)
	if bb and bb:IsA("BillboardGui") then
		bb.Size = UDim2.fromOffset(pal.width or 200, 40)
		bb.StudsOffsetWorldSpace = Vector3.new(0, cfgH, 0)
		bb.AlwaysOnTop = true
		bb.MaxDistance = CFG.maxDist
		bb.Adornee = model.PrimaryPart or model
	else
		bb = Kit.new("BillboardGui", {
			Name = bbName,
			Size = UDim2.fromOffset(pal.width or 200, 40),
			StudsOffsetWorldSpace = Vector3.new(0, cfgH, 0),
			AlwaysOnTop = true, MaxDistance = CFG.maxDist,
			LightInfluence = 0, ResetOnSpawn = false,
		}, folder)
		bb.Adornee = model.PrimaryPart or model
	end

	-- 复用已有的 Txt：之前无条件新建，重载几次同一个牌子上就叠几个 TextLabel，
	-- 文字互相压在一起（用户看到的"名字标记重叠"）。
	local label = bb:FindFirstChild("Txt")
	if label and label:IsA("TextLabel") then
		label.TextColor3 = pal.line
		label.Text = tag
	else
		label = Kit.new("TextLabel", {
			Name = "Txt", Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13,
			TextColor3 = pal.line, TextStrokeTransparency = 0.55,
			TextWrapped = true, Text = tag,
		}, bb)
	end

	-- 预估分单独一行（放最顶上）
	local scoreLine = ""
	local okS, est = pcall(estimateScore, model)
	if okS and type(est) == "number" and est > 0 then
		scoreLine = string.format("约%d分", est)
	end
	targets[model] = {
		hl = hl, bb = bb, label = label, tag = tag,
		sub = extraInfo(model), scoreLine = scoreLine, style = pal,
	}
end

local function sync()
	local seen = {}

	local function take(model, pal, tag)
		if not model or not model.Parent then return end
		seen[model] = true
		local t = targets[model]
		if not t then
			attach(model, pal, tag)
			return
		end
		-- 样式升级：同一实例从「活体」变「尸体」时，颜色/文字/宽度都要跟着换
		if t.tag ~= tag or t.style ~= pal then
			t.hl.FillColor = pal.fill
			t.hl.OutlineColor = pal.line
			t.hl.FillTransparency = pal.fillTransp or 0.62
			t.bb.Size = UDim2.fromOffset(pal.width or 200, 40)
			t.label.TextColor3 = pal.line
			t.tag = tag
			t.style = pal
		end
	end

	if CFG.animals then
		local carcasses = collectMyCarcasses()
		local carcassSet = {}
		for _, m in ipairs(carcasses) do carcassSet[m] = true end
		-- 我打死的先画（绿色描边，优先占位）
		for _, m in ipairs(carcasses) do
			pcall(noteCarcass, m)
			-- 预估分由 attach 的 scoreLine（第一行）统一显示，这里不再重复
			take(m, PALETTE.mine, localName(m) .. "尸体")   -- 例：灰熊尸体 / 花鹿尸体
		end
		-- 活体：跳过已经是尸体的，否则会被刷回原样式
		for _, m in ipairs(collectAnimals()) do
			if not carcassSet[m] then
				-- 打中但还没死：深蓝色标出来（5 分钟内有效）
				local hit = false
				local okId, id = pcall(function() return m:GetAttribute("Id") end)
				if okId and id ~= nil then
					local ts = pendingKills[tostring(id)]
					if ts and (os.clock() - ts) < 300 then hit = true end
				end
				if hit then
					take(m, PALETTE.hit, localName(m) .. "（打中）")
				else
					take(m, colorFor(m), localName(m) .. variantTag(m) .. hotTag(m))
				end
			end
		end
	end

	if CFG.players then
		local me = Players.LocalPlayer
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= me and p.Character then
				take(p.Character, PALETTE.byPlayer, p.Name)
			end
		end
	end

	for model, t in pairs(targets) do
		if not seen[model] then
			pcall(function() t.hl:Destroy() end)
			pcall(function() t.bb:Destroy() end)
			targets[model] = nil
		end
	end
end

-- ============================================================
-- 子弹追踪（P33 / K24）
-- 不 hook 任何 remote：直接替换 ProjectileCaster 实例的 Fire 方法，
-- 把 dir 换成「枪口 -> 目标瞄准点」的单位向量。
-- Fire 每次开枪只调一次，零帧开销，不会拖死后坐力状态机。
-- ============================================================
local bt = {
	caster = nil, origFire = nil, patched = false,
	shots = 0, aimed = 0, lastErr = nil, lastTarget = nil, leadLog = 0,
	dbg = { scanned = 0, noPoint = 0, outRange = 0, best = nil },
	pick = nil,
}

local function findCaster()
	for _, v in ipairs(getgc(true)) do
		if type(v) == "table" then
			local ok, hit = pcall(function()
				return rawget(v, "_activeProjectiles") ~= nil and rawget(v, "MaxDistance") ~= nil
			end)
			if ok and hit then return v end
		end
	end
	return nil
end

-- 动物瞄准点：RootPart + 肺偏移（偏移烘成局部坐标，避免骨骼抖动 K23）
local organCache = setmetatable({}, { __mode = "k" })
local headCache = setmetatable({}, { __mode = "k" })   -- 瞄头时兜底头顶偏移的缓存
-- 物种级的瞄准点纵向微调（单位 studs，负值=往下）。
-- 实测：大体型野猪 / 驼鹿的 RigChest 与两肺中点都落在体高约 63% 处，
-- 而真实致命区偏低一点，打上去弹道会从背上擦过去。
-- 其他物种暂不调整（默认 0），只在实测偏了的这里加。
local SPECIES_AIM_DY = {
	-- 野猪低头吃草时胸腔是全身最高点：实测 RigChest 在体高 63%，
	-- 而它的头只有 54%、下巴 51% —— RigChest 比头还高。
	-- 所以要压得比驼鹿多一倍，压到体高约 55%（真正的胸腔位置）。
	wildboar = -0.40,
	boar = -0.40,
	feralhog = -0.40,
	-- 驼鹿有肺，两肺中点本来就在体高 63%，只需微调
	moose = -0.18,
}

local function animalAimPoint(m)
	local root = m:FindFirstChild("RootPart")
	if not root then return nil end

	-- 瞄头：优先 Eyes 这个 Attachment（骨骼头上），退回 Head 部件，再退回头顶偏移
	if CFG.btrackAimPart == "head" then
		local ey = m:FindFirstChild("Eyes", true)
		if ey then
			if ey:IsA("Attachment") and ey.Parent then
				return root.CFrame * root.CFrame:PointToObjectSpace(ey.WorldPosition)
			elseif ey:IsA("BasePart") then
				return root.CFrame * root.CFrame:PointToObjectSpace(ey.Position)
			end
		end
		-- 非洲草原图（狮子/鬣狗/斑马/角马/豹）用 Rig* 命名，没有 Eyes，眼睛叫 RigLEye1 / RigREye1
		local le = m:FindFirstChild("RigLEye1", true)
		local re = m:FindFirstChild("RigREye1", true)
		if le and le:IsA("Attachment") and le.Parent then
			if re and re:IsA("Attachment") and re.Parent then
				return root.CFrame * root.CFrame:PointToObjectSpace((le.WorldPosition + re.WorldPosition) * 0.5)
			end
			return root.CFrame * root.CFrame:PointToObjectSpace(le.WorldPosition)
		end
		local hd = m:FindFirstChild("Head")
		if hd then
			if hd:IsA("BasePart") then return hd.Position end
			-- 有些物种的 Head 是骨骼 Attachment（如 CanadaGoose 的 Head/Beak）
			if hd:IsA("Attachment") then
				return root.CFrame * root.CFrame:PointToObjectSpace(hd.WorldPosition)
			end
		end
		-- 再退一步：RigHead（鹿/狼/野猪那套 Rig 命名）
		local rh = m:FindFirstChild("RigHead", true)
		if rh and rh:IsA("Attachment") then
			return root.CFrame * root.CFrame:PointToObjectSpace(rh.WorldPosition)
		end
		-- 缓存表 key 只能用 Instance，不能拼字符串（早年踩过 Instance .. string 报错）
		local offH = headCache[m]
		if not offH then
			offH = Vector3.new(0, 1.5, 0)
			headCache[m] = offH
		end
		return root.CFrame * offH
	end

	local off = organCache[m]
	-- 高速移动的目标（飞行的鸟、奔跑中的兽）不信任缓存的局部偏移：
	-- 那个偏移是第一次采样时用 root.CFrame 换算出来的，动画一变姿态
	-- （鸟俯冲、兽低头）真实器官位置就跟着转了，缓存值还停在旧姿态上，
	-- 结果是全程差一点点 —— 地面上慢慢走的动物感觉不出来，飞起来就差很多。
	do
		local r0 = m:FindFirstChild("RootPart")
		local v0 = r0 and r0.AssemblyLinearVelocity
		if v0 and v0.Magnitude > 15 then off = nil end
	end
	if not off then
		local ll = m:FindFirstChild("LeftLung", true)
		local rl = m:FindFirstChild("RightLung", true)
		local p
		if ll and ll:IsA("Attachment") and ll.Parent then
			if rl and rl:IsA("Attachment") and rl.Parent then
				p = (ll.WorldPosition + rl.WorldPosition) * 0.5
			else
				p = ll.WorldPosition
			end
		end
		if not p then
			local ht = m:FindFirstChild("Heart", true)
			if ht and ht:IsA("Attachment") and ht.Parent then p = ht.WorldPosition end
		end
		-- 没有器官模型的小物种：退到胸腔骨骼锚点，比 RootPart 准得多
		-- RigChest/RigSpine* 是鹿/狼/野猪那套命名；Chest/Body 是鸟类的命名（CanadaGoose 实测）
		if not p then
			for _, k in ipairs({ "RigChest", "RigSpine3", "RigSpine2", "RigSpine1", "Chest", "Body" }) do
				local a = m:FindFirstChild(k, true)
				if a and a:IsA("Attachment") then p = a.WorldPosition break end
			end
		end
		off = p and root.CFrame:PointToObjectSpace(p) or Vector3.new(0, 0.3, 0)
		organCache[m] = off
	end
	-- CFrame * Vector3 已经是世界坐标点（Vector3），不能再取 .Position
	local pt = root.CFrame * off
	local dy = SPECIES_AIM_DY[speciesKey(m.Name)]
	if dy then
		-- 只有身体点需要修正；瞄头时那个眼/头骨骼本身就是准的
		pt = pt + Vector3.new(0, dy, 0)
	end
	return pt
end

local function playerAimPoint(m)
	local hrp = m:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position + Vector3.new(0, 1.2, 0) end
	local head = m:FindFirstChild("Head")
	if head then return head.Position end
	return nil
end

local function btAimPoint(m)
	if m:FindFirstChildWhichIsA("Humanoid") then
		return playerAimPoint(m) or animalAimPoint(m)
	end
	return animalAimPoint(m)
end

-- 目标在往哪走：动物读 RootPart，NPC 读 HumanoidRootPart；读不到就返回 nil 表示不预判
-- 目标速度：优先用「实测位移 / 实测时间」算，不用 AssemblyLinearVelocity。
-- 实测（WhiteTailedDeerFemale 奔跑）：
--   位移 4.9 studs / 0.19s → 26.3 studs/s，而 AssemblyLinearVelocity 只报 17.6（差 1.5 倍）
--   位移 2.6 studs / 0.17s → 14.8 studs/s，报告 11.6（差 1.3 倍）
-- 差的原因是 Roblox 的 AssemblyLinearVelocity 是物理步进的平均值，抓不到加速段；
-- 按它算提前量就永远补不够，飞得越快偏得越多。
local velTrack = setmetatable({}, { __mode = "k" })
local function bodyVelocity(model)
	if not model then return nil end
	local root = model:FindFirstChild("RootPart")
	if not root or not root:IsA("BasePart") then
		root = model:FindFirstChild("HumanoidRootPart")
	end
	if not (root and root:IsA("BasePart")) then return nil end

	local now = os.clock()
	local pos = root.Position
	local rec = velTrack[root]
	if rec and (now - rec.t) > 0.015 then
		local v = (pos - rec.p) / (now - rec.t)
		-- 指数平滑，避免单帧抖动
		rec.v = rec.v and rec.v:Lerp(v, 0.45) or v
		rec.t, rec.p = now, pos
		return rec.v
	end
	if not rec then
		local ok, v = pcall(function() return root.AssemblyLinearVelocity end)
		local seed = (ok and typeof(v) == "Vector3") and v or Vector3.zero
		velTrack[root] = { t = now, p = pos, v = seed }
		return seed
	end
	return rec.v or Vector3.zero
end

-- 从已标记的 targets 里挑目标：圈内优先（屏幕像素距离），圈内没有就取世界最近
local function pickBulletTarget(origin)
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local vp = cam.ViewportSize
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	-- 子追的搜索距离直接等于 ESP 的显示距离，不再单独放一个参数。
	-- 两者分开时会出现「锁到屏幕上没有高亮的动物」：ESP 只在 maxDist 内画标记，
	-- 子追按更大的上限选目标，线就指向一个看不见的东西。
	local maxD = CFG.maxDist or 2000
	local bestIn, bestInD, bestAny, bestAnyD
	local dg = bt.dbg
	dg.scanned, dg.noPoint, dg.outRange, dg.best = 0, 0, 0, nil
	for model, t in pairs(targets) do
		dg.scanned = dg.scanned + 1
		-- 只判 model.Parent：t.hl.Parent 在 CoreGui 下会触发
		-- 「cannot access 'Instance' (lacking capability Plugin)」被 pcall 吞掉后整轮失效
		if model.Parent and t.style ~= PALETTE.mine then
			local pt = btAimPoint(model)
			if pt then
				local d = (pt - origin).Magnitude
				if d >= CFG.btrackMinDist and d <= maxD then
					local sp, onScreen = cam:WorldToViewportPoint(pt)
					-- 屏幕外的目标给一个惩罚像素值，而不是 math.huge：
					-- 否则它会被丢进 bestAny 分支去跟"世界最近"比，屏幕上明明有更贴准星的目标也抢不过它
					local pix
					if onScreen and sp.Z > 0 then
						pix = math.sqrt((sp.X - cx) ^ 2 + (sp.Y - cy) ^ 2)
					else
						pix = CFG.btrackFov * 8 + 5000
					end
					if pix <= CFG.btrackFov and (not bestInD or pix < bestInD) then
						bestIn, bestInD = { model = model, point = pt, dist = d, pix = pix }, pix
					end
					if not bestAnyD or d < bestAnyD then
						bestAny, bestAnyD = { model = model, point = pt, dist = d, pix = pix }, d
					end
				else
					dg.outRange = dg.outRange + 1
				end
			else
				dg.noPoint = dg.noPoint + 1
			end
		end
	end
	-- 只认 FOV 圈内（像素距离最小）的那一个。
	-- 不再用 bestAny 兜底：否则世界距离更近、但偏在屏幕角落的目标会抢走锁定，
	-- 表现为"线连到了野处的目标，准星附近明明有个更贴的"。
	local res = bestIn
	dg.best = res and res.model.Name or nil
	return res
end
bt.pick = pickBulletTarget

local function btFireHook(self, origin, dir, speed, ...)
	if not CFG.btrack or not bt.origFire then
		return bt.origFire(self, origin, dir, speed, ...)
	end
	bt.shots = bt.shots + 1
	local ok, res = pcall(pickBulletTarget, origin)
	if ok and res then
		local pt = res.point
		-- 提前量：目标是活的会跑，按"距离 / 子弹速度"算飞行时间，把瞄准点推到它那时候会在的地方
		local lead = CFG.btrackLead or 0
		if lead > 0 and speed and speed > 1 then
			local vel = bodyVelocity(res.model)
			if vel and vel.Magnitude > 0.5 then
				local travel = (pt - origin).Magnitude / speed
				local shift = vel * (travel * lead)
				pt = pt + shift
				-- 前 8 次开枪把实测值打出来，「提前量多了/少了」直接看数字调系数
				if (bt.leadLog or 0) < 8 then
					bt.leadLog = (bt.leadLog or 0) + 1
					print(string.format("[子追提前] %s 距=%dm 弹速=%.0f 飞行=%.3fs 目标速度=%.1f 偏移=%.2f studs (系数 %.2f)",
						res.model.Name, math.floor(res.dist), speed, travel, vel.Magnitude, shift.Magnitude, lead))
				end
			end
		end
		local d = pt - origin
		if d.Magnitude > 0.01 then
			bt.aimed = bt.aimed + 1
			bt.lastTarget = { model = res.model, point = pt, dist = res.dist, pix = res.pix }
			-- 子追开枪只登记「候选」，不直接认尸。
			-- 之前这里同时写了 rememberKill（= myKillModels[model] = true），导致子弹一出膛，
			-- 目标立刻被当成「我的尸体」画上尸体标；而动物其实还活着，
			-- 于是活体标和尸体标叠在同一只动物身上（用户看到的现象）。
			-- markPending 只登记 Id + 时间戳，5 分钟内在 DeadAnimals / AnimalRagdoll 里真出现才算转正。
			if res.model then
				pcall(markPending, res.model)
			end
			return bt.origFire(self, origin, d.Unit, speed, ...)
		end
	elseif not ok then
		bt.lastErr = tostring(res)
	end
	return bt.origFire(self, origin, dir, speed, ...)
end

local function btInstall()
	-- 忍者缺 getgc 就找不到 ProjectileCaster，直接给出明确原因而不是静默失败
	if not CAPS.getgc then
		bt.lastErr = "执行器不支持 getgc，无法定位 ProjectileCaster"
		return false
	end
	if bt.patched then return true end
	local c = findCaster()
	if not c then bt.lastErr = "找不到 ProjectileCaster"; return false end
	-- 必须从 prototype 取原函数：如果重载前实例字段已经被上一次的闭包占住，
	-- 直接 c.Fire 拿到的是旧闭包，会造成无限递归（K25）
	local mt = getmetatable(c)
	local proto = mt and mt.__index and rawget(mt.__index, "Fire")
	bt.caster = c
	bt.origFire = proto or c.Fire
	c.Fire = btFireHook

	-- 重力来自这里：实测 ProjectileUpdated 返回 acc = (0, -35.0357, 0)
	-- 包一层把 Y 分量归零 → 子弹走直线不下坠（水平分量保留，万一有风)
	-- 注意它是**实例字段**，原型上没有，所以直接读写 c.ProjectileUpdated
	if CFG.btrackNoDrop then
		local origPU = rawget(c, "ProjectileUpdated")
		if type(origPU) == "function" then
			bt.origPU = origPU
			-- 备份到 GENV：重载时局部变量会丢，靠这个还能还原游戏原本的下坠
			GENV.__DAWG_ORIG_PU = { caster = c, fn = origPU }
			c.ProjectileUpdated = function(self, proj, dt, ...)
				local ok, acc, damp = pcall(origPU, self, proj, dt, ...)
				if not ok or typeof(acc) ~= "Vector3" then
					return Vector3.new(0, 0, 0), damp
				end
				return Vector3.new(acc.X, 0, acc.Z), damp
			end
		end
	end

	bt.patched = true
	return true
end

local function btUninstall()
	if bt.patched and bt.caster then
		if bt.origFire then pcall(function() bt.caster.Fire = bt.origFire end) end
		if bt.origPU then pcall(function() bt.caster.ProjectileUpdated = bt.origPU end) end
	end
	bt.patched = false
	bt.caster, bt.origFire, bt.origPU = nil, nil, nil
end

local btDraw = { line = nil, text = nil }

-- 目标还活着吗：动物死了会被挪到 DeadAnimals，也可能只是打上 Dead 属性
local function btAlive(m)
	if not m or not m.Parent then return false end
	if m.Parent.Name == "DeadAnimals" then return false end
	if m:GetAttribute("Dead") == true then return false end
	local hum = m:FindFirstChildWhichIsA("Humanoid")
	if hum and hum.Health <= 0 then return false end
	return true
end

local function btRender()
	-- 开关和实际接管状态保持同步：面板/CFG 一改就立刻装或拆，
	-- 不要指望用户去点 UI 那条路径才生效（否则改了 CFG.btrack 看得到线却改不了弹道）
	if CFG.btrack and not bt.patched then pcall(btInstall) end
	if not CFG.btrack and bt.patched then pcall(btUninstall) end

	local show = CFG.btrack and CFG.btrackLine
	local showTxt = CFG.btrack and CFG.btrackText
	local cam = workspace.CurrentCamera
	local hp = Kit.hrp()

	-- 每帧按当前准星重新选，而不是"选一个就一直占着"。
	-- 之前只在 lastTarget 为 nil 时才重选，结果：目标一出圈线就没了、但 lastTarget 还占着坑，
	-- 圈里明明有别的更贴准星的目标也切不过去（表现为"连上之后转视角就再也没线了"）。
	local t = nil
	if hp and CFG.btrack then
		local okPick, picked = pcall(pickBulletTarget, hp.Position)
		if okPick and picked then
			t = picked
			bt.lastTarget = picked
		else
			bt.lastTarget = nil
		end
	end

	local valid = t and cam and btAlive(t.model)
	if not valid then
		if btDraw.line then btDraw.line.Visible = false end
		if btDraw.text then btDraw.text.Visible = false end
		return
	end

	-- 每帧重算瞄准点：目标是活的，会跑会转头，缓存开枪瞬间的点会让线钉在原地
	local okPt, curPt = pcall(btAimPoint, t.model)
	if not okPt or not curPt then
		if btDraw.line then btDraw.line.Visible = false end
		if btDraw.text then btDraw.text.Visible = false end
		return
	end
	local curDist = hp and (curPt - hp.Position).Magnitude or (t.dist or 0)
	local sp, onScreen = cam:WorldToViewportPoint(curPt)
	if sp.Z <= 0 then
		if btDraw.line then btDraw.line.Visible = false end
		if btDraw.text then btDraw.text.Visible = false end
		return
	end

	local vp = cam.ViewportSize
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	-- 连线只在准星圈（btrackFov 像素半径）内显示；出圈就自动收回
	local pix = math.sqrt((sp.X - cx) ^ 2 + (sp.Y - cy) ^ 2)
	local inFov = pix <= CFG.btrackFov

	if not (Drawing and Drawing.new) then return end
	if show and inFov then
		if not btDraw.line then
			btDraw.line = Drawing.new("Line")
			btDraw.line.Thickness = 1
			btDraw.line.Transparency = 0.9
		end
		local l = btDraw.line
		l.From = Vector2.new(cx, cy)
		l.To = Vector2.new(sp.X, sp.Y)
		l.Color = onScreen and CFG.btrackColor or CFG.btrackOffColor
		l.Visible = true
	elseif btDraw.line then
		btDraw.line.Visible = false
	end
	-- 文字跟连线同生同灭：没有线就不该留着上一帧识别到的名字和距离，
	-- 否则目标走出圈/被墙挡住之后，屏幕上还挂着一行「披肩榛鸡 151m」误导人。
	if show and showTxt and inFov then
		-- 不能用 Drawing.new("Text")：实测执行器里 Drawing.Fonts 的四种字体
		-- （UI / System / Plex / Monospace）全都不含中文字形，中文一律渲染成问号。
		-- 改成 ScreenGui 里的 TextLabel —— 跟 BillboardGui 标签同一套字体引擎，中文正常。
		if not btDraw.label or not btDraw.label.Parent then
			local h = uiHolder()
			local sg = h:FindFirstChild("DawgHuntOverlay")
			if not sg then
				sg = Kit.new("ScreenGui", {
					Name = "DawgHuntOverlay",
					ResetOnSpawn = false,
					DisplayOrder = 999,
					IgnoreGuiInset = true,
				}, h)
			end
			local old = sg:FindFirstChild("BtTargetText")
			if old then old:Destroy() end
			btDraw.label = Kit.new("TextLabel", {
				Name = "BtTargetText",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0.5, 42),
				Size = UDim2.new(0, 460, 0, 22),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextStrokeTransparency = 0.4,
				TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
				Text = "",
			}, sg)
		end
		local lb = btDraw.label
		if lb then
			lb.Text = string.format("%s  %.0fm", localName(t.model), curDist)
			lb.TextColor3 = onScreen and CFG.btrackColor or CFG.btrackOffColor
			lb.Visible = true
		end
	elseif btDraw.label and btDraw.label.Parent then
		btDraw.label.Visible = false
	end
end

-- 默认不接管：只有 CFG.btrack 为 true 时才替换 caster.Fire
if CFG.btrack then pcall(btInstall) end
bt._targetsRef = targets
bt._cfgRef = CFG
bt._aimPoint = btAimPoint
bt.velocity = bodyVelocity
GENV.__DAWG_BTRACK = bt
-- 暴露绘制对象，方便诊断「线到底有没有画」（btDraw 是局部的，外部看不到）
bt.Draw = btDraw

local function tickDist()
	local hrp = Kit.hrp()	if not hrp then return end
	local origin = hrp.Position
	for model, t in pairs(targets) do
		local part = model.PrimaryPart
		if part then
			local d = (part.Position - origin).Magnitude
			-- 被连线锁定的那只也照常显示三行，不做特殊处理
			-- （用户明确要求：连上线之后不要去掉分数和距离）
			do
				local lines = {}
				if t.scoreLine and t.scoreLine ~= "" then lines[#lines + 1] = t.scoreLine end
				lines[#lines + 1] = t.tag
				local tail = (t.sub and t.sub ~= "") and (t.sub .. "  ") or ""
				lines[#lines + 1] = tail .. string.format("%d格", math.floor(d + 0.5))
				t.label.Text = table.concat(lines, "\n")
				t.bb.Size = UDim2.fromOffset(t.bb.Size.X.Offset, #lines * 18 + 8)
				t.bb.Enabled = d <= CFG.maxDist
			end
		end
	end
end

---------------------------------------------------------------- 瞄准辅助
-- 只改相机朝向，不碰角色 CFrame（改角色会被服务端拉回，K08）
local aim = {
	-- 默认关，但记住上一次的选择：面板是复用的旧 Fluent 窗口，开关看着还是「开」，
	-- 而 CFG 已经回到 false —— 表现就是「一重载吸附就失效」，跟子追 btrack 同一个坑。
	enabled = (type(getgenv().__DAWG_AIM_LAST) == "boolean") and getgenv().__DAWG_AIM_LAST or false,
	holdOnly = true,     -- 默认按住右键才生效，平时不抢视角
	strength = 0.55,     -- 每帧插值系数（60fps 基准）
	range = 1200,
	ringRadius = 120,    -- 准星圈半径（屏幕像素）：圈内才锁，开镜不变
	ringVisible = true,  -- 显示准星圈（用户明确要留着，别动）
	height = 0.6,        -- 兜底抬高（studs），量不出模型高度时才用
	heightRatio = 0.55,  -- 目标点占模型高度的比例（0.5 = 躯干中线），不同体型自适应
	follow = 0.92,       -- 目标点平滑力度（跑动时不落队）
	leadTime = 0.14,     -- 预判提前量（秒，满速上限）：慢跑几乎不提前，狂奔补足
	mode = "mouse",      -- mouse = 推真实鼠标，让游戏相机自己转（唯一视角同步的方案）
	                     -- prerender 只写 Camera.CFrame，游戏内部角度不变 → 松手必跳回，已废弃
	blend = 0.92,        -- 吸附强度：越高越跟手（0.85 跑动时会落后）
	gain = 1.00,         -- 每帧抵消 100% 的角度误差：玩家手动划的位移会被完全拉回来，准星锁死
	degPerPixel = 0.05,  -- 灵敏度换算（0.05 × 14 = 0.7 度/帧封顶 ≈ 42 度/秒）
	maxPixels = 14,      -- 单帧最多推多少像素
	accumX = 0,          -- 亚像素累积余量（凑够 1 像素再推，见 mouse 分支）
	accumY = 0,
	minDist = 15,        -- 比这更近的不锁（防止锁到脚下的宠物/队友）
	headSync = true,     -- 开火时把头部方向对到目标（⚠ 高频会锁伤害/测距，K88，锁了只能重进）
	synced = 0,          -- 已同步次数（面板/调试用）
	target = nil,
	smooth = nil,
}

---------------------------------------------------------------- 开火同步（这局的关键机制）
-- 实测：准星跟 UpdateHeadDirection 走，相机只影响画面。
-- 做法：只在「扣着扳机 + 有目标」时，以 10Hz（游戏原生同频）把头部方向对到目标。
-- 60Hz 猛刷会被服务端判定异常并锁伤害（只能重进），10Hz 只在你开火时发是安全的。
local UHD = (function()
	local rs = game:GetService("ReplicatedStorage"):FindFirstChild("ReservesCommon")
	local rm = rs and rs:FindFirstChild("Remotes")
	return rm and rm:FindFirstChild("UpdateHeadDirection")
end)()

local headConn, headAcc = nil, 0
if UHD then
	headConn = RunService.Heartbeat:Connect(function(dt)
		if not (aim.enabled and aim.headSync) then return end
		-- 条件从「按住左键开火」改成「吸附正在生效（按住右键）」：
		-- 这游戏的命中判定走头部方向（UpdateHeadDirection），不是相机。
		-- 只转相机不转角色 = 画面指着目标、子弹照旧方向飞。所以吸附一激活就让角色跟着转。
		if not aim.active then return end
		local t = aim.target
		if not t or not t.PrimaryPart then return end
		headAcc = headAcc + dt
		if headAcc < 0.2 then return end   -- 5Hz 上限（10Hz 也可能被判异常）
		headAcc = 0
		local hrp = Kit.hrp()
		if not hrp then return end
		local head = (hrp.Parent and hrp.Parent:FindFirstChild("Head")) or hrp
		local dir = (t.PrimaryPart.Position - head.Position).Unit
		pcall(function() UHD:FireServer(dir) end)
		markPending(t)           -- 只登记候选，等尸体真的出现才转正（直接 rememberKill 会把打不死的也标绿）
		aim.synced = (aim.synced or 0) + 1
	end)
else
	Kit.log("没找到 UpdateHeadDirection，开火同步不可用")
end

-- 鼠标最近一次移动的时间（transformCam 里要用它做让步，必须在这里先声明）
local lastMouseMove = 0
UIS.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local d = input.Delta
		if math.abs(d.X) + math.abs(d.Y) > 0.5 then lastMouseMove = os.clock() end
	end
end)

---------------------------------------------------------------- 相机接管（PreRender 写，不碰元表）
-- 教训：hookmetamethod 改实例 __newindex，若执行器不返回原方法，会吞掉所有属性写入
--（K87）。改成在 PreRender（渲染前最后一刻）写 Camera.CFrame，安全、可撤销。
local camConn = nil

local function transformCam(cam)
	if not (aim.enabled and aim.active and aim.smooth) then return end
	local pos = cam.CFrame.Position
	local delta = aim.smooth - pos
	if delta.Magnitude < 2 then return end
	local dir = delta.Unit
	local up = cam.CFrame.UpVector
	if math.abs(dir.Y) > 0.99 then up = cam.CFrame.RightVector end
	local goal = CFrame.lookAt(pos, pos + dir, up)
	-- 每帧插值比例用 strength（速度），不是 blend（目标强度）。
	-- 用 blend=0.92 的话一帧就贴死了，玩家根本来不及反应，也看不出在跟；
	-- strength=0.55 大约 3~4 帧到位，眼睛能看到「被吸过去」的过程。
	local b = math.clamp(aim.strength * dt * 60, 0, 1)
	-- 开镜时（FOV 收窄）必须几乎瞬移到位，否则高倍镜下每帧都在飘
	if cam.FieldOfView <= 55 then b = math.max(b, 0.97) end
	cam.CFrame = cam.CFrame:Lerp(goal, b)
end

camConn = RunService.PreRender:Connect(function(dt)
	if aim.mode == "prerender" then
		local ok, err = pcall(transformCam, workspace.CurrentCamera)
		if not ok then Kit.lastError = tostring(err) end
	end
end)

-- 尸体不进瞄准候选（只保留 ESP 显示）：死的不动，吸它没意义还抢目标
local function isCarcass(m)
	local par = m.Parent
	if par and par.Name == "DeadAnimals" then return true end
	if CollectionService:HasTag(m, "AnimalRagdoll") then return true end
	local ok, settled = pcall(function() return m:GetAttribute("RagdollSettled") end)
	return ok and settled == true
end

local function pickAimTarget()
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local camPos = cam.CFrame.Position
	local vp = cam.ViewportSize
	local cx, cy = vp.X / 2, vp.Y / 2
	-- 锁定半径必须和画出来的圈一致，否则会出现「圈只有 120px、判定却是 300px」
	-- 这种看着明显不对的情况（反过来也一样）。
	local radius = aim.ringRadius
	local best, bestScore = nil, -math.huge
	for model in pairs(targets) do
		local part = model.PrimaryPart
		if part and part.Parent and not isPet(model) and not isCarcass(model) then
			local delta = part.Position - camPos
			local d = delta.Magnitude
			if d > aim.minDist and d <= aim.range then
				-- 投影到屏幕：圈是屏幕上的固定区域，开镜不会跟着放大
				local sp, onScreen = cam:WorldToViewportPoint(part.Position)
				if onScreen then
					local dx, dy = sp.X - cx, sp.Y - cy
					local dist = math.sqrt(dx * dx + dy * dy)
					if dist <= radius then
						local score = 1 - dist / radius -- 越靠中心越高，距离不参与
						if score > bestScore then
							best, bestScore = model, score
						end
					end
				end
			end
		end
	end
	return best
end

-- 按模型实际高度算瞄准点：蓝角马这类大体型，固定 +0.6 会落在脚上
local aimPointCache = setmetatable({}, { __mode = "k" })

local function aimPointOf(m)
	local p = m.PrimaryPart
	if not p then return nil end
	local cached = aimPointCache[m]
	if not cached then
		local top, bottom, n = -math.huge, math.huge, 0
		for _, c in ipairs(m:GetDescendants()) do
			if c:IsA("BasePart") and c.Transparency < 0.9 then
				local y = c.Position.Y
				top = math.max(top, y + c.Size.Y * 0.5)
				bottom = math.min(bottom, y - c.Size.Y * 0.5)
				n = n + 1
			end
		end
		if n > 0 and top > bottom then
			-- 存「相对根部件的偏移」而不是绝对 Y：动物上下坡后绝对高度会失效
			cached = {
				offY = (bottom + (top - bottom) * aim.heightRatio) - p.Position.Y,
				ratio = aim.heightRatio,
			}
			aimPointCache[m] = cached
		end
	end
	if cached then
		-- 比例被调整过就重算（缓存失效）
		if cached.ratio ~= aim.heightRatio then
			aimPointCache[m] = nil
			aimPointCache[m] = nil
			return aimPointOf(m)
		end
		return Vector3.new(p.Position.X, p.Position.Y + cached.offY, p.Position.Z)
	end
	return p.Position + Vector3.new(0, aim.height, 0)
end

local function aimStep(dt)
	if not aim.enabled then return end
	if aim.holdOnly and not UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		aim.target, aim.smooth, aim.active = nil, nil, false
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local pos = cam.CFrame.Position

	-- 粘滞：已锁定的只要还在范围内就不换，避免两只之间来回甩
	local function alive(m)
		if not m or not m.Parent then return false end
		local p = m.PrimaryPart
		return p ~= nil and (p.Position - pos).Magnitude <= aim.range
	end
	local t = aim.target
	if not alive(t) then
		t = pickAimTarget()
		aim.target = t
		aim.smooth = nil
	end
	if not t then return end
	local part = t.PrimaryPart
	if not part then return end

	-- 目标点抬高到躯干 + 平滑跟随
	local want = aimPointOf(t) or (part.Position + Vector3.new(0, aim.height, 0))
	-- 预判：只对「真的在跑」的目标加提前量。
	-- 之前不管速度快慢都乘固定 0.16 秒，慢走的动物也被甩到前面去（用户反馈"提前太多"）。
	local vel = part.AssemblyLinearVelocity
	if vel then
		local hv = Vector3.new(vel.X, 0, vel.Z)
		local speed = hv.Magnitude
		if speed > 0.1 then
			-- 提前距离按速度拟合（用户实测标定）：
			--   5 格/秒 → 0.4 格；10 格/秒 → 1.0 格；25 格/秒 → 3.5 格
			-- 曲线：lead = 0.06·v + 0.0032·v²（低速近似线性，高速加速补偿）
			local lead = 0.06 * speed + 0.0032 * speed * speed
			want = want + hv.Unit * lead
		end
	end
	if not aim.smooth then aim.smooth = want end
	aim.smooth = aim.smooth:Lerp(want, math.clamp(aim.follow * dt * 60, 0, 1))

	local delta = aim.smooth - pos
	if delta.Magnitude < 1 then return end
	local dir = delta.Unit
	local cur = cam.CFrame

	-- 不留微调区：只挡 0.02 度以内的浮点抖动，其余一律往目标拉
	local ang = math.deg(math.acos(math.clamp(cur.LookVector:Dot(dir), -1, 1)))
	if ang < 0.02 then return end

	-- 用当前 UpVector 构造，roll 不会被重置（之前 lookAt 默认 up 才是抖的根因）
	if aim.mode == "prerender" then return end
	if aim.mode == "mouse" then
		-- 推鼠标：游戏自己的相机去转，天然平滑，不会有「写一帧被覆盖一帧」的闪烁
		local cYaw2, cPitch2 = math.atan2(-cur.LookVector.X, -cur.LookVector.Z), math.asin(math.clamp(cur.LookVector.Y, -1, 1))
		local tYaw2, tPitch2 = math.atan2(-dir.X, -dir.Z), math.asin(math.clamp(dir.Y, -1, 1))
		local dyaw = (tYaw2 - cYaw2) % (2 * math.pi)
		if dyaw > math.pi then dyaw = dyaw - 2 * math.pi end
		local dpitch = tPitch2 - cPitch2
		local px = math.clamp(-math.deg(dyaw) * aim.gain / aim.degPerPixel, -aim.maxPixels, aim.maxPixels)
		local py = math.clamp(-math.deg(dpitch) * aim.gain / aim.degPerPixel, -aim.maxPixels, aim.maxPixels)
		-- 误差不足 0.5 像素才停手（原来是 1.0）：mousemoverel 的最小单位是 1 像素，
		-- 阈值定太高会留下一圈「准星能自己挪」的死区 —— 用户要的是锁死、拉不动，
		-- 宁可有一像素级的微跳也不能让它自由活动。
		if math.abs(px) < 0.5 and math.abs(py) < 0.5 then
			return
		end
		pcall(mousemoverel, math.floor(px), math.floor(py))
		return
	end

	-- 相机写入统一交给 transformCam（PreRender）。这里只负责标记吸附已激活，
	-- 绝不在这里也写一次 —— 两处都插值等于每帧转两次，划屏时会转一倍多（用户反馈「划过头」）。
	aim.active = true
end

RunService:BindToRenderStep("DawgAimAssist", Enum.RenderPriority.Camera.Value + 100, function(dt)
	local ok, err = pcall(aimStep, dt)
	if not ok then Kit.lastError = tostring(err) end
end)

local ring, updateRing
local connSync, connDist
local accSync, accDist = 0, 0
local reported = false

-- 世代号：重载时旧实例的连接拿不到（脚本上下文已清，局部变量全丢），
-- 所以用一个全局计数让旧的自己退休 —— 新实例加载即 +1，旧回调发现代数不符就自行断开。
-- 这样不需要在加载路径上销毁任何东西，做到「新加载直接覆盖」。
GENV.__DAWG_GEN = (tonumber(GENV.__DAWG_GEN) or 0) + 1
local MY_GEN = GENV.__DAWG_GEN

connSync = RunService.Heartbeat:Connect(function(dt)
	if GENV.__DAWG_GEN ~= MY_GEN then
		pcall(function() connSync:Disconnect() end)
		connSync = nil
		if headConn then pcall(function() headConn:Disconnect() end) headConn = nil end
		return
	end
	accSync = accSync + dt
	if accSync >= CFG.refresh then
		accSync = 0
		local ok, err = pcall(sync)
		if not ok then Kit.lastError = tostring(err) end
	end
	if updateRing then pcall(updateRing) end
	pcall(btRender)
	accDist = accDist + dt
	if accDist >= CFG.distEvery then
		accDist = 0
		local ok, err = pcall(tickDist)
		if not ok then
			Kit.lastError = tostring(err)
			if not reported then reported = true; warn("[狩猎ESP] tickDist 出错:", tostring(err)) end
		end
	end
end)

-- 覆盖层：准星圈 + 中心点独立挂，不跟着面板走（面板换 WindUI 也不会丢）
-- 同样复用：重载时上一轮建的 ScreenGui 还在场景里，新建一个就会变成两个叠着
local overlay = holder:FindFirstChild("DawgHuntOverlay")
if not overlay or not overlay:IsA("ScreenGui") then
	overlay = Kit.new("ScreenGui", {
		Name = "DawgHuntOverlay", ResetOnSpawn = false, IgnoreGuiInset = true,
		DisplayOrder = 1e6,
	}, holder)
end

-- 面板：WindUI 优先（PLAYBOOK 5.5 约定），失败回退 Kit 极简面板
local ui, win, statusPara, stat, aimLabel, uiKeyConn

local function buildFluent()
	if GENV.__DAWG_NO_UI then return true end   -- 排查用：完全跳过面板
	local Fluent = (Kit.fluent and Kit.fluent()) or GENV.__FLUENT
	if not Fluent then return false end
	GENV.__FLUENT = Fluent

	-- Fluent 单窗口：已有就**原样复用**。
	-- 千万不要清空 TabHolder/ContainerHolder —— 那会让所有 Tab 的内容叠在同一位置（实测过）
	local w = GENV.__FLUENT_WIN
	-- 必须确认根节点还挂在场景里：复用一个已被销毁的窗口，面板就等于不存在（K31 的兄弟坑）
	if w and w.Root and w.Root.Parent then
		win = w
		return true
	end
	GENV.__FLUENT_WIN = nil
	if not w then
		local okW, made = pcall(function()
			return Fluent:CreateWindow({
				Title = "狩猎 ESP",
				SubTitle = "DawgKit",
				TabWidth = 160,
				Size = UDim2.fromOffset(520, 260),   -- 内容实测 155px，压矮不留空白
				Acrylic = false,   -- 亚克力会生成全屏模糊层，会干扰输入（测距/射击归零）
				Theme = "Dark",
				MinimizeKey = Enum.KeyCode.RightShift,
			})
		end)
		if okW then w = made end
	end
	if not w then return false end
	win = w
	GENV.__FLUENT_WIN = w

	-- 关键：Fluent 默认把窗口放在屏幕中央偏右，会盖住准星 →
	-- 鼠标点击被面板吃掉，游戏收不到射击/测距输入，表现就是「打不出伤害、测距 0」。
	-- 实测点 X 关掉面板立刻恢复。所以固定挪到右上角让开准星。
	-- 用纯 Offset 定位，绝对不要用 Scale=1。
	-- 原因：Fluent 内部会把窗口 Position 规范化成 offset 模式（拖动时直接写 UDim2.fromOffset），
	-- 一旦在父容器布局完成前发生规范化，Scale=1 会被解释成 0 → 绝对 X 从 -620 起步，
	-- 拖一下再减几十像素就成 -724，整个窗口 X 落在 [-724, -204]，全在屏幕左边界外，
	-- 表现就是用户说的「一拖动面板就消失」（实测 Root.Visible 仍是 true，只是跑出屏幕了）。
	pcall(function()
		if not w.Root then return end
		local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
		local wpx = 520
		local x = math.max(8, vp.X - wpx - 24)
		w.Root.Position = UDim2.fromOffset(x, 24)
		if w.CurrentPos ~= nil then w.CurrentPos = x end
	end)

	local okBuild = pcall(function()
		local t1 = w:AddTab({ Title = "目标", Icon = "target" })
		local s1 = t1:AddSection("显示")
		s1:AddToggle("animals", { Title = "动物", Default = CFG.animals, Callback = function(v) CFG.animals = v; sync(); tickDist() end })
		s1:AddToggle("players", { Title = "玩家", Default = CFG.players, Callback = function(v) CFG.players = v; sync(); tickDist() end })
		s1:AddSlider("maxDist", { Title = "最远距离", Default = CFG.maxDist, Min = 200, Max = 3000, Rounding = 0,
			Callback = function(v) CFG.maxDist = v; for _, t in pairs(targets) do t.bb.MaxDistance = v end end })

		local t2 = w:AddTab({ Title = "瞄准", Icon = "crosshair" })
		local s2 = t2:AddSection("吸附")
		s2:AddToggle("aimOn", { Title = "启用", Default = aim.enabled, Callback = function(v)
			aim.enabled = v
			getgenv().__DAWG_AIM_LAST = v
			if not v then aim.target, aim.smooth, aim.active = nil, nil, false end
		end })
		s2:AddToggle("ringOn", { Title = "显示准星圈", Default = aim.ringVisible, Callback = function(v) aim.ringVisible = v end })
		s2:AddSlider("ringSize", { Title = "准星圈大小", Default = CFG.btrackFov, Min = 60, Max = 600, Rounding = 0,
			Callback = function(v) CFG.btrackFov = tonumber(v) or 300 end })
		s2:AddSlider("aimRange", { Title = "锁定距离", Default = aim.range, Min = 200, Max = 3000, Rounding = 0,
			Callback = function(v) aim.range = v end })
		-- Fluent 1.1.0 的 Slider 会把小数默认值截成 0，所以用整数百分比映射
		s2:AddSlider("aimBlend", { Title = "吸附强度(%)", Default = math.floor(aim.blend * 100 + 0.5),
			Min = 30, Max = 100, Rounding = 1,
			Callback = function(v) aim.blend = math.clamp((tonumber(v) or 85) / 100, 0.3, 1) end })

		local sb1 = t2:AddSection("子弹追踪")
		sb1:AddToggle("btOn", { Title = "启用子追", Default = CFG.btrack, Callback = function(v)
			CFG.btrack = v
			getgenv().__DAWG_BTRACK_LAST = v
			if v then
				local okI = btInstall()
				if not okI then warn("[狩猎ESP] 子追安装失败: " .. tostring(bt.lastErr)) end
			else
				btUninstall()
				bt.lastTarget = nil
			end
		end })
		sb1:AddSlider("btFov", { Title = "圈内优先半径", Default = CFG.btrackFov, Min = 100, Max = 1200, Rounding = 0,
			Callback = function(v) CFG.btrackFov = tonumber(v) or 600 end })
		sb1:AddToggle("btLine", { Title = "显示锁定线", Default = CFG.btrackLine, Callback = function(v) CFG.btrackLine = v end })
		sb1:AddToggle("btHead", { Title = "瞄准头部（关=身体）", Default = (CFG.btrackAimPart == "head"),
			Callback = function(v) CFG.btrackAimPart = v and "head" or "body" end })
		sb1:AddToggle("btText", { Title = "显示目标文字", Default = CFG.btrackText, Callback = function(v) CFG.btrackText = v end })

		local t3 = w:AddTab({ Title = "操作", Icon = "wrench" })
		local s3 = t3:AddSection("快捷")
		s3:AddButton({ Title = "立即刷新", Callback = function() sync(); tickDist() end })
		s3:AddButton({ Title = "重扫目标源", Callback = function() sync(); tickDist() end })
		s3:AddButton({ Title = "全部清掉", Callback = function() GENV.__DAWG_HUNT_ESP.destroy() end })
		statusPara = s3:AddParagraph({ Title = "状态", Content = "就绪" })
		GENV.__DAWG_STATUS_PARA = statusPara
	end)
	if not okBuild then return false end

		return true
end

-- 面板：加载时直接建（回到缩小面板前的行为）
if not GENV.__DAWG_NO_UI then
	if not (CFG.useFluent and buildFluent()) then
		ui = Kit.ui({ title = "狩猎 ESP", width = 232 })
		ui:section("目标")
		ui:toggle("动物", CFG.animals, function(v) CFG.animals = v; sync() end)
		ui:toggle("玩家", CFG.players, function(v) CFG.players = v; sync() end)
		ui:stepper("最远距离", 200, 3000, 100, CFG.maxDist, function(v)
			CFG.maxDist = v
			for _, t in pairs(targets) do t.bb.MaxDistance = v end
		end)
		ui:section("瞄准辅助")
		ui:toggle("启用", aim.enabled, function(v)
			aim.enabled = v
			getgenv().__DAWG_AIM_LAST = v
			if not v then aim.target, aim.smooth, aim.active = nil, nil, false end
		end)
		ui:toggle("显示准星圈", true, function(v) aim.ringVisible = v end)
		ui:stepper("准星圈大小", 60, 600, 10, CFG.btrackFov, function(v) CFG.btrackFov = v end)
		ui:stepper("锁定距离", 200, 3000, 100, aim.range, function(v) aim.range = v end)
		ui:stepper("吸附强度", 0.3, 1, 0.05, aim.blend, function(v) aim.blend = v end)
		ui:section("子弹追踪")
		ui:toggle("启用子追", CFG.btrack, function(v)
			CFG.btrack = v
			getgenv().__DAWG_BTRACK_LAST = v
			if v then
				local ok = btInstall()
				if not ok then warn("[狩猎ESP] 子追安装失败: " .. tostring(bt.lastErr)) end
			else
				btUninstall()
				bt.lastTarget = nil
			end
		end)
		ui:stepper("圈内优先半径", 100, 1200, 50, CFG.btrackFov, function(v) CFG.btrackFov = v end)
		ui:toggle("显示锁定线", CFG.btrackLine, function(v) CFG.btrackLine = v end)
		ui:toggle("瞄准头部（关=身体）", CFG.btrackAimPart == "head", function(v)
			CFG.btrackAimPart = v and "head" or "body"
		end)
		ui:toggle("显示目标文字", CFG.btrackText, function(v) CFG.btrackText = v end)
		ui:button(bt.patched and "子追状态：Caster 已接管" or ("子追未接管: " .. tostring(bt.lastErr or "无")), function()
			print(string.format("[狩猎ESP] 子追: patched=%s 开枪=%d 已瞄准=%d 最后=%s 错误=%s",
				tostring(bt.patched), bt.shots, bt.aimed,
				bt.lastTarget and (localName(bt.lastTarget.model) .. string.format(" %.0fm", bt.lastTarget.dist)) or "无",
				tostring(bt.lastErr)))
		end)
		ui:section("操作")
		ui:button("全部清掉", function() GENV.__DAWG_HUNT_ESP.destroy() end)
	end
end

-- 准星圈：把锁定范围画出来，看得见「圈内才锁」
ring = Kit.new("Frame", {
	Name = "FovRing",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Active = false,
	ZIndex = 5,
}, overlay)
Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
Kit.new("UIStroke", {
	Color = Color3.fromRGB(255, 230, 120), Thickness = 1, Transparency = 0.5,
}, ring)

-- 屏幕中心准星圆点
local aimDot = Kit.new("Frame", {
	Name = "AimDot",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(5, 5),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Active = false,
	ZIndex = 7,
}, overlay)
Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }, aimDot)
Kit.new("UIStroke", {
	Color = Color3.fromRGB(0, 0, 0), Thickness = 1, Transparency = 0.35,
}, aimDot)

updateRing = function()
	local cam = workspace.CurrentCamera
	if not (cam and ring.Parent) then return end
	-- FOV 圈独立显示，不再跟吸附联动：吸附关着也要能看到圈
	ring.Visible = aim.ringVisible
	if aimDot then aimDot.Visible = aim.ringVisible end
	if not ring.Visible then return end
	-- 圈的半径必须等于吸附判定用的 aim.ringRadius，否则会出现
	-- 「画出来 300px、实际只在 120px 内锁」这种看着明显不对的情况
	local r = aim.ringRadius
	ring.Size = UDim2.fromOffset(math.floor(r * 2), math.floor(r * 2))
end

sync()
tickDist()

local function destroy()
	pcall(btUninstall)
	btDraw.line, btDraw.text = nil, nil
	bt.lastTarget = nil
	if Drawing and Drawing.clear then pcall(function() Drawing.clear() end) end
	if connSync then connSync:Disconnect() connSync = nil end
	pcall(function() RunService:UnbindFromRenderStep("DawgAimAssist") end)
	if camConn then camConn:Disconnect() camConn = nil end
	if headConn then headConn:Disconnect() headConn = nil end
	GENV.__DAWG_SETTLE_STOP = true
	if fireConn then fireConn:Disconnect() fireConn = nil end
	if uiKeyConn then uiKeyConn:Disconnect() uiKeyConn = nil end
	-- 逐个销毁本实例建出来的高亮/标签，别只清表（否则重载累积，14 个高亮压 7 只动物）
	for _, t in pairs(targets) do
		if t.hl then pcall(function() t.hl:Destroy() end) end
		if t.bb then pcall(function() t.bb:Destroy() end) end
	end
	-- K108：WindUI 的 Destroy 有 bug，调了窗口就坏；只隐藏，下次重载复用
	if win then
		pcall(function()
			local folder = WindUI and WindUI.ScreenGui and WindUI.ScreenGui:FindFirstChild("Window")
			if folder then
				for _, c in ipairs(folder:GetChildren()) do
					if c:IsA("Frame") and c.AbsoluteSize.X > 300 then c.Visible = false end
				end
			end
		end)
	end
	-- 不调 Window:Destroy（Fluent 会锁死，只能重进）；收起来就够了
	if win then pcall(function() if win.Minimize then win:Minimize() end end) end
	if ui then pcall(function() ui:destroy() end) end
	pcall(function() overlay:Destroy() end)
	pcall(function() folder:Destroy() end)
	targets = {}
	-- 兜底：扫掉任何漏网的（上一次 reload 留下的容器/高亮/标签），否则越叠越多
	pcall(function()
		local cg = game:GetService("CoreGui")
		for _, c in ipairs(cg:GetChildren()) do
			if c.Name == "DawgHuntESP" or c.Name == "DawgKit_UI" then pcall(function() c:Destroy() end) end
		end
		local cam = workspace.CurrentCamera
		if cam then
			for _, c in ipairs(cam:GetChildren()) do
				if c.Name == "DawgHuntESP" or c.Name == "DawgAnimalESP" then pcall(function() c:Destroy() end) end
			end
		end
		for _, d in ipairs(game:GetDescendants()) do
			if d:IsA("Highlight") and d:GetFullName():find("DawgHuntESP", 1, true) then
				pcall(function() d:Destroy() end)
			end
			if d:IsA("BillboardGui") and d:GetFullName():find("DawgHuntESP", 1, true) then
				pcall(function() d:Destroy() end)
			end
		end
	end)
	GENV.__DAWG_FIRE_DIAG = nil
	print("[狩猎ESP] 已卸载")
end

GENV.__DAWG_HUNT_ESP = {
	destroy = destroy,
	cfg = CFG,
	aim = aim,
	sync = sync,
	count = function() local n = 0; for _ in pairs(targets) do n = n + 1 end; return n end,
	kills = myKills,
	refresh = function() sync() tickDist() end,
	rememberKill = rememberKill,
}

-- 统计刷到面板
task.spawn(function()
	while connSync do
		local cnt = GENV.__DAWG_HUNT_ESP.count()
		if stat then stat.Text = string.format("目标：%d 只（动物 %s）", cnt, tostring(CFG.animals)) end
		local t = aim.target
		if aimLabel then aimLabel.Text = "锁定：" .. (t and t.Name or "—") end
		if statusPara then pcall(function()
			statusPara:SetDesc(string.format("目标 %d 只 · 锁定 %s", cnt, t and t.Name or "—"))
		end) end
		task.wait(1)
	end
end)

-- ============ 悬浮按钮（忍者/移动端用） ============
-- 面板默认收起，点悬浮球展开。按钮可拖动，位置记在 GENV 里，重载后还在原处。
local floatBtn, floatGui
do
	local function panelRoot()
		-- Fluent 走 Window.Root；回退面板走 ui 自己的容器
		local w = GENV.__FLUENT_WIN
		if w and w.Root and w.Root.Parent then return w.Root end
		if ui and type(ui) == "table" then
			for _, k in ipairs({ "Root", "Frame", "Main", "Gui" }) do
				local v = ui[k]
				if typeof(v) == "Instance" and (v:IsA("GuiObject") or v:IsA("ScreenGui")) then return v end
			end
		end
		return nil
	end

	local function setPanel(on)
		local r = panelRoot()
		if not r then return false end
		if r:IsA("GuiObject") then
			r.Visible = on
		elseif r:IsA("ScreenGui") then
			r.Enabled = on
		end
		GENV.__NINJA_PANEL_OPEN = on
		return true
	end
	GENV.__NINJA_SET_PANEL = setPanel
	GENV.__NINJA_TOGGLE_PANEL = function()
		return setPanel(not (GENV.__NINJA_PANEL_OPEN == true))
	end

	-- 默认收起：整份脚本加载后面板不占屏，只留一个球
	task.defer(function()
		task.wait(0.35)
		setPanel(false)
	end)

	local holder = uiHolder()
	floatGui = holder:FindFirstChild("DawgHuntFloat")
	if not floatGui then
		floatGui = Kit.new("ScreenGui", {
			Name = "DawgHuntFloat",
			ResetOnSpawn = false,
			DisplayOrder = 10000,
			IgnoreGuiInset = true,
		}, holder)
	end
	local saved = GENV.__NINJA_BTN_POS
	floatBtn = floatGui:FindFirstChild("Toggle")
	if not floatBtn then
		floatBtn = Kit.new("TextButton", {
			Name = "Toggle",
			Size = UDim2.fromOffset(56, 56),
			Position = (type(saved) == "UDim2") and saved or UDim2.new(1, -76, 1, -136),
			AnchorPoint = Vector2.new(0, 0),
			BackgroundColor3 = Color3.fromRGB(28, 30, 38),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Text = "🐾",
			TextSize = 26,
			Font = Enum.Font.GothamBold,
			TextColor3 = Color3.fromRGB(120, 255, 190),
			AutoButtonColor = false,
		}, floatGui)
		pcall(function()
			local c = Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }, floatBtn)
			local s2 = Kit.new("UIStroke", {
				Color = Color3.fromRGB(120, 255, 190),
				Thickness = 1.5,
				Transparency = 0.35,
			}, floatBtn)
		end)
	end

	-- 拖动 + 点击（位移小于 6px 视为点击）
	local dragging, dragStart, startPos, moved = false, nil, nil, 0
	floatBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			moved = 0
			dragStart = input.Position
			startPos = floatBtn.Position
		end
	end)
	floatBtn.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - dragStart
			moved = math.max(moved, math.abs(d.X) + math.abs(d.Y))
			floatBtn.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	floatBtn.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if not dragging then return end
		dragging = false
		GENV.__NINJA_BTN_POS = floatBtn.Position
		if moved < 6 then
			GENV.__NINJA_TOGGLE_PANEL()
		end
	end)
end

local animalCount = (function()
	local a = workspace:FindFirstChild("Animals")
	return a and #a:GetChildren() or 0
end)()
print(string.format("[狩猎ESP] 就绪 · 当前目标 %d 个 · Animals=%d", GENV.__DAWG_HUNT_ESP.count(), animalCount))
return GENV.__DAWG_HUNT_ESP
