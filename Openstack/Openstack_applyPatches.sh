#!/bin/bash

INSTALL_DIR=${INSTALL_DIR:-"../"}
OPENSTACK_DIR=Openstack
PATCH_DIR=patch

DIST_LOCATION=`/usr/bin/python -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())"`

COMPUTE_COMPONENTS="python-nova"
CONTROLLER_COMPONENTS="python-nova python-novaclient openstack-dashboard"

# This function returns either rhel, fedora or ubuntu
# TODO : This function can be moved out to some common file
function getFlavour()
{
        flavour=""
        grep -c -i ubuntu /etc/*-release > /dev/null
        if [ $? -eq 0 ] ; then
                flavour="ubuntu"
        fi
        grep -c -i "red hat" /etc/*-release > /dev/null
        if [ $? -eq 0 ] ; then
                flavour="rhel"
        fi
        grep -c -i fedora /etc/*-release > /dev/null
        if [ $? -eq 0 ] ; then
                flavour="fedora"
        fi
        grep -c -i suse /etc/*-release > /dev/null
        if [ $? -eq 0 ] ; then
                flavour="suse"
        fi
        if [ "$flavour" == "" ] ; then
                echo "Unsupported linux flavor, Supported versions are ubuntu, rhel, fedora"
                exit
        else
                echo $flavour
        fi
}


function getOpenstackVersion()
{
	componentName=$1
	if [ $componentName == "python-novaclient" ] ; then
		if [ "$FLAVOUR" == "ubuntu" ] ; then
			version=`dpkg -l python-novaclient | tail -1 | awk '{print $3}' | cut -c-8 | awk -F ":" '{print $2}'`
		elif [ "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "fedora" ] ; then
			version=`rpm -qi python-novaclient | grep -i Version | awk  -F ":" '{print $2}'`
		elif [ "$FLAVOUR" == "suse" ] ; then
			version=`zypper info python-novaclient | grep -i version | awk  -F ":" '{print $2}' | awk -F "-" '{print $1}'`
		else
			echo "Unsupported linux flavour : $FLAVOUR found for patching, exiting"
			exit
		fi
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

function revertPatches()
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
                        # This is an anomaly and might go away with later 
                        # Openstack versions anomaly is openstack-dashboard does not lie
                        # in standard dist packages
                        if [ $component == "openstack-dashboard" ] ; then
                                target=`echo $file | cut -c2-`  
                        else
                                target=`echo $DIST_LOCATION/$file`
                        fi
			if [ -e "$target" ] ; then
	                        echo "Reverting file : $target"
        	                mv $target.mh.bak $target
			fi
                done
                cd -
        else
                echo "ERROR : Could not find the revert for $component and $version"
                echo "Patches are supported only for the following versions"
                echo `ls $INSTALL_DIR/$OPENSTACK_DIR/$PATCH_DIR/$component`
        fi

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
			# This is an anomaly and might go away with later 
			# Openstack versions anomaly is openstack-dashboard does not lie
			# in standard dist packages
	                if [ $component == "openstack-dashboard" ] ; then
				target=`echo $file | cut -c2-`	
        	        else
				target=`echo $DIST_LOCATION/$file`
	                fi
			targetMd5=`md5sum $target | awk '{print $1}'`
			sourceMd5=`md5sum $file | awk '{print $1}'`
			if [ $targetMd5 == $sourceMd5 ] ; then
				echo "$file md5sum matched, skipping patch"
			else
				echo "Patching file : $target"
		                mv $target $target.mh.bak
        		        cp $file $target
			fi
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
                if [ $REVERT == "true" ] ; then
			revertPatches $component $ver
                else
			applyPatches $component $ver
                fi
        done

	find $DIST_LOCATION/nova -name "*.pyc" -delete

        # Sanity for compute
#        chmod +x /usr/local/bin/mhagent
#
#        chown nova:nova /usr/local/bin/mhagent
#        rm -f /var/log/mhagent.log
#        touch /var/log/mhagent.log
#        chown nova:nova  /var/log/mhagent.log
        rm /var/lib/nova/instances/_base/*
	if [ -d /var/log/nova ] ; then
                chown -R nova:nova /var/log/nova
        fi
	echo "Syncing nova database"
	su -s /bin/sh -c "nova-manage db sync" nova

	if [ "$FLAVOUR" == "ubuntu" ] ; then
		service nova-compute restart
	elif [ "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "fedora" -o "$FLAVOUR" == "suse" ] ; then
		service openstack-nova-compute restart
	fi

	if [ ! -x  /usr/local/bin/policyagent ]
	then
		echo "WARN : Could not find policyagent, kindly install the same"
	fi

}

function patchOpenStackControllerPkgs()
{
        for component in $CONTROLLER_COMPONENTS ; do
                ver=$(getOpenstackVersion $component)
		if [ $REVERT == "true" ] ; then
	                revertPatches $component $ver
		else
			applyPatches $component $ver
		fi
        done


	find /usr/share/openstack-dashboard/ -name "*.pyc" -delete
	find $DIST_LOCATION/novaclient -name "*.pyc" -delete
	find $DIST_LOCATION/nova -name "*.pyc" -delete

	echo "Syncing nova database"
	if [ -d /var/log/nova ]	; then
		chown -R nova:nova /var/log/nova
	fi
	su -s /bin/sh -c "nova-manage db sync" nova

	if [ "$FLAVOUR" == "ubuntu" ] ; then
		service nova-compute restart
		service nova-api restart
		service nova-cert restart
		service nova-consoleauth restart
		service nova-scheduler restart
		service nova-conductor restart
		service nova-novncproxy restart
		service nova-network restart
	elif [ "$FLAVOUR" == "fedora" -o "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "suse" ] ; then
		service openstack-nova-compute restart
                service openstack-nova-api restart
                service openstack-nova-cert restart
                service openstack-nova-consoleauth restart
                service openstack-nova-scheduler restart
                service openstack-nova-conductor restart
                service openstack-nova-novncproxy restart
                service openstack-nova-network restart
	fi

}

function usage()
{
	echo "Usage : $0 [--controller|--compute] [--revert]"
	echo " Note : Any option other than --revert will be ignored"
}

function validate()
{
	if [ "$DIST_LOCATION" == "" ]; then
		echo "Did not find python dist location over this machine, Pl. install Openstack and python ?"	
		echo "Exiting..."
		exit
	fi
	echo "Found python dist location at $DIST_LOCATION"
	echo "Do you wish to use the current dist-location ? (y/n)"
	read useCurrdist
	if [ "$useCurrdist" == "n" ] ; then
		echo "Please enter the python dist location you wish to use : "
		read $DIST_LOCATION
		if [ -d "$DIST_LOCATION" ] ; then 
			echo "Using $DIST_LOCATION as python dist-location"
			export $DIST_LOCATION
		else
			echo "Please enter a valid python dist-location"
			exit
		fi
	fi
	
}

if [ $# -ne 1 -a $# -ne 2 ] ; then 
 usage 
 exit
fi

FLAVOUR=`getFlavour`

if [ "$1" == "--revert" -o "$2" == "--revert" ]; then
	export REVERT="true"
else
	export REVERT="false"
fi

if [ $1 == "--controller" ]; then
	validate
	patchOpenStackControllerPkgs
elif [ $1 == "--compute" ]; then
	validate
	patchOpenstackComputePkgs
else
	usage
fi

