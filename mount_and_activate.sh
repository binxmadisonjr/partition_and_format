#!/bin/bash

# ====================================================
# Swap Activation and Partition Mounting Script
# ====================================================
#
# Description:
#   Activates the swap partition and mounts the root,
#   EFI, and any additional custom partitions.
#
# Usage:
#   sudo ./mount_and_activate.sh
#
# Author: binxmadisonjr
# License: MIT
# ====================================================

set -e
set -o pipefail

# ------------------------------
# Color Definitions for Output
# ------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ------------------------------
# Logging Setup
# ------------------------------
LOG_FILE="../logs/mount_and_activate_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Ensure logs directory exists
mkdir -p ../logs

# ------------------------------
# FUNCTIONS
# ------------------------------

# Function to prompt yes/no questions
# Arguments:
#   $1 - Prompt message
#   $2 - Default answer ("yes" or "no")
# Returns:
#   0 for yes, 1 for no
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    if [[ "$default" == "yes" ]]; then
        prompt+=" [Y/n]: "
    elif [[ "$default" == "no" ]]; then
        prompt+=" [y/N]: "
    else
        prompt+=" [y/n]: "
    fi

    while true; do
        read -rp "$(echo -e "${YELLOW}$prompt${NC}")" response
        response=${response,,} # to lowercase

        if [[ -z "$response" ]]; then
            response="$default"
        fi

        case "$response" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                echo -e "${RED}Please answer yes or no.${NC}"
                ;;
        esac
    done
}

# Function to activate swap
activate_swap() {
    local swap_partition="$1"
    log "${BLUE}Activating swap partition (${swap_partition})...${NC}"
    sudo mkswap "$swap_partition" | tee -a "$LOG_FILE"
    sudo swapon "$swap_partition" | tee -a "$LOG_FILE"
    log "${GREEN}Swap partition activated.${NC}"
}

# Function to create mount points
create_mount_points() {
    local root_mount="$1"
    log "${BLUE}Creating mount points under ${root_mount}...${NC}"
    sudo mkdir -p "$root_mount"
    sudo mkdir -p "${root_mount}/efi"

    # Create additional mount points if needed
    if [[ -n "$CUSTOM_MOUNT_POINTS" ]]; then
        for mount_point in "${CUSTOM_MOUNT_POINTS[@]}"; do
            sudo mkdir -p "${root_mount}${mount_point}"
            log "${GREEN}Created mount point: ${root_mount}${mount_point}${NC}"
        done
    fi
}

# Function to mount partitions
mount_partitions() {
    local root_partition="$1"
    local efi_partition="$2"
    shift 2
    local custom_partitions=("$@")

    log "${BLUE}Mounting root partition (${root_partition}) to /mnt/gentoo...${NC}"
    sudo mount "$root_partition" /mnt/gentoo | tee -a "$LOG_FILE"

    log "${BLUE}Mounting EFI partition (${efi_partition}) to /mnt/gentoo/efi...${NC}"
    sudo mount "$efi_partition" /mnt/gentoo/efi | tee -a "$LOG_FILE"

    # Mount custom partitions if any
    if [[ ${#custom_partitions[@]} -gt 0 ]]; then
        local index=0
        for partition in "${custom_partitions[@]}"; do
            local mount_point="${CUSTOM_MOUNT_POINTS[$index]}"
            log "${BLUE}Mounting custom partition (${partition}) to ${mount_point}...${NC}"
            sudo mount "$partition" "/mnt/gentoo${mount_point}" | tee -a "$LOG_FILE"
            ((index++))
        done
    fi
}

# Function to set permissions
set_permissions() {
    local root_mount="$1"
    log "${BLUE}Setting permissions for /mnt/gentoo/tmp and /mnt/gentoo/var/tmp...${NC}"
    sudo chmod 1777 "${root_mount}/tmp"
    sudo chmod 1777 "${root_mount}/var/tmp" || true
    log "${GREEN}Permissions set.${NC}"
}

# ------------------------------
# MAIN SCRIPT
# ------------------------------

# Check if the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Please run this script with sudo or as root.${NC}"
    exit 1
fi

# Prompt user for partition details
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}  SWAP ACTIVATION AND MOUNTING SCRIPT${NC}"
echo -e "${GREEN}=====================================${NC}"
echo

# Prompt for swap partition
read -rp "$(echo -e "${YELLOW}Enter the swap partition (e.g., /dev/sda2): ${NC}")" SWAP_PARTITION

# Prompt for root partition
read -rp "$(echo -e "${YELLOW}Enter the root partition (e.g., /dev/sda3): ${NC}")" ROOT_PARTITION

# Prompt for EFI partition
read -rp "$(echo -e "${YELLOW}Enter the EFI partition (e.g., /dev/sda1): ${NC}")" EFI_PARTITION

# Prompt for custom partitions (optional)
if ask_yes_no "Do you have custom partitions to mount?" "no"; then
    declare -a CUSTOM_PARTITIONS
    declare -a CUSTOM_MOUNT_POINTS
    local add_custom=true
    local count=1

    while $add_custom; do
        read -rp "$(echo -e "${YELLOW}Enter custom partition ${count} (e.g., /dev/sda4): ${NC}")" CUSTOM_PART
        read -rp "$(echo -e "${YELLOW}Enter mount point for ${CUSTOM_PART} (e.g., /home, /var): ${NC}")" CUSTOM_MOUNT
        CUSTOM_PARTITIONS+=("$CUSTOM_PART")
        CUSTOM_MOUNT_POINTS+=("$CUSTOM_MOUNT")
        ((count++))
        if ! ask_yes_no "Add another custom partition?" "no"; then
            add_custom=false
        fi
    done
fi

# Confirm the details
echo
log "${YELLOW}=====================================${NC}"
log "${YELLOW}SUMMARY:${NC}"
log "Swap Partition: ${SWAP_PARTITION}"
log "Root Partition: ${ROOT_PARTITION}"
log "EFI Partition: ${EFI_PARTITION}"
if [[ ${#CUSTOM_PARTITIONS[@]} -gt 0 ]]; then
    for i in "${!CUSTOM_PARTITIONS[@]}"; do
        log "Custom Partition ${i+1}: ${CUSTOM_PARTITIONS[$i]} mounted at ${CUSTOM_MOUNT_POINTS[$i]}"
    done
fi
log "${YELLOW}=====================================${NC}"
echo

if ask_yes_no "Proceed with activating and mounting partitions?" "yes"; then
    log "${GREEN}Proceeding...${NC}"
else
    log "${RED}Aborted by user.${NC}"
    exit 1
fi

# Activate swap
activate_swap "$SWAP_PARTITION"

# Create mount points
if [[ -n "$CUSTOM_MOUNT_POINTS" ]]; then
    create_mount_points "/mnt/gentoo"
else
    create_mount_points "/mnt/gentoo"
fi

# Mount partitions
if [[ ${#CUSTOM_PARTITIONS[@]} -gt 0 ]]; then
    mount_partitions "$ROOT_PARTITION" "$EFI_PARTITION" "${CUSTOM_PARTITIONS[@]}"
else
    mount_partitions "$ROOT_PARTITION" "$EFI_PARTITION"
fi

# Set permissions
set_permissions "/mnt/gentoo"

log "${GREEN}Swap activated and partitions mounted successfully!${NC}"
lsblk /mnt/gentoo | tee -a "$LOG_FILE"
