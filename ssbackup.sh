#!/bin/sh

# Write a script that, when executed from the home directory of an account via the command line:
# Creates ~/SecretSourceBackups if it doesn't exist
# Creates a backup folder inside ~/SecretSourceBackups with the date and time as the name, e.g.: 2015-08-24_23-17-11
# Copies the web root to the backup folder
# Gets the MySQL credentials from wp-config and tests the db connection
# Dumps the database to the web folder
# Makes sure the database backup file is of a certain, minimum size and contains the minimum WP tables (do some minimum sanity checks)
# Compresses the backup folder to save space

# The above script will be called ss_backup.sh. It will take no parameters but must be run from the account home (a.k.a. ~/). It expects to find a web root called public_html. 
 

# set some environment variables
THIS_DIR=$( pwd )
BACKUP_DIR="$THIS_DIR/SecretSourceBackups"
mkdir -p "$BACKUP_DIR"
DATEFILE='%Y-%m-%d_%H%M%S'
BACKUP_NAME=$(echo "backup_"`date +$DATEFILE`)
WP_CONFIG="$THIS_DIR/public_html/wp-config.php"
DB_BACKUP_FILE="$THIS_DIR/public_html/$BACKUP_NAME.sql"
MYSQLDCOMMAND="$BACKUP_DIR/mysqldump.sh"

# Optional, save the "old" STDERR
exec 3>&2
# Redirect any output to STDERR to an error log file instead 
exec 2> "$BACKUP_DIR/backup_error.log"

# set a bunch of variables

# make sure wp-config.php actually exists before doing anything else
if [ -f "$WP_CONFIG" ]
then
	echo "Found the wp-config.php file. This is good!"
	# get the DB config from wp-config.php
	DB_NAME=$(grep -o -E '^\s*define.+?DB_NAME.+?,\s*.+?[a-zA-Z_][a-zA-Z_0-9]*' "$WP_CONFIG" | cut -d"'" -f 4)
	DB_USER=$(grep -o -E '^\s*define.+?DB_USER.+?,\s*.+?[a-zA-Z_][a-zA-Z_0-9]*' "$WP_CONFIG" | cut -d"'" -f 4)
	DB_PASS=$(grep -o -E '^\s*define.+?DB_PASSWORD.+' "$WP_CONFIG" | cut -d"'" -f 4)
	DB_HOST=$(grep -o -E '^\s*define.+?DB_HOST.+?,\s*.+?[0-9a-zA-Z_\.]*' "$WP_CONFIG" | cut -d"'" -f 4)
	BACKUP_NAME_TGZ="${DB_NAME}_$BACKUP_NAME.tar.gz"

	# if the password is empty, as could be the case for insecure servers, don't use the -p switch
	if [ "" == "$DB_PASS" ]
	then
		PASS=''
	else
		echo "The password is NOT empty, this is good!"
		PASS="-p'$DB_PASS'"
	fi
	# dump the db to a file inside the web root
	# there is some kind of bizzare issue porhibiting me from quoting the value of the password parameter
	# as a workaround, I'm going to try writing the command to an external file and executing it instead of trying to run it here
	echo '#!/bin/sh' > "$MYSQLDCOMMAND"
	echo "
	
	" >> "$MYSQLDCOMMAND"
	# not really sure how to capture a non-zero exit status from the command below
	echo "mysqldump -u '$DB_USER' $PASS -h $DB_HOST '$DB_NAME' > '$DB_BACKUP_FILE'" >> "$MYSQLDCOMMAND"
	. "$MYSQLDCOMMAND"

	if [ -f "$DB_BACKUP_FILE" ]
	then
		echo "The backup file was created. Checking to see if it is valid."
		# do a sanity check
		#	make sure it is a minimum size
		DB_BACKUP_FILE_SIZE=$(du -k "$DB_BACKUP_FILE" | cut -f 1)
		if [ "$DB_BACKUP_FILE_SIZE" -lt 500 ]
		then
			# file size is too small
			echo "The size of the database dump seems suspiciously small ($st_size). Please check the size and try again."
			exit 102
		else
			echo "The backup file seems to be large enough to be valid"
		fi
		#	make sure some key tables are defined
		# grep the backup file looking for definitions of default tables
		# if all the tables are there (as judged by the number of lines found, S/B 11) then proceed
		TABLES=$(grep -c -E 'CREATE TABLE `(wp_commentmeta|wp_comments|wp_links|wp_options|wp_postmeta|wp_posts|wp_term_relationships|wp_term_taxonomy|wp_terms|wp_usermeta|wp_users)`' "$DB_BACKUP_FILE")
		if [ $TABLES -lt 11 ]
		then
			echo "The backup seems to have failed. Specifically, we seem to be missing some core tables in the database backup. Please check the file and try again."
			echo "$DB_BACKUP_FILE"
			exit 103
		else
			echo "All required tables appear to be defined in the dump"
		fi
		echo "All tests have passed. Proceeding with the backup."
		tar -czf "$BACKUP_DIR/$BACKUP_NAME_TGZ" -C "$THIS_DIR/public_html" .
		echo "Cleaning up..."
		rm -f "$MYSQLDCOMMAND"
		rm -f "$DB_BACKUP_FILE"
		echo "Done. The backup file is: $BACKUP_DIR/$BACKUP_NAME_TGZ"
	else
		echo "backup file doesn't exist"
	fi
else
	# echo an error message and quit
	echo "Uh, the wp-config.php file can't be found"
	echo "We're looking here for it: $WP_CONFIG"
	echo "Are you running this script from the right location? ~/"
	echo "Have gremlins eaten it?"
	exit 101
fi

# Turn off redirect by reverting STDERR and closing FH3 
exec 2>&3-
