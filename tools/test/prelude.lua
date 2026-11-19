local log = {}
local function print(...)
  local t = {}
  for i = 1, select('#', ...) do t[#t + 1] = tostring((select(i, ...))) end
  log[#log + 1] = table.concat(t, " ")
end
local function wipe(t) for k in pairs(t) do t[k] = nil end return t end
local issecretvalue = nil
local STANDARD_TEXT_FONT = "font"
local RAID_CLASS_COLORS = { WARRIOR = {r=.78,g=.61,b=.43}, MAGE = {r=.25,g=.78,b=.92}, HUNTER = {r=.67,g=.83,b=.45}, PRIEST = {r=1,g=1,b=1} }
local CLASS_ICON_TCOORDS = { WARRIOR = {0,.25,0,.25}, MAGE = {.25,.5,0,.25}, HUNTER = {0,.25,.25,.5}, PRIEST = {.5,.75,.25,.5} }
local function NewFrame(name)
  local f = { name = name, shown = true, scripts = {} }
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  function f:SetPoint(...) self.point = { ... } end
  function f:ClearAllPoints() self.point = nil end
  function f:SetParent(p) self.parent = p end
  function f:SetScript(n, fn) self.scripts[n] = fn end
  function f:CreateTexture() return NewFrame("tex") end
  function f:CreateFontString() return NewFrame("fs") end
  function f:SetFormattedText(fmt, ...) self.textValue = string.format(fmt, ...) end
  function f:SetRotation(r) self.rotation = r end
  function f:SetSize(w, h) self.w = w end
  function f:SetValue(v) self.value = v; if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end end
  function f:SetChecked(v) self.checked = v end
  function f:GetChecked() return self.checked end
  function f:SetText(v) self.textValue = v end
  function f:GetWidth() return 1366 end
  function f:GetHeight() return 768 end
  function f:GetEffectiveScale() return 0.9 end
  return setmetatable(f, { __index = function() return function() end end })
end
local UIParent = NewFrame("UIParent")
local frames = {}
local function CreateFrame() local f = NewFrame("frame" .. (#frames + 1)); frames[#frames + 1] = f; return f end
local C_CVar = { GetCVar = function() return "90" end }
local world, classes, plates, dead = { player = { n = 0, w = 0, inst = 1 } }, { player = "PRIEST" }, {}, {}
local facingValue, partyCount, target = 0, 0, false
local function UnitPosition(u) local p = world[u]; if not p then return nil end return p.n, p.w, 0, p.inst end
local function GetPlayerFacing() return facingValue end
local sameAs, seeded = {}, {}
local C_NamePlate = {
  GetNamePlateForUnit = function(u)
    -- Mirrors the live client (1.60.1.70938), which rejects party and raid tokens.
    if u:match("^party") or u:match("^raid") then error("Raid<n>/Party<n> unit tokens are not allowed for this call.") end
    return plates[u]
  end,
  GetNamePlates = function() return seeded end,
}
local function UnitIsUnit(a, b) return a == b or sameAs[a] == b end
local function UnitGUID(u) return sameAs[u] or u end
local function UnitClass(u) return classes[u], classes[u] end
local function UnitExists(u) if u == "target" then return target end return world[u] ~= nil end
local function UnitIsConnected(u) return true end
local function UnitIsDeadOrGhost(u) return dead[u] or false end
local function UnitName(u) return u end
local function GetNumSubgroupMembers() return partyCount end
local instanceType = "none"
local function IsInInstance() return instanceType ~= "none", instanceType end
local SlashCmdList = {}
local openedCategory
local Settings = {
  RegisterCanvasLayoutCategory = function(panel, name) return { ID = 7, name = name } end,
  RegisterAddOnCategory = function() end,
  OpenToCategory = function(id) openedCategory = id end,
}
local InterfaceOptions_AddCategory = nil
local BackdropTemplateMixin, ChatFontNormal, CLOSE = {}, {}, "Close"
local function GetBuildInfo() return "1.60.1", "70338", "Nov 1 2026", 16001 end
local SLASH_PARTYBEACONS1, SLASH_PARTYBEACONS2, PartyBeaconsDB, PartyBeaconsCharDB
