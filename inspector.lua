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

local TEST_TAG = "RollbackTest02_StateVsUI"
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
	rerollCount = 0,
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
	if #state.logs > 80 then
		table.remove(state.logs, 1)
	end
end

local function getTraitGuiSnapshot()
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	if not tr then
		return "TraitReroll=MISSING", "N/A"
	end

	local traitVal = "N/A"
	local cur = tr:FindFirstChild("CurrentTraitText", true)
	if cur and cur:IsA("TextLabel") then
		traitVal = cur.Text
	end

	local qtyList = {}
	for _, d in ipairs(tr:GetDescendants()) do
		if d:IsA("TextLabel") and (d.Name == "Quantity" or d.Name == "Amount" or string.find(string.lower(d.Name), "token")) then
			if d.Text ~= "" and d.Text ~= "Qt." then
				qtyList[#qtyList + 1] = d.Name .. "=" .. tostring(d.Text)
			end
		end
	end

	local qtySummary = (#qtyList > 0) and table.concat(qtyList, ", ") or "NoQtyLabel"
	return "Trait=" .. tostring(traitVal) .. " | " .. qtySummary, traitVal
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end
	local snapText, traitOnly = getTraitGuiSnapshot()
	pcall(function()
		ui.statusLabel.Text = string.format("Armed: %s | Rerolls: %d | Live Trait: %s", state.armed and "YES" or "NO", state.rerollCount, tostring(traitOnly))
		ui.summaryBox.Text = table.concat({
			"=== TEST #2: DELAYED UI & TOKEN STATE CORRELATION ===",
			"Hypothesis: Does reroll update tokens/state even when CurrentTraitText looks unchanged?",
			"Snapshot: " .. snapText,
		}, "\n")
		ui.armBtn.Text = state.armed and "1. Probe: ARMED (Click to Disarm)" or "1. Arm State Watcher"
		ui.armBtn.BackgroundColor3 = state.armed and C.good or C.accent

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready. Arm watcher, perform 1 Trait Reroll, and wait ~2s."
	end)
end

local function monitorRerollWindow(sourceName)
	state.rerollCount += 1
	local idx = state.rerollCount
	local snapBefore = select(1, getTraitGuiSnapshot())
	addLog("WINDOW_START", string.format("#%d via %s | Before: [%s]", idx, sourceName, snapBefore))
	refreshUI()

	task.spawn(function()
		local tStart = os.clock()
		local lastSnap = snapBefore
		for step = 1, 6 do
			task.wait(0.5)
			if destroyed then
				return
			end
			local curSnap = select(1, getTraitGuiSnapshot())
			if curSnap ~= lastSnap then
				local dtMs = (os.clock() - tStart) * 1000
				addLog("STATE_SHIFT", string.format("#%d at +%.0fms: [%s] -> [%s]", idx, dtMs, lastSnap, curSnap))
				lastSnap = curSnap
				refreshUI()
			end
		end
		if lastSnap == snapBefore then
			addLog("NO_UI_DIFF", string.format("#%d after 3.0s: GUI labels showed no text change [%s]", idx, snapBefore))
			refreshUI()
		end
	end)
end

local function installWatchers()
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
						task.defer(function()
							monitorRerollWindow(rName)
						end)
					end
				end
				return oldNamecall(self, ...)
			end)
		end)
		if ok and oldNamecall then
			addLog("HOOK", "Watching InvokeServer on reroll endpoints over a 3.0s window.")
		end
	end

	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		local s2c = ep and ep:FindFirstChild("server_to_client")
		if s2c then
			for _, evName in ipairs({ "token_trait_reroll_amount_changed", "token_curse_reroll_amount_changed", "unit_unique_data_changed" }) do
				local ev = s2c:FindFirstChild(evName)
				if ev and ev:IsA("RemoteEvent") then
					trackConn(ev.OnClientEvent:Connect(function(...)
						if not destroyed and state.armed then
							local args = table.pack(...)
							local preview = {}
							for i = 1, math.min(args.n, 3) do
								preview[#preview + 1] = tostring(args[i])
							end
							addLog("S2C_EVENT", evName .. " fired | args=" .. table.concat(preview, ", "))
							refreshUI()
						end
					end))
				end
			end
		end
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
	ui.screenGui.DisplayOrder = 135

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
	title.Text = "TEST #2: DELAYED UI & STATE CORRELATION"
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

	ui.summaryBox = Instance.new("TextLabel")
	ui.summaryBox.Size = UDim2.new(1, -24, 0, 64)
	ui.summaryBox.Position = UDim2.new(0, 12, 0, 62)
	ui.summaryBox.BackgroundColor3 = C.card
	ui.summaryBox.BorderSizePixel = 0
	ui.summaryBox.TextColor3 = C.text
	ui.summaryBox.Font = Enum.Font.Code
	ui.summaryBox.TextSize = 12
	ui.summaryBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.summaryBox.TextYAlignment = Enum.TextYAlignment.Top
	ui.summaryBox.TextWrapped = true
	ui.summaryBox.Parent = ui.main
	Instance.new("UICorner", ui.summaryBox).CornerRadius = UDim.new(0, 6)
	local p1 = Instance.new("UIPadding", ui.summaryBox)
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

	ui.armBtn = makeBtn("1. Arm State Watcher", 12, 134, 180, C.accent)
	ui.snapBtn = makeBtn("2. Read GUI Now", 198, 134, 140, C.btn)
	ui.copyBtn = makeBtn("Copy Test #2 Log", 344, 134, 144, C.btn)

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
		addLog("STATE", state.armed and "Watcher ARMED: perform 1 Trait Reroll and wait 3s." or "Watcher DISARMED.")
		refreshUI()
	end))
	trackConn(ui.snapBtn.Activated:Connect(function()
		local snap = select(1, getTraitGuiSnapshot())
		addLog("READ_NOW", snap)
		refreshUI()
	end))
	trackConn(ui.copyBtn.Activated:Connect(function()
		local header = {
			"=== TEST #2 REPORT: DELAYED UI & STATE CORRELATION ===",
			ui.statusLabel.Text,
			ui.summaryBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied Test #2 log." or "Clipboard unavailable.")
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
	installWatchers()
	refreshUI()
end)
