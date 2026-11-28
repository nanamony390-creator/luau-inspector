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

local APP_TAG = "RollbackLab_SessionEntity_v3_2"
local GUARD_KEY = "__LiveTrialGuard_" .. APP_TAG
local ENTITY_FILE = "RollbackLab_v3_2_SessionEntity.json"

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
	sessionCounter = 0,
	rollsInSession = 0,
	exitMethod = "KICK_TP", -- KICK_TP | SHUTDOWN | TELEPORT
	unitGuid = "Unknown",
	unitName = "Unknown",
	liveTrait = "N/A",
	liveTokens = "Unknown",
	guiOpen = false,
	sessionEntity = nil, -- Full Pre-Open Session Entity
	verdict = "Step 1: Click [1. ARM OPEN ENTITY] before opening/rolling.",
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

local function writeEntityFile(tbl)
	local writeFn = findExecutorFn("writefile")
	if type(writeFn) == "function" and HttpService then
		local okEnc, json = pcall(function()
			return HttpService:JSONEncode(tbl)
		end)
		if okEnc and json then
			return pcall(writeFn, ENTITY_FILE, json)
		end
	end
	return false
end

local function readEntityFile()
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	if type(readFn) == "function" and HttpService then
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, ENTITY_FILE)
			if not (okEx and ex) then
				return nil
			end
		end
		local okRead, raw = pcall(readFn, ENTITY_FILE)
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

local function clearEntityFile()
	local delFn = findExecutorFn("delfile")
	local isFileFn = findExecutorFn("isfile")
	if type(delFn) == "function" then
		local exists = true
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, ENTITY_FILE)
			exists = okEx and ex
		end
		if exists then
			pcall(delFn, ENTITY_FILE)
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
		state.guiOpen = (tr:IsA("ScreenGui") and tr.Enabled) or false
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
		local entId = state.sessionEntity and tostring(state.sessionEntity.sessionId) or "NONE"
		ui.statusLabel.Text = string.format(
			"v3.2 Entity Gate | State:%s | Entity:%s | Rolls:%d | Cut:%s",
			state.armed and "ARMED" or "STANDBY",
			entId,
			state.rollsInSession,
			state.exitMethod
		)

		local entSummary = "No Pre-Open Session Entity Saved"
		if state.sessionEntity then
			entSummary = string.format(
				"%s [Trait=%s | Tok=%s | Gui=%s]",
				tostring(state.sessionEntity.sessionId),
				tostring(state.sessionEntity.preOpenTrait),
				tostring(state.sessionEntity.preOpenTokens),
				tostring(state.sessionEntity.guiOpenAtArm)
			)
		end

		ui.boardBox.Text = table.concat({
			string.format("Unit: %s | GUID: %s", tostring(state.unitName), tostring(state.unitGuid)),
			string.format("Now: [%s | Tok=%s]  ||  Entity: %s", tostring(state.liveTrait), tostring(state.liveTokens), entSummary),
			state.verdict,
		}, "\n")

		ui.armBtn.Text = state.armed and ("1. ENTITY ARMED (" .. entId .. ")") or "1. ARM OPEN ENTITY"
		ui.armBtn.BackgroundColor3 = state.armed and C.warn or C.accent
		ui.modeBtn.Text = "Cut: " .. state.exitMethod

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready."
	end)
end

local function armOpenSessionEntity()
	pcall(scanGuiState)
	state.sessionCounter += 1
	state.rollsInSession = 0

	local entity = {
		sessionId = string.format("SES-%03d", state.sessionCounter),
		armedAt = os.time(),
		unitGuid = tostring(state.unitGuid),
		unitName = tostring(state.unitName),
		preOpenTrait = tostring(state.liveTrait),
		preOpenTokens = tostring(state.liveTokens),
		guiOpenAtArm = state.guiOpen,
		confirmedRollback = false,
	}

	state.sessionEntity = entity
	state.armed = true
	local savedDisk = writeEntityFile(entity)

	state.verdict = string.format(
		"OPEN ENTITY %s LOCKED (%s): [%s | Tok=%s]. Open/roll manually, then Confirm Rollback or Keep!",
		entity.sessionId,
		savedDisk and "Disk+RAM" or "RAM",
		entity.preOpenTrait,
		entity.preOpenTokens
	)
	addLog("ARM_ENTITY", state.verdict)
	refreshUI()
end

local function keepSessionResult()
	pcall(scanGuiState)
	local prevId = state.sessionEntity and tostring(state.sessionEntity.sessionId) or "NONE"
	state.armed = false
	state.rollsInSession = 0
	state.sessionEntity = nil
	clearEntityFile()
	state.verdict = string.format("KEPT (%s): Released entity & accepted [%s | Tok=%s].", prevId, tostring(state.liveTrait), tostring(state.liveTokens))
	addLog("KEEP_ENTITY", state.verdict)
	refreshUI()
end

local function executeSessionCut(method)
	local lp = Players and Players.LocalPlayer
	if method == "KICK_TP" then
		if TeleportService and lp then
			task.spawn(function()
				pcall(function()
					TeleportService:Teleport(game.PlaceId, lp)
				end)
			end)
			task.wait(0.02)
			pcall(function()
				lp:Kick("RollbackLab v3.2 Session Entity Cut")
			end)
		end
	elseif method == "SHUTDOWN" then
		pcall(function()
			game:Shutdown()
		end)
	elseif method == "TELEPORT" then
		if TeleportService and lp then
			pcall(function()
				TeleportService:Teleport(game.PlaceId, lp)
			end)
		end
	end
end

local function confirmPreOpenAssertionAndCut()
	pcall(scanGuiState)
	local ent = state.sessionEntity or readEntityFile()

	-- Assert 1: Pre-open entity must exist
	if not ent then
		state.verdict = "ASSERTION FAILED: No Pre-Open Session Entity was armed before opening/rolling!"
		addLog("ASSERT_FAIL", "Missing Pre-Open Session Entity.")
		refreshUI()
		return
	end

	-- Assert 2: Match unit GUID if both are known
	if ent.unitGuid and ent.unitGuid ~= "Unknown" and state.unitGuid ~= "Unknown" and ent.unitGuid ~= state.unitGuid then
		state.verdict = string.format("ASSERTION MISMATCH: Armed GUID [%s] != Current GUID [%s]", tostring(ent.unitGuid), tostring(state.unitGuid))
		addLog("ASSERT_MISMATCH", state.verdict)
		refreshUI()
		return
	end

	ent.confirmedRollback = true
	ent.confirmedAt = os.time()
	ent.postRollTraitAtConfirm = tostring(state.liveTrait)
	ent.postRollTokensAtConfirm = tostring(state.liveTokens)
	ent.rollsObserved = state.rollsInSession
	state.sessionEntity = ent
	writeEntityFile(ent)

	addLog(
		"ASSERT_OK",
		string.format(
			"Assertion Passed for %s! PreOpen=[%s, Tok=%s] | PostRoll=[%s, Tok=%s] | Rolls=%d -> Cutting via %s...",
			tostring(ent.sessionId),
			tostring(ent.preOpenTrait),
			tostring(ent.preOpenTokens),
			tostring(state.liveTrait),
			tostring(state.liveTokens),
			state.rollsInSession,
			state.exitMethod
		)
	)
	refreshUI()
	executeSessionCut(state.exitMethod)
end

local function verifySessionContract()
	pcall(scanGuiState)
	local ent = state.sessionEntity or readEntityFile()
	if not ent then
		state.verdict = "No Session Entity found to verify."
		addLog("VERIFY", "No Session Entity found.")
		refreshUI()
		return
	end

	state.sessionEntity = ent
	local preTrait = tostring(ent.preOpenTrait)
	local nowTrait = tostring(state.liveTrait)
	local preTok = tostring(ent.preOpenTokens)
	local nowTok = tostring(state.liveTokens)

	if preTrait == nowTrait and (preTok == "Unknown" or preTok == nowTok) then
		state.verdict = string.format(
			"CONTRACT FULFILLED (%s): True Rollback to Pre-Open Entity [%s | Tok=%s]",
			tostring(ent.sessionId),
			preTrait,
			preTok
		)
	else
		state.verdict = string.format(
			"CONTRACT BROKEN (%s): Server Committed [%s, Tok=%s] over Pre-Open [%s, Tok=%s]",
			tostring(ent.sessionId),
			nowTrait,
			nowTok,
			preTrait,
			preTok
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
						state.rollsInSession += 1
					end
					task.defer(function()
						task.wait(0.05)
						pcall(scanGuiState)
						addLog(
							"SESSION_ROLL",
							string.format(
								"Roll #%d in %s -> Trait=%q | Tokens=%s",
								state.rollsInSession,
								state.sessionEntity and tostring(state.sessionEntity.sessionId) or "UNARMED",
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
		if tr:IsA("ScreenGui") then
			trackConn(tr:GetPropertyChangedSignal("Enabled"):Connect(function()
				if destroyed then
					return
				end
				state.guiOpen = tr.Enabled
				addLog("GUI_OPEN", "TraitReroll Enabled = " .. tostring(tr.Enabled))
				refreshUI()
			end))
		end
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
	ui.screenGui.DisplayOrder = 190

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
	title.Text = "ROLLBACK LAB v3.2 — OPEN SESSION ENTITY & ASSERTION"
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

	ui.armBtn = makeBtn("1. ARM OPEN ENTITY", 12, 144, 150, C.accent)
	ui.confirmBtn = makeBtn("2A. CONFIRM & ASSERT", 168, 144, 162, C.danger)
	ui.keepBtn = makeBtn("2B. KEEP ENTITY", 336, 144, 114, C.good)
	ui.verifyBtn = makeBtn("3. VERIFY CONTRACT", 456, 144, 112, C.btn)

	ui.modeBtn = makeBtn("Cut: KICK_TP", 12, 180, 145, C.btn)
	ui.copyBtn = makeBtn("Copy v3.2 Entity Report", 163, 180, 405, C.btn)

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
	bindSafeClick(ui.armBtn, armOpenSessionEntity)
	bindSafeClick(ui.confirmBtn, confirmPreOpenAssertionAndCut)
	bindSafeClick(ui.keepBtn, keepSessionResult)
	bindSafeClick(ui.verifyBtn, verifySessionContract)

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
			"=== ROLLBACK LAB v3.2 — SESSION ENTITY REPORT ===",
			ui.statusLabel.Text,
			ui.boardBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied v3.2 report to clipboard." or "Clipboard unavailable.")
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

	local existingEnt = readEntityFile()
	if existingEnt then
		state.sessionEntity = existingEnt
		if existingEnt.unitGuid and existingEnt.unitGuid ~= "Unknown" then
			state.unitGuid = existingEnt.unitGuid
		end
		addLog("BOOT", string.format("Loaded Session Entity %s: [%s | Tok=%s]", tostring(existingEnt.sessionId), tostring(existingEnt.preOpenTrait), tostring(existingEnt.preOpenTokens)))
		verifySessionContract()
	else
		addLog("BOOT", "Rollback Lab v3.2 ready. Arm Open Session Entity before opening/rolling.")
	end

	refreshUI()
end)
