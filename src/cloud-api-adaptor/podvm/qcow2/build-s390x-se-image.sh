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
cp $host_keys /root/HKD.crt
chmod 554 /root/HKD.crt
echo "Building SE podvm image for $ARCH"

# Ensure jq is installed
# echo "Checking for jq..."
# if ! command -v jq > /dev/null; then
#     echo "jq is not installed. Installing..."
#     sudo dnf install -y jq
# fi
echo "jq version:"
jq --version

# Define variables
workdir=$(pwd)
disksize=100G
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
tmp_nbd="/dev/$device"
dst_mnt=$workdir/dst_mnt
src_mnt=$workdir/src_mnt
ls -ltrh /
ls -ltrh /etc/
echo "Found target device: $device"

# Set up disk and partitions
echo "Creating partitions on $tmp_nbd"
sudo parted -a optimal ${tmp_nbd} mklabel gpt \
    mkpart boot-se ext4 1MiB 256MiB \
    mkpart root 256MiB 6400MiB \
    mkpart data 6400MiB ${disksize} \
    set 1 boot on
ls -ltrh /
ls -ltrh /etc/
# Wait for partitions to be created
echo "Waiting for partitions to be detected..."
while ! sudo ls ${tmp_nbd}1 || ! sudo ls ${tmp_nbd}2; do
    sleep 1
done
while true; do
sleep 1
[ -e ${tmp_nbd}2 ] && break
done

# Format boot-se partition
echo "Formatting boot-se partition"
sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
export boot_uuid
# Set up encrypted root partition
echo "Setting up encrypted root partition"
sudo mkdir -p ${workdir}/rootkeys
sudo mount -t tmpfs rootkeys ${workdir}/rootkeys
sudo dd if=/dev/random of=${workdir}/rootkeys/rootkey.bin bs=1 count=64
# echo YES | sudo cryptsetup luksFormat --type luks2 ${tmp_nbd}2 --key-file ${workdir}/rootkeys/rootkey.bin
LUKS_NAME="luks-$(sudo blkid -s UUID -o value ${tmp_nbd}2)"
export LUKS_NAME
echo "luks name is: $LUKS_NAME"
# sudo cryptsetup open ${tmp_nbd}2 $LUKS_NAME --key-file ${workdir}/rootkeys/rootkey.bin

# Copy the root filesystem
echo "Copying root filesystem to encrypted partition"
sudo mkfs.ext4 -L "root" /dev/mapper/${LUKS_NAME}
sudo mkdir -p ${dst_mnt}
sudo mkdir -p ${src_mnt}
sudo mount /dev/mapper/$LUKS_NAME /home/peerpod/dst_mnt
sudo mount
sudo lsblk
ls -lrh ${dst_mnt}
sudo mkdir ${dst_mnt}/boot-se
sudo mount -o norecovery ${tmp_nbd}1 /home/peerpod/dst_mnt/boot-se
sudo mount --bind -o ro / ${src_mnt}
sudo tar --numeric-owner --preserve-permissions --acl --xattrs --xattrs-include='*' --sparse --one-file-system -cf - -C ${src_mnt} . | sudo tar -xf - -C ${dst_mnt}
sudo umount ${src_mnt}
echo "Partition copy complete"
echo "Preparing secure execution boot image"
sudo rm -rf ${dst_mnt}/home/peerpod/*

sudo mount -t sysfs sysfs /home/peerpod/dst_mnt/sys
sudo mount -t proc proc /home/peerpod/dst_mnt/proc
sudo mount --bind /dev /home/peerpod/dst_mnt/dev
sudo mkdir -p /home/peerpod/dst_mnt/etc/keys
sudo mount -t tmpfs keys /home/peerpod/dst_mnt/etc/keys

echo "Adding fstab"
echo "Configuring filesystems and boot setup"
sudo -E bash -c 'cat <<END > /home/peerpod/dst_mnt/etc/fstab
#This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=${boot_uuid}    /boot-se    ext4  norecovery 1 2
END'
sudo chmod 644 /home/peerpod/dst_mnt/etc/fstab
cat /home/peerpod/dst_mnt/etc/fstab

echo "Adding luks keyfile for fs"
dev_uuid=$(sudo blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
sudo cp "${workdir}/rootkeys/rootkey.bin" "/home/peerpod/dst_mnt/etc/keys/luks-${dev_uuid}.key"
sudo chmod 600 "/home/peerpod/dst_mnt/etc/keys/luks-${dev_uuid}.key"

# Add LUKS keyfile to crypttab
echo "Add LUKS keyfile to crypttab"
sudo touch /home/peerpod/dst_mnt/etc/crypttab
sudo -E bash -c 'echo "${LUKS_NAME} UUID=$(sudo blkid -s UUID -o value ${tmp_nbd}2) /etc/keys/luks-$(blkid -s UUID -o value /dev/mapper/${LUKS_NAME}).key luks,discard,initramfs" > /home/peerpod/dst_mnt/etc/crypttab'
echo "ls ${dst_mnt}/etc/crypttab"
ls -ltrh "${dst_mnt}"/etc/crypttab
ls "${dst_mnt}"/etc/
cat "${dst_mnt}"/etc/crypttab

sudo chmod 744 /home/peerpod/dst_mnt/etc/crypttab

# Disable virtio_rng
sudo -E bash -c 'echo "blacklist virtio_rng" > /home/peerpod/dst_mnt/etc/modprobe.d/blacklist-virtio.conf'
sudo -E bash -c 'echo "s390_trng" > /home/peerpod/dst_mnt/etc/modules'

# Configure dracut and zipl
sudo -E bash -c 'echo "install_items+=\" /etc/keys/*.key \"" >> /home/peerpod/dst_mnt/etc/dracut.conf.d/cryptsetup.conf'
sudo -E bash -c 'echo "UMASK=0077" >> /home/peerpod/dst_mnt/etc/dracut.conf.d/initramfs.conf'
sudo -E bash -c 'cat <<END > /home/peerpod/dst_mnt/etc/zipl.conf
[defaultboot]
default=linux
target=/boot-se
targetbase=/dev/vda
targettype=scsi
targetblocksize=512
targetoffset=2048

[linux]
image = /boot-se/se.img
END'
cat "${dst_mnt}"/etc/zipl.conf
echo "Updating initramfs"
sudo chroot "${dst_mnt}" dracut -f /boot/initramfs-$(uname -r).img $(uname -r) || true
echo "ls ${dst_mnt}"
ls -ltrh ${dst_mnt}
echo "ls ${dst_mnt}/boot/"
ls -ltrh ${dst_mnt}/boot/
echo "ls /boot/"
ls -ltrh /boot/

# Create SE boot image
echo "Creating IBM Secure Execution boot image"
KERNEL_FILE=/boot/vmlinuz-$(uname -r)
INITRD_FILE=${dst_mnt}/boot/initramfs-$(uname -r).img
export SE_PARMLINE="root=/dev/mapper/${LUKS_NAME} panic=0 blacklist=virtio_rng swiotlb=262144 console=ttyS0 printk.time=0 systemd.getty_auto=0 systemd.firstboot=0 module.sig_enforce=1 quiet loglevel=0 systemd.show_status=0"
sudo touch /home/peerpod/dst_mnt/boot/parmfile
sudo -E bash -c 'echo "root=/dev/mapper/${LUKS_NAME} panic=0 blacklist=virtio_rng swiotlb=262144 console=ttyS0 printk.time=0 systemd.getty_auto=0 systemd.firstboot=0 module.sig_enforce=1 quiet loglevel=0 systemd.show_status=0" > /home/peerpod/dst_mnt/boot/parmfile'
echo "printing param file"
ls -lrh "${dst_mnt}"/boot/
cat "${dst_mnt}"/boot/parmfile
lsblk
sudo /usr/bin/genprotimg \
    --verbose \
    -i "${KERNEL_FILE}" \
    -r "${INITRD_FILE}" \
    -p "${dst_mnt}"/boot/parmfile \
    --no-verify \
    -k "/root/HKD.crt" \
    -o "${dst_mnt}"/boot-se/se.img

# Check if SE image was created
if [ ! -e ${dst_mnt}/boot-se/se.img ]; then
    echo "Failed to create SE image, exiting..."
    exit 1
fi
ls -ltrh "${dst_mnt}"/boot-se/se.img
ls -ltrh "${dst_mnt}"/boot-se

# Run zipl to prepare boot partition
echo "Running zipl to prepare boot partition"
sudo chroot "${dst_mnt}" zipl --targetbase ${tmp_nbd} \
    --targettype scsi \
    --targetblocksize 512 \
    --targetoffset 2048 \
    --target /boot-se \
    --image /boot-se/se.img

# Clean up
echo "Cleaning up"
sudo umount ${workdir}/rootkeys/
sudo rm -rf ${workdir}/rootkeys
sudo umount ${dst_mnt}/etc/keys
sudo umount ${dst_mnt}/boot-se
sudo umount ${dst_mnt}/dev
sudo umount ${dst_mnt}/proc
sudo umount ${dst_mnt}/sys
sudo umount ${dst_mnt}
sudo rm -rf ${src_mnt} ${dst_mnt}

echo "Script completed successfully"
echo "Closing encrypted root partition"
sudo cryptsetup close $LUKS_NAME
sleep 10