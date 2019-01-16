#!/bin/bash

# exit script if return code != 0
set -e

# build scripts
####

# download build scripts from github
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/scripts-master.zip -L https://github.com/binhex/scripts/archive/master.zip

# unzip build scripts
unzip /tmp/scripts-master.zip -d /tmp

# move shell scripts to /root
mv /tmp/scripts-master/shell/arch/docker/*.sh /root/

# pacman packages
####

# define pacman packages
pacman_packages="git tk mono dotnet-sdk"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# define aur packages
aur_packages="msbuild-15-bin rider"

# build package only, as apacman seems to be having issues finding the rider built
# package, probably related to the fact that the package version has a colon, so
# this could be a bug in apacman escaping.
# due to the above issue we build and then use pacman to install manually (done in aur.sh).
aur_build_only="true"

# call aur install script (arch user repo)
source /root/aur.sh

# config rider
####

# set rider paths for config, plugins, system and log, note the location of the idea.properties
# file is constructed from the idea.paths.selector value, as shown above.
mkdir -p /home/nobody/.config/rider/config
echo "idea.config.path=/config/rider/config" > /home/nobody/.config/rider/config/idea.properties
echo "idea.plugins.path=/config/rider/config/plugins" >> /home/nobody/.config/rider/config/idea.properties
echo "idea.system.path=/config/rider/system" >> /home/nobody/.config/rider/config/idea.properties
echo "idea.log.path=/config/rider/system/log" >> /home/nobody/.config/rider/config/idea.properties

cat <<'EOF' > /tmp/startcmd_heredoc
# check if recent projects directory config file exists, if it doesnt we assume
# rider hasn't been run yet and thus set default location for future projects to
# external volume mapping.
if [ ! -f /config/rider/config/options/recentProjects.xml ]; then
	mkdir -p /config/rider/config/options
	cp /home/nobody/recentProjects.xml /config/rider/config/options/recentProjects.xml
fi

# run rider
/usr/bin/rider
EOF

# replace startcmd placeholder string with contents of file (here doc)
sed -i '/# STARTCMD_PLACEHOLDER/{
    s/# STARTCMD_PLACEHOLDER//g
    r /tmp/startcmd_heredoc
}' /home/nobody/start.sh
rm /tmp/startcmd_heredoc

# config novnc
###

# overwrite novnc 16x16 icon with application specific 16x16 icon (used by bookmarks and favorites)
cp /home/nobody/novnc-16x16.png /usr/share/novnc/app/images/icons/

# config openbox
####

cat <<'EOF' > /tmp/menu_heredoc
    <item label="Rider">
    <action name="Execute">
      <command>/usr/bin/rider</command>
      <startupnotify>
        <enabled>yes</enabled>
      </startupnotify>
    </action>
    </item>
EOF

# replace menu placeholder string with contents of file (here doc)
sed -i '/<!-- APPLICATIONS_PLACEHOLDER -->/{
    s/<!-- APPLICATIONS_PLACEHOLDER -->//g
    r /tmp/menu_heredoc
}' /home/nobody/.config/openbox/menu.xml
rm /tmp/menu_heredoc

# env vars
####

# set RIDER_PROPERTIES env var, this determines the path to the custom idea.properties file
# which contains the paths for config, plugins, system and log paths (see config rider section),
# which are then defined to point at /config/... for persistence.

cat <<'EOF' > /tmp/envvars_heredoc
export RIDER_PROPERTIES=$(echo "${RIDER_PROPERTIES}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${RIDER_PROPERTIES}" ]]; then
	echo "[info] RIDER_PROPERTIES defined as '${RIDER_PROPERTIES}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	export RIDER_PROPERTIES="/home/nobody/.config/rider/config/idea.properties"
	echo "[info] RIDER_PROPERTIES not defined, defaulting to '${RIDER_PROPERTIES}'" | ts '%Y-%m-%d %H:%M:%.S'
fi

export RIDER_VM_OPTIONS=$(echo "${RIDER_VM_OPTIONS}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${RIDER_VM_OPTIONS}" ]]; then
	echo "[info] RIDER_VM_OPTIONS defined as '${RIDER_VM_OPTIONS}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] RIDER_VM_OPTIONS not defined, skipping additional options'" | ts '%Y-%m-%d %H:%M:%.S'
fi
EOF

# replace env vars placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
	s/# ENVVARS_PLACEHOLDER//g
	r /tmp/envvars_heredoc
}' /root/init.sh
rm /tmp/envvars_heredoc

# container perms
####

# define comma separated list of paths 
install_paths="/tmp,/usr/share/themes,/home/nobody,/usr/share/novnc,/usr/share/applications,/usr/share/licenses,/etc/xdg,/usr/share/rider"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/tmp/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/tmp/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different 
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/tmp/puid" || ! -f "/tmp/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /tmp (used to compare on next run)
echo "\${PUID}" > /tmp/puid
echo "\${PGID}" > /tmp/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /root/init.sh
rm /tmp/permissions_heredoc

# env vars
####

# cleanup
yes|pacman -Scc
rm -rf /usr/share/locale/*
rm -rf /usr/share/man/*
rm -rf /usr/share/gtk-doc/*
rm -rf /tmp/*
