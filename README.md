# 🌟 OpenClaw Qwen-Widget 🦞

[![OS: Linux / Pop!_OS](https://img.shields.io/badge/OS-Pop!__OS%2024.04%20%7C%20Linux-48b9c7.svg?style=flat-square&logo=linux)](https://pop.system76.com/)
[![Lua: 5.3](https://img.shields.io/badge/Lua-5.3%20%2B%20LGI-000080.svg?style=flat-square&logo=lua)](https://www.lua.org/)
[![UI: GTK3 + Cairo](https://img.shields.io/badge/GUI-GTK%203.0%20%2B%20Cairo-e95420.svg?style=flat-square&logo=gnome)](https://www.gtk.org/)
[![AI: Ollama](https://img.shields.io/badge/AI-Ollama%20%28Qwen3%29-black.svg?style=flat-square)](https://ollama.ai/)
[![Agent: OpenClaw](https://img.shields.io/badge/Agent-OpenClaw%20ReAct-ff4500.svg?style=flat-square)](https://github.com/openclaw/openclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)

Widget de escritorio flotante, interactivo y ultraligero para **Pop!_OS 24.04 LTS / Linux** con capacidades de **Agente Autónomo OpenClaw** (loop ReAct, comandos de sistema, diagnóstico y control de escritorio), **Mini Reproductor de YouTube Music** con barra de seek interactiva, y **Letras Sincronizadas en Tiempo Real (Karaoke LRC)**.

<div align="center">
  <img src="assets/avatar.jpg" alt="Qwen Widget Avatar" width="180" style="border-radius: 50%;">
  <p><em>Orbe interactivo flotante con diseño minimalista, animaciones suaves y consumo &lt;50 MB de RAM.</em></p>
</div>

---

## ✨ Características Principales

### 🦞 Agente Autónomo OpenClaw Integrado
Inspirado en el ecosistema [openclaw/openclaw](https://github.com/openclaw/openclaw) (*"The AI that really does things"*):
- 📊 **Diagnóstico de hardware en vivo**: Monitoreo de RAM libre, carga de CPU (1m, 5m, 15m), espacio en disco, estado de batería y kernel.
- 💻 **Ejecución asíncrona de comandos de terminal** vía subprocesos GLib (`/sh <comando>`).
- 🔍 **Búsqueda instantánea en la web** mediante DuckDuckGo Instant Answers (`/search <consulta>`).
- 🚀 **Lanzador de aplicaciones**: Abre navegador, terminal, YouTube Music o gestor de archivos (`/app <nombre>`).
- 📸 **Capturas de pantalla integradas** compatibles con Pop!_OS / Wayland / X11 (`/shot`).
- ⚡ **Loop ReAct**: El modelo analiza intenciones y puede invocar herramientas del sistema de manera autónoma cuando se le solicita.
- ⌨ **Slash Commands**: Acceso veloz a funciones comunes (`/sys`, `/music`, `/next`, `/prev`, `/play`, `/pause`, `/sh`, `/search`, `/app`, `/shot`, `/skills`, `/model`, `/clear`, `/help`).

### 🎵 Mini Reproductor de YouTube Music & MPRIS
- 🎯 **Despliegue automático**: Aparece flotante suavemente cada vez que YouTube Music o cualquier reproductor MPRIS cambia de pista.
- 🖼 **Información completa**: Portada del álbum en alta resolución, título de la canción, artista y estado.
- ⏱ **Barra de tiempo / Seek interactiva**: Haz clic o desliza con el ratón sobre la barra de progreso para adelantar o retroceder la canción en tiempo real.
- ⏯ **Controles completos**: Botones de pista anterior (⏮), reproducir/pausar (▶/⏸), pista siguiente (⏭).
- 📌 **Modo Pin / Auto-ocultado**: Mantén el reproductor anclado o deja que se oculte automáticamente tras 12 segundos de inactividad.

### 🎤 Letras Sincronizadas en Tiempo Real (Modo Karaoke)
- 💬 **Burbujas dinámicas superiores**: Las letras emergen sobre el orbe para no solaparse con las estadísticas del sistema ni el panel de chat.
- ⏱ **Sincronización milimétrica**: Sincronizadas línea por línea con la reproducción actual vía [LRCLIB](https://lrclib.net/) (sin necesidad de API keys).
- 🎸 **Detección de silencios y solos**: Se oculta durante pasajes instrumentales y reaparece cuando el vocalista retoma la letra.
- 🤫 **Modo silencioso**: Si la canción es instrumental o carece de LRC, el widget se mantiene limpio sin burbujas residuales.

### 💡 Burbujas Dinámicas de Información en Vivo
- 🕐 Reloj y saludos contextuales adaptados a la hora del día.
- 💵 Divisas actualizadas al momento: Dólar y Euro en pesos mexicanos (USD/MXN, EUR/MXN).
- 🪙 Criptomonedas en tiempo real: Bitcoin (BTC), Ethereum (ETH), Solana (SOL) vía CoinGecko con fallback a Binance.
- 🌤 Clima local en tiempo real vía `wttr.in`.
- 🧠 Diagnóstico de memoria RAM y carga del procesador.
- 💡 Consejos tecnológicos y atajos de Pop!_OS / COSMIC.

### ⚡ Control de Energía y Daemon (`qwen-power`)
- Script modular para encendido, apagado, reinicio y toggle del widget con notificaciones en el escritorio.

---

## 📦 Estructura del Proyecto

```
widget/
├── install.sh              # Instalador desatendido del sistema y dependencias
├── run.sh                  # Lanzador y verificador con soporte CLI
├── sync.sh                 # Sincronizador y sanitizador seguro para GitHub
├── README.md               # Documentación completa del proyecto
├── .gitignore              # Reglas de exclusión para datos personales y temporales
├── bin/
│   ├── qwen-widget         # Daemon launcher ejecutable en /usr/local/bin
│   └── qwen-power          # Interruptor de encendido / apagado / reinicio
├── lib/
│   ├── main.lua            # Entry point y bucle principal GTK3
│   ├── config.lua          # Configuración centralizada (dimensiones, colores, APIs)
│   ├── json.lua            # Encoder/Decoder JSON en Lua puro
│   ├── utils.lua           # Helpers de renderizado Cairo, Pango y curvaturas
│   ├── animator.lua        # Motor de animaciones fluidas por frames (60 FPS)
│   ├── fetchers.lua        # Micro-fetchers asíncronos (clima, forex, cripto, stats)
│   ├── dbus_listener.lua   # Interceptor de señales DBus y KDE Connect
│   ├── mpris.lua           # Cliente MPRIS DBus bidireccional para reproductores
│   ├── player.lua          # Mini Reproductor flotante con seek bar interactiva
│   ├── lyrics.lua          # Cliente y parser de letras sincronizadas (LRCLIB / LRC)
│   ├── lyrics_bubble.lua   # Burbuja animada superior para karaoke
│   ├── openclaw_agent.lua  # Motor de habilidades, herramientas y loop ReAct
│   ├── ollama.lua          # Cliente streaming de Ollama con prompts contextuales
│   ├── chat.lua            # Panel de chat flotante con Markdown y slash commands
│   ├── bubbles.lua         # Burbujas de datos laterales con snap magnético
│   ├── launcher.lua        # Menú radial de acceso rápido
│   └── widget.lua          # Orbe central flotante con soporte de arrastre
└── assets/
    ├── avatar.jpg          # Avatar principal sanitizado (sin metadatos EXIF/GPS)
    └── icon.png            # Icono del sistema para notificaciones y lanzadores
```

---

## 🛠️ Requisitos del Sistema

- **Sistema Operativo**: Pop!_OS 24.04 LTS, Ubuntu 22.04+, Debian o distribuciones compatibles con GTK3 / X11.
- **Lua**: Lua 5.3 con bindings LGI (`lua-lgi`).
- **Librerías del Sistema**:
  ```bash
  sudo apt install lua-lgi gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 gir1.2-pango-1.0 curl gcc make
  ```
- **Ollama**:
  ```bash
  # Iniciar el servicio Ollama
  ollama serve

  # Descargar el modelo por defecto (u otro de tu preferencia)
  ollama pull qwen3:0.6b
  # O modelo con mayor capacidad de razonamiento:
  ollama pull qwen3:4b
  ```

---

## 🚀 Instalación y Ejecución

### 1. Instalación Completa
Ejecuta el script de instalación para compilar componentes necesarios, registrar los ejecutables en `/usr/local/bin` y configurar el inicio automático:

```bash
./install.sh
```

O usa el asistente de `run.sh`:
```bash
./run.sh --install
```

### 2. Ejecutar el Widget
```bash
# Lanzar directamente desde la carpeta
./run.sh --run

# O desde cualquier terminal
qwen-widget
```

### 3. Usar un Modelo Diferente
Puedes cambiar dinámicamente de modelo asignando la variable de entorno:
```bash
QWEN_MODEL=qwen3:4b qwen-widget
```
O dentro del chat flotante escribiendo: `/model qwen3:4b`.

---

## 🎮 Controles e Interacción

| Acción | Disparador | Comportamiento |
|---|---|---|
| **Chat AI OpenClaw** | `Click izquierdo` en el orbe | Despliega / oculta el panel de conversación flotante |
| **Burbuja de Datos** | `Click derecho` en el orbe | Cicla datos en vivo (Clima, Crypto, Dólar, RAM/CPU, Reloj, Tips) |
| **Ciclar Información** | `Rueda del ratón (Scroll)` | Pasa inmediatamente a la siguiente burbuja informativa |
| **Siguiente Dato** | `Click sobre la burbuja` | Avanza al siguiente dato (Click derecho: cerrar burbuja) |
| **Reproductor YouTube Music**| `Click central` en el orbe | Abre / cierra el mini reproductor con carátula y seek bar |
| **Mover Widget** | `Arrastrar con el ratón` | Desplaza el orbe por la pantalla (snap magnético a los bordes) |
| **Seek en Canción** | `Click o arrastre en barra` | Adelanta o retrocede la reproducción en tiempo real |
| **Cerrar Chat** | Tecla `Escape` | Cierra rápidamente la ventana de chat flotante |

---

## 🦞 Catálogo de Comandos del Agente OpenClaw

Dentro de la ventana de chat puedes comunicarte en lenguaje natural o utilizar comandos directos con barra oblicua:

- `/help` o `/ayuda` — Muestra el catálogo de comandos disponibles.
- `/sys` o `/status` — Diagnóstico completo de CPU, RAM, disco y batería.
- `/music` o `/player` — Despliega el reproductor o muestra el estado actual de la música.
- `/next`, `/prev`, `/play`, `/pause` — Controles directos de YouTube Music.
- `/sh <comando>` — Ejecuta un comando en terminal bash (ej: `/sh free -h`, `/sh uptime`).
- `/search <texto>` — Búsqueda rápida de información en la web con DuckDuckGo.
- `/app <nombre>` — Lanza aplicaciones de escritorio (ej: `/app terminal`, `/app chrome`).
- `/shot` — Realiza una captura de pantalla del escritorio.
- `/skills` — Lista las habilidades de agente registradas.
- `/model <nombre>` — Cambia dinámicamente el modelo de Ollama en uso.
- `/clear` — Limpia el historial de la conversación.

---

## ⚡ Control con `qwen-power`

El binario auxiliar `bin/qwen-power` permite encender, apagar o reiniciar el widget fácilmente (ideal para asociarlo a atajos de teclado o atajos de Pop!_OS):

```bash
# Alternar estado (enciende si está apagado, reinicia si está encendido)
qwen-power

# Encender
qwen-power on

# Apagar
qwen-power off

# Reiniciar
qwen-power restart
```

---

## 🔄 Flujo de Sincronización Seguro con GitHub

Este repositorio cuenta con un sincronizador (`sync.sh`) para vincular tu carpeta local de trabajo con la versión limpia para GitHub, asegurando que:
1. **Ningún dato personal, log o archivo temporal se suba**: Se filtran credenciales, variables `.env`, logs y temporales.
2. **Las imágenes se despojen de metadatos EXIF y GPS**: Cualquier imagen modificada en `assets/` se sanitiza automáticamente antes de commitear.
3. **Escaneo de seguridad proactivo**: Detecta tokens, claves API o rutas personales antes de subir.

```bash
# Sincronizar cambios desde tu carpeta local y revisar el estado:
./sync.sh

# Sincronizar, sanitizar y generar un commit:
./sync.sh --commit "feat: mejoras en el reproductor de musica"

# Sincronizar, sanitizar, commit y subir directamente a GitHub:
./sync.sh --push
```

Si desarrollas desde tu carpeta local `/home/alex/Documentos/widget`, puedes ejecutar directamente:
```bash
./sync-to-github.sh --commit "Actualizaciones" --push
```

---

## ⚙️ Configuración (`lib/config.lua`)

Toda la apariencia, temporizadores y endpoints se pueden ajustar en `lib/config.lua`:
- `BUBBLE_SIZE`: Diámetro del orbe principal (por defecto `70`).
- `DATA_FETCH_INTERVAL`: Frecuencia de actualización de fuentes de internet (por defecto cada 5 minutos).
- `LYRICS_ENABLED`: Habilita o deshabilita la burbuja de letras sincronizadas.
- `PLAYER_AUTO_HIDE_MS`: Tiempo antes de que el mini reproductor se oculte suavemente (por defecto `12000` ms).
- `OLLAMA_MODEL`: Modelo por defecto (`qwen3:0.6b`).
- `ACCENT`: Paleta de colores pastel y neón para Pop!_OS.

---

## 🏗️ Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────────┐
│                          main.lua                           │
│                   (entry point + GTK loop)                  │
├─────────────┬───────────────────────────────┬───────────────┤
│ widget.lua  │         chat.lua              │  player.lua   │
│ (Cairo draw)│    (OpenClaw Chat UI)         │(YT MiniPlayer)│
├─────────────┼───────────────┬───────────────┼───────────────┤
│ fetchers    │ dbus_listener │ openclaw_agent│   mpris.lua   │
│ (curl async)│ (session bus) │ (Skills/Tools)│ (DBus player) │
├─────────────┴───────────────┴───────────────┴───────────────┤
│     animator.lua    │    ollama.lua   │     utils.lua       │
│     (GLib timers)   │    (LLM stream) │     (Cairo/Pango)   │
├─────────────────────────────────────────────────────────────┤
│                  config.lua (all settings)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 📄 Licencia

Este proyecto está bajo la Licencia **MIT**. Consulta el archivo `LICENSE` para más información.
