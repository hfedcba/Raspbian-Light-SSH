#!/bin/bash

set -x

# required build environment packages: binfmt-support qemu qemu-user-static debootstrap kpartx lvm2 dosfstools
# made possible by:
#   Klaus M Pfeiffer (http://blog.kmp.or.at/2012/05/build-your-own-raspberry-pi-image/)
#   Alex Bradbury (http://asbradbury.org/projects/spindle/)


deb_mirror="http://mirrordirector.raspbian.org/raspbian/"
deb_local_mirror=$deb_mirror
deb_release="jessie"

bootsize="64M"
buildenv="/root/rpi"
rootfs="${buildenv}/rootfs"
bootfs="${rootfs}/boot"

mydate=`date +%Y%m%d`

if [ $EUID -ne 0 ]; then
  echo "ERROR: This tool must be run as Root"
  exit 1
fi

echo "Creating image..."
mkdir -p $buildenv
image="${buildenv}/rpi_light_ssh_${deb_release}_${mydate}.img"
dd if=/dev/zero of=$image bs=1MB count=1024
[ $? -ne 0 ] && exit 1
device=`losetup -f --show $image`
[ $? -ne 0 ] && exit 1
echo "Image $image Created and mounted as $device"

fdisk $device << EOF
n
p
1

+$bootsize
t
c
n
p
2


w
EOF
sleep 1

losetup -d $device
[ $? -ne 0 ] && exit 1
sleep 1

device=`kpartx -va $image | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
[ $? -ne 0 ] && exit 1
sleep 1

echo "--- kpartx device ${device}"
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

mkfs.vfat $bootp
mkfs.ext4 $rootp

mkdir -p $rootfs
[ $? -ne 0 ] && exit 1

mount $rootp $rootfs
[ $? -ne 0 ] && exit 1

cd $rootfs
debootstrap --no-check-gpg --foreign --arch=armhf $deb_release $rootfs $deb_local_mirror
[ $? -ne 0 ] && exit 1

cp /usr/bin/qemu-arm-static usr/bin/
[ $? -ne 0 ] && exit 1
LANG=C chroot $rootfs /debootstrap/debootstrap --second-stage
[ $? -ne 0 ] && exit 1

mount $bootp $bootfs
[ $? -ne 0 ] && exit 1

echo "deb $deb_local_mirror $deb_release main contrib non-free rpi
" > etc/apt/sources.list

echo "blacklist i2c-bcm2708" > $rootfs/etc/modprobe.d/raspi-blacklist.conf

echo "dwc_otg.lpm_enable=0 console=ttyUSB0,115200 console=tty1 kgdboc=ttyUSB0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline rootwait" > boot/cmdline.txt

rm -f $rootfs/etc/fstab
cat > "$rootfs/etc/fstab" <<'EOF'
/dev/mmcblk0p1  /boot                       vfat            defaults,noatime,ro                                                 0       2
/dev/mmcblk0p2  /                           ext4            defaults,noatime,ro                                                 0       1
tmpfs           /run                        tmpfs           defaults,nosuid,mode=1777,size=20M                                  0       0
tmpfs           /var/log                    tmpfs           defaults,nosuid,mode=1777,size=10%                                  0       0
tmpfs           /var/tmp                    tmpfs           defaults,nosuid,mode=1777,size=10%                                  0       0
EOF

#Setup network settings
echo "raspberrypi" > etc/hostname
echo -e "127.0.0.1\traspberrypi" >> etc/hosts

echo "auto lo
iface lo inet loopback
iface lo inet6 loopback

auto eth0
iface eth0 inet dhcp
iface eth0 inet6 auto
" > etc/network/interfaces
#End network settings

echo "console-common    console-data/keymap/policy      select  Select keymap from full list
console-common  console-data/keymap/full        select  us
" > debconf.set

echo "#!/bin/bash
set -x
debconf-set-selections /debconf.set
rm -f /debconf.set
apt update
ls -l /etc/apt/sources.list.d
cat /etc/apt/sources.list
apt -y install apt-transport-https ca-certificates
update-ca-certificates --fresh
mkdir -p /etc/apt/sources.list.d/
apt update
apt -y install locales console-common ntp openssh-server binutils sudo parted git curl lua5.2 unzip keyboard-configuration tmux dialog whiptail
wget http://goo.gl/1BOfJ -O /usr/bin/rpi-update
chmod +x /usr/bin/rpi-update
mkdir -p /lib/modules/$(uname -r)
rpi-update
rm -Rf /boot.bak
useradd --create-home --shell /bin/bash --user-group pi
echo \"pi:raspberry\" | chpasswd
echo \"root:raspberry\" | chpasswd
echo \"pi ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
dpkg-divert --add --local /lib/udev/rules.d/75-persistent-net-generator.rules
dpkg-reconfigure locales
service ssh stop
service ntp stop
cd /tmp/
git clone --depth 1 git://github.com/raspberrypi/firmware/
cp -R /tmp/firmware/hardfp/opt/vc /opt/
rm -Rf /tmp/firmware
echo \"PATH=\\\"\\\$PATH:/opt/vc/bin:/opt/vc/sbin\\\"\" >> /etc/bash.bashrc
echo \"/opt/vc/lib\" >> /etc/ld.so.conf.d/vcgencmd.conf
ldconfig
" > $rootfs/third-stage
chmod +x third-stage
LANG=C chroot $rootfs /third-stage
rm -f $rootfs/third-stage

mkdir -p $rootfs/lib/systemd/scripts
cat > "$rootfs/lib/systemd/scripts/setup-tmpfs.sh" <<'EOF'
#!/bin/bash

mkdir /var/tmp/lock
chmod 755 /var/tmp/lock
mkdir /var/tmp/dhcp
chmod 755 /var/tmp/dhcp
mkdir /var/tmp/spool
chmod 755 /var/tmp/spool
mkdir /var/tmp/systemd
chmod 755 /var/tmp/systemd
touch /var/tmp/systemd/random-seed
chmod 600 /var/tmp/systemd/random-seed
mkdir -p /var/spool/cron/crontabs
chmod 731 /var/spool/cron/crontabs
chmod +t /var/spool/cron/crontabs

exit 0
EOF
    chmod 750 $rootfs/lib/systemd/scripts/setup-tmpfs.sh

    cat > "$rootfs/lib/systemd/system/setup-tmpfs.service" <<'EOF'
[Unit]
Description=setup-tmpfs
DefaultDependencies=no
After=var-log.mount var-tmp.mount
Before=systemd-random-seed.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/lib/systemd/scripts/setup-tmpfs.sh
TimeoutSec=30s

[Install]
WantedBy=sysinit.target
EOF

cat > "$rootfs/fourth-stage" <<'EOF'
rm -Rf /tmp
ln -s /var/tmp /tmp
mkdir /data
rm -Rf /var/spool
ln -s /var/tmp/spool /var/spool
rm -Rf /var/lib/dhcp
ln -s /var/tmp/dhcp /var/lib/dhcp
rm -Rf /var/lock
ln -s /var/tmp/lock /var/lock
rm -Rf /var/lib/systemd
ln -s /var/tmp/systemd /var/lib/systemd

# {{{ debian-fixup fixes
    ln -sf /proc/mounts /etc/mtab
# }}}

systemctl enable setup-tmpfs
EOF
chmod +x $rootfs/fourth-stage
LANG=C chroot $rootfs /fourth-stage

#Install raspi-config
wget https://raw.githubusercontent.com/RPi-Distro/raspi-config/master/raspi-config
mv raspi-config usr/bin
chown root:root usr/bin/raspi-config
chmod 755 usr/bin/raspi-config
#End install raspi-config

#Create Raspberry Pi boot config
echo "# For more options and information see
# http://www.raspberrypi.org/documentation/configuration/config-txt.md
# Some settings may impact device functionality. See link above for details

# uncomment if you get no picture on HDMI for a default "safe" mode
#hdmi_safe=1

# uncomment this if your display has a black border of unused pixels visible
# and your display can output without overscan
#disable_overscan=1

# uncomment the following to adjust overscan. Use positive numbers if console
# goes off screen, and negative if there is too much border
#overscan_left=16
#overscan_right=16
#overscan_top=16
#overscan_bottom=16

# uncomment to force a console size. By default it will be display's size minus
# overscan.
#framebuffer_width=1280
#framebuffer_height=720

# uncomment if hdmi display is not detected and composite is being output
#hdmi_force_hotplug=1

# uncomment to force a specific HDMI mode (this will force VGA)
#hdmi_group=1
#hdmi_mode=1

# uncomment to force a HDMI mode rather than DVI. This can make audio work in
# DMT (computer monitor) modes
#hdmi_drive=2

# uncomment to increase signal to HDMI, if you have interference, blanking, or
# no display
#config_hdmi_boost=4

# uncomment for composite PAL
#sdtv_mode=2

#uncomment to overclock the arm. 700 MHz is the default.
#arm_freq=800

# Uncomment some or all of these to enable the optional hardware interfaces
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on

# Uncomment this to enable the lirc-rpi module
#dtoverlay=lirc-rpi

# Additional overlays and parameters are documented /boot/overlays/README

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

enable_uart=1
dtparam=spi=on
dtparam=i2c_arm=on" > boot/config.txt
chown root:root boot/config.txt
chmod 755 boot/config.txt
#End Raspberry Pi boot config

echo "deb $deb_mirror $deb_release main contrib non-free rpi
" > etc/apt/sources.list

cat > "$rootfs/setupPartitions.sh" <<-'EOF'
#!/bin/bash

stage_one()
{
    TTY_X=$(($(stty size | awk '{print $2}')-6))
    TTY_Y=$(($(stty size | awk '{print $1}')-6))
    rootpartitionsize=""
    while [ -z $rootpartitionsize ] || ! [[ $rootpartitionsize =~ ^[1-9][0-9]*$ ]]; do
        rootpartitionsize=$(dialog --stdout --title "Partitioning" --no-tags --no-cancel --inputbox "Enter new size of root partition in gigabytes. The minimum partition size is 1 GB." $TTY_Y $TTY_X "2")
        if ! [[ $rootpartitionsize =~ ^[1-9][0-9]*$ ]]; then
            dialog --title "Partitioning" --msgbox "Please enter a valid size in gigabytes (without unit). E. g. \"2\" or \"4\". Not \"2G\"." $TTY_Y $TTY_X
        fi
    done

    TTY_X=$(($(stty size | awk '{print $2}')-6))
    TTY_Y=$(($(stty size | awk '{print $1}')-6))
    datapartitionsize=""
    while [ -z $datapartitionsize ] || ! [[ $datapartitionsize =~ ^[1-9][0-9]*$ ]]; do
        datapartitionsize=$(dialog --stdout --title "Partitioning" --no-tags --no-cancel --inputbox "Enter new size of data partition in gigabytes." $TTY_Y $TTY_X "2")
        if ! [[ $datapartitionsize =~ ^[1-9][0-9]*$ ]]; then
            dialog --title "Partitioning" --msgbox "Please enter a valid size in gigabytes (without unit). E. g. \"2\" or \"4\". Not \"2G\"." $TTY_Y $TTY_X
        fi
    done

    fdisk /dev/mmcblk0 << EOC
d
2
n
p
2

+${rootpartitionsize}G
n
p
3

+${datapartitionsize}G
w
EOC

    rm -f /partstageone
    touch /partstagetwo

    echo -n "Rebooting in 3... " && sleep 1 && echo -n "2... " && sleep 1 && echo -n "1... " && sleep 1
    reboot
}

stage_two()
{
    mkfs.ext4 -F /dev/mmcblk0p3

    sed -i '/\/dev\/mmcblk0p2/a\
\/dev\/mmcblk0p3  \/data                       ext4            defaults,noatime,commit=600             0       1' /etc/fstab
    mount -o defaults,noatime,commit=600 /dev/mmcblk0p3 /data
    rm -f /partstagetwo
}

[ -f /partstagetwo ] && stage_two
[ -f /partstageone ] && stage_one
EOF
touch $rootfs/partstageone
chmod 755 $rootfs/setupPartitions.sh

#First-start script
cat > "$rootfs/firstStart.sh" <<-'EOF'
#!/bin/bash

scriptCount=`/bin/ps -ejH -1 | /bin/grep firstStart.sh | /bin/grep -c /firstStart`
if [ $scriptCount -gt 3 ]; then
        echo "First start script is already running... Not executing it again..."
        exit 1
fi

echo "************************************************************"
echo "************************************************************"
echo "************************ Moin, moin ************************"
echo "************************************************************"
echo "************************************************************"

mount -o remount,rw /

export NCURSES_NO_UTF8_ACS=1

/setupPartitions.sh
if [ -f /partstageone ] || [ -f /partstagetwo ]; then
    exit 0
fi
rm -f /setupPartitions.sh

echo "Please enter a new password for user \"pi\":"
result=1
while [ $result -ne 0 ]; do
    mount -o remount,rw /
    passwd pi
    result=$?
done
echo ""
echo "Please enter a new password for user \"root\":"
result=1
while [ $result -ne 0 ]; do
    mount -o remount,rw /
    passwd root
    result=$?
done

echo "Generating new SSH host keys. This might take a while."
rm /etc/ssh/ssh_host* >/dev/null
ssh-keygen -A >/dev/null
echo "Updating your system..."
apt update
[ $? -ne 0 ] && mount -o remount,rw / && apt update
[ $? -ne 0 ] && mount -o remount,rw / && apt update
[ $? -ne 0 ] && exit 1
apt -y upgrade
echo "Starting raspi-config..."
PATH="$PATH:/opt/vc/bin:/opt/vc/sbin"
raspi-config
rm /firstStart.sh
sed -i '$ d' /home/pi/.bashrc >/dev/null
echo -n "Rebooting in 3... " && sleep 1 && echo -n "2... " && sleep 1 && echo -n "1... " && sleep 1
reboot
EOF
chown root:root $rootfs/firstStart.sh
chmod 755 $rootfs/firstStart.sh

echo "sudo /firstStart.sh" >> $rootfs/home/pi/.bashrc
#End first-start script

#Bash profile
echo "let upSeconds=\"\$(/usr/bin/cut -d. -f1 /proc/uptime)\"
let secs=\$((\${upSeconds}%60))
let mins=\$((\${upSeconds}/60%60))
let hours=\$((\${upSeconds}/3600%24))
let days=\$((\${upSeconds}/86400))
UPTIME=\`printf \"%d days, %02dh %02dm %02ds\" \"\$days\" \"\$hours\" \"\$mins\" \"\$secs\"\`

echo \"\$(tput bold)\$(tput setaf 7)Moin, moin
\`uname -srmo\`
Uptime: \${UPTIME}
\$(tput sgr0)\"

# if running bash
if [ -n \"\$BASH_VERSION\" ]; then
    # include .bashrc if it exists
    if [ -f \"\$HOME/.bashrc\" ]; then
        . \"\$HOME/.bashrc\"
    fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d \"\$HOME/bin\" ] ; then
    PATH=\"\$HOME/bin:\$PATH\"
fi" > home/pi/.bash_profile
#End bash profile

echo "#!/bin/bash
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f cleanup
" > cleanup
chmod +x cleanup
LANG=C chroot $rootfs /cleanup

cd

umount $bootp
umount $rootp

kpartx -d $image

mv $image .
rm -Rf $buildenv

echo "Created Image: $image"

echo "Done."
