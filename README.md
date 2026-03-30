<div align="center">

# Chat MImGui

### Reemplazo completo del chat nativo de SA-MP con interfaz moderna

[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=flat-square\&logo=lua\&logoColor=white)](https://www.lua.org/)
[![MoonLoader](https://img.shields.io/badge/MoonLoader-0.26+-00599C?style=flat-square)](https://www.blast.hk/moonloader/)
[![ImGui](https://img.shields.io/badge/ImGui-DirectX9-red?style=flat-square)](https://github.com/ocornut/imgui)
[![SQLite](https://img.shields.io/badge/SQLite3-Database-003B57?style=flat-square\&logo=sqlite\&logoColor=white)](https://www.sqlite.org/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

<br>

<p align="center">
  <img src="https://i.postimg.cc/rphDhwhZ/087B97F4-C6E3-4883-889E-9EFAD9343DEF.png" alt="Chat MImGui Preview" width="720"><br>
  <sub><b>Vista del chat en juego</b></sub>
</p>

<br>

<p align="center">
  <img src="https://i.postimg.cc/v8nWm52M/8CAAE144-49AA-4A43-897E-F7A790974752.png" alt="Chat MImGui Menu Preview" width="720"><br>
  <sub><b>Menú de configuración del sistema</b></sub>
</p>

<br>

<i>Sistema de chat reimaginado para SA-MP con renderizado DirectX9 y persistencia local</i>

</div>

---

## Indice

- [Descripcion](#descripcion)
- [Caracteristicas](#caracteristicas)
- [Requisitos](#requisitos)
- [Instalacion](#instalacion)
- [Uso](#uso)
- [Configuracion](#configuracion)
- [Sistema de Filtros](#sistema-de-filtros)
- [Sistema de Actualizaciones](#sistema-de-actualizaciones)
- [Comandos](#comandos)
- [Atajos de Teclado](#atajos-de-teclado)
- [Arquitectura](#arquitectura)
- [Creditos](#creditos)

---

## Descripcion

**Chat MImGui** es un script para MoonLoader que reemplaza completamente el sistema de chat nativo de SA-MP. Utiliza la biblioteca MImGui (wrapper de Dear ImGui para MoonLoader) junto con renderizado DirectX9 para proporcionar una experiencia de chat moderna, fluida y altamente personalizable.

El sistema intercepta los mensajes del chat original mediante hooks de bajo nivel en `samp.dll`, los procesa y renderiza utilizando ImGui, manteniendo toda la funcionalidad original mientras agrega nuevas capacidades como bloqueo de patrones, busqueda en tiempo real y personalizacion completa de la interfaz.

---

## Caracteristicas

### Interfaz
- Renderizado mediante **Dear ImGui** con backend DirectX9
- Animaciones suaves de fade-in/fade-out al abrir/cerrar el chat
- Scroll suave con interpolacion adaptativa segun la distancia
- Soporte completo para **colores SAMP** (codigos `{RRGGBB}` y `{RRGGBBAA}` en texto)
- Efecto de **sombra de texto** opcional (modo display 2 de SAMP)
- Timestamps opcionales en cada mensaje (`[HH:MM:SS]`)
- Indicador de mensajes no leidos con badge contador
- Menu contextual por mensaje (clic derecho)

### Sistema de Filtros
Basado en **bloqueo de patrones de texto plano**:
- Cada patron es una cadena de texto que se busca en el contenido del mensaje
- La comparacion **no distingue mayusculas/minusculas**
- La coincidencia es **parcial**: si el patron aparece en cualquier parte del mensaje, este se oculta
- Los patrones se aplican sobre el texto sin codigos de color (`{RRGGBB}`)
- Los mensajes bloqueados se ocultan **en tiempo real** del chat
- Al agregar un patron, los mensajes ya existentes en el historial que coincidan se **eliminan automaticamente**
- Los patrones se **persisten en SQLite** y se restauran al reiniciar
- Se pueden agregar patrones manualmente desde el panel de configuracion o haciendo **clic derecho** sobre cualquier mensaje y seleccionando `Filtrar mensaje`

### Personalizacion
- Selector de **fuentes del sistema** (TTF)
- Tamano de fuente ajustable (8–36 px)
- Lineas visibles configurables (4–60)
- **16 colores personalizables** con selector RGBA:
  - Fondo del chat y del input
  - Bordes de ventana
  - Color de texto y timestamps
  - Badge de no leidos
  - Colores de seleccion y hover por mensaje
  - Scrollbar (fondo, cursor, estados hover/activo)
  - Botones del menu contextual (normal, hover, activo)
- Boton de **restablecer colores** a valores por defecto

### Almacenamiento
- Base de datos **SQLite3** local (`moonloader/config/Chat_MImGui.db`)
- Sistema de **debounce** para escritura optimizada (800 ms de delay)
- Persistencia de todas las configuraciones, colores y patrones bloqueados
- Limite de mensajes en memoria configurable (50–5000)

### Input
- Historial de mensajes enviados navegable con **flechas arriba/abajo**
- Autocompletado del ultimo comando SAMP con **Tab**
- Indicador de idioma del teclado activo (EN / ES / etc.)
- Contador de caracteres con limite SAMP (**128 caracteres**), en rojo si se supera
- Busqueda en tiempo real con **Ctrl+F**, con contador de resultados hallados

### Actualizaciones
- **Verificacion automatica** de versiones al iniciar (descarga discreta en segundo plano)
- **Notificacion en el chat** del juego si hay una nueva version disponible
- Panel de estado en la pestana **Opciones** del menu de configuracion
- Boton directo para **abrir el repositorio** en el navegador

---

## Requisitos

| Componente | Version Minima |
|------------|----------------|
| GTA San Andreas | 1.0 US |
| SA-MP | 0.3.7-R1 |
| MoonLoader | 0.26+ |
| ASI Loader | Cualquiera |

### Dependencias (incluidas en el repositorio)
- `mimgui` — Wrapper de Dear ImGui para MoonLoader (FYP)
- `encoding` — Conversion de codificaciones UTF-8 / CP1252 / CP1251
- `sqlite3.dll` — Motor de base de datos embebido

---

## Instalacion

1. **Descargar** el repositorio o los archivos individuales desde [GitHub](https://github.com/kxrkoxv/Chat-Imgui)

2. **Copiar** la estructura al directorio de MoonLoader:
   ```
   moonloader/
   ├── Chat.lua
   └── lib/
       ├── bitex.lua
       ├── encoding.lua
       ├── sqlite3.dll
       └── mimgui/
           ├── init.lua
           ├── imgui.lua
           ├── dx9.lua
           ├── cdefs.lua
           ├── cimguidx9.dll
           └── themes.luac
   ```

3. **Iniciar** el juego. La base de datos de configuracion se creara automaticamente en:
   ```
   moonloader/config/Chat_MImGui.db
   ```

---

## Uso

### Abrir el Chat
Presiona **T** o la tecla configurada para abrir el input. El fondo del chat aparece con una animacion de fade-in y el cursor se activa automaticamente.

### Enviar Mensajes
Escribe tu mensaje y presiona **Enter**. El texto se procesa mediante `sampProcessChatInput` y se guarda en el historial local de enviados.

### Navegar el Historial de Enviados
- **Flecha Arriba** — mensaje anterior del historial
- **Flecha Abajo** — mensaje siguiente del historial

### Menu Contextual (clic derecho sobre un mensaje)
| Opcion | Descripcion |
|--------|-------------|
| Copiar texto | Copia el texto sin codigos de color al portapapeles |
| Copiar al input | Copia el texto con codigos de color al campo de input |
| Filtrar mensaje | Agrega el texto del mensaje como patron bloqueado |
| Editar | Abre un modal para editar texto, color y hora del mensaje localmente |
| Eliminar | Elimina el mensaje del historial local |

### Scroll
- **Rueda del mouse** — desplazamiento fino (paso de 50 px)
- **PgUp / PgDn** — desplazamiento rapido (paso de 200 px)
- **Barra lateral vertical** — arrastrar para navegar libremente

---

## Configuracion

Accede al panel de configuracion con **`/chconfig`** o con la hotkey personalizada.

### Pestana: Apariencia

| Opcion | Descripcion | Rango |
|--------|-------------|-------|
| Fuente | Selector de fuentes TTF detectadas en la carpeta de Windows | — |
| Tamano de fuente | Altura en pixeles | 8–36 |
| Lineas visibles | Cantidad de lineas mostradas en el chat | 4–60 |
| Colores (x16) | Selectores RGBA para cada elemento visual | — |
| Restablecer colores | Vuelve todos los colores a los valores por defecto | — |

### Pestana: Filtros

Gestiona los **patrones de texto bloqueado**:

| Elemento | Descripcion |
|----------|-------------|
| Lista de bloqueados | Muestra todos los patrones activos con boton `X` para eliminar cada uno |
| Campo de texto | Escribe el patron que quieres bloquear |
| Boton `+ Bloquear` | Agrega el patron escrito a la lista (sin duplicados, case-insensitive) |
| Borrar todos | Elimina todos los patrones bloqueados de un solo click |

**Como funciona el bloqueo:**
- El patron se busca con coincidencia parcial en el contenido del mensaje (sin codigos de color)
- No distingue mayusculas de minusculas
- Al agregar o eliminar un patron, el historial de mensajes se reprocesa automaticamente
- Los patrones se guardan en la base de datos y persisten entre sesiones
- Se puede bloquear un mensaje directamente haciendo clic derecho sobre el y eligiendo `Filtrar mensaje`

### Pestana: Opciones

| Seccion | Opcion | Descripcion |
|---------|--------|-------------|
| Memoria | Limite de mensajes | Maximo de mensajes en memoria (50–5000) |
| Estadisticas | — | Mensajes en historial, enviados guardados, sin leer |
| Acciones | Limpiar chat | Borra todos los mensajes del historial local |
| Acciones | Limpiar historial enviados | Borra el historial de mensajes enviados |
| Comandos y atajos | — | Referencia rapida de comandos y teclas |
| Actualizaciones | — | Version actual, estado de la ultima verificacion, boton de descarga si hay update |
| Repositorio | — | Boton para abrir `github.com/kxrkoxv/Chat-Imgui` en el navegador |

### Pestana: Teclas

Asigna una **hotkey personalizada** para abrir/cerrar el panel de configuracion sin necesidad de escribir `/chconfig`.

| Accion | Descripcion |
|--------|-------------|
| Asignar tecla | Entra en modo captura y registra la proxima tecla presionada |
| Quitar hotkey | Desactiva la hotkey asignada |

Teclas recomendadas: F1–F4, F8–F12, Insert, numpad, letras.

---

## Sistema de Filtros

El sistema de filtros funciona exclusivamente mediante **patrones de texto plano bloqueado**. No existe un filtro por tipo de mensaje, color o rango de tiempo — el unico mecanismo es el bloqueo por contenido.

### Flujo completo

```
Mensaje entrante (SAMP hook)
        │
        ▼
  msgIsBlocked(m)
  ┌─────────────────────────────────┐
  │  Para cada patron en la lista:  │
  │  ¿patron aparece en el texto    │
  │   (sin tags, lowercase)?        │
  └─────────────────────────────────┘
        │
   Si coincide ──► Mensaje descartado (no se muestra)
        │
   Si no coincide ──► pushMsg() ──► messages[] ──► Render
```

### Funciones internas

| Funcion | Descripcion |
|---------|-------------|
| `msgIsBlocked(m)` | Retorna `true` si algun patron coincide con el texto del mensaje |
| `msgPassesFilter(m)` | Wrapper de `msgIsBlocked`, retorna `true` si el mensaje debe mostrarse |
| `addBlockedPattern(pat)` | Agrega un patron a la lista (normaliza espacios, previene duplicados) |
| `removeBlockedPattern(i)` | Elimina el patron en el indice `i` de la lista |
| `purgeBlockedFromHistory()` | Elimina del historial en memoria todos los mensajes que coincidan con algun patron activo |
| `saveBlocked()` | Persiste la lista de patrones en SQLite |
| `serializeBlocked()` | Convierte la lista a string separado por `\n` para almacenamiento |
| `deserializeBlocked(s)` | Reconstruye la lista de patrones desde el string almacenado |

### Ejemplo de uso

Para bloquear todos los mensajes que contengan "You have been kicked":
1. Haz clic derecho sobre uno de esos mensajes y selecciona `Filtrar mensaje`, **o**
2. Ve a `Filtros` en el menu de configuracion, escribe `you have been kicked` en el campo y pulsa `+ Bloquear`

Todos los mensajes existentes y futuros que contengan ese texto (en cualquier combinacion de mayusculas) quedaran ocultos.

---

## Sistema de Actualizaciones

Al iniciar el script (antes de que SA-MP este disponible), se lanza en segundo plano una verificacion de version directamente contra el `Chat.lua` del repositorio en GitHub.

### Como funciona

1. Se descarga `https://raw.githubusercontent.com/kxrkoxv/Chat-Imgui/main/Chat.lua` con `downloadUrlToFile` (solo los primeros 2 KB del archivo, para ser eficiente)
2. Se extrae la version remota buscando la linea `CURRENT_VERSION = 'X.Y.Z'` dentro del script descargado. Si no se encuentra ese formato, se busca `script_version_number(X)` como fallback y se convierte a `X.0.0`
3. Se compara la version remota con `CURRENT_VERSION` del script local usando versionado semantico (`MAYOR.MENOR.PARCHE`)
4. Segun el resultado:
   - **Sin cambios**: el panel **Opciones** muestra `Tienes la version mas reciente`
   - **Actualizacion disponible**: el panel muestra la nueva version y un boton `Actualizar a vX.Y.Z` que descarga el `Chat.lua` completo y lo sobreescribe en disco; al terminar indica que hay que recargar el script (F9 o `/reload`)
   - **Error de red**: el panel muestra el mensaje de error y un boton `Reintentar`
5. Desde el panel **Opciones** tambien hay un boton `Verificar actualizaciones` para lanzar el chequeo manualmente en cualquier momento

### No se usa `version.txt`

El sistema **no depende de un archivo `version.txt` separado**. La fuente de verdad es siempre la constante `CURRENT_VERSION` dentro del propio `Chat.lua` del repositorio.

### Mantener actualizado el script

Para publicar una nueva version basta con:
1. Incrementar `CURRENT_VERSION` en `Chat.lua` (por ejemplo `'1.0.0'` → `'1.1.0'`)
2. Subir el archivo al repositorio en la rama `main`

No es necesario mantener ningun archivo auxiliar de version.

---

## Comandos

| Comando | Descripcion |
|---------|-------------|
| `/timestamp` | Activa/desactiva los timestamps `[HH:MM:SS]` en cada mensaje |
| `/chconfig` | Abre/cierra el panel de configuracion |
| `/clearchat` | Limpia todos los mensajes del historial local |

---

## Atajos de Teclado

| Tecla | Funcion |
|-------|---------|
| `T` / `F6` | Abrir chat |
| `Enter` | Enviar mensaje |
| `Escape` | Cerrar input del chat |
| `F5` | Ocultar / mostrar el chat completo |
| `Ctrl+F` | Activar / desactivar busqueda en tiempo real |
| `PgUp` | Scroll hacia arriba (200 px) |
| `PgDn` | Scroll hacia abajo (200 px) |
| `Rueda` | Scroll fino (50 px por paso) |
| `Flecha Arriba` | Historial anterior de mensajes enviados |
| `Flecha Abajo` | Historial siguiente de mensajes enviados |
| `Tab` | Autocompletar desde el ultimo input de SAMP |
| `Hotkey custom` | Abrir/cerrar configuracion (asignable en pestana Teclas) |

---

## Arquitectura

```
Chat.lua
├── Version y actualizaciones
│   ├── CURRENT_VERSION, UPDATE_CHECK_URL, GITHUB_URL
│   ├── compareVersions()
│   └── checkForUpdates() — descarga version.txt y notifica si hay update
│
├── FFI Definitions
│   ├── Windows API (VirtualProtect, VirtualAlloc, VirtualFree)
│   ├── SAMP Structures (stChatEntry, stInputInfo)
│   └── Locale Functions (GetLocaleInfoA, GetKeyboardLayoutNameA)
│
├── SQLite3 Layer
│   ├── db_open() / db_close()
│   ├── db_exec() / db_set() / db_get()
│   └── Debounce System (markDirty, flushDirty — 800ms)
│
├── Hook System
│   ├── Trampolines en memoria con VirtualAlloc
│   ├── onSampChat() — intercepta y empuja mensajes al historial
│   ├── onSampInput() — sincroniza el buffer del input
│   └── onSampInputEnable/Disable() — controla apertura y cierre del chat
│
├── Sistema de Filtros
│   ├── blockedPatterns[] — lista de patrones activos
│   ├── msgIsBlocked() / msgPassesFilter()
│   ├── addBlockedPattern() / removeBlockedPattern()
│   ├── purgeBlockedFromHistory()
│   └── saveBlocked() / serializeBlocked() / deserializeBlocked()
│
├── ImGui Renderer
│   ├── renderColorText() — parser de colores {RRGGBB} / {RRGGBBAA}
│   ├── chatWindow — ventana principal del chat (posicion fija, sin decoracion)
│   ├── settingsWindow — panel de configuracion con 4 pestanas
│   │   ├── drawTabApariencia() — fuentes, tamanos, 16 colores RGBA
│   │   ├── drawTabFiltros() — lista de patrones bloqueados, agregar/eliminar
│   │   ├── drawTabOpciones() — limites, stats, actualizaciones, GitHub
│   │   └── drawTabTeclas() — hotkey personalizable para el panel
│   └── Popups: menu contextual (clic derecho), modal de edicion de mensaje
│
└── Event Handlers
    ├── onWindowMessage() — teclado (ESC, F5, Ctrl+F, PgUp/Dn, hotkey), mouse (RButton, scroll)
    ├── Threads: scroll suave adaptativo, fade-in/fade-out del fondo
    └── onScriptTerminate — flush de DB, finalize de statements, cierre limpio
```

### Flujo de Datos

```
SAMP Chat Hook
      │
      ▼
 onSampChat()
      │
      ├── msgIsBlocked()? ──► Si: descartado
      │
      └── pushMsg() ──► messages[]
                              │
                              ▼
                       renderColorText()
                              │
                              ▼
                           ImGui
```

---

## Estructura de Archivos

```
.
├── Chat.lua                 # Script principal (~1800 lineas)
├── version.txt              # Numero de version para el sistema de actualizaciones
└── lib/
    ├── bitex.lua            # Utilidades de manipulacion de bits
    ├── encoding.lua         # Conversion UTF-8 / CP1252 / CP1251 / ASCII
    ├── sqlite3.dll          # Motor SQLite3
    └── mimgui/
        ├── init.lua         # API publica de MImGui
        ├── imgui.lua        # Bindings de Dear ImGui
        ├── dx9.lua          # Backend DirectX9
        ├── cdefs.lua        # Definiciones C de ImGui (cimgui)
        ├── cimguidx9.dll    # Biblioteca nativa compilada
        └── themes.luac      # Temas precompilados
```

---

## Base de Datos

El archivo `Chat_MImGui.db` almacena toda la configuracion en una tabla clave-valor:

```sql
CREATE TABLE config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

### Claves de configuracion

| Clave | Formato | Descripcion |
|-------|---------|-------------|
| `color.*` | `R\|G\|B\|A` (floats 0–1) | Colores RGBA de cada elemento visual |
| `val.font_size` | entero | Tamano de fuente en px |
| `val.font_name` | nombre de archivo | Fuente TTF seleccionada |
| `val.line_count` | entero | Lineas visibles del chat |
| `val.max_msgs` | entero | Limite de mensajes en memoria |
| `val.timestamp` | `0` / `1` | Estado de los timestamps |
| `filter.blocked` | patrones separados por `\n` | Lista de patrones bloqueados |
| `hotkey.settings` | VK code (entero) | Virtual key code de la hotkey personalizada |

---

## Notas Tecnicas

- Los hooks se instalan en direcciones especificas de `samp.dll` version **0.3.7-R1**; otras versiones no son compatibles
- Los codigos de color se parsean en formato `{RRGGBB}` (expandido a `{RRGGBBFF}` internamente) y `{RRGGBBAA}`
- El sistema de debounce agrupa escrituras a SQLite para evitar I/O excesivo durante el tipeo o cambios de color
- El renderizado usa el **ImGuiListClipper** para virtualizar la lista de mensajes y mantener el rendimiento con historiales grandes
- La animacion de scroll usa interpolacion adaptativa: velocidad mayor cuanto mas lejos esta el destino
- La verificacion de actualizaciones usa `downloadUrlToFile` (API de MoonLoader) y no bloquea el hilo principal

---

## Creditos

| Rol | Autor |
|-----|-------|
| Desarrollo | **[kxrko](https://github.com/kxrkoxv)** |
| MImGui | [FYP](https://github.com/THE-FYP) |
| Encoding Library | BlastHack Team |
| Dear ImGui | [Omar Cornut](https://github.com/ocornut) |

---

<div align="center">

**[Chat MImGui](https://github.com/kxrkoxv/Chat-Imgui)** — Desarrollado con dedicacion para la comunidad SA-MP

</div>
