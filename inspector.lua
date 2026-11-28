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

local TEST_TAG = "RollbackTest03_PostExitConsistency"
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
	lastTokens = "Unknown",
	lastUnitId = "Unknown",
	lastTrait = "N/A",
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
	if #state.logs > 90 then
		table.remove(state.logs, 1)
	end
end

local function readCurrentTrait()
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	local cur = tr and tr:FindFirstChild("CurrentTraitText", true)
	if cur and cur:IsA("TextLabel") and cur.Text ~= "" then
		state.lastTrait = cur.Text
	end
	return state.lastTrait
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end
	local traitNow = readCurrentTrait()
	pcall(function()
		ui.statusLabel.Text = string.format(
			"Zero-Hook | Armed: %s | Tokens: %s | Trait: %s",
			state.armed and "YES" or "NO",
			tostring(state.lastTokens),
			tostring(traitNow)
		)
		ui.summaryBox.Text = table.concat({
			"=== TEST #3: POST-EXIT STATE CONSISTENCY ===",
			"Unit GUID: " .. tostring(state.lastUnitId),
			"Observed Tokens: " .. tostring(state.lastTokens) .. "  |  Current Trait: " .. tostring(traitNow),
		}, "\n")
		ui.armBtn.Text = state.armed and "1. Watch: ON (Click to Pause)" or "1. Start Watch"
		ui.armBtn.BackgroundColor3 = state.armed and C.good or C.accent

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready. Start Watch, do 1 reroll, copy pre-exit report, then Rejoin and check."
	end)
end

local function bindListeners()
	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		local s2c = ep and ep:FindFirstChild("server_to_client")
		if s2c then
			local tokEv = s2c:FindFirstChild("token_trait_reroll_amount_changed")
			if tokEv and tokEv:IsA("RemoteEvent") then
				trackConn(tokEv.OnClientEvent:Connect(function(amount, ...)
					if destroyed or not state.armed then
						return
					end
					state.lastTokens = tostring(amount)
					addLog("TOKEN_SYNC", "token_trait_reroll_amount_changed -> " .. state.lastTokens)
					refreshUI()
				end))
			end

			local traitEv = s2c:FindFirstChild("unit_traits_changed")
			if traitEv and traitEv:IsA("RemoteEvent") then
				trackConn(traitEv.OnClientEvent:Connect(function(unitId, payload, ...)
					if destroyed or not state.armed then
						return
					end
					if unitId ~= nil then
						state.lastUnitId = tostring(unitId)
					end
					local pInfo = typeof(payload) == "table" and "table" or tostring(payload)
					task.defer(function()
						task.wait(0.05)
						local trNow = readCurrentTrait()
						addLog("UNIT_TRAIT_SYNC", string.format("Unit=%s (%s) | Trait=%q | Tokens=%s", state.lastUnitId, pInfo, trNow, state.lastTokens))
						refreshUI()
					end)
				end))
			end
		end
	end

	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	local tr = pg and pg:FindFirstChild("TraitReroll")
	if tr then
		local function hookText(obj)
			if obj:IsA("TextLabel") and obj.Name == "CurrentTraitText" then
				trackConn(obj:GetPropertyChangedSignal("Text"):Connect(function()
					if destroyed or not state.armed then
						return
					end
					state.lastTrait = obj.Text
					addLog("UI_TRAIT", "CurrentTraitText -> " .. tostring(obj.Text))
					refreshUI()
				end))
			end
		end
		for _, d in ipairs(tr:GetDescendants()) do
			hookText(d)
		end
		trackConn(tr.DescendantAdded:Connect(function(d)
			hookText(d)
			if not destroyed and state.armed and d:IsA("TextLabel") and d.Name == "CurrentTraitText" then
				state.lastTrait = d.Text
				addLog("UI_REBUILT", "CurrentTraitText -> " .. tostring(d.Text))
				refreshUI()
			end
		end))
	end

	addLog("INIT", "Test #3 zero-hook listeners ready.")
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
	ui.screenGui.DisplayOrder = 145

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
	title.Text = "TEST #3: POST-EXIT STATE CONSISTENCY"
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

	ui.armBtn = makeBtn("1. Start Watch", 12, 134, 165, C.accent)
	ui.snapBtn = makeBtn("2. Mark Pre-Exit", 183, 134, 155, C.btn)
	ui.copyBtn = makeBtn("Copy Test #3 Log", 344, 134, 144, C.btn)

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
		addLog("STATE", state.armed and "Watch ON: perform 1 reroll." or "Watch PAUSED.")
		refreshUI()
	end))
	trackConn(ui.snapBtn.Activated:Connect(function()
		local tr = readCurrentTrait()
		addLog("PRE_EXIT_MARK", string.format("Unit=%s | Tokens=%s | Trait=%q", state.lastUnitId, state.lastTokens, tr))
		refreshUI()
	end))
	trackConn(ui.copyBtn.Activated:Connect(function()
		local header = {
			"=== TEST #3 REPORT: POST-EXIT STATE CONSISTENCY ===",
			ui.statusLabel.Text,
			ui.summaryBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied Test #3 report." or "Clipboard unavailable.")
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
	bindListeners()
	refreshUI()
end)
