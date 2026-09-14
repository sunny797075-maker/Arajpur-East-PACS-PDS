$ErrorActionPreference = 'Stop'
$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sessionDir = Join-Path $env:TEMP 'pds-lightsail-session'
$server = '2406:da1a:356:9e00:a628:20cc:ea83:fbdc'
$profileArgs = @('--profile','pds-lightsail','--region','ap-south-1')
function Assert-Exit([string]$operation) { if ($LASTEXITCODE -ne 0) { throw "$operation failed." } }
& $aws sts get-caller-identity @profileArgs --query Account --output text
Assert-Exit 'AWS authentication (run aws login --profile pds-lightsail first)'
if (!(Test-Path -LiteralPath (Join-Path $repo 'saas/flutter_client/build/web/main.dart.js'))) { throw 'Build the Flutter web release first.' }
[IO.Directory]::CreateDirectory($sessionDir) | Out-Null
$taskIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $sessionDir /inheritance:r /grant:r "${taskIdentity}:(OI)(CI)F" | Out-Null
Assert-Exit 'Private deployment directory permissions'
$keyPath = Join-Path $sessionDir 'id_rsa'
$certPath = Join-Path $sessionDir 'id_rsa-cert.pub'
$knownHosts = Join-Path $sessionDir 'known_hosts'
$opened = $false
try {
  $clientIp = (& curl.exe -6 --noproxy '*' --max-time 10 -sS https://api64.ipify.org).Trim()
  Assert-Exit 'Deployment IPv6 lookup'
  if ($clientIp -notmatch '^[0-9a-fA-F:]+$' -or !$clientIp.Contains(':')) { throw 'Invalid deployment IPv6 address.' }
  & $aws lightsail open-instance-public-ports --instance-name LAMP-1 --port-info "fromPort=22,toPort=22,protocol=tcp,ipv6Cidrs=$clientIp/128,cidrListAliases=lightsail-connect" @profileArgs --query operation.status --output text
  Assert-Exit 'Temporary SSH access'
  $opened = $true
  $accessJson = & $aws lightsail get-instance-access-details --instance-name LAMP-1 --protocol ssh @profileArgs --output json
  Assert-Exit 'Temporary SSH certificate'
  $access = ($accessJson | ConvertFrom-Json).accessDetails
  $utf8 = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($keyPath, $access.privateKey.Replace("`r`n","`n")+"`n", $utf8)
  [IO.File]::WriteAllText($certPath, $access.certKey.Replace("`r`n","`n")+"`n", $utf8)
  $hostLines = @($access.hostKeys | ForEach-Object { "$server $($_.algorithm) $($_.publicKey)" })
  [IO.File]::WriteAllLines($knownHosts, $hostLines, $utf8)
  $access=$null; $accessJson=$null
  $apiArchive=Join-Path $sessionDir 'pds-api-update.tar.gz'
  $webArchive=Join-Path $sessionDir 'pds-saas-web.tar.gz'
  & tar.exe -czf $apiArchive -C (Join-Path $repo 'saas/backend') dist
  Assert-Exit 'API archive'
  & tar.exe -czf $webArchive -C (Join-Path $repo 'saas/flutter_client/build/web') .
  Assert-Exit 'Web archive'
  $sshArgs=@('-6','-i',$keyPath,'-o',"UserKnownHostsFile=$knownHosts",'-o','StrictHostKeyChecking=yes','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=3')
  $files=@($apiArchive,$webArchive,(Join-Path $repo 'saas/database/002_workflows.sql'),(Join-Path $PSScriptRoot 'migrate-workflows.sh'),(Join-Path $PSScriptRoot 'update-saas.sh'),(Join-Path $PSScriptRoot 'verify-live-workflows.cjs'))
  for($attempt=1;$attempt -le 3;$attempt++) {
    & scp.exe @sshArgs -l 2048 @files "admin@[$server]:/tmp/"
    if($LASTEXITCODE -eq 0){break}
    if($attempt -eq 3){throw 'Deployment upload failed after three attempts.'}
  }
  & ssh.exe @sshArgs "admin@$server" 'sudo bash /tmp/migrate-workflows.sh'
  Assert-Exit 'Database backup and workflow migration'
  & ssh.exe @sshArgs "admin@$server" 'sudo bash /tmp/update-saas.sh'
  Assert-Exit 'API and web publication'
  & ssh.exe @sshArgs "admin@$server" 'sudo -u postgres /opt/pds/node/bin/node /tmp/verify-live-workflows.cjs'
  Assert-Exit 'Live workflow verification'
  Write-Output 'Verified deployment: https://15.252.37.89/'
} finally {
  if($opened){
    & $aws lightsail close-instance-public-ports --instance-name LAMP-1 --port-info "fromPort=22,toPort=22,protocol=tcp,ipv6Cidrs=$clientIp/128" @profileArgs --query operation.status --output text
    if($LASTEXITCODE -ne 0){Write-Warning 'Could not remove the temporary SSH exception. Retry closure using the deployment IPv6 address.'}
  }
  foreach($credentialFile in @($keyPath,$certPath)){
    if(Test-Path -LiteralPath $credentialFile){Remove-Item -LiteralPath $credentialFile -Force}
  }
}
