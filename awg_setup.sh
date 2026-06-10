#!/bin/sh

config_file="amnezia_for_awg.conf"
interface_config="awg0.conf"
if [ ! -f "$config_file" ]; then
    echo "File $config_file not found"
    exit 1
fi

address=$(awk -F' = ' '/^Address/ {print $2}' "$config_file")
dns=$(awk -F' = ' '/^DNS/ {print $2}' "$config_file")
dns=$(echo $dns | cut -d',' -f1)
echo "AmneziaWG client address: $address"
echo "DNS: $dns"

if [ -f "$interface_config" ]; then
    echo "$interface_config already exists"
else
    awk '!/^Address/ && !/^DNS/' "$config_file" > "$interface_config"
    echo "$interface_config created"
fi

# Downloading AmneziaWG binaries if needed
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
    echo "AmneziaWG not found. Downloading..."    
    curl -L -o awg.tar.gz https://github.com/alexandershalin/amneziawg-be7000/raw/main/awg.tar.gz
    curl -L -o clear_firewall_settings.sh https://github.com/alexandershalin/amneziawg-be7000/raw/main/clear_firewall_settings.sh
    tar -xzvf /data/usr/app/awg/awg.tar.gz
    chmod +x /data/usr/app/awg/amneziawg-go
    chmod +x /data/usr/app/awg/awg 
    chmod +x /data/usr/app/awg/clear_firewall_settings.sh
    rm /data/usr/app/awg/awg.tar.gz    
    echo "Archive downloaded and unpacked. Setting up awg0 interface"
else
    echo "AmneziaWG binaries exist, setting up awg0 interface"
fi


# Set up AmneziaWG interface
/data/usr/app/awg/amneziawg-go awg0
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add $address dev awg0
ip l set up awg0

# /data/usr/app/awg/awg - check connection

# Delete existing route for guest network 
ip route del 192.168.33.0/24 dev br-guest

# Add new guest network routes
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200

# Set up firewall for DNS requests
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT

# Common rules for traffic
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT

# Set up NAT for DNS requests from guest network
iptables -t nat -A PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53
iptables -t nat -A PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53

# Set up NAT
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# Set up firewall AmneziaWG zone
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='ACCEPT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='ACCEPT'
if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='guest'
    uci set firewall.@forwarding[-1].dest='awg'
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='awg'
    uci set firewall.@forwarding[-1].dest='guest'
fi
uci commit firewall

# Clear routes cache and restart firewall
echo "Restarting firewall..."
ip route flush cache
/etc/init.d/firewall reload

# Turn IP-forwarding on
echo 1 > /proc/sys/net/ipv4/ip_forward
