#!/bin/bash

# TAS for VMs Parameter Management Scripts
# Handles hierarchical YAML parameter files for Concourse pipelines

set -euo pipefail

# Global variables
REPO_PATH=""
TEMP_DIR="/tmp/tas_param_$$"
SCRIPT_NAME=$(basename "$0")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Print usage information
usage() {
    cat << EOF
Usage: $SCRIPT_NAME <repo_path> <command> [options]

Commands:
    find-duplicates                    Find duplicate parameters across all files
    generate-foundation <datacenter> <foundation> [options]
                                      Generate complete foundation file

Options for generate-foundation:
    -e, --environment <env>           Environment type: lab, nonprod, prod (default: prod)
    -o, --output <file>              Output file path (default: stdout)

Examples:
    $SCRIPT_NAME /path/to/params find-duplicates
    $SCRIPT_NAME /path/to/params generate-foundation dc1 foundation1
    $SCRIPT_NAME /path/to/params generate-foundation dc1 foundation1 -e lab -o output.yml

EOF
}

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if required tools are available
check_dependencies() {
    local missing_tools=()
    
    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install yq: https://github.com/mikefarah/yq"
        exit 1
    fi
}

# Get all YAML files with their hierarchy information
get_all_yaml_files() {
    local repo_path="$1"
    local files_list="$TEMP_DIR/all_files.txt"
    
    mkdir -p "$TEMP_DIR"
    > "$files_list"
    
    # Top level files (level 0)
    for level_file in "global.yml" "global-lab.yml" "global-nonprod.yml" "global-prod.yml"; do
        if [[ -f "$repo_path/$level_file" ]]; then
            echo "0|global|$level_file|||$repo_path/$level_file" >> "$files_list"
        fi
    done
    
    # Datacenter level files (level 1) and foundation files (level 2)
    for dc_dir in "$repo_path"/*/; do
        if [[ -d "$dc_dir" ]]; then
            local datacenter=$(basename "$dc_dir")
            
            # Datacenter level files
            for dc_file in "datacenter.yml" "datacenter-lab.yml" "datacenter-nonprod.yml" "datacenter-prod.yml"; do
                if [[ -f "$dc_dir/$dc_file" ]]; then
                    echo "1|datacenter|$dc_file|$datacenter||$dc_dir$dc_file" >> "$files_list"
                fi
            done
            
            # Foundation level files
            for foundation_file in "$dc_dir"/*.yml; do
                if [[ -f "$foundation_file" ]]; then
                    local filename=$(basename "$foundation_file")
                    if [[ ! "$filename" =~ ^datacenter.*\.yml$ ]]; then
                        local foundation="${filename%.yml}"
                        echo "2|foundation|$filename|$datacenter|$foundation|$foundation_file" >> "$files_list"
                    fi
                fi
            done
        fi
    done
    
    echo "$files_list"
}

# Extract all parameters from a YAML file with dot notation paths
extract_parameters() {
    local yaml_file="$1"
    local prefix="$2"
    
    if [[ ! -f "$yaml_file" ]]; then
        return
    fi
    
    # Use yq to flatten the YAML and extract key-value pairs
    yq eval -o=props "$yaml_file" 2>/dev/null | while IFS='=' read -r key value; do
        if [[ -n "$key" && -n "$value" ]]; then
            local full_key="${prefix:+$prefix.}$key"
            echo "$full_key|$value"
        fi
    done
}

# Find duplicate parameters across all files
find_duplicate_parameters() {
    local repo_path="$1"
    local files_list
    local params_db="$TEMP_DIR/params.db"
    local duplicates_found=false
    
    files_list=$(get_all_yaml_files "$repo_path")
    
    log_info "Analyzing parameter files for duplicates..."
    echo "============================================================"
    
    # Create parameter database
    > "$params_db"
    
    while IFS='|' read -r level type filename datacenter foundation filepath; do
        local file_desc="$filename"
        if [[ -n "$datacenter" ]]; then
            file_desc="$datacenter/$filename"
        fi
        
        extract_parameters "$filepath" "" | while IFS='|' read -r param_key param_value; do
            echo "$param_key|$param_value|$file_desc|$level|$datacenter|$foundation" >> "$params_db"
        done
    done < "$files_list"
    
    # Find duplicates by grouping parameters
    local current_param=""
    local param_locations=()
    
    sort "$params_db" | while IFS='|' read -r param_key param_value file_desc level datacenter foundation; do
        if [[ "$param_key" != "$current_param" ]]; then
            # Process previous parameter if it had duplicates
            if [[ ${#param_locations[@]} -gt 1 ]]; then
                echo "DUPLICATE_FOUND"
                duplicates_found=true
            fi
            
            # Start new parameter
            current_param="$param_key"
            param_locations=("$param_value|$file_desc|$level")
        else
            # Add to current parameter locations
            param_locations+=("$param_value|$file_desc|$level")
        fi
    done > "$TEMP_DIR/duplicate_check.tmp"
    
    # Process duplicates for reporting
    local duplicate_params="$TEMP_DIR/duplicates.txt"
    > "$duplicate_params"
    
    sort "$params_db" | awk -F'|' '
    {
        key = $1
        value = $2
        file = $3
        level = $4
        
        # Store all occurrences
        locations[key][value][++counts[key][value]] = file "|" level
        param_keys[key] = 1
    }
    END {
        for (param in param_keys) {
            duplicate_found = 0
            for (value in locations[param]) {
                if (counts[param][value] > 1) {
                    duplicate_found = 1
                    break
                }
            }
            if (duplicate_found) {
                print "PARAM:" param
                for (value in locations[param]) {
                    if (counts[param][value] > 1) {
                        print "  VALUE:" value
                        for (i = 1; i <= counts[param][value]; i++) {
                            split(locations[param][value][i], parts, "|")
                            level_desc = (parts[2] == "0") ? "Global" : (parts[2] == "1") ? "Datacenter" : "Foundation" 
                            print "    FILE:" parts[1] " (" level_desc ")"
                        }
                    }
                }
                print "---"
            }
        }
    }' > "$duplicate_params"
    
    # Display results
    if [[ -s "$duplicate_params" ]]; then
        local param_count=$(grep -c "^PARAM:" "$duplicate_params")
        echo "Found $param_count parameters with duplicates:"
        echo "============================================================"
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^PARAM: ]]; then
                echo ""
                echo -e "${YELLOW}Parameter: ${line#PARAM:}${NC}"
                echo "----------------------------------------"
            elif [[ "$line" =~ ^\ \ VALUE: ]]; then
                echo -e "  ${BLUE}Value: ${line#  VALUE:}${NC}"
                echo "  Found in multiple files:"
            elif [[ "$line" =~ ^\ \ \ \ FILE: ]]; then
                echo "    - ${line#    FILE:}"
            elif [[ "$line" == "---" ]]; then
                echo ""
            fi
        done < "$duplicate_params"
    else
        log_success "No duplicate parameters found!"
    fi
}

# Merge YAML files with proper precedence
merge_yaml_files() {
    local output_file="$1"
    shift
    local files=("$@")
    
    > "$output_file"
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            log_info "Merging: $(basename "$file")"
            if [[ -s "$output_file" ]]; then
                yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$output_file" "$file" > "$output_file.tmp"
                mv "$output_file.tmp" "$output_file"
            else
                cp "$file" "$output_file"
            fi
        fi
    done
}

# Generate complete foundation file
generate_foundation_file() {
    local repo_path="$1"
    local datacenter="$2"
    local foundation="$3"
    local environment="${4:-prod}"
    local output_file="$5"
    
    local merged_file="$TEMP_DIR/merged.yml"
    local files_to_merge=()
    
    log_info "Generating foundation file for $datacenter/$foundation ($environment)"
    
    # Build file list in hierarchy order
    local global_file="$repo_path/global.yml"
    if [[ -f "$global_file" ]]; then
        files_to_merge+=("$global_file")
    fi
    
    local env_global_file="$repo_path/global-$environment.yml"
    if [[ -f "$env_global_file" ]]; then
        files_to_merge+=("$env_global_file")
    fi
    
    local dc_dir="$repo_path/$datacenter"
    if [[ -d "$dc_dir" ]]; then
        local dc_file="$dc_dir/datacenter.yml"
        if [[ -f "$dc_file" ]]; then
            files_to_merge+=("$dc_file")
        fi
        
        local dc_env_file="$dc_dir/datacenter-$environment.yml"
        if [[ -f "$dc_env_file" ]]; then
            files_to_merge+=("$dc_env_file")
        fi
        
        local foundation_file="$dc_dir/$foundation.yml"
        if [[ -f "$foundation_file" ]]; then
            files_to_merge+=("$foundation_file")
        fi
    fi
    
    if [[ ${#files_to_merge[@]} -eq 0 ]]; then
        log_error "No parameter files found for foundation $foundation in datacenter $datacenter"
        return 1
    fi
    
    # Merge all files
    merge_yaml_files "$merged_file" "${files_to_merge[@]}"
    
    # Sort the final output
    yq eval 'sort_keys(.)' "$merged_file" > "$merged_file.sorted"
    
    if [[ -n "$output_file" ]]; then
        cp "$merged_file.sorted" "$output_file"
        log_success "Generated foundation file: $output_file"
    else
        echo "Complete parameters for $datacenter/$foundation ($environment):"
        echo "============================================================"
        cat "$merged_file.sorted"
    fi
}

# Main function
main() {
    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi
    
    check_dependencies
    
    REPO_PATH="$1"
    local command="$2"
    
    if [[ ! -d "$REPO_PATH" ]]; then
        log_error "Repository path '$REPO_PATH' does not exist"
        exit 1
    fi
    
    mkdir -p "$TEMP_DIR"
    
    case "$command" in
        "find-duplicates")
            find_duplicate_parameters "$REPO_PATH"
            ;;
        "generate-foundation")
            if [[ $# -lt 4 ]]; then
                log_error "generate-foundation requires datacenter and foundation arguments"
                usage
                exit 1
            fi
            
            local datacenter="$3"
            local foundation="$4"
            local environment="prod"
            local output_file=""
            
            # Parse additional arguments
            shift 4
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -e|--environment)
                        environment="$2"
                        shift 2
                        ;;
                    -o|--output)
                        output_file="$2"
                        shift 2
                        ;;
                    *)
                        log_error "Unknown option: $1"
                        usage
                        exit 1
                        ;;
                esac
            done
            
            if [[ ! "$environment" =~ ^(lab|nonprod|prod)$ ]]; then
                log_error "Invalid environment: $environment. Must be lab, nonprod, or prod"
                exit 1
            fi
            
            generate_foundation_file "$REPO_PATH" "$datacenter" "$foundation" "$environment" "$output_file"
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"