#!/bin/bash

export LANG=C.UTF-8

echo "***********starting************"
# Check if SE_BOOT variable is set to 1 and architecture is s390x
if [ "${SE_BOOT:-0}" != "1" ]; then
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
echo "**********df -h****************"
df -h
sudo yum clean all

# Set up disk and partitions
workdir=$(pwd)
disksize=100G
device=$(sudo lsblk --json | jq -r --arg disksize "$disksize" '.blockdevices[] | select(.size == $disksize and .children == null and .mountpoint == null) | .name')
echo $device
echo "*************** lsblk json **************"
sudo lsblk --json 

export tmp_nbd="/dev/$device"
export dst_mnt=$workdir/dst_mnt
export src_mnt=$workdir/src_mnt

echo "Creating boot-se and root partitions"
sudo parted -a optimal ${tmp_nbd} mklabel gpt \
    mkpart boot-se ext4 1MiB 256MiB \
    mkpart root 256MiB ${disksize}\
    set 1 boot on

echo "**********df -h****************"
df -h 

echo "Waiting for the two partitions to show up"
while true; do
    sleep 1
    [ -e ${tmp_nbd}2 ] && break
done

# Format boot-se partition
echo "Formatting boot-se partition"
sudo mke2fs -t ext4 -L boot-se ${tmp_nbd}1
boot_uuid=$(sudo blkid ${tmp_nbd}1 -s PARTUUID -o value)
export boot_uuid
echo " ********* part uuid $boot_uuid ***********"

# Set up encrypted root partition
echo "Setting up encrypted root partition"
sudo mkdir ${workdir}/rootkeys
sudo mount -t tmpfs rootkeys ${workdir}/rootkeys
sudo dd if=/dev/random of=${workdir}/rootkeys/rootkey.bin bs=1 count=64 &> /dev/null
echo " ********* ls rootkeys ***********"
ls ${workdir}/rootkeys/
echo YES | sudo cryptsetup luksFormat --type luks2 ${tmp_nbd}2 --key-file ${workdir}/rootkeys/rootkey.bin
echo "***************** lsblk and blkid *****************"
lsblk
blkid
echo "Setting luks name for root partition"
LUKS_NAME="luks-$(sudo blkid -s UUID -o value ${tmp_nbd}2)"
export LUKS_NAME
echo "luks name is: $LUKS_NAME"
sudo cryptsetup open ${tmp_nbd}2 $LUKS_NAME --key-file ${workdir}/rootkeys/rootkey.bin

echo "************** ls ${workdir}/rootkeys/*****************"
ls ${workdir}/rootkeys/

# Copy the root filesystem
echo "Copying the root filesystem"
echo "************ ls root ***************"
ls /root
sudo mkfs.ext4 -L "root" /dev/mapper/${LUKS_NAME}
sudo mkdir -p ${dst_mnt}
sudo mkdir -p ${src_mnt}
sudo mount /dev/mapper/$LUKS_NAME ${dst_mnt}
echo "************ dstmnt *************"
ls ${dst_mnt}
sudo mkdir ${dst_mnt}/boot-se
sudo mount -o norecovery ${tmp_nbd}1 ${dst_mnt}/boot-se
echo "******************** ls boot-se *********"
ls ${dst_mnt}/boot-se
sudo mount --bind -o ro / ${src_mnt}
echo "********************ls ${src_mnt} srcmnt****************"
ls ${src_mnt}
tar_opts=(--numeric-owner --preserve-permissions --acl --selinux --xattrs --xattrs-include='*' --sparse  --one-file-system)
sudo tar -cf - "${tar_opts[@]}" --sort=none -C ${src_mnt} . | sudo tar -xf - "${tar_opts[@]}" --preserve-order  -C "$dst_mnt"

echo "************** ls src boot"
ls -ltr ${src_mnt}/boot
echo "************** ls dst"
ls -ltr $dst_mnt
echo "************** ls dst boot"
ls -ltr $dst_mnt/boot

sudo umount ${src_mnt}
echo "Partition copy complete"

# Prepare secure execution boot image
echo "Preparing secure execution boot image"
sudo rm -rf ${dst_mnt}/home/peerpod/*
sudo mount -t sysfs sysfs ${dst_mnt}/sys
sudo mount -t proc proc ${dst_mnt}/proc
sudo mount --bind /dev ${dst_mnt}/dev

echo "ls proc"
ls ${dst_mnt}/proc
echo "cat proc/cmdline"
cat ${dst_mnt}/proc/cmdline


sudo mkdir -p ${dst_mnt}/etc/keys
sudo chmod 744 ${dst_mnt}/etc/keys/
sudo mount -t tmpfs keys ${dst_mnt}/etc/keys
echo " ********** ls keys ************"
ls ${dst_mnt}/etc/keys
echo "***************** lsblk and blkid *****************"
lsblk
blkid
# Add configuration files
echo "Adding fstab"
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/fstab
#This file was auto-generated
/dev/mapper/$LUKS_NAME    /        ext4  defaults 1 1
PARTUUID=$boot_uuid    /boot-se    ext4  norecovery 1 2
END'

cat ${dst_mnt}/etc/fstab

echo "Adding luks keyfile for fs"
dev_uuid=$(sudo blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
echo "devuuid: $dev_uuid"
sudo cp "${workdir}/rootkeys/rootkey.bin" "${dst_mnt}/etc/keys/luks-${dev_uuid}.key"
sudo chmod 744 "${dst_mnt}/etc/keys/luks-${dev_uuid}.key"
echo "********* ls etc ************"
ls ${dst_mnt}/etc/

echo " *********** key verify *************"
ls ${dst_mnt}/etc/keys/
sudo chmod 744 ${dst_mnt}/etc/keys/
ls -latr ${dst_mnt}/etc/keys/
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/crypttab
#This file was auto-generated
$LUKS_NAME UUID=$(sudo blkid -s UUID -o value ${tmp_nbd}2) /etc/keys/luks-$(blkid -s UUID -o value /dev/mapper/$LUKS_NAME).key luks,discard,initramfs
END'
sudo chmod 744 "${dst_mnt}/etc/crypttab"

echo "***********crypttab*************"
cat ${dst_mnt}/etc/crypttab

# Disable virtio_rng
sudo -E bash -c 'cat <<END > ${dst_mnt}/etc/modprobe.d/blacklist-virtio.conf
#do not trust rng from hypervisor
blacklist virtio_rng
END'

echo "ls ${dst_mnt}/etc/modprobe.d/"
ls ${dst_mnt}/etc/modprobe.d/

sudo -E bash -c 'echo s390_trng >> ${dst_mnt}/etc/modules'

echo "ls ${dst_mnt}/etc/dracut.conf.d/"
ls ${dst_mnt}/etc/dracut.conf.d/

echo "********ls ${dst_mnt}/etc/**********"
ls ${dst_mnt}/etc/
echo "Preparing files needed for mkinitrd"
ls ${dst_mnt}/etc/
echo "keys"
ls ${dst_mnt}/etc/keys
echo "crypttab"
cat ${dst_mnt}/etc/crypttab
echo "fstab"
cat ${dst_mnt}/etc/fstab
#sudo -E bash -c 'echo "KEYFILE_PATTERN=\"/etc/keys/*.key\"" >> ${dst_mnt}/etc/dracut.conf.d/cryptsetup.conf'
#sudo -E bash -c 'echo "install_items+=\" /etc/keys/*.key \"" >> ${dst_mnt}/etc/dracut.conf.d/cryptsetup.conf'
#sudo -E bash -c 'echo "KEYFILE_PATTERN=\"/etc/fstab\"" >> ${dst_mnt}/etc/dracut.conf.d/fstab.conf'
#sudo -E bash -c 'echo "install_items+=\" /etc/fstab \"" >> ${dst_mnt}/etc/dracut.conf.d/fstab.conf'
#sudo -E bash -c 'echo "KEYFILE_PATTERN=\"/etc/crypttab\"" >> ${dst_mnt}/etc/dracut.conf.d/crypttab.conf'
#sudo -E bash -c 'echo "install_items+=\" /etc/crypttab \"" >> ${dst_mnt}/etc/dracut.conf.d/crypttab.conf'
#sudo -E bash -c 'echo "KEYFILE_PATTERN=\"/etc/zipl.conf\"" >> ${dst_mnt}/etc/dracut.conf.d/zipl.conf'
#sudo -E bash -c 'echo "install_items+=\" /etc/zipl.conf \"" >> ${dst_mnt}/etc/dracut.conf.d/zipl.conf'
sudo -E bash -c 'echo "UMASK=0077" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
sudo -E bash -c 'echo "add_drivers+=\" dm_crypt \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
sudo -E bash -c 'echo "add_dracutmodules+=\" crypt \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
sudo -E bash -c 'echo "KEYFILE_PATTERN=\" /etc/keys/*.key \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
sudo -E bash -c 'echo "install_items+=\" /etc/keys/*.key \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
echo 'install_items+=" /etc/fstab "' >>  ${dst_mnt}/etc/dracut.conf.d/crypt.conf
echo 'install_items+=" /etc/crypttab "' >>  ${dst_mnt}/etc/dracut.conf.d/crypt.conf
#echo 'add_dracutmodules+=" /sbin/cryptsetup "' | sudo tee ${dst_mnt}/etc/dracut.conf.d/crypt.conf
#echo 'add_dracutmodules+=" crypt "' | sudo tee ${dst_mnt}/etc/dracut.conf.d/crypt.conf
#echo 'install_items+=" /etc/keys/*.key "' | sudo tee -a ${dst_mnt}/etc/dracut.conf.d/crypt.conf
#sudo -E bash -c 'echo "KEYFILE_PATTERN=\" /etc/keys/*.key \"" >> ${dst_mnt}/etc/dracut.conf.d/cryptsetup.conf'
#sudo -E bash -c 'echo "install_items+=\" /etc/keys/*.key \"" >> ${dst_mnt}/etc/dracut.conf.d/cryptsetup.conf'
#sudo -E bash -c 'echo "UMASK=0077" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
#sudo -E bash -c 'echo "add_drivers+=\" dm_crypt \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
#sudo -E bash -c 'echo "add_dracutmodules+=\" crypt lvm \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
#sudo -E bash -c 'echo "omit_dracutmodules+=\" systemd \"" >> ${dst_mnt}/etc/dracut.conf.d/crypt.conf'
cat ${dst_mnt}/etc/dracut.conf.d/crypt.conf
#sudo -E bash -c 'echo "KEYFILE_PATTERN=\"/etc/keys/*.key\"" >> ${dst_mnt}/etc/cryptsetup-initramfs/conf-hook'
#sudo -E bash -c 'echo "UMASK=0077" >> ${dst_mnt}/etc/initramfs-tools/initramfs.conf'
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

echo "************** normal /etc"
ls /etc
cat /etc/zipl.conf
echo "************** dst mnt /etc"
ls ${dst_mnt}/etc/
cat ${dst_mnt}/etc/zipl.conf

echo "Updating initial ram disk"
echo "before dracut"
ls ${dst_mnt}/boot/

#sudo chroot ${dst_mnt} dracut -f --regenerate-all

ls /boot/
ls ${dst_mnt}/boot
cp /boot/initramfs-$(uname -r).img ${dst_mnt}/boot/
echo "dracut initramfs done"
ls ${dst_mnt}
echo "Generating an IBM Secure Execution image"

# Clean up kernel names and make sure they are where we expect them
echo "ls bootdst after dracut"
ls ${dst_mnt}/boot/
cp /boot/vmlinuz-$(uname -r) ${dst_mnt}/boot/
echo "ls bootdst after dracut and vmlinuz"
ls ${dst_mnt}/boot/
# sudo chroot ${dst_mnt} dracut -f --kver
ls ${dst_mnt}/boot/
#sudo chroot ${dst_mnt} dracut -f -v
sudo chroot ${dst_mnt} dracut --force --include /etc/crypttab /etc/crypttab
sudo chroot ${dst_mnt} dracut --force --include /etc/fstab /etc/fstab
sudo chroot ${dst_mnt} dracut --include /etc/dracut.conf.d/
sudo chroot ${dst_mnt} dracut -f -v
ls ${dst_mnt}/
echo "lsinitrd"
ls ${dst_mnt}/boot/
lsinitrd ${dst_mnt}/boot/initramfs-$(uname -r).img
lsinitrd | grep /etc/crypttab
lsinitrd | grep /etc/keys/luks-$(blkid -s UUID -o value /dev/mapper/$LUKS_NAME).key
ls ${dst_mnt}/
#sudo chroot ${dst_mnt} lsinitrd -v ${dst_mnt}/boot/initramfs-$(uname -r).img
KERNEL_FILE=${dst_mnt}/boot/vmlinuz-$(uname -r)
INITRD_FILE=${dst_mnt}/boot/initramfs-$(uname -r).img
echo "Creating SE boot image"
#export SE_PARMLINE="root=/dev/mapper/$LUKS_NAME rw  rd.luks.name="$(sudo blkid -s UUID -o value ${tmp_nbd}2)"=$LUKS_NAME rd.auto=1 rd.luks.uuid="$(sudo blkid -s UUID -o value ${tmp_nbd}2)" rd.luks.partuuid="$(sudo blkid -s PARTUUID -o value ${tmp_nbd}2)"  rd.retry=30 console=ttysclp0 quiet panic=0 rd.shell=1 blacklist=virtio_rng swiotlb=262144 luks.options=timeout=30s"
#export SE_PARMLINE="panic=0 blacklist=virtio_rng swiotlb=262144 cloud-init=disabled console=ttyS0 printk.time=0 systemd.getty_auto=0 systemd.firstboot=0 module.sig_enforce=1 quiet loglevel=0 systemd.show_status=0"
export SE_PARMLINE="root=/dev/mapper/$LUKS_NAME  rd.auto=1 rd.retry=30 console=ttysclp0 quiet panic=0 rd.shell=1 blacklist=virtio_rng swiotlb=262144"
sudo -E bash -c 'echo "${SE_PARMLINE}" > ${dst_mnt}/boot/parmfile'
echo "cat parmfile"
cat ${dst_mnt}/boot/parmfile
ls ${dst_mnt}/boot
cat "${host_keys}"
echo "ls dst"
ls ${dst_mnt}
echo "ls dst/etc"
ls ${dst_mnt}/etc
echo "keys"
ls ${dst_mnt}/etc/keys
echo "ls dst/run"
ls ${dst_mnt}/run
echo "ls dst/proc"
ls ${dst_mnt}/proc
echo "dst/dev"
ls ${dst_mnt}/dev
echo "dst/sys"
ls ${dst_mnt}/sys
blkid
cat /etc/crypttab
cat ${dst_mnt}/etc/crypttab
sudo -E /usr/bin/genprotimg \
    -i ${KERNEL_FILE} \
    -r ${INITRD_FILE} \
    -p ${dst_mnt}/boot/parmfile \
    --no-verify \
    ${host_keys} \
    -o ${dst_mnt}/boot-se/se.img
echo "done"
ls -l "/dev/mapper/$LUKS_NAME"
# Check if SE image was created
[ ! -e ${dst_mnt}/boot-se/se.img ] && exit 1
echo "not here"
#cp root.tar.gz ${dst_mnt}/boot-se/
# Clean /boot directory
sudo rm -rf ${dst_mnt}/boot/*
echo "*************ls bootse"
ls ${dst_mnt}/boot-se
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