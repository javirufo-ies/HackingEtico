#!/bin/bash

# ==============================================================================
# SCRIPT DE DESPLIEGUE DEFINITIVO Y REALISTA - LAB WI-FI (mac80211_hwsim)
#   - 21 radios virtuales
#   - Interfaces de ALUMNO: wlan0 .. wlan6
#   - Escenario PMKID CON clientes : he_pmkid
#   - Escenario PMKID SIN clientes : he_pmkid_nc  (no clientes / clientless)
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

echo "[+] 2. Cargando mac80211_hwsim (21 radios)..."
modprobe mac80211_hwsim radios=21
sleep 2

rfkill unblock wifi 2>/dev/null || true
rfkill unblock all 2>/dev/null || true

echo "[+] 3. Asignando nombres de interfaz..."

# 7 interfaces para el alumno (wlan0..wlan6) + 14 para el laboratorio = 21
TARGETS=(
  "wlan0" "wlan1" "wlan2" "wlan3" "wlan4" "wlan5" "wlan6"
  "wlan_ap_open" "wlan_cli_open"
  "wlan_ap_wpa2" "wlan_cli1_wpa2" "wlan_cli2_wpa2"
  "wlan_ap_pmkid" "wlan_cli1_pmkid"
  "wlan_ap_pmk_nc" "wlan_cl_pmk_nc"
  "wlan_ap_ent" "wlan_cli_ent"
  "wlan_ap_wep" "wlan_cli1_wep" "wlan_cli2_wep"
)

mapfile -t HW_IFS < <(ip link show | grep -oP '(?<=: )\b(wlan|wfx)\d+\b' | sort -V)

if [ "${#HW_IFS[@]}" -lt 21 ]; then
    echo "[-] ERROR: Se esperaban 21 interfaces inalámbricas, pero se detectaron ${#HW_IFS[@]}."
    exit 1
fi

for idx in "${!TARGETS[@]}"; do
  orig_if="${HW_IFS[$idx]}"
  target="${TARGETS[$idx]}"

  # Aviso temprano: Linux limita los nombres de interfaz a 15 caracteres.
  if [ "${#target}" -gt 15 ]; then
    echo "[-] ERROR: '$target' tiene ${#target} caracteres (máx. 15). Acorta el nombre."
    exit 1
  fi

  if [ -n "$orig_if" ] && [ "$orig_if" != "$target" ]; then
    ip link set "$orig_if" down 2>/dev/null || true
    if ip link set "$orig_if" name "$target" 2>/dev/null; then
      echo "  [✓] $orig_if -> $target"
    else
      echo "[-] ERROR: no se pudo renombrar $orig_if -> $target"
      exit 1
    fi
  fi
done

sleep 1

echo "[+] 4. Generando configuraciones..."
mkdir -p "$LAB_DIR"/{open,wpa2,pmkid,pmkid_nc,enterprise,wep}

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
# ESCENARIO 2: WPA2
#   Clave almacenada como PMK (wpa_psk, 64 hex = PBKDF2(passphrase, SSID)).
#   La passphrase en claro NO aparece en el script (anti-cheat con root).
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
wpa_psk=3dc00023cc4f8e283e2c2fb51c393f60a04d96f10797945dac73e2a92f18c088
EOF

cat << 'EOF' > "$LAB_DIR/wpa2/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_wpa2
p2p_disabled=1
network={
    ssid="he_wpa2"
    psk=3dc00023cc4f8e283e2c2fb51c393f60a04d96f10797945dac73e2a92f18c088
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 3a: PMKID CON CLIENTES
#   Clave como PMK (wpa_psk). Hay una estación asociada generando tráfico: el
#   alumno puede capturar el PMKID en la asociación o, tras un deauth, el
#   handshake 4-way. El comportamiento por radio es idéntico al de passphrase.
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
wpa_psk=4251bbd9ad8c453e3172cb49328778fd4394351e543b41c451cc105b7a7af155
okc=1
EOF

cat << 'EOF' > "$LAB_DIR/pmkid/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_pmkid
p2p_disabled=1
network={
    ssid="he_pmkid"
    psk=4251bbd9ad8c453e3172cb49328778fd4394351e543b41c451cc105b7a7af155
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 3b: PMKID SIN CLIENTES / NO CLIENTES (clientless)
#   Clave como PMK (wpa_psk). AP sin ninguna estación asociada de forma
#   permanente: el alumno debe provocar él mismo la asociación para que el AP
#   emita el M1 del 4-way. Con PSK el PMKID depende de la MAC del alumno
#   (HMAC-SHA1-128(PMK, "PMK Name" | MAC_AP | MAC_STA)), así que no depende
#   de que otro cliente se haya conectado antes.
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/pmkid_nc/hostapd.conf"
interface=wlan_ap_pmk_nc
driver=nl80211
ssid=he_pmkid_nc
hw_mode=g
channel=4
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_psk=1f84ed5d6b964c2489d9ce0f50e3d75eeb374207291538e4bdfc8491a1548192
okc=1
EOF

cat << 'EOF' > "$LAB_DIR/pmkid_nc/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_pmkid_nc
p2p_disabled=1
network={
    ssid="he_pmkid_nc"
    psk=1f84ed5d6b964c2489d9ce0f50e3d75eeb374207291538e4bdfc8491a1548192
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
  "ns_ap_pmkid_nc" "ns_cl_pmkid_nc"
  "ns_ap_ent" "ns_cli_ent"
  "ns_ap_wep" "ns_cli1_wep" "ns_cli2_wep"
)

IFS_TO_MOVE=(
  "wlan_ap_open" "wlan_cli_open"
  "wlan_ap_wpa2" "wlan_cli1_wpa2" "wlan_cli2_wpa2"
  "wlan_ap_pmkid" "wlan_cli1_pmkid"
  "wlan_ap_pmk_nc" "wlan_cl_pmk_nc"
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

# Activar interfaces del alumno en el namespace principal (wlan0 a wlan6)
for i in {0..6}; do
  ip link set "wlan$i" up 2>/dev/null || true
done

# ------------------------------------------------------------------------------
# hostapd parcheado para los escenarios PMKID (he_pmkid, he_pmkid_nc).
# El hostapd de serie no emite el PMKID en el M1 con WPA-PSK; se compila uno
# parcheado con compila_hostapd_pmkid.sh (en la misma carpeta que este script).
# ------------------------------------------------------------------------------
HOSTAPD_PMKID="/usr/local/sbin/hostapd-pmkid"
if [ ! -x "$HOSTAPD_PMKID" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -x "$SCRIPT_DIR/compila_hostapd_pmkid.sh" ]; then
    echo "[!] $HOSTAPD_PMKID no existe. Compilando hostapd parcheado..."
    "$SCRIPT_DIR/compila_hostapd_pmkid.sh"
  else
    echo "[-] ERROR: falta $HOSTAPD_PMKID y no encuentro compila_hostapd_pmkid.sh."
    echo "    Ejecuta antes: sudo ./compila_hostapd_pmkid.sh"
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# hostapd del sistema para los escenarios open/wpa2/enterprise/wep.
# Si no esta instalado, se instala; luego se resuelve su ruta completa
# (bajo sudo, /usr/sbin puede no estar en el PATH).
# ------------------------------------------------------------------------------
if ! command -v hostapd >/dev/null 2>&1 && [ ! -x /usr/sbin/hostapd ]; then
  echo "[!] hostapd no esta instalado. Instalandolo..."
  apt-get update -qq
  apt-get install -y -qq hostapd
  # apt deja el servicio activo bloqueando la radio: se desactiva.
  systemctl disable --now hostapd >/dev/null 2>&1 || true
  systemctl unmask hostapd >/dev/null 2>&1 || true
  rfkill unblock wifi 2>/dev/null || true
fi
HOSTAPD_SYS="$(command -v hostapd || echo /usr/sbin/hostapd)"
if [ ! -x "$HOSTAPD_SYS" ]; then
  echo "[-] ERROR: no se encuentra el binario hostapd tras intentar instalarlo."
  exit 1
fi

echo "[+] 6. Arrancando Puntos de Acceso (APs)..."
ip netns exec ns_ap_open     "$HOSTAPD_SYS" -B "$LAB_DIR/open/hostapd.conf"
ip netns exec ns_ap_wpa2     "$HOSTAPD_SYS" -B "$LAB_DIR/wpa2/hostapd.conf"
ip netns exec ns_ap_pmkid    "$HOSTAPD_PMKID" -B "$LAB_DIR/pmkid/hostapd.conf"
ip netns exec ns_ap_pmkid_nc "$HOSTAPD_PMKID" -B "$LAB_DIR/pmkid_nc/hostapd.conf"
ip netns exec ns_ap_ent      "$HOSTAPD_SYS" -B "$LAB_DIR/enterprise/hostapd.conf"
ip netns exec ns_ap_wep      "$HOSTAPD_SYS" -B "$LAB_DIR/wep/hostapd.conf"

ip netns exec ns_ap_open     ip addr add 192.168.1.1/24 dev wlan_ap_open
ip netns exec ns_ap_wpa2     ip addr add 192.168.2.1/24 dev wlan_ap_wpa2
ip netns exec ns_ap_pmkid    ip addr add 192.168.3.1/24 dev wlan_ap_pmkid
ip netns exec ns_ap_pmkid_nc ip addr add 192.168.6.1/24 dev wlan_ap_pmk_nc
ip netns exec ns_ap_ent      ip addr add 192.168.4.1/24 dev wlan_ap_ent
ip netns exec ns_ap_wep      ip addr add 192.168.5.1/24 dev wlan_ap_wep

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

# CLIENTE PMKID (CON cliente) -> escenario he_pmkid
mkdir -p /var/run/wpa_supplicant_pmkid
ip netns exec ns_cli1_pmkid wpa_supplicant -B -Dnl80211 -i wlan_cli1_pmkid -c "$LAB_DIR/pmkid/wpa.conf"
sleep 2
ip netns exec ns_cli1_pmkid ip addr add 192.168.3.10/24 dev wlan_cli1_pmkid
ip netns exec ns_cli1_pmkid sh -c "while true; do ping -i 1 192.168.3.1 > /dev/null 2>&1; done" &

# ESCENARIO PMKID NO CLIENTES (he_pmkid_nc): cliente efímero que asocia una vez
# (comprueba que el AP funciona) y se desconecta. Al acabar el AP queda SIN clientes.
mkdir -p /var/run/wpa_supplicant_pmkid_nc
CTRL_NC="/var/run/wpa_supplicant_pmkid_nc"
ip netns exec ns_cl_pmkid_nc wpa_supplicant -B -Dnl80211 -i wlan_cl_pmk_nc -c "$LAB_DIR/pmkid_nc/wpa.conf"

# Esperar a que complete el 4-way handshake (máx. 15 s)
NC_OK=0
for _ in $(seq 1 15); do
  if ip netns exec ns_cl_pmkid_nc wpa_cli -p "$CTRL_NC" -i wlan_cl_pmk_nc status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
    NC_OK=1
    break
  fi
  sleep 1
done
if [ "$NC_OK" -eq 1 ]; then
  echo "  [✓] Cliente he_pmkid_nc completó el handshake"
else
  echo "  [!] Cliente he_pmkid_nc NO completó el handshake"
fi

# Terminar SOLO este wpa_supplicant. 'ip netns exec' NO aísla PIDs: un pkill
# aquí mataría también los clientes de los demás escenarios.
ip netns exec ns_cl_pmkid_nc wpa_cli -p "$CTRL_NC" -i wlan_cl_pmk_nc terminate > /dev/null 2>&1 || true
sleep 1
# Forzar desconexión por si acaso (falla si ya no hay enlace: se ignora)
ip netns exec ns_cl_pmkid_nc iw dev wlan_cl_pmk_nc disconnect 2>/dev/null || true
# Verificar que está desconectado (debe decir "Not connected")
ip netns exec ns_cl_pmkid_nc iw dev wlan_cl_pmk_nc link || true

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

# Bucle continuo: flush de caché ARP + ping a IP inexistente para forzar ARP broadcast
# (ping a una IP SIN dueño => nunca se resuelve => broadcast perpetuo, ideal para aireplay -3)
ip netns exec ns_cli1_wep sh -c "while true; do ip neigh flush all dev wlan_cli1_wep >/dev/null 2>&1; ping -c1 -W1 192.168.5.200 >/dev/null 2>&1; sleep 0.3; done" &
ip netns exec ns_cli2_wep sh -c "while true; do ip neigh flush all dev wlan_cli2_wep >/dev/null 2>&1; ping -c1 -W1 192.168.5.201 >/dev/null 2>&1; sleep 0.3; done" &

sleep 1

# ------------------------------------------------------------------------------
# Resumen de BSSID REALES (se leen del sistema; evita adivinar la MAC del AP)
# ------------------------------------------------------------------------------
get_bssid() { ip netns exec "$1" cat "/sys/class/net/$2/address" 2>/dev/null; }

BSSID_OPEN=$(get_bssid ns_ap_open     wlan_ap_open)
BSSID_WPA2=$(get_bssid ns_ap_wpa2     wlan_ap_wpa2)
BSSID_PMKID=$(get_bssid ns_ap_pmkid    wlan_ap_pmkid)
BSSID_PMKIDNC=$(get_bssid ns_ap_pmkid_nc wlan_ap_pmk_nc)
BSSID_ENT=$(get_bssid ns_ap_ent      wlan_ap_ent)
BSSID_WEP=$(get_bssid ns_ap_wep      wlan_ap_wep)

echo "[+] 9. Eliminando archivos de configuración en disco (Anti-Cheat)..."
rm -f "$LAB_DIR"/open/*.conf "$LAB_DIR"/wpa2/*.conf "$LAB_DIR"/pmkid/*.conf \
      "$LAB_DIR"/pmkid_nc/*.conf "$LAB_DIR"/enterprise/*.conf "$LAB_DIR"/wep/*.conf 2>/dev/null || true

echo ""
echo "=========================================================================="
echo " [✓] LABORATORIO WI-FI COMPLETO (6 ESCENARIOS)"
echo "=========================================================================="
echo "Interfaces para el ALUMNO: wlan0 a wlan6"
echo ""
echo "Escenarios activos (BSSID real detectada):"
echo " - he_open       (Ch 1 , BSSID $BSSID_OPEN)   -> Captura HTTP POST (texto plano)"
echo " - he_wpa2       (Ch 6 , BSSID $BSSID_WPA2)   -> Handshake 4-Way     (clave oculta: crackear)"
echo " - he_pmkid      (Ch 11, BSSID $BSSID_PMKID)  -> PMKID CON clientes  (clave oculta: crackear)"
echo " - he_pmkid_nc   (Ch 4 , BSSID $BSSID_PMKIDNC)-> PMKID SIN clientes  (clave oculta: crackear)"
echo " - he_enterprise (Ch 3 , BSSID $BSSID_ENT)    -> EAP-PEAP            (Usuario: student_user@domain.lab)"
echo " - he_wep        (Ch 9 , BSSID $BSSID_WEP)    -> IVs / Reinyeccion ARP"
echo "=========================================================================="
echo "Las claves WPA2 se almacenan como PMK (wpa_psk hex): no son visibles en"
echo "claro ni en el script ni en los .conf. El alumno DEBE crackearlas."
echo "NOTA: con 21 radios, las BSSID cambian respecto a versiones anteriores."
echo "      Usa SIEMPRE las BSSID mostradas arriba (o airodump-ng) para atacar."
echo "=========================================================================="
