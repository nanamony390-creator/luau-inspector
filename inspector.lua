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

local TEST_TAG = "RollbackTest02_CleanNoHook"
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
	danger = Color3.fromRGB(138, 48, 54),
	btn = Color3.fromRGB(46, 52, 66),
}

local state = {
	armed = false,
	eventsCount = 0,
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
	if type(fn) == "function" and pcall(fn, text) then
		return true
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

local function readLiveState()
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	if not tr then
		return "TraitReroll=Closed", "N/A"
	end

	local traitVal = "N/A"
	local cur = tr:FindFirstChild("CurrentTraitText", true)
	if cur and cur:IsA("TextLabel") then
		traitVal = cur.Text
	end

	local tokenInfo = {}
	for _, d in ipairs(tr:GetDescendants()) do
		if d:IsA("TextLabel") and (d.Name == "Quantity" or d.Name == "Amount") then
			local pName = d.Parent and d.Parent.Parent and d.Parent.Parent.Name or "?"
			if string.find(string.lower(pName), "reroll") or string.find(string.lower(pName), "token") then
				tokenInfo[#tokenInfo + 1] = pName .. ":" .. tostring(d.Text)
			end
		end
	end

	local summary = "Trait=" .. tostring(traitVal)
	if #tokenInfo > 0 then
		summary = summary .. " | " .. table.concat(tokenInfo, ", ")
	end
	return summary, traitVal
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end
	local summary, traitOnly = readLiveState()
	pcall(function()
		ui.statusLabel.Text = string.format("Mode: ZERO-HOOK SAFE | Armed: %s | Events: %d | Trait: %s", state.armed and "YES" or "NO", state.eventsCount, tostring(traitOnly))
		ui.summaryBox.Text = table.concat({
			"=== TEST #2 (CLEAN): S2C EVENT & UI SYNC TIMING ===",
			"Zero hooks installed. Measures exact server event arrival vs UI update.",
			"Live: " .. summary,
		}, "\n")
		ui.armBtn.Text = state.armed and "1. Listener: ON (Click to Pause)" or "1. Start Clean Listener"
		ui.armBtn.BackgroundColor3 = state.armed and C.good or C.accent

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready. Click Start Clean Listener, then do 1 normal Trait Reroll."
	end)
end

local function bindSafeListeners()
	-- 1. Official server_to_client RemoteEvents (passive read-only)
	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		local s2c = ep and ep:FindFirstChild("server_to_client")
		if s2c then
			for _, child in ipairs(s2c:GetChildren()) do
				if child:IsA("RemoteEvent") and (string.find(child.Name, "reroll") or string.find(child.Name, "trait") or string.find(child.Name, "unit")) then
					trackConn(child.OnClientEvent:Connect(function(...)
						if destroyed or not state.armed then
							return
						end
						state.eventsCount += 1
						local args = table.pack(...)
						local parts = {}
						for i = 1, math.min(args.n, 4) do
							parts[#parts + 1] = tostring(args[i])
						end
						addLog("S2C_EVENT", string.format("%s -> [%s] | Live: %s", child.Name, table.concat(parts, ", "), select(1, readLiveState())))
						refreshUI()
					end))
				end
			end
		end
	end

	-- 2. Passive GUI property listener
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	if tr then
		local function watchLabel(lbl)
			if lbl:IsA("TextLabel") and (lbl.Name == "CurrentTraitText" or lbl.Name == "Quantity" or lbl.Name == "Amount") then
				local last = lbl.Text
				trackConn(lbl:GetPropertyChangedSignal("Text"):Connect(function()
					if destroyed or not state.armed then
						last = lbl.Text
						return
					end
					local now = lbl.Text
					if now ~= last then
						state.eventsCount += 1
						addLog("UI_TEXT", string.format("%s: %q -> %q", lbl.Name, last, now))
						last = now
						refreshUI()
					end
				end))
			end
		end
		for _, d in ipairs(tr:GetDescendants()) do
			watchLabel(d)
		end
		trackConn(tr.DescendantAdded:Connect(function(d)
			watchLabel(d)
			if not destroyed and state.armed and d:IsA("TextLabel") and d.Name == "CurrentTraitText" then
				state.eventsCount += 1
				addLog("UI_REBUILT", "CurrentTraitText recreated with value: " .. tostring(d.Text))
				refreshUI()
			end
		end))
	end
	addLog("INIT", "Clean passive listeners attached (0 hooks).")
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
	ui.screenGui.DisplayOrder = 140

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
	title.Text = "TEST #2 (CLEAN): S2C EVENT & UI SYNC"
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

	ui.armBtn = makeBtn("1. Start Clean Listener", 12, 134, 180, C.accent)
	ui.snapBtn = makeBtn("2. Snapshot State", 198, 134, 140, C.btn)
	ui.copyBtn = makeBtn("Copy Clean Log", 344, 134, 144, C.btn)

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
		addLog("STATE", state.armed and "Listener ON: perform 1 Trait Reroll now." or "Listener PAUSED.")
		refreshUI()
	end))
	trackConn(ui.snapBtn.Activated:Connect(function()
		addLog("SNAP", select(1, readLiveState()))
		refreshUI()
	end))
	trackConn(ui.copyBtn.Activated:Connect(function()
		local header = {
			"=== TEST #2 CLEAN REPORT (ZERO HOOKS) ===",
			ui.statusLabel.Text,
			ui.summaryBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied Clean Log." or "Clipboard unavailable.")
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
	bindSafeListeners()
	refreshUI()
end)
