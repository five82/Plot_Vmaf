# VMAF Tools

A collection of tools for video quality analysis using VMAF and XPSNR metrics.

Designed for macOS systems.

![Example VMAF Plot](plot.png)

## Features

- Generate VMAF and XPSNR scores for video comparisons
- Support for HDR to SDR conversion
- Automatic reference video cropping
- Optional denoising for noisy sources
- Frame synchronization validation
- Metric range validation
- Generate visualization plots
- Optional logging for debugging

## System Requirements

### macOS Dependencies
Install all required dependencies using Homebrew:
```bash
brew install ffmpeg libvmaf gawk jq python python-matplotlib numpy
```

FFmpeg must be compiled with libvmaf and xpsnr support. The Homebrew version of FFmpeg is compiled against libvmaf by default.

To verify FFmpeg has the required support:
```bash
ffmpeg -filters | grep -E 'libvmaf|xpsnr'
```
You should see both filters listed in the output.

## Installation

Clone and install locally:
```bash
git clone https://github.com/five82/Plot_Vmaf.git
cd Plot_Vmaf
pipx install -e .
```

## Uninstall
```bash
# If installed with -e flag
pipx uninstall vmaf-tools

# Remove cloned directory
cd ..
rm -rf Plot_Vmaf
```

## Usage

```bash
generate-vmaf [options] <reference_video> <distorted_video> [output_prefix]
```

### Options

```
--denoise        Enable denoising of reference video
--output-dir     Specify output directory for results (default: current directory)
--log            Enable logging to file
```

### Arguments

```
reference_video  Original/reference video file
distorted_video Encoded/processed video file to compare
output_prefix   Optional prefix for output files (default: vmaf_analysis)
```

### Examples

```bash
# Basic usage
generate-vmaf reference.mp4 distorted.mp4

# With output directory and custom prefix
generate-vmaf --output-dir ~/results reference.mp4 distorted.mp4 my_analysis

# With logging enabled
generate-vmaf --log reference.mp4 distorted.mp4
```

### Outputs

The script generates:
- JSON file with VMAF and XPSNR metrics
- VMAF score plot
- XPSNR score plot

## Features in Detail

### HDR Support
- Automatic HDR detection
- HDR to SDR conversion for VMAF analysis
- Native HDR support for XPSNR analysis

### Validation
- Frame synchronization checks
- Metric range validation
- Configurable thresholds for different content types

### Plotting
- VMAF score visualization
- XPSNR score visualization
- Statistical annotations

Example plot showing VMAF scores over time with statistical annotations:

![Example VMAF Plot](plot.png)

## Development

To contribute:

1. Clone the repository
2. Install development dependencies
3. Make your changes
4. Submit a pull request