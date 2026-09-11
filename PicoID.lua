------------------------------------------------------------------
-- PicoID v1.19 — imprinted-proc inventory viewer (WotLK 3.3.5a)
-- Shows every equipped item with the procs imprinted on it:
--   Item - Imprinted proc - Proc ID - Item of origin
-- Duplicated procs are shown in red (they never fire twice).
--
-- v1.15: PICO share strings. The Share button produces a compact string of
--   your slot/item/proc IDs; another PicoID user pastes it into the same
--   dialog and gets a read-only popup of your procs, with names, origins and
--   drop sources rebuilt from THEIR local PicoIDData tables. The whole
--   feature is offline: it sends NOTHING on the addon pipe, so the server
--   throttle is untouched. Also: icons for the item, proc and origin item
--   (origin ids from ICIPROCSRC, a stream verb previously ignored); hover now
--   shows the full effect body -- damage AND healing -- at the imprinted
--   magnitude, extraction-window style, plus the proc's scaling coefficients
--   from ICIPROCFACT; sortable columns; a live filter box; Shift-click for
--   the bare proc ID; and the first MANUAL.txt.
--
-- v1.16: DIRECT in-game sharing, approved by the server owner: the Share
--   dialog gains a "send to player" row that whispers your PICO string to
--   another PicoID user on the client-owned "PICO" prefix (zero AddonThrottle
--   tokens -- it rides the CMSG_MESSAGECHAT anti-DoS lane instead, paced far
--   under it). They get ONE clickable chat line; nothing auto-opens, received
--   text is never executed, delivery is honestly reported as unconfirmed
--   (this realm has no addon receipt), and an accept-shares option can drop
--   incoming shares entirely. All limits in the DIRECT SHARING section are
--   the admin's, hard-coded. Also: the hover's SP/AP percentages relabeled
--   as explicit-data maxima (see ScalingNote) -- zeros are now hidden, since
--   zero only means "no explicit bonus-data row", not "no scaling".
--
-- v1.17: PICO2 strings -- the pipe is gone. In-game testing (Mhortai's
--   screenshot + a clean copy->paste->View of his own uncut string) proved
--   the CLIENT mangles raw "|" on editbox paste: pipes are doubled to "||"
--   to block escape injection, the display renders "||" back as "|" so both
--   boxes LOOK identical, and the checksum rightly fails. That broke the
--   copy-paste import of every multi-item string since v1.15 day one (only
--   "|" between gear sections triggers it; direct send never touches an
--   editbox and was immune). PICO2 uses "/" -- inert in the escape grammar
--   -- as the section separator; the parser accepts BOTH versions and gives
--   failed PICO1 checksums one "||"->"|" un-mangling retry, which recovers
--   old strings saved in Discord. Also: the direct-send name box got a real
--   border + placeholder (it was invisible when empty on the dark dialog),
--   and the share dialog's close button hitbox now sits on the visible X.
--
-- v1.18: the share dialog's X actually works now. The 1.17 hit-rect fix
--   treated the wrong cause and finished the job of killing the button: the
--   real culprit was the full-width mouse-enabled TITLE DRAG STRIP overlapping
--   the close button and eating its clicks -- the "offset hitbox" Mhortai
--   felt in 1.16 was merely the thin right-edge sliver the strip did not
--   cover, and 1.17's insets clipped away exactly that sliver. Fix: the drag
--   strip now ends well clear of the button, the button rides a higher frame
--   level so nothing mouse-enabled can sit on it again, and the insets are
--   gone -- the X behaves like every other WoW dialog's.
--
-- v1.19: share exactly the procs you mean. Every proc row grew a tickbox;
--   with NOTHING ticked, Share behaves as always (the full list), and with
--   any ticks, the built string -- copy-paste AND direct send, they are the
--   same string -- carries only the ticked procs (slots with no ticked proc
--   drop out entirely). The dialog says which mode it is in and offers
--   "Clear ticks"; the totals line counts ticks; ticks are session-only
--   intent, keyed by slot+spellId (NOT stored on the pooled row frames,
--   which recycle on every sort/filter), and gear changes prune ticks whose
--   proc no longer exists. The receiver sees a perfectly ordinary, shorter
--   list.
--
-- Originally by Mhortai (v1.13), shipped on Uncapped with realm-side fixes.
--
-- ⚠ It does NOT only listen. It sends two verbs -- ICINV (COST_HEAVY, 6 tokens)
--   and USPELLDMG (COST_MEDIUM, 2) -- into a per-player token bucket of 60 burst
--   / 6 per second that is SHARED with every other addon on the account
--   (src/server/game/Handlers/AddonThrottle.cpp). A verb the bucket cannot afford
--   is dropped: not answered, not queued, not retried.
--
-- v1.14 changes, all of them about that:
--   * removed the prefetch that queued every proc on every soulbound item and
--     re-sent the unanswered ones twice a second. At the measured worst case on
--     this realm (39 procs) that was 78 messages/second, 26x the budget, and it
--     fired at login and on every gear change with the window shut.
--   * damage is now fetched once, on hover, and never retried in a loop
--   * ICINV debounced to one per 10s
--   * the 810 KB of proc/drop tables moved to the PicoIDData LoadOnDemand addon
--   * stopped overwriting UncappedSoulForge's tooltip on its on-use buttons
--   * PicoIDExport no longer grows by 3 lines per Print, forever
--   * clicking a row no longer force-opens the chat box and steals WASD
------------------------------------------------------------------

local ADDON_NAME = "PicoID"

local DEFAULTS = {
    minimap    = true,
    minimapPos = 200,     -- angle (degrees) around the minimap
    fontSize   = 13,
    opacity    = 0.8,
    acceptShares = true,  -- v1.16: accept direct PICO shares from other players
}

local db  -- SavedVariables (PicoIDDB), set on ADDON_LOADED

--[[ ★★ THE TABLES LIVE IN A SEPARATE LoadOnDemand ADDON, AND THAT IS NOT TIDINESS.
  PicoID_ProcDB.lua (575 KB, 9,591 entries) and PicoID_DropDB.lua (235 KB, 5,332)
  used to be listed in PicoID.toc, so 810 KB of Lua source was parsed at EVERY
  login by EVERY player, including everyone who never opens the window. This realm
  has split three tables out for exactly this reason already -- UncappedTransmogData
  (797 KB), UncappedQuestData (628 KB) and UncappedLootFeedSources (490 KB).

  ⚠ PicoIDData MUST stay force-enabled in the launcher manifest. LoadAddOn() on a
    DISABLED addon returns nil, "DISABLED" -- it cannot be loaded at all -- so an
    unticked data addon means the proc and origin columns are permanently empty
    with no error. Every reader below nil-guards, so it degrades to "-" rather
    than throwing, which is precisely why it would go unreported.               ]]
local dataLoaded = false
local function EnsureData()
    if dataLoaded then return true end
    if PicoID_ProcDB then dataLoaded = true; return true end       -- already in memory
    if not IsAddOnLoaded("PicoIDData") then
        local ok, reason = LoadAddOn("PicoIDData")
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff2020PicoID|r: could not load PicoIDData ("
                .. tostring(reason) .. "). Proc names and origins will be blank -- "
                .. "re-tick PicoID Data in the AddOns list.")
            dataLoaded = true   -- warn once, not on every refresh
            return false
        end
    end
    dataLoaded = true
    return true
end

-- Prefer SchoolPop's database when both addons are installed (same data)
local function ProcDB()    EnsureData() return SchoolPop_ProcDB or PicoID_ProcDB end
local function AbilityDB() EnsureData() return SchoolPop_AbilityDB or PicoID_AbilityDB end
local function ManualDB()  EnsureData() return SchoolPop_ProcDB_Manual or PicoID_ProcDB_Manual end

--=================== UNCAPPED WIRE LISTENER ======================
-- The server sends imprinted (soulbound) procs to the Uncapped addon
-- over CHAT_MSG_ADDON, prefix "UNC":
--   ICITEM:E:<slot> | ICITEM:B:<bag>:<slot>   start of one item
--   ICIPROC:<spellId>:<trigger>:<chance>:<mag> a proc on that item
--   ICINVEND                                   end of the inventory
-- PicoID listens to the same stream and never sends anything.
local UNC_PREFIX = "UNC"
local boundStaging, boundCur = {}, nil
local boundByKey = {}
local boundProcInfo = {}
local boundReceived = false
local RefreshList  -- forward declaration

-- v1.19: share-selection ticks. Session-only intent, keyed "E:<slot>:<sid>"
-- -- NEVER stored on row frames, which are pooled and recycled on every
-- sort/filter/scroll and would shuffle the state. Empty table = share all.
local ticked = {}
local OnTicksChanged   -- set by the share dialog; called on any tick change
local function TickedCount()
    local n = 0
    for _ in pairs(ticked) do n = n + 1 end
    return n
end
local function ProcTotal()
    local n = 0
    for slot = 1, 19 do
        local procs = boundByKey["E:" .. slot]
        if procs then n = n + #procs end
    end
    return n
end
-- Gear changed: drop ticks whose slot no longer carries that proc, so a
-- swapped item cannot leave a phantom selection silently shrinking shares.
local function PruneTicks()
    local changed = false
    for key in pairs(ticked) do
        local slot, sid = string.match(key, "^E:(%d+):(%d+)$")
        local keep = false
        for _, p in ipairs(boundByKey["E:" .. (slot or "")] or {}) do
            if p.spellId == tonumber(sid) then keep = true break end
        end
        if not keep then ticked[key] = nil changed = true end
    end
    return changed
end

local function OnUncappedLine(body)
    local cmd, rest = string.match(body, "^(%u+):?(.*)$")
    if not cmd then return end
    if cmd == "ICITEM" then
        boundCur = rest
        boundStaging[rest] = boundStaging[rest] or {}
    elseif cmd == "ICIPROC" then
        local sid, tr, ch, mg = string.match(rest, "^(%d+):(%d+):(%d+):(%d+)")
        if not sid then sid = string.match(rest, "^(%d+)") end
        if sid and boundCur then
            table.insert(boundStaging[boundCur], { spellId = tonumber(sid),
                chance = tonumber(ch), mag = tonumber(mg) or 100, bases = {} })
        end
    elseif cmd == "ICIPROCBP" then
        local cur = boundCur and boundStaging[boundCur]
        local last = cur and cur[#cur]
        if last then
            local v = {}
            for n in string.gmatch(rest, "(%d+)") do v[#v + 1] = tonumber(n) end
            last.bases = v
        end
    elseif cmd == "ICIPROCFACT" then
        local sc, rs, sp, ap = string.match(rest, "^(%d+):(%d+):(%d+):(%d+)$")
        local cur = boundCur and boundStaging[boundCur]
        local last = cur and cur[#cur]
        if last and sc then
            last.stackCap = tonumber(sc) or 0
            last.rankScales = (tonumber(rs) or 0) == 1
            last.spPct = tonumber(sp) or 0
            last.apPct = tonumber(ap) or 0
        end
    elseif cmd == "ICIPROCSRC" then
        -- <itemEntry> -- the sole item carrying the ICIPROC just before it.
        -- Only sent when unambiguous (multi-source procs never get this line).
        -- v1.15: PicoID ignored this verb until now; it feeds the origin icon.
        local e = string.match(rest, "^(%d+)$")
        local cur = boundCur and boundStaging[boundCur]
        local last = cur and cur[#cur]
        if last and e then last.srcItem = tonumber(e) end
    elseif cmd == "ICINVEND" then
        boundByKey = boundStaging
        boundProcInfo = {}
        for _, procs in pairs(boundByKey) do
            for _, p in ipairs(procs) do boundProcInfo[p.spellId] = p end
        end
        boundStaging, boundCur = {}, nil
        boundReceived = true
        if PruneTicks() and OnTicksChanged then OnTicksChanged() end
        if RefreshList then RefreshList() end
        -- ⚠ NO PREFETCH HERE. This branch runs whenever the server pushes the
        -- soulbound stream, which UncappedSoulForge does 2s after PLAYER_LOGIN and
        -- 0.3s after EVERY equipment change -- with the PicoID window closed and
        -- possibly never opened. Firing a per-proc burst from here landed it on
        -- the same bucket as the 28-token zone-in. Damage is fetched on hover.
    end
end

--====================== ORIGIN RESOLUTION ========================
local function Commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function PickSource(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return nil end
    if #value == 1 then return value[1] end
    local shown = {}
    for i = 1, math.min(3, #value) do shown[i] = value[i] end
    local s = table.concat(shown, " / ")
    if #value > 3 then s = s .. " / ..." end
    return s
end

local function OriginOf(spellId)
    local m = ManualDB()
    if m and m[spellId] then return PickSource(m[spellId]) end
    local a = AbilityDB()
    if a and a[spellId] then return a[spellId] .. " (ability)" end
    local p = ProcDB()
    if p and p[spellId] then return PickSource(p[spellId]) end
    return "-"
end

--========================= THE WINDOW ============================
local frame = CreateFrame("Frame", "PicoIDFrame", UIParent)
frame:SetWidth(560)
frame:SetHeight(300)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
frame:SetMovable(true)
frame:SetResizable(true)
frame:SetMinResize(360, 140)
frame:SetMaxResize(1000, 700)
do local w, h = UIParent:GetWidth(), UIParent:GetHeight()
   if w and h then frame:SetMaxResize(math.min(1000, w - 20), math.min(700, h - 20)) end end
frame:SetClampedToScreen(true)
frame:SetFrameStrata("MEDIUM")
frame:EnableMouse(true)
frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
frame:Hide()
tinsert(UISpecialFrames, "PicoIDFrame")  -- Esc closes it

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -6)
-- v1.15: shortened -- a fourth top-bar button (Share) was added and the long
-- title overlapped it at narrower window widths.
title:SetText("PicoID - imprinted procs")

-- Real columns: header row + pooled row-frames in a scroll frame.
local COLS = {
    { title = "Item",           w = 0.26 },
    { title = "Imprinted proc", w = 0.20 },
    { title = "Proc ID",        w = 0.09 },
    { title = "Item of origin", w = 0.25 },
    { title = "Dropped by",     w = 0.20 },
}

local function DropText(spellId)
    EnsureData()
    local d = PicoID_DropDB and PicoID_DropDB[spellId]
    if not d then return "-" end
    return table.concat(d, ", ")
end

--[[ ★★★ ONE ASK PER PROC, ON HOVER, NEVER RETRIED IN A LOOP.
  What was here before: a prefetch that queued EVERY proc on EVERY soulbound item
  (bags included, not just the 19 worn slots) and an OnUpdate that re-sent every
  unanswered one twice a second.

  USPELLDMG costs 2 tokens against a 60-burst / 6-per-second bucket
  (src/server/game/Handlers/AddonThrottle.cpp), so the sustainable rate is three
  per second. With N procs the old code demanded 4N tokens/second: break-even was
  N <= 1.5, and 86% of imprint owners on this realm are at N >= 2. The measured
  worst case is N = 39 -- 78 messages/second, 26x the budget, and the FIRST tick
  alone overdraws the whole bucket. Everything else the account sends is then
  dropped too, which is how one addon produces four unrelated-looking bug reports.

  Worse, the "stops after ~10s" bound could never fire: RequestSpellDamage reset
  dmgTries unconditionally, and the item primer calls RefreshList (and therefore
  the prefetch) on roughly half of all frames for three seconds after every open.

  The shipped Uncapped64bitUI does this correctly and this now matches it: ask
  once, only for the proc actually being hovered, and fail silently. A dropped
  answer is retried by the player hovering again -- which is a hardware event, is
  self-limiting, and cannot storm.                                             ]]
local spellDmg  = {}      -- spellId -> {min, max} once the server answers
local dmgAsked  = {}      -- spellId -> true while one ask is outstanding
local DMG_TIMEOUT = 6

local function RequestSpellDamage(spellId)
    if not spellId or spellDmg[spellId] or dmgAsked[spellId] then return end
    dmgAsked[spellId] = true
    SendAddonMessage("REAGENTBANK", "USPELLDMG:" .. spellId, "WHISPER", UnitName("player"))
    -- A plain timeout, because the ask can be dropped and then nothing ever
    -- arrives. Clearing the flag lets a later deliberate hover try once more;
    -- it does NOT re-send on its own.
    local f = CreateFrame("Frame")
    local left = DMG_TIMEOUT
    f:SetScript("OnUpdate", function(self, dt)
        left = left - dt
        if left > 0 then return end
        self:SetScript("OnUpdate", nil)
        if not spellDmg[spellId] then dmgAsked[spellId] = nil end
    end)
end
local function AbbrevNum(n)
    n = tonumber(n) or 0
    local scale, suffix
    if     n >= 1e18 then scale, suffix = 1e18, "Qi"
    elseif n >= 1e15 then scale, suffix = 1e15, "Qa"
    elseif n >= 1e12 then scale, suffix = 1e12, "T"
    elseif n >= 1e9  then scale, suffix = 1e9,  "B"
    elseif n >= 1e6  then scale, suffix = 1e6,  "M"
    elseif n >= 1e3  then scale, suffix = 1e3,  "K"
    else return string.format("%d", math.floor(n)) end
    local whole = math.floor(n / scale)
    local frac  = math.floor(n / (scale / 100)) % 100
    if frac > 0 then return string.format("%d.%02d%s", whole, frac, suffix) end
    return string.format("%d%s", whole, suffix)
end

--=========== SPELL EFFECT BODY (extraction-window style) =========
--[[ v1.15: the hover tooltip shows the proc's full effect -- damage AND
  healing -- at its imprinted soulforge magnitude, exactly the way the
  Dashboard's extraction window previews a proc. There is no healing verb on
  the wire: the extraction window builds its numbers CLIENT-SIDE, reading the
  spell's stock description and rewriting every server-sent base value (the
  ICIPROCBP list, which PicoID already receives) as base x magnitude
  (UncappedSoulForge.lua, scaleDescription). This is a faithful port.

  ⚠ ON THE "NO TOOLTIP SCRAPING" RULE (PicoID_CONSTRAINTS.md): PicoID v1.8
  removed a hidden scanning tooltip because that implementation disturbed the
  imprint/vestige lines other addons draw on ITEM tooltips. This is NOT that.
  It is a verbatim copy of the realm's own shipped pattern (UncappedSoulForge's
  descScan): a DEDICATED, named, hidden GameTooltip, ANCHOR_NONE, that only
  ever reads "spell:<id>" hyperlinks, hooks nothing, and never touches
  GameTooltip or any item tooltip. It reads the client's own DBC text; it
  cannot repaint or disturb anything.                                        ]]
local descScan = CreateFrame("GameTooltip", "PicoIDDescScan", UIParent,
    "GameTooltipTemplate")
descScan:SetOwner(UIParent, "ANCHOR_NONE")
local descCache = {}

local function SpellDescription(spellId)
    if descCache[spellId] ~= nil then
        if descCache[spellId] == false then return nil end
        return descCache[spellId]
    end
    descScan:SetOwner(UIParent, "ANCHOR_NONE")
    descScan:ClearLines()
    local ok = pcall(function() descScan:SetHyperlink("spell:" .. spellId) end)
    local desc
    if ok then
        -- The description is the last non-empty left line; earlier lines are
        -- the name, rank, cast time, range, cooldown and so on.
        for i = descScan:NumLines(), 2, -1 do
            local fs = _G["PicoIDDescScanTextLeft" .. i]
            local txt = fs and fs:GetText()
            if txt and string.match(txt, "%S") then
                desc = txt
                break
            end
        end
    end
    descCache[spellId] = desc or false
    return desc
end

-- SoulForge's scaleDescription with our AbbrevNum: rewrite each base value
-- found in the text as base x magnitude. Returns nil when nothing matched
-- (printing stock numbers next to a big multiplier would read as a bug).
local function ScaleDescription(desc, bases, mult)
    if not desc then return nil end
    if mult == 1 then return desc end
    local seen, ordered = {}, {}
    for _, b in ipairs(bases or {}) do
        if b and b > 0 and not seen[b] then
            seen[b] = true
            ordered[#ordered + 1] = b
        end
    end
    if #ordered == 0 then return nil end
    table.sort(ordered, function(a, b) return a > b end)
    local out, hit = desc, false
    for _, b in ipairs(ordered) do
        local scaled = AbbrevNum(b * mult)
        -- Frontier-bounded so 500 can't match inside 1500.
        local pattern = "%f[%d]" .. string.format("%d", b) .. "%f[%D]"
        local replaced, n = string.gsub(out, pattern,
            (string.gsub(scaled, "%%", "%%%%")))
        if n > 0 then out, hit = replaced, true end
    end
    if hit then return out end
    return nil
end

-- What the server LISTS as moving this proc's numbers, from ICIPROCFACT
-- (<stackCap>:<rankScales>:<spPct>:<apPct>).
-- ⚠ v1.16 RELABEL (admin clarification, 2026-09-11): the SP/AP percentages
--   are rounded MAXIMA of explicit spell_bonus_data rows, collected across
--   the proc and its trigger descendants to depth 2. They are NOT complete
--   effective coefficients: DBC fallback coefficients, handler overrides and
--   player-specific modifiers are not represented, forge potency is excluded,
--   and the SP and AP maxima can come from DIFFERENT sub-effects. A value of
--   ZERO only means "no explicit bonus-data row" -- it does NOT establish
--   that nothing scales the spell. So zeros are HIDDEN here; the old wording
--   ("nothing else scales it either") asserted exactly what a zero cannot
--   support and must not come back.
local function ScalingNote(p)
    if not p or p.rankScales == nil then return nil end   -- older server
    local from = {}
    if p.spPct and p.spPct > 0 then
        from[#from + 1] = string.format("up to %d%% of spell power", p.spPct)
    end
    if p.apPct and p.apPct > 0 then
        from[#from + 1] = string.format("up to %d%% of attack power", p.apPct)
    end
    local rank = p.rankScales and "Ranks raise this." or "Ranks do not raise this."
    if #from > 0 then
        return rank .. " Server-listed scaling: " .. table.concat(from, " and ")
            .. " (explicit data - actual scaling can differ)."
    end
    return rank
end

local function ShowProcTooltip(anchor, spellId)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine(GetSpellInfo(spellId) or "Proc", 1, 0.82, 0)
    local p = boundProcInfo[spellId]
    local dmg = spellDmg[spellId]
    if dmg then
        if dmg[2] and dmg[2] > dmg[1] then
            GameTooltip:AddLine("Approx. " .. AbbrevNum(dmg[1]) .. " - " .. AbbrevNum(dmg[2])
                .. " with your stats", 1, 0.82, 0)
        else
            GameTooltip:AddLine("Approx. " .. AbbrevNum(dmg[1]) .. " with your stats", 1, 0.82, 0)
        end
    else
        RequestSpellDamage(spellId)
        GameTooltip:AddLine("Calculating with your stats...", 0.6, 0.6, 0.6)
    end
    if p then
        if p.chance and p.chance > 0 then GameTooltip:AddLine(string.format("Proc chance: %d%%", p.chance), 0.7, 0.7, 0.7) end
        if p.stackCap and p.stackCap > 1 then GameTooltip:AddLine("Stacks up to " .. p.stackCap, 0.7, 0.7, 0.7) end
        -- v1.15: the effect body, extraction-window style -- the spell's own
        -- description with its numbers rewritten to this bound copy's
        -- magnitude. Covers damage AND healing (and hybrids show both),
        -- because the whole sentence is rewritten, not just damage figures.
        local mult = (p.mag or 100) / 100
        local desc = SpellDescription(spellId)
        local body = ScaleDescription(desc, p.bases, mult)
        if not body and desc and mult == 1 then body = desc end
        if body then
            GameTooltip:AddLine(body, 0.62, 0.62, 0.72, 1)   -- 1 = wrap
        end
        -- v1.15: the scaling coefficients (from ICIPROCFACT).
        local note = ScalingNote(p)
        if note then
            GameTooltip:AddLine(note, 0.55, 0.62, 0.55, 1)
        end
    end
    GameTooltip:Show()
end
local ROW_H = 17

local scroll = CreateFrame("ScrollFrame", "PicoIDScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 8, -44)
scroll:SetPoint("BOTTOMRIGHT", -30, 40)

local content = CreateFrame("Frame", nil, scroll)
content:SetWidth(1)
content:SetHeight(1)
scroll:SetScrollChild(content)

-- v1.15: headers are buttons -- click to sort by that column (asc), click
-- again to reverse, a third time to restore gear order.
local sortCol, sortDesc = nil, false
local header = {}
for c = 1, #COLS do
    local btn = CreateFrame("Button", nil, frame)
    btn:SetHeight(14)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetAllPoints()
    fs:SetJustifyH("LEFT")
    fs:SetText(COLS[c].title)
    btn.fs = fs
    btn:SetScript("OnClick", function()
        if sortCol ~= c then
            sortCol, sortDesc = c, false
        elseif not sortDesc then
            sortDesc = true
        else
            sortCol, sortDesc = nil, false   -- back to gear order
        end
        for i = 1, #COLS do
            local suffix = ""
            if sortCol == i then suffix = sortDesc and "  v" or "  ^" end
            header[i].fs:SetText(COLS[i].title .. suffix)
        end
        if RefreshList then RefreshList() end
    end)
    header[c] = btn
end
local headerLine = frame:CreateTexture(nil, "ARTWORK")
headerLine:SetTexture(1, 0.82, 0)
headerLine:SetHeight(1)
headerLine:SetAlpha(0.5)

local rowPool = {}
local usedRows = 0
local function AcquireRow(index)
    local row = rowPool[index]
    if not row then
        row = CreateFrame("Button", nil, content)
        row.picoRow = true      -- our tag; see the USPELLDMGR tooltip repaint
        row:SetHeight(ROW_H)
        row:EnableMouse(true)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.06)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture(0, 0, 0, 0)
        row:SetScript("OnEnter", function(self)
            if self.spellId then ShowProcTooltip(self, self.spellId) end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            if not self.spellId then return end
            -- v1.15: Shift-click inserts just the bare ID.
            local text
            if IsShiftKeyDown() then
                text = tostring(self.spellId)
            else
                local pname = GetSpellInfo(self.spellId) or "Proc"
                text = "[" .. pname .. "] (" .. self.spellId .. ")"
            end
            local edit = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                or ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend()
            -- ⚠ Only insert into a chat box the player already has open. Forcing
            -- one open steals keyboard focus, so the next WASD press walks into
            -- the edit box instead of the character.
            if edit and edit:IsShown() then
                edit:Insert(text)
                edit:SetFocus()
            end
        end)
        row.cells = {}
        for c = 1, #COLS do
            local fs = row:CreateFontString(nil, "OVERLAY")
            fs:SetFont("Fonts\\ARIALN.TTF", db and db.fontSize or 13, "")
            fs:SetJustifyH("LEFT")
            fs:SetHeight(ROW_H)
            row.cells[c] = fs
        end
        -- v1.15: icons at the left of the Item (1), proc (2) and origin (4)
        -- cells. Layout() indents those cells' text past the icon slot.
        row.icons = {}
        for _, c in ipairs({ 1, 2, 4 }) do
            local tex = row:CreateTexture(nil, "ARTWORK")
            tex:SetWidth(14)
            tex:SetHeight(14)
            tex:Hide()
            row.icons[c] = tex
        end
        -- v1.19: the share tickbox. State lives in `ticked` by key; the
        -- checkbox is a dumb view of it, refreshed on every AddRow.
        local tick = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        tick:SetWidth(16)
        tick:SetHeight(16)
        tick:SetPoint("LEFT", row, "LEFT", 0, 0)
        tick:SetScript("OnClick", function(self)
            local r = self:GetParent()
            if not r.tickKey then return end
            if ticked[r.tickKey] then ticked[r.tickKey] = nil
            else ticked[r.tickKey] = true end
            RefreshList()
            if OnTicksChanged then OnTicksChanged() end
        end)
        tick:Hide()
        row.tick = tick
        rowPool[index] = row
    end
    return row
end

-- totals line (left) and duplicate warning (right of it)
local totals = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
totals:SetPoint("BOTTOMLEFT", 10, 6)
totals:SetJustifyH("LEFT")

local warning = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
warning:SetPoint("LEFT", totals, "RIGHT", 12, 0)
warning:SetJustifyH("LEFT")
warning:SetTextColor(1, 0.3, 0.3)
warning:Hide()

-- v1.15: filter box (bottom-right, left of the resize grip). Typing narrows
-- the list live; matches any column, case-insensitive. Purely local.
local filterEdit = CreateFrame("EditBox", "PicoIDFilterBox", frame)
filterEdit:SetPoint("BOTTOMRIGHT", -22, 4)
filterEdit:SetWidth(110)
filterEdit:SetHeight(16)
filterEdit:SetAutoFocus(false)
filterEdit:SetMaxLetters(60)
filterEdit:SetFontObject(ChatFontNormal)
filterEdit:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
end)
local filterBg = filterEdit:CreateTexture(nil, "BACKGROUND")
filterBg:SetAllPoints()
filterBg:SetTexture(1, 1, 1, 0.08)
local filterHint = filterEdit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
filterHint:SetPoint("LEFT", 2, 0)
filterHint:SetText("filter...")
filterEdit:SetScript("OnTextChanged", function(self)
    if (self:GetText() or "") == "" then filterHint:Show() else filterHint:Hide() end
    if RefreshList then RefreshList() end
end)
warning:SetPoint("RIGHT", filterEdit, "LEFT", -8, 0)

local TICK_W = 18   -- v1.19: fixed left slot for the share tickbox
local function Layout()
    local width = scroll:GetWidth()
    if not width or width < 50 then return end
    content:SetWidth(width)
    local x = TICK_W
    for c, col in ipairs(COLS) do
        local w = math.floor((width - TICK_W) * col.w) - 6
        header[c]:ClearAllPoints()
        header[c]:SetPoint("TOPLEFT", frame, "TOPLEFT", 8 + x, -28)
        header[c]:SetWidth(w)
        local hasIcon = (c == 1 or c == 2 or c == 4)
        for i = 1, usedRows do
            local row = rowPool[i]
            local fs = row.cells[c]
            fs:ClearAllPoints()
            if hasIcon and row.icons and row.icons[c] then
                -- v1.15: a fixed 17px icon slot for every row keeps the text
                -- column-aligned whether or not this row's icon resolved.
                row.icons[c]:ClearAllPoints()
                row.icons[c]:SetPoint("LEFT", row, "LEFT", x + 1, 0)
                fs:SetPoint("LEFT", row, "LEFT", x + 17, 0)
                fs:SetWidth(math.max(10, w - 17))
            else
                fs:SetPoint("LEFT", row, "LEFT", x, 0)
                fs:SetWidth(w)
            end
        end
        x = x + math.floor((width - TICK_W) * col.w)
    end
    headerLine:ClearAllPoints()
    headerLine:SetPoint("TOPLEFT", 8, -42)
    headerLine:SetPoint("TOPRIGHT", -30, -42)
end
frame:SetScript("OnSizeChanged", function() Layout() end)

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 3, 3)
close:SetWidth(24)
close:SetHeight(24)

local grip = CreateFrame("Button", nil, frame)
grip:SetWidth(16)
grip:SetHeight(16)
grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

local rows = {}  -- plain-text rows for Print

local function ApplyLook()
    for _, row in ipairs(rowPool) do
        for _, fs in ipairs(row.cells) do
            fs:SetFont("Fonts\\ARIALN.TTF", db.fontSize, "")
        end
    end
    frame:SetBackdropColor(0, 0, 0, db.opacity)
end


-- On 3.3.5a GetItemInfo returns nil until the item is cached; prime the cache
-- for every equipped item and re-render as names resolve, so the list fills in
-- quickly on the first open instead of showing "slot N".
local PicoID_itemPrimer = CreateFrame("Frame")
PicoID_itemPrimer:Hide()
local primerElapsed, primerRepaint = 0, 0
PicoID_itemPrimer:SetScript("OnUpdate", function(self, dt)
    primerElapsed = primerElapsed + dt
    local allKnown = true
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link and not GetItemInfo(link) then allKnown = false end
    end
    -- v1.15: origin icons come from ICIPROCSRC item ids, which may not be in
    -- the local cache yet; asking GetItemInfo here is what requests them.
    for _, procs in pairs(boundByKey) do
        for _, p in ipairs(procs) do
            if p.srcItem and p.srcItem > 0 and not GetItemInfo(p.srcItem) then
                allKnown = false
            end
        end
    end
    if allKnown or primerElapsed > 3 then
        self:Hide(); primerElapsed = 0; primerRepaint = 0
        RefreshList()   -- final re-render with everything cached
    else
        -- ⚠ An accumulator, not a frame-parity test. `floor(elapsed*5) % 2 == 0`
        -- is true on roughly half of ALL frames, so this relaid out every row on
        -- ~90 frames of the 3-second window. This realm already has a measured
        -- FPS problem caused by action-bar repaint storms; four repaints a second
        -- is plenty for items trickling out of the cache.
        primerRepaint = primerRepaint + dt
        if primerRepaint >= 0.25 then
            primerRepaint = 0
            RefreshList()
        end
    end
end)

RefreshList = function()
    if not frame:IsShown() then return end
    rows = {}
    local n = 0
    -- v1.15: resolve and place the three row icons. Any icon that cannot be
    -- resolved yet (uncached item, message row) simply stays hidden; the item
    -- primer's re-renders fill them in as the cache answers.
    local function SetRowIcons(row, cols)
        if not row.icons then return end
        local t = cols.slot and GetInventoryItemTexture
            and GetInventoryItemTexture("player", cols.slot) or nil
        if t then row.icons[1]:SetTexture(t); row.icons[1]:Show()
        else row.icons[1]:Hide() end
        local pt = cols.spellId and select(3, GetSpellInfo(cols.spellId)) or nil
        if pt then row.icons[2]:SetTexture(pt); row.icons[2]:Show()
        else row.icons[2]:Hide() end
        local ot
        if cols.srcItem and cols.srcItem > 0 then
            ot = select(10, GetItemInfo(cols.srcItem))
        end
        if ot then row.icons[4]:SetTexture(ot); row.icons[4]:Show()
        else row.icons[4]:Hide() end
    end
    local function AddRow(cols, r, g, b, idWhite)
        n = n + 1
        local row = AcquireRow(n)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(n - 1) * ROW_H)
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        for c = 1, #COLS do
            row.cells[c]:SetText(cols[c] or "")
            if c == 3 and idWhite then
                row.cells[c]:SetTextColor(1, 1, 1)
            else
                row.cells[c]:SetTextColor(r, g, b)
            end
        end
        row.spellId = cols.spellId
        -- v1.19: bind the tickbox. Only real proc rows get one; message and
        -- proc-less rows hide it.
        if cols.spellId and cols.slot then
            row.tickKey = "E:" .. cols.slot .. ":" .. cols.spellId
            row.tick:SetChecked(ticked[row.tickKey] and true or false)
            row.tick:Show()
        else
            row.tickKey = nil
            row.tick:Hide()
        end
        SetRowIcons(row, cols)
        if cols.dup then row.bg:SetTexture(1, 0, 0, 0.18) else row.bg:SetTexture(0, 0, 0, 0) end
        row:Show()
        rows[#rows + 1] = table.concat({ cols[1] or "", cols[2] or "",
            cols[3] or "", cols[4] or "", cols[5] or "" }, "  -  ")
    end

    local itemCount, procCount, dupProcs = 0, 0, 0
    if not boundReceived then
        -- ⚠ This used to say "(is Uncapped loaded?)" unconditionally, which names
        -- the wrong cause in the common case. The usual reason nothing arrived is
        -- that the request was DROPPED by the server's addon throttle -- the exact
        -- misdiagnosis that produced four separate bug reports about four features
        -- that were all one thing. Ask UncappedThrottle, which knows.
        local UT = _G.UncappedThrottle
        if UT and UT.IsThrottled and UT.IsThrottled() then
            AddRow({ (UT.StatusText and UT.StatusText())
                     or "The server is busy and dropped the request. Reopen this window shortly." },
                1, 0.82, 0)
        else
            AddRow({ "No imprint data received from the server yet (is Uncapped loaded?)" },
                1, 0.5, 0.5)
        end
        totals:SetText("")
    else
        local count = {}
        for slot = 1, 19 do
            for _, p in ipairs(boundByKey["E:" .. slot] or {}) do
                count[p.spellId] = (count[p.spellId] or 0) + 1
            end
        end
        for sid, c in pairs(count) do
            procCount = procCount + c
            if c > 1 then dupProcs = dupProcs + 1 end
        end
        -- v1.15: collect everything first (so it can be filtered and sorted),
        -- render after. Totals always describe the FULL gear set; the filter
        -- only narrows what is displayed.
        local duplicates = false
        local entries = {}
        for slot = 1, 19 do
            local link = GetInventoryItemLink("player", slot)
            if link then
                itemCount = itemCount + 1
                local name = GetItemInfo(link) or ("slot " .. slot)
                local procs = boundByKey["E:" .. slot]
                if procs and #procs > 0 then
                    for _, p in ipairs(procs) do
                        local sid = p.spellId
                        local pname = GetSpellInfo(sid) or "?"
                        local dup = (count[sid] or 0) > 1
                        if dup then duplicates = true end
                        entries[#entries + 1] = { name, pname, tostring(sid),
                            OriginOf(sid), DropText(sid), spellId = sid, dup = dup,
                            slot = slot, srcItem = p.srcItem }
                    end
                else
                    entries[#entries + 1] = { name, "-", "-", "-", "-",
                        noproc = true, slot = slot }
                end
            end
        end

        local ft = string.lower(filterEdit:GetText() or "")
        if ft ~= "" then
            local kept = {}
            for _, e in ipairs(entries) do
                for c = 1, #COLS do
                    if string.find(string.lower(e[c] or ""), ft, 1, true) then
                        kept[#kept + 1] = e
                        break
                    end
                end
            end
            entries = kept
        end

        if sortCol then
            local col, desc = sortCol, sortDesc
            table.sort(entries, function(a, b)
                -- proc-less "-" rows always sink to the bottom
                if a.noproc ~= b.noproc then return b.noproc end
                local av, bv
                if col == 3 then
                    av, bv = a.spellId or 0, b.spellId or 0
                else
                    av, bv = string.lower(a[col] or ""), string.lower(b[col] or "")
                end
                if av == bv then return (a.spellId or 0) < (b.spellId or 0) end
                if desc then return av > bv end
                return av < bv
            end)
        end

        for _, e in ipairs(entries) do
            if e.noproc then
                AddRow(e, 0.6, 0.6, 0.6, false)
            elseif e.dup then
                AddRow(e, 1, 0.25, 0.25, false)
            else
                AddRow(e, 0.75, 0.55, 1, true)
            end
        end
        if ft ~= "" and #entries == 0 then
            AddRow({ "Nothing matches \"" .. filterEdit:GetText() .. "\"" }, 0.6, 0.6, 0.6)
        end

        local sel = TickedCount()
        totals:SetText(string.format("|cffffd100%d|r items   |cffffd100%d|r procs%s%s",
            itemCount, procCount,
            dupProcs > 0 and ("   |cffff4040" .. dupProcs .. " duplicated|r") or "",
            sel > 0 and ("   |cff80ffff" .. sel .. " ticked for Share|r") or ""))
        if duplicates then
            warning:SetText("Duplicate procs (red) fire only once, no matter how many items carry them.")
            warning:Show()
        else
            warning:Hide()
        end
    end

    for i = n + 1, usedRows do rowPool[i]:Hide() end
    usedRows = n
    content:SetHeight(math.max(1, n * ROW_H))
    Layout()
end

--========================== EXPORT ===============================
-- Addons cannot write files; Print opens a window with the list as
-- plain text pre-selected (Ctrl+C), and stores it in the PicoIDExport
-- saved variable, written to WTF\...\SavedVariables on logout/reload.
local exportFrame = CreateFrame("Frame", "PicoIDExportFrame", UIParent)
exportFrame:SetWidth(540)
exportFrame:SetHeight(380)
exportFrame:SetPoint("CENTER")
exportFrame:SetFrameStrata("DIALOG")
exportFrame:SetMovable(true)
exportFrame:EnableMouse(true)
exportFrame:SetClampedToScreen(true)
exportFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
exportFrame:Hide()
tinsert(UISpecialFrames, "PicoIDExportFrame")

local exportTitle = CreateFrame("Frame", nil, exportFrame)
exportTitle:SetPoint("TOPLEFT", 12, -12)
exportTitle:SetPoint("TOPRIGHT", -12, -12)
exportTitle:SetHeight(20)
exportTitle:EnableMouse(true)
exportTitle:RegisterForDrag("LeftButton")
exportTitle:SetScript("OnDragStart", function() exportFrame:StartMoving() end)
exportTitle:SetScript("OnDragStop", function() exportFrame:StopMovingOrSizing() end)
local exportTitleText = exportTitle:CreateFontString(nil, "OVERLAY", "GameFontNormal")
exportTitleText:SetPoint("CENTER")
exportTitleText:SetText("PicoID Export")

local exportHint = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
exportHint:SetPoint("BOTTOM", 0, 20)
exportHint:SetText("Text is selected: press Ctrl+C, then paste into Word or Notepad.")

local exportScroll = CreateFrame("ScrollFrame", "PicoIDExportScroll", exportFrame,
    "UIPanelScrollFrameTemplate")
exportScroll:SetPoint("TOPLEFT", 16, -36)
exportScroll:SetPoint("BOTTOMRIGHT", -36, 40)

local exportEdit = CreateFrame("EditBox", nil, exportScroll)
exportEdit:SetMultiLine(true)
exportEdit:SetAutoFocus(false)
exportEdit:SetMaxLetters(0)
exportEdit:SetFontObject(ChatFontNormal)
exportEdit:SetWidth(480)
exportEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
exportScroll:SetScrollChild(exportEdit)

local exportClose = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
exportClose:SetPoint("TOPRIGHT", -6, -6)

local function DoPrint()
    local out = { "Item  -  Imprinted proc  -  Proc ID  -  Item of origin" }
    for _, r in ipairs(rows) do out[#out + 1] = r end
    if warning:IsShown() then
        out[#out + 1] = ""
        out[#out + 1] = warning:GetText()
    end
    -- ⚠ `rows = out` was here, and it fed the output back into the source list.
    -- Every Print added another header, another blank and another warning line to
    -- the SAME table -- +3 rows per click, saved to SavedVariables each time, so
    -- PicoIDExport grew without bound for the life of the character. `out` is a
    -- local render of `rows`; it must never be written back over it.
    local text = table.concat(out, "\n")
    if text == "" then text = "(nothing to export)" end
    exportEdit:SetText(text)
    exportFrame:Show()
    exportEdit:SetFocus()
    exportEdit:HighlightText()
    PicoIDExport = PicoIDExport or {}
    PicoIDExport.exportedAt = date("%Y-%m-%d %H:%M:%S")
    PicoIDExport.lines = { unpack(out) }
end

--======================== PICO SHARE STRINGS =====================
--[[ Share your imprinted procs with another PicoID user the way talent
  strings are shared. The string carries ONLY numbers -- equipment slot,
  itemId, spellId and proc chance -- because both ends have PicoIDData
  installed: names, origins and drop sources are rebuilt on the receiving
  side from that player's own local tables. A worst-case gear set (39 procs)
  is a few hundred characters, not kilobytes.

  ⚠ EVERYTHING HERE IS OFFLINE. Building, copying, pasting and viewing a
  string sends NOTHING on the addon pipe -- no SendAddonMessage, no new verb,
  zero tokens against the AddonThrottle bucket. The string travels as text
  the PLAYER pastes wherever they like (Discord, forum, an in-game chat
  line). Direct addon-to-addon delivery on the "PICO" prefix was approved
  by the server owner and shipped in v1.16 -- see the DIRECT SHARING section
  below. THIS copy-paste path stays exactly as it was and remains the
  size-unlimited fallback for gear sets over the direct-send byte cap.

  Format (the version tag did its job -- PICO2 exists precisely because
  PICO1 could change nothing else):
    PICO2:<player>:<slot>=<itemId>=<sid>[.<chance>][,<sid>...]/<slot>=...!<sum>
  The trailing !<sum> is a position-weighted checksum of everything between
  the "PICOn:" tag and "!". It exists because in-game chat truncates at 255
  characters -- a cut or mangled paste is detected and named, instead of
  silently showing half a gear set.

  ⚠ WHY "/" AND NOT "|" (v1.17): the WoW client DOUBLES raw pipes to "||"
  when text is PASTED into an editbox (anti escape-injection), and renders
  "||" back as a single "|" -- so a pasted PICO1 string looked untouched
  while its bytes had changed, and the checksum correctly refused it. Every
  multi-item PICO1 string failed import this way since v1.15. "/" is inert
  in the escape grammar, like every other character the format uses. The
  parser still accepts PICO1: valid ones (files, addons passing strings in
  code) parse as before, and a failed PICO1 checksum gets exactly one
  "||"->"|" un-mangling retry -- which recovers old strings players saved
  in Discord and paste in through the mangling client.                     ]]

local function ShareChecksum(s)
    local sum = 0
    for i = 1, #s do
        sum = (sum + string.byte(s, i) * i) % 99991
    end
    return sum
end

local function BuildShareString()
    if not boundReceived then return nil end
    -- v1.19: with any ticks set, only ticked procs ride the string; a slot
    -- whose procs are all unticked drops out entirely. No ticks = full list,
    -- exactly the pre-1.19 behavior. Direct send uses this same function, so
    -- both paths always agree on what "Share" means right now.
    local anySel = TickedCount() > 0
    local sections = {}
    for slot = 1, 19 do
        local procs = boundByKey["E:" .. slot]
        if procs and #procs > 0 then
            local link = GetInventoryItemLink("player", slot)
            local itemId = (link and tonumber(string.match(link, "item:(%d+)"))) or 0
            local parts = {}
            for _, p in ipairs(procs) do
              if (not anySel) or ticked["E:" .. slot .. ":" .. p.spellId] then
                -- <sid>[.<chance>][.<srcItem>]; a src with no chance keeps the
                -- empty middle field (<sid>..<src>) so positions stay fixed.
                local part = tostring(p.spellId)
                local ch  = (p.chance and p.chance > 0) and tostring(p.chance) or ""
                local src = (p.srcItem and p.srcItem > 0) and tostring(p.srcItem) or ""
                if src ~= "" then
                    part = part .. "." .. ch .. "." .. src
                elseif ch ~= "" then
                    part = part .. "." .. ch
                end
                parts[#parts + 1] = part
              end
            end
            if #parts > 0 then
                sections[#sections + 1] = slot .. "=" .. itemId .. "=" .. table.concat(parts, ",")
            end
        end
    end
    if #sections == 0 then return nil end
    local payload = (UnitName("player") or "?") .. ":" .. table.concat(sections, "/")
    return "PICO2:" .. payload .. "!" .. ShareChecksum(payload)
end

-- Returns a table { name, items = { {slot, itemId, procs={{spellId,chance}}} } }
-- or nil plus a human-readable reason. Forgiving about surrounding junk
-- (leading spaces, a whole pasted chat line) but strict about the payload.
local function ParseShareString(text)
    local raw = string.match(text or "", "PICO[12]:%S+")
    if not raw then
        return nil, "No PICO string found in the pasted text."
    end
    -- v1.16: overall ceiling. A worst-case legitimate set is well under 1 KB;
    -- anything bigger is not a PICO string and is not worth walking.
    if #raw > 2000 then
        return nil, "That is too long to be a PICO string."
    end
    local ver, payload, sumStr = string.match(raw, "^PICO([12]):(.*)!(%d+)$")
    if not payload then
        return nil, "The string is incomplete - its end is missing. In-game chat cuts at 255 characters; get the full string (Discord keeps it in one piece)."
    end
    if ShareChecksum(payload) ~= tonumber(sumStr) then
        -- v1.17: one un-mangling retry for PICO1. The client doubles raw
        -- pipes to "||" on editbox PASTE (and renders them back as "|", so
        -- the box looks untouched). Undo exactly that and re-check; any
        -- other damage still fails and is named below.
        local rescued
        if ver == "1" then
            rescued = string.gsub(payload, "||", "|")
        end
        if rescued and rescued ~= payload
           and ShareChecksum(rescued) == tonumber(sumStr) then
            payload = rescued
        else
            return nil, "The string is damaged or truncated - ask for it to be sent again in one piece."
        end
    end
    local name, body = string.match(payload, "^([^:]+):(.+)$")
    if not name or #name > 24 then
        return nil, "The string's body is malformed."
    end
    local items = {}
    -- v1.16: BOUNDED numeric parsing (a direct-send requirement, applied to
    -- the paste path too): every field has a digit cap and the slot must be
    -- a real equipment slot. Every legitimate 1.15 string passes unchanged.
    for section in string.gmatch(body, ver == "1" and "[^|]+" or "[^/]+") do
        local slot, itemId, plist = string.match(section, "^(%d+)=(%d+)=(.+)$")
        local slotN = (slot and #slot <= 2) and tonumber(slot) or nil
        if slotN and slotN >= 1 and slotN <= 19 and #itemId <= 8 then
            local procs = {}
            for part in string.gmatch(plist, "[^,]+") do
                local sid, ch, src = string.match(part, "^(%d+)%.?(%d*)%.?(%d*)$")
                if sid and #sid <= 8 and #ch <= 3 and #src <= 8 then
                    procs[#procs + 1] = { spellId = tonumber(sid),
                        chance = tonumber(ch), src = tonumber(src) }
                end
            end
            if #procs > 0 then
                items[#items + 1] = { slot = slotN,
                    itemId = tonumber(itemId), procs = procs }
            end
        end
    end
    if #items == 0 then
        return nil, "The string carries no procs."
    end
    return { name = name, items = items }
end

--==================== SHARED-PROCS VIEWER POPUP ==================
-- A read-only clone of the main list, fed from a parsed PICO string instead
-- of the wire. Same columns, same duplicate highlighting. It never sends
-- anything: no ICINV, no USPELLDMG (potency "with your stats" is meaningless
-- for someone else's gear anyway, so hover shows the shared chance only).
local viewFrame = CreateFrame("Frame", "PicoIDViewFrame", UIParent)
viewFrame:SetWidth(560)
viewFrame:SetHeight(300)
viewFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
viewFrame:SetMovable(true)
viewFrame:SetClampedToScreen(true)
viewFrame:SetFrameStrata("DIALOG")
viewFrame:EnableMouse(true)
viewFrame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
viewFrame:SetBackdropColor(0, 0, 0, 0.85)
viewFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
viewFrame:RegisterForDrag("LeftButton")
viewFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
viewFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
viewFrame:Hide()
tinsert(UISpecialFrames, "PicoIDViewFrame")

local viewTitle = viewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
viewTitle:SetPoint("TOPLEFT", 10, -6)
viewTitle:SetText("Shared procs")

local viewClose = CreateFrame("Button", nil, viewFrame, "UIPanelCloseButton")
viewClose:SetPoint("TOPRIGHT", 3, 3)
viewClose:SetWidth(24)
viewClose:SetHeight(24)

local viewScroll = CreateFrame("ScrollFrame", "PicoIDViewScroll", viewFrame,
    "UIPanelScrollFrameTemplate")
viewScroll:SetPoint("TOPLEFT", 8, -44)
viewScroll:SetPoint("BOTTOMRIGHT", -30, 24)

local viewContent = CreateFrame("Frame", nil, viewScroll)
viewContent:SetWidth(1)
viewContent:SetHeight(1)
viewScroll:SetScrollChild(viewContent)

local viewHeader = {}
for c = 1, #COLS do
    local fs = viewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetHeight(14)
    fs:SetText(COLS[c].title)
    viewHeader[c] = fs
end
local viewHeaderLine = viewFrame:CreateTexture(nil, "ARTWORK")
viewHeaderLine:SetTexture(1, 0.82, 0)
viewHeaderLine:SetHeight(1)
viewHeaderLine:SetAlpha(0.5)

local viewTotals = viewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
viewTotals:SetPoint("BOTTOMLEFT", 10, 6)
viewTotals:SetPoint("RIGHT", -10, 0)
viewTotals:SetJustifyH("LEFT")

local viewPool = {}
local viewUsed = 0
local viewData          -- the parsed PICO string currently on display

local function ViewerAcquireRow(index)
    local row = viewPool[index]
    if not row then
        row = CreateFrame("Button", nil, viewContent)
        -- NOT tagged .picoRow: the USPELLDMGR repaint must never fire for
        -- these rows (this popup requests no damage), and the tag is what
        -- authorizes that repaint.
        row:SetHeight(ROW_H)
        row:EnableMouse(true)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.06)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture(0, 0, 0, 0)
        row:SetScript("OnEnter", function(self)
            if not self.spellId then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(GetSpellInfo(self.spellId) or "Proc", 1, 0.82, 0)
            if self.chance and self.chance > 0 then
                GameTooltip:AddLine(string.format("Proc chance: %d%%", self.chance),
                    0.7, 0.7, 0.7)
            end
            if viewData and viewData.name then
                GameTooltip:AddLine("From " .. viewData.name .. "'s gear (shared list)",
                    0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            if not self.spellId then return end
            local text
            if IsShiftKeyDown() then
                text = tostring(self.spellId)
            else
                local pname = GetSpellInfo(self.spellId) or "Proc"
                text = "[" .. pname .. "] (" .. self.spellId .. ")"
            end
            local edit = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                or ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend()
            -- Same rule as the main window: only insert into a chat box the
            -- player already has open; never steal WASD focus.
            if edit and edit:IsShown() then
                edit:Insert(text)
                edit:SetFocus()
            end
        end)
        row.cells = {}
        for c = 1, #COLS do
            local fs = row:CreateFontString(nil, "OVERLAY")
            fs:SetFont("Fonts\\ARIALN.TTF", db and db.fontSize or 13, "")
            fs:SetJustifyH("LEFT")
            fs:SetHeight(ROW_H)
            row.cells[c] = fs
        end
        row.icons = {}
        for _, c in ipairs({ 1, 2, 4 }) do
            local tex = row:CreateTexture(nil, "ARTWORK")
            tex:SetWidth(14)
            tex:SetHeight(14)
            tex:Hide()
            row.icons[c] = tex
        end
        viewPool[index] = row
    end
    return row
end

local function ViewerLayout(nRows)
    local width = viewScroll:GetWidth()
    if not width or width < 50 then return end
    viewContent:SetWidth(width)
    local x = 0
    for c, col in ipairs(COLS) do
        local w = math.floor(width * col.w) - 6
        viewHeader[c]:ClearAllPoints()
        viewHeader[c]:SetPoint("TOPLEFT", viewFrame, "TOPLEFT", 8 + x, -28)
        viewHeader[c]:SetWidth(w)
        local hasIcon = (c == 1 or c == 2 or c == 4)
        for i = 1, nRows do
            local row = viewPool[i]
            local fs = row.cells[c]
            fs:ClearAllPoints()
            if hasIcon and row.icons and row.icons[c] then
                row.icons[c]:ClearAllPoints()
                row.icons[c]:SetPoint("LEFT", row, "LEFT", x + 1, 0)
                fs:SetPoint("LEFT", row, "LEFT", x + 17, 0)
                fs:SetWidth(math.max(10, w - 17))
            else
                fs:SetPoint("LEFT", row, "LEFT", x, 0)
                fs:SetWidth(w)
            end
        end
        x = x + math.floor(width * col.w)
    end
    viewHeaderLine:ClearAllPoints()
    viewHeaderLine:SetPoint("TOPLEFT", 8, -42)
    viewHeaderLine:SetPoint("TOPRIGHT", -30, -42)
end

-- Renders viewData. Returns true when every item name resolved (so the
-- primer below knows when to stop re-rendering).
local function ViewerRender()
    if not viewData or not viewFrame:IsShown() then return true end
    local count = {}
    for _, it in ipairs(viewData.items) do
        for _, p in ipairs(it.procs) do
            count[p.spellId] = (count[p.spellId] or 0) + 1
        end
    end
    local procCount, dupProcs = 0, 0
    for _, c in pairs(count) do
        procCount = procCount + c
        if c > 1 then dupProcs = dupProcs + 1 end
    end
    local n, allNamed = 0, true
    for _, it in ipairs(viewData.items) do
        -- ⚠ GetItemInfo by id returns nil until the item is in the local
        -- cache; the call itself asks the client to fetch it (an item-query
        -- on the GAME protocol, not an addon verb -- the AddonThrottle
        -- bucket is not involved). The primer re-renders as names arrive.
        local iname = (it.itemId and it.itemId > 0) and GetItemInfo(it.itemId) or nil
        if not iname then
            if it.itemId and it.itemId > 0 then
                allNamed = false
                iname = "item #" .. it.itemId
            else
                iname = "slot " .. (it.slot or "?")
            end
        end
        for _, p in ipairs(it.procs) do
            n = n + 1
            local row = ViewerAcquireRow(n)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", viewContent, "TOPLEFT", 0, -(n - 1) * ROW_H)
            row:SetPoint("RIGHT", viewContent, "RIGHT", 0, 0)
            local sid = p.spellId
            local dup = (count[sid] or 0) > 1
            local pname = GetSpellInfo(sid) or ("spell #" .. sid)
            local cols = { iname, pname, tostring(sid), OriginOf(sid), DropText(sid) }
            local r, g, b = 0.75, 0.55, 1
            if dup then r, g, b = 1, 0.25, 0.25 end
            for c = 1, #COLS do
                row.cells[c]:SetText(cols[c] or "")
                if c == 3 and not dup then
                    row.cells[c]:SetTextColor(1, 1, 1)
                else
                    row.cells[c]:SetTextColor(r, g, b)
                end
            end
            if dup then row.bg:SetTexture(1, 0, 0, 0.18)
            else row.bg:SetTexture(0, 0, 0, 0) end
            -- v1.15: icons. Item and origin icons resolve from the recipient's
            -- own cache (GetItemInfo asks the server for uncached ids; the
            -- viewer primer re-renders as answers arrive).
            local it10 = (it.itemId and it.itemId > 0)
                and select(10, GetItemInfo(it.itemId)) or nil
            if it10 then row.icons[1]:SetTexture(it10); row.icons[1]:Show()
            else row.icons[1]:Hide() end
            local pt = select(3, GetSpellInfo(sid))
            if pt then row.icons[2]:SetTexture(pt); row.icons[2]:Show()
            else row.icons[2]:Hide() end
            local ot = (p.src and p.src > 0)
                and select(10, GetItemInfo(p.src)) or nil
            if ot then row.icons[4]:SetTexture(ot); row.icons[4]:Show()
            else row.icons[4]:Hide() end
            row.spellId = sid
            row.chance = p.chance
            row:Show()
        end
    end
    for i = n + 1, viewUsed do viewPool[i]:Hide() end
    viewUsed = n
    viewContent:SetHeight(math.max(1, n * ROW_H))
    ViewerLayout(n)
    viewTotals:SetText(string.format(
        "|cffffd100%d|r items   |cffffd100%d|r procs%s   |cff808080(shared by %s - read-only)|r",
        #viewData.items, procCount,
        dupProcs > 0 and ("   |cffff4040" .. dupProcs .. " duplicated|r") or "",
        viewData.name or "?"))
    return allNamed
end

-- Same accumulator pattern as the main window's item primer: re-render four
-- times a second for up to 3s while item names trickle out of the cache.
local viewPrimer = CreateFrame("Frame")
viewPrimer:Hide()
local vpElapsed, vpTick = 0, 0
viewPrimer:SetScript("OnUpdate", function(self, dt)
    vpElapsed = vpElapsed + dt
    vpTick = vpTick + dt
    if vpTick < 0.25 then return end
    vpTick = 0
    if ViewerRender() or vpElapsed > 3 then
        self:Hide()
        vpElapsed, vpTick = 0, 0
    end
end)

local function ViewerOpen(data)
    viewData = data
    viewTitle:SetText((data.name or "?") .. "'s imprinted procs")
    EnsureData()
    viewFrame:Show()
    ViewerRender()
    vpElapsed, vpTick = 0, 0
    viewPrimer:Show()
end

--==================== DIRECT SHARING (PICO whispers) =============
--[[ v1.16: send your PICO string straight to another online PicoID user.
  APPROVED by the server owner (relayed by the admin, 2026-09-11), with the
  admin's design limits. Every number below is HIS rule, not a tuning knob:

  * The "PICO" prefix is client-owned and collision-free on this realm.
    UNC, REAGENTBANK, UVER, UTS and DSTATS are reserved for server traffic
    and must never carry shares.
  * PICO whispers cost ZERO AddonThrottle tokens -- this feature never
    touches the ICINV/USPELLDMG bucket. They DO count toward the session's
    CMSG_MESSAGECHAT anti-DoS allowance (policy: 60 packets per session per
    world-second, BLOCKING -- overflow is requeued and stalls this session's
    own processing pass), shared with ordinary chat and every other addon's
    chat. The pacing below keeps us far under it by ourselves, but headroom
    during another addon's message storm is not guaranteed -- one more
    reason nothing here ever retries on its own.
  * Sender: explicit button only, NO automatic retry, ONE outbound transfer
    at a time, >= 0.5s between chunks, >= 3s between transfers, >= 10s
    between transfers to the same recipient. The complete string is capped
    at 900 bytes / 4 chunks / 240 bytes per message INCLUDING the chunk
    header; an oversized share is rejected BEFORE any part is sent. The
    copy-paste string has no cap and is the designed fallback.
  * Receiver: one assembly per sender, expiring after 10s; a new first
    chunk replaces an unfinished assembly; contradictory totals,
    out-of-range sequence numbers, duplicate chunks and excess bytes
    discard it; concurrent incomplete assemblies are bounded. The checksum
    AND the bounded numeric parser must pass BEFORE the one clickable chat
    line appears. Nothing ever auto-opens, and received text is data --
    never evaluated as Lua.
  * Notifications: at most one per sender per 10s and six per minute
    overall (the share itself is still held -- only the extra line is
    suppressed). The accept-shares option (Interface -> AddOns -> PicoID)
    drops incoming chunks entirely. It matters more than it looks: addon
    whispers BYPASS the game's normal ignore/accept-whisper filtering, so
    this option is the recipient's only wall.

  ⚠ DELIVERY IS UNCONFIRMED BY DESIGN. This realm has no addon delivery
    acknowledgement. SendAddonMessage returning proves nothing; silence
    proves nothing (no PicoID installed, shares switched off and a lost
    chunk are indistinguishable). The ONLY explicit signal is the client's
    own "No player named ... is currently playing" system line, which
    aborts the transfer and is surfaced as exactly that. Everything else
    is reported as "sent - delivery unconfirmed". NEVER "delivered".

  Wire format, one whisper per chunk on prefix "PICO":
      <seq>:<total>:<payload>          (seq and total: one digit, 1..4)
  concat(payloads) is the ordinary PICO1 string, checksum included, so the
  paste-path parser -- and all of its validation -- is the single decoder. ]]

local StartDirectSend, OnDirectChunk, DirectDebugLine
do
    local PREFIX            = "PICO"
    local MAX_STRING        = 900   -- whole PICO1 string, bytes
    local MAX_MSG           = 240   -- one addon message, bytes, incl. header
    local MAX_CHUNKS        = 4
    local CHUNK_GAP         = 0.5   -- s between chunks
    local TRANSFER_GAP      = 3     -- s between transfers, any recipient
    local RECIPIENT_GAP     = 10    -- s between transfers to one recipient
    local ASSEMBLY_TTL      = 10    -- s an incomplete assembly may live
    local MAX_ASSEMBLIES    = 8     -- concurrent incomplete assemblies
    local NOTIFY_SENDER_GAP = 10    -- s between notifications per sender
    local NOTIFY_PER_MIN    = 6     -- notifications per minute, overall
    local MAX_HELD_SHARES   = 20    -- latest-per-sender lists kept

    ------------------------------ sender -----------------------------
    local sendState                  -- { target, chunks, idx, nextAt }
    local lastChunkAt = -1e9         -- stamp of any outbound PICO chunk
    local lastToRecipient = {}       -- lower(name) -> stamp
    local watchTarget, watchUntil = nil, 0
    local statusSink                 -- set by the share dialog

    local function Status(ok, text)
        if statusSink then statusSink(ok, text) end
    end

    -- The one explicit failure signal that exists: the client's own
    -- player-not-found system line. Registered only around a transfer.
    local sysWatch = CreateFrame("Frame")
    sysWatch:SetScript("OnEvent", function(self, _, msg)
        if GetTime() > watchUntil then
            self:UnregisterEvent("CHAT_MSG_SYSTEM")
            return
        end
        if not (msg and watchTarget) then return end
        local notFound = string.format(ERR_CHAT_PLAYER_NOT_FOUND_S
            or "No player named '%s' is currently playing.", watchTarget)
        if msg == notFound then
            if sendState then sendState = nil end   -- stop the pump; the rest
            Status(false, "No player named '" .. watchTarget    -- is wasted
                .. "' is online - nothing was delivered.")
            watchTarget = nil
            self:UnregisterEvent("CHAT_MSG_SYSTEM")
        end
    end)

    local pump = CreateFrame("Frame")
    pump:Hide()
    pump:SetScript("OnUpdate", function(self)
        if not sendState then self:Hide() return end
        local now = GetTime()
        if now < sendState.nextAt then return end
        local i = sendState.idx
        SendAddonMessage(PREFIX, sendState.chunks[i], "WHISPER", sendState.target)
        lastChunkAt = now
        if i >= #sendState.chunks then
            Status(true, string.format(
                "All %d part%s sent to %s - delivery is UNCONFIRMED (this realm "
                .. "has no addon receipt). If nothing appeared for them: no "
                .. "PicoID 1.16+, shares switched off, or a lost part. "
                .. "Re-sending is manual, 10s per recipient.",
                #sendState.chunks, #sendState.chunks == 1 and "" or "s",
                sendState.target))
            lastToRecipient[string.lower(sendState.target)] = now
            sendState = nil
            self:Hide()
        else
            sendState.idx = i + 1
            sendState.nextAt = now + CHUNK_GAP
            Status(true, string.format("Sending to %s - part %d of %d...",
                sendState.target, i + 1, #sendState.chunks))
        end
    end)

    function StartDirectSend(target, sink)
        if sink then statusSink = sink end
        target = string.gsub(string.gsub(target or "", "^%s+", ""), "%s+$", "")
        if target == "" then
            Status(false, "Type a character name first."); return
        end
        if string.find(target, "%s") then
            Status(false, "Character names have no spaces."); return
        end
        if sendState then
            Status(false, "A send is already in progress - one transfer at a time."); return
        end
        local now = GetTime()
        if now - lastChunkAt < TRANSFER_GAP then
            Status(false, "Wait a moment - at least 3 seconds between sends."); return
        end
        local lastTo = lastToRecipient[string.lower(target)]
        if lastTo and now - lastTo < RECIPIENT_GAP then
            Status(false, string.format(
                "Wait %d more second(s) before re-sending to %s.",
                math.ceil(RECIPIENT_GAP - (now - lastTo)), target)); return
        end
        local s = BuildShareString()
        if not s then
            Status(false, "No imprint data yet - open the PicoID window first, then try again."); return
        end
        if #s > MAX_STRING then
            -- Rejected BEFORE sending any part (admin rule).
            Status(false, string.format(
                "This list is %d bytes - over the %d-byte direct-send limit. "
                .. "Use the copy-paste string above instead (it has no limit).",
                #s, MAX_STRING)); return
        end
        -- Chunk. Header "<seq>:<total>:" is at most 4 bytes (both one digit),
        -- so a fixed 4-byte reserve keeps every message under MAX_MSG
        -- INCLUDING its header, and 4 x (MAX_MSG - 4) = 944 >= MAX_STRING.
        local payloadMax = MAX_MSG - 4
        local total = math.ceil(#s / payloadMax)
        local chunks = {}
        for i = 1, total do
            chunks[i] = i .. ":" .. total .. ":"
                .. string.sub(s, (i - 1) * payloadMax + 1, i * payloadMax)
        end
        sendState = { target = target, chunks = chunks, idx = 1, nextAt = 0 }
        watchTarget = target
        watchUntil = now + (total - 1) * CHUNK_GAP + 6
        sysWatch:RegisterEvent("CHAT_MSG_SYSTEM")
        Status(true, string.format("Sending to %s - part 1 of %d...", target, total))
        pump:Show()
    end

    ----------------------------- receiver ----------------------------
    local assemblies, nAssemblies = {}, 0   -- lower(sender) -> assembly
    local latestShare = {}                  -- sender -> latest parsed data
    local heldOrder = {}                    -- fifo bounding latestShare
    local lastNotifyBySender = {}
    local notifyStamps = {}

    local function Drop(key)
        if assemblies[key] then
            assemblies[key] = nil
            nAssemblies = nAssemblies - 1
        end
    end

    local function PruneAssemblies(now)
        for k, a in pairs(assemblies) do
            if now > a.expires then Drop(k) end
        end
    end

    function OnDirectChunk(sender, body)
        if not db or db.acceptShares == false then return end  -- the wall
        if not sender or sender == "" or not body then return end
        if #body > MAX_MSG then return end                     -- oversized message
        local seq, total, payload = string.match(body, "^(%d):(%d):(.*)$")
        seq, total = tonumber(seq), tonumber(total)
        if not seq or not total then return end
        if total < 1 or total > MAX_CHUNKS
           or seq < 1 or seq > total then return end           -- out of range
        local key = string.lower(sender)
        local now = GetTime()
        PruneAssemblies(now)
        local a = assemblies[key]
        if seq == 1 then
            -- A new first chunk replaces an unfinished assembly (admin rule).
            if not a then
                if nAssemblies >= MAX_ASSEMBLIES then return end  -- bounded
                nAssemblies = nAssemblies + 1
            end
            a = { total = total, parts = {}, got = 0, bytes = 0,
                  expires = now + ASSEMBLY_TTL }
            assemblies[key] = a
        elseif not a then
            return                       -- a middle chunk with nothing to join
        elseif a.total ~= total then
            Drop(key); return            -- contradictory totals
        end
        if a.parts[seq] then Drop(key); return end             -- duplicate chunk
        a.parts[seq] = payload
        a.got = a.got + 1
        a.bytes = a.bytes + #payload
        if a.bytes > MAX_STRING then Drop(key); return end     -- excess bytes
        if a.got < a.total then return end
        Drop(key)
        -- Complete. Checksum + bounded numeric parse BEFORE anything shows.
        -- A failed parse stays silent: there is nothing honest to say about
        -- who or what mangled it, and noise here would be a griefing lever.
        local data = ParseShareString(table.concat(a.parts, "", 1, a.total))
        if not data then return end
        data.viaSender = sender
        if not latestShare[sender] then
            heldOrder[#heldOrder + 1] = sender
            if #heldOrder > MAX_HELD_SHARES then
                latestShare[table.remove(heldOrder, 1)] = nil
            end
        end
        latestShare[sender] = data
        -- Notification caps (admin rule). The share above is already held --
        -- only the extra chat line is suppressed.
        local last = lastNotifyBySender[sender]
        if last and (now - last) < NOTIFY_SENDER_GAP then return end
        for i = #notifyStamps, 1, -1 do
            if now - notifyStamps[i] > 60 then table.remove(notifyStamps, i) end
        end
        if #notifyStamps >= NOTIFY_PER_MIN then return end
        lastNotifyBySender[sender] = now
        notifyStamps[#notifyStamps + 1] = now
        local label = sender .. "'s PicoID"
        if data.name and data.name ~= sender then
            -- The string labels its owner; the whisper names its SENDER.
            -- Show both when they differ instead of trusting the label.
            label = label .. " (list labeled '" .. data.name .. "')"
        end
        DEFAULT_CHAT_FRAME:AddMessage("|Hpico:" .. sender .. "|h|cff80ffff["
            .. label .. " - click to view]|r|h")
    end

    function DirectDebugLine()
        local held = 0
        for _ in pairs(latestShare) do held = held + 1 end
        return "  direct: accept=" .. tostring(not (db and db.acceptShares == false))
            .. "  held shares: " .. held .. "  assemblies: " .. nAssemblies
            .. "  sending: " .. tostring(sendState ~= nil)
    end

    -- The clickable line. On 3.3.5a every |H...|h chat link lands in
    -- SetItemRef; unknown types fall through, so wrapping the original keeps
    -- every stock link working. The click IS the consent -- ViewerOpen runs
    -- here and nowhere else on the receive path.
    local origSetItemRef = SetItemRef
    function SetItemRef(link, text, button, chatFrame)
        local who = string.match(link or "", "^pico:(.+)$")
        if who then
            local data = latestShare[who]
            if data then
                ViewerOpen(data)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cffff2020PicoID|r: that share is "
                    .. "no longer held (only the latest list per sender is kept).")
            end
            return
        end
        return origSetItemRef(link, text, button, chatFrame)
    end
end

--========================= SHARE DIALOG ==========================

-- One dialog for both directions: your string on top (pre-selected for
-- Ctrl+C), a paste box + View underneath.
local shareFrame = CreateFrame("Frame", "PicoIDShareFrame", UIParent)
shareFrame:SetWidth(540)
shareFrame:SetHeight(268)   -- v1.16: taller for the direct-send row
shareFrame:SetPoint("CENTER")
shareFrame:SetFrameStrata("DIALOG")
shareFrame:SetMovable(true)
shareFrame:EnableMouse(true)
shareFrame:SetClampedToScreen(true)
shareFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
shareFrame:Hide()
tinsert(UISpecialFrames, "PicoIDShareFrame")

local shareTitleStrip = CreateFrame("Frame", nil, shareFrame)
shareTitleStrip:SetPoint("TOPLEFT", 12, -12)
-- v1.18: ends 44px short of the right edge. Full-width, this mouse-enabled
-- strip sat OVER the close button and swallowed its clicks (the 1.16/1.17 "X
-- doesn't work" reports in full). Nobody drags a dialog by the pixels under
-- its X; the button owns that corner now.
shareTitleStrip:SetPoint("TOPRIGHT", -44, -12)
shareTitleStrip:SetHeight(20)
shareTitleStrip:EnableMouse(true)
shareTitleStrip:RegisterForDrag("LeftButton")
shareTitleStrip:SetScript("OnDragStart", function() shareFrame:StartMoving() end)
shareTitleStrip:SetScript("OnDragStop", function() shareFrame:StopMovingOrSizing() end)
local shareTitleText = shareTitleStrip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
shareTitleText:SetPoint("CENTER")
shareTitleText:SetText("PicoID Share")

local shareClose = CreateFrame("Button", nil, shareFrame, "UIPanelCloseButton")
shareClose:SetPoint("TOPRIGHT", -6, -6)
-- v1.18: belt-and-braces on top of the shortened drag strip -- keep the X
-- above ANY mouse-enabled sibling so no future layout change can cover it
-- again. The 1.17 SetHitRectInsets is deliberately gone: it was aimed at the
-- wrong cause (stock art padding) and clipped away the one sliver of the
-- button the old full-width strip had left clickable.
shareClose:SetFrameLevel(shareTitleStrip:GetFrameLevel() + 5)

local shareLabel1 = shareFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
shareLabel1:SetPoint("TOPLEFT", 20, -40)
shareLabel1:SetText("Your PICO string - press Ctrl+C, then paste it anywhere (Discord keeps it in one piece):")

-- v1.19: tick-mode affordances. The label says which procs the string
-- carries, and Clear ticks returns to share-everything without a trip back
-- to the main window.
local clearTicksBtn = CreateFrame("Button", nil, shareFrame, "UIPanelButtonTemplate")
clearTicksBtn:SetPoint("TOPRIGHT", -24, -34)
clearTicksBtn:SetWidth(84)
clearTicksBtn:SetHeight(18)
clearTicksBtn:SetText("Clear ticks")
clearTicksBtn:Hide()

local function MakeShareEditBox(topOffset, rightOffset)
    local box = CreateFrame("EditBox", nil, shareFrame)
    box:SetPoint("TOPLEFT", 22, topOffset)
    box:SetPoint("RIGHT", rightOffset or -26, 0)
    box:SetHeight(20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(0)
    box:SetFontObject(ChatFontNormal)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.5)
    return box
end

local shareEdit = MakeShareEditBox(-58)
shareEdit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

local shareLabel2 = shareFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
shareLabel2:SetPoint("TOPLEFT", 20, -100)
shareLabel2:SetText("Paste a friend's string and press View:")

-- v1.16: narrower -- the View button moved up beside it, freeing the
-- bottom of the dialog for the direct-send row and a roomier status line.
local importEdit = MakeShareEditBox(-118, -116)

-- v1.16: the direct-send row. Approved player-to-player delivery; all the
-- pacing, sizing and honesty rules live in the DIRECT SHARING section.
local shareLabel3 = shareFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
shareLabel3:SetPoint("TOPLEFT", 20, -152)
shareLabel3:SetText("Or send it straight to an online player (they need PicoID 1.16+):")

-- v1.17: the box was invisible when empty -- a borderless half-transparent
-- black rectangle on a dark dialog, next to a lone Send button (Mhortai's
-- screenshot). A tooltip border + a placeholder make it findable.
local targetEdit = CreateFrame("EditBox", nil, shareFrame)
targetEdit:SetPoint("TOPLEFT", 22, -168)
targetEdit:SetWidth(150)
targetEdit:SetHeight(22)
targetEdit:SetAutoFocus(false)
targetEdit:SetMaxLetters(24)
targetEdit:SetFontObject(ChatFontNormal)
targetEdit:SetTextInsets(6, 6, 0, 0)
targetEdit:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 10,
    insets = { left = 3, right = 3, top = 2, bottom = 2 },
})
targetEdit:SetBackdropColor(0, 0, 0, 0.6)
targetEdit:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
targetEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
local targetHint = targetEdit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
targetHint:SetPoint("LEFT", 8, 0)
targetHint:SetText("character name...")
targetEdit:SetScript("OnEditFocusGained", function() targetHint:Hide() end)
targetEdit:SetScript("OnEditFocusLost", function(self)
    if self:GetText() == "" then targetHint:Show() end
end)
targetEdit:SetScript("OnTextChanged", function(self)
    if self:GetText() ~= "" then targetHint:Hide() end
end)

local sendBtn = CreateFrame("Button", nil, shareFrame, "UIPanelButtonTemplate")
sendBtn:SetPoint("LEFT", targetEdit, "RIGHT", 8, 0)
sendBtn:SetWidth(76)
sendBtn:SetHeight(22)
sendBtn:SetText("Send")

local shareStatus = shareFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
shareStatus:SetPoint("TOPLEFT", 20, -198)
shareStatus:SetPoint("RIGHT", -20, 0)
shareStatus:SetJustifyH("LEFT")
shareStatus:SetText("")

local function ShareStatusSink(ok, text)
    if ok then shareStatus:SetTextColor(0.6, 1, 0.6)
    else shareStatus:SetTextColor(1, 0.4, 0.4) end
    shareStatus:SetText(text or "")
end
sendBtn:SetScript("OnClick", function()
    StartDirectSend(targetEdit:GetText(), ShareStatusSink)
end)
targetEdit:SetScript("OnEnterPressed", function() sendBtn:Click() end)

local viewBtn = CreateFrame("Button", nil, shareFrame, "UIPanelButtonTemplate")
viewBtn:SetPoint("LEFT", importEdit, "RIGHT", 8, 0)
viewBtn:SetWidth(76)
viewBtn:SetHeight(22)
viewBtn:SetText("View")
viewBtn:SetScript("OnClick", function()
    local data, err = ParseShareString(importEdit:GetText())
    if data then
        shareStatus:SetTextColor(0.6, 1, 0.6)
        local nProcs = 0
        for _, it in ipairs(data.items) do nProcs = nProcs + #it.procs end
        shareStatus:SetText(string.format("Showing %s's list: %d items, %d procs.",
            data.name, #data.items, nProcs))
        ViewerOpen(data)
    else
        shareStatus:SetTextColor(1, 0.4, 0.4)
        shareStatus:SetText(err or "Could not read that string.")
    end
end)
importEdit:SetScript("OnEnterPressed", function() viewBtn:Click() end)

-- v1.19: one refresher for the dialog's string + mode line, used by OnShow,
-- by every tickbox click while the dialog is open (OnTicksChanged), and by
-- Clear ticks. It never steals focus -- only OnShow does that -- so ticking
-- rows mid-typing cannot yank the cursor out of the name box.
local function RefreshShareDialog()
    local s = BuildShareString()
    local sel, total = TickedCount(), ProcTotal()
    if sel > 0 then
        shareLabel1:SetText(string.format(
            "Your PICO string - |cff80ffff%d of %d procs (ticked only)|r - press Ctrl+C:",
            sel, total))
        clearTicksBtn:Show()
    else
        shareLabel1:SetText(
            "Your PICO string - press Ctrl+C, then paste it anywhere (Discord keeps it in one piece):")
        clearTicksBtn:Hide()
    end
    if s then
        shareEdit:SetText(s)
    else
        shareEdit:SetText("(no imprint data yet - open the PicoID window first, then reopen Share)")
    end
end
OnTicksChanged = function()
    if shareFrame:IsShown() then RefreshShareDialog() end
end
clearTicksBtn:SetScript("OnClick", function()
    ticked = {}
    if RefreshList then RefreshList() end
    RefreshShareDialog()
end)

shareFrame:SetScript("OnShow", function()
    RefreshShareDialog()
    local s = shareEdit:GetText() or ""
    if string.sub(s, 1, 5) == "PICO2" then
        shareEdit:SetFocus()
        shareEdit:HighlightText()
    else
        shareEdit:HighlightText(0, 0)
    end
    shareStatus:SetText("")
end)

local printBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
printBtn:SetPoint("RIGHT", close, "LEFT", 2, 0)
printBtn:SetWidth(50)
printBtn:SetHeight(16)
printBtn:SetText("Print")
printBtn:SetScript("OnClick", DoPrint)

local refreshBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
refreshBtn:SetPoint("RIGHT", printBtn, "LEFT", -2, 0)
refreshBtn:SetWidth(56)
refreshBtn:SetHeight(16)
refreshBtn:SetText("Refresh")
refreshBtn:SetScript("OnClick", function() RefreshList() end)

-- Reset button: restore the default size and centre position
local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
resetBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -2, 0)
resetBtn:SetWidth(50)
resetBtn:SetHeight(16)
resetBtn:SetText("Reset")
resetBtn:SetScript("OnClick", function()
    frame:ClearAllPoints()
    frame:SetWidth(560)
    frame:SetHeight(300)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    Layout()
end)

-- Share button: opens the PICO string dialog (copy yours / paste a friend's).
local shareBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
shareBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
shareBtn:SetWidth(50)
shareBtn:SetHeight(16)
shareBtn:SetText("Share")
shareBtn:SetScript("OnClick", function()
    if shareFrame:IsShown() then
        shareFrame:Hide()
    else
        shareFrame:Show()   -- OnShow rebuilds the string each time
    end
end)

-- Ask the server for a fresh soulbound-inventory stream (same request the
-- Uncapped addon uses: ICINV -> ICITEM/ICIPROC/.../ICINVEND). This makes the
-- data arrive right away instead of waiting for Uncapped's next refresh.
-- ⚠ DEBOUNCED. ICINV is the most expensive verb on this pipe -- COST_HEAVY, 6 of
-- a 60-token bucket -- and it was sent on every single window open. Ten impatient
-- clicks on the minimap button was the whole burst, after which this addon and
-- every other one on the account went quiet. The stream is also pushed by
-- UncappedSoulForge on login and on every equipment change, so a re-ask inside
-- the refresh window buys nothing.
local ICINV_MIN_INTERVAL = 10
local lastImprintAsk = 0
local function RequestImprints(force)
    local now = GetTime() or 0
    if not force and boundReceived and (now - lastImprintAsk) < ICINV_MIN_INTERVAL then return end
    lastImprintAsk = now
    SendAddonMessage("REAGENTBANK", "ICINV", "WHISPER", UnitName("player"))
end

function PicoID_Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        RefreshList()
        PicoID_itemPrimer:Show()
        RequestImprints()
    end
end

--======================= MINIMAP BUTTON ==========================
local mm = CreateFrame("Button", "PicoIDMinimapButton", Minimap)
mm:SetWidth(32)
mm:SetHeight(32)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mm:RegisterForClicks("LeftButtonUp")
mm:RegisterForDrag("LeftButton")

local mmOverlay = mm:CreateTexture(nil, "OVERLAY")
mmOverlay:SetWidth(53)
mmOverlay:SetHeight(53)
mmOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmOverlay:SetPoint("TOPLEFT")

local mmIcon = mm:CreateTexture(nil, "BACKGROUND")
mmIcon:SetWidth(20)
mmIcon:SetHeight(20)
mmIcon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02") -- change icon here
mmIcon:SetPoint("TOPLEFT", 7, -5)

local function MinimapSetPosition()
    local angle = math.rad(db.minimapPos or 200)
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function UpdateMinimapButton()
    if db.minimap then
        MinimapSetPosition()
        mm:Show()
    else
        mm:Hide()
    end
end

mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        db.minimapPos = math.deg(math.atan2(py - my, px - mx))
        MinimapSetPosition()
    end)
end)
mm:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)
mm:SetScript("OnClick", PicoID_Toggle)
mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("PicoID")
    GameTooltip:AddLine("Click: show imprinted procs", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 1, 1, 1)
    GameTooltip:Show()
end)
mm:SetScript("OnLeave", function() GameTooltip:Hide() end)

--======================= OPTIONS PANEL ===========================
local panel = CreateFrame("Frame", "PicoIDOptionsPanel", UIParent)
panel.name = "PicoID"

local function BuildPanel()
    local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -12)
    t:SetText("PicoID")
    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -2)
    sub:SetText("Lists the procs imprinted on your equipped items, with their IDs and origins.")

    local mmCheck = CreateFrame("CheckButton", "PicoIDMinimapCheck", panel, "OptionsCheckButtonTemplate")
    mmCheck:SetPoint("TOPLEFT", 8, -50)
    _G["PicoIDMinimapCheckText"]:SetText("Show minimap button")
    mmCheck:SetScript("OnClick", function(self)
        db.minimap = self:GetChecked() and true or false
        UpdateMinimapButton()
    end)
    panel.mmCheck = mmCheck

    -- v1.16: the recipient's only wall against direct shares -- addon
    -- whispers bypass the game's normal ignore list, so unticking this is
    -- the real "ignore", dropping incoming PICO chunks entirely.
    local shCheck = CreateFrame("CheckButton", "PicoIDAcceptSharesCheck", panel, "OptionsCheckButtonTemplate")
    shCheck:SetPoint("TOPLEFT", 8, -74)
    _G["PicoIDAcceptSharesCheckText"]:SetText("Accept shares sent directly by other players")
    shCheck:SetScript("OnClick", function(self)
        db.acceptShares = self:GetChecked() and true or false
    end)
    panel.shCheck = shCheck

    local function MakeSlider(name, label, key, minV, maxV, step, x, y, fmt)
        local s = CreateFrame("Slider", "PicoID" .. name, panel, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", x, y)
        s:SetWidth(160)
        s:SetMinMaxValues(minV, maxV)
        s:SetValueStep(step)
        _G[s:GetName() .. "Low"]:SetText(minV)
        _G[s:GetName() .. "High"]:SetText(maxV)
        local text = _G[s:GetName() .. "Text"]
        s:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value / step + 0.5) * step
            db[key] = value
            text:SetText(label .. ": " .. string.format(fmt, value))
            ApplyLook()
        end)
        return s
    end
    panel.fontSlider = MakeSlider("Font", "Font size", "fontSize", 8, 24, 1, 16, -140, "%d")
    panel.alphaSlider = MakeSlider("Alpha", "Opacity", "opacity", 0, 1, 0.05, 210, -140, "%.2f")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetPoint("TOPLEFT", 16, -190)
    open:SetWidth(120)
    open:SetHeight(22)
    open:SetText("Open PicoID")
    open:SetScript("OnClick", PicoID_Toggle)
end

panel.refresh = function()
    panel.mmCheck:SetChecked(db.minimap)
    panel.shCheck:SetChecked(db.acceptShares ~= false)
    panel.fontSlider:SetValue(db.fontSize)
    panel.alphaSlider:SetValue(db.opacity)
end
panel.okay, panel.cancel, panel.default = function() end, function() end, function() end

--========================= EVENT FRAME ===========================
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("UNIT_INVENTORY_CHANGED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, body, channel, sender = ...
        -- v1.16: direct shares arrive on the client-owned PICO prefix,
        -- whispers only. Everything about them lives in OnDirectChunk.
        if prefix == "PICO" then
            if channel == "WHISPER" and body then
                OnDirectChunk(sender, body)
            end
        elseif prefix == UNC_PREFIX and body then
            if string.sub(body, 1, 2) == "IC" then
                OnUncappedLine(body)
            else
                local sid, mn, mx = string.match(body, "^USPELLDMGR:(%d+):(%d+):(%d+)$")
                if sid then
                    sid = tonumber(sid)
                    spellDmg[sid] = { tonumber(mn), tonumber(mx) }
                    dmgAsked[sid] = nil
                    --[[ ⚠ `.spellId` IS NOT OURS ALONE. This used to repaint the
                      tooltip whenever ANY frame owning it happened to have a
                      matching .spellId field -- and UncappedSoulForge sets exactly
                      that on its equipped-row on-use buttons
                      (UncappedSoulForge.lua:1467) and anchors GameTooltip to them
                      on hover. So reading a clicky's cooldown line got it wiped and
                      replaced by ours. Require our own tag as well.            ]]
                    local owner = GameTooltip:GetOwner()
                    if GameTooltip:IsShown() and owner and owner.picoRow
                       and owner.spellId == sid then
                        ShowProcTooltip(owner, sid)
                    end
                end
            end
        end

    elseif event == "UNIT_INVENTORY_CHANGED" then
        if ... == "player" then
            spellDmg = {}; dmgAsked = {}
            if frame:IsShown() then RefreshList() end
        end

    elseif event == "ADDON_LOADED" and ... == ADDON_NAME then
        PicoIDDB = PicoIDDB or {}
        db = PicoIDDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        ApplyLook()
        UpdateMinimapButton()
        BuildPanel()
        InterfaceOptions_AddCategory(panel)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

--======================= SLASH COMMANDS ==========================
SLASH_PICOID1 = "/picoid"
SLASH_PICOID2 = "/pid"
SlashCmdList["PICOID"] = function(msg)
    if msg == "debug" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff80ffffPicoID debug|r")
        DEFAULT_CHAT_FRAME:AddMessage("  db set: " .. tostring(db ~= nil)
            .. "  boundReceived: " .. tostring(boundReceived))
        local n = 0
        for _ in pairs(boundByKey) do n = n + 1 end
        DEFAULT_CHAT_FRAME:AddMessage("  boundByKey entries: " .. n)
        local eq = 0
        for slot = 1, 19 do
            local p = boundByKey["E:" .. slot]
            if p then eq = eq + #p end
        end
        DEFAULT_CHAT_FRAME:AddMessage("  equipped procs counted: " .. eq)
        DEFAULT_CHAT_FRAME:AddMessage("  ProcDB loaded: " .. tostring(PicoID_ProcDB ~= nil)
            .. "  DropDB: " .. tostring(PicoID_DropDB ~= nil))
        DEFAULT_CHAT_FRAME:AddMessage(DirectDebugLine())
    else
        PicoID_Toggle()
    end
end
