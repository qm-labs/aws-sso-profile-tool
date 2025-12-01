#Requires -Version 5.1
<#
.SYNOPSIS
    AWS Profile Generator

.DESCRIPTION
    Generates AWS SSO profiles for all accounts and roles available to the user.

.PARAMETER Region
    The region where AWS SSO is configured (e.g., us-east-1)

.PARAMETER StartUrl
    The AWS SSO start URL

.PARAMETER ProfileFile
    The file where the profiles will be written (default is ~/.aws/config)

.PARAMETER NoPrompt
    Run in non-interactive mode. Overwrites the config file and creates all profiles without prompts.

.PARAMETER Map
    Map account names to shorter/different names in profile names. Format: "FROM:TO".
    Can be specified multiple times. Example: -Map "Infrastructure:Infra" -Map "Development:Dev"

.PARAMETER Default
    Create a [default] profile that mirrors the specified profile name.
    Example: -Default "DevAdministratorAccess"

.EXAMPLE
    .\awsssoprofiletool.ps1 -Region us-east-1 -StartUrl "https://example.awsapps.com/start"

.EXAMPLE
    .\awsssoprofiletool.ps1 -Region us-east-1 -StartUrl "https://example.awsapps.com/start" -NoPrompt

.EXAMPLE
    .\awsssoprofiletool.ps1 -Region us-east-1 -StartUrl "https://example.awsapps.com/start" -Map "Infrastructure:Infra" -Map "Development:Dev"

.EXAMPLE
    .\awsssoprofiletool.ps1 -Region us-east-1 -StartUrl "https://example.awsapps.com/start" -Default "DevAdministratorAccess"

.NOTES
    Copyright 2025 Amazon.com, Inc. or its affiliates. and Frank Bernhardt. All Rights Reserved.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Region,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$StartUrl,

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$ProfileFile = (Join-Path $env:USERPROFILE ".aws\config"),

    [Parameter(Mandatory = $false)]
    [switch]$NoPrompt,

    [Parameter(Mandatory = $false)]
    [string[]]$Map,

    [Parameter(Mandatory = $false)]
    [string]$Default
)

Write-Host "AWS Profile Generator"

$ACCOUNTPAGESIZE = 10
$ROLEPAGESIZE = 10

# Variables to store default profile settings when found
$defaultAccountId = ""
$defaultRoleName = ""
$defaultRegionValue = ""
$defaultOutputValue = ""

# Build account name mappings hashtable from -Map parameter
$accountMappings = @{}
if ($Map) {
    foreach ($mapping in $Map) {
        $parts = $mapping -split ':', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) {
            Write-Error "Error: -Map value must be in FROM:TO format (e.g., 'Infrastructure:Infra')"
            exit 1
        }
        $accountMappings[$parts[0]] = $parts[1]
    }
}

# Check AWS CLI version
try {
    $awsVersion = aws --version 2>&1
    if ($awsVersion -match "aws-cli/1") {
        Write-Error "ERROR: This script requires AWS CLI v2 or higher"
        exit 1
    }
}
catch {
    Write-Error "ERROR: AWS CLI not found. Please install AWS CLI v2."
    exit 1
}

# Overwrite option
if ($NoPrompt) {
    $overwrite = $true
}
else {
    Write-Host ""
    $overwriteResp = Read-Host "Would you like to overwrite the output file ($ProfileFile)? (Y/n)"
    if ([string]::IsNullOrEmpty($overwriteResp) -or $overwriteResp -eq 'Y' -or $overwriteResp -eq 'y') {
        $overwrite = $true
    }
    else {
        $overwrite = $false
    }
}

# Ensure .aws directory exists
$awsDir = Split-Path $ProfileFile -Parent
if (-not (Test-Path $awsDir)) {
    New-Item -ItemType Directory -Path $awsDir -Force | Out-Null
}

if ($overwrite) {
    "" | Set-Content -Path $ProfileFile -NoNewline
}

# Register client
Write-Host ""
Write-Host -NoNewline "Registering client... "

$registerJson = aws sso-oidc register-client --client-name 'profiletool' --client-type 'public' --region $Region --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed"
    Write-Error "$registerJson"
    exit 1
}

$registerOutput = $registerJson | ConvertFrom-Json
Write-Host "Succeeded"

$secret = $registerOutput.clientSecret
$clientId = $registerOutput.clientId

# Start device authorization
Write-Host -NoNewline "Starting device authorization... "

$authJson = aws sso-oidc start-device-authorization --client-id $clientId --client-secret $secret --start-url $StartUrl --region $Region --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed"
    Write-Error "$authJson"
    exit 1
}

$authOutput = $authJson | ConvertFrom-Json
Write-Host "Succeeded"

$regUrl = $authOutput.verificationUriComplete
$deviceCode = $authOutput.deviceCode

Write-Host ""
Write-Host "Open the following URL in your browser and sign in, then click the Allow button:"
Write-Host ""
Write-Host $regUrl
Write-Host ""
Read-Host "Press <ENTER> after you have signed in to continue..."

# Get access token
Write-Host -NoNewline "Getting access token... "

$tokenJson = aws sso-oidc create-token --client-id $clientId --client-secret $secret --grant-type 'urn:ietf:params:oauth:grant-type:device_code' --device-code $deviceCode --region $Region --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed"
    Write-Error "$tokenJson"
    exit 1
}

$tokenOutput = $tokenJson | ConvertFrom-Json
Write-Host "Succeeded"

$token = $tokenOutput.accessToken

# Set defaults for profiles
$defRegion = $Region
$defOutput = "json"

# Batch or interactive
if ($NoPrompt) {
    $interactive = $false
    $awsRegion = $defRegion
    $output = $defOutput
}
else {
    Write-Host ""
    Write-Host "This script can create all profiles with default values"
    Write-Host "or it can prompt you regarding each profile before it gets created."
    Write-Host ""
    $resp = Read-Host "Would you like to be prompted for each profile? (Y/n)"

    # Default to not prompted (N)
    $interactive = $false
    $awsRegion = $defRegion
    $output = $defOutput

    if ($resp -eq 'Y' -or $resp -eq 'y') {
        $interactive = $true
    }
}

# Retrieve accounts
Write-Host ""
Write-Host -NoNewline "Retrieving accounts... "

$accountsJson = aws sso list-accounts --access-token $token --page-size $ACCOUNTPAGESIZE --region $Region --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed"
    Write-Error "$accountsJson"
    exit 1
}

$accountsOutput = $accountsJson | ConvertFrom-Json
$accounts = $accountsOutput.accountList | Sort-Object -Property accountName
Write-Host "Succeeded"

$createdProfiles = @()

# Write sso-session block
Add-Content -Path $ProfileFile -Value ""
Add-Content -Path $ProfileFile -Value "#BEGIN_AWS_SSO_PROFILES"
Add-Content -Path $ProfileFile -Value ""
Add-Content -Path $ProfileFile -Value "[sso-session my-sso]"
Add-Content -Path $ProfileFile -Value "sso_start_url = $StartUrl"
Add-Content -Path $ProfileFile -Value "sso_region = $Region"
Add-Content -Path $ProfileFile -Value "sso_registration_scopes = sso:account:access"


# Process each account
foreach ($account in $accounts) {
    $acctNum = $account.accountId
    $acctName = $account.accountName

    # Apply account name mappings (if -Map was specified)
    if ($accountMappings.ContainsKey($acctName)) {
        $acctName = $accountMappings[$acctName]
    }

    Write-Host ""
    Write-Host "Adding roles for account $acctNum ($acctName)..."

    # Add comment to profile file
    Add-Content -Path $ProfileFile -Value ""
    Add-Content -Path $ProfileFile -Value "# $acctName ($acctNum)"

    $rolesJson = aws sso list-account-roles --account-id $acctNum --access-token $token --page-size $ROLEPAGESIZE --region $Region --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to retrieve roles."
        Write-Error "$rolesJson"
        exit 1
    }

    $rolesOutput = $rolesJson | ConvertFrom-Json
    $roles = $rolesOutput.roleList

    foreach ($role in $roles) {
        $roleName = $role.roleName

        Write-Host ""

        if ($interactive) {
            $create = Read-Host "Create a profile for $roleName role? (Y/n)"
            if ($create -eq 'n' -or $create -eq 'N') {
                continue
            }

            Write-Host ""
            $inputRegion = Read-Host "CLI default client Region [$defRegion]"
            if (-not [string]::IsNullOrEmpty($inputRegion)) {
                $awsRegion = $inputRegion
                $defRegion = $awsRegion
            }
            else {
                $awsRegion = $defRegion
            }

            $inputOutput = Read-Host "CLI default output format [$defOutput]"
            if (-not [string]::IsNullOrEmpty($inputOutput)) {
                $output = $inputOutput
                $defOutput = $output
            }
            else {
                $output = $defOutput
            }
        }

        # Sanitize account name (keep only alphanumeric and hyphen)
        $safeAcctName = $acctName -replace '[^a-zA-Z0-9-]', ''
        $defaultProfileName = "${safeAcctName}${roleName}"

        while ($true) {
            if ($interactive) {
                $inputProfileName = Read-Host "CLI profile name [$defaultProfileName]"
                if (-not [string]::IsNullOrEmpty($inputProfileName)) {
                    $profileName = $inputProfileName
                }
                else {
                    $profileName = $defaultProfileName
                }
            }
            else {
                $profileName = $defaultProfileName
            }

            # Check if profile already exists
            if (Test-Path $ProfileFile) {
                $existingContent = Get-Content $ProfileFile -Raw
                if ($existingContent -match "\[\s*profile\s+$([regex]::Escape($profileName))\s*\]") {
                    Write-Host "Profile name already exists!"
                    if ($interactive) {
                        continue
                    }
                    else {
                        Write-Host "Skipping..."
                        break
                    }
                }
            }

            Write-Host -NoNewline "Creating $profileName... "
            Add-Content -Path $ProfileFile -Value ""
            Add-Content -Path $ProfileFile -Value "[profile $profileName]"
            Add-Content -Path $ProfileFile -Value "sso_session = my-sso"
            Add-Content -Path $ProfileFile -Value "sso_account_id = $acctNum"
            Add-Content -Path $ProfileFile -Value "sso_role_name = $roleName"
            Add-Content -Path $ProfileFile -Value "region = $awsRegion"
            Add-Content -Path $ProfileFile -Value "output = $output"
            Write-Host "Succeeded"
            $createdProfiles += $profileName

            # Check if this profile should be the default
            if (-not [string]::IsNullOrEmpty($Default) -and $profileName -eq $Default) {
                $defaultAccountId = $acctNum
                $defaultRoleName = $roleName
                $defaultRegionValue = $awsRegion
                $defaultOutputValue = $output
            }
            break
        }
    }

    Write-Host ""
    Write-Host "Done adding roles for AWS account $acctNum ($acctName)"
}

# Write default profile if specified and found
if (-not [string]::IsNullOrEmpty($Default)) {
    if (-not [string]::IsNullOrEmpty($defaultAccountId)) {
        Add-Content -Path $ProfileFile -Value ""
        Add-Content -Path $ProfileFile -Value "# Default profile (mirrors $Default)"
        Add-Content -Path $ProfileFile -Value "[default]"
        Add-Content -Path $ProfileFile -Value "sso_session = my-sso"
        Add-Content -Path $ProfileFile -Value "sso_account_id = $defaultAccountId"
        Add-Content -Path $ProfileFile -Value "sso_role_name = $defaultRoleName"
        Add-Content -Path $ProfileFile -Value "region = $defaultRegionValue"
        Add-Content -Path $ProfileFile -Value "output = $defaultOutputValue"
        Write-Host ""
        Write-Host "Created [default] profile mirroring $Default"
    }
    else {
        Write-Host ""
        Write-Host "WARNING: -Default profile '$Default' was not found among created profiles"
    }
}

# Add old profile
Add-Content -Path $ProfileFile -Value ""
Add-Content -Path $ProfileFile -Value ""
Add-Content -Path $ProfileFile -Value "[profile old]"
Add-Content -Path $ProfileFile -Value "region = us-east-1"
Add-Content -Path $ProfileFile -Value ""
Add-Content -Path $ProfileFile -Value "#END_AWS_SSO_PROFILES"

Write-Host ""
Write-Host "Processing complete."
Write-Host ""
Write-Host "Added the following profiles to ${ProfileFile}:"
Write-Host ""

foreach ($profile in $createdProfiles) {
    Write-Host $profile
}

Write-Host ""
exit 0
