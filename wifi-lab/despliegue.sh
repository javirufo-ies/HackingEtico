#!/bin/bash

# ==============================================================================
# SCRIPT DE DESPLIEGUE DEFINITIVO Y REALISTA - LAB WI-FI (mac80211_hwsim)
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ejecuta este script como root (sudo)."
  exit 1
fi

LAB_DIR="/opt/wifi-lab"

echo "[+] 1. Limpiando entorno previo..."
pkill -9 hostapd 2>/dev/null || true
pkill -9 wpa_supplicant 2>/dev/null || true
pkill -9 nc 2>/dev/null || true
pkill -9 curl 2>/dev/null || true
pkill -9 ping 2>/dev/null || true
pkill -9 arping 2>/dev/null || true

# Limpiar sockets residuales
rm -rf /var/run/wpa_supplicant* 2>/dev/null || true

# Eliminar namespaces previos
for ns in $(ip netns list | awk '{print $1}'); do
    if [[ "$ns" == ns_* ]]; then
        ip netns del "$ns" 2>/dev/null || true
    fi
done

airmon-ng check kill 2>/dev/null || true
modprobe -r mac80211_hwsim 2>/dev/null || true

sleep 2

echo "[+] 2. Cargando mac80211_hwsim (16 radios)..."
modprobe mac80211_hwsim radios=16
sleep 2

rfkill unblock wifi 2>/dev/null || true
rfkill unblock all 2>/dev/null || true

echo "[+] 3. Asignando nombres de interfaz..."

TARGETS=(
  "wlan0" "wlan1" "wlan2" "wlan3"
  "wlan_ap_open" "wlan_cli_open"
  "wlan_ap_wpa2" "wlan_cli1_wpa2" "wlan_cli2_wpa2"
  "wlan_ap_pmkid" "wlan_cli1_pmkid"
  "wlan_ap_ent" "wlan_cli_ent"
  "wlan_ap_wep" "wlan_cli1_wep" "wlan_cli2_wep"
)

mapfile -t HW_IFS < <(ip link show | grep -oP '(?<=: )\b(wlan|wfx)\d+\b' | sort -V)

if [ "${#HW_IFS[@]}" -lt 16 ]; then
    echo "[-] ERROR: Se esperaban 16 interfaces inalámbricas, pero se detectaron ${#HW_IFS[@]}."
    exit 1
fi

for idx in "${!TARGETS[@]}"; do
  orig_if="${HW_IFS[$idx]}"
  target="${TARGETS[$idx]}"
  
  if [ -n "$orig_if" ] && [ "$orig_if" != "$target" ]; then
    ip link set "$orig_if" down 2>/dev/null || true
    ip link set "$orig_if" name "$target" 2>/dev/null || true
    echo "  [✓] $orig_if -> $target"
  fi
done

sleep 1

echo "[+] 4. Generando configuraciones..."
mkdir -p "$LAB_DIR"/{open,wpa2,pmkid,enterprise,wep}

# ------------------------------------------------------------------------------
# ESCENARIO 1: OPEN
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/open/hostapd.conf"
interface=wlan_ap_open
driver=nl80211
ssid=he_open
hw_mode=g
channel=1
auth_algs=1
wpa=0
EOF

cat << 'EOF' > "$LAB_DIR/open/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_open
p2p_disabled=1
network={
    ssid="he_open"
    key_mgmt=NONE
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 2: WPA2 (PMK precalculada para "dragonfly")
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/wpa2/hostapd.conf"
interface=wlan_ap_wpa2
driver=nl80211
ssid=he_wpa2
hw_mode=g
channel=6
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_psk=6c80242a9fb6f890f5d7be465e921d7b172a11bf3721349b19e7c52b7245bb1f
EOF

cat << 'EOF' > "$LAB_DIR/wpa2/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_wpa2
p2p_disabled=1
network={
    ssid="he_wpa2"
    psk=6c80242a9fb6f890f5d7be465e921d7b172a11bf3721349b19e7c52b7245bb1f
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 3: PMKID (PMK precalculada para "chocolate")
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/pmkid/hostapd.conf"
interface=wlan_ap_pmkid
driver=nl80211
ssid=he_pmkid
hw_mode=g
channel=11
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_psk=b91c893041ee2b450516eb4dfd74eb224422e1b12204d6e64d7df6bc5ccbf40f
okc=1
EOF

cat << 'EOF' > "$LAB_DIR/pmkid/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_pmkid
p2p_disabled=1
network={
    ssid="he_pmkid"
    psk=b91c893041ee2b450516eb4dfd74eb224422e1b12204d6e64d7df6bc5ccbf40f
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 4: ENTERPRISE (802.1X / EAP-PEAP)
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/enterprise/hostapd.conf"
interface=wlan_ap_ent
driver=nl80211
ssid=he_enterprise
hw_mode=g
channel=3
wpa=2
wpa_key_mgmt=WPA-EAP
wpa_pairwise=CCMP
ieee8021x=1
auth_server_addr=127.0.0.1
auth_server_port=1812
auth_server_shared_secret=testing123
EOF

cat << 'EOF' > "$LAB_DIR/enterprise/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_ent
p2p_disabled=1
network={
    ssid="he_enterprise"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="student_user@domain.lab"
    password="EnterprisePass2026"
    phase2="auth=MSCHAPV2"
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 5: WEP (Clave WEP de 128 bits: 12345678901234567890123456)
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/wep/hostapd.conf"
interface=wlan_ap_wep
driver=nl80211
ssid=he_wep
hw_mode=g
channel=9
auth_algs=1
wep_default_key=0
wep_key0=12345678901234567890123456
EOF

cat << 'EOF' > "$LAB_DIR/wep/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_wep
p2p_disabled=1
network={
    ssid="he_wep"
    key_mgmt=NONE
    wep_key0=12345678901234567890123456
    wep_tx_keyidx=0
    auth_alg=OPEN
}
EOF

echo "[+] 5. Creando Network Namespaces y aislando radios virtuales..."

NAMESPACES=(
  "ns_ap_open" "ns_cli_open"
  "ns_ap_wpa2" "ns_cli1_wpa2" "ns_cli2_wpa2"
  "ns_ap_pmkid" "ns_cli1_pmkid"
  "ns_ap_ent" "ns_cli_ent"
  "ns_ap_wep" "ns_cli1_wep" "ns_cli2_wep"
)

IFS_TO_MOVE=(
  "wlan_ap_open" "wlan_cli_open"
  "wlan_ap_wpa2" "wlan_cli1_wpa2" "wlan_cli2_wpa2"
  "wlan_ap_pmkid" "wlan_cli1_pmkid"
  "wlan_ap_ent" "wlan_cli_ent"
  "wlan_ap_wep" "wlan_cli1_wep" "wlan_cli2_wep"
)

for idx in "${!NAMESPACES[@]}"; do
  ns="${NAMESPACES[$idx]}"
  iface="${IFS_TO_MOVE[$idx]}"
  
  ip netns add "$ns"
  phy_dev=$(iw dev "$iface" info | grep wiphy | awk '{print "phy"$2}')
  iw phy "$phy_dev" set netns name "$ns"
  
  ip netns exec "$ns" ip link set "$iface" up
  ip netns exec "$ns" ip link set lo up
done

# Activar interfaces del alumno en el namespace principal (wlan0 a wlan3)
for i in {0..3}; do
  ip link set "wlan$i" up 2>/dev/null || true
done

echo "[+] 6. Arrancando Puntos de Acceso (APs)..."
ip netns exec ns_ap_open hostapd -B "$LAB_DIR/open/hostapd.conf"
ip netns exec ns_ap_wpa2 hostapd -B "$LAB_DIR/wpa2/hostapd.conf"
ip netns exec ns_ap_pmkid hostapd -B "$LAB_DIR/pmkid/hostapd.conf"
ip netns exec ns_ap_ent hostapd -B "$LAB_DIR/enterprise/hostapd.conf"
ip netns exec ns_ap_wep hostapd -B "$LAB_DIR/wep/hostapd.conf"

ip netns exec ns_ap_open ip addr add 192.168.1.1/24 dev wlan_ap_open
ip netns exec ns_ap_wpa2 ip addr add 192.168.2.1/24 dev wlan_ap_wpa2
ip netns exec ns_ap_pmkid ip addr add 192.168.3.1/24 dev wlan_ap_pmkid
ip netns exec ns_ap_ent ip addr add 192.168.4.1/24 dev wlan_ap_ent
ip netns exec ns_ap_wep ip addr add 192.168.5.1/24 dev wlan_ap_wep

sleep 2

echo "[+] 7. Iniciando Servidor HTTP en el AP Open..."
ip netns exec ns_ap_open sh -c "while true; do echo -e 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK' | nc -l -p 80 > /dev/null 2>&1; done" &

echo "[+] 8. Conectando Clientes y activando generación continua de tráfico..."

# CLIENTE OPEN
mkdir -p /var/run/wpa_supplicant_open
ip netns exec ns_cli_open wpa_supplicant -B -Dnl80211 -i wlan_cli_open -c "$LAB_DIR/open/wpa.conf"
sleep 2
ip netns exec ns_cli_open ip addr add 192.168.1.2/24 dev wlan_cli_open
ip netns exec ns_cli_open sh -c "while true; do curl -s -m 1 -X POST -d 'user=admin&pass=SecretPass2026' http://192.168.1.1/login.php > /dev/null 2>&1 || true; sleep 1; done" &

# CLIENTES WPA2
mkdir -p /var/run/wpa_supplicant_wpa2
ip netns exec ns_cli1_wpa2 wpa_supplicant -B -Dnl80211 -i wlan_cli1_wpa2 -c "$LAB_DIR/wpa2/wpa.conf"
ip netns exec ns_cli2_wpa2 wpa_supplicant -B -Dnl80211 -i wlan_cli2_wpa2 -c "$LAB_DIR/wpa2/wpa.conf"
sleep 2
ip netns exec ns_cli1_wpa2 ip addr add 192.168.2.10/24 dev wlan_cli1_wpa2
ip netns exec ns_cli2_wpa2 ip addr add 192.168.2.20/24 dev wlan_cli2_wpa2

ip netns exec ns_cli1_wpa2 sh -c "while true; do ping -i 1 192.168.2.1 > /dev/null 2>&1; done" &
ip netns exec ns_cli2_wpa2 sh -c "while true; do ping -i 1 192.168.2.1 > /dev/null 2>&1; done" &

# CLIENTE PMKID
mkdir -p /var/run/wpa_supplicant_pmkid
ip netns exec ns_cli1_pmkid wpa_supplicant -B -Dnl80211 -i wlan_cli1_pmkid -c "$LAB_DIR/pmkid/wpa.conf"
sleep 2
ip netns exec ns_cli1_pmkid ip addr add 192.168.3.10/24 dev wlan_cli1_pmkid
ip netns exec ns_cli1_pmkid sh -c "while true; do ping -i 1 192.168.3.1 > /dev/null 2>&1; done" &

# CLIENTE ENTERPRISE
mkdir -p /var/run/wpa_supplicant_ent
ip netns exec ns_cli_ent wpa_supplicant -B -Dnl80211 -i wlan_cli_ent -c "$LAB_DIR/enterprise/wpa.conf"
sleep 2
ip netns exec ns_cli_ent ip addr add 192.168.4.10/24 dev wlan_cli_ent
ip netns exec ns_cli_ent sh -c "while true; do ping -i 1 192.168.4.1 > /dev/null 2>&1; done" &

# CLIENTES WEP (Generación continua de peticiones ARP Broadcast)
mkdir -p /var/run/wpa_supplicant_wep
ip netns exec ns_cli1_wep wpa_supplicant -B -Dnl80211 -i wlan_cli1_wep -c "$LAB_DIR/wep/wpa.conf"
ip netns exec ns_cli2_wep wpa_supplicant -B -Dnl80211 -i wlan_cli2_wep -c "$LAB_DIR/wep/wpa.conf"
sleep 2
ip netns exec ns_cli1_wep ip addr add 192.168.5.10/24 dev wlan_cli1_wep
ip netns exec ns_cli2_wep ip addr add 192.168.5.20/24 dev wlan_cli2_wep

# Bucle continuo: flush de caché ARP + arping broadcast para forzar tramas ARP
ip netns exec ns_cli1_wep sh -c "while true; do ip neigh flush all dev wlan_cli1_wep >/dev/null 2>&1; arping -c 1 -I wlan_cli1_wep -b 192.168.5.1 > /dev/null 2>&1; sleep 0.5; done" &
ip netns exec ns_cli2_wep sh -c "while true; do ip neigh flush all dev wlan_cli2_wep >/dev/null 2>&1; arping -c 1 -I wlan_cli2_wep -b 192.168.5.1 > /dev/null 2>&1; sleep 0.5; done" &

sleep 1

echo "[+] 9. Eliminando archivos de configuración en disco (Anti-Cheat)..."
rm -f "$LAB_DIR"/open/*.conf "$LAB_DIR"/wpa2/*.conf "$LAB_DIR"/pmkid/*.conf "$LAB_DIR"/enterprise/*.conf "$LAB_DIR"/wep/*.conf 2>/dev/null || true

echo ""
echo "=========================================================================="
echo " [✓] LABORATORIO WI-FI COMPLETO (5 ESCENARIOS CON CLIENTES ACTIVOS)"
echo "=========================================================================="
echo "Interfaces para el ALUMNO: wlan0 a wlan3"
echo "Escenarios activos:"
echo " - he_open       (Ch 1)  -> Captura HTTP POST (Texto plano)"
echo " - he_wpa2       (Ch 6)  -> Handshake 4-Way (Clave: dragonfly)"
echo " - he_pmkid      (Ch 11) -> Ataque PMKID Clientless (Clave: chocolate)"
echo " - he_enterprise (Ch 3)  -> Autenticación EAP-PEAP (Usuario: student_user@domain.lab)"
echo " - he_wep        (Ch 9)  -> Recolección de IVs / Reinyección ARP (Clave: 12345678901234567890123456)"
echo "=========================================================================="
