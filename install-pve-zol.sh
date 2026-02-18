#!/bin/bash
set -euo pipefail

# Require root permissions
if [[ $EUID != 0 ]]; then sudo "$0" "$@"; exit $?; fi

# PVE-ZOL Installer
# copied from: https://github.com/stackcoder/pve-zol

DISK_IDS=(
  # id from /dev/disk/by-id/
  "wwn-0x0000000000000001"
  "wwn-0x0000000000000002"
)

ZPOOL_TYPE="mirror"

CRYPTSETUP_PASSPHRASE="password"
CRYPTSETUP_DEFAULTS=(
  --cipher "aes-xts-plain64"
  --pbkdf "argon2id"
  --key-size "512"
  # if you disk 4k formated
  #--sector-size "4096"
  --hash "sha512"
  --use-random
)

SWAP_SIZE="${SWAP_SIZE:-32G}"
ROOT_PASSWORD="root"

TARGET_HOSTNAME="${TARGET_HOSTNAME:-pve-zol}"
TARGET_IPADDRESS="${TARGET_IPADDRESS:-192.168.1.42/24}"
TARGET_GATEWAY="${TARGET_GATEWAY:-192.168.1.1}"
TARGET_DNS="${TARGET_DNS:-${TARGET_GATEWAY}}"

[[ -z "${ETHERNET_DEV:-}" ]] && ETHERNET_DEV="$(udevadm info -e | sed -n '/ID_NET_NAME_ONBOARD=/p' | head -n1 | cut -d= -f2)"
[[ -z "${ETHERNET_DEV:-}" ]] && ETHERNET_DEV="$(udevadm info -e | sed -n '/ID_NET_NAME_PATH=/p' | head -n1 | cut -d= -f2)"
[[ -z "${ETHERNET_DEV:-}" ]] && ETHERNET_DEV="enp0s1"

SSH_USER="root"
# insert you ssh key
SSH_KEY=""

[[ "${#DISK_IDS[@]}" -lt 2 ]] && ZPOOL_TYPE=""

export LC_ALL="en_US.UTF-8"

echo_section() {
  echo -e "\n\n\e[0;94m===== ${*} =====\e[0m"
}

echo_section "Configure live system"
( set -x
  gsettings set org.gnome.desktop.media-handling automount false || true
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
)

echo_section "Install ZOL and dependencies"
if ! modinfo zfs &> /dev/null; then
( set -x
  echo "deb http://mirror.yandex.ru/debian trixie contrib" \
    > /etc/apt/sources.list.d/trixie-contrib.list
  apt-get update
  apt-get install --yes cryptsetup curl debootstrap efibootmgr gdisk dpkg-dev parted rng-tools dosfstools "linux-headers-$(uname -r)"
  apt-get install --yes zfsutils-linux
  modprobe zfs
)
else
  echo "Already satisfied"
fi

echo_section "Stop and disable ZED"
( set -x
  systemctl stop zfs-zed.service
  systemctl disable zfs-zed.service
)

echo_section "Partition disks"
for id in "${DISK_IDS[@]}"; do
( set -x
  # Clear disk
  wipefs -af "/dev/disk/by-id/${id}"
  sgdisk --zap-all "/dev/disk/by-id/${id}"
  sync && partprobe "/dev/disk/by-id/${id}" && udevadm settle --timeout=5

  # Discard device sectors
  blkdiscard -sv "/dev/disk/by-id/${id}" || blkdiscard -fv "/dev/disk/by-id/${id}" || true

  # Always use 4k alignment
  part_end=$(blockdev --getsize "/dev/disk/by-id/${id}")
  part_end=$(( part_end - (part_end + 1) % 4096 ))
 
  sgdisk -a 4096 -n1:2M:+4G        -t1:EF00 -c1:"System Boot" "/dev/disk/by-id/${id}"
  sgdisk -a 4096 -n4:0:${part_end} -t4:8300 -c4:"System Root Pool" "/dev/disk/by-id/${id}"

  # Let the kernel reread the partition table
  sync && partprobe "/dev/disk/by-id/${id}"
  udevadm settle --timeout=15 --exit-if-exists="/dev/disk/by-id/${id}-part4"
)
done

echo_section "Format boot disks with fat32"
for id in "${DISK_IDS[@]}"; do
( set -x
  mkfs.vfat -F 32 -s 1 -n "System Boot" "/dev/disk/by-id/${id}-part1"
)
done

echo_section "Setup root pool cryptsetup partitions"
for i in "${!DISK_IDS[@]}"; do
  echo -n "${CRYPTSETUP_PASSPHRASE}" | \
    ( set -x; cryptsetup luksFormat --verbose "${CRYPTSETUP_DEFAULTS[@]}" "/dev/disk/by-id/${DISK_IDS[$i]}-part4" )
  echo -n "${CRYPTSETUP_PASSPHRASE}" | \
    ( set -x; cryptsetup luksOpen --verbose "/dev/disk/by-id/${DISK_IDS[$i]}-part4" "rtank${i}_crypt" )
done

echo_section "Create root pool"
( set -x
  zpool create -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/ -R /target \
    "rtank" ${ZPOOL_TYPE} $(printf "/dev/mapper/rtank%s_crypt " "${!DISK_IDS[@]}")
)

echo_section "Create datasets"
( set -x
  # Create filesystem datasets to act as containers
  zfs create -o canmount=off -o mountpoint=none rtank/ROOT

  # Enable discard
  zpool set autotrim=on rtank

  # Create a filesystem datasets for the root and boot filesystems
  zfs create -o canmount=noauto -o mountpoint=/ rtank/ROOT/debian
  zfs mount rtank/ROOT/debian

  # Create datasets
  zfs create                                            rtank/home
  zfs create -o mountpoint=/root                        rtank/home/root
  chmod 700 /target/root
  zfs create -o canmount=off                            rtank/var
  zfs create -o canmount=off                            rtank/var/lib
  zfs create                                            rtank/var/lib/vz
  zfs create                                            rtank/var/log
  zfs create                                            rtank/var/spool

  # Don't do this, it will break bootctl install
  #zfs create                                           rtank/boot

  # If you wish to exclude these from snapshots:
  zfs create -o com.sun:auto-snapshot=false             rtank/var/cache
  zfs create -o com.sun:auto-snapshot=false             rtank/var/tmp
  chmod 1777 /target/var/tmp
)

# fresh version zfs using big blocksize for native write (ex. 16k)
echo_section "Create swap zvol"
( set -x
  zfs create \
    -V "${SWAP_SIZE}" \
    -b 16384 \
    -o compression=zle \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    -o logbias=throughput \
    -o sync=always \
    rtank/swap
  mkswap -f /dev/zvol/rtank/swap
)

echo_section "Mount a tmpfs at /run"
( set -x
  mkdir /target/run
  mount -t tmpfs tmpfs /target/run
  mkdir /target/run/lock
  mkdir /target/run/udev
)

echo_section "Install minimal system"
( set -x
  debootstrap --arch amd64 trixie /target http://mirror.yandex.ru/debian
)

echo_section "Setup chroot environment"
( set -x
  mount --make-private --rbind /dev      /target/dev
  mount --make-private --rbind /proc     /target/proc
  mount --make-private --rbind /sys      /target/sys
  mount --make-private --rbind /run/udev /target/run/udev
)

cat <<END_OF_CHROOT >/target/var/tmp/chroot-commands.sh
#!/bin/bash
set -euxo pipefail

# array variables are not exported
DISK_IDS=( $(printf "\"%s\" " "${DISK_IDS[@]}") )

echo_section() {
  echo -e "\n\n\e[0;35m===== \${*} =====\e[0m"
}

export DEBIAN_FRONTEND=noninteractive
export GRUB_DISABLE_OS_PROBER=true

echo_section "Configure hostname"
echo "${TARGET_HOSTNAME}" > /etc/hostname
echo "${TARGET_IPADDRESS%/*}       ${TARGET_HOSTNAME}" >> /etc/hosts

echo_section "Configure package sources"
cat <<EOF > /etc/apt/sources.list
deb http://mirror.yandex.ru/debian trixie main contrib
#deb-src http://mirror.yandex.ru/debian trixie main contrib

deb http://mirror.yandex.ru/debian-security trixie-security main contrib
#deb-src http://mirror.yandex.ru/debian-security trixie-security main contrib

deb http://mirror.yandex.ru/debian trixie-updates main contrib
#deb-src http://mirror.yandex.ru/debian trixie-updates main contrib
EOF

echo_section "Configure proxmox pve repository"
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/proxmox.list

wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O /etc/apt/trusted.gpg.d/proxmox-archive-keyring-trixie.gpg
chmod +r /etc/apt/trusted.gpg.d/proxmox-archive-keyring-trixie.gpg

echo_section "Configure a basic system environment"
apt-get update
apt-get install --yes locales keyboard-configuration console-setup

echo_section "Setup locale"
perl -i -pe 's/# (en_US.UTF-8)/\$1/' /etc/locale.gen
echo 'LANG="en_US.UTF-8"' > /etc/default/locale
ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime
locale-gen
dpkg-reconfigure -f noninteractive tzdata keyboard-configuration console-setup debconf

echo_section "Mount a tmpfs to /tmp"
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

echo_section "Upgrade all packages"
apt-get upgrade --yes

echo_section "Install required packages"
apt-get install --no-install-recommends --yes \
  bridge-utils \
  cryptsetup \
  cryptsetup-initramfs \
  htop \
  keyutils \
  openssh-server \
  rng-tools \
  sudo \
  tree \
  tmux \
  pve-kernel-6.2 \
  pve-kernel-helper \
  zstd \
  zfsutils-linux \
  zfs-initramfs \
  zfs-zed

echo_section "Configure crypttab"
for i in "\${!DISK_IDS[@]}"; do
  uuid=\$(blkid -s UUID -o value "/dev/disk/by-id/\${DISK_IDS[\$i]}-part4")
  line="rtank\${i}_crypt UUID=\${uuid} system_crypt luks,initramfs,keyscript=decrypt_keyctl"
  if [[ \$(lsblk -dnro rota "/dev/disk/by-id/\${DISK_IDS[\$i]}") == "0" ]]; then
    # device is a non rotational device (aka. SSD)
    line="\${line},discard"
  fi
  echo "\${line}" >> /etc/crypttab
done

echo_section "Configure swap"
echo "/dev/zvol/rtank/swap none swap discard 0 0" >> /etc/fstab
echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume

echo_section "Refresh initramfs"
update-initramfs -c -k all

echo_section "Install bootloader"

# https://github.com/proxmox/pve-installer/blob/435522c9d174f6ef9ca06bb262ff1b418de987ff/proxinstall#L1784
ZFS_SNIPPET="luks.crypttab=no root=ZFS=rtank/ROOT/debian"
if [ -d /sys/firmware/efi ]; then
  apt install --no-install-recommends --yes systemd-boot efibootmgr
  echo "\$ZFS_SNIPPET" > /etc/kernel/cmdline
else
  apt install --no-install-recommends --yes grub-pc
  echo "GRUB_CMDLINE_LINUX=\"\\\$GRUB_CMDLINE_LINUX \$ZFS_SNIPPET\"" > /etc/default/grub.d/zfs.cfg
fi

for id in "\${DISK_IDS[@]}"; do
  proxmox-boot-tool init "/dev/disk/by-id/\${id}-part1"
done

kernel_prefix="/boot/vmlinuz-"
kernel_list=( "\${kernel_prefix}"* )
kernel_ver="\${kernel_list[0]##\${kernel_prefix}}"

proxmox-boot-tool kernel add "\${kernel_ver}"
proxmox-boot-tool refresh
proxmox-boot-tool status

echo_section "Fix filesystem mount ordering"

mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/rtank
[[ ! -e /etc/zfs/zed.d/history_event-zfs-list-cacher.sh ]] && \
  ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d

zed -F &
ZED_PID=\$!

# Loop while zed does its thing
while ! ( [ -f /etc/zfs/zfs-list.cache/rtank ] && \
          [ -s /etc/zfs/zfs-list.cache/rtank ] )
do
  sleep 3
  # If it is empty, force a cache update and check again:
  zfs set canmount=noauto rtank/ROOT/debian
done

# Delay one more time to avoid race condition
sleep 3
kill \$ZED_PID

# Fix paths to eliminate /target:
sed -Ei "s|/target/?|/|" /etc/zfs/zfs-list.cache/rtank

echo_section "Tasksel"
tasksel install standard

echo_section "Configure sshd"
sed -i "s/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_\*/" /etc/ssh/sshd_config

echo_section "Configure network"
cat <<EOF >> "/etc/network/interfaces"
auto ${ETHERNET_DEV}
allow-hotplug ${ETHERNET_DEV}
iface ${ETHERNET_DEV} inet manual

auto vmbr0
iface vmbr0 inet static
  bridge-ports ${ETHERNET_DEV}
  bridge-stp off
  bridge-fd 0
  address ${TARGET_IPADDRESS}
  gateway ${TARGET_GATEWAY}
  dns-nameservers ${TARGET_DNS}
EOF

echo_section "Set root password"
echo "root:${ROOT_PASSWORD}" | chpasswd

echo_section "Enroll ssh user"
adduser --disabled-login --disabled-password --gecos "" "${SSH_USER}"
mkdir "/home/${SSH_USER}/.ssh"
echo "${SSH_KEY}" > "/home/${SSH_USER}/.ssh/authorized_keys"
chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
chmod 700 "/home/${SSH_USER}/.ssh"
chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"
echo "${SSH_USER}    ALL= NOPASSWD: ALL" > "/etc/sudoers.d/${SSH_USER}"

echo_section "Self delete chroot commands script"
rm "\${0}"

echo_section "Snapshot initial installation"
zfs snapshot rtank/ROOT/debian@install
END_OF_CHROOT

echo_section "Run generated chroot script"
( set -x
  chmod +x /target/var/tmp/chroot-commands.sh
  chroot /target /var/tmp/chroot-commands.sh
)

echo_section "DONE"

read -ep "Umount target system? [Y/n]" choice

if [[ "${choice}" =~ ^[nN](o)?$ ]]; then
  exit 0
fi

( set -x
  TARGET_PATHS=(
    /target/run/udev
    /target/run
    /target/dev
    /target/proc
    /target/sys
  )
  for p in "${TARGET_PATHS[@]}"; do
    umount "$p" || umount -lf "$p"
  done
  zfs umount -a
  systemctl stop udev
  zpool export -a
  for i in "${!DISK_IDS[@]}"; do
    cryptsetup luksClose "rtank${i}_crypt"
  done
  sync
)
