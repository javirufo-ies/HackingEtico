#!/bin/bash

# ==============================================================================
# COMPILA UN HOSTAPD PARCHEADO PARA LOS ESCENARIOS PMKID (he_pmkid, he_pmkid_nc)
# Y WPS (he_wps)
#
#   El hostapd de serie no incluye el PMKID KDE en el mensaje M1 del 4-way con
#   WPA-PSK (solo con 802.1X, SAE u OWE). Para que el ejercicio PMKID del
#   laboratorio funcione, este script anade WPA-PSK a esa condicion en
#   src/ap/wpa_auth.c (estado PTKSTART). Ademas hace que hostapd no exija el
#   ACK de la Authentication/Association Response (en hwsim nadie confirma las
#   tramas dirigidas a una MAC inyectada desde modo monitor: hcxdumptool,
#   reaver, bully). Se compila con soporte WPS (CONFIG_WPS=y) para he_wps.
#   Compila el binario en:
#
#       /usr/local/sbin/hostapd-pmkid
#
#   El hostapd del sistema no se toca: el resto de escenarios lo siguen usando.
#   Uso: sudo ./compila_hostapd_pmkid.sh [--force]
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ejecuta este script como root (sudo)."
  exit 1
fi

HOSTAPD_VER="2.10"
HOSTAPD_SHA256="206e7c799b678572c2e3d12030238784bc4a9f82323b0156b4c9466f1498915d"
SRC_DIR="/usr/local/src"
BIN_DEST="/usr/local/sbin/hostapd-pmkid"

if [ -x "$BIN_DEST" ] && [ "$1" != "--force" ]; then
  echo "[OK] Ya existe $BIN_DEST (usa --force para recompilar)."
  exit 0
fi

echo "[+] 1. Comprobando dependencias de compilacion..."
PAQUETES=(build-essential pkg-config libnl-3-dev libnl-genl-3-dev libssl-dev wget perl)
FALTAN=()
for pkg in "${PAQUETES[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
    FALTAN+=("$pkg")
  fi
done

if [ "${#FALTAN[@]}" -gt 0 ]; then
  echo "[!] Faltan paquetes: ${FALTAN[*]}. Instalandolos..."
  # Un mirror a medio sincronizar hace fallar el update: se sigue con los
  # indices que haya y, si falta algo de verdad, fallara el install.
  apt-get update -qq || echo "[!] apt-get update ha fallado; se usan los indices existentes."
  apt-get install -y -qq "${FALTAN[@]}"
else
  echo "    [OK] Dependencias ya instaladas."
fi

echo "[+] 2. Descargando hostapd $HOSTAPD_VER..."
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"
rm -rf "hostapd-$HOSTAPD_VER"
if [ ! -f "hostapd-$HOSTAPD_VER.tar.gz" ]; then
  wget -q "https://w1.fi/releases/hostapd-$HOSTAPD_VER.tar.gz"
fi
echo "$HOSTAPD_SHA256  hostapd-$HOSTAPD_VER.tar.gz" | sha256sum -c --quiet -
tar xzf "hostapd-$HOSTAPD_VER.tar.gz"

echo "[+] 3. Aplicando parche (PMKID en M1 tambien con WPA-PSK)..."
WPA_AUTH="hostapd-$HOSTAPD_VER/src/ap/wpa_auth.c"
sed -i 's/(wpa_key_mgmt_wpa_ieee8021x(sm->wpa_key_mgmt) ||$/(wpa_key_mgmt_wpa_ieee8021x(sm->wpa_key_mgmt) || wpa_key_mgmt_wpa_psk(sm->wpa_key_mgmt) ||/' "$WPA_AUTH"
PATCHED=$(grep -c 'wpa_key_mgmt_wpa_ieee8021x(sm->wpa_key_mgmt) || wpa_key_mgmt_wpa_psk(sm->wpa_key_mgmt) ||' "$WPA_AUTH" || true)
if [ "$PATCHED" -ne 1 ]; then
  echo "[-] ERROR: el parche debia cambiar 1 linea y ha cambiado $PATCHED."
  exit 1
fi
echo "    [OK] Parche aplicado"

# mac80211_hwsim solo genera ACK hacia interfaces activas: las tramas que el AP
# envía a una MAC inyectada desde modo monitor (hcxdumptool, reaver, bully)
# nunca se confirman. hostapd descarta la estación si no recibe el ACK de la
# Authentication o de la Association Response: el M1 con el PMKID no llega a
# salir y el EAPOL-Start de reaver se ignora. Se ignora ese ACK en
# src/ap/ieee802_11.c (handle_auth_cb y handle_assoc_cb).
echo "[+] 3b. Aplicando parche (no exigir ACK de auth/assoc response, por hwsim)..."
IEEE80211="hostapd-$HOSTAPD_VER/src/ap/ieee802_11.c"
perl -0pi -e 's/if \(!ok\) \{(\s*hostapd_logger\(hapd, mgmt->da, HOSTAPD_MODULE_IEEE80211,\s*HOSTAPD_LEVEL_\w+,\s*"did not acknowledge (?:authentication|association) response"\);)/if (0 \&\& !ok) {$1/g' "$IEEE80211"
PATCHED=$(grep -c 'if (0 && !ok) {' "$IEEE80211" || true)
if [ "$PATCHED" -ne 2 ]; then
  echo "[-] ERROR: el parche debia cambiar 2 lineas y ha cambiado $PATCHED."
  exit 1
fi
echo "    [OK] Parche aplicado"

echo "[+] 4. Configurando compilacion (con soporte WPS para he_wps)..."
cd "hostapd-$HOSTAPD_VER/hostapd"
cp defconfig .config
# En el defconfig de 2.10 la linea viene comentada (#CONFIG_WPS=y): se
# descomenta y, si no existiera, se anade.
sed -i 's/^#[[:space:]]*CONFIG_WPS=y/CONFIG_WPS=y/' .config
grep -q '^CONFIG_WPS=y' .config || echo "CONFIG_WPS=y" >> .config
echo "    [OK] CONFIG_WPS=y"

echo "[+] 5. Compilando..."
# Warnings de APIs obsoletas de OpenSSL 3: se silencian y el log va a fichero.
BUILD_LOG="/tmp/hostapd_pmkid_build.log"
if ! make -j"$(nproc)" EXTRA_CFLAGS="-Wno-deprecated-declarations" > "$BUILD_LOG" 2>&1; then
  echo "[-] ERROR al compilar. Ultimas lineas de $BUILD_LOG:"
  tail -n 20 "$BUILD_LOG"
  exit 1
fi

# Verificacion real del soporte WPS: hostapd analiza la config ANTES de tocar
# la interfaz. Sin WPS se queja de 'unknown configuration item'; con WPS solo
# falla despues porque la interfaz de prueba no existe.
PROBE="$(mktemp)"
printf 'interface=lab_wps_probe\ndriver=nl80211\nssid=probe\nwps_state=2\neap_server=1\n' > "$PROBE"
PROBE_OUT="$(timeout 5 ./hostapd "$PROBE" 2>&1 || true)"
rm -f "$PROBE"
if echo "$PROBE_OUT" | grep -q "unknown configuration item"; then
  echo "[-] ERROR: el binario compilado no reconoce las opciones de WPS."
  echo "$PROBE_OUT" | head -n 5
  exit 1
fi
echo "    [OK] Soporte WPS verificado"

install -m 755 hostapd "$BIN_DEST"

echo ""
echo "=========================================================================="
echo " [OK] hostapd parcheado instalado en $BIN_DEST"
echo "=========================================================================="
echo " despliegue.sh lo usa automaticamente para he_pmkid, he_pmkid_nc y he_wps."
echo " El hostapd del sistema (resto de escenarios) no se ha modificado."
echo "=========================================================================="