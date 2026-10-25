# Bastionat automatitzat de Debian 13

`hardening_cis.sh` aplica a Debian 13 (Trixie) les mesures de bastionat seleccionades durant l'activitat de seguretat. Inspecciona l'estat del sistema, modifica només els controls que ho necessiten, fa còpies abans de canviar fitxers existents i verifica el resultat de cada operació. No busca reproduir una puntuació concreta de Lynis ni equival a una implantació completa del benchmark CIS.

El directori de l'entrega conté:

- `hardening_cis.sh`: script Bash de bastionat.
- `README.md`: instal·lació, ús, recuperació i limitacions.
- `RESUM_CONTROLS.md`: relació dels controls, les modificacions i les verificacions.

## Requisits

- Màquina Debian 13 amb `systemd`, accés d'administrador i connexió als repositoris de paquets.
- Bash, Python 3, APT/dpkg, curl, GnuPG, `flock`, `modprobe`, `hostname`, `getent` i utilitats estàndard del sistema. L'script comprova les ordres necessàries abans de començar.
- Certificats TLS operatius per obtenir la clau del repositori de CISOfy per HTTPS.
- La màquina no ha de prestar servei de correu amb Exim4: el control BOOT-5180 l'atura i el deshabilita si existeix.
- Una instantània recuperable de la màquina abans de la primera aplicació, especialment si s'administra remotament per SSH.

El programa no requereix instal·lar fitxers auxiliars: genera temporalment el codi Python que utilitza per preparar les modificacions de configuració. SSH i Docker són opcionals; si no existeixen, no s'instal·len per aquest motiu.

## Execució

Copieu els fitxers a la màquina Debian 13 i executeu, des del directori de l'entrega:

```bash
sudo bash hardening_cis.sh
```

`bash hardening_cis.sh --help` mostra l'ús. No hi ha mode de simulació: l'ordre anterior pot modificar paquets, fitxers i serveis. El bloqueig `/run/lock/hardening_cis.lock` impedeix dues execucions simultànies del mateix script. Eviteu modificacions concurrents d'APT, PAM, SSH o dels altres fitxers gestionats.

A l'inici es comproven el sistema operatiu, els privilegis i les dependències. Cada control té una capçalera amb el seu identificador i nom, i indica què ha detectat, què ha canviat i com ho ha verificat. El resum final utilitza `CORREGIT` per als controls modificats i verificats, `OMÈS` quan no cal actuar, `COMPROVACIÓ REQUERIDA` quan queda una comprovació manual, `AVÍS` per a una incidència detectada i `ERROR` si no s'ha pogut aplicar o verificar un control. El resum concreta cada comprovació, avís i error, i mostra el nombre de controls amb canvis, les còpies i les operacions sobre serveis. Una fallada obligatòria produeix un codi de sortida diferent de zero.

En un terminal compatible, els missatges informatius, els canvis, les còpies, les comprovacions manuals, els avisos i els errors es diferencien per colors. Amb la sortida redirigida, `TERM=dumb` o la variable `NO_COLOR` amb un valor no buit, es mostra text sense colors. El registre persistent sempre és text pla, sense codis ANSI.

## Controls inclosos

| Àmbit | Mesures |
|---|---|
| Repositoris i paquets | Repositori signat de CISOfy i paquet Lynis; `libpam-tmpdir`, `apt-listbugs`, `needrestart`, `debsums`, `apt-show-versions`, `unattended-upgrades`; versió candidata de `ca-certificates`; repositori `trixie-security`. |
| Serveis | Aturada i deshabilitació d'`exim4.service` si existeix. |
| Sessions | `UMASK 027` i `pam_umask.so nousergroups umask=027`. |
| Mòduls | Restricció de `usb-storage`, `dccp`, `sctp`, `rds`, `tipc` i `firewire-sbp2`. |
| Nom local | Resolució d'un FQDN coherent amb el nom real de la màquina, si cal. |
| SSH | `LogLevel VERBOSE`, `X11Forwarding no` i `AllowTcpForwarding no`, agrupats en una sola modificació i recàrrega quan sigui necessari. |
| Actualitzacions automàtiques | Índexs APT i `unattended-upgrades` activats cada dia; temporitzadors `apt-daily.timer` i `apt-daily-upgrade.timer` habilitats i actius. |
| Entorn | Comprovacions de SSH, resolució de noms i estat de Docker si està instal·lat. |
| Actualització final | `apt-get update` i `apt-get upgrade` sobre els repositoris configurats, com a últim control. |

La relació detallada de fitxers, condicions i ordres de verificació és a [RESUM_CONTROLS.md](RESUM_CONTROLS.md).

Primer es gestionen els paquets indicats i, al final, s'actualitzen els índexs i els paquets instal·lats amb `apt-get update` i `apt-get upgrade`. L'opció `--no-remove` evita que aquesta actualització elimini paquets; no s'executa `dist-upgrade`. Si la configuració dels repositoris ha fallat, l'actualització final es marca com a error i no es posa en marxa. El control final indica `CORREGIT` quan totes dues ordres acaben correctament, fins i tot si no hi havia paquets nous; el recompte de controls modificats només augmenta si APT informa de paquets actualitzats. El control PKGS-7420 instal·la `unattended-upgrades`, estableix una periodicitat diària amb APT i activa els temporitzadors `apt-daily.timer` i `apt-daily-upgrade.timer`; si els valors efectius ja són correctes, preserva la configuració existent. Lynis es gestiona com a paquet, però l'script no inicia cap auditoria de Lynis. No crea tasques de `debsums` ni activa `CRON_CHECK`.

## Còpies de seguretat i registres

Cada execució desa la sortida a `/var/log/hardening_cis/<data-i-hora-UTC>.log`, per exemple `20261025T125024Z.log`. Si ja existeix un registre amb aquell segon, espera al segon següent per evitar sobreescriure'l. Si APT falla, els detalls addicionals es desen en fitxers annexos del mateix registre; reviseu-ne el contingut abans de compartir-los, perquè poden incloure dades dels repositoris configurats.

Abans de modificar un fitxer existent, el programa en crea una còpia amb metadades a `/var/backups/hardening_cis/<data-i-hora-UTC>/`, reproduint la ruta original. `manifest.txt` relaciona cada fitxer amb la còpia corresponent; un fitxer creat de nou hi figura com a `NO_EXISTIA`. Si el contingut ja és correcte, no reescriu el fitxer ni en fa una còpia nova. Els canvis es preparen en un temporal del mateix directori i es substitueixen atòmicament.

Si falla la verificació d'un control, l'script intenta restaurar els fitxers modificats per aquell control i ho registra. En una recuperació manual, consulteu el manifest i restaureu cada fitxer existent amb la seva còpia preservant-ne les metadades. Per a una entrada `NO_EXISTIA`, elimineu únicament el fitxer que el programa havia creat. Després de restaurar SSH, valideu `sshd -t` abans de recarregar el servei; després de restaurar repositoris, valideu APT. Les còpies de fitxers no reverteixen instal·lacions de paquets ni canvis d'estat d'Exim4; per a una recuperació global utilitzeu la instantània de la màquina.

## Idempotència i comprovació

En un sistema sense canvis externs entre dues execucions, la segona execució ha de detectar els controls ja aplicats: no ha d'afegir directives repetides, reinstal·lar els paquets dels controls, reescriure fitxers conformes, fer còpies innecessàries ni recarregar serveis sense un canvi efectiu. Cada execució genera el seu registre. Els controls inicials poden reutilitzar índexs APT recents, però la secció final sempre torna a executar `apt-get update` i `apt-get upgrade`. Els índexs APT es refresquen i, si apareixen versions candidates noves entre execucions, també poden canviar els paquets instal·lats.

Per documentar la idempotència, executeu l'ordre dues vegades consecutives a la mateixa màquina. Conserveu la sortida i el codi de retorn de cada execució. Entre el final de la primera i el final de la segona, compareu els fitxers gestionats (hash, permisos, propietari i data de modificació), les versions dels paquets, l'estat d'Exim4, els valors efectius de SSH i les regles de `modprobe`. La segona execució ha d'indicar zero escriptures dels fitxers de configuració gestionats, zero còpies noves i zero operacions de servei si no hi ha hagut canvis externs; l'actualització general d'APT pot modificar índexs o paquets i s'ha de revisar per separat. Documenteu qualsevol diferència abans d'atribuir-la a l'script.

Obriu una nova connexió SSH des d'una altra màquina per confirmar l'accés i comprovar `umask` dins de la sessió (valor esperat: `0027`). També cal revisar `hostname -f`, la resolució local i externa, i l'estat de Docker i de les aplicacions que realment existeixin. La presència de directives en fitxers no demostra per si sola el comportament d'una sessió nova.

## Comportament conservador i limitacions

- **PAM:** preserva les opcions que no gestiona i rebutja configuracions amb múltiples entrades `pam_umask.so` o una pila que no reconeix. La verificació automàtica és estructural; cal comprovar una sessió nova.
- **SSH:** examina `sshd_config` i els fitxers inclosos, respecta els blocs `Match`, valida amb `sshd -t` i `sshd -T`, i només recarrega el servei si canvia la configuració efectiva. `AllowTcpForwarding no` impedeix el reenviament de ports SSH; reviseu les aplicacions que en depenguin. Un `Match` contradictori o un `Include` ambigu requereix revisió manual.
- **APT:** conserva els altres repositoris i `Signed-By`. Només substitueix una URI Azure `mirror+file` de `trixie-security` quan el bloc es pot identificar sense ambigüitat. Una font duplicada, mixta o desconeguda requereix revisió manual. La clau de CISOfy es limita al repositori corresponent amb `signed-by`.
- **Cloud-init:** si el FQDN ja es resol, no canvia `/etc/hosts`. Si cal corregir-lo i cloud-init està instal·lat, s'atura aquest control perquè la configuració local podria ser sobreescrita. Cal definir prèviament qui gestiona `/etc/hosts` a la imatge.
- **Mòduls:** comprova la regla amb `modprobe -c` i la simulació amb `modprobe -n -v --show-depends`. No descarrega mòduls ja carregats ni modifica altres controladors; la regla no impedeix totes les formes de càrrega directa.
- **Paquets:** els scripts de manteniment dels paquets Debian poden modificar fitxers o serveis com a part de la seva instal·lació. Aquestes operacions no formen part de la restauració de fitxers del programa.

L'script no configura tallafocs, DNS, GRUB, particions, Docker, aplicacions, claus o credencials SSH, ni instal·la controls descartats de l'activitat com Fail2ban, auditd, AIDE o sysstat. No reinicia la màquina.
