#!/bin/bash
ansible-playbook -i inventory.ini --private-key ~/Documents/PG/Projects/.sshkeys/iot_sm setup-microk8s.yaml