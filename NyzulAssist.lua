--[[
NyzulAssist - Windower 4 helper + semi-auto for Nyzul Isle Investigation (solo)
by SmallnDumb - BSD 3-Clause licence (see LICENSE)

  Helper : floor / timer / objective / restriction panel, objective-target finder
           (auto /check for "impossible to gauge"), archaic gear warnings,
           Rune of Transfer + lamp direction finder, lamp-order puzzle solver,
           token estimate.
  Semi-auto (//nz auto): targets + engages objective mobs that are already
           within range, faces them, weaponskills at your TP threshold, and
           pre-targets the lamp / Rune of Transfer when you walk up to it.
           YOU do all the moving. It pauses itself when you get a /tell.
  Jobs   : Corsair rolls, Dancer waltzes / jig, and buffs / heals you pick
           for any job (//nz buff, //nz heal).

Credits: message strings, token formula and lamp/rune entity indexes were
learned from NyzulHelper (Glarin of Asura, BSD-3), NyzulBuddy (Darkdoom) and
NyzulBestBuddy (LordAttilas). Target setting uses the same client-side
technique as Windower's official SetTarget addon.

Use at your own risk: Square Enix's ToS does not allow third-party tools.
]]

_addon.name     = 'NyzulAssist'
_addon.author   = 'SmallnDumb'
_addon.version  = '1.0.1'
_addon.commands = {'nyzulassist', 'nz'}
_addon.language = 'english'

require('chat')                 -- string.strip_format
local config  = require('config')
local packets = require('packets')
local texts   = require('texts')

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local ZONE_NYZUL      = 77
local ZONE_ALZADAAL   = 72
local KI_ARMBAND      = 797
local IDX_RUNE_FIRST  = 0x2D2   -- 0x2D2 / 0x2D3 alternate between floors
local IDX_RUNE_LAST   = 0x2D3
local IDX_LAMP_FIRST  = 0x2D4   -- lamps A..E = 0x2D4..0x2D8
local IDX_LAMP_LAST   = 0x2D8
local LIT_BIT         = 0x10000 -- 0x00E "_unknown4" bit for an activated lamp
local MSG_CHECK_IT    = 249     -- "<mob>'s strength is impossible to gauge!"
local SPAWN_MONSTER   = 16
local RUN_SECONDS     = 30 * 60

local function make_set(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

-- "Eliminate enemy leader" NMs (bg-wiki). Boss floors (20/40/60/80/100) are handled separately.
local LEADERS = make_set{
    'Long-Gunned Chariot', 'Long-Horned Chariot', 'Battledressed Chariot', 'Shielded Chariot',
    'Anise Custard', 'Caraway Custard', 'Cinnamon Custard', 'Cumin Custard', 'Ginger Custard',
    'Mint Custard', 'Nutmeg Custard', 'Vanilla Custard',
    'Mokka', 'Mokke', 'Mokku',
    'Eriri Samariri', 'Oriri Samariri', 'Uriri Samariri',
    'Vile Ineef', 'Vile Wahdaha', 'Vile Yabeewa',
    'Gem Heister Roorooroon', 'Quick Draw Sasaroon', 'Stealth Bomber Gagaroon',
}

-- Floor 20/40/60/80/100 bosses
local BOSSES = make_set{'Adamantoise', 'Aspidochelone', 'Aspid', 'Behemoth', 'Cerberus', 'Fafnir', 'Hydra', 'Khimaira'}

-- Random floor NMs (allakhazam's Nyzul Isle list). They check "impossible to gauge" too,
-- but they're never the "specified enemy" - that's always a normal mob that checks IT.
local FLOOR_NMS = make_set{
    -- floors 1-19
    'Bat Eye', 'Shadow Eye', 'Bomb King', 'Juggler Hecatomb', 'Smothered Schmidt', 'Hellion', 'Leaping Lizzy',
    'Tom Tit Tat', 'Jaggedy-Eared Jack', 'Cactuar Cantautor', 'Gargantua', 'Gyre-Carlin', 'Asphyxiated Amsel',
    'Frostmane', 'Peallaidh', 'Carnero', 'Falcatus Aranei', 'Emergent Elm',
    -- floors 21-39
    'Old Two-Wings', 'Aiatar', 'Intulo', 'Orctrap', 'Valkurm Emperor', 'Crushed Krause', 'Stinging Sophie',
    'Serpopard Ishtar', 'Western Shadow', 'Bloodtear Baldurf', 'Zizzy Zillah', 'Ellyllon', 'Mischievous Micholas',
    'Leech King', 'Eastern Shadow', 'Nunyenunc', 'Helldiver', 'Taisaijin', 'Aquarius',
    -- floors 41-59
    'Fungus Beetle', 'Friar Rush', 'Pulverized Pfeffer', 'Argus', 'Bloodpool Vorax', 'Nightmare Vase',
    'Daggerclaw Dracos', 'Northern Shadow', 'Fraelissa', 'Roc', 'Sabotender Bailarin', 'Energetic Eruca',
    'Spiny Spipi', 'Trickster Kinetix', 'Drooling Daisy', 'Bonnacon',
    -- floors 61-79
    'Golden Bat', 'Steelfleece Baldarich', 'Sabotender Mariachi', 'Ungur', 'Swamfisk', 'Buburimboo',
    'Keeper of Halidom', 'Serket', 'Dune Widow', 'Odqan', 'Burned Bergmann', 'Tyrannic Tunnok', 'Bloodsucker',
    'Tottering Toby', 'Southern Shadow', 'Sharp-Eared Ropipi', 'Unut', 'Vouivre',
    -- floors 81-99
    'Panzer Percival', 'Jolly Green', 'Tumbling Truffle', 'Capricious Cassie', 'Amikiri', 'Stray Mary',
    'Sewer Syrup', 'Simurgh', 'Pelican', 'Cargo Crab Colin', 'Wounded Wurfel', 'Peg Powler', 'Jaded Jody',
    'Maighdean Uaine',
}

local function is_nm_name(name)
    return FLOOR_NMS[name] or LEADERS[name] or BOSSES[name]
end

-- "Eliminate specified enemies" families (the real ones check "impossible to gauge").
local FAMILIES = make_set{
    'Heraldic Imp', 'Psycheflayer', 'Poroggo Gent', 'Ebony Pudding', 'Racing Chariot',
    'Qiqirn Treasure Hunter', 'Qiqirn Archaeologist',
}

-- Chat modes used by players (say/shout/tell/party/LS/emote/unity/assist...). Never parse these.
local PLAYER_MODES = make_set{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
                              211,212,213,214,215,216,217,218,219,220,221,222}
local MODE_TELL_IN = 12
-- Modes the game uses for Nyzul's own announcements (floor, objective, lamps, rules, timer).
local SYSTEM_MODES = make_set{121, 123, 146, 148, 150, 151, 161}

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local defaults = {
    pos     = {x = 150, y = 250},
    bg      = {alpha = 170, red = 15, green = 15, blue = 25},
    text    = {font = 'Consolas', size = 10, red = 230, green = 230, blue = 230,
               stroke = {width = 1, alpha = 200}},
    flags   = {draggable = true},
    padding = 6,

    engage_range    = 15,     -- semi-auto only engages objective mobs this close (yalms)
    check_range     = 30,     -- auto-/check mobs within this range
    check_interval  = 1.5,    -- seconds between auto checks
    autocheck       = true,   -- auto-/check mobs on "specified enemy/enemies/leader" floors
    hide_checks     = true,   -- hide the chat lines from checks the addon sent
    autoface        = true,   -- face your target while engaged (semi-auto)
    defend          = true,   -- semi-auto fights back against mobs that claimed you
    autoobject      = true,   -- semi-auto pre-targets lamp / rune when you're next to it
    object_range    = 6,
    ws_name         = '',     -- e.g. Savage Blade ('' = no auto weaponskill)
    ws_tp           = 1000,
    ws_delay        = 3,
    ws_alt          = '',     -- backup WS: for mobs your WS heals, and instead of an area WS next to an Archaic Gear
    ws_alt_mobs     = 'Cumin Custard:Aeolian Edge,Puk:Aeolian Edge',   -- "Mob:WS" pairs where that WS heals the mob (learned when it happens)
    ws_boss         = '',     -- WS on boss floors (20/40/60/80/100); '' = your normal WS
    ws_boss_tp      = 1000,
    lamp_read_wait  = 14,     -- seconds after the last lamp of a round before reading lamp states
    request_updates = false,  -- inject 0x016 to see far-away lamps (extra packet injection!)
    pause_on_tell   = true,
    update_check    = false,                -- look for a newer version once a week, at login (//nz update on)
    setup_pos       = {x = 560, y = 200},   -- where the //nz setup window opens
    welcomed        = false,                -- (said hello once)
    update_last     = '',                   -- (the last time it looked)
    gear_warn_range = 12,

    -- Corsair (main job COR, semi-auto only)
    cor              = true,
    cor_idle_rolls   = 'bolter',            -- kept up while not fighting (max 2)
    cor_combat_rolls = 'chaos,tactician',   -- kept up while engaged (max 2)
    cor_double_max   = 5,                   -- Double-Up while total <= this (5 = can never bust; 0 = never)
    cor_idle_enemy_range = 10,              -- don't roll idle rolls with an enemy this close (yalms); ignored once the floor is done
    cor_tp_hold      = 800,                 -- no rolls / Double-Up at this much TP or more (your roll gear resets TP); 0 = off
    -- Dancer (main or sub DNC, semi-auto only)
    waltz            = true,
    waltz3_hpp       = 50,                  -- Curing Waltz III at or below this HP%
    waltz2_hpp       = 70,                  -- Curing Waltz II at or below this HP%
    ja_gear_range    = 20,                  -- no rolls with an Archaic Gear this close (abilities aggro them)
    jig              = true,                -- DNC main/sub: Spectral Jig when not fighting
    jig_roll_window  = 15,                  -- COR: hold the jig if a roll is due within this many seconds
    jig_lamp_floors  = true,                -- jig on lamp floors too (Invisible is clicked off near the lamp)
    jig_lamp_range   = 15,                  -- ...but not within this many yalms of the lamp you need next
    jig_rune_range   = 20,                  -- floor done: jig only if the Rune of Transfer is further than this
    jig_all          = false,               -- also jig on "kill all enemies" floors
    jig_enemy_range  = 5,                   -- no jig with an enemy this close (yalms)
    uninvis          = true,                -- drop Invisible when you walk up to the lamp / rune you need
    -- Any job: abilities / spells to keep up and to heal with (//nz buff, //nz heal)
    rules_on         = true,
    buffs            = '',                  -- e.g. 'Berserk|fight;Hasso|always' (fight / idle / always)
    heals            = '',                  -- e.g. 'Cure IV|40;Chakra|30' (use at or below this HP%)
    uninvis_range    = 20,                  -- ...from this many yalms away

    directions       = 'compass',           -- 'compass' (N/NE/E...), 'clock' (12 = facing), or 'both'

    -- Main panel look. 'classic' = two columns with room between lines; 'compact' = the old single box.
    panel = {
        style         = 'classic',
        font          = 'Arial',
        size          = 12,
        bold          = true,
        stroke        = 0,       -- outline width around letters (0 = none)
        line_spacing  = 5,       -- extra pixels between lines
        group_spacing = 9,       -- extra pixels between sections
        padding       = 10,
        column_gap    = 16,
        bg            = {alpha = 215, red = 0, green = 0, blue = 0},
        show_rolls    = true,    -- the "Rolls:" line
        show_waltz    = true,    -- the "Waltz:" line
    },

    -- Radar widget: big arrow to the Rune of Transfer, small arrows for targets. Drag it by its title.
    radar = {
        show  = true,
        up    = 'camera',      -- 'camera' (up = into the screen), 'north', or 'facing'
        cam_calib = '',        -- learned automatically while you run; '' = not learned yet
        size  = 130,           -- pixels
        pos   = {x = -1, y = -1},   -- -1 = top-centre of the screen
        bg    = {alpha = 170, red = 15, green = 15, blue = 25},
        text  = {font = 'Consolas', size = 10, red = 230, green = 230, blue = 230,
                 stroke = {width = 1, alpha = 200}},
        flags = {draggable = true},
        padding = 3,
    },
    ignore          = 'Archaic Gear,Archaic Gears',  -- never auto-target these names

}

local settings = config.load(defaults)
local box = texts.new(settings)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local S = {}

local function reset_floor_state()
    S.objective      = ''
    S.obj_type       = nil      -- 'enemy' | 'enemies' | 'leader' | 'all' | 'lamps' | 'free' | 'other'
    S.free_floor     = nil      -- no objective came: a free floor
    S.floor_clear    = false
    S.restriction    = ''
    S.restr_failed   = false
    S.pathos         = {}       -- {ws=true, magic=true, ja=true}
    S.penalties      = 0
    S.checks         = {}       -- [mob id] = 'it' | 'normal'
    S.names_seen     = {}       -- [name] = how many different mobs with that name we've seen this floor
    S.ids_seen       = {}
    S.check_tries    = {}
    S.pending        = {}       -- [mob id] = os.clock() of check we sent
    S.lamps          = {}       -- [slot 1..5] = {x, y, lit, flag_t, seen_t, floor}
    S.lamp_type      = nil      -- 'order' | 'same' | 'code'
    S.lamp_override  = nil      -- user-specified lamp count
    S.touched        = {}       -- [slot] = os.clock()  (simultaneous lamps)
    S.round          = {}       -- slots touched in the current order round
    S.game_round     = {}       -- lamps touched since the game last ended a round (in order)
    S.lamp_min       = nil      -- at least this many lamps (there are more than it has seen)
    S.rounds         = {}       -- {order = {...}, lit = {[slot]=bool} | nil}
    S.pending_eval   = nil      -- finished round waiting to be read
    S.plan           = nil      -- suggested order (kept until something changes)
    S.last_on_t      = nil      -- last time a lamp switched on
    S.last_touch     = nil
    S.rune           = nil      -- {x, y, index, approx}
    S.arrival        = nil
    S.aggro          = {}       -- [mob id] = os.clock() it last attacked / cast on you
    S.swung          = {}       -- [mob id] = os.clock() of your last melee round at it
    S.cool         = {}       -- [lamp slot] = os.clock() until it can be touched again
    S.same_plan      = nil      -- "all at once" lamps: {key, order}
    S.same_failed    = nil      -- os.clock() of the last failed "all at once" try
end

local function reset_run()
    S.in_nyzul     = false
    S.floor        = 0
    S.floor_id     = 0
    S.start_floor  = 0
    S.commenced    = false    -- "Commencing Nyzul Isle Investigation" seen this visit (the orders are used)
    S.got_tokens   = false    -- "You obtain N tokens" seen this visit (a run ended)
    S.tok_started  = false    -- this run's start counted for the token total
    S.completed    = 0
    S.tokens       = 0
    S.end_time     = nil
    S.floor_times  = {}       -- this run's floors: {floor, secs, obj} from arriving to arriving on the next
    S.party_size   = 1
    S.auto         = S.auto or false
    S.next_engage  = 0
    S.next_ws      = 0
    S.next_ja      = 0
    S.ja_note      = nil
    S.cor          = {last = nil, pending = nil, totals = {}}
    S.next_face    = 0
    S.next_check   = 0
    S.next_object  = 0
    S.next_request = 0
    S.last_object  = nil
    reset_floor_state()
end

S.has_armband = false
S.debug = false
S.auto = false
reset_run()

local ignore_set = {}
local function load_ignore()
    ignore_set = {}
    for name in tostring(settings.ignore or ''):gmatch('[^,]+') do
        ignore_set[name:match('^%s*(.-)%s*$')] = true
    end
end
load_ignore()

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
-- Chat output. The panel's \cs(r,g,b) colour codes only work in text boxes, not in the
-- chat log, so they're stripped here; warnings (anything that was red) use a red chat colour.
-- The same line is never repeated within 3 seconds, as a guard against any feedback loop.
local last_said = {msg = nil, t = -100}
local function say(msg)
    local warn = msg:find('\\cs%(255,80,80%)') ~= nil
    msg = msg:gsub('\\cs%(%d+,%d+,%d+%)', ''):gsub('\\cr', '')
    if msg == last_said.msg and os.clock() - last_said.t < 3 then return end
    last_said.msg, last_said.t = msg, os.clock()
    windower.add_to_chat(warn and 167 or 207, '[Nyzul] ' .. msg)
end

local function color(r, g, b, s)
    return string.format('\\cs(%d,%d,%d)%s\\cr', r, g, b, s)
end
local function green(s)  return color(80, 255, 80, s) end
local function yellow(s) return color(255, 240, 120, s) end
local function orange(s) return color(255, 165, 0, s) end
local function red(s)    return color(255, 80, 80, s) end
local function grey(s)   return color(160, 160, 160, s) end

-- Debug lines go to data/debug.log only. (They used to be echoed to chat too, but the
-- game hands addon chat lines back to 'incoming text', so the addon re-read its own echo.)
local function debug_log(msg)
    if not S.debug then return end
    local ok, f = pcall(io.open, windower.addon_path .. 'data/debug.log', 'a')
    if ok and f then
        f:write(os.date('%H:%M:%S ') .. msg .. '\n')
        f:close()
    end
end

local function in_nyzul()
    local info = windower.ffxi.get_info()
    return info and info.logged_in and info.zone == ZONE_NYZUL
end

local function me()
    return windower.ffxi.get_mob_by_target('me')
end

local function dist2d(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return math.sqrt(dx * dx + dy * dy)
end

local function is_gear(name)
    return name ~= nil and name:find('^Archaic Gear') ~= nil
end

local function lamp_slot(index)
    if index and index >= IDX_LAMP_FIRST and index <= IDX_LAMP_LAST then
        return index - IDX_LAMP_FIRST + 1
    end
end

local function letter(slot) return string.char(64 + slot) end

local function slot_from_letter(ch)
    local b = ch and ch:upper():byte()
    if b and b >= 65 and b <= 69 then return b - 64 end
end

-- Direction of target relative to where you're facing, as a clock position (12 = straight ahead).
-- FFXI facing: 0 = east, increasing clockwise; so heading in math terms = -facing.
local function clock_dir(from, to)
    local theta = math.atan2(to.y - from.y, to.x - from.x)
    local rel = -(theta + (from.facing or 0))
    rel = rel % (2 * math.pi)
    local hour = math.floor(rel / (math.pi / 6) + 0.5) % 12
    if hour == 0 then hour = 12 end
    return hour
end

-- Map/compass direction (N is up on the in-game map). FFXI: +x = east, +y = north.
local COMPASS = {'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'}
local function compass_dir(from, to)
    local theta = math.atan2(to.y - from.y, to.x - from.x)       -- counter-clockwise from east
    local bearing = (math.pi / 2 - theta) % (2 * math.pi)        -- clockwise from north
    return COMPASS[math.floor(bearing / (math.pi / 4) + 0.5) % 8 + 1]
end

-- settings.directions: 'compass' (N/NE/E...), 'clock' (12 = where you're facing), or 'both'
local function where(from, to)
    if not from or not to then return '?' end
    local d = math.floor(dist2d(from, to) + 0.5)
    local mode = settings.directions
    if mode == 'clock' then
        return ('%dy %d o\'clock'):format(d, clock_dir(from, to))
    elseif mode == 'both' then
        return ('%dy %s (%d o\'clock)'):format(d, compass_dir(from, to), clock_dir(from, to))
    end
    return ('%dy %s'):format(d, compass_dir(from, to))
end

local function fmt_time(sec)
    sec = math.max(0, math.floor(sec))
    return string.format('%02d:%02d', math.floor(sec / 60), sec % 60)
end

local function time_left()
    if not S.end_time then return nil end
    return S.end_time - os.time()
end

local function set_timer(seconds)
    S.end_time = os.time() + seconds
end

---------------------------------------------------------------------------
-- Tokens (formula from NyzulHelper)
---------------------------------------------------------------------------
local function relative_floor()
    if S.floor < S.start_floor then return S.floor + 100 end
    return S.floor
end

local function token_rate()
    local rate = 1
    if S.has_armband then rate = rate + 0.1 end
    if S.party_size > 3 then rate = rate - (S.party_size - 3) * 0.1 end
    return rate
end

-- Each "Potential token reward reduced" halves that floor's tokens. (A floors 56-61 run in testing:
-- the game paid 1886 = 5 x 341 + 352 - 171, i.e. the penalised floor paid half of 341.)
local function add_floor_tokens()
    local rel = relative_floor()
    local rate = token_rate()
    local bonus = rel > 1 and 10 * math.floor((rel - 1) / 5) or 0
    local amount = math.floor((200 + bonus) * rate + 0.5)
    for _ = 1, S.penalties do amount = math.floor(amount / 2) end
    S.tokens = S.tokens + amount
end

---------------------------------------------------------------------------
-- Objective classification
---------------------------------------------------------------------------
local function classify_objective(text)
    local t = text:lower()
    if t:find('specified enemies') then return 'enemies' end
    if t:find('specified enemy') then return 'enemy' end
    if t:find('enemy leader') then return 'leader' end
    if t:find('all enemies') then return 'all' end
    if t:find('lamp') then return 'lamps' end
    return 'other'
end

local OBJECTIVE_LABEL = {
    enemies = 'Kill specified enemies (impossible to gauge)',
    enemy   = 'Kill specified enemy (impossible to gauge)',
    leader  = 'Kill the enemy leader',
    all     = 'Kill all enemies (gears don\'t count)',
    lamps   = 'Activate all lamps',
    free    = 'Free floor - just take the Rune of Transfer',
}

local function is_boss_floor()
    return S.floor > 0 and S.floor % 20 == 0
end

---------------------------------------------------------------------------
-- Lamp order puzzle solver (pure functions; unit-tested)
-- Each round you activate every lamp once. Lamps activated in the correct
-- position stay lit. So each round gives, per lamp, "right slot" or "wrong slot".
---------------------------------------------------------------------------
local Solver = {}
local lamp_switched_on      -- defined in the Lamps section
local lamp_late_reading     -- defined in the Lamps section
local check_armband         -- defined with the zone events
local next_lamp_slot        -- defined with the semi-auto actions
local FAX = {}
FAX.X = {}                  -- more //nz commands, each a function(args): see the sections that add them

-- rounds: { {order = {slotA, slotB, ...}, lit = {[slot] = true/false}} , ... }  (lit may be nil = unknown)
-- slots : list of lamp slots in play, e.g. {1,2,3,4}
function Solver.knowledge(slots, rounds)
    local n = #slots
    local in_play, possible, confirmed = {}, {}, {}
    for _, s in ipairs(slots) do
        in_play[s] = true
        possible[s] = {}
        for p = 1, n do possible[s][p] = true end
    end
    for _, r in ipairs(rounds) do
        if r.lit then
            for pos, s in ipairs(r.order) do
                if in_play[s] and pos <= n then
                    if r.lit[s] then
                        confirmed[s] = pos
                    else
                        possible[s][pos] = false
                    end
                end
            end
        end
    end
    -- propagate until stable
    local changed = true
    local guard = 0
    while changed and guard < 50 do
        changed, guard = false, guard + 1
        for s, pos in pairs(confirmed) do
            for p = 1, n do
                if p ~= pos and possible[s][p] then possible[s][p] = false; changed = true end
            end
            for _, o in ipairs(slots) do
                if o ~= s and possible[o][pos] then possible[o][pos] = false; changed = true end
            end
        end
        for _, s in ipairs(slots) do
            if not confirmed[s] then
                local only, cnt = nil, 0
                for p = 1, n do if possible[s][p] then only, cnt = p, cnt + 1 end end
                if cnt == 1 then confirmed[s] = only; changed = true end
            end
        end
        for p = 1, n do
            local only, cnt = nil, 0
            for _, s in ipairs(slots) do if possible[s][p] then only, cnt = s, cnt + 1 end end
            if cnt == 1 and not confirmed[only] then confirmed[only] = p; changed = true end
        end
    end
    return possible, confirmed
end

-- All orders consistent with what we know. Returns list of {slot at pos1, slot at pos2, ...}
function Solver.candidates(slots, rounds)
    local possible = Solver.knowledge(slots, rounds)
    local n, out, perm, used = #slots, {}, {}, {}
    local function bt(p)
        if p > n then
            local copy = {}
            for i = 1, n do copy[i] = perm[i] end
            out[#out + 1] = copy
            return
        end
        for _, s in ipairs(slots) do
            if not used[s] and possible[s][p] then
                used[s], perm[p] = true, s
                bt(p + 1)
                used[s] = false
            end
        end
    end
    bt(1)
    return out
end

-- Best next order: consistent with all feedback, shortest straight-line walk from `start`.
-- Walking cost of visiting lamps in this order from `start` (straight lines).
local function walk_cost(order, from_i, positions, start)
    local cost, cur = 0, start
    for i = from_i, #order do
        local p = positions and positions[order[i]]
        if cur and p then cost = cost + dist2d(cur, p) end
        if p then cur = p end
    end
    return cost
end

-- Best next order: consistent with all feedback, starting with the lamps already
-- touched this round (`prefix`), then the shortest walk from `start`.
-- Returns order, number of orders still possible overall.
function Solver.plan(slots, rounds, positions, start, prefix)
    prefix = prefix or {}
    local all = Solver.candidates(slots, rounds)
    local function fits(order)
        for i, s in ipairs(prefix) do if order[i] ~= s then return false end end
        return true
    end
    local cands = {}
    for _, order in ipairs(all) do if fits(order) then cands[#cands + 1] = order end end

    if #cands == 0 and #prefix > 0 then
        -- This round already went off-plan: finish it with the remaining lamps in a
        -- shortest-walk order (it still tells us something about those lamps).
        local used, rest = {}, {}
        for _, s in ipairs(prefix) do used[s] = true end
        for _, s in ipairs(slots) do if not used[s] then rest[#rest + 1] = s end end
        local order = {}
        for i, s in ipairs(prefix) do order[i] = s end
        local cur = start
        while #rest > 0 do
            local bi, bd = 1, math.huge
            for i, s in ipairs(rest) do
                local p = positions and positions[s]
                local d = (cur and p) and dist2d(cur, p) or 0
                if d < bd then bi, bd = i, d end
            end
            local s = table.remove(rest, bi)
            order[#order + 1] = s
            cur = positions and positions[s] or cur
        end
        return order, #all
    end
    if #cands == 0 then return nil, 0 end

    local best, best_cost = cands[1], math.huge
    for _, order in ipairs(cands) do
        local cost = walk_cost(order, #prefix + 1, positions, start)
        if cost < best_cost then best, best_cost = order, cost end
    end
    return best, #all
end

---------------------------------------------------------------------------
-- Lamps
---------------------------------------------------------------------------
local function lamps_seen()
    local n = 0
    for slot = 1, 5 do
        local l = S.lamps[slot]
        if l and l.floor == S.floor_id then n = math.max(n, slot) end
    end
    for _, s in ipairs(S.round) do n = math.max(n, s) end
    return n
end

-- Lamps are A, B, C... in order, so the count is the last letter seen - but one too far away
-- to have been seen yet doesn't count. An in-order floor always has more than one, and when
-- the game says there are more (see more_lamps), there are more.
local function lamp_count()
    if S.lamp_override then return S.lamp_override end
    local n = lamps_seen()
    if S.lamp_type == 'order' then n = math.max(n, 2) end
    return math.min(5, math.max(n, S.lamp_min or 0))
end

-- There are more lamps than it has counted: the round it thought was over isn't (nothing lit
-- up), or the game said "Not all lights have been activated" when it touched one again. Keep
-- the game's round going and go and find the rest.
local function more_lamps(why)
    local n = lamp_count()
    if n >= 5 then return end
    S.lamp_min = n + 1
    S.pending_eval = nil
    S.round = {}
    for i, sl in ipairs(S.game_round) do S.round[i] = sl end
    for i = #S.rounds, 1, -1 do                      -- (rounds read with too few lamps don't count)
        if #S.rounds[i].order < S.lamp_min then table.remove(S.rounds, i) end
    end
    S.plan = nil
    debug_log(('lamps: more than %d (%s) - looking for the rest'):format(n, why))
    say(orange('There are more lamps than I\'ve found') .. (' (%s). At least %d - looking for the rest.'):format(why, S.lamp_min))
end

local function lamp_slots()
    local slots = {}
    for i = 1, lamp_count() do slots[i] = i end
    return slots
end

local function lamp_positions()
    local pos = {}
    for slot, l in pairs(S.lamps) do
        if l.floor == S.floor_id and l.x then pos[slot] = {x = l.x, y = l.y} end
    end
    return pos
end

local function record_lamp(slot, x, y)
    local l = S.lamps[slot] or {}
    S.lamps[slot] = l
    if x and y and not (x == 0 and y == 0) then
        l.x, l.y = x, y
        l.floor = S.floor_id
        l.seen_t = os.clock()
    end
    return l
end

-- "All at once" lamps, solo: a lamp you touch lights and stays lit about 5 minutes. If they
-- weren't all lit close enough together, the game says "some other action appears to be
-- necessary"; once a lamp goes out it can't be touched again for ~30s. So touch them in the
-- order with the shortest run from the first to the last, and only start when all are ready.
local Same = {LIT = 300, COOL = 30}

-- seconds until this lamp can be touched again (0 = now)
function Same.ready_in(slot)
    local l = S.lamps[slot]
    local now = os.clock()
    local wait = 0
    if l and l.lit then
        wait = (l.lit_t or now) + Same.LIT + Same.COOL - now
    elseif l and l.dark_t then
        wait = l.dark_t + Same.COOL - now
    end
    if S.cool[slot] then wait = math.max(wait, S.cool[slot] - now) end
    return math.max(0, wait)
end

-- lit (or touched) during the try that's under way
function Same.done(slot)
    local l = S.lamps[slot]
    local now = os.clock()
    if S.touched[slot] and now - S.touched[slot] < 60 then return true end
    return l and l.lit and l.lit_t and now - l.lit_t < Same.LIT and not S.same_failed or false
end

function Same.plan()
    local slots = {}
    for slot = 1, lamp_count() do
        local l = S.lamps[slot]
        if l and l.x and l.floor == S.floor_id then slots[#slots + 1] = slot end
    end
    if #slots == 0 then return nil end
    local key = table.concat(slots, ',')
    if S.same_plan and S.same_plan.key == key then return S.same_plan.order end
    local m = me()
    local best, bc
    local function try(order)
        local c = 0
        for i = 2, #order do c = c + dist2d(S.lamps[order[i - 1]], S.lamps[order[i]]) end
        if m then c = c + 0.01 * dist2d(m, S.lamps[order[1]]) end    -- (ties: start nearest you)
        if not bc or c < bc then best, bc = {unpack(order)}, c end
    end
    local function perm(cur, used)
        if #cur == #slots then try(cur) return end
        for _, sl in ipairs(slots) do
            if not used[sl] then
                used[sl] = true; cur[#cur + 1] = sl
                perm(cur, used)
                cur[#cur] = nil; used[sl] = false
            end
        end
    end
    perm({}, {})
    S.same_plan = {key = key, order = best}
    return best
end

function Same.letters()
    local order = Same.plan()
    if not order then return nil end
    local t = {}
    for i, sl in ipairs(order) do t[i] = letter(sl) end
    return table.concat(t, ' > ')
end

-- next lamp to touch, or nil and the seconds until the next try can start
function Same.next()
    local order = Same.plan()
    if not order then return nil end
    local started = false
    for _, sl in ipairs(order) do if Same.done(sl) then started = true end end
    if started then
        for _, sl in ipairs(order) do
            if not Same.done(sl) then return sl end
        end
        return nil                                  -- all done: waiting on the game
    end
    local wait = 0
    for _, sl in ipairs(order) do wait = math.max(wait, Same.ready_in(sl)) end
    if wait > 0 then return nil, wait end
    S.same_failed = nil
    return order[1]
end

-- The suggested order is worked out once (from where you are at that moment) and then
-- kept, so it doesn't reshuffle as you walk. It's redone only when something changes:
-- new feedback, more lamps found, or you touch a lamp other than the suggested one.
local function plan_key()
    return ('%d|%d|%s'):format(lamp_count(), #S.rounds, table.concat(S.round, ','))
end

local function current_plan()
    if S.lamp_type ~= 'order' or lamp_count() == 0 then return nil, 0 end
    local P = S.plan
    if P and P.n == lamp_count() and P.rounds == #S.rounds then
        local ok = true
        for i, s in ipairs(S.round) do if P.order[i] ~= s then ok = false break end end
        if ok then return P.order, P.cands end
    end
    local m = me()
    local order, cands = Solver.plan(lamp_slots(), S.rounds, lamp_positions(), m and {x = m.x, y = m.y}, S.round)
    S.plan = order and {order = order, cands = cands, n = lamp_count(), rounds = #S.rounds} or nil
    return order, cands
end

local function describe_round(r)
    local parts = {}
    for _, s in ipairs(r.order) do
        local mark = r.lit == nil and '?' or (r.lit[s] and '+' or '-')
        parts[#parts + 1] = letter(s) .. mark
    end
    return table.concat(parts, ' ')
end

local function evaluate_round(order, t_end)
    local slots = lamp_slots()
    local _, confirmed = Solver.knowledge(slots, S.rounds)
    local lit, unknown = {}, {}
    for pos, s in ipairs(order) do
        local l = S.lamps[s]
        local fresh = l and l.flag_t and l.flag_t >= t_end - 0.25
        local left_view = l and l.gone_t and l.flag_t and l.gone_t > l.flag_t
        if fresh and (not l.lit or not left_view) then
            lit[s] = l.lit and true or false
        elseif l and l.lit and l.flag_t and not left_view then
            -- Lit before the round ended and in view since: a lamp that's already lit gets no
            -- update when it stays lit, so no news means it stayed on (right spot this round).
            lit[s] = true
        elseif confirmed[s] == pos then
            lit[s] = true
        else
            unknown[#unknown + 1] = letter(s)
        end
    end
    local r = {order = order, lit = (#unknown == 0) and lit or nil, guess = lit, t_end = t_end}
    S.rounds[#S.rounds + 1] = r
    if #unknown > 0 then
        say(('Round %d done. Couldn\'t see lamp(s) %s from here - walk past them and I\'ll fill them in, '
            .. 'or type //nz lit <letters that stayed ON> (e.g. //nz lit AC).')
            :format(#S.rounds, table.concat(unknown, ',')))
    else
        say(('Round %d: %s'):format(#S.rounds, describe_round(r)))
        local plan, n = current_plan()
        if plan then
            local letters = {}
            for i, s in ipairs(plan) do letters[i] = letter(s) end
            say(('Next try: %s  (%d possible order%s left)'):format(table.concat(letters, ' > '), n, n == 1 and '' or 's'))
        elseif #S.rounds > 0 then
            say('Lamp data conflicts. Use //nz lamps reset and start a fresh round.')
        end
    end
end

local function on_lamp_touch(slot)
    S.last_touch = {slot = slot, t = os.clock()}
    S.touched[slot] = os.clock()
    if S.lamp_type == 'code' or S.lamp_type == 'same' then return end
    for _, s in ipairs(S.round) do
        if s == slot then return end
    end
    S.round[#S.round + 1] = slot
    local known = false
    for _, s in ipairs(S.game_round) do if s == slot then known = true end end
    if not known then S.game_round[#S.game_round + 1] = slot; S.last_touch.game_new = true end
    debug_log(('lamp touch %s, round so far %d/%d'):format(letter(slot), #S.round, lamp_count()))
    local n = lamp_count()
    -- (never a round of one: the first touch can come before the game says what kind of lamps
    -- they are, and "in order" means two or more - one test run read a "round" of lamp A
    -- alone, couldn't make sense of it and stopped)
    if n >= 2 and #S.round >= n then
        -- Wait until the Yes/No menu is closed, then give the lamps a few seconds to change.
        S.pending_eval = {order = S.round, touched_at = os.clock()}
        S.round = {}
    end
end

local function undo_last_touch()
    local lt = S.last_touch
    if not lt or os.clock() - lt.t > 60 then return end
    S.touched[lt.slot] = nil
    if lt.game_new and S.game_round[#S.game_round] == lt.slot then table.remove(S.game_round) end
    local pe = S.pending_eval
    if pe and pe.order[#pe.order] == lt.slot then
        table.remove(pe.order)
        S.round = pe.order
        S.pending_eval = nil
    elseif S.round[#S.round] == lt.slot then
        table.remove(S.round)
    end
    S.last_touch = nil
    debug_log('lamp touch undone (event skipped): ' .. letter(lt.slot))
end

local function lamp_eval_tick()
    local pe = S.pending_eval
    if not pe then return end
    local now = os.clock()
    if not pe.armed then
        local player = windower.ffxi.get_player()
        -- status 4 = in an event/menu
        if player and player.status ~= 4 and now - pe.touched_at > 1 then pe.armed = now end
        return
    end
    -- After the last lamp, every lamp lights up a few seconds later and the wrong ones
    -- switch off about 7 seconds after that. Read them once that has settled.
    local settled = not S.last_on_t or S.last_on_t < pe.touched_at or now - S.last_on_t >= 11
    if now - pe.touched_at >= settings.lamp_read_wait and settled then
        S.pending_eval = nil
        if S.lamp_type == 'order' or S.lamp_type == nil then
            evaluate_round(pe.order, pe.touched_at)
        end
    end
end

-- Order lamps only light up when a round is finished. If that happens before we've seen
-- every touch of the round (a touch happened while the addon wasn't watching), the
-- positions we recorded are unreliable, so drop that round instead of learning wrong things.
-- After a round, lamps stay as they ended (right ones lit, wrong ones dark) until your next
-- touch. So a lamp we couldn't see at reading time can be filled in when you walk past it.
lamp_late_reading = function(slot, lit)
    local r = S.rounds[#S.rounds]
    if not r or r.lit or S.lamp_type ~= 'order' or S.pending_eval then return end
    -- Touching lamps doesn't light them (only finishing a round does), so a lamp you haven't
    -- touched again this round still shows how the last round ended - even mid-round.
    for _, s in ipairs(S.round) do if s == slot then return end end
    local in_round = false
    for _, s in ipairs(r.order) do if s == slot then in_round = true end end
    if not in_round then return end
    r.guess = r.guess or {}
    if r.guess[slot] == lit then return end
    r.guess[slot] = lit
    debug_log(('late lamp reading: %s %s'):format(letter(slot), lit and 'lit' or 'dark'))
    for _, s in ipairs(r.order) do if r.guess[s] == nil then return end end
    r.lit = r.guess
    S.plan = nil
    say(('Round %d (filled in as you walked by): %s'):format(#S.rounds, describe_round(r)))
    local plan, n = current_plan()
    if plan then
        local letters = {}
        for i, s in ipairs(plan) do letters[i] = letter(s) end
        say(('Next try: %s  (%d possible order%s left)'):format(table.concat(letters, ' > '), n, n == 1 and '' or 's'))
    end
end

lamp_switched_on = function(slot)
    S.last_on_t = os.clock()
    if S.lamp_type == 'order' then S.game_round = {} end       -- (lamps light up when the game ends a round)
    if S.lamp_type ~= 'order' or S.pending_eval or #S.round == 0 then return end
    if S.lamp_min and #S.round < lamp_count() and #S.round >= 2 then
        -- it thought there were more lamps, but the game ended the round: there weren't
        debug_log(('lamps: the round ended after %d - there are only %d'):format(#S.round, #S.round))
        S.lamp_min = nil
        if #S.round >= lamp_count() then
            S.pending_eval = {order = S.round, touched_at = S.last_touch and S.last_touch.t or os.clock()}
            S.round = {}
            return
        end
    end
    if #S.round < lamp_count() then
        debug_log(('lamps lit after only %d of %d touches - round dropped'):format(#S.round, lamp_count()))
        say(('That round ended after I saw only %d of %d lamps - ignoring it. Your next touch starts a new round.')
            :format(#S.round, lamp_count()))
        S.round = {}
        S.plan = nil
    end
end

---------------------------------------------------------------------------
-- Rune of Transfer
---------------------------------------------------------------------------
-- You arrive next to the floor's Rune of Transfer, so the rune nearest your arrival
-- point is the one to go back to. Any entity index is accepted.
local function find_rune_near(pt, maxd)
    local best, bd
    for _, mob in pairs(windower.ffxi.get_mob_array()) do
        if mob.name == 'Rune of Transfer' and not (mob.x == 0 and mob.y == 0) then
            local d = dist2d(pt, mob)
            if d <= maxd and (not bd or d < bd) then best, bd = mob, d end
        end
    end
    return best, bd
end

local function rune_tick()
    if S.floor == 0 or not S.arrival or (S.rune and not S.rune.approx) then return end
    local r, d = find_rune_near(S.arrival, 35)
    if r then
        S.rune = {x = r.x, y = r.y, index = r.index}
        debug_log(('rune found: index %d at %.1f,%.1f (%.1fy from arrival)'):format(r.index, r.x, r.y, d))
    elseif not S.rune then
        S.rune = {x = S.arrival.x, y = S.arrival.y, approx = true}
        debug_log('rune not visible yet - using arrival point')
    end
end

---------------------------------------------------------------------------
-- Floor / run events
---------------------------------------------------------------------------
local floor_cleared        -- defined just below

local function new_floor(n)
    if n == S.floor and S.floor_t and os.clock() - S.floor_t < 30 then return end   -- duplicate line
    -- You can only transfer up once the floor is done. If we never saw its "objective
    -- complete" line (it sometimes doesn't show), count it now so tokens stay right.
    if S.floor > 0 and not S.floor_clear and (n == S.floor + 1 or (S.floor == 100 and n == 1)) then
        debug_log(('floor %d clear (worked out from the transfer to %d)'):format(S.floor, n))
        floor_cleared()
    end
    -- how long that floor took, arriving to arriving here (for when to leave: see FA.leave_need)
    if S.floor > 0 and S.floor_t and (n == S.floor + 1 or (S.floor == 100 and n == 1)) then
        local secs = os.clock() - S.floor_t
        S.floor_times = S.floor_times or {}
        S.floor_times[#S.floor_times + 1] = {floor = S.floor, secs = secs, obj = S.obj_type}
        debug_log(('floor %d took %s (%s)'):format(S.floor, fmt_time(secs), tostring(S.obj_type)))
    end
    S.floor = n
    S.floor_id = S.floor_id + 1
    if S.start_floor == 0 then
        S.start_floor = n
        if not S.end_time then set_timer(RUN_SECONDS) end
        -- (a run that started here, not one picked up after a reload or //nz reset)
        if FAX.FA and S.commenced and not S.tok_started then
            S.tok_started = true
            FAX.Core.tok_run_started(n)
            FAX.FA.climb_run_started(n)
        end
    end
    local done = relative_floor() - S.start_floor
    if done > S.completed then S.completed = done end
    -- lamp packets for the new floor can arrive just before the "Welcome" line; keep those
    local fresh = {}
    for slot, l in pairs(S.lamps) do
        if l.seen_t and os.clock() - l.seen_t < 3 then
            l.floor = S.floor_id
            fresh[slot] = l
        end
    end
    reset_floor_state()
    S.lamps = fresh
    S.floor_t = os.clock()
    if FAX.FA then
        FAX.Menus.rune_outcome('floor')
        FAX.FA.retries_used = 0                 -- (a fresh floor: it may try again after problems here)
        if FAX.FA.retry then FAX.FA.retry.n = 1 end
        FAX.FA.new_floor()
        FAX.Loop.stop_record('you arrived on floor ' .. n)
    end
    -- read your position a moment after the transfer, once it has surely updated
    local fid = S.floor_id
    coroutine.schedule(function()
        if S.floor_id ~= fid then return end
        local m = me()
        if m then
            S.arrival = {x = m.x, y = m.y}
            debug_log(('arrival point %.1f,%.1f (map %s)'):format(m.x, m.y, FAX.Nav and FAX.Nav.map_id() or '?'))
            rune_tick()
        end
    end, 1.5)
end

floor_cleared = function()
    if S.floor_clear then return end
    S.floor_clear = true
    S.next_ja = math.max(S.next_ja or 0, os.clock() + 2)   -- let the kill finish before rolling
    S.completed = S.completed + 1
    add_floor_tokens()
    FAX.Core.stat_floor()
    -- (the floor's gear rule still holds after the objective's done: destroying a gear on a
    -- "Do not destroy archaic gears!" floor after the clear cost you "Potential token reward
    -- reduced" three times in one session - it had forgotten the rule at the clear)
end

local function parse_pathos(text)
    local t = text:lower()
    if t:find('weapon ?skill') then S.pathos.ws = true end
    if t:find('magic') or t:find('spell') then S.pathos.magic = true end
    if t:find('job abilit') or t:find('abilities') then S.pathos.ja = true end
end

local function handle_system_text(text, mode)
    -- floor arrival
    local f = text:match('Welcome to Floor (%d+)')
    if f then
        new_floor(tonumber(f))
        debug_log('floor ' .. f)
        return
    end

    if text:find('Commencing Nyzul Isle Investigation', 1, true) then S.commenced = true end
    if text:find('Objective:') then
        local obj = text:match('Objective:%s*(.-)%s*$') or text
        if obj:lower():find('commencing') then return end   -- lobby message
        S.objective = obj
        S.obj_type = classify_objective(obj)
        debug_log('objective: ' .. obj .. ' -> ' .. tostring(S.obj_type))
        if S.free_floor then
            -- it wasn't a free floor after all (the objective came late): undo that
            S.free_floor, S.floor_clear = nil, false
            S.completed = math.max(0, S.completed - 1)
            S.tokens = S.tokens_before_free or S.tokens
            debug_log('objective came late - not a free floor after all')
        end
        return
    end

    if text:find('Rune of Transfer activated') or text:find('objective complete') then
        floor_cleared()
        debug_log('floor clear')
        return
    end

    if text:find('Security field malfunction') then
        S.restr_failed = true
        parse_pathos(text)
        say(red('Rule broken (' .. (S.restriction ~= '' and S.restriction or 'archaic gear') .. ') - expect a Pathos penalty.'))
        debug_log('rule broken: ' .. text)
        return
    end

    local mins = text:match('Time limit has been reduced by (%d+) minute')
    if mins then
        if S.end_time then S.end_time = S.end_time - tonumber(mins) * 60 end
        return
    end

    local got = text:match('You obtain (%d+) tokens')
    if got then
        debug_log(('tokens: game gave %s, panel estimated %d (%d floors, armband %s, rate %.2f)'):format(
            got, S.tokens, S.completed, tostring(S.has_armband), token_rate()))
        S.tokens = tonumber(got)
        S.got_tokens = true
        FAX.Core.tok_earned(S.tokens)
        FAX.FA.climb_run_paid()
        return
    end

    if text:find('Potential token reward reduced') then
        S.penalties = S.penalties + 1
        return
    end

    if text:find('Earth time') or text:find('Time remaining') then
        local num = tonumber(text:match('(%d+)'))
        if num then
            local mult = text:find('minute') and 60 or 1
            set_timer(num * mult)
        end
        return
    end

    if (mode == 148 or mode == 146 or mode == 123) and text:lower():find('archaic gear') then
        S.restriction = text
        debug_log(('rule [mode %d]: %s'):format(mode, text))
        return
    end

    -- lamps
    if text:find('specific order') or text:find('specified order') then
        if S.lamp_type ~= 'order' then debug_log('lamp type: order') end
        S.lamp_type = 'order'
    elseif text:find('at the same time') then
        S.lamp_type = 'same'
    elseif text:find('certification code') then
        S.lamp_type = 'code'
    elseif text:find('some other action appears to be necessary') then
        -- every lamp is lit, but they weren't lit close enough together
        if S.lamp_type == 'same' then
            S.touched = {}
            local first = not S.same_failed or os.clock() - S.same_failed > 60
            S.same_failed = os.clock()
            if first then
                local order = Same.letters()
                say(('All lamps lit, but not close enough together. They stay lit about 5 minutes, then can be touched again '
                    .. '30 seconds after going out. Next try%s: touch them back to back.')
                    :format(order and (' ' .. order) or ''))
                say(orange('Solo tip: ') .. 'these lamps are meant for a party; solo it only works if you can run between them quickly.')
            end
        end
    elseif text:find('Not all lights have been activated') then
        -- touched a lamp that's already on in this round, after touching every lamp it knows
        -- of: the game's round needs lamps it hasn't found
        local lt = S.last_touch
        if S.lamp_type == 'order' and lt and os.clock() - lt.t < 10 and not S.lamp_override
           and #S.game_round >= lamp_count() then
            more_lamps('the game says not all are lit')
        end
    elseif text:find('cannot activate this lamp for some time') then
        local lt = S.last_touch
        if lt and os.clock() - lt.t < 10 then
            S.cool[lt.slot] = os.clock() + 10
            undo_last_touch()                       -- it didn't take
            debug_log('lamp ' .. letter(lt.slot) .. ' is cooling down')
        end
    elseif text:find('Event skipped') then
        undo_last_touch()
    end
end

---------------------------------------------------------------------------
-- Targets
---------------------------------------------------------------------------
-- returns priority (lower = better) and a short label, or nil if not a target
local function target_reason(m, my_id)
    if m.spawn_type ~= SPAWN_MONSTER or not m.valid_target or (m.hpp or 0) <= 0 then return nil end
    if m.status ~= 0 and m.status ~= 1 then return nil end
    -- After you: claimed by you, it hit / used a move / cast on you in the last 20 seconds,
    -- or (solo) it's in combat at all - in your own instance that can only be with you.
    local after_me = false
    if settings.defend and my_id then
        local hit = S.aggro and S.aggro[m.id]
        after_me = m.claim_id == my_id or (hit and os.clock() - hit < 20)
                   or (m.status == 1 and (m.claim_id or 0) == 0 and S.party_size <= 1 and S.in_nyzul)
    end
    if is_gear(m.name) then
        -- gears only when one's attacking you and the rule doesn't forbid destroying them
        if after_me and not S.restriction:lower():find('destroy') then return 0, 'on you' end
        return nil
    end
    if ignore_set[m.name] then return nil end
    if after_me then return 0, 'on you' end
    -- Archaic Ramparts check "impossible to gauge" but don't count for specified enemy /
    -- leader floors (a floor 59 in testing cleared without it). On "kill all enemies" floors they do.
    if m.name:find('^Archaic') then
        if S.obj_type == 'all' and not S.floor_clear then return 3, 'enemy' end
        return nil
    end
    if S.floor_clear then return nil end

    local it = S.checks[m.id] == 'it'
    local nm = is_nm_name(m.name)
    local ot = S.obj_type
    if ot == 'leader' then
        if LEADERS[m.name] then return 1, 'leader' end
        if is_boss_floor() then
            if BOSSES[m.name] then return 1, 'boss' end
            if not FLOOR_NMS[m.name] then return 3, 'boss?' end
        end
        if it and not FLOOR_NMS[m.name] then return 2, 'IT' end
    elseif ot == 'enemy' then
        -- the target is a normal mob that checks IT; named NMs check IT too but don't count.
        -- An IT mob with a same-name twin on the floor is a sure thing.
        if it and not nm then
            if S.names_seen[m.name] and S.names_seen[m.name] > 1 then return 1, 'IT' end
            return 2, 'IT'
        end
    elseif ot == 'enemies' then
        if it and not nm then return 1, 'IT' end
        if FAMILIES[m.name] then return 2, 'family' end
    elseif ot == 'all' then
        return 3, 'enemy'
    end
    return nil
end

local function find_targets(limit)
    local player = windower.ffxi.get_player()
    local my_id = player and player.id
    local list = {}
    for _, m in pairs(windower.ffxi.get_mob_array()) do
        if m.spawn_type == SPAWN_MONSTER and m.name and not S.ids_seen[m.id] then
            S.ids_seen[m.id] = true
            S.names_seen[m.name] = (S.names_seen[m.name] or 0) + 1
        end
        local prio, why = target_reason(m, my_id)
        if prio then
            list[#list + 1] = {mob = m, prio = prio, why = why, dist = math.sqrt(m.distance or 0)}
        end
    end
    table.sort(list, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.dist < b.dist
    end)
    if limit then
        while #list > limit do table.remove(list) end
    end
    return list
end

local function gear_info()
    local count, nearest, nd = 0, nil, nil
    for _, m in pairs(windower.ffxi.get_mob_array()) do
        if m.spawn_type == SPAWN_MONSTER and is_gear(m.name) and (m.hpp or 0) > 0 and m.valid_target then
            count = count + 1
            local d = math.sqrt(m.distance or 0)
            if not nd or d < nd then nearest, nd = m, d end
        end
    end
    return count, nearest, nd
end

local function check_stats()
    local checked, it = 0, 0
    for _, v in pairs(S.checks) do
        checked = checked + 1
        if v == 'it' then it = it + 1 end
    end
    return checked, it
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
-- Client-side target change (same technique as Windower's SetTarget addon).
local function set_target(mob)
    local player = windower.ffxi.get_player()
    if not player or not mob then return end
    packets.inject(packets.new('incoming', 0x058, {
        ['Player']       = player.id,
        ['Target']       = mob.id,
        ['Player Index'] = player.index,
    }))
end

local function engage(mob)
    set_target(mob)
    local ea = {id = mob.id, t = os.clock()}
    S.engaged_at = ea
    S.engaging_until = os.clock() + 4      -- no idle rolls while you're going in
    S.next_ja = math.max(S.next_ja or 0, os.clock() + 2)
    local id, name, tries = mob.id, mob.name, 0
    -- Your target has to be on it before /attack <t> goes. Right after a kill the game can
    -- move your target back, and then nothing
    -- went out at all and you stood there until the next try a few seconds later: point it
    -- again, a few times.
    local function go()
        if S.engaged_at ~= ea or not S.auto then return end         -- (something else engaged since)
        local t = windower.ffxi.get_mob_by_target('t')
        if t and t.id == id then
            ea.sent = os.clock()
            windower.send_command('input /attack <t>')
            return
        end
        tries = tries + 1
        local mm = windower.ffxi.get_mob_by_id(id)
        if tries == 2 and t and t.spawn_type ~= SPAWN_MONSTER and mm and mm.valid_target then
            -- <t> stuck on an NPC: your first floor of the day kept it on Naiel (from the floor
            -- transfer) through four tries and two engages, 20 seconds. Off her first.
            local mine = me()
            if mine then set_target(mine) end
            coroutine.schedule(function() if S.engaged_at == ea then set_target(mm) end end, 0.15)
            coroutine.schedule(go, 0.45)
            return
        end
        if tries >= 4 or not mm or (mm.hpp or 0) == 0 or not mm.valid_target then
            ea.failed = os.clock()
            debug_log(('engage: couldn\'t get your target onto %s - no /attack (target: %s%s)'):format(tostring(name),
                t and tostring(t.name) or 'none', not mm and ', gone' or not mm.valid_target and ', can\'t be targeted now'
                or (mm.hpp or 0) == 0 and ', dead' or (', %.0fy'):format(math.sqrt(mm.distance or 0))))
            return
        end
        set_target(mm)
        coroutine.schedule(go, 0.3)
    end
    coroutine.schedule(go, 0.4)
end

local function face(target, tol)
    local m = me()
    if not m or not target then return end
    local want = -math.atan2(target.y - m.y, target.x - m.x)
    local diff = (want - (m.facing or 0) + math.pi) % (2 * math.pi) - math.pi
    if math.abs(diff) > (tol or 0.35) then
        windower.ffxi.turn(want)
    end
end

-- Which weaponskill: the boss WS on boss floors; the backup WS on mobs your WS heals (an
-- Aeolian Edge heals wind-absorbing mobs like Cumin Custard and Puks) and instead of an
-- area WS when an Archaic Gear is next to the target (it would hit the gear too).
local WS = {AOE = {['aeolian edge'] = true, ['cyclone'] = true, ['circle blade'] = true, ['shockwave'] = true,
                   ['spinning attack'] = true, ['earth crusher'] = true, ['cataclysm'] = true, ['fell cleave'] = true,
                   ['spinning scythe'] = true}}

function WS.is_aoe(name) return name ~= nil and WS.AOE[name:lower()] == true end

-- Entries are "Mob" (any weaponskill) or "Mob:Weaponskill" (only that one heals it).
-- "Puk" also matches "Puks".
function WS.heals(name, ws)
    if not name then return false end
    local n, w = name:lower(), (ws or settings.ws_name or ''):lower()
    for part in tostring(settings.ws_alt_mobs or ''):gmatch('[^,]+') do
        local mob, which = part:match('^%s*(.-)%s*:%s*(.-)%s*$')
        mob = (mob or part:match('^%s*(.-)%s*$')):lower()
        if mob ~= '' and n:find(mob, 1, true) == 1 and (not which or which == '' or which:lower() == w) then return true end
    end
    return false
end

function WS.learn_heal(name, ws)
    if not name or WS.heals(name, ws) then return end
    local entry = ws and (name .. ':' .. ws) or name
    local list = settings.ws_alt_mobs or ''
    settings.ws_alt_mobs = list == '' and entry or (list .. ',' .. entry)
    config.save(settings)
    say(orange(('%s healed from %s.'):format(name, ws or 'your weaponskill'))
        .. (settings.ws_alt ~= '' and (' I\'ll use ' .. settings.ws_alt .. ' on it from now on.')
            or ' Set a backup WS for it: //nz ws backup <name>'))
end

function WS.gear_near(target, r)
    for _, m in pairs(windower.ffxi.get_mob_array()) do
        if m.spawn_type == SPAWN_MONSTER and is_gear(m.name) and (m.hpp or 0) > 0 and m.id ~= target.id
           and dist2d(m, target) <= r then return true end
    end
    return false
end

-- weaponskill name and TP for this target, or nil and why not
function WS.pick(target)
    if is_boss_floor() and settings.ws_boss ~= '' then return settings.ws_boss, settings.ws_boss_tp, 'boss' end
    local name = settings.ws_name
    if name == '' then return nil end
    local alt = settings.ws_alt ~= '' and settings.ws_alt or nil
    if WS.heals(target.name, name) then
        if alt then return alt, settings.ws_tp, 'heals' end
        return nil, nil, ('WS held: %s heals from it'):format(target.name)
    end
    if WS.is_aoe(name) and WS.gear_near(target, 12) then
        if alt and not WS.is_aoe(alt) then return alt, settings.ws_tp, 'gear' end
        return nil, nil, 'WS held: an Archaic Gear is next to ' .. target.name
    end
    return name, settings.ws_tp
end

local function try_ws(player, target)
    if S.pathos.ws then return end
    -- (not on a gear on a "Do not destroy archaic gears!" floor - the game's auto-target can
    if is_gear(target.name) and S.restriction:lower():find('destroy') then return end
    local name, tp, why = WS.pick(target)
    if not name then
        S.ws_note = why
        return
    end
    S.ws_note = (why == 'heals' or why == 'gear') and ('backup WS: %s (%s)'):format(name, why == 'heals' and
        (target.name .. ' heals from ' .. settings.ws_name) or 'gear close by') or nil
    if (player.vitals.tp or 0) < tp then return end
    if os.clock() < S.next_ws then return end
    local reach = (target.model_size or 0) + 3.5
    if math.sqrt(target.distance or 0) > reach then return end
    S.next_ws = os.clock() + settings.ws_delay
    S.next_ja = math.max(S.next_ja, os.clock() + 2.5)       -- abilities fail right after a WS
    S.last_ws = {name = name, target = target.id, t = os.clock()}
    S.last_act_t = os.clock()
    windower.send_command(('input /ws "%s" <t>'):format(name))
end

---------------------------------------------------------------------------
-- Job support: Corsair rolls + Dancer waltzes (semi-auto only)
---------------------------------------------------------------------------
local ROLLS = {
    {key = 'bolter',    name = "Bolter's Roll",    short = "Bolter's",    id = 118, buff = 330, lucky = 3, unlucky = 9},
    {key = 'tactician', name = "Tactician's Roll", short = "Tactician's", id = 122, buff = 334, lucky = 5, unlucky = 8},
    {key = 'chaos',     name = 'Chaos Roll',       short = 'Chaos',       id = 105, buff = 317, lucky = 4, unlucky = 8},
    {key = 'samurai',   name = 'Samurai Roll',     short = 'Samurai',     id = 109, buff = 321, lucky = 2, unlucky = 6},
}
local ROLL_BY_ID, ROLL_BY_KEY = {}, {}
for _, r in ipairs(ROLLS) do ROLL_BY_ID[r.id], ROLL_BY_KEY[r.key] = r, r end

local JA_DOUBLE_UP   = 123
local RECAST_ROLL    = 193   -- Phantom Roll (shared by every roll)
local RECAST_DOUBLE  = 194
local BUFF_DOUBLE_UP = 308   -- "Double-Up Chance"
local BUFF_BUST      = 309
local BUFF_AMNESIA   = 16
local MSG_ROLL       = {[420] = true, [422] = true}
local MSG_DOUBLE     = {[424] = true, [425] = true}
local MSG_BUST       = 426

local WALTZES = {    -- best first
    {name = 'Curing Waltz III', id = 192, recast = 187, tp = 500, hpp = 'waltz3_hpp'},
    {name = 'Curing Waltz II',  id = 191, recast = 186, tp = 350, hpp = 'waltz2_hpp'},
}

-- "bolter", "Bolter's", "bolter's roll", "Chaos" ... -> roll entry
local function resolve_roll(word)
    if not word then return nil end
    local w = word:lower():gsub("'s", ''):gsub("'", ''):gsub('%s*roll$', ''):gsub('%s+', '')
    return ROLL_BY_KEY[w]
end

local function roll_list(str)
    local out = {}
    for part in tostring(str or ''):gmatch('[^,]+') do
        local r = resolve_roll(part:match('^%s*(.-)%s*$'))
        if r and #out < 2 then out[#out + 1] = r end
    end
    return out
end

local function roll_names(str)
    local names = {}
    for i, r in ipairs(roll_list(str)) do names[i] = r.name end
    return #names > 0 and table.concat(names, ' + ') or 'none'
end

local known = {set = {}, t = -100}
local function knows(ja_id)
    if os.clock() - known.t > 10 then
        known.set, known.t = {}, os.clock()
        local a = windower.ffxi.get_abilities()
        for _, id in pairs(a and a.job_abilities or {}) do known.set[id] = true end
    end
    return known.set[ja_id] == true
end

local function buff_count(player, id)
    local n = 0
    for _, b in pairs(player.buffs or {}) do if b == id then n = n + 1 end end
    return n
end

local function ready(rec, recast_id)
    return (rec[recast_id] or 0) <= 0
end

-- Why a job ability can't be used right now (nil = OK).
-- Abilities aggro Archaic Gears, so rolls wait until you're clear of them. Waltzes only
-- wait on "avoid discovery" floors, and not at all once HP is critical.
local function ja_blocked(player, kind)
    if S.pathos.ja then return 'Pathos blocks job abilities' end
    if buff_count(player, BUFF_AMNESIA) > 0 then return 'amnesia' end
    local _, _, gd = gear_info()
    if gd and gd <= settings.ja_gear_range then
        if kind == 'roll' then return ('gear %dy away'):format(math.floor(gd)) end
        local avoid = not S.floor_clear and S.restriction:lower():find('avoid discovery') ~= nil
        if avoid and (player.vitals.hpp or 100) > 30 then return ('gear %dy away'):format(math.floor(gd)) end
    end
    return nil
end

local function use_ja(name, target)
    windower.send_command(('input /ja "%s" %s'):format(name, target or '<me>'))
    S.last_act_t = os.clock()                  -- (a "You must wait longer" after this is about it, not an engage)
    S.next_ja = os.clock() + 2
    S.next_ws = math.max(S.next_ws, os.clock() + 1.5)
    S.ja_note = nil
    debug_log('ja: ' .. name)
end

local function try_waltz(player)
    if not settings.waltz or (player.main_job ~= 'DNC' and player.sub_job ~= 'DNC') then return false end
    local hpp, tp = player.vitals.hpp or 100, player.vitals.tp or 0
    local rec = windower.ffxi.get_ability_recasts() or {}
    for _, w in ipairs(WALTZES) do
        if hpp <= settings[w.hpp] and tp >= w.tp and knows(w.id) and ready(rec, w.recast) then
            local why = ja_blocked(player, 'waltz')
            if why then S.ja_note = 'Waltz waiting: ' .. why; return false end
            use_ja(w.name)
            return true
        end
    end
    return false
end

local function should_double(roll, total)
    return total ~= nil and total < 11 and total ~= roll.lucky and total <= settings.cor_double_max
end

-- distance to the closest living enemy (gears included), or nil
local function nearest_enemy()
    local best
    for _, m in pairs(windower.ffxi.get_mob_array()) do
        if m.spawn_type == SPAWN_MONSTER and m.valid_target and (m.hpp or 0) > 0 and (m.status == 0 or m.status == 1) then
            local d = math.sqrt(m.distance or 0)
            if not best or d < best then best = d end
        end
    end
    return best
end

-- True when rolling now would cost stored TP (GearSwap weapon swaps for rolls reset TP).
local function tp_held(player)
    return settings.cor_tp_hold > 0 and (player.vitals.tp or 0) >= settings.cor_tp_hold
end

local function try_rolls(player, engaged)
    if not settings.cor or player.main_job ~= 'COR' then return false end
    local now, c = os.clock(), S.cor
    local rec = windower.ffxi.get_ability_recasts() or {}
    if c.pending and now - c.pending > 3 then c.pending = nil end    -- didn't go off: allow a retry
    if c.pending then return false end

    -- Floor done: Bolter's (your idle rolls) and its Double-Up go off even with stored TP,
    -- so you can run back to the Rune.
    local done = S.floor > 0 and S.floor_clear
    local hold = tp_held(player) and not done

    -- 1) finish the roll we just made
    local last = c.last
    if last and now - last.t < 42 and buff_count(player, BUFF_DOUBLE_UP) > 0 then
        local r = ROLL_BY_ID[last.id]
        if r and should_double(r, last.total) then
            if ready(rec, RECAST_DOUBLE) then
                if hold then
                    S.ja_note = ('Double-Up waiting: holding %d TP for your WS'):format(player.vitals.tp or 0)
                    return false
                end
                local why = ja_blocked(player, 'roll')
                if why then S.ja_note = 'Double-Up waiting: ' .. why; return false end
                use_ja('Double-Up')
                c.pending = now
                return true
            end
            return false       -- wait for Double-Up before starting another roll
        end
    end

    -- 2) put up whatever is missing
    if not ready(rec, RECAST_ROLL) or buff_count(player, BUFF_BUST) >= 2 then return false end
    -- Floor done: always go for the idle rolls (Bolter's to run back), even if still engaged
    -- and whatever is around you. Otherwise idle rolls wait until no enemy is close.
    if engaged and done then return false end      -- floor done: wait until your weapons are away
    local idle = not engaged
    if idle and os.clock() < (S.engaging_until or 0) then return false end   -- about to fight
    if idle and is_boss_floor() then return false end                         -- boss floors: combat rolls only
    local want = roll_list(idle and settings.cor_idle_rolls or settings.cor_combat_rolls)
    for _, r in ipairs(want) do
        if buff_count(player, r.buff) == 0 and knows(r.id) then
            if hold then
                S.ja_note = ('%s waiting: holding %d TP for your WS'):format(r.short, player.vitals.tp or 0)
                return false
            end
            if idle then
                local d = nearest_enemy()
                if d and d <= settings.cor_idle_enemy_range then
                    S.ja_note = ('%s waiting: enemy %dy away'):format(r.short, math.floor(d))
                    return false
                end
            end
            local why = ja_blocked(player, 'roll')
            if why then S.ja_note = r.short .. ' waiting: ' .. why; return false end
            use_ja(r.name)
            c.pending = now
            return true
        end
    end
    return false
end

local JA_SPECTRAL_JIG = 196
local RECAST_JIG      = 218
local BUFF_INVISIBLE  = 69
local BUFF_SNEAK      = 71

-- Click a buff off. windower.ffxi.cancel_buff alone didn't always take (in testing it
-- "dropped Invisible" eleven times in 30 seconds at the Rune and you were still invisible),
-- so the cancel packet is sent as well, the way the Cancel addon does it.
local function drop_buff(id)
    windower.ffxi.cancel_buff(id)
    packets.inject(packets.new('outgoing', 0x0F1, {['Buff'] = id}))
end

-- Seconds until the next out-of-combat roll / Double-Up, or nil if none is coming.
-- Using a job ability strips Invisible, so a jig right before a roll would be wasted.
local function roll_due_in(player)
    if not settings.cor or player.main_job ~= 'COR' then return nil end
    if tp_held(player) then return nil end          -- rolls are on hold until the TP is spent
    local c = S.cor
    if c.pending then return 0 end
    if c.last and os.clock() - c.last.t < 42 and buff_count(player, BUFF_DOUBLE_UP) > 0 then
        local r = ROLL_BY_ID[c.last.id]
        if r and should_double(r, c.last.total) then return 0 end
    end
    for _, r in ipairs(roll_list(settings.cor_idle_rolls)) do
        if buff_count(player, r.buff) == 0 and knows(r.id) then
            local rec = windower.ffxi.get_ability_recasts() or {}
            return math.max(0, rec[RECAST_ROLL] or 0)
        end
    end
    return nil
end

local function try_jig(player)
    if not settings.jig or (player.main_job ~= 'DNC' and player.sub_job ~= 'DNC') then return false end
    if is_boss_floor() then return false end                                  -- not on boss floors
    -- You can't touch lamps or the Rune of Transfer while invisible, so only jig when you're
    -- still a fair way from them (Invisible gets clicked off for you when you arrive).
    local m = me()
    if S.floor_clear then
        local keep = math.max(settings.jig_rune_range, settings.uninvis_range + 5)   -- (no jig just to drop it again)
        if not S.rune or not m or dist2d(m, S.rune) <= keep then return false end
    elseif S.obj_type == 'lamps' then
        if not settings.jig_lamp_floors then return false end
        local slot = next_lamp_slot()
        local l = slot and S.lamps[slot]
        local keep = math.max(settings.jig_lamp_range, settings.uninvis_range + 5)
        if l and l.x and m and dist2d(m, l) <= keep then return false end
    end
    -- on "kill all enemies" floors you want mobs to find you
    if S.obj_type == 'all' and not settings.jig_all then return false end
    -- not with an enemy right next to you
    local near = nearest_enemy()
    if near and near <= settings.jig_enemy_range then
        S.ja_note = S.ja_note or ('Jig waiting: enemy %dy away'):format(math.floor(near))
        return false
    end
    if buff_count(player, BUFF_INVISIBLE) > 0 or not knows(JA_SPECTRAL_JIG) then return false end
    local rec = windower.ffxi.get_ability_recasts() or {}
    if not ready(rec, RECAST_JIG) then return false end
    local due = roll_due_in(player)
    if due and due <= settings.jig_roll_window then
        S.ja_note = S.ja_note or ('Jig waiting: roll in %ds'):format(math.ceil(due))
        return false
    end
    local why = ja_blocked(player, 'roll')     -- same gear rule as rolls
    if why then S.ja_note = 'Jig waiting: ' .. why; return false end
    if buff_count(player, BUFF_SNEAK) > 0 then
        -- Jig won't land over an existing Sneak, so drop it first (same as clicking it off)
        drop_buff(BUFF_SNEAK)
        S.next_ja = os.clock() + 1
        return true
    end
    use_ja('Spectral Jig')
    return true
end

-- Corsair / Dancer rows for the panel: {label, value}
local function job_rows(player)
    local rows = {}
    if not player then return rows end
    local P = settings.panel
    if settings.cor and player.main_job == 'COR' and P.show_rolls then
        local parts, seen = {}, {}
        local all = roll_list(settings.cor_idle_rolls)
        for _, r in ipairs(roll_list(settings.cor_combat_rolls)) do all[#all + 1] = r end
        for _, r in ipairs(all) do
            if not seen[r.id] then
                seen[r.id] = true
                local total = S.cor.totals[r.id]
                local s
                if buff_count(player, r.buff) == 0 then
                    s = grey(r.short .. ' off')
                elseif total == 11 or total == r.lucky then
                    s = green(('%s %s'):format(r.short, total == 11 and 'XI' or total .. ' lucky'))
                elseif total == r.unlucky then
                    s = orange(('%s %d unlucky'):format(r.short, total))
                else
                    s = ('%s %s'):format(r.short, tostring(total or '?'))
                end
                parts[#parts + 1] = s
            end
        end
        local rec = windower.ffxi.get_ability_recasts() or {}
        local wait = rec[RECAST_ROLL] or 0
        rows[#rows + 1] = {'Rolls:', table.concat(parts, ', ')
                           .. (wait > 0 and grey(('  (next %ds)'):format(math.ceil(wait))) or '')}
    end
    if settings.waltz and (player.main_job == 'DNC' or player.sub_job == 'DNC') and P.show_waltz then
        local jig = ''
        if settings.jig then
            jig = buff_count(player, BUFF_INVISIBLE) > 0 and '   Jig: up' or '   Jig: auto'
        end
        rows[#rows + 1] = {'Waltz:', grey(('III at %d%%, II at %d%% HP%s'):format(settings.waltz3_hpp, settings.waltz2_hpp, jig))}
    end
    if S.ja_note and (P.show_rolls or P.show_waltz) then rows[#rows + 1] = {'', orange(S.ja_note)} end
    return rows
end

next_lamp_slot = function()
    if S.floor_clear or S.obj_type ~= 'lamps' or S.pending_eval then return nil end
    if S.lamp_type == 'order' then
        local plan = current_plan()
        if plan then return plan[#S.round + 1] end
        return nil
    end
    if S.lamp_type == 'same' then return Same.next() end
    local m = me()
    local best, bd
    local skip = FAX.FA and FAX.FA.on and FAX.FA.lamp_skip or {}
    for slot = 1, lamp_count() do
        local l = S.lamps[slot]
        if l and l.x and l.floor == S.floor_id and not S.touched[slot] and m
           and not (skip[slot] and os.clock() - skip[slot] < 60) then
            local d = dist2d(m, l)
            if not bd or d < bd then best, bd = slot, d end
        end
    end
    return best
end

local function try_object_target()
    if not settings.autoobject or os.clock() < S.next_object then return end
    local m = me()
    if not m then return end
    local current = windower.ffxi.get_mob_by_target('t')
    local want
    if S.floor_clear and S.rune and S.rune.index then
        want = windower.ffxi.get_mob_by_index(S.rune.index)
    else
        local slot = next_lamp_slot()
        if slot then want = windower.ffxi.get_mob_by_index(IDX_LAMP_FIRST + slot - 1) end
    end
    if want and want.valid_target and math.sqrt(want.distance or 999) <= settings.object_range
       and (not current or current.id ~= want.id) and S.last_object ~= want.id then
        set_target(want)
        S.last_object = want.id       -- only once, so you can tab away if you want
        S.next_object = os.clock() + 1
    end
end

-- "You cannot use that command while invisible": when you're next to the lamp you need,
-- or the Rune of Transfer after a clear, click Invisible off for you.
local function try_uninvis(player)
    if not settings.uninvis or buff_count(player, BUFF_INVISIBLE) == 0 then return end
    if os.clock() < (S.next_uninvis or 0) then return end
    local m = me()
    if not m then return end
    local target
    if S.floor_clear and S.rune then
        target = S.rune
    else
        local slot = next_lamp_slot()
        target = slot and S.lamps[slot]
        if target and not target.x then target = nil end
    end
    if target and dist2d(m, target) <= settings.uninvis_range then
        drop_buff(BUFF_INVISIBLE)
        S.next_uninvis = os.clock() + 3
        debug_log('dropped Invisible to touch ' .. (S.floor_clear and 'the rune' or 'a lamp'))
    end
end

---------------------------------------------------------------------------
-- Buffs and heals for any job (//nz buff, //nz heal)
-- Job abilities and spells you name are kept up (if they give a status) or used whenever
-- they're ready (if they don't, e.g. Jump), and heals are used at or below the HP% you set.
-- Names are looked up in Windower's resources, so any job's abilities and spells work.
---------------------------------------------------------------------------
do
local Rules = {fails = {}, pos = nil, pos_t = 0, cache = {}}
FAX.Rules = Rules
local res
local function resources()
    if res == nil then
        local ok, r = pcall(require, 'resources')
        res = ok and r or false
    end
    return res or nil
end
local function norm(name) return (tostring(name or ''):gsub('"', ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()) end
local ROMAN = {[' ii'] = true, [' iii'] = true, [' iv'] = true, [' v'] = true, [' vi'] = true}

-- who it can be used on: the resource's targets are a set ({Self = true, Enemy = true}) or bits (1 = self, 32 = enemy)
local function targets_of(t)
    if type(t) == 'table' then return t.Self or t.self or false, t.Enemy or t.enemy or false end
    if type(t) == 'number' then return t % 2 == 1, math.floor(t / 32) % 2 == 1 end
    return true, false                                  -- (not known: on yourself)
end
-- Copy Image shows as a different status for 1, 2, 3 and 4+ shadows
local SAME_BUFF = {[66] = {66, 444, 445, 446}}
function Rules.has_buff(player, id)
    for _, b in ipairs(SAME_BUFF[id] or {id}) do if buff_count(player, b) > 0 then return true end end
    return false
end

-- the job ability or spell called `name`: {kind = 'ja' | 'ma', id, name, recast, tp, mp, buff, cast, self, enemy, levels}
function Rules.lookup(name)
    local key = norm(name)
    if key == '' then return nil end
    if Rules.cache[key] ~= nil then return Rules.cache[key] or nil end
    local r = resources()
    local found
    if r then
        for id, a in pairs(r.job_abilities or {}) do
            if norm(a.en or a.english) == key then
                found = {kind = 'ja', id = id, name = a.en or a.english, recast = a.recast_id, tp = a.tp_cost or 0, mp = 0, buff = a.status}
                found.self, found.enemy = targets_of(a.targets)
                break
            end
        end
        if not found then
            for id, sp in pairs(r.spells or {}) do
                if norm(sp.en or sp.english) == key then
                    found = {kind = 'ma', id = id, name = sp.en or sp.english, recast = sp.recast_id or id, tp = 0,
                             mp = sp.mp_cost or 0, buff = sp.status, cast = sp.cast_time or 2, levels = sp.levels}
                    found.self, found.enemy = targets_of(sp.targets)
                    if not found.buff and key:find('^utsusemi') then found.buff = 66 end
                    break
                end
            end
        end
        -- a status of the same name (Protect IV -> Protect) when the resource doesn't say
        if found and not found.buff then
            local want = norm(found.name)
            for suffix in pairs(ROMAN) do
                if want:sub(-#suffix) == suffix then want = want:sub(1, -#suffix - 1) break end
            end
            for id, b in pairs(r.buffs or {}) do
                if norm(b.en or b.english) == want then found.buff = id break end
            end
        end
    end
    Rules.cache[key] = found or false
    return found
end

-- the rules as lists: settings.buffs 'Name|mode;...', settings.heals 'Name|hp;...'
function Rules.list(which)
    local out = {}
    for part in tostring(settings[which] or ''):gmatch('[^;]+') do
        local name, arg = part:match('^%s*(.-)%s*|%s*(.-)%s*$')
        name = name or part:match('^%s*(.-)%s*$')
        if name and name ~= '' then out[#out + 1] = {name = name, arg = arg} end
    end
    return out
end
local function save_list(which, list)
    local parts = {}
    for _, r in ipairs(list) do parts[#parts + 1] = r.name .. (r.arg and r.arg ~= '' and ('|' .. r.arg) or '') end
    settings[which] = table.concat(parts, ';')
    config.save(settings)
end

local function standing_still()
    local m = me()
    if not m then return false end
    local now = os.clock()
    local p = Rules.pos
    if not p or (m.x - p.x) ^ 2 + (m.y - p.y) ^ 2 > 0.04 then Rules.pos, Rules.pos_t = {x = m.x, y = m.y}, now end
    return now - Rules.pos_t >= 0.6
end

-- why this one can't go now (nil = it can)
-- the mob you're fighting, if this one goes on it (Jump, Provoke, Drain...)
local function enemy_target(player, a)
    if player.status ~= 1 then return nil end
    local t = windower.ffxi.get_mob_by_target('t')
    if not t or t.spawn_type ~= SPAWN_MONSTER or (t.hpp or 0) <= 0 then return nil end
    if math.sqrt(t.distance or 0) > (a.kind == 'ja' and 6 or 18) then return nil end
    return t
end
-- learned, and on your main or sub job at your level?
local spellbook = {t = -100}
local function spell_missing(player, a)
    if os.clock() - spellbook.t > 10 then
        spellbook.t = os.clock()
        spellbook.set = windower.ffxi.get_spells and windower.ffxi.get_spells() or nil
    end
    if spellbook.set and not spellbook.set[a.id] then return 'not learned' end
    local lv = a.levels
    if lv and player.main_job_id then
        local m, s = lv[player.main_job_id], player.sub_job_id and lv[player.sub_job_id]
        -- (over 99 = a job point spell: can't tell from here, so let it try)
        if not ((m and (m <= (player.main_job_level or 99) or m > 99)) or (s and s <= (player.sub_job_level or 0))) then
            return 'not on your jobs'
        end
    end
    return nil
end

local function blocked(player, a)
    local f = Rules.fails[a.name]
    if f and f.until_t and os.clock() < f.until_t then return 'failed a few times - trying again shortly' end
    if f and f.sent_t then return 'checking the last one worked' end
    if not a.self and not (a.enemy and enemy_target(player, a)) then return a.enemy and 'needs a target' or 'not on yourself' end
    if a.kind == 'ja' then
        if not knows(a.id) then return 'not on your jobs' end
        local rec = windower.ffxi.get_ability_recasts() or {}
        if a.recast and (rec[a.recast] or 0) > 0 then return 'recast' end
        if (player.vitals.tp or 0) < (a.tp or 0) then return 'TP' end
        return ja_blocked(player, 'buff')
    end
    local missing = spell_missing(player, a)
    if missing then return missing end
    if S.pathos.magic then return 'Pathos blocks magic' end
    if buff_count(player, 6) > 0 or buff_count(player, 29) > 0 then return 'silenced' end
    local rec = windower.ffxi.get_spell_recasts and windower.ffxi.get_spell_recasts() or {}
    if a.recast and (rec[a.recast] or 0) > 0 then return 'recast' end
    if (player.vitals.mp or 0) < (a.mp or 0) then return 'MP' end
    local _, _, gd = gear_info()
    if gd and gd <= settings.ja_gear_range then return 'gear close by' end
    if not standing_still() then return 'moving' end
    return nil
end

local function use(a, why)
    local f = Rules.fails[a.name] or {n = 0}
    Rules.fails[a.name] = f
    local now = os.clock()
    f.sent_t, f.buff, f.recast, f.id, f.kind, f.ok = now, a.buff, a.recast, a.id, a.kind, false
    f.check_t = now + (a.kind == 'ja' and 3 or (a.cast or 2) + 3)
    local target = a.self and '<me>' or '<t>'
    if a.kind == 'ja' then
        use_ja(a.name, target)
    else
        windower.send_command(('input /ma "%s" %s'):format(a.name, target))
        S.last_act_t = os.clock()
        S.next_ja = os.clock() + (a.cast or 2) + 1.5
        S.next_ws = math.max(S.next_ws, S.next_ja)
        debug_log('ma: ' .. a.name)
    end
    debug_log(('rules: %s (%s)'):format(a.name, why))
end

-- the game says you used it (the action event): ja = category 6 (14 and 15 for some), spell = 4
function Rules.done(category, param)
    for _, f in pairs(Rules.fails) do
        if f.sent_t and f.id == param and ((f.kind == 'ma' and category == 4)
            or (f.kind == 'ja' and (category == 6 or category == 14 or category == 15))) then f.ok = true end
    end
end

-- did the last one work? It isn't used again until that's known. Three that didn't (no status,
-- or for one without a status: it never went off): leave it for 2 minutes
local function check_fails(player)
    local now = os.clock()
    for name, f in pairs(Rules.fails) do
        if f.sent_t and not f.ok and f.recast then
            local rec = f.kind == 'ja' and (windower.ffxi.get_ability_recasts() or {})
                or (windower.ffxi.get_spell_recasts and windower.ffxi.get_spell_recasts() or {})
            if (rec[f.recast] or 0) > 0 then f.ok = true end
        end
        if f.sent_t and now >= f.check_t then
            local took
            if f.buff then took = Rules.has_buff(player, f.buff) else took = f.ok end
            if now - f.check_t > 10 then took = true end        -- (stale: semi-auto was off meanwhile)
            f.sent_t = nil
            if took then f.n = 0 else
                f.n = f.n + 1
                if f.n >= 3 then
                    f.n, f.until_t = 0, now + 120
                    debug_log(('rules: %s didn\'t work three times - leaving it for 2 minutes'):format(name))
                    if not f.told then
                        f.told = true
                        say(orange(('%s didn\'t work three times in a row, so it\'s left alone for 2 minutes.'):format(name))
                            .. ' (//nz buff remove / heal remove to take it off)')
                    end
                end
            end
        end
    end
end

-- heal at or below the HP% you set
function Rules.heal(player)
    if not settings.rules_on then return false end
    standing_still()
    check_fails(player)
    local hpp = player.vitals.hpp or 100
    for _, r in ipairs(Rules.list('heals')) do
        local at = tonumber(r.arg) or 50
        if hpp <= at then
            local a = Rules.lookup(r.name)
            if a and not blocked(player, a) then use(a, ('HP %d%%'):format(hpp)); return true end
        end
    end
    return false
end

-- keep buffs up: engaged = in a fight (fight / always rules), else idle / always rules
function Rules.buffs(player, engaged)
    if not settings.rules_on then return false end
    standing_still()                                   -- (keeps track of how long you've stood still)
    check_fails(player)
    if not engaged and buff_count(player, BUFF_INVISIBLE) > 0 then return false end   -- (it would take Invisible off)
    for _, r in ipairs(Rules.list('buffs')) do
        local mode = (r.arg or 'fight'):lower()
        if mode == 'always' or (engaged and mode == 'fight') or (not engaged and mode == 'idle') then
            local a = Rules.lookup(r.name)
            if a and not (a.buff and Rules.has_buff(player, a.buff)) and not blocked(player, a) then
                use(a, a.buff and 'not up' or 'ready')
                return true
            end
        end
    end
    return false
end

local function rule_args(args)
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end
    return rest
end

local function rules_command(which, args)
    local a1 = args[1] and args[1]:lower()
    local list = Rules.list(which)
    local label = which == 'buffs' and 'Buffs' or 'Heals'
    if a1 == 'on' or a1 == 'off' then
        settings.rules_on = a1 == 'on'
        config.save(settings)
    elseif a1 == 'add' then
        local rest = rule_args(args)
        local last = rest[#rest] and rest[#rest]:lower()
        local arg
        if which == 'heals' and tonumber(last) then arg = tostring(math.max(1, math.min(99, math.floor(tonumber(last))))); rest[#rest] = nil
        elseif which == 'buffs' and (last == 'fight' or last == 'idle' or last == 'always') then arg = last; rest[#rest] = nil end
        local a = Rules.lookup(table.concat(rest, ' '))
        if not a then
            say(orange(('I don\'t know a job ability or spell called "%s".'):format(table.concat(rest, ' '))))
            return
        end
        if not a.self and not a.enemy then
            say(orange(('%s can\'t be used on yourself or an enemy, so it can\'t go in the list.'):format(a.name)))
            return
        end
        if not a.self and which == 'buffs' and arg and arg ~= 'fight' then
            say(grey(('%s goes on your target, so it\'s only used in fights.'):format(a.name)))
            arg = 'fight'
        end
        for i = #list, 1, -1 do if norm(list[i].name) == norm(a.name) then table.remove(list, i) end end
        list[#list + 1] = {name = a.name, arg = arg or (which == 'heals' and '50' or 'fight')}
        save_list(which, list)
    elseif a1 == 'remove' or a1 == 'del' then
        local name = norm(table.concat(rule_args(args), ' '))
        for i = #list, 1, -1 do if norm(list[i].name) == name then table.remove(list, i) end end
        save_list(which, list)
    elseif a1 == 'clear' then
        save_list(which, {})
    end
    list = Rules.list(which)
    local parts = {}
    for _, r in ipairs(list) do
        local a = Rules.lookup(r.name)
        parts[#parts + 1] = r.name .. grey(which == 'heals' and (' at ' .. (r.arg or '50') .. '%') or (' (' .. (r.arg or 'fight') .. ')'))
            .. (a and '' or orange(' (unknown)'))
    end
    say(('%s%s: %s'):format(label, settings.rules_on and '' or ' (off)', #parts > 0 and table.concat(parts, ', ') or 'none'))
    if a1 == nil then
        say(which == 'buffs' and grey('//nz buff add <ability or spell> [fight|idle|always]  |  buff remove <name>  |  buff clear  |  buff on/off')
            or grey('//nz heal add <ability or spell> <hp%>  |  heal remove <name>  |  heal clear'))
    end
end
FAX.X.buff = function(args) rules_command('buffs', args) end
FAX.X.buffs = FAX.X.buff
FAX.X.heal = function(args) rules_command('heals', args) end
FAX.X.heals = FAX.X.heal
end

---------------------------------------------------------------------------
-- Version, update check and bug reports (//nz version, //nz update, //nz report)
---------------------------------------------------------------------------
do
local UPDATE_URL = 'https://raw.githubusercontent.com/SmallnDumb/NyzulAssist/main/version.txt'
local HOME_URL   = 'github.com/SmallnDumb/NyzulAssist'
local TIP_URL    = 'ko-fi.com/smallndumb'
FAX.HOME_URL, FAX.TIP_URL = HOME_URL, TIP_URL

local function vnum(v)
    local a, b, c = tostring(v or ''):match('(%d+)%.(%d+)%.?(%d*)')
    return a and (tonumber(a) * 1000000 + tonumber(b) * 1000 + (tonumber(c) or 0)) or 0
end
FAX.vnum = vnum

-- ask GitHub for the latest version (curl comes with Windows 10 and 11). Returns version, note.
local function fetch_latest()
    local ok, f = pcall(io.popen, ('curl -s -m 4 "%s"'):format(UPDATE_URL))
    if not ok or not f then return nil end
    local body = f:read('*a') or ''
    f:close()
    local v, note = body:match('^%s*(%d+%.%d+%.?%d*)%s*\n?(.*)$')
    return v, note and note:gsub('%s+$', '') or nil
end
FAX.fetch_latest = fetch_latest

local function check(quiet)
    settings.update_last = os.date('%Y-%m-%d')
    config.save(settings)
    local v, note = FAX.fetch_latest()
    if not v then
        if not quiet then say(orange('Couldn\'t check for updates') .. ' - see ' .. HOME_URL) end
        return
    end
    if vnum(v) > vnum(_addon.version) then
        say(green('NyzulAssist ' .. v .. ' is out') .. (' (you have %s).'):format(_addon.version)
            .. (note and note ~= '' and (' ' .. note) or '') .. ' Get it from ' .. HOME_URL)
    elseif not quiet then
        say(('You have the latest version (%s).'):format(_addon.version))
    end
end

FAX.X.update = function(args)
    local a1 = args[1] and args[1]:lower()
    if a1 == 'on' or a1 == 'off' then
        settings.update_check = a1 == 'on'
        config.save(settings)
        say('Weekly update check ' .. (settings.update_check and 'on' or 'off') .. '.')
        return
    end
    say(grey('Looking for a newer version...'))
    check(false)
end
FAX.X.version = function()
    say(('NyzulAssist %s%s by %s. What\'s new: CHANGELOG.md in the addon folder. Updates: %s  Tips: %s'):format(
        _addon.version, FAX.full and ' (full)' or '', _addon.author, HOME_URL, TIP_URL))
end

-- once a week, a while after loading (only says something if there's a newer version)
function FAX.update_tick()
    if not settings.update_check or FAX.full or FAX.update_done then return end
    FAX.update_done = true
    local last = tostring(settings.update_last or '')
    local y, m, d = last:match('(%d+)-(%d+)-(%d+)')
    if y and os.time() - os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d)}) < 7 * 86400 then return end
    coroutine.schedule(function() check(true) end, 20)
end

-- //nz report: everything needed to look into a problem, in one file to send
FAX.X.report = function()
    local path = windower.addon_path .. 'data/report.txt'
    local f = io.open(path, 'w')
    if not f then say(red('Couldn\'t write data/report.txt.')) return end
    local p = windower.ffxi.get_player()
    local info = windower.ffxi.get_info()
    f:write(('NyzulAssist %s%s report, %s\n'):format(_addon.version, FAX.full and ' (full)' or '', os.date('%Y-%m-%d %H:%M')))
    f:write(('job %s%s/%s%s, zone %s, floor %s, objective %s, lamps %s, rule %s\n'):format(
        p and p.main_job or '?', p and p.main_job_level or '', p and p.sub_job or '?', p and p.sub_job_level or '',
        info and info.zone or '?', tostring(S.floor), tostring(S.obj_type), tostring(S.lamp_type), tostring(S.restriction)))
    f:write(('semi-auto %s, debug log %s\n\nsettings:\n'):format(S.auto and 'on' or 'off', S.debug and 'on' or 'off'))
    local keys = {}
    for k, v in pairs(settings) do if type(v) ~= 'table' then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(('  %s = %s\n'):format(k, tostring(settings[k]))) end
    local lf = io.open(windower.addon_path .. 'data/debug.log', 'r')
    if lf then
        local lines = {}
        for line in lf:lines() do
            lines[#lines + 1] = line
            if #lines > 400 then table.remove(lines, 1) end
        end
        lf:close()
        f:write(('\nlast %d lines of the debug log:\n'):format(#lines))
        for _, line in ipairs(lines) do f:write(line, '\n') end
    else
        f:write('\n(no debug log)\n')
    end
    f:close()
    say(green('Saved data/report.txt') .. ' in the NyzulAssist folder - attach it to your bug report (' .. HOME_URL .. '/issues).')
    if not S.debug then
        say(grey('The debug log is off, so the report only has your settings. For more: //nz debug, make it happen again, then //nz report.'))
    end
end
end

local function auto_tick()
    if not S.auto then return end
    local player = windower.ffxi.get_player()
    if not player then return end

    if FAX.FA.on and FAX.FA.aiming(os.clock()) then return end
    local ja_ok = os.clock() >= S.next_ja
    if ja_ok then S.ja_note = nil end      -- recomputed below

    if player.status == 1 then           -- engaged
        local t = windower.ffxi.get_mob_by_target('t')
        if t and (t.hpp or 0) > 0 and settings.autoface and os.clock() >= S.next_face then
            face(t)
            S.next_face = os.clock() + 0.5
        end
        -- heal first, then rolls (incl. Double-Up), your buffs, then weaponskill
        if ja_ok and (try_waltz(player) or FAX.Rules.heal(player) or try_rolls(player, true)
                      or FAX.Rules.buffs(player, true)) then return end
        if t and (t.hpp or 0) > 0 then try_ws(player, t) end
        return
    end
    S.ws_note = nil
    if player.status ~= 0 then return end   -- event menu, resting, dead, etc.

    if ja_ok and (try_waltz(player) or FAX.Rules.heal(player)) then return end

    if os.clock() >= S.next_engage and not FAX.FA.engage_busy(os.clock()) then
        local best
        for _, t in ipairs(find_targets(6)) do
            local fa = FAX.FA
            if fa.on and fa.gave_up_on(t.mob.id, os.clock()) then
            elseif t.why == 'on you' or not (fa.on and fa.skipped(t.mob.id, os.clock())) then best = t; break end
        end
        if best and best.dist <= settings.engage_range then
            debug_log(('engage %s (%s) %.1fy'):format(best.mob.name, best.why, best.dist))
            engage(best.mob)
            S.next_engage = os.clock() + 2.5
            return
        end
    end
    if FAX.Menus and FAX.Menus.play then return end
    -- not fighting: keep Bolter's (or your idle rolls) up, then Spectral Jig
    if ja_ok and try_rolls(player, false) then return end
    if ja_ok and try_jig(player) then return end
    if ja_ok and FAX.Rules.buffs(player, false) then return end
    try_uninvis(player)
    try_object_target()
end

---------------------------------------------------------------------------
-- Auto /check (finds "impossible to gauge" targets)
---------------------------------------------------------------------------
local function check_tick()
    -- A free floor (rare) has no objective at all: no "Objective:" line comes, and the Rune of
    -- then gave up.)
    if S.floor > 0 and S.objective == '' and not S.floor_clear and S.floor_t and os.clock() - S.floor_t > 8 then
        S.obj_type, S.free_floor, S.tokens_before_free = 'free', true, S.tokens
        debug_log('no objective 8s after arriving: a free floor')
        say(green('Free floor') .. ' - no objective, just take the Rune of Transfer.')
        floor_cleared()
    end
    if not settings.autocheck or S.floor_clear then return end
    local ot = S.obj_type
    if ot ~= 'enemy' and ot ~= 'enemies' and ot ~= 'leader' then return end
    local now = os.clock()
    for id, t in pairs(S.pending) do
        if now - t > 3 then S.pending[id] = nil end
    end
    if next(S.pending) or now < S.next_check then return end

    local best, bd
    for _, m in pairs(windower.ffxi.get_mob_array()) do
        if m.spawn_type == SPAWN_MONSTER and m.valid_target and (m.hpp or 0) > 0
           and not S.checks[m.id] and not m.name:find('^Archaic') and not FLOOR_NMS[m.name]
           and (S.check_tries[m.id] or 0) < 3 then
            local d = math.sqrt(m.distance or 0)
            if d <= settings.check_range and (not bd or d < bd) then best, bd = m, d end
        end
    end
    if best then
        S.pending[best.id] = now
        S.check_tries[best.id] = (S.check_tries[best.id] or 0) + 1
        S.next_check = now + settings.check_interval
        packets.inject(packets.new('outgoing', 0x0DD, {
            ['Target']       = best.id,
            ['Target Index'] = best.index,
            ['Check Type']   = 0,
        }))
    end
end

-- Optional: ask the server for lamp/rune updates so far-away lamps show up.
local function request_tick()
    if not settings.request_updates or S.obj_type ~= 'lamps' or S.floor_clear then return end
    if os.clock() < S.next_request then return end
    S.next_request = os.clock() + 3
    for idx = IDX_RUNE_FIRST, IDX_LAMP_LAST do
        packets.inject(packets.new('outgoing', 0x016, {['Target Index'] = idx}))
    end
end

-- Pick up lamps that are in view.
local function poll_lamps()
    if S.obj_type ~= 'lamps' then return end
    for idx = IDX_LAMP_FIRST, IDX_LAMP_LAST do
        local l = windower.ffxi.get_mob_by_index(idx)
        if l and l.valid_target and l.name == 'Runic Lamp' then
            record_lamp(lamp_slot(idx), l.x, l.y)
        end
    end
end

---------------------------------------------------------------------------
-- Core (every build): a small file store, the token tracker, and engage retries
---------------------------------------------------------------------------
do
local Store, Core = {}, {}
FAX.Store, FAX.Core = Store, Core

-- ---- small file store: data/<name>.lua holds a plain Lua table ------------
local function data_file(name) return windower.addon_path .. 'data/' .. name end
-- a fresh install has no data folder until something creates it
if windower.dir_exists and windower.create_dir and not windower.dir_exists(windower.addon_path .. 'data') then
    pcall(windower.create_dir, windower.addon_path .. 'data')
end

local function serialize(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == 'number' then
        if v == math.floor(v) then return tostring(v) end
        return string.format('%.3f', v)
    elseif t == 'string' then
        return string.format('%q', v)
    elseif t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = {}
        for k, val in pairs(v) do
            local key = type(k) == 'number' and ('[' .. k .. ']') or ('[' .. string.format('%q', tostring(k)) .. ']')
            parts[#parts + 1] = key .. '=' .. serialize(val, depth + 1)
        end
        if depth == 0 then return '{\n  ' .. table.concat(parts, ',\n  ') .. '\n}' end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'nil'
end

function Store.save(name, tbl)
    local f = io.open(data_file(name .. '.lua'), 'w')
    if not f then return false end
    f:write('return ' .. serialize(tbl) .. '\n')
    f:close()
    return true
end

function Store.load(name)
    local f = io.open(data_file(name .. '.lua'), 'r')
    if not f then return nil end
    local src = f:read('*a')
    f:close()
    local chunk = loadstring(src)
    if not chunk then return nil end
    setfenv(chunk, {})                      -- data only, no code
    local ok, t = pcall(chunk)
    return ok and type(t) == 'table' and t or nil
end

-- ---- Tokens: your running total -----------------------------------------------
-- Every "You obtain N tokens" is added up and kept in data/tokens.lua. Sorrowful Sage's menu
-- carries the number of tokens you have (its third value: 36640 -> 39085 -> 41530 in your
-- log - each time a run's 4345 less 1900, which is what starting on floor 96 costs). So what
-- you have now is the Sage's figure plus what you've earned since, less what starting those
-- runs cost (learned from one Sage figure to the next).
Core.tok = {lifetime = 0, runs = 0, after_earned = 0, after_starts = {}, cost = {}}
-- this session: earned, runs, and net = earned less what starting those runs cost (a run's
-- cost is counted once it has paid out; one whose cost isn't known yet waits in `uncosted`)
Core.tok_session = {earned = 0, runs = 0, net = 0, spent = 0, uncosted = {}}
function Core.commas(n)
    local s = tostring(math.floor(n or 0))
    local neg = s:sub(1, 1) == '-'
    if neg then s = s:sub(2) end
    s = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return (neg and '-' or '') .. s
end
function Core.tok_load()
    local t = Store.load('tokens')
    if t then for k, v in pairs(t) do Core.tok[k] = v end end
    local T = Core.tok
    T.lifetime, T.runs, T.after_earned = T.lifetime or 0, T.runs or 0, T.after_earned or 0
    T.after_starts, T.cost = T.after_starts or {}, T.cost or {}
    T.since = T.since or os.date('%Y-%m-%d')
end
function Core.tok_save() Store.save('tokens', Core.tok) end
function Core.tok_earned(n)
    local now = os.clock()
    if Core.tok_last and Core.tok_last.n == n and now - Core.tok_last.t < 5 then return end    -- (the same line twice)
    Core.tok_last = {n = n, t = now}
    local T, ses = Core.tok, Core.tok_session
    T.lifetime, T.runs, T.after_earned = T.lifetime + n, T.runs + 1, T.after_earned + n
    T.best = math.max(T.best or 0, n)
    ses.earned, ses.runs = ses.earned + n, ses.runs + 1
    ses.best = math.max(ses.best or 0, n)
    local f = ses.current
    local c = f and T.cost[tostring(f)]
    ses.net = ses.net + n - (c or 0)
    if c then ses.spent = ses.spent + c elseif f then ses.uncosted[#ses.uncosted + 1] = f end
    ses.current = nil
    Core.tok_save()
    local have = Core.tok_have()
    debug_log(('tokens: +%d (this session %d from %d runs, counted %d)%s'):format(n, ses.earned, ses.runs, T.lifetime,
        have and (', you have about ' .. have) or ''))
end
function Core.tok_run_started(start_floor)
    local T = Core.tok
    Core.tok_session.current = start_floor
    local st = Core.stats
    st.t0, st.runs = st.t0 or os.time(), st.runs + 1
    if T.balance then T.after_starts[#T.after_starts + 1] = start_floor; Core.tok_save() end
end
function Core.tok_balance(b)
    local T = Core.tok
    if T.balance and #T.after_starts > 0 then
        local same = true
        for _, f in ipairs(T.after_starts) do if f ~= T.after_starts[1] then same = false end end
        local spent = T.balance + T.after_earned - b
        if same and spent >= 0 then
            local c = math.floor(spent / #T.after_starts + 0.5)
            T.cost[tostring(T.after_starts[1])] = c
            debug_log(('tokens: starting on floor %d costs %d'):format(T.after_starts[1], c))
            -- this session's runs that paid out before the cost was known: take it off now
            local ses, left = Core.tok_session, {}
            for _, f in ipairs(ses.uncosted) do
                local fc = T.cost[tostring(f)]
                if fc then ses.net, ses.spent = ses.net - fc, ses.spent + fc else left[#left + 1] = f end
            end
            ses.uncosted = left
        end
    end
    T.balance, T.balance_t, T.after_earned, T.after_starts = b, os.time(), 0, {}
    Core.tok_save()
    debug_log(('tokens: Sorrowful Sage says you have %d'):format(b))
end
-- tokens you have now (nil if no Sorrowful Sage figure yet); true as well if it's a guess
function Core.tok_have()
    local T = Core.tok
    if not T.balance then return nil end
    local have, guess = T.balance + T.after_earned, false
    for _, f in ipairs(T.after_starts) do
        local c = T.cost[tostring(f)]
        if c then have = have - c else guess = true end
    end
    return have, guess
end
-- the panel line
function Core.tok_row()
    local have, guess = Core.tok_have()
    local ses = Core.tok_session
    -- (what this session has made you after paying to start each run - "+2,445", not the 4,345 paid out)
    local net = ses.net >= 0 and ('+' .. Core.commas(ses.net)) or Core.commas(ses.net)
    local earned = ses.runs > 0 and grey(('  %s this session%s'):format(net, #ses.uncosted > 0 and ' (about)' or '')) or ''
    if have then return Core.commas(have) .. (guess and grey(' (about)') or '') .. earned end
    if ses.runs > 0 then return ('%s this session (%d run%s)'):format(net, ses.runs, ses.runs == 1 and '' or 's') end
end
function Core.tok_command(args)
    local a1 = args[1] and args[1]:lower()
    local T, ses = Core.tok, Core.tok_session
    if a1 == 'reset' then
        T.lifetime, T.runs, T.best, T.since = 0, 0, nil, os.date('%Y-%m-%d')
        ses.earned, ses.runs, ses.net, ses.spent, ses.uncosted = 0, 0, 0, 0, {}
        Core.tok_save()
        say('Token counts reset (what you have is kept).')
        return
    end
    local have, guess = Core.tok_have()
    if have then
        say(('You have %s%s Nyzul tokens (Sorrowful Sage said %s on %s%s).'):format(guess and 'about ' or '', Core.commas(have),
            Core.commas(T.balance), os.date('%m/%d %H:%M', T.balance_t), T.after_earned > 0 and (', plus ' .. Core.commas(T.after_earned) .. ' since') or ''))
    else
        say('Talk to Sorrowful Sage once and I\'ll know how many tokens you have.')
    end
    say(('This session: %d run%s paid %s, less %s to start them = %s%s%s.'):format(ses.runs, ses.runs == 1 and '' or 's',
        Core.commas(ses.earned), Core.commas(ses.spent), ses.net >= 0 and '+' or '', Core.commas(ses.net),
        #ses.uncosted > 0 and ' (a starting cost isn\'t known yet)' or ''))
    say(('Counted since %s: %s from %d run%s%s.  (//nz tokens reset)'):format(T.since or '?', Core.commas(T.lifetime), T.runs,
        T.runs == 1 and '' or 's', T.best and (', best run ' .. Core.commas(T.best)) or ''))
end

-- ---- Session stats: runs, floors, tokens per hour --------------------------------
-- (the clock starts when the first run of the session starts, so the trip between runs counts)
Core.stats = {t0 = nil, runs = 0, floors = 0}
function Core.stat_floor()
    local st = Core.stats
    st.t0, st.floors = st.t0 or os.time(), st.floors + 1
end
function Core.stat_hours()
    local st = Core.stats
    return st.t0 and (os.time() - st.t0) / 3600 or 0
end
-- the panel line (nil until a run has started)
function Core.stats_row()
    local st, ses = Core.stats, Core.tok_session
    if not st.t0 then return nil end
    local h = Core.stat_hours()
    local parts = {('%d run%s, %d floor%s'):format(st.runs, st.runs == 1 and '' or 's', st.floors, st.floors == 1 and '' or 's')}
    if ses.runs > 0 and h >= 0.1 then
        parts[#parts + 1] = ('%s/h'):format(Core.commas(ses.net / h))
    end
    parts[#parts + 1] = ('%d:%02d'):format(math.floor(h), math.floor(h * 60) % 60)
    return table.concat(parts, grey('  ·  '))
end
function Core.stats_command(args)
    local a1 = args[1] and args[1]:lower()
    local st, ses, T = Core.stats, Core.tok_session, Core.tok
    if a1 == 'reset' then
        Core.stats = {t0 = nil, runs = 0, floors = 0}
        ses.earned, ses.runs, ses.net, ses.spent, ses.uncosted, ses.best = 0, 0, 0, 0, {}, nil
        say('Session stats reset.')
        return
    end
    if not st.t0 then
        say('No runs yet this session.')
    else
        local h = Core.stat_hours()
        say(('This session (%d:%02d): %d run%s started, %d paid out, %d floor%s cleared%s.'):format(math.floor(h),
            math.floor(h * 60) % 60, st.runs, st.runs == 1 and '' or 's', ses.runs, st.floors, st.floors == 1 and '' or 's',
            ses.runs > 0 and (' (%.1f a run)'):format(st.floors / math.max(1, st.runs)) or ''))
        if ses.runs > 0 then
            say(('Tokens: %s paid out, %s to start the runs = %s%s%s.  Per hour: %s (%s before costs).  Best run: %s.'):format(
                Core.commas(ses.earned), Core.commas(ses.spent), ses.net >= 0 and '+' or '', Core.commas(ses.net),
                #ses.uncosted > 0 and ' (a starting cost isn\'t known yet)' or '',
                h >= 0.05 and Core.commas(ses.net / h) or '-', h >= 0.05 and Core.commas(ses.earned / h) or '-',
                Core.commas(ses.best or 0)))
        end
    end
    say(('All counted since %s: %s tokens from %d run%s%s.  (//nz stats reset)'):format(T.since or '?', Core.commas(T.lifetime),
        T.runs, T.runs == 1 and '' or 's', T.best and (', best run ' .. Core.commas(T.best)) or ''))
end

-- Sorrowful Sage's menu says how many tokens you have (its third value)
function Core.sage_menu(p)
    local mp = p and p['Menu Parameters']
    if not (p and p['Menu ID'] == 278 and type(mp) == 'string' and #mp >= 12) then return end
    local mob = windower.ffxi.get_mob_by_index(p['NPC Index'] or 0)
    if not (mob and mob.name == 'Sorrowful Sage') then return end
    local b1, b2, b3, b4 = mp:byte(9, 12)
    Core.tok_balance(b1 + b2 * 256 + b3 * 65536 + b4 * 16777216)
end

-- "You must wait longer to perform that action." just after an /attack: the game turned the
-- engage down (too soon after getting out of the last fight, or after an ability). Once more
-- a moment later, instead of standing there until the next try comes round.
function Core.engage_refused(text)
    if not text:find('You must wait longer to perform that action', 1, true) then return end
    local ea = S.engaged_at
    local now = os.clock()
    if not (ea and ea.sent and now - ea.sent < 2) or ea.refused or (ea.refused_n or 0) >= 2 then return end
    if S.last_act_t and S.last_act_t > ea.sent - 1.5 then return end    -- (that was about an ability or WS)
    ea.refused = true
    debug_log('engage: the game said to wait - trying again in a moment')
    -- (no sooner than 2s after the /attack went: if it did go through after all, you're in the
    -- fight by then, and another /attack would take you out of it)
    coroutine.schedule(function()
        if S.engaged_at ~= ea or not S.auto then return end
        local p = windower.ffxi.get_player()
        local mob = windower.ffxi.get_mob_by_id(ea.id)
        if p and p.status == 0 and mob and (mob.hpp or 0) > 0 and mob.valid_target then
            engage(mob)
            S.engaged_at.refused_n = (ea.refused_n or 0) + 1
            S.next_engage = math.max(S.next_engage or 0, os.clock() + 2.5)
        end
    end, math.max(1.2, ea.sent + 2 - now))
end

FAX.X.stats = Core.stats_command
Core.tok_load()
end

---------------------------------------------------------------------------
-- Stand-ins for the parts this build doesn't have.
---------------------------------------------------------------------------
do
local Nav, Mover, Menus, Loop, FA = {}, {}, {}, {}, {}
FAX.full = false
FAX.cmds = {tokens = true}
FAX.Nav, FAX.Mover, FAX.Menus, FAX.Loop, FAX.FA = Nav, Mover, Menus, Loop, FA
setmetatable(FA, {__index = FAX.Core})
local function nop() end
local function no() return false end
FA.on = false
FA.tick, FA.zone_change, FA.hand_back, FA.stop, FA.new_floor, FA.pull_text = nop, nop, nop, nop, nop, nop
FA.climb_run_started, FA.climb_run_paid = nop, nop
FA.engage_busy, FA.aiming, FA.body_pull_on, FA.gave_up_on, FA.skipped = no, no, no, no, no
FA.leave_need = function() return 0 end
FA.every = function() return 0 end
FA.status_rows = function() return {} end
function FA.command(cmd, args)
    if cmd == 'tokens' then FA.tok_command(args) end
end
Menus.busy, Menus.on_event = no, no
Menus.hex = function() return '' end
Menus.on_answer, Menus.abort, Menus.rune_outcome = nop, nop, nop
Nav.save, Nav.record = nop, nop
Nav.map_id = function() return '?' end
Mover.stop = nop
Loop.stop_record, Loop.note_poke = nop, nop
end

---------------------------------------------------------------------------
-- Display: one list of rows {label, value, gap = extra space above}, drawn either as
-- the roomy two-column "classic" panel or squeezed into one "compact" text box.
---------------------------------------------------------------------------
local WHY_COLOR = {         -- shared by the panel and the radar arrows
    ['on you'] = {200, 110, 255},
    leader     = {255, 70, 70},
    boss       = {255, 70, 70},
    IT         = {255, 165, 0},
    family     = {255, 225, 80},
    enemy      = {235, 235, 170},
    lamp       = {90, 170, 255},
}
local WHY_LABEL = {['on you'] = 'attacking you', leader = 'leader', boss = 'boss', IT = 'impossible to gauge',
                   family = 'family', enemy = 'enemy'}

local function build_rows()
    local rows = {}
    local m = me()
    local gap_next = false
    local function add(l, v)
        rows[#rows + 1] = {l = l or '', v = v or '', gap = gap_next}
        gap_next = false
    end
    local function gap() if #rows > 0 then gap_next = true end end
    local player = windower.ffxi.get_player()

    if S.floor == 0 then
        add('Nyzul Isle', yellow('waiting for first floor'))
        gap()
        for _, r in ipairs(job_rows(player)) do add(r[1], r[2]) end
        add('Auto:', S.auto and green('ON') or grey('off'))
        for _, r in ipairs(FAX.FA.status_rows()) do add(r[1], r[2]) end
        return rows
    end

    local tl = time_left()
    local tstr = tl and fmt_time(tl) or '--:--'
    if tl and tl < 120 then tstr = red(tstr) elseif tl and tl < 300 then tstr = orange(tstr) end
    add('Current Floor:', tostring(S.floor) .. grey(('   (started %d)'):format(S.start_floor)))
    add('Time Remaining:', tstr)

    gap()
    local label = OBJECTIVE_LABEL[S.obj_type] or (S.objective ~= '' and S.objective or 'touch the Rune of Transfer to see it')
    if is_boss_floor() and S.obj_type == 'leader' then label = label .. ' (boss floor)' end
    add('Objective:', S.floor_clear and green(label .. '  - DONE') or yellow(label))
    if S.restriction ~= '' then
        add('Rule:', S.restr_failed and red(S.restriction .. ' (BROKEN)') or orange(S.restriction))
    end
    local p = {}
    if S.pathos.ws then p[#p + 1] = 'no WS' end
    if S.pathos.magic then p[#p + 1] = 'no magic' end
    if S.pathos.ja then p[#p + 1] = 'no JA' end
    if #p > 0 then add('Pathos:', red(table.concat(p, ', '))) end

    -- targets (names coloured like their radar arrows)
    if not S.floor_clear and (S.obj_type == 'enemy' or S.obj_type == 'enemies'
                               or S.obj_type == 'leader' or S.obj_type == 'all') then
        gap()
        local list = find_targets(4)
        if #list == 0 then
            add('Targets:', grey('none in view - keep exploring'))
        else
            for _, t in ipairs(list) do
                local c = WHY_COLOR[t.why] or WHY_COLOR.enemy
                add(color(c[1], c[2], c[3], t.mob.name), where(m, t.mob) .. grey('   ' .. (WHY_LABEL[t.why] or t.why)))
            end
        end
        if S.obj_type ~= 'all' then
            local checked, it = check_stats()
            add('', grey(('checked %d mob%s, %d impossible to gauge'):format(checked, checked == 1 and '' or 's', it)))
        end
    end

    -- archaic gears
    local gc, gear, gd = gear_info()
    if gc > 0 then
        local s = ('%d in view, closest %s'):format(gc, where(m, gear))
        add('Gears:', gd <= settings.gear_warn_range and red(s) or orange(s))
    end

    -- lamps
    if S.obj_type == 'lamps' and not S.floor_clear then
        gap()
        local n = lamp_count()
        local kind = S.lamp_type == 'order' and 'in order'
                  or S.lamp_type == 'same' and 'all at once'
                  or S.lamp_type == 'code' and 'certification (touch it)'
                  or 'touch one to learn the type'
        local seen = lamps_seen()
        add('Lamps:', ('%s - %s%s'):format(kind,
            S.lamp_override and (n .. ' (set)') or seen < n and ('%d found, at least %d'):format(seen, n) or (n .. ' found'), ''))
        local nxt = next_lamp_slot()
        for slot = 1, n do
            local l = S.lamps[slot]
            local mark = letter(slot)
            if S.lamp_type == 'same' then
                mark = mark .. ((l and l.lit) and ' [lit]' or (S.touched[slot] and ' [x]' or ' [ ]'))
            elseif S.lamp_type ~= 'order' then
                mark = mark .. (S.touched[slot] and ' [x]' or ' [ ]')
            end
            local loc = (l and l.x and m) and where(m, l) or 'not seen'
            if slot == nxt then
                add(green('  > ' .. mark), green(loc))
            else
                add('     ' .. mark, loc)
            end
        end
        if S.lamp_type == 'order' then
            local plan, cands = current_plan()
            if plan then
                local parts = {}
                for i, s in ipairs(plan) do
                    local txt = letter(s)
                    if i <= #S.round then txt = grey(txt) elseif i == #S.round + 1 then txt = green(txt) end
                    parts[i] = txt
                end
                add('Try:', table.concat(parts, ' > ') .. grey(('   (%d order%s possible)'):format(cands, cands == 1 and '' or 's')))
            elseif #S.rounds > 0 then
                add('Try:', red('lamp data conflicts - //nz lamps reset'))
            end
            if S.pending_eval then add('', yellow('Round finished - reading lamps...')) end
            if #S.round > 0 then
                local done = {}
                for i, s in ipairs(S.round) do done[i] = letter(s) end
                add('This round:', grey(table.concat(done, ' ')))
            end
            for i = math.max(1, #S.rounds - 2), #S.rounds do
                add(('Round %d:'):format(i), grey(describe_round(S.rounds[i])))
            end
        elseif S.lamp_type == 'same' then
            local order = Same.letters()
            if order then add('Try:', order .. grey('   (shortest run, back to back)')) end
            local _, wait = Same.next()
            if wait then add('', yellow(('next try in %s (lamps stay lit ~5 min, then 30s)'):format(fmt_time(wait)))) end
            local first
            for _, t in pairs(S.touched) do if not first or t < first then first = t end end
            if first then add('', grey(('%ds since first lamp'):format(math.floor(os.clock() - first)))) end
        end
    end

    -- rune
    if S.rune and m then
        gap()
        local s = where(m, S.rune) .. (S.rune.approx and ' (start point)' or '')
        add('Rune of Transfer:', S.floor_clear and green(s .. '   GO') or s)
    end

    local jr = job_rows(player)
    if #jr > 0 then
        gap()
        for _, r in ipairs(jr) do add(r[1], r[2]) end
    end

    gap()
    add('Floors Completed:', tostring(S.completed))
    add('Reward Rate:', ('%d%%'):format(math.floor(token_rate() * 100 + 0.5)))
    add('Potential Tokens:', tostring(S.tokens))
    local trow = FAX.Core.tok_row()
    if trow then add('Token Total:', trow) end
    local srow = FAX.Core.stats_row()
    if srow then add('Session:', srow) end
    local ws = settings.ws_name ~= '' and ('%s @%d'):format(settings.ws_name, settings.ws_tp) or 'none'
    if is_boss_floor() and settings.ws_boss ~= '' then ws = ('%s @%d'):format(settings.ws_boss, settings.ws_boss_tp) .. grey(' (boss)') end
    add('Auto:', (S.auto and green('ON') or grey('off')) .. grey('   WS: ') .. ws)
    if S.ws_note and S.auto then add('', orange(S.ws_note)) end
    for _, r in ipairs(FAX.FA.status_rows()) do add(r[1], r[2]) end
    return rows
end

-- compact style: everything in one text box
local function compact_text(rows)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = (r.l ~= '' and (r.l .. ' ') or '') .. r.v
    end
    return table.concat(out, '\n')
end

local function build_display()
    return compact_text(build_rows())
end

-- classic style: two pixel-aligned columns with room between lines
local Panel = {labels = {}, values = {}, visible = false, rows = nil, line_h = nil}

local function strip_codes(s)
    return (s:gsub('\\cs%(%d+,%d+,%d+%)', ''):gsub('\\cr', ''))
end

local function panel_text()
    local P = settings.panel
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {font = P.font, size = P.size, red = 255, green = 255, blue = 255, alpha = 255,
                stroke = {width = P.stroke, alpha = 200, red = 0, green = 0, blue = 0}},
        bg = {visible = false},
        flags = {draggable = false, bold = P.bold},
        padding = 0,
    })
    t:hide()
    return {t = t, str = nil, shown = false}
end

local function pool_get(pool, i)
    pool[i] = pool[i] or panel_text()
    return pool[i]
end

local function slot_set(slot, str, x, y)
    if slot.str ~= str then slot.t:text(str); slot.str = str end
    slot.t:pos(x, y)
    if not slot.shown then slot.t:show(); slot.shown = true end
end

local function slot_hide(slot)
    if slot.shown then slot.t:hide(); slot.shown = false end
end

-- width in pixels: what the game measured last time it drew this line (at most a
-- quarter-second stale, which is fine for "20:50" vs "20:49"), or an estimate before that
local function text_w(slot, str)
    local w = slot.shown and slot.t:extents()
    if w and w > 0 then return w end
    return #strip_codes(str) * settings.panel.size * 0.62
end

local function panel_layout()
    local rows = Panel.rows
    if not rows or not Panel.bg then return end
    local P = settings.panel
    local x0, y0 = settings.pos.x, settings.pos.y
    local pad = P.padding

    -- line height from a drawn label, else a font-size estimate
    if not Panel.line_h then
        local first, h = Panel.labels[1], nil
        if first and first.shown then h = select(2, first.t:extents()) end
        if h and h > 0 then Panel.line_h = h end
    end
    local lh = Panel.line_h or math.floor(P.size * 1.45 + 0.5)

    local label_w, value_w = 0, 0
    for i, r in ipairs(rows) do
        local L, V = pool_get(Panel.labels, i), pool_get(Panel.values, i)
        if r.l ~= '' then label_w = math.max(label_w, text_w(L, r.l)) end
        if r.v ~= '' then value_w = math.max(value_w, text_w(V, r.v)) end
    end
    local vx = x0 + pad + math.floor(label_w) + P.column_gap

    local y = y0 + pad
    for i, r in ipairs(rows) do
        if r.gap then y = y + P.group_spacing end
        local L, V = Panel.labels[i], Panel.values[i]
        if r.l ~= '' then slot_set(L, r.l, x0 + pad, y) else slot_hide(L) end
        if r.v ~= '' then slot_set(V, r.v, vx, y) else slot_hide(V) end
        y = y + lh + P.line_spacing
    end
    for i = #rows + 1, math.max(#Panel.labels, #Panel.values) do
        if Panel.labels[i] then slot_hide(Panel.labels[i]) end
        if Panel.values[i] then slot_hide(Panel.values[i]) end
    end

    local w = math.floor(vx - x0 + value_w + pad)
    local h = math.floor(y - P.line_spacing - y0 + pad)
    windower.prim.set_position(Panel.bg, x0, y0)
    windower.prim.set_size(Panel.bg, w, h)
    if not Panel.visible then windower.prim.set_visibility(Panel.bg, true) end
    Panel.rect = {x = x0, y = y0, w = w, h = h}
    Panel.visible = true
end

local function panel_init()
    local P = settings.panel
    Panel.bg = 'nyzulassist_panel_bg'
    windower.prim.create(Panel.bg)
    windower.prim.set_color(Panel.bg, P.bg.alpha, P.bg.red, P.bg.green, P.bg.blue)
    windower.prim.set_visibility(Panel.bg, false)
end

local function panel_destroy_texts()
    for _, pool in ipairs({Panel.labels, Panel.values}) do
        for _, slot in ipairs(pool) do slot.t:destroy() end
    end
    Panel.labels, Panel.values, Panel.line_h = {}, {}, nil
end

local function classic_hide()
    if not Panel.visible then return end
    for _, pool in ipairs({Panel.labels, Panel.values}) do
        for _, slot in ipairs(pool) do slot_hide(slot) end
    end
    windower.prim.set_visibility(Panel.bg, false)
    Panel.visible = false
end

local function panel_hide()
    box:hide()
    classic_hide()
end

local function panel_update()
    if S.panel_hidden or not S.in_nyzul then panel_hide(); return end
    local rows = build_rows()
    if settings.panel.style == 'compact' then
        classic_hide()
        box:text(compact_text(rows))
        box:show()
    else
        box:hide()
        Panel.rows = rows
        panel_layout()
    end
end

panel_init()

-- drag the classic panel by clicking anywhere on it
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked or settings.panel.style == 'compact' or not Panel.visible then return end
    local su = FAX.Setup
    if not Panel.drag and su and su.visible and (su.drag or su.at(x, y)) then return end   -- (the setup window's)
    if mtype == 0 and Panel.drag then
        settings.pos.x, settings.pos.y = x - Panel.drag.dx, y - Panel.drag.dy
        panel_layout()
        return true
    elseif mtype == 1 then
        local b = Panel.rect
        if b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            Panel.drag = {dx = x - settings.pos.x, dy = y - settings.pos.y}
            return true
        end
    elseif mtype == 2 and Panel.drag then
        Panel.drag = nil
        box:pos(settings.pos.x, settings.pos.y)
        config.save(settings)
        return true
    end
end)


---------------------------------------------------------------------------
-- Setup window (//nz setup): click a line to switch it on or off
---------------------------------------------------------------------------
do
local Setup = {rows = {}, visible = false, line_h = 0, width = 0, chars = 0}
FAX.Setup = Setup
local W = 64                                   -- characters a line at least (all padded to the longest, so the window is even)
local FONT = 10
-- size estimates for Consolas 10 with 2 px padding, until the game has drawn the text once
local function est_w(chars) return math.floor(chars * FONT * 0.73 + 4 + 0.5) end
local EST_H = math.floor(FONT * 1.45 + 4 + 0.5)

local function onoff(v) return v and green('[ ON]') or grey('[off]') end
local function hint(cmd) return function() say(grey('Type ') .. cmd) end end
local function run(...) local a = {...}; return function() FAX.command(unpack(a)) end end

function Setup.items()
    local items = {}
    local function add(text, act) items[#items + 1] = {text = text, act = act} end
    local function head(text) add(grey('-- ' .. text .. ' ' .. string.rep('-', W - 5 - #text))) end
    items[1] = {title = ('NyzulAssist %s setup'):format(_addon.version) .. grey('   (click a line)'), act = function() Setup.hide() end}
    head('Fighting')
    add(onoff(S.auto) .. ' Semi-auto: fights objective mobs near you', run('auto'))
    add('      Weaponskill: ' .. (settings.ws_name ~= '' and ('%s at %d TP'):format(settings.ws_name, settings.ws_tp) or orange('none')),
        hint('//nz ws <name> <TP>  e.g. //nz ws Savage Blade 1000'))
    add('      Boss floors: ' .. (settings.ws_boss ~= '' and settings.ws_boss or 'same WS') .. grey('   backup: ')
        .. (settings.ws_alt ~= '' and settings.ws_alt or 'none'), hint('//nz ws boss <name> [TP]   or   //nz ws backup <name>'))
    add(onoff(settings.autocheck) .. ' Find the "impossible to gauge" mob (auto /check)', run('check'))
    add(onoff(settings.defend) .. ' Fight back against anything attacking you', run('defend'))
    add(onoff(settings.autoface) .. ' Face your target', run('face'))
    add(onoff(settings.autoobject) .. ' Target the lamp / Rune you walk up to', run('objects'))
    head('Jobs')
    add(onoff(settings.cor) .. (' Corsair rolls: %s, in a fight %s'):format(roll_names(settings.cor_idle_rolls),
        roll_names(settings.cor_combat_rolls)), run('cor'))
    add(onoff(settings.waltz) .. (' Dancer waltz: III at %d%%, II at %d%% HP'):format(settings.waltz3_hpp, settings.waltz2_hpp), run('waltz'))
    add(onoff(settings.jig) .. ' Spectral Jig when not fighting', run('jig'))
    local function summary(which)
        local parts = {}
        for _, r in ipairs(FAX.Rules.list(which)) do parts[#parts + 1] = r.name end
        local str = #parts > 0 and table.concat(parts, ', ') or 'none'
        return #str > 40 and (str:sub(1, 38) .. '..') or str
    end
    add(onoff(settings.rules_on) .. ' Buffs: ' .. summary('buffs'), run('buff', settings.rules_on and 'off' or 'on'))
    add('      Heals: ' .. summary('heals'), hint('//nz buff add <name> [fight|idle|always]   //nz heal add <name> <HP%>'))
    head('Display')
    add(onoff(settings.radar.show) .. ' Radar', run('radar'))
    add('      Panel: ' .. settings.panel.style .. grey(' (click to switch)'),
        run('style', settings.panel.style == 'classic' and 'compact' or 'classic'))
    local dirs = {compass = 'clock', clock = 'both', both = 'compass'}
    add('      Directions: ' .. settings.directions .. grey(' (click to switch)'), run('dir', dirs[settings.directions] or 'compass'))
    head('Other')
    add(onoff(S.debug) .. ' Debug log (for bug reports: //nz report)', run('debug'))
    add(onoff(settings.update_check) .. ' Look for a new version once a week, at login', run('update', settings.update_check and 'off' or 'on'))
    add(grey('Help: //nz help    Tips: ' .. FAX.TIP_URL))
    add(grey('Updates: ' .. FAX.HOME_URL))
    return items
end

local function row(i)
    local r = Setup.rows[i]
    if not r then
        r = {t = texts.new('', {
            pos = {x = 0, y = 0},
            text = {font = 'Consolas', size = 10, red = 235, green = 235, blue = 235, stroke = {width = 1, alpha = 180}},
            bg = {alpha = 200, red = 15, green = 15, blue = 25, visible = true},
            flags = {draggable = false},
            padding = 2,
        })}
        r.t:hide()
        Setup.rows[i] = r
    end
    return r
end

-- put the rows one under the other
local function place()
    local x, y = settings.setup_pos.x, settings.setup_pos.y
    for i = 1, Setup.n or 0 do
        local r = Setup.rows[i]
        r.y = y + (i - 1) * Setup.line_h
        r.t:pos(x, r.y)
    end
end

-- the game measures a text when it draws it, so right after a change extents() still gives
-- the old size (for a new row: just its padding, 4 x 4). Measure a moment later, and keep
-- the estimates until the numbers are believable.
function Setup.measure()
    Setup.measuring = nil
    if not Setup.visible or not Setup.rows[1] then return end
    local w, h = Setup.rows[1].t:extents()
    if not (w and h and h >= 10 and h <= 60 and w >= Setup.chars * 4) then
        Setup.tries = (Setup.tries or 0) + 1
        if Setup.tries <= 8 then
            Setup.measuring = true
            coroutine.schedule(Setup.measure, 0.25)
        end
        return
    end
    Setup.tries = 0
    if math.abs(h - Setup.line_h) >= 1 or math.abs(w - Setup.width) >= 2 then
        Setup.line_h, Setup.width = h, w
        place()
    end
end

function Setup.draw()
    if not Setup.visible then return end
    local items = Setup.items()
    local chars = W
    for _, it in ipairs(items) do chars = math.max(chars, #strip_codes(it.text or it.title) + (it.title and 8 or 0)) end
    for i, it in ipairs(items) do
        local r = row(i)
        local text
        if it.title then                               -- [close] at the right-hand end
            text = it.title .. string.rep(' ', chars - #strip_codes(it.title) - 7) .. orange('[close]')
        else
            text = it.text .. string.rep(' ', chars - #strip_codes(it.text))
        end
        r.t:text(text)
        r.act = it.act
        r.t:show()
    end
    for i = #items + 1, #Setup.rows do Setup.rows[i].t:hide(); Setup.rows[i].act, Setup.rows[i].y = nil, nil end
    Setup.n = #items
    if chars ~= Setup.chars then                       -- (a longer line: estimate the width again, then measure)
        Setup.chars, Setup.width = chars, est_w(chars)
    end
    if Setup.line_h <= 0 then Setup.line_h = EST_H end
    place()
    if not Setup.measuring then
        Setup.tries, Setup.measuring = 0, true
        coroutine.schedule(Setup.measure, 0.25)
    end
end
function Setup.show() Setup.visible = true; Setup.draw() end
function Setup.hide()
    Setup.visible = false
    for _, r in ipairs(Setup.rows) do r.t:hide() end
end
-- the row under the mouse (nil if none)
function Setup.at(x, y)
    if not Setup.visible then return nil end
    local x0 = settings.setup_pos.x
    if x < x0 or x > x0 + Setup.width then return nil end
    for i = 1, Setup.n or 0 do
        local r = Setup.rows[i]
        if r.y and y >= r.y and y < r.y + Setup.line_h then return i, r end
    end
end

FAX.X.setup = function() if Setup.visible then Setup.hide() else Setup.show() end end
FAX.X.config = FAX.X.setup
FAX.X.settings = FAX.X.setup

windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if not Setup.visible then Setup.drag = nil return end
    if Setup.drag then
        if mtype == 0 then
            settings.setup_pos.x, settings.setup_pos.y = x - Setup.drag.dx, y - Setup.drag.dy
            Setup.draw()
            return true
        elseif mtype == 1 or mtype == 2 then           -- (let go - or a click after a let-go we never saw)
            Setup.drag = nil
            config.save(settings)
            return true
        end
    end
    if blocked then return end
    local i, r = Setup.at(x, y)
    if mtype == 1 and i then
        if i == 1 and x < settings.setup_pos.x + Setup.width * 0.75 then
            Setup.drag = {dx = x - settings.setup_pos.x, dy = y - settings.setup_pos.y, moved = false}   -- (the title bar: drag)
        elseif r.act then
            r.act()
            Setup.draw()
        end
        return true
    elseif mtype == 2 and i then
        return true
    end
end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Radar widget: big arrow -> Rune of Transfer, small arrows -> targets / next lamp
-- Windower prims can't rotate, so each arrow is drawn from small squares.
---------------------------------------------------------------------------
local PRIM = 'nyzulassist'
local Radar = {prims = {}, state = {}, items = {}, labels = {}, visible = false}


local function prim_new(name, a, r, g, b)
    windower.prim.create(name)
    windower.prim.set_color(name, a, r, g, b)
    windower.prim.set_visibility(name, false)
    Radar.prims[#Radar.prims + 1] = name
    Radar.state[name] = {visible = false}
    return name
end

local function prim_show(name, visible)
    local st = Radar.state[name]
    if st.visible ~= visible then
        windower.prim.set_visibility(name, visible)
        st.visible = visible
    end
end

local function prim_color(name, a, r, g, b)
    local st = Radar.state[name]
    local key = a * 16777216 + r * 65536 + g * 256 + b
    if st.color ~= key then
        windower.prim.set_color(name, a, r, g, b)
        st.color = key
    end
end

local function arrow_new(id, length, thick, head)
    local a = {length = length, thick = thick, head = head, outline = {}, fill = {}, shown = false}
    local step = math.max(1, thick * 0.6)
    a.shaft_n = math.floor(length / step) + 1
    a.head_n = math.floor(head / step) + 1
    a.n = a.shaft_n + 2 * a.head_n
    for i = 1, a.n do      -- dark outline first so the colour draws on top
        a.outline[i] = prim_new(('%s_%s_o%d'):format(PRIM, id, i), 210, 0, 0, 0)
        windower.prim.set_size(a.outline[i], thick + 2, thick + 2)
    end
    for i = 1, a.n do
        a.fill[i] = prim_new(('%s_%s_f%d'):format(PRIM, id, i), 255, 255, 255, 255)
        windower.prim.set_size(a.fill[i], thick, thick)
    end
    return a
end

local function arrow_hide(a)
    if not a.shown then return end
    for i = 1, a.n do prim_show(a.outline[i], false); prim_show(a.fill[i], false) end
    a.shown = false
end

-- Tail at (tx, ty), pointing along unit vector (ux, uy) in screen space (y grows downward).
local function arrow_draw(a, tx, ty, ux, uy, rgb, alpha)
    local l = a.last
    if a.shown and l and math.abs(l[1] - tx) < 0.5 and math.abs(l[2] - ty) < 0.5
       and math.abs(l[3] - ux) < 0.01 and math.abs(l[4] - uy) < 0.01 then
        for i = 1, a.n do prim_color(a.fill[i], alpha or 255, rgb[1], rgb[2], rgb[3]) end
        return                                      -- nothing moved
    end
    a.last = {tx, ty, ux, uy}
    local pts = {}
    for i = 0, a.shaft_n - 1 do
        local f = a.length * i / math.max(1, a.shaft_n - 1)
        pts[#pts + 1] = {tx + ux * f, ty + uy * f}
    end
    local hx, hy = tx + ux * a.length, ty + uy * a.length
    local c, s = math.cos(math.rad(150)), math.sin(math.rad(150))
    for _, sign in ipairs({1, -1}) do
        local vx, vy = ux * c - uy * s * sign, ux * s * sign + uy * c
        for j = 1, a.head_n do
            local f = a.head * j / a.head_n
            pts[#pts + 1] = {hx + vx * f, hy + vy * f}
        end
    end
    local t, o = a.thick, a.thick + 2
    for i = 1, a.n do
        local p = pts[i]
        windower.prim.set_position(a.outline[i], math.floor(p[1] - o / 2), math.floor(p[2] - o / 2))
        windower.prim.set_position(a.fill[i], math.floor(p[1] - t / 2), math.floor(p[2] - t / 2))
        prim_color(a.fill[i], alpha or 255, rgb[1], rgb[2], rgb[3])
        if not a.shown then prim_show(a.outline[i], true); prim_show(a.fill[i], true) end
    end
    a.shown = true
end

local function small_label()
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {font = 'Consolas', size = 8, red = 255, green = 255, blue = 255, stroke = {width = 1, alpha = 255}},
        bg = {visible = false},
        flags = {draggable = false},
    })
    t:hide()
    return t
end

local function radar_init()
    local r = settings.radar
    if r.pos.x < 0 or r.pos.y < 0 then
        local ws = windower.get_windower_settings()
        r.pos.x = math.floor((ws and ws.ui_x_res or 1280) / 2 - r.size / 2)
        r.pos.y = 40
    end
    Radar.title = texts.new(r)
    Radar.title:hide()
    Radar.bg = prim_new(PRIM .. '_bg', r.bg.alpha, r.bg.red, r.bg.green, r.bg.blue)
    local W = r.size
    Radar.rune = arrow_new('rune', math.floor(W * 0.42), 5, math.floor(W * 0.14))
    for i = 1, 5 do
        Radar.items[i] = arrow_new('m' .. i, 18, 3, 7)
        Radar.labels[i] = small_label()
    end
    Radar.north = small_label()
    Radar.north:text('N')
end

local function radar_hide()
    if not Radar.title or not Radar.visible then return end
    Radar.title:hide()
    prim_show(Radar.bg, false)
    arrow_hide(Radar.rune)
    for i = 1, #Radar.items do arrow_hide(Radar.items[i]); Radar.labels[i]:hide() end
    Radar.north:hide()
    Radar.visible = false
end

local function bearing(from, to)       -- clockwise from north
    return (math.pi / 2 - math.atan2(to.y - from.y, to.x - from.x)) % (2 * math.pi)
end

-- Camera direction. Windower's get_camera() fields aren't documented, so instead of
-- guessing, the addon learns how to read them: while you run forward, your movement
-- direction is the camera's forward direction. Each way of reading the fields is
-- scored against that, and the best one is saved once it's clearly right.
local CAM_WAYS = {
    {key = 'pos_xy',  f = function(m, c) return m.x - c.camera_x, m.y - c.camera_y end},
    {key = 'pos_xz',  f = function(m, c) return m.x - c.camera_x, m.y - c.camera_z end},
    {key = 'npos_xy', f = function(m, c) return c.camera_x - m.x, c.camera_y - m.y end},
    {key = 'npos_xz', f = function(m, c) return c.camera_x - m.x, c.camera_z - m.y end},
    {key = 'dir_xy',  f = function(m, c) return c.camera_x, c.camera_y end},
    {key = 'dir_xz',  f = function(m, c) return c.camera_x, c.camera_z end},
    {key = 'ndir_xy', f = function(m, c) return -c.camera_x, -c.camera_y end},
    {key = 'ndir_xz', f = function(m, c) return -c.camera_x, -c.camera_z end},
}
local CAM_BY_KEY = {}
for _, w in ipairs(CAM_WAYS) do CAM_BY_KEY[w.key] = w end
local Cal = {stats = {}, last = nil}

local function get_cam()
    local ok, cam = pcall(windower.ffxi.get_camera)
    if ok and type(cam) == 'table' and cam.camera_x and cam.camera_y and cam.camera_z then return cam end
end

local function cam_heading(way, m, cam)   -- math angle (counter-clockwise from east), or nil
    local ok, vx, vy = pcall(way.f, m, cam)
    if not ok or not vx or not vy then return nil end
    if vx * vx + vy * vy < 1e-4 then return nil end
    return math.atan2(vy, vx)
end

local function cam_best()
    local best, second
    for key, st in pairs(Cal.stats) do
        if st.n >= 1 then
            local mean = st.sum / st.n
            if not best or mean > best.mean then
                second = best
                best = {key = key, mean = mean, n = st.n}
            elseif not second or mean > second.mean then
                second = {key = key, mean = mean, n = st.n}
            end
        end
    end
    return best, second
end

-- called every 0.25s
local function cam_learn()
    if settings.radar.up ~= 'camera' or settings.radar.cam_calib ~= '' then return end
    local m, cam = me(), get_cam()
    if not m or not cam then return end
    local last = Cal.last
    Cal.last = {x = m.x, y = m.y}
    if not last then return end
    local d = dist2d(last, m)
    if d < 0.8 or d > 10 then return end            -- standing still, or a teleport
    local move = math.atan2(m.y - last.y, m.x - last.x)
    for _, way in ipairs(CAM_WAYS) do
        local h = cam_heading(way, m, cam)
        if h then
            local st = Cal.stats[way.key] or {n = 0, sum = 0}
            st.n, st.sum = st.n + 1, st.sum + math.cos(h - move)
            Cal.stats[way.key] = st
        end
    end
    local best, second = cam_best()
    if best and best.n >= 40 and best.mean >= 0.85 and (not second or second.mean <= best.mean - 0.25) then
        settings.radar.cam_calib = best.key
        config.save(settings)
        debug_log(('camera learned: %s (match %.2f over %d steps)'):format(best.key, best.mean, best.n))
        say(green('Radar: camera direction learned.'))
    end
end

-- The compass bearing that points "up" on the radar.
local function view_bearing(m)
    local mode = settings.radar.up
    if mode == 'north' then return 0, 'north' end
    if mode == 'camera' then
        local cam = get_cam()
        if cam then
            local way = CAM_BY_KEY[settings.radar.cam_calib]
            if not way then
                local best = cam_best()
                if best and best.n >= 12 and best.mean >= 0.75 then way = CAM_BY_KEY[best.key] end
            end
            local h = way and cam_heading(way, m, cam)
            if h then return (math.pi / 2 - h) % (2 * math.pi), 'camera' end
            return (math.pi / 2 + (m.facing or 0)) % (2 * math.pi), 'learning'
        end
    end
    -- character facing (FFXI facing: 0 = east, clockwise)
    return (math.pi / 2 + (m.facing or 0)) % (2 * math.pi), 'facing'
end

-- Every 0.25s: decide what the small arrows point at (the per-frame redraw reuses this list).
local function radar_pick()
    local items = {}
    if S.floor > 0 and not S.floor_clear and S.obj_type == 'lamps' then
        local slot = next_lamp_slot()
        local l = slot and S.lamps[slot]
        if l and l.x then items[#items + 1] = {x = l.x, y = l.y, rgb = WHY_COLOR.lamp, tag = letter(slot)} end
    end
    for _, t in ipairs(find_targets(4)) do     -- after a clear this is only mobs attacking you
        items[#items + 1] = {index = t.mob.index, x = t.mob.x, y = t.mob.y, rgb = WHY_COLOR[t.why] or WHY_COLOR.enemy}
    end
    Radar.pick = items
end

local function radar_draw()
    if not Radar.title then return end
    local m = me()
    if not settings.radar.show or S.panel_hidden or not S.in_nyzul or S.floor == 0 or not m then
        radar_hide()
        return
    end

    local W = settings.radar.size
    local lx, ly = Radar.title:pos()
    local bx, by = lx, ly + 20
    local cx, cy = bx + W / 2, by + W / 2
    local view, used = view_bearing(m)
    local hint = used == 'learning' and '  \\cs(160,160,160)(run to set camera)\\cr' or ''

    if not Radar.visible then Radar.title:show(); Radar.visible = true end
    windower.prim.set_position(Radar.bg, bx, by)
    windower.prim.set_size(Radar.bg, W, W)
    prim_show(Radar.bg, true)

    -- north marker on the rim
    local nrel = -view
    Radar.north:pos(math.floor(cx + math.sin(nrel) * (W / 2 - 8) - 3), math.floor(cy - math.cos(nrel) * (W / 2 - 8) - 6))
    Radar.north:show()

    -- big arrow to the rune
    if S.rune then
        local rel = bearing(m, S.rune) - view
        local ux, uy = math.sin(rel), -math.cos(rel)
        local L = Radar.rune.length
        local rgb = S.floor_clear and {80, 255, 80} or {220, 220, 220}
        arrow_draw(Radar.rune, cx - ux * L / 2, cy - uy * L / 2, ux, uy, rgb, S.floor_clear and 255 or 170)
        local d = math.floor(dist2d(m, S.rune) + 0.5)
        Radar.title:text(('Rune %dy %s%s%s'):format(d, compass_dir(m, S.rune),
            S.floor_clear and '  \\cs(80,255,80)GO\\cr' or '', hint))
    else
        arrow_hide(Radar.rune)
        Radar.title:text('Rune: looking...')
    end

    -- small arrows on the rim
    local tip_r = W / 2 - 6                       -- small arrows end just inside the edge
    for i = 1, #Radar.items do
        local it = Radar.pick and Radar.pick[i]
        local a, lab = Radar.items[i], Radar.labels[i]
        local pos = it
        if it and it.index then
            local mob = windower.ffxi.get_mob_by_index(it.index)
            pos = (mob and (mob.hpp or 0) > 0) and mob or nil
        end
        if pos then
            local rel = bearing(m, pos) - view
            local ux, uy = math.sin(rel), -math.cos(rel)
            local tail = tip_r - a.length
            arrow_draw(a, cx + ux * tail, cy + uy * tail, ux, uy, it.rgb)
            local d = math.floor(dist2d(m, pos) + 0.5)
            lab:text((it.tag and (it.tag .. ' ') or '') .. d)
            lab:pos(math.floor(cx + ux * (tail - 12) - 6), math.floor(cy + uy * (tail - 12) - 6))
            lab:color(it.rgb[1], it.rgb[2], it.rgb[3])
            lab:show()
        else
            arrow_hide(a)
            lab:hide()
        end
    end
end

radar_init()

local function radar_rebuild()
    radar_hide()
    for _, name in ipairs(Radar.prims) do windower.prim.delete(name) end
    if Radar.title then Radar.title:destroy() end
    for _, l in ipairs(Radar.labels) do l:destroy() end
    if Radar.north then Radar.north:destroy() end
    Radar.prims, Radar.state, Radar.items, Radar.labels, Radar.visible = {}, {}, {}, {}, false
    radar_init()
end

windower.register_event('unload', function()
    FAX.Menus.abort('addon unloaded')
    FAX.Mover.stop()
    FAX.Nav.save()
    for _, name in ipairs(Radar.prims) do windower.prim.delete(name) end
    windower.prim.delete(Panel.bg)
end)

local last_tick, last_draw, last_radar = 0, 0, 0

windower.register_event('prerender', function()
    FAX.FA.tick()
    if not S.in_nyzul then return end
    local now = os.clock()
    if now - last_tick >= 0.25 then
        last_tick = now
        if S.floor > 0 then FAX.Nav.record(me()) end
        poll_lamps()
        lamp_eval_tick()
        check_tick()
        request_tick()
        auto_tick()
        rune_tick()
        cam_learn()
        radar_pick()
        if S.debug and type(windower.ffxi.get_camera) == 'function' and now - (S.last_cam_log or 0) >= 5 then
            S.last_cam_log = now
            local m, cam = me(), get_cam()
            if m then
                local b, used = view_bearing(m)
                debug_log(('cam %s | me %.1f,%.1f,%.1f f=%.2f | up=%.0f deg (%s) calib=%s'):format(
                    cam and ('%.2f,%.2f,%.2f'):format(cam.camera_x, cam.camera_y, cam.camera_z) or 'none',
                    m.x, m.y, m.z or 0, m.facing or 0, math.deg(b), used, settings.radar.cam_calib))
            end
        end
    end
    if now - last_draw >= 0.25 then
        last_draw = now
        panel_update()
    end
    if now - last_radar >= 0.05 then
        last_radar = now
        radar_draw()
    end
end)

-- Latch it: the armband may be used up as you go in, so a later update may no longer list
-- it even though the bonus applies to this run. Cleared when you leave Nyzul.
check_armband = function()
    for _, k in pairs(windower.ffxi.get_key_items() or {}) do
        if k == KI_ARMBAND then
            if not S.has_armband then debug_log('Assault armband found: +10% tokens') end
            S.has_armband = true
        end
    end
end

local function enter_nyzul()
    S.in_nyzul = true
    check_armband()
    local pi = windower.ffxi.get_party_info()
    S.party_size = pi and pi.party1_count or 1
    panel_update()
end

windower.register_event('load', 'login', function()
    if in_nyzul() then enter_nyzul() else panel_hide() end
    local info = windower.ffxi.get_info()
    if not (info and info.logged_in) then return end   -- (loaded at the title screen: say hello at login)
    FAX.update_tick()
    if not settings.welcomed then
        settings.welcomed = true
        config.save(settings)
        say(('NyzulAssist %s by %s - %s to set it up, %s for every command.'):format(_addon.version, _addon.author,
            green('//nz setup'), green('//nz help')))
    end
end)

windower.register_event('zone change', function(new_id, old_id)
    FAX.FA.zone_change(new_id, old_id)
    if old_id == ZONE_NYZUL then
        if S.auto and not FAX.FA.on then say('Left Nyzul Isle - auto off.') end
        S.auto = false
        reset_run()
        S.has_armband = false     -- the armband is used up by the run
        panel_hide()
        radar_hide()
    end
    if new_id == ZONE_NYZUL then
        enter_nyzul()
    end
end)

windower.register_event('status change', function(new, old)
    if new == 2 or new == 3 then
        if S.auto then
            S.auto = false
            say(red('You died - auto off.'))
        end
        FAX.FA.hand_back('you died', true)
    end
end)

windower.register_event('incoming text', function(original, modified, mode, modified_mode, blocked)
    -- (lines another addon hid are still read: hiding them doesn't make them less true)
    if not original or original == '' then return end
    if mode == MODE_TELL_IN and (S.auto or FAX.FA.on or FAX.FA.retry) and settings.pause_on_tell then
        S.auto = false
        FAX.FA.hand_back('tell received', true)
        say(red('Tell received - auto PAUSED. //nz auto to resume.'))
        return
    end
    if FAX.FA.on and not PLAYER_MODES[mode] and original:find('Nothing happens', 1, true) then FAX.FA.nothing_t = os.clock() end
    if not S.in_nyzul then return end
    if PLAYER_MODES[mode] then return end
    -- our own chat lines (and debug) come back through this event: never parse them
    if original:find('[Nyzul]', 1, true) then return end
    local text = original:strip_format()
    FAX.FA.pull_text(text)
    FAX.Core.engage_refused(text)
    if not SYSTEM_MODES[mode] then
        -- battle/loot lines (or other addons' rewrites of them) can mention "Archaic" etc.
        if text:find('Event skipped') then undo_last_touch() end
        if text:find('objective complete') and text:find('Rune of Transfer') then
            debug_log(('[mode %d] %s'):format(mode, text))
            floor_cleared()
        end
        return
    end
    if S.debug then debug_log(('[mode %d] %s'):format(mode, text)) end
    handle_system_text(text, mode)
end)

windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    -- armband (more tokens) is checked while in Alzadaal, before entry
    if id == 0x055 then
        local info = windower.ffxi.get_info()
        if info and (info.zone == ZONE_ALZADAAL or info.zone == ZONE_NYZUL) then
            -- key items update a moment after this packet, so look again shortly
            coroutine.schedule(check_armband, 0.5)
        end
        return
    end

    if id == 0x05C and not injected then FAX.Menus.update_t = os.clock() end
    if S.debug and (id == 0x05C or id == 0x052 or id == 0x05A) and FAX.Menus.busy() then
        debug_log(('menu: in 0x%03X %s'):format(id, FAX.Menus.hex(data:sub(5, 44))))
    end
    if (id == 0x032 or id == 0x033 or id == 0x034) and not injected then
        local p = packets.parse('incoming', data)
        FAX.Core.sage_menu(p)
        if p and FAX.Menus.on_event(p, id) then return true end
        return
    end

    if id == 0x017 and (S.auto or FAX.FA.on or FAX.FA.retry) and settings.pause_on_tell then
        -- GM flag on any incoming chat
        local p = packets.parse('incoming', data)
        if p and p['GM'] and p['Mode'] ~= 33 then           -- (33 = Unity chat: its NPC lines carry the flag)
            S.auto = false
            FAX.FA.hand_back('GM message', true)
            say(red('GM message - auto PAUSED.'))
        end
        return
    end

    if not S.in_nyzul then return end

    if id == 0x00E then
        local idx = data:byte(9) + data:byte(10) * 256
        if idx < IDX_RUNE_FIRST or idx > IDX_LAMP_LAST then return end
        local p = packets.parse('incoming', data)
        if not p then return end
        local mask = p['Mask'] or 0
        local slot = lamp_slot(idx)
        local has_pos = bit.band(mask, 0x01) ~= 0
        if not slot and S.rune and S.rune.index == idx then
            local u4 = p['_unknown4'] or 0
            if bit.band(mask, 0x04) ~= 0 or u4 > 0 then
                local lit = bit.band(u4, LIT_BIT) ~= 0
                debug_log(('rune %d mask=%02X u4=%08X lit=%s'):format(idx, mask, u4, tostring(lit)))
                -- seen dark on this floor, now lit (lamp floors start lit, so only a change counts)
                if lit and S.rune.seen_dark and not S.floor_clear then
                    debug_log('floor clear (Rune of Transfer lit up)')
                    floor_cleared()
                end
                if not lit then S.rune.seen_dark = true end
            end
        end
        if slot then
            local l = record_lamp(slot, has_pos and p['X'] or nil, has_pos and p['Y'] or nil)
            local u4 = p['_unknown4'] or 0
            if bit.band(mask, 0x20) ~= 0 then l.gone_t = os.clock() end
            if bit.band(mask, 0x04) ~= 0 or u4 > 0 then
                local was = l.lit
                l.lit = bit.band(u4, LIT_BIT) ~= 0
                l.flag_t = os.clock()
                if l.lit and not was then l.lit_t = os.clock() end
                if was and not l.lit then l.dark_t = os.clock() end
                -- (mask 0x08 = it just came into view: a lamp that's been lit a while isn't "switching on")
                if l.lit and not was and bit.band(mask, 0x08) == 0 then lamp_switched_on(slot) end
                lamp_late_reading(slot, l.lit)
            end
            debug_log(('lamp %s mask=%02X u4=%08X lit=%s'):format(letter(slot), mask, u4, tostring(l.lit)))
        end
        return
    end

    if id == 0x029 then
        local p = packets.parse('incoming', data)
        if not p then return end
        local msg = p['Message'] or 0
        if msg == 4 or msg == 5 or msg == 78 or msg == 154 or msg == 198 or msg == 217 or msg == 219 or msg == 328 then
            local player = windower.ffxi.get_player()      -- "<target> is out of range" / "Unable to see <target>"
            if player and p['Actor'] == player.id then
                FAX.FA.oor = {id = p['Target'], t = os.clock(), msg = msg, check = S.pending[p['Target']] ~= nil}
            end
            return
        end
        if msg == MSG_CHECK_IT or (msg >= 170 and msg <= 178) then
            local player = windower.ffxi.get_player()
            local tid = p['Target']
            if player and tid == player.id then tid = p['Actor'] end
            S.checks[tid] = (msg == MSG_CHECK_IT) and 'it' or 'normal'
            if msg == MSG_CHECK_IT then
                local mob = windower.ffxi.get_mob_by_id(tid)
                if mob and not is_nm_name(mob.name) and not mob.name:find('^Archaic')
                   and (S.obj_type == 'enemy' or S.obj_type == 'enemies') then
                    say(green('Target found: ') .. mob.name .. '  ' .. where(me(), mob))
                end
            end
            if S.pending[tid] then
                S.pending[tid] = nil
                if settings.hide_checks then return true end
            end
        end
        return
    end
end)

-- Corsair roll results (the same action packet carries the first roll and every Double-Up).
-- Also: any monster that attacks, uses a move or casts on you is marked as "on you".
windower.register_event('action', function(act)
    if not S.in_nyzul then return end
    local player = windower.ffxi.get_player()
    if not player then return end
    if act.actor_id ~= player.id then
        for _, t in ipairs(act.targets or {}) do
            if t.id == player.id then
                if not S.aggro[act.actor_id] then debug_log(('aggro: %d is after you (action %d)'):format(act.actor_id, act.category)) end
                S.aggro[act.actor_id] = os.clock()
                break
            end
        end
        return
    end
    FAX.Rules.done(act.category, act.param)
    if act.category == 1 then          -- your melee round: who you're actually swinging at
        S.swung = S.swung or {}
        for _, t in ipairs(act.targets or {}) do S.swung[t.id] = os.clock() end
        return
    end
    if act.category == 12 or act.category == 2 then      -- your ranged attack: started aiming / went off
        local lp = FAX.FA and FAX.FA.last_pull
        if lp and lp.sent then
            if act.category == 2 or act.param == 28787 then lp.fired = os.clock()   -- (28787 = interrupted)
            else lp.began = os.clock() end
        end
        return
    end
    if act.category == 3 then          -- your weaponskill landed (auto or by hand)
        S.next_ja = math.max(S.next_ja, os.clock() + 2)
        -- "<target> recovers N HP" from your WS: that mob absorbs it
        for _, t in ipairs(act.targets or {}) do
            local a = t.actions and t.actions[1]
            if a and (a.message == 238 or a.message == 103) and t.id ~= player.id then
                local mob = windower.ffxi.get_mob_by_id(t.id)
                if mob and mob.spawn_type ~= SPAWN_MONSTER then mob = nil end
                local ws = S.last_ws and os.clock() - S.last_ws.t < 6 and S.last_ws.name or nil
                if mob then WS.learn_heal(mob.name, ws) end
            end
        end
        return
    end
    if act.category ~= 6 then return end
    if not ROLL_BY_ID[act.param] and act.param ~= JA_DOUBLE_UP then return end
    local t1 = act.targets and act.targets[1]
    local a1 = t1 and t1.actions and t1.actions[1]
    if not a1 then return end

    local c = S.cor
    local id = ROLL_BY_ID[act.param] and act.param or (c.last and c.last.id)
    c.pending = nil
    S.next_ja = math.max(S.next_ja, os.clock() + 1.5)
    if a1.message == MSG_BUST then
        if id then c.totals[id] = 'BUST' end
        c.last = nil
        say(red('Bust!') .. ' (rolls continue on the next Phantom Roll recast)')
    elseif MSG_ROLL[a1.message] or MSG_DOUBLE[a1.message] then
        local first = MSG_ROLL[a1.message]
        c.last = {id = id, total = a1.param, t = (first or not c.last) and os.clock() or c.last.t}
        if id then c.totals[id] = a1.param end
        debug_log(('roll %s = %s (msg %d)'):format(tostring(id), tostring(a1.param), a1.message))
    end
end)

windower.register_event('outgoing chunk', function(id, original, modified, injected, blocked)
    if blocked then return end
    if S.debug and id ~= 0x015 and FAX.Menus.busy() then
        debug_log(('menu: out 0x%03X %s%s'):format(id, FAX.Menus.hex(original:sub(5, 44)), injected and ' (addon)' or ''))
    end
    if id == 0x05B or id == 0x05C then
        FAX.Menus.on_answer(id, packets.parse('outgoing', original), injected)
        return
    end
    if id == 0x01A and not injected then
        local p = packets.parse('outgoing', original)
        if p and p['Category'] == 0 then FAX.Loop.note_poke(windower.ffxi.get_mob_by_index(p['Target Index'] or 0)) end
    end
    if not S.in_nyzul then return end
    if id == 0x01A then
        local p = packets.parse('outgoing', original)
        if p and p['Category'] == 0 then                 -- NPC interaction
            local slot = lamp_slot(p['Target Index'])
            if slot then
                on_lamp_touch(slot)
                S.last_object = nil      -- allow pre-targeting the next lamp
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local function on_off(arg, current)
    if arg == 'on' then return true elseif arg == 'off' then return false end
    return not current
end

-- Help: //nz help lists the groups, //nz help <group> lists that group's commands.
local function help_groups()
    local onoff = function(v) return v and 'on' or 'off' end
    return {
        {name = 'Auto', aliases = {'auto', 'semi-auto', 'semiauto', 'fight', 'combat'},
         desc = 'semi-auto fighting, weaponskill, targeting',
         lines = {
            'auto [on|off]          fight objective mobs near you, WS, face target, pre-target lamp/rune (' .. onoff(S.auto) .. ')',
            'ws <name> [tp]         auto weaponskill, e.g. //nz ws Savage Blade 1000  |  ws off',
            'ws backup <name>|off   for mobs your WS heals, and instead of an area WS next to a gear (' .. (settings.ws_alt ~= '' and settings.ws_alt or 'none') .. ')',
            'ws boss <name> [tp]|off   WS on boss floors (' .. (settings.ws_boss ~= '' and settings.ws_boss or 'normal WS') .. ')',
            'ws heals [add|remove <mob>|clear]   mobs that get the backup WS (learned when one heals)',
            'range <yalms>          how close a mob must be before auto attacks it (' .. settings.engage_range .. ')',
            'check [on|off]         auto /check for "impossible to gauge" targets (' .. onoff(settings.autocheck) .. ')',
            'face [on|off]          turn to face your target (' .. onoff(settings.autoface) .. ')',
            'defend [on|off]        fight back against anything attacking you (' .. onoff(settings.defend) .. ')',
            'objects [on|off]       target the next lamp / the rune when you walk up to it (' .. onoff(settings.autoobject) .. ')',
         }},
        {name = 'Corsair', aliases = {'corsair', 'cor', 'rolls', 'roll'},
         desc = 'rolls and Double-Up',
         lines = {
            'cor [on|off]           keep rolls up + Double-Up (' .. onoff(settings.cor) .. ')',
            'rolls idle <rolls>     out-of-combat rolls, e.g. rolls idle bolter (' .. roll_names(settings.cor_idle_rolls) .. ')',
            'rolls combat <rolls>   in-combat rolls, up to 2, e.g. rolls combat chaos tactician (' .. roll_names(settings.cor_combat_rolls) .. ')',
            'rolls range <yalms>    no idle rolls with an enemy this close; ignored once the floor is done (' .. settings.cor_idle_enemy_range .. ')',
            'rolls tp <n>           no rolls / Double-Up at n TP or more (except Bolter\'s once the floor is done); 0 = off (' .. settings.cor_tp_hold .. ')',
            'doubleup <n>           Double-Up while the total is n or less, 0 = never (' .. settings.cor_double_max .. ')',
         }},
        {name = 'Dancer', aliases = {'dancer', 'dnc', 'waltz', 'jig'},
         desc = 'Curing Waltz and Spectral Jig',
         lines = {
            'waltz [on|off]         Curing Waltz III / II (' .. onoff(settings.waltz) .. ')',
            'waltz <III%> <II%>     HP thresholds, e.g. waltz 50 70 (' .. settings.waltz3_hpp .. ' / ' .. settings.waltz2_hpp .. ')',
            'jig [on|off]           Spectral Jig when not fighting (' .. onoff(settings.jig) .. ')',
            'jig <seconds>          hold the jig if a roll is due this soon (' .. settings.jig_roll_window .. ')',
            'jig lamps [on|off]     jig on lamp floors, away from the next lamp (' .. onoff(settings.jig_lamp_floors) .. ')',
            'jig all [on|off]       also jig on "kill all enemies" floors (' .. onoff(settings.jig_all) .. ')',
            'jig range <yalms>      no jig with an enemy this close (' .. settings.jig_enemy_range .. ')',
            'uninvis [on|off]       click Invisible off as you near the lamp / rune you need (' .. onoff(settings.uninvis) .. ')',
            'uninvis <yalms>        ...from this far away (' .. settings.uninvis_range .. ')',
         }},
        {name = 'Lamps', aliases = {'lamps', 'lamp'},
         desc = 'lamp puzzle helpers',
         lines = {
            'lit <letters> | lit none   after an order round: which lamps stayed ON, e.g. lit AC',
            'order <letters>        record a round it missed, e.g. order CABD (then use lit)',
            'lamps <n> | lamps reset    set the lamp count, or clear this floor\'s lamp history',
         }},
        {name = 'Panel', aliases = {'panel', 'hud', 'ui', 'display', 'show', 'hide'},
         desc = 'what the info box shows and how it looks',
         lines = {
            'show | hide            the whole panel and radar',
            'show|hide rolls|waltz|jobs   the Rolls / Waltz lines (jobs = both)',
            'style classic|compact  two-column panel or the old single box (' .. settings.panel.style .. ')',
            'font <name> <size>     e.g. font Arial 12  |  font bold on|off',
            'spacing <line> [section]   extra pixels between lines / sections (' .. settings.panel.line_spacing .. ' / ' .. settings.panel.group_spacing .. ')',
            'dir compass|clock|both     how directions are written (' .. settings.directions .. ')',
         }},
        {name = 'Radar', aliases = {'radar', 'arrow', 'arrows'},
         desc = 'the arrow box',
         lines = {
            'radar [on|off]         the arrow box (drag it by its title)',
            'radar up camera|north|facing   which way is up on the radar (' .. settings.radar.up .. ')',
            'radar size <px>        size of the box (' .. settings.radar.size .. ')',
            'radar recal            re-learn the camera direction (run around afterwards)',
            'radar cam              print camera readings',
         }},
        {name = 'Buffs', aliases = {'buffs', 'buff', 'heals', 'heal', 'jobs', 'job'},
         desc = 'any job: abilities and spells to keep up, and to heal with',
         lines = {
            'buff add <name> [fight|idle|always]   keep it up (or use it whenever it\'s ready, e.g. Jump), e.g. buff add Berserk',
            'heal add <name> <HP%>  use it at or below this HP, e.g. heal add Cure IV 40',
            'buff | heal            list them  |  buff remove <name>  |  heal remove <name>  |  buff clear  |  heal clear',
            'buff on|off            all of them on or off (' .. onoff(settings.rules_on) .. ')',
         }},
        {name = 'Other', aliases = {'other', 'misc', 'tools'},
         desc = 'setup, stats, timer, tokens, bug reports, updates',
         lines = {
            'setup                  the setup window: click a line to switch it on or off',
            'stats [reset]          this session: runs, floors, tokens per hour',
            'tokens [reset]         your token total, this session and since counting began',
            'time <minutes>         correct the timer',
            'armband on|off         set the Assault armband +10% token bonus by hand',
            'reset                  clear this run\'s floor/token counts',
            'debug                  write data/debug.log (starts a new file each time)',
            'report                 save data/report.txt to send with a bug report',
            'update [on|off]        look for a newer version now (on/off: the weekly check)',
            'version                version, what\'s new, where to get updates',
            'dump                   save nearby mobs/lamps/runes to data/dump_*.txt',
            'help [group|all]       this help',
         }},
    }
end

local function help(topic)
    local groups = help_groups()
    local function show(g)
        windower.add_to_chat(160, ('-- %s: %s --'):format(g.name, g.desc))
        for _, line in ipairs(g.lines) do windower.add_to_chat(207, '  //nz ' .. line) end
    end
    topic = topic and topic:lower()
    if topic == 'all' then
        windower.add_to_chat(207, '[Nyzul] NyzulAssist ' .. _addon.version .. ' - all commands')
        for _, g in ipairs(groups) do show(g) end
        return
    end
    if topic then
        for _, g in ipairs(groups) do
            for _, a in ipairs(g.aliases) do
                if a == topic then show(g); return end
            end
        end
        windower.add_to_chat(167, '[Nyzul] No help group called "' .. topic .. '".')
    end
    windower.add_to_chat(207, '[Nyzul] NyzulAssist ' .. _addon.version .. ' - type //nz help <group>:')
    for _, g in ipairs(groups) do
        windower.add_to_chat(207, ('  %-8s %s'):format(g.name, g.desc))
    end
    windower.add_to_chat(207, '  e.g. //nz help lamps   |   //nz help all for everything')
end

local function on_command(cmd, ...)
    cmd = cmd and cmd:lower() or 'help'
    local args = {...}
    local a1 = args[1] and args[1]:lower()

    if cmd == 'auto' then
        S.auto = on_off(a1, S.auto)
        say('Semi-auto ' .. (S.auto and green('ON') or 'off') .. (S.auto and ' - you steer, it fights.' or ''))
        if not S.auto then FAX.FA.stop('semi-auto switched off') end

    elseif FAX.X[cmd] then
        FAX.X[cmd](args)

    elseif FAX.cmds[cmd] then
        FAX.FA.command(cmd, args)

    elseif cmd == 'ws' and (a1 == 'backup' or a1 == 'alt' or a1 == 'boss') then
        local which = a1 == 'boss' and 'boss' or 'alt'
        local rest = {}
        for i = 2, #args do rest[#rest + 1] = args[i] end
        local w = rest[1] and rest[1]:lower()
        if not w or w == 'off' or w == 'none' then
            settings['ws_' .. which] = ''
        else
            local tp = which == 'boss' and tonumber(rest[#rest]) or nil
            local last = tp and #rest - 1 or #rest
            settings['ws_' .. which] = table.concat(rest, ' ', 1, last):gsub('"', '')
            if tp then settings.ws_boss_tp = tp end
        end
        config.save(settings)
        if which == 'boss' then
            say(settings.ws_boss ~= '' and ('Boss floors: %s at %d TP'):format(settings.ws_boss, settings.ws_boss_tp)
                or 'Boss floors use your normal weaponskill.')
        else
            say(settings.ws_alt ~= '' and ('Backup weaponskill: %s (mobs your WS heals: %s)'):format(settings.ws_alt, settings.ws_alt_mobs)
                or 'No backup weaponskill: no WS on mobs your WS heals.')
        end

    elseif cmd == 'ws' and (a1 == 'heals' or a1 == 'absorb') then
        local a2 = args[2] and args[2]:lower()
        local name = table.concat(args, ' ', 3)
        if a2 == 'clear' then
            settings.ws_alt_mobs = ''
        elseif a2 == 'add' and name ~= '' then
            settings.ws_alt_mobs = settings.ws_alt_mobs == '' and name or (settings.ws_alt_mobs .. ',' .. name)
        elseif a2 == 'remove' and name ~= '' then
            local keep = {}
            for part in settings.ws_alt_mobs:gmatch('[^,]+') do
                if part:lower() ~= name:lower() then keep[#keep + 1] = part end
            end
            settings.ws_alt_mobs = table.concat(keep, ',')
        end
        config.save(settings)
        say('Mobs that get the backup WS: ' .. (settings.ws_alt_mobs ~= '' and settings.ws_alt_mobs or 'none'))

    elseif cmd == 'ws' then
        if not a1 or a1 == 'off' or a1 == 'none' then
            settings.ws_name = ''
            say('Auto weaponskill off.')
        else
            local tp = tonumber(args[#args])
            local last = tp and #args - 1 or #args
            local name = table.concat(args, ' ', 1, last):gsub('"', '')
            settings.ws_name = name
            if tp then settings.ws_tp = tp end
            say(('Auto weaponskill: %s at %d TP'):format(settings.ws_name, settings.ws_tp))
        end
        config.save(settings)

    elseif cmd == 'range' then
        local n = tonumber(args[1])
        if n then settings.engage_range = n; config.save(settings) end
        say('Engage range: ' .. settings.engage_range .. ' yalms')

    elseif cmd == 'check' then
        settings.autocheck = on_off(a1, settings.autocheck); config.save(settings)
        say('Auto-check: ' .. tostring(settings.autocheck))

    elseif cmd == 'face' then
        settings.autoface = on_off(a1, settings.autoface); config.save(settings)
        say('Auto-face: ' .. tostring(settings.autoface))

    elseif cmd == 'defend' then
        settings.defend = on_off(a1, settings.defend); config.save(settings)
        say('Fight back: ' .. tostring(settings.defend))

    elseif cmd == 'objects' then
        settings.autoobject = on_off(a1, settings.autoobject); config.save(settings)
        say('Lamp/rune pre-targeting: ' .. tostring(settings.autoobject))

    elseif cmd == 'cor' then
        settings.cor = on_off(a1, settings.cor); config.save(settings)
        say(('Corsair rolls: %s  (idle: %s | combat: %s)'):format(settings.cor and 'on' or 'off',
            roll_names(settings.cor_idle_rolls), roll_names(settings.cor_combat_rolls)))

    elseif cmd == 'rolls' and a1 == 'tp' then
        local n = tonumber(args[2])
        if n then settings.cor_tp_hold = math.max(0, math.min(3000, n)); config.save(settings) end
        if settings.cor_tp_hold > 0 then
            say(('No rolls or Double-Up at %d TP or more - they wait until you\'ve used it.'):format(settings.cor_tp_hold))
        else
            say('Rolls ignore your TP (TP hold off).')
        end

    elseif cmd == 'rolls' and a1 == 'range' then
        local n = tonumber(args[2])
        if n then settings.cor_idle_enemy_range = math.max(0, math.min(50, n)); config.save(settings) end
        say(('Idle rolls wait until no enemy is within %d yalms (not once the floor is done).'):format(settings.cor_idle_enemy_range))

    elseif cmd == 'rolls' then
        local which = a1
        if which == 'idle' or which == 'combat' then
            local keys, bad = {}, {}
            for i = 2, #args do
                local w = args[i]:lower()
                if w ~= 'none' and w ~= 'roll' then
                    local r = resolve_roll(w)
                    if r then keys[#keys + 1] = r.key else bad[#bad + 1] = args[i] end
                end
            end
            if #bad > 0 then
                say(red('Unknown roll: ' .. table.concat(bad, ', ')) .. '  (supported: bolter, tactician, chaos, samurai)')
                return
            end
            if #keys > 2 then say(orange('Only 2 rolls can be up at once - keeping the first two.')) end
            local value = table.concat(keys, ',', 1, math.min(2, #keys))
            if which == 'idle' then settings.cor_idle_rolls = value else settings.cor_combat_rolls = value end
            config.save(settings)
        end
        say(('Rolls - idle: %s | combat: %s'):format(roll_names(settings.cor_idle_rolls), roll_names(settings.cor_combat_rolls)))

    elseif cmd == 'doubleup' then
        local n = tonumber(args[1])
        if n then settings.cor_double_max = math.max(0, math.min(10, n)); config.save(settings) end
        say(('Double-Up while total is %d or less%s'):format(settings.cor_double_max,
            settings.cor_double_max > 5 and orange(' (can bust!)') or ''))

    elseif cmd == 'waltz' then
        local n3, n2 = tonumber(args[1]), tonumber(args[2])
        if n3 then
            settings.waltz3_hpp = n3
            if n2 then settings.waltz2_hpp = n2 end
        else
            settings.waltz = on_off(a1, settings.waltz)
        end
        config.save(settings)
        say(('Waltz: %s  (III at %d%% HP, II at %d%% HP)'):format(settings.waltz and 'on' or 'off', settings.waltz3_hpp, settings.waltz2_hpp))

    elseif cmd == 'jig' and a1 == 'range' then
        local n = tonumber(args[2])
        if n then settings.jig_enemy_range = math.max(0, math.min(30, n)); config.save(settings) end
        say(('No Spectral Jig with an enemy within %d yalms.'):format(settings.jig_enemy_range))

    elseif cmd == 'jig' and a1 == 'all' then
        settings.jig_all = on_off(args[2] and args[2]:lower(), settings.jig_all)
        config.save(settings)
        say('Spectral Jig on "kill all enemies" floors: ' .. (settings.jig_all and 'on' or 'off'))

    elseif cmd == 'jig' and a1 == 'lamps' then
        settings.jig_lamp_floors = on_off(args[2] and args[2]:lower(), settings.jig_lamp_floors)
        config.save(settings)
        say('Spectral Jig on lamp floors: ' .. (settings.jig_lamp_floors and 'on' or 'off')
            .. '  (not within ' .. settings.jig_lamp_range .. 'y of the next lamp; Invisible is dropped when you get there)')

    elseif cmd == 'uninvis' then
        local n = tonumber(a1)
        if n then settings.uninvis_range = math.max(5, math.min(50, n)) else settings.uninvis = on_off(a1, settings.uninvis) end
        config.save(settings)
        say(('Drop Invisible %d yalms from the lamp / rune you need: %s'):format(settings.uninvis_range, settings.uninvis and 'on' or 'off'))

    elseif cmd == 'jig' then
        local n = tonumber(args[1])
        if n then settings.jig_roll_window = n else settings.jig = on_off(a1, settings.jig) end
        config.save(settings)
        say(('Spectral Jig: %s  (held if a roll is due within %ds)'):format(settings.jig and 'on' or 'off', settings.jig_roll_window))

    elseif cmd == 'dir' or cmd == 'directions' then
        if a1 == 'compass' or a1 == 'clock' or a1 == 'both' then
            settings.directions = a1
            config.save(settings)
        end
        say('Directions: ' .. settings.directions .. '  (compass = N/NE/E..., clock = 12 is where you face)')

    elseif cmd == 'armband' then
        S.has_armband = on_off(a1, S.has_armband)
        say('Assault armband bonus: ' .. (S.has_armband and 'on (+10% tokens)' or 'off'))

    elseif cmd == 'lit' then
        if S.pending_eval then
            S.rounds[#S.rounds + 1] = {order = S.pending_eval.order}
            S.pending_eval = nil
        end
        local r = S.rounds[#S.rounds]
        if not r then say('No finished round yet.'); return end
        local on = {}
        if a1 and a1 ~= 'none' then
            for ch in table.concat(args, ''):gmatch('%a') do
                local s = slot_from_letter(ch)
                if s then on[s] = true end
            end
        end
        r.lit = {}
        for _, s in ipairs(r.order) do r.lit[s] = on[s] or false end
        S.plan = nil
        say(('Round %d: %s'):format(#S.rounds, describe_round(r)))
        local plan, n = current_plan()
        if plan then
            local letters = {}
            for i, s in ipairs(plan) do letters[i] = letter(s) end
            say(('Next try: %s  (%d possible)'):format(table.concat(letters, ' > '), n))
        else
            say(red('That conflicts with earlier rounds. //nz lamps reset to start over.'))
        end

    elseif cmd == 'order' then
        local order = {}
        for ch in table.concat(args, ''):gmatch('%a') do
            local s = slot_from_letter(ch)
            if s then order[#order + 1] = s end
        end
        if #order == 0 then say('Usage: //nz order CABD'); return end
        S.lamp_type = S.lamp_type or 'order'
        S.round = {}
        S.rounds[#S.rounds + 1] = {order = order}
        say('Recorded round ' .. #S.rounds .. '. Now: //nz lit <letters that stayed ON>')

    elseif cmd == 'lamps' then
        if a1 == 'reset' then
            S.rounds, S.round, S.touched, S.plan, S.pending_eval = {}, {}, {}, nil, nil
            S.game_round, S.lamp_min = {}, nil
            say('Lamp history cleared.')
        elseif tonumber(a1) then
            S.lamp_override = math.max(1, math.min(5, tonumber(a1)))
            say('Lamp count set to ' .. S.lamp_override)
        else
            say(('Lamps: %d, type %s, %d round(s)'):format(lamp_count(), tostring(S.lamp_type), #S.rounds))
        end

    elseif cmd == 'time' then
        local n = tonumber(args[1])
        if n then set_timer(n * 60); say('Timer set to ' .. n .. ' min') end

    elseif cmd == 'reset' then
        local was = S.in_nyzul
        reset_run()
        S.in_nyzul = was
        say('Run data reset.')

    elseif cmd == 'show' or cmd == 'hide' then
        local on = cmd == 'show'
        if a1 == 'rolls' or a1 == 'waltz' or a1 == 'jobs' then
            if a1 ~= 'waltz' then settings.panel.show_rolls = on end
            if a1 ~= 'rolls' then settings.panel.show_waltz = on end
            config.save(settings)
            panel_update()
            say(('Panel lines - Rolls: %s, Waltz: %s'):format(settings.panel.show_rolls and 'shown' or 'hidden',
                settings.panel.show_waltz and 'shown' or 'hidden'))
        elseif a1 == 'radar' then
            settings.radar.show = on
            config.save(settings)
            if not on then radar_hide() end
            say('Radar ' .. (on and 'shown' or 'hidden'))
        elseif a1 and a1 ~= 'all' and a1 ~= 'panel' then
            say('Use //nz ' .. cmd .. ' [rolls | waltz | jobs | radar] - or nothing for everything')
        else
            S.panel_hidden = not on
            if on then panel_update() else panel_hide(); radar_hide() end
        end

    elseif cmd == 'style' then
        if a1 == 'classic' or a1 == 'compact' then
            settings.panel.style = a1
            box:pos(settings.pos.x, settings.pos.y)
            config.save(settings)
            panel_update()
        end
        say('Panel style: ' .. settings.panel.style .. '  (classic | compact)')

    elseif cmd == 'font' then
        -- //nz font Arial 12   |   //nz font 13   |   //nz font bold on|off
        if a1 == 'bold' then
            settings.panel.bold = on_off(args[2] and args[2]:lower(), settings.panel.bold)
        else
            local size = tonumber(args[#args])
            local last = size and #args - 1 or #args
            if last >= 1 then settings.panel.font = table.concat(args, ' ', 1, last) end
            if size then settings.panel.size = math.max(7, math.min(30, size)) end
        end
        config.save(settings)
        panel_destroy_texts()
        panel_update()
        say(('Panel font: %s %d%s'):format(settings.panel.font, settings.panel.size, settings.panel.bold and ' bold' or ''))

    elseif cmd == 'spacing' then
        local n = tonumber(args[1])
        if n then settings.panel.line_spacing = math.max(0, math.min(30, n)) end
        local g = tonumber(args[2])
        if g then settings.panel.group_spacing = math.max(0, math.min(40, g)) end
        config.save(settings)
        panel_update()
        say(('Line spacing: %dpx, section spacing: %dpx'):format(settings.panel.line_spacing, settings.panel.group_spacing))

    elseif cmd == 'radar' then
        if a1 == 'up' then
            local mode = args[2] and args[2]:lower()
            if mode == 'camera' or mode == 'north' or mode == 'facing' then
                settings.radar.up = mode
                config.save(settings)
            end
            say('Radar "up" is: ' .. settings.radar.up .. '  (camera | north | facing)')
            if settings.radar.up == 'camera' and type(windower.ffxi.get_camera) ~= 'function' then
                say('(your Windower has no camera function, so camera mode works like facing)')
            end
        elseif a1 == 'size' and tonumber(args[2]) then
            settings.radar.size = math.max(80, math.min(300, tonumber(args[2])))
            config.save(settings)
            radar_rebuild()
            say('Radar size: ' .. settings.radar.size)
        elseif a1 == 'recal' or a1 == 'axis' then
            settings.radar.cam_calib = ''
            Cal.stats, Cal.last = {}, nil
            config.save(settings)
            say('Radar camera reset - run around for a few seconds (holding forward) to teach it again.')
        elseif a1 == 'cam' then
            local m, cam = me(), get_cam()
            if type(windower.ffxi.get_camera) ~= 'function' then
                say('Your Windower has no camera function, so "up" on the radar is the way your character faces.')
                say('That matches the camera while you run. //nz radar up north keeps north at the top instead.')
                return
            end
            if not cam then
                local ok, raw = pcall(function() return windower.ffxi.get_camera() end)
                local desc
                if type(windower.ffxi.get_camera) ~= 'function' then
                    desc = 'windower.ffxi.get_camera does not exist in your Windower'
                elseif not ok then
                    desc = 'error: ' .. tostring(raw)
                elseif type(raw) == 'table' then
                    local parts = {}
                    for k, v in pairs(raw) do parts[#parts + 1] = tostring(k) .. '=' .. tostring(v) end
                    desc = 'table {' .. table.concat(parts, ', ') .. '}'
                else
                    desc = type(raw) .. ' ' .. tostring(raw)
                end
                say('get_camera() gave nothing usable (' .. desc .. ') - the radar uses your facing.')
                debug_log('get_camera: ' .. desc)
            end
            if m and cam then
                say(('camera x=%.2f y=%.2f z=%.2f | you x=%.1f y=%.1f z=%.1f facing %.2f'):format(
                    cam.camera_x, cam.camera_y, cam.camera_z, m.x, m.y, m.z or 0, m.facing or 0))
            end
            if settings.radar.cam_calib ~= '' then
                say('camera learned as: ' .. settings.radar.cam_calib .. '   (//nz radar recal to redo)')
            else
                local list = {}
                for key, st in pairs(Cal.stats) do list[#list + 1] = {key = key, mean = st.sum / st.n, n = st.n} end
                table.sort(list, function(a, b) return a.mean > b.mean end)
                local parts = {}
                for i = 1, math.min(3, #list) do parts[i] = ('%s %.2f/%d'):format(list[i].key, list[i].mean, list[i].n) end
                say('still learning (best match/steps): ' .. (#parts > 0 and table.concat(parts, ', ') or 'no running seen yet'))
            end
            if m then
                local b, used = view_bearing(m)
                say(('radar up = %s (%s)'):format(COMPASS[math.floor(b / (math.pi / 4) + 0.5) % 8 + 1], used))
            end
        else
            settings.radar.show = on_off(a1, settings.radar.show)
            config.save(settings)
            if not settings.radar.show then radar_hide() end
            say('Radar: ' .. (settings.radar.show and 'on' or 'off'))
        end

    elseif cmd == 'debug' then
        S.debug = not S.debug
        if S.debug then
            local f = io.open(windower.addon_path .. 'data/debug.log', 'w')     -- start a fresh log
            if f then
                f:write(('NyzulAssist %s debug log, %s\n'):format(_addon.version, os.date('%Y-%m-%d %H:%M')))
                f:close()
            end
        end
        say('Debug ' .. (S.debug and 'ON - writing data/debug.log (nothing extra in chat)' or 'off'))

    elseif cmd == 'dump' then
        local path = windower.addon_path .. 'data/dump_' .. os.date('%Y%m%d_%H%M%S') .. '.txt'
        local f = io.open(path, 'w')
        if not f then say('Could not write ' .. path); return end
        f:write(('floor=%d obj=%s type=%s lamp_type=%s clear=%s\n'):format(
            S.floor, S.objective, tostring(S.obj_type), tostring(S.lamp_type), tostring(S.floor_clear)))
        for _, mob in pairs(windower.ffxi.get_mob_array()) do
            if mob.spawn_type == SPAWN_MONSTER or (mob.index >= IDX_RUNE_FIRST and mob.index <= IDX_LAMP_LAST) then
                f:write(('%5d %-26s id=%d hpp=%d st=%d spawn=%d claim=%d valid=%s x=%.1f y=%.1f check=%s\n'):format(
                    mob.index, mob.name, mob.id, mob.hpp or 0, mob.status or -1, mob.spawn_type or -1,
                    mob.claim_id or 0, tostring(mob.valid_target), mob.x, mob.y, tostring(S.checks[mob.id])))
            end
        end
        f:close()
        say('Wrote ' .. path)

    else
        if cmd ~= 'help' then say('Unknown command: ' .. cmd) end
        help(cmd == 'help' and args[1] or nil)
    end
end
FAX.command = function(...)
    on_command(...)
    if FAX.Setup.visible then FAX.Setup.draw() end          -- (the setup window shows what changed)
end
windower.register_event('addon command', FAX.command)
