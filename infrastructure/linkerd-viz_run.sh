#!/bin/bash
ssh -L 50750:localhost:50750 root@10.29.16.101 -i ~/Documents/PG/Projects/.sshkeys/iot_sm
sleep 5
ssh root@10.29.16.101 -i ~/Documents/PG/Projects/.sshkeys/iot_sm "/usr/local/bin/linkerd viz dashboard &"