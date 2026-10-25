# Relació de controls gestionats

Aquest document identifica què avalua i modifica `hardening_cis.sh`. Els valors inicials i finals s'obtenen del registre de cada execució; poden variar segons l'estat de la màquina. `CORREGIT` identifica un canvi verificat i `OMÈS` indica que no ha calgut actuar. `COMPROVACIÓ REQUERIDA` identifica una verificació manual concreta; els avisos i els errors apareixen amb la causa al resum final.

| Control | Condició i acció | Fitxers o estat gestionat | Verificació |
|---|---|---|---|
| Lynis — repositori i paquet | Configurar el repositori oficial signat si falta; instal·lar o actualitzar Lynis fins al candidat disponible. | `/etc/apt/keyrings/cisofy.gpg`, `/etc/apt/sources.list.d/cisofy-lynis.list`, paquet `lynis`. | Clau llegible, actualització d'índex APT quan cal i estat/versió amb dpkg. |
| DEB-0280 | Instal·lar `libpam-tmpdir` si falta. | Paquet `libpam-tmpdir`. | Estat amb `dpkg-query`. |
| DEB-0810 | Instal·lar `apt-listbugs` si falta. | Paquet `apt-listbugs`. | Estat amb `dpkg-query`. |
| DEB-0831 | Instal·lar `needrestart` si falta. | Paquet `needrestart`. | Estat amb `dpkg-query`; mode de llista durant APT. |
| BOOT-5180 | Aturar i deshabilitar Exim4 si està actiu o habilitat. | `exim4.service`; sense desinstal·lar el paquet. | Estat actiu i habilitació abans i després amb `systemctl`. |
| AUTH-9328 | Establir UMASK 027 i aplicar `pam_umask.so nousergroups umask=027` a les sessions. | `/etc/login.defs`, `/etc/pam.d/common-session`, `/etc/pam.d/common-session-noninteractive`. | Coherència de les directives; confirmació d'`umask` en una sessió SSH nova. |
| USB-1000 | Restringir `usb-storage` amb `install usb-storage /bin/false`. | `/etc/modprobe.d/disable-usb-storage.conf`. | Regla efectiva, simulació de modprobe i detecció de càrrega actual. |
| NETW-3200 | Restringir `dccp`, `sctp`, `rds` i `tipc`. | `/etc/modprobe.d/disable-{dccp,sctp,rds,tipc}.conf`. | Regla i simulació per a cada mòdul; detecció de càrrega actual. |
| STRG-1846 | Restringir `firewire-sbp2`. | `/etc/modprobe.d/disable-firewire-storage.conf`. | Regla, simulació i detecció de mòduls FireWire carregats. |
| NAME-4028 / NAME-4404 | Conservar un FQDN ja resoluble o configurar un nom local basat en el hostname real quan és segur fer-ho. | `/etc/hosts`. | `hostname -f` i `getent hosts`; inspecció de cloud-init. |
| PKGS-7370 | Instal·lar `debsums` si falta. | Paquet `debsums`; sense activar `CRON_CHECK`. | Estat amb `dpkg-query`. |
| PKGS-7394 | Instal·lar `apt-show-versions` si falta. | Paquet `apt-show-versions`. | Estat amb `dpkg-query`. |
| PKGS-7392 | Actualitzar només `ca-certificates` si el candidat és superior. | Paquet `ca-certificates`. | Comparació de versions amb dpkg i estat final del paquet. |
| PKGS-7420 | Instal·lar `unattended-upgrades` i activar l'actualització periòdica diària. | Paquet `unattended-upgrades`; `/etc/apt/apt.conf.d/52hardening-cis-auto-upgrades` si cal; `apt-daily.timer` i `apt-daily-upgrade.timer`. | Estat amb `dpkg-query`, valors efectius amb `apt-config shell` i temporitzadors habilitats i actius amb `systemctl`. |
| PKGS-7388 | Substituir la URI Azure `mirror+file` d'una entrada exclusiva `trixie-security` identificada sense ambigüitat. | Fitxer Deb822 `.sources` o fitxer tradicional `.list` que contingui l'entrada. | Preservació de les altres fonts i de `Signed-By`; `apt-get update` després del canvi, amb restauració si falla. |
| SSH-7408 — LogLevel | Establir `VERBOSE` si el valor efectiu és diferent. | `/etc/ssh/sshd_config` i fitxers inclosos amb directives globals gestionades. | `sshd -t`, `sshd -T` i comparació dels altres valors globals. |
| SSH-7408 — X11Forwarding | Establir `no` si el valor efectiu és diferent. | Mateixa transacció SSH; blocs `Match` preservats. | `sshd -t`, `sshd -T`; una sola recàrrega quan cal. |
| SSH-7408 — AllowTcpForwarding | Establir `no` si el valor efectiu és diferent. | Mateixa transacció SSH; blocs `Match` preservats. | `sshd -t`, `sshd -T`; una sola recàrrega quan cal. |
| Entorn | Comprovar serveis i resolució sense instal·lar aplicacions addicionals. | SSH, nom local, DNS extern i Docker si existeix. | Estat de servei, `getent` i consulta de contenidors; accés SSH extern manual. |
| Actualització de paquets | Com a últim control, executar `apt-get update` i `apt-get upgrade --no-remove` si els repositoris s'han validat. | Índexs APT i paquets instal·lats amb versions candidates noves. | Codis de sortida de totes dues ordres; recompte de paquets actualitzats quan APT el proporciona. L'estat és `CORREGIT` si totes dues ordres acaben correctament, encara que el recompte sigui zero. |

El repositori Debian Security i el de CISOfy es validen dins d'un mateix control d'APT per compartir l'actualització dels índexs. Les tres directives SSH comparteixen una transacció i, si cal, una sola recàrrega. Per això el nombre de files de la taula pot ser superior al nombre de controls indicat pel resum de l'script.

Les configuracions ambigües es marquen com a error o avís per a revisió manual. El registre d'execució detalla l'estat inicial detectat, el canvi concret, la ruta de cada còpia, el resultat de la verificació i qualsevol restauració.
