#!/bin/bash
#
# Copyright 2025 Amazon.com, Inc. or its affiliates. and Frank Bernhardt. All Rights Reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

#
# Syntax:
#
# awsssoprofiletool.sh [-y] [--map "FROM:TO" ...] [--default <profile>] <region> <start_url> [<profile_file>]
#
# <region> is the region where AWS SSO is configured (e.g., us-east-1)
# <start_url> is the AWS SSO start URL
# <profile_file> is the file where the profiles will be written (default is
#    ~/.aws/config)
#
# Options:
# -y : Run in non-interactive mode. Overwrites the config file and creates all
#      profiles without prompts.
# --map "FROM:TO" : Map account name FROM to TO in profile names. Can be
#      specified multiple times. Example: --map "Infrastructure:Infra"
# --default <profile> : Create a [default] profile that mirrors the specified
#      profile. Example: --default "DevAdministratorAccess"

ACCOUNTPAGESIZE=10
ROLEPAGESIZE=10
PROFILEFILE="$HOME/.aws/config"

# Store account name mappings as newline-separated "FROM:TO" entries (bash 3 compatible)
account_mappings=""

noprompt=false
default_profile=""

# Variables to store default profile settings when found
default_account_id=""
default_role_name=""
default_region=""
default_output=""

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -y)
            noprompt=true
            shift
            ;;
        --map)
            if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "Error: --map requires a value in FROM:TO format"
                exit 1
            fi
            # Validate format contains exactly one colon with non-empty parts
            from_name="${2%%:*}"
            to_name="${2#*:}"
            if [ -z "$from_name" ] || [ -z "$to_name" ] || [ "$from_name" = "$2" ]; then
                echo "Error: --map value must be in FROM:TO format (e.g., 'Infrastructure:Infra')"
                exit 1
            fi
            account_mappings="${account_mappings}${2}
"
            shift 2
            ;;
        --default)
            if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "Error: --default requires a profile name"
                exit 1
            fi
            default_profile="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Syntax: $0 [-y] [--map \"FROM:TO\" ...] [--default <profile>] <region> <start_url> [<profile_file>]"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Function to apply account name mapping (bash 3 compatible)
apply_mapping() {
    local name="$1"
    local mapped
    # Search for mapping in the stored mappings
    mapped=$(echo "$account_mappings" | grep "^${name}:" | head -1)
    if [ -n "$mapped" ]; then
        echo "${mapped#*:}"
    else
        echo "$name"
    fi
}

if [ $# -lt 2 ]; then
    echo "Syntax: $0 [-y] [--map \"FROM:TO\" ...] [--default <profile>] <region> <start_url> [<profile_file>]"
    exit 1
fi

region=$1
starturl=$2

if [ $# -eq 3 ]; then
    profilefile=$3
else
    profilefile=$PROFILEFILE
fi

# Ensure .aws directory exists
profiledir=$(dirname "$profilefile")
if [ ! -d "$profiledir" ]; then
    mkdir -p "$profiledir"
fi

# Overwrite option
if [ "$noprompt" = true ]; then
    overwrite=true
else
    echo
    printf "%s" "Would you like to overwrite the output file ($profilefile)? (Y/n): "
    read overwrite_resp < /dev/tty
    if [ -z "$overwrite_resp" ];
    then
        overwrite=true
    elif [ "$overwrite_resp" == 'n' ] || [ "$overwrite_resp" == 'N' ];
    then
        overwrite=false
    else
        overwrite=true
    fi
fi

if [ "$overwrite" = true ]; then
    > "$profilefile"
fi

if [[ $(aws --version) == aws-cli/1* ]]
then
    echo "ERROR: $0 requires AWS CLI v2 or higher"
    exit 1
fi

# Get secret and client ID to begin authentication session

echo
printf "%s" "Registering client... "

out=$(aws sso-oidc register-client --client-name 'profiletool' --client-type 'public' --region "$region" --output text)

if [ $? -ne 0 ];
then
    echo "Failed"
    exit 1
else
    echo "Succeeded"
fi

secret=$(awk '{print $3}' <<< "$out")
clientid=$(awk '{print $1}' <<< "$out")

# Start the authentication process

printf "%s" "Starting device authorization... "

out=$(aws sso-oidc start-device-authorization --client-id "$clientid" --client-secret "$secret" --start-url "$starturl" --region "$region" --output text)

if [ $? -ne 0 ];
then
    echo "Failed"
    exit 1
else
    echo "Succeeded"
fi

regurl=$(awk '{print $6}' <<< "$out")
devicecode=$(awk '{print $1}' <<< "$out")

echo
echo "Open the following URL in your browser and sign in, then click the Allow button:"
echo
echo "$regurl"
echo
echo "Press <ENTER> after you have signed in to continue..."

read continue < /dev/tty

# Get the access token for use in the remaining API calls

printf "%s" "Getting access token... "

out=$(aws sso-oidc create-token --client-id "$clientid" --client-secret "$secret" --grant-type 'urn:ietf:params:oauth:grant-type:device_code' --device-code "$devicecode" --region "$region" --output text)

if [ $? -ne 0 ];
then
    echo "Failed"
    exit 1
else
    echo "Succeeded"
fi

token=$(awk '{print $1}' <<< "$out")

# Set defaults for profiles

defregion="$region"
defoutput="json"

# Batch or interactive

if [ "$noprompt" = true ]; then
    interactive=false
    awsregion=$defregion
    output=$defoutput
else
    echo
    echo "$0 can create all profiles with default values"
    echo "or it can prompt you regarding each profile before it gets created."
    echo
    printf "%s" "Would you like to be prompted for each profile? (Y/n): "
    read resp < /dev/tty
    # Default to not prompted (N)
    interactive=false
    awsregion=$defregion
    output=$defoutput
    if [ "$resp" == 'Y' ] || [ "$resp" == 'y' ];
    then
        interactive=true
    fi
fi

# Retrieve accounts first

echo
printf "%s" "Retrieving accounts... "

acctsfile="$(mktemp /tmp/sso.accts.XXXXXX)"

# Set up trap to clean up temp file
trap '{ rm -f "$acctsfile"; echo; exit 255; }' SIGINT SIGTERM
    
aws sso list-accounts --access-token "$token" --page-size $ACCOUNTPAGESIZE --region "$region" --output text > "$acctsfile"
# Sort by account name (3rd column)
sort -t $'\t' -k 3 -o "$acctsfile" "$acctsfile"

if [ $? -ne 0 ];
then
    echo "Failed"
    exit 1
else
    echo "Succeeded"
fi

declare -a created_profiles

echo "" >> "$profilefile"
echo "#BEGIN_AWS_SSO_PROFILES" >> "$profilefile"

echo "" >> "$profilefile"
echo "[sso-session my-sso]" >> "$profilefile"
echo "sso_start_url = $starturl" >> "$profilefile"
echo "sso_region = $region" >> "$profilefile"
echo "sso_registration_scopes = sso:account:access" >> "$profilefile"


# Read in accounts

while IFS=$'\t' read skip acctnum acctname acctowner;
do
    # Apply account name mappings (if --map was specified)
    acctname=$(apply_mapping "$acctname")

    echo
    echo "Adding roles for account $acctnum ($acctname)..."
    
    # Add comment to profile file
    echo "" >> "$profilefile"
    echo "# $acctname ($acctnum)" >> "$profilefile"
    
    rolesfile="$(mktemp /tmp/sso.roles.XXXXXX)"

    # Set up trap to clean up both temp files
    trap '{ rm -f "$rolesfile" "$acctsfile"; echo; exit 255; }' SIGINT SIGTERM
    
    aws sso list-account-roles --account-id "$acctnum" --access-token "$token" --page-size $ROLEPAGESIZE --region "$region" --output text > "$rolesfile"

    if [ $? -ne 0 ];
    then
	echo "Failed to retrieve roles."
	exit 1
    fi

    while IFS=$'\t' read junk junk rolename;
    do
	echo
	if $interactive ;
	then
	    printf "%s" "Create a profile for $rolename role? (Y/n): "
	    read create < /dev/tty
	    if [ -z "$create" ];
	    then
		:
	    elif [ "$create" == 'n' ] || [ "$create" == 'N' ];
	    then
		continue
	    fi
	    
	    echo
	    printf "%s" "CLI default client Region [$defregion]: "
	    read awsregion < /dev/tty
	    if [ -z "$awsregion" ]; then awsregion=$defregion ; fi
	    defregion=$awsregion
	    printf "%s" "CLI default output format [$defoutput]: "
	    read output < /dev/tty
	    if [ -z "$output" ]; then output=$defoutput ; fi
	    defoutput=$output
	fi
	
    safe_acctname=$(echo "$acctname" | tr -cd '[:alnum:]-')
	p="${safe_acctname}${rolename}"
	while true ; do
	    if $interactive ;
	    then
		printf "%s" "CLI profile name [$p]: "
		read profilename < /dev/tty
		if [ -z "$profilename" ]; then profilename=$p ; fi
		if [ -f "$profilefile" ];
		then
		    :
		else
		    break
		fi
	    else
		profilename=$p
	    fi
	    
	    if [ $(grep -ce "^\s*\[\s*profile\s\s*$profilename\s*\]" "$profilefile") -eq 0 ];
	    then
		break
	    else
		echo "Profile name already exists!"
		if $interactive ;
		then
		    :
		else
		    echo "Skipping..."
		    continue 2
		fi
	    fi
	done
	printf "%s" "Creating $profilename... "
	echo "" >> "$profilefile"
	echo "[profile $profilename]" >> "$profilefile"
	echo "sso_session = my-sso" >> "$profilefile"
	echo "sso_account_id = $acctnum" >> "$profilefile"
	echo "sso_role_name = $rolename" >> "$profilefile"
	echo "region = $awsregion" >> "$profilefile"
	echo "output = $output" >> "$profilefile"
	echo "Succeeded"
	created_profiles+=("$profilename")

	# Check if this profile should be the default
	if [ -n "$default_profile" ] && [ "$profilename" = "$default_profile" ]; then
	    default_account_id="$acctnum"
	    default_role_name="$rolename"
	    default_region="$awsregion"
	    default_output="$output"
	fi
    done < "$rolesfile"
    rm "$rolesfile"

    echo
    echo "Done adding roles for AWS account $acctnum ($acctname)"

done < "$acctsfile"
rm "$acctsfile"

# Write default profile if specified and found
if [ -n "$default_profile" ]; then
    if [ -n "$default_account_id" ]; then
        echo "" >> "$profilefile"
        echo "# Default profile (mirrors $default_profile)" >> "$profilefile"
        echo "[default]" >> "$profilefile"
        echo "sso_session = my-sso" >> "$profilefile"
        echo "sso_account_id = $default_account_id" >> "$profilefile"
        echo "sso_role_name = $default_role_name" >> "$profilefile"
        echo "region = $default_region" >> "$profilefile"
        echo "output = $default_output" >> "$profilefile"
        echo
        echo "Created [default] profile mirroring $default_profile"
    else
        echo
        echo "WARNING: --default profile '$default_profile' was not found among created profiles"
    fi
fi

echo >> "$profilefile"
echo "" >> "$profilefile"
echo "[profile old]" >> "$profilefile"
echo "region = us-east-1" >> "$profilefile"

echo "#END_AWS_SSO_PROFILES" >> "$profilefile"

echo
echo "Processing complete."
echo
echo "Added the following profiles to $profilefile:"
echo

for i in "${created_profiles[@]}"
do
    echo "$i"
done
echo
exit 0
