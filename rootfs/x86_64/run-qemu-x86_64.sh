#!/bin/bash

dir=$(cd $(dirname $0); pwd)
. ${dir}/../scripts/config.sh
. ${dir}/../scripts/common.sh

parse_args "$@"
shift $((OPTIND - 1))

machine=$1
cputype=$2

QEMU=${QEMU:-${QEMU_BIN}/qemu-system-x86_64}
ARCH=x86_64

# Older releases don't like gcc 6+
rel=$(git describe | cut -f1 -d- | cut -f1,2 -d.)
case "${rel}" in
"v3.16"|"v3.18")
	PATH_X86=/opt/poky/1.3/sysroots/x86_64-pokysdk-linux/usr/bin/x86_64-poky-linux
	PREFIX="x86_64-poky-linux-"
	;;
*)
	PATH_X86=/opt/kernel/x86_64/gcc-6.3.0/usr/bin/
	PREFIX="x86_64-linux-"
	;;
esac

PATH=${PATH_X86}:${PATH}

cached_config=""

skip_316="defconfig:smp:scsi[AM53C974] \
	defconfig:smp:scsi[DC395] \
	defconfig:nosmp:scsi[AM53C974] \
	defconfig:nosmp:scsi[DC395]"

skip_318="defconfig:smp:scsi[AM53C974] \
	defconfig:smp:scsi[DC395] \
	defconfig:nosmp:scsi[AM53C974] \
	defconfig:nosmp:scsi[DC395]"

patch_defconfig()
{
    local defconfig=$1
    local fixup=$2

    if [[ "${fixup}" = "nosmp" ]]; then
	sed -i -e '/CONFIG_SMP/d' ${defconfig}
    fi
    # Always enable SCSI controller drivers and NVME
    echo "CONFIG_BLK_DEV_NVME=y" >> ${defconfig}
    echo "CONFIG_SCSI_LOWLEVEL=y" >> ${defconfig}
    echo "CONFIG_SCSI_DC395x=y" >> ${defconfig}
    echo "CONFIG_SCSI_AM53C974=y" >> ${defconfig}
    echo "CONFIG_MEGARAID_SAS=y" >> ${defconfig}
}

runkernel()
{
    local defconfig=$1
    local fixup=$2
    local cpu=$3
    local mach=$4
    local rootfs=$5
    local drive
    local pid
    local retcode
    local logfile=/tmp/runkernel-$$.log
    local waitlist=("machine restart" "Restarting" "Boot successful" "Rebooting")
    local pbuild="${ARCH}:${mach}:${cpu}:${defconfig}:${fixup}"
    local build="${defconfig}:${fixup}"
    local config="${defconfig}:${fixup%:*}"

    if [[ "${rootfs}" == *cpio ]]; then
	pbuild+=":initrd"
    else
	pbuild+=":rootfs"
    fi

    if [ -n "${machine}" -a "${machine}" != "${mach}" ]
    then
	echo "Skipping ${pbuild} ... "
	return 0
    fi

    if [ -n "${cputype}" -a "${cputype}" != "${cpu}" ]
    then
	echo "Skipping ${pbuild} ... "
	return 0
    fi

    echo -n "Building ${pbuild} ... "

    if ! checkskip "${build}" ; then
	return 0
    fi

    if [ "${cached_config}" != "${config}" ]
    then
	dosetup -f "${fixup}" "${rootfs}" "${defconfig}"
	if [ $? -ne 0 ]; then
	    return 1
	fi
	cached_config="${config}"
    else
	setup_rootfs "${rootfs}"
    fi

    echo -n "running ..."

    if [[ "${rootfs}" == *cpio ]]; then
	initcli="rdinit=/sbin/init"
	diskcmd="-initrd ${rootfs}"
    else
	initcli="root=/dev/sda rw"
	if [[ "${fixup}" == *sata ]]; then
	    diskcmd="-drive file=${rootfs},if=ide,format=raw"
	elif [[ "${fixup}" == *nvme ]]; then
	    initcli="root=/dev/nvme0n1 rw"
	    diskcmd="-device nvme,serial=foo,drive=d0 \
		-drive file=${rootfs},if=none,format=raw,id=d0"
	elif [[ "${fixup}" == *usbdisk ]]; then
	    initcli="root=/dev/sda rw rootwait"
	    diskcmd="-device usb-storage,drive=d0 \
		-drive file=${rootfs},if=none,format=raw,id=d0"
	elif [[ "${fixup##*:}" == scsi* ]]; then
	    case "${fixup##*:}" in
	    "scsi[DC395]")
		device="dc390"
		;;
	    "scsi[AM53C974]")
		device="am53c974"
		;;
	    "scsi[MEGASAS]")
		device="megasas-gen2"
		;;
	    esac
	    diskcmd="-device "${device}" -device scsi-hd,drive=d0 \
		-drive file=${rootfs},if=none,format=raw,id=d0"
	fi
    fi

    kvm=""
    mem="-m 256"
    if [ "${cpu}" = "kvm64" ]
    then
	kvm="-enable-kvm -smp 4"
	mem="-m 1024"
    fi

    [[ ${dodebug} -ne 0 ]] && set -x

    ${QEMU} -kernel arch/x86/boot/bzImage \
	-M ${mach} -cpu ${cpu} ${kvm} -usb -no-reboot ${mem} \
	${diskcmd} \
	--append "earlycon=uart8250,io,0x3f8,9600n8 ${initcli} console=ttyS0 console=tty doreboot" \
	-nographic > ${logfile} 2>&1 &
    pid=$!

    [[ ${dodebug} -ne 0 ]] && set +x

    dowait ${pid} ${logfile} manual waitlist[@]
    retcode=$?
    rm -f ${logfile}
    return ${retcode}
}

echo "Build reference: $(git describe)"
echo

retcode=0

# runkernel defconfig kvm64 q35
# retcode=$((${retcode} + $?))
runkernel defconfig smp:sata Broadwell-noTSX q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:nvme IvyBridge q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:scsi[DC395] SandyBridge q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:scsi[AM53C974] Haswell q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:scsi[MEGASAS] core2duo pc rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:nvme Nehalem q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:sata phenom pc rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp:scsi[DC395] Opteron_G1 q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp Opteron_G5 q35 rootfs.cpio
retcode=$((${retcode} + $?))
runkernel defconfig smp:usbdisk EPYC-IBPB q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp Skylake-Client q35 rootfs.cpio
retcode=$((${retcode} + $?))
runkernel defconfig smp:usbdisk Skylake-Server q35 rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig smp Opteron_G3 q35 rootfs.cpio
retcode=$((${retcode} + $?))
runkernel defconfig nosmp:scsi[AM53C974] Opteron_G4 pc rootfs.ext2
retcode=$((${retcode} + $?))
runkernel defconfig nosmp:scsi[MEGASAS] IvyBridge q35 rootfs.ext2
retcode=$((${retcode} + $?))

exit ${retcode}
