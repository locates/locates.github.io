# To bypass default powershell security rules run explicitly as:
#
#   powershell -ExecutionPolicy Bypass "C:\path\to\locate-setup.ps1"


# Make sure we're running as Administrator.  (for the background task)
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
	exit
}

$LOCATE_DOMAIN="locate.name"
$LOCATE_API_DOMAIN="api.$LOCATE_DOMAIN"
$LOCATE_PING_DOMAIN="ping.$LOCATE_DOMAIN"
$LOCATE_PING6_DOMAIN="ping6.$LOCATE_DOMAIN"

function Locate-Resolve {
	Param([string]$type, [string]$hostname, [string]$server)
	try {
		$result = Resolve-DnsName -DnsOnly -Type "$type" -Server "$server" "$hostname" -ErrorAction Stop
		$result | Where-Object Section -eq Answer | ForEach-Object { $_.IPAddress } | Select -First 1
	}
	catch { }
}

echo ".------------------------------------------."
echo "| Locate.name: Automatic Dynamic DNS Setup |"
echo "'------------------------------------------'"

# Contact the API to create or access a locate.name subdomain.
while([string]::IsNullOrEmpty($locate_passcode)) {
	try {
		$LOCATE_USER = Read-Host -Prompt 'Enter your new or current subdomain (ex. "mysubdomain")'
		$LOCATE_PASS = Read-Host -Prompt 'Enter your new or current password'
		$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($LOCATE_USER):$($LOCATE_PASS)"))
		$headers = @{ Authorization = "Basic $auth" }
		$result = Invoke-WebRequest -Uri "https://$LOCATE_API_DOMAIN/create" -Headers $headers
		$LOCATE_PASSCODE = $result.Headers.'X-Passcode'
	}
	catch { echo $_.Exception.Message }
}

$LOCATE_USER_DOMAIN="$LOCATE_USER.$LOCATE_DOMAIN"
$LOCATE_UPDATE_USER_DOMAIN="$LOCATE_PASSCODE.$LOCATE_USER_DOMAIN"

echo "[*] Authenticated!"
echo "[*] Your passcode             : $LOCATE_PASSCODE"
echo "[*] Your subdomain            : $LOCATE_USER_DOMAIN"
echo "[*] Your update subdomain     : $LOCATE_UPDATE_USER_DOMAIN"


# Test IPv4/A update capability.
$LOCATE_RESOLVE_RESULT = Locate-Resolve A $LOCATE_UPDATE_USER_DOMAIN $LOCATE_PING_DOMAIN
if([string]::IsNullOrEmpty($LOCATE_RESOLVE_RESULT)) {
	echo "Sorry, the initial update test failed.  (trying again may work)"
	exit 1
}
echo "[*] Public IPv4 update result : $LOCATE_RESOLVE_RESULT"
$LOCATE_TASK_NAME="$LOCATE_USER_DOMAIN IP Updater"
echo "[*] Attempting to add task    : '$LOCATE_TASK_NAME'"
schtasks /create /tn $LOCATE_TASK_NAME /ru SYSTEM /tr "nslookup -nosearch -type=A $LOCATE_UPDATE_USER_DOMAIN $LOCATE_PING_DOMAIN" /sc minute /mo 5


# Test IPv6/AAAA update capability.
$LOCATE_RESOLVE_RESULT = Locate-Resolve AAAA $LOCATE_UPDATE_USER_DOMAIN $LOCATE_PING6_DOMAIN
if(-not [string]::IsNullOrEmpty($LOCATE_RESOLVE_RESULT)) {
	$LOCATE_TASK_NAME="$LOCATE_USER_DOMAIN IPv6 Updater"
	echo "[*] Attempting to add task    : '$LOCATE_TASK_NAME'"
	schtasks /create /tn $LOCATE_TASK_NAME /ru SYSTEM /tr "nslookup -nosearch -type=AAAA $LOCATE_UPDATE_USER_DOMAIN $LOCATE_PING6_DOMAIN" /sc minute /mo 5
}


# Make sure we leave the window open if windows automatically close.
Read-Host -Prompt "Press Enter to exit"
