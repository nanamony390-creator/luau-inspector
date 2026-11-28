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

local SIM_TAG = "RollbackSimulator_9F3A21"
local GUARD_KEY = "__RollbackSimGuard_" .. SIM_TAG

local connections = {}
local destroyed = false
local ui = {}

local C = {
	bg = Color3.fromRGB(22, 24, 30),
	panel = Color3.fromRGB(16, 18, 23),
	card = Color3.fromRGB(30, 34, 42),
	text = Color3.fromRGB(226, 232, 242),
	dim = Color3.fromRGB(148, 156, 170),
	accent = Color3.fromRGB(56, 94, 142),
	good = Color3.fromRGB(40, 102, 78),
	warn = Color3.fromRGB(132, 86, 38),
	danger = Color3.fromRGB(134, 48, 54),
	btn = Color3.fromRGB(48, 54, 68),
}

local ENDPOINTS = {
	traitReroll = "ReplicatedStorage.endpoints.client_to_server.request_token_trait_reroll",
	traitChanged = "ReplicatedStorage.endpoints.server_to_client.token_trait_reroll_amount_changed",
	statAll = "ReplicatedStorage.endpoints.client_to_server.reroll_base_stats_all",
	sessionSync = "ReplicatedStorage.endpoints.client_to_server.get_player_session",
	teleportLobby = "ReplicatedStorage.endpoints.client_to_server.teleport_back_to_lobby",
}

local TRAIT_POOL = {
	"Superior I", "Superior II", "Superior III",
	"Swift I", "Swift II", "Range I", "Range II",
	"Culling", "Godspeed", "Monarch",
}

local function cloneState(tbl)
	return {
		unitName = tbl.unitName,
		unitUuid = tbl.unitUuid,
		trait = tbl.trait,
		tokens = tbl.tokens,
		statCubes = tbl.statCubes,
		potency = tbl.potency,
		range = tbl.range,
		speed = tbl.speed,
		revision = tbl.revision,
	}
end

local sim = {
	autoCommit = false,
	dirty = false,
	saveLocked = false,
	lastCommitClock = os.clock(),
	logs = {},
	persisted = {
		unitName = "Demon Girl",
		unitUuid = "{2cffdf92-e260-41a5-b4d8-d25a5786503e}",
		trait = "No trait",
		tokens = 25,
		statCubes = 3,
		potency = 1.172,
		range = 1.098,
		speed = 1.066,
		revision = 1,
	},
	session = nil,
}
sim.session = cloneState(sim.persisted)

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

local function detectLiveContext()
	local notes = {}
	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		if ep then
			notes[#notes + 1] = "endpoints:OK"
		end
	end
	local lp = Players and Players.LocalPlayer
	if lp then
		local pg = lp:FindFirstChildOfClass("PlayerGui")
		local tr = pg and pg:FindFirstChild("TraitReroll")
		if tr then
			local cur = tr:FindFirstChild("CurrentTraitText", true)
			if cur and cur:IsA("TextLabel") and cur.Text ~= "" then
				notes[#notes + 1] = "LiveTraitUI=" .. tostring(cur.Text)
			end
		end
	end
	return (#notes > 0) and table.concat(notes, " | ") or "Standalone Sandbox Mode"
end

local function addLog(tag, msg)
	local stamp = string.format("%.2fs", os.clock() - sim.lastCommitClock)
	local line = string.format("[%s | +%s] %s", tag, stamp, msg)
	sim.logs[#sim.logs + 1] = line
	if #sim.logs > 80 then
		table.remove(sim.logs, 1)
	end
end

local function refreshUI()
	if destroyed or not ui.main then
		return
	end

	local s = sim.session
	local p = sim.persisted
	local syncStatus = sim.dirty and "UNSAVED (Dirty Session)" or "SYNCED (Committed)"
	if sim.saveLocked then
		syncStatus = "LOCKED (DataStore Write Blocked)"
	end

	pcall(function()
		ui.statusBanner.Text = string.format(
			"State: %s | AutoCommit: %s | %s",
			syncStatus,
			sim.autoCommit and "ON" or "OFF",
			detectLiveContext()
		)
		ui.statusBanner.TextColor3 = sim.dirty and Color3.fromRGB(245, 196, 102) or Color3.fromRGB(130, 224, 170)

		ui.sessionBox.Text = table.concat({
			"=== LIVE SESSION (Client / Server RAM) ===",
			"Unit: " .. s.unitName .. " " .. s.unitUuid,
			"Trait: " .. tostring(s.trait) .. "   |   Rev: #" .. tostring(s.revision),
			"Tokens: " .. tostring(s.tokens) .. "   |   Stat Cubes: " .. tostring(s.statCubes),
			string.format("Stats: Potency %.3f | Range %.3f | Speed %.3f", s.potency, s.range, s.speed),
		}, "\n")

		ui.persistedBox.Text = table.concat({
			"=== PERSISTED DATASTORE (Last Saved) ===",
			"Unit: " .. p.unitName .. " " .. p.unitUuid,
			"Trait: " .. tostring(p.trait) .. "   |   Rev: #" .. tostring(p.revision),
			"Tokens: " .. tostring(p.tokens) .. "   |   Stat Cubes: " .. tostring(p.statCubes),
			string.format("Stats: Potency %.3f | Range %.3f | Speed %.3f", p.potency, p.range, p.speed),
		}, "\n")

		ui.autoBtn.Text = "Auto-Save: " .. (sim.autoCommit and "ON" or "OFF")
		ui.autoBtn.BackgroundColor3 = sim.autoCommit and C.good or C.btn

		ui.lockBtn.Text = "Save Lock: " .. (sim.saveLocked and "ON" or "OFF")
		ui.lockBtn.BackgroundColor3 = sim.saveLocked and C.danger or C.btn

		local viewLogs = {}
		for i = math.max(1, #sim.logs - 18), #sim.logs do
			viewLogs[#viewLogs + 1] = sim.logs[i]
		end
		ui.logBox.Text = (#viewLogs > 0) and table.concat(viewLogs, "\n") or "Ready. Trigger a reroll, then test Commit vs Rollback (Rejoin)."
	end)
end

local function commitToDataStore(reason)
	if sim.saveLocked then
		addLog("SAVE_FAIL", "DataStore write rejected (" .. reason .. ") -> Session remains dirty!")
		refreshUI()
		return false
	end
	sim.persisted = cloneState(sim.session)
	sim.dirty = false
	sim.lastCommitClock = os.clock()
	addLog("COMMIT", "Saved Rev #" .. tostring(sim.persisted.revision) .. " to DataStore (" .. reason .. ")")
	refreshUI()
	return true
end

local function doTraitRerollSim()
	local s = sim.session
	if s.tokens <= 0 then
		addLog("BLOCKED", "Insufficient Trait Tokens (0/1) on " .. ENDPOINTS.traitReroll)
		refreshUI()
		return
	end

	local oldTrait = s.trait
	local newTrait = oldTrait
	for _ = 1, 6 do
		local pick = TRAIT_POOL[math.random(1, #TRAIT_POOL)]
		if pick ~= oldTrait then
			newTrait = pick
			break
		end
	end

	s.tokens -= 1
	s.trait = newTrait
	s.revision += 1
	sim.dirty = true

	addLog("REROLL_TRAIT", string.format("%s -> Trait: %q -> %q | Tokens: %d", ENDPOINTS.traitReroll, oldTrait, newTrait, s.tokens))
	addLog("EVENT", ENDPOINTS.traitChanged .. " -> newAmount=" .. tostring(s.tokens))

	if sim.autoCommit then
		commitToDataStore("Auto-Save after Trait Reroll")
	else
		refreshUI()
	end
end

local function doStatAllRerollSim()
	local s = sim.session
	if s.statCubes <= 0 then
		addLog("BLOCKED", "Amount_NotEnough (0/1) on " .. ENDPOINTS.statAll)
		refreshUI()
		return
	end

	s.statCubes -= 1
	s.potency = math.floor((0.98 + math.random() * 0.22) * 1000) / 1000
	s.range = math.floor((0.98 + math.random() * 0.14) * 1000) / 1000
	s.speed = math.floor((0.98 + math.random() * 0.13) * 1000) / 1000
	s.revision += 1
	sim.dirty = true

	addLog("REROLL_STAT", string.format("%s -> Pot=%.3f Rng=%.3f Spd=%.3f | Cubes=%d", ENDPOINTS.statAll, s.potency, s.range, s.speed, s.statCubes))

	if sim.autoCommit then
		commitToDataStore("Auto-Save after Stat All")
	else
		refreshUI()
	end
end

local function simulateRollbackRejoin()
	addLog("REJOIN", "Simulating disconnect/teleport (" .. ENDPOINTS.teleportLobby .. ") -> reloading " .. ENDPOINTS.sessionSync)
	if sim.dirty then
		local lostTrait = sim.session.trait
		local lostRev = sim.session.revision
		sim.session = cloneState(sim.persisted)
		sim.dirty = false
		addLog("ROLLBACK_OK", string.format("Reverted unsaved Rev #%d (%q) back to saved Rev #%d (%q) | Tokens restored: %d", lostRev, lostTrait, sim.persisted.revision, sim.persisted.trait, sim.persisted.tokens))
	else
		sim.session = cloneState(sim.persisted)
		addLog("NO_ROLLBACK", "Session was already committed (Rev #" .. tostring(sim.persisted.revision) .. "). State persisted without revert.")
	end
	refreshUI()
end

local function resetSimulator()
	sim.autoCommit = false
	sim.dirty = false
	sim.saveLocked = false
	sim.lastCommitClock = os.clock()
	sim.logs = {}
	sim.persisted = {
		unitName = "Demon Girl",
		unitUuid = "{2cffdf92-e260-41a5-b4d8-d25a5786503e}",
		trait = "No trait",
		tokens = 25,
		statCubes = 3,
		potency = 1.172,
		range = 1.098,
		speed = 1.066,
		revision = 1,
	}
	sim.session = cloneState(sim.persisted)
	addLog("INIT", "Reset baseline state (Rev #1, Trait='No trait', Tokens=25, Cubes=3)")
	refreshUI()
end

local function cleanupSimulator()
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

local function buildUI()
	ui.screenGui = Instance.new("ScreenGui")
	ui.screenGui.Name = SIM_TAG
	ui.screenGui.ResetOnSpawn = false
	ui.screenGui.IgnoreGuiInset = true
	ui.screenGui.DisplayOrder = 120

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, 500, 0, 470)
	ui.main.Position = UDim2.new(0.5, -250, 0.5, -235)
	ui.main.BackgroundColor3 = C.bg
	ui.main.BorderSizePixel = 0
	ui.main.Parent = ui.screenGui

	local mCorner = Instance.new("UICorner")
	mCorner.CornerRadius = UDim.new(0, 8)
	mCorner.Parent = ui.main

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
	title.Text = "ROLLBACK LOGIC SIMULATOR (TEST SANDBOX)"
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

	ui.statusBanner = Instance.new("TextLabel")
	ui.statusBanner.Size = UDim2.new(1, -24, 0, 20)
	ui.statusBanner.Position = UDim2.new(0, 12, 0, 38)
	ui.statusBanner.BackgroundTransparency = 1
	ui.statusBanner.Font = Enum.Font.SourceSansSemibold
	ui.statusBanner.TextSize = 12
	ui.statusBanner.TextXAlignment = Enum.TextXAlignment.Left
	ui.statusBanner.Text = ""
	ui.statusBanner.Parent = ui.main

	ui.sessionBox = Instance.new("TextLabel")
	ui.sessionBox.Size = UDim2.new(1, -24, 0, 82)
	ui.sessionBox.Position = UDim2.new(0, 12, 0, 62)
	ui.sessionBox.BackgroundColor3 = C.card
	ui.sessionBox.BorderSizePixel = 0
	ui.sessionBox.TextColor3 = C.text
	ui.sessionBox.Font = Enum.Font.Code
	ui.sessionBox.TextSize = 12
	ui.sessionBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.sessionBox.TextYAlignment = Enum.TextYAlignment.Top
	ui.sessionBox.TextWrapped = true
	ui.sessionBox.Parent = ui.main
	Instance.new("UICorner", ui.sessionBox).CornerRadius = UDim.new(0, 6)
	local pad1 = Instance.new("UIPadding", ui.sessionBox)
	pad1.PaddingLeft = UDim.new(0, 8)
	pad1.PaddingTop = UDim.new(0, 6)

	ui.persistedBox = Instance.new("TextLabel")
	ui.persistedBox.Size = UDim2.new(1, -24, 0, 82)
	ui.persistedBox.Position = UDim2.new(0, 12, 0, 150)
	ui.persistedBox.BackgroundColor3 = C.panel
	ui.persistedBox.BorderSizePixel = 0
	ui.persistedBox.TextColor3 = C.dim
	ui.persistedBox.Font = Enum.Font.Code
	ui.persistedBox.TextSize = 12
	ui.persistedBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.persistedBox.TextYAlignment = Enum.TextYAlignment.Top
	ui.persistedBox.TextWrapped = true
	ui.persistedBox.Parent = ui.main
	Instance.new("UICorner", ui.persistedBox).CornerRadius = UDim.new(0, 6)
	local pad2 = Instance.new("UIPadding", ui.persistedBox)
	pad2.PaddingLeft = UDim.new(0, 8)
	pad2.PaddingTop = UDim.new(0, 6)

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

	ui.traitBtn = makeBtn("1. Trait Reroll", 12, 240, 114, C.accent)
	ui.statBtn = makeBtn("2. Stat All Reroll", 132, 240, 114, C.accent)
	ui.commitBtn = makeBtn("3. Commit Save", 252, 240, 112, C.good)
	ui.rollbackBtn = makeBtn("4. Simulate Rejoin", 370, 240, 118, C.warn)

	ui.autoBtn = makeBtn("Auto-Save: OFF", 12, 274, 152, C.btn)
	ui.lockBtn = makeBtn("Save Lock: OFF", 170, 274, 152, C.btn)
	ui.copyLogBtn = makeBtn("Copy Sim Log", 328, 274, 82, C.btn)
	ui.resetBtn = makeBtn("Reset", 416, 274, 72, C.btn)

	ui.logBox = Instance.new("TextBox")
	ui.logBox.Size = UDim2.new(1, -24, 0, 148)
	ui.logBox.Position = UDim2.new(0, 12, 0, 310)
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
	ui.logBox.Text = ""
	ui.logBox.Parent = ui.main
	Instance.new("UICorner", ui.logBox).CornerRadius = UDim.new(0, 6)
	local pad3 = Instance.new("UIPadding", ui.logBox)
	pad3.PaddingLeft = UDim.new(0, 8)
	pad3.PaddingTop = UDim.new(0, 6)
end

local function bindEvents()
	trackConn(ui.closeBtn.Activated:Connect(cleanupSimulator))
	trackConn(ui.traitBtn.Activated:Connect(doTraitRerollSim))
	trackConn(ui.statBtn.Activated:Connect(doStatAllRerollSim))
	trackConn(ui.commitBtn.Activated:Connect(function()
		commitToDataStore("Manual Commit")
	end))
	trackConn(ui.rollbackBtn.Activated:Connect(simulateRollbackRejoin))
	trackConn(ui.autoBtn.Activated:Connect(function()
		sim.autoCommit = not sim.autoCommit
		addLog("CONFIG", "Auto-Save set to " .. tostring(sim.autoCommit))
		if sim.autoCommit and sim.dirty then
			commitToDataStore("Auto-Save Enabled")
		else
			refreshUI()
		end
	end))
	trackConn(ui.lockBtn.Activated:Connect(function()
		sim.saveLocked = not sim.saveLocked
		addLog("CONFIG", "Save Lock set to " .. tostring(sim.saveLocked))
		refreshUI()
	end))
	trackConn(ui.resetBtn.Activated:Connect(resetSimulator))
	trackConn(ui.copyLogBtn.Activated:Connect(function()
		local txt = table.concat(sim.logs, "\n")
		local ok = setClipboardSafe(txt)
		addLog("EXPORT", ok and "Copied simulation log to clipboard" or "Clipboard unavailable")
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
		_G[GUARD_KEY] = { destroy = cleanupSimulator }
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
	addLog("INIT", "Sandbox ready (" .. detectLiveContext() .. ")")
	refreshUI()
end)
