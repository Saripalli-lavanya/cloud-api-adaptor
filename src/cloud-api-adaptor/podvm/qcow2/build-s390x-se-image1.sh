#!/bin/bash
set -x
set -e  

export LANG=C.UTF-8

echo "Starting script..."
if [ "${SE_BOOT:-0}" != "1" ]; then
    echo "SE_BOOT variable is not set to 1, exiting..."
    exit 1
elif [ "${ARCH}" != "s390x" ]; then
    echo "Building of SE podvm image is only supported for s390x, exiting..."
    exit 1
fi

echo "Finding host key files"
host_keys=""
rm /tmp/files/.dummy.crt || true
for i in /tmp/files/*.crt; do
    [[ -f "$i" ]] || break
    echo "found host key file: \"${i}\""
    host_keys+="${i} "
done

[[ -z $host_keys ]] && echo "Didn't find host key files, please download host key files to 'files' folder " && exit 1
pwd
cp $host_keys /root/HKD.crt
chmod 554 /root/HKD.crt
echo "Building SE podvm image for $ARCH"

# Ensure jq is installed
echo "jq version:"
jq --version

# Define variables
workdir=$(pwd)
disksize=100G
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
tmp_nbd="/dev/$device"
dst_mnt=$workdir/dst_mnt
src_mnt=$workdir/src_mnt
echo "pwd"
pwd
echo "Found target device: $device"

# Set up disk and partitions
echo "Creating partitions on $tmp_nbd"
sudo parted -a optimal ${tmp_nbd} mklabel gpt \
    mkpart boot-se ext4 1MiB 256MiB \
    mkpart root 256MiB 6400MiB \
    mkpart data 6400MiB ${disksize} \
    set 1 boot on

# Wait for partitions to be created
echo "Waiting for partitions to be detected..."
while ! sudo ls ${tmp_nbd}1 || ! sudo ls ${tmp_nbd}2; do
    sleep 1
done

# Format boot-se partition
echo "Formatting boot-se partition"
sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
export boot_uuid

# Copy the root filesystem
echo "Copying root filesystem to partition"
sudo mke2fs -t ext4 -L root ${tmp_nbd}2
boot_uuid2=$(sudo blkid ${tmp_nbd}2 -s PARTUUID -o value)
export boot_uuid2
sudo mkdir -p ${dst_mnt}
sudo mkdir -p ${src_mnt}
sudo mount --bind -o ro / ${src_mnt}
sudo tar --numeric-owner --preserve-permissions --acl --xattrs --xattrs-include='*' --sparse --one-file-system -cf - -C ${src_mnt} . | sudo tar -xf - -C ${dst_mnt}
sudo umount ${src_mnt}
echo "Partition copy complete"
echo "ls /"
ls /
echo "ls /root/"
ls /root/

# Add entries to fstab
echo "Adding fstab entries"
sudo -E bash -c 'cat <<END > /etc/fstab
#This file was auto-generated
PARTUUID=${boot_uuid2}    /        ext4  defaults 1 1
PARTUUID=${boot_uuid}    /boot-se    ext4  defaults 1 2
END'

# Disable virtio_rng
sudo -E bash -c 'echo "blacklist virtio_rng" > /etc/modprobe.d/blacklist-virtio.conf'
sudo -E bash -c 'echo "s390_trng" > /etc/modules'

# Configure zipl
sudo -E bash -c 'cat <<END > /etc/zipl.conf
[defaultboot]
default=linux
target=/boot-se
targetbase=/dev/vdb
targettype=scsi
targetblocksize=512
targetoffset=2048

[linux]
image = /boot-se/se.img
END'

# Update initramfs
echo "Updating initramfs"
sudo dracut -f /boot/initramfs-$(uname -r).img $(uname -r) || true

# Create SE boot image
echo "Creating IBM Secure Execution boot image"
KERNEL_FILE=/boot/vmlinuz-$(uname -r)
INITRD_FILE=/boot/initramfs-$(uname -r).img
export SE_PARMLINE="root=/ panic=0 blacklist=virtio_rng swiotlb=262144 console=ttyS0 printk.time=0 systemd.getty_auto=0 systemd.firstboot=0 module.sig_enforce=1 quiet loglevel=0 systemd.show_status=0"
echo "$SE_PARMLINE" > /boot/parmfile
sudo /usr/bin/genprotimg \
    --verbose \
    -i "${KERNEL_FILE}" \
    -r "${INITRD_FILE}" \
    -p "/boot/parmfile" \
    --no-verify \
    -k "/root/HKD.crt" \
    -o "/boot-se/se.img"

# Check if SE image was created
if [ ! -e /boot-se/se.img ]; then
    echo "Failed to create SE image, exiting..."
    exit 1
fi

# Run zipl to prepare boot partition
echo "Running zipl to prepare boot partition"
sudo zipl --targetbase ${tmp_nbd} \
    --targettype scsi \
    --targetblocksize 512 \
    --targetoffset 2048 \
    --target /boot-se \
    --image /boot-se/se.img

echo "Script completed successfully"
