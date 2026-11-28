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

local APP_TAG = "RollbackLab_v4_3_DiagLog"
local GUARD_KEY = "__LiveTrialGuard_" .. APP_TAG
local STATE_FILE = "RollbackLab_v4_3_State.json"
local LOG_FILE = "RollbackLab_v4_3_Logs.txt"
local RUNNER_FILE = "RollbackLab_v4_1_Runner.lua"

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
	loadDelaySec = 3,
	exitMethod = "TELEPORT",
	unitGuid = "Unknown",
	unitName = "Unknown",
	liveTrait = "N/A",
	tok1x = "Unknown",
	tok5x = "Unknown",
	armedBase = nil,
	pendingConfirm = false,
	conflictCount = 0,
	verdict = "v4.3 Ready: Persistent disk logging + Rollback Active health checks.",
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

local function writeTextSafe(filename, content)
	local writeFn = findExecutorFn("writefile")
	if type(writeFn) == "function" and type(content) == "string" then
		return pcall(writeFn, filename, content)
	end
	return false
end

local function appendTextSafe(filename, line)
	local appendFn = findExecutorFn("appendfile")
	if type(appendFn) == "function" then
		local ok = pcall(appendFn, filename, line .. "\n")
		if ok then
			return true
		end
	end
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	local prev = ""
	if type(readFn) == "function" then
		local exists = true
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, filename)
			exists = okEx and ex
		end
		if exists then
			local okR, raw = pcall(readFn, filename)
			if okR and type(raw) == "string" then
				prev = raw
			end
		end
	end
	return writeTextSafe(filename, prev .. line .. "\n")
end

local function readTextSafe(filename)
	local readFn = findExecutorFn("readfile")
	local isFileFn = findExecutorFn("isfile")
	if type(readFn) == "function" then
		if type(isFileFn) == "function" then
			local okEx, ex = pcall(isFileFn, filename)
			if not (okEx and ex) then
				return nil
			end
		end
		local okR, raw = pcall(readFn, filename)
		if okR and type(raw) == "string" and raw ~= "" then
			return raw
		end
	end
	return nil
end

local function writeJsonSafe(filename, tbl)
	if not HttpService then
		return false
	end
	local okEnc, json = pcall(function()
		return HttpService:JSONEncode(tbl)
	end)
	if okEnc and type(json) == "string" then
		return writeTextSafe(filename, json)
	end
	return false
end

local function readJsonSafe(filename)
	if not HttpService then
		return nil
	end
	local raw = readTextSafe(filename)
	if raw then
		local okDec, tbl = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if okDec and type(tbl) == "table" then
			return tbl
		end
	end
	return nil
end

local function addLog(tag, msg)
	local line = string.format("[%s | %.2fs] %s", tag, os.clock() % 1000, tostring(msg))
	state.logs[#state.logs + 1] = line
	if #state.logs > 200 then
		table.remove(state.logs, 1)
	end
	pcall(appendTextSafe, LOG_FILE, line)
end

local function persistStateNow()
	writeJsonSafe(STATE_FILE, {
		rollbackActive = state.rollbackActive,
		autoLoadOnTp = state.autoLoadOnTp,
		loadDelaySec = state.loadDelaySec,
		exitMethod = state.exitMethod,
		unitGuid = state.unitGuid,
		unitName = state.unitName,
		armedBase = state.armedBase,
		pendingConfirm = state.pendingConfirm,
		conflictCount = state.conflictCount,
		verdict = state.verdict,
	})
end

local function ensureRunnerFileSaved()
	local existing = readTextSafe(RUNNER_FILE)
	if existing and #existing > 200 then
		return true
	end
	local src = nil
	if type(debug) == "table" and type(debug.info) == "function" then
		local okInfo, infoSrc = pcall(debug.info, 1, "s")
		if okInfo and type(infoSrc) == "string" and string.sub(infoSrc, 1, 1) == "@" then
			src = readTextSafe(string.sub(infoSrc, 2))
		end
	end
	if src and #src > 200 then
		return writeTextSafe(RUNNER_FILE, src)
	end
	return false
end

local function armAutoLoadQueue()
	if not state.autoLoadOnTp then
		return false, "AutoLoad OFF"
	end
	ensureRunnerFileSaved()
	local queueFn = findExecutorFn("queue_on_teleport") or findExecutorFn("queueonteleport")
	if type(queueFn) ~= "function" then
		return false, "queue_on_teleport unavailable"
	end

	local delayVal = tonumber(state.loadDelaySec) or 3
	local stub = string.format([[
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(%d)
local rf = (type(getgenv)=="function" and getgenv().readfile) or readfile
local ifn = (type(getgenv)=="function" and getgenv().isfile) or isfile
if type(rf)=="function" then
	local exists = true
	if type(ifn)=="function" then
		local okEx, ex = pcall(ifn, %q)
		exists = okEx and ex
	end
	if exists then
		local okC, code = pcall(rf, %q)
		if okC and type(code)=="string" and #code > 200 then
			local fn = loadstring(code)
			if type(fn)=="function" then pcall(fn) end
		end
	end
end
]], delayVal, RUNNER_FILE, RUNNER_FILE)

	local okQ, errQ = pcall(queueFn, stub)
	if okQ then
		return true, string.format("Queued (%ds)", delayVal)
	end
	return false, tostring(errQ)
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
			local foundPairs = {}
			for _, d in ipairs(utf:GetDescendants()) do
				if d:IsA("TextLabel") and string.find(d.Text, "^%d+%s*/%s*%d+$") then
					local clean = string.gsub(d.Text, "%s+", "")
					foundPairs[#foundPairs + 1] = { text = clean, x = d.AbsolutePosition.X }
				end
			end
			table.sort(foundPairs, function(a, b)
				return a.x < b.x
			end)
			if foundPairs[1] then
				state.tok1x = foundPairs[1].text
			end
			if foundPairs[2] then
				state.tok5x = foundPairs[2].text
			end
		end
	end
end

local function checkRollbackHealth(phaseTag)
	pcall(scanGuiState)
	local issues = {}

	if state.rollbackActive and not state.armedBase then
		issues[#issues + 1] = "Active without baseline"
	end
	if state.armedBase then
		if state.armedBase.unitGuid ~= "Unknown" and state.unitGuid ~= "Unknown" and state.armedBase.unitGuid ~= state.unitGuid then
			issues[#issues + 1] = "Unit GUID mismatch"
		end
		if state.armedBase.trait == "N/A" then
			issues[#issues + 1] = "Baseline trait was N/A"
		end
	end
	if state.liveTrait == "N/A" and state.tok1x == "Unknown" and state.tok5x == "Unknown" then
		issues[#issues + 1] = "TraitReroll state not readable"
	end

	if #issues > 0 then
		state.conflictCount += #issues
		addLog("DIAG_ISSUE", string.format("[%s] %s", phaseTag, table.concat(issues, "; ")))
		return false
	end

	addLog(
		"DIAG_OK",
		string.format("[%s] Active=%s | Trait=%s | 1x=%s | 5x=%s", phaseTag, tostring(state.rollbackActive), tostring(state.liveTrait), tostring(state.tok1x), tostring(state.tok5x))
	)
	return true
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end
	pcall(scanGuiState)
	pcall(function()
		ui.statusLabel.Text = string.format(
			"v4.3 DiagLog | Active:%s | AutoLoad:%s (%ds) | Cut:%s | Issues:%d",
			state.rollbackActive and "ON" or "OFF",
			state.autoLoadOnTp and "ON" or "OFF",
			state.loadDelaySec,
			state.exitMethod,
			state.conflictCount
		)

		local baseStr = "None"
		if state.armedBase then
			baseStr = string.format(
				"%s | 1x:%s | 5x:%s",
				tostring(state.armedBase.trait),
				tostring(state.armedBase.tok1x),
				tostring(state.armedBase.tok5x)
			)
		end

		ui.boardBox.Text = table.concat({
			string.format("Unit: %s | GUID: %s", tostring(state.unitName), tostring(state.unitGuid)),
			string.format("Now: [%s | 1x:%s | 5x:%s]  ||  Base: [%s]", tostring(state.liveTrait), tostring(state.tok1x), tostring(state.tok5x), baseStr),
			state.verdict,
		}, "\n")

		ui.activateBtn.Text = state.rollbackActive and "1. Rollback: ACTIVE" or "1. Activate Rollback"
		ui.activateBtn.BackgroundColor3 = state.rollbackActive and C.warn or C.accent

		ui.autoLoadBtn.Text = state.autoLoadOnTp and "Auto-Load: ON" or "Auto-Load: OFF"
		ui.autoLoadBtn.BackgroundColor3 = state.autoLoadOnTp and C.good or C.btn
		ui.delayBtn.Text = string.format("LoadWait:%ds", state.loadDelaySec)
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
		state.armedBase = {
			unitGuid = tostring(state.unitGuid),
			unitName = tostring(state.unitName),
			trait = tostring(state.liveTrait),
			tok1x = tostring(state.tok1x),
			tok5x = tostring(state.tok5x),
			armedAt = os.time(),
		}
		local okQ, infoQ = armAutoLoadQueue()
		state.verdict = string.format(
			"ACTIVE (%s): Base=[%s | 1x:%s | 5x:%s]. Roll manually, then Confirm.",
			infoQ,
			state.armedBase.trait,
			state.armedBase.tok1x,
			state.armedBase.tok5x
		)
		addLog("ACTIVATE", state.verdict .. " | queued=" .. tostring(okQ))
		checkRollbackHealth("AFTER_ACTIVATE")
		persistStateNow()
	else
		state.rollbackActive = false
		state.pendingConfirm = false
		state.verdict = "Rollback deactivated."
		addLog("DEACTIVATE", state.verdict)
		checkRollbackHealth("AFTER_DEACTIVATE")
		persistStateNow()
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
				lp:Kick("RollbackLab v4.3 Confirm Rollback")
			end)
		end
	elseif state.exitMethod == "SHUTDOWN" then
		pcall(function()
			game:Shutdown()
		end)
	end
end

local function confirmRollbackNow()
	checkRollbackHealth("PRE_CONFIRM")
	if not state.armedBase then
		state.armedBase = {
			unitGuid = tostring(state.unitGuid),
			unitName = tostring(state.unitName),
			trait = tostring(state.liveTrait),
			tok1x = tostring(state.tok1x),
			tok5x = tostring(state.tok5x),
			armedAt = os.time(),
		}
	end
	state.pendingConfirm = true
	local okQ, infoQ = armAutoLoadQueue()
	addLog(
		"CONFIRM",
		string.format(
			"Confirm pressed | Base=[%s | 1x:%s | 5x:%s] -> Now=[%s | 1x:%s | 5x:%s] | %s | Cut=%s",
			tostring(state.armedBase.trait),
			tostring(state.armedBase.tok1x),
			tostring(state.armedBase.tok5x),
			tostring(state.liveTrait),
			tostring(state.tok1x),
			tostring(state.tok5x),
			infoQ,
			state.exitMethod
		)
	)
	persistStateNow()
	refreshUI()
	executeSessionCut()
end

local function evaluatePostSession()
	pcall(scanGuiState)
	if not state.armedBase then
		return
	end
	local preTrait = tostring(state.armedBase.trait)
	local nowTrait = tostring(state.liveTrait)
	local pre1x = tostring(state.armedBase.tok1x)
	local now1x = tostring(state.tok1x)
	local pre5x = tostring(state.armedBase.tok5x)
	local now5x = tostring(state.tok5x)

	local traitSame = (preTrait == nowTrait)
	local t1Same = (pre1x == "Unknown") or (pre1x == now1x)
	local t5Same = (pre5x == "Unknown") or (pre5x == now5x)

	if traitSame and t1Same and t5Same then
		state.verdict = string.format("POST-RESULT: MATCHED BASE [%s | 1x:%s | 5x:%s]", preTrait, pre1x, pre5x)
	else
		state.verdict = string.format(
			"POST-RESULT: CHANGED TO [%s | 1x:%s | 5x:%s] (Base: [%s | 1x:%s | 5x:%s])",
			nowTrait, now1x, now5x, preTrait, pre1x, pre5x
		)
	end
	state.pendingConfirm = false
	state.rollbackActive = false
	addLog("POST_RESULT", state.verdict)
	checkRollbackHealth("POST_RETURN")
	persistStateNow()
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
					task.defer(function()
						task.wait(0.03)
						pcall(scanGuiState)
						addLog("S2C_TOKEN", string.format("Ev=%s | 1x=%s | 5x=%s", tostring(amount), tostring(state.tok1x), tostring(state.tok5x)))
						refreshUI()
					end)
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
						addLog("ROLL_EVENT", string.format("Trait=%q | 1x=%s | 5x=%s", state.liveTrait, state.tok1x, state.tok5x))
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
			state.conflictCount += 1
			addLog("BTN_ERR", tostring(err))
			refreshUI()
		end
	end))
end

local function buildUI()
	ui.screenGui = Instance.new("ScreenGui")
	ui.screenGui.Name = APP_TAG
	ui.screenGui.ResetOnSpawn = false
	ui.screenGui.IgnoreGuiInset = true
	ui.screenGui.DisplayOrder = 230

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 595, 0, 455)
	ui.main.Position = UDim2.new(0.5, -297, 0.5, -227)
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
	title.Text = "ROLLBACK LAB v4.3 — PERSISTENT LOG & DIAGNOSTICS"
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

	ui.activateBtn = makeBtn("1. Activate Rollback", 12, 144, 152, C.accent)
	ui.confirmBtn = makeBtn("2. Confirm Rollback", 170, 144, 152, C.danger)
	ui.autoLoadBtn = makeBtn("Auto-Load: ON", 328, 144, 114, C.good)
	ui.delayBtn = makeBtn("LoadWait:3s", 448, 144, 135, C.btn)

	ui.modeBtn = makeBtn("Cut: TELEPORT", 12, 180, 145, C.btn)
	ui.copyBtn = makeBtn("Copy v4.3 Log & Report", 163, 180, 420, C.btn)

	ui.logBox = Instance.new("TextBox")
	ui.logBox.Size = UDim2.new(1, -24, 0, 224)
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
		local okQ, infoQ = armAutoLoadQueue()
		addLog("AUTOLOAD", string.format("Auto-Load=%s (%s, ok=%s)", tostring(state.autoLoadOnTp), infoQ, tostring(okQ)))
		persistStateNow()
		refreshUI()
	end)

	local delays = { 2, 4, 6, 8 }
	bindSafeClick(ui.delayBtn, function()
		local idx = 1
		for i, d in ipairs(delays) do
			if d == state.loadDelaySec then
				idx = (i % #delays) + 1
				break
			end
		end
		state.loadDelaySec = delays[idx]
		local _, infoQ = armAutoLoadQueue()
		addLog("CONFIG", string.format("Post-TP wait -> %ds (%s)", state.loadDelaySec, infoQ))
		persistStateNow()
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
		addLog("CONFIG", "Cut mode -> " .. state.exitMethod)
		persistStateNow()
		refreshUI()
	end)

	bindSafeClick(ui.copyBtn, function()
		pcall(scanGuiState)
		local diskLog = readTextSafe(LOG_FILE) or table.concat(state.logs, "\n")
		local header = {
			"=== ROLLBACK LAB v4.3 — DIAGNOSTIC LOG REPORT ===",
			ui.statusLabel.Text,
			ui.boardBox.Text,
			"--- PERSISTENT LOGS ---",
		}
		local full = table.concat(header, "\n") .. "\n" .. diskLog
		local ok = setClipboardSafe(full)
		addLog("EXPORT", ok and "Copied v4.3 log report to clipboard." or "Clipboard unavailable.")
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
	local savedRunner = ensureRunnerFileSaved()

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
		if tonumber(saved.loadDelaySec) then
			state.loadDelaySec = tonumber(saved.loadDelaySec)
		end
		if type(saved.exitMethod) == "string" then
			state.exitMethod = saved.exitMethod
		end
		if tonumber(saved.conflictCount) then
			state.conflictCount = tonumber(saved.conflictCount)
		end
		if type(saved.armedBase) == "table" then
			state.armedBase = saved.armedBase
			if saved.armedBase.unitGuid and saved.armedBase.unitGuid ~= "Unknown" then
				state.unitGuid = saved.armedBase.unitGuid
			end
		end
	end

	local prevLogRaw = readTextSafe(LOG_FILE)
	if prevLogRaw then
		for line in string.gmatch(prevLogRaw, "[^\r\n]+") do
			state.logs[#state.logs + 1] = line
			if #state.logs > 200 then
				table.remove(state.logs, 1)
			end
		end
	end

	local okQ, infoQ = armAutoLoadQueue()
	addLog("BOOT", string.format("v4.3 booted | runnerSaved=%s | %s (ok=%s)", tostring(savedRunner), infoQ, tostring(okQ)))
	checkRollbackHealth("ON_BOOT")

	if type(saved) == "table" and saved.pendingConfirm then
		evaluatePostSession()
	else
		persistStateNow()
	end

	refreshUI()
end)
