#!/usr/bin/env bash
# ============================================================
#  GHOST PANEL by Jorge Barrios  -  Administracion de VPS (Ubuntu)
#  Menu SSH: usuarios, trafico, backup, banner + Webmin
#  Uso:  sudo bash ghost-panel-pro.sh   |   comando: ghostpanel
#  Version: 4.6
#  Versionado: desde 4.0 el numero es X.Y -> 4.0, 4.1 ... 4.9 y despues 5.0 (sin tercer numero).
#  Cambios 4.6 (actualizaciones privadas):
#    - Auto-actualizar ahora descarga desde el servidor propio, validando la key y el ID de la maquina.
#    - Se elimina SECRET_KEY y la validacion offline legacy (validar_key).
#    - Si /etc/ghost-panel.conf tenia UPDATE_URL apuntando al repo viejo, se ignora y se usa la fuente nueva.
#  Cambios 4.5 (temas Hielo/Carbon):
#    - Emojis del menú Tema con ancho correcto (marco alineado).
#    - Colores de opciones más vivos en Hielo y Carbon (ya no se ven apagados).
#  Cambios 4.4 (Optimizar + Mantenimiento):
#    - Optimizar: BBR/fq + buffers TCP, backlog, somaxconn, dirty ratios, file-max y nofile;
#      ficha con valores reales activos tras aplicar.
#    - Mantenimiento: espacio liberado, /var/tmp, journal por tiempo y tamaño, logrotate Ghost,
#      sync de hora, snap/docker si existen; ficha con resumen.
#  Cambios 4.3 (temas y menú Sistema):
#    - Temas nuevos: Hielo (azul/cian) y Carbon (monocromo).
#    - Diagnóstico solo en el menú principal [8]; se quitó la entrada duplicada de Sistema/Recursos.
#  Cambios 4.2 (logs, soporte y autodiagnóstico):
#    - Logs rotados: /etc/logrotate.d/ghost-panel (semanal o al pasar 5 MB, 4 copias comprimidas) para
#      ghost-panel.log, ghost-bot.log y ghost-cf-tunnel.log. Antes crecían sin límite. Se instala solo.
#    - Bot: los datos del cliente (usuario creado, enviar datos, clave nueva) terminan con la línea
#      «Soporte» (la misma de Herramientas → Soporte; si la dejas en «0» no aparece).
#    - Diagnóstico (menú 8): nueva sección «Ghost Panel» que revisa instancia única, versiones del panel
#      y del bot, Telegram, limiter, crones (incluido que el auto-corte avise al bot), CheckUser, backups,
#      logrotate, cuentas protegidas y carga, con un resumen ✔ / ! / ✘.
# ============================================================

set -u
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; fi

ROJO='\033[1;31m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'
AZUL='\033[1;34m'; CIAN='\033[1;36m'; BLANCO='\033[1;37m'
NC='\033[0m'
NARANJA='\033[38;5;208m'; GRIS='\033[38;5;245m'; MORADO='\033[38;5;141m'

# ---------- TEMAS DE COLOR ----------
# tema_aplicar NOMBRE fija: borde del marco, titulo, acento del prompt, degradado del logo (4 tonos)
# y el color de cada opcion del menu principal (9 tonos, 256 colores). Se guarda como THEME=
# en /etc/ghost-panel.conf. Temas: fantasma (defecto), neon, matrix, naranja, hielo, carbon.
GHOST_THEME=fantasma
TH_LOGO=(); TH_ITEMS=()
tema_aplicar(){
    local t="${1:-fantasma}" b ti ac
    case "$t" in
        neon)    b=165; ti=51;  ac=46;  TH_LOGO=(201 165 129 51);  TH_ITEMS=(51 201 46 226 39 213 87 208 196) ;;
        matrix)  b=28;  ti=46;  ac=46;  TH_LOGO=(22 28 34 46);     TH_ITEMS=(46 82 40 118 34 120 46 82 196) ;;
        naranja) b=130; ti=214; ac=208; TH_LOGO=(196 202 208 220); TH_ITEMS=(220 208 214 202 226 215 209 180 196) ;;
        hielo)   b=45;  ti=159; ac=87;  TH_LOGO=(39 45 51 87);     TH_ITEMS=(51 87 123 159 81 117 153 195 196) ;;
        carbon)  b=250; ti=255; ac=255; TH_LOGO=(245 250 252 255); TH_ITEMS=(255 231 252 250 15 255 253 254 196) ;;
        *)       t=fantasma; b=98; ti=141; ac=141; TH_LOGO=(141 105 75 45); TH_ITEMS=(51 201 46 208 226 75 213 120 196) ;;
    esac
    GHOST_THEME="$t"
    BORDE="\033[38;5;${b}m"; MORADO="\033[38;5;${ti}m"; ACENTO="\033[1;38;5;${ac}m"
}
tema_cargar(){
    local t=""
    [[ -r /etc/ghost-panel.conf ]] && t=$(awk -F= '/^THEME=/{print $2; exit}' /etc/ghost-panel.conf)
    tema_aplicar "$t"
}
tema_guardar(){
    touch /etc/ghost-panel.conf; chmod 600 /etc/ghost-panel.conf
    sed -i '/^THEME=/d' /etc/ghost-panel.conf
    echo "THEME=$1" >> /etc/ghost-panel.conf
}
tema_cargar
GHOST_VER='4.6'

# --- LICENCIA / KEY -------------------------------------------
# Validacion ONLINE obligatoria (Worker de Cloudflare). El enforcement
# real vive en el servidor de licencias, no aca.
KEY_FILE='/etc/vps-manager.key'
PREFIJO_KEY='VPSJB1'   # prefijo de marca; tambien acepta keys viejas VPSMGR1
# Servidor de actualizaciones (Worker de Cloudflare): solo entrega el script con key + ID validos
REPO_RAW='https://ghost-update.jorgebarriosmpya.workers.dev/update'
VPSMGR_DEST=/usr/local/bin/ghostpanel
if [[ -r /etc/ghost-panel.conf ]]; then
    _u=$(awk -F= '/^UPDATE_URL=/{print substr($0,12); exit}' /etc/ghost-panel.conf)
    # migracion: un UPDATE_URL viejo apuntando a GitHub ya no sirve, se ignora
    [[ "$_u" == *githubusercontent.com* || "$_u" == *github.com* ]] && _u=''
    [[ "$_u" =~ ^https?://[^[:space:]]+$ ]] && REPO_RAW="$_u"
fi
# --- VALIDACION ONLINE ---
# Pone aca la URL de tu Worker de Cloudflare.
# Vacio = el panel se niega a arrancar (modo produccion).
# Para desarrollo local sin Worker: export GHOST_DEV=1 antes de ejecutar.
LICENSE_URL='https://vps-licencias.jorgebarriosmpya.workers.dev/'
GRACE_SECS=259200                      # 72h de gracia si el servidor no responde
LICENSE_CACHE='/etc/vps-license.cache'
# REPO_RAW: se puede sobrescribir con /etc/ghost-panel.conf -> UPDATE_URL=https://...

machine_hash(){
    if [[ -f /etc/machine-id ]]; then
        sha256sum /etc/machine-id 2>/dev/null | cut -c1-12
    else
        sha256sum /etc/hostname 2>/dev/null | cut -c1-12
    fi
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
        if [[ "${GHOST_DEV:-0}" == "1" ]]; then
            WARN "GHOST_DEV=1: omitiendo validacion de licencia (solo desarrollo)."
            LICENSE_OK="dev"
            return 0
        fi
        FR_TXT "  ${ROJO}$(T t_online_req)${NC}"
        FR_TXT "  $(T t_online_req2)"
        FR_TXT "  ${GRIS}Configura LICENSE_URL en el script o en /etc/ghost-panel.conf${NC}"
        FR_TXT "  ${GRIS}Desarrollo: GHOST_DEV=1 sudo bash ghost-panel-pro.sh${NC}"
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
TXT_ES[t_ui_ses]="SESIÓN"; TXT_EN[t_ui_ses]="SESSION"
TXT_ES[t_ui_user]="Usuario"; TXT_EN[t_ui_user]="User"
TXT_ES[t_ui_days]="días"; TXT_EN[t_ui_days]="days"
TXT_ES[t_usuarios]="Usuarios SSH"; TXT_EN[t_usuarios]="SSH Users"
TXT_ES[t_protocolos]="Protocolos"; TXT_EN[t_protocolos]="Protocols"
TXT_ES[t_seguridad]="Seguridad"; TXT_EN[t_seguridad]="Security"
TXT_ES[t_sistema]="Sistema/Recursos"; TXT_EN[t_sistema]="System/Resources"
TXT_ES[t_herramientas]="Herramientas"; TXT_EN[t_herramientas]="Tools"
TXT_ES[t_webmin]="Webmin"; TXT_EN[t_webmin]="Webmin"
TXT_ES[t_backup]="Backup/Restaurar"; TXT_EN[t_backup]="Backup / Restore"
TXT_ES[t_diagnostico]="Diagnóstico"; TXT_EN[t_diagnostico]="Diagnostics"
TXT_ES[t_servidor_id]="Servidor ID"; TXT_EN[t_servidor_id]="Server ID"
TXT_ES[t_salir]="Salir"; TXT_EN[t_salir]="Exit"
TXT_ES[t_opcion]="Opción"; TXT_EN[t_opcion]="Option"
TXT_ES[t_volver]="Volver"; TXT_EN[t_volver]="Back"
TXT_ES[t_sub_usuarios]="USUARIOS SSH"; TXT_EN[t_sub_usuarios]="SSH USERS"
TXT_ES[t_crear]="Crear usuario"; TXT_EN[t_crear]="Create user"
TXT_ES[t_listar]="Listar usuarios"; TXT_EN[t_listar]="List users"
TXT_ES[t_clave]="Cambiar clave"; TXT_EN[t_clave]="Change password"
TXT_ES[t_bloquear]="Bloquear/Desbl."; TXT_EN[t_bloquear]="Block/Unblock"
TXT_ES[t_renovar]="Renovar usuario"; TXT_EN[t_renovar]="Renew user"
TXT_ES[t_limite]="Cambiar límite"; TXT_EN[t_limite]="Change limit"
TXT_ES[t_eliminar]="Eliminar usuario"; TXT_EN[t_eliminar]="Delete user"
TXT_ES[t_vencidos]="Borrar vencidos"; TXT_EN[t_vencidos]="Delete expired"
TXT_ES[t_test]="Crear test SSH"; TXT_EN[t_test]="Create SSH test"
TXT_ES[t_conexiones]="Conectados"; TXT_EN[t_conexiones]="Online sessions"
TXT_ES[t_desconectar]="Desconectar usr"; TXT_EN[t_desconectar]="Disconnect user"
TXT_ES[t_sub_seg]="SEGURIDAD"; TXT_EN[t_sub_seg]="SECURITY"
TXT_ES[t_fail2ban]="Fail2ban"; TXT_EN[t_fail2ban]="Fail2ban"
TXT_ES[t_limiter_on]="Activar limiter"; TXT_EN[t_limiter_on]="Limiter (enable)"
TXT_ES[t_limiter_off]="Quitar limiter"; TXT_EN[t_limiter_off]="Remove limiter"
TXT_ES[t_puerto_ssh]="Puerto SSH"; TXT_EN[t_puerto_ssh]="Change SSH port"
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
TXT_ES[t_automenu_on]="Auto-menú login"; TXT_EN[t_automenu_on]="Menu on login"
TXT_ES[t_automenu_off]="Quitar auto-menú"; TXT_EN[t_automenu_off]="Remove auto-menu"
TXT_ES[t_autoupdate]="Auto-actualizar"; TXT_EN[t_autoupdate]="Self-update"
TXT_ES[t_checkuser]="CheckUser API"; TXT_EN[t_checkuser]="CheckUser API"
TXT_ES[t_idioma]="Cambiar idioma"; TXT_EN[t_idioma]="Change language"
TXT_ES[t_sub_backup]="BACKUP / RESTAURAR"; TXT_EN[t_sub_backup]="BACKUP / RESTORE"
TXT_ES[t_backup_crear]="Crear backup"; TXT_EN[t_backup_crear]="Create backup"
TXT_ES[t_backup_restaurar]="Restaurar backup"; TXT_EN[t_backup_restaurar]="Restore backup"
TXT_ES[t_sub_prot]="PROTOCOLOS / CONEXIONES"; TXT_EN[t_sub_prot]="PROTOCOLS / CONNECTIONS"
TXT_ES[t_xray]="Xray Reality"; TXT_EN[t_xray]="Xray Reality"
TXT_ES[t_xray_ws]="Xray WS (CDN)"; TXT_EN[t_xray_ws]="Xray WS (CDN)"
TXT_ES[t_openvpn]="OpenVPN"; TXT_EN[t_openvpn]="OpenVPN"
TXT_ES[t_stunnel]="SSL Stunnel 443"; TXT_EN[t_stunnel]="SSL Stunnel 443"
TXT_ES[t_hysteria]="Hysteria2 (UDP)"; TXT_EN[t_hysteria]="Hysteria2 (UDP)"
TXT_ES[t_badvpn]="BadVPN (UDP GW)"; TXT_EN[t_badvpn]="BadVPN (UDP GW)"
TXT_ES[t_wsepro]="WS-epro WS->SSH"; TXT_EN[t_wsepro]="WS-epro WS->SSH"
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
TXT_ES[t_cu_rotar]="Rotar token"; TXT_EN[t_cu_rotar]="Rotate token"
TXT_ES[t_remover]="Remover"; TXT_EN[t_remover]="Remove"
TXT_ES[t_sub_trafico]="TRÁFICO POR USUARIO"; TXT_EN[t_sub_trafico]="PER-USER TRAFFIC"
TXT_ES[t_trafico]="Tráfico"; TXT_EN[t_trafico]="Traffic"
TXT_ES[t_tr_activar]="Activar conteo"; TXT_EN[t_tr_activar]="Enable counters"
TXT_ES[t_tr_ver]="Ver consumo"; TXT_EN[t_tr_ver]="View usage"
TXT_ES[t_tr_limite]="Límite (GB)"; TXT_EN[t_tr_limite]="Limit (GB)"
TXT_ES[t_tr_cortar]="Cortar excedidos"; TXT_EN[t_tr_cortar]="Cut exceeded"
TXT_ES[t_tr_auto]="Auto-corte"; TXT_EN[t_tr_auto]="Auto-cut"
TXT_ES[t_tr_auto_on]="Auto-corte ACTIVO · cada"; TXT_EN[t_tr_auto_on]="Auto-cut ACTIVE · every"
TXT_ES[t_banner_sop]="Soporte en el banner"; TXT_EN[t_banner_sop]="Banner support contact"
TXT_ES[t_ui_alto]="usuarios al 80%+ de su cuota"; TXT_EN[t_ui_alto]="users at 80%+ of quota"
TXT_ES[t_tr_auto_off]="Auto-corte inactivo"; TXT_EN[t_tr_auto_off]="Auto-cut inactive"
TXT_ES[t_ssl]="Dominio y SSL"; TXT_EN[t_ssl]="Domain & SSL"
TXT_ES[t_sub_ssl]="SEGURIDAD / Dominio y SSL"; TXT_EN[t_sub_ssl]="SECURITY / Domain & SSL"
TXT_ES[t_ssl_dom]="Dominio y verificar DNS"; TXT_EN[t_ssl_dom]="Domain & DNS check"
TXT_ES[t_ssl_crear]="Crear subdominio"; TXT_EN[t_ssl_crear]="Create subdomain"
TXT_ES[t_ssl_subs]="Mis subdominios"; TXT_EN[t_ssl_subs]="My subdomains"
TXT_ES[t_ssl_emitir]="Emitir certificado SSL"; TXT_EN[t_ssl_emitir]="Issue SSL certificate"
TXT_ES[t_ssl_renovar]="Renovar ahora"; TXT_EN[t_ssl_renovar]="Renew now"
TXT_ES[t_ssl_estado]="Estado y enlaces"; TXT_EN[t_ssl_estado]="Status & links"
TXT_ES[t_ssl_aplicar]="Aplicar a los servicios"; TXT_EN[t_ssl_aplicar]="Apply to services"
TXT_ES[t_ssl_quitar]="Quitar Dominio y SSL"; TXT_EN[t_ssl_quitar]="Remove Domain & SSL"
TXT_ES[t_ssl_sin_dom]="Sin dominio configurado (opción 1)"; TXT_EN[t_ssl_sin_dom]="No domain set (option 1)"
TXT_ES[t_ssl_sin_cert]="sin certificado aun"; TXT_EN[t_ssl_sin_cert]="no certificate yet"
TXT_ES[t_tr_reset]="Reset contadores"; TXT_EN[t_tr_reset]="Reset counters"
TXT_ES[t_tr_desbloq]="Desbloquear por cuota"; TXT_EN[t_tr_desbloq]="Unlock by quota"
TXT_ES[t_tr_notif]="Notificaciones cuota"; TXT_EN[t_tr_notif]="Quota notifications"
TXT_ES[t_tr_hist]="Historial consumo"; TXT_EN[t_tr_hist]="Usage history"
TXT_ES[t_sub_quitar]="QUITAR PROTOCOLOS"; TXT_EN[t_sub_quitar]="REMOVE PROTOCOLS"
TXT_ES[t_q_xray]="Xray completo"; TXT_EN[t_q_xray]="Xray (full)"
TXT_ES[t_panel]="Panel de administracion"; TXT_EN[t_panel]="Administration panel"
TXT_ES[t_ram]="RAM"; TXT_EN[t_ram]="RAM"
TXT_ES[t_cpu]="CPU"; TXT_EN[t_cpu]="CPU"
TXT_ES[t_disco]="Disco"; TXT_EN[t_disco]="Disk"
TXT_ES[t_online]="Online"; TXT_EN[t_online]="Online"
TXT_ES[t_licencia]="Licencia"; TXT_EN[t_licencia]="License"
TXT_ES[t_lic_req]="LICENCIA REQUERIDA"; TXT_EN[t_lic_req]="LICENSE REQUIRED"
TXT_ES[t_panel_jb]="👻 GHOST PANEL by Jorge Barrios"; TXT_EN[t_panel_jb]="👻 GHOST PANEL by Jorge Barrios"
TXT_ES[t_id_srv]="ID de este servidor"; TXT_EN[t_id_srv]="ID of this server"
TXT_ES[t_online_req]="VALIDACION ONLINE OBLIGATORIA"; TXT_EN[t_online_req]="ONLINE VALIDATION REQUIRED"
TXT_ES[t_online_req2]="LICENSE_URL vacio. Configuralo o usa GHOST_DEV=1 para pruebas."; TXT_EN[t_online_req2]="LICENSE_URL empty. Set it or use GHOST_DEV=1 for testing."
TXT_ES[t_opinv]="Opción inválida."; TXT_EN[t_opinv]="Invalid option."
TXT_ES[t_cf_test]="Tunel CDN (test)"; TXT_EN[t_cf_test]="CDN tunnel"
TXT_ES[t_q_tunnel]="Tunel CDN (cloudflared)"; TXT_EN[t_q_tunnel]="CDN tunnel (cloudflared)"
TXT_ES[t_ui_vital]="∞ vitalicia"; TXT_EN[t_ui_vital]="∞ lifetime"
TXT_ES[t_desinst_c]="Desinstalar"; TXT_EN[t_desinst_c]="Uninstall"
TXT_ES[t_banner_tz]="Zona horaria"; TXT_EN[t_banner_tz]="Time zone"
TXT_ES[t_ui_on]="online"; TXT_EN[t_ui_on]="online"
TXT_ES[t_ui_venc]="vencen"; TXT_EN[t_ui_venc]="expiring"
TXT_ES[t_tema]="Tema de color"; TXT_EN[t_tema]="Color theme"
TXT_ES[t_sub_tema]="HERRAMIENTAS / Tema"; TXT_EN[t_sub_tema]="TOOLS / Theme"
TXT_ES[t_desinst]="Desinstalar Ghost Panel"; TXT_EN[t_desinst]="Uninstall Ghost Panel"
TXT_ES[t_du_titulo]="DESINSTALAR GHOST PANEL"; TXT_EN[t_du_titulo]="UNINSTALL GHOST PANEL"
TXT_ES[t_du_word]="DESINSTALAR"; TXT_EN[t_du_word]="UNINSTALL"
TXT_ES[t_du_conf]="Escribe DESINSTALAR para confirmar (ENTER = cancelar):"; TXT_EN[t_du_conf]="Type UNINSTALL to confirm (ENTER = cancel):"
TXT_ES[t_du_fin]="Ghost Panel desinstalado por completo. Hasta pronto!"; TXT_EN[t_du_fin]="Ghost Panel fully uninstalled. See you!"
TXT_ES[t_adguard]="AdGuard Home"; TXT_EN[t_adguard]="AdGuard Home"
TXT_ES[t_sub_adguard]="PROTOCOLOS / AdGuard Home"; TXT_EN[t_sub_adguard]="PROTOCOLS / AdGuard Home"
TXT_ES[t_ad_reparar]="Reparar / reiniciar"; TXT_EN[t_ad_reparar]="Repair / restart"
TXT_ES[t_ad_nota1]="Bloquea anuncios por DNS solo para clientes WireGuard (DNS=10.66.0.1)."; TXT_EN[t_ad_nota1]="DNS ad-blocking for WireGuard clients only (DNS=10.66.0.1)."
TXT_ES[t_ad_nota2]="No aplica a HTTP Custom/SSH. Puerto 53 NO se publica a Internet."; TXT_EN[t_ad_nota2]="Does not apply to HTTP Custom/SSH. Port 53 is NOT exposed to the Internet."
TXT_ES[t_nu_gb]="Límite de tráfico en GB (0 = sin límite) [0]:"; TXT_EN[t_nu_gb]="Traffic limit in GB (0 = unlimited) [0]:"
TXT_ES[t_ad_inst]="Instalar AdGuard Home"; TXT_EN[t_ad_inst]="Install AdGuard Home"
TXT_ES[t_ad_estado]="Estado / panel web"; TXT_EN[t_ad_estado]="Status / web UI"
TXT_ES[t_ad_quitar]="Quitar AdGuard"; TXT_EN[t_ad_quitar]="Remove AdGuard"
TXT_ES[t_ad_listas]="Actualizar listas"; TXT_EN[t_ad_listas]="Update filter lists"
TXT_ES[t_dropbear]="Dropbear"; TXT_EN[t_dropbear]="Dropbear"
TXT_ES[t_udp_custom]="UDP Custom"; TXT_EN[t_udp_custom]="UDP Custom"
TXT_ES[t_slowdns]="SlowDNS (dnstt)"; TXT_EN[t_slowdns]="SlowDNS (dnstt)"
TXT_ES[t_ver_links]="Ver enlaces"; TXT_EN[t_ver_links]="Show links"
TXT_ES[t_bot]="Bot Telegram"; TXT_EN[t_bot]="Telegram Bot"
TXT_ES[t_sub_bot]="BOT DE TELEGRAM"; TXT_EN[t_sub_bot]="TELEGRAM BOT"
TXT_ES[t_bot_inst]="Instalar / Configurar"; TXT_EN[t_bot_inst]="Install / Configure"
TXT_ES[t_bot_iniciar]="Iniciar bot"; TXT_EN[t_bot_iniciar]="Start bot"
TXT_ES[t_bot_detener]="Detener bot"; TXT_EN[t_bot_detener]="Stop bot"
TXT_ES[t_bot_reiniciar]="Reiniciar bot"; TXT_EN[t_bot_reiniciar]="Restart bot"
TXT_ES[t_bot_estado]="Estado del bot"; TXT_EN[t_bot_estado]="Bot status"
TXT_ES[t_bot_ver]="Ver token y admin"; TXT_EN[t_bot_ver]="Show token & admin"
TXT_ES[t_bot_test]="Mensaje de prueba"; TXT_EN[t_bot_test]="Test message"
TXT_ES[t_bot_desinst]="Desinstalar bot"; TXT_EN[t_bot_desinst]="Uninstall bot"
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

# Si la terminal desaparece (EOF / error de tty) o pasa el tiempo de inactividad, el panel SALE.
# Antes seguia en bucle (redibujar cabecera + sleep 1) para siempre: los huerfanos se acumulaban y
# subian el load. GHOST_IDLE: segundos sin tocar nada (0 = nunca); /etc/ghost-panel.conf IDLE_TIMEOUT.
GHOST_IDLE=1200
ghost_salir_sin_terminal(){
    (( ${1:-1} > 128 )) && echo -e "\n  ${GRIS}⏱ Sesión cerrada por inactividad.${NC}"
    exit 0
}
PAUSA(){
    echo -e "\n  ${GRIS}↵ ENTER para continuar...${NC}"
    if (( GHOST_IDLE > 0 )); then read -r -t "$GHOST_IDLE" || ghost_salir_sin_terminal $?
    else read -r || ghost_salir_sin_terminal $?; fi
}

# ---------- HELPERS DE PRODUCCION ----------
LOG_PANEL='/var/log/ghost-panel.log'
LINKS_FILE='/root/vps-links.txt'
IP_CACHE_FILE='/run/vps-ip.cache'   # /run es de root (en /tmp un usuario SSH podia plantar un symlink)
USUARIOS_DIR='/etc/vps-users'
PROTEGIDOS_NOMBRES='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu debian admin ec2-user cloud-user vpsmgr ghostpanel dnstt opc oracle azureuser fedora centos rocky almalinux vagrant pi'

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
    # Protegido = NO es un usuario del panel: nombres del sistema/nube, uid fuera de 1000-60000 (snapd-range-*...),
    # cuentas de snapd/systemd y cualquier cuenta de administracion (sudo/wheel/admin: p. ej. opc, tu acceso SSH).
    local U="${1:-}" UIDN
    [[ -z "$U" ]] && return 0
    echo " $PROTEGIDOS_NOMBRES " | grep -q " $U " && return 0
    [[ "$U" == snapd-* || "$U" == systemd-* ]] && return 0
    UIDN=$(id -u "$U" 2>/dev/null || echo 0)
    [[ "$UIDN" -lt 1000 || "$UIDN" -gt 60000 ]] && return 0
    id -nG "$U" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin' && return 0
    return 1
}

usuarios_panel(){
    # Usuarios REALES del panel, uno por linea (mismo criterio que usuario_protegido, con un solo awk).
    local ADM
    ADM=$(getent group sudo wheel admin 2>/dev/null | awk -F: '{print $4}' | tr ',' ' ')
    awk -F: -v prot=" ${PROTEGIDOS_NOMBRES:-} " -v adm=" $ADM " '
        $3>=1000 && $3<=60000 && $1!="nobody" && $1 !~ /^(snapd|systemd)-/ \
        && index(prot," "$1" ")==0 && index(adm," "$1" ")==0 { print $1 }' /etc/passwd
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
    # Sesiones abiertas de un usuario.
    # Preferimos ss (conexiones establecidas reales); fallback a procesos sshd/dropbear.
    local u="$1" n=0
    if command -v ss >/dev/null 2>&1; then
        # OpenSSH: usuarios en peer name de sockets sshd (no siempre disponible)
        n=$(ss -H -tnp state established 2>/dev/null | grep -c "sshd.*$u" || true)
    fi
    if [[ "${n:-0}" -eq 0 ]]; then
        # Procesos vivos con tiempo de vida razonable (evita zombis/recien muertos)
        n=$(ps -eo user:32=,etime=,comm= 2>/dev/null | awk -v u="$u" '
            $1==u && ($3=="sshd"||$3=="dropbear") {
                # etime formato [[dd-]hh:]mm:ss — descartar si parece basura
                c++
            } END{print c+0}')
    fi
    echo "${n:-0}"
}

online_total(){
    # Sesiones ssh/dropbear de usuarios no-root: UNA sola pasada de ps (antes: ps + ss + ps por cada usuario)
    ps -eo user:32=,comm= 2>/dev/null | awk '($2=="sshd"||$2=="dropbear") && $1!="root"{n++} END{print n+0}'
}

sesiones_por_usuario(){
    ps -eo user:32=,comm= 2>/dev/null \
        | awk '($2=="sshd"||$2=="dropbear") && $1!="root"{c[$1]++} END{for(u in c) printf "  %-20s %d sesion(es)\n", u, c[u]}' | sort
}

SSHD_CFG=/etc/ssh/sshd_config

sshd_puerto_actual(){
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [[ -z "$p" ]] && p=$(awk 'tolower($1)=="port"{print $2; exit}' "$SSHD_CFG" 2>/dev/null)
    echo "${p:-22}"
}


# puerto_ocupado PORT [tcp|udp|both]  -> 0 ocupado / 1 libre
# Detecta sockets en escucha con ss (columna Local Address:Port).
puerto_ocupado(){
    local p="$1" proto="${2:-tcp}"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    case "$proto" in
        tcp)
            ss -tln 2>/dev/null | awk -v p="$p" 'NR>1{
                n=split($4,a,":"); if (a[n]==p) { found=1; exit }
            } END{ exit found?0:1 }'
            ;;
        udp)
            ss -uln 2>/dev/null | awk -v p="$p" 'NR>1{
                n=split($4,a,":"); if (a[n]==p) { found=1; exit }
            } END{ exit found?0:1 }'
            ;;
        both|*)
            ss -tuln 2>/dev/null | awk -v p="$p" 'NR>1{
                n=split($4,a,":"); if (a[n]==p) { found=1; exit }
            } END{ exit found?0:1 }'
            ;;
    esac
}

# Nombre corto del proceso que escucha en PORT (si ss lo reporta).
puerto_quien(){
    local p="$1" proto="${2:-tcp}" line
    case "$proto" in
        udp)  line=$(ss -ulnp 2>/dev/null | awk -v p="$p" 'NR>1{n=split($5,a,":"); if(a[n]==p){print; exit}}') ;;
        both) line=$(ss -tulnp 2>/dev/null | awk -v p="$p" 'NR>1{n=split($5,a,":"); if(a[n]==p){print; exit}}') ;;
        *)    line=$(ss -tlnp 2>/dev/null | awk -v p="$p" 'NR>1{n=split($5,a,":"); if(a[n]==p){print; exit}}') ;;
    esac
    [[ -z "$line" ]] && return 0
    if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "otro servicio"
    fi
}

# pedir_puerto VAR "Prompt [default]: " DEFAULT [tcp|udp|both] [allow_proc]
# Si el puerto esta ocupado, avisa (proceso) y pregunta si queres elegir otro.
# allow_proc opcional: si el puerto lo usa ese proceso, se considera libre (ej. sshd al reconfigurar).
# Devuelve 0 y asigna VAR / 1 si cancela o agota intentos.
pedir_puerto(){
    local _var="$1" _prompt="$2" _def="${3:-}" _proto="${4:-tcp}" _allow="${5:-}"
    local p quien intentos=0 sn
    while (( intentos < 8 )); do
        if [[ -n "$_def" ]]; then
            read -r -p "$_prompt" p
            p=${p:-$_def}
        else
            read -r -p "$_prompt" p
        fi
        if ! [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]]; then
            ERR "Puerto invalido (entero 1-65535)."
            intentos=$((intentos+1))
            continue
        fi
        if puerto_ocupado "$p" "$_proto"; then
            quien=$(puerto_quien "$p" "$_proto")
            if [[ -n "$_allow" && -n "$quien" && "$quien" == "$_allow" ]]; then
                printf -v "$_var" '%s' "$p"
                return 0
            fi
            ERR "El puerto ${p}/${_proto} esta ocupado${quien:+ por ${quien}}."
            read -r -p "Queres elegir otro puerto? (s/n): " sn
            if [[ "$sn" != "s" && "$sn" != "S" ]]; then
                INFO "Cancelado."
                return 1
            fi
            _def=""
            _prompt="Puerto libre (1-65535): "
            intentos=$((intentos+1))
            continue
        fi
        printf -v "$_var" '%s' "$p"
        return 0
    done
    ERR "Demasiados intentos sin un puerto libre."
    return 1
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
    # purgar_usuario USUARIO [keep]  -> borra usuario + limites + trafico + clientes xray + regla iptables.
    local U="$1" UIDN
    UIDN=$(id -u "$U" 2>/dev/null) || true
    pkill -KILL -u "$U" 2>/dev/null
    xray_usuario del "$U" >/dev/null 2>&1
    # Quitar regla iptables del UID (y con ella los bytes acumulados). Si no, al recrear
    # el mismo nombre/UID el banner heredaba el consumo anterior.
    if [[ -n "${UIDN:-}" ]] && iptables -L VPS-TRAFFIC -n >/dev/null 2>&1; then
        while iptables -D VPS-TRAFFIC -m owner --uid-owner "$UIDN" -j RETURN 2>/dev/null; do :; done
    fi
    rm -f "/etc/vps-limits/$U" "/etc/vps-trafico/$U" "/etc/vps-users/$U" "/etc/vps-banners/$U" "/etc/vps-plan/$U" "/etc/vps-cuota-agotada/$U"
    if [[ "${2:-}" == "keep" ]]; then userdel "$U" >/dev/null 2>&1
    else userdel -r "$U" >/dev/null 2>&1 || userdel -f "$U" >/dev/null 2>&1; fi
    banner_rebuild_match 2>/dev/null || true
    ! id "$U" >/dev/null 2>&1
}

cron_vencidos_instalar(){
    cat > /usr/local/bin/vps-cron-diario.sh <<'CRONEOF'
#!/usr/bin/env bash
# GHOST-CRON-V2
LOG=/var/log/ghost-panel.log
HOY=$(date +%Y-%m-%d)
PROTEGIDOS='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu debian admin ec2-user cloud-user vpsmgr ghostpanel dnstt opc oracle azureuser fedora centos rocky almalinux vagrant pi'
log(){ echo "$(date '+%F %T') [CRON] $*" >> "$LOG" 2>/dev/null; }
awk -F: '$3>=1000 && $3<=60000 && $1!="nobody"{print $1}' /etc/passwd | while read -r U; do
    echo " $PROTEGIDOS " | grep -q " $U " && continue
    [[ "$U" == snapd-* || "$U" == systemd-* ]] && continue
    id -nG "$U" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin' && continue      # cuentas de administracion
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
        rm -f "/etc/vps-limits/$U" "/etc/vps-trafico/$U" "/etc/vps-users/$U" "/etc/vps-plan/$U" "/etc/vps-cuota-agotada/$U" "/etc/vps-cuota-agotada/$U"
        userdel -r "$U" 2>/dev/null || userdel "$U" 2>/dev/null
        # Notificar al Bot de Telegram (si esta instalado)
        if [[ -f /opt/ghost-bot/config.env ]]; then
            . /opt/ghost-bot/config.env
            if [[ -n "${BOT_TOKEN:-}" && -n "${ADMIN_CHAT_ID:-}" ]]; then
                curl -fsS --max-time 8 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                    -d "chat_id=${ADMIN_CHAT_ID}" \
                    --data-urlencode "text=⏰ <b>Usuario vencido eliminado</b>
👤 <code>$U</code>
📅 Venció: $N" \
                    -d "parse_mode=HTML" >/dev/null 2>&1 || true
            fi
        fi
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

xray_ensure_api(){
    # Habilita Stats + API local en config.json (sin tocar inbounds de usuarios).
    local cfgp=/usr/local/etc/xray/config.json
    [[ -f "$cfgp" ]] || return 1
    python3 - <<'PY'
import json
cfgp = "/usr/local/etc/xray/config.json"
try:
    cfg = json.load(open(cfgp))
except Exception:
    raise SystemExit(1)
changed = False
if not cfg.get("stats"):
    cfg["stats"] = {}
    changed = True
pol = cfg.setdefault("policy", {}).setdefault("system", {})
for k in ("statsInboundUplink", "statsInboundDownlink", "statsOutboundUplink", "statsOutboundDownlink"):
    if not pol.get(k):
        pol[k] = True
        changed = True
inbounds = cfg.setdefault("inbounds", [])
has_api = any(
    (ib.get("protocol") == "dokodemo-door" and ib.get("tag") == "api")
    or (ib.get("listen") in ("127.0.0.1", "localhost") and ib.get("port") == 10085)
    for ib in inbounds
)
if not has_api:
    inbounds.append({
        "listen": "127.0.0.1",
        "port": 10085,
        "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1"},
        "tag": "api"
    })
    changed = True
api = cfg.setdefault("api", {})
if api.get("tag") != "api":
    api["tag"] = "api"
    api["services"] = ["HandlerService", "LoggerService", "StatsService"]
    changed = True
routing = cfg.setdefault("routing", {})
rules = routing.setdefault("rules", [])
if not any(
    (isinstance(r.get("inboundTag"), list) and "api" in r.get("inboundTag", []))
    or r.get("inboundTag") == "api"
    for r in rules
):
    rules.insert(0, {"inboundTag": ["api"], "outboundTag": "api", "type": "field"})
    changed = True
outbounds = cfg.setdefault("outbounds", [])
if not any(o.get("tag") == "api" for o in outbounds):
    outbounds.append({"protocol": "freedom", "tag": "api"})
    changed = True
if changed:
    json.dump(cfg, open(cfgp, "w"), indent=2)
    print("changed")
else:
    print("ok")
PY
}

xray_recargar(){
    local cfgp=/usr/local/etc/xray/config.json
    [[ -f "$cfgp" ]] || return 0
    xray_ensure_api >/dev/null 2>&1 || true
    xray_config_perms 2>/dev/null || true
    if systemctl is-active --quiet xray 2>/dev/null; then
        systemctl restart xray 2>/dev/null || true
    elif command -v xray >/dev/null 2>&1; then
        pkill -x xray 2>/dev/null
        /usr/local/bin/xray run -c "$cfgp" >/dev/null 2>&1 &
    fi
    return 0
}

xray_stats_usuario(){
    # Imprime up|down en bytes para email=USUARIO; vacio si API no responde.
    local U="$1" RAW
    command -v xray >/dev/null 2>&1 || return 1
    RAW=$(xray api statsquery --server=127.0.0.1:10085 2>/dev/null) || return 1
    [[ -n "$RAW" ]] || return 1
    printf '%s' "$RAW" | python3 -c '
import json,sys,re
u=sys.argv[1]
raw=sys.stdin.read()
up=down=0
try:
    data=json.loads(raw) if raw.strip()[:1] in "{[" else None
except Exception:
    data=None
if data and isinstance(data, dict) and "stat" in data:
    for s in data.get("stat") or []:
        name=s.get("name","")
        val=int(s.get("value") or 0)
        if ("user>>>%s>>>traffic>>>uplink" % u) in name: up=val
        if ("user>>>%s>>>traffic>>>downlink" % u) in name: down=val
else:
    for m in re.finditer(r"user>>>"+re.escape(u)+r">>>traffic>>>(uplink|downlink)[^\d]*(\d+)", raw or ""):
        if m.group(1)=="uplink": up=int(m.group(2))
        else: down=int(m.group(2))
print("%s|%s" % (up, down))
' "$U" 2>/dev/null
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
    xray_recargar
}

LOGROTATE_CONF='/etc/logrotate.d/ghost-panel'
logrotate_instalar(){
    # Rota los logs del panel, del bot y del tunel: semanal o al pasar 5 MB, 4 copias comprimidas.
    # copytruncate: el bot y los scripts siguen escribiendo en el mismo archivo sin perder el descriptor.
    [[ -d /etc/logrotate.d ]] || return 0
    local NUEVO
    NUEVO=$(cat <<'LREOF'
# GHOST-LOGROTATE-V1
/var/log/ghost-panel.log /var/log/ghost-bot.log /var/log/ghost-cf-tunnel.log {
    weekly
    maxsize 5M
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LREOF
)
    [[ -f "$LOGROTATE_CONF" && "$(cat "$LOGROTATE_CONF" 2>/dev/null)" == "$NUEVO" ]] && return 0
    if printf '%s\n' "$NUEVO" > "$LOGROTATE_CONF" 2>/dev/null; then
        chmod 644 "$LOGROTATE_CONF"
        vps_log INFO "logrotate configurado ($LOGROTATE_CONF)"
    fi
    return 0
}

ghost_bootstrap(){
    mkdir -p "$USUARIOS_DIR" /etc/vps-limits /etc/vps-trafico
    chmod 700 "$USUARIOS_DIR" 2>/dev/null
    touch "$LOG_PANEL" 2>/dev/null
    chmod 640 "$LOG_PANEL" 2>/dev/null || true
    [[ -f /etc/cron.d/ghost-panel-vencidos ]] && grep -q 'GHOST-CRON-V2' /usr/local/bin/vps-cron-diario.sh 2>/dev/null || cron_vencidos_instalar
    bot_backup_key_migrar                  # la copia de la clave de backup sale de /root/backups (4.1)
    logrotate_instalar                     # los logs dejan de crecer sin limite (4.2)
    xray_config_perms
    # Asegurar autenticacion por contraseña (muchas imagenes cloud la dejan en "no")
    sshd_asegurar_password_auth
    # Auto: CheckUser + banner HTML (para que USER/EXP/DAYS se sustituyan en HTTP Custom)
    checkuser_auto_activar
}

checkuser_auto_activar(){
    # Instala CheckUser en silencio si no existe, publica banner HTML y deja el servicio activo.
    # Idempotente: si ya esta todo OK, no hace nada visible.
    local PORT TOKEN need_banner=0
    if [[ ! -f /etc/vps-checkuser.conf ]]; then
        PORT=8080
        TOKEN=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 24)
        [[ -z "$TOKEN" ]] && TOKEN="ghost$(date +%s)"
        printf 'PORT=%s\nTOKEN=%s\n' "$PORT" "$TOKEN" > /etc/vps-checkuser.conf
        chmod 600 /etc/vps-checkuser.conf
        checkuser_escribir_py
        cat > /etc/systemd/system/vps-checkuser.service <<'SVCEOF'
[Unit]
Description=CheckUser API (Ghost Panel)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vps-checkuser.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
        systemctl enable --now vps-checkuser 2>/dev/null
        # Abrir puerto si ufw esta activo (protegido por TOKEN; no es resolutor DNS)
        command -v ufw >/dev/null 2>&1 && ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
        vps_log INFO "CheckUser auto-instalado (puerto $PORT, token en /etc/vps-checkuser.conf)"
        # Aviso en log: endpoint publico con token. Restringir por UFW si solo usas red interna.
        need_banner=1
    else
        # Asegurar servicio y script actualizados
        checkuser_escribir_py 2>/dev/null || true
        systemctl is-active --quiet vps-checkuser 2>/dev/null \
            || systemctl enable --now vps-checkuser 2>/dev/null || true
    fi
    # Publicar banner HTML generico (fallback) si no existe
    if [[ ! -f /etc/banner-vps ]] || [[ $need_banner -eq 1 ]]; then
        banner_html_http_custom | BANNER_HC=1 banner_publicar >/dev/null 2>&1 || true
    fi
    # Banners personalizados por usuario (nombre + vencimiento + dias, sin app CheckUser)
    banner_todos_actualizar >/dev/null 2>&1 || true
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
FR_TOP(){ printf '%b\n' "${BORDE}╭$(ui_rep ─ $((UI_W+2)))╮${NC}"; }
FR_MID(){ printf '%b\n' "${BORDE}├$(ui_rep ─ $((UI_W+2)))┤${NC}"; }
FR_BOT(){ printf '%b\n' "${BORDE}╰$(ui_rep ─ $((UI_W+2)))╯${NC}"; }
ui_box_top(){
    # ╭─ TITULO ─────────╮   (titulo con el color del tema dentro del marco)
    local t=" $1 " n
    ui_fit "$t" 999
    n=$(( UI_W + 1 - UI_FITW ))
    (( n < 1 )) && n=1
    printf '%b\n' "${BORDE}╭─${NC}${UI_ACC:-$MORADO}${t}${NC}${BORDE}$(ui_rep ─ "$n")╮${NC}"
}
ui_crumb(){
    if [[ -n "${1:-}" ]]; then printf '%b\n' "  ${GRIS}Inicio ›${NC} ${CIAN}${1}${NC}"
    else printf '%b\n' "  ${GRIS}Inicio ›${NC}"; fi
}
# --- Ancho visible de un caracter: emoji/CJK = 2 columnas, VS16/ZWJ = 0, resto = 1 ---
# Solo se usan emojis "anchos por defecto" (sin selector de variacion) para que todas las
# terminales (Termux, PuTTY, JuiceSSH, xterm...) coincidan con este calculo.
ui_cw(){
    # ui_cw CARACTER -> UI_CW (0, 1 o 2)
    local c="$1" cp
    case "$c" in [\ -~]) UI_CW=1; return ;; esac        # ASCII: camino rapido
    printf -v cp '%d' "'$c" 2>/dev/null || { UI_CW=1; return; }
    if (( cp == 0xFE0F || cp == 0xFE0E || cp == 0x200D )); then UI_CW=0
    elif (( (cp >= 0x1100  && cp <= 0x115F)  || (cp >= 0x2E80  && cp <= 0xA4CF)  ||
            (cp >= 0xAC00  && cp <= 0xD7A3)  || (cp >= 0xF900  && cp <= 0xFAFF)  ||
            (cp >= 0xFE30  && cp <= 0xFE6F)  || (cp >= 0xFF00  && cp <= 0xFF60)  ||
            (cp >= 0xFFE0  && cp <= 0xFFE6)  || (cp >= 0x1F300 && cp <= 0x1F64F) ||
            (cp >= 0x1F680 && cp <= 0x1F6FF) || (cp >= 0x1F7E0 && cp <= 0x1F7EB) ||
            (cp >= 0x1F900 && cp <= 0x1F9FF) || (cp >= 0x1FA70 && cp <= 0x1FAFF) ||
            cp == 0x231A || cp == 0x231B || cp == 0x23E9 || cp == 0x23F0 || cp == 0x23F3 || cp == 0x26A1 || cp == 0x26AA || cp == 0x26AB || cp == 0x26C5 || cp == 0x26D4 ||
            cp == 0x2705 || cp == 0x274C || cp == 0x274E || cp == 0x2795 ||
            cp == 0x2B50 || cp == 0x2B55 )); then UI_CW=2
    else UI_CW=1; fi
}
ui_fit(){
    # ui_fit TEXTO ANCHO -> UI_FIT (texto recortado a ANCHO columnas) y UI_FITW (columnas usadas)
    local s="$1" max="$2" out="" w=0 ch
    while [[ -n "$s" ]]; do
        ch="${s:0:1}"; s="${s:1}"
        ui_cw "$ch"
        (( w + UI_CW > max )) && break
        out+="$ch"; w=$(( w + UI_CW ))
    done
    UI_FIT="$out"; UI_FITW=$w
}
FR_TXT(){
    local raw="$1" out="" vis=0 esc ch W=$UI_W
    raw="${raw//\\033/$'\x1b'}"
    while [[ -n "$raw" ]]; do
        if [[ "$raw" == $'\x1b['* ]]; then
            esc="${raw%%m*}m"; out+="$esc"; raw="${raw#"$esc"}"; continue
        fi
        ch="${raw:0:1}"; ui_cw "$ch"
        (( vis + UI_CW > W )) && break
        out+="$ch"; vis=$(( vis + UI_CW )); raw="${raw:1}"
    done
    printf '%b %s%b%*s %b\n' "${BORDE}│${NC}" "$out" "$NC" "$((W-vis))" "" "${BORDE}│${NC}"
}
declare -A UI_KCOL=()
UI_ACC=""   # color de la seccion activa (lo fija el menu principal al entrar a un submenu)   # color por opcion (lo rellena el menu principal con los tonos del tema)
ui_cell(){
    # ui_cell INDICE ETIQUETA ANCHO -> "[1]  Etiqueta" coloreado, relleno a ANCHO columnas visibles
    local k="$1" lbl="${2:-}" w="$3" ic="$CIAN" lc="$BLANCO" pad txt
    [[ -n "${UI_ACC:-}" ]] && { ic="$UI_ACC"; lc="$UI_ACC"; }      # submenu: color de su seccion
    [[ "$k" == "0" ]] && { ic="$ROJO"; lc="$BLANCO"; }               # Volver/Salir siempre rojo
    [[ -n "${UI_KCOL[$k]:-}" ]] && { ic="${UI_KCOL[$k]}"; lc="${UI_KCOL[$k]}"; }
    txt=$(printf '%-4s' "[$k]")
    ui_fit "$lbl" $(( w - 6 )); lbl="$UI_FIT"
    pad=$(( w - 5 - UI_FITW ))
    (( pad < 0 )) && pad=0
    printf '%b%s%b %b%s%b%*s' "$ic" "$txt" "$NC" "$lc" "$lbl" "$NC" "$pad" ""
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
OK(){ echo -e "  ${VERDE}✅${NC} $1"; }
ERR(){ echo -e "  ${ROJO}❌${NC} $1"; }
INFO(){ echo -e "  ${CIAN}●${NC} $1"; }
WARN(){ echo -e "  ${AMARILLO}🔶${NC} $1"; }

# ---------- FICHAS: resultado listo para copiar y pegar ----------
# Solo lineas horizontales arriba y abajo, SIN bordes laterales ni relleno al final: al copiar y
# pegar (WhatsApp, Telegram, notas...) cada fila sale limpia y alineada. Emojis con ancho corregido.
FICHA_ET=22   # columnas reservadas para la etiqueta
ficha_abrir(){
    # ficha_abrir "TITULO" [COLOR] -> una sola linea ─ TITULO ─────  (mismo ancho que los marcos del panel)
    local t=" $1 " col="${2:-${UI_ACC:-$MORADO}}" n
    ui_init
    ui_fit "$t" $(( UI_W + 2 ))
    n=$(( UI_W + 3 - UI_FITW ))
    (( n < 1 )) && n=1
    echo
    printf '%b\n' "${BORDE}─${NC}${col}${UI_FIT}${NC}${BORDE}$(ui_rep ─ "$n")${NC}"
}
ficha_fila(){
    # ficha_fila "Etiqueta" "valor" [COLOR_VALOR]   (el valor va con %s: claves con \ o % salen intactas)
    local pad
    ui_fit "$1:" "$FICHA_ET"
    pad=$(( FICHA_ET - UI_FITW ))
    printf '%b%s%*s%b %b%s%b\n' "$GRIS" "$UI_FIT" "$pad" "" "$NC" "${3:-$BLANCO}" "$2" "$NC"
}
ficha_texto(){ printf '%b%s%b\n' "${2:-$BLANCO}" "$1" "$NC"; }   # linea libre (sin etiqueta), p. ej. un enlace
ficha_cerrar(){ printf '%b\n' "${BORDE}$(ui_rep ─ $((UI_W+4)))${NC}"; }
ficha_ok(){
    # ficha_ok "TITULO" "Etiqueta" "valor" ["Etiqueta2" "valor2" ...]  -> ficha completa verde
    local t="$1"; shift
    ficha_abrir "$t" "$VERDE"
    while (( $# >= 2 )); do ficha_fila "$1" "$2"; shift 2; done
    ficha_cerrar
}
ficha_aviso(){
    # igual que ficha_ok pero con titulo amarillo (avisos / pasos que requieren atencion)
    local t="$1"; shift
    ficha_abrir "$t" "$AMARILLO"
    while (( $# >= 2 )); do ficha_fila "$1" "$2"; shift 2; done
    ficha_cerrar
}
ficha_mal(){
    # igual que ficha_ok pero con titulo rojo (fallos que merecen detalle)
    local t="$1"; shift
    ficha_abrir "$t" "$ROJO"
    while (( $# >= 2 )); do ficha_fila "$1" "$2"; shift 2; done
    ficha_cerrar
}
FILA(){
    if [[ -n "$3" ]]; then
        printf " ${AZUL}[%-2s]${NC} %-26s ${AZUL}[%-2s]${NC} %s\n" "$1" "$2" "$3" "$4"
    else
        printf " ${AZUL}[%-2s]${NC} %s\n" "$1" "$2"
    fi
}

SUBTOP(){ ui_box_top "Inicio › $1"; }   # una sola linea: ruta + seccion dentro del marco
PROMPT(){
    local _p; _p="  $(echo -e "${ACENTO}👻 ❯${NC}") "
    echo
    if (( GHOST_IDLE > 0 )); then read -r -t "$GHOST_IDLE" -p "$_p" OP || ghost_salir_sin_terminal $?
    else read -r -p "$_p" OP || ghost_salir_sin_terminal $?; fi
}
seccion(){
    # seccion N FUNCION -> abre el submenu con el color de su seccion (TH_ITEMS del tema)
    UI_ACC="\033[1;38;5;${TH_ITEMS[$1-1]}m"
    "${@:2}"
    UI_ACC=""; GS_TS=0; GS_SVC_TS=0
}
ghost_fecha(){
    # Fecha/hora del pie del menu en la zona horaria elegida (Banner -> Zona horaria); si no, la del VPS
    local tz; tz=$(ghost_conf_get TZ_VISTA)
    if [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]]; then TZ="$tz" date '+%d/%m/%Y %H:%M'; else date '+%d/%m/%Y %H:%M'; fi
}
limpiar_pantalla(){ clear 2>/dev/null; printf '\033[3J'; }   # tambien borra el scrollback (sin restos arriba)

# --- Logo fantasma: 4 lineas de 7 columnas con el degradado del tema ---
ghost_logo_linea(){
    # ghost_logo_linea N (0-3) -> linea N del logo, coloreada con TH_LOGO[N]
    local c="\033[1;38;5;${TH_LOGO[$1]}m"
    case "$1" in
        0) printf '%b ▄███▄ %b' "$c" "$NC" ;;
        1) printf '%b█ %b● ●%b █%b' "$c" "$BLANCO" "$c" "$NC" ;;
        2) printf '%b█ ▀▀▀ █%b' "$c" "$NC" ;;
        3) printf '%b▀▄▀▄▀▄▀%b' "$c" "$NC" ;;
    esac
}

ghost_intro(){
    # Intro de ~1 s al abrir el panel; cualquier tecla la salta. Solo en terminal interactiva.
    [[ -t 0 && -t 1 ]] || return 0
    local i k
    ui_init; limpiar_pantalla
    printf '\n\n'
    for i in 0 1 2 3; do
        printf '   '; ghost_logo_linea "$i"
        case "$i" in
            0) printf '   %bG H O S T   P A N E L%b' "$BLANCO" "$NC" ;;
            1) printf '   %bv%s%b' "$GRIS" "$GHOST_VER" "$NC" ;;
        esac
        printf '\n'
        read -rsn1 -t 0.22 k && return 0
    done
    printf '\n   %bcargando...%b\n' "$GRIS" "$NC"
    read -rsn1 -t 0.25 k
    return 0
}

# --- Datos del negocio para la cabecera (cache de 30 s: una pasada por passwd/shadow + contadores) ---
GS_SVC_TS=0; GS_SVC_W=0; GS_SVC_LINE=""; GS_OS=""
GS_TS=0; GS_USERS=0; GS_VENC=0; GS_HOY=0; GS_PRONTO=0; GS_BLOQ=0; GS_TRAF="0 MB"; GS_ALTO=0
ghost_stats_refrescar(){
    local now out t=0 v
    now=$(date +%s)
    (( now - GS_TS < 30 )) && return 0
    GS_TS=$now
    # usuarios del panel: uid>=1000 y no protegidos. shadow: campo 2 "!..." = bloqueado; campo 8 = vencimiento (dias)
    local _adm; _adm=$(getent group sudo wheel admin 2>/dev/null | awk -F: '{print $4}' | tr ',' ' ')
    out=$(awk -F: -v today=$(( now / 86400 )) -v prot=" ${PROTEGIDOS_NOMBRES:-} " -v adm=" $_adm " '
        NR==FNR { if ($3>=1000 && $3<=60000 && $1!="nobody" && $1 !~ /^(snapd|systemd)-/ && index(prot," "$1" ")==0 && index(adm," "$1" ")==0) u[$1]=1; next }
        ($1 in u) { n++; if ($2 ~ /^!/) b++
                    if ($8 != "") { d=$8-today; if (d<0) v++; else if (d==0) h++; else if (d<=3) p++ } }
        END { print n+0, v+0, h+0, p+0, b+0 }' /etc/passwd /etc/shadow 2>/dev/null)
    read -r GS_USERS GS_VENC GS_HOY GS_PRONTO GS_BLOQ <<< "${out:-0 0 0 0 0}"
    trafico_cache_cargar
    local _pu
    while read -r _pu; do t=$(( t + ${TRAF_CACHE[$_pu]:-0} )); done < <(usuarios_panel)   # solo usuarios del panel
    if (( ${#TRAF_CACHE[@]} == 0 )); then GS_TRAF="--"; else GS_TRAF=$(fmt_bytes "$t"); fi   # "--" = contadores sin activar
    # Usuarios al 80% o mas de su cuota (alerta de la cabecera)
    GS_ALTO=0
    if (( ${#TRAF_CACHE[@]} > 0 )); then
        local f u g
        for f in /etc/vps-trafico/*; do
            [[ -f "$f" ]] || continue
            u=$(basename "$f"); g=$(tr -dc '0-9' 2>/dev/null < "$f"); g=${g:0:6}
            [[ -n "$g" ]] && (( 10#$g > 0 )) || continue
            id "$u" >/dev/null 2>&1 || continue
            (( ${TRAF_CACHE[$u]:-0} * 100 >= 10#$g * 1073741824 * 80 )) && GS_ALTO=$(( GS_ALTO + 1 ))
        done
    fi
}

ui_mini(){
    # ui_mini ETIQUETA PORCENTAJE ANCHO -> "RAM ███░░░ 34%"
    printf '%b%s%b %s %b%3s%%%b' "$GRIS" "$1" "$NC" "$(ui_bar "$2" "$3")" "$BLANCO" "$2" "$NC"
}

cab_licencia_txt(){
    # Licencia con semaforo: verde, amarillo <=7 dias, rojo <=3 dias; "∞ vitalicia" si dura mas de 10 años
    local lic lic_col txt="${VERDE}${LICENSE_OK:--}${NC}"
    if [[ -n "${LICENSE_EXP:-}" && "${LICENSE_EXP:-0}" != "0" ]]; then
        lic=$(( (LICENSE_EXP - $(date +%s)) / 86400 )); (( lic < 0 )) && lic=0
        if (( lic > 3650 )); then
            txt="${txt} ${GRIS}·${NC} ${VERDE}$(T t_ui_vital)${NC}"
        else
            lic_col=$VERDE; (( lic <= 7 )) && lic_col=$AMARILLO; (( lic <= 3 )) && lic_col=$ROJO
            txt="${txt} ${GRIS}·${NC} ${lic_col}${lic} $(T t_ui_days)${NC}"
        fi
    fi
    printf '%s' "$txt"
}

cab_negocio(){
    # cab_negocio ONLINE -> fila del negocio: usuarios · online · por vencer · bloqueados · trafico
    local ONLINE="$1" ven_n vc oc bc
    ven_n=$(( GS_VENC + GS_HOY + GS_PRONTO ))
    vc=$GRIS; (( GS_PRONTO > 0 )) && vc=$AMARILLO; (( GS_VENC + GS_HOY > 0 )) && vc=$ROJO
    oc=$GRIS; (( ONLINE > 0 )) && oc=$VERDE
    bc=$GRIS; (( GS_BLOQ > 0 )) && bc=$ROJO
    if (( UI_W >= 56 )); then
        FR_TXT "  👥 ${BLANCO}${GS_USERS}${NC} ${GRIS}·${NC} 🟢 ${oc}${ONLINE}${NC} $(T t_ui_on) ${GRIS}·${NC} ⏳ ${vc}${ven_n}${NC} $(T t_ui_venc) ${GRIS}·${NC} 🚫 ${bc}${GS_BLOQ}${NC} ${GRIS}·${NC} 📈 ${CIAN}${GS_TRAF}${NC}"
    elif (( UI_W >= 50 )); then
        FR_TXT "  👥 ${BLANCO}${GS_USERS}${NC} ${GRIS}·${NC} 🟢 ${oc}${ONLINE}${NC} $(T t_ui_on) ${GRIS}·${NC} ⏳ ${vc}${ven_n}${NC} ${GRIS}·${NC} 🚫 ${bc}${GS_BLOQ}${NC} ${GRIS}·${NC} 📈 ${CIAN}${GS_TRAF}${NC}"
    else
        FR_TXT "  👥 ${BLANCO}${GS_USERS}${NC} 🟢 ${oc}${ONLINE}${NC} ⏳ ${vc}${ven_n}${NC} 🚫 ${bc}${GS_BLOQ}${NC} 📈 ${CIAN}${GS_TRAF}${NC}"
    fi
}

cabecera(){
    # CAB_FULL=1 cabecera -> completa (solo menu principal). Sin la variable -> compacta (submenus).
    if [[ "${CAB_FULL:-0}" == 1 ]]; then cabecera_completa; else cabecera_mini; fi
}

cabecera_mini(){
    # 5 lineas: titulo+licencia, negocio, servicios (y alerta de cuotas si hay). Deja sitio al menu y al teclado.
    local ONLINE
    limpiar_pantalla
    ui_init
    ONLINE=$(online_total)
    ghost_stats_refrescar
    FR_TOP
    # Con terminal angosta se omite la version para que la licencia no se corte
    if (( UI_W >= 52 )); then FR_TXT " 👻 ${BLANCO}GHOST PANEL${NC} ${GRIS}v${GHOST_VER}${NC} 🔑 $(cab_licencia_txt)"
    else FR_TXT " 👻 ${BLANCO}GHOST PANEL${NC} 🔑 $(cab_licencia_txt)"; fi
    cab_negocio "$ONLINE"
    estado_servicios_cache; FR_TXT "  $GS_SVC_LINE"
    (( GS_ALTO > 0 )) && FR_TXT "  🔶 ${AMARILLO}${GS_ALTO} $(T t_ui_alto)${NC}"
    FR_BOT
}

cabecera_completa(){
    limpiar_pantalla
    ui_init
    local os up ram_t=0 ram_u=0 ram_p=0 cpu dsk_p=0 dsk_u="" dsk_t="" ONLINE lic_txt bw n
    [[ -n "$GS_OS" ]] || GS_OS=$( (. /etc/os-release 2>/dev/null; echo "${NAME:-Linux} ${VERSION_ID:-}") )
    os=$GS_OS
    up=$(awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
               if (d>0) printf "%dd %dh", d, h; else if (h>0) printf "%dh %dm", h, m; else printf "%dm", m}' /proc/uptime 2>/dev/null)
    [[ -z "$up" ]] && up="n/a"
    read -r ram_t ram_u < <(free -m 2>/dev/null | awk '/Mem:/{print $2, $3}')
    ram_t=${ram_t:-0}; ram_u=${ram_u:-0}
    (( ram_t > 0 )) && ram_p=$(( ram_u * 100 / ram_t ))
    cpu=$(cpu_pct)
    read -r dsk_p dsk_u dsk_t < <(df -P -h / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5, $3, $2}')
    dsk_p=${dsk_p:-0}
    ONLINE=$(online_total)
    ghost_stats_refrescar
    lic_txt=$(cab_licencia_txt)
    n=$(( UI_W - 14 )); (( n > 30 )) && n=30
    FR_TOP
    FR_TXT " $(ghost_logo_linea 0)   ${BLANCO}G H O S T   P A N E L${NC}"
    FR_TXT " $(ghost_logo_linea 1)   ${GRIS}v${GHOST_VER} · by Jorge Barrios${NC}"
    FR_TXT " $(ghost_logo_linea 2)   ${MORADO}$(ui_rep ━ "$n")${NC}"
    FR_TXT " $(ghost_logo_linea 3)   🔑 ${lic_txt}"
    FR_MID
    # Sistema
    if (( UI_W >= 50 )); then
        FR_TXT "  💻 ${BLANCO}${os}${NC} ${GRIS}·${NC} ${up}   🌍 ${CIAN}$(ip_publica)${NC}"
    else
        FR_TXT "  💻 ${BLANCO}${os}${NC} ${GRIS}·${NC} ${up}"
        FR_TXT "  🌍 ${CIAN}$(ip_publica)${NC}"
    fi
    # Recursos: una sola fila con 3 mini-barras (si no caben, vuelven las barras largas)
    bw=$(( (UI_W - 33) / 3 ))
    if (( bw >= 4 )); then
        (( bw > 10 )) && bw=10
        FR_TXT "  $(ui_mini RAM "$ram_p" "$bw")  $(ui_mini CPU "$cpu" "$bw")  $(ui_mini DSK "$dsk_p" "$bw")"
    else
        ui_gauge "RAM" "$ram_p" "${ram_u}M / ${ram_t}M"
        ui_gauge "CPU" "$cpu"
        ui_gauge "$(T t_disco)" "$dsk_p" "${dsk_u:-?} / ${dsk_t:-?}"
    fi
    cab_negocio "$ONLINE"
    estado_servicios_cache; FR_TXT "  $GS_SVC_LINE"
    (( GS_ALTO > 0 )) && FR_TXT "  🔶 ${AMARILLO}${GS_ALTO} $(T t_ui_alto)${NC}"
    FR_BOT
    echo
}


svc_dot(){
    # svc_dot "cmd-activo" "cmd-instalado" -> 🟢 corriendo | 🔴 instalado pero caido | ⚫ no instalado
    if eval "$1" >/dev/null 2>&1; then printf '🟢'
    elif [[ -n "${2:-}" ]] && eval "$2" >/dev/null 2>&1; then printf '🔴'
    else printf '⚫'; fi
}

estado_servicios_cache(){
    # La linea de servicios cuesta ~10 procesos (pgrep/systemctl): se recalcula cada 15 s (o si cambia el ancho)
    local now; printf -v now '%(%s)T' -1
    if (( now - GS_SVC_TS >= 15 )) || [[ "$GS_SVC_W" != "$UI_W" ]]; then
        GS_SVC_LINE=$(estado_servicios_min); GS_SVC_TS=$now; GS_SVC_W=$UI_W
    fi
}
estado_servicios_min(){
    # Una linea compacta para la cabecera (un solo espacio entre servicios si la terminal es angosta)
    local sp=" "; (( UI_W >= 52 )) && sp="  "
    printf '%s' "SSH $(svc_dot 'pgrep -x sshd' 'true')${sp}Xray $(svc_dot 'pgrep -x xray' '[[ -x /usr/local/bin/xray ]]')${sp}WG $(svc_dot 'systemctl is-active --quiet wg-quick@wg0' '[[ -f /etc/wireguard/wg0.conf ]]')${sp}AG $(svc_dot 'adguard_activo 2>/dev/null || systemctl is-active --quiet AdGuardHome' '[[ -d /opt/AdGuardHome ]]')${sp}ST $(svc_dot 'pgrep -f stunnel' '[[ -f /etc/stunnel/stunnel.conf ]]')${sp}CU $(svc_dot 'systemctl is-active --quiet vps-checkuser' '[[ -f /usr/local/bin/vps-checkuser.py ]]')${sp}WM $(svc_dot 'pgrep -f miniserv' '[[ -d /etc/webmin ]]')"
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
    local USU DIAS MAXC GB GB_TXT CLAVE EXPISO
    read -r -p "Nombre de usuario: " USU
    nombre_usuario_valido "$USU" || { ERR "Nombre invalido (minusculas, numeros, - y _; max 32; empieza con letra)."; PAUSA; return; }
    id "$USU" >/dev/null 2>&1 && { ERR "El usuario ya existe."; PAUSA; return; }
    if echo " $PROTEGIDOS_NOMBRES " | grep -q " $USU "; then ERR "Nombre reservado del sistema."; PAUSA; return; fi
    read -r -p "Dias de validez (ej. 30): " DIAS
    [[ "$DIAS" =~ ^[0-9]+$ && "$DIAS" -ge 1 ]] || { ERR "Dias invalidos (entero >= 1)."; PAUSA; return; }
    read -r -p "Conexion maxima (ej. 1) [1]: " MAXC; MAXC=${MAXC:-1}
    [[ "$MAXC" =~ ^[0-9]+$ ]] || { ERR "Limite invalido."; PAUSA; return; }
    # Limite de trafico en GB: vacio o 0 = sin limite (se valida ANTES de crear nada)
    read -r -p "$(T t_nu_gb) " GB; GB=${GB:-0}
    [[ "$GB" =~ ^[0-9]{1,6}$ ]] || { ERR "Trafico invalido (entero >= 0; 0 = sin limite)."; PAUSA; return; }
    GB=$((10#$GB))   # normaliza ceros a la izquierda ("010" -> 10)
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
    plan_dias_set "$USU" "$DIAS"        # dias del plan: alimenta la barra de vigencia del banner
    # Cuota de trafico (misma ruta/formato que trafico_limite). Sin limite -> sin archivo.
    if (( GB > 0 )); then
        mkdir -p /etc/vps-trafico
        echo "$GB" > "/etc/vps-trafico/$USU"
        GB_TXT="${GB} GB"
    else
        rm -f "/etc/vps-trafico/$USU"   # evita heredar un archivo viejo de un usuario homonimo
        GB_TXT="Sin limite"
    fi
    trafico_regla_usuario "$USU"       # si el conteo iptables esta activo, el usuario nuevo ya cuenta
    # Asegurar contador en 0: si se reutiliza el UID, borra y vuelve a crear la regla (bytes a cero).
    if UIDN=$(id -u "$USU" 2>/dev/null) && iptables -L VPS-TRAFFIC -n >/dev/null 2>&1; then
        while iptables -D VPS-TRAFFIC -m owner --uid-owner "$UIDN" -j RETURN 2>/dev/null; do :; done
        iptables -A VPS-TRAFFIC -m owner --uid-owner "$UIDN" -j RETURN 2>/dev/null || true
    fi
    xray_usuario add "$USU"
    # Banner personalizado con nombre/vencimiento/dias (sin configurar nada en la app)
    banner_usuario_actualizar "$USU"
    banner_rebuild_match
    # Asegurar CheckUser (opcional, por si la app lo usa)
    checkuser_auto_activar
    vps_log INFO "usuario creado: $USU (${DIAS}d, limite $MAXC, trafico $GB_TXT)"
    ficha_abrir "👻 USUARIO CREADO"
    ficha_fila "Usuario"           "$USU" "$VERDE"
    ficha_fila "Contraseña"        "$CLAVE" "$VERDE"
    ficha_fila "IP / Host"         "$(ip_publica)"
    ficha_fila "Puerto SSH"        "$(sshd_puerto_actual)"
    ficha_fila "Fecha de creación" "$(date '+%F %T')"
    ficha_fila "Días de validez"   "$DIAS"
    ficha_fila "Fecha de vencim."  "$EXPISO"
    ficha_fila "Límite conexiones" "$MAXC"
    ficha_fila "Límite de tráfico" "$GB_TXT"
    ficha_fila "Estado"            "ACTIVO" "$VERDE"
    ficha_cerrar
    # Notificar al Bot de Telegram (silencioso si no esta instalado)
    bot_notificar "✅ <b>Usuario creado</b>
👤 <code>$USU</code>
⏳ $DIAS días
🔌 Máx: $MAXC
📦 $GB_TXT"
    if [[ -f /etc/vps-checkuser.conf ]]; then
        local _P _T
        _P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
        _T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
        # el enlace va en su propia linea y sin sangria: no rompe la ficha y se copia completo
        printf '%bCheckUser:%b\n%s\n' "$GRIS" "$NC" "http://$(ip_publica):${_P}/checkuser.php?user=$USU&token=${_T}"
    fi
    PAUSA
}

cambiar_clave(){
    local USU
    pedir_usuario_ok USU || { PAUSA; return; }
    if passwd "$USU"; then
        vps_log INFO "clave cambiada: $USU"
        ficha_ok "🔑 CLAVE ACTUALIZADA" "Usuario" "$USU" "Estado" "ACTIVO"
    fi
    PAUSA
}

eliminar_usuario(){
    local USU SN
    pedir_usuario_ok USU || { PAUSA; return; }
    read -r -p "Borrar tambien su /home? (s/n): " SN
    if purgar_usuario "$USU" "$([[ "$SN" == "s" ]] || echo keep)"; then
        vps_log INFO "usuario eliminado: $USU"
        ficha_abrir "❌ USUARIO ELIMINADO" "$ROJO"
        ficha_fila "Usuario" "$USU" "$ROJO"
        ficha_fila "Carpeta /home" "$([[ "$SN" == "s" ]] && echo borrada || echo conservada)"
        ficha_cerrar
        bot_notificar "❌ <b>Usuario eliminado</b>
👤 <code>$USU</code>"
    else
        ERR "No se pudo eliminar '$USU'."
    fi
    PAUSA
}

bloquear_usuario(){
    local USU
    pedir_usuario_ok USU || { PAUSA; return; }
    if passwd -S "$USU" 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
        usermod -U "$USU"; vps_log INFO "desbloqueado: $USU"
        ficha_abrir "🔓 USUARIO DESBLOQUEADO" "$VERDE"
        ficha_fila "Usuario" "$USU" "$VERDE"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_cerrar
        bot_notificar "🔓 <b>Usuario desbloqueado</b>
👤 <code>$USU</code>"
    else
        usermod -L "$USU"; pkill -KILL -u "$USU" 2>/dev/null; vps_log INFO "bloqueado: $USU"
        ficha_abrir "🔒 USUARIO BLOQUEADO" "$ROJO"
        ficha_fila "Usuario" "$USU" "$ROJO"
        ficha_fila "Estado" "BLOQUEADO" "$ROJO"
        ficha_cerrar
        bot_notificar "🔒 <b>Usuario bloqueado</b>
👤 <code>$USU</code>"
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
    plan_dias_set "$USU" "$(dias_hasta "$EXPISO")"   # el plan vigente = dias que quedan tras renovar
    banner_usuario_actualizar "$USU"
    banner_rebuild_match
    vps_log INFO "renovado: $USU hasta $EXPISO"
    ficha_abrir "🔄 USUARIO RENOVADO"
    ficha_fila "Usuario"          "$USU" "$VERDE"
    ficha_fila "Días agregados"   "$DIAS"
    ficha_fila "Nuevo vencim."    "$EXPISO"
    ficha_fila "Días restantes"   "$(dias_hasta "$EXPISO")"
    ficha_cerrar
    # Notificar al Bot de Telegram (silencioso si no esta instalado)
    bot_notificar "🔄 <b>Usuario renovado</b>
👤 <code>$USU</code>
⏳ +$DIAS días
📅 Vence: $EXPISO"
    PAUSA
}

listar_usuarios(){
    ficha_abrir "👥 USUARIOS"
    local U EXPISO D EST LIM ON USED G P TXT COL SIN=0
    trafico_cache_cargar; TRAF_BATCH=1
    (( ${#TRAF_CACHE[@]} == 0 )) && SIN=1
    printf "%-14s %-11s %-4s %-4s %-3s %-9s %s\n" "USUARIO" "VENCE" "DIAS" "CONX" "ON" "TRAFICO" "EST"
    while read -r U; do
        EXPISO=$(usuario_fecha_cuenta "$U")
        if [[ "$EXPISO" == "never" ]]; then D="-"; else D=$(dias_hasta "$EXPISO"); fi
        EST=$(passwd -S "$U" 2>/dev/null | awk '{print $2}')
        if [[ "$EST" == "P" ]]; then EST="${VERDE}OK${NC}"; else EST="${ROJO}LOCK${NC}"; fi
        LIM=$(cat "/etc/vps-limits/$U" 2>/dev/null || echo "-")
        ON=$(usuario_online "$U")
        # Trafico usado / cuota (rojo desde 90%, amarillo desde 70%); "--" si los contadores no estan activos
        USED=$(trafico_usuario_bytes "$U"); G=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-trafico/$U"); G=${G:0:6}; COL=""
        if (( SIN )); then TXT="--"
        elif [[ -n "$G" ]] && (( 10#$G > 0 )); then
            P=$(( USED * 100 / (10#$G * 1073741824) )); TXT="$(fmt_corto "$USED")/${G}G"
            if (( P >= 90 )); then COL=$ROJO; elif (( P >= 70 )); then COL=$AMARILLO; fi
        else TXT="$(fmt_corto "$USED")"; fi
        printf "%-14s %-11s %-4s %-4s %-3s %b%-9s%b %b\n" "$U" "$EXPISO" "$D" "$LIM" "$ON" "$COL" "$TXT" "$NC" "$EST"
    done < <(usuarios_panel)
    TRAF_BATCH=0
    ficha_cerrar
    PAUSA
}

conexiones_online(){
    ficha_abrir "📡 CONEXIONES ONLINE (SSH / Dropbear, incluye túneles)"
    sesiones_por_usuario
    ficha_fila "Total sesiones" "$(online_total)" "$CIAN"
    ficha_cerrar
    PAUSA
}

matar_conexion(){
    local USU
    conexiones_online_rapido
    pedir_usuario_ok USU || { PAUSA; return; }
    if pgrep -u "$USU" >/dev/null 2>&1; then
        pkill -KILL -u "$USU" 2>/dev/null && ficha_ok "⛔ CONEXIONES CERRADAS" "Usuario" "$USU" "Estado" "Sesiones cerradas"
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
    ficha_abrir "📊 MONITOREO"
    echo -e "Uptime : $(uptime)"
    free -h | sed 's/^/         /'
    echo
    df -h / /home 2>/dev/null | sed 's/^/         /'
    echo
    ss -tunap 2>/dev/null | awk 'NR>1{print $1, $5, $7}' | head -20
    ficha_cerrar
    PAUSA
}

optimizar(){
    # Ajustes persistentes de red/kernel (no limpia disco: eso es Mantenimiento).
    INFO "Aplicando ajustes de rendimiento (BBR, buffers TCP, límites de sistema)..."
    cat > /etc/sysctl.d/99-vps-manager.conf <<'EOF'
# Ghost Panel — optimización de red y memoria
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
fs.file-max=1048576
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
net.core.somaxconn=1024
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_local_port_range=1024 65535
EOF
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    # Más descriptores abiertos para Xray / SSH / bot (sesión y procesos)
    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-ghost-panel.conf <<'LEOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
LEOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-vps-manager.conf >/dev/null 2>&1 || true
    local cong qdisc swap
    cong=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    swap=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
    ficha_abrir "⚡ OPTIMIZACIÓN APLICADA" "$VERDE"
    ficha_fila "Congestión TCP" "$cong" "$([[ "$cong" == "bbr" ]] && echo "$VERDE" || echo "$AMARILLO")"
    ficha_fila "Qdisc" "$qdisc"
    ficha_fila "Swappiness" "$swap"
    ficha_fila "Buffers TCP" "16 MB (rmem/wmem)"
    ficha_fila "Somaxconn" "1024"
    ficha_fila "file-max / nofile" "1048576 / 65535"
    ficha_fila "Persistente" "sysctl.d + limits.d + bbr al boot" "$VERDE"
    ficha_cerrar
    [[ "$cong" != "bbr" ]] && WARN "BBR no activo (kernel sin módulo o restringido). Se dejó cubic/lo disponible."
    PAUSA
}

update_sistema(){
    INFO "Actualizando paquetes..."
    apt update && apt upgrade -y
    ficha_ok "📦 SISTEMA ACTUALIZADO" "Estado" "Paquetes al día" "Fecha" "$(date '+%F %T')"
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
        ficha_ok "💾 BACKUP CREADO" "Archivo" "$FILE" "Tamaño" "$(du -h "$FILE" | cut -f1)" "Incluye" "/etc + lista de paquetes"
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
    printf '%s' \
        "$(banner_l_gruesa)" \
        '<p style="text-align:center;"><font color="#00FF7F"><b>👻 G H O S T · P A N E L 👻</b></font></p>' \
        '<p style="text-align:center;"><font color="#9E9E9E"><i>--- CONEXIÓN VIP ESTABLE ---</i></font></p>' \
        "$(banner_l_gruesa)" \
        "$(banner_p "$(banner_seg "#FFFFFF" "👤 ")$(banner_seg "#00BFFF" "USER")")" \
        "$(banner_p "$(banner_seg "#FFFFFF" "📅 ")$(banner_seg "#FFD700" "EXP")$(banner_sep)$(banner_seg "#FFFFFF" "⏳ ")$(banner_seg "#FF8C00" "DAYS")$(banner_seg "#FFFFFF" " días")")" \
        "$(banner_l_fina)" \
        '<p style="text-align:center;"><font color="#FF4444"><b>WARN</b></font></p>' \
        "$(banner_soporte_fila)" \
        '<p style="text-align:center;"><font color="#7CFC00"><i>🚀 Disfruta de la mejor velocidad 🚀</i></font></p>' \
        "$(banner_l_gruesa)"
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
    vps_log INFO "banner publicado (${SZ} bytes)"
    ficha_ok "🎨 BANNER PUBLICADO" "Destino" "${msg#Banner publicado en }" "Tamaño" "${SZ} bytes"
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
    ficha_ok "🗑 BANNER ELIMINADO" "OpenSSH" "sin banner" "Dropbear" "sin banner"
    PAUSA
}

# ------------------------------------------------------------
# TRAFICO: helpers compartidos (panel + banner)
# Total por usuario = SSH (iptables owner) + Xray (Stats API, up+down).
# ------------------------------------------------------------
declare -A TRAF_CACHE=()   # usuario -> bytes totales (se llena con trafico_cache_cargar)
TRAF_BATCH=0               # 1 = lotes (banner_todos_actualizar): reutiliza TRAF_CACHE

fmt_bytes(){
    # fmt_bytes BYTES -> "512 MB" si < 1 GB, o "1.25 GB" (2 decimales, sin bc)
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if (( b < 1073741824 )); then
        echo "$(( b / 1048576 )) MB"
    else
        local c=$(( b * 100 / 1073741824 ))
        printf '%d.%02d GB\n' $(( c / 100 )) $(( c % 100 ))
    fi
}

xray_stats_todos(){
    # Imprime "usuario up down" (bytes) por cada email Xray; nada si la API no responde.
    local RAW
    command -v xray >/dev/null 2>&1 || return 0
    RAW=$(timeout 3 xray api statsquery --server=127.0.0.1:10085 2>/dev/null) || return 0
    [[ -n "$RAW" ]] || return 0
    printf '%s' "$RAW" | python3 -c '
import json, sys, re
raw = sys.stdin.read()
st = {}
def add(u, d, v):
    st.setdefault(u, [0, 0])[0 if d == "uplink" else 1] = v
try:
    data = json.loads(raw) if raw.strip()[:1] in "{[" else None
except Exception:
    data = None
if isinstance(data, dict) and "stat" in data:
    for s in data.get("stat") or []:
        m = re.match(r"user>>>([^>]+)>>>traffic>>>(uplink|downlink)$", s.get("name", ""))
        if m:
            add(m.group(1), m.group(2), int(s.get("value") or 0))
else:
    for m in re.finditer(r"user>>>([^>\s]+)>>>traffic>>>(uplink|downlink)[^\d]*(\d+)", raw):
        add(m.group(1), m.group(2), int(m.group(3)))
for u, (a, b) in st.items():
    print(u, a, b)
' 2>/dev/null
}

trafico_cache_cargar(){
    # Lee UNA vez los contadores (iptables + Xray) de todos los usuarios -> TRAF_CACHE
    local B UIDN U UP DN
    TRAF_CACHE=()
    while read -r B UIDN; do
        [[ -n "$UIDN" ]] || continue
        U=$(id -un "$UIDN" 2>/dev/null) || continue
        TRAF_CACHE[$U]=$(( ${TRAF_CACHE[$U]:-0} + B ))
    done < <(iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk '/owner UID match/ {print $2, $NF}')
    while read -r U UP DN; do
        [[ -n "$U" ]] || continue
        TRAF_CACHE[$U]=$(( ${TRAF_CACHE[$U]:-0} + ${UP:-0} + ${DN:-0} ))
    done < <(xray_stats_todos)
}

trafico_usuario_bytes(){
    # trafico_usuario_bytes USUARIO -> bytes usados (SSH + Xray). Lectura fresca salvo en modo lote.
    (( TRAF_BATCH )) || trafico_cache_cargar
    echo "${TRAF_CACHE[$1]:-0}"
}

trafico_regla_usuario(){
    # trafico_regla_usuario USUARIO -> añade su regla al conteo iptables (idempotente).
    # Si el conteo no esta activado (cadena VPS-TRAFFIC inexistente) no hace nada.
    iptables -L VPS-TRAFFIC -n >/dev/null 2>&1 || return 0
    iptables -C VPS-TRAFFIC -m owner --uid-owner "$1" -j RETURN 2>/dev/null \
        || iptables -A VPS-TRAFFIC -m owner --uid-owner "$1" -j RETURN 2>/dev/null
    return 0
}

# Banner personalizado por usuario (sin CheckUser en la app).
# OpenSSH no expande %u en Banner: se usan bloques Match User.
# Nota: Dropbear solo admite UN banner global (/etc/dropbear/banner), no por usuario.
BANNERS_DIR='/etc/vps-banners'

banner_barra(){
    # banner_barra PORCENTAJE "#COLOR" [SEGMENTOS=10] -> barra en HTML (relleno coloreado + resto gris).
    # Si algun cliente no pinta ▰▱, cambia estos dos caracteres (p. ej. por ■ □).
    local p="${1:-0}" n="${3:-10}" f
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    (( p > 100 )) && p=100
    f=$(( (p * n + 50) / 100 ))
    printf '<font color="%s">%s</font><font color="#555555">%s</font>' "$2" "$(ui_rep ▰ "$f")" "$(ui_rep ▱ $(( n - f )))"
}
banner_seg(){ printf '<font color="%s"><b>%s</b></font>' "$1" "$2"; }      # banner_seg "#COLOR" "texto"
banner_sep(){ printf '<font color="#555555"> · </font>'; }
banner_hora(){
    # HH:MM en la zona elegida (Banner -> Zona horaria). Sin zona elegida NO devuelve nada: mostrar a los
    # clientes la hora UTC del VPS confunde mas que ayuda. "VPS" = hora del VPS con su etiqueta (UTC, UTC-3...).
    local tz z h m lbl; tz=$(ghost_conf_get TZ_VISTA)
    case "$tz" in
        "") ;;
        VPS)
            z=$(date +%z); lbl="UTC"
            if [[ "$z" != "+0000" ]]; then
                h=$(( 10#${z:1:2} )); m=${z:3:2}; lbl="UTC${z:0:1}${h}"; [[ "$m" != "00" ]] && lbl+=":$m"
            fi
            echo "$(date +%H:%M) $lbl" ;;
        *) [[ -f "/usr/share/zoneinfo/$tz" ]] && TZ="$tz" date '+%H:%M' ;;
    esac
    return 0
}
banner_soporte_txt(){
    # Texto de soporte configurado (vacio si se quito la linea)
    local S; S=$(ghost_conf_get SUPPORT); S=${S:-@JorgeBarrios}
    [[ "$S" == "NONE" ]] && return 0
    printf '%s' "$S"
}

ghost_conf_get(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' /etc/ghost-panel.conf 2>/dev/null; }
ghost_conf_set(){
    touch /etc/ghost-panel.conf; chmod 600 /etc/ghost-panel.conf
    sed -i "/^$1=/d" /etc/ghost-panel.conf
    echo "$1=$2" >> /etc/ghost-panel.conf
}
ghost_conf_del(){ [[ -f /etc/ghost-panel.conf ]] && sed -i "/^$1=/d" /etc/ghost-panel.conf; return 0; }
plan_dias_set(){ mkdir -p /etc/vps-plan; echo "$2" > "/etc/vps-plan/$1"; }   # dias del plan vigente (para la barra de vigencia)

# --- piezas del banner (siempre UNA linea; solo tags permitidos por HTTP Custom) ---
# Las lineas miden lo mismo (27 caracteres): un poco mas anchas que la fila de texto mas larga, asi el
# banner "cierra" bien arriba y abajo. Los textos fijos no deben contener USER, EXP, DAYS ni WARN.
banner_l_gruesa(){ printf '<p style="text-align:center;"><font color="#00FFFF"><b>%s</b></font></p>' "═══════════════════════════"; }
banner_l_fina(){ printf '<p style="text-align:center;"><font color="#555555">%s</font></p>' "───────────────────────────"; }
banner_p(){ printf '<p style="text-align:center;">%s</p>' "$1"; }
banner_soporte_fila(){
    local S; S=$(banner_soporte_txt)
    [[ -n "$S" ]] && banner_p "$(banner_seg "#FFFFFF" "💬 ")$(banner_seg "#00BFFF" "$S")"
    return 0
}

banner_fila(){
    # banner_fila "ETIQUETA" "#COLOR" "VALOR" -> una fila <p> con el mismo estilo del banner.
    # OJO: ni etiquetas ni valores deben contener los tokens que HTTP Custom sustituye (USER, EXP, DAYS, WARN).
    printf '<p style="text-align:center;"><font color="#FFFFFF"><b>%s : </b></font><font color="%s"><b>%s</b></font></p>' "$1" "$2" "$3"
}

banner_html_para_usuario(){
    # banner_html_para_usuario USUARIO -> HTML compacto con datos reales (UNA linea, 13 filas).
    # Estado/alerta: VENCIDA y SIN DATOS (sev 3) > POR VENCER (sev 2) > consumo >= 80% (sev 1).
    # Solo tags permitidos por HTTP Custom; ningun texto fijo contiene USER, EXP, DAYS ni WARN.
    local U="$1" EXPISO D="" PLAN_D PCT_D BAR_COL DAYS_TXT EXP_FMT CONN_TXT LIM_GB USED_B USED_TXT
    local LIM_B=0 REST_B REST_TXT REST_COLOR="#7CFC00" USED_PCT=0 PCT10=0 PCT_TXT SUP HORA
    local ST_ICON="✅" ST_TXT="ACTIVA" ST_COL="#00FF7F" ALERT="" ALERT_COL="#FFD700" SEV=0
    local R_VIG R_PLAN R_TRAF R_REST="" R_ALERT="" R_SUP B W="#FFFFFF"
    EXPISO=$(usuario_fecha_cuenta "$U")
    # Dias del plan (se guardan al crear/renovar); sin dato -> escala de 30 dias para la barra
    PLAN_D=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-plan/$U"); PLAN_D=${PLAN_D:0:5}
    if [[ -n "$PLAN_D" ]] && (( 10#$PLAN_D > 0 )); then PLAN_D=$((10#$PLAN_D)); else PLAN_D=""; fi
    # --- Vigencia ---
    if [[ "$EXPISO" == "never" ]]; then
        R_VIG=$(banner_p "$(banner_seg "$W" "📅 ")$(banner_seg "#FFD700" "Sin vencimiento")")
    else
        EXP_FMT="${EXPISO:8:2}/${EXPISO:5:2}/${EXPISO:0:4}"; D=$(dias_hasta "$EXPISO")
        PCT_D=$(( (D < 0 ? 0 : D) * 100 / ${PLAN_D:-30} )); (( PCT_D > 100 )) && PCT_D=100
        BAR_COL="#00FF7F"; (( PCT_D <= 50 )) && BAR_COL="#FF8C00"; (( PCT_D <= 20 )) && BAR_COL="#FF4444"
        B=$(banner_barra "$PCT_D" "$BAR_COL" 6)
        if (( D < 0 )); then
            DAYS_TXT="0 días"; SEV=3; ST_ICON="⛔"; ST_TXT="VENCIDA"; ST_COL="#FF4444"
            ALERT="⛔ Cuenta vencida"; ALERT_COL="#FF4444"
        else
            DAYS_TXT="$D días"; (( D == 1 )) && DAYS_TXT="1 día"
            if (( D <= 3 )); then
                SEV=2; ST_ICON="🔶"; ST_TXT="POR VENCER"; ST_COL="#FFD700"
                ALERT="🔶 Vence en $DAYS_TXT"; (( D == 0 )) && ALERT="🔶 Vence hoy"
            fi
        fi
        R_VIG=$(banner_p "$(banner_seg "$W" "📅 ")$(banner_seg "#FFD700" "$EXP_FMT")$(banner_sep)$(banner_seg "$W" "⏳ ")$(banner_seg "#FF8C00" "$DAYS_TXT") $B")
    fi
    # --- Conexiones: archivo ausente o 0 = sin limite (igual que el limiter) ---
    CONN_TXT=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-limits/$U"); CONN_TXT=${CONN_TXT:0:6}
    if [[ -n "$CONN_TXT" ]] && (( 10#$CONN_TXT > 0 )); then
        CONN_TXT=$((10#$CONN_TXT)); if (( CONN_TXT == 1 )); then CONN_TXT="1 conexión"; else CONN_TXT="$CONN_TXT conexiones"; fi
    else CONN_TXT="conexiones sin límite"; fi
    # --- Trafico (SSH + Xray) y cuota en GB: archivo ausente o 0 = sin limite ---
    USED_B=$(trafico_usuario_bytes "$U"); USED_TXT=$(fmt_bytes "$USED_B")
    LIM_GB=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-trafico/$U"); LIM_GB=${LIM_GB:0:6}
    if [[ -n "$LIM_GB" ]] && (( 10#$LIM_GB > 0 )); then
        LIM_GB=$((10#$LIM_GB)); LIM_B=$(( LIM_GB * 1073741824 )); REST_B=$(( LIM_B - USED_B )); (( REST_B < 0 )) && REST_B=0
        REST_TXT=$(fmt_bytes "$REST_B")
        USED_PCT=$(( USED_B * 100 / LIM_B )); (( USED_PCT > 100 )) && USED_PCT=100
        # Porcentaje con un decimal por debajo del 10% (50 MB de 10 GB -> 0.5%, no "0%")
        PCT10=$(( USED_B * 1000 / LIM_B ))
        if (( USED_B == 0 )); then PCT_TXT="0%"
        elif (( PCT10 < 100 )); then (( PCT10 < 1 )) && PCT10=1; PCT_TXT="$(( PCT10 / 10 )).$(( PCT10 % 10 ))%"
        else PCT_TXT="${USED_PCT}%"; fi
        BAR_COL="#00FF7F"; (( USED_PCT >= 70 )) && BAR_COL="#FF8C00"; (( USED_PCT >= 90 )) && BAR_COL="#FF4444"
        (( REST_B * 10 <= LIM_B )) && REST_COLOR="#FF4444"       # queda 10% o menos -> rojo
        R_PLAN=$(banner_p "$(banner_seg "$W" "📦 ")$(banner_seg "#40E0D0" "${LIM_GB} GB")$(banner_sep)$(banner_seg "$W" "🔌 ")$(banner_seg "#00FF7F" "$CONN_TXT")")
        R_TRAF=$(banner_p "$(banner_seg "$W" "📊 ")$(banner_seg "#DA70D6" "$USED_TXT")$(banner_seg "$W" " de ")$(banner_seg "#40E0D0" "${LIM_GB} GB") $(banner_barra "$USED_PCT" "$BAR_COL" 6) $(banner_seg "#DA70D6" "$PCT_TXT")")
        R_REST=$(banner_p "$(banner_seg "$W" "🔋 Restante ")$(banner_seg "$REST_COLOR" "$REST_TXT")")
        if (( USED_B >= LIM_B )) || [[ -f "/etc/vps-cuota-agotada/$U" ]]; then
            (( SEV < 3 )) && { SEV=3; ST_ICON="⛔"; ST_TXT="CUOTA AGOTADA"; ST_COL="#FF4444"; ALERT="⛔ CUOTA AGOTADA - contactá al administrador"; ALERT_COL="#FF4444"; }
        elif (( USED_PCT >= 80 && SEV < 1 )); then
            SEV=1; ALERT="🔶 Consumo al ${USED_PCT}%"; (( USED_PCT >= 90 )) && ALERT_COL="#FF8C00"
        fi
    else
        R_PLAN=$(banner_p "$(banner_seg "$W" "📦 ")$(banner_seg "#40E0D0" "Datos sin límite")$(banner_sep)$(banner_seg "$W" "🔌 ")$(banner_seg "#00FF7F" "$CONN_TXT")")
        R_TRAF=$(banner_p "$(banner_seg "$W" "📊 ")$(banner_seg "#DA70D6" "$USED_TXT usados")")
    fi
    [[ -n "$ALERT" ]] && R_ALERT=$(banner_p "$(banner_seg "$ALERT_COL" "$ALERT")")
    SUP=$(banner_soporte_txt); HORA=$(banner_hora); R_SUP=""
    if [[ -n "$SUP" && -n "$HORA" ]]; then
        R_SUP=$(banner_p "$(banner_seg "$W" "💬 ")$(banner_seg "#00BFFF" "$SUP")$(banner_sep)<font color=\"#9E9E9E\">🕒 ${HORA}</font>")
    elif [[ -n "$SUP" ]]; then
        R_SUP=$(banner_p "$(banner_seg "$W" "💬 ")$(banner_seg "#00BFFF" "$SUP")")
    elif [[ -n "$HORA" ]]; then
        R_SUP=$(banner_p "<font color=\"#9E9E9E\">🕒 ${HORA}</font>")
    fi
    printf '%s' \
        "$(banner_l_gruesa)" \
        '<p style="text-align:center;"><font color="#00FF7F"><b>👻 G H O S T · P A N E L 👻</b></font></p>' \
        '<p style="text-align:center;"><font color="#9E9E9E"><i>--- CONEXIÓN VIP ESTABLE ---</i></font></p>' \
        "$(banner_l_gruesa)" \
        "$(banner_p "$(banner_seg "$W" "👤 ")$(banner_seg "#00BFFF" "$U")$(banner_sep)$(banner_seg "$ST_COL" "$ST_ICON $ST_TXT")")" \
        "$R_VIG" "$R_PLAN" "$R_TRAF" "$R_REST" \
        "$(banner_l_fina)" \
        "$R_ALERT" "$R_SUP" \
        '<p style="text-align:center;"><font color="#7CFC00"><i>🚀 Disfruta de la mejor velocidad 🚀</i></font></p>' \
        "$(banner_l_gruesa)"
}

banner_usuario_actualizar(){
    # Genera /etc/vps-banners/USUARIO con HTML ya resuelto
    local U="$1"
    [[ -z "$U" ]] && return 1
    mkdir -p "$BANNERS_DIR"
    chmod 755 "$BANNERS_DIR"
    banner_html_para_usuario "$U" > "$BANNERS_DIR/$U"
    chmod 644 "$BANNERS_DIR/$U"
}

banner_rebuild_match(){
    # Reescribe al final de sshd_config los Match User con Banner personalizado.
    # Seguro: valida con sshd -t y restaura backup si falla.
    # Optimizacion: si el hash de la lista de banners no cambio, no reescribe ni recarga.
    local bak="${SSHD_CFG}.ghost-banners.bak" u hash_now hash_old=""
    [[ -f "$SSHD_CFG" ]] || return 1
    mkdir -p "$BANNERS_DIR"
    hash_now=$(find "$BANNERS_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | sha256sum | cut -c1-16)
    hash_old=$(awk '/# GHOST-BANNERS-HASH /{print $3; exit}' "$SSHD_CFG" 2>/dev/null)
    if [[ -n "$hash_old" && "$hash_old" == "$hash_now" ]] && grep -q '# GHOST-BANNERS-INICIO' "$SSHD_CFG" 2>/dev/null; then
        return 0   # nada que cambiar
    fi
    if grep -q '# GHOST-BANNERS-INICIO' "$SSHD_CFG" 2>/dev/null; then
        cp -a "$SSHD_CFG" "$bak"
        sed -i '/# GHOST-BANNERS-INICIO/,/# GHOST-BANNERS-FIN/d' "$SSHD_CFG"
    else
        cp -a "$SSHD_CFG" "$bak"
    fi
    {
        echo
        echo "# GHOST-BANNERS-INICIO"
        echo "# GHOST-BANNERS-HASH $hash_now"
        echo "# Banners personalizados por usuario (generado por Ghost Panel)"
        for u in "$BANNERS_DIR"/*; do
            [[ -f "$u" ]] || continue
            u=$(basename "$u")
            id "$u" >/dev/null 2>&1 || continue
            usuario_protegido "$u" && continue
            echo "Match User $u"
            echo "    Banner $BANNERS_DIR/$u"
        done
        echo "# GHOST-BANNERS-FIN"
    } >> "$SSHD_CFG"
    if ! sshd -t 2>/dev/null; then
        cp -a "$bak" "$SSHD_CFG"
        ERR "sshd_config invalido al aplicar banners; se restauro."
        return 1
    fi
    sshd_recargar 2>/dev/null || true
    return 0
}

banner_todos_actualizar(){
    # Regenera banner de todos los usuarios humanos + Match en sshd
    local U
    mkdir -p "$BANNERS_DIR"
    trafico_cache_cargar; TRAF_BATCH=1     # una sola lectura de contadores para todos los usuarios
    while read -r U; do
        usuario_protegido "$U" && continue
        banner_usuario_actualizar "$U"
    done < <(usuarios_panel)
    TRAF_BATCH=0
    banner_rebuild_match
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
    local P T IP U
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(ip_publica)
    ficha_ok "📡 CHECKUSER REINICIADO" "Estado" "corriendo" "Puerto" "${P:-8080}/tcp" "Campos" "expiration / days_left / warning / limit / online"
    printf '%bURL CheckUser:%b\n%s\n' "$GRIS" "$NC" "http://$IP:${P:-8080}/checkuser.php?user=USUARIO&token=$T"
    U=$(usuarios_panel | head -n1)
    if [[ -n "$U" ]]; then
        printf '%bPrueba con %s:%b\n' "$GRIS" "$U" "$NC"
        curl -s --max-time 4 "http://127.0.0.1:${P:-8080}/checkuser.php?user=$U&token=$T"; echo
    fi
    PAUSA
}

banner_soporte_menu(){
    local cur S re
    re='^[A-Za-z0-9@._:/+-]{1,40}$'
    cur=$(ghost_conf_get SUPPORT); cur=${cur:-@JorgeBarrios}
    echo -e "${CIAN}--- SOPORTE EN EL BANNER ---${NC}"
    echo "  Lo ven tus clientes al conectar: 💬 SOPORTE : <texto>"
    echo "  Ej: @TuUsuario   o   wa.me/549XXXXXXXXXX     (sin espacios)"
    [[ "$cur" == "NONE" ]] && cur="(sin linea de soporte)"
    read -r -p "  Texto [$cur]  (0 = quitar la linea): " S
    if [[ -z "$S" ]]; then INFO "Sin cambios."; PAUSA; return; fi
    if [[ "$S" == "0" ]]; then ghost_conf_set SUPPORT NONE
    elif [[ "$S" =~ $re ]]; then ghost_conf_set SUPPORT "$S"
    else ERR "Texto invalido (letras, numeros y @ . _ : / + -; max 40; sin espacios)."; PAUSA; return; fi
    banner_todos_actualizar >/dev/null 2>&1 || true
    ficha_ok "💬 SOPORTE ACTUALIZADO" "Texto" "$(ghost_conf_get SUPPORT)" "Banners" "de cada usuario"
    INFO "El banner generico (opcion 1) se actualiza al volver a publicarlo."
    PAUSA
}

banner_tz_menu(){
    local cur OPC TZN i re lista=(America/Argentina/Buenos_Aires America/Mexico_City America/Bogota America/Lima America/Santiago America/Sao_Paulo America/New_York Europe/Madrid UTC)
    re='^[A-Za-z0-9_+/-]{1,40}$'
    cur=$(ghost_conf_get TZ_VISTA)
    echo -e "${CIAN}--- ZONA HORARIA ---${NC}"
    echo "  Hora que ven tus clientes en el banner y que muestra el pie del panel."
    case "$cur" in
        "")  echo "  Ahora: sin elegir (el banner NO muestra la hora)" ;;
        VPS) echo "  Ahora: hora del VPS ($(date +%Z))" ;;
        *)   echo "  Ahora: $cur" ;;
    esac
    echo
    i=0; for TZN in "${lista[@]}"; do i=$((i+1)); printf '  %b[%d]%b %s\n' "$CIAN" "$i" "$NC" "$TZN"; done
    printf '  %b[10]%b Otra (escribirla)\n  %b[0]%b Usar la hora del VPS (%s)\n' "$CIAN" "$NC" "$ROJO" "$NC" "$(date +%Z)"
    read -r -p "  > " OPC
    case "$OPC" in
        0) TZN="VPS" ;;
        10) read -r -p "  Zona (ej: America/Lima): " TZN ;;
        [1-9]) TZN="${lista[$((OPC-1))]}" ;;
        *) INFO "Sin cambios."; PAUSA; return ;;
    esac
    if [[ "$TZN" != "VPS" ]]; then
        if [[ ! "$TZN" =~ $re || ! -f "/usr/share/zoneinfo/$TZN" ]]; then
            ERR "Zona no valida (o falta el paquete tzdata)."; PAUSA; return
        fi
    fi
    ghost_conf_set TZ_VISTA "$TZN"
    banner_todos_actualizar >/dev/null 2>&1 || true
    ficha_ok "🕒 ZONA HORARIA" "Zona" "$TZN" "En el banner" "$(banner_hora)"
    PAUSA
}

ghost_tz_primera_vez(){
    # Una sola vez: pregunta la zona horaria que veran los clientes (el banner no muestra hora hasta elegirla)
    [[ -t 0 && -t 1 ]] || return 0
    [[ -n "$(ghost_conf_get TZ_VISTA)" || -n "$(ghost_conf_get TZ_ASKED)" ]] && return 0
    ghost_conf_set TZ_ASKED 1
    limpiar_pantalla
    echo -e "${AMARILLO}Hora del banner${NC}"
    echo "  El VPS usa hora UTC y tus clientes no. Elige la zona horaria que veran en su banner."
    echo "  (Se cambia cuando quieras en Herramientas/Seguridad -> Banner -> Zona horaria)"
    echo
    banner_tz_menu
}

menu_banner(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_banner)"
        FR_OPT 1 "🎨 $(T t_banner_html)" "" ""
        FR_OPT 2 "📝 $(T t_banner_msg)" "" ""
        FR_OPT 3 "🗑 $(T t_banner_del)" "" ""
        FR_OPT 4 "📡 $(T t_banner_cu)" "" ""
        FR_OPT 5 "💬 $(T t_banner_sop)" "" ""
        FR_OPT 6 "🕒 $(T t_banner_tz)" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) banner_dinamico_html ;;
            2) banner_ssh ;;
            3) banner_eliminar ;;
            4) banner_con_checkuser ;;
            5) banner_soporte_menu ;;
            6) banner_tz_menu ;;
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
            # Fallback: intenta la ultima version publicada en sourceforge / download.webmin
            local WDEB=""
            WDEB=$(curl -fsSL --max-time 15 https://download.webmin.com/download/repository/pool/contrib/w/webmin/ 2>/dev/null \
                | grep -oE 'webmin_[0-9.]+_all\.deb' | sort -V | tail -1)
            if [[ -n "$WDEB" ]]; then
                wget -q "https://download.webmin.com/download/repository/pool/contrib/w/webmin/$WDEB" -O "$TMP/webmin.deb" \
                  || wget -q "https://prdownloads.sourceforge.net/webadmin/$WDEB" -O "$TMP/webmin.deb"
            else
                # ultima conocida razonable (se actualiza en futuras revisiones del panel)
                wget -q https://download.webmin.com/download/repository/pool/contrib/w/webmin/webmin_2.202_all.deb -O "$TMP/webmin.deb" \
                  || wget -q https://prdownloads.sourceforge.net/webadmin/webmin_2.202_all.deb -O "$TMP/webmin.deb"
            fi
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
    pgrep -f miniserv >/dev/null 2>&1 || ERR "Webmin quedo detenido. Proba con la opcion 2 (Estado / reiniciar) del menu."
    local IP; IP=$(ip_publica)
    ficha_ok "💻 WEBMIN INSTALADO" "Acceso" "https://${IP}:${WP}" "Usuario" "root (o cualquier usuario con sudo)"
    INFO "Si es una VM remota, acepta el aviso de certificado autofirmado."
    PAUSA
}

remover_webmin(){
    INFO "Deteniendo y eliminando Webmin..."
    systemctl stop webmin 2>/dev/null
    apt purge -y webmin 2>/dev/null
    rm -f /etc/apt/sources.list.d/webmin.list /usr/share/keyrings/webmin.gpg
    apt update -y >/dev/null 2>&1
    ficha_ok "🗑 WEBMIN REMOVIDO" "Estado" "desinstalado"
    PAUSA
}

menu_webmin(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_webmin)"
        FR_OPT 1 "$(T t_webmin_inst)" 4 "$(T t_cambiar_puerto)"
        FR_OPT 2 "Estado / reiniciar" 5 "$(T t_remover_webmin)"
        FR_OPT 3 "$(T t_abrir_10000)" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_webmin ;;
            2) systemctl restart webmin 2>/dev/null || /etc/webmin/start >/dev/null 2>&1
               sleep 1
               if pgrep -f miniserv >/dev/null 2>&1; then
                   local WP; WP=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1); WP=${WP:-10000}
                   ficha_ok "💻 WEBMIN ACTIVO" "Puerto" "$WP" "Estado" "corriendo"
               else
                   ERR "Webmin no levanto (¿sin systemd ni /etc/webmin/start?)."
               fi
               PAUSA ;;
            3) ufw allow 10000/tcp 2>/dev/null && ficha_ok "🔓 PUERTO ABIERTO" "Puerto" "10000/tcp" "Firewall" "UFW" || ERR "UFW no activo."; PAUSA ;;
            4) if ! pedir_puerto P "Nuevo puerto Webmin: " "" tcp; then PAUSA; continue; fi
               sed -i "s/^port=.*/port=$P/;s/^listen=.*/listen=$P/" /etc/webmin/miniserv.conf 2>/dev/null
               ufw allow "$P/tcp" >/dev/null 2>&1
               systemctl restart webmin 2>/dev/null && ficha_ok "💻 PUERTO WEBMIN CAMBIADO" "Puerto nuevo" "$P/tcp" "Estado" "reiniciado" || ERR "Webmin no instalado."
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
        # Compatibilidad: enlaces antiguos
        ln -sf "$DEST" /usr/local/bin/vpsmgr 2>/dev/null || true
        ln -sf "$DEST" /usr/local/bin/vps 2>/dev/null || true
        # Alias en bashrc
        grep -q "alias ghostpanel=" /root/.bashrc 2>/dev/null || echo "alias ghostpanel='/usr/local/bin/ghostpanel'" >> /root/.bashrc
        grep -q "alias vps=" /root/.bashrc 2>/dev/null || echo "alias vps='/usr/local/bin/ghostpanel'" >> /root/.bashrc
        ficha_ok "💻 COMANDO INSTALADO" "Comando" "ghostpanel" "Alias" "vpsmgr  |  vps" "Ruta" "$DEST"
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

limiter_intervalo(){
    local v; v=$(ghost_conf_get LIMITER_INTERVALO)
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 5 )) && echo "$v" || echo 30
}

limiter_escribir_archivos(){
    mkdir -p /etc/vps-limits
    cat > /usr/local/bin/vps-limiter.sh <<'LIMEOF'
#!/bin/bash
# GHOST-LIMITER-V2
# GHOST PANEL - Limiter: mantiene como maximo N sesiones por usuario (/etc/vps-limits/USUARIO).
# Corta las MAS NUEVAS. Cuenta procesos sshd/dropbear del usuario (tuneles sin tty incluidos).
# Eficiencia (VPS de 1 vCPU): UNA sola lectura de procesos por ciclo, sin procesos por usuario.
# Intervalo en segundos: /etc/ghost-panel.conf -> LIMITER_INTERVALO=30 (minimo 5; se relee cada ciclo).
# Log: /var/log/ghost-panel.log cuando corta sesiones.
LOG=/var/log/ghost-panel.log
CONF=/etc/ghost-panel.conf
exec 9>/run/vps-limiter.lock
flock -n 9 || { echo "vps-limiter ya esta corriendo"; exit 0; }   # una sola instancia
log_cut(){ printf '%s [LIMITER] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
declare -A CORTADAS MAXU
while true; do
    INTERVALO=$(awk -F= '$1=="LIMITER_INTERVALO"{print $2; exit}' "$CONF" 2>/dev/null)
    [[ "$INTERVALO" =~ ^[0-9]+$ ]] && (( INTERVALO >= 5 )) || INTERVALO=30
    # 1) limites de cada usuario (sin procesos: read + expansion de parametros)
    LIM=""
    for f in /etc/vps-limits/*; do
        [[ -f "$f" ]] || continue
        read -r MAX < "$f" 2>/dev/null; MAX=${MAX//[!0-9]/}
        [[ -n "$MAX" ]] && (( 10#$MAX > 0 )) && LIM+="${f##*/} $((10#$MAX))"$'\n'
    done
    if [[ -n "$LIM" ]]; then
        CORTADAS=(); MAXU=()
        # 2) UNA lectura de procesos, del mas viejo al mas nuevo: se conservan los primeros MAX y se cortan los demas
        while read -r U P M; do
            [[ -n "$P" ]] || continue
            if kill -KILL "$P" 2>/dev/null; then CORTADAS[$U]=$(( ${CORTADAS[$U]:-0} + 1 )); MAXU[$U]=$M; fi
        done < <(ps -eo user:32=,pid=,comm= --sort=-etimes 2>/dev/null | awk -v lim="$LIM" '
            BEGIN { n = split(lim, L, "\n"); for (i = 1; i <= n; i++) { split(L[i], a, " "); if (a[1] != "") mx[a[1]] = a[2] } }
            ($3 == "sshd" || $3 == "dropbear") && ($1 in mx) { if (++c[$1] > mx[$1]) print $1, $2, mx[$1] }')
        for U in "${!CORTADAS[@]}"; do
            N=${CORTADAS[$U]}; MAX=${MAXU[$U]}
            log_cut "usuario=$U max=$MAX cortadas=$N"
            # Notificar al Bot de Telegram (si esta instalado)
            if [ -f /opt/ghost-bot/config.env ]; then
                . /opt/ghost-bot/config.env
                if [ -n "${BOT_TOKEN:-}" ] && [ -n "${ADMIN_CHAT_ID:-}" ]; then
                    curl -fsS --max-time 8 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                        -d "chat_id=${ADMIN_CHAT_ID}" \
                        --data-urlencode "text=🚦 <b>Conexiones cortadas</b>
👤 <code>$U</code>
🔌 Máximo: $MAX
✂️ Cortadas: $N" \
                        -d "parse_mode=HTML" >/dev/null 2>&1 || true
                fi
            fi
        done
    fi
    sleep "$INTERVALO"
done
LIMEOF
    chmod 755 /usr/local/bin/vps-limiter.sh 2>/dev/null || return 1
    cat > /etc/systemd/system/vps-limiter.service <<'LSVC'
[Unit]
Description=GHOST PANEL - limitador de sesiones SSH
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/local/bin/vps-limiter.sh
Restart=on-failure
RestartSec=10
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
LSVC
}

limiter_migrar(){
    # Pasa un limiter viejo (bucle de 4 s con procesos por usuario) a la v2, sin preguntar
    limiter_escribir_archivos || return 1
    systemctl daemon-reload 2>/dev/null
    systemctl restart vps-limiter 2>/dev/null
    vps_log INFO "limiter actualizado a v2 (una lectura de procesos por ciclo)"
}

limiter_aplicar(){
    limiter_escribir_archivos || { ERR "Sin permiso para escribir /usr/local/bin"; PAUSA; return; }
    limiter_quitar_forcecommand
    systemctl daemon-reload
    systemctl enable vps-limiter >/dev/null 2>&1
    systemctl restart vps-limiter >/dev/null 2>&1
    if systemctl is-active --quiet vps-limiter 2>/dev/null; then
        ficha_ok "🚦 LIMITER ACTIVO" "Estado" "ACTIVO" "Usuarios con límite" "$(ls /etc/vps-limits/ 2>/dev/null | wc -l)" "Revisa cada" "$(limiter_intervalo) segundos" "Acción" "corta las sesiones MÁS NUEVAS"
        INFO "Intervalo configurable: ghost_conf LIMITER_INTERVALO en /etc/ghost-panel.conf (mínimo 5 s)."
        INFO "Con Dropbear solo se cuentan sesiones con shell; con OpenSSH también los túneles."
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
    ficha_ok "🛑 LIMITER DESACTIVADO" "Estado" "desactivado"
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
    ficha_ok "🚨 FAIL2BAN ACTIVO" "Protege" "SSH" "Intentos fallidos" "5" "Baneo" "1 hora"
    PAUSA
}

cambiar_puerto_ssh(){
    local P
    # Permitimos que el propio sshd ya este en ese puerto (reconfiguracion).
    if ! pedir_puerto P "Puerto SSH nuevo (ej. 2222): " "" tcp sshd; then PAUSA; return; fi
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
        vps_log INFO "puerto ssh -> $P"
        ficha_ok "🔑 PUERTO SSH CAMBIADO" "Puerto nuevo" "$P/tcp" "Firewall" "abierto en UFW"
        WARN "Abre otra terminal y prueba conectarte ANTES de cerrar esta."
        INFO "Si usas Stunnel/WS-epro, reinstálalos para que apunten al nuevo puerto."
    else
        ERR "sshd no escucha en $P. Revisa: sshd -T | grep -i ^port"
    fi
    PAUSA
}

ver_puertos(){
    ficha_abrir "🔎 PUERTOS ESCUCHANDO (TCP)"
    ss -tlnp 2>/dev/null | head -25
    ficha_cerrar
    ficha_abrir "🛡 UFW (firewall)"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose 2>/dev/null | head -20
    else
        echo "UFW no instalado."
    fi
    ficha_cerrar
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
    if ufw allow "$P/$PROTO" >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qE "^$P/"; then
        ficha_ok "🔓 PUERTO ABIERTO" "Puerto" "$P/$PROTO" "Firewall" "UFW"
    else
        ERR "No se confirmo la regla."
    fi
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
    banner_usuario_actualizar "$USU"   # el banner refleja el nuevo limite de conexiones
    ficha_ok "🚦 LÍMITE ACTUALIZADO" "Usuario" "$USU" "Máx. sesiones" "$([[ "$M" == 0 ]] && echo "sin límite" || echo "$M")"
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
    ficha_abrir "🧪 USUARIO DE PRUEBA CREADO"
    ficha_fila "Usuario"           "$USU" "$VERDE"
    ficha_fila "Contraseña"        "$CLAVE" "$VERDE"
    ficha_fila "IP / Host"         "$(ip_publica)"
    ficha_fila "Puerto SSH"        "$(sshd_puerto_actual)"
    ficha_fila "Vencimiento"       "$(date -d '+1 day' +%F) (mañana)"
    ficha_fila "Límite conexiones" "$MAXC"
    ficha_cerrar
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
    done < <(usuarios_panel)
    if [[ $BORRADOS -eq 0 ]]; then ficha_ok "🧹 USUARIOS VENCIDOS" "Eliminados" "0 (no hay vencidos)"
    else ficha_ok "🧹 USUARIOS VENCIDOS" "Eliminados" "$BORRADOS"; fi
    PAUSA
}

mantenimiento(){
    # Limpieza puntual (no cambia sysctl: eso es Optimizar).
    local antes despues liberado acciones="" trim_st sync_st
    INFO "Limpiando sistema..."
    antes=$(df -PB1 / 2>/dev/null | awk 'NR==2{print $4}')
    antes=${antes:-0}

    apt autoremove -y >/dev/null 2>&1 && acciones+="apt autoremove, "
    apt clean >/dev/null 2>&1 && acciones+="apt clean, "
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    journalctl --vacuum-size=100M >/dev/null 2>&1 || true
    acciones+="journal 7d/100M, "
    find /tmp -type f -mtime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
    acciones+="/tmp+/var/tmp, "
    ls -t /root/backups/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null || true
    acciones+="logs.gz, backups×3, "
    if [[ -f /etc/logrotate.d/ghost-panel ]]; then
        logrotate -f /etc/logrotate.d/ghost-panel >/dev/null 2>&1 || true
        acciones+="logrotate Ghost, "
    fi
    systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
    trim_st=$(systemctl is-enabled fstrim.timer 2>/dev/null || echo "n/a")
    # Hora: intenta sync si hay systemd-timesyncd o chrony/ntp
    sync_st="sin cambio"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1 && sync_st="NTP activo" || true
        timedatectl status 2>/dev/null | grep -qi 'synchronized: yes' && sync_st="sincronizada" || true
    fi
    # Opcional: solo si el software está instalado
    if command -v snap >/dev/null 2>&1; then
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r _name _rev; do
            [[ -n "$_name" && -n "$_rev" ]] && snap remove "$_name" --revision="$_rev" >/dev/null 2>&1 || true
        done
        acciones+="snap viejos, "
    fi
    if command -v docker >/dev/null 2>&1; then
        docker system prune -f >/dev/null 2>&1 || true
        acciones+="docker prune, "
    fi
    acciones=${acciones%, }

    despues=$(df -PB1 / 2>/dev/null | awk 'NR==2{print $4}')
    despues=${despues:-0}
    if (( despues >= antes )); then
        liberado=$(fmt_bytes $(( despues - antes )) 2>/dev/null || echo "$(( (despues - antes) / 1048576 )) MB")
    else
        liberado="0 B"
    fi

    ficha_abrir "🧹 MANTENIMIENTO LISTO" "$VERDE"
    ficha_fila "Espacio liberado" "$liberado" "$VERDE"
    ficha_fila "Acciones" "${acciones:-limpieza básica}"
    ficha_fila "Backups" "se conservan los últimos 3"
    ficha_fila "TRIM semanal" "$trim_st"
    ficha_fila "Hora del sistema" "$sync_st"
    ficha_cerrar
    PAUSA
}

auto_menu_snippet(){
    cat <<'AMEOF'
# VPS-JB-AUTOMENU-INICIO
case "$-" in *i*) [ -t 0 ] && [ -z "$GHOST_PANEL_ACTIVO" ] && [ -x /usr/local/bin/ghostpanel ] && /usr/local/bin/ghostpanel ;; esac
# VPS-JB-AUTOMENU-FIN
AMEOF
}

auto_menu_migrar(){
    # Snippet viejo (sin guardas: abria el panel en cualquier shell interactivo) -> snippet nuevo
    local rc
    for rc in /root/.bashrc "$HOME/.bashrc"; do
        [[ -f "$rc" ]] || continue
        grep -q "VPS-JB-AUTOMENU-INICIO" "$rc" 2>/dev/null || continue
        grep -q "GHOST_PANEL_ACTIVO" "$rc" 2>/dev/null && continue
        sed -i '/VPS-JB-AUTOMENU-INICIO/,/VPS-JB-AUTOMENU-FIN/d' "$rc"
        auto_menu_snippet >> "$rc"
    done
}

auto_menu(){
    if grep -q "VPS-JB-AUTOMENU-INICIO" "$HOME/.bashrc" 2>/dev/null; then
        ficha_ok "📌 AUTO-MENÚ" "Estado" "ya estaba activo"; PAUSA; return
    fi
    auto_menu_snippet >> "$HOME/.bashrc"
    ficha_ok "📌 AUTO-MENÚ ACTIVADO" "Estado" "activo" "Efecto" "el menú abre al iniciar sesión root"
    PAUSA
}

quitar_auto_menu(){
    sed -i '/VPS-JB-AUTOMENU-INICIO/,/VPS-JB-AUTOMENU-FIN/d' "$HOME/.bashrc" 2>/dev/null
    ficha_ok "📌 AUTO-MENÚ DESACTIVADO" "Estado" "desactivado"
    PAUSA
}

diagnostico(){
    ficha_abrir "🩺 DIAGNÓSTICO DEL SERVIDOR"
    local RAM_P DISCO_P LOAD ADV=0 TOP5 SW_T
    RAM_P=$(free | awk '/Mem/{printf "%d", $3*100/$2}')
    DISCO_P=$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    echo -e " RAM: ${RAM_P}%   Disco: ${DISCO_P}%   Carga: $LOAD"
    free -h 2>/dev/null | awk '/^Mem:/{printf "        total %s   usada %s   libre %s\n", $2, $3, $7}'
    SW_T=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
    if [[ "${SW_T:-0}" -gt 0 ]] 2>/dev/null; then
        free -h 2>/dev/null | awk '/^Swap:/{printf "        swap  %s usada de %s\n", $3, $2}'
    else
        echo -e "        swap  sin configurar"
    fi
    if [[ "$RAM_P" -gt 85 ]]; then
        echo -e " ${ROJO}!${NC} RAM al ${RAM_P}%. Los procesos que mas consumen:"
        TOP5=$(ps -eo rss=,comm= --sort=-rss 2>/dev/null \
            | awk '{a[$2]+=$1} END{for(c in a) printf "%d %s\n", a[c], c}' \
            | sort -rn | head -5 \
            | awk '{printf "        %6.1f MB  %s\n", $1/1024, $2}')
        [[ -n "$TOP5" ]] && printf '%s\n' "$TOP5"
        echo -e "        Si el nombre no te suena (ej. xmrig, kinsing, kdevtmpfsi) es un minero."
        echo -e "        Mitigar: Sistema/Recursos -> [9] ZRAM o [4] Swap."
        ADV=1
    fi
    [[ "$DISCO_P" -gt 85 ]]  && { echo -e " ${ROJO}!${NC} Disco al ${DISCO_P}%: correr Sistema -> Mantenimiento y revisar /root/backups."; ADV=1; }
    systemctl is-failed --quiet sshd 2>/dev/null && { echo -e " ${ROJO}!${NC} sshd con fallos: 'systemctl status sshd'."; ADV=1; }
    pgrep -f miniserv >/dev/null 2>&1 || echo -e " ${AMARILLO}-${NC} Webmin no corre (menu Webmin)."
    lastb -i 2>/dev/null | head -5 | grep -q . && echo -e " ${AMARILLO}-${NC} Intentos de login fallidos recientes: conviene Fail2ban (Seguridad -> Fail2ban)."
    [[ $ADV -eq 0 ]] && echo -e " ${VERDE}OK${NC} Sin alertas graves."
    ficha_cerrar
    diagnostico_panel
    PAUSA
}

DG_OK=0; DG_AV=0; DG_MAL=0
dg_ok(){  echo -e " ${VERDE}✔${NC} $*";    DG_OK=$((DG_OK+1)); }
dg_av(){  echo -e " ${AMARILLO}!${NC} $*"; DG_AV=$((DG_AV+1)); }
dg_mal(){ echo -e " ${ROJO}✘${NC} $*";     DG_MAL=$((DG_MAL+1)); }

diagnostico_panel(){
    # Revisa que TODO lo de Ghost Panel este en su version y funcionando (lo que antes se comprobaba a mano).
    DG_OK=0; DG_AV=0; DG_MAL=0
    local HU N T U C P F MIN AGE RAW PAN CORES L5
    ficha_abrir "🧩 GHOST PANEL"

    # --- panel: version e instancia unica
    dg_ok "Panel v${GHOST_VER}"
    HU=$(ps -eo pid=,tty=,args= 2>/dev/null | awk -v me=$$ '$2=="?" && $1!=me && $0 ~ /\/usr\/local\/bin\/(ghostpanel|vps|vpsmgr)( |$)/ {n++} END{print n+0}')
    if (( HU > 0 )); then dg_av "$HU panel(es) huérfano(s): se cierran al abrir otro"
    else dg_ok "Una sola instancia del panel"; fi

    # --- bot de Telegram
    if [[ -f "$BOT_DIR/bot.py" ]]; then
        if grep -q "^BOT_REV = \"${BOT_REV}\"" "$BOT_DIR/bot.py" 2>/dev/null; then dg_ok "Bot al día (rev $BOT_REV)"
        else dg_av "Bot desactualizado: se actualiza al reabrir el panel"; fi
        if systemctl is-active --quiet ghost-bot 2>/dev/null; then dg_ok "Servicio del bot activo"
        else dg_mal "Servicio del bot detenido (Bot Telegram → Iniciar)"; fi
        T=$(bot_conf_get BOT_TOKEN)
        if [[ -n "$T" ]]; then
            U=$(curl -fsS --max-time 4 "https://api.telegram.org/bot${T}/getMe" 2>/dev/null | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [[ -n "$U" ]]; then dg_ok "Telegram responde (@$U)"
            else dg_av "Telegram no responde (token o conexión)"; fi
        else dg_mal "El bot no tiene token configurado"; fi
    else
        dg_ok "Bot de Telegram: no instalado (opción 9)"
    fi

    # --- limiter
    N=$(ls /etc/vps-limits 2>/dev/null | wc -l)
    if [[ -f /usr/local/bin/vps-limiter.sh ]]; then
        grep -q 'GHOST-LIMITER-V2' /usr/local/bin/vps-limiter.sh 2>/dev/null || dg_av "Limiter viejo (se actualiza al reabrir el panel)"
        if systemctl is-active --quiet vps-limiter 2>/dev/null; then dg_ok "Limiter activo (cada $(limiter_intervalo) s, $N con límite)"
        else dg_av "Limiter detenido (Seguridad → Limiter)"; fi
    elif (( N > 0 )); then dg_av "$N usuario(s) con límite pero sin limiter (Seguridad)"
    else dg_ok "Limiter: sin usuarios con límite"; fi

    # --- crones
    if [[ -f /etc/cron.d/ghost-panel-trafico ]]; then
        F=/usr/local/bin/vps-trafico-cron.sh; MIN=$(trafico_auto_min)
        if [[ ! -s "$F" ]]; then dg_mal "Auto-corte activo pero falta $F"
        elif ! bash -n "$F" 2>/dev/null; then dg_mal "Auto-corte: el script tiene errores (reactívalo)"
        elif ! grep -q 'tg_destinos' "$F" 2>/dev/null; then dg_av "Auto-corte sin avisos al bot (se corrige al reabrir)"
        else dg_ok "Auto-corte cada ${MIN:-?} min, con avisos"; fi
    else
        dg_ok "Auto-corte de cuota: apagado"
    fi
    if [[ -f /etc/cron.d/ghost-panel-vencidos ]]; then
        if grep -q 'GHOST-CRON-V2' /usr/local/bin/vps-cron-diario.sh 2>/dev/null; then dg_ok "Cron de vencidos al día"
        else dg_av "Cron de vencidos viejo (se actualiza al reabrir)"; fi
    else
        dg_av "Falta el cron diario de vencidos"
    fi

    # --- checkuser y avisos
    if [[ -f /etc/vps-checkuser.conf ]]; then
        P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
        if systemctl is-active --quiet vps-checkuser 2>/dev/null; then dg_ok "CheckUser activo (puerto ${P:-?})"
        else dg_av "CheckUser detenido (Herramientas → CheckUser)"; fi
    else
        dg_ok "CheckUser: no instalado"
    fi
    C=$(notif_canales_txt)
    if [[ -n "$C" ]]; then dg_ok "Avisos de cuota: $C"
    else dg_av "Sin canal de avisos (Tráfico → Notificaciones)"; fi

    # --- backups y logs
    command -v openssl >/dev/null 2>&1 || dg_av "Falta openssl: el bot no puede cifrar backups"
    F=$(ls -t /root/backups/backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$F" ]]; then
        AGE=$(( ( $(date +%s) - $(stat -c %Y "$F") ) / 86400 ))
        if (( AGE <= 30 )); then dg_ok "Último backup: hace $AGE día(s)"
        else dg_av "Último backup hace $AGE días: conviene uno nuevo"; fi
    else
        dg_av "Sin backups locales (Sistema → Backup)"
    fi
    if [[ -f "$BOT_DIR/bot.py" ]]; then
        if [[ -s "$BOT_DIR/backup.key" && -s "$BOT_KEY_COPIA" ]]; then dg_ok "Clave de backup guardada y respaldada"
        else dg_av "Clave de backup sin copia (abre Bot Telegram)"; fi
    fi
    if [[ -f "$LOGROTATE_CONF" ]]; then dg_ok "Logs con rotación automática"
    elif [[ -d /etc/logrotate.d ]]; then dg_av "Logs sin rotación (se configura al reabrir)"
    else dg_av "logrotate no instalado: los logs crecen sin límite"; fi

    # --- cuentas, auto-menu, licencia y carga
    RAW=$(awk -F: '$3>=1000 && $3<=60000 && $1!="nobody"{n++} END{print n+0}' /etc/passwd)
    PAN=$(usuarios_panel | wc -l)
    dg_ok "$PAN usuario(s) del panel · $(( RAW - PAN )) cuenta(s) protegida(s)"
    if grep -q 'VPS-JB-AUTOMENU-INICIO' /root/.bashrc 2>/dev/null; then
        if grep -q 'GHOST_PANEL_ACTIVO' /root/.bashrc 2>/dev/null; then dg_ok "Auto-menú con protección"
        else dg_av "Auto-menú sin protección (se actualiza al reabrir)"; fi
    fi
    dg_ok "Licencia: ${LICENSE_OK:-?}"
    CORES=$(nproc 2>/dev/null || echo 1); L5=$(awk '{print $2}' /proc/loadavg)
    if awk -v l="$L5" -v c="$CORES" 'BEGIN{exit !(l > c*2)}'; then dg_av "Carga alta: $L5 (5 min, $CORES núcleo(s))"
    else dg_ok "Carga: $L5 (5 min, $CORES núcleo(s))"; fi

    echo -e " ${GRIS}Resumen:${NC} ${VERDE}✔ $DG_OK${NC}  ${AMARILLO}! $DG_AV${NC}  ${ROJO}✘ $DG_MAL${NC}"
    ficha_cerrar
}

cambiar_hostname(){
    echo -e "${CIAN}Hostname actual: ${BLANCO}$(hostname)${NC}"
    read -r -p "Nuevo hostname (sin espacios, ej. vps): " H
    [[ -z "$H" || "$H" =~ [^a-zA-Z0-9.-] ]] && { ERR "Hostname invalido."; PAUSA; return; }
    hostnamectl set-hostname "$H" 2>/dev/null || { ERR "No se pudo cambiar."; PAUSA; return; }
    sed -i "s/127.0.1.1.*/127.0.1.1\t$H/" /etc/hosts 2>/dev/null
    ficha_ok "🏷 HOSTNAME CAMBIADO" "Hostname nuevo" "$H" "Se ve completo" "en la próxima sesión"
    PAUSA
}

ghost_ver_de(){ grep -m1 "^GHOST_VER=" "$1" 2>/dev/null | cut -d"'" -f2; }

ghost_instalar_script(){
    # ghost_instalar_script ARCHIVO -> valida, compara versiones, respalda, instala y relanza.
    # Solo pregunta cuando hay algo que decidir (version nueva, mas vieja, sin version, o archivo distinto con la
    # misma version). Si ya tienes exactamente esa version, avisa y NO pregunta.
    local F="$1" NV CV="$GHOST_VER" DEST="$VPSMGR_DEST" RUN SN BK PREG
    bash -n "$F" 2>/dev/null || { ERR "El archivo no es un script bash valido."; return 1; }
    grep -q "GHOST PANEL" "$F" || { ERR "No parece ser GHOST PANEL."; return 1; }
    NV=$(ghost_ver_de "$F")
    echo -e "  Instalada: ${AMARILLO}v${CV}${NC}    Nueva: ${VERDE}$([[ -n "$NV" ]] && echo "v$NV" || echo "sin version")${NC}"
    if [[ -z "$NV" ]]; then
        WARN "El archivo no declara version: es ANTERIOR al rediseno. Instalarlo pierde la interfaz y los arreglos."
        PREG="  Instalarlo de todos modos? (s/n): "
    elif [[ "$NV" == "$CV" ]]; then
        if [[ -f "$DEST" ]] && cmp -s "$F" "$DEST"; then
            OK "Ya tienes la ultima version (v$CV): no hay nada que actualizar."
            return 0
        fi
        WARN "Es la misma version (v$CV) pero el contenido es distinto al instalado."
        PREG="  Reemplazar el instalado por este archivo? (s/n): "
    elif [[ "$(printf '%s\n%s\n' "$CV" "$NV" | sort -V | tail -1)" == "$CV" ]]; then
        WARN "La nueva (v$NV) es MAS VIEJA que la instalada (v$CV)."
        PREG="  Volver a la version anterior v$NV? (s/n): "
    else
        INFO "Hay una version nueva: v$CV -> v$NV"
        PREG="  Actualizar a v$NV? (s/n): "
    fi
    read -r -p "$PREG" SN
    [[ "$SN" =~ ^[sSyY]$ ]] || { INFO "Cancelado."; return 1; }
    RUN="${GHOST_SELF:-$(readlink -f "$0" 2>/dev/null)}"
    mkdir -p /root/backups; chmod 700 /root/backups
    BK="/root/backups/ghost-panel-v${CV}-$(date +%F_%H%M%S).sh"
    if [[ -n "$RUN" && -f "$RUN" ]]; then cp -a "$RUN" "$BK" 2>/dev/null; fi
    # install borra y recrea el destino: no corrompe el script que bash esta leyendo
    install -m 755 "$F" "$DEST" || { ERR "No se pudo escribir $DEST"; return 1; }
    ficha_abrir "⬆ PANEL ACTUALIZADO" "$VERDE"
    ficha_fila "Versión anterior" "v${CV}"
    ficha_fila "Versión nueva" "v${NV:-?}" "$VERDE"
    ficha_fila "Instalado en" "$DEST"
    if [[ -n "$RUN" && -f "$RUN" && "$RUN" != "$(readlink -f "$DEST")" && -w "$RUN" ]]; then
        install -m 755 "$F" "$RUN" 2>/dev/null && ficha_fila "También actualizado" "$RUN"
    fi
    [[ -n "${BK:-}" && -f "$BK" ]] && ficha_fila "Respaldo" "$BK"
    ficha_cerrar
    vps_log INFO "script actualizado v$CV -> v${NV:-?}"
    read -r -p "  Reiniciar el panel ahora con la version nueva? (s/n): " SN
    [[ "$SN" =~ ^[sSyY]$ ]] && exec "$DEST"
    return 0
}

auto_update_descargar(){
    local TMPF K CODE
    [[ -n "$REPO_RAW" ]] || { ERR "Fuente sin configurar (opcion 2)."; PAUSA; return; }
    command -v curl >/dev/null 2>&1 || { ERR "Falta curl."; PAUSA; return; }
    K=$(tr -d '[:space:]' < "$KEY_FILE" 2>/dev/null)
    [[ -n "$K" ]] || { ERR "No hay key activada: activa tu licencia primero."; PAUSA; return; }
    TMPF=$(mktemp /tmp/vpsmgr.XXXXXX) || { ERR "Sin temporal."; PAUSA; return; }
    INFO "Buscando actualizacion..."
    CODE=$(curl -sS -G --max-time 60 -o "$TMPF" -w '%{http_code}' "$REPO_RAW" \
        --data-urlencode "key=$K" --data-urlencode "id=$(machine_hash)" 2>/dev/null)
    case "$CODE" in
        200) if [[ -s "$TMPF" ]]; then ghost_instalar_script "$TMPF"
             else ERR "El servidor devolvio un archivo vacio."; fi ;;
        403) ERR "Licencia no valida para actualizar (key invalida, vencida o de otra maquina)." ;;
        404) ERR "El servidor no tiene el script publicado. Avisa al administrador." ;;
        *)   ERR "No se pudo descargar (HTTP ${CODE:-sin respuesta}). Revisa la red." ;;
    esac
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
        FR_OPT 2 "Cambiar fuente (URL)" "" ""
        FR_OPT 3 "Instalar desde archivo local" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) auto_update_descargar ;;
            2) read -r -p "  URL del servidor de actualizaciones (https://...): " U
               if [[ "$U" =~ ^https?://[^[:space:]]+$ ]]; then
                   touch /etc/ghost-panel.conf; chmod 600 /etc/ghost-panel.conf
                   sed -i '/^UPDATE_URL=/d' /etc/ghost-panel.conf
                   echo "UPDATE_URL=$U" >> /etc/ghost-panel.conf
                   REPO_RAW="$U"; ficha_ok "🌐 FUENTE GUARDADA" "URL" "$U"
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
    if ! pedir_puerto PORT "Puerto para el checkuser [8080]: " "8080" tcp; then PAUSA; return; fi
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
    ficha_abrir "📡 CHECKUSER INSTALADO"
    ficha_fila "Estado" "corriendo" "$VERDE"
    ficha_fila "Puerto" "$PORT/tcp"
    ficha_fila "Token" "$TOKEN" "$VERDE"
    ficha_fila "Config" "/etc/vps-checkuser.conf"
    ficha_cerrar
    printf '%bDesde la VM:%b\n%s\n' "$GRIS" "$NC" "curl http://localhost:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    printf '%bDesde afuera:%b\n%s\n' "$GRIS" "$NC" "http://$IP:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    PAUSA
}

checkuser_probar(){
    local P T IP
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(ip_publica)
    read -r -p "Usuario a consultar: " U
    ficha_abrir "📡 PRUEBA CHECKUSER · $U"
    curl -s "http://localhost:${P:-8080}/checkuser.php?user=$U&token=$T" && echo || ERR "No responde. Estado:"
    systemctl status vps-checkuser --no-pager 2>/dev/null | head -6
    ficha_cerrar
    PAUSA
}

checkuser_quitar(){
    systemctl disable --now vps-checkuser 2>/dev/null
    rm -f /usr/local/bin/vps-checkuser.py /etc/systemd/system/vps-checkuser.service /etc/vps-checkuser.conf
    systemctl daemon-reload 2>/dev/null
    ficha_ok "📡 CHECKUSER REMOVIDO" "Estado" "desinstalado"
    PAUSA
}

checkuser_rotar_token(){
    # Token nuevo. Es el mismo para los enlaces de TODOS los clientes: los enlaces anteriores dejan de servir.
    [[ -f /etc/vps-checkuser.conf ]] || { ERR "CheckUser no esta instalado."; PAUSA; return; }
    local P NT SN
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    echo -e "  ${AMARILLO}Rotar el token invalida TODOS los enlaces CheckUser que ya tienen tus clientes.${NC}"
    echo "  Tendras que reenviarles el enlace nuevo (el bot lo trae en cada ficha)."
    read -r -p "  ¿Generar un token nuevo? (s/n): " SN
    [[ "$SN" =~ ^[sSyY]$ ]] || { INFO "Cancelado."; PAUSA; return; }
    NT=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 24)
    [[ ${#NT} -ge 16 ]] || { ERR "No se pudo generar el token."; PAUSA; return; }
    printf 'PORT=%s\nTOKEN=%s\n' "${P:-8080}" "$NT" > /etc/vps-checkuser.conf
    chmod 600 /etc/vps-checkuser.conf
    systemctl restart vps-checkuser 2>/dev/null
    vps_log INFO "token de CheckUser rotado"
    ficha_ok "🔑 TOKEN ROTADO" "Token nuevo" "$NT" "Puerto" "${P:-8080}" "Enlaces anteriores" "ya no funcionan"
    PAUSA
}

menu_checkuser(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_cu)"
        FR_OPT 1 "$(T t_cu_inst)" 4 "$(T t_cu_token)"
        FR_OPT 2 "$(T t_estado_svc)" 5 "$(T t_remover)"
        FR_OPT 3 "$(T t_cu_probar)" 6 "🔑 $(T t_cu_rotar)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) checkuser_instalar ;;
            2) ficha_abrir "📡 ESTADO CHECKUSER"; systemctl status vps-checkuser --no-pager 2>/dev/null | head -15; ficha_cerrar; PAUSA ;;
            3) checkuser_probar ;;
            4) if [[ -f /etc/vps-checkuser.conf ]]; then ficha_abrir "📡 CONFIG CHECKUSER"; cat /etc/vps-checkuser.conf; ficha_cerrar; else ERR "No instalado."; fi; PAUSA ;;
            5) checkuser_quitar ;;
            6) checkuser_rotar_token ;;
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
        ficha_ok "🔄 REINICIO" "Estado" "cancelado"
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
    if ! pedir_puerto XP "Puerto para Xray [8443]: " "8443" tcp; then PAUSA; return; fi
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
    ficha_abrir "🚀 XRAY INSTALADO"
    ficha_fila "Estado" "corriendo" "$VERDE"
    ficha_fila "Protocolo" "VLESS + Reality"
    ficha_fila "IP / Host" "$IP"
    ficha_fila "Puerto" "$XP/tcp"
    ficha_fila "SNI" "$SNI"
    ficha_cerrar
    printf '%bEnlace para tu app (VLESS + Reality):%b\n%b%s%b\n' "$AMARILLO" "$NC" "$VERDE" "$LINK" "$NC"
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
    ficha_ok "🔐 OPENVPN INSTALADO" "Archivo cliente" "/root/*.ovpn"
    PAUSA
}

instalar_ssl_stunnel(){
    if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
        read -r -p "Stunnel ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR SSL (STUNNEL) ---${NC}"
    if ! pedir_puerto SP "Puerto SSL [443]: " "443" tcp; then PAUSA; return; fi
    read -r -p "Puerto SSH destino [$(sshd_puerto_actual)]: " SSHP
    SSHP=${SSHP:-$(sshd_puerto_actual)}
    [[ "$SSHP" =~ ^[0-9]+$ && "$SSHP" -ge 1 && "$SSHP" -le 65535 ]] || { ERR "Puerto SSH invalido."; PAUSA; return; }

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
        ficha_abrir "🔒 STUNNEL (SSL) ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "IP / Host" "$IP"
        ficha_fila "Puerto SSL" "$SP/tcp" "$VERDE"
        ficha_fila "Destino SSH local" "127.0.0.1:$SSHP"
        ficha_cerrar
        INFO "La app debe conectar por SSL/TLS al $SP y el tráfico sale por SSH ($SSHP)."
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
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
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
    for U in $(usuarios_panel); do
        iptables -A VPS-TRAFFIC -m owner --uid-owner "$U" -j RETURN 2>/dev/null && N=$((N+1))
    done
    iptables -C OUTPUT -j VPS-TRAFFIC 2>/dev/null || iptables -A OUTPUT -j VPS-TRAFFIC 2>/dev/null
    # Activar Stats API de Xray si existe
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        xray_ensure_api >/dev/null 2>&1 && xray_recargar 2>/dev/null
        INFO "Xray Stats API preparada en 127.0.0.1:10085 (conteo por email de usuario)."
    fi
    if [[ $N -gt 0 ]]; then
        ficha_ok "📶 CONTADORES ACTIVOS" "Usuarios SSH" "$N" "Medición" "iptables por UID (SSH)"
        INFO "iptables solo mide tráfico de procesos del UID (SSH). Xray/WG/etc. se ven aparte si Stats responde."
    else
        ERR "No se pudieron crear reglas (iptables fallo?)."
    fi
    PAUSA
}

fmt_corto(){
    # fmt_corto BYTES -> "512M" o "2.1G" (columnas angostas)
    local b="${1:-0}"
    if (( b < 1073741824 )); then echo "$(( b / 1048576 ))M"
    else printf '%d.%dG\n' $(( b / 1073741824 )) $(( (b * 10 / 1073741824) % 10 )); fi
}

trafico_ver(){
    ficha_abrir "📈 CONSUMO POR USUARIO"
    echo -e "${GRIS}Total = SSH (iptables) + Xray (Stats API). De mayor a menor consumo.${NC}"
    local U USED G P TOT=0 FILAS=()
    trafico_cache_cargar; TRAF_BATCH=1
    (( ${#TRAF_CACHE[@]} == 0 )) && WARN "Sin contadores: activalos en Trafico -> [1]."
    while read -r U; do
        usuario_protegido "$U" && continue
        USED=$(trafico_usuario_bytes "$U")
        G=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-trafico/$U"); G=${G:0:6}
        FILAS+=("$USED|$U|${G:-0}")
        TOT=$(( TOT + USED ))
    done < <(usuarios_panel)
    TRAF_BATCH=0
    printf "%-14s %-9s %-8s %s\n" "USUARIO" "USADO" "CUOTA" "USO"
    if (( ${#FILAS[@]} )); then
        while IFS='|' read -r USED U G; do
            if (( 10#$G > 0 )); then
                P=$(( USED * 100 / (10#$G * 1073741824) ))
                printf "%-14s %-9s %-8s %b %3s%%\n" "$U" "$(fmt_bytes "$USED")" "${G} GB" "$(ui_bar "$P" 8)" "$P"
            else
                printf "%-14s %-9s %-8s %s\n" "$U" "$(fmt_bytes "$USED")" "sin limite" "--"
            fi
        done < <(printf '%s\n' "${FILAS[@]}" | sort -t'|' -k1,1nr)
    fi
    ficha_fila "Total usuarios" "$(fmt_bytes "$TOT")" "$CIAN"
    ficha_cerrar
    INFO "Reset pone a cero los contadores iptables (no borra las stats de Xray)."
    banner_todos_actualizar >/dev/null 2>&1 || true   # deja los banners con el consumo actual
    PAUSA
}

trafico_limite(){
    local USU G
    pedir_usuario_ok USU || { PAUSA; return; }
    read -r -p "Limite en GB (0 = sin limite): " G
    [[ "$G" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    mkdir -p /etc/vps-trafico
    echo "$G" > "/etc/vps-trafico/$USU"
    banner_usuario_actualizar "$USU"   # el banner refleja el nuevo limite
    ficha_ok "🚦 LÍMITE DE TRÁFICO" "Usuario" "$USU" "Límite" "$([[ "$G" == 0 ]] && echo "sin límite" || echo "${G} GB")"
    PAUSA
}

trafico_excedido(){
    # trafico_excedido USUARIO -> 0 (verdadero) si tiene cuota en GB y ya la supero.
    # Usa trafico_usuario_bytes (SSH + Xray): la misma cifra que muestran el banner y "Ver consumo".
    local G
    G=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-trafico/$1"); G=${G:0:6}
    [[ -n "$G" ]] && (( 10#$G > 0 )) || return 1
    (( $(trafico_usuario_bytes "$1") >= 10#$G * 1073741824 ))
}

trafico_marcar_cuota(){
    # Marca al usuario como bloqueado por cuota (archivo de estado + log)
    mkdir -p /etc/vps-cuota-agotada
    echo "$(date +%s)|$2" > "/etc/vps-cuota-agotada/$1" 2>/dev/null
    chmod 600 "/etc/vps-cuota-agotada/$1" 2>/dev/null || true
}

trafico_limpiar_marca_cuota(){
    rm -f "/etc/vps-cuota-agotada/$1" 2>/dev/null
}

trafico_esta_por_cuota(){
    [[ -f "/etc/vps-cuota-agotada/$1" ]]
}

# ---- Notificaciones (Telegram / Discord / WhatsApp CallMeBot) ----
notif_enviar(){
    # notif_enviar "mensaje"
    local MSG="$1" URL TOKEN CHAT HOOK PHONE APIKEY
    # Telegram: el manual (TG_TOKEN/TG_CHAT) y/o el Bot instalado (opcion 9), sin repetir si son el mismo destino
    while read -r TOKEN CHAT; do
        [[ -n "$TOKEN" && -n "$CHAT" ]] || continue
        curl -fsS --max-time 8 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
            -d "chat_id=${CHAT}" --data-urlencode "text=${MSG}" -d "parse_mode=HTML" >/dev/null 2>&1 </dev/null || true
    done < <(tg_destinos)
    # Discord webhook
    HOOK=$(ghost_conf_get DISCORD_HOOK)
    if [[ -n "$HOOK" ]]; then
        curl -fsS --max-time 8 -H "Content-Type: application/json" \
            -d "{\"content\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MSG")}" \
            "$HOOK" >/dev/null 2>&1 || true
    fi
    # WhatsApp via CallMeBot (phone=54911...&apikey=...)
    PHONE=$(ghost_conf_get WA_PHONE)
    APIKEY=$(ghost_conf_get WA_APIKEY)
    if [[ -n "$PHONE" && -n "$APIKEY" ]]; then
        curl -fsS --max-time 8 --get "https://api.callmebot.com/whatsapp.php" \
            --data-urlencode "phone=${PHONE}" --data-urlencode "apikey=${APIKEY}" \
            --data-urlencode "text=${MSG}" >/dev/null 2>&1 || true
    fi
}

# ============================================================
# 🤖 BOT DE TELEGRAM (integrado en Ghost Panel 3.11.0)
# El bot vive en /opt/ghost-bot (venv + bot.py + config.env) y corre como
# servicio systemd "ghost-bot". Las acciones del panel notifican al admin
# con bot_notificar(). El chat del bot siempre se EDITA (nunca mensajes nuevos).
# ============================================================
BOT_DIR='/opt/ghost-bot'
BOT_KEY_COPIA='/root/.ghost-panel/ghost-bot-backup.key'   # copia de la clave de backup: sobrevive a desinstalar el bot

bot_conf_get(){
    # bot_conf_get CLAVE -> valor de /opt/ghost-bot/config.env (sin romper por '=')
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$BOT_DIR/config.env" 2>/dev/null
}

tg_destinos(){
    # tg_destinos -> una linea "TOKEN CHAT" por destino de Telegram: el manual (ghost-panel.conf) y el del
    # Bot instalado (/opt/ghost-bot/config.env). Si son el mismo, sale una sola vez.
    local T C BT BC
    T=$(ghost_conf_get TG_TOKEN); C=$(ghost_conf_get TG_CHAT)
    BT=$(bot_conf_get BOT_TOKEN); BC=$(bot_conf_get ADMIN_CHAT_ID)
    [[ -n "$T" && -n "$C" ]] && printf '%s %s\n' "$T" "$C"
    [[ -n "$BT" && -n "$BC" ]] && { [[ "$BT" != "$T" || "$BC" != "$C" ]] && printf '%s %s\n' "$BT" "$BC"; }
    return 0
}

tg_estado(){
    # tg_estado -> bot | manual | ambos | ninguno
    local T C BT BC
    T=$(ghost_conf_get TG_TOKEN); C=$(ghost_conf_get TG_CHAT)
    BT=$(bot_conf_get BOT_TOKEN); BC=$(bot_conf_get ADMIN_CHAT_ID)
    if [[ -n "$BT" && -n "$BC" ]]; then
        if [[ -n "$T" && -n "$C" && ( "$T" != "$BT" || "$C" != "$BC" ) ]]; then echo ambos; else echo bot; fi
    elif [[ -n "$T" && -n "$C" ]]; then echo manual
    else echo ninguno; fi
}

tg_estado_txt(){
    case "$(tg_estado)" in
        bot)    echo "Bot instalado (chat $(bot_conf_get ADMIN_CHAT_ID))" ;;
        ambos)  echo "Bot instalado + manual (chat $(ghost_conf_get TG_CHAT))" ;;
        manual) echo "Manual (chat $(ghost_conf_get TG_CHAT))" ;;
        *)      echo "(sin configurar)" ;;
    esac
}

notif_canales_txt(){
    # canales con destino configurado, separados por coma (vacio = ninguno)
    local R=""
    case "$(tg_estado)" in
        bot) R="Telegram (bot instalado)" ;; ambos) R="Telegram (bot + manual)" ;; manual) R="Telegram" ;;
    esac
    [[ -n "$(ghost_conf_get DISCORD_HOOK)" ]] && R+="${R:+, }Discord"
    [[ -n "$(ghost_conf_get WA_PHONE)" && -n "$(ghost_conf_get WA_APIKEY)" ]] && R+="${R:+, }WhatsApp"
    printf '%s' "$R"
}

bot_notificar(){
    # bot_notificar "mensaje HTML" -> notifica al admin por el Bot de Telegram.
    # Silencioso si el bot no esta instalado. La llaman las funciones del panel.
    local BTK BCH
    [[ -r "$BOT_DIR/config.env" ]] || return 0
    BTK=$(bot_conf_get BOT_TOKEN)
    BCH=$(bot_conf_get ADMIN_CHAT_ID)
    [[ -n "$BTK" && -n "$BCH" ]] || return 0
    curl -fsS --max-time 8 -X POST "https://api.telegram.org/bot${BTK}/sendMessage" \
        -d "chat_id=${BCH}" --data-urlencode "text=$1" -d "parse_mode=HTML" >/dev/null 2>&1 || true
    return 0
}

bot_detectar_chat(){
    # bot_detectar_chat TOKEN -> escucha getUpdates ~30 s y devuelve el chat_id del
    # primero que le escriba al bot (para no tener que buscar el chat_id a mano).
    local RESP CID i
    for i in 1 2 3 4 5 6; do
        RESP=$(curl -sS --max-time 6 "https://api.telegram.org/bot${1}/getUpdates" 2>/dev/null)
        CID=$(printf '%s' "$RESP" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    for u in reversed(d.get("result",[])):
        for k in ("message","edited_message","channel_post"):
            if k in u and isinstance(u[k],dict) and "chat" in u[k]:
                print(u[k]["chat"]["id"]); sys.exit(0)
except Exception:
    pass
' 2>/dev/null)
        [[ -n "$CID" ]] && { printf '%s' "$CID"; return 0; }
        sleep 5
    done
    return 1
}

bot_refresh_helper(){
    # Genera /opt/ghost-bot/panel-refresh.sh con funciones REALES del panel (declare -f),
    # misma tecnica de trafico_cron_instalar: asi el bot regenera los banners de los
    # usuarios EXACTAMENTE igual que el panel (banner por usuario + bloques Match de sshd).
    # Se regenera en cada arranque del panel (y al instalar/reinstalar el bot).
    local FN
    mkdir -p "$BOT_DIR"
    {
        echo '#!/bin/bash'
        echo '# Generado por Ghost Panel (bot_refresh_helper). No editar: se regenera solo.'
        echo 'export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin LC_ALL=C.UTF-8'
        declare -p BANNERS_DIR LOG_PANEL PROTEGIDOS_NOMBRES SSHD_CFG
        echo 'declare -A TRAF_CACHE=(); TRAF_BATCH=0'
        for FN in vps_log usuario_protegido ui_rep ui_fit ui_cw OK ERR fmt_bytes fmt_corto \
                  xray_stats_todos trafico_cache_cargar trafico_usuario_bytes \
                  usuario_fecha_cuenta dias_hasta ghost_conf_get ip_publica \
                  banner_barra banner_seg banner_sep banner_hora banner_l_gruesa banner_l_fina \
                  banner_p banner_fila banner_soporte_txt banner_soporte_fila \
                  banner_html_para_usuario banner_usuario_actualizar \
                  banner_rebuild_match sshd_recargar; do
            declare -f "$FN"
        done
        echo 'case "$1" in'
        echo '  user)    [[ -n "$2" ]] && banner_usuario_actualizar "$2"; banner_rebuild_match ;;'
        echo '  del)     rm -f "$BANNERS_DIR/$2"; banner_rebuild_match ;;'
        echo '  rebuild) banner_rebuild_match ;;'
        echo 'esac'
    } > "$BOT_DIR/panel-refresh.sh" 2>/dev/null
    chmod 700 "$BOT_DIR/panel-refresh.sh" 2>/dev/null || true
    return 0
}

BOT_REV='4.2'   # revision del bot.py embebido (debe coincidir con BOT_REV dentro de bot.py)

bot_autoactualizar(){
    # Si el bot ya esta instalado con un bot.py de otra revision, lo regenera solo (sin pedir token ni
    # reinstalar). Si el codigo nuevo no compila, restaura el anterior. Solo reinicia si estaba habilitado.
    [[ -f "$BOT_DIR/bot.py" && -f /etc/systemd/system/ghost-bot.service ]] || return 0
    grep -q "^BOT_REV = \"$BOT_REV\"" "$BOT_DIR/bot.py" 2>/dev/null && return 0
    cp -f "$BOT_DIR/bot.py" "$BOT_DIR/bot.py.bak" 2>/dev/null
    bot_telegram_escribir_py
    if ! python3 -m py_compile "$BOT_DIR/bot.py" 2>/dev/null; then
        mv -f "$BOT_DIR/bot.py.bak" "$BOT_DIR/bot.py" 2>/dev/null
        return 0
    fi
    rm -f "$BOT_DIR/bot.py.bak"
    bot_refresh_helper
    systemctl is-enabled --quiet ghost-bot 2>/dev/null && systemctl restart ghost-bot >/dev/null 2>&1
    vps_log INFO "bot actualizado a la revision $BOT_REV" 2>/dev/null
    return 0
}

bot_telegram_escribir_py(){
    bot_backup_key_asegurar
    # Genera /opt/ghost-bot/bot.py (el codigo del bot). Heredoc literal: sin expansion.
    mkdir -p "$BOT_DIR"
    cat > "$BOT_DIR/bot.py" <<'PYBOTGHOST'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
👻 GHOST PANEL · Bot de Telegram para administrar usuarios SSH
==============================================================
Generado por Ghost Panel (función bot_telegram_escribir_py). Revisión: ver BOT_REV.
NO editar a mano: se regenera al reinstalar el bot desde el panel
(Bot Telegram -> Instalar / Configurar).

REGLA DE ORO · CHAT SIEMPRE LIMPIO:
  - Al tocar un botón se EDITA la misma "pantalla" (nunca mensajes nuevos).
  - Mensaje nuevo solo en /start, en alertas automáticas y al enviar un backup.
  - Los textos que el admin escribe se BORRAN para no ensuciar el chat.

TODO CON BOTONES:
  - Menú con barras de RAM / CPU / disco.
  - Ficha por usuario (renovar, bloquear, clave, límites, enviar datos, eliminar).
  - Conectados ahora (con botón para desconectar), límites, test SSH de 1 día.
  - Alertas automáticas (resumen diario, por vencer, RAM/CPU/disco) cada 5 min.
  - Servidor: reiniciar servicios, puertos, logs, backup y reinicio de la VPS.
"""

import asyncio
import datetime
import functools
import html
import json
import logging
import os
import pwd
import re
import secrets
import shutil
import string
import subprocess
import sys
import time
import uuid

try:
    from zoneinfo import ZoneInfo
except ImportError:  # Python < 3.9
    ZoneInfo = None

BOT_REV = "4.2"   # el panel compara esto para actualizar el bot solo

if not hasattr(asyncio, "to_thread"):          # Python 3.8 (Ubuntu 20.04)
    async def _to_thread(fn, *a, **k):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, functools.partial(fn, *a, **k))
    asyncio.to_thread = _to_thread

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.error import BadRequest
from telegram.ext import (Application, CallbackQueryHandler, CommandHandler,
                          ContextTypes, MessageHandler, filters)

# ------------------------- CONSTANTES -------------------------
BOT_DIR = "/opt/ghost-bot"
CONF_FILE = os.path.join(BOT_DIR, "config.env")
ALERTS_FILE = os.path.join(BOT_DIR, "alerts.json")
CLAVES_FILE = os.path.join(BOT_DIR, "claves.json")      # OBSOLETO: ya no se escribe; se elimina al arrancar
BACKUP_KEY = os.path.join(BOT_DIR, "backup.key")        # clave para CIFRAR los backups (solo en el servidor)
REBOOT_FLAG = os.path.join(BOT_DIR, "reboot.flag")
LOG_FILE = "/var/log/ghost-bot.log"
REFRESH_SH = os.path.join(BOT_DIR, "panel-refresh.sh")   # banners: generado por el panel
PANEL_CONF = "/etc/ghost-panel.conf"
XRAY_CFG = "/usr/local/etc/xray/config.json"
XRAY_BIN = "/usr/local/bin/xray"
CHECKUSER_CONF = "/etc/vps-checkuser.conf"
BACKUP_DIR = "/root/backups"
TIMEOUT_FLOW = 300      # 5 minutos sin responder -> se cancela el flujo
PAGE = 8                # usuarios por página en la lista
ALERT_EVERY = 300       # chequeo de alertas cada 5 minutos
GB = 1073741824
TG_MAX_FILE = 49 * 1024 * 1024   # límite de subida de los bots de Telegram (~50 MB)

# Usuarios protegidos del sistema (espejo de PROTEGIDOS_NOMBRES del panel)
PROTEGIDOS = {
    "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
    "uucp", "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody",
    "systemd-network", "systemd-resolve", "systemd-timesync", "syslog",
    "messagebus", "_apt", "uuidd", "tcpdump", "sshd", "landscape", "pollinate",
    "ubuntu", "debian", "admin", "ec2-user", "cloud-user", "vpsmgr",
    "ghostpanel", "dnstt",
    "opc", "oracle", "azureuser", "fedora", "centos", "rocky", "almalinux", "vagrant", "pi",
}
ADMIN_GRUPOS = ("sudo", "wheel", "admin")     # quien pertenece a estos grupos es admin del sistema, no cliente
NAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")

# Logs que se pueden ver desde Servidor -> Logs
LOGS = {
    "bot": ("🤖 Bot", "/var/log/ghost-bot.log"),
    "panel": ("👻 Panel", "/var/log/ghost-panel.log"),
    "xray": ("🛰 Xray", "journal:xray"),
    "ssh": ("🔐 SSH", "journal:ssh"),
    "lim": ("🚦 Limiter", "journal:vps-limiter"),
}

# ------------------------- LOG -------------------------
try:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()],
    )
except OSError:  # sin permiso de escritura (no deberia pasar: corre como root)
    logging.basicConfig(level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)   # sus URLs llevan el token
log = logging.getLogger("ghost-bot")

ENV = dict(os.environ, LC_ALL="C", LANG="C")

# ------------------------- CONFIG -------------------------
def load_conf():
    d = {}
    try:
        with open(CONF_FILE, encoding="utf-8") as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k:
                    d[k] = v
    except OSError:
        pass
    return d

CONF = load_conf()
BOT_TOKEN = CONF.get("BOT_TOKEN", "").strip()
ADMIN_ID = str(CONF.get("ADMIN_CHAT_ID", "")).strip()

def _int_conf(key, default):
    try:
        return int(CONF.get(key, default))
    except (TypeError, ValueError):
        return default

TEST_DIAS = max(1, _int_conf("TEST_DIAS", 1))   # test SSH: días de validez
TEST_CONX = max(0, _int_conf("TEST_CONX", 1))   # test SSH: conexiones
TEST_GB = max(0, _int_conf("TEST_GB", 1))       # test SSH: GB (0 = sin límite)

def panel_conf_get(key):
    try:
        with open(PANEL_CONF, encoding="utf-8") as f:
            for line in f:
                k, _, v = line.rstrip("\n").partition("=")
                if k == key:
                    return v
    except OSError:
        pass
    return ""

def soporte_txt():
    """Contacto de soporte del panel (/etc/ghost-panel.conf SUPPORT; «NONE» = sin soporte)."""
    s = (panel_conf_get("SUPPORT") or "@JorgeBarrios").strip()
    return "" if s.upper() == "NONE" else s

# ------------------------- JSON (alertas / claves) -------------------------
def jload(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, type(default)) else default
    except (OSError, ValueError):
        return default

def jsave(path, data):
    """Guarda JSON con permisos 600 (escritura atómica)."""
    tmp = path + ".tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
        os.replace(tmp, path)
        return True
    except OSError:
        return False

ALERTS_DEF = {
    "daily": True, "hour": 21,          # resumen diario
    "venc": True, "dias_aviso": 3,      # aviso de vencimiento
    "res": True, "umbral": 85,          # RAM / CPU / disco
    "last_daily": "", "venc_avisado": {},
}

def alerts_get():
    d = dict(ALERTS_DEF)
    d.update(jload(ALERTS_FILE, {}))
    if not isinstance(d.get("venc_avisado"), dict):
        d["venc_avisado"] = {}
    return d

def alerts_set(**kw):
    d = alerts_get()
    d.update(kw)
    jsave(ALERTS_FILE, d)
    return d

# ------------------------- SEGURIDAD: contraseñas y backups -------------------------
def purgar_claves_antiguas():
    """Las versiones 3.12.0/3.12.1 guardaban en claves.json las contraseñas que el bot fijaba (texto plano).
    Ya no se guardan: si ese archivo existe se sobrescribe con ceros y se borra."""
    try:
        if os.path.isfile(CLAVES_FILE):
            n = os.path.getsize(CLAVES_FILE)
            with open(CLAVES_FILE, "r+b") as fh:
                fh.write(b"\0" * n)
                fh.flush()
                os.fsync(fh.fileno())
            os.remove(CLAVES_FILE)
            log.warning("claves.json (contraseñas en texto plano) eliminado de forma segura")
    except OSError as e:
        log.error("no se pudo eliminar claves.json: %s", e)

def backup_key():
    """Clave que CIFRA el backup antes de mandarlo a Telegram. Vive solo en el servidor (0600);
    se consulta en el panel: Bot Telegram -> Ver token y admin. Nunca se manda por Telegram."""
    k = ""
    try:
        with open(BACKUP_KEY, "r", encoding="utf-8") as fh:
            k = fh.readline().strip()
    except OSError:
        pass
    if len(k) < 16:
        alfabeto = string.ascii_letters + string.digits
        k = "".join(secrets.choice(alfabeto) for _ in range(24))
        fd = os.open(BACKUP_KEY, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(k + "\n")
    return k

def cifrar_backup(src):
    """AES-256-CBC + PBKDF2 (openssl). Devuelve (ok, ruta_cifrada | mensaje_de_error)."""
    if not shutil.which("openssl"):
        return False, "openssl no está instalado (apt install openssl)."
    backup_key()
    dst = src + ".enc"
    r = sh("openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-salt",
           "-in", src, "-out", dst, "-pass", "file:" + BACKUP_KEY, timeout=300)
    if r.returncode != 0 or not os.path.isfile(dst) or os.path.getsize(dst) == 0:
        try:
            os.remove(dst)
        except OSError:
            pass
        return False, "No se pudo cifrar: %s" % (r.stderr.strip()[:150] or "openssl falló")
    try:
        os.chmod(dst, 0o600)
    except OSError:
        pass
    return True, dst

# ------------------------- SUBPROCESOS -------------------------
def sh(*args, inp=None, timeout=20):
    """Ejecuta un comando y devuelve CompletedProcess (nunca lanza)."""
    try:
        return subprocess.run(args, capture_output=True, text=True, input=inp,
                              env=ENV, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")
    except (OSError, ValueError) as e:
        return subprocess.CompletedProcess(args, 1, "", str(e))

def uid_of(name):
    try:
        return pwd.getpwnam(name).pw_uid
    except KeyError:
        return None

def _uid_rango():
    """(UID_MIN, UID_MAX) de /etc/login.defs; por defecto 1000-60000 (snapd-range-* usa uids enormes)."""
    mn, mx = 1000, 60000
    try:
        with open("/etc/login.defs", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.split()
                if len(p) == 2 and p[1].isdigit():
                    if p[0] == "UID_MIN":
                        mn = max(1000, int(p[1]))
                    elif p[0] == "UID_MAX":
                        mx = min(60000, int(p[1]))
    except OSError:
        pass
    return mn, mx

UID_MIN, UID_MAX = _uid_rango()

def admins_sistema():
    """Miembros de sudo/wheel/admin (p. ej. opc, tu acceso SSH): nunca se tratan como usuarios del panel."""
    s = set()
    try:
        with open("/etc/group", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split(":")
                if len(p) >= 4 and p[0] in ADMIN_GRUPOS:
                    s.update(x for x in p[3].split(",") if x)
    except OSError:
        pass
    return s

def user_exists(name):
    uid = uid_of(name)
    return uid is not None and UID_MIN <= uid <= UID_MAX

def is_protegido(name, admins=None):
    if name in PROTEGIDOS or name.startswith(("snapd-", "systemd-")):
        return True
    return name in (admins_sistema() if admins is None else admins)

def panel_users():
    """Usuarios REALES del panel (uid en rango, no nobody, no protegidos, no admins del sistema), ordenados."""
    out = []
    adm = admins_sistema()
    try:
        with open("/etc/passwd", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.split(":")
                if (len(p) >= 3 and p[2].isdigit() and UID_MIN <= int(p[2]) <= UID_MAX
                        and p[0] != "nobody" and not is_protegido(p[0], adm)):
                    out.append(p[0])
    except OSError:
        pass
    return sorted(out)

def shadow_map():
    """usuario -> (bloqueado, expira_en_dias_epoch|None). Una lectura de /etc/shadow."""
    m = {}
    try:
        with open("/etc/shadow", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split(":")
                if len(p) >= 8:
                    exp = int(p[7]) if p[7].lstrip("-").isdigit() and int(p[7]) >= 0 else None
                    m[p[0]] = (p[1].startswith("!"), exp)
    except OSError:
        pass
    return m

EPOCH = datetime.date(1970, 1, 1)

def exp_iso(exp):
    if exp is None:
        return None
    try:
        return (EPOCH + datetime.timedelta(days=exp)).isoformat()
    except (OverflowError, ValueError):
        return None

def dias_desde_exp(exp):
    if exp is None:
        return None
    try:
        return (EPOCH + datetime.timedelta(days=exp) - datetime.date.today()).days
    except (OverflowError, ValueError):
        return None

def account_expiry_iso(name):
    """Vencimiento de la CUENTA como YYYY-MM-DD o None si no vence."""
    return exp_iso(shadow_map().get(name, (False, None))[1])

def days_hasta(iso_date):
    try:
        d = datetime.date.fromisoformat(iso_date)
    except (TypeError, ValueError):
        return 0
    return (d - datetime.date.today()).days

def dias_txt(d):
    if d is None:
        return "sin vencimiento"
    if d < 0:
        return "venció hace %d día%s" % (-d, "" if d == -1 else "s")
    if d == 0:
        return "vence hoy"
    return "%d día%s" % (d, "" if d == 1 else "s")

def dias_corto(d):
    """Texto corto para botones y avisos: hoy / mañana / 5d."""
    return "hoy" if d == 0 else ("mañana" if d == 1 else "%dd" % d)

def sesiones_map():
    """usuario -> nº de sesiones sshd/dropbear. UNA sola pasada de ps."""
    m = {}
    r = sh("ps", "-eo", "user:32=,comm=")
    for line in r.stdout.splitlines():
        p = line.split()
        if len(p) >= 2 and p[1] in ("sshd", "dropbear"):
            m[p[0]] = m.get(p[0], 0) + 1
    return m

def read_file(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default

def write_file(path, content):
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    except OSError:
        return False

def solo_digitos(path):
    v = "".join(ch for ch in read_file(path) if ch.isdigit())[:6]
    return int(v) if v else 0

def lim_conex(name):
    return solo_digitos("/etc/vps-limits/" + name)   # 0 = sin limite

def lim_gb(name):
    return solo_digitos("/etc/vps-trafico/" + name)  # 0 = sin limite

def cuota_agotada(name):
    return os.path.isfile("/etc/vps-cuota-agotada/" + name)

def fmt_bytes(b):
    b = int(b or 0)
    if b < GB:
        return "%d MB" % (b // 1048576)
    c = b * 100 // GB
    return "%d.%02d GB" % (c // 100, c % 100)

def fmt_uso(b, g):
    """'1.2 / 10 GB' · '300 MB / 10 GB' · '1.2 GB (sin límite)'."""
    b = int(b or 0)
    if g > 0:
        if b >= GB:
            return "%.1f / %d GB" % (b / GB, g)
        return "%d MB / %d GB" % (b // 1048576, g)
    return "%s (sin límite)" % fmt_bytes(b)

def trafico_mapa():
    """usuario -> bytes usados (SSH via iptables + Xray via API de stats)."""
    m = {}
    r = sh("iptables", "-L", "VPS-TRAFFIC", "-v", "-x", "-n")
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if "owner UID match" not in line:
                continue
            parts = line.split()
            try:
                b, uid = int(parts[1]), int(parts[-1])
            except (IndexError, ValueError):
                continue
            try:
                u = pwd.getpwuid(uid).pw_name
            except KeyError:
                continue
            m[u] = m.get(u, 0) + b
    if os.path.isfile(XRAY_BIN):
        r = sh(XRAY_BIN, "api", "statsquery", "--server=127.0.0.1:10085", timeout=6)
        data = None
        if r.stdout.strip()[:1] in ("{", "["):
            try:
                data = json.loads(r.stdout)
            except json.JSONDecodeError:
                data = None
        if isinstance(data, dict):
            for s in data.get("stat") or []:
                mo = re.match(r"user>>>([^>]+)>>>traffic>>>(uplink|downlink)$",
                              s.get("name", ""))
                if mo:
                    m[mo.group(1)] = m.get(mo.group(1), 0) + int(s.get("value") or 0)
    return m

# ------------------------- MÉTRICAS DEL SERVIDOR (sin subprocesos) -------------------------
def mem_info():
    """(usado_MB, total_MB, %). Usado = total - disponible (cuenta la caché como libre)."""
    tot = av = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    tot = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    av = int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    used = max(0, tot - av)
    return used // 1024, tot // 1024, (used * 100 // tot) if tot else 0

def disk_info(path="/"):
    """(usado_bytes, total_bytes, %) como df."""
    try:
        st = os.statvfs(path)
    except OSError:
        return 0, 0, 0
    tot = st.f_blocks * st.f_frsize
    used = (st.f_blocks - st.f_bfree) * st.f_frsize
    avail = st.f_bavail * st.f_frsize
    den = used + avail
    return used, tot, (int((used * 100 + den - 1) // den) if den else 0)

def _cpu_vals():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    return sum(v), v[3] + (v[4] if len(v) > 4 else 0)

def cpu_pct(intervalo=0.4):
    """% de CPU en una ventana corta. Bloquea 'intervalo' s (llamar en un hilo)."""
    try:
        t1, i1 = _cpu_vals()
        time.sleep(intervalo)
        t2, i2 = _cpu_vals()
        if t2 > t1:
            return max(0, min(100, 100 * ((t2 - t1) - (i2 - i1)) // (t2 - t1)))
    except (OSError, ValueError, IndexError):
        pass
    return 0

def uptime_txt():
    try:
        up = int(float(read_file("/proc/uptime", "0").split()[0] or 0))
    except (ValueError, IndexError):
        up = 0
    if up >= 86400:
        return "%dd %dh" % (up // 86400, (up % 86400) // 3600)
    if up >= 3600:
        return "%dh %dm" % (up // 3600, (up % 3600) // 60)
    return "%dm" % (up // 60)

def barra8(pct):
    pct = max(0, min(100, int(pct or 0)))
    f = (pct * 8 + 50) // 100
    return "▰" * f + "▱" * (8 - f)

def barra10(pct, seg=10):
    pct = max(0, min(100, int(pct or 0)))
    f = (pct * seg + 50) // 100
    return "█" * f + "░" * (seg - f)

def bloque_salud():
    """Bloque <pre> con barras de RAM, CPU y disco + uptime."""
    _, _, rp = mem_info()
    cp = cpu_pct()
    _, _, dp = disk_info()
    return ("<pre>RAM   %s %3d%%\n"
            "CPU   %s %3d%%\n"
            "Disco %s %3d%%   ⏱ %s</pre>"
            % (barra8(rp), rp, barra8(cp), cp, barra8(dp), dp, uptime_txt()))

def top_procesos(clave="rss", n=3):
    """Top n procesos por memoria (MB) o CPU (%), agrupados por nombre."""
    r = sh("ps", "-eo", "comm=,%s=" % ("rss" if clave == "rss" else "pcpu"),
           "--sort=-%s" % ("rss" if clave == "rss" else "pcpu"))
    ag = {}
    for line in r.stdout.splitlines()[:400]:
        p = line.rsplit(None, 1)
        if len(p) != 2:
            continue
        try:
            v = float(p[1])
        except ValueError:
            continue
        ag[p[0]] = ag.get(p[0], 0.0) + v
    top = sorted(ag.items(), key=lambda x: x[1], reverse=True)[:n]
    if clave == "rss":
        return ["%s %d MB" % (k, v // 1024) for k, v in top]
    return ["%s %.0f%%" % (k, v) for k, v in top]

# ------------------------- NEGOCIO -------------------------
_IP_CACHE = {"ip": "", "ts": 0.0}

def ip_publica():
    if _IP_CACHE["ip"] and time.time() - _IP_CACHE["ts"] < 600:
        return _IP_CACHE["ip"]
    r = sh("curl", "-4", "-fsS", "--max-time", "3", "ifconfig.me", timeout=6)
    ip = r.stdout.strip()
    if not ip:
        r = sh("hostname", "-I")
        parts = r.stdout.split()
        ip = parts[0] if parts else "?"
    _IP_CACHE.update(ip=ip, ts=time.time())
    return ip

def ssh_puerto():
    r = sh("sshd", "-T")
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if line.startswith("port "):
                return line.split()[1]
    return "22"

def checkuser_enlace(usuario):
    if not os.path.isfile(CHECKUSER_CONF):
        return ""
    port, tok = "8080", ""
    try:
        with open(CHECKUSER_CONF, encoding="utf-8") as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k == "PORT":
                    port = v
                elif k == "TOKEN":
                    tok = v
    except OSError:
        return ""
    return "http://%s:%s/checkuser.php?user=%s&token=%s" % (ip_publica(), port, usuario, tok)

def resumen_negocio(mapa=None):
    """dict: n, on, ven (0-3 días), bloq, traf (texto), mapa."""
    us = panel_users()
    shd = shadow_map()
    ses = sesiones_map()
    ven = bloq = on = 0
    for u in us:
        lk, exp = shd.get(u, (False, None))
        if lk:
            bloq += 1
        d = dias_desde_exp(exp)
        if d is not None and 0 <= d <= 3:
            ven += 1
        if ses.get(u):
            on += 1
    if mapa is None:
        mapa = trafico_mapa()
    # el total suma SOLO a los usuarios del panel (no a cuentas ajenas con contador, p. ej. tu SSH de admin)
    total = sum(mapa[u] for u in us if u in mapa) if mapa else 0
    return {"n": len(us), "on": on, "ven": ven, "bloq": bloq, "mapa": mapa,
            "traf": "--" if not mapa else fmt_bytes(total)}

def info_usuario(u, shd=None, ses=None, mapa=None):
    shd = shadow_map() if shd is None else shd
    ses = sesiones_map() if ses is None else ses
    mapa = trafico_mapa() if mapa is None else mapa
    lk, exp = shd.get(u, (False, None))
    d = dias_desde_exp(exp)
    cuota = cuota_agotada(u)
    if cuota:
        est = ("🔴", "CUOTA AGOTADA")
    elif lk:
        est = ("🔴", "BLOQUEADO")
    elif d is not None and d < 0:
        est = ("🔴", "VENCIDO")
    elif d is not None and d <= 3:
        est = ("⏳", "POR VENCER")
    else:
        est = ("🟢", "ACTIVO")
    return {"u": u, "locked": lk, "cuota": cuota, "iso": exp_iso(exp), "dias": d,
            "on": ses.get(u, 0), "lc": lim_conex(u), "gb": lim_gb(u),
            "used": mapa.get(u, 0), "emoji": est[0], "estado": est[1]}

# ------------------------- UI TELEGRAM -------------------------
def esc(s):
    return html.escape(str(s), quote=False)

def kb(rows):
    return InlineKeyboardMarkup(
        [[InlineKeyboardButton(t, callback_data=d[:64]) for t, d in fila] for fila in rows]
    )

KB_CANCELAR = [[("❌ Cancelar", "cancel")]]

MENU_ROWS = [
    [("➕ Crear", "cr"), ("📋 Usuarios", "ul|0")],
    [("🟢 Conectados", "on"), ("📈 Tráfico", "tr")],
    [("🛠 Servidor", "srv"), ("🔔 Alertas", "alr")],
    [("🔄 Actualizar", "menu")],
]

LINEA = "━━━━━━━━━━━━━━━━━━━━"

def menu_text():
    s = resumen_negocio()
    return (
        "👻 <b>GHOST PANEL · Bot Admin</b>\n"
        + LINEA + "\n"
        "👥 %d usuario%s · 🟢 %d online\n"
        "⏳ %d por vencer · 🚫 %d bloqueado%s\n"
        "📈 Tráfico: %s\n\n"
        % (s["n"], "" if s["n"] == 1 else "s", s["on"], s["ven"], s["bloq"],
           "" if s["bloq"] == 1 else "s", esc(s["traf"]))
        + bloque_salud()
    )

def scr_menu():
    return menu_text(), MENU_ROWS

def scr_error(detalle, rows=None):
    return ("❌ <b>ERROR</b>\n" + LINEA + "\n<code>%s</code>" % esc(detalle)[:300],
            rows or [[("🔙 Menú", "menu")]])

# ------------------------- ACCIONES (espejo de las funciones del panel) -------------------------
def refresh_banner(modo, usuario=None):
    """Regenera banners con el helper generado por el panel (panel-refresh.sh)."""
    if os.path.isfile(REFRESH_SH):
        if modo == "user" and usuario:
            sh("bash", REFRESH_SH, "user", usuario)
        elif modo == "del" and usuario:
            sh("bash", REFRESH_SH, "del", usuario)
        else:
            sh("bash", REFRESH_SH, "rebuild")

def xray_reiniciar():
    if sh("systemctl", "is-active", "--quiet", "xray").returncode == 0:
        sh("systemctl", "restart", "xray")
    elif os.path.isfile(XRAY_BIN):
        sh("pkill", "-x", "xray")
        try:
            subprocess.Popen([XRAY_BIN, "run", "-c", XRAY_CFG],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError:
            pass

def xray_add(usuario):
    """Espejo de xray_usuario add: crea uuid/trojan y agrega el cliente a config.json."""
    meta_p = "/etc/vps-users/" + usuario
    meta = {}
    for line in read_file(meta_p).splitlines():
        k, _, v = line.partition("=")
        if k:
            meta[k] = v
    meta.setdefault("uuid", str(uuid.uuid4()))
    meta.setdefault("trojan", secrets.token_hex(10))
    os.makedirs("/etc/vps-users", exist_ok=True)
    write_file(meta_p, "".join("%s=%s\n" % (k, v) for k, v in meta.items()))
    try:
        os.chmod(meta_p, 0o600)
    except OSError:
        pass
    if not os.path.isfile(XRAY_CFG):
        return
    try:
        with open(XRAY_CFG, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return
    for ib in cfg.get("inbounds", []):
        proto = ib.get("protocol")
        st = ib.setdefault("settings", {})
        clients = st.setdefault("clients", [])
        if proto in ("vless", "vmess"):
            clients[:] = [c for c in clients
                          if c.get("email") != usuario and c.get("id") != meta["uuid"]]
            entry = {"id": meta["uuid"], "email": usuario}
            if proto == "vless" and ib.get("streamSettings", {}).get("security") == "reality":
                entry["flow"] = "xtls-rprx-vision"
            clients.append(entry)
        elif proto == "trojan":
            clients[:] = [c for c in clients
                          if c.get("email") != usuario and c.get("password") != meta["trojan"]]
            clients.append({"password": meta["trojan"], "email": usuario})
    try:
        with open(XRAY_CFG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
    except OSError:
        return
    xray_reiniciar()

def xray_del(usuario):
    """Espejo de xray_usuario del."""
    meta_p = "/etc/vps-users/" + usuario
    uid = trojan = ""
    for line in read_file(meta_p).splitlines():
        k, _, v = line.partition("=")
        if k == "uuid":
            uid = v
        elif k == "trojan":
            trojan = v
    if os.path.isfile(XRAY_CFG):
        try:
            with open(XRAY_CFG, encoding="utf-8") as f:
                cfg = json.load(f)
            for ib in cfg.get("inbounds", []):
                proto = ib.get("protocol")
                clients = ib.get("settings", {}).get("clients", [])
                if proto in ("vless", "vmess"):
                    ib["settings"]["clients"] = [c for c in clients
                                                 if c.get("id") != uid and c.get("email") != usuario]
                elif proto == "trojan":
                    ib["settings"]["clients"] = [c for c in clients
                                                 if c.get("password") != trojan and c.get("email") != usuario]
            with open(XRAY_CFG, "w", encoding="utf-8") as f:
                json.dump(cfg, f, indent=2)
        except (OSError, ValueError):
            pass
    try:
        os.remove(meta_p)
    except OSError:
        pass
    xray_reiniciar()

def xray_reset_stats(usuario):
    """Pone a cero los contadores de Xray del usuario (mejor esfuerzo)."""
    if os.path.isfile(XRAY_BIN):
        sh(XRAY_BIN, "api", "statsquery", "--server=127.0.0.1:10085",
           "-pattern", "user>>>%s>>>" % usuario, "-reset", timeout=6)

def iptables_reset_uid(usuario):
    """Espejo del panel: borra y recrea la regla del UID (contador a cero)."""
    uid = uid_of(usuario)
    if uid is None or sh("iptables", "-L", "VPS-TRAFFIC", "-n").returncode != 0:
        return
    while sh("iptables", "-D", "VPS-TRAFFIC", "-m", "owner",
             "--uid-owner", str(uid), "-j", "RETURN").returncode == 0:
        pass
    sh("iptables", "-A", "VPS-TRAFFIC", "-m", "owner",
       "--uid-owner", str(uid), "-j", "RETURN")

def validar_usuario_flow(usuario):
    """Valida el nombre para CREAR. Devuelve mensaje de error o '' si ok."""
    if not usuario:
        return "Nombre vacío. Escribí el nombre (letras minúsculas, números, - y _)."
    if not NAME_RE.match(usuario):
        return "Nombre inválido: minúsculas, números, - y _; máx 32; empieza con letra."
    if is_protegido(usuario):
        return "Ese nombre está reservado del sistema."
    if user_exists(usuario):
        return "El usuario ya existe."
    return ""

def usuario_valido_existente(usuario):
    if not usuario:
        return "Nombre vacío."
    if is_protegido(usuario):
        return "Usuario protegido del sistema."
    if not user_exists(usuario):
        return "El usuario no existe."
    return ""

def gen_clave(n=12):
    alfabeto = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alfabeto) for _ in range(n))

def nombre_libre(prefijo):
    for _ in range(50):
        n = "%s%04d" % (prefijo, secrets.randbelow(10000))
        if not validar_usuario_flow(n):
            return n
    return "%s%d" % (prefijo, int(time.time()) % 100000)

def accion_crear(u, dias, maxc, gbk, clave):
    """Crea el usuario. Devuelve (ok, expiso|msg_error). Espejo de crear_usuario."""
    if not (isinstance(dias, int) and 1 <= dias <= 99999):
        return False, "Días inválidos (entero >= 1)."
    if not (isinstance(maxc, int) and 0 <= maxc <= 999999):
        return False, "Límite de conexiones inválido."
    if not (isinstance(gbk, int) and 0 <= gbk <= 999999):
        return False, "Límite de tráfico inválido."
    if not clave:
        return False, "Contraseña vacía."
    err = validar_usuario_flow(u)
    if err:
        return False, err
    r = sh("useradd", "-m", "-s", "/bin/bash", u)
    if r.returncode != 0:
        return False, "useradd: " + (r.stderr.strip() or "no se pudo crear")
    r = sh("chpasswd", inp="%s:%s\n" % (u, clave))
    if r.returncode != 0:
        sh("userdel", "-r", u)
        return False, "chpasswd: " + (r.stderr.strip() or "no se pudo fijar la contraseña")
    expiso = (datetime.date.today() + datetime.timedelta(days=dias)).isoformat()
    sh("chage", "-M", "99999", "-E", expiso, u)
    os.makedirs("/etc/vps-limits", exist_ok=True)
    write_file("/etc/vps-limits/" + u, "%d\n" % maxc)
    os.makedirs("/etc/vps-plan", exist_ok=True)
    write_file("/etc/vps-plan/" + u, "%d\n" % dias)
    if gbk > 0:
        os.makedirs("/etc/vps-trafico", exist_ok=True)
        write_file("/etc/vps-trafico/" + u, "%d\n" % gbk)
    else:
        try:
            os.remove("/etc/vps-trafico/" + u)
        except OSError:
            pass
    iptables_reset_uid(u)
    xray_add(u)
    refresh_banner("user", u)
    log.info("usuario creado via bot: %s (%dd, conx %d, %s)", u, dias, maxc,
             ("%d GB" % gbk) if gbk > 0 else "sin limite")
    return True, expiso

def accion_renovar(u, dias):
    """Espejo de renovar_usuario. Devuelve (ok, expiso|msg)."""
    if not (isinstance(dias, int) and 1 <= dias <= 99999):
        return False, "Días inválidos (entero >= 1)."
    act = account_expiry_iso(u)
    base = datetime.date.today()
    if act:
        try:
            d = datetime.date.fromisoformat(act)
            if d > base:
                base = d
        except ValueError:
            pass
    expiso = (base + datetime.timedelta(days=dias)).isoformat()
    r = sh("chage", "-M", "99999", "-E", expiso, u)
    if r.returncode != 0:
        return False, "chage falló: " + (r.stderr.strip() or "?")
    os.makedirs("/etc/vps-plan", exist_ok=True)
    write_file("/etc/vps-plan/" + u, "%d\n" % max(0, days_hasta(expiso)))
    refresh_banner("user", u)
    log.info("renovado via bot: %s hasta %s (+%dd)", u, expiso, dias)
    return True, expiso

def accion_eliminar(u, borrar_home=True):
    """Espejo de purgar_usuario. Devuelve (ok, msg)."""
    sh("pkill", "-KILL", "-u", u)
    xray_del(u)
    uid = uid_of(u)
    if uid is not None:
        while sh("iptables", "-D", "VPS-TRAFFIC", "-m", "owner",
                 "--uid-owner", str(uid), "-j", "RETURN").returncode == 0:
            pass
    for f in ("/etc/vps-limits/", "/etc/vps-trafico/", "/etc/vps-users/",
              "/etc/vps-banners/", "/etc/vps-plan/", "/etc/vps-cuota-agotada/"):
        try:
            os.remove(f + u)
        except OSError:
            pass
    r = sh("userdel", "-r", u) if borrar_home else sh("userdel", u)
    if r.returncode != 0 and not borrar_home:
        r = sh("userdel", "-r", u)
    refresh_banner("rebuild")
    ok = uid_of(u) is None
    if ok:
        log.info("usuario eliminado via bot: %s", u)
    return ok, "" if ok else "userdel falló: " + (r.stderr.strip() or "?")

def accion_bloquear(u):
    """Alterna bloqueo (espejo de bloquear_usuario). Devuelve (bloqueado, ok)."""
    estado = sh("passwd", "-S", u).stdout.split()
    ya_lock = len(estado) > 1 and estado[1].startswith("L")
    if ya_lock:
        sh("usermod", "-U", u)
        log.info("desbloqueado via bot: %s", u)
        return False, True
    sh("usermod", "-L", u)
    sh("pkill", "-KILL", "-u", u)
    log.info("bloqueado via bot: %s", u)
    return True, True

def accion_clave(u, clave):
    if not clave or len(clave) < 4:
        return False, "Contraseña demasiado corta (mínimo 4)."
    r = sh("chpasswd", inp="%s:%s\n" % (u, clave))
    if r.returncode != 0:
        return False, "chpasswd falló."
    log.info("clave cambiada via bot: %s", u)
    return True, ""

def accion_kick(u):
    """Desconecta TODAS las sesiones del usuario. Devuelve cuántas tenía."""
    n = sesiones_map().get(u, 0)
    sh("pkill", "-KILL", "-u", u)
    log.info("desconectado via bot: %s (%d sesiones)", u, n)
    return n

def accion_limite_conex(u, n):
    if not (isinstance(n, int) and 0 <= n <= 999999):
        return False, "Valor inválido."
    os.makedirs("/etc/vps-limits", exist_ok=True)
    write_file("/etc/vps-limits/" + u, "%d\n" % n)
    refresh_banner("user", u)
    log.info("limite conexiones via bot: %s = %d", u, n)
    return True, ""

def accion_limite_gb(u, g):
    if not (isinstance(g, int) and 0 <= g <= 999999):
        return False, "Valor inválido."
    if g > 0:
        os.makedirs("/etc/vps-trafico", exist_ok=True)
        write_file("/etc/vps-trafico/" + u, "%d\n" % g)
    else:
        try:
            os.remove("/etc/vps-trafico/" + u)
        except OSError:
            pass
    refresh_banner("user", u)
    log.info("limite GB via bot: %s = %d", u, g)
    return True, ""

def accion_reset_contador(u):
    iptables_reset_uid(u)
    xray_reset_stats(u)
    refresh_banner("user", u)
    log.info("contador reseteado via bot: %s", u)

def accion_desbloquear_cuota(u):
    """Espejo de trafico_desbloquear_cuota: desbloquea + Xray + contador a cero."""
    sh("usermod", "-U", u)
    try:
        os.remove("/etc/vps-cuota-agotada/" + u)
    except OSError:
        pass
    xray_add(u)
    iptables_reset_uid(u)
    xray_reset_stats(u)
    refresh_banner("user", u)
    refresh_banner("rebuild")
    log.info("desbloqueado por cuota via bot: %s", u)

# ------------------------- DATOS / FICHAS DE TEXTO -------------------------
ICONOS = {"Usuario": "👤", "Contraseña": "🔑", "IP": "🌍", "Puerto SSH": "🔌", "Vence": "📅", "Soporte": "🆘",
          "Conexiones": "📶", "Tráfico": "📦", "Sesiones": "🔌", "Cuota": "📦", "Usado": "📈",
          "Validez": "⏳", "Agregado": "➕"}

def tabla(filas):
    """Líneas «Etiqueta: valor» con cada VALOR en <code>: un toque copia ese dato solo.
    No depende de que la letra sea monoespaciada (en algunos Telegram el bloque <pre> sale desalineado)."""
    return "\n".join("%s%s: <code>%s</code>"
                     % ((ICONOS[k] + " ") if k in ICONOS else "", esc(k), esc(v)) for k, v in filas)

def copiar_bloque(filas):
    """Bloque <pre> compacto «Etiqueta: valor» (sin relleno): un toque copia TODO para pegárselo al cliente."""
    return ("📋 <b>Copiar todo para el cliente</b>\n<pre>%s</pre>"
            % esc("\n".join("%s: %s" % (k, v) for k, v in filas)))

def checkuser_bloque(u):
    """Enlace CheckUser en su propia línea (tocarlo lo copia completo)."""
    link = checkuser_enlace(u)
    return ("\n\n🔗 <b>CheckUser</b>\n<code>%s</code>" % esc(link)) if link else ""

def datos_filas(u, clave, iso):
    """Filas (etiqueta, valor) del cliente. clave=None -> sin fila de contraseña (no se guarda en ningún lado)."""
    d = days_hasta(iso) if iso else None
    cx = lim_conex(u)
    g = lim_gb(u)
    filas = [("Usuario", u)]
    if clave:
        filas.append(("Contraseña", clave))
    filas += [("IP", ip_publica()), ("Puerto SSH", ssh_puerto())]
    if iso:
        filas.append(("Vence", "%s · %s" % (iso, dias_txt(d))))
    filas.append(("Conexiones", str(cx) if cx > 0 else "sin límite"))
    filas.append(("Tráfico", ("%d GB" % g) if g > 0 else "sin límite"))
    sop = soporte_txt()
    if sop:
        filas.append(("Soporte", sop))          # termina los datos del cliente con tu contacto
    return filas

def bloque_datos(u, clave, iso, con_checkuser=False):
    return tabla(datos_filas(u, clave, iso))

def ficha_creada(u, clave, dias, maxc, gbk, expiso, test=False):
    titulo = "🧪 <b>TEST SSH CREADO</b>" if test else "👻 <b>USUARIO CREADO</b>"
    return (titulo + "\n" + LINEA + "\n"
            + bloque_datos(u, clave, expiso)
            + "\n🟢 <b>ACTIVO</b> · creado %s\n" % datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
            + "<i>Tocá un dato para copiarlo solo.</i>\n\n"
            + copiar_bloque(datos_filas(u, clave, expiso))
            + checkuser_bloque(u))

# ------------------------- PANTALLAS (devuelven (texto, filas)) -------------------------
def scr_lista(page=0, filtro=""):
    us = panel_users()
    if filtro:
        us = [u for u in us if filtro.lower() in u.lower()]
    if not us:
        txt = ("📋 <b>USUARIOS</b>\n<i>%s</i>"
               % ("Sin resultados para «%s»." % esc(filtro) if filtro else "No hay usuarios del panel."))
        return txt, [[("🔎 Buscar", "sr"), ("➕ Crear", "cr")], [("🔙 Menú", "menu")]]
    shd, ses, mapa = shadow_map(), sesiones_map(), trafico_mapa()
    total = len(us)
    pages = (total + PAGE - 1) // PAGE
    page = max(0, min(page, pages - 1))
    btns = []
    for u in us[page * PAGE:(page + 1) * PAGE]:
        i = info_usuario(u, shd, ses, mapa)
        extra = (" · " + dias_corto(i["dias"])) if (i["dias"] is not None and i["dias"] >= 0) else ""
        btns.append(("%s %s%s" % (i["emoji"], u, extra), "u|" + u))
    rows = [btns[i:i + 2] for i in range(0, len(btns), 2)]
    sufijo = ("|" + filtro[:30]) if filtro else ""
    if pages > 1:
        nav = []
        if page > 0:
            nav.append(("⬅", "ul|%d%s" % (page - 1, sufijo)))
        nav.append(("%d/%d" % (page + 1, pages), "noop"))
        if page < pages - 1:
            nav.append(("➡", "ul|%d%s" % (page + 1, sufijo)))
        rows.append(nav)
    rows.append([("🔎 Buscar", "sr"), ("➕ Crear", "cr")])
    rows.append([("🔄 Actualizar", "ul|%d%s" % (page, sufijo)), ("🔙 Menú", "menu")])
    txt = ("📋 <b>USUARIOS (%d)</b>%s\n" % (total, (" · «%s»" % esc(filtro)) if filtro else "")
           + "🟢 activo · ⏳ por vencer · 🔴 bloqueado/vencido\n"
           "<i>Tocá un usuario para abrir su ficha.</i>")
    return txt, rows

def scr_ficha(u, pre=""):
    i = info_usuario(u)
    vence = ("%s · %s" % (i["iso"], dias_txt(i["dias"]))) if i["iso"] else "sin vencimiento"
    cx = ("%d/%s" % (i["on"], i["lc"] if i["lc"] > 0 else "∞"))
    txt = (pre
           + "👤 <b>%s</b> · %s %s\n" % (esc(u), i["emoji"], i["estado"])
           + tabla([("Vence", vence), ("Sesiones", cx), ("Tráfico", fmt_uso(i["used"], i["gb"]))]))
    if i["cuota"]:
        lock_btn = ("🚦 Desbloq. cuota", "lim|" + u)
    elif i["locked"]:
        lock_btn = ("🔓 Desbloquear", "blk|" + u)
    else:
        lock_btn = ("🔒 Bloquear", "blk|" + u)
    rows = []
    if i["on"]:
        rows.append([("⛔ Desconectar (%d)" % i["on"], "kick|" + u)])
    rows += [
        [("🔄 Renovar", "rnm|" + u), lock_btn],
        [("🔑 Clave", "clv|" + u), ("🚦 Límites", "lim|" + u)],
        [("📤 Enviar datos", "snd|" + u), ("❌ Eliminar", "dl|" + u)],
        [("⬅ Usuarios", "ul|0")],
    ]
    return txt, rows

def scr_conectados(pre=""):
    ses = sesiones_map()
    us = [u for u in panel_users() if ses.get(u)]
    rows = []
    if not us:
        txt = pre + "🟢 <b>CONECTADOS AHORA</b>\n" + LINEA + "\n<i>Nadie conectado.</i>"
    else:
        lineas = []
        for u in us[:40]:
            lc = lim_conex(u)
            n = ses[u]
            warn = " ⚠️" if (lc > 0 and n > lc) else ""
            lineas.append("🟢 %s · %d/%s sesión%s%s" % (u, n, lc if lc > 0 else "∞",
                                                       "" if n == 1 else "es", warn))
        txt = (pre + "🟢 <b>CONECTADOS AHORA (%d)</b>\n" % len(us) + LINEA + "\n"
               "<pre>%s</pre>" % esc("\n".join(lineas)))
        for u in us[:12]:
            rows.append([("👤 %s (%d)" % (u, ses[u]), "u|" + u),
                         ("⛔ Desconectar", "kick|%s|on" % u)])
        if len(us) > 12:
            txt += "\n<i>Botones para los primeros 12.</i>"
    rows.append([("🔄 Actualizar", "on"), ("🔙 Menú", "menu")])
    return txt, rows

def scr_trafico():
    mapa = trafico_mapa()
    if not mapa:
        return ("📈 <b>TRÁFICO</b>\n"
                "<i>Sin contadores activos. Activalos en el panel: Tráfico → Activar conteo.</i>",
                [[("🔄 Actualizar", "tr")], [("🔙 Menú", "menu")]])
    us = sorted((u for u in panel_users() if u in mapa), key=lambda x: mapa[x], reverse=True)
    filas = []
    for u in us[:30]:
        used = mapa[u]
        g = lim_gb(u)
        if g > 0:
            pct = min(100, used * 100 // (g * GB))
            filas.append("%-14s %9s / %3d GB %3d%% %s" % (u, fmt_bytes(used), g, pct, barra10(pct, 8)))
        else:
            filas.append("%-14s %9s / sin límite" % (u, fmt_bytes(used)))
    total = sum(mapa[u] for u in us)     # solo usuarios del panel: coincide con la suma de las filas
    txt = ("📈 <b>TRÁFICO POR USUARIO (SSH + Xray)</b>\n<pre>%s</pre>\n"
           "Total: <b>%s</b>" % (esc("\n".join(filas)), esc(fmt_bytes(total))))
    btns = [("👤 " + u, "u|" + u) for u in us[:6]]
    rows = [btns[i:i + 2] for i in range(0, len(btns), 2)]
    rows.append([("🔄 Actualizar", "tr"), ("🔙 Menú", "menu")])
    return txt, rows

def scr_crear():
    return ("➕ <b>CREAR USUARIO</b>\n" + LINEA + "\n"
            "🧪 <b>Test SSH</b>: %d día%s · %s conexión%s · %s, un toque.\n"
            "👤 <b>Usuario completo</b>: elegís días, conexiones, GB y clave."
            % (TEST_DIAS, "" if TEST_DIAS == 1 else "s",
               TEST_CONX if TEST_CONX > 0 else "∞", "" if TEST_CONX == 1 else "es",
               ("%d GB" % TEST_GB) if TEST_GB > 0 else "sin límite"),
            [[("🧪 Test SSH (1 toque)", "cr|test")],
             [("👤 Usuario completo", "cr|full")],
             [("🔙 Menú", "menu")]])

def scr_renovar(u):
    i = info_usuario(u)
    return ("🔄 <b>RENOVAR · %s</b>\n" % esc(u)
            + ("📅 Vence %s (%s)\n" % (i["iso"], dias_txt(i["dias"])) if i["iso"] else "")
            + "Elegí los <b>días a agregar</b>:",
            [[("7", "rn|7|" + u), ("15", "rn|15|" + u), ("30", "rn|30|" + u)],
             [("60", "rn|60|" + u), ("90", "rn|90|" + u), ("✍️ Otro", "rn|c|" + u)],
             [("⬅ Ficha", "u|" + u)]])

def scr_clave(u):
    return ("🔑 <b>CLAVE · %s</b>\nElegí cómo definir la nueva contraseña:" % esc(u),
            [[("🎲 Generar", "clc|" + u), ("✍️ Escribir", "clm|" + u)],
             [("⬅ Ficha", "u|" + u)]])

def scr_limites(u, pre=""):
    i = info_usuario(u)
    pct = ("%d%%" % min(100, i["used"] * 100 // (i["gb"] * GB))) if i["gb"] > 0 else "—"
    txt = (pre + "🚦 <b>LÍMITES · %s</b>\n" % esc(u) + LINEA + "\n"
           + tabla([("Conexiones", "%s máx (ahora %d)" % (i["lc"] if i["lc"] > 0 else "∞", i["on"])),
                    ("Cuota", ("%d GB" % i["gb"]) if i["gb"] > 0 else "sin límite"),
                    ("Usado", "%s (%s)" % (fmt_bytes(i["used"]), pct))]))
    if i["cuota"]:
        txt += "\n🚫 <b>Cuota agotada</b>: tocá «Desbloquear por cuota»."

    def lab(v, cur, pref=""):
        return ("✔" if v == cur else pref) + ("♾" if v == 0 else str(v))
    rows = [
        [(lab(v, i["lc"], "🔌" if v == 1 else ""), "lmc|%d|%s" % (v, u)) for v in (1, 2, 3, 5, 0)],
        [(lab(v, i["gb"], "📦" if v == 10 else ""), "lmg|%d|%s" % (v, u)) for v in (10, 30, 50, 100, 0)],
        [("✍️ Otro GB", "lmx|" + u), ("🔄 Resetear contador", "lmr|" + u)],
    ]
    if i["cuota"] or (i["locked"] and i["gb"] > 0 and i["used"] >= i["gb"] * GB):
        rows.append([("🔓 Desbloquear por cuota", "lmu|" + u)])
    rows.append([("⬅ Ficha", "u|" + u)])
    return txt, rows

def scr_confirmar_clave(u, accion):
    """Cambiar la clave corta el acceso del cliente hasta que reciba la nueva: pide confirmación."""
    return ("⚠️ <b>CAMBIAR CLAVE · %s</b>\n" % esc(u) + LINEA + "\n"
            "Se genera una contraseña nueva y <b>la actual deja de funcionar</b>: el cliente no podrá "
            "conectarse hasta que le envíes la nueva.",
            [[("✅ Sí, cambiar clave", "%s|%s" % (accion, u))], [("❌ Cancelar", "u|" + u)]])

def scr_enviar(u, pre=""):
    iso = account_expiry_iso(u)
    txt = (pre + "📤 <b>DATOS PARA ENVIAR · %s</b>\n" % esc(u) + LINEA + "\n"
           + bloque_datos(u, None, iso)
           + "\n🔒 <i>La contraseña no se guarda en ningún lado (Linux solo guarda su hash). "
             "Para enviarla, generá una nueva: la anterior deja de funcionar.</i>"
           + checkuser_bloque(u))
    rows = [[("🎲 Nueva clave y enviar", "snc|" + u)], [("⬅ Ficha", "u|" + u)]]
    return txt, rows

def scr_eliminar(u):
    i = info_usuario(u)
    return ("⚠️ <b>CONFIRMAR ELIMINACIÓN</b>\n" + LINEA + "\n"
            "👤 <code>%s</code> · %s %s\n"
            "📅 %s\n\n"
            "Se borran: cuenta SSH, cliente Xray, límites, tráfico y banner. <b>No se puede deshacer.</b>"
            % (esc(u), i["emoji"], i["estado"], esc(i["iso"] or "sin vencimiento")),
            [[("✅ Sí, eliminar", "dly|" + u)], [("❌ Cancelar", "u|" + u)]])

# ------------------------- SERVIDOR -------------------------
def svc_activo(nombre):
    return sh("systemctl", "is-active", "--quiet", nombre).returncode == 0

def estado_servicios():
    partes = []
    if os.path.isfile(XRAY_BIN):
        partes.append("Xray %s" % ("🟢" if (svc_activo("xray") or sh("pgrep", "-x", "xray").returncode == 0) else "🔴"))
    partes.append("SSH %s" % ("🟢" if (svc_activo("ssh") or svc_activo("sshd")) else "🔴"))
    if os.path.isfile("/etc/systemd/system/vps-limiter.service"):
        partes.append("Limiter %s" % ("🟢" if svc_activo("vps-limiter") else "🔴"))
    partes.append("Bot 🟢")
    return " · ".join(partes)

def scr_servidor(pre=""):
    txt = (pre + "🛠 <b>SERVIDOR</b>\n" + LINEA + "\n"
           "🌍 IP <code>%s</code> · 🔌 SSH <code>%s</code>\n"
           "%s\n\n"
           % (esc(ip_publica()), esc(ssh_puerto()), estado_servicios())
           + bloque_salud())
    reinicios = []
    if os.path.isfile(XRAY_BIN):                         # sin Xray instalado, el botón no tiene sentido
        reinicios.append(("♻️ Xray", "srv|xray"))
    reinicios += [("♻️ SSH", "srv|ssh"), ("♻️ Limiter", "srv|lim")]
    rows = [
        reinicios,
        [("🔌 Puertos", "srv|ports"), ("📜 Logs", "srv|logs")],
        [("💾 Backup", "srv|bk"), ("📊 Detalle", "srv|st")],
        [("⚠️ Reiniciar VPS", "rb1")],
        [("🔄 Actualizar", "srv"), ("🔙 Menú", "menu")],
    ]
    return txt, rows

def scr_detalle():
    ru, rt, rp = mem_info()
    du, dt, dp = disk_info()
    cp = cpu_pct()
    try:
        carga = os.getloadavg()
        carga_txt = "%.2f %.2f %.2f" % carga
    except OSError:
        carga_txt = "?"
    s = resumen_negocio()
    txt = ("📊 <b>ESTADO DEL VPS</b>\n" + LINEA + "\n"
           "🌍 IP: <code>%s</code>\n"
           "🔌 Puerto SSH: <code>%s</code>\n"
           "⏱ Uptime: %s\n"
           "⚙️ Carga: %s\n"
           "💾 RAM: %d M / %d M  %s %d%%\n"
           "🧠 CPU: %s %d%%\n"
           "🗄 Disco: %s / %s  %s %d%%\n"
           "👥 Usuarios: %d  |  🟢 Online: %d\n"
           "⏳ Por vencer: %d  |  🚫 Bloqueados: %d"
           % (esc(ip_publica()), esc(ssh_puerto()), esc(uptime_txt()), esc(carga_txt),
              ru, rt, barra10(rp), rp, barra10(cp), cp,
              esc(fmt_bytes(du)), esc(fmt_bytes(dt)), barra10(dp), dp,
              s["n"], s["on"], s["ven"], s["bloq"]))
    return txt, [[("🔄 Actualizar", "srv|st")], [("⬅ Servidor", "srv"), ("🔙 Menú", "menu")]]

def svc_restart(clave):
    """Reinicia un servicio. Devuelve (ok, mensaje)."""
    if clave == "xray":
        if not os.path.isfile(XRAY_BIN):
            return False, "Xray no está instalado."
        xray_reiniciar()
        time.sleep(1.5)
        ok = svc_activo("xray") or sh("pgrep", "-x", "xray").returncode == 0
        return ok, "Xray reiniciado" if ok else "Xray no levantó (revisá Logs → Xray)"
    if clave == "ssh":
        t = sh("sshd", "-t")
        if t.returncode != 0:
            return False, "sshd -t falló, NO se reinició: " + (t.stderr.strip()[:150] or "?")
        r = sh("systemctl", "restart", "ssh")
        if r.returncode != 0:
            r = sh("systemctl", "restart", "sshd")
        time.sleep(1)
        ok = svc_activo("ssh") or svc_activo("sshd")
        return ok, "SSH reiniciado (las sesiones abiertas siguen)" if ok else "SSH no levantó"
    if clave == "lim":
        if not os.path.isfile("/etc/systemd/system/vps-limiter.service"):
            return False, "El limiter no está instalado."
        sh("systemctl", "restart", "vps-limiter")
        time.sleep(1)
        ok = svc_activo("vps-limiter")
        return ok, "Limiter reiniciado" if ok else "El limiter no levantó"
    return False, "Servicio desconocido."

def scr_puertos():
    r = sh("ss", "-H", "-tuln", "-p")
    vistos, filas = set(), []
    for line in r.stdout.splitlines():
        p = line.split()
        if len(p) < 5:
            continue
        proto, local = p[0], p[4]
        mo = re.search(r'\(\("([^"]+)"', line)
        proc = mo.group(1) if mo else "-"
        clave = (proto, local.rsplit(":", 1)[-1], proc)
        if clave in vistos:
            continue
        vistos.add(clave)
        filas.append((proto, local, proc))
    filas.sort(key=lambda x: (x[0], int(x[1].rsplit(":", 1)[-1]) if x[1].rsplit(":", 1)[-1].isdigit() else 0))
    cuerpo = "\n".join("%-4s %-22s %s" % f for f in filas[:40]) or "(sin datos)"
    return ("🔌 <b>PUERTOS EN ESCUCHA</b>\n<pre>%s</pre>" % esc(cuerpo),
            [[("🔄 Actualizar", "srv|ports")], [("⬅ Servidor", "srv"), ("🔙 Menú", "menu")]])

def scr_logs_menu():
    btns = [(n, "log|" + k) for k, (n, _) in LOGS.items()]
    rows = [btns[i:i + 3] for i in range(0, len(btns), 3)]
    rows.append([("⬅ Servidor", "srv")])
    return "📜 <b>LOGS</b>\nElegí cuál ver (últimas líneas):", rows

def scr_log(clave):
    if clave not in LOGS:
        return scr_logs_menu()
    nombre, src = LOGS[clave]
    if src.startswith("journal:"):
        unidad = src[8:]
        r = sh("journalctl", "-u", unidad, "-n", "25", "--no-pager", "-o", "short")
        out = r.stdout
        if not out.strip() and unidad == "ssh":
            out = sh("journalctl", "-u", "sshd", "-n", "25", "--no-pager", "-o", "short").stdout
    else:
        out = sh("tail", "-n", "25", src).stdout
    out = out.strip() or "(vacío)"
    if len(out) > 3300:
        out = "…" + out[-3300:]
    return ("📜 <b>LOG · %s</b>\n<pre>%s</pre>" % (nombre, esc(out)),
            [[("🔄 Actualizar", "log|" + clave)], [("⬅ Logs", "srv|logs"), ("🔙 Menú", "menu")]])

def hacer_backup():
    """Crea el .tar.gz (igual que el panel). Devuelve (ok, ruta|msg, tamaño_bytes)."""
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        os.chmod(BACKUP_DIR, 0o700)
    except OSError as e:
        return False, "No se pudo crear %s: %s" % (BACKUP_DIR, e), 0
    fn = os.path.join(BACKUP_DIR, "backup-bot-%s.tar.gz" % datetime.datetime.now().strftime("%Y-%m-%d_%H%M"))
    sh("bash", "-c", "dpkg --get-selections > /root/paquetes.txt 2>/dev/null")
    r = sh("tar", "czf", fn, "--exclude=etc/ssl/private", "/etc", "/root/paquetes.txt", timeout=300)
    if r.returncode > 1 or not os.path.isfile(fn) or os.path.getsize(fn) == 0:
        try:
            os.remove(fn)
        except OSError:
            pass
        return False, "tar falló (código %d): %s" % (r.returncode, r.stderr.strip()[:150]), 0
    try:
        os.chmod(fn, 0o600)
    except OSError:
        pass
    # conserva solo los 5 backups más nuevos creados por el bot
    try:
        viejos = sorted(f for f in os.listdir(BACKUP_DIR)
                        if f.startswith("backup-bot-") and f.endswith(".tar.gz"))
        for f in viejos[:-5]:
            os.remove(os.path.join(BACKUP_DIR, f))
    except OSError:
        pass
    return True, fn, os.path.getsize(fn)

def scr_reiniciar1():
    ses = sesiones_map()
    return ("♻️ <b>REINICIAR LA VPS</b>\n" + LINEA + "\n"
            "Se cortan <b>todas las conexiones</b> (%d sesiones ahora) y el servidor "
            "queda fuera de línea ~1-2 minutos.\n"
            "El bot te avisa cuando vuelva." % sum(ses.values()),
            [[("⚠️ Continuar", "rb2")], [("❌ Cancelar", "srv")]])

def scr_reiniciar2():
    return ("🚨 <b>ÚLTIMA CONFIRMACIÓN</b>\n" + LINEA + "\n"
            "¿Reiniciar la VPS <b>AHORA</b>?\n<i>Este botón vale 60 segundos.</i>",
            [[("♻️ SÍ, REINICIAR AHORA", "rb3|%d" % int(time.time()))],
             [("❌ Cancelar", "srv")]])

# ------------------------- ALERTAS -------------------------
def tz_panel():
    v = panel_conf_get("TZ_VISTA")
    if v and v != "VPS" and ZoneInfo is not None:
        try:
            return ZoneInfo(v)
        except Exception:
            return None
    return None

def ahora():
    tz = tz_panel()
    return datetime.datetime.now(tz) if tz else datetime.datetime.now()

def tz_label():
    v = panel_conf_get("TZ_VISTA")
    if v and v != "VPS" and tz_panel() is not None:
        return v
    return "hora del VPS (%s)" % time.strftime("%Z")

def onoff(v):
    return "ON ✅" if v else "OFF ⛔"

def scr_alertas(pre=""):
    a = alerts_get()
    txt = (pre + "🔔 <b>ALERTAS</b>\n" + LINEA + "\n"
           "📅 Resumen diario: <b>%s</b> · %02d:00\n"
           "⏳ Por vencer: <b>%s</b> · avisa a %d días\n"
           "🖥 Recursos: <b>%s</b> · sobre %d%% (RAM/CPU/disco)\n"
           "🕒 Zona: %s\n"
           "<i>Se revisa cada 5 min dentro del bot (sin procesos extra).</i>"
           % (onoff(a["daily"]), a["hour"], onoff(a["venc"]), a["dias_aviso"],
              onoff(a["res"]), a["umbral"], esc(tz_label())))
    rows = [
        [("📅 Resumen: " + onoff(a["daily"]), "alr|d"), ("🕒 Hora", "alr|h")],
        [("⏳ Por vencer: " + onoff(a["venc"]), "alr|e")],
        [("🖥 Recursos: " + onoff(a["res"]), "alr|r"), ("🎚 %d%%" % a["umbral"], "alr|u")],
        [("📨 Ver resumen ahora", "alr|t")],
        [("🔙 Menú", "menu")],
    ]
    return txt, rows

def scr_alertas_hora():
    a = alerts_get()
    btns = [(("✔%02d" if h == a["hour"] else "%02d") % h, "alr|hs|%d" % h) for h in range(24)]
    rows = [btns[i:i + 6] for i in range(0, 24, 6)]
    rows.append([("⬅ Alertas", "alr")])
    return "🕒 <b>HORA DEL RESUMEN DIARIO</b>\nElegí la hora (%s):" % esc(tz_label()), rows

def scr_alertas_umbral():
    a = alerts_get()
    btns = [(("✔%d%%" if v == a["umbral"] else "%d%%") % v, "alr|um|%d" % v) for v in (70, 80, 85, 90, 95)]
    return ("🎚 <b>UMBRAL DE RECURSOS</b>\nAvisar cuando RAM, CPU o disco pasen de:",
            [btns, [("⬅ Alertas", "alr")]])

def texto_resumen_diario():
    s = resumen_negocio()
    shd = shadow_map()
    por_vencer = []
    for u in panel_users():
        d = dias_desde_exp(shd.get(u, (False, None))[1])
        if d is not None and 0 <= d <= 3:
            por_vencer.append("%s %s" % (u, dias_corto(d)))
    pu = set(panel_users())
    top = sorted(((u, b) for u, b in s["mapa"].items() if u in pu),
                 key=lambda x: x[1], reverse=True)[:3]
    txt = ("📅 <b>RESUMEN DIARIO</b> · %s\n" % ahora().strftime("%d/%m/%Y") + LINEA + "\n"
           "👥 %d usuarios · 🟢 %d online\n"
           "⏳ Por vencer: %d%s\n"
           "🚫 Bloqueados: %d\n"
           "📈 Tráfico total: %s\n"
           % (s["n"], s["on"], s["ven"],
              (" (" + esc(", ".join(por_vencer)) + ")") if por_vencer else "",
              s["bloq"], esc(s["traf"])))
    if top:
        txt += "🏆 Top: " + esc(" · ".join("%s %s" % (u, fmt_bytes(b)) for u, b in top)) + "\n"
    return txt + "\n" + bloque_salud()

# --- chequeos del bucle (se ejecutan en un hilo) ---
RES = {"strikes": {}, "last": {}, "alerted": {}}

def check_recursos(a):
    """Devuelve el texto de alerta (o '') y actualiza el estado anti-spam."""
    th = a["umbral"]
    vals = {"RAM": mem_info()[2], "CPU": cpu_pct(1.0), "Disco": disk_info()[2]}
    ahora_t = time.time()
    msgs = []
    for k, v in vals.items():
        if v >= th:
            RES["strikes"][k] = RES["strikes"].get(k, 0) + 1
            necesarios = 2 if k == "CPU" else 1     # CPU: sostenida 2 chequeos (~10 min)
            if RES["strikes"][k] >= necesarios and ahora_t - RES["last"].get(k, 0) >= 6 * 3600:
                RES["last"][k] = ahora_t
                RES["alerted"][k] = True
                m = "🚨 <b>%s al %d%%</b> (umbral %d%%)\n%s %d%%" % (k, v, th, barra10(v), v)
                if k == "RAM":
                    ru, rt, _ = mem_info()
                    m += "\n💾 %d/%d MB · top: %s" % (ru, rt, esc(", ".join(top_procesos("rss"))))
                elif k == "CPU":
                    m += "\n🔥 top: " + esc(", ".join(top_procesos("cpu")))
                else:
                    du, dt, _ = disk_info()
                    m += "\n🗄 %s / %s" % (esc(fmt_bytes(du)), esc(fmt_bytes(dt)))
                    r = sh("du", "-sh", "/var/log", "/root/backups", timeout=10)
                    if r.stdout.strip():
                        m += "\n<pre>%s</pre>" % esc(r.stdout.strip())
                msgs.append(m)
        else:
            RES["strikes"][k] = 0
            if RES["alerted"].get(k) and v < th - 5:
                RES["alerted"][k] = False
                RES["last"][k] = 0
                msgs.append("✅ <b>%s normalizado</b> · %d%%" % (k, v))
    return "\n\n".join(msgs)

def check_venc(a):
    """Devuelve (texto, filas, nuevo_dict_avisados) o ('', None, None) si no hay nada nuevo."""
    ventana = int(a.get("dias_aviso", 3))
    av = a.get("venc_avisado", {})
    shd = shadow_map()
    nuevo_av, nuevos = {}, []
    for u in panel_users():
        d = dias_desde_exp(shd.get(u, (False, None))[1])
        iso = exp_iso(shd.get(u, (False, None))[1])
        if d is None or not (0 <= d <= ventana):
            continue
        if av.get(u) == iso:
            nuevo_av[u] = iso            # ya avisado para este vencimiento
        else:
            nuevo_av[u] = iso
            nuevos.append((u, d, iso))
    if not nuevos:
        if nuevo_av != av:
            return "", None, nuevo_av    # limpia entradas viejas sin enviar nada
        return "", None, None
    lineas = []
    for u, d, iso in nuevos:
        cuando = "hoy" if d == 0 else ("mañana" if d == 1 else "en %d días" % d)
        lineas.append("🔸 <code>%s</code> vence %s (%s)" % (esc(u), cuando, iso))
    txt = ("⏳ <b>POR VENCER</b> (faltan %d días o menos)\n" % ventana + LINEA + "\n"
           + "\n".join(lineas))
    btns = [("👤 " + u, "u|" + u) for u, _, _ in nuevos[:6]]
    rows = [btns[i:i + 2] for i in range(0, len(btns), 2)]
    return txt, rows, nuevo_av

async def notify(app, text, rows=None):
    try:
        await app.bot.send_message(int(ADMIN_ID), text, parse_mode=ParseMode.HTML,
                                   reply_markup=kb(rows) if rows else None,
                                   disable_web_page_preview=True)
        return True
    except Exception as e:
        log.warning("notify falló: %s", e)
        return False

async def alert_loop(app):
    await asyncio.sleep(45)
    while True:
        try:
            a = alerts_get()
            if a["res"]:
                txt = await asyncio.to_thread(check_recursos, a)
                if txt:
                    await notify(app, txt, [[("🛠 Servidor", "srv")]])
            if a["venc"]:
                txt, rows, nuevo = await asyncio.to_thread(check_venc, a)
                if nuevo is not None:
                    if not txt or await notify(app, txt, rows):
                        alerts_set(venc_avisado=nuevo)
            if a["daily"]:
                n = ahora()
                hoy = n.strftime("%Y-%m-%d")
                if n.hour == int(a["hour"]) and a.get("last_daily") != hoy:
                    txt = await asyncio.to_thread(texto_resumen_diario)
                    if await notify(app, txt, [[("🏠 Menú", "menu")]]):
                        alerts_set(last_daily=hoy)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("alert_loop")
        await asyncio.sleep(ALERT_EVERY)

# ------------------------- PANTALLA PERSISTENTE -------------------------
# ------------------------- MENSAJES CON CONTRASEÑA: se borran -------------------------
# El bot ya no guarda contraseñas, pero cada ficha con clave queda en el historial de Telegram (en la nube).
# Por eso esos mensajes llevan «Borrar este mensaje» y se borran solos pasados AUTOBORRAR_MIN minutos.
try:
    AUTOBORRAR_MIN = max(0, min(1440, int(str(CONF.get("AUTOBORRAR_MIN", "5")).strip() or 5)))
except ValueError:
    AUTOBORRAR_MIN = 5
SECRETOS_FILE = os.path.join(BOT_DIR, "secretos.json")      # "chat:mensaje" -> instante en que se borra
SECRETOS = jload(SECRETOS_FILE, {})
if not isinstance(SECRETOS, dict):
    SECRETOS = {}

def secretos_guardar():
    try:
        jsave(SECRETOS_FILE, SECRETOS)
    except Exception as e:
        log.warning("secretos: %s", e)

def secreto_olvidar(chat_id, msg_id):
    """Ese mensaje ya no muestra la clave (cambió de pantalla o se borró): nada que borrar luego."""
    if SECRETOS.pop("%s:%s" % (chat_id, msg_id), None) is not None:
        secretos_guardar()

async def borrar_mensaje(bot, chat_id, msg_id):
    try:
        await bot.delete_message(chat_id=chat_id, message_id=msg_id)
        return True
    except Exception as e:
        log.info("no se pudo borrar %s:%s (%s)", chat_id, msg_id, e)
        return False

async def borrado_loop(app):
    """Borra los mensajes con clave cuyo plazo venció. El plazo está en disco: sobrevive a reinicios del bot."""
    while True:
        try:
            ahora = time.time()
            vencidos = [k for k, t in list(SECRETOS.items()) if t <= ahora]
            for k in vencidos:
                SECRETOS.pop(k, None)
                chat_s, _, mid_s = k.partition(":")
                try:
                    chat_id, mid = int(chat_s), int(mid_s)
                except ValueError:
                    continue
                await borrar_mensaje(app.bot, chat_id, mid)
                ud = app.user_data.get(chat_id)
                if ud is not None and ud.get("wid") == mid:
                    ud["wid"] = None           # la próxima pantalla se manda como mensaje nuevo
            if vencidos:
                secretos_guardar()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("borrado_loop: %s", e)
        await asyncio.sleep(20)

async def pantalla(update, context, text, rows=None, borra_texto=False):
    """Mantiene UNA pantalla por chat: edita el mensaje persistente.

    Si borra_texto=True, elimina el mensaje de texto que escribió el admin
    (su contenido ya fue procesado): el chat queda siempre limpio.
    """
    chat_id = update.effective_chat.id
    if borra_texto and update.message is not None:
        try:
            await update.message.delete()
        except Exception:
            pass
    wid = context.user_data.get("wid")
    if wid:
        secreto_olvidar(chat_id, wid)          # al editarlo deja de mostrar la clave anterior
        try:
            await context.bot.edit_message_text(
                text, chat_id=chat_id, message_id=wid,
                parse_mode=ParseMode.HTML,
                reply_markup=kb(rows) if rows else None,
                disable_web_page_preview=True)
            return
        except BadRequest as e:
            low = str(e).lower()
            if "not modified" in low:
                return
            if "message to edit not found" not in low and "there is no text" not in low:
                log.warning("pantalla edit: %s", e)
    try:
        m = await context.bot.send_message(
            chat_id, text, parse_mode=ParseMode.HTML,
            reply_markup=kb(rows) if rows else None,
            disable_web_page_preview=True)
        context.user_data["wid"] = m.message_id
    except BadRequest as e:
        log.error("pantalla send: %s", e)

async def pantalla_secreta(update, context, text, rows=None, borra_texto=False):
    """Pantalla que muestra una CONTRASEÑA: agrega «Borrar este mensaje» y programa su borrado automático."""
    if AUTOBORRAR_MIN > 0:
        text += "\n\n🗑 <i>Este mensaje se borra solo en %d min.</i>" % AUTOBORRAR_MIN
    rows = [list(r) for r in (rows or [])] + [[("🗑 Borrar este mensaje", "delmsg")]]
    await pantalla(update, context, text, rows, borra_texto=borra_texto)
    wid = context.user_data.get("wid")
    if AUTOBORRAR_MIN > 0 and wid:
        SECRETOS["%s:%s" % (update.effective_chat.id, wid)] = time.time() + AUTOBORRAR_MIN * 60
        secretos_guardar()

async def show(update, context, fn, *args, pre=None, borra=False):
    """Ejecuta fn(*args) en un hilo (devuelve (texto, filas)) y lo muestra."""
    text, rows = await asyncio.to_thread(fn, *args)
    await pantalla(update, context, (pre or "") + text, rows, borra_texto=borra)

async def show_err(update, context, detalle, rows=None, borra=False):
    text, r = scr_error(detalle, rows)
    await pantalla(update, context, text, r, borra_texto=borra)

# ------------------------- CONTROL DE ACCESO -------------------------
def admin_only(func):
    @functools.wraps(func)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE, *a, **k):
        chat = update.effective_chat
        cid = str(chat.id) if chat is not None else ""
        if cid != ADMIN_ID:
            uname = update.effective_user.username if update.effective_user else "?"
            log.warning("acceso denegado chat_id=%s user=%s", cid, uname)
            if update.callback_query is not None:
                try:
                    await update.callback_query.answer("⛔ Acceso denegado", show_alert=True)
                except Exception:
                    pass
            elif update.message is not None:
                try:
                    await update.message.reply_text("⛔ Acceso denegado")
                except Exception:
                    pass
            return
        return await func(update, context, *a, **k)
    return wrapper

# ------------------------- FLUJOS (paso a paso, timeout 5 min) -------------------------
def flow_set(context, nombre, step, data=None):
    context.user_data["flow"] = {"name": nombre, "step": step,
                                 "data": data or {}, "ts": time.time()}

def flow_get(context):
    f = context.user_data.get("flow")
    return f if isinstance(f, dict) and f.get("name") else None

def flow_touch(context):
    f = flow_get(context)
    if f:
        f["ts"] = time.time()

def flow_clear(context):
    context.user_data["flow"] = None

KB_NOMBRE = [[("🎲 Nombre aleatorio", "cn|rnd")], [("❌ Cancelar", "cancel")]]

def paso_dias_rows():
    return [[("7", "dias|7"), ("15", "dias|15"), ("30", "dias|30")],
            [("60", "dias|60"), ("90", "dias|90"), ("✍️ Otro", "dias|custom")],
            [("❌ Cancelar", "cancel")]]

def paso_conx_rows():
    return [[("1", "conx|1"), ("2", "conx|2"), ("3", "conx|3")],
            [("5", "conx|5"), ("♾ Sin límite", "conx|0")],
            [("❌ Cancelar", "cancel")]]

def paso_gb_rows():
    return [[("10", "gb|10"), ("30", "gb|30"), ("50", "gb|50")],
            [("100", "gb|100"), ("♾ Sin límite", "gb|0"), ("✍️ Otro", "gb|custom")],
            [("❌ Cancelar", "cancel")]]

def paso_clave_rows():
    return [[("🎲 Generar", "cc|gen"), ("✍️ Manual", "cc|manual")],
            [("❌ Cancelar", "cancel")]]

def resumen_rows():
    return [[("✅ Confirmar", "crear_ok"), ("✏️ Editar", "crear_edit")],
            [("❌ Cancelar", "cancel")]]

def paso_edit_rows():
    return [[("👤 Nombre", "ced|nombre"), ("⏳ Días", "ced|dias")],
            [("🔌 Conexiones", "ced|conx"), ("📦 GB", "ced|gb")],
            [("🔑 Clave", "ced|clave"), ("✅ Listo", "crear_ok")],
            [("❌ Cancelar", "cancel")]]

def resumen_crear(d):
    gb_txt = ("%d GB" % d.get("gb", 0)) if d.get("gb", 0) > 0 else "sin límite"
    cx_txt = str(d.get("maxc", 1)) if d.get("maxc", 1) > 0 else "sin límite"
    dias = d.get("dias", "?")
    validez = ("%s día%s" % (dias, "" if dias == 1 else "s")) if isinstance(dias, int) else str(dias)
    return ("📝 <b>CONFIRMAR CREACIÓN</b>\n" + LINEA + "\n"
            + tabla([("Usuario", d.get("usuario", "?")),
                     ("Contraseña", d.get("clave", "?")),
                     ("Validez", validez),
                     ("Conexiones", cx_txt),
                     ("Tráfico", gb_txt)])
            + "\n¿Confirmás la creación?")

# ------------------------- ROUTER DE BOTONES -------------------------
@admin_only
async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    try:
        await q.answer()
    except Exception:
        pass
    data = q.data or ""
    # el mensaje tocado pasa a ser la "pantalla viva" (sirve tras reiniciar el bot y en alertas)
    if q.message is not None:
        context.user_data["wid"] = q.message.message_id

    f = flow_get(context)
    if f and time.time() - f.get("ts", 0) > TIMEOUT_FLOW:
        flow_clear(context)
        f = None
        await show(update, context, scr_menu,
                   pre="⏱ <i>Conversación cancelada por inactividad (5 min).</i>\n\n")
        return

    if data in ("menu", "cancel"):
        flow_clear(context)
        await show(update, context, scr_menu)
        return

    try:
        if f and await flow_button(update, context, data, f):
            return
        flow_clear(context)     # botón de navegación fuera del flujo: se cancela y se ejecuta
        await route(update, context, data)
    except Exception as e:
        log.exception("on_button %s", data)
        await show_err(update, context, "%s: %s" % (type(e).__name__, e))

async def route(update, context, data):
    """Acciones de primer nivel (sin flujo abierto)."""
    p = data.split("|")
    k = p[0]

    def arg(i, d=""):
        return p[i] if len(p) > i else d

    async def usuario_ok(u):
        err = usuario_valido_existente(u)
        if err:
            await show_err(update, context, err, [[("📋 Usuarios", "ul|0"), ("🔙 Menú", "menu")]])
            return False
        return True

    if k == "noop":
        return
    if k == "ul":
        await show(update, context, scr_lista, int(arg(1, "0")) if arg(1, "0").isdigit() else 0, arg(2))
    elif k == "sr":
        flow_set(context, "buscar", "texto")
        await pantalla(update, context,
                       "🔎 <b>BUSCAR USUARIO</b>\nEscribí <b>parte del nombre</b>:", KB_CANCELAR)
    elif k == "u":
        if await usuario_ok(arg(1)):
            await show(update, context, scr_ficha, arg(1))
    elif k == "on":
        await show(update, context, scr_conectados)
    elif k == "kick":
        u = arg(1)
        if await usuario_ok(u):
            n = await asyncio.to_thread(accion_kick, u)
            pre = "⛔ <b>%s desconectado</b> (%d sesión%s)\n\n" % (esc(u), n, "" if n == 1 else "es")
            if arg(2) == "on":
                await show(update, context, scr_conectados, pre)
            else:
                await show(update, context, scr_ficha, u, pre)
    elif k == "tr":
        await show(update, context, scr_trafico)
    # ---- crear ----
    elif k == "cr":
        sub = arg(1)
        if sub == "test":
            u = nombre_libre("test")
            clave = gen_clave(10)
            ok, res = await asyncio.to_thread(accion_crear, u, TEST_DIAS, TEST_CONX, TEST_GB, clave)
            if ok:
                txt = await asyncio.to_thread(ficha_creada, u, clave, TEST_DIAS, TEST_CONX, TEST_GB, res, True)
                await pantalla_secreta(update, context, txt,
                               [[("👤 Ficha", "u|" + u)],
                                [("🧪 Otro test", "cr|test"), ("🔙 Menú", "menu")]])
            else:
                await show_err(update, context, res, [[("🔄 Reintentar", "cr|test")], [("🔙 Menú", "menu")]])
        elif sub == "full":
            flow_set(context, "crear", "nombre")
            await pantalla(update, context,
                           "👤 <b>CREAR USUARIO · paso 1/6</b>\n"
                           "Escribí el <b>nombre de usuario</b> o tocá 🎲\n"
                           "<i>(minúsculas, números, - y _; máx 32)</i>", KB_NOMBRE)
        else:
            await show(update, context, scr_crear)
    # ---- renovar ----
    elif k == "rnm":
        if await usuario_ok(arg(1)):
            await show(update, context, scr_renovar, arg(1))
    elif k == "rn":
        u, v = arg(2), arg(1)
        if not await usuario_ok(u):
            return
        if v == "c":
            flow_set(context, "rnc", "dias", {"usuario": u})
            await pantalla(update, context,
                           "⏳ <b>RENOVAR · %s</b>\nEscribí los <b>días a agregar</b>:" % esc(u), KB_CANCELAR)
        elif v.isdigit():
            await renovar_ejecutar(update, context, u, int(v))
    # ---- bloquear ----
    elif k == "blk":
        u = arg(1)
        if await usuario_ok(u):
            bloqueado, _ = await asyncio.to_thread(accion_bloquear, u)
            pre = ("🔒 <b>%s bloqueado</b> (sesiones cerradas)\n\n" if bloqueado
                   else "🔓 <b>%s desbloqueado</b>\n\n") % esc(u)
            await show(update, context, scr_ficha, u, pre)
    # ---- clave ----
    elif k == "delmsg":
        wid = context.user_data.get("wid")                 # on_button deja aqui el mensaje tocado
        if wid:
            secreto_olvidar(update.effective_chat.id, wid)
            await borrar_mensaje(context.bot, update.effective_chat.id, wid)
            context.user_data["wid"] = None
        await show(update, context, scr_menu)              # el menú sale como mensaje nuevo
    elif k == "clv":
        if await usuario_ok(arg(1)):
            await show(update, context, scr_clave, arg(1))
    elif k in ("clc", "snc"):
        if await usuario_ok(arg(1)):
            await show(update, context, scr_confirmar_clave, arg(1), "clg" if k == "clc" else "sng")
    elif k == "clg":
        u = arg(1)
        if await usuario_ok(u):
            clave = gen_clave()
            ok, msg = await asyncio.to_thread(accion_clave, u, clave)
            if ok:
                txt = await asyncio.to_thread(ficha_clave, u, clave)
                await pantalla_secreta(update, context, txt, [[("⬅ Ficha", "u|" + u), ("🔙 Menú", "menu")]])
            else:
                await show_err(update, context, msg, [[("⬅ Ficha", "u|" + u)]])
    elif k == "clm":
        u = arg(1)
        if await usuario_ok(u):
            flow_set(context, "clavem", "clave", {"usuario": u})
            await pantalla(update, context,
                           "🔑 <b>CLAVE · %s</b>\nEscribí la <b>nueva contraseña</b>:" % esc(u),
                           KB_CANCELAR)
    # ---- enviar datos ----
    elif k == "snd":
        if await usuario_ok(arg(1)):
            await show(update, context, scr_enviar, arg(1))
    elif k == "sng":
        u = arg(1)
        if await usuario_ok(u):
            clave = gen_clave()
            ok, msg = await asyncio.to_thread(accion_clave, u, clave)
            if ok:
                txt = await asyncio.to_thread(ficha_clave, u, clave)
                await pantalla_secreta(update, context, txt, [[("⬅ Ficha", "u|" + u), ("🔙 Menú", "menu")]])
            else:
                await show_err(update, context, msg, [[("⬅ Ficha", "u|" + u)]])
    # ---- límites ----
    elif k == "lim":
        if await usuario_ok(arg(1)):
            await show(update, context, scr_limites, arg(1))
    elif k in ("lmc", "lmg"):
        n, u = arg(1), arg(2)
        if not (n.isdigit() and await usuario_ok(u)):
            return
        if k == "lmc":
            await asyncio.to_thread(accion_limite_conex, u, int(n))
            pre = "✅ Conexiones máximas: <b>%s</b>\n\n" % (n if int(n) > 0 else "sin límite")
        else:
            await asyncio.to_thread(accion_limite_gb, u, int(n))
            pre = "✅ Cuota: <b>%s</b>\n\n" % (("%s GB" % n) if int(n) > 0 else "sin límite")
            if cuota_agotada(u):
                pre += "ℹ️ Seguía marcado por cuota: tocá «Desbloquear por cuota».\n\n"
        await show(update, context, scr_limites, u, pre)
    elif k == "lmx":
        u = arg(1)
        if await usuario_ok(u):
            flow_set(context, "gbc", "gb", {"usuario": u})
            await pantalla(update, context,
                           "📦 <b>CUOTA · %s</b>\nEscribí los <b>GB</b> (0 = sin límite):" % esc(u),
                           KB_CANCELAR)
    elif k == "lmr":
        u = arg(1)
        if await usuario_ok(u):
            await asyncio.to_thread(accion_reset_contador, u)
            await show(update, context, scr_limites, u, "🔄 <b>Contador en cero.</b>\n\n")
    elif k == "lmu":
        u = arg(1)
        if await usuario_ok(u):
            await asyncio.to_thread(accion_desbloquear_cuota, u)
            await show(update, context, scr_ficha, u,
                       "🔓 <b>%s desbloqueado por cuota</b> (contador en cero)\n\n" % esc(u))
    # ---- eliminar ----
    elif k == "dl":
        if await usuario_ok(arg(1)):
            await show(update, context, scr_eliminar, arg(1))
    elif k == "dly":
        u = arg(1)
        if await usuario_ok(u):
            ok, res = await asyncio.to_thread(accion_eliminar, u)
            if ok:
                await show(update, context, scr_lista, 0, "",
                           pre="❌ <b>%s eliminado</b>\n\n" % esc(u))
            else:
                await show_err(update, context, res, [[("⬅ Ficha", "u|" + u)]])
    # ---- servidor ----
    elif k == "srv":
        sub = arg(1)
        if sub in ("xray", "ssh", "lim"):
            ok, msg = await asyncio.to_thread(svc_restart, sub)
            log.info("reinicio servicio via bot: %s -> %s", sub, msg)
            await show(update, context, scr_servidor, ("✅ " if ok else "❌ ") + esc(msg) + "\n\n")
        elif sub == "ports":
            await show(update, context, scr_puertos)
        elif sub == "logs":
            await show(update, context, scr_logs_menu)
        elif sub == "st":
            await show(update, context, scr_detalle)
        elif sub == "bk":
            await backup_ejecutar(update, context)
        else:
            await show(update, context, scr_servidor)
    elif k == "log":
        await show(update, context, scr_log, arg(1))
    elif k == "rb1":
        await show(update, context, scr_reiniciar1)
    elif k == "rb2":
        await show(update, context, scr_reiniciar2)
    elif k == "rb3":
        ts = int(arg(1, "0")) if arg(1, "0").isdigit() else 0
        if time.time() - ts > 60:
            await show(update, context, scr_servidor, "⌛ La confirmación venció. Volvé a empezar.\n\n")
            return
        write_file(REBOOT_FLAG, "%d\n" % int(time.time()))
        log.warning("REINICIO DE LA VPS pedido desde el bot")
        await pantalla(update, context,
                       "♻️ <b>Reiniciando la VPS…</b>\nEl bot te avisa cuando vuelva (1-2 min).", None)
        try:
            subprocess.Popen(["bash", "-c", "sleep 3; systemctl reboot"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError as e:
            await show_err(update, context, "No se pudo reiniciar: %s" % e)
    # ---- alertas ----
    elif k == "alr":
        sub = arg(1)
        a = alerts_get()
        if sub == "d":
            alerts_set(daily=not a["daily"])
        elif sub == "e":
            alerts_set(venc=not a["venc"])
        elif sub == "r":
            alerts_set(res=not a["res"])
        elif sub == "h":
            await show(update, context, scr_alertas_hora)
            return
        elif sub == "u":
            await show(update, context, scr_alertas_umbral)
            return
        elif sub == "hs" and arg(2).isdigit() and 0 <= int(arg(2)) <= 23:
            alerts_set(hour=int(arg(2)), last_daily="")
        elif sub == "um" and arg(2).isdigit() and 50 <= int(arg(2)) <= 99:
            alerts_set(umbral=int(arg(2)))
            RES["strikes"].clear()
        elif sub == "t":
            txt = await asyncio.to_thread(texto_resumen_diario)
            await pantalla(update, context, txt, [[("⬅ Alertas", "alr"), ("🔙 Menú", "menu")]])
            return
        await show(update, context, scr_alertas)
    else:
        await show(update, context, scr_menu)

def ficha_clave(u, clave):
    iso = account_expiry_iso(u)
    return ("🔑 <b>CLAVE ACTUALIZADA</b>\n" + LINEA + "\n"
            + bloque_datos(u, clave, iso)
            + "\n🟢 Contraseña cambiada · la anterior ya no funciona\n"
              "<i>Tocá un dato para copiarlo solo.</i>\n\n"
            + copiar_bloque(datos_filas(u, clave, iso))
            + checkuser_bloque(u))

# --- botones DENTRO de un flujo; devuelve False si el dato no es del flujo ---
async def flow_button(update, context, data, f):
    nombre, step = f["name"], f["step"]
    d = f.setdefault("data", {})
    flow_touch(context)

    if nombre != "crear":
        return False
    if step == "nombre" and data == "cn|rnd":
        d["usuario"] = nombre_libre("user")
        f["step"] = "dias"
        await pantalla(update, context,
                       "⏳ <b>CREAR · paso 2/6</b> · <code>%s</code>\n<b>Días de validez</b> de la cuenta:"
                       % esc(d["usuario"]), paso_dias_rows())
        return True
    if step == "dias" and data.startswith("dias|"):
        v = data.split("|", 1)[1]
        if v == "custom":
            f["step"] = "dias_custom"
            await pantalla(update, context,
                           "⏳ <b>CREAR · días</b>\nEscribí la <b>cantidad de días</b> (ej. 30):", KB_CANCELAR)
        else:
            d["dias"] = int(v)
            f["step"] = "conx"
            await pantalla(update, context,
                           "🔌 <b>CREAR · paso 3/6</b>\n<b>Conexiones máximas</b> simultáneas:",
                           paso_conx_rows())
        return True
    if step == "conx" and data.startswith("conx|"):
        d["maxc"] = int(data.split("|", 1)[1])
        f["step"] = "gb"
        await pantalla(update, context,
                       "📦 <b>CREAR · paso 4/6</b>\n<b>Límite de tráfico</b> (GB):", paso_gb_rows())
        return True
    if step == "gb" and data.startswith("gb|"):
        v = data.split("|", 1)[1]
        if v == "custom":
            f["step"] = "gb_custom"
            await pantalla(update, context,
                           "📦 <b>CREAR · GB</b>\nEscribí los <b>GB</b> (0 = sin límite):", KB_CANCELAR)
        else:
            d["gb"] = int(v)
            f["step"] = "clave"
            await pantalla(update, context,
                           "🔑 <b>CREAR · paso 5/6</b>\n<b>Contraseña</b> del usuario:", paso_clave_rows())
        return True
    if step == "clave" and data in ("cc|gen", "cc|manual"):
        if data == "cc|gen":
            d["clave"] = gen_clave()
            f["step"] = "resumen"
            await pantalla(update, context, resumen_crear(d), resumen_rows())
        else:
            f["step"] = "clave_manual"
            await pantalla(update, context,
                           "🔑 <b>CREAR · clave</b>\nEscribí la <b>contraseña</b>:", KB_CANCELAR)
        return True
    if step == "resumen" and data == "crear_ok":
        await crear_ejecutar(update, context, d)
        return True
    if step == "resumen" and data == "crear_edit":
        f["step"] = "edit"
        await pantalla(update, context, resumen_crear(d), paso_edit_rows())
        return True
    if step == "edit" and data.startswith("ced|"):
        campo = data.split("|", 1)[1]
        if campo == "nombre":
            f["step"] = "nombre"
            await pantalla(update, context,
                           "👤 <b>CREAR · nombre</b>\nEscribí el <b>nuevo nombre</b>:", KB_NOMBRE)
        elif campo == "dias":
            f["step"] = "dias"
            await pantalla(update, context, "⏳ <b>CREAR · días</b> de validez:", paso_dias_rows())
        elif campo == "conx":
            f["step"] = "conx"
            await pantalla(update, context, "🔌 <b>CREAR · conexiones</b> máximas:", paso_conx_rows())
        elif campo == "gb":
            f["step"] = "gb"
            await pantalla(update, context, "📦 <b>CREAR · límite de tráfico</b> (GB):", paso_gb_rows())
        elif campo == "clave":
            f["step"] = "clave"
            await pantalla(update, context, "🔑 <b>CREAR · contraseña</b>:", paso_clave_rows())
        return True
    if step == "edit" and data == "crear_ok":
        await crear_ejecutar(update, context, d)
        return True
    return False

# --- texto dentro de un flujo ---
async def flow_text(update, context, texto, f):
    nombre, step = f["name"], f["step"]
    d = f.setdefault("data", {})
    texto = texto.strip()

    if nombre == "crear":
        if step == "nombre":
            err = validar_usuario_flow(texto)
            if err:
                await pantalla(update, context, "⚠️ " + esc(err), KB_NOMBRE, borra_texto=True)
                return
            d["usuario"] = texto
            f["step"] = "dias"
            await pantalla(update, context,
                           "⏳ <b>CREAR · paso 2/6</b>\n<b>Días de validez</b> de la cuenta:",
                           paso_dias_rows(), borra_texto=True)
        elif step == "dias_custom":
            if not texto.isdigit() or int(texto) < 1:
                await pantalla(update, context, "⚠️ Escribí un <b>entero &gt;= 1</b>.", KB_CANCELAR,
                               borra_texto=True)
                return
            d["dias"] = int(texto)
            f["step"] = "conx"
            await pantalla(update, context,
                           "🔌 <b>CREAR · paso 3/6</b>\n<b>Conexiones máximas</b>:", paso_conx_rows(),
                           borra_texto=True)
        elif step == "gb_custom":
            if not texto.isdigit():
                await pantalla(update, context, "⚠️ Escribí un <b>entero</b> (0 = sin límite).",
                               KB_CANCELAR, borra_texto=True)
                return
            d["gb"] = int(texto)
            f["step"] = "clave"
            await pantalla(update, context,
                           "🔑 <b>CREAR · paso 5/6</b>\n<b>Contraseña</b>:", paso_clave_rows(),
                           borra_texto=True)
        elif step == "clave_manual":
            if len(texto) < 4:
                await pantalla(update, context, "⚠️ Mínimo <b>4 caracteres</b>.", KB_CANCELAR,
                               borra_texto=True)
                return
            d["clave"] = texto
            f["step"] = "resumen"
            await pantalla(update, context, resumen_crear(d), resumen_rows(), borra_texto=True)
        else:
            await pantalla(update, context, resumen_crear(d), resumen_rows(), borra_texto=True)
    elif nombre == "buscar":
        flow_clear(context)
        filtro = re.sub(r"[^A-Za-z0-9_-]", "", texto)[:30]
        await show(update, context, scr_lista, 0, filtro, borra=True)
    elif nombre == "rnc":
        if not texto.isdigit() or int(texto) < 1:
            await pantalla(update, context, "⚠️ Escribí un <b>entero &gt;= 1</b>.", KB_CANCELAR,
                           borra_texto=True)
            return
        await renovar_ejecutar(update, context, d.get("usuario", ""), int(texto), borra=True)
    elif nombre == "gbc":
        if not texto.isdigit() or int(texto) > 999999:
            await pantalla(update, context, "⚠️ Escribí un <b>entero</b> (0 = sin límite).",
                           KB_CANCELAR, borra_texto=True)
            return
        u = d.get("usuario", "")
        flow_clear(context)
        await asyncio.to_thread(accion_limite_gb, u, int(texto))
        pre = "✅ Cuota: <b>%s</b>\n\n" % (("%s GB" % texto) if int(texto) > 0 else "sin límite")
        await show(update, context, scr_limites, u, pre, borra=True)
    elif nombre == "clavem":
        u = d.get("usuario", "")
        ok, msg = await asyncio.to_thread(accion_clave, u, texto)
        if ok:
            flow_clear(context)
            txt = await asyncio.to_thread(ficha_clave, u, texto)
            await pantalla_secreta(update, context, txt, [[("⬅ Ficha", "u|" + u), ("🔙 Menú", "menu")]],
                                   borra_texto=True)
        else:
            await pantalla(update, context, "⚠️ " + esc(msg), KB_CANCELAR, borra_texto=True)

# --- ejecutores finales ---
async def crear_ejecutar(update, context, d):
    ok, res = await asyncio.to_thread(accion_crear, d.get("usuario", ""), d.get("dias", 0),
                                      d.get("maxc", 1), d.get("gb", 0), d.get("clave", ""))
    flow_clear(context)
    if ok:
        txt = await asyncio.to_thread(ficha_creada, d["usuario"], d["clave"], d["dias"],
                                      d["maxc"], d["gb"], res)
        await pantalla_secreta(update, context, txt,
                       [[("👤 Ficha", "u|" + d["usuario"])],
                        [("➕ Otro", "cr"), ("🔙 Menú", "menu")]])
    else:
        await show_err(update, context, res, [[("➕ Crear", "cr")], [("🔙 Menú", "menu")]])

async def renovar_ejecutar(update, context, usuario, dias, borra=False):
    flow_clear(context)
    ok, res = await asyncio.to_thread(accion_renovar, usuario, dias)
    if ok:
        pre = ("🔄 <b>USUARIO RENOVADO</b>\n"
               + tabla([("Usuario", usuario),
                        ("Agregado", "+%d día%s" % (dias, "" if dias == 1 else "s")),
                        ("Vence", "%s · %s" % (res, dias_txt(days_hasta(res))))])
               + "\n")
        await show(update, context, scr_ficha, usuario, pre, borra=borra)
    else:
        await show_err(update, context, res, [[("⬅ Ficha", "u|" + usuario)]], borra=borra)

async def backup_ejecutar(update, context):
    if ADMIN_ID.startswith("-"):
        await show(update, context, scr_servidor,
                   "⛔ El ADMIN_CHAT_ID es un <b>grupo</b>: el backup lleva datos de usuarios y "
                   "solo se envía a un chat privado.\n\n")
        return
    await pantalla(update, context, "💾 <b>Creando backup…</b>\n<i>Se cifra antes de enviarlo.</i>", None)
    ok, res, size = await asyncio.to_thread(hacer_backup)
    if not ok:
        await show(update, context, scr_servidor, "❌ Backup falló: %s\n\n" % esc(res))
        return
    # NUNCA se manda sin cifrar: el backup lleva /etc/shadow (hashes) y las llaves privadas de SSH
    ok, enc = await asyncio.to_thread(cifrar_backup, res)
    if not ok:
        await show(update, context, scr_servidor,
                   "❌ <b>No se envió el backup</b> (no se manda sin cifrar): %s\n"
                   "Quedó solo en el servidor: <code>%s</code>\n\n" % (esc(enc), esc(res)))
        return
    try:
        esize = os.path.getsize(enc)
        if esize > TG_MAX_FILE:
            await show(update, context, scr_servidor,
                       "⚠️ Backup creado pero pesa %s (> 49 MB, límite de Telegram).\n"
                       "Quedó solo en el servidor: <code>%s</code>\n\n" % (esc(fmt_bytes(esize)), esc(res)))
            return
        nombre = os.path.basename(enc)
        try:
            with open(enc, "rb") as fh:
                await context.bot.send_document(
                    chat_id=int(ADMIN_ID), document=fh, filename=nombre, parse_mode=ParseMode.HTML,
                    caption=("💾 <b>Backup CIFRADO</b> (AES-256) · %s\n"
                             "🔓 Para abrirlo:\n"
                             "<code>openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in %s -out backup.tar.gz</code>\n"
                             "🔑 La clave NO viaja por Telegram: panel → Bot Telegram → Ver token y admin."
                             % (esc(fmt_bytes(esize)), esc(nombre))))
        except Exception as e:
            log.error("backup send: %s", e)
            await show(update, context, scr_servidor, "❌ No se pudo enviar el backup: %s\n\n" % esc(e))
            return
    finally:
        try:
            os.remove(enc)          # el .enc es temporal; la copia local queda en BACKUP_DIR (0600)
        except OSError:
            pass
    log.info("backup CIFRADO enviado via bot: %s (%d bytes)", res, esize)
    await pantalla(update, context, "💾 <b>BACKUP ENVIADO (cifrado)</b> ↓\n<code>%s</code>" % esc(res), None)
    context.user_data["wid"] = None          # la nueva pantalla queda debajo del archivo
    await show(update, context, scr_servidor)

# ------------------------- ROUTER DE TEXTO -------------------------
@admin_only
async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    texto = (update.message.text or "").strip() if update.message else ""
    if not texto:
        return
    f = flow_get(context)
    if f and time.time() - f.get("ts", 0) > TIMEOUT_FLOW:
        flow_clear(context)
        await show(update, context, scr_menu, borra=True,
                   pre="⏱ <i>Conversación cancelada por inactividad (5 min).</i>\n\n")
        return
    if f:
        flow_touch(context)
        try:
            await flow_text(update, context, texto, f)
        except Exception as e:
            log.exception("on_text")
            flow_clear(context)
            await show_err(update, context, "%s: %s" % (type(e).__name__, e), borra=True)
        return
    # sin flujo activo: recordatorio amable (el chat queda limpio)
    await show(update, context, scr_menu, borra=True,
               pre="💡 Usá los <b>botones</b> del menú o <b>/start</b>.\n\n")

# ------------------------- COMANDOS -------------------------
@admin_only
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    flow_clear(context)
    context.user_data["wid"] = None
    await show(update, context, scr_menu)

# ------------------------- ERRORES / CICLO DE VIDA -------------------------
async def on_error(update, context):
    log.error("error no capturado: %s (update=%s)", context.error,
              type(update).__name__ if update else "?")

async def post_init(app):
    await asyncio.to_thread(purgar_claves_antiguas)
    await asyncio.to_thread(backup_key)
    app.bot_data["alert_task"] = asyncio.create_task(alert_loop(app))
    app.bot_data["borrado_task"] = asyncio.create_task(borrado_loop(app))
    if os.path.isfile(REBOOT_FLAG):          # venimos de un reinicio pedido desde el bot
        try:
            ts = float(read_file(REBOOT_FLAG, "0") or 0)
        except ValueError:
            ts = 0
        try:
            os.remove(REBOOT_FLAG)
        except OSError:
            pass
        dur = ("~%d min" % max(1, int((time.time() - ts) // 60))) if ts else ""
        await notify(app, "✅ <b>VPS reiniciada y en línea</b> %s\n⏱ Uptime: %s"
                     % (esc(dur), esc(uptime_txt())), [[("🏠 Menú", "menu")]])

async def post_shutdown(app):
    for nombre in ("alert_task", "borrado_task"):
        t = app.bot_data.get(nombre)
        if t:
            t.cancel()

# ------------------------- MAIN -------------------------
def main():
    if not BOT_TOKEN:
        log.error("BOT_TOKEN vacio en %s. Reinstalá el bot desde el panel.", CONF_FILE)
        sys.exit(1)
    if not ADMIN_ID:
        log.error("ADMIN_CHAT_ID vacio en %s. Reinstalá el bot desde el panel.", CONF_FILE)
        sys.exit(1)
    log.info("Ghost Bot %s iniciado (admin=%s, dir=%s)", BOT_REV, ADMIN_ID, BOT_DIR)
    app = (Application.builder().token(BOT_TOKEN)
           .post_init(post_init).post_shutdown(post_shutdown).build())
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("menu", cmd_start))
    app.add_handler(CallbackQueryHandler(on_button))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.add_error_handler(on_error)
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__":
    main()
PYBOTGHOST
    chmod 700 "$BOT_DIR/bot.py" 2>/dev/null || true
    return 0
}

bot_apt_instalar(){
    # bot_apt_instalar PAQUETES... -> apt install con reintento si el lock esta
    # ocupado (unattended-upgrades suele correr justo al bootear el VPS).
    local i
    for i in 1 2 3; do
        apt install -y "$@" >/tmp/ghost-apt.log 2>&1 && return 0
        grep -qi 'could not get lock\|locked by another process\|dpkg lock\|waiting for cache lock' /tmp/ghost-apt.log \
            || break
        WARN "apt está ocupado; espero 20 s y reintento ($i/3)..."
        sleep 20
    done
    return 1
}

bot_venv_crear(){
    # Crea $BOT_DIR/venv con pip y devuelve 0 si queda listo.
    # OJO Ubuntu 24.04: el modulo venv SIEMPRE se puede importar (viene en el
    # stdlib) pero 'ensurepip' vive en el paquete python3.12-venv; por eso el
    # chequeo correcto es INTENTAR CREAR el venv (no "import venv") e instalar
    # el paquete si la creacion falla. Plan B: venv --without-pip + get-pip.py.
    [[ -x "$BOT_DIR/venv/bin/pip" ]] && return 0
    local PYVER PKGS ERRLOG="$BOT_DIR/venv-error.log"
    rm -rf "$BOT_DIR/venv"
    INFO "Creando entorno virtual..."
    if python3 -m venv "$BOT_DIR/venv" 2>"$ERRLOG" && [[ -x "$BOT_DIR/venv/bin/pip" ]]; then
        return 0
    fi
    PYVER=$(python3 -c 'import sys;print("{}.{}".format(*sys.version_info[:2]))' 2>/dev/null)
    PKGS="python3-venv python3-pip"
    [[ -n "$PYVER" ]] && PKGS="python${PYVER}-venv $PKGS"
    INFO "ensurepip falta: instalando $PKGS (puede tardar)..."
    apt update -y >/dev/null 2>&1
    bot_apt_instalar $PKGS || bot_apt_instalar python3-venv python3-pip || true
    rm -rf "$BOT_DIR/venv"
    if python3 -m venv "$BOT_DIR/venv" 2>>"$ERRLOG" && [[ -x "$BOT_DIR/venv/bin/pip" ]]; then
        OK "Entorno virtual creado."
        return 0
    fi
    # Plan B: venv sin pip + bootstrap de pip con get-pip.py
    rm -rf "$BOT_DIR/venv"
    if python3 -m venv --without-pip "$BOT_DIR/venv" 2>>"$ERRLOG" && [[ -x "$BOT_DIR/venv/bin/python" ]]; then
        INFO "Bootstrap de pip (get-pip.py)..."
        curl -fsSL --max-time 60 https://bootstrap.pypa.io/get-pip.py -o "$BOT_DIR/.get-pip.py" 2>>"$ERRLOG" \
            && "$BOT_DIR/venv/bin/python" "$BOT_DIR/.get-pip.py" >/dev/null 2>&1
        rm -f "$BOT_DIR/.get-pip.py"
        if [[ -x "$BOT_DIR/venv/bin/pip" ]]; then
            OK "Entorno virtual creado (pip via get-pip)."
            return 0
        fi
    fi
    ERR "No se pudo crear el venv. Diagnostico:"
    tail -n 4 "$ERRLOG" 2>/dev/null | sed 's/^/      /'
    INFO "Probá manual: apt install -y python${PYVER:-3.12}-venv python3-pip  y volvé a la opción 1."
    rm -rf "$BOT_DIR/venv"
    return 1
}

bot_telegram_instalar(){
    # Instalador del bot: python3 + venv + dependencias + datos + servicio systemd.
    echo -e "${CIAN}--- BOT DE TELEGRAM: INSTALAR / CONFIGURAR ---${NC}"
    # Todas las locales INICIALIZADAS: el panel corre con set -u y una local
    # vacia (OKF="") es la senal correcta del bucle del token (OKF=0 rompia el
    # [[ -z "$OKF" ]], saltaba el pedido del token y $BTK quedaba sin asignar).
    local BTK="" BCH="" R="" OKF="" RESP="" EST="" BOTNAME="" REINST=0 BOT_PYBIN=""
    # 1) python3 + entorno virtual con pip (bot_venv_crear instala lo que falte)
    if ! command -v python3 >/dev/null 2>&1; then
        INFO "Instalando python3..."
        apt update -y >/dev/null 2>&1; bot_apt_instalar python3
        command -v python3 >/dev/null 2>&1 || { ERR "No se pudo instalar python3."; PAUSA; return; }
    fi
    mkdir -p "$BOT_DIR"
    [[ -f /etc/systemd/system/ghost-bot.service ]] && REINST=1
    if bot_venv_crear; then
        BOT_PYBIN="$BOT_DIR/venv/bin/python"
    else
        # Plan C: Python del sistema + pip (Ubuntu 24.04 exige --break-system-packages)
        WARN "Sin venv usable: instalo con el Python del sistema."
        python3 -m pip --version >/dev/null 2>&1 || { apt update -y >/dev/null 2>&1; bot_apt_instalar python3-pip; }
        python3 -m pip --version >/dev/null 2>&1 || { ERR "No hay pip para python3 (apt install -y python3-pip)."; PAUSA; return; }
        BOT_PYBIN="$(command -v python3)"
    fi
    # 2) dependencias (version fija)
    INFO "Instalando python-telegram-bot 20.7 (1-2 min, no cierres)..."
    if [[ "$BOT_PYBIN" == "$BOT_DIR/venv/bin/python" ]]; then
        "$BOT_DIR/venv/bin/pip" install -q python-telegram-bot==20.7 \
            || { ERR "Fallo la instalacion de python-telegram-bot. Revisá la conexion y reintentá."; PAUSA; return; }
    else
        python3 -m pip install -q --break-system-packages python-telegram-bot==20.7 \
            || python3 -m pip install -q python-telegram-bot==20.7 \
            || { ERR "Fallo la instalacion de python-telegram-bot. Revisá la conexion y reintentá."; PAUSA; return; }
    fi
    "$BOT_PYBIN" -c "import telegram" 2>/dev/null \
        || { ERR "La libreria no se pudo importar."; PAUSA; return; }
    OK "python-telegram-bot instalado."
    # 4) BOT_TOKEN (conserva el actual si reinstall y se pide ENTER)
    local CUR_TOK CUR_CHAT INTENTOS=0
    CUR_TOK=$(bot_conf_get BOT_TOKEN)
    CUR_CHAT=$(bot_conf_get ADMIN_CHAT_ID)
    # Si ya pusiste Telegram en Trafico → Notificaciones, se ofrece ese mismo token/chat (ENTER lo conserva)
    [[ -n "$CUR_TOK" ]]  || CUR_TOK=$(ghost_conf_get TG_TOKEN)
    [[ -n "$CUR_CHAT" ]] || CUR_CHAT=$(ghost_conf_get TG_CHAT)
    while [[ -z "$OKF" ]] && (( INTENTOS < 5 )); do
        if [[ -n "$CUR_TOK" ]]; then
            read -r -p "Ya hay un token (…${CUR_TOK: -6}). ENTER lo conserva, otro lo reemplaza: " R
            BTK=$(echo "${R:-$CUR_TOK}" | tr -d '[:space:]')
        else
            read -r -p "BOT_TOKEN (el que te dio @BotFather): " BTK
            BTK=$(echo "$BTK" | tr -d '[:space:]')
        fi
        if [[ ! "$BTK" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]; then
            ERR "Formato invalido (ej: 123456789:AAE...)."
            INTENTOS=$((INTENTOS+1))
            continue
        fi
        RESP=$(curl -sS --max-time 8 "https://api.telegram.org/bot${BTK}/getMe" 2>/dev/null)
        if printf '%s' "$RESP" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
            OK "Token validado contra Telegram."
            BOTNAME=$(printf '%s' "$RESP" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("result",{}).get("username",""))
except Exception: print("")' 2>/dev/null)
            OKF=1
        elif [[ -n "$RESP" ]]; then
            ERR "Telegram rechazo el token (revocado o mal copiado)."
            INTENTOS=$((INTENTOS+1))
        else
            WARN "Sin respuesta de api.telegram.org; sigo con el formato (se valida al arrancar)."
            OKF=1
        fi
    done
    [[ -n "$OKF" ]] || { ERR "Token invalido tras varios intentos."; PAUSA; return; }
    # 5) ADMIN_CHAT_ID
    BCH=""
    if [[ -n "$CUR_CHAT" ]]; then
        read -r -p "ADMIN_CHAT_ID actual: ${CUR_CHAT}. ENTER lo conserva, otro lo reemplaza: " R
        BCH="${R:-$CUR_CHAT}"
    else
        read -r -p "ADMIN_CHAT_ID (tu chat_id numerico; ENTER = lo detecto solo): " BCH
    fi
    if [[ -z "$BCH" ]]; then
        INFO "Enviá CUALQUIER mensaje a tu bot ahora (espero hasta ~30 s)..."
        BCH=$(bot_detectar_chat "$BTK") || true
        [[ -n "$BCH" ]] || { ERR "No llegó ningún mensaje. Averiguá tu chat_id con @userinfobot y volvé a intentar."; PAUSA; return; }
        OK "chat_id detectado: $BCH"
    fi
    [[ "$BCH" =~ ^-?[0-9]{4,}$ ]] || { ERR "ADMIN_CHAT_ID invalido (ej: 123456789)."; PAUSA; return; }
    # 6) config.env (600)
    umask 077
    local _AB; _AB=$(bot_conf_get AUTOBORRAR_MIN)          # se conserva si ya lo habias cambiado
    printf 'BOT_TOKEN=%s\nADMIN_CHAT_ID=%s\n' "$BTK" "$BCH" > "$BOT_DIR/config.env"
    [[ "$_AB" =~ ^[0-9]+$ ]] && printf 'AUTOBORRAR_MIN=%s\n' "$_AB" >> "$BOT_DIR/config.env"
    chmod 600 "$BOT_DIR/config.env"
    umask 022
    # 7) bot.py + helper de banners + verificacion de sintaxis
    bot_telegram_escribir_py
    bot_refresh_helper
    if ! "$BOT_PYBIN" -m py_compile "$BOT_DIR/bot.py" 2>/dev/null; then
        ERR "El bot.py generado no compila (reportalo al desarrollador)."; PAUSA; return
    fi
    # 8) servicio systemd (ExecStart segun el interprete que quedo funcionando)
    cat > /etc/systemd/system/ghost-bot.service <<GBSVC
[Unit]
Description=Ghost Panel Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_PYBIN $BOT_DIR/bot.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
GBSVC
    systemctl daemon-reload
    systemctl enable --now ghost-bot >/dev/null 2>&1
    systemctl restart ghost-bot 2>/dev/null || true
    sleep 2
    EST=$(systemctl is-active ghost-bot 2>/dev/null || echo unknown)
    # 10) ficha de resultado
    if [[ "$EST" == "active" ]]; then
        ficha_ok "🤖 BOT DE TELEGRAM INSTALADO" \
            "Bot" "${BOTNAME:+@$BOTNAME}" \
            "Chat admin" "$BCH" \
            "Servicio" "ghost-bot (ACTIVO)" \
            "Directorio" "$BOT_DIR" \
            "Log" "/var/log/ghost-bot.log"
        INFO "Abrí el chat del bot en Telegram y mandale /start."
        WARN "Guarda la clave de backup FUERA del servidor: opcion 6 de este menu (Ver token y admin)."
        [[ $REINST -eq 1 ]] && INFO "Reinstalación: config y código actualizados, servicio reiniciado."
    else
        ficha_aviso "🤖 BOT INSTALADO (no levantó)" \
            "Servicio" "ghost-bot ($EST)" \
            "Directorio" "$BOT_DIR"
        INFO "Revisá: journalctl -u ghost-bot -n 20 --no-pager"
        INFO "Suele ser el token: corregilo con la opción 1 de este menú."
    fi
    PAUSA
}

bot_telegram_iniciar(){
    [[ -f "$BOT_DIR/bot.py" && -f /etc/systemd/system/ghost-bot.service ]] \
        || { ERR "El bot no está instalado (opción 1)."; PAUSA; return; }
    systemctl enable ghost-bot >/dev/null 2>&1
    systemctl start ghost-bot 2>/dev/null
    sleep 1
    if systemctl is-active --quiet ghost-bot 2>/dev/null; then
        ficha_ok "🚀 BOT INICIADO" "Servicio" "ghost-bot (ACTIVO)" "Log" "/var/log/ghost-bot.log"
    else
        ficha_mal "🚀 BOT NO PUDO INICIAR" "Servicio" "ghost-bot (detenido)"
        INFO "Revisá: journalctl -u ghost-bot -n 20 --no-pager"
    fi
    PAUSA
}

bot_telegram_detener(){
    [[ -f /etc/systemd/system/ghost-bot.service ]] \
        || { ERR "El bot no está instalado (opción 1)."; PAUSA; return; }
    systemctl stop ghost-bot 2>/dev/null
    systemctl disable ghost-bot >/dev/null 2>&1   # queda detenido aunque se reinicie el VPS
    ficha_ok "🛑 BOT DETENIDO" "Servicio" "ghost-bot (detenido)" "Al reiniciar el VPS" "sigue detenido"
    PAUSA
}

bot_telegram_reiniciar(){
    [[ -f /etc/systemd/system/ghost-bot.service ]] \
        || { ERR "El bot no está instalado (opción 1)."; PAUSA; return; }
    systemctl restart ghost-bot 2>/dev/null
    sleep 1
    if systemctl is-active --quiet ghost-bot 2>/dev/null; then
        ficha_ok "🔄 BOT REINICIADO" "Servicio" "ghost-bot (ACTIVO)"
    else
        ficha_mal "🔄 BOT NO LEVANTÓ" "Servicio" "ghost-bot (detenido)"
        INFO "Revisá: journalctl -u ghost-bot -n 20 --no-pager"
    fi
    PAUSA
}

bot_telegram_estado(){
    ficha_abrir "📊 ESTADO DEL BOT"
    if [[ ! -f "$BOT_DIR/bot.py" ]]; then
        ficha_fila "Instalación" "NO INSTALADO" "$ROJO"
        ficha_cerrar
        PAUSA; return
    fi
    local EST PID TOK CHAT
    if systemctl is-active --quiet ghost-bot 2>/dev/null; then
        PID=$(systemctl show -p MainPID --value ghost-bot 2>/dev/null)
        ficha_fila "Servicio" "ACTIVO 🟢  (PID ${PID:-?})" "$VERDE"
    elif [[ -f /etc/systemd/system/ghost-bot.service ]]; then
        ficha_fila "Servicio" "DETENIDO 🔴" "$ROJO"
    else
        ficha_fila "Servicio" "sin unidad systemd (reinstalá)" "$AMARILLO"
    fi
    ficha_fila "Directorio" "$BOT_DIR"
    TOK=$(bot_conf_get BOT_TOKEN)
    [[ -n "$TOK" ]] && ficha_fila "Token" "…${TOK: -6}"
    CHAT=$(bot_conf_get ADMIN_CHAT_ID)
    [[ -n "$CHAT" ]] && ficha_fila "Chat admin" "$CHAT"
    ficha_fila "Log" "/var/log/ghost-bot.log"
    ficha_cerrar
    if [[ -s /var/log/ghost-bot.log ]]; then
        echo "  Últimas líneas del log:"
        tail -n 4 /var/log/ghost-bot.log 2>/dev/null | sed 's/^/    /'
    fi
    PAUSA
}

bot_backup_key_migrar(){
    # La 4.0 guardaba la copia en /root/backups, junto a los backups: si copiabas esa carpeta a otro sitio, la
    # clave viajaba con ellos. Ahora vive aparte (/root/.ghost-panel). Mueve la vieja si existe.
    local VIEJA=/root/backups/ghost-bot-backup.key
    [[ -f "$VIEJA" ]] || return 0
    mkdir -p "$(dirname "$BOT_KEY_COPIA")" 2>/dev/null; chmod 700 "$(dirname "$BOT_KEY_COPIA")" 2>/dev/null
    [[ -s "$BOT_KEY_COPIA" ]] || install -m 600 "$VIEJA" "$BOT_KEY_COPIA" 2>/dev/null
    [[ -s "$BOT_KEY_COPIA" ]] && rm -f "$VIEJA"
    rmdir /root/backups 2>/dev/null
    return 0
}
bot_backup_key_respaldar(){
    # Copia (0600) de la clave de backup fuera de /opt/ghost-bot: desinstalar el bot ya no la borra.
    bot_backup_key_migrar
    [[ -s "$BOT_DIR/backup.key" ]] || return 0
    mkdir -p "$(dirname "$BOT_KEY_COPIA")" 2>/dev/null; chmod 700 "$(dirname "$BOT_KEY_COPIA")" 2>/dev/null
    cmp -s "$BOT_DIR/backup.key" "$BOT_KEY_COPIA" 2>/dev/null \
        || install -m 600 "$BOT_DIR/backup.key" "$BOT_KEY_COPIA" 2>/dev/null
    return 0
}

bot_backup_key_asegurar(){
    # Clave con la que el bot CIFRA los backups antes de mandarlos a Telegram (24 caracteres, 0600).
    # Si el bot se desinstalo antes, se RECUPERA de la copia: los backups viejos siguen abriendose.
    bot_backup_key_migrar
    mkdir -p "$BOT_DIR" 2>/dev/null
    if [[ ! -s "$BOT_DIR/backup.key" ]]; then
        if [[ -s "$BOT_KEY_COPIA" ]]; then
            install -m 600 "$BOT_KEY_COPIA" "$BOT_DIR/backup.key" 2>/dev/null
        else
            ( umask 077; head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24 > "$BOT_DIR/backup.key"; echo >> "$BOT_DIR/backup.key" )
        fi
    fi
    chmod 600 "$BOT_DIR/backup.key" 2>/dev/null
    bot_backup_key_respaldar
}

bot_telegram_ver(){
    if [[ ! -r "$BOT_DIR/config.env" ]]; then
        ERR "Sin configuración: instalá el bot (opción 1)."; PAUSA; return
    fi
    bot_backup_key_asegurar
    ficha_ok "🔑 DATOS DEL BOT" \
        "BOT_TOKEN" "$(bot_conf_get BOT_TOKEN)" \
        "ADMIN_CHAT_ID" "$(bot_conf_get ADMIN_CHAT_ID)" \
        "Clave de backup" "$(head -n1 "$BOT_DIR/backup.key" 2>/dev/null)" \
        "Auto-borrar claves" "$(_ab=$(bot_conf_get AUTOBORRAR_MIN); echo "${_ab:-5} min (AUTOBORRAR_MIN en config.env; 0 = nunca)")" \
        "Config" "$BOT_DIR/config.env"
    INFO "El token y la clave de backup son SECRETOS: no los compartas."
    INFO "El backup que el bot manda por Telegram va CIFRADO con esa clave (la clave nunca viaja por Telegram)."
    INFO "Para abrirlo: openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in ARCHIVO.enc -out backup.tar.gz"
    WARN "GUARDA la clave de backup FUERA del servidor (gestor de contraseñas). Sin ella ningun backup se abre."
    WARN "Si pierdes la VPS, la clave se pierde con ella: la copia de $BOT_KEY_COPIA tambien esta en este servidor."
    PAUSA
}

bot_telegram_probar(){
    local T C RESP
    T=$(bot_conf_get BOT_TOKEN); C=$(bot_conf_get ADMIN_CHAT_ID)
    [[ -n "$T" && -n "$C" ]] || { ERR "Sin configuración: instalá el bot (opción 1)."; PAUSA; return; }
    INFO "Enviando mensaje de prueba..."
    RESP=$(curl -sS --max-time 10 -X POST "https://api.telegram.org/bot${T}/sendMessage" \
        -d "chat_id=${C}" -d "parse_mode=HTML" \
        --data-urlencode "text=🧪 <b>Ghost Panel</b> · mensaje de prueba.
Si leés esto, el bot funciona." 2>&1)
    if printf '%s' "$RESP" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
        ficha_ok "🧪 MENSAJE DE PRUEBA" "Envío" "ENTREGADO ✅" "Chat" "$C"
    else
        ficha_mal "🧪 MENSAJE DE PRUEBA" "Envío" "FALLÓ"
        printf '    %s\n' "${RESP:0:200}"
        INFO "Si dice 'chat not found': mandale /start al bot y verificá el ADMIN_CHAT_ID (opción 1)."
    fi
    PAUSA
}

bot_telegram_desinstalar_silencioso(){
    # Sin preguntas (tambien la usa el desinstalador completo del panel).
    systemctl disable --now ghost-bot >/dev/null 2>&1
    rm -f /etc/systemd/system/ghost-bot.service
    systemctl daemon-reload 2>/dev/null
    bot_backup_key_respaldar        # la clave NO se pierde: los backups ya enviados a Telegram siguen abriendose
    rm -rf "$BOT_DIR"
    rm -f /var/log/ghost-bot.log
    return 0
}

bot_telegram_desinstalar(){
    [[ -f "$BOT_DIR/bot.py" || -f /etc/systemd/system/ghost-bot.service ]] \
        || { ERR "El bot no está instalado."; PAUSA; return; }
    local R
    read -r -p "¿Desinstalar el bot? Se borra $BOT_DIR y el servicio ghost-bot; la clave de backup se conserva (s/N): " R
    [[ "$R" =~ ^[sSyY]$ ]] || { INFO "Cancelado."; PAUSA; return; }
    bot_telegram_desinstalar_silencioso
    ficha_ok "🗑️ BOT DESINSTALADO" "Servicio" "eliminado" "Archivos" "$BOT_DIR borrado" "Log" "borrado" "Clave de backup" "conservada en $BOT_KEY_COPIA"
    INFO "Al reinstalar el bot se recupera esa clave. Guardala tambien FUERA del servidor."
    PAUSA
}

menu_bot_telegram(){
    local EST_LINEA
    while true; do
        cabecera
        SUBTOP "$(T t_sub_bot)"
        if systemctl is-active --quiet ghost-bot 2>/dev/null; then
            EST_LINEA="${VERDE}🤖 Bot ACTIVO${NC}"
        elif [[ -f /etc/systemd/system/ghost-bot.service ]]; then
            EST_LINEA="${ROJO}🤖 Bot DETENIDO${NC}"
        else
            EST_LINEA="${GRIS}🤖 Bot NO INSTALADO${NC}"
        fi
        FR_OPT 1 "📥 $(T t_bot_inst)"    5 "📊 $(T t_bot_estado)"
        FR_OPT 2 "🚀 $(T t_bot_iniciar)" 6 "🔑 $(T t_bot_ver)"
        FR_OPT 3 "🛑 $(T t_bot_detener)" 7 "🧪 $(T t_bot_test)"
        FR_OPT 4 "🔄 $(T t_bot_reiniciar)" 8 "🗑️ $(T t_bot_desinst)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_TXT "  $EST_LINEA"
        FR_BOT
        PROMPT
        case "$OP" in
            1) bot_telegram_instalar ;;
            2) bot_telegram_iniciar ;;
            3) bot_telegram_detener ;;
            4) bot_telegram_reiniciar ;;
            5) bot_telegram_estado ;;
            6) bot_telegram_ver ;;
            7) bot_telegram_probar ;;
            8) bot_telegram_desinstalar ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}
bot_telegram_menu(){ menu_bot_telegram "$@"; }   # alias (nombre alternativo del submenu)

trafico_notif_corte(){
    # trafico_notif_corte USUARIO GB_USADOS
    local U="$1" G="$2" IP SOP
    IP=$(ip_publica 2>/dev/null || echo "?")
    SOP=$(ghost_conf_get SUPPORT); SOP=${SOP:-@JorgeBarrios}
    notif_enviar "🚫 <b>CUOTA AGOTADA</b>
👤 <code>${U}</code>
📦 Límite: ${G} GB
🌍 Servidor: ${IP}
⛔ Bloqueado (SSH + Xray)
🆘 Soporte: ${SOP}"
}

# ---- Historial diario de consumo ----
# HIST_DIR se define localmente en trafico_hist_*
trafico_hist_registrar(){
    # Registra snapshot diario por usuario (se llama desde auto-ciclo)
    local U USED HOY HDIR='/var/log/ghost-trafico-hist'
    HOY=$(date +%Y-%m-%d)
    mkdir -p "$HDIR"
    for U in "${!TRAF_CACHE[@]}"; do
        USED=${TRAF_CACHE[$U]:-0}
        if [[ -f "$HDIR/$U" ]] && grep -q "^${HOY}|" "$HDIR/$U" 2>/dev/null; then
            sed -i "s#^${HOY}|.*#${HOY}|${USED}#" "$HDIR/$U"
        else
            echo "${HOY}|${USED}" >> "$HDIR/$U"
        fi
        tail -n 60 "$HDIR/$U" > "$HDIR/$U.tmp" 2>/dev/null && mv "$HDIR/$U.tmp" "$HDIR/$U"
    done
}

trafico_hist_ver(){
    local U DIAS=14 FECHA BYTES HDIR='/var/log/ghost-trafico-hist'
    pedir_usuario_ok U || { PAUSA; return; }
    if [[ ! -f "$HDIR/$U" ]]; then
        WARN "Sin historial para $U (se genera con el auto-corte activo)."
        PAUSA; return
    fi
    ficha_abrir "📅 HISTORIAL DE CONSUMO · $U"
    printf "%-12s  %s\n" "FECHA" "CONSUMO"
    tail -n "$DIAS" "$HDIR/$U" | while IFS='|' read -r FECHA BYTES; do
        printf "%-12s  %s\n" "$FECHA" "$(fmt_bytes "$BYTES")"
    done
    ficha_cerrar
    PAUSA
}

trafico_bloquear_excedidos(){
    # Bloquea cuenta Linux + elimina de Xray + marca estado + notifica.
    # Imprime "USUARIO GB" por cada bloqueo nuevo.
    # Llamar con la cache cargada (trafico_cache_cargar; TRAF_BATCH=1).
    local F U G
    for F in /etc/vps-trafico/*; do
        [[ -f "$F" ]] || continue
        U=$(basename "$F"); id "$U" >/dev/null 2>&1 || continue
        usuario_protegido "$U" && continue
        trafico_excedido "$U" || continue
        # ya bloqueado por cuota o por passwd -L
        if trafico_esta_por_cuota "$U"; then continue; fi
        if passwd -S "$U" 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
            # estaba bloqueado manualmente; igual marcamos por cuota si excedio
            :
        fi
        G=$(tr -dc '0-9' 2>/dev/null < "$F"); G=${G:0:6}
        # 1) Bloquear cuenta Linux y matar sesiones
        usermod -L "$U" 2>/dev/null
        pkill -KILL -u "$U" 2>/dev/null
        # 2) Quitar de Xray (VLESS / VMess / Trojan)
        xray_usuario del "$U" >/dev/null 2>&1
        # 3) Marcar estado
        trafico_marcar_cuota "$U" "${G:-0}"
        # 4) Notificar (Telegram manual y/o Bot instalado, Discord, WhatsApp): un solo envio por canal
        trafico_notif_corte "$U" "${G:-?}"
        echo "$U ${G:-?}"
    done
}

trafico_cortar(){
    local CORTADOS=0 U G NOMBRES=""
    trafico_cache_cargar; TRAF_BATCH=1
    while read -r U G; do
        [[ -n "$U" ]] || continue
        vps_log INFO "cuota excedida, bloqueado completo: $U (${G}GB)"
        NOMBRES+="${NOMBRES:+, }$U (${G}GB)"
        CORTADOS=$((CORTADOS+1))
    done < <(trafico_bloquear_excedidos)
    TRAF_BATCH=0
    if [[ $CORTADOS -eq 0 ]]; then ficha_ok "🚫 CORTE POR CUOTA" "Bloqueados" "0 (nadie superó su límite)"
    else ficha_mal "🚫 CORTE POR CUOTA" "Bloqueados (SSH+Xray)" "$CORTADOS" "Usuarios" "$NOMBRES"; fi
    banner_todos_actualizar >/dev/null 2>&1 || true
    PAUSA
}

# ---- Auto-corte: un ciclo = bloquear excedidos + historial + regenerar banners ----
trafico_auto_ciclo(){
    local U G
    trafico_cache_cargar; TRAF_BATCH=1
    while read -r U G; do
        [[ -n "$U" ]] || continue
        vps_log INFO "auto-corte: $U supero ${G}GB, bloqueado (SSH+Xray)"
    done < <(trafico_bloquear_excedidos)
    trafico_hist_registrar
    while read -r U; do
        usuario_protegido "$U" && continue
        banner_usuario_actualizar "$U"
    done < <(usuarios_panel)
    TRAF_BATCH=0
}

trafico_cron_instalar(){
    # Genera /usr/local/bin/vps-trafico-cron.sh COPIANDO las funciones de este script (declare -f):
    # no duplica codigo, no ejecuta el panel completo (sin validacion de licencia ni menus).
    # Se regenera en cada arranque del panel para que siempre coincida con la version instalada.
    local FN MIN="${1:-}"
    # Frecuencia: la pasada por parametro, o la que ya tenia el cron, o 1 minuto
    [[ -n "$MIN" ]] || MIN=$(trafico_auto_min)
    [[ "$MIN" =~ ^(1|5|10)$ ]] || MIN=5
    {
        echo '#!/bin/bash'
        echo '# Generado por Ghost Panel (trafico_cron_instalar). No editar: se regenera solo.'
        echo 'export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin LC_ALL=C.UTF-8'
        echo 'exec 9>/run/ghost-trafico.lock; flock -n 9 || exit 0      # sin ciclos solapados'
        declare -p BANNERS_DIR LOG_PANEL PROTEGIDOS_NOMBRES BOT_DIR
        echo 'declare -A TRAF_CACHE=(); TRAF_BATCH=0'
        for FN in vps_log usuario_protegido usuarios_panel ui_rep fmt_bytes xray_stats_todos trafico_cache_cargar \
                  trafico_usuario_bytes trafico_excedido trafico_bloquear_excedidos trafico_marcar_cuota \
                  trafico_esta_por_cuota trafico_notif_corte notif_enviar bot_conf_get tg_destinos trafico_hist_registrar \
                  xray_usuario xray_recargar xray_ensure_api xray_config_perms xray_grupo \
                  usuario_fecha_cuenta dias_hasta ghost_conf_get ip_publica \
                  banner_barra banner_seg banner_sep banner_hora banner_l_gruesa banner_l_fina \
                  banner_p banner_fila banner_soporte_txt banner_soporte_fila banner_html_para_usuario \
                  banner_usuario_actualizar trafico_auto_ciclo; do
            declare -f "$FN"
        done
        echo 'trafico_auto_ciclo'
    } > /usr/local/bin/vps-trafico-cron.sh
    chmod 755 /usr/local/bin/vps-trafico-cron.sh
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n*/%s * * * * root nice -n 15 ionice -c3 /usr/local/bin/vps-trafico-cron.sh\n' "$MIN" > /etc/cron.d/ghost-panel-trafico
    chmod 644 /etc/cron.d/ghost-panel-trafico
}

trafico_auto_min(){ awk '/^\*\/[0-9]+ /{sub(/^\*\//,"",$1); print $1; exit}' /etc/cron.d/ghost-panel-trafico 2>/dev/null; }

trafico_auto_pedir_min(){
    # trafico_auto_pedir_min VARIABLE -> pregunta 1/5/10 minutos (por defecto 5)
    local _m
    read -r -p "  Cada cuantos minutos refrescar banners y revisar cuotas? (1/5/10) [5]: " _m
    [[ "$_m" =~ ^(1|5|10)$ ]] || _m=5
    printf -v "$1" '%s' "$_m"
}

trafico_auto_toggle(){
    local OPC MIN
    echo -e "${CIAN}--- AUTO-CORTE ---${NC}"
    if [[ -f /etc/cron.d/ghost-panel-trafico ]]; then
        echo "  Activo: cada $(trafico_auto_min) min."
        echo "  [1] Cambiar frecuencia    [2] Desactivar    [0] Cancelar"
        read -r -p "  > " OPC
        case "$OPC" in
            1) trafico_auto_pedir_min MIN; trafico_cron_instalar "$MIN"
               ficha_ok "🤖 AUTO-CORTE" "Frecuencia" "cada $MIN min"; vps_log INFO "auto-corte cada $MIN min" ;;
            2) rm -f /etc/cron.d/ghost-panel-trafico /usr/local/bin/vps-trafico-cron.sh /run/ghost-trafico.lock
               ficha_ok "🤖 AUTO-CORTE" "Estado" "desactivado" "Banners" "se actualizan solo con el panel"
               vps_log INFO "auto-corte desactivado" ;;
            *) INFO "Sin cambios." ;;
        esac
    else
        trafico_auto_pedir_min MIN
        trafico_cron_instalar "$MIN"
        /usr/local/bin/vps-trafico-cron.sh >/dev/null 2>&1       # primer ciclo ahora mismo
        ficha_ok "🤖 AUTO-CORTE ACTIVO" "Frecuencia" "cada $MIN min" "Acción" "bloquea excedidos y refresca banners" "Bloqueo" "SSH + Xray (VLESS/VMess/Trojan)"
        INFO "Activa antes los contadores (opción 1) para que el tráfico SSH cuente."
        vps_log INFO "auto-corte activado cada $MIN min"
    fi
    PAUSA
}
trafico_reset_usuario(){
    # Pone a cero el contador iptables de UN usuario (borra y recrea la regla del UID)
    local U="$1" UIDN
    UIDN=$(id -u "$U" 2>/dev/null) || return 1
    if ! iptables -L VPS-TRAFFIC -n >/dev/null 2>&1; then
        ERR "Cadena VPS-TRAFFIC no activa."; return 1
    fi
    while iptables -D VPS-TRAFFIC -m owner --uid-owner "$UIDN" -j RETURN 2>/dev/null; do :; done
    iptables -A VPS-TRAFFIC -m owner --uid-owner "$UIDN" -j RETURN 2>/dev/null || true
    ficha_ok "🔄 CONTADOR EN CERO" "Usuario" "$U" "iptables" "en cero"
    return 0
}

trafico_reset(){
    # Reset global o individual
    local OPC U SN
    echo -e "${CIAN}--- RESET CONTADORES ---${NC}"
    echo "  [1] Reset GLOBAL (todos los usuarios)"
    echo "  [2] Reset de UN usuario"
    echo "  [0] Cancelar"
    read -r -p "  > " OPC
    case "$OPC" in
        1)
            echo "  · iptables (SSH): se ponen a cero para TODOS."
            echo "  · Xray: stats en memoria; solo se limpian reiniciando el servicio."
            read -r -p "  Continuar con reset GLOBAL de iptables? (s/n): " SN
            [[ "$SN" == "s" || "$SN" == "S" ]] || { INFO "Cancelado."; PAUSA; return; }
            if iptables -L VPS-TRAFFIC -n >/dev/null 2>&1; then
                iptables -Z VPS-TRAFFIC 2>/dev/null && ficha_ok "🔄 CONTADORES EN CERO" "Alcance" "todos los usuarios" "iptables" "en cero" || ERR "No se pudo hacer iptables -Z."
            else
                WARN "Cadena VPS-TRAFFIC no activa (activa contadores en Tráfico -> [1])."
            fi
            if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
                read -r -p "  ¿Reiniciar Xray para limpiar también sus stats? (s/n): " SN
                if [[ "$SN" == "s" || "$SN" == "S" ]]; then
                    systemctl restart xray 2>/dev/null && ficha_ok "🚀 XRAY REINICIADO" "Stats" "a cero" || ERR "No se pudo reiniciar Xray."
                fi
            fi
            ;;
        2)
            pedir_usuario_ok U || { PAUSA; return; }
            trafico_reset_usuario "$U"
            INFO "Nota: las stats de Xray de este usuario solo se limpian reiniciando Xray (global)."
            read -r -p "  ¿Reiniciar Xray ahora? (s/n): " SN
            if [[ "$SN" == "s" || "$SN" == "S" ]]; then
                systemctl restart xray 2>/dev/null && ficha_ok "🚀 XRAY REINICIADO" "Stats" "a cero" || ERR "No se pudo reiniciar Xray."
            fi
            ;;
        *) INFO "Cancelado." ;;
    esac
    banner_todos_actualizar >/dev/null 2>&1 || true
    PAUSA
}

trafico_desbloquear_cuota(){
    # Desbloquea un usuario cortado por cuota: usermod -U + re-agrega a Xray + opcional subir GB + reset contador
    local U G NEWG SN R_CUENTA R_CUOTA R_XRAY
    echo -e "${CIAN}--- DESBLOQUEAR POR CUOTA ---${NC}"
    # Listar los que estan marcados por cuota
    if compgen -G "/etc/vps-cuota-agotada/*" >/dev/null; then
        echo "  Usuarios con cuota agotada:"
        for F in /etc/vps-cuota-agotada/*; do
            [[ -f "$F" ]] || continue
            printf "    · %s\n" "$(basename "$F")"
        done
        echo
    else
        INFO "No hay usuarios marcados por cuota agotada."
    fi
    pedir_usuario_ok U || { PAUSA; return; }
    if ! trafico_esta_por_cuota "$U" && ! passwd -S "$U" 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
        WARN "$U no parece bloqueado por cuota ni por passwd -L."
        read -r -p "  Continuar de todos modos? (s/n): " SN
        [[ "$SN" == "s" || "$SN" == "S" ]] || { PAUSA; return; }
    fi
    G=$(tr -dc '0-9' 2>/dev/null < "/etc/vps-trafico/$U"); G=${G:0:6}; G=${G:-0}
    echo -e "  Cuota actual: ${BLANCO}${G} GB${NC}"
    read -r -p "  Nueva cuota en GB (Enter = mantener $G, 0 = sin limite): " NEWG
    if [[ -z "$NEWG" ]]; then NEWG=$G; fi
    if ! [[ "$NEWG" =~ ^[0-9]{1,6}$ ]]; then ERR "Valor invalido."; PAUSA; return; fi
    NEWG=$((10#$NEWG))
    # 1) Desbloquear cuenta
    usermod -U "$U" 2>/dev/null && R_CUENTA="desbloqueada" || R_CUENTA="ERROR: no se pudo desbloquear"
    # 2) Actualizar cuota
    if (( NEWG > 0 )); then
        mkdir -p /etc/vps-trafico
        echo "$NEWG" > "/etc/vps-trafico/$U"
        R_CUOTA="${NEWG} GB"
    else
        rm -f "/etc/vps-trafico/$U"
        R_CUOTA="sin límite"
    fi
    # 3) Re-agregar a Xray
    xray_usuario add "$U" >/dev/null 2>&1 && R_XRAY="re-agregado" || R_XRAY="no se pudo (¿Xray instalado?)"
    # 4) Reset contador del usuario
    trafico_reset_usuario "$U" >/dev/null 2>&1 || true
    # 5) Limpiar marca
    trafico_limpiar_marca_cuota "$U"
    # 6) Banner
    banner_usuario_actualizar "$U" >/dev/null 2>&1 || true
    banner_rebuild_match 2>/dev/null || true
    vps_log INFO "desbloqueado por cuota: $U (nueva cuota ${NEWG}GB)"
    ficha_abrir "🔓 USUARIO DESBLOQUEADO" "$VERDE"
    ficha_fila "Usuario" "$U" "$VERDE"
    ficha_fila "Cuenta" "$R_CUENTA"
    ficha_fila "Cuota" "$R_CUOTA"
    ficha_fila "Xray" "$R_XRAY"
    ficha_fila "Contador" "en cero"
    ficha_fila "Estado" "puede volver a conectar" "$VERDE"
    ficha_cerrar
    PAUSA
}

tg_pedir_manual(){
    # Token + chat para un Telegram MANUAL (solo si no usas el Bot instalado, o quieres otro destino ADEMAS)
    local CUR T C
    CUR=$(ghost_conf_get TG_TOKEN)
    read -r -p "  Bot Token${CUR:+ [ya configurado]}: " T; T=${T:-$CUR}
    CUR=$(ghost_conf_get TG_CHAT)
    read -r -p "  Chat ID${CUR:+ [$CUR]}: " C; C=${C:-$CUR}
    [[ -n "$T" ]] && ghost_conf_set TG_TOKEN "$T"
    [[ -n "$C" ]] && ghost_conf_set TG_CHAT "$C"
    ficha_ok "📣 TELEGRAM MANUAL CONFIGURADO" "Chat ID" "$(ghost_conf_get TG_CHAT)" "Bot token" "$([[ -n "$(ghost_conf_get TG_TOKEN)" ]] && echo '********' || echo '(vacío)')"
}

trafico_notif_config(){
    local OPC OPC2 CUR H P K _h _k _e CAN
    _e=$(tg_estado)
    echo -e "${CIAN}--- NOTIFICACIONES DE CUOTA ---${NC}"
    echo "  Se envian al auto-cortar o al cortar manualmente por cuota."
    case "$_e" in
        bot|ambos) echo -e "  ${VERDE}✔ Telegram ya funciona con tu Bot instalado (opción 9 del menú principal).${NC}" ;;
        manual)    echo -e "  ${VERDE}✔ Telegram manual configurado.${NC}" ;;
        *)         echo -e "  ${AMARILLO}Telegram sin configurar.${NC} ${GRIS}Si instalas el Bot (opción 9) se usa solo.${NC}" ;;
    esac
    echo
    echo "  [1] Telegram"
    echo "  [2] Discord (webhook URL)"
    echo "  [3] WhatsApp CallMeBot (telefono + apikey)"
    echo "  [4] Probar envio"
    echo "  [5] Ver configuracion actual"
    echo "  [0] Volver"
    read -r -p "  > " OPC
    case "$OPC" in
        1)
            if [[ "$_e" == bot || "$_e" == ambos ]]; then
                ficha_abrir "📣 TELEGRAM · BOT INSTALADO" "$VERDE"
                ficha_fila "Origen" "Bot de Telegram (opción 9)"
                ficha_fila "Chat ID" "$(bot_conf_get ADMIN_CHAT_ID)"
                ficha_fila "Estado" "se usa solo, sin pedir token" "$VERDE"
                ficha_cerrar
                echo "  [1] Dejarlo así (recomendado)"
                echo "  [2] Enviar ADEMÁS a otro bot/chat"
                [[ -n "$(ghost_conf_get TG_TOKEN)" ]] && echo "  [3] Quitar el Telegram manual (usar solo el Bot)"
                read -r -p "  > " OPC2
                case "$OPC2" in
                    2) tg_pedir_manual ;;
                    3) if [[ -n "$(ghost_conf_get TG_TOKEN)" ]]; then
                           ghost_conf_del TG_TOKEN; ghost_conf_del TG_CHAT
                           ficha_ok "📣 TELEGRAM" "Origen" "solo el Bot instalado"
                       fi ;;
                    *) INFO "Sin cambios." ;;
                esac
            else
                tg_pedir_manual
                INFO "Tip: con el Bot instalado (opción 9 del menú principal) no hace falta configurar esto."
            fi
            ;;
        2)
            CUR=$(ghost_conf_get DISCORD_HOOK)
            read -r -p "  Webhook URL${CUR:+ [ya configurado]}: " H
            if [[ -n "$H" ]]; then ghost_conf_set DISCORD_HOOK "$H"; ficha_ok "📣 DISCORD CONFIGURADO" "Webhook" "guardado"; else INFO "Sin cambios."; fi
            ;;
        3)
            echo "  CallMeBot: obtene apikey en https://www.callmebot.com/blog/free-api-whatsapp-messages/"
            CUR=$(ghost_conf_get WA_PHONE)
            read -r -p "  Telefono con codigo pais (ej 54911xxxxxxx)${CUR:+ [$CUR]}: " P; P=${P:-$CUR}
            CUR=$(ghost_conf_get WA_APIKEY)
            read -r -p "  API Key${CUR:+ [ya configurada]}: " K; K=${K:-$CUR}
            [[ -n "$P" ]] && ghost_conf_set WA_PHONE "$P"
            [[ -n "$K" ]] && ghost_conf_set WA_APIKEY "$K"
            ficha_ok "📣 WHATSAPP CONFIGURADO" "Teléfono" "$(ghost_conf_get WA_PHONE)" "API Key" "$([[ -n "$(ghost_conf_get WA_APIKEY)" ]] && echo '********' || echo '(vacío)')"
            ;;
        4)
            CAN=$(notif_canales_txt)
            if [[ -z "$CAN" ]]; then
                ERR "No hay ningún canal configurado (Telegram, Discord o WhatsApp)."
            else
                INFO "Enviando mensaje de prueba..."
                notif_enviar "🧪 Prueba Ghost Panel — notificaciones de cuota OK ($(date '+%F %T'))"
                ficha_ok "📣 PRUEBA ENVIADA" "Canales" "$CAN" "Si no llega" "revisa token / webhook / apikey"
            fi
            ;;
        5)
            _h=$(ghost_conf_get DISCORD_HOOK); _k=$(ghost_conf_get WA_APIKEY)
            ficha_abrir "📣 NOTIFICACIONES DE CUOTA"
            ficha_fila "Telegram" "$(tg_estado_txt)"
            ficha_fila "Discord webhook" "$([[ -n "$_h" ]] && echo "${_h:0:30}..." || echo '(vacío)')"
            ficha_fila "WhatsApp teléfono" "$(ghost_conf_get WA_PHONE | grep . || echo '(vacío)')"
            ficha_fila "WhatsApp API Key" "$([[ -n "$_k" ]] && echo '********' || echo '(vacío)')"
            ficha_cerrar
            ;;
        *) ;;
    esac
    PAUSA
}

menu_trafico(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_trafico)"
        FR_OPT 1 "📶 $(T t_tr_activar)" 4 "🚫 $(T t_tr_cortar)"
        FR_OPT 2 "📈 $(T t_tr_ver)" 5 "🔄 $(T t_tr_reset)"
        FR_OPT 3 "🚦 $(T t_tr_limite)" 6 "🤖 $(T t_tr_auto)"
        FR_OPT 7 "🔓 $(T t_tr_desbloq)" 8 "📣 $(T t_tr_notif)"
        FR_OPT 9 "📅 $(T t_tr_hist)" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        if [[ -f /etc/cron.d/ghost-panel-trafico ]]; then FR_TXT "  ${VERDE}🤖 $(T t_tr_auto_on) $(trafico_auto_min) min${NC}"
        else FR_TXT "  ${GRIS}🤖 $(T t_tr_auto_off)${NC}"; fi
        FR_BOT
        PROMPT
        case "$OP" in
            1) trafico_activar ;;
            2) trafico_ver ;;
            3) trafico_limite ;;
            4) trafico_cortar ;;
            5) trafico_reset ;;
            6) trafico_auto_toggle ;;
            7) trafico_desbloquear_cuota ;;
            8) trafico_notif_config ;;
            9) trafico_hist_ver ;;
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
        ficha_ok "💽 SWAP ACTIVA" "Tamaño" "${G} GB" "Archivo" "/swapfile" "Persistente" "sí (/etc/fstab)"
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
    if ! pedir_puerto HP "Puerto UDP [8443]: " "8443" udp; then PAUSA; return; fi
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
        ficha_abrir "⚡ HYSTERIA2 INSTALADO"
        ficha_fila "Estado" "corriendo" "$VERDE"
        ficha_fila "IP / Host" "$IP"
        ficha_fila "Puerto UDP" "$HP/udp"
        ficha_fila "Contraseña" "$PASS" "$VERDE"
        ficha_cerrar
        printf '%bEnlace para el cliente (NekoBox / tu app):%b\n%b%s%b\n' "$AMARILLO" "$NC" "$VERDE" "hysteria2://$PASS@$IP:$HP/?insecure=1#VPS-JORGEBARRIOS" "$NC"
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
    ficha_aviso "📥 BACKUP RESTAURADO" "Archivo" "$F" "Recomendado" "reiniciar el VPS (Sistema → Reiniciar VPS)"
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
    if ! pedir_puerto BP "Puerto UDP GW [7300]: " "7300" tcp; then PAUSA; return; fi

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
        ficha_abrir "🎮 BADVPN (UDP GW) ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "UDP Gateway" "127.0.0.1:${BP}" "$VERDE"
        ficha_fila "Uso" "a través del túnel SSH/SSL"
        ficha_cerrar
        INFO "En la app del cliente (HTTP Injector / eProxy / tu app) pon ese UDP Gateway."
        INFO "Con eso funcionan juegos UDP y llamadas de WhatsApp/Telegram."
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
    ficha_ok "🎮 BADVPN REMOVIDO" "Servicio" "detenido" "Binario" "eliminado"
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
    if ! pedir_puerto WP "Puerto WS [8080]: " "8080" tcp; then PAUSA; return; fi
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
    xray_recargar 2>/dev/null
    sleep 1
    local IP; IP=$(ip_publica)
    if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
        ficha_abrir "🌐 XRAY WS INSTALADO"
        ficha_fila "Estado" "corriendo" "$VERDE"
        ficha_fila "Protocolo" "VLESS + WebSocket"
        ficha_fila "IP / Host" "$IP"
        ficha_fila "Puerto" "$WP/tcp"
        ficha_fila "Path" "$WPATH"
        ficha_cerrar
        printf '%bEnlace VLESS + WebSocket (ponlo detrás de Cloudflare):%b\n%b%s%b\n' "$AMARILLO" "$NC" "$VERDE" "vless://$UUID@$IP:$WP?type=ws&path=%2F${WPATH#/}&security=none#VPSJB-WS" "$NC"
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
    if ! pedir_puerto EP "Puerto WS [80]: " "80" tcp; then PAUSA; return; fi
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
        ficha_abrir "🌐 WS-EPRO ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "Servidor WS" "$IP:$EP" "$VERDE"
        ficha_fila "Destino SSH" "127.0.0.1:$SSHP"
        ficha_fila "Path" "cualquiera"
        ficha_cerrar
        INFO "Cliente (HTTP Custom / HTTP Injector): payload con Upgrade: websocket, o WebSocket estándar."
    else
        ERR "El proxy WS no levanto. Revisa: journalctl -u vpsjb-ws"
    fi
    PAUSA
}

# ------------------------------------------------------------
# ADBLOCK - AdGuard Home (DNS filter, seguro para VPS)
# No abre el puerto 53 al mundo: solo localhost + interfaz WireGuard.
# ------------------------------------------------------------
adguard_instalado(){
    [[ -x /opt/AdGuardHome/AdGuardHome ]] || command -v AdGuardHome >/dev/null 2>&1
}

adguard_activo(){
    # SOLO systemctl: el install.sh deja un proceso temporal que engaña a pgrep
    # y el panel marcaba ACTIVO aunque el unit estuviera dead/failed.
    systemctl is-active --quiet AdGuardHome 2>/dev/null
}

adguard_esperar_activo(){
    # Espera hasta N segundos a que el servicio quede arriba
    local i n="${1:-15}"
    for ((i=1; i<=n; i++)); do
        if adguard_activo; then return 0; fi
        sleep 1
    done
    return 1
}

adguard_ip_disponible(){
    # true solo si la IP esta asignada a alguna interfaz (no basta con que exista wg0.conf)
    local ip="$1"
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$ip"
}

adguard_escribir_config(){
    # DNS solo en IPs que EXISTEN ahora: 127.0.0.1 siempre; 10.66.0.1 solo si WireGuard
    # tiene esa direccion activa. Bind a IP inexistente = "cannot assign requested address" = crash.
    local CFG="${1:-/opt/AdGuardHome/AdGuardHome.yaml}" hosts
    hosts='    - 127.0.0.1'
    if adguard_ip_disponible "10.66.0.1"; then
        hosts+=$'\n    - 10.66.0.1'
    fi
    mkdir -p "$(dirname "$CFG")"
    # TLS (Dominio y SSL): DNS-over-TLS interno con el certificado de /etc/ghost-ssl. HTTPS de la UI
    # desactivado (port_https: 0) para no chocar con el 443. GHOST_SSL_OFF=1 lo omite (rollback).
    local TLS_BLOCK="" TDOM
    TDOM=$(awk -F= '$1=="DOMINIO"{print $2; exit}' /etc/ghost-ssl/domain.conf 2>/dev/null)
    if [[ -n "$TDOM" && -z "${GHOST_SSL_OFF:-}" && -f /etc/ghost-ssl/fullchain.pem ]]; then
        TLS_BLOCK=$'tls:\n  enabled: true\n  server_name: '"$TDOM"$'\n  force_https: false\n  port_https: 0\n  port_dns_over_tls: 853\n  port_dns_over_quic: 0\n  certificate_path: /etc/ghost-ssl/fullchain.pem\n  private_key_path: /etc/ghost-ssl/privkey.pem\n'
    fi
    # Preservar users del wizard si ya existen
    local USERS_BLOCK=""
    if [[ -f "$CFG" ]] && grep -q '^users:' "$CFG" 2>/dev/null; then
        USERS_BLOCK=$(awk '
            /^users:/{p=1}
            p{
                if (/^[a-zA-Z]/ && !/^users:/ && !/^[[:space:]]/){exit}
                print
            }
        ' "$CFG")
    fi
    # Config minima y estable (sin schema_version fijo: AdGuard lo migra solo)
    cat > "$CFG" <<AGEOF
http:
  address: 127.0.0.1:3000
dns:
  bind_hosts:
${hosts}
  port: 53
  upstream_dns:
    - 1.1.1.1
    - 8.8.8.8
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  protection_enabled: true
  parental_enabled: false
  ratelimit: 20
${TLS_BLOCK}filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
AGEOF
    if [[ -n "$USERS_BLOCK" ]]; then
        printf '\n%s\n' "$USERS_BLOCK" >> "$CFG"
    fi
    chmod 644 "$CFG"
}

adguard_liberar_53(){
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/adguardhome.conf <<'RSEOF'
[Resolve]
DNS=1.1.1.1
FallbackDNS=8.8.8.8
DNSStubListener=no
RSEOF
    # resolv.conf -> resolved (sin stub en :53)
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 2
    # Si 127.0.0.1:53 o *:53 sigue ocupado por resolved, forzar
    if ss -ulnp 2>/dev/null | grep -E ':(53)\s' | grep -qi resolved; then
        WARN "systemd-resolved aun en :53 — reiniciando de nuevo..."
        systemctl stop systemd-resolved 2>/dev/null || true
        sleep 1
        systemctl start systemd-resolved 2>/dev/null || true
        sleep 2
    fi
}

adguard_unit_propio(){
    local AGH="/opt/AdGuardHome/AdGuardHome" CFG="/opt/AdGuardHome/AdGuardHome.yaml"
    # Sin -s run ni --pidfile=... : esa forma da "unknown option" / exit 64 USAGE
    # en varias builds de AdGuard. Type=simple + binario directo es estable.
    cat > /etc/systemd/system/AdGuardHome.service <<UNIT
[Unit]
Description=AdGuard Home
Documentation=https://github.com/AdguardTeam/AdGuardHome
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${AGH} -c ${CFG} -w /opt/AdGuardHome --no-check-update
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
}

adguard_parar_todo(){
    systemctl stop AdGuardHome 2>/dev/null || true
    /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
    pkill -9 -x AdGuardHome 2>/dev/null || true
    pkill -9 -f '/opt/AdGuardHome/AdGuardHome' 2>/dev/null || true
    sleep 1
}

adguard_diag(){
    echo -e "${GRIS}--- diagnostico AdGuard ---${NC}"
    systemctl status AdGuardHome --no-pager -l 2>/dev/null | sed 's/^/  /' | head -20 || true
    echo -e "${GRIS}--- quien usa :53 / :3000 ---${NC}"
    ss -tulnp 2>/dev/null | grep -E ':(53|3000)\s' | sed 's/^/  /' || echo "  (nadie)"
    echo -e "${GRIS}--- journal (ultimas 30) ---${NC}"
    journalctl -u AdGuardHome -n 30 --no-pager 2>/dev/null | sed 's/^/  /' || true
    echo -e "${GRIS}--- yaml bind_hosts ---${NC}"
    grep -A5 'bind_hosts\|address:' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null | sed 's/^/  /' || true
}

adguard_arreglar_y_arrancar(){
    local AGH="/opt/AdGuardHome/AdGuardHome" CFG="/opt/AdGuardHome/AdGuardHome.yaml"
    [[ -x "$AGH" ]] || return 1

    adguard_parar_todo
    adguard_liberar_53

    # Quitar unit del instalador oficial e instalar el nuestro
    "$AGH" -s uninstall 2>/dev/null || true
    rm -f /etc/systemd/system/AdGuardHome.service
    systemctl daemon-reload 2>/dev/null || true

    adguard_escribir_config "$CFG"
    chmod 755 /opt/AdGuardHome "$AGH" 2>/dev/null || true
    adguard_unit_propio

    # Puerto 53 libre?
    if ss -uln 2>/dev/null | awk 'NR>1{n=split($4,a,":"); if(a[n]==53){found=1}} END{exit found?0:1}'; then
        WARN "UDP 53 ocupado antes de arrancar:"
        ss -ulnp 2>/dev/null | grep ':53' | sed 's/^/  /' || true
    fi

    systemctl reset-failed AdGuardHome 2>/dev/null || true
    systemctl enable AdGuardHome 2>/dev/null || true
    systemctl start AdGuardHome 2>/dev/null || true

    local i
    for ((i=1; i<=20; i++)); do
        if systemctl is-active --quiet AdGuardHome 2>/dev/null; then
            # Confirmar que sigue vivo 2s (no sale al toque)
            sleep 2
            if systemctl is-active --quiet AdGuardHome 2>/dev/null; then
                return 0
            fi
        fi
        # Si failed, no tiene sentido esperar 20s en vano
        if systemctl is-failed --quiet AdGuardHome 2>/dev/null; then
            break
        fi
        sleep 1
    done
    return 1
}

instalar_adguard(){
    # install.sh oficial: -c=canal, -o=dir base, -r=reinstalar (NO son rutas de config).
    echo -e "${CIAN}--- INSTALADOR AdGuard Home ---${NC}"
    local REINST=0 ARCH URL TMP AGH="/opt/AdGuardHome/AdGuardHome" CFG="/opt/AdGuardHome/AdGuardHome.yaml"
    if adguard_instalado; then
        read -r -p "AdGuard ya esta instalado. Reinstalar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
        REINST=1
        systemctl stop AdGuardHome 2>/dev/null || true
        pkill -x AdGuardHome 2>/dev/null || true
        pkill -f '/opt/AdGuardHome/AdGuardHome' 2>/dev/null || true
        sleep 1
    fi

    INFO "Liberando puerto 53 (stub de systemd-resolved)..."
    adguard_liberar_53
    if ss -uln 2>/dev/null | awk 'NR>1{n=split($4,a,":"); if(a[n]==53){found=1}} END{exit found?0:1}'; then
        WARN "UDP 53 sigue en uso: $(ss -ulnp 2>/dev/null | awk 'NR>1{n=split($5,a,":"); if(a[n]==53){print; exit}}')"
    fi

    INFO "Descargando e instalando AdGuard Home..."
    local INST_OK=0
    if (( REINST )); then
        curl -s -S -L --max-time 30 https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
            | sh -s -- -v -c release -o /opt -r && INST_OK=1
    else
        curl -s -S -L --max-time 30 https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
            | sh -s -- -v -c release -o /opt && INST_OK=1
    fi

    if [[ $INST_OK -ne 1 || ! -x "$AGH" ]]; then
        WARN "Script oficial fallo o sin binario. Instalacion manual..."
        case "$(uname -m)" in
            x86_64|amd64) ARCH=amd64 ;;
            aarch64|arm64) ARCH=arm64 ;;
            armv7l|armhf) ARCH=armv7 ;;
            *) ARCH=amd64 ;;
        esac
        URL="https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_${ARCH}.tar.gz"
        TMP=$(mktemp -d /tmp/agh-XXXXXX) || { ERR "Sin temporal."; PAUSA; return; }
        if curl -fsSL --max-time 120 "$URL" -o "$TMP/agh.tar.gz" \
            && tar -C "$TMP" -xzf "$TMP/agh.tar.gz" \
            && [[ -x "$TMP/AdGuardHome/AdGuardHome" ]]; then
            mkdir -p /opt/AdGuardHome
            systemctl stop AdGuardHome 2>/dev/null || true
            "$TMP/AdGuardHome/AdGuardHome" -s uninstall 2>/dev/null || true
            install -m 755 "$TMP/AdGuardHome/AdGuardHome" "$AGH"
            cp -a "$TMP/AdGuardHome/." /opt/AdGuardHome/ 2>/dev/null || true
            chmod 755 "$AGH"
            INST_OK=1
            OK "Binario en $AGH"
        else
            ERR "No se pudo descargar AdGuard Home ($URL)."
            rm -rf "$TMP"; PAUSA; return
        fi
        rm -rf "$TMP"
    fi
    [[ -x "$AGH" ]] || { ERR "No existe $AGH"; PAUSA; return; }

    # El install.sh oficial deja un proceso temporal (log "serving url=...") que no es el unit.
    # Pararlo antes de aplicar nuestra config y unit propio.
    INFO "Aplicando config segura y servicio systemd propio..."
    adguard_parar_todo

    if ! adguard_arreglar_y_arrancar; then
        ERR "No se pudo registrar/arrancar AdGuard Home."
        adguard_diag
        PAUSA; return
    fi

    if adguard_activo; then
        ficha_abrir "🛡 ADGUARD HOME ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "DNS en" "127.0.0.1$(adguard_ip_disponible 10.66.0.1 && echo ' y 10.66.0.1 (WG activo)' || echo ' (10.66.0.1 al levantar WG)')"
        ficha_fila "Puerto 53" "NO abierto a Internet" "$VERDE"
        ficha_fila "Panel web" "http://127.0.0.1:3000"
        ficha_cerrar
        printf '%bPanel web (ejecútalo en tu PC):%b\n%b%s%b\n' "$GRIS" "$NC" "$VERDE" "ssh -L 3000:127.0.0.1:3000 root@$(ip_publica)" "$NC"
        if [[ -f /etc/wireguard/wg0.conf ]]; then
            INFO "Clientes WireGuard: DNS = 10.66.0.1"
        else
            INFO "Instala WireGuard después: el panel pondrá DNS=10.66.0.1 en el cliente."
        fi
        vps_log INFO "AdGuard Home instalado/activo"
    else
        ERR "AdGuard no quedo activo tras el arranque."
        echo -e "${GRIS}--- ultimas lineas del journal ---${NC}"
        journalctl -u AdGuardHome -n 25 --no-pager 2>/dev/null | sed 's/^/  /' || true
        if ss -uln 2>/dev/null | awk 'NR>1{n=split($4,a,":"); if(a[n]==53){found=1}} END{exit found?0:1}'; then
            ERR "UDP 53 ocupado: suele impedir el DNS de AdGuard."
        fi
        # Si el proceso murio pero el binario esta, sugerir arranque manual
        INFO "Proba: systemctl status AdGuardHome"
        INFO "O: /opt/AdGuardHome/AdGuardHome -s start -c $CFG -w /opt/AdGuardHome"
    fi
    PAUSA
}

estado_adguard(){
    ficha_abrir "📊 ESTADO ADGUARD HOME"
    if adguard_instalado; then
        if adguard_activo; then
            OK "Servicio ACTIVO"
        else
            WARN "Instalado pero DETENIDO — intentando reparar y arrancar..."
            # Causa tipica: bind a 10.66.0.1 sin WireGuard UP, o systemd-resolved en :53
            if adguard_arreglar_y_arrancar; then
                OK "Servicio ACTIVO tras reparacion"
            else
                ERR "No arranco. Diagnostico:"
                adguard_diag
            fi
        fi
        echo
        ss -tulnp 2>/dev/null | grep -E ':53|:3000' | sed 's/^/  /' || true
        echo
        echo -e " Panel: ${VERDE}ssh -L 3000:127.0.0.1:3000 root@$(ip_publica)${NC}"
        echo -e "        luego ${CIAN}http://127.0.0.1:3000${NC}"
        if adguard_ip_disponible 10.66.0.1; then
            INFO "WireGuard UP: clientes deben usar DNS=10.66.0.1 para adblock."
        else
            WARN "WireGuard no UP: AdGuard solo escucha en 127.0.0.1:53 (seguro). Al levantar WG, entra a Estado otra vez para re-bind."
        fi
    else
        ERR "AdGuard Home no esta instalado."
    fi
    ficha_cerrar
    PAUSA
}

actualizar_listas_adguard(){
    if ! adguard_activo; then
        ERR "AdGuard no esta activo."; PAUSA; return
    fi
    INFO "Las listas se actualizan desde el panel web (Filters)."
    INFO "Tambien puedes forzar recarga del servicio:"
    systemctl restart AdGuardHome 2>/dev/null && ficha_ok "🔄 ADGUARD REINICIADO" "Servicio" "reiniciado" "Listas" "se cargan al iniciar" || ERR "No se pudo reiniciar."
    PAUSA
}

quitar_adguard(){
    echo -e "${CIAN}--- QUITAR AdGuard Home ---${NC}"
    read -r -p "Confirmar eliminacion de AdGuard Home? (s/n): " SN
    [[ "$SN" != "s" ]] && { INFO "Cancelado."; PAUSA; return; }
    systemctl disable --now AdGuardHome 2>/dev/null
    /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
    rm -rf /opt/AdGuardHome
    rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null
    ficha_ok "🗑 ADGUARD HOME ELIMINADO" "DNS del sistema" "restaurado a systemd-resolved"
    vps_log INFO "AdGuard Home eliminado"
    PAUSA
}

reparar_adguard(){
    # Reutiliza la logica de reparacion existente (libera :53, reescribe yaml, re-registra el unit).
    echo -e "${CIAN}--- REPARAR AdGuard Home ---${NC}"
    if ! adguard_instalado; then ERR "AdGuard Home no esta instalado."; PAUSA; return; fi
    INFO "Liberando :53, reescribiendo config y re-registrando el servicio..."
    if adguard_arreglar_y_arrancar; then
        vps_log INFO "AdGuard Home reparado"
        ficha_ok "🛠 ADGUARD HOME REPARADO" "Servicio" "ACTIVO"
    else
        ERR "No arranco. Diagnostico:"
        adguard_diag
    fi
    PAUSA
}

# Submenu de AdGuard Home (se abre desde Protocolos [11]).
menu_adguard(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_adguard)"
        FR_OPT 1 "📥 $(T t_ad_inst)" "" ""
        FR_OPT 2 "📊 $(T t_ad_estado)" "" ""
        FR_OPT 3 "🔧 $(T t_ad_reparar)" "" ""
        FR_OPT 4 "🔄 $(T t_ad_listas)" "" ""
        FR_OPT 5 "🧹 $(T t_ad_quitar)" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        echo -e "  ${GRIS}$(T t_ad_nota1)${NC}"
        echo -e "  ${GRIS}$(T t_ad_nota2)${NC}"
        PROMPT
        case "$OP" in
            1) instalar_adguard ;;
            2) estado_adguard ;;
            3) reparar_adguard ;;
            4) actualizar_listas_adguard ;;
            5) quitar_adguard ;;
            0) break ;;
            *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}


menu_protocolos(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_prot)"
        FR_OPT 1 "⚡ $(T t_xray)" 2 "🌐 $(T t_xray_ws)"
        FR_OPT 3 "🔐 $(T t_openvpn)" 4 "🔏 $(T t_stunnel)"
        FR_OPT 5 "🚀 $(T t_hysteria)" 6 "🎮 $(T t_badvpn)"
        FR_OPT 7 "🔗 $(T t_wsepro)" 8 "🎭 $(T t_shadowsocks)"
        FR_OPT 9 "🐴 $(T t_trojan)" 10 "🐉 $(T t_wireguard)"
        FR_OPT 11 "🚫 $(T t_adguard)" 12 "📊 $(T t_estado_prot)"
        FR_OPT 13 "🧹 $(T t_quitar)" 14 "⛅ $(T t_cf_test)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_xray ;;        2) instalar_xray_ws ;;
            3) instalar_openvpn ;;     4) instalar_ssl_stunnel ;;
            5) instalar_hysteria ;;    6) instalar_badvpn ;;
            7) instalar_wsepro ;;      8) instalar_shadowsocks ;;
            9) instalar_trojan ;;      10) instalar_wireguard ;;
            11) menu_adguard ;;        12) estado_protocolos ;;
            13) menu_quitar ;;         14) tunel_trycloudflare ;;
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
        FR_OPT 1 "➕ $(T t_crear)" 7 "❌ $(T t_eliminar)"
        FR_OPT 2 "📋 $(T t_listar)" 8 "⏰ $(T t_vencidos)"
        FR_OPT 3 "🔑 $(T t_clave)" 9 "🧪 $(T t_test)"
        FR_OPT 4 "🔒 $(T t_bloquear)" 10 "📡 $(T t_conexiones)"
        FR_OPT 5 "🔄 $(T t_renovar)" 11 "⛔ $(T t_desconectar)"
        FR_OPT 6 "🚦 $(T t_limite)" 12 "📈 $(T t_trafico)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) crear_usuario ;;   2) listar_usuarios ;; 3) cambiar_clave ;;
            4) bloquear_usuario ;; 5) renovar_usuario ;; 6) cambiar_limite ;;
            7) eliminar_usuario ;; 8) eliminar_vencidos ;; 9) crear_test_ssh ;;
            10) conexiones_online ;; 11) matar_conexion ;; 12) menu_trafico ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# DOMINIO Y SSL  (Let's Encrypt con certbot, HTTP-01 standalone, SIN API de DNS)
# Requisito: el cliente ya apunta su dominio (@) y un comodin (*) a la IP de la VPS en Cloudflare,
# en "DNS only" (nube gris). El panel NO crea registros DNS: solo los VERIFICA.
# Un unico certificado (lineage "ghost-panel") cubre el dominio y sus subdominios y se despliega a
# Stunnel, Hysteria2, Trojan (Xray), Webmin y AdGuard Home. Renovacion: certbot.timer + hooks que
# liberan/restauran el puerto 80 y vuelven a desplegar (script generado: /usr/local/bin/ghost-ssl-hook).
# ------------------------------------------------------------
SSL_DIR='/etc/ghost-ssl'
SSL_NAME='ghost-panel'
SSL_LIVE="/etc/letsencrypt/live/$SSL_NAME"
SSL_HOOK='/usr/local/bin/ghost-ssl-hook'
SSL_PROC_DIR='/proc'

ssl_conf_get(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$SSL_DIR/domain.conf" 2>/dev/null; }
ssl_conf_set(){
    mkdir -p "$SSL_DIR"; touch "$SSL_DIR/domain.conf"
    sed -i "/^$1=/d" "$SSL_DIR/domain.conf"
    echo "$1=$2" >> "$SSL_DIR/domain.conf"
}
ssl_subs_lista(){ [[ -f "$SSL_DIR/subdominios.list" ]] && cat "$SSL_DIR/subdominios.list"; return 0; }
ssl_nombres(){ ssl_conf_get DOMINIO; ssl_subs_lista; }

ssl_reiniciar(){
    # ssl_reiniciar UNIDAD -> reinicia SOLO si esta corriendo (no enciende servicios apagados a proposito)
    local u="$1" vivo=0
    if systemctl is-active --quiet "$u" 2>/dev/null; then vivo=1
    else
        case "$u" in
            stunnel4) pgrep -f stunnel >/dev/null 2>&1 && vivo=1 ;;
            webmin)   pgrep -f miniserv >/dev/null 2>&1 && vivo=1 ;;
            xray)     pgrep -x xray >/dev/null 2>&1 && vivo=1 ;;
            hysteria-server) pgrep -x hysteria >/dev/null 2>&1 && vivo=1 ;;
            AdGuardHome) pgrep -x AdGuardHome >/dev/null 2>&1 && vivo=1 ;;
        esac
    fi
    (( vivo )) && { systemctl restart "$u" 2>/dev/null || service "$u" restart >/dev/null 2>&1 || true; }
    return 0
}

ssl_guardar_original(){
    # Copia (una sola vez) el archivo de certificado/clave original antes de pisarlo: lo usa ssl_quitar.
    local f="$1" dst="$SSL_DIR/orig$1"
    [[ -f "$f" && ! -e "$dst" ]] || return 0
    mkdir -p "$(dirname "$dst")"; cp -a "$f" "$dst" 2>/dev/null
    return 0
}

ssl_webmin_aplicar(){
    # Apunta Webmin (miniserv) al certificado real; guarda las lineas originales para poder revertir.
    local MC=/etc/webmin/miniserv.conf kv k
    [[ -f "$MC" ]] || return 0
    mkdir -p "$SSL_DIR"
    if [[ ! -f "$SSL_DIR/webmin.orig" ]]; then grep -E '^(keyfile|certfile)=' "$MC" > "$SSL_DIR/webmin.orig" 2>/dev/null; touch "$SSL_DIR/webmin.orig"; fi
    for kv in "keyfile=$SSL_DIR/privkey.pem" "certfile=$SSL_DIR/fullchain.pem"; do
        k=${kv%%=*}
        if grep -q "^$k=" "$MC"; then sed -i "s#^$k=.*#$kv#" "$MC"; else echo "$kv" >> "$MC"; fi
    done
    ssl_reiniciar webmin
    return 0
}

ssl_desplegar(){
    # ssl_desplegar [force] -> copia el certificado emitido a cada servicio instalado y lo reinicia.
    # Sin "force" no hace nada si el certificado no cambio (asi el hook de renovacion es barato).
    local force="${1:-}" crt="$SSL_LIVE/fullchain.pem" key="$SSL_LIVE/privkey.pem" XG DOM OLD
    [[ -r "$crt" && -r "$key" ]] || return 1
    mkdir -p "$SSL_DIR/orig"; chmod 755 "$SSL_DIR"
    if [[ -z "$force" ]] && cmp -s "$crt" "$SSL_DIR/fullchain.pem" 2>/dev/null; then return 0; fi
    install -m 644 "$crt" "$SSL_DIR/fullchain.pem"
    install -m 600 "$key" "$SSL_DIR/privkey.pem"
    DOM=$(ssl_conf_get DOMINIO)
    # Stunnel: pem = cadena + clave
    if [[ -f /etc/stunnel/stunnel.conf ]]; then
        ssl_guardar_original /etc/stunnel/stunnel.pem
        cat "$crt" "$key" > /etc/stunnel/stunnel.pem; chmod 600 /etc/stunnel/stunnel.pem
        ssl_reiniciar stunnel4
    fi
    # Hysteria2
    if [[ -f /etc/hysteria/server.crt ]]; then
        ssl_guardar_original /etc/hysteria/server.crt; ssl_guardar_original /etc/hysteria/server.key
        install -m 644 "$crt" /etc/hysteria/server.crt; install -m 600 "$key" /etc/hysteria/server.key
        if id hysteria >/dev/null 2>&1; then chown hysteria:hysteria /etc/hysteria/server.crt /etc/hysteria/server.key
        else chmod 644 /etc/hysteria/server.key; fi
        ssl_reiniciar hysteria-server
    fi
    # Trojan (Xray): certificado real y SNI = dominio (guarda el SNI de camuflaje original)
    if [[ -f /etc/vpsjb-trojan/cert.pem ]]; then
        ssl_guardar_original /etc/vpsjb-trojan/cert.pem; ssl_guardar_original /etc/vpsjb-trojan/key.pem
        install -m 644 "$crt" /etc/vpsjb-trojan/cert.pem
        if XG=$(xray_grupo); then install -m 640 -o root -g "$XG" "$key" /etc/vpsjb-trojan/key.pem
        else install -m 644 "$key" /etc/vpsjb-trojan/key.pem; fi
        if [[ -n "$DOM" ]]; then
            OLD=$(python3 - "$DOM" <<'PYEOF'
import json, sys
dom = sys.argv[1]; p = "/usr/local/etc/xray/config.json"
try:
    c = json.load(open(p)); old = ""; ch = False
    for ib in c.get("inbounds", []):
        if ib.get("protocol") == "trojan":
            t = ib.get("streamSettings", {}).get("tlsSettings", {})
            if t.get("serverName") != dom:
                old = old or t.get("serverName", ""); t["serverName"] = dom; ch = True
    if ch:
        json.dump(c, open(p, "w"), indent=2)
    print(old)
except Exception:
    pass
PYEOF
)
            [[ -n "$OLD" && ! -f "$SSL_DIR/trojan-sni.orig" ]] && echo "$OLD" > "$SSL_DIR/trojan-sni.orig"
        fi
        ssl_reiniciar xray
    fi
    ssl_webmin_aplicar
    # AdGuard Home: solo reinicia si su yaml ya apunta a /etc/ghost-ssl (el yaml lo escribe el panel)
    grep -q 'certificate_path: /etc/ghost-ssl' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null && ssl_reiniciar AdGuardHome
    vps_log INFO "ssl: certificado desplegado (${DOM:-?})"
    return 0
}

ssl_puerto80_liberar(){
    # Detiene (via systemd) lo que escucha en el 80 para que certbot valide. Guarda las unidades en
    # /run/ghost-ssl-stopped para que ssl_puerto80_restaurar las vuelva a levantar. Nunca toca SSH.
    local f=/run/ghost-ssl-stopped pid unit i
    : > "$f"
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        unit=$(grep -o '[A-Za-z0-9@_.:-]*\.service' "$SSL_PROC_DIR/$pid/cgroup" 2>/dev/null | tail -1)
        case "$unit" in
            ssh.service|sshd.service|ssh@*|dropbear.service)
                echo "El puerto 80 lo usa SSH ($unit): no se detiene. Cambia ese puerto y reintenta." >&2; return 1 ;;
            "")
                echo "El puerto 80 lo usa un proceso fuera de systemd ($(cat "$SSL_PROC_DIR/$pid/comm" 2>/dev/null), pid $pid). Detenlo a mano y reintenta." >&2; return 1 ;;
        esac
        systemctl stop "$unit" 2>/dev/null && echo "$unit" >> "$f"
    done < <(ss -ltnpH 'sport = :80' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ss -ltnH 'sport = :80' 2>/dev/null | grep -q . || return 0
        sleep 0.5
    done
    echo "El puerto 80 sigue ocupado." >&2
    return 1
}
ssl_puerto80_restaurar(){
    local f=/run/ghost-ssl-stopped u
    [[ -f "$f" ]] || return 0
    while read -r u; do [[ -n "$u" ]] && systemctl start "$u" 2>/dev/null; done < "$f"
    rm -f "$f"
    return 0
}

ssl_hook_instalar(){
    # Genera /usr/local/bin/ghost-ssl-hook COPIANDO las funciones de este script (declare -f): lo usa
    # certbot en cada emision/renovacion (pre = liberar 80, post = restaurar, deploy = desplegar).
    # Se regenera al abrir el panel para que coincida siempre con la version instalada.
    local FN
    {
        echo '#!/bin/bash'
        echo '# Generado por Ghost Panel (ssl_hook_instalar). No editar: se regenera solo.'
        echo 'export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin LC_ALL=C.UTF-8'
        declare -p SSL_DIR SSL_NAME SSL_LIVE SSL_PROC_DIR LOG_PANEL
        for FN in vps_log xray_grupo ssl_conf_get ssl_reiniciar ssl_guardar_original ssl_webmin_aplicar \
                  ssl_desplegar ssl_puerto80_liberar ssl_puerto80_restaurar; do
            declare -f "$FN"
        done
        echo 'case "${1:-}" in pre) ssl_puerto80_liberar ;; post) ssl_puerto80_restaurar ;; deploy) ssl_desplegar ;; esac'
    } > "$SSL_HOOK"
    chmod 755 "$SSL_HOOK"
}

ssl_certbot_instalar(){
    command -v certbot >/dev/null 2>&1 && return 0
    INFO "Instalando certbot..."
    apt update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt install -y certbot >/dev/null 2>&1 || { ERR "No se pudo instalar certbot (sin red?)."; return 1; }
    mkdir -p "$SSL_DIR"; touch "$SSL_DIR/certbot-por-panel"      # el desinstalador lo quita solo si lo puso el panel
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    return 0
}

ssl_ufw_80(){
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status 2>/dev/null | grep -qE '^80(/tcp)?[[:space:]]+ALLOW'; then
            ufw allow 80/tcp >/dev/null 2>&1 && INFO "Puerto 80/tcp abierto en UFW (necesario para validar)."
        fi
    fi
    return 0
}

ssl_oci_detectar(){
    # -> 0 si hay senales de que la VPS es Oracle Cloud (OCI).
    [[ -f /etc/oci-hostname.conf ]] && return 0
    grep -qi oracle /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name /sys/class/dmi/id/sys_vendor 2>/dev/null && return 0
    grep -qi DataSourceOracle /var/lib/cloud/instance/datasource 2>/dev/null && return 0
    return 1
}

ssl_oci_aviso(){
    # El bloqueo de red de Oracle Cloud (Security List del VCN) solo se corrige
    # desde la consola OCI: la VPS no puede abrirlo por si sola.
    ssl_oci_detectar || return 0
    echo
    WARN "Este VPS parece ORACLE CLOUD (OCI): ademas del firewall interno, OCI filtra los puertos desde la nube."
    echo "  Consola OCI -> Redes -> Redes virtuales en la nube -> tu VCN -> Listas de seguridad"
    echo "  -> 'Agregar reglas de entrada' con:  Origen 0.0.0.0/0 · Protocolo TCP · Puerto destino 80"
    echo "  (y otra regla igual con puerto 443). Sin eso Let's Encrypt NUNCA puede validar."
    echo
    return 0
}

ssl_iptables_puerto_ok(){
    # ssl_iptables_puerto_ok PUERTO -> 0 si el puerto TCP quedaria alcanzable
    # segun las reglas INPUT de iptables (los imagenes de Oracle traen un
    # REJECT final que bloquea TODO salvo SSH, aunque UFW este inactivo).
    local p="$1" pol
    command -v iptables >/dev/null 2>&1 || return 0
    pol=$(iptables -S INPUT 2>/dev/null | awk '$1=="-P"{print $3}')
    iptables -S INPUT 2>/dev/null | awk -v pol="$pol" -v p="$p" '
        BEGIN { r = 2 }
        !d {
            if ($0 ~ /(-j|--jump) (REJECT|DROP)/)        { d = 1; r = 1 }
            else if ($0 ~ ("--dport " p "([ :]|$)"))     { r = 0; exit 0 }
        }
        END {
            if (r == 0) exit 0
            if (d)      exit 1
            if (pol == "ACCEPT") exit 0
            exit 1
        }'
}

ssl_firewall_verificar(){
    # Asegura 80/443 alcanzables a nivel local: UFW (ssl_ufw_80) + iptables.
    # Si faltan reglas las agrega y las persiste (imagenes Oracle: rules.v4).
    local p abrir="" persist=0
    ssl_ufw_80
    for p in 80 443; do
        ssl_iptables_puerto_ok "$p" && continue
        if iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then continue; fi
        iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || { ERR "No pude abrir $p/tcp en iptables."; continue; }
        abrir+="$p "
    done
    [[ -n "$abrir" ]] || return 0
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && persist=1
    elif [[ -d /etc/iptables ]] && command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && persist=1
    fi
    INFO "Puerto(s) ${abrir%/ }/tcp abierto(s) en iptables${persist:+ (regla guardada)}: es el bloqueo tipico de las imagenes de Oracle."
    return 0
}

ssl_diagnostico_certbot(){
    # Interpreta el log de certbot y senala la causa probable del fallo.
    local L="$1"
    if grep -qiE 'timeout during connect|connection timed out|timeout during' "$L"; then
        WARN "Diagnostico: el puerto 80 NO responde desde Internet (timeout)."
        ssl_oci_detectar && WARN "Tu VPS es Oracle Cloud: casi seguro falta la regla TCP 80/443 en la LISTA DE SEGURIDAD del VCN (se corrige solo desde la consola OCI, mira el aviso de arriba)."
        INFO "Revisa tambien: firewall del proveedor, iptables local y que nada este en 80."
    elif grep -qi 'connection refused' "$L"; then
        WARN "Diagnostico: el puerto 80 rechaza conexiones (REJECT local o servicio caido al validar)."
    elif grep -qiE 'no valid IP addresses found|nxdomain|name or service not known|dns problem' "$L"; then
        WARN "Diagnostico: el dominio no resuelve o no apunta a esta VPS (opcion 1 del menu SSL)."
    fi
    return 0
}

ssl_resuelve(){ getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

ssl_dns_verificar(){
    # ssl_dns_verificar NOMBRE -> 0 si resuelve a la IP publica de esta VPS (imprime diagnostico)
    local n="$1" ip r v6
    ip=$(ip_publica); r=$(ssl_resuelve "$n")
    if [[ -z "$r" ]]; then ERR "$n no resuelve (¿falta el registro A?)."; return 1; fi
    if [[ "$r" != "$ip" ]]; then
        ERR "$n resuelve a $r pero esta VPS es $ip."
        INFO "En Cloudflare el registro debe apuntar a $ip y estar en 'DNS only' (nube gris), no en 'Proxied'."
        return 1
    fi
    v6=$(getent ahostsv6 "$n" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}')
    if [[ -n "$v6" ]] && ! ip -6 addr 2>/dev/null | grep -qiF "$v6"; then
        WARN "$n tiene un registro AAAA ($v6) que no es de esta VPS: Let's Encrypt validaria por IPv6 y fallaria. Borra ese AAAA."
    fi
    OK "$n -> $r"
    return 0
}

ssl_dias_restantes(){
    local f="$SSL_DIR/fullchain.pem" fin
    [[ -f "$f" ]] || return 0
    fin=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
    [[ -n "$fin" ]] || return 0
    echo $(( ( $(date -d "$fin" +%s) - $(date +%s) ) / 86400 ))
}

ssl_dominio_poner(){
    local DOM EM cur re_d re_e R_A="apunta a esta VPS" R_W="apunta a esta VPS"
    re_d='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
    re_e='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    cur=$(ssl_conf_get DOMINIO)
    echo -e "${CIAN}--- DOMINIO ---${NC}"
    echo "  En el panel de DNS de tu dominio (Cloudflare, DigitalPlat/dpdns.org, etc.)"
    echo "  crea 2 registros A hacia $(ip_publica), sin proxy (solo DNS):"
    echo "    @  (dominio principal)     y     *  (todos los subdominios)"
    if ssl_oci_detectar; then
        WARN "VPS de Oracle Cloud: recuerda abrir TCP 80 y 443 en la LISTA DE SEGURIDAD del VCN (consola OCI), o el certificado nunca validara."
    fi
    echo
    read -r -p "  Dominio${cur:+ [$cur]} (ej: midominio.com): " DOM; DOM=${DOM:-$cur}
    DOM=$(echo "$DOM" | tr 'A-Z' 'a-z')
    [[ "$DOM" =~ $re_d ]] || { ERR "Dominio invalido."; PAUSA; return; }
    read -r -p "  Correo para avisos de Let's Encrypt (opcional, Enter = sin correo): " EM
    if [[ -n "$EM" && ! "$EM" =~ $re_e ]]; then ERR "Correo invalido."; PAUSA; return; fi
    if [[ -n "$cur" && "$cur" != "$DOM" && -s "$SSL_DIR/subdominios.list" ]]; then
        WARN "Cambiaste de dominio: la lista de subdominios anterior se vacia."
        : > "$SSL_DIR/subdominios.list"
    fi
    ssl_conf_set DOMINIO "$DOM"; ssl_conf_set EMAIL "$EM"
    echo
    ssl_dns_verificar "$DOM" || R_A="AÚN NO apunta a esta VPS"
    ssl_dns_verificar "ghost-prueba-$RANDOM.$DOM" || R_W="FALTA el comodín (*): los subdominios no resolverán"
    vps_log INFO "ssl: dominio $DOM"
    ficha_abrir "🌍 DOMINIO CONFIGURADO" "$VERDE"
    ficha_fila "Dominio" "$DOM" "$VERDE"
    ficha_fila "Correo avisos" "${EM:-sin correo}"
    ficha_fila "Registro @" "$R_A" "$([[ "$R_A" == apunta* ]] && echo "$VERDE" || echo "$AMARILLO")"
    ficha_fila "Registro *" "$R_W" "$([[ "$R_W" == apunta* ]] && echo "$VERDE" || echo "$AMARILLO")"
    ficha_cerrar
    PAUSA
}

ssl_sub_crear(){
    local DOM L F SN re
    DOM=$(ssl_conf_get DOMINIO)
    [[ -n "$DOM" ]] || { ERR "Primero configura el dominio (opcion 1)."; PAUSA; return; }
    echo -e "${CIAN}--- CREAR SUBDOMINIO ---${NC}"
    read -r -p "  Nombre (ej: cliente1 -> cliente1.$DOM): " L
    L=$(echo "$L" | tr 'A-Z' 'a-z')
    re='^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'
    [[ "$L" =~ $re ]] || { ERR "Nombre invalido (letras, numeros y guion; sin puntos)."; PAUSA; return; }
    F="$L.$DOM"
    if ssl_subs_lista | grep -qxF "$F"; then ERR "$F ya esta en la lista."; PAUSA; return; fi
    if (( $(ssl_subs_lista | wc -l) >= 90 )); then ERR "Limite de 90 subdominios por certificado."; PAUSA; return; fi
    ssl_dns_verificar "$F" || { PAUSA; return; }
    echo "$F" >> "$SSL_DIR/subdominios.list"
    vps_log INFO "ssl: subdominio $F"
    ficha_ok "🌍 SUBDOMINIO REGISTRADO" "Subdominio" "$F" "Apunta a" "$(ip_publica)"
    read -r -p "  ¿Actualizar el certificado ahora para incluirlo? (S/n): " SN
    if [[ ! "$SN" =~ ^[nN]$ ]]; then ssl_emitir_flujo; else INFO "Pendiente: usa 'Emitir certificado SSL' cuando quieras."; fi
    PAUSA
}

ssl_subs_menu(){
    local i SEL F SN
    echo -e "${CIAN}--- MIS SUBDOMINIOS ---${NC}"
    if [[ -z "$(ssl_subs_lista)" ]]; then INFO "No hay subdominios (opcion 2 para crear)."; PAUSA; return; fi
    i=0; while read -r F; do i=$((i+1)); printf '  %b[%d]%b %s\n' "$CIAN" "$i" "$NC" "$F"; done < <(ssl_subs_lista)
    echo
    read -r -p "  Numero a BORRAR (Enter = volver): " SEL
    [[ "$SEL" =~ ^[0-9]+$ ]] || return
    F=$(ssl_subs_lista | sed -n "${SEL}p")
    [[ -n "$F" ]] || { ERR "Numero invalido."; PAUSA; return; }
    sed -i "\#^${F}\$#d" "$SSL_DIR/subdominios.list"
    ficha_ok "🗑 SUBDOMINIO QUITADO" "Subdominio" "$F" "Certificado" "lo conserva hasta que lo reemitas"
    read -r -p "  ¿Reemitir ahora para quitarlo del certificado? (s/N): " SN
    [[ "$SN" =~ ^[sSyY]$ ]] && ssl_emitir_flujo force
    PAUSA
}

ssl_certbot_run(){
    # ssl_certbot_run dry|real [force] -> certbot certonly standalone para dominio + subdominios.
    # Los hooks (pre/post/deploy) quedan guardados en la renovacion de este certificado.
    local mode="$1" force="${2:-}" a=() n EM LOGC=/tmp/ghost-certbot.log
    EM=$(ssl_conf_get EMAIL)
    a=(certonly --standalone --non-interactive --agree-tos --cert-name "$SSL_NAME" --preferred-challenges http --expand
       --pre-hook "$SSL_HOOK pre" --post-hook "$SSL_HOOK post" --deploy-hook "$SSL_HOOK deploy")
    if [[ -n "$EM" ]]; then a+=(--email "$EM"); else a+=(--register-unsafely-without-email); fi
    [[ "$mode" == dry ]] && a+=(--dry-run)
    [[ -n "$force" ]] && a+=(--force-renewal)
    while read -r n; do [[ -n "$n" ]] && a+=(-d "$n"); done < <(ssl_nombres)
    if certbot "${a[@]}" >"$LOGC" 2>&1; then rm -f "$LOGC"; return 0; fi
    ERR "certbot fallo. Ultimas lineas:"
    tail -n 12 "$LOGC" | sed 's/^/    /'
    ssl_diagnostico_certbot "$LOGC"
    ssl_puerto80_restaurar            # por si el pre-hook alcanzo a detener algo
    return 1
}

ssl_emitir_flujo(){
    # Verifica DNS de todos los nombres, prepara certbot/UFW/hooks, simula y emite de verdad.
    local n bad=0 force="${1:-}"
    while read -r n; do ssl_dns_verificar "$n" || bad=1; done < <(ssl_nombres)
    (( bad )) && { ERR "Corrige el DNS y vuelve a intentar."; return 1; }
    ssl_certbot_instalar || return 1
    ssl_firewall_verificar
    ssl_oci_aviso
    ssl_hook_instalar
    WARN "Se detendra unos segundos lo que use el puerto 80 (p. ej. WS-epro); los clientes reconectan solos."
    INFO "1/2 Simulacion (no gasta limites de Let's Encrypt)..."
    ssl_certbot_run dry "$force" || return 1
    OK "Simulacion correcta."
    INFO "2/2 Emision real..."
    ssl_certbot_run real "$force" || return 1
    ssl_desplegar            # no-op si el deploy-hook ya lo hizo
    ssl_aplicar_adguard
    ficha_ok "🔒 CERTIFICADO EMITIDO" "Dominio" "$(ssl_conf_get DOMINIO)" "Días restantes" "$(ssl_dias_restantes)" "Aplicado a" "los servicios instalados"
    ssl_enlaces
    return 0
}

ssl_emitir(){
    [[ -n "$(ssl_conf_get DOMINIO)" ]] || { ERR "Primero configura el dominio (opcion 1)."; PAUSA; return; }
    echo -e "${CIAN}--- EMITIR CERTIFICADO SSL ---${NC}"
    ssl_emitir_flujo
    PAUSA
}

ssl_renovar(){
    local SN a=(renew --cert-name "$SSL_NAME")
    [[ -d "$SSL_LIVE" ]] || { ERR "Aun no hay certificado (opcion 4)."; PAUSA; return; }
    echo -e "${CIAN}--- RENOVAR ---${NC}"
    INFO "Por defecto solo renueva si faltan menos de 30 dias."
    read -r -p "  ¿Forzar la renovacion ahora? (s/N): " SN
    [[ "$SN" =~ ^[sSyY]$ ]] && a+=(--force-renewal)
    ssl_hook_instalar
    if certbot "${a[@]}" >/tmp/ghost-certbot.log 2>&1; then
        ficha_ok "🔄 CERTIFICADO RENOVADO" "Días restantes" "$(ssl_dias_restantes)"
        rm -f /tmp/ghost-certbot.log
    else
        ERR "Fallo la renovacion:"; tail -n 12 /tmp/ghost-certbot.log | sed 's/^/    /'
        ssl_puerto80_restaurar
    fi
    PAUSA
}

ssl_aplicar_adguard(){
    # AdGuard Home con TLS (DNS-over-TLS interno). Si no arranca, revierte solo.
    adguard_instalado || return 0
    [[ -f "$SSL_DIR/fullchain.pem" ]] || return 0
    local CFG=/opt/AdGuardHome/AdGuardHome.yaml
    INFO "AdGuard Home: activando TLS..."
    adguard_escribir_config "$CFG"
    systemctl restart AdGuardHome 2>/dev/null; sleep 3
    if adguard_activo; then OK "AdGuard Home con certificado."
    else
        WARN "AdGuard no arranco con TLS: se revierte a la config anterior."
        GHOST_SSL_OFF=1 adguard_escribir_config "$CFG"
        systemctl restart AdGuardHome 2>/dev/null
    fi
    return 0
}

ssl_aplicar(){
    [[ -f "$SSL_LIVE/fullchain.pem" ]] || { ERR "Aun no hay certificado (opcion 4)."; PAUSA; return; }
    echo -e "${CIAN}--- APLICAR A LOS SERVICIOS ---${NC}"
    ssl_hook_instalar
    ssl_desplegar force && ficha_ok "🔒 CERTIFICADO APLICADO" "Servicios" "Stunnel, Hysteria2, Trojan, Webmin" "Alcance" "solo los que estén instalados"
    ssl_aplicar_adguard
    ssl_enlaces
    PAUSA
}

ssl_fp(){ openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null | cut -d= -f2; }

ssl_enlaces(){
    local DOM P PASS TROJ
    DOM=$(ssl_conf_get DOMINIO); [[ -n "$DOM" && -f "$SSL_DIR/fullchain.pem" ]] || return 0
    ficha_abrir "🔗 CONECTA CON TU DOMINIO" "$AMARILLO"
    echo -e "${AMARILLO}Usa el DOMINIO (no la IP). Certificado válido: no actives 'aceptar inválidos'.${NC}"
    if [[ -f /etc/stunnel/stunnel.conf ]]; then
        P=$(awk '/^accept *=/{print $3; exit}' /etc/stunnel/stunnel.conf)
        echo -e "Stunnel : host/SNI ${VERDE}$DOM${NC}  puerto SSL ${VERDE}${P:-?}${NC}"
    fi
    if [[ -f /etc/hysteria/config.yaml ]]; then
        P=$(awk '/^listen:/{sub(/^:/,"",$2); print $2; exit}' /etc/hysteria/config.yaml)
        PASS=$(awk -F'"' '/password:/{print $2; exit}' /etc/hysteria/config.yaml)
        echo -e "Hysteria: ${VERDE}hysteria2://$PASS@$DOM:${P:-?}/?sni=$DOM#VPS-JORGEBARRIOS${NC}"
    fi
    if [[ -f /etc/vpsjb-trojan/cert.pem ]]; then
        TROJ=$(python3 - <<'PYEOF' 2>/dev/null
import json
try:
    c = json.load(open("/usr/local/etc/xray/config.json"))
    for ib in c.get("inbounds", []):
        if ib.get("protocol") == "trojan":
            for cl in ib.get("settings", {}).get("clients", []):
                print(ib.get("port"), cl.get("password", ""))
except Exception:
    pass
PYEOF
)
        while read -r P PASS; do
            [[ -n "$P" ]] && echo -e "Trojan  : ${VERDE}trojan://$PASS@$DOM:$P?security=tls&sni=$DOM#VPSJB-Trojan${NC}"
        done <<< "$TROJ"
    fi
    if [[ -f /etc/webmin/miniserv.conf ]]; then
        P=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1)
        echo -e "Webmin  : ${VERDE}https://$DOM:${P:-10000}${NC}"
    fi
    if grep -q 'certificate_path: /etc/ghost-ssl' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null; then
        echo -e "AdGuard : DNS-over-TLS interno en 853 (solo clientes WireGuard), nombre ${VERDE}$DOM${NC}"
    fi
    ficha_cerrar
}

ssl_estado(){
    local DOM D FP nsub
    DOM=$(ssl_conf_get DOMINIO)
    [[ -n "$DOM" ]] || { INFO "Sin dominio configurado (opcion 1)."; PAUSA; return; }
    nsub=$(ssl_subs_lista | wc -l)
    D=$(ssl_dias_restantes)
    ficha_abrir "📊 ESTADO DOMINIO Y SSL"
    ficha_fila "Dominio" "$DOM" "$VERDE"
    ficha_fila "Subdominios" "$nsub"
    if [[ -z "$D" ]]; then
        ficha_fila "Certificado" "aún no hay (opción 4)" "$AMARILLO"
        ficha_cerrar; PAUSA; return
    fi
    ficha_fila "Certificado" "vence en $D días" "$VERDE"
    ficha_fila "Emisor" "$(openssl x509 -issuer -noout -in "$SSL_DIR/fullchain.pem" 2>/dev/null | sed 's/^issuer=//')"
    ficha_fila "Nombres" "$(openssl x509 -noout -ext subjectAltName -in "$SSL_DIR/fullchain.pem" 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g')"
    if systemctl is-active --quiet certbot.timer 2>/dev/null; then ficha_fila "Renovación" "automática (certbot.timer)" "$VERDE"
    else ficha_fila "Renovación" "certbot.timer inactivo (systemctl enable --now certbot.timer)" "$AMARILLO"; fi
    FP=$(ssl_fp "$SSL_DIR/fullchain.pem")
    [[ -f /etc/stunnel/stunnel.conf ]]  && ssl_estado_fila "Stunnel" "$FP" /etc/stunnel/stunnel.pem
    [[ -f /etc/hysteria/server.crt ]]   && ssl_estado_fila "Hysteria2" "$FP" /etc/hysteria/server.crt
    [[ -f /etc/vpsjb-trojan/cert.pem ]] && ssl_estado_fila "Trojan" "$FP" /etc/vpsjb-trojan/cert.pem
    if [[ -f /etc/webmin/miniserv.conf ]]; then
        if grep -q "^certfile=$SSL_DIR/fullchain.pem" /etc/webmin/miniserv.conf; then ficha_fila "Webmin" "aplicado" "$VERDE"
        else ficha_fila "Webmin" "pendiente (opción 7)" "$AMARILLO"; fi
    fi
    if [[ -d /opt/AdGuardHome ]]; then
        if grep -q 'certificate_path: /etc/ghost-ssl' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null; then ficha_fila "AdGuard" "aplicado" "$VERDE"
        else ficha_fila "AdGuard" "pendiente (opción 7)" "$AMARILLO"; fi
    fi
    echo -e "${GRIS}No usan certificado: Reality, WS-epro, Shadowsocks, OpenVPN, WireGuard, BadVPN, SSH.${NC}"
    ficha_cerrar
    ssl_enlaces
    PAUSA
}
ssl_estado_fila(){
    # ssl_estado_fila ETIQUETA HUELLA_ESPERADA ARCHIVO -> fila "aplicado" (verde) / "pendiente" (amarillo)
    if [[ "$(ssl_fp "$3")" == "$2" ]]; then ficha_fila "$1" "aplicado" "$VERDE"
    else ficha_fila "$1" "pendiente (opción 7)" "$AMARILLO"; fi
}
ssl_estado_fp(){
    # ssl_estado_fp HUELLA_ESPERADA ARCHIVO -> "aplicado" / "pendiente"
    if [[ "$(ssl_fp "$2")" == "$1" ]]; then echo -e "${VERDE}aplicado${NC}"; else echo -e "${AMARILLO}pendiente (opcion 7)${NC}"; fi
}

ssl_quitar(){
    # Restaura los certificados originales de cada servicio y borra TODO lo de Dominio y SSL.
    local f p PURGE=0 u
    [[ -d "$SSL_DIR" ]] || return 0
    [[ -f "$SSL_DIR/certbot-por-panel" ]] && PURGE=1
    if [[ -d "$SSL_DIR/orig" ]]; then
        while read -r f; do
            p="/${f#./}"
            [[ -d "$(dirname "$p")" ]] || continue            # el servicio ya no esta instalado
            cp -a "$SSL_DIR/orig/${f#./}" "$p" 2>/dev/null
        done < <(cd "$SSL_DIR/orig" && find . -type f)
    fi
    # Trojan: devuelve el SNI de camuflaje original
    if [[ -f "$SSL_DIR/trojan-sni.orig" && -f /usr/local/etc/xray/config.json ]]; then
        python3 - "$(cat "$SSL_DIR/trojan-sni.orig")" <<'PYEOF' 2>/dev/null
import json, sys
sni = sys.argv[1]; p = "/usr/local/etc/xray/config.json"
try:
    c = json.load(open(p))
    for ib in c.get("inbounds", []):
        if ib.get("protocol") == "trojan":
            ib.setdefault("streamSettings", {}).setdefault("tlsSettings", {})["serverName"] = sni
    json.dump(c, open(p, "w"), indent=2)
except Exception:
    pass
PYEOF
    fi
    # Webmin: devuelve sus lineas keyfile/certfile originales
    if [[ -f "$SSL_DIR/webmin.orig" && -f /etc/webmin/miniserv.conf ]]; then
        sed -i '/^keyfile=/d;/^certfile=/d' /etc/webmin/miniserv.conf
        cat "$SSL_DIR/webmin.orig" >> /etc/webmin/miniserv.conf
    fi
    # AdGuard: regenera su config sin bloque TLS
    if adguard_instalado 2>/dev/null; then GHOST_SSL_OFF=1 adguard_escribir_config /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null; fi
    for u in stunnel4 hysteria-server xray webmin AdGuardHome; do ssl_reiniciar "$u"; done
    command -v certbot >/dev/null 2>&1 && certbot delete --cert-name "$SSL_NAME" --non-interactive >/dev/null 2>&1
    rm -f "$SSL_HOOK" /run/ghost-ssl-stopped
    rm -rf "$SSL_DIR"
    if (( PURGE )); then
        DEBIAN_FRONTEND=noninteractive apt purge -y certbot >/dev/null 2>&1
        rm -rf /etc/letsencrypt
    fi
    ficha_ok "🗑 DOMINIO Y SSL REMOVIDOS" "Servicios" "volvieron a su certificado anterior" "DNS Cloudflare" "no se tocó"
    vps_log INFO "ssl: removido"
    return 0
}

ssl_quitar_menu(){
    local W
    echo -e "${ROJO}--- QUITAR DOMINIO Y SSL ---${NC}"
    echo "  Borra el certificado, los hooks y la lista de subdominios, y devuelve cada servicio a su"
    echo "  certificado autofirmado anterior. Los registros DNS de Cloudflare no se tocan."
    read -r -p "  Escribe QUITAR para confirmar (ENTER = cancelar): " W
    [[ "$W" == "QUITAR" ]] || { INFO "Cancelado."; PAUSA; return; }
    ssl_quitar
    PAUSA
}

menu_ssl(){
    local DOM DIAS
    while true; do
        cabecera
        SUBTOP "$(T t_sub_ssl)"
        FR_OPT 1 "🌐 $(T t_ssl_dom)" "" ""
        FR_OPT 2 "➕ $(T t_ssl_crear)" "" ""
        FR_OPT 3 "📋 $(T t_ssl_subs)" "" ""
        FR_OPT 4 "🔒 $(T t_ssl_emitir)" "" ""
        FR_OPT 5 "🔁 $(T t_ssl_renovar)" "" ""
        FR_OPT 6 "📊 $(T t_ssl_estado)" "" ""
        FR_OPT 7 "🔧 $(T t_ssl_aplicar)" "" ""
        FR_OPT 8 "🧹 $(T t_ssl_quitar)" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        DOM=$(ssl_conf_get DOMINIO); DIAS=$(ssl_dias_restantes)
        if [[ -z "$DOM" ]]; then FR_TXT "  ${GRIS}$(T t_ssl_sin_dom)${NC}"
        elif [[ -n "$DIAS" ]]; then FR_TXT "  🌐 ${BLANCO}${DOM}${NC} ${GRIS}·${NC} 🔒 ${VERDE}${DIAS} $(T t_ui_days)${NC}"
        else FR_TXT "  🌐 ${BLANCO}${DOM}${NC} ${GRIS}·${NC} ${AMARILLO}$(T t_ssl_sin_cert)${NC}"; fi
        FR_BOT
        PROMPT
        case "$OP" in
            1) ssl_dominio_poner ;; 2) ssl_sub_crear ;; 3) ssl_subs_menu ;; 4) ssl_emitir ;;
            5) ssl_renovar ;; 6) ssl_estado ;; 7) ssl_aplicar ;; 8) ssl_quitar_menu ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_seguridad(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_seg)"
        FR_OPT 1 "🚨 $(T t_fail2ban)" 5 "🔎 $(T t_ver_puertos)"
        FR_OPT 2 "🚦 $(T t_limiter_on)" 6 "🔓 $(T t_abrir_puerto)"
        FR_OPT 3 "🛑 $(T t_limiter_off)" 7 "📢 $(T t_banner)"
        FR_OPT 4 "🔑 $(T t_puerto_ssh)" 8 "🔒 $(T t_ssl)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_fail2ban ;; 2) limiter_aplicar ;; 3) limiter_quitar ;;
            4) cambiar_puerto_ssh ;; 5) ver_puertos ;; 6) abrir_puerto ;; 7) menu_banner ;; 8) menu_ssl ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_sistema(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_sistema)"
        FR_OPT 1 "$(T t_monitoreo)" 5 "$(T t_mantenimiento)"
        FR_OPT 2 "$(T t_optimizar)" 6 "$(T t_hostname)"
        FR_OPT 3 "$(T t_swap)" 7 "$(T t_update)"
        FR_OPT 4 "$(T t_zram)" 8 "$(T t_reiniciar)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) monitoreo ;; 2) optimizar ;; 3) agregar_swap ;; 4) agregar_zram ;;
            5) mantenimiento ;; 6) cambiar_hostname ;; 7) update_sistema ;; 8) reiniciar_vps ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_tema(){
    # Submenu de temas: aplica y guarda al instante (la cabecera se redibuja con los nuevos colores)
    local m
    while true; do
        cabecera
        SUBTOP "$(T t_sub_tema)"
        m=""; [[ "$GHOST_THEME" == fantasma ]] && m=" ✅"; FR_OPT 1 "👻 Fantasma · violeta/cian$m" "" ""
        m=""; [[ "$GHOST_THEME" == neon ]]     && m=" ✅"; FR_OPT 2 "⚡ Neon · verde/magenta$m" "" ""
        m=""; [[ "$GHOST_THEME" == matrix ]]   && m=" ✅"; FR_OPT 3 "💚 Matrix · verde$m" "" ""
        m=""; [[ "$GHOST_THEME" == naranja ]]  && m=" ✅"; FR_OPT 4 "🧡 Naranja · fuego$m" "" ""
        m=""; [[ "$GHOST_THEME" == hielo ]]    && m=" ✅"; FR_OPT 5 "🧊 Hielo · azul/cian$m" "" ""
        m=""; [[ "$GHOST_THEME" == carbon ]]   && m=" ✅"; FR_OPT 6 "⚫ Carbon · monocromo$m" "" ""
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) tema_aplicar fantasma; tema_guardar fantasma ;;
            2) tema_aplicar neon;     tema_guardar neon ;;
            3) tema_aplicar matrix;   tema_guardar matrix ;;
            4) tema_aplicar naranja;  tema_guardar naranja ;;
            5) tema_aplicar hielo;    tema_guardar hielo ;;
            6) tema_aplicar carbon;   tema_guardar carbon ;;
            0) break ;;
            *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}
menu_herramientas(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_herr)"
        FR_OPT 1 "🌍 $(T t_global)" 4 "🔄 $(T t_autoupdate)"
        FR_OPT 2 "🚀 $(T t_automenu_on)" 5 "📡 $(T t_checkuser)"
        FR_OPT 3 "🛑 $(T t_automenu_off)" 6 "🔤 $(T t_idioma)"
        UI_KCOL[8]="$ROJO"     # Desinstalar siempre en rojo
        FR_OPT 7 "🎨 $(T t_tema)" 8 "🔥 $(T t_desinst_c)"
        UI_KCOL=()
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_comando_global ;; 2) auto_menu ;; 3) quitar_auto_menu ;;
            4) auto_update ;; 5) menu_checkuser ;; 7) menu_tema ;; 8) desinstalar_ghost ;;
            6) rm -f /etc/vps-manager.lang; seleccionar_idioma; ficha_ok "🌐 IDIOMA" "Idioma" "$IDIOMA"; PAUSA ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_backup(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_backup)"
        FR_OPT 1 "$(T t_backup_crear)" 2 "$(T t_backup_restaurar)"
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
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
    if ! pedir_puerto SP "Puerto SS [8388]: " "8388" both; then PAUSA; return; fi
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
        ficha_abrir "🎭 SHADOWSOCKS ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "IP / Host" "$IP"
        ficha_fila "Puerto" "$SP (tcp + udp)"
        ficha_fila "Cifrado" "aes-256-gcm"
        ficha_fila "Contraseña" "$PASS" "$VERDE"
        ficha_cerrar
        printf '%bEnlace para el cliente (SS/SSR compatible):%b\n%b%s%b\n' "$AMARILLO" "$NC" "$VERDE" "ss://$B64@$IP:$SP#VPSJB-SS" "$NC"
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
    if ! pedir_puerto TP "Puerto Trojan [9443]: " "9443" tcp; then PAUSA; return; fi
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
    xray_recargar 2>/dev/null
    sleep 1
    if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
        local IP; IP=$(ip_publica)
        ficha_abrir "🐴 TROJAN ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "IP / Host" "$IP"
        ficha_fila "Puerto" "$TP/tcp"
        ficha_fila "SNI" "$SNI"
        ficha_fila "Contraseña" "$PASS" "$VERDE"
        ficha_cerrar
        printf '%bEnlace para el cliente (activar allowInsecure):%b\n%b%s%b\n' "$AMARILLO" "$NC" "$VERDE" "trojan://$PASS@$IP:$TP?security=tls&sni=$SNI&allowInsecure=1#VPSJB-Trojan" "$NC"
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
    if ! pedir_puerto WP "Puerto UDP [51820]: " "51820" udp; then PAUSA; return; fi
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
        # DNS: si AdGuard Home esta activo en el VPS, forzar el DNS interno del tunel
        local WGDNS="1.1.1.1"
        if systemctl is-active --quiet AdGuardHome 2>/dev/null || pgrep -f AdGuardHome >/dev/null 2>&1; then
            WGDNS="10.66.0.1"
            INFO "AdGuard Home detectado: DNS del cliente = 10.66.0.1 (adblock en el tunel)."
        elif [[ -f /opt/AdGuardHome/AdGuardHome ]]; then
            WGDNS="10.66.0.1"
            INFO "AdGuard Home instalado: DNS del cliente = 10.66.0.1."
        fi
        cat > /root/wg-client.conf <<CLIENTEOF
[Interface]
PrivateKey = $CPRIV
Address = 10.66.0.2/24
DNS = $WGDNS

[Peer]
PublicKey = $SPUB
Endpoint = $IP:$WP
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTEOF
        ficha_ok "🐉 WIREGUARD ACTIVO" "Estado" "ACTIVO" "IP / Host" "$IP" "Puerto" "$WP/udp" "DNS del cliente" "$WGDNS" "Config cliente" "/root/wg-client.conf"
        # Si AdGuard esta instalado, reescribir config para bindear 10.66.0.1 ahora que la IP existe
        if adguard_instalado 2>/dev/null; then
            INFO "Actualizando AdGuard Home para escuchar en 10.66.0.1 (adblock en el tunel)..."
            adguard_escribir_config /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
            systemctl restart AdGuardHome 2>/dev/null || true
        fi
        ficha_abrir "📲 CONFIG PARA LA APP WIREGUARD" "$AMARILLO"
        cat /root/wg-client.conf
        ficha_cerrar
        if command -v qrencode >/dev/null 2>&1; then
            echo -e " ${CIAN}QR para escanear desde el celular:${NC}"
            qrencode -t ansiutf8 < /root/wg-client.conf 2>/dev/null || qrencode -t UTF8 < /root/wg-client.conf 2>/dev/null || true
        else
            INFO "Instala qrencode para ver QR: apt install -y qrencode"
            read -r -p "Instalar qrencode ahora y mostrar QR? (s/n): " SNQ
            if [[ "$SNQ" == "s" ]]; then
                apt install -y qrencode >/dev/null 2>&1 && qrencode -t ansiutf8 < /root/wg-client.conf 2>/dev/null || true
            fi
        fi
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
    ficha_ok "🗑 XRAY REMOVIDO" "Incluye" "Xray, Trojan y WS" "Estado" "desinstalado"
    PAUSA
}
quitar_wsepro(){
    systemctl disable --now vpsjb-ws 2>/dev/null
    rm -f /etc/systemd/system/vpsjb-ws.service /usr/local/bin/vpsjb-ws.py
    systemctl daemon-reload 2>/dev/null
    pkill -f vpsjb-ws.py 2>/dev/null
    ficha_ok "🗑 WS-EPRO REMOVIDO" "Servicio" "detenido y eliminado"
    PAUSA
}
quitar_stunnel(){
    systemctl disable --now stunnel4 2>/dev/null
    service stunnel4 stop 2>/dev/null
    rm -f /etc/stunnel/stunnel.conf /etc/stunnel/stunnel.pem /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key
    read -r -p "Tambien desinstalar el paquete stunnel4? (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        apt purge -y stunnel4 2>/dev/null && apt autoremove -y >/dev/null 2>&1
        ficha_ok "🗑 STUNNEL REMOVIDO" "Servicio" "detenido" "Paquete" "eliminado"
    else
        ficha_ok "🗑 STUNNEL REMOVIDO" "Servicio" "detenido" "Paquete" "permanece instalado"
    fi
    PAUSA
}
quitar_hysteria(){
    systemctl disable --now hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service /etc/hysteria/config.yaml
    systemctl daemon-reload 2>/dev/null
    pkill -x hysteria 2>/dev/null
    read -r -p "Tambien borrar binario/certificados de Hysteria? (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        rm -rf /etc/hysteria /usr/local/bin/hysteria 2>/dev/null
        # instalador oficial suele dejar unit en /etc/systemd/system
        rm -f /etc/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server*.service 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        ficha_ok "🗑 HYSTERIA2 REMOVIDO" "Servicio" "detenido" "Binario y certificados" "eliminados"
    else
        ficha_ok "🗑 HYSTERIA2 REMOVIDO" "Servicio" "detenido" "Binario" "puede permanecer"
    fi
    PAUSA
}
quitar_shadowsocks(){
    systemctl disable --now vpsjb-ss 2>/dev/null
    rm -f /etc/systemd/system/vpsjb-ss.service /etc/shadowsocks-libev/config.json
    systemctl daemon-reload 2>/dev/null
    pkill -x ss-server 2>/dev/null
    read -r -p "Tambien desinstalar el paquete shadowsocks-libev? (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        apt purge -y shadowsocks-libev 2>/dev/null && apt autoremove -y >/dev/null 2>&1
        ficha_ok "🗑 SHADOWSOCKS REMOVIDO" "Servicio" "detenido" "Paquete" "eliminado"
    else
        ficha_ok "🗑 SHADOWSOCKS REMOVIDO" "Servicio" "detenido" "Paquete" "permanece instalado"
    fi
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
    xray_recargar 2>/dev/null
    ficha_ok "🗑 TROJAN REMOVIDO" "Estado" "quitado de Xray"
    PAUSA
}
quitar_wireguard(){
    systemctl disable --now wg-quick@wg0 2>/dev/null
    rm -f /etc/wireguard/wg0.conf /root/wg-client.conf
    read -r -p "Tambien desinstalar el paquete wireguard? (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        apt purge -y wireguard wireguard-tools 2>/dev/null && apt autoremove -y >/dev/null 2>&1
        ficha_ok "🗑 WIREGUARD REMOVIDO" "Servicio" "detenido" "Paquete" "eliminado"
    else
        ficha_ok "🗑 WIREGUARD REMOVIDO" "Servicio" "detenido" "Paquete" "permanece instalado"
    fi
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
        FR_OPT 0 "🔙 $(T t_volver)" "" ""
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
        ficha_ok "🧠 ZRAM ACTIVA" "Tamaño" "${G} GB" "Prioridad" "alta (más rápida que swap de disco)"
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
        ficha_abrir "⛅ TÚNEL CDN ACTIVO"
        ficha_fila "Estado" "ACTIVO" "$VERDE"
        ficha_fila "Servidor" "${URL#https://}" "$VERDE"
        ficha_fila "Puerto" "443"
        ficha_fila "Path" "/"
        ficha_fila "Log" "/var/log/ghost-cf-tunnel.log"
        ficha_fila "Para frenar" "pkill cloudflared"
        ficha_cerrar
        printf '%b%s%b\n' "$VERDE" "$URL" "$NC"
        WARN "La URL cambia al reiniciar el túnel. Es para pruebas/demos."
        INFO "En la app: WebSocket activado, servidor ${URL#https://}, puerto 443, path /"
    else
        ERR "El tunel no dio URL a tiempo. Log:"
        tail -5 /var/log/ghost-cf-tunnel.log 2>/dev/null
    fi
    PAUSA
}

quitar_tunel_cdn(){
    pkill -x cloudflared 2>/dev/null && ficha_ok "⛅ TÚNEL CDN DETENIDO" "Estado" "detenido" || ERR "No habia tunel corriendo."
    PAUSA
}

# ------------------------------------------------------------
# DESINSTALAR GHOST PANEL
# Quita servicios, archivos, config de sshd/Dropbear, reglas iptables, auto-menu, logs
# y el propio script. Reutiliza las funciones quitar_* (sin pausas, respondiendo "s").
# ------------------------------------------------------------
desinst_run(){
    # desinst_run FUNCION -> la ejecuta sin PAUSA y contestando "s" a sus preguntas
    ( export DEBIAN_FRONTEND=noninteractive; PAUSA(){ :; }; yes s 2>/dev/null | "$@" ) 2>&1 | sed 's/^/  /'
}

desinst_protocolos(){
    # Solo actua sobre lo que realmente esta instalado (evita ruido y apt innecesario)
    [[ -e /usr/local/bin/xray || -d /usr/local/etc/xray ]]            && desinst_run quitar_xray_completo
    [[ -f /etc/systemd/system/vpsjb-ws.service ]]                      && desinst_run quitar_wsepro
    [[ -f /etc/stunnel/stunnel.conf ]]                                 && desinst_run quitar_stunnel
    [[ -d /etc/hysteria || -e /usr/local/bin/hysteria ]]              && desinst_run quitar_hysteria
    [[ -f /etc/shadowsocks-libev/config.json || -f /etc/systemd/system/vpsjb-ss.service ]] && desinst_run quitar_shadowsocks
    [[ -f /etc/wireguard/wg0.conf ]]                                   && desinst_run quitar_wireguard
    [[ -f /etc/systemd/system/badvpn.service || -e /usr/local/bin/badvpn-udpgw ]] && desinst_run quitar_badvpn
    [[ -d /opt/AdGuardHome ]]                                          && desinst_run quitar_adguard
    [[ -d /etc/webmin ]]                                               && desinst_run remover_webmin
    # Tunel CDN (cloudflared)
    pkill -x cloudflared 2>/dev/null
    dpkg -s cloudflared >/dev/null 2>&1 && dpkg -r cloudflared >/dev/null 2>&1 && OK "cloudflared removido."
    rm -f /root/cloudflared.deb /var/log/ghost-cf-tunnel.log
    # zram persistente
    if [[ -f /etc/systemd/system/vpsjb-zram.service ]]; then
        systemctl disable --now vpsjb-zram 2>/dev/null
        swapoff /dev/zram0 2>/dev/null; zramctl --reset /dev/zram0 2>/dev/null
        rm -f /etc/systemd/system/vpsjb-zram.service
        OK "zram removido."
    fi
    # swapfile creado por el panel
    if [[ -f /swapfile ]] || grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
        swapoff /swapfile 2>/dev/null; rm -f /swapfile
        sed -i '\#^/swapfile #d' /etc/fstab 2>/dev/null
        OK "Swapfile removido."
    fi
    rmdir /etc/wireguard /etc/stunnel /etc/hysteria 2>/dev/null
    return 0
}

desinstalar_ghost(){
    local RUN WORD R U L N=0 DO_USERS=0 DO_PROTO=1 DO_BK=0 DO_KEY=0 USERS=()
    ficha_abrir "🔥 $(T t_du_titulo)" "$ROJO"
    echo "Se eliminará TODO lo que creó Ghost Panel:"
    echo "   · Servicios: limiter, CheckUser, cron de vencidos y de auto-corte, contadores iptables, Bot Telegram"
    echo "   · Banners (OpenSSH Match User, /etc/banner-vps, Dropbear) y auto-menu"
    echo "   · Datos: limites, trafico, usuarios del panel, licencia, idioma, links, logs"
    echo "   · Dominio y SSL: certificado, hooks de renovacion y lista de subdominios"
    echo "   · Ajustes: sysctl/BBR del panel, jail.local de fail2ban"
    echo "   · El comando ghostpanel (vpsmgr, vps) y este archivo del script"
    ficha_cerrar
    while read -r U; do
        usuario_protegido "$U" && continue
        USERS+=("$U")
    done < <(usuarios_panel)

    read -r -p "  ¿Quitar tambien los protocolos instalados (Xray, WS, Hysteria, Stunnel, WireGuard, AdGuard, Webmin...)? (S/n): " R
    [[ "$R" =~ ^[nN]$ ]] && DO_PROTO=0
    if (( ${#USERS[@]} > 0 )); then
        echo -e "  ${AMARILLO}Usuarios SSH detectados (${#USERS[@]}):${NC} ${USERS[*]}"
        read -r -p "  ¿ELIMINAR tambien estos usuarios y sus carpetas /home? (s/N): " R
        [[ "$R" =~ ^[sSyY]$ ]] && DO_USERS=1
    fi
    if compgen -G "/root/backups/ghost-panel-v*.sh" >/dev/null || compgen -G "/root/backups/backup-*.tar.gz" >/dev/null; then
        read -r -p "  ¿Borrar tambien los respaldos en /root/backups? (s/N): " R
        [[ "$R" =~ ^[sSyY]$ ]] && DO_BK=1
    fi
    bot_backup_key_respaldar        # si el bot esta instalado, asegura la copia antes de preguntar
    if [[ -f "$BOT_KEY_COPIA" ]]; then
        echo -e "  ${AMARILLO}Clave de backup del bot:${NC} $BOT_KEY_COPIA"
        echo "  Sin ella no se pueden abrir los backups cifrados que ya tienes en Telegram."
        read -r -p "  ¿Borrar tambien esa clave? (s/N): " R
        [[ "$R" =~ ^[sSyY]$ ]] && DO_KEY=1
    fi
    echo
    read -r -p "  $(T t_du_conf) " WORD
    if [[ "${WORD^^}" != "$(T t_du_word)" ]]; then INFO "Cancelado. No se toco nada."; PAUSA; return; fi
    echo

    # 1) Usuarios (opcional): primero, mientras xray/sshd siguen existiendo
    if (( DO_USERS )); then
        for U in "${USERS[@]}"; do purgar_usuario "$U" && N=$((N+1)); done
        OK "Usuarios eliminados: $N"
    fi

    # 2) Servicios propios del panel
    INFO "Deteniendo servicios del panel..."
    desinst_run limiter_quitar
    desinst_run checkuser_quitar
    desinst_run bot_telegram_desinstalar_silencioso   # detiene y borra /opt/ghost-bot
    rm -f /usr/local/bin/vps-limiter.sh /usr/local/bin/vps-checkuser.py /usr/local/bin/vps-cron-diario.sh \
          /etc/cron.d/ghost-panel-vencidos /etc/cron.d/ghost-panel-trafico /usr/local/bin/vps-trafico-cron.sh /run/ghost-trafico.lock /etc/vps-checkuser.conf \
          /etc/logrotate.d/ghost-panel

    # 3) sshd / Dropbear: banner global, bloques Match User, overrides neutralizados
    INFO "Limpiando sshd_config y banners..."
    desinst_run banner_eliminar
    if grep -q '# GHOST-BANNERS-INICIO' "$SSHD_CFG" 2>/dev/null; then
        sed -i '/# GHOST-BANNERS-INICIO/,/# GHOST-BANNERS-FIN/d' "$SSHD_CFG"
    fi
    for L in /etc/ssh/sshd_config.d/*.conf; do   # reactiva los "Banner" que el panel comento
        [[ -f "$L" ]] && sed -i -E 's/^# (.*)   # desactivado por GHOST PANEL$/\1/' "$L"
    done
    rm -f /etc/ssh/sshd_config.d/*.ghost.bak "${SSHD_CFG}.ghost.bak" "${SSHD_CFG}.ghost-banners.bak"
    if sshd -t 2>/dev/null; then sshd_recargar 2>/dev/null || true
    else WARN "sshd_config no valida: revisa /etc/ssh/sshd_config antes de reiniciar sshd."; fi
    rm -rf /etc/vps-banners

    # 4) Contadores de trafico
    iptables -D OUTPUT -j VPS-TRAFFIC 2>/dev/null
    iptables -F VPS-TRAFFIC 2>/dev/null; iptables -X VPS-TRAFFIC 2>/dev/null

    # 4b) Dominio y SSL: devuelve los certificados originales y borra hooks/certbot (si lo puso el panel)
    if [[ -d "$SSL_DIR" ]]; then INFO "Quitando Dominio y SSL..."; desinst_run ssl_quitar; fi

    # 5) Protocolos instalados por el panel (opcional)
    if (( DO_PROTO )); then
        INFO "Quitando protocolos instalados..."
        desinst_protocolos
    fi

    # 6) Ajustes del sistema hechos por el panel
    rm -f /etc/sysctl.d/99-vps-manager.conf /etc/modules-load.d/bbr.conf /etc/security/limits.d/99-ghost-panel.conf /etc/fail2ban/jail.local
    systemctl is-active --quiet fail2ban 2>/dev/null && systemctl restart fail2ban 2>/dev/null
    systemctl daemon-reload 2>/dev/null

    # 7) Datos, licencia, config, auto-menu
    INFO "Borrando datos y configuracion..."
    rm -rf /etc/vps-limits /etc/vps-trafico /etc/vps-users /etc/vps-plan /etc/vps-cuota-agotada /var/log/ghost-trafico-hist
    rm -f /etc/vps-manager.key /etc/vps-manager.lang /etc/vps-license.cache /etc/vps-license.name \
          /etc/ghost-panel.conf /run/vps-ip.cache /root/vps-links.txt /root/wg-client.conf /root/paquetes.txt
    [[ -d /etc/openvpn ]] || rm -f /root/openvpn-install.sh      # si OpenVPN sigue, se conserva su instalador
    for L in /root/.bashrc "$HOME/.bashrc"; do
        [[ -f "$L" ]] && sed -i '/VPS-JB-AUTOMENU-INICIO/,/VPS-JB-AUTOMENU-FIN/d' "$L"
    done
    if (( DO_BK )); then
        rm -f /root/backups/ghost-panel-v*.sh /root/backups/backup-*.tar.gz
        rmdir /root/backups 2>/dev/null
        OK "Respaldos borrados."
    fi
    if (( DO_KEY )); then
        rm -f "$BOT_KEY_COPIA"; rmdir "$(dirname "$BOT_KEY_COPIA")" 2>/dev/null
        OK "Clave de backup del bot borrada."
    fi

    # 8) Comando global + este script + log (lo ultimo: despues no se escribe nada al log)
    RUN=$(readlink -f "$0" 2>/dev/null)
    for L in vpsmgr vps; do
        [[ -L "/usr/local/bin/$L" && "$(readlink -f "/usr/local/bin/$L")" == "$(readlink -f "$VPSMGR_DEST")" ]] \
            && rm -f "/usr/local/bin/$L"
    done
    rm -f "$VPSMGR_DEST"
    [[ -n "$RUN" && -f "$RUN" ]] && rm -f "$RUN"
    rm -f /var/log/ghost-panel.log

    ficha_abrir "👻 GHOST PANEL DESINSTALADO" "$VERDE"
    echo -e "${VERDE}$(T t_du_fin)${NC}"
    echo -e "${GRIS}No se tocaron: paquetes del sistema (python3, curl, ufw, fail2ban...), reglas UFW ya abiertas,"
    echo -e "PasswordAuthentication de sshd, ni OpenVPN (para quitarlo: bash /root/openvpn-install.sh).${NC}"
    ficha_cerrar
    echo
    exit 0
}

# ------------------------------------------------------------
# MENU PRINCIPAL
# ------------------------------------------------------------
# ------------------------------------------------------------
# INSTANCIA UNICA (3.11.6): un solo panel a la vez
# pidfile + flock (solo durante el chequeo) + starttime del proceso (un PID reutilizado no cuenta).
# El flock NO queda abierto en el panel, asi que no lo heredan xray/cloudflared/etc. lanzados desde aqui.
# ------------------------------------------------------------
GHOST_PIDFILE=/run/ghost-panel.pid
GHOST_LOCKFILE=/run/ghost-panel.lock
ghost_proc_inicio(){
    # starttime (campo 22 de /proc/PID/stat)
    local s f
    read -r s 2>/dev/null < "/proc/$1/stat" || return 1
    s=${s##*) }
    read -ra f <<< "$s"
    printf '%s' "${f[19]}"
}
ghost_instancia_viva(){
    # ghost_instancia_viva PID INICIO -> 0 si ese PID sigue siendo la misma instancia
    [[ "$1" =~ ^[0-9]+$ && -r "/proc/$1/stat" ]] || return 1
    [[ "$(ghost_proc_inicio "$1")" == "$2" ]]
}
ghost_instancia_liberar(){
    local pid _i
    read -r pid _i 2>/dev/null < "$GHOST_PIDFILE" || return 0
    [[ "$pid" == "$$" ]] && rm -f "$GHOST_PIDFILE"
    return 0
}
ghost_instancia_unica(){
    local pid ini tty up op n=0
    while (( n++ < 5 )); do
        # reclamar el lugar de forma atomica (el lock vive solo dentro de este subshell)
        if (
            flock -x 9
            if read -r pid ini 2>/dev/null < "$GHOST_PIDFILE" && [[ "$pid" != "$$" ]] && ghost_instancia_viva "$pid" "$ini"; then exit 1; fi
            printf '%s %s\n' "$$" "$(ghost_proc_inicio "$$")" > "$GHOST_PIDFILE"
        ) 9>"$GHOST_LOCKFILE"; then
            trap ghost_instancia_liberar EXIT
            return 0
        fi
        read -r pid ini 2>/dev/null < "$GHOST_PIDFILE" || continue
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        up=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ -z "$tty" || "$tty" == "?" ]]; then
            # sin terminal = huerfana: se cierra sola y esta instancia toma su lugar
            vps_log WARN "instancia huerfana del panel (PID $pid) cerrada"
            kill "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
            continue
        fi
        [[ -t 0 ]] || { echo "Ghost Panel ya esta abierto (PID $pid, $tty)."; exit 1; }
        ficha_aviso "⚠ GHOST PANEL YA ESTÁ ABIERTO" "PID" "$pid" "Terminal" "$tty" "Abierto hace" "$up"
        echo -e "  ${CIAN}[1]${NC} Cerrar la otra sesión y continuar aquí"
        echo -e "  ${ROJO}[0]${NC} Salir"
        read -r -p "  ❯ " op || exit 0
        [[ "$op" == 1 ]] || exit 0
        kill "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
    done
    echo "No se pudo tomar el bloqueo de instancia unica." >&2
    exit 1
}

[[ $EUID -ne 0 ]] && { echo -e "${ROJO}Ejecuta como root o con sudo.${NC}"; exit 1; }
export GHOST_PANEL_ACTIVO=1          # shells hijos (auto-menu) no vuelven a abrir el panel
ghost_instancia_unica
GHOST_IDLE=$(ghost_conf_get IDLE_TIMEOUT); [[ "$GHOST_IDLE" =~ ^[0-9]+$ ]] || GHOST_IDLE=1200

seleccionar_idioma
gate_licencia
ghost_intro
ghost_bootstrap
auto_menu_migrar                      # snippet viejo del .bashrc -> con guardas (sin terminal / anidado)
[[ -f /etc/systemd/system/vps-limiter.service ]] && ! grep -q 'GHOST-LIMITER-V2' /usr/local/bin/vps-limiter.sh 2>/dev/null && limiter_migrar
[[ -f "$BOT_DIR/config.env" ]] && bot_refresh_helper 2>/dev/null   # helper del bot a la par de esta version
bot_autoactualizar 2>/dev/null || true          # y el propio bot.py (si cambio de revision)
ghost_tz_primera_vez
[[ -f /etc/cron.d/ghost-panel-trafico ]] && trafico_cron_instalar   # mantiene el cron a la par de esta version
[[ -f "$SSL_DIR/domain.conf" ]] && ssl_hook_instalar             # idem para los hooks de renovacion SSL
# Comando global: ghostpanel (si el script se ejecuta desde otra ruta, lo instala)
if [[ "$(readlink -f "$0" 2>/dev/null)" != "$(readlink -f "$VPSMGR_DEST" 2>/dev/null)" ]]; then
    install -m 755 "$(readlink -f "$0")" "$VPSMGR_DEST" 2>/dev/null && {
        ln -sf "$VPSMGR_DEST" /usr/local/bin/vpsmgr 2>/dev/null || true
        ln -sf "$VPSMGR_DEST" /usr/local/bin/vps 2>/dev/null || true
    }
fi

while true; do
    CAB_FULL=1 cabecera
    ui_box_top "$(T t_menu_principal)"
    for _i in 1 2 3 4 5 6 7 8 9; do UI_KCOL[$_i]="\033[1;38;5;${TH_ITEMS[_i-1]}m"; done   # tonos del tema
    FR_OPT 1 "👤 $(T t_usuarios)" 2 "🔌 $(T t_protocolos)"
    FR_OPT 3 "🔰 $(T t_seguridad)" 4 "🔧 $(T t_sistema)"
    FR_OPT 5 "🧰 $(T t_herramientas)" 6 "🌐 $(T t_webmin)"
    FR_OPT 7 "💾 $(T t_backup)" 8 "🩺 $(T t_diagnostico)"
    # (sin linea en blanco: [9]/[0] queda pegado al resto del menu en celulares)
    FR_OPT 9 "🤖 $(T t_bot)" 0 "🚪 $(T t_salir)"
    FR_BOT
    UI_KCOL=()
    echo -e "  ${GRIS}$(T t_servidor_id) ${VERDE}$(machine_hash)${GRIS}  ·  $(ghost_fecha)${NC}"
    PROMPT
    case "$OP" in
        1) seccion 1 menu_usuarios ;;
        2) seccion 2 menu_protocolos ;;
        3) seccion 3 menu_seguridad ;;
        4) seccion 4 menu_sistema ;;
        5) seccion 5 menu_herramientas ;;
        6) seccion 6 menu_webmin ;;
        7) seccion 7 menu_backup ;;
        8) seccion 8 diagnostico ;;
        9) seccion 9 menu_bot_telegram ;;
        0) echo -e "👻 ${VERDE}Hasta luego!${NC}"; exit 0 ;;
        *) ERR "$(T t_opinv)"; sleep 1 ;;
    esac
done
