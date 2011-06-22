#!/bin/bash
## Define exit function used to shutdown EC2 Instance
function quit {
    echo "Initiate EC2 Instance Shutdown"
    if [ -n "$tunnel" ] # Check if a tunnel has been made or not
    then
	echo "Closing SSH Tunnel"
	ssh -i $ssh_key root@$EC2_HOST "touch /tmp/stop"
    fi	
    export EC2_INSTANCE=`$EC2_HOME/bin/ec2-describe-instances | grep INSTANCE | grep -v terminated | tr '\t' '\n' | grep '^i-'`
    export EC2_IP=`$EC2_HOME/bin/ec2-describe-addresses | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}'`
    echo "Terminating Instance"
    $EC2_HOME/bin/ec2-terminate-instances $EC2_INSTANCE > /dev/null
    if [ -n "$EC2_IP" ] # Check if server has an IP address assigned
    then
	echo "Releasing IP address"
	$EC2_HOME/bin/ec2-release-address $EC2_IP > /dev/null
    fi
    echo "Server is now shut down, bye bye!"
    exit
}

## Create an ami-23b6534a proxy instance
echo "Create an Amazon EC2 Server Instance"
export EC2_INSTANCE=`$EC2_HOME/bin/ec2-run-instances ami-23b6534a -k gsg-keypair -t c1.medium | tr '\t' '\n' | grep '^i-'`
echo "Wait for instance to load before preceding"

## Loop which waits for instance to load fully
x=0
ec2running=`$EC2_HOME/bin/ec2-describe-instances | grep INSTANCE | tr '\t' '\n' | grep running`
until [ -n "$ec2running" ] # (Until unempty string is returned)
do
    sleep 2
    ec2running=`$EC2_HOME/bin/ec2-describe-instances | grep INSTANCE | tr '\t' '\n' | grep running`
    x=$(($x+1))
    echo "Server not yet running, $x attempts"
    if [ "$x" -ge 10 ]
    then
	quit
    fi
done
echo "Instance running, proceed to aquire hostname"

## Retrieve Instance Hostname
echo "Retrieve Hostname"
export EC2_HOST=`$EC2_HOME/bin/ec2-describe-instances | grep $EC2_INSTANCE | tr '\t' '\n' | grep amazonaws.com`

# Get IP Address
export localip=`curl -s checkip.dyndns.com | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"`

#  Build customized httpd.conf file to be used
echo "Building httpd.conf file"
cat $autoproxy/httpd.temp > /tmp/httpd.conf
echo "<IfModule mod_proxy.c>

ProxyRequests On

<Proxy *>
    Order deny,allow
    Deny from all
    Allow from $localip
</Proxy>

</IfModule>" >> /tmp/httpd.conf

### Use Rsync to put httpd.conf on remote instance and restart apache
echo "Sync httpd.conf to instance and restart apache"
rsync --delete --compress --stats --progress --include-from=$autoproxy/httpd_include -e "ssh -i $ssh_key" -avz /tmp/ root@$EC2_HOST:/etc/httpd/conf > /tmp/rsync_log.txt
ssh -i $ssh_key root@$EC2_HOST "sudo /etc/init.d/httpd restart"

## Do we want to assign an IP address?
read -p "Do you want to assign an IP address to your proxy server (y/n)?"
if [ "$REPLY" == "y" ] 
then
    # Allocate Elastic IP
    $EC2_HOME/bin/ec2-allocate-address > /dev/null
    sleep 5
    
    # Find Remote IP Address
    export EC2_IP=`$EC2_HOME/bin/ec2-describe-addresses | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}'`
    
    # Associate Elastic IP with Instance and print out IP
    $EC2_HOME/bin/ec2-associate-address -i $EC2_INSTANCE $EC2_IP > /dev/null
    echo "Your proxy server IP address is $EC2_IP"
fi

## Do we want to create an SSH Tunnel?
read -p "Do you want to create an SSH tunnel to the proxy server (y/n)?"
if [ "$REPLY" == "y" ] 
then
    # Make Tunnel, only terminate when file /tmp/stop is created
    export tunnel=yes
    echo "Creating HTTP Tunnel to EC2 Instance in the background"
    ssh -f -i $ssh_key -D 9999 root@$EC2_HOST "while [ ! -f /tmp/stop ]; do echo > /dev/null; done" &
fi

# Proxy is now running, wait for user input to initiate shutdown
until [ "$keypress" = "stop" ]
do
    echo "Proxy is now running, to shutdown proxy type \"stop\" in the terminal"
    read -n 4 keypress
done
sleep 1
# Initiate shutdown of EC2 instance 
echo -e "\n Now shutting down EC2 instance"
quit
exit


