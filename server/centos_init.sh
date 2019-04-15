#!/bin/bash

# This script only works for CentOS

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this initial optimization script"
	exit 1
fi

Update_OS()
{
    yum clean all
	yum makecache fast
	yum update -y
	yum install wget git unzip -y
}


Disable_Selinux()
{
    if [ -s /etc/selinux/config ]
	then
	  sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
	fi

}


Optimize_Resolv()
{
    if [ -s /etc/resolv.conf ]
	then
	  echo '8.8.8.8' > /etc/resolv.conf
	  echo '8.8.4.4' >> /etc/resolv.conf
	  echo '4.2.2.1' >> /etc/resolv.conf
	  echo '4.2.2.2' >> /etc/resolv.conf
	  echo '4.2.2.3' >> /etc/resolv.conf
	  echo '4.2.2.4' >> /etc/resolv.conf
	  echo '4.2.2.5' >> /etc/resolv.conf
	  echo '4.2.2.6' >> /etc/resolv.conf
	fi
}

# set EST5 timezone
Set_Timezone()
{
    echo "Setting timezone..."
    rm -rf /etc/localtime
    cp /usr/share/zoneinfo/America/New_York /etc/localtime
}

Root_Aliases()
{
   read -p "Please enter the email address you wanna setup for root:" rootemail
   echo "root:$rootemail" >> /etc/aliases
   newaliases
}


Set_SSHPort()
{
    read -p "Please enter new SSH ports:" sshport
	sed -i "s/^Port 22/Port $sshport/g" /etc/ssh/sshd_config
	sed -i "s/^#Port 22/Port $sshport/g" /etc/ssh/sshd_config
	systemctl restart sshd
}

Pre_CSF()
{
    echo "This is a centos server,install necessary packages for CSF:"
    yum install perl-libwww-perl.noarch perl-LWP-Protocol-https.noarc bind-utils perl-Crypt-SSLeay perl-Net-SSLeay perl-LWP-Protocol-https unzip bind-utils -y
}

Install_CSF()
{
    if [ -x /usr/sbin/csf ]
	then
	  echo "You've already have CSF installed"
	else
	  echo "CSF installation starts:"
	  cd ~
	  rm -rf csf.tgz
	  wget https://download.configserver.com/csf.tgz
      tar -xzf csf.tgz
      cd csf
      sh install.sh
	  cd ~
	  echo "CSF installation completed!"
	fi
}

Init_CSF()
{

    echo "Please enter the ports you want to open for system, for example 25,53,80,443"
	read CSFPorts
    if [ -s $CSFL ]
	then 
     # change ports
      sed -i "s/^TCP_IN =.*/TCP_IN = \"$CSFPorts\"/g" $CSFL	 
	 # disable email alerts
	  sed -i 's/^TESTING = "1"$/TESTING = "0"/g' $CSFL
	  sed -i 's/^RESTRICT_SYSLOG = "0"$/RESTRICT_SYSLOG = "3"/g' $CSFL
	  sed -i 's/^ICMP_IN_RATE = "1\/s"$/ICMP_IN_RATE = "0"/g' $CSFL
	  sed -i 's/^LF_PERMBLOCK_ALERT = "1"$/LF_PERMBLOCK_ALERT = "0"/g' $CSFL
	  sed -i 's/^LF_NETBLOCK_ALERT = "1"$/LF_NETBLOCK_ALERT = "0"/g' $CSFL
	  sed -i 's/^LF_EMAIL_ALERT = "1"$/LF_EMAIL_ALERT = "0"/g' $CSFL
	  sed -i 's/^LF_CONSOLE_EMAIL_ALERT = "1"$/LF_CONSOLE_EMAIL_ALERT = "0"/g' $CSFL
	  sed -i 's/^LF_DISTFTP_ALERT = "1"$/LF_DISTFTP_ALERT = "0"/g' $CSFL
	  sed -i 's/^LF_DISTSMTP_ALERT = "1"$/LF_DISTSMTP_ALERT = "0"/g' $CSFL
	  sed -i 's/^LT_EMAIL_ALERT = "1"$/LT_EMAIL_ALERT = "0"/g' $CSFL
	  sed -i 's/^CT_EMAIL_ALERT = "1"$/CT_EMAIL_ALERT = "0"/g' $CSFL
	  sed -i 's/^PT_LIMIT = "60"$/PT_LIMIT = "0"/g' $CSFL
	  sed -i 's/^PT_USERPROC = "10"$/PT_USERPROC = "0"/g' $CSFL
	  sed -i 's/^PT_USERMEM = "512"$/PT_USERMEM = "0"/g' $CSFL
	  sed -i 's/^PT_USERRSS = "256"$/PT_USERRSS = "0"/g' $CSFL
	  sed -i 's/^PT_USERTIME = "1800"$/PT_USERTIME = "0"/g' $CSFL
	  sed -i 's/^PT_USERKILL_ALERT = "1"$/PT_USERKILL_ALERT = "0"/g' $CSFL
	  sed -i 's/^PT_LOAD = "30"$/PT_LOAD = "0"/g' $CSFL
	  sed -i 's/^PS_EMAIL_ALERT = "1"$/PS_EMAIL_ALERT = "0"/g' $CSFL	  	  	  
	fi
}

Reload_CSF()
{
    echo "CSF reloading starts:"
    csf -r
	echo "CSF reloading completed!"
}

Setup_CSF()
{
    Pre_CSF
	Install_CSF
	Init_CSF
	Reload_CSF
}


echo "Simple Server Auto Optimization Starting"

echo "Start OS updates"
Update_OS

echo "Setup EST timezone"
Set_Timezone

echo "Disable selinux"
Disable_Selinux

echo "Add new resolv"
Optimize_Resolv

echo "Setup root aliases"
Root_Aliases

echo "Setup SSH port"
Set_SSHPort

echo "Setup CSF"
Setup_CSF

echo "Simple Server Auto Optimization Completed"
