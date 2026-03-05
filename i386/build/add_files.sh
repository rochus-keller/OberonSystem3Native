#!/bin/bash

# Ensure both arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image_name> <directory_path>"
    exit 1
fi

IMAGE_NAME="$1"
TARGET_DIR="$2"

# Check if the tool exists and is executable
if [ ! -x "../toolchain/aosfstool" ]; then
    echo "Error: ../toolchain/aosfstool not found or not executable."
    exit 1
fi

# Check if the directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' not found."
    exit 1
fi

../toolchain/aosfstool new "$IMAGE_NAME" 45

# Use nullglob to prevent the loop from running if no files are found
shopt -s nullglob

# Iterate through every file in the directory
for FILE in "$TARGET_DIR"/*; do
    # Check if the current path is a regular file
    if [ -f "$FILE" ]; then
        ../toolchain/aosfstool add "$IMAGE_NAME" "$FILE"
    fi
done

