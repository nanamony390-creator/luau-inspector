local function getServiceSafe(name)
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	return ok and svc or nil
end

local Players = getServiceSafe("Players")
local ReplicatedStorage = getServiceSafe("ReplicatedStorage")
local CoreGui = getServiceSafe("CoreGui")
local UserInputService = getServiceSafe("UserInputService")

local TEST_TAG = "RollbackTest01_HypothesisProbe"
local GUARD_KEY = "__TestGuard_" .. TEST_TAG

local connections = {}
local destroyed = false
local ui = {}

local C = {
	bg = Color3.fromRGB(20, 22, 28),
	panel = Color3.fromRGB(15, 17, 22),
	card = Color3.fromRGB(28, 32, 40),
	text = Color3.fromRGB(228, 234, 244),
	dim = Color3.fromRGB(148, 156, 170),
	accent = Color3.fromRGB(54, 96, 148),
	good = Color3.fromRGB(40, 108, 82),
	warn = Color3.fromRGB(142, 92, 38),
	danger = Color3.fromRGB(138, 48, 54),
	btn = Color3.fromRGB(46, 52, 66),
}

local state = {
	armed = false,
	hookActive = false,
	samples = {},
	logs = {},
}

local function trackConn(conn)
	if conn then
		connections[#connections + 1] = conn
	end
	return conn
end

local function findExecutorFn(name)
	local okEnv, env = pcall(function()
		return type(getgenv) == "function" and getgenv() or nil
	end)
	if okEnv and type(env) == "table" and type(env[name]) == "function" then
		return env[name]
	end
	if type(_G) == "table" and type(_G[name]) == "function" then
		return _G[name]
	end
	return nil
end

local function setClipboardSafe(text)
	local fn = findExecutorFn("setclipboard") or findExecutorFn("toclipboard")
	if type(fn) == "function" then
		local ok = pcall(fn, text)
		if ok then
			return true
		end
	end
	return false
end

local function addLog(tag, msg)
	local line = string.format("[%s | %.2fs] %s", tag, os.clock() % 1000, msg)
	state.logs[#state.logs + 1] = line
	if #state.logs > 70 then
		table.remove(state.logs, 1)
	end
end

local function getLiveTraitText()
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	local cur = tr and tr:FindFirstChild("CurrentTraitText", true)
	if cur and cur:IsA("TextLabel") then
		return cur.Text
	end
	return "N/A"
end

local function getEndpointsFolder()
	if not ReplicatedStorage then
		return nil
	end
	local ep = ReplicatedStorage:FindFirstChild("endpoints")
	return ep and ep:FindFirstChild("client_to_server") or nil
end

local function classifyLatency(ms)
	if ms < 110 then
		return "FAST (In-Memory RAM / Async Queue)"
	elseif ms < 260 then
		return "MODERATE (Server Processing / Validation)"
	else
		return "SLOW (Likely Synchronous DataStore Commit)"
	end
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end

	local avgMs = 0
	if #state.samples > 0 then
		local sum = 0
		for _, v in ipairs(state.samples) do
			sum += v.ms
		end
		avgMs = sum / #state.samples
	end

	local verdict = "Awaiting probe execution..."
	if #state.samples > 0 then
		local last = state.samples[#state.samples]
		verdict = string.format("Last: %.1f ms | Avg: %.1f ms -> %s", last.ms, avgMs, classifyLatency(avgMs))
	end

	pcall(function()
		ui.statusLabel.Text = string.format(
			"Hook: %s | Armed: %s | Live Trait: %s",
			state.hookActive and "ACTIVE" or "FALLBACK",
			state.armed and "YES (Listening)" or "NO",
			getLiveTraitText()
		)
		ui.verdictBox.Text = table.concat({
			"=== TEST #1: COMMIT LATENCY & SERVER WRITE PROBE ===",
			"Hypothesis: Does reroll wait for DataStore write or return from RAM?",
			"Samples: " .. tostring(#state.samples) .. "   |   " .. verdict,
		}, "\n")

		ui.armBtn.Text = state.armed and "1. Probe: ARMED (Click to Disarm)" or "1. Arm Reroll Probe"
		ui.armBtn.BackgroundColor3 = state.armed and C.good or C.accent

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready. Run Baseline Ping first, then Arm Probe and do 1 reroll."
	end)
end

local function runBaselinePing()
	local c2s = getEndpointsFolder()
	local fn = c2s and (c2s:FindFirstChild("poll_active_items") or c2s:FindFirstChild("get_current_event"))
	if not (fn and fn:IsA("RemoteFunction")) then
		addLog("BASELINE_ERR", "No safe read-only RemoteFunction found for baseline RTT.")
		refreshUI()
		return
	end

	addLog("BASELINE", "Measuring baseline network RTT via " .. fn.Name .. "...")
	refreshUI()

	task.spawn(function()
		local t0 = os.clock()
		local ok = pcall(function()
			fn:InvokeServer()
		end)
		local dt = (os.clock() - t0) * 1000
		if ok then
			addLog("BASELINE_OK", string.format("Network RTT (%s) = %.1f ms (Pure Server Round-Trip)", fn.Name, dt))
		else
			addLog("BASELINE_WARN", string.format("Call returned error after %.1f ms", dt))
		end
		refreshUI()
	end)
end

local function recordProbeSample(remoteName, ms, beforeTrait, afterTrait)
	state.samples[#state.samples + 1] = {
		name = remoteName,
		ms = ms,
		before = beforeTrait,
		after = afterTrait,
	}
	addLog("PROBE_DATA", string.format("%s took %.1f ms | Trait: %q -> %q | %s", remoteName, ms, beforeTrait, afterTrait, classifyLatency(ms)))
	refreshUI()
end

local function installHooks()
	local hookmetamethodFn = findExecutorFn("hookmetamethod")
	local getnamecallmethodFn = findExecutorFn("getnamecallmethod")
	local checkcallerFn = findExecutorFn("checkcaller")

	if type(hookmetamethodFn) == "function" and type(getnamecallmethodFn) == "function" then
		local oldNamecall
		local ok = pcall(function()
			oldNamecall = hookmetamethodFn(game, "__namecall", function(self, ...)
				local method = getnamecallmethodFn()
				if not destroyed and state.armed and method == "InvokeServer" and typeof(self) == "Instance" and self:IsA("RemoteFunction") then
					local isInternal = type(checkcallerFn) == "function" and checkcallerFn()
					local rName = self.Name
					if not isInternal and (rName == "request_token_trait_reroll" or rName == "reroll_base_stats_all" or rName == "reroll_base_stats_specific") then
						local beforeTrait = getLiveTraitText()
						local t0 = os.clock()
						local results = table.pack(oldNamecall(self, ...))
						local dt = (os.clock() - t0) * 1000
						task.defer(function()
							task.wait(0.15)
							recordProbeSample(rName, dt, beforeTrait, getLiveTraitText())
						end)
						return table.unpack(results, 1, results.n)
					end
				end
				return oldNamecall(self, ...)
			end)
		end)
		if ok and oldNamecall then
			state.hookActive = true
			addLog("HOOK", "Installed __namecall timing probe for reroll endpoints.")
			return
		end
	end

	-- Fallback UI watcher if __namecall hook is unavailable
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	local cur = tr and tr:FindFirstChild("CurrentTraitText", true)
	if cur and cur:IsA("TextLabel") then
		local lastVal = cur.Text
		trackConn(cur:GetPropertyChangedSignal("Text"):Connect(function()
			if destroyed or not state.armed then
				lastVal = cur.Text
				return
			end
			local newVal = cur.Text
			if newVal ~= lastVal then
				addLog("UI_CHANGE", string.format("CurrentTraitText changed: %q -> %q (Fallback mode: no exact RPC RTT)", lastVal, newVal))
				lastVal = newVal
				refreshUI()
			end
		end))
		addLog("FALLBACK", "hookmetamethod unavailable; watching CurrentTraitText changes.")
	end
end

local function cleanupTest()
	if destroyed then
		return
	end
	destroyed = true
	state.armed = false
	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	connections = {}
	if ui.screenGui then
		pcall(function()
			ui.screenGui:Destroy()
		end)
	end
	ui = {}
end

local function buildUI()
	ui.screenGui = Instance.new("ScreenGui")
	ui.screenGui.Name = TEST_TAG
	ui.screenGui.ResetOnSpawn = false
	ui.screenGui.IgnoreGuiInset = true
	ui.screenGui.DisplayOrder = 130

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 500, 0, 390)
	ui.main.Position = UDim2.new(0.5, -250, 0.5, -195)
	ui.main.BackgroundColor3 = C.bg
	ui.main.BorderSizePixel = 0
	ui.main.Parent = ui.screenGui
	Instance.new("UICorner", ui.main).CornerRadius = UDim.new(0, 8)

	ui.dragBar = Instance.new("TextButton")
	ui.dragBar.Size = UDim2.new(1, -80, 0, 32)
	ui.dragBar.Position = UDim2.new(0, 12, 0, 6)
	ui.dragBar.BackgroundTransparency = 1
	ui.dragBar.Text = ""
	ui.dragBar.AutoButtonColor = false
	ui.dragBar.Parent = ui.main

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 1, 0)
	title.BackgroundTransparency = 1
	title.TextColor3 = C.text
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "TEST #1: HYPOTHESIS & COMMIT LATENCY PROBE"
	title.Parent = ui.dragBar

	ui.closeBtn = Instance.new("TextButton")
	ui.closeBtn.Size = UDim2.new(0, 58, 0, 24)
	ui.closeBtn.Position = UDim2.new(1, -68, 0, 10)
	ui.closeBtn.BackgroundColor3 = C.danger
	ui.closeBtn.BorderSizePixel = 0
	ui.closeBtn.TextColor3 = C.text
	ui.closeBtn.Font = Enum.Font.SourceSansSemibold
	ui.closeBtn.TextSize = 12
	ui.closeBtn.Text = "Close"
	ui.closeBtn.Parent = ui.main
	Instance.new("UICorner", ui.closeBtn).CornerRadius = UDim.new(0, 5)

	ui.statusLabel = Instance.new("TextLabel")
	ui.statusLabel.Size = UDim2.new(1, -24, 0, 20)
	ui.statusLabel.Position = UDim2.new(0, 12, 0, 38)
	ui.statusLabel.BackgroundTransparency = 1
	ui.statusLabel.TextColor3 = C.dim
	ui.statusLabel.Font = Enum.Font.SourceSansSemibold
	ui.statusLabel.TextSize = 12
	ui.statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	ui.statusLabel.Parent = ui.main

	ui.verdictBox = Instance.new("TextLabel")
	ui.verdictBox.Size = UDim2.new(1, -24, 0, 64)
	ui.verdictBox.Position = UDim2.new(0, 12, 0, 62)
	ui.verdictBox.BackgroundColor3 = C.card
	ui.verdictBox.BorderSizePixel = 0
	ui.verdictBox.TextColor3 = C.text
	ui.verdictBox.Font = Enum.Font.Code
	ui.verdictBox.TextSize = 12
	ui.verdictBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.verdictBox.TextYAlignment = Enum.TextYAlignment.Top
	ui.verdictBox.TextWrapped = true
	ui.verdictBox.Parent = ui.main
	Instance.new("UICorner", ui.verdictBox).CornerRadius = UDim.new(0, 6)
	local p1 = Instance.new("UIPadding", ui.verdictBox)
	p1.PaddingLeft = UDim.new(0, 8)
	p1.PaddingTop = UDim.new(0, 6)

	local function makeBtn(label, x, y, w, bg)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, w, 0, 28)
		b.Position = UDim2.new(0, x, 0, y)
		b.BackgroundColor3 = bg
		b.BorderSizePixel = 0
		b.TextColor3 = C.text
		b.Font = Enum.Font.SourceSansSemibold
		b.TextSize = 12
		b.Text = label
		b.Parent = ui.main
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
		return b
	end

	ui.armBtn = makeBtn("1. Arm Reroll Probe", 12, 134, 180, C.accent)
	ui.pingBtn = makeBtn("2. Measure Baseline Ping", 198, 134, 150, C.btn)
	ui.copyBtn = makeBtn("Copy Test Log", 354, 134, 134, C.btn)

	ui.logBox = Instance.new("TextBox")
	ui.logBox.Size = UDim2.new(1, -24, 0, 210)
	ui.logBox.Position = UDim2.new(0, 12, 0, 170)
	ui.logBox.BackgroundColor3 = C.panel
	ui.logBox.BorderSizePixel = 0
	ui.logBox.TextColor3 = C.text
	ui.logBox.Font = Enum.Font.Code
	ui.logBox.TextSize = 11
	ui.logBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.logBox.TextYAlignment = Enum.TextYAlignment.Top
	ui.logBox.TextWrapped = true
	ui.logBox.TextEditable = false
	ui.logBox.ClearTextOnFocus = false
	ui.logBox.Parent = ui.main
	Instance.new("UICorner", ui.logBox).CornerRadius = UDim.new(0, 6)
	local p2 = Instance.new("UIPadding", ui.logBox)
	p2.PaddingLeft = UDim.new(0, 8)
	p2.PaddingTop = UDim.new(0, 6)
end

local function bindEvents()
	trackConn(ui.closeBtn.Activated:Connect(cleanupTest))
	trackConn(ui.armBtn.Activated:Connect(function()
		state.armed = not state.armed
		addLog("STATE", state.armed and "Probe ARMED: perform 1 Trait Reroll now." or "Probe DISARMED.")
		refreshUI()
	end))
	trackConn(ui.pingBtn.Activated:Connect(runBaselinePing))
	trackConn(ui.copyBtn.Activated:Connect(function()
		local header = {
			"=== TEST #1 REPORT: COMMIT LATENCY PROBE ===",
			ui.statusLabel.Text,
			ui.verdictBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied Test #1 report to clipboard." or "Clipboard unavailable.")
		refreshUI()
	end))

	if UserInputService then
		local dragging = false
		local dragStart, startPos
		trackConn(ui.dragBar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = ui.main.Position
			end
		end))
		trackConn(UserInputService.InputChanged:Connect(function(input)
			if dragging and dragStart and startPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				ui.main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end))
		trackConn(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))
	end
end

local prev = type(_G) == "table" and _G[GUARD_KEY] or nil
if type(prev) == "table" and type(prev.destroy) == "function" then
	pcall(prev.destroy)
end
pcall(function()
	if type(_G) == "table" then
		_G[GUARD_KEY] = { destroy = cleanupTest }
	end
end)

task.defer(function()
	local parent = nil
	if typeof(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then
			parent = h
		end
	end
	if not parent then
		parent = CoreGui or (Players and Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui"))
	end
	if not parent then
		return
	end

	buildUI()
	bindEvents()
	ui.screenGui.Parent = parent
	installHooks()
	refreshUI()
end)
