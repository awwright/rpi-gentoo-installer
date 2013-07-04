#!/bin/sh

for b in dd parted emerge rsync; do
	if ! type $b &>/dev/null; then
		echo "Command not found: $b" >&2
		exit 1
	fi
done

print_help() {
	echo "Usage: $0 [options]"
	echo "Options:"
	echo "    -? -h --help               This help"
	echo "    --pretend                  Only show configured options"
	echo "    --disk-image-path=<file>   Create an image for/on an SD card"
	echo "    --disk-image-size=<bytes>  Set size of output disk image, if necessary"
	echo "    --boot-image-path=<file>   Create a boot partition image"
	echo "    --boot-image-size=<bytes>  Set size of output image, if necessary"
	echo "    --boot-image-mnt=<dir>     Location of existing filesystem to install boot files to"
	echo "    --root-image-path=<file>   Create a root partition image"
	echo "    --root-image-size=<bytes>  Set size of output image, if necessary"
	echo "    --root-image-mnt=<dir>     Location of existing filesystem to install root files to"
	echo "    --pkgdir=<dir>             Location of cache for binary packages"
	echo "    --package=<name>           Install a package (in addition to others)"
}

PRETEND=
BOOT_IMAGE_PATH=
BOOT_IMAGE_SIZE=
BOOT_IMAGE_SIZE_DEFAULT=
BOOT_IMAGE_MNT=
BOOT_IMAGE_MNT_DEFAULT=mnt/boot
ROOT_IMAGE_PATH=
ROOT_IMAGE_SIZE=
ROOT_IMAGE_MNT=
ROOT_IMAGE_MNT_DEFAULT=mnt/root
DISK_IMAGE_PATH=
DISK_IMAGE_SIZE=
PKGDIR=$PKGDIR
PKGDIR_DEFAULT=packages
PACKAGES=$(cat src/world)

getarg() {
	case "$1" in
		--*=)
			echo 1 ;;
		--*=*)
			expr "X$1" : '[^=]*=\(.*\)' ;;
	esac
}

while (( "$#" )); do
	case "$1" in
		-?|-h|--help)
			print_help; exit ;;
		--pretend)
			PRETEND=1 ;;
		--disk-image-path=*)
			DISK_IMAGE_PATH="$(getarg $1)" ;;
		--disk-image-size=*)
			DISK_IMAGE_SIZE=$((0+$(getarg $1))) ;;
		--boot-image-path=*)
			BOOT_IMAGE_PATH="$(getarg $1)" ;;
		--boot-image-size=*)
			BOOT_IMAGE_SIZE=$((0+$(getarg $1))) ;;
		--boot-image-mnt=*)
			BOOT_IMAGE_MNT="$(getarg $1)" ;;
		--root-image-path=*)
			ROOT_IMAGE_PATH="$(getarg $1)" ;;
		--root-image-size=*)
			ROOT_IMAGE_SIZE=$((0+$(getarg $1))) ;;
		--root-image-mnt=*)
			ROOT_IMAGE_MNT="$(getarg $1)" ;;
		--pkgdir=*)
			PKGDIR="$(getarg $1)" ;;
		--package=*)
			PACKAGES="$PACKAGES $(getarg $1)" ;;
		*)
			echo "Unknown argument $1"
			exit
			;;
	esac
	shift
done

setup_loopback() {
	line=$(parted -s $1 'unit B' 'p' | awk "/^ $2 /{print}")
	offset=$(echo "$line" | awk '{print $2}')
	size=$(echo "$line" | awk '{print $4}')
	offset=${offset%%B}
	size=${size%%B}
	dev=$($SUDO losetup -o $offset --sizelimit $size -f --show $1 2>/dev/null)
	echo $dev
}

MBR_SIZE=512

prepare_disk_image() {
	echo "Preparing disk image..."

	BOOTFS_START=$MBR_SIZE
	BOOTFS_END=$(expr $BOOTFS_START + $BOOTFS_SIZE - 1)
	ROOTFS_START=$(expr $BOOTFS_END + 1)
	ROOTFS_END=$(expr $DISK_IMAGE_SIZE - 1)

	#rm -f $DISK_IMAGE_PATH
	test -f "$DISK_IMAGE_PATH" || dd if=/dev/zero of=$DISK_IMAGE_PATH bs=4M count=$(expr $DISK_IMAGE_SIZE / 4194304)
	parted $DISK_IMAGE_PATH -s -a minimal "mklabel msdos"
	parted $DISK_IMAGE_PATH -s -a minimal "mkpart primary fat32 ${BOOTFS_START}B ${BOOTFS_END}B"
	parted $DISK_IMAGE_PATH -s -a minimal "set 1 boot on"
	parted $DISK_IMAGE_PATH -s -a minimal "mkpart primary ext4 ${ROOTFS_START}B ${ROOTFS_END}B"
}

pause() {
	echo 'Press return to continue...'
	read
}

# See if we can guess at any arguments

fill_in_arguments() {
	if [ -n "$BOOT_IMAGE_PATH" -a -z "$BOOT_IMAGE_SIZE" ]; then
		BOOT_IMAGE_SIZE=$((96*1024*1024))
	fi

	if [ -n "$DISK_IMAGE_PATH" -a '(' -n "$BOOT_IMAGE_PATH" -o -n "$ROOT_IMAGE_PATH" ')' ]; then
		echo 'Cannot provide disk-image-path with boot-image-path or root-image-path.'
		exit 1
	fi

	# Set defaults if not set by the user
	if [ -z "$BOOT_IMAGE_MNT" -a -n "$BOOT_IMAGE_PATH" ]; then
		BOOT_IMAGE_MNT="$BOOT_IMAGE_MNT_DEFAULT"
	fi
	if [ -z "$ROOT_IMAGE_MNT" -a -n "$ROOT_IMAGE_PATH" ]; then
		ROOT_IMAGE_MNT="$ROOT_IMAGE_MNT_DEFAULT"
	fi
	if [ -z "$PKGDIR" ]; then
		PKGDIR="$PKGDIR_DEFAULT"
	fi

	if [ -n "$BOOT_IMAGE_PATH" -a -n "$ROOT_IMAGE_PATH" ]; then
		BOOT_IMAGE_SIZE=$((48*1024*1024))
	fi
}

validate_arguments() {
	# Sanity check the rest of the arguments
	if [ -z "$DISK_IMAGE_PATH" -a -z "$BOOT_IMAGE_MNT" -a -z "$ROOT_IMAGE_MNT" ]; then
		echo "Must provide one of disk-image-path, boot-image-path, or root-image-path."
		exit 1
	fi
	if [ -n "$DISK_IMAGE_PATH" ]; then
		if [ -z "$DISK_IMAGE_SIZE" ]; then
			echo "Must provide disk-image-size with disk-image-path"
			exit 1
		fi
		if [ -d "$DISK_IMAGE_PATH" ]; then
			echo "disk-image-path cannot be a directory"
			exit
		fi
	fi
	if [ -n "$BOOT_IMAGE_PATH" ]; then
		if [ -z "$BOOT_IMAGE_SIZE" ]; then
			echo "Must provide boot-image-size with boot-image-path"
			exit 1
		fi
		if [ -d "$BOOT_IMAGE_PATH" ]; then
			echo "boot-image-path is a directory, did you mean boot-image-mnt?"
			exit
		fi
	fi
	if [ -n "$ROOT_IMAGE_PATH" ]; then
		if [ -z "$ROOT_IMAGE_SIZE" ]; then
			echo "Must provide root-image-size with root-image-path"
			exit 1
		fi
		if [ -d "$ROOT_IMAGE_PATH" ]; then
			echo "root-image-path is a directory, did you mean root-image-mnt?"
			exit
		fi
	fi
	if [ -n "$ROOT_IMAGE_MNT" ]; then
		if [ ! -d "$PKGDIR" ]; then
			echo "Package directory does not exist: $PKGDIR"
			exit 1
		fi
	fi
}
fill_in_arguments

# If any arguments are still missing, prompt for them here
# fill_in_arguments

validate_arguments

test -n "$PRETEND" || echo "Will start installation..."

if [ -n "$DISK_IMAGE_PATH" ]; then
	echo "Disk image path: $DISK_IMAGE_PATH"
	echo "Disk image size: $DISK_IMAGE_SIZE"
fi
if [ -n "$BOOT_IMAGE_MNT" ]; then
	[ -n "$BOOT_IMAGE_PATH" ] && echo "Boot image path: $BOOT_IMAGE_PATH"
	echo "Boot image size: $BOOT_IMAGE_SIZE"
	echo "Boot image mountpoint: $BOOT_IMAGE_MNT"
fi
if [ -n "$ROOT_IMAGE_MNT" ]; then
	[ -n "$ROOT_IMAGE_PATH" ] && echo "Root image path: $ROOT_IMAGE_PATH"
	echo "Root image size: $ROOT_IMAGE_SIZE"
	echo "Root image mountpoint: $ROOT_IMAGE_MNT"
	echo "Package directory: $PKGDIR"
fi

test -n "$PRETEND" && exit

echo -n 'Installing in 5... '
for I in {4..0}; do
	sleep 1; echo -n "$I... ";
done
echo 'Go!'

if [ -n "$DISK_IMAGE_PATH" ]; then
	prepare_disk_image
	setup_loopback $DISK_IMAGE_PATH 1
	BOOT_IMAGE_MNT_DEVICE=$dev
	setup_loopback $DISK_IMAGE_PATH 2
	ROOT_IMAGE_MNT_DEVICE=$dev
else
	BOOT_IMAGE_MNT_DEVICE=$BOOT_IMAGE_PATH
	ROOT_IMAGE_MNT_DEVICE=$ROOT_IMAGE_PATH
fi

if [ -n "$BOOT_IMAGE_PATH" ]; then
	test -f "$BOOT_IMAGE_PATH" || dd if=/dev/zero of=$BOOT_IMAGE_PATH bs=4M count=$(expr $BOOT_IMAGE_SIZE / 4194304)
fi

if [ -n "$BOOT_IMAGE_MNT_DEVICE" ]; then
	echo 'Mounting boot'
	mkfs.vfat -n boot -f 2 -F 32 $BOOT_IMAGE_PATH
	mount "$BOOT_IMAGE_PATH" -o loop,noatime "$BOOT_IMAGE_MNT"
fi

if [ -n "$BOOT_IMAGE_MNT" ]; then
	echo 'Installing boot'
	rsync -av src/boot/ "$BOOT_IMAGE_MNT"
fi

if [ -n "$ROOT_IMAGE_PATH" ]; then
	test -f "$ROOT_IMAGE_PATH" || dd if=/dev/zero of=$ROOT_IMAGE_PATH bs=4M count=$(expr $ROOT_IMAGE_SIZE / 4194304)
fi

if [ -n "$ROOT_IMAGE_MNT_DEVICE" ]; then
	echo 'Mounting device root filesystem'
	umount $ROOT_IMAGE_MNT
	test -f "$ROOT_IMAGE_PATH" || ROOT_IMAGE_PATH
	mkfs.ext4dev -F -L rootfs -M / $ROOT_IMAGE_PATH
	mount "$ROOT_IMAGE_PATH" "$ROOT_IMAGE_MNT" || exit
fi

if [ -n "$ROOT_IMAGE_MNT" ]; then
	echo 'Installing system'
	mkdir -pv $ROOT_IMAGE_MNT/etc/portage/
	ln -svf /usr/portage/profiles/default/linux/arm/13.0/armv6j $ROOT_IMAGE_MNT/etc/portage/make.profile
	cp -av /etc/portage/make.conf $ROOT_IMAGE_MNT/etc/portage/make.conf
	rsync -av src/overlay/ "$ROOT_IMAGE_MNT"
	mkdir -pv "$ROOT_IMAGE_MNT/dev"
	mknod "$ROOT_IMAGE_MNT/dev/console" c 5 1
	mknod "$ROOT_IMAGE_MNT/dev/null" c 1 3
	mknod "$ROOT_IMAGE_MNT/dev/zero" c 1 5
	echo Merge sys-apps/baselayout
	env ROOT="$ROOT_IMAGE_MNT" PORTAGE_CONFIGROOT="$ROOT_IMAGE_MNT" PKGDIR="$PKGDIR" emerge --buildpkg --usepkg --jobs=1 --root-deps=rdeps baselayout
	# Mark news as read
	cat $ROOT_IMAGE_MNT/var/lib/gentoo/news/news-gentoo.unread >> $ROOT_IMAGE_MNT/var/lib/gentoo/news/news-gentoo.read
	cat /dev/null > $ROOT_IMAGE_MNT/var/lib/gentoo/news/news-gentoo.read
	#pause
	sed -i -e 's/^#en_US.UTF-8 UTF-8$/en_US.UTF-8 UTF-8/' $ROOT_IMAGE_MNT/etc/locale.gen
	echo Merge @system
	env ROOT="$ROOT_IMAGE_MNT" PORTAGE_CONFIGROOT="$ROOT_IMAGE_MNT" PKGDIR="$PKGDIR" emerge --buildpkg --usepkg --jobs=1 --root-deps=rdeps @system
	echo Merge $PACKAGES
	env ROOT="$ROOT_IMAGE_MNT" PORTAGE_CONFIGROOT="$ROOT_IMAGE_MNT" PKGDIR="$PKGDIR" emerge --buildpkg --usepkg --jobs=1 --root-deps=rdeps $PACKAGES
fi
