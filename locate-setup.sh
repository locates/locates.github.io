#!/bin/sh
#
# Locate.name: Automatic Dynamic DNS Setup for UNIX-based environments.
#

LOCATE_DOMAIN="locate.name"
LOCATE_API_DOMAIN="api.$LOCATE_DOMAIN"
LOCATE_PING_DOMAIN="ping.$LOCATE_DOMAIN"
LOCATE_PING6_DOMAIN="ping6.$LOCATE_DOMAIN"

locate_get_credentials() {
	unset LOCATE_USER LOCATE_PASS
	while [ -z "$LOCATE_USER" ] ; do
		printf "Enter your new or current subdomain (ex. \"mysubdomain\"): "
		read LOCATE_USER
	done
	while [ -z "$LOCATE_PASS" ] ; do
		printf "Enter your new or current password: "
		read LOCATE_PASS
	done
}
locate_create_curl() {
	HEADERS_OUTFILE=$(mktemp /tmp/locate.XXXXXX)
	curl -D "$HEADERS_OUTFILE" https://"$LOCATE_USER":"$LOCATE_PASS"@"$LOCATE_API_DOMAIN"/create
	if [ $? -eq 0 -a -f "$HEADERS_OUTFILE" ]; then
		LOCATE_PASSCODE=$(grep X-Passcode "$HEADERS_OUTFILE" | sed 's/.* //' | sed 's/[^a-zA-Z0-9]//g' )
	fi
	rm -f "$HEADERS_OUTFILE" 2>/dev/null
}
locate_create_wget() {
	HEADERS_OUTFILE=$(mktemp /tmp/locate.XXXXXX)
	wget -SO- https://"$LOCATE_USER":"$LOCATE_PASS"@"$LOCATE_API_DOMAIN"/create 2>"$HEADERS_OUTFILE"
	if [ $? -eq 0 -a -f "$HEADERS_OUTFILE" ]; then
		LOCATE_PASSCODE=$(grep X-Passcode "$HEADERS_OUTFILE" | sed 's/.* //' | sed 's/[^a-zA-Z0-9]//g')
	elif [ -f "$HEADERS_OUTFILE" ]; then
		grep -v '^ *$' "$HEADERS_OUTFILE" | tail -1
	fi
	rm -f "$HEADERS_OUTFILE" 2>/dev/null
}
locate_create() {
	if locate_command_exists curl; then
		locate_create_curl
	elif locate_command_exists wget; then
		locate_create_wget
	else
		echo "Sorry, \"curl\" or \"wget\" must be installed to create locate.name accounts."
		exit 1
	fi
}
locate_command_exists() {
	type "$1" 1>/dev/null 2>&1
}
locate_resolve_nslookup() {
	LOCATE_RESOLVE_CMD="nslookup -nosearch -type=$1 $2 $3";
	LOCATE_RESOLVE_CMD_EVAL="nslookup -nosearch -type=$1 "$(eval "echo $2")" $3";
	if [ "$3" = "$LOCATE_PING6_DOMAIN" ]; then
		LOCATE_RESOLVE_RESULT=$($LOCATE_RESOLVE_CMD_EVAL 2>&1 | grep -i aaaa | sed 's/.* //')
	else
		LOCATE_RESOLVE_RESULT=$($LOCATE_RESOLVE_CMD_EVAL 2>&1 | grep -iA2 ^name: | grep -iF address | sed 's/.* //')
	fi
}
locate_resolve_host() {
	LOCATE_RESOLVE_CMD="host -t $1 $2 $3";
	LOCATE_RESOLVE_CMD_EVAL="host -t $1 "$(eval "echo $2")" $3";
	LOCATE_RESOLVE_RESULT=$($LOCATE_RESOLVE_CMD_EVAL 2>&1 | grep -vi ^address |  grep -i address | grep -vi "not found" | sed 's/.* //')
}
locate_resolve() {
	if locate_command_exists host; then
		locate_resolve_host "$1" "$2" "$3"
	elif locate_command_exists nslookup; then
		locate_resolve_nslookup "$1" "$2" "$3"
	else
		echo "Sorry, \"host\" or \"nslookup\" must be installed to update your subdomain."
		exit 1
	fi
}


echo ".------------------------------------------."
echo "| Locate.name: Automatic Dynamic DNS Setup |"
echo "\`------------------------------------------'"


# Contact the API to create or access a locate.name subdomain.
while true; do
	locate_get_credentials
	locate_create
	if [ ! -z "$LOCATE_PASSCODE" ] ; then
		break
	fi
done

LOCATE_USER_DOMAIN="$LOCATE_USER.$LOCATE_DOMAIN"
LOCATE_UPDATE_USER_DOMAIN="$LOCATE_PASSCODE.$LOCATE_USER_DOMAIN"

echo "[*] Authenticated!"
echo "[*] Your passcode             : $LOCATE_PASSCODE"
echo "[*] Your subdomain            : $LOCATE_USER_DOMAIN"
echo "[*] Your update subdomain     : $LOCATE_UPDATE_USER_DOMAIN"


# Use hashcode window logic instead of plaintext passcode?
while [ -z "$LOCATE_USE_HASH_WINDOWS" ] ; do
	printf "Use hashcode windows to increase security (requires system time to be accurate) [Y/N]? "
	read CHOICE
	case "$CHOICE" in
		y|Y ) LOCATE_USE_HASH_WINDOWS='true';;
		n|N ) LOCATE_USE_HASH_WINDOWS='false';;
	esac
done
if [ "$LOCATE_USE_HASH_WINDOWS" = "true" ]; then
	if locate_command_exists sha1sum; then
		HASH_CMD="sha1sum"
	elif locate_command_exists md5sum; then
		HASH_CMD="md5sum"
	elif locate_command_exists md5; then
		HASH_CMD="md5"
	else
		HASH_CMD=""
		echo "Sorry, \"sha1sum\", \"md5sum\" or \"md5\" are required to use hashcode windows."
	fi
	if [ ! -z "$HASH_CMD" ]; then
		LOCATE_UPDATE_USER_DOMAIN="\$(printf \"$LOCATE_PASSCODE:\$(expr \$(date +%s) / 1000)\" | $HASH_CMD | awk '{print \$1\".$LOCATE_USER_DOMAIN\"}')"
	fi
fi


# Wipe existing crons that relate to this subdomain?
if ! locate_command_exists crontab; then
	echo "Sorry, \"crontab\" is required to create background tasks."
	exit 1
fi

CRON_EXISTS_COUNT=$(crontab -l | grep -iF ".$LOCATE_USER_DOMAIN" | wc -l |  sed 's/[^0-9]//g')
if [ "$CRON_EXISTS_COUNT" -gt 0 ]; then
	while [ -z "$LOCATE_CRON_WIPE" ] ; do
		printf "$CRON_EXISTS_COUNT cronjob(s) already exist for this subdomain, erase them[Y/N]? "
		read CHOICE
		case "$CHOICE" in
			y|Y ) LOCATE_CRON_WIPE='true';;
			n|N ) LOCATE_CRON_WIPE='false';;
		esac
	done
fi
if [ "$LOCATE_CRON_WIPE" = "true" ]; then
	(crontab -l | grep -viF ".$LOCATE_USER_DOMAIN") | crontab -
fi


# Test IPv4/A update capability, add cronjob if applicable.
locate_resolve A "$LOCATE_UPDATE_USER_DOMAIN" "$LOCATE_PING_DOMAIN"
if [ -z "$LOCATE_RESOLVE_RESULT" ] ; then
	echo "Sorry, the initial update test failed.  (trying again may work)"
	exit 1
fi
echo "[*] Public IPv4 update result : $LOCATE_RESOLVE_RESULT"

CRON_COUNT=0
CRON_EXISTS=$(crontab -l | grep -iF ".$LOCATE_USER_DOMAIN" | grep -iF " $LOCATE_PING_DOMAIN")
if [ -z "$CRON_EXISTS" ]; then
	(crontab -l; echo "*/5 * * * * $LOCATE_RESOLVE_CMD") | crontab -
	CRON_COUNT=$((CRON_COUNT + 1))
fi


# Test IPv6/AAAA update capability, add cronjob if applicable.
locate_resolve AAAA "$LOCATE_UPDATE_USER_DOMAIN" "$LOCATE_PING6_DOMAIN"
if [ ! -z "$LOCATE_RESOLVE_RESULT" ] ; then
	echo "[*] Public IPv6 update result : $LOCATE_RESOLVE_RESULT"
	CRON_EXISTS=$(crontab -l | grep -iF ".$LOCATE_USER_DOMAIN" | grep -iF " $LOCATE_PING6_DOMAIN")
	if [ -z "$CRON_EXISTS" ]; then
		(crontab -l; echo "*/5 * * * * $LOCATE_RESOLVE_CMD") | crontab -
		CRON_COUNT=$((CRON_COUNT + 1))
	fi
fi


# Show what we did.
echo "[*] Total cronjobs created    : $CRON_COUNT"
