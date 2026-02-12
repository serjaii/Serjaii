#!/bin/bash

# Script de Instalación y Configuración de Servidor PXE (BIOS/UEFI) + Preseed
# Autor: Sergio Jiménez
# Descripción: Configura DHCP, TFTP y HTTP para instalar Debian 13 (Trixie) automáticamente.

set -e

# --- VARIABLES ---
INTERFACE="ens3" # Cambiar según la interfaz de red
SERVER_IP="192.168.122.18" # IP de este servidor (PXE Server)
SUBNET="192.168.122.0"
NETMASK="255.255.255.0"
RANGE_START="192.168.122.100"
RANGE_END="192.168.122.200"
GATEWAY="192.168.122.1"
DNS="8.8.8.8"

PRESEED_SRC="preseed.cfg"
WEB_ROOT="/var/www/html"
TFTP_ROOT="/srv/tftp"

# URL de Netboot para Debian Testing (Trixie)
NETBOOT_URL="https://d-i.debian.org/daily-images/amd64/daily/netboot/netboot.tar.gz"

echo "=== 1. Instalando Paquetes Necesarios ==="
sudo apt update
sudo apt install -y isc-dhcp-server tftpd-hpa apache2 wget

echo "=== 2. Configurando DHCP (isc-dhcp-server) ==="
# Configurar interfaz por defecto
sudo sed -i "s/INTERFACESv4=\"\"/INTERFACESv4=\"$INTERFACE\"/" /etc/default/isc-dhcp-server

# Crear backup de dhcpd.conf
if [ ! -f /etc/dhcp/dhcpd.conf.bak ]; then
    sudo cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.bak
fi

# Escribir nueva configuración DHCP
cat <<EOF | sudo tee /etc/dhcp/dhcpd.conf
option arch code 93 = unsigned integer 16;

default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet $SUBNET netmask $NETMASK {
    range $RANGE_START $RANGE_END;
    option routers $GATEWAY;
    option domain-name-servers $DNS;

    class "pxeclients" {
        match if substring (option vendor-class-identifier, 0, 9) = "PXEClient";
        next-server $SERVER_IP;

        if option arch = 00:07 {
            filename "debian-installer/amd64/bootnetx64.efi";
        } else if option arch = 00:09 {
            filename "debian-installer/amd64/bootnetx64.efi";
        } else {
            filename "pxelinux.0";
        }
    }
}
EOF

echo "=== 3. Configurando TFTP (tftpd-hpa) ==="
# Asegurar configuración
cat <<EOF | sudo tee /etc/default/tftpd-hpa
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_ROOT"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure"
EOF

echo "=== 4. Descargando Archivos de Netboot (Debian Trixie) ==="
# Limpiar directorio TFTP
if [ -d "$TFTP_ROOT" ]; then
    sudo rm -rf "$TFTP_ROOT"/*
fi

# Descargar y extraer
wget "$NETBOOT_URL" -O /tmp/netboot.tar.gz
sudo tar -xzf /tmp/netboot.tar.gz -C "$TFTP_ROOT"
rm /tmp/netboot.tar.gz

# Asegurar permisos
sudo chown -R tftp:tftp "$TFTP_ROOT"

echo "=== 5. Configurando Menús de Arranque ==="

# --- BIOS (pxelinux.cfg/default) ---
# El archivo ya viene con netboot, pero vamos a sobrescribirlo para añadir la opción automática
BIOS_CFG="$TFTP_ROOT/debian-installer/amd64/boot-screens/txt.cfg"
# Nota: pxelinux.0 busca en pxelinux.cfg/default, que en el netboot de debian suele incluir otros ficheros.
# Vamos a modificar pxelinux.cfg/default directamente o el que incluya.
# En el netboot de Debian, pxelinux.cfg/default hace un 'include debian-installer/amd64/boot-screens/menu.cfg'
# Vamos a crear una entrada por defecto que apunte al preseed.

cat <<EOF | sudo tee "$TFTP_ROOT/pxelinux.cfg/default"
DEFAULT install
LABEL install
    KERNEL debian-installer/amd64/linux
    APPEND vga=788 initrd=debian-installer/amd64/initrd.gz auto=true priority=critical url=http://$SERVER_IP/preseed.cfg --- quiet
EOF

# --- UEFI (grub.cfg) ---
# El netboot de Debian trae grub/grub.cfg. Lo editamos.
GRUB_CFG="$TFTP_ROOT/debian-installer/amd64/grub/grub.cfg"

cat <<EOF | sudo tee "$GRUB_CFG"
set default="0"
set timeout=0

menuentry "Install Debian 13 (Automated)" {
    linux /debian-installer/amd64/linux auto=true priority=critical url=http://$SERVER_IP/preseed.cfg --- quiet
    initrd /debian-installer/amd64/initrd.gz
}
EOF

echo "=== 6. Configurando Servidor Web (Preseed) ==="
if [ -f "$PRESEED_SRC" ]; then
    sudo cp "$PRESEED_SRC" "$WEB_ROOT/preseed.cfg"
    sudo chmod 644 "$WEB_ROOT/preseed.cfg"
else
    echo "ERROR: No se encuentra $PRESEED_SRC en el directorio actual."
    exit 1
fi

echo "=== 7. Reiniciando Servicios ==="
sudo systemctl restart isc-dhcp-server
sudo systemctl restart tftpd-hpa
sudo systemctl restart apache2

echo "=== INSTALACIÓN COMPLETADA ==="
echo "Servidor PXE listo en $SERVER_IP"
echo "Archivo Preseed accesible en http://$SERVER_IP/preseed.cfg"
echo "Asegúrate de que el firewall permita DHCP (67/udp), TFTP (69/udp) y HTTP (80/tcp)."
