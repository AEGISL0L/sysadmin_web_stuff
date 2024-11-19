#!/bin/bash

# Verificar que los programas necesarios estén instalados
if ! command -v pngquant &>/dev/null; then
    echo "pngquant no está instalado. Instalando..."
    sudo zypper install -y pngquant
fi

if ! command -v optipng &>/dev/null; then
    echo "optipng no está instalado. Instalando..."
    sudo zypper install -y optipng
fi

if ! command -v parallel &>/dev/null; then
    echo "GNU parallel no está instalado. Instalando..."
    sudo zypper install -y parallel
fi

# Verificar si hay archivos PNG en el directorio actual
shopt -s nullglob
png_files=(*.png)
if [ ${#png_files[@]} -eq 0 ]; then
    echo "No se encontraron archivos PNG en el directorio."
    exit 1
fi

# Procesar y optimizar cada archivo PNG en paralelo
echo "Optimización y eliminación de metadatos en curso..."

parallel --will-cite --bar "
    # Reducir la paleta de colores con pngquant
    pngquant --quality=65-80 --ext .png --force '{}'

    # Optimizar la compresión y eliminar metadatos con optipng
    optipng -o7 -strip all '{}'

    echo 'Archivo optimizado y metadatos eliminados: {}'
" ::: "${png_files[@]}"

echo "Optimización completa y metadatos eliminados para todos los archivos PNG."