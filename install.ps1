param (
    [ValidateSet("sqlcmd", "sqlengine")]
    [string[]]$Components,
    [bool]$ForceEncryption,
    [string]$SaPassword,
    [ValidateSet("2019", "2022")]
    [string]$Version
)

function Wait-ForContainer {
    $checkInterval = 5
    $containerName = "sql"
    $timeout = 60

    $startTime = Get-Date
    Write-Host "Waiting for the container '$containerName' to be healthy..."

    while ($true) {
        # Get the container's health status
        $healthStatus = (docker inspect --format='{{.State.Health.Status}}' $containerName) 2>&1

        if ($healthStatus -eq "healthy") {
            Write-Host "Container '$containerName' is healthy."
            break
        }
        elseif ((Get-Date) -gt $startTime.AddSeconds($timeout)) {
            Write-Host "Timed out waiting for container '$containerName' to be healthy."
            & docker logs sql
            & docker inspect --format "{{json .State.Health }}" sql
            exit 1
        }

        # Wait for the check interval before checking again
        Start-Sleep -Seconds $checkInterval
    }
}

# figure out if we are running Ubuntu 24.04, as we need to implement a couple of custom behaviours for it
$IsUbuntu2404 = $false
if ($IsLinux) {
    $osRelease = Get-Content -Path "/etc/os-release" | Out-String
    $osRelease -match 'VERSION_ID="(\d+\.\d+)"' | Out-Null
    $IsUbuntu2404 = $matches[1] -eq "24.04"
}

if ("sqlengine" -in $Components) {
    if ($IsLinux) {
        if ($ForceEncryption) {
            Write-Output "Force encryption is set, generating self-signed certificate ..."
    
            # SOURCE: https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-docker-container-security?view=sql-server-ver16#encrypt-connections-to-sql-server-linux-containers
            & mkdir -p /opt/mssql
            & openssl req -x509 -nodes -newkey rsa:2048 -subj '/CN=sql1.contoso.com' -keyout /opt/mssql/mssql.key -out /opt/mssql/mssql.pem -days 365
            
            # Microsoft recommends to mount the SQL certificates at /etc/ssl/certs and /etc/ssl/private
            # However, with SQL Server 2019, this always results in a file permission error
            # Also mounting it into the /var/opt/mssql directory works just fine
            $MssqlConf = @'
[network]
tlscert = /var/opt/mssql/mssql.pem
tlskey = /var/opt/mssql/mssql.key
tlsprotocols = 1.2
forceencryption = 1
'@
    
            Set-Content -Path /opt/mssql/mssql.conf -Value $MssqlConf
            & sudo chmod -R 775 /opt/mssql
    
            Copy-Item -Path /opt/mssql/mssql.pem -Destination /usr/share/ca-certificates/mssql.crt
            & sudo dpkg-reconfigure ca-certificates 
                
            $AdditionalContainerConfiguration = "-v /opt/mssql/mssql.conf:/var/opt/mssql/mssql.conf -v /opt/mssql/mssql.pem:/var/opt/mssql/mssql.pem -v /opt/mssql/mssql.key:/var/opt/mssql/mssql.key"
        }

        switch ($Version) {
            "2019" {
                $Tag = "CU30-ubuntu-20.04"
            }
            "2022" {
                $Tag = "CU17-ubuntu-22.04"
            }
        }

        Write-Output "Starting a Docker Container"
        Invoke-Expression "docker run --name=`"sql`" -e `"ACCEPT_EULA=Y`"-e `"SA_PASSWORD=$SaPassword`" --health-cmd=`"/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P '$SaPassword' -Q 'SELECT 1' -b -o /dev/null`" --health-start-period=`"10s`" --health-retries=3 --health-interval=`"10s`" -p 1433:1433 $AdditionalContainerConfiguration -d `"mcr.microsoft.com/mssql/server:$Version-$Tag`""
        Wait-ForContainer
    }

    if ($IsWindows) {
        Write-Output "Downloading and installing SQL Server"
        New-Item -ItemType Directory -Path "C:\Downloads"

        switch ($Version) {
            "2019" {
                $DownloadUrl = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLEXPR_x64_ENU.exe"
                $MajorVersion = 15
            }
            "2022" {
                $DownloadUrl = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe"
                $MajorVersion = 16
            }
        }

        Invoke-WebRequest $DownloadUrl -OutFile "C:\Downloads\mssql.exe"
        Start-Process -Wait -FilePath "C:\Downloads\mssql.exe" -ArgumentList /qs, /x:"C:\Downloads\setup"
        C:\Downloads\setup\setup.exe /q /ACTION=Install /INSTANCENAME=SQLEXPRESS /FEATURES=SQLEngine /UPDATEENABLED=0 /SQLSVCACCOUNT='NT AUTHORITY\System' /SQLSYSADMINACCOUNTS='BUILTIN\ADMINISTRATORS' /TCPENABLED=1 /NPENABLED=0 /IACCEPTSQLSERVERLICENSETERMS

        Write-Host "Configuring SQL Express ..."
        stop-service MSSQL`$SQLEXPRESS

        $InstancePath = "HKLM:\software\microsoft\microsoft sql server\mssql$MajorVersion.SQLEXPRESS\mssqlserver"
        $SuperSocketNetLibPath = "$InstancePath\supersocketnetlib"
        set-itemproperty -path "$SuperSocketNetLibPath\tcp\ipall" -name tcpdynamicports -value ''
        set-itemproperty -path "$SuperSocketNetLibPath\tcp\ipall" -name tcpport -value 1433
        set-itemproperty -path $InstancePath -name LoginMode -value 2

        # SOURCE: https://blogs.infosupport.com/configuring-sql-server-encrypted-connections-using-powershell/
        if ($ForceEncryption) {
            Write-Output "Force encryption is set, configuring SQL server to do so ..."

            $params = @{
                DnsName           = 'sql1.contoso.com'
                CertStoreLocation = 'Cert:\LocalMachine\My'
            }
            $Certificate = New-SelfSignedCertificate @params

            Set-ItemProperty $SuperSocketNetLibPath -Name "Certificate" -Value $Certificate.Thumbprint.ToLowerInvariant()
            Set-ItemProperty $SuperSocketNetLibPath -Name "ForceEncryption" -Value 1
        }

        Write-Host "Starting SQL Express ..."
        start-service MSSQL`$SQLEXPRESS
        & sqlcmd -Q "ALTER LOGIN sa with password='$SaPassword'; ALTER LOGIN sa ENABLE;"
    }
}

if ("sqlcmd" -in $Components) {
    if ($IsUbuntu2404) {
        # for maintenance reasons, sqlcmd has been removed from the Ubuntu 24.04 runner image
        # but a dedicated build is also not yet available, so we are using the Ubuntu 22.04 build
        Write-Output "Installing sqlcmd tools"

        $DownloadPath = "/tmp/sqlcmd.deb"
        Invoke-WebRequest "https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/s/sqlcmd/sqlcmd_1.5.0-1_jammy_all.deb" -OutFile $DownloadPath
        & sudo dpkg -i $DownloadPath
        Remove-Item $DownloadPath
    }

    # Linux and Windows runner already contain sqlclient tools
    Write-Output "sqlclient tools are installed"
}
