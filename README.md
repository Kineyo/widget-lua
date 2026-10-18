# OpenClaw Qwen-Widget v2.0 — Hybrid Lua + C/C++ Desktop AI & Media Suite

[![OS: Linux / Pop!_OS / Windows / macOS](https://img.shields.io/badge/OS-Pop!__OS%20%7C%20Linux%20%7C%20Windows%20%7C%20macOS-48b9c7.svg?style=flat-square)](#instalacion-y-compilacion-por-sistema-operativo)
[![Architecture: Hybrid Lua 5.3 + C++17](https://img.shields.io/badge/Core-Lua%205.3%20%2B%20C%2B%2B17%20Native-000080.svg?style=flat-square)](#arquitectura-hibrida-lua--cc-y-presupuesto-de-ram--500-mb)
[![UI: GTK3 + Cairo Vector](https://img.shields.io/badge/GUI-GTK%203.0%20%2B%20Cairo%20Vector-e95420.svg?style=flat-square)](#sistema-de-diseno-visual-cero-emojis-y-fallbacks)
[![AI Engine: Embedded llama.cpp + Cloud API](https://img.shields.io/badge/AI-llama.cpp%20%28GGUF%29%20%2B%20Cloud%20API-10a37f.svg?style=flat-square)](#motor-de-inferencia-llamacpp-embebido--cloud-api)
[![RAM Budget: <= 500 MB](https://img.shields.io/badge/RAM%20Budget-%E2%89%A4%20500%20MB%20Strict-2ea44f.svg?style=flat-square)](#arquitectura-hibrida-lua--cc-y-presupuesto-de-ram--500-mb)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)


Widget de escritorio hibrido (**Lua 5.3 + C/C++17**), autonomo y ultraligero con motor de inferencia local **`llama.cpp` embebido** (y soporte nativo para **Cloud API**), **Corrector Gramatical Instantaneo por Hooks Nativos de Seleccion**, **Mini-Reproductor Unificado para YouTube Music y Spotify** con **Letras Sincronizadas (Karaoke LRC)** y **Agente Autonomo OpenClaw** asincrono. Disenado bajo un presupuesto estricto de memoria **menor o igual a 500 MB de RAM**.

<div align="center">
  <img src="assets/sprites/idle.png" alt="Qwen Widget v2.0 Avatar" width="160">
  <p><em>Interfaz vectorial de alto contraste sin emojis, con sprites de estado dinamicos generados desde qwen_image-v2.jpeg y consumo total &lt; 250 MB de RAM con inferencia local activa.</em></p>
</div>

---

## Instalacion y Compilacion por Sistema Operativo

<details>
<summary><b>> Windows;</b></summary>

Para descargar el .exe ve a release, busca latest y descarga el archivo que coincida con tu sistema operativo y arquitecura.

**Como compilar y/o modificar**
Primero clona el repositorio..
```powershell
git clone https://github.com/openclaw/qwen-widget.git
cd qwen-widget
```
1. Instala las herramientas de compilacion en Windows (MSYS2 / MinGW-w64 o Visual Studio Build Tools 2022, CMake >= 3.16 y NSIS para empaquetado `.exe`).
2. Compila los modulos nativos en C/C++ (`qwen_native.dll` y `qwen-widget-bin.exe`):
```powershell
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```
3. (Opcional) Regenera los sprites de estado e iconos desde `qwen_image-v2.jpeg`:
```powershell
python scripts/generate_sprites.py
```
4. Genera el instalador `.exe` con NSIS:
```powershell
makensis packaging/windows/installer.nsi
```
El instalador compilado quedara en `dist/QwenWidget-2.0.0-Setup-x64.exe`. Al iniciar por primera vez, el gestor integrado descargara automaticamente los modelos `es-grammar.gguf` y `qwen3.0-0.8b.gguf`.
</details>

<details>
<summary><b>> macOS;</b></summary>

Para descargar el instalador ve a release, busca latest y descarga el archivo que coincida con tu sistema operativo y arquitecura.

**Como compilar y/o modificar**
Primero clona el repositorio..
```bash
git clone https://github.com/openclaw/qwen-widget.git
cd qwen-widget
```
1. Instala las dependencias base con Homebrew:
```bash
brew install cmake pkg-config lua@5.3 gobject-introspection gtk+3 curl python3
```
2. Compila la capa nativa en C/C++ (`lib/qwen_native.so` con soporte para Accessibility API / CoreFoundation y el lanzador `bin/qwen-widget-bin`):
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4
```
3. (Opcional) Genera el paquete `.dmg` y `.pkg` nativo de macOS:
```bash
chmod +x packaging/macos/build_dmg.sh
./packaging/macos/build_dmg.sh
```
Los instaladores generados estaran disponibles en `dist/QwenWidget-2.0.0-macOS.dmg` y `dist/QwenWidget-2.0.0-macOS.pkg`.
</details>

<details>
<summary><b>> Distros de Linux;</b></summary>

Para descargar el paquete (.deb para Debian/Pop!_OS, paquete para Arch o el .tar.gz universal) ve a release, busca latest y descarga el archivo que coincida con tu sistema operativo y arquitecura.

**Como compilar y/o modificar**
Primero clona el repositorio..
```bash
git clone https://github.com/openclaw/qwen-widget.git
cd qwen-widget
```

1. **En Pop!_OS / Debian / Ubuntu**:
   Instala las cabeceras de desarrollo y dependencias GTK3/X11:
   ```bash
   sudo apt-get update
   sudo apt-get install -y cmake g++ gcc make pkg-config \
     libglib2.0-dev libx11-dev libxfixes-dev libxi-dev \
     lua5.3 liblua5.3-dev lua-lgi gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 gir1.2-pango-1.0 curl python3-pil
   ```
   Compila los modulos nativos en C/C++ (`lib/qwen_native.so`, `lib/libqwen_mmap_guard.so` y `bin/qwen-widget-bin`):
   ```bash
   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
   cmake --build build -j$(nproc)
   ```
   Para instalar y ejecutar directamente en tu sistema (descargando y verificando automaticamente `es-grammar.gguf` y `qwen3.0-0.8b.gguf`):
   ```bash
   ./install.sh
   ./run.sh --run
   ```
   Para construir los paquetes redistribuibles `.deb` y `.tar.gz` en `dist/`:
   ```bash
   ./scripts/build_packages.sh
   sudo dpkg -i dist/qwen-widget_2.0.0_amd64.deb
   ```

2. **En Arch Linux / Manjaro / EndeavourOS**:
   Instala las dependencias y construye el paquete nativo `.pkg.tar.zst` usando `makepkg`:
   ```bash
   sudo pacman -Syu --needed base-devel cmake gcc pkgconf lua53 lua53-lgi gtk3 glib2 libx11 libxfixes libxi curl
   cd packaging/arch
   makepkg -si
   ```

3. **Paquete Portable Universal (`.tar.gz`)**:
   Extrae el archivo portable en cualquier directorio y ejecutalo sin compilar:
   ```bash
   tar -xzf dist/qwen-widget-2.0.0-linux-x86_64.tar.gz
   cd qwen-widget-2.0.0
   ./bin/qwen-widget
   ```
</details>

<details>
<summary><b>> Google Colab (Compilacion en la Nube con 1 Clic);</b></summary>

Puedes compilar todos los releases (.deb y .tar.gz) en la nube utilizando las maquinas virtuales gratuitas de Google Colab sin consumir recursos locales:

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/openclaw/qwen-widget/blob/main/colab_build_release.ipynb)

1. Abre el notebook [colab_build_release.ipynb](file:///home/alex/Documentos/widget%20%5BGithub%5D/colab_build_release.ipynb) en Google Colab.
2. Ejecuta las celdas secuencialmente (soporta CPU y aceleracion NVIDIA GPU CUDA 12).
3. Elige tu metodo de exportacion:
   - Descarga directa al navegador de los paquetes compilados y sumas SHA256.
   - Guardado directo en tu Google Drive.
   - Publicacion automatica en GitHub Releases mediante API token.
</details>

<details>
<summary><b>> GitHub Actions (Compilacion y Releases Automaticos);</b></summary>

Cada vez que se suben cambios al repositorio (`push` a `main` o tags `v*`), el flujo de trabajo en [.github/workflows/release.yml](file:///home/alex/Documentos/widget%20%5BGithub%5D/.github/workflows/release.yml) compila automaticamente en matrices de maquinas virtuales:
- **Ubuntu Linux (x86_64)**: Paquete Debian `.deb` y Universal Portable `.tar.gz`.
- **Arch Linux (Contenedor base-devel)**: Paquete `.pkg.tar.zst` y PKGBUILD.
- **Windows Server (x64)**: Instalador ejecutable `.exe` (NSIS) y portable `.zip`.
- **macOS (arm64 Metal)**: Instaladores `.dmg` y `.pkg`.

Los artefactos se publican y actualizan de forma continua en la seccion **Releases** y quedan almacenados como artefactos descargables del workflow.
</details>

---

## 1. Arquitectura Hibrida (Lua + C/C++) y Presupuesto de RAM (<= 500 MB)

El proyecto combina la flexibilidad de **Lua 5.3 + LGI (GTK3/Cairo)** para la logica de interfaz con modulos nativos en **C/C++17** compilados mediante CMake:

* **`lib/qwen_native.so` (`src/qwen_native.cpp`)**:
  1. **Hooks nativos de seleccion de texto**: Hilo en segundo plano con `XFixesSelectSelectionInput` (`PRIMARY` y `CLIPBOARD`) y verificacion del estado de botones del puntero (`XQueryPointer` / Wayland fallback) para detectar instantaneamente cuando el usuario termina de seleccionar texto y obtener las coordenadas exactas del cursor sin polling lento ni bloqueos.
  2. **Geometria, Clamping e Interpolacion Nativa**: Calculo en C++ de acoplamiento magnetico (`compute_dock_position`), restriccion estricta a los bordes visibles del monitor (`clamp_rect`) e interpolacion lineal suave (`lerp_point`) para que el mini-reproductor y todos los paneles sigan a la burbuja principal en tiempo real durante el arrastre.
  3. **Puente IPC de Medios (`MPRIS2` / `GDBus`)**: Consulta directa en C++ sobre el bus de sesion D-Bus (`org.mpris.MediaPlayer2.*`) para detectar automaticamente **YouTube Music** y **Spotify**, extraer metadatos en tiempo real (`title`, `artist`, `album`, `art_url`, `length_sec`, `position_sec`, `volume`) y enviar comandos (`PlayPause`, `Next`, `Previous`, `Seek`, `SetPosition`, `Volume`).
  4. **Controlador de Inferencia `llama.cpp` y Presupuesto de Memoria**: Gestion del proceso embebido `bin/llama-server` con carga bajo demanda (*lazy loading*), cuantizacion de cache KV (`--cache-type-k q4_0 --cache-type-v q4_0`), tamano de contexto ajustado (`--ctx-size 768`), descarga automatica por inactividad o presion de memoria, y recorte explicito del heap con `malloc_trim(0)` + `collectgarbage("collect")`.
* **`lib/libqwen_mmap_guard.so` (`src/qwen_mmap_guard.c`)**:
  Libreria POSIX inyectada en `llama-server` que intercepta `mmap`/`mmap64` sobre archivos `.gguf` y aplica `posix_fadvise(..., POSIX_FADV_DONTNEED)` de forma periodica para expulsar paginas limpias de la cache del kernel, manteniendo el `VmRSS` total del widget + inferencia local en **~240 MB (estrictamente <= 500 MB)**.

---

## 2. Modulos Principales Refactorizados

### A. Musica, Letras Sincronizadas y Mini-Reproductor (YouTube Music + Spotify)
* **Soporte Dual YouTube Music + Spotify**: Deteccion automatica del reproductor activo o seleccion manual mediante el boton ciclico `[AUTO | YT MUSIC | SPOTIFY]` integrado en la cabecera del reproductor.
* **Mini-Reproductor Acoplado en Tiempo Real**: Al arrastrar o mover la burbuja principal, el mini-reproductor, la burbuja de letras, el chat y los paneles acoplados actualizan sus coordenadas instantaneamente en cada frame sin congelarse ni desfasarse.
* **Controles Completos**:
  * Pista anterior (`PREV`), Reproducir/Pausar (`PLAY/PAUSE`), Pista siguiente (`NEXT`).
  * Barra de progreso (`seek bar`) interactiva por clic o arrastre.
  * Control deslizante de volumen (`0% - 100%`) sincronizado por IPC.
  * Conmutador de letras sincronizadas (`LRC ON/OFF`) y ajuste fino de sincronizacion (`-0.5s` / `+0.5s` offset).
* **Letras Sincronizadas (LRCLIB + Cache Local)**: Limpieza inteligente de sufijos de YouTube/Spotify (`Official Video`, `Remastered`, `feat.`), consulta asincrona a LRCLIB con cache local en `~/.cache/qwen-widget/lyrics/` y sincronizacion precisa con soporte de offset.

### B. Corrector Gramatical Automatico y Menu Contextual de Seleccion
* **Aparicion Instantanea**: En cuanto seleccionas cualquier texto en el sistema y sueltas el boton del raton, el hook nativo en C++ dispara el menu flotante junto al cursor sin atajos manuales.
* **Cero Emojis y Contraste Garantizado**: Botones tipograficos con iconos vectoriales Cairo (`CORREGIR`, `MEJORAR`, `TRADUCIR`, `RESUMIR`, `EXPLICAR`) y variables explicitas de color `background` y `foreground` de alto contraste en todos los estados (`normal`, `hover`, `active`, `disabled`).

### C. Agente Autonomo OpenClaw
* **Ejecucion 100% Asincrona**: Reescritura completa de `lib/openclaw_agent.lua` y `lib/skills/openclaw_gateway.lua` con timeouts configurables, reconexion automatica, serializacion JSON segura y cero bloqueo del hilo GTK.

### D. Motor de Inferencia: `llama.cpp` Embebido + Cloud API
* **Sin Dependencia de Ollama**: El widget gestiona directamente su propio binario embebido `bin/llama-server` con librerias nativas en `lib/native/`.
* **Modelos GGUF Preconfigurados y Descarga Automatica**:
  1. **Correccion Gramatical**: `es-grammar` (`models/es-grammar.gguf`).
  2. **Chat Conversacional**: `qwen3.0-0.8b` (`models/qwen3.0-0.8b.gguf`).
  * Al instalar o iniciar por primera vez, `lib/model_manager.lua` e `install.sh` verifican la cabecera binaria `GGUF` y descargan automaticamente cualquier modelo faltante mostrando el progreso.
* **Soporte Nativo Cloud API**: Desde el panel de configuraciones o el selector rapido `LOCAL / CLOUD` en la ventana de chat, puedes alternar hacia proveedores en la nube (**OpenAI**, **Google Gemini**, **Anthropic**, **OpenRouter** o un endpoint **Custom OpenAI**) guardando tus claves de forma segura con permisos `0600` en `~/.config/qwen-widget/settings.json`.

---

## 3. Sistema de Diseno Visual, Cero Emojis y Sprites de Estado

* **Prohibicion Total de Emojis**: Toda la interfaz grafica (chat, configuraciones, menu contextual, mini-reproductor, burbujas informativas y notificaciones) utiliza exclusivamente tipografia limpia e iconografia vectorial geometrica renderizada con Cairo (`lib/icons.lua` y `assets/icons/`).
* **Panel de Configuraciones en 6 Secciones**: Organizado en pestañas de alto contraste (`General`, `Modelos Locales`, `API Cloud`, `Musica`, `Gramatica`, `OpenClaw`).
* **Sprites de Estado Generados desde `qwen_image-v2.jpeg`**:
  El script `scripts/generate_sprites.py` procesa el avatar base `qwen_image-v2.jpeg` y genera en `assets/sprites/` (formatos `.png` y `.webp`) los 7 estados reactivos conectados a la maquina de estados del widget:
  `idle`, `hover`, `chatting`, `thinking`, `music`, `grammar` y `error`.

---

## 4. Estructura del Proyecto

```text
widget/
├── CMakeLists.txt                  # Build system C/C++17 (Linux, Windows, macOS)
├── install.sh                      # Instalador autonomo con descarga GGUF automatica
├── run.sh                          # Lanzador rapido e integrador de entorno
├── sync-to-github.sh               # Puente de sincronizacion hacia el repositorio GitHub
├── qwen_image-v2.jpeg              # Imagen base del nuevo avatar
├── .github/workflows/
│   └── release.yml                 # CI/CD multiplataforma (.exe, .dmg/.pkg, .deb, Arch, .tar.gz)
├── src/
│   ├── qwen_native.cpp             # Modulo C++17: hooks X11/Wayland, MPRIS2, geometria, llama.cpp
│   ├── qwen_mmap_guard.c           # Guardia POSIX mmap para presupuesto estricto <= 500 MB RAM
│   ├── qwen_runner.cpp             # Ejecutable nativo embebido multiplataforma
│   └── include/lua_capi.h          # Cabecera ligera Lua 5.3 C API
├── bin/
│   ├── qwen-widget                 # Script lanzador con entorno nativo configurado
│   ├── qwen-widget-bin             # Binario nativo compilado en C++
│   ├── qwen-power                  # Control de encendido/apagado/reinicio sin emojis
│   └── llama-server                # Servidor de inferencia llama.cpp embebido
├── lib/
│   ├── main.lua                    # Punto de entrada, loop GTK3 y coordinacion de ventanas
│   ├── config.lua                  # Sistema de diseno, paleta de alto contraste y persistencia
│   ├── icons.lua                   # Renderizador vectorial Cairo (cero emojis)
│   ├── model_manager.lua           # Descarga automatica y verificacion GGUF de modelos
│   ├── ai_engine.lua               # Motor hibrido llama.cpp local + Cloud API (OpenAI/Gemini/Anthropic)
│   ├── widget.lua                  # Burbuja principal con maquina de estados de sprites
│   ├── chat.lua                    # Ventana flotante de chat + panel de 6 secciones de ajustes
│   ├── player.lua                  # Mini-reproductor YT Music + Spotify con seguimiento en vivo
│   ├── mpris.lua                   # Puente hibrido C++/Lua para control de medios MPRIS2
│   ├── lyrics.lua                  # Cliente LRCLIB + cache local + offset de sincronizacion
│   ├── lyrics_bubble.lua           # Burbuja superior de letras sincronizadas
│   ├── text_popup.lua              # Menu contextual instantaneo de gramatica y traduccion
│   ├── bubbles.lua                 # Burbujas de metricas en vivo con screen clamping
│   ├── fetchers.lua                # Colectores asincronos con fallbacks garantizados
│   ├── openclaw_agent.lua          # Agente ReAct OpenClaw asincrono
│   └── skills/                     # Habilidades modulares sin emojis (writing, gateway, etc.)
├── assets/
│   ├── sprites/                    # Sprites de estado (.png y .webp): idle, hover, chatting, etc.
│   └── icons/                      # Iconografia geometrica generada programaticamente
├── models/
│   ├── es-grammar.gguf             # Modelo local por defecto para correccion gramatical
│   └── qwen3.0-0.8b.gguf           # Modelo local por defecto para chat conversacional
├── packaging/
│   ├── arch/PKGBUILD               # Empaquetado nativo para Arch Linux (.pkg.tar.zst)
│   ├── macos/build_dmg.sh          # Constructor de paquete .dmg y .pkg para macOS
│   └── windows/installer.nsi       # Script NSIS para instalador .exe de Windows
└── scripts/
    ├── generate_sprites.py         # Generador programatico de sprites e iconos desde qwen_image-v2.jpeg
    └── build_packages.sh           # Constructor local de paquetes .deb (Pop!_OS/Debian) y .tar.gz
```

---

## Licencia

Este proyecto se distribuye bajo la Licencia **MIT**. Consulta el archivo `LICENSE` para mas detalles.
