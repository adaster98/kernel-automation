#!/bin/bash

# 1. TRAP: Ensure terminal resets to normal on exit
trap 'echo -ne "\e[r"; tput cup 9999 0; tput cnorm' EXIT

# 2. PIPEFAIL: Critical for catching errors when piping to logs
set -o pipefail

# 3. Source Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    source "$SCRIPT_DIR/config.env"
else
    echo -e "\e[31mError: config.env not found in $SCRIPT_DIR\e[0m"
    exit 1
fi

# =======================
# VARIABLES
# =======================
RED='\e[31m'
BLUE='\e[34m'
GREEN='\e[32m'
YELLOW='\e[33m'
RESET='\e[0m'
BOLD='\e[1m'

ICON_PENDING="[-]"
ICON_PROCESS="[*]"
ICON_DONE="[✓]"
ICON_FAIL="[X]"

LOG_FILE="$SCRIPT_DIR/build.log"
# Clear previous log
> "$LOG_FILE"

# Kernel Setup
cd /usr/src/linux || { echo "Cannot find /usr/src/linux"; exit 1; }

if [[ ! -f .config ]]; then
    echo -e "${RED}Error: No .config found in /usr/src/linux${RESET}"
    exit 1
fi

localVersion=$(grep -E '^CONFIG_LOCALVERSION=' .config | cut -d'"' -f2)
kernelRelease=$(make kernelrelease 2>/dev/null)
if [[ -z "$kernelRelease" ]]; then
    currentKernel=$(eselect kernel list | grep '\*$' | awk '{print $2}' | sed 's/^linux-//')
    kernelRelease="$currentKernel$localVersion"
fi

ROOT_PARTUUID=$(findmnt / -o PARTUUID -n)
HAS_INITRD=$(grep -E '^CONFIG_BLK_DEV_INITRD=y' .config)
HAS_MOD_SIG=$(grep -E '^CONFIG_MODULE_SIG=y' .config)

USE_NVIDIA=false
if [[ " $GPU_DRIVERS " =~ " nvidia " ]]; then
    USE_NVIDIA=true
fi

# =======================
# JOB QUEUE
# =======================
JOB_NAMES=()
JOB_CMDS=()
JOB_STATUS=()

add_job() {
    JOB_NAMES+=("$1")
    JOB_CMDS+=("$2")
    JOB_STATUS+=(0)
}

add_job "Compile Kernel" "step_compile_kernel"
add_job "Copy Kernel Image" "step_copy_kernel"

if [[ "$USE_NVIDIA" == "true" ]]; then
    add_job "Emerge Nvidia Drivers" "step_nvidia_driver"
fi

if [[ -n "$HAS_MOD_SIG" && "$USE_NVIDIA" == "true" ]]; then
    add_job "Sign External Modules" "step_sign_driver"
fi

if [[ -n "$HAS_INITRD" && "$INITRAMFS_TOOL" != "none" ]]; then
    add_job "Generate Initramfs ($INITRAMFS_TOOL)" "step_initramfs"
fi

if [[ "$BOOTLOADER" != "none" ]]; then
    add_job "Update Bootloader ($BOOTLOADER)" "step_bootloader"
fi

# =======================
# UI FUNCTIONS
# =======================

SCROLL_START_ROW=0

# Shared Header
print_info_header() {
    echo "-----------------------------------"
    echo "- ASTER'S KERNEL BUILD AUTOMATION -"
    echo "-----------------------------------"
    echo -e "Target Version: ${BLUE}$kernelRelease${RESET}"
    echo -e "GPU Drivers:    ${BLUE}$GPU_DRIVERS${RESET}"
    echo -e "Bootloader:     ${BLUE}$BOOTLOADER${RESET}"
    if [[ -n "$HAS_INITRD" ]]; then
        echo -e "Initramfs:      ${BLUE}$INITRAMFS_TOOL${RESET}"
    else
        echo -e "Initramfs:      ${YELLOW}Disabled${RESET}"
    fi
    echo ""
}

init_dashboard() {
    clear
    print_info_header

    JOB_LIST_START_ROW=8

    for i in "${!JOB_NAMES[@]}"; do
        echo -e "  ${ICON_PENDING} ${JOB_NAMES[$i]}"
    done

    echo "-----------------------------------"
    echo -e "${BOLD}LOGS:${RESET}"

    local total_header_lines=$(( JOB_LIST_START_ROW + ${#JOB_NAMES[@]} + 2 ))
    SCROLL_START_ROW=$(( total_header_lines + 1 ))

    # Freeze Header
    echo -ne "\033[${SCROLL_START_ROW};r"
    # Move cursor to logs
    tput cup $((SCROLL_START_ROW - 1)) 0
}

update_job_status() {
    local index=$1
    local status_code=$2
    local name="${JOB_NAMES[$index]}"

    case $status_code in
        0) icon="${ICON_PENDING}" ;;
        1) icon="${YELLOW}${ICON_PROCESS}${RESET}" ;;
        2) icon="${GREEN}${ICON_DONE}${RESET}" ;;
        *) icon="${RED}${ICON_FAIL}${RESET}" ;;
    esac

    tput sc
    local target_row=$(( JOB_LIST_START_ROW + index ))
    tput cup $target_row 0
    echo -e "  $icon $name\033[K"
    tput rc
}

# =======================
# WORKER FUNCTIONS
# =======================

step_compile_kernel() {
    echo -e "Starting kernel compilation..."
    local cmd=(make -j$(nproc))
    if [[ "$USE_LLVM" == "true" ]]; then
        cmd+=(LLVM=1)
    fi

    echo -e "Running: ${cmd[*]}"

    "${cmd[@]}" || return 1

    echo -e "Installing modules..."
    "${cmd[@]}" modules_install || return 1

    echo -e "${BLUE}${BOLD}INFO: ${RESET}Kernel & Modules compiled successfully."
}

step_copy_kernel() {
    local img_path="/usr/src/linux/arch/x86_64/boot/bzImage"
    local dest_path="$ESP_DIR/vmlinuz-$kernelRelease.efi"

    if [[ ! -f "$img_path" ]]; then
        echo -e "${RED}Error: bzImage not found at $img_path${RESET}"
        return 1
    fi

    mkdir -p "$ESP_DIR"
    cp -v "$img_path" "$dest_path"
    echo -e "${BLUE}${BOLD}INFO: ${RESET}Kernel copied to $dest_path"
}

step_nvidia_driver() {
    echo -e "${RED}${BOLD}EMERGE: ${RESET}Rebuilding Nvidia Drivers..."
    if [[ "$NVIDIA_USE_CUSTOM_CFLAGS" == "true" && "$USE_LLVM" == "true" ]]; then
        export LLVM=1
        export CC=clang
        export LD=ld.lld
        export AR=llvm-ar
        export NM=llvm-nm
        export STRIP=llvm-strip
        echo "Using LLVM variables for Emerge..."
    fi
    emerge --oneshot x11-drivers/nvidia-drivers --quiet || return 1
    echo -e "${BLUE}${BOLD}INFO: ${RESET}Nvidia drivers rebuilt."
}

step_sign_driver() {
    echo -e "Stripping and Signing external modules..."
    local mod_dir="/lib/modules/$kernelRelease/video"
    local sign_tool="/usr/src/linux/scripts/sign-file"

    if [[ ! -f "$KEY_PRIV" || ! -f "$KEY_PUB" ]]; then
         echo -e "${RED}Error: Signing keys not found in config paths.${RESET}"
         return 1
    fi

    if [[ -d "$mod_dir" ]]; then
        cd "$mod_dir" || return 1
        for module in nvidia*.ko; do
            [[ ! -f "$module" ]] && continue
            echo "Processing $module..."
            strip --strip-debug "$module"
            "$sign_tool" sha512 "$KEY_PRIV" "$KEY_PUB" "$module"
        done
        echo -e "${BLUE}${BOLD}INFO: ${RESET}Modules signed."
    else
        echo -e "${YELLOW}Warning: No video module directory found at $mod_dir${RESET}"
    fi
}

step_initramfs() {
    local out_img="$ESP_DIR/initramfs-$kernelRelease.img"
    echo -e "Generating Initramfs using $INITRAMFS_TOOL..."
    if [[ "$INITRAMFS_TOOL" == "ugrd" ]]; then
        ugrd --kver "$kernelRelease" "$out_img"
    elif [[ "$INITRAMFS_TOOL" == "dracut" ]]; then
        dracut --kver "$kernelRelease" --force "$out_img"
    else
        echo -e "${RED}Unknown initramfs tool: $INITRAMFS_TOOL${RESET}"
        return 1
    fi
    echo -e "${BLUE}${BOLD}INFO: ${RESET}Initramfs created at $out_img"
}

step_bootloader() {
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        local entry_file="$ESP_DIR/loader/entries/$kernelRelease.conf"
        mkdir -p "$(dirname "$entry_file")"
        cat <<EOF > "$entry_file"
title   Gentoo Linux
version $kernelRelease
linux   /vmlinuz-$kernelRelease.efi
EOF
        if [[ -f "$ESP_DIR/initramfs-$kernelRelease.img" ]]; then
            echo "initrd  /initramfs-$kernelRelease.img" >> "$entry_file"
        fi
        echo "options root=PARTUUID=${ROOT_PARTUUID} ${KERNEL_CMDLINE}" >> "$entry_file"
        echo -e "${BLUE}${BOLD}INFO: ${RESET}Entry created at $entry_file"

    elif [[ "$BOOTLOADER" == "grub" ]]; then
        echo -e "Running grub-mkconfig..."
        grub-mkconfig -o /boot/grub/grub.cfg

    elif [[ "$BOOTLOADER" == "limine" ]]; then
        local limine_conf="$ESP_DIR/limine.conf"
        [[ ! -f "$limine_conf" ]] && touch "$limine_conf"

        echo -e "Appending entry to $limine_conf..."
        {
            echo ""
            echo "/Gentoo Linux ($kernelRelease)"
            echo "    protocol: linux"
            echo "    path: boot():/vmlinuz-$kernelRelease.efi"
            if [[ -f "$ESP_DIR/initramfs-$kernelRelease.img" ]]; then
                echo "    module_path: boot():/initramfs-$kernelRelease.img"
            fi
            echo "    kernel_cmdline: root=PARTUUID=${ROOT_PARTUUID} ${KERNEL_CMDLINE}"
        } >> "$limine_conf"
        echo -e "${BLUE}${BOLD}INFO: ${RESET}Limine configuration updated."

    elif [[ "$BOOTLOADER" == "asterboot" ]]; then
        local entry_file="$ESP_DIR/asterboot/slots/$kernelRelease.conf"
        mkdir -p "$(dirname "$entry_file")"

        echo -e "Creating AsterBoot entry: $entry_file"

        cat <<EOF > "$entry_file"
TITLE=Gentoo Linux
VERSION=$kernelRelease
KERNEL=\\vmlinuz-$kernelRelease.efi
EOF
        if [[ -f "$ESP_DIR/initramfs-$kernelRelease.img" ]]; then
            echo "INITRD=\\initramfs-$kernelRelease.img" >> "$entry_file"
        fi

        echo "PARAMS=root=PARTUUID=${ROOT_PARTUUID} ${KERNEL_CMDLINE}" >> "$entry_file"
        echo -e "${BLUE}${BOLD}INFO: ${RESET}AsterBoot entry created at $entry_file"
    fi
}

# =======================
# EXECUTION START
# =======================

# 1. Clear & Show Initial Header
clear
print_info_header

# 2. Confirmation Prompt
echo -e "\n${YELLOW}${BOLD}WARNING:${RESET}"
echo -e "Make sure you have ${BOLD}eselected the correct kernel${RESET} before starting."
echo -e "Ensure your kernel config is placed in ${BOLD}/usr/src/linux/.config${RESET}\n"

read -p "Start Build? [Y/n] " -n 1 -r confirm
echo ""

if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo -e "\n${RED}Aborted.${RESET}"
    exit 0
fi

# 3. Initialize Dashboard & Scroll Region
init_dashboard

# 4. Run Jobs
for i in "${!JOB_NAMES[@]}"; do
    # Update Status to Processing [*]
    update_job_status $i 1

    # Run the function
    cmd="${JOB_CMDS[$i]}"

    # Pipe the ENTIRE function execution to tee
    # Because pipefail is ON, if $cmd fails, the whole statement fails.
    if $cmd 2>&1 | tee -a "$LOG_FILE"; then
        # Update Status to Done [✓]
        update_job_status $i 2
    else
        # Update Status to Fail [X]
        update_job_status $i 3
        echo -e "\n${RED}Critical Error in step: ${JOB_NAMES[$i]}${RESET}" | tee -a "$LOG_FILE"
        exit 1
    fi
done

echo -e "\n${GREEN}${BOLD}ALL TASKS COMPLETED SUCCESSFULLY.${RESET}" | tee -a "$LOG_FILE"
