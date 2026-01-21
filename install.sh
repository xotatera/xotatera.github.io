#!/bin/bash
# --- NVMe-Optimized Arch Installer (LUKS + Btrfs + AMD) ---
# v2.1 - Fixed fstab generation, systemd race conditions

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   AMD + NVMe Arch Installer (LUKS + Btrfs)     ${NC}"
echo -e "${GREEN}================================================${NC}"

# 1. Hardware Detection
echo -e "\n${GREEN}[1/6] Identifying Drives:${NC}"
lsblk -d -o NAME,MODEL,SIZE,ROTA | grep -E 'nvme|sd' | grep -v 'loop\|sr' || true

read -p "Enter the device name to wipe (e.g., nvme0n1): " DISK_NAME
DISK="/dev/$DISK_NAME"

if [ ! -b "$DISK" ]; then
    echo -e "${RED}Error: $DISK does not exist.${NC}"
    exit 1
fi

# Detect partition naming scheme
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

echo -e "\n${RED}!!! WARNING !!!${NC}"
echo -e "This will DESTROY all data on ${RED}$DISK${NC}."
read -p "Are you absolutely sure? (type 'CONFIRM'): " confirm
if [ "$confirm" != "CONFIRM" ]; then
    echo "Installation aborted."
    exit 1
fi

# 2. User Configuration
echo -e "\n${GREEN}[2/6] System Configuration...${NC}"

read -p "Enter hostname [arch-nvme]: " HOSTNAME
HOSTNAME=${HOSTNAME:-arch-nvme}

read -p "Enter username: " USERNAME
while [ -z "$USERNAME" ]; do
    read -p "Username cannot be empty. Enter username: " USERNAME
done

read -p "Enter timezone [Europe/Istanbul]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Istanbul}

if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    echo -e "${YELLOW}Warning: Timezone '$TIMEZONE' not found, defaulting to UTC${NC}"
    TIMEZONE="UTC"
fi

read -p "Reserve 50GB for SSD over-provisioning? [Y/n]: " RESERVE_SPACE
RESERVE_SPACE=${RESERVE_SPACE:-Y}

# 3. Partitioning
echo -e "\n${GREEN}[3/6] Partitioning...${NC}"

sgdisk -Z $DISK
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" $DISK

if [[ "$RESERVE_SPACE" =~ ^[Yy]$ ]]; then
    sgdisk -n 2:0:-50G -t 2:8309 -c 2:"LUKS" $DISK
    echo -e "${GREEN}Reserved 50GB for SSD health.${NC}"
else
    sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS" $DISK
fi

udevadm settle
partprobe $DISK 2>/dev/null || true
sleep 1

if [ ! -b "${PART_PREFIX}1" ] || [ ! -b "${PART_PREFIX}2" ]; then
    echo -e "${RED}Error: Partitions not created properly.${NC}"
    exit 1
fi

mkfs.fat -F32 -n EFI ${PART_PREFIX}1

echo -e "\n${GREEN}Partition layout:${NC}"
lsblk $DISK

# 4. Encryption & Subvolumes
echo -e "\n${GREEN}[4/6] LUKS2 + Btrfs Setup...${NC}"
echo -e "${YELLOW}You will be prompted to create the encryption passphrase.${NC}"

cryptsetup luksFormat --type luks2 --sector-size 4096 --label CRYPTROOT ${PART_PREFIX}2
cryptsetup open ${PART_PREFIX}2 cryptroot

mkfs.btrfs -L ARCH /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

echo -e "${GREEN}Creating Btrfs subvolumes...${NC}"
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

# 5. Mounting & Base Install
echo -e "\n${GREEN}[5/6] Installing Base System...${NC}"

# Include systemd timeout in mount options - genfstab will capture these
MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,x-systemd.device-timeout=30s"

mount -o subvol=@,$MOUNT_OPTS /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}

mount -o subvol=@home,$MOUNT_OPTS /dev/mapper/cryptroot /mnt/home
mount -o subvol=@log,$MOUNT_OPTS /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@pkg,$MOUNT_OPTS /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o subvol=@snapshots,$MOUNT_OPTS /dev/mapper/cryptroot /mnt/.snapshots
mount ${PART_PREFIX}1 /mnt/boot

pacstrap /mnt base linux linux-firmware amd-ucode btrfs-progs cryptsetup \
    vim nano apparmor audit grub efibootmgr networkmanager sudo

# genfstab captures mount options including x-systemd.device-timeout
genfstab -U /mnt >> /mnt/etc/fstab

# 6. Internal Configuration
echo -e "\n${GREEN}[6/6] Configuring System...${NC}"

CRYPT_UUID=$(blkid -s UUID -o value ${PART_PREFIX}2)

cat <<'CHROOT_SCRIPT' > /mnt/setup_internal.sh
#!/bin/bash
set -e

TIMEZONE="$1"
HOSTNAME="$2"
USERNAME="$3"
CRYPT_UUID="$4"

echo "Configuring timezone and locale..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname

cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# crypttab - tells systemd about LUKS container, prevents race conditions
echo "cryptroot UUID=$CRYPT_UUID none timeout=30s,discard" > /etc/crypttab

# mkinitcpio - keyboard/keymap BEFORE encrypt is critical
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# GRUB
CMDLINE="cryptdevice=UUID=$CRYPT_UUID:cryptroot:allow-discards root=/dev/mapper/cryptroot rootflags=subvol=@ lsm=landlock,lockdown,yama,integrity,apparmor,bpf quiet"
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"|" /etc/default/grub
grep -q "^GRUB_ENABLE_CRYPTODISK=y" /etc/default/grub || echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# User
useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# Services
systemctl enable apparmor auditd fstrim.timer NetworkManager

echo "Chroot configuration complete."
CHROOT_SCRIPT

chmod +x /mnt/setup_internal.sh
arch-chroot /mnt ./setup_internal.sh "$TIMEZONE" "$HOSTNAME" "$USERNAME" "$CRYPT_UUID"
rm /mnt/setup_internal.sh

# Passwords
echo -e "\n${GREEN}Set Root Password:${NC}"
arch-chroot /mnt passwd

echo -e "\n${GREEN}Set Password for $USERNAME:${NC}"
arch-chroot /mnt passwd "$USERNAME"

# Verification
echo -e "\n${GREEN}Verifying installation...${NC}"
VERIFY_FAILED=0

for file in /mnt/boot/grub/grub.cfg /mnt/etc/crypttab /mnt/etc/fstab /mnt/etc/mkinitcpio.conf; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $(basename $file)"
    else
        echo -e "  ${RED}✗${NC} $file missing!"
        VERIFY_FAILED=1
    fi
done

# Verify fstab has systemd timeout
if grep -q "x-systemd.device-timeout" /mnt/etc/fstab; then
    echo -e "  ${GREEN}✓${NC} fstab has systemd timeout"
else
    echo -e "  ${YELLOW}!${NC} fstab missing systemd timeout (may cause boot race)"
fi

# Verify mkinitcpio hooks
if grep -q "keyboard keymap.*encrypt" /mnt/etc/mkinitcpio.conf; then
    echo -e "  ${GREEN}✓${NC} mkinitcpio hooks ordered correctly"
else
    echo -e "  ${RED}✗${NC} mkinitcpio hooks may be misordered!"
    VERIFY_FAILED=1
fi

if [ $VERIFY_FAILED -eq 1 ]; then
    echo -e "\n${RED}Warning: Issues detected. Review before rebooting.${NC}"
fi

# Cleanup
umount -R /mnt
cryptsetup close cryptroot

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}   Installation Complete!                       ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "  Hostname:  $HOSTNAME"
echo -e "  Username:  $USERNAME"
echo -e "  Timezone:  $TIMEZONE"
echo -e "  Disk:      $DISK"
echo ""
echo -e "${GREEN}You can now reboot.${NC}"
echo -e "${YELLOW}Remember your LUKS passphrase!${NC}"
