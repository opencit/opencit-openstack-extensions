#!/bin/bash

INSTALL_DIR=${INSTALL_DIR:-"../"}
OPENSTACK_DIR=Openstack
PATCH_DIR=patch

COMPUTE_COMPONENTS="python-nova"
CONTROLLER_COMPONENTS="python-nova python-novaclient openstack-dashboard"

function getOpenstackVersion()
{
	componentName=$1
	if [ $componentName == "python-novaclient" ] ; then
		version=`dpkg -l python-novaclient | tail -1 | awk '{print $3}' | cut -c-8`
	else
		if [ -x /usr/bin/nova-manage ] ; then
			version=`/usr/bin/nova-manage --version 2>&1`
		else
		   echo "/usr/bin/nova-manage does not exist"
		   echo "Kindly install nova compute first and then rerun this script"
		   exit
		fi
	fi
	
	echo $version	

}

function applyPatches()
{
        component=$1
        version=$2
        echo "Applying patch for $component and $version"
	if [ -d $INSTALL_DIR/$OPENSTACK_DIR/$PATCH_DIR/$component/$version ]
	then
	        cd $INSTALL_DIR/$OPENSTACK_DIR/$PATCH_DIR/$component/$version
	        listOfFiles=`find . -type f`
        	for file in $listOfFiles
	        do
        	        target=`echo $file | cut -c2-`
			echo "Patching file : $target"
	                mv $target $target.mh.bak
        	        cp $file $target
	        done
		cd -
	else
		echo "ERROR : Could not find the patch for $component and $version"
		echo "Patches are supported only for the following versions"
		echo `ls $INSTALL_DIR/$OPENSTACK_DIR/$PATCH_DIR/$component`
	fi
}

function patchOpenstackComputePkgs()
{
        for component in $COMPUTE_COMPONENTS ; do
                ver=$(getOpenstackVersion $component)
                applyPatches $component $ver
        done

	find /usr/lib/python2.7/dist-packages/nova -name "*.pyc" -delete

        # Sanity for compute
#        chmod +x /usr/local/bin/mhagent
#
#        chown nova:nova /usr/local/bin/mhagent
#        rm -f /var/log/mhagent.log
#        touch /var/log/mhagent.log
#        chown nova:nova  /var/log/mhagent.log
        rm /var/lib/nova/instances/_base/*

	echo "Syncing nova database"
	su -s /bin/sh -c "nova-manage db sync" nova

	service nova-compute restart
	if [ ! -x  /usr/local/bin/mhagent ]
	then
		echo "WARN : Could not find mhagent, kindly install the same"
	fi

}

function patchOpenStackControllerPkgs()
{
        for component in $COMPUTE_COMPONENTS ; do
                ver=$(getOpenstackVersion $component)
                applyPatches $component $ver
        done


	find /usr/share/openstack-dashboard/ -name "*.pyc" -delete
	find /usr/lib/python2.7/dist-packages/novaclient -name "*.pyc" -delete
	find /usr/lib/python2.7/dist-packages/nova -name "*.pyc" -delete

	echo "Syncing nova database"	
	su -s /bin/sh -c "nova-manage db sync" nova

	service nova-compute restart
	service nova-api restart
	service nova-cert restart
	service nova-consoleauth restart
	service nova-scheduler restart
	service nova-conductor restart
	service nova-novncproxy restart
	service nova-network restart

}

function usage()
{
	echo "Usage : $0 [--controller|--compute]"
}

if [ $# -ne 1 ] ; then 
 usage 
 exit
fi


if [ $1 == "--controller" ]; then
	patchOpenStackControllerPkgs
elif [ $1 == "--compute" ]; then
	patchOpenstackComputePkgs
else
	usage
fi

