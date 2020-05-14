
$InstanceOS = "${instance_os}"
$InstanceType = "${instance_type}"
$isBuilder = $false
$isStandalone = $false
if ($InstanceType -eq "builder") {
  $isBuilder = $true
}
if ($InstanceType -eq "sa") {
  $isStandalone = $true
}

# global vars
$BuildSlug = "${build_slug}"
$ErrorSignalFile = "${error_signal_file}"
$RMUser = "${rm_user}"
$PypiUrl = "${pypi_url}"
$DebugMode = "${debug}"

# log file
$UserdataLogFile = "${userdata_log}"
if (-not (Test-Path "$UserdataLogFile")) {
  New-Item "$UserdataLogFile" -ItemType "file" -Force
}

# directory needed by logs and for various other purposes
$TempDir = "${temp_dir}"
if (-not (Test-Path "$TempDir")) {
  New-Item "$TempDir" -ItemType "directory" -Force
}
cd $TempDir

function Debug-2S3 {
  ## Immediately upload the debug and log files to S3.
  param (
    [Parameter(Mandatory=$false)][string]$Msg
  )

  $DebugFile = "$TempDir\debug.log"
  "$(Get-Date): $Msg" | Out-File $DebugFile -Append -Encoding utf8
  Write-S3Object -BucketName "$BuildSlug/$InstanceOS$InstanceType" -File $DebugFile
  Write-S3Object -BucketName "$BuildSlug/$InstanceOS$InstanceType" -File $UserdataLogFile
}

function Check-Metadata-Availability {
  ## This will not return until metadata is available.
  $MetadataLoopbackAZ = "http://169.254.169.254/latest/meta-data/placement/availability-zone"
  $MetadataCommand = "Invoke-WebRequest -Uri $MetadataLoopbackAZ -UseBasicParsing | Select-Object -ExpandProperty Content"

  Test-Command $MetadataCommand 50

  Invoke-Expression -Command $MetadataCommand -OutVariable AZ
  Write-Tfi "Connect to EC2 metadata (AZ is $AZ)" $?
}

function Write-Tfi {
  ## Writes messages to a SolidGround log file. Second param is success/failure related to msg.
  param (
    [String]$Msg,
    $Success = $null
  )

  # result is succeeded or failed or nothing if success is null
  if ( $Success -ne $null ) {
    if ($Success) {
      $OutResult = ": Succeeded"
    } else {
      $OutResult = ": Failed"
    }
  }

  "$(Get-Date): $Msg $OutResult" | Out-File "$UserdataLogFile" -Append -Encoding utf8

  if ("$DebugMode" -ne "0" ) {
    Debug-2S3 "$Msg $OutResult"
  }
}

function Test-Command {
  ## Tests commands and handles/retries errors that result.
  param (
    [Parameter(Mandatory=$true)][string]$Test,
    [Parameter(Mandatory=$false)][int]$Tries = 1,
    [Parameter(Mandatory=$false)][int]$SecondsDelay = 2
  )
  $TryCount = 0
  $Completed = $false
  $MsgFailed = "Command [{0}] failed" -f $Test
  $MsgSucceeded = "Command [{0}] succeeded." -f $Test

  while (-not $Completed) {
    try {
      $Result = @{}
      # Invokes commands and in the same context captures the $? and $LastExitCode
      Invoke-Expression -Command ($Test+';$Result = @{ Success = $?; ExitCode = $LastExitCode }')
      if (($False -eq $Result.Success) -Or ((($Result.ExitCode) -ne $null) -And (0 -ne ($Result.ExitCode)) )) {
        throw $MsgFailed
      } else {
        Write-Tfi $MsgSucceeded
        $Completed = $true
      }
    } catch {
      $TryCount++
      if ($TryCount -ge $Tries) {
        $Completed = $true
        $ErrorMessage = [String]$_.Exception + "Invocation Info: " + ($PSItem.InvocationInfo | Format-List * | Out-String)
        Write-Tfi $ErrorMessage
        Write-Tfi ("Command [{0}] failed the maximum number of {1} time(s)." -f $Test, $Tries)
        Write-Tfi ("Error code (if available): {0}" -f ($Result.ExitCode))
        throw ("Command [{0}] failed" -f $Test)
      } else {
        Write-Tfi ("Command [{0}] failed. Retrying in {1} second(s)." -f $Test, $SecondsDelay)
        Start-Sleep $SecondsDelay
      }
    }
  }
}

function Publish-Artifacts {
  ## Uploads various useful files to s3 relative to the test/build.
  $ErrorActionPreference = "Continue"

  # create a directory with all the build artifacts
  $ArtifactDir = "$TempDir\build-artifacts"
  Invoke-Expression -Command "mkdir $ArtifactDir" -ErrorAction SilentlyContinue
  Invoke-Expression -Command "mkdir $ArtifactDir\watchmaker" -ErrorAction SilentlyContinue # need to create dir if globbing to it
  Copy-Item "C:\Watchmaker\Logs\*log" -Destination "$ArtifactDir\watchmaker" -Recurse -Force
  Copy-Item "C:\Watchmaker\SCAP" -Destination "$ArtifactDir\scap" -Recurse -Force
  Copy-Item "C:\ProgramData\Amazon\EC2-Windows\Launch\Log" -Destination "$ArtifactDir\cloud" -Recurse -Force
  Copy-Item "C:\Program Files\Amazon\Ec2ConfigService\Logs" -Destination "$ArtifactDir\cloud" -Recurse -Force
  Copy-Item "C:\Windows\TEMP\*.tmp" -Destination "$ArtifactDir\cloud" -Recurse -Force
  Copy-Item "C:\Program Files\Amazon\Ec2ConfigService\Scripts\User*ps1" -Destination "$ArtifactDir\cloud" -Recurse -Force
  Get-ChildItem Env: | Out-File "$ArtifactDir\cloud\environment_variables.log" -Append -Encoding utf8

  # copy artifacts to s3
  Write-Tfi "Writing logs to $BuildSlug/$InstanceOS$InstanceType"
  Copy-Item $UserdataLogFile -Destination "$ArtifactDir" -Force
  Write-S3Object -BucketName "$BuildSlug" -KeyPrefix "$InstanceOS$InstanceType" -Folder "$ArtifactDir" -Recurse

  # creates compressed archive to upload to s3
  $BuildSlugZipName = "$BuildSlug" -replace '/','-'
  $ZipFile = "$TempDir\$BuildSlugZipName-$InstanceOS$InstanceType.zip"
  cd 'C:\Program Files\7-Zip'
  Test-Command ".\7z a -y -tzip $ZipFile -r $ArtifactDir\*"
  Write-S3Object -BucketName "$BuildSlug" -File $ZipFile
}

function Test-DisplayResult {
  ## Call this function with $? to log the outcome and throw errors.
  param (
    [String]$Msg,
    $Success = $null
  )

  Write-Tfi $Msg $Success
  if (-not $Success) {
    throw "$Msg : FAILED"
  }
}

function Write-UserdataStatus {
  ## Write file to the local system to indicate the outcome of the userdata script.
  param (
    [Parameter(Mandatory=$true)]$UserdataStatus
  )

  # write the status to a file for reading by test script
  $UserdataStatus | Out-File "${userdata_status_file}"
  Write-Tfi "Write userdata status file" $?
}

function Open-WinRM {
  ## Open WinRM for access by, for example, a Terraform remote-exec provisioner.
  # initial winrm setup
  Start-Process -FilePath "winrm" -ArgumentList "quickconfig -q"
  Write-Tfi "WinRM quickconfig" $?
  Start-Process -FilePath "winrm" -ArgumentList "set winrm/config/service @{AllowUnencrypted=`"true`"}" -Wait
  Write-Tfi "Open winrm/unencrypted" $?
  Start-Process -FilePath "winrm" -ArgumentList "set winrm/config/service/auth @{Basic=`"true`"}" -Wait
  Write-Tfi "Open winrm/auth/basic" $?
  Start-Process -FilePath "winrm" -ArgumentList "set winrm/config @{MaxTimeoutms=`"1900000`"}"
  Write-Tfi "Set winrm timeout" $?
}

function Close-Firewall {
  ## Close the local firewall to WinRM traffic.
  # close the firewall
  netsh advfirewall firewall add rule name="WinRM in" protocol=tcp dir=in profile=any localport=5985 remoteip=any localip=any action=block
  Write-Tfi "Close firewall" $?
}

function Open-Firewall {
  ## Open the local firewall to WinRM traffic.
  # open firewall for winrm - rule was added previously, now we modify it with "set"
  netsh advfirewall firewall set rule name="WinRM in" new action=allow
  Write-Tfi "Open firewall" $?
}

function Rename-User {
  ## Renames a system username.
  param (
    [Parameter(Mandatory=$true)][string]$From,
    [Parameter(Mandatory=$true)][string]$To
  )

  $Admin = [adsi]("WinNT://./$From, user")
  if ($Admin.Name) {
    $Admin.psbase.rename("$To")
    Write-Tfi "Rename $From account to $To" $?
  }
}

function Set-Password {
  ## Changes a system user's password.
  param (
    [Parameter(Mandatory=$true)][string]$User,
    [Parameter(Mandatory=$true)][string]$Pass
  )
  # Set Administrator password, for logging in before wam changes Administrator account name
  $Admin = [adsi]("WinNT://./$User, user")
  if ($Admin.Name) {
    $Admin.psbase.invoke("SetPassword", $Pass)
    Write-Tfi "Set $User password" $?
  } else {
    Write-Tfi "Unable to set password because user ($User) was not found."
  }
}

function Invoke-CmdScript {
  ## Invoke the specified batch file with params, and propagate env var changes back to
  ## PowerShell environment that called it.
  ##
  ## Recipe from "Windows PowerShell Cookbook by Lee Holmes"
  param (
    [string] $script,
    [string] $parameters
  )

  $tempFile = [IO.Path]::GetTempFileName()

  ## Store the output of cmd.exe. We also ask cmd.exe to output
  ## the environment table after the batch file completes
  cmd /c " `"$script`" $parameters && set > `"$tempFile`" "

  ## Go through the environment variables in the temp file.
  ## For each of them, set the variable in our local environment.
  Get-Content $tempFile | Foreach-Object {
    if($_ -match "^(.*?)=(.*)$") {
      Set-Content "env:\$($matches[1])" $matches[2]
    }
  }

  Remove-Item $tempFile
}

function Install-PythonGit {
  ## Use the Watchmaker bootstrap to install Python and Git.
  $BootstrapUrl = "${bootstrap_url}"
  $PythonUrl = "${python_url}"
  $GitUrl = "${git_url}"

  # Download bootstrap file
  $Stage = "download bootstrap"
  $BootstrapFile = "$${Env:Temp}\$($${BootstrapUrl}.split("/")[-1])"
  (New-Object System.Net.WebClient).DownloadFile($BootstrapUrl, $BootstrapFile)

  # Install python and git
  $Stage = "install python/git"
  & "$BootstrapFile" `
      -PythonUrl "$PythonUrl" `
      -GitUrl "$GitUrl" `
      -Verbose -ErrorAction Stop
  Test-DisplayResult "Install Python/Git" $?
}

function Install-Watchmaker {
  param (
    [Parameter(Mandatory=$false)][bool]$UseVenv=$false
  )

  $GitRepo = "${git_repo}"
  $GitRef = "${git_ref}"

  # Upgrade pip and setuptools
  $Stage = "upgrade pip setuptools boto3"
  Test-Command "python -m pip install --index-url=`"$PypiUrl`" --upgrade pip setuptools" -Tries 2
  Test-Command "pip install --index-url=`"$PypiUrl`" --upgrade boto3" -Tries 2

  if ($UseVenv) {
    $Stage = "install virtualenv wheel"
    Test-Command "pip install virtualenv wheel"

    # ----- build the standalone binary
    # use a virtual env
    $Stage = "virtualenv"
    $VirtualEnvDir = "C:\venv"
    mkdir $VirtualEnvDir
    Test-DisplayResult "Create virtualenv directory" $?

    Test-Command "virtualenv $VirtualEnvDir"
    Invoke-CmdScript "$VirtualEnvDir\Scripts\activate.bat"
    Test-DisplayResult "Activate virtualenv" $?
  }

  # Clone watchmaker
  $Stage = "git"
  Test-Command "git clone `"$GitRepo`" --recursive" -Tries 2
  cd watchmaker
  if ($GitRef) {
    # decide whether to switch to pull request or branch
    if ($GitRef -match "^[0-9]+$") {
      Test-Command "git fetch origin pull/$GitRef/head:pr-$GitRef" -Tries 2
      Test-Command "git checkout pr-$GitRef"
    } else {
      Test-Command "git checkout $GitRef"
    }
  }

  # Update submodule refs
  $Stage = "update submodules"
  Test-Command "git submodule update"

  # Install watchmaker
  $Stage = "install wam"
  Test-Command "pip install --upgrade --index-url `"$PypiUrl`" --editable ."
}

$ErrorActionPreference = "Stop"

Write-Tfi "----------------------------- $InstanceOS$InstanceType ---------------------"

Set-Password -User "Administrator" -Pass "${rm_pass}"
Close-Firewall

# declare an array to hold the status (number and message)
$UserdataStatus=@(1,"Error: Build not completed (should never see this error)")

# Use TLS, as git won't do SSL now
[Net.ServicePointManager]::SecurityProtocol = "Ssl3, Tls, Tls11, Tls12"

# install 7-zip for use with artifacts - download fails after wam install, fyi
(New-Object System.Net.WebClient).DownloadFile("${seven_zip_url}", "$TempDir\7z-install.exe")
Invoke-Expression -Command "$TempDir\7z-install.exe /S /D='C:\Program Files\7-Zip'" -ErrorAction Continue

%{ if instance_type == "builder" }

try {
    Write-Tfi "Start build"
  
    # time wam install
    $StartDate=Get-Date
  
    # ---------- begin of wam standalone package build ----------
    Install-PythonGit
  
    Install-Watchmaker -UseVenv $true
  
    # Install prereqs
    $Stage = "install build prerequisites"
    
    python -m pip install --index-url="$PypiUrl" -r requirements\pip.txt
    Test-DisplayResult "Install pip" $?
  
    pip install --index-url="$PypiUrl" -r requirements\build.txt
    Test-DisplayResult "Install build prerequisites" $?
  
    # create standalone application
    gravitybee --src-dir src --sha file --with-latest --extra-data static --extra-pkgs boto3 --extra-modules boto3
    Test-DisplayResult "Run gravitybee (build standalone)" $?
  
    Invoke-CmdScript .\.gravitybee\gravitybee-environs.bat
    Test-DisplayResult "Set environment variables" $?
  
    if ($env:GB_ENV_STAGING_DIR) {
      Remove-Item ".\$env:GB_ENV_STAGING_DIR\0*" -Recurse
      Write-S3Object -BucketName "$BuildSlug" -KeyPrefix "${release_prefix}" -Folder ".\$env:GB_ENV_STAGING_DIR" -Recurse
      Test-DisplayResult "Copy standalone to $ArtifactDest" $?
    }
  
    # ----------  end of wam standalone package build ----------
  
    $EndDate = Get-Date
    Write-Tfi("WAM standalone build took {0} seconds." -f [math]::Round(($EndDate - $StartDate).TotalSeconds))
    Write-Tfi("End build")
    $UserdataStatus=@(0,"Success") # made it this far, it's a success
} catch {
  $ErrorMessage = [String]$_.Exception + "Invocation Info: " + ($PSItem.InvocationInfo | Format-List * | Out-String)
  Write-Tfi ("*** ERROR caught ($Stage) ***")
  Write-Tfi $ErrorMessage
  Debug-2S3 $ErrorMessage
  
  # signal any instances waiting to test this standalone that the build failed
  if (-not (Test-Path "$ErrorSignalFile")) {
      New-Item "$ErrorSignalFile" -ItemType "file" -Force
  }
  $Msg = "$ErrorMessage (For more information on the error, see the win_builder/userdata.log file.)"
  "$(Get-Date): $Msg" | Out-File "$ErrorSignalFile" -Append -Encoding utf8
  Write-S3Object -BucketName "$BuildSlug/${release_prefix}" -File $ErrorSignalFile
  Write-Tfi "Signal error to S3" $?
  
  # setup userdata status for passing to the test script via a file
  $ErrCode = 1  # trying to set this to $lastExitCode does not work (always get 0)
  $UserdataStatus=@($ErrCode,"Error at: " + $Stage + " [$ErrorMessage]")
}

Rename-User -From "Administrator" -To "$RMUser"
Open-WinRM
Write-UserdataStatus -UserdataStatus $UserdataStatus
Open-Firewall
Publish-Artifacts

%{ else }

Check-Metadata-Availability

try {
  Write-Tfi "Start install"

  # time wam install
  $StartDate=Get-Date

  if ($isStandalone) {
    Write-Tfi "Installing Watchmaker from standalone executable package............."

    $SleepTime = 20
    $Standalone = "${executable}"
    $ErrorKey = $ErrorSignalFile

    Write-Tfi "Looking for standalone executable at $BuildSlug/$Standalone"
    Write-Tfi "Looking for error signal at $BuildSlug/$ErrorKey"

    #block until executable exists, an error, or timeout
    while ($true) {
      # find out what's happening with the builder
      $Exists = $true
      $SignaledError = $true

      # see if the standalone is ready yet
      try {
        Get-S3ObjectMetadata -BucketName "$BuildSlug" -Key "$Standalone"
      } catch {
        $Exists = $false
      }

      # see if the builder encountered an error
      try {
        Get-S3ObjectMetadata -BucketName "$BuildSlug" -Key "$ErrorKey"
      } catch {
        $SignaledError = $false
      }

      if ($SignaledError) {
        # error signaled by the builder
        $ErrorMsg = "Error signaled by the builder (Error file found at $BuildSlug/$ErrorKey)"
        Write-Tfi $ErrorMsg
        throw $ErrorMsg
        break
      } else {
        if ($Exists) {
          Write-Tfi "The standalone executable was found!"
          break
        } else {
          Write-Tfi "The standalone executable was not found. Trying again in $SleepTime s..."
          Start-Sleep -Seconds $SleepTime
        }
      }
    } # end of while($true)

    #Invoke-Expression -Command "mkdir C:\scripts" -ErrorAction SilentlyContinue
    $DownloadDir = "${download_dir}"
    Read-S3Object -BucketName "$BuildSlug" -Key $Standalone -File "$DownloadDir\watchmaker.exe"
    Test-Command "$DownloadDir\watchmaker.exe ${common_args} ${win_args}"
  } else {
    # ---------- begin of wam install ----------
    Write-Tfi "Installing Watchmaker from source...................................."

    Install-PythonGit
    Install-Watchmaker

    # Run watchmaker
    $Stage = "run wam"
    Test-Command "watchmaker ${common_args} ${win_args}"
    # ----------  end of wam install ----------
  }

  $EndDate = Get-Date
  Write-Tfi ("WAM install took {0} seconds." -f [math]::Round(($EndDate - $StartDate).TotalSeconds))
  Write-Tfi "End install"
  $UserdataStatus=@(0,"Success") # made it this far, it's a success
} catch {
  $ErrorMessage = [String]$_.Exception + "Invocation Info: " + ($PSItem.InvocationInfo | Format-List * | Out-String)
  Write-Tfi ("*** ERROR caught ($Stage) ***")
  Write-Tfi $ErrorMessage
  Debug-2S3 $ErrorMessage

  # setup userdata status for passing to the test script via a file
  $ErrCode = 1  # trying to set this to $lastExitCode does not work (always get 0)
  $UserdataStatus=@($ErrCode,"Error at: " + $Stage + " [$ErrorMessage]")
}

# in case wam didn't change admin account name, winrm won't be able to log in so make sure
Rename-User -From "Administrator" -To "$RMUser"

# Open-WinRM won't work if lgpo is blocking, but we'll have salt in that case
Open-WinRM

if (Test-Path -path "C:\salt\salt-call.bat") {
  # fix the lgpos to allow winrm
  C:\salt\salt-call --local -c C:\Watchmaker\salt\conf ash_lgpo.set_reg_value `
      key='HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service\AllowBasic' `
      value='1' `
      vtype='REG_DWORD'
  Write-Tfi "Salt modify lgpo, allow basic" $?

  C:\salt\salt-call --local -c C:\Watchmaker\salt\conf ash_lgpo.set_reg_value `
      key='HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service\AllowUnencryptedTraffic' `
      value='1' `
      vtype='REG_DWORD'
  Write-Tfi "Salt modify lgpo, unencrypted" $?
}

Write-UserdataStatus -UserdataStatus $UserdataStatus
Open-Firewall
Publish-Artifacts

%{ endif }
