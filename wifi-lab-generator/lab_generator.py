#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ==============================================================================
# lab_generator.py — Generador de laboratorios Wi-Fi (mac80211_hwsim)
#
#   Lee un fichero de configuración que describe las redes del laboratorio y
#   genera un script de despliegue bash autónomo, del mismo estilo que el
#   despliegue.sh escrito a mano. El script generado se lleva a la VM (Kali) y
#   se ejecuta allí como root.
#
#   Uso:
#       ./lab_generator.py lab.conf                 # -> despliegue.sh
#       ./lab_generator.py lab.conf -o mi_lab.sh
#       ./lab_generator.py lab.conf --dict /ruta/diccionario.txt
#
#   Formato del fichero de configuración (ver lab.conf.example):
#       # comentarios con '#'
#       dict = /usr/share/wordlists/rockyou.txt   # directiva global
#       student_ifaces = 7                        # interfaces del alumno
#
#       # ssid, tipo, clientes [, canal]
#       he_abierta, open,  2
#       wpa2_casa,  wpa2,  1
#       pmkid_ofi,  pmkid, 1, 11
# ==============================================================================

import argparse
import datetime
import os
import re
import shutil
import sys
import textwrap

# ------------------------------------------------------------------------------
# Catálogo de tipos de escenario.
#   radios_ap     : radios para los puntos de acceso (siempre 1)
#   clientes_def  : clientes por defecto si no se indican en la conf
#   clientes_min/ : rango permitido de clientes genéricos
#   clientes_max    (los tipos con clientes FIJOS ignoran la columna y avisan)
#   clientes_fijos: None = usa la columna; un número = forzado por el escenario
#   canal_def     : canal por defecto (el usuario puede sobrescribirlo)
#   hostapd       : 'system' (hostapd del sistema) o 'pmkid' (binario parcheado)
#   feature       : marcas que activan comprobaciones en el script generado
#   desc          : pista didáctica para el resumen final
# ------------------------------------------------------------------------------
TYPES = {
    "open": dict(clientes_def=1, clientes_min=0, clientes_max=4, clientes_fijos=None,
                 canal_def=1, hostapd="system", feature=set(),
                 desc="Captura HTTP POST (texto plano)"),
    "wpa2": dict(clientes_def=2, clientes_min=0, clientes_max=4, clientes_fijos=None,
                 canal_def=6, hostapd="system", feature=set(),
                 desc="Handshake 4-Way (clave del diccionario: crackear)"),
    "pmkid": dict(clientes_def=1, clientes_min=1, clientes_max=4, clientes_fijos=None,
                  canal_def=11, hostapd="pmkid", feature={"pmkid"},
                  desc="PMKID CON clientes (clave del diccionario: crackear)"),
    "pmkid_nc": dict(clientes_def=0, clientes_min=0, clientes_max=0, clientes_fijos=0,
                     canal_def=4, hostapd="pmkid", feature={"pmkid"},
                     desc="PMKID SIN clientes (clientless)"),
    "enterprise": dict(clientes_def=1, clientes_min=0, clientes_max=4, clientes_fijos=None,
                       canal_def=3, hostapd="system", feature={"enterprise"},
                       desc="EAP-PEAP (identidad alumno@iesvjp.es; pass del diccionario)"),
    "wep": dict(clientes_def=2, clientes_min=0, clientes_max=4, clientes_fijos=None,
                canal_def=9, hostapd="system", feature=set(),
                desc="IVs / Reinyeccion ARP (clave aleatoria)"),
    "wps": dict(clientes_def=1, clientes_min=0, clientes_max=1, clientes_fijos=None,
                canal_def=7, hostapd="pmkid", feature={"pmkid", "wps"},
                desc="WPS PIN (fuerza bruta: reaver / bully)"),
    "wpa3": dict(clientes_def=1, clientes_min=0, clientes_max=4, clientes_fijos=None,
                 canal_def=5, hostapd="system", feature={"sae"},
                 desc="WPA3 puro (SAE): diccionario ONLINE"),
    "wpa3_tm": dict(clientes_def=2, clientes_min=2, clientes_max=2, clientes_fijos=2,
                    canal_def=2, hostapd="system", feature={"sae"},
                    desc="WPA3 transicion: atacar la parte WPA2"),
    "wpa3_dg": dict(clientes_def=1, clientes_min=1, clientes_max=1, clientes_fijos=1,
                    canal_def=10, hostapd="system", feature={"sae", "dg"},
                    desc="WPA3 downgrade: AP gemelo WPA2"),
}

LABS_DIR_DEFAULT = "/opt/wifi-labs"   # base donde se crean los laboratorios
MAX_RADIOS_HARD = 100       # tope del módulo mac80211_hwsim
MAX_RADIOS_WARN = 50        # a partir de aquí, aviso por RAM/CPU

# Canales por banda (regulatorio ES).
CANALES_24 = set(range(1, 14))                       # 2,4 GHz: 1-13
CANALES_5_NODFS = {36, 40, 44, 48, 149, 153, 157, 161, 165}   # UNII-1 y UNII-3
CANALES_5_DFS = {52, 56, 60, 64,                     # UNII-2A
                 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144}  # UNII-2C
CANALES_5 = CANALES_5_NODFS | CANALES_5_DFS


def banda_de_canal(ch):
    """Devuelve (banda, hw_mode, es_dfs) o lanza ConfigError si el canal no vale."""
    if ch in CANALES_24:
        return ("2.4", "g", False)
    if ch in CANALES_5_NODFS:
        return ("5", "a", False)
    if ch in CANALES_5_DFS:
        return ("5", "a", True)
    raise ConfigError(
        f"canal {ch} no válido. 2,4 GHz: 1-13. "
        f"5 GHz no-DFS: {sorted(CANALES_5_NODFS)}. "
        f"5 GHz DFS: {sorted(CANALES_5_DFS)}.")


class ConfigError(Exception):
    pass


# ------------------------------------------------------------------------------
# Parseo del fichero de configuración
# ------------------------------------------------------------------------------
def parse_config(path):
    directivas = {"dict": "/usr/share/wordlists/rockyou.txt", "student_ifaces": "7"}
    redes = []
    try:
        lineas = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        raise ConfigError(f"no se puede leer '{path}': {e}")

    for n, linea in enumerate(lineas, 1):
        # Quitar comentarios y espacios
        linea = linea.split("#", 1)[0].strip()
        if not linea:
            continue

        # Directiva: clave = valor
        if "=" in linea and "," not in linea.split("=", 1)[0]:
            clave, valor = (x.strip() for x in linea.split("=", 1))
            directivas[clave.lower()] = valor
            continue

        # Red: ssid, tipo, clientes [, canal]  (coma o espacios)
        campos = [c.strip() for c in re.split(r"[,\s]+", linea) if c.strip()]
        if len(campos) < 2:
            raise ConfigError(f"línea {n}: se esperaba 'ssid, tipo [, clientes [, canal]]': {linea!r}")

        ssid, tipo = campos[0], campos[1].lower()
        clientes = campos[2] if len(campos) >= 3 else None
        canal = campos[3] if len(campos) >= 4 else None
        redes.append(dict(linea=n, ssid=ssid, tipo=tipo, clientes=clientes, canal=canal))

    return directivas, redes


# ------------------------------------------------------------------------------
# Validación + planificación (asigna índices, interfaces, namespaces, IPs)
# ------------------------------------------------------------------------------
def planificar(directivas, redes):
    # Interfaces del alumno
    try:
        student = int(directivas.get("student_ifaces", "7"))
        if student < 1:
            raise ValueError
    except ValueError:
        raise ConfigError(f"student_ifaces debe ser un entero >= 1 (es {directivas.get('student_ifaces')!r})")

    if not redes:
        raise ConfigError("el fichero no define ninguna red")

    ssids_vistos = set()
    plan = []
    subred = 1
    for idx, r in enumerate(redes):
        ssid, tipo = r["ssid"], r["tipo"]

        if tipo not in TYPES:
            raise ConfigError(
                f"línea {r['linea']}: tipo desconocido '{tipo}'. "
                f"Válidos: {', '.join(sorted(TYPES))}")
        if ssid in ssids_vistos:
            raise ConfigError(f"línea {r['linea']}: SSID duplicado '{ssid}'")
        if len(ssid.encode()) > 32:
            raise ConfigError(f"línea {r['linea']}: SSID '{ssid}' supera 32 bytes")
        ssids_vistos.add(ssid)

        meta = TYPES[tipo]

        # Número de clientes
        if meta["clientes_fijos"] is not None:
            nclientes = meta["clientes_fijos"]
            if r["clientes"] is not None and r["clientes"].isdigit() and int(r["clientes"]) != nclientes:
                print(f"[aviso] línea {r['linea']}: '{tipo}' usa un número de clientes fijo "
                      f"({nclientes}); se ignora el {r['clientes']} indicado.", file=sys.stderr)
        else:
            if r["clientes"] is None:
                nclientes = meta["clientes_def"]
            else:
                if not r["clientes"].isdigit():
                    raise ConfigError(f"línea {r['linea']}: 'clientes' debe ser un número (es {r['clientes']!r})")
                nclientes = int(r["clientes"])
            if not (meta["clientes_min"] <= nclientes <= meta["clientes_max"]):
                raise ConfigError(
                    f"línea {r['linea']}: '{tipo}' admite entre {meta['clientes_min']} y "
                    f"{meta['clientes_max']} clientes (se pidieron {nclientes})")

        # Canal (y banda deducida)
        if r["canal"] is None:
            canal = meta["canal_def"]
        else:
            if not r["canal"].isdigit():
                raise ConfigError(f"línea {r['linea']}: el canal debe ser un número (es {r['canal']!r})")
            canal = int(r["canal"])
        try:
            banda, hw_mode, es_dfs = banda_de_canal(canal)
        except ConfigError as e:
            raise ConfigError(f"línea {r['linea']}: {e}")
        if es_dfs:
            print(f"[aviso] línea {r['linea']}: canal {canal} es DFS (5 GHz). El AP hará "
                  f"CAC (~1 min escuchando radar) antes de emitir: tardará en aparecer.",
                  file=sys.stderr)

        # Nombres de interfaz y namespace (deterministas, <= 15 chars)
        ap_iface = f"wlan_ap_{idx}"
        ap_ns = f"ns_ap_{idx}"
        if len(ap_iface) > 15:
            raise ConfigError(f"demasiados escenarios: '{ap_iface}' supera 15 caracteres")

        clientes = []
        for j in range(nclientes):
            cif = f"wlan_c{idx}_{j}"
            if len(cif) > 15:
                raise ConfigError(f"demasiados escenarios/clientes: '{cif}' supera 15 caracteres")
            clientes.append(dict(iface=cif, ns=f"ns_c{idx}_{j}", j=j))

        # El cliente efímero de pmkid_nc ocupa una radio aunque luego se desconecte
        efimero = None
        if tipo == "pmkid_nc":
            efimero = dict(iface=f"wlan_e{idx}", ns=f"ns_e{idx}")
            if len(efimero["iface"]) > 15:
                raise ConfigError(f"'{efimero['iface']}' supera 15 caracteres")

        plan.append(dict(
            idx=idx, ssid=ssid, tipo=tipo, canal=canal, subred=subred,
            banda=banda, hw_mode=hw_mode, dfs=es_dfs,
            ap_iface=ap_iface, ap_ns=ap_ns, clientes=clientes, efimero=efimero,
            hostapd=meta["hostapd"], feature=meta["feature"], desc=meta["desc"],
        ))
        subred += 1
        if subred > 254:
            raise ConfigError("más de 254 escenarios: se agotan las subredes 192.168.X.0/24")

    # Radios totales
    total = student
    for p in plan:
        total += 1 + len(p["clientes"]) + (1 if p["efimero"] else 0)

    if total > MAX_RADIOS_HARD:
        raise ConfigError(
            f"el laboratorio necesita {total} radios, pero mac80211_hwsim admite "
            f"como máximo {MAX_RADIOS_HARD}. Reduce redes o clientes.")
    if total > MAX_RADIOS_WARN:
        print(f"[aviso] el laboratorio usa {total} radios (> {MAX_RADIOS_WARN}): "
              f"asegúrate de dar suficiente RAM/CPU a la VM.", file=sys.stderr)

    # Canales compartidos (permitido, pero se avisa)
    por_canal = {}
    for p in plan:
        por_canal.setdefault(p["canal"], []).append(p["ssid"])
    for canal, ssids in sorted(por_canal.items()):
        if len(ssids) > 1:
            print(f"[info] canal {canal} compartido por: {', '.join(ssids)} "
                  f"(el alumno deberá filtrar por BSSID).", file=sys.stderr)

    features = set().union(*(p["feature"] for p in plan)) if plan else set()
    if any(p["banda"] == "5" for p in plan):
        features.add("band5")
    if any(p["dfs"] for p in plan):
        features.add("dfs")
    return dict(student=student, total=total, plan=plan, features=features,
                dict_path=directivas.get("dict", "/usr/share/wordlists/rockyou.txt"))


# ------------------------------------------------------------------------------
# Utilidades de emisión de bash
# ------------------------------------------------------------------------------
def tpl(s, **kw):
    """Sustituye @TOKEN@ por su valor. Evita el infierno de llaves de .format()."""
    for k, v in kw.items():
        s = s.replace("@" + k + "@", str(v))
    return s


def sh_q(s):
    """Comilla simple segura para bash."""
    return "'" + s.replace("'", "'\\''") + "'"


# ------------------------------------------------------------------------------
# Fragmentos de configuración por tipo (generan los .conf en el script)
# ------------------------------------------------------------------------------
def radio_lines(p):
    """Líneas de banda/canal para el hostapd.conf según el canal (2,4 o 5 GHz)."""
    out = [f"hw_mode={p['hw_mode']}", f"channel={p['canal']}"]
    if p["banda"] == "5":
        out.append("country_code=ES")
        out.append("ieee80211d=1")
        if p["dfs"]:
            out.append("ieee80211h=1")   # DFS: obligatorio para canales con radar
    return "\n".join(out)


def cfg_block(p):
    i = p["idx"]
    d = f"$LAB_DIR/s{i}"
    ap = p["ap_iface"]
    ssid = p["ssid"]
    ch = p["canal"]
    t = p["tipo"]
    radio = radio_lines(p)

    if t == "open":
        return tpl('''
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ssid=@SSID@
@RADIO@
auth_algs=1
wpa=0
EOF
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=NONE
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    if t in ("wpa2", "pmkid", "pmkid_nc"):
        okc = "okc=1" if t in ("pmkid", "pmkid_nc") else ""
        return tpl('''
K@I@="$(palabra_aleatoria)"
PSK@I@="$(calcula_pmk @SSID@ "$K@I@")"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ssid=@SSID@
@RADIO@
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_psk=$PSK@I@
@OKC@
EOF
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@
p2p_disabled=1
network={
    ssid="@SSID@"
    psk=$PSK@I@
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i, OKC=okc)

    if t == "wep":
        return tpl('''
WEP_ASCII@I@="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 13)"
WEP_HEX@I@="$(printf '%s' "$WEP_ASCII@I@" | od -An -tx1 | tr -d ' \\n')"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ssid=@SSID@
@RADIO@
auth_algs=1
wep_default_key=0
wep_key0=$WEP_HEX@I@
EOF
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=NONE
    wep_key0=$WEP_HEX@I@
    wep_tx_keyidx=0
    auth_alg=OPEN
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    if t == "enterprise":
        return tpl('''
CERT_DIR@I@="@D@/certs"
mkdir -p "$CERT_DIR@I@"
if [ ! -s "$CERT_DIR@I@/server.pem" ] || [ ! -s "$CERT_DIR@I@/server.key" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \\
    -subj "/C=ES/O=HE Lab/CN=radius.domain.lab" \\
    -keyout "$CERT_DIR@I@/server.key" -out "$CERT_DIR@I@/server.pem" > /dev/null 2>&1
  chmod 600 "$CERT_DIR@I@/server.key"
fi
K@I@="$(palabra_aleatoria)"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ssid=@SSID@
@RADIO@
wpa=2
wpa_key_mgmt=WPA-EAP
rsn_pairwise=CCMP
ieee8021x=1
disable_pmksa_caching=1
eap_server=1
eap_user_file=@D@/eap_user.conf
ca_cert=$CERT_DIR@I@/server.pem
server_cert=$CERT_DIR@I@/server.pem
private_key=$CERT_DIR@I@/server.key
EOF
cat << EOF > "@D@/eap_user.conf"
*                          PEAP
"alumno@iesvjp.es"  MSCHAPV2  "$K@I@"  [2]
EOF
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="alumno@iesvjp.es"
    password="$K@I@"
    phase2="auth=MSCHAPV2"
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    if t == "wps":
        return tpl('''
WPS_PIN7@I@="$(printf '%04d' $((RANDOM % 100)))$(printf '%03d' $((RANDOM % 100)))"
WPS_PIN@I@="${WPS_PIN7@I@}$(wps_checksum "$WPS_PIN7@I@")"
WPS_PASS@I@="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ctrl_interface=/var/run/hostapd_wps_@I@
ssid=@SSID@
@RADIO@
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$WPS_PASS@I@
wps_state=2
eap_server=1
ap_pin=$WPS_PIN@I@
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
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@
p2p_disabled=1
network={
    ssid="@SSID@"
    psk="$WPS_PASS@I@"
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    if t == "wpa3":
        return tpl('''
K@I@="$(palabra_aleatoria)"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ssid=@SSID@
@RADIO@
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
sae_password=$K@I@
ieee80211w=2
EOF
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=SAE
    sae_password="$K@I@"
    ieee80211w=2
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    if t == "wpa3_tm":
        return tpl('''
K@I@="$(palabra_aleatoria)"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ssid=@SSID@
@RADIO@
wpa=2
wpa_key_mgmt=WPA-PSK SAE
rsn_pairwise=CCMP
wpa_passphrase=$K@I@
ieee80211w=1
sae_require_mfp=1
EOF
cat << EOF > "@D@/cli_sae.conf"
ctrl_interface=/var/run/wsup_@I@_0
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=SAE
    psk="$K@I@"
    ieee80211w=2
}
EOF
cat << EOF > "@D@/cli_wpa2.conf"
ctrl_interface=/var/run/wsup_@I@_1
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=WPA-PSK
    psk="$K@I@"
    ieee80211w=0
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    if t == "wpa3_dg":
        return tpl('''
K@I@="$(palabra_aleatoria)"
cat << EOF > "@D@/hostapd.conf"
interface=@AP@
driver=nl80211
ctrl_interface=/var/run/hostapd_dg_@I@
ssid=@SSID@
@RADIO@
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
sae_password=$K@I@
ieee80211w=2
EOF
if [ "$DG_TRANSITION_DISABLE" = "1" ]; then
  echo "transition_disable=0x01" >> "@D@/hostapd.conf"
fi
cat << EOF > "@D@/cli.conf"
ctrl_interface=/var/run/wsup_@I@_0
p2p_disabled=1
network={
    ssid="@SSID@"
    key_mgmt=SAE WPA-PSK
    psk="$K@I@"
    ieee80211w=1
}
EOF
''', D=d, AP=ap, SSID=ssid, CH=ch, RADIO=radio, I=i)

    raise ConfigError(f"tipo sin plantilla de configuración: {t}")


# ------------------------------------------------------------------------------
# Fragmentos de arranque de clientes/tráfico por tipo
# ------------------------------------------------------------------------------
def cli_block(p):
    i = p["idx"]
    d = f"$LAB_DIR/s{i}"
    t = p["tipo"]
    gw = f"192.168.{p['subred']}.1"
    wait = 90 if p["dfs"] else 15   # DFS: el cliente no asocia hasta que acabe el CAC
    out = []

    def ping(ns, iface):
        return (f'ip netns exec {ns} sh -c ": LAB_TRAFFIC; '
                f'while true; do ping -i 1 {gw} > /dev/null 2>&1; done" &\n')

    if t == "open":
        for c in p["clientes"]:
            ip = f"192.168.{p['subred']}.{10 + c['j']}"
            out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
sleep 1
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
CLAVE_OPEN@I@="$(palabra_aleatoria)"
ip netns exec @NS@ sh -c ": LAB_TRAFFIC; while true; do curl -s -m 1 -X POST -d \\"user=admin&pass=$CLAVE_OPEN@I@\\" http://@GW@/login.php > /dev/null 2>&1 || true; sleep 1; done" &
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip, GW=gw))
        return "".join(out)

    if t in ("wpa2", "pmkid"):
        for c in p["clientes"]:
            ip = f"192.168.{p['subred']}.{10 + c['j']}"
            out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
sleep 1
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip))
            out.append(ping(c["ns"], c["iface"]))
        return "".join(out)

    if t == "wep":
        for c in p["clientes"]:
            ip = f"192.168.{p['subred']}.{10 + c['j']}"
            dead = f"192.168.{p['subred']}.{200 + c['j']}"
            out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
sleep 1
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
ip netns exec @NS@ sh -c ": LAB_TRAFFIC; while true; do ip neigh flush all dev @IF@ >/dev/null 2>&1; ping -c1 -W1 @DEAD@ >/dev/null 2>&1; sleep 0.3; done" &
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip, DEAD=dead))
        return "".join(out)

    if t == "pmkid_nc":
        e = p["efimero"]
        ip = f"192.168.{p['subred']}.10"
        out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
NC_OK=0
for _ in $(seq 1 15); do
  if ip netns exec @NS@ wpa_cli -p /var/run/wsup_@I@ -i @IF@ status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then NC_OK=1; break; fi
  sleep 1
done
[ "$NC_OK" -eq 1 ] && echo "  [OK] @SSID@: cliente efímero asoció (y se desconecta)" || echo "  [!] @SSID@: el cliente efímero no asoció"
ip netns exec @NS@ wpa_cli -p /var/run/wsup_@I@ -i @IF@ terminate > /dev/null 2>&1 || true
sleep 1
ip netns exec @NS@ iw dev @IF@ disconnect 2>/dev/null || true
''', I=i, NS=e["ns"], IF=e["iface"], D=d, SSID=p["ssid"]))
        return "".join(out)

    if t == "enterprise":
        for c in p["clientes"]:
            ip = f"192.168.{p['subred']}.{10 + c['j']}"
            out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
ENT_OK=0
for _ in $(seq 1 15); do
  if ip netns exec @NS@ wpa_cli -p /var/run/wsup_@I@ -i @IF@ status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then ENT_OK=1; break; fi
  sleep 1
done
[ "$ENT_OK" -eq 1 ] && echo "  [OK] @SSID@: cliente EAP autenticado" || echo "  [!] @SSID@: cliente EAP NO autenticado"
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
ip netns exec @NS@ sh -c ": LAB_TRAFFIC; while true; do ping -i 1 @GW@ > /dev/null 2>&1; done" &
ip netns exec @NS@ sh -c ": LAB_TRAFFIC; while true; do sleep 30; wpa_cli -p /var/run/wsup_@I@ -i @IF@ reassociate > /dev/null 2>&1; done" &
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip, GW=gw, SSID=p["ssid"]))
        return "".join(out)

    if t == "wps":
        for c in p["clientes"]:
            ip = f"192.168.{p['subred']}.{10 + c['j']}"
            out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
sleep 1
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip))
            out.append(ping(c["ns"], c["iface"]))
        # Watchdog anti-lockout (desbloquea el PIN cada segundo)
        out.append(tpl('''ip netns exec @NS@ sh -c "
  : LAB_WPS_WATCHDOG
  CLI='$HOSTAPD_CLI -p /var/run/hostapd_wps_@I@ -i @AP@'
  while true; do
    P=\\$(\\$CLI wps_ap_pin get 2>/dev/null)
    if echo \\"\\$P\\" | grep -qE '^[0-9]{8}\\$'; then \\$CLI wps_ap_pin set \\"\\$P\\" 0 > /dev/null 2>&1; fi
    sleep 1
  done
" &
''', NS=p["ap_ns"], I=i, AP=p["ap_iface"]))
        return "".join(out)

    if t == "wpa3":
        for c in p["clientes"]:
            ip = f"192.168.{p['subred']}.{10 + c['j']}"
            out.append(tpl('''mkdir -p /var/run/wsup_@I@
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
esperar_cliente @NS@ @IF@ /var/run/wsup_@I@ "@SSID@ (SAE)" @WAIT@
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip, SSID=p["ssid"], WAIT=wait))
            out.append(ping(c["ns"], c["iface"]))
            # reasociación para captura pasiva del SAE
            out.append(tpl('''ip netns exec @NS@ sh -c ": LAB_TRAFFIC; while true; do sleep 30; wpa_cli -p /var/run/wsup_@I@ -i @IF@ reassociate > /dev/null 2>&1; done" &
''', NS=c["ns"], I=i, IF=c["iface"]))
        return "".join(out)

    if t == "wpa3_tm":
        csae, cwpa2 = p["clientes"][0], p["clientes"][1]
        ipsae = f"192.168.{p['subred']}.10"
        ipw2 = f"192.168.{p['subred']}.20"
        out.append(tpl('''mkdir -p /var/run/wsup_@I@_0 /var/run/wsup_@I@_1
ip netns exec @NSS@ wpa_supplicant -B -Dnl80211 -i @IFS@ -c "@D@/cli_sae.conf"
ip netns exec @NSW@ wpa_supplicant -B -Dnl80211 -i @IFW@ -c "@D@/cli_wpa2.conf"
esperar_cliente @NSS@ @IFS@ /var/run/wsup_@I@_0 "@SSID@ (WPA3/SAE)" @WAIT@
esperar_cliente @NSW@ @IFW@ /var/run/wsup_@I@_1 "@SSID@ (WPA2 antiguo)" @WAIT@
ip netns exec @NSS@ ip addr add @IPS@/24 dev @IFS@
ip netns exec @NSW@ ip addr add @IPW@/24 dev @IFW@
ip netns exec @NSS@ sh -c ": LAB_TRAFFIC; while true; do ping -i 1 @GW@ > /dev/null 2>&1; done" &
ip netns exec @NSW@ sh -c ": LAB_TRAFFIC; while true; do ping -i 1 @GW@ > /dev/null 2>&1; done" &
''', I=i, D=d, GW=gw, SSID=p["ssid"],
             NSS=csae["ns"], IFS=csae["iface"], IPS=ipsae,
             NSW=cwpa2["ns"], IFW=cwpa2["iface"], IPW=ipw2, WAIT=wait))
        return "".join(out)

    if t == "wpa3_dg":
        c = p["clientes"][0]
        ip = f"192.168.{p['subred']}.10"
        out.append(tpl('''mkdir -p /var/run/wsup_@I@_0
ip netns exec @NS@ wpa_supplicant -B -Dnl80211 -i @IF@ -c "@D@/cli.conf"
esperar_cliente @NS@ @IF@ /var/run/wsup_@I@_0 "@SSID@ (SAE, perfil con WPA2)" @WAIT@
ip netns exec @NS@ ip addr add @IP@/24 dev @IF@
ip netns exec @NS@ sh -c ": LAB_TRAFFIC; while true; do ping -i 1 @GW@ > /dev/null 2>&1; done" &
ip netns exec @NS@ sh -c ": LAB_TRAFFIC; C='wpa_cli -p /var/run/wsup_@I@_0 -i @IF@'; while true; do sleep 30; \\$C select_network 0 > /dev/null 2>&1; sleep 1; \\$C reassociate > /dev/null 2>&1; done" &
''', I=i, NS=c["ns"], IF=c["iface"], D=d, IP=ip, GW=gw, SSID=p["ssid"], WAIT=wait))
        return "".join(out)

    raise ConfigError(f"tipo sin plantilla de clientes: {t}")


# ------------------------------------------------------------------------------
# Ensamblado del script bash completo
# ------------------------------------------------------------------------------
def emitir(cfg, conf_path):
    plan = cfg["plan"]
    feats = cfg["features"]
    L = []
    a = L.append

    fecha = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    a("#!/bin/bash")
    a("# " + "=" * 76)
    a("# SCRIPT DE DESPLIEGUE GENERADO POR lab_generator.py")
    a(f"#   Fichero de configuración: {os.path.basename(conf_path)}")
    a(f"#   Generado: {fecha}")
    a(f"#   Radios: {cfg['total']} ({cfg['student']} del alumno + "
      f"{cfg['total'] - cfg['student']} del laboratorio)")
    a("#   NO editar a mano: regenera con lab_generator.py si cambias la conf.")
    a("# " + "=" * 76)
    a("")
    a("set -e")
    a('if [ "$EUID" -ne 0 ]; then echo "[-] Ejecuta como root (sudo)."; exit 1; fi')
    a("")

    # Paquetes (según lo que use el lab)
    paquetes = ["hostapd", "wpasupplicant", "iw"]
    if "pmkid" in feats or "sae" in feats:
        paquetes += ["hcxtools", "pocl-opencl-icd", "ocl-icd-libopencl1"]
    if "enterprise" in feats:
        paquetes += ["hostapd-wpe", "openssl"]
    paquetes.append("net-tools")  # nc para el servidor HTTP del open
    a("PAQUETES=(" + " ".join(sorted(set(paquetes))) + ")")
    a(textwrap.dedent('''\
        FALTAN=()
        for pkg in "${PAQUETES[@]}"; do
          dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || FALTAN+=("$pkg")
        done
        if [ "${#FALTAN[@]}" -gt 0 ]; then
          echo "[!] Instalando: ${FALTAN[*]}"
          apt-get update -qq || true
          apt-get install -y -qq "${FALTAN[@]}"
          if [[ " ${FALTAN[*]} " == *" hostapd "* ]]; then
            systemctl disable --now hostapd >/dev/null 2>&1 || true
            systemctl unmask hostapd >/dev/null 2>&1 || true
          fi
        fi'''))
    a("")
    a('LAB_DIR="/opt/wifi-lab"')
    if "dg" in feats:
        a('DG_TRANSITION_DISABLE="${DG_TRANSITION_DISABLE:-0}"')
    a("")

    # Diccionario (parámetro $1, por defecto el de la conf)
    a(tpl('DICCIONARIO="${1:-@DICT@}"', DICT=cfg["dict_path"]))
    a(textwrap.dedent('''\
        if [ ! -r "$DICCIONARIO" ]; then
          if [ -r "$DICCIONARIO.gz" ]; then
            echo "[-] $DICCIONARIO está comprimido. Ejecuta: sudo gunzip $DICCIONARIO.gz"
          else
            echo "[-] No se puede leer el diccionario: $DICCIONARIO"
            echo "    Indica otro:  sudo $0 /ruta/diccionario.txt"
          fi
          exit 1
        fi
        DICC_FILTRADO="$(mktemp)"
        LC_ALL=C grep -aE '^[ -~]{8,63}$' "$DICCIONARIO" | LC_ALL=C grep -av '["\\\\]' > "$DICC_FILTRADO" || true
        if [ ! -s "$DICC_FILTRADO" ]; then
          echo "[-] El diccionario no tiene palabras válidas (8-63 ASCII)."; rm -f "$DICC_FILTRADO"; exit 1
        fi
        echo "[+] Diccionario: $DICCIONARIO ($(wc -l < "$DICC_FILTRADO") claves candidatas)"
        palabra_aleatoria() { shuf -n1 "$DICC_FILTRADO"; }
        if ! command -v wpa_passphrase >/dev/null 2>&1; then
          echo "[-] Falta wpa_passphrase (paquete wpasupplicant)."; rm -f "$DICC_FILTRADO"; exit 1
        fi
        calcula_pmk() { wpa_passphrase "$1" "$2" | sed -n 's/^\\tpsk=//p'; }'''))
    a("")

    # Checksum WPS si hace falta
    if "wps" in feats:
        a(textwrap.dedent('''\
            wps_checksum() {
              local p=$((10#$1)) acc=0
              while [ "$p" -gt 0 ]; do
                acc=$((acc + 3 * (p % 10))); p=$((p / 10))
                acc=$((acc + p % 10));       p=$((p / 10))
              done
              echo $(( (10 - acc % 10) % 10 ))
            }'''))
        a("")

    # Helper esperar_cliente (lo usan sae/enterprise/etc.)
    a(textwrap.dedent('''\
        esperar_cliente() {   # ns iface ctrl etiqueta [timeout_seg]
          local k top="${5:-15}"
          for k in $(seq 1 "$top"); do
            if ip netns exec "$1" wpa_cli -p "$3" -i "$2" status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
              echo "  [OK] Cliente $4 conectado"; return 0
            fi
            sleep 1
          done
          echo "  [!] Cliente $4 NO conectó"; return 0
        }'''))
    a("")

    # Limpieza
    a('echo "[+] 1. Limpiando entorno previo..."')
    a("pkill -9 -f LAB_WPS_WATCHDOG 2>/dev/null || true")
    a("pkill -9 -f LAB_TRAFFIC 2>/dev/null || true")
    a("for b in hostapd hostapd-wpe wpa_supplicant nc curl ping arping; do pkill -9 \"$b\" 2>/dev/null || true; done")
    a("rm -rf /var/run/wsup_* /var/run/hostapd_wps_* /var/run/hostapd_dg_* 2>/dev/null || true")
    a(textwrap.dedent('''\
        for ns in $(ip netns list | awk '{print $1}'); do
          case "$ns" in ns_*) ip netns del "$ns" 2>/dev/null || true ;; esac
        done
        NM_CONF="/etc/NetworkManager/conf.d/99-wifi-lab.conf"
        if [ -d /etc/NetworkManager/conf.d ]; then
          printf '[keyfile]\\nunmanaged-devices+=driver:mac80211_hwsim\\n' > "$NM_CONF"
          nmcli general reload conf 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
        fi
        modprobe -r mac80211_hwsim 2>/dev/null || true
        sleep 2'''))
    a("")

    # Carga del módulo
    a(tpl('echo "[+] 2. Cargando mac80211_hwsim (@N@ radios)..."', N=cfg["total"]))
    a(tpl("modprobe mac80211_hwsim radios=@N@", N=cfg["total"]))
    a("sleep 2")
    a("rfkill unblock all 2>/dev/null || true")
    if "band5" in feats:
        a('# Regulatorio para 5 GHz (canales UNII y DFS).')
        a('iw reg set ES 2>/dev/null || true')
        a('sleep 1')
    a("")

    # TARGETS: interfaces del alumno + las del laboratorio
    student_ifaces = [f"wlan{n}" for n in range(cfg["student"])]
    lab_ifaces = []
    for p in plan:
        lab_ifaces.append(p["ap_iface"])
        for c in p["clientes"]:
            lab_ifaces.append(c["iface"])
        if p["efimero"]:
            lab_ifaces.append(p["efimero"]["iface"])
    targets = student_ifaces + lab_ifaces

    a('echo "[+] 3. Asignando nombres de interfaz..."')
    a("TARGETS=(")
    for t in targets:
        a(f"  {t}")
    a(")")
    a(textwrap.dedent(tpl('''\
        mapfile -t HW_IFS < <(ip link show | grep -oP '(?<=: )\\b(wlan|wfx)\\d+\\b' | sort -V)
        if [ "${#HW_IFS[@]}" -lt @N@ ]; then
          echo "[-] ERROR: se esperaban @N@ interfaces, hay ${#HW_IFS[@]}."; exit 1
        fi
        for idx in "${!TARGETS[@]}"; do
          orig="${HW_IFS[$idx]}"; target="${TARGETS[$idx]}"
          [ "${#target}" -gt 15 ] && { echo "[-] '$target' supera 15 caracteres"; exit 1; }
          if [ -n "$orig" ] && [ "$orig" != "$target" ]; then
            ip link set "$orig" down 2>/dev/null || true
            ip link set "$orig" name "$target" 2>/dev/null || { echo "[-] no se pudo renombrar $orig"; exit 1; }
          fi
        done
        for target in "${TARGETS[@]}"; do nmcli dev set "$target" managed no 2>/dev/null || true; done
        sleep 1''', N=cfg["total"])))
    a("")

    # Binarios hostapd y comprobaciones condicionales
    a('HOSTAPD_SYS="$(command -v hostapd || echo /usr/sbin/hostapd)"')
    a('[ -x "$HOSTAPD_SYS" ] || { echo "[-] no se encuentra hostapd"; exit 1; }')
    if "wps" in feats:
        a('HOSTAPD_CLI="$(command -v hostapd_cli || echo /usr/sbin/hostapd_cli)"')
        a('[ -x "$HOSTAPD_CLI" ] || { echo "[-] no se encuentra hostapd_cli"; exit 1; }')
    if "pmkid" in feats:
        a(textwrap.dedent('''\
            HOSTAPD_PMKID="/usr/local/sbin/hostapd-pmkid"
            if [ ! -x "$HOSTAPD_PMKID" ]; then
              SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
              if [ -x "$SCRIPT_DIR/compila_hostapd_pmkid.sh" ]; then
                "$SCRIPT_DIR/compila_hostapd_pmkid.sh"
              else
                echo "[-] Falta $HOSTAPD_PMKID y compila_hostapd_pmkid.sh."; exit 1
              fi
            fi'''))
    if "wps" in feats:
        a(textwrap.dedent('''\
            # El escenario WPS necesita que hostapd-pmkid tenga CONFIG_WPS=y. Si el
            # binario existe pero se compiló sin WPS, se recompila SOLO (--force) para
            # que el alumno no tenga que hacer nada a mano.
            wps_soportado() {
              local probe out
              probe="$(mktemp)"
              printf 'interface=lab_wps_probe\\ndriver=nl80211\\nssid=probe\\nwps_state=2\\neap_server=1\\n' > "$probe"
              out="$(timeout 5 "$HOSTAPD_PMKID" "$probe" 2>&1 || true)"
              rm -f "$probe"
              ! echo "$out" | grep -q "unknown configuration item 'wps_state'"
            }
            if ! wps_soportado; then
              echo "[!] hostapd-pmkid sin soporte WPS: recompilando automaticamente..."
              SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
              if [ -x "$SCRIPT_DIR/compila_hostapd_pmkid.sh" ]; then
                "$SCRIPT_DIR/compila_hostapd_pmkid.sh" --force
              else
                echo "[-] Falta compila_hostapd_pmkid.sh para recompilar con WPS."; exit 1
              fi
              if ! wps_soportado; then
                echo "[-] Tras recompilar, hostapd-pmkid sigue sin WPS. Revisa compila_hostapd_pmkid.sh."; exit 1
              fi
            fi'''))
    if "sae" in feats:
        a(textwrap.dedent('''\
            SAE_PROBE="$(mktemp)"
            printf 'interface=lab_sae_probe\\ndriver=nl80211\\nssid=probe\\nwpa=2\\nwpa_key_mgmt=SAE\\nrsn_pairwise=CCMP\\nieee80211w=2\\nsae_password=probe1234\\n' > "$SAE_PROBE"
            if timeout 5 "$HOSTAPD_SYS" "$SAE_PROBE" 2>&1 | grep -qiE "invalid key_mgmt|unknown configuration item"; then
              echo "[-] El hostapd del sistema no tiene soporte SAE (WPA3)."; rm -f "$SAE_PROBE"; exit 1
            fi
            rm -f "$SAE_PROBE"'''))
    a("")

    # Directorios y configuraciones
    a('echo "[+] 4. Generando configuraciones..."')
    a("mkdir -p " + " ".join(f'"$LAB_DIR/s{p["idx"]}"' for p in plan))
    for p in plan:
        a(tpl("# --- s@I@ : @SSID@ (@T@, canal @CH@) ---",
              I=p["idx"], SSID=p["ssid"], T=p["tipo"], CH=p["canal"]))
        a(cfg_block(p).strip("\n"))
    a("")

    # Namespaces (AP + clientes + efímero)
    a('echo "[+] 5. Creando namespaces y aislando radios..."')
    a(textwrap.dedent('''\
        mover_a_ns() {   # ns iface
          ip netns add "$1"
          local phy; phy=$(iw dev "$2" info | grep wiphy | awk '{print "phy"$2}')
          iw phy "$phy" set netns name "$1"
          ip netns exec "$1" ip link set "$2" up
          ip netns exec "$1" ip link set lo up
        }'''))
    for p in plan:
        a(f'mover_a_ns {p["ap_ns"]} {p["ap_iface"]}')
        for c in p["clientes"]:
            a(f'mover_a_ns {c["ns"]} {c["iface"]}')
        if p["efimero"]:
            a(f'mover_a_ns {p["efimero"]["ns"]} {p["efimero"]["iface"]}')
    a(tpl("for i in $(seq 0 @LAST@); do ip link set \"wlan$i\" up 2>/dev/null || true; done",
          LAST=cfg["student"] - 1))
    a("")

    # Arranque de APs
    a('echo "[+] 6. Arrancando puntos de acceso..."')
    for p in plan:
        binario = '"$HOSTAPD_PMKID"' if p["hostapd"] == "pmkid" else '"$HOSTAPD_SYS"'
        a(f'ip netns exec {p["ap_ns"]} {binario} -B "$LAB_DIR/s{p["idx"]}/hostapd.conf"')
        a(f'ip netns exec {p["ap_ns"]} ip addr add 192.168.{p["subred"]}.1/24 dev {p["ap_iface"]}')
        if p["dfs"]:
            a(f'echo "  [i] {p["ssid"]} en canal DFS {p["canal"]} (5 GHz): CAC ~1 min, tardará en emitir y en aceptar clientes."')
    a("sleep 2")
    a("")

    # Servidor HTTP para los open
    open_present = [p for p in plan if p["tipo"] == "open"]
    if open_present:
        a('echo "[+] 7. Servidor HTTP en las redes abiertas..."')
        for p in open_present:
            a(tpl('ip netns exec @NS@ sh -c "while true; do echo -e '
                  "'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nOK'"
                  ' | nc -l -p 80 > /dev/null 2>&1; done" &', NS=p["ap_ns"]))
        a("")

    # Clientes y tráfico
    a('echo "[+] 8. Conectando clientes y generando tráfico..."')
    for p in plan:
        if p["clientes"] or p["efimero"]:
            a(tpl("# --- clientes de s@I@ : @SSID@ ---", I=p["idx"], SSID=p["ssid"]))
        blk = cli_block(p).strip("\n")
        if blk:
            a(blk)
    if "dg" in feats:
        a('[ "$DG_TRANSITION_DISABLE" = "1" ] && echo "  [i] Transition Disable ACTIVO (mitigacion downgrade)"')
    a("sleep 1")
    a("")

    # Resumen (BSSID reales)
    a("get_bssid() { ip netns exec \"$1\" cat \"/sys/class/net/$2/address\" 2>/dev/null; }")
    for p in plan:
        a(f'BSSID{p["idx"]}=$(get_bssid {p["ap_ns"]} {p["ap_iface"]})')
    a('rm -f "$DICC_FILTRADO" 2>/dev/null || true')
    a("")

    # Anti-cheat: borrar confs
    a('echo "[+] 9. Borrando configuraciones en disco (anti-cheat)..."')
    a("rm -f " + " ".join(f'"$LAB_DIR/s{p["idx"]}"/*.conf' for p in plan) + " 2>/dev/null || true")
    a("")

    # Cuadro final
    a('echo ""')
    a('echo "=========================================================================="')
    a(tpl('echo " [OK] LABORATORIO WI-FI (@N@ escenarios)"', N=len(plan)))
    a('echo "=========================================================================="')
    a(tpl('echo "Interfaces del alumno: wlan0 a wlan@LAST@"', LAST=cfg["student"] - 1))
    a('echo ""')
    for p in plan:
        linea = (f'echo " - {p["ssid"]:<16} (Ch {p["canal"]:<2}, BSSID $BSSID{p["idx"]})'
                 f'  -> {p["desc"]}"')
        a(linea)
    a('echo "=========================================================================="')
    a('echo "Las claves cambian en cada despliegue (del diccionario). Consultalas con"')
    a('echo "hostapd_cli / wpa_cli, o crackeando con el mismo diccionario."')
    a('echo "=========================================================================="')
    a("")

    return "\n".join(L) + "\n"


# ------------------------------------------------------------------------------
def copiar_auxiliar(nombre, destino_dir):
    """Copia un script auxiliar (si existe junto al generador) al directorio del
    laboratorio y lo deja ejecutable. Devuelve True si lo copió."""
    origen = os.path.join(os.path.dirname(os.path.abspath(__file__)), nombre)
    if not os.path.isfile(origen):
        print(f"[aviso] no encuentro '{nombre}' junto al generador; "
              f"cópialo a mano en el laboratorio si hace falta.", file=sys.stderr)
        return False
    dst = os.path.join(destino_dir, nombre)
    shutil.copy2(origen, dst)
    os.chmod(dst, 0o755)
    return True


def main():
    ap = argparse.ArgumentParser(
        description="Genera un laboratorio Wi-Fi (script de despliegue) a partir de un .conf")
    ap.add_argument("config", help="fichero de configuración del laboratorio")
    ap.add_argument("name", nargs="?",
                    help="nombre del laboratorio: crea una carpeta con ese nombre (por defecto "
                         "en " + LABS_DIR_DEFAULT + ") y mete dentro todos los ficheros. Si se "
                         "omite, se genera un único script en el directorio actual.")
    ap.add_argument("--labs-dir", default=LABS_DIR_DEFAULT,
                    help="directorio base donde crear los laboratorios (def: %(default)s)")
    ap.add_argument("-o", "--output",
                    help="nombre del script de despliegue (def: despliegue.sh)")
    ap.add_argument("--dict", help="sobrescribe la directiva 'dict' del fichero")
    ap.add_argument("-f", "--force", action="store_true",
                    help="sobrescribe el directorio del laboratorio si ya existe")
    args = ap.parse_args()

    try:
        directivas, redes = parse_config(args.config)
        if args.dict:
            directivas["dict"] = args.dict
        cfg = planificar(directivas, redes)
        script = emitir(cfg, args.config)
    except ConfigError as e:
        print(f"[-] Error de configuración: {e}", file=sys.stderr)
        sys.exit(1)

    script_name = args.output or "despliegue.sh"

    # ---- Modo directorio: lab_generator.py CONFIG NOMBRE ----
    if args.name:
        # Si el nombre es una ruta (absoluta o con '/'), se respeta tal cual;
        # si es un nombre simple, se crea dentro del directorio base (--labs-dir).
        if os.path.isabs(args.name) or os.sep in args.name:
            labdir = args.name
        else:
            labdir = os.path.join(args.labs_dir, args.name)

        # Crear el directorio base si no existe
        base = os.path.dirname(os.path.abspath(labdir))
        try:
            os.makedirs(base, exist_ok=True)
        except PermissionError:
            print(f"[-] Sin permisos para crear '{base}'. Ejecuta con sudo o usa "
                  f"--labs-dir en una ruta donde puedas escribir.", file=sys.stderr)
            sys.exit(1)

        if os.path.exists(labdir):
            if not os.path.isdir(labdir):
                print(f"[-] '{labdir}' existe y no es un directorio.", file=sys.stderr)
                sys.exit(1)
            if not args.force:
                print(f"[-] El directorio '{labdir}' ya existe. Usa -f para sobrescribirlo.",
                      file=sys.stderr)
                sys.exit(1)
        try:
            os.makedirs(labdir, exist_ok=True)
        except PermissionError:
            print(f"[-] Sin permisos para crear '{labdir}'. Ejecuta con sudo o usa "
                  f"--labs-dir en una ruta donde puedas escribir.", file=sys.stderr)
            sys.exit(1)

        # Script de despliegue
        ruta_script = os.path.join(labdir, script_name)
        with open(ruta_script, "w", encoding="utf-8") as f:
            f.write(script)
        os.chmod(ruta_script, 0o755)

        # Copia del .conf (reproducibilidad: regenerar el mismo lab más tarde)
        shutil.copy2(args.config, os.path.join(labdir, "lab.conf"))

        # Scripts auxiliares SOLO si este laboratorio los necesita
        copiados = []
        if "pmkid" in cfg["features"]:
            if copiar_auxiliar("compila_hostapd_pmkid.sh", labdir):
                copiados.append("compila_hostapd_pmkid.sh")
        if "sae" in cfg["features"]:
            if copiar_auxiliar("sae_online.sh", labdir):
                copiados.append("sae_online.sh")

        ruta_abs = os.path.abspath(labdir)
        print(f"[OK] Laboratorio creado en {ruta_abs}/ "
              f"({len(cfg['plan'])} escenarios, {cfg['total']} radios)")
        print(f"     - {script_name}      (script de despliegue)")
        print(f"     - lab.conf          (copia de la configuración)")
        for c in copiados:
            print(f"     - {c}")
        print(f"     Despliega:  cd {ruta_abs} && sudo ./{script_name}")
        return

    # ---- Modo fichero único: lab_generator.py CONFIG [-o SALIDA] ----
    with open(script_name, "w", encoding="utf-8") as f:
        f.write(script)
    os.chmod(script_name, 0o755)
    print(f"[OK] Generado {script_name}  ({len(cfg['plan'])} escenarios, {cfg['total']} radios)")
    print(f"     Despliega en la VM:  sudo ./{os.path.basename(script_name)}")


if __name__ == "__main__":
    main()