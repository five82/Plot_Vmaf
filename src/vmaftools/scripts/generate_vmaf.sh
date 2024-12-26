#!/bin/bash

# Add this near the beginning of the script, after the shebang line
START_TIME=$(date +%s)

# Initialize logging flag
ENABLE_LOG=false

# Check for required Homebrew dependencies
BREW_DEPS=("ffmpeg" "gawk")
MISSING_DEPS=()

# Parse optional parameters
while [[ $# -gt 0 ]]; do
    case $1 in
        --denoise)
            NO_DENOISE=false
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --log)
            ENABLE_LOG=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Setup logging if enabled
if [ "$ENABLE_LOG" = true ]; then
    LOG_FILE="vmaf_$(date +%Y%m%d_%H%M%S).log"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    echo "Starting VMAF analysis at $(date)"
    echo "Log file: $LOG_FILE"
fi

if [ "$#" -lt 2 ]; then
    echo "Usage: generate-vmaf [options] <reference_video> <distorted_video> [output_prefix]"
    echo ""
    echo "Examples:"
    echo "  # Basic usage (no denoising)"
    echo "  generate-vmaf reference.mp4 distorted.mp4"
    echo ""
    echo "  # With output directory and prefix"
    echo "  generate-vmaf --output-dir ~/results reference.mp4 distorted.mp4 my_analysis"
    echo ""
    echo "Options:"
    echo "  --denoise        Enable denoising of reference video"
    echo "  --output-dir     Specify output directory for results (default: current directory)"
    echo "  --log            Enable logging to file"
    echo ""
    echo "Arguments:"
    echo "  reference_video  Original/reference video file"
    echo "  distorted_video Encoded/processed video file to compare"
    echo "  output_prefix   Optional prefix for output files (default: vmaf_analysis)"
    echo ""
    echo "Outputs:"
    echo "  - JSON file with VMAF and XPSNR metrics"
    echo "  - VMAF score plot"
    echo "  - XPSNR score plot"
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

# Check if distorted video is larger than reference - likely wrong order
if [ "$DIST_HEIGHT" -gt "$REF_HEIGHT" ]; then
    echo "Error: Distorted video height (${DIST_HEIGHT}) is larger than reference video height (${REF_HEIGHT})"
    echo "This likely means the reference and distorted videos were provided in the wrong order."
    echo "Usage: generate-vmaf [options] <reference_video> <distorted_video>"
    echo "The reference video should typically be the higher quality/resolution version."
    exit 1
fi

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

# Select VMAF model based on reference resolution
if [ "$REF_HEIGHT" -gt 1080 ]; then
    MODEL="$VMAF_4K_MODEL"
else
    MODEL="$VMAF_MODEL"
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
    else
        REF_PROCESS="${CROP_FILTER:-null}"
    fi
else
    if [ "$REF_IS_HDR" = true ]; then
        REF_PROCESS="${HDR_TO_SDR_FILTER}${CROP_FILTER:+,$CROP_FILTER},hqdn3d=4:3:6:4"
    else
        REF_PROCESS="${CROP_FILTER:+$CROP_FILTER,}hqdn3d=4:3:6:4"
    fi
fi

# Prepare input video filter - split into two commands
# First command for VMAF
if [ "$DIST_IS_HDR" = true ]; then
    VMAF_FILTER="[0:v]${HDR_TO_SDR_FILTER},fps=${REF_FPS}:round=near[main2];[1:v]${REF_PROCESS},fps=${REF_FPS}:round=near[main1];[main2][main1]libvmaf=model=$MODEL:log_fmt=json:log_path=${PREFIX}.json:n_threads=4:n_subsample=8"
else
    VMAF_FILTER="[0:v]fps=${REF_FPS}:round=near[main2];[1:v]${REF_PROCESS},fps=${REF_FPS}:round=near[main1];[main2][main1]libvmaf=model=$MODEL:log_fmt=json:log_path=${PREFIX}.json:n_threads=4:n_subsample=8"
fi

# Second command for XPSNR
if [ "$DIST_IS_HDR" = true ]; then
    XPSNR_FILTER="[0:v]fps=${REF_FPS}:round=near,format=yuv420p10le[main2];[1:v]${REF_PROCESS:+$REF_PROCESS,}fps=${REF_FPS}:round=near,format=yuv420p10le[main1];[main2][main1]xpsnr=stats_file=${PREFIX}_xpsnr.log"
else
    XPSNR_FILTER="[0:v]fps=${REF_FPS}:round=near,format=yuv420p[main2];[1:v]${REF_PROCESS},fps=${REF_FPS}:round=near,format=yuv420p[main1];[main2][main1]xpsnr=stats_file=${PREFIX}_xpsnr.log"
fi

# Generate VMAF scores and save to JSON
ffmpeg -hide_banner -loglevel error -i "$DISTORTED" -i "$REFERENCE" -lavfi "${VMAF_FILTER}" -f null -

# Generate XPSNR scores
if ! ffmpeg -hide_banner -i "$DISTORTED" -i "$REFERENCE" -lavfi "${XPSNR_FILTER}" -f null -; then
    echo "Error: XPSNR calculation failed"
    exit 1
fi

# Check for GNU awk
if ! command -v gawk >/dev/null 2>&1; then
    echo "Error: gawk (GNU awk) is required but not installed"
    echo "Install it with: brew install gawk"
    exit 1
fi

# Convert XPSNR log to JSON
if ! gawk '
BEGIN { 
    print "{"
    print "\"frames\": ["
    first = 1
    n = 0
}
/n:[[:space:]]*[0-9]+[[:space:]]*XPSNR/ {
    # Skip the summary line
    if ($0 ~ /XPSNR average/) {
        next
    }

    # Extract frame number and XPSNR values
    match($0, /n:[[:space:]]*([0-9]+)[[:space:]]*XPSNR[[:space:]]*y:[[:space:]]*([0-9.inf]+)[[:space:]]*XPSNR[[:space:]]*u:[[:space:]]*([0-9.inf]+)[[:space:]]*XPSNR[[:space:]]*v:[[:space:]]*([0-9.inf]+)/, arr)
    if (arr[1] == "" || arr[2] == "" || arr[3] == "" || arr[4] == "") {
        print "Error parsing line: " $0 > "/dev/stderr"
        exit 1
    }

    # Skip frames with inf values
    if (arr[2] == "inf" || arr[3] == "inf" || arr[4] == "inf") {
        next
    }
    
    if (!first) print ","
    first = 0
    
    # Calculate weighted average XPSNR (6:1:1 ratio for Y:U:V)
    xpsnr = (6 * arr[2] + arr[3] + arr[4]) / 8
    
    printf "{\"frameNum\": %d, \"metrics\": {\"xpsnr\": %.6f, \"xpsnr_y\": %.6f, \"xpsnr_u\": %.6f, \"xpsnr_v\": %.6f}}", \
           arr[1], xpsnr, arr[2], arr[3], arr[4]
    n++
}
END {
    if (n == 0) {
        print "Error: No valid XPSNR data found" > "/dev/stderr"
        exit 1
    }
    print "]}" 
}' "${PREFIX}_xpsnr.log" > "${PREFIX}_xpsnr.json"; then
    echo "Error: Failed to convert XPSNR log to JSON"
    echo "XPSNR log contents:"
    head -n 5 "${PREFIX}_xpsnr.log"
    echo "..."
    tail -n 5 "${PREFIX}_xpsnr.log"
    exit 1
fi

# Validate XPSNR JSON
if ! jq empty "${PREFIX}_xpsnr.json" 2>/dev/null; then
    echo "Error: Invalid XPSNR JSON generated"
    exit 1
fi

# Merge VMAF and XPSNR data
if ! jq -s '
def merge_frames:
  if length == 2 then
    .[0].metrics + .[1].metrics
  else
    .[0].metrics
  end;

.[0] as $vmaf | .[1] as $xpsnr |
$vmaf | .frames = [range(0; ($vmaf.frames | length)) as $i |
  {
    "frameNum": $i,
    "metrics": (
      if $i < ($xpsnr.frames | length) then
        [$vmaf.frames[$i], $xpsnr.frames[$i]] | merge_frames
      else
        $vmaf.frames[$i].metrics
      end
    )
  }
]
' "${PREFIX}.json" "${PREFIX}_xpsnr.json" > "${PREFIX}_combined.json"; then
    echo "Error: Failed to merge VMAF and XPSNR data"
    exit 1
fi

# Debug: Print the first few frames of each JSON file
echo "First frame from VMAF JSON:"
jq '.frames[0]' "${PREFIX}.json"
echo "First frame from XPSNR JSON:"
jq '.frames[0]' "${PREFIX}_xpsnr.json"
echo "First frame from combined JSON:"
jq '.frames[0]' "${PREFIX}_combined.json"

# Count frames in each file
echo "Frame counts:"
echo "VMAF frames: $(jq '.frames | length' "${PREFIX}.json")"
echo "XPSNR frames: $(jq '.frames | length' "${PREFIX}_xpsnr.json")"
echo "Combined frames: $(jq '.frames | length' "${PREFIX}_combined.json")"

# Check if XPSNR metrics exist in combined file
echo "XPSNR frames in combined file:"
jq '.frames | map(select(.metrics.xpsnr != null)) | length' "${PREFIX}_combined.json"

# Validate the combined JSON
if ! jq empty "${PREFIX}_combined.json" 2>/dev/null; then
    echo "Error: Invalid combined JSON generated"
    exit 1
fi

# Move combined JSON to final location
mv "${PREFIX}_combined.json" "${PREFIX}.json"
rm -f "${PREFIX}_xpsnr.json" "${PREFIX}_xpsnr.log"

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

# Validate XPSNR calculation
validate_xpsnr() {
    local json_file="$1"
    local is_hdr="$2"
    local frame_count=$(jq '.frames | length' "$json_file")
    local xpsnr_count=$(jq '[.frames[].metrics.xpsnr] | length' "$json_file")
    
    echo "Analyzing XPSNR values..."
    echo "Total frames: $frame_count"
    echo "Frames with XPSNR: $xpsnr_count"
    
    if [ "$xpsnr_count" -lt "$((frame_count * 9 / 10))" ]; then
        echo "Error: Not enough XPSNR frames ($xpsnr_count) compared to total frames ($frame_count)"
        return 1
    fi
    
    # Get XPSNR statistics
    local min_y=$(jq '[.frames[].metrics.xpsnr_y] | min' "$json_file")
    local max_y=$(jq '[.frames[].metrics.xpsnr_y] | max' "$json_file")
    local avg_y=$(jq '[.frames[].metrics.xpsnr_y] | add/length' "$json_file")
    
    echo "XPSNR Y-component statistics:"
    echo "  Minimum: $min_y"
    echo "  Maximum: $max_y"
    echo "  Average: $avg_y"
    
    # Adjust ranges based on content type
    local min_threshold=25
    local max_threshold=60
    
    # Check for reasonable ranges in Y component with adjusted thresholds
    local invalid_y=$(jq "[.frames[].metrics.xpsnr_y | select(. < $min_threshold or . > $max_threshold)] | length" "$json_file")
    if [ "$invalid_y" -gt "$((frame_count / 10))" ]; then
        echo "Warning: $invalid_y frames have Y values outside expected range ($min_threshold-$max_threshold)"
        echo "This might be normal for some content. Continuing anyway..."
    fi
    
    return 0
}

# Validate both metrics after merging
if ! validate_vmaf "${PREFIX}.json" || ! validate_xpsnr "${PREFIX}.json" "$DIST_IS_HDR"; then
    exit 1
fi

# Generate plots
echo "Attempting to generate plots..."

# Generate VMAF plot
if ! vmaf-plot "${PREFIX}.json" -m VMAF -o "${PREFIX}_vmaf_plot.png"; then
    echo "Error: Failed to generate VMAF plot"
    exit 1
fi

# Generate XPSNR plot
if ! vmaf-plot "${PREFIX}.json" -m XPSNR -o "${PREFIX}_xpsnr_plot.png"; then
    echo "Error: Failed to generate XPSNR plot"
    exit 1
fi

echo "Plots generated successfully:"
echo "- VMAF plot: ${PREFIX}_vmaf_plot.png"
echo "- XPSNR plot: ${PREFIX}_xpsnr_plot.png"

# Calculate and display elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))
echo "Total execution time: ${MINUTES} minutes and ${SECONDS} seconds"

# Add after the merge:
VMAF_FRAMES=$(jq '.frames | length' "${PREFIX}.json")
XPSNR_FRAMES=$(jq '.frames | map(select(.metrics.xpsnr != null)) | length' "${PREFIX}.json")

if [ "$XPSNR_FRAMES" -eq 0 ]; then
    echo "Error: No XPSNR data was merged into the final JSON"
    exit 1
fi

# Function to validate frame synchronization
validate_frame_sync() {
    local json_file="$1"
    local prev_frame=-1
    local gaps=0
    local max_gap=0
    
    # Read frame numbers into array for faster processing
    local frame_nums=($(jq -r '.frames[].frameNum' "$json_file"))
    local total_frames=${#frame_nums[@]}
    
    for frame in "${frame_nums[@]}"; do
        if [ "$prev_frame" -ne -1 ]; then
            local gap=$((frame - prev_frame))
            if [ "$gap" -ne 1 ]; then
                gaps=$((gaps + 1))
                if [ "$gap" -gt "$max_gap" ]; then
                    max_gap=$gap
                fi
            fi
        fi
        prev_frame=$frame
    done
    
    if [ "$gaps" -gt 0 ]; then
        if [ "$gaps" -gt "$((total_frames / 10))" ]; then
            echo "Error: Too many frame gaps detected. Possible sync issue."
            return 1
        fi
    fi
    
    return 0
}

# Function to validate metric values
validate_metrics() {
    local json_file="$1"
    local content_type="${2:-standard}" # standard, animation, film, etc.
    
    # Adjust thresholds based on content type
    case "$content_type" in
        animation)
            local vmaf_min=70
            local vmaf_max=100
            local xpsnr_min=30
            local xpsnr_max=65
            ;;
        film)
            local vmaf_min=60
            local vmaf_max=100
            local xpsnr_min=25
            local xpsnr_max=65  # Increased max XPSNR
            ;;
        *)  # standard thresholds
            local vmaf_min=50
            local vmaf_max=100
            local xpsnr_min=25
            local xpsnr_max=65  # Increased max XPSNR
            ;;
    esac
    
    # Get total frame count
    local total_frames=$(jq '.frames | length' "$json_file")
    
    # Check for invalid values (NaN, null, wrong type)
    local invalid_count=$(jq "[.frames[] | select(
        (.metrics.vmaf | type != \"number\") or
        (.metrics.xpsnr | type != \"number\") or
        (.metrics.vmaf | isnan) or
        (.metrics.xpsnr | isnan) or
        (.metrics.vmaf == null) or
        (.metrics.xpsnr == null)
    )] | length" "$json_file")
    
    if [ "$invalid_count" -gt 0 ]; then
        echo "Error: Found $invalid_count frames with invalid metric values"
        return 1
    fi
    
    # Validate metric ranges with more lenient thresholds
    local out_of_range=$(jq "[.frames[] | select(
        .metrics.vmaf < $vmaf_min or
        .metrics.vmaf > $vmaf_max or
        .metrics.xpsnr < $xpsnr_min or
        .metrics.xpsnr > $xpsnr_max
    )] | length" "$json_file")
    
    if [ "$out_of_range" -gt 0 ]; then
        local percent_out=$((out_of_range * 100 / total_frames))
        if [ "$percent_out" -gt 10 ]; then
            echo "Error: Too many frames ($percent_out%) with out-of-range values"
            return 1
        else
            return 0
        fi
    fi
    
    return 0
}

# Add these calls before generating plots
if ! validate_frame_sync "${PREFIX}.json"; then
    echo "Error: Frame synchronization validation failed"
    exit 1
fi

if ! validate_metrics "${PREFIX}.json" "${CONTENT_TYPE:-standard}"; then
    echo "Error: Metric validation failed"
    exit 1
fi
