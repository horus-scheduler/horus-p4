#!/bin/bash

usage() {
    cat <<EOF
Usage:

    sudo $0 <resolution>

    <resolution> is specified as WIDTHxHEIGHT, e.g. 1920x1080
    This script must be run as root (e.g. via sudo)
EOF
}

check_params() {
    if [ -z $1 ]; then
        usage
        exit 1
    fi

    if [[ ! $1 =~ ^[0-9][0-9]*x[0-9][0-9]*$ ]]; then
        usage
        exit 1
    fi
    
    if [ $UID -ne 0 ]; then
        usage
        exit 1
    fi
}

update_service_file() {
    cat <<EOF > /etc/systemd/system/vncserver@.service
[Unit]
Description=Start VNC server at startup
After=syslog.target network.target

[Service]
Type=forking
User=$SUDO_USER
Group=$SUDO_USER
WorkingDirectory=/home/$SUDO_USER
PIDFile=/home/$SUDO_USER/.vnc/%H:%i.pid
ExecStartPre=/bin/sh -c '/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || :'
ExecStartPre=-/bin/rm -f /tmp/.X11-unix/X%i /tmp/.X%i-lock
ExecStart=/usr/bin/vncserver -depth 24 -geometry $1 :%i
ExecStop=/usr/bin/vncserver -kill %i

Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

reload_service() {
    systemctl daemon-reload
    systemctl restart vncserver@1.service
    systemctl restart tomcat8.service
}

check_params $*
cat <<EOF

ATTENTION: You requested to change desktop resolution to $1
           The Xvnc server will be restarted and all applications will close.
           Make sure all your work is saved. 
           You will briefly lose the connection to the proxy server (Guacamole).
           Wait ten seconds or so and reconnect again.

EOF

read -p "Enter YES to proceed: " proceed
proceed=`echo $proceed | tr a-z A-Z`
if [[ "$proceed" == "YES" ]]; then
    reload_service &
    update_service_file $*
else
    echo "Resolution change cancelled"
fi
