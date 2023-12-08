#!/bin/bash

# Add /root to the PATH in order to be able to add custom binaries to the LiveCD
export PATH="$PATH:/root"

# Exit on error
set -e

source /usr/bin/gettext.sh
export TEXTDOMAIN="install"
export TEXTDOMAINDIR="$PWD/po"

SUPPORTED_LOCALES=(
	fr_FR
	en_US
)

#===================================================
# Cambria Linux install script
#===================================================

# Create system_install script to allow the usage of 'gum spin'.
cat << EOMF > system_install.sh
#!/usr/bin/env bash

source /usr/bin/gettext.sh
export TEXTDOMAIN="system_install"
export TEXTDOMAINDIR="$PWD/po"

# Mount root partition
eval_gettext "Mounting root partition"; echo
mkfs.ext4 -F \$ROOT_PART &>/dev/null
mkdir -p /mnt/gentoo
mount \$ROOT_PART /mnt/gentoo

# Copy stage archive
echo "Copying stage archive..."
cp \$FILE /mnt/gentoo

# Extract stage archive
eval_gettext "Extracting stage archive..."; echo
cd /mnt/gentoo
pv \$FILE | tar xJp --xattrs-include='*.*' --numeric-owner

# Mount UEFI partition
eval_gettext "Mounting UEFI partition..."; echo
mkfs.vfat \$UEFI_PART &>/dev/null
mkdir -p /mnt/gentoo/boot/efi
mount \$UEFI_PART /mnt/gentoo/boot/efi

eval_gettext "Activating SWAP partition..."; echo
mkswap \$SWAP_PART

eval_gettext "Creating fstab..."; echo
echo "UUID=\$(blkid -o value -s UUID "\$UEFI_PART") /boot/efi vfat defaults 0 2" >>/mnt/gentoo/etc/fstab
echo "UUID=\$(blkid -o value -s UUID "\$ROOT_PART") / \$(lsblk -nrp -o FSTYPE \$ROOT_PART) defaults 1 1" >>/mnt/gentoo/etc/fstab
echo "UUID=\$(blkid -o value -s UUID "\$SWAP_PART") swap swap pri=1 0 0" >>/mnt/gentoo/etc/fstab

# Keymap configuration
eval_gettext "Configuring keymap..."; echo
echo "KEYMAP=\$KEYMAP" >/mnt/gentoo/etc/vconsole.conf

# Execute installation stuff
eval_gettext "Chroot inside Cambria..."; echo
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

eval_gettext "Installing GRUB..."; echo
cat <<EOF | chroot /mnt/gentoo
grub-install --efi-directory=/boot/efi
grub-mkconfig -o /boot/grub/grub.cfg
EOF
eval_gettext "Setting up hostname..."; echo
chroot /mnt/gentoo systemd-machine-id-setup
eval_gettext "Setting up users..."; echo
cat <<EOF | chroot /mnt/gentoo
useradd -m -G users,wheel,audio,video,input -s /bin/bash \$USERNAME
echo -e "\${USER_PASSWORD}\n\${USER_PASSWORD}" | passwd -q \$USERNAME
echo -e "\${ROOT_PASSWORD}\n\${ROOT_PASSWORD}" | passwd -q
systemctl preset-all --preset-mode=enable-only
EOF

eval_gettext "Deleting stage archive..."; echo
rm /mnt/gentoo/\$(basename \$FILE)
EOMF

chmod +x system_install.sh

exit_() {
    echo $1
    exit
}

#mount_iso() {
#	mkdir -p /mnt/iso
#	if [ -b /dev/mapper/ventoy ]; then
#		mount /dev/mapper/ventoy /mnt/iso
#	elif [ -b /dev/disk/by-label/ISOIMAGE* ]; then
#		mount /dev/disk/by-label/ISOIMAGE* /mnt/iso
#	fi
#}

installation_mode_selection() {
	case $(gum choose "Automatic" "Manual") in
		"Automatic") automatic_install;;
		"Manual") manual_install;;
	esac
}

manual_install() {
	stage_selection
	clear
	disk_selection
	cfdisk $DISK
	clear
	root_part_selection
	clear
	filesystem_selection
	clear
	uefi_part_selection
	clear
	swap_part_selection
	clear
	user_account
	clear
	root_password
	clear
	config_keymap
	clear
}

automatic_install() {
	stage_selection
	clear
	disk_selection
	clear
	automatic_partitioning
	clear
	filesystem_selection
	clear
	user_account
	clear
	root_password
	clear
	config_keymap
	clear
}


automatic_partitioning() {
	[[ "$DISK" == *"nvme"* ]] && DISK_P="${DISK}p" || DISK_P="$DISK"

	eval_gettext "Enter SWAP size in Gib:"; echo
	echo ""
	SWAP_SIZE=$(gum input --placeholder="`eval_gettext \"If not sure set to (CPU_threads*2) - ram_size + 1 only if the result is positive, else set to 1\"`")

	gum confirm "`eval_gettext \"All content from \\\$DISK will be loose, continue?\"`" || exit_ "`eval_gettext \"Exiting...\"`"

	SFDISK_CONFIG="label: gpt
	"
	SFDISK_CONFIG+="device: $DISK
	"
	SFDISK_CONFIG+="${DISK_P}1: size=256M,type=uefi
	"
	SFDISK_CONFIG+="${DISK_P}2: size=${SWAP_SIZE}G,type=swap
	"
	SFDISK_CONFIG+="${DISK_P}3: type=linux
	"

	echo "$SFDISK_CONFIG" | sfdisk --force --no-reread $DISK

	UEFI_PART="${DISK_P}1"
	SWAP_PART="${DISK_P}2"
	ROOT_PART="${DISK_P}3"
}

showkeymap() {
	if [ -d /usr/share/kbd/keymaps ]; then
		find /usr/share/kbd/keymaps/ -type f -iname "*.map.gz" -printf "%f\n" | sed 's|.map.gz||g' | sed '/include\//d' | sort
	else
		find /usr/share/keymaps/ -type f -iname "*.map.gz" -printf "%f\n" | sed 's|.map.gz||g' | sed '/include\//d' | sort
	fi
}

root_password() {
	eval_gettext "Root account configuration:"; echo
	echo ""
	ROOT_PASSWORD=$(gum input --password --placeholder="`eval_gettext \"Enter root password\"`")
}

user_account() {
	eval_gettext "User account creation:"; echo
	echo ""
    USERNAME=$(gum input --placeholder="`eval_gettext \"Enter username\"`")
    USER_PASSWORD=$(gum input --password --placeholder "`eval_gettext \"Enter \\\$USERNAME's password\"`")
}

stage_selection() {
	eval_gettext "STAGE SELECTION:"; echo
	echo ""
	ARCHIVES=/mnt/cdrom/*.tar.xz
	if [ "${#ARCHIVES[@]}" == "1" ]; then
		FILE=${ARCHIVES[0]}
	else
		FILE=$(gum choose --header="`eval_gettext \"Select the wanted stage:\"`" ${ARCHIVES[@]})
	fi
}

disk_selection() {
	eval_gettext "Disk selection:"; echo
	echo ""
    disks=$(lsblk -o NAME,SIZE,MODEL -d -p | grep -v "loop0" | grep -v "sr0" | grep -v "zram0" | tail -n +2)
    DISK=$(echo "$disks" | gum choose --header="`eval_gettext \"Select the disk to install Cambria into:\"`" | cut -d ' ' -f 1)
}

root_part_selection() {
	parts=$(ls $DISK* | grep "$DISK.*" | tail -n +2)
	eval_gettext "Root partition selection:"; echo
	echo ""
    ROOT_PART=$(gum choose --header="`eval_gettext \"Select the root partition: (/)\"`" $parts)
}

uefi_part_selection() {
	not_parsed_parts=$(ls $DISK* | grep "$DISK.*" | tail -n +2)
	
	parts=""
	for part in $not_parsed_parts; do
		[ "$part" != "$ROOT_PART" ] && parts+="$part "
	done
	
	eval_gettext "UEFI partition selection:"; echo
	echo ""
    UEFI_PART=$(gum choose --header="`eval_gettext \"Select the efi partiton: (/boot/efi)\"`" $parts)
}

swap_part_selection() {
	not_parsed_parts=$(ls $DISK* | grep "$DISK.*" | tail -n +2)
	
	parts=""
	for part in $not_parsed_parts; do
		[ "$part" != "$ROOT_PART" ] && [ "$part" != "$UEFI_PART" ] && parts+="$part "
	done

	eval_gettext "SWAP partition selection:"; echo
	echo ""
	SWAP_PART=$(gum choose --header="`eval_gattext \"Select the swap partition:\"`" $parts)
}

config_keymap() {
	unset KEYMAP keymappart
	eval_gettext "Keymap selection:"; echo
	echo ""
	keymappart=$(showkeymap | gum filter --placeholder="`eval_gettext \"Enter and find your keymap...\"`")
}

locale_selection() {
	export LC_ALL=$(gum choose --header="`eval_gettext \"Select the locale to use:\"`" ${SUPPORTED_LOCALES[@]})
}

filesystem_selection() {
	eval_gettext "Filesystem selection"; echo
	FILESYSTEM=$(gum choose ${SUPPORTED_FS[@]})

	if [ $FILESYSTEM = "BTRFS" ]; then
		clear
		btrfs_layout_selection
	fi
}

btrfs_layout_selection() {
	eval_gettext "1. Basic layout"; echo
	echo "\- @ => /"
	echo
	eval_gettext "2. Separated home"; echo
	echo "|- @ => /"
	echo "\- @home => /home"
	echo
	eval_gettext "3. Inside a folder"; echo
	echo "|- cambria"
	echo " \- @ => /"
	echo
	eval_gettext "4. Inside a folder with separated home"; echo
	echo "|- cambria"
	echo " |- @ => /"
	echo " \- @home => /home"
	echo

	while [ ! $layout ]; do
		read -p "`eval_gettext \"Select a layout [1-4]: \"`" SELECTED_LAYOUT
		[ $SELECTED_LAYOUT -gt 4 ] && continue
		[ $SELECTED_LAYOUT = 0 ] && continue
		layout=$SELECTED_LAYOUT
	done
}
echo "========================================================================"
echo "                     WELCOME ON CAMBRIA LINUX !                         "
echo "========================================================================"
echo ""

#locale_selection

eval_gettext "This script is here to help you install our distro easily.              "; echo
eval_gettext "Let us guide you step-by-step and you'll have a fully working Gentoo !  "; echo
echo ""
eval_gettext "Let's start !"; echo
echo ""

gum confirm "`eval_gettext \"Ready?\"`" || exit_ "`eval_gettext \"See you next time!\"`"

echo ""

installation_mode_selection

gum confirm "`eval_gettext \"Install Cambria on \\\$ROOT_PART from \\\$DISK ? DATA MAY BE LOST!\"`" || exit_ "`eval_gettext \"Installation aborted, exiting.\"`"

gum spin -s pulse --show-output --title="`eval_gettext \"Please wait while the script is doing the install for you :D\"`" /usr/bin/env ROOT_PART=$ROOT_PART UEFI_PART=$UEFI_PART KEYMAP=$KEYMAP USERNAME=$USERNAME USER_PASSWORD=$USER_PASSWORD ROOT_PASSWORD=$ROOT_PASSWORD FILE=$FILE SWAP_PART=$SWAP_PART bash ./system_install.sh

clear

# Locale configuration
LOCALE=$(grep "UTF-8" /mnt/gentoo/usr/share/i18n/SUPPORTED | awk '{print $1}' | sed 's/^#//;s/\.UTF-8//' | gum filter --limit 1 --header "`eval_gettext \"Choose your locale:\"`")
echo "$LOCALE.UTF-8 UTF-8" >> /mnt/gentoo/etc/locale.gen
cat <<EOF | chroot /mnt/gentoo
locale-gen
eselect locale set $LOCALE.UTF-8
EOF

# Keymap configuration
xkb_symbols=$(find /mnt/gentoo/usr/share/X11/xkb/symbols -maxdepth 1 -type f)
X11_KEYMAP=$(for file in ${xkb_symbols[@]}; do [ "$(cat $file | grep '// Keyboard layouts')" != "" ] && echo $(basename $file) ; done | sort | gum filter --header "`eval_gettext \"Choose a X11 keymap:\"`")

mkdir -p /mnt/gentoo/etc/X11/xorg.conf.d
cat <<EOF > /mnt/gentoo/etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
  Identifier "system-keyboard"
  MatchIsKeyboard "on"
  Option "XkbLayout" "$X11_KEYMAP"
EndSection
EOF

# Timezone configuration
unset TIMEZONE location country listloc listc countrypart

for l in /mnt/gentoo/usr/share/zoneinfo/*; do
	[ -d $l ] || continue
	l=${l##*/}
	case $l in
		Etc|posix|right) continue;;
	esac
	listloc="$listloc $l"
done

location=$(echo $listloc | tr ' ' '\n' | gum filter --header "`eval_gettext \"Choose a location:\"`")

for c in /mnt/gentoo/usr/share/zoneinfo/$location/*; do
	c=${c##*/}
	listc="$listc $c"
done

country=$(echo $listc | tr ' ' '\n' | gum filter --header "`eval_gettext \"Choose a city:\"`")
rm -f /mnt/gentoo/etc/localtime
ln -s /usr/share/zoneinfo/$location/$country /mnt/gentoo/etc/localtime

cp /usr/bin/cambria-center /mnt/gentoo/usr/bin/

mkdir -p /mnt/gentoo/etc/xdg/autostart
cp /etc/xdg/autostart/cambria-center.desktop /mnt/gentoo/etc/xdg/autostart/

# VM Max Map Count
cat <<EOF > /mnt/gentoo/etc/sysctl.conf
vm.max_map_count=1048576
EOF

cat <<EOF | chroot /mnt/gentoo
su $USERNAME -c "cd /home/$USERNAME && LANG=$LOCALE.UTF-8 xdg-user-dirs-update"
EOF

clear
eval_gettext "Installation has finished !"; echo
eval_gettext "Press R to reboot..."; echo
read REBOOT

if [ "$REBOOT" == "R" ] || [ "$REBOOT" == "r" ]; then
	reboot
fi
