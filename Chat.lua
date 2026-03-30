script_name('Chat MImGui')
script_version_number(1)
script_author('kxrko')

-- ============================================================
--  VERSION Y ACTUALIZACIONES
-- ============================================================
local REPO_OWNER   = 'kxrkoxv'
local REPO_NAME    = 'Chat-Imgui'
local REPO_BRANCH  = 'main'
local RAW_BASE_URL = 'https://raw.githubusercontent.com/' .. REPO_OWNER .. '/' .. REPO_NAME .. '/' .. REPO_BRANCH .. '/'

-- El manifest define TODOS los archivos del proyecto y sus dependencias.
-- El updater lo descarga primero para saber qué necesita instalar/actualizar.
local MANIFEST_URL   = RAW_BASE_URL .. 'manifest.json'
local RAW_SCRIPT_URL = RAW_BASE_URL .. 'Chat.lua'

local CURRENT_VERSION = '1.0.1'

-- ── Estado del updater ────────────────────────────────────────
local _upd = {
    status       = nil,      -- nil | 'idle' | 'checking' | 'downloading' | 'done' | 'error'
    remoteVer    = '',
    log          = {},       -- tabla de strings con el progreso detallado
    logScroll    = true,     -- auto-scroll del log
    progress     = 0.0,      -- 0..1 para la barra de progreso
    progressMsg  = '',
    totalFiles   = 0,
    doneFiles    = 0,
    failedFiles  = {},
    autoChecked  = false,    -- ya hizo la verificación automática al inicio
    silentMode   = false,    -- true = no mostrar UI, solo toast al terminar
    needsReload  = false,    -- hay archivos actualizados que requieren reload
    -- Manifest cacheado
    manifest     = nil,
}

local function updLog(msg, color)
    color = color or 'normal'  -- 'normal' | 'ok' | 'warn' | 'error' | 'info'
    table.insert(_upd.log, { msg = msg, color = color, t = os.clock() })
    if #_upd.log > 200 then table.remove(_upd.log, 1) end
    _upd.logScroll = true
end

-- ============================================================
--  DEPENDENCIAS
-- ============================================================
local imgui    = require 'mimgui'
local memory   = require 'memory'
local ffi      = require 'ffi'
local bit      = require 'bit'
local encoding = require 'encoding'
local raknet   = require 'samp.raknet'

encoding.default = 'CP1252'
local u8 = encoding.UTF8

-- mimgui_blur: efecto glassmorphism bajo el panel del chat.
-- Cargado con pcall — si la DLL no está, el script funciona sin blur.
local _blur = nil
local _blurOk = false
do
    local ok, mod = pcall(require, 'mimgui_blur')
    if ok and mod then
        _blur   = mod
        _blurOk = true
    end
end

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
pcall(ffi.cdef, [[
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
]])
local SQLITE_ROW       = 100
local SQLITE_DONE      = 101
local SQLITE_TRANSIENT = ffi.cast('void*', -1)

local db = ffi.new('sqlite3*[1]')
local DB_PATH

local function db_exec(sql)
    local err = ffi.new('char*[1]')
    local rc  = _sq.sqlite3_exec(db[0], sql, nil, nil, err)
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
    _sq.sqlite3_prepare_v2(db[0], 'INSERT OR REPLACE INTO config(key,value) VALUES(?,?);', -1, stmt_set, nil)
    _sq.sqlite3_prepare_v2(db[0], 'SELECT value FROM config WHERE key=?;', -1, stmt_get, nil)
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
local _dirtyCount = 0

local function markDirty(key, value)
    if _dirty[key] == value then return end
    _dirty[key]  = value
    _dirtyTimer  = os.clock() * 1000
    _dirtyCount  = _dirtyCount + 1
end

local function flushDirty()
    if _dirtyCount == 0 then return end
    local now = os.clock() * 1000
    if now - _dirtyTimer >= SAVE_DELAY then
        db_exec('BEGIN;')
        for k, v in pairs(_dirty) do db_set(k, v) end
        db_exec('COMMIT;')
        _dirty      = {}
        _dirtyCount = 0
    end
    if _CMD and _CMD.recentCmdsDirty then
        if now - _CMD.recentCmdsSaveTimer >= 3000 then
            pcall(saveRecentCmds)
            _CMD.recentCmdsDirty = false
        end
    end
end

-- ============================================================
--  SISTEMA DE ANIMACIONES
-- ============================================================
-- Lerp exponencial suave: factor 0..1 controla velocidad
local function lerpSmooth(current, target, speed, dt)
    dt = dt or 0.016
    local t = 1.0 - math.exp(-speed * dt)
    return current + (target - current) * t
end

-- Easing out cubic para transiciones de UI
local function easeOutCubic(t)
    t = 1 - t
    return 1 - t * t * t
end

-- Easing in-out sine
local function easeInOutSine(t)
    return -(math.cos(math.pi * t) - 1) / 2
end

-- Pulso sinusoidal (0..1)
local function pulse(speed, offset)
    offset = offset or 0
    return (math.sin(os.clock() * speed + offset) + 1) * 0.5
end

-- Estado global de animaciones
local _anim = {
    -- Chat open/close
    chatAlpha        = 0.0,   -- alpha actual del fondo del chat (animado)
    chatSlideY       = -8.0,  -- offset Y del slide de apertura
    chatTargetAlpha  = 0.0,
    chatTargetSlide  = 0.0,

    -- Scroll suave
    scrollCurrent    = 0.0,   -- posicion actual del scroll (float, animado)
    scrollTarget     = 0.0,   -- posicion objetivo
    scrollToBottom   = true,  -- flag: ir al final en el próximo frame (se resuelve DESPUÉS de leer max_scroll)
    scrollVelocity   = 0.0,   -- velocidad actual (para inercia)
    scrollAtBottom   = true,

    -- Input border glow
    inputGlow        = 0.0,   -- 0..1 intensidad del glow del borde del input

    -- Badge unread pulse
    badgePulse       = 0.0,

    -- Emoji picker
    emojiPickerScale = 0.0,   -- 0..1 animacion de apertura del picker
    emojiPickerAlpha = 0.0,

    -- Toast slide
    toastOffsets     = {},    -- por toast, offset X de slide-in

    -- Scrollbar highlight
    scrollbarGlow    = 0.0,   -- glow cuando esta en uso

    -- Hover por mensaje (idx -> alpha)
    msgHover         = {},

    -- Timestamp del ultimo frame para dt
    lastFrameTime    = os.clock(),
    dt               = 0.016,
}

-- Actualizar dt cada frame
local function updateAnimDt()
    local now = os.clock()
    _anim.dt  = math.min(now - _anim.lastFrameTime, 0.05)  -- cap en 50ms
    _anim.lastFrameTime = now
end

-- ============================================================
--  HOOK SYSTEM
-- ============================================================
local hook = { hooks = {} }

function hook.new(cast, callback, hook_addr, size, trampoline, org_bytes_tramp)
    size       = size or 5
    trampoline = trampoline or false
    local new_hook, mt = {}, {}
    local detour_addr  = tonumber(ffi.cast('intptr_t', ffi.cast('void*', ffi.cast(cast, callback))))
    local void_addr    = ffi.cast('void*', hook_addr)
    local old_prot     = ffi.new('unsigned long[1]')
    local org_bytes    = ffi.new('uint8_t[?]', size)
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

local _S = {
    openChat             = false,
    openColor            = 0,
    noScroll             = false,
    max_scroll           = 0,
    current_scroll       = 0,
    setup_current_scroll = 0,
    lastHistoryIdx       = 0,
    unreadCount          = 0,
    chatInputActive      = false,
    needsFocus           = false,
    contextMenuOpen      = false,
    contextMenuId        = nil,
    pendingContextMenu   = false,
    selPreviewActive     = false,
    selPreviewTimeout    = 0,
    rbuttonPending       = false,
    rbuttonMsgId         = nil,
    pendingEditModal     = false,
    timestampStatus      = true,
    showChat             = true,
    searchActive         = false,
    forceClosePopups     = false,
    emojiAnchorX         = 0,
    emojiAnchorY         = 0,
    showEmojiPicker      = false,
    emojiPickerBtnTex    = nil,
    inputForceSetText    = nil,
    -- Nuevo: pendiente de insertar emoji en el input
    pendingEmojiInsert   = nil,
    -- Para efecto ripple en mensajes
    lastClickedMsgId     = nil,
    lastClickTime        = 0,
}

-- scrollbar: ya no se usa (reemplazado por scrollbar DrawList custom)

local INPUT_BUF = 512
local inputChat = imgui.new.char[INPUT_BUF]()
local searchBuf       = imgui.new.char[256]()
local searchResults   = {}

local editLine  = imgui.new.char[512]()
local editColor = imgui.new.char[10]()
local editTime  = imgui.new.char[12]()
local editId    = 1

local layout = ffi.new('char[10]')
local info   = ffi.new('char[10]')

-- ============================================================
--  CACHE DE RENDIMIENTO
-- ============================================================
local _renderCacheVer  = 0
local _mentionCacheVer = 0
local _blockCacheVer   = 0

local function invalidateRenderCache()  _renderCacheVer  = _renderCacheVer  + 1 end
local function invalidateMentionCache() _mentionCacheVer = _mentionCacheVer + 1 end
local function invalidateBlockCache()   _blockCacheVer   = _blockCacheVer   + 1 end

-- ============================================================
--  SISTEMA DE EMOJIS DISCORD
-- ============================================================
local DISCORD_TOKEN    = ''
local DISCORD_GUILD_ID = ''

local _discordEmojis   = {}
local _emojiByName     = {}
local _emojiCacheDir   = ''
local _emojiLoadState  = 'idle'
local _emojiLoadMsg    = ''

local function findEmojiByName(name)
    return _emojiByName[name] or _emojiByName[name:lower()]
end

local function rebuildEmojiIndex()
    _emojiByName = {}
    for _, e in ipairs(_discordEmojis) do
        _emojiByName[e.name]          = e
        _emojiByName[e.name:lower()]  = e
    end
end

local function loadEmojiTexture(e)
    if e.tex or e.loadFailed then return end
    if not doesFileExist(e.path) then e.loadFailed = true; return end
    local ok, tex = pcall(imgui.CreateTextureFromFile, e.path)
    if ok and tex ~= nil then
        e.tex = tex
    else
        e.loadFailed = true
    end
end

local _inputEmojiTokens = {}

local function parseInputEmojiTokens(text)
    local tokens = {}
    local i = 1
    while i <= #text do
        local s, e2, name = text:find(':([%w_]+):', i)
        if not s then break end
        local entry = findEmojiByName(name)
        if entry then
            table.insert(tokens, { name=name, s=s, e=e2, entry=entry })
            loadEmojiTexture(entry)
        end
        i = e2 + 1
    end
    return tokens
end

-- ============================================================
--  AUTOCOMPLETADO DE EMOJIS EN EL INPUT
-- ============================================================
local _emojiSuggest = {
    list    = {},
    active  = false,
    prefix  = '',
    selIdx  = 1,
}

local function detectEmojiPrefix(text)
    local lastColon = nil
    local i = #text
    while i >= 1 do
        local c = text:sub(i, i)
        if c == ':' then lastColon = i; break end
        if c == ' ' then break end
        i = i - 1
    end
    if not lastColon then return nil end
    local after = text:sub(lastColon + 1)
    if after:find(':') then return nil end
    local prefix = after
    if #prefix == 0 then return nil end
    return prefix
end

local function updateEmojiSuggestions(text)
    if _emojiLoadState ~= 'ready' or #_discordEmojis == 0 then
        _emojiSuggest.active = false; return
    end
    local prefix = detectEmojiPrefix(text)
    if not prefix or #prefix < 1 then
        _emojiSuggest.active = false; _emojiSuggest.prefix = ''; _emojiSuggest.list = {}; return
    end
    if prefix == _emojiSuggest.prefix then return end
    _emojiSuggest.prefix = prefix; _emojiSuggest.selIdx = 1
    local prefL = prefix:lower(); local list = {}
    for _, e in ipairs(_discordEmojis) do
        if e.name:lower():sub(1, #prefL) == prefL then
            table.insert(list, e)
            if #list >= 8 then break end
        end
    end
    _emojiSuggest.list   = list
    _emojiSuggest.active = #list > 0
end

-- ============================================================
--  INSERTAR EMOJI EN EL INPUT
-- ============================================================

-- insertEmojiInInput: llamado desde el picker al hacer click.
-- Escribe al buffer inmediatamente (mismo frame) Y deja pendingEmojiInsert
-- para el siguiente frame como respaldo, garantizando que el InputText
-- siempre reciba el nuevo valor independientemente del orden de render.
local function insertEmojiInInput(name)
    local token   = ':' .. name .. ':'
    local cur     = u8:decode(ffi.string(inputChat))
    local newText = cur .. token
    if #newText <= SAMP_INPUT_LIMIT then
        local encoded = u8(newText)
        imgui.StrCopy(inputChat, encoded)       -- escritura inmediata
        _S.pendingEmojiInsert    = encoded      -- respaldo para el próximo frame
        _S.needsFocus            = true
        _CMD.lastSuggestionInput = nil
    end
end

-- completeEmojiSuggestion: llamado desde el autocomplete de :nombre:
-- Reemplaza ":prefijo" al final del buffer con ":nombre:" completo.
-- Misma lógica de escritura doble que insertEmojiInInput.
local function completeEmojiSuggestion(e)
    if not e then return end
    local cur     = u8:decode(ffi.string(inputChat))
    local prefix  = _emojiSuggest.prefix
    local newText = cur:sub(1, #cur - #prefix - 1) .. ':' .. e.name .. ':'
    if #newText <= SAMP_INPUT_LIMIT then
        local encoded = u8(newText)
        imgui.StrCopy(inputChat, encoded)
        _S.pendingEmojiInsert    = encoded
        _S.needsFocus            = true
        _CMD.lastSuggestionInput = nil
    end
    _emojiSuggest.active = false
    _emojiSuggest.list   = {}
    _emojiSuggest.prefix = ''
end

-- ============================================================
--  WININET
-- ============================================================
pcall(ffi.cdef, [[
    typedef void*         HINTERNET;
    typedef unsigned long DWORD;
    typedef const char*   LPCSTR;
    typedef void*         LPVOID;
    typedef bool          BOOL;
    typedef char*         LPSTR;

    HINTERNET InternetOpenA(LPCSTR lpszAgent, DWORD dwAccessType,
        LPCSTR lpszProxy, LPCSTR lpszProxyBypass, DWORD dwFlags);
    HINTERNET InternetConnectA(HINTERNET hInternet, LPCSTR lpszServerName,
        unsigned short nServerPort, LPCSTR lpszUserName, LPCSTR lpszPassword,
        DWORD dwService, DWORD dwFlags, unsigned long dwContext);
    HINTERNET HttpOpenRequestA(HINTERNET hConnect, LPCSTR lpszVerb,
        LPCSTR lpszObjectName, LPCSTR lpszVersion, LPCSTR lpszReferrer,
        LPCSTR* lplpszAcceptTypes, DWORD dwFlags, unsigned long dwContext);
    BOOL HttpSendRequestA(HINTERNET hRequest, LPCSTR lpszHeaders,
        DWORD dwHeadersLength, LPVOID lpOptional, DWORD dwOptionalLength);
    BOOL InternetReadFile(HINTERNET hFile, LPVOID lpBuffer,
        DWORD dwNumberOfBytesToRead, DWORD* lpdwNumberOfBytesRead);
    BOOL InternetCloseHandle(HINTERNET hInternet);
    BOOL HttpQueryInfoA(HINTERNET hRequest, DWORD dwInfoLevel,
        LPVOID lpBuffer, DWORD* lpdwBufferLength, DWORD* lpdwIndex);
]])

local _wininet = nil
local function getWinINet()
    if not _wininet then
        local ok, lib = pcall(ffi.load, 'wininet')
        if ok then _wininet = lib end
    end
    return _wininet
end

local INTERNET_OPEN_TYPE_DIRECT        = 1
local INTERNET_SERVICE_HTTP            = 3
local INTERNET_FLAG_SECURE             = 0x00800000
local INTERNET_FLAG_RELOAD             = 0x80000000
local INTERNET_FLAG_NO_CACHE_WRITE     = 0x04000000
local INTERNET_FLAG_IGNORE_CERT_ERRORS = 0x00003000
local HTTP_QUERY_STATUS_CODE           = 19
local HTTP_QUERY_FLAG_NUMBER           = 0x20000000
local INTERNET_DEFAULT_HTTPS_PORT      = 443

local function parseUrl(url)
    local host, path, useSSL, port
    host, path = url:match('https://([^/?]+)(/?[^?]*)')
    if host then
        useSSL = true; port = INTERNET_DEFAULT_HTTPS_PORT
    else
        host, path = url:match('http://([^/?]+)(/?[^?]*)')
        useSSL = false; port = 80
    end
    if not host then return nil end
    local qs = url:match('%?(.+)$')
    if qs then path = (path or '') .. '?' .. qs end
    if not path or path == '' then path = '/' end
    local portOverride = host:match(':(%d+)$')
    if portOverride then port = tonumber(portOverride); host = host:gsub(':%d+$','') end
    return host, path, useSSL, port
end

local function httpGet(url, headers)
    local inet = getWinINet()
    if not inet then return nil, 'WinINet no disponible' end
    local host, path, useSSL, port = parseUrl(url)
    if not host then return nil, 'URL invalida: ' .. url end
    local hInet = inet.InternetOpenA('MoonLoaderChat/1.0', INTERNET_OPEN_TYPE_DIRECT, nil, nil, 0)
    if hInet == nil then return nil, 'InternetOpenA fallo' end
    local hConn = inet.InternetConnectA(hInet, host, port, nil, nil, INTERNET_SERVICE_HTTP, 0, 0)
    if hConn == nil then inet.InternetCloseHandle(hInet); return nil, 'InternetConnectA fallo' end
    local reqFlags = INTERNET_FLAG_RELOAD + INTERNET_FLAG_NO_CACHE_WRITE
    if useSSL then reqFlags = reqFlags + INTERNET_FLAG_SECURE + INTERNET_FLAG_IGNORE_CERT_ERRORS end
    local hReq = inet.HttpOpenRequestA(hConn, 'GET', path, 'HTTP/1.1', nil, nil, reqFlags, 0)
    if hReq == nil then
        inet.InternetCloseHandle(hConn); inet.InternetCloseHandle(hInet)
        return nil, 'HttpOpenRequestA fallo'
    end
    local headerStr = nil; local headerLen = 0
    if headers and #headers > 0 then
        headerStr = table.concat(headers, '\r\n') .. '\r\n'
        headerLen = #headerStr
    end
    local sent = inet.HttpSendRequestA(hReq, headerStr, headerLen, nil, 0)
    if sent == false then
        inet.InternetCloseHandle(hReq); inet.InternetCloseHandle(hConn)
        inet.InternetCloseHandle(hInet); return nil, 'HttpSendRequestA fallo'
    end
    local statusBuf = ffi.new('DWORD[1]', 0)
    local statusLen = ffi.new('DWORD[1]', ffi.sizeof('DWORD'))
    inet.HttpQueryInfoA(hReq, HTTP_QUERY_STATUS_CODE + HTTP_QUERY_FLAG_NUMBER, statusBuf, statusLen, nil)
    local statusCode = tonumber(statusBuf[0])
    local chunks = {}; local bufSize = 8192
    local buf = ffi.new('char[?]', bufSize); local nread = ffi.new('DWORD[1]', 0)
    while true do
        nread[0] = 0
        local ok = inet.InternetReadFile(hReq, buf, bufSize, nread)
        if not ok or nread[0] == 0 then break end
        table.insert(chunks, ffi.string(buf, nread[0])); wait(0)
    end
    inet.InternetCloseHandle(hReq); inet.InternetCloseHandle(hConn); inet.InternetCloseHandle(hInet)
    local body = table.concat(chunks)
    if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
        return nil, 'HTTP ' .. statusCode .. ': ' .. body:sub(1, 150)
    end
    return body, nil
end

local function httpDownloadToFile(url, destPath, headers, progressFn)
    local inet = getWinINet()
    if not inet then
        if downloadUrlToFile then downloadUrlToFile(url, destPath); wait(200); return doesFileExist(destPath) end
        return false
    end
    local host, path, useSSL, port = parseUrl(url)
    if not host then return false end
    local hInet = inet.InternetOpenA('MoonLoaderChat/1.0', INTERNET_OPEN_TYPE_DIRECT, nil, nil, 0)
    if hInet == nil then return false end
    local hConn = inet.InternetConnectA(hInet, host, port, nil, nil, INTERNET_SERVICE_HTTP, 0, 0)
    if hConn == nil then inet.InternetCloseHandle(hInet); return false end
    local reqFlags = INTERNET_FLAG_RELOAD + INTERNET_FLAG_NO_CACHE_WRITE
    if useSSL then reqFlags = reqFlags + INTERNET_FLAG_SECURE + INTERNET_FLAG_IGNORE_CERT_ERRORS end
    local hReq = inet.HttpOpenRequestA(hConn, 'GET', path, 'HTTP/1.1', nil, nil, reqFlags, 0)
    if hReq == nil then inet.InternetCloseHandle(hConn); inet.InternetCloseHandle(hInet); return false end
    local headerStr = nil; local headerLen = 0
    if headers and #headers > 0 then headerStr = table.concat(headers, '\r\n') .. '\r\n'; headerLen = #headerStr end
    local sent = inet.HttpSendRequestA(hReq, headerStr, headerLen, nil, 0)
    if sent == false then
        inet.InternetCloseHandle(hReq); inet.InternetCloseHandle(hConn); inet.InternetCloseHandle(hInet); return false
    end
    local f = io.open(destPath, 'wb')
    if not f then inet.InternetCloseHandle(hReq); inet.InternetCloseHandle(hConn); inet.InternetCloseHandle(hInet); return false end
    local bufSize = 16384; local buf = ffi.new('char[?]', bufSize); local nread = ffi.new('DWORD[1]', 0); local total = 0
    while true do
        nread[0] = 0
        local ok = inet.InternetReadFile(hReq, buf, bufSize, nread)
        if not ok or nread[0] == 0 then break end
        f:write(ffi.string(buf, nread[0])); total = total + nread[0]
        if progressFn then progressFn(total) end; wait(0)
    end
    f:close()
    inet.InternetCloseHandle(hReq); inet.InternetCloseHandle(hConn); inet.InternetCloseHandle(hInet)
    return total > 0
end

local function parseEmojiJson(content)
    local emojis = {}
    for obj in content:gmatch('{([^}]+)}') do
        local id       = obj:match('"id"%s*:%s*"(%d+)"')
        local name     = obj:match('"name"%s*:%s*"([^"]+)"')
        local animated = obj:match('"animated"%s*:%s*(%a+)')
        if id and name then
            table.insert(emojis, { id=id, name=name, animated=(animated=='true') })
        end
    end
    return emojis
end

local function fetchDiscordEmojis()
    if DISCORD_TOKEN == '' or DISCORD_GUILD_ID == '' then
        _emojiLoadState = 'error'; _emojiLoadMsg = u8('Configura el Token y Guild ID'); return
    end
    if _emojiLoadState == 'fetching' or _emojiLoadState == 'downloading' then return end
    _emojiLoadState = 'fetching'; _emojiLoadMsg = u8('Conectando con Discord...'); _discordEmojis = {}
    lua_thread.create(function()
        local cleanToken   = DISCORD_TOKEN:match('^%s*(.-)%s*$')
        local cleanGuildId = DISCORD_GUILD_ID:match('^%s*(.-)%s*$')
        local apiUrl = 'https://discord.com/api/v10/guilds/' .. cleanGuildId .. '/emojis'
        local content, err = httpGet(apiUrl, {
            'Authorization: Bot ' .. cleanToken,
            'User-Agent: DiscordBot (moonloader, 1.0)',
            'Content-Type: application/json',
        })
        if not content or content == '' then
            _emojiLoadState = 'error'; _emojiLoadMsg = u8('Error de red: ' .. (err or 'sin respuesta')); return
        end
        if content:find('"code"') or content:find('"message"') then
            local code = content:match('"code"%s*:%s*(%d+)') or '?'
            local msg  = content:match('"message"%s*:%s*"([^"]+)"') or content:sub(1, 80)
            _emojiLoadState = 'error'; _emojiLoadMsg = u8('Discord ' .. code .. ': ' .. msg); return
        end
        local jf = io.open(_emojiCacheDir .. 'emojis.json', 'w')
        if jf then jf:write(content); jf:close() end
        local parsed = parseEmojiJson(content)
        if #parsed == 0 then
            _emojiLoadState = 'error'; _emojiLoadMsg = u8('Sin emojis (verifica permisos del bot)'); return
        end
        for _, e in ipairs(parsed) do
            table.insert(_discordEmojis, { id=e.id, name=e.name, animated=e.animated,
                path=_emojiCacheDir .. e.id .. '.png', tex=nil, loadFailed=false })
        end
        _emojiLoadState = 'downloading'
        local total = #_discordEmojis; local done = 0; local failed = 0
        for _, e in ipairs(_discordEmojis) do
            if not doesFileExist(e.path) then
                local ext = e.animated and 'gif' or 'png'
                local url = string.format('https://cdn.discordapp.com/emojis/%s.%s?size=32', e.id, ext)
                local tmp = e.path .. '.tmp'
                local ok  = httpDownloadToFile(url, tmp)
                if ok and doesFileExist(tmp) then os.rename(tmp, e.path)
                else failed = failed + 1; os.remove(tmp) end
            end
            done = done + 1; _emojiLoadMsg = u8(string.format('Descargando: %d / %d', done, total))
        end
        local cacheF = io.open(_emojiCacheDir .. 'names.dat', 'w')
        if cacheF then
            for _, e in ipairs(_discordEmojis) do cacheF:write(e.id .. '\t' .. e.name .. '\n') end
            cacheF:close()
        end
        rebuildEmojiIndex()
        _emojiLoadState = 'ready'
        _emojiLoadMsg   = u8((total - failed) .. ' emojis cargados' .. (failed > 0 and (', ' .. failed .. ' fallidos') or ''))
        addToast(u8((total - failed) .. ' emojis de Discord listos!'), imgui.ImVec4(0.4, 0.85, 0.6, 1.0), 4.0)
    end)
end

local function loadEmojisFromJson(jsonPath)
    local f = io.open(jsonPath, 'r')
    if not f then _emojiLoadState = 'error'; _emojiLoadMsg = u8('No se encontro emojis.json'); return end
    local content = f:read('*a'); f:close()
    local parsed = parseEmojiJson(content)
    if #parsed == 0 then _emojiLoadState = 'error'; _emojiLoadMsg = u8('JSON vacio o formato no reconocido'); return end
    _discordEmojis = {}
    for _, e in ipairs(parsed) do
        table.insert(_discordEmojis, { id=e.id, name=e.name, animated=e.animated,
            path=_emojiCacheDir .. e.id .. '.png', tex=nil, loadFailed=false })
    end
    _emojiLoadState = 'downloading'; local total = #_discordEmojis; _emojiLoadMsg = u8('0 / ' .. total)
    lua_thread.create(function()
        local done, failed = 0, 0
        for _, e in ipairs(_discordEmojis) do
            if not doesFileExist(e.path) then
                local ext = e.animated and 'gif' or 'png'
                local url = string.format('https://cdn.discordapp.com/emojis/%s.%s?size=32', e.id, ext)
                local tmp = e.path .. '.tmp'
                local ok  = httpDownloadToFile(url, tmp)
                if ok and doesFileExist(tmp) then os.rename(tmp, e.path)
                else failed = failed + 1; os.remove(tmp) end
            end
            done = done + 1; _emojiLoadMsg = u8(string.format('Descargando: %d / %d', done, total))
        end
        local cacheF = io.open(_emojiCacheDir .. 'names.dat', 'w')
        if cacheF then
            for _, e in ipairs(_discordEmojis) do cacheF:write(e.id .. '\t' .. e.name .. '\n') end
            cacheF:close()
        end
        rebuildEmojiIndex()
        _emojiLoadState = 'ready'; _emojiLoadMsg = u8(total .. ' emojis listos')
        addToast(u8((total-failed) .. ' emojis cargados!'), imgui.ImVec4(0.4, 0.85, 0.6, 1.0), 4.0)
    end)
end

local function loadEmojisFromCache()
    local namesPath = _emojiCacheDir .. 'names.dat'
    local f = io.open(namesPath, 'r')
    if not f then return false end
    _discordEmojis = {}
    for line in f:lines() do
        local id, name = line:match('^(%d+)\t(.+)$')
        if id and name then
            local path = _emojiCacheDir .. id .. '.png'
            table.insert(_discordEmojis, { id=id, name=name, path=path, tex=nil, loadFailed=false, animated=false })
        end
    end
    f:close()
    if #_discordEmojis > 0 then
        rebuildEmojiIndex()
        _emojiLoadState = 'ready'; _emojiLoadMsg = u8(#_discordEmojis .. ' emojis (cache local)')
        return true
    end
    return false
end

-- ============================================================
--  UTILIDADES DE TEXTO
-- ============================================================
local function stripTags(text)
    return text:gsub('{%x%x%x%x%x%x%x%x}',''):gsub('{%x%x%x%x%x%x}','')
end

local function trim(s)
    return s:match('^%s*(.-)%s*$')
end

-- ============================================================
--  TOASTS — con animación slide-in mejorada
-- ============================================================
local _toasts = {}

function addToast(text, color, duration)
    color    = color    or imgui.ImVec4(0.7, 1.0, 0.7, 1.0)
    duration = duration or 3.0
    local toast = { text=text, timer=os.clock()+duration, color=color, slideX=300.0, age=0.0 }
    table.insert(_toasts, toast)
    if #_toasts > 5 then table.remove(_toasts, 1) end
    _anim.toastOffsets[#_toasts] = 300.0
end

-- ============================================================
--  ENCODING
-- ============================================================
local _iconvCache = {}
local function getConv(from, to)
    local key = from .. ':' .. to
    if not _iconvCache[key] then
        local iconv = require 'iconv'
        local cd = iconv.new(to .. '//IGNORE', from)
        if not cd then return nil end
        _iconvCache[key] = cd
    end
    return _iconvCache[key]
end

local function isRealUTF8(s)
    if not s or #s == 0 then return false end
    local i, n, hasHigh = 1, #s, false
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xC2 then return false
        elseif b < 0xE0 then
            local c = s:byte(i + 1)
            if not c or c < 0x80 or c > 0xBF then return false end
            hasHigh = true; i = i + 2
        elseif b < 0xF0 then
            local c1, c2 = s:byte(i+1), s:byte(i+2)
            if not c1 or c1 < 0x80 or c1 > 0xBF then return false end
            if not c2 or c2 < 0x80 or c2 > 0xBF then return false end
            hasHigh = true; i = i + 3
        elseif b < 0xF5 then
            local c1, c2, c3 = s:byte(i+1), s:byte(i+2), s:byte(i+3)
            if not c1 or c1 < 0x80 or c1 > 0xBF then return false end
            if not c2 or c2 < 0x80 or c2 > 0xBF then return false end
            if not c3 or c3 < 0x80 or c3 > 0xBF then return false end
            hasHigh = true; i = i + 4
        else return false end
    end
    return hasHigh
end

local _decodeCache = {}; local _decodeCacheN = 0; local _decodeCacheMax = 1000

local function smartDecode(raw)
    if not raw or raw == '' then return '' end
    local cached = _decodeCache[raw]
    if cached then return cached end
    local result
    if isRealUTF8(raw) then
        result = raw
    else
        local hasHigh = false
        for i = 1, #raw do if raw:byte(i) >= 0x80 then hasHigh = true; break end end
        if not hasHigh then
            result = raw
        else
            local encodings = { 'CP1252', 'CP1251', 'CP1250', 'CP1254', 'CP1253' }
            result = raw
            for _, enc in ipairs(encodings) do
                local cd = getConv(enc, 'UTF-8')
                if cd then
                    local ok, r = pcall(function() return cd:iconv(raw) end)
                    if ok and r and r ~= '' and isRealUTF8(r) then result = r; break end
                end
            end
        end
    end
    if _decodeCacheN >= _decodeCacheMax then _decodeCache = {}; _decodeCacheN = 0 end
    _decodeCache[raw] = result; _decodeCacheN = _decodeCacheN + 1
    return result
end

-- ============================================================
--  CARGA DE FUENTE
-- ============================================================
local _glyphRanges = nil

local function buildAndLoadFont(io, fontPath, sizePx)
    _glyphRanges = nil
    local builder = imgui.ImFontGlyphRangesBuilder()
    builder:AddRanges(io.Fonts:GetGlyphRangesDefault())
    builder:AddRanges(io.Fonts:GetGlyphRangesCyrillic())
    local rangeBlocks = {
        0x0080,0x024F, 0x0250,0x02FF, 0x0370,0x03FF, 0x0400,0x052F,
        0x0590,0x05FF, 0x0600,0x06FF, 0x2000,0x206F, 0x2070,0x209F,
        0x20A0,0x20CF, 0x2100,0x214F, 0x2190,0x21FF, 0x2200,0x22FF,
        0x2300,0x23FF, 0x2400,0x243F, 0x2460,0x24FF, 0x2500,0x257F,
        0x2580,0x259F, 0x25A0,0x25FF, 0x2600,0x26FF, 0x2700,0x27BF,
        0x27C0,0x27FF, 0x2900,0x297F, 0x2B00,0x2BFF, 0x3200,0x33FF,
    }
    for i = 1, #rangeBlocks, 2 do
        for cp = rangeBlocks[i], rangeBlocks[i+1] do builder:AddChar(cp) end
    end
    local singles = {
        0x00A1,0x00BF,0x00D7,0x00F7,0x00B5,0x00B0,0x00B1,0x00B2,0x00B3,0x00B9,
        0x00BC,0x00BD,0x00BE,0x0152,0x0153,0x0160,0x0161,0x0178,0x017D,0x017E,
        0x0192,0x011E,0x011F,0x015E,0x015F,0x0130,0x0131,0x02C6,0x02DC,
        0x2020,0x2021,0x2030,0x2039,0x203A,0x20AC,0x20BD,0x20BF,0x20B9,
    }
    for _, cp in ipairs(singles) do builder:AddChar(cp) end
    _glyphRanges = imgui.ImVector_ImWchar()
    builder:BuildRanges(_glyphRanges)
    io.Fonts:AddFontFromFileTTF(fontPath, sizePx, nil, _glyphRanges[0].Data)
    local emojiPaths = {
        getWorkingDirectory() .. '\\moonloader\\NotoEmoji-Regular.ttf',
        'C:\\Windows\\Fonts\\seguiemj.ttf',
        'C:\\Windows\\Fonts\\seguisym.ttf',
    }
    for _, ep in ipairs(emojiPaths) do
        if doesFileExist and doesFileExist(ep) then
            local cfgEmoji = imgui.ImFontConfig()
            cfgEmoji.MergeMode = true; cfgEmoji.PixelSnapH = true
            cfgEmoji.OversampleH = 1; cfgEmoji.OversampleV = 1
            local emojiRanges = imgui.new['unsigned short'][5](0x2300, 0x27BF, 0x1F300, 0x1F9FF, 0x0000)
            io.Fonts:AddFontFromFileTTF(ep, sizePx, cfgEmoji, emojiRanges)
            break
        end
    end
end

-- ============================================================
--  SISTEMA DE MENSAJES BLOQUEADOS
-- ============================================================
local blockedPatterns    = {}
local blockedPatternsLow = {}
local blockedNewBuf      = imgui.new.char[256]()

local function serializeBlocked()   return table.concat(blockedPatterns, '\n') end

local function deserializeBlocked(s)
    blockedPatterns = {}; blockedPatternsLow = {}
    if not s or s == '' then return end
    for line in s:gmatch('([^\n]+)') do
        if line ~= '' then
            table.insert(blockedPatterns, line)
            table.insert(blockedPatternsLow, line:lower())
        end
    end
    invalidateBlockCache()
end

local function addBlockedPattern(pat)
    pat = trim(pat); if pat == '' then return false end
    local patL = pat:lower()
    for _, v in ipairs(blockedPatternsLow) do if v == patL then return false end end
    table.insert(blockedPatterns, pat); table.insert(blockedPatternsLow, patL)
    invalidateBlockCache(); return true
end

local function removeBlockedPattern(i)
    table.remove(blockedPatterns, i); table.remove(blockedPatternsLow, i); invalidateBlockCache()
end

local function msgIsBlocked(m)
    if #blockedPatternsLow == 0 then return false end
    if m._blockVer == _blockCacheVer then return m._blocked end
    local hay = m._plainLower
    if not hay then hay = stripTags(m.text):lower(); m._plainLower = hay end
    local blocked = false
    for _, pat in ipairs(blockedPatternsLow) do
        if hay:find(pat, 1, true) then blocked = true; break end
    end
    m._blocked = blocked; m._blockVer = _blockCacheVer; return blocked
end

local function purgeBlockedFromHistory()
    local i = 1
    while i <= #messages do
        if msgIsBlocked(messages[i]) then table.remove(messages, i) else i = i + 1 end
    end
end

local function saveBlocked()
    local val = serializeBlocked()
    db_exec('BEGIN;'); db_set('filter.blocked', val); db_exec('COMMIT;')
    _dirty['filter.blocked'] = val
end

local function msgPassesFilter(m) return not msgIsBlocked(m) end

-- ============================================================
--  TABLA DE COLORES
-- ============================================================
local C = {}

local function makeColor(r, g, b, a)
    r=tonumber(r) or 0; g=tonumber(g) or 0; b=tonumber(b) or 0; a=tonumber(a) or 1
    return { vec=imgui.ImVec4(r,g,b,a), flt=imgui.new.float[4](r,g,b,a) }
end

local function syncVec(entry)
    entry.vec = imgui.ImVec4(entry.flt[0], entry.flt[1], entry.flt[2], entry.flt[3])
    invalidateRenderCache()
end

local function fltToStr(flt)
    return string.format('%.4f|%.4f|%.4f|%.4f', flt[0], flt[1], flt[2], flt[3])
end

local _F = {
    chatLines=15, chatLinesInt=nil, fontSize=nil, fonts={}, fontsArray={},
    fontSelected=nil, fontChanged=false, fontSizeChanged=false, showSettings=nil,
}

-- ============================================================
--  VALORES DEFAULT
-- ============================================================
local DEFAULTS = {
    ['color.chat_bg']         = '0.0000|0.0000|0.0000|0.0000',
    ['color.input_bg']        = '0.0000|0.0000|0.0000|0.9700',
    ['color.border']          = '0.0000|0.0000|0.0000|0.0000',
    ['color.text_color']      = '0.8800|0.9200|1.0000|1.0000',
    ['color.timestamp']       = '1.0000|1.0000|1.0000|0.8500',
    ['color.unread']          = '0.5373|0.0000|1.0000|1.0000',
    ['color.mention']         = '1.0000|0.8500|0.0000|1.0000',
    ['color.btn']             = '0.0000|0.0000|0.0000|1.0000',
    ['color.btn_hov']         = '0.2985|0.0000|0.2762|1.0000',
    ['color.btn_act']         = '0.0000|0.0000|0.0000|1.0000',
    ['color.scroll_bg']       = '9.8672e-07|9.9211e-07|9.9999e-07|0.5400',
    ['color.scroll_grab']     = '0.0000|0.0000|0.0000|1.0000',
    ['color.scroll_grab_act'] = '0.0000|0.0000|0.0000|1.0000',
    ['color.scroll_hov']      = '9.9998e-07|9.9999e-07|9.9999e-07|0.4000',
    ['color.scroll_act']      = '0.3880|0.0000|1.0000|0.7500',
    ['color.sel_normal']      = '0.2000|0.3000|0.5000|0.4000',
    ['color.sel_hovered']     = '0.3000|0.4000|0.7000|0.5000',
    ['val.font_size']         = '15',
    ['val.font_name']         = 'arialbd.ttf',
    ['val.line_count']        = '15',
    ['val.max_msgs']          = '500',
    ['val.timestamp']         = '1',
    ['val.mention_highlight'] = '1',
    ['filter.blocked']        = '',
    ['hotkey.settings']       = '0',
    ['discord.token']         = '',
    ['discord.guild_id']      = '',
}

local function cfgGet(key)    return db_get(key) or DEFAULTS[key] or '' end
local function cfgSet(key, v) markDirty(key, v) end

local function parseColor(str)
    local r,g,b,a = str:match('([^|]+)|([^|]+)|([^|]+)|([^|]+)')
    return tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1
end

-- ============================================================
--  UTILIDADES
-- ============================================================
local function splitsigned(n)
    n = tonumber(n)
    local x, y = bit.band(n, 0xffff), bit.rshift(n, 16)
    if x >= 0x8000 then x = x - 0xffff end
    if y >= 0x8000 then y = y - 0xffff end
    return x, y
end

local function learnCmdsFromText(text)
    local plain = stripTags(text)
    for cmd in plain:gmatch('(/[%a][%a%d_]*)') do
        if #cmd >= 2 and #cmd <= 32 then
            local cmdL = cmd:lower()
            if not _CMD.recentCmdsSet[cmdL] then
                table.insert(_CMD.recentCmds, cmdL); _CMD.recentCmdsSet[cmdL] = true
                if #_CMD.recentCmds > 200 then
                    local removed = table.remove(_CMD.recentCmds, 1); _CMD.recentCmdsSet[removed] = nil
                end
            end
        end
    end
end

local function pushMsg(entry)
    table.insert(messages, entry)
    if #messages > MAX_MESSAGES then
        local removed = table.remove(messages, 1)
        removed._plainLower = nil; removed._blocked = nil
    end
    if not _S.openChat then _S.unreadCount = _S.unreadCount + 1 end
    pcall(learnCmdsFromText, entry.text)
    -- Si el usuario no está scrolleando manualmente, marcar para ir al final
    -- No usamos 999999 para evitar race condition con max_scroll del frame anterior
    if not _S.noScroll then
        _anim.scrollToBottom = true
    end
end

local function refreshSearch()
    local q = ffi.string(searchBuf):lower()
    searchResults = {}
    if q == '' then return end
    for i, m in ipairs(messages) do
        local plain = m._plainLower
        if not plain then plain = stripTags(m.text):lower(); m._plainLower = plain end
        if plain:find(q, 1, true) then table.insert(searchResults, i) end
    end
end

-- ============================================================
--  MENCION
-- ============================================================
local mentionHighlight = true
local myNick           = ''
local _myNickLower     = ''

local function setMyNick(nick)
    if nick == myNick then return end
    myNick       = nick
    _myNickLower = nick:lower()
    invalidateMentionCache()
end

local function isMention(m)
    if not mentionHighlight or _myNickLower == '' then return false end
    if m._mentionVer == _mentionCacheVer then return m._isMention end
    local plain = m._plainLower
    if not plain then plain = stripTags(m.text):lower(); m._plainLower = plain end
    local result = plain:find(_myNickLower, 1, true) ~= nil
    m._isMention = result; m._mentionVer = _mentionCacheVer; return result
end

-- ============================================================
--  AUTOCOMPLETADO DE COMANDOS
-- ============================================================
_CMD = {
    suggestions         = {},
    suggestIdx          = -1,
    recentCmds          = {},
    recentCmdsSet       = {},
    recentCmdsDirty     = false,
    recentCmdsSaveTimer = 0,
    lastSuggestionInput = nil,
}

local _builtinCmds = { '/timestamp', '/clearchat', '/chconfig' }

local function registerCmd(cmd)
    local cmdL = cmd:lower()
    if _CMD.recentCmdsSet[cmdL] then
        for i, v in ipairs(_CMD.recentCmds) do
            if v == cmdL then table.remove(_CMD.recentCmds, i); break end
        end
    end
    table.insert(_CMD.recentCmds, 1, cmdL); _CMD.recentCmdsSet[cmdL] = true
    if #_CMD.recentCmds > 200 then
        local removed = table.remove(_CMD.recentCmds); _CMD.recentCmdsSet[removed] = nil
    end
    _CMD.recentCmdsDirty = true; _CMD.recentCmdsSaveTimer = os.clock() * 1000
end

local function updateSuggestions(inputText)
    if inputText == _CMD.lastSuggestionInput then return end
    _CMD.lastSuggestionInput = inputText
    if inputText == '' or inputText:sub(1,1) ~= '/' then
        if #_CMD.suggestions > 0 then _CMD.suggestions = {}; _CMD.suggestIdx = -1 end
        return
    end
    local prefix = inputText:lower(); local newSuggestions = {}; local seen = {}
    for _, cmd in ipairs(_builtinCmds) do
        local cmdL = cmd:lower()
        if cmdL:sub(1, #prefix) == prefix and cmdL ~= prefix and not seen[cmdL] then
            seen[cmdL] = true; table.insert(newSuggestions, cmd)
        end
    end
    for _, cmdL in ipairs(_CMD.recentCmds) do
        if not seen[cmdL] and cmdL:sub(1, #prefix) == prefix and cmdL ~= prefix then
            seen[cmdL] = true; table.insert(newSuggestions, cmdL)
        end
        if #newSuggestions >= 8 then break end
    end
    local changed = (#newSuggestions ~= #_CMD.suggestions)
    if not changed then
        for i, v in ipairs(newSuggestions) do if _CMD.suggestions[i] ~= v then changed = true; break end end
    end
    if changed then _CMD.suggestions = newSuggestions; _CMD.suggestIdx = -1 end
end

-- ============================================================
--  SISTEMA DE HOTKEY
-- ============================================================
local VK_NAMES = {
    [0x70]='F1',[0x71]='F2',[0x72]='F3',[0x73]='F4',[0x74]='F5',[0x75]='F6',
    [0x76]='F7',[0x77]='F8',[0x78]='F9',[0x79]='F10',[0x7A]='F11',[0x7B]='F12',
    [0x60]='Num0',[0x61]='Num1',[0x62]='Num2',[0x63]='Num3',[0x64]='Num4',
    [0x65]='Num5',[0x66]='Num6',[0x67]='Num7',[0x68]='Num8',[0x69]='Num9',
    [0x2D]='Ins',[0x2E]='Del',[0x24]='Home',[0x23]='End',
    [0x21]='PgUp',[0x22]='PgDn',
    [0x25]='Left',[0x26]='Up',[0x27]='Right',[0x28]='Down',
    [0x20]='Space',
    [0x30]='0',[0x31]='1',[0x32]='2',[0x33]='3',[0x34]='4',
    [0x35]='5',[0x36]='6',[0x37]='7',[0x38]='8',[0x39]='9',
}
for i = 65, 90 do VK_NAMES[i] = string.char(i) end

local function vkName(vk) return VK_NAMES[vk] or string.format('VK_%02X', vk) end

local hotkeyVK       = 0
local hotkeyCapture  = false
local hotkeyLastName = 'Ninguna'

-- ============================================================
--  EXPORTACION DE CHAT
-- ============================================================
local function exportChatToFile()
    local path = getWorkingDirectory() .. '\\config\\chat_export_' .. os.date('%Y%m%d_%H%M%S') .. '.txt'
    local f = io.open(path, 'w')
    if not f then addToast('Error al exportar chat', imgui.ImVec4(1,0.3,0.3,1)); return end
    f:write('--- Chat MImGui export --- ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n\n')
    for _, m in ipairs(messages) do f:write((m.timestamp or '') .. ' ' .. stripTags(m.text) .. '\n') end
    f:close(); addToast('Chat exportado a config\\', imgui.ImVec4(0.5,1,0.6,1))
end

local pInput = nil

-- ============================================================
--  CARGA DE CONFIG
-- ============================================================
local function loadConfig()
    local function loadEntry(key)
        local r,g,b,a = parseColor(cfgGet(key)); return makeColor(r,g,b,a)
    end
    C.chat=loadEntry('color.chat_bg'); C.input=loadEntry('color.input_bg')
    C.border=loadEntry('color.border'); C.text=loadEntry('color.text_color')
    C.timestamp=loadEntry('color.timestamp'); C.unread=loadEntry('color.unread')
    C.mention=loadEntry('color.mention'); C.btn=loadEntry('color.btn')
    C.btnHov=loadEntry('color.btn_hov'); C.btnAct=loadEntry('color.btn_act')
    C.scrollBG=loadEntry('color.scroll_bg'); C.scrollGrab=loadEntry('color.scroll_grab')
    C.scrollGrabActive=loadEntry('color.scroll_grab_act'); C.scrollHov=loadEntry('color.scroll_hov')
    C.scrollAct=loadEntry('color.scroll_act'); C.selNormal=loadEntry('color.sel_normal')
    C.selHovered=loadEntry('color.sel_hovered')
    MAX_MESSAGES=tonumber(cfgGet('val.max_msgs')) or 500
    _F.chatLines=tonumber(cfgGet('val.line_count')) or 15
    _F.chatLinesInt=imgui.new.int(_F.chatLines)
    _F.fontSize=imgui.new.int(tonumber(cfgGet('val.font_size')) or 15)
    _S.openColor=0; mentionHighlight=cfgGet('val.mention_highlight') ~= '0'
    deserializeBlocked(cfgGet('filter.blocked'))
    _S.timestampStatus=cfgGet('val.timestamp') ~= '0'
    hotkeyVK=tonumber(cfgGet('hotkey.settings')) or 0
    hotkeyLastName=hotkeyVK ~= 0 and vkName(hotkeyVK) or 'Ninguna'
    DISCORD_TOKEN=cfgGet('discord.token'); DISCORD_GUILD_ID=cfgGet('discord.guild_id')
    invalidateRenderCache()
end

local function saveRecentCmds()
    local val = table.concat(_CMD.recentCmds, '\n')
    db_exec('BEGIN;'); db_set('cache.recent_cmds', val); db_exec('COMMIT;')
end

local function loadRecentCmds()
    local val = db_get('cache.recent_cmds')
    if not val or val == '' then return end
    _CMD.recentCmds = {}; _CMD.recentCmdsSet = {}
    for line in val:gmatch('([^\n]+)') do
        if line ~= '' and #_CMD.recentCmds < 200 then
            local cmdL = line:lower()
            table.insert(_CMD.recentCmds, cmdL); _CMD.recentCmdsSet[cmdL] = true
        end
    end
end

-- ============================================================
--  RENDER DE TEXTO — CON EMOJIS INLINE
-- ============================================================
local function parseColorSegments(text, defaultVec)
    local segments = {}
    local full  = text:gsub('{(%x%x%x%x%x%x)}', '{%1FF}')
    local color = defaultVec
    local start = 1
    local a, b = full:find('{........}', start)
    while a do
        local t = full:sub(start, a - 1)
        if #t > 0 then
            table.insert(segments, { t=t, r=color.x, g=color.y, b=color.z, a=color.w })
        end
        local clr = full:sub(a + 1, b - 1)
        if clr:upper() == 'STANDART' or clr:upper() == 'FFFFFFFF' then
            color = defaultVec
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
        start = b + 1; a, b = full:find('{........}', start)
    end
    if #full >= start then
        local t = full:sub(start)
        if #t > 0 then table.insert(segments, { t=t, r=color.x, g=color.y, b=color.z, a=color.w }) end
    end
    return segments
end

local function splitSegmentByEmojis(seg)
    local result = {}
    local text   = seg.t
    local pos    = 1
    while pos <= #text do
        local s, e2, name = text:find(':([%w_]+):', pos)
        if not s then
            if pos <= #text then
                table.insert(result, {type='text', t=text:sub(pos), r=seg.r, g=seg.g, b=seg.b, a=seg.a})
            end
            break
        end
        if s > pos then
            table.insert(result, {type='text', t=text:sub(pos, s-1), r=seg.r, g=seg.g, b=seg.b, a=seg.a})
        end
        local entry = findEmojiByName(name)
        if entry then
            table.insert(result, {type='emoji', name=name, entry=entry})
        else
            table.insert(result, {type='text', t=text:sub(s, e2), r=seg.r, g=seg.g, b=seg.b, a=seg.a})
        end
        pos = e2 + 1
    end
    return result
end

local function getMsgSegments(m)
    if m._segVer == _renderCacheVer then return m._segments end
    m._segments = parseColorSegments(m.color .. (m._prefixedText or m.text), C.text.vec)
    m._segVer   = _renderCacheVer
    return m._segments
end

-- ============================================================
--  RENDER DE MENSAJE CON ANIMACIONES DE HOVER
-- ============================================================
local function renderColorText(m, msgId)
    local lineH  = imgui.GetTextLineHeight()
    local pos    = imgui.GetCursorScreenPos()
    local width  = imgui.GetContentRegionAvail().x
    local dl     = imgui.GetWindowDrawList()
    local now    = os.clock()

    -- Hover animado: interpolamos el alpha del hover rect
    local mx, my = getCursorPos()
    local isHovered = (_S.openChat and
        mx >= pos.x and mx <= pos.x + width and
        my >= pos.y and my <= pos.y + lineH)

    local prevHover = _anim.msgHover[msgId] or 0
    local targetHover = isHovered and 1.0 or 0.0
    local newHover = lerpSmooth(prevHover, targetHover, 12, _anim.dt)
    _anim.msgHover[msgId] = newHover

    -- Efecto ripple en click
    local rippleAlpha = 0
    if _S.lastClickedMsgId == msgId then
        local age = now - _S.lastClickTime
        if age < 0.4 then
            rippleAlpha = (1 - age / 0.4) * 0.3
        end
    end

    -- Fondo de mención
    if mentionHighlight and isMention(m) then
        local mc = C.mention.vec
        dl:AddRectFilled(
            imgui.ImVec2(pos.x - 4, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(mc.x, mc.y, mc.z, 0.12)))
        dl:AddRectFilled(
            imgui.ImVec2(pos.x - 4, pos.y), imgui.ImVec2(pos.x - 1, pos.y + lineH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(mc.x, mc.y, mc.z, 0.85)))
    end

    -- Fondo hover animado
    if newHover > 0.005 and _S.openChat then
        local sv = C.selHovered.vec
        dl:AddRectFilled(
            imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(sv.x, sv.y, sv.z,
                math.min(sv.w, 0.70) * newHover)))
    end

    -- Ripple de click
    if rippleAlpha > 0 then
        dl:AddRectFilled(
            imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, rippleAlpha)))
    end

    -- Preview de seleccion
    if _S.selPreviewActive and msgId == #messages then
        local sv = C.selNormal.vec
        dl:AddRectFilled(
            imgui.ImVec2(pos.x, pos.y), imgui.ImVec2(pos.x + width, pos.y + lineH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(sv.x, sv.y, sv.z, math.min(sv.w, 0.55))))
    end

    local segments  = getMsgSegments(m)
    local hasShadow = sampGetChatDisplayMode and sampGetChatDisplayMode() == 2
    local first     = true

    for _, seg in ipairs(segments) do
        local subItems = splitSegmentByEmojis(seg)
        for _, item in ipairs(subItems) do
            if item.type == 'text' and item.t ~= '' then
                if not first then imgui.SameLine(nil, 0) end
                first = false
                local cv = imgui.ImVec4(item.r, item.g, item.b, item.a)
                if hasShadow then
                    local p = imgui.GetCursorPos()
                    local sc = imgui.ImVec4(0, 0, 0, 0.75)
                    for dx = -1, 1 do
                        for dy = -1, 1 do
                            if dx ~= 0 or dy ~= 0 then
                                imgui.SetCursorPos(imgui.ImVec2(p.x+dx, p.y+dy))
                                imgui.TextColored(sc, item.t)
                                imgui.SameLine(nil, 0)
                            end
                        end
                    end
                    imgui.SetCursorPos(p)
                end
                imgui.TextColored(cv, item.t)

            elseif item.type == 'emoji' then
                if not first then imgui.SameLine(nil, 0) end
                first = false
                local e = item.entry
                loadEmojiTexture(e)

                if e and e.tex then
                    local cursorPos = imgui.GetCursorScreenPos()
                    local emojiSz   = lineH * 1.5
                    local padY      = -((emojiSz - lineH) * 0.5)
                    local ey0       = cursorPos.y + padY
                    local ey1       = ey0 + emojiSz

                    -- Usar WindowDrawList (respeta el clip rect del child window)
                    -- Solo dibujar si el emoji está dentro del área visible del clip
                    local clipMin = imgui.GetWindowDrawList():GetClipRectMin()
                    local clipMax = imgui.GetWindowDrawList():GetClipRectMax()
                    local visible = (cursorPos.x < clipMax.x and cursorPos.x + emojiSz > clipMin.x
                                 and ey1 > clipMin.y and ey0 < clipMax.y)

                    if visible then
                        local texID = ffi.cast('ImTextureID', e.tex)
                        local wdl   = imgui.GetWindowDrawList()
                        wdl:AddImage(
                            texID,
                            imgui.ImVec2(cursorPos.x, ey0),
                            imgui.ImVec2(cursorPos.x + emojiSz, ey1),
                            imgui.ImVec2(0,0), imgui.ImVec2(1,1), 0xFFFFFFFF)
                    end

                    imgui.Dummy(imgui.ImVec2(emojiSz, lineH))
                    if visible and imgui.IsItemHovered() then
                        imgui.BeginTooltip()
                        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.80, 1.0, 1.0))
                        imgui.Text(':' .. e.name .. ':')
                        imgui.PopStyleColor()
                        imgui.EndTooltip()
                    end
                else
                    local cv = imgui.ImVec4(0.65, 0.60, 0.80, 0.85)
                    imgui.TextColored(cv, ':' .. item.name .. ':')
                end
            end
        end
    end
    if first then imgui.NewLine() end
end

local function prepareMsgPrefixedText(m)
    if not _S.timestampStatus or not m.timestamp then
        m._prefixedText = m.text
    else
        local tsHex = string.format('%02X%02X%02X',
            math.floor(C.timestamp.vec.x * 255),
            math.floor(C.timestamp.vec.y * 255),
            math.floor(C.timestamp.vec.z * 255))
        m._prefixedText = '{' .. tsHex .. 'FF}' .. m.timestamp .. ' {FFFFFFFF}' .. m.text
    end
    m._segVer = _renderCacheVer - 1
end

-- ============================================================
--  INIT IMGUI
-- ============================================================
imgui.OnInitialize(function()
    local st = imgui.GetStyle()
    st.WindowTitleAlign = imgui.ImVec2(0.5, 0.5); st.WindowBorderSize = 0; st.PopupBorderSize = 0
    st.WindowRounding = 12; st.ChildRounding = 8; st.FrameRounding = 8; st.PopupRounding = 12
    st.ScrollbarRounding = 10; st.GrabRounding = 10; st.TabRounding = 8
    st.ItemSpacing = imgui.ImVec2(6, 10); st.WindowPadding = imgui.ImVec2(10, 10)
    st.FramePadding = imgui.ImVec2(8, 5)

    _F.fonts = {}; _F.fontsArray = {}; _F.fontChanged = false; _F.fontSizeChanged = false
    _F.showSettings = imgui.new.bool(false)
    loadConfig()
    imgui.GetIO().IniFilename = nil
    local io = imgui.GetIO()
    io.Fonts:Clear()
    buildAndLoadFont(io, getFolderPath(0x14) .. '\\' .. cfgGet('val.font_name'), _F.fontSize[0])
    local search, file = findFirstFile(getFolderPath(0x14) .. '\\*.ttf')
    _F.fontSelected = imgui.new.int(0)
    while file do
        table.insert(_F.fonts, file)
        if file == cfgGet('val.font_name') then _F.fontSelected[0] = #_F.fonts - 1 end
        file = findNextFile(search)
    end
    if #_F.fonts > 0 then _F.fontsArray = imgui.new['const char*'][#_F.fonts](_F.fonts) end
    _F.fontSize[0] = imgui.GetIO().Fonts.ConfigData.Data[0].SizePixels
end)

-- ============================================================
--  CALLBACK INPUT
-- ============================================================
local function TextEditCallback(cbData)
    local COMP = imgui.InputTextFlags.CallbackCompletion
    local HIST = imgui.InputTextFlags.CallbackHistory

    if cbData.EventFlag == COMP then
        if _emojiSuggest.active and #_emojiSuggest.list > 0 then
            local e = _emojiSuggest.list[_emojiSuggest.selIdx] or _emojiSuggest.list[1]
            local cur    = ffi.string(cbData.Buf, cbData.BufTextLen)
            local prefix = _emojiSuggest.prefix
            local newText = cur:sub(1, #cur - #prefix - 1) .. ':' .. e.name .. ':'
            cbData:DeleteChars(0, cbData.BufTextLen)
            cbData:InsertChars(0, u8(newText))
            cbData.BufDirty = true
            _emojiSuggest.active = false; _emojiSuggest.list = {}; _emojiSuggest.prefix = ''
            _CMD.lastSuggestionInput = nil
        elseif #_CMD.suggestions > 0 then
            local idx    = _CMD.suggestIdx > 0 and _CMD.suggestIdx or 1
            local chosen = _CMD.suggestions[idx]
            cbData:DeleteChars(0, cbData.BufTextLen)
            cbData:InsertChars(0, chosen)
            cbData.BufDirty = true
            _CMD.suggestions = {}; _CMD.suggestIdx = -1; _CMD.lastSuggestionInput = nil
        else
            local cur = sampGetChatInputText and sampGetChatInputText() or ''
            if cur ~= '' then
                cbData:DeleteChars(0, cbData.BufTextLen)
                cbData:InsertChars(0, u8(cur))
                cbData.BufDirty = true
            end
        end

    elseif cbData.EventFlag == HIST then
        local histLen = #sendHistory
        local KEY_UP = 3; local KEY_DOWN = 4

        if cbData.EventKey == KEY_UP then
            if _emojiSuggest.active and #_emojiSuggest.list > 0 then
                _emojiSuggest.selIdx = math.max(1, _emojiSuggest.selIdx - 1); return 0
            end
            if #_CMD.suggestions > 0 then
                _CMD.suggestIdx = math.max(1, (_CMD.suggestIdx <= 0 and 1 or _CMD.suggestIdx) - 1); return 0
            end
            if histLen == 0 then return 0 end
            _S.lastHistoryIdx = (_S.lastHistoryIdx == 0) and histLen or math.max(1, _S.lastHistoryIdx - 1)
        elseif cbData.EventKey == KEY_DOWN then
            if _emojiSuggest.active and #_emojiSuggest.list > 0 then
                _emojiSuggest.selIdx = math.min(#_emojiSuggest.list, _emojiSuggest.selIdx + 1); return 0
            end
            if #_CMD.suggestions > 0 then
                _CMD.suggestIdx = math.min(#_CMD.suggestions, (_CMD.suggestIdx <= 0 and 0 or _CMD.suggestIdx) + 1); return 0
            end
            if histLen == 0 then return 0 end
            _S.lastHistoryIdx = _S.lastHistoryIdx + 1
            if _S.lastHistoryIdx > histLen then _S.lastHistoryIdx = 0 end
        end

        local txt     = (_S.lastHistoryIdx > 0) and sendHistory[_S.lastHistoryIdx] or ''
        local encoded = u8(txt)
        cbData:DeleteChars(0, cbData.BufTextLen)
        if #encoded > 0 then cbData:InsertChars(0, encoded) end
        cbData.BufDirty = true
        if sampSetChatInputText then sampSetChatInputText(txt) end
    end
    return 0
end
local TextEditCallbackC = ffi.cast('int (*)(ImGuiInputTextCallbackData* data)', TextEditCallback)

-- Estado de drag de la scrollbar (declarado aquí, antes de closeChat que lo usa)
local _sbDrag = {
    active   = false,
    startY   = 0,
    startScr = 0,
}

-- ============================================================
--  HELPER: CIERRE LIMPIO
-- ============================================================
local function closeChat()
    _S.openChat = false; _S.chatInputActive = false
    ButterflyWidgetChatOpen = false
    _S.contextMenuId = nil; _S.needsFocus = false; _S.pendingContextMenu = false
    _S.contextMenuOpen = false; _S.rbuttonPending = false; _S.noScroll = false
    _S.forceClosePopups = true
    _CMD.suggestions = {}; _CMD.suggestIdx = -1; _CMD.lastSuggestionInput = nil
    _S.showEmojiPicker = false
    _emojiSuggest.active = false; _emojiSuggest.list = {}
    _S.pendingEmojiInsert = nil
    -- Resetear drag de scrollbar
    _sbDrag.active = false
    if not (_F.showSettings and _F.showSettings[0]) then
        imgui.DisableMouseInput = true; sampToggleCursor(false)
    end
    if pInput then pInput.iInputEnabled = 0 end
    -- Animación de cierre del picker
    _anim.emojiPickerScale = 0.0
    _anim.emojiPickerAlpha = 0.0
end

-- ============================================================
--  RENDER DE EMOJIS AUTOCOMPLETE (solo una definición)
-- ============================================================
local function drawEmojiAutocomplete(posX, posY, chatH, extraH)
    if not _emojiSuggest.active or #_emojiSuggest.list == 0 then return end

    local fs      = imgui.GetFontSize()
    local lh      = imgui.GetTextLineHeight()
    local emojiSz = lh * 1.5
    local rowH    = emojiSz + 6
    local padV    = 6
    local padH    = 8
    local n       = #_emojiSuggest.list
    local ww      = emojiSz + padH * 2 + 180
    local sugH    = padV + (n * rowH) + padV + fs + 8
    local sx_pos  = posY + chatH + extraH - sugH - 42

    local dl = imgui.GetForegroundDrawList()
    local mx, my = getCursorPos()

    -- Fondo principal
    dl:AddRectFilled(
        imgui.ImVec2(posX, sx_pos),
        imgui.ImVec2(posX + ww, sx_pos + sugH),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.06, 0.06, 0.10, 0.97)), 8)
    dl:AddRect(
        imgui.ImVec2(posX, sx_pos),
        imgui.ImVec2(posX + ww, sx_pos + sugH),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.40, 0.18, 0.68, 0.80)), 8, nil, 1.0)

    local cy = sx_pos + padV

    for si, e in ipairs(_emojiSuggest.list) do
        local ry  = cy
        local rh  = rowH
        local rx2 = posX + ww

        local hovered = (mx >= posX and mx <= rx2 and my >= ry and my <= ry + rh)
        if hovered then _emojiSuggest.selIdx = si end

        local isSelected = (si == _emojiSuggest.selIdx)

        if isSelected then
            dl:AddRectFilled(
                imgui.ImVec2(posX + 2, ry),
                imgui.ImVec2(rx2 - 2, ry + rh),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.28, 0.10, 0.52, 0.95)), 6)
            dl:AddRectFilled(
                imgui.ImVec2(posX + 2, ry + 2),
                imgui.ImVec2(posX + 5, ry + rh - 2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.70, 0.38, 1.00, 1.00)), 3)
        end

        if hovered and imgui.IsMouseClicked(0) then
            completeEmojiSuggestion(e)
        end

        loadEmojiTexture(e)
        local ex = posX + padH
        local ey = ry + (rh - emojiSz) * 0.5
        if e and e.tex then
            local texID = ffi.cast('ImTextureID', e.tex)
            dl:AddImage(texID,
                imgui.ImVec2(ex, ey),
                imgui.ImVec2(ex + emojiSz, ey + emojiSz),
                imgui.ImVec2(0,0), imgui.ImVec2(1,1), 0xFFFFFFFF)
        else
            dl:AddRectFilled(
                imgui.ImVec2(ex, ey),
                imgui.ImVec2(ex + emojiSz, ey + emojiSz),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.3, 0.2, 0.5, 0.5)), 4)
        end

        local tx = ex + emojiSz + 6
        local ty = ry + (rh - fs) * 0.5
        local nameColor = isSelected
            and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.00, 0.95, 1.00, 1.00))
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.60, 0.58, 0.78, 1.00))
        dl:AddText(imgui.ImVec2(tx, ty), nameColor, ':' .. e.name .. ':')

        cy = cy + rowH
    end

    dl:AddLine(
        imgui.ImVec2(posX + 6, cy + 2),
        imgui.ImVec2(posX + ww - 6, cy + 2),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.30, 0.15, 0.48, 0.40)))
    dl:AddText(
        imgui.ImVec2(posX + padH, cy + 5),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.30, 0.26, 0.42, 1.00)),
        u8('TAB completar  ESC cancelar'))
end

-- ============================================================
--  OVERLAY DE EMOJIS EN EL INPUT
-- ============================================================
local function renderInputEmojiOverlay(inputPosX, inputPosY, inputH, tokens, text)
    if #tokens == 0 then return end
    if not C or not C.input then return end

    local dl      = imgui.GetForegroundDrawList()
    local bgColor = imgui.ColorConvertFloat4ToU32(
                        imgui.ImVec4(C.input.vec.x, C.input.vec.y, C.input.vec.z, 1.0))
    local fs      = imgui.GetFontSize()
    local emojiSz = fs * 1.3
    local padX    = imgui.GetStyle().FramePadding.x
    local padY    = (inputH - emojiSz) * 0.5

    for _, tok in ipairs(tokens) do
        local e = tok.entry
        if e and e.tex then
            local before = text:sub(1, tok.s - 1)
            local tw     = imgui.CalcTextSize(before).x
            local px     = inputPosX + padX + tw

            local tokenW = imgui.CalcTextSize(text:sub(tok.s, tok.e)).x
            dl:AddRectFilled(
                imgui.ImVec2(px, inputPosY + 1),
                imgui.ImVec2(px + tokenW, inputPosY + inputH - 1),
                bgColor)

            local texID = ffi.cast('ImTextureID', e.tex)
            dl:AddImage(
                texID,
                imgui.ImVec2(px,            inputPosY + padY),
                imgui.ImVec2(px + emojiSz,  inputPosY + padY + emojiSz),
                imgui.ImVec2(0,0), imgui.ImVec2(1,1),
                0xFFFFFFFF)
        end
    end
end

-- ============================================================
--  EMOJI PICKER — con animación de escala y fade
-- ============================================================
local function drawEmojiPicker(anchorX, anchorY)
    -- Fade in/out limpio, sin escala que causaba clipping
    local targetAlpha = _S.showEmojiPicker and 1.0 or 0.0
    _anim.emojiPickerAlpha = lerpSmooth(_anim.emojiPickerAlpha, targetAlpha, 22, _anim.dt)
    local alpha = _anim.emojiPickerAlpha
    if alpha < 0.02 then return end
    if not _S.openChat then
        _S.showEmojiPicker = false
        _anim.emojiPickerAlpha = 0.0
        return
    end

    local COLS    = 9
    local BTN     = 36
    local PAD     = 8
    local SPACING = 4
    local visibleEmojis = _discordEmojis
    local rows    = math.max(1, math.ceil(#visibleEmojis / COLS))
    local gridH   = math.min(rows, 7) * (BTN + SPACING)
    local pickerW = COLS * (BTN + SPACING) + PAD * 2
    local pickerH = 28 + gridH + 24  -- header + grid + statusbar
    local sx, sy  = getScreenResolution()
    local px      = math.min(anchorX, sx - pickerW - 4)
    local py      = math.max(4, anchorY - pickerH - 6)

    -- Ventana independiente con SetNextWindowPos en coordenadas absolutas de pantalla
    imgui.SetNextWindowPos(imgui.ImVec2(px, py), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(pickerW, pickerH), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(0.97 * alpha)

    imgui.PushStyleColor(imgui.Col.WindowBg,       imgui.ImVec4(0.06, 0.06, 0.09, 0.97 * alpha))
    imgui.PushStyleColor(imgui.Col.Border,          imgui.ImVec4(0.38, 0.18, 0.62, 0.85 * alpha))
    imgui.PushStyleColor(imgui.Col.Button,         imgui.ImVec4(0.10, 0.08, 0.18, 0.80 * alpha))
    imgui.PushStyleColor(imgui.Col.ButtonHovered,  imgui.ImVec4(0.32, 0.14, 0.55, alpha))
    imgui.PushStyleColor(imgui.Col.ButtonActive,   imgui.ImVec4(0.55, 0.22, 0.82, alpha))
    imgui.PushStyleColor(imgui.Col.ScrollbarBg,    imgui.ImVec4(0.04, 0.04, 0.07, 0.85 * alpha))
    imgui.PushStyleColor(imgui.Col.ScrollbarGrab,  imgui.ImVec4(0.35, 0.15, 0.58, alpha))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.5)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarFloat(imgui.StyleVar.ScrollbarSize, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(PAD, PAD))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing,   imgui.ImVec2(SPACING, SPACING))

    local openBool = imgui.new.bool(true)
    imgui.Begin('##emoji_picker_win', openBool,
        imgui.WindowFlags.NoDecoration +
        imgui.WindowFlags.NoSavedSettings +
        imgui.WindowFlags.NoMove +
        imgui.WindowFlags.NoNav +
        imgui.WindowFlags.NoScrollWithMouse)

    -- Blur glassmorphism bajo el picker
    if _blurOk and alpha > 0.05 then
        local wp  = imgui.GetWindowPos()
        local wsz = imgui.GetWindowSize()
        pcall(_blur.applyRect,
            imgui.GetWindowDrawList(),
            imgui.ImVec2(wp.x, wp.y),
            imgui.ImVec2(wp.x + wsz.x, wp.y + wsz.y),
            3.0, 0, 10, 0)
    end

    -- Header: título + botón X
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.45, 0.80, alpha))
    imgui.Text(u8('Emojis Discord'))
    imgui.PopStyleColor()
    imgui.SameLine(pickerW - PAD * 2 - 20)
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.55, 0.10, 0.10, 0.9))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.75, 0.12, 0.12, 1.0))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.78, 0.32, 0.32, alpha))
    if imgui.Button('X##epX', imgui.ImVec2(18, 17)) then
        _S.showEmojiPicker = false
    end
    imgui.PopStyleColor(4)

    -- Grid de emojis con scroll propio
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.BeginChild('##epscroll', imgui.ImVec2(pickerW - PAD * 2, gridH), false)

    if _emojiLoadState == 'ready' and #visibleEmojis > 0 then
        for i, e in ipairs(visibleEmojis) do
            imgui.PushIDInt(i + 8000)
            loadEmojiTexture(e)
            local clicked = false

            if e.tex then
                local texID = ffi.cast('ImTextureID', e.tex)
                clicked = imgui.ImageButton(texID,
                    imgui.ImVec2(BTN, BTN),
                    imgui.ImVec2(0, 0), imgui.ImVec2(1, 1),
                    2,
                    imgui.ImVec4(0, 0, 0, 0),
                    imgui.ImVec4(1, 1, 1, 1))  -- tint siempre 1 para visibilidad
            elseif e.loadFailed then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.35, 0.65, 1))
                clicked = imgui.Button('?##epf' .. i, imgui.ImVec2(BTN, BTN))
                imgui.PopStyleColor()
            else
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.4, 0.4, 0.7))
                imgui.Button('·##epl' .. i, imgui.ImVec2(BTN, BTN))
                imgui.PopStyleColor()
            end

            if clicked then
                insertEmojiInInput(e.name)
                _S.showEmojiPicker = false
            end

            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.80, 1.0, 1.0))
                imgui.Text(':' .. e.name .. ':')
                imgui.PopStyleColor()
                imgui.EndTooltip()
            end

            imgui.PopID()
            if i % COLS ~= 0 then imgui.SameLine(nil, SPACING) end
        end

    elseif _emojiLoadState == 'fetching' or _emojiLoadState == 'downloading' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.3, 1))
        imgui.TextWrapped(u8(_emojiLoadMsg))
        imgui.PopStyleColor()
    elseif _emojiLoadState == 'error' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.30, 0.30, 1))
        imgui.TextWrapped(u8(_emojiLoadMsg))
        imgui.PopStyleColor()
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.70, 1))
        imgui.TextWrapped(u8('Configura tu servidor en Ajustes > Discord'))
        imgui.PopStyleColor()
    end

    imgui.EndChild()
    imgui.PopStyleColor()  -- ChildBg

    -- Status bar
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.38, 0.32, 0.52, alpha))
    imgui.Separator()
    if _emojiLoadState == 'ready' then
        imgui.Text(u8(#_discordEmojis .. ' emojis  |  :nombre: para insertar'))
    elseif _emojiLoadState == 'downloading' then
        imgui.Text(u8(_emojiLoadMsg))
    else
        imgui.Text(u8('Ajustes > Discord para configurar'))
    end
    imgui.PopStyleColor()

    -- Cerrar al click fuera
    local mx, my = getCursorPos()
    if imgui.IsMouseClicked(0) and
       not imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows) then
        _S.showEmojiPicker = false
    end

    if not openBool[0] then _S.showEmojiPicker = false end

    imgui.End()
    imgui.PopStyleVar(6)
    imgui.PopStyleColor(7)
end

-- ============================================================
--  SCROLLBAR CUSTOM — dibujada con DrawList, sin VSliderInt
-- ============================================================
-- Razón: VSliderInt de ImGui causa artefactos visuales (punto flotante,
-- grab que aparece fuera de contexto) cuando max_scroll es 0 o cambia
-- bruscamente. Dibujamos la scrollbar nosotros con DrawList para tener
-- control total y cero artefactos.

local function drawAnimatedScrollbar(chatH, lineH)
    if not _S.openChat then return end
    if _S.max_scroll <= 0 then return end  -- sin contenido → no dibujar

    -- Glow animado cuando se está usando
    local isScrolling = _S.noScroll
    _anim.scrollbarGlow = lerpSmooth(_anim.scrollbarGlow, isScrolling and 1.0 or 0.0, 8, _anim.dt)
    local glowA = _anim.scrollbarGlow

    -- Geometría de la scrollbar
    local winPos  = imgui.GetWindowPos()
    local sbX     = winPos.x + 4
    local sbY     = winPos.y + 12
    local sbW     = 6
    local sbH     = lineH * _F.chatLines + 12
    local rounding = 3

    -- Ratio de posición (0=top, 1=bottom)
    local ratio    = math.max(0, math.min(1, _anim.scrollCurrent / _S.max_scroll))
    -- Tamaño del grab (proporcional a la ventana visible vs contenido total)
    local grabMinH = 20
    local grabH    = math.max(grabMinH, sbH * (sbH / (sbH + _S.max_scroll)))
    local grabY    = sbY + ratio * (sbH - grabH)

    local dl = imgui.GetForegroundDrawList()
    local mx, my = getCursorPos()

    -- Hover sobre la scrollbar
    local sbHovered = (mx >= sbX and mx <= sbX + sbW and my >= sbY and my <= sbY + sbH)
    local grabHovered = (mx >= sbX and mx <= sbX + sbW and my >= grabY and my <= grabY + grabH)
    local hoverAlpha = (sbHovered or _sbDrag.active) and 1.0 or (0.5 + glowA * 0.5)

    -- Track (fondo)
    local bgC = C.scrollBG.vec
    dl:AddRectFilled(
        imgui.ImVec2(sbX, sbY),
        imgui.ImVec2(sbX + sbW, sbY + sbH),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(bgC.x, bgC.y, bgC.z, bgC.w * hoverAlpha)),
        rounding)

    -- Grab
    local grabC = _sbDrag.active and C.scrollGrabActive.vec or
                  (grabHovered   and C.scrollHov.vec        or C.scrollGrab.vec)
    -- Interpolamos hacia morado cuando hay glow activo
    local gr = grabC.x + (0.50 - grabC.x) * glowA
    local gg = grabC.y + (0.12 - grabC.y) * glowA
    local gb = grabC.z + (0.88 - grabC.z) * glowA
    dl:AddRectFilled(
        imgui.ImVec2(sbX, grabY),
        imgui.ImVec2(sbX + sbW, grabY + grabH),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(gr, gg, gb, hoverAlpha)),
        rounding)

    -- Lógica de drag con mouse
    if imgui.IsMouseClicked(0) and (sbHovered or grabHovered) then
        _sbDrag.active   = true
        _sbDrag.startY   = my
        _sbDrag.startScr = _anim.scrollCurrent
        _S.noScroll      = true
    end

    if _sbDrag.active then
        if imgui.IsMouseDown(0) then
            local dy      = my - _sbDrag.startY
            local scrollPerPx = _S.max_scroll / math.max(1, sbH - grabH)
            _anim.scrollTarget = math.max(0, math.min(_S.max_scroll,
                _sbDrag.startScr + dy * scrollPerPx))
            _S.noScroll = (_anim.scrollTarget < _S.max_scroll)
        else
            _sbDrag.active = false
            if _anim.scrollTarget >= _S.max_scroll then _S.noScroll = false end
        end
    end

    -- Click en el track (fuera del grab) → saltar a esa posición
    if imgui.IsMouseClicked(0) and sbHovered and not grabHovered and not _sbDrag.active then
        local clickRatio = math.max(0, math.min(1, (my - sbY) / sbH))
        _anim.scrollTarget = clickRatio * _S.max_scroll
        _S.noScroll = (_anim.scrollTarget < _S.max_scroll)
        _sbDrag.active   = true
        _sbDrag.startY   = my
        _sbDrag.startScr = _anim.scrollTarget
    end

    -- Reservar espacio invisible para que ImGui no haga layout encima
    imgui.SetCursorPos(imgui.ImVec2(4, 12))
    imgui.Dummy(imgui.ImVec2(sbW, sbH))
end

-- ============================================================
--  SETTINGS TABS
-- ============================================================
local function drawTabApariencia()
    imgui.Spacing()
    local SEL_ALPHA_CAP = { ['color.sel_normal']=0.55, ['color.sel_hovered']=0.70 }
    local function colorRow(label, entry, dbKey)
        imgui.Text(label)
        imgui.SameLine(imgui.GetWindowWidth() - 56)
        if imgui.ColorEdit4('##' .. dbKey, entry.flt,
            imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel +
            imgui.ColorEditFlags.AlphaBar + imgui.ColorEditFlags.AlphaPreview) then
            local cap = SEL_ALPHA_CAP[dbKey]
            if cap then entry.flt[3] = math.min(entry.flt[3], cap) end
            syncVec(entry); cfgSet(dbKey, fltToStr(entry.flt))
        end
        if SEL_ALPHA_CAP[dbKey] then
            if imgui.IsItemActive() or imgui.IsItemHovered() then
                entry.flt[3] = math.min(entry.flt[3], SEL_ALPHA_CAP[dbKey]); syncVec(entry)
                _S.selPreviewActive = true; _S.selPreviewTimeout = os.clock() + 0.3; _S.showChat = true
            end
        end
    end
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Fuente y tamano')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    if #_F.fonts > 0 then
        imgui.Text(u8('Fuente:')); imgui.PushItemWidth(-1)
        if imgui.Combo('##fcmb', _F.fontSelected, _F.fontsArray, #_F.fonts) then
            _F.fontChanged = true; cfgSet('val.font_name', _F.fonts[_F.fontSelected[0]+1] or cfgGet('val.font_name'))
        end
        imgui.PopItemWidth()
    end
    imgui.Spacing()
    if imgui.SliderInt(u8('Tamano de fuente'), _F.fontSize, 8, 36) then
        _F.fontSizeChanged = true; cfgSet('val.font_size', tostring(_F.fontSize[0]))
    end
    imgui.Spacing()
    if imgui.SliderInt(u8('Lineas visibles del chat'), _F.chatLinesInt, 4, 60) then
        _F.chatLines = _F.chatLinesInt[0]; cfgSet('val.line_count', tostring(_F.chatLines))
    end
    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Colores de chat')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    colorRow(u8('Fondo del chat:'),      C.chat,      'color.chat_bg')
    colorRow(u8('Fondo del input:'),     C.input,     'color.input_bg')
    colorRow(u8('Borde de ventana:'),    C.border,    'color.border')
    colorRow(u8('Color del texto:'),     C.text,      'color.text_color')
    colorRow(u8('Timestamps:'),          C.timestamp, 'color.timestamp')
    colorRow(u8('Badge no leidos:'),     C.unread,    'color.unread')
    colorRow(u8('Color de menciones:'),  C.mention,   'color.mention')
    colorRow(u8('Seleccion mensajes:'),  C.selNormal,  'color.sel_normal')
    colorRow(u8('Seleccion hover:'),     C.selHovered, 'color.sel_hovered')
    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Scrollbar')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    colorRow(u8('Fondo scrollbar:'),  C.scrollBG,         'color.scroll_bg')
    colorRow(u8('Cursor scrollbar:'), C.scrollGrab,       'color.scroll_grab')
    colorRow(u8('Cursor activo:'),    C.scrollGrabActive, 'color.scroll_grab_act')
    colorRow(u8('Fondo hover:'),      C.scrollHov,        'color.scroll_hov')
    colorRow(u8('Fondo activo:'),     C.scrollAct,        'color.scroll_act')
    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Botones del menu contextual')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    colorRow(u8('Boton normal:'), C.btn,    'color.btn')
    colorRow(u8('Boton hover:'),  C.btnHov, 'color.btn_hov')
    colorRow(u8('Boton activo:'), C.btnAct, 'color.btn_act')
    imgui.Spacing(); imgui.Spacing()
    if imgui.Button(u8('  Restablecer colores'), imgui.ImVec2(-1, 28)) then
        db_exec('DELETE FROM config WHERE key LIKE "color.%";')
        _dirty = {}; _dirtyCount = 0; loadConfig()
    end
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
    imgui.TextWrapped(u8('Los cambios se aplican y guardan automaticamente.')); imgui.PopStyleColor()
end

local function drawTabFiltros()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.75,0.45,1.00,1.0))
    imgui.Text(u8('  Mensajes bloqueados  (' .. #blockedPatterns .. ')')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40,0.40,0.50,1.0))
    imgui.TextWrapped(u8('Los mensajes que coincidan con estos patrones se ocultan automaticamente.')); imgui.PopStyleColor()
    imgui.Spacing()
    local rowH  = imgui.GetTextLineHeightWithSpacing() + 4
    local listH = math.max(80, math.min(#blockedPatterns, 8) * rowH + 10)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.07,0.07,0.10,1.0))
    imgui.PushStyleColor(imgui.Col.Border,  imgui.ImVec4(0.30,0.15,0.50,0.5))
    imgui.BeginChild('##blocked_list', imgui.ImVec2(-1, listH), true)
    if #blockedPatterns == 0 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35,0.35,0.45,1.0))
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 8); imgui.Text(u8('  (ninguno)')); imgui.PopStyleColor()
    end
    local toRemoveBlocked = nil
    for bi, pat in ipairs(blockedPatterns) do
        imgui.PushIDInt(bi)
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.42,0.08,0.08,0.85))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.70,0.12,0.12,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.85,0.16,0.16,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.65,0.65,1.00))
        if imgui.Button('X##bd', imgui.ImVec2(22, 0)) then toRemoveBlocked = bi end
        imgui.PopStyleColor(4); imgui.SameLine(nil, 8)
        local disp = #pat > 64 and pat:sub(1,61)..'...' or pat
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85,0.75,1.00,1.0))
        imgui.Text(u8(disp)); imgui.PopStyleColor(); imgui.PopID()
    end
    imgui.EndChild(); imgui.PopStyleColor(2)
    if toRemoveBlocked then removeBlockedPattern(toRemoveBlocked); saveBlocked(); purgeBlockedFromHistory() end
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.11,0.08,0.18,1.0))
    imgui.PushItemWidth(imgui.GetContentRegionAvail().x - 106)
    imgui.InputText(u8('##newblocked'), blockedNewBuf, ffi.sizeof(blockedNewBuf) - 1)
    imgui.PopItemWidth(); imgui.PopStyleColor(); imgui.SameLine(nil, 4)
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.22,0.10,0.40,0.92))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.38,0.16,0.62,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.50,0.22,0.78,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.88,0.68,1.00,1.00))
    if imgui.Button(u8('+ Bloquear'), imgui.ImVec2(-1, 0)) then
        if addBlockedPattern(ffi.string(blockedNewBuf)) then saveBlocked(); purgeBlockedFromHistory() end
        imgui.StrCopy(blockedNewBuf, '')
    end
    imgui.PopStyleColor(4); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.25,0.08,0.08,0.88))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.45,0.12,0.12,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.60,0.15,0.15,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.65,0.65,1.00))
    if imgui.Button(u8('  Borrar todos los bloqueados'), imgui.ImVec2(-1, 26)) then
        blockedPatterns = {}; blockedPatternsLow = {}; invalidateBlockCache(); saveBlocked()
    end
    imgui.PopStyleColor(4)
end

local function compareVersions(a, b)
    local function parts(v)
        local x,y,z = v:match('^(%d+)%.(%d+)%.(%d+)$')
        return tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
    end
    local a1,a2,a3 = parts(a); local b1,b2,b3 = parts(b)
    if a1~=b1 then return a1>b1 and 1 or -1 end
    if a2~=b2 then return a2>b2 and 1 or -1 end
    if a3~=b3 then return a3>b3 and 1 or -1 end
    return 0
end

-- ============================================================
--  SISTEMA DE ACTUALIZACIONES AUTOMÁTICAS
-- ============================================================
--
-- Flujo completo:
--   1. Descarga manifest.json del repo
--   2. Compara versión → si hay update disponible:
--      a. En modo silencioso (auto al inicio): muestra toast y descarga en background
--      b. En modo manual: muestra UI detallada con progreso
--   3. Para cada archivo en el manifest:
--      - Si no existe localmente → instalar
--      - Si existe pero tiene diferente tamaño/hash → actualizar
--   4. Para cada librería en manifest.libs:
--      - Detecta ruta de MoonLoader automáticamente
--      - Si la lib no existe → descargar e instalar
--   5. Al terminar: toast "Actualizado. Recarga con F9"
--      Los archivos .lua se reemplazan directamente.
--      Las DLLs se copian con retry (pueden estar bloqueadas).
--
-- Formato del manifest.json:
-- {
--   "version": "1.3.1",
--   "files": [
--     {"path": "Chat.lua",       "url": "Chat.lua",       "required": true},
--     {"path": "lib/sqlite3.dll","url": "lib/sqlite3.dll","required": true}
--   ],
--   "libs": [
--     {
--       "name": "mimgui_blur",
--       "check": "lib/mimgui_blur/mimgui_blur_lib.dll",
--       "files": [
--         {"dest": "lib/mimgui_blur/mimgui_blur_lib.dll", "url": "libs/mimgui_blur/mimgui_blur_lib.dll"},
--         {"dest": "lib/mimgui_blur/init.lua",            "url": "libs/mimgui_blur/init.lua"}
--       ]
--     }
--   ]
-- }

-- Detectar la ruta base de MoonLoader
-- Prioridad: getWorkingDirectory() ya devuelve la carpeta moonloader en MoonLoader
local function getMoonloaderPath()
    return getWorkingDirectory()
end

-- Parsear JSON mínimo para el manifest (sin librerías externas)
local function parseManifest(json)
    if not json or #json < 2 then return nil end
    local manifest = {}

    -- version
    manifest.version = json:match('"version"%s*:%s*"([^"]+)"') or ''

    -- files array
    manifest.files = {}
    local filesBlock = json:match('"files"%s*:%s*%[(.-)%]%s*[,}]')
    if not filesBlock then
        -- intento más amplio con bloques anidados
        filesBlock = json:match('"files"%s*:%s*(%b[])')
        if filesBlock then filesBlock = filesBlock:sub(2, -2) end
    end
    if filesBlock then
        for obj in filesBlock:gmatch('{([^}]+)}') do
            local path     = obj:match('"path"%s*:%s*"([^"]+)"')
            local url      = obj:match('"url"%s*:%s*"([^"]+)"')
            local required = obj:match('"required"%s*:%s*(true)') ~= nil
            if path and url then
                table.insert(manifest.files, { path=path, url=url, required=required })
            end
        end
    end

    -- libs array
    manifest.libs = {}
    local libsSection = json:match('"libs"%s*:%s*(%b[])')
    if libsSection then
        for libObj in libsSection:gmatch('{%s*"name"[^{]*"files"%s*:%s*%b[][^}]*}') do
            local name  = libObj:match('"name"%s*:%s*"([^"]+)"')
            local check = libObj:match('"check"%s*:%s*"([^"]+)"')
            local lib   = { name=name, check=check, files={} }
            local libFiles = libObj:match('"files"%s*:%s*(%b[])')
            if libFiles then
                for fobj in libFiles:gmatch('{([^}]+)}') do
                    local dest = fobj:match('"dest"%s*:%s*"([^"]+)"')
                    local furl = fobj:match('"url"%s*:%s*"([^"]+)"')
                    if dest and furl then
                        table.insert(lib.files, { dest=dest, url=furl })
                    end
                end
            end
            if name then table.insert(manifest.libs, lib) end
        end
    end

    return manifest
end

-- Verificar si un archivo local necesita actualización comparando tamaño
-- (hash MD5 sería ideal pero requiere DLL; tamaño es suficiente para detectar cambios)
local function fileNeedsUpdate(localPath, remoteSize)
    if not doesFileExist(localPath) then return true end
    if not remoteSize or remoteSize == 0 then return false end
    local f = io.open(localPath, 'rb')
    if not f then return true end
    f:seek('end'); local sz = f:seek(); f:close()
    return sz ~= remoteSize
end

-- Crear directorio recursivamente
local function ensureDir(path)
    -- Normalizar separadores
    path = path:gsub('/', '\\')
    local parts = {}
    for p in path:gmatch('[^\\]+') do table.insert(parts, p) end
    local cur = ''
    for _, p in ipairs(parts) do
        cur = cur == '' and p or (cur .. '\\' .. p)
        if not doesDirectoryExist(cur) then
            pcall(createDirectory, cur)
        end
    end
end

-- Descarga con retry (3 intentos)
local function downloadWithRetry(url, destPath, maxRetries)
    maxRetries = maxRetries or 3
    for attempt = 1, maxRetries do
        os.remove(destPath .. '.tmp')
        local ok = false
        if downloadUrlToFile then
            downloadUrlToFile(url, destPath .. '.tmp')
            wait(3000)
            ok = doesFileExist(destPath .. '.tmp')
        end
        if not ok then
            -- Intentar con httpDownloadToFile si está disponible
            ok = pcall(httpDownloadToFile, url, destPath .. '.tmp')
            if ok then ok = doesFileExist(destPath .. '.tmp') end
        end
        if ok then
            -- Verificar que el archivo no está vacío
            local f = io.open(destPath .. '.tmp', 'rb')
            local sz = 0
            if f then f:seek('end'); sz = f:seek(); f:close() end
            if sz > 10 then
                -- Mover al destino (con retry para DLLs que pueden estar en uso)
                for mv = 1, 3 do
                    os.remove(destPath)
                    local moved = os.rename(destPath .. '.tmp', destPath)
                    if moved or doesFileExist(destPath) then
                        os.remove(destPath .. '.tmp')
                        return true, sz
                    end
                    wait(500)
                end
                -- Si rename falla (DLL en uso), intentar copia manual
                local src = io.open(destPath .. '.tmp', 'rb')
                local dst = io.open(destPath, 'wb')
                if src and dst then
                    dst:write(src:read('*a')); src:close(); dst:close()
                    os.remove(destPath .. '.tmp')
                    return true, sz
                end
                if src then src:close() end
                if dst then dst:close() end
            end
        end
        if attempt < maxRetries then
            updLog('  Reintento ' .. attempt .. '/' .. maxRetries .. '...', 'warn')
            wait(1500)
        end
    end
    os.remove(destPath .. '.tmp')
    return false, 0
end

-- Función principal del updater — corre en lua_thread
local function runUpdater(options)
    options = options or {}
    local silent   = options.silent   or false
    local forceAll = options.forceAll or false  -- actualizar todos aunque sean iguales

    _upd.status    = 'checking'
    _upd.log       = {}
    _upd.progress  = 0
    _upd.doneFiles = 0
    _upd.totalFiles= 0
    _upd.failedFiles = {}
    _upd.needsReload = false
    _upd.silentMode  = silent

    local mlPath = getMoonloaderPath()
    updLog('MoonLoader: ' .. mlPath, 'info')
    updLog('Descargando manifest...', 'info')

    -- 1. Descargar manifest
    local manifestPath = mlPath .. '\\config\\chat_manifest.json'
    os.remove(manifestPath)
    local mOk = false
    if downloadUrlToFile then
        downloadUrlToFile(MANIFEST_URL, manifestPath)
        wait(4000)
        mOk = doesFileExist(manifestPath)
    end

    if not mOk then
        -- Fallback: intentar con httpGet
        local content, err = pcall(httpGet, MANIFEST_URL)
        if content and type(content) == 'string' and #content > 10 then
            local f = io.open(manifestPath, 'w')
            if f then f:write(content); f:close(); mOk = true end
        end
    end

    if not mOk then
        _upd.status = 'error'
        updLog('No se pudo descargar el manifest.', 'error')
        if not silent then
            addToast(u8('Error: no se pudo contactar el servidor'), imgui.ImVec4(1,0.3,0.3,1), 5)
        end
        return
    end

    -- 2. Parsear manifest
    local f = io.open(manifestPath, 'r')
    if not f then
        _upd.status = 'error'; updLog('No se pudo leer el manifest.', 'error'); return
    end
    local manifestContent = f:read('*a'); f:close()
    local manifest = parseManifest(manifestContent)
    if not manifest or manifest.version == '' then
        _upd.status = 'error'; updLog('Manifest invalido o vacio.', 'error'); return
    end
    _upd.manifest   = manifest
    _upd.remoteVer  = manifest.version
    updLog('Manifest OK — version remota: v' .. manifest.version, 'ok')

    -- 3. Comparar versiones
    local cmp = compareVersions(manifest.version, CURRENT_VERSION)
    if cmp <= 0 and not forceAll then
        _upd.status = 'idle'
        updLog('Ya tienes la version mas reciente (v' .. CURRENT_VERSION .. ').', 'ok')
        if not silent then
            addToast(u8('Ya tienes la version mas reciente'), imgui.ImVec4(0.4,0.85,0.5,1), 3)
        end
        return
    end

    _upd.status = 'downloading'
    updLog('Nueva version disponible: v' .. manifest.version .. ' (instalada: v' .. CURRENT_VERSION .. ')', 'warn')

    if silent then
        addToast(u8('Actualizando a v' .. manifest.version .. '...'), imgui.ImVec4(0.6,0.7,1,1), 4)
    end

    -- Contar archivos totales (script + libs)
    local totalFiles = #manifest.files
    for _, lib in ipairs(manifest.libs) do
        totalFiles = totalFiles + #lib.files
    end
    _upd.totalFiles = totalFiles

    -- 4. Descargar e instalar archivos del proyecto
    updLog('--- Archivos del proyecto (' .. #manifest.files .. ') ---', 'info')
    for _, fileEntry in ipairs(manifest.files) do
        local localPath = mlPath .. '\\' .. fileEntry.path:gsub('/', '\\')
        local remoteUrl = RAW_BASE_URL .. fileEntry.url
        local dirPath   = localPath:match('^(.+)\\[^\\]+$')
        if dirPath then ensureDir(dirPath) end

        _upd.progressMsg = fileEntry.path
        updLog('  ' .. fileEntry.path .. '...', 'normal')

        local ok, sz = downloadWithRetry(remoteUrl, localPath)
        _upd.doneFiles = _upd.doneFiles + 1
        _upd.progress  = _upd.doneFiles / math.max(1, _upd.totalFiles)

        if ok then
            updLog('  ✓ ' .. fileEntry.path .. ' (' .. math.floor(sz/1024) .. ' KB)', 'ok')
            -- Si es un .lua → necesita reload
            if fileEntry.path:match('%.lua$') then
                _upd.needsReload = true
            end
        else
            updLog('  ✗ Error descargando: ' .. fileEntry.path, 'error')
            if fileEntry.required then
                table.insert(_upd.failedFiles, fileEntry.path)
            end
        end
        wait(100)
    end

    -- 5. Instalar librerías nuevas o faltantes
    if #manifest.libs > 0 then
        updLog('--- Librerias (' .. #manifest.libs .. ') ---', 'info')
        for _, lib in ipairs(manifest.libs) do
            local checkPath = lib.check and (mlPath .. '\\' .. lib.check:gsub('/', '\\')) or nil
            local alreadyInstalled = checkPath and doesFileExist(checkPath)

            if alreadyInstalled and not forceAll then
                updLog('  [' .. lib.name .. '] ya instalada, omitiendo.', 'info')
                _upd.doneFiles  = _upd.doneFiles + #lib.files
                _upd.progress   = _upd.doneFiles / math.max(1, _upd.totalFiles)
            else
                if not alreadyInstalled then
                    updLog('  [' .. lib.name .. '] NUEVA — instalando...', 'warn')
                else
                    updLog('  [' .. lib.name .. '] actualizando...', 'info')
                end
                local libOk = true
                for _, lf in ipairs(lib.files) do
                    local destPath = mlPath .. '\\' .. lf.dest:gsub('/', '\\')
                    local srcUrl   = RAW_BASE_URL .. lf.url
                    local dDir     = destPath:match('^(.+)\\[^\\]+$')
                    if dDir then ensureDir(dDir) end

                    _upd.progressMsg = lib.name .. '/' .. lf.dest:match('[^/\\]+$')
                    local ok2, sz2 = downloadWithRetry(srcUrl, destPath)
                    _upd.doneFiles = _upd.doneFiles + 1
                    _upd.progress  = _upd.doneFiles / math.max(1, _upd.totalFiles)

                    if ok2 then
                        updLog('    ✓ ' .. lf.dest:match('[^/\\]+$'), 'ok')
                    else
                        updLog('    ✗ Error: ' .. lf.dest, 'error')
                        libOk = false
                    end
                    wait(80)
                end
                if libOk then
                    updLog('  [' .. lib.name .. '] instalada correctamente.', 'ok')
                    addToast(u8('Libreria instalada: ' .. lib.name), imgui.ImVec4(0.5,0.9,0.6,1), 4)
                else
                    updLog('  [' .. lib.name .. '] instalacion parcial.', 'warn')
                end
            end
        end
    end

    -- 6. Resultado final
    _upd.progress = 1.0
    local nFailed = #_upd.failedFiles
    if nFailed == 0 then
        _upd.status = 'done'
        updLog('', 'normal')
        updLog('Actualizacion completada: v' .. CURRENT_VERSION .. ' → v' .. manifest.version, 'ok')
        if _upd.needsReload then
            updLog('Recarga el script con F9 o /reload para aplicar cambios.', 'warn')
            addToast(u8('Actualizado a v' .. manifest.version .. ' — recarga con F9'), imgui.ImVec4(0.5,1,0.6,1), 6)
        else
            updLog('No se requiere recarga (solo librerias actualizadas).', 'info')
            addToast(u8('Actualizado a v' .. manifest.version), imgui.ImVec4(0.5,1,0.6,1), 4)
        end
    else
        _upd.status = 'error'
        updLog('', 'normal')
        updLog('Actualizacion incompleta — ' .. nFailed .. ' archivo(s) fallaron:', 'error')
        for _, fp in ipairs(_upd.failedFiles) do
            updLog('  • ' .. fp, 'error')
        end
        addToast(u8('Actualizacion incompleta (' .. nFailed .. ' errores)'), imgui.ImVec4(1,0.4,0.3,1), 6)
    end
end

-- Lanzar verificación automática al inicio (silenciosa)
local function autoCheckUpdate()
    if _upd.autoChecked then return end
    _upd.autoChecked = true
    lua_thread.create(function()
        wait(2000)  -- esperar a que SAMP esté listo
        runUpdater({ silent = true })
    end)
end

-- Verificación manual desde la UI
local function checkUpdateManual()
    if _upd.status == 'checking' or _upd.status == 'downloading' then return end
    lua_thread.create(function()
        runUpdater({ silent = false })
    end)
end

-- Re-instalar todo (forzado)
local function forceReinstall()
    if _upd.status == 'checking' or _upd.status == 'downloading' then return end
    lua_thread.create(function()
        runUpdater({ silent = false, forceAll = true })
    end)
end

local function drawTabOpciones()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Comportamiento')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    local mentBool = imgui.new.bool(mentionHighlight)
    if imgui.Checkbox(u8('Resaltar menciones de mi nick'), mentBool) then
        mentionHighlight = mentBool[0]; cfgSet('val.mention_highlight', mentionHighlight and '1' or '0'); invalidateMentionCache()
    end
    imgui.Spacing()
    imgui.Text(u8('Limite de mensajes en memoria:')); imgui.SameLine(nil, 8)
    local maxBuf = imgui.new.char[8](tostring(MAX_MESSAGES))
    imgui.PushItemWidth(80)
    imgui.InputText('##maxmsg', maxBuf, 7, imgui.InputTextFlags.CharsDecimal)
    if imgui.IsItemDeactivatedAfterEdit() then
        local v = tonumber(ffi.string(maxBuf))
        if v and v >= 50 and v <= 5000 then MAX_MESSAGES = v; cfgSet('val.max_msgs', tostring(v)) end
    end
    imgui.PopItemWidth(); imgui.SameLine(nil, 8)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4,0.4,0.5,1))
    imgui.Text(u8('(50 - 5000)')); imgui.PopStyleColor()

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Estadisticas')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    local function statRow(label, val)
        imgui.Text(label); imgui.SameLine(nil, 6)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6,0.7,1.0,1.0))
        imgui.Text(tostring(val)); imgui.PopStyleColor()
    end
    statRow(u8('Mensajes en historial:'), #messages)
    statRow(u8('Enviados guardados:'),    #sendHistory)
    statRow(u8('Sin leer:'),              _S.unreadCount)
    statRow(u8('Tu nick detectado:'),     myNick ~= '' and myNick or u8('(no conectado)'))
    statRow(u8('Comandos recientes:'),    #_CMD.recentCmds)
    statRow(u8('Emojis cargados:'),       #_discordEmojis)

    imgui.Spacing(); imgui.Spacing()
    if imgui.Button(u8('  Limpiar chat'), imgui.ImVec2(-1, 28)) then
        messages = {}; _S.unreadCount = 0; _anim.scrollCurrent = 0; _anim.scrollTarget = 0; _S.noScroll = false
    end
    imgui.Spacing()
    if imgui.Button(u8('  Limpiar historial enviados'), imgui.ImVec2(-1, 28)) then
        sendHistory = {}; _S.lastHistoryIdx = 0; _CMD.recentCmds = {}; _CMD.recentCmdsSet = {}
    end
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10,0.22,0.15,0.92))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.15,0.38,0.22,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.20,0.50,0.28,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.70,1.00,0.78,1.00))
    if imgui.Button(u8('  Exportar chat a .txt'), imgui.ImVec2(-1, 28)) then exportChatToFile() end
    imgui.PopStyleColor(4)

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Comandos y atajos')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65,0.65,0.75,1.0))
    imgui.TextWrapped(u8(
        '/timestamp  |  /chconfig  |  /clearchat\n\n'..
        'T / F       abrir chat       F5   ocultar/mostrar\n'..
        'Ctrl+F      buscar           ESC  cerrar input\n'..
        'PgUp/PgDn   scroll rapido    Rueda  desplazar\n'..
        'Flechas     historial de enviados\n'..
        'TAB         autocompletar comando o emoji\n'..
        'Click der.  menu de mensaje\n'..
        '[emoji]     abrir selector de emojis Discord'
    )); imgui.PopStyleColor()

    imgui.Spacing(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Actualizaciones automaticas')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()

    -- Versiones
    local busy = (_upd.status == 'checking' or _upd.status == 'downloading')
    imgui.Text(u8('Instalada:')); imgui.SameLine(nil, 6)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.80,0.55,1.0))
    imgui.Text('v' .. CURRENT_VERSION); imgui.PopStyleColor()
    if _upd.remoteVer ~= '' then
        imgui.SameLine(nil, 16)
        imgui.Text(u8('En repo:')); imgui.SameLine(nil, 6)
        local isNewer = compareVersions(_upd.remoteVer, CURRENT_VERSION) > 0
        imgui.PushStyleColor(imgui.Col.Text,
            isNewer and imgui.ImVec4(1.0,0.82,0.20,1.0) or imgui.ImVec4(0.55,0.80,0.55,1.0))
        imgui.Text('v' .. _upd.remoteVer); imgui.PopStyleColor()
    end
    imgui.Spacing()

    -- Barra de progreso
    if busy then
        imgui.PushStyleColor(imgui.Col.PlotHistogram, imgui.ImVec4(0.35,0.65,1.0,1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg,       imgui.ImVec4(0.10,0.12,0.20,1.0))
        imgui.ProgressBar(_upd.status == 'checking' and (-1 * os.clock()) or _upd.progress,
            imgui.ImVec2(-1, 16),
            _upd.status == 'checking' and '' or
            string.format('%d/%d  %s', _upd.doneFiles, _upd.totalFiles, _upd.progressMsg))
        imgui.PopStyleColor(2); imgui.Spacing()
    end

    -- Botones de control
    if not busy then
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.14,0.22,0.45,0.95))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22,0.34,0.65,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.28,0.42,0.78,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.75,0.88,1.00,1.00))
        if imgui.Button(u8('  Buscar y aplicar actualizaciones'), imgui.ImVec2(-1, 28)) then
            checkUpdateManual()
        end
        imgui.PopStyleColor(4); imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.22,0.10,0.10,0.85))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.38,0.14,0.14,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.52,0.18,0.18,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.70,0.70,1.00))
        if imgui.Button(u8('  Reinstalar todo (forzado)'), imgui.ImVec2(-1, 24)) then
            forceReinstall()
        end
        imgui.PopStyleColor(4)
    else
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.20,0.20,0.20,0.55))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.50,0.50,0.50,1.00))
        imgui.Button(u8('  Actualizando...'), imgui.ImVec2(-1, 28)); imgui.PopStyleColor(2)
    end
    imgui.Spacing()

    -- Log de progreso
    if #_upd.log > 0 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
        imgui.Text(u8('  Log de actualizacion')); imgui.PopStyleColor()
        imgui.Separator(); imgui.Spacing()

        local logH = math.min(#_upd.log, 10) * (imgui.GetTextLineHeightWithSpacing()) + 8
        logH = math.max(logH, 60)
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.05,0.05,0.08,1.0))
        imgui.PushStyleColor(imgui.Col.Border,  imgui.ImVec4(0.25,0.12,0.42,0.5))
        imgui.BeginChild('##updlog', imgui.ImVec2(-1, logH), true)

        local colorMap = {
            normal = imgui.ImVec4(0.72,0.72,0.80,1.0),
            ok     = imgui.ImVec4(0.35,0.90,0.45,1.0),
            warn   = imgui.ImVec4(1.00,0.82,0.20,1.0),
            error  = imgui.ImVec4(0.90,0.30,0.30,1.0),
            info   = imgui.ImVec4(0.45,0.65,0.90,1.0),
        }
        for _, entry in ipairs(_upd.log) do
            local c = colorMap[entry.color] or colorMap.normal
            imgui.PushStyleColor(imgui.Col.Text, c)
            imgui.TextUnformatted(u8(entry.msg))
            imgui.PopStyleColor()
        end

        -- Auto-scroll al final del log
        if _upd.logScroll then
            imgui.SetScrollHereY(1.0)
            _upd.logScroll = false
        end
        imgui.EndChild(); imgui.PopStyleColor(2); imgui.Spacing()

        -- Botón limpiar log
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.08,0.08,0.12,0.80))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.14,0.14,0.20,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.40,0.40,0.52,1.00))
        if imgui.Button(u8('Limpiar log'), imgui.ImVec2(100, 20)) then
            _upd.log = {}
        end
        imgui.PopStyleColor(3)
    end

    -- Info sobre qué hace el sistema
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35,0.35,0.48,1.0))
    imgui.TextWrapped(u8(
        'Al iniciar, el sistema verifica automaticamente si hay actualizaciones.\n'..
        'Descarga Chat.lua, librerias nuevas y archivos de soporte desde GitHub.\n'..
        'Las librerias faltantes se instalan automaticamente en moonloader\\lib\\'
    ))
    imgui.PopStyleColor()
end

local function drawTabDiscord()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.55, 0.90, 1.0))
    imgui.Text(u8('  Emojis de Discord')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.45, 0.60, 1.0))
    imgui.TextWrapped(u8(
        'Conecta tu servidor de Discord para usar sus emojis custom.\n'..
        'Los emojis se envian como :nombre: — jugadores sin el mod\n'..
        'los ven exactamente como Discord sin Nitro (:nombre:).'
    )); imgui.PopStyleColor()
    imgui.Spacing(); imgui.Separator(); imgui.Spacing()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.70, 0.70, 0.80, 1.0))
    imgui.Text(u8('Bot Token:')); imgui.PopStyleColor()
    local tokenBuf = imgui.new.char[128](DISCORD_TOKEN)
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.10, 0.10, 0.16, 1.0))
    imgui.PushItemWidth(-1)
    imgui.InputText('##discord_token', tokenBuf, 127, imgui.InputTextFlags.Password)
    if imgui.IsItemDeactivatedAfterEdit() then
        DISCORD_TOKEN = ffi.string(tokenBuf):match('^%s*(.-)%s*$')
        cfgSet('discord.token', DISCORD_TOKEN); addToast(u8('Token guardado'))
    end
    imgui.PopItemWidth(); imgui.PopStyleColor(); imgui.Spacing()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.70, 0.70, 0.80, 1.0))
    imgui.Text(u8('Guild ID:')); imgui.PopStyleColor()
    local guildBuf = imgui.new.char[32](DISCORD_GUILD_ID)
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.10, 0.10, 0.16, 1.0))
    imgui.PushItemWidth(220)
    imgui.InputText('##discord_guild', guildBuf, 31, imgui.InputTextFlags.CharsDecimal)
    if imgui.IsItemDeactivatedAfterEdit() then
        DISCORD_GUILD_ID = ffi.string(guildBuf); cfgSet('discord.guild_id', DISCORD_GUILD_ID)
        addToast(u8('Guild ID guardado'))
    end
    imgui.PopItemWidth(); imgui.PopStyleColor(); imgui.Spacing(); imgui.Spacing()
    imgui.Separator(); imgui.Spacing()

    local stateColor = imgui.ImVec4(0.5, 0.5, 0.6, 1.0); local stateText = u8('Sin configurar')
    if _emojiLoadState == 'ready' then
        stateColor = imgui.ImVec4(0.3, 0.85, 0.4, 1.0); stateText = u8(#_discordEmojis .. ' emojis cargados')
    elseif _emojiLoadState == 'fetching' then
        stateColor = imgui.ImVec4(0.8, 0.75, 0.2, 1.0); stateText = u8(_emojiLoadMsg)
    elseif _emojiLoadState == 'downloading' then
        stateColor = imgui.ImVec4(0.4, 0.75, 1.0, 1.0); stateText = u8(_emojiLoadMsg)
    elseif _emojiLoadState == 'error' then
        stateColor = imgui.ImVec4(0.85, 0.25, 0.25, 1.0); stateText = u8(_emojiLoadMsg)
    end
    imgui.Text(u8('Estado:')); imgui.SameLine(nil, 6)
    imgui.PushStyleColor(imgui.Col.Text, stateColor); imgui.Text(stateText); imgui.PopStyleColor()

    if _emojiLoadState == 'downloading' or _emojiLoadState == 'fetching' then
        local total = #_discordEmojis; local ratio = 0.0
        if total > 0 then
            local done = _emojiLoadMsg:match('(%d+)%s*/%s*%d+') or '0'; ratio = tonumber(done) / total
        end
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.PlotHistogram,
            _emojiLoadState == 'fetching' and imgui.ImVec4(0.7,0.65,0.15,1.0) or imgui.ImVec4(0.25,0.60,0.95,1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.12,0.12,0.18,1.0))
        imgui.ProgressBar(_emojiLoadState=='fetching' and -1*os.clock() or ratio, imgui.ImVec2(-1, 14), '')
        imgui.PopStyleColor(2); imgui.Spacing()
    end

    imgui.Spacing()
    local canFetch = DISCORD_TOKEN ~= '' and DISCORD_GUILD_ID ~= ''
    local isBusy   = _emojiLoadState == 'fetching' or _emojiLoadState == 'downloading'

    if isBusy then
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.20,0.20,0.20,0.60))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20,0.20,0.20,0.60))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.20,0.20,0.20,0.60))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.55,0.55,0.55,1.00))
        imgui.Button(u8('  Descargando...'), imgui.ImVec2(-1, 32)); imgui.PopStyleColor(4)
    elseif canFetch then
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.25,0.55,0.95))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.38,0.75,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.35,0.48,0.88,1.00))
        imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.85,0.92,1.00,1.00))
        if imgui.Button(u8('  Descargar emojis automaticamente  '), imgui.ImVec2(-1, 32)) then fetchDiscordEmojis() end
        imgui.PopStyleColor(4)
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6,0.4,0.4,1.0))
        imgui.TextWrapped(u8('Completa el Token y Guild ID para continuar.')); imgui.PopStyleColor()
    end

    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.12,0.20,0.42,0.92))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20,0.35,0.65,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.25,0.42,0.78,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.75,0.88,1.00,1.00))
    if imgui.Button(u8('  Cargar desde JSON manual  '), imgui.ImVec2(-1, 28)) then
        loadEmojisFromJson(_emojiCacheDir .. 'emojis.json')
    end
    imgui.PopStyleColor(4); imgui.Spacing()

    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10,0.22,0.14,0.92))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.15,0.38,0.22,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.20,0.50,0.28,1.00))
    imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.70,1.00,0.78,1.00))
    if imgui.Button(u8('  Recargar desde cache local  '), imgui.ImVec2(-1, 28)) then
        _discordEmojis = {}
        if not loadEmojisFromCache() then
            _emojiLoadState = 'error'; _emojiLoadMsg = u8('No hay cache.')
        end
    end
    imgui.PopStyleColor(4); imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.38,0.38,0.50,1.0))
    imgui.TextWrapped(u8('Cache en: moonloader\\config\\emoji_cache\\')); imgui.PopStyleColor()
end

local function drawTabTeclas()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.70,1.0))
    imgui.Text(u8('  Hotkeys personalizadas')); imgui.PopStyleColor()
    imgui.Separator(); imgui.Spacing()
    imgui.TextWrapped(u8('Asigna un boton del teclado para abrir y cerrar esta ventana de configuracion.'))
    imgui.Spacing(); imgui.Spacing()
    imgui.Text(u8('Tecla actual:')); imgui.SameLine(nil, 8)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6,0.9,0.6,1.0))
    imgui.Text(hotkeyLastName); imgui.PopStyleColor(); imgui.Spacing()
    if hotkeyCapture then
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.55,0.20,0.20,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.70,0.28,0.28,1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.80,0.32,0.32,1.00))
        imgui.Button(u8('  [ Presiona una tecla... ]'), imgui.ImVec2(-1, 32)); imgui.PopStyleColor(3)
    else
        imgui.PushStyleColor(imgui.Col.Button,        C.btn.vec)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, C.btnHov.vec)
        imgui.PushStyleColor(imgui.Col.ButtonActive,  C.btnAct.vec)
        if imgui.Button(u8('  Asignar tecla...'), imgui.ImVec2(-1, 32)) then hotkeyCapture = true end
        imgui.PopStyleColor(3)
    end
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.25,0.10,0.10,0.90))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.40,0.14,0.14,1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.55,0.18,0.18,1.00))
    if imgui.Button(u8('  Quitar hotkey'), imgui.ImVec2(-1, 28)) then
        hotkeyCapture = false; hotkeyVK = 0; hotkeyLastName = 'Ninguna'; cfgSet('hotkey.settings', '0')
    end
    imgui.PopStyleColor(3)
end

-- ============================================================
--  VENTANA PRINCIPAL
-- ============================================================
local chatWindow = imgui.OnFrame(
    function()
        return not isPauseMenuActive()
            and sampIsChatVisible()
            and not sampIsScoreboardOpen()
            and _S.showChat
    end,
    function(self)
        updateAnimDt()
        flushDirty()

        -- Aplicar emoji pendiente (respaldo para garantizar que InputText recibe el valor)
        if _S.pendingEmojiInsert then
            imgui.StrCopy(inputChat, _S.pendingEmojiInsert)
            _S.pendingEmojiInsert    = nil
            _S.needsFocus            = true
            _CMD.lastSuggestionInput = nil
        end

        -- Liberar drag de scrollbar si el mouse no está presionado
        if _sbDrag.active and not imgui.IsMouseDown(0) then
            _sbDrag.active = false
            if _anim.scrollTarget >= _S.max_scroll then _S.noScroll = false end
        end

        local needsMouse = _S.openChat or (_F.showSettings and _F.showSettings[0]) or _S.showEmojiPicker
        imgui.DisableMouseInput = not needsMouse
        if not needsMouse then imgui.CaptureMouseFromApp(false) end

        if _F.fontChanged or _F.fontSizeChanged then
            _F.fontChanged = false; _F.fontSizeChanged = false
            local io2 = imgui.GetIO(); io2.Fonts:Clear()
            buildAndLoadFont(io2,
                getFolderPath(0x14) .. '\\' .. (_F.fonts[_F.fontSelected[0]+1] or cfgGet('val.font_name')),
                _F.fontSize[0])
            imgui.InvalidateFontsTexture(); invalidateRenderCache()
        end
    end,
    function(self)
        _S.contextMenuOpen = false
        if os.clock() > _S.selPreviewTimeout then _S.selPreviewActive = false end

        -- ── Animaciones de scroll suave con inercia ──────────────────
        -- NOTA: scrollTarget se resuelve DESPUÉS de leer max_scroll del EndChild
        -- para evitar race condition cuando llegan mensajes nuevos.
        -- Aquí solo hacemos el lerp hacia el target actual.

        local scrollDiff = _anim.scrollTarget - _anim.scrollCurrent
        if math.abs(scrollDiff) > 0.3 then
            -- Velocidad adaptativa: más rápido cuando la distancia es grande
            local speed = math.abs(scrollDiff) > 300 and 14
                       or math.abs(scrollDiff) > 100 and 10
                       or 7
            _anim.scrollCurrent = lerpSmooth(_anim.scrollCurrent, _anim.scrollTarget, speed, _anim.dt)
        else
            _anim.scrollCurrent = _anim.scrollTarget
        end
        -- Clampear al rango válido conocido del frame anterior
        _anim.scrollCurrent = math.max(0, math.min(_anim.scrollCurrent, math.max(_S.max_scroll, _anim.scrollTarget)))
        _S.setup_current_scroll = _anim.scrollCurrent

        -- ── Cursor y captura ────────────────────────────────────────
        if _S.openChat or _S.showEmojiPicker then
            if not sampIsCursorActive() then sampToggleCursor(true) end
            imgui.CaptureMouseFromApp(true)
        else
            imgui.CaptureMouseFromApp(false)
        end

        local lineH  = imgui.GetTextLineHeightWithSpacing()
        local chatH  = lineH * _F.chatLines + 52
        local extraH = (_S.searchActive and _S.openChat) and (lineH + 12) or 0

        -- ── Animación de apertura/cierre del chat (fade + slide) ─────
        local targetAlpha = _S.openChat and (C.chat.flt[3]) or 0.0
        _S.openColor = lerpSmooth(_S.openColor, targetAlpha, _S.openChat and 10 or 8, _anim.dt)

        -- ── Animación de badge (pulso) ──────────────────────────────
        if not _S.openChat and _S.unreadCount > 0 then
            _anim.badgePulse = pulse(3.0)
        end

        imgui.SetNextWindowPos(imgui.ImVec2(2, 10))
        imgui.SetNextWindowSize(imgui.ImVec2(1022, chatH + extraH))
        imgui.PushStyleColor(imgui.Col.WindowBg, C.chat.vec)
        imgui.PushStyleColor(imgui.Col.Border,   C.border.vec)
        imgui.PushStyleColor(imgui.Col.Text,      C.text.vec)
        imgui.SetNextWindowBgAlpha(_S.openColor)

        local flags = imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoSavedSettings
                    + imgui.WindowFlags.NoNav
        if not _S.openChat then
            flags = flags + imgui.WindowFlags.NoMouseInputs
        end
        imgui.Begin('##ChatMain', nil, flags)

        -- ── Blur glassmorphism bajo el panel del chat ──────────────
        -- Solo cuando hay contenido visible (openColor > 0) y la lib está cargada
        if _blurOk and _S.openColor > 0.02 then
            local winP  = imgui.GetWindowPos()
            local winSz = imgui.GetWindowSize()
            local blurR = math.min(3.5, _S.openColor * 4)  -- radio proporcional al fade
            -- Color tintado semitransparente (oscurece ligeramente la escena)
            local tintA = math.floor(_S.openColor * 0.18 * 255) * 0x01000000
            pcall(_blur.applyRect,
                imgui.GetWindowDrawList(),
                imgui.ImVec2(winP.x, winP.y),
                imgui.ImVec2(winP.x + winSz.x, winP.y + winSz.y),
                blurR,
                tintA,
                12,  -- rounding
                0)   -- all corners
        end

        if _S.openChat
            and imgui.IsMouseClicked(0)
            and not imgui.IsWindowHovered(imgui.HoveredFlags.AnyWindow)
            and not imgui.IsPopupOpen('##ctx_msg')
            and not imgui.IsPopupOpen('##edit_msg') then
            if not _S.showEmojiPicker then closeChat() end
        end

        -- ── Scrollbar animada ─────────────────────────────────────
        if _S.openChat then
            drawAnimatedScrollbar(chatH, lineH)
        end

        -- ── Area de mensajes ──────────────────────────────────────
        imgui.SetCursorPos(imgui.ImVec2(24, 12))
        imgui.BeginChild('##msgs', imgui.ImVec2(0, lineH * _F.chatLines + 4), false,
            imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
            + (not _S.openChat and imgui.WindowFlags.NoBackground or 0))

        local showAll   = not (_S.searchActive and ffi.string(searchBuf) ~= '')
        local searchSet = {}
        if not showAll then
            for _, idx in ipairs(searchResults) do searchSet[idx] = true end
        end

        for i = 1, #messages do
            local m = messages[i]
            if m and (showAll or searchSet[i]) and msgPassesFilter(m) then
                if m._tsStatus ~= _S.timestampStatus then
                    m._tsStatus = _S.timestampStatus; prepareMsgPrefixedText(m)
                end
                renderColorText(m, i)
            end
        end

        _S.current_scroll = imgui.GetScrollY()
        _S.max_scroll     = imgui.GetScrollMaxY()
        imgui.SetScrollY(_S.setup_current_scroll)
        imgui.EndChild()

        -- ── Resolver scroll al final AQUÍ, cuando max_scroll ya está actualizado ──
        -- scrollToBottom: set por pushMsg o por apertura del chat
        if _anim.scrollToBottom and _S.max_scroll > 0 then
            _anim.scrollTarget   = _S.max_scroll
            -- Si la distancia es muy grande (carga inicial), hacer snap directo
            if _S.max_scroll - _anim.scrollCurrent > 500 then
                _anim.scrollCurrent = _S.max_scroll
            end
            _anim.scrollToBottom = false
        end
        -- Auto-follow: si no estamos en modo manual, mantenerse al final
        if not _S.noScroll and _S.max_scroll > 0 then
            _anim.scrollTarget = _S.max_scroll
        end
        -- Clampear scrollCurrent al rango ahora que max_scroll está actualizado
        _anim.scrollCurrent = math.max(0, math.min(_anim.scrollCurrent, _S.max_scroll))
        _S.setup_current_scroll = _anim.scrollCurrent

        if _S.pendingContextMenu then _S.pendingContextMenu = false; imgui.OpenPopup('##ctx_msg') end
        if _S.pendingEditModal  then _S.pendingEditModal = false;   imgui.OpenPopup('##edit_msg') end

        -- ── Input del chat ──────────────────────────────────────────
        if _S.openChat then
            if _S.searchActive then
                imgui.SetCursorPosX(24)
                imgui.PushStyleColor(imgui.Col.FrameBg, C.input.vec)
                imgui.PushItemWidth(380)
                local changed = imgui.InputText(u8('##search '), searchBuf, ffi.sizeof(searchBuf)-1,
                    imgui.InputTextFlags.EnterReturnsTrue)
                if changed or imgui.IsItemEdited() then refreshSearch() end
                imgui.PopItemWidth(); imgui.PopStyleColor()
                imgui.SameLine(nil, 6)
                imgui.TextColored(C.timestamp.vec, string.format('%d hallado(s)', #searchResults))
                imgui.SameLine(nil, 6)
                imgui.PushStyleColor(imgui.Col.Button,        C.btn.vec)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, C.btnHov.vec)
                imgui.PushStyleColor(imgui.Col.ButtonActive,  C.btnAct.vec)
                if imgui.Button(u8('X##cerrar_busq')) then
                    _S.searchActive = false; imgui.StrCopy(searchBuf, ''); searchResults = {}
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

            -- Animar glow del input cuando está activo
            local inputTargetGlow = _S.chatInputActive and 1.0 or 0.0
            _anim.inputGlow = lerpSmooth(_anim.inputGlow, inputTargetGlow, 10, _anim.dt)

            -- Border glow del input animado
            local glowA  = _anim.inputGlow
            local inputBorder = imgui.ImVec4(0.45 * glowA, 0.18 * glowA, 0.75 * glowA, glowA * 0.9)

            imgui.PushStyleColor(imgui.Col.FrameBg,        C.input.vec)
            imgui.PushStyleColor(imgui.Col.Text,            C.text.vec)
            imgui.PushStyleColor(imgui.Col.Border,          inputBorder)
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)

            -- Border size animado para el glow
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, glowA * 1.5)

            if _S.needsFocus then imgui.SetKeyboardFocusHere(0); _S.needsFocus = false end

            local inputW = imgui.GetContentRegionAvail().x - 120
            imgui.PushItemWidth(inputW)
            local inputChanged = imgui.InputText('##chatinput', inputChat, INPUT_BUF - 1,
                imgui.InputTextFlags.CallbackCompletion + imgui.InputTextFlags.CallbackHistory,
                TextEditCallbackC)
            if inputChanged then
                if sampSetChatInputText then
                    pcall(sampSetChatInputText, u8:decode(ffi.string(inputChat)))
                end
            end

            -- Guardar posición del input para overlays
            local inputRectMin = imgui.GetItemRectMin()
            local inputRectMax = imgui.GetItemRectMax()
            local inputH_px    = inputRectMax.y - inputRectMin.y

            local curInput = ffi.string(inputChat)

            updateSuggestions(curInput)
            updateEmojiSuggestions(curInput)

            local anyPopupOpen = imgui.IsPopupOpen('##ctx_msg') or imgui.IsPopupOpen('##edit_msg')
            if not anyPopupOpen then _S.chatInputActive = imgui.IsItemActive() end

            imgui.PopItemWidth()
            imgui.PopStyleVar(2)  -- FrameRounding + FrameBorderSize
            imgui.PopStyleColor(3)  -- FrameBg + Text + Border

            -- Overlay de emojis en el input
            if _emojiLoadState == 'ready' and #_discordEmojis > 0 then
                local tokens = parseInputEmojiTokens(curInput)
                if #tokens > 0 then
                    renderInputEmojiOverlay(inputRectMin.x, inputRectMin.y, inputH_px, tokens, curInput)
                end
            end

            -- Botón idioma
            imgui.SameLine(nil, 4)
            imgui.PushStyleColor(imgui.Col.Button,        C.input.vec)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, C.scrollHov.vec)
            imgui.PushStyleColor(imgui.Col.ButtonActive,  C.scrollAct.vec)
            imgui.PushStyleColor(imgui.Col.Text,          C.timestamp.vec)
            imgui.Button(langStr, imgui.ImVec2(28, 0)); imgui.PopStyleColor(4)

            -- Botón Emoji con glow animado
            imgui.SameLine(nil, 4)
            local emojiBtnGlow = _S.showEmojiPicker and 1.0 or (_anim.emojiPickerAlpha * 0.8)
            imgui.PushStyleColor(imgui.Col.Button,
                imgui.ImVec4(0.15 + emojiBtnGlow * 0.2, 0.12 + emojiBtnGlow * 0.03, 0.22 + emojiBtnGlow * 0.38, 0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.40,0.18,0.68,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.55,0.22,0.82,1.00))

            -- Intentar cargar textura del botón emoji
            if _S.emojiPickerBtnTex == nil then
                local iconNames = {'blush', 'smile', 'grinning', 'slightly_smiling_face', 'smiley', 'happy'}
                for _, n in ipairs(iconNames) do
                    local e = findEmojiByName(n)
                    if e then
                        loadEmojiTexture(e)
                        if e.tex then _S.emojiPickerBtnTex = e.tex; break end
                    end
                end
                if _S.emojiPickerBtnTex == nil then
                    _S.emojiPickerBtnTex = false
                end
            end

            local btnH = imgui.GetFrameHeight()
            if _S.emojiPickerBtnTex then
                local texID = ffi.cast('ImTextureID', _S.emojiPickerBtnTex)
                if imgui.ImageButton(texID, imgui.ImVec2(btnH - 6, btnH - 6),
                    imgui.ImVec2(0,0), imgui.ImVec2(1,1), 3,
                    imgui.ImVec4(0,0,0,0), imgui.ImVec4(1,1,1,1)) then
                    _S.showEmojiPicker = not _S.showEmojiPicker
                end
            else
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.80,0.70,1.00,1.00))
                if imgui.Button(u8(':)##epbtn'), imgui.ImVec2(28, 0)) then
                    _S.showEmojiPicker = not _S.showEmojiPicker
                end
                imgui.PopStyleColor()
            end

            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.75,0.70,0.90,1.0))
                imgui.Text(u8('Selector de emojis  (o escribe :nombre:)')); imgui.PopStyleColor()
                imgui.EndTooltip()
            end
            local ep = imgui.GetItemRectMin()
            _S.emojiAnchorX = ep.x; _S.emojiAnchorY = ep.y
            imgui.PopStyleColor(3)

            -- Contador de caracteres
            local charCount = #curInput
            local over      = charCount > SAMP_INPUT_LIMIT
            imgui.SameLine(nil, 6)
            if over then
                imgui.TextColored(imgui.ImVec4(1,0.25,0.25,1), string.format('%d/%d', charCount, SAMP_INPUT_LIMIT))
            else
                local ratio = charCount / SAMP_INPUT_LIMIT
                local barR  = math.min(ratio*2, 1.0); local barG = math.min((1-ratio)*2, 1.0)
                imgui.TextColored(imgui.ImVec4(barR,barG,0.3,0.9), string.format('%d/%d', charCount, SAMP_INPUT_LIMIT))
            end

            -- ── Popup sugerencias de COMANDOS ──────────────────────
            if #_CMD.suggestions > 0 and _S.chatInputActive and not _emojiSuggest.active then
                local fs2  = imgui.GetFontSize()
                local rowH = fs2 + 10
                local padV = 10
                local sugH = padV + (#_CMD.suggestions * rowH) + 6 + (fs2 + 10) + padV
                local posX = 26
                local posY = 10 + chatH + extraH - sugH - 38
                local dl   = imgui.GetForegroundDrawList()
                local ww   = 320

                dl:AddRectFilled(imgui.ImVec2(posX+4,posY+4), imgui.ImVec2(posX+ww+4,posY+sugH+4),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0,0,0,0.50)), 12)
                dl:AddRectFilled(imgui.ImVec2(posX,posY), imgui.ImVec2(posX+ww,posY+sugH),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.04,0.04,0.08,0.99)), 10)
                dl:AddRect(imgui.ImVec2(posX,posY), imgui.ImVec2(posX+ww,posY+sugH),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.45,0.22,0.75,0.85)), 10, nil, 1.2)
                dl:AddText(imgui.ImVec2(posX+12, posY+5),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.42,0.28,0.65,1.0)), 'Comandos')

                local cy = posY + padV + fs2 - 2
                for si, sug in ipairs(_CMD.suggestions) do
                    local isSelected = (si == _CMD.suggestIdx)
                    local ry = cy-2; local rh = rowH+2
                    if isSelected then
                        dl:AddRectFilled(imgui.ImVec2(posX+6,ry), imgui.ImVec2(posX+ww-6,ry+rh),
                            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.25,0.09,0.48,0.98)), 7)
                        dl:AddRectFilled(imgui.ImVec2(posX+6,ry), imgui.ImVec2(posX+10,ry+rh),
                            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.72,0.38,1.00,1.00)), 7)
                        dl:AddText(imgui.ImVec2(posX+18,cy+1),
                            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.00,0.95,1.00,1.00)), sug)
                    else
                        dl:AddText(imgui.ImVec2(posX+22,cy+1),
                            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.62,0.62,0.80,1.00)), sug)
                    end
                    cy = cy + rowH
                end
                dl:AddText(imgui.ImVec2(posX+12,cy+8),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.32,0.28,0.44,1.00)),
                    u8('TAB completar  ESC cerrar'))
            end

            -- ── Popup sugerencias de EMOJIS ────────────────────────
            if _S.chatInputActive then
                drawEmojiAutocomplete(26, 10, chatH, extraH)
            end
        end

        -- ── Badge no leidos animado ──────────────────────────────
        if not _S.openChat and _S.unreadCount > 0 then
            imgui.SetCursorPos(imgui.ImVec2(24, lineH * _F.chatLines + 20))
            local uc = C.unread.vec
            local pulseV = 0.85 + _anim.badgePulse * 0.15
            imgui.TextColored(
                imgui.ImVec4(uc.x, uc.y, uc.z, pulseV),
                string.format('+ %d nuevo(s)', _S.unreadCount))

            -- Indicador de glow detrás del badge
            if _anim.badgePulse > 0.5 then
                local bpos = imgui.GetItemRectMin()
                local bmax = imgui.GetItemRectMax()
                local dl3  = imgui.GetWindowDrawList()
                dl3:AddRectFilled(
                    imgui.ImVec2(bpos.x - 2, bpos.y - 1),
                    imgui.ImVec2(bmax.x + 2, bmax.y + 1),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(uc.x, uc.y, uc.z,
                        (_anim.badgePulse - 0.5) * 0.25)), 4)
            end
        end

        -- ── Toasts con slide-in animado ──────────────────────────
        local now = os.clock(); local dl3 = imgui.GetWindowDrawList()
        local sx, sy = getScreenResolution(); local toastY = sy - 60; local i = 1
        while i <= #_toasts do
            local t = _toasts[i]
            if now > t.timer then
                table.remove(_toasts, i)
            else
                local remaining = t.timer - now
                local alpha = math.min(remaining, 0.5) * 2
                t.slideX = lerpSmooth(t.slideX or 300, 0, 15, _anim.dt)
                local toastW = 280
                local toastX = sx - toastW - 20 + (t.slideX or 0)
                dl3:AddRectFilled(
                    imgui.ImVec2(toastX, toastY-26),
                    imgui.ImVec2(toastX+toastW, toastY),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.08,0.08,0.12, 0.92*alpha)), 8)
                -- Línea de color a la izquierda
                dl3:AddRectFilled(
                    imgui.ImVec2(toastX, toastY-26),
                    imgui.ImVec2(toastX+3, toastY),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(t.color.x, t.color.y, t.color.z, alpha)), 8)
                imgui.SetCursorScreenPos(imgui.ImVec2(toastX+10, toastY-20))
                imgui.TextColored(imgui.ImVec4(t.color.x,t.color.y,t.color.z,alpha), u8(t.text))
                toastY = toastY - 34; i = i + 1
            end
        end

        -- Menu contextual
        _S.contextMenuOpen = _S.contextMenuOpen or imgui.IsPopupOpen('##ctx_msg')
        imgui.PushStyleColor(imgui.Col.PopupBg,   imgui.ImVec4(0.10,0.10,0.13,0.97))
        imgui.PushStyleColor(imgui.Col.Separator, imgui.ImVec4(1,1,1,0.06))
        if imgui.BeginPopup('##ctx_msg') then
            if not _S.openChat then
                imgui.CloseCurrentPopup(); imgui.EndPopup()
                imgui.PopStyleColor(2); imgui.End(); imgui.PopStyleColor(3); return
            end
            local m   = _S.contextMenuId and messages[_S.contextMenuId] or nil
            local mid = _S.contextMenuId or 0
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.55,0.65,1.0))
            imgui.Text(string.format('  #%d  %s', mid, m and m.timestamp or '')); imgui.PopStyleColor()
            imgui.Spacing()
            local BTN_W, BTN_H = 172, 26
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.18,0.24,0.75))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.28,0.40,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.35,0.35,0.55,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.92,0.92,0.96,1.00))
            if imgui.Button(u8('  Copiar texto'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then setClipboardText(stripTags(m.text)) end; imgui.CloseCurrentPopup()
            end
            if imgui.Button(u8('  Copiar al input'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then imgui.StrCopy(inputChat, m.text) end; imgui.CloseCurrentPopup()
            end
            imgui.Spacing(); imgui.Separator(); imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.10,0.32,0.85))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.35,0.15,0.55,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.50,0.20,0.70,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.85,0.65,1.00,1.00))
            if imgui.Button(u8('  Filtrar mensaje'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then
                    local plain = stripTags(m.text):match('^%s*(.-)%s*$')
                    if addBlockedPattern(plain) then saveBlocked() end; purgeBlockedFromHistory()
                end
                imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(4); imgui.Spacing(); imgui.Separator(); imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.18,0.24,0.75))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.28,0.40,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.35,0.35,0.55,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.92,0.92,0.96,1.00))
            if imgui.Button(u8('  Editar'), imgui.ImVec2(BTN_W, BTN_H)) then
                editId = mid
                if m then
                    imgui.StrCopy(editColor, m.color:match('{(.+)}') or '')
                    imgui.StrCopy(editLine,  m.text)
                    imgui.StrCopy(editTime,  m.timestamp:match('%[(.+)%]') or '')
                end
                _S.pendingEditModal = true; imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(4)
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.38,0.10,0.10,0.80))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.58,0.14,0.14,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.70,0.18,0.18,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(1.00,0.70,0.70,1.00))
            if imgui.Button(u8('  Eliminar'), imgui.ImVec2(BTN_W, BTN_H)) then
                if m then
                    table.remove(messages, mid)
                    _anim.scrollTarget = math.max(0, _anim.scrollTarget - imgui.GetTextLineHeightWithSpacing())
                end
                imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(4); imgui.EndPopup()
        end
        imgui.PopStyleColor(2)

        -- Modal edición
        imgui.SetNextWindowSize(imgui.ImVec2(500, 0), imgui.Cond.Always)
        imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(0.10,0.10,0.13,0.98))
        if imgui.BeginPopupModal('##edit_msg', nil,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize) then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55,0.55,0.68,1.0))
            imgui.Text(u8('  Editar mensaje  #'..editId)); imgui.PopStyleColor(); imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.Separator, imgui.ImVec4(1,1,1,0.07))
            imgui.Separator(); imgui.PopStyleColor(); imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.16,0.16,0.22,1.0))
            imgui.Text(u8('Texto:')); imgui.PushItemWidth(-1)
            imgui.InputText('##et', editLine, ffi.sizeof(editLine)-1); imgui.PopItemWidth(); imgui.Spacing()
            imgui.Columns(2, nil, false)
            imgui.Text(u8('Color (RRGGBB):')); imgui.PushItemWidth(-1)
            imgui.InputText('##ec', editColor, ffi.sizeof(editColor)-1); imgui.PopItemWidth()
            imgui.NextColumn()
            imgui.Text(u8('Hora (HH:MM:SS):')); imgui.PushItemWidth(-1)
            imgui.InputText('##eh', editTime, ffi.sizeof(editTime)-1); imgui.PopItemWidth()
            imgui.Columns(1); imgui.PopStyleColor(); imgui.Spacing(); imgui.Spacing()
            local half = (imgui.GetContentRegionAvail().x - 6) * 0.5
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.20,0.38,0.22,0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.54,0.30,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.34,0.64,0.36,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.85,1.00,0.85,1.00))
            if imgui.Button(u8('  Aplicar'), imgui.ImVec2(half, 30)) then
                local edited = {
                    text      = ffi.string(editLine),
                    color     = '{' .. ffi.string(editColor) .. '}',
                    timestamp = '[' .. ffi.string(editTime) .. ']',
                    msgType   = messages[editId] and messages[editId].msgType or 1,
                }
                edited._segVer = _renderCacheVer-1; edited._blockVer = _blockCacheVer-1
                edited._mentionVer = _mentionCacheVer-1; messages[editId] = edited
                imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(4); imgui.SameLine(nil, 6)
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.18,0.18,0.24,0.80))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.28,0.28,0.40,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.35,0.35,0.55,1.00))
            imgui.PushStyleColor(imgui.Col.Text,          imgui.ImVec4(0.75,0.75,0.82,1.00))
            if imgui.Button(u8('  Cancelar'), imgui.ImVec2(half, 30)) then imgui.CloseCurrentPopup() end
            imgui.PopStyleColor(4); imgui.EndPopup()
        end
        imgui.PopStyleColor()

        imgui.End(); imgui.PopStyleColor(3)

        -- Emoji picker: ventana independiente, fuera del Begin/End del chat
        drawEmojiPicker(_S.emojiAnchorX, _S.emojiAnchorY)
    end
)
chatWindow.HideCursor = true

-- ============================================================
--  VENTANA DE CONFIGURACION
-- ============================================================
local settingsWindow = imgui.OnFrame(
    function() return _F.showSettings and _F.showSettings[0] end,
    function(self)
        imgui.DisableMouseInput = false
        self.HideCursor = false
        if not sampIsCursorActive() then sampToggleCursor(true) end
    end,
    function(self)
        -- Detectar cierre via botón X de ImGui (showSettings pasa a false dentro del End())
        local wasOpen = _F.showSettings and _F.showSettings[0]
        local sx, sy = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(sx/2, sy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5,0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(640, 600), imgui.Cond.FirstUseEver)
        imgui.PushStyleColor(imgui.Col.WindowBg,       imgui.ImVec4(0.08,0.08,0.11,0.98))
        imgui.PushStyleColor(imgui.Col.TitleBg,        imgui.ImVec4(0.08,0.08,0.11,1.00))
        imgui.PushStyleColor(imgui.Col.TitleBgActive,  imgui.ImVec4(0.12,0.10,0.18,1.00))
        imgui.PushStyleColor(imgui.Col.Tab,            imgui.ImVec4(0.12,0.12,0.17,1.00))
        imgui.PushStyleColor(imgui.Col.TabHovered,     imgui.ImVec4(0.22,0.20,0.35,1.00))
        imgui.PushStyleColor(imgui.Col.TabActive,      imgui.ImVec4(0.20,0.18,0.32,1.00))
        imgui.PushStyleColor(imgui.Col.Button,         C.btn.vec)
        imgui.PushStyleColor(imgui.Col.ButtonHovered,  C.btnHov.vec)
        imgui.PushStyleColor(imgui.Col.ButtonActive,   C.btnAct.vec)
        imgui.PushStyleColor(imgui.Col.Border,         imgui.ImVec4(1,1,1,0.06))
        imgui.PushStyleColor(imgui.Col.Text,           C.text.vec)
        imgui.PushStyleColor(imgui.Col.FrameBg,        imgui.ImVec4(0.14,0.14,0.20,1.00))
        imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.18,0.18,0.28,1.00))
        local selN = imgui.ImVec4(C.selNormal.vec.x,  C.selNormal.vec.y,  C.selNormal.vec.z,  math.min(C.selNormal.vec.w,0.55))
        local selH = imgui.ImVec4(C.selHovered.vec.x, C.selHovered.vec.y, C.selHovered.vec.z, math.min(C.selHovered.vec.w,0.70))
        imgui.PushStyleColor(imgui.Col.Header,         selN)
        imgui.PushStyleColor(imgui.Col.HeaderHovered,  selH)
        imgui.PushStyleColor(imgui.Col.TextSelectedBg, selN)
        imgui.Begin(u8('Chat MImGui  |  Configuracion'), _F.showSettings)

        -- Blur glassmorphism bajo la ventana de settings
        if _blurOk then
            local wp  = imgui.GetWindowPos()
            local wsz = imgui.GetWindowSize()
            pcall(_blur.applyRect,
                imgui.GetWindowDrawList(),
                imgui.ImVec2(wp.x, wp.y),
                imgui.ImVec2(wp.x + wsz.x, wp.y + wsz.y),
                4.0, 0, 12, 0)
        end
        if imgui.BeginTabBar('##tabs') then
            if imgui.BeginTabItem(u8(' Apariencia ')) then drawTabApariencia(); imgui.EndTabItem() end
            if imgui.BeginTabItem(u8(' Filtros '))    then drawTabFiltros();    imgui.EndTabItem() end
            if imgui.BeginTabItem(u8(' Opciones '))   then drawTabOpciones();   imgui.EndTabItem() end
            if imgui.BeginTabItem(u8(' Teclas '))     then drawTabTeclas();     imgui.EndTabItem() end
            if imgui.BeginTabItem(u8(' Discord '))    then drawTabDiscord();    imgui.EndTabItem() end
            imgui.EndTabBar()
        end
        imgui.End(); imgui.PopStyleColor(16)

        -- Si la ventana se cerró con el botón X de ImGui en este frame → restaurar control
        if wasOpen and _F.showSettings and not _F.showSettings[0] and not _S.openChat then
            imgui.DisableMouseInput = true
            sampToggleCursor(false)
        end
    end
)

-- ============================================================
--  HOOKS DE SAMP
-- ============================================================
local _hooks = { chat=nil, input=nil, inputEnable=nil, inputDisable=nil }

local function onSampChat(this, msgType, text, prefix, color, pcolor)
    local clr     = string.format('%06X', bit.band(color, 0xFFFFFF))
    local rawText = ffi.string(text)
    local decoded = smartDecode(rawText)
    local txt     = decoded

    if msgType == 2 then
        local pclr          = string.format('%06X', bit.band(pcolor, 0xFFFFFF))
        local decodedPrefix = smartDecode(ffi.string(prefix))
        txt = '{'..pclr..'}'..decodedPrefix..': {'..clr..'}'..decoded
    end

    local entry = {
        text      = txt,
        color     = '{'..clr..'}',
        timestamp = os.date('[%H:%M:%S]'),
        msgType   = msgType,
        _tsStatus = _S.timestampStatus,
    }
    prepareMsgPrefixedText(entry)

    if mentionHighlight and _myNickLower ~= '' then
        local plain = stripTags(txt):lower()
        if plain:find(_myNickLower, 1, true) then
            addToast(u8('Mencion: ') .. stripTags(decoded):sub(1, 40),
                     imgui.ImVec4(C.mention.vec.x, C.mention.vec.y, C.mention.vec.z, 1.0), 4.0)
        end
    end

    pushMsg(entry)
    _hooks.chat(this, msgType, text, prefix, color, pcolor)
end

local function onSampInput(this, text, carret)
    if not _S.openChat then
        imgui.StrCopy(inputChat, u8(ffi.string(text)))
    end
    _hooks.input(this, text, carret)
end

local function onSampInputEnable(this)
    if isSampfuncsConsoleActive and isSampfuncsConsoleActive() then return end
    _S.openChat = true; ButterflyWidgetChatOpen = true
    _S.unreadCount = 0; _S.lastHistoryIdx = 0; _S.chatInputActive = false
    imgui.DisableMouseInput = false
    imgui.StrCopy(inputChat, '')
    if sampGetChatInputText then
        local sampText = sampGetChatInputText() or ''
        if sampText ~= '' then imgui.StrCopy(inputChat, u8(sampText)) end
    end
    _S.needsFocus = true
    if pInput then pInput.iInputEnabled = 1 end
    -- Ir al final al abrir el chat
    _anim.scrollToBottom = true
end

local function onSampInputDisable(this)
    if _S.openChat and sampIsCursorActive() then return end
    _S.openChat = false; _S.chatInputActive = false
    imgui.CaptureMouseFromApp(false); ButterflyWidgetChatOpen = false
    if pInput then pInput.iInputEnabled = 0 end
    _S.noScroll = false
    _anim.scrollbarGlow = 0
    if not (_F.showSettings and _F.showSettings[0]) then
        imgui.DisableMouseInput = true; sampToggleCursor(false)
    end
end

-- ============================================================
--  MAIN
-- ============================================================
function main()
    _hooks.input = hook.new(
        'void(__thiscall *)(void* this, const char* text, bool carret)',
        onSampInput, getModuleHandle('samp.dll') + 0x80F60, 5, false, '8B 44 24 04 56')
    _hooks.inputEnable = hook.new(
        'void(__thiscall *)(void* this)',
        onSampInputEnable, getModuleHandle('samp.dll') + 0x657E0, 5, false, '83 EC 10 56 8B')
    _hooks.inputDisable = hook.new(
        'void(__thiscall *)(void* this)',
        onSampInputDisable, getModuleHandle('samp.dll') + 0x658E0, 5, false, '56 8B F1 8B 86')

    DB_PATH       = getWorkingDirectory() .. '\\config\\Chat_MImGui.db'
    local confdir = getWorkingDirectory() .. '\\config\\'
    if not doesDirectoryExist(confdir) then createDirectory(confdir) end
    _emojiCacheDir = confdir .. 'emoji_cache\\'
    if not doesDirectoryExist(_emojiCacheDir) then createDirectory(_emojiCacheDir) end
    assert(db_open(DB_PATH), '[ChatMImGui] No se pudo abrir la DB SQLite.')
    db_prepare_stmts(); loadRecentCmds()
    loadEmojisFromCache()

    wait(100); autoCheckUpdate()

    while not isSampAvailable() do wait(50) end

    lua_thread.create(function()
        wait(1000)
        if sampGetLocalPlayerNickname then setMyNick(sampGetLocalPlayerNickname() or '') end
    end)

    pInput = ffi.cast('struct stInputInfo*', sampGetInputInfoPtr())[0]

    -- Cargar historial de SAMP
    local chatEntry = ffi.cast('chatInfoMin*', sampGetChatInfoPtr() + 306).chatEntry
    for i = 0, 99 do
        local ce = chatEntry[i]
        if ce.clTextColor ~= 0 and ffi.string(ce.szText) ~= '' then
            local clr = string.format('%06X', bit.band(ce.clTextColor, 0xFFFFFF))
            local txt = smartDecode(ffi.string(ce.szText))
            if ce.iType == 2 then
                local pclr = string.format('%06X', bit.band(ce.clPrefixColor, 0xFFFFFF))
                txt = '{'..pclr..'}'..smartDecode(ffi.string(ce.szPrefix))..' {'..clr..'}'..txt
            end
            local entry = {
                text=txt, color='{'..clr..'}',
                timestamp=os.date('[%H:%M:%S]', ce.SystemTime),
                msgType=ce.iType, _tsStatus=_S.timestampStatus,
            }
            prepareMsgPrefixedText(entry); table.insert(messages, entry); learnCmdsFromText(txt)
        end
    end

    _hooks.chat = hook.new(
        'void(__thiscall *)(void *this, uint32_t type, const char* text, const char* prefix, uint32_t color, uint32_t pcolor)',
        onSampChat, getModuleHandle('samp.dll') + 0x64010, 5, false, '55 56 8B E9 57')

    memory.setuint8(sampGetBase() + 0x71480, 0xEB, true)
    imgui.DisableMouseInput = true

    -- Al cargar el historial inicial, ir directamente al final sin animación
    _anim.scrollToBottom = true
    _anim.scrollCurrent  = 0  -- empezar desde 0, la flag lo llevará al final

    addEventHandler('onScriptTerminate', function(scr)
        if scr == script.this then
            for _, h in ipairs(hook.hooks) do if h.status then h.stop() end end
            if _dirtyCount > 0 then
                db_exec('BEGIN;'); for k, v in pairs(_dirty) do db_set(k, v) end; db_exec('COMMIT;')
            end
            if _CMD.recentCmdsDirty then pcall(saveRecentCmds) end
            _sq.sqlite3_finalize(stmt_set[0]); _sq.sqlite3_finalize(stmt_get[0])
            _sq.sqlite3_close(db[0])
        end
    end)

    -- Thread de nick
    lua_thread.create(function()
        while true do
            wait(5000)
            if sampGetLocalPlayerNickname and isSampAvailable() then
                local nick = sampGetLocalPlayerNickname()
                if nick and nick ~= '' then setMyNick(nick) end
            end
        end
    end)

    while true do wait(1000) end
end

-- ============================================================
--  MENSAJES DE VENTANA
-- ============================================================
addEventHandler('onWindowMessage', function(msg, wparam, lparam)

    -- Click derecho en mensaje
    if msg == 0x0204 and _S.openChat then
        local mx, my = getCursorPos()
        local lineH  = imgui.GetTextLineHeightWithSpacing()
        -- La ventana del chat está en y=10, el child de mensajes tiene offset y=12
        -- El cursor del mouse relativo al inicio del child:
        local chatAreaY = 10 + 12  -- posición Y en pantalla del inicio del área de mensajes
        local relY = my - chatAreaY + _anim.scrollCurrent

        -- Calcular índice correcto iterando solo sobre mensajes visibles
        -- (igual que el loop de render, respetando filtros y búsqueda)
        local showAll   = not (_S.searchActive and ffi.string(searchBuf) ~= '')
        local searchSet = {}
        if not showAll then
            for _, sidx in ipairs(searchResults) do searchSet[sidx] = true end
        end

        local visualRow = 0
        local foundIdx  = nil
        for i = 1, #messages do
            local m = messages[i]
            if m and (showAll or searchSet[i]) and msgPassesFilter(m) then
                local rowY0 = visualRow * lineH
                local rowY1 = rowY0 + lineH
                if relY >= rowY0 and relY < rowY1 then
                    foundIdx = i
                    break
                end
                visualRow = visualRow + 1
            end
        end

        if foundIdx then
            _S.contextMenuId = foundIdx; _S.pendingContextMenu = true
        end
        consumeWindowMessage(true, true, true); return
    end

    -- Click izquierdo en mensaje para ripple
    if msg == 0x0201 and _S.openChat then
        local mx, my = getCursorPos()
        local lineH  = imgui.GetTextLineHeightWithSpacing()
        local chatAreaY = 10 + 12
        local relY = my - chatAreaY + _anim.scrollCurrent

        local showAll   = not (_S.searchActive and ffi.string(searchBuf) ~= '')
        local searchSet = {}
        if not showAll then
            for _, sidx in ipairs(searchResults) do searchSet[sidx] = true end
        end

        local visualRow = 0
        for i = 1, #messages do
            local m = messages[i]
            if m and (showAll or searchSet[i]) and msgPassesFilter(m) then
                local rowY0 = visualRow * lineH
                local rowY1 = rowY0 + lineH
                if relY >= rowY0 and relY < rowY1 then
                    _S.lastClickedMsgId = i
                    _S.lastClickTime    = os.clock()
                    break
                end
                visualRow = visualRow + 1
            end
        end
    end

    if msg == 0x0008 then
        if _S.openChat then closeChat() end
        _S.showEmojiPicker = false; imgui.CaptureMouseFromApp(false); return
    end

    if msg == 0x0100 then
        if hotkeyCapture then
            if wparam ~= 0x10 and wparam ~= 0x11 and wparam ~= 0x12
               and wparam ~= 0xA0 and wparam ~= 0xA1
               and wparam ~= 0xA2 and wparam ~= 0xA3 then
                hotkeyCapture = false; hotkeyVK = wparam; hotkeyLastName = vkName(wparam)
                cfgSet('hotkey.settings', tostring(wparam)); consumeWindowMessage(true, true, true); return
            end
        end

        if wparam == 0x1B then   -- ESC
            if _emojiSuggest.active then
                _emojiSuggest.active = false; _emojiSuggest.list = {}
                consumeWindowMessage(true, false)
            elseif _S.showEmojiPicker then
                _S.showEmojiPicker = false; consumeWindowMessage(true, false)
            elseif _S.openChat then
                if #_CMD.suggestions > 0 then
                    _CMD.suggestions = {}; _CMD.suggestIdx = -1; _CMD.lastSuggestionInput = nil
                    consumeWindowMessage(true, false)
                else
                    closeChat(); consumeWindowMessage(true, false)
                end
            end

        elseif wparam == 0x74 then   -- F5
            _S.showChat = not _S.showChat

        elseif hotkeyVK ~= 0 and wparam == hotkeyVK and not _S.openChat then
            if _F.showSettings then
                local wasOpen = _F.showSettings[0]
                _F.showSettings[0] = not _F.showSettings[0]
                -- Al CERRAR: restaurar estado de cursor/mouse para el juego
                if wasOpen and not _F.showSettings[0] then
                    imgui.DisableMouseInput = true
                    sampToggleCursor(false)
                end
            end
            consumeWindowMessage(true, false)

        elseif wparam == 0x46 and _S.openChat and imgui.GetIO().KeyCtrl then  -- Ctrl+F
            _S.searchActive = not _S.searchActive
            if not _S.searchActive then imgui.StrCopy(searchBuf, ''); searchResults = {} end
            consumeWindowMessage(true, false)

        elseif wparam == 0x21 then   -- PgUp
            _S.noScroll = true
            _anim.scrollTarget = math.max(0, _anim.scrollTarget - 200)

        elseif wparam == 0x22 then   -- PgDn
            _S.noScroll = true
            _anim.scrollTarget = _anim.scrollTarget + 200
            if _anim.scrollTarget >= _S.max_scroll then
                _anim.scrollTarget = _S.max_scroll
                _S.noScroll = false
            end
        end

    elseif msg == 0x0101 then
        if _S.openChat then
            if wparam == 0x0D then   -- Enter
                local text = u8:decode(ffi.string(inputChat))

                if text == '/timestamp' then
                    _S.timestampStatus = not _S.timestampStatus
                    cfgSet('val.timestamp', _S.timestampStatus and '1' or '0')
                    for _, m in ipairs(messages) do m._tsStatus = nil end
                    addToast(u8('Timestamps: ') .. (_S.timestampStatus and 'ON' or 'OFF'))
                    _S.lastHistoryIdx = 0; imgui.StrCopy(inputChat, '')
                    closeChat(); consumeWindowMessage(true, false); return true

                elseif text == '/clearchat' then
                    messages = {}; _S.unreadCount = 0
                    _anim.scrollCurrent = 0; _anim.scrollTarget = 0; _S.noScroll = false
                    addToast(u8('Chat limpiado')); _S.lastHistoryIdx = 0; imgui.StrCopy(inputChat, '')
                    closeChat(); consumeWindowMessage(true, false); return true

                elseif text == '/chconfig' then
                    _F.showSettings[0] = not _F.showSettings[0]
                    _S.lastHistoryIdx = 0; imgui.StrCopy(inputChat, '')
                    closeChat(); consumeWindowMessage(true, false); return true

                elseif text ~= '' then
                    sampProcessChatInput(text)
                    if sendHistory[#sendHistory] ~= text then table.insert(sendHistory, text) end
                    if text:sub(1,1) == '/' then
                        local cmd = text:match('^(%S+)'); if cmd then registerCmd(cmd) end
                    end
                end

                _S.lastHistoryIdx = 0; imgui.StrCopy(inputChat, '')
                _CMD.suggestions = {}; _CMD.suggestIdx = -1; _CMD.lastSuggestionInput = nil
                _emojiSuggest.active = false; _emojiSuggest.list = {}
                _S.showEmojiPicker = false; _S.pendingEmojiInsert = nil
                closeChat(); consumeWindowMessage(true, false)

            elseif wparam == 0x75 then   -- F6
                closeChat(); consumeWindowMessage(true, false)
            end
        end

    elseif msg == 0x020A and _S.openChat then  -- WM_MOUSEWHEEL
        -- Si el picker de emojis está visible, consumir el evento para
        -- que la rueda no mueva el scroll del chat (el picker tiene su propio scroll)
        if _S.showEmojiPicker then
            consumeWindowMessage(true, true, true); return
        end
        local _, delta = splitsigned(ffi.cast('int32_t', wparam))
        local step = 50
        if delta > 0 then
            -- Scroll arriba
            _anim.scrollTarget = math.max(0, _anim.scrollTarget - step)
            _S.noScroll = (_anim.scrollTarget < _S.max_scroll)
        elseif delta < 0 then
            -- Scroll abajo
            _anim.scrollTarget = _anim.scrollTarget + step
            if _anim.scrollTarget >= _S.max_scroll then
                _anim.scrollTarget = _S.max_scroll
                _S.noScroll = false
            else
                _S.noScroll = true
            end
        end
    end
end)