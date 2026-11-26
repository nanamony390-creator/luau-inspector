local function service(name)
	local ok, result = pcall(function()
		return game:GetService(name)
	end)
	return ok and result or nil
end

local Players = service("Players")
local ReplicatedStorage = service("ReplicatedStorage")
local StarterPlayer = service("StarterPlayer")
local StarterGui = service("StarterGui")
local Workspace = service("Workspace")
local CoreGui = service("CoreGui")
local CollectionService = service("CollectionService")
local UserInputService = service("UserInputService")

local GUI_TAG = "RuntimeInspector_7C1E9A"
local GUARD_KEY = "__RuntimeInspectorGuard_" .. GUI_TAG
local MAX_ENTRIES = 140
local MAX_TARGET_HITS = 450
local MAX_LIVE_EVENTS = 160
local SCAN_BATCH = 90
local MIN_SCORE = 2

local W, H = 520, 585
local LIST_W = 302
local DET_X, DET_W = 322, 188
local TOP = 76
local BOTTOM_H = 118
local CONTENT_H = H - TOP - BOTTOM_H

local connections = {}
local entries = {}
local entryOrder = {}
local entryCount = 0

local inspectedHistory = {}
local inspectedSeen = {}
local liveEvents = {}
local liveEventSeen = {}
local markCounter = 0

local activeFilter = "All"
local searchQuery = ""
local rightViewMode = "Details" -- "Details" | "Live"
local scanToken = 0
local destroyed = false
local ui = {}

local C = {
	bg = Color3.fromRGB(24, 26, 32),
	panel = Color3.fromRGB(18, 20, 25),
	row = Color3.fromRGB(35, 38, 46),
	rowSelected = Color3.fromRGB(48, 66, 94),
	chipActive = Color3.fromRGB(58, 92, 138),
	markBtn = Color3.fromRGB(42, 96, 78),
	copyBtn = Color3.fromRGB(48, 66, 94),
	text = Color3.fromRGB(224, 230, 240),
	dim = Color3.fromRGB(150, 158, 172),
	btn = Color3.fromRGB(52, 58, 72),
}

local PRIORITY_KEYWORDS = {
	"trait", "reroll", "roll", "potential", "stat", "cube", "token",
	"rollback", "undo", "revert", "rejoin", "state", "save", "data",
	"remote", "event", "function", "bindable", "unit", "equip",
	"party", "invite", "trade", "gift", "craft", "blessing",
}

local VALUE_PROPS = {
	Value = true, Position = true, CFrame = true, Size = true,
	Velocity = true, Color = true, Material = true, Transparency = true,
	Anchored = true, CanCollide = true, Health = true, MaxHealth = true,
	WalkSpeed = true, Text = true, Visible = true, Enabled = true,
	Name = true, ClassName = true,
}

local SKIP_CLASSES = {
	Terrain = true, Camera = true, Decal = true, Texture = true,
	Sky = true, Atmosphere = true, BloomEffect = true,
	SunRaysEffect = true, DepthOfFieldEffect = true,
	UIGradient = true, UICorner = true, UIListLayout = true,
	UIPadding = true, UISizeConstraint = true,
	UIAspectRatioConstraint = true, UIStroke = true,
}

local function safe(fn, ...)
	local ok, a, b = pcall(fn, ...)
	if ok then
		return a, b
	end
	return nil
end

local function getGlobalFn(name)
	local okG, g = pcall(function()
		return type(getgenv) == "function" and getgenv() or nil
	end)
	if okG and type(g) == "table" and type(g[name]) == "function" then
		return g[name]
	end
	if type(_G) == "table" and type(_G[name]) == "function" then
		return _G[name]
	end
	local okDirect, fn = pcall(function()
		return _G and rawget(_G, name)
	end)
	if okDirect and type(fn) == "function" then
		return fn
	end
	return nil
end

local function copyToClipboard(text)
	local setClip = getGlobalFn("setclipboard") or getGlobalFn("toclipboard")
	if type(setClip) == "function" then
		local ok = pcall(setClip, text)
		if ok then
			return true
		end
	end
	return false
end

local function saveReportFile(text)
	local writeFn = getGlobalFn("writefile")
	if type(writeFn) == "function" then
		return pcall(writeFn, "inspector_report.txt", text)
	end
	return false
end

local function printReportChunks(text)
	local lines = string.split(text, "\n")
	for i = 1, #lines, 16 do
		local chunk = table.concat(lines, "\n", i, math.min(i + 15, #lines))
		pcall(print, chunk)
	end
end

local function trackGlobal(conn)
	if conn then
		connections[#connections + 1] = conn
	end
	return conn
end

local function getFullName(inst)
	local ok, name = pcall(function()
		return inst:GetFullName()
	end)
	if ok and type(name) == "string" then
		return name
	end
	return safe(function()
		return inst.Name
	end) or "?"
end

local function getAttributes(inst)
	local ok, attrs = pcall(function()
		return inst:GetAttributes()
	end)
	if ok and typeof(attrs) == "table" then
		return attrs
	end
	return {}
end

local function getDebugId(inst)
	local ok, id = pcall(function()
		return inst:GetDebugId()
	end)
	if ok then
		return tostring(id)
	end
	return ""
end

local function readProp(inst, prop)
	local ok, value = pcall(function()
		return inst[prop]
	end)
	if ok then
		return value
	end
	return nil
end

local function isA(inst, className)
	local ok, result = pcall(function()
		return inst:IsA(className)
	end)
	return ok and result or false
end

local function isSelf(inst)
	if not ui.screenGui then
		return false
	end
	local ok, result = pcall(function()
		return inst == ui.screenGui or inst:IsDescendantOf(ui.screenGui)
	end)
	return ok and result or false
end

local function formatValue(value)
	local kind = typeof(value)
	if kind == "nil" then
		return "nil"
	elseif kind == "string" then
		return "\"" .. string.sub(value, 1, 120) .. "\""
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	elseif kind == "Vector3" then
		return string.format("(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
	elseif kind == "CFrame" then
		local p = value.Position
		return string.format("CF(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
	elseif kind == "Color3" then
		return string.format("RGB(%.0f, %.0f, %.0f)", value.R * 255, value.G * 255, value.B * 255)
	elseif kind == "Instance" then
		return getFullName(value)
	elseif kind == "table" then
		return "table"
	end
	return tostring(value)
end

local function sortedPairs(t)
	local keys = {}
	for key in pairs(t) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local index = 0
	return function()
		index += 1
		if keys[index] == nil then
			return nil
		end
		return keys[index], t[keys[index]]
	end
end

local function countKeys(t)
	local count = 0
	for _ in pairs(t) do
		count += 1
	end
	return count
end

local function keywordWeight(inst)
	local nameLower = string.lower(tostring(readProp(inst, "Name") or ""))
	local pathLower = string.lower(getFullName(inst))
	local weight = 0
	for _, kw in ipairs(PRIORITY_KEYWORDS) do
		if string.find(nameLower, kw, 1, true) then
			weight += 5
		elseif string.find(pathLower, kw, 1, true) then
			weight += 2
		end
	end
	for k in pairs(getAttributes(inst)) do
		local keyLower = string.lower(tostring(k))
		for _, kw in ipairs(PRIORITY_KEYWORDS) do
			if string.find(keyLower, kw, 1, true) then
				weight += 3
			end
		end
	end
	return weight
end

local function isRemoteClass(className)
	return className == "RemoteEvent"
		or className == "RemoteFunction"
		or className == "BindableEvent"
		or className == "BindableFunction"
end

local function isValueClass(className)
	return className == "BoolValue"
		or className == "IntValue"
		or className == "NumberValue"
		or className == "StringValue"
		or className == "ObjectValue"
		or className == "Color3Value"
		or className == "Vector3Value"
		or className == "CFrameValue"
		or className == "RayValue"
		or className == "BrickColorValue"
end

local function isSystemOrTargetCandidate(inst)
	if isSelf(inst) then
		return false
	end
	local className = readProp(inst, "ClassName")
	if SKIP_CLASSES[className] then
		return false
	end
	if isRemoteClass(className) or className == "ModuleScript" or isValueClass(className) then
		return true
	end
	return keywordWeight(inst) > 0
end

local function score(inst)
	if isSelf(inst) then
		return 0
	end
	local className = readProp(inst, "ClassName")
	if SKIP_CLASSES[className] then
		return 0
	end
	local value = keywordWeight(inst)
	if isRemoteClass(className) then
		value += 7
	end
	if className == "ModuleScript" then
		value += 4
	end
	if next(getAttributes(inst)) ~= nil then
		value += 4
	end
	if isA(inst, "Humanoid") then
		value += 5
	end
	if isA(inst, "Model") and readProp(inst, "PrimaryPart") then
		value += 2
	end
	if isValueClass(className) or isA(inst, "ValueBase") then
		value += 3
	end
	if isA(inst, "BasePart") and readProp(inst, "Anchored") then
		value += 1
	end
	if isA(inst, "LayerCollector") then
		value += 2
	end
	if className == "Player" then
		value += 3
	end
	local okTags, tags = pcall(function()
		return CollectionService:GetTags(inst)
	end)
	if okTags and #tags > 0 then
		value += 3
	end
	return value
end

local function buildInfo(inst)
	local info = {
		name = tostring(readProp(inst, "Name") or "?"),
		className = tostring(readProp(inst, "ClassName") or "?"),
		fullName = getFullName(inst),
		debugId = getDebugId(inst),
		weight = keywordWeight(inst),
		attrs = {},
		props = {},
		propKeys = {},
	}
	for key, value in pairs(getAttributes(inst)) do
		info.attrs[tostring(key)] = formatValue(value)
	end
	for prop in pairs(VALUE_PROPS) do
		local value = readProp(inst, prop)
		if value ~= nil then
			info.props[prop] = formatValue(value)
			info.propKeys[#info.propKeys + 1] = prop
		end
	end
	local okTags, tags = pcall(function()
		return CollectionService:GetTags(inst)
	end)
	if okTags and #tags > 0 then
		info.props.Tags = table.concat(tags, ", ")
	end
	return info
end

local function formatInfoBlock(info)
	local lines = {
		"Name: " .. info.name,
		"Class: " .. info.className,
		"Path: " .. info.fullName,
		"DebugId: " .. info.debugId,
		"Attributes (" .. countKeys(info.attrs) .. "):",
	}
	for key, value in sortedPairs(info.attrs) do
		lines[#lines + 1] = "  " .. key .. " = " .. value
	end
	lines[#lines + 1] = "Properties:"
	for key, value in sortedPairs(info.props) do
		lines[#lines + 1] = "  " .. key .. " = " .. value
	end
	return table.concat(lines, "\n")
end

local function renderRightPanel()
	if not ui.details then
		return
	end
	if rightViewMode == "Live" then
		local lines = {
			"=== LIVE NOW (Mark #" .. tostring(markCounter) .. ") ===",
			"Events captured: " .. tostring(#liveEvents),
			"",
		}
		if #liveEvents == 0 then
			lines[#lines + 1] = "No changes yet after Mark Now."
			lines[#lines + 1] = "Perform action in-game (open/roll/toggle) to verify capture."
		else
			for i = math.max(1, #liveEvents - 35), #liveEvents do
				lines[#lines + 1] = liveEvents[i]
			end
		end
		pcall(function()
			ui.details.Text = table.concat(lines, "\n")
		end)
		return
	end

	if ui.selected and ui.selected.info then
		pcall(function()
			ui.details.Text = formatInfoBlock(ui.selected.info)
		end)
	else
		pcall(function()
			ui.details.Text = "Select an item to inspect, or switch to Live Now."
		end)
	end
end

local function recordInspected(info)
	local key = tostring(info.fullName) .. "|" .. tostring(info.debugId)
	if inspectedSeen[key] then
		return
	end
	inspectedSeen[key] = true
	inspectedHistory[#inspectedHistory + 1] = info
end

local function recordLiveEvent(inst, detail)
	if #liveEvents >= MAX_LIVE_EVENTS or isSelf(inst) then
		return
	end
	local path = getFullName(inst)
	local tag = (markCounter > 0) and ("[M" .. tostring(markCounter) .. "] ") or ""
	local line = string.format(
		"%s%s [%s] -> %s (%s)",
		tag,
		tostring(readProp(inst, "Name") or "?"),
		tostring(readProp(inst, "ClassName") or "?"),
		path,
		tostring(detail)
	)
	if liveEventSeen[line] then
		return
	end
	liveEventSeen[line] = true
	liveEvents[#liveEvents + 1] = line
	if rightViewMode == "Live" then
		renderRightPanel()
	end
end

local function markCurrentMoment()
	markCounter += 1
	liveEvents = {}
	liveEventSeen = {}
	rightViewMode = "Live"
	if ui.viewModeBtn then
		pcall(function()
			ui.viewModeBtn.Text = "View: Live Now"
		end)
	end
	renderRightPanel()
end

local function matchesFilterAndSearch(info)
	if activeFilter == "Target" and info.weight <= 0 then
		return false
	elseif activeFilter == "Remotes" and not isRemoteClass(info.className) then
		return false
	elseif activeFilter == "Modules" and info.className ~= "ModuleScript" then
		return false
	elseif activeFilter == "Values" and not isValueClass(info.className) then
		return false
	end

	if searchQuery ~= "" then
		local q = string.lower(searchQuery)
		if string.find(string.lower(info.name), q, 1, true)
			or string.find(string.lower(info.fullName), q, 1, true)
			or string.find(string.lower(info.className), q, 1, true)
		then
			return true
		end
		for k, v in pairs(info.attrs) do
			if string.find(string.lower(k), q, 1, true) or string.find(string.lower(v), q, 1, true) then
				return true
			end
		end
		return false
	end

	return true
end

local function refreshEntry(entry)
	local row = entry.row
	if not row then
		return
	end
	local info = entry.info
	local isSelected = (ui.selected == entry)
	pcall(function()
		row.BackgroundColor3 = isSelected and C.rowSelected or C.row
		row.Text = string.format(
			"%s [%s]  %s  (%d attrs)",
			info.name, info.className, info.fullName, countKeys(info.attrs)
		)
	end)
end

local function applyFiltersToRows()
	local shown = 0
	for _, entry in ipairs(entryOrder) do
		local visible = matchesFilterAndSearch(entry.info)
		if entry.row then
			pcall(function()
				entry.row.Visible = visible
			end)
		end
		if visible then
			shown += 1
		end
	end
	if ui.countLabel then
		pcall(function()
			ui.countLabel.Text = string.format(
				"Show: %d/%d | Log: %d | Live: %d",
				shown, entryCount, #inspectedHistory, #liveEvents
			)
		end)
	end
	for chipName, chipBtn in pairs(ui.chips or {}) do
		pcall(function()
			chipBtn.BackgroundColor3 = (chipName == activeFilter) and C.chipActive or C.btn
		end)
	end
end

local function selectEntry(entry)
	if not entry or not ui.details then
		return
	end
	local previous = ui.selected
	ui.selected = entry
	if previous and previous ~= entry then
		refreshEntry(previous)
	end
	refreshEntry(entry)
	recordInspected(entry.info)
	recordLiveEvent(entry.inst, "inspected")
	rightViewMode = "Details"
	if ui.viewModeBtn then
		pcall(function()
			ui.viewModeBtn.Text = "View: Details"
		end)
	end
	renderRightPanel()
	applyFiltersToRows()
end

local function clearEntry(entry)
	if entry.row then
		pcall(function()
			entry.row:Destroy()
		end)
		entry.row = nil
	end
	for _, conn in ipairs(entry.conns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	entry.conns = {}
end

local function createRow(entry)
	local row = Instance.new("TextButton")
	row.Name = "Row"
	row.Size = UDim2.new(1, -12, 0, 34)
	row.BackgroundColor3 = C.row
	row.BorderSizePixel = 0
	row.TextColor3 = C.text
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.Font = Enum.Font.SourceSans
	row.TextSize = 13
	row.Text = ""
	row.Visible = matchesFilterAndSearch(entry.info)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = row

	row.Parent = ui.list
	entry.row = row
	refreshEntry(entry)

	entry.conns[#entry.conns + 1] = row.Activated:Connect(function()
		if not destroyed then
			selectEntry(entry)
		end
	end)
end

local function updateCounts()
	applyFiltersToRows()
end

local function updateStatus(text)
	if not ui.statusLabel then
		return
	end
	pcall(function()
		ui.statusLabel.Text = text
	end)
end

local function addEntry(inst)
	if entries[inst] or destroyed or entryCount >= MAX_ENTRIES then
		return
	end
	if not pcall(function()
		return inst.Parent
	end) then
		return
	end

	local info = buildInfo(inst)
	local entry = { inst = inst, info = info, row = nil, conns = {} }
	entries[inst] = entry
	entryOrder[#entryOrder + 1] = entry
	entryCount += 1

	local okAttr, attrSignal = pcall(function()
		return inst.AttributeChanged
	end)
	if okAttr and attrSignal then
		local conn = attrSignal:Connect(function(attribute)
			if destroyed or entries[inst] ~= entry then
				return
			end
			local okValue, value = pcall(function()
				return inst:GetAttribute(attribute)
			end)
			local formatted = okValue and formatValue(value) or "?"
			entry.info.attrs[tostring(attribute)] = formatted
			recordLiveEvent(inst, "attr:" .. tostring(attribute) .. "=" .. formatted)
			refreshEntry(entry)
			if ui.selected == entry and rightViewMode == "Details" then
				renderRightPanel()
			end
			updateCounts()
		end)
		entry.conns[#entry.conns + 1] = conn
	end

	for _, prop in ipairs(info.propKeys) do
		local okSignal, signal = pcall(function()
			return inst:GetPropertyChangedSignal(prop)
		end)
		if okSignal and signal then
			local conn = signal:Connect(function()
				if destroyed or entries[inst] ~= entry then
					return
				end
				local formatted = formatValue(readProp(inst, prop))
				entry.info.props[prop] = formatted
				if prop == "Value" or prop == "Visible" or prop == "Text" then
					recordLiveEvent(inst, prop .. "=" .. formatted)
				end
				if ui.selected == entry and rightViewMode == "Details" then
					renderRightPanel()
				end
				updateCounts()
			end)
			entry.conns[#entry.conns + 1] = conn
		end
	end

	createRow(entry)
	updateCounts()
end

local function removeEntry(inst)
	local entry = entries[inst]
	if not entry then
		return
	end
	clearEntry(entry)
	entries[inst] = nil
	for i, item in ipairs(entryOrder) do
		if item == entry then
			table.remove(entryOrder, i)
			break
		end
	end
	entryCount = math.max(0, entryCount - 1)
	if ui.selected == entry then
		ui.selected = nil
		renderRightPanel()
	end
	updateCounts()
end

local function clearEntries()
	for inst, entry in pairs(entries) do
		clearEntry(entry)
		entries[inst] = nil
	end
	entryOrder = {}
	entryCount = 0
	ui.selected = nil
	renderRightPanel()
	updateCounts()
end

local function clearLogs()
	inspectedHistory = {}
	inspectedSeen = {}
	liveEvents = {}
	liveEventSeen = {}
	markCounter = 0
	renderRightPanel()
	updateCounts()
end

local function collectSystemReport()
	local sections = {
		"=== RUNTIME INSPECTOR FULL SYSTEM REPORT ===",
		"Target Scope: Trait Reroll / Stats & Potential Reroll / Rollback & State / Remotes",
		"Mark Index: #" .. tostring(markCounter),
		"Inspected By User Count: " .. tostring(#inspectedHistory),
		"Live Events Count: " .. tostring(#liveEvents),
		"",
		"--- [1] USER INSPECTED ITEMS ---",
	}

	if #inspectedHistory == 0 then
		sections[#sections + 1] = "(None clicked yet)"
	else
		for i, info in ipairs(inspectedHistory) do
			sections[#sections + 1] = "[" .. i .. "] " .. formatInfoBlock(info)
			sections[#sections + 1] = "----------------------------------------"
		end
	end

	sections[#sections + 1] = ""
	sections[#sections + 1] = "--- [2] LIVE NOW EVENTS ---"
	if #liveEvents == 0 then
		sections[#sections + 1] = "(No live events recorded)"
	else
		for _, line in ipairs(liveEvents) do
			sections[#sections + 1] = line
		end
	end

	sections[#sections + 1] = ""
	sections[#sections + 1] = "--- [3] MATCHED SYSTEM CANDIDATES (REMOTES / MODULES / VALUES / TRAIT / REROLL / STATE) ---"

	local roots = {}
	if ReplicatedStorage then
		roots[#roots + 1] = ReplicatedStorage
	end
	local localPlayer = Players and Players.LocalPlayer
	if localPlayer then
		roots[#roots + 1] = localPlayer
		local pg = safe(function()
			return localPlayer:FindFirstChildOfClass("PlayerGui")
		end)
		if pg then
			roots[#roots + 1] = pg
		end
	end
	if StarterPlayer then
		roots[#roots + 1] = StarterPlayer
	end
	if StarterGui then
		roots[#roots + 1] = StarterGui
	end
	if Workspace then
		roots[#roots + 1] = Workspace
	end

	local candidates = {}
	local seenPaths = {}

	for _, root in ipairs(roots) do
		local okDesc, desc = pcall(function()
			return root:GetDescendants()
		end)
		if okDesc and type(desc) == "table" then
			for _, inst in ipairs(desc) do
				if typeof(inst) == "Instance" and isSystemOrTargetCandidate(inst) then
					local info = buildInfo(inst)
					if not seenPaths[info.fullName] then
						seenPaths[info.fullName] = true
						candidates[#candidates + 1] = info
					end
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		if a.weight ~= b.weight then
			return a.weight > b.weight
		end
		return tostring(a.fullName) < tostring(b.fullName)
	end)

	local matched = math.min(#candidates, MAX_TARGET_HITS)
	for i = 1, matched do
		local info = candidates[i]
		sections[#sections + 1] = string.format(
			"• [w=%d] %s [%s] -> %s",
			info.weight, info.name, info.className, info.fullName
		)
		if countKeys(info.attrs) > 0 then
			for k, v in sortedPairs(info.attrs) do
				sections[#sections + 1] = "    attr " .. k .. " = " .. v
			end
		end
		if info.props.Value ~= nil then
			sections[#sections + 1] = "    Value = " .. tostring(info.props.Value)
		end
		if info.props.Visible ~= nil then
			sections[#sections + 1] = "    Visible = " .. tostring(info.props.Visible)
		end
	end

	sections[#sections + 1] = ""
	sections[#sections + 1] = string.format("Total Matched System Items: %d (of %d found)", matched, #candidates)
	return table.concat(sections, "\n"), matched
end

local function startScan()
	scanToken += 1
	local token = scanToken
	clearEntries()

	local okList, list = pcall(function()
		return game:GetDescendants()
	end)
	if not okList or type(list) ~= "table" then
		updateStatus("Scan failed")
		return
	end

	local index = 1
	updateStatus("Scanning 0/" .. #list)

	task.defer(function()
		while not destroyed
			and token == scanToken
			and index <= #list
			and entryCount < MAX_ENTRIES
		do
			local processed = 0
			while index <= #list and processed < SCAN_BATCH and entryCount < MAX_ENTRIES do
				local inst = list[index]
				index += 1
				processed += 1
				if typeof(inst) == "Instance" then
					local value = score(inst)
					if value >= MIN_SCORE then
						addEntry(inst)
					end
				end
			end
			updateStatus(string.format("Scanning %d/%d - %d shown", index - 1, #list, entryCount))
			task.wait()
		end
		if not destroyed and token == scanToken then
			updateStatus(string.format("Done - %d/%d scanned, %d shown", index - 1, #list, entryCount))
		end
	end)
end

local function setVisible(visible)
	if not ui.main then
		return
	end
	local ok = pcall(function()
		ui.main.Visible = visible
	end)
	if ok then
		ui.visible = visible
		pcall(function()
			ui.toggleBtn.Text = visible and "Hide" or "Show"
		end)
	end
end

local function destroy()
	if destroyed then
		return
	end
	destroyed = true
	scanToken += 1

	for _, conn in ipairs(connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	connections = {}

	for inst, entry in pairs(entries) do
		clearEntry(entry)
		entries[inst] = nil
	end
	entryOrder = {}
	entryCount = 0

	if ui.screenGui then
		pcall(function()
			ui.screenGui:Destroy()
		end)
	end
	ui = {}
end

local function buildUI()
	ui.screenGui = Instance.new("ScreenGui")
	ui.screenGui.Name = GUI_TAG
	ui.screenGui.ResetOnSpawn = false
	ui.screenGui.IgnoreGuiInset = true
	ui.screenGui.DisplayOrder = 100
	ui.screenGui.Enabled = true

	ui.toggleBtn = Instance.new("TextButton")
	ui.toggleBtn.Name = "Toggle"
	ui.toggleBtn.Size = UDim2.new(0, 86, 0, 26)
	ui.toggleBtn.Position = UDim2.new(0, 20, 0, 615)
	ui.toggleBtn.BackgroundColor3 = C.btn
	ui.toggleBtn.BorderSizePixel = 0
	ui.toggleBtn.TextColor3 = C.text
	ui.toggleBtn.Font = Enum.Font.SourceSansSemibold
	ui.toggleBtn.TextSize = 13
	ui.toggleBtn.Text = "Hide"
	ui.toggleBtn.Parent = ui.screenGui

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 5)
	toggleCorner.Parent = ui.toggleBtn

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, W, 0, H)
	ui.main.Position = UDim2.new(0, 20, 0, 20)
	ui.main.BackgroundColor3 = C.bg
	ui.main.BorderSizePixel = 0
	ui.main.Parent = ui.screenGui

	local mainCorner = Instance.new("UICorner")
	mainCorner.CornerRadius = UDim.new(0, 8)
	mainCorner.Parent = ui.main

	ui.dragBar = Instance.new("TextButton")
	ui.dragBar.Name = "DragBar"
	ui.dragBar.Size = UDim2.new(1, -225, 0, 30)
	ui.dragBar.Position = UDim2.new(0, 10, 0, 6)
	ui.dragBar.BackgroundTransparency = 1
	ui.dragBar.Text = ""
	ui.dragBar.AutoButtonColor = false
	ui.dragBar.Parent = ui.main

	ui.title = Instance.new("TextLabel")
	ui.title.Size = UDim2.new(1, 0, 1, 0)
	ui.title.Position = UDim2.new(0, 0, 0, 0)
	ui.title.BackgroundTransparency = 1
	ui.title.TextColor3 = C.text
	ui.title.Font = Enum.Font.GothamBold
	ui.title.TextSize = 15
	ui.title.TextXAlignment = Enum.TextXAlignment.Left
	ui.title.Text = "RUNTIME INSPECTOR"
	ui.title.Parent = ui.dragBar

	ui.countLabel = Instance.new("TextLabel")
	ui.countLabel.Size = UDim2.new(0, 215, 0, 26)
	ui.countLabel.Position = UDim2.new(1, -225, 0, 8)
	ui.countLabel.BackgroundTransparency = 1
	ui.countLabel.TextColor3 = C.dim
	ui.countLabel.Font = Enum.Font.SourceSans
	ui.countLabel.TextSize = 12
	ui.countLabel.TextXAlignment = Enum.TextXAlignment.Right
	ui.countLabel.Text = "Show: 0/0 | Log: 0 | Live: 0"
	ui.countLabel.Parent = ui.main

	ui.searchBox = Instance.new("TextBox")
	ui.searchBox.Name = "SearchBox"
	ui.searchBox.Size = UDim2.new(0, LIST_W, 0, 26)
	ui.searchBox.Position = UDim2.new(0, 10, 0, 40)
	ui.searchBox.BackgroundColor3 = C.panel
	ui.searchBox.BorderSizePixel = 0
	ui.searchBox.TextColor3 = C.text
	ui.searchBox.PlaceholderColor3 = C.dim
	ui.searchBox.PlaceholderText = "Search trait, reroll, stat, remote, path..."
	ui.searchBox.Font = Enum.Font.SourceSans
	ui.searchBox.TextSize = 13
	ui.searchBox.TextXAlignment = Enum.TextXAlignment.Left
	ui.searchBox.ClearTextOnFocus = false
	ui.searchBox.Text = ""
	ui.searchBox.Parent = ui.main

	local searchPad = Instance.new("UIPadding")
	searchPad.PaddingLeft = UDim.new(0, 8)
	searchPad.PaddingRight = UDim.new(0, 8)
	searchPad.Parent = ui.searchBox

	local searchCorner = Instance.new("UICorner")
	searchCorner.CornerRadius = UDim.new(0, 5)
	searchCorner.Parent = ui.searchBox

	ui.chips = {}
	local chipDefs = {
		{ name = "All", x = 322, w = 32 },
		{ name = "Target", x = 357, w = 44 },
		{ name = "Remotes", x = 404, w = 52 },
		{ name = "Modules", x = 459, w = 51 },
	}
	for _, cdef in ipairs(chipDefs) do
		local chip = Instance.new("TextButton")
		chip.Name = "Chip_" .. cdef.name
		chip.Size = UDim2.new(0, cdef.w, 0, 26)
		chip.Position = UDim2.new(0, cdef.x, 0, 40)
		chip.BackgroundColor3 = (cdef.name == activeFilter) and C.chipActive or C.btn
		chip.BorderSizePixel = 0
		chip.TextColor3 = C.text
		chip.Font = Enum.Font.SourceSansSemibold
		chip.TextSize = 11
		chip.Text = cdef.name
		chip.Parent = ui.main

		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 5)
		cc.Parent = chip

		ui.chips[cdef.name] = chip
	end

	ui.list = Instance.new("ScrollingFrame")
	ui.list.Size = UDim2.new(0, LIST_W, 0, CONTENT_H)
	ui.list.Position = UDim2.new(0, 10, 0, TOP)
	ui.list.BackgroundColor3 = C.panel
	ui.list.BorderSizePixel = 0
	ui.list.ScrollBarThickness = 6
	ui.list.CanvasSize = UDim2.new(0, 0, 0, 0)
	ui.list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	ui.list.Parent = ui.main

	local listCorner = Instance.new("UICorner")
	listCorner.CornerRadius = UDim.new(0, 6)
	listCorner.Parent = ui.list

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = ui.list

	ui.details = Instance.new("TextBox")
	ui.details.Size = UDim2.new(0, DET_W, 0, CONTENT_H - 58)
	ui.details.Position = UDim2.new(0, DET_X, 0, TOP)
	ui.details.BackgroundColor3 = C.panel
	ui.details.BorderSizePixel = 0
	ui.details.TextColor3 = C.text
	ui.details.Font = Enum.Font.SourceSans
	ui.details.TextSize = 12
	ui.details.TextXAlignment = Enum.TextXAlignment.Left
	ui.details.TextYAlignment = Enum.TextYAlignment.Top
	ui.details.TextWrapped = true
	ui.details.TextEditable = false
	ui.details.ClearTextOnFocus = false
	ui.details.Text = "Select an item to inspect, or switch to Live Now."
	ui.details.Parent = ui.main

	local detailPadding = Instance.new("UIPadding")
	detailPadding.PaddingLeft = UDim.new(0, 8)
	detailPadding.PaddingTop = UDim.new(0, 8)
	detailPadding.Parent = ui.details

	local detailCorner = Instance.new("UICorner")
	detailCorner.CornerRadius = UDim.new(0, 6)
	detailCorner.Parent = ui.details

	ui.viewModeBtn = Instance.new("TextButton")
	ui.viewModeBtn.Name = "ViewMode"
	ui.viewModeBtn.Size = UDim2.new(0, DET_W, 0, 24)
	ui.viewModeBtn.Position = UDim2.new(0, DET_X, 0, TOP + CONTENT_H - 52)
	ui.viewModeBtn.BackgroundColor3 = C.btn
	ui.viewModeBtn.BorderSizePixel = 0
	ui.viewModeBtn.TextColor3 = C.text
	ui.viewModeBtn.Font = Enum.Font.SourceSansSemibold
	ui.viewModeBtn.TextSize = 12
	ui.viewModeBtn.Text = "View: Details"
	ui.viewModeBtn.Parent = ui.main

	local viewModeCorner = Instance.new("UICorner")
	viewModeCorner.CornerRadius = UDim.new(0, 5)
	viewModeCorner.Parent = ui.viewModeBtn

	ui.copyPathBtn = Instance.new("TextButton")
	ui.copyPathBtn.Name = "CopyPath"
	ui.copyPathBtn.Size = UDim2.new(0, DET_W, 0, 24)
	ui.copyPathBtn.Position = UDim2.new(0, DET_X, 0, TOP + CONTENT_H - 24)
	ui.copyPathBtn.BackgroundColor3 = C.btn
	ui.copyPathBtn.BorderSizePixel = 0
	ui.copyPathBtn.TextColor3 = C.text
	ui.copyPathBtn.Font = Enum.Font.SourceSansSemibold
	ui.copyPathBtn.TextSize = 12
	ui.copyPathBtn.Text = "Copy Selected Path"
	ui.copyPathBtn.Parent = ui.main

	local copyPathCorner = Instance.new("UICorner")
	copyPathCorner.CornerRadius = UDim.new(0, 5)
	copyPathCorner.Parent = ui.copyPathBtn

	ui.statusLabel = Instance.new("TextLabel")
	ui.statusLabel.Size = UDim2.new(1, -20, 0, 20)
	ui.statusLabel.Position = UDim2.new(0, 10, 0, TOP + CONTENT_H + 6)
	ui.statusLabel.BackgroundTransparency = 1
	ui.statusLabel.TextColor3 = C.dim
	ui.statusLabel.Font = Enum.Font.SourceSans
	ui.statusLabel.TextSize = 12
	ui.statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	ui.statusLabel.Text = "Idle"
	ui.statusLabel.Parent = ui.main

	local buttons = {
		{ key = "scanBtn", label = "Scan", x = 10, y = H - 78, w = 115, bg = C.btn },
		{ key = "clearBtn", label = "Clear", x = 135, y = H - 78, w = 115, bg = C.btn },
		{ key = "clearLogBtn", label = "Clear Log", x = 260, y = H - 78, w = 115, bg = C.btn },
		{ key = "closeBtn", label = "Close", x = 385, y = H - 78, w = 125, bg = C.btn },
		{ key = "copyBtn", label = "Copy Full Report", x = 10, y = H - 40, w = 240, bg = C.copyBtn },
		{ key = "markBtn", label = "Mark Now", x = 260, y = H - 40, w = 250, bg = C.markBtn },
	}
	for _, def in ipairs(buttons) do
		local button = Instance.new("TextButton")
		button.Name = def.key
		button.Size = UDim2.new(0, def.w, 0, 32)
		button.Position = UDim2.new(0, def.x, 0, def.y)
		button.BackgroundColor3 = def.bg
		button.BorderSizePixel = 0
		button.TextColor3 = C.text
		button.Font = Enum.Font.SourceSansSemibold
		button.TextSize = 13
		button.Text = def.label
		button.Parent = ui.main

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = button

		ui[def.key] = button
	end

	ui.visible = true
	ui.selected = nil
end

local function bindDrag()
	if not ui.dragBar or not ui.main or not UserInputService then
		return
	end
	local dragging = false
	local dragStart = nil
	local startPos = nil

	trackGlobal(ui.dragBar.InputBegan:Connect(function(input)
		if destroyed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = ui.main.Position
		end
	end))

	trackGlobal(UserInputService.InputChanged:Connect(function(input)
		if destroyed or not dragging or not dragStart or not startPos then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			pcall(function()
				ui.main.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end)
		end
	end))

	trackGlobal(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			dragStart = nil
			startPos = nil
		end
	end))
end

local function bindUI()
	trackGlobal(ui.searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if not destroyed then
			searchQuery = tostring(ui.searchBox.Text or "")
			applyFiltersToRows()
		end
	end))

	for chipName, chipBtn in pairs(ui.chips or {}) do
		trackGlobal(chipBtn.Activated:Connect(function()
			if not destroyed then
				activeFilter = chipName
				applyFiltersToRows()
				updateStatus("Filter: " .. chipName)
			end
		end))
	end

	trackGlobal(ui.viewModeBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		rightViewMode = (rightViewMode == "Details") and "Live" or "Details"
		ui.viewModeBtn.Text = (rightViewMode == "Details") and "View: Details" or "View: Live Now"
		renderRightPanel()
	end))

	trackGlobal(ui.copyPathBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		if ui.selected and ui.selected.info and ui.selected.info.fullName then
			local pathStr = ui.selected.info.fullName
			local ok = copyToClipboard(pathStr)
			updateStatus(ok and ("Path copied: " .. pathStr) or ("Path: " .. pathStr))
		else
			updateStatus("No item selected")
		end
	end))

	trackGlobal(ui.markBtn.Activated:Connect(function()
		if not destroyed then
			markCurrentMoment()
			updateCounts()
			updateStatus("Marked Now #" .. tostring(markCounter) .. " - perform action in-game")
		end
	end))

	trackGlobal(ui.scanBtn.Activated:Connect(function()
		if not destroyed then
			startScan()
		end
	end))

	trackGlobal(ui.clearBtn.Activated:Connect(function()
		if not destroyed then
			clearEntries()
			updateStatus("Cleared list (Log & Live kept)")
		end
	end))

	trackGlobal(ui.clearLogBtn.Activated:Connect(function()
		if not destroyed then
			clearLogs()
			updateStatus("Cleared User Log & Live Events")
		end
	end))

	trackGlobal(ui.copyBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		local reportText, matchedCount = collectSystemReport()
		local copied = copyToClipboard(reportText)
		local savedFile = saveReportFile(reportText)
		printReportChunks(reportText)

		if copied then
			updateStatus("Report copied (" .. matchedCount .. " items)")
		elseif savedFile then
			updateStatus("Saved inspector_report.txt + printed to Output")
		else
			pcall(function()
				ui.details.Text = reportText
			end)
			updateStatus("Printed to Output + shown in Details box")
		end
	end))

	trackGlobal(ui.closeBtn.Activated:Connect(function()
		destroy()
	end))

	trackGlobal(ui.toggleBtn.Activated:Connect(function()
		if not destroyed then
			setVisible(not ui.visible)
		end
	end))

	trackGlobal(ui.screenGui.AncestryChanged:Connect(function(_, parent)
		if parent == nil and not destroyed then
			destroy()
		end
	end))

	trackGlobal(game.DescendantAdded:Connect(function(inst)
		if destroyed or entryCount >= MAX_ENTRIES then
			return
		end
		task.defer(function()
			if destroyed or isSelf(inst) or entryCount >= MAX_ENTRIES then
				return
			end
			if not pcall(function()
				return inst.Parent
			end) then
				return
			end
			if keywordWeight(inst) > 0 then
				recordLiveEvent(inst, "added")
				updateCounts()
			end
			if score(inst) >= MIN_SCORE then
				addEntry(inst)
			end
		end)
	end))

	trackGlobal(game.DescendantRemoving:Connect(function(inst)
		if destroyed then
			return
		end
		removeEntry(inst)
	end))

	bindDrag()
end

local previous = safe(function()
	return _G[GUARD_KEY]
end)
if type(previous) == "table" and type(previous.destroy) == "function" then
	pcall(previous.destroy)
end

pcall(function()
	if type(_G) == "table" then
		_G[GUARD_KEY] = { destroy = destroy }
	end
end)

task.defer(function()
	local container, source = safe(function()
		if typeof(gethui) == "function" then
			local success, hui = pcall(gethui)
			if success and typeof(hui) == "Instance" then
				return hui, "gethui"
			end
		end
		return nil, nil
	end)

	if not container then
		local okCore, core = pcall(function()
			return CoreGui
		end)
		if okCore and typeof(core) == "Instance" then
			container, source = core, "CoreGui"
		end
	end

	if not container then
		local okPlayerGui, playerGui = pcall(function()
			local localPlayer = Players and Players.LocalPlayer
			if localPlayer then
				return localPlayer:WaitForChild("PlayerGui", 5)
			end
			return nil
		end)
		if okPlayerGui and typeof(playerGui) == "Instance" then
			container, source = playerGui, "PlayerGui"
		end
	end

	if not container then
		return
	end

	pcall(function()
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("ScreenGui") and child.Name == GUI_TAG then
				child:Destroy()
			end
		end
	end)

	buildUI()
	bindUI()

	local okParent = pcall(function()
		ui.screenGui.Parent = container
	end)
	if not okParent then
		destroy()
		return
	end

	updateStatus("Mounted via " .. tostring(source) .. " - press Scan or Mark Now")
	startScan()
end)
