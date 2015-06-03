#!/bin/bash
# A tool for showing CPU, network- and diskload on a Xen Host at once.
# At the moment we use the xm toolstack for historic reasons and the lack of a Xen install with xl toolstack.
#
# You the folling tools on your system: awk, bash, date, sar, sort, stat, tput, xentop and xm. The location of this tools are Debian based.
#
# TODO:
#	- combine getNetworkLoad() and getIOStat(), because both use sar and we should get a faster update. Than we have to parse network and io from one sar command.
#	- dynamic amount of disks
#
# Links:
# /proc/net/dev
# /proc/diskstats
#	https://www.kernel.org/doc/Documentation/ABI/testing/procfs-diskstats
#	https://www.kernel.org/doc/Documentation/iostats.txt
#
# Licence:
#    Copyright (C) 2014-2015  Matthias Scholz
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#
#set -x
#set -u

# we need all messages in english!
unset LANG

AWK="/usr/bin/awk"
DATE="/bin/date"
SAR="/usr/bin/sar"
SORT="/usr/bin/sort"
STAT="/usr/bin/stat"
TPUT="/usr/bin/tput"
XENTOP="/usr/sbin/xentop"
XM="/usr/sbin/xm"

# Array for the lookup from network interface to host. That are only the "vif..." of the VM's
declare -A interface2host

# Array with the networkload
declare -A host2networkload

# Array for the lookup from the host to the blockdevices
declare -A host2blockDevs

# Array with the IO stats
declare -A dev2ioStat

# Array with the non LVM disks, mostly sd*
declare -A normalDisks

# Array with the Xen CPU usage
declare -A dom2cpuUsage

# fill the array for the lookup from the network interface to the host
# we make this only at startup
# TODO: update the array in case of creation of a new VM or destruction of an existing VM
while read host id
do
    vif="vif${id}.0"
    interface2host[$vif]="${host}"
done < <(${XM} list | ${AWK} 'NR > 1 {print $1 " " $2}')

# fill the array for the host to blockdevices
# sar or iostat supply the blockdev as a "dev{major}-{minor}" String
# we determine for every DomU the blockdevs in a list separated by spaces
while read host devs
do
    devList=""
    for dev in $devs
    do
	devList="${devList} $(printf "dev%d-%d" $(${STAT} -L --printf '0x%t 0x%T\n' "${dev}"))"
    done
    host2blockDevs[$host]="${devList}"
done < <(${XM} list -l | ${AWK} 'BEGIN {first=1} /^\(domain/ { if (first == 1) {first=0} else {printf("\n")}} /^    \(name .*\)/ || /^            \(uname phy:\/dev\/.*\)/ { gsub(/[\(\)]/, ""); gsub(/uname phy:/, ""); gsub(/ +/, " "); gsub(/^ name /, ""); printf("%s", $0)}  END {printf("\n")}')

# fill array  with the non-LVM disks (sd*)
while read dev devName
do
    normalDisks[$dev]=${devName}
done < <(${AWK} '/sd.$/ {printf("dev%s-%s %s\n", $1, $2, $4)}' /proc/partitions)

### functions
# fill the networkload array
getNetworkLoad() {
    # get the network load with sar
    while read if rxkBs txkBs
    do
	host=${interface2host[${if}]}
	# if a host ist empty after the interface to host lookup, this is a non VM network interface such as eth*, lo, bridges. It gets embraced with "()".
	[ -z "${host}" ] && host="(${if})"
	host2networkload[$host]="${rxkBs} ${txkBs}"
    done < <(${SAR} -n DEV 1 1 | ${AWK} '!/Average:/ && NR > 3 && $0 != "" {print $2 " " $5 " " $6}')
}


# fill the io stats array
getIOStat() {
    # loop through all devices
    while read dev tps rd_sec wr_sec
    do
	dev2ioStat["$dev"]="${rd_sec} ${wr_sec}"
    done < <(${SAR} -d 1 1 | ${AWK} '!/Average:/ && NR > 3 && $0 != "" {printf"%s %d %d %d\n", $2,  $3, $4 / 2, $5 / 2}')
}

# fill the array with the Xen CPU usage
getXenCpuUsage() {
# we need two iterations of xentop, because the first one delivers 0 for all CPU's :-( The awk have to use only the second sample!
    while read dom cpu
    do
	dom2cpuUsage["$dom"]="$cpu"
    done < <(${XENTOP} --batch --delay 1 --iterations 2 | ${AWK} 'BEGIN {sample=0} {if (sample==2) print $1 " " $4} /NAME  STATE   CPU/ {sample++}')
}

# dumps an array - only for debugging
# $1 - array
dumpArray() {
    for k in ${!host2blockDevs[*]}
    do
	echo "$k -> ${host2blockDevs[$k]}"
    done
}

#dumpArray

# public static void main() :-D
# on exit make cursor visible again
trap '${TPUT} cnorm; exit' 1 2 15
# set cursor of and clear screen
${TPUT} civis
${TPUT} clear
${TPUT} cup 0 0
echo -n "collecting data "
while :
do
    getNetworkLoad
    echo -n "."
    getIOStat
    echo -n "."
    getXenCpuUsage
    echo -n "."
    # set cursor at position 0,0, because a simple clear flickers
    ${TPUT} cup 0 0
    printf "%13s %6s %19s  %19s %19s %19s\n" "$(${DATE} '+%H:%M:%S') host" "cpu" "network    " "disk1      " "disk2      " "disk3      "
    printf "%13s %6s %9s %9s  %9s %9s %9s %9s %9s %9s\n" "" "%" "rxkB/s" "txkB/s" "rdkb/s" "wrkB/s" "rdkb/s" "wrkB/s" "rdkb/s" "wrkB/s"
    # loop through all hosts
    (for host in ${!host2networkload[*]}
    do
	printf "%13s %6s %9s %9s  " "${host}" "${dom2cpuUsage[$host]}" ${host2networkload[$host]}
	# Blockdevs of the host
	for dev in ${host2blockDevs[$host]}
	do
	    printf "%9s %9s" ${dev2ioStat[$dev]}
	done
	printf "\n"
    done) | ${SORT} -b
    # the /dev/sd* disk are appear at the end without host
    (for dev in ${!normalDisks[*]}
    do
	printf "%13s %6s %9s %9s  %9s %9s\n" "Dom0 ${normalDisks[$dev]}" "${dom2cpuUsage['Domain-0']}" "" "" ${dev2ioStat[$dev]}
    done) | ${SORT} -b
    echo -ne "     \r"    
done
