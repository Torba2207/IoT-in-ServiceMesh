#!/bin/bash
for ip in 10.29.16.101 10.29.16.102 10.29.16.103 10.29.16.104; do
  echo -e "\n======================================"
  echo "🚀 EXPANDING DISK ON NODE: $ip"
  echo "======================================"
  
  # 1. Tell LVM to use 100% of the unallocated free space
  ssh -i ~/Documents/PG/Projects/.sshkeys/iot-sm root@$ip "lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv"
  
  # 2. Tell the filesystem to stretch to match the new LVM size
  ssh -i ~/Documents/PG/Projects/.sshkeys/iot-sm root@$ip "resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv"
  
  # 3. Print the new disk size
  echo -e "\n✅ New Disk Size:"
  ssh -i ~/Documents/PG/Projects/.sshkeys/iot-sm root@$ip "df -h /"
done