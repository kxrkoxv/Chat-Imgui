script_name('Chat MImGui')
script_version_number(1)
script_author('kxrko')

-- ============================================================
--  VERSION Y ACTUALIZACIONES (por version semantica)
-- ============================================================
local REPO_OWNER     = 'kxrkoxv'
local REPO_NAME      = 'Chat-Imgui'
local REPO_BRANCH    = 'main'
local RAW_SCRIPT_URL = 'https://raw.githubusercontent.com/' .. REPO_OWNER .. '/' .. REPO_NAME .. '/' .. REPO_BRANCH .. '/Chat.lua'

-- Version actual del script (hardcodeada aqui, se incrementa con cada release)
local CURRENT_VERSION = '1.0.0'

-- Version remota obtenida de GitHub (se extrae de la linea script_version del archivo)
local _remoteVersion  = ''
local _updateStatus   = nil  -- nil=sin checar, 'checking', 'ok', 'available', 'error', 'updating', 'updated'
local _updateMsg      = ''   -- mensaje extra para mostrar al usuario

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

-- Estado del click derecho detectado manualmente
local _rbuttonPending   = false
local _rbuttonMsgId     = nil
local _pendingEditModal = false

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
--  SISTEMA DE HOTKEY CONFIGURABLE
-- ============================================================
local VK_NAMES = {
    [0x70]='F1', [0x71]='F2', [0x72]='F3', [0x73]='F4',
    [0x74]='F5', [0x75]='F6', [0x76]='F7', [0x77]='F8',
    [0x78]='F9', [0x79]='F10',[0x7A]='F11',[0x7B]='F12',
    [0x60]='Num0',[0x61]='Num1',[0x62]='Num2',[0x63]='Num3',
    [0x64]='Num4',[0x65]='Num5',[0x66]='Num6',[0x67]='Num7',
    [0x68]='Num8',[0x69]='Num9',
    [0x2D]='Ins', [0x2E]='Del', [0x24]='Home',[0x23]='End',
    [0x21]='PgUp',[0x22]='PgDn',
    [0x25]='Left',[0x26]='Up', [0x27]='Right',[0x28]='Down',
    [0x20]='Space',
    [0x30]='0',[0x31]='1',[0x32]='2',[0x33]='3',[0x34]='4',
    [0x35]='5',[0x36]='6',[0x37]='7',[0x38]='8',[0x39]='9',
}
for i = 65, 90 do VK_NAMES[i] = string.char(i) end

local function vkName(vk)
    return VK_NAMES[vk] or string.format('VK_%02X', vk)
end

local hotkeyVK       = 0
local hotkeyCapture  = false
local hotkeyLastName = 'Ninguna'

local function stripTags(text)
    return text:gsub('{%x%x%x%x%x%x%x%x}',''):gsub('{%x%x%x%x%x%x}','')
end

-- ============================================================
--  SISTEMA DE MENSAJES BLOQUEADOS
-- ============================================================
local blockedPatterns = {}
local blockedNewBuf   = imgui.new.char[256]()

local function serializeBlocked()
    return table.concat(blockedPatterns, '\n')
end

local function deserializeBlocked(s)
    blockedPatterns = {}
    if not s or s == '' then return end
    for line in s:gmatch('([^\n]+)') do
        if line ~= '' then table.insert(blockedPatterns, line) end
    end
end

local function addBlockedPattern(pat)
    pat = pat:match('^%s*(.-)%s*$')
    if pat == '' then return false end
    for _, v in ipairs(blockedPatterns) do
        if v:lower() == pat:lower() then return false end
    end
    table.insert(blockedPatterns, pat)
    return true
end

local function removeBlockedPattern(i)
    table.remove(blockedPatterns, i)
end

local function msgIsBlocked(m)
    if #blockedPatterns == 0 then return false end
    local hay = stripTags(u8:decode(m.text)):lower()
    for _, pat in ipairs(blockedPatterns) do
        if hay:find(pat:lower(), 1, true) then return true end
    end
    return false
end

local function purgeBlockedFromHistory()
    local i = 1
    while i <= #messages do
        if msgIsBlocked(messages[i]) then
            table.remove(messages, i)
        else
            i = i + 1
        end
    end
end

local function saveBlocked()
    local val = serializeBlocked()
    db_exec('BEGIN;')
    db_set('filter.blocked', val)
    db_exec('COMMIT;')
    _dirty['filter.blocked'] = val
end

local function msgPassesFilter(m)
    return not msgIsBlocked(m)
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
    ['filter.blocked']         = '',
    ['hotkey.settings']        = '0',
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

    deserializeBlocked(cfgGet('filter.blocked'))

    timestampStatus = cfgGet('val.timestamp') ~= '0'

    hotkeyVK       = tonumber(cfgGet('hotkey.settings')) or 0
    hotkeyLastName = hotkeyVK ~= 0 and vkName(hotkeyVK) or 'Ninguna'
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
        local lineH = imgui.GetTextLineHeight()
        local pos   = imgui.GetCursorScreenPos()
        local width = imgui.GetContentRegionAvail().x
        local dl    = imgui.GetWindowDrawList()
        local isLast = (msgId == #messages)

        local mx, my  = getCursorPos()
        local hovered = mx >= pos.x and mx <= pos.x + width
                     and my >= pos.y and my <= pos.y + lineH

        if _selPreviewActive and isLast then
            local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                C.selNormal.vec.x, C.selNormal.vec.y, C.selNormal.vec.z,
                math.min(C.selNormal.vec.w, 0.55)))
            dl:AddRectFilled(imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH), col)
        elseif openChat and hovered then
            local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                C.selHovered.vec.x, C.selHovered.vec.y, C.selHovered.vec.z,
                math.min(C.selHovered.vec.w, 0.70)))
            dl:AddRectFilled(imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH), col)
        end
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
    _rbuttonPending     = false
    noScroll            = false
    _forceClosePopups   = true
    imgui.DisableMouseInput = true
    if pInput then pInput.iInputEnabled = 0 end
    imgui.CaptureMouseFromApp(false)
    sampToggleCursor(false)
end

-- ============================================================
--  SETTINGS TABS
-- ============================================================

-- ---- TAB: APARIENCIA ----------------------------------------
local function drawTabApariencia()
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

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Colores de chat'))
    imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()

    colorRow(u8('Fondo del chat:'),        C.chat,      'color.chat_bg')
    colorRow(u8('Fondo del input:'),       C.input,     'color.input_bg')
    colorRow(u8('Borde de ventana:'),      C.border,    'color.border')
    colorRow(u8('Color del texto:'),       C.text,      'color.text_color')
    colorRow(u8('Timestamps:'),            C.timestamp, 'color.timestamp')
    colorRow(u8('Badge no leidos:'),       C.unread,    'color.unread')
    colorRow(u8('Seleccion mensajes:'),    C.selNormal,  'color.sel_normal')
    colorRow(u8('Seleccion hover:'),       C.selHovered, 'color.sel_hovered')

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Scrollbar'))
    imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()

    colorRow(u8('Fondo scrollbar:'),  C.scrollBG,        'color.scroll_bg')
    colorRow(u8('Cursor scrollbar:'), C.scrollGrab,      'color.scroll_grab')
    colorRow(u8('Cursor activo:'),    C.scrollGrabActive,'color.scroll_grab_act')
    colorRow(u8('Fondo hover:'),      C.scrollHov,       'color.scroll_hov')
    colorRow(u8('Fondo activo:'),     C.scrollAct,       'color.scroll_act')

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Botones del menu contextual'))
    imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()

    colorRow(u8('Boton normal:'), C.btn,    'color.btn')
    colorRow(u8('Boton hover:'),  C.btnHov, 'color.btn_hov')
    colorRow(u8('Boton activo:'), C.btnAct, 'color.btn_act')

    imgui.Spacing(); imgui.Spacing()
    if imgui.Button(u8('  Restablecer colores'), imgui.ImVec2(-1, 28)) then
        db_exec('DELETE FROM config WHERE key LIKE "color.%";')
        _dirty = {}
        loadConfig()
    end
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
    imgui.TextWrapped(u8('Los cambios se aplican y guardan automaticamente.'))
    imgui.PopStyleColor()
end

-- ---- TAB: FILTROS -------------------------------------------
local function drawTabFiltros()
    imgui.Spacing()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.75,0.45,1.00,1.0))
    imgui.Text(u8('  Mensajes bloqueados  (' .. #blockedPatterns .. ')'))
    imgui.PopStyleColor()
    imgui.Separator()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
    imgui.TextWrapped(u8('Los mensajes que coincidan con estos patrones se ocultan automaticamente del chat. Puedes bloquear mensajes haciendo click derecho sobre ellos.'))
    imgui.PopStyleColor()
    imgui.Spacing()

    local rowH    = imgui.GetTextLineHeightWithSpacing() + 4
    local listH   = math.max(80, math.min(#blockedPatterns, 8) * rowH + 10)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.07,0.07,0.10,1.0))
    imgui.PushStyleColor(imgui.Col.Border,  imgui.ImVec4(0.30,0.15,0.50,0.5))
    imgui.BeginChild('##blocked_list', imgui.ImVec2(-1, listH), true)
    if #blockedPatterns == 0 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35,0.35,0.45,1.0))
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 8)
        imgui.Text(u8('  (ninguno)'))
        imgui.PopStyleColor()
    end
    local toRemoveBlocked = nil
    for bi, pat in ipairs(blockedPatterns) do
        imgui.PushIDInt(bi)
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.42,0.08,0.08,0.85))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.70,0.12,0.12,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.85,0.16,0.16,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.65,0.65,1.00))
        if imgui.Button('X##bd', imgui.ImVec2(22, 0)) then
            toRemoveBlocked = bi
        end
        imgui.PopStyleColor(4)
        imgui.SameLine(nil, 8)
        local disp = #pat > 64 and pat:sub(1,61)..'...' or pat
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85,0.75,1.00,1.0))
        imgui.Text(u8(disp))
        imgui.PopStyleColor()
        imgui.PopID()
    end
    imgui.EndChild()
    imgui.PopStyleColor(2)

    if toRemoveBlocked then
        removeBlockedPattern(toRemoveBlocked)
        saveBlocked()
        purgeBlockedFromHistory()
    end

    imgui.Spacing()

    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.11,0.08,0.18,1.0))
    imgui.PushItemWidth(imgui.GetContentRegionAvail().x - 106)
    imgui.InputText(u8('##newblocked'), blockedNewBuf, ffi.sizeof(blockedNewBuf) - 1)
    imgui.PopItemWidth()
    imgui.PopStyleColor()
    imgui.SameLine(nil, 4)
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.22,0.10,0.40,0.92))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.38,0.16,0.62,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.50,0.22,0.78,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.88,0.68,1.00,1.00))
    if imgui.Button(u8('+ Bloquear'), imgui.ImVec2(-1, 0)) then
        local newPat = ffi.string(blockedNewBuf)
        if addBlockedPattern(newPat) then
            saveBlocked()
            purgeBlockedFromHistory()
        end
        imgui.StrCopy(blockedNewBuf, '')
    end
    imgui.PopStyleColor(4)

    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.25,0.08,0.08,0.88))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.45,0.12,0.12,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.60,0.15,0.15,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.65,0.65,1.00))
    if imgui.Button(u8('  Borrar todos los bloqueados'), imgui.ImVec2(-1, 26)) then
        blockedPatterns = {}
        saveBlocked()
    end
    imgui.PopStyleColor(4)

    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.38,0.38,0.48,1.0))
    imgui.TextWrapped(u8('Tip: el patron es texto plano. El bloqueo no distingue mayusculas/minusculas y busca coincidencia parcial. Si el patron aparece en cualquier parte del mensaje, este se oculta.'))
    imgui.PopStyleColor()
end

-- ============================================================
--  SISTEMA DE ACTUALIZACIONES POR VERSION SEMANTICA
-- ============================================================

-- Compara dos versiones semanticas "X.Y.Z". Devuelve:
--   1  si a > b
--   0  si a == b
--  -1  si a < b
local function compareVersions(a, b)
    local function parts(v)
        local x, y, z = v:match('^(%d+)%.(%d+)%.(%d+)$')
        return tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
    end
    local a1,a2,a3 = parts(a)
    local b1,b2,b3 = parts(b)
    if a1 ~= b1 then return a1 > b1 and 1 or -1 end
    if a2 ~= b2 then return a2 > b2 and 1 or -1 end
    if a3 ~= b3 then return a3 > b3 and 1 or -1 end
    return 0
end

-- Extrae la version del header del script remoto:
-- busca la linea: script_version_number(X) o una etiqueta como: -- VERSION: X.Y.Z
-- Primero intenta la etiqueta, luego script_version_number como fallback numerico.
local function extractRemoteVersion(content)
    -- Formato preferido: CURRENT_VERSION = '1.0.0'
    local v = content:match("CURRENT_VERSION%s*=%s*'([%d%.]+)'")
    if v and v:match('^%d+%.%d+%.%d+$') then return v end
    -- Fallback: busca script_version_number(X) y lo convierte a "X.0.0"
    local n = content:match('script_version_number%((%d+)%)')
    if n then return n .. '.0.0' end
    return nil
end

-- Descarga el script remoto y extrae su version
local function fetchRemoteVersion(callback)
    lua_thread.create(function()
        local tmpScript = getWorkingDirectory() .. '\\config\\chat_mimgui_ver.tmp'
        local ok = false
        if downloadUrlToFile then
            os.remove(tmpScript)
            downloadUrlToFile(RAW_SCRIPT_URL, tmpScript)
            wait(5000)
            local f = io.open(tmpScript, 'r')
            if f then
                -- Solo leer los primeros 2KB para encontrar la version (es rapido)
                local content = f:read(2048)
                f:close()
                os.remove(tmpScript)
                if content and #content > 10 then
                    local ver = extractRemoteVersion(content)
                    if ver then
                        ok = true
                        callback(ver)
                    end
                end
            end
        end
        if not ok then
            callback(nil)
        end
    end)
end

-- Descarga el script completo y lo aplica
local function downloadAndApply(remoteVer)
    _updateStatus = 'updating'
    lua_thread.create(function()
        local scriptPath = getWorkingDirectory() .. '\\Chat.lua'
        local tmpScript  = getWorkingDirectory() .. '\\config\\chat_mimgui_new.tmp'
        os.remove(tmpScript)
        if downloadUrlToFile then
            downloadUrlToFile(RAW_SCRIPT_URL, tmpScript)
            wait(6000)
            local f = io.open(tmpScript, 'r')
            if f then
                local content = f:read('*a')
                f:close()
                os.remove(tmpScript)
                if content and #content > 100 then
                    local out = io.open(scriptPath, 'w')
                    if out then
                        out:write(content)
                        out:close()
                        _updateStatus = 'updated'
                        _updateMsg = 'Actualizado a v' .. remoteVer .. '. Recarga el script (F9 o /reload).'
                        return
                    end
                end
            end
        end
        _updateStatus = 'error'
        _updateMsg = 'No se pudo descargar el archivo.'
    end)
end

-- Chequeo principal: compara version local con version remota
local function checkUpdate()
    _updateStatus = 'checking'
    _updateMsg    = ''
    fetchRemoteVersion(function(remoteVer)
        if not remoteVer then
            _updateStatus = 'error'
            _updateMsg    = 'No se pudo contactar GitHub.'
            return
        end
        _remoteVersion = remoteVer
        local cmp = compareVersions(remoteVer, CURRENT_VERSION)
        if cmp <= 0 then
            _updateStatus = 'ok'
            _updateMsg    = ''
        else
            _updateStatus = 'available'
            _updateMsg    = 'Nueva version: v' .. remoteVer
        end
    end)
end

-- ---- TAB: OPCIONES ------------------------------------------
local function drawTabOpciones()
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

    imgui.Spacing(); imgui.Spacing()
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
    statRow(u8('Mensajes en historial:'), #messages)
    statRow(u8('Enviados guardados:'),    #sendHistory)
    statRow(u8('Sin leer:'),              unreadCount)

    imgui.Spacing(); imgui.Spacing()
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

    imgui.Spacing(); imgui.Spacing()
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
        'Flechas arriba/abajo  historial de enviados\n\n' ..
        'Hotkey config: asignable en la pestana "Teclas"'
    ))
    imgui.PopStyleColor()

    -- ---- ACTUALIZACIONES ----
    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Actualizaciones'))
    imgui.PopStyleColor()
    imgui.Separator()
    imgui.Spacing()

    -- Version instalada (siempre CURRENT_VERSION hardcodeada en el script)
    imgui.Text(u8('Version instalada:'))
    imgui.SameLine(nil, 6)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.80,0.55,1.0))
    imgui.Text('v' .. CURRENT_VERSION)
    imgui.PopStyleColor()

    -- Version remota (si ya se consulto)
    if _remoteVersion ~= '' then
        imgui.Text(u8('Ultima en GitHub:'))
        imgui.SameLine(nil, 6)
        local isLatest = compareVersions(_remoteVersion, CURRENT_VERSION) <= 0
        imgui.PushStyleColor(imgui.Col.Text,
            isLatest and imgui.ImVec4(0.55,0.80,0.55,1.0) or imgui.ImVec4(1.0,0.82,0.20,1.0))
        imgui.Text('v' .. _remoteVersion)
        imgui.PopStyleColor()
    end

    imgui.Spacing()

    -- Estado principal
    if _updateStatus == nil then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.60,1.0))
        imgui.Text(u8('  Esperando verificacion automatica...'))
        imgui.PopStyleColor()

    elseif _updateStatus == 'checking' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.70,0.70,0.35,1.0))
        imgui.Text(u8('  Consultando GitHub...'))
        imgui.PopStyleColor()

    elseif _updateStatus == 'ok' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35,0.85,0.40,1.0))
        imgui.Text(u8('  Tienes la version mas reciente.'))
        imgui.PopStyleColor()
        if _updateMsg ~= '' then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45,0.55,0.45,1.0))
            imgui.TextWrapped(u8(_updateMsg))
            imgui.PopStyleColor()
        end

    elseif _updateStatus == 'available' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0,0.85,0.15,1.0))
        imgui.Text(u8('  Hay una actualizacion disponible!'))
        imgui.PopStyleColor()
        if _updateMsg ~= '' then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.75,0.65,0.30,1.0))
            imgui.TextWrapped(u8(_updateMsg))
            imgui.PopStyleColor()
        end
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.15,0.35,0.15,0.95))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22,0.52,0.22,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.28,0.62,0.28,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.75,1.00,0.75,1.00))
        if imgui.Button(u8('  Actualizar a v' .. _remoteVersion .. '  '), imgui.ImVec2(-1, 30)) then
            downloadAndApply(_remoteVersion)
        end
        imgui.PopStyleColor(4)

    elseif _updateStatus == 'updating' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.70,0.70,0.35,1.0))
        imgui.Text(u8('  Descargando actualizacion...'))
        imgui.PopStyleColor()

    elseif _updateStatus == 'updated' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35,0.90,0.45,1.0))
        imgui.Text(u8('  Actualizacion aplicada!'))
        imgui.PopStyleColor()
        if _updateMsg ~= '' then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.80,0.55,1.0))
            imgui.TextWrapped(u8(_updateMsg))
            imgui.PopStyleColor()
        end

    elseif _updateStatus == 'error' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85,0.30,0.30,1.0))
        imgui.Text(u8('  Error al verificar.'))
        imgui.PopStyleColor()
        if _updateMsg ~= '' then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65,0.35,0.35,1.0))
            imgui.TextWrapped(u8(_updateMsg))
            imgui.PopStyleColor()
        end
    end

    imgui.Spacing()

    if _updateStatus ~= 'updating' and _updateStatus ~= 'updated' and _updateStatus ~= 'checking' then
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.12,0.18,0.35,0.92))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20,0.30,0.55,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.25,0.38,0.68,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.75,0.88,1.00,1.00))
        local btnLabel = _updateStatus == 'error' and u8('  Reintentar') or u8('  Verificar actualizaciones')
        if imgui.Button(btnLabel, imgui.ImVec2(-1, 26)) then
            checkUpdate()
        end
        imgui.PopStyleColor(4)
    end
    imgui.Spacing()
end

-- ---- TAB: TECLAS --------------------------------------------
local function drawTabTeclas()
    imgui.Spacing()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Hotkeys personalizadas'))
    imgui.PopStyleColor()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextWrapped(u8('Asigna un boton del teclado para abrir y cerrar esta ventana de configuracion desde cualquier momento (sin necesidad de escribir /chconfig).'))
    imgui.Spacing(); imgui.Spacing()

    imgui.Text(u8('Tecla actual:'))
    imgui.SameLine(nil, 8)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6,0.9,0.6,1.0))
    imgui.Text(hotkeyLastName)
    imgui.PopStyleColor()

    imgui.Spacing()

    if hotkeyCapture then
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.55,0.20,0.20,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.70,0.28,0.28,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.80,0.32,0.32,1.00))
        imgui.Button(u8('  [ Presiona una tecla... ]'), imgui.ImVec2(-1, 32))
        imgui.PopStyleColor(3)
    else
        imgui.PushStyleColor(imgui.Col.Button,        C.btn.vec)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, C.btnHov.vec)
        imgui.PushStyleColor(imgui.Col.ButtonActive,  C.btnAct.vec)
        if imgui.Button(u8('  Asignar tecla...'), imgui.ImVec2(-1, 32)) then
            hotkeyCapture = true
        end
        imgui.PopStyleColor(3)
    end

    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.25,0.10,0.10,0.90))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.40,0.14,0.14,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.55,0.18,0.18,1.00))
    if imgui.Button(u8('  Quitar hotkey'), imgui.ImVec2(-1, 28)) then
        hotkeyCapture  = false
        hotkeyVK       = 0
        hotkeyLastName = 'Ninguna'
        cfgSet('hotkey.settings', '0')
    end
    imgui.PopStyleColor(3)

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
    imgui.TextWrapped(u8('Nota: la hotkey solo funciona cuando el chat/input esta cerrado. Teclas recomendadas: F1-F4, F8-F12, Insert, numpad, letras, etc.'))
    imgui.PopStyleColor()
end

-- ============================================================
--  VENTANA PRINCIPAL
-- ============================================================
local chatWindow = imgui.OnFrame(
    function()
        return not isPauseMenuActive()
            and sampIsChatVisible()
            and not sampIsScoreboardOpen()
            and showChat
    end,
    function(self)
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
    function(self)
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

            if _pendingEditModal then
                _pendingEditModal = false
                imgui.OpenPopup('##edit_msg')
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

        if not openChat and unreadCount > 0 then
            imgui.SetCursorPos(imgui.ImVec2(24, lineH * chatLines + 20))
            imgui.TextColored(C.unread.vec, string.format('+ %d nuevo(s)', unreadCount))
        end

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
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.10,0.32,0.85))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.35,0.15,0.55,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.50,0.20,0.70,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.85,0.65,1.00,1.00))
            if imgui.Button(u8('  Filtrar mensaje'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then
                    local plain = stripTags(u8:decode(m.text)):match('^%s*(.-)%s*$')
                    if addBlockedPattern(plain) then
                        saveBlocked()
                    end
                    purgeBlockedFromHistory()
                end
                imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(4)
            imgui.Spacing(); imgui.Separator(); imgui.Spacing()
            if imgui.Button(u8('  Editar'), imgui.ImVec2(BTN_W, BTN_H)) then
                editId = mid
                if m then
                    imgui.StrCopy(editColor, m.color:match('{(.+)}') or '')
                    imgui.StrCopy(editLine,  m.text)
                    imgui.StrCopy(editTime,  m.timestamp:match('%[(.+)%]') or '')
                end
                _pendingEditModal = true
                imgui.CloseCurrentPopup()
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
            imgui.EndPopup()
        end
        imgui.PopStyleColor(2)

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
        imgui.SetNextWindowSize(imgui.ImVec2(640, 580), imgui.Cond.FirstUseEver)

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
        imgui.PushStyleColor(imgui.Col.TextSelectedBg, selN)

        imgui.Begin(u8('Chat MImGui  |  Configuracion'), showSettings)

        if imgui.BeginTabBar('##tabs') then
            if imgui.BeginTabItem(u8(' Apariencia ')) then
                drawTabApariencia()
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem(u8(' Filtros ')) then
                drawTabFiltros()
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem(u8(' Opciones ')) then
                drawTabOpciones()
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem(u8(' Teclas ')) then
                drawTabTeclas()
                imgui.EndTabItem()
            end
            imgui.EndTabBar()
        end

        imgui.End()
        imgui.PopStyleColor(16)
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
    imgui.DisableMouseInput = false
    if pInput then pInput.iInputEnabled = 1 end
end

local function onSampInputDisable(this)
    if openChat and sampIsCursorActive() then return end
    openChat        = false
    chatInputActive = false
    imgui.CaptureMouseFromApp(false)
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

    -- Lanzar chequeo automatico de actualizaciones al iniciar
    wait(100)
    checkUpdate()

    while not isSampAvailable() do wait(50) end

    pInput = ffi.cast('struct stInputInfo*', sampGetInputInfoPtr())[0]

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

    if msg == 0x0204 and openChat then
        local mx, my = getCursorPos()
        local lineH  = imgui.GetTextLineHeightWithSpacing()
        local winY   = 10 + 12
        local relY   = my - winY + current_scroll
        local idx    = math.floor(relY / lineH) + 1
        if idx >= 1 and idx <= #messages then
            contextMenuId       = idx
            _pendingContextMenu = true
        end
        consumeWindowMessage(true, true, true)
        return
    end

    if msg == 0x0008 then
        if openChat then closeChat() end
        imgui.CaptureMouseFromApp(false)
        return
    end

    if msg == 0x0100 then
        if hotkeyCapture then
            if wparam ~= 0x10 and wparam ~= 0x11 and wparam ~= 0x12
               and wparam ~= 0xA0 and wparam ~= 0xA1
               and wparam ~= 0xA2 and wparam ~= 0xA3 then
                hotkeyCapture  = false
                hotkeyVK       = wparam
                hotkeyLastName = vkName(wparam)
                cfgSet('hotkey.settings', tostring(wparam))
                consumeWindowMessage(true, true, true)
                return
            end
        end

        if wparam == 0x1B and openChat then
            closeChat()
            consumeWindowMessage(true, false)

        elseif wparam == 0x74 then
            showChat = not showChat

        elseif hotkeyVK ~= 0 and wparam == hotkeyVK and not openChat then
            if showSettings then showSettings[0] = not showSettings[0] end
            consumeWindowMessage(true, false)

        elseif wparam == 0x46 and openChat and imgui.GetIO().KeyCtrl then
            searchActive = not searchActive
            if not searchActive then
                imgui.StrCopy(searchBuf, '')
                searchResults = {}
            end
            consumeWindowMessage(true, false)

        elseif wparam == 0x21 then
            noScroll = true
            setup_current_scroll = math.max(0, setup_current_scroll - 200)
            scrollbar[0] = max_scroll - setup_current_scroll

        elseif wparam == 0x22 then
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
            if wparam == 0x0D then
                local text = u8:decode(ffi.string(inputChat))
                if text == '/timestamp' then
                    timestampStatus = not timestampStatus
                    cfgSet('val.timestamp', timestampStatus and '1' or '0')
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
                    lastHistoryIdx = 0
                    imgui.StrCopy(inputChat, '')
                    closeChat()
                    consumeWindowMessage(true, false)
                    return true
                elseif text == '/chconfig' then
                    showSettings[0] = not showSettings[0]
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

            elseif wparam == 0x75 then
                closeChat()
                consumeWindowMessage(true, false)
            end
        end

    elseif msg == 0x020A and openChat then
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