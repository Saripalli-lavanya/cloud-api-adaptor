#!/bin/bash

export LANG=C.UTF-8

echo "Starting script..."

# Check if SE_BOOT variable is set to 1 and architecture is s390x
if [ "${SE_BOOT:-0}" != "1" ]; then
    echo "SE_BOOT is not set to 1, exiting..."
    exit 0
elif [ "${ARCH}" != "s390x" ]; then
    echo "Building of SE podvm image is only supported for s390x"
    exit 0
fi

echo "Building SE podvm image for $ARCH"

# Find host key files
echo "Finding host key files"
host_keys=""
for i in /tmp/files/*.crt; do
    [[ -f "$i" ]] || break
    echo "Found host key file: \"${i}\""
    host_keys+="-k ${i} "
done
[[ -z $host_keys ]] && echo "Didn't find host key files, please download host key files to 'files' folder " && exit 1

# Install necessary packages and prepare environment
echo "Installing necessary packages and preparing environment"
sudo yum clean all

# Set up disk and partitions
workdir=$(pwd)
disksize=100G
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
sudo lsblk --json
echo "Found target device $device"
export tmp_nbd="/dev/$device"
export dst_mnt=$workdir/dst_mnt
export src_mnt=$workdir/src_mnt

echo "Creating boot-se and root partitions"
sudo parted -a optimal ${tmp_nbd} mklabel gpt \
    mkpart boot-se ext4 1MiB 256MiB \
    mkpart root 256MiB ${disksize} \
    set 1 boot on

echo "Waiting for the partitions to show up"
while true; do
    sleep 1
    [ -e ${tmp_nbd}2 ] && break
done

# Format boot-se partition
echo "Formatting boot-se partition"
sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
echo "Boot partition UUID: $boot_uuid"

# Set up encrypted root partition
echo "Setting up encrypted root partition"
sudo mkdir -p ${workdir}/rootkeys
sudo mount -t tmpfs rootkeys ${workdir}/rootkeys
sudo dd if=/dev/random of=${workdir}/rootkeys/rootkey.bin bs=1 count=64
sudo cryptsetup luksFormat --type luks2 ${tmp_nbd}2 ${workdir}/rootkeys/rootkey.bin
LUKS_NAME="luks-$(sudo blkid -s UUID -o value ${tmp_nbd}2)"
sudo cryptsetup open ${tmp_nbd}2 $LUKS_NAME --key-file ${workdir}/rootkeys/rootkey.bin

# Mount root filesystem and copy contents
echo "Mounting root filesystem and copying contents"
sudo mkfs.ext4 -L "root" /dev/mapper/${LUKS_NAME}
sudo mkdir -p ${dst_mnt}
sudo mkdir -p ${src_mnt}
sudo mount /dev/mapper/$LUKS_NAME ${dst_mnt}
sudo mkdir ${dst_mnt}/boot-se
sudo mount -o norecovery ${tmp_nbd}1 ${dst_mnt}/boot-se
sudo mount --bind -o ro / ${src_mnt}
sudo tar -cf - --numeric-owner --preserve-permissions --acl --selinux --xattrs --xattrs-include='*' --sparse --one-file-system -C ${src_mnt} . | sudo tar -xf - --preserve-order -C "${dst_mnt}"

# Configure /etc/fstab
echo "Configuring /etc/fstab"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/fstab
# This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=$boot_uuid        /boot-se ext4  norecovery 1 2
END'

# Configure /etc/crypttab
echo "Configuring /etc/crypttab"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/crypttab
# This file was auto-generated
$LUKS_NAME UUID=$(sudo blkid -s UUID -o value ${tmp_nbd}2) /etc/keys/luks-${LUKS_NAME}.key luks,discard,initramfs
END'
sudo chmod 644 "${dst_mnt}/etc/crypttab"

# Configure zipl for boot
echo "Configuring zipl"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/zipl.conf
[defaultboot]
default=linux
target=/boot-se

targetbase=${tmp_nbd}
targettype=scsi
targetblocksize=512
targetoffset=2048

[linux]
image = /boot-se/se.img
END'

# Update initramfs
echo "Updating initramfs"
sudo chroot "${dst_mnt}" dracut -f --regenerate-all

# Create SE boot image
echo "Creating SE boot image"
sudo -E /usr/bin/genprotimg \
    -i ${dst_mnt}/boot/vmlinuz-$(uname -r) \
    -r ${dst_mnt}/boot/initramfs-$(uname -r).img \
    -p ${dst_mnt}/boot/parmfile \
    --no-verify \
    ${host_keys} \
    -o ${dst_mnt}/boot-se/se.img

# Check if SE image was created
[ ! -e ${dst_mnt}/boot-se/se.img ] && exit 1

# Clean up /boot directory
sudo rm -rf ${dst_mnt}/boot/*

# Run zipl to prepare boot partition
echo "Running zipl to prepare boot partition"
sudo chroot ${dst_mnt} zipl --targetbase ${tmp_nbd} \
    --targettype scsi \
    --targetblocksize 512 \
    --targetoffset 2048 \
    --target /boot-se \
    --image /boot-se/se.img

# Clean up
echo "Cleaning up"
sudo umount ${workdir}/rootkeys/ || true
sudo rm -rf ${workdir}/rootkeys
sudo umount ${dst_mnt}/boot-se
sudo umount ${dst_mnt}
sudo rm -rf ${src_mnt} ${dst_mnt}

echo "Script completed successfully."
