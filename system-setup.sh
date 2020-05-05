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
# Number of worker machines in the cluster.
NUM_WORKER=$3
# Number of aggregation switches in the cluster.
NUM_AGG=$4
# Local partition on NFS server that will be exported via NFS and used as a
# shared home directory for cluster users.
NFS_SHARED_HOME_EXPORT_DIR=$5
# NFS directory where remote blockstore datasets are mounted and exported via
# NFS to be shared by all nodes in the cluster.
NFS_DATASETS_EXPORT_DIR=$6


# === Paarameters decided by this script. ===
# Directory where the NFS partition will be mounted on NFS clients
SHARED_HOME_DIR=/shome
# Directory where NFS shared datasets will be mounted on NFS clients
DATASETS_DIR=/datasets

# Other variables
KERNEL_RELEASE=`uname -r`
UBUNTU_RELEASE=`lsb_release --release | awk '{print $2}'`
NODES_TXT="nodes.txt"
USER_EXP="ubuntu"
HOSTNAME_JUMPHOST="jumphost"
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
hostArray=("$HOSTNAME_JUMPHOST" "$HOSTNAME_EXP_CONTROLLER")
for i in $(seq 1 $NUM_WORKER)
do
  host=$(printf "worker%02d" $i)
  hostArray=("${hostArray[@]}" "$host")
done

for host in ${hostArray[@]}
do
  while ! nc -z -v -w5 $host 22
  do
    sleep 1
    echo "Waiting for $host to come up..."
  done
  # ctrlip localip hostname
  if [ "$host" == "$HOSTNAME_JUMPHOST" ]
  then
    continue
  fi
  echo $(getent hosts $host | awk '{ print $1 ; exit }')" "$(getent hosts $host | awk '{ print $1 ; exit }')" $host"  >> /home/$USER_EXP/$NODES_TXT
done

# NFS specific setup here. NFS exports NFS_SHARED_HOME_EXPORT_DIR (used as
# a shared home directory for all users), and also NFS_DATASETS_EXPORT_DIR
# (mount point for CloudLab datasets to which cluster nodes need shared access).
if [ $(hostname --short) == "$HOSTNAME_JUMPHOST" ]
then
  echo -e "\n===== SETTING UP NFS EXPORTS ON NFS ====="
  # Make the file system rwx by all.
  chmod 777 $NFS_SHARED_HOME_EXPORT_DIR

  # The datasets directory only exists if the user is mounting remote datasets.
  # Otherwise we'll just create an empty directory.
  if [ ! -e "$NFS_DATASETS_EXPORT_DIR" ]
  then
    mkdir $NFS_DATASETS_EXPORT_DIR
  fi

  chmod 777 $NFS_DATASETS_EXPORT_DIR

  # Remote the lost+found folder in the shared home directory
  rm -rf $NFS_SHARED_HOME_EXPORT_DIR/*

  # Make the NFS exported file system readable and writeable by all hosts in
  # the system (/etc/exports is the access control list for NFS exported file
  # systems, see exports(5) for more information).
  echo "$NFS_SHARED_HOME_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports
  echo "$NFS_DATASETS_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports

  for dataset in $(ls $NFS_DATASETS_EXPORT_DIR)
  do
    echo "$NFS_DATASETS_EXPORT_DIR/$dataset *(rw,sync,no_root_squash)" >> /etc/exports
  done

  # Start the NFS service.
  /etc/init.d/nfs-kernel-server start

  # Give it a second to start-up
  sleep 5



  # Use the existence of this file as a flag for other servers to know that
  # NFS is finished with its setup.
  > /local/setup-nfs-done
fi

echo -e "\n===== WAITING FOR NFS SERVER TO COMPLETE SETUP ====="
# Wait until nfs is properly set up.
while [ "$(ssh -i $ssh_dir/id_rsa $USER_EXP@$HOSTNAME_JUMPHOST "[ -f /local/setup-nfs-done ] && echo 1 || echo 0")" != "1" ]; do
  sleep 1
done

# NFS clients setup (all servers are NFS clients).
echo -e "\n===== SETTING UP NFS CLIENT ====="
nfs_clan_ip=`grep "jumphost-core" /etc/hosts | cut -d$'\t' -f1`
my_clan_ip=`grep "$(hostname --short)-tor" /etc/hosts | cut -d$'\t' -f1`
mkdir $SHARED_HOME_DIR; mount -t nfs4 $nfs_clan_ip:$NFS_SHARED_HOME_EXPORT_DIR $SHARED_HOME_DIR
echo "$nfs_clan_ip:$NFS_SHARED_HOME_EXPORT_DIR $SHARED_HOME_DIR nfs4 rw,sync,hard,intr,addr=$my_clan_ip 0 0" >> /etc/fstab

mkdir $DATASETS_DIR; mount -t nfs4 $nfs_clan_ip:$NFS_DATASETS_EXPORT_DIR $DATASETS_DIR
echo "$nfs_clan_ip:$NFS_DATASETS_EXPORT_DIR $DATASETS_DIR nfs4 rw,sync,hard,intr,addr=$my_clan_ip 0 0" >> /etc/fstab


# jumphost specific configuration.
if [ $(hostname --short) == "$HOSTNAME_JUMPHOST" ]
then

  chown -R $USER_EXP: "$DATASETS_DIR"

#   echo -e "\n===== SETTING UP AUTOMATIC TMUX ON JUMPHOST ====="
#   # Make tmux start automatically when logging into rcmaster
#   cat >> /etc/profile.d/etc.sh <<EOM
#
# if [[ -z "\$TMUX" ]] && [ "\$SSH_CONNECTION" != "" ]
# then
#   tmux attach-session -t ssh_tmux || tmux new-session -s ssh_tmux
# fi
# EOM
fi

# Mark that setup has finished. This script is actually run again after a
# reboot, so we need to mark that we've already setup this machine and catch
# this flag after a reboot to prevent ourselves from re-running everything.
touch /local/setup_done

echo -e "\n===== SYSTEM SETUP COMPLETE ====="
