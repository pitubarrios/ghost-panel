#!/usr/bin/env bash
# ============================================================
#  GHOST PANEL by Jorge Barrios  -  Administracion de VPS (Ubuntu)
#  Menu SSH: usuarios, trafico, backup, banner + Webmin
#  Uso:  sudo bash vps-manager.sh
#  (revision: banner HC validado, CheckUser corregido, limiter por sesiones,
#   sshd_config seguro, ghost_bootstrap activo, usuarios protegidos)
# ============================================================

set -u
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; fi

ROJO='\033[1;31m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'
AZUL='\033[1;34m'; CIAN='\033[1;36m'; BLANCO='\033[1;37m'
NC='\033[0m'
NARANJA='\033[38;5;208m'; GRIS='\033[38;5;245m'; MORADO='\033[38;5;141m'
BORDE="$GRIS"          # color del marco
GHOST_VER='3.3.0'

# --- LICENCIA / KEY -------------------------------------------
# Validacion ONLINE obligatoria (Worker de Cloudflare). El enforcement
# real vive en el servidor de licencias, no aca: SECRET_KEY es legacy
# (el modo offline esta deshabilitado; ya no se usa para validar).
SECRET_KEY='Copiaesta**'
KEY_FILE='/etc/vps-manager.key'
PREFIJO_KEY='VPSJB1'   # prefijo de marca; tambien acepta keys viejas VPSMGR1
# URL del script en TU repo (para la opcion de auto-update)
REPO_RAW='https://raw.githubusercontent.com/pitubarrios/vps-manager/refs/heads/main/ghost-panel.sh'
VPSMGR_DEST=/usr/local/bin/vpsmgr
if [[ -r /etc/ghost-panel.conf ]]; then
    _u=$(awk -F= '/^UPDATE_URL=/{print substr($0,12); exit}' /etc/ghost-panel.conf)
    [[ "$_u" =~ ^https?://[^[:space:]]+$ ]] && REPO_RAW="$_u"
fi
# --- VALIDACION ONLINE (opcional) ---
# Pone aca la URL de tu Worker de Cloudflare. Vacio = validacion offline (firma local).
LICENSE_URL='https://vps-licencias.jorgebarriosmpya.workers.dev'
GRACE_SECS=259200                      # 72h de gracia si el servidor no responde
LICENSE_CACHE='/etc/vps-license.cache'

machine_hash(){
    if [[ -f /etc/machine-id ]]; then
        sha256sum /etc/machine-id 2>/dev/null | cut -c1-12
    else
        sha256sum /etc/hostname 2>/dev/null | cut -c1-12
    fi
}

validar_key(){
    # Uso: validar_key "$KEY"  -> 0 valida / 1 invalida
    local KEY BODY B64 SIG SIGC PAYLOAD NOMBRE EXP MACH
    KEY=$(echo "$1" | tr -d '[:space:]')
    case "$KEY" in ${PREFIJO_KEY}-*|VPSMGR1-*) ;; *) return 1 ;; esac
    BODY=${KEY#*-}
    SIG=${BODY##*-}
    B64=${BODY%-*}
    [[ -n "$B64" && -n "$SIG" && "$B64" != "$SIG" ]] || return 1
    SIGC=$(printf '%s' "$B64" | openssl dgst -sha256 -hmac "$SECRET_KEY" 2>/dev/null | awk '{print $NF}' | cut -c1-16 | tr 'a-f' 'A-F')
    [[ "$SIGC" == "$SIG" ]] || return 1
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || return 1
    NOMBRE=${PAYLOAD%%|*}; PAYLOAD=${PAYLOAD#*|}
    EXP=${PAYLOAD%%|*};  MACH=${PAYLOAD#*|}
    [[ -n "$NOMBRE" && -n "$EXP" ]] || return 1
    [[ "$EXP" != "0" && "$(date +%s)" -gt "$EXP" ]] && return 1
    if [[ -n "$MACH" && "$MACH" != "$(machine_hash)" ]]; then return 1; fi
    KEY_NOMBRE="$NOMBRE"
    KEY_EXP="$EXP"
    return 0
}

lic_json_str(){
    # lic_json_str "$JSON" clave1 clave2 ... -> primer valor string no vacio
    local json="$1" k v; shift
    for k in "$@"; do
        v=$(printf '%s' "$json" | grep -o "\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
            | sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//')
        [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    done
    return 1
}

lic_guardar_nombre(){
    # guarda el nombre para mostrarlo tambien en modo gracia (servidor caido)
    [[ -n "${LICENSE_NOMBRE:-}" ]] || return 0
    printf '%s' "$LICENSE_NOMBRE" > /etc/vps-license.name 2>/dev/null && chmod 600 /etc/vps-license.name 2>/dev/null
    return 0
}

consultar_licencia(){
    # Modo online: pregunta al Worker de Cloudflare.
    # Devuelve: 0 valida / 1 invalida / 2 servidor sin respuesta
    local KEY="$1" RESP
    [[ -z "$LICENSE_URL" ]] && return 2
    RESP=$(curl -G -fsS --max-time 10 -A "Mozilla/5.0" "$LICENSE_URL" \
        --data-urlencode "key=$KEY" --data-urlencode "id=$(machine_hash)" 2>/dev/null)
    [[ -z "$RESP" ]] && return 2
    if echo "$RESP" | grep -q '"valid":[[:space:]]*true'; then
        LICENSE_NOMBRE=$(lic_json_str "$RESP" name nombre owner cliente client customer username user)
        LICENSE_NOMBRE=$(printf '%b' "$LICENSE_NOMBRE" | tr -d '\000-\037' | cut -c1-40)   # decodifica \u00e9 y limpia
        LICENSE_DIAS=$(echo "$RESP" | grep -o '"days_left"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$')
        return 0
    fi
    return 1
}

gate_licencia(){
    local INTENTOS=0 K RC
    FR_TOP
    FR_TXT "  ${AMARILLO}$(T t_lic_req)${NC} - $(T t_panel_jb)"
    FR_MID
    FR_TXT "  $(T t_id_srv): ${BLANCO}$(machine_hash)${NC}"

    if [[ -z "$LICENSE_URL" ]]; then
        FR_TXT "  ${ROJO}$(T t_online_req)${NC}"
        FR_TXT "  $(T t_online_req2)"
        FR_BOT
        exit 1
    fi

    # ---------------- MODO ONLINE (unico modo) ----------------
    INFO "Validacion online activa."
    if [[ -f "$KEY_FILE" ]]; then
        K=$(cat "$KEY_FILE" 2>/dev/null)
        consultar_licencia "$K"; RC=$?
        if [[ $RC -eq 0 ]]; then
            date +%s > "$LICENSE_CACHE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            lic_guardar_nombre
            [[ -n "${LICENSE_DIAS:-}" ]] && LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
            return 0
        elif [[ $RC -eq 2 ]]; then
            if [[ -f "$LICENSE_CACHE" ]] && (( $(date +%s) - $(cat "$LICENSE_CACHE" 2>/dev/null || echo 0) < GRACE_SECS )); then
                LICENSE_OK="$(cat /etc/vps-license.name 2>/dev/null || echo cliente) (modo gracia)"
                return 0
            fi
            ERR "Servidor de licencias no responde y no hay gracia acumulada."
        fi
    fi
    while [[ $INTENTOS -lt 3 ]]; do
        read -r -p " INGRESE SU KEY > " K
        consultar_licencia "$K"; RC=$?
        if [[ $RC -eq 0 ]]; then
            echo "$K" > "$KEY_FILE" 2>/dev/null
            date +%s > "$LICENSE_CACHE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            lic_guardar_nombre
            [[ -n "${LICENSE_DIAS:-}" ]] && LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
            OK "Licencia aceptada. Bienvenido, ${LICENSE_OK}."
            sleep 1
            return 0
        elif [[ $RC -eq 2 ]]; then
            ERR "Servidor de licencias no responde. Intenta mas tarde."
        else
            ERR "Key invalida, expirada, revocada o de otro servidor."
        fi
        INTENTOS=$((INTENTOS+1))
    done
    echo -e "${ROJO}Sin licencia valida. Contacta al administrador.${NC}"
    exit 1
}


# ---------- MULTI-IDIOMA ----------
IDIOMA="es"
[[ -f /etc/vps-manager.lang ]] && IDIOMA=$(cat /etc/vps-manager.lang 2>/dev/null)
declare -A TXT_ES TXT_EN
TXT_ES[t_menu_principal]="PRINCIPAL"; TXT_EN[t_menu_principal]="MAIN"
TXT_ES[t_ui_sys]="SISTEMA"; TXT_EN[t_ui_sys]="SYSTEM"
TXT_ES[t_ui_res]="RECURSOS"; TXT_EN[t_ui_res]="RESOURCES"
TXT_ES[t_ui_ses]="SESION"; TXT_EN[t_ui_ses]="SESSION"
TXT_ES[t_ui_user]="Usuario"; TXT_EN[t_ui_user]="User"
TXT_ES[t_ui_days]="dias"; TXT_EN[t_ui_days]="days"
TXT_ES[t_usuarios]="Usuarios SSH"; TXT_EN[t_usuarios]="SSH Users"
TXT_ES[t_protocolos]="Protocolos"; TXT_EN[t_protocolos]="Protocols"
TXT_ES[t_seguridad]="Seguridad"; TXT_EN[t_seguridad]="Security"
TXT_ES[t_sistema]="Sistema y Recursos"; TXT_EN[t_sistema]="System & Resources"
TXT_ES[t_herramientas]="Herramientas"; TXT_EN[t_herramientas]="Tools"
TXT_ES[t_webmin]="Webmin"; TXT_EN[t_webmin]="Webmin"
TXT_ES[t_backup]="Backup / Restaurar"; TXT_EN[t_backup]="Backup / Restore"
TXT_ES[t_diagnostico]="Diagnostico"; TXT_EN[t_diagnostico]="Diagnostics"
TXT_ES[t_servidor_id]="Servidor ID"; TXT_EN[t_servidor_id]="Server ID"
TXT_ES[t_salir]="Salir"; TXT_EN[t_salir]="Exit"
TXT_ES[t_opcion]="Opcion"; TXT_EN[t_opcion]="Option"
TXT_ES[t_volver]="Volver"; TXT_EN[t_volver]="Back"
TXT_ES[t_sub_usuarios]="USUARIOS SSH"; TXT_EN[t_sub_usuarios]="SSH USERS"
TXT_ES[t_crear]="Crear usuario"; TXT_EN[t_crear]="Create user"
TXT_ES[t_listar]="Listar usuarios"; TXT_EN[t_listar]="List users"
TXT_ES[t_clave]="Cambiar clave"; TXT_EN[t_clave]="Change password"
TXT_ES[t_bloquear]="Bloquear/Desbl."; TXT_EN[t_bloquear]="Block/Unblock"
TXT_ES[t_renovar]="Renovar usuario"; TXT_EN[t_renovar]="Renew user"
TXT_ES[t_limite]="Cambiar limite"; TXT_EN[t_limite]="Change limit"
TXT_ES[t_eliminar]="Eliminar usuario"; TXT_EN[t_eliminar]="Delete user"
TXT_ES[t_vencidos]="Eliminar vencidos"; TXT_EN[t_vencidos]="Delete expired"
TXT_ES[t_test]="Crear test SSH"; TXT_EN[t_test]="Create SSH test"
TXT_ES[t_conexiones]="Conexiones online"; TXT_EN[t_conexiones]="Online connections"
TXT_ES[t_desconectar]="Desconectar usr"; TXT_EN[t_desconectar]="Disconnect user"
TXT_ES[t_sub_seg]="SEGURIDAD"; TXT_EN[t_sub_seg]="SECURITY"
TXT_ES[t_fail2ban]="Fail2ban"; TXT_EN[t_fail2ban]="Fail2ban"
TXT_ES[t_limiter_on]="Limiter (activar)"; TXT_EN[t_limiter_on]="Limiter (enable)"
TXT_ES[t_limiter_off]="Quitar limiter"; TXT_EN[t_limiter_off]="Remove limiter"
TXT_ES[t_puerto_ssh]="Cambiar puerto SSH"; TXT_EN[t_puerto_ssh]="Change SSH port"
TXT_ES[t_ver_puertos]="Ver puertos"; TXT_EN[t_ver_puertos]="Show ports"
TXT_ES[t_abrir_puerto]="Abrir puerto"; TXT_EN[t_abrir_puerto]="Open port"
TXT_ES[t_banner]="Banner SSH / HC"; TXT_EN[t_banner]="SSH / HC banner"
TXT_ES[t_sub_banner]="BANNER SSH / HTTP CUSTOM"; TXT_EN[t_sub_banner]="SSH / HTTP CUSTOM BANNER"
TXT_ES[t_banner_html]="Banner HTML dinamico"; TXT_EN[t_banner_html]="Dynamic HTML banner"
TXT_ES[t_banner_msg]="Mensajes banner SSH"; TXT_EN[t_banner_msg]="SSH banner messages"
TXT_ES[t_banner_del]="Eliminar banner"; TXT_EN[t_banner_del]="Remove banner"
TXT_ES[t_banner_cu]="CheckUser + banner"; TXT_EN[t_banner_cu]="CheckUser + banner"
TXT_ES[t_sub_sistema]="SISTEMA Y RECURSOS"; TXT_EN[t_sub_sistema]="SYSTEM & RESOURCES"
TXT_ES[t_monitoreo]="Monitoreo"; TXT_EN[t_monitoreo]="Monitoring"
TXT_ES[t_optimizar]="Optimizar (BBR)"; TXT_EN[t_optimizar]="Optimize (BBR)"
TXT_ES[t_swap]="Agregar swap"; TXT_EN[t_swap]="Add swap"
TXT_ES[t_zram]="Agregar zram"; TXT_EN[t_zram]="Add zram"
TXT_ES[t_mantenimiento]="Mantenimiento"; TXT_EN[t_mantenimiento]="Maintenance"
TXT_ES[t_hostname]="Cambiar hostname"; TXT_EN[t_hostname]="Change hostname"
TXT_ES[t_update]="Update sistema"; TXT_EN[t_update]="System update"
TXT_ES[t_reiniciar]="Reiniciar VPS"; TXT_EN[t_reiniciar]="Reboot VPS"
TXT_ES[t_sub_herr]="HERRAMIENTAS DEL PANEL"; TXT_EN[t_sub_herr]="PANEL TOOLS"
TXT_ES[t_global]="Comando global"; TXT_EN[t_global]="Global command"
TXT_ES[t_automenu_on]="Auto-menu login"; TXT_EN[t_automenu_on]="Auto-menu on login"
TXT_ES[t_automenu_off]="Quitar auto-menu"; TXT_EN[t_automenu_off]="Remove auto-menu"
TXT_ES[t_autoupdate]="Auto-update script"; TXT_EN[t_autoupdate]="Self-update script"
TXT_ES[t_checkuser]="CheckUser API"; TXT_EN[t_checkuser]="CheckUser API"
TXT_ES[t_idioma]="Cambiar idioma"; TXT_EN[t_idioma]="Change language"
TXT_ES[t_sub_backup]="BACKUP / RESTAURAR"; TXT_EN[t_sub_backup]="BACKUP / RESTORE"
TXT_ES[t_backup_crear]="Crear backup"; TXT_EN[t_backup_crear]="Create backup"
TXT_ES[t_backup_restaurar]="Restaurar backup"; TXT_EN[t_backup_restaurar]="Restore backup"
TXT_ES[t_sub_prot]="PROTOCOLOS / CONEXIONES"; TXT_EN[t_sub_prot]="PROTOCOLS / CONNECTIONS"
TXT_ES[t_xray]="Xray VLESS+Reality"; TXT_EN[t_xray]="Xray VLESS+Reality"
TXT_ES[t_xray_ws]="Xray WS (CDN)"; TXT_EN[t_xray_ws]="Xray WS (CDN)"
TXT_ES[t_openvpn]="OpenVPN"; TXT_EN[t_openvpn]="OpenVPN"
TXT_ES[t_stunnel]="SSL Stunnel 443"; TXT_EN[t_stunnel]="SSL Stunnel 443"
TXT_ES[t_hysteria]="Hysteria2 (UDP)"; TXT_EN[t_hysteria]="Hysteria2 (UDP)"
TXT_ES[t_badvpn]="BadVPN (UDP GW)"; TXT_EN[t_badvpn]="BadVPN (UDP GW)"
TXT_ES[t_wsepro]="WS-epro (WS->SSH)"; TXT_EN[t_wsepro]="WS-epro (WS->SSH)"
TXT_ES[t_shadowsocks]="Shadowsocks"; TXT_EN[t_shadowsocks]="Shadowsocks"
TXT_ES[t_trojan]="Trojan"; TXT_EN[t_trojan]="Trojan"
TXT_ES[t_wireguard]="WireGuard"; TXT_EN[t_wireguard]="WireGuard"
TXT_ES[t_estado_prot]="Estado y puertos"; TXT_EN[t_estado_prot]="Status & ports"
TXT_ES[t_quitar]="Quitar protocolo"; TXT_EN[t_quitar]="Remove protocol"
TXT_ES[t_sub_webmin]="WEBMIN"; TXT_EN[t_sub_webmin]="WEBMIN"
TXT_ES[t_webmin_inst]="Instalar Webmin"; TXT_EN[t_webmin_inst]="Install Webmin"
TXT_ES[t_estado_svc]="Estado servicio"; TXT_EN[t_estado_svc]="Service status"
TXT_ES[t_abrir_10000]="Abrir puerto 10000"; TXT_EN[t_abrir_10000]="Open port 10000"
TXT_ES[t_cambiar_puerto]="Cambiar puerto"; TXT_EN[t_cambiar_puerto]="Change port"
TXT_ES[t_remover_webmin]="Remover Webmin"; TXT_EN[t_remover_webmin]="Remove Webmin"
TXT_ES[t_sub_cu]="CHECKUSER API"; TXT_EN[t_sub_cu]="CHECKUSER API"
TXT_ES[t_cu_inst]="Instalar / reinstalar"; TXT_EN[t_cu_inst]="Install / reinstall"
TXT_ES[t_cu_probar]="Probar consulta"; TXT_EN[t_cu_probar]="Test query"
TXT_ES[t_cu_token]="Ver token y puerto"; TXT_EN[t_cu_token]="Show token & port"
TXT_ES[t_remover]="Remover"; TXT_EN[t_remover]="Remove"
TXT_ES[t_sub_trafico]="TRAFICO POR USUARIO"; TXT_EN[t_sub_trafico]="PER-USER TRAFFIC"
TXT_ES[t_tr_activar]="Activar contadores"; TXT_EN[t_tr_activar]="Enable counters"
TXT_ES[t_tr_ver]="Ver consumo"; TXT_EN[t_tr_ver]="View usage"
TXT_ES[t_tr_limite]="Poner limite (GB)"; TXT_EN[t_tr_limite]="Set limit (GB)"
TXT_ES[t_tr_cortar]="Cortar excedidos"; TXT_EN[t_tr_cortar]="Cut exceeded"
TXT_ES[t_tr_reset]="Reset contadores"; TXT_EN[t_tr_reset]="Reset counters"
TXT_ES[t_sub_quitar]="QUITAR PROTOCOLOS"; TXT_EN[t_sub_quitar]="REMOVE PROTOCOLS"
TXT_ES[t_q_xray]="Xray completo"; TXT_EN[t_q_xray]="Xray (full)"
TXT_ES[t_panel]="Panel de administracion"; TXT_EN[t_panel]="Administration panel"
TXT_ES[t_ram]="RAM"; TXT_EN[t_ram]="RAM"
TXT_ES[t_cpu]="CPU"; TXT_EN[t_cpu]="CPU"
TXT_ES[t_disco]="Disco"; TXT_EN[t_disco]="Disk"
TXT_ES[t_online]="Online"; TXT_EN[t_online]="Online"
TXT_ES[t_licencia]="Licencia"; TXT_EN[t_licencia]="License"
TXT_ES[t_lic_req]="LICENCIA REQUERIDA"; TXT_EN[t_lic_req]="LICENSE REQUIRED"
TXT_ES[t_panel_jb]="GHOST PANEL by Jorge Barrios"; TXT_EN[t_panel_jb]="GHOST PANEL by Jorge Barrios"
TXT_ES[t_id_srv]="ID de este servidor"; TXT_EN[t_id_srv]="ID of this server"
TXT_ES[t_online_req]="VALIDACION ONLINE OBLIGATORIA"; TXT_EN[t_online_req]="ONLINE VALIDATION REQUIRED"
TXT_ES[t_online_req2]="LICENSE_URL no configurado. Baja la version oficial."; TXT_EN[t_online_req2]="LICENSE_URL not set. Get the official release."
TXT_ES[t_opinv]="Opcion invalida."; TXT_EN[t_opinv]="Invalid option."
TXT_ES[t_cf_test]="Tunel CDN (prueba)"; TXT_EN[t_cf_test]="CDN tunnel (test)"
TXT_ES[t_q_tunnel]="Tunel CDN (cloudflared)"; TXT_EN[t_q_tunnel]="CDN tunnel (cloudflared)"
TXT_ES[t_dropbear]="Dropbear"; TXT_EN[t_dropbear]="Dropbear"
TXT_ES[t_udp_custom]="UDP Custom"; TXT_EN[t_udp_custom]="UDP Custom"
TXT_ES[t_slowdns]="SlowDNS (dnstt)"; TXT_EN[t_slowdns]="SlowDNS (dnstt)"
TXT_ES[t_ver_links]="Ver enlaces"; TXT_EN[t_ver_links]="Show links"
T(){
    if [[ "$IDIOMA" == "en" && -n "${TXT_EN[$1]:-}" ]]; then echo "${TXT_EN[$1]}"; else echo "${TXT_ES[$1]:-$1}"; fi
}
seleccionar_idioma(){
    [[ -f /etc/vps-manager.lang ]] && { IDIOMA=$(cat /etc/vps-manager.lang 2>/dev/null); return; }
    echo
    echo -e "  ${CIAN}Idioma / Language:${NC}"
    echo    "   1) Español"
    echo    "   2) English"
    read -r -p "   > " L
    case "$L" in 2) IDIOMA="en";; *) IDIOMA="es";; esac
    echo "$IDIOMA" > /etc/vps-manager.lang 2>/dev/null
}

PAUSA(){ echo -e "\n  ${GRIS}↵ ENTER para continuar...${NC}"; read -r; }

# ---------- HELPERS DE PRODUCCION ----------
LOG_PANEL='/var/log/ghost-panel.log'
LINKS_FILE='/root/vps-links.txt'
IP_CACHE_FILE='/run/vps-ip.cache'   # /run es de root (en /tmp un usuario SSH podia plantar un symlink)
USUARIOS_DIR='/etc/vps-users'
PROTEGIDOS_NOMBRES='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu debian admin ec2-user cloud-user vpsmgr dnstt'

vps_arch(){
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armhf) echo arm ;;
        *) uname -m ;;
    esac
}

vps_log(){
    local NIV=${1:-INFO}; shift || true
    mkdir -p "$(dirname "$LOG_PANEL")" 2>/dev/null
    echo "$(date '+%F %T') [$NIV] $*" >> "$LOG_PANEL" 2>/dev/null || true
}

ip_publica(){
    local ip ahora mtime=0
    ahora=$(date +%s)
    if [[ -f "$IP_CACHE_FILE" ]]; then
        mtime=$(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0)
        if (( ahora - mtime < 3600 )); then
            cat "$IP_CACHE_FILE"
            return 0
        fi
    fi
    ip=$(curl -4 -fsS --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    printf '%s' "$ip" > "$IP_CACHE_FILE" 2>/dev/null
    printf '%s' "$ip"
}

guardar_enlace(){
    local TITULO="$1" CUERPO="$2"
    mkdir -p "$(dirname "$LINKS_FILE")"
    {
        echo "===== $(date '+%F %T')  ${TITULO} ====="
        echo "$CUERPO"
        echo
    } >> "$LINKS_FILE"
    chmod 600 "$LINKS_FILE" 2>/dev/null || true
}

usuario_protegido(){
    local U="${1:-}" UIDN
    [[ -z "$U" ]] && return 0
    echo " $PROTEGIDOS_NOMBRES " | grep -q " $U " && return 0
    UIDN=$(id -u "$U" 2>/dev/null || echo 0)
    [[ "$UIDN" -lt 1000 ]] && return 0
    return 1
}

pedir_usuario_ok(){
    # Uso: pedir_usuario_ok VAR  -> 0 ok / 1 error (ya mostro mensaje)
    local _n
    read -r -p "Usuario: " _n
    if [[ -z "$_n" ]]; then ERR "Nombre vacio."; return 1; fi
    if ! id "$_n" >/dev/null 2>&1; then ERR "No existe."; return 1; fi
    if usuario_protegido "$_n"; then ERR "Usuario protegido del sistema: $_n"; vps_log WARN "intento sobre usuario protegido: $_n"; return 1; fi
    printf -v "$1" '%s' "$_n"
    return 0
}

nombre_usuario_valido(){
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

usuario_fecha_cuenta(){
    # Vencimiento de la CUENTA (chage -E) en ISO YYYY-MM-DD, o "never".
    local raw iso
    raw=$(LC_ALL=C LANG=C chage -l "$1" 2>/dev/null | awk -F': ' '/^Account expires/{print $2; exit}')
    raw=${raw#"${raw%%[![:space:]]*}"}
    if [[ -z "$raw" || "$raw" == "never" ]]; then echo never; return 0; fi
    iso=$(date -d "$raw" +%Y-%m-%d 2>/dev/null) || { echo never; return 0; }
    echo "$iso"
}

dias_hasta(){
    # dias_hasta YYYY-MM-DD -> dias enteros desde hoy (negativo si ya paso). UTC: sin saltos por DST.
    local t h
    t=$(date -u -d "$1" +%s 2>/dev/null) || { echo 0; return 1; }
    h=$(date -u -d "$(date +%F)" +%s)
    echo $(( (t - h) / 86400 ))
}

usuario_online(){
    # Sesiones abiertas de un usuario (OpenSSH: tuneles sin tty incluidos; Dropbear: solo con shell).
    ps -eo user:32=,comm= 2>/dev/null | awk -v u="$1" '$1==u && ($2=="sshd"||$2=="dropbear"){c++} END{print c+0}'
}

online_total(){
    ps -eo user:32=,comm= 2>/dev/null | awk '($2=="sshd"||$2=="dropbear") && $1!="root"{c++} END{print c+0}'
}

sesiones_por_usuario(){
    ps -eo user:32=,comm= 2>/dev/null | awk '($2=="sshd"||$2=="dropbear") && $1!="root"{c[$1]++} END{for(u in c) printf "  %-20s %d sesion(es)\n", u, c[u]}' | sort
}

SSHD_CFG=/etc/ssh/sshd_config

sshd_puerto_actual(){
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [[ -z "$p" ]] && p=$(awk 'tolower($1)=="port"{print $2; exit}' "$SSHD_CFG" 2>/dev/null)
    echo "${p:-22}"
}

sshd_recargar(){
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || service ssh reload 2>/dev/null || service sshd reload 2>/dev/null
}

sshd_main_set(){
    # sshd_main_set CLAVE VALOR -> deja UNA directiva global ANTES de cualquier bloque Match
    # (al final del archivo quedaba dentro del Match y rompia sshd). VALOR vacio = solo borrar.
    # Valida con sshd -t y restaura el original si queda invalido.
    local key="$1" val="${2:-}" tmp bak="${SSHD_CFG}.ghost.bak"
    [[ -f "$SSHD_CFG" ]] || { ERR "No existe $SSHD_CFG"; return 1; }
    tmp=$(mktemp /tmp/sshd-cfg.XXXXXX) || return 1
    awk -v k="$key" -v v="$val" '
        BEGIN{ kl=tolower(k); done=0; inmatch=0 }
        {
            t=$0; sub(/^[ \t]+/,"",t); split(t,a,/[ \t=]+/); f=tolower(a[1])
            if (f=="match") {
                if (!inmatch && !done && v!="") { print k " " v; done=1 }
                inmatch=1; print $0; next
            }
            if (!inmatch && f==kl) next
            print $0
        }
        END{ if (!done && v!="" && !inmatch) print k " " v }
    ' "$SSHD_CFG" > "$tmp" || { rm -f "$tmp"; return 1; }
    cp -a "$SSHD_CFG" "$bak"
    cat "$tmp" > "$SSHD_CFG"; rm -f "$tmp"
    if ! sshd -t 2>/dev/null; then
        cp -a "$bak" "$SSHD_CFG"
        ERR "sshd_config quedo invalido con el cambio; se restauro el original."
        return 1
    fi
    return 0
}

xray_grupo(){
    # Grupo con el que corre Xray (para darle lectura a config/claves sin abrirlas a los usuarios SSH).
    local u g
    u=$(systemctl show -p User --value xray 2>/dev/null)
    [[ -z "$u" ]] && u=root
    g=$(id -gn "$u" 2>/dev/null) || return 1
    echo "$g"
}

xray_config_perms(){
    local f=/usr/local/etc/xray/config.json g
    [[ -f "$f" ]] || return 0
    g=$(xray_grupo) || return 0
    chown root:"$g" "$f" 2>/dev/null && chmod 640 "$f"
}

purgar_usuario(){
    # purgar_usuario USUARIO [keep]  -> borra usuario + limites + trafico + clientes xray.
    local U="$1"
    pkill -KILL -u "$U" 2>/dev/null
    xray_usuario del "$U" >/dev/null 2>&1
    rm -f "/etc/vps-limits/$U" "/etc/vps-trafico/$U" "/etc/vps-users/$U"
    if [[ "${2:-}" == "keep" ]]; then userdel "$U" >/dev/null 2>&1
    else userdel -r "$U" >/dev/null 2>&1 || userdel -f "$U" >/dev/null 2>&1; fi
    ! id "$U" >/dev/null 2>&1
}

cron_vencidos_instalar(){
    cat > /usr/local/bin/vps-cron-diario.sh <<'CRONEOF'
#!/usr/bin/env bash
LOG=/var/log/ghost-panel.log
HOY=$(date +%Y-%m-%d)
PROTEGIDOS='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu debian admin ec2-user cloud-user vpsmgr dnstt'
log(){ echo "$(date '+%F %T') [CRON] $*" >> "$LOG" 2>/dev/null; }
awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | while read -r U; do
    echo " $PROTEGIDOS " | grep -q " $U " && continue
    EXP=$(LC_ALL=C LANG=C chage -l "$U" 2>/dev/null | awk -F': ' '/Account expires/{gsub(/^ +/,"",$2); print $2}')
    [[ -z "$EXP" || "$EXP" == "never" ]] && continue
    N=$(date -d "$EXP" +%Y-%m-%d 2>/dev/null) || continue
    if [[ "$N" < "$HOY" ]]; then
        pkill -u "$U" 2>/dev/null
        python3 - "$U" >/dev/null 2>&1 <<'PY'
import json,sys,os
u=sys.argv[1]
p="/usr/local/etc/xray/config.json"
meta={}
try:
    for line in open(f"/etc/vps-users/{u}"):
        k,_,v=line.strip().partition("=")
        if k: meta[k]=v
except FileNotFoundError:
    pass
if os.path.isfile(p):
    try:
        c=json.load(open(p))
        uid=meta.get("uuid",""); tp=meta.get("trojan","")
        for ib in c.get("inbounds",[]):
            proto=ib.get("protocol")
            clients=ib.get("settings",{}).get("clients",[])
            if proto in ("vless","vmess"):
                ib["settings"]["clients"]=[x for x in clients if x.get("id")!=uid and x.get("email")!=u]
            elif proto=="trojan":
                ib["settings"]["clients"]=[x for x in clients if x.get("password")!=tp and x.get("email")!=u]
        json.dump(c, open(p,"w"), indent=2)
    except Exception:
        pass
PY
        rm -f "/etc/vps-limits/$U" "/etc/vps-trafico/$U" "/etc/vps-users/$U"
        userdel -r "$U" 2>/dev/null || userdel "$U" 2>/dev/null
        log "eliminado vencido: $U (vencio $N)"
    fi
done
CRONEOF
    chmod 755 /usr/local/bin/vps-cron-diario.sh
    cat > /etc/cron.d/ghost-panel-vencidos <<'TAB'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root /usr/local/bin/vps-cron-diario.sh
TAB
    chmod 644 /etc/cron.d/ghost-panel-vencidos
}

xray_usuario(){
    # xray_usuario add|del USUARIO
    local ACC="$1" USU="$2"
    python3 - "$ACC" "$USU" <<'PY'
import json, os, sys, uuid, secrets
acc, user = sys.argv[1], sys.argv[2]
meta_p = f"/etc/vps-users/{user}"
cfgp = "/usr/local/etc/xray/config.json"
os.makedirs("/etc/vps-users", exist_ok=True)
meta = {}
if os.path.isfile(meta_p):
    for line in open(meta_p):
        k,_,v = line.strip().partition("=")
        if k: meta[k]=v
if acc == "add":
    meta.setdefault("uuid", str(uuid.uuid4()))
    meta.setdefault("trojan", secrets.token_hex(10))
    with open(meta_p,"w") as f:
        for k,v in meta.items():
            f.write(f"{k}={v}\n")
    os.chmod(meta_p, 0o600)
    if not os.path.isfile(cfgp):
        raise SystemExit(0)
    try:
        cfg = json.load(open(cfgp))
    except Exception:
        raise SystemExit(0)
    for ib in cfg.get("inbounds", []):
        proto = ib.get("protocol")
        st = ib.setdefault("settings", {})
        clients = st.setdefault("clients", [])
        if proto in ("vless", "vmess"):
            clients[:] = [c for c in clients if c.get("email") != user and c.get("id") != meta["uuid"]]
            entry = {"id": meta["uuid"], "email": user}
            if proto == "vless" and ib.get("streamSettings",{}).get("security") == "reality":
                entry["flow"] = "xtls-rprx-vision"
            clients.append(entry)
        elif proto == "trojan":
            clients[:] = [c for c in clients if c.get("email") != user and c.get("password") != meta["trojan"]]
            clients.append({"password": meta["trojan"], "email": user})
    json.dump(cfg, open(cfgp,"w"), indent=2)
elif acc == "del":
    uid, tp = meta.get("uuid",""), meta.get("trojan","")
    if os.path.isfile(cfgp):
        try:
            cfg = json.load(open(cfgp))
            for ib in cfg.get("inbounds", []):
                proto = ib.get("protocol")
                clients = ib.get("settings",{}).get("clients",[])
                if proto in ("vless","vmess"):
                    ib["settings"]["clients"] = [c for c in clients if c.get("id")!=uid and c.get("email")!=user]
                elif proto == "trojan":
                    ib["settings"]["clients"] = [c for c in clients if c.get("password")!=tp and c.get("email")!=user]
            json.dump(cfg, open(cfgp,"w"), indent=2)
        except Exception:
            pass
    try:
        os.remove(meta_p)
    except FileNotFoundError:
        pass
PY
    [[ -f /usr/local/etc/xray/config.json ]] && systemctl restart xray 2>/dev/null || true
}

ghost_bootstrap(){
    mkdir -p "$USUARIOS_DIR" /etc/vps-limits /etc/vps-trafico
    chmod 700 "$USUARIOS_DIR" 2>/dev/null
    touch "$LOG_PANEL" 2>/dev/null
    chmod 640 "$LOG_PANEL" 2>/dev/null || true
    [[ -f /etc/cron.d/ghost-panel-vencidos ]] || cron_vencidos_instalar
    xray_config_perms
    # Asegurar autenticacion por contraseña (muchas imagenes cloud la dejan en "no")
    sshd_asegurar_password_auth
}

sshd_asegurar_password_auth(){
    # Activa PasswordAuthentication + KbdInteractiveAuthentication de forma segura.
    # Neutraliza tambien cualquier override en /etc/ssh/sshd_config.d/
    local f changed=0
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]=]+no' "$f" 2>/dev/null         || grep -qiE '^[[:space:]]*KbdInteractiveAuthentication[[:space:]=]+no' "$f" 2>/dev/null; then
            cp -a "$f" "$f.ghost.bak" 2>/dev/null
            sed -i -E 's/^([[:space:]]*PasswordAuthentication[[:space:]=]+).*$/\1yes/I' "$f"
            sed -i -E 's/^([[:space:]]*KbdInteractiveAuthentication[[:space:]=]+).*$/\1yes/I' "$f"
            changed=1
        fi
    done
    # Directiva global en sshd_config (antes de cualquier Match)
    local cur
    cur=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    if [[ "$cur" != "yes" ]]; then
        sshd_main_set PasswordAuthentication yes && changed=1
    fi
    cur=$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication /{print $2}')
    if [[ "$cur" != "yes" ]]; then
        sshd_main_set KbdInteractiveAuthentication yes && changed=1
    fi
    if [[ $changed -eq 1 ]]; then
        sshd_recargar 2>/dev/null || true
        vps_log INFO "PasswordAuthentication activado automaticamente"
    fi
}

# ---------- MARCO / DISEÑO DEL PANEL ----------
UI_W=56
ui_init(){
    # ancho del marco segun la terminal (celular ~58 col, PC hasta 62)
    local c
    c=$(tput cols 2>/dev/null) || c=80
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    UI_W=$(( c - 4 ))
    (( UI_W > 62 )) && UI_W=62
    (( UI_W < 38 )) && UI_W=38
}
ui_rep(){ local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
FR_TOP(){ printf '%b\n' "${BORDE}┌$(ui_rep ─ $((UI_W+2)))┐${NC}"; }
FR_MID(){ printf '%b\n' "${BORDE}├$(ui_rep ─ $((UI_W+2)))┤${NC}"; }
FR_BOT(){ printf '%b\n' "${BORDE}└$(ui_rep ─ $((UI_W+2)))┘${NC}"; }
ui_box_top(){
    # ┌─ TITULO ─────────┐   (titulo en morado dentro del marco)
    local t=" $1 " n
    n=$(( UI_W + 1 - ${#t} ))
    (( n < 1 )) && n=1
    printf '%b\n' "${BORDE}┌─${NC}${MORADO}${t}${NC}${BORDE}$(ui_rep ─ "$n")┐${NC}"
}
ui_crumb(){
    if [[ -n "${1:-}" ]]; then printf '%b\n' "  ${GRIS}Inicio ›${NC} ${CIAN}${1}${NC}"
    else printf '%b\n' "  ${GRIS}Inicio ›${NC}"; fi
}
FR_TXT(){
    local raw="$1" out="" vis=0 esc W=$UI_W
    raw="${raw//\\033/$'\x1b'}"
    while [[ -n "$raw" ]]; do
        if [[ "$raw" == $'\x1b['* ]]; then
            esc="${raw%%m*}m"; out+="$esc"; raw="${raw#"$esc"}"; continue
        fi
        [[ $vis -ge $W ]] && break
        out+="${raw:0:1}"; vis=$((vis+1)); raw="${raw:1}"
    done
    printf '%b %s%b%*s %b\n' "${BORDE}│${NC}" "$out" "$NC" "$((W-vis))" "" "${BORDE}│${NC}"
}
ui_cell(){
    # ui_cell INDICE ETIQUETA ANCHO -> "[1]  Etiqueta" coloreado, relleno a ANCHO columnas visibles
    local k="$1" lbl="${2:-}" w="$3" ic="$CIAN" pad txt
    [[ "$k" == "0" ]] && ic="$ROJO"
    txt=$(printf '%-4s' "[$k]")
    lbl="${lbl:0:$((w-6))}"
    pad=$(( w - 5 - ${#lbl} ))
    (( pad < 0 )) && pad=0
    printf '%b%s%b %b%s%b%*s' "$ic" "$txt" "$NC" "$BLANCO" "$lbl" "$NC" "$pad" ""
}
FR_OPT(){
    local half=$(( UI_W / 2 ))
    if [[ -n "${3:-}" ]]; then
        FR_TXT "  $(ui_cell "$1" "$2" $((half-2)))$(ui_cell "$3" "${4:-}" $((half-2)))"
    else
        FR_TXT "  $(ui_cell "$1" "$2" $((UI_W-2)))"
    fi
}
ui_sec(){ FR_MID; FR_TXT " ${GRIS}$1${NC}"; }
ui_kv(){ FR_TXT "$(printf '  %b%-8s%b %b' "$GRIS" "$1" "$NC" "$2")"; }
ui_bar(){
    # ui_bar PORCENTAJE ANCHO  (verde <70, naranja <90, rojo >=90)
    local p=${1:-0} w=$2 f e col
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    (( p > 100 )) && p=100
    f=$(( p * w / 100 )); e=$(( w - f ))
    if (( p >= 90 )); then col=$ROJO; elif (( p >= 70 )); then col=$NARANJA; else col=$VERDE; fi
    printf '%b%s%b%s%b' "$col" "$(ui_rep █ "$f")" "$GRIS" "$(ui_rep ░ "$e")" "$NC"
}
ui_gauge(){
    # ui_gauge ETIQUETA PORCENTAJE [TEXTO]
    local bw=$(( UI_W - 33 ))
    (( bw > 24 )) && bw=24
    (( bw < 8 )) && bw=8
    FR_TXT "$(printf '  %b%-6s%b %s %b%3s%%%b  %b%s%b' "$GRIS" "$1" "$NC" "$(ui_bar "$2" "$bw")" "$BLANCO" "${2:-0}" "$NC" "$GRIS" "${3:-}" "$NC")"
}
cpu_pct(){
    # CPU instantaneo (2 lecturas de /proc/stat); 0 si no esta disponible (p. ej. proot)
    local _c a b c d e f g h t1 i1 t2 i2
    read -r _c a b c d e f g h _ < /proc/stat 2>/dev/null || { echo 0; return; }
    t1=$((a+b+c+d+e+f+g+h)); i1=$((d+e))
    sleep 0.2
    read -r _c a b c d e f g h _ < /proc/stat 2>/dev/null || { echo 0; return; }
    t2=$((a+b+c+d+e+f+g+h)); i2=$((d+e))
    if (( t2 > t1 )); then echo $(( 100 * ((t2-t1) - (i2-i1)) / (t2-t1) )); else echo 0; fi
}
OK(){ echo -e "  ${VERDE}✔${NC} $1"; }
ERR(){ echo -e "  ${ROJO}✘${NC} $1"; }
INFO(){ echo -e "  ${CIAN}●${NC} $1"; }
WARN(){ echo -e "  ${AMARILLO}▲${NC} $1"; }
FILA(){
    if [[ -n "$3" ]]; then
        printf " ${AZUL}[%-2s]${NC} %-26s ${AZUL}[%-2s]${NC} %s\n" "$1" "$2" "$3" "$4"
    else
        printf " ${AZUL}[%-2s]${NC} %s\n" "$1" "$2"
    fi
}

SUBTOP(){ ui_crumb "$1"; ui_box_top "$1"; }
PROMPT(){ echo; read -r -p "  $(echo -e "${CIAN}▸${NC}") $(T t_opcion) $(echo -e "${GRIS}›${NC}") " OP; }

cabecera(){
    clear
    ui_init
    local os kern up ram_t="" ram_u="" ram_p=0 cpu dsk_p="" dsk_u="" dsk_t="" ONLINE lic lic_txt
    os=$( (. /etc/os-release 2>/dev/null; echo "${NAME:-Linux} ${VERSION_ID:-}") )
    kern=$(uname -r)
    up=$(uptime -p 2>/dev/null); up=${up#up }; [[ -z "$up" ]] && up="n/a"
    read -r ram_t ram_u < <(free -m 2>/dev/null | awk '/Mem:/{print $2, $3}')
    ram_t=${ram_t:-0}; ram_u=${ram_u:-0}
    (( ram_t > 0 )) && ram_p=$(( ram_u * 100 / ram_t ))
    cpu=$(cpu_pct)
    read -r dsk_p dsk_u dsk_t < <(df -P -h / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5, $3, $2}')
    ONLINE=$(online_total)
    lic_txt="${VERDE}${LICENSE_OK:--}${NC}"
    if [[ -n "${LICENSE_EXP:-}" && "${LICENSE_EXP:-0}" != "0" ]]; then
        lic=$(( (LICENSE_EXP - $(date +%s)) / 86400 )); (( lic < 0 )) && lic=0
        lic_txt="${lic_txt}  ${GRIS}·${NC}  ${AMARILLO}${lic} $(T t_ui_days)${NC}"
    fi
    FR_TOP
    FR_TXT " ${MORADO}◆${NC} ${BLANCO}GHOST PANEL${NC}  ${GRIS}-  v${GHOST_VER}${NC}"
    ui_sec "$(T t_ui_sys)"
    ui_kv "OS" "${os}  ${GRIS}·${NC}  kernel ${kern}"
    ui_kv "Uptime" "$up"
    ui_sec "$(T t_ui_res)"
    ui_gauge "RAM" "$ram_p" "${ram_u}M / ${ram_t}M"
    ui_gauge "CPU" "$cpu"
    ui_gauge "$(T t_disco)" "${dsk_p:-0}" "${dsk_u:-?} / ${dsk_t:-?}"
    ui_sec "$(T t_ui_ses)"
    ui_kv "IP" "${CIAN}$(ip_publica)${NC}"
    ui_kv "Host" "$(hostname)   ${GRIS}Online${NC} ${VERDE}${ONLINE}${NC}"
    ui_kv "$(T t_ui_user)" "${BLANCO}$(id -un)${NC}"
    ui_kv "$(T t_licencia)" "$lic_txt"
    ui_kv "Webmin" "$(estado_webmin_min)"
    FR_BOT
    echo
}

estado_webmin_min(){
    if dpkg -l webmin >/dev/null 2>&1; then
        if pgrep -f miniserv >/dev/null 2>&1; then echo -e "${VERDE}ACTIVO :10000${NC}"
        else echo -e "${AMARILLO}INSTALADO (detenido)${NC}"; fi
    else
        echo -e "${ROJO}NO INSTALADO${NC}"
    fi
}

# ------------------------------------------------------------
# GESTION DE USUARIOS SSH
# ------------------------------------------------------------
crear_usuario(){
    echo -e "${CIAN}--- CREAR USUARIO SSH ---${NC}"
    local USU DIAS MAXC CLAVE EXPISO
    read -r -p "Nombre de usuario: " USU
    nombre_usuario_valido "$USU" || { ERR "Nombre invalido (minusculas, numeros, - y _; max 32; empieza con letra)."; PAUSA; return; }
    id "$USU" >/dev/null 2>&1 && { ERR "El usuario ya existe."; PAUSA; return; }
    if echo " $PROTEGIDOS_NOMBRES " | grep -q " $USU "; then ERR "Nombre reservado del sistema."; PAUSA; return; fi
    read -r -p "Dias de validez (ej. 30): " DIAS
    [[ "$DIAS" =~ ^[0-9]+$ && "$DIAS" -ge 1 ]] || { ERR "Dias invalidos (entero >= 1)."; PAUSA; return; }
    read -r -p "Conexion maxima (ej. 1) [1]: " MAXC; MAXC=${MAXC:-1}
    [[ "$MAXC" =~ ^[0-9]+$ ]] || { ERR "Limite invalido."; PAUSA; return; }
    IFS= read -r -p "Contrasena: " CLAVE
    [[ -n "$CLAVE" ]] || { ERR "Contrasena vacia."; PAUSA; return; }
    useradd -m -s /bin/bash "$USU" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    if ! echo "$USU:$CLAVE" | chpasswd 2>/dev/null; then
        ERR "No se pudo fijar la contrasena."; userdel -r "$USU" 2>/dev/null; PAUSA; return
    fi
    EXPISO=$(date -d "+${DIAS} days" +%Y-%m-%d)
    chage -M 99999 -E "$EXPISO" "$USU"
    mkdir -p /etc/vps-limits
    echo "$MAXC" > "/etc/vps-limits/$USU"
    xray_usuario add "$USU"
    vps_log INFO "usuario creado: $USU (${DIAS}d, limite $MAXC)"
    OK "Usuario '$USU' creado. Vence: $EXPISO"
    echo -e "  Usuario: ${VERDE}$USU${NC}   Clave: ${VERDE}$CLAVE${NC}   Limite: $MAXC"
    echo -e "  IP: $(ip_publica)  |  Puerto SSH: $(sshd_puerto_actual)"
    PAUSA
}

cambiar_clave(){
    local USU
    pedir_usuario_ok USU || { PAUSA; return; }
    passwd "$USU" && { OK "Clave actualizada."; vps_log INFO "clave cambiada: $USU"; }
    PAUSA
}

eliminar_usuario(){
    local USU SN
    pedir_usuario_ok USU || { PAUSA; return; }
    read -r -p "Borrar tambien su /home? (s/n): " SN
    if purgar_usuario "$USU" "$([[ "$SN" == "s" ]] || echo keep)"; then
        vps_log INFO "usuario eliminado: $USU"
        OK "Usuario '$USU' eliminado."
    else
        ERR "No se pudo eliminar '$USU'."
    fi
    PAUSA
}

bloquear_usuario(){
    local USU
    pedir_usuario_ok USU || { PAUSA; return; }
    if passwd -S "$USU" 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
        usermod -U "$USU"; OK "'$USU' DESBLOQUEADO."; vps_log INFO "desbloqueado: $USU"
    else
        usermod -L "$USU"; pkill -KILL -u "$USU" 2>/dev/null; OK "'$USU' BLOQUEADO."; vps_log INFO "bloqueado: $USU"
    fi
    PAUSA
}

renovar_usuario(){
    local USU DIAS ACT BASE EXPISO
    pedir_usuario_ok USU || { PAUSA; return; }
    read -r -p "Dias a agregar: " DIAS
    [[ "$DIAS" =~ ^[0-9]+$ && "$DIAS" -ge 1 ]] || { ERR "Dias invalidos (entero >= 1)."; PAUSA; return; }
    ACT=$(usuario_fecha_cuenta "$USU")
    BASE=$(date +%F)
    # si todavia tiene dias, se SUMAN al vencimiento actual; si ya vencio, cuentan desde hoy
    if [[ "$ACT" != "never" && "$ACT" > "$BASE" ]]; then BASE="$ACT"; fi
    EXPISO=$(date -d "$BASE +${DIAS} days" +%Y-%m-%d)
    chage -M 99999 -E "$EXPISO" "$USU"
    vps_log INFO "renovado: $USU hasta $EXPISO"
    OK "'$USU' renovado por ${DIAS} dias (vence: $EXPISO)."
    PAUSA
}

listar_usuarios(){
    echo -e "${CIAN}--- USUARIOS DEL SISTEMA (humanos) ---${NC}"
    printf "%-16s %-12s %-6s %-7s %-7s %s\n" "USUARIO" "VENCE" "DIAS" "LIMITE" "ONLINE" "ESTADO"
    local U EXPISO D EST LIM ON
    while read -r U; do
        EXPISO=$(usuario_fecha_cuenta "$U")
        if [[ "$EXPISO" == "never" ]]; then D="-"; else D=$(dias_hasta "$EXPISO"); fi
        EST=$(passwd -S "$U" 2>/dev/null | awk '{print $2}')
        if [[ "$EST" == "P" ]]; then EST="${VERDE}OK${NC}"; else EST="${ROJO}LOCK${NC}"; fi
        LIM=$(cat "/etc/vps-limits/$U" 2>/dev/null || echo "-")
        ON=$(usuario_online "$U")
        printf "%-16s %-12s %-6s %-7s %-7s %b\n" "$U" "$EXPISO" "$D" "$LIM" "$ON" "$EST"
    done < <(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
    PAUSA
}

conexiones_online(){
    echo -e "${CIAN}--- CONEXIONES ONLINE (SSH / Dropbear, incluye tuneles) ---${NC}"
    sesiones_por_usuario
    echo
    echo -e "${CIAN}Total sesiones de usuarios:${NC} $(online_total)"
    PAUSA
}

matar_conexion(){
    local USU
    conexiones_online_rapido
    pedir_usuario_ok USU || { PAUSA; return; }
    if pgrep -u "$USU" >/dev/null 2>&1; then
        pkill -KILL -u "$USU" 2>/dev/null && OK "Sesiones de '$USU' cerradas."
    else
        ERR "Sin sesiones activas."
    fi
    PAUSA
}
conexiones_online_rapido(){ sesiones_por_usuario; echo; }

# ------------------------------------------------------------
# SISTEMA / RED
# ------------------------------------------------------------
monitoreo(){
    echo -e "${CIAN}--- MONITOREO ---${NC}"
    echo -e "Uptime : $(uptime)"
    free -h | sed 's/^/         /'
    echo
    df -h / /home 2>/dev/null | sed 's/^/         /'
    echo
    ss -tunap 2>/dev/null | awk 'NR>1{print $1, $5, $7}' | head -20
    PAUSA
}

optimizar(){
    INFO "Aplicando ajustes basicos de rendimiento..."
    cat > /etc/sysctl.d/99-vps-manager.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    modprobe tcp_bbr 2>/dev/null; echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
    OK "Optimizacion aplicada (BBR + swappiness=10)."
    PAUSA
}

update_sistema(){
    INFO "Actualizando paquetes..."
    apt update && apt upgrade -y
    OK "Sistema actualizado."
    PAUSA
}

backup_basico(){
    local DIR="/root/backups" FILE RC
    mkdir -p "$DIR"; chmod 700 "$DIR"
    FILE="$DIR/backup-$(date +%F_%H%M).tar.gz"
    INFO "Creando backup de /etc y lista de paquetes..."
    dpkg --get-selections > /root/paquetes.txt 2>/dev/null
    # subshell: el umask 077 no debe filtrarse al resto del panel. Contiene shadow y claves: solo root.
    ( umask 077; tar czf "$FILE" --exclude='etc/ssl/private' /etc /root/paquetes.txt 2>/dev/null ); RC=$?
    if [[ $RC -le 1 && -s "$FILE" ]]; then
        chmod 600 "$FILE"
        OK "Backup creado: $FILE ($(du -h "$FILE" | cut -f1))"
    else
        rm -f "$FILE"; ERR "Fallo el backup (tar codigo $RC)."
    fi
    PAUSA
}

# Banner HTML minificado para logs de HTTP Custom (Android).
# Tokens en texto plano: USER EXP DAYS WARN  (HC los sustituye).
# No usar la subcadena EXP en texto fijo (p.ej. nunca "EXPIRA").
# WARN va solo: si el checkuser lo deja vacio, no queda "AVISO :" huerfano.
banner_html_http_custom(){
    # Banner para los logs de HTTP Custom: UNA sola linea, sin salto final, un <p> por renglon.
    # Variables en texto plano limpio: USER EXP DAYS WARN (HC las sustituye).
    # Ningun texto fijo contiene USER/EXP/DAYS/WARN (HC reemplaza aunque esten dentro de otra palabra).
    # WARN va solo en su renglon: si viene vacio no queda ningun rotulo huerfano.
    printf '%s' '<p style="text-align:center;"><font color="#00FFFF"><b>═══════════════════════</b></font></p><p style="text-align:center;"><font color="#00FF7F"><b>🌐 G H O S T   P A N E L 🌐</b></font></p><p style="text-align:center;"><font color="#9E9E9E"><i>--- CONEXION VIP ESTABLE ---</i></font></p><p style="text-align:center;"><font color="#00FFFF"><b>═══════════════════════</b></font></p><p style="text-align:center;"><font color="#FFFFFF"><b>👤 USUARIO : </b></font><font color="#00BFFF"><b>USER</b></font></p><p style="text-align:center;"><font color="#FFFFFF"><b>📅 VENCIMIENTO : </b></font><font color="#FFD700"><b>EXP</b></font></p><p style="text-align:center;"><font color="#FFFFFF"><b>⏳ RESTANTES : </b></font><font color="#FF8C00"><b>DAYS</b></font></p><p style="text-align:center;"><font color="#555555">──────────────────────</font></p><p style="text-align:center;"><font color="#FF4444"><b>WARN</b></font></p><p style="text-align:center;"><font color="#7CFC00"><i>🚀 Disfruta de la mejor velocidad 🚀</i></font></p><p style="text-align:center;"><font color="#00FFFF"><b>═══════════════════════</b></font></p>'
}

banner_validar_hc(){
    # banner_validar_hc ARCHIVO -> 0 valido / 1 invalido (imprime el motivo)
    python3 - "$1" <<'PYEOF'
import re, sys
try:
    raw = open(sys.argv[1], encoding="utf-8").read()
except Exception:
    print("El banner no es UTF-8 valido."); sys.exit(1)
html = raw.rstrip("\r\n")

def fail(msg):
    print(msg); sys.exit(1)

if not html.strip():
    fail("Banner vacio.")
if "\n" in html or "\r" in html:
    fail("El HTML debe ir en UNA sola linea (sin saltos).")
if re.search(r"[\$\[\]\{\}]", html):
    fail("Prohibido $, [] y {}: las variables van en texto plano (USER EXP DAYS WARN).")
low = html.lower()
if "<script" in low or "<style" in low or "javascript:" in low or "<!--" in low or re.search(r"\sclass\s*=", low):
    fail("No se permite script, style, class ni comentarios.")
for t in re.findall(r"<[^>]*>", html):
    if t.lower() in ("<b>", "</b>", "<i>", "</i>", "</p>", "</font>"):
        continue
    if t == '<p style="text-align:center;">':
        continue
    if re.fullmatch(r'<font color="#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})">', t):
        continue
    fail("Etiqueta no permitida: " + t)
segs = re.findall(r'<p style="text-align:center;">(.*?)</p>', html)
if not segs or "".join('<p style="text-align:center;">%s</p>' % s for s in segs) != html:
    fail('Cada renglon debe ir en su propio <p style="text-align:center;">...</p>, sin nada entre ellos.')
for s in segs:
    if "<p" in s:
        fail("No anides <p>: un renglon por etiqueta.")
    stack = []
    for m in re.finditer(r"<(/?)(b|i|font)\b[^>]*>", s):
        if m.group(1) == "":
            stack.append(m.group(2))
        elif not stack or stack.pop() != m.group(2):
            fail("Etiquetas <b>/<i>/<font> mal anidadas.")
    if stack:
        fail("Etiquetas <b>/<i>/<font> sin cerrar.")
    txt = re.sub(r"<[^>]*>", "", s)
    if re.search(r"[<>]", txt):
        fail("Caracteres < o > sueltos en el texto.")
    if re.search(r"(?i)\bwarn\b", txt) and txt.strip().lower() != "warn":
        fail("La linea de WARN debe contener SOLO la variable (sin prefijos como AVISO :).")
for s in segs:
    plain = re.sub(r"<[^>]*>", "", s)
    for m in re.finditer(r"(?i)user|exp|days|warn", plain):
        a, b = m.start(), m.end()
        pre = plain[a-1] if a > 0 else " "
        nxt = plain[b] if b < len(plain) else " "
        if re.match(r"\w", pre) or re.match(r"\w", nxt):
            w = re.search(r"\w*" + re.escape(m.group(0)) + r"\w*", plain)
            fail("Texto fijo con '%s' dentro de una palabra (%s): HC lo pisaria. Evita EXPIRA y similares." % (m.group(0).upper(), w.group(0) if w else "?"))
print("ok")
PYEOF
}

banner_activar_en_sshd(){
    local f ef
    # El primer valor de 'Banner' que lee sshd gana: se neutralizan los de sshd_config.d
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        grep -qiE '^[[:space:]]*Banner[[:space:]=]' "$f" || continue
        cp -a "$f" "$f.ghost.bak"
        sed -i -E 's/^([[:space:]]*Banner[[:space:]=].*)$/# \1   # desactivado por GHOST PANEL/I' "$f"
    done
    sshd_main_set Banner /etc/banner-vps || return 1
    sshd_recargar || true
    ef=$(sshd -T 2>/dev/null | awk '/^banner /{print $2}')
    [[ "$ef" == "/etc/banner-vps" ]] || WARN "OpenSSH no reporta el banner activo (efectivo: ${ef:-none}). Revisa: sshd -T | grep -i banner"
    return 0
}

dropbear_presente(){ command -v dropbear >/dev/null 2>&1 || [[ -f /etc/default/dropbear ]]; }

banner_activar_en_dropbear(){
    dropbear_presente || return 0
    mkdir -p /etc/dropbear
    install -m 644 /etc/banner-vps /etc/dropbear/banner
    if [[ -f /etc/default/dropbear ]]; then
        # Dropbear solo muestra el banner si se arranca con -b ARCHIVO (DROPBEAR_BANNER)
        if grep -qE '^[[:space:]]*#?[[:space:]]*DROPBEAR_BANNER=' /etc/default/dropbear; then
            sed -i -E 's|^[[:space:]]*#?[[:space:]]*DROPBEAR_BANNER=.*|DROPBEAR_BANNER="/etc/dropbear/banner"|' /etc/default/dropbear
        else
            printf '\nDROPBEAR_BANNER="/etc/dropbear/banner"\n' >> /etc/default/dropbear
        fi
    else
        INFO "Dropbear sin /etc/default/dropbear: agrega -b /etc/dropbear/banner a su comando de inicio."
    fi
    # Dropbear lee el banner al arrancar y no admite reload: hay que reiniciarlo
    systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null || true
    return 0
}

# Recibe HTML por stdin (una linea) y lo activa en OpenSSH + Dropbear.
banner_publicar(){
    local tmp msg SZ
    tmp=$(mktemp /tmp/banner-vps.XXXXXX) || { ERR "No se pudo crear temporal."; return 1; }
    cat > "$tmp"
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"; ERR "Banner vacio. No se publico."; return 1
    fi
    if [[ "${BANNER_HC:-0}" == "1" ]]; then
        if ! msg=$(banner_validar_hc "$tmp"); then
            rm -f "$tmp"; ERR "HTML invalido para HTTP Custom: $msg"; return 1
        fi
        printf '%s' "$(cat "$tmp")" > "$tmp.n" && mv -f "$tmp.n" "$tmp"   # sin salto de linea final
    fi
    SZ=$(wc -c < "$tmp")
    if dropbear_presente && (( SZ >= 2000 )); then
        WARN "El banner pesa ${SZ} bytes: Dropbear ignora banners de 2000 bytes o mas."
    fi
    install -m 644 "$tmp" /etc/banner-vps || { rm -f "$tmp"; ERR "No se pudo escribir /etc/banner-vps"; return 1; }
    rm -f "$tmp"
    banner_activar_en_sshd || return 1
    banner_activar_en_dropbear
    msg="Banner publicado en OpenSSH (/etc/banner-vps)"
    [[ -f /etc/dropbear/banner ]] && msg="Banner publicado en OpenSSH y Dropbear"
    OK "$msg"
    vps_log INFO "banner publicado (${SZ} bytes)"
}

banner_dinamico_html(){
    echo -e "${CIAN}--- BANNER DINAMICO HTML (HTTP CUSTOM) ---${NC}"
    echo "  Debe ejecutarse en el VPS (root). No sirve en Termux sin proot."
    echo
    echo "  [P] Plantilla GHOST PANEL (recomendado)"
    echo "  [C] Pegar HTML propio (UNA linea, variables USER EXP DAYS WARN)"
    echo "  [0] Cancelar"
    local MODO HTML
    read -r -p "  > " MODO
    case "$MODO" in
        P|p|"")
            if banner_html_http_custom | BANNER_HC=1 banner_publicar; then
                echo
                INFO "HTTP Custom sustituye USER / EXP / DAYS / WARN con lo que devuelve CheckUser."
                INFO "WARN queda vacio si CheckUser no envia aviso (no hay rotulo fijo)."
                echo
                echo -e "${AMARILLO}HTML publicado:${NC}"
                cat /etc/banner-vps; echo
            fi
            ;;
        C|c)
            echo "Pega el HTML en UNA linea y ENTER (la terminal corta a ~4000 caracteres):"
            IFS= read -r HTML
            printf '%s' "$HTML" | BANNER_HC=1 banner_publicar
            ;;
        *) INFO "Cancelado." ;;
    esac
    PAUSA
}

banner_ssh(){
    echo -e "${CIAN}--- MENSAJES BANNER SSH (texto) ---${NC}"
    echo "Escribe las lineas del banner (linea vacia para terminar):"
    local tmp
    tmp=$(mktemp /tmp/banner-vps.XXXXXX) || return
    while IFS= read -r LINEA; do [[ -z "$LINEA" ]] && break; printf '%s\n' "$LINEA" >> "$tmp"; done
    if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; ERR "Sin contenido."; PAUSA; return; fi
    cat "$tmp" | banner_publicar
    rm -f "$tmp"
    PAUSA
}

banner_eliminar(){
    echo -e "${CIAN}--- ELIMINAR BANNER (OpenSSH + Dropbear) ---${NC}"
    sshd_main_set Banner "" || true
    rm -f /etc/banner-vps /etc/dropbear/banner
    sshd_recargar || true
    if [[ -f /etc/default/dropbear ]]; then
        sed -i -E '/^[[:space:]]*DROPBEAR_BANNER=/d' /etc/default/dropbear
    fi
    dropbear_presente && { systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null || true; }
    vps_log INFO "banner eliminado"
    OK "Banner eliminado."
    PAUSA
}

banner_con_checkuser(){
    echo -e "${CIAN}--- CHECKUSER + BANNER HTML ---${NC}"
    INFO "Publica el banner HTML dinamico y deja CheckUser listo para USER/EXP/DAYS/WARN."
    banner_html_http_custom | BANNER_HC=1 banner_publicar || { PAUSA; return; }
    if [[ ! -f /etc/vps-checkuser.conf ]]; then
        INFO "CheckUser no instalado. Lanzando instalador..."
        checkuser_instalar
        return
    fi
    checkuser_escribir_py
    systemctl restart vps-checkuser 2>/dev/null || true
    sleep 1
    OK "CheckUser reiniciado (expiration / days_left / warning / limit / online)."
    local P T IP U
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(ip_publica)
    echo -e " URL CheckUser: ${BLANCO}http://$IP:${P:-8080}/checkuser.php?user=USUARIO&token=$T${NC}"
    U=$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd)
    if [[ -n "$U" ]]; then
        echo -e " Prueba con '${U}':"
        curl -s --max-time 4 "http://127.0.0.1:${P:-8080}/checkuser.php?user=$U&token=$T"; echo
    fi
    PAUSA
}

menu_banner(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_banner)"
        FR_OPT 1 "$(T t_banner_html)" 3 "$(T t_banner_del)"
        FR_OPT 2 "$(T t_banner_msg)" 4 "$(T t_banner_cu)"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) banner_dinamico_html ;;
            2) banner_ssh ;;
            3) banner_eliminar ;;
            4) banner_con_checkuser ;;
            0) break ;;
            *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# WEBMIN  (instalador oficial vía repositorio)
# ------------------------------------------------------------
instalar_webmin(){
    echo -e "${CIAN}--- INSTALADOR WEBMIN ---${NC}"
    if dpkg -l webmin >/dev/null 2>&1; then
        INFO "Webmin ya esta instalado."
    else
        INFO "Instalando dependencias..."
        apt update -y && apt install -y curl wget gnupg2 software-properties-common
        INFO "Agregando repositorio oficial de Webmin..."
        local TMP; TMP=$(mktemp -d)
        if curl -fsSL -o "$TMP/setup-repos.sh" https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh; then
            sh "$TMP/setup-repos.sh" -f
            INFO "Instalando Webmin..."
            apt update -y && apt install -y webmin
        else
            ERR "No se pudo descargar setup-repos.sh. Instalando .deb manual..."
            wget -q https://download.webmin.com/download/repository/pool/contrib/w/webmin/webmin_2.301_all.deb -O "$TMP/webmin.deb" \
              || wget -q https://prdownloads.sourceforge.net/webadmin/webmin_2.301_all.deb -O "$TMP/webmin.deb"
            apt install -y "$TMP/webmin.deb" || apt -f install -y
        fi
        rm -rf "$TMP"
    fi
    # firewall
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
        ufw allow 10000/tcp >/dev/null 2>&1 && INFO "Puerto 10000/tcp abierto en UFW."
    fi
    systemctl enable --now webmin 2>/dev/null || /etc/webmin/start >/dev/null 2>&1
    sleep 1
    local WP; WP=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1); WP=${WP:-10000}
    if pgrep -f miniserv >/dev/null 2>&1; then
        OK "Webmin ACTIVO en puerto $WP."
    else
        ERR "Webmin quedo detenido. Proba con la opcion 2 (Estado / reiniciar) del menu."
    fi
    echo
    local IP; IP=$(ip_publica)
    OK "Webmin instalado."
    echo -e " Acceso  : ${VERDE}https://${IP}:10000${NC}"
    echo -e " Usuario : ${VERDE}root${NC} (o cualquier usuario con sudo)"
    echo -e " ${AMARILLO}Nota: si es una VM remota, acepta el aviso de certificado autofirmado.${NC}"
    PAUSA
}

remover_webmin(){
    INFO "Deteniendo y eliminando Webmin..."
    systemctl stop webmin 2>/dev/null
    apt purge -y webmin 2>/dev/null
    rm -f /etc/apt/sources.list.d/webmin.list /usr/share/keyrings/webmin.gpg
    apt update -y >/dev/null 2>&1
    OK "Webmin removido."
    PAUSA
}

menu_webmin(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_webmin)"
        FR_OPT 1 "$(T t_webmin_inst)" 4 "$(T t_cambiar_puerto)"
        FR_OPT 2 "Estado / reiniciar" 5 "$(T t_remover_webmin)"
        FR_OPT 3 "$(T t_abrir_10000)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_webmin ;;
            2) systemctl restart webmin 2>/dev/null || /etc/webmin/start >/dev/null 2>&1
               sleep 1
               if pgrep -f miniserv >/dev/null 2>&1; then
                   local WP; WP=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1); WP=${WP:-10000}
                   OK "Webmin corriendo en puerto $WP."
               else
                   ERR "Webmin no levanto (¿sin systemd ni /etc/webmin/start?)."
               fi
               PAUSA ;;
            3) ufw allow 10000/tcp 2>/dev/null && OK "Puerto abierto." || ERR "UFW no activo."; PAUSA ;;
            4) read -r -p "Nuevo puerto: " P
               if ! [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]]; then ERR "Puerto invalido."; PAUSA; continue; fi
               sed -i "s/^port=.*/port=$P/;s/^listen=.*/listen=$P/" /etc/webmin/miniserv.conf 2>/dev/null
               ufw allow "$P/tcp" >/dev/null 2>&1
               systemctl restart webmin 2>/dev/null && OK "Puerto cambiado a $P." || ERR "Webmin no instalado."
               PAUSA ;;
            5) remover_webmin ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# HERRAMIENTAS EXTRA
# ------------------------------------------------------------
instalar_comando_global(){
    local DEST="$VPSMGR_DEST"
    if install -m 755 "$(readlink -f "$0")" "$DEST" 2>/dev/null; then
        grep -q "alias vps=" /root/.bashrc 2>/dev/null || echo "alias vps='/usr/local/bin/vpsmgr'" >> /root/.bashrc
        OK "Instalado. Ahora entras desde cualquier lado con: ${VERDE}vpsmgr${NC} (o ${VERDE}vps${NC})"
    else
        ERR "No se pudo instalar en $DEST (permisos?)."
    fi
    PAUSA
}

limiter_quitar_forcecommand(){
    # Migra/limpia el metodo viejo (Match Group vpsusers + ForceCommand)
    if grep -q '# VPS-LIMITER-INICIO' "$SSHD_CFG" 2>/dev/null; then
        cp -a "$SSHD_CFG" "${SSHD_CFG}.ghost.bak"
        sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' "$SSHD_CFG"
        if sshd -t 2>/dev/null; then sshd_recargar
        else cp -a "${SSHD_CFG}.ghost.bak" "$SSHD_CFG"; ERR "No se pudo limpiar el limiter viejo de sshd_config."; fi
    fi
}

limiter_aplicar(){
    mkdir -p /etc/vps-limits
    cat > /usr/local/bin/vps-limiter.sh <<'LIMEOF'
#!/bin/bash
# GHOST PANEL - Limiter: mantiene como maximo N sesiones por usuario (/etc/vps-limits/USUARIO).
# Corta las MAS NUEVAS. Cuenta procesos sshd/dropbear del usuario (tuneles sin tty incluidos).
INTERVALO=4
while true; do
    for f in /etc/vps-limits/*; do
        [ -f "$f" ] || continue
        U=$(basename "$f")
        MAX=$(tr -dc '0-9' < "$f")
        [ -n "$MAX" ] && [ "$MAX" -gt 0 ] || continue
        # "etimes pid" ordenado de mas viejo a mas nuevo; se conservan los primeros MAX
        EXTRA=$(ps -u "$U" -o pid=,etimes=,comm= 2>/dev/null \
            | awk '$3=="sshd"||$3=="dropbear"{print $2, $1}' | sort -rn | awk -v m="$MAX" 'NR>m{print $2}')
        for P in $EXTRA; do kill -KILL "$P" 2>/dev/null; done
    done
    sleep "$INTERVALO"
done
LIMEOF
    chmod 755 /usr/local/bin/vps-limiter.sh 2>/dev/null || { ERR "Sin permiso para escribir /usr/local/bin"; PAUSA; return; }
    limiter_quitar_forcecommand
    cat > /etc/systemd/system/vps-limiter.service <<'LSVC'
[Unit]
Description=GHOST PANEL - limitador de sesiones SSH
After=network.target

[Service]
ExecStart=/usr/local/bin/vps-limiter.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
LSVC
    systemctl daemon-reload
    systemctl enable --now vps-limiter >/dev/null 2>&1
    if systemctl is-active --quiet vps-limiter 2>/dev/null; then
        OK "Limiter activo. Usuarios con limite: $(ls /etc/vps-limits/ 2>/dev/null | tr '\n' ' ')"
        INFO "Corta las sesiones MAS NUEVAS cuando el usuario supera su maximo (revisa cada 4 s)."
        INFO "Con Dropbear solo se cuentan sesiones con shell; con OpenSSH tambien los tuneles."
    else
        ERR "El limiter no levanto. Revisa: journalctl -u vps-limiter"
    fi
    PAUSA
}

limiter_quitar(){
    systemctl disable --now vps-limiter >/dev/null 2>&1
    rm -f /etc/systemd/system/vps-limiter.service
    systemctl daemon-reload 2>/dev/null
    limiter_quitar_forcecommand
    OK "Limiter desactivado."
    PAUSA
}

instalar_fail2ban(){
    INFO "Instalando fail2ban (anti fuerza bruta SSH)..."
    apt update -y >/dev/null 2>&1
    apt install -y fail2ban >/dev/null 2>&1
    cat > /etc/fail2ban/jail.local <<'F2BEOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 5
bantime  = 1h
F2BEOF
    systemctl enable --now fail2ban 2>/dev/null
    OK "Fail2ban activo: 5 intentos fallidos = baneo de 1 hora."
    PAUSA
}

cambiar_puerto_ssh(){
    local P
    read -r -p "Puerto SSH nuevo (ej. 2222): " P
    [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    if ss -tln 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${P}$"; then
        ss -tlnp 2>/dev/null | grep -E "[:.]${P}[[:space:]]" | grep -q 'sshd' \
            || { ERR "El puerto $P ya lo usa otro servicio."; PAUSA; return; }
    fi
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        INFO "Ubuntu usa ssh.socket (ignora Port de sshd_config): paso a ssh.service."
        systemctl disable --now ssh.socket >/dev/null 2>&1
        systemctl enable --now ssh.service >/dev/null 2>&1
    fi
    sshd_main_set Port "$P" || { PAUSA; return; }
    ufw allow "$P/tcp" >/dev/null 2>&1
    sshd_recargar
    sleep 1
    if ss -tln 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${P}$"; then
        OK "Puerto SSH: $P. ${AMARILLO}Abri otra terminal y proba conectarte ANTES de cerrar esta.${NC}"
        INFO "Si usas Stunnel/WS-epro, reinstalalos para que apunten al nuevo puerto."
        vps_log INFO "puerto ssh -> $P"
    else
        ERR "sshd no escucha en $P. Revisa: sshd -T | grep -i ^port"
    fi
    PAUSA
}

ver_puertos(){
    echo -e "${CIAN}--- PUERTOS ESCUCHANDO (TCP) ---${NC}"
    ss -tlnp 2>/dev/null | head -25
    echo
    echo -e "${CIAN}--- UFW (firewall) ---${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose 2>/dev/null | head -20
    else
        echo "UFW no instalado."
    fi
    PAUSA
}

abrir_puerto(){
    read -r -p "Puerto a abrir (ej. 8080): " P
    [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Protocolo (tcp/udp) [tcp]: " PROTO; PROTO=${PROTO:-tcp}
    [[ "$PROTO" != "tcp" && "$PROTO" != "udp" ]] && { ERR "Protocolo invalido."; PAUSA; return; }
    if ! command -v ufw >/dev/null 2>&1; then
        INFO "UFW no instalado, instalando..."
        apt update -y >/dev/null 2>&1 && apt install -y ufw >/dev/null 2>&1
    fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        read -r -p "UFW no esta activo. Activarlo ahora? (s/n): " SN
        [[ "$SN" == "s" ]] && { ufw --force enable; INFO "UFW activado."; }
    fi
    ufw allow "$P/$PROTO" >/dev/null 2>&1 && OK "Puerto $P/$PROTO abierto."
    ufw status 2>/dev/null | grep -E "^$P/" || ERR "No se confirmo la regla."
    PAUSA
}

cambiar_limite(){
    echo -e "${CIAN}--- CAMBIAR LIMITE DE SESIONES ---${NC}"
    local U USU M
    for U in $(ls /etc/vps-limits/ 2>/dev/null); do
        printf "  %-16s max: %s\n" "$U" "$(cat "/etc/vps-limits/$U" 2>/dev/null)"
    done
    pedir_usuario_ok USU || { PAUSA; return; }
    read -r -p "Nuevo maximo de sesiones (0 = sin limite): " M
    [[ "$M" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    mkdir -p /etc/vps-limits
    echo "$M" > "/etc/vps-limits/$USU"
    OK "Limite de '$USU' actualizado a $M sesiones."
    PAUSA
}

crear_test_ssh(){
    echo -e "${CIAN}--- CREAR USUARIO DE PRUEBA (vence en 1 dia) ---${NC}"
    local NOMBRE USU CLAVE MAXC
    read -r -p "Nombre base (le agrego prefijo test-): " NOMBRE
    USU="test-$(echo "$NOMBRE" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z' | cut -c1-18)"
    nombre_usuario_valido "$USU" || { ERR "Nombre invalido."; PAUSA; return; }
    id "$USU" >/dev/null 2>&1 && { ERR "Ya existe."; PAUSA; return; }
    read -r -p "Conexion maxima [1]: " MAXC; MAXC=${MAXC:-1}
    [[ "$MAXC" =~ ^[0-9]+$ ]] || { ERR "Limite invalido."; PAUSA; return; }
    CLAVE=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 10)
    [[ -z "$CLAVE" ]] && CLAVE="test123456"
    useradd -m -s /bin/bash "$USU" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    echo "$USU:$CLAVE" | chpasswd
    chage -M 99999 -E "$(date -d '+1 day' +%Y-%m-%d)" "$USU" 2>/dev/null
    mkdir -p /etc/vps-limits; echo "$MAXC" > "/etc/vps-limits/$USU"
    xray_usuario add "$USU"
    vps_log INFO "test creado: $USU"
    OK "Usuario de prueba creado:"
    echo -e "  Usuario: ${VERDE}$USU${NC}   Clave: ${VERDE}$CLAVE${NC}"
    echo -e "  ${AMARILLO}Vence manana. IP: $(ip_publica)  Puerto: $(sshd_puerto_actual)${NC}"
    PAUSA
}

eliminar_vencidos(){
    local HOY BORRADOS=0 U EXPISO
    HOY=$(date +%F)
    while read -r U; do
        usuario_protegido "$U" && continue
        EXPISO=$(usuario_fecha_cuenta "$U")
        [[ "$EXPISO" == "never" ]] && continue
        if [[ "$EXPISO" < "$HOY" ]]; then
            if purgar_usuario "$U"; then
                INFO "Eliminado vencido: $U (vencio: $EXPISO)"
                vps_log INFO "vencido eliminado: $U ($EXPISO)"
                BORRADOS=$((BORRADOS+1))
            fi
        fi
    done < <(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
    [[ $BORRADOS -eq 0 ]] && OK "No hay usuarios vencidos." || OK "Eliminados $BORRADOS usuarios vencidos."
    PAUSA
}

mantenimiento(){
    INFO "Limpiando sistema..."
    apt autoremove -y >/dev/null 2>&1
    apt clean >/dev/null 2>&1
    journalctl --vacuum-time=7d >/dev/null 2>&1
    find /tmp -type f -mtime +7 -delete 2>/dev/null
    ls -t /root/backups/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    systemctl enable --now fstrim.timer >/dev/null 2>&1
    INFO "TRIM semanal: $(systemctl is-enabled fstrim.timer 2>/dev/null || echo "no aplica en este entorno")"
    OK "Listo: paquetes huerfanos, logs viejos, /tmp y backups (conservo los ultimos 3)."
    PAUSA
}

auto_menu(){
    if grep -q "VPS-JB-AUTOMENU-INICIO" "$HOME/.bashrc" 2>/dev/null; then
        OK "El auto-menu ya estaba activo."; PAUSA; return
    fi
    cat >> "$HOME/.bashrc" <<'AMEOF'
# VPS-JB-AUTOMENU-INICIO
case "$-" in *i*) [ -x /usr/local/bin/vpsmgr ] && /usr/local/bin/vpsmgr ;; esac
# VPS-JB-AUTOMENU-FIN
AMEOF
    OK "Auto-menu activo: la proxima vez que root inicie sesion (SSH o consola), el menu abre solo."
    PAUSA
}

quitar_auto_menu(){
    sed -i '/VPS-JB-AUTOMENU-INICIO/,/VPS-JB-AUTOMENU-FIN/d' "$HOME/.bashrc" 2>/dev/null
    OK "Auto-menu desactivado."
    PAUSA
}

diagnostico(){
    echo -e "${CIAN}--- DIAGNOSTICO DEL SERVIDOR ---${NC}"
    local RAM_P DISCO_P LOAD ADV=0
    RAM_P=$(free | awk '/Mem/{printf "%d", $3*100/$2}')
    DISCO_P=$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    echo -e " RAM: ${RAM_P}%   Disco: ${DISCO_P}%   Carga: $LOAD"
    [[ "$RAM_P" -gt 85 ]]    && { echo -e " ${ROJO}!${NC} RAM al ${RAM_P}%: cerrar procesos o agregar swap."; ADV=1; }
    [[ "$DISCO_P" -gt 85 ]]  && { echo -e " ${ROJO}!${NC} Disco al ${DISCO_P}%: correr Sistema -> Mantenimiento y revisar /root/backups."; ADV=1; }
    systemctl is-failed --quiet sshd 2>/dev/null && { echo -e " ${ROJO}!${NC} sshd con fallos: 'systemctl status sshd'."; ADV=1; }
    pgrep -f miniserv >/dev/null 2>&1 || echo -e " ${AMARILLO}-${NC} Webmin no corre (menu Webmin)."
    lastb -i 2>/dev/null | head -5 | grep -q . && echo -e " ${AMARILLO}-${NC} Intentos de login fallidos recientes: conviene Fail2ban (Seguridad -> Fail2ban)."
    [[ $ADV -eq 0 ]] && echo -e " ${VERDE}OK${NC} Sin alertas graves."
    PAUSA
}

cambiar_hostname(){
    echo -e "${CIAN}Hostname actual: ${BLANCO}$(hostname)${NC}"
    read -r -p "Nuevo hostname (sin espacios, ej. vps): " H
    [[ -z "$H" || "$H" =~ [^a-zA-Z0-9.-] ]] && { ERR "Hostname invalido."; PAUSA; return; }
    hostnamectl set-hostname "$H" 2>/dev/null || { ERR "No se pudo cambiar."; PAUSA; return; }
    sed -i "s/127.0.1.1.*/127.0.1.1\t$H/" /etc/hosts 2>/dev/null
    OK "Hostname cambiado a '$H'. Se ve completo en la proxima sesion."
    PAUSA
}

ghost_ver_de(){ grep -m1 "^GHOST_VER=" "$1" 2>/dev/null | cut -d"'" -f2; }

ghost_instalar_script(){
    # ghost_instalar_script ARCHIVO -> valida, compara versiones, respalda, instala y relanza
    local F="$1" NV CV="$GHOST_VER" DEST="$VPSMGR_DEST" RUN SN BK
    bash -n "$F" 2>/dev/null || { ERR "El archivo no es un script bash valido."; return 1; }
    grep -q "GHOST PANEL" "$F" || { ERR "No parece ser GHOST PANEL."; return 1; }
    NV=$(ghost_ver_de "$F")
    echo -e "  Instalada: ${AMARILLO}v${CV}${NC}    Nueva: ${VERDE}${NV:+v$NV}${NV:-sin version}${NC}"
    if [[ -z "$NV" ]]; then
        WARN "El archivo no declara version: es ANTERIOR al rediseno. Instalarlo pierde la interfaz y los arreglos."
    elif [[ "$NV" == "$CV" ]]; then
        INFO "Es la misma version que la instalada."
    elif [[ "$(printf '%s\n%s\n' "$CV" "$NV" | sort -V | tail -1)" == "$CV" ]]; then
        WARN "La nueva (v$NV) es MAS VIEJA que la instalada (v$CV)."
    fi
    read -r -p "  Instalar igual? (s/n): " SN
    [[ "$SN" == "s" ]] || { INFO "Cancelado."; return 1; }
    RUN="${GHOST_SELF:-$(readlink -f "$0" 2>/dev/null)}"
    mkdir -p /root/backups; chmod 700 /root/backups
    BK="/root/backups/ghost-panel-v${CV}-$(date +%F_%H%M%S).sh"
    if [[ -n "$RUN" && -f "$RUN" ]]; then cp -a "$RUN" "$BK" 2>/dev/null && INFO "Respaldo: $BK"; fi
    # install borra y recrea el destino: no corrompe el script que bash esta leyendo
    install -m 755 "$F" "$DEST" || { ERR "No se pudo escribir $DEST"; return 1; }
    OK "Instalado en $DEST (v${NV:-?})"
    if [[ -n "$RUN" && -f "$RUN" && "$RUN" != "$(readlink -f "$DEST")" && -w "$RUN" ]]; then
        install -m 755 "$F" "$RUN" 2>/dev/null && OK "Tambien actualizado el archivo que estas ejecutando: $RUN"
    fi
    vps_log INFO "script actualizado v$CV -> v${NV:-?}"
    read -r -p "  Reiniciar el panel ahora con la version nueva? (s/n): " SN
    [[ "$SN" == "s" ]] && exec "$DEST"
    return 0
}

auto_update_descargar(){
    local TMPF URL
    [[ -n "$REPO_RAW" ]] || { ERR "Fuente sin configurar (opcion 2)."; PAUSA; return; }
    URL="${REPO_RAW}$([[ "$REPO_RAW" == *\?* ]] && echo '&' || echo '?')cb=$(date +%s)"   # evita cache del CDN
    TMPF=$(mktemp /tmp/vpsmgr.XXXXXX) || { ERR "Sin temporal."; PAUSA; return; }
    INFO "Descargando desde: $REPO_RAW"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' "$URL" -o "$TMPF" 2>/dev/null
    else
        wget -q --no-cache -T 30 "$URL" -O "$TMPF" 2>/dev/null
    fi
    if [[ -s "$TMPF" ]]; then ghost_instalar_script "$TMPF"
    else ERR "No se pudo descargar. Revisa la URL (repo publico, enlace raw) y la red."; fi
    rm -f "$TMPF"
    PAUSA
}

auto_update(){
    local F U
    while true; do
        cabecera
        SUBTOP "ACTUALIZAR SCRIPT"
        ui_kv "Version" "v${GHOST_VER}"
        ui_kv "Fuente" "${REPO_RAW:-sin configurar}"
        FR_MID
        FR_OPT 1 "Actualizar desde la fuente" "" ""
        FR_OPT 2 "Cambiar fuente (URL raw)" "" ""
        FR_OPT 3 "Instalar desde archivo local" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) auto_update_descargar ;;
            2) read -r -p "  URL raw de TU repo (https://...): " U
               if [[ "$U" =~ ^https?://[^[:space:]]+$ ]]; then
                   touch /etc/ghost-panel.conf; chmod 600 /etc/ghost-panel.conf
                   sed -i '/^UPDATE_URL=/d' /etc/ghost-panel.conf
                   echo "UPDATE_URL=$U" >> /etc/ghost-panel.conf
                   REPO_RAW="$U"; OK "Fuente guardada."
               else ERR "URL invalida."; fi
               PAUSA ;;
            3) read -r -p "  Ruta del archivo .sh: " F
               if [[ -f "$F" ]]; then ghost_instalar_script "$F"; else ERR "No existe: $F"; fi
               PAUSA ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# CHECKUSER API (para apps cliente: validar usuarios SSH en JSON)
# ------------------------------------------------------------
checkuser_escribir_py(){
    cat > /usr/local/bin/vps-checkuser.py <<'PYEOF'
#!/usr/bin/env python3
import datetime, hmac, json, os, re, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
CONF = "/etc/vps-checkuser.conf"
ENV_C = dict(os.environ)
ENV_C["LC_ALL"] = "C"
ENV_C["LANG"] = "C"
NAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
def conf():
    d = {"PORT": "8080", "TOKEN": ""}
    try:
        for line in open(CONF):
            k, _, v = line.strip().partition("=")
            if k in ("PORT", "TOKEN"): d[k] = v.strip()
    except FileNotFoundError: pass
    return d
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, env=ENV_C, timeout=5)
def uid_of(name):
    r = sh("id", "-u", name)
    s = r.stdout.strip()
    return int(s) if r.returncode == 0 and s.isdigit() else None
def account_expiry(name):
    # Vencimiento de la CUENTA (chage -E). Antes se leia "Password expires": siempre vacio.
    for line in sh("chage", "-l", name).stdout.splitlines():
        if line.startswith("Account expires"):
            v = line.split(":", 1)[1].strip()
            if not v or v.lower() == "never": return None
            try: return datetime.datetime.strptime(v, "%b %d, %Y").date()
            except ValueError: return None
    return None
def online_count(name):
    n = 0
    for l in sh("ps", "-eo", "user:32=,comm=").stdout.splitlines():
        p = l.split()
        if len(p) >= 2 and p[0] == name and p[1] in ("sshd", "dropbear"): n += 1
    return n
def read_limit(name):
    try: return int(open("/etc/vps-limits/" + name).read().strip())
    except (FileNotFoundError, ValueError): return 0
def user_info(name):
    uid = uid_of(name) if NAME_RE.match(name) else None
    if uid is None or uid < 1000:
        msg = "Usuario no existe"
        return {"username": name, "user": name, "exists": False, "status": "notfound", "expired": True,
                "expiration": "", "expiration_date": "", "expiration_days": "0", "days_left": 0,
                "remaining": 0, "warning": msg, "warn": msg, "count_connection": "0", "online": 0,
                "limit_connection": "0", "limit": 0}
    exp = account_expiry(name)
    today = datetime.date.today()
    status, warn = "active", ""
    if exp is None:
        days, exp_iso, exp_dmy = 9999, "Sin vencimiento", "Sin vencimiento"
    else:
        days = (exp - today).days
        exp_iso, exp_dmy = exp.strftime("%Y-%m-%d"), exp.strftime("%d/%m/%Y")
        if days <= 0:
            status, days, warn = "expired", 0, "Cuenta vencida"
        elif days <= 3:
            warn = "Por vencer: quedan %d dias" % days
    online = online_count(name)
    lim = read_limit(name)
    # Aliases (user/exp/days/warn) + formato tipo DTunnel (expiration_date/expiration_days/count_connection)
    return {"username": name, "user": name, "exists": True, "status": status,
            "expired": status == "expired",
            "expiration": exp_iso, "expiration_date": exp_dmy,
            "expiration_days": str(days), "days_left": days, "remaining": days,
            "warning": warn, "warn": warn,
            "count_connection": str(online), "online": online,
            "limit_connection": str(lim), "limit": lim}
class H(BaseHTTPRequestHandler):
    timeout = 10
    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        c = conf(); u = urlparse(self.path); qs = parse_qs(u.query)
        if c["TOKEN"] and not hmac.compare_digest(qs.get("token", [""])[0], c["TOKEN"]):
            return self._send(403, {"error": "forbidden"})
        if u.path in ("/checkuser.php", "/checkuser", "/check"):
            name = qs.get("user", [""])[0]
            if not name: return self._send(400, {"error": "falta parametro user"})
            return self._send(200, user_info(name))
        if u.path == "/status":
            tot = sh("awk", "-F:", "$3>=1000 && $1!=\"nobody\"", "/etc/passwd").stdout
            return self._send(200, {"service": "checkuser",
                                    "online_now": len([1 for l in sh("ps", "-eo", "user:32=,comm=").stdout.splitlines()
                                                       if len(l.split()) >= 2 and l.split()[1] in ("sshd", "dropbear") and l.split()[0] != "root"]),
                                    "total_users": len([l for l in tot.splitlines() if l.strip()])})
        return self._send(404, {"error": "not found"})
if __name__ == "__main__":
    c = conf()
    print("checkuser en 0.0.0.0:%s" % c["PORT"], flush=True)
    ThreadingHTTPServer(("0.0.0.0", int(c["PORT"])), H).serve_forever()
PYEOF
    chmod 755 /usr/local/bin/vps-checkuser.py
}

checkuser_instalar(){
    echo -e "${CIAN}--- INSTALADOR CHECKUSER ---${NC}"
    local PORT TOKEN
    read -r -p "Puerto para el checkuser [8080]: " PORT; PORT=${PORT:-8080}
    [[ "$PORT" =~ ^[0-9]+$ ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Token de seguridad (entero = aleatorio): " TOKEN
    [[ -z "$TOKEN" ]] && TOKEN=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 20)
    printf 'PORT=%s\nTOKEN=%s\n' "$PORT" "$TOKEN" > /etc/vps-checkuser.conf
    chmod 600 /etc/vps-checkuser.conf
    checkuser_escribir_py

    cat > /etc/systemd/system/vps-checkuser.service <<SVCEOF
[Unit]
Description=CheckUser API (VPS-JORGEBARRIOS)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vps-checkuser.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now vps-checkuser 2>/dev/null
    ufw allow "$PORT/tcp" >/dev/null 2>&1
    local IP; IP=$(ip_publica)
    OK "CheckUser instalado y corriendo."
    echo -e " Prueba desde la VM:  curl http://localhost:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    echo -e " Desde afuera:        http://$IP:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    echo -e " ${AMARILLO}Guarda este token, se guarda en /etc/vps-checkuser.conf${NC}"
    PAUSA
}

checkuser_probar(){
    local P T IP
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(ip_publica)
    read -r -p "Usuario a consultar: " U
    echo
    curl -s "http://localhost:${P:-8080}/checkuser.php?user=$U&token=$T" && echo || ERR "No responde. Estado:"
    systemctl status vps-checkuser --no-pager 2>/dev/null | head -6
    PAUSA
}

checkuser_quitar(){
    systemctl disable --now vps-checkuser 2>/dev/null
    rm -f /usr/local/bin/vps-checkuser.py /etc/systemd/system/vps-checkuser.service /etc/vps-checkuser.conf
    systemctl daemon-reload 2>/dev/null
    OK "CheckUser removido."
    PAUSA
}

menu_checkuser(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_cu)"
        FR_OPT 1 "$(T t_cu_inst)" 4 "$(T t_cu_token)"
        FR_OPT 2 "$(T t_estado_svc)" 5 "$(T t_remover)"
        FR_OPT 3 "$(T t_cu_probar)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) checkuser_instalar ;;
            2) systemctl status vps-checkuser --no-pager 2>/dev/null | head -15; PAUSA ;;
            3) checkuser_probar ;;
            4) cat /etc/vps-checkuser.conf 2>/dev/null || ERR "No instalado."; PAUSA ;;
            5) checkuser_quitar ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

reiniciar_vps(){
    read -r -p "Reiniciar el VPS ahora? Los servicios caeran. (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        WARN "Reiniciando en 3 segundos..."
        sleep 3
        reboot
    else
        OK "Reinicio cancelado."
        PAUSA
    fi
}

# ------------------------------------------------------------
# PROTOCOLOS / CONEXIONES (Xray, OpenVPN)
# ------------------------------------------------------------
instalar_xray(){
    if command -v xray >/dev/null 2>&1; then
        read -r -p "Xray ya esta instalado. Reinstalar/configurar de nuevo? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR XRAY (VLESS + REALITY) ---${NC}"
    read -r -p "Puerto para Xray [8443]: " XP; XP=${XP:-8443}
    [[ "$XP" =~ ^[0-9]+$ && "$XP" -ge 1 && "$XP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "SNI (dominio camuflaje) [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}

    INFO "Instalando Xray (descarga oficial)..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
        || { ERR "No se pudo instalar Xray (sin red?)."; PAUSA; return; }

    local KEYS UUID
    KEYS=$(xray x25519 2>/dev/null)
    local PRIV PUB
    PRIV=$(echo "$KEYS" | awk '/[Pp]rivate/{print $NF; exit}')
    PUB=$(echo "$KEYS"  | awk '/[Pp]ublic|Password/{print $NF; exit}')
    UUID=$(xray uuid)
    [[ -z "$PRIV" || -z "$PUB" || -z "$UUID" ]] && { ERR "No se pudieron generar las claves."; PAUSA; return; }

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XP,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": [""]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
XEOF

    xray_config_perms
    ufw allow "$XP/tcp" >/dev/null 2>&1
    systemctl enable --now xray 2>/dev/null || { /usr/local/bin/xray run -c /usr/local/etc/xray/config.json & }
    sleep 2
    local IP; IP=$(ip_publica)
    local LINK="vless://$UUID@$IP:$XP?security=reality&encryption=none&pbk=$PUB&fp=chrome&sni=$SNI&flow=xtls-rprx-vision&sid=#VPS-JORGEBARRIOS"
    OK "Xray corriendo en el puerto $XP"
    echo
    echo -e " ${AMARILLO}Enlace para tu app (VLESS + Reality):${NC}"
    echo -e " ${VERDE}$LINK${NC}"
    echo
    INFO "Guarda ese enlace: es la config que importas en el cliente (v2rayNG / tu app)."
    PAUSA
}

instalar_openvpn(){
    if command -v openvpn >/dev/null 2>&1; then
        ERR "OpenVPN ya esta instalado."; PAUSA; return
    fi
    INFO "Descargando instalador de OpenVPN..."
    curl -fsSL -o /root/openvpn-install.sh https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh \
        || { ERR "Sin red, no se pudo descargar."; PAUSA; return; }
    chmod +x /root/openvpn-install.sh
    INFO "Arrancando instalador (configuralo con los valores que quieras)..."
    AUTO_INSTALL=y bash /root/openvpn-install.sh
    OK "Listo. El archivo .ovpn del cliente queda en /root/"
    PAUSA
}

instalar_ssl_stunnel(){
    if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
        read -r -p "Stunnel ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR SSL (STUNNEL) ---${NC}"
    read -r -p "Puerto SSL [443]: " SP; SP=${SP:-443}
    [[ "$SP" =~ ^[0-9]+$ && "$SP" -ge 1 && "$SP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Puerto SSH destino [22]: " SSHP; SSHP=${SSHP:-22}

    INFO "Instalando stunnel4..."
    apt update -y >/dev/null 2>&1
    apt install -y stunnel4 >/dev/null 2>&1 || { ERR "No se pudo instalar stunnel4."; PAUSA; return; }

    INFO "Generando certificado autofirmado (10 años)..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=vps-jorgebarrios" \
        -keyout /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
    cat /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key > /etc/stunnel/stunnel.pem 2>/dev/null
    chmod 600 /etc/stunnel/stunnel.key /etc/stunnel/stunnel.pem 2>/dev/null

    cat > /etc/stunnel/stunnel.conf <<SEOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1

[ssh-ssl]
accept = $SP
connect = 127.0.0.1:$SSHP
SEOF

    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    ufw allow "$SP/tcp" >/dev/null 2>&1
    systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null
    sleep 1
    local IP; IP=$(ip_publica)
    if pgrep -f stunnel >/dev/null 2>&1; then
        OK "Stunnel ACTIVO: SSL en el puerto $SP -> SSH local $SSHP"
        echo
        echo -e " ${AMARILLO}Datos para la config del cliente (HTTP Injector / tu app):${NC}"
        echo -e "  IP/Host: ${VERDE}$IP${NC}   Puerto SSL: ${VERDE}$SP${NC}"
        echo -e "  La app debe conectar por SSL/TLS al $SP y el trafico sale por SSH ($SSHP)."
    else
        ERR "Stunnel no levanto. Revisa con: systemctl status stunnel4"
    fi
    PAUSA
}

# ============================================================
#  ESTADO Y PUERTOS: que servicio escucha en que puerto (datos reales de ss)
# ============================================================
ss_listen_tabla(){
    # una linea por socket en escucha: proto puerto proceso pid ambito(P=publico/L=local)
    ss -tulnp 2>/dev/null | tail -n +2 | awk '
        { n=split($5,a,":"); port=a[n]; proc="-"; pid="0"
          scope = ($5 ~ /^(127\.|\[::1\])/) ? "L" : "P"
          if (match($0,/users:\(\("[^"]+"/)) proc=substr($0,RSTART+9,RLENGTH-10)
          if (match($0,/pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4)
          print $1, port, proc, pid, scope }' | sort -u
}

UFW_RULES=""; UFW_ON=0
ufw_cargar(){
    UFW_RULES=""; UFW_ON=0
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    UFW_ON=1
    UFW_RULES=$(ufw status 2>/dev/null | awk '/ALLOW/{print $1}')
}
ufw_permite(){ # ufw_permite puerto/proto
    local p="${1%/*}" pr="${1#*/}"
    grep -qxE "${p}(/${pr})?" <<< "$UFW_RULES"
}

svc_ports(){
    # svc_ports TABLA modo patron -> "22/tcp, 443/tcp(local)" ; modo: name (proceso) | cmd (linea de comando)
    local tab="$1" mode="$2" pat="$3" proto port proc pid scope out=""
    while read -r proto port proc pid scope; do
        [[ -n "$port" ]] || continue
        if [[ "$mode" == name ]]; then
            [[ "$proc" =~ $pat ]] || continue
        else
            [[ -r "/proc/$pid/cmdline" ]] || continue
            tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qE "$pat" || continue
        fi
        if [[ "$scope" == "L" ]]; then out+="${port}/${proto}(local)"$'\n'
        elif (( UFW_ON )) && ! ufw_permite "${port}/${proto}"; then out+="${port}/${proto}▲"$'\n'
        else out+="${port}/${proto}"$'\n'; fi
    done <<< "$tab"
    printf '%s' "$out" | sort -t/ -k1,1n -k2,2 -u | paste -sd, - | sed 's/,/, /g'
}

svc_conns(){
    # conexiones TCP establecidas (sin las de loopback: WS/Stunnel hablan con sshd por 127.0.0.1)
    local e p tot=0 n
    for e in ${1//,/ }; do
        [[ "$e" == */tcp* ]] || continue
        p="${e%%/*}"
        n=$(ss -tn state established "( sport = :${p} and not dst 127.0.0.0/8 )" 2>/dev/null | tail -n +2 | wc -l)
        tot=$((tot+n))
    done
    echo "$tot"
}

svc_row(){
    # svc_row on|off NOMBRE PUERTOS CONEXIONES   (relleno por caracteres: ▲ ocupa 3 bytes)
    local dot name="${2:0:18}" ports="${3:-}" conn="${4:-}"
    if [[ "$1" == on ]]; then dot="${VERDE}●${NC}"; else dot="${ROJO}○${NC}"; ports="detenido"; fi
    [[ -z "$ports" ]] && ports="-"
    ports="${ports:0:20}"
    FR_TXT "  ${dot} ${BLANCO}${name}${NC}$(printf '%*s' $((19 - ${#name})) '')${CIAN}${ports}${NC}$(printf '%*s' $((21 - ${#ports})) '')${GRIS}${conn}${NC}"
}

svc_check(){
    # svc_check "Nombre" "prueba-de-instalado" modo patron   (usa TAB / NOINST del llamador)
    local name="$1" inst="$2" mode="$3" pat="$4" ports conn=""
    if ! eval "$inst" >/dev/null 2>&1; then NOINST+="${NOINST:+, }$name"; return 0; fi
    ports=$(svc_ports "$TAB" "$mode" "$pat")
    if [[ -n "$ports" ]]; then conn=$(svc_conns "$ports"); svc_row on "$name" "$ports" "$conn"
    else svc_row off "$name"; fi
}

xray_inbounds_lista(){
    python3 - <<'XPYEOF' 2>/dev/null
import json
try:
    c = json.load(open("/usr/local/etc/xray/config.json"))
except Exception:
    raise SystemExit
for ib in c.get("inbounds", []):
    p = ib.get("port"); pr = str(ib.get("protocol", "?")).upper()
    st = ib.get("streamSettings") or {}
    net = st.get("network", "tcp"); sec = st.get("security", "none")
    if ib.get("listen") in ("127.0.0.1", "localhost") and pr in ("DOKODEMO-DOOR", "HTTP", "SOCKS"):
        continue
    lab = pr
    if sec == "reality": lab += " Reality"
    elif net == "ws": lab += " WS"
    elif sec == "tls": lab += " TLS"
    print("%s|%s" % (p, lab))
XPYEOF
}

puertos_servicios(){
    local TAB NOINST="" xl xp xlab wgp conn ipv ufwtxt
    TAB=$(ss_listen_tabla)
    ufw_cargar
    ipv=$(ip_publica)
    if (( UFW_ON )); then ufwtxt="${VERDE}activo${NC}"; else ufwtxt="${AMARILLO}inactivo${NC}"; fi
    ui_box_top "ESTADO Y PUERTOS"
    FR_TXT "  ${GRIS}IP${NC} ${CIAN}${ipv}${NC}   ${GRIS}UFW${NC} ${ufwtxt}"
    FR_MID
    FR_TXT "  ${GRIS}  SERVICIO           PUERTO(S)            CONEX${NC}"
    svc_check "OpenSSH"      "command -v sshd"  name '^sshd$'
    svc_check "Dropbear"     "command -v dropbear" name '^dropbear$'
    svc_check "Stunnel SSL"  "command -v stunnel4 || command -v stunnel" name '^stunnel4?$'
    svc_check "WS-epro"      "[ -f /usr/local/bin/vpsjb-ws.py ]" cmd 'vpsjb-ws\.py'
    # Xray: una fila por inbound (protocolo + puerto reales de config.json)
    if command -v xray >/dev/null 2>&1; then
        xl=$(xray_inbounds_lista)
        if [[ -n "$xl" ]]; then
            while IFS='|' read -r xp xlab; do
                [[ -n "$xp" ]] || continue
                if grep -q "^tcp ${xp} xray" <<< "$TAB"; then
                    conn=$(svc_conns "${xp}/tcp")
                    if (( UFW_ON )) && ! ufw_permite "${xp}/tcp"; then svc_row on "Xray ${xlab}" "${xp}/tcp▲" "$conn"
                    else svc_row on "Xray ${xlab}" "${xp}/tcp" "$conn"; fi
                else svc_row off "Xray ${xlab}"; fi
            done <<< "$xl"
        else
            svc_check "Xray" "true" name '^xray$'
        fi
    else NOINST+="${NOINST:+, }Xray"; fi
    svc_check "Hysteria2"    "command -v hysteria" name '^hysteria'
    svc_check "Shadowsocks"  "systemctl cat vpsjb-ss" name '^ss-server$'
    svc_check "OpenVPN"      "command -v openvpn" name '^openvpn$'
    # WireGuard: el puerto lo tiene el kernel (no hay proceso en ss)
    if command -v wg >/dev/null 2>&1 && [[ -f /etc/wireguard/wg0.conf ]]; then
        wgp=$(wg show wg0 listen-port 2>/dev/null)
        if [[ -n "$wgp" ]]; then svc_row on "WireGuard" "${wgp}/udp" ""; else svc_row off "WireGuard"; fi
    else NOINST+="${NOINST:+, }WireGuard"; fi
    svc_check "BadVPN UDPGW" "command -v badvpn-udpgw" name '^badvpn'
    svc_check "CheckUser API" "[ -f /usr/local/bin/vps-checkuser.py ]" cmd 'vps-checkuser\.py'
    svc_check "Webmin"       "[ -d /etc/webmin ]" cmd 'miniserv'
    svc_check "Squid"        "command -v squid" name '^squid$'
    FR_MID
    FR_TXT "  ${VERDE}●${NC} ${GRIS}escuchando${NC}  ${ROJO}○${NC} ${GRIS}detenido${NC}  ${AMARILLO}▲${NC} ${GRIS}sin regla UFW${NC}"
    if [[ -n "$NOINST" ]]; then
        while IFS= read -r xl || [[ -n "$xl" ]]; do FR_TXT "  ${GRIS}${xl}${NC}"; done < <(printf 'No instalados: %s' "$NOINST" | fold -s -w $((UI_W - 4)))
    fi
    FR_BOT
}

puertos_todos(){
    local TAB proto port proc pid scope amb mark
    TAB=$(ss_listen_tabla)
    ufw_cargar
    ui_box_top "TODOS LOS PUERTOS EN ESCUCHA"
    FR_TXT "  ${GRIS}PUERTO      PROCESO            AMBITO${NC}"
    while read -r proto port proc pid scope; do
        [[ -n "$port" ]] || continue
        mark=""; amb="publico"
        if [[ "$scope" == "L" ]]; then amb="local"
        elif (( UFW_ON )) && ! ufw_permite "${port}/${proto}"; then mark="${AMARILLO} ▲${NC}"; fi
        FR_TXT "$(printf '  %b%-11s%b %b%-18s%b %b%s%b%b' "$CIAN" "${port}/${proto}" "$NC" "$BLANCO" "${proc:0:18}" "$NC" "$GRIS" "$amb" "$NC" "$mark")"
    done < <(sort -k2,2n -k1,1 <<< "$TAB")
    FR_BOT
}

menu_puertos(){
    while true; do
        clear
        ui_init
        puertos_servicios
        echo
        FR_TOP
        FR_OPT 1 "Actualizar" 2 "Todos los puertos"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) ;;
            2) clear; ui_init; puertos_todos; PAUSA ;;
            0) break ;;
            *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

estado_protocolos(){ menu_puertos; }

# ------------------------------------------------------------
# TRAFICO POR USUARIO (iptables)
# ------------------------------------------------------------
trafico_activar(){
    iptables -N VPS-TRAFFIC 2>/dev/null
    iptables -F VPS-TRAFFIC 2>/dev/null
    local N=0 U
    for U in $(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd); do
        iptables -A VPS-TRAFFIC -m owner --uid-owner "$U" -j RETURN 2>/dev/null && N=$((N+1))
    done
    iptables -C OUTPUT -j VPS-TRAFFIC 2>/dev/null || iptables -A OUTPUT -j VPS-TRAFFIC 2>/dev/null
    [[ $N -gt 0 ]] && OK "Contadores activos para $N usuarios (se suman usuarios nuevos al re-activar)." \
                   || ERR "No se pudieron crear reglas (iptables fallo?)."
    PAUSA
}

trafico_ver(){
    echo -e "${CIAN}--- CONSUMO POR USUARIO (desde el ultimo reset) ---${NC}"
    printf "%-16s %-12s %s\n" "USUARIO" "USADO" "LIMITE(GB)"
    iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk '/owner UID match/ {print $2, $NF}' | while read -r BYTES UIDN; do
        local U MB LIM
        U=$(id -un "$UIDN" 2>/dev/null || echo "uid$UIDN")
        MB=$(( BYTES / 1048576 ))
        LIM=$(cat "/etc/vps-trafico/$U" 2>/dev/null || echo "-")
        printf "%-16s %7d MB   %s\n" "$U" "$MB" "$LIM"
    done
    echo
    INFO "Para medir desde cero, usa la opcion 'reset' del menu de trafico."
    PAUSA
}

trafico_limite(){
    local USU G
    pedir_usuario_ok USU || { PAUSA; return; }
    read -r -p "Limite en GB (0 = sin limite): " G
    [[ "$G" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    mkdir -p /etc/vps-trafico
    echo "$G" > "/etc/vps-trafico/$USU"
    OK "Limite de $USU = ${G}GB."
    PAUSA
}

trafico_cortar(){
    local CORTADOS=0
    for F in /etc/vps-trafico/*; do
        [[ -f "$F" ]] || continue
        local U G USED
        U=$(basename "$F"); G=$(cat "$F")
        [[ "$G" =~ ^[0-9]+$ && "$G" -gt 0 ]] || continue
        USED=$(iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk -v uid="$(id -u "$U" 2>/dev/null)" '/owner UID match/ && $NF==uid {print $2; exit}')
        [[ -n "$USED" && $(( USED / 1073741824 )) -ge "$G" ]] || continue
        if ! passwd -S "$U" 2>/dev/null | grep -q ' L '; then
            usermod -L "$U" 2>/dev/null; pkill -u "$U" 2>/dev/null
            INFO "$U supero su limite (${G}GB) y fue bloqueado."
            CORTADOS=$((CORTADOS+1))
        fi
    done
    [[ $CORTADOS -eq 0 ]] && OK "Nadie supero su limite." || OK "Bloqueados: $CORTADOS."
    PAUSA
}

trafico_reset(){
    iptables -Z VPS-TRAFFIC 2>/dev/null && OK "Contadores en cero." || ERR "La cadena no existe (activa antes)."
    PAUSA
}

menu_trafico(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_trafico)"
        FR_OPT 1 "$(T t_tr_activar)" 4 "$(T t_tr_cortar)"
        FR_OPT 2 "$(T t_tr_ver)" 5 "$(T t_tr_reset)"
        FR_OPT 3 "$(T t_tr_limite)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) trafico_activar ;;
            2) trafico_ver ;;
            3) trafico_limite ;;
            4) trafico_cortar ;;
            5) trafico_reset ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SWAP / HYSTERIA2 / RESTORE
# ------------------------------------------------------------
agregar_swap(){
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        ERR "Ya hay una swapfile activa."; PAUSA; return
    fi
    read -r -p "Tamaño del swap en GB [1]: " G; G=${G:-1}
    [[ "$G" =~ ^[0-9]+$ && "$G" -ge 1 ]] || { ERR "Tamaño invalido."; PAUSA; return; }
    INFO "Creando swap de ${G}GB..."
    fallocate -l "${G}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((G*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile 2>/dev/null
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        OK "Swap de ${G}GB activa y persistente."
    else
        rm -f /swapfile
        ERR "No se pudo activar la swap."
    fi
    PAUSA
}

instalar_hysteria(){
    if command -v hysteria >/dev/null 2>&1; then
        read -r -p "Hysteria2 ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR HYSTERIA2 (UDP) ---${NC}"
    read -r -p "Puerto UDP [8443]: " HP; HP=${HP:-8443}
    [[ "$HP" =~ ^[0-9]+$ && "$HP" -ge 1 && "$HP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1 \
        || { ERR "No se pudo instalar (sin red?)."; PAUSA; return; }
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=vps-jorgebarrios" \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt >/dev/null 2>&1
    local PASS; PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
    cat > /etc/hysteria/config.yaml <<HEOF
listen: :$HP
auth:
  type: password
  password: "$PASS"
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
HEOF
    if id hysteria >/dev/null 2>&1; then
        chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt /etc/hysteria/config.yaml
        chmod 600 /etc/hysteria/server.key
    else
        chmod 644 /etc/hysteria/server.key
    fi
    ufw allow "$HP/udp" >/dev/null 2>&1
    systemctl enable --now hysteria-server >/dev/null 2>&1
    sleep 1
    local IP; IP=$(ip_publica)
    if systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -x hysteria >/dev/null 2>&1; then
        OK "Hysteria2 corriendo en UDP $HP"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (NekoBox / tu app):${NC}"
        echo -e " ${VERDE}hysteria2://$PASS@$IP:$HP/?insecure=1#VPS-JORGEBARRIOS${NC}"
    else
        ERR "Hysteria no levanto. Revisa: journalctl -u hysteria-server"
    fi
    PAUSA
}

restaurar_backup(){
    local DIR=/root/backups
    echo -e "${CIAN}--- BACKUPS DISPONIBLES ---${NC}"
    ls -lh "$DIR"/*.tar.gz 2>/dev/null || { ERR "No hay backups en $DIR."; PAUSA; return; }
    read -r -p "Archivo a restaurar (nombre exacto, Enter = el mas reciente): " F
    [[ -z "$F" ]] && F=$(ls -t "$DIR"/*.tar.gz 2>/dev/null | head -1)
    [[ -f "$F" ]] || F="$DIR/$(basename "$F")"
    [[ -f "$F" ]] || { ERR "Archivo no encontrado."; PAUSA; return; }
    echo
    echo -e "${ROJO}ATENCION: esto pisa la configuracion actual de /etc${NC}"
    echo -e "${ROJO}(incluye usuarios, claves y la key de licencia).${NC}"
    read -r -p "Escribi RESTAURAR para confirmar: " CONF
    [[ "$CONF" != "RESTAURAR" ]] && { ERR "Cancelado."; PAUSA; return; }
    INFO "Restaurando $F ..."
    tar xzf "$F" -C / 2>/dev/null || { ERR "La restauracion fallo o quedo incompleta."; PAUSA; return; }
    OK "Restaurado. Recomendado: reiniciar el VPS (Sistema -> Reiniciar VPS)."
    PAUSA
}

# ------------------------------------------------------------
# BADVPN (UDP GW - juegos y llamadas por el tunel)
# ------------------------------------------------------------
instalar_badvpn(){
    if pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        read -r -p "BadVPN ya esta corriendo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
        systemctl disable --now badvpn 2>/dev/null
        pkill -f badvpn-udpgw 2>/dev/null
        sleep 1
    fi

    echo -e "${CIAN}--- INSTALADOR BADVPN (UDP GW) ---${NC}"
    read -r -p "Puerto UDP GW [7300]: " BP; BP=${BP:-7300}
    [[ "$BP" =~ ^[0-9]+$ && "$BP" -ge 1 && "$BP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }

    # El paquete "badvpn" NO existe en los repos de Ubuntu 22.04/24.04.
    # Se compila solo el modulo udpgw desde el codigo fuente oficial.
    if command -v badvpn-udpgw >/dev/null 2>&1; then
        INFO "Binario ya presente, reconfigurando servicio..."
    else
        INFO "Compilando badvpn-udpgw desde codigo fuente (no existe en apt)..."
        apt update -y >/dev/null 2>&1
        apt install -y cmake build-essential gcc g++ make wget >/dev/null 2>&1 \
            || { ERR "Faltan dependencias de compilacion (cmake, gcc, make...)."; PAUSA; return; }

        local TMPDIR
        TMPDIR=$(mktemp -d /tmp/badvpn-XXXXXX) || { ERR "No se pudo crear directorio temporal."; PAUSA; return; }
        (
            cd "$TMPDIR" || exit 1
            # Fuente oficial estable 1.999.130
            if ! wget -q --timeout=25 -O badvpn.tar.gz \
                "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz"; then
                ERR "No se pudo descargar el codigo fuente (sin red?)."; exit 1
            fi
            tar xzf badvpn.tar.gz || { ERR "Error al descomprimir."; exit 1; }
            cd badvpn-1.999.130 || exit 1
            mkdir -p build && cd build
            cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 \
                || { ERR "cmake fallo."; exit 1; }
            make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1 \
                || { ERR "Compilacion fallo."; exit 1; }
            make install >/dev/null 2>&1 \
                || { ERR "make install fallo."; exit 1; }
        )
        local RC=$?
        rm -rf "$TMPDIR"
        if [[ $RC -ne 0 ]]; then
            PAUSA; return
        fi
        # Asegurar que el binario quede accesible
        if [[ -f /usr/local/bin/badvpn-udpgw ]]; then
            chmod 755 /usr/local/bin/badvpn-udpgw
            OK "badvpn-udpgw compilado e instalado en /usr/local/bin/"
        else
            ERR "El binario no se genero correctamente."
            PAUSA; return
        fi
    fi

    # Servicio systemd (binario en /usr/local/bin)
    cat > /etc/systemd/system/badvpn.service <<BEOF
[Unit]
Description=BadVPN UDP Gateway (Ghost Panel)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${BP} --max-clients 500 --max-connections-for-client 10
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
BEOF

    systemctl daemon-reload
    systemctl enable --now badvpn 2>/dev/null
    sleep 1

    if systemctl is-active --quiet badvpn 2>/dev/null || pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        OK "BadVPN ACTIVO en 127.0.0.1:${BP}"
        echo
        echo -e " ${AMARILLO}En la app del cliente (HTTP Injector / eProxy / tu app):${NC}"
        echo -e "  UDP Gateway: ${VERDE}127.0.0.1:${BP}${NC} a traves del tunel SSH/SSL"
        echo -e "  ${CIAN}Con eso funcionan juegos UDP y llamadas de WhatsApp/Telegram.${NC}"
        vps_log INFO "badvpn instalado/activado puerto $BP"
    else
        ERR "BadVPN no levanto. Revisa: journalctl -u badvpn -n 30"
    fi
    PAUSA
}

quitar_badvpn(){
    systemctl disable --now badvpn 2>/dev/null
    rm -f /etc/systemd/system/badvpn.service
    systemctl daemon-reload 2>/dev/null
    pkill -f badvpn-udpgw 2>/dev/null
    # Eliminar binario compilado (no viene de apt)
    rm -f /usr/local/bin/badvpn-udpgw /usr/bin/badvpn-udpgw 2>/dev/null
    OK "BadVPN detenido y removido (servicio + binario)."
    PAUSA
}

# ------------------------------------------------------------
# WEBSOCKET: VLESS+WS (Xray) y WS-epro (proxy WS->SSH propio)
# ------------------------------------------------------------
instalar_xray_ws(){
    if ! command -v xray >/dev/null 2>&1; then
        INFO "Xray no esta instalado, instalando primero..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
            || { ERR "No se pudo instalar Xray."; PAUSA; return; }
    fi
    echo -e "${CIAN}--- XRAY VLESS + WEBSOCKET (para CDN) ---${NC}"
    read -r -p "Puerto WS [8080]: " WP; WP=${WP:-8080}
    [[ "$WP" =~ ^[0-9]+$ && "$WP" -ge 1 && "$WP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Path WS [/vpsjb]: " WPATH; WPATH=${WPATH:-/vpsjb}
    [[ "$WPATH" == /* ]] || WPATH="/$WPATH"
    local UUID; UUID=$(xray uuid)
    mkdir -p /usr/local/etc/xray
    python3 - "$WP" "$WPATH" "$UUID" <<'PYEOF'
import json, sys
port, path, uid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cfgp = "/usr/local/etc/xray/config.json"
try:
    cfg = json.load(open(cfgp))
except Exception:
    cfg = {"log":{"loglevel":"warning"},"inbounds":[],
           "outbounds":[{"protocol":"freedom"}]}
ib = [i for i in cfg.get("inbounds", []) if i.get("port") != port]
ib.append({
    "port": port,
    "protocol": "vless",
    "settings": {"clients":[{"id": uid}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": path}},
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
})
cfg["inbounds"] = ib
json.dump(cfg, open(cfgp, "w"), indent=2)
print("ok")
PYEOF
    xray_config_perms
    ufw allow "$WP/tcp" >/dev/null 2>&1
    systemctl restart xray 2>/dev/null
    sleep 1
    local IP; IP=$(ip_publica)
    if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
        OK "Xray WS corriendo en el puerto $WP (path $WPATH)"
        echo
        echo -e " ${AMARILLO}Enlace VLESS + WebSocket (ponelo detras de Cloudflare):${NC}"
        echo -e " ${VERDE}vless://$UUID@$IP:$WP?type=ws&path=%2F${WPATH#/}&security=none#VPSJB-WS${NC}"
        INFO "En tu app: network=ws, path=$WPATH, TLS desactivado (el CDN lo pone)."
    else
        ERR "Xray no levanto. Revisa: journalctl -u xray"
    fi
    PAUSA
}

instalar_wsepro(){
    if systemctl is-active --quiet vpsjb-ws 2>/dev/null; then
        read -r -p "WS-epro ya esta corriendo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- WEBSOCKET SSH (ws-epro propio, WS -> SSH) ---${NC}"
    read -r -p "Puerto WS [80]: " EP; EP=${EP:-80}
    [[ "$EP" =~ ^[0-9]+$ && "$EP" -ge 1 && "$EP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    local SSHP; SSHP=$(sshd_puerto_actual)

    cat > /usr/local/bin/vpsjb-ws.py <<'WSEOF'
#!/usr/bin/env python3
# Proxy WebSocket -> SSH. Solo libreria estandar.
#  - Cliente con Sec-WebSocket-Key: WebSocket estandar (con framing).
#  - HTTP Custom / HTTP Injector (payload "Upgrade: websocket" sin key): responde 101 y tunela TCP en crudo.
import socket, base64, hashlib, struct, threading, sys

LISTEN = ('0.0.0.0', int(sys.argv[1]) if len(sys.argv) > 1 else 80)
TARGET = ('127.0.0.1', int(sys.argv[2]) if len(sys.argv) > 2 else 22)
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

class Conn:
    """Socket con buffer inicial (bytes que llegaron pegados a las cabeceras HTTP)."""
    def __init__(self, sock, pre=b''):
        self.s, self.buf = sock, pre
    def recv(self, n):
        if self.buf:
            d, self.buf = self.buf[:n], self.buf[n:]
            return d
        return self.s.recv(n)

def recv_exact(c, n):
    out = b''
    while len(out) < n:
        chunk = c.recv(n - len(out))
        if not chunk:
            return None
        out += chunk
    return out

def read_headers(sock, limit=16384):
    data = b''
    while b'\r\n\r\n' not in data and len(data) < limit:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    head, sep, rest = data.partition(b'\r\n\r\n')
    return (head, rest) if sep else (b'', b'')

def unmask(payload, mask):
    if not payload:
        return payload
    m = (mask * (len(payload) // 4 + 1))[:len(payload)]
    return (int.from_bytes(payload, 'big') ^ int.from_bytes(m, 'big')).to_bytes(len(payload), 'big')

def read_frame(c):
    hdr = recv_exact(c, 2)
    if hdr is None:
        return None, None
    op = hdr[0] & 0x0F
    masked = hdr[1] & 0x80
    ln = hdr[1] & 0x7F
    if ln == 126:
        e = recv_exact(c, 2)
        if e is None:
            return None, None
        ln = struct.unpack('>H', e)[0]
    elif ln == 127:
        e = recv_exact(c, 8)
        if e is None:
            return None, None
        ln = struct.unpack('>Q', e)[0]
    mask = recv_exact(c, 4) if masked else None
    if masked and mask is None:
        return None, None
    payload = recv_exact(c, ln) if ln else b''
    if payload is None:
        return None, None
    if mask:
        payload = unmask(payload, mask)
    return op, payload

def send_frame(s, lock, data, op=2):
    h = bytes([0x80 | op])
    ln = len(data)
    if ln < 126:
        h += bytes([ln])
    elif ln < 65536:
        h += bytes([126]) + struct.pack('>H', ln)
    else:
        h += bytes([127]) + struct.pack('>Q', ln)
    with lock:
        s.sendall(h + data)

def kill(*socks):
    for s in socks:
        try:
            s.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass

def ws_to_tcp(conn, ws, tcp, lock):
    try:
        while True:
            op, data = read_frame(conn)
            if op is None or op == 8:
                break
            if op == 9:
                send_frame(ws, lock, data, 10)
                continue
            if op in (0, 1, 2) and data:
                tcp.sendall(data)
    except Exception:
        pass
    finally:
        kill(ws, tcp)

def tcp_to_ws(tcp, ws, lock):
    try:
        while True:
            data = tcp.recv(65536)
            if not data:
                break
            send_frame(ws, lock, data)
    except Exception:
        pass
    finally:
        kill(ws, tcp)

def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except Exception:
        pass
    finally:
        kill(a, b)

def handle(c):
    tcp = None
    try:
        c.settimeout(15)
        head, rest = read_headers(c)
        if not head:
            return
        key = ''
        for line in head.split(b'\r\n')[1:]:
            if line.lower().startswith(b'sec-websocket-key:'):
                key = line.split(b':', 1)[1].strip().decode('latin-1')
        tcp = socket.create_connection(TARGET, timeout=15)
        c.settimeout(None)
        tcp.settimeout(None)
        for s in (c, tcp):
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        lock = threading.Lock()
        if key:
            acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                       "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
            t1 = threading.Thread(target=ws_to_tcp, args=(Conn(c, rest), c, tcp, lock))
            t2 = threading.Thread(target=tcp_to_ws, args=(tcp, c, lock))
        else:
            c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            if rest:
                tcp.sendall(rest)
            t1 = threading.Thread(target=pipe, args=(c, tcp))
            t2 = threading.Thread(target=pipe, args=(tcp, c))
        t1.start(); t2.start()
        t1.join(); t2.join()
    except Exception:
        pass
    finally:
        for s in (c, tcp):
            try:
                if s:
                    s.close()
            except Exception:
                pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(LISTEN)
srv.listen(256)
print("WS->SSH proxy en %s:%d (destino %s:%d)" % (LISTEN[0], LISTEN[1], TARGET[0], TARGET[1]), flush=True)
while True:
    client, _ = srv.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
WSEOF
    chmod +x /usr/local/bin/vpsjb-ws.py

    cat > /etc/systemd/system/vpsjb-ws.service <<SVCEOF
[Unit]
Description=WS-epro VPS-JORGEBARRIOS (WS -> SSH)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vpsjb-ws.py $EP $SSHP
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now vpsjb-ws 2>/dev/null
    sleep 1
    local IP; IP=$(ip_publica)
    if systemctl is-active --quiet vpsjb-ws 2>/dev/null || pgrep -f vpsjb-ws.py >/dev/null 2>&1; then
        ufw allow "$EP/tcp" >/dev/null 2>&1
        OK "WS-epro ACTIVO: ws://$IP:$EP (cualquier path) -> SSH $SSHP"
        echo
        echo -e " ${AMARILLO}Config del cliente (HTTP Custom / HTTP Injector / tu app):${NC}"
        echo -e "  Servidor WS: ${VERDE}$IP:$EP${NC}   (payload con Upgrade: websocket, o WebSocket estandar)"
    else
        ERR "El proxy WS no levanto. Revisa: journalctl -u vpsjb-ws"
    fi
    PAUSA
}

menu_protocolos(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_prot)"
        FR_OPT 1 "$(T t_xray)" 2 "$(T t_xray_ws)"
        FR_OPT 3 "$(T t_openvpn)" 4 "$(T t_stunnel)"
        FR_OPT 5 "$(T t_hysteria)" 6 "$(T t_badvpn)"
        FR_OPT 7 "$(T t_wsepro)" 8 "$(T t_shadowsocks)"
        FR_OPT 9 "$(T t_trojan)" 10 "$(T t_wireguard)"
        FR_OPT 11 "$(T t_estado_prot)" 12 "$(T t_quitar)"
        FR_OPT 13 "$(T t_cf_test)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_xray ;;        2) instalar_xray_ws ;;
            3) instalar_openvpn ;;     4) instalar_ssl_stunnel ;;
            5) instalar_hysteria ;;    6) instalar_badvpn ;;
            7) instalar_wsepro ;;      8) instalar_shadowsocks ;;
            9) instalar_trojan ;;      10) instalar_wireguard ;;
            11) estado_protocolos ;;   12) menu_quitar ;;
            13) tunel_trycloudflare ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SUBMENUS DEL PANEL
# ------------------------------------------------------------
menu_usuarios(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_usuarios)"
        FR_OPT 1 "$(T t_crear)" 7 "$(T t_eliminar)"
        FR_OPT 2 "$(T t_listar)" 8 "$(T t_vencidos)"
        FR_OPT 3 "$(T t_clave)" 9 "$(T t_test)"
        FR_OPT 4 "$(T t_bloquear)" 10 "$(T t_conexiones)"
        FR_OPT 5 "$(T t_renovar)" 11 "$(T t_desconectar)"
        FR_OPT 6 "$(T t_limite)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) crear_usuario ;;   2) listar_usuarios ;; 3) cambiar_clave ;;
            4) bloquear_usuario ;; 5) renovar_usuario ;; 6) cambiar_limite ;;
            7) eliminar_usuario ;; 8) eliminar_vencidos ;; 9) crear_test_ssh ;;
            10) conexiones_online ;; 11) matar_conexion ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_seguridad(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_seg)"
        FR_OPT 1 "$(T t_fail2ban)" 5 "$(T t_ver_puertos)"
        FR_OPT 2 "$(T t_limiter_on)" 6 "$(T t_abrir_puerto)"
        FR_OPT 3 "$(T t_limiter_off)" 7 "$(T t_banner)"
        FR_OPT 4 "$(T t_puerto_ssh)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_fail2ban ;; 2) limiter_aplicar ;; 3) limiter_quitar ;;
            4) cambiar_puerto_ssh ;; 5) ver_puertos ;; 6) abrir_puerto ;; 7) menu_banner ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_sistema(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_sistema)"
        FR_OPT 1 "$(T t_monitoreo)" 5 "$(T t_mantenimiento)"
        FR_OPT 2 "$(T t_diagnostico)" 6 "$(T t_hostname)"
        FR_OPT 3 "$(T t_optimizar)" 7 "$(T t_update)"
        FR_OPT 4 "$(T t_swap)" 8 "$(T t_reiniciar)"
        FR_OPT 9 "$(T t_zram)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) monitoreo ;; 2) diagnostico ;; 3) optimizar ;; 4) agregar_swap ;;
            5) mantenimiento ;; 6) cambiar_hostname ;; 7) update_sistema ;; 8) reiniciar_vps ;;
            9) agregar_zram ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_herramientas(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_herr)"
        FR_OPT 1 "$(T t_global)" 4 "$(T t_autoupdate)"
        FR_OPT 2 "$(T t_automenu_on)" 5 "$(T t_checkuser)"
        FR_OPT 3 "$(T t_automenu_off)" 6 "$(T t_idioma)"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_comando_global ;; 2) auto_menu ;; 3) quitar_auto_menu ;;
            4) auto_update ;; 5) menu_checkuser ;;
            6) rm -f /etc/vps-manager.lang; seleccionar_idioma; OK "Idioma: $IDIOMA / Language: $IDIOMA"; PAUSA ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_backup(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_backup)"
        FR_OPT 1 "$(T t_backup_crear)" 2 "$(T t_backup_restaurar)"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) backup_basico ;; 2) restaurar_backup ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SHADOWSOCKS / TROJAN / WIREGUARD
# ------------------------------------------------------------
instalar_shadowsocks(){
    if systemctl is-active --quiet vpsjb-ss 2>/dev/null; then
        read -r -p "Shadowsocks ya esta activo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- SHADOWSOCKS ---${NC}"
    read -r -p "Puerto SS [8388]: " SP; SP=${SP:-8388}
    [[ "$SP" =~ ^[0-9]+$ && "$SP" -ge 1 && "$SP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando shadowsocks-libev (repositorio Ubuntu)..."
    apt update -y >/dev/null 2>&1
    apt install -y shadowsocks-libev >/dev/null 2>&1 || { ERR "No se pudo instalar shadowsocks-libev."; PAUSA; return; }
    local PASS; PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 16)
    mkdir -p /etc/shadowsocks-libev
    cat > /etc/shadowsocks-libev/config.json <<SSEOF
{
    "server": "0.0.0.0",
    "server_port": $SP,
    "password": "$PASS",
    "method": "aes-256-gcm",
    "mode": "tcp_and_udp",
    "fast_open": true
}
SSEOF
    cat > /etc/systemd/system/vpsjb-ss.service <<SSSVC
[Unit]
Description=Shadowsocks VPS-JORGEBARRIOS
After=network.target

[Service]
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SSSVC
    systemctl daemon-reload
    systemctl enable --now vpsjb-ss 2>/dev/null
    ufw allow "$SP/tcp" >/dev/null 2>&1; ufw allow "$SP/udp" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet vpsjb-ss 2>/dev/null; then
        local IP B64
        IP=$(ip_publica)
        B64=$(printf 'aes-256-gcm:%s' "$PASS" | base64 -w0 2>/dev/null || printf 'aes-256-gcm:%s' "$PASS" | base64)
        OK "Shadowsocks ACTIVO en puerto $SP (aes-256-gcm)"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (SS/SSR compatible):${NC}"
        echo -e " ${VERDE}ss://$B64@$IP:$SP#VPSJB-SS${NC}"
    else
        ERR "Shadowsocks no levanto. Revisa: journalctl -u vpsjb-ss"
    fi
    PAUSA
}

instalar_trojan(){
    if ! command -v xray >/dev/null 2>&1; then
        INFO "Xray no esta instalado, instalando primero..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1             || { ERR "No se pudo instalar Xray."; PAUSA; return; }
    fi
    echo -e "${CIAN}--- TROJAN (dentro de Xray) ---${NC}"
    read -r -p "Puerto Trojan [9443]: " TP; TP=${TP:-9443}
    [[ "$TP" =~ ^[0-9]+$ && "$TP" -ge 1 && "$TP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "SNI (dominio camuflaje) [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}
    mkdir -p /etc/vpsjb-trojan
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$SNI" \
        -keyout /etc/vpsjb-trojan/key.pem -out /etc/vpsjb-trojan/cert.pem >/dev/null 2>&1
    chmod 755 /etc/vpsjb-trojan; chmod 644 /etc/vpsjb-trojan/cert.pem
    if XG=$(xray_grupo); then chown root:"$XG" /etc/vpsjb-trojan/key.pem; chmod 640 /etc/vpsjb-trojan/key.pem
    else chmod 644 /etc/vpsjb-trojan/key.pem; fi
    local PASS; PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 20)
    python3 - "$TP" "$SNI" "$PASS" <<'PYEOF'
import json, sys
port, sni, pwd = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cfgp = "/usr/local/etc/xray/config.json"
try:
    cfg = json.load(open(cfgp))
except Exception:
    cfg = {"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}
ib = [i for i in cfg.get("inbounds", []) if i.get("port") != port]
ib.append({
    "port": port,
    "protocol": "trojan",
    "settings": {"clients":[{"password": pwd}]},
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": sni,
            "certificates": [{"certificateFile": "/etc/vpsjb-trojan/cert.pem",
                              "keyFile": "/etc/vpsjb-trojan/key.pem"}]
        }
    }
})
cfg["inbounds"] = ib
json.dump(cfg, open(cfgp, "w"), indent=2)
print("ok")
PYEOF
    xray_config_perms
    ufw allow "$TP/tcp" >/dev/null 2>&1
    systemctl restart xray 2>/dev/null
    sleep 1
    if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
        local IP; IP=$(ip_publica)
        OK "Trojan ACTIVO en puerto $TP (SNI $SNI)"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (activar 'allowInsecure'):${NC}"
        echo -e " ${VERDE}trojan://$PASS@$IP:$TP?security=tls&sni=$SNI&allowInsecure=1#VPSJB-Trojan${NC}"
    else
        ERR "Xray no levanto. Revisa: journalctl -u xray"
    fi
    PAUSA
}

instalar_wireguard(){
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        read -r -p "WireGuard ya esta activo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- WIREGUARD ---${NC}"
    read -r -p "Puerto UDP [51820]: " WP; WP=${WP:-51820}
    [[ "$WP" =~ ^[0-9]+$ && "$WP" -ge 1 && "$WP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando wireguard..."
    apt update -y >/dev/null 2>&1
    apt install -y wireguard >/dev/null 2>&1 || { ERR "No se pudo instalar wireguard."; PAUSA; return; }
    local SPRIV SPRIV2 CPRIV CPUB SPUB IFACE
    SPRIV=$(wg genkey); SPUB=$(echo "$SPRIV" | wg pubkey)
    CPRIV=$(wg genkey); CPUB=$(echo "$CPRIV" | wg pubkey)
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && IFACE="eth0"
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
Address = 10.66.0.1/24
ListenPort = $WP
PrivateKey = $SPRIV
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE

[Peer]
PublicKey = $CPUB
AllowedIPs = 10.66.0.2/32
WGEOF
    chmod 600 /etc/wireguard/wg0.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    ufw allow "$WP/udp" >/dev/null 2>&1
    systemctl enable --now wg-quick@wg0 2>/dev/null
    sleep 1
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        local IP; IP=$(ip_publica)
        cat > /root/wg-client.conf <<CLIENTEOF
[Interface]
PrivateKey = $CPRIV
Address = 10.66.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SPUB
Endpoint = $IP:$WP
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTEOF
        OK "WireGuard ACTIVO (puerto UDP $WP)"
        INFO "Config del cliente: /root/wg-client.conf"
        echo -e " ${AMARILLO}--- para la app WireGuard ---${NC}"
        cat /root/wg-client.conf
    else
        ERR "WireGuard no levanto. Revisa: journalctl -u wg-quick@wg0"
    fi
    PAUSA
}

# ------------------------------------------------------------
# DESINSTALADORES DE PROTOCOLOS
# ------------------------------------------------------------
quitar_xray_completo(){
    systemctl disable --now xray 2>/dev/null
    rm -f /etc/systemd/system/xray.service /usr/local/bin/xray /usr/local/bin/xray-linux-*
    rm -rf /usr/local/etc/xray /etc/vpsjb-trojan
    systemctl daemon-reload 2>/dev/null
    pkill -x xray 2>/dev/null
    OK "Xray (y Trojan/WS) removido."
    PAUSA
}
quitar_wsepro(){
    systemctl disable --now vpsjb-ws 2>/dev/null
    rm -f /etc/systemd/system/vpsjb-ws.service /usr/local/bin/vpsjb-ws.py
    systemctl daemon-reload 2>/dev/null
    pkill -f vpsjb-ws.py 2>/dev/null
    OK "WS-epro removido."
    PAUSA
}
quitar_stunnel(){
    systemctl disable --now stunnel4 2>/dev/null
    rm -f /etc/stunnel/stunnel.conf /etc/stunnel/stunnel.pem /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key
    OK "Stunnel detenido (el paquete queda instalado)."
    PAUSA
}
quitar_hysteria(){
    systemctl disable --now hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service /etc/hysteria/config.yaml
    systemctl daemon-reload 2>/dev/null
    pkill -x hysteria 2>/dev/null
    OK "Hysteria2 removido."
    PAUSA
}
quitar_shadowsocks(){
    systemctl disable --now vpsjb-ss 2>/dev/null
    rm -f /etc/systemd/system/vpsjb-ss.service /etc/shadowsocks-libev/config.json
    systemctl daemon-reload 2>/dev/null
    pkill -x ss-server 2>/dev/null
    OK "Shadowsocks removido (el paquete queda instalado)."
    PAUSA
}
quitar_trojan(){
    python3 <<'PYEOF'
import json
try:
    cfg = json.load(open("/usr/local/etc/xray/config.json"))
    cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("protocol") != "trojan"]
    json.dump(cfg, open("/usr/local/etc/xray/config.json", "w"), indent=2)
    print("ok")
except Exception:
    pass
PYEOF
    rm -rf /etc/vpsjb-trojan
    systemctl restart xray 2>/dev/null
    OK "Trojan removido del Xray."
    PAUSA
}
quitar_wireguard(){
    systemctl disable --now wg-quick@wg0 2>/dev/null
    rm -f /etc/wireguard/wg0.conf /root/wg-client.conf
    OK "WireGuard removido."
    PAUSA
}

menu_quitar(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_quitar)"
        FR_OPT 1 "$(T t_q_xray)" 5 "Hysteria2"
        FR_OPT 2 "WS-epro" 6 "$(T t_shadowsocks)"
        FR_OPT 3 "Stunnel" 7 "$(T t_trojan)"
        FR_OPT 4 "BadVPN" 8 "$(T t_wireguard)"
        FR_OPT 9 "$(T t_q_tunnel)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) quitar_xray_completo ;; 2) quitar_wsepro ;; 3) quitar_stunnel ;; 4) quitar_badvpn ;;
            5) quitar_hysteria ;; 6) quitar_shadowsocks ;; 7) quitar_trojan ;; 8) quitar_wireguard ;;
            9) quitar_tunel_cdn ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

agregar_zram(){
    if swapon --show 2>/dev/null | grep -q zram; then
        read -r -p "ZRAM ya esta activa. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
        swapoff /dev/zram0 2>/dev/null; zramctl --reset /dev/zram0 2>/dev/null; rmmod zram 2>/dev/null
    fi
    echo -e "${CIAN}--- ZRAM (memoria comprimida) ---${NC}"
    read -r -p "Tamaño zram en GB [1]: " G; G=${G:-1}
    [[ "$G" =~ ^[0-9]+$ && "$G" -ge 1 ]] || { ERR "Tamaño invalido."; PAUSA; return; }
    INFO "Cargando modulo zram..."
    modprobe zram 2>/dev/null || { ERR "Sin acceso al kernel (OpenVZ/LXC). Usa la opcion de swap."; PAUSA; return; }
    zramctl /dev/zram0 --algorithm zstd --size "${G}G" >/dev/null 2>&1 \
        || zramctl /dev/zram0 --algorithm lzo --size "${G}G" >/dev/null 2>&1 \
        || { ERR "zramctl fallo."; PAUSA; return; }
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 100 /dev/zram0 2>/dev/null || swapon /dev/zram0 2>/dev/null
    cat > /etc/systemd/system/vpsjb-zram.service <<ZEOF
[Unit]
Description=ZRAM VPS-JORGEBARRIOS
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "modprobe zram && (zramctl /dev/zram0 -a zstd -s ${G}G || zramctl /dev/zram0 -a lzo -s ${G}G) && mkswap /dev/zram0 && swapon -p 100 /dev/zram0"
ExecStop=/bin/bash -c "swapoff /dev/zram0 2>/dev/null; zramctl --reset /dev/zram0 2>/dev/null; rmmod zram 2>/dev/null"

[Install]
WantedBy=multi-user.target
ZEOF
    systemctl daemon-reload
    systemctl enable vpsjb-zram 2>/dev/null
    if swapon --show 2>/dev/null | grep -q zram; then
        OK "ZRAM de ${G}GB activa (prioridad alta, mas rapida que swap de disco)."
    else
        ERR "ZRAM no pudo activarse en este entorno."
    fi
    PAUSA
}

tunel_trycloudflare(){
    if pgrep -x cloudflared >/dev/null 2>&1; then
        read -r -p "Ya hay un tunel CDN corriendo. Reiniciarlo (nueva URL)? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
        pkill -x cloudflared 2>/dev/null; sleep 2
    fi
    if ! command -v cloudflared >/dev/null 2>&1; then
        INFO "Instalando cloudflared..."
        local ARCH="amd64"; [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && ARCH="arm64"
        timeout 25 wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" -O /root/cloudflared.deb 2>/dev/null \
            && dpkg -i /root/cloudflared.deb >/dev/null 2>&1 && rm -f /root/cloudflared.deb \
            || { ERR "No se pudo descargar cloudflared (sin red?)."; PAUSA; return; }
    fi
    local PUERTO=80
    if [[ -f /etc/systemd/system/vpsjb-ws.service ]]; then
        PUERTO=$(grep -o 'vpsjb-ws.py [0-9]*' /etc/systemd/system/vpsjb-ws.service | awk '{print $2}' | head -1)
        PUERTO=${PUERTO:-80}
    fi
    if ! pgrep -f vpsjb-ws.py >/dev/null 2>&1; then
        WARN "WS-epro no esta corriendo. Instalalo primero (Protocolos -> 7, puerto 80)."
        PAUSA; return
    fi
    INFO "Levantando tunel CDN hacia 127.0.0.1:${PUERTO}..."
    nohup cloudflared tunnel --url "http://127.0.0.1:${PUERTO}" > /var/log/ghost-cf-tunnel.log 2>&1 &
    local URL="" i
    for i in $(seq 1 15); do
        sleep 2
        URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/ghost-cf-tunnel.log | head -1)
        [[ -n "$URL" ]] && break
    done
    echo
    if [[ -n "$URL" ]]; then
        OK "Tunel CDN activo:"
        echo
        echo -e " ${VERDE}${URL}${NC}"
        echo
        echo -e " ${AMARILLO}Uso en la app: WebSocket activado, servidor ${URL#https://} puerto 443, path /${NC}"
        echo -e " ${AMARILLO}OJO: la URL cambia al reiniciar el tunel. Es para pruebas/demos.${NC}"
        echo -e " ${CIAN}Log: /var/log/ghost-cf-tunnel.log  |  Frenar: pkill cloudflared${NC}"
    else
        ERR "El tunel no dio URL a tiempo. Log:"
        tail -5 /var/log/ghost-cf-tunnel.log 2>/dev/null
    fi
    PAUSA
}

quitar_tunel_cdn(){
    pkill -x cloudflared 2>/dev/null && OK "Tunel CDN detenido." || ERR "No habia tunel corriendo."
    PAUSA
}

# ------------------------------------------------------------
# MENU PRINCIPAL
# ------------------------------------------------------------
[[ $EUID -ne 0 ]] && { echo -e "${ROJO}Ejecuta como root o con sudo.${NC}"; exit 1; }

seleccionar_idioma
gate_licencia
ghost_bootstrap

while true; do
    cabecera
    ui_crumb
    ui_box_top "$(T t_menu_principal)"
    FR_OPT 1 "$(T t_usuarios)" 2 "$(T t_protocolos)"
    FR_OPT 3 "$(T t_seguridad)" 4 "$(T t_sistema)"
    FR_OPT 5 "$(T t_herramientas)" 6 "$(T t_webmin)"
    FR_OPT 7 "$(T t_backup)" 8 "$(T t_diagnostico)"
    FR_TXT ""
    FR_OPT 0 "$(T t_salir)" "" ""
    FR_BOT
    echo -e "  ${GRIS}$(T t_servidor_id) ${VERDE}$(machine_hash)${GRIS}  ·  $(date '+%d/%m/%Y %H:%M')${NC}"
    PROMPT
    case "$OP" in
        1) menu_usuarios ;;
        2) menu_protocolos ;;
        3) menu_seguridad ;;
        4) menu_sistema ;;
        5) menu_herramientas ;;
        6) menu_webmin ;;
        7) menu_backup ;;
        8) diagnostico ;;
        0) echo -e "${VERDE}Hasta luego!${NC}"; exit 0 ;;
        *) ERR "$(T t_opinv)"; sleep 1 ;;
    esac
done
