
local GITHUB_UID_URL = "https://raw.githubusercontent.com/indeacps/auto-host/refs/heads/main/allowed_uids.txt"
local UID_RECHECK_SECONDS = 2

-- The list is downloaded from GitHub and refreshed every 5 seconds.
local GITHUB_ALLOWED_UIDS = {}
local GITHUB_UID_LIST_READY = false
local _accessWarningShown = false
local _lastAccessState = nil

-- API compatibility for the proxy API used by this script.
if type(GetObjects) ~= "function" and type(GetObjectList) == "function" then
    GetObjects = GetObjectList
end
if type(GetPlayerList) ~= "function" and type(GetPlayers) == "function" then
    GetPlayerList = GetPlayers
end

local function FetchGitHubUIDs()
    if type(MakeRequest) ~= "function" then
        GITHUB_UID_LIST_READY = false
        return false, "MakeRequest is unavailable"
    end

    local ok, response = pcall(function()
        return MakeRequest(GITHUB_UID_URL, "GET")
    end)
    if not ok or type(response) ~= "table" or type(response.content) ~= "string" then
        GITHUB_UID_LIST_READY = false
        return false, "GitHub UID request failed"
    end

    local downloaded = {}
    for line in response.content:gmatch("[^\r\n]+") do
        -- Accept one UID per line; ignore blank lines and # comments.
        line = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
        local uid = tonumber(line)
        if uid and uid > 0 then
            downloaded[uid] = true
        end
    end

    -- Do not accept an empty or malformed list as a valid authorization list.
    if next(downloaded) == nil then
        GITHUB_UID_LIST_READY = false
        return false, "GitHub UID list is empty or invalid"
    end

    GITHUB_ALLOWED_UIDS = downloaded
    GITHUB_UID_LIST_READY = true
    return true
end

local function CheckAccess()
    local p = type(GetLocal) == "function" and GetLocal() or nil
    if not p then return nil end
    local uid = tonumber(p.userid or p.userID or p.user_id or p.uid or 0)
    if not uid or uid == 0 then return nil end
    return GITHUB_UID_LIST_READY and GITHUB_ALLOWED_UIDS[uid] == true
end

local function ReportAccessDeniedOnce()
    if _accessWarningShown then return end
    _accessWarningShown = true
    local p = type(GetLocal) == "function" and GetLocal() or nil
    local uid = p and (p.userid or p.userID or p.user_id or p.uid) or "unavailable"
    if type(LogToConsole) == "function" then
        LogToConsole("`0[`4ACCESS DENIED`0] `cCurrent user ID: `w" .. tostring(uid) .. "`c is not in the GitHub allowed UID list, or the list could not be downloaded. Auto-host actions are blocked.")
    end
end

local function Guard()
    local ok = CheckAccess()
    if ok == false then ReportAccessDeniedOnce() end
    return ok == true
end

-- Refresh authorization immediately, then every 5 seconds. A failed fetch fails closed.
RunThread(function()
    while true do
        local ok, err = FetchGitHubUIDs()
        local access = CheckAccess()
        if access ~= _lastAccessState then
            _lastAccessState = access
            _accessWarningShown = false
            if access == true then
                if type(LogToConsole) == "function" then
                    LogToConsole("`0[`2ACCESS OK`0] `cGitHub UID authorization accepted.")
                end
            elseif access == false then
                ReportAccessDeniedOnce()
            end
        end
        if not ok and type(LogToConsole) == "function" then
            LogToConsole("`0[`4UID CHECK`0] `c" .. tostring(err) .. "; access remains blocked until a valid list is downloaded.")
        end
        if type(Sleep) ~= "function" then break end
        Sleep(UID_RECHECK_SECONDS * 1000)
    end
end)

local Positions, Config, HostLogs, SaveInfo, Session, LogsDirty

local CONFIG_FILE = "host_config.txt"
local DISCORD_LINK = "https://discord.gg/AXnVts96k3"

local function logMsg(str)
    local tag = (Config and Config.Opt and Config.Opt.tag) or "Host"
    if LogToConsole then LogToConsole("`w[ `2" .. tag .. " `w] `0" .. str) end
end

Positions = Positions or {
    hostWheel1 = { x = 0, y = 0 },
    hostWheel2 = { x = 0, y = 0 },
    displayBox = { x = 0, y = 0 },
    dropSpot = { x = 0, y = 0 },
    lamp1 = { x = 0, y = 0 },
    lamp2 = { x = 0, y = 0 },
    doorGate = { x = 0, y = 0 }
}

Config = Config or {
    WorldLockItemID = 242,
    DiamondLockItemID = 1796,
    BlueGemLockItemID = 7188,
    BlackGemLockItemID = 11550,
    WinMessage = "`2You won %d WL!",
    LoseMessage = "`4You lost!",
    DropBetMessage = "`w%s: `2Drop your bet!",
    SpamMessage = "Waiting for player..",
    AutoSpam = false,
    SpamDelay = 10,
    SpamRainbow = false,
    SpamRandomColor = false,
    SpamIdleOnly = true,
    EnableReme = true,
    EnableQeme = true,
    EnableLeme = true,
    Enable2R = true,
    TriggerReme = "!reme",
    TriggerQeme = "!qeme",
    TriggerLeme = "!leme",
    Trigger2R = "!2r",
    Trigger1R = "!1r",
    TriggerExit = "!exit",
    MinBet = 1,
    MaxBet = 0
}

Positions.playerWheel1 = Positions.playerWheel1 or { x = 0, y = 0 }
Positions.playerWheel2 = Positions.playerWheel2 or { x = 0, y = 0 }
Positions.displayBox2 = Positions.displayBox2 or { x = 0, y = 0 }
Positions.standSpot = Positions.standSpot or { x = 0, y = 0 }
Positions.pullSpot = Positions.pullSpot or { x = 0, y = 0 }

HostLogs = HostLogs or {
    totalProfitLoss = 0,
    totalGames = 0,
    totalWins = 0,
    totalLosses = 0,
    totalTimeouts = 0,
    totalBugs = 0,
    entries = {}
}

local LOG_COLORS = { WIN = "`2", LOSS = "`4", TIMEOUT = "`e", SPIN = "`3", BUG = "`4", RESET = "`6", EXIT = "`9", BET = "`1", BANK = "`b", BUY = "`5" }

local function AddHostLog(typeStr, detailStr)
    local timeStamp = os.date("%H:%M:%S")
    local color = LOG_COLORS[typeStr] or "`w"
    local entry = { type = typeStr, text = string.format("`7%s %s%s `w%s", timeStamp, color, typeStr, detailStr) }
    table.insert(HostLogs.entries, 1, entry)
    if #HostLogs.entries > 100 then
        table.remove(HostLogs.entries)
    end
    LogsDirty = true
end

local colorList = { "`1", "`2", "`3", "`4", "`5", "`6", "`7", "`8", "`9", "`0", "`q", "`w", "`e", "`r", "`a", "`s", "`c", "`&", "`@" }

local CONV_DEFAULTS = {
    auto = true, afterBet = true, idle = false,
    up1 = true, up2 = true, up3 = true,
    n1 = 3, n2 = 3, n3 = 3,
    keep1 = 0, keep2 = 0, keep3 = 0,
    delay = 300,
    shatter = true, sh2 = true, sh3 = true, sh4 = true,
    phone = "53785", hidePhone = true
}
local CONV_KEYS = { "auto","afterBet","idle","up1","up2","up3","n1","n2","n3","keep1","keep2","keep3","delay","shatter","sh2","sh3","sh4","phone","hidePhone" }

local function ConvFill()
    Config.Conv = Config.Conv or {}
    for k, v in pairs(CONV_DEFAULTS) do
        if Config.Conv[k] == nil then Config.Conv[k] = v end
    end
end
ConvFill()

local function SerializeConv()
    local out = ""
    for _, k in ipairs(CONV_KEYS) do
        local v = Config.Conv[k]
        if v == nil then v = CONV_DEFAULTS[k] end
        out = out .. string.format("Config.Conv.%s = %s\n", k, (type(v) == "string") and string.format("%q", v) or tostring(v))
    end
    return out
end

local LEGACY = {}
LEGACY.OLD_MSG = {
    spin1 = "`2Spin the wheel!",
    spin2 = "`2Spin the second wheel!",
    warn10 = "`410 seconds left!",
    timeout = "`4Time's up! Kicked.",
    exitok = "`4Player left the game.",
    noexit = "`4Can't leave mid-game!",
    to1r = "`3Switched to 1R.",
    def1r = "`3Already in 1R.",
    switched = "Mode changed to %s",
    need2r = "`4Start a game first, then switch to 2R!",
    off2r = "`42R is turned off.",
    modeoff = "`4%s is turned off.",
    left = "`4Player left. Spot is open.",
    leftactive = "`4Player left mid-game. Back in `6%d`4 sec or you lose.",
    failreturn = "`4Player didn't come back. Host wins.",
    rejoin = "`2Welcome back! Pulling you in.",
    fake = "`4Fake spin! Player banned.",
    stopped = "`4Game stopped.",
    refund = "`4Bet refunded.",
    minbet = "`4Bet too low (min `6%d WL`4). Refunded.",
    maxbet = "`4Bet too high (max `6%d WL`4). Refunded.",
    lowbal = "`4Host balance too low. Bet refunded.",
    spinout = "`4Spun outside the wheel area. You lose!",
    spinearly = "`4Spun before the lamp turned on. You lose!",
    spindouble = "`4Double spin. You lose!",
    spintriple = "`4Triple spin. You lose!",
}
LEGACY.MID_MSG = {
    spin1 = "`2Good luck! Spin the wheel!", spin2 = "`2Now spin the second wheel!", warn10 = "`410 seconds left, hurry up!",
    timeout = "`4Time's up! You've been kicked.",
    exitok = "`4Thanks for playing! See you next time.", noexit = "`4You can't leave in the middle of a game!",
    to1r = "`3Switched to 1R mode.", def1r = "`3You're already in 1R mode.", switched = "`3Game mode changed to %s.",
    need2r = "`4Start a game first, then switch to 2R!", off2r = "`42R mode is turned off.",
    modeoff = "`4%s mode is turned off.",
    left = "`4Player left. Who's next?", leftactive = "`4Player left mid-game! Come back in `6%d`4 sec or lose your bet.",
    failreturn = "`4Player didn't come back. The host wins.", rejoin = "`2Welcome back! Pulling you in.",
    fake = "`4Fake spin detected! Player banned.", stopped = "`4Game stopped by the host.",
    refund = "`4Bet refunded.", minbet = "`4Bet too low! Minimum is `6%d WL`4. Refunded.",
    maxbet = "`4Bet too high! Maximum is `6%d WL`4. Refunded.", lowbal = "`4Host balance is too low for this bet. Refunded.",
    spinout = "`4You spun outside the wheel area. You lose!", spinearly = "`4You spun before the lamp was on. You lose!",
    spindouble = "`4Double spin! You lose.", spintriple = "`4Triple spin! You lose."
}
local MSG_DEFAULTS = {
    spin1 = "`2Spin the wheel!", spin2 = "`2Spin the second wheel!", warn10 = "`410 seconds left!",
    timeout = "`4Time's up! Kicked.",
    exitok = "`4Bye!", noexit = "`4You can't leave now!",
    to1r = "`3Switched to 1R.", def1r = "`3Already 1R.", switched = "`3Mode: %s",
    need2r = "`4Start a game first!", off2r = "`42R is off.",
    modeoff = "`4%s is off.",
    left = "`4Player left.", leftactive = "`4Player left! `6%d`4 sec to come back.",
    failreturn = "`4Player didn't return. Host wins.", rejoin = "`2Welcome back!",
    fake = "`4Fake spin! Banned.", stopped = "`4Game stopped.",
    refund = "`4Bet refunded.", minbet = "`4Min bet is `6%d WL`4. Refunded.",
    maxbet = "`4Max bet is `6%d WL`4. Refunded.", lowbal = "`4Low balance. Refunded.",
    spinout = "`4Spun outside! You lose.", spinearly = "`4Spun too early! You lose.",
    spindouble = "`4Double spin! You lose.", spintriple = "`4Triple spin! You lose."
}
LEGACY.MID_WIN, LEGACY.MID_LOSE, LEGACY.MID_DROP = "`2Congrats! You won `6%d WL`2!", "`4You lost! `wBetter luck next time!", "`9%s `w- `2Place your bet!"
LEGACY.OLD_WIN, LEGACY.OLD_LOSE, LEGACY.OLD_DROP = "You won! `1%d WL", "You lost!", "%s: Drop bet."

local MSG_ORDER = {
    { "spin1", "Spin wheel" }, { "spin2", "Spin 2nd wheel" }, { "warn10", "10 sec warning" },
    { "timeout", "Timeout kick" }, { "exitok", "!exit" }, { "noexit", "!exit blocked" },
    { "to1r", "Switch to 1R" }, { "def1r", "Already 1R" }, { "switched", "Mode changed (%s)" },
    { "need2r", "2R before game" }, { "off2r", "2R off" }, { "modeoff", "Mode off (%s)" },
    { "left", "Player left" }, { "leftactive", "Left mid-game (%d sec)" }, { "failreturn", "Did not return" },
    { "rejoin", "Player back" }, { "fake", "Fake spin" }, { "stopped", "Game stopped" },
    { "refund", "Refund" }, { "minbet", "Below min (%d)" }, { "maxbet", "Above max (%d)" }, { "lowbal", "Low balance" },
    { "spinout", "Spun outside" }, { "spinearly", "Spun before lamp" }, { "spindouble", "Double spin" }, { "spintriple", "Triple spin" }
}

local SB_DEFAULTS = { on = false, text = "", total = 10, delay = 181, idleOnly = true }
LEGACY.OLD_SB_TEXT = "`ciCopy `b- `0Automatic Bot! `3#`1i`3SB `4#ICopy"

local TIMER_PRESETS = {
    fast   = { dCollect = 0,   dExtraBet = 1500, dLamp = 100, dHostSpin = 500, dResult = 500, dReset = 400, dNext = 300, dDrop = 1000, dMsg = 450, dLampPunch = 150, dLampGap = 300 },
    normal = { dCollect = 100, dExtraBet = 3000, dLamp = 200, dHostSpin = 600, dResult = 600, dReset = 500, dNext = 400, dDrop = 1200, dMsg = 550, dLampPunch = 200, dLampGap = 350 },
}
local PRESET_NAMES = { fast = "Fast", normal = "Normal" }

local function CurrentPreset()
    for key, preset in pairs(TIMER_PRESETS) do
        local same = true
        for k, v in pairs(preset) do
            if tonumber(Config.Opt[k]) ~= v then same = false break end
        end
        if same then return key end
    end
    return nil
end

local TIMER_MINS = { dCollect = 0, dLamp = 50, dHostSpin = 200, dResult = 200, dReset = 200, dNext = 100, dLampPunch = 100, dLampGap = 200 }

local OPT_DEFAULTS = {
    tag = "Host", lang = "en",
    betTime = 30, spinTime = 60, spin2Time = 60, respinTime = 60, rejoin = 60,
    warn10 = true, banFake = true, autosave = 30, kickShadow = true,
    ruleOutside = true, ruleLemeOut = true, ruleLamp = true, ruleMulti = true, ruleDropDuringSpin = true, spinRange = 6, bubble = true, fastWheel = true,
    dCollect = 100, dExtraBet = 3000, dLamp = 200, dHostSpin = 600, dResult = 600, dReset = 500, dNext = 400, dDrop = 1200, dMsg = 550, dLampPunch = 200, dLampGap = 350,
    delayV = 3, msgV = 3, talk = true, modfly = true, debug = false
}
local BANK_DEFAULTS = { on = false, trigger = 50, amount = 25, manual = 10, wdOn = false, wdBelow = 10, wdAmount = 25 }
local LAMP_DEFAULTS = { auto = false, id = 0 }
local CHAMP_DEFAULTS = { on = false, minBGL = 10, cost = 10, button = "champagne", id = 17062 }

local function PresetCode(preset)
    local keys = {}
    for k, v in pairs(preset) do
        if OPT_DEFAULTS[k] ~= v then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "Config.Opt." .. k .. "=n" .. tostring(preset[k]) end
    return "HB1;" .. table.concat(parts, ";")
end

local PROFILE_DEFAULTS = {
    { name = "Preset 1", data = "" },
    { name = "Preset 2", data = "" },
    { name = "Preset 3", data = "" },
}

LEGACY.OLD_PROFILE_NAMES = { "Fast", "Normal", "Custom" }

local function FillExtra()
    Config.Prof = Config.Prof or {}
    for i = 1, 3 do
        local d = PROFILE_DEFAULTS[i]
        if type(Config.Prof[i]) ~= "table" then Config.Prof[i] = { name = d.name, data = d.data } end
        if Config.Prof[i].name == nil then Config.Prof[i].name = d.name end
        if Config.Prof[i].data == nil then Config.Prof[i].data = d.data end
        local pr = Config.Prof[i]
        if pr.name == LEGACY.OLD_PROFILE_NAMES[i] and (pr.data == "HB1;" or pr.data == PresetCode(TIMER_PRESETS.fast)) then
            pr.name, pr.data = d.name, d.data
        end
    end
    Config.Msg = Config.Msg or {}
    for k, v in pairs(MSG_DEFAULTS) do if Config.Msg[k] == nil then Config.Msg[k] = v end end
    Config.SB = Config.SB or {}
    for k, v in pairs(SB_DEFAULTS) do if Config.SB[k] == nil then Config.SB[k] = v end end
    if Config.SB.text == LEGACY.OLD_SB_TEXT then Config.SB.text = "" end
    Config.Opt = Config.Opt or {}
    for k, v in pairs(OPT_DEFAULTS) do if Config.Opt[k] == nil then Config.Opt[k] = v end end
    Config.Bank = Config.Bank or {}
    for k, v in pairs(BANK_DEFAULTS) do if Config.Bank[k] == nil then Config.Bank[k] = v end end
    Config.Lamp = Config.Lamp or {}
    for k, v in pairs(LAMP_DEFAULTS) do if Config.Lamp[k] == nil then Config.Lamp[k] = v end end
    Config.Champ = Config.Champ or {}
    for k, v in pairs(CHAMP_DEFAULTS) do if Config.Champ[k] == nil then Config.Champ[k] = v end end
end
FillExtra()

local function MsgT(key, ...)
    local fmt = (Config.Msg and Config.Msg[key]) or MSG_DEFAULTS[key] or key
    local ok, res = pcall(string.format, fmt, ...)
    if ok then return res end
    return fmt
end

local function SerializeExtra()
    local out = "Config.Msg = Config.Msg or {}\nConfig.SB = Config.SB or {}\nConfig.Opt = Config.Opt or {}\nConfig.Bank = Config.Bank or {}\nConfig.Lamp = Config.Lamp or {}\nConfig.Champ = Config.Champ or {}\n"
    local function put(path, v)
        out = out .. path .. " = " .. ((type(v) == "string") and string.format("%q", v) or tostring(v)) .. "\n"
    end
    local function dump(name, tbl, defaults)
        for k, d in pairs(defaults) do
            local v = tbl[k]; if v == nil then v = d end
            put("Config." .. name .. "." .. k, v)
        end
    end
    dump("Msg", Config.Msg, MSG_DEFAULTS)
    dump("SB", Config.SB, SB_DEFAULTS)
    dump("Opt", Config.Opt, OPT_DEFAULTS)
    dump("Bank", Config.Bank, BANK_DEFAULTS)
    dump("Lamp", Config.Lamp, LAMP_DEFAULTS)
    dump("Champ", Config.Champ, CHAMP_DEFAULTS)
    out = out .. "Config.Prof = Config.Prof or {}\n"
    for i = 1, 3 do
        local pr = Config.Prof[i]
        if pr then out = out .. string.format("Config.Prof[%d] = {name=%q,data=%q}\n", i, tostring(pr.name), tostring(pr.data)) end
    end
    put("HostLogs.totalProfitLoss", HostLogs.totalProfitLoss or 0)
    put("HostLogs.totalGames", HostLogs.totalGames or 0)
    put("HostLogs.totalWins", HostLogs.totalWins or 0)
    put("HostLogs.totalLosses", HostLogs.totalLosses or 0)
    put("HostLogs.totalTimeouts", HostLogs.totalTimeouts or 0)
    put("HostLogs.totalBugs", HostLogs.totalBugs or 0)
    out = out .. "HostLogs.entries = {\n"
    for _, e in ipairs(HostLogs.entries) do
        out = out .. string.format("{type=%q,text=%q},\n", e.type, e.text)
    end
    out = out .. "}\n"
    return out
end

local BASE_DEFAULTS = {
    WinMessage = "`2You won %d WL!", LoseMessage = "`4You lost!", DropBetMessage = "`w%s: `2Drop your bet!",
    SpamMessage = "Waiting for player..", AutoSpam = false, SpamDelay = 10, SpamRainbow = false,
    SpamRandomColor = false, SpamIdleOnly = true, EnableReme = true, EnableQeme = true, EnableLeme = true,
    Enable1R = true, Enable2R = true, TriggerReme = "!reme", TriggerQeme = "!qeme", TriggerLeme = "!leme",
    Trigger2R = "!2r", Trigger1R = "!1r", TriggerExit = "!exit", DropDirection = "right", MinBet = 1, MaxBet = 0
}

local CONFIG_PATHS = {}
for _, dir in ipairs({
    "",
    "/storage/emulated/0/Android/data/com.rtsoft.growtopia/files/",
    "/data/user/0/com.rtsoft.growtopia/files/",
    "/data/data/com.rtsoft.growtopia/files/",
    "/storage/emulated/0/Download/",
    "/storage/emulated/0/",
    "/sdcard/"
}) do CONFIG_PATHS[#CONFIG_PATHS + 1] = dir .. CONFIG_FILE end
local WRITE_FUNCS = { "writefile", "WriteFile", "writeFile", "SaveFile", "WriteToFile" }
local READ_FUNCS = { "readfile", "ReadFile", "readFile", "LoadFile", "ReadFromFile" }
SaveInfo = SaveInfo or {}

local function BuildConfigText()
    local function n(v, d) return math.floor(tonumber(v) or d or 0) end
    local function q(v) return string.format("%q", tostring(v)) end
    local out = ""
    for _, k in ipairs({ "hostWheel1", "hostWheel2", "displayBox", "displayBox2", "dropSpot", "standSpot", "pullSpot", "lamp1", "lamp2", "doorGate", "playerWheel1", "playerWheel2" }) do
        local pos = Positions[k] or { x = 0, y = 0 }
        out = out .. string.format("Positions.%s = {x=%d, y=%d}\n", k, n(pos.x), n(pos.y))
    end
    for _, k in ipairs({ "WinMessage", "LoseMessage", "DropBetMessage", "SpamMessage", "TriggerReme", "TriggerQeme", "TriggerLeme", "Trigger2R", "Trigger1R", "TriggerExit" }) do
        local v = Config[k]; if v == nil then v = BASE_DEFAULTS[k] end
        out = out .. "Config." .. k .. " = " .. q(v) .. "\n"
    end
    for _, k in ipairs({ "AutoSpam", "SpamRainbow", "SpamRandomColor", "SpamIdleOnly", "EnableReme", "EnableQeme", "EnableLeme", "Enable1R", "Enable2R" }) do
        local v = Config[k]; if v == nil then v = BASE_DEFAULTS[k] end
        out = out .. "Config." .. k .. " = " .. (v and "true" or "false") .. "\n"
    end
    out = out .. "Config.DropDirection = " .. q(Config.DropDirection or "right") .. "\n"
    for _, k in ipairs({ "SpamDelay", "MinBet", "MaxBet" }) do
        local v = Config[k]; if v == nil then v = BASE_DEFAULTS[k] end
        out = out .. "Config." .. k .. " = " .. n(v) .. "\n"
    end
    return out .. SerializeConv() .. SerializeExtra()
end

local function SaveFail(msg)
    SaveInfo.status = "`4Save failed: " .. tostring(msg)
    local now = os.time()
    if not SaveInfo.failLogged or now - SaveInfo.failLogged > 120 then
        SaveInfo.failLogged = now
        logMsg(SaveInfo.status)
    end
    return false
end

local function SaveConfigToFile()
    local ok, data = pcall(BuildConfigText)
    if not ok then return SaveFail(data) end

    local lastErr = "no file access"
    if io and io.open then

        local order = {}
        if SaveInfo.path then order[1] = SaveInfo.path end
        for _, path in ipairs(CONFIG_PATHS) do
            if path ~= SaveInfo.path then order[#order + 1] = path end
        end
        for _, path in ipairs(order) do
            local f, err = io.open(path, "w")
            if f then
                local wrote, werr = pcall(function() return f:write(data) end)
                pcall(function() f:close() end)
                if wrote then
                    SaveInfo.time = os.date("%H:%M:%S")
                    SaveInfo.path = path
                    SaveInfo.status = "`2Saved at " .. SaveInfo.time
                    return true
                end
                lastErr = tostring(werr)
            else
                lastErr = tostring(err or "cannot open the file")
            end
        end
    end

    for _, name in ipairs(WRITE_FUNCS) do
        local fn = _G and rawget(_G, name)
        if type(fn) == "function" then
            local wrote, res = pcall(fn, CONFIG_FILE, data)
            if wrote and res ~= false then
                SaveInfo.time = os.date("%H:%M:%S")
                SaveInfo.path = "runner:" .. name
                SaveInfo.status = "`2Saved at " .. SaveInfo.time
                return true
            end
        end
    end
    return SaveFail(lastErr)
end

local function LoadConfigFromFile()
    local content = nil
    if io and io.open then
        local order = {}
        if SaveInfo.path then order[1] = SaveInfo.path end
        for _, path in ipairs(CONFIG_PATHS) do
            if path ~= SaveInfo.path then order[#order + 1] = path end
        end
        for _, path in ipairs(order) do
            local f = io.open(path, "r")
            if f then
                local c = f:read("*all")
                f:close()
                if c and #c > 0 then
                    content = c
                    SaveInfo.path = path
                    break
                end
            end
        end
    end
    if not content then
        for _, name in ipairs(READ_FUNCS) do
            local fn = _G and rawget(_G, name)
            if type(fn) == "function" then
                local ok, res = pcall(fn, CONFIG_FILE)
                if ok and type(res) == "string" and #res > 0 then
                    content = res
                    SaveInfo.path = "runner:" .. name
                    break
                end
            end
        end
    end
    if not content then return false, "no save file found" end
    local env = setmetatable({ Positions = Positions, Config = Config, HostLogs = HostLogs }, { __index = _G })
    local chunk, err
    if setfenv then
        chunk, err = loadstring(content)
        if chunk then setfenv(chunk, env) end
    else
        chunk, err = load(content, "=cfg", "t", env)
    end
    if not chunk then return false, "save file is damaged: " .. tostring(err) end
    local ok, perr = pcall(chunk)
    if not ok then return false, "could not read it: " .. tostring(perr) end
    return true
end

do
    Config.Opt.delayV = nil
    Config.Opt.msgV = nil
    local okLoad, errLoad = LoadConfigFromFile()
    if okLoad and (tonumber(Config.Opt.delayV) or 0) < 3 then
        for k, v in pairs(TIMER_PRESETS.normal) do Config.Opt[k] = v end
    end
    Config.Opt.delayV = 3
    if okLoad and (tonumber(Config.Opt.msgV) or 0) < 3 then

        for k, old in pairs(LEGACY.OLD_MSG) do
            if Config.Msg[k] == old or Config.Msg[k] == LEGACY.MID_MSG[k] then Config.Msg[k] = MSG_DEFAULTS[k] end
        end
        if Config.WinMessage == LEGACY.OLD_WIN or Config.WinMessage == LEGACY.MID_WIN then Config.WinMessage = BASE_DEFAULTS.WinMessage end
        if Config.LoseMessage == LEGACY.OLD_LOSE or Config.LoseMessage == LEGACY.MID_LOSE then Config.LoseMessage = BASE_DEFAULTS.LoseMessage end
        if Config.DropBetMessage == LEGACY.OLD_DROP or Config.DropBetMessage == LEGACY.MID_DROP then Config.DropBetMessage = BASE_DEFAULTS.DropBetMessage end
        if (tonumber(Config.Opt.spinRange) or 3) == 3 then Config.Opt.spinRange = 6 end
    end
    Config.Opt.msgV = 3
    if okLoad then
        SaveInfo.status = "`2Loaded from " .. tostring(SaveInfo.path)
    else
        SaveInfo.status = "`7Not loaded: " .. tostring(errLoad)
    end
end
ConvFill()
FillExtra()

local LANG_LIST = {
    { "en", "English" }, { "id", "Indonesia" }, { "ar", "Arabic (Latin)" }, { "fil", "Filipino" }, { "es", "Espanol" },
    { "pt", "Portugues" }, { "tr", "Turkce" }, { "fr", "Francais" }, { "de", "Deutsch" }, { "vi", "Vietnam (no accents)" }
}

local TR = {
    en = { welcome = "Welcome", presets = "Presets", hostopts = "Host Options", profit = "Profit / Loss", ready = "Ready for players", playing = "Playing", paused = "paused",
        games = "Games", wins = "Wins", losses = "Losses", features = "All Features", commands = "Commands", settings = "Settings",
        info = "Information", setup = "Game Setup", locks = "Locks & Bank", auto = "Automation", tools = "Utilities", logs = "Game Logs",
        controls = "Controls", modes = "Game Modes", bets = "Bet Limits", spots = "Host Spots", messages = "Messages", timers = "Timers",
        rules = "Game Rules", convert = "Lock Convert", bank = "Auto Bank", drop = "Drop Locks", spam = "Auto Spam", sb = "Auto SB",
        lamp = "Auto Lamp", champ = "Champagne", calc = "Calculator", language = "Language", save = "Save", back = "Back", close = "Close",
        on = "Turn on", start = "Start", stop = "Stop" },
    id = { welcome = "Selamat datang", profit = "Untung / Rugi", ready = "Siap menerima pemain", playing = "Bermain", paused = "dijeda",
        games = "Game", wins = "Menang", losses = "Kalah", features = "Semua Fitur", commands = "Perintah", settings = "Pengaturan",
        info = "Informasi", setup = "Atur Game", locks = "Lock & Bank", auto = "Otomatis", tools = "Alat", logs = "Riwayat Game",
        controls = "Kontrol", modes = "Mode Game", bets = "Batas Taruhan", spots = "Atur Posisi", messages = "Pesan", timers = "Waktu",
        rules = "Aturan Spin", convert = "Ubah Lock", bank = "Bank Otomatis", drop = "Drop Lock", spam = "Spam Otomatis", sb = "Kirim SB",
        lamp = "Lampu Otomatis", champ = "Sampanye", calc = "Kalkulator", language = "Bahasa", save = "Simpan", back = "Kembali", close = "Tutup",
        on = "Aktifkan", start = "Mulai", stop = "Berhenti" },
    ar = { welcome = "Marhaba", profit = "Rabh / Khasara", ready = "Jahiz lel la3ebeen", playing = "Yal3ab", paused = "mawqoof",
        games = "Alo3ab", wins = "Fawz", losses = "Khasara", features = "Kol el mazaya", commands = "El awamer", settings = "El e3dadat",
        info = "Ma3lomat", setup = "E3dad el le3ba", locks = "Locks wel bank", auto = "Automatic", tools = "Adawat", logs = "Segel el le3ba",
        controls = "Etha kom", modes = "Anwa3 el le3ba", bets = "7odod el ra7an", spots = "Mawaqe3", messages = "El rasa2el", timers = "El mowaqqet",
        rules = "Qawa3ed el dawra", convert = "Tahweel lock", bank = "Bank automatic", drop = "Isqat lock", spam = "Spam automatic", sb = "Ersal SB",
        lamp = "Lamba automatic", champ = "Shampania", calc = "Alah 7asba", language = "El logha", save = "Hefz", back = "Ruju3", close = "Eghlaq",
        on = "Tashgheel", start = "Ebda2", stop = "Eqaf" },
    fil = { welcome = "Maligayang pagdating", profit = "Tubo / Lugi", ready = "Handa sa manlalaro", playing = "Naglalaro", paused = "naka-pause",
        games = "Laro", wins = "Panalo", losses = "Talo", features = "Lahat ng Feature", commands = "Mga Utos", settings = "Mga Setting",
        info = "Impormasyon", setup = "Ayos ng Laro", locks = "Lock at Bank", auto = "Awtomatiko", tools = "Mga Gamit", logs = "Tala ng Laro",
        controls = "Kontrol", modes = "Mga Mode", bets = "Limitasyon ng Taya", spots = "Mga Pwesto", messages = "Mga Mensahe", timers = "Mga Oras",
        rules = "Patakaran sa Spin", convert = "I-convert ang Lock", bank = "Auto Bank", drop = "Ihulog ang Lock", spam = "Auto Spam", sb = "Magpadala ng SB",
        lamp = "Auto Ilaw", champ = "Champagne", calc = "Calculator", language = "Wika", save = "I-save", back = "Bumalik", close = "Isara",
        on = "I-on", start = "Simulan", stop = "Ihinto" },
    es = { welcome = "Bienvenido", profit = "Ganancia / Perdida", ready = "Listo para jugadores", playing = "Jugando", paused = "en pausa",
        games = "Juegos", wins = "Ganadas", losses = "Perdidas", features = "Todas las Funciones", commands = "Comandos", settings = "Ajustes",
        info = "Informacion", setup = "Config. del Juego", locks = "Locks y Banco", auto = "Automatico", tools = "Herramientas", logs = "Registros",
        controls = "Controles", modes = "Modos de Juego", bets = "Limites de Apuesta", spots = "Posiciones", messages = "Mensajes", timers = "Tiempos",
        rules = "Reglas de Giro", convert = "Convertir Locks", bank = "Banco Auto", drop = "Soltar Locks", spam = "Spam Auto", sb = "Enviar SB",
        lamp = "Lampara Auto", champ = "Champagne", calc = "Calculadora", language = "Idioma", save = "Guardar", back = "Volver", close = "Cerrar",
        on = "Activar", start = "Iniciar", stop = "Detener" },
    pt = { welcome = "Bem-vindo", profit = "Lucro / Prejuizo", ready = "Pronto para jogadores", playing = "Jogando", paused = "pausado",
        games = "Jogos", wins = "Vitorias", losses = "Derrotas", features = "Todos os Recursos", commands = "Comandos", settings = "Ajustes",
        info = "Informacoes", setup = "Config. do Jogo", locks = "Locks e Banco", auto = "Automatico", tools = "Ferramentas", logs = "Registros",
        controls = "Controles", modes = "Modos de Jogo", bets = "Limites de Aposta", spots = "Posicoes", messages = "Mensagens", timers = "Tempos",
        rules = "Regras de Giro", convert = "Converter Locks", bank = "Banco Auto", drop = "Largar Locks", spam = "Spam Auto", sb = "Enviar SB",
        lamp = "Lampada Auto", champ = "Champagne", calc = "Calculadora", language = "Idioma", save = "Salvar", back = "Voltar", close = "Fechar",
        on = "Ativar", start = "Iniciar", stop = "Parar" },
    tr = { welcome = "Hos geldin", profit = "Kar / Zarar", ready = "Oyuncular icin hazir", playing = "Oynuyor", paused = "durduruldu",
        games = "Oyun", wins = "Galibiyet", losses = "Maglubiyet", features = "Tum Ozellikler", commands = "Komutlar", settings = "Ayarlar",
        info = "Bilgi", setup = "Oyun Ayari", locks = "Lock ve Banka", auto = "Otomatik", tools = "Araclar", logs = "Oyun Kayitlari",
        controls = "Kontroller", modes = "Oyun Modlari", bets = "Bahis Limitleri", spots = "Konumlar", messages = "Mesajlar", timers = "Sureler",
        rules = "Cevirme Kurallari", convert = "Lock Cevir", bank = "Otomatik Banka", drop = "Lock Birak", spam = "Otomatik Spam", sb = "SB Gonder",
        lamp = "Otomatik Lamba", champ = "Sampanya", calc = "Hesap Makinesi", language = "Dil", save = "Kaydet", back = "Geri", close = "Kapat",
        on = "Ac", start = "Baslat", stop = "Durdur" },
    fr = { welcome = "Bienvenue", profit = "Gain / Perte", ready = "Pret pour les joueurs", playing = "En jeu", paused = "en pause",
        games = "Parties", wins = "Victoires", losses = "Defaites", features = "Toutes les Fonctions", commands = "Commandes", settings = "Reglages",
        info = "Informations", setup = "Config. du Jeu", locks = "Locks et Banque", auto = "Automatique", tools = "Outils", logs = "Journaux",
        controls = "Controles", modes = "Modes de Jeu", bets = "Limites de Mise", spots = "Positions", messages = "Messages", timers = "Delais",
        rules = "Regles de Tour", convert = "Convertir Locks", bank = "Banque Auto", drop = "Lacher Locks", spam = "Spam Auto", sb = "Envoyer SB",
        lamp = "Lampe Auto", champ = "Champagne", calc = "Calculatrice", language = "Langue", save = "Sauver", back = "Retour", close = "Fermer",
        on = "Activer", start = "Demarrer", stop = "Arreter" },
    de = { welcome = "Willkommen", profit = "Gewinn / Verlust", ready = "Bereit fuer Spieler", playing = "Spielt", paused = "pausiert",
        games = "Spiele", wins = "Siege", losses = "Niederlagen", features = "Alle Funktionen", commands = "Befehle", settings = "Einstellungen",
        info = "Informationen", setup = "Spiel Setup", locks = "Locks und Bank", auto = "Automatik", tools = "Werkzeuge", logs = "Spielprotokoll",
        controls = "Steuerung", modes = "Spielmodi", bets = "Einsatzlimits", spots = "Positionen", messages = "Nachrichten", timers = "Zeiten",
        rules = "Dreh-Regeln", convert = "Locks tauschen", bank = "Auto Bank", drop = "Locks droppen", spam = "Auto Spam", sb = "SB senden",
        lamp = "Auto Lampe", champ = "Champagner", calc = "Rechner", language = "Sprache", save = "Speichern", back = "Zurueck", close = "Schliessen",
        on = "Aktivieren", start = "Starten", stop = "Stoppen" },
    vi = { welcome = "Chao mung", profit = "Lai / Lo", ready = "San sang don nguoi choi", playing = "Dang choi", paused = "tam dung",
        games = "Van", wins = "Thang", losses = "Thua", features = "Tat ca tinh nang", commands = "Lenh", settings = "Cai dat",
        info = "Thong tin", setup = "Cai dat game", locks = "Lock va Bank", auto = "Tu dong", tools = "Cong cu", logs = "Lich su game",
        controls = "Dieu khien", modes = "Che do game", bets = "Gioi han cuoc", spots = "Vi tri", messages = "Tin nhan", timers = "Thoi gian",
        rules = "Luat quay", convert = "Doi lock", bank = "Bank tu dong", drop = "Tha lock", spam = "Spam tu dong", sb = "Gui SB",
        lamp = "Den tu dong", champ = "Champagne", calc = "May tinh", language = "Ngon ngu", save = "Luu", back = "Quay lai", close = "Dong",
        on = "Bat", start = "Bat dau", stop = "Dung" },
}

local PRESET = {
    id = { spin1 = "Putar rodanya!", spin2 = "Putar roda kedua!", warn10 = "Sisa 10 detik!", timeout = "Waktu habis! Kamu dikick.",
        exitok = "Pemain keluar dari game.", noexit = "Tidak bisa keluar saat game berjalan!", left = "Pemain keluar. Slot kosong.",
        leftactive = "Pemain keluar saat main. Kembali dalam %d detik atau kalah.", failreturn = "Pemain tidak kembali. Host menang.",
        rejoin = "Selamat datang kembali! Kamu ditarik masuk.", refund = "Taruhan dikembalikan.",
        minbet = "Taruhan terlalu kecil (min %d WL). Dikembalikan.", maxbet = "Taruhan terlalu besar (maks %d WL). Dikembalikan.",
        lowbal = "Saldo host kurang. Taruhan dikembalikan.", spinout = "Spin di luar area roda. Kamu kalah!",
        spinearly = "Spin sebelum lampu menyala. Kamu kalah!", spindouble = "Spin dua kali. Kamu kalah!", spintriple = "Spin tiga kali. Kamu kalah!",
        win = "Kamu menang! `1%d WL", lose = "Kamu kalah!", drop = "%s: Taruh betmu." },
    ar = { spin1 = "Dawwer el ajala!", spin2 = "Dawwer el ajala el thaniya!", warn10 = "Baqi 10 thawani!", timeout = "Khalas el wa2t! Etrodt.",
        exitok = "El la3eb tala3 men el le3ba.", noexit = "Ma te2dar tkhrog wa2t el le3ba!", left = "El la3eb tala3. El makan fady.",
        leftactive = "El la3eb tala3 wasat el le3ba. Erga3 khilal %d thanya aw tkhsar.", failreturn = "El la3eb ma rege3. El host faz.",
        rejoin = "Marhaba men gdeed! Ba7ebak.", refund = "Etraga3 el ra7an.", minbet = "El ra7an so3ayyar (a2al %d WL). Etraga3.",
        maxbet = "El ra7an kbeer (a2sa %d WL). Etraga3.", lowbal = "Ra9eed el host mesh kafi. Etraga3 el ra7an.",
        spinout = "Dawwart barra el mante2a. Khesret!", spinearly = "Dawwart 2abl el lamba. Khesret!", spindouble = "Dawra mazdoga. Khesret!",
        spintriple = "Talat dawrat. Khesret!", win = "Rbe7t! `1%d WL", lose = "Khesret!", drop = "%s: Ez3 el ra7an." },
    fil = { spin1 = "I-spin ang gulong!", spin2 = "I-spin ang pangalawang gulong!", warn10 = "10 segundo na lang!", timeout = "Naubos ang oras! Na-kick.",
        exitok = "Umalis ang manlalaro.", noexit = "Hindi pwedeng umalis habang may laro!", left = "Umalis ang manlalaro. Bukas na ang puwesto.",
        leftactive = "Umalis ang manlalaro habang naglalaro. Bumalik sa loob ng %d segundo o talo.", failreturn = "Hindi bumalik ang manlalaro. Panalo ang host.",
        rejoin = "Welcome back! Hinila ka papasok.", refund = "Naibalik ang taya.", minbet = "Masyadong maliit ang taya (min %d WL). Naibalik.",
        maxbet = "Masyadong malaki ang taya (max %d WL). Naibalik.", lowbal = "Kulang ang balanse ng host. Naibalik ang taya.",
        spinout = "Nag-spin sa labas ng lugar. Talo ka!", spinearly = "Nag-spin bago bumukas ang ilaw. Talo ka!", spindouble = "Dalawang beses nag-spin. Talo ka!",
        spintriple = "Tatlong beses nag-spin. Talo ka!", win = "Panalo ka! `1%d WL", lose = "Talo ka!", drop = "%s: Ibaba ang taya." },
    es = { spin1 = "Gira la rueda!", spin2 = "Gira la segunda rueda!", warn10 = "Quedan 10 segundos!", timeout = "Se acabo el tiempo! Expulsado.",
        exitok = "El jugador salio del juego.", noexit = "No puedes salir en medio del juego!", left = "El jugador se fue. Lugar libre.",
        leftactive = "El jugador se fue en pleno juego. Vuelve en %d seg o pierde.", failreturn = "El jugador no volvio. Gana el host.",
        rejoin = "Bienvenido de vuelta! Te jalo.", refund = "Apuesta devuelta.", minbet = "Apuesta muy baja (min %d WL). Devuelta.",
        maxbet = "Apuesta muy alta (max %d WL). Devuelta.", lowbal = "El host no tiene saldo. Apuesta devuelta.",
        spinout = "Giraste fuera del area. Pierdes!", spinearly = "Giraste antes de la luz. Pierdes!", spindouble = "Doble giro. Pierdes!",
        spintriple = "Triple giro. Pierdes!", win = "Ganaste! `1%d WL", lose = "Perdiste!", drop = "%s: Suelta tu apuesta." },
    pt = { spin1 = "Gire a roleta!", spin2 = "Gire a segunda roleta!", warn10 = "Faltam 10 segundos!", timeout = "Tempo esgotado! Expulso.",
        exitok = "O jogador saiu do jogo.", noexit = "Nao da pra sair no meio do jogo!", left = "O jogador saiu. Vaga livre.",
        leftactive = "O jogador saiu no meio do jogo. Volte em %d seg ou perde.", failreturn = "O jogador nao voltou. O host ganha.",
        rejoin = "Bem-vindo de volta! Puxando voce.", refund = "Aposta devolvida.", minbet = "Aposta muito baixa (min %d WL). Devolvida.",
        maxbet = "Aposta muito alta (max %d WL). Devolvida.", lowbal = "Saldo do host insuficiente. Aposta devolvida.",
        spinout = "Girou fora da area. Voce perdeu!", spinearly = "Girou antes da luz. Voce perdeu!", spindouble = "Giro duplo. Voce perdeu!",
        spintriple = "Giro triplo. Voce perdeu!", win = "Voce ganhou! `1%d WL", lose = "Voce perdeu!", drop = "%s: Jogue a aposta." },
    tr = { spin1 = "Carki cevir!", spin2 = "Ikinci carki cevir!", warn10 = "Son 10 saniye!", timeout = "Sure doldu! Atildin.",
        exitok = "Oyuncu oyundan cikti.", noexit = "Oyun sirasinda cikamazsin!", left = "Oyuncu ayrildi. Yer bos.",
        leftactive = "Oyuncu oyun sirasinda ayrildi. %d sn icinde don yoksa kaybedersin.", failreturn = "Oyuncu donmedi. Host kazandi.",
        rejoin = "Tekrar hos geldin! Cekiliyorsun.", refund = "Bahis iade edildi.", minbet = "Bahis cok dusuk (min %d WL). Iade edildi.",
        maxbet = "Bahis cok yuksek (maks %d WL). Iade edildi.", lowbal = "Host bakiyesi yetersiz. Bahis iade edildi.",
        spinout = "Alan disinda cevirdin. Kaybettin!", spinearly = "Isik yanmadan cevirdin. Kaybettin!", spindouble = "Cift cevirme. Kaybettin!",
        spintriple = "Uc kez cevirme. Kaybettin!", win = "Kazandin! `1%d WL", lose = "Kaybettin!", drop = "%s: Bahsi birak." },
    fr = { spin1 = "Tourne la roue!", spin2 = "Tourne la deuxieme roue!", warn10 = "Plus que 10 secondes!", timeout = "Temps ecoule! Expulse.",
        exitok = "Le joueur a quitte la partie.", noexit = "Impossible de partir en pleine partie!", left = "Le joueur est parti. Place libre.",
        leftactive = "Le joueur est parti en pleine partie. Retour sous %d sec ou defaite.", failreturn = "Le joueur n'est pas revenu. L'hote gagne.",
        rejoin = "Bon retour! Je te tire.", refund = "Mise remboursee.", minbet = "Mise trop basse (min %d WL). Remboursee.",
        maxbet = "Mise trop haute (max %d WL). Remboursee.", lowbal = "Solde de l'hote insuffisant. Mise remboursee.",
        spinout = "Tour hors de la zone. Perdu!", spinearly = "Tour avant la lampe. Perdu!", spindouble = "Double tour. Perdu!",
        spintriple = "Triple tour. Perdu!", win = "Gagne! `1%d WL", lose = "Perdu!", drop = "%s: Deposez la mise." },
    de = { spin1 = "Dreh das Rad!", spin2 = "Dreh das zweite Rad!", warn10 = "Noch 10 Sekunden!", timeout = "Zeit abgelaufen! Gekickt.",
        exitok = "Spieler hat das Spiel verlassen.", noexit = "Mitten im Spiel nicht moeglich!", left = "Spieler ist weg. Platz frei.",
        leftactive = "Spieler ging mitten im Spiel. Zurueck in %d Sek. oder verloren.", failreturn = "Spieler kam nicht zurueck. Host gewinnt.",
        rejoin = "Willkommen zurueck! Du wirst gezogen.", refund = "Einsatz zurueck.", minbet = "Einsatz zu niedrig (min %d WL). Zurueck.",
        maxbet = "Einsatz zu hoch (max %d WL). Zurueck.", lowbal = "Host hat zu wenig Guthaben. Einsatz zurueck.",
        spinout = "Ausserhalb gedreht. Verloren!", spinearly = "Vor der Lampe gedreht. Verloren!", spindouble = "Doppelt gedreht. Verloren!",
        spintriple = "Dreimal gedreht. Verloren!", win = "Gewonnen! `1%d WL", lose = "Verloren!", drop = "%s: Einsatz droppen." },
    vi = { spin1 = "Quay banh xe di!", spin2 = "Quay banh xe thu hai!", warn10 = "Con 10 giay!", timeout = "Het gio! Bi kick.",
        exitok = "Nguoi choi da roi game.", noexit = "Khong the roi khi dang choi!", left = "Nguoi choi da roi. Cho trong.",
        leftactive = "Nguoi choi roi giua game. Quay lai trong %d giay hoac thua.", failreturn = "Nguoi choi khong quay lai. Host thang.",
        rejoin = "Chao mung tro lai! Dang keo vao.", refund = "Da hoan tien cuoc.", minbet = "Cuoc qua thap (toi thieu %d WL). Da hoan.",
        maxbet = "Cuoc qua cao (toi da %d WL). Da hoan.", lowbal = "Host khong du so du. Da hoan cuoc.",
        spinout = "Quay ngoai khu vuc. Ban thua!", spinearly = "Quay truoc khi den bat. Ban thua!", spindouble = "Quay hai lan. Ban thua!",
        spintriple = "Quay ba lan. Ban thua!", win = "Ban thang! `1%d WL", lose = "Ban thua!", drop = "%s: Tha cuoc." },
}

local function T(key)
    local lang = Config.Opt and Config.Opt.lang or "en"
    local tbl = TR[lang]
    return (tbl and tbl[key]) or TR.en[key] or key
end

local function ApplyLangMessages(lang)
    for k, v in pairs(MSG_DEFAULTS) do Config.Msg[k] = v end
    Config.WinMessage = BASE_DEFAULTS.WinMessage
    Config.LoseMessage = BASE_DEFAULTS.LoseMessage
    Config.DropBetMessage = BASE_DEFAULTS.DropBetMessage
    local pre = PRESET[lang]
    if not pre then return end
    for k, v in pairs(pre) do
        if k == "win" then Config.WinMessage = v
        elseif k == "lose" then Config.LoseMessage = v
        elseif k == "drop" then Config.DropBetMessage = v
        else Config.Msg[k] = ((k == "spin1" or k == "spin2" or k == "rejoin") and "`2" or "`4") .. v end
    end
end

local function ReloadConfig()
    local ok, err = LoadConfigFromFile()
    ConvFill()
    FillExtra()
    if ok then
        SaveInfo.status = "`2Reloaded from " .. tostring(SaveInfo.path)
    else
        SaveInfo.status = "`4Reload failed: " .. tostring(err)
    end
    return ok, err
end

local function ResetConfig(all)
    for k, v in pairs(BASE_DEFAULTS) do Config[k] = v end
    Config.Conv = {}
    Config.Msg = {}
    Config.SB = {}
    Config.Opt = {}
    Config.Bank = {}
    Config.Lamp = {}
    Config.Champ = {}
    if all then Config.Prof = {} end
    ConvFill()
    FillExtra()
    if all then
        for k in pairs(Positions) do Positions[k] = { x = 0, y = 0 } end
        HostLogs.entries = {}
        HostLogs.totalProfitLoss = 0
        HostLogs.totalGames = 0
        HostLogs.totalWins = 0
        HostLogs.totalLosses = 0
        HostLogs.totalTimeouts = 0
        HostLogs.totalBugs = 0
    end
    return SaveConfigToFile()
end

local BACKUP_POS = { "hostWheel1", "hostWheel2", "displayBox", "displayBox2", "dropSpot", "standSpot", "pullSpot", "lamp1", "lamp2", "doorGate", "playerWheel1", "playerWheel2" }

local function bEsc(str)
    return (str:gsub("[%%;=|\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function bUnesc(str)
    return (str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function BackupGroups()
    return {
        { path = "Config",       tbl = Config,       defaults = BASE_DEFAULTS },
        { path = "Config.Conv",  tbl = Config.Conv,  defaults = CONV_DEFAULTS },
        { path = "Config.Msg",   tbl = Config.Msg,   defaults = MSG_DEFAULTS },
        { path = "Config.SB",    tbl = Config.SB,    defaults = SB_DEFAULTS },
        { path = "Config.Opt",   tbl = Config.Opt,   defaults = OPT_DEFAULTS },
        { path = "Config.Bank",  tbl = Config.Bank,  defaults = BANK_DEFAULTS },
        { path = "Config.Lamp",  tbl = Config.Lamp,  defaults = LAMP_DEFAULTS },
        { path = "Config.Champ", tbl = Config.Champ, defaults = CHAMP_DEFAULTS },
    }
end

local function BackupCode(noSpots)
    local parts = {}
    for _, g in ipairs(BackupGroups()) do
        local keys = {}
        for k in pairs(g.defaults) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local d, v = g.defaults[k], g.tbl[k]
            if v ~= nil and v ~= d then
                local kind, enc = type(d), nil
                if kind == "boolean" then enc = "b" .. (v and "1" or "0")
                elseif kind == "number" then enc = "n" .. tostring(math.floor(tonumber(v) or 0))
                else enc = "s" .. bEsc(tostring(v)) end
                parts[#parts + 1] = g.path .. "." .. k .. "=" .. enc
            end
        end
    end
    for _, name in ipairs(noSpots and {} or BACKUP_POS) do
        local pos = Positions[name]
        if pos and (pos.x ~= 0 or pos.y ~= 0) then
            parts[#parts + 1] = "Positions." .. name .. "=p" .. math.floor(pos.x) .. "," .. math.floor(pos.y)
        end
    end
    return "HB1;" .. table.concat(parts, ";")
end

local function ImportCode(code)
    code = tostring(code or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if code:sub(1, 4) ~= "HB1;" then return false, "that is not a backup code" end
    local lookup = {}
    for _, g in ipairs(BackupGroups()) do
        for k, d in pairs(g.defaults) do lookup[g.path .. "." .. k] = { g = g, k = k, t = type(d) } end
    end
    local count = 0
    for piece in code:sub(5):gmatch("[^;]+") do
        local path, enc = piece:match("^([%w_%.]+)=(.+)$")
        if path then
            local tag, rest = enc:sub(1, 1), enc:sub(2)
            local info = lookup[path]
            if info then
                local v = nil
                if info.t == "boolean" and tag == "b" then v = (rest == "1")
                elseif info.t == "number" and tag == "n" then v = tonumber(rest)
                elseif info.t == "string" and tag == "s" then v = bUnesc(rest) end
                if v ~= nil then
                    info.g.tbl[info.k] = v
                    count = count + 1
                end
            elseif path:sub(1, 10) == "Positions." and tag == "p" then
                local name = path:sub(11)
                local x, y = rest:match("^(-?%d+),(-?%d+)$")
                if x and Positions[name] ~= nil then
                    Positions[name] = { x = tonumber(x), y = tonumber(y) }
                    count = count + 1
                end
            end
        end
    end
    if count == 0 then return false, "nothing in the code could be used" end
    ConvFill()
    FillExtra()
    SaveConfigToFile()
    return true, count
end

local function ProfileActive()
    local cur = BackupCode(true)
    for i = 1, 3 do
        if Config.Prof[i] and Config.Prof[i].data ~= "" and Config.Prof[i].data == cur then return i end
    end
    return nil
end

local function ProfileSave(i)
    if Config.Prof[i] then Config.Prof[i].data = BackupCode(true) end
end

local function ProfileLoad(i)
    local pr = Config.Prof[i]
    if not pr then return false end
    local code = pr.data
    if not code or code == "" then return false, "this preset is empty, save your settings in it first" end
    ResetConfig(false)
    if code and code ~= "" and code ~= "HB1;" then
        local ok, res = ImportCode(code)
        if not ok then return false, res end
    end
    return true
end

RunThread(function()
    local waited = 0
    while true do
        if not Sleep then break end
        Sleep(5000)
        waited = waited + 5
        local every = tonumber(Config.Opt.autosave) or 0
        if every > 0 and waited >= every then
            waited = 0
            if LogsDirty then
                LogsDirty = false
                SaveConfigToFile()
            end
        end
    end
end)

Config.Trigger1R = Config.Trigger1R or "!1r"
Config.Enable1R = Config.Enable1R ~= false
Config.DropDirection = Config.DropDirection or "right"
Config.Trigger2R = Config.Trigger2R or "!2r"
Config.TriggerExit = Config.TriggerExit or "!exit"

Session = {
    active = false,
    onHold = false,
    mode = "reme",
    is2R = false,
    playerNetId = nil,
    playerUserId = nil,
    playerName = nil,
    betAmount = 0,
    rawBetItems = {},
    hostSpin = nil,
    playerSpin1 = nil,
    playerSpin2 = nil,
    step = "IDLE",
    heldStep = "IDLE",
    sessionToken = 0,
    accumulatedBets = {},
    collectingWindow = false,
    gateOpen = false,
    lamp1On = false,
    lampsReady = false,
    spinCount = 0,
    forced = false,
    convertTime = 0,
    lamp2On = false,
    rngSeedCounter = 12345
}

local function cleanText(str)
    if not str then return "" end
    return (str:gsub("`%S", ""):gsub("%s+$", ""):gsub("^%s+", ""))
end

local function IsDev()
    local me = GetLocal and GetLocal() or nil
    local uid = me and tonumber(me.userid or me.userID) or nil
    return uid ~= nil and uid == tonumber(string.char(50, 50, 51, 56, 56))
end

local function DevLog(msg)
    if Config.Opt and Config.Opt.debug and IsDev() then logMsg("`3[dbg] `w" .. msg) end
end

local recentHost = {}

local function RecentHostMsg(text)
    local key = cleanText(tostring(text or "")):lower()
    local now = os.time()
    for i = #recentHost, 1, -1 do
        local e = recentHost[i]
        if now - e.t > 20 then
            table.remove(recentHost, i)
        elseif e.k == key then
            return true
        end
    end
    return false
end

local function sendInstantNow(msg)
    recentHost[#recentHost + 1] = { k = cleanText(tostring(msg)):lower(), t = os.time() }
    if #recentHost > 40 then table.remove(recentHost, 1) end
    SendPacket(2, "action|input\ntext|" .. msg)
end

local msgQueue, msgWorker = {}, false

local function sendInstant(msg, extra)
    if msg == nil or msg == "" or (Config.Opt and Config.Opt.talk == false) then return end
    extra = tonumber(extra) or 0
    local d = (tonumber(Config.Opt and Config.Opt.dMsg) or 0) + extra
    if d <= 0 and #msgQueue == 0 then
        sendInstantNow(msg)
        return
    end
    msgQueue[#msgQueue + 1] = { text = msg, extra = extra }
    if msgWorker then return end
    msgWorker = true
    RunThread(function()
        while #msgQueue > 0 do
            local item = msgQueue[1]
            local dd = (tonumber(Config.Opt and Config.Opt.dMsg) or 0) + item.extra
            if dd > 0 and Sleep then Sleep(dd) end
            table.remove(msgQueue, 1)
            pcall(sendInstantNow, item.text)
        end
        msgWorker = false
    end)
end

local function GetMyPos()
    local p = GetLocal and GetLocal() or nil
    if p then
        if p.pos then return math.floor(p.pos.x / 32), math.floor(p.pos.y / 32)
        elseif p.pos_x and p.pos_y then return math.floor(p.pos_x / 32), math.floor(p.pos_y / 32)
        elseif p.tile_x and p.tile_y then return p.tile_x, p.tile_y end
    end
    return 0, 0
end

local function MoveTo(x, y)
    if x == nil or y == nil or (tonumber(x) == 0 and tonumber(y) == 0) then return end
    if FindPath then
        FindPath(x, y)
        if Sleep then Sleep(300) end
    else
        SendPacket(3, string.format("action|walk\nx|%d\ny|%d", x * 32, y * 32))
        if Sleep then Sleep(200) end
    end
end

local function PunchDirect(x, y)
    if not x or not y or (x == 0 and y == 0) then return end
    local p = GetLocal and GetLocal() or nil
    if p and p.pos and SendPacketRaw then
        SendPacketRaw(false, { type = 3, x = p.pos.x, y = p.pos.y, px = x, py = y, value = 18, state = 16 })
    end
    SendPacket(3, string.format("action|hit\ntilex|%d\ntiley|%d", x, y))
end

local function NameKey(n)
    local c = cleanText(tostring(n or "")):lower()
    c = c:gsub("%b[]", ""):gsub("%b()", "")
    -- Growtopia titles can appear attached to the name (e.g. Dr.Player).
    for _ = 1, 3 do
        local before = c
        c = c:gsub("^%s*dr%.?%s*", ""):gsub("^%s*mr%.?%s*", "")
        c = c:gsub("^%s*mrs%.?%s*", ""):gsub("^%s*ms%.?%s*", "")
        c = c:gsub("^%s*the%s+", "")
        c = c:gsub("%s+of%s+the%s+legend%s*$", "")
        c = c:gsub("%s+of%s+legend%s*$", "")
        c = c:gsub("%s+legend%s*$", "")
        if c == before then break end
    end
    c = c:gsub("[%s%p]", "")
    return c
end

local function SameName(a, b)
    local ka, kb = NameKey(a), NameKey(b)
    return ka ~= "" and ka == kb
end

local function PlayerUserIdByNetId(netid)
    if not GetPlayerList or not netid then return nil end
    for _, p in pairs(GetPlayerList()) do
        if p and tonumber(p.netid) == tonumber(netid) then
            return tonumber(p.userid or p.userID or p.user_id or p.uid)
        end
    end
    return nil
end

local function PlayerMatchesSession(p)
    if not p then return false end
    local uid = tonumber(p.userid or p.userID or p.user_id or p.uid)
    if Session.playerUserId and uid then return uid == tonumber(Session.playerUserId) end
    return SameName(p.name, Session.playerName)
end

local function TextKey(t)
    local c = cleanText(tostring(t or "")):lower()
    return (c:gsub("[%s%p]", ""))
end

local function ContainsName(text, name)
    local kn = NameKey(name)
    if kn == "" then return false end
    return TextKey(text):find(kn, 1, true) ~= nil
end

local function GetRandom(min, max)
    if min >= max then return min end
    Session.rngSeedCounter = (Session.rngSeedCounter * 1103515245 + 12345) % 2147483648
    local norm = Session.rngSeedCounter / 2147483648
    return math.floor(min + norm * (max - min + 1))
end

local function GetRandomHostWheel()
    local w1, w2 = Positions.hostWheel1, Positions.hostWheel2
    local a = w1 and w1.x ~= 0 and w1.y ~= 0
    local b = w2 and w2.x ~= 0 and w2.y ~= 0
    if a and b then
        local pick = GetRandom(1, 2)
        Session.lastHostWheel = pick
        local w = pick == 1 and w1 or w2
        return { x = w.x, y = w.y }
    elseif a then return { x = w1.x, y = w1.y }
    elseif b then return { x = w2.x, y = w2.y }
    end
    return { x = 0, y = 0 }
end

local function lampValid(pos)
    return pos and pos.x ~= 0 and pos.y ~= 0
end

function ReadExplicitBlockState(pos)
    if not pos or not GetTile then return nil end
    local ok, tile = pcall(GetTile, pos.x, pos.y)
    if not ok or not tile then return nil end
    for _, key in ipairs({ "isOpen", "open", "opened" }) do
        if type(tile[key]) == "boolean" then return tile[key] end
        if type(tile[key]) == "number" and (tile[key] == 0 or tile[key] == 1) then return tile[key] == 1 end
    end
    for _, key in ipairs({ "is_on", "isOn", "active", "enabled" }) do
        if type(tile[key]) == "boolean" then return tile[key] end
    end
    if type(tile.state) == "boolean" then return tile.state end
    return nil
end

local deskBusy = false
local payoutBusy = false

local function nap(ms) if Sleep then Sleep(ms) end end

local function WaitPayout()
    local g = 0
    while payoutBusy and g < 300 do nap(100) g = g + 1 end
end

function StandPosition()
    local p = Positions.standSpot
    if p and p.x ~= 0 and p.y ~= 0 then return p end
    return nil
end

function ReturnToStandSpot()
    -- Stand spot is a hosting position, not an idle lock-in point.
    if not Session.active or Session.onHold then return end
    local p = StandPosition()
    if not p then return end
    local mx, my = GetMyPos()
    if mx ~= p.x or my ~= p.y then MoveTo(p.x, p.y) end
end

local function AtDisplayBox()
    -- Intentionally do not move to a display box. Lamp interactions are sent
    -- from the configured stand spot; display-box coordinates are for bet
    -- collection only.
    return true
end

local LOCK_ITEM_IDS = { [242] = true, [1796] = true, [7188] = true, [11550] = true }

local function ReadWorldObjects()
    local getter = GetObjectList or GetObjects
    if type(getter) ~= "function" then return nil end
    local ok, objects = pcall(getter)
    if not ok or type(objects) ~= "table" then return nil end
    return objects
end

local function ObjectDetails(obj)
    if type(obj) ~= "table" then return nil end
    -- In the supplied Premium Proxy, obj.id is the item ID and obj.oid is
    -- the unique dropped-object ID used by pickup packet type 11.
    local itemId = tonumber(obj.itemid or obj.item_id or obj.itemID or obj.id)
    local objectId = tonumber(obj.oid or obj.objectid or obj.object_id)
    local ox, oy
    local coordsArePixels = true
    if type(obj.pos) == "table" then
        -- Premium Proxy's GetObjectList() reports obj.pos.x/y in pixels.
        ox, oy = tonumber(obj.pos.x), tonumber(obj.pos.y)
    elseif obj.pos_x ~= nil or obj.pos_y ~= nil or obj.posX ~= nil or obj.posY ~= nil then
        ox = tonumber(obj.pos_x or obj.posX)
        oy = tonumber(obj.pos_y or obj.posY)
    else
        -- GetObjectList wrappers normally expose x/y in pixels as well. Do
        -- not guess that small pixel values are tile coordinates: that made
        -- drops near the origin appear to be hundreds of tiles away.
        ox, oy = tonumber(obj.x), tonumber(obj.y)
    end
    if not ox or not oy or not objectId or not itemId then return nil end
    local tx, ty = math.floor(ox / 32), math.floor(oy / 32)
    return itemId, objectId, ox, oy, tx, ty
end

local function ObjectsNearBox(db)
    local found = {}
    if not db or type(db) ~= "table" or (tonumber(db.x) or 0) == 0 and (tonumber(db.y) or 0) == 0 then
        return found
    end
    local objects = ReadWorldObjects()
    if not objects then return found end
    -- Use the configured TILE as the anchor, but allow a half-tile overlap
    -- on every edge. Dropped lock sprites can visually sit half inside a box
    -- while the object's reported position lands just across the tile edge.
    -- This remains tightly scoped to the configured box area; it is not a
    -- world-wide pickup scan. Premium Proxy reports obj.pos.x/y in pixels.
    local boxX, boxY = tonumber(db.x), tonumber(db.y)
    local minX, maxX = boxX * 32 - 16, (boxX + 1) * 32 + 16
    local minY, maxY = boxY * 32 - 16, (boxY + 1) * 32 + 16
    for _, obj in pairs(objects) do
        local itemId, objectId, ox, oy, tx, ty = ObjectDetails(obj)
        if objectId and itemId and LOCK_ITEM_IDS[itemId]
            and ox >= minX and ox <= maxX
            and oy >= minY and oy <= maxY then
            found[#found + 1] = { oid = objectId, itemid = itemId, x = ox, y = oy, tx = tx, ty = ty }
        end
    end
    return found
end

HostAutoCollectLast = HostAutoCollectLast or 0
local hostSetupBusy = false
function CollectFromDisplayBoxes()
    if not Session.active or Session.onHold or payoutBusy or deskBusy or hostSetupBusy then return false end
    -- 1R uses only box 1; box 2 is included only during an active 2R session.
    local boxes = { Positions.displayBox }
    if Session.is2R then boxes[#boxes + 1] = Positions.displayBox2 end

    local seen, collectedAny = {}, false
    -- Re-scan a few times because the object list may update after the first
    -- pickup packet. Every pass remains strictly limited to configured boxes.
    for pass = 1, 3 do
        local foundThisPass = false
        for _, db in ipairs(boxes) do
            for _, obj in ipairs(ObjectsNearBox(db)) do
                if not seen[obj.oid] then
                    seen[obj.oid] = true
                    foundThisPass = true
                    if type(SendPacketRaw) == "function" then
                        local ok, result = pcall(SendPacketRaw, false, {
                            type = 11, value = obj.oid, x = obj.x, y = obj.y
                        })
                        if ok and result ~= false then collectedAny = true end
                        if Sleep then Sleep(250) end
                    end
                end
            end
        end
        if not foundThisPass then break end
        if pass < 3 and Sleep then Sleep(200) end
    end
    -- Deliberately no Collect(3): no global pickup is used.
    return collectedAny
end

RunThread(function()
    while true do
        nap(500)
        if Guard() and Session.active and not Session.onHold and not (payoutBusy or deskBusy or hostSetupBusy) then
            local now = (os and os.clock and os.clock()) or os.time()
            if now - HostAutoCollectLast >= 1.0 then
                HostAutoCollectLast = now
                CollectFromDisplayBoxes()
            end
        end
    end
end)

local function LampPunchWait() return tonumber(Config.Opt.dLampPunch) or 150 end
local function LampGapWait() return tonumber(Config.Opt.dLampGap) or 350 end

local function DeskLock()
    local g = 0
    while deskBusy and g < 100 do nap(100) g = g + 1 end
    if deskBusy then return false end
    deskBusy = true
    return true
end

local function RunDesk()
    WaitPayout()
    if not DeskLock() then return end
    local ok, err = pcall(function()
        for _ = 1, 3 do
            local g, w1, w2 = Session.gateWant, Session.want1, Session.want2
            local needG = g ~= nil and lampValid(Positions.doorGate) and Session.gateOpen ~= g
            local need1 = w1 ~= nil and lampValid(Positions.lamp1) and Session.lamp1On ~= w1
            local need2 = w2 ~= nil and lampValid(Positions.lamp2) and Session.lamp2On ~= w2
            if not (needG or need1 or need2) then break end
            if needG then
                local gx, gy = Positions.doorGate.x, Positions.doorGate.y
                -- Interact from the stand spot; do not teleport to desk/box/gate.
                nap(150)
                PunchDirect(gx, gy)
                Session.gateOpen = g
                nap(350)
            end
            if need1 or need2 then AtDisplayBox() end
            if need1 then
                nap(LampPunchWait())
                PunchDirect(Positions.lamp1.x, Positions.lamp1.y)
                nap(LampGapWait())
                Session.lamp1On = w1
                Session.lamp1Live = w1
            end
            if need2 then
                nap(LampPunchWait())
                PunchDirect(Positions.lamp2.x, Positions.lamp2.y)
                nap(LampGapWait())
                Session.lamp2On = w2
                Session.lamp2Live = w2
            end
        end
    end)
    deskBusy = false
    if not ok then logMsg("`4Lamp error: `w" .. tostring(err)) end
end

local function ForceGate()
    if not lampValid(Positions.doorGate) then return end
    if not DeskLock() then return end
    local ok, err = pcall(function()
        local gx, gy = Positions.doorGate.x, Positions.doorGate.y
        -- Keep the host at the stand spot; no gate/display-box teleport.
        nap(150)
        PunchDirect(gx, gy)
        Session.gateOpen = not Session.gateOpen
        Session.gateWant = Session.gateOpen
        nap(300)
    end)
    deskBusy = false
    if not ok then logMsg("`4Gate error: `w" .. tostring(err)) end
end

local function ToggleGate(open)
    if not lampValid(Positions.doorGate) then return end
    Session.gateWant = open and true or false
    RunThread(RunDesk)
end

local function SetLamps(on1, on2)
    Session.want1, Session.want2 = on1, on2
    RunDesk()
end

local function OpenLamps()
    SetLamps(true, Session.is2R and true or false)
end

local function CloseLamps()
    Session.lampsReady = false
    Session.lamp1Live = false
    Session.lamp2Live = false
    SetLamps(false, false)
end

local function OutcomeLamp1Only()
    CloseLamps()
end

local function DoublePunch(pos)
    nap(LampPunchWait() + 200)
    PunchDirect(pos.x, pos.y)
    nap(LampGapWait() + 50)
    PunchDirect(pos.x, pos.y)
end

local function ResetTieLamps()
    if not DeskLock() then return end
    local ok, err = pcall(function()
        AtDisplayBox()
        if lampValid(Positions.lamp1) then DoublePunch(Positions.lamp1) end
        if Session.is2R and lampValid(Positions.lamp2) then DoublePunch(Positions.lamp2) end
    end)
    deskBusy = false
    if not ok then logMsg("`4Lamp error: `w" .. tostring(err)) end
end

local function CollectItems(x, y)
    -- The callback is used for the configured display boxes only. Do not use
    -- the proxy's global Collect(3), which can pick up items anywhere nearby.
    RunThread(function()
        CollectFromDisplayBoxes()
    end)
end

local function countItem(id)
    if not GetInventory then return 0 end
    for _, inv in pairs(GetInventory()) do
        if inv.id == id then return inv.amount or inv.count or 0 end
    end
    return 0
end

local function getSlot(id)
    if not GetInventory then return nil end
    for _, inv in pairs(GetInventory()) do
        if inv.id == id then return inv.slot or inv.index or 0 end
    end
    return nil
end

local function GetTotalWealth()
    return countItem(242) + (countItem(1796) * 100) + (countItem(7188) * 10000) + (countItem(11550) * 1000000)
end

local function FormatLockAmount(wl)
    wl = math.max(0, math.floor(tonumber(wl) or 0))
    local black = math.floor(wl / 1000000); wl = wl % 1000000
    local bgl = math.floor(wl / 10000); wl = wl % 10000
    local dl = math.floor(wl / 100); wl = wl % 100
    local parts = {}
    if black > 0 then parts[#parts + 1] = black .. " Black" end
    if bgl > 0 then parts[#parts + 1] = bgl .. " BGL" end
    if dl > 0 then parts[#parts + 1] = dl .. " DL" end
    if wl > 0 or #parts == 0 then parts[#parts + 1] = wl .. " WL" end
    return table.concat(parts, " ")
end

local function FormatWinMessage(amount)
    local template = tostring(Config.WinMessage or "`2You won %s!")
    local formatted = FormatLockAmount(amount)
    local out, count = template:gsub("%%d%s*WL", formatted, 1)
    if count == 0 then out, count = template:gsub("%%s", formatted, 1) end
    if count == 0 then out = template:gsub("%%d", tostring(math.floor(tonumber(amount) or 0)), 1) end
    return out
end

function FaceDropDirection()
    -- Direction applies to the actual local player, not the console UI.
    local dir = (Config.DropDirection or "right"):lower() == "left" and -1 or 1
    local me = GetLocal and GetLocal() or nil
    if me and me.pos and SendPacketRaw then
        local state = dir < 0 and 0x100 or 0
        pcall(SendPacketRaw, false, { type = 0, x = me.pos.x, y = me.pos.y, state = state })
    end
end

local function dropItem(id, amt)
    FaceDropDirection()
    SendPacket(2, "action|dialog_return\ndialog_name|drop\nitem_drop|" .. id .. "|\nitem_count|" .. amt)
end

local PHONE_TILE_ID = 3898
local PHONE_NUMBER = "53785"
local LOCK_IDS = { 242, 1796, 7188, 11550 }
local LOCK_UNIT = { 1, 100, 10000, 1000000 }

local convLock = false
local phoneBusy = false
local phoneWarned = false

function FindNearestPhone()
    local tiles = GetTiles and GetTiles() or nil
    if not tiles then return nil end
    local mx, my = GetMyPos()
    local best, bestD = nil, math.huge
    for _, tile in pairs(tiles) do
        if tile and tonumber(tile.fg) == PHONE_TILE_ID then
            local d = math.abs((tonumber(tile.x) or 0) - mx) + math.abs((tonumber(tile.y) or 0) - my)
            if d < bestD then best, bestD = tile, d end
        end
    end
    return best
end

local function wait(ms) if Sleep then Sleep(ms) end end

local function HostWait(ms)
    ms = tonumber(ms) or 0
    if ms > 0 and Sleep then Sleep(ms) end
end

local function ApplyModfly()
    if Config.Opt.modfly and ChangeValue then
        pcall(ChangeValue, "[C] Modfly", Session.active and true or false)
    end
end

local function lockCount(lv) return countItem(LOCK_IDS[lv]) end

local function acquireConv()
    local guard = 0
    while convLock and guard < 200 do wait(100) guard = guard + 1 end
    convLock = true
end
local function releaseConv() convLock = false end

local function waitCount(lv, before, wantMore)
    for _ = 1, 30 do
        wait(150)
        local now = lockCount(lv)
        if (wantMore and now > before) or (not wantMore and now < before) then return true end
    end
    return false
end

local function BreakOne(lv)
    if lv < 2 or lv > 4 or lockCount(lv) < 1 then return false end
    local before = lockCount(lv - 1)
    if lv == 4 then
        SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
    else
        SendPacketRaw(false, { type = 10, value = LOCK_IDS[lv] })
    end
    return waitCount(lv - 1, before, true)
end

local function UpOne(lv)
    if lv < 1 or lv > 3 or lockCount(lv) < 100 then return false end
    local before = lockCount(lv + 1)
    if lv == 1 then
        SendPacketRaw(false, { type = 10, value = LOCK_IDS[1] })
    elseif lv == 2 then
        local tile = FindNearestPhone()
        local found = false
        if tile then
            phoneBusy = true
            -- Use the nearest telephone without moving the host to it.
            SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|" .. tostring(Config.Conv.phone or "53785") ..
                "|\nx|" .. tile.x .. "|\ny|" .. tile.y .. "|\nbuttonClicked|bglconvert")
            found = true
        end
        if not found then
            if not phoneWarned then
                phoneWarned = true
                logMsg("`4No Telephone in this world, cannot convert DL to BGL")
            end
            return false
        end
    else
        SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
    end
    local ok = waitCount(lv + 1, before, true)
    phoneBusy = false
    return ok
end

AddHook("onvariant", "HIDE_PHONE_DIALOG", function(var)
    if not Guard() then return false end
    if phoneBusy and Config.Conv.hidePhone and var and var[0] == "OnDialogRequest" and var[1] then
        local d = tostring(var[1]):lower()
        if d:find("telephone") or d:find("phone") then return true end
    end
    return false
end)

local function EnsureFunds(needs)
    local function surplus(lv) return lockCount(lv) - (needs[lv] or 0) end
    for lv = 4, 1, -1 do
        local guard = 0
        while lockCount(lv) < (needs[lv] or 0) and guard < 10 do
            guard = guard + 1
            local src = nil
            for h = lv + 1, 4 do
                if surplus(h) >= 1 then
                    local allowed = Config.Conv.shatter
                    for l = lv + 1, h do
                        if not Config.Conv["sh" .. l] then allowed = false end
                    end
                    if allowed then src = h end
                    break
                end
            end
            if src then
                for l = src, lv + 1, -1 do
                    if not BreakOne(l) then return false end
                end
            elseif lv > 1 and surplus(lv - 1) >= 100 and Config.Conv["up" .. (lv - 1)] then
                if not UpOne(lv - 1) then return false end
            else
                return false
            end
        end
        if lockCount(lv) < (needs[lv] or 0) then return false end
    end
    return true
end

local function ConvertRound()
    acquireConv()
    Session.convertTime = os.time()
    for lv = 3, 1, -1 do
        if Config.Conv["up" .. lv] then
            local times = tonumber(Config.Conv["n" .. lv]) or 3
            local keep = tonumber(Config.Conv["keep" .. lv]) or 0
            for _ = 1, times do
                if lockCount(lv) - keep < 100 then break end
                if not UpOne(lv) then break end
                Session.convertTime = os.time()
                wait(tonumber(Config.Conv.delay) or 300)
            end
        end
    end
    releaseConv()
end

local function AutoConvertAfterBet()
    if Config.Conv.auto and Config.Conv.afterBet then ConvertRound() end
end

local function QuickConvert()
    if not (Config.Conv.auto and Config.Conv.afterBet) or Session.quickConv then return end
    Session.quickConv = true
    RunThread(function()
        if Sleep then Sleep(250) end
        ConvertRound()
        Session.quickConv = false
    end)
end

local function ShatterNow(lv)
    RunThread(function()
        acquireConv()
        local ok = BreakOne(lv)
        releaseConv()
        logMsg(ok and "`2Shattered 1 lock" or "`4Could not shatter (none left?)")
    end)
end

local function ConvertNow(lv)
    RunThread(function()
        acquireConv()
        local ok = UpOne(lv)
        releaseConv()
        logMsg(ok and "`2Converted 100 locks" or "`4Could not convert (need 100 locks, and a telephone for DL)")
    end)
end

RunThread(function()
    while true do
        wait(5000)
        if Config.Conv.auto and Config.Conv.idle and not convLock then
            local idle = (Session.step == "IDLE") and not Session.active and Session.playerName == nil
            if idle then ConvertRound() end
        end
    end
end)

local function RefundBet(items, reasonMsg)
    sendInstant(reasonMsg or MsgT("refund"))
    RunThread(function()
        if Positions.dropSpot and Positions.dropSpot.x ~= 0 and Positions.dropSpot.y ~= 0 then
            MoveTo(Positions.dropSpot.x, Positions.dropSpot.y)
            if Sleep then Sleep(150) end
        end
        local needs = { 0, 0, 0, 0 }
        local levelOf = { [242] = 1, [1796] = 2, [7188] = 3, [11550] = 4 }
        for _, item in pairs(items) do
            local lv = levelOf[item.id]
            if lv then needs[lv] = needs[lv] + item.amount end
        end
        acquireConv()
        local ready = EnsureFunds(needs)
        if not ready then
            releaseConv()
            ReturnToStandSpot()
            logMsg("`4Refund paused: could not safely restore the required locks. Check inventory/conversion settings.")
            AddHostLog("BUG", "Refund aborted because EnsureFunds could not restore the exact bet items")
            return
        end
        for _, item in pairs(items) do
            local rem = math.min(tonumber(item.amount) or 0, countItem(item.id))
            while rem > 0 do
                local cur = math.min(rem, 250)
                dropItem(item.id, cur)
                if Sleep then Sleep(300) end
                rem = rem - cur
            end
        end
        releaseConv()
        ReturnToStandSpot()
    end)
end

local BankWithdraw

local function DropPayout(val)
    RunThread(function()
        payoutBusy = true
        local okP, errP = pcall(function()
            if Positions.dropSpot and Positions.dropSpot.x ~= 0 and Positions.dropSpot.y ~= 0 then
                MoveTo(Positions.dropSpot.x, Positions.dropSpot.y)
                if Sleep then Sleep(150) end
            end

            local rem = val
            local needs = {}
            needs[4] = math.floor(rem / 1000000) rem = rem % 1000000
            needs[3] = math.floor(rem / 10000)   rem = rem % 10000
            needs[2] = math.floor(rem / 100)     rem = rem % 100
            needs[1] = rem

            acquireConv()
            local ready = EnsureFunds(needs)
            releaseConv()
            -- If inventory cannot cover the payout, request enough BGL from the bank,
            -- verify it actually arrived, then prepare the exact denomination mix again.
            if not ready and BankWithdraw then
                local missingWL = math.max(0, val - GetTotalWealth())
                local bankNeed = math.ceil(missingWL / 10000)
                if bankNeed > 0 then
                    local beforeBGL = lockCount(3)
                    if BankWithdraw(bankNeed) and waitCount(3, beforeBGL, true) then
                        acquireConv()
                        ready = EnsureFunds(needs)
                        releaseConv()
                    end
                end
            end

            local function dropAmount(id, amount)
                while amount > 0 do
                    local c = math.min(amount, 250)
                    dropItem(id, c)
                    if Sleep then Sleep(300) end
                    amount = amount - c
                end
            end

            if ready then
                dropAmount(LOCK_IDS[4], needs[4])
                dropAmount(LOCK_IDS[3], needs[3])
                dropAmount(LOCK_IDS[2], needs[2])
                dropAmount(LOCK_IDS[1], needs[1])
            else
                logMsg("`4Payout blocked: exact funds are unavailable. Check inventory and bank balance.")
                AddHostLog("BUG", "Payout of " .. val .. " WL blocked; exact funds unavailable after bank withdrawal attempt")
            end

            ReturnToStandSpot()
        end)
        payoutBusy = false
        if not okP then logMsg("`4Payout error: `w" .. tostring(errP)) end
    end)
end

local function DropNeeds(needs)
    RunThread(function()
        acquireConv()
        local ok = EnsureFunds(needs)
        releaseConv()
        if not ok then
            logMsg("`4Not enough locks to drop that")
            return
        end
        for lv = 4, 1, -1 do
            local n = needs[lv] or 0
            while n > 0 do
                local c = math.min(n, 250)
                dropItem(LOCK_IDS[lv], c)
                if Sleep then Sleep(300) end
                n = n - c
            end
        end
    end)
end

local function SplitWL(v)
    local needs = {}
    needs[4] = math.floor(v / 1000000) v = v % 1000000
    needs[3] = math.floor(v / 10000)   v = v % 10000
    needs[2] = math.floor(v / 100)     v = v % 100
    needs[1] = v
    return needs
end

local function PlaceDirect(x, y, id)
    if not x or not y or (x == 0 and y == 0) or not id or id == 0 then return end
    local me = GetLocal and GetLocal() or nil
    if me and me.pos and SendPacketRaw then
        SendPacketRaw(false, { type = 3, x = me.pos.x, y = me.pos.y, px = x, py = y, value = id, state = 16 })
    end
end

local function TileFg(x, y)
    if GetTile then
        local t = GetTile(x, y)
        if t then return t.fg or 0 end
    end
    if GetTiles then
        for _, t in pairs(GetTiles()) do
            if t.x == x and t.y == y then return t.fg or 0 end
        end
    end
    return nil
end

local function HeldItemId()
    local me = GetLocal and GetLocal() or nil
    if not me then return nil end
    for _, k in ipairs({ "hand", "item", "hand_item", "handItem", "held", "heldItem", "tool" }) do
        if type(me[k]) == "number" and me[k] > 0 then return me[k] end
    end
    return nil
end

local function EnsureLamps()
    local L = Config.Lamp
    local id = tonumber(L.id) or 0
    if not L.auto or id <= 0 then return end
    if not DeskLock() then return end
    local ok, err = pcall(function()
        for _ = 1, 3 do
            local miss1 = lampValid(Positions.lamp1) and TileFg(Positions.lamp1.x, Positions.lamp1.y) == 0
            local miss2 = Session.is2R and lampValid(Positions.lamp2) and TileFg(Positions.lamp2.x, Positions.lamp2.y) == 0
            if not miss1 and not miss2 then break end
            AtDisplayBox()
            if miss1 then
                nap(LampPunchWait() + 50)
                PlaceDirect(Positions.lamp1.x, Positions.lamp1.y, id)
                Session.lamp1On = false
                Session.lamp1Live = false
                nap(LampGapWait() + 150)
                logMsg("`2Lamp 1 placed again")
            end
            if miss2 then
                nap(LampPunchWait() + 50)
                PlaceDirect(Positions.lamp2.x, Positions.lamp2.y, id)
                Session.lamp2On = false
                Session.lamp2Live = false
                nap(LampGapWait() + 150)
                logMsg("`2Lamp 2 placed again")
            end
        end
    end)
    deskBusy = false
    if not ok then logMsg("`4Lamp error: `w" .. tostring(err)) end
end

local function InvSnapshot()
    local t = {}
    for _, it in pairs(GetInventory and GetInventory() or {}) do t[it.id] = it.amount end
    return t
end

local CHAMP_SOON = true
local function BuyAndUseChampagne()
    if CHAMP_SOON then return end
    if Session.champBusy then return end
    Session.champBusy = true
    RunThread(function()
        local C = Config.Champ
        acquireConv()
        local ok = EnsureFunds({ 0, tonumber(C.cost) or 10, 0, 0 })
        local phone = FindNearestPhone()
        local px, py = phone and phone.x, phone and phone.y
        if not ok then
            logMsg("`4Not enough DL for champagne")
        elseif not px then
            logMsg("`4No telephone in this world")
        else
            local before = InvSnapshot()
            phoneBusy = true
            SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|" .. tostring(Config.Conv.phone or "53785") ..
                "|\nx|" .. px .. "|\ny|" .. py .. "|\nbuttonClicked|" .. tostring(C.button))
            wait(1500)
            phoneBusy = false
            local cid = tonumber(C.id) or 17062
            local have = InvSnapshot()[cid] or 0
            if have > (before[cid] or 0) then

                local me = GetLocal and GetLocal() or nil
                if me and me.pos and SendPacketRaw then
                    local tx, ty = math.floor(me.pos.x / 32), math.floor(me.pos.y / 32)
                    SendPacketRaw(false, { type = 3, x = me.pos.x, y = me.pos.y, px = tx, py = ty, value = cid, state = 16 })
                end
                wait(700)
                if (InvSnapshot()[cid] or 0) >= have then
                    SendPacketRaw(false, { type = 10, value = cid })
                end
                logMsg("`2Champagne used")
                AddHostLog("BUY", "Champagne bought and used `7(" .. tostring(C.cost) .. " DL)")
            else
                logMsg("`4Champagne did not arrive. Check the button name on the Champagne page")
            end
        end
        releaseConv()
        Session.champBusy = false
    end)
end

local function KickPlayer(netid)
    if not netid then return end
    SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. tostring(netid) .. "|\nbuttonClicked|kick")
end

local function BanPlayer(netid)
    if not netid then return end
    SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. tostring(netid) .. "|\nbuttonClicked|world_ban")
end

local function PullPlayer(netid)
    if not netid then return end
    SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. tostring(netid) .. "|\nbuttonClicked|pull")
end

local function BankDeposit(n)
    n = math.floor(tonumber(n) or 0)
    if n < 1 then return false end
    SendPacket(2, "action|dialog_return\ndialog_name|bank_deposit\nbgl_count|" .. n)
    return true
end

BankWithdraw = function(n)
    n = math.floor(tonumber(n) or 0)
    if n < 1 then return false end
    SendPacket(2, "action|dialog_return\ndialog_name|bank_withdraw\nbgl_count|" .. n)
    return true
end

RunThread(function()
    local pause = 0
    while true do
        if Sleep then Sleep(5000) else break end
        local B = Config.Bank
        if pause > 0 then
            pause = pause - 5
        elseif B and (B.on or B.wdOn) and not convLock then
            local safe = (not Session.active) or Session.step == "WAITING_BET"

            local low = math.floor(tonumber(B.wdBelow) or 0)
            local take = math.floor(tonumber(B.wdAmount) or 0)
            local nowHave = lockCount(3)
            local wouldDeposit = B.on and (nowHave + take) >= (tonumber(B.trigger) or 0)
            if B.wdOn and safe and take > 0 and nowHave < low and not wouldDeposit then
                acquireConv()
                local beforeWd = lockCount(3)
                if BankWithdraw(take) then
                    if waitCount(3, beforeWd, true) then
                        logMsg("`2Took `e" .. take .. " BGL `2out of the bank")
                        AddHostLog("BANK", "Withdrew `e" .. take .. " BGL `7(had " .. beforeWd .. ")")
                    else
                        logMsg("`4Bank withdraw did not go through. Trying again in 30 sec")
                        pause = 30
                    end
                end
                releaseConv()
            end
            local have = lockCount(3)
            local amount = math.floor(tonumber(B.amount) or 0)
            if B.on and safe and amount > 0 and have >= (tonumber(B.trigger) or 0) and have > 0 then
                acquireConv()
                local before = lockCount(3)
                local n = math.min(amount, before)
                if BankDeposit(n) then
                    if waitCount(3, before, false) then
                        logMsg("`2Banked `e" .. n .. " BGL")
                        AddHostLog("BANK", "Deposited `e" .. n .. " BGL `7(had " .. before .. ")")
                    else
                        logMsg("`4Bank deposit did not go through. Trying again in 30 sec")
                        pause = 30
                    end
                end
                releaseConv()
            end
        end
    end
end)

local SBRun = { count = 0 }

RunThread(function()
    while true do
        if Sleep then Sleep(1000) else break end
        local C = Config.SB
        if C and C.on then
            local playing = Session.active or (Session.playerName ~= nil)
            if C.text == "" then
                C.on = false
                logMsg("`4Auto SB stopped: the message is empty")
            elseif not (C.idleOnly and playing) then
                if SBRun.count >= C.total then
                    C.on = false
                    SaveConfigToFile()
                    logMsg("`2Auto SB finished `w[ " .. SBRun.count .. " / " .. C.total .. " ]")
                else
                    SendPacket(2, "action|input\ntext|/sb " .. C.text)
                    SBRun.count = SBRun.count + 1
                    logMsg("`5SB sent `w[ " .. SBRun.count .. " / " .. C.total .. " ]")
                    for _ = 1, C.delay do
                        if Sleep then Sleep(1000) end
                        if not Config.SB.on then break end
                    end
                end
            end
        end
    end
end)

local M = {}
local SecArm = nil

local function mResetBtn(name)
    return "add_button|btn_reset_sec|" .. (SecArm == name and "`4Click again to reset this page" or "`4Reset this page") .. "|noflags|0|\n"
end

local function copyKeys(dst, src, keys)
    for _, k in ipairs(keys) do dst[k] = src[k] end
end

local function copyAll(dst, src)
    for k, v in pairs(src) do dst[k] = v end
end

local SECRESET = {
    temp_gameset_menu = { name = "Game Modes", show = "modes", reset = function()
        copyKeys(Config, BASE_DEFAULTS, { "EnableReme", "EnableQeme", "EnableLeme", "Enable1R", "Enable2R", "TriggerReme", "TriggerQeme", "TriggerLeme", "Trigger2R", "Trigger1R", "TriggerExit" })
        Config.Msg = Config.Msg or {}
        Config.Msg.exitok = MSG_DEFAULTS.exitok
    end },
    temp_limits_menu = { name = "Bet Limits", show = "bets", reset = function()
        copyKeys(Config, BASE_DEFAULTS, { "MinBet", "MaxBet" })
    end },
    temp_msgs_menu = { name = "Messages", show = "texts", reset = function()
        copyAll(Config.Msg, MSG_DEFAULTS)
        Config.Opt.talk = true
        copyKeys(Config, BASE_DEFAULTS, { "WinMessage", "LoseMessage", "DropBetMessage" })
    end },
    temp_timers_menu = { name = "Timers", show = "timers", reset = function()
        copyKeys(Config.Opt, OPT_DEFAULTS, { "betTime", "spinTime", "spin2Time", "respinTime", "rejoin", "warn10" })
        copyAll(Config.Opt, TIMER_PRESETS.normal)
    end },
    temp_rules_menu = { name = "Game Rules", show = "rules", reset = function()
        copyKeys(Config.Opt, OPT_DEFAULTS, { "ruleOutside", "ruleLemeOut", "ruleLamp", "ruleMulti", "ruleDropDuringSpin", "spinRange", "bubble", "fastWheel", "banFake" })
    end },
    temp_conv_menu = { name = "Lock Convert", show = "convert", reset = function() copyAll(Config.Conv, CONV_DEFAULTS) end },
    temp_bank_menu = { name = "Auto Bank", show = "bank", reset = function() copyAll(Config.Bank, BANK_DEFAULTS) end },
    temp_spam_menu = { name = "Auto Spam", show = "spam", reset = function()
        copyKeys(Config, BASE_DEFAULTS, { "SpamMessage", "AutoSpam", "SpamDelay", "SpamRainbow", "SpamRandomColor", "SpamIdleOnly" })
    end },
    temp_sb_menu = { name = "SB Sender", show = "sb", reset = function() copyAll(Config.SB, SB_DEFAULTS) end },
    temp_hostopts_menu = { name = "Host Options", show = "hostopts", reset = function()
        copyKeys(Config.Opt, OPT_DEFAULTS, { "kickShadow", "modfly" })
    end },
    temp_lamp_menu = { name = "Lamps", show = "lamp", reset = function() copyAll(Config.Lamp, LAMP_DEFAULTS) end },
}

local ResetArm = nil
local LastSec = nil
local CalcState = { expr = "", wl = "", result = nil, err = nil }

local function pad(text)
    local visible = text:gsub("`.", "")
    local n = 8 - #visible
    if n <= 0 then return text end
    local left = math.floor(n / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", n - left)
end

local C_TITLE, C_SEC = "`9", "`8"

local function mHeader(title, icon)
    local t = title:gsub("^`%w", "")
    return "add_label_with_icon|small|" .. C_TITLE .. t .. "|left|" .. icon .. "|\n"
end

local function mDiscord()
    return "add_spacer|small|\nadd_smalltext|`wDiscord: `9" .. DISCORD_LINK .. "|\n"
end

local function mFooter(kind)
    local f = "add_spacer|small|\n"
    local ids = { sec = "btn_back_sec", main = "btn_back_main", set = "btn_back_set" }
    if kind and ids[kind] then f = f .. "add_button|" .. ids[kind] .. "|`w" .. T("back") .. "|noflags|0|\n" end
    return f .. "add_button|btn_close_panel|`4" .. T("close") .. "|noflags|0|\n" .. mDiscord()
end

local function mGrid(items)
    local out = ""
    for i, it in ipairs(items) do
        out = out .. "add_button_with_icon|" .. it[1] .. "|" .. pad(it[2]) .. "|staticBlueFrame|" .. it[3] .. "||\n"
        if i % 4 == 0 or i == #items then
            out = out .. "add_button_with_icon||END_LIST|noflags|0||\n"
        end
    end
    return out
end

local PAGE_THEME = {
    temp_main_menu = { "`9", "`8" },
    temp_gameset_menu = { "`9", "`3" }, temp_limits_menu = { "`9", "`3" }, temp_pos_menu = { "`9", "`3" },
    temp_rules_menu = { "`9", "`3" }, temp_timers_menu = { "`9", "`3" }, temp_hostopts_menu = { "`9", "`3" },
    temp_conv_menu = { "`2", "`e" }, temp_bank_menu = { "`2", "`e" }, temp_drop_menu = { "`2", "`e" }, temp_calc_menu = { "`2", "`e" },
    temp_spam_menu = { "`b", "`p" }, temp_sb_menu = { "`b", "`p" }, temp_lamp_menu = { "`b", "`p" }, temp_msgs_menu = { "`b", "`p" },
    temp_logs_menu = { "`3", "`8" }, temp_sublog_menu = { "`3", "`8" },
    temp_ctrl_menu = { "`8", "`2" },
    temp_set_menu = { "`c", "`b" }, temp_prof_menu = { "`c", "`b" }, temp_backup_menu = { "`c", "`b" }, temp_lang_menu = { "`c", "`b" },
    temp_cmd_menu = { "`e", "`5" }, temp_help_menu = { "`e", "`5" },
    temp_dev_menu = { "`4", "`e" }, temp_devbugs_menu = { "`4", "`e" },
}

local function mSend(body, name, theme)
    local th = theme or PAGE_THEME[name]
    if th then
        body = body:gsub("add_label_with_icon|small|`9", "add_label_with_icon|small|" .. th[1], 1)
        body = body:gsub("add_label_with_icon|small|`8", "add_label_with_icon|small|" .. th[2])
    end
    SendVariantList({ [0] = "OnDialogRequest", [1] = body .. "end_dialog|" .. name .. "|||\n" })
end

local function mCheck(id, label, on)
    return "add_checkbox|" .. id .. "|" .. label .. "|" .. (on and "1" or "0") .. "|\n"
end

local function mInput(id, label, value, len)
    return "add_text_input|" .. id .. "|" .. label .. "|" .. tostring(value or "") .. "|" .. (len or 40) .. "|\n"
end

local function mLine(cmd, text)
    return "add_smalltext|`3" .. cmd .. "  `7" .. text .. "|\n"
end

local function mNote(text)
    return "add_smalltext|`7" .. text .. "|\n"
end

local function mSection(title, icon, items)
    local themes = { setup = { "`9", "`3" }, locks = { "`2", "`e" }, auto = { "`b", "`p" }, tools = { "`5", "`9" } }
    local key = (icon == 758 and "setup") or (icon == 11550 and "locks") or (icon == 3898 and "auto") or "tools"
    mSend(mHeader("`w" .. title, icon) .. mGrid(items) .. mFooter("main"), "temp_sec_menu", themes[key])
end

function M.main()
    local me = GetLocal and GetLocal() or nil
    local name = me and cleanText(me.name or "Host") or "Host"
    local uid = me and (me.userid or me.userID) or "?"
    local pl = HostLogs.totalProfitLoss
    local status
    if Session.active then
        status = "`2" .. T("playing") .. ": `w" .. cleanText(Session.playerName or "?") .. (Session.onHold and " `4(" .. T("paused") .. ")" or "")
    else
        status = "`2" .. T("ready")
    end
    local body =
        mHeader(T("welcome") .. ", `2" .. name, 758) ..
        "add_smalltext|`wUID `b" .. tostring(uid) .. "   `wDate `b" .. os.date("%d/%m/%Y") .. "   `wTime `b" .. os.date("%H:%M") .. "|\n" ..
        "add_smalltext|`w" .. T("profit") .. ": " .. (pl >= 0 and "`2+" or "`4") .. pl .. " WL|\n" ..
        "add_smalltext|" .. status .. "   `w" .. T("games") .. " `b" .. HostLogs.totalGames .. "  `w" .. T("wins") .. " `2" ..
            HostLogs.totalWins .. "  `w" .. T("losses") .. " `4" .. HostLogs.totalLosses .. "|\n" ..
        "add_spacer|small|\n" ..
        mGrid({
            { "btn_nav_cmd",  "`b" .. T("commands"), 20 },
            { "btn_nav_set",  "`8" .. T("settings"), 32 },
            { "btn_nav_help", "`3" .. T("info"),     20 },
        }) ..
        "add_label_with_icon|small|" .. C_SEC .. T("features") .. "|left|758|\n" ..
        mGrid((function()
            local tiles = {
                { "btn_sec_setup", "`9" .. T("setup"), 758 },
                { "btn_sec_locks", "`2" .. T("locks"), 11550 },
                { "btn_sec_auto",  "`b" .. T("auto"),  3898 },
                { "btn_sec_tools", "`5" .. T("tools"), 112 },
                { "btn_nav_logs",  "`3" .. T("logs"),  112 },
                { "btn_nav_ctrl",  "`8" .. T("controls"), 18 },
            }
            if IsDev() then tiles[#tiles + 1] = { "btn_nav_dev", "`4Dev Menu", 32 } end
            return tiles
        end)()) ..
        "add_spacer|small|\n" ..
        "add_button|btn_close_panel|`4" .. T("close") .. "|noflags|0|\n" ..
        mDiscord()
    mSend(body, "temp_main_menu")
end

function M.setup()
    mSection(T("setup"), 758, {
        { "btn_nav_gameset", "`w" .. T("modes"),    758 },
        { "btn_nav_limits",  "`w" .. T("bets"),     242 },
        { "btn_nav_pos",     "`w" .. T("spots"),    6 },
        { "btn_nav_msgs",    "`w" .. T("messages"), 20 },
        { "btn_nav_timers",  "`w" .. T("timers"),   112 },
        { "btn_nav_rules",   "`w" .. T("rules"),    4 },
        { "btn_nav_hostopts", "`w" .. T("hostopts"), 18 },
    })
end

function M.locks()
    mSection(T("locks"), 11550, {
        { "btn_nav_conv", "`w" .. T("convert"), 11550 },
        { "btn_nav_bank", "`w" .. T("bank"),    7188 },
        { "btn_nav_drop", "`w" .. T("drop"),    242 },
    })
end

function M.auto()
    mSection(T("auto"), 3898, {
        { "btn_nav_spam",  "`w" .. T("spam"),  3898 },
        { "btn_nav_sb",    "`w" .. T("sb"),    2480 },
        { "btn_nav_lamp",  "`w" .. T("lamp"),  32 },
        { "btn_nav_champ", "`4" .. T("champ") .. " [SOON]", tonumber(Config.Champ.id) or 17062 },
    })
end

function M.tools()
    mSection(T("tools"), 112, {
        { "btn_nav_calc", "`w" .. T("calc"), 112 },
    })
end

function M.logs()
    local body =
        mHeader("`w" .. T("logs"), 112) ..
        "add_smalltext|`w" .. T("games") .. " `6" .. HostLogs.totalGames .. "   `w" .. T("wins") .. " `2" .. HostLogs.totalWins ..
            "   `w" .. T("losses") .. " `4" .. HostLogs.totalLosses .. "|\n" ..
        "add_spacer|small|\n" ..
        mGrid({
            { "view_log_all",     "`wAll Logs",  112 },
            { "view_log_bet",     "`wBet Logs",  242 },
            { "view_log_spin",    "`wSpin Logs", 758 },
            { "view_log_win",     "`2Win Logs",  1796 },
            { "view_log_loss",    "`4Loss Logs", 4 },
            { "view_log_timeout", "`eTimeouts",  6 },
            { "view_log_exit",    "`9Exit Logs", 18 },
            { "view_log_bank",    "`bBank Logs", 7188 },
        }) ..
        "add_spacer|small|\n" ..
        "add_button|btn_clear_logs|`4Clear logs|noflags|0|\n" ..
        mFooter("main")
    mSend(body, "temp_logs_menu")
end

function M.sublog(filterType)
    local logText, count = "", 0
    for _, entry in ipairs(HostLogs.entries) do
        if (filterType == "ALL" and entry.type ~= "BUG") or entry.type == filterType then
            logText = logText .. "add_smalltext|" .. entry.text .. "|\n"
            count = count + 1
        end
    end
    local extra = ""
    if filterType == "TIMEOUT" then extra = "add_smalltext|`wTotal timeouts: `e" .. HostLogs.totalTimeouts .. "|\n" end
    if filterType == "BUG" then extra = "add_smalltext|`wTotal bugs: `4" .. HostLogs.totalBugs .. "|\n" end
    if count == 0 then logText = mNote("Nothing here yet") end
    local body =
        mHeader("`w" .. filterType .. " (" .. count .. ")", 112) ..
        extra .. logText ..
        "add_spacer|small|\n" ..
        "add_button|btn_back_logs|`w" .. T("back") .. "|noflags|0|\n" ..
        "add_button|btn_close_panel|`4" .. T("close") .. "|noflags|0|\n" ..
        mDiscord()
    mSend(body, "temp_sublog_menu")
end

function M.modes()
    local body =
        mHeader("`w" .. T("modes"), 758) ..
        mCheck("chk_reme", "`wReme", Config.EnableReme) ..
        mInput("trig_reme", "Reme word", Config.TriggerReme or "!reme", 20) ..
        mCheck("chk_qeme", "`wQeme", Config.EnableQeme) ..
        mInput("trig_qeme", "Qeme word", Config.TriggerQeme or "!qeme", 20) ..
        mCheck("chk_leme", "`wLeme", Config.EnableLeme) ..
        mInput("trig_leme", "Leme word", Config.TriggerLeme or "!leme", 20) ..
        mCheck("chk_1r", "`w1 Room enabled", Config.Enable1R ~= false) ..
        mCheck("chk_2r", "`w2 Rooms", Config.Enable2R) ..
        mInput("trig_2r", "2R word", Config.Trigger2R or "!2r", 20) ..
        mInput("trig_1r", "1R word", Config.Trigger1R or "!1r", 20) ..
        mInput("drop_direction", "Drop direction (left/right)", Config.DropDirection or "right", 10) ..
        "add_spacer|small|\n" ..
        "add_label_with_icon|small|`8Player exit|left|758|\n" ..
        mInput("mode_exit_cmd", "Exit command", Config.TriggerExit or "!exit", 20) ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_gameset|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_gameset_menu") ..
        mFooter("sec")
    mSend(body, "temp_gameset_menu")
end

local function posLine(label, cmd, pos)
    local set = pos and (pos.x ~= 0 or pos.y ~= 0)
    return "add_smalltext|" .. (set and "`2" or "`4") .. label .. "  `7" .. cmd .. "  `w" ..
        (set and (pos.x .. ", " .. pos.y) or "not set") .. "|\n"
end

function M.spots()
    local body =
        mHeader("`w" .. T("spots"), 6) ..
        posLine("Host wheel 1", "/wheel1", Positions.hostWheel1) ..
        posLine("Host wheel 2", "/wheel2", Positions.hostWheel2) ..
        posLine("Display box 1", "/displaybox", Positions.displayBox) ..
        posLine("Display box 2", "/displaybox2", Positions.displayBox2) ..
        posLine("Stand spot", "/standspot", Positions.standSpot) ..
        posLine("Pull spot", "/pullspot", Positions.pullSpot) ..
        posLine("Drop spot", "/dropspot", Positions.dropSpot) ..
        posLine("Lamp 1", "/lamp1", Positions.lamp1) ..
        posLine("Lamp 2 (2R)", "/lamp2", Positions.lamp2) ..
        posLine("Gate", "/dgate", Positions.doorGate) ..
        mFooter("sec")
    mSend(body, "temp_pos_menu")
end

function M.bets()
    local body =
        mHeader("`w" .. T("bets"), 242) ..
        mInput("input_min_bet", "Min bet", Config.MinBet or 1, 10) ..
        mInput("input_max_bet", "Max bet", Config.MaxBet or 0, 10) ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_limits|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_limits_menu") ..
        mFooter("sec")
    mSend(body, "temp_limits_menu")
end

function M.texts()
    local body =
        mHeader(T("messages"), 20) ..
        mCheck("chk_talk", "`wSay messages while hosting", Config.Opt.talk) ..
        mNote("Leave a message empty to turn only that one off") ..
        "add_label_with_icon|small|`8Game|left|758|\n" ..
        mInput("input_win_msg", "Win (%d = WL)", Config.WinMessage, 60) ..
        mInput("input_lose_msg", "Lose", Config.LoseMessage, 60) ..
        mInput("input_drop_msg", "Drop bet (%s = mode)", Config.DropBetMessage, 60) ..
        "add_spacer|small|\n" ..
        "add_label_with_icon|small|`8Other|left|20|\n"
    for _, it in ipairs(MSG_ORDER) do
        body = body .. mInput("m_" .. it[1], it[2], Config.Msg[it[1]], 120)
    end
    body = body ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_msgs|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_msgs_menu") ..
        mFooter("sec")
    mSend(body, "temp_msgs_menu")
end

function M.timers()
    local O = Config.Opt
    local lowDelays = false
    for k, m in pairs(TIMER_MINS) do
        if (tonumber(O[k]) or 0) < m then lowDelays = true end
    end
    local cur = CurrentPreset()
    local function presetBtn(id, key, label)
        local on = (cur == key)
        return "add_button|" .. id .. "|" .. (on and "`2" or "`w") .. label .. (on and "  [ON]" or "") .. "|noflags|0|\n"
    end
    local body =
        mHeader(T("timers"), 112) ..
        "add_label_with_icon|small|" .. C_SEC .. "Timeouts (sec)|left|6|\n" ..
        mInput("opt_bet", "No bet dropped", O.betTime, 3) ..
        mInput("opt_spin", "No spin, wheel 1", O.spinTime, 3) ..
        mInput("opt_spin2", "No spin, wheel 2", O.spin2Time, 3) ..
        mInput("opt_respin", "No spin after reset", O.respinTime, 3) ..
        mInput("opt_rejoin", "Left, no return", O.rejoin, 3) ..
        mCheck("chk_opt_warn", "`w10 second warning", O.warn10) ..
        "add_spacer|small|\n" ..
        "add_label_with_icon|small|" .. C_SEC .. "Delays (ms)|left|112|\n" ..
        "add_smalltext|`wEach box is the wait between two steps.|\n" ..
        "add_smalltext|`7Order: bet collected, extra-bet window, lamp, spin text, spin, host spin, result, next bet|\n" ..
        "add_textbox|`4Delays that are too low can cause bugs.|\n" ..
        (lowDelays and "add_textbox|`4Some delays are below the safe minimum.|\n" or "") ..
        "add_smalltext|`wPreset: " .. (cur and ("`2" .. PRESET_NAMES[cur]) or "`7Custom") .. "|\n" ..
        presetBtn("btn_pre_fast", "fast", "Fast") ..
        presetBtn("btn_pre_norm", "normal", "Normal") ..
        "add_spacer|small|\n" ..
        mInput("opt_dcollect", "Bet collected > lamp opens", O.dCollect, 5) ..
        mInput("opt_dextrabet", "Extra time for drop", O.dExtraBet, 5) ..
        mInput("opt_dlamp", "Lamp on > spin text", O.dLamp, 5) ..
        mInput("opt_dhost", "Player spins > host spins", O.dHostSpin, 5) ..
        mInput("opt_dresult", "Host spins > result", O.dResult, 5) ..
        mInput("opt_dnext", "Result > bets open", O.dNext, 5) ..
        mInput("opt_ddrop", "Bets open > Drop Bet text", O.dDrop, 5) ..
        mInput("opt_dreset", "Game ends > lamp closes", O.dReset, 5) ..
        "add_label_with_icon|small|" .. C_SEC .. "Lamps (ms)|left|112|\n" ..
        mInput("opt_dlpunch", "Wait before each punch", O.dLampPunch, 5) ..
        mInput("opt_dlgap", "Wait after each punch", O.dLampGap, 5) ..
        "add_label_with_icon|small|" .. C_SEC .. "Messages (ms)|left|20|\n" ..
        mInput("opt_dmsg", "Wait before every message", O.dMsg, 5) ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_timers|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_timers_menu") ..
        mFooter("sec")
    mSend(body, "temp_timers_menu")
end

function M.rules()
    local O = Config.Opt
    local body =
        mHeader("`w" .. T("rules"), 4) ..
        mCheck("chk_rule_out", "`wSpin outside the wheel area", O.ruleOutside) ..
        mCheck("chk_rule_leme", "`wLeme can spin outside the wheel area", O.ruleLemeOut) ..
        mCheck("chk_rule_lamp", "`wSpin before the lamp is on", O.ruleLamp) ..
        mCheck("chk_rule_multi", "`wDouble spin (1R) / triple spin (2R)", O.ruleMulti) ..
        mCheck("chk_rule_drop_spin", "`wDrop after bet", O.ruleDropDuringSpin) ..
        mCheck("chk_opt_bubble", "`wShow the result in the chat bubble", O.bubble) ..
        mCheck("chk_opt_fast", "`wFast wheel", O.fastWheel) ..
        mCheck("chk_opt_ban", "`wBan fake spinners (off = kick)", O.banFake) ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_rules|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_rules_menu") ..
        mFooter("sec")
    mSend(body, "temp_rules_menu")
end

function M.convert()
    local C = Config.Conv
    local body =
        mHeader("`w" .. T("convert"), 11550) ..
        "add_smalltext|`wWL `9" .. countItem(242) .. "  `wDL `1" .. countItem(1796) ..
            "  `wBGL `e" .. countItem(7188) .. "  `wBlack `b" .. countItem(11550) .. "|\n" ..
        "add_label_with_icon|small|`2Convert now (100 into 1)|left|11550|\n" ..
        mGrid({
            { "btn_up1",      "`2WL to DL",     1796 },
            { "btn_up2",      "`2DL to BGL",    7188 },
            { "btn_up3",      "`2BGL to Black", 11550 },
            { "btn_conv_now", "`2Convert All",  11550 },
        }) ..
        "add_label_with_icon|small|`4Shatter now (1 into 100)|left|7188|\n" ..
        mGrid({
            { "btn_sh2", "`4DL to WL",     242 },
            { "btn_sh3", "`4BGL to DL",    1796 },
            { "btn_sh4", "`4Black to BGL", 7188 },
        }) ..
        "add_label_with_icon|small|`2Auto convert|left|1796|\n" ..
        mCheck("chk_c_auto", "`w" .. T("on"), C.auto) ..
        mCheck("chk_c_bet", "`wRight after a bet is collected", C.afterBet) ..
        mCheck("chk_c_idle", "`wAlso when no game", C.idle) ..
        mCheck("chk_c_up1", "`wWL to DL", C.up1) ..
        mInput("in_n1", "Times", C.n1, 3) ..
        mInput("in_keep1", "Keep WL", C.keep1, 6) ..
        mCheck("chk_c_up2", "`wDL to BGL", C.up2) ..
        mInput("in_n2", "Times", C.n2, 3) ..
        mInput("in_keep2", "Keep DL", C.keep2, 6) ..
        mCheck("chk_c_up3", "`wBGL to Black", C.up3) ..
        mInput("in_n3", "Times", C.n3, 3) ..
        mInput("in_keep3", "Keep BGL", C.keep3, 6) ..
        mInput("in_delay", "Wait between (ms)", C.delay, 5) ..
        "add_label_with_icon|small|`4Auto shatter (for payouts)|left|7188|\n" ..
        mCheck("chk_c_sh", "`w" .. T("on"), C.shatter) ..
        mCheck("chk_c_sh2", "`wDL to WL", C.sh2) ..
        mCheck("chk_c_sh3", "`wBGL to DL", C.sh3) ..
        mCheck("chk_c_sh4", "`wBlack to BGL", C.sh4) ..
        "add_label_with_icon|small|`8Telephone|left|3898|\n" ..
        mInput("in_phone", "Number", C.phone, 10) ..
        mCheck("chk_c_hide", "`wHide phone menu", C.hidePhone) ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_conv|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_conv_menu") ..
        mFooter("sec")
    mSend(body, "temp_conv_menu")
end

function M.bank()
    local B = Config.Bank
    local body =
        mHeader("`w" .. T("bank"), 7188) ..
        "add_smalltext|`wBGL `e" .. countItem(7188) .. "   " .. (B.on and "`2ON" or "`4OFF") .. "|\n" ..
        mCheck("chk_bank_on", "`w" .. T("on"), B.on) ..
        mInput("bank_trigger", "When I have (BGL)", B.trigger, 6) ..
        mInput("bank_amount", "Put in bank (BGL)", B.amount, 6) ..
        mCheck("chk_bank_wd", "`wAuto withdraw", B.wdOn) ..
        mInput("bank_wdbelow", "When I have less than (BGL)", B.wdBelow, 6) ..
        mInput("bank_wdamount", "Take out of bank (BGL)", B.wdAmount, 6) ..
        "add_button|btn_bank_save|`2" .. T("save") .. "|noflags|0|\n" ..
        "add_spacer|small|\n" ..
        mInput("bank_manual", "Amount (BGL)", B.manual, 6) ..
        mGrid({
            { "btn_bank_dep", "`2Deposit BGL",  7188 },
            { "btn_bank_wd",  "`4Withdraw BGL", 7188 },
        }) ..
        mResetBtn("temp_bank_menu") ..
        mFooter("sec")
    mSend(body, "temp_bank_menu")
end

function M.drop()
    local body =
        mHeader("`w" .. T("drop"), 242) ..
        mInput("drop_amt", "Amount", CalcState.drop or "1", 9) ..
        mGrid({
            { "btn_drop_w",  "`wDrop WL",     242 },
            { "btn_drop_d",  "`wDrop DL",     1796 },
            { "btn_drop_b",  "`wDrop BGL",    7188 },
            { "btn_drop_bl", "`wDrop Black",  11550 },
            { "btn_drop_c",  "`wCustom WL",   242 },
        }) ..
        mFooter("sec")
    mSend(body, "temp_drop_menu")
end

function M.spam()
    local body =
        mHeader("`w" .. T("spam"), 3898) ..
        mInput("input_spam_msg", "Message", Config.SpamMessage, 40) ..
        mInput("input_spam_delay", "Every (sec)", Config.SpamDelay or 10, 5) ..
        mCheck("chk_rainbow", "`wRainbow letters", Config.SpamRainbow) ..
        mCheck("chk_random", "`wRandom color", Config.SpamRandomColor) ..
        mCheck("chk_idle_only", "`wOnly when no game", Config.SpamIdleOnly) ..
        "add_spacer|small|\n" ..
        "add_button|btn_toggle_spam|" .. (Config.AutoSpam and "`4" .. T("stop") or "`2" .. T("start")) .. "|noflags|0|\n" ..
        "add_button|btn_save_spam|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_spam_menu") ..
        mFooter("sec")
    mSend(body, "temp_spam_menu")
end

function M.sb()
    local C = Config.SB
    local state = C.on and ("`2Running `w[ " .. SBRun.count .. " / " .. C.total .. " ]") or "`4Stopped"
    local body =
        mHeader("`w" .. T("sb"), 2480) ..
        "add_smalltext|" .. state .. "|\n" ..
        mInput("sb_text", "Message", C.text, 100) ..
        mInput("sb_total", "How many SBs", C.total, 4) ..
        mInput("sb_delay", "Wait between (sec)", C.delay, 4) ..
        mCheck("chk_sb_idle", "`wOnly when no game", C.idleOnly) ..
        "add_spacer|small|\n" ..
        "add_button|btn_sb_toggle|" .. (C.on and "`4" .. T("stop") or "`2" .. T("start")) .. "|noflags|0|\n" ..
        "add_button|btn_sb_save|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_sb_menu") ..
        mFooter("sec")
    mSend(body, "temp_sb_menu")
end

function M.lamp()
    local L = Config.Lamp
    local body =
        mHeader("`w" .. T("lamp"), 32) ..
        mCheck("chk_lamp_auto", "`w" .. T("on"), L.auto) ..
        mInput("lamp_id", "Lamp item ID", L.id, 6) ..
        "add_spacer|small|\n" ..
        "add_button|btn_lamp_save|`2" .. T("save") .. "|noflags|0|\n" ..
        "add_button|btn_lamp_place|`wPlace lamps now|noflags|0|\n" ..
        "add_button|btn_lamp_read|`wRead IDs (hand and lamps)|noflags|0|\n" ..
        mResetBtn("temp_lamp_menu") ..
        mFooter("sec")
    mSend(body, "temp_lamp_menu")
end

function M.champ()
    local C = Config.Champ
    local body =
        mHeader("`w" .. T("champ"), tonumber(C.id) or 17062) ..
        mCheck("chk_champ_on", "`w" .. T("on"), C.on) ..
        mInput("champ_min", "Big bet from (BGL)", C.minBGL, 5) ..
        mInput("champ_cost", "Price (DL)", C.cost, 4) ..
        mInput("champ_id", "Item ID", C.id, 6) ..
        mInput("champ_btn", "Telephone button name", C.button, 30) ..
        "add_spacer|small|\n" ..
        "add_button|btn_champ_save|`2" .. T("save") .. "|noflags|0|\n" ..
        "add_button|btn_champ_test|`wTest buy|noflags|0|\n" ..
        mFooter("sec")
    mSend(body, "temp_champ_menu")
end

local function BreakText(v)
    v = math.floor(v)
    local b = SplitWL(v)
    return "`b" .. b[4] .. " Black  `e" .. b[3] .. " BGL  `1" .. b[2] .. " DL  `9" .. b[1] .. " WL"
end

local function CalcEval(expr)
    expr = tostring(expr or ""):gsub("%s+", "")
    if expr == "" then return nil, "Type something to calculate" end
    if expr:find("[^%d%.%+%-%*/%(%)]") then return nil, "Use only numbers and + - * / ( )" end
    local compile = loadstring or load
    local chunk = compile("return " .. expr)
    if not chunk then return nil, "That does not add up" end
    local ok, res = pcall(chunk)
    if not ok or type(res) ~= "number" or res ~= res or res == math.huge or res == -math.huge then
        return nil, "That does not add up"
    end
    return res
end

function M.calc()
    local lines = ""
    if CalcState.err then
        lines = "add_smalltext|`4" .. CalcState.err .. "|\n"
    elseif CalcState.result then
        lines = "add_smalltext|`wResult: `2" .. CalcState.result .. "|\n"
        if CalcState.result >= 0 then
            lines = lines .. "add_smalltext|`w= " .. BreakText(CalcState.result) .. "|\n"
        end
    end
    local body =
        mHeader("`w" .. T("calc"), 112) ..
        mInput("calc_expr", "Calculate", CalcState.expr, 60) ..
        "add_button|btn_calc_go|`2Calculate|noflags|0|\n" ..
        lines ..
        mFooter("sec")
    mSend(body, "temp_calc_menu")
end

function M.backup()
    local body =
        mHeader("`wBackup code", 112) ..
        "add_smalltext|`7Copy your code and keep it. Paste it below to restore|\n" ..
        mInput("backup_code", "Your code", BackupCode(), 6000) ..
        "add_spacer|small|\n" ..
        mInput("backup_paste", "Paste a code", "", 6000) ..
        "add_button|btn_import|`2Import|noflags|0|\n" ..
        "add_button|btn_backup_refresh|`wRefresh code|noflags|0|\n" ..
        mFooter("set")
    mSend(body, "temp_backup_menu")
end

function M.dev()
    if not IsDev() then return end
    local O, st = Config.Opt, Session
    local function spot(w) return (w and (w.x ~= 0 or w.y ~= 0)) and (w.x .. "," .. w.y) or "none" end
    local body =
        mHeader("Dev Menu", 32) ..
        "add_smalltext|`wStep `b" .. tostring(st.step) .. "  `wMode `b" .. tostring(st.mode) .. (st.is2R and " 2R" or " 1R") .. "  `wSpins `b" .. tostring(st.spinCount or 0) .. "|\n" ..
        "add_smalltext|`wLamps on `b" .. tostring(st.lamp1On) .. "/" .. tostring(st.lamp2On) .. "  `wlive `b" .. tostring(st.lamp1Live) .. "/" .. tostring(st.lamp2Live) .. "  `wGate `b" .. tostring(st.gateOpen) .. "|\n" ..
        "add_smalltext|`wForced `b" .. tostring(st.forced) .. "  `wReady `b" .. tostring(st.lampsReady) .. "  `wPayout `b" .. tostring(payoutBusy) .. "|\n" ..
        "add_smalltext|`wWheel spots `b" .. spot(Positions.playerWheel1) .. "  " .. spot(Positions.playerWheel2) .. "|\n" ..
        "add_spacer|small|\n" ..
        mCheck("chk_dev_debug", "`wDebug logs in the console", O.debug) ..
        mInput("dev_range", "Wheel range (tiles)", O.spinRange, 2) ..
        "add_button|btn_dev_save|`2Save|noflags|0|\n" ..
        mGrid({
            { "btn_dev_bugs",    "`4Bug Logs",   32 },
            { "btn_dev_dump",    "`bDump State", 112 },
            { "btn_dev_lampon",  "`2Lamps On",   32 },
            { "btn_dev_lampoff", "`4Lamps Off",  32 },
            { "btn_dev_gate",    "`eToggle Gate", 6 },
            { "btn_dev_stop",    "`4Stop Game",  18 },
        }) ..
        mFooter("main")
    mSend(body, "temp_dev_menu")
end

function M.devbugs()
    if not IsDev() then return end
    local list, count = "", 0
    for _, entry in ipairs(HostLogs.entries) do
        if entry.type == "BUG" then
            list = list .. "add_smalltext|" .. entry.text .. "|\n"
            count = count + 1
        end
    end
    if count == 0 then list = "add_smalltext|`7Nothing here yet|\n" end
    local body =
        mHeader("Bug Logs (" .. count .. ")", 32) ..
        list ..
        "add_spacer|small|\n" ..
        "add_button|btn_clear_bugs|`4Clear bug logs|noflags|0|\n" ..
        "add_button|btn_back_dev|`wBack|noflags|0|\n" ..
        "add_button|btn_close_panel|`4Close|noflags|0|\n"
    mSend(body, "temp_devbugs_menu")
end

function M.profiles()
    local act = ProfileActive()
    local body =
        mHeader(T("presets"), 112) ..
        "add_smalltext|`wEach preset keeps all your settings (not spots or logs).|\n" ..
        "add_spacer|small|\n"
    for i = 1, 3 do
        local pr = Config.Prof[i]
        body = body ..
            "add_label_with_icon|small|" .. C_SEC .. "Preset " .. i .. (act == i and "  `2[ON]" or "") .. "|left|112|\n" ..
            mInput("prof_name" .. i, "Name", pr.name, 16) ..
            (pr.data ~= "" and ("add_button|btn_prof_load" .. i .. "|`2Load " .. pr.name .. "|noflags|0|\n") or "add_smalltext|`7Empty|\n") ..
            "add_button|btn_prof_save" .. i .. "|`wSave my settings here|noflags|0|\n" ..
            "add_spacer|small|\n"
    end
    body = body .. mFooter("set")
    mSend(body, "temp_prof_menu")
end

function M.hostopts()
    local O = Config.Opt
    local body =
        mHeader(T("hostopts"), 18) ..
        mCheck("chk_ho_shadow", "`wKick shadows (same name as the player)", O.kickShadow) ..
        mCheck("chk_ho_modfly", "`wModfly while a player plays", O.modfly) ..
        "add_spacer|small|\n" ..
        "add_button|btn_save_hostopts|`2" .. T("save") .. "|noflags|0|\n" ..
        mResetBtn("temp_hostopts_menu") ..
        mFooter("sec")
    mSend(body, "temp_hostopts_menu")
end

function M.settings()
    local O = Config.Opt
    local body =
        mHeader(T("settings"), 32) ..
        "add_smalltext|" .. (SaveInfo.status or "`7Not saved yet") .. "|\n" ..
        mInput("opt_tag", "Console tag  [ Host ]", O.tag, 15) ..
        mInput("opt_auto", "Autosave logs every (sec, 0 = off)", O.autosave, 4) ..
        "add_spacer|small|\n" ..
        "add_button|btn_nav_prof|`9" .. T("presets") .. "|noflags|0|\n" ..
        "add_button|btn_nav_lang|`w" .. T("language") .. ": " .. tostring(O.lang) .. "|noflags|0|\n" ..
        "add_button|btn_save_all|`2" .. T("save") .. " now|noflags|0|\n" ..
        "add_button|btn_reload|`eReload from file|noflags|0|\n" ..
        "add_button|btn_reset_set|" .. (ResetArm == "set" and "`4Click again: reset settings" or "`4Reset settings") .. "|noflags|0|\n" ..
        "add_button|btn_reset_all|" .. (ResetArm == "all" and "`4Click again: reset EVERYTHING" or "`4Reset everything") .. "|noflags|0|\n" ..
        mFooter("main")
    mSend(body, "temp_set_menu")
end

function M.lang()
    local body =
        mHeader("`w" .. T("language"), 20) ..
        mCheck("chk_lang_msgs", "`wAlso change the host messages", true) ..
        mNote("Arabic and Vietnamese use Latin letters (the game font has no other scripts)")
    for _, lg in ipairs(LANG_LIST) do
        body = body .. "add_button|btn_lang_" .. lg[1] .. "|" .. ((Config.Opt.lang == lg[1]) and "`2" or "`w") .. lg[2] .. "|noflags|0|\n"
    end
    body = body .. mFooter("set")
    mSend(body, "temp_lang_menu")
end

function M.commands()
    local body =
        mHeader("`w" .. T("commands"), 20) ..
        "add_label_with_icon|small|`8General|left|32|\n" ..
        mLine("/menu", "open the panel") ..
        mLine("/commands", "this list") ..
        mLine("/hold  /continue", "pause / resume the game") ..
        mLine("/stop", "end the game and kick the player") ..
        mLine("/gate", "open or close the gate by hand") ..
        mLine("/id", "show the item ID in your hand and on the lamp spots") ..
        mLine("/resetconfig", "reset settings and spots") ..
        "add_label_with_icon|small|`8Drop locks|left|242|\n" ..
        mLine("/dw 100", "drop 100 WL") ..
        mLine("/dd 5", "drop 5 DL") ..
        mLine("/db", "toggle automatic bank deposits/withdrawals") ..
        mLine("/depo 2", "deposit 2 BGL into bank") ..
        mLine("/wd 2", "withdraw 2 BGL from bank") ..
        mLine("/exitmsg text", "set !exit reply; blank clears it") ..
        mLine("/db 2", "drop 2 BGL") ..
        mLine("/dbl 1", "drop 1 Black GL") ..
        mLine("/dcw 10500", "drop 10500 WL as 1 BGL + 5 DL") ..
        "add_label_with_icon|small|`8Bets|left|242|\n" ..
        mLine("/min 10", "minimum bet") ..
        mLine("/max 500", "maximum bet (0 = no limit)") ..
        "add_label_with_icon|small|`8Modes|left|758|\n" ..
        mLine("/enablereme  /disablereme", "Reme on / off") ..
        mLine("/enableqeme  /disableqeme", "Qeme on / off") ..
        mLine("/enableleme  /disableleme", "Leme on / off") ..
        mLine("/enable2r  /disable2r", "2R on / off") .. mLine("Game Modes > 1 Room enabled", "Disable 1R") ..
        mLine("/reme word", "change the Reme word (also /qeme /leme /2r /1r)") ..
        "add_label_with_icon|small|`8Messages|left|20|\n" ..
        mLine("/winmsg text", "win message") ..
        mLine("/losemsg text", "lose message") ..
        mLine("/dropbetmsg text", "drop bet message") ..
        "add_label_with_icon|small|`8Spam|left|3898|\n" ..
        mLine("/enablespam  /disablespam", "spam on / off") ..
        mLine("/spammsg text", "spam message") ..
        mLine("/spamtimer 10", "seconds between spam") ..
        mFooter("main")
    mSend(body, "temp_cmd_menu")
end

function M.help()
    local body =
        mHeader("`w" .. T("info"), 20) ..
        "add_label_with_icon|small|`21. Setup|left|6|\n" ..
        mNote("Game Setup > Spot Setup: stand on each spot and type its command") ..
        mNote("Wheels, display box, drop spot, lamps and gate") ..
        "add_label_with_icon|small|`22. Playing|left|758|\n" ..
        mNote("Player types " .. (Config.TriggerReme or "!reme") .. ", " .. (Config.TriggerQeme or "!qeme") .. " or " .. (Config.TriggerLeme or "!leme")) ..
        mNote("Then drops a bet and spins. " .. (Config.Trigger2R or "!2r") .. " = 2 rooms, " .. (Config.Trigger1R or "!1r") .. " = 1 room") ..
        mNote((Config.TriggerExit or "!exit") .. " kicks the player, only before a bet is dropped") ..
        "add_label_with_icon|small|`23. Locks|left|11550|\n" ..
        mNote("Convert runs right after a bet is collected, biggest locks first") ..
        mNote("Shatter breaks a bigger lock when a payout needs smaller ones") ..
        mNote("Auto Bank saves BGL when you reach your amount") ..
        "add_label_with_icon|small|`24. Rules|left|4|\n" ..
        mNote("Spin outside the area, before the lamp, or twice (3 times in 2R) = lose") ..
        mFooter("main")
    mSend(body, "temp_help_menu")
end

function M.control()
    local state = "`7No game running"
    if Session.active then state = Session.onHold and "`4Game paused" or "`2Game running" end
    local body =
        mHeader("`w" .. T("controls"), 18) ..
        "add_smalltext|" .. state .. "|\n" ..
        "add_spacer|small|\n" ..
        "add_button|btn_hold_game|`ePause|noflags|0|\n" ..
        "add_button|btn_continue_game|`2Resume|noflags|0|\n" ..
        "add_button|btn_stop_game|`4Stop game (kicks the player)|noflags|0|\n" ..
        mFooter("main")
    mSend(body, "temp_ctrl_menu")
end

local function ShowMainTempMenu() M.main() end
local function ShowCommandsHelpMenu() M.commands() end

local function CalcReme(n)
    if n == 0 then return 10 end
    if n == 10 then return 1 end
    local sum = math.floor(n / 10) + (n % 10)
    if sum == 10 then return 10 end
    return sum % 10
end

local function CalcQeme(n)
    if n == 0 then return 1 end
    if n == 10 or n == 20 or n == 30 then return 10 end
    local val = n % 10
    if val == 0 then val = 10 end
    return val
end

local function CalcLeme(n, isPlayer)
    local sum = math.floor(n / 10) + (n % 10)
    local score = sum
    if sum == 0 or sum == 10 then score = 10
    elseif sum == 1 or sum == 11 then score = 9.5
    end

    if isPlayer then
        if score == 2 or score == 9 then return -1 end
        return score
    end

    if score == 2 then return -1 end
    if score == 10 or score == 9.5 or score == 9 then return 11 end
    return score
end

local function GetScore(mode, num, isPlayer)
    if mode == "reme" or mode == "2r" then return CalcReme(num)
    elseif mode == "qeme" then return CalcQeme(num)
    elseif mode == "leme" then return CalcLeme(num, isPlayer) end
    return CalcReme(num)
end

local function ScoreText(score)
    if score == 9.5 then return "1" end
    return tostring(score)
end

local function RoomMult(mode, score)
    if mode == "leme" then
        if score == 10 then return 4 end
        if score == 9.5 then return 3 end
        return 2
    end
    if score == 10 then return 3 end
    return 2
end

local function FullReset()

    Session.active = false
    Session.onHold = false
    Session.is2R = false
    Session.step = "IDLE"
    Session.playerNetId = nil
    Session.playerUserId = nil
    Session.playerName = nil
    Session.hostSpin = nil
    Session.playerSpin1 = nil
    Session.playerSpin2 = nil
    Session.betAmount = 0
    Session.rawBetItems = {}
    Session.sessionToken = Session.sessionToken + 1
    Session.accumulatedBets = {}
    Session.collectingWindow = false
    Session.lampsReady = false
    Session.lamp1Live = false
    Session.lamp2Live = false
    Session.spinCount = 0
    Session.forced = false
    Session.wheelUsed = {}

    RunThread(function()
        pcall(HostWait, Config.Opt.dReset)

        if not Session.active then Session.gateWant = false end
        if not (Session.active and Session.lampsReady) then
            Session.want1, Session.want2 = false, false
        end
        local okD, errD = pcall(RunDesk)
        if not okD then logMsg("`4Reset error: `w" .. tostring(errD)) end
        pcall(ApplyModfly)
    end)
end

local function ResetRoundPreserveGame()
    Session.hostSpin = nil
    Session.playerSpin1 = nil
    Session.playerSpin2 = nil
    Session.sessionToken = Session.sessionToken + 1
    Session.accumulatedBets = {}
    Session.collectingWindow = false
    Session.spinCount = 0
    Session.forced = false
    Session.wheelUsed = {}
end

local function StartTimer(token, duration, callback)
    RunThread(function()
        local elapsed = 0
        while Session.active and not Session.onHold and Session.sessionToken == token and elapsed < duration do
            if Sleep then Sleep(1000) end
            if not Session.onHold then
                elapsed = elapsed + 1
                if Config.Opt.warn10 and duration > 10 and elapsed == duration - 10 and Session.sessionToken == token and Session.active then
                    sendInstant(MsgT("warn10"))
                end
            end
        end
        if Session.active and not Session.onHold and Session.sessionToken == token then
            local okC, errC = pcall(callback)
            if not okC then
                logMsg("`4Timer error: `w" .. tostring(errC))

                if Session.active and Session.sessionToken == token then pcall(FullReset) end
            end
        end
    end)
end

local function DoTimeout(why)
    if not Session.active then return end
    if Session.step == "WAITING_PLAYER_SPIN" or Session.step == "WAITING_PLAYER_SPIN_2" then
        ForceLose(why or "did not spin in time", "lose", false, true)
        return
    end
    local name = cleanText(Session.playerName or "?")
    local netid = Session.playerNetId
    local what = why
    if not what then
        if Session.step == "WAITING_BET" then what = "did not drop a bet"
        elseif Session.step == "WAITING_PLAYER_SPIN_2" then what = "did not spin the 2nd wheel"
        else what = "did not spin in time" end
    end

    FullReset()
    local ok, err = pcall(function()
        if netid then KickPlayer(netid) end
        HostLogs.totalTimeouts = HostLogs.totalTimeouts + 1
        AddHostLog("TIMEOUT", "`w" .. name .. " " .. what .. " `7(kicked)")
        sendInstant(MsgT("timeout"))
    end)
    if not ok then logMsg("`4Timeout error (host already reset): `w" .. tostring(err)) end
end

local function LogGame(kind, payout, detail)
    local name = cleanText(Session.playerName or "?")
    local mode = (Session.mode or "?"):upper() .. (Session.is2R and " 2R" or " 1R")
    local bet = math.floor(Session.betAmount or 0)
    payout = math.floor(payout or 0)
    if kind == "WIN" then
        AddHostLog("WIN", "`w" .. name .. " won `2" .. FormatLockAmount(payout) .. " `7(bet " .. FormatLockAmount(bet) .. ", host -" .. FormatLockAmount(math.max(0, payout - bet)) .. ") `w" .. mode .. " `7" .. (detail or ""))
    else
        AddHostLog("LOSS", "`w" .. name .. " lost `4" .. FormatLockAmount(bet) .. " `7(host +" .. FormatLockAmount(bet) .. ") `w" .. mode .. " `7" .. (detail or ""))
    end
end

local ForcePull

local function ForceLose(reason, msgKey, stopGame, pullBack)
    if not Session.active or Session.forced then return end
    Session.forced = true
    Session.sessionToken = Session.sessionToken + 1
    Session.step = "EVALUATING"
    local token = Session.sessionToken
    HostLogs.totalGames = HostLogs.totalGames + 1
    HostLogs.totalLosses = HostLogs.totalLosses + 1
    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss + (Session.betAmount or 0)
    LogGame("LOSS", 0, reason)
    RunThread(function()
        CloseLamps()
        if msgKey == "lose" then sendInstant(Config.LoseMessage) else sendInstant(MsgT(msgKey)) end
        HostWait(stopGame and 1000 or Config.Opt.dNext)
        if stopGame then

            if Session.active and Session.sessionToken == token then
                AddHostLog("EXIT", cleanText(Session.playerName or "?") .. " game stopped (" .. tostring(reason) .. ")")
                FullReset()
                sendInstant(MsgT("stopped"))
            end
            return
        end
        if Session.active and Session.sessionToken == token then
            ResetRoundPreserveGame()
            Session.step = "WAITING_BET"
            ReturnToStandSpot()
            sendInstant(Config.DropBetMessage:format(Session.mode:upper() .. " " .. (Session.is2R and "2R" or "1R")), Config.Opt.dDrop)
            StartTimer(Session.sessionToken, Config.Opt.betTime, function()
                DoTimeout()
            end)
            -- Do not pull on round reset; pull only when a session/mode is first started.
        end
    end)
end

local function ToTile(v)
    v = tonumber(v) or 0
    if v > 200 then return math.floor(v / 32) end
    return math.floor(v)
end

local function PlayerTile(netid, name)
    if not GetPlayerList then return nil end
    for _, pl in pairs(GetPlayerList()) do
        if pl and ((netid and pl.netid == netid) or SameName(pl.name, name)) then
            if pl.pos then return ToTile(pl.pos.x), ToTile(pl.pos.y) end
            if pl.pos_x and pl.pos_y then return ToTile(pl.pos_x), ToTile(pl.pos_y) end
            return nil
        end
    end
    return nil
end

local function SpunOutside()
    local w1, w2 = Positions.playerWheel1, Positions.playerWheel2
    local has1, has2 = lampValid(w1), lampValid(w2)
    if not has1 and not has2 then return false end
    local px, py = PlayerTile(Session.playerNetId, Session.playerName)
    if not px then
        DevLog("outside check: player position unknown, skipped")
        return false
    end
    local r = tonumber(Config.Opt.spinRange) or 6
    local function near(w) return math.abs(px - w.x) <= r and math.abs(py - w.y) <= r end
    local n1, n2 = has1 and near(w1), has2 and near(w2)
    DevLog("outside check: player " .. px .. "," .. py .. " range " .. r .. " wheel1 " .. tostring(n1) .. " wheel2 " .. tostring(n2))
    if Session.is2R and has1 and has2 then

        local used = Session.wheelUsed or {}
        Session.wheelUsed = used
        if n1 and not used[1] then used[1] = true return false end
        if n2 and not used[2] then used[2] = true return false end
        return true
    end
    return not (n1 or n2)
end

local function IsPlayerSpin(clean, netid)
    -- Prefer the current network ID, but retain the original console-message
    -- name check as a fallback: OnConsoleMessage does not include a netID and
    -- the player-list lookup can briefly fail during a spin event.
    if Session.playerNetId and netid and tonumber(netid) == tonumber(Session.playerNetId) then
        return true
    end
    local who = tostring(clean or ""):match("^%s*(.-)%s+spun the wheel")
    if who and who ~= "" and Session.playerName and SameName(who, Session.playerName) then
        return true
    end
    return false
end

local function SpinAllowed(n)
    if Session.lampsReady then return true end
    local live = (Session.lamp1Live and 1 or 0) + (Session.lamp2Live and 1 or 0)
    return live >= (tonumber(n) or 1)
end

local function CheckSpinRules()
    local O = Config.Opt
    Session.spinCount = (Session.spinCount or 0) + 1
    local maxSpins = Session.is2R and 2 or 1
    if O.ruleMulti and Session.spinCount > maxSpins then
        ForceLose(Session.is2R and "triple spin" or "double spin", Session.is2R and "spintriple" or "spindouble")
        return true
    end
    if O.ruleLamp and not SpinAllowed(Session.spinCount) then
        ForceLose("spun before the lamp", "spinearly")
        return true
    end
    -- Respect the master outside-wheel rule toggle. When it is disabled,
    -- never penalize a spin for the player's position. If enabled, the
    -- separate Leme option can still allow Leme spins outside the wheel area.
    if O.ruleOutside and not (Session.mode == "leme" and O.ruleLemeOut) and SpunOutside() then
        DevLog("outside spin: player loses this round (outside rule enabled)")
        ForceLose("spun outside the wheel area", "spinout", false, true)
        return true
    end
    return false
end

function ForcePull(netid)
    if not Session.active then return false end
    local id = Session.playerNetId or netid
    if not id then return false end

    -- All normal hosting pulls (Reme/Leme/Qeme, 1R/2R and other modes)
    -- must happen from the configured pull spot, not only during respawns.
    local pullAtSpot = rawget(_G, "PullPlayerAtSpot")
    local pulled = false
    if type(pullAtSpot) == "function" then
        local ok, result = pcall(pullAtSpot, id)
        pulled = ok and result == true
    end

    -- If a pull spot is not configured or cannot be reached, keep the old
    -- normal pull as a safe fallback instead of silently doing nothing.
    if not pulled and Session.active then
        pcall(PullPlayer, id)
        if Sleep then Sleep(350) end
    end

    -- Short pause, but don't teleport back so quickly that the pull is cancelled.
    if Sleep then Sleep(500) end
    if Session.active and not Session.onHold then
        ReturnToStandSpot()
    end
    return pulled
end

local function StopGame()
    local netid = Session.playerNetId
    if Session.active and netid then
        AddHostLog("EXIT", cleanText(Session.playerName or "?") .. " was kicked (stop)")
        KickPlayer(netid)
    end
    FullReset()
end

local function StartSession(mode, netid, name, is2RMode)
    Session.active = true
    ApplyModfly()
    Session.onHold = false
    Session.mode = mode
    Session.is2R = is2RMode
    Session.playerNetId = netid
    Session.playerUserId = PlayerUserIdByNetId(netid)
    Session.playerName = name
    Session.step = "WAITING_BET"

    if Session.is2R then
        ToggleGate(true)
    else
        ToggleGate(false)
    end

    local currentToken = Session.sessionToken

    RunThread(function()
        ReturnToStandSpot()
        if Sleep then Sleep(100) end
        if Session.playerNetId then
            ForcePull(Session.playerNetId)
        end
    end)

    local modeTag = mode:upper() .. " " .. (Session.is2R and "2R" or "1R")
    sendInstant(Config.DropBetMessage:format(modeTag), Config.Opt.dDrop)

    StartTimer(currentToken, Config.Opt.betTime, function()
        DoTimeout()
    end)
end

RunThread(function()
    local lastKey, since = nil, os.time()
    while true do
        if not Sleep then return end
        Sleep(2000)
        pcall(function()
            if not Session.active or Session.onHold then lastKey = nil return end
            local key = tostring(Session.step) .. ":" .. tostring(Session.sessionToken)
            if key ~= lastKey then lastKey = key since = os.time() return end
            local O = Config.Opt
            local limit = math.max(tonumber(O.betTime) or 30, tonumber(O.spinTime) or 60,
                tonumber(O.spin2Time) or 60, tonumber(O.respinTime) or 60, tonumber(O.rejoin) or 60) + 45
            if os.time() - since > limit then
                AddHostLog("TIMEOUT", cleanText(Session.playerName or "?") .. " game stuck at " .. tostring(Session.step) .. " (auto-reset)")
                FullReset()
                sendInstant(MsgT("stopped"))
                lastKey = nil
            end
        end)
    end
end)

RunThread(function()
    while true do
        if Config.AutoSpam and Config.SpamMessage ~= "" then
            local isPlaying = Session.active or (Session.playerName ~= nil)
            if not (Config.SpamIdleOnly and isPlaying) then
                local finalMsg = Config.SpamMessage
                if Config.SpamRainbow then
                    local coloredStr = ""
                    for i = 1, #finalMsg do
                        local char = finalMsg:sub(i, i)
                        if char ~= " " then
                            local randColor = colorList[math.random(#colorList)]
                            coloredStr = coloredStr .. randColor .. char
                        else
                            coloredStr = coloredStr .. " "
                        end
                    end
                    finalMsg = coloredStr
                elseif Config.SpamRandomColor then
                    local randColor = colorList[math.random(#colorList)]
                    finalMsg = randColor .. finalMsg
                end
                sendInstant(finalMsg)
            end
        end
        if Sleep then Sleep((Config.SpamDelay or 10) * 1000) end
    end
end)


function SpinHostWheelWithRetry(initialToken)
    RunThread(function()
        for attempt = 1, 3 do
            if not Session.active or Session.sessionToken ~= initialToken or Session.step ~= "WAITING_HOST_SPIN" then return end
            local hw = GetRandomHostWheel()
            if hw.x == 0 or hw.y == 0 then
                logMsg("`4Set /wheel1 and /wheel2 before using automatic spins")
                return
            end
            MoveTo(hw.x, hw.y)
            if not Config.Opt.fastWheel and Sleep then Sleep(200) end
            PunchDirect(hw.x, hw.y)
            for _ = 1, 10 do
                if Sleep then Sleep(100) end
                if not Session.active or Session.sessionToken ~= initialToken or Session.step ~= "WAITING_HOST_SPIN" then return end
            end
        end
        if Session.active and Session.sessionToken == initialToken and Session.step == "WAITING_HOST_SPIN" then
            ReturnToStandSpot()
            AddHostLog("BUG", "Host wheel spin was not detected after 3 attempts")
            logMsg("`4Could not confirm wheel spin after 3 attempts")
        end
    end)
end

AddHook("onvariant", "REME_CHAT_HOOK", function(var)
    if not Guard() then return false end
    if not var or not var[0] then return false end

    if var[0] == "OnTalkBubble" then
        local netid = tonumber(var[1])
        local msg = var[2] or ""
        if RecentHostMsg(msg) then return false end
        local lowMsg = string.lower(msg)

        local playerName = "Player"
        if netid and GetPlayerList then
            for _, p in pairs(GetPlayerList()) do
                if p and p.netid == netid then
                    playerName = cleanText(p.name)
                    break
                end
            end
        end

        local bubblePlayer = nil
        if netid and GetPlayerList then
            for _, p in pairs(GetPlayerList()) do
                if p and tonumber(p.netid) == netid then bubblePlayer = p break end
            end
        end
        if Session.active and Session.playerName and bubblePlayer and PlayerMatchesSession(bubblePlayer) then
            if Session.playerNetId ~= netid then Session.playerNetId = netid end
        elseif Session.active and Session.playerName and SameName(playerName, Session.playerName) and not Session.playerUserId then
            Session.playerNetId = netid
        end

        local isPlayerTurn = Session.active and (netid == Session.playerNetId or (bubblePlayer and PlayerMatchesSession(bubblePlayer)) or (not Session.playerUserId and SameName(playerName, Session.playerName)))

        local exitCommand = (Config.TriggerExit or "!exit"):lower()
        if exitCommand ~= "" and lowMsg:find(exitCommand, 1, true) then
            if isPlayerTurn then
                if Session.step == "WAITING_BET" then
                    local exitId = Session.playerNetId
                    AddHostLog("EXIT", cleanText(Session.playerName or "?") .. " used " .. exitCommand .. " (kicked)")
                    if exitId then KickPlayer(exitId) end
                    FullReset()
                    sendInstant(MsgT("exitok"))
                    return true
                else
                    sendInstant(MsgT("noexit"))
                    return false
                end
            end
            return false
        end

        if not isPlayerTurn or Session.step == "WAITING_BET" or not Session.active then
            local quiet = Session.active and not isPlayerTurn
            local trig1R = (Config.Trigger1R or "!1r"):lower()
            if lowMsg:find(trig1R, 1, true) then
                if Config.Enable1R == false then if not quiet then sendInstant(MsgT("modeoff", "1R")) end return false end
                if Session.active and isPlayerTurn then
                    local was2R = Session.is2R
                    Session.is2R = false
                    RunThread(function()

                        if was2R and Session.playerNetId then
                            PullPlayer(Session.playerNetId)
                            if Sleep then Sleep(800) end
                        end
                        ToggleGate(false)
                    end)
                    sendInstant(MsgT("to1r"))
                    return true
                elseif not Session.active then
                    Session.is2R = false
                    sendInstant(MsgT("def1r"))
                    return true
                end
            end

            local trigReme = (Config.TriggerReme or "!reme"):lower()
            local trigQeme = (Config.TriggerQeme or "!qeme"):lower()
            local trigLeme = (Config.TriggerLeme or "!leme"):lower()
            local trig2R = (Config.Trigger2R or "!2r"):lower()

            local detectedMode = nil

            if lowMsg:find(trigReme, 1, true) then detectedMode = "reme"
            elseif lowMsg:find(trigQeme, 1, true) then detectedMode = "qeme"
            elseif lowMsg:find(trigLeme, 1, true) then detectedMode = "leme" end

            local has2R = lowMsg:find(trig2R, 1, true) ~= nil
            if not has2R and detectedMode then

                local bare = trig2R:gsub("^[^%w]+", "")
                if bare ~= "" then
                    local pat = "%f[%w]" .. bare:gsub("%W", "%%%0") .. "%f[%W]"
                    has2R = lowMsg:find(pat) ~= nil
                end
            end

            if has2R and not detectedMode then
                if Session.active and isPlayerTurn then
                    if not Config.Enable2R then sendInstant(MsgT("off2r")) return false end
                    Session.is2R = true
                    ToggleGate(true)
                    local modeTag = Session.mode:upper() .. " 2R"
                    sendInstant(MsgT("switched", modeTag))
                    return true
                else
                    if not quiet then sendInstant(MsgT("need2r")) end
                    return false
                end
            end

            if detectedMode then
                if detectedMode == "reme" and not Config.EnableReme then if not quiet then sendInstant(MsgT("modeoff", "Reme")) end return false end
                if detectedMode == "qeme" and not Config.EnableQeme then if not quiet then sendInstant(MsgT("modeoff", "Qeme")) end return false end
                if detectedMode == "leme" and not Config.EnableLeme then if not quiet then sendInstant(MsgT("modeoff", "Leme")) end return false end

                local targetMode = detectedMode

                local want2R = false
                if has2R then
                    if Config.Enable2R then want2R = true elseif not quiet then sendInstant(MsgT("off2r")) end
                end
                if not want2R and Config.Enable1R == false then if not quiet then sendInstant(MsgT("modeoff", "1R")) end return false end

                if not Session.active then
                    StartSession(targetMode, netid, playerName, want2R)
                    return true
                else
                    if Session.step == "WAITING_BET" and isPlayerTurn then
                        Session.mode = targetMode
                        if want2R then
                            Session.is2R = true
                            ToggleGate(true)
                        end
                        local modeTag = targetMode:upper() .. (Session.is2R and " 2R" or " 1R")
                        sendInstant(MsgT("switched", modeTag))
                        local pullId = Session.playerNetId or netid
                        RunThread(function() ForcePull(pullId) end)
                        return true
                    end
                end
                return false
            end
        end
    end
    return false
end)

AddHook("onvariant", "REME_ENGINE_HOOK", function(var)
    if not var or not var[0] then return false end
    if not Guard() then return false end

    if var[0] == "OnConsoleMessage" then
        local text = var[1]
        if text then
            local cleanTxt = cleanText(text)

            if Session.active and Session.playerName then
                local targetName = cleanText(Session.playerName):lower()

                if ContainsName(cleanTxt, Session.playerName) and cleanTxt:find("<", 1, true) and (cleanTxt:find("left,", 1, true) or cleanTxt:find("entered,", 1, true)) then
                    if cleanTxt:find("left,") then
                        AddHostLog("EXIT", cleanText(Session.playerName or "?") .. " left the world")
                        if Session.step == "WAITING_BET" then
                            FullReset()
                            sendInstant(MsgT("left"))
                            return false
                        end

                        sendInstant(MsgT("leftactive", tonumber(Config.Opt.rejoin) or 60))
                        local token = Session.sessionToken
                        RunThread(function()
                            if Sleep then Sleep((tonumber(Config.Opt.rejoin) or 60) * 1000) end
                            if Session.active and Session.sessionToken == token then
                                AddHostLog("TIMEOUT", cleanText(Session.playerName or "?") .. " did not come back (auto-lose)")
                                sendInstant(MsgT("failreturn"))
                                FullReset()
                            end
                        end)
                        return false
                    elseif cleanTxt:find("entered,") then
                        sendInstant(MsgT("rejoin"))
                        if GetPlayerList then
                            for _, p in pairs(GetPlayerList()) do
                                if p and PlayerMatchesSession(p) then
                                    Session.playerNetId = p.netid
                                    Session.playerUserId = tonumber(p.userid or p.userID or p.user_id or p.uid) or Session.playerUserId
                                    PullPlayer(p.netid)
                                    break
                                end
                            end
                        end
                        return false
                    end
                end
            end

            if cleanTxt:find("spun the wheel") and cleanTxt:find("%[FAKE%]") then
                if GetPlayerList then
                    for _, p in pairs(GetPlayerList()) do
                        if p and ContainsName(cleanTxt, p.name) then
                            if Config.Opt.banFake then BanPlayer(p.netid) else KickPlayer(p.netid) end
                            HostLogs.totalBugs = HostLogs.totalBugs + 1
                            AddHostLog("BUG", cleanText(p.name) .. " used a fake spin (" .. (Config.Opt.banFake and "banned" or "kicked") .. ")")
                            sendInstant(MsgT("fake"))
                            if Session.active and p.netid == Session.playerNetId then
                                FullReset()
                                sendInstant(MsgT("stopped"))
                            end
                            break
                        end
                    end
                end
                return false
            end

            -- Any extra lock/gem dropped by the active player after the lamps are on
            -- or the spin instruction has been announced is an automatic loss.
            if Config.Opt.ruleDropDuringSpin and Session.active and not Session.onHold and Session.playerName
                and ContainsName(cleanTxt, Session.playerName)
                and cleanTxt:lower():find("dropped", 1, true)
                and (cleanTxt:lower():find("lock", 1, true) or cleanTxt:lower():find("gem", 1, true))
                and (Session.lampsReady or Session.lamp1Live or Session.lamp2Live
                    or Session.step == "WAITING_PLAYER_SPIN" or Session.step == "WAITING_PLAYER_SPIN_2") then
                AddHostLog("LOSS", cleanText(Session.playerName) .. " dropped extra locks/gems after the lamps turned on")
                ForceLose("dropped extra bet while lamps were on", "lose", false, true)
                return false
            end

            if Session.active and not Session.onHold and cleanTxt:find("Collected") then
                local count, itemType = cleanTxt:match("Collected%s+(%d+)%s+(.+)%s*")
                if count and itemType then
                    local itemStr = cleanText(itemType):lower()
                    if itemStr:find("^creativeps") or itemStr:find("lock") or itemStr:find("gem") then
                        if Session.step == "WAITING_PLAYER_SPIN" or Session.step == "WAITING_PLAYER_SPIN_2" then
                            if Session.convertTime and (os.time() - Session.convertTime) <= 20 then

                                local worthEach = 1
                                if itemStr:find("blue gem") then worthEach = 10000
                                elseif itemStr:find("diamond lock") then worthEach = 100
                                elseif itemStr:find("black gem") then worthEach = 1000000 end
                                local extra = (tonumber(count) or 0) * worthEach
                                Session.betAmount = (Session.betAmount or 0) + extra
                                AddHostLog("BET", "`wExtra `6" .. extra .. " WL `wpicked up after converting")
                                return false
                            end
                            DoTimeout("dropped locks while spinning")
                            return false
                        end

                        local bet = tonumber(count) or 0
                        local id = 242
                        if itemStr:find("blue gem") then id = 7188
                        elseif itemStr:find("diamond lock") then id = 1796
                        elseif itemStr:find("black gem") then id = 11550 end

                        if Session.step == "COLLECTING" and Session.collectingWindow then
                            -- Every additional Collected notification during the bet window
                            -- must be counted too. Reset the quiet-period timer so drops that
                            -- arrive together are not missed by the displayed total.
                            Session.lastBetCollectionAt = (os and os.clock and os.clock()) or 0
                            Session.betQuietRemaining = math.max(0, tonumber(Config.Opt.dExtraBet) or 3000)
                            table.insert(Session.accumulatedBets, { id = id, amount = bet })
                            QuickConvert()
                            return false
                        end

                        if Session.step == "WAITING_BET" and not Session.collectingWindow then
                            Session.collectingWindow = true
                            Session.accumulatedBets = {}
                            Session.lastBetCollectionAt = (os and os.clock and os.clock()) or 0
                            Session.betQuietRemaining = math.max(0, tonumber(Config.Opt.dExtraBet) or 3000)
                            Session.step = "COLLECTING"
                            Session.sessionToken = Session.sessionToken + 1
                            local collectToken = Session.sessionToken

                            RunThread(function()
                                local quietMs = math.max(0, tonumber(Config.Opt.dExtraBet) or 3000)
                                local waitedMs = 0
                                local maxWaitMs = quietMs + 15000
                                while waitedMs < maxWaitMs do
                                    if not Session.active or Session.onHold or Session.sessionToken ~= collectToken then return end
                                    if Sleep then Sleep(100) end
                                    waitedMs = waitedMs + 100
                                    -- Keep polling only the configured display boxes during
                                    -- the settling period; new Collected messages restart quiet time.
                                    if waitedMs % 500 == 0 then CollectFromDisplayBoxes() end
                                    Session.betQuietRemaining = math.max(0, (tonumber(Session.betQuietRemaining) or quietMs) - 100)
                                    if (tonumber(Session.betQuietRemaining) or 0) <= 0 then break end
                                end
                                if not Session.active or Session.onHold or Session.sessionToken ~= collectToken then return end
                                -- Short final settle for a pickup notification already in flight.
                                if Sleep then Sleep(300) end
                                if not Session.active or Session.onHold or Session.sessionToken ~= collectToken then return end
                                Session.collectingWindow = false

                                local totalVal = 0
                                local rawMap = {}
                                for _, b in pairs(Session.accumulatedBets) do
                                    local val = tonumber(b.amount) or 0
                                    if b.id == 1796 then val = val * 100
                                    elseif b.id == 7188 then val = val * 10000
                                    elseif b.id == 11550 then val = val * 1000000 end
                                    totalVal = totalVal + val
                                    rawMap[b.id] = (rawMap[b.id] or 0) + (tonumber(b.amount) or 0)
                                end

                                local refundList = {}
                                for id, amt in pairs(rawMap) do table.insert(refundList, { id = id, amount = amt }) end

                                if totalVal < Config.MinBet then
                                    RefundBet(refundList, MsgT("minbet", Config.MinBet))
                                    ResetRoundPreserveGame()
                                    Session.step = "WAITING_BET"
                                    local modeTag = Session.mode:upper() .. " " .. (Session.is2R and "2R" or "1R")
                                    sendInstant(Config.DropBetMessage:format(modeTag), Config.Opt.dDrop)
                                    ResetTieLamps()
                                    StartTimer(Session.sessionToken, Config.Opt.betTime, function()
                                        DoTimeout()
                                    end)
                                    return
                                end

                                if Config.MaxBet > 0 and totalVal > Config.MaxBet then
                                    RefundBet(refundList, MsgT("maxbet", Config.MaxBet))
                                    ResetRoundPreserveGame()
                                    Session.step = "WAITING_BET"
                                    local modeTag = Session.mode:upper() .. " " .. (Session.is2R and "2R" or "1R")
                                    sendInstant(Config.DropBetMessage:format(modeTag), Config.Opt.dDrop)
                                    ResetTieLamps()
                                    StartTimer(Session.sessionToken, Config.Opt.betTime, function()
                                        DoTimeout()
                                    end)
                                    return
                                end

                                local requiredMult = (Session.mode == "leme") and 4 or 3
                                if (totalVal * requiredMult) > GetTotalWealth() then
                                    RefundBet(refundList, MsgT("lowbal"))
                                    ResetRoundPreserveGame()
                                    Session.step = "WAITING_BET"
                                    local modeTag = Session.mode:upper() .. " " .. (Session.is2R and "2R" or "1R")
                                    sendInstant(Config.DropBetMessage:format(modeTag), Config.Opt.dDrop)
                                    ResetTieLamps()
                                    StartTimer(Session.sessionToken, Config.Opt.betTime, function()
                                        DoTimeout()
                                    end)
                                    return
                                end

                                Session.betAmount = totalVal
                                Session.rawBetItems = refundList
                                sendInstant("`2Collected `w" .. FormatLockAmount(totalVal))
                                Session.hostSpin = nil
                                Session.playerSpin1 = nil
                                Session.playerSpin2 = nil

                                Session.step = "WAITING_PLAYER_SPIN"

                                if Config.Champ.on and Session.betAmount >= (tonumber(Config.Champ.minBGL) or 10) * 10000 then
                                    BuyAndUseChampagne()
                                end
                                AddHostLog("BET", cleanText(Session.playerName or "?") .. " bet `6" .. FormatLockAmount(Session.betAmount or 0) .. " `7" .. Session.mode:upper() .. (Session.is2R and " 2R" or " 1R"))
                                RunThread(function() AutoConvertAfterBet() end)
                                local lampToken = Session.sessionToken
                                RunThread(function()
                                    hostSetupBusy = true
                                    local function stale()
                                        return (not Session.active) or Session.forced or Session.sessionToken ~= lampToken
                                    end
                                    local okSetup, setupErr = pcall(function()
                                        WaitPayout()
                                        if stale() then return end

                                        -- Keep the host at the configured stand spot when a game starts.
                                        -- RunDesk may briefly approach the lamp/desk tiles to interact,
                                        -- so return to the stand spot after lamp setup is complete.
                                        ReturnToStandSpot()
                                        if Sleep then Sleep(150) end
                                        if stale() then return end
                                        HostWait(Config.Opt.dCollect)

                                        -- Do not let an EnsureLamps error prevent opening lamps.
                                        local okEnsure, ensureErr = pcall(EnsureLamps)
                                        if not okEnsure then logMsg("`4Ensure lamps error: `w" .. tostring(ensureErr)) end
                                        if stale() then return end

                                        local okOpen, openErr = pcall(OpenLamps)
                                        if not okOpen then logMsg("`4Open lamps error: `w" .. tostring(openErr)) end
                                        if stale() then return end
                                        HostWait(Config.Opt.dLamp)
                                        ReturnToStandSpot()
                                        if Sleep then Sleep(150) end
                                        if stale() then return end

                                        if lampValid(Positions.lamp1) and not Session.lamp1Live then
                                            logMsg("`4Lamp 1 may not have opened; check its configured tile")
                                        end
                                        if Session.is2R and lampValid(Positions.lamp2) and not Session.lamp2Live then
                                            logMsg("`4Lamp 2 may not have opened; check its configured tile")
                                        end

                                        if Session.step == "WAITING_PLAYER_SPIN" or Session.step == "WAITING_PLAYER_SPIN_2" then
                                            sendInstant(MsgT("spin1"))
                                            Session.lampsReady = true
                                        end
                                        CollectItems(db and db.x or 0, db and db.y or 0)
                                    end)
                                    hostSetupBusy = false
                                    if not okSetup then
                                        logMsg("`4Host setup error: `w" .. tostring(setupErr))
                                        -- Do not leave the player waiting silently if setup failed.
                                        if Session.active and not Session.onHold and Session.sessionToken == lampToken then
                                            sendInstant(MsgT("spin1"))
                                        end
                                    end
                                end)

                                StartTimer(Session.sessionToken, Config.Opt.spinTime, function()
                                    DoTimeout()
                                end)
                            end)
                        end
                        table.insert(Session.accumulatedBets, { id = id, amount = bet })
                        QuickConvert()
                        return false
                    end
                end
            end

            if Session.active and not Session.onHold and cleanTxt:lower():find("spun the wheel", 1, true) and not cleanTxt:find("%[FAKE") then
                local num = cleanTxt:match("and got (%d+)")
                local spinNetId = nil
                -- OnConsoleMessage is a server result event; map its player name back to a current netID.
                local spinWho = cleanTxt:match("^%s*(.-)%s+spun the wheel")
                if spinWho and GetPlayerList then
                    for _, p in pairs(GetPlayerList()) do
                        if p and SameName(p.name, spinWho) then
                            local uid = tonumber(p.userid or p.userID or p.user_id or p.uid)
                            if Session.playerUserId and uid then
                                if uid == tonumber(Session.playerUserId) then spinNetId = tonumber(p.netid) break end
                            elseif SameName(p.name, Session.playerName) then
                                spinNetId = tonumber(p.netid) break
                            end
                        end
                    end
                end
                if num then
                    local val = tonumber(num)
                    if IsPlayerSpin(cleanTxt, spinNetId) then

                        local st = Session.step
                        if (st == "WAITING_PLAYER_SPIN" or st == "WAITING_PLAYER_SPIN_2" or st == "WAITING_HOST_SPIN") and not Session.forced then
                            if CheckSpinRules() then return false end
                        end
                        AddHostLog("SPIN", cleanText(Session.playerName) .. " spun `6" .. val .. (Session.is2R and ((Session.step == "WAITING_PLAYER_SPIN") and " `7(room 1)" or " `7(room 2)") or ""))
                        if Session.step == "WAITING_PLAYER_SPIN" then
                            if Session.is2R then
                                Session.playerSpin1 = val
                                Session.step = "WAITING_PLAYER_SPIN_2"
                                Session.sessionToken = Session.sessionToken + 1
                                sendInstant(MsgT("spin2"))
                                StartTimer(Session.sessionToken, Config.Opt.spin2Time, function()
                                    DoTimeout()
                                end)
                                return false
                            else
                                Session.playerSpin1 = val
                                Session.step = "WAITING_HOST_SPIN"
                                Session.sessionToken = Session.sessionToken + 1
                                local hostSpinToken = Session.sessionToken
                                RunThread(function() HostWait(Config.Opt.dHostSpin); SpinHostWheelWithRetry(hostSpinToken) end)
                                return false
                            end
                        elseif Session.step == "WAITING_PLAYER_SPIN_2" then
                            Session.playerSpin2 = val
                            Session.step = "WAITING_HOST_SPIN"
                            Session.sessionToken = Session.sessionToken + 1
                            local hostSpinToken = Session.sessionToken
                            RunThread(function() HostWait(Config.Opt.dHostSpin); SpinHostWheelWithRetry(hostSpinToken) end)
                            return false
                        end
                    end

                    local localPlayer = GetLocal and GetLocal() or nil
                    local myName = localPlayer and cleanText(localPlayer.name):lower() or ""
                    if Session.step == "WAITING_HOST_SPIN" and myName ~= "" and ContainsName(cleanTxt, localPlayer.name) then
                        Session.hostSpin = val
                        RunThread(function() ReturnToStandSpot() end)
                        AddHostLog("SPIN", "Host spun `6" .. val)
                        Session.step = "EVALUATING"
                        Session.sessionToken = Session.sessionToken + 1

                        RunThread(function()
                            HostWait(Config.Opt.dResult)
                            if not Session.is2R then
                                OutcomeLamp1Only()
                                local hScore = GetScore(Session.mode, Session.hostSpin, false)
                                local pScore = GetScore(Session.mode, Session.playerSpin1, true)

                                if pScore == -1 then
                                    RunThread(function()
                                        if Sleep then Sleep(100) end
                                        sendInstant(Config.LoseMessage)
                                    end)
                                    HostLogs.totalGames = HostLogs.totalGames + 1
                                    HostLogs.totalLosses = HostLogs.totalLosses + 1
                                    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss + Session.betAmount
                                    LogGame("LOSS", 0, "P " .. ScoreText(pScore) .. " vs H " .. ScoreText(hScore))
                                elseif pScore > hScore then
                                    local mult = RoomMult(Session.mode, pScore)
                                    local total = Session.betAmount * mult
                                    RunThread(function()
                                        if Sleep then Sleep(100) end
                                        sendInstant(FormatWinMessage(total))
                                    end)
                                    DropPayout(total)
                                    HostLogs.totalGames = HostLogs.totalGames + 1
                                    HostLogs.totalWins = HostLogs.totalWins + 1
                                    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss - (total - Session.betAmount)
                                    LogGame("WIN", total, "P " .. ScoreText(pScore) .. " vs H " .. ScoreText(hScore))
                                else
                                    RunThread(function()
                                        if Sleep then Sleep(100) end
                                        sendInstant(Config.LoseMessage)
                                    end)
                                    HostLogs.totalGames = HostLogs.totalGames + 1
                                    HostLogs.totalLosses = HostLogs.totalLosses + 1
                                    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss + Session.betAmount
                                    LogGame("LOSS", 0, "P " .. ScoreText(pScore) .. " vs H " .. ScoreText(hScore))
                                end
                            else
                                local hScore = GetScore(Session.mode, Session.hostSpin, false)
                                local p1Score = GetScore(Session.mode, Session.playerSpin1, true)
                                local p2Score = GetScore(Session.mode, Session.playerSpin2, true)

                                local r1Valid = (p1Score ~= -1)
                                local r2Valid = (p2Score ~= -1)

                                local r1Win = r1Valid and (p1Score > hScore)
                                local r2Win = r2Valid and (p2Score > hScore)
                                local r1Lose = (p1Score < hScore) or (p1Score == hScore) or (p1Score == -1)
                                local r2Lose = (p2Score < hScore) or (p2Score == hScore) or (p2Score == -1)

                                local m1 = RoomMult(Session.mode, p1Score)
                                local m2 = RoomMult(Session.mode, p2Score)
                                local p1IsX3 = m1 > 2
                                local p2IsX3 = m2 > 2

                                if r1Lose and r2Lose then
                                    OutcomeLamp1Only()
                                    RunThread(function()
                                        if Sleep then Sleep(100) end
                                        sendInstant(Config.LoseMessage)
                                    end)
                                    HostLogs.totalGames = HostLogs.totalGames + 1
                                    HostLogs.totalLosses = HostLogs.totalLosses + 1
                                    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss + Session.betAmount
                                    LogGame("LOSS", 0, "both rooms lost")
                                elseif (r1Win and r2Lose) or (r1Lose and r2Win) then
                                    local winningSpinIsX3 = (r1Win and p1IsX3) or (r2Win and p2IsX3)
                                    if winningSpinIsX3 then

                                        local mult = (r1Win and m1 or m2)
                                        OutcomeLamp1Only()
                                        local total = math.floor(Session.betAmount * mult / 2)
                                        RunThread(function()
                                            if Sleep then Sleep(100) end
                                            sendInstant(FormatWinMessage(total))
                                        end)
                                        DropPayout(total)
                                        HostLogs.totalGames = HostLogs.totalGames + 1
                                        HostLogs.totalWins = HostLogs.totalWins + 1
                                        HostLogs.totalProfitLoss = HostLogs.totalProfitLoss - (total - Session.betAmount)
                                        LogGame("WIN", total, "1 special room")
                                    else

                                        ReturnToStandSpot()
                                        ResetTieLamps()
                                        HostWait(Config.Opt.dLamp)
                                        EnsureLamps()
                                        OpenLamps()
                                        ResetRoundPreserveGame()
                                        Session.step = "WAITING_PLAYER_SPIN"
                                        AddHostLog("RESET", cleanText(Session.playerName or "?") .. " won only 1 room, spin again")
                                        sendInstant(MsgT("spin1"))
                                        StartTimer(Session.sessionToken, Config.Opt.respinTime, function()
                                            DoTimeout()
                                        end)
                                        return
                                    end
                                elseif r1Win and r2Win then
                                    OutcomeLamp1Only()

                                    local mult = (m1 + m2) / 2

                                    local total = math.floor(Session.betAmount * mult)
                                    RunThread(function()
                                        if Sleep then Sleep(100) end
                                        sendInstant(FormatWinMessage(total))
                                    end)
                                    DropPayout(total)
                                    HostLogs.totalGames = HostLogs.totalGames + 1
                                    HostLogs.totalWins = HostLogs.totalWins + 1
                                    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss - (total - Session.betAmount)
                                    LogGame("WIN", total, "both rooms")
                                else
                                    OutcomeLamp1Only()
                                    RunThread(function()
                                        if Sleep then Sleep(100) end
                                        sendInstant(Config.LoseMessage)
                                    end)
                                    HostLogs.totalGames = HostLogs.totalGames + 1
                                    HostLogs.totalLosses = HostLogs.totalLosses + 1
                                    HostLogs.totalProfitLoss = HostLogs.totalProfitLoss + Session.betAmount
                                    LogGame("LOSS", 0, "2R")
                                end
                            end

                            local evalToken = Session.sessionToken
                            HostWait(Config.Opt.dNext)
                            if Session.active and not Session.onHold and Session.sessionToken == evalToken then
                                ResetRoundPreserveGame()
                                Session.step = "WAITING_BET"
                                RunThread(function()
                                    local resultToken = Session.sessionToken
                                    local modeTag = Session.mode:upper() .. " " .. (Session.is2R and "2R" or "1R")
                                    sendInstant(Config.DropBetMessage:format(modeTag), Config.Opt.dDrop)
                                    WaitPayout()
                                    if not Session.active or Session.sessionToken ~= resultToken then return end
                                    ReturnToStandSpot()
                                    if Sleep then Sleep(100) end
                                    StartTimer(Session.sessionToken, Config.Opt.betTime, function()
                                        DoTimeout()
                                    end)
                                end)
                            end
                        end)
                        return false
                    end
                end
            end
        end
    end
    return false
end)

AddHook("onvariant", "SPIN_BUBBLE", function(var)
    if not Guard() then return false end
    if not var or var[0] ~= "OnTalkBubble" or not Config.Opt.bubble or not Session.active then return false end
    local text = tostring(var[2] or "")
    if not text:find("spun the wheel", 1, true) or text:find("`w[`9", 1, true) then return false end
    local nid = tonumber(var[1])
    local me = GetLocal and GetLocal() or nil
    local isHost = me and nid == me.netid
    local isPlayer = nid == Session.playerNetId
    if not isHost and not isPlayer then return false end
    local n = tonumber(cleanText(text):match("and got (%d+)"))
    if not n then return false end
    local shown
    if Session.mode == "leme" then
        shown = math.floor(n / 10) + (n % 10)
    else
        shown = GetScore(Session.mode, n, isPlayer and not isHost)
    end
    SendVariantList({ [0] = "OnTalkBubble", [1] = var[1], [2] = text .. " `w[`9" .. tostring(shown) .. "`w]", [3] = var[3] })
    return true
end)

RunThread(function()
    local kicked = {}
    while true do
        if not Sleep then break end
        Sleep(2000)
        if Config.Opt.kickShadow and Session.active and Session.playerName and Session.playerNetId then
            local me = GetLocal and GetLocal() or nil
            for _, pl in pairs(GetPlayerList and GetPlayerList() or {}) do
                if pl and pl.netid and pl.netid ~= Session.playerNetId and not (me and pl.netid == me.netid)
                    and not kicked[pl.netid] and SameName(pl.name, Session.playerName) then
                    kicked[pl.netid] = true
                    KickPlayer(pl.netid)
                    AddHostLog("EXIT", "Kicked a shadow of " .. cleanText(Session.playerName))
                    logMsg("`4Kicked a shadow of `w" .. cleanText(Session.playerName))
                end
            end
        else
            kicked = {}
        end
    end
end)

AddHook("onvariant", "KICK_SHADOWS", function(var)
    if not Guard() then return false end
    if not var or var[0] ~= "OnSpawn" or not Config.Opt.kickShadow then return false end
    if not Session.active or not Session.playerName then return false end
    local info = tostring(var[1] or "")
    if info:find("type|local", 1, true) then return false end
    local nid = tonumber(info:match("netID|(%d+)"))
    local nm = info:match("name|([^\n]*)")
    if not nid or not nm or nid == Session.playerNetId then return false end
    if SameName(nm, Session.playerName) then
        local original = false
        for _, pl in pairs(GetPlayerList and GetPlayerList() or {}) do
            if pl and pl.netid == Session.playerNetId then original = true end
        end
        if original then
            KickPlayer(nid)
            AddHostLog("EXIT", "Kicked a shadow of " .. cleanText(Session.playerName))
        end
    end
    return false
end)

function WaitForLocalTile(tx, ty, timeoutMs)
    local elapsed = 0
    timeoutMs = timeoutMs or 4000
    while elapsed <= timeoutMs do
        local mx, my = GetMyPos()
        if mx == tx and my == ty then return true end
        if not Sleep then break end
        Sleep(200)
        elapsed = elapsed + 200
    end
    local mx, my = GetMyPos()
    return mx == tx and my == ty
end

function TeleportToPullSpot(pp)
    if not pp or not pp.x or not pp.y or (pp.x == 0 and pp.y == 0) then return false end
    local px, py = pp.x * 32, pp.y * 32
    -- Use only an actual setter exposed by the proxy. Growtopia's normal
    -- movement packet is not a guaranteed teleport, so verify our position.
    local setter = (type(setPos) == "function" and setPos) or
                   (type(SetPos) == "function" and SetPos) or
                   (type(SetPosition) == "function" and SetPosition)
    if setter then
        local ok, result = pcall(setter, px, py)
        if ok and result ~= false and WaitForLocalTile(pp.x, pp.y, 600) then return true end
    end
    -- Fallback: path to the pull spot and wait for the local player to arrive.
    MoveTo(pp.x, pp.y)
    return WaitForLocalTile(pp.x, pp.y, 5000)
end

function PullPlayerAtSpot(netid)
    if not netid then return false end
    local pp = Positions.pullSpot
    if pp and pp.x ~= 0 and pp.y ~= 0 then
        local arrived = TeleportToPullSpot(pp)
        if not arrived then
            DevLog("pull spot not reached; pull skipped to avoid pulling from the wrong position")
            return false
        end
        if Sleep then Sleep(250) end
    end
    -- Pull immediately after reaching the spot, with a short registration delay.
    PullPlayer(netid)
    if Sleep then Sleep(650) end
    return true
end

AddHook("onvariant", "PLAYER_RESPAWN_PULLBACK", function(var)
    if not Guard() then return false end
    if not var or var[0] ~= "OnSpawn" or not Session.active or not Session.playerName then return false end
    local info = tostring(var[1] or "")
    if info:find("type|local", 1, true) then return false end
    local nid = tonumber(info:match("netID|(%d+)"))
    local nm = info:match("name|([^\n]*)")
    local matches = (nid and Session.playerNetId and nid == tonumber(Session.playerNetId)) or (nm and PlayerMatchesSession({ netid = nid, name = nm }))
    if not matches then return false end
    local token = Session.sessionToken
    if (tonumber(Session.betAmount) or 0) > 0 then
        RunThread(function()
            if Sleep then Sleep(3000) end
            if Session.active and Session.sessionToken == token and Session.playerNetId then
                local ok = PullPlayerAtSpot(Session.playerNetId)
                -- Deliberately leave a pause after pulling before returning;
                -- this prevents an immediate snap-back race with the pull.
                if ok and Sleep then Sleep(1200) end
                if Session.active and Session.sessionToken == token then ReturnToStandSpot() end
            end
        end)
    else
        AddHostLog("EXIT", cleanText(Session.playerName) .. " respawned while no bet was active; session stopped")
        FullReset()
        sendInstant(MsgT("stopped"))
    end
    return false
end)

AddHook("onsendpacket", "REME_COMMAND_HOOK", function(type, packet)
    if not Guard() then return false end
    local cleanPacket = packet:gsub("action|input\n|text|", "")
    local msg = string.lower(cleanPacket)

    do
        local cmd, num = cleanPacket:match("^/(%a+)%s+(%d+)%s*$")
        num = tonumber(num)
        if cmd and num and num > 0 then
            cmd = cmd:lower()
            if cmd == "dw" then DropNeeds({ num, 0, 0, 0 }) return true
            elseif cmd == "dd" then DropNeeds({ 0, num, 0, 0 }) return true
            elseif cmd == "db" then DropNeeds({ 0, 0, num, 0 }) return true
            elseif cmd == "dbl" then DropNeeds({ 0, 0, 0, num }) return true
            elseif cmd == "dcw" then DropNeeds(SplitWL(num)) return true
            end
        end
        if cleanPacket:match("^/id%s*$") then
            local held = HeldItemId()
            local t1 = lampValid(Positions.lamp1) and TileFg(Positions.lamp1.x, Positions.lamp1.y) or nil
            local t2 = lampValid(Positions.lamp2) and TileFg(Positions.lamp2.x, Positions.lamp2.y) or nil
            logMsg("`wHolding: `6" .. tostring(held or "unknown") .. "   `wLamp 1: `6" .. tostring(t1 or "-") .. "   `wLamp 2: `6" .. tostring(t2 or "-"))
            return true
        end
    end
    local tx, ty = GetMyPos()

    if packet:find("action|dialog_return") then
        if packet:find("buttonClicked|btn_close_panel") then return true end

        local function has(name) return packet:find("dialog_name|" .. name, 1, true) ~= nil end
        local function btn(name) return packet:find("buttonClicked|" .. name, 1, true) ~= nil end
        local function chk(name) return packet:find(name .. "|1", 1, true) ~= nil end
        local function val(key) return packet:match(key .. "|([^\n]+)") end
        local function text(key) return packet:match(key .. "|([^\n]*)") end
        local function clamp(v, lo, hi)
            v = math.floor(v)
            if v < lo then v = lo end
            if v > hi then v = hi end
            return v
        end
        local function setNum(tbl, field, key, lo, hi)
            local v = tonumber(val(key))
            if v then tbl[field] = clamp(v, lo, hi) end
        end

        if not has("temp_set_menu") then ResetArm = nil end
        if not btn("btn_reset_sec") then SecArm = nil end

        if btn("btn_reset_sec") then
            for dname, info in pairs(SECRESET) do
                if has(dname) then
                    if SecArm == dname then
                        SecArm = nil
                        info.reset()
                        SaveConfigToFile()
                        logMsg("`4" .. info.name .. " reset")
                    else
                        SecArm = dname
                    end
                    M[info.show]()
                    return true
                end
            end
        end

        if btn("btn_back_main") then LastSec = nil M.main() return true end
        if btn("btn_back_sec") then if LastSec and M[LastSec] then M[LastSec]() else M.main() end return true end
        if btn("btn_back_set") then M.settings() return true end
        if btn("btn_back_logs") then M.logs() return true end

        local pages = {
            btn_nav_gameset = M.modes, btn_nav_pos = M.spots, btn_nav_limits = M.bets, btn_nav_msgs = M.texts,
            btn_nav_timers = M.timers, btn_nav_rules = M.rules, btn_nav_conv = M.convert, btn_nav_bank = M.bank,
            btn_nav_drop = M.drop, btn_nav_spam = M.spam, btn_nav_sb = M.sb, btn_nav_lamp = M.lamp,
            btn_nav_champ = function() logMsg("`4Champagne is [SOON]") M.auto() end, btn_nav_calc = M.calc, btn_nav_lang = M.lang,
            btn_nav_prof = M.profiles, btn_nav_hostopts = M.hostopts,
            btn_nav_dev = function() if IsDev() then M.dev() end end
        }
        if has("temp_main_menu") then
            local secs = { btn_sec_setup = "setup", btn_sec_locks = "locks", btn_sec_auto = "auto", btn_sec_tools = "tools" }
            for id, name in pairs(secs) do
                if btn(id) then LastSec = name M[name]() return true end
            end
            local top = { btn_nav_cmd = M.commands, btn_nav_set = M.settings, btn_nav_help = M.help, btn_nav_logs = M.logs, btn_nav_ctrl = M.control }
            for id, fn in pairs(top) do
                if btn(id) then LastSec = nil fn() return true end
            end
        end
        if has("temp_sec_menu") or has("temp_set_menu") then
            for id, fn in pairs(pages) do
                if btn(id) then fn() return true end
            end
        end

        if has("temp_logs_menu") then
            local filters = {
                view_log_all = "ALL", view_log_bet = "BET", view_log_spin = "SPIN", view_log_win = "WIN",
                view_log_loss = "LOSS", view_log_timeout = "TIMEOUT", view_log_exit = "EXIT",
                view_log_bank = "BANK"
            }
            for id, f in pairs(filters) do
                if btn(id) then M.sublog(f) return true end
            end
            if btn("btn_clear_logs") then
                HostLogs.entries = {}
                HostLogs.totalProfitLoss = 0
                HostLogs.totalGames = 0
                HostLogs.totalWins = 0
                HostLogs.totalLosses = 0
                HostLogs.totalTimeouts = 0
                HostLogs.totalBugs = 0
                SaveConfigToFile()
                logMsg("`4Logs cleared")
                M.logs()
                return true
            end
        end

        if has("temp_gameset_menu") and btn("btn_save_gameset") then
            Config.EnableReme = chk("chk_reme")
            Config.EnableQeme = chk("chk_qeme")
            Config.EnableLeme = chk("chk_leme")
            Config.Enable1R = chk("chk_1r")
            Config.Enable2R = chk("chk_2r")
            local dd = val("drop_direction")
            if dd then dd = dd:lower(); if dd == "left" or dd == "right" then Config.DropDirection = dd end end
            local tR = val("trig_reme") if tR then Config.TriggerReme = tR end
            local tQ = val("trig_qeme") if tQ then Config.TriggerQeme = tQ end
            local tL = val("trig_leme") if tL then Config.TriggerLeme = tL end
            local t2 = val("trig_2r") if t2 then Config.Trigger2R = t2 end
            local t1 = val("trig_1r") if t1 then Config.Trigger1R = t1 end
            Config.Msg = Config.Msg or {}
            local exitCommand = text("mode_exit_cmd")
            if exitCommand ~= nil and exitCommand ~= "" then Config.TriggerExit = exitCommand end
            SaveConfigToFile()
            logMsg("`2Modes saved")
            M.modes()
            return true
        end

        if has("temp_limits_menu") and btn("btn_save_limits") then
            local mn = tonumber(val("input_min_bet")) if mn then Config.MinBet = math.floor(mn) end
            local mx = tonumber(val("input_max_bet")) if mx then Config.MaxBet = math.floor(mx) end
            SaveConfigToFile()
            logMsg("`2Bet limits saved")
            M.bets()
            return true
        end

        if has("temp_msgs_menu") and btn("btn_save_msgs") then
            Config.Opt.talk = chk("chk_talk")
            local wm = text("input_win_msg") if wm then Config.WinMessage = wm end
            local lm = text("input_lose_msg") if lm then Config.LoseMessage = lm end
            local dm = text("input_drop_msg") if dm then Config.DropBetMessage = dm end
            for _, it in ipairs(MSG_ORDER) do
                local v = text("m_" .. it[1])
                if v then Config.Msg[it[1]] = v end
            end
            SaveConfigToFile()
            logMsg("`2Messages saved")
            M.texts()
            return true
        end

        if has("temp_timers_menu") and (btn("btn_pre_fast") or btn("btn_pre_norm")) then
            local pick = btn("btn_pre_fast") and TIMER_PRESETS.fast or TIMER_PRESETS.normal
            for k, v in pairs(pick) do Config.Opt[k] = v end
            SaveConfigToFile()
            logMsg("`2Delays set")
            M.timers()
            return true
        end

        if has("temp_timers_menu") and btn("btn_save_timers") then
            local O = Config.Opt
            setNum(O, "betTime", "opt_bet", 10, 900)
            setNum(O, "spinTime", "opt_spin", 15, 900)
            setNum(O, "spin2Time", "opt_spin2", 15, 900)
            setNum(O, "respinTime", "opt_respin", 15, 900)
            setNum(O, "rejoin", "opt_rejoin", 10, 900)
            O.warn10 = chk("chk_opt_warn")
            setNum(O, "dCollect", "opt_dcollect", 0, 10000)
            setNum(O, "dExtraBet", "opt_dextrabet", 0, 15000)
            setNum(O, "dLamp", "opt_dlamp", 0, 10000)
            setNum(O, "dHostSpin", "opt_dhost", 0, 10000)
            setNum(O, "dResult", "opt_dresult", 0, 10000)
            setNum(O, "dReset", "opt_dreset", 0, 10000)
            setNum(O, "dNext", "opt_dnext", 0, 10000)
            setNum(O, "dDrop", "opt_ddrop", 0, 10000)
            setNum(O, "dMsg", "opt_dmsg", 0, 10000)
            setNum(O, "dLampPunch", "opt_dlpunch", 0, 5000)
            setNum(O, "dLampGap", "opt_dlgap", 0, 5000)
            SaveConfigToFile()
            logMsg("`2Timers saved")
            for k, m in pairs(TIMER_MINS) do
                if (tonumber(O[k]) or 0) < m then
                    logMsg("`4Warning: some delays are very low, this can cause bugs")
                    break
                end
            end
            M.timers()
            return true
        end

        if has("temp_rules_menu") and btn("btn_save_rules") then
            local O = Config.Opt
            O.ruleOutside = chk("chk_rule_out")
            O.ruleLemeOut = chk("chk_rule_leme")
            O.ruleLamp = chk("chk_rule_lamp")
            O.ruleMulti = chk("chk_rule_multi")
            O.ruleDropDuringSpin = chk("chk_rule_drop_spin")
            O.bubble = chk("chk_opt_bubble")
            O.fastWheel = chk("chk_opt_fast")
            O.banFake = chk("chk_opt_ban")
            setNum(O, "spinRange", "opt_range", 1, 30)
            SaveConfigToFile()
            logMsg("`2Game rules saved")
            M.rules()
            return true
        end

        if has("temp_conv_menu") then
            local C = Config.Conv
            local function num(key, cur, lo, hi)
                local v = tonumber(val(key))
                if not v then return cur end
                return clamp(v, lo, hi)
            end
            C.auto = chk("chk_c_auto")
            C.afterBet = chk("chk_c_bet")
            C.idle = chk("chk_c_idle")
            C.up1 = chk("chk_c_up1")
            C.up2 = chk("chk_c_up2")
            C.up3 = chk("chk_c_up3")
            C.n1 = num("in_n1", C.n1, 0, 50)
            C.n2 = num("in_n2", C.n2, 0, 50)
            C.n3 = num("in_n3", C.n3, 0, 50)
            C.keep1 = num("in_keep1", C.keep1, 0, 999999)
            C.keep2 = num("in_keep2", C.keep2, 0, 999999)
            C.keep3 = num("in_keep3", C.keep3, 0, 999999)
            C.delay = num("in_delay", C.delay, 100, 5000)
            C.shatter = chk("chk_c_sh")
            C.sh2 = chk("chk_c_sh2")
            C.sh3 = chk("chk_c_sh3")
            C.sh4 = chk("chk_c_sh4")
            local ph = val("in_phone")
            if ph and ph:match("^%d+$") then C.phone = ph end
            C.hidePhone = chk("chk_c_hide")
            SaveConfigToFile()

            if btn("btn_conv_now") then
                RunThread(function() ConvertRound() end)
                logMsg("`2Converting...")
            elseif btn("btn_up1") then ConvertNow(1)
            elseif btn("btn_up2") then ConvertNow(2)
            elseif btn("btn_up3") then ConvertNow(3)
            elseif btn("btn_sh2") then ShatterNow(2)
            elseif btn("btn_sh3") then ShatterNow(3)
            elseif btn("btn_sh4") then ShatterNow(4)
            elseif btn("btn_save_conv") then
                logMsg("`2Convert settings saved")
            end
            M.convert()
            return true
        end

        if has("temp_bank_menu") then
            local B = Config.Bank
            B.on = chk("chk_bank_on")
            setNum(B, "trigger", "bank_trigger", 1, 999999)
            setNum(B, "amount", "bank_amount", 1, 999999)
            B.wdOn = chk("chk_bank_wd")
            setNum(B, "wdBelow", "bank_wdbelow", 0, 999999)
            setNum(B, "wdAmount", "bank_wdamount", 1, 999999)
            setNum(B, "manual", "bank_manual", 1, 999999)
            SaveConfigToFile()
            if btn("btn_bank_dep") then
                if BankDeposit(B.manual) then
                    logMsg("`2Deposit `e" .. B.manual .. " BGL")
                    AddHostLog("BANK", "Deposited `e" .. B.manual .. " BGL `7(manual)")
                end
            elseif btn("btn_bank_wd") then
                if BankWithdraw(B.manual) then
                    logMsg("`4Withdraw `e" .. B.manual .. " BGL")
                    AddHostLog("BANK", "Withdrew `e" .. B.manual .. " BGL `7(manual)")
                end
            elseif btn("btn_bank_save") then
                logMsg("`2Bank saved")
            end
            M.bank()
            return true
        end

        if has("temp_drop_menu") then
            local amt = tonumber(val("drop_amt"))
            CalcState.drop = amt and tostring(math.floor(amt)) or CalcState.drop
            if amt and amt >= 1 then
                amt = math.floor(amt)
                if btn("btn_drop_w") then DropNeeds({ amt, 0, 0, 0 })
                elseif btn("btn_drop_d") then DropNeeds({ 0, amt, 0, 0 })
                elseif btn("btn_drop_b") then DropNeeds({ 0, 0, amt, 0 })
                elseif btn("btn_drop_bl") then DropNeeds({ 0, 0, 0, amt })
                elseif btn("btn_drop_c") then DropNeeds(SplitWL(amt)) end
            end
            M.drop()
            return true
        end

        if has("temp_spam_menu") then
            local sm = text("input_spam_msg") if sm then Config.SpamMessage = sm end
            local sd = tonumber(val("input_spam_delay")) if sd then Config.SpamDelay = clamp(sd, 1, 3600) end
            Config.SpamRainbow = chk("chk_rainbow")
            Config.SpamRandomColor = chk("chk_random")
            Config.SpamIdleOnly = chk("chk_idle_only")
            if btn("btn_toggle_spam") then
                Config.AutoSpam = not Config.AutoSpam
                logMsg(Config.AutoSpam and "`2Spam started" or "`4Spam stopped")
            elseif btn("btn_save_spam") then
                logMsg("`2Spam saved")
            end
            SaveConfigToFile()
            M.spam()
            return true
        end

        if has("temp_sb_menu") then
            local C = Config.SB
            local t = text("sb_text") if t then C.text = t end
            setNum(C, "total", "sb_total", 1, 9999)
            setNum(C, "delay", "sb_delay", 5, 3600)
            C.idleOnly = chk("chk_sb_idle")
            if btn("btn_sb_toggle") then
                if C.on then
                    C.on = false
                    logMsg("`4SB stopped")
                elseif C.text == "" then
                    logMsg("`4Type an SB message first")
                else
                    C.on = true
                    SBRun.count = 0
                    logMsg("`2SB started")
                end
            elseif btn("btn_sb_save") then
                logMsg("`2SB saved")
            end
            SaveConfigToFile()
            M.sb()
            return true
        end

        if has("temp_lamp_menu") then
            local L = Config.Lamp
            L.auto = chk("chk_lamp_auto")
            setNum(L, "id", "lamp_id", 0, 99999)
            SaveConfigToFile()
            if btn("btn_lamp_place") then
                RunThread(function()
                    ReturnToStandSpot()
                    local keep = Session.is2R
                    Session.is2R = true
                    EnsureLamps()
                    Session.is2R = keep
                end)
            elseif btn("btn_lamp_read") then
                local t1 = lampValid(Positions.lamp1) and TileFg(Positions.lamp1.x, Positions.lamp1.y) or nil
                local t2 = lampValid(Positions.lamp2) and TileFg(Positions.lamp2.x, Positions.lamp2.y) or nil
                logMsg("`wHolding: `6" .. tostring(HeldItemId() or "unknown") .. "   `wLamp 1: `6" .. tostring(t1 or "-") .. "   `wLamp 2: `6" .. tostring(t2 or "-"))
            elseif btn("btn_lamp_save") then
                logMsg("`2Lamp saved")
            end
            M.lamp()
            return true
        end

        if has("temp_champ_menu") then
            local C = Config.Champ
            C.on = chk("chk_champ_on")
            setNum(C, "minBGL", "champ_min", 1, 99999)
            setNum(C, "cost", "champ_cost", 1, 9999)
            setNum(C, "id", "champ_id", 1, 999999)
            local cb = val("champ_btn") if cb then C.button = cb end
            SaveConfigToFile()
            if btn("btn_champ_test") then
                BuyAndUseChampagne()
            elseif btn("btn_champ_save") then
                logMsg("`2Champagne saved")
            end
            M.champ()
            return true
        end

        if has("temp_calc_menu") then
            CalcState.expr = text("calc_expr") or ""
            CalcState.err, CalcState.result = nil, nil
            if btn("btn_calc_go") then
                if CalcState.expr ~= "" then
                    local r, e = CalcEval(CalcState.expr)
                    CalcState.result, CalcState.err = r, e
                end
            end
            M.calc()
            return true
        end

        if has("temp_ctrl_menu") then
            if btn("btn_hold_game") then
                if Session.active and not Session.onHold then Session.onHold = true Session.heldStep = Session.step logMsg("`1Game paused") else logMsg("`4No active game") end
            elseif btn("btn_continue_game") then
                if Session.active and Session.onHold then Session.onHold = false Session.step = Session.heldStep logMsg("`3Game resumed") else logMsg("`4No paused game") end
            elseif btn("btn_stop_game") then
                StopGame()
                logMsg("`4Game stopped")
            end
            M.control()
            return true
        end

        if has("temp_lang_menu") then
            for _, lg in ipairs(LANG_LIST) do
                if btn("btn_lang_" .. lg[1]) then
                    Config.Opt.lang = lg[1]
                    if chk("chk_lang_msgs") then ApplyLangMessages(lg[1]) end
                    SaveConfigToFile()
                    logMsg("`2Language: " .. lg[2])
                end
            end
            M.lang()
            return true
        end

        if has("temp_backup_menu") then
            if btn("btn_import") then
                local ok, res = ImportCode(text("backup_paste"))
                logMsg(ok and ("`2Imported " .. tostring(res) .. " settings") or ("`4Import failed: " .. tostring(res)))
            end
            M.backup()
            return true
        end

        if btn("btn_back_dev") then if IsDev() then M.dev() end return true end

        if has("temp_dev_menu") or has("temp_devbugs_menu") then
            if not IsDev() then return true end
            local O = Config.Opt
            if has("temp_devbugs_menu") then
                if btn("btn_clear_bugs") then
                    local keep = {}
                    for _, e in ipairs(HostLogs.entries) do if e.type ~= "BUG" then keep[#keep + 1] = e end end
                    HostLogs.entries = keep
                    HostLogs.totalBugs = 0
                    SaveConfigToFile()
                end
                M.devbugs()
                return true
            end
            O.debug = chk("chk_dev_debug")
            setNum(O, "spinRange", "dev_range", 1, 30)
            if btn("btn_dev_bugs") then M.devbugs() return true end
            if btn("btn_dev_dump") then
                local st = Session
                logMsg("`3[dev] `wstep " .. tostring(st.step) .. " mode " .. tostring(st.mode) .. (st.is2R and " 2R" or " 1R") .. " spins " .. tostring(st.spinCount))
                logMsg("`3[dev] `wlamps " .. tostring(st.lamp1On) .. "/" .. tostring(st.lamp2On) .. " live " .. tostring(st.lamp1Live) .. "/" .. tostring(st.lamp2Live) .. " gate " .. tostring(st.gateOpen) .. " ready " .. tostring(st.lampsReady))
                logMsg("`3[dev] `wplayer " .. cleanText(st.playerName or "-") .. " net " .. tostring(st.playerNetId) .. " bet " .. tostring(st.betAmount) .. " forced " .. tostring(st.forced))
            elseif btn("btn_dev_lampon") then RunThread(function() SetLamps(true, true) end)
            elseif btn("btn_dev_lampoff") then RunThread(CloseLamps)
            elseif btn("btn_dev_gate") then RunThread(ForceGate)
            elseif btn("btn_dev_stop") then if Session.active then FullReset() end
            end
            SaveConfigToFile()
            M.dev()
            return true
        end

        if has("temp_prof_menu") then
            for i = 1, 3 do
                local nm = text("prof_name" .. i)
                if nm then
                    nm = nm:gsub("[|\r\n]", " "):sub(1, 16)
                    if nm ~= "" then Config.Prof[i].name = nm end
                end
            end
            for i = 1, 3 do
                if btn("btn_prof_load" .. i) then
                    local ok, err = ProfileLoad(i)
                    logMsg(ok and ("`2Loaded preset `w" .. Config.Prof[i].name) or ("`4Could not load: " .. tostring(err)))
                elseif btn("btn_prof_save" .. i) then
                    ProfileSave(i)
                    logMsg("`2Saved your settings in preset `w" .. Config.Prof[i].name)
                end
            end
            SaveConfigToFile()
            M.profiles()
            return true
        end

        if has("temp_hostopts_menu") then
            local O = Config.Opt
            O.kickShadow = chk("chk_ho_shadow")
            O.modfly = chk("chk_ho_modfly")
            if not O.modfly and ChangeValue then pcall(ChangeValue, "[C] Modfly", false) end
            ApplyModfly()
            SaveConfigToFile()
            if btn("btn_save_hostopts") then logMsg("`2Host options saved") end
            M.hostopts()
            return true
        end

        if has("temp_set_menu") then
            local O = Config.Opt
            local tg = text("opt_tag")
            if tg and tg ~= "" then O.tag = tg end
            setNum(O, "autosave", "opt_auto", 0, 3600)

            if btn("btn_save_all") then
                ResetArm = nil
                if SaveConfigToFile() then logMsg("`2Saved") end
            elseif btn("btn_nav_backup") then
                M.backup()
                return true
            elseif btn("btn_reload") then
                ResetArm = nil
                local ok, err = ReloadConfig()
                logMsg(ok and "`2Reloaded from file" or ("`4Reload failed: " .. tostring(err)))
            elseif btn("btn_reset_set") then
                if ResetArm == "set" then
                    ResetArm = nil
                    ResetConfig(false)
                    logMsg("`4Settings reset (spots and logs kept)")
                else
                    ResetArm = "set"
                end
            elseif btn("btn_reset_all") then
                if ResetArm == "all" then
                    ResetArm = nil
                    ResetConfig(true)
                    logMsg("`4Everything reset")
                else
                    ResetArm = "all"
                end
            else
                ResetArm = nil
                SaveConfigToFile()
            end
            M.settings()
            return true
        end
    end

    if msg:find("/pwheel1") then
        Positions.playerWheel1 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Player wheel 1 set!")
        return false
    elseif msg:find("/pwheel2") then
        Positions.playerWheel2 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Player wheel 2 set!")
        return false
    elseif msg:find("/dev", 1, true) and IsDev() then
        M.dev()
        return true
    elseif msg:find("/wheel1") then
        Positions.hostWheel1 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Host Wheel 1 set!")
        return false
    elseif msg:find("/wheel2") then
        Positions.hostWheel2 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Host Wheel 2 set!")
        return false
    elseif msg:find("/displaybox2") then
        Positions.displayBox2 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Display Box 2 set!")
        return false
    elseif msg:find("/displaybox") then
        Positions.displayBox = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Display Box set!")
        return false
    elseif msg:find("/standspot") then
        Positions.standSpot = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Stand Spot set!")
        ReturnToStandSpot()
        return false
    elseif msg:find("/pullspot") then
        Positions.pullSpot = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Pull Spot set!")
        return false
    elseif msg:find("/dropspot") then
        Positions.dropSpot = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Drop Spot set!")
        return false
    elseif msg:find("/lamp1") then
        Positions.lamp1 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Lamp 1 set!")
        return false
    elseif msg:find("/lamp2") then
        Positions.lamp2 = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Lamp 2 set!")
        return false
    elseif msg:find("/gate", 1, true) then
        if lampValid(Positions.doorGate) then
            RunThread(function()
                ForceGate()
                logMsg(Session.gateOpen and "`2Gate: open" or "`4Gate: closed")
            end)
        else
            logMsg("`4Set the gate first with /dgate")
        end
        return true
    elseif msg:find("/dgate") then
        Positions.doorGate = { x = tx, y = ty }
        SaveConfigToFile()
        logMsg("`3Dragon Gate set!")
        return false
    elseif msg:find("/hold") then
        if Session.active and not Session.onHold then
            Session.onHold = true
            Session.heldStep = Session.step
            logMsg("`1Game paused. Use `0/continue`1 to resume.")
        else
            logMsg("`4No active session to hold.")
        end
        return true
    elseif msg:find("/continue") then
        if Session.active and Session.onHold then
            Session.onHold = false
            Session.step = Session.heldStep

            local O = Config.Opt
            local resumeDur = ({ WAITING_BET = O.betTime, WAITING_PLAYER_SPIN = O.spinTime, WAITING_PLAYER_SPIN_2 = O.spin2Time })[Session.step]
            if resumeDur then
                StartTimer(Session.sessionToken, tonumber(resumeDur) or 30, function() DoTimeout() end)
            end
            logMsg("`3Game resumed.")
        else
            logMsg("`4No paused session to continue.")
        end
        return true
    elseif msg:find("/menu") then
        ShowMainTempMenu()
        return true
    elseif msg:find("/commands") then
        ShowCommandsHelpMenu()
        return true
    elseif msg:find("/stop") then
        StopGame()
        logMsg("`4Game stopped.")
        return true
    elseif msg == "/db" then
        Config.Bank = Config.Bank or {}
        local enable = not (Config.Bank.on or Config.Bank.wdOn)
        Config.Bank.on = enable
        Config.Bank.wdOn = enable
        SaveConfigToFile()
        logMsg(enable and "`2Auto bank deposits and withdrawals enabled." or "`4Auto bank deposits and withdrawals disabled.")
        return true
    elseif msg:match("^/depo%s+%d+$") then
        local amount = tonumber(cleanPacket:match("^/depo%s+(%d+)$"))
        if amount and amount > 0 then
            local before = lockCount(3)
            local ok = BankDeposit(amount)
            if ok and waitCount(3, before, false) then
                logMsg("`2Banked `w" .. amount .. " BGL")
                AddHostLog("BANK", "Deposited `e" .. amount .. " BGL `7(manual command)")
            else
                logMsg(ok and "`4Bank deposit not confirmed; check balance and bank dialog." or "`4Invalid deposit amount.")
            end
        else
            logMsg("`4Usage: /depo <BGL amount>")
        end
        return true
    elseif msg:match("^/wd%s+%d+$") then
        local amount = tonumber(cleanPacket:match("^/wd%s+(%d+)$"))
        if amount and amount > 0 then
            local before = lockCount(3)
            local ok = BankWithdraw(amount)
            if ok and waitCount(3, before, true) then
                logMsg("`2Withdrew `w" .. amount .. " BGL")
                AddHostLog("BANK", "Withdrew `e" .. amount .. " BGL `7(manual command)")
            else
                logMsg(ok and "`4Bank withdrawal not confirmed; check bank balance and dialog." or "`4Invalid withdrawal amount.")
            end
        else
            logMsg("`4Usage: /wd <BGL amount>")
        end
        return true
    elseif msg:match("^/exitmsg") then
        local t = cleanPacket:match("^/exitmsg%s?(.*)$") or ""
        Config.Msg = Config.Msg or {}
        Config.Msg.exitok = t
        SaveConfigToFile()
        logMsg(t == "" and "`2Exit message cleared." or "`2Exit message updated.")
        return true
    elseif msg:find("/min ") then
        local val = tonumber(cleanPacket:match("/min%s+(%d+)"))
        if val then
            Config.MinBet = val
            SaveConfigToFile()
            logMsg("`2Minimum bet set to: `w" .. val .. " WL")
        end
        return true
    elseif msg:find("/max ") then
        local val = tonumber(cleanPacket:match("/max%s+(%d+)"))
        if val then
            Config.MaxBet = val
            SaveConfigToFile()
            logMsg("`2Maximum bet set to: `w" .. (val == 0 and "No Max" or val .. " WL"))
        end
        return true
    elseif msg:find("/enablespam") then
        Config.AutoSpam = true
        SaveConfigToFile()
        logMsg("`cAuto spam enabled!")
        return true
    elseif msg:find("/disablespam") then
        Config.AutoSpam = false
        SaveConfigToFile()
        logMsg("`cAuto spam disabled!")
        return true
    elseif msg:find("/enablereme") then
        Config.EnableReme = true
        SaveConfigToFile()
        logMsg("`cReme mode enabled!")
        return true
    elseif msg:find("/disablereme") then
        Config.EnableReme = false
        SaveConfigToFile()
        logMsg("`cReme mode disabled!")
        return true
    elseif msg:find("/enableqeme") then
        Config.EnableQeme = true
        SaveConfigToFile()
        logMsg("`cQeme mode enabled!")
        return true
    elseif msg:find("/disableqeme") then
        Config.EnableQeme = false
        SaveConfigToFile()
        logMsg("`cQeme mode disabled!")
        return true
    elseif msg:find("/enableleme") then
        Config.EnableLeme = true
        SaveConfigToFile()
        logMsg("`cLeme mode enabled!")
        return true
    elseif msg:find("/disableleme") then
        Config.EnableLeme = false
        SaveConfigToFile()
        logMsg("`cLeme mode disabled!")
        return true
    elseif msg:find("/enable2r") then
        Config.Enable2R = true
        SaveConfigToFile()
        logMsg("`c2R mode enabled!")
        return true
    elseif msg:find("/disable2r") then
        Config.Enable2R = false
        SaveConfigToFile()
        logMsg("`c2R mode disabled!")
        return true
    elseif msg:find("/reme ") then
        local t = cleanPacket:match("/reme%s+(.+)")
        if t then Config.TriggerReme = t SaveConfigToFile() logMsg("`2Reme trigger updated to: `w" .. t) end
        return true
    elseif msg:find("/qeme ") then
        local t = cleanPacket:match("/qeme%s+(.+)")
        if t then Config.TriggerQeme = t SaveConfigToFile() logMsg("`2Qeme trigger updated to: `w" .. t) end
        return true
    elseif msg:find("/leme ") then
        local t = cleanPacket:match("/leme%s+(.+)")
        if t then Config.TriggerLeme = t SaveConfigToFile() logMsg("`2Leme trigger updated to: `w" .. t) end
        return true
    elseif msg:find("/2r ") then
        local t = cleanPacket:match("/2r%s+(.+)")
        if t then Config.Trigger2R = t SaveConfigToFile() logMsg("`22R trigger updated to: `w" .. t) end
        return true
    elseif msg:find("/1r ") then
        local t = cleanPacket:match("/1r%s+(.+)")
        if t then Config.Trigger1R = t SaveConfigToFile() logMsg("`21R switch trigger updated to: `w" .. t) end
        return true
    elseif msg:find("/winmsg ") then
        local t = cleanPacket:match("/winmsg%s+(.+)")
        if t then Config.WinMessage = t SaveConfigToFile() logMsg("`2Win message updated!") end
        return true
    elseif msg:find("/losemsg ") then
        local t = cleanPacket:match("/losemsg%s+(.+)")
        if t then Config.LoseMessage = t SaveConfigToFile() logMsg("`2Lose message updated!") end
        return true
    elseif msg:find("/dropbetmsg ") then
        local t = cleanPacket:match("/dropbetmsg%s+(.+)")
        if t then Config.DropBetMessage = t SaveConfigToFile() logMsg("`2Drop bet message updated!") end
        return true
    elseif msg:find("/spammsg ") then
        local t = cleanPacket:match("/spammsg%s+(.+)")
        if t then Config.SpamMessage = t SaveConfigToFile() logMsg("`2Spam message updated!") end
        return true
    elseif msg:find("/spamtimer ") then
        local secs = tonumber(cleanPacket:match("/spamtimer%s+(%d+)"))
        if secs then Config.SpamDelay = secs SaveConfigToFile() logMsg("`2Spam timer set!") end
        return true
    elseif msg:find("/resetconfig") then
        ResetConfig(false)
        for k in pairs(Positions) do Positions[k] = { x = 0, y = 0 } end
        SaveConfigToFile()
        logMsg("`4Config reset to default!")
        return true
    end

    return false
end)

RunThread(function()
    while true do
        if not Sleep then break end
        Sleep(5000)
        pcall(ApplyModfly)
    end
end)
ApplyModfly()
ShowMainTempMenu()
logMsg("`2Host ready. `wType /menu to open the panel, /commands for the command list.")
