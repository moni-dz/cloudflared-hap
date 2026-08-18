#!/bin/sh

set -m

export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# /run may not exist in the container rootfs; iptables needs it for xtables.lock
mkdir -p /run

# Enable IP forwarding
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

# Prepare run dirs (OpenSSH privsep dir; no-op under dropbear)
if [ -x /usr/sbin/sshd ] && [ ! -d "/var/run/sshd" ]; then
  mkdir -p /var/run/sshd
fi

# Set root password
echo "root:${PASSWORD}" | chpasswd

# Install routes
OLDIFS="$IFS"
IFS=','
for s in $ADVERTISE_ROUTES; do
  ip route add "$s" via "${CONTAINER_GATEWAY}"
done
IFS="$OLDIFS"

# Execute startup script if it exists
if [ -n "${STARTUP_SCRIPT}" ] && [ -f "${STARTUP_SCRIPT}" ]; then
       sh "${STARTUP_SCRIPT}" || exit $?
fi

# Execute running script if it exists
if [ -n "${RUNNING_SCRIPT}" ] && [ -f "${RUNNING_SCRIPT}" ]; then
       sh "${RUNNING_SCRIPT}" || exit $?
fi

# Start Cloudflare Tunnel if a token is set
if [ -n "${TUNNEL_TOKEN}" ]; then
  cloudflared tunnel run --token "${TUNNEL_TOKEN}" &
fi

# Start SSH (OpenSSH on the Alpine stage, dropbear on the musl stage)
if [ -x /usr/sbin/dropbear ]; then
  exec /usr/sbin/dropbear -F -E -j -k -p 22
else
  exec /usr/sbin/sshd -D
fi
