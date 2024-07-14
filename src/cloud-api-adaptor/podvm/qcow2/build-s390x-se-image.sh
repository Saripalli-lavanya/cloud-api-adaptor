#!/bin/bash -x

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

if [ "${SE_BOOT:-0}" != "1" ]; then
    exit 0
elif [ "${ARCH}" != "s390x" ]; then
    echo "Building of SE podvm image is only supported for s390x"
    exit 0
fi

echo "Building SE podvm image for $(uname -m)"
echo "Finding host key files"
host_keys=""
rm /tmp/files/.dummy.crt || true
for i in /tmp/files/*.crt; do
    [[ -f "$i" ]] || break
    echo "found host key file: \"${i}\""
    host_keys+="-k ${i} "
done
[[ -z $host_keys ]] && echo "Didn't find host key files, please download host key files to 'files' folder " && exit 1


workdir=$(pwd)
disksize=100G
sudo lsblk --json
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
echo "Found target device $device"

# Prepare device and partitions
export tmp_nbd="/dev/$device"
export dst_mnt=$workdir/dst_mnt
export src_mnt=$workdir/src_mnt

echo "Creating boot-se and root partitions"

sudo parted -a optimal ${tmp_nbd} mklabel gpt \
    mkpart boot-se ext4 1MiB 256MiB \
    mkpart root 256MiB 6400MiB \
    mkpart data 6400MiB ${disksize} \
    set 1 boot on

echo "Waiting for the two partitions to show up"
while true; do
    sleep 1
    [ -e ${tmp_nbd}2 ] && break
done

echo "Formatting boot-se partition"
sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
export boot_uuid

echo "Setting up encrypted root partition"
sudo mkdir ${workdir}/rootkeys
sudo mount -t tmpfs rootkeys ${workdir}/rootkeys
sudo dd if=/dev/random of=${workdir}/rootkeys/rootkey.bin bs=1 count=64 &> /dev/null
echo YES | sudo cryptsetup luksFormat --type luks2 ${tmp_nbd}2 --key-file ${workdir}/rootkeys/rootkey.bin

echo "Setting luks name for root partition"
LUKS_NAME="luks-$(sudo blkid -s UUID -o value ${tmp_nbd}2)"
export LUKS_NAME
echo "luks name is: $LUKS_NAME"
sudo cryptsetup open ${tmp_nbd}2 $LUKS_NAME --key-file ${workdir}/rootkeys/rootkey.bin

echo "Copying the root filesystem"
sudo mkfs.ext4 -L "root" /dev/mapper/${LUKS_NAME}
sudo mkdir -p ${dst_mnt}
sudo mkdir -p ${src_mnt}
sudo mount /dev/mapper/$LUKS_NAME ${dst_mnt}
sudo mkdir ${dst_mnt}/boot-se
sudo mount -o norecovery ${tmp_nbd}1 ${dst_mnt}/boot-se

# Copy root filesystem to encrypted partition
sudo mount --bind -o ro / ${src_mnt}
tar_opts=(--numeric-owner --preserve-permissions --acl --selinux --xattrs --xattrs-include='*' --sparse --one-file-system)
sudo tar -cf - "${tar_opts[@]}" --sort=none -C ${src_mnt} . | sudo tar -xf - "${tar_opts[@]}" --preserve-order -C "$dst_mnt"
sudo umount ${src_mnt}
echo "Partition copy complete"

echo "Preparing secure execution boot image"
sudo rm -rf ${dst_mnt}/home/peerpod/*

# Mount necessary filesystems
sudo mount -t sysfs sysfs ${dst_mnt}/sys
sudo mount -t proc proc ${dst_mnt}/proc
sudo mount --bind /dev ${dst_mnt}/dev

sudo mkdir -p ${dst_mnt}/etc/keys
sudo mount -t tmpfs keys ${dst_mnt}/etc/keys

echo "Adding fstab"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/fstab
# This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=$boot_uuid    /boot-se    ext4  norecovery 1 2
END'

echo "Adding luks keyfile for fs"
dev_uuid=$(sudo blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
sudo cp "${workdir}/rootkeys/rootkey.bin" "${dst_mnt}/etc/keys/luks-${dev_uuid}.key"
sudo chmod 600 "${dst_mnt}/etc/keys/luks-${dev_uuid}.key"

sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/crypttab
# This file was auto-generated
$LUKS_NAME UUID=$(sudo blkid -s UUID -o value ${tmp_nbd}2) /etc/keys/luks-$(blkid -s UUID -o value /dev/mapper/$LUKS_NAME).key luks,discard,initramfs
END'
sudo chmod 744 "${dst_mnt}/etc/crypttab"

echo "Configuring kernel modules"
sudo -E bash -c 'echo "blacklist virtio_rng" > ${dst_mnt}/etc/modprobe.d/blacklist-virtio.conf'
sudo -E bash -c 'echo "s390_trng" >> ${dst_mnt}/etc/modules'

sudo mkdir -p ${dst_mnt}/etc/cryptsetup-initramfs/
sudo touch ${dst_mnt}/etc/cryptsetup-initramfs/conf-hook
sudo mkdir -p ${dst_mnt}/etc/initramfs-tools/
sudo touch ${dst_mnt}/etc/initramfs-tools/initramfs.conf
echo "Creating SE boot image"
# Example for zipl.conf creation
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/zipl.conf
# This file was auto-generated
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

echo "Updating initial ram disk"
sudo chroot "${dst_mnt}" dracut -f || true

# Adjusted example for /etc/fstab
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/fstab
#This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=$boot_uuid    /boot-se    ext4  defaults,norecovery 1 2
END'

echo "Generating an IBM Secure Execution image"
KERNEL_FILE=$(readlink ${dst_mnt}/boot/vmlinuz)
INITRD_FILE=$(readlink ${dst_mnt}/boot/initrd.img)

echo "Creating SE boot image"
sudo wget https://github.com/ibm-s390-tools/s390-tools/tree/master/genprotimg -O /usr/bin/genprotimg
sudo /usr/bin/genprotimg --version
export SE_PARMLINE="root=/dev/mapper/$LUKS_NAME console=ttysclp0 quiet panic=0 rd.shell=0 blacklist=virtio_rng swiotlb=262144"
sudo -E bash -c 'echo "${SE_PARMLINE}" > ${dst_mnt}/boot/parmfile'
sudo -E /usr/bin/genprotimg \
    -i ${dst_mnt}/boot/${KERNEL_FILE} \
    -r ${dst_mnt}/boot/${INITRD_FILE} \
    -p ${dst_mnt}/boot/parmfile \
    --no-verify \
    ${host_keys} \
    -o ${dst_mnt}/boot-se/se.img

[ ! -e ${dst_mnt}/boot-se/se.img ] && { echo "Error: SE image creation failed."; exit 1; }

echo "Running zipl to prepare boot partition"
sudo chroot ${dst_mnt} zipl --targetbase ${tmp_nbd} \
    --targettype scsi \
    --targetblocksize 512 \
    --targetoffset 2048 \
    --target /boot-se \
    --image /boot-se/se.img

echo "Cleaning up"
sudo umount ${workdir}/rootkeys/ || true
sudo rm -rf ${workdir}/rootkeys
sudo umount ${dst_mnt}/etc/keys || true
sudo umount ${dst_mnt}/boot-se || true
sudo umount ${dst_mnt}/dev || true
sudo umount ${dst_mnt}/proc || true
sudo umount ${dst_mnt}/sys || true
sudo umount ${dst_mnt} || true
sudo rm -rf ${src_mnt} ${dst_mnt}

echo "Closing encrypted root partition"
sudo cryptsetup close $LUKS_NAME
sleep 10
