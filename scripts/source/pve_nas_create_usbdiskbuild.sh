#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Filename:     pve_nas_create_usbdiskbuild.sh
# Description:  Source script for NAS internal SATA or Nvme disk ZFS raid storage
# ----------------------------------------------------------------------------------

#---- Source -----------------------------------------------------------------------
#---- Dependencies -----------------------------------------------------------------

# Install PVE USB auto mount
function install_usbautomount () {
  PVE_VERS=$(pveversion -v | grep 'proxmox-ve:*' | awk '{ print $2 }' | sed 's/\..*$//')
  if [ ${PVE_VERS} = 6 ]; then
    # Remove old version
    if [ $(dpkg -l pve[0-9]-usb-automount >/dev/null 2>&1; echo $?) = 0 ] && [ $(dpkg -l pve6-usb-automount >/dev/null 2>&1; echo $?) != 0 ]; then
      apt-get remove --purge pve[0-9]-usb-automount -y > /dev/null
    fi
    # Install new version
    if [ $(dpkg -l pve6-usb-automount >/dev/null 2>&1; echo $?) != 0 ]; then
      msg "Installing PVE USB automount..."
      apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 2FAB19E7CCB7F415 &> /dev/null
      echo "deb https://apt.iteas.at/iteas buster main" > /etc/apt/sources.list.d/iteas.list
      apt-get -qq update > /dev/null
      apt-get install pve6-usb-automount -y > /dev/null
      if [ $(dpkg -l pve6-usb-automount >/dev/null 2>&1; echo $?) = 0 ]; then
        info "PVE USB Automount status: ${GREEN}ok${NC} ( fully installed )"
        echo
      else
        warn "There are problems with the installation. Manual intervention is required.\nExiting installation in 3 second. Bye..."
        sleep 3
        echo
        trap cleanup EXIT
      fi
    fi
  elif [ ${PVE_VERS} = 7 ]; then
    # Remove old version
    if [ $(dpkg -l pve[0-9]-usb-automount >/dev/null 2>&1; echo $?) = 0 ] && [ $(dpkg -l pve7-usb-automount >/dev/null 2>&1; echo $?) != 0 ]; then
      apt-get remove --purge pve[0-9]-usb-automount -y > /dev/null
    fi
    # Install new version
    if [ $(dpkg -l pve7-usb-automount >/dev/null 2>&1; echo $?) != 0 ]; then
      msg "Installing PVE USB automount..."
      apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 2FAB19E7CCB7F415 &> /dev/null
      echo "deb https://apt.iteas.at/iteas bullseye main" > /etc/apt/sources.list.d/iteas.list
      apt-get -qq update > /dev/null
      apt-get install pve7-usb-automount -y > /dev/null
      if [ $(dpkg -l pve7-usb-automount >/dev/null 2>&1; echo $?) = 0 ]; then
        info "PVE USB Automount status: ${GREEN}ok${NC} ( fully installed )"
        echo
      else
        warn "There are problems with the installation. Manual intervention is required.\nExiting installation in 3 second. Bye..."
        sleep 3
        echo
        trap cleanup EXIT
      fi
    fi
  elif [ ${PVE_VERS} -lt 6 ]; then
    warn "There are problems with the installation:\n\n      1. This installation requires Proxmox version 6 or later. To continue you must first upgrade your Proxmox host.\n\n      Exiting installation in 3 second. Bye..."
    sleep 2
    echo
    trap cleanup EXIT
  fi
}

# Storage Array List
function reset_usb() {
  msg "Resetting USB devices..."
  # USB 3.1 Only
  for port in $(lspci | grep xHCI | cut -d' ' -f1); do
    echo -n "0000:${port}"| tee /sys/bus/pci/drivers/xhci_hcd/unbind > /dev/null
    sleep 5
    echo -n "0000:${port}" | tee /sys/bus/pci/drivers/xhci_hcd/bind > /dev/null
    sleep 5
  done
  # All USB
  for port in $(lspci | grep USB | cut -d' ' -f1); do
    echo -n "0000:${port}"| tee /sys/bus/pci/drivers/xhci_hcd/unbind > /dev/null
    sleep 5
    echo -n "0000:${port}" | tee /sys/bus/pci/drivers/xhci_hcd/bind > /dev/null
    sleep 5
  done
  echo
}

# Storage Array List
function storage_list() {
  # 1=PATH:2=KNAME:3=PKNAME (or part cnt.):4=FSTYPE:5=TRAN:6=MODEL:7=SERIAL:8=SIZE:9=TYPE:10=ROTA:11=UUID:12=RM:13=LABEL:14=ZPOOLNAME:15=SYSTEM
  # PVE All Disk array
  # Output printf '%s\n' "${allSTORAGE[@]}"
  unset allSTORAGE
  while read -r line; do
    #---- Set dev
    dev=$(echo $line | awk -F':' '{ print $1 }')

    #---- Set variables
    # Partition Cnt (Col 3)
    if ! [[ $(echo $line | awk -F':' '{ print $3 }') ]] && [[ "$(echo "$line" | awk -F':' '{ if ($1 ~ /^\/dev\/sd[a-z]$/ || $1 ~ /^\/dev\/nvme[0-9]n[0-9]$/) { print "0" } }')" ]]; then
      # var3=$(partx -g ${dev} | wc -l)
      if [[ $(lsblk ${dev} | grep -q part) ]]; then
        var3=$(lsblk ${dev} | grep part | wc -l)
      else
        var3='0'
      fi
    else
      var3=$(echo $line | awk -F':' '{ print $3 }')
    fi

    #---- ZFS_Members (Col 4)
    if ! [[ $(echo $line | awk -F':' '{ print $4 }') ]] && [ "$(lsblk -nbr -o FSTYPE ${dev})" = "zfs_member" ] || [ "$(blkid -o value -s TYPE ${dev})" = "zfs_member" ]; then
      var4='zfs_member'
    else
      var4=$(echo $line | awk -F':' '{ print $4 }')
    fi

    # Tran (Col 5)
    if ! [[ $(echo $line | awk -F':' '{ print $5 }') ]]; then
      var5=$(lsblk -nbr -o TRAN /dev/"$(lsblk -nbr -o PKNAME ${dev} | uniq | sed '/^$/d')" | uniq | sed '/^$/d')
    else
      var5=$(echo $line | awk -F':' '{ print $5 }')
    fi

    # Size (Col 8)
    var8=$(lsblk -nbrd -o SIZE ${dev} | awk '{ $1=sprintf("%.0f",$1/(1024^3))"G" } {print $0}')

    # Zpool Name or Cnt (Col 14)
    if [[ "$(echo ${dev} | awk '{ if ($1 ~ /^\/dev\/sd[a-z]$/ || $1 ~ /^\/dev\/nvme[0-9]n[0-9]$/) { print "0" } }')" ]]; then
      var14=$(lsblk -nbr -o PATH,KNAME,PKNAME,FSTYPE,TRAN,MODEL,SERIAL,SIZE,TYPE,ROTA,UUID,RM,LABEL | sed 's/ /:/g' | sed 's/$/:/' | sed 's/$/:0/' 2>/dev/null | grep -w "^$(echo ${dev} | awk '{ print $1".*[0-9]*$" }')\|^$(echo ${dev} | awk '{ print $1".*p[0-9]*$" }')" | awk -F':' '{ if ($4 == 'zfs_member') { print $0 }}' | wc -l)
    elif [ "$(lsblk -nbr -o FSTYPE ${dev})" = "zfs_member" ] || [ "$(blkid -o value -s TYPE ${dev})" = "zfs_member" ]; then
      var14=$(blkid -o value -s LABEL ${dev})
    else
      var14='0'
    fi

    # System (Col 15)
    if [[ $(df -hT | grep /$ | grep -w '^rpool/.*') ]]; then
      ONLINE=$(zpool status rpool | grep -Po "\S*(?=\s*ONLINE)")
      while read -r pool; do
        if ! [ -b "/dev/disk/by-id/$pool" ]; then
          continue
        fi
        ROOT_DEV=$(readlink -f /dev/disk/by-id/$pool)
      done <<< "$ONLINE"
    elif [[ $(df -hT | grep /$ | grep -w '^/dev/.*') ]]; then
      ROOT_DEV=$(df -hT | grep /$)
    fi
    if [[ $(fdisk -l ${dev} 2>/dev/null | grep -E '(BIOS boot|EFI System|Linux swap|Linux LVM)' | awk '{ print $1 }') ]] || [[ ${dev} == ${ROOT_DEV} ]]; then
      var15='1'
    else
      var15='0'
    fi

    #---- Finished Output
    allSTORAGE+=( "$(echo $line | awk -F':' -v var3=${var3} -v var4=${var4} -v var5=${var5} -v var8=${var8} -v var14=${var14} -v var15=${var15} 'BEGIN {OFS = FS}{ $3 = var3 } { $4 = var4 } {if ($5 == "") {$5 = var5;}} { $8 = var8 } { $14 = var14 } { $15 = var15 } { print $0 }')" )

  done < <( lsblk -nbr -o PATH,KNAME,PKNAME,FSTYPE,TRAN,MODEL,SERIAL,SIZE,TYPE,ROTA,UUID,RM,LABEL | sed 's/ /:/g' | sed 's/$/:/' | sed 's/$/:0/' | sed '/^$/d' 2>/dev/null )
}

#---- Static Variables -------------------------------------------------------------
#---- Other Variables --------------------------------------------------------------

# USB Disk Storage minimum size (GB)
STOR_MIN=10

#---- Other Files ------------------------------------------------------------------
#---- Body -------------------------------------------------------------------------

#---- Prerequisites
# Create storage list array
storage_list
echo hello2

# Create a output file
unset storLIST
for i in "${allSTORAGE[@]}"; do
  storLIST+=( $(echo $i) )
done

# Check for USB disks
if [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' '{ if ($5 == "usb" && $15 == 0) { print $0 } }' | wc -l) = 0 ] && [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' '{ if ($5 == "usb" && $15 == 0 && ($9 == "disk" || $9 == "part")) { print $0 } }' | wc -l) = 0 ]; then
  warn "No available USB disk was discovered. Try reconnecting your USB disk and run this installation script again.\nExisting in 3 seconds..."
  echo
  sleep 3
  exit 1
fi

#---- Creating the ZPOOL Tank
section "Setup a USB ZFS Storage Pool"
# 1=PATH:2=KNAME:3=PKNAME:4=FSTYPE:5=TRAN:6=MODEL:7=SERIAL:8=SIZE:9=TYPE:10=ROTA:11=UUID:12=RM:13=LABEL:14=ZPOOLNAME:15=SYSTEM

# Set ZFS Storage Pool name
while true; do
  if [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' '{ if ($5 == "usb" && $4 == "zfs_member" && $15 == 0) { print $0 } }' | wc -l) = 0 ] && [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' '{ if ($5 == "usb" && $15 == 0 && ($9 == "disk" || $9 == "part")) { print $0 } }' | wc -l) = 0 ]; then
    msg "No existing USB ZFS Storage Pools are available to the User. The User must create a new ZFS Storage Pool using any of the available disks or drive partitions shown below. If your USB disk wrongly identifies as a 'system drive' its because it contains Linux system partitions. To fix this issue, manually format the disk erasing all data before running this installation again. The standard default name for USB connected ZFS Storage Pools is 'usbtank'.\n"
    printf '%s\n' "${storLIST[@]}" | awk -F':' -v RED=${RED} -v GREEN=${GREEN} -v NC=${NC} -v STOR_MIN=$STOR_MIN 'BEGIN{OFS=FS} $8 ~ /G$/ {if ($5 == "usb" && $15 == 1) { print $1, $6, $8, $14, RED "not available" NC " - system drive" }} {if ($5 == "usb" && $4 == "zfs_member" && $15 == 0) { print $1, $6, $8, $14, GREEN "OK" NC " - existing ZFS pool" } } {size=0.0+$8; if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "part" && size >= STOR_MIN) { print $1, $6, $8, $14, "partition only (excluded)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 -gt 0) { print $1, $6, $8, $14, GREEN "OK" NC " - disk inc. x"$3" partitions, x"$14" ZFS Pools (warning)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 == 0) { print $1, $6, $8, $14, GREEN "OK" NC " - disk no partitions (good)" } }' | column -t -s : -N "DEVICE,MODEL,SIZE,ZFS POOL,STATUS" | indent2
    echo
    msg "In the next steps the User must enter a new ZFS Storage Pool name and select a valid disk or drive partition to create a new ZFS Storage Pool."
  elif [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' '{ if ($5 == "usb" && $15 == 0 && $4 == "zfs_member" && ($9 == "disk" || $9 == "part")) { print $0 } }' | wc -l) -ge 0 ]; then
    msg "The User has the option to mount an existing USB ZFS Storage Pool or create a new Pool on the available storage devices. Users options are shown below. If your USB device wrongly identifies as a 'system drive' its because it contains Linux system or OS partitions. To fix this issue, manually format the disk erasing all data before running this installation again.\n"
    printf '%s\n' "${storLIST[@]}" | awk -F':' -v RED=${RED} -v GREEN=${GREEN} -v NC=${NC} -v STOR_MIN=$STOR_MIN 'BEGIN{OFS=FS} $8 ~ /G$/ {if ($5 == "usb" && $15 == 1) { print $1, $6, $8, $14, RED "not available" NC " - system drive" }} {if ($5 == "usb" && $4 == "zfs_member" && $15 == 0) { print $1, $6, $8, $14, GREEN "OK" NC " - existing ZFS pool" } } {size=0.0+$8; if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "part" && size >= STOR_MIN) { print $1, $6, $8, $14, "partition only (excluded)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 -gt 0) { print $1, $6, $8, $14, GREEN "OK" NC " - disk inc. x"$3" partitions, x"$14" ZFS Pools (warning)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 == 0) { print $1, $6, $8, $14, GREEN "OK" NC " - disk no partitions (good)" } }' | column -t -s : -N "DEVICE,MODEL,SIZE,ZFS POOL,STATUS" | indent2
    echo
    msg "If the User chooses to mount a existing ZFS Storage Pool simply simply enter the existing 'pool name' in the next step. The User will be given the option to mount this ZFS Storage Pool, retaining all existing pool data, or destroy and recreate it. The later will result in 100% loss of all the old ZFS Storage Pool dataset data. If the User chooses to create a new ZFS Storage Pool then in the next steps enter a 'new pool name' and the User can select any valid disk or drive partition to create a new ZFS Storage Pool. In the next step enter a ZFS Storage Pool name."
    echo
  fi
  read -p "Enter a USB ZFS Storage Pool name (i.e default is usbtank): " -e -i usbtank POOL
  POOL=${POOL,,}
  echo
  if [[ $POOL = [Rr][Pp][Oo][Oo][Ll] ]]; then
    warn "ZFS Storage Pool name '$POOL' is your default root ZFS Storage Pool.\nYou cannot use this. Try again..."
    echo
  elif [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' -v pool=$POOL '{ if ($5 != "usb" && $4 == "zfs_member" && $14 == pool) { print $0 } }' | wc -l) != 0 ]; then
    warn "ZFS Storage Pool name '$POOL' is an existing onboard (SATA/eSATA/NVMe/SCSI) ZFS Storage Pool.\nYou cannot use this name. Try again..."
    echo
  elif [ $(zfs list | grep -w "^$POOL" >/dev/null; echo $?) = 1 ]; then
    ZPOOL_TYPE=0
    info "ZFS Storage Pool name is set: ${YELLOW}$POOL${NC}"
    echo
    break
  elif [ $(printf '%s\n' "${storLIST[@]}" | awk -F':' -v pool=$POOL '{ if ($5 == "usb" && $4 == "zfs_member" && $14 == pool && $15 == 0) { print $0 } }' | wc -l) -gt 0 ]; then
    warn "A USB ZFS Storage Pool named '$POOL' already exists:\n"
    printf '%s\n' "${storLIST[@]}" | awk -F':' -v RED=${RED} -v GREEN=${GREEN} -v NC=${NC} -v pool=$POOL 'BEGIN{OFS=FS} {if ($5 == "usb" && $4 == "zfs_member" && $14 == pool && $15 == 0) { print $1, $6, $8, $14, GREEN "OK" NC " - existing ZFS pool" } }' | column -t -s : -N "DEVICE,MODEL,SIZE,ZFS POOL,STATUS"
    echo
    TYPE01="${YELLOW}Destroy & Rebuild${NC} - destroy & recreate a ZFS Storage Pool '$POOL'."
    TYPE02="${YELLOW}Use Existing${NC} - use the existing ZFS Storage Pool '$POOL'."
    TYPE03="${YELLOW}Destroy & Exit${NC} - destroy ZFS Storage Pool '$POOL' and exit installation."
    TYPE04="${YELLOW}None. Try again${NC} - try another ZFS Storage Pool name."
    PS3="Select the action type you want to do (entering numeric) : "
    msg "Your available options are:"
    options=("$TYPE01" "$TYPE02" "$TYPE03" "$TYPE04")
    select menu in "${options[@]}"; do
      case $menu in
        "$TYPE01")
          echo
          warn "You have chosen to destroy ZFS Storage Pool '$POOL' on PVE $(echo $(hostname)). This action will result in ${UNDERLINE}permanent data loss${NC} ${WHITE}of all data stored in the existing ZFS Storage Pool '$POOL'. A clean new ZFS Storage Pool '$POOL' with then be re-created.${NC}\n"
          while true; do
            read -p "Are you sure you want to destroy ZFS Storage Pool '$POOL' and its datasets: [y/n]?" -n 1 -r YN
            echo
            case $YN in
              [Yy]*)
                ZPOOL_TYPE=1
                msg "Destroying ZFS Storage Pool '$POOL'..."
                # while read -r var; do
                #   zfs unmount $var &> /dev/null
                # done < <( zfs list -r $POOL | awk '{ print $1 }' | sed '1d' | sort -r -n )
                zpool destroy -f $POOL &> /dev/null
                zpool labelclear -f $(printf '%s\n' "${storLIST[@]}" | awk -F':' -v pool=$POOL '{if ($14 == pool) { print $1 } }') &> /dev/null
                info "ZFS Storage Pool '$POOL' status: ${YELLOW}destroyed${NC}"
                storage_list # Update storage list array
                echo
                break 2
                ;;
              [Nn]*)
                echo
                msg "You have chosen not to proceed with destroying ZFS Storage Pool '$POOL'.\nTry again..."
                sleep 2
                echo
                break
                ;;
              *)
                warn "Error! Entry must be 'y' or 'n'. Try again..."
                echo
                ;;
            esac
          done
          ;;
        "$TYPE02")
          echo
          ZPOOL_TYPE=2
          info "You have chosen to use the existing ZFS Storage Pool '$POOL'.\nNo new ZFS Storage Pool will be created.\nZFS Storage Pool name is set: ${YELLOW}$POOL${NC} (existing ZFS Storage Pool)"
          echo
          break 2
          ;;
        "$TYPE03")
          echo
          msg "You have chosen to destroy ZFS Storage Pool '$POOL'. This action will result in ${UNDERLINE}permanent data loss${NC} of all data stored in the existing ZFS Storage Pool '$POOL'. After ZFS Storage Pool '$POOL' is destroyed this installation script with exit."
          echo
          while true; do
            read -p "Are you sure to destroy ZFS Storage Pool '$POOL': [y/n]?" -n 1 -r YN
            echo
            case $YN in
              [Yy]*)
                msg "Destroying ZFS Storage Pool '$POOL'..."
                # while read -r var; do
                #   zfs unmount $var &> /dev/null
                # done < <( zfs list -r $POOL | awk '{ print $1 }' | sed '1d' | sort -r -n )
                zpool destroy -f $POOL &> /dev/null
                zpool labelclear -f $(printf '%s\n' "${storLIST[@]}" | awk -F':' -v pool=$POOL '{if ($14 == pool) { print $1 } }') &> /dev/null
                echo
                exit 0
                ;;
              [Nn]*)
                echo
                msg "You have chosen not to proceed with destroying ZFS Storage Pool '$POOL'.\nTry again..."
                sleep 1
                echo
                break 2
                ;;
              *)
                warn "Error! Entry must be 'y' or 'n'. Try again..."
                echo
                ;;
            esac
          done
          ;;
        "$TYPE04")
          echo
          msg "No problem. Try again..."
          echo
          break
          # done
          ;;
        *) warn "Invalid entry. Try again.." >&2
      esac
    done
  fi
  if ! [ -z "${ZPOOL_TYPE+x}" ]; then
    break
  fi
done


# #---- Select a USB disk or drive partition
if [ $ZPOOL_TYPE = 0 ] || [ $ZPOOL_TYPE = 1 ]; then
  # 1=PATH:2=KNAME:3=PKNAME:4=FSTYPE:5=TRAN:6=MODEL:7=SERIAL:8=SIZE:9=TYPE:10=ROTA:11=UUID:12=RM:13=LABEL:14=ZPOOLNAME:15=SYSTEM
  section "Select a USB disk or drive partition."

  # Select a USB disk or drive partition
  msg "The User must select a USB NAS storage disk for ZFS Storage Pool '$POOL'. Only storage disks are available - disk partitions are excluded. All existing data on the selected disk will be 100% destroyed.\n"
  printf '%s\n' "${storLIST[@]}" | awk -F':' -v RED=${RED} -v GREEN=${GREEN} -v NC=${NC} -v STOR_MIN=$STOR_MIN 'BEGIN{OFS=FS} $8 ~ /G$/ {size=0.0+$8; if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "part" && size >= STOR_MIN) { print $1, $6, $8, $14, "partition only (excluded)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 -gt 0) { print $1, $6, $8, $14, GREEN "OK" NC " - disk inc. x"$3" partitions, x"$14" ZFS Pools (warning)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 == 0) { print $1, $6, $8, $14, GREEN "OK" NC " - disk no partitions (good)" } }' | column -t -s : -N "DEVICE,MODEL,SIZE,ZFS POOL,STATUS" | indent2
  echo
  OPTIONS_VALUES_INPUT=$(printf '%s\n' "${storLIST[@]}" | awk -F':' -v STOR_MIN=$STOR_MIN 'BEGIN{OFS=FS} $8 ~ /G$/ {size=0.0+$8; if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 > 0) { print $1, $5, $6, $7, $9 } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 == 0) { print $1, $5, $6, $7, $9 } }')
  OPTIONS_LABELS_INPUT=$(printf '%s\n' "${storLIST[@]}" | awk -F':' -v STOR_MIN=$STOR_MIN 'BEGIN{OFS=FS} $8 ~ /G$/ {size=0.0+$8; if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 > 0) { print $1, $6, $8, "OK - disk contains x"$3" existing partitions (warning)" } } {if ($5 == "usb" && $4 != "zfs_member" && $15 == 0 && $9 == "disk" && $3 == 0) { print $1, $6, $8, "OK - disk with no partitions (good)" } }' | column -t -s :)
  makeselect_input1 "$OPTIONS_VALUES_INPUT" "$OPTIONS_LABELS_INPUT"
  singleselect SELECTED "$OPTIONS_STRING"
  ZFSPOOL_TANK_CREATE=0
fi


# Erase / Wipe ZFS pool disks
if [ ${ZPOOL_TYPE} = 0 ] || [ ${ZPOOL_TYPE} = 1 ] && [ ${ZFSPOOL_TANK_CREATE} = 0 ]; then
  msg "Zapping, Erasing and Wiping selected storage device..."
  while read SELECTED_DEVICE; do
    sgdisk --zap $SELECTED_DEVICE >/dev/null 2>&1
    dd if=/dev/zero of=$SELECTED_DEVICE count=1 bs=512 conv=notrunc 2>/dev/null
    wipefs -afq $SELECTED_DEVICE >/dev/null 2>&1
    info "Storage device wiped: ${YELLOW}$SELECTED_DEVICE${NC}"
  done  < <( printf '%s\n' "${RESULTS[@]}" | awk -F':' '{ print $1 }' )
  echo
fi

# Create ZFS Pool
if [ ${ZPOOL_TYPE} = 0 ] || [ ${ZPOOL_TYPE} = 1 ] && [ ${ZFSPOOL_TANK_CREATE} = 0 ]; then
  msg "Creating ZFS pool '$POOL'..."
  zpool create -f -o ashift=12 $POOL $(printf '%s\n' "${RESULTS[@]}" | awk -F':' '{ print $1 }')
  sleep 1
  zpool export $POOL
  zpool import -d /dev/disk/by-id $POOL
  storage_list # Update storage list array
  info "ZFS Storage Pool status: ${YELLOW}$(zpool status -x $POOL)${NC}"
  echo
fi

# Reconnect to ZFS Pool
if [ ${ZPOOL_TYPE} = 2 ]; then
  msg "Reconnecting to existing ZFS '$POOL'..."
  zpool export $POOL
  zpool import -d /dev/disk/by-id $POOL
  storage_list # Update storage list array
  info "ZFS Storage Pool status: ${YELLOW}$(zpool status -x $POOL)${NC}"
  echo
fi

#---- Create PVE ZFS File System
section "Create ZFS file system."

# Wake USB disk
while IFS= read -r line; do
  dd if=${line} of=/dev/null count=512 status=none
done < <( printf '%s\n' "${storLIST[@]}" | awk -F':' '{if ($5 == "usb") { print $1 } }' )

# Create PVE ZFS 
if [ $(zfs list -r -H -o name $POOL/$CT_HOSTNAME &>/dev/null; echo $?) != 0 ]; then
  msg "Creating ZFS file system $POOL/$CT_HOSTNAME..."
  zfs create -o compression=lz4 $POOL/$CT_HOSTNAME >/dev/null
  zfs set acltype=posixacl aclinherit=passthrough xattr=sa $POOL/$CT_HOSTNAME >/dev/null
  zfs set xattr=sa dnodesize=auto $POOL >/dev/null
  info "ZFS file system settings:\n    --  Compresssion: ${YELLOW}lz4${NC}\n    --  Posix ACL type: ${YELLOW}posixacl${NC}\n    --  ACL inheritance: ${YELLOW}passthrough${NC}\n    --  LXC/VM with ACL on ZFS: ${YELLOW}auto${NC}"
  echo
elif [ $(zfs list -r -H -o name $POOL/$CT_HOSTNAME &>/dev/null; echo $?) == 0 ]; then  
  msg "Modifying existing ZFS file system settings /$POOL/$CT_HOSTNAME..."
  zfs set compression=lz4 $POOL/$CT_HOSTNAME
  zfs set acltype=posixacl aclinherit=passthrough xattr=sa $POOL/$CT_HOSTNAME >/dev/null
  zfs set xattr=sa dnodesize=auto $POOL >/dev/null
  info "Changes to existing ZFS file system settings ( $POOL/$CT_HOSTNAME ):\n  --  Compresssion: ${YELLOW}lz4${NC}\n  --  Posix ACL type: ${YELLOW}posixacl${NC}\n  --  ACL inheritance: ${YELLOW}passthrough${NC}\n  --  LXC/VM with ACL on ZFS: ${YELLOW}auto${NC}\nCompression will only be performed on new stored data."
  echo
fi