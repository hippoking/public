#!/bin/bash

# CSF config location
CSFL="/etc/csf/csf.conf"

Pre_CSF()
{
    apt-get update
	apt-get upgrade -y
	apt-get install perl unzip host exim4 -y
}

Pre2_CSF()
{
    if grep -Eqi "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
#        DISTRO='CentOS'
		echo "This is a centos server,install necessary packages for CSF:"
		yum install perl-libwww-perl.noarch perl-LWP-Protocol-https.noarc bind-utils perl-Crypt-SSLeay perl-Net-SSLeay perl-LWP-Protocol-https unzip bind-utils
    elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
#        DISTRO='Debian'
		echo "This is a debian based server, install necessary packages for CSF:"
		apt-get install libwww-perl
    elif grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
#        DISTRO='Debian'
		echo "This is a debian based server, install necessary packages for CSF:"
		apt-get install libwww-perl -y
    else
#        DISTRO='unknow'
		echo "We can't detect dist for this server"
    fi
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


Disable_Selinux()
{
    if [ -s /etc/selinux/config ]
	then
	  sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
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


Disable_Selinux
Pre_CSF
Pre2_CSF
Install_CSF
Init_CSF
Reload_CSF

echo "CSF has been installed and initiated !!!"
