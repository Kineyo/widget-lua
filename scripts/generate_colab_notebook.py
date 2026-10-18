#!/usr/bin/env python3
import json

notebook = {
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "# 🚀 Qwen-Widget v2.0 — Compilador de Releases en Google Colab\n",
    "\n",
    "[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/openclaw/qwen-widget/blob/main/colab_build_release.ipynb)\n",
    "\n",
    "Este Jupyter Notebook permite compilar, verificar y empaquetar de forma automatizada los releases de **Qwen-Widget v2.0** en las máquinas virtuales gratuitas de Google Colaboratory (utilizando procesadores multi-núcleo o GPUs NVIDIA con aceleración CUDA).\n",
    "\n",
    "### 📦 Artefactos y Paquetes Generados:\n",
    "1. **Debian / Ubuntu / Pop!_OS (`.deb`)**: Instalador estándar para `/opt/qwen-widget` con accesos directos y configuración autostart.\n",
    "2. **Universal Portable (`.tar.gz`)**: Tarball autocontenido ejecutable en cualquier distribución Linux x86_64.\n",
    "3. **Binarios y Módulos Nativos C/C++**: `qwen_native.so` (LGI/X11 hooks), `libqwen_mmap_guard.so` (POSIX page eviction guard) y `qwen-widget-bin`.\n",
    "4. **Runtime embebido `llama.cpp`**: Versión optimizada (CPU x86_64 o GPU CUDA).\n",
    "5. **Sumas de Verificación Criptográficas SHA256**: Generadas automáticamente para comprobar la integridad de cada paquete.\n",
    "\n",
    "---"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## ⚙️ Configuración y Parámetros del Build\n",
    "Configura las opciones de compilación a continuación y luego ejecuta la celda."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {
    "cellView": "form"
   },
   "outputs": [],
   "source": [
    "#@title ⚙️ Parámetros de Compilación { run: \"auto\" }\n",
    "import os\n",
    "\n",
    "REPO_URL = \"https://github.com/openclaw/qwen-widget.git\" #@param {type:\"string\"}\n",
    "BRANCH = \"main\" #@param {type:\"string\"}\n",
    "BUILD_TYPE = \"Release\" #@param [\"Release\", \"RelWithDebInfo\", \"Debug\"]\n",
    "LLAMA_BACKEND = \"CPU (Universal x86_64)\" #@param [\"CPU (Universal x86_64)\", \"CUDA 12 (NVIDIA GPU Acceleration)\"]\n",
    "DOWNLOAD_MODELS = False #@param {type:\"boolean\"}\n",
    "WORKSPACE_DIR = \"/content/widget\"\n",
    "\n",
    "print(\"Configuración definida:\")\n",
    "print(f\"  • Repositorio:    {REPO_URL} (rama: {BRANCH})\")\n",
    "print(f\"  • Tipo de Build:  {BUILD_TYPE}\")\n",
    "print(f\"  • Backend LLM:    {LLAMA_BACKEND}\")\n",
    "print(f\"  • Incluir GGUF:   {DOWNLOAD_MODELS}\")\n",
    "print(f\"  • Directorio:     {WORKSPACE_DIR}\")"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 🔍 Paso 1: Diagnóstico del Entorno (CPU, GPU y Memoria)\n",
    "Comprobamos las especificaciones del entorno asignado por Google Colab."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "# Diagnosticar CPU y memoria\n",
    "!echo \"=== INFORMACIÓN DE LA CPU ===\"\n",
    "!lscpu | grep -E 'Model name|Socket|Thread|NUMA|CPU\\(s\\)' || nproc\n",
    "!echo \"\\n=== MEMORIA RAM ===\"\n",
    "!free -h\n",
    "!echo \"\\n=== DISCO ===\"\n",
    "!df -h /content\n",
    "\n",
    "# Comprobar GPU NVIDIA (si está disponible)\n",
    "!echo \"\\n=== INFORMACIÓN DE GPU NVIDIA ===\"\n",
    "!if command -v nvidia-smi &>/dev/null; then nvidia-smi; else echo \"Modo CPU asignado (sin aceleradora GPU activa)\"; fi"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 📥 Paso 2: Clonar o Actualizar el Código Fuente\n",
    "Descargamos el repositorio de Qwen-Widget o preparamos el directorio de trabajo."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "import os, shutil\n",
    "\n",
    "if os.path.exists(WORKSPACE_DIR):\n",
    "    print(f\"Actualizando repositorio existente en {WORKSPACE_DIR}...\")\n",
    "    %cd {WORKSPACE_DIR}\n",
    "    !git fetch --all\n",
    "    !git checkout {BRANCH}\n",
    "    !git pull origin {BRANCH} || true\n",
    "else:\n",
    "    print(f\"Clonando {REPO_URL} (rama: {BRANCH}) en {WORKSPACE_DIR}...\")\n",
    "    !git clone --depth 1 --branch {BRANCH} {REPO_URL} {WORKSPACE_DIR}\n",
    "    %cd {WORKSPACE_DIR}\n",
    "\n",
    "!git log -1 --oneline\n",
    "!ls -la"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 🛠️ Paso 3: Instalar Dependencias del Sistema\n",
    "Instalamos los compiladores (GCC/G++, Make, CMake), bibliotecas de interfaz (GTK3, GLib, X11, XFixes, Xi) y el entorno de scripting Lua 5.3 + LGI."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "!echo \"[Instalando dependencias de compilación y empaquetado en Ubuntu Colab]\"\n",
    "!apt-get update -qq\n",
    "!DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \\\n",
    "    cmake g++ gcc make pkg-config \\\n",
    "    libglib2.0-dev libx11-dev libxfixes-dev libxi-dev \\\n",
    "    lua5.3 liblua5.3-dev lua-lgi gir1.2-gtk-3.0 \\\n",
    "    gir1.2-gdkpixbuf-2.0 gir1.2-pango-1.0 \\\n",
    "    curl unzip tar dpkg-dev patchelf\n",
    "\n",
    "!echo \"✓ Dependencias instaladas exitosamente.\""
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 🧠 Paso 4: Descargar e Integrar Runtime Embebido llama.cpp\n",
    "Descargamos el servidor de inferencia optimizado `llama-server` y sus bibliotecas dinámicas compartidas."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "%cd {WORKSPACE_DIR}\n",
    "import os, urllib.request, zipfile\n",
    "\n",
    "os.makedirs(\"bin\", exist_ok=True)\n",
    "os.makedirs(\"lib/native\", exist_ok=True)\n",
    "os.makedirs(\"dist\", exist_ok=True)\n",
    "\n",
    "LLAMA_VER = \"b5092\"\n",
    "if \"CUDA\" in LLAMA_BACKEND:\n",
    "    LLAMA_ZIP_URL = f\"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_VER}/llama-{LLAMA_VER}-bin-ubuntu-cu12.4-x64.zip\"\n",
    "    print(\"Descargando runtime llama.cpp con aceleración CUDA 12...\")\n",
    "else:\n",
    "    LLAMA_ZIP_URL = f\"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_VER}/llama-{LLAMA_VER}-bin-ubuntu-x64.zip\"\n",
    "    print(\"Descargando runtime universal llama.cpp para CPU (x86_64 AVX2)...\")\n",
    "\n",
    "tmp_zip = \"/tmp/llama.zip\"\n",
    "!curl -sSL \"{LLAMA_ZIP_URL}\" -o {tmp_zip}\n",
    "\n",
    "with zipfile.ZipFile(tmp_zip, 'r') as z:\n",
    "    z.extractall(\"/tmp/llama_out\")\n",
    "\n",
    "!find /tmp/llama_out -type f -name \"llama-server\" -exec cp -f {} bin/llama-server \\;\n",
    "!chmod +x bin/llama-server\n",
    "!find /tmp/llama_out -type f -name \"lib*.so*\" -exec cp -a {} lib/native/ \\;\n",
    "\n",
    "!echo \"=== VERIFICACIÓN LLAMA-SERVER ===\"\n",
    "!ls -lh bin/llama-server\n",
    "!bin/llama-server --version || true"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## ⚡ Paso 5: Compilación Nativa C/C++ con CMake\n",
    "Compilamos los módulos nativos compartidos (`qwen_native.so` y `libqwen_mmap_guard.so`) y el lanzador binario embebido (`qwen-widget-bin`)."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "%cd {WORKSPACE_DIR}\n",
    "import subprocess, multiprocessing\n",
    "\n",
    "cores = multiprocessing.cpu_count()\n",
    "print(f\"Compilando con CMake ({BUILD_TYPE}) utilizando {cores} núcleos...\")\n",
    "\n",
    "!cmake -S . -B build -DCMAKE_BUILD_TYPE={BUILD_TYPE}\n",
    "!cmake --build build -j{cores}\n",
    "\n",
    "!echo \"\\n=== ARTEFACTOS NATIVOS COMPILADOS ===\"\n",
    "!ls -lh lib/qwen_native.so lib/libqwen_mmap_guard.so bin/qwen-widget-bin\n",
    "!file lib/qwen_native.so\n",
    "!file bin/qwen-widget-bin"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 🎁 Paso 6: Generación de Paquetes de Release (.deb y .tar.gz)\n",
    "Construimos los instaladores finales y calculamos los checksums SHA256."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "%cd {WORKSPACE_DIR}\n",
    "!chmod +x scripts/build_packages.sh\n",
    "!./scripts/build_packages.sh\n",
    "\n",
    "%cd {WORKSPACE_DIR}/dist\n",
    "!sha256sum *.deb *.tar.gz > SHA256SUMS.txt\n",
    "\n",
    "print(\"\\n\" + \"=\"*60)\n",
    "print(\" 🎉 RELEASES COMPILADOS EXITOSAMENTE:\")\n",
    "print(\"=\"*60)\n",
    "!ls -lh {WORKSPACE_DIR}/dist\n",
    "print(\"\\nChecksums SHA256:\")\n",
    "!cat {WORKSPACE_DIR}/dist/SHA256SUMS.txt"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 🤖 Paso 7 (Opcional): Descargar Modelos GGUF Livianos\n",
    "Si activaste `DOWNLOAD_MODELS` o deseas descargar los modelos oficiales de inferencia ultrarrápida:"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "%cd {WORKSPACE_DIR}\n",
    "import os\n",
    "\n",
    "if DOWNLOAD_MODELS:\n",
    "    os.makedirs(\"models\", exist_ok=True)\n",
    "    print(\"Descargando Qwen2.5-0.5B-Instruct Q4_K_M (corrección gramatical rápida < 380 MB)...\")\n",
    "    !curl -L -C - \"https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf\" -o models/es-grammar.gguf\n",
    "    print(\"Descargando Qwen3-0.6B Q4_K_M (asistente de chat)... \")\n",
    "    !curl -L -C - \"https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf\" -o models/qwen3.0-0.8b.gguf\n",
    "    !ls -lh models/\n",
    "else:\n",
    "    print(\"Descarga de modelos omitida (los modelos se descargan automáticamente en el primer inicio de la app o bajo demanda).\")"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 💾 Paso 8: Exportar y Descargar los Paquetes Compilados\n",
    "Elige la opción que prefieras para guardar tus archivos de release."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "#@title 📥 Opción A: Descarga Directa al Navegador { run: \"auto\" }\n",
    "from google.colab import files\n",
    "import glob\n",
    "\n",
    "dist_files = glob.glob(f\"{WORKSPACE_DIR}/dist/*\")\n",
    "print(f\"Se encontraron {len(dist_files)} archivos en dist/:\")\n",
    "for f in dist_files:\n",
    "    print(\" - \", os.path.basename(f))\n",
    "\n",
    "DESCARGAR_AHORA = False #@param {type:\"boolean\"}\n",
    "if DESCARGAR_AHORA:\n",
    "    for file_path in dist_files:\n",
    "        print(f\"Iniciando descarga: {file_path}\")\n",
    "        files.download(file_path)"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "#@title ☁️ Opción B: Copiar a Google Drive { run: \"auto\" }\n",
    "GUARDAR_EN_DRIVE = False #@param {type:\"boolean\"}\n",
    "DRIVE_SUBFOLDER = \"QwenWidget_Releases\" #@param {type:\"string\"}\n",
    "\n",
    "if GUARDAR_EN_DRIVE:\n",
    "    from google.colab import drive\n",
    "    drive.mount('/content/drive')\n",
    "    target_dir = f\"/content/drive/MyDrive/{DRIVE_SUBFOLDER}\"\n",
    "    os.makedirs(target_dir, exist_ok=True)\n",
    "    !cp -rv {WORKSPACE_DIR}/dist/* \"{target_dir}/\"\n",
    "    print(f\"\\n✓ Artefactos guardados exitosamente en Google Drive: {target_dir}\")\n",
    "    !ls -lh \"{target_dir}\""
   ]
  },
  {
   "cell_type": "code",
   "execution_count": None,
   "metadata": {},
   "outputs": [],
   "source": [
    "#@title 🚀 Opción C: Publicar en GitHub Releases automáticamente { run: \"auto\" }\n",
    "import urllib.request, json, os, glob\n",
    "\n",
    "PUBLICAR_GITHUB = False #@param {type:\"boolean\"}\n",
    "GITHUB_TOKEN = \"\" #@param {type:\"string\"}\n",
    "GITHUB_REPO = \"openclaw/qwen-widget\" #@param {type:\"string\"}\n",
    "RELEASE_TAG = \"v2.0.0\" #@param {type:\"string\"}\n",
    "RELEASE_TITLE = \"Qwen-Widget v2.0 Release\" #@param {type:\"string\"}\n",
    "\n",
    "if PUBLICAR_GITHUB and GITHUB_TOKEN:\n",
    "    headers = {\n",
    "        \"Authorization\": f\"token {GITHUB_TOKEN}\",\n",
    "        \"Accept\": \"application/vnd.github.v3+json\"\n",
    "    }\n",
    "    # 1. Crear o buscar release\n",
    "    rel_url = f\"https://api.github.com/repos/{GITHUB_REPO}/releases\"\n",
    "    payload = {\n",
    "        \"tag_name\": RELEASE_TAG,\n",
    "        \"name\": RELEASE_TITLE,\n",
    "        \"body\": \"Compilado y empaquetado automáticamente mediante Google Colab.\",\n",
    "        \"draft\": False,\n",
    "        \"prerelease\": False\n",
    "    }\n",
    "    req = urllib.request.Request(rel_url, data=json.dumps(payload).encode(), headers=headers, method=\"POST\")\n",
    "    try:\n",
    "        with urllib.request.urlopen(req) as resp:\n",
    "            release_data = json.loads(resp.read().decode())\n",
    "            upload_url_template = release_data.get(\"upload_url\", \"\").split(\"{\")[0]\n",
    "            print(f\"Release creado: {release_data.get('html_url')}\")\n",
    "    except Exception as e:\n",
    "        print(f\"Nota al crear release (puede que ya exista): {e}\")\n",
    "        get_req = urllib.request.Request(f\"{rel_url}/tags/{RELEASE_TAG}\", headers=headers)\n",
    "        with urllib.request.urlopen(get_req) as resp:\n",
    "            release_data = json.loads(resp.read().decode())\n",
    "            upload_url_template = release_data.get(\"upload_url\", \"\").split(\"{\")[0]\n",
    "    \n",
    "    # 2. Subir activos a release\n",
    "    for asset_file in glob.glob(f\"{WORKSPACE_DIR}/dist/*\"):\n",
    "        fname = os.path.basename(asset_file)\n",
    "        print(f\"Subiendo activo: {fname}...\")\n",
    "        upload_url = f\"{upload_url_template}?name={fname}\"\n",
    "        with open(asset_file, \"rb\") as af:\n",
    "            fdata = af.read()\n",
    "        up_headers = headers.copy()\n",
    "        up_headers[\"Content-Type\"] = \"application/octet-stream\"\n",
    "        up_req = urllib.request.Request(upload_url, data=fdata, headers=up_headers, method=\"POST\")\n",
    "        try:\n",
    "            with urllib.request.urlopen(up_req) as up_resp:\n",
    "                print(f\"  ✓ Subido {fname}\")\n",
    "        except Exception as err:\n",
    "            print(f\"  Advertencia al subir {fname}: {err}\")\n",
    "    print(\"\\n✓ Proceso de publicación en GitHub finalizado.\")\n",
    "elif PUBLICAR_GITHUB and not GITHUB_TOKEN:\n",
    "    print(\"Por favor ingresa un GITHUB_TOKEN válido con permisos 'repo' para publicar en GitHub.\")"
   ]
  }
 ],
 "metadata": {
  "accelerator": "GPU",
  "colab": {
   "provenance": [],
   "toc_visible": True
  },
  "kernelspec": {
   "display_name": "Python 3",
   "name": "python3"
  },
  "language_info": {
   "name": "python"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 0
}

with open("/home/alex/Documentos/widget [Github]/colab_build_release.ipynb", "w", encoding="utf-8") as f:
    json.dump(notebook, f, indent=1, ensure_ascii=False)

print("Notebook generado exitosamente en colab_build_release.ipynb")
