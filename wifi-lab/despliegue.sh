#!/bin/bash

# ==============================================================================
# LABORATORIO WI-FI (mac80211_hwsim) HACKING ÉTICO
# Francisco Javier Rufo Mendo
#   - 23 radios virtuales
#   - Interfaces de ALUMNO: wlan0 .. wlan6
#   - Escenario PMKID CON clientes : he_pmkid
#   - Escenario PMKID SIN clientes : he_pmkid_nc  (no clientes / clientless)
#   - Escenario WPS vulnerable     : he_wps       (fuerza bruta del PIN)
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ejecuta este script como root (sudo)."
  exit 1 
fi

# ------------------------------------------------------------------------------
# Paquetes necesarios: hostapd (APs), hcxtools (captura/conversion PMKID) y
# OpenCL en CPU (pocl + ocl-icd) para hashcat. Solo se instalan los que falten.
# ------------------------------------------------------------------------------
PAQUETES=(hostapd hcxtools pocl-opencl-icd ocl-icd-libopencl1 hostapd-wpe openssl)
FALTAN=()
for pkg in "${PAQUETES[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
    FALTAN+=("$pkg")
  fi
done

if [ "${#FALTAN[@]}" -gt 0 ]; then
  echo "[!] Faltan paquetes: ${FALTAN[*]}. Instalandolos..."
  apt-get update -qq
  apt-get install -y -qq "${FALTAN[@]}"
  if [[ " ${FALTAN[*]} " == *" hostapd "* ]]; then
    # apt deja el servicio activo bloqueando la radio: se desactiva.
    systemctl disable --now hostapd >/dev/null 2>&1 || true
    systemctl unmask hostapd >/dev/null 2>&1 || true
  fi
else
  echo "[+] Paquetes necesarios ya instalados."
fi

LAB_DIR="/opt/wifi-lab"

echo "[+] 1. Limpiando entorno previo..."
pkill -9 -f LAB_WPS_WATCHDOG 2>/dev/null || true
pkill -9 hostapd 2>/dev/null || true
pkill -9 wpa_supplicant 2>/dev/null || true
pkill -9 nc 2>/dev/null || true
pkill -9 curl 2>/dev/null || true
pkill -9 ping 2>/dev/null || true
pkill -9 arping 2>/dev/null || true
pkill -9 -f "wlan_cli_ent reassociate" 2>/dev/null || true

# Limpiar sockets residuales
rm -rf /var/run/wpa_supplicant* /var/run/hostapd_wps 2>/dev/null || true

# Eliminar namespaces previos
for ns in $(ip netns list | awk '{print $1}'); do
    if [[ "$ns" == ns_* ]]; then
        ip netns del "$ns" 2>/dev/null || true
    fi
done

# NetworkManager NO debe gestionar las radios virtuales (escanearía y cambiaría
# de canal). Se excluyen por driver, así la wifi real del host no se ve afectada.
# No se usa 'airmon-ng check kill': pararía NetworkManager (red del host) y,
# como 'ip netns exec' no aísla PIDs, mataría también a los clientes del lab.
NM_CONF="/etc/NetworkManager/conf.d/99-wifi-lab.conf"
if [ -d /etc/NetworkManager/conf.d ]; then
  cat << 'EOF' > "$NM_CONF"
[keyfile]
unmanaged-devices+=driver:mac80211_hwsim
EOF
  nmcli general reload conf 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
fi

modprobe -r mac80211_hwsim 2>/dev/null || true

sleep 2

echo "[+] 2. Cargando mac80211_hwsim (23 radios)..."
modprobe mac80211_hwsim radios=23
sleep 2

rfkill unblock wifi 2>/dev/null || true
rfkill unblock all 2>/dev/null || true

echo "[+] 3. Asignando nombres de interfaz..."

# 7 interfaces para el alumno (wlan0..wlan6) + 16 para el laboratorio = 23
TARGETS=(
  "wlan0" "wlan1" "wlan2" "wlan3" "wlan4" "wlan5" "wlan6"
  "wlan_ap_open" "wlan_cli_open"
  "wlan_ap_wpa2" "wlan_cli1_wpa2" "wlan_cli2_wpa2"
  "wlan_ap_pmkid" "wlan_cli1_pmkid"
  "wlan_ap_pmk_nc" "wlan_cl_pmk_nc"
  "wlan_ap_ent" "wlan_cli_ent"
  "wlan_ap_wep" "wlan_cli1_wep" "wlan_cli2_wep"
  "wlan_ap_wps" "wlan_cli_wps"
)

mapfile -t HW_IFS < <(ip link show | grep -oP '(?<=: )\b(wlan|wfx)\d+\b' | sort -V)

if [ "${#HW_IFS[@]}" -lt 23 ]; then
    echo "[-] ERROR: Se esperaban 23 interfaces inalámbricas, pero se detectaron ${#HW_IFS[@]}."
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

# Refuerzo en caliente por si NetworkManager no ha leído la configuración
for target in "${TARGETS[@]}"; do
  nmcli dev set "$target" managed no 2>/dev/null || true
done

sleep 1

echo "[+] 4. Generando configuraciones..."
mkdir -p "$LAB_DIR"/{open,wpa2,pmkid,pmkid_nc,enterprise,wep,wps}

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
wpa_psk=3e9ef0d8989c7a272eb6ff5a711136aba70f47821c5690017335f9f1d1ecf262
EOF

cat << 'EOF' > "$LAB_DIR/wpa2/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_wpa2
p2p_disabled=1
network={
    ssid="he_wpa2"
    psk=3e9ef0d8989c7a272eb6ff5a711136aba70f47821c5690017335f9f1d1ecf262
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
wpa_psk=414ff00c403e17f5d6a1e8baa5fbb78eec5053795aa027d5763fc5a26afce996
okc=1
EOF

cat << 'EOF' > "$LAB_DIR/pmkid/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_pmkid
p2p_disabled=1
network={
    ssid="he_pmkid"
    psk=414ff00c403e17f5d6a1e8baa5fbb78eec5053795aa027d5763fc5a26afce996
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
wpa_psk=b25e910e95c0b150e515f1057caeb6cba4437c813d80947cd9ee84dd0899e745
okc=1
EOF

cat << 'EOF' > "$LAB_DIR/pmkid_nc/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_pmkid_nc
p2p_disabled=1
network={
    ssid="he_pmkid_nc"
    psk=b25e910e95c0b150e515f1057caeb6cba4437c813d80947cd9ee84dd0899e745
}
EOF


# ------------------------------------------------------------------------------
# ESCENARIO 4: ENTERPRISE (802.1X / EAP-PEAP)
#   El propio hostapd hace de servidor de autenticación (eap_server=1), sin
#   RADIUS externo: así el cliente completa el intercambio PEAP/MSCHAPv2 y en
#   el aire se ven la identidad y el método EAP (tipo 25).
#   El certificado del servidor es autofirmado y se reutiliza entre despliegues.
# ------------------------------------------------------------------------------
CERT_DIR="$LAB_DIR/enterprise/certs"
mkdir -p "$CERT_DIR"
if [ ! -s "$CERT_DIR/server.pem" ] || [ ! -s "$CERT_DIR/server.key" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/C=ES/O=HE Lab/CN=radius.domain.lab" \
    -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.pem" > /dev/null 2>&1
  chmod 600 "$CERT_DIR/server.key"
fi

cat << EOF > "$LAB_DIR/enterprise/hostapd.conf"
interface=wlan_ap_ent
driver=nl80211
ssid=he_enterprise
hw_mode=g
channel=3
wpa=2
wpa_key_mgmt=WPA-EAP
rsn_pairwise=CCMP
ieee8021x=1
disable_pmksa_caching=1
eap_server=1
eap_user_file=$LAB_DIR/enterprise/eap_user.conf
ca_cert=$CERT_DIR/server.pem
server_cert=$CERT_DIR/server.pem
private_key=$CERT_DIR/server.key
EOF

# Fase 1: cualquier identidad externa usa PEAP. Fase 2 (dentro del túnel):
# usuario y contraseña MSCHAPv2 ([2] = solo válido en fase 2).
cat << 'EOF' > "$LAB_DIR/enterprise/eap_user.conf"
*                          PEAP
"alumno@iesvjp.es"  MSCHAPV2  "computer"  [2]
EOF

cat << 'EOF' > "$LAB_DIR/enterprise/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_ent
p2p_disabled=1
network={
    ssid="he_enterprise"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="alumno@iesvjp.es"
    password="computer"
    phase2="auth=MSCHAPV2"
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 5: WEP (clave de 104 bits en hex, 13 caracteres ASCII)
# ------------------------------------------------------------------------------
cat << 'EOF' > "$LAB_DIR/wep/hostapd.conf"
interface=wlan_ap_wep
driver=nl80211
ssid=he_wep
hw_mode=g
channel=9
auth_algs=1
wep_default_key=0
wep_key0=696c6f76656d7966616d696c79
EOF

cat << 'EOF' > "$LAB_DIR/wep/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_wep
p2p_disabled=1
network={
    ssid="he_wep"
    key_mgmt=NONE
    wep_key0=696c6f76656d7966616d696c79
    wep_tx_keyidx=0
    auth_alg=OPEN
}
EOF

# ------------------------------------------------------------------------------
# ESCENARIO 6: WPS VULNERABLE (fuerza bruta online del PIN de AP)
#   - PIN y passphrase ALEATORIOS en cada despliegue (anti-cheat): no aparecen
#     en el script. La passphrase no está en ningún diccionario: la lección es
#     que WPS entrega la clave WPA2 aunque esta sea robusta.
#   - Primera mitad del PIN en 0000-0099 y segunda en 000-099 (+ checksum):
#     con reaver (orden ascendente) son ~200 intentos como máximo, lo que
#     cabe en una sesión de clase.
#   - hostapd bloquea el PIN tras 3 fallos; un watchdog (paso 8) lo desbloquea
#     cada segundo para simular un router sin protección anti-fuerza bruta.
#   - Usa hostapd-pmkid (parche del ACK), no el hostapd del sistema.
# ------------------------------------------------------------------------------
wps_checksum() {
  local p=$((10#$1)) acc=0
  while [ "$p" -gt 0 ]; do
    acc=$((acc + 3 * (p % 10))); p=$((p / 10))
    acc=$((acc + p % 10));       p=$((p / 10))
  done
  echo $(( (10 - acc % 10) % 10 ))
}
WPS_PIN7="$(printf '%04d' $((RANDOM % 100)))$(printf '%03d' $((RANDOM % 100)))"
WPS_PIN="${WPS_PIN7}$(wps_checksum "$WPS_PIN7")"
WPS_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"

cat << EOF > "$LAB_DIR/wps/hostapd.conf"
interface=wlan_ap_wps
driver=nl80211
ctrl_interface=/var/run/hostapd_wps
ssid=he_wps
hw_mode=g
channel=7
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$WPS_PASS
# --- WPS ---
wps_state=2
eap_server=1
ap_pin=$WPS_PIN
ap_setup_locked=0
config_methods=label display keypad push_button
device_name=Router Lab
manufacturer=HackingEtico
model_name=VulnRouter
model_number=1.0
serial_number=0001
device_type=6-0050F204-1
os_version=01020300
EOF

# Cliente legítimo: da realismo (la red "tiene uso") y verifica que el AP
# funciona. NO es necesario para el ataque WPS.
cat << EOF > "$LAB_DIR/wps/wpa.conf"
ctrl_interface=/var/run/wpa_supplicant_wps
p2p_disabled=1
network={
    ssid="he_wps"
    psk="$WPS_PASS"
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
  "ns_ap_wps" "ns_cli_wps"
)

IFS_TO_MOVE=(
  "wlan_ap_open" "wlan_cli_open"
  "wlan_ap_wpa2" "wlan_cli1_wpa2" "wlan_cli2_wpa2"
  "wlan_ap_pmkid" "wlan_cli1_pmkid"
  "wlan_ap_pmk_nc" "wlan_cl_pmk_nc"
  "wlan_ap_ent" "wlan_cli_ent"
  "wlan_ap_wep" "wlan_cli1_wep" "wlan_cli2_wep"
  "wlan_ap_wps" "wlan_cli_wps"
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
# hostapd parcheado para los escenarios PMKID (he_pmkid, he_pmkid_nc) y WPS.
# El hostapd de serie no emite el PMKID en el M1 con WPA-PSK; se compila uno
# parcheado con compila_hostapd_pmkid.sh (en la misma carpeta que este script).
# he_wps también lo usa por el parche del ACK: reaver/bully se asocian desde
# modo monitor y, sin ese parche, hostapd los descarta tras la asociación
# (EAPOL-Start sin respuesta => "Receive timeout occurred").
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

# El escenario WPS exige que hostapd-pmkid esté compilado con CONFIG_WPS=y.
# (La cadena 'wps_state' solo existe en el binario si se compiló con WPS.)
if ! grep -qa 'wps_state' "$HOSTAPD_PMKID"; then
  echo "[-] ERROR: $HOSTAPD_PMKID no tiene soporte WPS (falta CONFIG_WPS=y)."
  echo "    En compila_hostapd_pmkid.sh, justo después de crear el .config"
  echo "    (cp defconfig .config), añade:   echo \"CONFIG_WPS=y\" >> .config"
  echo "    y recompila:                     sudo ./compila_hostapd_pmkid.sh --force"
  exit 1
fi

# ------------------------------------------------------------------------------
# hostapd del sistema para los escenarios open/wpa2/enterprise/wep.
# Se resuelve su ruta completa (bajo sudo, /usr/sbin puede no estar en el PATH).
# ------------------------------------------------------------------------------
HOSTAPD_SYS="$(command -v hostapd || echo /usr/sbin/hostapd)"
if [ ! -x "$HOSTAPD_SYS" ]; then
  echo "[-] ERROR: no se encuentra el binario hostapd tras intentar instalarlo."
  exit 1
fi
HOSTAPD_CLI="$(command -v hostapd_cli || echo /usr/sbin/hostapd_cli)"
if [ ! -x "$HOSTAPD_CLI" ]; then
  echo "[-] ERROR: no se encuentra hostapd_cli (necesario para el escenario WPS)."
  exit 1
fi

echo "[+] 6. Arrancando Puntos de Acceso (APs)..."
ip netns exec ns_ap_open     "$HOSTAPD_SYS" -B "$LAB_DIR/open/hostapd.conf"
ip netns exec ns_ap_wpa2     "$HOSTAPD_SYS" -B "$LAB_DIR/wpa2/hostapd.conf"
ip netns exec ns_ap_pmkid    "$HOSTAPD_PMKID" -B "$LAB_DIR/pmkid/hostapd.conf"
ip netns exec ns_ap_pmkid_nc "$HOSTAPD_PMKID" -B "$LAB_DIR/pmkid_nc/hostapd.conf"
ip netns exec ns_ap_ent      "$HOSTAPD_SYS" -B "$LAB_DIR/enterprise/hostapd.conf"
ip netns exec ns_ap_wep      "$HOSTAPD_SYS" -B "$LAB_DIR/wep/hostapd.conf"
ip netns exec ns_ap_wps      "$HOSTAPD_PMKID" -B "$LAB_DIR/wps/hostapd.conf"

ip netns exec ns_ap_open     ip addr add 192.168.1.1/24 dev wlan_ap_open
ip netns exec ns_ap_wpa2     ip addr add 192.168.2.1/24 dev wlan_ap_wpa2
ip netns exec ns_ap_pmkid    ip addr add 192.168.3.1/24 dev wlan_ap_pmkid
ip netns exec ns_ap_pmkid_nc ip addr add 192.168.6.1/24 dev wlan_ap_pmk_nc
ip netns exec ns_ap_ent      ip addr add 192.168.4.1/24 dev wlan_ap_ent
ip netns exec ns_ap_wep      ip addr add 192.168.5.1/24 dev wlan_ap_wep
ip netns exec ns_ap_wps      ip addr add 192.168.7.1/24 dev wlan_ap_wps

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

# Esperar a que complete PEAP + 4-way handshake (máx. 15 s)
ENT_OK=0
for _ in $(seq 1 15); do
  if ip netns exec ns_cli_ent wpa_cli -p /var/run/wpa_supplicant_ent -i wlan_cli_ent status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
    ENT_OK=1
    break
  fi
  sleep 1
done
if [ "$ENT_OK" -eq 1 ]; then
  echo "  [✓] Cliente he_enterprise autenticado (PEAP/MSCHAPv2)"
else
  echo "  [!] Cliente he_enterprise NO se autenticó (revisa hostapd/certificados)"
fi
ip netns exec ns_cli_ent ip addr add 192.168.4.10/24 dev wlan_cli_ent
ip netns exec ns_cli_ent sh -c "while true; do ping -i 1 192.168.4.1 > /dev/null 2>&1; done" &
# Reasociación periódica: repite el EAP completo (sin caché de PMKSA) para que
# el alumno lo vea con una captura pasiva, sin necesidad de deauth.
ip netns exec ns_cli_ent sh -c "while true; do sleep 30; wpa_cli -p /var/run/wpa_supplicant_ent -i wlan_cli_ent reassociate > /dev/null 2>&1; done" &

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

# ESCENARIO WPS
WPS_CTRL="/var/run/hostapd_wps"

# Comprobar que hostapd ha activado WPS (si el binario no tuviera soporte WPS,
# no habría arrancado o get_config no mostraría wps_state=configured)
if ip netns exec ns_ap_wps "$HOSTAPD_CLI" -p "$WPS_CTRL" -i wlan_ap_wps get_config 2>/dev/null | grep -q '^wps_state=configured'; then
  echo "  [✓] AP he_wps con WPS activo (PIN de AP habilitado)"
else
  echo "  [!] AP he_wps: WPS NO aparece activo (revisa CONFIG_WPS en hostapd-pmkid)"
fi

# Cliente legítimo (realismo + verificación del AP)
mkdir -p /var/run/wpa_supplicant_wps
ip netns exec ns_cli_wps wpa_supplicant -B -Dnl80211 -i wlan_cli_wps -c "$LAB_DIR/wps/wpa.conf"
WPS_OK=0
for _ in $(seq 1 15); do
  if ip netns exec ns_cli_wps wpa_cli -p /var/run/wpa_supplicant_wps -i wlan_cli_wps status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
    WPS_OK=1
    break
  fi
  sleep 1
done
if [ "$WPS_OK" -eq 1 ]; then
  echo "  [✓] Cliente he_wps conectado"
else
  echo "  [!] Cliente he_wps NO completó el handshake"
fi
ip netns exec ns_cli_wps ip addr add 192.168.7.10/24 dev wlan_cli_wps
ip netns exec ns_cli_wps sh -c "while true; do ping -i 1 192.168.7.1 > /dev/null 2>&1; done" &

# WATCHDOG ANTI-LOCKOUT: re-fija el PIN cada segundo. 'wps_ap_pin set' pone a
# cero los contadores de fallos y desbloquea el AP => simula un router sin
# protección contra fuerza bruta. Lee el PIN del propio hostapd para que no
# aparezca en la lista de procesos. Para demostrar la defensa (lockout):
#   sudo pkill -f LAB_WPS_WATCHDOG
ip netns exec ns_ap_wps sh -c "
  : LAB_WPS_WATCHDOG
  CLI='$HOSTAPD_CLI -p $WPS_CTRL -i wlan_ap_wps'
  while true; do
    P=\$(\$CLI wps_ap_pin get 2>/dev/null)
    if echo \"\$P\" | grep -qE '^[0-9]{8}\$'; then
      \$CLI wps_ap_pin set \"\$P\" 0 > /dev/null 2>&1
    fi
    sleep 1
  done
" &

# No dejar el PIN ni la clave en variables del script
unset WPS_PIN WPS_PIN7 WPS_PASS

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
BSSID_WPS=$(get_bssid ns_ap_wps      wlan_ap_wps)

echo "[+] 9. Eliminando archivos de configuración en disco (Anti-Cheat)..."
rm -f "$LAB_DIR"/open/*.conf "$LAB_DIR"/wpa2/*.conf "$LAB_DIR"/pmkid/*.conf \
      "$LAB_DIR"/pmkid_nc/*.conf "$LAB_DIR"/enterprise/*.conf "$LAB_DIR"/wep/*.conf \
      "$LAB_DIR"/wps/*.conf 2>/dev/null || true

echo ""
echo "=========================================================================="
echo " [✓] LABORATORIO WI-FI COMPLETO (7 ESCENARIOS)"
echo "=========================================================================="
echo "Interfaces para el ALUMNO: wlan0 a wlan6"
echo ""
echo "Escenarios activos (BSSID real detectada):"
echo " - he_open       (Ch 1 , BSSID $BSSID_OPEN)   -> Captura HTTP POST (texto plano)"
echo " - he_wpa2       (Ch 6 , BSSID $BSSID_WPA2)   -> Handshake 4-Way     (clave oculta: crackear)"
echo " - he_pmkid      (Ch 11, BSSID $BSSID_PMKID)  -> PMKID CON clientes  (clave oculta: crackear)"
echo " - he_pmkid_nc   (Ch 4 , BSSID $BSSID_PMKIDNC)-> PMKID SIN clientes  (clave oculta: crackear)"
echo " - he_enterprise (Ch 3 , BSSID $BSSID_ENT)    -> EAP-PEAP            (Usuario: alumno@iesvjp.es)"
echo " - he_wep        (Ch 9 , BSSID $BSSID_WEP)    -> IVs / Reinyeccion ARP"
echo " - he_wps        (Ch 7 , BSSID $BSSID_WPS)    -> WPS PIN (fuerza bruta: reaver / bully)"
echo "=========================================================================="
echo "Las claves WPA2 se almacenan como PMK (wpa_psk hex): no son visibles en"
echo "claro ni en el script ni en los .conf. El alumno DEBE crackearlas."
echo "El PIN WPS y la clave de he_wps son ALEATORIOS en cada despliegue."
echo "NOTA: con 23 radios, las BSSID cambian respecto a versiones anteriores."
echo "      Usa SIEMPRE las BSSID mostradas arriba (o airodump-ng) para atacar."
echo "=========================================================================="