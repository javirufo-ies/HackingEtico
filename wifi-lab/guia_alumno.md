# Guía del alumno — Laboratorio Wi-Fi (Hacking Ético)

> **Entorno 100 % virtualizado.** Todas las redes de esta práctica son radios
> simuladas con `mac80211_hwsim` dentro de tu máquina. No se emite nada por
> radio real y los ataques solo funcionan contra los puntos de acceso del
> laboratorio. **Uso exclusivamente educativo.** Atacar redes reales sin
> autorización expresa por escrito es delito (en España, arts. 197 bis y 264
> del Código Penal).

---

## 0. Puesta en marcha

```bash
sudo ./despliegue.sh
```

Al terminar, el script muestra el **SSID, canal y BSSID** de cada red. Los
BSSID cambian cada vez que despliegas el laboratorio, así que apúntalos en cada
sesión. Para desmontarlo todo: `sudo ./limpia.sh`.

### Reglas del laboratorio

- Tus interfaces de trabajo son **`wlan0` … `wlan6`**. Puedes usar varias a la
  vez.
- No toques las interfaces `wlan_ap_*` / `wlan_cli*` ni los *network namespaces*
  `ns_*`: son la infraestructura de los escenarios.
- Las claves de las redes **no están en claro** en el sistema. No está
  permitido sacar resultados leyendo los scripts o la configuración del
  laboratorio: cada resultado debe salir del ataque a la red correspondiente.
- Herramientas disponibles: suite **aircrack-ng**, **hcxdumptool /
  hcxtools**, **hashcat**, **tshark / Wireshark**. Diccionario:
  `/usr/share/wordlists/rockyou.txt`.

---

## Escenarios

| SSID            | Canal | Seguridad | Qué tienes que conseguir |
|-----------------|-------|-----------|--------------------------|
| `he_open`       | 1     | Abierta   | Las credenciales que envía un cliente |
| `he_wep`        | 9     | WEP       | La clave de la red |
| `he_wpa2`       | 6     | WPA2-PSK  | La clave de la red |
| `he_pmkid`      | 11    | WPA2-PSK  | La clave de la red |
| `he_pmkid_nc`   | 4     | WPA2-PSK  | La clave de la red |
| `he_enterprise` | 3     | WPA2-EAP  | La identidad del usuario y el método EAP |

En cada escenario debes investigar qué técnica es la adecuada, aplicarla y
documentarla.

---

## 1. `he_open` — Red abierta

Hay un cliente conectado que inicia sesión periódicamente en una aplicación web.

**Objetivo:** obtener el usuario y la contraseña que envía.

**Preguntas:**

1. ¿Por qué has podido leer las credenciales? ¿Qué capa debería haberlas
   protegido?
2. ¿Cambiaría algo si la web usara HTTPS? ¿Y si la red fuera WPA2-PSK y tú
   conocieras la clave?

---

## 2. `he_wep` — WEP

Red WEP con clientes conectados que generan tráfico.

**Objetivo:** obtener la clave de la red.

**Preguntas:**

1. ¿Por qué WEP se puede romper independientemente de lo robusta que sea la
   clave?
2. ¿Qué has hecho para acelerar el ataque y por qué funciona?

---

## 3. `he_wpa2` — WPA2-PSK

Red WPA2 personal con clientes conectados.

**Objetivo:** obtener la clave de la red.

**Preguntas:**

1. ¿Qué material criptográfico has necesitado capturar y por qué permite atacar
   la clave sin estar conectado a la red?
2. ¿Qué has tenido que hacer para conseguirlo y qué efecto tiene sobre los
   clientes legítimos?
3. ¿Qué haría inviable el ataque aunque capturaras lo mismo?

---

## 4. `he_pmkid` — WPA2-PSK

Red WPA2 personal con un cliente conectado.

**Objetivo:** obtener la clave de la red **sin usar el mismo método que en
`he_wpa2`**.

**Preguntas:**

1. ¿Qué es el PMKID, en qué mensaje viaja y cómo se calcula?
2. En esta red, ¿cuántas vías distintas había para atacar la clave?

---

## 5. `he_pmkid_nc` — WPA2-PSK sin clientes

Red WPA2 personal **sin ningún cliente conectado**.

**Objetivo:** obtener la clave de la red.

**Preguntas:**

1. ¿Por qué los métodos que no funcionan aquí sí funcionaban en `he_wpa2`?
2. Completa la tabla:

   | | `he_pmkid` | `he_pmkid_nc` |
   |---|---|---|
   | ¿Hay clientes conectados? | | |
   | ¿Necesitas un cliente para el ataque? | | |
   | Material que puedes obtener | | |

3. ¿Qué conclusión sacas sobre la seguridad de WPA2-PSK frente a este ataque?

---

## 6. `he_enterprise` — WPA2-Enterprise

Red WPA2 corporativa (802.1X) con un cliente conectado.

**Objetivo:** identificar, a partir del tráfico, la **identidad** con la que se
autentica el usuario y el **método EAP** que usa la red.

**Preguntas:**

1. ¿Qué información de la autenticación viaja sin cifrar?
2. Describe qué ataque permitiría capturar las credenciales del usuario en este
   tipo de red y qué configuración del cliente lo evitaría.

---

## Entrega

Entrega un informe con, **para cada escenario**:

- El BSSID y canal del objetivo en tu despliegue.
- El resultado obtenido (clave, credenciales o identidad/método).
- Los comandos que has ejecutado y por qué, con capturas de pantalla que
  muestren el resultado.
- Las respuestas a las preguntas.
- Una medida defensiva concreta que habría evitado el ataque.
