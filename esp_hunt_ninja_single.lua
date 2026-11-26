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

-- ============ 内嵌 DawgKit（单文件版，零外部依赖） ============
-- DawgKit 末尾有 return，直接拼会让整个 chunk 提前结束、ESP 主体一行都不执行，
-- 所以必须包进一个函数里再由这里调用。
local Kit = GENV.__DAWG_KIT
if not Kit then
	local __bootKit = function()
		--[[=========================================================================
		  DawgKit v1.0.1 · Roblox 脚本开发底座（单文件，零依赖）
		  用法：loadstring(readfile("DawgKit.lua"))()  →  拿到 Kit
		        Studio 里当 ModuleScript：local Kit = require(script.DawgKit)
		
		  设计原则（全部来自 总结/00_坑清单 的 85 条）：
		    · 默认什么都不做（K66）—— 加载只做只读准备，功能全等用户点
		    · hook 常驻、开关只控制放行，不提供「恢复」（K26）
		    · hook 里只调 hookfunction 的返回值（K24），全局只装一次（K25）
		    · 只信 pcall 结果，不做对象比较（K35）
		    · 面板挂 CoreGui/gethui，DisplayOrder 1e6，不补偿 58px（K45/K46）
		    · 每帧/每个属性都现取 Character，绝不缓存（K59）
		    · 所有速度/位移用「小步 CFrame」或抗重力 BV，不改 WalkSpeed（K10/K12/K17）
		=========================================================================]]
		
		local Players    = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local UIS        = game:GetService("UserInputService")
		local HttpService= game:GetService("HttpService")
		local Workspace  = game:GetService("Workspace")
		
		local Kit = {}
		Kit.version = "1.2.6"
		Kit.lastError = nil
		
		------------------------------------------------------------------ 0. 环境
		-- K37：checkcaller / getgenv / gethui 都可能不存在，全部 pcall 探测
		local function safe(f, ...)
			local ok, a, b = pcall(f, ...)
			if ok then return a, b end
			return nil
		end
		
		local GENV = safe(function() return getgenv() end) or _G
		local RENV = safe(function() return getrenv() end) or _G
		local HUI  = safe(function() return gethui() end) or safe(function() return game:GetService("CoreGui") end)
		
		-- K86：实测这是 Potassium 的 getgenv() ~= _G，执行器函数（readfile/writefile/
		-- hookfunction/getconnections…）只挂在 genv 上，rawget(_G) 拿到的是 nil。
		-- 所有执行器能力统一走这个取值器：先 genv，再 _G 兜底。
		local function g(name)
			local v = GENV[name]
			if v == nil then v = rawget(_G, name) end
			return v
		end
		Kit.env = {
			isExecutor = type(GENV.getgenv) == "function" or type(g("hookfunction")) == "function",
			genv = GENV, renv = RENV, hui = HUI,
			isStudio   = RunService:IsStudio(),
			hasHook    = type(g("hookfunction")) == "function",
			hasConn    = type(g("getconnections")) == "function",
			hasFile    = type(g("writefile")) == "function",
		}
		
		------------------------------------------------------------------ 1. 日志
		local TAG = "[DawgKit]"
		local LINES = {}
		local function fmt(...)
			local t = {}
			for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
			return table.concat(t, " ")
		end
		
		function Kit.log(...)
			local line = fmt(...)
			LINES[#LINES + 1] = line
			if #LINES > 200 then table.remove(LINES, 1) end
			print(TAG, line)
			return line
		end
		
		-- K61：pcall 必须把 err 留下来，不能吞
		-- 错误归一化：去掉「chunk:行号」和具体数字，同一个坑才会累加到同一条
		local function normErr(msg)
			local m = tostring(msg)
			m = m:gsub("^[%w_%.%(%)%-]+:%d+:%s*", "")
			m = m:gsub("%d+", "#")
			return m
		end
		
		function Kit.safe(f, ...)
			local ok, a, b = pcall(f, ...)
			if not ok then
				Kit.lastError = tostring(a)
				warn(TAG, "出错:", tostring(a))
				-- 自动经验：报错原文进库（修法留空，等人/AI 补）
				local L = Kit.learn
				if L and L.auto then
					L.add({
						kind = "pitfall",
						title = "运行报错: " .. normErr(a):sub(1, 70),
						how = "自动记录（Kit.safe 捕获）",
						fix = "待补：查 K86-K89 / PLAYBOOK 决策树",
						tags = { "auto", "runtime" },
					})
				end
			end
			return ok, a, b
		end
		
		function Kit.tail(n)
			n = math.min(n or 20, #LINES)
			local t = {}
			for i = math.max(1, #LINES - n + 1), #LINES do t[#t + 1] = LINES[i] end
			return t
		end
		
		-- 真实时间（tempo 改变 os.clock 后，日志/测速仍要准，K85）
		function Kit.clock()
			local rec = Kit._tempo and Kit._tempo.rec
			if rec and type(rec.raw) == "function" then return rec.raw() end
			return os.clock()
		end
		
		------------------------------------------------------------------ 2. 代际与单例
		-- K40：旧实例的连接不随 GUI 销毁，必须用代际号让回调自sha
		function Kit.guard(name)
			local k = "__dawg_gen_" .. tostring(name)
			local g = (tonumber(GENV[k]) or 0) + 1
			GENV[k] = g
			return g
		end
		
		function Kit.alive(gen, name)
			return tonumber(GENV["__dawg_gen_" .. tostring(name)]) == gen
		end
		
		------------------------------------------------------------------ 3. 实例构造
		-- K48：Instance.new 第二参数是 parent，不是属性表；Name 必须显式给
		function Kit.new(class, props, parent)
			local inst = Instance.new(class)
			local p = parent
			if props then
				for k, v in pairs(props) do
					if k == "Parent" then
						p = p or v -- props 里给的 Parent 也要生效，否则层级静默丢失
					else
						inst[k] = v
					end
				end
			end
			if not props or props.Name == nil then
				if inst.Name == class then inst.Name = class .. "_" .. tostring(math.random(1000, 9999)) end
			end
			if p then inst.Parent = p end
			return inst
		end
		
		------------------------------------------------------------------ 4. 名字匹配
		-- K56：裸子串会命中 Banana / HitDetection，必须按 token 边界
		function Kit.matchToken(name, kw)
			local s, k = tostring(name):lower(), tostring(kw):lower()
			if not string.find(k, "[^\0-\127]") then -- 中文/非 ASCII 直接子串
				local i = 1
				while true do
					local a, b = string.find(s, k, i, true)
					if not a then return false end
					local pre  = a > 1 and string.sub(s, a - 1, a - 1) or ""
					local post = b < #s and string.sub(s, b + 1, b + 1) or ""
					-- 只把字母数字当词内字符；下划线算分隔（player_detect_v2 里的 detect 是独立词）
					local function word(c) return c ~= "" and string.match(c, "[%a%d]") ~= nil end
					if not word(pre) and not word(post) then return true end
					i = a + 1
				end
			end
			return string.find(s, k, 1, true) ~= nil
		end
		
		------------------------------------------------------------------ 5. 探针
		-- K22 / K69 / K85：三行探针定死架构，一次返回全部字段，省 5-10 轮往返
		function Kit.probe(opts)
			opts = opts or {}
			local lp = Players.LocalPlayer
			local ch = lp and lp.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			local anim = hum and hum:FindFirstChildOfClass("Animator")
			local tool = ch and ch:FindFirstChildOfClass("Tool")
		
			local info = {
				game = game.Name, place = game.PlaceId, job = game.JobId,
				isClient = RunService:IsClient(),
				character = ch and ch.Name or false,
				hum  = hum and hum.WalkSpeed or false,
				anim = anim and (safe(function() return #(anim:GetPlayingAnimationTracks()) end) or 0) or false,
				tool = tool and true or false,
				remoteCount = 0,
			}
			info.remoteCount = #Kit.remotes()
		
			if opts.verticals ~= false then
				-- 判定是标准 3D 角色架构还是纯 UI 自研引擎
				local humans, anims, models = 0, 0, 0
				local scanned = 0
				for _, d in ipairs(Workspace:GetDescendants()) do
					scanned = scanned + 1
					if d:IsA("Humanoid") then humans = humans + 1
					elseif d:IsA("Animator") then anims = anims + 1
					elseif d:IsA("Model") then models = models + 1 end
					if scanned >= 4000 then break end
				end
				info.world = { humans = humans, anims = anims, models = models }
				info.kind = (humans > 0 or anims > 0) and "3D-角色架构" or "纯 UI / 自研引擎（不要用 Humanoid/Animator/Tool 写法）"
			end
		
			if opts.print ~= false then
				print(string.format("[探针] %s | Place %d | HUM=%s ANIM=%s TOOL=%s | remote=%d | %s",
					info.game, info.place, tostring(info.hum), tostring(info.anim),
					tostring(info.tool), info.remoteCount, info.kind or "-"))
			end
			return info
		end
		
		-- remote 清单（ReplicatedStorage + PlayerScripts + nil-parented）
		function Kit.remotes(filter)
			local out, seen = {}, {}
			local roots = { game:GetService("ReplicatedStorage"), game:GetService("ReplicatedFirst") }
			local lp = Players.LocalPlayer
			local ps = lp and lp:FindFirstChild("PlayerScripts")
			if ps then roots[#roots + 1] = ps end
		
			local function take(d)
				if seen[d] then return end
				seen[d] = true
				local path = safe(function() return d:GetFullName() end) or d.Name
				if filter and not string.find(string.lower(path), string.lower(tostring(filter)), 1, true) then return end
				out[#out + 1] = { path = path, name = d.Name, class = d.ClassName, inst = d }
			end
		
			for _, root in ipairs(roots) do
				for _, d in ipairs(root:GetDescendants()) do
					if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then take(d) end
				end
			end
			local nilInsts = safe(function() return getnilinstances() end)
			if nilInsts then
				for _, d in ipairs(nilInsts) do
					if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then take(d) end
				end
			end
			return out
		end
		
		-- K05 / K06 / K27：写一次 → 等 1 秒 → 读回，判定本地权威还是服务端覆盖
		function Kit.authority(inst, prop, value, waitSec)
			waitSec = waitSec or 1
			local before = safe(function() return inst[prop] end)
			if value ~= nil then
				local ok = pcall(function() inst[prop] = value end) -- 某些 __newindex 会静默失败
				if not ok then return { writable = false, before = before, verdict = "写入被拦截" } end
			end
			task.wait(waitSec)
			local after = safe(function() return inst[prop] end)
			local kept = value ~= nil and after == value or (value == nil and after == before)
			return {
				before = before, after = after, kept = kept, writable = true,
				verdict = kept and "保持（客户端权威 / 或只是本地镜像，需对照服务端行为）" or "被覆写（服务端权威，别在这上面花时间）",
			}
		end
		
		------------------------------------------------------------------ 6. hook
		local HOOKS = {}
		Kit.hooks = HOOKS
		
		-- K34：引擎内部高频函数，hook 了就卡死
		Kit.HOOK_DENY = {
			["debug.info"] = "Roblox 内部高频调用，hook 后画面冻结",
			["debug.traceback"] = "高频，且会污染调用栈",
			["task.wait"] = "会破坏所有脚本的调度",
			["os.time"] = "服务端时间语义，改了会让数据全判过期（K29 同类）",
		}
		
		--- 装一个幂等 hook。
		--- key    : 唯一名（重复调用直接返回旧记录，K25）
		--- owner  : 函数所在表，如 os / 某个 Player 表
		--- field  : 字段名
		--- handler: function(raw, ...) → 返回值；raw 是 hookfunction 的返回值，K24
		function Kit.hook(key, owner, field, handler)
			if type(key) ~= "string" then error("Kit.hook: key 必须是字符串", 2) end
			if HOOKS[key] then return HOOKS[key] end
			if Kit.HOOK_DENY[key] or Kit.HOOK_DENY[field] then
				Kit.log("拒绝 hook（黑名单）:", key, "—", Kit.HOOK_DENY[key] or Kit.HOOK_DENY[field])
				return nil
			end
			local orig = owner and owner[field]
			if type(orig) ~= "function" then
				Kit.log("hook 目标不是函数:", key)
				return nil
			end
			local hf = g("hookfunction")
			if type(hf) ~= "function" then
				Kit.log("当前环境没有 hookfunction（Studio/vanilla），跳过:", key) -- 降级不报错
				return nil
			end
		
			local raw
			local wrapper = function(...) return handler(raw, ...) end
			local nc = g("newcclosure")
			local wrapped = (type(nc) == "function" and safe(nc, wrapper)) or wrapper
			local ok, got = pcall(hf, orig, wrapped)
			if not ok then
				Kit.lastError = tostring(got)
				Kit.log("hook 失败:", key, "—", tostring(got))
				local L = Kit.learn
				if L and L.auto then
					L.add({
						kind = "pitfall",
						title = "hook 装不上（" .. tostring(got):sub(1, 40) .. "）",
						how = "key=" .. tostring(key),
						fix = "改事件驱动 / PreRender，别硬 hook（K87）",
						tags = { "auto", "hook" },
					})
				end
				return nil
			end
			raw = got -- K24：必须保存返回值，不能再用 orig
		
			-- K35：只信 pcall 成功，不比较函数对象
			local rec = { key = key, raw = raw, orig = orig, owner = owner, field = field, active = true }
			HOOKS[key] = rec
			Kit.log("hook 已装:", key)
			return rec
		end
		
		--- K26：restorefunction 会弄坏 hook 链，面板里不要给「恢复」按钮。仅在调试用。
		function Kit.unhook(key)
			local rec = HOOKS[key]
			if not rec then return false end
			local ok = pcall(function() restorefunction(rec.raw, rec.orig) end)
			if ok then HOOKS[key] = nil end
			return ok
		end
		
		--- K31：__namecall 会影响武器链路，默认不装；只在需要抓包时手动开
		function Kit.hookNamecall(handler)
			local hm = g("hookmetamethod")
			local nc = g("newcclosure")
			local cc = g("checkcaller")
			if type(hm) ~= "function" then
				Kit.log("没有 hookmetamethod，跳过 __namecall")
				return nil
			end
			local wrap = function(self, ...)
				local okName, name = pcall(getnamecallmethod)
				if cc and not (safe(cc) or false) then
					local ok, r = pcall(handler, okName and name or "?", self, ...)
					if ok and r ~= nil then return r end
				end
				return nil
			end
			if type(nc) == "function" then
				local ok, w = pcall(nc, wrap)
				if ok and w then wrap = w end
			end
			local ok = pcall(hm, game, "__namecall", wrap)
			return ok
		end
		
		------------------------------------------------------------------ 7. 循环与连接管理
		local CONNS = {}
		Kit.conns = CONNS
		
		function Kit.track(conn)
			CONNS[#CONNS + 1] = conn
			return conn
		end
		
		-- K74：task.spawn 返回的是 thread，不能 :Disconnect()，用标志位停
		function Kit.loop(name, interval, fn)
			local h = { name = name, running = true }
			task.spawn(function()
				while h.running do
					local ok, err = pcall(fn)
					if not ok then
						Kit.lastError = tostring(err)
						warn(TAG, "循环出错[" .. tostring(name) .. "]:", tostring(err))
					end
					task.wait(interval or 0)
				end
			end)
			function h.stop() h.running = false end
			return h
		end
		
		------------------------------------------------------------------ 8. 点击补偿
		-- K50 / K51 / K53：firesignal 首次无效；conns[1] 未必是目标；必须 task.spawn + 状态判定
		function Kit.click(btn, changed, tries)
			tries = tries or 3
			local conns = safe(function() return getconnections(btn.MouseButton1Click) end)
			if conns and #conns > 0 then
				for i = 1, math.min(#conns, tries) do
					local c = conns[i]
					local f = c.Function or c.fn
					if type(f) == "function" then
						task.spawn(function() safe(f) end)
					else
						safe(function() c:Fire() end)
					end
					task.wait(0.03)
					if changed and changed() then return true end
				end
				return false
			end
			-- 没有 getconnections（Studio）
			local ok = pcall(function() btn:Click() end)
			return ok
		end
		
		------------------------------------------------------------------ 9. 时间变速
		-- K02 / K29 / K38 / K39：只 hook os.clock；offset 上限 20 秒；不归零（归零会把冷却点推到未来）
		local tempo = { offset = 0, rate = 1, limit = 20, rec = nil }
		Kit._tempo = tempo
		
		function tempo.install()
			if tempo.rec then return true end
			tempo.rec = Kit.hook("os.clock", RENV.os, "clock", function(raw, ...)
				local t = raw(...)
				if tempo.rate ~= 1 then t = t * tempo.rate end
				return t + tempo.offset
			end)
			return tempo.rec ~= nil
		end
		
		function tempo.setOffset(v)
			v = math.clamp(tonumber(v) or 0, -tempo.limit, tempo.limit) -- K38：32 秒就冻屏
			tempo.offset = v
			return v
		end
		
		function tempo.freeze(sec)
			tempo.install()
			local stop = (Kit.clock()) + (sec or 5)
			tempo.setOffset((tempo.offset + (sec or 5)))
			-- 保持 offset 不归零（K39）；由调用方决定何时 tempo.reset
			return { until_ = stop, stop = function() tempo.rate = 1 end }
		end
		
		function tempo.reset()
			tempo.offset = 0
			tempo.rate = 1
		end
		
		function tempo.status()
			return { offset = tempo.offset, rate = tempo.rate, installed = tempo.rec ~= nil, limit = tempo.limit }
		end
		
		Kit.tempo = tempo
		
		------------------------------------------------------------------ 10. 位移
		-- K59：每帧现取，不缓存 Character
		function Kit.hrp()
			local lp = Players.LocalPlayer
			local ch = lp and lp.Character
			if not ch then return nil end
			return ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
		end
		
		-- K12 / K17：Y 轴 MaxForce 给 0 才能水平加速；不用时销毁 BV，不要把 Velocity 设 0
		function Kit.velocity(vec, opts)
			opts = opts or {}
			local hrp = opts.hrp or Kit.hrp()
			if not hrp then return nil end
			Kit.clearMovers(hrp)
			local bv = Instance.new("BodyVelocity")
			bv.Name = "__dawg_" .. tostring(opts.name or "vel")
			bv.MaxForce = Vector3.new(1e6, opts.antiGravity and 0 or 1e6, 1e6)
			bv.Velocity = vec
			bv.Parent = hrp
			return bv
		end
		
		function Kit.clearMovers(hrp)
			hrp = hrp or Kit.hrp()
			if not hrp then return end
			for _, c in ipairs(hrp:GetChildren()) do
				if c:IsA("BodyMover") and string.sub(c.Name, 1, 7) == "__dawg_" then
					pcall(function() c:Destroy() end)
				end
			end
		end
		
		-- K08 / K13：小步 CFrame 才不会被拉回；上升阶段跳过，否则跳跃被清零
		function Kit.step(offset, stepLen)
			local hrp = Kit.hrp()
			if not hrp then return false end
			local hum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
			if hum and (hum:GetState() == Enum.HumanoidStateType.Jumping or hrp.AssemblyLinearVelocity.Y > 1) then
				return false
			end
			stepLen = stepLen or 1
			local d = offset.Magnitude > stepLen and offset.Unit * stepLen or offset
			hrp.CFrame = hrp.CFrame + d
			return true
		end
		
		------------------------------------------------------------------ 11. getgc 分批扫描
		-- K58：全量 getgc 冻结主线程 —— 必须 islclosure 粗筛 + 分批让出 + 上限 + 进度
		function Kit.gcScan(pred, opts)
			opts = opts or {}
			local gc = safe(function() return getgc(true) end)
			if not gc then return {} end
			local limit = opts.limit or 5000
			local batch = opts.batch or 200
			local out, scanned, hit = {}, 0, 0
			for _, v in ipairs(gc) do
				if typeof(v) == "function" and safe(function() return islclosure(v) end) then
					scanned = scanned + 1
					local ok, keep = pcall(pred, v)
					if ok and keep then
						hit = hit + 1
						out[hit] = v
					end
					if scanned >= limit then break end
					if scanned % batch == 0 then
						if opts.progress then safe(opts.progress, scanned, limit, hit) end
						task.wait()
					end
				end
			end
			return out
		end
		
		------------------------------------------------------------------ 12. 持久化
		-- K60 / K64：存配置；Studio 走 plugin:SetSetting，executor 走 writefile
		function Kit.save(file, tbl)
			local ok, json = pcall(function() return HttpService:JSONEncode(tbl) end)
			if not ok then return false end
			local wf = g("writefile")
			if type(wf) == "function" then
				return (pcall(wf, file, json))
			end
			local plug = g("plugin")
			if plug and plug.SetSetting then
				return (pcall(function() plug:SetSetting(file, json) end))
			end
			return false
		end
		
		function Kit.load(file, default)
			local raw
			local rf = g("readfile")
			if type(rf) == "function" then
				if not (safe(function() return isfile(file) end) or false) then return default end
				raw = safe(rf, file)
			else
				local plug = g("plugin")
				if plug and plug.GetSetting then
					raw = safe(function() return plug:GetSetting(file) end)
				end
			end
			if type(raw) ~= "string" or raw == "" then return default end
			local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
			return ok and data or default
		end
		
		------------------------------------------------------------------ 13. 突破实验台
		-- 原则：不预设上限。先量化测，达标才算；单轮有硬超时，没提升就换下一条，不死磕。
		local lab = {}
		Kit.lab = lab
		
		--- 单轮实验：duration 秒内反复执行 action，用 sense 的差值算「服务端接受」
		--- sense 必须是「累计值读取器」（例如命中计数），返回数字
		function lab.trial(name, action, sense, opts)
			opts = opts or {}
			local duration = opts.duration or 3
			local gap = opts.gap or 0.05
			local settle = opts.settle or 0.4
			local before = sense and (tonumber(safe(sense)) or 0) or nil
			local t0 = Kit.clock()
			local attempts = 0
			while Kit.clock() - t0 < duration do
				if pcall(action, attempts + 1) then attempts = attempts + 1 end
				task.wait(gap)
			end
			if settle > 0 then task.wait(settle) end
			local after = sense and (tonumber(safe(sense)) or 0) or nil
			local accepted = (before and after) and math.max(0, after - before) or 0
			local row = {
				name = name, attempts = attempts, accepted = accepted,
				rate = attempts > 0 and accepted / attempts or 0,
				sendPerSec = attempts / duration,
				acceptPerSec = accepted / duration,
			}
			Kit.log(string.format("[实验] %-22s 发 %d 收 %d | %.2f/s 接受率 %.0f%%",
				name, attempts, accepted, row.acceptPerSec, row.rate * 100))
			return row
		end
		
		--- 梯度扫描：同一动作换不同参数跑一轮，按「每秒接受」排序，直接给最优
		--- opts.gapFor(v) 可让每轮用不同发包间隔（扫节奏必备）
		function lab.sweep(name, values, opts)
			opts = opts or {}
			local rows = {}
			for _, v in ipairs(values) do
				if opts.setup then pcall(opts.setup, v) end
				local sub = {}
				for k, val in pairs(opts) do sub[k] = val end
				if opts.gapFor then sub.gap = opts.gapFor(v) end
				local row = lab.trial(name .. "=" .. tostring(v),
					function(i) return opts.action(v, i) end, opts.sense, sub)
				row.value = v
				rows[#rows + 1] = row
			end
			table.sort(rows, function(a, b) return a.acceptPerSec > b.acceptPerSec end)
			if rows[1] then
				Kit.log(string.format("[实验] 最优 %s = %s（%.2f/s）", name, tostring(rows[1].value), rows[1].acceptPerSec))
			end
			return rows[1], rows
		end
		
		--- 方案链：按顺序试，第一个达标立刻停；全不达标返回 winner = nil
		--- candidates = { { label = "A 多入口并行", run = function() return 刀每秒 end, target = 2.0 }, ... }
		function lab.plan(name, candidates, opts)
			local rows = {}
			for _, c in ipairs(candidates) do
				if opts and opts.between then task.wait(opts.between) end
				local ok, m = pcall(c.run)
				m = ok and tonumber(m) or nil
				local hit = ok and (not c.target or (m or 0) >= c.target)
				rows[#rows + 1] = { label = c.label, metric = m, target = c.target, ok = hit }
				Kit.log(string.format("[方案] %s → %s %s（%s / 门槛 %s）",
					name, c.label, hit and "达标" or "不行，换下一条",
					m and string.format("%.2f", m) or "n/a", tostring(c.target or "-")))
				if hit then return { winner = c.label, metric = m, rows = rows } end
			end
			return { winner = nil, rows = rows }
		end
		
		--- 通道聚类：找「同语义不同入口」。每个 remote 往往独立限流，多路并行才是真的突破点
		function lab.channels(filter)
			local groups = {}
			for _, r in ipairs(Kit.remotes(filter)) do
				local root = string.lower(r.name)
				root = root:gsub("%d+$", ""):gsub("remote", ""):gsub("event", ""):gsub("request", ""):gsub("client", "")
				groups[root] = groups[root] or {}
				table.insert(groups[root], r)
			end
			local out = {}
			for k, v in pairs(groups) do out[#out + 1] = { root = k, count = #v, list = v } end
			table.sort(out, function(a, b) return a.count > b.count end)
			return out
		end
		
		--- 时序探测：RTT 抖动决定「卡锁边界发包」值不值得做（抖动 < 20ms 才有戏）
		function lab.clockProbe(rounds)
			rounds = rounds or 6
			local samples = {}
			for _ = 1, rounds do
				local t0 = Kit.clock()
				local st = safe(function() return Workspace:GetServerTimeNow() end)
				local t1 = Kit.clock()
				if st then samples[#samples + 1] = { rtt = t1 - t0, server = st } end
				task.wait(0.08)
			end
			local sum, mn, mx = 0, math.huge, 0
			for _, s in ipairs(samples) do
				sum = sum + s.rtt
				mn = math.min(mn, s.rtt)
				mx = math.max(mx, s.rtt)
			end
			local avg = #samples > 0 and sum / #samples or 0
			local out = { samples = samples, avg = avg, min = mn, max = mx, jitter = (#samples > 0) and (mx - mn) or 0 }
			Kit.log(string.format("[时序] RTT avg %.1fms jitter %.1fms → 边界发包 %s",
				avg * 1000, out.jitter * 1000, out.jitter < 0.02 and "值得试" or "抖动太大，别钻"))
			return out
		end
		
		--- 压门：一直挂在门口发，解锁瞬间被接住（K01 的结论落地，属于「喂满」不是「突破」）
		function lab.pushQueue(fire, gap, sense)
			local st = { sent = 0, accepted = 0, running = true }
			local before = sense and (tonumber(safe(sense)) or 0) or 0
			task.spawn(function()
				while st.running do
					if pcall(fire, st.sent + 1) then st.sent = st.sent + 1 end
					task.wait(gap or 0.04)
				end
				if sense then st.accepted = math.max(0, (tonumber(safe(sense)) or 0) - before) end
			end)
			function st.stop(reason)
				st.running = false
				if reason then Kit.log("压门停止:", reason) end
			end
			return st
		end
		
		--- 写属性对抗：每帧写回，看能不能压住引擎/服务端覆写（K10 的实验版）
		function lab.fightProperty(inst, prop, value, opts)
			opts = opts or {}
			local duration = opts.duration or 3
			local hz = opts.hz or 60
			local writes = 0
			local deadline = Kit.clock() + duration
			local h = Kit.loop("fight:" .. tostring(prop), 1 / hz, function()
				if Kit.clock() > deadline then return end
				pcall(function() inst[prop] = value end)
				writes = writes + 1
			end)
			task.wait(duration + 0.3)
			h.stop()
			local final = safe(function() return inst[prop] end)
			local kept = final == value
			Kit.log(string.format("[实验] 重写 %s = %s ×%d 次 → 最终 %s（%s）",
				tostring(prop), tostring(value), writes, tostring(final), kept and "压住了" or "被覆写"))
			return { writes = writes, final = final, kept = kept }
		end
		
		------------------------------------------------------------------ 14. UI
		local UI = {}
		UI.__index = UI
		
		--- 建一个面板。cfg = { title, width, hotkey, position }
		function Kit.ui(cfg)
			cfg = cfg or {}
			local self = setmetatable({}, UI)
			self.gen = Kit.guard("ui")
			self.order = 0
			self.conns = {}
			self.controls = {}
		
			local gui = Kit.new("ScreenGui", {
				Name = "DawgKit_UI",
				ResetOnSpawn = false,
				IgnoreGuiInset = true,
				ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
				DisplayOrder = 1e6, -- K46：游戏有 1000，必须压过
			})
			-- K46：先 CoreGui，失败退 gethui，再退 PlayerGui；每一层都要 pcall
			-- （普通脚本往 CoreGui 塞东西会抛 "Parent property is locked"）
			local coreGui = safe(function() return game:GetService("CoreGui") end)
			local mounted = coreGui ~= nil and (pcall(function() gui.Parent = coreGui end) or gui.Parent ~= nil)
			if not mounted and HUI and HUI ~= coreGui then
				pcall(function() gui.Parent = HUI end)
			end
			if gui.Parent == nil then
				local lp = Players.LocalPlayer
				local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
				if pg then pcall(function() gui.Parent = pg end) end
			end
			if gui.Parent == nil then
				Kit.log("没有可挂载的容器（CoreGui / gethui / PlayerGui 全部不可写）")
			end
		
			local W = cfg.width or 226
			-- K45：坐标系已含内缩，只用 AnchorPoint 贴左下角，不做 +58 补偿
			local panel = Kit.new("Frame", {
				Name = "Panel",
				Size = UDim2.fromOffset(W, cfg.height or 264),
				AnchorPoint = Vector2.new(0, 1),
				Position = cfg.position or UDim2.new(0, 20, 1, -20),
				BackgroundColor3 = Color3.fromRGB(20, 21, 26),
				BackgroundTransparency = 0.08,
				BorderSizePixel = 0,
				Active = true,
				ZIndex = 50,
			}, gui)
			Kit.new("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
			local stroke = Kit.new("UIStroke", {
				Color = Color3.fromRGB(255, 175, 45), Thickness = 1, Transparency = 0.45,
			}, panel)
		
			local bar = Kit.new("Frame", {
				Name = "TitleBar", Size = UDim2.new(1, 0, 0, 30),
				BackgroundColor3 = Color3.fromRGB(32, 33, 40), BackgroundTransparency = 0.12,
				BorderSizePixel = 0, ZIndex = 51,
			}, panel)
			Kit.new("UICorner", { CornerRadius = UDim.new(0, 10) }, bar)
		
			local title = Kit.new("TextLabel", {
				Name = "Title", Size = UDim2.new(1, -36, 1, 0), Position = UDim2.fromOffset(12, 0),
				BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(240, 240, 245),
				Text = cfg.title or "DawgKit", ZIndex = 52,
			}, bar)
		
			local closeBtn = Kit.new("TextButton", {
				Name = "Close", Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -30, 0, 3),
				BackgroundColor3 = Color3.fromRGB(58, 40, 44), BorderSizePixel = 0,
				AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 14,
				TextColor3 = Color3.fromRGB(255, 140, 140), Text = "×", ZIndex = 52,
			}, bar)
			Kit.new("UICorner", { CornerRadius = UDim.new(0, 6) }, closeBtn)
		
			local body = Kit.new("ScrollingFrame", {
				Name = "Body", Size = UDim2.new(1, -12, 1, -42), Position = UDim2.fromOffset(6, 36),
				BackgroundTransparency = 1, BorderSizePixel = 0,
				ScrollBarThickness = 4, ScrollBarImageColor3 = Color3.fromRGB(90, 92, 102),
				CanvasSize = UDim2.new(0, 0, 0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y, -- K44：不手算高度
				ZIndex = 51,
			}, panel)
			Kit.new("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder, -- K41：默认按 Name 排会乱
				Padding = UDim.new(0, 6),
			}, body)
		
			local openBtn = Kit.new("TextButton", {
				Name = "Open", Size = UDim2.fromOffset(54, 34),
				AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -20),
				BackgroundColor3 = Color3.fromRGB(20, 21, 26), BackgroundTransparency = 0.08,
				BorderSizePixel = 0, AutoButtonColor = false, Font = Enum.Font.GothamBold,
				TextSize = 12, TextColor3 = Color3.fromRGB(255, 175, 45), Text = "Dawg",
				Visible = false, ZIndex = 60,
			}, gui)
			Kit.new("UICorner", { CornerRadius = UDim.new(0, 8) }, openBtn)
		
			self.gui, self.panel, self.body = gui, panel, body
			self.stroke, self.openBtn = stroke, openBtn
			GENV.__dawg_ui = self -- K60：旧句柄留在全局，下次注入先 destroy
		
			local function nextOrder()
				self.order = self.order + 1
				return self.order
			end
			self._nextOrder = nextOrder
		
			------------------------------------------------ 控件工厂
			function self:section(text)
				local f = Kit.new("Frame", {
					Name = "Section_" .. tostring(text), Size = UDim2.new(1, 0, 0, 20),
					BackgroundTransparency = 1, ZIndex = 52, LayoutOrder = nextOrder(),
				}, body)
				Kit.new("TextLabel", {
					Name = "Label", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(4, 2),
					BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Color3.fromRGB(255, 175, 45), Text = text, ZIndex = 52,
				}, f)
				return f
			end
		
			-- K47：开关只有一个 setter，按钮/热键/代码全走它，且幂等
			function self:toggle(text, default, cb)
				local parent = self.body
				local row = Kit.new("Frame", {
					Name = "Toggle_" .. tostring(text), Size = UDim2.new(1, 0, 0, 28),
					BackgroundTransparency = 1, ZIndex = 52, LayoutOrder = nextOrder(),
				}, parent)
		
				local lab = Kit.new("TextLabel", {
					Name = "Label", Size = UDim2.new(1, -56, 1, 0), BackgroundTransparency = 1,
					Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Color3.fromRGB(214, 216, 224), Text = text, ZIndex = 52,
				}, row)
		
				local btn = Kit.new("TextButton", {
					Name = "ToggleBtn", Size = UDim2.fromOffset(48, 22),
					Position = UDim2.new(1, -48, 0.5, -11), BorderSizePixel = 0,
					AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 11,
					Text = "", ZIndex = 52,
				}, row)
				Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }, btn)
		
				local state = { on = default and true or false }
				local ctl = { state = state, btn = btn, label = lab }
		
				local function paint()
					btn.BackgroundColor3 = state.on and Color3.fromRGB(38, 120, 68) or Color3.fromRGB(56, 57, 64)
					btn.TextColor3 = state.on and Color3.fromRGB(235, 245, 235) or Color3.fromRGB(170, 172, 180)
					btn.Text = state.on and "ON" or "OFF"
				end
		
				function ctl.set(v, silent)
					v = v and true or false
					if state.on == v then return end -- 幂等
					state.on = v
					paint()
					if not silent and cb then task.spawn(function() safe(cb, v) end) end
				end
				function ctl.get() return state.on end
		
				paint()
				local c = btn.MouseButton1Click:Connect(function()
					if not Kit.alive(self.gen, "ui") then return end
					ctl.set(not state.on)
				end)
				self.conns[#self.conns + 1] = c
				self.controls[#self.controls + 1] = ctl
				return ctl
			end
		
			function self:button(text, cb)
				local b = Kit.new("TextButton", {
					Name = "Btn_" .. tostring(text), Size = UDim2.new(1, 0, 0, 28),
					BackgroundColor3 = Color3.fromRGB(40, 42, 50), BorderSizePixel = 0,
					AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 12,
					TextColor3 = Color3.fromRGB(220, 222, 230), Text = text,
					ZIndex = 52, LayoutOrder = nextOrder(),
				}, self.body)
				Kit.new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
				local c = b.MouseButton1Click:Connect(function()
					if not Kit.alive(self.gen, "ui") then return end
					task.spawn(function() safe(cb) end)
				end)
				self.conns[#self.conns + 1] = c
				return b
			end
		
			function self:label(text, size)
				local l = Kit.new("TextLabel", {
					Name = "Label", Size = UDim2.new(1, 0, 0, size or 18), BackgroundTransparency = 1,
					Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Color3.fromRGB(150, 152, 162), Text = text or "", TextWrapped = true,
					ZIndex = 52, LayoutOrder = nextOrder(),
				}, self.body)
				return l
			end
		
			-- 步进器：− 值 +（比滑块省 3 倍代码，够用）
			function self:stepper(text, min, max, step, default, cb)
				local row = Kit.new("Frame", {
					Name = "Step_" .. tostring(text), Size = UDim2.new(1, 0, 0, 28),
					BackgroundTransparency = 1, ZIndex = 52, LayoutOrder = nextOrder(),
				}, self.body)
				Kit.new("TextLabel", {
					Name = "Label", Size = UDim2.new(1, -104, 1, 0), BackgroundTransparency = 1,
					Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Color3.fromRGB(214, 216, 224), Text = text, ZIndex = 52,
				}, row)
				local minus = Kit.new("TextButton", {
					Name = "Minus", Size = UDim2.fromOffset(24, 22), Position = UDim2.new(1, -100, 0.5, -11),
					BackgroundColor3 = Color3.fromRGB(48, 50, 58), BorderSizePixel = 0, AutoButtonColor = false,
					Font = Enum.Font.GothamBold, TextSize = 13, Text = "-", TextColor3 = Color3.fromRGB(220, 222, 230), ZIndex = 52,
				}, row)
				local val = Kit.new("TextLabel", {
					Name = "Value", Size = UDim2.fromOffset(44, 22), Position = UDim2.new(1, -74, 0.5, -11),
					BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
					TextColor3 = Color3.fromRGB(255, 175, 45), Text = tostring(default or min), ZIndex = 52,
				}, row)
				local plus = Kit.new("TextButton", {
					Name = "Plus", Size = UDim2.fromOffset(24, 22), Position = UDim2.new(1, -26, 0.5, -11),
					BackgroundColor3 = Color3.fromRGB(48, 50, 58), BorderSizePixel = 0, AutoButtonColor = false,
					Font = Enum.Font.GothamBold, TextSize = 13, Text = "+", TextColor3 = Color3.fromRGB(220, 222, 230), ZIndex = 52,
				}, row)
				for _, b in ipairs({ minus, plus }) do
					Kit.new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
				end
		
				local cur = default or min
				local function apply(v, silent)
					cur = math.clamp(v, min, max)
					val.Text = string.format("%.2f", cur)
					if not silent and cb then task.spawn(function() safe(cb, cur) end) end
				end
				apply(cur, true)
				local c1 = minus.MouseButton1Click:Connect(function()
					if Kit.alive(self.gen, "ui") then apply(cur - step) end
				end)
				local c2 = plus.MouseButton1Click:Connect(function()
					if Kit.alive(self.gen, "ui") then apply(cur + step) end
				end)
				self.conns[#self.conns + 1] = c1
				self.conns[#self.conns + 1] = c2
				return { get = function() return cur end, set = apply }
			end
		
			------------------------------------------------ 关闭 / 重开 / 热键
			local cClose = closeBtn.MouseButton1Click:Connect(function()
				if not Kit.alive(self.gen, "ui") then return end
				panel.Visible = false
				openBtn.Visible = true
			end)
			local cOpen = openBtn.MouseButton1Click:Connect(function()
				if not Kit.alive(self.gen, "ui") then return end
				panel.Visible = true
				openBtn.Visible = false
			end)
			self.conns[#self.conns + 1] = cClose
			self.conns[#self.conns + 1] = cOpen
		
			-- K46 热键兜底：被别的界面压住时 still 能收放
			local hk = cfg.hotkey or Enum.KeyCode.RightShift
			local cHot = UIS.InputBegan:Connect(function(input, gp)
				if gp then return end
				if not Kit.alive(self.gen, "ui") then return end
				if input.KeyCode == hk then
					panel.Visible = not panel.Visible
					openBtn.Visible = not panel.Visible
				end
			end)
			self.conns[#self.conns + 1] = cHot
		
			------------------------------------------------ 拖动（K54 / K55：手写，5px 阈值）
			local dragging, dragStart, startPos, moved = false, nil, nil, 0
			local cBarBegin = bar.InputBegan:Connect(function(input)
				if not Kit.alive(self.gen, "ui") then return end
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					dragStart = input.Position
					startPos = panel.Position
					moved = 0
					input.Changed:Connect(function()
						if input.UserInputState == Enum.UserInputState.End then dragging = false end
					end)
				end
			end)
			local cEnd = UIS.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = false
				end
			end)
			local cMove = UIS.InputChanged:Connect(function(input)
				if not Kit.alive(self.gen, "ui") then return end
				if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch) then
					local d = input.Position - dragStart
					moved = math.max(moved, d.Magnitude)
					if moved > 5 then
						panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
							startPos.Y.Scale, startPos.Y.Offset + d.Y)
					end
				end
			end)
			self.conns[#self.conns + 1] = cBarBegin
			self.conns[#self.conns + 1] = cEnd
			self.conns[#self.conns + 1] = cMove
		
			function self:destroy()
				for _, c in ipairs(self.conns) do pcall(function() c:Disconnect() end) end
				self.conns = {}
				pcall(function() gui:Destroy() end)
				self.gui = nil
			end
		
			function self:setVisible(v)
				panel.Visible = v and true or false
				openBtn.Visible = not panel.Visible
			end
		
			return self
		end
		
		------------------------------------------------------------------ 15. 自举
		--- 一键自举：探针 → 面板 → 全局注册。插件 / autoexec 只调这一个函数。
		--- opts = { title, width, hotkey, probe = true, printProbe = true, ui = true, onReady = fn }
		--- 用法：Kit.mount()  之后任何脚本都能 getgenv().DawgKit 拿到库
		function Kit.mount(opts)
			opts = opts or {}
			local out = { kit = Kit, version = Kit.version }
		
			-- 1. 全局注册，后续脚本不用再 loadstring
			GENV.__DAWG_KIT = Kit
			GENV.DawgKit = Kit
			_G.DawgKit = Kit
		
			-- 2. 探针（默认打印一行，省一次手动调用）
			if opts.probe ~= false then
				local ok, p = pcall(Kit.probe, { print = opts.printProbe ~= false })
				out.probe = ok and p or nil
			end
		
			-- 3. 面板：探针结果直接落在第一屏
			if opts.ui ~= false then
				local ok, ui = pcall(Kit.ui, { title = opts.title or "DawgKit", width = opts.width, hotkey = opts.hotkey })
				if ok and ui then
					local p = out.probe
					ui:section("环境")
					ui:label(p and string.format("%s · Place %d · remote %d", tostring(p.game), p.place, p.remoteCount)
						or "（无探针数据）", 16)
					if p then
						ui:label(string.format("HUM=%s ANIM=%s TOOL=%s", tostring(p.hum), tostring(p.anim), tostring(p.tool)), 16)
						if p.kind then ui:label(p.kind, 30) end
					end
					ui:section("工具")
					ui:button("重新探针", function() Kit.probe() end)
					ui:button("列出 remote", function()
						for _, r in ipairs(Kit.remotes()) do Kit.log(r.class, r.path) end
					end)
					ui:button("打印最近日志", function()
						for _, l in ipairs(Kit.tail(15)) do print(l) end
					end)
					ui:button("卸载面板", function() ui:destroy() end)
					out.ui = ui
				else
					Kit.log("面板创建失败（插件环境没有 PlayerGui 属正常）：", tostring(ui))
				end
			end
		
			if opts.onReady then
				task.spawn(function() safe(opts.onReady, out) end)
			end
			Kit.log("mount 完成 · v" .. Kit.version)
			return out
		end
		
		------------------------------------------------------------------ 15.5 反作弊预检（ac）
		-- 动手写功能之前先扫一遍：知道它盯什么，才知道哪些路不能走。
		-- 只读扫描，不 hook、不改环境（K31/K32 的教训）。
		local ac = { patterns = {
			-- 只放「不会误伤零件名」的词：Triggerguard / Handguard 这种不能算
			"voltils", "anti cheat", "anticheat", "anti-cheat", "antiskid", "anti skid",
			"anticheatservice", "sentinel", "safeguard module", "validator",
			"kickplayer", "banplayer", "kick log", "ban log", "detection",
		} }
		Kit.ac = ac
		
		local function hitsIn(name)
			local ln = string.lower(tostring(name))
			for _, p in ipairs(ac.patterns) do
				if string.find(ln, p, 1, true) then return p end
			end
		end
		
		--- 扫客户端能看到的所有反作弊痕迹（脚本名 + 远程/容器名）
		function ac.scan(opts)
			opts = opts or {}
			local hits, checked = {}, 0
			local sc = rawget(_G, "getscripts")
			if type(sc) ~= "function" then sc = GENV.getscripts end
			if type(sc) == "function" then
				local ok, list = pcall(sc)
				if ok then
					for _, s2 in ipairs(list) do
						checked = checked + 1
						local okN, path = pcall(function() return s2:GetFullName() end)
						local okName, nm = pcall(function() return s2.Name end)
						if okN and path then
							local p = hitsIn(okName and nm or path)
							if p then hits[#hits + 1] = { kind = "script", path = path, pattern = p } end
						end
					end
				end
			end
			-- 只扫有意义的东西：脚本、远程、容器；BasePart/Weld 之类（扳机护圈、护木）一律跳过
			local function interesting(d)
				return d:IsA("LuaSourceContainer") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction")
					or d:IsA("UnreliableRemoteEvent") or d:IsA("Folder") or d:IsA("ScreenGui")
			end
			for _, svc in ipairs({ game:GetService("ReplicatedStorage"), game:GetService("ReplicatedFirst") }) do
				for _, d in ipairs(svc:GetDescendants()) do
					if interesting(d) then
						local p = hitsIn(d.Name)
						if p then hits[#hits + 1] = { kind = d.ClassName, path = d:GetFullName(), pattern = p } end
					end
				end
			end
			local level = (#hits == 0) and "none" or (#hits < 3 and "low" or "high")
			if opts.print ~= false then
				Kit.log(string.format("反作弊预检：%s（脚本 %d 个，命中 %d 处）", level, checked, #hits))
				for i = 1, math.min(#hits, 8) do
					print(string.format("  [%s] %s  ← %s", hits[i].kind, hits[i].path, hits[i].pattern))
				end
			end
			return { level = level, hits = hits, checked = checked }
		end
		
		--- 运行时自保：扫完直接把策略定下来，脚本按这个跑，不用人判断
		--- 返回 { safeMode, allowNamecallHook, maxSendHz, notes }
		function ac.harden(opts)
			local res = ac.scan({ print = false })
			local level = res.level
			local pol = {
				level = level,
				safeMode = (level ~= "none"),
				allowNamecallHook = (level == "none"),
				maxSendHz = (level == "none") and 10 or (level == "low" and 8 or 5),
				notes = {},
			}
			for _, h in ipairs(res.hits) do
				local l = string.lower(h.pattern)
				if l == "voltils" or l == "antiskid" or l == "anti skid" then
					pol.notes[#pol.notes + 1] = "Voltils：不代理环境、不 hook __namecall"
				elseif string.find(l, "kick", 1, true) or string.find(l, "ban", 1, true) then
					pol.notes[#pol.notes + 1] = "有踢人通道：发包降到 " .. pol.maxSendHz .. "Hz"
				end
			end
			Kit.acPolicy = pol
			if opts and opts.print ~= false then
				Kit.log(string.format("自保：level=%s safeMode=%s maxSendHz=%d%s",
					level, tostring(pol.safeMode), pol.maxSendHz,
					#pol.notes > 0 and (" | " .. table.concat(pol.notes, "；")) or ""))
			end
			return pol
		end
		
		--- 基于扫描结果给施工建议（这些是踩过的，不是通用废话）
		function ac.advise(res)
			res = res or ac.scan({ print = false })
			local tips, seen = {}, {}
			local function add(t)
				if seen[t] then return end
				seen[t] = true
				tips[#tips + 1] = t
			end
			if res.level == "none" then
				add("没扫到明显反作弊：仍按「不高频发包、不碰元表」写，别赌")
			else
				add("有检测：先按它盯的面设计，再写功能（顺序反了要重写）")
			end
			for _, h in ipairs(res.hits) do
				local l = string.lower(h.pattern)
				if l == "voltils" or l == "antiskid" or l == "anti skid" then
					add("Voltils 系：检测代码结构与环境代理 → 不 setfenv、不代理 _ENV（K32），走包装层")
				elseif l == "kick" or l == "ban" then
					add("有踢人/封禁通道：先看它由什么触发（校验/速度/异常包），别压满限流")
				elseif l == "trap" or l == "shield" or l == "guard" then
					add("有守卫脚本：避免无意义的高频轮询与属性轰炸"
						.. "（每帧全量扫、每帧写属性都会被看到）")
				end
			end
			add("通用：不 hook __namecall / 不碰实例元表（K31/K87）；要动相机用 PreRender（K90）")
			add("通用：发包频率跟游戏原生一致，别 60Hz 硬刷（K88）")
			if Kit.env.isExecutor and not Kit.env.hasConn then
				add("本环境没有 getconnections，别设计依赖连接禁用的方案")
			end
			return tips
		end
		
		------------------------------------------------------------------ 15.6 UI 库（WindUI）
		-- 约定：以后脚本 UI 默认用 WindUI（Footagesus/WindUI），本地 vendor 优先，避免连不上。
		GENV_CACHE = GENV_CACHE or GENV
		local WINDUI_LOCAL = { "vendor/WindUI.lua", "WindUI.lua", "vendor/main.lua" }
		local WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"
		
		function Kit.windui(opts)
			opts = opts or {}
			local cached = rawget(GENV_CACHE or {}, "__WINDUI_LIB")
			if cached then return cached end
		
			local rf = g("readfile")
			if type(rf) == "function" then
				for _, path in ipairs(WINDUI_LOCAL) do
					local ok, src = pcall(rf, path)
					if ok and type(src) == "string" and #src > 1000 then
						local chunk = loadstring(src, "@WindUI")
						if chunk then
							local ok2, lib = pcall(chunk)
							if ok2 and type(lib) == "table" then
								GENV_CACHE.__WINDUI_LIB = lib
								return lib
							end
						end
					end
				end
			end
		
			if opts.offlineOnly then
				Kit.log("WindUI：本地副本没找到，且要求离线")
				return nil
			end
			local ok, lib = pcall(function()
				return loadstring(game:HttpGet(WINDUI_URL))()
			end)
			if ok and type(lib) == "table" then
				GENV_CACHE.__WINDUI_LIB = lib
				Kit.log("WindUI：本地没有，已从 GitHub 拉取（建议存一份到 vendor/）")
				return lib
			end
			Kit.log("WindUI 加载失败：", tostring(lib))
			return nil
		end
		
		------------------------------------------------------------------ 15.7 功能管理（feat）
		-- 功能不写死在面板里：注册 → 自动生成控件 → 可增可减可关。
		-- 想让某个功能消失就 feat.remove(id)，UI 下次重建时自然没有它。
		local feat = { items = {}, order = {} }
		Kit.feat = feat
		
		--- 注册一个功能：{ id, name, desc, default, on(v), off(v) }
		function feat.register(def)
			if type(def) ~= "table" or not def.id then return nil end
			local exist = feat.items[def.id]
			if exist then return exist end
			local item = {
				id = def.id,
				name = def.name or def.id,
				desc = def.desc or "",
				on = def.on,
				off = def.off,
				enabled = false,
			}
			feat.items[def.id] = item
			feat.order[#feat.order + 1] = def.id
			if def.default ~= false then feat.set(def.id, true, true) end
			return item
		end
		
		--- 开关一个功能：只调它自己的 on/off，不碰别的
		function feat.set(id, v, silent)
			local it = feat.items[id]
			if not it then return false end
			v = v and true or false
			if it.enabled == v then return false end
			it.enabled = v
			local fn = v and it.on or it.off
			if type(fn) == "function" then
				local ok, err = pcall(fn, v)
				if not ok then
					Kit.lastError = tostring(err)
					Kit.log("功能出错[" .. id .. "]:", tostring(err))
				end
			end
			if not silent then Kit.log("功能", id, v and "开" or "关") end
			return true
		end
		
		--- 移除一个功能（先关掉再摘掉）
		function feat.remove(id)
			local it = feat.items[id]
			if not it then return false end
			feat.set(id, false, true)
			feat.items[id] = nil
			for i = #feat.order, 1, -1 do
				if feat.order[i] == id then table.remove(feat.order, i) end
			end
			return true
		end
		
		function feat.list()
			local out = {}
			for _, id in ipairs(feat.order) do
				local it = feat.items[id]
				if it then
					out[#out + 1] = { id = it.id, name = it.name, desc = it.desc, enabled = it.enabled }
				end
			end
			return out
		end
		
		--- 把已注册功能铺到 WindUI 的 section 上（每个功能一个 Toggle）
		function feat.bindTo(section)
			if not section or type(section.Toggle) ~= "function" then return 0 end
			local made = 0
			for _, id in ipairs(feat.order) do
				local it = feat.items[id]
				if it then
					local ok = pcall(function()
						section:Toggle({
							Title = it.name,
							Desc = it.desc,
							Value = it.enabled,
							Callback = function(v) feat.set(id, v) end,
						})
					end)
					if ok then made = made + 1 end
				end
			end
			return made
		end
		
		--- 把已注册功能铺到 Kit.ui 的 panel 上（回退用）
		function feat.bindToKit(ui)
			if not ui or type(ui.toggle) ~= "function" then return 0 end
			local made = 0
			for _, id in ipairs(feat.order) do
				local it = feat.items[id]
				if it then
					local ok = pcall(function()
						ui:toggle(it.name, it.enabled, function(v) feat.set(id, v) end)
					end)
					if ok then made = made + 1 end
				end
			end
			return made
		end
		
		------------------------------------------------------------------ 15.8 UI 库（Fluent）
		-- 约定：脚本 UI 用 Fluent（dawid-scripts/Fluent），本地 vendor 优先。
		-- 相比 WindUI：加载 10ms（WindUI 3770ms）、原生支持 MinimizeKey 快捷键、手机适配更好。
		local FLUENT_LOCAL = { "vendor/Fluent.lua", "Fluent.lua" }
		local FLUENT_URL = "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"
		
		function Kit.fluent(opts)
			opts = opts or {}
			local cache = rawget(GENV_CACHE or {}, "__FLUENT_LIB")
			if cache then return cache end
		
			local rf = g("readfile")
			if type(rf) == "function" then
				for _, path in ipairs(FLUENT_LOCAL) do
					local ok, src = pcall(rf, path)
					if ok and type(src) == "string" and #src > 1000 then
						local chunk = loadstring(src, "@Fluent")
						if chunk then
							local ok2, lib = pcall(chunk)
							if ok2 and type(lib) == "table" then
								GENV_CACHE.__FLUENT_LIB = lib
								return lib
							end
						end
					end
				end
			end
			if opts.offlineOnly then
				Kit.log("Fluent：本地没有副本，且要求离线")
				return nil
			end
			local ok, lib = pcall(function() return loadstring(game:HttpGet(FLUENT_URL))() end)
			if ok and type(lib) == "table" then
				GENV_CACHE.__FLUENT_LIB = lib
				return lib
			end
			Kit.log("Fluent 加载失败：", tostring(lib))
			return nil
		end
		
		------------------------------------------------------------------ 16. 经验库（learn）
		-- 让库自己记住：这次踩过什么、哪条路验证有效。下次开局先 recall，不重复踩。
		local learn = { entries = {}, max = 300, auto = true }
		Kit.learn = learn
		
		function learn.add(e)
			if type(e) ~= "table" or not e.title then return nil end
			-- 同标题合并：累加 hits，能看出「这个坑踩第几次了」
			local prev = nil
			for i = #learn.entries, 1, -1 do
				if learn.entries[i].title == e.title then
					prev = learn.entries[i]
					table.remove(learn.entries, i)
					break
				end
			end
			local rec = {
				id = e.id or ("L" .. (#learn.entries + 1)),
				kind = e.kind or "pitfall",   -- pitfall / win
				title = e.title,
				how = e.how or "",
				fix = e.fix or "",
				tags = e.tags or {},
				at = os.date and os.date("%m-%d") or "",
				hits = (prev and prev.hits or 0) + 1,
			}
			table.insert(learn.entries, 1, rec) -- 新的在前
			if #learn.entries > learn.max then table.remove(learn.entries) end
			-- 每积累 5 条自动落盘一次：跨会话也能带着走（失败不报错，静默）
			learn._dirty = (learn._dirty or 0) + 1
			if learn._dirty >= 5 then
				learn._dirty = 0
				pcall(learn.save)
			end
			return rec
		end
		
		function learn.find(q)
			q = tostring(q or ""):lower()
			local out = {}
			for _, e in ipairs(learn.entries) do
				local hay = (e.title .. " " .. e.how .. " " .. e.fix .. " " .. table.concat(e.tags, " ")):lower()
				if q == "" or string.find(hay, q, 1, true) then out[#out + 1] = e end
			end
			return out
		end
		
		function learn.report(q)
			local list = learn.find(q)
			Kit.log(string.format("经验库 %d 条（查询：%s）", #list, q or "全部"))
			for _, e in ipairs(list) do
				print(string.format("  [%s] %s\n       现象 %s\n       修法 %s", e.kind, e.title, e.how, e.fix))
			end
			return list
		end
		
		--- 踩得最多的几条（自动捕获的排前面）
		function learn.top(n)
			local list = {}
			for _, e in ipairs(learn.entries) do list[#list + 1] = e end
			table.sort(list, function(a, b)
				local ha, hb = a.hits or 0, b.hits or 0
				if ha ~= hb then return ha > hb end
				return (a.kind == "pitfall") and (b.kind ~= "pitfall")
			end)
			local out = {}
			for i = 1, math.min(n or 5, #list) do out[i] = list[i] end
			return out
		end
		
		function learn.save(file)
			return Kit.save(file or "dawg/learn.json", { entries = learn.entries })
		end
		
		function learn.load(file)
			local data = Kit.load(file or "dawg/learn.json", nil)
			if type(data) == "table" and type(data.entries) == "table" and #data.entries > 0 then
				learn.entries = data.entries   -- 直接接管，不做 add（否则 hits 会被重算）
			end
			return learn.entries
		end
		
		------------------------------------------------------------------ 16.5 经验自动收集
		-- 自动把「运行期异常」沉淀成 pitfall，不用人手动记。
		-- 抓三类：
		--   ① LogService 报错（脚本自身报错、游戏脚本报错）
		--   ② 写入无效（setproperty 后读回值不一致 —— 这是最典型的坑）
		--   ③ 远程调用异常（InvokeServer 抛错/超时）
		local autoLearn = {
			enabled = true,
			conns = {},
			seen = {},          -- 去重（同一条错误只记一次）
			maxPerSession = 40, -- 单次会话最多记 40 条，防止刷爆
			count = 0,
			minInterval = 1.5,  -- 两次记录之间的最小间隔
			lastAt = 0,
		}
		learn.auto = autoLearn
		
		local function autoAllowed(title)
			if not autoLearn.enabled then return false end
			if autoLearn.count >= autoLearn.maxPerSession then return false end
			local now = os.clock()
			if now - autoLearn.lastAt < autoLearn.minInterval then return false end
			if autoLearn.seen[title] then return false end
			autoLearn.seen[title] = true
			autoLearn.lastAt = now
			autoLearn.count = autoLearn.count + 1
			return true
		end
		
		--- 手动上报一条自动经验（外部模块也可以调）
		function autoLearn.report(title, how, fix, kind)
			if not autoAllowed(title) then return false end
			learn.add({
				kind = kind or "pitfall",
				title = title,
				how = how or "",
				fix = fix or "",
				when = "自动捕获 · " .. os.date("%m-%d %H:%M"),
				auto = true,
			})
			return true
		end
		
		--- 抓 LogService 报错
		function autoLearn.hookErrors()
			local LogService = game:GetService("LogService")
			local conn = LogService.MessageOut:Connect(function(message, msgType)
				if msgType ~= Enum.MessageType.MessageError then return end
				local msg = tostring(message)
				-- 过滤无关噪音
				if msg:find("GetServerChannelRemote") or msg:find("Failed to load") then return end
				-- 抓脚本错误：文件名:行号 + 错误内容
				local loc, err = msg:match("([%w_%-%.]+:%d+:%s*.-)\n") , nil
				local firstLine = msg:match("^[^\n]+") or msg
				local title = "运行报错: " .. firstLine:sub(1, 60)
				autoLearn.report(title, firstLine, "看堆栈定位；重复出现说明是结构性问题，别再重试同一路径")
			end)
			autoLearn.conns[#autoLearn.conns + 1] = conn
			return conn
		end
		
		--- 安全写属性：写后读回校验，不一致就自动记一条坑
		function autoLearn.setVerified(obj, prop, value, label)
			if not obj then return false end
			local okSet = pcall(function() obj[prop] = value end)
			if not okSet then
				autoLearn.report(
					string.format("写入失败: %s.%s", label or tostring(obj), prop),
					"setproperty 抛错（属性只读/对象无效）",
					"换通道：找对应 remote 或改父级对象"
				)
				return false
			end
			local okGet, got = pcall(function() return obj[prop] end)
			if not okGet then return false end
			local same = (typeof(got) == typeof(value)) and (tostring(got) == tostring(value))
			if not same then
				autoLearn.report(
					string.format("写入被覆盖: %s.%s", label or tostring(obj), prop),
					string.format("写入 %s 后读回 %s（被服务端/其他脚本重置）", tostring(value), tostring(got)),
					"这类属性由服务端权威，别硬写；改走 remote 或放弃该路径"
				)
				return false
			end
			return true
		end
		
		--- 包一层远程调用，失败自动记坑
		function autoLearn.callRemote(remote, ...)
			if not remote then return false, "no remote" end
			local args = { ... }
			local ok, res = pcall(function()
				if remote:IsA("RemoteFunction") then
					return remote:InvokeServer(table.unpack(args))
				elseif remote:IsA("RemoteEvent") then
					remote:FireServer(table.unpack(args))
					return true
				end
				return false
			end)
			if not ok then
				autoLearn.report(
					string.format("远程失败: %s", tostring(remote.Name)),
					"调用抛错: " .. tostring(res):sub(1, 80),
					"检查参数类型/数量，或该 remote 需要前置条件（权限、物品、状态）"
				)
				return false, res
			end
			return true, res
		end
		
		function autoLearn.stop()
			for _, c in ipairs(autoLearn.conns) do pcall(function() c:Disconnect() end) end
			autoLearn.conns = {}
			autoLearn.enabled = false
		end
		
		function autoLearn.stats()
			return string.format("自动收集 %d 条（上限 %d），经验库共 %d 条",
				autoLearn.count, autoLearn.maxPerSession, #learn.entries)
		end
		
		------------------------------------------------------------------ 16.6 全自动：查经验 + 包操作
		-- 目标：不用人记也不用人事先问，脚本自己在每次操作前后做检查。
		
		--- 按关键词查经验，返回可直接打印的建议文本（没命中返回 nil）
		function autoLearn.advise(topic, limit)
			if not topic or topic == "" then return nil end
			local hits = learn.find(topic)
			if #hits == 0 then return nil end
			local lines = {}
			for i = 1, math.min(limit or 3, #hits) do
				local e = hits[i]
				lines[#lines + 1] = string.format("[%s] %s → %s", e.kind, e.title, e.fix or "")
			end
			return table.concat(lines, "\n")
		end
		
		--- 操作前自动提示（打印到控制台，不用人问）
		function autoLearn.before(topic)
			local tip = autoLearn.advise(topic, 2)
			if tip then
				Kit.log("经验提醒（" .. topic .. "）：\n" .. tip)
			end
			return tip
		end
		
		--- 通用操作包装：自动验结果 + 失败自动记坑
		-- 用法：L.run("改门碰撞", function() ... return 结果 end,
		--            { verify = function(r) return r ~= nil end,
		--              fix = "如果这里失败，说明..." })
		function autoLearn.run(name, fn, opt)
			opt = opt or {}
			local t0 = os.clock()
			local ok, res = pcall(fn)
			local ms = math.floor((os.clock() - t0) * 1000)
		
			if not ok then
				autoLearn.report(
					"操作异常: " .. name,
					"抛错: " .. tostring(res):sub(1, 100),
					opt.fix or "看堆栈；连续两次同样错误就别再试这条路"
				)
				return false, res
			end
		
			if opt.verify then
				local vOk, passed = pcall(opt.verify, res)
				if not vOk or not passed then
					autoLearn.report(
						"结果无效: " .. name,
						string.format("返回 %s 但校验没通过（%dms）", tostring(res):sub(1, 60), ms),
						opt.fix or "结果被服务端覆盖/条件不满足，换通道或放弃该路径"
					)
					return false, res
				end
			end
		
			return true, res
		end
		
		--- 启动时自动注入常用经验到控制台（boot 会调）
		function autoLearn.bootBrief()
			local top = learn.top(3)
			if #top == 0 then return end
			local lines = { "高频坑（自动加载）：" }
			for _, e in ipairs(top) do
				lines[#lines + 1] = string.format("  · %s —— %s", e.title, (e.fix or ""):sub(1, 60))
			end
			Kit.log(table.concat(lines, "\n"))
		end
		
		-- 启动经验自动收集（抓报错 / 写入被覆盖 / 远程失败）
		task.spawn(function()
			pcall(function()
				learn.load()          -- 读回历史经验
				autoLearn.hookErrors()-- 开始监听报错
				Kit.log("经验自动收集已启动 · " .. autoLearn.stats())
				autoLearn.bootBrief()
			end)
		end)
		
		-- 预置：本次实战（Ugc 狩猎 / Potassium v2.6）的坑与有效方案
		local SEED = {
			-- 思路层
			{ kind = "sop", id = "S1", title = "总纲：四条判断顺序", how = "① 谁说了算 ② 写回读验 ③ 换通道（相机→输入→发包）④ 两条不通就收手喂满", fix = "任何新游戏都从这四步开始", tags = { "thinking" } },
			{ kind = "sop", id = "S2", title = "先问：这个数值/行为谁说了算", how = "客户端权威随手改；服务端权威只能找它允许的口子", fix = "先分客户端/服务端，再选手段", tags = { "thinking" } },
			{ kind = "sop", id = "S00", title = "加功能前先去 xahub 翻现成的", how = "D:/AI.dawangou/xahub 下有 XA 脚本的源码/脱壳/成品多份副本，夜视(Fullbright)、去雾(NoFog)、画质、锁定视角这些都有", fix = "先 grep xahub 找实现与参数，没有再自己写；自己写容易像夜视那样反复调光照还不像", tags = { "thinking", "reuse" } },
			{ kind = "sop", id = "S0", title = "动手前先扫反作弊，按它的检测面设计", how = "Kit.ac.scan() 看客户端有什么守卫/踢人/Voltils 类；它盯什么决定了你不能走哪条路", fix = "顺序永远是「先看检测面 → 再设计手段 → 最后写功能」；反过来要重写", tags = { "thinking", "anticheat" } },
			{ kind = "sop", id = "S3", title = "改之前先测：写一次、等一秒、读回", how = "属性被覆写、相机被覆盖、输入被忽略，只有读回能发现", fix = "保持=可能可用；复原=这条路不通", tags = { "thinking", "measure" } },
			{ kind = "sop", id = "S4", title = "输入层被忽略就去发包", how = "mousemoverel 后 GetMouseDelta 恒 0 = 输入进不了游戏", fix = "改找方向/发射 remote", tags = { "thinking", "aim" } },
			{ kind = "sop", id = "S5", title = "先出效果，再碰机制", how = "ESP 这类纯客户端功能能立刻验证探针/渲染/循环链路", fix = "机制类（瞄准/伤害）最后做", tags = { "thinking" } },
			{ kind = "sop", id = "S6", title = "一次只改一个变量 + 量化阈值", how = "抖动<0.1°/帧、接受率连续两轮+30%、锁定偏差<5°", fix = "多变量同时改无法归因", tags = { "thinking", "measure" } },
			{ kind = "sop", id = "S7", title = "两条路无提升就收手", how = "到了服务端硬上限，再调也是喂满；出现「只能重进」的副作用立刻回滚", fix = "接受上限→压门喂满", tags = { "thinking" } },
		
			-- 环境 / hook 层
			{ kind = "pitfall", id = "K86", title = "执行器 getgenv() ≠ _G", how = "readfile/hookfunction 只挂 genv，rawget(_G,'readfile') 是 nil；_G.__X 与 genv().__X 互不可见", fix = "能力取 genv[name] or rawget(_G,name)；句柄一律写 getgenv()", tags = { "env", "executor" } },
			{ kind = "pitfall", id = "K87", title = "hookmetamethod 改实例 __newindex 会吞掉所有属性写入", how = "拿不到原方法时返回 nil，之后 part.Name 写不进、ScreenGui 挂不上、相机冻结；元表全局共享且撤不回", fix = "改相机用 PreRender 写 CFrame；要 hook 就 hook 函数，别碰元表", tags = { "hook", "fatal" } },
			{ kind = "pitfall", id = "K90", title = "相机 Scriptable 时写 CFrame 被每帧覆盖", how = "写入后 0.5 秒偏差回 0°，游戏自己每帧写；mousemoverel 也无效", fix = "RunService.PreRender 写（渲染前最后一刻），实测偏差 146°→4.5°", tags = { "camera" } },
			{ kind = "pitfall", id = "K88", title = "准星不由相机决定，且高频刷方向会被锁伤害", how = "准星跟 UpdateHeadDirection（10Hz Vector3）；60Hz 抢发判异常，枪没伤害只能重进", fix = "只在扣扳机+有目标时 10Hz 同步方向；平时不发", tags = { "aim", "remote", "anticheat" } },
			{ kind = "pitfall", id = "K89", title = "「我打过」≠「已经死了」", how = "尸体标记只校验归属，打中没死的动物也会变尸体绿并继续跑", fix = "引用分支也要过 RagdollSettled / AnimalRagdoll / DeadAnimals", tags = { "esp", "logic" } },
		
			-- 测量纪律
			{ kind = "pitfall", id = "K91", title = "窗口失焦时所有测量都不可信", how = "角色位移 0、mouse1click 无响应、traffic 0 条、相机不动，但帧率照跑", fix = "先确认能动能开枪，再判断方案有效无效", tags = { "measure" } },
			{ kind = "pitfall", id = "K105", title = "异常数据先排除「人在操作」再猜原因", how = "数值突跳、位置对不上、采样前后不一致，可能是操作者刚好在移动/开枪/切武器/开镜/转视角", fix = "先问「刚才有没有操作」，确认不是人为再分析机制；否则把人动作当游戏行为，结论全错", tags = { "measure", "human" } },
			{ kind = "pitfall", id = "K92", title = "没伤害先看弹药", how = "CurrentAmmoLabel=0 时怎么打都没伤害，容易被误判成脚本搞坏游戏", fix = "先读弹药/武器 UI，再怀疑代码", tags = { "debug" } },
		
			-- 数据 / ESP
			{ kind = "pitfall", id = "K93", title = "DeadAnimals 没有「谁打的」字段", how = "尸体只有 Id/Weight/Sex/AIState/RagdollSettled", fix = "开火时记 Id + 模型引用；收集走 AnimalRagdoll 标签 + DeadAnimals + 引用三源", tags = { "esp", "data" } },
			{ kind = "pitfall", id = "K94", title = "Highlight 透明度 0.92 等于看不见", how = "想做「只描边」，结果远看什么都没有，以为高亮失效", fix = "可见至少 0.55–0.7；纯描边用 1.0 + 对比色", tags = { "ui", "esp" } },
			{ kind = "pitfall", id = "K95", title = "重载脚本会清掉运行时状态", how = "local 表每次 loadstring 归零，之前打过的尸体不再标绿", fix = "跨重载状态挂 getgenv()；经验库落盘", tags = { "state" } },
			{ kind = "pitfall", id = "K96", title = "同实例从活体变尸体不会自动换样式", how = "attach 只在首建时设颜色，死后仍显示原配色和名字", fix = "take() 比对 tag/style，不同就原地改颜色与文字", tags = { "ui", "esp" } },
		
			-- 吸附（本轮新增）
			{ kind = "pitfall", id = "K97", title = "吸附中心点按玩家身高算会偏高", how = "height=1.2 是玩家躯干高度，动物不到那么高，准心飘在背上", fix = "动物用 0.5–0.6；按目标类型分别设", tags = { "aim" } },
			{ kind = "pitfall", id = "K98", title = "横着划视角会越来越歪", how = "每帧用当前 UpVector 重建相机，roll 会累积", fix = "用世界 up = Vector3.new(0,1,0)，roll 恒为 0", tags = { "aim", "camera" } },
			{ kind = "pitfall", id = "K99", title = "死区边界会让准星抽搐", how = "目标在死区线上来回跨，权重在「不动」和「强吸」间跳变", fix = "改成连续权重（按屏幕偏离比例），不要二值边界", tags = { "aim" } },
			{ kind = "pitfall", id = "K100", title = "手机：手指按在屏幕上导致吸力被砍", how = "用「0.4 秒内有滑动」判断操作中，手机开镜时手指一直按着 → 吸力乘 0.45，永远跟不上", fix = "手机不要按手指活跃度削减吸力", tags = { "aim", "mobile" } },
			{ kind = "pitfall", id = "K101", title = "手机：准星圈按固定像素会失效", how = "PC 110px 占屏高 12%，手机 2000+ 高只占 5%，几乎摸不到", fix = "半径 = 视口高 × 比例（手机 0.16），判定与绘制同源", tags = { "aim", "mobile" } },
			{ kind = "pitfall", id = "K102", title = "追移动目标：只调吸力没用，要预判", how = "瞄的是上一帧位置，动物跑起来永远差半个身位", fix = "目标点 + 速度×0.08~0.14 秒提前量；同时上限速放宽（9°→22°/帧）", tags = { "aim" } },
		
			-- 工程
			{ kind = "pitfall", id = "K103", title = "Python 切片方向反了会写坏整个文件", how = "s[a:b] 中 b<a 得空串，replace('', new) 在每个字符间插入", fix = "替换前 assert a<b 且 old 命中数 ==1", tags = { "tooling", "fatal" } },
			{ kind = "pitfall", id = "K104", title = "局部函数/变量前向引用是 nil", how = "updateRing、lastTouchMove 在定义之前被回调引用，永远 nil，效果静默失效", fix = "先 local 声明再加 nil 保护，或把定义提前", tags = { "lua" } },
		
			-- 有效方案
			{ kind = "pitfall", id = "K108", title = "WindUI 的 Destroy 有 bug，窗口坏了只能重进", how = "Window:Destroy() 抛 attempt to index nil；销毁失败后窗口进入半损坏状态，之后所有 w:Tab 报 Frame is not a valid member of ScrollingFrame", fix = "别调 Destroy；重载脚本时复用 WindUI.Window；控件创建整段包 pcall，失败回退 Kit.ui", tags = { "ui", "windui" } },
			{ kind = "pitfall", id = "K112", title = "「我打过」要分两段：开火只登记候选，尸体真出现才转正", how = "直接在开火瞬间把准星附近动物记成击杀 → 打空的也标成尸体；反过来只在锁定目标时记 → 手动瞄准打死的反而记不上（一枪死的更快，来不及补）", fix = "开火时只写 pending（Id+时间戳，8 秒有效期），等尸体列表里出现同 Id 再转正成击杀；超时丢弃。注意 InputBegan 的 gp 常为 true，别用它提前 return", tags = { "esp", "logic" } },
			{ kind = "pitfall", id = "K111", title = "UI 面板盖住准星会让游戏「打不出伤害、测距归零」", how = "Fluent 默认把窗口放在屏幕中央偏右，正好压住准星；点击被面板的拖动区吃掉，游戏收不到射击/测距输入。另外 Acrylic=true 会生成全屏模糊层，同样干扰。表现为打死活没伤害、测距恒 0，点 X 关掉面板立刻恢复", fix = "面板固定挪到右上角（w.Root.Position = UDim2.new(1,-620,0,20)），且 Acrylic 设 false。排查任何「功能突然失效」先看有没有 UI 盖着准星", tags = { "ui", "fatal" } },
			{ kind = "pitfall", id = "K110", title = "Fluent 的 Slider 会把小数默认值截成 0", how = "Default=0.85 / 0.5 都变 0，整数（1、120、2000）正常；用 Default=0.85 的吸附强度直接失效", fix = "小数参数改成整数百分比映射：Min=30 Max=100，回调里 /100 还原", tags = { "ui", "fluent" } },
			{ kind = "pitfall", id = "K109", title = "Fluent 单窗口且 Destroy 后内部状态锁死", how = "Window:Destroy() 本身能跑，但内部「已创建」标记不清，之后 CreateWindow 报 You cannot create more than one window；本会话就再也建不出面板", fix = "重载时复用窗口：清空 TabHolder / ContainerHolder 再 AddTab；永远不要调 Window:Destroy", tags = { "ui", "fluent" } },
			{ kind = "pitfall", id = "K107", title = "WindUI 的 CreateWindow 在本执行器会挂起", how = "库能加载（API 齐全），但 CreateWindow 调用不返回，连续两次 40s 超时；游戏本身没死，是那个调用把线程挂住，之后同会话的 exec 也不稳", fix = "面板默认用 Kit.ui；要试 WindUI 把 CFG.useWindUI 打开，且只在一个可丢弃的会话里试", tags = { "ui", "windui", "fatal" } },
			{ kind = "win", id = "W1", title = "屏幕空间准星圈：圈内才锁、开镜不缩放", how = "WorldToViewportPoint 投影，算到屏幕中心像素距离", fix = "score = 1 - dist/radius，距离不参与，避免总锁最近的", tags = { "aim", "ui" } },
			{ kind = "win", id = "W2", title = "自适应目标源 + 多地图汉化", how = "常见文件夹名优先，名字关键词兜底，只扫直接子级；物种表按北美/非洲分组约 90 条", fix = "换服/换图不改代码", tags = { "esp", "portable" } },
			{ kind = "win", id = "W3", title = "距离牌文本永远刷新，只用距离控显隐", how = "超远时只 Enabled=false，不停止写文本", fix = "避免「牌子看起来没刷新」的误判", tags = { "esp", "ui" } },
			{ kind = "win", id = "W4", title = "agent RPC：一条命令一件事、回一行 JSON、大结果落盘", how = "@@DAWG@@ 前缀便于 grep；超 40 条或 16KB 落 dawg/*.json", fix = "recon/remotes/scripts/gui/eval/hookfn/dump/read", tags = { "agent" } },
			{ kind = "win", id = "W5", title = "lab 实验台：先测后判", how = "trial/sweep/plan/channels/clockProbe/pushQueue 量化接受率", fix = "达标才认，不达标换下一条", tags = { "lab" } },
			{ kind = "win", id = "W6", title = "经验库自动捕获 + 落盘", how = "Kit.safe/hook 失败自动入库；同标题累加 hits（错误去行号归一化）；每 5 条存 dawg/learn.json", fix = "boot 时读回并打印踩得最多的三条", tags = { "learn" } },
		}
		
		-- 种子只在库为空时灌入，避免 load 之后又 seed 一遍（hits 会翻倍）
		if #learn.entries == 0 then
			for _, e in ipairs(SEED) do learn.add(e) end
		end
		
		------------------------------------------------------------------ 17. 卸载
		-- K59：热注入必须清干净；hook 保留（K26），只停循环、断连接、销毁 GUI
		function Kit.cleanup(opts)
			opts = opts or {}
			for i = #CONNS, 1, -1 do
				pcall(function() CONNS[i]:Disconnect() end)
				CONNS[i] = nil
			end
			local gm = GENV.__dawg_ui
			if gm and gm.destroy then pcall(gm.destroy, gm) end
			GENV.__dawg_ui = nil
			if opts.movers ~= false then Kit.clearMovers() end
			for _, g in ipairs(safe(function() return game:GetService("CoreGui"):GetChildren() end) or {}) do
				if g.Name == "DawgKit_UI" then pcall(function() g:Destroy() end) end
			end
			local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if pg then
				for _, g in ipairs(pg:GetChildren()) do
					if g.Name == "DawgKit_UI" then pcall(function() g:Destroy() end) end
				end
			end
			Kit.log("已清理（hook 保留，重进游戏才真正复位）")
		end
		
		------------------------------------------------------------------ 18. 单例装载
		-- K25 / K59 / K60：同一会话重复注入 → 先清旧实例
		do
			local prev = GENV.__DAWG_KIT
			if type(prev) == "table" and prev.cleanup then
				pcall(prev.cleanup)
			end
			GENV.__DAWG_KIT = Kit
			_G.__DAWG_KIT = Kit
		end
		
		Kit.log(string.format("v%s 已就绪 | executor=%s studio=%s hook=%s conn=%s file=%s",
			Kit.version, tostring(Kit.env.isExecutor), tostring(Kit.env.isStudio),
			tostring(Kit.env.hasHook), tostring(Kit.env.hasConn), tostring(Kit.env.hasFile)))
		
		return Kit
	end
	pcall(__bootKit)
	Kit = GENV.__DAWG_KIT
	if not Kit then
		error("[忍者版] 内嵌 DawgKit 启动失败")
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

-- 视觉容器必须「一定渲染」：uiHolder() 在 Potassium 上返回 CoreGui.RobloxGui，
-- 那是 Roblox 自己的 GUI 层，第三方 Highlight / BillboardGui / ScreenGui 挂进去
-- 在移动端屏幕上什么都不画（Parent 正常、Enabled 正常，就是看不见）。
-- 所以这里绕开 uiHolder()，优先用真正会渲染的 CoreGui → PlayerGui。
local holder
do
	local function writable(c)
		if not c then return false end
		local ok = pcall(function()
			local probe = Instance.new("Folder")
			probe.Parent = c
			probe:Destroy()
		end)
		return ok
	end
	local cg = game:GetService("CoreGui")
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if writable(cg) then
		holder = cg
	elseif writable(pg) then
		holder = pg
	else
		holder = uiHolder()
	end
end

-- 重载策略：不销毁、不重建，直接接管旧容器。
-- 理由：销毁 → 重建之间有一帧空窗（动物标记全闪一下），而且旧引用一旦丢在场景里就会越叠越多。
-- 改成「有就复用、没有才建」，重载等于把新逻辑盖到同一套实例上，视觉上零中断。
local folder = holder:FindFirstChild("DawgHuntESP")
if not folder or not folder:IsA("Folder") then
	-- 旧容器可能还挂在 gethui 的隐藏层里，先搬过来再复用（不然会建出第二套，旧高亮留在不可见层）
	local stale
	for _, c in ipairs({ game:GetService("CoreGui"), uiHolder() }) do
		pcall(function()
			local g = c:FindFirstChild("DawgHuntESP")
			if g and g:IsA("Folder") and g ~= stale then stale = g end
		end)
	end
	if stale then
		folder = stale
		pcall(function() folder.Parent = holder end)
	else
		folder = Kit.new("Folder", { Name = "DawgHuntESP" }, holder)
	end
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
-- 候选有效期（秒）：开火后这么久之内目标真的变成尸体，才算我打中的。
-- 原来是 300 秒 —— 太长了，别人打死的也会算进来
-- （用户反馈「连线的目标被其他玩家的子弹打中了会标蓝」）。
-- 最近一次真实发射（btFireHook 里写入）。
-- ============ 击杀归属判定（唯一两条） ============
-- ① 开枪那一刻：从相机打一条射线，穿透一切遮挡物，命中 Animals 里的动物 → shotHitIds[Id] = true
-- ② 每秒扫描尸体：没高亮 且 shotHitIds 里有 → 套高亮
-- 旧的 pendingKills / claimWindow / SHOT_WINDOW / BleedsOutAt 判定已全部移除。

-- 打中记录：Id → os.clock() 时间戳（不是 true，否则标签会永久挂着）
local shotHitIds = getgenv().__DAWG_SHOT_HIT_IDS
if type(shotHitIds) ~= "table" then
	shotHitIds = {}
	getgenv().__DAWG_SHOT_HIT_IDS = shotHitIds
end
local HIT_TAG_TTL = 15       -- 秒：「（打中）」标签显示多久，过期自动消失
local HIT_CLAIM_TTL = 300    -- 秒：尸体认领的有效期（动物可能跑几分钟才倒）

-- 保留空壳：headConn 等旧位置仍在调它，避免改一处漏一处
local function markPending(model)
end

local function rememberKill(model)
	if not model then return end
	myKillModels[model] = true -- 引用：父级怎么变都认
	local ok, id = pcall(function() return model:GetAttribute("Id") end)
	if ok and id ~= nil then
		myKills[tostring(id)] = true
	end
end

-- checkShotRay 定义在文件更后面，这里必须前向声明：
-- Lua 的 local 只对后面定义的函数可见，直接引用会读到全局 nil，
-- pcall(nil) 静默失败 → 打中检测永远不执行（这个坑已经踩过 K104）。
local checkShotRay

-- 开火触发：只认真实开火，不认触摸/鼠标按键。
-- 为什么不能用 InputBegan：平板转视角、点空白都会触发 Touch 的 InputBegan，
-- 结果「没开枪也记成打中」（实测踩过）。
-- ProjectileFire 是游戏自己的开火广播，只有真的扣扳机才会发。
local fireSignalBound = false
local function bindFireSignal()
	if fireSignalBound then return end
	local rs = game:GetService("ReplicatedStorage")
	local remotes = rs:FindFirstChild("Remotes")
	local pfire = remotes and remotes:FindFirstChild("ProjectileFire")
	if not pfire then return end
	fireSignalBound = true
	-- 服务器广播（本机开火也会收到）
	pcall(function()
		pfire.OnClientEvent:Connect(function()
			pcall(checkShotRay)
		end)
	end)
	-- 自己发出去的开火（有些实现不走 OnClientEvent 回声）
	pcall(function()
		local oldFS = pfire.FireServer
		pfire.FireServer = function(self, ...)
			pcall(checkShotRay)
			return oldFS(self, ...)
		end
	end)
end
bindFireSignal()
task.delay(3, bindFireSignal)

-- 开火瞬间就记账：不依赖「锁定目标」（手动瞄准时 aim.target 是 nil，一枪死的动物根本记不上）。
-- 一次点击可能打死多只（霰弹），所以把准星附近的都记进来。
local fireConn
-- 射线判定：从相机中心往前打一条线，只有真正被这条线打中的动物才算「打中」。
-- 之前用「准星 160px 内全部记一笔」，周围没打中的也被记 → 它们后来死了就被误标成我的尸体。
-- raycastAnimal 用上面那个 lastShot 替代相机方向判命中（只影响判得准不准，不新增记账点）。

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
	local rayOrigin = cam.CFrame.Position
	local rayDir = cam.CFrame.LookVector
	local ok, result = pcall(function()
		return workspace:Raycast(rayOrigin, rayDir * 2000, params)
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
	-- 第二道校验（只在相机射线时用）：命中的模型必须在准星 120 像素内。
	-- 装饰墙可能 CanQuery=false，射线会穿过去打到墙后的动物；靠屏幕距离把这种剔掉。
	-- 用真实弹道时不加这道 —— 子弹本来就飞那儿，准星偏不偏跟打没打中无关。
	if not usingShot then
		local vp = cam.ViewportSize
		local sp, onScreen = cam:WorldToViewportPoint(found.PrimaryPart and found.PrimaryPart.Position or found:GetPivot().Position)
		if not onScreen then return nil end
		local dx, dy = sp.X - vp.X / 2, sp.Y - vp.Y / 2
		if math.sqrt(dx * dx + dy * dy) > 120 then return nil end
	end
	return found
end

fireConn = nil
-- 这里原本挂着 InputBegan 的诊断射线：每次点左键都跑一遍 2000 格 Raycast，
-- 只为了往 GENV.__DAWG_FIRE_DIAG 里记流水，且引用的 `hit` 根本不存在（永远 nil）。
-- 记账完全不需要它：真实记账只在 btFireHook，用子弹出膛那一刻的真实 origin/dir。
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
		-- 归属只看 myKills / myKillModels（由 sweepNearbyCarcasses 依据 shotHitIds 写入）
		local mine = (idStr ~= nil and myKills[idStr] == true) or myKillModels[m] == true
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
	-- pendingKills 机制已移除，这里不再需要清理循环
	-- myKillModels 不再参与判定，只做清理（历史残留的引用该放就放）
	for m in pairs(myKillModels) do
		if not m.Parent then myKillModels[m] = nil end
	end
	return list
end

-- 额外尸体检查：每 CARCASS_SWEEP 秒独立扫一遍尸体，
-- 凡是「我开枪后射线撞到过」的 Id 出现在尸体堆里，就认成我打死的。
-- 这不是重复造一个 collectMyCarcasses，而是换了一个持久判据：
-- collectMyCarcasses 看 pendingKills（模型引用），这里看 shotHitIds（Id 字符串）。
-- 转正后只写 myKills / myKillModels，加高亮交给 sync 的 take()——
-- take 里比较 tag/style，已经有高亮的不会重刷（用户要求「有高亮的不管」）。
local CARCASS_SWEEP = 1.0
local carcassAcc = 0

local function sweepCarcasses()
	local hit = 0
	local function try(m)
		if not m or not m:IsA("Model") or not m.Parent then return end
		local ok, id = pcall(function() return m:GetAttribute("Id") end)
		if not ok or id == nil then return end
		local idStr = tostring(id)
		if myKills[idStr] and myKillModels[m] then return end
		-- 只认射线记过账的，按 HIT_CLAIM_TTL 判过期
		local rec = shotHitIds[idStr]
		if rec == nil then return end
		if type(rec) == "number" and (os.clock() - rec) > HIT_CLAIM_TTL then
			shotHitIds[idStr] = nil
			return
		end
		myKills[idStr] = true
		myKillModels[m] = true
		hit = hit + 1
	end
	for _, m in ipairs(CollectionService:GetTagged("AnimalRagdoll")) do try(m) end
	local dead = workspace:FindFirstChild("DeadAnimals")
	if dead then
		for _, m in ipairs(dead:GetChildren()) do try(m) end
	end
	GENV.__SWEEP = { t = os.clock(), hit = hit, ids = (function() local n = 0 for _ in pairs(shotHitIds) do n = n + 1 end return n end)() }
end

-- 独立尸体扫描：每 3 秒跑一次，不用开火事件触发。
-- 判据：① 我的射线真的打中过它（shotHitIds）② 在玩家周围 NEARBY_RADIUS 内 ③ 还没标记过。
-- 已经标过的直接跳过（myKills + myKillModels 都有就是标过）。
local NEARBY_RADIUS = 1600
local function sweepNearbyCarcasses()
	local lp = Players.LocalPlayer
	local ch = lp and lp.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not hrp then return 0 end
	local origin = hrp.Position
	local hit = 0

	local function try(m)
		if not m or not m:IsA("Model") or not m.Parent then return end
		local ok, id = pcall(function() return m:GetAttribute("Id") end)
		if not ok or id == nil then return end
		local idStr = tostring(id)
		-- 已经标记过的不动
		if myKills[idStr] and myKillModels[m] then return end

		-- 唯一判据：我的射线真的打中过它（按 HIT_CLAIM_TTL 判过期）
		local rec = shotHitIds[idStr]
		if rec == nil then return end
		if type(rec) == "number" and (os.clock() - rec) > HIT_CLAIM_TTL then
			shotHitIds[idStr] = nil
			return
		end

		-- 距离兜底：必须在玩家附近
		local pos = m.PrimaryPart and m.PrimaryPart.Position
		if not pos then
			local okP, pv = pcall(function() return m:GetPivot().Position end)
			if okP then pos = pv end
		end
		if not pos then return end
		if (pos - origin).Magnitude > NEARBY_RADIUS then return end

		myKills[idStr] = true
		myKillModels[m] = true
		hit = hit + 1
	end

	for _, m in ipairs(CollectionService:GetTagged("AnimalRagdoll")) do try(m) end
	local dead = workspace:FindFirstChild("DeadAnimals")
	if dead then
		for _, m in ipairs(dead:GetChildren()) do try(m) end
	end
	GENV.__NEARBY = { t = os.clock(), hit = hit, radius = NEARBY_RADIUS }
	return hit
end

-- 事件驱动兜底：尸体可能存活不到 1 秒（一枪致死后立刻被清理/移走），
-- 光靠每秒轮询会漏。这里监听 AnimalRagdoll 标签的出现信号，瞬间抓。
-- 同时监听 Animals 的子项移除：动物从活体列表消失的那一刻就检查是不是我打死的。
local function claimOne(m)
	if not m or not m:IsA("Model") or not m.Parent then return false end
	local ok, id = pcall(function() return m:GetAttribute("Id") end)
	if not ok or id == nil then return false end
	local idStr = tostring(id)
	if myKills[idStr] and myKillModels[m] then return true end
	local rec = shotHitIds[idStr]
	if rec == nil then return false end
	if type(rec) == "number" and (os.clock() - rec) > HIT_CLAIM_TTL then
		shotHitIds[idStr] = nil
		return false
	end
	myKills[idStr] = true
	myKillModels[m] = true
	GENV.__CLAIM_HIT = (GENV.__CLAIM_HIT or 0) + 1
	return true
end

do
	local CS = game:GetService("CollectionService")
	-- 尸体标签一出现就抓（比轮询快，能抓住存活很短的尸体）
	pcall(function()
		CS:GetInstanceAddedSignal("AnimalRagdoll"):Connect(function(m)
			task.defer(function()
				pcall(claimOne, m)
			end)
		end)
	end)
	-- 活体从 Animals 移除的那一刻：先记 Id（尸体可能晚一步或直接消失）
	pcall(function()
		local an = workspace:FindFirstChild("Animals")
		if an then
			an.ChildRemoved:Connect(function(m)
				if m:IsA("Model") then
					local ok, id = pcall(function() return m:GetAttribute("Id") end)
					if ok and id ~= nil then
						local idStr = tostring(id)
						-- 只要射线记过账，就先标成我的（尸体出现后 sweep 会补上高亮）
						local rec = shotHitIds[idStr]
						if rec ~= nil and not (myKills[idStr] and myKillModels[m]) then
							myKills[idStr] = true
							myKillModels[m] = true
							GENV.__CLAIM_REMOVED = (GENV.__CLAIM_REMOVED or 0) + 1
						end
					end
				end
			end)
		end
	end)
end

-- 手动补标：把玩家附近 NEARBY_RADIUS 内所有还没高亮的尸体，不管有没有射线记录全标上。
-- 只用于补齐历史尸体（比如判据修好之前打死的那些）。正常流程不会调用它。
local function claimNearbyForce()
	local lp = Players.LocalPlayer
	local ch = lp and lp.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not hrp then return 0 end
	local origin = hrp.Position
	local hit = 0
	local function try(m)
		if not m or not m:IsA("Model") or not m.Parent then return end
		local ok, id = pcall(function() return m:GetAttribute("Id") end)
		if not ok or id == nil then return end
		local idStr = tostring(id)
		if myKills[idStr] and myKillModels[m] then return end
		local pos = m.PrimaryPart and m.PrimaryPart.Position
		if not pos then
			local okP, pv = pcall(function() return m:GetPivot().Position end)
			if okP then pos = pv end
		end
		if not pos then return end
		if (pos - origin).Magnitude > NEARBY_RADIUS then return end
		myKills[idStr] = true
		myKillModels[m] = true
		shotHitIds[idStr] = os.clock()
		hit = hit + 1
	end
	for _, m in ipairs(CollectionService:GetTagged("AnimalRagdoll")) do try(m) end
	local dead = workspace:FindFirstChild("DeadAnimals")
	if dead then
		for _, m in ipairs(dead:GetChildren()) do try(m) end
	end
	return hit
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
			-- 已经是「我打中的尸体」样式就不再重复处理：
			-- take 里靠比较 tag/style 实现跳过，这里先把常见情况短路掉。
			-- 预估分由 attach 的 scoreLine（第一行）统一显示，这里不再重复
			take(m, PALETTE.mine, localName(m) .. "尸体")   -- 例：灰熊尸体 / 花鹿尸体
		end
		-- 活体：跳过已经是尸体的，否则会被刷回原样式
		for _, m in ipairs(collectAnimals()) do
			if not carcassSet[m] then
				-- 打中但还没死：深蓝色标出来（HIT_TAG_TTL 秒内有效）
				local hit = false
				local okId, id = pcall(function() return m:GetAttribute("Id") end)
				if okId and id ~= nil then
					local rec = shotHitIds[tostring(id)]
					if rec == true then
						-- 兼容旧版存 true 的记录：直接清掉，让它自然过期
						shotHitIds[tostring(id)] = nil
					elseif type(rec) == "number" and (os.clock() - rec) < HIT_TAG_TTL then
						hit = true
					end
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
-- 器官 Attachment 引用缓存（只缓存对象本身，不缓存坐标）。
-- 之前 FindFirstChild(name, true) 每帧递归搜子孙，20+ 只动物 × 60Hz 太贵。
local organRefs = setmetatable({}, { __mode = "k" })
local organSmooth = setmetatable({}, { __mode = "k" })
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
	-- 白尾鹿（WhiteTailedDeerMale / Female → 都归到 whitetaileddeer）：
	-- 两肺中点落在体高偏上的位置，子追打上去子弹从背上擦过去，往下压 0.15 studs。
	whitetaileddeer = -0.15,
	-- 熊：GrizzlyBear 实测——两肺中点比心脏高约 0.35 studs，落在肩隆/脖子根的高度，
	-- 视觉上就是用户说的「靠脖子」。往下压 0.25 落到胸腔中部（±0.05 内）。
	-- 注意物种 key 是 grizzlybear，不是 grizzly —— speciesKey 只做小写和剥后缀，
	-- 不会把 GrizzlyBear 拆成 grizzly，之前写 grizzly 所以一直没匹配上。
	grizzlybear = 0,
	grizzly = 0,
	blackbear = 0,
	brownbear = 0,
	polarbear = 0,
	slothbear = 0,
	bear = 0,
}

-- 前后偏移（沿目标自身朝向，单位 studs，负值 = 往后退）。
-- 熊现在用 spine_03/spine_02 中点定位，不需要人工前后偏移（全部 0）。
local SPECIES_AIM_DZ = {
	blackbear = 0,
	brownbear = 0,
	grizzlybear = 0,
	grizzly = 0,
	polarbear = 0,
	slothbear = 0,
	bear = 0,
}

-- 用身体 MeshPart 定位的物种（器官坐标会随骨骼摆动的）。
local BODY_MESH_SPECIES = {
	grizzlybear = true, grizzly = true, blackbear = true, brownbear = true,
	polarbear = true, slothbear = true,
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

	-- 胸腔定位：胸椎（spine_03）与背椎（spine_02）的中点。
	-- 实测 MaleMoose 的骨骼（相对 RootPart，沿 LookVector）：
	--   Eyes +3.93 / neck +1.59 / 前腿起点 +1.71 / spine_03 +0.17 /
	--   spine_02 -1.22 / spine_01 -2.48 / 后腿 -3.0~-4.6（后负为朝头）
	-- 用户说的「肺在前腿靠后一点」= spine_03 与 spine_02 之间，中点约 -0.53。
	-- 之前用的 LeftLung / RightLung 落在 +0.588（肩前 / 脖子根）——
	-- 名字叫肺，位置根本不在肺上。
	if BODY_MESH_SPECIES[speciesKey(m.Name)] then
		-- 熊没有 spine_XX 骨骼（实测 GrizzlyBear 的 spine_01/02/03 全是 nil，
		-- 和驼鹿不同构，不能照搬驼鹿那套命名）。
		-- 但 LeftLung / RightLung / Heart 都在，实测（相对 RootPart，沿 LookVector）：
		--   LeftLung  前后=-0.499  上下=+0.513
		--   RightLung 前后=-0.500  上下=+0.514
		--   Heart     前后=-0.502  上下=+0.123
		-- 前后 -0.50 正是用户说的「前腿靠后一点」；但两肺本身偏上（+0.51），
		-- 所以取「两肺中点」与「心脏」的中点 = 胸腔中心（前后 -0.50 / 上下 +0.32）。
		-- 熊的 LeftLung / Heart 挂点不可信：实测两者前后都在 -0.50
		-- （完全重合），而驼鹿的两肺在 -0.166、心在 -0.831（差 0.66）。
		-- 照搬驼鹿那套会把点落在前腿前方（=肩/胸口），用户反馈的「定到胸口了」就是这个。
		-- 改用**身体包围盒按比例**，比例从驼鹿实测反推：
		--   FemaleMoose: bounds Size=(2.06,5.92,8.42)，两肺前后 -0.166 → (-0.166+4.21)/8.42 = 48.0%（从头往尾）
		--                两肺上下 +0.834 → (0.834+2.96)/5.92 = 64.1%（从脚往上）
		--   驼鹿前腿根 c_thigh_b = -0.367 (=45.6%)，肺 48.0% 正好在前腿后面 2.4%，和用户说的一致。
		local pbB = m:FindFirstChild("_ProjectileBounds")
		if pbB and pbB:IsA("BasePart") then
			local L, U = root.CFrame.LookVector, root.CFrame.UpVector
			local minF, maxF, minU, maxU = 1e9, -1e9, 1e9, -1e9
			for _, s in ipairs({
				Vector3.new(1, 1, 1), Vector3.new(1, 1, -1), Vector3.new(1, -1, 1), Vector3.new(1, -1, -1),
				Vector3.new(-1, 1, 1), Vector3.new(-1, 1, -1), Vector3.new(-1, -1, 1), Vector3.new(-1, -1, -1),
			}) do
				local v = (pbB.CFrame * (pbB.Size * 0.5 * s)) - root.Position
				local f, u = v:Dot(L), v:Dot(U)
				if f < minF then minF = f end
				if f > maxF then maxF = f end
				if u < minU then minU = u end
				if u > maxU then maxU = u end
			end
			if maxF - minF > 0.5 then
				-- 48% 从头往尾、 64% 从脚往上
				local f = minF + (maxF - minF) * 0.48
				local u = minU + (maxU - minU) * 0.64
				local raw = root.CFrame * Vector3.new(0, u, f)
				local prev = organSmooth[m]
				if prev then raw = prev:Lerp(raw, 0.40) end
				organSmooth[m] = raw
				return raw
			end
		end
		local s3 = m:FindFirstChild("spine_03", true)
		local s2 = m:FindFirstChild("spine_02", true)
		if s3 and s2 and s3:IsA("Attachment") and s2:IsA("Attachment")
			and s3.Parent and s2.Parent then
			local mid = (s3.WorldPosition + s2.WorldPosition) * 0.5
			-- 跟姿态但有一定惯性，避免骨骼微抖直接传到准星
			local prev = organSmooth[m]
			if prev then mid = prev:Lerp(mid, 0.40) end
			organSmooth[m] = mid
			return mid
		end
		-- 没有 spine 骨骼才退回身体 MeshPart 几何中心
		local best, bestV = nil, 0
		for _, p in ipairs(m:GetDescendants()) do
			if p:IsA("BasePart") and p.Name ~= "RootPart" and p.Name ~= "_ProjectileBounds" and p.Name ~= "Eyes" then
				local v = p.Size.X * p.Size.Y * p.Size.Z
				if v > bestV then best, bestV = p, v end
			end
		end
		if best then
			return best.CFrame * Vector3.new(0, best.Size.Y * 0.08, 0)
		end
	end


	-- 熊曾经改用包围盒比例定位，已撤销：那段写的 `Vector3.new(0, u, -f)` 带了个错误的负号，
	-- f 本来就是沿 LookVector 的正值，再取反就把点翻到 RootPart 背后。
	-- 实测 GrizzlyBear：肺在局部 +0.596（前）/ +0.657（上），而那段算出来是 -0.953（后）。
	-- 现在直接用肺中点，不在错基准上叠加修正。

	-- 器官坐标每帧重算，不信任缓存。
	-- 肺挂在骨骼上，熊走路 / 低头时 spine 姿态一变，肺相对 RootPart 就移了，
	-- 缓存的局部坐标还停在旧姿态 —— 用户实测：同一只熊刚才准、换个姿势就不准。
	-- 现在每帧读真实世界坐标，再用 Lerp 平滑，既跟得上姿态又不抖（抖是当初缓存的原因）。
	local off = organCache[m]
	do
		local refs = organRefs[m]
		if not refs or not refs.ll or not refs.ll.Parent then
			refs = {
				ll = m:FindFirstChild("LeftLung", true),
				rl = m:FindFirstChild("RightLung", true),
				ht = m:FindFirstChild("Heart", true),
			}
			organRefs[m] = refs
		end
		local livePt
		if refs.ll and refs.ll.Parent then
			if refs.rl and refs.rl.Parent then
				livePt = (refs.ll.WorldPosition + refs.rl.WorldPosition) * 0.5
			else
				livePt = refs.ll.WorldPosition
			end
		elseif refs.ht and refs.ht.Parent then
			livePt = refs.ht.WorldPosition
		end
		if livePt then
			local prev = organSmooth[m]
			if prev then livePt = prev:Lerp(livePt, 0.55) end
			organSmooth[m] = livePt
			off = root.CFrame:PointToObjectSpace(livePt)
			organCache[m] = off
		end
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
	local sk = speciesKey(m.Name)
	local dy = SPECIES_AIM_DY[sk]
	if dy then
		-- 只有身体点需要修正；瞄头时那个眼/头骨骼本身就是准的
		pt = pt + Vector3.new(0, dy, 0)
	end
	-- 前后：LookVector 是目标自身的正前方，负值就是往尾巴那边退
	local dz = SPECIES_AIM_DZ and SPECIES_AIM_DZ[sk]
	if dz then
		pt = pt + root.CFrame.LookVector * dz
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

-- 开枪后的真实射线碰撞检测：从 origin 沿 dir 打一条 2000 格的 Raycast，
-- 撞到哪个动物就记哪个。不再遍历 targets 算垂直距离（那种算法会把
-- 射线旁边擦过、实际没碰到的动物也算成命中）。
-- 开枪后 SHOT_WINDOW 秒内，每帧用「相机中心射线」碰撞检测：撞到目标就标「打中」。
-- 用户明确要的判定方式：不看弹道、不看子追锁定、不看开火瞬间那一条线，
-- 只看「开枪之后一小段时间里，我的准星射线碰到了谁」。
-- 开枪瞬间调用一次：从相机发射一条射线，命中 Animals 里的动物就记进 shotHitIds。
-- 不再用「开枪后 N 秒窗口内每帧检测」——只在你真正扣扳机那一刻判一次。
function checkShotRay()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	-- 「只认动物、穿透一切遮挡物」：排除 workspace 下除 Animals 之外的所有顶层对象，
	-- 于是树(Trees)、地形(Terrain)、洞穴(Cave)、墙(Barriers)、建筑、其他玩家
	-- 全部不参与碰撞，射线只会命中 Animals 里的动物。
	-- 顶层对象数量很少（20~30 个），每帧构建一次可接受。
	local ign = {}
	local ch = Players.LocalPlayer.Character
	if ch then ign[#ign + 1] = ch end
	if cam then ign[#ign + 1] = cam end          -- 第一人称手里的枪贴在相机前一格
	-- 排除列表缓存：workspace 顶层对象很少变化，每帧重建 55 项没必要
	local cached = GENV.__SHOTRAY_IGN
	if not cached or cached.tick ~= math.floor(os.clock() / 2) then
		cached = { list = {}, tick = math.floor(os.clock() / 2) }
		local animalRoot = workspace:FindFirstChild("Animals")
		for _, c in ipairs(workspace:GetChildren()) do
			if c ~= animalRoot and c ~= ch then
				cached.list[#cached.list + 1] = c
			end
		end
		GENV.__SHOTRAY_IGN = cached
	end
	for _, c in ipairs(cached.list) do
		ign[#ign + 1] = c
	end
	params.FilterDescendantsInstances = ign
	local ok, res = pcall(function()
		return workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 2000, params)
	end)
	if not ok or not res or not res.Instance then
		GENV.__MB = { t = os.clock(), stage = "miss", ok = ok }
		return
	end
	-- 从命中的零件往上找，找到 targets 里登记过的 Model 就是它。
	local node = res.Instance
	local depth = 0
	local chain = {}
	while node and depth < 8 do
		chain[#chain + 1] = node.Name
		if targets[node] then
			GENV.__MB = { t = os.clock(), stage = "hit", hit = res.Instance.Name, found = node.Name, depth = depth, chain = table.concat(chain, " < ") }
			-- 记下 Id：尸体兜底机制靠它认领
			local okId, tid = pcall(function() return node:GetAttribute("Id") end)
			if okId and tid ~= nil then shotHitIds[tostring(tid)] = os.clock() end
			markPending(node)
			return
		end
		node = node.Parent
		depth = depth + 1
	end
	GENV.__MB = { t = os.clock(), stage = "nottarget", hit = res.Instance.Name, chain = table.concat(chain, " < ") }
end

-- ============ 真实子弹命中：ProjectileHit（最可靠的判据） ============
-- ProjectileCaster.ProjectileHit 是子弹真正打到东西时的处理函数，参数是 RaycastResult。
-- 实测：res.Instance 是 _ProjectileBounds，往上爬一层 Parent 就是动物 Model。
-- 它不依赖相机朝向、也不用管动物是否已经被移走 —— 物理上打到了就一定触发。
local function onProjectileHit(res)
	if not res or not res.Instance then return end
	local node = res.Instance
	local depth = 0
	while node and depth < 6 do
		-- 【不能只认 targets】一枪秒杀时动物在子弹命中的同一帧就被移出 Animals，
		-- 而 targets 是 sync() 每 0.5 秒重建的活体表 —— 这一刻里面已经没有它了。
		-- 老写法 targets[node] 判 false 就 continue，爬到顶也找不到，记一次 __PROJ_MISS 走人，
		-- 尸体随后出现却因为 shotHitIds 里没这个 Id 而不被认领 → 「秒死尸体不显示」。
		-- 改成只看 Id 属性：Id 是本作动物的唯一标识（形如 1795262786967-xxx-0），
		-- 骨骼、武器、玩家角色都没有这个属性。
		-- 万一别的东西也有 Id 也不会误标：后续 sweepNearbyCarcasses 只处理
		-- AnimalRagdoll 标签和 DeadAnimals 子级，玩家/model 根本不进这两个集合。
		if node:IsA("Model") then
			local ok, id = pcall(function() return node:GetAttribute("Id") end)
			if ok and id ~= nil then
				shotHitIds[tostring(id)] = os.clock()
				GENV.__MB = { t = os.clock(), stage = "proj", found = node.Name, viaId = true }
				GENV.__PROJ_HITS = (GENV.__PROJ_HITS or 0) + 1
				return
			end
		end
		node = node.Parent
		depth = depth + 1
	end
	GENV.__PROJ_MISS = (GENV.__PROJ_MISS or 0) + 1
end

local projHitInstalled = false
local function installProjectileHit()
	if projHitInstalled then return true end
	local c = findCaster()
	if not c then return false end
	local orig = rawget(c, "ProjectileHit")
	if type(orig) ~= "function" then return false end
	c.ProjectileHit = function(self, res, ...)
		pcall(onProjectileHit, res)
		return orig(self, res, ...)
	end
	projHitInstalled = true
	return true
end
installProjectileHit()
task.delay(2, installProjectileHit)
task.delay(6, installProjectileHit)

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
				if (bt.leadLog or 0) < 40 then
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
			return bt.origFire(self, origin, d.Unit, speed, ...)
		end
	else
		if not ok then bt.lastErr = tostring(res) end
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
			-- 必须用 holder（CoreGui 根）：uiHolder() 返回 CoreGui.RobloxGui，
			-- 那是 Roblox 自己的 GUI 层，ScreenGui 挂进去不渲染，
			-- 结果就是「子追的目标文字/锁定线看不见」。
			local h = holder
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
-- 无条件装：子追关着的时候也要能捕到真实开枪（手动扣扳机也走 caster.Fire），
-- 否则 lastShot 不更新，markPending 的开枪检测会把真打中的也一起丢掉。
-- btFireHook 里已有 `if not CFG.btrack ... return bt.origFire(...)` 分支，子追关时只记录、不干预弹道。
pcall(btInstall)
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
	ringRadius = 120,    -- 已废弃：圈与判定统一用 CFG.btrackFov，这里只留兼容
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
		-- 不在这里记账：headSync 是按住左键时每 0.2 秒跑一次的，
		-- 把 aim.target（=就是连线锁定的那只）反复登记成「开火候选」，
		-- 别人打死它也会被认成我打中的（用户反馈的标蓝）。
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
	-- 锁定半径必须和画出来的圈一致，也要和子追判定一致，否则会出现
	-- 「圈画 120px、实际能锁 300px」这种看着明显不对的情况。
	-- 唯一真源：CFG.btrackFov（面板「准星圈大小」改的就是它）
	local radius = CFG.btrackFov
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
	-- 额外尸体检查：每 CARCASS_SWEEP 秒跑一次
	carcassAcc = carcassAcc + dt
	if carcassAcc >= CARCASS_SWEEP then
		carcassAcc = 0
		pcall(sweepCarcasses)
		-- 独立认领：以玩家为中心 NEARBY_RADIUS 内、未标记过的尸体
		pcall(sweepNearbyCarcasses)
	end
	if GENV.__DAWG_GEN ~= MY_GEN then
		pcall(function() connSync:Disconnect() end)
		connSync = nil
		if headConn then pcall(function() headConn:Disconnect() end) headConn = nil end
		return
	end
	-- 每帧给速度跟踪器喂样本。
	-- 之前只在 btFireHook 里调用 bodyVelocity（=只在开枪那一刻采样），
	-- 两次开枪相隔好几秒，差分算出来的是「这几秒的平均速度」：
	-- 目标从慢走加速到奔跑时，平均值远低于开枪那一刻的真实速度，
	-- 提前量就系统性偏少（用户反馈「奔跑的时候预判还是少了」）。
	-- 放到 Heartbeat 里每帧采一次，开枪时 rec.t 只差 16ms，算的就是瞬时速度。
	for m in pairs(targets) do
		pcall(bodyVelocity, m)
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
		-- 提前量倍数：1.0 = 按「距离/弹速」完整预判。奔跑目标还是打在后面就往上拉。
		sb1:AddSlider("btLead", { Title = "提前量(%)", Default = math.floor((CFG.btrackLead or 1) * 100 + 0.5),
			Min = 0, Max = 300, Rounding = 0,
			Callback = function(v) CFG.btrackLead = (tonumber(v) or 100) / 100 end })

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
		ui:stepper("提前量", 0, 3, 0.1, CFG.btrackLead, function(v) CFG.btrackLead = v end)
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
	-- 圈的半径必须等于判定用的 CFG.btrackFov，否则会出现
	-- 「画出来 120px、实际能锁 300px」这种看着明显不对的情况
	local r = CFG.btrackFov
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
	claimNearby = claimNearbyForce,
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

	-- 悬浮球必须「一定看得见」：移动端 gethui() 常返回隐藏容器（反检测用），
	-- ScreenGui 挂进去虽然 Parent 正常，但屏幕上什么都不显示。
	-- 所以这里优先用真正会渲染的容器：CoreGui → PlayerGui → gethui() 兜底。
	local holder
	do
		local function writable(c)
			if not c then return false end
			local ok = pcall(function()
				local probe = Instance.new("Folder")
				probe.Parent = c
				probe:Destroy()
			end)
			return ok
		end
		local cg = game:GetService("CoreGui")
		local lp = Players.LocalPlayer
		local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
		if writable(cg) then
			holder = cg
		elseif writable(pg) then
			holder = pg
		else
			holder = uiHolder()
		end
	end

	-- 换容器时把旧的搬过来（重载不会出现两个球，也不会因为换了容器就消失）
	local oldGui
	for _, c in ipairs({ game:GetService("CoreGui"), uiHolder() }) do
		pcall(function()
			local g = c:FindFirstChild("DawgHuntFloat")
			if g and g ~= oldGui then oldGui = g end
		end)
	end
	floatGui = holder:FindFirstChild("DawgHuntFloat")
	if not floatGui and oldGui then
		floatGui = oldGui
		pcall(function() floatGui.Parent = holder end)
	end
	if not floatGui then
		floatGui = Kit.new("ScreenGui", {
			Name = "DawgHuntFloat",
			ResetOnSpawn = false,
			DisplayOrder = 20000,
			IgnoreGuiInset = true,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			Enabled = true,
		}, holder)
	end
	-- 强制可见（有些执行器会继承容器的隐藏状态）
	pcall(function() floatGui.Enabled = true end)
	local saved = GENV.__NINJA_BTN_POS
	floatBtn = floatGui:FindFirstChild("Toggle")
	if not floatBtn then
		floatBtn = Kit.new("TextButton", {
			Name = "Toggle",
			Size = UDim2.fromOffset(56, 56),
			Position = (type(saved) == "UDim2") and saved or UDim2.new(1, -76, 0, 96),
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
	pcall(function()
		print(string.format("[悬浮球] 容器=%s Enabled=%s 位置=%s 尺寸=%s",
			tostring(floatGui.Parent and floatGui.Parent:GetFullName()),
			tostring(floatGui.Enabled),
			tostring(floatBtn.Position),
			tostring(floatBtn.Size)))
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
