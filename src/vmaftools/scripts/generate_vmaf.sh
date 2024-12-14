#!/bin/bash

# Function to check if a command exists
check_dependency() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: Required dependency '$1' is not installed."
        case "$1" in
            ffmpeg)
                echo "Install with: brew install ffmpeg"
                ;;
            jq)
                echo "Install with: brew install jq"
                ;;
            python3)
                echo "Install with: brew install python3"
                ;;
        esac
        exit 1
    fi
}

# Check required dependencies
check_dependency ffmpeg
check_dependency jq
check_dependency python3
check_dependency bc

# Check Python packages
check_python_package() {
    if ! python3 -c "import $1" >/dev/null 2>&1; then
        echo "Error: Required Python package '$1' is not installed."
        echo "Install with: pip3 install $1"
        exit 1
    fi
}

check_python_package numpy
check_python_package matplotlib

# Add start time capture at the beginning of the script
START_TIME=$(date +%s)

# Initialize default values
NO_DENOISE=false
OUTPUT_DIR=""

# Parse optional parameters
while [[ $# -gt 0 ]]; do
    case $1 in
        --no_denoise)
            NO_DENOISE=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -lt 2 ]; then
    echo "Usage: generate-vmaf [--no_denoise] [--output-dir <dir>] <reference_video> <distorted_video> [output_prefix]"
    echo ""
    echo "Examples:"
    echo "  # Basic usage"
    echo "  generate-vmaf reference.mp4 distorted.mp4"
    echo ""
    echo "  # With output directory and prefix"
    echo "  generate-vmaf --output-dir ~/results reference.mp4 distorted.mp4 my_analysis"
    echo ""
    echo "  # Disable denoising"
    echo "  generate-vmaf --no_denoise reference.mp4 distorted.mp4"
    echo ""
    echo "Options:"
    echo "  --no_denoise     Disable denoising of reference video"
    echo "  --output-dir     Specify output directory for results (default: current directory)"
    echo "  [output_prefix]  Optional prefix for output files (default: vmaf_analysis)"
    exit 1
fi

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set current directory as working directory
CURRENT_DIR="$(pwd)"

# Use output directory if specified, otherwise use current directory
if [ -n "$OUTPUT_DIR" ]; then
    # Create output directory if it doesn't exist
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
else
    OUTPUT_DIR="$CURRENT_DIR"
fi

REFERENCE=$(realpath "$1")
DISTORTED=$(realpath "$2")
PREFIX="${3:-vmaf_analysis}"

# Ensure the output files are written to the specified directory
PREFIX="$OUTPUT_DIR/$PREFIX"

# Check if input files exist
if [ ! -f "$REFERENCE" ]; then
    echo "Error: Reference video file not found: $REFERENCE"
    exit 1
fi

if [ ! -f "$DISTORTED" ]; then
    echo "Error: Distorted video file not found: $DISTORTED"
    exit 1
fi

# Define model versions
VMAF_MODEL="version=vmaf_v0.6.1"
VMAF_4K_MODEL="version=vmaf_4k_v0.6.1"

# Get video dimensions using ffprobe
REF_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$REFERENCE" | tr -d ',' | tr -d ' ')
REF_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$REFERENCE" | tr -d ',' | tr -d ' ')
DIST_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$DISTORTED" | tr -d ',' | tr -d ' ')
DIST_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$DISTORTED" | tr -d ',' | tr -d ' ')

# Get frame counts and frame rates
REF_FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$REFERENCE" | tr -d ',' | tr -d ' ')
DIST_FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$DISTORTED" | tr -d ',' | tr -d ' ')
REF_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$REFERENCE" | tr -d ',' | tr -d ' ')
DIST_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$DISTORTED" | tr -d ',' | tr -d ' ')

# Convert fractional frame rate to decimal
REF_FPS=$(echo "scale=3; $REF_FPS" | bc)
DIST_FPS=$(echo "scale=3; $DIST_FPS" | bc)

# Validate frame counts and rates
if [ "$REF_FRAMES" != "$DIST_FRAMES" ]; then
    echo "Warning: Frame count mismatch! Reference: $REF_FRAMES, Distorted: $DIST_FRAMES"
    exit 1
fi

if [ "$REF_FPS" != "$DIST_FPS" ]; then
    echo "Warning: Frame rate mismatch! Reference: $REF_FPS, Distorted: $DIST_FPS"
    exit 1
fi

# Calculate crop values
WIDTH_DIFF=$((REF_WIDTH - DIST_WIDTH))
HEIGHT_DIFF=$((REF_HEIGHT - DIST_HEIGHT))
CROP_X=$((WIDTH_DIFF / 2))
CROP_Y=$((HEIGHT_DIFF / 2))

echo "Reference: ${REF_WIDTH}x${REF_HEIGHT}"
echo "Distorted: ${DIST_WIDTH}x${DIST_HEIGHT}"

# Determine if we need to crop or scale
if [ "$DIST_HEIGHT" -lt "$REF_HEIGHT" ] && [ "$DIST_WIDTH" -eq "$REF_WIDTH" ]; then
    # Calculate crop values to remove black bars
    HEIGHT_DIFF=$((REF_HEIGHT - DIST_HEIGHT))
    CROP_Y=$((HEIGHT_DIFF / 2))
    echo "Cropping reference video to remove black bars: ${DIST_WIDTH}x${DIST_HEIGHT}"
    CROP_FILTER="crop=${DIST_WIDTH}:${DIST_HEIGHT}:0:${CROP_Y}"
else
    echo "Scaling distorted video to match reference dimensions"
    CROP_FILTER=""
fi

# Check if videos are HDR using ffprobe
is_hdr() {
    local file="$1"
    local color_space=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_space -of default=noprint_wrappers=1:nokey=1 "$file")
    local color_transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=noprint_wrappers=1:nokey=1 "$file")
    
    if [[ "$color_transfer" == *"smpte2084"* ]] || [[ "$color_transfer" == *"arib-std-b67"* ]]; then
        return 0  # true in bash
    else
        return 1  # false in bash
    fi
}

REF_IS_HDR=$(is_hdr "$REFERENCE" && echo true || echo false)
DIST_IS_HDR=$(is_hdr "$DISTORTED" && echo true || echo false)

echo "Reference is HDR: $REF_IS_HDR"
echo "Distorted is HDR: $DIST_IS_HDR"

# Select VMAF model based on reference resolution
if [ "$REF_HEIGHT" -gt 1080 ]; then
    MODEL="$VMAF_4K_MODEL"
    echo "4K video detected, using 4K VMAF model"
else
    MODEL="$VMAF_MODEL"
    echo "HD/FHD video detected, using standard VMAF model"
fi

# Prepare HDR conversion parameters
if [ "$REF_IS_HDR" = true ] || [ "$DIST_IS_HDR" = true ]; then
    # HDR to SDR conversion parameters
    HDR_TO_SDR_FILTER="zscale=t=linear:npl=100,tonemap=tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv"
else
    HDR_TO_SDR_FILTER=""
fi

# Prepare the filter chain
if [ "$NO_DENOISE" = true ]; then
    if [ "$REF_IS_HDR" = true ]; then
        REF_PROCESS="${HDR_TO_SDR_FILTER}${CROP_FILTER:+,$CROP_FILTER}"
        echo "HDR to SDR conversion enabled for reference video (no denoise)"
    else
        REF_PROCESS="${CROP_FILTER:-null}"
        echo "SDR reference video detected (no denoise)"
    fi
else
    if [ "$REF_IS_HDR" = true ]; then
        REF_PROCESS="${HDR_TO_SDR_FILTER}${CROP_FILTER:+,$CROP_FILTER},hqdn3d=4:3:6:4"
        echo "HDR to SDR conversion enabled for reference video (with denoise)"
    else
        REF_PROCESS="${CROP_FILTER:+$CROP_FILTER,}hqdn3d=4:3:6:4"
        echo "SDR reference video detected (with denoise)"
    fi
fi

# Prepare input video filter
if [ "$DIST_IS_HDR" = true ]; then
    FILTER_CHAIN="[0:v]${HDR_TO_SDR_FILTER},fps=${REF_FPS}:round=near[main2];[1:v]${REF_PROCESS},fps=${REF_FPS}:round=near[main1];[main2][main1]libvmaf=model=$MODEL:log_fmt=json:log_path=${PREFIX}.json:n_threads=4:n_subsample=8"
    echo "HDR to SDR conversion enabled for distorted video"
else
    FILTER_CHAIN="[0:v]fps=${REF_FPS}:round=near[main2];[1:v]${REF_PROCESS},fps=${REF_FPS}:round=near[main1];[main2][main1]libvmaf=model=$MODEL:log_fmt=json:log_path=${PREFIX}.json:n_threads=4:n_subsample=8"
    echo "SDR distorted video detected"
fi

# Function to validate VMAF scores
validate_vmaf() {
    local json_file="$1"
    local min_vmaf=$(jq '.pooled_metrics.vmaf.min' "$json_file")
    local max_vmaf=$(jq '.pooled_metrics.vmaf.max' "$json_file")
    local mean_vmaf=$(jq '.pooled_metrics.vmaf.mean' "$json_file")
    
    if (( $(echo "$mean_vmaf < 10" | bc -l) )); then
        echo "Error: Mean VMAF score ($mean_vmaf) is suspiciously low. Possible frame sync issue."
        return 1
    fi
    
    if (( $(echo "$max_vmaf < 20" | bc -l) )); then
        echo "Error: Max VMAF score ($max_vmaf) is suspiciously low. Possible frame sync issue."
        return 1
    fi
    
    return 0
}

# Generate VMAF scores and save to JSON
ffmpeg -hide_banner -loglevel error -i "$DISTORTED" -i "$REFERENCE" -lavfi "${FILTER_CHAIN}" -f null -

# Check if ffmpeg command was successful
if [ $? -eq 0 ]; then
    echo "VMAF analysis complete. JSON file saved as ${PREFIX}.json"
    
    # Validate VMAF scores
    if ! validate_vmaf "${PREFIX}.json"; then
        exit 1
    fi
    
    # Generate plot using vmaf-plot command
    if ! command -v vmaf-plot >/dev/null 2>&1; then
        echo "Error: vmaf-plot command not found. Please ensure vmaf-tools is installed correctly."
        exit 1
    fi
    
    echo "Running: vmaf-plot \"${PREFIX}.json\" -m VMAF -o \"${PREFIX}_plot.png\""
    # Run vmaf-plot with error output visible
    if ! vmaf-plot "${PREFIX}.json" -m VMAF -o "${PREFIX}_plot.png"; then
        echo "Error: Failed to generate plot"
        echo "vmaf-plot command failed with exit code $?"
        exit 1
    fi
    
    # Verify plot was actually created
    if [ ! -f "${PREFIX}_plot.png" ]; then
        echo "Error: Plot file was not created at ${PREFIX}_plot.png"
        echo "Current directory: $(pwd)"
        echo "Output directory: $OUTPUT_DIR"
        echo "Full path: ${PREFIX}_plot.png"
        exit 1
    fi
    
    echo "Plot generated successfully as ${PREFIX}_plot.png"
else
    echo "Error during VMAF analysis"
    exit 1
fi

# Calculate and display elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "Total execution time: $((ELAPSED / 60)) minutes and $((ELAPSED % 60)) seconds"
