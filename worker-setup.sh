#!/usr/bin/env bash
# Script for setting up the cluster after initial booting and configuration by
# CloudLab.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

exec > >(tee "$SCRIPTPATH/system.log") 2>&1

# Echo all the args so we can see how this script was invoked in the logs.
echo -e "\n===== SCRIPT PARAMETERS ====="
echo $@
echo

# === Parameters decided by profile.py ===
# partition that will be exported via NFS and used as a shared home
# directory for cluster users.
NODE_LOCAL_STORAGE_DIR=$1
CLOUDLAB_USER=$2

# Other variables
NODES_TXT="nodes.txt"
USER_EXP="ubuntu"
HOSTNAME_EXP_CONTROLLER="expctrl"


# === Here goes configuration that's performed on every boot. ===

# nothing to do

# Check if we've already complete setup before. If so, the buck stops here.
# Everything above will be executed on every boot. Everything below this will be
# executed on the first boot only. Therefore any soft state that's reset after a
# reboot should be set above. If the soft state can only be set after setup,
# then it should go inside this if statement.
if [ -f /local/setup_done ]
then
  echo "setup already done"
  exit 0
fi

# === Here goes configuration that happens once on the first boot. ===


# === Software dependencies that need to be installed. ===
# Common utilities
echo -e "\n===== INSTALLING COMMON UTILITIES ====="
apt-get update
apt-get --assume-yes install mosh vim tmux pdsh tree axel htop ctags whois
echo -e "\n===== INSTALLING NFS PACKAGES ====="
apt-get --assume-yes install nfs-kernel-server nfs-common
echo -e "\n===== INSTALLING basic PACKAGES ====="
apt-get --assume-yes install python2.7 python-requests openjdk-8-jre ack-grep python-minimal  iperf3
echo -e "\n===== INSTALLING Docker ====="
apt-get --assume-yes install docker.io
gpasswd -a "$USER" docker
newgrp docker

# create new admin user
useradd -p `mkpasswd "test"` -d /home/"$USER_EXP" -m -g users -s /bin/bash "$USER_EXP"
passwd -d $USER_EXP
gpasswd -a $USER_EXP root

chown -R "$USER_EXP:" "$NODE_LOCAL_STORAGE_DIR"


# === Configuration settings for all machines ===
# Make vim the default editor.
cat >> /etc/profile.d/etc.sh <<EOM
export EDITOR=vim
EOM
chmod ugo+x /etc/profile.d/etc.sh

# Disable user prompting for sshing to new hosts.
cat >> /etc/ssh/ssh_config <<EOM
    StrictHostKeyChecking no
EOM

# Change default shell to bash for all users on all machines
echo -e "\n===== CHANGE USERS SHELL TO BASH ====="
for user in $(ls /home/)
do
  chsh -s /bin/bash $user
done

echo -e "\n===== SETTING UP SSH BETWEEN NODES ====="
ssh_dir=/home/$USER_EXP/.ssh
mkdir "$ssh_dir"
/usr/bin/geni-get key > $ssh_dir/id_rsa
chown $USER_EXP: $ssh_dir/id_rsa
chmod 600 $ssh_dir/id_rsa

ssh-keygen -y -f $ssh_dir/id_rsa > $ssh_dir/id_rsa.pub
cat $ssh_dir/id_rsa.pub >> $ssh_dir/authorized_keys
cat "/users/$CLOUDLAB_USER/.ssh/authorized_keys" >> $ssh_dir/authorized_keys
chown $USER_EXP: $ssh_dir/authorized_keys
chown -R $USER_EXP: $ssh_dir
chmod 644 $ssh_dir/authorized_keys

# Add machines to /etc/hosts
echo -e "\n===== ADDING HOSTS TO /ETC/HOSTS ====="
hostArray=("$HOSTNAME_EXP_CONTROLLER")
host="worker"
hostArray=("${hostArray[@]}" "$host")

for host in ${hostArray[@]}
do
  while ! nc -z -v -w5 $host 22
  do
    sleep 1
    echo "Waiting for $host to come up..."
  done
  # ctrlip localip hostname
  echo $(getent hosts $host | awk '{ print $1 ; exit }')" "$(getent hosts $host | awk '{ print $1 ; exit }')" $host"  >> /home/$USER_EXP/$NODES_TXT
done

# Mark that setup has finished. This script is actually run again after a
# reboot, so we need to mark that we've already setup this machine and catch
# this flag after a reboot to prevent ourselves from re-running everything.
touch /local/setup_done

echo -e "\n===== SYSTEM SETUP COMPLETE ====="
