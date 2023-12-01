#!/bin/bash
set +h
set -e
umask 022
SEP="$ ==================================== $"

KERNEL_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.6.2.tar.xz"
ZEN_KERNEL=1    # yes
ZEN_KERNEL_URL="https://github.com/zen-kernel/zen-kernel/releases/download/v6.6.2-zen1/linux-v6.6.2-zen1.patch.zst"
CC="clang"
CXX="clang++"
LD="ld.lld"
BB_CC="gcc"
GLIBC_CC="gcc"
NUM_CORES=$(nproc --all)
BUSYBOX_URL="https://busybox.net/downloads/busybox-1.36.1.tar.bz2"
GLIBC_URL="https://ftp.gnu.org/gnu/glibc/glibc-2.38.tar.xz"
CLFS_BOOT_SCRIPTS_URL="http://ftp.clfs.org/pub/clfs/conglomeration/clfs-embedded-bootscripts/clfs-embedded-bootscripts-1.0-pre5.tar.bz2"

KVERS="6.6.2"
KVERS_FULL=$KVERS

if [ $ZEN_KERNEL -eq 1 ]; then
    KVERS_FULL=$KVERS"-zen1"
fi 

CLEAN_UP=0
comp_kernel=1
comp_bb=1
comp_glibc=1 
strip_sym=1 

while test $# -gt 0
do
    case "$1" in
        "--help")
            echo "possible options:"
            echo "  --help          show this"
            echo "  --clean         clean everything before re-building"
            echo "  --skip-kernel   skip compilation AND configuration of kernel"
            echo "  --skip-busybox  skip compilation AND configuration AND installation of busybox"
            echo "  --skip-glibc    skip compilation AND configuration AND installation of glibc"
            echo "  --no-strip      do not strip debugging symbols"
            exit 0
            ;;
        "--clean")
            CLEAN_UP=1
            ;;
        "--skip-kernel")
            comp_kernel=0 
            ;;
        "--skip-busybox")
            comp_bb=0
            ;;
        "--skip-glibc")
            comp_glibc=0
            ;;
        "--no-strip")
            strip_sym=0
            ;;
        --*)
            echo "invalid option! run with --help to get a list of available options!"
            exit 1
            ;;
        *) echo "argument $1"
            echo "invalid argument! run with --help to get a list of available arguments!"
            exit 1
            ;;
    esac
    shift
done

if [ $CLEAN_UP -eq 1 ]; then
    err=0 
    if [ $comp_kernel -eq 0 ]; then 
        err=1
    fi
    if [ $comp_glibc -eq 0 ]; then
        err=1
    fi 
    if [ $comp_bb -eq 0 ]; then
        err=1
    fi 
    if [ $err -eq 1 ]; then
        echo "invalid combination of arguments!"
        exit 1 
    fi 
fi 

step () {
    echo ""
echo "  "$1
    echo $SEP
}

step "Checking dependencies"
errs=0

required () {
    if ! command -v $1 &> /dev/null
    then
        echo "\"$1\" not be found!"
        ((errs++))
    fi
}

required "wget"
required "zstd"
required "git"
required "tar"
required "patch"
required "make"
required "rsync"
required "msgfmt"
required "makeinfo"
required "sed"
required "gawk"
required "bison"
required "python3"
required "strip"
required "grub-mkrescue"
required "xorriso"
required "mformat"

required $CC
required $CXX
required $LD
required $BB_CC
required $GLIBC_CC

if ! [ $errs -eq 0 ]; then
    echo "Stopping"
    exit $errs
fi

if [ $CLEAN_UP -eq 1 ]; then
    step "Cleaning up"
    rm -rf build/
    rm -rf download/
    rm -rf target/
fi

if ! [ -d "build/" ]; then
    mkdir build/
fi

if ! [ -d "download/" ]; then
    mkdir download/
fi

if ! [ -d "target/" ]; then
    step "Creating target file system"

    mkdir target
    mkdir -p target/{bin,boot{,grub},dev,{etc/,}opt,home,lib/{firmware,modules},lib64}
    mkdir -p target/{proc,sbin,srv,sys}
    mkdir -p target/var/{lock,log,run,spool,op,cache,lib/{misc,locate},local}
    install -d -m 0750 target/root
    install -d -m 1777 target/{/var,}/tmp
    install -d target/etc/init.d
    mkdir -p target/usr/{,local/}{bin,include,lib{,64},sbin,src}
    mkdir -p target/usr/{,local/}share/{doc,info,locale,man,misc,terminfo,zoneinfo}
    mkdir -p target/usr/{,local/}share/man/man{1,2,3,4,5,6,7,8}
    for dir in target/usr{,/local}; do 
        ln -s share/{man,doc,info} ${dir}
    done
fi

if ! [ -f download/"kernel.tar.xz" ]; then 
    step "Downloading kernel"
    wget -O download/"kernel.tar.xz" $KERNEL_URL
fi
if ! [ -f download/"zen-patches.patch.zst" ]; then 
    if [ $ZEN_KERNEL -eq 1 ]; then
        step "Downloading zen patches"
        wget -O download/"zen-patches.patch.zst" $ZEN_KERNEL_URL
    fi
fi 

if ! [ -d build/"linux" ]; then  
    step "Unpacking kernel"
    tar -xf download/"kernel.tar.xz" -C build/
    mv build/"linux"* build/"linux"
fi 
if ! [ -f download/"zen-patches.patch" ]; then
    if [ $ZEN_KERNEL -eq 1 ]; then
        step "Unpacking zen patches"
        zstd -T$NUM_CORES -o download/"zen-patches.patch" --decompress download/"zen-patches.patch.zst"
    fi
fi

if [ $ZEN_KERNEL -eq 1 ]; then
    step "Applying zen patches"
    patch -t -p1 -d build/"linux" < download/"zen-patches.patch"
fi

step "Applying custom kernel patches"
for file in patches/kernel/*.patch; do 
    patch -t -p1 -d build/"linux" < $file
done

if [ $comp_kernel -eq 1 ]; then 
    step "Configuring kernel"
    make -C build/linux/ LD=$LD CC=$CC HOSTCC=$CC HOSTLD=$LD -j$NUM_CORES x86_64_defconfig
    for file in config/kernel/*.patch; do
         patch -t -p1 -d build/linux < $file
    done

    step "Compiling kernel"
    make -C build/linux/ LD=$LD CC=$CC -j$NUM_CORES HOSTCC=$CC HOSTLD=$LD
fi 

tg_path=$(realpath target)

step "Installing kernel headers"
make -C build/linux/ LD=$LD CC=$CC -j$NUM_CORES HOSTCC=$CC HOSTLD=$LD INSTALL_HDR_PATH="$tg_path/usr" headers_install

if ! [ -f download/"glibc.tar.xz" ]; then
    step "Downloading GLibC"
    wget -O download/"glibc.tar.xz" $GLIBC_URL
fi

if ! [ -d build/"glibc" ]; then
    step "Unpacking GLibC"
    tar -xf download/"glibc.tar.xz" -C build/
    mv build/glibc* build/"glibc"
fi 

export LD=$LD
OLD_CC=$CC
export CC=$CC
export CXX=$CXX 

if [ $comp_glibc -eq 1 ]; then 
    step "Configuring GLibC"
    cd build/glibc
    if ! [ -d build/ ]; then 
        mkdir build/
    fi 
    cd build/

    echo "libc_cv_forced_unwind=yes" > config.cache
    echo "libc_cv_c_cleanup=yes" >> config.cache
    echo "libc_cv_ssp=no" >> config.cache
    echo "libc_cv_ssp_strong=no" >> config.cache
    
    export CC=$GLIBC_CC
    export BUILD_CC=$GLIBC_CC

    ../configure \
        --with-headers="$tg_path/usr/include" \
        --prefix=/usr \
        --disable-profile \
        --enable-add-ons \
        --with-tls \
        --with-__thread \
        --cache-file=config.cache 

    step "Compiling GLibC"
    make -j12 CC=$GLIBC_CC LD=$LD CXX=$CXX

    step "Installing GLibC on target system"
    make install_root=$tg_path/ install
    cd ../../../ 
fi 

export CC=$OLD_CC 

if ! [ -f download/"busybox.tar.bz2" ]; then
    step "Downloading BusyBox"
    wget -O download/"busybox.tar.bz2" $BUSYBOX_URL
fi

if ! [ -d build/"busybox" ]; then
    step "Unpacking BusyBox"
    tar -xf download/"busybox.tar.bz2" -C build/
    mv build/"busybox"* build/"busybox"
fi

if [ $comp_bb -eq 1 ]; then 
    step "Configuring BusyBox"
    make -C build/busybox LD=$LD CC=$BB_CC defconfig
    for file in config/busybox/*.patch; do
        patch -t -p1 -d build/busybox < $file
    done
    sed -i "s\`CONFIG_SYSROOT=\"\"\`CONFIG_SYSROOT=\"${tg_path}\"\`g" build/busybox/.config

    step "Compiling BusyBox"
    make -C build/busybox LD=$LD CC=$BB_CC -j$NUM_CORES # CROSS_COMPILE="$tg_path/"

    step "Installing BusyBox on target system"
    make -C build/busybox LD=$LD CC=$BB_CC CONFIG_PREFIX=${tg_path} install
fi 

step "Installing kernel on target system"
make -C build/linux INSTALL_MOD_PATH=${tg_path} modules_install
cp build/linux/arch/x86_64/boot/bzImage target/boot/vmlinuz-$KVERS_FULL
cp build/linux/System.map target/boot/System.map-$KVERS_FULL
cp build/linux/.config target/boot/config-$KVERS_FULL
chmod +x build/busybox/examples/depmod.pl
build/busybox/examples/depmod.pl \
    -F target/"boot/System.map-$KVERS_FULL" \
    -b target/"lib/modules/$KVERS_FULL"

if ! [ -f download/"clfs-embedded-bootscripts-1.0-pre4.tar.bz2" ]; then
    step "Downloading CLFS embedded bootscripts"
    wget -O download/"clfs-embedded-bootscripts-1.0-pre4.tar.bz2" $CLFS_BOOT_SCRIPTS_URL
fi 

if ! [ -d build/clfs-boot-scripts/ ]; then
    step "Unpacking CLFS embedded bootscripts"
    tar -xf download/"clfs-embedded-bootscripts-1.0-pre4.tar.bz2" -C build/
    mv build/clfs-embedded-bootscripts* build/clfs-boot-scripts
fi

# step "Patching boot scripts"
# for file in patches/bootscripts/*.patch; do 
#     patch -t -p1 -d build/clfs-boot-scripts < $file
# done

step "Installing boot scripts"
make -C build/clfs-boot-scripts DESTDIR=$tg_path/ install-bootscripts
if ! [ -f $tg_path/etc/init.d/rcS ]; then 
    ln -sv $tg_path/etc/rc.d/startup $tg_path/etc/init.d/rcS
fi 

if [ $strip_sym -eq 1 ]; then
    step "Stripping debugging symbols"
    find $tg_path/{,usr/}{bin,lib,sbin} -type f -exec strip --strip-debug '{}' ';'
    find $tg_path/{,usr/}lib64 -type f -exec strip --strip-debug '{}' ';'
fi 

step "Configuring target OS"
for file in conf/target/*; do 
    cp $file $tg_path/etc/
done
if ! [ -d $tg_path/boot/grub/ ]; then 
    mkdir $tg_path/boot/grub/ 
fi 
echo "
set default=0
set timeout=5

set root=(hd0,1)

menuentry \"NeatOS 0.1\" {
        linux   /boot/vmlinuz-$KVERS_FULL root=/dev/sda1 ro quiet
}
" > $tg_path/boot/grub/grub.cfg
touch $tg_path/var/run/utmp $tg_path/var/log/{btmp,lastlog,wtmp}
chmod -v 664 $tg_path/var/run/utmp $tg_path/var/log/lastlog
sudo chown -R root:root $tg_path
sudo chgrp 13 $tg_path/var/run/utmp $tg_path/var/log/lastlog
sudo mknod -m 0666 $tg_path/dev/null c 1 3
sudo mknod -m 0600 $tg_path/dev/console c 5 1
sudo chmod 4755 $tg_path/bin/busybox

step "Creating ISO"
grub-mkrescue -o "NeatOS-0.1.iso" $tg_path
