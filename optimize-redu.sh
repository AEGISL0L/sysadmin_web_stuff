#!/bin/bash

# ===========================
# Configuración Inicial
# ===========================

set -euo pipefail
IFS=$'\n\t'

# Directorio donde se ejecuta el script
SCRIPT_DIR="$(pwd)"

# Timestamp para directorios únicos con mayor precisión
TIMESTAMP=$(date +%Y%m%d_%H%M%S_%N)

# Definición de directorios individuales
BACKUP_DIR="${SCRIPT_DIR}/backup_original_images_${TIMESTAMP}"
OUTPUT_DIR="${SCRIPT_DIR}/optimized_images_${TIMESTAMP}"
WEBP_DIR="${SCRIPT_DIR}/webp_images_${TIMESTAMP}"
LOGS_DIR="${SCRIPT_DIR}/progress_logs"

# Archivos de log y estadísticas
LOGFILE="${SCRIPT_DIR}/conversion_log.txt"
STATS_FILE="${SCRIPT_DIR}/optimization_stats.csv"
PROGRESS_FILE="${LOGS_DIR}/progress.txt"

# Definición de dependencias
REQUIRED_DEPENDENCIES=(pngquant oxipng parallel bc pv zopflipng optipng)
OPTIONAL_DEPENDENCIES=(cwebp)

# Parámetros de procesamiento
PARALLEL_JOBS=$(nproc)  # Utiliza todos los núcleos disponibles

# ===========================
# Funciones Utilitarias
# ===========================

# Función para mostrar y registrar el progreso
show_progress() {
    local message="$1"
    echo "[$(date +%H:%M:%S)] $message" | tee -a "$PROGRESS_FILE"
}

# Función para verificar la presencia de dependencias
check_dependencies() {
    local missing=()
    for pkg in "${REQUIRED_DEPENDENCIES[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -ne 0 ]; then
        echo "❌ Las siguientes dependencias requeridas no están instaladas: ${missing[*]}"
        echo "Por favor, instala las dependencias antes de ejecutar el script."
        exit 1
    else
        show_progress "Todas las dependencias requeridas están instaladas."
    fi

    # Verificar dependencias opcionales
    local optional_missing=()
    for pkg in "${OPTIONAL_DEPENDENCIES[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            optional_missing+=("$pkg")
        fi
    done

    if [ "${#optional_missing[@]}" -eq 0 ]; then
        WEBP_AVAILABLE=true
        show_progress "Dependencias opcionales están instaladas. La conversión a WebP estará habilitada."
    else
        WEBP_AVAILABLE=false
        show_progress "Dependencias opcionales no están instaladas: ${optional_missing[*]}"
        show_progress "La conversión a WebP se omitirá."
    fi
}

# Función para inicializar directorios y archivos de log
initialize_environment() {
    # Habilitar extended globbing y manejo adecuado de archivos
    shopt -s extglob nullglob

    # Crear directorios necesarios
    mkdir -p "$BACKUP_DIR" "$OUTPUT_DIR" "$WEBP_DIR" "$LOGS_DIR"

    # Crear el archivo de progreso vacío
    touch "$PROGRESS_FILE"

    # Inicializar archivos de log y estadísticas
    echo "timestamp,filename,original_size,final_size,compression_ratio,format,duration,memory_usage" > "$STATS_FILE"
    echo "=== Iniciando proceso: $(date) ===" > "$LOGFILE"
    echo "=== Iniciando proceso: $(date) ===" > "$PROGRESS_FILE"
}

# Función para verificar la existencia de archivos PNG
check_png_files() {
    # Utilizar 'find' para recopilar archivos PNG que no comienzan con 'optimized_'
    mapfile -t PNG_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname "*.png" ! -iname "optimized_*")

    if [ "${#PNG_FILES[@]}" -eq 0 ]; then
        show_progress "No se encontraron archivos PNG en ${SCRIPT_DIR}."
        exit 1
    fi
    show_progress "Encontrados ${#PNG_FILES[@]} archivos PNG para procesar."
}

# Función para realizar la copia de seguridad de los archivos originales
backup_original_files() {
    show_progress "Iniciando copia de seguridad de archivos originales..."
    # Usar 'command cp' para evitar aliases como 'cp -i', y asegurar la correcta copia
    command cp -vf "${PNG_FILES[@]}" "$BACKUP_DIR/" || {
        show_progress "Error al copiar archivos a ${BACKUP_DIR}."
        exit 1
    }
    show_progress "Copia de seguridad completada."
}

# Función para optimizar archivos PNG
optimize_png() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")

    local start_time
    start_time=$(date +%s)

    show_progress "Procesando PNG: $basename_file"

    # Copiar el archivo al directorio de salida
    command cp -vf "$file" "$OUTPUT_DIR/" || {
        show_progress "Error al copiar $basename_file a ${OUTPUT_DIR}."
        exit 1
    }

    local original_size final_size duration savings ratio

    original_size=$(stat -c%s "$file")

    # Reducir la paleta de colores para disminuir la calidad y el tamaño
    pngquant --quality=10-50 --speed=1 --force --strip --output "${OUTPUT_DIR}/$basename_file" "${OUTPUT_DIR}/$basename_file" || {
        show_progress "Error al optimizar $basename_file con pngquant."
        exit 1
    }

    # Optimización con oxipng
    oxipng -o max --strip safe "${OUTPUT_DIR}/$basename_file" || {
        show_progress "Error al optimizar $basename_file con oxipng."
        exit 1
    }

    # Optimización adicional con zopflipng para una mejor compresión
    zopflipng -m "${OUTPUT_DIR}/$basename_file" "${OUTPUT_DIR}/$basename_file" || {
        show_progress "Error al optimizar $basename_file con zopflipng."
        exit 1
    }

    # Añadir optimización con optipng si está disponible
    if [ "$OPTIPNG_AVAILABLE" = true ]; then
        optipng -o7 -strip all "${OUTPUT_DIR}/$basename_file" || {
            show_progress "Error al optimizar $basename_file con optipng."
            exit 1
        }
    fi

    final_size=$(stat -c%s "${OUTPUT_DIR}/$basename_file")
    duration=$(( $(date +%s) - start_time ))
    savings=$(( original_size - final_size ))
    ratio=$(echo "scale=2; ($savings/$original_size)*100" | bc)

    if [ "$final_size" -lt "$original_size" ]; then
        show_progress "Optimizado $basename_file en ${duration}s - Ahorro: ${ratio}%"
        echo "$(date +%Y-%m-%d_%H:%M:%S),$basename_file,$original_size,$final_size,$ratio,PNG,$duration,0" >> "$STATS_FILE"
    else
        show_progress "No se logró reducir el tamaño de $basename_file. Tamaño original: ${original_size} bytes, Tamaño optimizado: ${final_size} bytes."
        # Restaurar el archivo original si no hay ahorro
        command cp -vf "$BACKUP_DIR/$basename_file" "$OUTPUT_DIR/$basename_file"
        echo "$(date +%Y-%m-%d_%H:%M:%S),$basename_file,$original_size,$original_size,0,PNG,$duration,0" >> "$STATS_FILE"
    fi
}

# Función para convertir archivos PNG a WebP (solo si cwebp está disponible)
convert_to_webp() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")

    local start_time
    start_time=$(date +%s)

    show_progress "Convirtiendo a WebP: $basename_file"

    local original_size final_size ratio output best_size best_params
    original_size=$(stat -c%s "$file")
    best_size=$original_size
    best_params=""
    local best_file=""
    local -a generated_files=()

    # Pruebas de calidad para encontrar la mejor compresión
    for q in {10..60..5}; do  # Reducido el mínimo de calidad para mayor compresión
        for m in {4..6}; do
            local output_test="${WEBP_DIR}/${basename_file%.png}_q${q}_m${m}.webp"
            if cwebp -q "$q" -m "$m" -pass 6 -af -mt -f 80 -metadata none "$file" -o "$output_test" &>/dev/null; then
                if [ -f "$output_test" ]; then
                    current_size=$(stat -c%s "$output_test")
                    echo "Archivo $output_test creado con tamaño $current_size bytes." >> "$LOGFILE"
                    generated_files+=("$output_test")
                    if [ "$current_size" -lt "$best_size" ]; then
                        best_size=$current_size
                        best_params="q${q}_m${m}"
                        best_file="$output_test"
                    fi
                else
                    echo "Error creando $output_test para $file con calidad $q y método $m" >> "$LOGFILE"
                fi
            else
                echo "Error creando $output_test para $file con calidad $q y método $m" >> "$LOGFILE"
            fi
        done
    done

    echo "Best file for $file is $best_file with size $best_size bytes" >> "$LOGFILE"

    # Limpiar archivos temporales y renombrar el mejor archivo
    if [ -n "$best_file" ]; then
        for temp_file in "${generated_files[@]}"; do
            if [ "$temp_file" != "$best_file" ]; then
                rm -f "$temp_file"
            fi
        done
        mv -f "$best_file" "${file%.png}.webp" || {
            show_progress "Error al mover $best_file a ${file%.png}.webp."
            exit 1
        }
    fi

    final_size=$best_size
    duration=$(( $(date +%s) - start_time ))
    ratio=$(echo "scale=2; (($original_size - $final_size)/$original_size)*100" | bc)

    if [ "$final_size" -lt "$original_size" ]; then
        show_progress "Convertido $basename_file a WebP en ${duration}s - Ahorro: ${ratio}%"
        echo "$(date +%Y-%m-%d_%H:%M:%S),$basename_file,$original_size,$final_size,$ratio,WebP,$duration,0" >> "$STATS_FILE"
    else
        show_progress "No se logró reducir el tamaño de $basename_file al convertir a WebP. Tamaño original: ${original_size} bytes, Tamaño WebP: ${final_size} bytes."
        # Eliminar el WebP que no cumple el criterio de menor tamaño
        rm -f "${file%.png}.webp"
        echo "$(date +%Y-%m-%d_%H:%M:%S),$basename_file,$original_size,$original_size,0,WebP,$duration,0" >> "$STATS_FILE"
    fi
}

# Función para generar el reporte de estadísticas
generate_statistics() {
    show_progress "Generando análisis de rendimiento detallado..."

    awk -F',' '
        BEGIN {
            CONVMB=1048576
        }
        NR > 1 {
            total_orig += $3
            total_final += $4
            count++
            total_duration += $7
            if ($6 == "PNG") {
                png_savings += ($3 - $4)
                png_count++
                png_duration += $7
            }
            else if ($6 == "WebP") {
                webp_savings += ($3 - $4)
                webp_count++
                webp_duration += $7
            }
        }
        END {
            if (total_orig > 0) {
                savings = total_orig - total_final
                ratio = (savings / total_orig) * 100
                printf "\n📊 RESUMEN DEL PROCESAMIENTO\n"
                printf "━━━━━━━━━━━━━━━━━━━━\n"
                printf "📁 Total de archivos: %d\n", count
                printf "⏱️ Tiempo de procesamiento: %.2f minutos\n\n", total_duration / 60
                printf "📈 RESULTADOS DE COMPRESIÓN\n"
                printf "━━━━━━━━━━━━━━━━━━━━\n"
                printf "💾 Total ahorrado: %.2f MB (%.2f%%)\n", savings / CONVMB, ratio
                if (png_count > 0) {
                    printf "🔸 PNG optimizados: %d (%.2f MB)\n", png_count, png_savings / CONVMB
                    printf "⏳ Tiempo promedio por PNG: %.2f segundos\n", png_duration / png_count
                }
                if (webp_count > 0) {
                    printf "🔹 WebP convertidos: %d (%.2f MB)\n", webp_count, webp_savings / CONVMB
                    printf "⏳ Tiempo promedio por WebP: %.2f segundos\n", webp_duration / webp_count
                }
            } else {
                print "❌ No se procesaron archivos."
            }
        }' "$STATS_FILE" | tee -a "$LOGFILE"
}

# ===========================
# Ejecución Principal
# ===========================

main() {
    # Inicializar directorios y logs
    initialize_environment

    # Verificar la presencia de dependencias
    check_dependencies

    # Verificar existencia de archivos PNG
    check_png_files

    # Realizar copia de seguridad de los archivos originales
    backup_original_files

    # Optimización de PNG en paralelo
    show_progress "Iniciando optimización de PNG con $PARALLEL_JOBS trabajos en paralelo..."
    export -f show_progress
    export -f optimize_png
    export BACKUP_DIR OUTPUT_DIR STATS_FILE PROGRESS_FILE LOGFILE

    parallel --progress --eta -j "$PARALLEL_JOBS" optimize_png ::: "${PNG_FILES[@]}"

    show_progress "Optimización de PNG completada exitosamente."

    # Conversión a WebP en paralelo, solo si cwebp está disponible
    if [ "$WEBP_AVAILABLE" = true ]; then
        show_progress "Iniciando conversión a WebP con $PARALLEL_JOBS trabajos en paralelo..."
        export -f convert_to_webp
        export WEBP_DIR PROGRESS_FILE LOGFILE

        # Utilizar 'find' para recopilar archivos PNG en OUTPUT_DIR
        mapfile -t WEBP_FILES < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -iname "*.png")

        if [ "${#WEBP_FILES[@]}" -gt 0 ]; then
            parallel --progress --eta -j "$PARALLEL_JOBS" convert_to_webp ::: "${WEBP_FILES[@]}"
            show_progress "Conversión a WebP completada exitosamente."
        else
            show_progress "No hay archivos PNG en $OUTPUT_DIR para convertir a WebP."
        fi
    fi

    # Generar reporte de estadísticas
    generate_statistics

    # Mensaje final con ubicaciones de los archivos
    show_progress "Proceso completado exitosamente!"
    echo "📁 Archivos originales: $BACKUP_DIR"
    echo "📂 Archivos PNG optimizados: $OUTPUT_DIR"
    if [ "$WEBP_AVAILABLE" = true ]; then
        echo "🖼️ Archivos WebP: $WEBP_DIR"
    else
        echo "🖼️ Conversión a WebP omitida."
    fi
    echo "📊 Estadísticas: $STATS_FILE"
    echo "📄 Log de progreso: $PROGRESS_FILE"
    echo "📝 Log completo: $LOGFILE"
}

# Ejecutar la función principal
main

