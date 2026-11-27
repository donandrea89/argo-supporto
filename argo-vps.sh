#!/bin/bash
# Argo · il tuo VPS come «postino cieco» per gli ospiti fuori casa.
# Uso, come root su un VPS Ubuntu o Debian:  bash argo-vps.sh <codice-del-NAS>
# Il codice del NAS lo mostra l'app Argo (Impostazioni › Fuori casa › Con un mio VPS).
#
# Il VPS tiene un solo collegamento WireGuard con il NAS (10.67.0.1 <-> 10.67.0.2) e inoltra
# al NAS, così come arrivano, i pacchetti cifrati degli ospiti sulla porta UDP 51821.
# Le chiavi degli ospiti stanno solo sul NAS: il VPS non può leggere nulla.
# Alla fine stampa un codice ARGO-VPS1-… da incollare nell'app.
set -euo pipefail
test "$(id -u)" = 0 || { echo "Serve root: sudo bash $0 <codice-del-NAS>"; exit 1; }
NAS_PUB="${1:-}"
[[ "$NAS_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "Manca il codice del NAS (una chiave di 44 caratteri) o non è valido."; exit 1; }
command -v wg >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools iptables >/dev/null; }
W=/etc/wireguard; umask 077; mkdir -p $W
CONF=$W/argo.conf
[ -s $W/argo-vps.key ] || wg genkey > $W/argo-vps.key
VPS_PUB=$(wg pubkey < $W/argo-vps.key)
PUBIF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
VPS_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
test -n "$PUBIF" && test -n "$VPS_IP"
cat > $CONF <<CONF
[Interface]
PrivateKey = $(cat $W/argo-vps.key)
Address = 10.67.0.1/24
ListenPort = 51820
PostUp = sysctl -qw net.ipv4.ip_forward=1
PostUp = iptables -t nat -A PREROUTING -i $PUBIF -p udp --dport 51821 -j DNAT --to-destination 10.67.0.2:51821
PostUp = iptables -t nat -A POSTROUTING -o %i -p udp -d 10.67.0.2 --dport 51821 -j MASQUERADE
PostUp = iptables -I FORWARD 1 -i $PUBIF -o %i -d 10.67.0.2 -p udp --dport 51821 -j ACCEPT
PostUp = iptables -I FORWARD 2 -i %i -o $PUBIF -s 10.67.0.2 -p udp --sport 51821 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -I INPUT 1 -i %i -j DROP
PostDown = iptables -t nat -D PREROUTING -i $PUBIF -p udp --dport 51821 -j DNAT --to-destination 10.67.0.2:51821
PostDown = iptables -t nat -D POSTROUTING -o %i -p udp -d 10.67.0.2 --dport 51821 -j MASQUERADE
PostDown = iptables -D FORWARD -i $PUBIF -o %i -d 10.67.0.2 -p udp --dport 51821 -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o $PUBIF -s 10.67.0.2 -p udp --sport 51821 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D INPUT -i %i -j DROP

[Peer]
# NAS di casa con Argo
PublicKey = $NAS_PUB
AllowedIPs = 10.67.0.2/32
CONF
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then ufw allow 51820/udp >/dev/null; ufw allow 51821/udp >/dev/null; fi
systemctl enable -q wg-quick@argo
systemctl restart wg-quick@argo
sleep 2
wg show argo >/dev/null
CODE=$(printf '{"ip":"%s","pub":"%s"}' "$VPS_IP" "$VPS_PUB" | base64 -w0 | tr '+/' '-_' | tr -d '=')
echo
echo "Fatto. Copia questo codice e incollalo nell'app Argo:"
echo
echo "ARGO-VPS1-$CODE"
echo
echo "Se il fornitore del VPS ha un firewall nel suo pannello, apri le porte UDP 51820 e 51821."
