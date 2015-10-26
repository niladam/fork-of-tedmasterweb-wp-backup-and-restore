#!/bin/sh

# Gets the names of the available backup files and lists them for the user
# Asks the user which file should be used for restoring via a prompt
# Takes the name of a gzipped backup file and uncompresses it
# Gets the MySQL credentials from wp-config and tests the db connection
# Makes sure the backup db file exists and that it is a minimum size and has the basic WP tables in it
# Backs up the existing site and DB file to a file called failed_update_[date] inside the SecretSourceBackups folder and compresses it
# Restores live database from backup
# Deletes files from web root
# Copies backup files to web root
# Deletes .sql found inside web root produced by script above

# ISSUES
# restoring seems to be overwriting the original restore file with a different name and appending data in the tar archive


echo "Starting a restore procedure."
# set a bunch of variables
for FN in "$@"
do
	case "$FN" in
		'--documentroot')
			shift
			DOC_ROOT="${1:-public_html}"
		;;
	esac
done

# set some environment variables
THIS_DIR=$( pwd )
BACKUP_DIR="$THIS_DIR/SecretSourceBackups"
PUBLIC_HTML="${DOC_ROOT:=public_html}"
TEMP_DIR="$BACKUP_DIR/temp"
DATEFILE='%Y-%m-%d_%H%M%S'
FAILED_UPDATE_NAME=$(echo "failed_update_"`date +$DATEFILE`)
WP_CONFIG="$THIS_DIR/$PUBLIC_HTML/wp-config.php"
MYSQLDCOMMAND="$BACKUP_DIR/mysqldump.sh"

BACKUPS_EXIST=$(find "$BACKUP_DIR" -iname "*_backup_20*.tar.gz" | wc -c)
if [ $BACKUPS_EXIST -gt 1 ]
then
	OFS=$IFS
	IFS="
"
	backup_filelist=$(ls "$BACKUP_DIR" | grep "_backup_20")
	backup_filelist_bytes=$(echo "$backup_filelist" | wc -c)
	if [ $backup_filelist_bytes -gt 1 ]
	then
		PS3='Restore a site from backup: '
		until [ "$backup_file" == "Finished" ]
		do
			printf "%b" "\a\n\nPlease type the number of the archive you would like to restore from:\n" >&2 
			select backup_file in $backup_filelist
			do
				# User types a number which is stored in $REPLY, but select 
				# returns the value of the entry
				if [ "$backup_file" == "Finished" ]; then
					echo "Finished processing directories."
					break
				elif [ -n "$backup_file" ]; then
					echo "You chose number $REPLY, processing $backup_file..."
					# make a backup of the failed update
					echo "Making a backup of the failed update."
					# this line needs to be updated when in production as it
					# will no longer source it, but rather run it as a command
					ssbackup.sh --documentroot "$PUBLIC_HTML"
					BACKUP_STATUS=$?
					if (( $BACKUP_STATUS )); then echo "There was an error backing up the existing site. The error code is: $BACKUP_STATUS"; else echo "Backed up the existing site."; fi
			
					echo "Uncompressing the selected backup file."
					# uncompress the desired backup
					mkdir -p "$TEMP_DIR" 2> "$BACKUP_DIR/backup_error.log"
					tar -zxf "$BACKUP_DIR/$backup_file" -C "$TEMP_DIR" 2> "$BACKUP_DIR/backup_error.log"
					WP_CONFIG_FROM_BACKUP="$TEMP_DIR/wp-config.php"
					DB_NAME=$(grep -o -E '^\s*define.+?DB_NAME.+?,\s*.+?[a-zA-Z_][a-zA-Z_0-9]*' "$WP_CONFIG_FROM_BACKUP" | cut -d"'" -f 4)
					DB_USER=$(grep -o -E '^\s*define.+?DB_USER.+?,\s*.+?[a-zA-Z_][a-zA-Z_0-9]*' "$WP_CONFIG_FROM_BACKUP" | cut -d"'" -f 4)
					DB_PASS=$(grep -o -E '^\s*define.+?DB_PASSWORD.+' "$WP_CONFIG_FROM_BACKUP" | cut -d"'" -f 4)
					DB_HOST=$(grep -o -E '^\s*define.+?DB_HOST.+?,\s*.+?[0-9a-zA-Z_\.]*' "$WP_CONFIG_FROM_BACKUP" | cut -d"'" -f 4)
					# if the password is empty, as could be the case for insecure servers, don't use the -p switch
					if [ "" == "$DB_PASS" ]
					then
						echo "Either the password is blank or we were unable to find it."
						read -p "Please enter the password for this site and hit Enter, or hit Enter to leave it blank: " DB_PASS
						if [ "" == "$DB_PASS" ]
						then
							PASS=''
						else
							PASS="-p'$DB_PASS'"
						fi
					else
						echo "The password is NOT empty, this is good!"
						PASS="-p'$DB_PASS'"
					fi
	
					if [ "" == "$DB_USER" ]
					then
						echo "Either the database username is blank or we were unable to find it."
						read -p "Please enter the database username for this site and hit Enter: " DB_USER
						if [ "" == "$DB_USER" ]
						then
							echo "We're sorry but the database username cannot be left blank."
							echo "No action has been taken."
							exit 104
						fi
					fi
	
					if [ "" == "$DB_NAME" ]
					then
						echo "Either the database name is blank or we were unable to find it."
						read -p "Please enter the database name for this site and hit Enter: " DB_NAME
						if [ "" == "$DB_NAME" ]
						then
							echo "We're sorry but the database name cannot be left blank."
							echo "No action has been taken."
							exit 105
						fi
					fi
	
					if [ "" == "$DB_HOST" ]
					then
						echo "Either the database host is blank or we were unable to find it."
						read -p "Please enter the database host for this site and hit Enter: " DB_HOST
						if [ "" == "$DB_HOST" ]
						then
							echo "We're sorry but the database host cannot be left blank."
							echo "No action has been taken."
							exit 106
						fi
					fi
	
					HOST_HAS_PORT=$(echo $DB_HOST | grep -o ':')
					if [ ! "" == "$HOST_HAS_PORT" ]
					then
						DB_HOST=${DB_HOST/\:[0-9]*/}
					fi
			
					# get the most recently created backup file and rename it
					# only do this if the backup actually succeeded
					# /usr/local/bin/ssrestore.sh: line 134: ((: 0 -eq 0 : syntax error in expression (error token is "0 ")
					# when using if (( 0 -eq "$BACKUP_STATUS" ))
					if (( 0 == $BACKUP_STATUS ))
					then
						FAILED_UPDATE_NAME_TGZ="${DB_NAME}_$FAILED_UPDATE_NAME.tar.gz"
						F=$(find "$BACKUP_DIR" -iname *.tar.gz -type f | sort | tail -n 1)
						NF=$(basename "$F")
						mv "$F" "$BACKUP_DIR/$FAILED_UPDATE_NAME_TGZ" 2> "$BACKUP_DIR/backup_error.log"
					fi
					
					# get the name of the restore database
					# select the last line of files that start with backup_ and end with .sql
					DB_RESTORE_NAME=$(basename $(find "$TEMP_DIR" -type f -iregex '.*/backup_.+\.sql' | tail -n 1))
					echo "Restoring from $DB_RESTORE_NAME"
			
					echo "Restoring the database"
					# put WP into maintenace mode, if possible
					# drop and reimport the database
					echo '#!/bin/sh' > "$BACKUP_DIR/mysql_restore.sh"
					echo "
			
					" >> "$BACKUP_DIR/mysql_restore.sh"
					echo "mysql -u '$DB_USER' $PASS -h '$DB_HOST' -e 'DROP DATABASE IF EXISTS $DB_NAME'" >> "$BACKUP_DIR/mysql_restore.sh"
					echo "mysql -u '$DB_USER' $PASS -h '$DB_HOST' -e 'CREATE DATABASE IF NOT EXISTS $DB_NAME'" >> "$BACKUP_DIR/mysql_restore.sh"
					echo "mysql -u '$DB_USER' $PASS -h '$DB_HOST' '$DB_NAME' < '$TEMP_DIR/$DB_RESTORE_NAME'" >> "$BACKUP_DIR/mysql_restore.sh"
					. "$BACKUP_DIR/mysql_restore.sh" 2> "$BACKUP_DIR/backup_error.log"
			
					# delete everything in public_html
					echo "Removing everything in $THIS_DIR/$PUBLIC_HTML/*"
					rm -rf "$THIS_DIR/$PUBLIC_HTML/*" 2> "$BACKUP_DIR/backup_error.log"
			
					# move contents of restore folder to public_html
					echo "Restoring the WP files and all uploaded content."
					rm -Rf "$THIS_DIR/$PUBLIC_HTML/*"
					OWD=$(pwd)
					cd "$TEMP_DIR"
					cp -Rv . "$THIS_DIR/$PUBLIC_HTML/" 2> "$BACKUP_DIR/backup_error.log"
					cd "$OWD"
			
					echo "Removing temporary files."
					# delete uncompressed folder (house cleaning)
					rm -Rf "$TEMP_DIR" 2> "$BACKUP_DIR/backup_error.log"
					rm -f "$BACKUP_DIR/mysql_restore.sh" 2> "$BACKUP_DIR/backup_error.log"
					rm -f "$THIS_DIR/$PUBLIC_HTML/$DB_RESTORE_NAME.sql" 2> "$BACKUP_DIR/backup_error.log"
					echo "Done! The site has been restored."
					exit 0
					break
				else
					echo "Invalid selection!"
				fi # end of handle user's selection
			done # end of select a backup_file 
		done # end of until dir == finished
		IFS=$OFS
	else
		echo "No backup files are available for restoring."
		exit 107 
	fi
else
	echo "Sorry. There don't appear to be any backup files available for restoring."
	echo "Did you run ssbackup.sh before running this RESTORE command?"
fi
