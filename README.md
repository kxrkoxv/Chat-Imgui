<div align="center">

# Chat MImGui

### Reemplazo completo del chat nativo de SA-MP con interfaz moderna

[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=flat-square&logo=lua&logoColor=white)](https://www.lua.org/)
[![MoonLoader](https://img.shields.io/badge/MoonLoader-0.26+-00599C?style=flat-square)](https://www.blast.hk/moonloader/)
[![ImGui](https://img.shields.io/badge/ImGui-DirectX9-red?style=flat-square)](https://github.com/ocornut/imgui)
[![SQLite](https://img.shields.io/badge/SQLite3-Database-003B57?style=flat-square&logo=sqlite&logoColor=white)](https://www.sqlite.org/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

<br>

<img src="https://postimg.cc/TyD21fvn" alt="Chat MImGui Preview" width="720">

*Sistema de chat reimaginado para SA-MP con renderizado DirectX9 y persistencia local*

</div>

---

## Indice

- [Descripcion](#descripcion)
- [Caracteristicas](#caracteristicas)
- [Requisitos](#requisitos)
- [Instalacion](#instalacion)
- [Uso](#uso)
- [Configuracion](#configuracion)
- [Comandos](#comandos)
- [Atajos de Teclado](#atajos-de-teclado)
- [Arquitectura](#arquitectura)
- [Creditos](#creditos)

---

## Descripcion

**Chat MImGui** es un script para MoonLoader que reemplaza completamente el sistema de chat nativo de SA-MP. Utiliza la biblioteca MImGui (wrapper de Dear ImGui para MoonLoader) junto con renderizado DirectX9 para proporcionar una experiencia de chat moderna, fluida y altamente personalizable.

El sistema intercepta los mensajes del chat original mediante hooks de bajo nivel, los procesa y renderiza utilizando ImGui, manteniendo toda la funcionalidad original mientras agrega nuevas capacidades como filtros avanzados, busqueda en tiempo real y personalizacion completa de la interfaz.

---

## Caracteristicas

### Interfaz
- Renderizado mediante **Dear ImGui** con backend DirectX9
- Animaciones suaves de fade-in/fade-out
- Scroll suave con interpolacion adaptativa
- Soporte completo para **colores SAMP** (codigos hexadecimales en texto)
- Timestamps opcionales en cada mensaje
- Indicador de mensajes no leidos
- Menu contextual por mensaje (clic derecho)

### Sistema de Filtros
- Filtrado por **tipo de mensaje** (Chat, Sistema, Server)
- Filtrado por **contenido de texto**
- Filtrado por **prefijo/nombre de jugador**
- Filtrado por **color del mensaje**
- Filtrado por **rango de tiempo** (HH:MM)
- Opcion de **invertir filtros**
- Sensibilidad a mayusculas configurable
- Barra de progreso visual de mensajes filtrados

### Personalizacion
- Selector de **fuentes del sistema** (TTF)
- Tamano de fuente ajustable (8-36px)
- Lineas visibles configurables (4-60)
- **16 colores personalizables**:
  - Fondo del chat y del input
  - Bordes de ventana
  - Color de texto y timestamps
  - Colores de seleccion y hover
  - Scrollbar (fondo, cursor, estados)
  - Botones del menu contextual

### Almacenamiento
- Base de datos **SQLite3** local
- Sistema de **debounce** para escritura optimizada (800ms)
- Persistencia de todas las configuraciones
- Limite de mensajes configurable (50-5000)

### Input
- Historial de mensajes enviados (flechas arriba/abajo)
- Autocompletado con Tab
- Indicador de idioma del teclado
- Contador de caracteres con limite SAMP (128)
- Busqueda en tiempo real (Ctrl+F)

---

## Requisitos

| Componente | Version Minima |
|------------|----------------|
| GTA San Andreas | 1.0 US |
| SA-MP | 0.3.7-R1 |
| MoonLoader | 0.26+ |
| ASI Loader | Cualquiera |

### Dependencias (incluidas)
- `mimgui` - Wrapper de ImGui para MoonLoader
- `encoding` - Conversion de codificaciones (UTF-8, CP1251, etc.)
- `bitex` - Operaciones de bits extendidas
- `sqlite3.dll` - Motor de base de datos

---

## Instalacion

1. **Descargar** el repositorio o los archivos individuales

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

3. **Iniciar** el juego - la configuracion se creara automaticamente en:
   ```
   moonloader/config/Chat_MImGui.db
   ```

---

## Uso

### Abrir el Chat
Presiona **T** o **F6** para abrir el input del chat. El fondo aparecera con una animacion suave y el cursor se activara automaticamente.

### Enviar Mensajes
Escribe tu mensaje y presiona **Enter**. El mensaje se procesa mediante SAMP y se guarda en el historial local.

### Navegar el Historial
- **Flecha Arriba** - Mensaje anterior del historial
- **Flecha Abajo** - Mensaje siguiente del historial

### Menu Contextual
Haz **clic derecho** sobre cualquier mensaje para:
- Copiar el texto (sin codigos de color)
- Copiar al input (con codigos de color)
- Editar el mensaje localmente
- Eliminar el mensaje

### Scroll
- **Rueda del mouse** - Desplazamiento fino
- **PgUp / PgDn** - Desplazamiento rapido
- **Barra lateral** - Arrastrar para navegar

---

## Configuracion

Accede al panel de configuracion con el comando `/chconfig` o editando los mensajes.

### Pestana: Apariencia

| Opcion | Descripcion | Rango |
|--------|-------------|-------|
| Fuente | Selector de fuentes TTF del sistema | - |
| Tamano de fuente | Pixels de altura | 8-36 |
| Lineas visibles | Cantidad de lineas mostradas | 4-60 |
| Colores | 16 selectores de color RGBA | - |

### Pestana: Filtros

| Filtro | Descripcion |
|--------|-------------|
| Tipo de mensaje | Todos / Chat / Sistema / Server |
| Contiene texto | Busqueda parcial en contenido |
| Prefijo/Jugador | Busqueda en nombre del remitente |
| Color | Codigo hexadecimal (parcial) |
| Rango de tiempo | Formato HH:MM (desde/hasta) |
| Invertir | Muestra los que NO coinciden |
| Mayus/Min | Sensibilidad a mayusculas |

### Pestana: Opciones

| Opcion | Descripcion | Rango |
|--------|-------------|-------|
| Limite de mensajes | Maximos en memoria | 50-5000 |
| Limpiar chat | Borra todos los mensajes | - |
| Limpiar historial | Borra mensajes enviados | - |

---

## Comandos

| Comando | Descripcion |
|---------|-------------|
| `/timestamp` | Activa/desactiva timestamps |
| `/chconfig` | Abre el panel de configuracion |
| `/clearchat` | Limpia todos los mensajes |

---

## Atajos de Teclado

| Tecla | Funcion |
|-------|---------|
| `T` / `F6` | Abrir chat |
| `Enter` | Enviar mensaje |
| `Escape` | Cerrar chat |
| `F5` | Ocultar/mostrar chat |
| `Ctrl+F` | Activar busqueda |
| `PgUp` | Scroll hacia arriba |
| `PgDn` | Scroll hacia abajo |
| `Flecha Arriba` | Historial anterior |
| `Flecha Abajo` | Historial siguiente |
| `Tab` | Autocompletar |

---

## Arquitectura

```
Chat.lua
├── FFI Definitions
│   ├── Windows API (VirtualProtect, VirtualAlloc)
│   ├── SAMP Structures (stChatEntry, stInputInfo)
│   └── Locale Functions (GetLocaleInfoA, GetKeyboardLayoutNameA)
│
├── SQLite3 Layer
│   ├── db_open() / db_close()
│   ├── db_exec() / db_set() / db_get()
│   └── Debounce System (markDirty, flushDirty)
│
├── Hook System
│   ├── Memory patching con trampolines
│   ├── onSampChat() - Intercepcion de mensajes
│   ├── onSampInput() - Sincronizacion de input
│   └── onSampInputEnable/Disable() - Control de estado
│
├── Filter Engine
│   ├── msgPassesFilter()
│   ├── Filtros por tipo, texto, color, tiempo
│   └── Sistema de inversion
│
├── ImGui Renderer
│   ├── renderColorText() - Parser de colores SAMP
│   ├── chatWindow - Ventana principal
│   ├── settingsWindow - Panel de configuracion
│   └── Context menu / Edit popup
│
└── Event Handlers
    ├── onWindowMessage() - Teclado y mouse
    ├── Threads: Scroll suave, Fade animacion
    └── Script termination cleanup
```

### Flujo de Datos

```
SAMP Chat Hook ──► pushMsg() ──► messages[] ──► renderColorText() ──► ImGui
                                     │
                                     ▼
                              msgPassesFilter()
                                     │
                                     ▼
                              Display/Hidden
```

---

## Estructura de Archivos

```
.
├── Chat.lua                 # Script principal (~1800 lineas)
└── lib/
    ├── bitex.lua           # Utilidades de manipulacion de bits
    ├── encoding.lua        # Conversion UTF-8/CP1251/ASCII
    ├── sqlite3.dll         # Motor SQLite3
    └── mimgui/
        ├── init.lua        # API publica de MImGui
        ├── imgui.lua       # Bindings de ImGui
        ├── dx9.lua         # Backend DirectX9
        ├── cdefs.lua       # Definiciones C de ImGui
        ├── cimguidx9.dll   # Biblioteca nativa
        └── themes.luac     # Temas precompilados
```

---

## Base de Datos

El archivo `Chat_MImGui.db` almacena la configuracion en una tabla simple:

```sql
CREATE TABLE config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

### Claves de Configuracion

| Prefijo | Descripcion |
|---------|-------------|
| `color.*` | Colores RGBA (formato: `R\|G\|B\|A`) |
| `val.*` | Valores numericos y strings |
| `filter.*` | Estado de los filtros |

---

## Notas Tecnicas

- El script utiliza **hooks de bajo nivel** en direcciones especificas de `samp.dll` (version 0.3.7-R1)
- Los colores se parsean en formato SAMP (`{RRGGBB}` o `{RRGGBBAA}`)
- El sistema de debounce agrupa escrituras a la DB para evitar I/O excesivo
- El renderizado utiliza **clipper** de ImGui para optimizar listas largas
- La animacion de scroll usa interpolacion adaptativa segun la distancia

---

## Creditos

| Rol | Autor |
|-----|-------|
| Desarrollo | **kxrko** |
| MImGui | [FYP](https://github.com/THE-FYP) |
| Encoding Library | BlastHack Team |
| Dear ImGui | [Omar Cornut](https://github.com/ocornut) |

---

<div align="center">

**Chat MImGui** - Desarrollado con dedicacion para la comunidad SA-MP

</div>
