#! /bin/bash
setup-cluster:
    echo "Bring the HA cluster of k8s.....!"
    ansible-playbook -b -v -i inventory/sample/inventory.ini cluster.yml 
teardown-cluster:
    ansible-playbook -b -v -i inventory/sample/inventory.ini reset.yml -e reset_confirmation=yes

upgrade-cluster:
    echo "Bring the HA cluster of k8s.....!"
    ansible-playbook -b -v -i inventory/sample/inventory.ini upgrade-cluster.yml
