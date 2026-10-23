#!/bin/bash

# ==============================================================================
# COMPILA UN HOSTAPD PARCHEADO PARA LOS ESCENARIOS PMKID (he_pmkid, he_pmkid_nc)
#
#   El hostapd de serie no incluye el PMKID KDE en el mensaje M1 del 4-way con
#   WPA-PSK (solo con 802.1X, SAE u OWE). Para que el ejercicio PMKID del
#   laboratorio funcione, este script anade WPA-PSK a esa condicion en
#   src/ap/wpa_auth.c (estado PTKSTART) y compila el binario en:
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

echo "[+] 1. Instalando dependencias de compilacion..."
apt-get update -qq
apt-get install -y -qq build-essential pkg-config libnl-3-dev libnl-genl-3-dev libssl-dev wget

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

echo "[+] 4. Compilando..."
cd "hostapd-$HOSTAPD_VER/hostapd"
cp defconfig .config
# Warnings de APIs obsoletas de OpenSSL 3: se silencian y el log va a fichero.
BUILD_LOG="/tmp/hostapd_pmkid_build.log"
if ! make -j"$(nproc)" EXTRA_CFLAGS="-Wno-deprecated-declarations" > "$BUILD_LOG" 2>&1; then
  echo "[-] ERROR al compilar. Ultimas lineas de $BUILD_LOG:"
  tail -n 20 "$BUILD_LOG"
  exit 1
fi
install -m 755 hostapd "$BIN_DEST"

echo ""
echo "=========================================================================="
echo " [OK] hostapd parcheado instalado en $BIN_DEST"
echo "=========================================================================="
echo " despliegue.sh lo usa automaticamente para he_pmkid y he_pmkid_nc."
echo " El hostapd del sistema (resto de escenarios) no se ha modificado."
echo "=========================================================================="
