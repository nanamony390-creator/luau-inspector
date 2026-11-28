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

local APP_TAG = "RollbackLab_ManualGate_v2_2"
local GUARD_KEY = "__LiveTrialGuard_" .. APP_TAG
local CHECKPOINT_FILE = "RollbackLab_v2_2_Checkpoint.json"

local connections = {}
local destroyed = false
local ui = {}

local C = {
	bg = Color3.fromRGB(18, 20, 26),
	panel = Color3.fromRGB(13, 15, 20),
	card = Color3.fromRGB(26, 30, 38),
	text = Color3.fromRGB(232, 238, 248),
	dim = Color3.fromRGB(148, 156, 170),
	accent = Color3.fromRGB(52, 98, 156),
	good = Color3.fromRGB(38, 114, 84),
	warn = Color3.fromRGB(168, 102, 34),
	danger = Color3.fromRGB(154, 48, 54),
	btn = Color3.fromRGB(44, 50, 64),
}

local state = {
	rollbackArmed = false,
	unitGuid = "Unknown",
	unitName = "Unknown",
	liveTrait = "N/A",
	liveTokens = "Unknown",
	armedBaseline = nil,
	verdict = "Step 1: Click [1. Arm Rollback] BEFORE rolling, then roll manually.",
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

local function writeCheckpointFile(dataTable)
	local writeFn = findExecutorFn("writefile")
	if type(writeFn) == "function" and HttpService then
		local okEnc, json = pcall(function()
			return HttpService:JSONEncode(dataTable)
		end)
		if okEnc and json then
			return pcall(writeFn, CHECKPOINT_FILE, json)
		end
	end
	return false
end

local function readCheckpointFile()
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	if type(readFn) == "function" and HttpService then
		if type(isFileFn) == "function" then
			local okExists, exists = pcall(isFileFn, CHECKPOINT_FILE)
			if not (okExists and exists) then
				return nil
			end
		end
		local okRead, raw = pcall(readFn, CHECKPOINT_FILE)
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
	if #state.logs > 120 then
		table.remove(state.logs, 1)
	end
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
			"v2.2 Manual Gate | Rollback Mode: %s | Zero-Hook Safe",
			state.rollbackArmed and "ARMED (WAITING YOUR DECISION)" or "STANDBY"
		)

		local baseStr = "None"
		if state.armedBaseline then
			baseStr = string.format("%s | Tok=%s", tostring(state.armedBaseline.trait), tostring(state.armedBaseline.tokens))
		end

		ui.boardBox.Text = table.concat({
			string.format("Unit: %s | GUID: %s", tostring(state.unitName), tostring(state.unitGuid)),
			string.format("Live: [%s | Tok=%s]   ||   Baseline: [%s]", tostring(state.liveTrait), tostring(state.liveTokens), baseStr),
			state.verdict,
		}, "\n")

		ui.armBtn.Text = state.rollbackArmed and "1. Rollback: ARMED" or "1. Arm Rollback"
		ui.armBtn.BackgroundColor3 = state.rollbackArmed and C.warn or C.accent

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready."
	end)
end

local function armRollbackMode()
	pcall(scanGuiState)
	local cp = {
		unitGuid = tostring(state.unitGuid),
		unitName = tostring(state.unitName),
		trait = tostring(state.liveTrait),
		tokens = tostring(state.liveTokens),
		armedAt = os.time(),
	}
	state.armedBaseline = cp
	state.rollbackArmed = true
	local savedDisk = writeCheckpointFile(cp)
	state.verdict = string.format(
		"ARMED (%s): Baseline=[%s, Tok=%s]. Now roll manually, then click Confirm Rollback or Keep!",
		savedDisk and "Disk+RAM" or "RAM",
		cp.trait,
		cp.tokens
	)
	addLog("ARMED", state.verdict)
	refreshUI()
end

local function keepResultAndDisarm()
	pcall(scanGuiState)
	state.rollbackArmed = false
	state.armedBaseline = nil
	state.verdict = string.format("KEPT RESULT: Disarmed at [%s | Tok=%s].", tostring(state.liveTrait), tostring(state.liveTokens))
	addLog("KEEP", state.verdict)
	refreshUI()
end

local function confirmManualRollbackAndRejoin()
	pcall(scanGuiState)
	if not state.armedBaseline then
		state.armedBaseline = {
			unitGuid = tostring(state.unitGuid),
			unitName = tostring(state.unitName),
			trait = tostring(state.liveTrait),
			tokens = tostring(state.liveTokens),
			armedAt = os.time(),
		}
		writeCheckpointFile(state.armedBaseline)
	end

	addLog(
		"CONFIRM_RB",
		string.format(
			"Manual Rollback Confirmed! Baseline=[%s, Tok=%s] vs Current=[%s, Tok=%s] -> Triggering Rejoin...",
			tostring(state.armedBaseline.trait),
			tostring(state.armedBaseline.tokens),
			tostring(state.liveTrait),
			tostring(state.liveTokens)
		)
	)
	refreshUI()

	local lp = Players and Players.LocalPlayer
	if TeleportService and lp then
		pcall(function()
			TeleportService:Teleport(game.PlaceId, lp)
		end)
	end
end

local function verifyPostRejoin()
	pcall(scanGuiState)
	local cp = state.armedBaseline or readCheckpointFile()
	if not cp then
		state.verdict = "No armed baseline found. Click [1. Arm Rollback] before rolling."
		addLog("VERIFY", "No baseline found.")
		refreshUI()
		return
	end

	state.armedBaseline = cp
	local preTrait = tostring(cp.trait)
	local nowTrait = tostring(state.liveTrait)
	local preTok = tostring(cp.tokens)
	local nowTok = tostring(state.liveTokens)

	if preTrait == nowTrait and (preTok == "Unknown" or preTok == nowTok) then
		state.verdict = string.format(
			"RESULT: ROLLBACK SUCCEEDED! Returned to Baseline [%s | Tok=%s]",
			preTrait, preTok
		)
	else
		state.verdict = string.format(
			"RESULT: SERVER COMMITTED (NO ROLLBACK) | Baseline:[%s, Tok=%s] -> Now:[%s, Tok=%s]",
			preTrait, preTok, nowTrait, nowTok
		)
	end
	addLog("VERIFY", state.verdict)
	refreshUI()
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
					addLog("S2C_TOKEN", "Tokens updated = " .. state.liveTokens)
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
						addLog(
							"MANUAL_ROLL",
							string.format(
								"Rolled -> Trait=%q | Tokens=%s (Decide now: Confirm Rollback or Keep!)",
								state.liveTrait,
								state.liveTokens
							)
						)
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
	ui.screenGui.DisplayOrder = 170

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 560, 0, 440)
	ui.main.Position = UDim2.new(0.5, -280, 0.5, -220)
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
	title.Text = "ROLLBACK LAB v2.2 — MANUAL TWO-STAGE DECISION GATE"
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

	ui.armBtn = makeBtn("1. Arm Rollback", 12, 144, 130, C.accent)
	ui.confirmBtn = makeBtn("2A. Confirm Rollback", 148, 144, 152, C.danger)
	ui.keepBtn = makeBtn("2B. Keep Result", 306, 144, 118, C.good)
	ui.verifyBtn = makeBtn("3. Check Rejoin", 430, 144, 118, C.btn)

	ui.copyBtn = makeBtn("Copy Full Report", 12, 180, 536, C.btn)

	ui.logBox = Instance.new("TextBox")
	ui.logBox.Size = UDim2.new(1, -24, 0, 212)
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
	bindSafeClick(ui.armBtn, armRollbackMode)
	bindSafeClick(ui.confirmBtn, confirmManualRollbackAndRejoin)
	bindSafeClick(ui.keepBtn, keepResultAndDisarm)
	bindSafeClick(ui.verifyBtn, verifyPostRejoin)

	bindSafeClick(ui.copyBtn, function()
		pcall(scanGuiState)
		local header = {
			"=== ROLLBACK LAB v2.2 — MANUAL DECISION REPORT ===",
			ui.statusLabel.Text,
			ui.boardBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied v2.2 report to clipboard." or "Clipboard unavailable.")
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

	local existingCp = readCheckpointFile()
	if existingCp then
		state.armedBaseline = existingCp
		if existingCp.unitGuid and existingCp.unitGuid ~= "Unknown" then
			state.unitGuid = existingCp.unitGuid
		end
		addLog("BOOT", string.format("Loaded Armed Baseline: %s | Tok=%s", tostring(existingCp.trait), tostring(existingCp.tokens)))
		verifyPostRejoin()
	else
		addLog("BOOT", "Rollback Lab v2.2 initialized (Manual Two-Stage Gate).")
	end

	refreshUI()
end)
