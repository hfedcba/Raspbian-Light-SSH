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
dd if=/dev/zero of=$image bs=1MB count=1536
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

echo "blacklist i2c-bcm2708" > etc/modprobe.d/raspi-blacklist.conf

echo "dwc_otg.lpm_enable=0 console=ttyUSB0,115200 kgdboc=ttyUSB0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline rootwait" > boot/cmdline.txt

echo "proc            /proc           proc    defaults        0       0
/dev/mmcblk0p1  /boot           vfat    defaults        0       2
/dev/mmcblk0p2  /           ext4    defaults        0       1
" > etc/fstab

#Setup network settings
echo "raspberrypi" > etc/hostname
echo "127.0.0.1       localhost raspberrypi
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
" > etc/hosts

echo "auto lo
iface lo inet loopback
iface lo inet6 loopback

allow-hotplug eth0
iface eth0 inet dhcp
iface eth0 inet6 auto

allow-hotplug wlan0
iface wlan0 inet manual
    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf

allow-hotplug wlan1
iface wlan1 inet manual
    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
" > etc/network/interfaces

echo "nameserver 208.67.222.222
nameserver 208.67.220.220
nameserver 2620:0:ccc::2
nameserver 2620:0:ccd::2" > etc/resolv.conf
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
echo \"deb http://archive.raspberrypi.org/debian/ jessie main ui\" > /etc/apt/sources.list.d/raspi.list
wget http://archive.raspbian.org/raspbian.public.key && apt-key add raspbian.public.key && rm raspbian.public.key
wget http://archive.raspberrypi.org/debian/raspberrypi.gpg.key && apt-key add raspberrypi.gpg.key && rm raspberrypi.gpg.key
apt update
apt -y install libraspberrypi0 libraspberrypi-bin  locales console-common ntp openssh-server binutils sudo parted git curl lua5.2 unzip keyboard-configuration tmux
# Wireless packets
apt -y install bluez-firmware firmware-atheros firmware-libertas firmware-realtek firmware-ralink firmware-brcm80211 libraspberrypi0 libraspberrypi-bin wireless-tools wpasupplicant
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
rm -f third-stage
" > third-stage
chmod +x third-stage
LANG=C chroot $rootfs /third-stage

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

cat > "etc/init.d/tmpfslog.sh" <<-'EOF'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          tmpfslog
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# X-Start-Before:    $syslog
# X-Stop-After:      $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start/stop logfile saving
### END INIT INFO
#
# varlog        This init.d script is used to start logfile saving and restore.
#

varlogSave=/var/log.save/
[ ! -d $varlogSave ] && mkdir -p $varlogSave

PATH=/sbin:/usr/sbin:/bin:/usr/bin

case $1 in
    start)
        echo "*** Starting tmpfs file restore: varlog."
        if [ -z "$(grep /var/log /proc/mounts)" ]; then
            echo "*** mounting /var/log"
            cp -Rpu /var/log/* $varlogSave
            rm -Rf /var/log/*
            varlogsize=$(grep /var/log /etc/fstab|awk {'print $4'}|cut -d"=" -f2)
            [ -z "$varlogsize" ] && varlogsize="100M"
            mount -t tmpfs tmpfs /var/log -o defaults,size=$varlogsize
            chmod 755 /var/log
        fi
        cp -Rpu ${varlogSave}* /var/log/
    ;;
    stop)
        echo "*** Stopping tmpfs file saving: varlog."
        rm -Rf ${varlogSave}*
        cp -Rpu /var/log/* $varlogSave >/dev/null 2>&1
        sync
        umount -f /var/log/
    ;;
  reload)
    echo "*** Stopping tmpfs file saving: varlog."
    	rm -Rf ${varlogSave}*
        cp -Rpu /var/log/* $varlogSave >/dev/null 2>&1
        sync
  ;;
    *)
        echo "Usage: $0 {start|stop}"
    ;;
esac

exit 0
EOF
chown root:root etc/init.d/tmpfslog.sh
chmod 755 etc/init.d/tmpfslog.sh

#First-start script
echo "#!/bin/bash
sed -i '$ d' /home/pi/.bashrc >/dev/null
echo \"************************************************************\"
echo \"************************************************************\"
echo \"************************ Moin, moin ************************\"
echo \"************************************************************\"
echo \"************************************************************\"" > firstStart.sh

echo "echo \"Generating new SSH host keys. This might take a while.\"
rm /etc/ssh/ssh_host* >/dev/null
ssh-keygen -A >/dev/null
if [ \$(nproc --all) -ge 4 ]; then
  echo \"dwc_otg.lpm_enable=0 console=ttyUSB0,115200 kgdboc=ttyUSB0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline rootwait\" > /boot/cmdline.txt
  sed -i 's/varlogsize=\"100M\"/varlogsize=\"250M\"/g' /etc/init.d/tmpfslog.sh
fi
insserv tmpfslog.sh
echo \"Updating your system...\"
apt update
apt -y upgrade" >> firstStart.sh
echo "echo \"Starting raspi-config...\"
PATH=\"\$PATH:/opt/vc/bin:/opt/vc/sbin\"
raspi-config
rm /firstStart.sh
echo \"Rebooting...\"
reboot" >> firstStart.sh
chown root:root firstStart.sh
chmod 755 firstStart.sh

echo "sudo /firstStart.sh" >> home/pi/.bashrc
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
