--[[
  Gizmo Vlog Builder  -  for DaVinci Resolve (free or Studio)

  What it does
    1. Reads the clips + music from the project you have open right now.
    2. Creates a NEW project (your original project is not touched).
    3. Builds a 2.39:1 cinematic timeline at 24 fps, ~90 seconds long:
         - Title card "DAY IN THE LIFE OF / GIZMO THE GREMLIN" over black, with fade in/out
         - Clips ordered by time of day (morning -> night), cut on the music's beat
         - Camera audio removed, the song underneath
    4. Looks at frames from every clip, measures how bright/dark it is, and gives each
       clip its own exposure correction plus a shared cinematic look
       (soft film contrast, warm highlights, cool shadows, slightly lower saturation).

  How to run
    Put this file in Resolve's Scripts/Utility folder (see README.md), open the project
    that contains your clips, then: Workspace > Scripts > Gizmo Vlog Builder.
    Progress is printed to Workspace > Console.

  Beat sync
    By default cuts follow a 109 BPM grid (the song's published tempo).
    For perfect sync: in your ORIGINAL project, open the song in the Source viewer, play it,
    and tap M on every beat you want a cut on (at least 8 markers). The script will use
    your markers instead of the BPM grid.
]]

local CONFIG = {
  PROJECT_NAME    = "Gizmo - Day in the Life",
  TIMELINE_NAME   = "Gizmo - Cinematic Cut",
  TARGET_SECONDS  = 90,
  FPS             = 24,
  WIDTH           = 1920,
  HEIGHT          = 804,          -- 1920x804 = 2.39:1
  BPM             = 109,
  FIRST_BEAT      = 0.0,          -- seconds into the song where the first downbeat lands
  BEATS_PER_BAR   = 4,
  TITLE_TEXT      = "DAY IN THE LIFE OF\nGIZMO THE GREMLIN",
  TITLE_FONT      = "Futura",
  TITLE_STYLE     = "Medium",
  TITLE_SIZE      = 0.055,
  AUTO_EXPOSURE   = true,
  -- cinematic look (applied on top of each clip's exposure fix)
  LOOK_SATURATION = 0.88,
  LOOK_SLOPE      = {1.03, 1.00, 0.97},    -- warm highlights
  LOOK_OFFSET     = {0.004, 0.008, 0.020}, -- slightly lifted, cool shadows (matte film blacks)
}

------------------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------------------
local function log(fmt, ...)
  print("[Gizmo] " .. string.format(fmt, ...))
end

local function round(x) return math.floor(x + 0.5) end

local function clamp(x, a, b)
  if x < a then return a elseif x > b then return b end
  return x
end

local function num(v)
  if v == nil then return nil end
  local s = tostring(v):match("[%d%.]+")
  return s and tonumber(s) or nil
end

local SEP = package.config:sub(1, 1)
local TMP = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
if TMP:sub(-1) == SEP then TMP = TMP:sub(1, -2) end

local function tc(frame)
  local fps = CONFIG.FPS
  local ff = frame % fps
  local s = math.floor(frame / fps)
  return string.format("%02d:%02d:%02d:%02d",
    math.floor(s / 3600), math.floor(s / 60) % 60, s % 60, ff)
end

local function collect(folder, out)
  if not folder then return end
  local clips = folder:GetClipList() or {}
  for _, c in pairs(clips) do table.insert(out, c) end
  local subs = folder:GetSubFolderList() or {}
  for _, f in pairs(subs) do collect(f, out) end
end

-- "DJI_20261107075737_0046_D" -> "075737_20261107" (time of day first => morning..night)
local function sortKey(name)
  local date, hms = tostring(name):match("(%d%d%d%d%d%d%d%d)(%d%d%d%d%d%d)")
  if date then return hms .. "_" .. date end
  return "999999_" .. tostring(name)
end

------------------------------------------------------------------------------------------
-- image analysis (stills exported from Resolve as BMP or PPM, parsed in plain Lua)
------------------------------------------------------------------------------------------
local function newHist()
  local h = { n = 0 }
  for i = 0, 255 do h[i] = 0 end
  return h
end

local function addPixel(h, r, g, b)
  local y = 0.2126 * r + 0.7152 * g + 0.0722 * b
  local bin = clamp(math.floor(y), 0, 255)
  h[bin] = h[bin] + 1
  h.n = h.n + 1
end

local function percentile(h, q)
  local target = h.n * q
  local acc = 0
  for i = 0, 255 do
    acc = acc + h[i]
    if acc >= target then return i / 255 end
  end
  return 1
end

local function u16(s, i) local a, b = s:byte(i, i + 1); return a + b * 256 end
local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function sampleStep(w, h)
  return math.max(1, math.floor(math.sqrt(w * h / 40000)))
end

local function readBMP(data, hist)
  if #data < 54 or data:sub(1, 2) ~= "BM" then return false end
  local off, w, h = u32(data, 11), u32(data, 19), u32(data, 23)
  if h >= 2147483648 then h = 4294967296 - h end
  local bpp, compression = u16(data, 29), u32(data, 31)
  if (bpp ~= 24 and bpp ~= 32) or (compression ~= 0 and compression ~= 3) then return false end
  local bytes = bpp / 8
  local rowSize = math.floor((w * bpp + 31) / 32) * 4
  local step = sampleStep(w, h)
  for y = 0, h - 1, step do
    local base = off + y * rowSize + 1
    for x = 0, w - 1, step do
      local p = base + x * bytes
      local b, g, r = data:byte(p, p + 2)
      if r then addPixel(hist, r, g, b) end
    end
  end
  return true
end

local function readPPM(data, hist)
  if data:sub(1, 2) ~= "P6" then return false end
  local pos, vals = 3, {}
  while #vals < 3 do
    local c = data:sub(pos, pos)
    if c == "" then return false
    elseif c == "#" then pos = (data:find("\n", pos, true) or #data) + 1
    elseif c:match("%s") then pos = pos + 1
    else
      local s, e = data:find("^%d+", pos)
      if not s then return false end
      table.insert(vals, tonumber(data:sub(s, e)))
      pos = e + 1
    end
  end
  pos = pos + 1
  local w, h, maxv = vals[1], vals[2], vals[3]
  local bps = (maxv > 255) and 2 or 1
  local step = sampleStep(w, h)
  for y = 0, h - 1, step do
    for x = 0, w - 1, step do
      local p = pos + (y * w + x) * 3 * bps
      local r, g, b
      if bps == 1 then
        r, g, b = data:byte(p, p + 2)
      else
        r, _, g, _, b = data:byte(p, p + 5)  -- high bytes of 16-bit big-endian samples
      end
      if b then addPixel(hist, r, g, b) end
    end
  end
  return true
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

-- Export the frame under the playhead and add its pixels to hist.
local stillFormat = nil
local function probeFrame(project, hist)
  local formats = stillFormat and { stillFormat } or { "bmp", "ppm" }
  for _, ext in ipairs(formats) do
    local path = TMP .. SEP .. "gizmo_probe." .. ext
    os.remove(path)
    local ok = project:ExportCurrentFrameAsStill(path)
    local data = ok and readFile(path)
    os.remove(path)
    if data then
      local parsed = (ext == "bmp") and readBMP(data, hist) or readPPM(data, hist)
      if parsed then stillFormat = ext; return true end
    end
  end
  return false
end

------------------------------------------------------------------------------------------
-- grading
------------------------------------------------------------------------------------------
-- Build a CDL that fixes exposure (levels + midtones) and adds the cinematic look.
local function buildCDL(stats)
  local k, o, p = 1.0, 0.0, 1.0
  if stats then
    local lo, md, hi = stats.lo, stats.md, stats.hi
    local night = md < 0.18
    local blackT, whiteT = 0.03, 0.90               -- soft, film-like highlight roll-off
    local midT = night and 0.24 or 0.40            -- keep night shots moody
    k = clamp((whiteT - blackT) / math.max(hi - lo, 0.05), 0.80, night and 1.25 or 1.35)
    o = clamp(blackT - lo * k, -0.12, 0.08)
    local m1 = clamp(md * k + o, 0.05, 0.95)
    p = clamp(math.log(midT) / math.log(m1), 0.75, 1.35)
  end
  local s, f = CONFIG.LOOK_SLOPE, CONFIG.LOOK_OFFSET
  return {
    NodeIndex  = "1",
    Slope      = string.format("%.4f %.4f %.4f", k * s[1], k * s[2], k * s[3]),
    Offset     = string.format("%.4f %.4f %.4f", o + f[1], o + f[2], o + f[3]),
    Power      = string.format("%.4f %.4f %.4f", p, p, p),
    Saturation = string.format("%.3f", CONFIG.LOOK_SATURATION),
  }
end

------------------------------------------------------------------------------------------
-- title
------------------------------------------------------------------------------------------
local function styleTitle(titleItem)
  local comp = titleItem:GetFusionCompByIndex(1)
  if not comp then log("Title: could not open its Fusion comp, left as default text."); return end
  local tool = comp:FindToolByID("TextPlus")
  if not tool then
    local list = comp:GetToolList(false, "TextPlus")
    if list then for _, t in pairs(list) do tool = t; break end end
  end
  if not tool then log("Title: Text+ tool not found."); return end

  comp:Lock()
  local function set(id, v, t)
    local ok = pcall(function()
      if t then tool:SetInput(id, v, t) else tool:SetInput(id, v) end
    end)
    if not ok then log("Title: could not set %s", id) end
  end
  set("StyledText", CONFIG.TITLE_TEXT)
  set("Font", CONFIG.TITLE_FONT)
  set("Style", CONFIG.TITLE_STYLE)
  set("Size", CONFIG.TITLE_SIZE)
  set("CharacterSpacingClone", 1.35)   -- wide tracking
  set("LineSpacingClone", 1.4)

  -- fade in over 1s, fade out over the last 1s
  pcall(function()
    local a = comp:GetAttrs()
    local s, e = a.COMPN_RenderStart, a.COMPN_RenderEnd
    local fps = CONFIG.FPS
    tool.Opacity1 = comp:BezierSpline()
    tool:SetInput("Opacity1", 0, s)
    tool:SetInput("Opacity1", 1, s + fps)
    tool:SetInput("Opacity1", 1, e - fps)
    tool:SetInput("Opacity1", 0, e)
  end)
  comp:Unlock()
end

------------------------------------------------------------------------------------------
-- cut planning
------------------------------------------------------------------------------------------
local function pickEvenly(list, n)
  if n >= #list then return list end
  local out = {}
  for i = 1, n do
    out[i] = list[math.floor((i - 1) * #list / n) + 1]
  end
  return out
end

-- Returns per-clip beat counts (sum == totalBeats, multiples of unit where possible).
local function planBeats(clips, totalBeats, unit, secPerBeat)
  local n = #clips
  local per = math.max(unit, math.floor(totalBeats / n / unit) * unit)
  local counts, maxB = {}, {}
  for i, c in ipairs(clips) do
    counts[i] = per
    maxB[i] = math.max(1, math.floor(c.usableSec / secPerBeat))
  end
  -- cap at source length
  local spare = totalBeats - per * n
  for i = 1, n do
    if counts[i] > maxB[i] then spare = spare + counts[i] - maxB[i]; counts[i] = maxB[i] end
  end
  -- hand out leftover beats to the longest clips first
  local order = {}
  for i = 1, n do order[i] = i end
  table.sort(order, function(a, b) return clips[a].usableSec > clips[b].usableSec end)
  local guard = 0
  while spare >= 1 and guard < 1000 do
    local gave = false
    for _, i in ipairs(order) do
      local give = math.min(unit, spare)
      if counts[i] + give <= maxB[i] and give > 0 then
        counts[i] = counts[i] + give
        spare = spare - give
        gave = true
      end
      if spare < 1 then break end
    end
    if not gave then break end
    guard = guard + 1
  end
  return counts
end

------------------------------------------------------------------------------------------
-- main
------------------------------------------------------------------------------------------
print("[Gizmo] Script started")
local resolve = nil
pcall(function() resolve = _G.resolve end)
if not resolve then pcall(function() resolve = Resolve() end) end
if not resolve then pcall(function() resolve = bmd.scriptapp("Resolve") end) end
if not resolve then pcall(function() resolve = fu:GetResolve() end) end
print("[Gizmo] Connected to Resolve: " .. tostring(resolve ~= nil))

local function main()
  if not resolve then error("Could not connect to DaVinci Resolve.") end
  local fps = CONFIG.FPS
  local pm = resolve:GetProjectManager()
  local src = pm:GetCurrentProject()
  if not src then error("Open the project that contains your clips first.") end
  local srcFps = num(src:GetSetting("timelineFrameRate")) or fps
  log("Reading media from project '%s'", src:GetName())

  -- 1. gather media from the current project ------------------------------------------
  local all = {}
  collect(src:GetMediaPool():GetRootFolder(), all)
  local videos, music = {}, nil
  for _, c in ipairs(all) do
    local typ = c:GetClipProperty("Type") or ""
    local path = c:GetClipProperty("File Path") or ""
    if path ~= "" then
      if typ:find("Video") then
        table.insert(videos, { path = path, name = c:GetName() })
      elseif typ:find("Audio") and not music then
        music = { path = path, name = c:GetName(), markers = c:GetMarkers() or {} }
      end
    end
  end
  if #videos == 0 then error("No video clips found in the Media Pool.") end
  if not music then error("No audio-only clip (your song) found in the Media Pool.") end
  table.sort(videos, function(a, b) return sortKey(a.name) < sortKey(b.name) end)
  log("Found %d video clips and music '%s'", #videos, music.name)

  local markerSecs = {}
  for f, _ in pairs(music.markers) do table.insert(markerSecs, tonumber(f) / srcFps) end
  table.sort(markerSecs)

  -- 2. new project ---------------------------------------------------------------------
  local proj = pm:CreateProject(CONFIG.PROJECT_NAME)
  local suffix = 2
  while not proj and suffix < 50 do
    proj = pm:CreateProject(CONFIG.PROJECT_NAME .. " " .. suffix)
    suffix = suffix + 1
  end
  if not proj then error("Could not create a new project.") end
  log("Created project '%s'", proj:GetName())

  local settings = {
    timelineFrameRate         = tostring(fps),
    timelinePlaybackFrameRate = tostring(fps),
    timelineResolutionWidth   = tostring(CONFIG.WIDTH),
    timelineResolutionHeight  = tostring(CONFIG.HEIGHT),
  }
  for k, v in pairs(settings) do
    if not proj:SetSetting(k, v) then log("Note: could not set %s = %s", k, v) end
  end
  pcall(function() proj:SetSetting("timelineInputResMismatchBehavior", "scaleToCrop") end)
  local cropOK = false
  pcall(function() cropOK = (proj:GetSetting("timelineInputResMismatchBehavior") == "scaleToCrop") end)

  -- 3. import ---------------------------------------------------------------------------
  local mp = proj:GetMediaPool()
  local paths = { music.path }
  for _, v in ipairs(videos) do table.insert(paths, v.path) end
  local imported = mp:ImportMedia(paths) or {}
  local byPath = {}
  for _, it in pairs(imported) do byPath[it:GetClipProperty("File Path")] = it end
  music.item = byPath[music.path]
  if not music.item then error("Could not import the music file.") end

  local ready = {}
  for _, v in ipairs(videos) do
    v.item = byPath[v.path]
    if v.item then
      v.fps = num(v.item:GetClipProperty("FPS")) or fps
      v.frames = num(v.item:GetClipProperty("Frames"))
      if not v.frames then
        local h, m, s, f = tostring(v.item:GetClipProperty("Duration") or ""):match("(%d+):(%d+):(%d+)[:;](%d+)")
        if h then v.frames = ((h * 60 + m) * 60 + s) * math.floor(v.fps + 0.5) + f end
      end
      local rw, rh = tostring(v.item:GetClipProperty("Resolution") or ""):match("(%d+)x(%d+)")
      v.resW, v.resH = tonumber(rw), tonumber(rh)
      if v.frames and v.frames > 0 then
        v.usableSec = v.frames / v.fps * 0.8
        table.insert(ready, v)
      else
        log("Skipping %s (unknown length)", v.name)
      end
    else
      log("Skipping %s (import failed)", v.name)
    end
  end

  -- 4. timeline + title -----------------------------------------------------------------
  local tl = mp:CreateEmptyTimeline(CONFIG.TIMELINE_NAME)
  if not tl then error("Could not create timeline.") end
  proj:SetCurrentTimeline(tl)
  resolve:OpenPage("edit")
  local start = tl:GetStartFrame()

  tl:SetCurrentTimecode(tc(start))
  local titleEnd = start + 5 * fps
  local title = tl:InsertFusionTitleIntoTimeline("Text+")
  if title then
    titleEnd = title:GetEnd()
    styleTitle(title)
    log("Title added (%.1fs)", (titleEnd - start) / fps)
  else
    log("Could not add the title automatically - add a Text+ title at the start by hand.")
  end
  local titleSec = (titleEnd - start) / fps

  -- 5. beat grid -------------------------------------------------------------------------
  local T = CONFIG.TARGET_SECONDS
  local beatTime, firstIdx, lastIdx, unit
  if #markerSecs >= 8 then
    log("Using %d markers from the song as cut points", #markerSecs)
    beatTime = function(i) return markerSecs[i + 1] end
    for i = 0, #markerSecs - 1 do
      if not firstIdx and markerSecs[i + 1] >= titleSec then firstIdx = i end
      if markerSecs[i + 1] <= T then lastIdx = i end
    end
    unit = 1
  else
    local b = 60 / CONFIG.BPM
    log("Using %.1f BPM grid (first beat at %.2fs)", CONFIG.BPM, CONFIG.FIRST_BEAT)
    beatTime = function(i) return CONFIG.FIRST_BEAT + i * b end
    local bar = CONFIG.BEATS_PER_BAR
    firstIdx = math.max(0, math.ceil((titleSec - CONFIG.FIRST_BEAT) / (b * bar)) * bar)
    lastIdx = math.floor((T - CONFIG.FIRST_BEAT) / b)
    unit = 2
  end
  if not firstIdx or not lastIdx or lastIdx <= firstIdx then
    error("Not enough beats/markers after the title to place clips.")
  end
  local totalBeats = lastIdx - firstIdx
  local maxClips = math.floor(totalBeats / unit)
  local clips = pickEvenly(ready, maxClips)
  local secPerBeat = (beatTime(lastIdx) - beatTime(firstIdx)) / totalBeats
  local counts = planBeats(clips, totalBeats, unit, secPerBeat)

  -- 6. place clips (each placement corrects for any rounding of the previous one) --------
  local cursor = nil
  local idx = firstIdx
  local placed = {}
  for k, v in ipairs(clips) do
    local tStart = start + round(beatTime(idx) * fps)
    idx = idx + counts[k]
    local tEnd = start + round(beatTime(idx) * fps)
    local recF = cursor or tStart
    local L = math.max(6, tEnd - recF)
    local n = math.max(2, round(L * v.fps / fps))
    local uS, uE = math.floor(v.frames * 0.12), math.floor(v.frames * 0.92)
    if uE - uS < n then uS, uE = 0, v.frames end
    local s0 = clamp(round(v.frames * 0.45 - n / 2), uS, math.max(uS, uE - n))
    local e0 = math.min(v.frames - 1, s0 + n - 1)
    local res = mp:AppendToTimeline({ {
      mediaPoolItem = v.item, startFrame = s0, endFrame = e0,
      mediaType = 1, trackIndex = 1, recordFrame = recF,
    } })
    local item = res and res[1]
    if item then
      cursor = item:GetEnd()
      table.insert(placed, { item = item, clip = v })
      if not cropOK and v.resW and v.resH then
        local fit = math.min(CONFIG.WIDTH / v.resW, CONFIG.HEIGHT / v.resH)
        local z = math.max(CONFIG.WIDTH / (v.resW * fit), CONFIG.HEIGHT / (v.resH * fit))
        item:SetProperty("ZoomX", z)
        item:SetProperty("ZoomY", z)
      end
    else
      log("Could not place %s", v.name)
      cursor = recF + L
    end
  end
  log("Placed %d clips, video ends at %.1fs", #placed, (cursor - start) / fps)

  -- 7. music ---------------------------------------------------------------------------
  local mFps = num(music.item:GetClipProperty("FPS"))
  if not mFps or mFps < 1 then mFps = fps end
  local musicLen = round((cursor - start) / fps * mFps)
  local mres = mp:AppendToTimeline({ {
    mediaPoolItem = music.item, startFrame = 0, endFrame = musicLen,
    trackIndex = 1, recordFrame = start,
  } })
  if not (mres and mres[1]) then
    log("Could not place the music automatically - drag it onto A1 at the start.")
  end

  -- 8. measure + grade -----------------------------------------------------------------
  resolve:OpenPage("color")
  local graded = 0
  for i, p in ipairs(placed) do
    local stats = nil
    if CONFIG.AUTO_EXPOSURE then
      local s, e = p.item:GetStart(), p.item:GetEnd()
      local hist = newHist()
      for _, frac in ipairs({ 0.25, 0.5, 0.75 }) do
        tl:SetCurrentTimecode(tc(round(s + (e - s) * frac)))
        probeFrame(proj, hist)
      end
      if hist.n > 0 then
        stats = { lo = percentile(hist, 0.02), md = percentile(hist, 0.5), hi = percentile(hist, 0.98) }
      end
    end
    local cdl = buildCDL(stats)
    local ok = p.item:SetCDL(cdl)
    if ok then graded = graded + 1 end
    if stats then
      log("%2d %-34s black %.2f  mid %.2f  white %.2f  -> slope %s power %s",
        i, p.clip.name, stats.lo, stats.md, stats.hi, cdl.Slope, cdl.Power)
    else
      log("%2d %-34s (could not measure - look only)", i, p.clip.name)
    end
  end
  log("Graded %d/%d clips", graded, #placed)

  resolve:OpenPage("edit")
  tl:SetCurrentTimecode(tc(start))
  pm:SaveProject()
  log("Done! Project '%s' is ready.", proj:GetName())
end

local ok, err = pcall(main)
if not ok then log("ERROR: %s", tostring(err)) end
