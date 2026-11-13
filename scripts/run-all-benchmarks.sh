#!/bin/bash
# run-all-benchmarks.sh - Run all benchmark configurations sequentially
#
# This script runs all five benchmark sizes in sequence:
# - 128MB files (1.28GB total data)
# - 256MB files (2.56GB total data)
# - 512MB files (5.12GB total data)
# - 1GB files (10.24GB total data)
# - 10GB files (100GB total data)
#
# Prerequisites:
#   1. AWS SSO logged in
#   2. ZSTORE_ENV environment variable pointing to zstore .env file
#      OR ensure scripts/.env exists and can be sourced
#   3. ZSTORE_BIN environment variable pointing to zstore binary
#      OR ensure scripts/.env exists and can be sourced
#   4. z-bench project directory with activated venv
#   5. AWS_REGION set in zstore .env file
#
# Usage:
#   source .venv/bin/activate
#   # Option 1: Run directly (auto-sources scripts/.env if needed)
#   ./scripts/run-all-benchmarks.sh
#   # Option 2: Pre-configure environment
#   source scripts/.env && ./scripts/run-all-benchmarks.sh

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Benchmark scripts in order of increasing file size
SCRIPTS=(
    "128mb-all-configs.sh"
    "256mb-all-configs.sh"
    "512mb-all-configs.sh"
    "1024mb-all-configs.sh"
    "10GB-all-configs.sh"
)

# Track overall results
declare -a SUCCESSFUL_SCRIPTS=()
declare -a FAILED_SCRIPTS=()
OVERALL_START_TIME=0

# Global path variables (portable resolution)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/results"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "${BLUE}[SECTION]${NC} $1"
}

# Validate environment
validate_environment() {
    log_section "Validating environment..."

    # Auto-source scripts/.env if ZSTORE_ENV is not already set
    if [ -z "$ZSTORE_ENV" ] || [ -z "$ZSTORE_BIN" ]; then
        if [ -f "$SCRIPT_DIR/.env" ]; then
            log_info "Sourcing scripts/.env to get environment variables..."
            source "$SCRIPT_DIR/.env"
        else
            log_warn "scripts/.env not found at $SCRIPT_DIR/.env"
        fi
    fi

    # Check ZSTORE_ENV
    if [ -z "$ZSTORE_ENV" ] || [ ! -f "$ZSTORE_ENV" ]; then
        log_error "ZSTORE_ENV not set or file not found."
        echo "Please set: export ZSTORE_ENV=/path/to/your/zstore/.env"
        exit 1
    fi
    log_info "ZSTORE_ENV: $ZSTORE_ENV"

    # Source the zstore environment to get AWS_REGION and other vars
    log_info "Sourcing zstore environment from $ZSTORE_ENV..."
    source "$ZSTORE_ENV"

    # Check AWS_REGION (now available after sourcing ZSTORE_ENV)
    if [ -z "$AWS_REGION" ]; then
        log_error "AWS_REGION not set. Please ensure it's in your zstore .env file"
        exit 1
    fi
    log_info "AWS_REGION: $AWS_REGION"

    # Check ZBENCH_PATH
    ZBENCH_PATH="$SCRIPT_DIR/../.venv/bin/z-bench"
    
    if [ ! -x "$ZBENCH_PATH" ]; then
        log_error "z-bench not found at $ZBENCH_PATH"
        exit 1
    fi
    log_info "z-bench found at: $ZBENCH_PATH"

    # Check ZSTORE_BIN
    if [ -z "$ZSTORE_BIN" ]; then
        log_error "ZSTORE_BIN not set. Please ensure it's in scripts/.env or zstore .env"
        exit 1
    fi
    log_info "ZSTORE_BIN: $ZSTORE_BIN"

    log_info "Environment validation complete"
}

# Run a single benchmark script
run_benchmark_script() {
    local script="$1"
    local script_path="$SCRIPT_DIR/$script"
    local start_time
    local end_time
    local duration

    if [ ! -x "$script_path" ]; then
        log_error "Script not found or not executable: $script_path"
        FAILED_SCRIPTS+=("$script (not found)")
        return 1
    fi

    log_section "Starting: $script"
    log_info "Full path: $script_path"

    start_time=$(date +%s)
    
    if "$script_path"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log_info "Completed $script in ${duration}s"
        SUCCESSFUL_SCRIPTS+=("$script (${duration}s)")
        return 0
    else
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log_error "Failed $script after ${duration}s"
        FAILED_SCRIPTS+=("$script (${duration}s)")
        return 1
    fi
}

# Print summary table
print_summary() {
    local end_time
    local total_duration

    end_time=$(date +%s)
    total_duration=$((end_time - OVERALL_START_TIME))

    echo ""
    echo "========================================="
    echo "         BENCHMARK RUN SUMMARY          "
    echo "========================================="
    echo ""
    echo "File Sizes Tested: ${#SCRIPTS[@]}"
    echo "Successful: ${#SUCCESSFUL_SCRIPTS[@]}"
    echo "Failed:     ${#FAILED_SCRIPTS[@]}"
    echo "Total Time: ${total_duration}s"
    echo ""

    if [ ${#SUCCESSFUL_SCRIPTS[@]} -gt 0 ]; then
        echo "Successful Runs:"
        for s in "${SUCCESSFUL_SCRIPTS[@]}"; do
            echo -e "  ${GREEN}✓${NC} $s"
        done
        echo ""
    fi

    if [ ${#FAILED_SCRIPTS[@]} -gt 0 ]; then
        echo -e "${RED}Failed Runs:${NC}"
        for f in "${FAILED_SCRIPTS[@]}"; do
            echo -e "  ${RED}✗${NC} $f"
        done
        echo ""
        echo "Check the individual script output files for details."
        echo "Results are in: $SCRIPT_DIR/results/"
    fi

    echo "========================================="
}

# Main execution
main() {
    OVERALL_START_TIME=$(date +%s)

    echo ""
    echo "========================================="
    echo "  Z-Bench Sequential Benchmark Runner   "
    echo "========================================="
    echo ""
    log_info "Starting sequential benchmark execution"
    log_info "Number of scripts: ${#SCRIPTS[@]}"
    echo ""

    # Validate environment once
    validate_environment
    echo ""

    # Ensure we're in the z-bench directory
    cd "$SCRIPT_DIR/.." || {
        log_error "Failed to change to project root. Script_DIR: $SCRIPT_DIR"
        exit 1
    }

    # Ensure results directory exists
    mkdir -p "$SCRIPT_DIR/results"

    # Activate venv if not already active
    if [ -z "$VIRTUAL_ENV" ]; then
        log_info "Activating virtual environment..."
        source .venv/bin/activate
    fi

    # Run each script in sequence
    for script in "${SCRIPTS[@]}"; do
        run_benchmark_script "$script"
        # Continue even if one fails
    done

    # Print summary
    print_summary

    # Exit with error if any failed
    if [ ${#FAILED_SCRIPTS[@]} -gt 0 ]; then
        exit 1
    fi
}

# Run main
main "$@"