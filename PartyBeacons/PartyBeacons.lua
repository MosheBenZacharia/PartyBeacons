-- Party Beacons (WoW Forever)
-- Copyright (c) 2026 Ooga Vibers. Licensed under GPLv3 (see LICENSE).
-- The world-position and secret-value helpers are adapted from PartyArrow,
-- Copyright (c) 2026 TC Conway (GPLv3), itself based on PlayerArrow by Jayama.
--
-- A class marker above each party member's nameplate. When a member has no nameplate
-- on screen, the marker moves to the edge of the screen and points toward them.
--
-- Enabled per character (PartyBeaconsCharDB); look and feel is account-wide
-- (PartyBeaconsDB).

local MEDIA = "Interface\\AddOns\\PartyBeacons\\media\\"
local CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local TITLE = "|cff4fc3f7Party Beacons|r"

local DEFAULTS = {
    size = 36,       -- marker diameter in UI pixels
    offset = 4,      -- gap between the top of the nameplate and the marker
    style = "icon",  -- "icon": class icon in a class-colored ring; "color": plain class-colored disc
    edge = true,     -- show screen-edge indicators for members without a nameplate
    margin = 80,     -- how far edge indicators sit from every screen edge, in UI pixels
}

-- Members closer than this without a nameplate get no edge indicator (the bearing is
-- too jumpy to be useful when someone is standing on top of you).
local MIN_EDGE_DISTANCE = 5

local pi = math.pi
local abs, sqrt, tan, atan, atan2, floor = math.abs, math.sqrt, math.tan, math.atan, math.atan2, math.floor

local db, charDB
local driver = CreateFrame("Frame")
local members = {}   -- everyone currently tracked: { unit, real, class, marker, bearing, dist, p }
local edgeList = {}  -- members that need an edge indicator this frame
local pool = {}      -- spare marker frames
local testMode = false
local halfFov = math.rad(41)
local lastError, lastAttachError, optionsError
local optionsPanel
local CreateOptionsPanel  -- defined with the options panel, further down
local plateTokens = {}  -- nameplate unit tokens on screen -> serial number of that appearance
local plateSerial = 0
local scanNow = true    -- look for party members among the nameplates on this frame


-- Secret values -------------------------------------------------------------------
-- Forever inherits Midnight's "secret" values: some API results cannot be compared or
-- branched on by addons. Anything that might be one is checked before it is used.

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

local function Flag(value, fallback)
    if IsSecret(value) then return fallback end
    return value and true or false
end


-- World state ---------------------------------------------------------------------

-- Returns north, west, instanceID in yards, or nil where the game does not share
-- positions (dungeons and raids). The first value grows northward, the second westward.
local function GetWorldPosition(unit)
    local north, west, _, instanceID = UnitPosition(unit)
    if not north or not west or IsSecret(north) or IsSecret(west) or IsSecret(instanceID) then
        return nil
    end
    return north, west, instanceID
end

-- The character's facing: 0 is north, growing counter-clockwise. Nil in instances.
local function GetFacing()
    local facing = GetPlayerFacing()
    if not facing or IsSecret(facing) then return nil end
    return facing
end

-- Returns the nameplate frame for a unit token, or nil plus the reason there is none.
local function GetPlate(unit, includeForbidden)
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil, "no nameplate API" end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit, includeForbidden or false)
    if not ok then return nil, tostring(plate) end
    if IsSecret(plate) then return nil, "secret" end
    if not plate then return nil, "none" end
    return plate
end

local function SameUnit(a, b)
    local ok, same = pcall(UnitIsUnit, a, b)
    if ok and same ~= nil and not IsSecret(same) then return same end
    local okA, guidA = pcall(UnitGUID, a)
    local okB, guidB = pcall(UnitGUID, b)
    if okA and okB and guidA and guidB and not IsSecret(guidA) and not IsSecret(guidB) then
        return guidA == guidB
    end
    return false
end

local function TrackPlate(token)
    if type(token) ~= "string" or IsSecret(token) then return end
    plateSerial = plateSerial + 1
    plateTokens[token] = plateSerial
    scanNow = true
end

-- Picks up nameplates that were already on screen before the addon started listening.
local function SeedPlates()
    wipe(plateTokens)
    if not C_NamePlate or not C_NamePlate.GetNamePlates then return end
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if not ok or type(plates) ~= "table" then return end
    for _, plate in pairs(plates) do
        local token = plate.unitToken or plate.namePlateUnitToken
        if not token and plate.GetUnit then
            local okUnit, unit = pcall(plate.GetUnit, plate)
            token = okUnit and unit or nil
        end
        TrackPlate(token)
    end
end

-- The game hands out nameplates under their own tokens ("nameplate7") and refuses to
-- look one up by a party or raid token, so a member's plate is found by checking which
-- on-screen nameplate belongs to them. The match is remembered until that plate goes.
local function FindPlate(mem)
    local unit = mem.unit
    local plate
    if not mem.real then
        -- The test preview's "target" token can be looked up directly.
        plate = GetPlate(unit)
        if plate then return plate end
    end

    local token = mem.plateToken
    if token and plateTokens[token] == mem.plateSerial then
        plate = GetPlate(token)
        if plate then return plate end
    end
    mem.plateToken, mem.plateSerial = nil, nil

    if scanNow then
        for candidate, serial in pairs(plateTokens) do
            if SameUnit(candidate, unit) then
                plate = GetPlate(candidate)
                if plate then
                    mem.plateToken, mem.plateSerial = candidate, serial
                    return plate
                end
            end
        end
    end
    return nil
end

local function GetUnitClassFile(unit)
    local _, classFile = UnitClass(unit)
    if classFile and not IsSecret(classFile) then return classFile end
    return nil
end

-- Half of the horizontal field of view. The cameraFov setting is treated as a diagonal
-- angle, which is close enough for placing an indicator along the top of the screen.
local function RefreshFov()
    local value = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("cameraFov")
    local fov = tonumber(value) or 90
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    local aspect = (height and height > 0) and (width / height) or (16 / 9)
    local half = atan(tan(math.rad(fov) / 2) * aspect / sqrt(1 + aspect * aspect))
    halfFov = math.max(0.3, math.min(1.2, half))
end


-- Edge path -----------------------------------------------------------------------
-- An indicator's place on the screen edge is a distance along a rectangle, measured
-- from the top center: positive to the right, negative to the left. Straight ahead is
-- the top center, directly behind is the bottom center.

-- theta: bearing relative to the character, radians, positive to the right, in (-pi, pi].
local function BearingToPerimeter(theta, half, hx, side)
    local a = abs(theta)
    local back = pi - half
    local p
    if a <= half then
        p = hx * tan(a) / tan(half)
    elseif a <= back then
        p = hx + side * (a - half) / (back - half)
    else
        p = hx + side + hx * (a - back) / half
    end
    return theta < 0 and -p or p
end

local function PerimeterToPoint(p, hx, top, bottom)
    local side = top + bottom
    local total = 4 * hx + 2 * side
    p = p % total
    if p > total / 2 then p = p - total end
    local sign = p < 0 and -1 or 1
    local a = abs(p)
    if a <= hx then
        return sign * a, top
    elseif a <= hx + side then
        return sign * hx, top - (a - hx)
    end
    return sign * (hx - (a - hx - side)), -bottom
end

local function ByPerimeter(a, b)
    return a.p < b.p
end

-- Pushes overlapping indicators apart along the path (which wraps around).
local function Spread(list, total, minGap)
    local n = #list
    if n < 2 then return end
    for i = 1, n do
        list[i].p = list[i].p % total
    end
    table.sort(list, ByPerimeter)
    for _ = 1, 4 do
        for i = 1, n do
            local a, b = list[i], list[i % n + 1]
            local gap = b.p - a.p
            if i == n then gap = gap + total end
            if gap < minGap then
                local push = (minGap - gap) / 2
                a.p = a.p - push
                b.p = b.p + push
            end
        end
    end
end


-- Markers -------------------------------------------------------------------------

local function CreateMarker()
    local m = CreateFrame("Frame", nil, UIParent)
    m:SetFrameStrata("LOW")
    m:Hide()
    -- White disc with a baked black outline; tinted with the class color.
    m.disc = m:CreateTexture(nil, "BACKGROUND")
    m.disc:SetAllPoints()
    m.disc:SetTexture(MEDIA .. "disc.tga")
    m.icon = m:CreateTexture(nil, "ARTWORK")
    m.icon:SetPoint("CENTER")
    m.icon:SetTexture(CLASS_CIRCLES)
    m.arrow = m:CreateTexture(nil, "ARTWORK")
    m.arrow:SetTexture(MEDIA .. "arrow.tga")
    m.arrow:Hide()
    m.text = m:CreateFontString(nil, "OVERLAY")
    m.text:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    m.text:Hide()
    return m
end

local function AcquireMarker()
    local m = table.remove(pool) or CreateMarker()
    m.mode, m.plate, m.styleKey = nil, nil, nil
    return m
end

local function ReleaseMarker(m)
    m:Hide()
    m:ClearAllPoints()
    m:SetParent(UIParent)
    m:SetIgnoreParentAlpha(false)
    m:SetIgnoreParentScale(false)
    m:SetScale(1)
    m.mode, m.plate, m.styleKey = nil, nil, nil
    pool[#pool + 1] = m
end

local function StyleMarker(m, class, dead)
    local key = (class or "?") .. db.style .. db.size .. (dead and "d" or "a")
    if m.styleKey == key then return end
    m.styleKey = key

    local size = db.size
    m:SetSize(size, size)
    m.icon:SetSize(size * 0.72, size * 0.72)
    m.arrow:SetSize(size * 0.6, size * 0.6)
    m.fontSize = math.max(11, floor(size * 0.38))
    m.text:SetFont(STANDARD_TEXT_FONT, m.fontSize, "OUTLINE")

    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local r, g, b = 0.9, 0.9, 0.9
    if color then r, g, b = color.r, color.g, color.b end
    m.disc:SetVertexColor(r, g, b)
    m.arrow:SetVertexColor(r, g, b)

    local coords = db.style == "icon" and class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        m.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        m.icon:SetDesaturated(dead)
        m.icon:Show()
    else
        m.icon:Hide()
    end
    m:SetAlpha(dead and 0.6 or 1)
end

-- Sits the marker just above the nameplate. It ignores the plate's alpha and scale so
-- it keeps full contrast and a constant size while the plate fades or shrinks.
local function AttachToPlate(m, plate)
    if m.mode ~= "plate" or m.plate ~= plate then
        m:SetParent(plate)
        m:SetFrameStrata("LOW")
        m:SetIgnoreParentAlpha(true)
        m:SetIgnoreParentScale(true)
        m:SetScale(UIParent:GetEffectiveScale())
        m:ClearAllPoints()
        m:SetPoint("BOTTOM", plate, "TOP", 0, db.offset)
        m.arrow:Hide()
        m.text:Hide()
        m.mode, m.plate = "plate", plate
    end
    m:Show()
end

local function PlaceOnEdge(m, x, y, dist)
    if m.mode ~= "edge" then
        m:SetParent(UIParent)
        m:SetFrameStrata("LOW")
        m:SetIgnoreParentAlpha(false)
        m:SetIgnoreParentScale(false)
        m:SetScale(1)
        m.arrow:Show()
        m.text:Show()
        m.mode, m.plate = "edge", nil
    end
    m:ClearAllPoints()
    m:SetPoint("CENTER", UIParent, "CENTER", x, y)

    -- The arrow sits on the outward side of the disc, the distance on the inward side.
    local length = sqrt(x * x + y * y)
    local ux, uy = 0, 1
    if length > 0 then ux, uy = x / length, y / length end
    local radius = db.size / 2
    m.arrow:ClearAllPoints()
    m.arrow:SetPoint("CENTER", m, "CENTER", ux * (radius + db.size * 0.2), uy * (radius + db.size * 0.2))
    m.arrow:SetRotation(atan2(uy, ux) - pi / 2)
    m.text:ClearAllPoints()
    local fontSize = m.fontSize or 11
    m.text:SetPoint("CENTER", m, "CENTER", -ux * (radius + fontSize * 1.5), -uy * (radius + fontSize * 0.8))
    m.text:SetFormattedText("%d yd", floor(dist + 0.5))
    m:Show()
end


-- Per-frame update ----------------------------------------------------------------

local function Update()
    local playerNorth, playerWest, playerInstance = GetWorldPosition("player")
    local facing = GetFacing()
    wipe(edgeList)

    for i = 1, #members do
        local mem = members[i]
        local unit = mem.unit
        local m = mem.marker
        local visible, dead = true, false

        if unit then
            if not Flag(UnitExists(unit), true) then
                visible = false
            elseif mem.real then
                visible = Flag(UnitIsConnected(unit), true)
                dead = Flag(UnitIsDeadOrGhost(unit), false)
            end
            if visible and (not mem.class or not mem.real) then
                mem.class = GetUnitClassFile(mem.real and unit or "player") or mem.class
            end
        end

        local placed = false
        if visible then
            StyleMarker(m, mem.class, dead)
            local plate = unit and FindPlate(mem)
            if plate then
                local ok, err = pcall(AttachToPlate, m, plate)
                placed = ok
                if not ok then
                    lastAttachError = err
                    m.mode, m.plate = nil, nil
                end
            end
            if not placed and db.edge and playerNorth and facing then
                local theta, dist
                if mem.bearing then
                    theta, dist = facing - mem.bearing, mem.dist
                elseif unit then
                    local north, west, instance = GetWorldPosition(unit)
                    if north and instance == playerInstance then
                        local dNorth, dWest = north - playerNorth, west - playerWest
                        dist = sqrt(dNorth * dNorth + dWest * dWest)
                        if dist >= MIN_EDGE_DISTANCE then
                            theta = facing - atan2(dWest, dNorth)
                        end
                    end
                end
                if theta then
                    mem.theta = (theta + pi) % (2 * pi) - pi
                    mem.edgeDist = dist
                    edgeList[#edgeList + 1] = mem
                    placed = true
                end
            end
        end
        if not placed then m:Hide() end
    end

    if #edgeList > 0 then
        local width, height = UIParent:GetWidth(), UIParent:GetHeight()
        local hx = math.max(50, width / 2 - db.margin)
        local top = math.max(50, height / 2 - db.margin)
        local bottom = top
        local side = top + bottom
        for i = 1, #edgeList do
            local mem = edgeList[i]
            mem.p = BearingToPerimeter(mem.theta, halfFov, hx, side)
        end
        Spread(edgeList, 4 * hx + 2 * side, db.size + 6)
        for i = 1, #edgeList do
            local mem = edgeList[i]
            local x, y = PerimeterToPoint(mem.p, hx, top, bottom)
            PlaceOnEdge(mem.marker, x, y, mem.edgeDist)
        end
    end
end

local sinceFov, sinceScan = 0, 0
local function OnUpdate(_, elapsed)
    sinceFov = sinceFov + elapsed
    if sinceFov > 2 then
        sinceFov = 0
        RefreshFov()
    end
    sinceScan = sinceScan + elapsed
    if sinceScan > 0.25 then
        sinceScan = 0
        scanNow = true
    end
    -- An unexpected API restriction should not spam an error every frame.
    local ok, err = pcall(Update)
    scanNow = false
    if not ok and lastError ~= err then
        lastError = err
        print(TITLE, "hit an error (shown once):", tostring(err))
    end
end


-- Roster --------------------------------------------------------------------------

local function AddMember(entry)
    entry.marker = AcquireMarker()
    members[#members + 1] = entry
end

local function Rebuild()
    for i = 1, #members do
        ReleaseMarker(members[i].marker)
    end
    wipe(members)
    wipe(edgeList)
    if not db or not charDB then return end

    if charDB.enabled then
        for i = 1, GetNumSubgroupMembers() do
            AddMember({ unit = "party" .. i, real = true })
        end
        if testMode then
            -- Your target stands in for a party member's nameplate; three fixed compass
            -- bearings (north, south-west, south-east) stand in for distant members.
            AddMember({ unit = "target", real = false })
            AddMember({ class = "WARRIOR", bearing = 0, dist = 40 })
            AddMember({ class = "MAGE", bearing = 2 * pi / 3, dist = 120 })
            AddMember({ class = "HUNTER", bearing = 4 * pi / 3, dist = 300 })
        end
    end

    RefreshFov()
    scanNow = true
    driver:SetScript("OnUpdate", #members > 0 and OnUpdate or nil)
end

-- Forces every marker to re-apply its look and its nameplate anchor.
local function Restyle()
    for i = 1, #members do
        local m = members[i].marker
        m.styleKey, m.mode, m.plate = nil, nil, nil
    end
end


-- Events --------------------------------------------------------------------------

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("GROUP_ROSTER_UPDATE")
driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "PartyBeacons" then return end
        PartyBeaconsDB = PartyBeaconsDB or {}
        PartyBeaconsCharDB = PartyBeaconsCharDB or {}
        db, charDB = PartyBeaconsDB, PartyBeaconsCharDB
        for key, value in pairs(DEFAULTS) do
            if db[key] == nil then db[key] = value end
        end
        if charDB.enabled == nil then charDB.enabled = true end
        -- A problem building the options panel must not take the markers down with it.
        local ok, err = pcall(CreateOptionsPanel)
        if not ok then optionsError = err end
        return
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        TrackPlate(arg1)
        return
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if type(arg1) == "string" and not IsSecret(arg1) then plateTokens[arg1] = nil end
        return
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Only the test preview follows the target; its remembered plate is now stale.
        for i = 1, #members do
            if not members[i].real then
                members[i].plateToken, members[i].plateSerial = nil, nil
            end
        end
        scanNow = true
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        SeedPlates()
    end
    Rebuild()
end)


-- Options panel -------------------------------------------------------------------
-- Lives under the game's Options > AddOns. Built from plain widgets so it does not
-- depend on slider templates that differ between clients.

local function MakeHeader(panel, text, anchor, gap)
    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap or -20)
    header:SetText(text)
    return header
end

local function MakeCheck(panel, text, anchor, onClick)
    local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    check.label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    check.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.label:SetText(text)
    check:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return check
end

-- A labelled slider: "Label  value" above a track. get/set read and write the setting.
local function MakeSlider(panel, text, anchor, minValue, maxValue, get, set)
    local holder = CreateFrame("Frame", nil, panel)
    holder:SetSize(260, 44)
    holder:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
    holder.label = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    holder.label:SetPoint("TOPLEFT", 4, 0)
    holder.label:SetText(text)
    holder.value = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    holder.value:SetPoint("LEFT", holder.label, "RIGHT", 8, 0)

    local slider = CreateFrame("Slider", nil, holder)
    slider:SetOrientation("HORIZONTAL")
    slider:EnableMouse(true)
    slider:SetSize(240, 18)
    slider:SetPoint("TOPLEFT", holder.label, "BOTTOMLEFT", 0, -6)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    track:SetColorTexture(1, 1, 1, 0.25)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = slider:GetThumbTexture()
    if thumb then thumb:SetSize(28, 28) end
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetScript("OnValueChanged", function(_, value)
        value = floor(value + 0.5)
        holder.value:SetText(value)
        if not holder.refreshing and value ~= get() then set(value) end
    end)
    holder.slider = slider

    function holder.Refresh()
        holder.refreshing = true
        slider:SetValue(get())
        holder.value:SetText(get())
        holder.refreshing = false
    end
    return holder
end

CreateOptionsPanel = function()
    if optionsPanel then return optionsPanel end
    local panel = CreateFrame("Frame", nil, UIParent)
    panel.name = "Party Beacons"
    panel:Hide()

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Party Beacons")
    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText("Class markers above party members' nameplates, and at the screen edge when they are out of view.")

    local name = UnitName("player")
    local who = (name and not IsSecret(name)) and name or "this character"
    local enabled = MakeCheck(panel, "Enabled for " .. who .. " (each character has its own setting)", subtitle, function(on)
        charDB.enabled = on
        Rebuild()
    end)
    enabled:ClearAllPoints()
    enabled:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -2, -14)

    -- A sample marker beside the size slider, drawn at the real size.
    local previewDisc = panel:CreateTexture(nil, "ARTWORK")
    previewDisc:SetTexture(MEDIA .. "disc.tga")
    local previewIcon = panel:CreateTexture(nil, "OVERLAY")
    previewIcon:SetTexture(CLASS_CIRCLES)
    previewIcon:SetPoint("CENTER", previewDisc, "CENTER")
    local function RefreshPreview()
        local class = GetUnitClassFile("player")
        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        local r, g, b = 0.9, 0.9, 0.9
        if color then r, g, b = color.r, color.g, color.b end
        previewDisc:SetSize(db.size, db.size)
        previewDisc:SetVertexColor(r, g, b)
        local coords = db.style == "icon" and class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
        if coords then
            previewIcon:SetSize(db.size * 0.72, db.size * 0.72)
            previewIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
            previewIcon:Show()
        else
            previewIcon:Hide()
        end
    end

    local markerHeader = MakeHeader(panel, "Marker", enabled)
    local size = MakeSlider(panel, "Size", markerHeader, 16, 96,
        function() return db.size end,
        function(value) db.size = value; Restyle(); RefreshPreview() end)
    previewDisc:SetPoint("CENTER", size, "RIGHT", 90, -4)
    local offset = MakeSlider(panel, "Height above the nameplate", size, -20, 80,
        function() return db.offset end,
        function(value) db.offset = value; Restyle() end)
    local icon = MakeCheck(panel, "Show the class icon (off: a plain class-colored disc)", offset, function(on)
        db.style = on and "icon" or "color"
        Restyle()
        RefreshPreview()
    end)

    local edgeHeader = MakeHeader(panel, "Screen edge", icon)
    local edge = MakeCheck(panel, "Show an indicator at the screen edge for members with no nameplate in view", edgeHeader, function(on)
        db.edge = on
    end)
    local margin = MakeSlider(panel, "Distance from the screen edge", edge, 20, 400,
        function() return db.margin end,
        function(value) db.margin = value end)

    local test = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    test:SetSize(150, 24)
    test:SetPoint("TOPLEFT", margin, "BOTTOMLEFT", 0, -18)
    test:SetScript("OnClick", function() SlashCmdList["PARTYBEACONS"]("test") end)
    local debug = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    debug:SetSize(110, 24)
    debug:SetPoint("LEFT", test, "RIGHT", 8, 0)
    debug:SetText("Debug info")
    debug:SetScript("OnClick", function() SlashCmdList["PARTYBEACONS"]("debug") end)

    function panel.Refresh()
        enabled:SetChecked(charDB.enabled and true or false)
        icon:SetChecked(db.style == "icon")
        edge:SetChecked(db.edge and true or false)
        size.Refresh()
        offset.Refresh()
        margin.Refresh()
        test:SetText(testMode and "Stop test preview" or "Start test preview")
        RefreshPreview()
    end
    panel:SetScript("OnShow", panel.Refresh)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Party Beacons")
        Settings.RegisterAddOnCategory(category)
        panel.categoryID = category.ID or (category.GetID and category:GetID())
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
    optionsPanel = panel
    return panel
end

-- Opens the panel; returns false when this client gives no way to do that.
local function OpenOptionsPanel()
    if not optionsPanel or not optionsPanel.categoryID then return false end
    if not Settings or not Settings.OpenToCategory then return false end
    return (pcall(Settings.OpenToCategory, optionsPanel.categoryID))
end


-- Slash commands ------------------------------------------------------------------

local function OnOff(value)
    return value and "|cff40ff40on|r" or "|cffff4040off|r"
end

local function PrintStatus()
    local name = UnitName("player")
    print(TITLE, "is", OnOff(charDB.enabled), "for", (name and not IsSecret(name)) and name or "this character")
    print(TITLE, string.format("size %d, offset %d, style %s, edge indicators %s, margin %d",
        db.size, db.offset, db.style, db.edge and "on" or "off", db.margin))
end

local function PrintHelp()
    print(TITLE, "commands:")
    print("  /pb - open the options panel")
    print("  /pb status - print the current settings")
    print("  /pb on | off - turn the markers on or off for this character")
    print("  /pb size <16-96> - marker size")
    print("  /pb offset <number> - gap above the nameplate")
    print("  /pb style icon | color - class icon in a ring, or a plain class-colored disc")
    print("  /pb edge on | off - screen-edge indicators for members out of view")
    print("  /pb margin <20-400> - how far edge indicators sit from the screen edge")
    print("  /pb test - preview: marks your target and adds three sample edge indicators")
    print("  /pb debug - print what the game is reporting")
end

local function Describe(value)
    if IsSecret(value) then return "<secret>" end
    if type(value) == "number" then
        return string.format(value == floor(value) and "%d" or "%.1f", value)
    end
    return tostring(value)
end

-- Everything worth knowing when something misbehaves, as plain lines of text.
-- Player names are left out on purpose; the unit tokens are enough.
local function BuildDebugLines()
    local lines = {}
    local function add(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, " ")
    end

    local version, build, _, interface = GetBuildInfo()
    add("Party Beacons debug | client", version, build, "interface", interface)
    add("enabled", tostring(charDB.enabled), "| test preview", tostring(testMode),
        string.format("| size %d offset %d style %s edge %s margin %d",
            db.size, db.offset, db.style, db.edge and "on" or "off", db.margin))
    local cvars = {}
    for _, name in ipairs({ "nameplateShowFriends", "nameplateShowFriendlyPlayers", "nameplateShowAll", "cameraFov" }) do
        local value = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(name)
        cvars[#cvars + 1] = name .. "=" .. tostring(value)
    end
    add("settings:", table.concat(cvars, " "))

    local north, west, height, instance = UnitPosition("player")
    add("you: pos", Describe(north), Describe(west), Describe(height), "instance", Describe(instance),
        "facing", Describe(GetPlayerFacing()))
    add(string.format("half field of view %.1f deg, screen %dx%d",
        math.deg(halfFov), floor(UIParent:GetWidth()), floor(UIParent:GetHeight())))

    local tokens = {}
    for token in pairs(plateTokens) do tokens[#tokens + 1] = token end
    table.sort(tokens)
    add(#tokens, "nameplates on screen:", table.concat(tokens, " "))

    local units = {}
    for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    if testMode then units[#units + 1] = "target" end
    if #units == 0 then add("no party members (and no test preview)") end
    for _, unit in ipairs(units) do
        local n, w, h, inst = UnitPosition(unit)
        add(unit, "class", Describe(GetUnitClassFile(unit)),
            "pos", Describe(n), Describe(w), Describe(h), "instance", Describe(inst))
        -- How each way of finding this unit's nameplate fares.
        local direct, directWhy = GetPlate(unit)
        local forbidden, forbiddenWhy = GetPlate(unit, true)
        local matched, compare = "none", "n/a"
        for _, token in ipairs(tokens) do
            local ok, same = pcall(UnitIsUnit, token, unit)
            compare = (not ok and "error: " .. tostring(same)) or (IsSecret(same) and "secret") or "ok"
            if SameUnit(token, unit) then
                local plate, why = GetPlate(token)
                matched = token .. (plate and " (plate found)" or (" (no plate: " .. tostring(why) .. ")"))
                break
            end
        end
        add("   nameplate: direct", direct and "yes" or directWhy,
            "| incl. protected", forbidden and "yes" or forbiddenWhy,
            "| matched", matched, "| UnitIsUnit", compare)
    end
    for i = 1, #members do
        local mem = members[i]
        add("   marker", i, tostring(mem.unit or "sample"), "mode", tostring(mem.marker.mode),
            "shown", tostring(mem.marker:IsShown()))
    end
    add("last error:", tostring(lastError))
    add("last nameplate attach error:", tostring(lastAttachError))
    add("options panel error:", tostring(optionsError))
    return lines
end

-- A small window holding the debug text, selected and ready to copy.
local debugWindow
local function ShowDebugWindow(lines)
    local width = 640
    local w = debugWindow
    if not w then
        w = CreateFrame("Frame", "PartyBeaconsDebugWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        w:SetFrameStrata("DIALOG")
        w:SetPoint("CENTER")
        w:SetWidth(width)
        w:SetClampedToScreen(true)
        w:SetMovable(true)
        w:EnableMouse(true)
        w:RegisterForDrag("LeftButton")
        w:SetScript("OnDragStart", w.StartMoving)
        w:SetScript("OnDragStop", w.StopMovingOrSizing)
        if w.SetBackdrop then
            w:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 8, right = 8, top = 8, bottom = 8 },
            })
        end

        w.title = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        w.title:SetPoint("TOP", 0, -18)
        w.title:SetText("Party Beacons debug info")
        w.hint = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        w.hint:SetPoint("TOP", w.title, "BOTTOM", 0, -6)
        w.hint:SetText("The text is selected. Press Cmd+C (Ctrl+C on Windows) to copy it.")

        local box = CreateFrame("EditBox", nil, w)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetMaxLetters(0)
        box:SetFontObject(ChatFontNormal)
        box:SetPoint("TOP", w.hint, "BOTTOM", 0, -12)
        box:SetWidth(width - 44)
        -- Read-only: undo anything typed, and keep the whole text selected.
        box:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(self.original or "")
                self:HighlightText()
            end
        end)
        box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
        box:SetScript("OnEscapePressed", function() w:Hide() end)
        w.box = box

        w.close = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
        w.close:SetSize(90, 22)
        w.close:SetPoint("BOTTOM", 0, 16)
        w.close:SetText(CLOSE or "Close")
        w.close:SetScript("OnClick", function() w:Hide() end)
        debugWindow = w
    end

    -- Tall enough for every line, counting long lines that will wrap.
    local rows = 0
    for i = 1, #lines do
        rows = rows + math.max(1, math.ceil(#lines[i] / 84))
    end
    w:SetHeight(math.min(700, rows * 15 + 120))

    local text = table.concat(lines, "\n")
    w.box.original = text
    w.box:SetText(text)
    w:Show()
    w.box:SetFocus()
    w.box:HighlightText()
end

local function PrintDebug()
    local lines = BuildDebugLines()
    local ok = pcall(ShowDebugWindow, lines)
    if ok then
        print(TITLE, "debug info is in the window: press Cmd+C to copy it.")
    else
        -- The window could not be built on this client; fall back to chat.
        for i = 1, #lines do print(lines[i]) end
    end
end

SLASH_PARTYBEACONS1 = "/pb"
SLASH_PARTYBEACONS2 = "/partybeacons"
SlashCmdList["PARTYBEACONS"] = function(msg)
    if not db or not charDB then return end
    local command, argument = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")

    if command == "" or command == "options" or command == "config" then
        if not OpenOptionsPanel() then
            PrintStatus()
            print(TITLE, "type /pb help for commands")
        end
    elseif command == "status" then
        PrintStatus()
    elseif command == "help" then
        PrintHelp()
    elseif command == "on" or command == "off" or command == "toggle" then
        if command == "toggle" then
            charDB.enabled = not charDB.enabled
        else
            charDB.enabled = command == "on"
        end
        Rebuild()
        PrintStatus()
    elseif command == "size" then
        local size = tonumber(argument)
        if size and size >= 16 and size <= 96 then
            db.size = floor(size)
            Restyle()
            print(TITLE, "size", db.size)
        else
            print(TITLE, "size must be a number from 16 to 96")
        end
    elseif command == "offset" then
        local offset = tonumber(argument)
        if offset and offset >= -100 and offset <= 200 then
            db.offset = floor(offset)
            Restyle()
            print(TITLE, "offset", db.offset)
        else
            print(TITLE, "offset must be a number from -100 to 200")
        end
    elseif command == "style" then
        if argument == "icon" or argument == "color" then
            db.style = argument
            Restyle()
            print(TITLE, "style", db.style)
        else
            print(TITLE, "style must be icon or color")
        end
    elseif command == "edge" then
        if argument == "on" or argument == "off" then
            db.edge = argument == "on"
            print(TITLE, "edge indicators", OnOff(db.edge))
        else
            print(TITLE, "use /pb edge on or /pb edge off")
        end
    elseif command == "margin" then
        local margin = tonumber(argument)
        if margin and margin >= 20 and margin <= 400 then
            db.margin = floor(margin)
            print(TITLE, "margin", db.margin)
        else
            print(TITLE, "margin must be a number from 20 to 400")
        end
    elseif command == "test" then
        testMode = not testMode
        Rebuild()
        if testMode and not charDB.enabled then
            print(TITLE, "test preview needs the addon on for this character: /pb on")
        elseif testMode then
            print(TITLE, "test preview on. Target anything with a nameplate to see the marker above it;")
            print("  the three edge indicators sit north, south-west and south-east of you, so they")
            print("  should slide around the screen edge as you turn. /pb test again to stop.")
        else
            print(TITLE, "test preview off")
        end
    elseif command == "debug" then
        PrintDebug()
    else
        PrintHelp()
    end
    if optionsPanel and optionsPanel:IsShown() and optionsPanel.Refresh then
        optionsPanel.Refresh()
    end
end
