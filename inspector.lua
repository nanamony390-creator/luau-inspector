local function getServiceSafe(name)
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	return ok and svc or nil
end

local Players = getServiceSafe("Players")
local ReplicatedStorage = getServiceSafe("ReplicatedStorage")
local TeleportService = getServiceSafe("TeleportService")
local CoreGui = getServiceSafe("CoreGui")
local UserInputService = getServiceSafe("UserInputService")
local HttpService = getServiceSafe("HttpService")

local APP_TAG = "RollbackLab_v4_0_AutoLoad"
local GUARD_KEY = "__LiveTrialGuard_" .. APP_TAG
local STATE_FILE = "RollbackLab_v4_0_State.json"
local SCRIPT_SOURCE_FILE = "RollbackLab_v4_0_Runner.lua"

local connections = {}
local destroyed = false
local ui = {}

local C = {
	bg = Color3.fromRGB(16, 18, 24),
	panel = Color3.fromRGB(12, 14, 19),
	card = Color3.fromRGB(24, 28, 36),
	text = Color3.fromRGB(235, 240, 250),
	dim = Color3.fromRGB(145, 154, 168),
	accent = Color3.fromRGB(48, 96, 158),
	good = Color3.fromRGB(36, 116, 84),
	warn = Color3.fromRGB(176, 104, 32),
	danger = Color3.fromRGB(162, 46, 52),
	btn = Color3.fromRGB(42, 48, 62),
}

local state = {
	rollbackActive = false,
	autoLoadOnTp = true,
	exitMethod = "TELEPORT", -- TELEPORT | KICK_TP | SHUTDOWN
	unitGuid = "Unknown",
	unitName = "Unknown",
	liveTrait = "N/A",
	liveTokens = "Unknown",
	savedBase = nil,
	pendingConfirm = false,
	verdict = "v4.0 Ready: Toggle [1. Activate Rollback] before rolling, then [2. Confirm Rollback].",
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
	return type(fn) == "function" and pcall(fn, text) or false
end

local function writeJsonSafe(filename, tbl)
	local writeFn = findExecutorFn("writefile")
	if type(writeFn) == "function" and HttpService then
		local okEnc, json = pcall(function()
			return HttpService:JSONEncode(tbl)
		end)
		if okEnc and json then
			return pcall(writeFn, filename, json)
		end
	end
	return false
end

local function readJsonSafe(filename)
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	if type(readFn) == "function" and HttpService then
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, filename)
			if not (okEx and ex) then
				return nil
			end
		end
		local okRead, raw = pcall(readFn, filename)
		if okRead and type(raw) == "string" and raw ~= "" then
			local okDec, tbl = pcall(function()
				return HttpService:JSONDecode(raw)
			end)
			if okDec and type(tbl) == "table" then
				return tbl
			end
		end
	end
	return nil
end

local function addLog(tag, msg)
	local line = string.format("[%s | %.2fs] %s", tag, os.clock() % 1000, tostring(msg))
	state.logs[#state.logs + 1] = line
	if #state.logs > 140 then
		table.remove(state.logs, 1)
	end
end

local function persistStateNow()
	writeJsonSafe(STATE_FILE, {
		rollbackActive = state.rollbackActive,
		autoLoadOnTp = state.autoLoadOnTp,
		exitMethod = state.exitMethod,
		unitGuid = state.unitGuid,
		unitName = state.unitName,
		savedBase = state.savedBase,
		pendingConfirm = state.pendingConfirm,
		verdict = state.verdict,
	})
end

local function armAutoLoadQueue()
	if not state.autoLoadOnTp then
		return false
	end
	local queueFn = findExecutorFn("queue_on_teleport") or findExecutorFn("queueonteleport")
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	if type(queueFn) ~= "function" then
		return false
	end

	local runnerCode = nil
	if type(readFn) == "function" then
		local exists = true
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, SCRIPT_SOURCE_FILE)
			exists = okEx and ex
		end
		if exists then
			local okR, src = pcall(readFn, SCRIPT_SOURCE_FILE)
			if okR and type(src) == "string" and #src > 50 then
				runnerCode = src
			end
		end
	end

	if not runnerCode then
		runnerCode = [[
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(1.5)
local rf = (type(getgenv)=="function" and getgenv().readfile) or readfile
local ifn = (type(getgenv)=="function" and getgenv().isfile) or isfile
if type(rf)=="function" then
	local okEx = (type(ifn)~="function") or pcall(ifn, "RollbackLab_v4_0_Runner.lua")
	if okEx then
		local okC, code = pcall(rf, "RollbackLab_v4_0_Runner.lua")
		if okC and type(code)=="string" and #code > 50 then
			local fn = loadstring(code)
			if type(fn)=="function" then pcall(fn) end
		end
	end
end
]]
	end

	local okQ = pcall(queueFn, runnerCode)
	return okQ
end

local function scanGuiState()
	local lp = Players and Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end

	local tr = pg:FindFirstChild("TraitReroll")
	if tr then
		local cur = tr:FindFirstChild("CurrentTraitText", true)
		if cur and cur:IsA("TextLabel") and cur.Text ~= "" then
			state.liveTrait = cur.Text
		end

		local recv = tr:FindFirstChild("ReceiveUnit", true)
		if recv then
			local nameLbl = recv:FindFirstChild("name", true)
			if nameLbl and nameLbl:IsA("TextLabel") and nameLbl.Text ~= "" and nameLbl.Text ~= "???" then
				state.unitName = nameLbl.Text
			end
			for _, attrKey in ipairs({ "GUID", "guid", "UnitGUID", "UniqueId", "id" }) do
				local v = recv:GetAttribute(attrKey)
				if type(v) == "string" and #v > 10 then
					state.unitGuid = v
					break
				end
			end
		end

		local utf = tr:FindFirstChild("UseTokenFrame", true)
		if utf then
			for _, d in ipairs(utf:GetDescendants()) do
				if d:IsA("TextLabel") and string.find(d.Text, "/") then
					local num = string.match(d.Text, "^(%d+)%s*/")
					if num then
						state.liveTokens = num
						break
					end
				end
			end
		end
	end
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end
	pcall(scanGuiState)
	pcall(function()
		ui.statusLabel.Text = string.format(
			"v4.0 Engine | Rollback:%s | AutoLoad:%s | Cut:%s",
			state.rollbackActive and "ACTIVE" or "OFF",
			state.autoLoadOnTp and "ON" or "OFF",
			state.exitMethod
		)

		local baseStr = "None"
		if state.savedBase then
			baseStr = string.format("%s | Tok=%s", tostring(state.savedBase.trait), tostring(state.savedBase.tokens))
		end

		ui.boardBox.Text = table.concat({
			string.format("Unit: %s | GUID: %s", tostring(state.unitName), tostring(state.unitGuid)),
			string.format("Live: [%s | Tok=%s]   ||   Armed Base: [%s]", tostring(state.liveTrait), tostring(state.liveTokens), baseStr),
			state.verdict,
		}, "\n")

		ui.activateBtn.Text = state.rollbackActive and "1. Rollback: ACTIVE" or "1. Activate Rollback"
		ui.activateBtn.BackgroundColor3 = state.rollbackActive and C.warn or C.accent

		ui.autoLoadBtn.Text = state.autoLoadOnTp and "Auto-Load: ON" or "Auto-Load: OFF"
		ui.autoLoadBtn.BackgroundColor3 = state.autoLoadOnTp and C.good or C.btn
		ui.modeBtn.Text = "Cut: " .. state.exitMethod

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready."
	end)
end

local function toggleActivateRollback()
	pcall(scanGuiState)
	if not state.rollbackActive then
		state.rollbackActive = true
		state.pendingConfirm = false
		state.savedBase = {
			unitGuid = tostring(state.unitGuid),
			unitName = tostring(state.unitName),
			trait = tostring(state.liveTrait),
			tokens = tostring(state.liveTokens),
			armedAt = os.time(),
		}
		local queued = armAutoLoadQueue()
		persistStateNow()
		state.verdict = string.format(
			"ROLLBACK ACTIVATED (AutoLoad:%s): Base=[%s, Tok=%s]. Roll manually, then click Confirm Rollback!",
			queued and "QUEUED" or "READY",
			state.savedBase.trait,
			state.savedBase.tokens
		)
		addLog("ACTIVATE", state.verdict)
	else
		state.rollbackActive = false
		state.pendingConfirm = false
		persistStateNow()
		state.verdict = "Rollback deactivated."
		addLog("DEACTIVATE", state.verdict)
	end
	refreshUI()
end

local function executeSessionCut()
	local lp = Players and Players.LocalPlayer
	if state.exitMethod == "TELEPORT" then
		if TeleportService and lp then
			pcall(function()
				TeleportService:Teleport(game.PlaceId, lp)
			end)
		end
	elseif state.exitMethod == "KICK_TP" then
		if TeleportService and lp then
			task.spawn(function()
				pcall(function()
					TeleportService:Teleport(game.PlaceId, lp)
				end)
			end)
			task.wait(0.02)
			pcall(function()
				lp:Kick("RollbackLab v4.0 Confirm Rollback")
			end)
		end
	elseif state.exitMethod == "SHUTDOWN" then
		pcall(function()
			game:Shutdown()
		end)
	end
end

local function confirmRollbackNow()
	pcall(scanGuiState)
	if not state.savedBase then
		state.savedBase = {
			unitGuid = tostring(state.unitGuid),
			unitName = tostring(state.unitName),
			trait = tostring(state.liveTrait),
			tokens = tostring(state.liveTokens),
			armedAt = os.time(),
		}
	end
	state.pendingConfirm = true
	local queued = armAutoLoadQueue()
	persistStateNow()

	addLog(
		"CONFIRM",
		string.format(
			"Confirm Rollback pressed! Base=[%s, Tok=%s] -> Now=[%s, Tok=%s] | AutoLoad=%s | Cut=%s",
			tostring(state.savedBase.trait),
			tostring(state.savedBase.tokens),
			tostring(state.liveTrait),
			tostring(state.liveTokens),
			tostring(queued),
			state.exitMethod
		)
	)
	refreshUI()
	executeSessionCut()
end

local function evaluatePostSession()
	pcall(scanGuiState)
	if not state.savedBase then
		return
	end
	local preTrait = tostring(state.savedBase.trait)
	local nowTrait = tostring(state.liveTrait)
	local preTok = tostring(state.savedBase.tokens)
	local nowTok = tostring(state.liveTokens)

	if preTrait == nowTrait and (preTok == "Unknown" or preTok == nowTok) then
		state.verdict = string.format("ROLLBACK RESULT: RESTORED [%s | Tok=%s]", preTrait, preTok)
	else
		state.verdict = string.format("ROLLBACK RESULT: SERVER COMMITTED [%s, Tok=%s] (Was [%s, Tok=%s])", nowTrait, nowTok, preTrait, preTok)
	end
	state.pendingConfirm = false
	state.rollbackActive = false
	persistStateNow()
	addLog("POST_LOAD", state.verdict)
end

local function bindPassiveWatchers()
	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		local s2c = ep and ep:FindFirstChild("server_to_client")
		if s2c then
			local tokEv = s2c:FindFirstChild("token_trait_reroll_amount_changed")
			if tokEv and tokEv:IsA("RemoteEvent") then
				trackConn(tokEv.OnClientEvent:Connect(function(amount)
					if destroyed then
						return
					end
					state.liveTokens = tostring(amount)
					addLog("S2C_TOKEN", "Tokens = " .. state.liveTokens)
					refreshUI()
				end))
			end

			local traitEv = s2c:FindFirstChild("unit_traits_changed")
			if traitEv and traitEv:IsA("RemoteEvent") then
				trackConn(traitEv.OnClientEvent:Connect(function(unitId)
					if destroyed then
						return
					end
					if unitId ~= nil then
						state.unitGuid = tostring(unitId)
					end
					task.defer(function()
						task.wait(0.05)
						pcall(scanGuiState)
						addLog("ROLL_EVENT", string.format("Trait=%q | Tokens=%s", state.liveTrait, state.liveTokens))
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
		local function watchText(obj)
			if obj:IsA("TextLabel") and obj.Name == "CurrentTraitText" then
				trackConn(obj:GetPropertyChangedSignal("Text"):Connect(function()
					if destroyed then
						return
					end
					state.liveTrait = obj.Text
					refreshUI()
				end))
			end
		end
		for _, d in ipairs(tr:GetDescendants()) do
			watchText(d)
		end
		trackConn(tr.DescendantAdded:Connect(function(d)
			watchText(d)
			if not destroyed and d:IsA("TextLabel") and d.Name == "CurrentTraitText" then
				state.liveTrait = d.Text
				refreshUI()
			end
		end))
	end
end

local function cleanupApp()
	if destroyed then
		return
	end
	destroyed = true
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

local function bindSafeClick(btn, fn)
	trackConn(btn.MouseButton1Click:Connect(function()
		local ok, err = pcall(fn)
		if not ok then
			addLog("ERR", tostring(err))
			refreshUI()
		end
	end))
end

local function buildUI()
	ui.screenGui = Instance.new("ScreenGui")
	ui.screenGui.Name = APP_TAG
	ui.screenGui.ResetOnSpawn = false
	ui.screenGui.IgnoreGuiInset = true
	ui.screenGui.DisplayOrder = 200

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 580, 0, 445)
	ui.main.Position = UDim2.new(0.5, -290, 0.5, -222)
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
	title.Text = "ROLLBACK LAB v4.0 — ROLLBACK + AUTO-LOAD ENGINE"
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

	ui.boardBox = Instance.new("TextLabel")
	ui.boardBox.Size = UDim2.new(1, -24, 0, 74)
	ui.boardBox.Position = UDim2.new(0, 12, 0, 62)
	ui.boardBox.BackgroundColor3 = C.card
	ui.boardBox.BorderSizePixel = 0
	ui.boardBox.TextColor3 = C.text
	ui.boardBox.Font = Enum.Font.Code
	ui.boardBox.TextSize = 12
	ui.boardBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.boardBox.TextYAlignment = Enum.TextYAlignment.Top
	ui.boardBox.TextWrapped = true
	ui.boardBox.Parent = ui.main
	Instance.new("UICorner", ui.boardBox).CornerRadius = UDim.new(0, 6)
	local p1 = Instance.new("UIPadding", ui.boardBox)
	p1.PaddingLeft = UDim.new(0, 8)
	p1.PaddingTop = UDim.new(0, 6)

	local function makeBtn(label, x, y, w, bg)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, w, 0, 30)
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

	ui.activateBtn = makeBtn("1. Activate Rollback", 12, 144, 156, C.accent)
	ui.confirmBtn = makeBtn("2. Confirm Rollback", 174, 144, 156, C.danger)
	ui.autoLoadBtn = makeBtn("Auto-Load: ON", 336, 144, 114, C.good)
	ui.modeBtn = makeBtn("Cut: TELEPORT", 456, 144, 112, C.btn)

	ui.copyBtn = makeBtn("Copy v4.0 Report", 12, 180, 556, C.btn)

	ui.logBox = Instance.new("TextBox")
	ui.logBox.Size = UDim2.new(1, -24, 0, 216)
	ui.logBox.Position = UDim2.new(0, 12, 0, 216)
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
	bindSafeClick(ui.closeBtn, cleanupApp)
	bindSafeClick(ui.activateBtn, toggleActivateRollback)
	bindSafeClick(ui.confirmBtn, confirmRollbackNow)

	bindSafeClick(ui.autoLoadBtn, function()
		state.autoLoadOnTp = not state.autoLoadOnTp
		if state.autoLoadOnTp then
			armAutoLoadQueue()
		end
		persistStateNow()
		addLog("AUTOLOAD", "Auto-Load on teleport/rejoin = " .. tostring(state.autoLoadOnTp))
		refreshUI()
	end)

	local methods = { "TELEPORT", "KICK_TP", "SHUTDOWN" }
	bindSafeClick(ui.modeBtn, function()
		local idx = 1
		for i, m in ipairs(methods) do
			if m == state.exitMethod then
				idx = (i % #methods) + 1
				break
			end
		end
		state.exitMethod = methods[idx]
		persistStateNow()
		addLog("CONFIG", "Cut mode -> " .. state.exitMethod)
		refreshUI()
	end)

	bindSafeClick(ui.copyBtn, function()
		pcall(scanGuiState)
		local header = {
			"=== ROLLBACK LAB v4.0 — AUTO-LOAD REPORT ===",
			ui.statusLabel.Text,
			ui.boardBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied v4.0 report to clipboard." or "Clipboard unavailable.")
		refreshUI()
	end)

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
		_G[GUARD_KEY] = { destroy = cleanupApp }
	end
end)

task.defer(function()
	local writeFn = findExecutorFn("writefile")
	local okSrc, src = pcall(function()
		return debug and debug.info and debug.info(1, "s")
	end)
	if type(writeFn) == "function" and type(src) == "string" and string.sub(src, 1, 1) == "@" then
		local readFn = findExecutorFn("readfile")
		if type(readFn) == "function" then
			local okR, rawSelf = pcall(readFn, string.sub(src, 2))
			if okR and type(rawSelf) == "string" and #rawSelf > 100 then
				pcall(writeFn, SCRIPT_SOURCE_FILE, rawSelf)
			end
		end
	end

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
	bindPassiveWatchers()
	pcall(scanGuiState)

	local saved = readJsonSafe(STATE_FILE)
	if type(saved) == "table" then
		state.autoLoadOnTp = (saved.autoLoadOnTp ~= false)
		if type(saved.exitMethod) == "string" then
			state.exitMethod = saved.exitMethod
		end
		if type(saved.savedBase) == "table" then
			state.savedBase = saved.savedBase
			if saved.savedBase.unitGuid and saved.savedBase.unitGuid ~= "Unknown" then
				state.unitGuid = saved.savedBase.unitGuid
			end
		end
		if saved.pendingConfirm then
			evaluatePostSession()
		end
	end

	if state.autoLoadOnTp then
		armAutoLoadQueue()
	end

	addLog("BOOT", "RollbackLab v4.0 initialized with Auto-Load support.")
	refreshUI()
end)
