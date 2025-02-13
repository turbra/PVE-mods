#!/usr/bin/env bash
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display temperature information.
#

################### Configuration #############

# Display configuration for HDD, NVME, CPU
CPU_ITEMS_PER_ROW=4;
NVME_ITEMS_PER_ROW=4;
HDD_ITEMS_PER_ROW=4;

# Known CPU sensor names. They can be full or partial but should ensure unambiguous identification.
# Should new ones be added, also update logic in configure() function.
KNOWN_CPU_SENSORS=("coretemp-isa-" "k10temp-pci-")

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

# Files backup location
BACKUP_DIR="$SCRIPT_CWD/backup"

# File paths
pvemanagerlibjs="/usr/share/pve-manager/js/pvemanagerlib.js"
nodespm="/usr/share/perl5/PVE/API2/Nodes.pm"

###############################################

# Helper functions
function msg {
    echo -e "\e[0m$1\e[0m"
}

#echo message in bold
function msgb {
	echo -e "\e[1m$1\e[0m"
}

function warn {
    echo -e "\e[0;33m[warning] $1\e[0m"
}

function err {
    echo -e "\e[0;31m[error] $1\e[0m"
    exit 1
}
# End of helper functions

# Function to display usage information
function usage {
	msgb "\nUsage:\n$0 [install | uninstall]\n"
	exit 1
}

# Define a function to install packages
function install_packages {
	# Check if the 'sensors' command is available on the system
	if (! command -v sensors &> /dev/null); then
		# If the 'sensors' command is not available, prompt the user to install lm-sensors
		read -p "lm-sensors is not installed. Would you like to install it? (y/n) " choice
		case "$choice" in
			y|Y )
				# If the user chooses to install lm-sensors, update the package list and install the package
				apt-get update
				apt-get install lm-sensors
				;;
			n|N )
				# If the user chooses not to install lm-sensors, exit the script with a zero status code
				msg "Decided to not install lm-sensors. The mod cannot run without it. Exiting..."
				exit 0
				;;
				* )
				# If the user enters an invalid input, print an error message and exit the script with a non-zero status code
				err "Invalid input. Exiting..."
				;;
		esac
	fi
}

function configure {
	local sensorOutput=$(sensors -j)

	# Check if HDD/SSD data is installed
	msg "\nDetecting support for HDD/SDD temperature sensors..."
	if (lsmod | grep -wq "drivetemp"); then
		# Check if SDD/HDD data is available
		if (echo "$sensorOutput" | grep -q "drivetemp-scsi-" ); then
			msg "Detected sensors:\n$(echo "$sensorOutput" | grep -o '"drivetemp-scsi[^"]*"' | sed 's/"//g')"
			enableHddTemp=true
		else
			warn "Kernel module \"drivetemp\" is not installed. HDD/SDD temperatures will not be available."
			enableHddTemp=false
		fi
	else
		enableHddTemp=false
	fi

	# Check if NVMe data is available
	msg "\nDetecting support for NVMe temperature sensors..."
	if (echo "$sensorOutput" | grep -q "nvme-" ); then
		msg "Detected sensors:\n$(echo "$sensorOutput" | grep -o '"nvme[^"]*"' | sed 's/"//g')"
		enableNvmeTemp=true
	else
		warn "No NVMe temperature sensors found."
		enableNvmeTemp=false
	fi

	# Check if CPU is part of known list for autoconfiguration
	msg "\nDetecting support for CPU temperature sensors..."
	for item in "${KNOWN_CPU_SENSORS[@]}"; do
		if (echo "$sensorOutput" | grep -q "$item"); then
			case "$item" in
				"coretemp-"*)
					CPU_ADDRESS="$(echo "$sensorOutput" | grep "$item" | sed 's/"//g;s/:{//;s/^\s*//')"
					CPU_ITEM_PREFIX="Core "
					CPU_TEMP_CAPTION="Core"
					break
					;;
				"k10temp-"*)
					CPU_ADDRESS="$(echo "$sensorOutput" | grep "$item" | sed 's/"//g;s/:{//;s/^\s*//')"
					CPU_ITEM_PREFIX="Tctl"
					CPU_TEMP_CAPTION="Temp"
					break
					;;
				*)
					continue
					;;
			esac
		fi
	done

	if [ -n "$CPU_ADDRESS" ]; then
		msg "Detected sensor:\n$CPU_ADDRESS"
	fi

	# If cpu is not known, ask the user for input
	if [ -z "$CPU_ADDRESS" ]; then
		warn "Could not automatically detect the CPU temperature sensor. Please configure it manually."
		# Ask user for CPU information
		# Inform the user and prompt them to press any key to continue
		read -rsp $'Sensor output will be presented. Press any key to continue...\n' -n1 key

		# Print the output to the user
		msg "Sensor output:\n${sensorOutput}"

		# Prompt the user for adapter name and item name
		read -p "Enter the CPU sensor address (e.g.: coretemp-isa-0000 or k10temp-pci-00c3): " CPU_ADDRESS
		read -p "Enter the CPU sensor input prefix (e.g.: Core or Tc): " CPU_ITEM_PREFIX
		read -p "Enter the CPU temperature caption (e.g.: Core or Temp): " CPU_TEMP_CAPTION
	fi

	if [[ -z "$CPU_ADDRESS" || -z "$CPU_ITEM_PREFIX" ]]; then
		warn "The CPU configuration is not complete. Temperatures will not be available."
	fi

	echo # add a new line
}

# Function to install the modification
function install_mod {
	msg "\nPreparing mod installation..."

	# Provide sensor configuration
	configure

	# Create backup of original files
	mkdir -p "$BACKUP_DIR"

	local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

	# Add new line to Nodes.pm file
	if [[ -z $(cat $nodespm | grep -e "$res->{thermalstate}") ]]; then
		# Create backup of original file
		cp "$nodespm" "$BACKUP_DIR/Nodes.pm.$timestamp"
		msg "Backup of \"$nodespm\" saved to \"$BACKUP_DIR/Nodes.pm.$timestamp\"."

		sed -i '/my $dinfo = df('\''\/'\'', 1);/i\'$'\t''$res->{thermalstate} = `sensors -j`;\n' "$nodespm"
		msg "Added thermalstate to $nodespm."
	else
		warn "Thermalstate already added to \"$nodespm\"."
	fi

	# Add new item to the items array in PVE.node.StatusView
	if [[ -z $(cat "$pvemanagerlibjs" | grep -e "itemId: 'thermal[[:alnum:]]*'") ]]; then
		# Create backup of original file
		cp "$pvemanagerlibjs" "$BACKUP_DIR/pvemanagerlib.js.$timestamp"
		msg "Backup of \"$pvemanagerlibjs\" saved to \"$BACKUP_DIR/pvemanagerlib.js.$timestamp\"."

		# Expand space in StatusView
		sed -i "/Ext.define('PVE\.node\.StatusView'/,/\},/ {
			s/\(bodyPadding:\) '[^']*'/\1 '20 15 20 15'/
			s/height: [0-9]\+/minHeight: 360,\n\tflex: 1/
			s/\(tableAttrs:.*$\)/trAttrs: \{ valign: 'top' \},\n\t\1/
		}" "$pvemanagerlibjs"
		msg "Expanded space in \"$pvemanagerlibjs\"."

		sed -i "/^Ext.define('PVE.node.StatusView',/ {
			:a;
			/items:/!{N;ba;}
			:b;
			/swap.*},/!{N;bb;}
			a\
			\\
	{\n\
		itemId: 'thermalCpu',\n\
		colspan: 1,\n\
		printBar: false,\n\
		title: gettext('CPU Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'thermalstate',\n\
		renderer: function(value){\n\
			// sensors configuration\n\
			const cpuAddress = \"$CPU_ADDRESS\";\n\
			const cpuItemPrefix = \"$CPU_ITEM_PREFIX\";\n\
			const cpuTempCaption = \"$CPU_TEMP_CAPTION\";\n\
			// display configuration\n\
			const itemsPerRow = $CPU_ITEMS_PER_ROW;\n\
			// ---\n\
			const objValue = JSON.parse(value);\n\
			if(objValue.hasOwnProperty(cpuAddress)) {\n\
				const items = objValue[cpuAddress],\n\
					itemKeys = Object.keys(items).filter(item => { return String(item).startsWith(cpuItemPrefix); });\n\
				let temps = [];\n\
				itemKeys.forEach((coreKey) => {\n\
					try {\n\
						Object.keys(items[coreKey]).forEach((secondLevelKey) => {\n\
							if (secondLevelKey.includes('_input')) {\n\
								let tempStr = '';\n\
								let temp = items[coreKey][secondLevelKey];\n\
								let index = coreKey.match(/\\\S+\\\s*(\\\d+)/);\n\
								if(index !== null && index.length > 1) {\n\
									index = index[1];\n\
									tempStr = \`\${cpuTempCaption}&nbsp;\${index}:&nbsp;\${temp}&deg;C\`;\n\
								}\n\
								else {\n\
									tempStr = \`\${cpuTempCaption}:&nbsp;\${temp}&deg;C\`;\n\
								}\n\
								temps.push(tempStr);\n\
							}\n\
						})\n\
					} catch(e) { /*_*/ }\n\
				});\n\
				const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : ' | ') : '')});\n\
				return result.length > 0 ? result.join('') : 'N/A';\n\
			}\n\
		}\n\
	},
		}" "$pvemanagerlibjs"

		#
		# NOTE: The following items will be added in reverse order
		#
		if [ $enableHddTemp = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		itemId: 'thermalHdd',\n\
		colspan: 1,\n\
		printBar: false,\n\
		title: gettext('HDD/SSD Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'thermalstate',\n\
		renderer: function(value) {\n\
			// sensors configuration\n\
			const addressPrefix = \"drivetemp-scsi-\";\n\
			const sensorName = \"temp1\";\n\
			// display configuration\n\
			const itemsPerRow = ${HDD_ITEMS_PER_ROW};\n\
			const objValue = JSON.parse(value);\n\
			// ---\n\
			const drvKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
			let temps = [];\n\
			drvKeys.forEach((drvKey, index) => {\n\
				try {\n\
					Object.keys(objValue[drvKey][sensorName]).forEach((secondLevelKey) => {\n\
						if (secondLevelKey.includes('_input')) {\n\
							let temp = objValue[drvKey][sensorName][secondLevelKey];\n\
							temps.push(\`Drive&nbsp;\${index + 1}:&nbsp;\${temp}&deg;C\`);\n\
						}\n\
					})\n\
				} catch(e) { /*_*/ }\n\
			});\n\
			const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : ' | ') : ''); });\n\
			return result.length > 0 ? result.join('') : 'N/A';\n\
		}\n\
	},
		}" "$pvemanagerlibjs"
		fi

		if [ $enableNvmeTemp = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		itemId: 'thermalNvme',\n\
		colspan: 1,\n\
		printBar: false,\n\
		title: gettext('NVMe Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'thermalstate',\n\
		renderer: function(value) {\n\
			// sensors configuration\n\
			const addressPrefix = \"nvme-pci-\";\n\
			const sensorName = \"Composite\";\n\
			// display configuration\n\
			const itemsPerRow = ${NVME_ITEMS_PER_ROW};\n\
			// ---\n\
			const objValue = JSON.parse(value);\n\
			const nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
			let temps = [];\n\
			nvmeKeys.forEach((nvmeKey, index) => {\n\
				try {\n\
					Object.keys(objValue[nvmeKey][sensorName]).forEach((secondLevelKey) => {\n\
						if (secondLevelKey.includes('_input')) {\n\
							let temp = objValue[nvmeKey][sensorName][secondLevelKey];\n\
							temps.push(\`Drive&nbsp;\${index + 1}:&nbsp;\${temp}&deg;C\`);\n\
						}\n\
					})\n\
				} catch(e) { /*_*/ }\n\
			});\n\
			const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : ' | ') : ''); });\n\
			return result.length > 0 ? result.join('') : 'N/A';\n\
		}\n\
	},
			}" "$pvemanagerlibjs"
		fi

		if [ $enableNvmeTemp = true -a $enableHddTemp = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
			:a;
			/^.*{.*'thermalNvme'.*},/!{N;ba;}
			a\
			\\
	{\n\
		xtype: 'box',\n\
		colspan: 1,\n\
		padding: '0 0 20 0',\n\
	},
		}" "$pvemanagerlibjs"
		fi

		msg "New temperature display items added to the summary panel in \"$pvemanagerlibjs\"."

		restart_proxy

		msg "Installation completed"
	else
		warn "New temperature display items already added to the summary panel in \"$pvemanagerlibjs\"."
	fi
}

# Function to uninstall the modification
function uninstall_mod {
	msg "\nRestoring modified files..."
	# Find the latest Nodes.pm file using the find command
	local latest_nodes_pm=$(find "$BACKUP_DIR" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_nodes_pm" ]; then
		# Remove the latest Nodes.pm file
		cp "$latest_nodes_pm" "$nodespm"
		msg "Copied latest backup to $nodespm."
	else
		warn "No Nodes.pm files found."
	fi

	# Find the latest pvemanagerlib.js file using the find command
	local latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_pvemanagerlibjs" ]; then
		# Remove the latest pvemanagerlib.js file
		cp "$latest_pvemanagerlibjs" "$pvemanagerlibjs"
		msg "Copied latest backup to \"$pvemanagerlibjs\"."
	else
		warn "No pvemanagerlib.js files found."
	fi

    if [ -n "$latest_nodes_pm" ] || [ -n "$latest_pvemanagerlibjs" ]; then
        # At least one of the variables is not empty, restart the proxy
        restart_proxy
    fi
}

function restart_proxy {
	# Restart pveproxy
	msg "\nRestarting PVE proxy..."
	systemctl restart pveproxy
}

# Process the arguments using a while loop and a case statement
executed=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		install)
			executed=$(($executed + 1))
			msgb "\nInstalling the Proxmox VE temperatures display mod..."
			install_packages
			install_mod
			echo # add a new line
			;;
		uninstall)
			executed=$(($executed + 1))
			msgb "\nUninstalling the Proxmox VE temperatures display mod..."
			uninstall_mod
			echo # add a new line
			;;
	esac
	shift
done

# If no arguments were provided or all arguments have been processed, print the usage message
if [[ $executed -eq 0 ]]; then
	usage
fi
