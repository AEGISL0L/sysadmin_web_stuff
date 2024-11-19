#!/bin/bash

# ===========================
# Configuración Inicial
# ===========================

set -euo pipefail
IFS=$'\n\t'

# Directorio donde se ejecuta el script
SCRIPT_DIR="$(pwd)"

# Timestamp para directorios únicos
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

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
REQUIRED_DEPENDENCIES=(pngquant optipng parallel bc pv zopflipng)
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
    shopt -s nullglob
    PNG_FILES=("$SCRIPT_DIR"/*.png)
    if [ "${#PNG_FILES[@]}" -eq 0 ]; then
        show_progress "No se encontraron archivos PNG en ${SCRIPT_DIR}."
        exit 1
    fi
    show_progress "Encontrados ${#PNG_FILES[@]} archivos PNG para procesar."
}

# Función para realizar la copia de seguridad de los archivos originales
backup_original_files() {
    show_progress "Iniciando copia de seguridad de archivos originales..."
    # Usar 'command cp' para evitar aliases como 'cp -i'
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

    # Reducción de colores con pngquant
    pngquant --quality=65-80 --speed=3 --force --strip --output "${OUTPUT_DIR}/$basename_file" "${OUTPUT_DIR}/$basename_file" || {
        show_progress "Error al optimizar $basename_file con pngquant."
        exit 1
    }

    # Optimización con optipng
    optipng -o7 -strip all "${OUTPUT_DIR}/$basename_file" || {
        show_progress "Error al optimizar $basename_file con optipng."
        exit 1
    }

    # Optimización adicional con zopflipng para una mejor compresión
    zopflipng -m "${OUTPUT_DIR}/$basename_file" "${OUTPUT_DIR}/$basename_file" || {
        show_progress "Error al optimizar $basename_file con zopflipng."
        exit 1
    }

    final_size=$(stat -c%s "${OUTPUT_DIR}/$basename_file")
    duration=$(( $(date +%s) - start_time ))
    savings=$(( original_size - final_size ))
    ratio=$(echo "scale=2; ($savings/$original_size)*100" | bc)

    show_progress "Optimizado $basename_file en ${duration}s - Ahorro: ${ratio}%"
    echo "$(date +%Y-%m-%d_%H:%M:%S),$basename_file,$original_size,$final_size,$ratio,PNG,$duration,0" >> "$STATS_FILE"
}

# Función para convertir archivos PNG a WebP (solo si cwebp está disponible)
convert_to_webp() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")

    local start_time
    start_time=$(date +%s)

    show_progress "Convirtiendo a WebP: $basename_file"

    local original_size final_size ratio output
    original_size=$(stat -c%s "$file")

    # Crear archivo WebP
    output="${WEBP_DIR}/${basename_file%.png}.webp"
    cwebp -q 75 -mt -sharp_yuv -af -pre 4 -alpha_filter best -alpha_method 1 "$file" -o "$output" &>/dev/null

    final_size=$(stat -c%s "$output")
    duration=$(( $(date +%s) - start_time ))
    ratio=$(echo "scale=2; (($original_size - $final_size)/$original_size)*100" | bc)

    show_progress "Convertido $basename_file a WebP en ${duration}s - Ahorro: ${ratio}%"
    echo "$(date +%Y-%m-%d_%H:%M:%S),$basename_file,$original_size,$final_size,$ratio,WebP,$duration,0" >> "$STATS_FILE"
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
                printf "━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                printf "📁 Total de archivos: %d\n", count
                printf "⏱️ Tiempo de procesamiento: %.2f minutos\n\n", total_duration / 60
                printf "📈 RESULTADOS DE COMPRESIÓN\n"
                printf "━━━━━━━━━━━━━━━━━━━━━━━━━\n"
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
    export BACKUP_DIR OUTPUT_DIR STATS_FILE PROGRESS_FILE

    parallel --progress --eta -j "$PARALLEL_JOBS" optimize_png ::: "${PNG_FILES[@]}"

    show_progress "Optimización de PNG completada exitosamente."

    # Conversión a WebP en paralelo, solo si cwebp está disponible
    if [ "$WEBP_AVAILABLE" = true ]; then
        show_progress "Iniciando conversión a WebP con $PARALLEL_JOBS trabajos en paralelo..."
        export -f convert_to_webp
        export WEBP_DIR PROGRESS_FILE
        # Asegurarse de que solo se pasen archivos existentes
        WEBP_FILES=("$OUTPUT_DIR"/*.png)
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
    echo "🗑 Log completo: $LOGFILE"
}

# Ejecutar la función principal
main

