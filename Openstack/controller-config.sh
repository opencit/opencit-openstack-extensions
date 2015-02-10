#!/bin/bash
Current_Dir=$(pwd)
usage()
{
   echo "Usage: $0 <IP_Address_of_Controller>"
   exit 1
}

function set_keyvaluepair(){
	TARGET_KEY=$1
	REPLACEMENT_VALUE=$2
	CONFIG_FILE=$3
	sed  -i "s|\($TARGET_KEY *= *\).*|\1$REPLACEMENT_VALUE|" $CONFIG_FILE
}

function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# call usage() function if IP not supplied
[[ $# -eq 0 ]] && usage

IP_Address=$1

if ( ! valid_ip "$IP_Address" );
then
   echo "Not a valid IP"
   exit 1
fi

echo "Please enter the root password for this server: "
stty -echo
read PASSWD
stty echo


Admin_Token=$(openssl rand -hex 10)

echo "Restarting mysql service"
sleep 1
service mysql restart

echo "Changing RabbitMQ password ....."
sleep 1
rabbitmqctl change_password guest $PASSWD

function KeystoneDBSetup()
{
   mysql --user=root --password=$PASSWD < $Current_Dir/db_files/keystone_db.sql	
}

function GlanceDBSetup()
{
   mysql --user=root --password=$PASSWD < $Current_Dir/db_files/glance_db.sql
}

function NovaDBSetup()
{
   mysql --user=root --password=$PASSWD < $Current_Dir/db_files/nova_db.sql
}

function ModifyKeystoneConf()
{
   #Copy keystone.conf
   mv /etc/keystone/keystone.conf /etc/keystone/keystone.conf.bak
   cp $Current_Dir/conf_files/keystone/keystone.conf /etc/keystone/keystone.conf

   set_keyvaluepair "connection" "mysql://keystone:$PASSWD@$IP_Address/keystone" /etc/keystone/keystone.conf

   #Remove sqlite database
   rm /var/lib/keystone/keystone.db 2> /dev/null

   #Create Database for Identity Service
   KeystoneDBSetup
   
   echo -e "Creating the database tables for the Identity Service ....."
   sleep 1
   keystone-manage db_sync
   set_keyvaluepair "admin_token" "$Admin_Token" /etc/keystone/keystone.conf

   service keystone restart

}

function DefineKeystoneUsersAndAPIEndpoint()
{
   export OS_SERVICE_TOKEN=$Admin_Token
   export OS_SERVICE_ENDPOINT=http://$IP_Address:35357/v2.0
   echo "Creating Tenants - Admin and Service ....."
   sleep 1
   keystone tenant-create --name=admin --description="Admin Tenant"
   sleep 1
   keystone tenant-create --name=service --description="Service Tenant"
   sleep 1
   echo "Creating User - keystone ....."
   sleep 1
   keystone user-create --name=admin --pass=$PASSWD
   echo "Creating Role - admin ....."
   sleep 1
   keystone role-create --name=admin
   echo "Adding role ....."
   sleep 1   
   keystone user-role-add --user=admin --tenant=admin --role=admin
   echo "Creating Service and API Endpoint for keystone Identity Service ....."
   sleep 1
   ServiceID=$(keystone service-create --name=keystone --type=identity --description="Keystone Identity Service" | grep "id " | awk -F '|' '{ print $3 }' | tr -d ' ')
   echo "----------  Service ID : $ServiceID -----------"
   sleep 1
   keystone endpoint-create \
--service-id=$ServiceID \
--publicurl=http://$IP_Address:5000/v2.0 \
--internalurl=http://$IP_Address:5000/v2.0 \
--adminurl=http://$IP_Address:35357/v2.0   

   sleep 1
   echo "Restarting Keystone Service ....."
   sleep 1
   service keystone restart
}

function CreateKeystonercFile() {
   rm -f /root/keystonerc
   touch /root/keystonerc
   echo "export OS_USERNAME=admin" >> /root/keystonerc
   echo "export OS_PASSWORD=$PASSWD" >> /root/keystonerc
   echo "export OS_TENANT_NAME=admin" >> /root/keystonerc
   echo "export OS_AUTH_URL=http://$IP_Address:35357/v2.0" >> /root/keystonerc
}

function ModifyGlanceConf()
{
   #Copy keystone.conf
   mv /etc/glance/glance-api.conf /etc/glance/glance-api.conf.bak
   mv /etc/glance/glance-registry.conf /etc/glance/glance-registry.conf.bak
   cp $Current_Dir/conf_files/glance/glance-api.conf /etc/glance/glance-api.conf
   cp $Current_Dir/conf_files/glance/glance-registry.conf /etc/glance/glance-registry.conf

   set_keyvaluepair "sql_connection" "mysql://glance:$PASSWD@$IP_Address/glance" /etc/glance/glance-api.conf
   set_keyvaluepair "sql_connection" "mysql://glance:$PASSWD@$IP_Address/glance" /etc/glance/glance-registry.conf
   set_keyvaluepair "auth_host" "$IP_Address" /etc/glance/glance-api.conf
   set_keyvaluepair "auth_host" "$IP_Address" /etc/glance/glance-registry.conf

   mv /etc/glance/glance-api-paste.ini /etc/glance/glance-api-paste.ini.bak
   mv /etc/glance/glance-registry-paste.ini /etc/glance/glance-registry-paste.ini.bak
   cp $Current_Dir/conf_files/glance/glance-api-paste.ini /etc/glance/glance-api-paste.ini
   cp $Current_Dir/conf_files/glance/glance-registry-paste.ini /etc/glance/glance-registry-paste.ini
   
   set_keyvaluepair "auth_host" "$IP_Address" /etc/glance/glance-api-paste.ini
   set_keyvaluepair "auth_host" "$IP_Address" /etc/glance/glance-registry-paste.ini

   chown glance:glance /etc/glance/glance-api.conf /etc/glance/glance-registry.conf /etc/glance/glance-api-paste.ini /etc/glance/glance-registry-paste.ini

   #Remove sqlite database
   rm /var/lib/glance/glance.sqlite 2> /dev/null

   #Create Database for Identity Service
   GlanceDBSetup

   echo -e "Creating the database tables for the Image Service ....."
   sleep 1
   glance-manage db_sync

}

function DefineGlanceUsersAndAPIEndpoint() {
   export OS_SERVICE_TOKEN=$Admin_Token
   export OS_SERVICE_ENDPOINT=http://$IP_Address:35357/v2.0
   sleep 1
   echo "Creating User - glance ....."
   sleep 1
   keystone user-create --name=glance --pass=$PASSWD
   echo "Adding Role ....."
   sleep 1
   keystone user-role-add --user=glance --tenant=service --role=admin
   echo "Creating Service and API Endpoint for keystone Identity Service ....."
   sleep 1
   ServiceID=$(keystone service-create --name=glance --type=image --description="Glance Image Service" | grep "id " | awk -F '|' '{ print $3 }' | tr -d ' ')
   echo "----------  Service ID : $ServiceID -----------"
   sleep 1
   keystone endpoint-create \
--service_id=$ServiceID \
--publicurl=http://$IP_Address:9292 \
--internalurl=http://$IP_Address:9292 \
--adminurl=http://$IP_Address:9292
   sleep 1
   echo "Restarting Glance Services ....."
   sleep 1
   service glance-registry restart
   service glance-api restart
}

function ModifyNovaConf()
{
   #Copy keystone.conf
   mv /etc/nova/nova.conf /etc/nova/nova.conf.bak
   cp $Current_Dir/conf_files/nova/nova.conf /etc/nova/nova.conf
   
   set_keyvaluepair "connection" "mysql://nova:$PASSWD@$IP_Address/nova" /etc/nova/nova.conf
   set_keyvaluepair "auth_host" "$IP_Address" /etc/nova/nova.conf
   set_keyvaluepair "rabbit_host" "$IP_Address" /etc/nova/nova.conf
   set_keyvaluepair "my_ip" "$IP_Address" /etc/nova/nova.conf
   set_keyvaluepair "vncserver_listen" "$IP_Address" /etc/nova/nova.conf
   set_keyvaluepair "vncserver_proxyclient_address" "$IP_Address" /etc/nova/nova.conf

   mv /etc/nova/api-paste.ini /etc/nova/api-paste.ini.bak
   cp $Current_Dir/conf_files/nova/api-paste.ini /etc/nova/api-paste.ini

   set_keyvaluepair "auth_host" "$IP_Address" /etc/nova/api-paste.ini

   chown nova:nova /etc/nova/nova.conf /etc/nova/api-paste.ini

   #Remove sqlite database
   rm /var/lib/nova/nova.sqlite 2> /dev/null

   #Create Database for Identity Service
   NovaDBSetup

   echo -e "Creating the database tables for the Compute Service ....."
   sleep 1
   nova-manage db sync

}

function DefineNovaUsersAndAPIEndpoint()
{
   export OS_SERVICE_TOKEN=$Admin_Token
   export OS_SERVICE_ENDPOINT=http://$IP_Address:35357/v2.0
   sleep 1
   echo "Creating User - nova ....."
   sleep 1
   keystone user-create --name=nova --pass=$PASSWD 
   echo "Adding Role ....."
   sleep 1
   keystone user-role-add --user=nova --tenant=service --role=admin
   echo "Creating Service and API Endpoint for keystone Identity Service ....."
   sleep 1
   ServiceID=$(keystone service-create --name=nova --type=compute --description="Nova Compute service" | grep "id " | awk -F '|' '{ print $3 }' | tr -d ' ')
   echo "----------  Service ID : $ServiceID -----------"
   sleep 1
   keystone endpoint-create \
--service-id=$ServiceID \
--publicurl=http://$IP_Address:8774/v2/%\(tenant_id\)s \
--internalurl=http://$IP_Address:8774/v2/%\(tenant_id\)s \
--adminurl=http://$IP_Address:8774/v2/%\(tenant_id\)s
   sleep 1
   echo "Restarting All(Keystone, Glance, Nova, apache2 & memcached) Services ....."
   sleep 1
   RestartAllServices
}

function CreateNovaServiceFile()
{
   touch /root/services.sh
   echo "att=\$1" >> /root/services.sh
   echo "service keystone \$att" >> /root/services.sh
   echo "service glance-registry \$att" >> /root/services.sh
   echo "service glance-api \$att" >> /root/services.sh
   echo "service nova-api \$att" >> /root/services.sh
   echo "service nova-cert \$att" >> /root/services.sh
   echo "service nova-consoleauth \$att" >> /root/services.sh
   echo "service nova-scheduler \$att" >> /root/services.sh
   echo "service nova-conductor \$att" >> /root/services.sh
   echo "service nova-novncproxy \$att" >> /root/services.sh
   echo "service apache2 \$att" >> /root/services.sh
   echo "service memcached \$att" >> /root/services.sh
}

function ApplyPatchedFiles()
{
   cd $Current_Dir/patched_files
   rm -f /tmp/patched_files
   touch /tmp/patched_files
   find . -type f > /tmp/patched_files
   for i in `cat /tmp/patched_files`;do mv ${i:1} ${i:1}.bak;done
   for i in `cat /tmp/patched_files`;do cp $i ${i:1};done
   rm -f /usr/lib/python2.7/dist-packages/nova/db/sqlalchemy/migrate_repo/versions/217_add_is_measured_to_instance.py
   ln -s /usr/share/pyshared/nova/db/sqlalchemy/migrate_repo/versions/217_add_is_measured_to_instance.py /usr/lib/python2.7/dist-packages/nova/db/sqlalchemy/migrate_repo/versions/217_add_is_measured_to_instance.py
   nova-manage db sync
}

function RestartAllServices() 
{
   /root/services.sh restart
}

function CheckStatusOfAllServices()
{
   /root/services.sh status
}

echo "----------------------------------------------"
echo "----------------------------------------------"
echo "Configuring Keystone ....."
sleep 3
ModifyKeystoneConf
echo "Defining Users and API endpoints for Keystone ....."
sleep 1
DefineKeystoneUsersAndAPIEndpoint
echo "Creating /root/keystonerc File ....."
sleep 1
CreateKeystonercFile
echo "----------------------------------------------"
echo "----------------------------------------------"
echo "Configuring Glance ....."
sleep 1
ModifyGlanceConf
echo "Defining Users and API endpoints for Glance ....."
sleep 1
DefineGlanceUsersAndAPIEndpoint
echo "----------------------------------------------"
echo "----------------------------------------------"
echo "Configuring Nova ....."
sleep 3
ModifyNovaConf
sleep 1
if [ ! -f /root/services.sh ]
then
   echo "Creating /root/services.sh File ....."
   sleep 1
   CreateNovaServiceFile
   chmod +x /root/services.sh
fi
echo "Defining Users and API endpoints for Nova ....."
sleep 1
DefineNovaUsersAndAPIEndpoint
sleep 1
echo "Applying the Patched Files ....."
sleep 1
ApplyPatchedFiles
echo "Applying Patched Files Done ....."
sleep 1
echo "Restarting All Services ....."
sleep 1
RestartAllServices
sleep 1
echo "Checking Status of All Services ....."
sleep 1
CheckStatusOfAllServices
