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

local APP_TAG = "RollbackLab_PreRollArm_v3_1"
local GUARD_KEY = "__LiveTrialGuard_" .. APP_TAG
local BASE_FILE = "RollbackLab_v3_1_PreRollBase.json"

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
	armed = false,
	armSeq = 0,
	rollsSinceArm = 0,
	exitMethod = "KICK_TP", -- KICK_TP | SHUTDOWN | TELEPORT
	unitGuid = "Unknown",
	unitName = "Unknown",
	liveTrait = "N/A",
	liveTokens = "Unknown",
	preRollBase = nil, -- Locked Pre-Roll Base saved before rolling
	verdict = "Click [1. ARM PRE-ROLL BASE] BEFORE rolling to lock your pre-roll base.",
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

local function writeBaseFile(tbl)
	local writeFn = findExecutorFn("writefile")
	if type(writeFn) == "function" and HttpService then
		local okEnc, json = pcall(function()
			return HttpService:JSONEncode(tbl)
		end)
		if okEnc and json then
			return pcall(writeFn, BASE_FILE, json)
		end
	end
	return false
end

local function readBaseFile()
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	if type(readFn) == "function" and HttpService then
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, BASE_FILE)
			if not (okEx and ex) then
				return nil
			end
		end
		local okRead, raw = pcall(readFn, BASE_FILE)
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

local function clearBaseFile()
	local delFn = findExecutorFn("delfile")
	local isFileFn = findExecutorFn("isfile")
	if type(delFn) == "function" then
		local exists = true
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, BASE_FILE)
			exists = okEx and ex
		end
		if exists then
			pcall(delFn, BASE_FILE)
		end
	end
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
			"v3.1 Pre-Roll Arm | Armed:%s (Arm#%d) | RollsAfterArm:%d | Cut:%s",
			state.armed and "LOCKED" or "OFF",
			state.armSeq,
			state.rollsSinceArm,
			state.exitMethod
		)

		local baseStr = "None (Not Armed Before Roll)"
		if state.preRollBase then
			baseStr = string.format(
				"#%d [%s | Tok=%s]",
				tonumber(state.preRollBase.armSeq) or 0,
				tostring(state.preRollBase.trait),
				tostring(state.preRollBase.tokens)
			)
		end

		ui.boardBox.Text = table.concat({
			string.format("Unit: %s | GUID: %s", tostring(state.unitName), tostring(state.unitGuid)),
			string.format("Post-Roll Now: [%s | Tok=%s]  ||  Pre-Roll Base: %s", tostring(state.liveTrait), tostring(state.liveTokens), baseStr),
			state.verdict,
		}, "\n")

		ui.armBtn.Text = state.armed and string.format("1. BASE LOCKED (#%d)", state.armSeq) or "1. ARM PRE-ROLL BASE"
		ui.armBtn.BackgroundColor3 = state.armed and C.warn or C.accent
		ui.modeBtn.Text = "Cut: " .. state.exitMethod

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready."
	end)
end

local function armPreRollBase()
	pcall(scanGuiState)
	state.armSeq += 1
	state.rollsSinceArm = 0
	local base = {
		armSeq = state.armSeq,
		unitGuid = tostring(state.unitGuid),
		unitName = tostring(state.unitName),
		trait = tostring(state.liveTrait),
		tokens = tostring(state.liveTokens),
		armedAt = os.time(),
	}
	state.preRollBase = base
	state.armed = true
	local savedDisk = writeBaseFile(base)
	state.verdict = string.format(
		"PRE-ROLL BASE #%d LOCKED (%s): [%s | Tok=%s]. Roll manually now, then Confirm Rollback or Keep!",
		state.armSeq,
		savedDisk and "Disk+RAM" or "RAM",
		base.trait,
		base.tokens
	)
	addLog("ARM_BASE", state.verdict)
	refreshUI()
end

local function keepPostRollResult()
	pcall(scanGuiState)
	state.armed = false
	state.rollsSinceArm = 0
	state.preRollBase = nil
	clearBaseFile()
	state.verdict = string.format("KEPT RESULT: Cleared Pre-Roll Base & accepted [%s | Tok=%s].", tostring(state.liveTrait), tostring(state.liveTokens))
	addLog("KEEP_RESULT", state.verdict)
	refreshUI()
end

local function executeSessionCut(method)
	local lp = Players and Players.LocalPlayer
	if method == "TELEPORT" then
		if TeleportService and lp then
			pcall(function()
				TeleportService:Teleport(game.PlaceId, lp)
			end)
		end
	elseif method == "KICK_TP" then
		if TeleportService and lp then
			task.spawn(function()
				pcall(function()
					TeleportService:Teleport(game.PlaceId, lp)
				end)
			end)
			task.wait(0.02)
			pcall(function()
				lp:Kick("RollbackLab v3.1 Pre-Roll Rollback Cut")
			end)
		end
	elseif method == "SHUTDOWN" then
		pcall(function()
			game:Shutdown()
		end)
	end
end

local function confirmPreRollRollback()
	pcall(scanGuiState)
	local base = state.preRollBase or readBaseFile()
	if not base then
		state.verdict = "ERROR: No Pre-Roll Base was armed before rolling! Click [1. ARM PRE-ROLL BASE] first."
		addLog("CONFIRM_ERR", "Missing Pre-Roll Base.")
		refreshUI()
		return
	end

	state.preRollBase = base
	writeBaseFile(base)
	addLog(
		"CONFIRM_RB",
		string.format(
			"Confirming Rollback to Base #%d [%s, Tok=%s] from Post-Roll [%s, Tok=%s] via %s...",
			tonumber(base.armSeq) or 0,
			tostring(base.trait),
			tostring(base.tokens),
			tostring(state.liveTrait),
			tostring(state.liveTokens),
			state.exitMethod
		)
	)
	refreshUI()
	executeSessionCut(state.exitMethod)
end

local function verifyAgainstPreRollBase()
	pcall(scanGuiState)
	local base = state.preRollBase or readBaseFile()
	if not base then
		state.verdict = "No Pre-Roll Base found to compare against."
		addLog("VERIFY", "No Pre-Roll Base found.")
		refreshUI()
		return
	end

	state.preRollBase = base
	local preTrait = tostring(base.trait)
	local nowTrait = tostring(state.liveTrait)
	local preTok = tostring(base.tokens)
	local nowTok = tostring(state.liveTokens)

	if preTrait == nowTrait and (preTok == "Unknown" or preTok == nowTok) then
		state.verdict = string.format(
			"VERDICT: ROLLBACK MATCHED PRE-ROLL BASE #%d! [%s | Tok=%s]",
			tonumber(base.armSeq) or 0,
			preTrait,
			preTok
		)
	else
		state.verdict = string.format(
			"VERDICT: SERVER COMMITTED NEW STATE | Pre-Roll Base #%d:[%s, Tok=%s] -> Now:[%s, Tok=%s]",
			tonumber(base.armSeq) or 0,
			preTrait,
			preTok,
			nowTrait,
			nowTok
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
					if state.armed then
						state.rollsSinceArm += 1
					end
					task.defer(function()
						task.wait(0.05)
						pcall(scanGuiState)
						addLog(
							"POST_ARM_ROLL",
							string.format(
								"Roll #%d after Arm#%d -> Trait=%q | Tokens=%s",
								state.rollsSinceArm,
								state.armSeq,
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
	ui.screenGui.DisplayOrder = 185

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 575, 0, 445)
	ui.main.Position = UDim2.new(0.5, -287, 0.5, -222)
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
	title.Text = "ROLLBACK LAB v3.1 — TRUE PRE-ROLL ARM BASE ENGINE"
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

	ui.armBtn = makeBtn("1. ARM PRE-ROLL BASE", 12, 144, 152, C.accent)
	ui.confirmBtn = makeBtn("2A. CONFIRM ROLLBACK", 170, 144, 156, C.danger)
	ui.keepBtn = makeBtn("2B. KEEP RESULT", 332, 144, 114, C.good)
	ui.verifyBtn = makeBtn("3. VERIFY BASE", 452, 144, 111, C.btn)

	ui.modeBtn = makeBtn("Cut: KICK_TP", 12, 180, 145, C.btn)
	ui.copyBtn = makeBtn("Copy v3.1 Report", 163, 180, 400, C.btn)

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
	bindSafeClick(ui.armBtn, armPreRollBase)
	bindSafeClick(ui.confirmBtn, confirmPreRollRollback)
	bindSafeClick(ui.keepBtn, keepPostRollResult)
	bindSafeClick(ui.verifyBtn, verifyAgainstPreRollBase)

	local methods = { "KICK_TP", "SHUTDOWN", "TELEPORT" }
	bindSafeClick(ui.modeBtn, function()
		local idx = 1
		for i, m in ipairs(methods) do
			if m == state.exitMethod then
				idx = (i % #methods) + 1
				break
			end
		end
		state.exitMethod = methods[idx]
		addLog("CONFIG", "Cut mode -> " .. state.exitMethod)
		refreshUI()
	end)

	bindSafeClick(ui.copyBtn, function()
		pcall(scanGuiState)
		local header = {
			"=== ROLLBACK LAB v3.1 — PRE-ROLL ARM REPORT ===",
			ui.statusLabel.Text,
			ui.boardBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied v3.1 report to clipboard." or "Clipboard unavailable.")
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

	local existingBase = readBaseFile()
	if existingBase then
		state.preRollBase = existingBase
		state.armSeq = tonumber(existingBase.armSeq) or state.armSeq
		if existingBase.unitGuid and existingBase.unitGuid ~= "Unknown" then
			state.unitGuid = existingBase.unitGuid
		end
		addLog("BOOT", string.format("Loaded Pre-Roll Base #%d: %s | Tok=%s", state.armSeq, tostring(existingBase.trait), tostring(existingBase.tokens)))
		verifyAgainstPreRollBase()
	else
		addLog("BOOT", "Rollback Lab v3.1 ready. Arm Pre-Roll Base before rolling.")
	end

	refreshUI()
end)
