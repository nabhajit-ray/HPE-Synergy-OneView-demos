# -------------------------------------------------------------------------------------------------------
# by lionel.jullien@hpe.com
# July 2019
#
# Change the iLO password complexity option in all iLOs managed by OneView without using any iLO local account
#
# OneView administrator account is required. 
# iLO modification is done through OneView and iLO SSOsession key using REST PATCH method
# --------------------------------------------------------------------------------------------------------

#################################################################################
#        (C) Copyright 2017 Hewlett Packard Enterprise Development LP           #
#################################################################################
#                                                                               #
# Permission is hereby granted, free of charge, to any person obtaining a copy  #
# of this software and associated documentation files (the "Software"), to deal #
# in the Software without restriction, including without limitation the rights  #
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell     #
# copies of the Software, and to permit persons to whom the Software is         #
# furnished to do so, subject to the following conditions:                      #
#                                                                               #
# The above copyright notice and this permission notice shall be included in    #
# all copies or substantial portions of the Software.                           #
#                                                                               #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR    #
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,      #
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE   #
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER        #
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, #
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN     #
# THE SOFTWARE.                                                                 #
#                                                                               #
#################################################################################


#IP address of OneView
$DefaultIP = "192.168.1.110" 
Clear
$IP = Read-Host "Please enter the IP address of your OneView appliance [$($DefaultIP)]" 
$IP = ($DefaultIP, $IP)[[bool]$IP]

# OneView Credentials
$username = "Administrator" 
$defaultpassword = "password" 
$password = Read-Host "Please enter the Administrator password for OneView [$($Defaultpassword)]"
$password = ($Defaultpassword, $password)[[bool]$password]


# Import the OneView 4.20 library

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

if (-not (get-module HPOneview.420)) {  
    Import-module HPOneview.420
}

   
   
$PWord = ConvertTo-SecureString -String $password -AsPlainText -Force
$cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $Username, $PWord


# Connection to the Synergy Composer
if ((test-path Variable:ConnectedSessions) -and ($ConnectedSessions.Count -gt 1)) {
    Write-Host -ForegroundColor red "Disconnect all existing HPOV / Composer sessions and before running script"
    exit 1
}
elseif ((test-path Variable:ConnectedSessions) -and ($ConnectedSessions.Count -eq 1) -and ($ConnectedSessions[0].Default) -and ($ConnectedSessions[0].Name -eq $IP)) {
    Write-Host -ForegroundColor gray "Reusing Existing Composer session"
}
else {
    #Make a clean connection
    Disconnect-HPOVMgmt -ErrorAction SilentlyContinue
    $Appplianceconnection = Connect-HPOVMgmt -appliance $IP -PSCredential $cred
}

                
import-HPOVSSLCertificate


# Capture iLO IP adresses managed by OneView
$iloIPs = Get-HPOVServer | where mpModel -eq iLO5 | % { $_.mpHostInfo.mpIpAddresses[1].address }
clear

if ($iloIPs) {
    write-host ""
    Write-host $iloIPs.Count "iLO5 can support REST API commands and will be configured with a new password :" 
    $result = Get-HPOVServer | where mpModel -eq iLO5 | select @{Name = "IP Address"; expression = { $_.mpHostInfo.mpIpAddresses[1].address } }, name, shortModel, serialNumber 
    $result.ForEach( { [PSCustomObject]$_ }) | Format-Table -AutoSize | Out-Host

}

#Creation of the body content to enable iLO password complexity
$bodyiloParams = ConvertTo-Json   @{ Oem = @{ Hpe = @{ EnforcePasswordComplexity = $true } } } -Depth 99


# Added these lines to avoid the error: "The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel."
# due to an invalid Remote Certificate
add-type -TypeDefinition  @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy



Foreach ($iloIP in $iloIPs) {
    # Capture of the SSO Session Key
 
    $ilosessionkey = (Get-HPOVServer | where { $_.mpHostInfo.mpIpAddresses[1].address -eq $iloIP } | Get-HPOVIloSso -IloRestSession)."X-Auth-Token"
 
    # Creation of the header using the SSO Session Key 
    $headerilo = @{ } 
    $headerilo["Accept"] = "application/json" 
    $headerilo["X-API-Version"] = "1000"
    $headerilo["X-Auth-Token"] = $ilosessionkey 


    Try {

        $error.clear()

        # Modification of the Administrator password
        $rest = Invoke-WebRequest -Uri "https://$iloIP/redfish/v1/accountservice" -Body $bodyiloParams -ContentType "application/json" -Headers $headerilo -Method PATCH -UseBasicParsing

        if ($Error[0] -eq $Null) {
            write-host ""
            Write-Host "iLO password complexity option has been enabled in iLo $iloIP"
        }

    }

    #Error is returned if iLO FW is not supported
    catch [System.Net.WebException] { 
        write-host ""
        Write-Warning "$_"
        Write-Warning "The firmware of iLO: $iloIP might be too old ! The iLO password complexity option has not been changed !" 
    }
 
}

write-host ""
Read-Host -Prompt "Operation done ! Hit return to close" 
