#!/bin/sh
# /opt/ragflow/init/fix-gai.sh
if [ ! -f /etc/gai.conf ]; then
  echo "precedence ::ffff:0:0/96 100" > /etc/gai.conf
  echo "label ::1/128 0" >> /etc/gai.conf
  echo "label ::/0 1" >> /etc/gai.conf
  echo "[INIT] Applied gai.conf to prefer IPv4"
fi
