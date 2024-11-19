#!/bin/bash

# Informa el inicio del proceso
echo "Iniciando el proceso de renombrado de imágenes en el directorio actual..."

# Genera un prefijo aleatorio basado en el timestamp actual para evitar conflictos
prefix=$(date +%s)

# Itera sobre cada archivo PNG en el directorio actual
for file in ./*.png; do
  # Verifica que el archivo exista (en caso de que no haya archivos PNG)
  [ -e "$file" ] || { echo "No se encontraron archivos PNG para renombrar."; exit 0; }

  # Extrae el nombre base del archivo (sin ruta)
  base_name=$(basename "$file")

  # Genera un nombre de archivo "cifrado" utilizando SHA1
  # Combina el nombre del archivo, un número aleatorio y el prefijo para mayor unicidad
  new_name="$(echo "$base_name $RANDOM $prefix" | sha1sum | cut -d' ' -f1).png"

  # Renombra el archivo asegurándose de que el nuevo nombre esté en el mismo directorio
  mv -- "$file" "./$new_name"

  # Informa al usuario sobre el cambio
  echo "Archivo '$base_name' renombrado a '$new_name'"
done

echo "Renombrado de imágenes completado."

