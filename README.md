<div align="center">

# Chat MImGui

### Reemplazo completo del chat nativo de SA-MP con interfaz moderna

[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=flat-square&logo=lua&logoColor=white)](https://www.lua.org/)
[![MoonLoader](https://img.shields.io/badge/MoonLoader-0.26+-00599C?style=flat-square)](https://www.blast.hk/moonloader/)
[![ImGui](https://img.shields.io/badge/ImGui-DirectX9-red?style=flat-square)](https://github.com/ocornut/imgui)
[![SQLite](https://img.shields.io/badge/SQLite3-Database-003B57?style=flat-square&logo=sqlite&logoColor=white)](https://www.sqlite.org/)
[![Version](https://img.shields.io/badge/version-1.3.1-blueviolet?style=flat-square)](https://github.com/kxrkoxv/Chat-Imgui/releases)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

<br>

<p align="center">
  <img src="https://i.postimg.cc/rphDhwhZ/087B97F4-C6E3-4883-889E-9EFAD9343DEF.png" alt="Chat MImGui Preview" width="720"><br>
  <sub><b>Vista del chat en juego</b></sub>
</p>

<br>

<p align="center">
  <img src="https://i.postimg.cc/v8nWm52M/8CAAE144-49AA-4A43-897E-F7A790974752.png" alt="Chat MImGui Configuración" width="720"><br>
  <sub><b>Panel de configuración</b></sub>
</p>

<br>

<p align="center">
  <img src="https://i.postimg.cc/TPLYjbpd/60631C23-8F13-416C-8632-EF62F4340741.png" alt="Chat MImGui Emojis Discord" width="720"><br>
  <sub><b>Sistema de emojis de Discord integrado en el chat</b></sub>
</p>

<br>

<i>Sistema de chat reimaginado para SA-MP con renderizado DirectX9, emojis de Discord, actualizaciones automáticas y persistencia local</i>

</div>

---

## Índice

- [Descripción](#descripción)
- [Características](#características)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Uso](#uso)
- [Sistema de Emojis Discord](#sistema-de-emojis-discord)
- [Configuración](#configuración)
- [Sistema de Filtros](#sistema-de-filtros)
- [Sistema de Actualizaciones](#sistema-de-actualizaciones)
- [Comandos](#comandos)
- [Atajos de Teclado](#atajos-de-teclado)
- [Arquitectura](#arquitectura)
- [Créditos](#créditos)

---

## Descripción

**Chat MImGui** es un script para MoonLoader que reemplaza completamente el sistema de chat nativo de SA-MP. Utiliza la biblioteca MImGui (wrapper de Dear ImGui para MoonLoader) junto con renderizado DirectX9 para proporcionar una experiencia de chat moderna, fluida y altamente personalizable.

El sistema intercepta los mensajes del chat original mediante hooks de bajo nivel en `samp.dll`, los procesa y renderiza utilizando ImGui, manteniendo toda la funcionalidad original mientras agrega nuevas capacidades como emojis de Discord, bloqueo de patrones, búsqueda en tiempo real, actualizaciones automáticas completas y personalización total de la interfaz.

---

## Características

### Interfaz y Animaciones
- Renderizado mediante **Dear ImGui** con backend DirectX9
- Animaciones de **fade-in/fade-out** al abrir y cerrar el chat
- **Scroll suave con inercia**: interpolación exponencial adaptativa (más rápido cuando la distancia es grande)
- Sistema de scroll corregido con flag `scrollToBottom` que evita race conditions al llegar mensajes nuevos
- **Efecto glassmorphism** bajo el panel del chat, picker de emojis y ventana de configuración (requiere `mimgui_blur`)
- Efecto de **hover animado** por mensaje con interpolación de alpha
- **Efecto ripple** al hacer clic sobre un mensaje
- Soporte completo para **colores SAMP** (`{RRGGBB}` y `{RRGGBBAA}`)
- Efecto de **sombra de texto** opcional (modo display 2 de SAMP)
- Timestamps opcionales `[HH:MM:SS]` con color personalizable
- Indicador de mensajes no leídos con **badge pulsante**
- **Toasts** con animación slide-in desde la derecha para notificaciones del sistema
- **Scrollbar personalizada** dibujada con DrawList (sin artefactos, con drag, click-to-jump y glow animado)
- **Borde del input** con glow morado animado al estar activo

### Sistema de Emojis Discord
- Integración completa con la **API de Discord** para obtener emojis personalizados de tu servidor
- Los emojis se envían como `:nombre:` — **compatible con todos los jugadores**: quienes no tienen el mod ven `:nombre:` igual que Discord sin Nitro
- **Picker visual** con grid de imágenes, scroll interno, tooltips y búsqueda
- **Autocompletado en el input**: al escribir `:pe` se muestran sugerencias de emojis con imagen y nombre
  - Navegar con `↑↓`, confirmar con `TAB`, cancelar con `ESC`
- **Render inline** en los mensajes del chat: los tokens `:nombre:` se reemplazan por imágenes en tiempo real
- Soporte de renderizado correcto dentro del área de scroll (clip rect respetado)
- Sistema de caché local de texturas en `moonloader/config/emoji_cache/`
- Carga diferida de texturas (lazy loading) para no bloquear el hilo principal
- Botón `:)` en el input para abrir el picker, con ícono del emoji si está disponible

### Sistema de Filtros
Basado en **bloqueo de patrones de texto plano**:
- Comparación **no distingue mayúsculas/minúsculas**
- Coincidencia **parcial**: si el patrón aparece en cualquier parte del mensaje, este se oculta
- Los patrones se aplican sobre el texto sin códigos de color
- Los mensajes bloqueados se ocultan **en tiempo real** y se purgan del historial
- Los patrones se **persisten en SQLite** y se restauran al reiniciar
- Agregar patrón directamente desde el **clic derecho** sobre cualquier mensaje → `Filtrar mensaje`

### Personalización
- Selector de **fuentes del sistema** (TTF)
- Tamaño de fuente ajustable (8–36 px)
- Líneas visibles configurables (4–60)
- **17 colores personalizables** con selector RGBA:
  - Fondo del chat, fondo del input y bordes
  - Color de texto y timestamps
  - Badge de no leídos y menciones
  - Colores de selección y hover (con cap de alpha para legibilidad)
  - Scrollbar (fondo, cursor, estados hover/activo)
  - Botones del menú contextual
- Resaltado de **menciones de tu nick** con barra lateral y fondo sutil
- Botón de **restablecer colores** a valores por defecto

### Almacenamiento
- Base de datos **SQLite3** local (`moonloader/config/Chat_MImGui.db`)
- Sistema de **debounce** optimizado (800 ms de delay antes de escribir)
- Persistencia de todas las configuraciones, colores y patrones bloqueados
- Historial de comandos recientes para autocompletado
- Límite de mensajes en memoria configurable (50–5000)

### Input
- Historial de mensajes enviados navegable con **flechas arriba/abajo**
- **Autocompletado de comandos** con sugerencias visuales (builtin + aprendidos automáticamente del chat)
- **Autocompletado de emojis** al escribir `:nombre:` con preview de imágenes
- Indicador de idioma del teclado activo (EN / ES / etc.)
- Contador de caracteres con límite SAMP (**128 caracteres**), con gradiente de color
- Búsqueda en tiempo real con **Ctrl+F**, con contador de resultados

### Actualizaciones Automáticas
- Sistema basado en **`manifest.json`** que define todos los archivos del proyecto
- **Verificación automática** al iniciar (silenciosa, en background)
- Descarga e instala **automáticamente** Chat.lua, librerías y DLLs
- **Detección e instalación automática de librerías nuevas**: si el manifest incluye una librería que el usuario no tiene, se descarga e instala sola en `moonloader/lib/`
- Log detallado con progreso en tiempo real visible en la UI
- Botón "Reinstalar todo (forzado)" para reparar la instalación
- Toast de notificación al completar con instrucción de recarga (F9)

---

## Requisitos

| Componente | Versión Mínima |
|------------|----------------|
| GTA San Andreas | 1.0 US |
| SA-MP | 0.3.7-R1 |
| MoonLoader | 0.26+ |
| ASI Loader | Cualquiera |

### Dependencias (gestionadas automáticamente)
- `mimgui` — Wrapper de Dear ImGui para MoonLoader (FYP)
- `encoding` — Conversión de codificaciones UTF-8 / CP1252 / CP1251
- `sqlite3.dll` — Motor de base de datos embebido
- `mimgui_blur` *(opcional)* — Efecto glassmorphism bajo las ventanas. Se instala automáticamente si está en el manifest

---

## Instalación

### Método automático (recomendado)

1. Descarga únicamente `Chat.lua` del repositorio
2. Colócalo en `moonloader/`
3. Inicia el juego — el script **detectará e instalará automáticamente** todas las dependencias necesarias

### Método manual

1. **Descargar** el repositorio completo desde [GitHub](https://github.com/kxrkoxv/Chat-Imgui)

2. **Copiar** la estructura al directorio de MoonLoader:
   ```
   moonloader/
   ├── Chat.lua
   └── lib/
       ├── encoding.lua
       ├── sqlite3.dll
       ├── mimgui/
       │   ├── init.lua
       │   ├── imgui.lua
       │   ├── dx9.lua
       │   ├── cdefs.lua
       │   ├── cimguidx9.dll
       │   └── themes.luac
       └── mimgui_blur/          ← opcional, para efecto glassmorphism
           ├── init.lua
           └── mimgui_blur_lib.dll
   ```

3. La base de datos se crea automáticamente en:
   ```
   moonloader/config/Chat_MImGui.db
   ```

---

## Uso

### Abrir el Chat
Presiona **T** o **F** para abrir el input. El chat aparece con animación de fade-in y el cursor se activa automáticamente.

### Enviar Mensajes
Escribe tu mensaje y presiona **Enter**. Puedes insertar emojis con `:nombre:` directamente o usando el botón `:)`.

### Menú Contextual (clic derecho sobre un mensaje)
| Opción | Descripción |
|--------|-------------|
| Copiar texto | Copia el texto sin códigos de color al portapapeles |
| Copiar al input | Copia el texto con códigos de color al campo de input |
| Filtrar mensaje | Agrega el texto del mensaje como patrón bloqueado |
| Editar | Abre un modal para editar texto, color y hora localmente |
| Eliminar | Elimina el mensaje del historial local |

### Scroll
- **Rueda del mouse** — desplazamiento fino (50 px por paso), bloqueado automáticamente cuando el picker de emojis está abierto
- **PgUp / PgDn** — desplazamiento rápido (200 px)
- **Barra lateral** — arrastrar el grab, o clic en el track para saltar a esa posición

---

## Sistema de Emojis Discord

### Configuración inicial

1. Ve a **Ajustes → Discord** en el panel de configuración (`/chconfig`)
2. Crea un Bot en [discord.com/developers](https://discord.com/developers) → Applications → tu app → Bot → Reset Token
3. Pega el **Token del Bot** en el campo correspondiente
4. Activa el **Modo desarrollador** en Discord (Ajustes de usuario → Avanzado)
5. Haz clic derecho en tu servidor → **Copiar ID del servidor** y pégala en Guild ID
6. Presiona **"Descargar emojis automáticamente"**

Los emojis se cachean localmente en `moonloader/config/emoji_cache/`. Las próximas veces se cargan instantáneamente desde la caché.

### Compatibilidad con otros jugadores

> Los emojis se envían al servidor **exactamente como texto** `:nombre:`. Los jugadores sin el mod ven `:nombre:`, igual que Discord sin Nitro. No hay modificación del protocolo de red.

### Usar emojis

| Método | Descripción |
|--------|-------------|
| Escribir `:nombre:` | Inserta el emoji directamente. Se renderiza inline en el chat |
| Autocompletado | Escribe `:pe` → aparecen sugerencias con preview de imagen. `TAB` para completar, `↑↓` para navegar |
| Picker `:)` | Abre una grilla visual con todos los emojis del servidor. Clic para insertar |

### Caché y rendimiento

- Las texturas se cargan de forma diferida (lazy) para no bloquear el juego
- El clip rect del área de mensajes se respeta correctamente: los emojis no "se escapan" al hacer scroll
- La carpeta de caché puede borrarse para forzar una re-descarga desde Discord

---

## Configuración

Accede con **`/chconfig`** o con la hotkey personalizada.

### Pestaña: Apariencia

| Opción | Descripción | Rango |
|--------|-------------|-------|
| Fuente | Selector de fuentes TTF del sistema | — |
| Tamaño de fuente | Altura en píxeles | 8–36 |
| Líneas visibles | Cantidad de líneas mostradas | 4–60 |
| Colores (×17) | Selectores RGBA para cada elemento | — |
| Restablecer colores | Vuelve todos los valores a los predeterminados | — |

### Pestaña: Filtros

| Elemento | Descripción |
|----------|-------------|
| Lista de bloqueados | Todos los patrones activos con botón `X` por cada uno |
| Campo de texto | Escribe el patrón a bloquear |
| `+ Bloquear` | Agrega el patrón (sin duplicados, case-insensitive) |
| Borrar todos | Elimina todos los patrones de un clic |

### Pestaña: Opciones

| Sección | Descripción |
|---------|-------------|
| Comportamiento | Resaltado de menciones, límite de mensajes |
| Estadísticas | Mensajes en historial, enviados guardados, no leídos, emojis cargados |
| Acciones | Limpiar chat, limpiar historial enviados, exportar a .txt |
| Comandos y atajos | Referencia rápida |
| Actualizaciones | Estado, log de progreso, botones de actualizar/reinstalar |

### Pestaña: Teclas

Asigna una **hotkey personalizada** para abrir/cerrar la configuración.

### Pestaña: Discord

Configuración del sistema de emojis:
- Token del Bot y Guild ID
- Estado de carga con barra de progreso
- Botones: descargar automático, cargar desde JSON, recargar caché local
- Guía de configuración paso a paso integrada

---

## Sistema de Filtros

```
Mensaje entrante (SAMP hook)
        │
        ▼
  msgIsBlocked(m)
  ┌────────────────────────────────────┐
  │  Para cada patrón en la lista:     │
  │  ¿patrón aparece en el texto       │
  │   (sin tags de color, lowercase)?  │
  └────────────────────────────────────┘
        │
   Si coincide ──► Mensaje descartado
        │
   No coincide ──► pushMsg() ──► messages[] ──► Render
```

| Función | Descripción |
|---------|-------------|
| `msgIsBlocked(m)` | `true` si algún patrón coincide con el texto |
| `msgPassesFilter(m)` | Wrapper, `true` si el mensaje debe mostrarse |
| `addBlockedPattern(pat)` | Agrega patrón (normaliza espacios, previene duplicados) |
| `removeBlockedPattern(i)` | Elimina el patrón en el índice `i` |
| `purgeBlockedFromHistory()` | Elimina del historial mensajes que coincidan con patrones activos |
| `saveBlocked()` | Persiste la lista en SQLite |

---

## Sistema de Actualizaciones

### Cómo funciona

Al iniciar, el script descarga silenciosamente `manifest.json` del repositorio. El manifest define todos los archivos del proyecto y las librerías necesarias:

```json
{
  "version": "1.3.1",
  "files": [
    { "path": "Chat.lua",        "url": "Chat.lua",        "required": true },
    { "path": "lib/sqlite3.dll", "url": "lib/sqlite3.dll", "required": true }
  ],
  "libs": [
    {
      "name": "mimgui_blur",
      "check": "lib/mimgui_blur/mimgui_blur_lib.dll",
      "files": [
        { "dest": "lib/mimgui_blur/mimgui_blur_lib.dll", "url": "libs/mimgui_blur/mimgui_blur_lib.dll" },
        { "dest": "lib/mimgui_blur/init.lua",            "url": "libs/mimgui_blur/init.lua" }
      ]
    }
  ]
}
```

### Flujo automático

```
Inicio del script
      │
      ▼
Descarga manifest.json
      │
      ▼
¿Version remota > local?
  │             │
 Sí            No
  │             └── "Ya estás al día" (sin notificación)
  ▼
Descarga cada archivo en manifest.files
  │
  ▼
Para cada lib en manifest.libs:
  ┌── ¿Ya instalada? → omitir
  └── No instalada → descargar e instalar en moonloader/lib/
  │
  ▼
Toast: "Actualizado a vX.X.X — recarga con F9"
```

### Para mantener el repositorio actualizado

1. Subir el `Chat.lua` actualizado con el nuevo valor en `CURRENT_VERSION`
2. Actualizar `"version"` en `manifest.json` con el mismo valor
3. Agregar/modificar entradas en `files` o `libs` según lo que cambió

Los usuarios recibirán la actualización automáticamente en su próxima sesión de juego.

---

## Comandos

| Comando | Descripción |
|---------|-------------|
| `/timestamp` | Activa/desactiva los timestamps `[HH:MM:SS]` en cada mensaje |
| `/chconfig` | Abre/cierra el panel de configuración |
| `/clearchat` | Limpia todos los mensajes del historial local |

---

## Atajos de Teclado

| Tecla | Función |
|-------|---------|
| `T` / `F6` | Abrir chat |
| `Enter` | Enviar mensaje |
| `Escape` | Cerrar input / cancelar autocompletado |
| `F5` | Ocultar / mostrar el chat completo |
| `Ctrl+F` | Activar / desactivar búsqueda en tiempo real |
| `PgUp` | Scroll hacia arriba (200 px) |
| `PgDn` | Scroll hacia abajo (200 px) |
| `Rueda` | Scroll fino (50 px, bloqueado si el picker está abierto) |
| `↑ / ↓` | Historial de enviados / navegar sugerencias de autocompletado |
| `TAB` | Completar comando o emoji seleccionado |
| `Hotkey custom` | Abrir/cerrar configuración (asignable en pestaña Teclas) |

---

## Arquitectura

```
Chat.lua
├── Sistema de actualizaciones automáticas
│   ├── manifest.json (remoto) — define archivos y librerías
│   ├── runUpdater() — descarga, instala archivos y libs, con retry
│   ├── autoCheckUpdate() — verificación silenciosa al inicio
│   └── checkUpdateManual() / forceReinstall() — acciones desde UI
│
├── Sistema de emojis Discord
│   ├── fetchDiscordEmojis() — obtiene lista vía API con Bot Token
│   ├── httpDownloadToFile() — descarga cada emoji a la caché local
│   ├── loadEmojiTexture() — carga diferida de texturas DX9
│   ├── splitSegmentByEmojis() — tokeniza :nombre: dentro de segmentos
│   ├── renderColorText() — renderiza emojis inline con clip rect correcto
│   ├── drawEmojiAutocomplete() — popup de sugerencias con preview
│   ├── drawEmojiPicker() — ventana independiente con grid de emojis
│   └── renderInputEmojiOverlay() — preview de emojis sobre el InputText
│
├── FFI / Hooks
│   ├── Windows API (VirtualProtect, VirtualAlloc, VirtualFree, WinINet)
│   ├── SAMP Structures (stChatEntry, stInputInfo, chatInfoMin)
│   ├── onSampChat() — intercepta y procesa mensajes entrantes
│   └── onSampInputEnable/Disable() — controla apertura y cierre
│
├── SQLite3 Layer
│   ├── db_open / db_exec / db_set / db_get
│   └── Debounce (markDirty / flushDirty — 800 ms)
│
├── Sistema de animaciones
│   ├── lerpSmooth() — interpolación exponencial
│   ├── _anim.scrollCurrent/Target/ToBottom — scroll suave sin race conditions
│   ├── _anim.emojiPickerAlpha — fade del picker
│   ├── _anim.inputGlow — glow del borde del input
│   ├── _anim.badgePulse — pulso del badge de no leídos
│   └── _anim.scrollbarGlow — glow de la scrollbar al usarse
│
├── ImGui Renderer
│   ├── chatWindow — ventana principal (scrollbar DrawList custom)
│   ├── settingsWindow — panel con 5 pestañas
│   │   ├── drawTabApariencia()
│   │   ├── drawTabFiltros()
│   │   ├── drawTabOpciones() — incluye log de actualizaciones
│   │   ├── drawTabTeclas()
│   │   └── drawTabDiscord() — configuración del sistema de emojis
│   └── Popups: menú contextual, modal de edición
│
└── Event Handlers
    ├── onWindowMessage() — teclado, mouse, scroll (con guard para picker)
    ├── Click derecho: cálculo correcto de índice por fila visual
    └── onScriptTerminate — flush de DB y cierre limpio
```

### Flujo de un mensaje entrante

```
SAMP Chat Hook (onSampChat)
        │
        ├── smartDecode() — CP1252/CP1251 → UTF-8
        │
        ├── msgIsBlocked()? ──► Sí: descartado
        │
        └── pushMsg() ──► messages[]
                               │
                               ▼
                        renderColorText()
                               │
                        parseColorSegments()
                               │
                        splitSegmentByEmojis()
                          /          \
                    text              emoji
                  TextColored      AddImage (WindowDrawList
                                   + clip rect check)
```

---

## Estructura del Repositorio

```
.
├── Chat.lua                        # Script principal
├── manifest.json                   # Manifiesto de archivos y librerías
├── README.md
└── lib/
    ├── sqlite3.dll
    ├── mimgui/
    │   ├── init.lua
    │   ├── imgui.lua
    │   ├── dx9.lua
    │   ├── cdefs.lua
    │   ├── cimguidx9.dll
    │   └── themes.luac
    └── mimgui_blur/                # Opcional — glassmorphism
        ├── init.lua
        └── mimgui_blur_lib.dll
```

---

## Base de Datos

```sql
CREATE TABLE config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

| Clave | Formato | Descripción |
|-------|---------|-------------|
| `color.*` | `R\|G\|B\|A` (floats 0–1) | Colores RGBA de cada elemento visual |
| `val.font_size` | entero | Tamaño de fuente en px |
| `val.font_name` | nombre de archivo | Fuente TTF seleccionada |
| `val.line_count` | entero | Líneas visibles del chat |
| `val.max_msgs` | entero | Límite de mensajes en memoria |
| `val.timestamp` | `0` / `1` | Estado de los timestamps |
| `val.mention_highlight` | `0` / `1` | Resaltado de menciones |
| `filter.blocked` | patrones separados por `\n` | Lista de patrones bloqueados |
| `hotkey.settings` | VK code (entero) | Virtual key code de la hotkey |
| `discord.token` | string | Token del Bot de Discord |
| `discord.guild_id` | string | ID del servidor de Discord |
| `cache.recent_cmds` | comandos separados por `\n` | Historial de comandos para autocompletado |

---

## Notas Técnicas

- Los hooks se instalan en direcciones específicas de `samp.dll` versión **0.3.7-R1**
- Los códigos de color se parsean en formato `{RRGGBB}` (expandido a `{RRGGBBFF}` internamente) y `{RRGGBBAA}`
- Los emojis inline usan `GetWindowDrawList()` con verificación manual de clip rect para respetar el scroll del child window
- La scrollbar es completamente custom en DrawList — sin `VSliderInt` para evitar artefactos visuales
- El scroll usa una flag `scrollToBottom` que se resuelve **después** de leer `GetScrollMaxY()`, eliminando el salto visual al recibir mensajes
- El sistema de actualizaciones usa `downloadUrlToFile` de MoonLoader con retry de 3 intentos por archivo
- Las librerías faltantes se instalan automáticamente comparando el campo `check` del manifest con el filesystem local

---

## Créditos

| Rol | Autor |
|-----|-------|
| Desarrollo | **[kxrko](https://github.com/kxrkoxv)** |
| MImGui | [FYP](https://github.com/THE-FYP) |
| mimgui_blur | [Northn](https://github.com/Northn/mimgui_blur) |
| Encoding Library | BlastHack Team |
| Dear ImGui | [Omar Cornut](https://github.com/ocornut) |

---

<div align="center">

**[Chat MImGui](https://github.com/kxrkoxv/Chat-Imgui)** — Desarrollado con dedicación para la comunidad SA-MP

</div>
