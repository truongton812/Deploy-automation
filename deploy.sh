#!/bin/bash

# Configuration
GITHUB_API="https://api.github.com/repos"
REPO_OWNER=""
REPO_NAME=""
GITHUB_TOKEN=""
KEEP_VERSIONS=10

# Environment to GCP Project mapping
GCP_PROJECTS_DEV=""
GCP_PROJECTS_STAGE=""
GCP_PROJECTS_PROD=""

# Valid environments
VALID_ENVIRONMENTS=("stage" "prod")

# Directory structure
BASE_DIR="$(pwd)"
DEFAULT_CONFIG_FILE="deployment.yaml"
DOWNLOADS_DIR=""
ENVIRONMENT=""
CONFIG_FILE=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message=$@
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${timestamp} - $message"
            ;;
    esac
}

# Function to validate environment
validate_environment() {
    local env=$1
    for valid_env in "${VALID_ENVIRONMENTS[@]}"; do
        if [[ "$env" == "$valid_env" ]]; then
            return 0
        fi
    done
    log "ERROR" "Invalid environment: $env. Valid environments are: ${VALID_ENVIRONMENTS[*]}"

    # Check if GitHub token is set
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log "ERROR" "GitHub token is not set. Please set GITHUB_TOKEN environment variable."
        exit 1
    fi

    return 1
}

# Function to check required tools
check_requirements() {
    local required_tools=("gcloud" "curl")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            log "ERROR" "$tool is required but not installed."
            exit 1
        fi
    done

    # Check and install yq if not present
    if ! command -v yq &> /dev/null; then
        log "INFO" "yq not found. Attempting to install..."
        if ! sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq; then
            log "ERROR" "Failed to install yq. Please install it manually."
            exit 1
        fi
        log "INFO" "yq installed successfully"
    fi

    sudo chmod +x /usr/bin/yq
    
    # Check if logged in to gcloud
    if ! gcloud auth list 2>&1 | grep -q "ACTIVE"; then
        log "ERROR" "Not logged in to gcloud. Please run 'gcloud auth login' first."
        exit 1
    fi
}

# Function to validate release tag format
validate_release_tag() {
    local tag=$1
    if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+-build\.[0-9]+$ ]]; then
        log "ERROR" "Invalid release tag format. Expected: vx.x.x-build.x"
        return 1
    fi
    return 0
}

# Function to set GCP project
check_gcp_project() {
    local env=$1
    local project_id
    
    # Get project ID from config based on environment
    case "$env" in
        "dev")
            project_id="$GCP_PROJECTS_DEV"
            ;;
        "stage")
            project_id="$GCP_PROJECTS_STAGE"
            ;;
        "prod")
            project_id="$GCP_PROJECTS_PROD"
            ;;
        *)
            log "ERROR" "Invalid environment: $env"
            return 1
            ;;
    esac
    
    # Check if project ID is configured
    if [[ -z "$project_id" ]]; then
        log "ERROR" "GCP project ID not configured for environment: $env"
        return 1
    fi
    
    # Get current project ID from gcloud config
    local current_project
    current_project=$(gcloud config get-value project 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to get current GCP project"
        return 1
    fi
    
    # If current project is different from target project
    if [[ "$current_project" != "$project_id" ]]; then
        log "INFO" "Current project: $current_project"
        log "INFO" "Input to project: $project_id"
        
        # Verify project exists and we have access
        if ! gcloud projects describe "$project_id" &>/dev/null; then
            log "ERROR" "Project $project_id does not exist or you don't have access to it"
            return 1
        fi
        log "ERROR" "Google project id not match"
        return 1
        
    else
        log "INFO" "Already using correct project: $project_id"
    fi
    
    # Verify App Engine is enabled
    if ! gcloud app describe &>/dev/null; then
        log "ERROR" "App Engine is not enabled in project: $project_id"
        return 1
    fi
    
    # Verify we have the necessary permissions
    if ! gcloud app versions list &>/dev/null; then
        log "ERROR" "Insufficient permissions in project: $project_id"
        log "ERROR" "Required permissions: appengine.applications.get, appengine.versions.list"
        return 1
    fi
    
    log "INFO" "Successfully verified and set GCP project: $project_id"
    return 0
}

# Function to format size
format_size() {
    local size=$1
    local units=("B" "KB" "MB" "GB")
    local unit=0
    
    while [ $size -gt 1024 ] && [ $unit -lt 3 ]; do
        size=$((size / 1024))
        unit=$((unit + 1))
    done
    
    echo "${size}${units[$unit]}"
}

# Function to download packages from GitHub release
download_packages() {
    local release_tag=$1
    local release_env=$2
    shift 2
    local services=("$@")
    
    log "INFO" "Downloading assets for release: $release_tag (Environment: $release_env)"

    # If no services specified, get all services from environment
    if [ ${#services[@]} -eq 0 ]; then
        log "INFO" "No services specified, deploying all services from environment: $env"
        # Read services into array
        while IFS= read -r service; do
            services+=("$service")
        done <<< $(get_env_services "$env")
        
        if [ ${#services[@]} -eq 0 ]; then
            log "ERROR" "No services found in environment: $env"
            return 1
        fi
        
        log "INFO" "Found services to deploy: ${services[*]}"
    fi
    
    if [ ${#services[@]} -gt 0 ]; then
        log "INFO" "Validating services: ${services[*]}"
    fi
    
    # Create downloads directory if it doesn't exist
    mkdir -p "$DOWNLOADS_DIR"
    
    # Get release assets list
    local assets_url="${GITHUB_API}/${REPO_OWNER}/${REPO_NAME}/releases/tags/${release_tag}"
    local assets_response
    local http_code
    
    log "INFO" "Fetching release information..."
    
    # Get release information with timeout
    assets_response=$(curl -sL --connect-timeout 10 --max-time 30 -w "HTTPSTATUS:%{http_code}" \
                          -H "Authorization: token ${GITHUB_TOKEN}" \
                          -H "Accept: application/vnd.github.v3+json" \
                          "$assets_url")
    
    http_code=$(echo "$assets_response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    assets_response=$(echo "$assets_response" | sed -e 's/HTTPSTATUS\:.*//g')
    
    if [ "$http_code" -eq 200 ]; then
        # Extract assets URLs, names and sizes
        local assets_list
        assets_list=$(echo "$assets_response" | jq -r '.assets[] | {name: .name, url: .url, size: .size} | @base64')
        
        if [ -z "$assets_list" ]; then
            log "ERROR" "No assets found for release ${release_tag}"
            return 1
        fi
        
        # Validate services if specified
        if [ ${#services[@]} -gt 0 ]; then
            local missing_services=()
            for service in "${services[@]}"; do
                local package_name=$(get_package_name "$env" "$service")
                # Check if any asset name starts with the service name (ignoring version)
                if ! echo "$assets_response" | jq -e --arg svc "$REPO_NAME-$package_name" '.assets[] | select(.name | startswith($svc + "-"))' > /dev/null; then
                    missing_services+=("$package_name")
                fi
            done
            
            if [ ${#missing_services[@]} -gt 0 ]; then
                log "ERROR" "Missing assets for services: ${missing_services[*]} in release ${release_tag}"
                return 1
            fi
            
            log "INFO" "All specified services found in release"
        fi
        
        # Count total assets and calculate total size
        local total_assets=$(echo "$assets_list" | wc -l)
        local total_size=0
        local current_asset=0
        
        # Calculate total size
        while IFS= read -r asset_info; do
            local size
            size=$(echo "$asset_info" | base64 --decode | jq -r '.size')
            total_size=$((total_size + size))
        done <<< "$assets_list"
        
        log "INFO" "Found ${total_assets} assets, total size: $(format_size $total_size)"
        
        # Create version directory and temp directory
        local version=$release_tag
        local extract_dir="${DOWNLOADS_DIR}/${release_env}/${version}"
        local temp_dir="${DOWNLOADS_DIR}/${release_env}/${version}/.temp"
        local archives_dir="${extract_dir}/archives"
        mkdir -p "$extract_dir" "$temp_dir" "$archives_dir"
        
        # Create a temporary file to store asset information
        local tmp_assets="${temp_dir}/assets_${version}_$$"
        echo "$assets_list" > "$tmp_assets"
        
        # Initialize error flag
        local has_error=0
        local downloaded_size=0
        
        # Download each asset
        while IFS= read -r asset_info; do
            local name
            local url
            local size
            current_asset=$((current_asset + 1))
            
            name=$(echo "$asset_info" | base64 --decode | jq -r '.name')
            url=$(echo "$asset_info" | base64 --decode | jq -r '.url')
            size=$(echo "$asset_info" | base64 --decode | jq -r '.size')
            local temp_file="${temp_dir}/${name}"
            local archive_file="${archives_dir}/${name}"
            
            # Calculate progress percentage
            local total_progress=$(( (downloaded_size * 100) / total_size ))
            local formatted_size=$(format_size $size)
            
            log "INFO" "Downloading asset ${current_asset}/${total_assets}: ${name} (${formatted_size})"
            echo -ne "Total progress: [${total_progress}%] [${downloaded_size}/${total_size} bytes]\r"
            
            # Download asset with timeout and progress
            local download_response
            download_response=$(curl -L --connect-timeout 10 --max-time 300 \
                                   -H "Authorization: token ${GITHUB_TOKEN}" \
                                   -H "Accept: application/octet-stream" \
                                   --progress-bar \
                                   -o "$temp_file" \
                                   -w "HTTPSTATUS:%{http_code}\\n%{speed_download}\\n%{size_download}" \
                                   "$url")
            
            local download_code
            local download_speed
            local downloaded
            download_code=$(echo "$download_response" | head -n1 | sed -e 's/HTTPSTATUS://')
            download_speed=$(echo "$download_response" | head -n2 | tail -n1)
            downloaded=$(echo "$download_response" | tail -n1)
            
            if [ "$download_code" -eq 200 ]; then
                downloaded_size=$((downloaded_size + size))
                log "INFO" "Successfully downloaded ${name} ($(format_size $download_speed)/s)"
                
                # Move downloaded file to archives directory
                mv "$temp_file" "$archive_file"
                
                # Verify and extract zip file if it's a zip
                if [[ "$name" == *.zip ]]; then
                    # Get directory name from asset name (remove .zip extension)
                    local asset_dir="${extract_dir}/${name%.zip}"
                    mkdir -p "$asset_dir"
                    
                    if unzip -t "$archive_file" > /dev/null 2>&1; then
                        if unzip -o -q "$archive_file" -d "$asset_dir"; then
                            log "INFO" "Successfully extracted ${name} to ${asset_dir}"
                        else
                            log "ERROR" "Failed to extract ${name}"
                            has_error=1
                            break
                        fi
                    else
                        log "ERROR" "Invalid or corrupted zip file: ${name}"
                        has_error=1
                        break
                    fi
                fi
            else
                log "ERROR" "Failed to download ${name} (HTTP ${download_code})"
                [ -f "$temp_file" ] && rm -f "$temp_file"
                has_error=1
                break
            fi
        done < "$tmp_assets"
        
        echo # New line after progress
        
        # Cleanup temp files
        rm -f "$tmp_assets"
        rm -rf "$temp_dir"
        rm -rf "$archives_dir"
        
        # Return error status
        [ "$has_error" -eq 1 ] && return 1
        
        log "INFO" "Successfully downloaded all assets (Total: $(format_size $total_size))"
        log "INFO" "All packages are stored in: ${extract_dir}"
        return 0
    else
        log "ERROR" "Failed to fetch release information (HTTP ${http_code})"
        return 1
    fi
}

# Function to deploy maintenance mode
deploy_maintenance() {
    local env=$1
    local dispatch="${DOWNLOADS_DIR}/${env}/maintenance"

    # Create dispatch.yaml
    if ! create_dispatch_yaml "$env" maintenance "$dispatch"; then
        log "ERROR" "Failed to create dispatch.yaml for maintenance"
        return 1
    fi
    
    local dispatch_yaml="${dispatch}/dispatch.yaml"
    
    if [[ ! -f "$dispatch_yaml" ]]; then
        log "ERROR" "Maintenance configuration files not found for environment: $env"
        return 1
    fi
    
    log "INFO" "Deploying maintenance service for environment: $env"
    if gcloud app deploy "$dispatch_yaml" --quiet; then
        log "INFO" "Maintenance mode activated successfully"
        return 0
    fi
    
    log "ERROR" "Failed to deploy maintenance mode"
    return 1
}

# Function to create app.yaml for a service
create_app_yaml() {
    local env=$1
    local service=$2
    local source_dir=$3
    local app_yaml="${source_dir}/app.yaml"
    
    # Create source directory if it doesn't exist
    mkdir -p "$source_dir"
    
    # Get complete app.yaml configuration for the service in this environment
    if ! yq eval ".environments.${env}.services.${service}.app_yaml" "$CONFIG_FILE" > "$app_yaml"; then
        log "ERROR" "Failed to get app.yaml configuration for service $service in environment $env"
        return 1
    fi
    
    # Check if app.yaml was created and is not empty
    if [[ ! -s "$app_yaml" ]]; then
        log "ERROR" "app.yaml configuration not defined for service $service in environment $env"
        return 1
    fi
    
    # Validate that service name in app.yaml matches the service
    local configured_service=$(yq eval '.service' "$app_yaml")
    if [[ "$configured_service" != "$service" ]]; then
        log "ERROR" "Service name mismatch in app.yaml for $service (found: $configured_service)"
        return 1
    fi
    
    # Validate that runtime is specified
    local runtime=$(yq eval '.runtime' "$app_yaml")
    if [[ -z "$runtime" || "$runtime" == "null" ]]; then
        log "ERROR" "Runtime not specified in app.yaml for service $service"
        return 1
    fi
    
    log "INFO" "Created app.yaml for service $service in $app_yaml"
    return 0
}

# Function to create dispatch.yaml
create_dispatch_yaml() {
    local env=$1
    local service=$2
    local source_dir=$3
    local dispatch_yaml="${source_dir}/dispatch.yaml"
    
    # Create source directory if it doesn't exist
    mkdir -p "$source_dir"
    
    # Get complete dispatch.yaml configuration for the service in this environment
    if ! yq eval ".environments.${env}.dispatch.${service}" "$CONFIG_FILE" > "$dispatch_yaml"; then
        log "ERROR" "Failed to get dispatch.yaml configuration for $service in environment $env"
        return 1
    fi
    
    # Check if dispatch.yaml was created and is not empty
    if [[ ! -s "$dispatch_yaml" ]]; then
        log "ERROR" "dispatch.yaml configuration not defined for $service in environment $env"
        return 1
    fi
    
    log "INFO" "Created dispatch.yaml for $service in $dispatch_yaml"
    return 0
}

# Function to get all services from environment
get_env_services() {
    local env=$1
    # Get list of services from deployment.yaml, excluding maintenance service
    yq eval ".environments.${env}.services | keys | .[] | select(. != \"maintenance\")" "$CONFIG_FILE"
}

# Function to get package name by service
get_package_name() {
    local env=$1
    local service=$2
    yq eval ".environments.${env}.services.${service}.package_name // \"${service}\"" "$CONFIG_FILE"
}

# Function to deploy a single service
deploy_service() {
    local env=$1
    local tag=$2
    shift 2
    local services=("$@")
    
    # If no services specified, get all services from environment
    if [ ${#services[@]} -eq 0 ]; then
        log "INFO" "No services specified, deploying all services from environment: $env"
        # Read services into array
        while IFS= read -r service; do
            services+=("$service")
        done <<< $(get_env_services "$env")
        
        if [ ${#services[@]} -eq 0 ]; then
            log "ERROR" "No services found in environment: $env"
            return 1
        fi
        
        log "INFO" "Found services to deploy: ${services[*]}"
    fi
    
    # Format version string for GCP (replace dots with dashes)
    local gcp_version=$(echo $tag | tr '.' '-' | sed 's/v//')
    
    for service in "${services[@]}"; do
        local package_name=$(get_package_name "$env" "$service")
        local source_dir="${DOWNLOADS_DIR}/${env}/${tag}/${REPO_NAME}-${package_name}-${tag}"
        
        if [[ ! -d "$source_dir" ]]; then
            log "ERROR" "Source directory not found for $service: $source_dir"
            return 1
        fi
        
        # Create app.yaml for the service
        if ! create_app_yaml "$env" "$service" "$source_dir"; then
            log "ERROR" "Failed to create app.yaml for $service"
            return 1
        fi
        
        local app_yaml="${source_dir}/app.yaml"
        log "INFO" "Deploying $service version $gcp_version to environment: $env"
        
        # Change to service directory for deployment
        pushd "$source_dir" > /dev/null || {
            log "ERROR" "Failed to change to directory: $source_dir"
            return 1
        }
        
        if gcloud app deploy app.yaml --version="$gcp_version" --quiet; then
            log "INFO" "Successfully deployed $service"
            
            # Cleanup old versions
            cleanup_versions "$env" "$service"
            
            # Return to original directory
            popd > /dev/null
        else
            log "ERROR" "Failed to deploy $service"
            popd > /dev/null
            return 1
        fi
    done
    
    return 0
}

# Function to cleanup old versions
cleanup_versions() {
    local env=$1
    local service_name=$2
    
    log "INFO" "Cleaning up old versions for $service_name in environment: $env"
    
    # List versions sorted by last deployed time
    local versions=$(gcloud app versions list \
        --service="$service_name" \
        --sort-by="~version.createTime" \
        --format="value(version.id)" \
        | tail -n +$((KEEP_VERSIONS + 1)))
    
    if [[ -n "$versions" ]]; then
        log "INFO" "Deleting old versions: $versions"
        echo "$versions" | xargs gcloud app versions delete --service="$service_name" --quiet
    else
        log "INFO" "No old versions to cleanup for $service_name"
    fi
}

# Function to restore normal dispatch rules
dispatch_service() {
    local env=$1
    local tag=$2

    local dispatch_dir="${DOWNLOADS_DIR}/${env}/${tag}"

    # Create dispatch.yaml
    if ! create_dispatch_yaml "$env" services "$dispatch_dir"; then
        log "ERROR" "Failed to create dispatch.yaml for services"
        return 1
    fi

    local dispatch_yaml="${dispatch_dir}/dispatch.yaml"
    
    if [[ ! -f "$dispatch_yaml" ]]; then
        log "ERROR" "Dispatch services configuration files not found for environment: $env"
        return 1
    fi
    
    log "INFO" "Deploying dispatch rules for environment: $env"
    if gcloud app deploy "$dispatch_yaml" --quiet; then
        log "INFO" "Dispatch rules deployed successfully"
        return 0
    fi
    

    
    log "ERROR" "Failed to deploy dispatch rules"
    return 1
}

# Function to load configuration
load_config() {
    local config_file="$1"

    if [[ -z "$config_file" ]]; then
        config_file="$DEFAULT_CONFIG_FILE"
    fi

    if [[ ! -f "${BASE_DIR}/$config_file" ]]; then
        log "ERROR" "Configuration file not found: $config_file"
        exit 1
    fi

    # Load configuration using yq/jq
    GITHUB_TOKEN=$(yq eval '.github_token' "${BASE_DIR}/$config_file")
    REPO_OWNER=$(yq eval '.repo_owner' "${BASE_DIR}/$config_file")
    REPO_NAME=$(yq eval '.repo_name' "${BASE_DIR}/$config_file")
    KEEP_VERSIONS=$(yq eval '.keep_versions // 10' "${BASE_DIR}/$config_file")
    
    # Load GCP project IDs
    GCP_PROJECTS_DEV=$(yq eval '.gcp_projects.dev' "${BASE_DIR}/$config_file")
    GCP_PROJECTS_STAGE=$(yq eval '.gcp_projects.stage' "${BASE_DIR}/$config_file")
    GCP_PROJECTS_PROD=$(yq eval '.gcp_projects.prod' "${BASE_DIR}/$config_file")

    # Load custom directories with defaults
    local custom_dir=$(yq eval '.directories // ""' "${BASE_DIR}/$config_file")

    # Set directories with custom paths or defaults
    if [[ -n "$custom_dir" ]]; then
        # If path is relative, make it relative to BASE_DIR
        DOWNLOADS_DIR="${custom_dir}"
    else
        DOWNLOADS_DIR="${BASE_DIR}/${REPO_NAME}"
    fi

    CONFIG_FILE="${BASE_DIR}/$config_file"
}

# Parse command line arguments
case "$1" in
    "prepare-release")
        shift
        local env=""
        local tag=""
        local config_file="deployment.yaml"
        local services=()
        
        # Parse arguments
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -e|--env)
                    if [[ -n "$2" ]]; then
                        env="$2"
                        shift 2
                    else
                        log "ERROR" "Environment argument is missing"
                        echo "Usage: $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                        exit 1
                    fi
                    ;;
                -t|--tag)
                    if [[ -n "$2" ]]; then
                        tag="$2"
                        shift 2
                    else
                        log "ERROR" "Release tag argument is missing"
                        echo "Usage: $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                        exit 1
                    fi
                    ;;
                -c|--config)
                    if [[ -n "$2" ]]; then
                        config_file="$2"
                        shift 2
                    fi
                    ;;
                -s|--services)
                    shift
                    while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                        services+=("$1")
                        shift
                    done
                    if [ ${#services[@]} -eq 0 ]; then
                        log "ERROR" "No services specified after -s|--services"
                        echo "Usage: $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                        exit 1
                    fi
                    ;;
                *)
                    log "ERROR" "Invalid argument: $1"
                    echo "Usage: $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                    exit 1
                    ;;
            esac
        done
        
        # Validate required arguments
        if [[ -z "$env" ]]; then
            log "ERROR" "Environment (-e|--env) is required"
            echo "Usage: $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
            exit 1
        fi
        
        if [[ -z "$tag" ]]; then
            log "ERROR" "Release tag (-t|--tag) is required"
            echo "Usage: $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
            exit 1
        fi

        check_requirements
        
        # Load config and validate environment
        load_config "$config_file"
        if ! validate_environment "$env"; then
            exit 1
        fi

        if ! check_gcp_project "$env"; then
            exit 1
        fi

        # Download packages
        download_packages "$tag" "$env" "${services[@]}"

        # Deploy maintenance mode
        deploy_maintenance "$env" 
        ;;

    "dispatch-service")
        shift
        local env=""
        local tag=""
        local config_file="deployment.yaml"
        
        # Parse arguments
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -e|--env)
                    if [[ -n "$2" ]]; then
                        env="$2"
                        shift 2
                    else
                        log "ERROR" "Environment argument is missing"
                        echo "Usage: $0 dispatch-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag>"
                        exit 1
                    fi
                    ;;
                -t|--tag)
                    if [[ -n "$2" ]]; then
                        tag="$2"
                        shift 2
                    else
                        log "ERROR" "Release tag argument is missing"
                        echo "Usage: $0 dispatch-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag>"
                        exit 1
                    fi
                    ;;
                -c|--config)
                    if [[ -n "$2" ]]; then
                        config_file="$2"
                        shift 2
                    fi
                    ;;
                *)
                    log "ERROR" "Invalid argument: $1"
                    echo "Usage: $0 dispatch-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag>"
                    exit 1
                    ;;
            esac
        done
        
        # Validate required arguments
        if [[ -z "$env" ]]; then
            log "ERROR" "Environment (-e|--env) is required"
            echo "Usage: $0 dispatch-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag>"
            exit 1
        fi
        
        if [[ -z "$tag" ]]; then
            log "ERROR" "Release tag (-t|--tag) is required"
            echo "Usage: $0 dispatch-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag>"
            exit 1
        fi

        check_requirements
        
        # Load config and validate environment
        load_config "$config_file"
        if ! validate_environment "$env"; then
            exit 1
        fi
        
        # check GCP project
        if ! check_gcp_project "$env"; then
            exit 1
        fi
        
        # Deploy dispatch rules
        dispatch_service "$env" "$tag"
        ;;

    "deploy-service")
        shift
        local env=""
        local tag=""
        local config_file="deployment.yaml"
        local services=()
        
        # Parse arguments
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -e|--env)
                    if [[ -n "$2" ]]; then
                        env="$2"
                        shift 2
                    else
                        log "ERROR" "Environment argument is missing"
                        echo "Usage: $0 deploy-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                        exit 1
                    fi
                    ;;
                -t|--tag)
                    if [[ -n "$2" ]]; then
                        tag="$2"
                        shift 2
                    else
                        log "ERROR" "Release tag argument is missing"
                        echo "Usage: $0 deploy-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                        exit 1
                    fi
                    ;;
                -c|--config)
                    if [[ -n "$2" ]]; then
                        config_file="$2"
                        shift 2
                    fi
                    ;;
                -s|--services)
                    shift
                    while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                        services+=("$1")
                        shift
                    done
                    ;;
                *)
                    log "ERROR" "Invalid argument: $1"
                    echo "Usage: $0 deploy-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
                    exit 1
                    ;;
            esac
        done
        
        # Validate required arguments
        if [[ -z "$env" ]]; then
            log "ERROR" "Environment (-e|--env) is required"
            echo "Usage: $0 deploy-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
            exit 1
        fi
        
        if [[ -z "$tag" ]]; then
            log "ERROR" "Release tag (-t|--tag) is required"
            echo "Usage: $0 deploy-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
            exit 1
        fi

        check_requirements
        
        # Load config and validate environment
        load_config "$config_file"
        if ! validate_environment "$env"; then
            exit 1
        fi
        
        # check GCP project
        if ! check_gcp_project "$env"; then
            exit 1
        fi
        
        # Deploy services
        deploy_service "$env" "$tag" "${services[@]}"
        ;;

    *)
        echo "Usage:"
        echo "  $0 prepare-release [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
        echo "  $0 deploy-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag> [-s|--services <service1 service2 ...>]"
        echo "  $0 dispatch-service [-c deployment.yaml] -e|--env <environment> -t|--tag <release_tag>"
        exit 1
        ;;
esac 
