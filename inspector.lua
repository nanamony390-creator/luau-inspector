local function getServiceSafe(name)
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	return ok and svc or nil
end

local Players = getServiceSafe("Players")
local ReplicatedStorage = getServiceSafe("ReplicatedStorage")
local CoreGui = getServiceSafe("CoreGui")
local CollectionService = getServiceSafe("CollectionService")
local UserInputService = getServiceSafe("UserInputService")
local TeleportService = getServiceSafe("TeleportService")

local GUI_TAG = "RuntimeInspector_7C1E9A"
local GUARD_KEY = "__RuntimeInspectorGuard_" .. GUI_TAG
local MAX_ENTRIES = 160
local MAX_TARGET_HITS = 500
local MAX_LIVE_EVENTS = 250
local SCAN_BATCH = 90
local MIN_SCORE = 2

local W, H = 530, 585
local LIST_W = 302
local DET_X, DET_W = 322, 198
local TOP = 76
local BOTTOM_H = 116
local CONTENT_H = H - TOP - BOTTOM_H

local connections = {}
local entries = {}
local entryOrder = {}
local entryCount = 0

local inspectedHistory = {}
local inspectedSeen = {}
local liveEvents = {}
local liveEventSeen = {}
local touchedPaths = {}
local touchedOrder = {}
local markCounter = 0
local markStartClock = os.clock()
local lastEventClock = nil
local snapshotText = ""
local prevSnapshotMap = nil
local lastDiffSummary = ""

local activeFilter = "All"
local searchQuery = ""
local rightViewMode = "Details" -- "Details" | "Live" | "Snapshot"
local scanToken = 0
local destroyed = false
local safeCallsHooked = 0
local hookedRemotes = {}
local remoteInventory = {}
local remoteInventorySeen = {}
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

local TARGET_KEYWORDS = {
	"trait", "traitreroll", "reroll", "roll", "potential",
	"stat", "statreroll", "base_stats", "curse", "cube", "token", "quantity",
	"rollback", "undo", "revert", "rejoin", "confirm", "activate",
	"teleport", "session", "sync", "state", "save", "data", "store",
	"unit", "equip", "profile", "pet", "endpoint", "snapshot", "backup",
}

local NOISE_PATH_PATTERNS = {
	"leaderboard",
	"_eventleaderboard",
	"tradinglist",
	"partyinvitelist",
	"giftinglist",
	"experiencechat",
	"chatwindow",
	"_overhead",
	"_fx_cache",
	"collection.grid.list.outer.unitframes",
	"lobby_assets",
	"packages.",
	"surfacegui",
}

local NOISE_EXACT_NAMES = {
	"rainbow",
	"scaledampeningpercent",
	"avatarpartscaletype",
	"_root",
	"_parent_folder",
	"_player",
	"spinning",
	"border",
	"bordershadow",
	"pattern",
	"line",
	"backgroundglow",
	"bannerdecoht",
	"bannerdecoglow",
	"titleimage",
}

local VALUE_PROPS = {
	Value = true, Text = true, Visible = true, Enabled = true,
	Name = true, ClassName = true,
}

local SKIP_CLASSES = {
	Terrain = true, Camera = true, Decal = true, Texture = true,
	Sky = true, Atmosphere = true, BloomEffect = true,
	SunRaysEffect = true, DepthOfFieldEffect = true,
	UIGradient = true, UICorner = true, UIListLayout = true, UIGridLayout = true,
	UIPadding = true, UISizeConstraint = true,
	UIAspectRatioConstraint = true, UIStroke = true,
	BillboardGui = true, SurfaceGui = true,
	WorldModel = true, ViewportFrame = true, Bone = true,
	BodyColors = true, Shirt = true, Pants = true,
	RopeConstraint = true, AlignPosition = true, AlignOrientation = true,
	MeshPart = true, Part = true, UnionOperation = true, WedgePart = true, CornerWedgePart = true,
	Weld = true, WeldConstraint = true, Motor6D = true, Attachment = true,
	ParticleEmitter = true, Beam = true, Trail = true, Light = true, PointLight = true, SpotLight = true, SurfaceLight = true,
	Sound = true, SpecialMesh = true, SurfaceAppearance = true,
	Humanoid = true, Animator = true, AnimationController = true,
}

local function safeCall(fn, ...)
	local ok, a, b = pcall(fn, ...)
	if ok then
		return a, b
	end
	return nil
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

local function printChunksSafe(text)
	local lines = string.split(text, "\n")
	for i = 1, #lines, 16 do
		local part = table.concat(lines, "\n", i, math.min(i + 15, #lines))
		pcall(print, part)
	end
end

local function trackConn(conn)
	if conn then
		connections[#connections + 1] = conn
	end
	return conn
end

local function propSafe(inst, propName)
	local ok, val = pcall(function()
		return inst[propName]
	end)
	return ok and val or nil
end

local function isClass(inst, className)
	local ok, res = pcall(function()
		return inst:IsA(className)
	end)
	return ok and res or false
end

local function fullPathSafe(inst)
	local ok, path = pcall(function()
		return inst:GetFullName()
	end)
	if ok and type(path) == "string" then
		return path
	end
	return tostring(propSafe(inst, "Name") or "?")
end

local function parentPathSafe(inst)
	local okP, par = pcall(function()
		return inst.Parent
	end)
	if okP and typeof(par) == "Instance" then
		return fullPathSafe(par)
	end
	return "nil"
end

local function attrsSafe(inst)
	local ok, attrs = pcall(function()
		return inst:GetAttributes()
	end)
	return (ok and typeof(attrs) == "table") and attrs or {}
end

local function debugIdSafe(inst)
	local ok, id = pcall(function()
		return inst:GetDebugId()
	end)
	return ok and tostring(id) or ""
end

local function isOwnGui(inst)
	if not ui.screenGui then
		return false
	end
	local ok, res = pcall(function()
		return inst == ui.screenGui or inst:IsDescendantOf(ui.screenGui)
	end)
	return ok and res or false
end

local function isLocalPlayerOwnedPet(inst)
	local lp = Players and Players.LocalPlayer
	if not lp then
		return true
	end
	local playerVal = safeCall(function()
		return inst:FindFirstChild("_player")
	end)
	if playerVal and isClass(playerVal, "ObjectValue") then
		local owner = propSafe(playerVal, "Value")
		if owner and owner ~= lp then
			return false
		end
	end
	return true
end

local function isNoisePath(pathLower)
	if not pathLower or pathLower == "" then
		return false
	end
	for _, pat in ipairs(NOISE_PATH_PATTERNS) do
		if string.find(pathLower, pat, 1, true) then
			return true
		end
	end
	if string.find(pathLower, "players.", 1, true) then
		local lp = Players and Players.LocalPlayer
		local lpName = lp and string.lower(tostring(propSafe(lp, "Name") or "")) or ""
		if lpName ~= "" then
			local prefix = "players." .. lpName
			if not string.find(pathLower, prefix, 1, true) then
				return true
			end
		end
	end
	return false
end

local function isLiveNoise(inst, pathLower)
	if isNoisePath(pathLower) then
		return true
	end
	local nameL = string.lower(tostring(propSafe(inst, "Name") or ""))
	for _, n in ipairs(NOISE_EXACT_NAMES) do
		if nameL == n then
			return true
		end
	end
	return false
end

local function isRerollGuiPath(pathLower)
	if not pathLower or pathLower == "" then
		return false
	end
	return string.find(pathLower, "statreroll", 1, true) ~= nil
		or string.find(pathLower, "traitreroll", 1, true) ~= nil
		or string.find(pathLower, "reroll", 1, true) ~= nil
end

local function isRelevantRerollSnapshotNode(inst, pathLower)
	if not isRerollGuiPath(pathLower) then
		return false
	end
	local nameL = string.lower(tostring(propSafe(inst, "Name") or ""))
	for _, n in ipairs(NOISE_EXACT_NAMES) do
		if nameL == n then
			return false
		end
	end
	local cls = propSafe(inst, "ClassName")
	if cls == "TextButton" or cls == "ImageButton" or cls == "TextBox" then
		return true
	end
	if cls == "TextLabel" then
		local txt = tostring(propSafe(inst, "Text") or "")
		if txt ~= "" and (
			string.find(nameL, "quantity", 1, true)
			or string.find(nameL, "stat", 1, true)
			or string.find(nameL, "trait", 1, true)
			or string.find(nameL, "level", 1, true)
			or string.find(nameL, "name", 1, true)
			or string.find(nameL, "title", 1, true)
			or string.find(nameL, "note", 1, true)
			or string.find(nameL, "cost", 1, true)
		) then
			return true
		end
	end
	return string.find(nameL, "reroll", 1, true) ~= nil
		or string.find(nameL, "quantity", 1, true) ~= nil
		or string.find(nameL, "stat", 1, true) ~= nil
		or string.find(nameL, "trait", 1, true) ~= nil
		or string.find(nameL, "receiveunit", 1, true) ~= nil
end

local function isActionableRerollControl(inst, pathLower)
	if not isRerollGuiPath(pathLower) then
		return false
	end
	if isLiveNoise(inst, pathLower) then
		return false
	end
	local cls = propSafe(inst, "ClassName")
	if cls == "TextButton" or cls == "ImageButton" or cls == "TextBox" then
		return true
	end
	local nameL = string.lower(tostring(propSafe(inst, "Name") or ""))
	return string.find(nameL, "quantity", 1, true) ~= nil
		or string.find(nameL, "trait", 1, true) ~= nil
		or string.find(nameL, "stat", 1, true) ~= nil
		or string.find(nameL, "confirm", 1, true) ~= nil
		or string.find(nameL, "roll", 1, true) ~= nil
end

local function classifyPhase(rawLineLower, pathLower)
	if string.find(rawLineLower, "[fn]", 1, true)
		or string.find(rawLineLower, "[ev]", 1, true)
		or string.find(pathLower, "endpoints", 1, true)
	then
		return "REROLL/REMOTE"
	end
	if string.find(rawLineLower, "teleport", 1, true)
		or string.find(rawLineLower, "rejoin", 1, true)
		or string.find(rawLineLower, "rollback", 1, true)
		or string.find(rawLineLower, "revert", 1, true)
	then
		return "FLOW/TELEPORT"
	end
	if string.find(rawLineLower, "attr:", 1, true)
		or string.find(rawLineLower, "value (", 1, true)
		or string.find(rawLineLower, "visible (", 1, true)
	then
		return "STATE/VAL"
	end
	if isRerollGuiPath(pathLower) then
		return "REROLL/UI"
	end
	return "UI/NODE"
end

local function recordTouchedPath(pathStr, phase)
	if not pathStr or pathStr == "" then
		return
	end
	if not touchedPaths[pathStr] then
		touchedPaths[pathStr] = { count = 1, lastPhase = phase }
		touchedOrder[#touchedOrder + 1] = pathStr
	else
		touchedPaths[pathStr].count += 1
		touchedPaths[pathStr].lastPhase = phase
	end
end

local function formatTimingTag()
	local now = os.clock()
	local sinceMark = math.max(0, now - markStartClock)
	local delta = lastEventClock and math.max(0, now - lastEventClock) or sinceMark
	lastEventClock = now
	return string.format("t=+%.2fs | dt=+%.2fs", sinceMark, delta)
end

local function serializeArg(val, depth)
	depth = depth or 0
	if depth > 2 then
		return "{...}"
	end
	local t = typeof(val)
	if t == "nil" then
		return "nil"
	elseif t == "string" then
		return "\"" .. string.sub(val, 1, 90) .. "\""
	elseif t == "number" or t == "boolean" then
		return tostring(val)
	elseif t == "Instance" then
		return fullPathSafe(val)
	elseif t == "Vector3" then
		return string.format("(%.1f,%.1f,%.1f)", val.X, val.Y, val.Z)
	elseif t == "table" then
		local parts = {}
		local count = 0
		for k, v in pairs(val) do
			count += 1
			if count > 8 then
				parts[#parts + 1] = "..."
				break
			end
			parts[#parts + 1] = tostring(k) .. "=" .. serializeArg(v, depth + 1)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(val)
end

local function fmtVal(val)
	return serializeArg(val, 0)
end

local function pairsSorted(tbl)
	local keys = {}
	for k in pairs(tbl) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local idx = 0
	return function()
		idx += 1
		if keys[idx] == nil then
			return nil
		end
		return keys[idx], tbl[keys[idx]]
	end
end

local function keyCount(tbl)
	local n = 0
	for _ in pairs(tbl) do
		n += 1
	end
	return n
end

local function isRemoteKind(className)
	return className == "RemoteEvent"
		or className == "RemoteFunction"
		or className == "BindableEvent"
		or className == "BindableFunction"
		or className == "UnreliableRemoteEvent"
end

local function isValueKind(className)
	return className == "BoolValue"
		or className == "IntValue"
		or className == "NumberValue"
		or className == "StringValue"
		or className == "ObjectValue"
end

local function targetWeight(inst)
	local pathStr = fullPathSafe(inst)
	local pathL = string.lower(pathStr)
	if isNoisePath(pathL) then
		return 0
	end
	local nameL = string.lower(tostring(propSafe(inst, "Name") or ""))
	local w = 0
	if string.find(pathL, "endpoints", 1, true) then
		w += 12
	end
	if string.find(nameL, "reroll_base_stats_all", 1, true) then
		w += 15
	end
	if isRerollGuiPath(pathL) then
		w += 9
	end
	if string.find(nameL, "reroll", 1, true)
		or string.find(nameL, "rollback", 1, true)
		or string.find(nameL, "rejoin", 1, true)
		or string.find(nameL, "save", 1, true)
		or string.find(nameL, "data", 1, true)
	then
		w += 6
	end
	for _, kw in ipairs(TARGET_KEYWORDS) do
		if string.find(nameL, kw, 1, true) then
			w += 5
		elseif string.find(pathL, kw, 1, true) then
			w += 2
		end
	end
	for attrName in pairs(attrsSafe(inst)) do
		local attrL = string.lower(tostring(attrName))
		for _, kw in ipairs(TARGET_KEYWORDS) do
			if string.find(attrL, kw, 1, true) then
				w += 3
			end
		end
	end
	return w
end

local function isTargetCandidate(inst)
	if isOwnGui(inst) then
		return false
	end
	local cls = propSafe(inst, "ClassName")
	if SKIP_CLASSES[cls] then
		return false
	end
	local pathL = string.lower(fullPathSafe(inst))
	if isNoisePath(pathL) then
		return false
	end
	if isRemoteKind(cls) or cls == "ModuleScript" or isValueKind(cls) or isRerollGuiPath(pathL) then
		return true
	end
	return targetWeight(inst) > 0
end

local function scoreInst(inst)
	if isOwnGui(inst) then
		return 0
	end
	local cls = propSafe(inst, "ClassName")
	if SKIP_CLASSES[cls] then
		return 0
	end
	local pathL = string.lower(fullPathSafe(inst))
	if isNoisePath(pathL) then
		return 0
	end
	local s = targetWeight(inst)
	if isRemoteKind(cls) then
		s += 8
	end
	if cls == "ModuleScript" then
		s += 4
	end
	if next(attrsSafe(inst)) ~= nil then
		s += 4
	end
	if isValueKind(cls) or isClass(inst, "ValueBase") then
		s += 3
	end
	local okTags, tags = pcall(function()
		return CollectionService:GetTags(inst)
	end)
	if okTags and #tags > 0 then
		s += 3
	end
	return s
end

local function buildInstInfo(inst)
	local info = {
		name = tostring(propSafe(inst, "Name") or "?"),
		className = tostring(propSafe(inst, "ClassName") or "?"),
		fullName = fullPathSafe(inst),
		parentPath = parentPathSafe(inst),
		debugId = debugIdSafe(inst),
		weight = targetWeight(inst),
		attrs = {},
		props = {},
		propKeys = {},
	}
	for k, v in pairs(attrsSafe(inst)) do
		info.attrs[tostring(k)] = fmtVal(v)
	end
	for propName in pairs(VALUE_PROPS) do
		local v = propSafe(inst, propName)
		if v ~= nil then
			info.props[propName] = fmtVal(v)
			info.propKeys[#info.propKeys + 1] = propName
		end
	end
	return info
end

local function formatInfoText(info)
	local lines = {
		"Name: " .. info.name,
		"Class: " .. info.className,
		"Path: " .. info.fullName,
		"Parent: " .. info.parentPath,
		"DebugId: " .. info.debugId,
		"Attributes (" .. keyCount(info.attrs) .. "):",
	}
	for k, v in pairsSorted(info.attrs) do
		lines[#lines + 1] = "  " .. k .. " = " .. v
	end
	lines[#lines + 1] = "Properties:"
	for k, v in pairsSorted(info.props) do
		lines[#lines + 1] = "  " .. k .. " = " .. v
	end
	return table.concat(lines, "\n")
end

local function setStatus(msg)
	if ui.statusLabel then
		pcall(function()
			ui.statusLabel.Text = tostring(msg)
		end)
	end
end

local function renderRightBox()
	if not ui.details then
		return
	end
	if rightViewMode == "Snapshot" then
		local txt = (snapshotText ~= "") and snapshotText or "No snapshot taken yet. Click Snapshot State to capture current target state."
		pcall(function()
			ui.details.Text = txt
		end)
		return
	end

	if rightViewMode == "Live" then
		local lines = {
			"=== LIVE NOW & CALLS (Mark #" .. tostring(markCounter) .. ") ===",
			"Hooked: " .. tostring(safeCallsHooked) .. " | Events: " .. tostring(#liveEvents) .. " | Paths: " .. tostring(#touchedOrder),
			"",
		}
		if #liveEvents == 0 then
			lines[#lines + 1] = "Waiting for stat reroll changes or endpoint events..."
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
			ui.details.Text = formatInfoText(ui.selected.info)
		end)
	else
		pcall(function()
			ui.details.Text = "Select an item, switch to Live Now, or take a Snapshot."
		end)
	end
end

local function pushRawLiveLine(rawLine, sourcePath)
	if destroyed or #liveEvents >= MAX_LIVE_EVENTS then
		return
	end
	local timing = formatTimingTag()
	local phase = classifyPhase(string.lower(tostring(rawLine)), string.lower(tostring(sourcePath or "")))
	local prefix = (markCounter > 0) and ("[M" .. tostring(markCounter) .. "] ") or ""
	local line = string.format("%s[%s] (%s) %s", prefix, phase, timing, tostring(rawLine))
	if liveEventSeen[line] then
		return
	end
	liveEventSeen[line] = true
	liveEvents[#liveEvents + 1] = line
	if sourcePath then
		recordTouchedPath(sourcePath, phase)
	end
	if rightViewMode == "Live" then
		renderRightBox()
	end
end

local function pushLiveEvent(inst, tagText)
	if isOwnGui(inst) then
		return
	end
	local cls = propSafe(inst, "ClassName")
	if SKIP_CLASSES[cls] then
		return
	end
	local pathStr = fullPathSafe(inst)
	if isLiveNoise(inst, string.lower(pathStr)) then
		return
	end
	local line = string.format(
		"%s [%s] -> %s (%s)",
		tostring(propSafe(inst, "Name") or "?"),
		tostring(cls or "?"),
		pathStr,
		tostring(tagText)
	)
	pushRawLiveLine(line, pathStr)
end

local function buildSnapshotDiff(currMap, prevMap)
	if type(prevMap) ~= "table" then
		return "First snapshot baseline (no prior snapshot to diff)."
	end
	local diffs = {}
	for key, newVal in pairsSorted(currMap) do
		local oldVal = prevMap[key]
		if oldVal == nil then
			if #diffs < 40 then
				diffs[#diffs + 1] = "[ADDED] " .. key .. " = " .. newVal
			end
		elseif oldVal ~= newVal then
			if #diffs < 40 then
				diffs[#diffs + 1] = "[CHANGED] " .. key .. ": " .. oldVal .. " -> " .. newVal
			end
		end
	end
	for key, oldVal in pairsSorted(prevMap) do
		if currMap[key] == nil and #diffs < 40 then
			diffs[#diffs + 1] = "[REMOVED] " .. key .. " (was " .. oldVal .. ")"
		end
	end
	if #diffs == 0 then
		return "No differences vs previous snapshot (identical state)."
	end
	return table.concat(diffs, "\n")
end

local function captureTargetSnapshot()
	local currMap = {}
	local rerollLines = {}
	local petLines = {}

	local lp = Players and Players.LocalPlayer
	if lp then
		local pg = safeCall(function()
			return lp:FindFirstChildOfClass("PlayerGui")
		end)
		if pg then
			for _, guiName in ipairs({ "StatReroll", "TraitReroll" }) do
				local guiRoot = pg:FindFirstChild(guiName)
				if guiRoot then
					local okD, desc = pcall(function()
						return guiRoot:GetDescendants()
					end)
					if okD and type(desc) == "table" then
						for _, inst in ipairs(desc) do
							if typeof(inst) == "Instance" and not isOwnGui(inst) then
								local pathStr = fullPathSafe(inst)
								local pathL = string.lower(pathStr)
								if isRelevantRerollSnapshotNode(inst, pathL) then
									local cls = tostring(propSafe(inst, "ClassName") or "?")
									local txt = isClass(inst, "TextLabel") and propSafe(inst, "Text") or nil
									local vis = propSafe(inst, "Visible")
									local attrs = attrsSafe(inst)
									local parts = {}
									if txt ~= nil and tostring(txt) ~= "" then
										parts[#parts + 1] = "Text=" .. fmtVal(txt)
										currMap[pathStr .. ".Text"] = fmtVal(txt)
									end
									if vis ~= nil then
										parts[#parts + 1] = "Visible=" .. tostring(vis)
										currMap[pathStr .. ".Visible"] = tostring(vis)
									end
									for k, v in pairsSorted(attrs) do
										local fv = fmtVal(v)
										parts[#parts + 1] = "attr:" .. tostring(k) .. "=" .. fv
										currMap[pathStr .. "@attr:" .. tostring(k)] = fv
									end
									if #parts > 0 and #rerollLines < 45 then
										rerollLines[#rerollLines + 1] = string.format(
											"• %s [%s] -> %s | %s",
											tostring(propSafe(inst, "Name") or "?"),
											cls,
											pathStr,
											table.concat(parts, ", ")
										)
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local hp = ReplicatedStorage and ReplicatedStorage:FindFirstChild("__HIDDEN_PETS")
	if hp then
		local okC, children = pcall(function()
			return hp:GetChildren()
		end)
		if okC and type(children) == "table" then
			for _, petModel in ipairs(children) do
				if typeof(petModel) == "Instance" and isClass(petModel, "Model") and isLocalPlayerOwnedPet(petModel) then
					local pPath = fullPathSafe(petModel)
					local attrs = attrsSafe(petModel)
					local unitId = attrs._unit_id and fmtVal(attrs._unit_id) or "?"
					local kv = {}
					for k, v in pairsSorted(attrs) do
						local fv = fmtVal(v)
						currMap[pPath .. "@attr:" .. tostring(k)] = fv
						if tostring(k) ~= "_unit_id" then
							kv[#kv + 1] = tostring(k) .. "=" .. fv
						end
					end
					if #petLines < 35 then
						petLines[#petLines + 1] = string.format(
							"• %s (%s) -> %s",
							tostring(propSafe(petModel, "Name") or "?"),
							unitId,
							pPath
						)
						if #kv > 0 then
							petLines[#petLines + 1] = "    " .. table.concat(kv, " | ")
						end
					end
				end
			end
		end
	end

	lastDiffSummary = buildSnapshotDiff(currMap, prevSnapshotMap)
	prevSnapshotMap = currMap

	local lines = {
		"=== STATE SNAPSHOT (Mark #" .. tostring(markCounter) .. ") ===",
		"--- DIFF VS PREVIOUS SNAPSHOT ---",
		lastDiffSummary,
		"",
		"--- REROLL UI (" .. tostring(#rerollLines) .. ") ---",
	}
	if #rerollLines == 0 then
		lines[#lines + 1] = "(No relevant StatReroll/TraitReroll elements)"
	else
		for _, l in ipairs(rerollLines) do
			lines[#lines + 1] = l
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "--- LOCAL HIDDEN PETS (" .. tostring(#petLines) .. ") ---"
	if #petLines == 0 then
		lines[#lines + 1] = "(None)"
	else
		for _, l in ipairs(petLines) do
			lines[#lines + 1] = l
		end
	end

	snapshotText = table.concat(lines, "\n")
	rightViewMode = "Snapshot"
	if ui.viewModeBtn then
		pcall(function()
			ui.viewModeBtn.Text = "View: Snapshot"
		end)
	end
	renderRightBox()
end

local function recordRemoteInventory(statusTag, cls, rPath)
	local key = tostring(statusTag) .. "|" .. tostring(cls) .. "|" .. tostring(rPath)
	if remoteInventorySeen[key] then
		return
	end
	remoteInventorySeen[key] = true
	remoteInventory[#remoteInventory + 1] = string.format("[%s | %s] %s", tostring(statusTag), tostring(cls), tostring(rPath))
end

local function hookSingleRemoteSafe(remote)
	if destroyed or typeof(remote) ~= "Instance" or isOwnGui(remote) then
		return
	end
	local cls = propSafe(remote, "ClassName")
	local rPath = fullPathSafe(remote)
	local isEndpoint = string.find(string.lower(rPath), "endpoints", 1, true) ~= nil

	if hookedRemotes[remote] then
		if isEndpoint then
			recordRemoteInventory("HOOKED", cls, rPath)
		end
		return
	end

	if cls == "RemoteFunction" then
		local okGet, origFn = pcall(function()
			return remote.InvokeServer
		end)
		local hooked = false
		if okGet and type(origFn) == "function" then
			local okSet = pcall(function()
				remote.InvokeServer = function(self, ...)
					if not destroyed then
						local args = { ... }
						local argParts = {}
						for i = 1, math.min(#args, 6) do
							argParts[#argParts + 1] = serializeArg(args[i], 0)
						end
						local msg = string.format("[FN] %s(%s)", rPath, table.concat(argParts, ", "))
						task.defer(function()
							pushRawLiveLine(msg, rPath)
						end)
					end
					return origFn(self, ...)
				end
			end)
			if okSet then
				hookedRemotes[remote] = { fnProp = "InvokeServer", orig = origFn }
				safeCallsHooked += 1
				hooked = true
			end
		end
		if isEndpoint then
			recordRemoteInventory(hooked and "HOOKED" or "UNHOOKED", cls, rPath)
		end
	elseif cls == "RemoteEvent" then
		local okGet, origFn = pcall(function()
			return remote.FireServer
		end)
		local hooked = false
		if okGet and type(origFn) == "function" then
			local okSet = pcall(function()
				remote.FireServer = function(self, ...)
					if not destroyed then
						local args = { ... }
						local argParts = {}
						for i = 1, math.min(#args, 6) do
							argParts[#argParts + 1] = serializeArg(args[i], 0)
						end
						local msg = string.format("[EV] %s(%s)", rPath, table.concat(argParts, ", "))
						task.defer(function()
							pushRawLiveLine(msg, rPath)
						end)
					end
					return origFn(self, ...)
				end
			end)
			if okSet then
				hookedRemotes[remote] = { fnProp = "FireServer", orig = origFn }
				safeCallsHooked += 1
				hooked = true
			end
		end
		if isEndpoint then
			recordRemoteInventory(hooked and "HOOKED" or "UNHOOKED", cls, rPath)
		end
	elseif isEndpoint then
		recordRemoteInventory("DETECTED", cls, rPath)
	end
end

local function unhookAllRemotesSafe()
	for remote, info in pairs(hookedRemotes) do
		if typeof(remote) == "Instance" and type(info) == "table" and info.fnProp and type(info.orig) == "function" then
			pcall(function()
				remote[info.fnProp] = info.orig
			end)
		end
	end
	hookedRemotes = {}
	remoteInventory = {}
	remoteInventorySeen = {}
	safeCallsHooked = 0
end

local function attachAllRemotesSafe()
	if not ReplicatedStorage then
		return
	end
	local okD, desc = pcall(function()
		return ReplicatedStorage:GetDescendants()
	end)
	if okD and type(desc) == "table" then
		for _, inst in ipairs(desc) do
			local cls = propSafe(inst, "ClassName")
			local pathL = string.lower(fullPathSafe(inst))
			if cls == "RemoteFunction" or cls == "RemoteEvent" or string.find(pathL, "endpoints", 1, true) then
				hookSingleRemoteSafe(inst)
			end
		end
	end
end

local function pushInspected(info)
	local key = tostring(info.fullName) .. "|" .. tostring(info.debugId)
	if inspectedSeen[key] then
		return
	end
	inspectedSeen[key] = true
	inspectedHistory[#inspectedHistory + 1] = info
end

local function itemMatchesView(info)
	if activeFilter == "Target" and info.weight <= 0 then
		return false
	elseif activeFilter == "Remotes" and not isRemoteKind(info.className) then
		return false
	elseif activeFilter == "Modules" and info.className ~= "ModuleScript" then
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

local function refreshRowStyle(entry)
	if not entry or not entry.row then
		return
	end
	local info = entry.info
	local sel = (ui.selected == entry)
	pcall(function()
		entry.row.BackgroundColor3 = sel and C.rowSelected or C.row
		entry.row.Text = string.format(
			"%s [%s]  %s  (%d attrs)",
			info.name, info.className, info.fullName, keyCount(info.attrs)
		)
	end)
end

local function applyViewFilter()
	local shown = 0
	for _, entry in ipairs(entryOrder) do
		local vis = itemMatchesView(entry.info)
		if entry.row then
			pcall(function()
				entry.row.Visible = vis
			end)
		end
		if vis then
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
	for name, btn in pairs(ui.chips or {}) do
		pcall(function()
			btn.BackgroundColor3 = (name == activeFilter) and C.chipActive or C.btn
		end)
	end
end

local function selectRowEntry(entry)
	if not entry or destroyed then
		return
	end
	local prev = ui.selected
	ui.selected = entry
	if prev and prev ~= entry then
		refreshRowStyle(prev)
	end
	refreshRowStyle(entry)
	pushInspected(entry.info)
	pushLiveEvent(entry.inst, "inspected")
	rightViewMode = "Details"
	if ui.viewModeBtn then
		pcall(function()
			ui.viewModeBtn.Text = "View: Details"
		end)
	end
	renderRightBox()
	applyViewFilter()
end

local function disposeEntry(entry)
	if not entry then
		return
	end
	if entry.row then
		pcall(function()
			entry.row:Destroy()
		end)
		entry.row = nil
	end
	for _, c in ipairs(entry.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	entry.conns = {}
end

local function makeRow(entry)
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
	row.Visible = itemMatchesView(entry.info)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = row

	row.Parent = ui.list
	entry.row = row
	refreshRowStyle(entry)

	entry.conns[#entry.conns + 1] = row.Activated:Connect(function()
		if not destroyed then
			selectRowEntry(entry)
		end
	end)
end

local function insertEntry(inst)
	if entries[inst] or destroyed or entryCount >= MAX_ENTRIES then
		return
	end
	if not pcall(function()
		return inst.Parent
	end) then
		return
	end

	local info = buildInstInfo(inst)
	if isNoisePath(string.lower(info.fullName)) then
		return
	end

	local entry = { inst = inst, info = info, row = nil, conns = {} }
	entries[inst] = entry
	entryOrder[#entryOrder + 1] = entry
	entryCount += 1

	local pathL = string.lower(info.fullName)
	local isTrackedState = isValueKind(info.className)
		or info.weight > 0
		or isRerollGuiPath(pathL)
		or string.find(pathL, "__hidden_pets", 1, true) ~= nil

	if isTrackedState then
		local okAttr, attrSig = pcall(function()
			return inst.AttributeChanged
		end)
		if okAttr and attrSig then
			entry.conns[#entry.conns + 1] = attrSig:Connect(function(attrName)
				if destroyed or entries[inst] ~= entry then
					return
				end
				local oldV = entry.info.attrs[tostring(attrName)] or "nil"
				local okV, v = pcall(function()
					return inst:GetAttribute(attrName)
				end)
				local newV = okV and fmtVal(v) or "?"
				entry.info.attrs[tostring(attrName)] = newV
				pushLiveEvent(inst, string.format("attr:%s (%s -> %s)", tostring(attrName), oldV, newV))
				refreshRowStyle(entry)
				if ui.selected == entry and rightViewMode == "Details" then
					renderRightBox()
				end
				applyViewFilter()
			end)
		end

		if isValueKind(info.className) and not isLiveNoise(inst, pathL) then
			local okSig, sig = pcall(function()
				return inst:GetPropertyChangedSignal("Value")
			end)
			if okSig and sig then
				entry.conns[#entry.conns + 1] = sig:Connect(function()
					if destroyed or entries[inst] ~= entry then
						return
					end
					local oldV = entry.info.props.Value or "nil"
					local newV = fmtVal(propSafe(inst, "Value"))
					entry.info.props.Value = newV
					pushLiveEvent(inst, string.format("Value (%s -> %s)", oldV, newV))
					if ui.selected == entry and rightViewMode == "Details" then
						renderRightBox()
					end
					applyViewFilter()
				end)
			end
		end

		if isActionableRerollControl(inst, pathL) then
			local okVis, visSig = pcall(function()
				return inst:GetPropertyChangedSignal("Visible")
			end)
			if okVis and visSig then
				entry.conns[#entry.conns + 1] = visSig:Connect(function()
					if destroyed or entries[inst] ~= entry then
						return
					end
					local oldVis = tostring(entry.info.props.Visible or "nil")
					local newVis = tostring(propSafe(inst, "Visible"))
					if oldVis ~= newVis then
						entry.info.props.Visible = newVis
						pushLiveEvent(inst, string.format("Visible (%s -> %s)", oldVis, newVis))
					end
				end)
			end
		end
	end

	makeRow(entry)
	applyViewFilter()
end

local function removeEntry(inst)
	local entry = entries[inst]
	if not entry then
		return
	end
	disposeEntry(entry)
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
		renderRightBox()
	end
	applyViewFilter()
end

local function clearListEntries()
	for inst, entry in pairs(entries) do
		disposeEntry(entry)
		entries[inst] = nil
	end
	entryOrder = {}
	entryCount = 0
	ui.selected = nil
	renderRightBox()
	applyViewFilter()
end

local function clearLogsData()
	inspectedHistory = {}
	inspectedSeen = {}
	liveEvents = {}
	liveEventSeen = {}
	touchedPaths = {}
	touchedOrder = {}
	snapshotText = ""
	prevSnapshotMap = nil
	lastDiffSummary = ""
	markCounter = 0
	markStartClock = os.clock()
	lastEventClock = nil
	renderRightBox()
	applyViewFilter()
end

local function collectTargetRoots()
	local roots = {}
	if ReplicatedStorage then
		local ep = ReplicatedStorage:FindFirstChild("endpoints")
		if ep then
			roots[#roots + 1] = ep
		end
		local hp = ReplicatedStorage:FindFirstChild("__HIDDEN_PETS")
		if hp then
			roots[#roots + 1] = hp
		end
		roots[#roots + 1] = ReplicatedStorage
	end
	local lp = Players and Players.LocalPlayer
	if lp then
		roots[#roots + 1] = lp
		local pg = safeCall(function()
			return lp:FindFirstChildOfClass("PlayerGui")
		end)
		if pg then
			roots[#roots + 1] = pg
		end
	end
	return roots
end

local function buildFullReport()
	local out = {
		"=== RUNTIME INSPECTOR ROLLBACK ARCHITECTURE REPORT ===",
		"Target Scope: Stat All Reroll / Remotes & Endpoints / State & Attributes / Rollback Flow",
		"Mark #" .. tostring(markCounter) .. " | HookedRemotes: " .. tostring(safeCallsHooked) .. " | Inspected: " .. tostring(#inspectedHistory) .. " | Live: " .. tostring(#liveEvents),
		"",
		"--- [0A] HOOKED REMOTES INVENTORY ---",
	}

	if #remoteInventory == 0 then
		out[#out + 1] = "(None)"
	else
		for i = 1, math.min(#remoteInventory, 120) do
			out[#out + 1] = "• " .. remoteInventory[i]
		end
	end

	out[#out + 1] = ""
	out[#out + 1] = "--- [0B] TOUCHED ENTITIES & PHASES ---"

	if #touchedOrder == 0 then
		out[#out + 1] = "(None)"
	else
		for i = 1, math.min(#touchedOrder, 40) do
			local p = touchedOrder[i]
			local meta = touchedPaths[p]
			out[#out + 1] = string.format("• [%s] (x%d) %s", meta.lastPhase, meta.count, p)
		end
	end

	out[#out + 1] = ""
	out[#out + 1] = "--- [1] LIVE NOW & CALLS ---"

	if #liveEvents == 0 then
		out[#out + 1] = "(None)"
	else
		for _, line in ipairs(liveEvents) do
			out[#out + 1] = line
		end
	end

	out[#out + 1] = ""
	out[#out + 1] = "--- [2] SNAPSHOT ---"
	out[#out + 1] = (snapshotText ~= "") and snapshotText or "(No snapshot captured)"

	out[#out + 1] = ""
	out[#out + 1] = "--- [3] USER INSPECTED ---"
	if #inspectedHistory == 0 then
		out[#out + 1] = "(None)"
	else
		for i, info in ipairs(inspectedHistory) do
			out[#out + 1] = "[" .. i .. "] " .. formatInfoText(info)
			out[#out + 1] = "----------------------------------------"
		end
	end

	out[#out + 1] = ""
	out[#out + 1] = "--- [4] SYSTEM CANDIDATES ---"

	local roots = collectTargetRoots()
	local found = {}
	local seen = {}
	for _, root in ipairs(roots) do
		local okD, desc = pcall(function()
			return root:GetDescendants()
		end)
		if okD and type(desc) == "table" then
			for _, inst in ipairs(desc) do
				if typeof(inst) == "Instance" and isTargetCandidate(inst) then
					local info = buildInstInfo(inst)
					if not seen[info.fullName] then
						seen[info.fullName] = true
						found[#found + 1] = info
					end
				end
			end
		end
	end

	table.sort(found, function(a, b)
		if a.weight ~= b.weight then
			return a.weight > b.weight
		end
		return tostring(a.fullName) < tostring(b.fullName)
	end)

	local limit = math.min(#found, MAX_TARGET_HITS)
	for i = 1, limit do
		local info = found[i]
		out[#out + 1] = string.format("• [w=%d] %s [%s] -> %s", info.weight, info.name, info.className, info.fullName)
		for k, v in pairsSorted(info.attrs) do
			out[#out + 1] = "    attr " .. k .. " = " .. v
		end
		if info.props.Value ~= nil then
			out[#out + 1] = "    Value = " .. tostring(info.props.Value)
		end
		if info.props.Visible ~= nil then
			out[#out + 1] = "    Visible = " .. tostring(info.props.Visible)
		end
	end

	out[#out + 1] = ""
	out[#out + 1] = "Matched: " .. tostring(limit) .. " / " .. tostring(#found)
	return table.concat(out, "\n"), limit
end

local function runScan(targetedOnly)
	scanToken += 1
	local token = scanToken
	clearListEntries()

	local list = {}
	if targetedOnly then
		local seen = {}
		for _, root in ipairs(collectTargetRoots()) do
			local okD, desc = pcall(function()
				return root:GetDescendants()
			end)
			if okD and type(desc) == "table" then
				for _, inst in ipairs(desc) do
					if typeof(inst) == "Instance" and not seen[inst] then
						seen[inst] = true
						list[#list + 1] = inst
					end
				end
			end
		end
	else
		local okList, gameDesc = pcall(function()
			return game:GetDescendants()
		end)
		if okList and type(gameDesc) == "table" then
			list = gameDesc
		end
	end

	if #list == 0 then
		setStatus("Scan failed or empty")
		return
	end

	local idx = 1
	setStatus((targetedOnly and "Targeted scan " or "Scanning ") .. "0/" .. #list)

	task.defer(function()
		while not destroyed and token == scanToken and idx <= #list and entryCount < MAX_ENTRIES do
			local step = 0
			while idx <= #list and step < SCAN_BATCH and entryCount < MAX_ENTRIES do
				local inst = list[idx]
				idx += 1
				step += 1
				if typeof(inst) == "Instance" and scoreInst(inst) >= MIN_SCORE then
					insertEntry(inst)
				end
			end
			setStatus(string.format("Scanning %d/%d - %d shown", idx - 1, #list, entryCount))
			task.wait()
		end
		if not destroyed and token == scanToken then
			setStatus(string.format("Done - %d shown | Remotes:%d", entryCount, safeCallsHooked))
		end
	end)
end

local function setGuiVisible(vis)
	if not ui.main then
		return
	end
	local ok = pcall(function()
		ui.main.Visible = vis
	end)
	if ok then
		ui.visible = vis
		if ui.toggleBtn then
			pcall(function()
				ui.toggleBtn.Text = vis and "Hide" or "Show"
			end)
		end
	end
end

local function cleanupInspector()
	if destroyed then
		return
	end
	destroyed = true
	scanToken += 1
	unhookAllRemotesSafe()

	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	connections = {}

	for inst, entry in pairs(entries) do
		disposeEntry(entry)
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

local function buildInspectorUI()
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

	local tCorner = Instance.new("UICorner")
	tCorner.CornerRadius = UDim.new(0, 5)
	tCorner.Parent = ui.toggleBtn

	ui.main = Instance.new("Frame")
	ui.main.Name = "Main"
	ui.main.Size = UDim2.new(0, W, 0, H)
	ui.main.Position = UDim2.new(0, 20, 0, 20)
	ui.main.BackgroundColor3 = C.bg
	ui.main.BorderSizePixel = 0
	ui.main.Parent = ui.screenGui

	local mCorner = Instance.new("UICorner")
	mCorner.CornerRadius = UDim.new(0, 8)
	mCorner.Parent = ui.main

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

	local sPad = Instance.new("UIPadding")
	sPad.PaddingLeft = UDim.new(0, 8)
	sPad.PaddingRight = UDim.new(0, 8)
	sPad.Parent = ui.searchBox

	local sCorner = Instance.new("UICorner")
	sCorner.CornerRadius = UDim.new(0, 5)
	sCorner.Parent = ui.searchBox

	ui.chips = {}
	local chipDefs = {
		{ name = "All", x = 322, w = 34 },
		{ name = "Target", x = 359, w = 46 },
		{ name = "Remotes", x = 408, w = 54 },
		{ name = "Modules", x = 465, w = 55 },
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

		local cCorner = Instance.new("UICorner")
		cCorner.CornerRadius = UDim.new(0, 5)
		cCorner.Parent = chip

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

	local lCorner = Instance.new("UICorner")
	lCorner.CornerRadius = UDim.new(0, 6)
	lCorner.Parent = ui.list

	local lLayout = Instance.new("UIListLayout")
	lLayout.Padding = UDim.new(0, 4)
	lLayout.SortOrder = Enum.SortOrder.LayoutOrder
	lLayout.Parent = ui.list

	ui.details = Instance.new("TextBox")
	ui.details.Size = UDim2.new(0, DET_W, 0, CONTENT_H - 84)
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
	ui.details.Text = "Select an item, switch to Live Now, or take a Snapshot."
	ui.details.Parent = ui.main

	local dPad = Instance.new("UIPadding")
	dPad.PaddingLeft = UDim.new(0, 8)
	dPad.PaddingTop = UDim.new(0, 8)
	dPad.Parent = ui.details

	local dCorner = Instance.new("UICorner")
	dCorner.CornerRadius = UDim.new(0, 6)
	dCorner.Parent = ui.details

	ui.snapBtn = Instance.new("TextButton")
	ui.snapBtn.Name = "Snapshot"
	ui.snapBtn.Size = UDim2.new(0, DET_W, 0, 24)
	ui.snapBtn.Position = UDim2.new(0, DET_X, 0, TOP + CONTENT_H - 78)
	ui.snapBtn.BackgroundColor3 = C.btn
	ui.snapBtn.BorderSizePixel = 0
	ui.snapBtn.TextColor3 = C.text
	ui.snapBtn.Font = Enum.Font.SourceSansSemibold
	ui.snapBtn.TextSize = 12
	ui.snapBtn.Text = "Snapshot State"
	ui.snapBtn.Parent = ui.main

	local snCorner = Instance.new("UICorner")
	snCorner.CornerRadius = UDim.new(0, 5)
	snCorner.Parent = ui.snapBtn

	ui.viewModeBtn = Instance.new("TextButton")
	ui.viewModeBtn.Name = "ViewMode"
	ui.viewModeBtn.Size = UDim2.new(0, DET_W, 0, 24)
	ui.viewModeBtn.Position = UDim2.new(0, DET_X, 0, TOP + CONTENT_H - 51)
	ui.viewModeBtn.BackgroundColor3 = C.btn
	ui.viewModeBtn.BorderSizePixel = 0
	ui.viewModeBtn.TextColor3 = C.text
	ui.viewModeBtn.Font = Enum.Font.SourceSansSemibold
	ui.viewModeBtn.TextSize = 12
	ui.viewModeBtn.Text = "View: Details"
	ui.viewModeBtn.Parent = ui.main

	local vmCorner = Instance.new("UICorner")
	vmCorner.CornerRadius = UDim.new(0, 5)
	vmCorner.Parent = ui.viewModeBtn

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

	local cpCorner = Instance.new("UICorner")
	cpCorner.CornerRadius = UDim.new(0, 5)
	cpCorner.Parent = ui.copyPathBtn

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

	local btnDefs = {
		{ key = "scanBtn", label = "Scan", x = 10, y = H - 78, w = 118, bg = C.btn },
		{ key = "clearBtn", label = "Clear", x = 138, y = H - 78, w = 118, bg = C.btn },
		{ key = "clearLogBtn", label = "Clear Log", x = 266, y = H - 78, w = 118, bg = C.btn },
		{ key = "closeBtn", label = "Close", x = 394, y = H - 78, w = 126, bg = C.btn },
		{ key = "copyBtn", label = "Copy Full Report", x = 10, y = H - 40, w = 246, bg = C.copyBtn },
		{ key = "markBtn", label = "Mark Now", x = 266, y = H - 40, w = 254, bg = C.markBtn },
	}
	for _, def in ipairs(btnDefs) do
		local b = Instance.new("TextButton")
		b.Name = def.key
		b.Size = UDim2.new(0, def.w, 0, 32)
		b.Position = UDim2.new(0, def.x, 0, def.y)
		b.BackgroundColor3 = def.bg
		b.BorderSizePixel = 0
		b.TextColor3 = C.text
		b.Font = Enum.Font.SourceSansSemibold
		b.TextSize = 13
		b.Text = def.label
		b.Parent = ui.main

		local bCorner = Instance.new("UICorner")
		bCorner.CornerRadius = UDim.new(0, 5)
		bCorner.Parent = b

		ui[def.key] = b
	end

	ui.visible = true
	ui.selected = nil
end

local function bindDragBar()
	if not ui.dragBar or not ui.main or not UserInputService then
		return
	end
	local dragging = false
	local dragStart = nil
	local startPos = nil

	trackConn(ui.dragBar.InputBegan:Connect(function(input)
		if destroyed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = ui.main.Position
		end
	end))

	trackConn(UserInputService.InputChanged:Connect(function(input)
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

	trackConn(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			dragStart = nil
			startPos = nil
		end
	end))
end

local function bindInspectorEvents()
	trackConn(ui.searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if not destroyed then
			searchQuery = tostring(ui.searchBox.Text or "")
			applyViewFilter()
		end
	end))

	for chipName, chipBtn in pairs(ui.chips or {}) do
		trackConn(chipBtn.Activated:Connect(function()
			if not destroyed then
				activeFilter = chipName
				applyViewFilter()
				setStatus("Filter: " .. chipName)
			end
		end))
	end

	trackConn(ui.snapBtn.Activated:Connect(function()
		if not destroyed then
			captureTargetSnapshot()
			setStatus("Snapshot captured at Mark #" .. tostring(markCounter))
		end
	end))

	trackConn(ui.viewModeBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		if rightViewMode == "Details" then
			rightViewMode = "Live"
			ui.viewModeBtn.Text = "View: Live Now"
		elseif rightViewMode == "Live" then
			rightViewMode = "Snapshot"
			ui.viewModeBtn.Text = "View: Snapshot"
		else
			rightViewMode = "Details"
			ui.viewModeBtn.Text = "View: Details"
		end
		renderRightBox()
	end))

	trackConn(ui.copyPathBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		if ui.selected and ui.selected.info and ui.selected.info.fullName then
			local p = ui.selected.info.fullName
			local ok = setClipboardSafe(p)
			setStatus(ok and ("Path copied: " .. p) or ("Path: " .. p))
		else
			setStatus("No item selected")
		end
	end))

	trackConn(ui.markBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		markCounter += 1
		markStartClock = os.clock()
		lastEventClock = markStartClock
		liveEvents = {}
		liveEventSeen = {}
		touchedPaths = {}
		touchedOrder = {}
		rightViewMode = "Live"
		if ui.viewModeBtn then
			pcall(function()
				ui.viewModeBtn.Text = "View: Live Now"
			end)
		end
		renderRightBox()
		applyViewFilter()
		setStatus("Marked Now #" .. tostring(markCounter) .. " (t=0.00s)")
	end))

	trackConn(ui.scanBtn.Activated:Connect(function()
		if not destroyed then
			runScan(false)
		end
	end))

	trackConn(ui.clearBtn.Activated:Connect(function()
		if not destroyed then
			clearListEntries()
			setStatus("Cleared list")
		end
	end))

	trackConn(ui.clearLogBtn.Activated:Connect(function()
		if not destroyed then
			clearLogsData()
			setStatus("Cleared Log, Live & Snapshot")
		end
	end))

	trackConn(ui.copyBtn.Activated:Connect(function()
		if destroyed then
			return
		end
		local reportText, matched = buildFullReport()
		local copied = setClipboardSafe(reportText)
		printChunksSafe(reportText)
		if copied then
			setStatus("Report copied (" .. tostring(matched) .. " items)")
		else
			pcall(function()
				ui.details.Text = reportText
			end)
			setStatus("Printed to Output + shown in Details box")
		end
	end))

	trackConn(ui.closeBtn.Activated:Connect(function()
		cleanupInspector()
	end))

	trackConn(ui.toggleBtn.Activated:Connect(function()
		if not destroyed then
			setGuiVisible(not ui.visible)
		end
	end))

	trackConn(ui.screenGui.AncestryChanged:Connect(function(_, parent)
		if parent == nil and not destroyed then
			cleanupInspector()
		end
	end))

	if TeleportService then
		trackConn(TeleportService.TeleportInitFailed:Connect(function(player, teleportResult, message)
			if not destroyed then
				pushRawLiveLine(
					string.format("TeleportInitFailed (%s: %s)", tostring(teleportResult), tostring(message)),
					"TeleportService"
				)
			end
		end))
	end

	trackConn(game.DescendantAdded:Connect(function(inst)
		if destroyed or entryCount >= MAX_ENTRIES then
			return
		end
		task.defer(function()
			if destroyed or isOwnGui(inst) or entryCount >= MAX_ENTRIES then
				return
			end
			if not pcall(function()
				return inst.Parent
			end) then
				return
			end
			local cls = propSafe(inst, "ClassName")
			if SKIP_CLASSES[cls] then
				return
			end
			local pathStr = fullPathSafe(inst)
			local pathL = string.lower(pathStr)
			if isNoisePath(pathL) then
				return
			end
			if cls == "RemoteFunction" or cls == "RemoteEvent" or string.find(pathL, "endpoints", 1, true) then
				hookSingleRemoteSafe(inst)
			end
			if not isLiveNoise(inst, pathL) and (isRemoteKind(cls) or isValueKind(cls) or isActionableRerollControl(inst, pathL)) then
				pushLiveEvent(inst, "added")
				applyViewFilter()
			end
			if scoreInst(inst) >= MIN_SCORE then
				insertEntry(inst)
			end
		end)
	end))

	trackConn(game.DescendantRemoving:Connect(function(inst)
		if destroyed then
			return
		end
		local pathL = string.lower(fullPathSafe(inst))
		if not isLiveNoise(inst, pathL) and isActionableRerollControl(inst, pathL) then
			pushLiveEvent(inst, "removed")
		end
		removeEntry(inst)
	end))

	bindDragBar()
end

local previousGuard = safeCall(function()
	return _G[GUARD_KEY]
end)
if type(previousGuard) == "table" and type(previousGuard.destroy) == "function" then
	pcall(previousGuard.destroy)
end

pcall(function()
	if type(_G) == "table" then
		_G[GUARD_KEY] = { destroy = cleanupInspector }
	end
end)

task.defer(function()
	local parent, mountSrc = safeCall(function()
		if typeof(gethui) == "function" then
			local okH, h = pcall(gethui)
			if okH and typeof(h) == "Instance" then
				return h, "gethui"
			end
		end
		return nil, nil
	end)

	if not parent and CoreGui then
		parent, mountSrc = CoreGui, "CoreGui"
	end

	if not parent and Players then
		local lp = Players.LocalPlayer
		if lp then
			local pg = safeCall(function()
				return lp:WaitForChild("PlayerGui", 5)
			end)
			if typeof(pg) == "Instance" then
				parent, mountSrc = pg, "PlayerGui"
			end
		end
	end

	if not parent then
		return
	end

	pcall(function()
		for _, ch in ipairs(parent:GetChildren()) do
			if ch:IsA("ScreenGui") and ch.Name == GUI_TAG then
				ch:Destroy()
			end
		end
	end)

	buildInspectorUI()
	bindInspectorEvents()
	attachAllRemotesSafe()

	local okParent = pcall(function()
		ui.screenGui.Parent = parent
	end)
	if not okParent then
		cleanupInspector()
		return
	end

	setStatus("Ready (" .. tostring(mountSrc) .. ") | Remotes:" .. tostring(safeCallsHooked))
	runScan(true)
end)
