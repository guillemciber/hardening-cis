#!/usr/bin/env bash
# Bastionat limitat a les mesures documentades de l'activitat. Debian 13.
set -Euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

CONTROL=INICI
CANVIS=0 BACKUPS=0 SERVEIS=0 OK=0 AVISOS=0 ERRORS=0 COMPROVACIONS=0 MODIFICATS=0
NUM_CONTROL=0 COLOR_ACTIU=0
declare -a RESULTATS=() DETALL_ERRORS=() DETALL_AVISOS=() DETALL_COMPROVACIONS=() TX=()
declare -A ORIGINAL=() MOTIUS_OMES=()
TMP= BACKUP_DIR= LOG= APT_ACTUALITZAT=0
CANVI_CONTROL=0 EXECUCIO_CONTROL=0 AVIS_CONTROL=0 COMPROVACIO_CONTROL=0 MOTIU_CONTROL= MOTIU_OMES=

# La sortida del terminal pot tenir colors; el registre sempre és text pla.
missatge() {
    local etiqueta=$1 descripcio=$2 color=
    if [[ $etiqueta == ERROR && $CONTROL != FINAL && -z $MOTIU_CONTROL ]]; then
        MOTIU_CONTROL=$descripcio
    elif [[ $etiqueta == 'OMÈS' && -z $MOTIU_OMES ]]; then
        MOTIU_OMES=$descripcio
    fi
    if [[ -n $LOG ]]; then
        printf '[%s] [%s] %s\n' "$etiqueta" "$CONTROL" "$descripcio" >> "$LOG" || return 1
    fi
    if ((COLOR_ACTIU)); then
        case "$etiqueta" in
            INFO) color='36';;
            OK|'CORREGIT') color='1;32';;
            CANVI) color='1;34';;
            'OMÈS') color='2';;
            'COMPROVACIÓ REQUERIDA') color='1;35';;
            'AVÍS') color='1;33';;
            ERROR) color='1;31';;
            BACKUP|RESTORE) color='35';;
            RESUM) color='1;37';;
        esac
    fi
    if [[ -n $color ]]; then
        printf '\033[%sm[%s]\033[0m %s\n' "$color" "$etiqueta" "$descripcio" >&3
    else
        printf '[%s] %s\n' "$etiqueta" "$descripcio" >&3
    fi
}

capcalera() {
    local titol=$1 color=${2:-'1;36'}
    local ratlla='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n%s\n' "$ratlla" "$titol" >> "$LOG" || return 1
    if ((COLOR_ACTIU)); then
        printf '\n\033[%sm%s\n%s\033[0m\n' "$color" "$ratlla" "$titol" >&3
    else
        printf '\n%s\n%s\n' "$ratlla" "$titol" >&3
    fi
}

nom_control() {
    case "$1" in
        'PKGS-7388 / LYNIS-REPO') printf 'Repositoris APT i clau de CISOfy';;
        'LYNIS — eina d’auditoria') printf 'Paquet Lynis';;
        DEB-0280) printf 'Directori temporal per usuari';;
        DEB-0810) printf 'Avisos d’errors de paquets';;
        DEB-0831) printf 'Detecció de reinicis necessaris';;
        PKGS-7370) printf 'Integritat dels paquets: debsums';;
        PKGS-7394) printf 'Versions dels paquets';;
        PKGS-7392) printf 'Certificats de confiança';;
        PKGS-7420) printf 'Actualitzacions automàtiques amb APT';;
        BOOT-5180) printf 'Servei de correu Exim4';;
        AUTH-9328) printf 'Màscara UMASK i sessions PAM';;
        USB-1000) printf 'Emmagatzematge USB';;
        NETW-3200) printf 'Protocols de xarxa innecessaris';;
        STRG-1846) printf 'Emmagatzematge FireWire';;
        'NAME-4028 / NAME-4404') printf 'Nom de domini local';;
        'SSH-7408 — LogLevel, X11Forwarding i AllowTcpForwarding') printf 'Configuració del servidor SSH';;
        ENTORN) printf 'Comprovacions de funcionament';;
        'ACTUALITZACIÓ DE PAQUETS') printf 'Actualització general amb APT';;
        *) printf 'Control de seguretat';;
    esac
}
avis() { AVISOS=$((AVISOS+1)); AVIS_CONTROL=1; DETALL_AVISOS+=("$CONTROL: $*"); missatge 'AVÍS' "$*"; }
comprovacio() {
    COMPROVACIONS=$((COMPROVACIONS+1))
    COMPROVACIO_CONTROL=1
    DETALL_COMPROVACIONS+=("$CONTROL: $*")
    missatge 'COMPROVACIÓ REQUERIDA' "$*"
}
error() { ERRORS=$((ERRORS+1)); DETALL_ERRORS+=("$CONTROL: $*"); missatge ERROR "$*"; }
verificat() { OK=$((OK+1)); missatge OK "$*"; }

# La transacció només cobreix els fitxers del control actual, no paquets ni serveis.
restaura() {
    local f i fallada=0
    for ((i=${#TX[@]}-1; i>=0; i--)); do
        f=${TX[i]}
        if [[ ${ORIGINAL[$f]} == NO_EXISTIA ]]; then
            if ! rm -f -- "$f"; then fallada=1; error "No s'ha pogut eliminar $f; intervenció manual."; fi
        elif ! cp -a -- "${ORIGINAL[$f]}" "$f"; then
            fallada=1; error "Restauració fallida de $f; intervenció manual: ${ORIGINAL[$f]}"
        fi
        if ((fallada == 0)); then missatge RESTORE "Restaurat: $f (origen: ${ORIGINAL[$f]})."; fi
    done
    TX=()
    (( fallada == 0 ))
}
mostra_detalls() {
    local etiqueta=$1 nom=$2 detall trobat=0
    shift 2
    for detall in "$@"; do
        [[ $detall == "$nom: "* ]] || continue
        missatge "$etiqueta" "$detall"
        trobat=1
    done
    ((trobat))
}
resum() {
    local r estat nom corregits=0 omesos=0 pendents=0 amb_avisos=0 amb_errors=0
    for r in "${RESULTATS[@]}"; do
        case "$r" in
            *' | CORREGIT') corregits=$((corregits+1));;
            *' | OMÈS') omesos=$((omesos+1));;
            *' | COMPROVACIÓ REQUERIDA') pendents=$((pendents+1));;
            *' | AVÍS') amb_avisos=$((amb_avisos+1));;
            *' | ERROR') amb_errors=$((amb_errors+1));;
        esac
    done
    CONTROL=FINAL
    capcalera 'RESUM FINAL · HARDENING CIS' '1;35'
    missatge RESUM "Controls gestionats: ${#RESULTATS[@]}; modificats: $MODIFICATS; corregits i verificats: $corregits; omesos: $omesos"
    missatge RESUM "Controls amb comprovació requerida: $pendents; amb avisos: $amb_avisos; amb errors: $amb_errors"
    missatge RESUM "Verificacions correctes: $OK; comprovacions manuals: $COMPROVACIONS; avisos: $AVISOS; errors: $ERRORS"
    missatge RESUM "Escriptures de fitxers: $CANVIS; còpies: $BACKUPS; operacions de servei: $SERVEIS (inclou intents revertits)."
    for r in "${RESULTATS[@]}"; do
        nom=${r%% | *}; estat=${r##* | }
        case "$estat" in
            'OMÈS')
                missatge 'OMÈS' "$nom — ${MOTIUS_OMES[$nom]:-Ja compleix el control; no cal modificar res.}";;
            'COMPROVACIÓ REQUERIDA')
                mostra_detalls 'COMPROVACIÓ REQUERIDA' "$nom" "${DETALL_COMPROVACIONS[@]}" ||
                    missatge ERROR "$nom: Falta el detall de la comprovació requerida al registre.";;
            'AVÍS')
                mostra_detalls 'AVÍS' "$nom" "${DETALL_AVISOS[@]}" ||
                    missatge ERROR "$nom: Falta el detall de l’avís al registre."
                mostra_detalls 'COMPROVACIÓ REQUERIDA' "$nom" "${DETALL_COMPROVACIONS[@]}" || :;;
            'ERROR')
                mostra_detalls ERROR "$nom" "${DETALL_ERRORS[@]}" ||
                    missatge ERROR "$nom: El control ha fallat sense diagnòstic; consulteu $LOG.";;
            *) missatge "$estat" "$nom";;
        esac
    done
    missatge RESUM "Registre: $LOG; còpies, si n'hi ha: $BACKUP_DIR"
}
finalitza() {
    local rc=$?
    trap - EXIT INT TERM
    if ((${#TX[@]})); then restaura || :; fi
    if (( rc != 0 && ERRORS == 0 )); then error "Interrupció inesperada (codi $rc); revisar el registre."; fi
    resum
    [[ -z $TMP ]] || rm -rf -- "$TMP"
    (( ERRORS == 0 && rc == 0 )) || exit 1
}
control() {
    local estat causa
    CONTROL=$1; shift
    NUM_CONTROL=$((NUM_CONTROL+1))
    CANVI_CONTROL=0 EXECUCIO_CONTROL=0 AVIS_CONTROL=0 COMPROVACIO_CONTROL=0 MOTIU_CONTROL= MOTIU_OMES= TX=()
    printf -v estat '%02d' "$NUM_CONTROL"
    capcalera "[$estat] $CONTROL · $(nom_control "$CONTROL")"
    if "$@"; then
        TX=()
        if ((AVIS_CONTROL)); then estat='AVÍS'
        elif ((COMPROVACIO_CONTROL)); then estat='COMPROVACIÓ REQUERIDA'
        elif ((CANVI_CONTROL || EXECUCIO_CONTROL)); then estat='CORREGIT'
        else estat='OMÈS'; fi
    else
        causa=${MOTIU_CONTROL:-"No s'ha pogut completar o verificar el control; consulteu $LOG per identificar l'ordre que ha fallat."}
        if [[ -n $MOTIU_CONTROL ]]; then
            ERRORS=$((ERRORS+1))
            DETALL_ERRORS+=("$CONTROL: $causa")
        else
            error "$causa"
        fi
        if ((${#TX[@]})); then restaura || :; fi
        estat=ERROR
    fi
    if ((CANVI_CONTROL)); then MODIFICATS=$((MODIFICATS+1)); fi
    if [[ $estat == 'OMÈS' ]]; then MOTIUS_OMES[$CONTROL]=${MOTIU_OMES:-'Ja compleix el control; no cal modificar res.'}; fi
    RESULTATS+=("$CONTROL | $estat")
    if [[ $estat == CORREGIT || $estat == 'OMÈS' ]]; then
        missatge "$estat" "Resultat del control: $estat."
    fi
}

# Comparació prèvia, còpia immutable per execució i substitució en el mateix FS.
posa_fitxer() {
    local origen=$1 desti=$2 temporal pare
    if [[ -L $desti || ( -e $desti && ! -f $desti ) ]]; then
        missatge ERROR "Fitxer especial o enllaç no admès: $desti"; return 1
    fi
    if [[ -f $desti ]] && cmp -s -- "$origen" "$desti"; then
        missatge 'OMÈS' "$desti ja té el contingut previst."; return 0
    fi
    pare=${desti%/*}
    [[ -d $pare ]] || { missatge ERROR "Directori absent: $pare"; return 1; }
    mkdir -p -m 0700 -- "$BACKUP_DIR${desti%/*}" || {
        missatge ERROR "No es pot crear el directori de còpia de $desti."; return 1;
    }
    if [[ -e $desti ]]; then
        cp -a -- "$desti" "$BACKUP_DIR$desti" || {
            missatge ERROR "No es pot fer la còpia prèvia de $desti."; return 1;
        }
        ORIGINAL[$desti]="$BACKUP_DIR$desti"
        BACKUPS=$((BACKUPS+1)); missatge BACKUP "$desti -> $BACKUP_DIR$desti"
    else ORIGINAL[$desti]=NO_EXISTIA; fi
    printf '%s\t%s\n' "$desti" "${ORIGINAL[$desti]}" >> "$BACKUP_DIR/manifest.txt" || {
        missatge ERROR "No es pot registrar $desti al manifest de còpies."; return 1;
    }
    temporal=$(mktemp "$pare/.hardening-cis.XXXXXXXX") || {
        missatge ERROR "No es pot crear un fitxer temporal a $pare."; return 1;
    }
    if [[ -f $desti ]]; then
        cp --preserve=all -- "$desti" "$temporal" || {
            rm -f "$temporal"; missatge ERROR "No es poden preservar les metadades de $desti."; return 1;
        }
    else
        chmod 0644 "$temporal" && chown root:root "$temporal" || {
            rm -f "$temporal"; missatge ERROR "No es poden establir permisos de $desti."; return 1;
        }
    fi
    cat -- "$origen" > "$temporal" || {
        rm -f "$temporal"; missatge ERROR "No es pot preparar el contingut de $desti."; return 1;
    }
    TX+=("$desti")
    mv -f -- "$temporal" "$desti" || {
        rm -f "$temporal"; missatge ERROR "No es pot substituir $desti; s'intentarà restaurar-lo."; return 1;
    }
    CANVIS=$((CANVIS+1)); CANVI_CONTROL=1
    missatge CANVI "Contingut actualitzat: $desti"
}

crea_transformador() {
cat > "$TMP/transforma.py" <<'PYTHON'
# Transformacions pures: només llegeixen entrades i escriuen a la zona temporal.
import glob
import os
import re
import sys
from pathlib import Path


def falla(text):
    raise ValueError(text)


def login(text):
    lines = text.splitlines(True)
    out, found = [], False
    for line in lines:
        if re.match(r'^\s*UMASK\s+', line):
            if not found:
                out.append('UMASK 027\n')
                found = True
        else:
            out.append(line)
    if not found:
        out.append(('\n' if text and not text.endswith('\n') else '') + 'UMASK 027\n')
    return ''.join(out)


def pam(text):
    lines = text.splitlines(True)
    hits = [i for i, line in enumerate(lines)
            if not line.lstrip().startswith('#') and re.search(r'\bpam_umask\.so\b', line)]
    if len(hits) > 1:
        falla('Múltiples entrades pam_umask: cal revisar-les sense alterar salts PAM.')
    if hits:
        i = hits[0]
        body, sep, comment = lines[i].partition('#')
        m = re.fullmatch(r'(\s*session\s+(?:optional|required|requisite|sufficient|\[[^\]]+\])\s+(?:/\S*/)?pam_umask\.so)([^\n]*)\n?', body)
        if not m:
            falla('Entrada PAM no reconeguda; no es modifica.')
        options = [x for x in m[2].split() if x not in ('usergroups', 'nousergroups') and not x.startswith('umask=')]
        # umask explícita evita que GECOS anul·li login.defs; manté els altres arguments.
        options += ['nousergroups', 'umask=027']
        lines[i] = m[1] + ' ' + ' '.join(options) + (' #' + comment.rstrip('\n') if sep else '') + '\n'
    else:
        # Afegir al final no canvia les destinacions dels salts numèrics existents.
        if not re.search(r'^session\s+required\s+pam_permit\.so\s*$', text, re.M):
            falla('Pila PAM sense patró Debian reconegut; revisió manual necessària.')
        lines.append(('\n' if text and not text.endswith('\n') else '') + 'session optional pam_umask.so nousergroups umask=027\n')
    return ''.join(lines)


def modul(text, name):
    wanted = f'install {name} /bin/false\n'
    lines, found = [], False
    for line in text.splitlines(True):
        tokens = line.split('#', 1)[0].split()
        if len(tokens) >= 2 and tokens[0] == 'install' and tokens[1].replace('_', '-') == name:
            if not found:
                lines.append(wanted); found = True
        else:
            lines.append(line)
    if not found:
        lines.append(('\n' if text and not text.endswith('\n') else '') + wanted)
    return ''.join(lines)


def hosts(text, short):
    if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', short):
        falla('Hostname curt no vàlid.')
    fqdn = short + '.internal'
    out, aliases, seen = [], [], False
    for line in text.splitlines(True):
        body, sep, comment = line.partition('#')
        fields = body.split()
        if not fields:
            out.append(line); continue
        if fields[0] == '127.0.1.1':
            aliases += [x for x in fields[1:] if x.lower() not in (short.lower(), fqdn.lower())]
            if sep: out.append('#' + comment.rstrip('\n') + '\n')
            if not seen: out.append(None); seen = True
        elif any(x.lower() in (short.lower(), fqdn.lower()) for x in fields[1:]):
            falla('Associació prèvia del hostname a una altra IP: revisió manual.')
        else: out.append(line)
    entry = '127.0.1.1 ' + ' '.join([fqdn, short] + list(dict.fromkeys(aliases))) + '\n'
    if seen: out = [entry if x is None else x for x in out]
    else: out.append(('\n' if text and not text.endswith('\n') else '') + entry)
    return ''.join(out)


def deb822(text):
    count = 0
    parts = re.split(r'(\n[ \t]*\n)', text)
    for i in range(0, len(parts), 2):
        block = parts[i]
        fields, spans, current = {}, {}, None
        lines = block.splitlines(True)
        for j, line in enumerate(lines):
            if line.startswith('#') or not line.strip(): continue
            if line[:1].isspace():
                if current is None: falla('Continuació Deb822 sense camp.')
                fields[current] += ' ' + line.strip(); spans[current].append(j)
                continue
            m = re.match(r'^([A-Za-z-]+):\s*(.*?)\s*$', line)
            if not m: falla('Sintaxi Deb822 no reconeguda.')
            current = m[1].lower()
            if current in fields: falla('Camp Deb822 duplicat.')
            fields[current] = m[2]; spans[current] = [j]
        if fields.get('enabled', 'yes').lower() == 'no': continue
        if 'trixie-security' not in fields.get('suites', '').split(): continue
        if 'deb' not in fields.get('types', '').split(): continue
        count += 1
        uris = fields.get('uris', '').split()
        azure = [u for u in uris if u.startswith('mirror+file:')]
        if azure:
            if len(uris) != 1 or fields['suites'].split() != ['trixie-security']:
                falla('Bloc de seguretat mixt: separar-lo manualment abans de continuar.')
            if not azure[0].startswith('mirror+file:///etc/apt/mirrors/'):
                falla('mirror+file fora del patró esperat; revisió manual.')
            if fields.get('signed-by') != '/usr/share/keyrings/debian-archive-keyring.gpg':
                falla('Signed-By de Debian no reconegut; es preserva sense canvis.')
            ix = spans['uris']
            lines[ix[0]] = 'URIs: http://security.debian.org/debian-security/\n'
            for j in ix[1:]: lines[j] = ''
            parts[i] = ''.join(lines)
    return ''.join(parts), count


def tradicional(text):
    count, out = 0, []
    for line in text.splitlines(True):
        m = re.match(r'^(\s*deb\s+(?:\[[^\]]+\]\s+)?)(\S+)(\s+trixie-security\s+.*)$', line.rstrip('\n'))
        if m:
            count += 1
            if m[2].startswith('mirror+file:'):
                if not m[2].startswith('mirror+file:///etc/apt/mirrors/'):
                    falla('mirror+file desconegut.')
                if 'signed-by=/usr/share/keyrings/debian-archive-keyring.gpg' not in m[1]:
                    falla('Signed-By absent o no reconegut; cal revisió manual.')
                line = m[1] + 'http://security.debian.org/debian-security/' + m[3] + '\n'
        out.append(line)
    return ''.join(out), count


def ssh_plan(main, outdir):
    plans, visited = {}, set()
    def walk(path, matched=False):
        path = Path(path)
        if path.is_symlink(): falla('Include SSH amb enllaç simbòlic: revisió manual.')
        key = str(path.resolve())
        if key in visited: falla('Include SSH repetit o cíclic: revisió manual.')
        visited.add(key)
        output = []
        for line in path.read_text().splitlines(True):
            body = line.split('#', 1)[0].strip()
            pair = re.split(r'[\s=]+', body, maxsplit=1)
            name = pair[0].lower()
            value = pair[1].strip() if len(pair) > 1 else ''
            if name == 'match': matched = True
            if name == 'include':
                # Includes simples d'OpenSSH; rebutjar sintaxi ambigua.
                if any(c in value for c in ('"', "'", '%', '\\')):
                    falla('Include SSH complex; revisió manual.')
                for pattern in value.split():
                    if not pattern.startswith('/'): pattern = '/etc/ssh/' + pattern
                    for sub in sorted(glob.glob(pattern)):
                        matched = walk(sub, matched)
            if name in ('loglevel', 'x11forwarding', 'allowtcpforwarding'):
                desired = 'verbose' if name == 'loglevel' else 'no'
                print(f'Directiva SSH: {path}: {name} {value}', file=sys.stderr)
                if matched:
                    if value.lower() != desired:
                        falla('Un bloc Match contradiu el valor desitjat; es preserva i requereix revisió manual.')
                else:
                    continue
            output.append(line)
        plans[str(path)] = ''.join(output)
        return matched
    walk(main)
    plans[main] = 'LogLevel VERBOSE\nX11Forwarding no\nAllowTcpForwarding no\n' + plans[main]
    for path, content in plans.items():
        dest = Path(outdir + path)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content)


if __name__ == '__main__':
    try:
        mode, args = sys.argv[1], sys.argv[2:]
        if mode == 'ssh': ssh_plan(*args)
        elif mode == 'repos':
            root, outdir = args
            paths = sorted(set(glob.glob(root + '/sources.list') + glob.glob(root + '/sources.list.d/*.list') + glob.glob(root + '/sources.list.d/*.sources')))
            count = 0
            for path in paths:
                text = Path(path).read_text()
                new, n = (deb822 if path.endswith('.sources') else tradicional)(text)
                count += n
                if new != text:
                    target = Path(outdir + path)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(new)
            if count == 0: falla('No hi ha cap repositori trixie-security actiu. Cal configurar-lo manualment.')
            if count > 1: falla('Múltiples entrades trixie-security: revisar possibles duplicats manualment.')
        else:
            path, output, *extra = args
            text = Path(path).read_text() if Path(path).exists() else ''
            new = {'login': login, 'pam': pam, 'hosts': hosts, 'modul': modul}[mode](text, *extra)
            Path(output).write_text(new)
    except (ValueError, OSError) as exc:
        print('ERROR: ' + str(exc), file=sys.stderr)
        sys.exit(1)
PYTHON
}

aplica_pla() {
    local dir=$1 f
    while IFS= read -r -d '' f; do
        posa_fitxer "$f" "${f#"$dir"}" || {
            missatge ERROR "No s'ha pogut aplicar el fitxer preparat ${f#"$dir"}."; return 1;
        }
    done < <(find "$dir" -type f -print0 | sort -z)
}
transforma() {
    local sortida
    if ! sortida=$(python3 "$TMP/transforma.py" "$@" 2>&1); then
        missatge ERROR "Transformació de configuració fallida: ${sortida##*$'\n'}"
        return 1
    fi
    [[ -z $sortida ]] || missatge INFO "$sortida"
}
motiu_apt() {
    local fitxer=$1
    if grep -Eiq 'NO_PUBKEY|EXPKEYSIG|signature|signatura|not signed' "$fitxer"; then
        printf 'problema de signatura o clau d’un repositori'
    elif grep -Eiq 'Temporary failure resolving|Could not resolve|Name or service not known' "$fitxer"; then
        printf 'fallada de resolució DNS'
    elif grep -Eiq 'Could not get lock|Unable to acquire the dpkg frontend lock' "$fitxer"; then
        printf 'bloqueig d’APT o dpkg per un altre procés'
    elif grep -Eiq 'unmet dependencies|held broken packages' "$fitxer"; then
        printf 'dependències de paquets no resoltes'
    elif grep -Eiq '404 Not Found|does not have a Release file' "$fitxer"; then
        printf 'font de paquets inexistent o sense fitxer Release'
    elif grep -Eiq 'Connection refused|Connection timed out|Failed to fetch' "$fitxer"; then
        printf 'error de connexió o descàrrega'
    else
        printf 'APT ha retornat un error no classificat'
    fi
}
actualitza_apt() {
    ((APT_ACTUALITZAT == 0)) || return 0
    missatge INFO 'Validant repositoris i actualitzant els índexs APT necessaris per als controls de paquets.'
    if ! apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 update > "$TMP/apt.log" 2>&1; then
        missatge ERROR "apt-get update ha fallat: $(motiu_apt "$TMP/apt.log"). Detall privat: $LOG.apt"
        cp "$TMP/apt.log" "$LOG.apt" || :
        return 1
    fi
    APT_ACTUALITZAT=1; verificat 'Índexs APT actualitzats amb signatures verificades.'
}
index_si_cal() {
    local recent
    ((APT_ACTUALITZAT == 0)) || return 0
    recent=$(find /var/lib/apt/lists -maxdepth 1 -name '*InRelease' -mmin -1440 -print -quit) || {
        missatge ERROR 'No es poden inspeccionar els índexs locals d’APT.'; return 1;
    }
    if [[ -z $recent ]]; then actualitza_apt; else missatge 'OMÈS' 'Índex APT recent (<24 hores); es reutilitza.'; fi
}
instal_lat() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }
paquet() {
    local p=$1 actual candidat actualitza=${2:-no}
    actual=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null) || actual=absent
    missatge INFO "$p: versió inicial $actual"
    if instal_lat "$p" && [[ $actualitza == no ]]; then
        missatge 'OMÈS' "$p ja està instal·lat."; verificat "dpkg: $p instal·lat."; return 0
    fi
    index_si_cal || return 1
    candidat=$(apt-cache policy "$p" | awk '/Candidate:/ {print $2; exit}') || {
        missatge ERROR "No s'ha pogut consultar la versió candidata de $p."; return 1;
    }
    [[ -n $candidat && $candidat != '(none)' ]] || { missatge ERROR "Sense candidat per a $p"; return 1; }
    missatge INFO "$p: candidat $candidat"
    if instal_lat "$p" && ! dpkg --compare-versions "$candidat" gt "$actual"; then
        verificat "$p ja és igual o superior al candidat."; return 0
    fi
    missatge INFO "Instal·lant/actualitzant únicament $p i les dependències necessàries."
    if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y --no-remove \
        -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        install "$p=$candidat" > "$TMP/apt-paquet.log" 2>&1; then
        cp "$TMP/apt-paquet.log" "$LOG.$p.apt" || :
        missatge ERROR "Instal·lació de $p fallida: $(motiu_apt "$TMP/apt-paquet.log"). Detall privat: $LOG.$p.apt. APT pot haver deixat canvis parcials."
        return 1
    fi
    CANVI_CONTROL=1
    instal_lat "$p" || { missatge ERROR "dpkg no confirma la instal·lació de $p."; return 1; }
    actual=$(dpkg-query -W -f='${Version}' "$p") || { missatge ERROR "No es pot llegir la versió instal·lada de $p."; return 1; }
    dpkg --compare-versions "$actual" eq "$candidat" || {
        missatge ERROR "Versió inesperada de $p: instal·lada $actual, candidata $candidat."; return 1;
    }
    missatge CANVI "$p instal·lat: $actual"; verificat "Estat i versió de $p verificats amb dpkg."
}

actualitzacions_automatiques() {
    local fitxer=/etc/apt/apt.conf.d/52hardening-cis-auto-upgrades valors temporitzador
    paquet unattended-upgrades || return 1
    valors=$(apt-config shell HC_LISTS APT::Periodic::Update-Package-Lists \
        HC_UPGRADE APT::Periodic::Unattended-Upgrade) || {
        missatge ERROR 'No es pot llegir la configuració efectiva d’APT.'; return 1;
    }
    if ! grep -Fqx "HC_LISTS='1'" <<< "$valors" ||
       ! grep -Fqx "HC_UPGRADE='1'" <<< "$valors"; then
        printf '%s\n' \
            'APT::Periodic::Update-Package-Lists "1";' \
            'APT::Periodic::Unattended-Upgrade "1";' > "$TMP/auto-upgrades.conf" || {
                missatge ERROR 'No es pot preparar la configuració periòdica d’APT.'; return 1;
            }
        posa_fitxer "$TMP/auto-upgrades.conf" "$fitxer" || return 1
        valors=$(apt-config shell HC_LISTS APT::Periodic::Update-Package-Lists \
            HC_UPGRADE APT::Periodic::Unattended-Upgrade) || {
            missatge ERROR 'No es pot verificar la configuració periòdica d’APT.'; return 1;
        }
    fi
    grep -Fqx "HC_LISTS='1'" <<< "$valors" &&
    grep -Fqx "HC_UPGRADE='1'" <<< "$valors" || {
        missatge ERROR 'APT manté desactivades les actualitzacions periòdiques; revisar directives posteriors a 52hardening-cis-auto-upgrades.'; return 1;
    }
    verificat 'APT té configurades la renovació diària dels índexs i les actualitzacions automàtiques.'
    for temporitzador in apt-daily.timer apt-daily-upgrade.timer; do
        if ! systemctl is-enabled --quiet "$temporitzador" ||
           ! systemctl is-active --quiet "$temporitzador"; then
            systemctl enable --now "$temporitzador" || {
                missatge ERROR "No es pot habilitar i iniciar $temporitzador."; return 1;
            }
            CANVI_CONTROL=1; SERVEIS=$((SERVEIS+1))
            missatge CANVI "Temporitzador $temporitzador habilitat i iniciat."
        fi
        systemctl is-enabled --quiet "$temporitzador" &&
        systemctl is-active --quiet "$temporitzador" || {
            missatge ERROR "$temporitzador no continua habilitat i actiu."; return 1;
        }
        verificat "$temporitzador habilitat i actiu."
    done
}

repositoris() {
    local f altre=0 clau=/etc/apt/keyrings/cisofy.gpg repo=/etc/apt/sources.list.d/cisofy-lynis.list
    mkdir "$TMP/repos" || { missatge ERROR 'No es pot preparar el directori temporal dels repositoris.'; return 1; }
    transforma repos /etc/apt "$TMP/repos" || return 1
    # Evitar afegir una segona entrada CISOfy en un altre fitxer o format.
    while IFS= read -r -d '' f; do
        if [[ $f != "$repo" ]] && grep -Eq '^[^#]*packages\.cisofy\.com/community/lynis' "$f"; then
            missatge ERROR "CISOfy ja apareix a $f; consolidar-lo manualment al fitxer dedicat."; altre=1
        fi
    done < <(find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \) -print0)
    ((altre == 0)) || return 1
    if [[ -f $repo ]] && grep -Ev '^([[:space:]]*(#.*)?|deb \[signed-by=/etc/apt/keyrings/cisofy.gpg\] https://packages.cisofy.com/community/lynis/deb/ stable main)$' "$repo" > /dev/null; then
        missatge ERROR "El fitxer CISOfy conté entrades diferents; revisar-lo manualment."; return 1
    fi
    if [[ ! -d /etc/apt/keyrings ]]; then
        install -d -m 0755 /etc/apt/keyrings || { missatge ERROR 'No es pot crear /etc/apt/keyrings.'; return 1; }
        CANVI_CONTROL=1; missatge CANVI 'Creat el directori /etc/apt/keyrings.'
    fi
    if [[ ! -s $clau ]]; then
        curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 60 \
            https://packages.cisofy.com/keys/cisofy-software-public.key -o "$TMP/cisofy.asc" || {
                missatge ERROR 'No s’ha pogut descarregar la clau pública de CISOfy per HTTPS.'; return 1;
            }
        gpg --batch --homedir "$TMP/gpg" --dearmor --output "$TMP/cisofy.gpg" "$TMP/cisofy.asc" || {
            missatge ERROR 'La clau descarregada de CISOfy no es pot convertir a format GPG.'; return 1;
        }
        posa_fitxer "$TMP/cisofy.gpg" "$clau" || return 1
    fi
    gpg --batch --homedir "$TMP/gpg" --show-keys "$clau" > "$TMP/clau.txt" 2>&1 || {
        missatge ERROR "La clau de $clau no és llegible o no és una clau GPG vàlida."; return 1;
    }
    [[ $(stat -c '%a:%u:%g' "$clau") == 644:0:0 ]] || { missatge ERROR 'La clau necessita permisos 0644 i propietari root:root; revisió manual.'; return 1; }
    printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/cisofy.gpg] https://packages.cisofy.com/community/lynis/deb/ stable main' > "$TMP/cisofy.list" || {
        missatge ERROR 'No es pot preparar temporalment la font APT de CISOfy.'; return 1;
    }
    posa_fitxer "$TMP/cisofy.list" "$repo" || return 1
    aplica_pla "$TMP/repos" || return 1
    if ((CANVI_CONTROL)); then actualitza_apt || return 1; else index_si_cal || return 1; fi
    verificat 'Repositoris inspeccionats; altres suites i Signed-By preservats.'
}

umask_pam() {
    local f n=0
    compgen -G '/usr/lib/*/security/pam_umask.so' > /dev/null || [[ -f /usr/lib/security/pam_umask.so ]] || {
        missatge ERROR 'El mòdul pam_umask.so no està disponible al sistema.'; return 1;
    }
    for f in /etc/login.defs /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        [[ -f $f ]] || { missatge ERROR "Falta el fitxer de configuració $f."; return 1; }
        missatge INFO "Inspeccionant $f"
        if [[ $f == /etc/login.defs ]]; then
            transforma login "$f" "$TMP/pam-$n" || return 1
        else transforma pam "$f" "$TMP/pam-$n" || return 1; fi
        n=$((n+1))
    done
    n=0
    for f in /etc/login.defs /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        posa_fitxer "$TMP/pam-$n" "$f" || return 1; n=$((n+1))
    done
    [[ $(grep -Ec '^[[:space:]]*UMASK[[:space:]]+027[[:space:]]*$' /etc/login.defs) == 1 ]] || {
        missatge ERROR 'La verificació de /etc/login.defs no troba exactament una directiva UMASK 027.'; return 1;
    }
    for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        transforma pam "$f" "$TMP/pam-verificat" || return 1
        cmp -s "$f" "$TMP/pam-verificat" || {
            missatge ERROR "La configuració PAM de $f no coincideix amb la directiva prevista."; return 1;
        }
    done
    verificat 'Coherència estàtica de login.defs i pam_umask; no és una prova completa de PAM.'
    if command -v sshd > /dev/null; then
        comprovacio 'Obrir una sessió SSH nova i executar umask; el valor esperat és 0027.'
    else
        comprovacio 'Obrir una sessió d’usuari nova i executar umask; el valor esperat és 0027.'
    fi
}

moduls() {
    local m fitxer sortida nom
    for m in "$@"; do
        case "$m" in firewire-sbp2) fitxer=/etc/modprobe.d/disable-firewire-storage.conf;; *) fitxer="/etc/modprobe.d/disable-$m.conf";; esac
        transforma modul "$fitxer" "$TMP/modul" "$m" || return 1
        posa_fitxer "$TMP/modul" "$fitxer" || return 1
        # Comprovar la regla del mòdul concret: una dependència amb /bin/false no basta.
        modprobe -c | awk -v module="${m//-/_}" '
            $1 == "install" {gsub(/-/, "_", $2); if ($2 == module) {
                n++; if ($3 != "/bin/false" || NF != 3) bad=1
            }} END {exit !(n > 0 && !bad)}' || {
                missatge ERROR "Regles efectives contradictòries o absents per a $m."; return 1;
            }
        sortida=$(modprobe -n -v --show-depends "$m" 2>&1) || { missatge ERROR "$m: $sortida"; return 1; }
        missatge INFO "$m: $sortida"
        grep -Eq '^install /bin/false([[:space:]]|$)' <<< "$sortida" || {
            missatge ERROR "La simulació de modprobe per a $m no mostra install /bin/false."; return 1;
        }
        verificat "modprobe impedeix la càrrega habitual de $m; les dependències prèvies són admissibles."
        nom=${m//-/_}
        if [[ -d /sys/module/$nom ]]; then avis "$m ja està carregat; no es descarrega. La restricció no elimina l'ús actual."; fi
        if [[ $m == firewire-sbp2 ]]; then
            for nom in /sys/module/firewire*; do [[ ! -d $nom ]] || avis "FireWire carregat: ${nom##*/}; no es modifica."; done
        fi
    done
}

exim() {
    local load actiu habilitat
    load=$(systemctl show exim4.service -p LoadState --value) || {
        missatge ERROR 'systemctl no pot consultar exim4.service.'; return 1;
    }
    if [[ $load == not-found ]]; then missatge 'OMÈS' 'Exim4 no existeix; no cal aturar-lo.'; return 0; fi
    actiu=$(systemctl is-active exim4.service) || :
    habilitat=$(systemctl is-enabled exim4.service) || :
    missatge INFO "Exim4 abans: actiu=$actiu; habilitat=$habilitat"
    if [[ $actiu != inactive && $actiu != failed ]] || [[ $habilitat == enabled* || $habilitat == linked* || $habilitat == alias ]]; then
        systemctl disable --now exim4.service || {
            missatge ERROR 'systemctl no ha pogut aturar i deshabilitar exim4.service.'; return 1;
        }
        CANVI_CONTROL=1; SERVEIS=$((SERVEIS+1)); missatge CANVI 'Exim4 aturat i deshabilitat (VM sense funció de correu).'
    fi
    actiu=$(systemctl is-active exim4.service) || :
    habilitat=$(systemctl is-enabled exim4.service) || :
    missatge INFO "Exim4 després: actiu=$actiu; habilitat=$habilitat"
    [[ $actiu == inactive || $actiu == failed ]] || {
        missatge ERROR "Exim4 continua actiu després del canvi: $actiu."; return 1;
    }
    [[ $habilitat == disabled || $habilitat == masked || $habilitat == static ]] || {
        missatge ERROR "Exim4 continua habilitat després del canvi: $habilitat."; return 1;
    }
    verificat 'Exim4 no està actiu ni habilitat.'
}

fqdn() {
    local nom curt f
    nom=$(hostname -f 2>/dev/null) || nom=
    if [[ $nom == *.* && $nom != *localhost* ]] && getent hosts "$nom" > "$TMP/fqdn"; then
        verificat "FQDN ja resoluble: $nom"; return 0
    fi
    if instal_lat cloud-init; then
        # Configuració dinàmica (metadata/user-data) pot prevaler: no s'endevina.
        missatge ERROR 'cloud-init instal·lat: confirmar i desactivar-ne explícitament la gestió de hosts fora de l’script abans d’aplicar aquest control.'
        return 1
    fi
    for f in /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/*.cfg; do
        [[ -f $f ]] || continue
        if grep -Eq '^[[:space:]]*manage_etc_hosts:[[:space:]]*(true|yes|1|localhost|template)' "$f"; then
            missatge ERROR "hosts gestionat per cloud-init ($f); no es modifica."; return 1
        fi
    done
    curt=$(hostname -s) || { missatge ERROR 'No s’ha pogut obtenir el hostname curt.'; return 1; }
    transforma hosts /etc/hosts "$TMP/hosts" "$curt" || return 1
    posa_fitxer "$TMP/hosts" /etc/hosts || return 1
    nom=$(hostname -f) || { missatge ERROR 'hostname -f no retorna cap FQDN després del canvi.'; return 1; }
    [[ ${nom,,} == "${curt,,}.internal" ]] || {
        missatge ERROR "FQDN inesperat després del canvi: $nom; s’esperava $curt.internal."; return 1;
    }
    getent hosts "$nom" || { missatge ERROR "getent no pot resoldre $nom després del canvi."; return 1; }
    verificat "Resolució local comprovada: $nom"
}

ssh() {
    local abans despres diagnostic
    if ! command -v sshd > /dev/null; then missatge 'OMÈS' 'Servidor SSH absent; no s’instal·la.'; return 0; fi
    if ! diagnostic=$(sshd -t 2>&1); then
        missatge ERROR "La configuració inicial de SSH no supera sshd -t: ${diagnostic##*$'\n'}"; return 1
    fi
    abans=$(sshd -T) || { missatge ERROR 'No es pot llegir la configuració efectiva inicial amb sshd -T.'; return 1; }
    missatge INFO "Valors globals inicials: $(grep -E '^(loglevel|x11forwarding|allowtcpforwarding) ' <<< "$abans")"
    mkdir "$TMP/ssh" || { missatge ERROR 'No es pot preparar el directori temporal de SSH.'; return 1; }
    # Analitzar també els Match quan els valors globals ja són correctes.
    transforma ssh /etc/ssh/sshd_config "$TMP/ssh" || return 1
    if grep -qix 'loglevel VERBOSE' <<< "$abans" &&
       grep -qix 'x11forwarding no' <<< "$abans" &&
       grep -qix 'allowtcpforwarding no' <<< "$abans"; then
        verificat 'Valors globals correctes i cap Match contradictori detectat.'; return 0
    fi
    aplica_pla "$TMP/ssh" || return 1
    if ! diagnostic=$(sshd -t 2>&1); then
        missatge ERROR "La configuració SSH modificada no supera sshd -t: ${diagnostic##*$'\n'}"; return 1
    fi
    despres=$(sshd -T) || { missatge ERROR 'No es pot llegir la configuració efectiva modificada amb sshd -T.'; return 1; }
    grep -qix 'loglevel VERBOSE' <<< "$despres" &&
    grep -qix 'x11forwarding no' <<< "$despres" &&
    grep -qix 'allowtcpforwarding no' <<< "$despres" || {
        missatge ERROR 'sshd -T no confirma LogLevel VERBOSE, X11Forwarding no i AllowTcpForwarding no.'; return 1;
    }
    # Verificar que cap altre valor global ha canviat.
    diff -u <(grep -Ev '^(loglevel|x11forwarding|allowtcpforwarding) ' <<< "$abans") <(grep -Ev '^(loglevel|x11forwarding|allowtcpforwarding) ' <<< "$despres") || {
        missatge ERROR 'Han canviat altres paràmetres globals de SSH; es restaurarà la configuració anterior.'; return 1;
    }
    if [[ $abans != "$despres" ]] && systemctl is-active --quiet ssh.service; then
        if ! systemctl reload ssh.service; then
            restaura || return 1
            sshd -t && systemctl reload ssh.service || { missatge ERROR 'SSH no s’ha pogut recuperar; intervenció manual urgent.'; return 1; }
            missatge ERROR 'Recàrrega fallida; configuració anterior restaurada i recarregada.'; return 1
        fi
        SERVEIS=$((SERVEIS+1)); missatge CANVI 'SSH recarregat una única vegada.'
    fi
    verificat "sshd -t i sshd -T correctes: $(grep -E '^(loglevel|x11forwarding|allowtcpforwarding) ' <<< "$despres")"
}

entorn() {
    if command -v sshd > /dev/null; then
        local diagnostic
        if ! diagnostic=$(sshd -t 2>&1); then
            missatge ERROR "La configuració SSH no supera sshd -t durant la revisió final: ${diagnostic##*$'\n'}"; return 1
        fi
        systemctl is-active ssh.service || avis 'SSH no està actiu.'
    fi
    hostname -f && getent hosts "$(hostname -f)" || avis 'Resolució local pendent de revisar.'
    if timeout 15 getent hosts debian.org > /dev/null; then verificat 'Resolució externa de debian.org correcta.'
    else avis 'No s’ha pogut comprovar DNS extern; no es modifica cap DNS.'; fi
    if command -v docker > /dev/null; then
        systemctl is-active docker.service || avis 'El servei Docker no està actiu o utilitza una altra modalitat.'
        timeout 15 docker ps --format '{{.Names}}: {{.Status}}' || avis 'No es pot consultar Docker.'
    else missatge 'OMÈS' 'Docker i aplicacions associades: no aplicable.'; fi
    if command -v sshd > /dev/null; then
        comprovacio 'Obrir una connexió SSH nova des d’una altra màquina i confirmar que es pot iniciar sessió.'
    fi
    if command -v docker > /dev/null; then
        comprovacio 'Si hi ha aplicacions publicades amb Docker, comprovar-ne l’accés des de l’exterior.'
    fi
}

actualitzacio_final() {
    local repositoris_correctes=$1 resum_apt paquets
    if ((repositoris_correctes == 0)); then
        missatge ERROR 'No es pot fer l’actualització general: la configuració dels repositoris no s’ha validat.'
        return 1
    fi

    missatge INFO 'Actualitzant els índexs de tots els repositoris configurats amb apt-get update.'
    if ! apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 update > "$TMP/apt-final-update.log" 2>&1; then
        cp "$TMP/apt-final-update.log" "$LOG.update.apt" || :
        missatge ERROR "apt-get update ha fallat: $(motiu_apt "$TMP/apt-final-update.log"). Detall privat: $LOG.update.apt"
        return 1
    fi
    APT_ACTUALITZAT=1
    verificat 'apt-get update completat amb tots els repositoris disponibles.'

    missatge INFO 'Actualitzant els paquets instal·lats amb apt-get upgrade, sense eliminar paquets.'
    if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y --no-remove \
        -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        upgrade > "$TMP/apt-final-upgrade.log" 2>&1; then
        cp "$TMP/apt-final-upgrade.log" "$LOG.upgrade.apt" || :
        missatge ERROR "apt-get upgrade ha fallat: $(motiu_apt "$TMP/apt-final-upgrade.log"). Detall privat: $LOG.upgrade.apt. Pot haver-hi paquets actualitzats parcialment."
        return 1
    fi
    resum_apt=$(awk '/^[0-9]+ upgraded,/{linia=$0} END{print linia}' "$TMP/apt-final-upgrade.log")
    if [[ -n $resum_apt ]]; then missatge INFO "Resultat APT: $resum_apt"; fi
    paquets=${resum_apt%% *}
    if [[ $paquets =~ ^[0-9]+$ ]] && ((paquets > 0)); then
        CANVI_CONTROL=1
        missatge CANVI "S’han actualitzat $paquets paquets."
    else
        missatge INFO 'L’ordre upgrade ha acabat sense paquets actualitzats o sense un recompte interpretable.'
    fi
    EXECUCIO_CONTROL=1
    verificat 'apt-get upgrade completat correctament.'
}

main() {
    local ordre id versio repositoris_correctes=1
    if (($#)); then
        if [[ $# == 1 && $1 == --help ]]; then
            printf '%s\n' 'Ús: sudo bash hardening_cis.sh' 'Aplica canvis exclusivament en una VM Debian 13 autoritzada. No té mode de simulació.'; return 0
        fi
        printf '%s\n' 'Argument desconegut. Consulteu --help.' >&2; return 2
    fi
    ((EUID == 0)) || { printf '%s\n' '[ERROR] Cal ser root.' >&2; return 1; }
    id=$(. /etc/os-release; printf '%s' "$ID")
    versio=$(. /etc/os-release; printf '%s' "$VERSION_ID")
    [[ $id == debian && $versio == 13 ]] || { printf '%s\n' '[ERROR] Cal Debian 13.' >&2; return 1; }
    for ordre in python3 curl gpg apt-get apt-cache apt-config dpkg dpkg-query systemctl modprobe hostname getent \
        flock mktemp cmp cp mv chmod chown install mkdir rm cat tee date sleep awk grep find sort stat diff timeout; do
        command -v "$ordre" > /dev/null || { printf '[ERROR] Dependència absent: %s\n' "$ordre" >&2; return 1; }
    done
    [[ -d /run/systemd/system ]] || { printf '%s\n' '[ERROR] Cal una VM amb systemd actiu.' >&2; return 1; }
    # Un únic procés evita còpies i edicions concurrents del mateix script.
    exec 9>/run/lock/hardening_cis.lock || return 1
    flock -n 9 || { printf '%s\n' '[ERROR] Ja hi ha una execució activa.' >&2; return 1; }
    TMP=$(mktemp -d /tmp/hardening-cis.XXXXXXXX) || return 1
    local identificador
    install -d -m 0700 /var/log/hardening_cis || { rm -rf "$TMP"; return 1; }
    # Només data i hora al nom; esperar el segon següent si ja existeix.
    while :; do
        identificador=$(date -u +%Y%m%dT%H%M%SZ) || return 1
        BACKUP_DIR="/var/backups/hardening_cis/$identificador"
        LOG="/var/log/hardening_cis/$identificador.log"
        [[ -e $LOG || -e $BACKUP_DIR ]] || break
        sleep 1
    done
    (set -C; : > "$LOG") || { rm -rf "$TMP"; printf '%s\n' '[ERROR] El nom del registre ja existeix.' >&2; return 1; }
    exec 3>&1
    if [[ -t 3 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then COLOR_ACTIU=1; fi
    exec > >(tee -a "$LOG") 2>&1
    trap finalitza EXIT
    trap 'error "Interrupció rebuda; restaurant transacció activa."; exit 130' INT TERM
    mkdir -m 0700 "$TMP/gpg" || return 1
    crea_transformador || return 1
    capcalera 'HARDENING CIS · DEBIAN 13' '1;36'
    missatge OK 'Debian 13, root i dependències verificats. No s’executa cap auditoria Lynis.'
    control 'PKGS-7388 / LYNIS-REPO' repositoris
    # No executar operacions APT si la validació de repositoris ha fallat.
    if [[ ${RESULTATS[-1]} == *' | ERROR' ]]; then
        repositoris_correctes=0
        error 'S’ometen els paquets perquè els repositoris no s’han pogut validar.'
        for ordre in LYNIS DEB-0280 DEB-0810 DEB-0831 PKGS-7370 PKGS-7394 PKGS-7392 PKGS-7420; do
            RESULTATS+=("$ordre | ERROR")
            DETALL_ERRORS+=("$ordre: no executat per l'error de repositoris; intervenció manual necessària.")
        done
    else
        control 'LYNIS — eina d’auditoria' paquet lynis si
        control 'DEB-0280' paquet libpam-tmpdir
        control 'DEB-0810' paquet apt-listbugs
        control 'DEB-0831' paquet needrestart
        control 'PKGS-7370' paquet debsums
        control 'PKGS-7394' paquet apt-show-versions
        control 'PKGS-7392' paquet ca-certificates si
        control 'PKGS-7420' actualitzacions_automatiques
    fi
    control 'BOOT-5180' exim
    control 'AUTH-9328' umask_pam
    control 'USB-1000' moduls usb-storage
    control 'NETW-3200' moduls dccp sctp rds tipc
    control 'STRG-1846' moduls firewire-sbp2
    control 'NAME-4028 / NAME-4404' fqdn
    control 'SSH-7408 — LogLevel, X11Forwarding i AllowTcpForwarding' ssh
    control 'ENTORN' entorn
    control 'ACTUALITZACIÓ DE PAQUETS' actualitzacio_final "$repositoris_correctes"
    ((ERRORS == 0))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
