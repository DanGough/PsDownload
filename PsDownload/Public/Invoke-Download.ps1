<#
.SYNOPSIS
Downloads a file from a specified URI.

.DESCRIPTION
The Invoke-Download function downloads a file from a specified URI and saves it to the specified destination.

.PARAMETER Uri
The URI of the file to download. URL is accepted as an alias.

.PARAMETER Destination
The destination folder where the downloaded file will be saved. Default is the current working directory.

.PARAMETER FileName
The name of the downloaded file. If not provided, the function will attempt to extract the filename from the URI.

.PARAMETER UserAgent
The user agent string to use for the request. By default, it uses two user agent strings: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36' and 'Googlebot/2.1 (+http://www.google.com/bot.html)'. You can specify multiple user agent strings as an array.

.PARAMETER Headers
Additional headers to include in the request. Default is @{'accept' = '*/*'}, which is needed to trick some servers into serving a download, such as from FileZilla.

.PARAMETER TempPath
The temporary folder path to use for storing the downloaded file temporarily. Default is the user's temp folder.

.PARAMETER IgnoreDate
If specified, the function will not set the last modified date of the downloaded file.

.PARAMETER BlockFile
If specified, the downloaded file will be marked as downloaded from the internet.

.PARAMETER NoClobber
If specified, the function will not overwrite an existing file with the same name in the destination folder.

.PARAMETER NoProgress
If specified, the function will not display a progress bar during the download.

.PARAMETER PassThru
If specified, the function will return the downloaded file object.

.EXAMPLE
Invoke-Download -Uri 'https://example.com/file.txt' -Destination 'C:\Downloads'

This example downloads the file from the specified URI and saves it to the 'C:\Downloads' folder.

#>
function Invoke-Download {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [Alias('Url')]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,
        
        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination = $PWD.Path,
        
        [Parameter(Position = 2)]
        [string]$FileName,

        [string[]]$UserAgent = @('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36', 'Googlebot/2.1 (+http://www.google.com/bot.html)'),
        
        [hashtable]$Headers = @{accept = '*/*' },
        
        [string]$TempPath = [System.IO.Path]::GetTempPath(),
        
        [switch]$IgnoreDate,
        
        [switch]$BlockFile,
        
        [switch]$NoClobber,
        
        [switch]$NoProgress,
        
        [switch]$PassThru
    )	
	
    begin {
        # Required on Windows Powershell only
        if ($PSEdition -eq 'Desktop') {
            Add-Type -AssemblyName System.Net.Http
            Add-Type -AssemblyName System.Web
        }

        # Enable TLS 1.2 in addition to whatever is pre-configured
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # Create one single client object for the pipeline
        $HttpClient = New-Object System.Net.Http.HttpClient

        foreach ($Header in $Headers.GetEnumerator()) {
            $HttpClient.DefaultRequestHeaders.Add($Header.Key, $Header.Value)
        }
    }

    process {

        $ResolveUriSplat = @{
            Uri       = $Uri
            UserAgent = $UserAgent
            Headers   = $Headers
        }
        $Properties = Resolve-Uri @ResolveUriSplat -ErrorAction Stop

        if ([string]::IsNullOrEmpty($FileName)) {
            if ([string]::IsNullOrEmpty($Properties.FileName)) {
                Write-Error "No filename found for $Uri"
                return
            }
            else {
                $FileName = $Properties.FileName
            }
        }

        $DestinationFilePath = Join-Path $Destination $FileName

        # Exit if -NoClobber specified and file exists.
        if ($NoClobber -and (Test-Path -LiteralPath $DestinationFilePath -PathType Leaf)) {
            Write-Error 'NoClobber switch specified and file already exists'
            return
        }

        foreach ($UserAgentString in $UserAgent) {
            $HttpClient.DefaultRequestHeaders.Remove('User-Agent') | Out-Null
            if ($UserAgentString) {
                Write-Verbose "$($MyInvocation.MyCommand): Using UserAgent '$UserAgentString'"
                $HttpClient.DefaultRequestHeaders.Add('User-Agent', $UserAgentString)
            }

            $ResponseStream = $HttpClient.GetStreamAsync($Uri)

            if ($ResponseStream.Result.CanRead) {
                break
            }
            else {
                continue
            }
        }

        if (!$ResponseStream.Result.CanRead) {
            throw "$($MyInvocation.MyCommand): $($ResponseStream.Exception.InnerException.Message)"
        }

        # Check TempPath exists and create it if not
        if (-not (Test-Path -LiteralPath $TempPath -PathType Container)) {
            Write-Verbose "$($MyInvocation.MyCommand): Temp folder '$TempPath' does not exist"
            try {
                New-Item -LiteralPath $Destination -ItemType Directory -Force | Out-Null
                Write-Verbose "$($MyInvocation.MyCommand): Created temp folder '$TempPath'"
            }
            catch {
                Write-Error "$($MyInvocation.MyCommand): Unable to create temp folder '$TempPath': $_"
                return
            }
        }
        
        # Generate temp file name
        $TempFileName = (New-Guid).ToString('N') + ".tmp"
        $TempFilePath = Join-Path $TempPath $TempFileName
        
        # Check Destination exists and create it if not
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
            Write-Verbose "$($MyInvocation.MyCommand): Output folder '$Destination' does not exist"
            try {
                New-Item -Path $Destination -ItemType Directory -Force | Out-Null
                Write-Verbose "$($MyInvocation.MyCommand): Created output folder '$Destination'"
            }
            catch {
                Write-Error "$($MyInvocation.MyCommand): Unable to create output folder '$Destination': $_"
                return
            }
        }
        
        # Open file stream
        try {
            $FileStream = [System.IO.File]::Create($TempFilePath)
        }
        catch {
            Write-Error "$($MyInvocation.MyCommand): Unable to create file '$TempFilePath': $_"
            return
        }
                
        if ($FileStream.CanWrite) {
            Write-Verbose "$($MyInvocation.MyCommand): Downloading to temp file '$TempFilePath'..."
        
            $Buffer = New-Object byte[] 64KB
            $BytesDownloaded = 0
            $ProgressIntervalMs = 250
            $ProgressTimer = (Get-Date).AddMilliseconds(-$ProgressIntervalMs)
        
            while ($true) {
                try {
                    # Read stream into buffer
                    $ReadBytes = $ResponseStream.Result.Read($Buffer, 0, $Buffer.Length)
        
                    # Track bytes downloaded and display progress bar if enabled and file size is known
                    $BytesDownloaded += $ReadBytes
                    if (!$NoProgress -and (Get-Date) -gt $ProgressTimer.AddMilliseconds($ProgressIntervalMs)) {
                        if ($Properties.FileSizeBytes) {
                            $PercentComplete = [System.Math]::Floor($BytesDownloaded / $Properties.FileSizeBytes * 100)
                            Write-Progress -Activity "Downloading $FileName" -Status "$BytesDownloaded of $($Properties.FileSizeBytes) bytes ($PercentComplete%)" -PercentComplete $PercentComplete
                        }
                        else {
                            Write-Progress -Activity "Downloading $FileName" -Status "$BytesDownloaded of ? bytes" -PercentComplete 0
                        }
                        $ProgressTimer = Get-Date
                    }
        
                    # If end of stream
                    if ($ReadBytes -eq 0) {
                        Write-Progress -Activity "Downloading $FileName" -Completed
                        $FileStream.Close()
                        $FileStream.Dispose()
                        try {
                            Write-Verbose "$($MyInvocation.MyCommand): Moving temp file to destination '$DestinationFilePath'"
                            $DownloadedFile = Move-Item -LiteralPath $TempFilePath -Destination $DestinationFilePath -Force -PassThru
                        }
                        catch {
                            Write-Error "$($MyInvocation.MyCommand): Error moving file from '$TempFilePath' to '$DestinationFilePath': $_"
                            return
                        }
                        if ($IsWindows) {
                            if ($BlockFile) {
                                Write-Verbose "$($MyInvocation.MyCommand): Marking file as downloaded from the internet"
                                Set-Content -LiteralPath $DownloadedFile -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`nZoneId=3"
                            }
                            else {
                                Unblock-File -LiteralPath $DownloadedFile
                            }
                        }
                        if ($Properties.LastModified -and -not $IgnoreDate) {
                            Write-Verbose "$($MyInvocation.MyCommand): Setting Last Modified date"
                            $DownloadedFile.LastWriteTime = $Properties.LastModified
                        }
                        Write-Verbose "$($MyInvocation.MyCommand): Download complete!"
                        if ($PassThru) {
                            $DownloadedFile
                        }
                        break
                    }
                    $FileStream.Write($Buffer, 0, $ReadBytes)
                }
                catch {
                    Write-Error "$($MyInvocation.MyCommand): Error downloading file: $_"
                    Write-Progress -Activity "Downloading $FileName" -Completed
                    $FileStream.Close()
                    $FileStream.Dispose()
                    break
                }
            }
            
        }

    }

    end {
        $HttpClient.Dispose()
    }
}