
local function fire(event, arg) driver.scripts.OnEvent(driver, event, arg) end
local function tick() local fn = driver.scripts.OnUpdate; if fn then fn(driver, 0.016) end end
local function show(label)
  for i = 1, #members do
    local mem = members[i]; local m = mem.marker; local pt = m.point
    local where = "no point"
    if type(pt) == "table" then
      if type(pt[4]) == "number" and pt[1] == "CENTER" then where = string.format("CENTER x=%.1f y=%.1f", pt[4], pt[5])
      else where = string.format("%s -> %s.%s off=%s", pt[1], tostring(pt[2].name), pt[3], tostring(pt[5])) end
    end
    print(string.format("%s | %s class=%s shown=%s mode=%s parent=%s %s text=%s arrowRot=%s", label, tostring(mem.unit or "fake"), tostring(mem.class), tostring(m.shown), tostring(m.mode), tostring(m.parent and m.parent.name), where, tostring(m.text.shown and m.text.textValue), m.arrow.rotation and string.format("%.0fdeg", math.deg(m.arrow.rotation)) or "-"))
  end
end
fire("ADDON_LOADED", "SomethingElse")
fire("GROUP_ROSTER_UPDATE")
fire("ADDON_LOADED", "PartyBeacons")
print("defaults", PartyBeaconsDB.size, PartyBeaconsDB.offset, PartyBeaconsDB.style, tostring(PartyBeaconsDB.edge), "enabled", tostring(PartyBeaconsCharDB.enabled))
fire("PLAYER_ENTERING_WORLD")
print("solo: members", #members, "onupdate", tostring(driver.scripts.OnUpdate ~= nil))

partyCount = 2
world.party1 = { n = 100, w = 0, inst = 1 }; classes.party1 = "WARRIOR"
world.party2 = { n = 0, w = -50, inst = 1 }; classes.party2 = "MAGE"
fire("GROUP_ROSTER_UPDATE"); tick(); show("A facing north; p1 100 north, p2 50 east")
-- L: max distance hides far edge indicators
SlashCmdList["PARTYBEACONS"]("maxdist 60"); tick(); show("L maxdist 60: p1 (100 yd) hidden, p2 (50 yd) shown")
SlashCmdList["PARTYBEACONS"]("maxdist 0"); tick(); show("L maxdist 0: both shown")
SlashCmdList["PARTYBEACONS"]("maxdist 500"); tick()
facingValue = math.pi / 2; tick(); show("B facing west")
facingValue = 0
world.party1 = { n = -60, w = 1, inst = 1 }; world.party2 = { n = -60, w = -1, inst = 1 }
tick(); show("C both 60 behind")
plates.nameplate1 = NewFrame("plateA"); sameAs.nameplate1 = "party1"
fire("NAME_PLATE_UNIT_ADDED", "nameplate1"); tick(); show("D p1 has nameplate")
fire("NAME_PLATE_UNIT_REMOVED", "nameplate1"); plates.nameplate1 = nil; sameAs.nameplate1 = nil
-- The game only knows the plate as "nameplate3"; asking for party1 directly finds nothing.
plates.nameplate3 = NewFrame("plateB"); sameAs.nameplate3 = "party1"
fire("NAME_PLATE_UNIT_ADDED", "nameplate3"); tick(); show("D2 p1 plate known only by its own token")
tick(); show("D3 next frame, remembered")
SlashCmdList["PARTYBEACONS"]("debug")
fire("NAME_PLATE_UNIT_REMOVED", "nameplate3"); plates.nameplate3 = nil; sameAs.nameplate3 = nil; tick(); show("D4 plate gone")
-- Token reused for someone else in the same frame must not keep party1's marker.
plates.nameplate3 = NewFrame("plateC"); sameAs.nameplate3 = "party2"; fire("NAME_PLATE_UNIT_ADDED", "nameplate3"); tick(); show("D5 token reused by p2")
fire("NAME_PLATE_UNIT_REMOVED", "nameplate3"); plates.nameplate3 = nil; sameAs.nameplate3 = nil
dead.party2 = true; world.party1 = { n = 30, w = 30, inst = 2 }
tick(); show("E p1 other instance, p2 dead")
world.party1 = { n = 2, w = 0, inst = 1 }; tick(); show("F p1 2yd away no plate")
world.player = nil; tick(); show("G in a dungeon (no player position)")
world.player = { n = 0, w = 0, inst = 1 }
SlashCmdList["PARTYBEACONS"]("off"); print("off: members", #members, "onupdate", tostring(driver.scripts.OnUpdate ~= nil), "enabled", tostring(PartyBeaconsCharDB.enabled))
SlashCmdList["PARTYBEACONS"]("on")
partyCount = 0; world.party1 = nil; world.party2 = nil; fire("GROUP_ROSTER_UPDATE")
SlashCmdList["PARTYBEACONS"]("test"); target = true; plates.target = NewFrame("plateT"); tick(); show("H test mode")
SlashCmdList["PARTYBEACONS"]("margin 40"); tick(); show("H2 margin 40")
SlashCmdList["PARTYBEACONS"]("size 40"); SlashCmdList["PARTYBEACONS"]("offset 10"); SlashCmdList["PARTYBEACONS"]("style color"); tick(); show("I restyled")
SlashCmdList["PARTYBEACONS"]("  SIZE   999 "); SlashCmdList["PARTYBEACONS"]("edge off"); tick(); show("J edge off")
SlashCmdList["PARTYBEACONS"]("debug"); SlashCmdList["PARTYBEACONS"](""); SlashCmdList["PARTYBEACONS"]("bogus")
print("debug window shown:", tostring(debugWindow and debugWindow.shown), "lines:")
print(debugWindow.box.original)
-- Typing into the box must restore the text.
debugWindow.box.scripts.OnTextChanged(debugWindow.box, true)
print("after typing, text restored:", tostring(debugWindow.box.original ~= nil))
debugWindow.box.scripts.OnEscapePressed(debugWindow.box); print("after escape shown:", tostring(debugWindow.shown))
-- Options panel
print("options panel built:", tostring(optionsPanel ~= nil), "error:", tostring(optionsError), "category", tostring(optionsPanel and optionsPanel.categoryID))
SlashCmdList["PARTYBEACONS"](""); print("opened category:", tostring(openedCategory))
optionsPanel.shown = true; optionsPanel.scripts.OnShow(optionsPanel)
local sliders = {}
for i = 1, #frames do if type(rawget(frames[i], "slider")) == "table" then sliders[#sliders + 1] = frames[i] end end
print("sliders:", #sliders, "values:", sliders[1].slider.value, sliders[2].slider.value, sliders[3].slider.value, "labels:", sliders[1].value.textValue, sliders[2].value.textValue, sliders[3].value.textValue)
sliders[1].slider:SetValue(47.6); print("after dragging size to 47.6: db.size", PartyBeaconsDB.size, "label", sliders[1].value.textValue)
tick(); show("K size from slider")
sliders[3].slider:SetValue(120); print("margin", PartyBeaconsDB.margin)
SlashCmdList["PARTYBEACONS"]("size 30"); print("slash size 30 -> slider shows", sliders[1].slider.value, sliders[1].value.textValue)
print("lastError", tostring(lastError))
return table.concat(log, "\n")
