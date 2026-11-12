#!/bin/bash
# 256mb-all-configs.sh - Test all chunk configurations on 256 MB files
#
# This script runs 18 benchmark configurations testing:
# - Chunking methods: none, fixed, equal-split
# - Chunk sizes: 10MB, 25MB, 50MB, 100MB
# - Memory limits: none, 500MB
#
# Prerequisites:
#   1. AWS SSO logged in
#   2. Set ZSTORE_ENV environment variable pointing to your zstore .env file
#      Example: export ZSTORE_ENV=/path/to/your/zstore/.env
#   3. Set ZSTORE_BIN environment variable pointing to your zstore binary
#      Example: export ZSTORE_BIN=/path/to/your/zstore
#   4. z-bench project directory with activated venv
#
# Usage:
#   export ZSTORE_ENV=/path/to/your/zstore/.env
#   export ZSTORE_BIN=/path/to/your/zstore
#   cd /path/to/z-bench
#   source .venv/bin/activate
#   ./scripts/256mb-all-configs.sh

set -o pipefail

# Source environment configuration if available
if [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# Environment Setup (from ZSTORE_ENV variable)
# ============================================
if [ -n "$ZSTORE_ENV" ] && [ -f "$ZSTORE_ENV" ]; then
    log_info "Sourcing zstore environment from $ZSTORE_ENV"
    source "$ZSTORE_ENV"
else
    echo "Error: ZSTORE_ENV not set or file not found."
    echo "Please set: export ZSTORE_ENV=/path/to/your/zstore/.env"
    echo "Example: source /path/to/your/zstore/.env && aws sso login"
    exit 1
fi

# Verify AWS_REGION is set
if [ -z "$AWS_REGION" ]; then
    echo "Error: AWS_REGION not set. Please ensure it's in your zstore .env file"
    exit 1
fi

# Configuration
FILE_SIZE="256MB"
NUM_FILES=10
TOTAL_SIZE="2560MB"
WAIT_SECONDS=10
OUTPUT_DIR="./scripts/results"

# ZSTORE_BIN can be overridden via environment variable
ZSTORE_BIN="${ZSTORE_BIN:-/usr/local/bin/zstore}"

# BUCKET can be overridden via TEST_BUCKET from .env
BUCKET="${TEST_BUCKET:-zs://bayani-zstore-aws-bucket/}"

DOWNLOADS_DIR="${DOWNLOADS_DIR:-./downloads/}"
TESTFILES_DIR="./testfiles/${FILE_SIZE}"

# Resolve full path to z-bench (works with sudo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZBENCH_PATH="$SCRIPT_DIR/../.venv/bin/z-bench"

if [ ! -x "$ZBENCH_PATH" ]; then
    echo "Error: z-bench not found at $ZBENCH_PATH"
    echo "Please run from z-bench project directory"
    exit 1
fi

# Track failed configurations
FAILED_CONFIGS=()

run_config() {
    local config_num=$1
    local chunking=$2
    local chunk_size=$3
    local mem_limit=$4
    local out_file=$5
    local put_cmd=$6
    local get_cmd=$7
    local del_cmd=$8

    log_info "Starting Config $config_num: chunking=$chunking, chunk_size=${chunk_size:-default}, memory=${mem_limit:-none}"

    local cmd="$ZBENCH_PATH --ALL \
  --input-dir $TESTFILES_DIR \
  --put-cmd \"$put_cmd\" \
  --get-cmd \"$get_cmd\" \
  --del-cmd \"$del_cmd\" \
  --out $out_file \
  --warmup 0 \
  --wait $WAIT_SECONDS"

    log_info "Running: $cmd"

    if eval "$cmd" > "$OUTPUT_DIR/config-${config_num}-log.txt" 2>&1; then
        log_info "Config $config_num completed successfully"
    else
        log_error "Config $config_num failed. See $OUTPUT_DIR/config-${config_num}-log.txt"
        FAILED_CONFIGS+=($config_num)
    fi
}

# Main execution
main() {
    log_info "Starting 256MB All Configurations Benchmark"
    log_info "Files: $NUM_FILES × $FILE_SIZE = $TOTAL_SIZE"
    log_info "Total configurations: 18"

    # Step 1: Generate test files if they don't exist
    if [ ! -d "$TESTFILES_DIR" ] || [ -z "$(ls -A $TESTFILES_DIR/*.bin 2>/dev/null)" ]; then
        log_info "Generating test files..."
        "$ZBENCH_PATH" generate --output-dir "$TESTFILES_DIR" --file-size "$FILE_SIZE" --total-size "$TOTAL_SIZE"
        if [ $? -ne 0 ]; then
            log_error "Failed to generate test files"
            exit 1
        fi
        log_info "Test files generated successfully"
    else
        log_info "Using existing test files from $TESTFILES_DIR"
    fi

    # Ensure download directory exists
    mkdir -p "$DOWNLOADS_DIR"

    # Store current directory
    local script_dir=$(pwd)
    cd /home/bayani/Documents/Programming/z-bench

    # Activate venv if not already active
    if [ -z "$VIRTUAL_ENV" ]; then
        source .venv/bin/activate
    fi

    # ============================================
    # Config 1: none, default, no memory limit
    # ============================================
    run_config 1 "none" "default" "none" \
        "$OUTPUT_DIR/config-01-none-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 2: none, default, 500MB memory limit
    # ============================================
    run_config 2 "none" "default" "500MB" \
        "$OUTPUT_DIR/config-02-none-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 3: fixed, 10MB, no limit
    # ============================================
    run_config 3 "fixed" "10MB" "none" \
        "$OUTPUT_DIR/config-03-fixed-10mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=10MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 4: fixed, 10MB, 500MB
    # ============================================
    run_config 4 "fixed" "10MB" "500MB" \
        "$OUTPUT_DIR/config-04-fixed-10mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=10MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 5: fixed, 25MB, no limit
    # ============================================
    run_config 5 "fixed" "25MB" "none" \
        "$OUTPUT_DIR/config-05-fixed-25mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=25MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 6: fixed, 25MB, 500MB
    # ============================================
    run_config 6 "fixed" "25MB" "500MB" \
        "$OUTPUT_DIR/config-06-fixed-25mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=25MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 7: fixed, 50MB, no limit
    # ============================================
    run_config 7 "fixed" "50MB" "none" \
        "$OUTPUT_DIR/config-07-fixed-50mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=50MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 8: fixed, 50MB, 500MB
    # ============================================
    run_config 8 "fixed" "50MB" "500MB" \
        "$OUTPUT_DIR/config-08-fixed-50mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=50MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 9: fixed, 100MB, no limit
    # ============================================
    run_config 9 "fixed" "100MB" "none" \
        "$OUTPUT_DIR/config-09-fixed-100mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=100MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 10: fixed, 100MB, 500MB
    # ============================================
    run_config 10 "fixed" "100MB" "500MB" \
        "$OUTPUT_DIR/config-10-fixed-100mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=fixed --chunk-size=100MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 11: equal-split, 10MB, no limit
    # ============================================
    run_config 11 "equal-split" "10MB" "none" \
        "$OUTPUT_DIR/config-11-equal-split-10mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=10MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 12: equal-split, 10MB, 500MB
    # ============================================
    run_config 12 "equal-split" "10MB" "500MB" \
        "$OUTPUT_DIR/config-12-equal-split-10mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=10MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 13: equal-split, 25MB, no limit
    # ============================================
    run_config 13 "equal-split" "25MB" "none" \
        "$OUTPUT_DIR/config-13-equal-split-25mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=25MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 14: equal-split, 25MB, 500MB
    # ============================================
    run_config 14 "equal-split" "25MB" "500MB" \
        "$OUTPUT_DIR/config-14-equal-split-25mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=25MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 15: equal-split, 50MB, no limit
    # ============================================
    run_config 15 "equal-split" "50MB" "none" \
        "$OUTPUT_DIR/config-15-equal-split-50mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=50MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 16: equal-split, 50MB, 500MB
    # ============================================
    run_config 16 "equal-split" "50MB" "500MB" \
        "$OUTPUT_DIR/config-16-equal-split-50mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=50MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 17: equal-split, 100MB, no limit
    # ============================================
    run_config 17 "equal-split" "100MB" "none" \
        "$OUTPUT_DIR/config-17-equal-split-100mb-256mb-no-mem.csv" \
        "$ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=100MB" \
        "$ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "$ZSTORE_BIN delete $BUCKET{filename}"

    # ============================================
    # Config 18: equal-split, 100MB, 500MB
    # ============================================
    run_config 18 "equal-split" "100MB" "500MB" \
        "$OUTPUT_DIR/config-18-equal-split-100mb-256mb-500mb.csv" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN upload {file} $BUCKET --chunk-method=equal-split --chunk-size=100MB" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN download $BUCKET{filename} $DOWNLOADS_DIR" \
        "systemd-run --scope -p MemoryLimit=500M $ZSTORE_BIN delete $BUCKET{filename}"

    # Summary
    cd "$script_dir"
    log_info "========================================="
    log_info "Benchmark Run Complete"
    log_info "Results directory: $OUTPUT_DIR"
    
    if [ ${#FAILED_CONFIGS[@]} -eq 0 ]; then
        log_info "All 18 configurations completed successfully!"
    else
        log_warn "Failed configurations: ${FAILED_CONFIGS[*]}"
        log_warn "Check log files in $OUTPUT_DIR for details"
    fi
}

# Run main
main "$@"
