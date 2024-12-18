#!/bin/bash

# ====================================================
# Interactive Partition & Format Tool
# ====================================================
#
# WARNING: This tool will overwrite the selected disk!
# Press Ctrl+C at any time to abort.
#
# Description:
#   An interactive bash script to partition and format disks.
#   Supports EFI, Swap, Root, Home, and custom partitions with customizable sizes and filesystems.
#
# Author: Your Name
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
LOG_FILE="partition_tool_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# ------------------------------
# Dependency Check
# ------------------------------
DEPENDENCIES=(lsblk sgdisk mkfs.fat mkswap mkfs.ext4 mkfs.xfs mkfs.btrfs partprobe wipefs)

for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        log "${RED}Error:${NC} Required command '$cmd' is not installed."
        exit 1
    fi
done

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

# Function to select a disk
select_disk() {
    log "${BLUE}Available drives:${NC}"
    log ""

    # Identify the system disk to exclude it
    CURRENT_DISK=$(lsblk -d -p -n -o NAME | grep -E "^/dev/[a-z]+$" | head -n1)

    # List disks excluding the current system disk
    mapfile -t DISKS < <(lsblk -d -p -n -o NAME,SIZE,TYPE | grep 'disk' | grep -v "$CURRENT_DISK")

    if [[ ${#DISKS[@]} -eq 0 ]]; then
        log "${RED}No available disks found (excluding system disk). Exiting.${NC}"
        exit 1
    fi

    # Display formatted list of disks
    for i in "${!DISKS[@]}"; do
        disk_info=(${DISKS[$i]})
        disk_name="${disk_info[0]}"
        disk_size="${disk_info[1]}"
        disk_type="${disk_info[2]}"
        printf " ${GREEN}%d)${NC} %-20s Size: %-10s Type: %s\n" "$((i + 1))" "$disk_name" "$disk_size" "$disk_type"
    done

    while true; do
        read -rp "$(echo -e "${YELLOW}Select a disk by number (or 'q' to quit): ${NC}")" disk_choice
        if [[ "$disk_choice" == "q" || "$disk_choice" == "Q" ]]; then
            log "${RED}Aborted by user.${NC}"
            exit 0
        fi
        if [[ $disk_choice =~ ^[0-9]+$ ]] && (( disk_choice >= 1 && disk_choice <= ${#DISKS[@]} )); then
            DISK=$(echo "${DISKS[$((disk_choice - 1))]}" | awk '{print $1}')
            log "${GREEN}Selected disk:${NC} $DISK"

            # Check if any partitions are mounted
            if mount | grep "^$DISK" &>/dev/null; then
                log "${RED}Warning: The selected disk has mounted partitions.${NC}"
                if ! ask_yes_no "Are you sure you want to continue?" "no"; then
                    log "${RED}Aborted by user.${NC}"
                    exit 1
                fi
            fi
            break
        else
            log "${RED}Invalid choice. Please select a valid number or 'q' to quit.${NC}"
        fi
    done
}

# Prompt for filesystem selection with extended options
select_filesystem() {
    local fs_choice
    while true; do
        echo -e "${BLUE}Choose a filesystem type:${NC}" >&2
        echo -e "  ${GREEN}1)${NC} ext4   (common default, stable, widely supported)" >&2
        echo -e "  ${GREEN}2)${NC} xfs    (high performance, good for large storage)" >&2
        echo -e "  ${GREEN}3)${NC} btrfs  (advanced features, snapshots)" >&2
        echo -e "  ${GREEN}4)${NC} fat32  (required for EFI partitions)" >&2
        echo -e "  ${GREEN}5)${NC} ntfs   (Windows compatibility)" >&2
        echo -e "  ${GREEN}6)${NC} exfat  (cross-platform compatibility)" >&2
        read -rp "$(echo -e "${YELLOW}Enter your choice (1-6) [default: 1]: ${NC}")" fs_choice

        # Default to '1' (ext4) if nothing entered
        [[ -z "$fs_choice" ]] && fs_choice=1

        case $fs_choice in
            1) echo "ext4"; return 0 ;;
            2) echo "xfs"; return 0 ;;
            3) echo "btrfs"; return 0 ;;
            4) echo "fat32"; return 0 ;;
            5) echo "ntfs"; return 0 ;;
            6) echo "exfat"; return 0 ;;
            *)
                echo -e "${RED}Invalid choice. Please enter a number between 1 and 6.${NC}" >&2
                ;;
        esac
    done
}

# Validate partition size format
validate_size() {
    local size="$1"
    if ! [[ "$size" =~ ^[0-9]+[MG]$ ]]; then
        echo -e "${RED}Invalid size format. Use numbers followed by M or G (e.g., 512M, 8G).${NC}"
        return 1
    fi
    return 0
}

# Function to add custom partitions
add_custom_partition() {
    local partition_number=$1
    local partition_name partition_size partition_type filesystem_type

    read -rp "$(echo -e "${YELLOW}Enter name for partition $partition_number (e.g., /var, /tmp): ${NC}")" partition_name
    while true; do
        read -rp "$(echo -e "${YELLOW}Enter size for $partition_name (e.g., 10G, 500M, or '0' for remaining space): ${NC}")" partition_size
        if [[ "$partition_size" == "0" ]] || validate_size "$partition_size"; then
            break
        else
            echo -e "${RED}Invalid size format.${NC}"
        fi
    done

    echo -e "${BLUE}Select filesystem for $partition_name:${NC}"
    filesystem_type=$(select_filesystem)

    CUSTOM_PARTITIONS+=("$partition_name:$partition_size:$filesystem_type")
}

# Ask for partition details
get_partition_details() {
    echo -e "${BLUE}Specify partition sizes (with unit, e.g. 512M or 8G).${NC}"
    echo -e "${BLUE}Press Enter to use defaults where shown.${NC}"
    echo

    # EFI
    while true; do
        read -rp "$(echo -e "${YELLOW}EFI partition size [default: 512M]: ${NC}")" EFI_SIZE
        [[ -z "$EFI_SIZE" ]] && EFI_SIZE="512M"
        validate_size "$EFI_SIZE" && break
    done
    log "${GREEN}Using fat32 for EFI.${NC}"
    EFI_FS_TYPE="fat32"

    # Swap
    while true; do
        read -rp "$(echo -e "${YELLOW}Swap partition size [default: 8G]: ${NC}")" SWAP_SIZE
        [[ -z "$SWAP_SIZE" ]] && SWAP_SIZE="8G"
        validate_size "$SWAP_SIZE" && break
    done
    log "${GREEN}Using Swap for Swap.${NC}"
    SWAP_FS_TYPE="swap"

    # Root
    echo -e "${BLUE}Specify the size for the Root partition.${NC}" >&2
    echo -e "${BLUE}Enter '0' or leave blank to use all remaining space.${NC}" >&2
    while true; do
        read -rp "$(echo -e "${YELLOW}Root partition size [default: remaining space]: ${NC}")" ROOT_SIZE
        if [[ -z "$ROOT_SIZE" ]]; then
            ROOT_SIZE="0"
            log "${GREEN}Root partition will use the remaining space.${NC}"
            break
        elif [[ "$ROOT_SIZE" == "0" ]]; then
            ROOT_SIZE="0"
            log "${GREEN}Root partition will use the remaining space.${NC}"
            break
        elif validate_size "$ROOT_SIZE"; then
            break
        fi
    done

    echo -e "${BLUE}Filesystem for root partition:${NC}" >&2
    ROOT_FS_TYPE=$(select_filesystem)

    # Home
    if ask_yes_no "Create a separate home partition?" "no"; then
        while true; do
            read -rp "$(echo -e "${YELLOW}Home partition size (e.g., 50G): ${NC}")" HOME_SIZE
            if validate_size "$HOME_SIZE"; then
                break
            fi
        done
        echo -e "${BLUE}Filesystem for home partition:${NC}" >&2
        HOME_FS_TYPE=$(select_filesystem)
        CREATE_HOME="yes"
    else
        CREATE_HOME="no"
    fi

    # Custom Partitions
    if ask_yes_no "Do you want to add custom partitions?" "no"; then
        CUSTOM_PARTITIONS=()
        local part_num=1
        while true; do
            add_custom_partition "$part_num"
            ((part_num++))
            if ! ask_yes_no "Add another custom partition?" "no"; then
                break
            fi
        done
    fi
}

# Confirm settings with summary
summarize_and_confirm() {
    echo
    log "${YELLOW}=====================================${NC}"
    log "${YELLOW}SUMMARY:${NC}"
    log "Disk: $DISK"
    log "1. EFI partition: ${EFI_SIZE} (${EFI_FS_TYPE})"
    log "2. Swap partition: ${SWAP_SIZE} (${SWAP_FS_TYPE})"
    log "3. Root partition: ${ROOT_SIZE} (${ROOT_FS_TYPE})"
    if [[ "$CREATE_HOME" == "yes" ]]; then
        log "4. Home partition: ${HOME_SIZE} (${HOME_FS_TYPE})"
    fi
    if [[ ${#CUSTOM_PARTITIONS[@]} -gt 0 ]]; then
        local idx=5
        for part in "${CUSTOM_PARTITIONS[@]}"; do
            IFS=':' read -r name size fs <<< "$part"
            log "${idx}. $name partition: ${size} (${fs})"
            ((idx++))
        done
    fi
    log "${YELLOW}=====================================${NC}"
    echo

    if ask_yes_no "Proceed with these settings?" "yes"; then
        log "${GREEN}Proceeding...${NC}"
    else
        log "${RED}Aborted.${NC}"
        exit 1
    fi
}

# Function to display a spinner during long operations
format_with_spinner() {
    local cmd="$1"
    local description="$2"

    echo -e "${YELLOW}$description...${NC}"
    # Start spinner in background
    local pid
    local spinner='|/-\'
    local i=0
    eval "$cmd" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r${spinner:$i:1} $description"
        sleep .1
    done
    wait "$pid"
    echo -e "\r${GREEN}$description completed.${NC}"
}

# Partition the disk
partition_disk() {
    log "${BLUE}Partitioning disk: $DISK${NC}"

    # Wipe existing partition table
    log "${YELLOW}Wiping existing GPT data structures...${NC}"
    sgdisk --zap-all "$DISK" || { log "${RED}Failed to wipe disk.${NC}"; exit 1; }

    # Create EFI partition
    log "${YELLOW}Creating EFI partition...${NC}"
    sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI System" "$DISK" || { log "${RED}Failed to create EFI partition.${NC}"; exit 1; }

    # Create Swap partition
    log "${YELLOW}Creating Swap partition...${NC}"
    sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"Linux Swap" "$DISK" || { log "${RED}Failed to create Swap partition.${NC}"; exit 1; }

    # Create Root partition
    log "${YELLOW}Creating Root partition...${NC}"
    if [[ "$ROOT_SIZE" == "0" ]]; then
        sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux Root" "$DISK" || { log "${RED}Failed to create Root partition.${NC}"; exit 1; }
    else
        sgdisk -n 3:0:+${ROOT_SIZE} -t 3:8300 -c 3:"Linux Root" "$DISK" || { log "${RED}Failed to create Root partition.${NC}"; exit 1; }
    fi

    # Create Home partition if selected
    if [[ "$CREATE_HOME" == "yes" ]]; then
        log "${YELLOW}Creating Home partition...${NC}"
        sgdisk -n 4:0:+${HOME_SIZE} -t 4:8302 -c 4:"Linux Home" "$DISK" || { log "${RED}Failed to create Home partition.${NC}"; exit 1; }
    fi

    # Create Custom partitions
    if [[ ${#CUSTOM_PARTITIONS[@]} -gt 0 ]]; then
        local part_num=5
        for part in "${CUSTOM_PARTITIONS[@]}"; do
            IFS=':' read -r name size fs <<< "$part"
            log "${YELLOW}Creating $name partition...${NC}"
            if [[ "$size" == "0" ]]; then
                sgdisk -n "$part_num":0:0 -t "$part_num":8300 -c "$part_num":"Linux $name" "$DISK" || { log "${RED}Failed to create $name partition.${NC}"; exit 1; }
            else
                sgdisk -n "$part_num":0:+${size} -t "$part_num":8300 -c "$part_num":"Linux $name" "$DISK" || { log "${RED}Failed to create $name partition.${NC}"; exit 1; }
            fi
            ((part_num++))
        done
    fi

    # Refresh partition table
    log "${YELLOW}Refreshing partition table...${NC}"
    partprobe "$DISK" || { log "${RED}Failed to refresh partition table.${NC}"; exit 1; }
}

# Format the partitions with progress indicators
format_partitions() {
    log "${BLUE}Formatting partitions...${NC}"

    # Determine partition prefix (e.g., /dev/nvme0n1p)
    PART_PREFIX="${DISK}"
    if [[ "${DISK}" == *"nvme"* ]]; then
        PART_PREFIX="${DISK}p"
    fi

    # EFI
    format_with_spinner "wipefs -a ${PART_PREFIX}1 && mkfs.fat -F 32 ${PART_PREFIX}1" "Formatting EFI partition (${PART_PREFIX}1) as fat32"

    # Swap
    format_with_spinner "wipefs -a ${PART_PREFIX}2 && mkswap ${PART_PREFIX}2" "Setting up Swap partition (${PART_PREFIX}2)"

    # Root
    case "$ROOT_FS_TYPE" in
        ext4)
            format_with_spinner "wipefs -a ${PART_PREFIX}3 && mkfs.ext4 -F -L root ${PART_PREFIX}3" "Formatting Root partition (${PART_PREFIX}3) as ext4"
            ;;
        xfs)
            format_with_spinner "wipefs -a ${PART_PREFIX}3 && mkfs.xfs -f -L root ${PART_PREFIX}3" "Formatting Root partition (${PART_PREFIX}3) as xfs"
            ;;
        btrfs)
            format_with_spinner "wipefs -a ${PART_PREFIX}3 && mkfs.btrfs -f -L root ${PART_PREFIX}3" "Formatting Root partition (${PART_PREFIX}3) as btrfs"
            ;;
        fat32)
            log "${RED}EFI partition already formatted as fat32. Skipping Root formatting.${NC}"
            ;;
        ntfs)
            format_with_spinner "wipefs -a ${PART_PREFIX}3 && mkfs.ntfs -f -L root ${PART_PREFIX}3" "Formatting Root partition (${PART_PREFIX}3) as ntfs"
            ;;
        exfat)
            format_with_spinner "wipefs -a ${PART_PREFIX}3 && mkfs.exfat -n root ${PART_PREFIX}3" "Formatting Root partition (${PART_PREFIX}3) as exfat"
            ;;
        *)
            log "${RED}Unsupported filesystem type for Root. Aborting.${NC}"
            exit 1
            ;;
    esac

    # Home (if chosen)
    if [[ "$CREATE_HOME" == "yes" ]]; then
        case "$HOME_FS_TYPE" in
            ext4)
                format_with_spinner "wipefs -a ${PART_PREFIX}4 && mkfs.ext4 -F -L home ${PART_PREFIX}4" "Formatting Home partition (${PART_PREFIX}4) as ext4"
                ;;
            xfs)
                format_with_spinner "wipefs -a ${PART_PREFIX}4 && mkfs.xfs -f -L home ${PART_PREFIX}4" "Formatting Home partition (${PART_PREFIX}4) as xfs"
                ;;
            btrfs)
                format_with_spinner "wipefs -a ${PART_PREFIX}4 && mkfs.btrfs -f -L home ${PART_PREFIX}4" "Formatting Home partition (${PART_PREFIX}4) as btrfs"
                ;;
            fat32)
                log "${RED}Home partition cannot be fat32. Skipping Home formatting.${NC}"
                ;;
            ntfs)
                format_with_spinner "wipefs -a ${PART_PREFIX}4 && mkfs.ntfs -f -L home ${PART_PREFIX}4" "Formatting Home partition (${PART_PREFIX}4) as ntfs"
                ;;
            exfat)
                format_with_spinner "wipefs -a ${PART_PREFIX}4 && mkfs.exfat -n home ${PART_PREFIX}4" "Formatting Home partition (${PART_PREFIX}4) as exfat"
                ;;
            *)
                log "${RED}Unsupported filesystem type for Home. Aborting.${NC}"
                exit 1
                ;;
        esac
    fi

    # Format Custom Partitions
    if [[ ${#CUSTOM_PARTITIONS[@]} -gt 0 ]]; then
        local part_num=5
        for part in "${CUSTOM_PARTITIONS[@]}"; do
            IFS=':' read -r name size fs <<< "$part"
            case "$fs" in
                ext4)
                    format_with_spinner "wipefs -a ${PART_PREFIX}${part_num} && mkfs.ext4 -F -L ${name#*/} ${PART_PREFIX}${part_num}" "Formatting $name partition (${PART_PREFIX}${part_num}) as ext4"
                    ;;
                xfs)
                    format_with_spinner "wipefs -a ${PART_PREFIX}${part_num} && mkfs.xfs -f -L ${name#*/} ${PART_PREFIX}${part_num}" "Formatting $name partition (${PART_PREFIX}${part_num}) as xfs"
                    ;;
                btrfs)
                    format_with_spinner "wipefs -a ${PART_PREFIX}${part_num} && mkfs.btrfs -f -L ${name#*/} ${PART_PREFIX}${part_num}" "Formatting $name partition (${PART_PREFIX}${part_num}) as btrfs"
                    ;;
                fat32)
                    format_with_spinner "wipefs -a ${PART_PREFIX}${part_num} && mkfs.fat -F 32 ${PART_PREFIX}${part_num}" "Formatting $name partition (${PART_PREFIX}${part_num}) as fat32"
                    ;;
                ntfs)
                    format_with_spinner "wipefs -a ${PART_PREFIX}${part_num} && mkfs.ntfs -f -L ${name#*/} ${PART_PREFIX}${part_num}" "Formatting $name partition (${PART_PREFIX}${part_num}) as ntfs"
                    ;;
                exfat)
                    format_with_spinner "wipefs -a ${PART_PREFIX}${part_num} && mkfs.exfat -n ${name#*/} ${PART_PREFIX}${part_num}" "Formatting $name partition (${PART_PREFIX}${part_num}) as exfat"
                    ;;
                *)
                    log "${RED}Unsupported filesystem type for $name. Skipping formatting.${NC}"
                    ;;
            esac
            ((part_num++))
        done
    fi
}

# ------------------------------
# MAIN SCRIPT
# ------------------------------

clear
log "${GREEN}=====================================${NC}"
log "${GREEN}  INTERACTIVE PARTITION & FORMAT TOOL${NC}"
log "${GREEN}=====================================${NC}"
log ""
log "${RED}WARNING: This tool will overwrite the selected disk.${NC}"
log "Press Ctrl+C at any time to abort."
log ""

select_disk
get_partition_details
summarize_and_confirm
partition_disk
format_partitions

log ""
log "${GREEN}Partitioning and formatting complete!${NC}"
lsblk "$DISK" | tee -a "$LOG_FILE"
