local function service(name)
	local ok, result = pcall(function()
		return game:GetService(name)
	end)
	return ok and result or nil
end

local Players = service("Players")
local CoreGui = service("CoreGui")
local CollectionService = service("CollectionService")
local UserInputService = service("UserInputService")

local GUI_TAG = "RuntimeInspector_7C1E9A"
local GUARD_KEY = "__RuntimeInspectorGuard_" .. GUI_TAG
local MAX_ENTRIES = 60
local SCAN_BATCH = 40
local MIN_SCORE = 2

local W, H = 460, 520
local LIST_W = 268
local DET_X, DET_W = 288, 162
local TOP = 42
local BOTTOM_H = 76
local CONTENT_H = H - TOP - BOTTOM_H

local connections = {}
local entries = {}
local entryCount = 0
local scanToken = 0
local destroyed = false
local ui = {}

local C = {
	bg = Color3.fromRGB(24, 26, 32),
	panel = Color3.fromRGB(18, 20, 25),
	row = Color3.fromRGB(35, 38, 46),
	rowSelected = Color3.fromRGB(48, 66, 94),
	accent = Color3.fromRGB(90, 160, 255),
	text = Color3.fromRGB(224, 230, 240),
	dim = Color3.fromRGB(150, 158, 172),
	btn = Color3.fromRGB(52, 58, 72),
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

local function trackGlobal(conn)
	if conn then
		connections[#connections + 1] = conn
	end
	return conn
end

local function safe(fn, ...)
	local ok, a, b = pcall(fn, ...)
	if ok then
		return a, b
	end
	return nil
end

local function getFullName(inst)
	local ok, name = pcall(function()
		return inst:GetFullName()
	end)
	if ok then
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
		return "\"" .. value .. "\""
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

local function score(inst)
	if isSelf(inst) then
		return 0
	end
	local className = readProp(inst, "ClassName")
	if SKIP_CLASSES[className] then
		return 0
	end
	local value = 0
	if next(getAttributes(inst)) ~= nil then
		value += 4
	end
	if isA(inst, "Humanoid") then
		value += 5
	end
	if isA(inst, "Model") and readProp(inst, "PrimaryPart") then
		value += 2
	end
	if isA(inst, "ValueBase") then
		value += 2
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

	local info = entry.info
	local lines = {
		"Name: " .. info.name,
		"Class: " .. info.className,
		"Path: " .. info.fullName,
		"DebugId: " .. info.debugId,
		"",
		"Attributes (" .. countKeys(info.attrs) .. "):",
	}
	for key, value in sortedPairs(info.attrs) do
		lines[#lines + 1] = "  " .. key .. " = " .. value
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Properties:"
	for key, value in sortedPairs(info.props) do
		lines[#lines + 1] = "  " .. key .. " = " .. value
	end
	pcall(function()
		ui.details.Text = table.concat(lines, "\n")
	end)
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
	if not ui.countLabel then
		return
	end
	pcall(function()
		ui.countLabel.Text = "Tracked: " .. entryCount
	end)
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
			entry.info.attrs[tostring(attribute)] = okValue and formatValue(value) or "?"
			refreshEntry(entry)
			if ui.selected == entry then
				selectEntry(entry)
			end
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
				entry.info.props[prop] = formatValue(readProp(inst, prop))
				if ui.selected == entry then
					selectEntry(entry)
				end
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
	entryCount = math.max(0, entryCount - 1)
	if ui.selected == entry then
		ui.selected = nil
		if ui.details then
			pcall(function()
				ui.details.Text = "Select an item to inspect."
			end)
		end
	end
	updateCounts()
end

local function clearEntries()
	for inst, entry in pairs(entries) do
		clearEntry(entry)
		entries[inst] = nil
	end
	entryCount = 0
	ui.selected = nil
	if ui.details then
		pcall(function()
			ui.details.Text = "Select an item to inspect."
		end)
	end
	updateCounts()
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
	ui.toggleBtn.Position = UDim2.new(0, 20, 0, 550)
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
	ui.dragBar.Size = UDim2.new(1, -156, 0, 32)
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
	ui.title.Font = Enum.Font.GothicBold
	ui.title.TextSize = 16
	ui.title.TextXAlignment = Enum.TextXAlignment.Left
	ui.title.Text = "RUNTIME INSPECTOR"
	ui.title.Parent = ui.dragBar

	ui.countLabel = Instance.new("TextLabel")
	ui.countLabel.Size = UDim2.new(0, 140, 0, 28)
	ui.countLabel.Position = UDim2.new(1, -150, 0, 8)
	ui.countLabel.BackgroundTransparency = 1
	ui.countLabel.TextColor3 = C.dim
	ui.countLabel.Font = Enum.Font.SourceSans
	ui.countLabel.TextSize = 13
	ui.countLabel.TextXAlignment = Enum.TextXAlignment.Right
	ui.countLabel.Text = "Tracked: 0"
	ui.countLabel.Parent = ui.main

	ui.list = Instance.new("ScrollingFrame")
	ui.list.Size = UDim2.new(0, LIST_W, 0, CONTENT_H)
	ui.list.Position = UDim2.new(0, 10, 0, TOP)
	ui.list.BackgroundColor3 = C.panel
	ui.list.BorderSizePixel = 0
	ui.list.ScrollBarThickness = 6
	ui.list.CanvasSize = UDim2.new(0, 0, 0, 0)
	ui.list.AutomaticCanvasSize = Enum.AutomaticCanvasSize.Y
	ui.list.Parent = ui.main

	local listCorner = Instance.new("UICorner")
	listCorner.CornerRadius = UDim.new(0, 6)
	listCorner.Parent = ui.list

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = ui.list

	ui.details = Instance.new("TextBox")
	ui.details.Size = UDim2.new(0, DET_W, 0, CONTENT_H)
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
	ui.details.Text = "Select an item to inspect."
	ui.details.Parent = ui.main

	local detailPadding = Instance.new("UIPadding")
	detailPadding.PaddingLeft = UDim.new(0, 8)
	detailPadding.PaddingTop = UDim.new(0, 8)
	detailPadding.Parent = ui.details

	local detailCorner = Instance.new("UICorner")
	detailCorner.CornerRadius = UDim.new(0, 6)
	detailCorner.Parent = ui.details

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
		{ key = "scanBtn", label = "Scan", x = 10 },
		{ key = "clearBtn", label = "Clear", x = 120 },
		{ key = "closeBtn", label = "Close", x = 230 },
	}
	for _, def in ipairs(buttons) do
		local button = Instance.new("TextButton")
		button.Name = def.key
		button.Size = UDim2.new(0, 100, 0, 32)
		button.Position = UDim2.new(0, def.x, 0, H - 44)
		button.BackgroundColor3 = C.btn
		button.BorderSizePixel = 0
		button.TextColor3 = C.text
		button.Font = Enum.Font.SourceSansSemibold
		button.TextSize = 14
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
	trackGlobal(ui.scanBtn.Activated:Connect(function()
		if not destroyed then
			startScan()
		end
	end))

	trackGlobal(ui.clearBtn.Activated:Connect(function()
		if not destroyed then
			clearEntries()
			updateStatus("Cleared")
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

	updateStatus("Mounted via " .. tostring(source) .. " - press Scan")
	startScan()
end)
