[root@a3elp61 home]# tmp_img_path="${workdir}/tmpsl.qcow2"
[root@a3elp61 home]# tmp_nbd=/dev/nbd1^C
[root@a3elp61 home]# disksize=100G
[root@a3elp61 home]# 
[root@a3elp61 home]# qemu-img create -f qcow2 "${tmp_img_path}" "${disksize}"
Formatting './tmpsl.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=107374182400 lazy_refcounts=off refcount_bits=16
[root@a3elp61 home]# 

IMAGE_URL=podvmsl.qcow2 
 1012  export ORG_ID="1979710"
 1013  export ACTIVATION_KEY="RHEL-TEST"
 1014  export REGISTER_CMD="subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}"
 1015  export LIBGUESTFS_BACKEND=direct
 1016  virt-customize -v -x -a ${IMAGE_URL} --run-command "${REGISTER_CMD}" --install jq,cryptsetup
 1017  history

sudo virt-install  --memory 4096  --vcpus 4  --name sl-se-hvbd3 --disk ./podvmluks.qcow2,device=disk,bus=virtio,format=qcow2  --disk /home/anjana/cloud-init.iso,device=cdrom  --os-variant rhel9.1  --graphics none  --import --disk /home/tmpluks.qcow2,device=disk,bus=virtio,format=qcow2 


Inside qcow2

 1  workdir=.
    2  tmp_nbd=/dev/vdb
    3  dst_mnt=./dst_mnt
    4  disksize=100G
    5  sudo parted -a optimal "${tmp_nbd}"
    6  lsblk
    7  mke2fs -t ext4 -L boot "${tmp_nbd}"1
    8  boot_uuid=$(blkid "${tmp_nbd}"1 -s PARTUUID -o value)
    9  mke2fs -t ext4 -L system "${tmp_nbd}"2
   10  system_uuid=$(blkid "${tmp_nbd}"2 -s PARTUUID -o value)
   11  mkdir -p "${dst_mnt}"
   12  mount "${tmp_nbd}2" "${dst_mnt}"
   13  mkdir -p "${dst_mnt}"/boot
   14  mount -o norecovery "${tmp_nbd}"1 "${dst_mnt}"/boot
   15  cp /boot/initramfs-5.14.0-284.11.1.el9_2.s390x.img "${dst_mnt}"/boot/initrd.img
   16  ls /boot/
   17  cp /boot/vmlinuz-5.14.0-284.11.1.el9_2.s390x "${dst_mnt}"/boot/vmlinuz
   19  src_mnt=./system
   20  tar_opts=(--numeric-owner --preserve-permissions --acl --selinux --xattrs --xattrs-include='*' --sparse)
   22  mkdir -p "${src_mnt}"
   26  sudo mount --bind -o ro / ${src_mnt}
   27  tar -cf - "${tar_opts[@]}" --sort=none -C "${src_mnt}" . | tar -xf - "${tar_opts[@]}" --preserve-order  -C "${dst_mnt}"
   28  cat <<END > "${dst_mnt}/etc/fstab"
#This file was auto-generated
PARTUUID=${system_uuid}   /        ext4  defaults 1 1
PARTUUID=${boot_uuid}     /boot    ext4  norecovery 1 2
END
   29  mount -t sysfs sysfs "${dst_mnt}/sys"
   30  mount -t proc proc "${dst_mnt}/proc"
   31  mount --bind /dev "${dst_mnt}/dev"
   32  cd dst_mnt/
   33  ls
   34  cd ..
   35  export SE_PARMLINE="root=LABEL=system selinux=0 enforcing=0 audit=0 systemd.firstboot=off"
   36  sudo -E bash -c 'echo "${SE_PARMLINE}" > ${dst_mnt}/boot-se/parmfile'
   37  sudo -E bash -c 'echo "${SE_PARMLINE}" > ${dst_mnt}/boot/parmfile'
   38  ls dst_mnt/
   39  ls dst_mnt/boot/
   40  echo "${SE_PARMLINE}"
   41  echo "${SE_PARMLINE}" > ${dst_mnt}/boot/parmfile
   42  cat ${dst_mnt}/boot/parmfile
   43  cd dst_mnt/boot/parmfile 
   44  cat dst_mnt/boot/parmfile 
   45  vi HKD
   46  sudo -E /usr/bin/genprotimg     -i ${dst_mnt}/boot/vmlinuz     -r ${dst_mnt}/boot/initrd.img     -p ${dst_mnt}/boot/parmfile     --no-verify     -k HKD     -o ${dst_mnt}/boot-se/se.img
   47  sudo -E /usr/bin/genprotimg     -i ${dst_mnt}/boot/vmlinuz     -r ${dst_mnt}/boot/initrd.img     -p ${dst_mnt}/boot/parmfile     --no-verify     -k HKD     -o ${dst_mnt}/boot/se.img
   48  sudo chroot ${dst_mnt} zipl --targetbase ${tmp_nbd}     --targettype scsi     --targetblocksize 512     --targetoffset 2048     --target /boot     --image /boot/se.img
   49  history

[root@a3elp61 home]# virsh destroy lavanya-se-hvbd 
Domain 'lavanya-se-hvbd' destroyed

[root@a3elp61 home]# virsh undefine lavanya-se-hvbd 
Domain 'lavanya-se-hvbd' has been undefined

sudo virt-install  --memory 4096  --vcpus 4  --name luks-test-se --disk /home/no-crypt-se.qcow2,device=disk,bus=virtio,format=qcow2  --disk /home/anjana/cloud-init.iso,device=cdrom  --os-variant rhel9.1  --graphics none  --import 