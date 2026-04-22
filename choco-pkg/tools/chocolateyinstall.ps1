$ErrorActionPreference = 'Stop'

$toolsDir = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"
$url64 = 'https://github.com/psmux/psmux/releases/download/v3.3.3/psmux-v3.3.3-windows-x64.zip'

$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  unzipLocation  = $toolsDir
  url64bit       = $url64
  checksum64     = 'E6FE103A776ED453647F82254445CBD4BA851E1A14BCBB959FDF858DE16CE5DD'
  checksumType64 = 'sha256'
}

Install-ChocolateyZipPackage @packageArgs

$psmuxPath = Join-Path $toolsDir "psmux.exe"
$pmuxPath = Join-Path $toolsDir "pmux.exe"
$tmuxPath = Join-Path $toolsDir "tmux.exe"

Install-BinFile -Name "psmux" -Path $psmuxPath
Install-BinFile -Name "pmux" -Path $pmuxPath
Install-BinFile -Name "tmux" -Path $tmuxPath