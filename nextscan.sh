#!/bin/bash

local_external_share="/path/to/share"
exclude="Folder"
sharename="Nextcloudsharename"
modifications="/tmp/modifications"
mod_to_process="/tmp/mod_to_process"
fullscan=120
fullscandt=86400

monitor_changes(){
        while read FILE; do
                echo "${FILE}" >> "${modifications}"
        done <  <(inotifywait -rmq --format '%w' "${local_external_share}" --exclude "${exclude}" -e create,delete,modify,moved_to,moved_from)
}

nextcloudusers=()
get_nextcloud_users(){
        nextcloudusers=()
        rawusers=$(docker exec -i -u www-data nextcloud php occ user:list)
        external_storage=$(docker exec -i -u www-data nextcloud php occ files_external:list)
        while read line; do
                user=$(echo ${line} | cut -d " " -f2 | tr -dc '[:alnum:]\n')
                if [[ ${external_storage} =~ ${user} ]]; then
                        nextcloudusers+=("${user}")
                fi
        done <  <(docker exec -i -u www-data nextcloud php occ user:list)
}

userstoscan=()
get_userstoscan(){
        userstoscan=()
        group=$(stat -c %G "$1")
        users=$(members "$group")
        IFS=' ' read -r -a systemusers <<< "$users"

        for nextclouduser in "${nextcloudusers[@]}"
        do
                if [[ "${systemusers[@],,}" =~ ${nextclouduser,,} ]]; then
                        userstoscan+=("${nextclouduser}")
                fi
        done
}

parsed_mod=()
parse_modifications() {
        mv ${modifications} ${mod_to_process}
        mapfile -t parsed_mod < <(cat ${mod_to_process} | sort -u)
}

do_periodic_fullscan(){
        echo "$(date) Periodic Fullscan"
        docker exec -i -u www-data nextcloud php occ files:scan --all
        ((fullscan=SECONDS+$fullscandt))
}

do_delayed_fullscan(){
        sleep 60
        parse_modifications
        echo "$(date) Fullscan because multiple files modifications"
        docker exec -i -u www-data nextcloud php occ files:scan --all
}

do_scan(){
        nextcloudfilepath=${1#"$local_external_share"}
        for user in "${userstoscan[@]}"
        do
                nextcloudpath="${user}/files/${sharename}${nextcloudfilepath}"
                echo "$(date) scan ${nextcloudpath}"
                docker exec -i -u www-data nextcloud php occ files:scan --path="${nextcloudpath}"
        done
}

main(){
        monitor_changes &
        get_nextcloud_users
        echo "${nextcloudusers[@]}"
        while true
        do
                if [ $SECONDS -ge $fullscan ]; then
                        do_periodic_fullscan
                        continue
                fi
                if [ ! -f ${modifications} ]; then
                        echo "Nothing found"
                        sleep 15
                        continue
                fi
                parse_modifications
                if [ "${#parsed_mod[@]}" -ge 10 ]; then
                        do_delayed_fullscan
                        continue
                fi
                for path in "${parsed_mod[@]}"
                do
                        get_userstoscan "${path}"
                        do_scan "${path}"
                done
                sleep 15
        done
}
main

