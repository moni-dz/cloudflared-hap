#!/bin/sh

set -m

export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /run

echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

if [ -x /usr/sbin/sshd ] && [ ! -d "/var/run/sshd" ]; then
  mkdir -p /var/run/sshd
fi

echo "root:${PASSWORD}" | chpasswd

OLDIFS="$IFS"
IFS=','
for s in $ADVERTISE_ROUTES; do
  ip route add "$s" via "${CONTAINER_GATEWAY}"
done
IFS="$OLDIFS"

if [ -n "${STARTUP_SCRIPT}" ] && [ -f "${STARTUP_SCRIPT}" ]; then
       sh "${STARTUP_SCRIPT}" || exit $?
fi

if [ -n "${TUNNEL_TOKEN}" ]; then
  cloudflared tunnel --no-autoupdate run --token "${TUNNEL_TOKEN}" &
fi

if [ -x /usr/sbin/dropbear ]; then
  exec /usr/sbin/dropbear -F -E -j -k -p 22
else
  exec /usr/sbin/sshd -D
fi
