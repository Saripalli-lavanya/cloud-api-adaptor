#!/bin/bash

export LANG=C.UTF-8

echo "starting************"
# Check if SE_BOOT variable is set to 1 and architecture is s390x
if [ "${SE_BOOT:-0}" != "1" ]; then
    echo "exit**************"
    exit 0
elif [ "${ARCH}" != "s390x" ]; then
    echo "Building of SE podvm image is only supported for s390x"
    exit 0
fi

echo "Building SE podvm image for $ARCH"

# Find host key files
echo "Finding host key files"
host_keys=""
rm /tmp/files/.dummy.crt || true
for i in /tmp/files/*.crt; do
    [[ -f "$i" ]] || break
    echo "found host key file: \"${i}\""
    host_keys+="-k ${i} "
done
[[ -z $host_keys ]] && echo "Didn't find host key files, please download host key files to 'files' folder " && exit 1

# Install necessary packages
echo "Installing necessary packages"
#sudo dnf install -y epel-release
echo "df -h"
df -h
#echo "codeready builder"
#sudo yum repolist
#subscription-manager repos --enable rhel-9-for-s390x-appstream-rpms
#sudo yum repolist
echo "clean all"
#sudo yum autoremove -y
sudo yum clean all
#sudo rm -rf /var/cache/yum
#echo "eple"
#sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
echo "jq1"
#sudo dnf install -y jq
#sudo dnf install -y https://rpmfind.net/linux/centos-stream/9-stream/AppStream/s390x/os/Packages/jq-1.6-16.el9.s390x.rpm
jq --version
#wget http://mirror.centos.org/centos/9-stream/BaseOS/s390x/os/Packages/oniguruma-6.9.6-1.el9.5.s390x.rpm
#sudo rpm -ivh oniguruma-6.9.6-1.el9.5.s390x.rpm

# Set up disk and partitions
workdir=$(pwd)
disksize=100G
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
sudo lsblk --json
echo $device
echo "Found target device $device"
export tmp_nbd="/dev/$device"
export dst_mnt=$workdir/dst_mnt
export src_mnt=$workdir/src_mnt

echo "Creating boot-se and root partitions"
sudo parted -a optimal ${tmp_nbd} mklabel gpt \
    mkpart boot-se ext4 1MiB 256MiB \
    mkpart root 256MiB "${disksize}" \
    set 1 boot on

echo "Waiting for the two partitions to show up"
while true; do
    sleep 1
    [ -e ${tmp_nbd}2 ] && break
done

# Format boot-se partition
echo "Formatting boot-se partition"
sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
root_uuid=$(sudo blkid ${tmp_nbd}2 -s PARTUUID -o value)
export boot_uuid
export root_uuid
# Set up encrypted root partition
echo "Setting up encrypted root partition"
sudo mkdir ${workdir}/rootkeys
sudo mount -t tmpfs rootkeys ${workdir}/rootkeys
sudo dd if=/dev/random of=${workdir}/rootkeys/rootkey.bin bs=1 count=64 &> /dev/null
echo YES | sudo cryptsetup luksFormat --type luks2 ${tmp_nbd}2 --key-file ${workdir}/rootkeys/rootkey.bin
mkdir -p /tmp/files/etc/rootkeys/ &> /dev/null
echo "ls ${workdir}/rootkeys/" 
ls ${workdir}/rootkeys/ &> /dev/null
sudo cp -a ${workdir}/rootkeys/ /tmp/files/etc/rootkeys/
echo "Setting luks name for root partition"
LUKS_NAME="luks-$(sudo blkid -s UUID -o value ${tmp_nbd}2)"
export LUKS_NAME
echo "luks name is: $LUKS_NAME"
sudo cryptsetup open ${tmp_nbd}2 $LUKS_NAME --key-file ${workdir}/rootkeys/rootkey.bin

# Copy the root filesystem
echo "Copying the root filesystem"
sudo mkfs.ext4 -L "root" /dev/mapper/${LUKS_NAME}
sudo mount /dev/mapper/$LUKS_NAME ${dst_mnt}
sudo mkdir -p ${dst_mnt}
sudo mkdir -p ${src_mnt}
sudo mkdir ${dst_mnt}/etc
sudo mkdir ${dst_mnt}/boot-se
sudo mkdir ${dst_mnt}/boot
sudo mount -o norecovery ${tmp_nbd}1 ${dst_mnt}/boot-se
sudo mount --bind -o ro / ${src_mnt}
sudo mount -o bind ${src_mnt}/boot ${dst_mnt}/boot
tar_opts=(--numeric-owner --preserve-permissions --acl --selinux --xattrs --xattrs-include='*' --sparse)
tar -cf - "${tar_opts[@]}" --sort=none -C "$src_mnt" . | tar -xf - "${tar_opts[@]}" --preserve-order  -C "$dst_mnt"
sudo umount ${src_mnt}
echo "Partition copy complete"

# Prepare secure execution boot image
echo "Preparing secure execution boot image"
sudo rm -rf ${dst_mnt}/home/peerpod/*

sudo mount -t sysfs sysfs ${dst_mnt}/sys
sudo mount -t proc proc ${dst_mnt}/proc
sudo mount --bind /dev ${dst_mnt}/dev

sudo mkdir -p ${dst_mnt}/etc/keys
sudo mount -t tmpfs keys ${dst_mnt}/etc/keys

# Add configuration files
echo "Adding fstab"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/fstab
#This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=$boot_uuid    /boot-se    ext4  norecovery 1 2
END'
echo $boot_uuid 
cat ${dst_mnt}/etc/fstab

echo "Adding luks keyfile for fs"
dev_uuid=$(sudo blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
sudo cp "${workdir}/rootkeys/rootkey.bin" "${dst_mnt}/etc/keys/luks-${dev_uuid}.key"
sudo chmod 600 "${dst_mnt}/etc/keys/luks-${dev_uuid}.key"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/crypttab
#This file was auto-generated
$LUKS_NAME UUID=$(sudo blkid -s UUID -o value ${tmp_nbd}2) /etc/keys/luks-$(blkid -s UUID -o value /dev/mapper/$LUKS_NAME).key luks,discard,initramfs
END'
sudo chmod 744 "${dst_mnt}/etc/crypttab"

# Disable virtio_rng
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/modprobe.d/blacklist-virtio.conf
#do not trust rng from hypervisor
blacklist virtio_rng
END'

sudo -E bash -c 'echo s390_trng >> ${dst_mnt}/etc/modules'

echo "Preparing files needed for mkinitrd"
ls ${dst_mnt}/etc/
sudo -E bash -c 'echo "install_items+=\" /etc/keys/*.key \"" >> ${dst_mnt}/etc/dracut.conf.d/cryptsetup.conf'
sudo -E bash -c 'echo "UMASK=0077" >> ${dst_mnt}/etc/dracut.conf.d/initramfs.conf'
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/zipl.conf
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

echo "Updating initial ram disk"
echo "before dracut"
ls ${dst_mnt}/boot/
sudo chroot "${dst_mnt}" dracut -f || true

echo "Generating an IBM Secure Execution image"

# Clean up kernel names and make sure they are where we expect them
echo "ls bootdst after dracut"
ls ${dst_mnt}/boot/
cp /boot/vmlinuz-$(uname -r) ${dst_mnt}/boot/
echo "ls bootdst after dracut and vmlinuz"
ls ${dst_mnt}/boot/

KERNEL_FILE=${dst_mnt}/boot/vmlinuz-$(uname -r)
INITRD_FILE=${dst_mnt}/boot/initramfs-$(uname -r).img
echo "Creating SE boot image"
# export SE_PARMLINE="panic=0 blacklist=virtio_rng swiotlb=262144 cloud-init=disabled console=ttyS0 printk.time=0 systemd.getty_auto=0 systemd.firstboot=0 module.sig_enforce=1 quiet loglevel=0 systemd.show_status=0"
export SE_PARMLINE="root=/dev/mapper/$LUKS_NAME console=ttysclp0 quiet panic=0 rd.shell=0 blacklist=virtio_rng swiotlb=262144"
sudo -E bash -c 'echo "${SE_PARMLINE}" > ${dst_mnt}/boot/parmfile'
echo "cat parmfile"
cat ${dst_mnt}/boot/parmfile
ls ${dst_mnt}/boot
cat "${host_keys}"
sudo -E /usr/bin/genprotimg \
    -i ${KERNEL_FILE} \
    -r ${INITRD_FILE} \
    -p ${dst_mnt}/boot/parmfile \
    --no-verify \
    ${host_keys} \
    -o ${dst_mnt}/boot-se/se.img
echo "done"
# Check if SE image was created
[ ! -e ${dst_mnt}/boot-se/se.img ] && exit 1
echo "not here"
# Clean /boot directory
sudo rm -rf ${dst_mnt}/boot/*

echo "Running zipl to prepare boot partition"
sudo chroot ${dst_mnt} zipl --targetbase ${tmp_nbd}1 \
    --targettype scsi \
    --targetblocksize 512 \
    --targetoffset 2048 \
    --target /boot-se \
    --image /boot-se/se.img

# Clean up
echo "Cleaning up"
sudo umount ${workdir}/rootkeys/ || true
sudo rm -rf ${workdir}/rootkeys
sudo umount ${dst_mnt}/etc/keys
sudo umount ${dst_mnt}/boot-se
sudo umount ${dst_mnt}/dev
sudo umount ${dst_mnt}/proc
sudo umount ${dst_mnt}/sys
sudo umount ${dst_mnt}
sudo rm -rf ${src_mnt} ${dst_mnt}

echo "Closing encrypted root partition"
sudo cryptsetup close $LUKS_NAME

sleep 10

echo "RHEL-based SE podvm qcow2 image build completed successfully"