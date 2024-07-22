#!/bin/bash

export LANG=C.UTF-8

# echo "Starting script"

# # Check if SE_BOOT variable is set to 1 and architecture is s390x
# if [ "${SE_BOOT:-0}" != "1" ]; then
#     echo "SE_BOOT variable not set to 1, exiting"
#     exit 0
# elif [ "${ARCH}" != "s390x" ]; then
#     echo "Building of SE podvm image is only supported for s390x"
#     exit 0
# fi

# echo "Building SE podvm image for $ARCH"

# # Find host key files
# echo "Finding host key files"
# host_keys=""
# for i in /tmp/files/*.crt; do
#     [[ -f "$i" ]] || break
#     echo "Found host key file: ${i}"
#     host_keys+="-k ${i} "
# done
# [[ -z $host_keys ]] && echo "Didn't find host key files, please download host key files to 'files' folder " && exit 1

# Install necessary packages

# Set up disk and partitions
workdir=$(pwd)
disksize=100G
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
export tmp_nbd="/dev/$device"
export dst_mnt=$workdir/dst_mnt
export src_mnt=$workdir/src_mnt

# echo "Creating boot-se and root partitions"
# sudo parted -a optimal ${tmp_nbd} mklabel gpt \
#     mkpart boot-se ext4 1MiB 256MiB \
#     mkpart root 256MiB ${disksize} \
#     set 1 boot on

# # Wait for partitions to show up
# while true; do
#     sleep 1
#     [ -e ${tmp_nbd}2 ] && break
# done

# # Format boot-se partition
# echo "Formatting boot-se partition"
# sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
export boot_uuid

echo "Setting up encrypted root partition with passphrase"
echo "mystrongpassphrase" | sudo cryptsetup luksFormat --type luks2 ${tmp_nbd}2 -
echo "mystrongpassphrase" | sudo cryptsetup open ${tmp_nbd}2 $LUKS_NAME --type luks2 -
sudo mkfs.ext4 -L "root" /dev/mapper/$LUKS_NAME

sudo mkdir -p ${dst_mnt}
sudo mount /dev/mapper/$LUKS_NAME ${dst_mnt}
sudo mkdir -p ${dst_mnt}/boot-se
sudo mount -o norecovery ${tmp_nbd}1 ${dst_mnt}/boot-se

sudo mkdir -p ${src_mnt}
sudo mount --bind -o ro / ${src_mnt}
tar_opts=(--numeric-owner --preserve-permissions --acl --selinux --xattrs --xattrs-include='*' --sparse  --one-file-system)
sudo tar -cf - "${tar_opts[@]}" --sort=none -C ${src_mnt} . | sudo tar -xf - "${tar_opts[@]}" --preserve-order  -C "$dst_mnt"

sudo mount -t sysfs sysfs ${dst_mnt}/sys
sudo mount -t proc proc ${dst_mnt}/proc
sudo mount --bind /dev ${dst_mnt}/dev

sudo bash -c 'cat <<END > ${dst_mnt}/etc/fstab
# This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=${boot_uuid}   /boot-se    ext4  norecovery 1 2
END'

sudo bash -c 'cat <<END > ${dst_mnt}/etc/crypttab
# This file was auto-generated
$LUKS_NAME /dev/${device}2 none luks,discard,initramfs
END'

sudo chroot ${dst_mnt} dracut -f --regenerate-all
sudo cp /boot/vmlinuz-$(uname -r) ${dst_mnt}/boot/
sudo bash -c 'echo "root=/dev/mapper/$LUKS_NAME console=ttysclp0 quiet panic=0 rd.shell=1 rd.debug=1 blacklist=virtio_rng swiotlb=262144" > ${dst_mnt}/boot/parmfile'
sudo /usr/bin/genprotimg -i ${dst_mnt}/boot/vmlinuz-$(uname -r) -r ${dst_mnt}/boot/initramfs-$(uname -r).img -p ${dst_mnt}/boot/parmfile --no-verify -k ./HKD -o ${dst_mnt}/boot-se/se.img

# Clean up
sudo umount ${dst_mnt}/boot-se
sudo umount ${dst_mnt}
sudo cryptsetup close $LUKS_NAME
sudo rm -rf ${workdir}/rootkeys ${src_mnt} ${dst_mnt}

echo "Script execution completed successfully"
