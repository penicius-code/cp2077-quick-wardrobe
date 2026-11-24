-- Cyberslop CET Style 1.0.0 (2026-11-22): this mod's windows use the gold palette (cyberslop_palette.lua, colours only).
do
  local ok, palette = pcall(require, "cyberslop_palette")
  if ok and type(palette) == "table" and type(registerForEvent) == "function" then
    local reg = registerForEvent
    registerForEvent = function(ev, fn)
      if ev == "onDraw" and type(fn) == "function" then fn = palette.wrap("gold", fn) end
      return reg(ev, fn)
    end
  end
end
-- Cyberslop Quick Wardrobe 1.2.2 (2026-11-23; 1.2.0 2026-11-22)
-- 1.2.2: a Build() of -1 (Equipment-EX not ready) counts as not built, so the list is fetched again by itself.
-- A CET window with every Equipment-EX wardrobe item: click a row to put it on or take it off,
-- no wardrobe menu needed. The Pin toggle keeps the window on screen after the CET overlay
-- closes; while pinned, hotkeys (unbound by default) move a cursor through the list and put
-- the item under it on or off. Data and actions go through the redscript bridge
-- r6\scripts\CyberslopQuickWardrobe (Equipment-EX's public API only, no hooks anywhere).
-- 1.1.0: tick boxes mark looks, "Move N marked to stash" sends their inventory copies to the
-- stash (near a stash or in V's own car). 1.2.0: mouse mode, the pinned window keeps the mouse after
-- the overlay closes (own cursor, camera and weapons held, keyboard free).
--
-- Lightweight rules: no Observe/Override. onDraw draws nothing unless the overlay is open or
-- the window is pinned. Rows are clipped (only visible rows are drawn) and all labels are built
-- when the list is built, so a pinned frame allocates no Lua garbage. The bridge is polled
-- twice a second only while the window is visible.

local VERSION = "1.2.0"
local SYS = "CyberslopQuickWardrobe"
local TITLE = "Quick Wardrobe##CyberslopQuickWardrobe"
local SOURCE_NAMES = { "Wardrobe store", "Inventory + stash", "Inventory only" } -- index = source + 1

-- persistent settings (config.json) and favourites (favorites.json, keyed by look)
local cfg = { pinned = false, area = "All", wornOnly = false, favOnly = false, markOnly = false, hudAlpha = 0.6,
  takeMouse = true, mouseSpeed = 1.0 }
local favs = {}
-- marked looks (key -> true), this game session only: a mark left from an old session must
-- never send clothes to the stash later
local marks = {}

-- runtime state, grouped to stay far below LuaJIT's local / upvalue limits
local S = {
  clock = 0, overlay = false, overlayAt = -10, lastAction = -10,
  playerOK = false, hudAllowed = false, nextPresence = 0, nextMenuCheck = 0, hudChildFlags = nil,
  nextPoll = 0, pollSoon = {}, nextSourceCheck = 0,
  token = nil, built = false, rawCount = -1, newItems = false,
  outfitActive = false, blocked = false,
  status = "", statusAt = -10, statusDur = 3,
  stripArmedAt = -10, source = 0, hudFlags = nil,
  outfits = {}, outfitLabels = {}, currentOutfit = "", nextOutfitRefresh = 0,
  saveName = "",
  holdDir = 0, holdT = 0, holdStep = 0,
  logLines = 0,
  markCount = 0, moveLabel = "", stashOK = true, nextStashCheck = 0,
}

local items = {}      -- sorted list entries: { idx, name, lname, key, slot, area, fav, marked, label, markId }
local byIdx = {}      -- bridge index -> entry
local slotNames = {}  -- 1-based slot -> localized slot name
local areas = { "All" }
local view = {}       -- filtered entries
local V = { dirty = true, cursor = 1, cursorMoved = false, search = "", query = "", header = "" }
local worn, wornNext = {}, {} -- bridge index -> true

------------------------------------------------------------------------ helpers

local function log(msg)
  if S.logLines > 40 then return end
  S.logLines = S.logLines + 1
  local f = io.open("CyberslopQuickWardrobe.log", "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S "), tostring(msg), "\n")
    f:close()
  end
end

local function getSys() return Game.GetScriptableSystemsContainer():Get(SYS) end

local function bridge()
  local ok, s = pcall(getSys)
  if ok and s then return s end
  return nil
end

local function call(fn, ...)
  local s = bridge()
  if not s then return nil end
  local ok, r = pcall(s[fn], s, ...)
  if not ok then
    log("bridge " .. fn .. " failed: " .. tostring(r))
    return nil
  end
  return r
end

local function saveJson(path, t)
  local ok, text = pcall(json.encode, t)
  if not ok then return end
  local f = io.open(path, "w")
  if f then f:write(text) f:close() end
end

local function loadJson(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, t = pcall(json.decode, text)
  if ok and type(t) == "table" then return t end
  return nil
end

local function saveCfg() saveJson("config.json", cfg) end
local function saveFavs() saveJson("favorites.json", favs) end

local function setStatus(text, dur)
  S.status = text
  S.statusAt = S.clock
  S.statusDur = dur or 3
end

local function makeLabel(e)
  e.label = (e.fav and "* " or "") .. e.name .. "##cqw" .. e.idx
end

local function setMarkCount(n)
  S.markCount = n
  S.moveLabel = "Move " .. n .. " marked to stash##cqwmove"
end

------------------------------------------------------------------------ list

local function updateHeader()
  local h = cfg.area .. " | " .. #view .. (#view == 1 and " item" or " items")
  if S.markCount > 0 then h = h .. " | " .. S.markCount .. " marked" end
  if S.blocked then
    h = h .. " | locked (quest outfit)"
  elseif not S.outfitActive then
    h = h .. " | outfit OFF"
  end
  if S.newItems then h = h .. " | new items: open the overlay" end
  V.header = h
end

local function applyFilter()
  local keepIdx = view[V.cursor] and view[V.cursor].idx or nil
  local nv = {}
  local q = V.query
  for i = 1, #items do
    local e = items[i]
    if (cfg.area == "All" or e.area == cfg.area)
      and (not cfg.wornOnly or worn[e.idx])
      and (not cfg.favOnly or e.fav)
      and (not cfg.markOnly or e.marked)
      and (q == "" or e.lname:find(q, 1, true)) then
      nv[#nv + 1] = e
    end
  end
  view = nv
  local c = 1
  if keepIdx then
    for i = 1, #view do
      if view[i].idx == keepIdx then c = i break end
    end
  end
  V.cursor = math.min(c, math.max(1, #view))
  V.cursorMoved = true
  V.dirty = false
  updateHeader()
end

local function rebuild()
  local n = call("Build")
  if not n or n < 0 then   -- 1.2.2: -1 = Equipment-EX not ready yet
    S.built = false
    return
  end
  local names = call("GetNames") or {}
  local keys = call("GetKeys") or {}
  local slots = call("GetItemSlots") or {}
  local sNames = call("GetSlotNames") or {}
  local sAreas = call("GetSlotAreas") or {}
  S.token = call("GetToken")
  S.rawCount = call("GetRawCount") or -1
  S.source = call("GetSource") or 0

  slotNames = sNames
  local newItems, newByIdx, newMarks, markCount = {}, {}, {}, 0
  for i = 1, #names do
    local slot = (slots[i] or 0) + 1
    local e = {
      idx = i - 1, name = names[i], lname = string.lower(names[i]), key = keys[i] or names[i],
      slot = slot, area = sAreas[slot] or "Other", markId = "##cqwm" .. (i - 1),
    }
    e.fav = favs[e.key] == true
    -- marks of looks no longer listed (moved away, other source) are dropped
    e.marked = marks[e.key] == true
    if e.marked then
      newMarks[e.key] = true
      markCount = markCount + 1
    end
    makeLabel(e)
    newItems[#newItems + 1] = e
    newByIdx[e.idx] = e
  end
  table.sort(newItems, function(a, b)
    if a.slot ~= b.slot then return a.slot < b.slot end
    if a.lname ~= b.lname then return a.lname < b.lname end
    return a.idx < b.idx
  end)
  items, byIdx = newItems, newByIdx
  marks = newMarks
  setMarkCount(markCount)

  local newAreas, seen = { "All" }, {}
  for i = 1, #items do
    local a = items[i].area
    if not seen[a] then
      seen[a] = true
      newAreas[#newAreas + 1] = a
    end
  end
  areas = newAreas
  if cfg.area ~= "All" and not seen[cfg.area] then cfg.area = "All" end
  S.built = true
  S.newItems = false
  V.dirty = true
end

-- Reads the outfit state; returns false if the bridge's list belongs to another build/session.
local function poll()
  local p = call("Poll")
  if not p then return false end
  if p[1] ~= S.token then
    S.built = false
    return false
  end
  local active, blocked = p[2] == 1, p[3] == 1
  for k in pairs(wornNext) do wornNext[k] = nil end
  for i = 4, #p do wornNext[p[i]] = true end
  local changed = active ~= S.outfitActive or blocked ~= S.blocked
  for k in pairs(worn) do if not wornNext[k] then changed = true break end end
  if not changed then
    for k in pairs(wornNext) do if not worn[k] then changed = true break end end
  end
  worn, wornNext = wornNext, worn
  S.outfitActive, S.blocked = active, blocked
  if changed then
    if cfg.wornOnly then V.dirty = true else updateHeader() end
  end
  return true
end

local function ensureList()
  if not S.built then
    rebuild()
    poll()
  end
end

local function schedulePolls()
  S.pollSoon[1] = S.clock + 0.25
  S.pollSoon[2] = S.clock + 1.0
end

local function refreshOutfits()
  local list = call("GetOutfitNames") or {}
  local changed = #list ~= #S.outfits
  if not changed then
    for i = 1, #list do
      if list[i] ~= S.outfits[i] then changed = true break end
    end
  end
  if changed then
    S.outfits = list
    S.outfitLabels = {}
    for i = 1, #list do S.outfitLabels[i] = list[i] .. "##cqwo" .. i end
  end
  S.currentOutfit = call("GetCurrentOutfit") or ""
end

------------------------------------------------------------------------ actions

local function toggleEntry(e)
  if not e then return end
  local r = call("Toggle", e.idx)
  if r == 1 then
    for k in pairs(worn) do
      local o = byIdx[k]
      if o and o.slot == e.slot then worn[k] = nil end
    end
    worn[e.idx] = true
    S.outfitActive = true
    setStatus("On: " .. e.name)
  elseif r == 0 then
    worn[e.idx] = nil
    setStatus("Off: " .. e.name)
  else
    setStatus(S.blocked and "Locked: quest outfit" or "Refused: " .. e.name)
  end
  if cfg.wornOnly then V.dirty = true else updateHeader() end
  schedulePolls()
end

local function setOutfitActive(on)
  local ok = call("SetOutfitActive", on)
  if on and not ok then setStatus("Outfit can't be switched on now") end
  schedulePolls()
end

local function wearNextOutfit()
  refreshOutfits()
  local list = S.outfits
  if #list == 0 then setStatus("No saved outfits") return end
  local nextName = list[1]
  for i = 1, #list do
    if list[i] == S.currentOutfit then nextName = list[(i % #list) + 1] break end
  end
  if call("LoadOutfit", nextName) then
    S.currentOutfit = nextName
    setStatus("Outfit: " .. nextName)
  else
    setStatus("Refused: " .. nextName)
  end
  schedulePolls()
end

local function toggleFav(e)
  e.fav = not e.fav
  favs[e.key] = e.fav or nil
  makeLabel(e)
  saveFavs()
  if cfg.favOnly then V.dirty = true end
end

local function toggleMark(e)
  if not e then return end
  e.marked = not e.marked
  marks[e.key] = e.marked or nil
  setMarkCount(S.markCount + (e.marked and 1 or -1))
  S.nextStashCheck = 0
  if cfg.markOnly then V.dirty = true else updateHeader() end
end

local function clearMarks()
  for i = 1, #items do items[i].marked = false end
  marks = {}
  setMarkCount(0)
  if cfg.markOnly then V.dirty = true else updateHeader() end
end

-- Sends every inventory copy of the marked looks to the stash (bridge MoveListToStash):
-- worn and quest pieces stay, so do looks that are only in the stash / wardrobe store.
local function moveMarked()
  if S.markCount == 0 then setStatus("Nothing marked") return end
  if not bridge() then setStatus("Redscript part not loaded") return end
  if not S.built or not poll() then
    ensureList() -- the bridge's list changed (load, other build): indices must match first
    setStatus("List refreshed, press again")
    return
  end
  call("ClearMoveList")
  for i = 1, #items do
    if items[i].marked then call("AddToMoveList", items[i].idx) end
  end
  local r = call("MoveListToStash")
  if type(r) ~= "table" or type(r[1]) ~= "number" then
    setStatus("Move failed (see CyberslopQuickWardrobe.log)")
    return
  end
  if r[1] == -1 then
    S.stashOK = false
    setStatus("No stash in reach: stand near your stash or sit in your own car", 5)
    return
  end
  if r[1] ~= 0 or #r < 6 then
    setStatus("Not ready, try again")
    return
  end
  for i = 7, #r do
    local e = byIdx[r[i]]
    if e then marks[e.key] = nil end
  end
  local msg = "Stashed " .. r[2] .. (r[2] == 1 and " item" or " items")
  if r[3] > 0 then msg = msg .. " | kept " .. r[3] .. " worn" end
  if r[4] > 0 then msg = msg .. " | kept " .. r[4] .. " quest" end
  if r[5] > 0 then msg = msg .. " | " .. r[5] .. " failed" end
  if r[6] > 0 then msg = msg .. " | " .. r[6] .. " not in inventory" end
  rebuild() -- moved looks leave an inventory list; the marks follow the new list
  poll()
  setStatus(msg, 6)
  schedulePolls()
end

local function hudVisible()
  return cfg.pinned and not S.overlay and S.playerOK and S.hudAllowed
end

local function moveCursor(d)
  if #view == 0 then return end
  local c = V.cursor + d
  if c < 1 then c = #view elseif c > #view then c = 1 end
  V.cursor = c
  V.cursorMoved = true
end

local function cycleArea(d)
  local cur = 1
  for i = 1, #areas do if areas[i] == cfg.area then cur = i break end end
  cur = cur + d
  if cur < 1 then cur = #areas elseif cur > #areas then cur = 1 end
  cfg.area = areas[cur]
  V.dirty = true -- config.json is written when the overlay closes or the game quits
end

------------------------------------------------------------------------ mouse mode
-- Mouse mode (1.2.0): CET gives no window the mouse while its overlay is closed, so the pinned
-- window reads the mouse itself. The redscript part collects the raw mouse (Codeware Input/Key +
-- Input/Axis) and holds the camera and V's weapons with the game's own gameplay restrictions
-- while the mode is on (the keyboard stays V's). This side moves a drawn cursor and hit-tests the
-- window as drawn in the last frame. Other CET windows are never touched.
-- On: closing the overlay with the window pinned (Options: take the mouse), or the hotkey.
-- Off: Done, a click outside the window, the hotkey, any menu, the overlay, unpin, loading; the
-- redscript watchdog also lets go if this side stops asking for input.

local CT = {
  on = false, want = false, wantUntil = 0, sys = nil, sysAt = -10,
  x = 0, y = 0, sw = 1920, sh = 1080, scroll = 0,
  wx0 = 0, wy0 = 0, wx1 = 0, wy1 = 0,       -- pinned window, last frame
  cx0 = 0, cy0 = 0, cx1 = 0, cy1 = 0,       -- its list, last frame
  rowX0 = 0, rowY0 = 0, rowH = 20, rowFirst = 1, rowLast = 0, boxW = 22,
  nbtn = 0, bx0 = {}, by0 = {}, bx1 = {}, by1 = {}, bid = {},
  dl = nil, dlAt = -10, colCursor = nil, colEdge = nil, colHover = nil,
}

local function mouseOn()
  if CT.on then return true end
  if call("SetMouse", true) ~= true then
    setStatus("Mouse mode not available (redscript part not loaded?)")
    return false
  end
  CT.on, CT.want, CT.scroll, CT.sys = true, false, 0, nil
  local ok, w, h = pcall(GetDisplayResolution)
  if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then CT.sw, CT.sh = w, h end
  if CT.wx1 > CT.wx0 then
    CT.x, CT.y = (CT.wx0 + CT.wx1) * 0.5, (CT.wy0 + CT.wy1) * 0.5
  else
    CT.x, CT.y = CT.sw * 0.5, CT.sh * 0.5
  end
  return true
end

local function mouseOff()
  CT.want = false
  if not CT.on then return end
  CT.on, CT.scroll = false, 0
  call("SetMouse", false)
end

-- the input since the last frame; the system handle is kept for 2 s (one bridge call a frame)
local function mousePull()
  if not CT.sys or S.clock >= CT.sysAt then
    CT.sys = bridge()
    CT.sysAt = S.clock + 2
    if not CT.sys then return nil end
  end
  local ok, r = pcall(CT.sys.PullInput, CT.sys)
  if not ok or type(r) ~= "table" or #r < 6 then
    CT.sys = nil
    return nil
  end
  return r
end

local function inRect(x, y, x0, y0, x1, y1)
  return x >= x0 and x <= x1 and y >= y0 and y <= y1
end

-- what the cursor is over: "button" / "box" / "row" with an index, "window", or nil (outside)
local function mouseHit()
  local x, y = CT.x, CT.y
  if not inRect(x, y, CT.wx0, CT.wy0, CT.wx1, CT.wy1) then return nil, 0 end
  for i = 1, CT.nbtn do
    if inRect(x, y, CT.bx0[i], CT.by0[i], CT.bx1[i], CT.by1[i]) then return "button", i end
  end
  if inRect(x, y, CT.cx0, CT.cy0, CT.cx1, CT.cy1) and y >= CT.rowY0 then
    local i = CT.rowFirst + math.floor((y - CT.rowY0) / CT.rowH)
    if i <= CT.rowLast and view[i] then
      if x < CT.rowX0 + CT.boxW then return "box", i end
      return "row", i
    end
  end
  return "window", 0
end

local function mouseButton(id)
  if id == "done" then
    mouseOff()
  elseif id == "outfit" then
    setOutfitActive(not S.outfitActive)
  elseif id == "prev" then
    cycleArea(-1)
  elseif id == "next" then
    cycleArea(1)
  elseif id == "stash" then
    moveMarked()
  end
end

-- left: name = put on / take off, box = mark, button = its action, outside = mouse back to the
-- game; right: name = favourite
local function mouseClick(left)
  local kind, i = mouseHit()
  if not kind then
    if left then
      mouseOff()
      setStatus("Mouse back to the game")
    end
    return
  end
  if kind == "button" then
    if left then mouseButton(CT.bid[i]) end
  elseif kind == "box" then
    if left then
      V.cursor = i
      toggleMark(view[i])
    end
  elseif kind == "row" then
    V.cursor = i
    if left then toggleEntry(view[i]) else toggleFav(view[i]) end
  end
end

-- once a frame from onUpdate while the mode is on (geometry from the last drawn frame)
local function mouseUpdate()
  if not hudVisible() or not S.built then
    mouseOff()
    return
  end
  local r = mousePull()
  if not r then return end
  if r[1] ~= 1 then -- the redscript side let go (watchdog, load)
    CT.on = false
    return
  end
  local sp = cfg.mouseSpeed
  CT.x = math.max(0, math.min(CT.sw - 1, CT.x + r[2] * sp))
  CT.y = math.max(0, math.min(CT.sh - 1, CT.y + r[3] * sp))
  if r[4] ~= 0 then CT.scroll = CT.scroll - r[4] * 3 end
  for _ = 1, r[5] do
    if not CT.on then break end
    mouseClick(true)
  end
  for _ = 1, r[6] do
    if not CT.on then break end
    mouseClick(false)
  end
end

------------------------------------------------------------------------ drawing

local COL_SLOT_W = 130

local function drawRows(interactive)
  local n = #view
  local rowH = ImGui.GetTextLineHeightWithSpacing()
  local winH = ImGui.GetWindowHeight()
  -- ImGui clamps the scroll one frame late when the list shrinks (filter): clip with the clamp now
  local scrollY = math.min(ImGui.GetScrollY(), math.max(0, n * rowH - winH))
  if V.cursorMoved then
    V.cursorMoved = false
    local top = (V.cursor - 1) * rowH
    if top < scrollY then
      scrollY = top
      ImGui.SetScrollY(top)
    elseif top + rowH > scrollY + winH then
      scrollY = math.max(0, top + rowH - winH)
      ImGui.SetScrollY(scrollY)
    end
  end
  local mouse = CT.on and not interactive
  if mouse and CT.scroll ~= 0 then -- mouse wheel in mouse mode
    scrollY = math.max(0, math.min(math.max(0, n * rowH - winH), scrollY + CT.scroll * rowH))
    ImGui.SetScrollY(scrollY)
    CT.scroll = 0
  end
  local first = math.max(1, math.floor(scrollY / rowH) + 1)
  local last = math.min(n, first + math.ceil(winH / rowH) + 1)
  local startY = ImGui.GetCursorPosY()
  local availW = ImGui.GetContentRegionAvail()
  local nameW = math.max(80, availW - COL_SLOT_W)
  local selW = math.max(40, nameW - ImGui.GetFontSize() - 8)
  ImGui.SetCursorPosY(startY + (first - 1) * rowH)
  if mouse then -- geometry for the next frame's hit test (numbers only, no garbage)
    local cx, cy = ImGui.GetWindowPos()
    local cw, ch = ImGui.GetWindowSize()
    CT.cx0, CT.cy0, CT.cx1, CT.cy1 = cx, cy, cx + cw, cy + ch
    CT.rowX0, CT.rowY0 = ImGui.GetCursorScreenPos()
    CT.rowFirst, CT.rowLast, CT.rowH = first, last, rowH
    CT.boxW = ImGui.GetFontSize() + 4
  end
  -- no frame padding: the mark box is one text line high, so rows keep the text line height
  ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
  for i = first, last do
    local e = view[i]
    local isWorn = worn[e.idx] == true
    local isCursor = i == V.cursor and (not interactive or cfg.pinned)
    local _, markPressed = ImGui.Checkbox(e.markId, e.marked == true)
    if interactive and markPressed and S.clock - S.overlayAt > 0.25 then
      V.cursor = i
      toggleMark(e)
    end
    ImGui.SameLine()
    if isCursor then ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.82, 0.25, 1.0) end
    local ret = ImGui.Selectable(e.label, isWorn, 0, selW, 0)
    if isCursor then ImGui.PopStyleColor(1) end
    if interactive then
      -- CET's Selectable returns the row's new selected state: a click flips it
      if ret ~= isWorn and S.clock - S.overlayAt > 0.25 and S.clock - S.lastAction > 0.15 then
        S.lastAction = S.clock
        V.cursor = i
        toggleEntry(e)
      elseif ImGui.IsItemClicked(1) then
        toggleFav(e)
      end
    end
    ImGui.SameLine(nameW + 12)
    ImGui.TextDisabled(slotNames[e.slot] or "")
  end
  ImGui.PopStyleVar(1)
  ImGui.SetCursorPosY(startY + n * rowH)
  ImGui.Dummy(1, 0)
end

local function drawStatus()
  if S.clock - S.statusAt < S.statusDur then
    ImGui.TextColored(1.0, 0.82, 0.25, 1.0, S.status)
  end
end

local function hudButton(label, id)
  ImGui.Button(label)
  local n = CT.nbtn + 1
  CT.nbtn = n
  CT.bx0[n], CT.by0[n] = ImGui.GetItemRectMin()
  CT.bx1[n], CT.by1[n] = ImGui.GetItemRectMax()
  CT.bid[n] = id
end

local function drawHud()
  local wx, wy = ImGui.GetWindowPos()
  local ww, wh = ImGui.GetWindowSize()
  CT.wx0, CT.wy0, CT.wx1, CT.wy1 = wx, wy, wx + ww, wy + wh
  CT.nbtn = 0
  if CT.on then
    hudButton("Done##cqwmdone", "done")
    ImGui.SameLine()
    hudButton(S.outfitActive and "Outfit: on##cqwmout" or "Outfit: off##cqwmout", "outfit")
    ImGui.SameLine()
    hudButton("<##cqwmprev", "prev")
    ImGui.SameLine()
    hudButton(">##cqwmnext", "next")
    if S.markCount > 0 then
      ImGui.SameLine()
      hudButton(S.moveLabel, "stash")
    end
    ImGui.TextDisabled("Click outside the window or Done: mouse back to the game")
  end
  ImGui.Text(V.header)
  drawStatus()
  if not S.hudChildFlags then
    S.hudChildFlags = (ImGuiWindowFlags.NoScrollbar or 0) + (ImGuiWindowFlags.NoInputs or 0)
  end
  ImGui.BeginChild("##cqwhud", 0, 0, false, S.hudChildFlags)
  drawRows(false)
  ImGui.EndChild()
end

-- the cursor and the highlight under it, on top of everything (foreground draw list, kept 5 s)
local function drawMouse()
  if not CT.colCursor then
    CT.colCursor = ImGui.GetColorU32(1.0, 0.82, 0.25, 1.0)
    CT.colEdge = ImGui.GetColorU32(0.0, 0.0, 0.0, 0.9)
    CT.colHover = ImGui.GetColorU32(1.0, 0.82, 0.25, 0.18)
  end
  if not CT.dl or S.clock >= CT.dlAt then
    CT.dl = ImGui.GetForegroundDrawList()
    CT.dlAt = S.clock + 5
  end
  local dl = CT.dl
  local kind, i = mouseHit()
  if kind == "button" then
    ImGui.ImDrawListAddRectFilled(dl, CT.bx0[i], CT.by0[i], CT.bx1[i], CT.by1[i], CT.colHover)
  elseif kind == "row" or kind == "box" then
    local y0 = CT.rowY0 + (i - CT.rowFirst) * CT.rowH
    ImGui.ImDrawListAddRectFilled(dl, CT.cx0, math.max(CT.cy0, y0), CT.cx1, math.min(CT.cy1, y0 + CT.rowH), CT.colHover)
  end
  local x, y = CT.x, CT.y
  ImGui.ImDrawListAddTriangleFilled(dl, x - 1, y - 2, x + 15, y + 15, x - 1, y + 20, CT.colEdge)
  ImGui.ImDrawListAddTriangleFilled(dl, x, y, x + 12, y + 13, x, y + 17, CT.colCursor)
end

local function tooltip(text)
  if ImGui.IsItemHovered() then ImGui.SetTooltip(text) end
end

local function drawItemsTab()
  ImGui.SetNextItemWidth(170)
  local q, qChanged = ImGui.InputTextWithHint("##cqwsearch", "Search", V.search, 64)
  if qChanged then
    V.search = q
    V.query = string.lower(q)
    V.dirty = true
  end
  ImGui.SameLine()
  ImGui.SetNextItemWidth(110)
  local cur = 0
  for i = 1, #areas do if areas[i] == cfg.area then cur = i - 1 break end end
  local nc, aChanged = ImGui.Combo("##cqwarea", cur, areas, #areas)
  if aChanged and areas[nc + 1] then
    cfg.area = areas[nc + 1]
    V.dirty = true
    saveCfg()
  end
  local w, wChanged = ImGui.Checkbox("Worn", cfg.wornOnly)
  if wChanged then cfg.wornOnly = w V.dirty = true saveCfg() end
  ImGui.SameLine()
  local f, fChanged = ImGui.Checkbox("Favourites", cfg.favOnly)
  if fChanged then cfg.favOnly = f V.dirty = true saveCfg() end
  tooltip("Right-click a row to mark or unmark it as a favourite (*)")
  ImGui.SameLine()
  local m, mChanged = ImGui.Checkbox("Marked", cfg.markOnly)
  if mChanged then cfg.markOnly = m V.dirty = true saveCfg() end
  tooltip("Only the rows ticked in the box on the left (marked for the stash)")
  ImGui.TextDisabled(V.header)
  if S.markCount > 0 then
    if ImGui.Button(S.moveLabel) and S.clock - S.overlayAt > 0.25 then moveMarked() end
    tooltip("Every inventory copy of the marked items goes to the stash. Worn and quest pieces stay.\n"
      .. "Needs a stash in reach: near your stash, or sitting in your own car (its trunk is the stash).")
    ImGui.SameLine()
    if ImGui.Button("Clear marks##cqwclr") then clearMarks() end
    if not S.stashOK then
      ImGui.SameLine()
      ImGui.TextDisabled("no stash in reach")
    end
  end
  drawStatus()
  ImGui.BeginChild("##cqwlist", 0, 0, true)
  drawRows(true)
  ImGui.EndChild()
end

local function drawOutfitsTab()
  if S.clock >= S.nextOutfitRefresh then
    S.nextOutfitRefresh = S.clock + 1.0
    refreshOutfits()
  end
  ImGui.SetNextItemWidth(170)
  local name = ImGui.InputTextWithHint("##cqwsave", "New outfit name", S.saveName, 64)
  S.saveName = name
  ImGui.SameLine()
  if ImGui.Button("Save current") then
    if call("SaveOutfit", S.saveName) then
      setStatus("Saved: " .. S.saveName)
      S.saveName = ""
      S.nextOutfitRefresh = 0
    else
      setStatus("Name empty or taken")
    end
  end
  drawStatus()
  ImGui.BeginChild("##cqwoutfits", 0, 0, true)
  local list = S.outfits
  if #list == 0 then ImGui.TextDisabled("No saved outfits (Equipment-EX's list)") end
  for i = 1, #list do
    local isCur = list[i] == S.currentOutfit
    local ret = ImGui.Selectable(S.outfitLabels[i], isCur)
    if ret ~= isCur and S.clock - S.overlayAt > 0.25 and S.clock - S.lastAction > 0.15 then
      S.lastAction = S.clock
      if call("LoadOutfit", list[i]) then
        S.currentOutfit = list[i]
        setStatus("Outfit: " .. list[i])
      else
        setStatus("Refused: " .. list[i])
      end
      schedulePolls()
    end
  end
  ImGui.EndChild()
end

local function drawOptionsTab()
  local a, used = ImGui.SliderFloat("Pinned opacity", cfg.hudAlpha, 0.1, 1.0, "%.2f")
  if used then cfg.hudAlpha = a end -- saved when the overlay closes
  local t, tChanged = ImGui.Checkbox("Pinned: take the mouse when the overlay closes", cfg.takeMouse)
  if tChanged then cfg.takeMouse = t saveCfg() end
  local sp, spUsed = ImGui.SliderFloat("Mouse speed", cfg.mouseSpeed, 0.2, 4.0, "%.2f")
  if spUsed then cfg.mouseSpeed = sp end -- saved when the overlay closes
  ImGui.TextWrapped("Pinned: the window stays on screen when the CET overlay closes (hidden in menus) and, "
    .. "with the box above, keeps the mouse: a cursor of its own, camera and weapons held, keyboard free. "
    .. "Click outside the window or Done to give the mouse back. Hotkeys (CET Bindings, all unbound): "
    .. "mouse mode on / off, cursor up / down, put on / take off, mark, move marked to stash, body area, "
    .. "pin, outfit on / off, next saved outfit.")
  ImGui.TextDisabled("Source: Equipment-EX's own setting (same as its wardrobe menu).")
  ImGui.TextDisabled("Cyberslop Quick Wardrobe " .. VERSION)
end

local function greenButton(label, on)
  if on then
    ImGui.PushStyleColor(ImGuiCol.Button, 0.15, 0.50, 0.25, 1.0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.20, 0.62, 0.32, 1.0)
  end
  local pressed = ImGui.Button(label)
  if on then ImGui.PopStyleColor(2) end
  return pressed
end

local function drawFull()
  local wasPinned = cfg.pinned
  local pinPressed = greenButton(wasPinned and "Pinned##cqwpin" or "Pin##cqwpin", wasPinned)
  tooltip("Keep this window on screen after closing the CET overlay")
  if pinPressed then
    cfg.pinned = not cfg.pinned
    saveCfg()
  end
  ImGui.SameLine()
  if S.blocked then
    ImGui.TextDisabled("Locked (quest outfit)")
  else
    if ImGui.Button(S.outfitActive and "Outfit: on##cqwact" or "Outfit: off##cqwact") then
      setOutfitActive(not S.outfitActive)
    end
    tooltip("Off: Equipment-EX steps aside and your real equipment shows")
    ImGui.SameLine()
    local armed = S.clock - S.stripArmedAt < 3
    if ImGui.Button(armed and "Confirm strip##cqwstrip" or "Strip all##cqwstrip") then
      if armed then
        S.stripArmedAt = -10
        if call("UnequipAll") then setStatus("Stripped") end
        schedulePolls()
      else
        S.stripArmedAt = S.clock
      end
    end
    tooltip("Take every outfit item off (click twice)")
  end
  ImGui.SameLine()
  if ImGui.Button("Refresh##cqwref") then
    rebuild()
    poll()
  end
  ImGui.SetNextItemWidth(170)
  local src = S.source
  local ns, sChanged = ImGui.Combo("Source##cqwsrc", src, SOURCE_NAMES, #SOURCE_NAMES)
  if sChanged and ns ~= src then
    call("SetSource", ns)
    rebuild()
    poll()
  end
  tooltip("Equipment-EX's own item source, shared with its wardrobe menu")
  if ImGui.BeginTabBar("##cqwtabs") then
    if ImGui.BeginTabItem("Items") then
      drawItemsTab()
      ImGui.EndTabItem()
    end
    if ImGui.BeginTabItem("Outfits") then
      drawOutfitsTab()
      ImGui.EndTabItem()
    end
    if ImGui.BeginTabItem("Options") then
      drawOptionsTab()
      ImGui.EndTabItem()
    end
    ImGui.EndTabBar()
  end
end

------------------------------------------------------------------------ presence / menus

-- Menu gate: IsInMenu is read 10 times a second from onUpdate (never from onDraw) through a
-- blackboard handle that is fetched again every 2 s and whenever the player is gone (loading,
-- main menu), so a handle from an older session can't keep the window hidden. A plain GetBool
-- returns a Lua boolean; only the fetch creates handles on the Lua heap.
local MG = { bb = nil, id = nil, nextFetch = 0 }

local function fetchMenuBB()
  local ui = GetAllBlackboardDefs().UI_System
  MG.id = ui.IsInMenu
  MG.bb = Game.GetBlackboardSystem():Get(ui)
end

local function readInMenu() return MG.bb:GetBool(MG.id) end

local function updatePresence()
  local ok, p = pcall(Game.GetPlayer)
  S.playerOK = ok and p ~= nil and IsDefined(p)
  if not S.playerOK then MG.bb = nil end
end

local function updateMenuGate()
  if not S.playerOK then
    S.hudAllowed = false
    return
  end
  if not MG.bb or S.clock >= MG.nextFetch then
    MG.nextFetch = S.clock + 2
    if not pcall(fetchMenuBB) or not MG.bb then
      MG.bb = nil
      S.hudAllowed = false
      return
    end
  end
  local ok, inMenu = pcall(readInMenu)
  if not ok then MG.bb = nil end
  S.hudAllowed = ok and not inMenu
end

------------------------------------------------------------------------ CET events

registerHotkey("cqw_pin", "Quick Wardrobe: pin / unpin the window", function()
  cfg.pinned = not cfg.pinned
  saveCfg()
end)

registerHotkey("cqw_mouse", "Quick Wardrobe: mouse mode on / off (pinned window)", function()
  if CT.on then
    mouseOff()
  elseif hudVisible() and S.built then
    mouseOn()
  end
end)

registerHotkey("cqw_equip", "Quick Wardrobe: put on / take off the item under the cursor", function()
  if not hudVisible() then return end
  ensureList()
  if V.dirty then applyFilter() end
  toggleEntry(view[V.cursor])
end)

registerHotkey("cqw_mark", "Quick Wardrobe: mark / unmark the item under the cursor (for the stash)", function()
  if not hudVisible() then return end
  ensureList()
  if V.dirty then applyFilter() end
  toggleMark(view[V.cursor])
end)

registerHotkey("cqw_stash", "Quick Wardrobe: move the marked items to the stash", function()
  -- only with the marks on screen (pinned window visible): no blind moves, no rebuild in a menu
  if not (hudVisible() or S.overlay) then return end
  ensureList()
  moveMarked()
end)

registerHotkey("cqw_area_next", "Quick Wardrobe: next body area", function()
  if hudVisible() then cycleArea(1) end
end)

registerHotkey("cqw_area_prev", "Quick Wardrobe: previous body area", function()
  if hudVisible() then cycleArea(-1) end
end)

registerHotkey("cqw_outfit_toggle", "Quick Wardrobe: outfit on / off", function()
  local p = call("Poll")
  local active = p and p[2] == 1
  setOutfitActive(not active)
end)

registerHotkey("cqw_outfit_next", "Quick Wardrobe: wear the next saved outfit", function()
  wearNextOutfit()
end)

local function holdInput(dir)
  return function(down)
    if down then
      if not hudVisible() then return end
      moveCursor(dir)
      S.holdDir, S.holdT, S.holdStep = dir, 0, 0
    elseif S.holdDir == dir then
      S.holdDir = 0
    end
  end
end

registerInput("cqw_next", "Quick Wardrobe: cursor down (hold to scroll)", holdInput(1))
registerInput("cqw_prev", "Quick Wardrobe: cursor up (hold to scroll)", holdInput(-1))

registerForEvent("onInit", function()
  local c = loadJson("config.json")
  if c then
    for k, v in pairs(c) do
      if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
    end
  end
  favs = loadJson("favorites.json") or {}
  updatePresence()
end)

registerForEvent("onOverlayOpen", function()
  mouseOff()
  S.overlay = true
  S.overlayAt = S.clock
  updatePresence()
  if not S.playerOK then return end
  if S.built then
    S.source = call("GetSource") or S.source
    poll()
    if S.built then
      local raw = call("SourceCount")
      if raw and raw ~= S.rawCount then S.built = false end
    end
  end
  ensureList()
  S.nextOutfitRefresh = 0
  S.nextStashCheck = 0
end)

registerForEvent("onOverlayClose", function()
  S.overlay = false
  S.holdDir = 0
  if cfg.pinned and cfg.takeMouse then CT.want, CT.wantUntil = true, S.clock + 1.5 end
  saveCfg()
end)

registerForEvent("onUpdate", function(dt)
  S.clock = S.clock + dt
  if CT.on and not cfg.pinned then mouseOff() end
  if not cfg.pinned and not S.overlay then return end

  if S.clock >= S.nextPresence then
    S.nextPresence = S.clock + 0.25
    updatePresence()
  end
  -- menu gate for the pinned window, 10 times a second (it may linger up to 0.1 s over a menu)
  if not S.overlay and S.clock >= S.nextMenuCheck then
    S.nextMenuCheck = S.clock + 0.1
    updateMenuGate()
  end
  if not S.playerOK then
    S.hudAllowed = false
    mouseOff()
    return
  end

  -- mouse mode: taken after the overlay closed (once the window shows), then input every frame
  if CT.want then
    if hudVisible() and S.built then
      mouseOn()
    elseif S.clock > CT.wantUntil then
      CT.want = false
    end
  end
  if CT.on then mouseUpdate() end

  -- held list keys repeat after 0.35 s, 16 steps a second
  if S.holdDir ~= 0 then
    if not hudVisible() then
      S.holdDir = 0
    else
      S.holdT = S.holdT + dt
      if S.holdT > 0.35 then
        S.holdStep = S.holdStep + dt
        while S.holdStep >= 0.06 do
          S.holdStep = S.holdStep - 0.06
          moveCursor(S.holdDir)
        end
      end
    end
  end

  -- pinned but hidden by a menu: no polling (a missing list still gets built, so the
  -- window can show as soon as the menu closes)
  local visible = S.overlay or hudVisible()
  if not visible and S.built then return end
  local due = S.clock >= S.nextPoll
  for i = 1, 2 do
    if S.pollSoon[i] and S.clock >= S.pollSoon[i] then
      S.pollSoon[i] = nil
      due = true
    end
  end
  if due then
    S.nextPoll = S.clock + 0.5
    if not S.built or not poll() then
      ensureList() -- first use, new session or a list from another build: fetch it again
    end
  end
  if not visible then return end
  -- overlay open with marks: is a stash in reach (for the hint next to the move button), 1/s
  if S.overlay and S.markCount > 0 and S.clock >= S.nextStashCheck then
    S.nextStashCheck = S.clock + 1
    S.stashOK = call("StashInReach") == true
  end
  -- pinned, wardrobe-store source only: notice new clothes every 10 s (the store list is one
  -- native array copy; inventory sources would walk the whole inventory, so they are checked
  -- only when the overlay opens). No rebuild during play (that is the one heavy call, 1,000+
  -- items); the header says so and the overlay open / Refresh rebuilds.
  if not S.overlay and S.built and S.source == 0 and not S.newItems and S.clock >= S.nextSourceCheck then
    S.nextSourceCheck = S.clock + 10
    local raw = call("SourceCount")
    if raw and raw >= 0 and raw ~= S.rawCount then
      S.newItems = true
      updateHeader()
    end
  end
end)

registerForEvent("onDraw", function()
  if S.overlay then
    ImGui.SetNextWindowSize(420, 520, ImGuiCond.FirstUseEver)
    if ImGui.Begin(TITLE) then
      if not S.playerOK then
        ImGui.TextDisabled("Load a save first.")
      elseif not S.built then
        ImGui.TextDisabled(bridge() and "Equipment-EX not ready yet."
          or "Redscript part not loaded (r6\\scripts\\CyberslopQuickWardrobe).")
      else
        if V.dirty then applyFilter() end
        drawFull()
      end
    end
    ImGui.End()
    return
  end

  -- pinned, overlay closed: display only, hidden in menus and outside a loaded game.
  -- No game calls here: the flags come from onUpdate.
  if not cfg.pinned or not S.playerOK or not S.built or not S.hudAllowed then return end
  if V.dirty then applyFilter() end
  if not S.hudFlags then
    S.hudFlags = (ImGuiWindowFlags.NoInputs or 0) + (ImGuiWindowFlags.NoFocusOnAppearing or 0)
      + (ImGuiWindowFlags.NoBringToFrontOnFocus or 0) + (ImGuiWindowFlags.NoScrollbar or 0)
  end
  ImGui.SetNextWindowSize(420, 520, ImGuiCond.FirstUseEver)
  ImGui.SetNextWindowBgAlpha(CT.on and math.max(cfg.hudAlpha, 0.85) or cfg.hudAlpha)
  if ImGui.Begin(TITLE, S.hudFlags) then drawHud() end
  ImGui.End()
  if CT.on then drawMouse() end
end)

registerForEvent("onShutdown", function()
  mouseOff()
  saveCfg()
end)
