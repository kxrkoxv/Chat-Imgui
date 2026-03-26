script_name('Chat MImGui')
script_version_number(1)
script_author('kxrko')

-- ============================================================
--  DEPENDENCIAS
-- ============================================================
local imgui    = require 'mimgui'
local memory   = require 'memory'
local ffi      = require 'ffi'
local bit      = require 'bit'
local encoding = require 'encoding'

encoding.default = 'CP1252'
local u8 = encoding.UTF8

-- ============================================================
--  FFI
-- ============================================================
ffi.cdef [[
    int   VirtualProtect(void* lpAddress, unsigned long dwSize, unsigned long flNewProtect, unsigned long* lpflOldProtect);
    void* VirtualAlloc(void* lpAddress, unsigned long dwSize, unsigned long flAllocationType, unsigned long flProtect);
    int   VirtualFree(void* lpAddress, unsigned long dwSize, unsigned long dwFreeType);

    struct stChatEntry {
        uint32_t SystemTime;
        char     szPrefix[28];
        char     szText[144];
        uint8_t  unknown[64];
        int      iType;
        int      clTextColor;
        int      clPrefixColor;
    } __attribute__((packed));

    typedef struct stChatInfoMin {
        struct stChatEntry chatEntry[100];
    } chatInfoMin;

    typedef void(__cdecl *CMDPROC)(char *);
    struct stInputInfo {
        void    *pD3DDevice;
        void    *pDXUTDialog;
        struct   stInputBox *pDXUTEditBox;
        CMDPROC  pCMDs[144];
        char     szCMDNames[144][33];
        int      iCMDCount;
        int      iInputEnabled;
        char     szInputBuffer[129];
        char     szRecallBufffer[10][129];
        char     szCurrentBuffer[129];
        int      iCurrentRecall;
        int      iTotalRecalls;
        CMDPROC  pszDefaultCMD;
    } __attribute__((packed));

    typedef char CHAR;
    typedef CHAR *PCHAR;
    int  GetLocaleInfoA(int Locale, int LCType, PCHAR lpLCData, int cchData);
    bool GetKeyboardLayoutNameA(char* pwszKLID);
]]

-- ============================================================
--  SQLITE3
-- ============================================================
local sqlite_path = getWorkingDirectory() .. '\\lib\\sqlite3.dll'
local _sq = ffi.load(sqlite_path)
ffi.cdef [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    int    sqlite3_open(const char *filename, sqlite3 **ppDb);
    int    sqlite3_close(sqlite3 *db);
    int    sqlite3_exec(sqlite3 *db, const char *sql, void *cb, void *arg, char **errmsg);
    int    sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
    int    sqlite3_step(sqlite3_stmt *pStmt);
    int    sqlite3_finalize(sqlite3_stmt *pStmt);
    int    sqlite3_reset(sqlite3_stmt *pStmt);
    int    sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void*);
    int    sqlite3_bind_double(sqlite3_stmt*, int, double);
    int    sqlite3_bind_int(sqlite3_stmt*, int, int);
    const unsigned char* sqlite3_column_text(sqlite3_stmt*, int iCol);
    double sqlite3_column_double(sqlite3_stmt*, int iCol);
    int    sqlite3_column_int(sqlite3_stmt*, int iCol);
    int    sqlite3_column_count(sqlite3_stmt *pStmt);
    const char* sqlite3_column_name(sqlite3_stmt*, int N);
    int64_t sqlite3_last_insert_rowid(sqlite3*);
    void   sqlite3_free(void*);
]]
local SQLITE_ROW  = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast('void*', -1)

local db = ffi.new('sqlite3*[1]')
local DB_PATH

local function db_exec(sql)
    local err = ffi.new('char*[1]')
    local rc = _sq.sqlite3_exec(db[0], sql, nil, nil, err)
    if rc ~= 0 and err[0] ~= nil then
        print('[ChatDB] ERROR: ' .. ffi.string(err[0]))
        _sq.sqlite3_free(err[0])
    end
    return rc == 0
end

local function db_open(path)
    if _sq.sqlite3_open(path, db) ~= 0 then
        print('[ChatDB] No se pudo abrir: ' .. path)
        return false
    end
    db_exec('PRAGMA journal_mode=WAL;')
    db_exec('PRAGMA synchronous=NORMAL;')
    db_exec([[
        CREATE TABLE IF NOT EXISTS config (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
    ]])
    return true
end

local stmt_set, stmt_get

local function db_prepare_stmts()
    stmt_set = ffi.new('sqlite3_stmt*[1]')
    stmt_get = ffi.new('sqlite3_stmt*[1]')
    _sq.sqlite3_prepare_v2(db[0],
        'INSERT OR REPLACE INTO config(key,value) VALUES(?,?);',
        -1, stmt_set, nil)
    _sq.sqlite3_prepare_v2(db[0],
        'SELECT value FROM config WHERE key=?;',
        -1, stmt_get, nil)
end

local function db_set(key, value)
    _sq.sqlite3_reset(stmt_set[0])
    _sq.sqlite3_bind_text(stmt_set[0], 1, key,   -1, SQLITE_TRANSIENT)
    _sq.sqlite3_bind_text(stmt_set[0], 2, value, -1, SQLITE_TRANSIENT)
    _sq.sqlite3_step(stmt_set[0])
end

local function db_get(key)
    _sq.sqlite3_reset(stmt_get[0])
    _sq.sqlite3_bind_text(stmt_get[0], 1, key, -1, SQLITE_TRANSIENT)
    if _sq.sqlite3_step(stmt_get[0]) == SQLITE_ROW then
        return ffi.string(_sq.sqlite3_column_text(stmt_get[0], 0))
    end
    return nil
end

-- ============================================================
--  DEBOUNCE DE GUARDADO
-- ============================================================
local SAVE_DELAY  = 800
local _dirty      = {}
local _dirtyTimer = 0

local function markDirty(key, value)
    _dirty[key]  = value
    _dirtyTimer  = os.clock() * 1000
end

local function flushDirty()
    if next(_dirty) == nil then return end
    local now = os.clock() * 1000
    if now - _dirtyTimer < SAVE_DELAY then return end
    db_exec('BEGIN;')
    for k, v in pairs(_dirty) do db_set(k, v) end
    db_exec('COMMIT;')
    _dirty = {}
end

-- ============================================================
--  HOOK SYSTEM
-- ============================================================
local hook = { hooks = {} }

function hook.new(cast, callback, hook_addr, size, trampoline, org_bytes_tramp)
    size = size or 5
    trampoline = trampoline or false
    local new_hook, mt = {}, {}
    local detour_addr = tonumber(ffi.cast('intptr_t', ffi.cast('void*', ffi.cast(cast, callback))))
    local void_addr   = ffi.cast('void*', hook_addr)
    local old_prot    = ffi.new('unsigned long[1]')
    local org_bytes   = ffi.new('uint8_t[?]', size)
    ffi.copy(org_bytes, void_addr, size)

    if trampoline then
        local alloc_addr = ffi.gc(
            ffi.C.VirtualAlloc(nil, size + 5, 0x1000, 0x40),
            function(addr) ffi.C.VirtualFree(addr, 0, 0x8000) end
        )
        local trampoline_bytes = ffi.new('uint8_t[?]', size + 5, 0x90)
        if org_bytes_tramp then
            local bytes = {}
            for byte in org_bytes_tramp:gmatch('(%x%x)') do
                table.insert(bytes, tonumber(byte, 16))
            end
            trampoline_bytes = ffi.new('uint8_t[?]', size + 5, bytes)
        else
            ffi.copy(trampoline_bytes, org_bytes, size)
        end
        trampoline_bytes[size] = 0xE9
        ffi.cast('uint32_t*', trampoline_bytes + size + 1)[0] =
            hook_addr - tonumber(ffi.cast('intptr_t', ffi.cast('void*', ffi.cast(cast, alloc_addr)))) - size
        ffi.copy(alloc_addr, trampoline_bytes, size + 5)
        new_hook.call = ffi.cast(cast, alloc_addr)
        mt = { __call = function(self, ...) return self.call(...) end }
    else
        new_hook.call = ffi.cast(cast, hook_addr)
        mt = { __call = function(self, ...)
            self.stop()
            local res = self.call(...)
            self.start()
            return res
        end }
    end

    local hook_bytes = ffi.new('uint8_t[?]', size, 0x90)
    hook_bytes[0] = 0xE9
    ffi.cast('uint32_t*', hook_bytes + 1)[0] = detour_addr - hook_addr - 5

    new_hook.status = false
    local function set_status(bool)
        new_hook.status = bool
        ffi.C.VirtualProtect(void_addr, size, 0x40, old_prot)
        ffi.copy(void_addr, bool and hook_bytes or org_bytes, size)
        ffi.C.VirtualProtect(void_addr, size, old_prot[0], old_prot)
    end
    new_hook.stop  = function() set_status(false) end
    new_hook.start = function() set_status(true)  end
    new_hook.start()

    table.insert(hook.hooks, new_hook)
    return setmetatable(new_hook, mt)
end

-- ============================================================
--  ESTADO GLOBAL
-- ============================================================
local MAX_MESSAGES     = 500
local SAMP_INPUT_LIMIT = 128

local messages    = {}
local sendHistory = {}

local openChat    = false
local openColor   = 0
local scrollbar   = imgui.new.int(0)
local noScroll    = false
local max_scroll, current_scroll, setup_current_scroll = 0, 0, 0

local lastHistoryIdx = 0
local unreadCount    = 0

local INPUT_BUF  = 512
local inputChat  = imgui.new.char[INPUT_BUF]()
local chatInputActive   = false
local _needsFocus       = false
local contextMenuOpen   = false
local contextMenuId     = nil
local _pendingContextMenu = false
local _selPreviewActive  = false
local _selPreviewTimeout = 0

local timestampStatus = true
local showChat        = true
local searchActive    = false
local searchBuf       = imgui.new.char[256]()
local searchResults   = {}

local editLine  = imgui.new.char[512]()
local editColor = imgui.new.char[10]()
local editTime  = imgui.new.char[12]()
local editId    = 1

local layout = ffi.new('char[10]')
local info   = ffi.new('char[10]')

-- ============================================================
--  Sistema de Filtros
-- ============================================================
local filterMode          = imgui.new.int(0)
local filterModeNames     = imgui.new['const char*'][4]({'Todos', 'Chat (tipo 2)', 'Sistema (tipo 1)', 'Server (tipo 0)'})
local filterTextBuf       = imgui.new.char[256]()
local filterColorBuf      = imgui.new.char[8]()
local filterPrefixBuf     = imgui.new.char[64]()
local filterTimeFromBuf   = imgui.new.char[10]()
local filterTimeToBuf     = imgui.new.char[10]()
local filterCaseSensitive = imgui.new.bool(false)
local filterInvert        = imgui.new.bool(false)
local filterEnabled       = false

local function timeToSec(s)
    local h, m = s:match('^(%d%d):(%d%d)$')
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60
end

local function msgTimeSec(m)
    local h, mn, s = (m.timestamp or ''):match('%[(%d%d):(%d%d):(%d%d)%]')
    if not h then return nil end
    return tonumber(h)*3600 + tonumber(mn)*60 + tonumber(s)
end

local function msgPassesFilter(m)
    local pass = true
    if not filterEnabled then return true end

    local mode = filterMode[0]
    if mode == 1 and m.msgType ~= 2 then pass = false end
    if mode == 2 and m.msgType ~= 1 then pass = false end
    if mode == 3 and m.msgType ~= 0 then pass = false end

    if pass then
        local ft = ffi.string(filterTextBuf)
        if ft ~= '' then
            local haystack = u8:decode(m.text)
            if not filterCaseSensitive[0] then
                ft       = ft:lower()
                haystack = haystack:lower()
            end
            if not haystack:find(ft, 1, true) then pass = false end
        end
    end

    if pass then
        local fp = ffi.string(filterPrefixBuf)
        if fp ~= '' then
            local hay = u8:decode(m.text)
            if not filterCaseSensitive[0] then fp = fp:lower(); hay = hay:lower() end
            if not hay:find(fp, 1, true) then pass = false end
        end
    end

    if pass then
        local fc = ffi.string(filterColorBuf):upper()
        if fc ~= '' then
            local msgClr = m.color:match('{(%x+)}') or ''
            if not msgClr:upper():find(fc, 1, true) then pass = false end
        end
    end

    if pass then
        local tf = ffi.string(filterTimeFromBuf)
        local tt = ffi.string(filterTimeToBuf)
        local sfrom = timeToSec(tf)
        local sto   = timeToSec(tt)
        local smsg  = msgTimeSec(m)
        if smsg and sfrom and smsg < sfrom then pass = false end
        if smsg and sto   and smsg > sto   then pass = false end
    end

    if filterInvert[0] then pass = not pass end
    return pass
end

-- ============================================================
--  TABLA DE COLORES
-- ============================================================
local C = {}

local function makeColor(r, g, b, a)
    local flt = imgui.new.float[4](r, g, b, a)
    local vec = imgui.ImVec4(r, g, b, a)
    return { vec = vec, flt = flt }
end

local function syncVec(entry)
    entry.vec.x = entry.flt[0]
    entry.vec.y = entry.flt[1]
    entry.vec.z = entry.flt[2]
    entry.vec.w = entry.flt[3]
end

local function fltToStr(flt)
    return string.format('%.4f|%.4f|%.4f|%.4f', flt[0], flt[1], flt[2], flt[3])
end

local chatLines, chatLinesInt
local fontSize
local fonts, fontsArray, fontSelected
local fontChanged, fontSizeChanged = false, false
local showSettings

-- ============================================================
--  VALORES DEFAULT
-- ============================================================
local DEFAULTS = {
    ['color.chat_bg']          = '0.0000|0.0000|0.0000|0.0000',
    ['color.input_bg']         = '0.0000|0.0000|0.0000|0.9700',
    ['color.border']           = '0.0000|0.0000|0.0000|0.0000',
    ['color.text_color']       = '0.8800|0.9200|1.0000|1.0000',
    ['color.timestamp']        = '1.0000|1.0000|1.0000|0.8500',
    ['color.unread']           = '0.5373|0.0000|1.0000|1.0000',
    ['color.btn']              = '0.0000|0.0000|0.0000|1.0000',
    ['color.btn_hov']          = '0.2985|0.0000|0.2762|1.0000',
    ['color.btn_act']          = '0.0000|0.0000|0.0000|1.0000',
    ['color.scroll_bg']        = '9.8672e-07|9.9211e-07|9.9999e-07|0.5400',
    ['color.scroll_grab']      = '0.0000|0.0000|0.0000|1.0000',
    ['color.scroll_grab_act']  = '0.0000|0.0000|0.0000|1.0000',
    ['color.scroll_hov']       = '9.9998e-07|9.9999e-07|9.9999e-07|0.4000',
    ['color.scroll_act']       = '0.3880|0.0000|1.0000|0.7500',
    ['color.sel_normal']       = '0.2000|0.3000|0.5000|0.4000',
    ['color.sel_hovered']      = '0.3000|0.4000|0.7000|0.5000',
    ['val.font_size']          = '15',
    ['val.font_name']          = 'arialbd.ttf',
    ['val.line_count']         = '15',
    ['val.max_msgs']           = '500',
    ['val.timestamp']          = '1',
    ['filter.mode']            = '0',
    ['filter.text']            = '',
    ['filter.color']           = '',
    ['filter.prefix']          = '',
    ['filter.time_from']       = '',
    ['filter.time_to']         = '',
    ['filter.case_sensitive']  = '0',
    ['filter.invert']          = '0',
    ['filter.enabled']         = '0',
}

local function cfgGet(key)
    return db_get(key) or DEFAULTS[key] or ''
end

local function cfgSet(key, value)
    markDirty(key, value)
end

local function parseColor(str)
    local r,g,b,a = str:match('([^|]+)|([^|]+)|([^|]+)|([^|]+)')
    return tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1
end

-- ============================================================
--  UTILIDADES
-- ============================================================
local function ARGBtoRGB(color)
    return bit.band(color, 0xFFFFFF)
end

local function splitsigned(n)
    n = tonumber(n)
    local x, y = bit.band(n, 0xffff), bit.rshift(n, 16)
    if x >= 0x8000 then x = x - 0xffff end
    if y >= 0x8000 then y = y - 0xffff end
    return x, y
end

local function stripTags(text)
    return text:gsub('{%x%x%x%x%x%x%x%x}',''):gsub('{%x%x%x%x%x%x}','')
end

local function pushMsg(entry)
    table.insert(messages, entry)
    if #messages > MAX_MESSAGES then table.remove(messages, 1) end
    if not openChat then unreadCount = unreadCount + 1 end
end

local function refreshSearch()
    local q = ffi.string(searchBuf):lower()
    searchResults = {}
    if q == '' then return end
    for i, m in ipairs(messages) do
        if u8:decode(m.text):lower():find(q, 1, true) then
            table.insert(searchResults, i)
        end
    end
end

local pInput = nil

-- ============================================================
--  CARGA DE CONFIG DESDE SQLITE
-- ============================================================
local function loadConfig()
    local function loadEntry(key)
        local r,g,b,a = parseColor(cfgGet(key))
        return makeColor(r,g,b,a)
    end

    C.chat             = loadEntry('color.chat_bg')
    C.input            = loadEntry('color.input_bg')
    C.border           = loadEntry('color.border')
    C.text             = loadEntry('color.text_color')
    C.timestamp        = loadEntry('color.timestamp')
    C.unread           = loadEntry('color.unread')
    C.btn              = loadEntry('color.btn')
    C.btnHov           = loadEntry('color.btn_hov')
    C.btnAct           = loadEntry('color.btn_act')
    C.scrollBG         = loadEntry('color.scroll_bg')
    C.scrollGrab       = loadEntry('color.scroll_grab')
    C.scrollGrabActive = loadEntry('color.scroll_grab_act')
    C.scrollHov        = loadEntry('color.scroll_hov')
    C.scrollAct        = loadEntry('color.scroll_act')
    C.selNormal        = loadEntry('color.sel_normal')
    C.selHovered       = loadEntry('color.sel_hovered')

    MAX_MESSAGES = tonumber(cfgGet('val.max_msgs'))  or 500
    chatLines    = tonumber(cfgGet('val.line_count')) or 15
    chatLinesInt = imgui.new.int(chatLines)
    fontSize     = imgui.new.int(tonumber(cfgGet('val.font_size')) or 15)

    filterMode[0]           = tonumber(cfgGet('filter.mode')) or 0
    filterEnabled           = cfgGet('filter.enabled') == '1'
    filterCaseSensitive[0]  = cfgGet('filter.case_sensitive') == '1'
    filterInvert[0]         = cfgGet('filter.invert') == '1'
    imgui.StrCopy(filterTextBuf,     cfgGet('filter.text'))
    imgui.StrCopy(filterColorBuf,    cfgGet('filter.color'))
    imgui.StrCopy(filterPrefixBuf,   cfgGet('filter.prefix'))
    imgui.StrCopy(filterTimeFromBuf, cfgGet('filter.time_from'))
    imgui.StrCopy(filterTimeToBuf,   cfgGet('filter.time_to'))

    timestampStatus = cfgGet('val.timestamp') ~= '0'
end

-- ============================================================
--  RENDER DE TEXTO CON COLORES SAMP
-- ============================================================
local function renderColorText(text, msgId)
    local function shadow(t, c)
        if sampGetChatDisplayMode and sampGetChatDisplayMode() == 2 then
            local pos = imgui.GetCursorPos()
            local sc  = imgui.ImVec4(0, 0, 0, 0.75)
            for dx = -1, 1 do
                for dy = -1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        imgui.SetCursorPos(imgui.ImVec2(pos.x + dx, pos.y + dy))
                        imgui.TextColored(sc, t)
                    end
                end
            end
            imgui.SetCursorPos(pos)
        end
        imgui.TextColored(c, t)
    end

    if (openChat or _selPreviewActive) and msgId then
        local lineH   = imgui.GetTextLineHeight()
        local pos     = imgui.GetCursorScreenPos()
        local width   = imgui.GetContentRegionAvail().x
        local dl      = imgui.GetWindowDrawList()
        local isLast  = (msgId == #messages)
        local hovered = imgui.IsMouseHoveringRect(
            imgui.ImVec2(pos.x, pos.y),
            imgui.ImVec2(pos.x + width, pos.y + lineH), true)

        if _selPreviewActive and isLast then
            local c = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                C.selNormal.vec.x, C.selNormal.vec.y, C.selNormal.vec.z,
                math.min(C.selNormal.vec.w, 0.55)))
            dl:AddRectFilled(imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH), c)
        elseif openChat then
            if hovered then
                local c = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                    C.selHovered.vec.x, C.selHovered.vec.y, C.selHovered.vec.z,
                    math.min(C.selHovered.vec.w, 0.70)))
                dl:AddRectFilled(imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH), c)
            end
        end

        imgui.InvisibleButton('##sel_'..msgId, imgui.ImVec2(width, lineH))
        if imgui.IsItemHovered() then
            contextMenuOpen = true
            if imgui.IsMouseClicked(1) then
                contextMenuId = msgId
                _pendingContextMenu = true
            end
        end
        imgui.SetCursorScreenPos(imgui.ImVec2(pos.x, pos.y))
    end

    local full  = text:gsub('{(%x%x%x%x%x%x)}', '{%1FF}')
    local color = C.text.vec
    local start = 1
    local a, b  = full:find('{........}', start)
    local first = true

    while a do
        local t = full:sub(start, a - 1)
        if #t > 0 then
            if not first then imgui.SameLine(nil, 0) end
            first = false
            shadow(t, color)
            imgui.SameLine(nil, 0)
        end
        local clr = full:sub(a + 1, b - 1)
        if clr:upper() == 'STANDART' or clr:upper() == 'FFFFFFFF' then
            color = C.text.vec
        else
            local cv = tonumber(clr, 16)
            if cv then
                color = imgui.ImVec4(
                    bit.band(bit.rshift(cv,24),0xFF)/255,
                    bit.band(bit.rshift(cv,16),0xFF)/255,
                    bit.band(bit.rshift(cv, 8),0xFF)/255,
                    bit.band(cv,0xFF)/255)
            end
        end
        start = b + 1
        a, b  = full:find('{........}', start)
    end

    imgui.NewLine()
    if #full >= start then
        imgui.SameLine(nil, 0)
        shadow(full:sub(start), color)
    end
end

-- ============================================================
--  INIT IMGUI
-- ============================================================
imgui.OnInitialize(function()
    local st = imgui.GetStyle()
    st.WindowTitleAlign  = imgui.ImVec2(0.5, 0.5)
    st.WindowBorderSize  = 0
    st.PopupBorderSize   = 0
    st.WindowRounding    = 12
    st.ChildRounding     = 8
    st.FrameRounding     = 8
    st.PopupRounding     = 12
    st.ScrollbarRounding = 10
    st.GrabRounding      = 10
    st.TabRounding       = 8
    st.ItemSpacing       = imgui.ImVec2(6, 5)
    st.WindowPadding     = imgui.ImVec2(10, 10)
    st.FramePadding      = imgui.ImVec2(8, 5)

    fonts           = {}
    fontsArray      = {}
    fontChanged     = false
    fontSizeChanged = false
    showSettings    = imgui.new.bool(false)

    loadConfig()

    imgui.GetIO().IniFilename = nil
    local gr = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    imgui.GetIO().Fonts:Clear()
    imgui.GetIO().Fonts:AddFontFromFileTTF(
        getFolderPath(0x14) .. '\\' .. cfgGet('val.font_name'),
        fontSize[0], nil, gr)

    local search, file = findFirstFile(getFolderPath(0x14) .. '\\*.ttf')
    fontSelected = imgui.new.int(0)
    while file do
        table.insert(fonts, file)
        if file == cfgGet('val.font_name') then
            fontSelected[0] = #fonts - 1
        end
        file = findNextFile(search)
    end
    if #fonts > 0 then
        fontsArray = imgui.new['const char*'][#fonts](fonts)
    end
    fontSize[0] = imgui.GetIO().Fonts.ConfigData.Data[0].SizePixels
end)

-- ============================================================
--  CALLBACK INPUT
-- ============================================================
local function TextEditCallback(cbData)
    local COMP = imgui.InputTextFlags.CallbackCompletion
    local HIST = imgui.InputTextFlags.CallbackHistory

    if cbData.EventFlag == COMP then
        local cur = sampGetChatInputText and sampGetChatInputText() or ''
        if cur ~= '' then
            cbData:DeleteChars(0, cbData.BufTextLen)
            cbData:InsertChars(0, u8(cur))
            cbData.BufDirty = true
        end

    elseif cbData.EventFlag == HIST then
        local histLen = #sendHistory
        if histLen == 0 then return 0 end

        local KEY_UP   = 3
        local KEY_DOWN = 4

        if cbData.EventKey == KEY_UP then
            if lastHistoryIdx == 0 then
                lastHistoryIdx = histLen
            elseif lastHistoryIdx > 1 then
                lastHistoryIdx = lastHistoryIdx - 1
            end
        elseif cbData.EventKey == KEY_DOWN then
            lastHistoryIdx = lastHistoryIdx + 1
            if lastHistoryIdx > histLen then
                lastHistoryIdx = 0
            end
        end

        local txt = (lastHistoryIdx > 0) and sendHistory[lastHistoryIdx] or ''
        local encoded = u8(txt)
        cbData:DeleteChars(0, cbData.BufTextLen)
        if #encoded > 0 then
            cbData:InsertChars(0, encoded)
        end
        cbData.BufDirty = true
        if sampSetChatInputText then sampSetChatInputText(txt) end
    end
    return 0
end
local TextEditCallbackC = ffi.cast('int (*)(ImGuiInputTextCallbackData* data)', TextEditCallback)

-- ============================================================
--  HELPER: CIERRE LIMPIO DEL CHAT
-- ============================================================
local _forceClosePopups = false

local function closeChat()
    openChat            = false
    chatInputActive     = false
    contextMenuId       = nil
    _needsFocus         = false
    _pendingContextMenu = false
    contextMenuOpen     = false
    contextMenuId       = nil
    noScroll            = false
    _forceClosePopups   = true
    -- *** Liberar el mouse de ImGui al cerrar el chat ***
    imgui.DisableMouseInput = true
    if pInput then pInput.iInputEnabled = 0 end
    imgui.CaptureMouseFromApp(false)
    sampToggleCursor(false)
end

-- ============================================================
--  VENTANA PRINCIPAL
-- ============================================================
local chatWindow = imgui.OnFrame(
    function()
        return #messages > 0
            and not isPauseMenuActive()
            and sampIsChatVisible()
            and not sampIsScoreboardOpen()
            and showChat
    end,
    function(self)   -- _before
        flushDirty()
        local needsMouse = openChat or (showSettings and showSettings[0])
        imgui.DisableMouseInput = not needsMouse
        if fontChanged then
            fontChanged = false
            local fp = getFolderPath(0x14) .. '\\' .. (fonts[fontSelected[0]+1] or cfgGet('val.font_name'))
            local gr = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
            imgui.GetIO().Fonts:Clear()
            imgui.GetIO().Fonts:AddFontFromFileTTF(fp, fontSize[0], nil, gr)
            imgui.InvalidateFontsTexture()
        end
        if fontSizeChanged then
            fontSizeChanged = false
            local cfgData = imgui.GetIO().Fonts.ConfigData
            for i = 0, cfgData:size() - 1 do
                cfgData.Data[i].SizePixels = fontSize[0]
            end
            imgui.GetIO().Fonts:ClearTexData()
            imgui.InvalidateFontsTexture()
        end
    end,
    function(self)   -- _draw
        contextMenuOpen = false
        if os.clock() > _selPreviewTimeout then _selPreviewActive = false end
 
        if openChat then
            if not sampIsCursorActive() then sampToggleCursor(true) end
            imgui.CaptureMouseFromApp(true)
        else
            imgui.CaptureMouseFromApp(false)
        end
 
        local lineH  = imgui.GetTextLineHeightWithSpacing()
        local chatH  = lineH * chatLines + 52
        local extraH = (searchActive and openChat) and (lineH + 12) or 0
 
        imgui.SetNextWindowPos(imgui.ImVec2(2, 10))
        imgui.SetNextWindowSize(imgui.ImVec2(1022, chatH + extraH))
        imgui.PushStyleColor(imgui.Col.WindowBg, C.chat.vec)
        imgui.PushStyleColor(imgui.Col.Border,   C.border.vec)
        imgui.PushStyleColor(imgui.Col.Text,      C.text.vec)
        imgui.SetNextWindowBgAlpha(openColor)
 
        local flags = imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoSavedSettings
        if not openChat then flags = flags + imgui.WindowFlags.NoMouseInputs end
        imgui.Begin('##ChatMain', nil, flags)
 
        if openChat
            and imgui.IsMouseClicked(0)
            and not imgui.IsWindowHovered(imgui.HoveredFlags.AnyWindow)
            and not imgui.IsPopupOpen('##ctx_msg')
            and not imgui.IsPopupOpen('##edit_msg') then
            closeChat()
        end
 
        if openChat then
            imgui.SetCursorPos(imgui.ImVec2(4, 12))
            imgui.PushStyleColor(imgui.Col.Text,             imgui.ImVec4(0,0,0,0))
            imgui.PushStyleColor(imgui.Col.FrameBg,          C.scrollBG.vec)
            imgui.PushStyleColor(imgui.Col.FrameBgHovered,   C.scrollHov.vec)
            imgui.PushStyleColor(imgui.Col.FrameBgActive,    C.scrollAct.vec)
            imgui.PushStyleColor(imgui.Col.SliderGrab,       C.scrollGrab.vec)
            imgui.PushStyleColor(imgui.Col.SliderGrabActive, C.scrollGrabActive.vec)
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 14)
            imgui.PushStyleVarFloat(imgui.StyleVar.GrabRounding,  14)
            if imgui.VSliderInt('##vscroll', imgui.ImVec2(14, lineH * chatLines + 12), scrollbar, 0, max_scroll) then
                noScroll = scrollbar[0] ~= 0
                setup_current_scroll = max_scroll - scrollbar[0]
            end
            imgui.PopStyleVar(2)
            imgui.PopStyleColor(6)
        end
 
        imgui.SetCursorPos(imgui.ImVec2(24, 12))
        imgui.BeginChild('##msgs', imgui.ImVec2(0, lineH * chatLines + 4), false,
            imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
 
        local showAll = not (searchActive and ffi.string(searchBuf) ~= '')
        local searchSet = {}
        if not showAll then
            for _, idx in ipairs(searchResults) do searchSet[idx] = true end
        end
        local clipper = imgui.ImGuiListClipper(#messages)
        while clipper:Step() do
            for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                local m = messages[i]
                if m and (showAll or searchSet[i]) and msgPassesFilter(m) then
                    local prefix = ''
                    if timestampStatus and m.timestamp then
                        prefix = '{' .. string.format('%02X%02X%02XFF',
                            math.floor(C.timestamp.vec.x*255),
                            math.floor(C.timestamp.vec.y*255),
                            math.floor(C.timestamp.vec.z*255)) .. '}'
                            .. m.timestamp .. ' {FFFFFFFF}'
                    end
                    renderColorText(m.color .. prefix .. m.text, i)
                end
            end
        end
        current_scroll = imgui.GetScrollY()
        max_scroll     = imgui.GetScrollMaxY()
        imgui.SetScrollY(setup_current_scroll)
        imgui.EndChild()
 
        if _pendingContextMenu then
            _pendingContextMenu = false
            imgui.OpenPopup('##ctx_msg')
        end
 
        if openChat then
            if searchActive then
                imgui.SetCursorPosX(24)
                imgui.PushStyleColor(imgui.Col.FrameBg, C.input.vec)
                imgui.PushItemWidth(380)
                local changed = imgui.InputText(u8('##search '), searchBuf, ffi.sizeof(searchBuf) - 1, imgui.InputTextFlags.EnterReturnsTrue)
                if changed or imgui.IsItemEdited() then refreshSearch() end
                imgui.PopItemWidth()
                imgui.PopStyleColor()
                imgui.SameLine(nil, 6)
                imgui.TextColored(C.timestamp.vec, string.format('%d hallado(s)', #searchResults))
                imgui.SameLine(nil, 6)
                imgui.PushStyleColor(imgui.Col.Button,        C.btn.vec)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, C.btnHov.vec)
                imgui.PushStyleColor(imgui.Col.ButtonActive,  C.btnAct.vec)
                if imgui.Button(u8('X##cerrar_busq')) then
                    searchActive = false; imgui.StrCopy(searchBuf, ''); searchResults = {}
                end
                imgui.PopStyleColor(3)
            end
 
            imgui.SetCursorPosX(24)
            local langStr = 'EN'
            if ffi.C.GetKeyboardLayoutNameA(layout) then
                if ffi.C.GetLocaleInfoA(tonumber(ffi.string(layout), 16), 0x3, info, ffi.sizeof(info)) > 0 then
                    langStr = ffi.string(info):sub(1,2):upper()
                end
            end
            imgui.PushStyleColor(imgui.Col.FrameBg, C.input.vec)
            imgui.PushStyleColor(imgui.Col.Text,     C.text.vec)
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
            if _needsFocus then imgui.SetKeyboardFocusHere(0); _needsFocus = false end
            imgui.PushItemWidth(imgui.GetContentRegionAvail().x - 112)
            if imgui.InputText('##chatinput', inputChat, INPUT_BUF - 1,
                imgui.InputTextFlags.CallbackCompletion + imgui.InputTextFlags.CallbackHistory,
                TextEditCallbackC) then
                if sampSetChatInputText then sampSetChatInputText(u8:decode(ffi.string(inputChat))) end
            end
            local anyPopupOpen = imgui.IsPopupOpen('##ctx_msg') or imgui.IsPopupOpen('##edit_msg')
            if not anyPopupOpen then chatInputActive = imgui.IsItemActive() end
            imgui.PopItemWidth()
            imgui.PopStyleVar()
            imgui.PopStyleColor(2)
            imgui.SameLine(nil, 4)
            imgui.PushStyleColor(imgui.Col.Button,        C.input.vec)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, C.scrollHov.vec)
            imgui.PushStyleColor(imgui.Col.ButtonActive,  C.scrollAct.vec)
            imgui.PushStyleColor(imgui.Col.Text,          C.timestamp.vec)
            imgui.Button(langStr, imgui.ImVec2(28, 0))
            imgui.PopStyleColor(4)
            local charCount = #ffi.string(inputChat)
            local over = charCount > SAMP_INPUT_LIMIT
            imgui.SameLine(nil, 4)
            if over then imgui.TextColored(imgui.ImVec4(1,0.25,0.25,1), charCount..'/'..SAMP_INPUT_LIMIT)
            else         imgui.TextColored(C.timestamp.vec,              charCount..'/'..SAMP_INPUT_LIMIT) end
        end
 
        if filterEnabled and not openChat then
            imgui.SetCursorPos(imgui.ImVec2(24, lineH * chatLines + 6))
            imgui.TextColored(imgui.ImVec4(0.9,0.6,0.1,1), u8('[FILTRO ACTIVO]'))
            imgui.SameLine(nil, 4)
        end
        if not openChat and unreadCount > 0 then
            if not filterEnabled then imgui.SetCursorPos(imgui.ImVec2(24, lineH * chatLines + 20)) end
            imgui.TextColored(C.unread.vec, string.format('+ %d nuevo(s)', unreadCount))
        end
 
        -- POPUP: cierra solo si el chat se cerro mientras estaba abierto
        contextMenuOpen = contextMenuOpen or imgui.IsPopupOpen('##ctx_msg')
        imgui.PushStyleColor(imgui.Col.PopupBg,   imgui.ImVec4(0.10, 0.10, 0.13, 0.97))
        imgui.PushStyleColor(imgui.Col.Separator, imgui.ImVec4(1, 1, 1, 0.06))
        if imgui.BeginPopup('##ctx_msg') then
            if not openChat then
                imgui.CloseCurrentPopup()
                imgui.EndPopup()
                imgui.PopStyleColor(2)
                imgui.End()
                imgui.PopStyleColor(3)
                return
            end
            local m   = contextMenuId and messages[contextMenuId] or nil
            local mid = contextMenuId or 0
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.55,0.65,1.0))
            imgui.Text(string.format('  #%d  %s', mid, m and m.timestamp or ''))
            imgui.PopStyleColor()
            imgui.Spacing()
            local BTN_W, BTN_H = 172, 26
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.18,0.24,0.75))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.28,0.40,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.35,0.35,0.55,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.92,0.92,0.96,1.00))
            if imgui.Button(u8('  Copiar texto'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then setClipboardText(stripTags(u8:decode(m.text))) end
                imgui.CloseCurrentPopup()
            end
            if imgui.Button(u8('  Copiar al input'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then imgui.StrCopy(inputChat, m.text) end
                imgui.CloseCurrentPopup()
            end
            imgui.Spacing(); imgui.Separator(); imgui.Spacing()
            if imgui.Button(u8('  Editar'), imgui.ImVec2(BTN_W, BTN_H)) then
                editId = mid
                if m then
                    imgui.StrCopy(editColor, m.color:match('{(.+)}') or '')
                    imgui.StrCopy(editLine,  m.text)
                    imgui.StrCopy(editTime,  m.timestamp:match('%[(.+)%]') or '')
                end
                imgui.OpenPopup('##edit_msg')
            end
            imgui.PopStyleColor(4)
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.38,0.10,0.10,0.80))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.58,0.14,0.14,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.70,0.18,0.18,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.70,0.70,1.00))
            if imgui.Button(u8('  Eliminar'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then
                    table.remove(messages, mid)
                    setup_current_scroll = math.max(0, setup_current_scroll - imgui.GetTextLineHeightWithSpacing())
                end
                imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(4)
            imgui.SetNextWindowSize(imgui.ImVec2(500, 0), imgui.Cond.Always)
            imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(0.10,0.10,0.13,0.98))
            if imgui.BeginPopupModal('##edit_msg', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize) then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.55,0.68,1.0))
                imgui.Text(u8('  Editar mensaje  #'..editId))
                imgui.PopStyleColor()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Separator, imgui.ImVec4(1,1,1,0.07))
                imgui.Separator()
                imgui.PopStyleColor()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.16,0.16,0.22,1.0))
                imgui.Text(u8('Texto:')); imgui.PushItemWidth(-1)
                imgui.InputText('##et', editLine, ffi.sizeof(editLine) - 1)
                imgui.PopItemWidth(); imgui.Spacing()
                imgui.Columns(2, nil, false)
                imgui.Text(u8('Color (RRGGBB):')); imgui.PushItemWidth(-1)
                imgui.InputText('##ec', editColor, ffi.sizeof(editColor) - 1); imgui.PopItemWidth()
                imgui.NextColumn()
                imgui.Text(u8('Hora (HH:MM:SS):')); imgui.PushItemWidth(-1)
                imgui.InputText('##eh', editTime, ffi.sizeof(editTime) - 1); imgui.PopItemWidth()
                imgui.Columns(1); imgui.PopStyleColor()
                imgui.Spacing(); imgui.Spacing()
                local half = (imgui.GetContentRegionAvail().x - 6) * 0.5
                imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.20,0.38,0.22,0.90))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.54,0.30,1.00))
                imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.34,0.64,0.36,1.00))
                imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.85,1.00,0.85,1.00))
                if imgui.Button(u8('  Aplicar'), imgui.ImVec2(half, 30)) then
                    messages[editId] = {
                        text      = ffi.string(editLine),
                        color     = '{'..ffi.string(editColor)..'}',
                        timestamp = '['..ffi.string(editTime)..']',
                        msgType   = messages[editId] and messages[editId].msgType or 1,
                    }
                    imgui.CloseCurrentPopup()
                end
                imgui.PopStyleColor(4)
                imgui.SameLine(nil, 6)
                imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.18,0.24,0.80))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.28,0.40,1.00))
                imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.35,0.35,0.55,1.00))
                imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.75,0.75,0.82,1.00))
                if imgui.Button(u8('  Cancelar'), imgui.ImVec2(half, 30)) then imgui.CloseCurrentPopup() end
                imgui.PopStyleColor(4)
                imgui.EndPopup()
            end
            imgui.PopStyleColor()
            imgui.EndPopup()
        end
        imgui.PopStyleColor(2)
        imgui.End()
        imgui.PopStyleColor(3)
    end
)
chatWindow.HideCursor = true

-- ============================================================
--  VENTANA DE CONFIGURACION
-- ============================================================
local settingsWindow = imgui.OnFrame(
    function() return showSettings and showSettings[0] end,
    function()
        local sx, sy = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(sx/2, sy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5,0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(620, 540), imgui.Cond.FirstUseEver)

        imgui.PushStyleColor(imgui.Col.WindowBg,       imgui.ImVec4(0.08, 0.08, 0.11, 0.98))
        imgui.PushStyleColor(imgui.Col.TitleBg,        imgui.ImVec4(0.08, 0.08, 0.11, 1.00))
        imgui.PushStyleColor(imgui.Col.TitleBgActive,  imgui.ImVec4(0.12, 0.10, 0.18, 1.00))
        imgui.PushStyleColor(imgui.Col.Tab,            imgui.ImVec4(0.12, 0.12, 0.17, 1.00))
        imgui.PushStyleColor(imgui.Col.TabHovered,     imgui.ImVec4(0.22, 0.20, 0.35, 1.00))
        imgui.PushStyleColor(imgui.Col.TabActive,      imgui.ImVec4(0.20, 0.18, 0.32, 1.00))
        imgui.PushStyleColor(imgui.Col.Button,         C.btn.vec)
        imgui.PushStyleColor(imgui.Col.ButtonHovered,  C.btnHov.vec)
        imgui.PushStyleColor(imgui.Col.ButtonActive,   C.btnAct.vec)
        imgui.PushStyleColor(imgui.Col.Border,         imgui.ImVec4(1,1,1,0.06))
        imgui.PushStyleColor(imgui.Col.Text,           C.text.vec)
        imgui.PushStyleColor(imgui.Col.FrameBg,        imgui.ImVec4(0.14,0.14,0.20,1.00))
        imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.18,0.18,0.28,1.00))
        local selN = imgui.ImVec4(C.selNormal.vec.x,  C.selNormal.vec.y,  C.selNormal.vec.z,  math.min(C.selNormal.vec.w,  0.55))
        local selH = imgui.ImVec4(C.selHovered.vec.x, C.selHovered.vec.y, C.selHovered.vec.z, math.min(C.selHovered.vec.w, 0.70))
        imgui.PushStyleColor(imgui.Col.Header,         selN)
        imgui.PushStyleColor(imgui.Col.HeaderHovered,  selH)

        imgui.Begin(u8('Chat MImGui  |  Configuracion'), showSettings)

        if imgui.BeginTabBar('##tabs') then

            -- ==========================================
            --  TAB: APARIENCIA
            -- ==========================================
            if imgui.BeginTabItem(u8(' Apariencia ')) then
                imgui.Spacing()

                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Fuente y tamano'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                if #fonts > 0 then
                    imgui.Text(u8('Fuente:'))
                    imgui.PushItemWidth(-1)
                    if imgui.Combo('##fcmb', fontSelected, fontsArray, #fonts) then
                        fontChanged = true
                        cfgSet('val.font_name', fonts[fontSelected[0]+1] or cfgGet('val.font_name'))
                    end
                    imgui.PopItemWidth()
                end
                imgui.Spacing()
                if imgui.SliderInt(u8('Tamano de fuente'), fontSize, 8, 36) then
                    fontSizeChanged = true
                    cfgSet('val.font_size', tostring(fontSize[0]))
                end
                imgui.Spacing()
                if imgui.SliderInt(u8('Lineas visibles del chat'), chatLinesInt, 4, 60) then
                    chatLines = chatLinesInt[0]
                    cfgSet('val.line_count', tostring(chatLines))
                end

                imgui.Spacing()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Colores de chat'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                local SEL_ALPHA_CAP = { ['color.sel_normal'] = 0.55, ['color.sel_hovered'] = 0.70 }
                local function colorRow(label, entry, dbKey)
                    imgui.Text(label)
                    imgui.SameLine(imgui.GetWindowWidth() - 56)
                    if imgui.ColorEdit4('##' .. dbKey, entry.flt,
                        imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel +
                        imgui.ColorEditFlags.AlphaBar + imgui.ColorEditFlags.AlphaPreview) then
                        local cap = SEL_ALPHA_CAP[dbKey]
                        if cap then entry.flt[3] = math.min(entry.flt[3], cap) end
                        syncVec(entry)
                        cfgSet(dbKey, fltToStr(entry.flt))
                    end
                    if SEL_ALPHA_CAP[dbKey] then
                        if imgui.IsItemActive() or imgui.IsItemHovered() then
                            local cap = SEL_ALPHA_CAP[dbKey]
                            entry.flt[3] = math.min(entry.flt[3], cap)
                            syncVec(entry)
                            _selPreviewActive  = true
                            _selPreviewTimeout = os.clock() + 0.3
                            showChat           = true
                        end
                    end
                end

                colorRow(u8('Fondo del chat:'),        C.chat,      'color.chat_bg')
                colorRow(u8('Fondo del input:'),       C.input,     'color.input_bg')
                colorRow(u8('Borde de ventana:'),      C.border,    'color.border')
                colorRow(u8('Color del texto:'),       C.text,      'color.text_color')
                colorRow(u8('Timestamps:'),            C.timestamp, 'color.timestamp')
                colorRow(u8('Badge no leidos:'),       C.unread,    'color.unread')
                colorRow(u8('Seleccion mensajes:'),    C.selNormal,  'color.sel_normal')
                colorRow(u8('Seleccion hover:'),       C.selHovered, 'color.sel_hovered')

                imgui.Spacing()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Scrollbar'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                colorRow(u8('Fondo scrollbar:'),  C.scrollBG,        'color.scroll_bg')
                colorRow(u8('Cursor scrollbar:'), C.scrollGrab,      'color.scroll_grab')
                colorRow(u8('Cursor activo:'),    C.scrollGrabActive,'color.scroll_grab_act')
                colorRow(u8('Fondo hover:'),      C.scrollHov,       'color.scroll_hov')
                colorRow(u8('Fondo activo:'),     C.scrollAct,       'color.scroll_act')

                imgui.Spacing()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Botones del menu contextual'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                colorRow(u8('Boton normal:'), C.btn,    'color.btn')
                colorRow(u8('Boton hover:'),  C.btnHov, 'color.btn_hov')
                colorRow(u8('Boton activo:'), C.btnAct, 'color.btn_act')

                imgui.Spacing()
                imgui.Spacing()
                if imgui.Button(u8('  Restablecer colores'), imgui.ImVec2(-1, 28)) then
                    db_exec('DELETE FROM config WHERE key LIKE "color.%";')
                    _dirty = {}
                    loadConfig()
                end
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
                imgui.TextWrapped(u8('Los cambios se aplican y guardan automaticamente.'))
                imgui.PopStyleColor()

                imgui.EndTabItem()
            end

            -- ==========================================
            --  TAB: FILTROS
            -- ==========================================
            if imgui.BeginTabItem(u8(' Filtros ')) then
                imgui.Spacing()

                local enBool = imgui.new.bool(filterEnabled)
                if imgui.Checkbox(u8('  Activar filtrado de mensajes'), enBool) then
                    filterEnabled = enBool[0]
                    cfgSet('filter.enabled', filterEnabled and '1' or '0')
                end
                imgui.SameLine(nil, 12)
                if imgui.Checkbox(u8('Invertir filtro'), filterInvert) then
                    cfgSet('filter.invert', filterInvert[0] and '1' or '0')
                end

                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()

                if not filterEnabled then
                    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, 0.38)
                end

                imgui.Text(u8('Tipo de mensaje:'))
                imgui.PushItemWidth(-1)
                if imgui.Combo('##fmode', filterMode, filterModeNames, 4) then
                    cfgSet('filter.mode', tostring(filterMode[0]))
                end
                imgui.PopItemWidth()

                imgui.Spacing()

                imgui.Text(u8('Contiene texto:'))
                imgui.PushItemWidth(imgui.GetContentRegionAvail().x - 140)
                if imgui.InputText('##ftext', filterTextBuf, ffi.sizeof(filterTextBuf)-1) then
                    cfgSet('filter.text', ffi.string(filterTextBuf))
                end
                imgui.PopItemWidth()
                imgui.SameLine(nil, 8)
                if imgui.Checkbox(u8('Mayus/Min'), filterCaseSensitive) then
                    cfgSet('filter.case_sensitive', filterCaseSensitive[0] and '1' or '0')
                end

                imgui.Spacing()

                imgui.Text(u8('Prefijo / Jugador:'))
                imgui.PushItemWidth(-1)
                if imgui.InputText('##fprefix', filterPrefixBuf, ffi.sizeof(filterPrefixBuf)-1) then
                    cfgSet('filter.prefix', ffi.string(filterPrefixBuf))
                end
                imgui.PopItemWidth()

                imgui.Spacing()

                imgui.Text(u8('Color del mensaje (RRGGBB, parcial):'))
                imgui.PushItemWidth(160)
                if imgui.InputText('##fcolor', filterColorBuf, ffi.sizeof(filterColorBuf)-1) then
                    cfgSet('filter.color', ffi.string(filterColorBuf))
                end
                imgui.PopItemWidth()

                imgui.Spacing()

                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Rango de tiempo (HH:MM)'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                imgui.Columns(2, '##timecols', false)
                imgui.Text(u8('Desde:'))
                imgui.PushItemWidth(-1)
                if imgui.InputText('##ftime_from', filterTimeFromBuf, ffi.sizeof(filterTimeFromBuf)-1,
                    imgui.InputTextFlags.CharsDecimal) then
                end
                if imgui.IsItemDeactivatedAfterEdit() then
                    cfgSet('filter.time_from', ffi.string(filterTimeFromBuf))
                end
                imgui.PopItemWidth()
                imgui.NextColumn()
                imgui.Text(u8('Hasta:'))
                imgui.PushItemWidth(-1)
                if imgui.InputText('##ftime_to', filterTimeToBuf, ffi.sizeof(filterTimeToBuf)-1,
                    imgui.InputTextFlags.CharsDecimal) then
                end
                if imgui.IsItemDeactivatedAfterEdit() then
                    cfgSet('filter.time_to', ffi.string(filterTimeToBuf))
                end
                imgui.PopItemWidth()
                imgui.Columns(1)

                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
                imgui.Text(u8('Formato: 14:30  (dejar vacio = sin limite)'))
                imgui.PopStyleColor()

                if not filterEnabled then imgui.PopStyleVar() end

                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()

                if filterEnabled then
                    local visible, total = 0, #messages
                    for _, m in ipairs(messages) do
                        if msgPassesFilter(m) then visible = visible + 1 end
                    end
                    local pct = total > 0 and math.floor(visible/total*100) or 0
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5,0.9,0.5,1))
                    imgui.Text(string.format(u8('  Visibles: %d / %d  (%d%%)'), visible, total, pct))
                    imgui.PopStyleColor()
                    local bw = imgui.GetContentRegionAvail().x
                    local ratio = total > 0 and (visible/total) or 0
                    local drawList = imgui.GetWindowDrawList()
                    local cp = imgui.GetCursorScreenPos()
                    drawList:AddRectFilled(
                        imgui.ImVec2(cp.x, cp.y),
                        imgui.ImVec2(cp.x + bw, cp.y + 4),
                        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.2,0.2,0.3,1)))
                    drawList:AddRectFilled(
                        imgui.ImVec2(cp.x, cp.y),
                        imgui.ImVec2(cp.x + bw * ratio, cp.y + 4),
                        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.4,0.8,0.4,1)))
                    imgui.Dummy(imgui.ImVec2(bw, 6))
                else
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4,0.4,0.5,1))
                    imgui.Text(u8('  Activa el filtro para ver estadisticas.'))
                    imgui.PopStyleColor()
                end

                imgui.Spacing()
                if imgui.Button(u8('  Limpiar todos los filtros'), imgui.ImVec2(-1, 28)) then
                    filterMode[0]      = 0
                    filterCaseSensitive[0] = false
                    filterInvert[0]    = false
                    imgui.StrCopy(filterTextBuf,     '')
                    imgui.StrCopy(filterColorBuf,    '')
                    imgui.StrCopy(filterPrefixBuf,   '')
                    imgui.StrCopy(filterTimeFromBuf, '')
                    imgui.StrCopy(filterTimeToBuf,   '')
                    cfgSet('filter.mode',           '0')
                    cfgSet('filter.text',           '')
                    cfgSet('filter.color',          '')
                    cfgSet('filter.prefix',         '')
                    cfgSet('filter.time_from',      '')
                    cfgSet('filter.time_to',        '')
                    cfgSet('filter.case_sensitive', '0')
                    cfgSet('filter.invert',         '0')
                end
                imgui.EndTabItem()
            end

            -- ==========================================
            --  TAB: OPCIONES
            -- ==========================================
            if imgui.BeginTabItem(u8(' Opciones ')) then
                imgui.Spacing()

                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Memoria'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                imgui.Text(u8('Limite de mensajes en memoria:'))
                imgui.SameLine(nil, 8)
                local maxBuf = imgui.new.char[8](tostring(MAX_MESSAGES))
                imgui.PushItemWidth(80)
                imgui.InputText('##maxmsg', maxBuf, 7, imgui.InputTextFlags.CharsDecimal)
                if imgui.IsItemDeactivatedAfterEdit() then
                    local v = tonumber(ffi.string(maxBuf))
                    if v and v >= 50 and v <= 5000 then
                        MAX_MESSAGES = v
                        cfgSet('val.max_msgs', tostring(v))
                    end
                end
                imgui.PopItemWidth()
                imgui.SameLine(nil, 8)
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4,0.4,0.5,1))
                imgui.Text(u8('(50 - 5000)'))
                imgui.PopStyleColor()

                imgui.Spacing()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Estadisticas'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()

                local function statRow(label, val)
                    imgui.Text(label)
                    imgui.SameLine(nil, 6)
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6,0.7,1.0,1.0))
                    imgui.Text(tostring(val))
                    imgui.PopStyleColor()
                end
                statRow(u8('Mensajes en historial:'),        #messages)
                statRow(u8('Enviados guardados:'),           #sendHistory)
                statRow(u8('Sin leer:'),                     unreadCount)

                imgui.Spacing()
                imgui.Spacing()
                if imgui.Button(u8('  Limpiar chat'), imgui.ImVec2(-1, 28)) then
                    messages             = {}
                    unreadCount          = 0
                    setup_current_scroll = 0
                    noScroll             = false
                end
                imgui.Spacing()
                if imgui.Button(u8('  Limpiar historial enviados'), imgui.ImVec2(-1, 28)) then
                    sendHistory    = {}
                    lastHistoryIdx = 0
                end

                imgui.Spacing()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
                imgui.Text(u8('  Comandos y atajos'))
                imgui.PopStyleColor()
                imgui.Separator()
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65,0.65,0.75,1.0))
                imgui.TextWrapped(u8(
                    '/timestamp  |  /chconfig  |  /clearchat\n\n' ..
                    'T / F   abrir chat          F5   ocultar/mostrar\n' ..
                    'Ctrl+F  buscar              ESC  cerrar input\n' ..
                    'PgUp/PgDn  scroll rapido    Rueda  desplazar\n' ..
                    'Flechas arriba/abajo  historial de enviados'
                ))
                imgui.PopStyleColor()

                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end

        imgui.End()
        imgui.PopStyleColor(15)
    end
)

-- ============================================================
--  HOOKS DE SAMP
-- ============================================================
local _sampChatHook, _sampInputHook, _sampInputEnableHook, _sampInputDisableHook

local function onSampChat(this, msgType, text, prefix, color, pcolor)
    local clr = bit.tohex(ARGBtoRGB(color)):gsub('^00','')
    local txt = ffi.string(text)
    if msgType == 2 then
        local pclr = bit.tohex(ARGBtoRGB(pcolor)):gsub('^00','')
        txt = '{'..pclr..'}'..ffi.string(prefix)..': {'..clr..'}'..txt
    end
    pushMsg({
        text      = u8(txt),
        color     = '{'..clr..'}',
        timestamp = os.date('[%H:%M:%S]'),
        msgType   = msgType,
    })
    _sampChatHook(this, msgType, text, prefix, color, pcolor)
end

local function onSampInput(this, text, carret)
    if not openChat then
        imgui.StrCopy(inputChat, u8(ffi.string(text)))
    end
    _sampInputHook(this, text, carret)
end

local function onSampInputEnable(this)
    if isSampfuncsConsoleActive and isSampfuncsConsoleActive() then return end
    openChat        = true
    unreadCount     = 0
    lastHistoryIdx  = 0
    _needsFocus     = true
    chatInputActive = false
    -- *** Habilitar mouse de ImGui al abrir el chat ***
    imgui.DisableMouseInput = false
    if pInput then pInput.iInputEnabled = 1 end
end

local function onSampInputDisable(this)
    if openChat and sampIsCursorActive() then return end
    openChat        = false
    chatInputActive = false
    imgui.CaptureMouseFromApp(false)
    -- *** Deshabilitar mouse de ImGui al cerrar el chat ***
    imgui.DisableMouseInput = true
    if pInput then pInput.iInputEnabled = 0 end
    sampToggleCursor(false)
    noScroll = false
end

-- ============================================================
--  MAIN
-- ============================================================
function main()
    _sampInputHook = hook.new(
        'void(__thiscall *)(void* this, const char* text, bool carret)',
        onSampInput,
        getModuleHandle('samp.dll') + 0x80F60, 5, false, '8B 44 24 04 56')

    _sampInputEnableHook = hook.new(
        'void(__thiscall *)(void* this)',
        onSampInputEnable,
        getModuleHandle('samp.dll') + 0x657E0, 5, false, '83 EC 10 56 8B')

    _sampInputDisableHook = hook.new(
        'void(__thiscall *)(void* this)',
        onSampInputDisable,
        getModuleHandle('samp.dll') + 0x658E0, 5, false, '56 8B F1 8B 86')

    DB_PATH = getWorkingDirectory() .. '\\config\\Chat_MImGui.db'
    local confdir = getWorkingDirectory() .. '\\config\\'
    if not doesDirectoryExist(confdir) then createDirectory(confdir) end
    assert(db_open(DB_PATH), '[ChatMImGui] No se pudo abrir la DB SQLite.')
    db_prepare_stmts()

    while not isSampAvailable() do wait(50) end

    pInput = ffi.cast('struct stInputInfo*', sampGetInputInfoPtr())[0]

    -- Cargar mensajes existentes de SAMP
    local chatEntry = ffi.cast('chatInfoMin*', sampGetChatInfoPtr() + 306).chatEntry
    for i = 0, 99 do
        local ce = chatEntry[i]
        if ce.clTextColor ~= 0 and ce.szText ~= '' then
            local clr = bit.tohex(ARGBtoRGB(ce.clTextColor)):gsub('^00','')
            local txt = ffi.string(ce.szText)
            if ce.iType == 2 then
                local pclr = bit.tohex(ARGBtoRGB(ce.clPrefixColor)):gsub('^00','')
                txt = '{'..pclr..'}'..ffi.string(ce.szPrefix)..' {'..clr..'}'..txt
            end
            table.insert(messages, {
                text      = u8(txt),
                color     = '{'..clr..'}',
                timestamp = os.date('[%H:%M:%S]', ce.SystemTime),
                msgType   = ce.iType,
            })
        end
    end

    _sampChatHook = hook.new(
        'void(__thiscall *)(void *this, uint32_t type, const char* text, const char* prefix, uint32_t color, uint32_t pcolor)',
        onSampChat,
        getModuleHandle('samp.dll') + 0x64010, 5, false, '55 56 8B E9 57')

    memory.setuint8(sampGetBase() + 0x71480, 0xEB, true)

    -- *** Estado inicial: deshabilitar mouse de ImGui hasta que se abra el chat ***
    imgui.DisableMouseInput = true

    addEventHandler('onScriptTerminate', function(scr)
        if scr == script.this then
            for _, h in ipairs(hook.hooks) do
                if h.status then h.stop() end
            end
            if next(_dirty) ~= nil then
                db_exec('BEGIN;')
                for k, v in pairs(_dirty) do db_set(k, v) end
                db_exec('COMMIT;')
            end
            _sq.sqlite3_finalize(stmt_set[0])
            _sq.sqlite3_finalize(stmt_get[0])
            _sq.sqlite3_close(db[0])
        end
    end)

    -- Hilo: scroll suave
    lua_thread.create(function()
        while true do
            wait(0)
            if not noScroll then
                local iters = 0
                while max_scroll - current_scroll ~= 0 and not noScroll and iters < 200 do
                    local diff  = max_scroll - setup_current_scroll
                    local speed = diff > 360 and 56 or diff > 180 and 32 or diff > 60 and 16 or 6
                    setup_current_scroll = setup_current_scroll + speed
                    iters = iters + 1
                    wait(14)
                end
                scrollbar[0] = 0
            end
        end
    end).work_in_pause = true

    -- Hilo: fade del fondo
    lua_thread.create(function()
        while true do
            wait(0)
            if openChat then
                local target = C.chat.flt[3]
                if openColor < target then
                    wait(300)
                    while openChat and openColor < target do
                        openColor = math.min(openColor + 0.05, target)
                        wait(14)
                    end
                end
                while openChat do wait(0) end
            else
                if openColor > 0 then
                    wait(120)
                    while openColor > 0 do
                        openColor = math.max(openColor - 0.05, 0)
                        wait(14)
                    end
                    openColor = 0
                end
            end
        end
    end).work_in_pause = true

    while true do wait(1000) end
end

-- ============================================================
--  MENSAJES DE VENTANA
-- ============================================================
addEventHandler('onWindowMessage', function(msg, wparam, lparam)

    if msg == 0x0204 and openChat then  -- WM_RBUTTONDOWN
        consumeWindowMessage(true, true, true)
        return
    end

    if msg == 0x0008 then   -- WM_KILLFOCUS
        if openChat then closeChat() end
        imgui.CaptureMouseFromApp(false)
        return
    end

    if msg == 0x0100 then
        if wparam == 0x1B and openChat then     -- ESC
            closeChat()
            consumeWindowMessage(true, false)

        elseif wparam == 0x74 then      -- F5
            showChat = not showChat

        elseif wparam == 0x46 and openChat and imgui.GetIO().KeyCtrl then   -- Ctrl+F
            searchActive = not searchActive
            if not searchActive then
                imgui.StrCopy(searchBuf, '')
                searchResults = {}
            end
            consumeWindowMessage(true, false)

        elseif wparam == 0x21 then      -- PgUp
            noScroll = true
            setup_current_scroll = math.max(0, setup_current_scroll - 200)
            scrollbar[0] = max_scroll - setup_current_scroll

        elseif wparam == 0x22 then      -- PgDn
            noScroll = true
            if setup_current_scroll + 200 <= max_scroll then
                setup_current_scroll = setup_current_scroll + 200
                scrollbar[0] = max_scroll - setup_current_scroll
            else
                setup_current_scroll = max_scroll
                scrollbar[0] = 0
                noScroll = false
            end
        end

    elseif msg == 0x0101 then
        if openChat then
            if wparam == 0x0D then      -- Enter
                local text = u8:decode(ffi.string(inputChat))
                if text == '/timestamp' then
                    timestampStatus = not timestampStatus
                    cfgSet('val.timestamp', timestampStatus and '1' or '0')
                    -- Cerrar el chat despues de ejecutar el comando
                    lastHistoryIdx = 0
                    imgui.StrCopy(inputChat, '')
                    closeChat()
                    consumeWindowMessage(true, false)
                    return true
                elseif text == '/clearchat' then
                    messages             = {}
                    unreadCount          = 0
                    setup_current_scroll = 0
                    noScroll             = false
                    -- Cerrar el chat despues de ejecutar el comando
                    lastHistoryIdx = 0
                    imgui.StrCopy(inputChat, '')
                    closeChat()
                    consumeWindowMessage(true, false)
                    return true
                elseif text == '/chconfig' then
                    showSettings[0] = not showSettings[0]
                    -- Cerrar el chat despues de ejecutar el comando (comportamiento real de CMD)
                    lastHistoryIdx = 0
                    imgui.StrCopy(inputChat, '')
                    closeChat()
                    consumeWindowMessage(true, false)
                    return true
                elseif text ~= '' then
                    sampProcessChatInput(text)
                    if sendHistory[#sendHistory] ~= text then
                        table.insert(sendHistory, text)
                    end
                end
                lastHistoryIdx = 0
                imgui.StrCopy(inputChat, '')
                closeChat()
                consumeWindowMessage(true, false)

            elseif wparam == 0x75 then  -- F6
                closeChat()
                consumeWindowMessage(true, false)
            end
        end

    elseif msg == 0x020A and openChat then   -- WM_MOUSEWHEEL
        local _, delta = splitsigned(ffi.cast('int32_t', wparam))
        noScroll = true
        local step = 50
        if delta > 0 then
            setup_current_scroll = math.max(0, setup_current_scroll - step)
            scrollbar[0] = max_scroll - setup_current_scroll
        elseif delta < 0 then
            if setup_current_scroll + step <= max_scroll then
                setup_current_scroll = setup_current_scroll + step
                scrollbar[0] = max_scroll - setup_current_scroll
            else
                setup_current_scroll = max_scroll
                scrollbar[0] = 0
                noScroll = false
            end
        end
    end
end)
