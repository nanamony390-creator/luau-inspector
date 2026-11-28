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

local APP_TAG = "RollbackLab_LiveTrial_v2"
local GUARD_KEY = "__LiveTrialGuard_" .. APP_TAG
local CHECKPOINT_FILE = "RollbackLab_v2_Checkpoint.json"

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
	armed = true,
	trialCount = 0,
	unitGuid = "Unknown",
	unitName = "Unknown",
	liveTrait = "N/A",
	liveTokens = "Unknown",
	curseTokens = "Unknown",
	statPreview = "N/A",
	raceDelayMs = 15, -- Default timing window in ms before rejoin trigger
	lastSyncClock = 0,
	savedCheckpoint = nil,
	verdict = "Ready: Select unit in TraitReroll, Save Checkpoint, then run Test.",
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
	local line = string.format("[%s | %.2fs] %s", tag, os.clock() % 1000, msg)
	state.logs[#state.logs + 1] = line
	if #state.logs > 110 then
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
			-- Check attributes or StringValues for selected unit GUID
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

	local sr = pg:FindFirstChild("StatReroll")
	if sr then
		local statsFrame = sr:FindFirstChild("UnitStats", true)
		if statsFrame then
			local parts = {}
			for _, statName in ipairs({ "Attack", "Range", "Cooldown" }) do
				local row = statsFrame:FindFirstChild(statName)
				if row then
					for _, lbl in ipairs(row:GetDescendants()) do
						if lbl:IsA("TextLabel") and lbl.Text ~= "" and lbl.Text ~= statName and lbl.Text ~= "Reroll" then
							parts[#parts + 1] = statName .. "=" .. lbl.Text
							break
						end
					end
				end
			end
			if #parts > 0 then
				state.statPreview = table.concat(parts, ", ")
			end
		end
	end
end

local function saveCheckpointNow(reasonTag)
	scanGuiState()
	local cp = {
		unitGuid = state.unitGuid,
		unitName = state.unitName,
		trait = state.liveTrait,
		tokens = state.liveTokens,
		stats = state.statPreview,
		savedAt = os.time(),
	}
	state.savedCheckpoint = cp
	local savedToDisk = writeCheckpointFile(cp)
	state.verdict = string.format(
		"Checkpoint [%s] (%s): Trait=%s | Tokens=%s",
		reasonTag or "MANUAL",
		savedToDisk and "Disk+RAM" or "RAM",
		tostring(cp.trait),
		tostring(cp.tokens)
	)
	addLog("CHECKPOINT", state.verdict)
	return cp
end

local function evaluateAgainstCheckpoint()
	scanGuiState()
	local cp = state.savedCheckpoint or readCheckpointFile()
	if not cp then
		state.verdict = "No prior checkpoint found. Save Checkpoint before running a trial."
		addLog("COMPARE", "No prior checkpoint file found.")
		return
	end

	state.savedCheckpoint = cp
	local traitMatch = (cp.trait == state.liveTrait)
	local tokenMatch = (tostring(cp.tokens) == "Unknown") or (tostring(cp.tokens) == tostring(state.liveTokens))

	if traitMatch and tokenMatch then
		state.verdict = string.format(
			"VERDICT: PERSISTED (NO ROLLBACK) | Pre:[%s, Tok=%s] == Now:[%s, Tok=%s]",
			tostring(cp.trait),
			tostring(cp.tokens),
			tostring(state.liveTrait),
			tostring(state.liveTokens)
		)
	else
		state.verdict = string.format(
			"VERDICT: ROLLBACK / STATE DIFF! | Pre:[%s, Tok=%s] -> Now:[%s, Tok=%s]",
			tostring(cp.trait),
			tostring(cp.tokens),
			tostring(state.liveTrait),
			tostring(state.liveTokens)
		)
	end
	addLog("COMPARE", state.verdict)
end

local function triggerRejoin(newServer)
	local lp = Players and Players.LocalPlayer
	if not (TeleportService and lp) then
		addLog("REJOIN_ERR", "TeleportService or LocalPlayer unavailable.")
		return
	end
	addLog("REJOIN", newServer and "Teleporting to fresh server..." or "Rejoining current PlaceId...")
	pcall(function()
		if not newServer and game.JobId and game.JobId ~= "" then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp)
		else
			TeleportService:Teleport(game.PlaceId, lp)
		end
	end)
end

local function getRerollEndpoint()
	if not ReplicatedStorage then
		return nil
	end
	local ep = ReplicatedStorage:FindFirstChild("endpoints")
	local c2s = ep and ep:FindFirstChild("client_to_server")
	return c2s and c2s:FindFirstChild("request_token_trait_reroll") or nil
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end
	scanGuiState()
	pcall(function()
		ui.statusLabel.Text = string.format(
			"v2.0 Active Trial | Zero-Hook | Monitor: %s | Trials: %d | RaceDelay: %dms",
			state.armed and "ON" or "OFF",
			state.trialCount,
			state.raceDelayMs
		)
		ui.boardBox.Text = table.concat({
			string.format("Unit: %s | GUID: %s", tostring(state.unitName), tostring(state.unitGuid)),
			string.format("Live Trait: %s | Real Tokens: %s | Curse Tokens: %s", tostring(state.liveTrait), tostring(state.liveTokens), tostring(state.curseTokens)),
			"Stats: " .. tostring(state.statPreview),
			state.verdict,
		}, "\n")

		ui.armBtn.Text = state.armed and "1. Monitor: ON" or "1. Monitor: OFF"
		ui.armBtn.BackgroundColor3 = state.armed and C.good or C.btn
		ui.delayBtn.Text = string.format("Delay: %dms", state.raceDelayMs)

		local view = {}
		for i = math.max(1, #state.logs - 16), #state.logs do
			view[#view + 1] = state.logs[i]
		end
		ui.logBox.Text = (#view > 0) and table.concat(view, "\n") or "Ready."
	end)
end

local function bindPassiveWatchers()
	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		local s2c = ep and ep:FindFirstChild("server_to_client")
		if s2c then
			local tokEv = s2c:FindFirstChild("token_trait_reroll_amount_changed")
			if tokEv and tokEv:IsA("RemoteEvent") then
				trackConn(tokEv.OnClientEvent:Connect(function(amount)
					if destroyed or not state.armed then
						return
					end
					state.lastSyncClock = os.clock()
					state.liveTokens = tostring(amount)
					addLog("S2C_TOKEN", "Server Trait Tokens = " .. state.liveTokens)
					refreshUI()
				end))
			end

			local curseEv = s2c:FindFirstChild("token_curse_reroll_amount_changed")
			if curseEv and curseEv:IsA("RemoteEvent") then
				trackConn(curseEv.OnClientEvent:Connect(function(amount)
					if destroyed or not state.armed then
						return
					end
					state.curseTokens = tostring(amount)
					addLog("S2C_CURSE", "Server Curse Tokens = " .. state.curseTokens)
					refreshUI()
				end))
			end

			local traitEv = s2c:FindFirstChild("unit_traits_changed")
			if traitEv and traitEv:IsA("RemoteEvent") then
				trackConn(traitEv.OnClientEvent:Connect(function(unitId)
					if destroyed or not state.armed then
						return
					end
					state.trialCount += 1
					if unitId ~= nil then
						state.unitGuid = tostring(unitId)
					end
					local dtMs = state.lastSyncClock > 0 and ((os.clock() - state.lastSyncClock) * 1000) or 0
					task.defer(function()
						task.wait(0.05)
						scanGuiState()
						addLog(
							"TRIAL_COMMIT",
							string.format(
								"Trial #%d | Unit=%s (%s) | Trait=%q | Tokens=%s | Delta=%.1fms",
								state.trialCount,
								state.unitName,
								state.unitGuid,
								state.liveTrait,
								state.liveTokens,
								dtMs
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
					if destroyed or not state.armed then
						return
					end
					state.liveTrait = obj.Text
					addLog("UI_SYNC", "CurrentTraitText -> " .. tostring(obj.Text))
					refreshUI()
				end))
			end
		end
		for _, d in ipairs(tr:GetDescendants()) do
			watchText(d)
		end
		trackConn(tr.DescendantAdded:Connect(function(d)
			watchText(d)
			if not destroyed and state.armed and d:IsA("TextLabel") and d.Name == "CurrentTraitText" then
				state.liveTrait = d.Text
				addLog("UI_REBUILD", "CurrentTraitText rebuilt -> " .. tostring(d.Text))
				refreshUI()
			end
		end))
	end
end

local function executeRollbackRaceTrial()
	scanGuiState()
	local cp = saveCheckpointNow("PRE_RACE")
	local remote = getRerollEndpoint()

	if not remote then
		addLog("ERROR", "request_token_trait_reroll endpoint not found.")
		refreshUI()
		return
	end

	if cp.unitGuid == "Unknown" or cp.unitGuid == "" then
		addLog("WARN", "Unit GUID unknown yet! Do 1 manual reroll first so GUID is captured, then run Race Trial.")
		state.verdict = "Action needed: Do 1 normal reroll first so the script captures your Unit GUID."
		refreshUI()
		return
	end

	addLog("RACE_START", string.format("Invoking reroll on %s, then triggering Rejoin after %dms...", cp.unitGuid, state.raceDelayMs))
	refreshUI()

	-- Fire reroll asynchronously without blocking the race timer
	task.spawn(function()
		pcall(function()
			if remote:IsA("RemoteFunction") then
				remote:InvokeServer(cp.unitGuid)
			elseif remote:IsA("RemoteEvent") then
				remote:FireServer(cp.unitGuid)
			end
		end)
	end)

	-- Wait exact race window in ms, then trigger teleport/rejoin
	if state.raceDelayMs > 0 then
		task.wait(state.raceDelayMs / 1000)
	else
		task.wait()
	end
	triggerRejoin(true)
end

local function cleanupApp()
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
	ui.screenGui.Name = APP_TAG
	ui.screenGui.ResetOnSpawn = false
	ui.screenGui.IgnoreGuiInset = true
	ui.screenGui.DisplayOrder = 155

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 550, 0, 455)
	ui.main.Position = UDim2.new(0.5, -275, 0.5, -227)
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
	title.Text = "ROLLBACK LAB v2.0 — ACTIVE TRIAL, RACE & REJOIN ENGINE"
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
	ui.boardBox.Size = UDim2.new(1, -24, 0, 82)
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

	-- Row 1: Measurement & Checkpoint
	ui.armBtn = makeBtn("1. Monitor: ON", 12, 152, 125, C.good)
	ui.saveBtn = makeBtn("2. Save Checkpoint", 143, 152, 132, C.accent)
	ui.cmpBtn = makeBtn("3. Compare Rejoin", 281, 152, 132, C.btn)
	ui.copyBtn = makeBtn("Copy Report", 419, 152, 119, C.btn)

	-- Row 2: Active Rollback Race Trial & Rejoin Controls
	ui.raceBtn = makeBtn("4. Run Rollback Race Trial", 12, 186, 195, C.danger)
	ui.delayBtn = makeBtn("Delay: 15ms", 213, 186, 95, C.btn)
	ui.rejoinBtn = makeBtn("5. Rejoin Server", 314, 186, 112, C.warn)
	ui.rejoinNewBtn = makeBtn("Rejoin New", 432, 186, 106, C.btn)

	ui.logBox = Instance.new("TextBox")
	ui.logBox.Size = UDim2.new(1, -24, 0, 222)
	ui.logBox.Position = UDim2.new(0, 12, 0, 222)
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
	trackConn(ui.closeBtn.Activated:Connect(cleanupApp))

	trackConn(ui.armBtn.Activated:Connect(function()
		state.armed = not state.armed
		addLog("MODE", state.armed and "Monitor enabled." or "Monitor paused.")
		refreshUI()
	end))

	trackConn(ui.saveBtn.Activated:Connect(function()
		saveCheckpointNow("MANUAL")
		refreshUI()
	end))

	trackConn(ui.cmpBtn.Activated:Connect(function()
		evaluateAgainstCheckpoint()
		refreshUI()
	end))

	trackConn(ui.raceBtn.Activated:Connect(function()
		executeRollbackRaceTrial()
	end))

	local delaySteps = { 0, 5, 15, 30, 60 }
	trackConn(ui.delayBtn.Activated:Connect(function()
		local idx = 1
		for i, v in ipairs(delaySteps) do
			if v == state.raceDelayMs then
				idx = (i % #delaySteps) + 1
				break
			end
		end
		state.raceDelayMs = delaySteps[idx]
		addLog("CONFIG", string.format("Race Rejoin delay set to %dms.", state.raceDelayMs))
		refreshUI()
	end))

	trackConn(ui.rejoinBtn.Activated:Connect(function()
		saveCheckpointNow("PRE_REJOIN")
		triggerRejoin(false)
	end))

	trackConn(ui.rejoinNewBtn.Activated:Connect(function()
		saveCheckpointNow("PRE_NEW_SRV")
		triggerRejoin(true)
	end))

	trackConn(ui.copyBtn.Activated:Connect(function()
		scanGuiState()
		local header = {
			"=== ROLLBACK LAB v2.0 — ACTIVE TRIAL & RACE REPORT ===",
			ui.statusLabel.Text,
			ui.boardBox.Text,
			"--- LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. table.concat(state.logs, "\n")
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied v2.0 report to clipboard." or "Clipboard unavailable.")
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
	scanGuiState()

	local existingCp = readCheckpointFile()
	if existingCp then
		state.savedCheckpoint = existingCp
		if existingCp.unitGuid and existingCp.unitGuid ~= "Unknown" then
			state.unitGuid = existingCp.unitGuid
		end
		addLog("BOOT", string.format("Restored Checkpoint: Unit=%s | Trait=%s | Tokens=%s", tostring(existingCp.unitName), tostring(existingCp.trait), tostring(existingCp.tokens)))
		evaluateAgainstCheckpoint()
	else
		addLog("BOOT", "Rollback Lab v2.0 initialized (Active Race Trial + Zero-Hook Monitor).")
	end

	refreshUI()
end)
