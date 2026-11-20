-- 秒杀爆发监控（常驻后台，抓到就写文件）
-- 用法：loadstring(readfile("dawg/kill_burst_monitor.lua"))()
-- 日志：kill_burst_log.txt

local Players = game:GetService("Players")
local t0 = os.clock()
local watched = {}
local recent = {}        -- 最近 5 秒内的死亡
local reported = {}      -- 已上报的爆发时间点

local LOG = "kill_burst_log.txt"

local function writeLog(line)
	local ok, old = pcall(function() return readfile(LOG) end)
	local content = (ok and old or "") .. os.date("%H:%M:%S ") .. line .. "\n"
	pcall(writefile, LOG, content)
end

local function posOf(p)
	local c = p.Character
	local h = c and c:FindFirstChild("HumanoidRootPart")
	if h then return string.format("%.0f,%.0f,%.0f", h.Position.X, h.Position.Y, h.Position.Z) end
	return "nil"
end

local deathMark = {}   -- [名字] = 上次记录时间（去重）

local function onDeath(victim)
	local now = os.clock()
	-- 去重：同一个人 5 秒内只记一次（Died + 血量检测可能重复触发）
	local last = deathMark[victim.Name]
	if last and (now - last) < 5 then return end
	deathMark[victim.Name] = now

	local entry = {
		t = now,
		name = victim.Name,
		pos = posOf(victim),
	}
	table.insert(recent, entry)

	-- 清理 10 秒前的
	for i = #recent, 1, -1 do
		if now - recent[i].t > 10 then table.remove(recent, i) end
	end

	-- 统计最近 3 秒内死亡人数
	local cnt = 0
	for _, r in ipairs(recent) do
		if now - r.t <= 3 then cnt = cnt + 1 end
	end

	-- 3 秒内死 3 人以上 → 判定为爆发
	if cnt >= 3 then
		local bucket = math.floor(now / 3)
		if reported[bucket] then return end
		reported[bucket] = true

		local names = {}
		local positions = {}
		for _, r in ipairs(recent) do
			if now - r.t <= 3 then
				names[#names + 1] = r.name
				positions[#positions + 1] = r.pos
			end
		end
		local line = string.format("【爆发】3秒内%d人死亡: %s | 位置: %s",
			cnt, table.concat(names, ","):sub(1, 120), table.concat(positions, " / "):sub(1, 150))
		writeLog(line)
		print(line)

		-- 同时记录当时所有活着的玩家（嫌疑人）
		local alive = {}
		for _, p in ipairs(Players:GetPlayers()) do
			local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
			if h and h.Health > 0 and p ~= Players.LocalPlayer then
				alive[#alive + 1] = p.Name
			end
		end
		writeLog("  当时活着: " .. table.concat(alive, ","):sub(1, 200))
	end
end

local function watch(p)
	local c = p.Character
	if not c then return end
	local h = c:FindFirstChildOfClass("Humanoid")
	if not h or watched[h] then return end
	watched[h] = true
	h.Died:Connect(function() onDeath(p) end)
end

for _, p in ipairs(Players:GetPlayers()) do
	if p ~= Players.LocalPlayer then
		watch(p)
		p.CharacterAdded:Connect(function()
			task.wait(0.6)
			watch(p)
		end)
	end
end

Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function()
		task.wait(0.6)
		watch(p)
	end)
end)

-- 轮询补挂：远处玩家角色可能延迟加载，Humanoid 出现时间不确定
task.spawn(function()
	while true do
		task.wait(1.5)
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= Players.LocalPlayer then
				pcall(watch, p)
			end
		end
	end
end)

-- 同时监控血量骤降（有些死亡不走 Died 事件）
local lastHealth = {}
task.spawn(function()
	while true do
		task.wait(0.5)
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= Players.LocalPlayer then
				local c = p.Character
				local h = c and c:FindFirstChildOfClass("Humanoid")
				if h then
					local prev = lastHealth[p.Name]
					local cur = h.Health
					if prev and prev > 0 and cur <= 0 then
						onDeath(p)
					end
					lastHealth[p.Name] = cur
				end
			end
		end
	end
end)

local M = {
	active = true,
	recent = recent,
	stop = function() M.active = false end,
	status = function()
		return string.format("监控中 · 已记录 %d 次死亡", #recent)
	end,
}
getgenv().__DAWG_KILLMON = M

writeLog("=== 秒杀监控启动 ===")
print("[秒杀监控] 已启动 · 3秒内死3人以上会记录到 kill_burst_log.txt")
return M
